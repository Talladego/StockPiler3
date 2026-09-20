----------------------------------------------------------------
-- StockPiler3 Stores/WatchStore — per-character watches + toggles
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Watch = StockPiler3.Watch or {}
local Watch = StockPiler3.Watch

Watch._gen = 0

--- Per-character settings bucket (autoGrowEnabled, watches, AutoBuy, etc.).
function Watch.CharacterRow(create)
    if StockPiler3.Persistence and StockPiler3.Persistence.GetCharacterBucket then
        return StockPiler3.Persistence.GetCharacterBucket(create ~= false)
    end
    return nil
end

-- Alias: some call sites expect GetCharacter for settings access.
Watch.GetCharacter = Watch.CharacterRow

local function CharacterRow(create)
    return Watch.CharacterRow(create)
end

function Watch.GetGen()
    return tonumber(Watch._gen) or 0
end

function Watch.BumpGen()
    Watch._gen = (tonumber(Watch._gen) or 0) + 1
end

function Watch.GetCharacterKey()
    if StockPiler3.Persistence and StockPiler3.Persistence.GetCharacterKey then
        return StockPiler3.Persistence.GetCharacterKey()
    end
    return "_default"
end

function Watch.GetWatches()
    local row = CharacterRow(true)
    if type(row) ~= "table" or type(row.watches) ~= "table" then
        return {}
    end
    return row.watches
end

local function DefaultWatch()
    return { enabled = false, targetStock = 40, autoGrow = false, priorityTier = nil }
end

--- Read-only watch peek (does not create SV stubs).
function Watch.GetWatch(recipeKey)
    local key = tostring(recipeKey or "")
    if key == "" then
        return DefaultWatch()
    end
    local row = CharacterRow(false)
    if type(row) ~= "table" or type(row.watches) ~= "table" then
        return DefaultWatch()
    end
    local watch = row.watches[key]
    if type(watch) ~= "table" then
        return DefaultWatch()
    end
    return watch
end

--- Count watches with enabled==true (Clear watches / footer / priority N).
function Watch.CountEnabled()
    local watches = Watch.GetWatches()
    local n = 0
    if type(watches) ~= "table" then
        return 0
    end
    for _, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            n = n + 1
        end
    end
    return n
end

local function MaxPriorityTier(excludeKey)
    excludeKey = excludeKey and tostring(excludeKey) or nil
    local watches = Watch.GetWatches()
    local maxTier = 0
    if type(watches) ~= "table" then
        return 0
    end
    for key, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true and tostring(key) ~= excludeKey then
            local t = tonumber(watch.priorityTier) or 0
            if t > maxTier then
                maxTier = t
            end
        end
    end
    return maxTier
end

--- Next unique tier for a newly enabled watch (add order).
function Watch.NextPriorityTier(excludeKey)
    return MaxPriorityTier(excludeKey) + 1
end

function Watch.GetPriorityTier(recipeKey)
    local watch = Watch.GetWatch(recipeKey)
    local n = Watch.CountEnabled()
    if n < 1 then
        n = 1
    end
    local t = tonumber(watch and watch.priorityTier)
    if t == nil or t < 1 then
        return 1
    end
    if t > n then
        return n
    end
    return math.floor(t)
end

function Watch.ClampAllPriorityTiers()
    local watches = Watch.GetWatches()
    local n = Watch.CountEnabled()
    if type(watches) ~= "table" then
        return
    end
    if n < 1 then
        n = 1
    end
    for _, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            local t = tonumber(watch.priorityTier)
            if t == nil or t < 1 then
                watch.priorityTier = 1
            elseif t > n then
                watch.priorityTier = n
            else
                watch.priorityTier = math.floor(t)
            end
        end
    end
end

