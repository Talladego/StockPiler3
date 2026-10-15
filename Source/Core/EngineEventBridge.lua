----------------------------------------------------------------
-- StockPiler3 Core/EngineEventBridge -- SystemData.Events -> stores
-- Host: StockPiler3Window (WindowRegisterEventHandler).
-- UPDATE_PROCESSED: Perf.OnFrame -> ApplySlots -> snapGen ->
-- LearnBridge -> Refine.OnUpdate -> Scheduler.OnUpdate (Orch due).
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.EngineEventBridge = StockPiler3.EngineEventBridge or {}

local Bridge = StockPiler3.EngineEventBridge

Bridge._registered = false
Bridge._host = "StockPiler3Window"
Bridge._handlers = Bridge._handlers or {}

StockPiler3.FrameCounter = tonumber(StockPiler3.FrameCounter) or 0

local function Events()
    return SystemData and SystemData.Events
end

local function BusFire(name, payload)
    local B = StockPiler3.EventBus
    if B and B.Fire then
        B.Fire(name, payload)
    end
end

local function RequestFooterViaBus(payload)
    local B = StockPiler3.EventBus
    if B and B.FireFooterDirty then
        B.FireFooterDirty(type(payload) == "table" and payload or {})
        return
    end
    if StockPiler3.Ui and StockPiler3.Ui.RequestFooterRefresh then
        StockPiler3.Ui.RequestFooterRefresh()
    end
end

local function HostWindow()
    local host = Bridge._host or "StockPiler3Window"
    if DoesWindowExist and DoesWindowExist(host) then
        return host
    end
    return host
end

local function TrackHandler(eventId, handlerName)
    Bridge._handlers[#Bridge._handlers + 1] = {
        event = eventId,
        handler = handlerName,
    }
end

