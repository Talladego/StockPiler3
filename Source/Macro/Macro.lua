----------------------------------------------------------------
-- StockPiler3 Macro - ActionBar Harvest / Brew macros
-- (WarTriage / GatherButton / SP1 pattern). Macros only; does
-- not hijack stock Cultivating / Apothecary craft skills.
----------------------------------------------------------------

StockPiler3.Macro = StockPiler3.Macro or {}
local Macro = StockPiler3.Macro

local function T(key, tokens)
    return StockPiler3.Util.T(key, tokens)
end

local MACRO_NAME = L"StockPiler3 Harvest"
local MACRO_TEXT = L"/script StockPiler3.Macro.HarvestClick()"
local MACRO_ICON = 2486 -- Abi_or_Mushroom01.dds (+ _disabled)

local BREW_MACRO_NAME = L"StockPiler3 Brew"
local BREW_MACRO_TEXT = L"/script StockPiler3.Macro.BrewClick()"
local BREW_MACRO_ICON = 10985 -- abi_de_elixirofmaddenedspeed.dds (+ _disabled)

local actionButtonHooksInstalled = false
local setActionDataHooked = false
local updateEnabledStateHooked = false
local hotbarEventRegistered = false
local tooltipHookInstalled = false
local gameActionBindCache = {}

-- ActionButton BASE_ICON window index (ea_actionbars actionbutton.lua).
local ACTION_BUTTON_BASE_ICON = 0

Macro.MacroId = 0
Macro.BrewMacroId = 0
Macro.MacroWarningState = { missing = false, unplaced = false, full = false }
Macro.BrewMacroWarningState = { missing = false, unplaced = false, full = false }

local function D(msg)
    if StockPiler3.Debug and StockPiler3.Debug.D then
        StockPiler3.Debug.D("[Macro] " .. tostring(msg))
    end
end

local function Print(msg)
    if StockPiler3.Debug and StockPiler3.Debug.Print then
        StockPiler3.Debug.Print(msg)
    end
end

local function TryCall(context, fn, ...)
    return StockPiler3.Util.TryCall(context, fn, ...)
end

local function BindCacheKey(button)
    if not button then
        return nil
    end
    if type(button.GetName) == "function" then
        local name = button:GetName()
        if name ~= nil and name ~= "" then
            return name
        end
    end
    return button.m_Name
end

local function ClearGameActionBindCache()
    gameActionBindCache = {}
end

local function GameActionAlreadyBound(button, token)
    local key = BindCacheKey(button)
    if key == nil or token == nil then
        return false
    end
    return gameActionBindCache[key] == token
end

local function RememberGameActionBind(button, token)
    local key = BindCacheKey(button)
    if key ~= nil and token ~= nil then
        gameActionBindCache[key] = token
    end
end

local function ForgetGameActionBind(button)
    local key = BindCacheKey(button)
    if key ~= nil then
        gameActionBindCache[key] = nil
    end
end

local function ActionWindowName(button)
    if not button then
        return nil
    end
    if button.m_Name and button.m_Name ~= "" then
        return button.m_Name .. "Action"
    end
    if type(button.GetName) == "function" then
        local name = button:GetName()
        if name ~= nil and name ~= "" then
            return name .. "Action"
        end
    end
    return nil
end

local function forceGreyMacroIcon(button)
    -- Macro icons often ship a colorful *_disabled texture; ActionButton only greys
    -- via tint when no disabled texture exists. Force tint so SP2-off always looks off.
    local icon = button and button.m_Windows and button.m_Windows[ACTION_BUTTON_BASE_ICON]
    if icon and type(icon.SetTintColor) == "function" then
        icon:SetTintColor(125, 125, 125)
    end
end

local function resetMacroIconTint(button)
    local icon = button and button.m_Windows and button.m_Windows[ACTION_BUTTON_BASE_ICON]
    if icon and type(icon.SetTintColor) == "function" then
        icon:SetTintColor(255, 255, 255)
    end
end

local function setButtonEnabledVisual(button, canUse)
    canUse = canUse == true
    if type(button.UpdateEnabledState) == "function" then
        button:UpdateEnabledState(canUse, true, false)
        if canUse then
            resetMacroIconTint(button)
        else
            forceGreyMacroIcon(button)
        end
        return
    end
    local win = button.m_Name
    if (win == nil or win == "") and type(button.GetName) == "function" then
        win = button:GetName()
    end
    if win and win ~= "" and ButtonSetDisabledFlag then
        ButtonSetDisabledFlag(win, not canUse)
    end
end

local function canHarvestMacro()
    return StockPiler3.Grow and StockPiler3.Grow.CanHarvestNow
        and StockPiler3.Grow.CanHarvestNow() == true
