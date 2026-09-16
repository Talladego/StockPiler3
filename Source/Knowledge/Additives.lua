----------------------------------------------------------------
-- StockPiler3 Knowledge/Additives — Soil / Water / Nutrient catalog stubs
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Additives = StockPiler3.Additives or {}
local AD = StockPiler3.Additives

local function ToNarrow(text)
    if StockPiler3.Persistence and StockPiler3.Persistence.ToNarrow then
        return StockPiler3.Persistence.ToNarrow(text)
    end
    if type(text) == "wstring" and type(WStringToString) == "function" then
        return WStringToString(text) or ""
    end
    return tostring(text or "")
end

local function CultTypes()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes
    end
    return { NONE = 0, SEED = 1, SOIL = 2, WATERCAN = 3, NUTRIENT = 4, SPORE = 5 }
end

local function CraftBonusRefs()
    if StockPiler3.BrewLearn and StockPiler3.BrewLearn.CraftBonus then
        return StockPiler3.BrewLearn.CraftBonus
    end
    return { GROW_TIME = 10, CRITICAL_CHANCE = 12, FAIL_CHANCE = 13, SPECIAL_CHANCE = 14 }
end

local function SignedBonus(val)
    val = tonumber(val) or 0
    if val > 32767 then
        return val - 65536
    end
    return val
end

local function ParseStats(itemData)
    local B = CraftBonusRefs()
    local growTime, critChance, superCrit, failChance = 0, 0, 0, 0
    if type(itemData) == "table" and type(itemData.craftingBonus) == "table" then
        for _, bonus in pairs(itemData.craftingBonus) do
            if type(bonus) == "table" then
                local ref = tonumber(bonus.bonusReference) or 0
                local val = SignedBonus(bonus.bonusValue)
                if ref == (B.GROW_TIME or 10) then
                    growTime = val
                elseif ref == (B.CRITICAL_CHANCE or 12) then
                    critChance = val
                elseif ref == (B.SPECIAL_CHANCE or 14) then
                    superCrit = val
                elseif ref == (B.FAIL_CHANCE or 13) then
                    failChance = val
                end
            end
        end
    end
    return {
        growTime = growTime,
        critChance = critChance,
        superCrit = superCrit,
        failChance = failChance,
    }
end

local function AdditivesTable()
    if StockPiler3.Knowledge and StockPiler3.Knowledge.Additives then
        return StockPiler3.Knowledge.Additives()
    end
    return nil
end

local function StoreRecord(itemData, info, source)
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.id) or 0
    if uid <= 0 then
        return false, false
    end
    local store = AdditivesTable()
    if type(store) ~= "table" then
        return false, false
    end
    local key = tostring(uid)
    local isNew = store[key] == nil
    store[key] = {
        uniqueID = uid,
        iconNum = tonumber(itemData.iconNum) or 0,
        name = itemData.name,
        nameNarrow = ToNarrow(itemData.name),
        cultType = info.cultType,
        role = info.role,
        growTime = info.growTime,
        critChance = info.critChance,
        superCrit = info.superCrit,
        failChance = info.failChance,
        skillReq = tonumber(itemData.craftingSkillRequirement) or 0,
        source = source or "bag",
    }
    if StockPiler3.Items and StockPiler3.Items.StoreItem then
        StockPiler3.Items.StoreItem(itemData, "additive")
    end
    if isNew and StockPiler3.Knowledge and StockPiler3.Knowledge.Touch then
        StockPiler3.Knowledge.Touch("additive")
    end
    return true, isNew
end

function AD.Classify(itemData)
    if type(itemData) ~= "table" then
        return nil
    end
    local types = CultTypes()
    local soil = tonumber(types.SOIL) or 2
    local water = tonumber(types.WATERCAN) or 3
    local nutrient = tonumber(types.NUTRIENT) or 4
    local seed = tonumber(types.SEED) or 1
    local spore = tonumber(types.SPORE) or 5
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType == seed or cultType == spore then
        return nil
    end

    local stats = ParseStats(itemData)
    if cultType ~= soil and cultType ~= water and cultType ~= nutrient then
        if stats.growTime < 0 and stats.critChance > 0 and stats.superCrit <= 0 then
            cultType = soil
        elseif stats.growTime < 0 and stats.superCrit > 0 then
            cultType = water
        elseif stats.growTime < 0 and stats.failChance < 0 then
            cultType = nutrient
        else
            return nil
        end
    end

    local role = "soil"
    if cultType == water then
        role = "watering"
    elseif cultType == nutrient then
        role = "nutrient"
    end

    return {
        cultType = cultType,
        role = role,
        growTime = stats.growTime,
        critChance = stats.critChance,
        superCrit = stats.superCrit,
        failChance = stats.failChance,
    }
