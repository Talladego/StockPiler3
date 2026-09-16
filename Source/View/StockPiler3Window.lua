----------------------------------------------------------------
-- StockPiler3Window -- settings-style chrome
----------------------------------------------------------------

StockPiler3Window = {}

local function T(key, tokens)
    if StockPiler3.T then
        return StockPiler3.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

StockPiler3Window.TABS_POTIONS = 1
StockPiler3Window.TABS_WATCH = 2
StockPiler3Window.TABS_MAX = 2
StockPiler3Window.SelectedTab = StockPiler3Window.TABS_POTIONS

local CLEAR_WATCHES_WIN = "StockPiler3WindowClearWatches"
local HARVEST_WIN = "StockPiler3WindowHarvest"
local BREW_WIN = "StockPiler3WindowBrew"

StockPiler3Window.Tabs = {
    [1] = {
        window = "SP3TabPotions",
        name = "StockPiler3WindowTabButtonsPotions",
        labelKey = "ui.tab_potions",
        refresh = function()
            if StockPiler3TabPotions and StockPiler3TabPotions.Refresh then
                StockPiler3TabPotions.Refresh()
            end
        end,
    },
    [2] = {
        window = "SP3TabWatch",
        name = "StockPiler3WindowTabButtonsWatch",
        labelKey = "ui.tab_watch",
        refresh = function()
            if StockPiler3TabWatch and StockPiler3TabWatch.Refresh then
                StockPiler3TabWatch.Refresh()
            end
        end,
    },
}

function StockPiler3Window.OnInitialize()
    local selected = StockPiler3Window.SelectedTab or StockPiler3Window.TABS_POTIONS
    for index, tab in ipairs(StockPiler3Window.Tabs) do
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, index == selected)
        end
        if DoesWindowExist(tab.name) then
            ButtonSetPressedFlag(tab.name, index == selected)
        end
    end
end

function StockPiler3Window.RequestFooterRefresh()
    StockPiler3Window._footerRefreshPending = true
end

