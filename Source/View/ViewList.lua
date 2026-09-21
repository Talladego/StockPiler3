----------------------------------------------------------------
-- StockPiler3 View/ViewList — shared list chrome helpers
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.ViewList = StockPiler3.ViewList or {}
local VL = StockPiler3.ViewList

local DEFAULT_ICON_SCALE = 0.34

function VL.T(key, tokens)
    return StockPiler3.Util.T(key, tokens)
end

function VL.ItemRarityNameColor(itemData)
    if itemData and DataUtils and DataUtils.GetItemRarityColor then
        local ok, color = StockPiler3.Util.TryCallQuiet(
            "DataUtils.GetItemRarityColor",
            DataUtils.GetItemRarityColor,
            itemData
        )
        if ok and type(color) == "table" then
            return tonumber(color.r) or 255, tonumber(color.g) or 255, tonumber(color.b) or 255
        end
    end
    return 255, 255, 255
end

--- opts.zeroAsDash: show ui.dash when n == 0 (Plants default).
function VL.FormatSignedStat(n, opts)
    n = tonumber(n) or 0
    opts = type(opts) == "table" and opts or {}
    if n == 0 and opts.zeroAsDash == true then
        return VL.T("ui.dash")
    end
    if n > 0 then
        return towstring("+" .. tostring(n))
    end
    return towstring(tostring(n))
end

function VL.FormatPercentStat(n)
    n = tonumber(n) or 0
    if n == 0 then
        return VL.T("ui.dash")
    end
    return towstring(tostring(n) .. "%")
end

--- opts.emptyDash: return ui.dash when empty (Plants). Else L"" then upper fallback (Potions).
function VL.EffectTextForRow(effectKey, opts)
    opts = type(opts) == "table" and opts or {}
    if type(effectKey) == "string" and effectKey ~= "" then
        local RS = StockPiler3.RecipeSpec
        if RS and RS.NormalizeEffectKeyForUi then
            effectKey = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
        end
        if StockPiler3.Classify and StockPiler3.Classify.EffectShortLabel then
            local label = StockPiler3.Classify.EffectShortLabel(effectKey)
            if label ~= nil and label ~= L"" then
                return label
            end
        end
        if opts.emptyDash ~= true then
            return towstring(string.upper(effectKey))
        end
    end
    if opts.emptyDash == true then
        return VL.T("ui.dash")
    end
    return L""
end

function VL.SetIconTexture(iconWin, iconNum, scale)
    if not DoesWindowExist(iconWin) then
        return
    end
    scale = tonumber(scale) or DEFAULT_ICON_SCALE
    if iconNum and iconNum > 0 and type(GetIconData) == "function" then
        local ok, texture, x, y = StockPiler3.Util.TryCallQuiet("GetIconData", GetIconData, iconNum)
        if ok and texture and texture ~= "" then
            DynamicImageSetTexture(iconWin, texture, x or 0, y or 0)
            if type(DynamicImageSetTextureScale) == "function" then
                DynamicImageSetTextureScale(iconWin, scale)
            end
            WindowSetShowing(iconWin, true)
            return
        end
    end
    DynamicImageSetTexture(iconWin, "", 0, 0)
    WindowSetShowing(iconWin, false)
end

function VL.PaintWatchCheckbox(win, watched, blocked)
    if win == nil or win == "" or not DoesWindowExist(win) then
        return
    end
    blocked = blocked == true
    watched = watched == true and not blocked
    if ButtonSetCheckButtonFlag then
        ButtonSetCheckButtonFlag(win, true)
    end
    ButtonSetPressedFlag(win, watched)
    if ButtonSetDisabledFlag then
        ButtonSetDisabledFlag(win, blocked)
    end
end

