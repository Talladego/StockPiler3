----------------------------------------------------------------
-- StockPiler3 View/Catalog -- potion list + forget helpers
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Catalog = StockPiler3.Catalog or {}
local Catalog = StockPiler3.Catalog

local function ToNarrow(value)
    if StockPiler3.Persistence and StockPiler3.Persistence.ToNarrow then
        return StockPiler3.Persistence.ToNarrow(value)
    end
    if type(value) == "wstring" and type(WStringToString) == "function" then
        local ok, text = pcall(WStringToString, value)
        if ok and type(text) == "string" then
            return text
        end
    end
    return tostring(value or "")
end

local function PotionRecipeKeys(potion)
    if type(potion) ~= "table" then
        return {}
    end
    local keys = potion.recipeKeys
    if type(keys) == "table" and #keys > 0 then
        return keys
    end
    local active = potion.activeRecipeKey or potion.activeRecipeSpecKey or potion.recipeSpecKey
    if type(active) == "string" and active ~= "" then
        return { active }
    end
    return {}
end

local function ListEntriesFromKnowledge()
    local out = {}
    local Know = StockPiler3.Knowledge
    local RS = StockPiler3.RecipeSpec
    local potions = Know and Know.Potions and Know.Potions() or Know and Know.GetTable and Know.GetTable("potions")
    local recipes = Know and Know.Recipes and Know.Recipes() or Know and Know.GetTable and Know.GetTable("recipes")
    if type(potions) ~= "table" then
        return out
    end
    for _, potion in pairs(potions) do
        if type(potion) == "table" then
            local uid = tonumber(potion.outputUid) or 0
            if uid > 0 then
                local keys = PotionRecipeKeys(potion)
                local seen = {}
                for i = 1, #keys do
                    local recipeKey = keys[i]
                    if type(recipeKey) == "string" and recipeKey ~= "" and seen[recipeKey] ~= true then
                        seen[recipeKey] = true
                        local recipe = type(recipes) == "table" and recipes[recipeKey] or nil
                        if type(recipe) == "table" then
                            local include = true
                            if type(recipe.outcomes) == "table" and next(recipe.outcomes) ~= nil then
                                if recipe.outcomes[tostring(uid)] == nil then
                                    include = false
                                end
                            end
                            if include then
                                if RS and RS.HydrateRecipeSlots then
                                    RS.HydrateRecipeSlots(recipe)
                                end
                                local prKey = RS and RS.PotionRecipeKey and RS.PotionRecipeKey(uid, recipeKey)
                                    or ("uid:" .. tostring(uid) .. "|rk:" .. recipeKey)
                                local stats = { power = 0, stability = 0, multiplier = 0, superCrit = 0, yield = 0 }
                                if RS and RS.RecipeFingerprintStats then
                                    stats = RS.RecipeFingerprintStats(recipe, uid) or stats
                                end
                                out[#out + 1] = {
                                    potionRecipeKey = prKey,
                                    potionKey = potion.potionKey or (RS and RS.PotionKeyFromUid and RS.PotionKeyFromUid(uid)),
                                    outputUid = uid,
                                    recipeSpecKey = recipeKey,
                                    name = potion.name,
                                    iconNum = tonumber(potion.iconNum) or 0,
                                    effectKey = potion.effectKey,
                                    recipeLabel = potion.recipeLabel or L"",
                                    power = tonumber(stats.power) or 0,
                                    stability = tonumber(stats.stability) or 0,
                                    multiplier = tonumber(stats.multiplier) or 0,
                                    superCrit = tonumber(stats.superCrit) or 0,
                                    yield = tonumber(stats.yield) or 0,
                                    potion = potion,
                                    recipe = recipe,
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        local na = string.lower(ToNarrow(a.name))
        local nb = string.lower(ToNarrow(b.name))
        if na == nb then
            return ToNarrow(a.recipeLabel) < ToNarrow(b.recipeLabel)
        end
        return na < nb
    end)
    return out
end

function Catalog.ListPotionRecipeEntries()
    local RS = StockPiler3.RecipeSpec
    if RS and RS.ListPotionRecipeEntries then
        return RS.ListPotionRecipeEntries()
    end
    return ListEntriesFromKnowledge()
end

--- Peek only — listing potions must not create disabled SV stubs.
function Catalog.GetWatch(potionKey)
    if StockPiler3.Watch and StockPiler3.Watch.GetWatch then
        return StockPiler3.Watch.GetWatch(potionKey)
    end
    return { enabled = false, targetStock = 40, autoGrow = false }
end

function Catalog.EnsureWatch(potionKey)
    if StockPiler3.Watch and StockPiler3.Watch.EnsureWatch then
        return StockPiler3.Watch.EnsureWatch(potionKey)
    end
    return { enabled = false, targetStock = 40, autoGrow = false }
end

function Catalog.ClearWatchList()
    if StockPiler3.Watch and StockPiler3.Watch.ClearAll then
        return StockPiler3.Watch.ClearAll()
    end
    return 0
end