--- Sync Harvest/Brew readiness: macros always; footer chrome only when window is open.
function StockPiler3Window.SyncActionReadiness(opts)
    opts = type(opts) == "table" and opts or {}
    local immediate = opts.immediate == true
    local Perf = StockPiler3.Perf

    local windowOpen = DoesWindowExist("StockPiler3Window")
        and WindowGetShowing("StockPiler3Window") == true
    local onWatch = StockPiler3Window.SelectedTab == StockPiler3Window.TABS_WATCH
    local onPotions = StockPiler3Window.SelectedTab == StockPiler3Window.TABS_POTIONS

    local canHarvest = StockPiler3.Grow and StockPiler3.Grow.CanHarvestNow
        and StockPiler3.Grow.CanHarvestNow() == true
    local canBrew = StockPiler3.Brew and StockPiler3.Brew.CanBrewNow
        and StockPiler3.Brew.CanBrewNow() == true
    local enabledWatches = 0
    if StockPiler3.Watch and StockPiler3.Watch.CountEnabled then
        enabledWatches = tonumber(StockPiler3.Watch.CountEnabled()) or 0
    end
    local canClearWatches = enabledWatches > 0

    local appearanceKey = tostring(canHarvest) .. ":" .. tostring(canBrew) .. ":" .. tostring(canClearWatches)
    local unchanged = StockPiler3Window._footerWindowOpen == windowOpen
        and StockPiler3Window._footerOnWatch == onWatch
        and StockPiler3Window._footerOnPotions == onPotions
        and StockPiler3Window._footerCanHarvest == canHarvest
        and StockPiler3Window._footerCanBrew == canBrew
        and StockPiler3Window._footerCanClearWatches == canClearWatches
    -- `immediate` must re-apply macro tint: ActionButton.UpdateEnabledState greys
    -- our macros mid-craft while CanBrewNow can stay true, so appearanceKey is unchanged.
    if unchanged and not immediate then
        if StockPiler3.Macro == nil
            or StockPiler3.Macro._lastAppearanceKey == nil
            or StockPiler3.Macro._lastAppearanceKey == appearanceKey
        then
            return canHarvest, canBrew
        end
    end

    if Perf and Perf.Begin then
        Perf.Begin("Footer")
    end

    if windowOpen then
        if DoesWindowExist(CLEAR_WATCHES_WIN) then
            WindowSetShowing(CLEAR_WATCHES_WIN, onPotions)
            if onPotions and ButtonSetDisabledFlag then
                ButtonSetDisabledFlag(CLEAR_WATCHES_WIN, not canClearWatches)
            end
        end
        if DoesWindowExist(HARVEST_WIN) then
            WindowSetShowing(HARVEST_WIN, onWatch)
            if onWatch then
                if StockPiler3.HarvestChrome and StockPiler3.HarvestChrome.SetFooterHarvestClickable then
                    StockPiler3.HarvestChrome.SetFooterHarvestClickable(canHarvest)
                else
                    ButtonSetDisabledFlag(HARVEST_WIN, not canHarvest)
                end
            elseif StockPiler3.HarvestChrome and StockPiler3.HarvestChrome.ClearHarvestActionBound then
                StockPiler3.HarvestChrome.ClearHarvestActionBound()
            end
        end
        if DoesWindowExist(BREW_WIN) then
            WindowSetShowing(BREW_WIN, onWatch)
            if onWatch then
                ButtonSetDisabledFlag(BREW_WIN, not canBrew)
            end
        end
    end

    local prevOnWatch = StockPiler3Window._footerOnWatch
    local prevHarvest = StockPiler3Window._footerCanHarvest
    local prevBrew = StockPiler3Window._footerCanBrew
    StockPiler3Window._footerWindowOpen = windowOpen
    StockPiler3Window._footerOnWatch = onWatch
    StockPiler3Window._footerOnPotions = onPotions
    StockPiler3Window._footerCanHarvest = canHarvest
    StockPiler3Window._footerCanBrew = canBrew
    StockPiler3Window._footerCanClearWatches = canClearWatches
    local readinessChanged = prevOnWatch ~= onWatch
        or prevHarvest ~= canHarvest
        or prevBrew ~= canBrew

    if not readinessChanged and StockPiler3.Macro then
        local skipDrift = false
        if StockPiler3.Brew then
            if StockPiler3.Brew.IsBusy and StockPiler3.Brew.IsBusy() == true then
                skipDrift = true
            else
                local session = StockPiler3.Brew.GetSession and StockPiler3.Brew.GetSession()
                if type(session) == "table" and session.phase == "loading" then
                    skipDrift = true
                end
            end
        end
        if not skipDrift then
            if StockPiler3.Macro._lastAppearanceKey ~= nil
                and StockPiler3.Macro._lastAppearanceKey ~= appearanceKey
            then
                readinessChanged = true
            end
        end
    end

    if readinessChanged or immediate then
        if StockPiler3.Macro then
            if immediate and StockPiler3.Macro.RefreshMacroButtonAppearance then
                StockPiler3.Macro._enabledSyncPending = false
                StockPiler3.Macro._pendingCanHarvest = nil
                StockPiler3.Macro._pendingCanBrew = nil
                StockPiler3.Macro.RefreshMacroButtonAppearance({
                    canHarvest = canHarvest,
                    canBrew = canBrew,
                })
            elseif StockPiler3.Macro.RequestEnabledSync then
                StockPiler3.Macro.RequestEnabledSync(canHarvest, canBrew)
            elseif StockPiler3.Macro.SyncEnabledState then
                StockPiler3.Macro.SyncEnabledState(canHarvest, canBrew)
            end
        end
    end

    if Perf and Perf.End then
        Perf.End("Footer")
    end
    return canHarvest, canBrew
end

