----------------------------------------------------------------
-- StockPiler3 Adapters/ApothecaryAdapter - open/load/perform/close
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.ApothecaryAdapter = StockPiler3.ApothecaryAdapter or {}
local AA = StockPiler3.ApothecaryAdapter

local function TryCall(label, fn, ...)
    return StockPiler3.Util.TryCall(label, fn, ...)
end

local function TryQuiet(label, fn, ...)
    return StockPiler3.Util.TryCallQuiet(label, fn, ...)
end

local function RemoveEntry(apo, slot, backpack, seen)
    if slot == nil or backpack == nil then
        return false
    end
    local key = tostring(backpack) .. ":" .. tostring(slot)
    if type(seen) == "table" then
        if seen[key] then
            return false
        end
        seen[key] = true
    end
    if type(RemoveCraftingItem) == "function" then
        TryCall("RemoveCraftingItem", RemoveCraftingItem, apo, slot, backpack)
        return true
    end
    return false
end

function AA.TradeSkill()
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.ApothecaryId then
        return Caps.ApothecaryId()
    end
    return 4
end

function AA.CraftingBackpackType()
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING then
        return EA_Window_Backpack.TYPE_CRAFTING
    end
    return 4
end

function AA.WindowName()
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.windowName) == "string" then
        return ApothecaryWindow.windowName
    end
    return "ApothecaryWindow"
end

function AA.IsWindowOpen()
    local name = AA.WindowName()
    return type(DoesWindowExist) == "function"
        and DoesWindowExist(name)
        and WindowGetShowing(name) == true
end

function AA.GetCraftingStatus()
    if not GameData or not GameData.CraftingStatus then
        return { state = -1, skillType = -1, successChance = -1 }
    end
    return {
        state = tonumber(GameData.CraftingStatus.State) or -1,
        skillType = tonumber(GameData.CraftingStatus.SkillType) or -1,
        -- Same field ApothecaryWindow.SetStabilityState uses (HIGH/MEDIUM/LOW).
        successChance = tonumber(GameData.CraftingStatus.SuccessChance) or -1,
    }
end

function AA.CraftingState()
    return AA.GetCraftingStatus().state
end

function AA.CraftingSkillType()
    return AA.GetCraftingStatus().skillType
end

function AA.SuccessChance()
    return AA.GetCraftingStatus().successChance
end

--- Stock red hint: TEXT_CRAFTING_HINT_WILL_DEFINITELY_FAIL (SuccessChance == LOW).
function AA.WillDefinitelyFail()
    local CSC = GameData and GameData.CraftingSuccessChance
    if type(CSC) ~= "table" or CSC.LOW == nil then
        return false
    end
    return AA.SuccessChance() == CSC.LOW
end

--- HIGH or MEDIUM only. LOW = definite fail; INVALID = incomplete / stale after mat change.
function AA.SuccessChanceAllowsPerform()
    local CSC = GameData and GameData.CraftingSuccessChance
    if type(CSC) ~= "table" then
        return true
    end
    local chance = AA.SuccessChance()
    return chance == CSC.HIGH or chance == CSC.MEDIUM
end

--- States where stock UI shows a brewable board (not NEED_* / FAIL / PERFORMING).
function AA.IsBrewableCraftState()
    local cs = GameData and GameData.CraftingStates
    if type(cs) ~= "table" then
        return AA.ServerHasItems() == true
    end
    local state = AA.CraftingState()
    return state == cs.VALID_RECIPE or state == cs.SUCCESS_REPEAT
end

--- Stock UI bug: SetStabilityState rejects SuccessChance < LOW, so INVALID(0) leaves
--- ApothecaryWindow.stabilityCurrentState stuck on the previous (often HIGH/green) value.
--- Returns true when the painted cache disagrees with the live engine field.
function AA.UiStabilityDesync()
    if type(ApothecaryWindow) ~= "table" then
        return false
    end
    local painted = tonumber(ApothecaryWindow.stabilityCurrentState)
    local live = AA.SuccessChance()
    if painted == nil or live < 0 then
        return false
    end
    return painted ~= live
end

