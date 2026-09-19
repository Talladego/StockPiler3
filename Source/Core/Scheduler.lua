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
Sch.PLAN_WARM_HOLD_MAX_SEC = 1.0
Sch.AUTO_TICK_SEC = 1.0
Sch.AUTO_TICK_IDLE_SEC = 5.0
Sch.HARVEST_STORM_MIN_SEC = 1.5
Sch.PLANT_QUIET_BASE_SEC = 0.75

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
Sch._initialized = false
Sch._harvestStormUntil = 0
Sch._plantQuietUntil = 0
Sch._skipPlanThisFrame = false
Sch._skipUiThisFrame = false
Sch._skipUiHoldFooter = false
Sch._skipOrchThisFrame = false
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
    local FW = StockPiler3.FrameWork
    if not FW or not FW.StartOnce then
        return
    end
    local snapGen = 0
    if StockPiler3.Inventory and StockPiler3.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler3.Inventory.GetSnapGen()) or 0
    end
    local genKey = tostring(snapGen) .. ":" .. tostring(reason or "")
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

local function FlushBagIfDue()
    if Sch._bagDue ~= true then
        return false
    end
    if Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
        Sch._bagAt = Now() + Sch.BAG_COALESCE_SEC
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
    -- Hold full rebuild until WarmHave prewarm finishes (never publish partial plan).
    if Planner and Planner.CanCheapOrGardenPatch and Planner.CanCheapOrGardenPatch() ~= true then
        local warm = Planner.IsHaveCacheWarmForSnap and Planner.IsHaveCacheWarmForSnap() == true
        if not warm then
            local holdMax = tonumber(Sch.PLAN_WARM_HOLD_MAX_SEC) or 1.0
            local holdStart = tonumber(Sch._planWarmHoldAt) or 0
            if holdStart <= 0 then
                Sch._planWarmHoldAt = Now()
                holdStart = Sch._planWarmHoldAt
            end
            if (Now() - holdStart) < holdMax then
                RequestCachePrewarm("plan-hold-warm")
                return false
            end
        end
    end
    Sch._planWarmHoldAt = 0
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
    -- Snap path: never WakeAutoGrow / ClearFillBlocked (snap-wake storm risk).
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
        if ShouldWakeAutoGrowUrgent() then
            Sch._autoGrowFast = true
        end
    end
    if Refine and Refine.InvalidateBufferFlags then
        Refine.InvalidateBufferFlags()
    end
    Sch.MarkWatchUiDirty()
end

local function OnGardenDirty(payload)
    -- Soft (stage-only) pulses: refresh Watch UI, do not wake AutoGrow / plan rebuild.
    if type(payload) == "table" and payload.soft == true then
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
    Sch.EnqueueBagFlush(true)
    -- Soft Invalidate on mid-session LOADING_END (zone/scenario). Hard Clear only when
    -- character identity changes (or first plan with no prior key) — never serve another
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
        Sch.SkipPlanThisFrame()
        InvalidatePlantQueue("storm-end")
        RequestCachePrewarm("storm-end")
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
    if Sch.IsInventorySideEffectsSuppressed() then
        Sch._pendingPlanAfterSuppress = true
        return
    end
    if Sch._bagDue == true then
        Sch._bagNeedQueue = true
        return
    end
    if nudge == true and Sch._planDue == true and (tonumber(Sch._planAt) or 0) > 0 then
        return
    end
    local now = Now()
    local wait = tonumber(Sch.PLAN_MAX_WAIT_SEC) or 0.5
    if Sch.ShouldWakeAutoGrow and Sch.ShouldWakeAutoGrow() == true and nudge ~= true then
        wait = tonumber(Sch.PLAN_COALESCE_WHEN_AWAKE_SEC) or 3.0
    end
    local at = now + wait
    local minGap = tonumber(Sch.PLAN_MIN_GAP_SEC) or 2.0
    local lastBuilt = tonumber(Sch._lastPlanBuiltAt) or 0
    if lastBuilt > 0 and minGap > 0 then
        local gapAt = lastBuilt + minGap
        if gapAt > at then
            at = gapAt
        end
    end
    Sch._planDue = true
    if Sch._planAt <= 0 then
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
    if Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() == true then
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
    if StockPiler3.Buy and StockPiler3.Buy.PollStorePresence then
        StockPiler3.Buy.PollStorePresence()
    end
    if StockPiler3.Grow and StockPiler3.Grow.ExpireStalePending then
        StockPiler3.Grow.ExpireStalePending()
    end
    if StockPiler3.Brew and StockPiler3.Brew.OnUpdate then
        StockPiler3.Brew.OnUpdate(timeElapsed)
    end
    DecaySuppressInventorySideEffects()
    if Sch.IsHarvestStorm then
        Sch.IsHarvestStorm()
    end
    if Sch.IsPlantQuiet then
        Sch.IsPlantQuiet()
    end

    local didHeavy = false
    if FlushBagIfDue() then
        didHeavy = true
    end
    local brewSession = StockPiler3.Orchestrator
        and StockPiler3.Orchestrator.IsBrewSessionActive
        and StockPiler3.Orchestrator.IsBrewSessionActive() == true
    local skipPump = brewSession
        or Sch._skipPlanThisFrame == true
        or (Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true)
    if not didHeavy and not skipPump
        and StockPiler3.FrameWork and StockPiler3.FrameWork.Pump
        and StockPiler3.FrameWork.Pump() == true
    then
        didHeavy = true
    end
    if not didHeavy and RebuildPlanIfDue() then
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
end