function Catalog.PotionHaveCombined(potion)
    if type(potion) ~= "table" then
        return 0
    end
    local uid = tonumber(potion.outputUid) or 0
    if uid <= 0 or not StockPiler3.Inventory or not StockPiler3.Inventory.CountByUid then
        return 0
    end
    return tonumber(StockPiler3.Inventory.CountByUid(uid)) or 0
end

local function ScrubWatchKey(key)
    key = tostring(key or "")
    if key == "" then
        return
    end
    local watches = StockPiler3.Watch and StockPiler3.Watch.GetWatches and StockPiler3.Watch.GetWatches()
    if type(watches) == "table" and watches[key] ~= nil then
        watches[key] = nil
        if StockPiler3.Watch.BumpGen then
            StockPiler3.Watch.BumpGen()
        end
    end
end

--- Unlink one potion fingerprint from its learned recipe. Shared recipes stay if other potions remain.
function Catalog.ForgetPotionRecipeLink(outputUid, recipeSpecKey)
    local RS = StockPiler3.RecipeSpec
    if RS and RS.ForgetPotionRecipeLink then
        local removed = RS.ForgetPotionRecipeLink(outputUid, recipeSpecKey) == true
        if removed and StockPiler3.Knowledge and StockPiler3.Knowledge.Touch then
            StockPiler3.Knowledge.Touch()
        end
        return removed
    end

    outputUid = tonumber(outputUid) or 0
    recipeSpecKey = tostring(recipeSpecKey or "")
    if outputUid <= 0 or recipeSpecKey == "" then
        return false
    end

    local potions = StockPiler3.Knowledge and StockPiler3.Knowledge.Potions and StockPiler3.Knowledge.Potions()
    local recipes = StockPiler3.Knowledge and StockPiler3.Knowledge.Recipes and StockPiler3.Knowledge.Recipes()
    if type(potions) ~= "table" or type(recipes) ~= "table" then
        return false
    end

    local potionKey = RS and RS.PotionKeyFromUid and RS.PotionKeyFromUid(outputUid) or ("uid:" .. tostring(outputUid))
    local potion = potions[potionKey]
    local recipe = recipes[recipeSpecKey]
    local hadLink = false

    if type(potion) == "table" then
        local keys = PotionRecipeKeys(potion)
        for i = 1, #keys do
            if keys[i] == recipeSpecKey then
                hadLink = true
                break
            end
        end
    end
    if type(recipe) == "table" and type(recipe.outcomes) == "table"
        and type(recipe.outcomes[tostring(outputUid)]) == "table"
    then
        hadLink = true
    end
    if not hadLink then
        return false
    end

    if type(potion) == "table" then
        local keys = PotionRecipeKeys(potion)
        local trimmed = {}
        for i = 1, #keys do
            if keys[i] ~= recipeSpecKey then
                trimmed[#trimmed + 1] = keys[i]
            end
        end
        potion.recipeKeys = trimmed
        if potion.activeRecipeKey == recipeSpecKey or potion.activeRecipeSpecKey == recipeSpecKey
            or potion.recipeSpecKey == recipeSpecKey
        then
            potion.activeRecipeKey = trimmed[1]
            potion.activeRecipeSpecKey = trimmed[1]
            potion.recipeSpecKey = trimmed[1]
        end
        if #trimmed == 0 then
            potions[potionKey] = nil
        end
    end

    if type(recipe) == "table" and type(recipe.outcomes) == "table" then
        recipe.outcomes[tostring(outputUid)] = nil
        local remaining = false
        for _ in pairs(recipe.outcomes) do
            remaining = true
            break
        end
        if not remaining then
            -- Keep recipe only if another potion still lists it.
            local stillLinked = false
            for _, other in pairs(potions) do
                if type(other) == "table" then
                    local oks = PotionRecipeKeys(other)
                    for i = 1, #oks do
                        if oks[i] == recipeSpecKey then
                            stillLinked = true
                            break
                        end
                    end
                end
                if stillLinked then
                    break
                end
            end
            if not stillLinked then
                recipes[recipeSpecKey] = nil
            end
        end
    end

    if RS and RS.PotionRecipeKey then
        ScrubWatchKey(RS.PotionRecipeKey(outputUid, recipeSpecKey))
    end
    if StockPiler3.Knowledge and StockPiler3.Knowledge.Touch then
        StockPiler3.Knowledge.Touch()
    elseif StockPiler3.Knowledge and StockPiler3.Knowledge.BumpGen then
        StockPiler3.Knowledge.BumpGen()
    end
    return true
end

function Catalog.ForgetLearnedRecipeSpec(key)
    key = tostring(key or "")
    if key == "" then
        return false
    end
    local RS = StockPiler3.RecipeSpec
    if RS and RS.ParsePotionRecipeKey then
        local parsed = RS.ParsePotionRecipeKey(key)
        if type(parsed) == "table" and parsed.isComposite == true
            and type(parsed.recipeSpecKey) == "string" and parsed.recipeSpecKey ~= ""
        then
            return Catalog.ForgetPotionRecipeLink(parsed.outputUid, parsed.recipeSpecKey)
        end
    end
    return false
end
