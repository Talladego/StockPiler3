----------------------------------------------------------------
-- StockPiler3 Adapters/TradeSkillCaps - live cult/apo skill levels
-- Read GameData on each call (SP2 style). Engine often leaves tradeSkills
-- empty until TRADE_SKILL_UPDATED; never treat a mid-session 0 as unlearned
-- after we have seen a real level (combat / scenario / zone blips).
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.TradeSkillCaps = StockPiler3.TradeSkillCaps or {}
local Caps = StockPiler3.TradeSkillCaps

Caps._skillsReady = Caps._skillsReady == true
Caps._lastCult = tonumber(Caps._lastCult) or 0
Caps._lastApo = tonumber(Caps._lastApo) or 0
-- After LOADING_END, next TRADE_SKILL_UPDATED may legitimately report 0 (new char).
Caps._pendingLoadRefresh = Caps._pendingLoadRefresh == true

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

local function StickLevel(live, last)
    live = tonumber(live) or 0
    last = tonumber(last) or 0
    if live > 0 then
        return live, live
    end
    -- Transient empty (combat/scenario): keep last known.
    if last > 0 then
        return last, last
    end
    return 0, 0
end

function Caps.Refresh()
    if Caps.GetCultSkill() > 0 or Caps.GetApoSkill() > 0 then
        Caps._skillsReady = true
    end
end

function Caps.CultivationId()
    return SkillId("CULTIVATION", 3)
end

function Caps.ApothecaryId()
    return SkillId("APOTHECARY", 4)
end

--- Abilities-window trade skill icon id (GetTradeskillIcon). 0 if unavailable.
function Caps.GetTradeSkillIcon(skillId)
    skillId = tonumber(skillId) or 0
    if skillId <= 0 then
        return 0
    end
    if type(GetTradeskillIcon) == "function" then
        local ok, icon = pcall(GetTradeskillIcon, skillId)
        if ok == true then
            return tonumber(icon) or 0
        end
    end
    return 0
end

function Caps.GetCultivationIcon()
    return Caps.GetTradeSkillIcon(Caps.CultivationId())
end

function Caps.GetApothecaryIcon()
    return Caps.GetTradeSkillIcon(Caps.ApothecaryId())
end

function Caps.Level(skillId)
    return ReadLevel(skillId)
end

--- Live engine read (ignores sticky cache). For load/char-switch reconciliation.
function Caps.ReadCultSkillLive()
    return ReadLevel(Caps.CultivationId())
end

function Caps.ReadApoSkillLive()
    return ReadLevel(Caps.ApothecaryId())
end

function Caps.GetCultSkill()
    local live = ReadLevel(Caps.CultivationId())
    local out
    out, Caps._lastCult = StickLevel(live, Caps._lastCult)
    return out
end

function Caps.GetApoSkill()
    local live = ReadLevel(Caps.ApothecaryId())
    local out
    out, Caps._lastApo = StickLevel(live, Caps._lastApo)
    return out
end

--- Call from LOADING_END so the next TRADE_SKILL_UPDATED can accept real zeros.
function Caps.BeginLoadSkillRefresh()
    Caps._pendingLoadRefresh = true
end

--- Apply a TRADE_SKILL_UPDATED pulse. When pending load refresh, trust live zeros
--- (character switch / first populate). Otherwise ignore transient zeros.
function Caps.OnTradeSkillPulse()
    local liveCult = ReadLevel(Caps.CultivationId())
    local liveApo = ReadLevel(Caps.ApothecaryId())
    if Caps._pendingLoadRefresh == true then
        Caps._lastCult = liveCult
        Caps._lastApo = liveApo
        Caps._pendingLoadRefresh = false
    else
        if liveCult > 0 then
            Caps._lastCult = liveCult
        end
        if liveApo > 0 then
            Caps._lastApo = liveApo
        end
    end
    if Caps._lastCult > 0 or Caps._lastApo > 0 then
        Caps._skillsReady = true
    end
end

function Caps.AreTradeSkillsReady()
    if Caps._skillsReady == true then
        return true
    end
    if Caps.GetCultSkill() > 0 or Caps.GetApoSkill() > 0 then
        Caps._skillsReady = true
        return true
    end
    return false
end

function Caps.MarkTradeSkillsReady()
    Caps.OnTradeSkillPulse()
    Caps.Refresh()
    if Caps.GetCultSkill() > 0 or Caps.GetApoSkill() > 0 then
        Caps._skillsReady = true
    end
end

function Caps.ResetTradeSkillsReady()
    Caps._skillsReady = false
    -- Keep _lastCult/_lastApo across combat/zone unless BeginLoadSkillRefresh
    -- + OnTradeSkillPulse replaces them. Avoids SkillUp rows vanishing when the
    -- engine briefly reports tradeSkills empty.
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

function Caps.CanAutoBuy()
    return Caps.CanAutoGrow() or Caps.CanApothecary()
end

function Caps.LevelsHash()
    return tostring(Caps.GetCultSkill()) .. ":" .. tostring(Caps.GetApoSkill())
end
