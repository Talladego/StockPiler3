----------------------------------------------------------------
-- StockPiler3 Core/Scheduler -- coalesce heavy work, frame budgets
-- UPDATE_PROCESSED pump: bag flush -> FrameWork.Pump -> PlanRebuild
-- -> Watch UI (one heavy). Orch tick on interval.
-- Wake vs snap: only wake forces plant-queue invalidate.
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Scheduler = StockPiler3.Scheduler or {}

local Sch = StockPiler3.Scheduler

Sch.BAG_COALESCE_SEC = 2.0
Sch.PLAN_MAX_WAIT_SEC = 0.5
Sch.PLAN_COALESCE_WHEN_AWAKE_SEC = 3.0
Sch.PLAN_MIN_GAP_SEC = 2.0
Sch.PLAN_WARM_HOLD_MAX_SEC = 3.0
Sch.SESSION_SETTLE_SEC = 2.5
-- 75 frames ended settle in ~1.2s at 60fps — AutoGrow planted before LOADING_END.
Sch.SESSION_SETTLE_MIN_FRAMES = 90
Sch.AUTO_TICK_SEC = 1.0
Sch.AUTO_TICK_IDLE_SEC = 5.0
Sch.HARVEST_STORM_MIN_SEC = 1.5
Sch.POLL_SEC = 0.25
-- Cover plant/refine inventory + CultivationUpdated lag (0.75 left WarmHave
-- miss storms between IssueOne and the next orch tick).
Sch.PLANT_QUIET_BASE_SEC = 1.25

Sch._bagDue = false
Sch._bagAt = 0
Sch._bagNeedQueue = false
Sch._planDue = false
Sch._planAt = 0
Sch._lastPlanBuiltAt = 0
Sch._autoAccum = 0
Sch._autoGrowFast = true
Sch._suppressInvTicks = 0
Sch._pendingBagFlushAfterSuppress = false
Sch._pendingBagNeedQueueAfterSuppress = false
Sch._pendingPlanAfterSuppress = false
Sch._pendingPrewarmAfterQuiet = false
Sch._pendingPrewarmReason = nil
Sch._pendingPlanAfterPrewarm = false
Sch._initialized = false
Sch._harvestStormUntil = 0
Sch._plantQuietUntil = 0
Sch._holds = {}
Sch._pollAt = 0
Sch._brewLightAt = 0
Sch._skipPlanThisFrame = false
Sch._skipUiThisFrame = false
Sch._skipUiHoldFooter = false
Sch._skipOrchThisFrame = false
Sch._awaitingSessionLoad = false
Sch._orchDecisionHoldTicks = 0
Sch._heavyWorkFrame = -1
Sch._pendingBufferFlagsRebuild = false
Sch._busTokens = nil

local function Now()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function TrackBus(token)
    if token == nil then
        return
    end
    Sch._busTokens = Sch._busTokens or {}
    Sch._busTokens[#Sch._busTokens + 1] = token
end

local function InvalidatePlantQueue(reason)
    local Grow = StockPiler3.Grow
    if not Grow then
        return
    end
    if Grow.InvalidatePlantQueue then
        Grow.InvalidatePlantQueue(reason)
    elseif Grow.MarkPlantJobDirty then
        Grow.MarkPlantJobDirty(reason)
    end
end

local function RequestCachePrewarm(reason)
    -- Defer prewarm during plant/refine quiet — sync WarmHave.miss under
    -- Inv.ApplySlots was the dominant ~90-100ms trail after every IssueOne.
    if Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
        Sch._pendingPrewarmAfterQuiet = true
        Sch._pendingPrewarmReason = reason
        return
    end
    if Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true then
        Sch._pendingPrewarmAfterQuiet = true
        Sch._pendingPrewarmReason = reason
        return
    end
    local FW = StockPiler3.FrameWork
    if not FW or not FW.StartOnce then
        return
    end
    local snapGen = 0
    if StockPiler3.Inventory and StockPiler3.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler3.Inventory.GetSnapGen()) or 0
    end
    local genKey = tostring(snapGen)
    if FW.EnqueueWarmHave then
        FW.EnqueueWarmHave(genKey)
    end
    if FW.EnqueueDemand then
        FW.EnqueueDemand(genKey)
    end
    if FW.EnqueueSeedLines then
        FW.EnqueueSeedLines(genKey)
    end
end

local function FlushPendingPrewarmAfterQuiet()
    if Sch._pendingPrewarmAfterQuiet ~= true then
        return
    end
    if Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
        return
    end
    if Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true then
        return
    end
    Sch._pendingPrewarmAfterQuiet = false
    local reason = Sch._pendingPrewarmReason or "quiet-end"
    Sch._pendingPrewarmReason = nil
    local Planner = StockPiler3.Planner
    if Planner and Planner.InvalidateHaveCacheAfterQuiet then
        Planner.InvalidateHaveCacheAfterQuiet()
    end
    RequestCachePrewarm(reason)
    -- Rebuild after prewarm finishes — never same frame as quiet-end flush.
    Sch._pendingPlanAfterPrewarm = true
end

