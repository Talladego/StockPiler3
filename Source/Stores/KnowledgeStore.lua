----------------------------------------------------------------
-- StockPiler3 Stores/KnowledgeStore — account learned-data facade
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Knowledge = StockPiler3.Knowledge or {}
local Know = StockPiler3.Knowledge

local ACCOUNT_TABLES = { "items", "grows", "refines", "recipes", "potions", "additives", "vendorItems" }

Know._gen = 0
Know._ensuring = false

local function IsAllowedTable(name)
    for i = 1, #ACCOUNT_TABLES do
        if ACCOUNT_TABLES[i] == name then
            return true
        end
    end
    return false
end

local function EnsureAccountTables(acct)
    if type(acct) ~= "table" then
        return false
    end
    for i = 1, #ACCOUNT_TABLES do
        local k = ACCOUNT_TABLES[i]
        if type(acct[k]) ~= "table" then
            acct[k] = {}
        end
    end
    return true
end

function Know.GetGen()
    return tonumber(Know._gen) or 0
end

--- Shape Account knowledge tables. Does not call Persistence.EnsureAccount
--- (that would recurse via GetAccount/Recipes during migrate).
function Know.Ensure()
    if Know._ensuring == true then
        return type(StockPiler3.Account) == "table"
    end
    Know._ensuring = true
    local ok = false
    local acct = StockPiler3.Account
    if type(acct) ~= "table" then
        -- Caller (Bootstrap / Persistence) must create Account first.
        Know._ensuring = false
        return false
    end
    ok = EnsureAccountTables(acct)
    Know._ensuring = false
    return ok
end

--- Run fingerprint migrate once Account tables exist (Bootstrap after EnsureAccount).
function Know.MigrateFingerprints()
    if StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.MigrateRecipeFingerprintsV2 then
        StockPiler3.RecipeSpec.MigrateRecipeFingerprintsV2()
    end
    if StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.MigratePotionEffectKeys then
        StockPiler3.RecipeSpec.MigratePotionEffectKeys()
    end
    if StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.ScrubSubsetPotionRecipeKeys then
        local n = tonumber(StockPiler3.RecipeSpec.ScrubSubsetPotionRecipeKeys()) or 0
        if n > 0 and StockPiler3.Knowledge and StockPiler3.Knowledge.Touch then
            StockPiler3.Knowledge.Touch("recipe-subset-scrub")
        end
    end
end

function Know.GetAccount()
    local acct = StockPiler3.Account
    if type(acct) == "table" then
        EnsureAccountTables(acct)
        return acct
    end
    -- Create once; EnsureAccount must not re-enter GetAccount/Ensure migrate.
    if StockPiler3.Persistence and StockPiler3.Persistence.EnsureAccount then
        return StockPiler3.Persistence.EnsureAccount()
    end
    return nil
end

function Know.GetTable(name)
    if type(name) ~= "string" or name == "" or not IsAllowedTable(name) then
        return nil
    end
    local acct = Know.GetAccount()
    if type(acct) ~= "table" then
        return nil
    end
    if type(acct[name]) ~= "table" then
        acct[name] = {}
    end
    return acct[name]
end

function Know.Items()
    return Know.GetTable("items")
end

function Know.Grows()
    return Know.GetTable("grows")
end

function Know.Refines()
    return Know.GetTable("refines")
end

function Know.Recipes()
    return Know.GetTable("recipes")
end

function Know.Potions()
    return Know.GetTable("potions")
end

function Know.Additives()
    return Know.GetTable("additives")
end

function Know.VendorItems()
    return Know.GetTable("vendorItems")
end

function Know.Touch(reason)
    Know._gen = (tonumber(Know._gen) or 0) + 1
    if StockPiler3.Debug and StockPiler3.Debug.LogOp then
        StockPiler3.Debug.LogOp("know", "touch gen=" .. tostring(Know._gen) .. " reason=" .. tostring(reason or ""))
    end
    local B = StockPiler3.EventBus
    local E = StockPiler3.Events
    if B and B.Fire and E and E.KNOWLEDGE_UPDATED then
        B.Fire(E.KNOWLEDGE_UPDATED, { reason = tostring(reason or ""), gen = Know._gen })
    end
end
