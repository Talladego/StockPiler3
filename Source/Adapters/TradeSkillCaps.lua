----------------------------------------------------------------
-- StockPiler3 Adapters/TradeSkillCaps - live cult/apo skill levels
-- Prefer GetTradeSkillLevel / TradeSkillLevels (stock Abilities + Cultivation).
-- Player.tradeSkills often empties mid-session; sticky holds through unknown
-- empties. Explicit 0 from TradeSkillLevels is a real unlearn and clears sticky.
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

--- Returns level, explicit.
--- explicit=true: stock SoT reported a number (including 0 = unlearned).
--- explicit=false: sources missing/empty — keep sticky (combat/scenario blip).
local function ReadLevel(skillId)
    skillId = tonumber(skillId) or 0
    if skillId <= 0 then
        return 0, false
    end
    -- Stock CultivationWindow / AbilitiesWindow / tooltips use these first.
    if type(GetTradeSkillLevel) == "function" then
        local ok, level = pcall(GetTradeSkillLevel, skillId)
        if ok == true and level ~= nil then
            return tonumber(level) or 0, true
        end
    end
    if GameData and type(GameData.TradeSkillLevels) == "table" then
        local level = GameData.TradeSkillLevels[skillId]
        if level ~= nil then
            return tonumber(level) or 0, true
        end
    end
    -- Player.tradeSkills is flaky (empty mid-combat). Only trust a positive
    -- reading; treat missing/0 here as unknown so sticky can cover blips.
    if GameData and GameData.Player and type(GameData.Player.tradeSkills) == "table" then
        local row = GameData.Player.tradeSkills[skillId]
        if type(row) == "table" then
            local level = tonumber(row.level) or 0
            if level > 0 then
                return level, true
            end
            return 0, false
        end
        if row ~= nil then
            local level = tonumber(row) or 0
            if level > 0 then
                return level, true
            end
            return 0, false
        end
    end
    if GameData and type(GameData.TradeSkillData) == "table" then
        local row = GameData.TradeSkillData[skillId]
        if type(row) == "table" then
            local level = tonumber(row.level) or tonumber(row.SkillLevel) or 0
            if level > 0 then
                return level, true
            end
            if row.level ~= nil or row.SkillLevel ~= nil then
                return 0, true
            end
            return 0, false
        end
        if row ~= nil then
            local level = tonumber(row) or 0
            return level, true
        end
    end
    return 0, false
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
    local row = CharBucket(true)
    if type(row) ~= "table" then
        return
    end
    -- Always write both so unlearn clears a previous persisted level.
    row.lastCultSkill = cult
    row.lastApoSkill = apo
end

--- live + explicit from ReadLevel. Trust explicit 0 (unlearn); keep sticky on unknown.
local function StickLevel(live, explicit, last)
    live = tonumber(live) or 0
    last = tonumber(last) or 0
    if explicit == true then
        return live, live
    end
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
    local level = ReadLevel(skillId)
    return level
end

--- Live engine read (ignores sticky cache). For load/char-switch reconciliation.
function Caps.ReadCultSkillLive()
    local level = ReadLevel(Caps.CultivationId())
    return level
end

function Caps.ReadApoSkillLive()
    local level = ReadLevel(Caps.ApothecaryId())
    return level
end

function Caps.GetCultSkill()
    HydrateStickyFromPersist()
    local live, explicit = ReadLevel(Caps.CultivationId())
    local out
    out, Caps._lastCult = StickLevel(live, explicit, Caps._lastCult)
    return out
end

function Caps.GetApoSkill()
    HydrateStickyFromPersist()
    local live, explicit = ReadLevel(Caps.ApothecaryId())
    local out
    out, Caps._lastApo = StickLevel(live, explicit, Caps._lastApo)
    return out
end

