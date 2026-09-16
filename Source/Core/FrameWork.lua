----------------------------------------------------------------
-- StockPiler3 Core/FrameWork -- frame-sliced prewarm job queue
-- One StartOnce heavy job per Pump (budget=1). Publish only in done().
-- Never slice engine craft APIs (PlantSeed / BuyItem / PerformCrafting).
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.FrameWork = StockPiler3.FrameWork or {}

local FW = StockPiler3.FrameWork

FW.DEFAULT_STEPS_PER_FRAME = 1
FW.DEFAULT_FRAME_BUDGET = 1

FW._jobs = FW._jobs or {}
FW._order = FW._order or {}
FW._didWork = false
FW._lastComplete = FW._lastComplete or {}
FW._frameBudget = FW.DEFAULT_FRAME_BUDGET

local function TryCall(context, fn, ...)
    if StockPiler3.Debug and StockPiler3.Debug.TryCallQuiet then
        return StockPiler3.Debug.TryCallQuiet(context, fn, ...)
    end
    return pcall(fn, ...)
end

local function RemoveFromOrder(id)
    local order = FW._order
    for i = #order, 1, -1 do
        if order[i] == id then
            table.remove(order, i)
        end
    end
end

local function FinishJob(id, job)
    FW._jobs[id] = nil
    RemoveFromOrder(id)
    if type(job.done) == "function" then
        TryCall("FrameWork.done:" .. id, job.done)
    end
    FW._lastComplete[id] = {
        gen = job.gen,
        at = (GetGameTime and GetGameTime()) or 0,
    }
end

local function RunOneStep(job)
    local id = job.id
    if type(job.resume) == "function" then
        local ok, result = TryCall("FrameWork.resume:" .. id, job.resume, job.state)
        if not ok then
            return false
        end
        return result ~= "done"
    end
    local list = job.list
    local index = tonumber(job.index) or 1
    if type(list) ~= "table" or index > #list then
        return false
    end
    if type(job.step) == "function" then
        local ok = TryCall("FrameWork.step:" .. id, job.step, list[index], index)
        if not ok then
            return false
        end
    end
    job.index = index + 1
    return job.index <= #list
end

local function ShouldSkipPump()
    local Sch = StockPiler3.Scheduler
    if Sch then
        if Sch.SkipPlanThisFrameActive and Sch.SkipPlanThisFrameActive() == true then
            return true
        end
        if Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
            return true
        end
        if Sch._skipPlanThisFrame == true then
            return true
        end
    end
    local Orch = StockPiler3.Orchestrator
    if Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true then
        return true
    end
    return false
end

function FW.SetFrameBudget(n)
    n = tonumber(n) or FW.DEFAULT_FRAME_BUDGET
    if n < 1 then
        n = 1
    end
    FW._frameBudget = n
end

function FW.GetFrameBudget()
    return tonumber(FW._frameBudget) or FW.DEFAULT_FRAME_BUDGET
end

function FW.DidWork()
    return FW._didWork == true
end

function FW.ClearDidWork()
    FW._didWork = false
end

function FW.IsActive(id)
    id = tostring(id or "")
    return id ~= "" and type(FW._jobs[id]) == "table"
end

function FW.Busy()
    return #(FW._order) > 0
end

function FW.GetLastComplete(id)
    id = tostring(id or "")
    return FW._lastComplete[id]
end

function FW.Cancel(id)
    id = tostring(id or "")
    if id == "" then
        return
    end
    local job = FW._jobs[id]
    if type(job) ~= "table" then
        return
    end
    FW._jobs[id] = nil
    RemoveFromOrder(id)
    if type(job.cancel) == "function" then
        TryCall("FrameWork.cancel:" .. id, job.cancel)
    end
end