--- Stealth brew keeps the apo window hidden; readiness is skill session, not WindowGetShowing.
function AA.IsCraftingSessionActive()
    return AA.CraftingSkillType() == AA.TradeSkill()
end

function AA.IsPerforming()
    if type(ApothecaryWindow) == "table" and ApothecaryWindow.STATE_PERFORMING then
        if ApothecaryWindow.currentState == ApothecaryWindow.STATE_PERFORMING then
            return true
        end
    end
    if GameData and GameData.CraftingStates and GameData.CraftingStates.PERFORMING then
        return AA.CraftingSkillType() == AA.TradeSkill()
            and AA.CraftingState() == GameData.CraftingStates.PERFORMING
    end
    return type(ApothecaryWindow) == "table" and ApothecaryWindow.PerformingLock == true
end

function AA.SetSoftLocks(enabled)
    if type(EA_BackpackUtilsMediator) == "table"
        and type(EA_BackpackUtilsMediator.EnableSoftLocks) == "function"
    then
        TryQuiet("EnableSoftLocks", EA_BackpackUtilsMediator.EnableSoftLocks, enabled == true)
    elseif type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.EnableSoftLocks) == "function"
    then
        TryQuiet("EA_Window_Backpack.EnableSoftLocks", EA_Window_Backpack.EnableSoftLocks, enabled == true)
    end
end

function AA.ReleaseBackpackLocks()
    local name = AA.WindowName()
    if type(EA_BackpackUtilsMediator) == "table"
        and type(EA_BackpackUtilsMediator.ReleaseAllLocksForWindow) == "function"
    then
        TryCall("ReleaseAllLocksForWindow", EA_BackpackUtilsMediator.ReleaseAllLocksForWindow, name)
    elseif type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.ReleaseAllLocksForWindow) == "function"
    then
        TryCall("EA_Window_Backpack.ReleaseAllLocksForWindow", EA_Window_Backpack.ReleaseAllLocksForWindow, name)
    end
    AA.SetSoftLocks(false)
end

function AA.ClearSlots()
    local apo = AA.TradeSkill()
    local cleared = false
    local seen = {}
    if type(GetCraftingBackPackSlots) == "function" then
        local ok, slots = TryQuiet("GetCraftingBackPackSlots", GetCraftingBackPackSlots, apo)
        if ok and type(slots) == "table" then
            for index = 4, 0, -1 do
                local entry = slots[index]
                if type(entry) == "table" then
                    if RemoveEntry(apo, entry.slot, entry.backpack, seen) then
                        cleared = true
                    end
                end
            end
            for _, entry in pairs(slots) do
                if type(entry) == "table" then
                    if RemoveEntry(apo, entry.slot, entry.backpack, seen) then
                        cleared = true
                    end
                end
            end
        end
    end
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.craftingData) == "table"
        and type(RemoveCraftingItem) == "function"
    then
        for slotNum = 4, 0, -1 do
            local cd = ApothecaryWindow.craftingData[slotNum]
            if type(cd) == "table" and cd.sourceSlot and cd.sourceBackpack then
                if RemoveEntry(apo, cd.sourceSlot, cd.sourceBackpack, seen) then
                    cleared = true
                end
            end
        end
    end
    return cleared
end

-- Park the Apo root off-screen while SP3 owns brew. Do not hide widgets or
-- swallow WindowSetShowing: SkillType needs a real show, and SetStateData
-- re-shows bottles/slots independently of the frame. Do not eat the player
-- Apothecary ability (stock ToggleShowing).
local PARK_X = -4000
local PARK_Y = -4000

local function ApoRootName()
    return AA.WindowName()
end

local function CallOrigToggle(tradeSkill)
    local fn = AA._origToggleShowing
    if type(fn) ~= "function" and CraftingSystem and type(CraftingSystem.ToggleShowing) == "function" then
        fn = CraftingSystem.ToggleShowing
    end
    if type(fn) == "function" then
        TryCall("CraftingSystem.ToggleShowing", fn, tradeSkill)
        return true
    end
    return false
end

local function SetRootHandleInput(handle)
    if type(WindowSetHandleInput) ~= "function" then
        return
    end
    local name = ApoRootName()
    if DoesWindowExist and DoesWindowExist(name) then
        TryQuiet("WindowSetHandleInput", WindowSetHandleInput, name, handle == true)
    end
