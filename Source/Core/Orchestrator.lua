----------------------------------------------------------------
-- StockPiler3 Core/Orchestrator -- phase FSM + paced AutoGrow tick
-- Tick order: plant one -> additives -> refine -> buy
-- fillBlocked: extend only if newWait > cur; clear when buffer ok.
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Orchestrator = StockPiler3.Orchestrator or {}

local Orch = StockPiler3.Orchestrator

Orch.Phase = "idle"
Orch._brewPhase = nil
Orch._lastOpId = 0
Orch._initialized = false
Orch._fillBlocked = false
Orch._fillBlockedWait = 0
Orch._busTokens = nil
Orch._seedBufferRefineArmed = false
Orch._inTick = false

local function TrackBus(token)
    if token == nil then
        return
    end
    Orch._busTokens = Orch._busTokens or {}
    Orch._busTokens[#Orch._busTokens + 1] = token
end

local function SetPhase(phase, reason)
    phase = tostring(phase or "idle")
    if Orch.Phase == phase then
        return
    end
    local prev = Orch.Phase
    Orch.Phase = phase
    if StockPiler3.Debug and StockPiler3.Debug.LogOp then
        StockPiler3.Debug.LogOp("orch", tostring(prev) .. "->" .. phase .. " reason=" .. tostring(reason or "?"))
    end
    local B = StockPiler3.EventBus
    local E = StockPiler3.Events
    if B and E and E.PHASE_CHANGED then
        B.Fire(E.PHASE_CHANGED, { phase = phase, prev = prev, reason = reason })
    end
end

local function HasAutoBuyWork()
    return StockPiler3.Buy and StockPiler3.Buy.NeedsTick and StockPiler3.Buy.NeedsTick() == true
end

local function TryBuyTick(opId)
    if not HasAutoBuyWork() then
        return false
    end
    local Buy = StockPiler3.Buy
    local ok = false
    if Buy and Buy.IssueOne then
        ok = Buy.IssueOne(opId) == true
    elseif Buy and Buy.OnTick then
        ok = Buy.OnTick() == true
    end
    if ok then
        SetPhase("buying", "auto")
        if StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
            StockPiler3.Scheduler.WakeAutoBuy()
        end
        return true
    end
    return false
end

local function HasPendingBufferRefine()
    local Grow = StockPiler3.Grow
    if Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() == true then
        return true
    end
    return false
end

local function HasAutoGrowWork()
    local Watch = StockPiler3.Watch
    if not Watch or not Watch.IsAutoGrowEnabled or Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    local Grow = StockPiler3.Grow
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive() then
        return true
    end
    if Orch.IsFillBlocked() then
        local RP = StockPiler3.RefinePipeline
        if RP and RP.HasOutstanding and RP.HasOutstanding() then
            return true
        end
        return HasPendingBufferRefine()
    end
    local RP = StockPiler3.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() then
        return true
    end
    if Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() then
        return true
    end
    local Refine = StockPiler3.Refine
    if Refine and Refine._refineDirty == true then
        return true
    end
    return HasPendingBufferRefine()
end

local function ClearFillIfBufferOk()
    local Grow = StockPiler3.Grow
    if Grow and Grow.IsSeedBufferSatisfied and Grow.IsSeedBufferSatisfied() == true then
        Orch.ClearFillBlocked()
        if Grow.ClearFillBlocked then
            Grow.ClearFillBlocked()
        end
        return true
    end
    return false
end

local function EndTick()
    Orch._inTick = false
    if StockPiler3.Perf and StockPiler3.Perf.End then
        StockPiler3.Perf.End("Orchestrator.Tick")
    end
end

function Orch.GetPhase()
    return tostring(Orch.Phase or "idle")
end

function Orch.IsHarvestActive()
    if StockPiler3.Grow and StockPiler3.Grow.IsHarvestOpActive then
        return StockPiler3.Grow.IsHarvestOpActive() == true
    end
    return false
end

function Orch.IsBrewSessionActive()
    return Orch._brewPhase == "loading" or Orch._brewPhase == "loaded"
end

function Orch.SetBrewPhase(phase)
    Orch._brewPhase = phase
end

function Orch.IsFillBlocked()
    if Orch._fillBlocked == true then
        return true
    end
    local Grow = StockPiler3.Grow
    if Grow and Grow.IsFillBlocked and Grow.IsFillBlocked() == true then
        return true
    end
    return false
end

--- only extend wait if newWait > cur; do not re-arm every idle tick with a smaller/equal wait
function Orch.SetFillBlocked(wait)
    wait = tonumber(wait) or 0
    if wait < 0 then
        wait = 0
    end
    local cur = tonumber(Orch._fillBlockedWait) or 0
    if wait > cur then
        Orch._fillBlockedWait = wait
    end
    Orch._fillBlocked = true
    local Grow = StockPiler3.Grow
    if Grow and Grow.SetFillBlocked then
        Grow.SetFillBlocked(true, Orch._fillBlockedWait)
    end
end

function Orch.ClearFillBlocked()
    Orch._fillBlocked = false
    Orch._fillBlockedWait = 0
    local Grow = StockPiler3.Grow
    if Grow and Grow.ClearFillBlocked then
        Grow.ClearFillBlocked()
    end
end

function Orch.DecayFillBlocked()
    if Orch._fillBlocked ~= true then
        -- Grow may still be latched after Orch wait hit 0 on a prior tick.
        local Grow = StockPiler3.Grow
        if Grow and Grow.IsFillBlocked and Grow.IsFillBlocked() == true
            and Grow.ClearFillBlocked
        then
            Grow.ClearFillBlocked()
        end
        return
    end
    local wait = tonumber(Orch._fillBlockedWait) or 0
    if wait <= 0 then
        Orch.ClearFillBlocked()
        return
    end
    wait = wait - 1
    Orch._fillBlockedWait = wait
    if wait <= 0 then
        Orch.ClearFillBlocked()
    end
end

function Orch.OnAutoGrowDisabled()
    SetPhase("idle", "autogrow-off")
    Orch.ClearFillBlocked()
    if StockPiler3.Scheduler and StockPiler3.Scheduler.SetAutoGrowIdle then
        StockPiler3.Scheduler.SetAutoGrowIdle(true)
    end
end

function Orch.NewOpId()
    if StockPiler3.Debug and StockPiler3.Debug.NextOpId then
        Orch._lastOpId = StockPiler3.Debug.NextOpId()
    else
        Orch._lastOpId = (tonumber(Orch._lastOpId) or 0) + 1
    end
    return Orch._lastOpId
end

function Orch.DispatchCommand(kind, payload)
    kind = tostring(kind or "")
    payload = type(payload) == "table" and payload or {}
    local opId = Orch.NewOpId()
    if kind == "harvest" then
        SetPhase("harvesting", "user-macro")
        if StockPiler3.Grow and StockPiler3.Grow.HarvestClick then
            StockPiler3.Grow.HarvestClick()
        elseif StockPiler3.Grow and StockPiler3.Grow.HarvestNext then
            StockPiler3.Grow.HarvestNext(opId)
        end
        if Orch.Phase == "harvesting" then
            SetPhase("idle", "harvest-done")
        end
        if StockPiler3.Scheduler and StockPiler3.Scheduler.EnqueueBagFlush then
            StockPiler3.Scheduler.EnqueueBagFlush(true)
        end
        return true
    elseif kind == "brew.perform" then
        if StockPiler3.Brew and StockPiler3.Brew.TryPerform then
            StockPiler3.Brew.TryPerform(opId)
        elseif StockPiler3.Brew and StockPiler3.Brew.BrewClick then
            StockPiler3.Brew.BrewClick()
        end
        return true
    end
    return false
end

function Orch.Tick()
    -- PlantSeed/AddAdditive can re-enter UPDATE_PROCESSED on the same C stack.
    if Orch._inTick == true then
        return
    end
    Orch._inTick = true

    local ok, err = pcall(Orch._TickBody)
    if ok ~= true then
        Orch._inTick = false
        if StockPiler3.Perf and StockPiler3.Perf.End then
            StockPiler3.Perf.End("Orchestrator.Tick")
        end
        if StockPiler3.Debug and StockPiler3.Debug.ReportProtectedCallFailure then
            StockPiler3.Debug.ReportProtectedCallFailure("Orchestrator.Tick", err, true)
        end
    end
end

function Orch._TickBody()
    if StockPiler3.Perf and StockPiler3.Perf.Begin then
        StockPiler3.Perf.Begin("Orchestrator.Tick")
    end

    local Watch = StockPiler3.Watch
    local autoGrowOn = Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true
    if not autoGrowOn then
        -- AutoGrow off -> buy only
        TryBuyTick(Orch.NewOpId())
        if Orch.Phase ~= "idle" and not Orch.IsHarvestActive() and not Orch.IsBrewSessionActive() then
            SetPhase("idle", "autogrow-off")
        end
        EndTick()
        return
    end

    -- fillBlocked: allow refine AND plant (FindSeedSlot misses after refine used to
    -- latch fillBlocked and never retry planting while seeds sat in bag).
    if Orch.IsFillBlocked() then
        local Refine = StockPiler3.Refine
        local Grow = StockPiler3.Grow
        local Sch = StockPiler3.Scheduler
        local bufferRefine = HasPendingBufferRefine()
        local refineForced = Refine and (
            Refine._refineDirty == true
            or tostring(Refine._refineDirtyReason or "") == "harvest"
        )
        local usRefine = false
        local US = StockPiler3.UpgradeSeed
        if US and US.IsEnabled and US.IsEnabled() == true
            and US.NeedsRefineFirst and US.NeedsRefineFirst() == true
        then
            usRefine = true
            if Refine and Refine.MarkRefineDue then
                Refine.MarkRefineDue("upgrade-seed")
            end
        end
        local canPlant = Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true
        local hasSeeds = false
        if usRefine then
            -- Cheap probe clear; do not run PickPlantCandidate while refine-first.
            if Grow and Grow.MarkPlantJobProbed then
                Grow.MarkPlantJobProbed(nil)
            end
        elseif canPlant and Grow and Grow.GetPlantJob then
            local job = Grow.GetPlantJob()
            hasSeeds = type(job) == "table" and (tonumber(job.seedUid) or 0) > 0
        end
        if canPlant or bufferRefine or refineForced or usRefine then
            if Sch and Sch.SetAutoGrowIdle then
                Sch.SetAutoGrowIdle(false)
            end
        end
        local opId = Orch.NewOpId()
        if canPlant and hasSeeds then
            local planted = false
            if Grow and Grow.IssuePlantOne then
                planted = Grow.IssuePlantOne(opId) == true
            end
            if planted then
                SetPhase("planting", "auto")
                Orch.ClearFillBlocked()
                if Sch and Sch.WakeAutoGrow then
                    Sch.WakeAutoGrow()
                end
                EndTick()
                return
            end
        end
        if (bufferRefine or refineForced or usRefine)
            and Refine and Refine.ShouldAllowRefineNow and Refine.ShouldAllowRefineNow() == true
            and Refine.RefineCheckDue and Refine.RefineCheckDue() == true
            and Refine.TryTick
        then
            if Refine.TryTick(opId) == true then
                SetPhase("refining", bufferRefine and "seed-buffer" or "auto")
                Orch.ClearFillBlocked()
                if Sch and Sch.WakeAutoGrow then
                    Sch.WakeAutoGrow()
                end
                EndTick()
                return
            end
        end
        -- Keep fast ticks while empty plots remain; idle-5s made fillBlocked feel stuck.
        if not canPlant and Sch and Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(true)
        end
        if Orch.Phase ~= "idle" and not Orch.IsHarvestActive() and not Orch.IsBrewSessionActive() then
            SetPhase("idle", "fill-blocked")
        end
        TryBuyTick(Orch.NewOpId())
        EndTick()
        return
    end

    local Sch = StockPiler3.Scheduler
    local plantQuiet = Sch and Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true
    local harvestStorm = Sch and Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true
    -- plant quiet / harvest storm -> fast tick, no grow probes
    if plantQuiet or harvestStorm then
        if Sch and Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(false)
        end
        TryBuyTick(Orch.NewOpId())
        EndTick()
        return
    end

    -- brew loading/loaded -> skip grow; buy allowed.
    -- Probe first: settle-hold then silence can park phase=loaded forever
    -- (blocks grow + plan rebuild until a forced Build / watchplan).
    if Orch.IsBrewSessionActive() == true then
        local Brew = StockPiler3.Brew
        if Brew and Brew.ProbeStuckAutoLoaded then
            Brew.ProbeStuckAutoLoaded("orch-tick")
        end
    end
    if Orch.IsBrewSessionActive() == true then
        if Sch and Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(false)
        end
        TryBuyTick(Orch.NewOpId())
        EndTick()
        return
    end

    if not HasAutoGrowWork() then
        if Sch and Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(true)
        end
        if TryBuyTick(Orch.NewOpId()) then
            EndTick()
            return
        end
        if Orch.Phase ~= "idle" and not Orch.IsHarvestActive() and not Orch.IsBrewSessionActive() then
            SetPhase("idle", "idle-grow")
        end
        EndTick()
        return
    end

    -- Vendor open with buy work: take this tick (independent of plant/refine).
    -- Avoids busy AutoGrow starving AutoBuy while still one IssueOne/frame.
    if TryBuyTick(Orch.NewOpId()) then
        EndTick()
        return
    end

    local Grow = StockPiler3.Grow
    local canPlant = Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true
    -- Upgrade Seed refine-first: skip demand pick, clear plant-probe via MarkPlantJobProbed.
    -- Leaving dirty made ShouldAllowRefineNow return plant-probe-pending and block
    -- refine for ~50s after harvest (idle 5s ticks until a dump probed the queue).
    local usRefineFirst = false
    local US = StockPiler3.UpgradeSeed
    if US and US.IsEnabled and US.IsEnabled() == true
        and US.NeedsRefineFirst and US.NeedsRefineFirst() == true
    then
        usRefineFirst = true
        if StockPiler3.Refine and StockPiler3.Refine.MarkRefineDue then
            StockPiler3.Refine.MarkRefineDue("upgrade-seed")
        end
        if Grow and Grow.MarkPlantJobProbed then
            Grow.MarkPlantJobProbed(nil)
        elseif Grow and Grow.GetPlantJob then
            Grow.GetPlantJob()
        end
    end
    -- One plant-queue probe per tick (nil-cache makes idle re-entry O(1)).
    local hasSeeds = false
    if canPlant and not usRefineFirst and Grow and Grow.GetPlantJob then
        local job = Grow.GetPlantJob()
        hasSeeds = type(job) == "table" and (tonumber(job.seedUid) or 0) > 0
    end
    local needAdditives = Grow and Grow.NeedsCurrentStageAdditive
        and Grow.NeedsCurrentStageAdditive() == true
    local holdHarvestBatch = Grow and Grow.ShouldHoldPlantForReadyHarvest
        and Grow.ShouldHoldPlantForReadyHarvest() == true
    local opId = Orch.NewOpId()

    if (canPlant and hasSeeds) or needAdditives or usRefineFirst then
        if Sch and Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(false)
        end
    end

    -- 1) Plant one seed
    if canPlant and hasSeeds and not holdHarvestBatch then
        local deferPlant, deferReason = false, nil
        if Sch and Sch.ShouldDeferAutoGrowPlant then
            deferPlant, deferReason = Sch.ShouldDeferAutoGrowPlant()
        end
        if deferPlant == true then
            if Grow and Grow.LogSkipPlant then
                Grow.LogSkipPlant(tostring(deferReason or "combat"))
            end
            if Sch and Sch.SetAutoGrowIdle then
                Sch.SetAutoGrowIdle(false)
            end
        else
            local planted = false
            if Grow and Grow.IssuePlantOne then
                planted = Grow.IssuePlantOne(opId) == true
            elseif Grow and Grow.TryPlantOne then
                planted = Grow.TryPlantOne(opId) == true
            end
            if planted then
                SetPhase("planting", "auto")
                if Sch and Sch.WakeAutoGrow then
                    Sch.WakeAutoGrow()
                end
                EndTick()
                return
            end
            -- Plant fail / no-seeds: arm fillBlocked (extend only)
            Orch.SetFillBlocked(5)
        end
    elseif canPlant and hasSeeds and holdHarvestBatch then
        if Sch and Sch.SetAutoGrowIdle then
            Sch.SetAutoGrowIdle(false)
        end
    elseif canPlant and not hasSeeds then
        if HasPendingBufferRefine() or usRefineFirst then
            if not usRefineFirst and Orch._seedBufferRefineArmed ~= true
                and StockPiler3.Refine and StockPiler3.Refine.MarkRefineDue
            then
                Orch._seedBufferRefineArmed = true
                StockPiler3.Refine.MarkRefineDue("seed-buffer")
            end
            if Sch and Sch.SetAutoGrowIdle then
                Sch.SetAutoGrowIdle(false)
            end
        else
            Orch._seedBufferRefineArmed = false
            if not ClearFillIfBufferOk() then
                -- Do NOT re-arm fillBlocked every idle tick when already blocked
                -- or when buffer is merely short without a plant attempt this tick.
            end
            if Sch and Sch.SetAutoGrowIdle then
                Sch.SetAutoGrowIdle(true)
            end
        end
    else
        Orch._seedBufferRefineArmed = false
    end

    -- 2) Additives
    if needAdditives then
        local added = false
        if Grow and Grow.TryAdditive then
            added = Grow.TryAdditive(opId) == true
        end
        if added then
            SetPhase("planting", "additive")
            if Sch and Sch.WakeAutoGrow then
                Sch.WakeAutoGrow()
            end
            EndTick()
            return
        end
    end

    -- 3) Refine
    local Refine = StockPiler3.Refine
    local refineDue = Refine and Refine.ShouldAllowRefineNow and Refine.ShouldAllowRefineNow() == true
        and Refine.RefineCheckDue and Refine.RefineCheckDue() == true
    if refineDue and Refine.TryTick then
        local ok = Refine.TryTick(opId)
        if ok == true then
            SetPhase("refining", "auto")
            if Grow and Grow.MarkPlantJobDirty then
                Grow.MarkPlantJobDirty("refine")
            end
            if Sch and Sch.WakeAutoGrow then
                Sch.WakeAutoGrow()
            end
            EndTick()
            return
        end
        -- After failed refine, re-probe once and plant same tick (IssuePlantOne hits cache).
        if canPlant and Grow and Grow.MarkPlantJobDirty then
            Grow.MarkPlantJobDirty("refine-miss")
            if Grow.GetPlantJob then
                local job = Grow.GetPlantJob()
                hasSeeds = type(job) == "table" and (tonumber(job.seedUid) or 0) > 0
            end
        end
        if canPlant and hasSeeds and not holdHarvestBatch then
            local planted = false
            if Grow and Grow.IssuePlantOne then
                planted = Grow.IssuePlantOne(opId) == true
            elseif Grow and Grow.TryPlantOne then
                planted = Grow.TryPlantOne(opId) == true
            end
            if planted then
                SetPhase("planting", "auto")
                if Sch and Sch.WakeAutoGrow then
                    Sch.WakeAutoGrow()
                end
                EndTick()
                return
            end
        elseif canPlant and not hasSeeds then
            if not ClearFillIfBufferOk() then
                Orch.SetFillBlocked(5)
            end
        end
    elseif canPlant and not hasSeeds then
        if not ClearFillIfBufferOk() then
            -- Only arm after a real no-job path this tick (not every idle)
            if Orch._fillBlocked ~= true then
                Orch.SetFillBlocked(5)
            end
        end
    end

    -- 4) Buy
    if TryBuyTick(opId) then
        EndTick()
        return
    end

    if Orch.Phase ~= "idle" and not Orch.IsHarvestActive() and not Orch.IsBrewSessionActive() then
        SetPhase("idle", "tick-idle")
    end
    EndTick()
