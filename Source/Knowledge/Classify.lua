----------------------------------------------------------------
-- StockPiler3 Knowledge/Classify - potion effect / level / rarity helpers
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Classify = StockPiler3.Classify or {}
local Classify = StockPiler3.Classify

-- ~27 short effect filter keys (stubs OK for UI combo).
Classify.EFFECT_KEYS = {
    "str", "int", "wp", "bs", "tou", "armor", "absorb", "heal", "hot", "ap",
    "rcorp", "rele", "rspi",
    "hytoucrit", "hystrmelee", "hywillheal", "hystrheal", "hyintmcrit",
    "hyaccrcrit", "hywoumelee", "hywoucrit", "hywoumcrit", "hywourcrit",
    "hywouheal", "hywoustr", "hyresist", "hywouarmpen", "hywouinit",
    "hytounocrit", "hyhpregencritdmg", "hywsarmpen",
}

local EFFECT_SHORT = {
    str = "Str",
    int = "Int",
    wp = "WP",
    bs = "BS",
    tou = "Tou",
    armor = "Armor",
    absorb = "Absorb",
    heal = "Heal",
    hot = "HoT",
    ap = "AP",
    rcorp = "Corp",
    rele = "Ele",
    rspi = "Spi",
    hytoucrit = "Tou+Crit",
    hystrmelee = "Str+Melee",
    hywillheal = "Will+Heal",
    hystrheal = "Str+Heal",
    hyintmcrit = "Int+MCrit",
    hyaccrcrit = "BS+RCrit",
    hywoumelee = "Wou+Melee",
    hywoucrit = "Wou+Crit",
    hywoumcrit = "Wou+MCrit",
    hywourcrit = "Wou+RCrit",
    hywouheal = "Wou+Heal",
    hywoustr = "Wou+Str",
    hyresist = "Resist",
    hywouarmpen = "Wou+APen",
    hywouinit = "Wou+Init",
    hytounocrit = "Tou-Crit",
    hyhpregencritdmg = "Regen+CritD",
    hywsarmpen = "WS+APen",
    hywsnocrit = "WS-Crit",
}

-- Memoize short labels (finite key set).
local EFFECT_SHORT_WS = {}

local function ToNarrow(value)
    return StockPiler3.Util.ToNarrow(value)
end

local function T(key)
    if StockPiler3.T then
        return StockPiler3.T(key)
    end
    local short = EFFECT_SHORT[key]
    if short then
        return towstring(short)
    end
    return towstring(tostring(key or ""))
end

function Classify.EffectShortLabel(effectKey)
    effectKey = tostring(effectKey or "")
    if effectKey == "" then
        return L""
    end
    local cached = EFFECT_SHORT_WS[effectKey]
    if cached ~= nil then
        return cached
    end
    local labeled = nil
    local localeKey = "effect.short." .. effectKey
    if StockPiler3.Locale and StockPiler3.Locale.ResolveTemplate then
        local template = StockPiler3.Locale.ResolveTemplate(localeKey)
        if type(template) == "wstring" then
            labeled = template
        end
    elseif StockPiler3.T then
        local t = StockPiler3.T(localeKey)
        local narrow = ToNarrow(t)
        if narrow ~= "" and narrow ~= localeKey and string.sub(narrow, 1, 1) ~= "[" then
            labeled = t
        end
    end
    if labeled == nil and EFFECT_SHORT[effectKey] then
        labeled = towstring(EFFECT_SHORT[effectKey])
    end
    if labeled == nil then
        labeled = towstring(string.upper(effectKey))
    end
    EFFECT_SHORT_WS[effectKey] = labeled
    return labeled
end

function Classify.EffectFilterKeys()
    local keys = {}
    for i = 1, #Classify.EFFECT_KEYS do
        keys[i] = Classify.EFFECT_KEYS[i]
    end
    return keys
end

function Classify.IsPotionItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if GameData and GameData.ItemTypes and GameData.ItemTypes.POTION then
        local t = itemData.type or itemData.itemType
        if t == GameData.ItemTypes.POTION then
            return true
        end
    end
    local n = string.lower(ToNarrow(itemData.name))
    return string.find(n, "potion", 1, true)
        or string.find(n, "draught", 1, true)
        or string.find(n, "elixir", 1, true)
        or string.find(n, "unguent", 1, true)
        or string.find(n, "liniment", 1, true)
        or string.find(n, "liquid", 1, true)
end