end

local function UnparkApoRoot()
    local name = ApoRootName()
    local wasParked = AA._apoParked == true
    AA._apoParked = false
    if not (DoesWindowExist and DoesWindowExist(name)) then
        return
    end
    -- Clearing anchors on every hide (player-closed stock Apo) can reopen at
    -- top-left. Only strip stealth park anchors.
    if wasParked and type(WindowClearAnchors) == "function" then
        TryQuiet("WindowClearAnchors", WindowClearAnchors, name)
    end
    SetRootHandleInput(true)
    if type(WindowSetAlpha) == "function" then
        TryQuiet("WindowSetAlpha", WindowSetAlpha, name, 1)
    end
    if type(WindowSetFontAlpha) == "function" then
        TryQuiet("WindowSetFontAlpha", WindowSetFontAlpha, name, 1)
    end
end

local function PlaceApoOnScreen()
    local name = ApoRootName()
    UnparkApoRoot()
    if not (DoesWindowExist and DoesWindowExist(name)) then
        return
    end
    local function CloseCallback()
        if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
            TryQuiet("SetCurrentTradeSkill", CraftingSystem.SetCurrentTradeSkill, AA.TradeSkill())
        end
        CallOrigToggle(AA.TradeSkill())
    end
    if type(WindowUtils) == "table" and type(WindowUtils.AddToOpenList) == "function" then
        local mode = WindowUtils.Cascade and WindowUtils.Cascade.MODE_AUTOMATIC
        TryQuiet("AddToOpenList", WindowUtils.AddToOpenList, name, CloseCallback, mode)
    elseif type(WindowAddAnchor) == "function" then
        TryQuiet("WindowAddAnchor", WindowAddAnchor, name, "center", "Root", "center", 0, 0)
    end
    if type(WindowForceProcessAnchors) == "function" then
        pcall(WindowForceProcessAnchors, name)
    end
end

function AA.UnparkApoRoot()
    UnparkApoRoot()
end

function AA.PlaceApoOnScreen()
    PlaceApoOnScreen()
end

function AA.ParkApoRoot()
    if AA._playerWantsApo == true then
        return false
    end
    local name = ApoRootName()
    if not (DoesWindowExist and DoesWindowExist(name)) then
        return false
    end
    if type(WindowClearAnchors) == "function" then
        TryQuiet("WindowClearAnchors", WindowClearAnchors, name)
    end
    if type(WindowAddAnchor) == "function" then
        TryQuiet("WindowAddAnchor", WindowAddAnchor, name, "topleft", "Root", "topleft", PARK_X, PARK_Y)
    end
    if type(WindowForceProcessAnchors) == "function" then
        pcall(WindowForceProcessAnchors, name)
    end
    SetRootHandleInput(false)
    if type(WindowUtils) == "table" and type(WindowUtils.RemoveFromOpenList) == "function" then
        TryQuiet("RemoveFromOpenList", WindowUtils.RemoveFromOpenList, name)
    end
    AA._apoParked = true
    return true
end

--- True while SP3 should ignore engine CRAFTING_SHOW_WINDOW echoes from SendInitCrafting.
local function EngineShowSuppressed()
    if AA._sp3Opening == true or AA._suppressEngineShow == true then
        return true
    end
    local untilT = tonumber(AA._suppressEngineShowUntil) or 0
    if untilT <= 0 then
        return false
    end
    local now = 0
    if type(GetGameTime) == "function" then
        now = tonumber(GetGameTime()) or 0
    end
    if now <= untilT then
        return true
    end
    AA._suppressEngineShowUntil = 0
    return false
end

local function ArmEngineShowSuppress(sec)
    AA._suppressEngineShow = true
    local now = 0
    if type(GetGameTime) == "function" then
        now = tonumber(GetGameTime()) or 0
    end
    AA._suppressEngineShowUntil = now + (tonumber(sec) or 2)
end

function AA.ClearEngineShowSuppress()
    AA._suppressEngineShow = false
    AA._suppressEngineShowUntil = 0
end

