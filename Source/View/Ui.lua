----------------------------------------------------------------
-- StockPiler3 View/Ui -- window show/hide + coalesced Watch flush
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Ui = StockPiler3.Ui or {}
local Ui = StockPiler3.Ui

local function T(key, tokens)
    return StockPiler3.Util.T(key, tokens)
end

Ui.WATCH_UI_MIN_INTERVAL_SEC = 5.0
Ui.BREW_WATCH_CATCHUP_SEC = 1.0
Ui._watchUiDirty = false
Ui._watchUiFlushedAt = 0
Ui._watchUiBrewCatchupAt = 0
Ui._watchUiLastKey = nil
Ui._watchUiLastKnowledgeGen = 0
Ui._watchUiLastPlanGen = 0
Ui._watchUiLastBrewKey = nil

function Ui.Print(msg)
    if StockPiler3.Debug and StockPiler3.Debug.Print then
        StockPiler3.Debug.Print(msg)
    end
end

function Ui.ToggleWindow()
    if not DoesWindowExist("StockPiler3Window") then
        Ui.Print(T("ui.window_missing"))
        return
    end
    if WindowUtils and WindowUtils.ToggleShowing then
        WindowUtils.ToggleShowing("StockPiler3Window")
        return
    end
    local showing = WindowGetShowing("StockPiler3Window") == true
    WindowSetShowing("StockPiler3Window", not showing)
end

function Ui.ShowWindow(tabId)
    if not DoesWindowExist("StockPiler3Window") then
        return
    end
    WindowSetShowing("StockPiler3Window", true)
    if tabId and StockPiler3Window and StockPiler3Window.SelectTab then
        StockPiler3Window.SelectTab(tabId)
    end
end

local function CurrentPlanGen()
    if StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Get then
        local plan = StockPiler3.PlanSnapshot.Get()
        if type(plan) == "table" then
            return tonumber(plan.planGen) or 0
        end
    end
    return 0
end

local function BrewChromeKey()
    local Brew = StockPiler3.Brew
    if not Brew or not Brew.GetSession then
        return "idle"
    end
    local session = Brew.GetSession()
    if type(session) ~= "table" then
        return "idle"
    end
    return tostring(session.phase or "idle")
        .. ":" .. tostring(session.potionRecipeKey or session.potionKey or "")
        .. ":" .. tostring(session.rowId or "")
        .. ":" .. tostring(Brew._loadSource or "")
end

local function WatchContentKey()
    local snapGen = 0
    if StockPiler3.Inventory and StockPiler3.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler3.Inventory.GetSnapGen()) or 0
    end
    local planGen = CurrentPlanGen()
    local knowledgeGen = 0
    if StockPiler3.Knowledge and StockPiler3.Knowledge.GetGen then
        knowledgeGen = tonumber(StockPiler3.Knowledge.GetGen()) or 0
    end
    local watchGen = 0
    if StockPiler3.Watch and StockPiler3.Watch.GetGen then
        watchGen = tonumber(StockPiler3.Watch.GetGen()) or 0
    end
    local autoGrowOn = false
    if StockPiler3.Watch and StockPiler3.Watch.IsAutoGrowEnabled then
        autoGrowOn = StockPiler3.Watch.IsAutoGrowEnabled() == true
    end
    return tostring(snapGen)
        .. ":" .. tostring(planGen)
        .. ":" .. tostring(knowledgeGen)
        .. ":" .. tostring(watchGen)
        .. ":" .. tostring(autoGrowOn)
        .. ":" .. BrewChromeKey()
end

local function IsWatchPlanStale()
    local Sch = StockPiler3.Scheduler
    if Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true then
        return true
    end
    local Planner = StockPiler3.Planner
    if not Planner or not Planner.CacheKeyFromGens then
        return false
    end
    local wantKey = Planner.CacheKeyFromGens()
    local plan = StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Get and StockPiler3.PlanSnapshot.Get()
    if type(plan) ~= "table" then
        return false
    end
    return tostring(plan.cacheKey or "") ~= tostring(wantKey or "")
end

--- Hold Watch paint during harvest storm, refine outstanding, buffer refine, or AutoBuy visit.
local function ShouldDeferWatchFlush()
    local Sch = StockPiler3.Scheduler
    if Sch and Sch.SkipUiThisFrameActive and Sch.SkipUiThisFrameActive() == true then
        return true
    end
    if Sch and Sch._skipUiThisFrame == true then
        return true
    end
    if Sch and Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
        return true
    end
    if Sch and Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true then
        return true
    end
    local RP = StockPiler3.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        return true
    end
    -- Peek only: HasPendingBufferRefine rebuilds BufferFlags after every snap invalidate.
    local Refine = StockPiler3.Refine
    if Refine and Refine.PeekCachedBufferPending and Refine.PeekCachedBufferPending() == true then
        return true
    end
    local Buy = StockPiler3.Buy
    local VA = StockPiler3.VendorAdapter
    if Buy and Buy.IsEnabled and Buy.IsEnabled() == true
        and VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
    then
        return true
    end
    return false