local function ClassifyFromDescription(description)
    if type(description) ~= "string" or description == "" then
        return nil
    end
    local descLower = string.lower(description)
    if string.find(descLower, "wounds", 1, true) then
        if string.find(descLower, "ranged", 1, true)
            and (string.find(descLower, "crit", 1, true) or string.find(descLower, "critical", 1, true))
        then
            return "hywourcrit"
        end
        if string.find(descLower, "magic", 1, true)
            and (string.find(descLower, "crit", 1, true) or string.find(descLower, "critical", 1, true))
        then
            return "hywoumcrit"
        end
        if (string.find(descLower, "melee", 1, true) or string.find(descLower, "weapon", 1, true))
            and (string.find(descLower, "crit", 1, true) or string.find(descLower, "critical", 1, true))
        then
            return "hywoucrit"
        end
        if string.find(descLower, "initiative", 1, true) then
            return "hywouinit"
        end
        if string.find(descLower, "heal", 1, true) then
            return "hywouheal"
        end
        if string.find(descLower, "strength", 1, true) then
            return "hywoustr"
        end
        if string.find(descLower, "armor pen", 1, true) or string.find(descLower, "armour pen", 1, true) then
            return "hywouarmpen"
        end
        if string.find(descLower, "melee", 1, true) then
            return "hywoumelee"
        end
    end
    -- Potion Use: ability text (same strings as stock tooltips).
    if string.find(descLower, "instantly restores", 1, true) then
        if string.find(descLower, "action point", 1, true) then
            return "ap"
        end
        if string.find(descLower, "health", 1, true) then
            return "heal"
        end
    end
    if string.find(descLower, "gradually restores", 1, true)
        or string.find(descLower, "heals for", 1, true)
    then
        return "hot"
    end
    if string.find(descLower, "absorbs", 1, true) or string.find(descLower, "magical barrier", 1, true) then
        return "absorb"
    end
    -- Resist potions / plant text (before generic "increases" / "armor").
    if string.find(descLower, "spirit resistance", 1, true)
        or string.find(descLower, "spirit resist", 1, true)
    then
        return "rspi"
    end
    if string.find(descLower, "corporeal resistance", 1, true)
        or string.find(descLower, "corporeal resist", 1, true)
    then
        return "rcorp"
    end
    if string.find(descLower, "elemental resistance", 1, true)
        or string.find(descLower, "elemental resist", 1, true)
    then
        return "rele"
    end
    if string.find(descLower, "increases", 1, true)
        or string.find(descLower, "create", 1, true)
        or string.find(descLower, "used to", 1, true)
    then
        -- Willpower before strength/"power": "willpower potions" contains "power potion".
        if string.find(descLower, "willpower", 1, true) then return "wp" end
        if string.find(descLower, "intelligence", 1, true) then return "int" end
        if string.find(descLower, "ballistic skill", 1, true) then return "bs" end
        if string.find(descLower, "strength", 1, true) then return "str" end
        if string.find(descLower, "power potion", 1, true) then return "str" end
        if string.find(descLower, "toughness", 1, true) then return "tou" end
        if string.find(descLower, "armor", 1, true) or string.find(descLower, "armour", 1, true) then
            return "armor"
        end
    end
    return nil
end

local function ClassifyFromName(name)
    local n = string.lower(ToNarrow(name))
    if n == "" then
        return nil
    end
    if string.find(n, "liniment", 1, true) or string.find(n, "war:", 1, true) then
        if string.find(n, "hunger", 1, true) then return "hywoustr" end
        if string.find(n, "mercy", 1, true) then return "hywouheal" end
        if string.find(n, "blood", 1, true) then return "hywoucrit" end
        if string.find(n, "demise", 1, true) then return "hywoumelee" end
        if string.find(n, "genius", 1, true) then return "hywoumcrit" end
        if string.find(n, "fervor", 1, true) then return "hywourcrit" end
    end
    -- Do not map potion product names (Recovery / Elixir / Draught) - Effect comes
    -- from Use: ability or the recipe main's EFFECT id, not the finished name.
    if string.find(n, "brilliance", 1, true) then return "int" end
    if string.find(n, "discipline", 1, true) then return "wp" end
    if string.find(n, "securing", 1, true) then return "armor" end
    if string.find(n, "spirit screen", 1, true) or string.find(n, "spirit resist", 1, true) then
        return "rspi"
    end
    if string.find(n, "corporeal", 1, true) then return "rcorp" end
    if string.find(n, "elemental", 1, true) and string.find(n, "resist", 1, true) then
        return "rele"
    end
    return nil
end