function AA.InstallStealthHooks()
    if CraftingSystem and type(CraftingSystem.ToggleShowing) == "function" and not AA._origToggleShowing then
        AA._origToggleShowing = CraftingSystem.ToggleShowing
        CraftingSystem.ToggleShowing = function(tradeSkill)
            local apo = AA.TradeSkill()
            local isApo = tradeSkill == nil or tradeSkill == apo
            -- Headless open: never run stock ShowCurrentWindow (on-screen + backpack).
            if isApo and EngineShowSuppressed() then
                return
            end
            -- Parked stealth brew: action-bar ability brings Apo on-screen.
            -- Do not treat late CRAFTING_SHOW_WINDOW echoes as player intent while suppressed.
            if isApo and AA._apoParked == true then
                AA._playerWantsApo = true
                AA.ClearEngineShowSuppress()
                PlaceApoOnScreen()
                local name = ApoRootName()
                if type(DoesWindowExist) == "function"
                    and DoesWindowExist(name)
                    and WindowGetShowing(name) == true
                then
                    return
                end
            end
            return AA._origToggleShowing(tradeSkill)
        end
    end
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.OnHidden) == "function" and not AA._origApoOnHidden then
        AA._origApoOnHidden = ApothecaryWindow.OnHidden
        ApothecaryWindow.OnHidden = function(...)
            AA._playerWantsApo = false
            UnparkApoRoot()
            return AA._origApoOnHidden(...)
        end
    end
end

function AA.BeginOwnedSession()
    AA.InstallStealthHooks()
end

function AA.EndStealthUi()
    AA._sp3Opening = false
    AA.ClearEngineShowSuppress()
    AA._playerWantsApo = false
    UnparkApoRoot()
end

--- Show Apo without stock ShowCurrentWindow side effects:
--- - AddToOpenList(MODE_AUTOMATIC) + Cascade.Resolve can close the vendor
---   (store is MODE_HIGHLANDER; overflow windows get Done/closeFunction)
--- - EA_BackpackUtilsMediator.ShowBackpack() opens bags the player left closed
--- Cultivation planting uses AddCraftingItem and never opens CultivationWindow,
--- which is why plant jobs do not disturb bag/vendor the same way.
local function ShowApoRootVisible()
    local name = ApoRootName()
    if not (DoesWindowExist and DoesWindowExist(name)) then
        return false
    end
    if WindowGetShowing(name) == true then
        return true
    end
    -- Direct show only. Apo XML OnShown clears the board; it does not join cascade.
    TryCall("WindowSetShowing", WindowSetShowing, name, true)
    return WindowGetShowing(name) == true
end

function AA.InitHeadlessSession()
    local apo = AA.TradeSkill()
    if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
        TryQuiet("SetCurrentTradeSkill", CraftingSystem.SetCurrentTradeSkill, apo)
    end
    if CraftingSystem and type(CraftingSystem.SetStaticData) == "function" then
        TryQuiet("SetStaticData", CraftingSystem.SetStaticData)
    end
    -- Park first so the required "real show" for SkillType never paints on-screen.
    AA.ParkApoRoot()
    ShowApoRootVisible()
    -- Prefer SendInitCrafting without ApothecaryWindow.Show: Show() enables soft
    -- locks that make AddCraftingItem no-op for mains/ingredients (container still
    -- works). Soft locks stay off for headless brew load.
    if type(SendInitCrafting) == "function" then
        TryCall("SendInitCrafting", SendInitCrafting, apo)
    elseif type(ApothecaryWindow) == "table" and type(ApothecaryWindow.Show) == "function" then
        TryQuiet("ApothecaryWindow.Show", ApothecaryWindow.Show)
    end
    AA.SetSoftLocks(false)
    -- Re-park: engine CRAFTING_SHOW_WINDOW / SetStateData can reset anchors.
    AA.ParkApoRoot()
end

function AA.HideWindowOnly()
    return AA.ParkApoRoot()
end

function AA.EnforceStealthHide(session)
    session = type(session) == "table" and session or nil
    if not session or session._brewOwnedSession ~= true then
        return false
    end
    if AA._playerWantsApo == true then
        return false
    end
    AA.BeginOwnedSession()
    if AA.IsWindowOpen() and AA.ParkApoRoot() then
        session._brewApoStealth = true
        return true
    end
    return false
