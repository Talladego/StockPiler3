----------------------------------------------------------------
-- StockPiler3 Knowledge/Items — learned item rows (plants/mats/potions)
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Items = StockPiler3.Items or {}
local Items = StockPiler3.Items

local function ToNarrow(value)
    if StockPiler3.Persistence and StockPiler3.Persistence.ToNarrow then
        return StockPiler3.Persistence.ToNarrow(value)
    end
    if type(value) == "wstring" and type(WStringToString) == "function" then
        return WStringToString(value) or ""
    end
    return tostring(value or "")
end

local function ItemsTable()
    local acct = StockPiler3.Account
    if type(acct) == "table" then
        if type(acct.items) ~= "table" then
            acct.items = {}
        end
        return acct.items
    end
    if StockPiler3.Knowledge and StockPiler3.Knowledge.Items then
        return StockPiler3.Knowledge.Items()
    end
    return nil
end

local function SignedBonus(val)
    val = tonumber(val) or 0
    if val > 32767 then
        return val - 65536
    end
    return val
end

local function BonusesFromCrafting(item)
    local out = {}
    if type(item) ~= "table" then
        return out
    end
    if type(item.craftingBonus) == "table" then
        for _, bonus in pairs(item.craftingBonus) do
            if type(bonus) == "table" then
                local ref = tonumber(bonus.bonusReference) or 0
                if ref > 0 then
                    out[ref] = SignedBonus(bonus.bonusValue)
                end
            end
        end
    end
    if next(out) ~= nil then
        return out
    end
    if type(item.CraftItemInfo) == "table" then
        for ref, vals in pairs(item.CraftItemInfo) do
            local nref = tonumber(ref) or 0
            if nref > 0 then
                if type(vals) == "table" then
                    out[nref] = SignedBonus(vals[1] or vals)
                else
                    out[nref] = SignedBonus(vals)
                end
            end
        end
    end
    if next(out) ~= nil then
        return out
    end
    if type(CraftItemInfo) == "table" and type(CraftItemInfo.GetItemBonuses) == "function" then
        local ok, vData = pcall(CraftItemInfo.GetItemBonuses, item)
        if ok and type(vData) == "table" then
            for ref, vals in pairs(vData) do
                local nref = tonumber(ref) or 0
                if nref > 0 then
                    if type(vals) == "table" then
                        out[nref] = SignedBonus(vals[1] or vals)
                    else
                        out[nref] = SignedBonus(vals)
                    end
                end
            end
        end
    end
    return out
end

local function RoleFromItem(item, bonuses)
    if type(item) ~= "table" then
        return "ingredient"
    end
    local role = tostring(item.craftingRole or item.role or "")
    if role ~= "" and role ~= "ingredient" then
        return role
    end
    local cult = tonumber(item.cultivationType) or 0
    if cult == 1 or cult == 5 then
        return "ingredient"
    end
    bonuses = type(bonuses) == "table" and bonuses or {}
    local slotType = tonumber(bonuses[8]) or tonumber(item.slotType) or 0
    local cit = GameData and GameData.CraftingItemType
    if cit then
        if slotType == cit.CONTAINER or slotType == cit.CONTAINER_DYE then
            return "container"
        end
        if slotType == cit.MAIN_INGREDIENT then
            return "main"
        end
        if slotType == cit.STABILIZER or slotType == cit.GOLDWEED then
            return "stabilizer"
        end
        if slotType == cit.EXTENDER then
            return "extender"
        end
        if slotType == cit.MULTIPLIER then
            return "multiplier"
        end
        if slotType == cit.STIMULANT then
            return "stimulant"
        end
    elseif slotType == 5 or slotType == 6 then
        return "container"
    elseif slotType == 2 then
        return "main"
    end
    if bonuses[6] ~= nil then
        return "main"
    end
    return role ~= "" and role or "ingredient"
end

--- Strip Eternal / Exceptional / Bunched prefixes for Bloodseed↔Powder relatedness.
function Items.StripEternalExceptionalBunchedPrefixes(name)
    local s = string.lower(ToNarrow(name))
    s = string.gsub(s, "^bunched%s+", "")
    s = string.gsub(s, "^eternal%s+", "")
    s = string.gsub(s, "^exceptional%s+", "")
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

function Items.GetByUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    local store = ItemsTable()
    if type(store) ~= "table" then
        return nil
    end
    local row = store[tostring(uid)]
    if type(row) == "table" then
        return row
    end
    return nil
end

