----------------------------------------------------------------
-- StockPiler3 Stores/PlanSnapshotStore - cached planner output
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.PlanSnapshot = StockPiler3.PlanSnapshot or {}
local PS = StockPiler3.PlanSnapshot

PS._plan = nil
PS._cacheKey = nil

local function FireInvalidated()
    local B = StockPiler3.EventBus
    local E = StockPiler3.Events
    if B and E and E.PLAN_INVALIDATED then
        B.Fire(E.PLAN_INVALIDATED, {})
    end
end

local function FireUpdated()
    local B = StockPiler3.EventBus
    local E = StockPiler3.Events
    if B and E and E.PLAN_UPDATED then
        B.Fire(E.PLAN_UPDATED, { hasPlan = type(PS._plan) == "table" })
    end
end

function PS.Get()
    return PS._plan
end

function PS.Set(plan, cacheKey)
    PS._plan = plan
    PS._cacheKey = cacheKey
    FireUpdated()
end

function PS.GetCacheKey()
    return PS._cacheKey
end

--- Soft invalidate: drop cache key, keep stale plan for UI / GetOrBuild(false).
function PS.Invalidate()
    PS._cacheKey = nil
    FireInvalidated()
end

--- Hard clear: drop plan (character / session change only).
function PS.Clear()
    PS._plan = nil
    PS._cacheKey = nil
    FireInvalidated()
end

--- Never sync-build while a coalesced rebuild is pending.
--- GetOrBuild(false) / {refresh=false}: return stale only (may nudge enqueue).
--- GetOrBuild() / true / {refresh=true}: build when Planner exists and not pending.
function PS.GetOrBuild(refresh)
    local opts = {}
    local wantRefresh = true
    if refresh == false then
        wantRefresh = false
    elseif type(refresh) == "table" then
        opts = refresh
        if opts.refresh == false then
            wantRefresh = false
        end
        if opts.force == true then
            wantRefresh = true
        end
    elseif refresh == true then
        wantRefresh = true
    end

    local Sch = StockPiler3.Scheduler
    local pending = Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true

    -- Pending rebuild: never sync-build; serve last plan (or nil).
    if pending then
        return PS._plan
    end

    if not wantRefresh then
        if Sch and Sch.EnqueuePlanRebuild and type(PS._plan) == "table" then
            -- Stale with key mismatch: nudge only; do not Build here.
            if PS._cacheKey == nil and Sch.EnqueuePlanRebuild then
                Sch.EnqueuePlanRebuild({ nudge = true })
            end
        elseif Sch and Sch.EnqueuePlanRebuild then
            Sch.EnqueuePlanRebuild({ nudge = true })
        end
        return PS._plan
    end

    local Planner = StockPiler3.Planner
    if Planner and type(Planner.Build) == "function" then
        local plan = Planner.Build(opts)
        if type(plan) == "table" then
            local key = nil
            if Planner.CacheKeyFromGens then
                key = Planner.CacheKeyFromGens()
            end
            PS.Set(plan, key)
            return plan
        end
    end

    return PS._plan
end