end

function Ui.ClearWatchTipCaches()
    if StockPiler3TabWatch then
        StockPiler3TabWatch._statusTipCache = nil
        StockPiler3TabWatch._seedBufferTipCache = nil
    end
end

function Ui.MarkWatchUiDirty()
    Ui._watchUiDirty = true
end

function Ui.RequestFooterRefresh()
    if StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
        StockPiler3Window.RequestFooterRefresh()
    end
end

function Ui.RefreshIfOpen(opts)
    opts = type(opts) == "table" and opts or {}
    if opts.force ~= true then
        Ui.MarkWatchUiDirty()
        return
    end
    if DoesWindowExist("StockPiler3Window")
        and WindowGetShowing("StockPiler3Window") == true
        and StockPiler3Window
        and StockPiler3Window.RefreshActiveTab
    then
        StockPiler3Window.RefreshActiveTab()
    end
end

function Ui.FlushWatchUiIfDirty()
    if Ui._watchUiDirty ~= true then
        return
    end
    local windowOpen = DoesWindowExist("StockPiler3Window")
        and WindowGetShowing("StockPiler3Window") == true
    -- Ready wake must run even while AutoBuy visit defers full Watch paint
    -- (flask fills clear Shared/Buy-flasks without a potion craftable delta).
    local function WakeReadyFromLiveStatus()
        if StockPiler3.Planner and StockPiler3.Planner.SyncLiveStatusClosedWindow then
            StockPiler3.Planner.SyncLiveStatusClosedWindow()
        elseif StockPiler3.Brew and StockPiler3.Brew.SyncLiveStatusClosedWindow then
            StockPiler3.Brew.SyncLiveStatusClosedWindow()
        end
        if StockPiler3.Brew and StockPiler3.Brew.MaybeNotifyBrewReady then
            StockPiler3.Brew.MaybeNotifyBrewReady()
        end
    end
    if not windowOpen then
        WakeReadyFromLiveStatus()
        if ShouldDeferWatchFlush() then
            return
        end
        -- Closed-window: Ready wake done; keep dirty for next open paint.
        return
    end
    if ShouldDeferWatchFlush() then
        WakeReadyFromLiveStatus()
        return
    end

    local Orch = StockPiler3.Orchestrator
    local brewSessionActive = Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true
    -- Mid-brew: hold full RefreshWatch; chrome via ForceBrewUiRefresh; ~1s Stock/Status catch-up.
    if brewSessionActive then
        local brewKey = BrewChromeKey()
        local brewChanged = brewKey ~= tostring(Ui._watchUiLastBrewKey or "")
        local now = 0
        if type(GetGameTime) == "function" then
            now = tonumber(GetGameTime()) or 0
        end
        if brewChanged then
            Ui._watchUiLastBrewKey = brewKey
            if StockPiler3TabWatch and StockPiler3TabWatch.UpdateRows then
                StockPiler3TabWatch.UpdateRows()
            end
            -- Keep dirty so a full flush runs when the session ends.
            return
        end
        local catchupSec = tonumber(Ui.BREW_WATCH_CATCHUP_SEC) or 1.0
        local lastCatchup = tonumber(Ui._watchUiBrewCatchupAt) or 0
        if lastCatchup > 0 and (now - lastCatchup) < catchupSec then
            return
        end
        Ui._watchUiBrewCatchupAt = now
        local listData = StockPiler3TabWatch and StockPiler3TabWatch.listData
        if type(listData) == "table"
            and #listData > 0
            and StockPiler3.Planner
            and StockPiler3.Planner.PatchWatchRowsLiveCounts
        then
            if StockPiler3.Perf and StockPiler3.Perf.Begin then
                StockPiler3.Perf.Begin("UiFlush.BrewCatchup")
            end
            StockPiler3.Planner.PatchWatchRowsLiveCounts(listData, {
                allowWarmHave = false,
                syncSnapshot = false,
                recountCraftable = false,
            })
            if StockPiler3TabWatch.UpdateRows then
                StockPiler3TabWatch.UpdateRows()
            end
            if StockPiler3.Perf and StockPiler3.Perf.End then
                StockPiler3.Perf.End("UiFlush.BrewCatchup")
            end
        end
        -- Keep dirty for post-session full Watch refresh.
        return
    end

    local knowledgeGen = 0
    if StockPiler3.Knowledge and StockPiler3.Knowledge.GetGen then
        knowledgeGen = tonumber(StockPiler3.Knowledge.GetGen()) or 0
    end
    local planGen = CurrentPlanGen()
    local brewKey = BrewChromeKey()
    local contentKey = WatchContentKey()
    local planChanged = planGen ~= (tonumber(Ui._watchUiLastPlanGen) or 0)
    -- Plan status can change without stock/craftable deltas; never skip when planGen moved.
    if Ui._watchUiLastKey == contentKey and not planChanged then
        Ui._watchUiDirty = false
        return
    end
    local now = 0
    if type(GetGameTime) == "function" then
        now = tonumber(GetGameTime()) or 0
    end
    local last = tonumber(Ui._watchUiFlushedAt) or 0
    local knowledgeChanged = knowledgeGen ~= (tonumber(Ui._watchUiLastKnowledgeGen) or 0)
    local brewChanged = brewKey ~= tostring(Ui._watchUiLastBrewKey or "")
    local interval = Ui.WATCH_UI_MIN_INTERVAL_SEC
    if not knowledgeChanged and not planChanged and not brewChanged and IsWatchPlanStale() then
        interval = math.min(interval, 1.0)
    end
    if not knowledgeChanged
        and not planChanged
        and not brewChanged
        and last > 0
        and (now - last) < interval
    then
        return
    end

    if StockPiler3.Perf and StockPiler3.Perf.Begin then
        StockPiler3.Perf.Begin("UiFlush")
    end
    Ui._watchUiDirty = false
    Ui._watchUiFlushedAt = now
    Ui._watchUiBrewCatchupAt = 0
    Ui._watchUiLastKey = contentKey
    Ui._watchUiLastKnowledgeGen = knowledgeGen
    Ui._watchUiLastPlanGen = planGen
    Ui._watchUiLastBrewKey = brewKey
    if StockPiler3Window and StockPiler3Window.RefreshActiveTab then
        StockPiler3Window.RefreshActiveTab()
    end
    if StockPiler3.Perf and StockPiler3.Perf.End then
        StockPiler3.Perf.End("UiFlush")
    end
    return true