function VL.UpdateSortArrows(headers, column, ascending)
    if type(headers) ~= "table" then
        return
    end
    column = tostring(column or "")
    ascending = ascending ~= false
    for key, win in pairs(headers) do
        if DoesWindowExist(win) then
            local up = win .. "UpArrow"
            local down = win .. "DownArrow"
            if key == column then
                WindowSetShowing(up, ascending)
                WindowSetShowing(down, not ascending)
            else
                WindowSetShowing(up, false)
                WindowSetShowing(down, false)
            end
        end
    end
end

function VL.EffectFilterCycle()
    local keys = { "" }
    if StockPiler3.Classify and StockPiler3.Classify.EffectFilterKeys then
        local list = StockPiler3.Classify.EffectFilterKeys()
        for i = 1, #list do
            keys[#keys + 1] = list[i]
        end
    end
    return keys
end

function VL.SyncEffectCombo(comboWin, currentKey, effectTextFn)
    if not DoesWindowExist(comboWin) then
        return
    end
    local cycle = VL.EffectFilterCycle()
    currentKey = tostring(currentKey or "")
    local selected = 1
    for i = 1, #cycle do
        if cycle[i] == currentKey then
            selected = i
            break
        end
    end
    ComboBoxSetSelectedMenuItem(comboWin, selected)
end

function VL.InitEffectCombo(comboWin, currentKey, effectTextFn)
    if not DoesWindowExist(comboWin) then
        return
    end
    effectTextFn = type(effectTextFn) == "function" and effectTextFn or VL.EffectTextForRow
    ComboBoxClearMenuItems(comboWin)
    ComboBoxAddMenuItem(comboWin, VL.T("potions.all_effects"))
    local cycle = VL.EffectFilterCycle()
    for i = 2, #cycle do
        ComboBoxAddMenuItem(comboWin, effectTextFn(cycle[i]))
    end
    VL.SyncEffectCombo(comboWin, currentKey, effectTextFn)
end

--- Two-button confirm; calls onYes immediately if DialogManager missing.
function VL.ConfirmTwoButton(message, onYes)
    if type(DialogManager) == "table" and type(DialogManager.MakeTwoButtonDialog) == "function" then
        local yes = GetString and GetString(StringTables.Default.LABEL_YES) or VL.T("ui.yes")
        local no = GetString and GetString(StringTables.Default.LABEL_NO) or VL.T("ui.no")
        DialogManager.MakeTwoButtonDialog(message, yes, onYes, no, nil)
        return true
    end
    if type(onYes) == "function" then
        onYes()
    end
    return false
end

function VL.ShowTextTip(anchorWin, text, anchor)
    if not (Tooltips and Tooltips.CreateTextOnlyTooltip) then
        return
    end
    Tooltips.CreateTextOnlyTooltip(anchorWin or SystemData.ActiveWindow.name, text)
    Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_RIGHT)
end

--- Live text tooltip shell: state table with _liveWindow/_liveAnchor/_liveFp.
--- api = { buildText=fn, fingerprint=fn, show=fn? }
function VL.LiveTipShow(state, buildText, fingerprint, mouseoverWindow, anchor, defaultAnchor)
    mouseoverWindow = mouseoverWindow or (SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    if mouseoverWindow == nil or mouseoverWindow == "" then
        return
    end
    state._liveWindow = mouseoverWindow
    state._liveAnchor = anchor or defaultAnchor or (Tooltips and Tooltips.ANCHOR_WINDOW_TOP)
    state._liveFp = fingerprint()
    Tooltips.CreateTextOnlyTooltip(mouseoverWindow, buildText())
    Tooltips.AnchorTooltip(state._liveAnchor)
end

function VL.LiveTipClear(state)
    state._liveWindow = nil
    state._liveFp = nil
end

function VL.LiveTipMaybeRefresh(state, buildText, fingerprint, showFn)
    local win = state._liveWindow
    if win == nil or win == "" then
        return
    end
    local fp = fingerprint()
    if fp == state._liveFp then
        return
    end
    if type(showFn) == "function" then
        showFn(win, state._liveAnchor)
    else
        VL.LiveTipShow(state, buildText, fingerprint, win, state._liveAnchor)
    end
end
