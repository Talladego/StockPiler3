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
    return DoesWindowExist(name) and WindowGetShowing(name) == true
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

--- Engine reports no usable chance (incomplete / cleared mats). Distinct from LOW.
function AA.SuccessChanceInvalid()
    local CSC = GameData and GameData.CraftingSuccessChance
    if type(CSC) ~= "table" or CSC.INVALID == nil then
        return false
    end
    return AA.SuccessChance() == CSC.INVALID
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

--- Board empty and engine wants a container (SP2 SessionReadyToFill).
function AA.SessionReadyToFill()
    if AA.ServerHasItems() then
        return false
    end
    local containerSlot = (ApothecaryWindow and ApothecaryWindow.SLOT_CONTAINER) or 0
    if AA.GetSlottedItem(containerSlot) ~= nil then
        return false
    end
    local cs = GameData and GameData.CraftingStates
    if cs == nil then
        return AA.IsCraftingSessionActive()
    end
    return AA.CraftingState() == cs.ADDCONTAINER
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

function AA.HideWindowOnly()
    local name = AA.WindowName()
    if DoesWindowExist(name) and WindowGetShowing(name) then
        TryCall("WindowSetShowing", WindowSetShowing, name, false)
        if type(WindowUtils) == "table" and type(WindowUtils.RemoveFromOpenList) == "function" then
            TryQuiet("RemoveFromOpenList", WindowUtils.RemoveFromOpenList, name)
        end
        return true
    end
    return false
end

--- Open apo crafting session (prefer headless / stealth when possible).
function AA.OpenWindow(session)
    session = type(session) == "table" and session or nil
    if AA.IsWindowOpen() then
        if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
            TryQuiet("SetCurrentTradeSkill", CraftingSystem.SetCurrentTradeSkill, AA.TradeSkill())
        end
        return true
    end
    if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
        TryQuiet("SetCurrentTradeSkill", CraftingSystem.SetCurrentTradeSkill, AA.TradeSkill())
    end
    if CraftingSystem and type(CraftingSystem.SetStaticData) == "function" then
        TryQuiet("SetStaticData", CraftingSystem.SetStaticData)
    end
    if type(SendInitCrafting) == "function" then
        TryCall("SendInitCrafting", SendInitCrafting, AA.TradeSkill())
    end
    AA.SetSoftLocks(true)
    if session then
        session._idleForceClosed = false
        session._brewOwnedSession = true
        session._brewApoStealth = true
    end
    AA.HideWindowOnly()
    if AA.CraftingSkillType() == AA.TradeSkill() then
        return true
    end
    if not (CraftingSystem and type(CraftingSystem.ToggleShowing) == "function") then
        return AA.CraftingSkillType() == AA.TradeSkill()
    end
    TryCall("CraftingSystem.ToggleShowing", CraftingSystem.ToggleShowing, AA.TradeSkill())
    if AA.CraftingSkillType() ~= AA.TradeSkill() and not AA.IsWindowOpen() then
        return false
    end
    if session then
        session._idleForceClosed = false
        session._brewOwnedSession = true
        session._brewOpenedApo = true
        session._brewApoStealth = true
    end
    AA.HideWindowOnly()
    return true
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

    if session then
        session._brewOpenedApo = false
        session._brewOpenedBackpack = false
        session._brewOwnedSession = false
        session._brewApoStealth = false
    end

    local endEngine = ownedSession or stealth or closeApo
        or (apoSkillActive == true and not playerVisible)
    if not endEngine then
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
    if DoesWindowExist(name) then
        TryCall("WindowSetShowing", WindowSetShowing, name, false)
        if type(WindowUtils) == "table" and type(WindowUtils.RemoveFromOpenList) == "function" then
            TryQuiet("RemoveFromOpenList", WindowUtils.RemoveFromOpenList, name)
        end
    end
end

function AA.AddItemToCrafting(craftSlot, bagSlot, bagType)
    craftSlot = tonumber(craftSlot)
    bagSlot = tonumber(bagSlot) or 0
    if bagSlot <= 0 or type(AddCraftingItem) ~= "function" then
        return false
    end
    -- Container slot 0 uses AddCraftingContainer when available.
    if craftSlot == 0 or craftSlot == nil then
        if type(AddCraftingContainer) == "function" then
            return TryCall(
                "AddCraftingContainer",
                AddCraftingContainer,
                AA.TradeSkill(),
                bagSlot,
                bagType or AA.CraftingBackpackType()
            ) == true
        end
        craftSlot = 0
    end
    return TryCall(
        "AddCraftingItem",
        AddCraftingItem,
        AA.TradeSkill(),
        craftSlot,
        bagSlot,
        bagType or AA.CraftingBackpackType()
    ) == true
end

function AA.AddContainer(bagSlot, bagType)
    return AA.AddItemToCrafting(0, bagSlot, bagType)
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