--- After quiet/storm prewarm: enqueue one coalesced rebuild when FrameWork is idle.
local function FlushPendingPlanAfterPrewarm()
    if Sch._pendingPlanAfterPrewarm ~= true then
        return false
    end
    if Sch.SkipPlanThisFrameActive and Sch.SkipPlanThisFrameActive() == true then
        return false
    end
    if Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
        return false
    end
    if Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true then
        return false
    end
    local FW = StockPiler3.FrameWork
    if FW and FW.IsPrewarmBusy and FW.IsPrewarmBusy() == true then
        return false
    end
    if FW and FW.Busy and FW.Busy() == true then
        return false
    end
    Sch._pendingPlanAfterPrewarm = false
    if Sch.EnqueuePlanRebuild then
        Sch.EnqueuePlanRebuild({ nudge = true })
    end
    Sch.MarkWatchUiDirty()
    return true
end

local function DecaySuppressInventorySideEffects()
    local n = tonumber(Sch._suppressInvTicks) or 0
    if n <= 0 then
        return
    end
    Sch._suppressInvTicks = n - 1
    if Sch._suppressInvTicks > 0 then
        return
    end
    Sch._suppressInvTicks = 0
    if StockPiler3.Inventory and StockPiler3.Inventory.FlushPendingSnapGen then
        StockPiler3.Inventory.FlushPendingSnapGen()
    end
    local needBag = Sch._pendingBagFlushAfterSuppress == true
    local needQueue = Sch._pendingBagNeedQueueAfterSuppress == true
    local needPlan = Sch._pendingPlanAfterSuppress == true
    Sch._pendingBagFlushAfterSuppress = false
    Sch._pendingBagNeedQueueAfterSuppress = false
    Sch._pendingPlanAfterSuppress = false
    if needBag then
        Sch.EnqueueBagFlush(needQueue)
    elseif needQueue then
        Sch._bagNeedQueue = true
    end
    if needPlan then
        Sch.EnqueuePlanRebuild()
    end
end

--- Idle one-heavy: rebuild BufferFlags after invalidate (never on Orch plant frame).
local function FlushPendingBufferFlagsRebuild(didHeavy)
    if Sch._pendingBufferFlagsRebuild ~= true then
        return false
    end
    if didHeavy == true then
        return false
    end
    if Sch.SkipPlanThisFrameActive and Sch.SkipPlanThisFrameActive() == true then
        return false
    end
    if Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
        return false
    end
    if Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true then
        return false
    end
    local Refine = StockPiler3.Refine
    if not (Refine and Refine.EnsureBufferFlagsNow) then
        Sch._pendingBufferFlagsRebuild = false
        return false
    end
    Sch._pendingBufferFlagsRebuild = false
    Refine.EnsureBufferFlagsNow()
    return true
end

local function FlushBagIfDue()
    if Sch._bagDue ~= true then
        return false
    end
    if Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
        Sch._bagAt = Now() + Sch.BAG_COALESCE_SEC
        return false
    end
    if Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true then
        Sch._bagAt = Now() + Sch.BAG_COALESCE_SEC
        return false
    end
    -- Brew load AddItem storms enqueue flushes; do not Inv.Flush on the same
    -- Update as AdvanceLoadJob (libperf Brew.LoadJob + BagFlush pileup).
    -- Keep _bagDue; do not extend _bagAt so flush runs on the first eligible
    -- Update after the job clears. Load uses live BagAdapter.
    local Brew = StockPiler3.Brew
    if Brew and Brew.IsLoadJobActive and Brew.IsLoadJobActive() then
        return false
    end
    if Now() < (tonumber(Sch._bagAt) or 0) then
        return false
    end
    Sch._bagDue = false
    local needQueue = Sch._bagNeedQueue == true
    Sch._bagNeedQueue = false
    local Inv = StockPiler3.Inventory
    if Inv and Inv.Flush then
        if StockPiler3.Perf and StockPiler3.Perf.Begin then
            StockPiler3.Perf.Begin("BagFlush")
        end
        Inv.Flush({ forceEngine = false })
        if StockPiler3.Perf and StockPiler3.Perf.End then
            StockPiler3.Perf.End("BagFlush")
        end
    end
    if needQueue then
        Sch.EnqueuePlanRebuild()
    end
    RequestCachePrewarm("bag-flush")
    return true
end

