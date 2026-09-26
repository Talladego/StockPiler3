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
Caps._persistedHydrated = Caps._persistedHydrated == true

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

local function CharBucket(create)
    if StockPiler3.Util and StockPiler3.Util.CharacterRow then
        return StockPiler3.Util.CharacterRow(create == true)
    end
    return nil
end

--- Once per session: seed sticky from last known character skills (survives /reload
--- before the first non-empty TRADE_SKILL_UPDATED).
local function HydrateStickyFromPersist()
    if Caps._persistedHydrated == true then
        return
    end
    Caps._persistedHydrated = true
    local row = CharBucket(false)
    if type(row) ~= "table" then
        return
    end
    local pc = tonumber(row.lastCultSkill) or 0
    local pa = tonumber(row.lastApoSkill) or 0
    if (tonumber(Caps._lastCult) or 0) <= 0 and pc > 0 then
        Caps._lastCult = pc
    end
    if (tonumber(Caps._lastApo) or 0) <= 0 and pa > 0 then
        Caps._lastApo = pa
    end
end

local function PersistSticky()
    local cult = tonumber(Caps._lastCult) or 0
    local apo = tonumber(Caps._lastApo) or 0
    if cult <= 0 and apo <= 0 then
        return
    end
    local row = CharBucket(true)
    if type(row) ~= "table" then
        return
    end
    if cult > 0 then
        row.lastCultSkill = cult
    end
    if apo > 0 then
        row.lastApoSkill = apo
    end
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
    HydrateStickyFromPersist()
    local live = ReadLevel(Caps.CultivationId())
    local out
    out, Caps._lastCult = StickLevel(live, Caps._lastCult)
    return out
end

function Caps.GetApoSkill()
    HydrateStickyFromPersist()
    local live = ReadLevel(Caps.ApothecaryId())
    local out
    out, Caps._lastApo = StickLevel(live, Caps._lastApo)
    return out
end

--- Call from LOADING_END so a later non-empty TRADE_SKILL_UPDATED can refresh.
function Caps.BeginLoadSkillRefresh()
    Caps._pendingLoadRefresh = true
    Caps._loadEmptyPulses = 0
end

--- Apply a TRADE_SKILL_UPDATED pulse.
--- Never replace sticky levels with empty post-load blips (combat/scenario).
--- Authoritative update only when any skill reads > 0. Empty pulses never wipe
--- a known sticky level (char-switch zeros wait for a real non-empty snapshot,
--- or player logout clears session state).
function Caps.OnTradeSkillPulse()
    HydrateStickyFromPersist()
    local liveCult = ReadLevel(Caps.CultivationId())
    local liveApo = ReadLevel(Caps.ApothecaryId())
    if Caps._pendingLoadRefresh == true then
        if liveCult > 0 or liveApo > 0 then
            Caps._lastCult = liveCult
            Caps._lastApo = liveApo
            Caps._pendingLoadRefresh = false
            Caps._loadEmptyPulses = 0
            PersistSticky()
        else
            Caps._loadEmptyPulses = (tonumber(Caps._loadEmptyPulses) or 0) + 1
            -- Never clear sticky on empties: scenario/combat fires many empty
            -- TRADE_SKILL_UPDATED with no follow-up until the next skill-up.
            -- Untrained chars keep sticky 0; char switch gets a non-empty pulse.
            if Caps._loadEmptyPulses >= 5
                and (tonumber(Caps._lastCult) or 0) <= 0
                and (tonumber(Caps._lastApo) or 0) <= 0
            then
                Caps._pendingLoadRefresh = false
                Caps._loadEmptyPulses = 0
            elseif Caps._loadEmptyPulses >= 12 then
                -- Enough empties: stop waiting; keep sticky as-is.
                Caps._pendingLoadRefresh = false
                Caps._loadEmptyPulses = 0
                if StockPiler3.Debug and StockPiler3.Debug.LogOp then
                    StockPiler3.Debug.LogOp("caps", string.format(
                        "load-empty-keep sticky cult=%d apo=%d",
                        tonumber(Caps._lastCult) or 0,
                        tonumber(Caps._lastApo) or 0
                    ))
                end
            end
        end
    else
        local changed = false
        if liveCult > 0 and liveCult ~= (tonumber(Caps._lastCult) or 0) then
            Caps._lastCult = liveCult
            changed = true
        elseif liveCult > 0 then
            Caps._lastCult = liveCult
        end
        if liveApo > 0 and liveApo ~= (tonumber(Caps._lastApo) or 0) then
            Caps._lastApo = liveApo
            changed = true
        elseif liveApo > 0 then
            Caps._lastApo = liveApo
        end
        if liveCult > 0 or liveApo > 0 then
            PersistSticky()
        end
        if changed and StockPiler3.Debug and StockPiler3.Debug.LogOp then
            -- quiet; Bridge logs hash changes
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
    -- Keep _lastCult/_lastApo across combat/zone unless a non-empty
    -- OnTradeSkillPulse replaces them. Avoids SkillUp rows vanishing when the
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
