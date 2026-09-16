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
    if StockPiler3.Ui and StockPiler3.Ui.MarkWatchUiDirty then
        StockPiler3.Ui.MarkWatchUiDirty()
    end
    if StockPiler3Window and StockPiler3Window.RequestListRepopulate then
        StockPiler3Window.RequestListRepopulate()
    end
    if Brew and Brew.MaybeNotifyBrewReady then
        Brew.MaybeNotifyBrewReady()
    end
    if StockPiler3.Perf and StockPiler3.Perf.End then
        StockPiler3.Perf.End("BrewUi")
    end
end
