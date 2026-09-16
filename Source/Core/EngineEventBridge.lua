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
    Bridge._pendingMainSlots = Bridge._pendingMainSlots or {}
    Bridge._pendingMainSlotSet = Bridge._pendingMainSlotSet or {}
    CoalesceSlots(Bridge._pendingMainSlots, Bridge._pendingMainSlotSet, updatedSlots)
    Bridge._pendingMainApply = true
end

function Bridge.OnCraftingSlotUpdated(updatedSlots)
    Bridge._pendingCraftSlots = Bridge._pendingCraftSlots or {}
    Bridge._pendingCraftSlotSet = Bridge._pendingCraftSlotSet or {}
    CoalesceSlots(Bridge._pendingCraftSlots, Bridge._pendingCraftSlotSet, updatedSlots)
    Bridge._pendingCraftApply = true
    local Grow = StockPiler3.Grow
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive()
        and StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoGrow
    then
        StockPiler3.Scheduler.WakeAutoGrow()
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
    if StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
        StockPiler3Window.RequestFooterRefresh()
    end
end

function Bridge.OnCultivationUpdated()
    if StockPiler3.Perf and StockPiler3.Perf.Begin then
        StockPiler3.Perf.Begin("CultivationUpdated")
    end
    local plotNum = 0
    if GameData and GameData.Player and GameData.Player.Cultivation then
        plotNum = tonumber(GameData.Player.Cultivation.UpdatedIndex) or 0
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
    if StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
        StockPiler3Window.RequestFooterRefresh()
    end
    local Grow = StockPiler3.Grow
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive()
        and StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoGrow
    then
        StockPiler3.Scheduler.WakeAutoGrow()
    end
    if StockPiler3.Perf and StockPiler3.Perf.End then
        StockPiler3.Perf.End("CultivationUpdated")
    end
end

function Bridge.OnTradeSkillUpdated()
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.MarkTradeSkillsReady then
        Caps.MarkTradeSkillsReady()
    end
    if StockPiler3.Scheduler and StockPiler3.Scheduler.EnqueuePlanRebuild then
        StockPiler3.Scheduler.EnqueuePlanRebuild()
    end
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
    if StockPiler3.TradeSkillCaps and StockPiler3.TradeSkillCaps.ResetTradeSkillsReady then
        StockPiler3.TradeSkillCaps.ResetTradeSkillsReady()
    end
    if StockPiler3.Garden and StockPiler3.Garden.SyncAll then
        StockPiler3.Garden.SyncAll()
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
    if StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
        StockPiler3Window.RequestFooterRefresh()
    end
end

function Bridge.OnUpdateProcessed(timeElapsed)
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

    -- Coalesced macro enable sync (footer/cultivation storms).
    if StockPiler3.Macro and StockPiler3.Macro.DrainEnabledSync then
        StockPiler3.Macro.DrainEnabledSync()
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
end

local function RegisterOne(ev, eventKey, handlerName)
    local eventId = ev[eventKey]
    if eventId == nil then
        return
    end
    local host = HostWindow()
    if type(WindowRegisterEventHandler) == "function" then
        WindowRegisterEventHandler(host, eventId, handlerName)
        TrackHandler(eventId, handlerName)
    elseif type(RegisterEventHandler) == "function" then
        RegisterEventHandler(eventId, handlerName)
        TrackHandler(eventId, handlerName)
    end
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
    RegisterOne(ev, "PLAYER_INVENTORY_SLOT_UPDATED", prefix .. "OnInventoryUpdated")
    RegisterOne(ev, "PLAYER_CRAFTING_SLOT_UPDATED", prefix .. "OnCraftingSlotUpdated")
    RegisterOne(ev, "PLAYER_CRAFTING_UPDATED", prefix .. "OnCraftingUpdated")
    RegisterOne(ev, "PLAYER_CULTIVATION_UPDATED", prefix .. "OnCultivationUpdated")
    RegisterOne(ev, "TRADE_SKILL_UPDATED", prefix .. "OnTradeSkillUpdated")
    RegisterOne(ev, "LOADING_END", prefix .. "OnLoadingEnd")
    RegisterOne(ev, "INTERACT_SHOW_STORE", prefix .. "OnStoreShow")
    RegisterOne(ev, "UPDATE_PROCESSED", prefix .. "OnUpdateProcessed")
    RegisterOne(ev, "PLAYER_COMBAT_FLAG_UPDATED", prefix .. "OnCombatFlagUpdated")
    Bridge._registered = true
    if StockPiler3.Debug and StockPiler3.Debug.LogAlways then
        StockPiler3.Debug.LogAlways("init engine event bridge registered")
    end
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
end

function Bridge.Initialize()
    Bridge.Register()
end

function Bridge.Shutdown()
    Bridge.Unregister()
end
