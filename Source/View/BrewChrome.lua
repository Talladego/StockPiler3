----------------------------------------------------------------
-- StockPiler3 BrewChrome -- footer / row brew paint requests
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.BrewChrome = StockPiler3.BrewChrome or {}
local BrewChrome = StockPiler3.BrewChrome

function BrewChrome.RefreshBrewUi()
    local Brew = StockPiler3.Brew
    if Brew and Brew._suppressBrewUi == true then
        return
    end
    if Brew and Brew.InvalidateCanBrewCache then
        Brew.InvalidateCanBrewCache()
    end
    if StockPiler3.Perf and StockPiler3.Perf.Begin then
        StockPiler3.Perf.Begin("BrewUi")
    end
    if StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
        StockPiler3Window.RequestFooterRefresh()
    elseif StockPiler3Window and StockPiler3Window.RefreshFooterButtons then
        StockPiler3Window.RefreshFooterButtons()
    end
    if StockPiler3TabWatch and StockPiler3TabWatch.InvalidateBrewChrome then
        StockPiler3TabWatch.InvalidateBrewChrome()
    end
    -- Chrome-only keepVisible paint. Do not MarkWatchUiDirty / RequestListRepopulate:
    -- those queued a full RefreshActiveTab (ListBoxSetDisplayOrder) once the
    -- inter-craft hold expired and blanked every Watch row between crafts.
    if DoesWindowExist("StockPiler3Window")
        and WindowGetShowing("StockPiler3Window") == true
        and StockPiler3Window.SelectedTab == StockPiler3Window.TABS_WATCH
        and StockPiler3TabWatch
        and StockPiler3TabWatch.UpdateRows
    then
        StockPiler3TabWatch.UpdateRows({ keepVisible = true })
    end
    if Brew and Brew.MaybeNotifyBrewReady then
        Brew.MaybeNotifyBrewReady()
    end
    if StockPiler3.Perf and StockPiler3.Perf.End then
        StockPiler3.Perf.End("BrewUi")
    end
end