end

local function canBrewMacro()
    return StockPiler3.Brew and StockPiler3.Brew.CanBrewNow
        and StockPiler3.Brew.CanBrewNow() == true
end

local function GetMacroTable()
    if type(GetMacrosData) == "function" then
        return GetMacrosData()
    end
    if DataUtils and type(DataUtils.GetMacros) == "function" then
        return DataUtils.GetMacros()
    end
    return {}
end

local function NumMacroSlots()
    if EA_Window_Macro and tonumber(EA_Window_Macro.NUM_MACROS) then
        return tonumber(EA_Window_Macro.NUM_MACROS)
    end
    local macros = GetMacroTable()
    return #macros
end

local function MacroText(macroData)
    if type(macroData) ~= "table" then
        return L""
    end
    return macroData.text or macroData.macroText or macroData.body or macroData.command or L""
end

local function IsLegacyMacroName(name)
    if name == nil then
        return false
    end
    -- Ignore StockPiler / StockPiler2 macro names (parallel-safe).
    if name == L"StockPiler Harvest" or name == L"StockPiler Brew" then
        return true
    end
    if name == L"StockPiler2 Harvest" or name == L"StockPiler2 Brew" then
        return true
    end
    return false
end

local function FindMacroSlot(name, text, cachedId)
    cachedId = tonumber(cachedId) or 0
    if cachedId > 0 then
        return cachedId
    end
    local macros = GetMacroTable()
    local limit = NumMacroSlots()
    for slot = 1, limit do
        local macro = macros[slot]
        if type(macro) == "table" and not IsLegacyMacroName(macro.name) then
            if MacroText(macro) == text then
                return slot
            end
            if macro.name == name then
                return slot
            end
        end
    end
    return nil
end

function Macro.GetMacroId()
    local slot = FindMacroSlot(MACRO_NAME, MACRO_TEXT, Macro.MacroId)
    if slot then
        Macro.MacroId = slot
    end
    return slot
end

function Macro.GetBrewMacroId()
    local slot = FindMacroSlot(BREW_MACRO_NAME, BREW_MACRO_TEXT, Macro.BrewMacroId)
    if slot then
        Macro.BrewMacroId = slot
    end
    return slot
end