end

function Orch.DumpState(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler3.Debug and StockPiler3.Debug.Print then
            StockPiler3.Debug.Print(msg)
        end
    end
    emit("=== StockPiler3 state ===")
    emit("phase=" .. Orch.GetPhase() .. " lastOpId=" .. tostring(Orch._lastOpId or 0))
    emit("harvestActive=" .. tostring(Orch.IsHarvestActive() == true))
    emit("brewPhase=" .. tostring(Orch._brewPhase or "none"))
    emit("fillBlocked=" .. tostring(Orch._fillBlocked == true)
        .. " wait=" .. tostring(Orch._fillBlockedWait or 0))
    local Sch = StockPiler3.Scheduler
    if Sch then
        emit("harvestStorm=" .. tostring(Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true))
        emit("plantQuiet=" .. tostring(Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true))
    end
    if StockPiler3.Inventory and StockPiler3.Inventory.GetSnapshotMeta then
        local m = StockPiler3.Inventory.GetSnapshotMeta()
        emit(string.format(
            "inventory snapGen=%s ready=%s dirty=%s",
            tostring(m.snapGen), tostring(m.ready), tostring(m.dirty)
        ))
    elseif StockPiler3.Inventory and StockPiler3.Inventory.GetSnapGen then
        emit("inventory snapGen=" .. tostring(StockPiler3.Inventory.GetSnapGen()))
    end
    if StockPiler3.Garden and StockPiler3.Garden.GetGen then
        emit("gardenGen=" .. tostring(StockPiler3.Garden.GetGen()))
    end
    if StockPiler3.Watch and StockPiler3.Watch.GetGen then
        emit("watchGen=" .. tostring(StockPiler3.Watch.GetGen()))
    end
    if StockPiler3.Knowledge and StockPiler3.Knowledge.GetGen then
        emit("knowledgeGen=" .. tostring(StockPiler3.Knowledge.GetGen()))
    end
    if StockPiler3.RefinePipeline and StockPiler3.RefinePipeline.GetGen then
        emit("refinePipelineGen=" .. tostring(StockPiler3.RefinePipeline.GetGen()))
    end
    if StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Get then
        local plan = StockPiler3.PlanSnapshot.Get()
        if type(plan) == "table" then
            emit("planGen=" .. tostring(plan.planGen) .. " cacheKey=" .. tostring(plan.cacheKey))
        end
    end
    emit("=== end state ===")
end

function Orch.Initialize()
    if Orch._initialized == true then
        return
    end
    local E = StockPiler3.Events
    local B = StockPiler3.EventBus
    if not B or not E then
        return
    end
    Orch._initialized = true
    TrackBus(B.Subscribe(E.CMD_HARVEST, function()
        Orch.DispatchCommand("harvest", {})
    end))
    TrackBus(B.Subscribe(E.CMD_BREW_PERFORM, function()
        Orch.DispatchCommand("brew.perform", {})
    end))
end

function Orch.Shutdown()
    local B = StockPiler3.EventBus
    local tokens = Orch._busTokens
    if B and B.Unsubscribe and type(tokens) == "table" then
        for i = 1, #tokens do
            B.Unsubscribe(tokens[i])
        end
    end
    Orch._busTokens = nil
    Orch._initialized = false
    Orch.Phase = "idle"
    Orch._brewPhase = nil
    Orch.ClearFillBlocked()
end