end

function AD.LearnFromItemData(itemData, source)
    local info = AD.Classify(itemData)
    if info == nil then
        return false
    end
    local stored = StoreRecord(itemData, info, source)
    return stored == true
end

function AD.LearnFromPlotRow(row)
    if type(row) ~= "table" then
        return 0
    end
    local n = 0
    local slots = row.additives or row.Additives
    if type(slots) ~= "table" then
        return 0
    end
    for _, slot in pairs(slots) do
        if type(slot) == "table" then
            local item = slot.item or slot
            if AD.LearnFromItemData(item, "plot") then
                n = n + 1
            end
        end
    end
    return n
end

function AD.StageForCultType(cultType)
    cultType = tonumber(cultType) or 0
    local types = CultTypes()
    if cultType == (tonumber(types.SOIL) or 2) then
        return 1
    end
    if cultType == (tonumber(types.WATERCAN) or 3) then
        return 2
    end
    if cultType == (tonumber(types.NUTRIENT) or 4) then
        return 3
    end
    return 0
end

function AD.CultTypeForStage(stageNum)
    stageNum = tonumber(stageNum) or 0
    local types = CultTypes()
    if stageNum == 1 then
        return tonumber(types.SOIL) or 2
    end
    if stageNum == 2 then
        return tonumber(types.WATERCAN) or 3
    end
    if stageNum == 3 then
        return tonumber(types.NUTRIENT) or 4
    end
    return 0
end

--- Score for stage preference: prefer higher superCrit, then crit, then shorter grow.
function AD.Score(info, skillReq, _iLevel)
    if type(info) ~= "table" then
        return -999999
    end
    skillReq = tonumber(skillReq) or tonumber(info.skillReq) or 0
    local score = (tonumber(info.superCrit) or 0) * 1000
        + (tonumber(info.critChance) or 0) * 10
        - (tonumber(info.growTime) or 0)
        - skillReq
    return score
end

--- Prefer best matching additive for a cultivation stage from Account.additives + bags.
function AD.FindBestForStage(stageNum)
    local cultType = AD.CultTypeForStage(stageNum)
    if cultType <= 0 then
        return nil
    end
    return AD.FindBestInCraftBag(cultType)
end

function AD.FindBestInCraftBag(cultType)
    cultType = tonumber(cultType) or 0
    if cultType <= 0 then
        return nil
    end
    local bestUid, bestScore, bestItem = 0, -999999, nil
    local store = AdditivesTable() or {}

    local function consider(item)
        if type(item) ~= "table" then
            return
        end
        local info = AD.Classify(item)
        if info == nil or tonumber(info.cultType) ~= cultType then
            local uid = tonumber(item.uniqueID) or 0
            local row = store[tostring(uid)]
            if type(row) ~= "table" or tonumber(row.cultType) ~= cultType then
                return
            end
            info = row
        end
        local score = AD.Score(info, item.craftingSkillRequirement or info.skillReq)
        local uid = tonumber(item.uniqueID) or 0
        if uid > 0 and score > bestScore then
            bestScore = score
            bestUid = uid
            bestItem = item
        end
    end

    if StockPiler3.Inventory and StockPiler3.Inventory.ForEachItem then
        StockPiler3.Inventory.ForEachItem(consider)
    end

    -- Catalog stubs: prefer known Account.additives when bag sample missing.
    if bestUid <= 0 then
        for _, row in pairs(store) do
            if type(row) == "table" and tonumber(row.cultType) == cultType then
                local score = AD.Score(row, row.skillReq)
                local uid = tonumber(row.uniqueID) or 0
                if uid > 0 and score > bestScore then
                    bestScore = score
                    bestUid = uid
                    bestItem = row
                end
            end
        end
    end

    if bestUid <= 0 then
        return nil
    end
    return {
        uniqueID = bestUid,
        score = bestScore,
        item = bestItem,
        cultType = cultType,
    }
end

function AD.CountKnown()
    local store = AdditivesTable()
    local n = 0
    if type(store) == "table" then
        for _ in pairs(store) do
            n = n + 1
        end
    end
    return n
end

function AD.IsEnabled()
    if StockPiler3.Watch and StockPiler3.Watch.IsAutoGrowAdditivesEnabled then
        return StockPiler3.Watch.IsAutoGrowAdditivesEnabled() == true
    end
    if StockPiler3.Persistence and StockPiler3.Persistence.GetCharacterBucket then
        local row = StockPiler3.Persistence.GetCharacterBucket(false)
        return type(row) == "table" and row.autoGrowAdditives == true
    end
    return false
end