local function RebuildPlanIfDue()
    if Sch._planDue ~= true then
        return false
    end
    if Sch._skipPlanThisFrame == true then
        return false
    end
    if Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
        return false
    end
    if Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true then
        return false
    end
    -- Orch probe remounts have; wait for hold to drop before CheapRebuild.
    if Sch.IsOrchDecisionHold and Sch.IsOrchDecisionHold() == true then
        return false
    end
    local Orch = StockPiler3.Orchestrator
    if Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true then
        return false
    end
    local RP = StockPiler3.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        return false
    end
    if Now() < (tonumber(Sch._planAt) or 0) then
        return false
    end
    local Planner = StockPiler3.Planner
    local FW = StockPiler3.FrameWork
    -- Hold full rebuild while FrameWork prewarm is mid-flight (collect/bag/demand/seeds).
    if FW and FW.IsPrewarmBusy and FW.IsPrewarmBusy() == true then
        return false
    end
    if FW and FW.Busy and FW.Busy() == true then
        return false
    end
    -- Hold rebuild until WarmHave finishes — including Cheap/Garden paths.
    -- Snap bumps InvalidateHaveWarm; without this wait CheapRebuild sync-warms
    -- under a remounted cache and stamps stale craftable after the first move.
    local warm = Planner and Planner.IsHaveCacheWarmForSnap
        and Planner.IsHaveCacheWarmForSnap() == true
    if not warm then
        RequestCachePrewarm("plan-hold-warm")
        -- Never cold-build while a prewarm job is still queued after RequestCachePrewarm.
        if FW and FW.IsPrewarmBusy and FW.IsPrewarmBusy() == true then
            return false
        end
        local holdMax = tonumber(Sch.PLAN_WARM_HOLD_MAX_SEC) or 3.0
        local holdStart = tonumber(Sch._planWarmHoldAt) or 0
        if holdStart <= 0 then
            Sch._planWarmHoldAt = Now()
            holdStart = Sch._planWarmHoldAt
        end
        if (Now() - holdStart) < holdMax then
            return false
        end
        -- Hold expired still cold: re-enqueue prewarm and extend hold (avoid sync
        -- Build.WarmHave hitch) up to a few retries, then fall through.
        local retries = tonumber(Sch._planWarmHoldRetries) or 0
        local maxRetries = 2
        if retries < maxRetries then
            Sch._planWarmHoldRetries = retries + 1
            Sch._planWarmHoldAt = Now()
            RequestCachePrewarm("plan-hold-warm-retry")
            if FW and FW.IsPrewarmBusy and FW.IsPrewarmBusy() == true then
                return false
            end
        end
    end
    Sch._planWarmHoldAt = 0
    Sch._planWarmHoldRetries = 0
    Sch._planDue = false
    Sch._planAt = 0
    Sch._lastPlanBuiltAt = Now()
    if Planner and Planner.GetOrBuild then
        if StockPiler3.Perf and StockPiler3.Perf.Begin then
            StockPiler3.Perf.Begin("PlanRebuild")
        end
        Planner.GetOrBuild(true)
        if StockPiler3.Perf and StockPiler3.Perf.End then
            StockPiler3.Perf.End("PlanRebuild")
        end
        -- Never paint Watch on the same frame as a full Build (WarmHave hitch).
        Sch.SkipUiThisFrame()
        Sch.MarkWatchUiDirty()
        return true
    end
    return false
end

local function FlushWatchUiIfDue(didHeavy)
    if didHeavy == true then
        return false
    end
    if Sch._skipUiThisFrame == true then
        return false
    end
    local openPaint = StockPiler3Window and StockPiler3Window._openPaintPending == true
    if not openPaint then
        if Sch.IsSessionSettling and Sch.IsSessionSettling() == true then
            return false
        end
        local FW = StockPiler3.FrameWork
        if FW and FW.IsPrewarmBusy and FW.IsPrewarmBusy() == true then
            return false
        end
        if FW and FW.Busy and FW.Busy() == true then
            return false
        end
    end
    local Ui = StockPiler3.Ui
    if Ui and Ui.FlushWatchUiIfDirty then
        return Ui.FlushWatchUiIfDirty() == true
    end
    return false
end

local function AutoTickIntervalSec()
    if StockPiler3.Buy and StockPiler3.Buy.NeedsTick and StockPiler3.Buy.NeedsTick() == true then
        return Sch.AUTO_TICK_SEC
    end
    local Watch = StockPiler3.Watch
    if Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true then
        local Orch = StockPiler3.Orchestrator
        if Orch and Orch.IsFillBlocked and Orch.IsFillBlocked() == true then
            return Sch.AUTO_TICK_IDLE_SEC
        end
        if Sch._autoGrowFast == true then
            return Sch.AUTO_TICK_SEC
        end
        return Sch.AUTO_TICK_IDLE_SEC
    end
    return Sch.AUTO_TICK_SEC
end

local function ShouldWakeAutoGrowUrgent()
    local Watch = StockPiler3.Watch
    if not Watch or not Watch.IsAutoGrowEnabled or Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    local Grow = StockPiler3.Grow
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive() then
        return true
    end
    local RP = StockPiler3.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() then
        return true
    end
    local Refine = StockPiler3.Refine
    if Refine and Refine._refineDirty == true then
        return true
    end
    if Refine and Refine.PeekCachedBufferPending and Refine.PeekCachedBufferPending() == true then
        return true
    end
    return false
end

