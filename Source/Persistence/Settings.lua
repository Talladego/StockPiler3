----------------------------------------------------------------
-- StockPiler3 Persistence/Settings - profile + account ensure
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Persistence = StockPiler3.Persistence or {}
local P = StockPiler3.Persistence

local ACCOUNT_TABLES = { "items", "grows", "refines", "recipes", "potions", "additives", "vendorItems", "skillUpRates" }

-- Historical leak keys (settings flags written onto Account). Strip on load.
local ACCOUNT_LEAKED_SETTINGS_KEYS = {
    "growPlantSurplusSeeds",
    "autoGrowAdditives",
    "autoGrowEnabled",
    "autoBuyEnabled",
    "autoBuyReserveGold",
    "autoBuyBudgetGold",
    "autoBuySpentBrass",
    "growSeedBufferMin",
    "growSeedBufferEnabled",
    "autoGrowPauseCombat",
    "brewMacroEnabled",
    "brewRespectGrowReserve",
    "brewPreferNonGrowableFirst",
    "watches",
    "characters",
    "debugEnabled",
    "eventTrace",
    "perfEnabled",
    "perfThresholdMs",
    "potionKnownRecipeOnly",
}

-- Must include every ACCOUNT_TABLES key or Shutdown StripUnexpectedAccountKeys
-- will delete them before SavedVariables write (wiped skillUpRates each reload).
local ACCOUNT_ALLOWED = {
    accountVersion = true,
    recipeFingerprintMigrateV2 = true,
    recipeFingerprintMigrateV3 = true,
    recipeFingerprintMigrateV4 = true,
}
for i = 1, #ACCOUNT_TABLES do
    ACCOUNT_ALLOWED[ACCOUNT_TABLES[i]] = true
end

local function ClampInt(n, lo, hi, default)
    n = tonumber(n)
    if n == nil then
        return default
    end
    n = math.floor(n)
    if n < lo then
        return lo
    end
    if n > hi then
        return hi
    end
    return n
end

