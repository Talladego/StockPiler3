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
    return { enabled = false, targetStock = 40, autoGrow = false }
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

--- Count watches with enabled==true (Clear watches / footer).
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
    watch.enabled = enabled == true
    if enabled == true and opts.fromPotionsToggle == true then
        watch.autoGrow = true
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
    if type(watches) ~= "table" then
        return false
    end
    for _, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true and watch.autoGrow == true then
            return true
        end
    end
    return false
end

function Watch.IsAutoGrowAdditivesEnabled()
    local row = CharacterRow(false)
    return type(row) == "table" and row.autoGrowAdditives == true
end

function Watch.IsSeedBufferEnabled()
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