local function OnInventorySnapshot()
    -- Every bag snap must re-warm Have before craftable recount. Remount-under-hold
    -- used to leave IsHaveCacheWarm true with stale mat totals after the first move.
    local Planner = StockPiler3.Planner
    if Planner and Planner.InvalidateHaveWarm then
        Planner.InvalidateHaveWarm()
    end
    -- Snap path: avoid full WakeAutoGrow (snap-wake storm risk), but clear a
    -- soft fill-block when empty plots are waiting for bag seeds after refine.
    if StockPiler3.Buy and StockPiler3.Buy.OnInventorySnapshot then
        StockPiler3.Buy.OnInventorySnapshot()
    end
    local Refine = StockPiler3.Refine
    -- Peek cached pending before invalidate so wake does not rebuild BufferFlags.
    local pendingBuffer = Refine and Refine.PeekCachedBufferPending
        and Refine.PeekCachedBufferPending() == true
    local plantQuiet = Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true
    local storm = Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true
    local Orch = StockPiler3.Orchestrator
    local brewSession = Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true
    if not plantQuiet and not storm and not brewSession then
        local Watch = StockPiler3.Watch
        local autoGrowOn = Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true
        local Grow = StockPiler3.Grow
        local hasPlantWork = false
        if autoGrowOn and Grow then
            if Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true then
                hasPlantWork = true
            elseif Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive() == true then
                hasPlantWork = true
            elseif pendingBuffer then
                hasPlantWork = true
            end
        end
        -- Soft dirty only; do not force plant-queue invalidate on snap.
        if hasPlantWork and Grow and Grow.MarkPlantJobDirty then
            Grow.MarkPlantJobDirty("snap")
        end
        if hasPlantWork and Orch and Orch.IsFillBlocked and Orch.IsFillBlocked() == true
            and Orch.ClearFillBlocked
        then
            Orch.ClearFillBlocked()
        end
        if hasPlantWork or ShouldWakeAutoGrowUrgent() then
            Sch._autoGrowFast = true
        end
    end
    -- Do not InvalidateBufferFlags on every snap: BufferFlagsCacheKey includes snapGen,
    -- so the next real read rebuilds on key mismatch. PeekFreshBufferPending treats
    -- stale/nil as unknown (orch falls through to full check).
    -- Craft-bag / inventory spends must recount Watch craftable (paint-only leaves
    -- stale greens after manual apo / buy / harvest). Coalesce via RebuildPlanIfDue;
    -- never WarmHave or PatchWatch inside this handler.
    local RP = StockPiler3.RefinePipeline
    local refineBusy = RP and RP.HasOutstanding and RP.HasOutstanding() == true
    if not plantQuiet and not storm and not brewSession and not refineBusy then
        Sch.EnqueuePlanRebuild({ nudge = true })
    elseif plantQuiet or storm then
        -- Bag moves during quiet/storm: latch rebuild after quiet-end invalidate.
        -- Without this, remounted WarmHave stamps stale craftable and Watch only
        -- catches up on a later stack move.
        Sch._pendingPrewarmAfterQuiet = true
        if Sch._pendingPrewarmReason == nil then
            Sch._pendingPrewarmReason = "snap-during-quiet"
        end
        Sch._pendingPlanAfterPrewarm = true
    end
    Sch.MarkWatchUiDirty()
end

local function OnGardenDirty(payload)
    -- Soft (stage-only) pulses: refresh Watch UI, do not wake AutoGrow / plan rebuild.
    if type(payload) == "table" and payload.soft == true then
        Sch.MarkWatchUiDirty()
        return
    end
    -- Harvest storm / plant quiet / refine outstanding: never WakeAutoGrow /
    -- EnqueuePlanRebuild from garden dirty (SP2 Flatten on plant/refine).
    if Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
        Sch.MarkWatchUiDirty()
        return
    end
    if Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true then
        Sch.MarkWatchUiDirty()
        return
    end
    local RP = StockPiler3.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        Sch.MarkWatchUiDirty()
        return
    end
    if Sch.IsSessionSettling and Sch.IsSessionSettling() == true then
        Sch.MarkWatchUiDirty()
        return
    end
    if Sch.ShouldWakeAutoGrow and Sch.ShouldWakeAutoGrow() == true then
        if Sch._planDue == true then
            Sch._autoGrowFast = true
            return
        end
        Sch.WakeAutoGrow()
        Sch.EnqueuePlanRebuild()
    else
        Sch.MarkWatchUiDirty()
    end
end

local function OnPlanUpdated()
    if StockPiler3.Buy and StockPiler3.Buy.OnPlanUpdated then
        StockPiler3.Buy.OnPlanUpdated()
    end
end

local function OnSessionLoaded()
    Sch._awaitingSessionLoad = false
    if Sch.BeginSessionSettle then
        Sch.BeginSessionSettle()
    end
    Sch.SkipUiThisFrame()
    Sch.EnqueueBagFlush(true)
    -- Drop any plant job picked on empty bags before LOADING_END.
    InvalidatePlantQueue("session-loaded")
    -- Soft Invalidate on mid-session LOADING_END (zone/scenario). Hard Clear only when
    -- character identity changes (or first plan with no prior key) - never serve another
    -- character's stale plan via GetOrBuild(false).
    local charKey = ""
    if StockPiler3.Persistence and StockPiler3.Persistence.GetCharacterKey then
        charKey = tostring(StockPiler3.Persistence.GetCharacterKey() or "")
    elseif StockPiler3.Watch and StockPiler3.Watch.GetCharacterKey then
        charKey = tostring(StockPiler3.Watch.GetCharacterKey() or "")
    end
    local prevKey = tostring(Sch._planSessionCharKey or "")
    local charChanged = charKey ~= "" and prevKey ~= "" and charKey ~= prevKey
    local PS = StockPiler3.PlanSnapshot
    local firstPlan = PS == nil or PS.Get == nil or type(PS.Get()) ~= "table"
    if PS then
        if charChanged or (firstPlan and prevKey == "") then
            if PS.Clear then
                PS.Clear()
            elseif PS.Invalidate then
                PS.Invalidate()
            end
        elseif PS.Invalidate then
            PS.Invalidate()
        elseif PS.Clear then
            PS.Clear()
        end
    end
    if charKey ~= "" then
        Sch._planSessionCharKey = charKey
    end
    Sch.EnqueuePlanRebuild()
    Sch.MarkWatchUiDirty()
