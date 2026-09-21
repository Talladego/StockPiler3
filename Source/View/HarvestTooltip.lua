----------------------------------------------------------------
-- StockPiler3 HarvestTooltip -- live plot readiness tip
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.HarvestTooltip = StockPiler3.HarvestTooltip or {}
local HarvestTooltip = StockPiler3.HarvestTooltip

local function T(key, tokens)
    return StockPiler3.Util.T(key, tokens)
end

local function ReadyCount()
    local Grow = StockPiler3.Grow
    if Grow and Grow.GetReadyHarvestPlots then
        local plots = Grow.GetReadyHarvestPlots()
        if type(plots) == "table" then
            return #plots
        end
    end
    return 0
end

local function BuildTipText()
    local ready = ReadyCount()
    local can = StockPiler3.Grow and StockPiler3.Grow.CanHarvestNow
        and StockPiler3.Grow.CanHarvestNow() == true
    if can and ready > 0 then
        return T("grow.harvest_ready", { count = tostring(ready) })
    end
    if ready > 0 then
        return T("ui.harvest_tip_ready", { count = tostring(ready) })
    end
    return T("ui.harvest_tip_none")
end

local function Fingerprint()
    local ready = ReadyCount()
    local can = StockPiler3.Grow and StockPiler3.Grow.CanHarvestNow
        and StockPiler3.Grow.CanHarvestNow() == true
    return tostring(can) .. ":" .. tostring(ready)
end

function HarvestTooltip.Show(mouseoverWindow, anchor)
    StockPiler3.ViewList.LiveTipShow(
        HarvestTooltip,
        BuildTipText,
        Fingerprint,
        mouseoverWindow,
        anchor,
        Tooltips and Tooltips.ANCHOR_WINDOW_TOP
    )
end

function HarvestTooltip.ClearLive()
    StockPiler3.ViewList.LiveTipClear(HarvestTooltip)
end

function HarvestTooltip.MaybeRefresh()
    StockPiler3.ViewList.LiveTipMaybeRefresh(
        HarvestTooltip,
        BuildTipText,
        Fingerprint,
        HarvestTooltip.Show
    )
end

function HarvestTooltip.TickLive()
    HarvestTooltip.MaybeRefresh()
end