function StockPiler3Window.FlushPendingFooterRefresh()
    if StockPiler3Window._footerRefreshPending ~= true then
        return
    end
    local Sch = StockPiler3.Scheduler
    if Sch and Sch.SkipUiHoldFooter and Sch.SkipUiHoldFooter() == true then
        return
    end
    local brewJob = StockPiler3.Brew and type(StockPiler3.Brew._job) == "table"
    if not brewJob then
        if Sch and Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
            return
        end
        if Sch and Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true then
            return
        end
    end
    StockPiler3Window._footerRefreshPending = false
    StockPiler3Window.SyncActionReadiness()
    if StockPiler3.HarvestTooltip and StockPiler3.HarvestTooltip.TickLive then
        StockPiler3.HarvestTooltip.TickLive()
    end
    if StockPiler3.BrewTooltip and StockPiler3.BrewTooltip.TickLive then
        StockPiler3.BrewTooltip.TickLive()
    end
end

function StockPiler3Window.RefreshFooterButtons()
    StockPiler3Window.RequestFooterRefresh()
end

function StockPiler3Window.Initialize()
    if not DoesWindowExist("StockPiler3Window") then
        return
    end
    local version = StockPiler3.Version or L""
    if version ~= L"" then
        LabelSetText("StockPiler3WindowTitleBarText", T("ui.title_version", { version = version }))
    else
        LabelSetText("StockPiler3WindowTitleBarText", T("ui.title"))
    end
    if DoesWindowExist(CLEAR_WATCHES_WIN) then
        ButtonSetText(CLEAR_WATCHES_WIN, T("ui.clear_watches"))
    end
    if DoesWindowExist(HARVEST_WIN) then
        ButtonSetText(HARVEST_WIN, T("ui.harvest"))
        if StockPiler3.HarvestChrome and StockPiler3.HarvestChrome.EnsureHarvestActionBound then
            StockPiler3.HarvestChrome.EnsureHarvestActionBound()
        end
    end
    if DoesWindowExist(BREW_WIN) then
        ButtonSetText(BREW_WIN, T("ui.brew"))
    end
    for _, tab in ipairs(StockPiler3Window.Tabs) do
        ButtonSetText(tab.name, T(tab.labelKey))
    end
    StockPiler3Window.SelectTab(StockPiler3Window.SelectedTab)
end

function StockPiler3Window.RefreshActiveTab()
    if StockPiler3.Perf and StockPiler3.Perf.Begin then
        StockPiler3.Perf.Begin("RefreshWatch")
    end
    local tab = StockPiler3Window.Tabs[StockPiler3Window.SelectedTab]
    if tab and tab.refresh then
        tab.refresh()
    end
    StockPiler3Window.RefreshFooterButtons()
    if StockPiler3.Perf and StockPiler3.Perf.End then
        StockPiler3.Perf.End("RefreshWatch")
    end
end

function StockPiler3Window.RequestListRepopulate()
    StockPiler3Window._repopulatePending = true
end

function StockPiler3Window.FlushPendingListRepopulate()
    if StockPiler3Window._repopulatePending ~= true then
        return
    end
    if not DoesWindowExist("StockPiler3Window") then
        return
    end
    if WindowGetShowing("StockPiler3Window") ~= true then
        return
    end
    StockPiler3Window._repopulatePending = false
    if StockPiler3.Ui and StockPiler3.Ui.MarkWatchUiDirty then
        StockPiler3.Ui.MarkWatchUiDirty()
        return
    end
    StockPiler3Window.RefreshActiveTab()
end