--- ITEMBONUS_USE = 3. Stock tooltip Use: line = GetAbilityDesc(bonus.reference, iLevel).
local ITEMBONUS_USE = 3
if GameDefs and GameDefs.ITEMBONUS_USE then
    ITEMBONUS_USE = GameDefs.ITEMBONUS_USE
end

local function FirstUseAbilityId(itemData)
    if type(itemData) ~= "table" or type(itemData.bonus) ~= "table" then
        return 0
    end
    for _, bonus in ipairs(itemData.bonus) do
        if type(bonus) == "table" and tonumber(bonus.type) == ITEMBONUS_USE then
            local ref = tonumber(bonus.reference) or 0
            if ref > 0 then
                return ref
            end
        end
    end
    for _, bonus in pairs(itemData.bonus) do
        if type(bonus) == "table" and tonumber(bonus.type) == ITEMBONUS_USE then
            local ref = tonumber(bonus.reference) or 0
            if ref > 0 then
                return ref
            end
        end
    end
    return 0
end

local function AbilityTextForUseBonus(itemData)
    local abilityId = FirstUseAbilityId(itemData)
    if abilityId <= 0 or type(GetAbilityDesc) ~= "function" then
        return nil, abilityId
    end
    local iLevel = tonumber(itemData.iLevel) or tonumber(itemData.level) or 0
    local ok, text = pcall(GetAbilityDesc, abilityId, iLevel)
    if not ok then
        return nil, abilityId
    end
    local narrow = ToNarrow(text)
    if narrow == "" then
        return nil, abilityId
    end
    return narrow, abilityId
end

--- Prefer potion Use: ability text (tooltip SoT) over plain description/name.
function Classify.GetEffectKeyFromPotionUse(itemData)
    if type(itemData) ~= "table" then
        return nil
    end
    local abilityText = AbilityTextForUseBonus(itemData)
    if abilityText then
        return ClassifyFromDescription(abilityText)
    end
    return nil
end

--- Ability id for the potion Use: bonus (ITEMBONUS_USE), or 0.
function Classify.GetPotionUseAbilityId(itemData)
    return FirstUseAbilityId(itemData)
end

function Classify.GetEffectKey(itemData)
    if type(itemData) ~= "table" then
        return nil
    end
    -- Finished potions: Use bonus -> ability text (matches stock tooltip). Never name-first.
    local fromUse = Classify.GetEffectKeyFromPotionUse(itemData)
    if fromUse then
        return fromUse
    end
    if itemData.effectKey and tostring(itemData.effectKey) ~= "" then
        return tostring(itemData.effectKey)
    end
    local desc = ToNarrow(itemData.description or itemData.desc or "")
    local key = ClassifyFromDescription(desc)
    if key then
        return key
    end
    return ClassifyFromName(itemData.name)
end

--- Level / rank from item (craftingSkillRequirement, iLevel, level).
function Classify.GetLevelRank(itemData)
    if type(itemData) ~= "table" then
        return 0, 0, L"-"
    end
    local rank = tonumber(itemData.craftingSkillRequirement)
        or tonumber(itemData.skillReq)
        or tonumber(itemData.skillLevel)
        or 0
    local level = tonumber(itemData.iLevel)
        or tonumber(itemData.level)
        or tonumber(itemData.rank)
        or rank
    local text = L"-"
    if level > 0 then
        text = towstring(tostring(level))
    elseif rank > 0 then
        text = towstring(tostring(rank))
    end
    return level, rank, text
end

function Classify.GetRarity(itemData)
    if type(itemData) ~= "table" then
        return 0
    end
    return tonumber(itemData.rarity) or 0
end

function Classify.GetRarityColor(itemData)
    local r, g, b = 255, 255, 255
    if type(itemData) ~= "table" then
        return r, g, b
    end
    if DataUtils and DataUtils.GetItemRarityColor then
        local ok, color = pcall(DataUtils.GetItemRarityColor, itemData)
        if ok and type(color) == "table" then
            return tonumber(color.r) or r, tonumber(color.g) or g, tonumber(color.b) or b
        end
    end
    return r, g, b
end

function Classify.GetPotionStats(itemData)
    local level, rank, levelText = Classify.GetLevelRank(itemData)
    local effectKey = Classify.GetEffectKey(itemData)
    return {
        effectKey = effectKey,
        effectText = Classify.EffectShortLabel(effectKey),
        level = level,
        rank = rank,
        levelText = levelText,
        rarity = Classify.GetRarity(itemData),
    }
end