--- Persist / merge a learned item row. Returns row, structuralNew.
function Items.StoreItem(itemData, kindHint)
    if type(itemData) ~= "table" then
        return nil, false
    end
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.uniqueId) or tonumber(itemData.id) or 0
    if uid <= 0 then
        return nil, false
    end
    local store = ItemsTable()
    if type(store) ~= "table" then
        return nil, false
    end
    local key = tostring(uid)
    local existing = store[key]
    local isNew = type(existing) ~= "table"
    local row = isNew and { uniqueID = uid } or existing
    row.uniqueID = uid

    local bonuses = BonusesFromCrafting(itemData)
    local hasBonuses = next(bonuses) ~= nil
    local nameNarrow = ToNarrow(itemData.name)

    if itemData.name ~= nil then
        row.name = itemData.name
        row.nameNarrow = nameNarrow
    end
    local desc = itemData.description or itemData.desc
    if desc ~= nil and ToNarrow(desc) ~= "" then
        row.descriptionNarrow = ToNarrow(desc)
    end
    if itemData.iconNum ~= nil then
        row.iconNum = tonumber(itemData.iconNum) or 0
    end
    if itemData.rarity ~= nil then
        row.rarity = tonumber(itemData.rarity)
    end
    if itemData.iLevel ~= nil or itemData.level ~= nil then
        row.iLevel = tonumber(itemData.iLevel) or tonumber(itemData.level) or row.iLevel
    end
    if itemData.craftingSkillRequirement ~= nil then
        row.skillReq = tonumber(itemData.craftingSkillRequirement) or 0
    end
    if itemData.tradeSkill ~= nil then
        row.tradeSkill = tonumber(itemData.tradeSkill) or 0
    end
    if itemData.cultivationType ~= nil then
        row.cultivationType = tonumber(itemData.cultivationType) or 0
    end
    if itemData.isRefinable ~= nil then
        row.isRefinable = itemData.isRefinable == true
    end
    -- Engine false-positives (Squig Bits) + hybrid/liniment specials: sticky via MaterialExceptions.
    local ME = StockPiler3.MaterialExceptions
    local forceProbe = row
    if ME and ME.LooksSpecialApoMain then
        -- Prefer live itemData (may carry description) over sparse learned row.
        if ME.LooksSpecialApoMain(itemData) or ME.LooksSpecialApoMain(row) then
            forceProbe = itemData
        end
    end
    if ME and ME.IsForceNotRefinable and ME.IsForceNotRefinable(forceProbe) == true then
        row.forceNotRefinable = true
        row.isRefinable = false
        if ME.MarkForceNotRefinable then
            local reason = "store"
            if ME.LooksSpecialApoMain and ME.LooksSpecialApoMain(forceProbe) then
                reason = "special-apo-main"
            end
            ME.MarkForceNotRefinable(uid, reason)
        end
    end
    if itemData.type ~= nil or itemData.itemType ~= nil then
        row.itemType = tonumber(itemData.type) or tonumber(itemData.itemType) or 0
    end
    if kindHint then
        row.kind = kindHint
    elseif not row.kind then
        row.kind = "mat"
    end

    if hasBonuses then
        row.bonuses = bonuses
        row.role = RoleFromItem(itemData, bonuses)
        row.power = bonuses[2]
        row.stability = bonuses[1]
        row.duration = bonuses[3]
        row.effectId = bonuses[6]
        row.slotType = bonuses[8]
        if bonuses[9] ~= nil then
            row.skillReq = tonumber(bonuses[9]) or row.skillReq
            row.skillLevel = tonumber(bonuses[9]) or row.skillLevel
        end
        if bonuses[5] ~= nil then
            row.tradeSkill = tonumber(bonuses[5]) or row.tradeSkill
        end
        row.incomplete = false
        if row.role == "main" and (bonuses[6] == nil or tonumber(bonuses[6]) <= 0) then
            row.incomplete = true
        end
    elseif type(row.bonuses) ~= "table" then
        row.incomplete = true
        row.role = RoleFromItem(itemData, nil)
    end

    store[key] = row
    return row, isNew
end

