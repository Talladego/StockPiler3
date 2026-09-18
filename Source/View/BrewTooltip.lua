----------------------------------------------------------------
-- StockPiler3 BrewTooltip -- footer Ready tip (live while hovered)
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.BrewTooltip = StockPiler3.BrewTooltip or {}
local BrewTooltip = StockPiler3.BrewTooltip

local function T(key, tokens)
    if StockPiler3.T then
        return StockPiler3.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

local function SessionBrewName(session)
    if type(session) ~= "table" then
        return nil
    end
    local phase = tostring(session.phase or "idle")
    if phase ~= "loading" and phase ~= "loaded" then
        return nil
    end
    if session.name ~= nil and session.name ~= L"" then
        return session.name
    end
    return nil
end

local function ReadyName()
    local Brew = StockPiler3.Brew
    local session = Brew and Brew.GetSession and Brew.GetSession()
    local loadedName = SessionBrewName(session)
    if loadedName ~= nil then
        return loadedName
    end
    if Brew and Brew.PickReadyWatch then
        local row = Brew.PickReadyWatch()
        if type(row) == "table" and row.name ~= nil and row.name ~= L"" then
            return row.name
        end
    end
    return T("brew.potion_fallback")
end

local function BuildTipText()
    local Brew = StockPiler3.Brew
    local session = Brew and Brew.GetSession and Brew.GetSession()
    local loadedName = SessionBrewName(session)
    local can = Brew and Brew.CanBrewNow and Brew.CanBrewNow() == true

    -- Loaded board: always name the recipe on the board (not PickReadyWatch).
    if loadedName ~= nil then
        if can then
            return T("brew.ready", { name = loadedName })
        end
        return T("brew.load_recipe", { name = loadedName })
    end

    if can then
        return T("brew.ready", { name = ReadyName() })
    end
    local why = Brew and Brew.AutoBrewBlockedReason and Brew.AutoBrewBlockedReason()
    if why == "buffer" then
        return T("brew.blocked_buffer")
    elseif why == "pending-plant" then
        return T("brew.blocked_plant")
    elseif why == "refine" then
        return T("brew.blocked_refine")
    elseif why == "harvest" then
        return T("brew.blocked_harvest")
    end
    if Brew and Brew.HasReadyToCraft and Brew.HasReadyToCraft() == true then
        return T("brew.blocked_other")
    end
    return T("brew.none_ready")
end

local function Fingerprint()
    local Brew = StockPiler3.Brew
    local can = Brew and Brew.CanBrewNow and Brew.CanBrewNow() == true
    local session = Brew and Brew.GetSession and Brew.GetSession()
    local phase = "idle"
    local key = ""
    local nameKey = ""
    if type(session) == "table" then
        phase = tostring(session.phase or "idle")
        key = tostring(session.potionKey or session.rowId or "")
        local loadedName = SessionBrewName(session)
        if loadedName ~= nil then
            if type(loadedName) == "wstring" and type(WStringToString) == "function" then
                nameKey = WStringToString(loadedName) or ""
            else
                nameKey = tostring(loadedName)
            end
        end
    end
    if nameKey == "" then
        local n = ReadyName()
        if type(n) == "wstring" and type(WStringToString) == "function" then
            nameKey = WStringToString(n) or ""
        else
            nameKey = tostring(n or "")
        end
    end
    return tostring(can) .. ":" .. phase .. ":" .. key .. ":" .. nameKey
end

function BrewTooltip.Show(mouseoverWindow, anchor)
    mouseoverWindow = mouseoverWindow or (SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    if mouseoverWindow == nil or mouseoverWindow == "" then
        return
    end
    BrewTooltip._liveWindow = mouseoverWindow
    BrewTooltip._liveAnchor = anchor or (Tooltips and Tooltips.ANCHOR_WINDOW_TOP)
    BrewTooltip._liveFp = Fingerprint()
    Tooltips.CreateTextOnlyTooltip(mouseoverWindow, BuildTipText())
    Tooltips.AnchorTooltip(BrewTooltip._liveAnchor)
end

function BrewTooltip.ShowRow(mouseoverWindow, row, anchor)
    mouseoverWindow = mouseoverWindow or (SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    if mouseoverWindow == nil or mouseoverWindow == "" then
        return
    end
    local name = (type(row) == "table" and row.name) or T("brew.potion_fallback")
    local tip = T("brew.load_recipe", { name = name })
    if type(row) == "table" then
        local craftable = tonumber(row.craftable) or 0
        local status = tostring(row.statusKey or "")
        if craftable <= 0 then
            tip = T("brew.nothing_craftable")
        elseif status ~= "ready_to_craft" and status ~= "ready_to_craft_shared" then
            tip = T("brew.not_ready")
        end
    end
    Tooltips.CreateTextOnlyTooltip(mouseoverWindow, tip)
    Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_RIGHT)
end

function BrewTooltip.ClearLive()
    BrewTooltip._liveWindow = nil
    BrewTooltip._liveFp = nil
end

function BrewTooltip.MaybeRefresh()
    local win = BrewTooltip._liveWindow
    if win == nil or win == "" then
        return
    end
    local fp = Fingerprint()
    if fp == BrewTooltip._liveFp then
        return
    end
    BrewTooltip.Show(win, BrewTooltip._liveAnchor)
end

function BrewTooltip.TickLive()
    BrewTooltip.MaybeRefresh()
end