end

function Sch.IsInventorySideEffectsSuppressed()
    return (tonumber(Sch._suppressInvTicks) or 0) > 0
end

function Sch.SuppressInventorySideEffects(ticks)
    ticks = tonumber(ticks) or 2
    if ticks < 1 then
        ticks = 1
    end
    local cur = tonumber(Sch._suppressInvTicks) or 0
    if ticks > cur then
        Sch._suppressInvTicks = ticks
    end
end

--- Orch plant/refine probe: remount have/demand instead of WarmHave.miss bag walk.
function Sch.ArmOrchDecisionHold(ticks)
    ticks = tonumber(ticks) or 2
    if ticks < 1 then
        ticks = 1
    end
    local cur = tonumber(Sch._orchDecisionHoldTicks) or 0
    if ticks > cur then
        Sch._orchDecisionHoldTicks = ticks
    end
end

function Sch.IsOrchDecisionHold()
    return (tonumber(Sch._orchDecisionHoldTicks) or 0) > 0
end

local function DecayOrchDecisionHold()
    local n = tonumber(Sch._orchDecisionHoldTicks) or 0
    if n > 0 then
        Sch._orchDecisionHoldTicks = n - 1
        if (tonumber(Sch._orchDecisionHoldTicks) or 0) <= 0 then
            -- Hold end: same Have bust as quiet-end so CheapRebuild cannot trust
            -- remounted mat totals from the probe window.
            local Planner = StockPiler3.Planner
            if Planner and Planner.InvalidateHaveWarm then
                Planner.InvalidateHaveWarm()
            end
            Sch._pendingPrewarmAfterQuiet = true
            if Sch._pendingPrewarmReason == nil then
                Sch._pendingPrewarmReason = "orch-hold-end"
            end
            Sch._pendingPlanAfterPrewarm = true
        end
    end
end

--- Mark BagFlush / PlanRebuild so WarmHave bag phase can defer same frame.
function Sch.NoteHeavyWork()
    Sch._heavyWorkFrame = tonumber(StockPiler3.FrameCounter) or 0
end

function Sch.ShouldDeferWarmHaveBag()
    local frame = tonumber(StockPiler3.FrameCounter) or 0
    if frame > 0 and frame == (tonumber(Sch._heavyWorkFrame) or -1) then
        return true
    end
    return false
end

--- Expose prewarm enqueue for PickPlantCandidate cold-cache path.
function Sch.RequestCachePrewarm(reason)
    return RequestCachePrewarm(reason)
end

function Sch.Hold(reason, seconds)
    reason = tostring(reason or "")
    seconds = tonumber(seconds) or 0
    if reason == "" then
        return
    end
    if type(Sch._holds) ~= "table" then
        Sch._holds = {}
    end
    local untilT = Now() + math.max(0, seconds)
    local cur = tonumber(Sch._holds[reason]) or 0
    if untilT > cur then
        Sch._holds[reason] = untilT
    end
end

function Sch.IsHeld(reason)
    reason = tostring(reason or "")
    local untilT = tonumber(Sch._holds and Sch._holds[reason]) or 0
    if untilT <= 0 then
        return false
    end
    local now = Now()
    if now <= 0 then
        return true
    end
    if now < untilT then
        return true
    end
    Sch._holds[reason] = nil
    return false
end

--- Expire named holds and storm/quiet windows once per frame.
function Sch.Advance(now)
    now = tonumber(now) or Now()
    if Sch.IsHarvestStorm then
        Sch.IsHarvestStorm()
    end
    if Sch.IsPlantQuiet then
        Sch.IsPlantQuiet()
    end
    if type(Sch._holds) == "table" and now > 0 then
        for reason, untilT in pairs(Sch._holds) do
            if (tonumber(untilT) or 0) > 0 and now >= untilT then
                Sch._holds[reason] = nil
            end
        end
    end
end

function Sch.ArmHarvestStorm(seconds)
    seconds = tonumber(seconds) or Sch.HARVEST_STORM_MIN_SEC or 1.5
    local minSec = tonumber(Sch.HARVEST_STORM_MIN_SEC) or 1.5
    if seconds < minSec then
        seconds = minSec
    end
    local untilT = Now() + seconds
    local cur = tonumber(Sch._harvestStormUntil) or 0
    if untilT > cur then
        Sch._harvestStormUntil = untilT
    end
    -- Plant quiet >= storm floor.
    local quietSec = math.max(seconds, minSec)
    local quietUntil = Now() + quietSec
    local curQuiet = tonumber(Sch._plantQuietUntil) or 0
    if quietUntil > curQuiet then
        Sch._plantQuietUntil = quietUntil
    end
    Sch.Hold("harvestStorm", seconds)
    Sch.Hold("plantQuiet", quietSec)
end

