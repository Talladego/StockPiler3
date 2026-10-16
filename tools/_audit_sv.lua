-- Offline audit of StockPiler3 SavedVariables.lua (client shutdown).
-- Usage: lua tools/_audit_sv.lua <path-to-SavedVariables.lua>

local path = arg[1]
if not path or path == "" then
    io.stderr:write("usage: lua _audit_sv.lua <SavedVariables.lua>\n")
    os.exit(1)
end

function L(s)
    return s
end

StockPiler3 = StockPiler3 or {}

local chunk, err = loadfile(path)
if not chunk then
    io.stderr:write("LOAD FAIL: " .. tostring(err) .. "\n")
    os.exit(2)
end

local ok, loaded = pcall(chunk)
if not ok then
    io.stderr:write("EXEC FAIL: " .. tostring(loaded) .. "\n")
    os.exit(3)
end

local acct = StockPiler3 and StockPiler3.Account
local settings = StockPiler3 and StockPiler3.Settings

local findings = {}
local function note(sev, msg)
    findings[#findings + 1] = { sev = sev, msg = msg }
    print(string.format("[%s] %s", sev, msg))
end

if type(acct) ~= "table" then
    note("CRIT", "Could not resolve Account table from SavedVariables")
    os.exit(4)
end

local recipes = acct.recipes
local potions = acct.potions
local items = acct.items
local grows = acct.grows

note("INFO", string.format(
    "migrate v2=%s v3=%s v4=%s v5=%s",
    tostring(acct.recipeFingerprintMigrateV2),
    tostring(acct.recipeFingerprintMigrateV3),
    tostring(acct.recipeFingerprintMigrateV4),
    tostring(acct.recipeFingerprintMigrateV5)
))

local function countPairs(t)
    local n = 0
    if type(t) ~= "table" then return 0 end
    for _ in pairs(t) do n = n + 1 end
    return n
end

note("INFO", string.format(
    "counts recipes=%d potions=%d items=%d grows=%d",
    countPairs(recipes), countPairs(potions), countPairs(items), countPairs(grows)
))

-- Recipe key integrity
local recipeKeyMismatch = 0
local recipeEmptySlots = 0
local recipeMissingSlots = 0
local recipeOrphanOutcomes = 0
local recipeDupByLiveFp = {}
local recipeFpCollisions = 0
local incompleteSlotCount = 0
local skillUpRecipes = 0
local bonusNoiseKeys = 0 -- keys still containing TYPE/FAMILY bonus refs 5= or 8=

local function hasBonusNoise(key)
    key = tostring(key or "")
    -- crude: b:...5= or ,5= or |b:5= and similarly for 8 (TYPE)
    if string.find(key, "[=,]5=", 1) or string.find(key, "b:5=", 1, true) then
        return true
    end
    if string.find(key, "[=,]8=", 1) or string.find(key, "b:8=", 1, true) then
        return true
    end
    return false
end

if type(recipes) == "table" then
    for key, recipe in pairs(recipes) do
        if type(recipe) ~= "table" then
            note("WARN", "recipes[" .. tostring(key) .. "] is not a table")
        else
            if recipe.skillUpOrigin == true then
                skillUpRecipes = skillUpRecipes + 1
            end
            if hasBonusNoise(key) then
                bonusNoiseKeys = bonusNoiseKeys + 1
            end
            local rk = tostring(recipe.recipeSpecKey or "")
            if rk ~= "" and rk ~= tostring(key) then
                recipeKeyMismatch = recipeKeyMismatch + 1
                if recipeKeyMismatch <= 8 then
                    note("WARN", "recipe key mismatch storeKey vs recipeSpecKey:\n  store="
                        .. tostring(key):sub(1, 100) .. "\n  field=" .. rk:sub(1, 100))
                end
            end
            if type(recipe.slots) ~= "table" then
                recipeMissingSlots = recipeMissingSlots + 1
            elseif #recipe.slots == 0 then
                recipeEmptySlots = recipeEmptySlots + 1
            else
                for i = 1, #recipe.slots do
                    local s = recipe.slots[i]
                    if type(s) == "table" then
                        local spec = s.spec
                        if type(spec) == "table" and spec.incomplete == true then
                            incompleteSlotCount = incompleteSlotCount + 1
                        end
                    end
                end
            end
            -- Group by normalized identity ignoring TYPE/FAMILY for collision detection
            local norm = tostring(key)
            norm = string.gsub(norm, ",5=%d+", "")
            norm = string.gsub(norm, "5=%d+,", "")
            norm = string.gsub(norm, ",8=%d+", "")
            norm = string.gsub(norm, "8=%d+,", "")
            if not recipeDupByLiveFp[norm] then
                recipeDupByLiveFp[norm] = {}
            end
            local bucket = recipeDupByLiveFp[norm]
            bucket[#bucket + 1] = tostring(key)
        end
    end
end

for norm, list in pairs(recipeDupByLiveFp) do
    if #list > 1 then
        recipeFpCollisions = recipeFpCollisions + 1
        if recipeFpCollisions <= 12 then
            note("CORRUPT", string.format(
                "bonus-noise / twin fingerprint cluster (%d keys) normLen=%d",
                #list, #norm
            ))
            for i = 1, math.min(3, #list) do
                print("    key" .. i .. "=" .. list[i]:sub(1, 140))
            end
        end
    end
end

note("INFO", string.format(
    "recipes: keyMismatch=%d emptySlots=%d missingSlots=%d skillUpOrigin=%d incompleteSlots=%d bonusNoiseKeys=%d twinClusters=%d",
    recipeKeyMismatch, recipeEmptySlots, recipeMissingSlots, skillUpRecipes,
    incompleteSlotCount, bonusNoiseKeys, recipeFpCollisions
))

-- Potion integrity
local potionNoKeys = 0
local potionDanglingKeys = 0
local potionDupNames = {}
local potionMultiKeys = 0
local potionActiveMissing = 0
local potionRecipeKeyNotInRecipes = 0

if type(potions) == "table" and type(recipes) == "table" then
    for pk, potion in pairs(potions) do
        if type(potion) == "table" then
            local name = tostring(potion.nameNarrow or potion.name or pk)
            potionDupNames[name] = (potionDupNames[name] or 0) + 1
            local keys = {}
            local function add(k)
                k = tostring(k or "")
                if k ~= "" then keys[#keys + 1] = k end
            end
            if type(potion.recipeKeys) == "table" then
                for i = 1, #potion.recipeKeys do add(potion.recipeKeys[i]) end
            end
            if type(potion.alternateRecipeSpecKeys) == "table" then
                for i = 1, #potion.alternateRecipeSpecKeys do add(potion.alternateRecipeSpecKeys[i]) end
            end
            add(potion.activeRecipeKey)
            add(potion.activeRecipeSpecKey)
            add(potion.recipeSpecKey)
            -- dedupe
            local seen = {}
            local uniq = {}
            for i = 1, #keys do
                if not seen[keys[i]] then
                    seen[keys[i]] = true
                    uniq[#uniq + 1] = keys[i]
                end
            end
            if #uniq == 0 then
                potionNoKeys = potionNoKeys + 1
            end
            if #uniq > 1 then
                potionMultiKeys = potionMultiKeys + 1
            end
            local active = tostring(potion.activeRecipeKey or potion.activeRecipeSpecKey or potion.recipeSpecKey or "")
            if active ~= "" and type(recipes[active]) ~= "table" then
                potionActiveMissing = potionActiveMissing + 1
                if potionActiveMissing <= 6 then
                    note("CORRUPT", "potion active recipe missing from recipes: " .. name
                        .. " key=" .. active:sub(1, 100))
                end
            end
            for i = 1, #uniq do
                if type(recipes[uniq[i]]) ~= "table" then
                    potionRecipeKeyNotInRecipes = potionRecipeKeyNotInRecipes + 1
                    potionDanglingKeys = potionDanglingKeys + 1
                    if potionDanglingKeys <= 8 then
                        note("CORRUPT", "potion dangling recipeKey: " .. name
                            .. " key=" .. uniq[i]:sub(1, 100))
                    end
                    break
                end
            end
        end
    end
end

local dupPotionNames = 0
for name, n in pairs(potionDupNames) do
    if n > 1 then
        dupPotionNames = dupPotionNames + 1
        if dupPotionNames <= 8 then
            note("WARN", string.format("duplicate potion name rows name=%s count=%d", name, n))
        end
    end
end

note("INFO", string.format(
    "potions: noKeys=%d multiKeys=%d activeMissing=%d dangling=%d dupNames=%d",
    potionNoKeys, potionMultiKeys, potionActiveMissing, potionRecipeKeyNotInRecipes, dupPotionNames
))

-- Items incomplete / kind weirdness
local itemIncomplete = 0
local itemKindPotionIncomplete = 0
local itemMissingUid = 0
if type(items) == "table" then
    for id, row in pairs(items) do
        if type(row) == "table" then
            if row.incomplete == true then
                itemIncomplete = itemIncomplete + 1
                if tostring(row.kind or "") == "potion" then
                    itemKindPotionIncomplete = itemKindPotionIncomplete + 1
                end
            end
            local uid = tonumber(row.uniqueID) or tonumber(id) or 0
            if uid <= 0 then
                itemMissingUid = itemMissingUid + 1
            end
        end
    end
end
note("INFO", string.format(
    "items: incomplete=%d incompletePotionKind=%d missingUid=%d",
    itemIncomplete, itemKindPotionIncomplete, itemMissingUid
))

-- Watch integrity
local watchDangling = 0
local watchEnabled = 0
local watchComposite = 0
local watchPlain = 0
if type(settings) == "table" and type(settings.characters) == "table" then
    for charName, char in pairs(settings.characters) do
        if type(char) == "table" and type(char.watches) == "table" then
            for wk, watch in pairs(char.watches) do
                if type(watch) == "table" then
                    if watch.enabled == true then
                        watchEnabled = watchEnabled + 1
                    end
                    local key = tostring(wk)
                    if string.find(key, "|rk:", 1, true) then
                        watchComposite = watchComposite + 1
                        local rk = key:match("|rk:(.+)$")
                        if rk and type(recipes) == "table" and type(recipes[rk]) ~= "table" then
                            watchDangling = watchDangling + 1
                            if watchDangling <= 8 then
                                note("CORRUPT", "watch composite recipe missing: char="
                                    .. tostring(charName) .. " key=" .. key:sub(1, 120))
                            end
                        end
                    else
                        watchPlain = watchPlain + 1
                    end
                end
            end
        end
    end
else
    note("WARN", "Settings.characters not found (watch audit skipped)")
end
note("INFO", string.format(
    "watches: enabled=%d composite=%d plain=%d danglingRecipe=%d",
    watchEnabled, watchComposite, watchPlain, watchDangling
))

-- Orphan recipes (not referenced by any potion)
local orphanRecipes = 0
if type(recipes) == "table" and type(potions) == "table" then
    local referenced = {}
    for _, potion in pairs(potions) do
        if type(potion) == "table" then
            local function mark(k)
                k = tostring(k or "")
                if k ~= "" then referenced[k] = true end
            end
            if type(potion.recipeKeys) == "table" then
                for i = 1, #potion.recipeKeys do mark(potion.recipeKeys[i]) end
            end
            if type(potion.alternateRecipeSpecKeys) == "table" then
                for i = 1, #potion.alternateRecipeSpecKeys do mark(potion.alternateRecipeSpecKeys[i]) end
            end
            mark(potion.activeRecipeKey)
            mark(potion.activeRecipeSpecKey)
            mark(potion.recipeSpecKey)
        end
    end
    for k, recipe in pairs(recipes) do
        if type(recipe) == "table" and not referenced[tostring(k)] then
            orphanRecipes = orphanRecipes + 1
        end
    end
end
note("INFO", "orphan recipes (unreferenced by potions)=" .. tostring(orphanRecipes))

-- Summary severity
local crit, corrupt, warn = 0, 0, 0
for i = 1, #findings do
    local s = findings[i].sev
    if s == "CRIT" then crit = crit + 1
    elseif s == "CORRUPT" then corrupt = corrupt + 1
    elseif s == "WARN" then warn = warn + 1
    end
end
print(string.format("\n=== SUMMARY crit=%d corrupt=%d warn=%d info_notes=%d ===",
    crit, corrupt, warn, #findings - crit - corrupt - warn))