end

--- Headless show (no cascade / backpack) so SkillType can stamp, then park
--- off-screen in the same call. Player ability still uses stock ToggleShowing
--- via InstallStealthHooks / PlaceApoOnScreen.
function AA.OpenWindow(session)
    session = type(session) == "table" and session or nil
    local apo = AA.TradeSkill()
    AA.BeginOwnedSession()
    AA._playerWantsApo = false
    if session then
        session._idleForceClosed = false
        session._brewOwnedSession = true
        session._brewApoStealth = false
    end

    -- Already stealth-active: do not re-show (OpenWindow retries must not flash).
    if AA.IsCraftingSessionActive() == true and AA._apoParked == true then
        if session then
            session._brewApoStealth = true
        end
        AA.ParkApoRoot()
        return true
    end

    ArmEngineShowSuppress(2.5)
    AA._sp3Opening = true
    AA.InitHeadlessSession()
    AA._sp3Opening = false
    if AA.IsWindowOpen() and AA.ParkApoRoot() and session then
        session._brewApoStealth = true
    end
    return AA.CraftingSkillType() == apo
end

function AA.CloseWindow(session)
    session = type(session) == "table" and session or nil
    local apo = AA.TradeSkill()
    local closeApo = session and session._brewOpenedApo == true
    local ownedSession = session and session._brewOwnedSession == true
    local stealth = session and session._brewApoStealth == true
    local playerVisible = AA.IsWindowOpen()
    local apoSkillActive = AA.CraftingSkillType() == apo

    AA.ClearSlots()
    AA.ReleaseBackpackLocks()
    AA.ClearEngineShowSuppress()

    if session then
        session._brewOpenedApo = false
        session._brewOpenedBackpack = false
        session._brewOwnedSession = false
        session._brewApoStealth = false
    end

    local endEngine = ownedSession or stealth or closeApo
        or (apoSkillActive == true and not playerVisible)
    if not endEngine then
        AA.EndStealthUi()
        return
    end

    if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
        TryQuiet("SetCurrentTradeSkill", CraftingSystem.SetCurrentTradeSkill, apo)
    end

    if type(ApothecaryWindow) == "table" then
        if type(ApothecaryWindow.Clear) == "function" then
            TryCall("ApothecaryWindow.Clear", ApothecaryWindow.Clear)
        end
        ApothecaryWindow.nextFreeSlot = 0
        ApothecaryWindow.PerformingLock = false
    end

    if type(SendCloseCrafting) == "function" then
        TryCall("SendCloseCrafting", SendCloseCrafting, apo)
    end

    AA.ReleaseBackpackLocks()

    local name = AA.WindowName()
    if type(DoesWindowExist) == "function" and DoesWindowExist(name) then
        TryCall("WindowSetShowing", WindowSetShowing, name, false)
        if type(WindowUtils) == "table" and type(WindowUtils.RemoveFromOpenList) == "function" then
            TryQuiet("RemoveFromOpenList", WindowUtils.RemoveFromOpenList, name)
        end
    end
    AA.EndStealthUi()
end

function AA.AddItemToCrafting(craftSlot, bagSlot, bagType)
    craftSlot = tonumber(craftSlot)
    bagSlot = tonumber(bagSlot) or 0
    if bagSlot <= 0 or type(AddCraftingItem) ~= "function" then
        return false
    end
    bagType = tonumber(bagType) or AA.CraftingBackpackType()
    -- Stock ApothecaryWindow.AddItem stamps clientSlotList before the engine
    -- call; without it AddCraftingItem often no-ops while pcall still succeeds.
    if type(ApothecaryWindow) == "table" then
        if type(ApothecaryWindow.clientSlotList) ~= "table" then
            ApothecaryWindow.clientSlotList = {}
        end
        if craftSlot ~= nil then
            ApothecaryWindow.clientSlotList[craftSlot] = {
                slot = bagSlot,
                backpack = bagType,
            }
        end
    end
    -- Container is slot 0 only. Nil craftSlot used to fall through to
    -- AddCraftingContainer and silently "succeed" for mains/stabs.
    if craftSlot == 0 then
        if type(AddCraftingContainer) == "function" then
            return TryCall(
                "AddCraftingContainer",
                AddCraftingContainer,
                AA.TradeSkill(),
                bagSlot,
                bagType
            ) == true
        end
    elseif craftSlot == nil then
        return false
    end
    -- Soft locks from ApothecaryWindow.Show / a prior container add make
    -- AddCraftingItem no-op for mains/ingredients while AddCraftingContainer
    -- still works. Only clear soft locks — ReleaseAllLocks mid-load can
    -- disturb the board (flask flicker) without helping the add.
    AA.SetSoftLocks(false)
    return TryCall(
        "AddCraftingItem",
        AddCraftingItem,
        AA.TradeSkill(),
        craftSlot,
        bagSlot,
        bagType
    ) == true