function Sch.IsHarvestStorm()
    local untilT = tonumber(Sch._harvestStormUntil) or 0
    if untilT <= 0 then
        return false
    end
    local now = Now()
    if now > 0 and now < untilT then
        return true
    end
    if now >= untilT then
        Sch._harvestStormUntil = 0
        -- Storm end: skip plan+UI this frame; enqueue coalesced rebuild for later.
        -- Do not InvalidatePlantQueue / prewarm here (that piled WarmHave + Build
        -- + Watch flush into the first post-harvest / replant hitch).
        Sch.SkipPlanThisFrame()
        Sch.SkipUiThisFrame()
        if Sch.EnqueuePlanRebuild then
            Sch.EnqueuePlanRebuild({ nudge = true })
        end
        Sch.MarkWatchUiDirty()
        FlushPendingPrewarmAfterQuiet()
    end
    return false
end

function Sch.IsPlantQuiet()
    local untilT = tonumber(Sch._plantQuietUntil) or 0
    if untilT <= 0 then
        return false
    end
    local now = Now()
    if now > 0 and now < untilT then
        return true
    end
    if now >= untilT then
        Sch._plantQuietUntil = 0
        -- Quiet-end: drop remounted have, prewarm, then rebuild (bag moves during
        -- quiet never EnqueuePlanRebuild — without this Watch sits one stack behind).
        Sch.SkipPlanThisFrame()
        Sch.SkipUiThisFrame()
        local Planner = StockPiler3.Planner
        if Planner and Planner.InvalidateHaveCacheAfterQuiet then
            Planner.InvalidateHaveCacheAfterQuiet()
        end
        FlushPendingPrewarmAfterQuiet()
        Sch._pendingPlanAfterPrewarm = true
        Sch.MarkWatchUiDirty()
    end
    return false
end

-- Aliases used by other modules / SP2-shaped call sites.
Sch.IsHarvestStormActive = Sch.IsHarvestStorm
Sch.BeginHarvestStorm = Sch.ArmHarvestStorm

function Sch.ArmPlantQuiet(seconds)
    seconds = tonumber(seconds) or Sch.PLANT_QUIET_BASE_SEC or 0.75
    local minSec = tonumber(Sch.HARVEST_STORM_MIN_SEC) or 1.5
    if Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true and seconds < minSec then
        seconds = minSec
    end
    local untilT = Now() + seconds
    local cur = tonumber(Sch._plantQuietUntil) or 0
    if untilT > cur then
        Sch._plantQuietUntil = untilT
    end
    Sch.Hold("plantQuiet", seconds)
end

function Sch.SkipPlanThisFrame()
    Sch._skipPlanThisFrame = true
end

function Sch.SkipUiThisFrame()
    Sch._skipUiThisFrame = true
    Sch._skipUiHoldFooter = true
end

function Sch.SkipOrchThisFrame()
    Sch._skipOrchThisFrame = true
end

function Sch.SkipPlanThisFrameActive()
    return Sch._skipPlanThisFrame == true
end

function Sch.SkipUiThisFrameActive()
    return Sch._skipUiThisFrame == true
end

--- Hold Watch paint / AutoGrow plant after reload until LOADING_END, then a
--- short window so the first real bag flatten can land.
function Sch.BeginSessionSettle(seconds)
    seconds = tonumber(seconds) or Sch.SESSION_SETTLE_SEC or 2.5
    local untilT = Now() + seconds
    local cur = tonumber(Sch._sessionSettleUntil) or 0
    if untilT > cur then
        Sch._sessionSettleUntil = untilT
    end
    -- Frame-based fallback: GetGameTime can be 0 during early reload.
    local fc = tonumber(StockPiler3.FrameCounter) or 0
    local minFrames = tonumber(Sch.SESSION_SETTLE_MIN_FRAMES) or 90
    local frames = math.max(minFrames, math.floor(seconds * 60))
    local untilFrame = fc + frames
    local curFrame = tonumber(Sch._sessionSettleUntilFrame) or 0
    if untilFrame > curFrame then
        Sch._sessionSettleUntilFrame = untilFrame
    end
end

function Sch.MarkAwaitingSessionLoad()
    Sch._awaitingSessionLoad = true
    Sch.BeginSessionSettle()
end

function Sch.IsSessionSettling()
    -- Addon init /reload fires orch ticks before LOADING_END; bags still empty.
    if Sch._awaitingSessionLoad == true then
        return true
    end
    local fc = tonumber(StockPiler3.FrameCounter) or 0
    local untilFrame = tonumber(Sch._sessionSettleUntilFrame) or 0
    if untilFrame > 0 and fc < untilFrame then
        return true
    end
    if untilFrame > 0 and fc >= untilFrame then
        Sch._sessionSettleUntilFrame = 0
    end
    local untilT = tonumber(Sch._sessionSettleUntil) or 0
    if untilT <= 0 then
        return false
    end
    local now = Now()
    -- now==0: trust frame gate above; clear stale time gate once time is valid.
    if now <= 0 then
        return untilFrame > 0
    end
    if now < untilT then
        return true
    end
    Sch._sessionSettleUntil = 0
    return false
end

function Sch.SkipUiHoldFooter()
    return Sch._skipUiHoldFooter == true
end

function Sch.ClearSkipUiHoldFooter()
    Sch._skipUiHoldFooter = false
end