function StockPiler3Window.PrimeTabListsIfNeeded()
    if StockPiler3Window._tabListsPrimed == true then
        return
    end
    if not DoesWindowExist("StockPiler3Window") then
        return
    end
    if WindowGetShowing("StockPiler3Window") ~= true then
        return
    end
    StockPiler3Window._tabListsPrimed = true
    local selected = StockPiler3Window.SelectedTab or StockPiler3Window.TABS_POTIONS
    for index, tab in ipairs(StockPiler3Window.Tabs) do
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, true)
            if type(WindowForceProcessAnchors) == "function" then
                if StockPiler3.Debug and StockPiler3.Debug.TryCall then
                    StockPiler3.Debug.TryCall("WindowForceProcessAnchors", WindowForceProcessAnchors, tab.window)
                else
                    pcall(WindowForceProcessAnchors, tab.window)
                end
            end
        end
        if tab.refresh then
            tab.refresh()
        end
        if DoesWindowExist(tab.window) and index ~= selected then
            WindowSetShowing(tab.window, false)
        end
    end
    for index, tab in ipairs(StockPiler3Window.Tabs) do
        if DoesWindowExist(tab.name) then
            ButtonSetPressedFlag(tab.name, index == selected)
        end
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, index == selected)
        end
    end
    StockPiler3Window.RefreshFooterButtons()
end

function StockPiler3Window.OnShow()
    WindowUtils.OnShown()
    if StockPiler3.Inventory and StockPiler3.Inventory.RefreshAllIfNeeded then
        StockPiler3.Inventory.RefreshAllIfNeeded({
            force = StockPiler3.Inventory.IsDirty and StockPiler3.Inventory.IsDirty(),
        })
    end
    if StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Invalidate then
        StockPiler3.PlanSnapshot.Invalidate()
    end
    if StockPiler3TabWatch and StockPiler3TabWatch.RefreshSkillGates then
        StockPiler3TabWatch.RefreshSkillGates()
    end
    if StockPiler3TabWatch and StockPiler3TabWatch.ClearRowPaintCache then
        StockPiler3TabWatch.ClearRowPaintCache()
    end
    StockPiler3Window.PrimeTabListsIfNeeded()
    StockPiler3Window.RefreshActiveTab()
    StockPiler3Window.RequestListRepopulate()
end

function StockPiler3Window.OnClose()
    WindowSetShowing("StockPiler3Window", false)
end

function StockPiler3Window.ConfirmClearWatches()
    local n = 0
    if StockPiler3.Catalog and StockPiler3.Catalog.ClearWatchList then
        n = tonumber(StockPiler3.Catalog.ClearWatchList()) or 0
    end
    if StockPiler3.Ui and StockPiler3.Ui.Print then
        StockPiler3.Ui.Print(T("ui.watches_cleared", { count = tostring(n) }))
    end
    if StockPiler3TabWatch and StockPiler3TabWatch.Refresh then
        StockPiler3TabWatch.Refresh()
    end
    StockPiler3Window.RefreshFooterButtons()
end

function StockPiler3Window.OnClearWatches()
    local count = 0
    if StockPiler3.Watch and StockPiler3.Watch.CountEnabled then
        count = tonumber(StockPiler3.Watch.CountEnabled()) or 0
    end
    if count <= 0 then
        if StockPiler3.Ui and StockPiler3.Ui.Print then
            StockPiler3.Ui.Print(T("ui.no_watches"))
        end
        StockPiler3Window.RefreshFooterButtons()
        return
    end
    if type(DialogManager) == "table" and type(DialogManager.MakeTwoButtonDialog) == "function" then
        local yes = GetString and GetString(StringTables.Default.LABEL_YES) or T("ui.yes")
        local no = GetString and GetString(StringTables.Default.LABEL_NO) or T("ui.no")
        DialogManager.MakeTwoButtonDialog(
            T("ui.clear_watches_confirm", { count = tostring(count) }),
            yes,
            StockPiler3Window.ConfirmClearWatches,
            no,
            nil
        )
        return
    end
    StockPiler3Window.ConfirmClearWatches()
end