--- Call from LOADING_END so a later non-empty TRADE_SKILL_UPDATED can refresh.
function Caps.BeginLoadSkillRefresh()
    Caps._pendingLoadRefresh = true
    Caps._loadEmptyPulses = 0
end

--- Apply a TRADE_SKILL_UPDATED pulse.
--- Explicit TradeSkillLevels / GetTradeSkillLevel (including 0) update sticky.
--- Unknown empties never wipe sticky (combat / scenario blips).
function Caps.OnTradeSkillPulse()
    HydrateStickyFromPersist()
    local liveCult, cultExplicit = ReadLevel(Caps.CultivationId())
    local liveApo, apoExplicit = ReadLevel(Caps.ApothecaryId())
    local prevCult = tonumber(Caps._lastCult) or 0
    local prevApo = tonumber(Caps._lastApo) or 0
    local changed = false

    if Caps._pendingLoadRefresh == true then
        if cultExplicit == true or apoExplicit == true
            or liveCult > 0 or liveApo > 0
        then
            local newCult = prevCult
            local newApo = prevApo
            if cultExplicit == true then
                newCult = liveCult
            elseif liveCult > 0 then
                newCult = liveCult
            end
            if apoExplicit == true then
                newApo = liveApo
            elseif liveApo > 0 then
                newApo = liveApo
            end
            Caps._lastCult = newCult
            Caps._lastApo = newApo
            Caps._pendingLoadRefresh = false
            Caps._loadEmptyPulses = 0
            PersistSticky()
            changed = newCult ~= prevCult or newApo ~= prevApo
        else
            Caps._loadEmptyPulses = (tonumber(Caps._loadEmptyPulses) or 0) + 1
            -- Never clear sticky on empties: scenario/combat fires many empty
            -- TRADE_SKILL_UPDATED with no follow-up until the next skill-up.
            if Caps._loadEmptyPulses >= 5
                and prevCult <= 0
                and prevApo <= 0
            then
                Caps._pendingLoadRefresh = false
                Caps._loadEmptyPulses = 0
            elseif Caps._loadEmptyPulses >= 12 then
                Caps._pendingLoadRefresh = false
                Caps._loadEmptyPulses = 0
                if StockPiler3.Debug and StockPiler3.Debug.LogOp then
                    StockPiler3.Debug.LogOp("caps", string.format(
                        "load-empty-keep sticky cult=%d apo=%d",
                        prevCult, prevApo
                    ))
                end
            end
        end
    else
        if cultExplicit == true then
            if liveCult ~= prevCult then
                Caps._lastCult = liveCult
                changed = true
            else
                Caps._lastCult = liveCult
            end
        elseif liveCult > 0 then
            if liveCult ~= prevCult then
                Caps._lastCult = liveCult
                changed = true
            else
                Caps._lastCult = liveCult
            end
        end
        if apoExplicit == true then
            if liveApo ~= prevApo then
                Caps._lastApo = liveApo
                changed = true
            else
                Caps._lastApo = liveApo
            end
        elseif liveApo > 0 then
            if liveApo ~= prevApo then
                Caps._lastApo = liveApo
                changed = true
            else
                Caps._lastApo = liveApo
            end
        end
        if cultExplicit == true or apoExplicit == true
            or liveCult > 0 or liveApo > 0
        then
            PersistSticky()
        end
        if changed and StockPiler3.Debug and StockPiler3.Debug.LogOp then
            StockPiler3.Debug.LogOp("caps", string.format(
                "sticky-update cult=%d->%d apo=%d->%d explicit=%s/%s",
                prevCult, tonumber(Caps._lastCult) or 0,
                prevApo, tonumber(Caps._lastApo) or 0,
                tostring(cultExplicit == true), tostring(apoExplicit == true)
            ))
        end
    end
    if (tonumber(Caps._lastCult) or 0) > 0 or (tonumber(Caps._lastApo) or 0) > 0 then
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
    -- Keep _lastCult/_lastApo across combat/zone unless an explicit
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