function Sch.EnqueueBagFlush(needQueue)
    if Sch.IsInventorySideEffectsSuppressed() then
        Sch._pendingBagFlushAfterSuppress = true
        if needQueue == true then
            Sch._pendingBagNeedQueueAfterSuppress = true
        end
        return
    end
    local now = Now()
    if Sch._bagDue == true then
        if needQueue == true then
            Sch._bagNeedQueue = true
        end
        return
    end
    Sch._bagDue = true
    Sch._bagAt = now + Sch.BAG_COALESCE_SEC
    if needQueue == true then
        Sch._bagNeedQueue = true
    end
end

function Sch.EnqueuePlanRebuild(opts)
    opts = type(opts) == "table" and opts or {}
    local nudge = opts.nudge == true
    -- Structural watch mark/clear: fire on next tick; skip AutoGrow 3s coalesce + min-gap.
    local urgent = opts.urgent == true
    if Sch.IsInventorySideEffectsSuppressed() then
        Sch._pendingPlanAfterSuppress = true
        return
    end
    if Sch._bagDue == true then
        Sch._bagNeedQueue = true
        return
    end
    if nudge == true and urgent ~= true and Sch._planDue == true and (tonumber(Sch._planAt) or 0) > 0 then
        return
    end
    local now = Now()
    local wait = 0
    if urgent ~= true then
        wait = tonumber(Sch.PLAN_MAX_WAIT_SEC) or 0.5
        if Sch.ShouldWakeAutoGrow and Sch.ShouldWakeAutoGrow() == true and nudge ~= true then
            wait = tonumber(Sch.PLAN_COALESCE_WHEN_AWAKE_SEC) or 3.0
        end
    end
    local at = now + wait
    if urgent ~= true then
        local minGap = tonumber(Sch.PLAN_MIN_GAP_SEC) or 2.0
        local lastBuilt = tonumber(Sch._lastPlanBuiltAt) or 0
        if lastBuilt > 0 and minGap > 0 then
            local gapAt = lastBuilt + minGap
            if gapAt > at then
                at = gapAt
            end
        end
    end
    Sch._planDue = true
    if Sch._planAt <= 0 or urgent == true then
        Sch._planAt = at
    elseif at > Sch._planAt and nudge ~= true then
        Sch._planAt = at
    end
    if nudge ~= true then
        RequestCachePrewarm("plan-enqueue")
    end
end

function Sch.IsPlanRebuildPending()
    return Sch._planDue == true
end

function Sch.MarkWatchUiDirty()
    local Ui = StockPiler3.Ui
    if Ui and Ui.MarkWatchUiDirty then
        Ui.MarkWatchUiDirty()
    end
end

function Sch.ShouldWakeAutoGrow()
    local Watch = StockPiler3.Watch
    if not Watch or not Watch.IsAutoGrowEnabled or Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    local Grow = StockPiler3.Grow
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive() then
        return true
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
    -- Peek only: HasPendingBufferRefine rebuilds BufferFlags (harvest hitch amplifier).
    if Refine and Refine.PeekCachedBufferPending and Refine.PeekCachedBufferPending() == true then
        return true
    end
    return false
end

--- Intentional wake: clear fill-block + force plant-queue invalidate + fast ticks.
function Sch.WakeAutoGrow()
    local Orch = StockPiler3.Orchestrator
    if Orch and Orch.ClearFillBlocked then
        Orch.ClearFillBlocked()
    end
    local Grow = StockPiler3.Grow
    if Grow and Grow.ClearFillBlocked then
        Grow.ClearFillBlocked()
    end
    InvalidatePlantQueue("wake")
    Sch._autoGrowFast = true
end

function Sch.WakeAutoBuy()
    Sch._autoAccum = math.max(tonumber(Sch._autoAccum) or 0, AutoTickIntervalSec())
end

function Sch.SetAutoGrowIdle(idle)
    Sch._autoGrowFast = idle ~= true
end

function Sch.ShouldDeferAutoGrowPlant()
    local SchSelf = Sch
    if SchSelf.IsSessionSettling and SchSelf.IsSessionSettling() == true then
        return true, "session-settle"
    end
    local Inv = StockPiler3.Inventory
    if Inv and Inv.IsReady and Inv.IsReady() ~= true then
        return true, "inv-not-ready"
    end
    local Watch = StockPiler3.Watch
    if Watch and Watch.IsCombatPauseEnabled and Watch.IsCombatPauseEnabled() ~= true then
        return false, nil
    end
    local player = GameData and GameData.Player
    if type(player) ~= "table" then
        return false, nil
    end
    if player.inCombat == true then
        return true, "combat"
    end
    if player.isInScenario == true then
        return true, "scenario"
    end
    return false, nil
end

