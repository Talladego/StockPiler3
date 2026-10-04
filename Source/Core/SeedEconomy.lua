----------------------------------------------------------------
-- StockPiler3 Core/SeedEconomy -- shared seed budget / deficit
-- Grow, Refine, UpgradeSeed, and SkillUp all consult these.
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.SeedEconomy = StockPiler3.SeedEconomy or {}
local SE = StockPiler3.SeedEconomy

local function EmptyBudget()
    return {
        live = 0,
        ground = 0,
        outstanding = 0,
        credit = 0,
        headroom = 0,
        bufferMin = 0,
        unsettled = true,
    }
end

function SE.GetSeedBudget(seedUid)
    local Refine = StockPiler3.Refine
    if Refine and Refine.GetSeedBudget then
        local b = Refine.GetSeedBudget(seedUid)
        if type(b) == "table" then
            return b
        end
    end
    local US = StockPiler3.UpgradeSeed
    if US and US.GetSeedBudget then
        local b = US.GetSeedBudget(seedUid)
        if type(b) == "table" then
            return b
        end
    end
    return EmptyBudget()
end

function SE.SeedDeficit(seedUid, mode)
    local US = StockPiler3.UpgradeSeed
    if US and US.SeedDeficit then
        return tonumber(US.SeedDeficit(seedUid, mode)) or 0
    end
    local SkillUp = StockPiler3.SkillUp
    if SkillUp and SkillUp.SeedDeficit then
        return tonumber(SkillUp.SeedDeficit(seedUid)) or 0
    end
    return 0
end

function SE.PlantableSurplus(seedUid, bagSeeds, empty, opts)
    local US = StockPiler3.UpgradeSeed
    if US and US.PlantableSurplus then
        return tonumber(US.PlantableSurplus(seedUid, bagSeeds, empty, opts)) or 0
    end
    local SkillUp = StockPiler3.SkillUp
    if SkillUp and SkillUp.PlantableSurplus then
        return tonumber(SkillUp.PlantableSurplus(seedUid, bagSeeds, empty, opts)) or 0
    end
    return 0
end

function SE.CountEmptyPlots()
    local Grow = StockPiler3.Grow
    if Grow and Grow.CountEmptyPlots then
        return tonumber(Grow.CountEmptyPlots()) or 0
    end
    local US = StockPiler3.UpgradeSeed
    if US and US.CountEmptyPlots then
        return tonumber(US.CountEmptyPlots()) or 0
    end
    return 0
end