--- Learned plant/mat fingerprint (bag AsItemData often lacks craftingBonus).
--- Accepts uid number or item table.
function Items.ToSpec(item)
    local uid = 0
    local row = nil
    if type(item) == "number" then
        uid = item
        row = Items.GetByUid(uid)
    elseif type(item) == "table" then
        uid = tonumber(item.uniqueID) or tonumber(item.uniqueId) or tonumber(item.id) or 0
        if type(item.craftingBonus) == "table" and next(item.craftingBonus) ~= nil then
            local bonuses = BonusesFromCrafting(item)
            local out = {
                uid = uid,
                role = RoleFromItem(item, bonuses),
                power = tonumber(bonuses[2]) or 0,
                stability = tonumber(bonuses[1]) or 0,
                duration = tonumber(bonuses[3]) or 0,
                bonuses = bonuses,
                tradeSkill = tonumber(item.tradeSkill) or bonuses[5] or 0,
                skillLevel = tonumber(item.craftingSkillRequirement) or bonuses[9] or 0,
                cultivationType = tonumber(item.cultivationType) or 0,
                slotType = tonumber(bonuses[8]) or 0,
                effectId = bonuses[6],
                incomplete = (RoleFromItem(item, bonuses) == "main"
                    and (bonuses[6] == nil or tonumber(bonuses[6]) <= 0)),
                boundUid = uid > 0 and uid or nil,
                name = item.name,
                rarity = item.rarity,
            }
            if item.isRefinable ~= nil then
                out.isRefinable = item.isRefinable == true
            elseif uid > 0 then
                local learned = Items.GetByUid(uid)
                if type(learned) == "table" and learned.isRefinable ~= nil then
                    out.isRefinable = learned.isRefinable == true
                end
            end
            return out
        end
        row = uid > 0 and Items.GetByUid(uid) or nil
        if row == nil and (item.role or item.power or item.bonuses) then
            local bonuses = type(item.bonuses) == "table" and item.bonuses or {}
            local out = {
                uid = uid,
                role = item.role or "ingredient",
                power = tonumber(item.power) or tonumber(bonuses[2]) or 0,
                stability = tonumber(item.stability) or tonumber(bonuses[1]) or 0,
                duration = tonumber(item.duration) or tonumber(bonuses[3]) or 0,
                bonuses = bonuses,
                tradeSkill = tonumber(item.tradeSkill) or tonumber(bonuses[5]) or 0,
                skillLevel = tonumber(item.skillLevel) or tonumber(item.skillReq) or tonumber(bonuses[9]) or 0,
                cultivationType = tonumber(item.cultivationType) or 0,
                slotType = tonumber(item.slotType) or tonumber(bonuses[8]) or 0,
                effectId = item.effectId or bonuses[6],
                incomplete = item.incomplete == true,
                boundUid = tonumber(item.boundUid) or (item.incomplete == true and uid > 0 and uid or nil),
                name = item.name,
                rarity = item.rarity,
            }
            if item.isRefinable ~= nil then
                out.isRefinable = item.isRefinable == true
            end
            return out
        end
    else
        return nil
    end
    if type(row) ~= "table" then
        return nil
    end
    local bonuses = type(row.bonuses) == "table" and row.bonuses or {}
    local incomplete = row.incomplete == true
    local out = {
        uid = tonumber(row.uniqueID) or uid,
        role = row.role or "ingredient",
        power = tonumber(row.power) or tonumber(bonuses[2]) or 0,
        stability = tonumber(row.stability) or tonumber(bonuses[1]) or 0,
        duration = tonumber(row.duration) or tonumber(bonuses[3]) or 0,
        bonuses = bonuses,
        tradeSkill = tonumber(row.tradeSkill) or tonumber(bonuses[5]) or 0,
        skillLevel = tonumber(row.skillLevel) or tonumber(row.skillReq) or tonumber(bonuses[9]) or 0,
        cultivationType = tonumber(row.cultivationType) or 0,
        slotType = tonumber(row.slotType) or tonumber(bonuses[8]) or 0,
        effectId = row.effectId or bonuses[6],
        incomplete = incomplete,
        boundUid = incomplete and (tonumber(row.uniqueID) or uid) or nil,
        name = row.name,
        rarity = row.rarity,
    }
    -- Preserve known false; omit when never observed (nil ≠ non-refinable).
    if row.isRefinable ~= nil then
        out.isRefinable = row.isRefinable == true
    end
    return out
end

function Items.AsItemData(uid)
    local row = Items.GetByUid(uid)
    if type(row) ~= "table" then
        return nil
    end
    local out = {
        uniqueID = tonumber(row.uniqueID) or tonumber(uid) or 0,
        name = row.name,
        nameNarrow = row.nameNarrow,
        iconNum = tonumber(row.iconNum) or 0,
        craftingSkillRequirement = tonumber(row.skillReq) or 0,
        tradeSkill = tonumber(row.tradeSkill) or 0,
        cultivationType = tonumber(row.cultivationType) or 0,
        itemType = tonumber(row.itemType) or 0,
        type = tonumber(row.itemType) or 0,
        iLevel = tonumber(row.iLevel) or 0,
        rarity = tonumber(row.rarity),
        craftingBonus = nil,
    }
    if row.isRefinable ~= nil then
        out.isRefinable = row.isRefinable == true
    end
    return out
end