end

function AA.PerformCrafting()
    if type(PerformCrafting) ~= "function" then
        return false
    end
    -- Arm learn before the engine craft: SkillUp / macros call AA.Perform, not
    -- ApothecaryWindow.Perform (that hook never runs on this path).
    if StockPiler3.BrewLearn and StockPiler3.BrewLearn.BeginPendingCraft then
        pcall(StockPiler3.BrewLearn.BeginPendingCraft)
    end
    local ok = TryCall("PerformCrafting", PerformCrafting, AA.TradeSkill(), 1)
    if ok and type(ApothecaryWindow) == "table" then
        ApothecaryWindow.PerformingLock = true
    end
    return ok == true
end

-- Alias
function AA.Perform()
    return AA.PerformCrafting()
end

function AA.GetSlottedItem(craftingSlot)
    craftingSlot = tonumber(craftingSlot) or -1
    if craftingSlot < 0 then
        return nil
    end
    if type(GetCraftingBackPackSlots) == "function"
        and type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
    then
        local ok, slots = TryQuiet("GetCraftingBackPackSlots", GetCraftingBackPackSlots, AA.TradeSkill())
        if ok and type(slots) == "table" then
            local entry = slots[craftingSlot]
            if type(entry) == "table" and entry.slot and entry.backpack then
                local bag = EA_Window_Backpack.GetItemsFromBackpack(entry.backpack)
                local item = type(bag) == "table" and bag[entry.slot] or nil
                if type(item) == "table" and (tonumber(item.uniqueID) or 0) > 0 then
                    return item
                end
            end
        end
    end
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.craftingData) == "table" then
        local cd = ApothecaryWindow.craftingData[craftingSlot]
        if type(cd) == "table" then
            if cd.sourceSlot ~= nil and type(EA_Window_Backpack) == "table"
                and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
            then
                local bag = EA_Window_Backpack.GetItemsFromBackpack(cd.sourceBackpack or AA.CraftingBackpackType())
                local fromBag = type(bag) == "table" and bag[cd.sourceSlot] or nil
                if type(fromBag) == "table" and (tonumber(fromBag.uniqueID) or 0) > 0 then
                    return fromBag
                end
            end
            if (tonumber(cd.objectId) or 0) > 0 then
                return {
                    uniqueID = tonumber(cd.objectId) or 0,
                    iconNum = tonumber(cd.iconId) or 0,
                }
            end
        end
    end
    return nil
end

function AA.ReadBoard()
    local out = {}
    for slotNum = 0, 4 do
        out[slotNum] = AA.GetSlottedItem(slotNum)
    end
    return out
end

function AA.ServerHasItems()
    if type(GetCraftingData) == "function" then
        local ok, data = TryQuiet("GetCraftingData", GetCraftingData, AA.TradeSkill())
        if ok and type(data) == "table" then
            for slotNum = 0, 4 do
                local row = data[slotNum]
                if type(row) == "table" then
                    local id = tonumber(row.id) or tonumber(row.objectId) or tonumber(row.uniqueID) or 0
                    if id > 0 then
                        return true
                    end
                end
            end
        end
    end
    for slotNum = 0, 4 do
        if AA.GetSlottedItem(slotNum) ~= nil then
            return true
        end
    end
    return false
end