end

function Ui.InitializeWindow()
    if StockPiler3Window and StockPiler3Window.Initialize then
        StockPiler3Window.Initialize()
    end
end

function Ui.RegisterEventRefresh()
    if Ui._eventsRegistered == true then
        return
    end
    local B = StockPiler3.EventBus
    local E = StockPiler3.Events
    if not B or not E then
        return
    end
    Ui._busTokens = Ui._busTokens or {}
    local tokens = Ui._busTokens
    local function track(token)
        if token then
            tokens[#tokens + 1] = token
        end
    end
    local function markDirty()
        Ui.MarkWatchUiDirty()
    end
    track(B.Subscribe(E.PLAN_UPDATED, function()
        Ui.ClearWatchTipCaches()
        Ui.MarkWatchUiDirty()
    end))
    track(B.Subscribe(E.PLAN_INVALIDATED, markDirty))
    track(B.Subscribe(E.INVENTORY_SNAPSHOT, markDirty))
    track(B.Subscribe(E.GARDEN_SNAPSHOT, markDirty))
    if E.KNOWLEDGE_UPDATED then
        track(B.Subscribe(E.KNOWLEDGE_UPDATED, function()
            -- Knowledge can land after an inventory flush already painted Potions.
            -- Bypass Watch throttle and refresh the active tab (Potions or Watch).
            Ui._watchUiLastKey = nil
            Ui._watchUiLastKnowledgeGen = 0
            Ui._watchUiFlushedAt = 0
            Ui.MarkWatchUiDirty()
            if DoesWindowExist("StockPiler3Window")
                and WindowGetShowing("StockPiler3Window") == true
                and StockPiler3Window
                and StockPiler3Window.RefreshActiveTab
            then
                StockPiler3Window.RefreshActiveTab()
            end
        end))
    end
    if E.SESSION_LOADED then
        track(B.Subscribe(E.SESSION_LOADED, function()
            if StockPiler3TabWatch and StockPiler3TabWatch.RefreshSkillGates then
                StockPiler3TabWatch.RefreshSkillGates()
            end
            -- Session load: force refresh so stock/status are not stale until tab flip.
            Ui._watchUiLastKey = nil
            Ui._watchUiLastBrewKey = nil
            Ui._watchUiFlushedAt = 0
            Ui._watchUiLastPlanGen = 0
            Ui._watchUiLastKnowledgeGen = 0
            Ui.ClearWatchTipCaches()
            Ui.MarkWatchUiDirty()
            if DoesWindowExist("StockPiler3Window")
                and WindowGetShowing("StockPiler3Window") == true
                and StockPiler3Window
                and StockPiler3Window.RefreshActiveTab
            then
                StockPiler3Window.RefreshActiveTab()
            end
        end))
    end
    Ui._eventsRegistered = true
end

function Ui.UnregisterEventRefresh()
    local B = StockPiler3.EventBus
    local tokens = Ui._busTokens
    if B and B.Unsubscribe and type(tokens) == "table" then
        for i = 1, #tokens do
            B.Unsubscribe(tokens[i])
        end
    end
    Ui._busTokens = nil
    Ui._eventsRegistered = false
end