--- Start or replace a prewarm job.
--- opts.id (required), opts.gen (same id+gen no-ops if already running)
--- opts.list + opts.step  OR  opts.resume(state) -> "continue"|"done"
--- opts.done / opts.cancel / opts.stepsPerFrame
function FW.Start(opts)
    opts = type(opts) == "table" and opts or nil
    if not opts then
        return false
    end
    local id = tostring(opts.id or "")
    if id == "" then
        return false
    end
    local gen = opts.gen
    local existing = FW._jobs[id]
    if type(existing) == "table" and existing.gen ~= nil and gen ~= nil
        and tostring(existing.gen) == tostring(gen)
    then
        return false
    end
    if type(existing) == "table" then
        FW.Cancel(id)
    end
    local steps = tonumber(opts.stepsPerFrame) or FW.DEFAULT_STEPS_PER_FRAME
    if steps < 1 then
        steps = 1
    end
    local job = {
        id = id,
        gen = gen,
        list = type(opts.list) == "table" and opts.list or nil,
        index = 1,
        step = type(opts.step) == "function" and opts.step or nil,
        resume = type(opts.resume) == "function" and opts.resume or nil,
        state = type(opts.state) == "table" and opts.state or {},
        done = type(opts.done) == "function" and opts.done or nil,
        cancel = type(opts.cancel) == "function" and opts.cancel or nil,
        stepsPerFrame = steps,
        cost = math.max(1, tonumber(opts.cost) or 1),
    }
    if job.list == nil and job.resume == nil and job.step == nil then
        return false
    end
    if job.list == nil and job.resume == nil and job.step ~= nil then
        local stepFn = job.step
        job.resume = function(_state)
            TryCall("FrameWork.step:" .. id, stepFn, nil, 1)
            return "done"
        end
        job.step = nil
    end
    FW._jobs[id] = job
    RemoveFromOrder(id)
    FW._order[#FW._order + 1] = id
    return true
end

function FW.StartOnce(id, gen, fn)
    return FW.Start({
        id = id,
        gen = gen,
        stepsPerFrame = 1,
        step = function()
            if type(fn) == "function" then
                fn()
            end
        end,
    })
end

--- WarmHave / Demand / seed-lines style helpers (call into Planner when present).
function FW.EnqueueWarmHave(gen)
    return FW.StartOnce("prewarm-warm-have", gen, function()
        local P = StockPiler3.Planner
        -- Must warm watched recipe specs — nil WarmSpecHaveCache marks empty warm.
        if P and P.WarmHave then
            P.WarmHave()
        elseif P and P.WarmSpecHaveCacheForWatches then
            P.WarmSpecHaveCacheForWatches()
        end
    end)
end

function FW.EnqueueDemand(gen)
    return FW.StartOnce("prewarm-demand", gen, function()
        local P = StockPiler3.Planner
        if P and P.WarmDemand then
            P.WarmDemand()
        elseif P and P.BuildBalancedSpecDemand then
            P.BuildBalancedSpecDemand({ cacheOnly = true })
        end
    end)
end

function FW.EnqueueSeedLines(gen)
    return FW.StartOnce("prewarm-seed-lines", gen, function()
        local Grow = StockPiler3.Grow
        if Grow and Grow.WarmSeedLines then
            Grow.WarmSeedLines()
        elseif Grow and Grow.CollectAutoGrowSeedLines then
            Grow.CollectAutoGrowSeedLines({ cacheOnly = true })
        end
    end)
end

--- Drain up to frame budget (default 1). Returns true if any step ran.
function FW.Pump()
    FW._didWork = false
    if ShouldSkipPump() then
        return false
    end
    local budget = FW.GetFrameBudget()
    local spent = 0
    local guard = 0
    while spent < budget and #(FW._order) > 0 and guard < 64 do
        guard = guard + 1
        local id = FW._order[1]
        local job = FW._jobs[id]
        if type(job) ~= "table" then
            RemoveFromOrder(id)
        else
            local steps = tonumber(job.stepsPerFrame) or 1
            local cost = tonumber(job.cost) or 1
            local n = 0
            local cont = true
            while cont and n < steps and (spent + cost) <= budget do
                cont = RunOneStep(job) == true
                n = n + 1
                spent = spent + cost
                FW._didWork = true
            end
            if cont ~= true then
                FinishJob(id, job)
            else
                RemoveFromOrder(id)
                if FW._jobs[id] == job then
                    FW._order[#FW._order + 1] = id
                end
            end
        end
    end
    if FW._didWork == true and StockPiler3.Perf and StockPiler3.Perf.Mark then
        StockPiler3.Perf.Mark("FrameWork.Pump")
    end
    return FW._didWork == true
end

function FW.Shutdown()
    local order = FW._order
    for i = #order, 1, -1 do
        FW.Cancel(order[i])
    end
    FW._jobs = {}
    FW._order = {}
    FW._didWork = false
end
