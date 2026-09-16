----------------------------------------------------------------
-- StockPiler3 Knowledge/BrewLearn — capture apo board → StoreLearnedRecipeSpec
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.BrewLearn = StockPiler3.BrewLearn or {}
local BL = StockPiler3.BrewLearn

BL.CraftBonus = {
    STABILITY = 1,
    POWER = 2,
    DURATION = 3,
    MULTIPLIER = 4,
    CRAFTING_FAMILY = 5,
    EFFECT = 6,
    TYPE = 8,
    CRITICAL_CHANCE = 12,
    FAIL_CHANCE = 13,
    SPECIAL_CHANCE = 14,
}

BL._pendingCraft = nil

local function ToNarrow(value)
    if StockPiler3.Persistence and StockPiler3.Persistence.ToNarrow then
        return StockPiler3.Persistence.ToNarrow(value)
    end
    if type(value) == "wstring" and type(WStringToString) == "function" then
        return WStringToString(value) or ""
    end
    return tostring(value or "")
end

local function IsPotionType(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if GameData and GameData.ItemTypes and GameData.ItemTypes.POTION then
        return (itemData.type or itemData.itemType) == GameData.ItemTypes.POTION
    end
    return tonumber(itemData.type) == 31
end

local function StackSize(item)
    local n = tonumber(item.stackCount) or tonumber(item.Count) or 0
    if n < 1 then
        return 1
    end
    return n
end

local function MatResourceRole(resourceType, slotNum)
    resourceType = tonumber(resourceType) or 0
    if GameData and GameData.CraftingItemType then
        local cit = GameData.CraftingItemType
        if resourceType == cit.CONTAINER or resourceType == cit.CONTAINER_DYE then
            return "container"
        end
        if resourceType == cit.MAIN_INGREDIENT or resourceType == cit.PIGMENT then
            return "main"
        end
        if resourceType == cit.STABILIZER or resourceType == cit.GOLDWEED then
            return "stabilizer"
        end
        if resourceType == cit.EXTENDER then
            return "extender"
        end
        if resourceType == cit.MULTIPLIER then
            return "multiplier"
        end
        if resourceType == cit.STIMULANT then
            return "stimulant"
        end
    end
    if slotNum == 0 then
        return "container"
    end
    if slotNum == 1 then
        return "main"
    end
    return "ingredient"
end

local function AggregateMaterials(slots)
    local byKey = {}
    local list = {}
    if type(slots) ~= "table" then
        return list
    end
    for i = 1, #slots do
        local m = slots[i]
        if type(m) == "table" then
            local uid = tonumber(m.uniqueID) or 0
            if uid > 0 then
                local key = tostring(uid) .. ":" .. tostring(m.role or "ingredient")
                local row = byKey[key]
                if row == nil then
                    row = {
                        uniqueID = uid,
                        role = m.role or "ingredient",
                        perCraft = 0,
                        itemData = m.itemData,
                        name = m.name,
                        nameNarrow = m.nameNarrow,
                        iconNum = m.iconNum,
                    }
                    byKey[key] = row
                    list[#list + 1] = row
                end
                row.perCraft = (tonumber(row.perCraft) or 0) + (tonumber(m.perCraft) or 1)
            end
        end
    end
    return list
end

--- Materials rebuilt from a saved recipe — never invent a board-only fingerprint.
local function MaterialsFromSavedRecipe(recipe)
    local list = {}
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return list
    end
    local RS = StockPiler3.RecipeSpec
    if RS and RS.HydrateRecipeSlots then
        RS.HydrateRecipeSlots(recipe)
    end
    for i = 1, #recipe.slots do
        local slot = recipe.slots[i]
        if type(slot) == "table" then
            local spec = slot.spec
            if type(spec) ~= "table" and RS and RS.ResolveSlotSpec then
                spec = RS.ResolveSlotSpec(slot)
            end
            local uid = tonumber(slot.uniqueID) or tonumber(slot.uid) or 0
            if uid <= 0 and type(spec) == "table" then
                uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
            end
            if uid > 0 then
                list[#list + 1] = {
                    uniqueID = uid,
                    role = tostring(slot.role or slot.materialRole or "ingredient"),
                    perCraft = math.max(1, tonumber(slot.perCraft) or 1),
                    itemData = spec,
                    name = slot.name or (spec and spec.name),
                }
            end
        end
    end
    return AggregateMaterials(list)
end

local function SnapshotPotionCounts()
    local counts = {}
    local Inv = StockPiler3.Inventory
    if Inv and Inv.ForEachItem then
        Inv.ForEachItem(function(item)
            if IsPotionType(item) then
                local uid = tonumber(item.uniqueID) or 0
                if uid > 0 then
                    counts[uid] = (counts[uid] or 0) + StackSize(item)
                end
            end
        end)
    end
    return counts
end

local function DiffPotionOutputs(before, after)
    local outputs = {}
    after = type(after) == "table" and after or {}
    before = type(before) == "table" and before or {}
    local seen = {}
    for uid, count in pairs(after) do
        uid = tonumber(uid) or 0
        count = tonumber(count) or 0
        local prev = tonumber(before[uid]) or 0
        local delta = count - prev
        if uid > 0 and delta > 0 then
            seen[uid] = true
            local sample = nil
            if StockPiler3.Inventory and StockPiler3.Inventory.GetSample then
                sample = StockPiler3.Inventory.GetSample(uid)
            end
            outputs[#outputs + 1] = {
                uniqueID = uid,
                lastDelta = delta,
                crafts = delta,
                name = sample and sample.name,
                nameNarrow = ToNarrow(sample and sample.name),
                iconNum = sample and tonumber(sample.iconNum) or 0,
                itemData = sample,
            }
        end
    end
    return outputs
end

function BL.CaptureApothecaryMaterials()
    local AA = StockPiler3.ApothecaryAdapter
    local board = nil
    if AA and AA.ReadBoard then
        board = AA.ReadBoard()
    end
    if type(board) ~= "table" and type(ApothecaryWindow) == "table"
        and type(ApothecaryWindow.craftingData) == "table"
    then
        board = {}
        for slotNum = 0, 4 do
            local cd = ApothecaryWindow.craftingData[slotNum]
            if type(cd) == "table" and (tonumber(cd.objectId) or 0) > 0 then
                local itemData = nil
                if AA and AA.GetSlottedItem then
                    itemData = AA.GetSlottedItem(slotNum)
                end
                board[slotNum] = itemData or {
                    uniqueID = tonumber(cd.objectId) or 0,
                    iconNum = tonumber(cd.iconId) or 0,
                }
            end
        end
    end
    if type(board) ~= "table" then
        return nil
    end

    local slots = {}
    for slotNum = 0, 4 do
        local item = board[slotNum]
        if type(item) == "table" then
            local uid = tonumber(item.uniqueID) or 0
            if uid > 0 then
                local resourceType = 0
                if CraftingSystem and type(CraftingSystem.GetCraftingData) == "function" then
                    local ok, _, rt = pcall(CraftingSystem.GetCraftingData, item)
                    if ok then
                        resourceType = tonumber(rt) or 0
                    end
                end
                local role = MatResourceRole(resourceType, slotNum)
                slots[#slots + 1] = {
                    slot = slotNum,
                    uniqueID = uid,
                    role = role,
                    perCraft = 1,
                    itemData = item,
                    name = item.name,
                    nameNarrow = ToNarrow(item.name),
                    iconNum = tonumber(item.iconNum) or 0,
                }
                if StockPiler3.Items and StockPiler3.Items.StoreItem then
                    StockPiler3.Items.StoreItem(item, "mat")
                end
            end
        end
    end
    if #slots == 0 then
        return nil
    end
    return slots
end

local BOARD_SNAPSHOT_TTL_SEC = 45

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

--- Keep a soft board snapshot while the apo recipe is loaded (VALID), so instant
--- SUCCESS / bag-update / "You created" can still learn after the board clears.
function BL.RefreshBoardSnapshot()
    local slots = BL.CaptureApothecaryMaterials()
    if slots == nil then
        return false
    end
    local materials = AggregateMaterials(slots)
    local hasMain = false
    for i = 1, #materials do
        if materials[i].role == "main" then
            hasMain = true
            break
        end
    end
    if not hasMain then
        return false
    end
    BL._lastBoardMaterials = materials
    BL._lastBoardPotionCounts = SnapshotPotionCounts()
    BL._lastBoardAt = NowSec()
    return true
end

function BL.ArmPendingFromLastBoard()
    if type(BL._pendingCraft) == "table" then
        return true
    end
    if type(BL._lastBoardMaterials) ~= "table" then
        return false
    end
    local at = tonumber(BL._lastBoardAt) or 0
    local now = NowSec()
    if at > 0 and now > 0 and (now - at) > BOARD_SNAPSHOT_TTL_SEC then
        return false
    end
    local materials = BL._lastBoardMaterials
    local recipeKey = ""
    if StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.RecipeSpecKey then
        recipeKey = StockPiler3.RecipeSpec.RecipeSpecKey(materials) or ""
    end
    BL._pendingCraft = {
        materials = materials,
        recipeKey = recipeKey,
        potionCountsBefore = BL._lastBoardPotionCounts or {},
    }
    return true
end

function BL.BeginPendingCraft()
    local slots = BL.CaptureApothecaryMaterials()
    if slots == nil then
        -- Instant craft may clear the board before PERFORMING; keep last board if fresh.
        return BL.ArmPendingFromLastBoard() == true
    end
    local materials = AggregateMaterials(slots)
    local hasMain = false
    for i = 1, #materials do
        if materials[i].role == "main" then
            hasMain = true
            break
        end
    end
    if not hasMain then
        BL._pendingCraft = nil
        return false
    end
    local recipeKey = ""
    if StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.RecipeSpecKey then
        recipeKey = StockPiler3.RecipeSpec.RecipeSpecKey(materials) or ""
    end
    local potionCounts = SnapshotPotionCounts()
    BL._lastBoardMaterials = materials
    BL._lastBoardPotionCounts = potionCounts
    BL._lastBoardAt = NowSec()
    BL._pendingCraft = {
        materials = materials,
        recipeKey = recipeKey,
        potionCountsBefore = potionCounts,
    }
    return true
end

function BL.CompletePendingCraftLearn(opts)
    opts = type(opts) == "table" and opts or {}
    local pending = BL._pendingCraft
    if type(pending) ~= "table" or type(pending.materials) ~= "table" then
        BL._pendingCraft = nil
        return false
    end
    local outputs = {}
    if opts.failed ~= true then
        local after = SnapshotPotionCounts()
        outputs = DiffPotionOutputs(pending.potionCountsBefore, after)
    end
    local function NotifyBrewOutcome(msg)
        if StockPiler3.Debug and StockPiler3.Debug.Notify then
            StockPiler3.Debug.Notify(msg)
        elseif StockPiler3.Debug and StockPiler3.Debug.Print then
            StockPiler3.Debug.Print(msg)
        end
    end
    local function T(key, tokens)
        if StockPiler3.T then
            return StockPiler3.T(key, tokens)
        end
        return towstring(tostring(key or ""))
    end
    if #outputs > 0 then
        local CC = StockPiler3.CraftChatAdapter
        for i = 1, #outputs do
            local out = outputs[i]
            local delta = tonumber(out.lastDelta) or tonumber(out.crafts) or 1
            local name = out.name
            if name == nil or name == L"" then
                name = T("brew.potion_fallback")
            end
            local uid = tonumber(out.uniqueID) or 0
            if CC and CC.ItemLink and uid > 0 then
                name = CC.ItemLink(uid, name)
            end
            NotifyBrewOutcome(T("brew.outcome_ok", {
                name = name,
                count = tostring(delta),
            }))
        end
    elseif opts.failed == true then
        NotifyBrewOutcome(T("brew.outcome_fail", { name = T("brew.potion_fallback") }))
    end
    local RS = StockPiler3.RecipeSpec
    local ok = false
    -- SP3 brew session: learn only the exact watched/saved recipe, never a partial board.
    local Brew = StockPiler3.Brew
    local session = Brew and Brew.GetSession and Brew.GetSession() or nil
    local intendedKey = type(session) == "table" and tostring(session.recipeSpecKey or "") or ""
    local materials = pending.materials
    if intendedKey ~= "" and type(session) == "table" and type(session.recipe) == "table" then
        local exact = MaterialsFromSavedRecipe(session.recipe)
        if type(exact) == "table" and #exact > 0 then
            materials = exact
            pending.recipeKey = intendedKey
        end
    elseif intendedKey ~= "" and tostring(pending.recipeKey or "") ~= ""
        and tostring(pending.recipeKey) ~= intendedKey
    then
        -- Board snapshot drifted from the loaded recipe — do not register a new fingerprint.
        if StockPiler3.Debug and StockPiler3.Debug.LogOp then
            StockPiler3.Debug.LogOp("brewlearn", "reject board fingerprint != session recipe")
        end
        BL._pendingCraft = nil
        return false
    end
    if RS and RS.StoreLearnedRecipeSpec then
        ok = RS.StoreLearnedRecipeSpec(materials, outputs, {
            mainConsumed = opts.mainConsumed,
            failed = opts.failed == true,
        }) == true
    end
    BL._pendingCraft = nil
    return ok
end

function BL.OnCraftingUpdated()
    local AA = StockPiler3.ApothecaryAdapter
    local state = AA and AA.CraftingState and AA.CraftingState() or -1
    local States = GameData and GameData.CraftingStates
    if type(States) ~= "table" then
        return false
    end
    -- Soft-arm while a valid recipe sits on the board (before instant SUCCESS).
    if state == States.VALID_RECIPE or state == States.PERFORMING then
        BL.RefreshBoardSnapshot()
    end
    if state == States.PERFORMING then
        if type(BL._pendingCraft) ~= "table" then
            BL.BeginPendingCraft()
        end
        return false
    end
    if state == States.SUCCESS or state == States.SUCCESS_REPEAT or state == (States.DONE) then
        if type(BL._pendingCraft) ~= "table" then
            BL.ArmPendingFromLastBoard()
        end
        return BL.CompletePendingCraftLearn() == true
    end
    if state == States.FAIL then
        if type(BL._pendingCraft) ~= "table" then
            BL.ArmPendingFromLastBoard()
        end
        return BL.CompletePendingCraftLearn({ failed = true }) == true
    end
    return false
end

function BL.MarkInventoryCraftPollDue()
    BL._inventoryCraftPollDue = true
end

function BL.DrainInventoryCraftPoll()
    if BL._inventoryCraftPollDue ~= true then
        return false
    end
    BL._inventoryCraftPollDue = false
    if type(BL._pendingCraft) ~= "table" then
        BL.ArmPendingFromLastBoard()
    end
    if type(BL._pendingCraft) ~= "table" then
        return false
    end
    local pending = BL._pendingCraft
    local after = SnapshotPotionCounts()
    local before = pending.potionCountsBefore or {}
    local gained = false
    for uid, count in pairs(after) do
        if (tonumber(count) or 0) > (tonumber(before[uid]) or 0) then
            gained = true
            break
        end
    end
    if not gained then
        return false
    end
    return BL.CompletePendingCraftLearn() == true
end

function BL.MaybeCompletePendingCraftFromInventory()
    return BL.DrainInventoryCraftPoll()
end

--- Crafting chat "You created …" when SUCCESS state was skipped (instant brew).
--- Complete only if bag already gained; otherwise arm inventory poll.
function BL.OnCreatedChat(createdName)
    if type(BL._pendingCraft) ~= "table" then
        BL.ArmPendingFromLastBoard()
    end
    if type(BL._pendingCraft) ~= "table" then
        return false
    end
    local pending = BL._pendingCraft
    local after = SnapshotPotionCounts()
    local before = pending.potionCountsBefore or {}
    for uid, count in pairs(after) do
        if (tonumber(count) or 0) > (tonumber(before[uid]) or 0) then
            return BL.CompletePendingCraftLearn() == true
        end
    end
    BL.MarkInventoryCraftPollDue()
    return false
end
