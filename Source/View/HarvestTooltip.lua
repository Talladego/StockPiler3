----------------------------------------------------------------
-- StockPiler3 HarvestTooltip -- live plot readiness tip
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.HarvestTooltip = StockPiler3.HarvestTooltip or {}
local HarvestTooltip = StockPiler3.HarvestTooltip

local function T(key, tokens)
    if StockPiler3.T then
        return StockPiler3.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
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
    mouseoverWindow = mouseoverWindow or (SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    if mouseoverWindow == nil or mouseoverWindow == "" then
        return
    end
    HarvestTooltip._liveWindow = mouseoverWindow
    HarvestTooltip._liveAnchor = anchor or (Tooltips and Tooltips.ANCHOR_WINDOW_TOP)
    HarvestTooltip._liveFp = Fingerprint()
    Tooltips.CreateTextOnlyTooltip(mouseoverWindow, BuildTipText())
    Tooltips.AnchorTooltip(HarvestTooltip._liveAnchor)
end

function HarvestTooltip.ClearLive()
    HarvestTooltip._liveWindow = nil
    HarvestTooltip._liveFp = nil
end

function HarvestTooltip.MaybeRefresh()
    local win = HarvestTooltip._liveWindow
    if win == nil or win == "" then
        return
    end
    local fp = Fingerprint()
    if fp == HarvestTooltip._liveFp then
        return
    end
    HarvestTooltip.Show(win, HarvestTooltip._liveAnchor)
end

function HarvestTooltip.TickLive()
    HarvestTooltip.MaybeRefresh()
end
