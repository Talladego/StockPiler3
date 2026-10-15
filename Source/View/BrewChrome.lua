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
    local Bus = StockPiler3.EventBus
    if Bus and Bus.FireFooterDirty then
        Bus.FireFooterDirty({ immediate = true, syncMacro = true, reason = "brew-chrome" })
    end
    if Bus and Bus.FireBrewSessionChanged then
        Bus.FireBrewSessionChanged({ reason = "brew-chrome" })
    end
    if Brew and Brew.MaybeNotifyBrewReady then
        Brew.MaybeNotifyBrewReady()
    end
    if StockPiler3.Perf and StockPiler3.Perf.End then
        StockPiler3.Perf.End("BrewUi")
    end
end