function Sch.OnUpdate(timeElapsed)
    local now = Now()
    local pollSec = tonumber(Sch.POLL_SEC) or 0.25
    local pollDue = now <= 0 or (now - (tonumber(Sch._pollAt) or 0) >= pollSec)
    if pollDue then
        Sch._pollAt = now
        if StockPiler3.Buy and StockPiler3.Buy.PollStorePresence then
            StockPiler3.Buy.PollStorePresence()
        end
        if StockPiler3.Grow and StockPiler3.Grow.ExpireStalePending then
            StockPiler3.Grow.ExpireStalePending()
        end
    end
    local Brew = StockPiler3.Brew
    if Brew and Brew.OnUpdate then
        local loadJob = Brew.IsLoadJobActive and Brew.IsLoadJobActive() == true
        if loadJob then
            Brew.OnUpdate(timeElapsed)
        else
            local brewDue = now <= 0 or (now - (tonumber(Sch._brewLightAt) or 0) >= pollSec)
            if brewDue then
                Sch._brewLightAt = now
                Brew.OnUpdate(timeElapsed)
            end
        end
    end
    DecaySuppressInventorySideEffects()
    DecayOrchDecisionHold()
    Sch.Advance(now)

    local didHeavy = false
    if FlushBagIfDue() then
        Sch.NoteHeavyWork()
        didHeavy = true
    end
    local brewSession = StockPiler3.Orchestrator
        and StockPiler3.Orchestrator.IsBrewSessionActive
        and StockPiler3.Orchestrator.IsBrewSessionActive() == true
    local skipPump = brewSession
        or Sch._skipPlanThisFrame == true
        or (Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true)
        or (Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true)
    if not didHeavy and not skipPump
        and StockPiler3.FrameWork and StockPiler3.FrameWork.Pump
        and StockPiler3.FrameWork.Pump() == true
    then
        didHeavy = true
    end
    if not didHeavy and FlushPendingPlanAfterPrewarm() then
        -- Enqueued only; RebuildPlanIfDue may still run this frame if due.
    end
    if not didHeavy and RebuildPlanIfDue() then
        Sch.NoteHeavyWork()
        didHeavy = true
    end
    -- BufferFlags rebuild: idle one-heavy, never on Orch plant / BagFlush frame.
    if not didHeavy and FlushPendingBufferFlagsRebuild(false) then
        didHeavy = true
    end
    Sch._skipPlanThisFrame = false
    FlushWatchUiIfDue(didHeavy)
    Sch._skipUiThisFrame = false

    Sch._autoAccum = (tonumber(Sch._autoAccum) or 0) + (tonumber(timeElapsed) or 0)
    local tickSec = AutoTickIntervalSec()
    if Sch._autoAccum >= tickSec then
        Sch._autoAccum = Sch._autoAccum - tickSec
        if StockPiler3.Refine and StockPiler3.Refine.DecayRefineWaitTicks then
            StockPiler3.Refine.DecayRefineWaitTicks()
        end
        if StockPiler3.Grow and StockPiler3.Grow.DecayPlantWaitTicks then
            StockPiler3.Grow.DecayPlantWaitTicks()
        end
        if StockPiler3.Grow and StockPiler3.Grow.DecayHarvestOpLock then
            StockPiler3.Grow.DecayHarvestOpLock()
        end
        if StockPiler3.Orchestrator and StockPiler3.Orchestrator.DecayFillBlocked then
            StockPiler3.Orchestrator.DecayFillBlocked()
        end
        local skipOrch = Sch._skipOrchThisFrame == true
        Sch._skipOrchThisFrame = false
        -- Skip Orch while brew load job runs (AddItem path). Keep Orch when
        -- phase=loaded with no job so ProbeStuckAutoLoaded still ticks.
        local Brew = StockPiler3.Brew
        if Brew and Brew.IsLoadJobActive and Brew.IsLoadJobActive() then
            skipOrch = true
        end
        if not didHeavy and not skipOrch
            and StockPiler3.Orchestrator and StockPiler3.Orchestrator.Tick
        then
            StockPiler3.Orchestrator.Tick()
        end
    else
        Sch._skipOrchThisFrame = false
    end
end

function Sch.Initialize()
    if Sch._initialized == true then
        return
    end
    Sch._initialized = true
    local E = StockPiler3.Events
    local B = StockPiler3.EventBus
    if not (B and E) then
        return
    end
    TrackBus(B.Subscribe(E.INVENTORY_SNAPSHOT, OnInventorySnapshot))
    TrackBus(B.Subscribe(E.GARDEN_DIRTY, OnGardenDirty))
    TrackBus(B.Subscribe(E.SESSION_LOADED, OnSessionLoaded))
    if E.PLAN_UPDATED then
        TrackBus(B.Subscribe(E.PLAN_UPDATED, OnPlanUpdated))
    end
end

function Sch.Shutdown()
    local B = StockPiler3.EventBus
    local tokens = Sch._busTokens
    if B and B.Unsubscribe and type(tokens) == "table" then
        for i = 1, #tokens do
            B.Unsubscribe(tokens[i])
        end
    end
    Sch._busTokens = nil
    Sch._initialized = false
    Sch._bagDue = false
    Sch._planDue = false
    Sch._harvestStormUntil = 0
    Sch._plantQuietUntil = 0
    Sch._pendingPrewarmAfterQuiet = false
    Sch._pendingPrewarmReason = nil
    Sch._pendingPlanAfterPrewarm = false
    Sch._orchDecisionHoldTicks = 0
    Sch._awaitingSessionLoad = false
    Sch._heavyWorkFrame = -1
    Sch._pendingBufferFlagsRebuild = false
    Sch._holds = {}
    Sch._pollAt = 0
    Sch._brewLightAt = 0
end