function Macro.GetMacroSlots(macroId)
    macroId = tonumber(macroId) or 0
    local slots = {}
    if macroId <= 0 or not ActionBars or not ActionBars.m_Bars then
        return slots
    end
    for i = 1, #ActionBars.m_Bars do
        local bar = ActionBars.m_Bars[i]
        if bar and bar.m_Buttons then
            for j = 1, #bar.m_Buttons do
                local button = bar.m_Buttons[j]
                if button
                    and button.m_ActionType == GameData.PlayerActions.DO_MACRO
                    and button.m_ActionId == macroId
                then
                    slots[#slots + 1] = button.m_HotBarSlot
                end
            end
        end
    end
    return slots
end

local function InvalidateSlotCache()
    Macro._cachedHarvestSlots = nil
    Macro._cachedBrewSlots = nil
    Macro._slotCacheFp = nil
    Macro._cachedHarvestId = nil
    Macro._cachedBrewId = nil
end

--- Stable fingerprint of harvest/brew hotbar placements (sorted slot ids).
--- Caches slot lists so Refresh does not walk ActionBars 4x per apply.
local function SlotFingerprint()
    local harvestId = tonumber(Macro.GetMacroId()) or 0
    local brewId = tonumber(Macro.GetBrewMacroId()) or 0
    local hSlots
    local bSlots
    if Macro._slotCacheFp ~= nil
        and Macro._cachedHarvestId == harvestId
        and Macro._cachedBrewId == brewId
        and type(Macro._cachedHarvestSlots) == "table"
        and type(Macro._cachedBrewSlots) == "table"
    then
        hSlots = Macro._cachedHarvestSlots
        bSlots = Macro._cachedBrewSlots
    else
        hSlots = Macro.GetMacroSlots(harvestId)
        bSlots = Macro.GetMacroSlots(brewId)
        table.sort(hSlots)
        table.sort(bSlots)
        Macro._cachedHarvestSlots = hSlots
        Macro._cachedBrewSlots = bSlots
        Macro._cachedHarvestId = harvestId
        Macro._cachedBrewId = brewId
    end
    local parts = { "h", tostring(harvestId) }
    for i = 1, #hSlots do
        parts[#parts + 1] = tostring(hSlots[i])
    end
    parts[#parts + 1] = "b"
    parts[#parts + 1] = tostring(brewId)
    for i = 1, #bSlots do
        parts[#parts + 1] = tostring(bSlots[i])
    end
    local fp = table.concat(parts, ",")
    Macro._slotCacheFp = fp
    return fp
end

local function RememberSlotFingerprint()
    Macro._lastSlotFingerprint = SlotFingerprint()
end

local function CachedSlotsForMacro(macroId)
    macroId = tonumber(macroId) or 0
    SlotFingerprint()
    if macroId > 0 and macroId == Macro._cachedHarvestId then
        return Macro._cachedHarvestSlots or {}
    end
    if macroId > 0 and macroId == Macro._cachedBrewId then
        return Macro._cachedBrewSlots or {}
    end
    return Macro.GetMacroSlots(macroId)
end

local function SetMacroSlot(slot, name, text, iconId, kind)
    SetMacroData(name, text, iconId, slot)
    if EA_Window_Macro and EA_Window_Macro.UpdateDetails then
        TryCall("EA_Window_Macro.UpdateDetails", EA_Window_Macro.UpdateDetails, slot)
    end
    if kind == "brew" then
        Macro.BrewMacroId = slot
    else
        Macro.MacroId = slot
    end
end

function Macro.UpdateMacro()
    local macros = GetMacroTable()
    local limit = NumMacroSlots()

    local existing = Macro.GetMacroId()
    if existing then
        SetMacroSlot(existing, MACRO_NAME, MACRO_TEXT, MACRO_ICON)
        Macro.MacroWarningState.full = false
        Macro.MacroWarningState.missing = false
        return true
    end

    for slot = 1, limit do
        local macro = macros[slot]
        if type(macro) == "table" and MacroText(macro) == L"" and (macro.name == nil or macro.name == L"") then
            SetMacroSlot(slot, MACRO_NAME, MACRO_TEXT, MACRO_ICON)
            Print(T("macro.harvest_created", {
                icon = tostring(MACRO_ICON),
                slot = tostring(slot),
            }))
            Macro.MacroWarningState.full = false
            Macro.MacroWarningState.missing = false
            return true
        end
    end

    if not Macro.MacroWarningState.full then
        Print(T("macro.harvest_full"))
        Macro.MacroWarningState.full = true
    end
    return false
end

function Macro.UpdateBrewMacro()
    local macros = GetMacroTable()
    local limit = NumMacroSlots()

    local existing = Macro.GetBrewMacroId()
    if existing then
        SetMacroSlot(existing, BREW_MACRO_NAME, BREW_MACRO_TEXT, BREW_MACRO_ICON, "brew")
        Macro.BrewMacroWarningState.full = false
        Macro.BrewMacroWarningState.missing = false
        return true
    end

    for slot = 1, limit do
        local macro = macros[slot]
        if type(macro) == "table" and MacroText(macro) == L"" and (macro.name == nil or macro.name == L"") then
            SetMacroSlot(slot, BREW_MACRO_NAME, BREW_MACRO_TEXT, BREW_MACRO_ICON, "brew")
            Print(T("macro.brew_created", {
                icon = tostring(BREW_MACRO_ICON),
                slot = tostring(slot),
            }))
            Macro.BrewMacroWarningState.full = false
            Macro.BrewMacroWarningState.missing = false
            return true
        end
    end

    if not Macro.BrewMacroWarningState.full then
        Print(T("macro.brew_full"))
        Macro.BrewMacroWarningState.full = true
    end
    return false
end

local function CultivationTradeSkill()
    if GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION then
        return GameData.TradeSkills.CULTIVATION
    end
    return 3
end

local function ApothecaryTradeSkill()
    if GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY then
        return GameData.TradeSkills.APOTHECARY
    end
    return 4
end

local function PerformCraftingAction()
    if GameData and GameData.PlayerActions and GameData.PlayerActions.PERFORM_CRAFTING then
        return GameData.PlayerActions.PERFORM_CRAFTING
    end
    return 8
end

local function NonePlayerAction()
    if GameData and GameData.PlayerActions and GameData.PlayerActions.NONE ~= nil then
        return GameData.PlayerActions.NONE
    end
    return 0
end

local function bindHarvestGameAction(button)
    if not button or not button.m_Name or WindowSetGameActionData == nil then
        return false
    end
    local actionName = button.m_Name .. "Action"
    if not DoesWindowExist(actionName) then
        return false
    end
    local ok = TryCall(
        "WindowSetGameActionData", WindowSetGameActionData,
        actionName,
        PerformCraftingAction(),
        CultivationTradeSkill(),
        L""
    )
    return ok == true
end

local function bindHarvestGameActionForButton(button, opts)
    opts = type(opts) == "table" and opts or {}
    if not button then
        return false
    end
    -- force=true on click: engine may have cleared the Action bind while our
    -- cache still says "harvest", which made WindowGameAction a no-op.
    if opts.force ~= true and GameActionAlreadyBound(button, "harvest") then
        return true
    end
    if button.m_Name and bindHarvestGameAction(button) then
        RememberGameActionBind(button, "harvest")
        return true
    end
    if type(button.GetName) == "function" then
        local actionName = button:GetName() .. "Action"
        if WindowSetGameActionData and DoesWindowExist(actionName) then
            local ok = TryCall(
                "WindowSetGameActionData", WindowSetGameActionData,
                actionName,
                PerformCraftingAction(),
                CultivationTradeSkill(),
                L""
            )
            if ok == true then
                RememberGameActionBind(button, "harvest")
            end
            return ok == true
        end
    end
    return false
end

local function clearHarvestGameActionForButton(button)
    if not button or WindowSetGameActionData == nil then
        return false
    end
    local actionName = ActionWindowName(button)
    if actionName == nil or not DoesWindowExist(actionName) then
        return false
    end
    local ok = TryCall(
        "WindowSetGameActionData.clear", WindowSetGameActionData,
        actionName,
        NonePlayerAction(),
        0,
        L""
    )
    ForgetGameActionBind(button)
    return ok == true
end

local function clearBrewGameActionForButton(button)
    if not button or WindowSetGameActionData == nil then
        return false
    end
    local actionName = ActionWindowName(button)
    if actionName == nil or not DoesWindowExist(actionName) then
        return false
    end
    local ok = TryCall(
        "WindowSetGameActionData.clear", WindowSetGameActionData,
        actionName,
        NonePlayerAction(),
        0,
        L""
    )
    ForgetGameActionBind(button)
    return ok == true
end

--- Stock UpdateEnabledState skips tint reset when iconType is USE_EMPTY_ICON and the
--- slot is disabled - our forceGrey tint then sticks on Blank-Action-Bar-Icon-Slot
--- after Harvest/Brew is dragged away. WarTriage only tints current macro slots and
--- does not hook UpdateEnabledState, so it rarely leaves this residue.
local function restoreVacatedMacroSlot(button)
    if not button then
        return
    end
    resetMacroIconTint(button)
    clearHarvestGameActionForButton(button)
    clearBrewGameActionForButton(button)
end

local function bindBrewGameAction(button)
    if not button or not button.m_Name or WindowSetGameActionData == nil then
        return false
    end
    local actionName = button.m_Name .. "Action"
    if not DoesWindowExist(actionName) then
        return false
    end
    local ok = TryCall(
        "WindowSetGameActionData", WindowSetGameActionData,
        actionName,
        PerformCraftingAction(),
        ApothecaryTradeSkill(),
        L""
    )
    return ok == true
end

local function bindBrewGameActionForButton(button, opts)
    opts = type(opts) == "table" and opts or {}
    if not button then
        return false
    end
    if opts.force ~= true and GameActionAlreadyBound(button, "brew") then
        return true
    end
    if button.m_Name and bindBrewGameAction(button) then
        RememberGameActionBind(button, "brew")
        return true
    end
    if type(button.GetName) == "function" then
        local actionName = button:GetName() .. "Action"
        if WindowSetGameActionData and DoesWindowExist(actionName) then
            local ok = TryCall(
                "WindowSetGameActionData", WindowSetGameActionData,
                actionName,
                PerformCraftingAction(),
                ApothecaryTradeSkill(),
                L""
            )
            if ok == true then
                RememberGameActionBind(button, "brew")
            end
            return ok == true
        end
    end
    return false
end

function Macro.IsMacroButton(button)
    if not button or button.m_ActionType ~= GameData.PlayerActions.DO_MACRO then
        return false
    end
    local macroId = Macro.GetMacroId()
    return macroId ~= nil and button.m_ActionId == macroId
end

function Macro.IsBrewMacroButton(button)
    if not button or button.m_ActionType ~= GameData.PlayerActions.DO_MACRO then
        return false
    end
    local macroId = Macro.GetBrewMacroId()
    return macroId ~= nil and button.m_ActionId == macroId
end

--- Fire PERFORM_CRAFTING via a placed Harvest macro Action window.
function Macro.FireHarvestGameAction()
    if type(WindowGameAction) ~= "function" or not ActionBars or not ActionBars.BarAndButtonIdFromSlot then
        return false
    end
    local function tryButton(button)
        if not button or not button.m_Name then
            return false
        end
        local actionName = button.m_Name .. "Action"
        if not DoesWindowExist(actionName) then
            return false
        end
        if not bindHarvestGameActionForButton(button, { force = true }) then
            return false
        end
        local ok = TryCall("WindowGameAction", WindowGameAction, actionName)
        return ok == true
    end
    local macroId = Macro.GetMacroId()
    if not macroId then
        return false
    end
    local slots = Macro.GetMacroSlots(macroId) or {}
    for i = 1, #slots do
        local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(slots[i])
        local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
        if tryButton(button) then
            return true
        end
    end
    return false
end

local function clearPickupIfMouse(flags)
    if SystemData and SystemData.ButtonFlags
        and flags ~= SystemData.ButtonFlags.GAME_ACTION
        and ActionBars and ActionBars.SetPickupButton
    then
        ActionBars:SetPickupButton(nil)
    end
end

function Macro.ApplyButtonAppearance(button, opts)
    if not button then
        return
    end
    opts = opts or {}
    local canUse = opts.canUse
    if canUse == nil then
        canUse = canHarvestMacro()
    else
        canUse = canUse == true
    end
    setButtonEnabledVisual(button, canUse)
    if canUse then
        bindHarvestGameActionForButton(button)
    else
        clearHarvestGameActionForButton(button)
    end
end

function Macro.ApplyBrewButtonAppearance(button, opts)
    if not button then
        return
    end
    opts = opts or {}
    local canUse = opts.canUse
    if canUse == nil then
        canUse = canBrewMacro()
    else
        canUse = canUse == true
    end
    setButtonEnabledVisual(button, canUse)
    -- Match Harvest: clear craft bind when disabled or the hotbar stays lit.
    -- Activation uses Lua FirePerform; rebind when enabled for chrome.
    if canUse then
        bindBrewGameActionForButton(button)
    else
        clearBrewGameActionForButton(button)
    end
end

--- Coalesce hotbar enable sync (footer/cultivation storms). Drain via DrainEnabledSync.
function Macro.RequestEnabledSync(canHarvest, canBrew)
    Macro._enabledSyncPending = true
    if canHarvest ~= nil then
        Macro._pendingCanHarvest = canHarvest == true
    end
    if canBrew ~= nil then
        Macro._pendingCanBrew = canBrew == true
    end
end

--- Apply pending RequestEnabledSync once (EngineEventBridge.OnUpdateProcessed).
function Macro.DrainEnabledSync()
    if Macro._enabledSyncPending ~= true then
        return
    end
    Macro._enabledSyncPending = false
    local opts = {}
    if Macro._pendingCanHarvest ~= nil then
        opts.canHarvest = Macro._pendingCanHarvest
        Macro._pendingCanHarvest = nil
    end
    if Macro._pendingCanBrew ~= nil then
        opts.canBrew = Macro._pendingCanBrew
        Macro._pendingCanBrew = nil
    end
    Macro.RefreshMacroButtonAppearance(opts)
end

function Macro.RefreshMacroButtonAppearance(opts)
    opts = type(opts) == "table" and opts or {}
    if Macro._refreshingAppearance == true then
        Macro._appearanceDirty = true
        if opts.canHarvest ~= nil then
            Macro._pendingCanHarvest = opts.canHarvest == true
        end
        if opts.canBrew ~= nil then
            Macro._pendingCanBrew = opts.canBrew == true
        end
        return
    end
    if not ActionBars or not ActionBars.m_Bars then
        return
    end

    local canHarvest = opts.canHarvest
    if canHarvest == nil then
        canHarvest = canHarvestMacro()
    else
        canHarvest = canHarvest == true
    end
    local canBrew = opts.canBrew
    if canBrew == nil then
        canBrew = canBrewMacro()
    else
        canBrew = canBrew == true
    end
    local appearanceKey = tostring(canHarvest) .. ":" .. tostring(canBrew)
    if Macro._lastAppearanceKey == appearanceKey then
        return
    end

    local prevKey = Macro._lastAppearanceKey
    local applyHarvest = true
    local applyBrew = true
    if type(prevKey) == "string" then
        local ph, pb = string.match(prevKey, "^([^:]+):([^:]+)$")
        if ph ~= nil and pb ~= nil then
            applyHarvest = tostring(canHarvest) ~= ph
            applyBrew = tostring(canBrew) ~= pb
            if not applyHarvest and not applyBrew then
                applyHarvest = true
                applyBrew = true
            end
        end
    end

    local Perf = StockPiler3.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Macro.Appearance")
    end
    Macro._refreshingAppearance = true
    local ok, err = pcall(function()
        Macro._lastAppearanceKey = appearanceKey
        -- Forced wants for UpdateEnabledState hook (avoid re-CanBrewNow per button).
        Macro._refreshCanHarvest = canHarvest
        Macro._refreshCanBrew = canBrew

        local macroId = Macro.GetMacroId()
        local brewId = Macro.GetBrewMacroId()
        local harvestOpts = { canUse = canHarvest }
        local brewOpts = { canUse = canBrew }

        if applyHarvest and macroId then
            local slots = CachedSlotsForMacro(macroId)
            if #slots == 0 then
                if not Macro.MacroWarningState.unplaced then
                    Print(T("macro.harvest_unplaced", { icon = tostring(MACRO_ICON) }))
                    Macro.MacroWarningState.unplaced = true
                end
            else
                Macro.MacroWarningState.unplaced = false
                for i = 1, #slots do
                    local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(slots[i])
                    local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
                    if button then
                        Macro.ApplyButtonAppearance(button, harvestOpts)
                    end
                end
            end
        end

        if applyBrew and brewId then
            local slots = CachedSlotsForMacro(brewId)
            if #slots == 0 then
                if not Macro.BrewMacroWarningState.unplaced then
                    Print(T("macro.brew_unplaced", { icon = tostring(BREW_MACRO_ICON) }))
                    Macro.BrewMacroWarningState.unplaced = true
                end
            else
                Macro.BrewMacroWarningState.unplaced = false
                for i = 1, #slots do
                    local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(slots[i])
                    local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
                    if button then
                        Macro.ApplyBrewButtonAppearance(button, brewOpts)
                    end
                end
            end
        end
        RememberSlotFingerprint()
    end)
    Macro._refreshingAppearance = false
    Macro._refreshCanHarvest = nil
    Macro._refreshCanBrew = nil
    if Perf and Perf.End then
        Perf.End("Macro.Appearance")
    end
    if ok ~= true then
        D("refresh failed: " .. tostring(err))
    end
    if Macro._appearanceDirty == true then
        Macro._appearanceDirty = false
        -- Keep _lastAppearanceKey; key check no-ops if can-state unchanged.
        local dirtyOpts = {}
        if Macro._pendingCanHarvest ~= nil then
            dirtyOpts.canHarvest = Macro._pendingCanHarvest
            Macro._pendingCanHarvest = nil
        end
        if Macro._pendingCanBrew ~= nil then
            dirtyOpts.canBrew = Macro._pendingCanBrew
            Macro._pendingCanBrew = nil
        end
        Macro.RefreshMacroButtonAppearance(dirtyOpts)
    end
end

--- Queue hotbar enable sync (coalesced). Prefer RequestEnabledSync from callers.
function Macro.SyncEnabledState(canHarvest, canBrew)
    Macro.RequestEnabledSync(canHarvest, canBrew)
end

local function applySetActionDataAppearance(button, actionType, actionId)
    if not button then
        return
    end
    if actionType ~= GameData.PlayerActions.DO_MACRO then
        return
    end
    local harvestId = Macro.GetMacroId()
    local brewId = Macro.GetBrewMacroId()
    if harvestId ~= nil and actionId == harvestId then
        Macro.ApplyButtonAppearance(button)
        return
    end
    if brewId ~= nil and actionId == brewId then
        Macro.ApplyBrewButtonAppearance(button)
    end
end

local function installSetActionDataHook()
    if not ActionButton or type(ActionButton.SetActionData) ~= "function" then
        return
    end
    if setActionDataHooked then
        return
    end
    local orgSetActionData = ActionButton.SetActionData
    ActionButton.SetActionData = function(self, actionType, actionId)
        local wasOurs = Macro.IsMacroButton(self) or Macro.IsBrewMacroButton(self)
        orgSetActionData(self, actionType, actionId)
        local isOurs = Macro.IsMacroButton(self) or Macro.IsBrewMacroButton(self)
        if wasOurs and not isOurs then
            restoreVacatedMacroSlot(self)
            return
        end
        applySetActionDataAppearance(self, actionType, actionId)
    end
    setActionDataHooked = true
end

--- Engine ActionBars.UpdateSlotEnabledState / SetActionData re-enable DO_MACRO slots
--- after SP2 greys them. Appearance-key early-out then skips re-apply until Harvest
--- readiness flips - Brew stays lit while footer is correctly grey. Force SP2
--- readiness on every UpdateEnabledState for our macros.
local function installUpdateEnabledStateHook()
    if not ActionButton or type(ActionButton.UpdateEnabledState) ~= "function" then
        return
    end
    if updateEnabledStateHooked then
        return
    end
    local orgUpdateEnabledState = ActionButton.UpdateEnabledState
    ActionButton.UpdateEnabledState = function(self, isSlotEnabled, isTargetValid, isBlocked)
        local forced = false
        local want = false
        if Macro.IsBrewMacroButton(self) then
            forced = true
            if Macro._refreshingAppearance == true and Macro._refreshCanBrew ~= nil then
                want = Macro._refreshCanBrew == true
            else
                want = canBrewMacro()
            end
        elseif Macro.IsMacroButton(self) then
            forced = true
            if Macro._refreshingAppearance == true and Macro._refreshCanHarvest ~= nil then
                want = Macro._refreshCanHarvest == true
            else
                want = canHarvestMacro()
            end
        end
        if forced then
            isSlotEnabled = want
            isTargetValid = true
            isBlocked = false
        end
        orgUpdateEnabledState(self, isSlotEnabled, isTargetValid, isBlocked)
        if forced and want ~= true then
            forceGreyMacroIcon(self)
        end
    end
    updateEnabledStateHooked = true
end

local function handleMacroHarvestActivation(flags)
    if Cursor and Cursor.IconOnCursor and Cursor.IconOnCursor() then
        return "cursor"
    end
    local Grow = StockPiler3.Grow
    if not (Grow and Grow.CanHarvestNow) or Grow.CanHarvestNow() ~= true then
        clearPickupIfMouse(flags)
        return "blocked"
    end
    if Grow and Grow.PrepareHarvestPlot then
        if Grow.PrepareHarvestPlot(true) ~= true then
            clearPickupIfMouse(flags)
            return "blocked"
        end
    end
    return "go"
end

local function handleMacroBrewActivation(flags)
    if Cursor and Cursor.IconOnCursor and Cursor.IconOnCursor() then
        return "cursor"
    end
    if not canBrewMacro() then
        clearPickupIfMouse(flags)
        return "blocked"
    end
    if not (StockPiler3.Brew and StockPiler3.Brew.TryBrewClick) then
        clearPickupIfMouse(flags)
        return "blocked"
    end
    local result = StockPiler3.Brew.TryBrewClick()
    if result == "go" then
        return "go"
    end
    clearPickupIfMouse(flags)
    return "blocked"
end

local function installActionButtonHooks()
    if actionButtonHooksInstalled or not ActionButton then
        return
    end

    local orgOnLButtonUp = ActionButton.OnLButtonUp
    ActionButton.OnLButtonUp = function(self, flags, x, y)
        if Macro.IsMacroButton(self) then
            if not canHarvestMacro() then
                clearHarvestGameActionForButton(self)
                clearPickupIfMouse(flags)
                return
            end
            bindHarvestGameActionForButton(self, { force = true })
            local result = handleMacroHarvestActivation(flags)
            if result == "cursor" or result == "go" then
                if orgOnLButtonUp then
                    orgOnLButtonUp(self, flags, x, y)
                end
                return
            end
            if result == "blocked" then
                return
            end
        elseif Macro.IsBrewMacroButton(self) then
            local result = handleMacroBrewActivation(flags)
            if result == "cursor" then
                if orgOnLButtonUp then
                    orgOnLButtonUp(self, flags, x, y)
                end
                return
            end
            if result == "go" then
                -- Suppress BrewClick if the engine also runs the macro script this frame.
                Macro._brewFired = true
                Macro._brewFiredAt = (type(GetGameTime) == "function" and tonumber(GetGameTime())) or 0
                if StockPiler3.Brew and StockPiler3.Brew.FirePerform then
                    StockPiler3.Brew.FirePerform()
                end
                return
            end
            if result == "blocked" then
                return
            end
        end
        if orgOnLButtonUp then
            orgOnLButtonUp(self, flags, x, y)
        end
    end

    actionButtonHooksInstalled = true
end

local function installMacroTooltipHook()
    if tooltipHookInstalled or not Tooltips or type(Tooltips.CreateMacroTooltip) ~= "function" then
        return
    end
    local orgCreateMacroTooltip = Tooltips.CreateMacroTooltip
    Tooltips.CreateMacroTooltip = function(macroData, mouseoverWindow, anchor, extraText)
        local harvestId = Macro.GetMacroId()
        local brewId = Macro.GetBrewMacroId()
        local isHarvest = false
        local isBrew = false
        if type(macroData) == "table" then
            if harvestId and (macroData.slot == harvestId or macroData.index == harvestId or macroData.macroIndex == harvestId) then
                isHarvest = true
            elseif macroData.name == MACRO_NAME or MacroText(macroData) == MACRO_TEXT then
                isHarvest = true
            end
            if brewId and (macroData.slot == brewId or macroData.index == brewId or macroData.macroIndex == brewId) then
                isBrew = true
            elseif macroData.name == BREW_MACRO_NAME or MacroText(macroData) == BREW_MACRO_TEXT then
                isBrew = true
            end
        end
        if isHarvest then
            if StockPiler3.HarvestTooltip and StockPiler3.HarvestTooltip.Show then
                StockPiler3.HarvestTooltip.Show(mouseoverWindow, anchor or Tooltips.ANCHOR_WINDOW_TOP)
            end
            return
        end
        if isBrew then
            if StockPiler3.BrewTooltip and StockPiler3.BrewTooltip.Show then
                StockPiler3.BrewTooltip.Show(mouseoverWindow, anchor or Tooltips.ANCHOR_WINDOW_TOP)
            end
            return
        end
        return orgCreateMacroTooltip(macroData, mouseoverWindow, anchor, extraText)
    end
    tooltipHookInstalled = true
end

function Macro.OnHotBarUpdated()
    -- ApplyButtonAppearance / WindowSetGameActionData can fire this event while
    -- we refresh. Ignoring those echoes stops Macro.Appearance xN under trail hold.
    if Macro._refreshingAppearance == true then
        return
    end
    -- Rescan bars for fingerprint; only clear bind cache when slots actually moved.
    InvalidateSlotCache()
    local fp = SlotFingerprint()
    -- Unrelated hotbar noise must not wipe appearance key / force Begin - that
    -- was Macro.Appearance x67 storms under trail hold (0.4.23 uilog).
    if Macro._lastSlotFingerprint == fp then
        return
    end
    ClearGameActionBindCache()
    Macro._lastSlotFingerprint = fp
    Macro._lastAppearanceKey = nil
    if Macro._enabledSyncPending == true then
        return
    end
    Macro.RequestEnabledSync()
end

function Macro.RegisterHotbarEventHandler()
    if hotbarEventRegistered or not SystemData or not SystemData.Events then
        return
    end
    if SystemData.Events.PLAYER_HOT_BAR_UPDATED then
        RegisterEventHandler(SystemData.Events.PLAYER_HOT_BAR_UPDATED, "StockPiler3.Macro.OnHotBarUpdated")
        hotbarEventRegistered = true
    end
end

function Macro.UnregisterHotbarEventHandler()
    if not hotbarEventRegistered or not SystemData or not SystemData.Events then
        return
    end
    if SystemData.Events.PLAYER_HOT_BAR_UPDATED then
        UnregisterEventHandler(SystemData.Events.PLAYER_HOT_BAR_UPDATED, "StockPiler3.Macro.OnHotBarUpdated")
    end
    hotbarEventRegistered = false
end

function Macro.HarvestClick()
    local Grow = StockPiler3.Grow
    if not Grow then
        return
    end
    if Grow.CanHarvestNow and Grow.CanHarvestNow() ~= true then
        return
    end
    if Grow.PrepareHarvestPlot and Grow.PrepareHarvestPlot(true) ~= true then
        return
    end
    if Macro.FireHarvestGameAction() then
        return
    end
    -- Fallback when no bar slot / Action bind failed (Grow.FireHarvestAction never existed).
    if StockPiler3.HarvestChrome and StockPiler3.HarvestChrome.FireHarvestAction then
        StockPiler3.HarvestChrome.FireHarvestAction()
        return
    end
    if Grow.HarvestClick then
        Grow.HarvestClick()
    end
end

function Macro.BrewClick()
    Macro.ExpireBrewFiredGuard()
    if Macro._brewFired == true then
        Macro._brewFired = false
        Macro._brewFiredAt = nil
        return
    end
    if not canBrewMacro() then
        return
    end
    local Brew = StockPiler3.Brew
    if not Brew or not Brew.TryBrewClick then
        return
    end
    local result = Brew.TryBrewClick()
    if result == "go" and Brew.FirePerform then
        Brew.FirePerform()
    end
end

--- Drop sticky _brewFired if BrewClick never ran after OnLButtonUp FirePerform.
function Macro.ExpireBrewFiredGuard()
    if Macro._brewFired ~= true then
        return
    end
    local at = tonumber(Macro._brewFiredAt) or 0
    local now = (type(GetGameTime) == "function" and tonumber(GetGameTime())) or 0
    if at <= 0 or now <= 0 or (now - at) >= 0.25 then
        Macro._brewFired = false
        Macro._brewFiredAt = nil
    end
end

function Macro.Initialize()
    if Macro._initialized then
        Macro.UpdateMacro()
        Macro.UpdateBrewMacro()
        Macro.RefreshMacroButtonAppearance()
        return
    end
    installSetActionDataHook()
    installUpdateEnabledStateHook()
    installActionButtonHooks()
    installMacroTooltipHook()
    Macro.UpdateMacro()
    Macro.UpdateBrewMacro()
    Macro.RegisterHotbarEventHandler()
    Macro.RefreshMacroButtonAppearance()
    Macro._initialized = true
    D("Initialize harvestId=" .. tostring(Macro.GetMacroId())
        .. " brewId=" .. tostring(Macro.GetBrewMacroId()))
end

function Macro.Shutdown()
    Macro.UnregisterHotbarEventHandler()
    Macro._initialized = false
end