function P.CopyTable(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = P.CopyTable(v)
    end
    return copy
end

-- NO potionKnownRecipeOnly - known-recipe filter omitted in SP3.
StockPiler3.DefaultSettings = {
    settingsVersion = 1,
    charactersVersion = 1,
    characters = {},
    debugEnabled = false,
    eventTrace = false,
    language = 0,
    selectedTab = 1,
    potionNameFilter = "",
    potionEffectFilter = "",
    potionSortColumn = "name",
    potionSortAscending = true,
    potionHideSkillUp = true,
}

StockPiler3.DefaultCharacterSettings = {
    watches = {},
    autoGrowEnabled = false,
    autoGrowAdditives = false,
    autoBuyEnabled = false,
    autoBuyReserveGold = 10,
    autoBuyBudgetGold = 50,
    autoBuySpentBrass = 0,
    growSeedBufferMin = 5,
    growSeedBufferEnabled = true,
    autoGrowPauseCombat = true,
    brewMacroEnabled = false,
    brewRespectGrowReserve = true,
    -- Brew load: spend butcher/vendor twins before cult plants. Future UI toggle.
    brewPreferNonGrowableFirst = true,
    skillUpCultEnabled = false,
    skillUpApoEnabled = false,
    upgradeSeedsEnabled = false,
}

StockPiler3.DefaultAccount = {
    accountVersion = 3,
    items = {},
    grows = {},
    refines = {},
    recipes = {},
    potions = {},
    additives = {},
    vendorItems = {},
    skillUpRates = { v = 2, cult = {}, apo = {} },
}

function P.ToNarrow(value)
    if value == nil then
        return ""
    end
    if type(value) == "string" then
        return value
    end
    if type(value) == "wstring" then
        if type(WStringToString) ~= "function" then
            return ""
        end
        local ok, text
        if StockPiler3.Debug and StockPiler3.Debug.TryCallQuiet then
            ok, text = StockPiler3.Debug.TryCallQuiet("ToNarrow", WStringToString, value)
        else
            ok, text = pcall(WStringToString, value)
        end
        if ok and type(text) == "string" then
            return text
        end
        return ""
    end
    return tostring(value)
end

--- Character key = player name with trailing ^realm markup stripped.
function P.GetCharacterKey()
    if GameData and GameData.Player and GameData.Player.name then
        local name = GameData.Player.name
        if type(name) == "wstring" then
            local narrow = P.ToNarrow(name)
            if type(narrow) == "string" and narrow ~= "" then
                if string.len(narrow) >= 2 and string.sub(narrow, -2, -2) == "^" then
                    narrow = string.sub(narrow, 1, -3)
                end
                narrow = string.gsub(narrow, "%^.*$", "")
                narrow = string.gsub(narrow, "^%s+", "")
                narrow = string.gsub(narrow, "%s+$", "")
                if narrow ~= "" then
                    return narrow
                end
            end
        elseif type(name) == "string" and name ~= "" then
            local narrow = name
            if string.len(narrow) >= 2 and string.sub(narrow, -2, -2) == "^" then
                narrow = string.sub(narrow, 1, -3)
            end
            narrow = string.gsub(narrow, "%^.*$", "")
            if narrow ~= "" then
                return narrow
            end
        end
    end
    return "_default"
end

function P.EnsureSettings()
    local s = StockPiler3.Settings
    if type(s) ~= "table" then
        s = P.CopyTable(StockPiler3.DefaultSettings)
        StockPiler3.Settings = s
    end
    if s.settingsVersion == nil then
        s.settingsVersion = 1
    end
    if s.charactersVersion == nil then
        s.charactersVersion = 1
    end
    if type(s.characters) ~= "table" then
        s.characters = {}
    end
    if s.potionNameFilter == nil then
        s.potionNameFilter = ""
    end
    if s.potionEffectFilter == nil then
        s.potionEffectFilter = ""
    end
    if s.potionSortColumn == nil then
        s.potionSortColumn = "name"
    end
    if s.potionSortAscending == nil then
        s.potionSortAscending = true
    end
    if s.potionHideSkillUp == nil then
        s.potionHideSkillUp = true
    end
    if s.selectedTab == nil then
        s.selectedTab = 1
    end
    if s.language == nil then
        s.language = 0
    end
    -- Explicitly drop known-filter if somehow present in old SV.
    if s.potionKnownRecipeOnly ~= nil then
        s.potionKnownRecipeOnly = nil
    end
    if s.perfEnabled ~= nil then
        s.perfEnabled = nil
    end
    if s.perfThresholdMs ~= nil then
        s.perfThresholdMs = nil
    end
    if StockPiler3.Debug then
        StockPiler3.Debug.Enabled = s.debugEnabled == true
        StockPiler3.Debug.EventTrace = s.eventTrace == true
    end
    return s
end

function P.EnsureCharacterBucketShape(char)
    if type(char) ~= "table" then
        char = {}
    end
    local defaults = StockPiler3.DefaultCharacterSettings
    for k, v in pairs(defaults) do
        if char[k] == nil then
            if type(v) == "table" then
                char[k] = {}
            else
                char[k] = v
            end
        end
    end
    if type(char.watches) ~= "table" then
        char.watches = {}
    end
    char.autoGrowEnabled = char.autoGrowEnabled == true
    char.autoGrowAdditives = char.autoGrowAdditives == true
    char.autoBuyEnabled = char.autoBuyEnabled == true
    char.brewMacroEnabled = char.brewMacroEnabled == true
    char.brewRespectGrowReserve = char.brewRespectGrowReserve ~= false
    char.brewPreferNonGrowableFirst = char.brewPreferNonGrowableFirst ~= false
    char.growSeedBufferEnabled = char.growSeedBufferEnabled ~= false
    char.autoGrowPauseCombat = char.autoGrowPauseCombat ~= false
    char.skillUpCultEnabled = char.skillUpCultEnabled == true
    char.skillUpApoEnabled = char.skillUpApoEnabled == true
    char.upgradeSeedsEnabled = char.upgradeSeedsEnabled == true
    char.autoBuyReserveGold = ClampInt(char.autoBuyReserveGold, 1, 99, 10)
    char.autoBuyBudgetGold = ClampInt(char.autoBuyBudgetGold, 1, 999, 50)
    do
        local spent = tonumber(char.autoBuySpentBrass)
        if spent == nil or spent < 0 then
            char.autoBuySpentBrass = 0
        else
            char.autoBuySpentBrass = math.floor(spent)
        end
    end
    char.growSeedBufferMin = ClampInt(char.growSeedBufferMin, 4, 20, 5)
    return char
end

function P.GetCharacterBucket(create)
    local settings = P.EnsureSettings()
    settings.characters = type(settings.characters) == "table" and settings.characters or {}
    local key = P.GetCharacterKey()
    local row = settings.characters[key]
    if type(row) ~= "table" then
        if create == false then
            return nil, key
        end
        row = P.CopyTable(StockPiler3.DefaultCharacterSettings)
        settings.characters[key] = row
    end
    return P.EnsureCharacterBucketShape(row), key
end

function P.EnsureAccount()
    local a = StockPiler3.Account
    if type(a) ~= "table" then
        a = P.CopyTable(StockPiler3.DefaultAccount)
        StockPiler3.Account = a
    end
    if a.accountVersion == nil then
        a.accountVersion = 3
    end
    for i = 1, #ACCOUNT_TABLES do
        local k = ACCOUNT_TABLES[i]
        if type(a[k]) ~= "table" then
            a[k] = {}
        end
    end
    for i = 1, #ACCOUNT_LEAKED_SETTINGS_KEYS do
        local k = ACCOUNT_LEAKED_SETTINGS_KEYS[i]
        if a[k] ~= nil then
            a[k] = nil
        end
    end
    -- Only shape knowledge tables here - never migrate (would recurse via
    -- Recipes->GetAccount->EnsureAccount). Bootstrap calls MigrateFingerprints after.
    if StockPiler3.Knowledge and StockPiler3.Knowledge.Ensure then
        StockPiler3.Knowledge.Ensure()
    end
    return a
end

--- Report unexpected Account top-level keys (for /sp3 audit).
function P.AuditAccountKeys()
    local a = StockPiler3.Account
    local unexpected = {}
    if type(a) ~= "table" then
        return unexpected
    end
    for k, _ in pairs(a) do
        if ACCOUNT_ALLOWED[k] ~= true then
            unexpected[#unexpected + 1] = tostring(k)
        end
    end
    table.sort(unexpected)
    return unexpected
end

function P.StripUnexpectedAccountKeys()
    local a = StockPiler3.Account
    if type(a) ~= "table" then
        return 0
    end
    local n = 0
    local removed = {}
    for k, _ in pairs(a) do
        if ACCOUNT_ALLOWED[k] ~= true then
            removed[#removed + 1] = tostring(k)
            a[k] = nil
            n = n + 1
        end
    end
    if n > 0 and StockPiler3.Debug and StockPiler3.Debug.LogOp then
        StockPiler3.Debug.LogOp("persist", "strip-account-keys n=" .. tostring(n)
            .. " keys=" .. table.concat(removed, ","))
    end
    return n
end
