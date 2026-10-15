----------------------------------------------------------------
-- StockPiler3 Core/SeedEconomy -- seed budget lookup.
-- GetSeedBudget delegates to Refine, then UpgradeSeed. SkillUp keeps its own deficit math.
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