local function CoalesceSlots(pendingList, pendingSet, updatedSlots)
    if type(updatedSlots) ~= "table" then
        return
    end
    local n = 0
    for _, v in ipairs(updatedSlots) do
        local slot = tonumber(v) or 0
        if slot > 0 and pendingSet[slot] ~= true then
            pendingSet[slot] = true
            pendingList[#pendingList + 1] = slot
            n = n + 1
        end
    end
    if n > 0 then
        return
    end
    for k, v in pairs(updatedSlots) do
        local slot = tonumber(k)
        if slot == nil or slot <= 0 then
            slot = tonumber(v) or 0
        end
        if slot > 0 and pendingSet[slot] ~= true then
            pendingSet[slot] = true
            pendingList[#pendingList + 1] = slot
        end
    end
end

local function ApplyInventorySlots(bagKind, slots, reason)
    local Inv = StockPiler3.Inventory
    if not Inv then
        return
    end
    if type(slots) == "table" and #slots > 0 and Inv.ApplySlotUpdates then
        Inv.ApplySlotUpdates(bagKind, slots, reason)
    elseif Inv.MarkDirty then
        Inv.MarkDirty({ reason = reason, full = true })
    end
end

function Bridge.OnInventoryUpdated(updatedSlots)
    -- Stock DataUtils.ReloadItems sticks itemsDirty; mirror so force reads see it.
    if GameData and GameData.Player then
        GameData.Player.itemsDirty = true
    end
    if DataUtils and type(DataUtils.ReloadItems) == "function" then
        pcall(DataUtils.ReloadItems)
    end
    Bridge._pendingMainSlots = Bridge._pendingMainSlots or {}
    Bridge._pendingMainSlotSet = Bridge._pendingMainSlotSet or {}
    CoalesceSlots(Bridge._pendingMainSlots, Bridge._pendingMainSlotSet, updatedSlots)
    Bridge._pendingMainApply = true
end

function Bridge.OnCraftingSlotUpdated(updatedSlots)
    -- Stock: PLAYER_CRAFTING_SLOT_UPDATED → DataUtils.ReloadCraftingItems (craft bag).
    -- Distinct from PLAYER_INVENTORY_SLOT_UPDATED (main bag). Never route craft here→main.
    if GameData and GameData.Player then
        GameData.Player.craftingItemsDirty = true
    end
    if DataUtils and type(DataUtils.ReloadCraftingItems) == "function" then
        pcall(DataUtils.ReloadCraftingItems)
    end
    Bridge._pendingCraftSlots = Bridge._pendingCraftSlots or {}
    Bridge._pendingCraftSlotSet = Bridge._pendingCraftSlotSet or {}
    CoalesceSlots(Bridge._pendingCraftSlots, Bridge._pendingCraftSlotSet, updatedSlots)
    Bridge._pendingCraftApply = true
    local Grow = StockPiler3.Grow
    local Sch = StockPiler3.Scheduler
    local storm = Sch and Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true
    local quiet = Sch and Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive()
        and Sch and Sch.WakeAutoGrow
        and not storm and not quiet
    then
        Sch.WakeAutoGrow()
    end
end

--- Stock backpack icon view: PLAYER_CRAFTING_INVENTORY_UPDATED (craft bag capacity / full rebuild).
function Bridge.OnCraftingInventoryUpdated()
    if GameData and GameData.Player then
        GameData.Player.craftingItemsDirty = true
    end
    if DataUtils and type(DataUtils.ReloadCraftingItems) == "function" then
        pcall(DataUtils.ReloadCraftingItems)
    end
    local Inv = StockPiler3.Inventory
    if Inv and Inv.ForceFullRefresh then
        Inv.ForceFullRefresh({
            forceEngine = true,
            needQueue = true,
            reason = "engine-crafting-inventory",
        })
    elseif Inv and Inv.MarkDirty then
        Inv.MarkDirty({ reason = "engine-crafting-inventory", full = true, needQueue = true })
    end
end

function Bridge.FlushPendingMainSlots()
    if Bridge._pendingMainApply ~= true then
        return false
    end
    Bridge._pendingMainApply = false
    local slots = Bridge._pendingMainSlots
    Bridge._pendingMainSlots = {}
    Bridge._pendingMainSlotSet = {}
    if StockPiler3.Perf and StockPiler3.Perf.Begin then
        StockPiler3.Perf.Begin("Inv.ApplySlots")
    end
    ApplyInventorySlots("main", slots, "engine-inventory")
    if StockPiler3.Perf and StockPiler3.Perf.End then
        StockPiler3.Perf.End("Inv.ApplySlots")
    end
    return true
end

function Bridge.FlushPendingCraftSlots()
    if Bridge._pendingCraftApply ~= true then
        return false
    end
    Bridge._pendingCraftApply = false
    local slots = Bridge._pendingCraftSlots
    Bridge._pendingCraftSlots = {}
    Bridge._pendingCraftSlotSet = {}
    if StockPiler3.Perf and StockPiler3.Perf.Begin then
        StockPiler3.Perf.Begin("Inv.ApplySlots")
    end
    ApplyInventorySlots("craft", slots, "engine-crafting-slot")
    if StockPiler3.Perf and StockPiler3.Perf.End then
        StockPiler3.Perf.End("Inv.ApplySlots")
    end
    return true
end

function Bridge.OnCraftingUpdated()
    if StockPiler3.LearnBridge and StockPiler3.LearnBridge.OnCraftingUpdated then
        StockPiler3.LearnBridge.OnCraftingUpdated()
    end
    if StockPiler3.Brew and StockPiler3.Brew.OnCraftingUpdated then
        StockPiler3.Brew.OnCraftingUpdated()
    end
    -- Brew.ForceBrewUiRefresh already synced footer/macro this frame.
    local Brew = StockPiler3.Brew
    local frame = tonumber(StockPiler3.FrameCounter) or 0
    if Brew and tonumber(Brew._brewUiForcedFrame) == frame and frame > 0 then
        return
    end
    RequestFooterViaBus({ reason = "crafting-updated" })
end

function Bridge.OnCultivationUpdated()
    if StockPiler3.Perf and StockPiler3.Perf.Begin then
        StockPiler3.Perf.Begin("CultivationUpdated")
    end
    local plotNum = 0
    if GameData and GameData.Player and GameData.Player.Cultivation then
        plotNum = tonumber(GameData.Player.Cultivation.UpdatedIndex) or 0
    end
    -- Harvest macro op-lock: arm storm before Garden dirty fans out so
    -- OnGardenDirty / Watch flush cannot sync Planner.Build this frame.
    local Grow = StockPiler3.Grow
    local Sch = StockPiler3.Scheduler
    -- Always hold Watch paint on cult updates (plot storms pile RefreshWatch).
    if Sch and Sch.SkipUiThisFrame then
        Sch.SkipUiThisFrame()
    end
    if Grow and Grow.IsHarvestOpActive and Grow.IsHarvestOpActive() == true then
        if Sch and Sch.ArmHarvestStorm then
            Sch.ArmHarvestStorm()
        end
        if Sch and Sch.SkipPlanThisFrame then
            Sch.SkipPlanThisFrame()
        end
    end
    if StockPiler3.Garden and StockPiler3.Garden.OnCultivationUpdated then
        StockPiler3.Garden.OnCultivationUpdated(plotNum)
    elseif StockPiler3.Garden and StockPiler3.Garden.SyncAll then
        StockPiler3.Garden.SyncAll()
    end
    if StockPiler3.Grow and StockPiler3.Grow.OnCultivationUpdated then
        StockPiler3.Grow.OnCultivationUpdated(plotNum)
    end
    if StockPiler3.LearnBridge and StockPiler3.LearnBridge.OnCultivationUpdated then
        StockPiler3.LearnBridge.OnCultivationUpdated()
    end
    -- Footer via coalesced flush only — never SyncActionReadiness per plot.
    local storm = Sch and Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true
    local quiet = Sch and Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true
    local settling = Sch and Sch.IsSessionSettling and Sch.IsSessionSettling() == true
    if not storm and not quiet and not settling then
        RequestFooterViaBus({ reason = "cultivation-updated" })
    end
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive()
        and Sch and Sch.WakeAutoGrow
        and not storm and not quiet
    then
        Sch.WakeAutoGrow()
    end
    if StockPiler3.Perf and StockPiler3.Perf.End then
        StockPiler3.Perf.End("CultivationUpdated")
    end
end

function Bridge.OnTradeSkillUpdated()
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.OnTradeSkillPulse then
        Caps.OnTradeSkillPulse()
    elseif Caps and Caps.MarkTradeSkillsReady then
        Caps.MarkTradeSkillsReady()
    end
    local cult = Caps and Caps.GetCultSkill and Caps.GetCultSkill() or 0
    local apo = Caps and Caps.GetApoSkill and Caps.GetApoSkill() or 0
    local levelsHash = Caps and Caps.LevelsHash and Caps.LevelsHash()
        or (tostring(cult) .. ":" .. tostring(apo))
    local prevHash = Bridge._skillLevelsHash
    local hashChanged = prevHash ~= levelsHash
    local firstSkillsReady = Bridge._skillsWereReady ~= true
        and (cult > 0 or apo > 0)
    Bridge._skillLevelsHash = levelsHash
    if cult > 0 or apo > 0 then
        Bridge._skillsWereReady = true
    end
    -- Cult often arrives one TRADE_SKILL_UPDATED before Apo. Scrubbing potion
    -- watches while apo still reads 0 was wiping every marked L1–L200 watch.
    if apo > 0 then
        Bridge._apoSkillSeen = true
    end
    if cult > 0 then
        Bridge._cultSkillSeen = true
    end

    local prev = Bridge._skillPrev
    if type(prev) ~= "table" then
        Bridge._skillPrev = { cult = cult, apo = apo }
        hashChanged = true
    else
        -- Read the previous sample before overwriting it. liveDrop used to see
        -- the new value, so a real drop (200 -> 0) was missed and the next
        -- pulse recorded a +200 skill-up (CORE-3).
        local prevCult = tonumber(prev.cult) or cult
        local prevApo = tonumber(prev.apo) or apo
        local dCult = cult - prevCult
        local dApo = apo - prevApo
        prev.cult = cult
        prev.apo = apo
        -- Logout / char switch: ignore large negative jumps.
        -- Use live reads so sticky cache cannot hide a real char swap.
        local liveCult = Caps and Caps.ReadCultSkillLive and Caps.ReadCultSkillLive() or cult
        local liveApo = Caps and Caps.ReadApoSkillLive and Caps.ReadApoSkillLive() or apo
        local liveDrop = (liveCult <= 0 and prevCult >= 5)
            or (liveApo <= 0 and prevApo >= 5)
        if (dCult <= -5 or dApo <= -5) and liveDrop and Caps and Caps._pendingLoadRefresh == true then
            if Caps.ResetTradeSkillsReady then
                Caps.ResetTradeSkillsReady()
            end
            Bridge._skillsWereReady = false
            Bridge._apoSkillSeen = false
            Bridge._cultSkillSeen = false
            Bridge._skillLevelsHash = nil
            Bridge._skillPrev = nil
            return
        end
        local SkillUp = StockPiler3.SkillUp
        if dCult > 0 and SkillUp and SkillUp.OnCultSkillDelta then
            SkillUp.OnCultSkillDelta(dCult)
        end
        if dApo > 0 and SkillUp and SkillUp.OnApoSkillDelta then
            SkillUp.OnApoSkillDelta(dApo)
        end
    end

    if hashChanged or firstSkillsReady then
        -- Defer over-skill scrub until the skill we need has been observed.
        -- DisableOverSkillWatches itself also no-ops potion/plant sides at 0.
        local canScrub = (Bridge._apoSkillSeen == true) or (Bridge._cultSkillSeen == true)
        if canScrub and StockPiler3.Watch and StockPiler3.Watch.DisableOverSkillWatches then
            StockPiler3.Watch.DisableOverSkillWatches({ notify = firstSkillsReady and apo > 0 })
        end
        -- Skill tier floors change refine eligibility without bag deltas; bust
        -- sticky empty CollectIntents latch (issue #11 / 0.3.256 regression).
        local Refine = StockPiler3.Refine
        if Refine and Refine.InvalidateIntentCache then
            Refine.InvalidateIntentCache()
        end
        if Refine and Refine.MarkRefineDue then
            Refine.MarkRefineDue("skill")
        end
        if StockPiler3.Scheduler and StockPiler3.Scheduler.EnqueuePlanRebuild then
            StockPiler3.Scheduler.EnqueuePlanRebuild()
        end
        if StockPiler3.Ui and StockPiler3.Ui.InvalidateSkillGates then
            StockPiler3.Ui.InvalidateSkillGates()
        end
        if StockPiler3.Ui and StockPiler3.Ui.RefreshCatalogRows then
            StockPiler3.Ui.RefreshCatalogRows()
        end
        RequestFooterViaBus({ reason = "trade-skills" })
        if firstSkillsReady and cult > 0
            and StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoGrow
        then
            StockPiler3.Scheduler.WakeAutoGrow()
        end
        if StockPiler3.Debug and StockPiler3.Debug.LogOp then
            local liveCult = Caps and Caps.ReadCultSkillLive and Caps.ReadCultSkillLive() or cult
            local liveApo = Caps and Caps.ReadApoSkillLive and Caps.ReadApoSkillLive() or apo
            StockPiler3.Debug.LogOp("caps", string.format(
                "trade-skill-updated cult=%d apo=%d live=%d/%d first=%s",
                cult, apo, liveCult, liveApo, tostring(firstSkillsReady)
            ))
        end
    end
end

--- Trainer / interact closed: GameData may update a tick after TRADE_SKILL_UPDATED.
function Bridge.OnInteractDone()
    Bridge.OnTradeSkillUpdated()
end

function Bridge.OnStoreShow()
    if StockPiler3.VendorAdapter then
        if StockPiler3.VendorAdapter.EnsureStoreHook then
            StockPiler3.VendorAdapter.EnsureStoreHook()
        end
        if StockPiler3.VendorAdapter.OnStoreShow then
            StockPiler3.VendorAdapter.OnStoreShow()
        end
    end
    if StockPiler3.Buy and StockPiler3.Buy.OnStoreShow then
        StockPiler3.Buy.OnStoreShow()
    end
    if StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
        StockPiler3.Scheduler.WakeAutoBuy()
    end
end

function Bridge.OnLoadingEnd()
    Bridge._loadingEndSeen = true
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.BeginLoadSkillRefresh then
        Caps.BeginLoadSkillRefresh()
    end
    if Caps and Caps.ResetTradeSkillsReady then
        Caps.ResetTradeSkillsReady()
    end
    Bridge._skillLevelsHash = nil
    Bridge._skillPrev = nil
    Bridge._skillsWereReady = false
    Bridge._apoSkillSeen = false
    Bridge._cultSkillSeen = false
    local Sch = StockPiler3.Scheduler
    -- Defer SyncAll + skip plan/UI this frame so SESSION_LOADED cannot pile
    -- CultivationUpdated x4 with Planner.Build / RefreshWatch (10s hitch).
    if Sch and Sch.SkipPlanThisFrame then
        Sch.SkipPlanThisFrame()
    end
    if Sch and Sch.SkipUiThisFrame then
        Sch.SkipUiThisFrame()
    end
    if StockPiler3.Garden then
        if StockPiler3.Garden.MarkSyncAllDue then
            StockPiler3.Garden.MarkSyncAllDue()
        elseif StockPiler3.Garden._syncAllDue ~= nil then
            StockPiler3.Garden._syncAllDue = true
        elseif StockPiler3.Garden.SyncAll then
            StockPiler3.Garden.SyncAll()
        end
    end
    if StockPiler3.Inventory and StockPiler3.Inventory.ForceFullRefresh then
        StockPiler3.Inventory.ForceFullRefresh()
    elseif StockPiler3.Inventory and StockPiler3.Inventory.MarkDirty then
        StockPiler3.Inventory.MarkDirty({ reason = "loading-end", full = true })
    end
    local E = StockPiler3.Events
    if E and E.SESSION_LOADED then
        BusFire(E.SESSION_LOADED, { reason = "loading-end" })
    end
end

function Bridge.OnCombatFlagUpdated()
    -- Light: combat pause is consulted on Orch plant path; dirty footer readiness only.
    RequestFooterViaBus({ reason = "combat-flag" })
end

local function RunUpdateProcessed(timeElapsed)
    StockPiler3.FrameCounter = (tonumber(StockPiler3.FrameCounter) or 0) + 1

    -- Perf.OnFrame first when in-addon hitch logger (LibPerf sets Available=true).
    local Perf = StockPiler3.Perf
    if Perf and Perf.OnFrame and Perf.Available ~= true then
        Perf.OnFrame(timeElapsed)
    end

    if StockPiler3.Garden and StockPiler3.Garden.FlushPendingSyncAll then
        StockPiler3.Garden.FlushPendingSyncAll()
    end

    -- Coalesced Inv.ApplySlots (main + craft)
    Bridge.FlushPendingMainSlots()
    Bridge.FlushPendingCraftSlots()

    -- Flush pending snapGen
    if StockPiler3.Inventory and StockPiler3.Inventory.FlushPendingSnapGen then
        StockPiler3.Inventory.FlushPendingSnapGen()
    end

    -- LearnBridge drain
    if StockPiler3.LearnBridge and StockPiler3.LearnBridge.OnUpdateProcessed then
        StockPiler3.LearnBridge.OnUpdateProcessed()
    end

    -- Refine OnUpdate
    if StockPiler3.Refine and StockPiler3.Refine.OnUpdateProcessed then
        StockPiler3.Refine.OnUpdateProcessed(timeElapsed)
    elseif StockPiler3.Refine and StockPiler3.Refine.OnUpdate then
        StockPiler3.Refine.OnUpdate(timeElapsed)
    end

    -- Scheduler pump (bag -> FrameWork -> Plan -> Watch UI; Orch tick due)
    if StockPiler3.Scheduler and StockPiler3.Scheduler.OnUpdate then
        StockPiler3.Scheduler.OnUpdate(timeElapsed)
    end

    -- First-open Watch ListBox bind: must run even when Scheduler skips UI.
    if StockPiler3Window and StockPiler3Window.FlushOpenPaint then
        StockPiler3Window.FlushOpenPaint()
    end

    -- Coalesced macro enable sync (footer/cultivation storms).
    if StockPiler3.Macro and StockPiler3.Macro.DrainEnabledSync then
        StockPiler3.Macro.DrainEnabledSync()
    end
    if StockPiler3.Macro and StockPiler3.Macro.DrainEnableReassert then
        StockPiler3.Macro.DrainEnableReassert()
    end
    if StockPiler3.CraftHarvestTimer and StockPiler3.CraftHarvestTimer.OnUpdate then
        StockPiler3.CraftHarvestTimer.OnUpdate(timeElapsed)
    end

    -- Footer after Scheduler so SkipUiHoldFooter can hold this frame.
    local Sch = StockPiler3.Scheduler
    local holdFooter = Sch and Sch.SkipUiHoldFooter and Sch.SkipUiHoldFooter() == true
    if not holdFooter and StockPiler3Window and StockPiler3Window.FlushPendingFooterRefresh then
        StockPiler3Window.FlushPendingFooterRefresh()
    end
    if Sch and Sch.ClearSkipUiHoldFooter then
        Sch.ClearSkipUiHoldFooter()
    end
    -- Deferred tab list repop (SelectTab deferRefresh / OnShow) — SP2 parity.
    if StockPiler3Window and StockPiler3Window.FlushPendingListRepopulate
        and StockPiler3Window._repopulatePending == true
    then
        StockPiler3Window.FlushPendingListRepopulate()
    end
end

function Bridge.OnUpdateProcessed(timeElapsed)
    if Bridge._inUpdate == true then
        return
    end
    Bridge._inUpdate = true
    local ok, err = pcall(RunUpdateProcessed, timeElapsed)
    Bridge._inUpdate = false
    if ok ~= true and StockPiler3.Debug and StockPiler3.Debug.ReportProtectedCallFailure then
        StockPiler3.Debug.ReportProtectedCallFailure("Bridge.OnUpdateProcessed", err, true)
    end
end

local function RegisterOne(ev, eventKey, handlerName)
    local eventId = ev[eventKey]
    if eventId == nil then
        if StockPiler3.Debug and StockPiler3.Debug.LogAlways then
            StockPiler3.Debug.LogAlways("engine bridge skip missing event " .. tostring(eventKey))
        end
        return false
    end
    local host = HostWindow()
    if type(WindowRegisterEventHandler) == "function" then
        WindowRegisterEventHandler(host, eventId, handlerName)
        TrackHandler(eventId, handlerName)
    elseif type(RegisterEventHandler) == "function" then
        RegisterEventHandler(eventId, handlerName)
        TrackHandler(eventId, handlerName)
    else
        return false
    end
    return true
end

function Bridge.Register()
    if Bridge._registered == true then
        return
    end
    local ev = Events()
    if type(ev) ~= "table" then
        return
    end
    Bridge._handlers = {}
    local prefix = "StockPiler3.EngineEventBridge."
    -- Parity with EA_Window_Backpack + DataUtils:
    --   PLAYER_INVENTORY_SLOT_UPDATED → main bag
    --   PLAYER_CRAFTING_SLOT_UPDATED  → craft bag (apo mats)
    --   PLAYER_CRAFTING_INVENTORY_UPDATED → craft bag capacity / full rebuild
    RegisterOne(ev, "PLAYER_INVENTORY_SLOT_UPDATED", prefix .. "OnInventoryUpdated")
    RegisterOne(ev, "PLAYER_CRAFTING_SLOT_UPDATED", prefix .. "OnCraftingSlotUpdated")
    RegisterOne(ev, "PLAYER_CRAFTING_INVENTORY_UPDATED", prefix .. "OnCraftingInventoryUpdated")
    RegisterOne(ev, "PLAYER_CRAFTING_UPDATED", prefix .. "OnCraftingUpdated")
    RegisterOne(ev, "PLAYER_CULTIVATION_UPDATED", prefix .. "OnCultivationUpdated")
    RegisterOne(ev, "TRADE_SKILL_UPDATED", prefix .. "OnTradeSkillUpdated")
    RegisterOne(ev, "INTERACT_DONE", prefix .. "OnInteractDone")
    RegisterOne(ev, "LOADING_END", prefix .. "OnLoadingEnd")
    RegisterOne(ev, "INTERACT_SHOW_STORE", prefix .. "OnStoreShow")
    RegisterOne(ev, "UPDATE_PROCESSED", prefix .. "OnUpdateProcessed")
    RegisterOne(ev, "PLAYER_COMBAT_FLAG_UPDATED", prefix .. "OnCombatFlagUpdated")
    Bridge._registered = true
    if StockPiler3.Debug and StockPiler3.Debug.LogAlways then
        StockPiler3.Debug.LogAlways("init engine event bridge registered")
    end
end

local function LoadingScreenShowing()
    local names = { "EA_Window_LoadingScreen", "LoadingScreen" }
    for i = 1, #names do
        local n = names[i]
        if type(DoesWindowExist) == "function" and DoesWindowExist(n)
            and type(WindowGetShowing) == "function" and WindowGetShowing(n) == true
        then
            return true
        end
    end
    return false
end

--- /reload often fires LOADING_END before this bridge registers; synthesize it
--- once the loading screen is already gone so AutoGrow is not stuck settling.
function Bridge.MaybeCatchUpLoadingEnd()
    if Bridge._loadingEndSeen == true then
        return
    end
    if LoadingScreenShowing() then
        return
    end
    if StockPiler3.Debug and StockPiler3.Debug.LogAlways then
        StockPiler3.Debug.LogAlways("session catch-up loading-end (event missed)")
    end
    Bridge.OnLoadingEnd()
end

function Bridge.Unregister()
    if Bridge._registered ~= true then
        return
    end
    local host = HostWindow()
    local handlers = Bridge._handlers
    if type(handlers) == "table" then
        for i = 1, #handlers do
            local entry = handlers[i]
            if type(entry) == "table" and entry.event ~= nil and entry.handler then
                if type(WindowUnregisterEventHandler) == "function" then
                    WindowUnregisterEventHandler(host, entry.event)
                elseif type(UnregisterEventHandler) == "function" then
                    UnregisterEventHandler(entry.event, entry.handler)
                end
            end
        end
    end
    Bridge._handlers = {}
    Bridge._registered = false
    Bridge._pendingMainApply = false
    Bridge._pendingCraftApply = false
    Bridge._pendingMainSlots = nil
    Bridge._pendingCraftSlots = nil
    Bridge._pendingMainSlotSet = nil
    Bridge._pendingCraftSlotSet = nil
    Bridge._loadingEndSeen = false
end

function Bridge.Initialize()
    Bridge.Register()
end

function Bridge.Shutdown()
    Bridge.Unregister()
end