function StockPiler3Window.OnMouseOverClearWatches()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("ui.clear_watches_tip"))
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler3Window.OnHarvestPrepare()
    if StockPiler3.Grow and StockPiler3.Grow.CanHarvestNow then
        if StockPiler3.Grow.CanHarvestNow() ~= true then
            return
        end
    else
        local ready = 0
        if StockPiler3.Grow and StockPiler3.Grow.GetReadyHarvestPlots then
            local plots = StockPiler3.Grow.GetReadyHarvestPlots()
            ready = type(plots) == "table" and #plots or 0
        end
        if ready <= 0 then
            return
        end
    end
    if DoesWindowExist(HARVEST_WIN) and ButtonGetDisabledFlag(HARVEST_WIN) == true then
        return
    end
    local prepared = false
    if StockPiler3.Grow and StockPiler3.Grow.PrepareHarvestPlot then
        prepared = StockPiler3.Grow.PrepareHarvestPlot(true) == true
    end
    if prepared then
        if Sound and Sound.Play and Sound.CULTIVATING_HARVEST_CROP then
            Sound.Play(Sound.CULTIVATING_HARVEST_CROP)
        end
    end
end

function StockPiler3Window.OnHarvest()
end

function StockPiler3Window.OnMouseOverHarvest()
    if StockPiler3.HarvestTooltip and StockPiler3.HarvestTooltip.Show then
        StockPiler3.HarvestTooltip.Show(
            SystemData.ActiveWindow.name,
            Tooltips.ANCHOR_WINDOW_TOP
        )
        return
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("ui.harvest_tip_none"))
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler3Window.OnBrew()
    if DoesWindowExist(BREW_WIN) and ButtonGetDisabledFlag(BREW_WIN) == true then
        return
    end
    if not StockPiler3.Brew then
        return
    end
    local result = nil
    if StockPiler3.Brew.TryBrewClick then
        result = StockPiler3.Brew.TryBrewClick()
    end
    if result == "go" and StockPiler3.Brew.FirePerform then
        StockPiler3.Brew.FirePerform()
    end
    StockPiler3Window.RefreshFooterButtons()
end

function StockPiler3Window.OnBrewRightClick()
    if StockPiler3.Brew and StockPiler3.Brew.ClearLoadedSession then
        StockPiler3.Brew.ClearLoadedSession()
    end
    StockPiler3Window.RefreshFooterButtons()
end

function StockPiler3Window.OnMouseOverBrew()
    if StockPiler3.BrewTooltip and StockPiler3.BrewTooltip.Show then
        StockPiler3.BrewTooltip.Show(
            SystemData.ActiveWindow.name,
            Tooltips.ANCHOR_WINDOW_TOP
        )
        return
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("brew.none_ready"))
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
end

function StockPiler3Window.SelectTab(tabNumber)
    tabNumber = tonumber(tabNumber)
    if tabNumber == nil or tabNumber < StockPiler3Window.TABS_POTIONS or tabNumber > StockPiler3Window.TABS_MAX then
        return
    end
    StockPiler3Window.SelectedTab = tabNumber
    local s = StockPiler3.Persistence and StockPiler3.Persistence.EnsureSettings
        and StockPiler3.Persistence.EnsureSettings()
    if type(s) == "table" then
        s.selectedTab = tabNumber
    end
    for index, tab in ipairs(StockPiler3Window.Tabs) do
        local selected = (index == tabNumber)
        ButtonSetPressedFlag(tab.name, selected)
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, selected)
            if selected and type(WindowForceProcessAnchors) == "function" then
                if StockPiler3.Debug and StockPiler3.Debug.TryCall then
                    StockPiler3.Debug.TryCall("WindowForceProcessAnchors", WindowForceProcessAnchors, tab.window)
                else
                    pcall(WindowForceProcessAnchors, tab.window)
                end
            end
        end
    end
    StockPiler3Window.RefreshActiveTab()
    StockPiler3Window.RequestListRepopulate()
end

function StockPiler3Window.OnLButtonUpTab()
    local tabId = WindowGetId(SystemData.ActiveWindow.name)
    StockPiler3Window.SelectTab(tabId)
end
