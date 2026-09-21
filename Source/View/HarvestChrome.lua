----------------------------------------------------------------
-- StockPiler3 HarvestChrome -- footer PERFORM_CRAFTING bind (ready transitions only)
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.HarvestChrome = StockPiler3.HarvestChrome or {}
local HarvestChrome = StockPiler3.HarvestChrome

local HARVEST_WIN = "StockPiler3WindowHarvest"
local HARVEST_ACTION_WIN = "StockPiler3WindowHarvestAction"

local function T(key, tokens)
    return StockPiler3.Util.T(key, tokens)
end

local function TryCall(context, fn, ...)
    return StockPiler3.Util.TryCall(context, fn, ...)
end

local function RestoreHarvestChrome(windowName)
    if windowName == nil or windowName == "" or not DoesWindowExist(windowName) then
        return
    end
    if ButtonSetText then
        ButtonSetText(windowName, T("ui.harvest"))
    end
    if ButtonSetPressedFlag then
        ButtonSetPressedFlag(windowName, false)
    end
end

local function BindCultivationHarvestAction(windowName)
    if WindowSetGameActionData == nil or windowName == nil or windowName == "" then
        return false
    end
    if not DoesWindowExist(windowName) then
        return false
    end
    local cult = GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION or 3
    local action = GameData and GameData.PlayerActions and GameData.PlayerActions.PERFORM_CRAFTING or 8
    local ok = TryCall("WindowSetGameActionData", WindowSetGameActionData, windowName, action, cult, L"")
    if ok ~= true then
        return false
    end
    RestoreHarvestChrome(windowName)
    return true
end

local function ClearHarvestBindOnly()
    local Grow = StockPiler3.Grow
    if not Grow or Grow._harvestActionBound ~= true then
        return false
    end
    if WindowSetGameActionData == nil then
        Grow._harvestActionBound = false
        return false
    end
    local none = 0
    if GameData and GameData.PlayerActions and GameData.PlayerActions.NONE ~= nil then
        none = GameData.PlayerActions.NONE
    end
    local function clearWin(windowName)
        if not DoesWindowExist(windowName) then
            return false
        end
        local ok = TryCall("WindowSetGameActionData.clear", WindowSetGameActionData, windowName, none, 0, L"")
        RestoreHarvestChrome(windowName)
        return ok == true
    end
    local cleared = clearWin(HARVEST_WIN)
    clearWin(HARVEST_ACTION_WIN)
    Grow._harvestActionBound = false
    return cleared
end

function HarvestChrome.EnsureHarvestActionBound()
    local Grow = StockPiler3.Grow
    if not Grow then
        return false
    end
    if Grow._harvestActionBound == true and DoesWindowExist(HARVEST_WIN) then
        return true
    end
    if BindCultivationHarvestAction(HARVEST_WIN) or BindCultivationHarvestAction(HARVEST_ACTION_WIN) then
        Grow._harvestActionBound = true
        return true
    end
    Grow._harvestActionBound = false
    return false
end

--- Bind/clear PERFORM_CRAFTING only on ready transitions. Keep HandleInput for tooltips.
function HarvestChrome.SetFooterHarvestClickable(enabled)
    local Grow = StockPiler3.Grow
    if not Grow or not DoesWindowExist(HARVEST_WIN) then
        return
    end
    enabled = enabled == true
    if WindowSetHandleInput then
        WindowSetHandleInput(HARVEST_WIN, true)
    end
    if Grow._footerHarvestClickable == enabled then
        return
    end
    if ButtonSetDisabledFlag then
        ButtonSetDisabledFlag(HARVEST_WIN, not enabled)
    end
    if enabled then
        HarvestChrome.EnsureHarvestActionBound()
    else
        ClearHarvestBindOnly()
    end
    Grow._footerHarvestClickable = enabled
end

function HarvestChrome.ClearHarvestActionBound()
    local Grow = StockPiler3.Grow
    if Grow then
        Grow._footerHarvestClickable = nil
    end
    local cleared = ClearHarvestBindOnly()
    if DoesWindowExist(HARVEST_WIN) and WindowSetHandleInput then
        WindowSetHandleInput(HARVEST_WIN, true)
    end
    return cleared
end

function HarvestChrome.FireHarvestAction()
    if StockPiler3.Macro and StockPiler3.Macro.FireHarvestGameAction then
        if StockPiler3.Macro.FireHarvestGameAction() == true then
            return true
        end
    end
    HarvestChrome.EnsureHarvestActionBound()
    if type(WindowGameAction) ~= "function" then
        return false
    end
    local function tryWin(windowName, rebind)
        if windowName == nil or windowName == "" or not DoesWindowExist(windowName) then
            return false
        end
        if rebind == true then
            BindCultivationHarvestAction(windowName)
        end
        local child = windowName .. "Action"
        if DoesWindowExist(child) then
            local okChild = TryCall("WindowGameAction", WindowGameAction, child)
            if okChild == true then
                return true
            end
        end
        local ok = TryCall("WindowGameAction", WindowGameAction, windowName)
        return ok == true
    end
    return tryWin(HARVEST_WIN, true) or tryWin(HARVEST_ACTION_WIN, true)
end