--- Remap enabled tiers to dense 1..K preserving shared groups and relative order.
function Watch.DensifyPriorityTiers()
    local watches = Watch.GetWatches()
    if type(watches) ~= "table" then
        return
    end
    local used = {}
    for _, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            local t = tonumber(watch.priorityTier)
            if t ~= nil and t >= 1 then
                used[math.floor(t)] = true
            end
        end
    end
    local sorted = {}
    for t in pairs(used) do
        sorted[#sorted + 1] = t
    end
    table.sort(sorted)
    if #sorted == 0 then
        return
    end
    local map = {}
    for i = 1, #sorted do
        map[sorted[i]] = i
    end
    local changed = false
    for _, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            local t = tonumber(watch.priorityTier)
            if t ~= nil and map[math.floor(t)] ~= nil then
                local neu = map[math.floor(t)]
                if watch.priorityTier ~= neu then
                    watch.priorityTier = neu
                    changed = true
                end
            end
        end
    end
    Watch.ClampAllPriorityTiers()
    if changed then
        Watch.BumpGen()
    end
end

local function WatchDisplayName(key, watch)
    local RS = StockPiler3.RecipeSpec
    if RS and RS.ResolveWatchPotion then
        local resolved = RS.ResolveWatchPotion(key)
        local potion = resolved and resolved.potion
        if type(potion) == "table" and potion.name ~= nil then
            if StockPiler3.Persistence and StockPiler3.Persistence.ToNarrow then
                return StockPiler3.Persistence.ToNarrow(potion.name)
            end
            return tostring(potion.name)
        end
    end
    return tostring(key or "")
end

--- One-shot: assign unique 1..N by name/key for legacy saves without tiers.
function Watch.MigratePriorityTiersIfNeeded()
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return false
    end
    if row.watchPriorityTiersMigrated == true then
        return false
    end
    local watches = row.watches
    if type(watches) ~= "table" then
        row.watchPriorityTiersMigrated = true
        return false
    end
    local list = {}
    for key, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            list[#list + 1] = { key = tostring(key), watch = watch }
        end
    end
    table.sort(list, function(a, b)
        local na = WatchDisplayName(a.key, a.watch)
        local nb = WatchDisplayName(b.key, b.watch)
        if na ~= nb then
            return na < nb
        end
        return a.key < b.key
    end)
    for i = 1, #list do
        list[i].watch.priorityTier = i
    end
    row.watchPriorityTiersMigrated = true
    Watch.BumpGen()
    return true
end

function Watch.SetPriorityTier(recipeKey, tier)
    local watch = Watch.EnsureWatch(recipeKey)
    if type(watch) ~= "table" or watch.enabled ~= true then
        return watch
    end
    local n = Watch.CountEnabled()
    if n < 1 then
        n = 1
    end
    tier = tonumber(tier)
    if tier == nil then
        return watch
    end
    tier = math.floor(tier)
    if tier < 1 then
        tier = 1
    elseif tier > n then
        tier = n
    end
    watch.priorityTier = tier
    Watch.BumpGen()
    return watch
end

function Watch.BumpPriorityTier(recipeKey, delta)
    delta = tonumber(delta) or 0
    if delta == 0 then
        return Watch.GetWatch(recipeKey)
    end
    local cur = Watch.GetPriorityTier(recipeKey)
    return Watch.SetPriorityTier(recipeKey, cur + delta)
end

--- Remove disabled watch rows that still look like EnsureWatch defaults
--- (from Potions list creating SV stubs). Keeps unchecked watches with custom target/autoGrow.
function Watch.ScrubPristineDisabledStubs()
    local row = CharacterRow(false)
    if type(row) ~= "table" or type(row.watches) ~= "table" then
        return 0
    end
    local n = 0
    for key, watch in pairs(row.watches) do
        if type(watch) == "table"
            and watch.enabled ~= true
            and (tonumber(watch.targetStock) or 40) == 40
            and watch.autoGrow ~= true
        then
            row.watches[key] = nil
            n = n + 1
        end
    end
    if n > 0 then
        Watch.BumpGen()
    end
    return n
end

--- Remove all disabled watch rows (optional cleanup; not used on list refresh —
--- unchecked watches may still hold targetStock / autoGrow).
function Watch.ScrubDisabledStubs()
    local row = CharacterRow(false)
    if type(row) ~= "table" or type(row.watches) ~= "table" then
        return 0
    end
    local n = 0
    for key, watch in pairs(row.watches) do
        if type(watch) ~= "table" or watch.enabled ~= true then
            row.watches[key] = nil
            n = n + 1
        end
    end
    if n > 0 then
        Watch.BumpGen()
    end
    return n
end

--- Ensure watch row. Defaults: enabled=false, targetStock=40, autoGrow=false.
--- When opts.fromPotionsToggle (or opts.autoGrow=true), new rows get autoGrow=true.
function Watch.EnsureWatch(recipeKey, opts)
    opts = type(opts) == "table" and opts or {}
    local key = tostring(recipeKey or "")
    local defaultAutoGrow = false
    if opts.fromPotionsToggle == true or opts.autoGrow == true then
        defaultAutoGrow = true
    end
    if key == "" then
        return { enabled = false, targetStock = 40, autoGrow = defaultAutoGrow }
    end
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return { enabled = false, targetStock = 40, autoGrow = defaultAutoGrow }
    end
    if type(row.watches) ~= "table" then
        row.watches = {}
    end
    local watch = row.watches[key]
    if type(watch) ~= "table" then
        watch = {
            enabled = false,
            targetStock = 40,
            autoGrow = defaultAutoGrow,
        }
        row.watches[key] = watch
        Watch.BumpGen()
    end
    if watch.targetStock == nil then
        watch.targetStock = 40
    end
    if watch.autoGrow == nil then
        watch.autoGrow = defaultAutoGrow
    end
    if watch.enabled == nil then
        watch.enabled = false
    end
    return watch
end

function Watch.SetTarget(recipeKey, targetStock)
    local watch = Watch.EnsureWatch(recipeKey)
    targetStock = tonumber(targetStock)
    if targetStock == nil then
        return watch
    end
    if targetStock < 0 then
        targetStock = 0
    end
    watch.targetStock = math.floor(targetStock)
    Watch.BumpGen()
    return watch
end

function Watch.SetAutoGrow(recipeKey, enabled)
    local watch = Watch.EnsureWatch(recipeKey)
    watch.autoGrow = enabled == true
    Watch.BumpGen()
    return watch
end

function Watch.SetEnabled(recipeKey, enabled, opts)
    opts = type(opts) == "table" and opts or {}
    if enabled == true and opts.fromPotionsToggle == true then
        opts.autoGrow = true
    end
    local watch = Watch.EnsureWatch(recipeKey, opts)
    local wasEnabled = watch.enabled == true
    watch.enabled = enabled == true
    if enabled == true and opts.fromPotionsToggle == true then
        watch.autoGrow = true
    end
    if enabled == true then
        if not wasEnabled or tonumber(watch.priorityTier) == nil then
            watch.priorityTier = Watch.NextPriorityTier(recipeKey)
        end
        Watch.ClampAllPriorityTiers()
    else
        if wasEnabled then
            Watch.DensifyPriorityTiers()
            Watch.ClampAllPriorityTiers()
        end
    end
    Watch.BumpGen()
    return watch
end

function Watch.ClearAll()
    local row = CharacterRow(true)
    local enabledN = 0
    if type(row) == "table" and type(row.watches) == "table" then
        for _, watch in pairs(row.watches) do
            if type(watch) == "table" and watch.enabled == true then
                enabledN = enabledN + 1
            end
        end
        -- Drop enabled watches and disabled list stubs alike.
        row.watches = {}
    end
    Watch.BumpGen()
    if StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Invalidate then
        StockPiler3.PlanSnapshot.Invalidate()
    end
    return enabledN
end

function Watch.IsAutoGrowEnabled()
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local row = CharacterRow(false)
    return type(row) == "table" and row.autoGrowEnabled == true
end

--- True when master AutoGrow is on and at least one enabled watch has AutoGrow.
function Watch.HasAnyAutoGrow()
    if Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local watches = Watch.GetWatches()
    if type(watches) == "table" then
        for _, watch in pairs(watches) do
            if type(watch) == "table" and watch.enabled == true and watch.autoGrow == true then
                return true
            end
        end
    end
    if Watch.CountEnabledPlantWatches and Watch.CountEnabledPlantWatches() > 0 then
        return true
    end
    return false
end

function Watch.IsAutoGrowAdditivesEnabled()
    local row = CharacterRow(false)
    return type(row) == "table" and row.autoGrowAdditives == true
end

function Watch.IsSeedBufferEnabled()
    local Caps = StockPiler3.TradeSkillCaps
    if not (Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true) then
        return false
    end
    local row = CharacterRow(false)
    if type(row) ~= "table" then
        return true
    end
    return row.growSeedBufferEnabled ~= false
end

function Watch.GetSeedBufferMin()
    local row = CharacterRow(false)
    local n = type(row) == "table" and tonumber(row.growSeedBufferMin) or nil
    if n == nil or n < 0 then
        return 5
    end
    return math.floor(n)
end

function Watch.IsAutoGrowPauseCombat()
    local row = CharacterRow(false)
    if type(row) ~= "table" then
        return true
    end
    return row.autoGrowPauseCombat ~= false
end

-- Alias used by Scheduler.ShouldDeferAutoGrowPlant
function Watch.IsCombatPauseEnabled()
    return Watch.IsAutoGrowPauseCombat()
end

function Watch.IsAutoBuyEnabled()
    local row = CharacterRow(false)
    return type(row) == "table" and row.autoBuyEnabled == true
end

function Watch.GetAutoBuyReserveGold()
    local row = CharacterRow(false)
    local n = type(row) == "table" and tonumber(row.autoBuyReserveGold) or nil
    if n == nil or n < 1 then
        return 10
    end
    if n > 99 then
        return 99
    end
    return math.floor(n)
end

function Watch.GetAutoBuyBudgetGold()
    local row = CharacterRow(false)
    local n = type(row) == "table" and tonumber(row.autoBuyBudgetGold) or nil
    if n == nil or n < 1 then
        return 50
    end
    if n > 999 then
        return 999
    end
    return math.floor(n)
end

--- Lifetime AutoBuy spend (brass) against autoBuyBudgetGold until manual reset.
function Watch.GetAutoBuySpentBrass()
    local row = CharacterRow(false)
    local n = type(row) == "table" and tonumber(row.autoBuySpentBrass) or nil
    if n == nil or n < 0 then
        return 0
    end
    return math.floor(n)
end

function Watch.AddAutoBuySpentBrass(delta)
    delta = tonumber(delta) or 0
    if delta <= 0 then
        return Watch.GetAutoBuySpentBrass()
    end
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return Watch.GetAutoBuySpentBrass()
    end
    local nextVal = (tonumber(row.autoBuySpentBrass) or 0) + math.floor(delta)
    if nextVal < 0 then
        nextVal = 0
    end
    row.autoBuySpentBrass = nextVal
    return nextVal
end

function Watch.ResetAutoBuySpentBrass()
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return 0
    end
    row.autoBuySpentBrass = 0
    return 0
end

----------------------------------------------------------------
-- Plant watches (material stock floors; always below potion priority)
----------------------------------------------------------------

function Watch.PlantKeyFromUid(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return ""
    end
    return "plant:" .. tostring(plantUid)
end

function Watch.ParsePlantKey(key)
    key = tostring(key or "")
    local uid = key:match("^plant:(%d+)$")
    if uid then
        return tonumber(uid) or 0
    end
    return 0
end

function Watch.GetPlantWatches()
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return {}
    end
    if type(row.plantWatches) ~= "table" then
        row.plantWatches = {}
    end
    return row.plantWatches
end

local function DefaultPlantWatch()
    return { enabled = false, targetStock = 40, autoGrow = true }
end

function Watch.GetPlantWatch(plantKey)
    local key = tostring(plantKey or "")
    if key == "" then
        return DefaultPlantWatch()
    end
    local row = CharacterRow(false)
    if type(row) ~= "table" or type(row.plantWatches) ~= "table" then
        return DefaultPlantWatch()
    end
    local watch = row.plantWatches[key]
    if type(watch) ~= "table" then
        return DefaultPlantWatch()
    end
    return watch
end

function Watch.EnsurePlantWatch(plantKey, opts)
    opts = type(opts) == "table" and opts or {}
    local key = tostring(plantKey or "")
    if key == "" then
        return DefaultPlantWatch()
    end
    local row = CharacterRow(true)
    if type(row) ~= "table" then
        return DefaultPlantWatch()
    end
    if type(row.plantWatches) ~= "table" then
        row.plantWatches = {}
    end
    local watch = row.plantWatches[key]
    if type(watch) ~= "table" then
        watch = {
            enabled = false,
            targetStock = 40,
            autoGrow = true,
        }
        row.plantWatches[key] = watch
        Watch.BumpGen()
    end
    if watch.targetStock == nil then
        watch.targetStock = 40
    end
    if watch.autoGrow == nil then
        watch.autoGrow = true
    end
    if watch.enabled == nil then
        watch.enabled = false
    end
    if opts.fromPlantsToggle == true then
        watch.autoGrow = true
    end
    return watch
end

function Watch.SetPlantTarget(plantKey, targetStock)
    local watch = Watch.EnsurePlantWatch(plantKey)
    targetStock = tonumber(targetStock)
    if targetStock == nil then
        return watch
    end
    if targetStock < 0 then
        targetStock = 0
    end
    watch.targetStock = math.floor(targetStock)
    Watch.BumpGen()
    return watch
end

function Watch.SetPlantEnabled(plantKey, enabled, opts)
    opts = type(opts) == "table" and opts or {}
    local watch = Watch.EnsurePlantWatch(plantKey, opts)
    watch.enabled = enabled == true
    if enabled == true then
        watch.autoGrow = true
    end
    Watch.BumpGen()
    return watch
end

function Watch.SetPlantAutoGrow(plantKey, enabled)
    local watch = Watch.EnsurePlantWatch(plantKey)
    watch.autoGrow = enabled == true
    Watch.BumpGen()
    return watch
end

function Watch.CountEnabledPlantWatches()
    local watches = Watch.GetPlantWatches()
    local n = 0
    if type(watches) ~= "table" then
        return 0
    end
    for _, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            n = n + 1
        end
    end
    return n
end

--- True when every enabled potion watch has have >= targetStock.
function Watch.AllEnabledPotionWatchesStocked()
    local watches = Watch.GetWatches()
    if type(watches) ~= "table" then
        return true
    end
    local RS = StockPiler3.RecipeSpec
    local Catalog = StockPiler3.Catalog
    for key, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            local target = tonumber(watch.targetStock) or 40
            local have = 0
            if RS and RS.ResolveWatchPotion then
                local resolved = RS.ResolveWatchPotion(key)
                local potion = resolved and resolved.potion
                if type(potion) == "table" and Catalog and Catalog.PotionHaveCombined then
                    have = tonumber(Catalog.PotionHaveCombined(potion)) or 0
                elseif resolved and resolved.outputUid and StockPiler3.Inventory and StockPiler3.Inventory.CountByUid then
                    have = tonumber(StockPiler3.Inventory.CountByUid(resolved.outputUid)) or 0
                end
            end
            if have < target then
                return false
            end
        end
    end
    return true
end

function Watch.ShouldAutoGrowPlant(plantKey)
    if Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    local watch = Watch.GetPlantWatch(plantKey)
    return type(watch) == "table" and watch.enabled == true and watch.autoGrow ~= false
end
