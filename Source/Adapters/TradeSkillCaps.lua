----------------------------------------------------------------
-- StockPiler3 Adapters/TradeSkillCaps — cached cult/apo skill levels
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.TradeSkillCaps = StockPiler3.TradeSkillCaps or {}
local Caps = StockPiler3.TradeSkillCaps

Caps._cache = Caps._cache or nil
Caps._skillsReady = Caps._skillsReady == true

local function SkillId(name, fallback)
    if GameData and GameData.TradeSkills and GameData.TradeSkills[name] then
        return GameData.TradeSkills[name]
    end
    return fallback
end

local function ReadLevel(skillId)
    skillId = tonumber(skillId) or 0
    if skillId <= 0 then
        return 0
    end
    if GameData and GameData.Player and type(GameData.Player.tradeSkills) == "table" then
        local row = GameData.Player.tradeSkills[skillId]
        if type(row) == "table" then
            return tonumber(row.level) or 0
        end
        if row ~= nil then
            return tonumber(row) or 0
        end
    end
    if GameData and type(GameData.TradeSkillLevels) == "table" then
        return tonumber(GameData.TradeSkillLevels[skillId]) or 0
    end
    if GameData and type(GameData.TradeSkillData) == "table" then
        local row = GameData.TradeSkillData[skillId]
        if type(row) == "table" then
            return tonumber(row.level) or tonumber(row.SkillLevel) or 0
        end
        if row ~= nil then
            return tonumber(row) or 0
        end
    end
    return 0
end

local function BuildCache()
    local cultId = SkillId("CULTIVATION", 3)
    local apoId = SkillId("APOTHECARY", 4)
    local cult = ReadLevel(cultId)
    local apo = ReadLevel(apoId)
    Caps._cache = {
        cultId = cultId,
        apoId = apoId,
        cult = cult,
        apo = apo,
    }
    if cult > 0 or apo > 0 then
        Caps._skillsReady = true
    end
    return Caps._cache
end

local function EnsureCache()
    if type(Caps._cache) ~= "table" then
        return BuildCache()
    end
    return Caps._cache
end

function Caps.Invalidate()
    Caps._cache = nil
end

function Caps.Refresh()
    return BuildCache()
end

function Caps.CultivationId()
    return SkillId("CULTIVATION", 3)
end

function Caps.ApothecaryId()
    return SkillId("APOTHECARY", 4)
end

function Caps.Level(skillId)
    skillId = tonumber(skillId) or 0
    local c = EnsureCache()
    if skillId == c.cultId then
        return c.cult
    end
    if skillId == c.apoId then
        return c.apo
    end
    return ReadLevel(skillId)
end

function Caps.GetCultSkill()
    return EnsureCache().cult
end

function Caps.GetApoSkill()
    return EnsureCache().apo
end

-- Aliases
function Caps.CultivationLevel()
    return Caps.GetCultSkill()
end

function Caps.ApothecaryLevel()
    return Caps.GetApoSkill()
end

function Caps.AreTradeSkillsReady()
    if Caps._skillsReady == true then
        return true
    end
    local c = EnsureCache()
    if c.cult > 0 or c.apo > 0 then
        Caps._skillsReady = true
        return true
    end
    return false
end

function Caps.MarkTradeSkillsReady()
    Caps._skillsReady = true
end

function Caps.ResetTradeSkillsReady()
    Caps._skillsReady = false
    Caps.Invalidate()
end

function Caps.CanAutoGrow()
    return Caps.GetCultSkill() > 0
end

function Caps.CanApothecary()
    return Caps.GetApoSkill() > 0
end

function Caps.CanBrewPotions()
    return Caps.CanApothecary()
end

function Caps.HasCultivation()
    return Caps.CanAutoGrow()
end

function Caps.HasApothecary()
    return Caps.CanApothecary()
end

function Caps.CanAutoBuy()
    return Caps.CanAutoGrow() or Caps.CanApothecary()
end

function Caps.LevelsHash()
    local c = EnsureCache()
    return tostring(c.cult) .. ":" .. tostring(c.apo)
end
