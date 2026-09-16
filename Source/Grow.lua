----------------------------------------------------------------
-- StockPiler3 Grow -- AutoGrow plant pick + IssuePlantOne + harvest
-- Policy and executor live here (no separate Executors folder).
-- Callees above callers (RoR Lua local-order).
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Grow = StockPiler3.Grow or {}
local Grow = StockPiler3.Grow

Grow.PENDING_TTL_SEC = 10
Grow.PENDING_EMPTY_GRACE_SEC = 5.0
Grow.UNCONFIRMED_PLANT_COOLDOWN_SEC = 6.0
Grow.UNCONFIRMED_GARDEN_QUIET_SEC = 8.0
Grow.POST_HARVEST_PLANT_DELAY_SEC = 0.75
Grow.HARVEST_FORCE_DEBOUNCE_SEC = 1.5
Grow.HARVEST_OP_LOCK_SEC = 1.0

Grow._pendingPlant = Grow._pendingPlant or {}
Grow._pendingPlantAt = Grow._pendingPlantAt or {}
Grow._pendingSeedUid = Grow._pendingSeedUid or {}
-- True while _seedCommitted still counts this plot's in-flight plant.
Grow._pendingSeedHeld = Grow._pendingSeedHeld or {}
Grow._seedCommitted = Grow._seedCommitted or {}
Grow._wavePlantedBySeed = Grow._wavePlantedBySeed or {}
Grow._plantFailCooldownUntil = Grow._plantFailCooldownUntil or {}
Grow._pendingAdditive = Grow._pendingAdditive or {}
Grow._pendingAdditiveAt = Grow._pendingAdditiveAt or {}
Grow._fillCursor = Grow._fillCursor or 1
Grow._additiveCursor = Grow._additiveCursor or 1
Grow._lastPlantedSeedUid = 0
Grow._fillBlocked = false
Grow._plantWaitTicks = 0
Grow._plantQueueDirty = true
Grow._cachedPlantJob = nil
Grow._plantQuietUntil = 0
Grow._lastHarvestForceAt = 0
Grow._harvestOpLockUntil = 0
Grow._lastPreparedHarvestPlot = 0
Grow._skillSkipByUid = Grow._skillSkipByUid or {}
Grow._skillSkipSnapGen = -1
Grow._lastSkipKey = nil
Grow._lastPickLogKey = nil
Grow._commitForceCleared = false
Grow._chatHarvestNeedsForce = false
Grow._additiveDirty = false

local ROLE_PICK_ORDER = {
    main = 1,
    stabilizer = 2,
    goldweed = 2,
    extender = 3,
    multiplier = 4,
    stimulant = 4,
    container = 5,
    ingredient = 6,
}

----------------------------------------------------------------
-- Helpers (callees first)
----------------------------------------------------------------

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function LogGrow(msg)
    if StockPiler3.Debug and StockPiler3.Debug.LogOp then
        StockPiler3.Debug.LogOp("grow", msg)
    end
end

local function LogOnce(key, msg)
    key = tostring(key or "")
    if Grow._lastSkipKey == key then
        return
    end
    Grow._lastSkipKey = key
    LogGrow(msg)
end

local function StageEmpty()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.EMPTY or 0
    end
    return 0
end

local function StageGrown()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.GROWN
            or GameData.CultivationStage.HARVESTABLE
            or 4
    end
    return 4
end

local function StageHarvesting()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.HARVESTING or 5
    end
    return 5
end

local function NormalizeStage(stage)
    return tonumber(stage) or 0
end

local function SpecRole(spec)
    if type(spec) ~= "table" then
        return "ingredient"
    end
    local role = tostring(spec.role or spec.materialRole or "")
    if role == "" then
        return "ingredient"
    end
    return role
end

local function RoleRank(role)
    return ROLE_PICK_ORDER[tostring(role or "")] or 99
end

local function IsPlotLocked(row, plotNum)
    if type(row) == "table" and row.locked == true then
        return true
    end
    local CA = StockPiler3.CultivatorAdapter
    if CA and CA.IsPlotLocked then
        return CA.IsPlotLocked(plotNum, CA.GetCultSkill and CA.GetCultSkill()) == true
    end
    return false
end

local function IsPlotEmptyRow(row)
    if type(row) ~= "table" then
        return false
    end
    if row.locked == true then
        return false
    end
    return NormalizeStage(row.stage) == StageEmpty()
end

local function IsPlotGrownStage(stage)
    local s = NormalizeStage(stage)
    local grown = StageGrown()
    if grown ~= nil and s == grown then
        return true
    end
    -- Some clients use HARVESTABLE alias.
    if GameData and GameData.CultivationStage and GameData.CultivationStage.HARVESTABLE then
        return s == GameData.CultivationStage.HARVESTABLE
    end
    return false
end

local function CanUseSeedUid(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local Inv = StockPiler3.Inventory
    local snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    if Grow._skillSkipSnapGen ~= snapGen then
        Grow._skillSkipByUid = {}
        Grow._skillSkipSnapGen = snapGen
    end
    if Grow._skillSkipByUid[seedUid] == true then
        return false
    end
    local sample = Inv and Inv.GetSample and Inv.GetSample(seedUid)
    if type(sample) == "table" and Inv and Inv.CanUseCraftingItem then
        if Inv.CanUseCraftingItem(sample) ~= true then
            Grow._skillSkipByUid[seedUid] = true
            return false
        end
    end
    return true
end

local function CountInGroundSeeds(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    local n = 0
    local plots = StockPiler3.Garden and StockPiler3.Garden.GetPlots and StockPiler3.Garden.GetPlots()
    if type(plots) ~= "table" then
        return 0
    end
    for _, row in pairs(plots) do
        if type(row) == "table" and (tonumber(row.seedUid) or 0) == seedUid then
            if not IsPlotEmptyRow(row) then
                n = n + 1
            end
        end
    end
    return n
end

--- Opaque Eternal/Exceptional credit: full unlocked plot wave while owned.
local function OpaqueSeedCredit(seedUid, bagCount)
    seedUid = tonumber(seedUid) or 0
    bagCount = tonumber(bagCount) or 0
    if seedUid <= 0 or bagCount <= 0 then
        return bagCount
    end
    local SM = StockPiler3.SeedMap
    if SM and SM.EffectiveSeedCredit then
        return tonumber(SM.EffectiveSeedCredit(seedUid, bagCount)) or bagCount
    end
    local Inv = StockPiler3.Inventory
    local sample = Inv and Inv.GetSample and Inv.GetSample(seedUid)
    local name = ""
    if type(sample) == "table" and sample.name ~= nil then
        if type(sample.name) == "wstring" and type(WStringToString) == "function" then
            local ok, text = pcall(WStringToString, sample.name)
            if ok then
                name = tostring(text or "")
            end
        else
            name = tostring(sample.name)
        end
    end
    local lower = string.lower(name)
    if string.find(lower, "eternal", 1, true) or string.find(lower, "exceptional", 1, true) then
        local plots = 1
        local CA = StockPiler3.CultivatorAdapter
        if CA and CA.NumPlots then
            plots = math.max(1, tonumber(CA.NumPlots()) or 1)
        end
        if bagCount < plots then
            return plots
        end
    end
    return bagCount
end

local function LiveSeedBag(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    local Inv = StockPiler3.Inventory
    if Inv and Inv.CountByUid then
        return tonumber(Inv.CountByUid(seedUid)) or 0
    end
    return 0
end

local function BufferCredit(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    local Refine = StockPiler3.Refine
    if Refine and Refine.GetSeedBudget then
        local b = Refine.GetSeedBudget(seedUid)
        if type(b) == "table" and b.credit ~= nil then
            return tonumber(b.credit) or 0
        end
    end
    local bag = OpaqueSeedCredit(seedUid, LiveSeedBag(seedUid))
    local ground = CountInGroundSeeds(seedUid)
    local outstanding = 0
    local RP = StockPiler3.RefinePipeline
    if RP and RP.GetOutstanding then
        outstanding = tonumber(RP.GetOutstanding(seedUid)) or 0
    end
    return bag + ground + outstanding
end

local function PreferJob(job, best, bestScore, bestShare, bestCrafts, bestPlots, bestRole, useFocus)
    if type(job) ~= "table" then
        return best, bestScore, bestShare, bestCrafts, bestPlots, bestRole
    end
    local crafts = tonumber(job.craftsShort) or 0
    local role = RoleRank(job.role)
    local plots = tonumber(job.plotCount) or CountInGroundSeeds(job.seedUid)
    job.plotCount = plots
    job.roleRank = role
    local better = false
    if useFocus then
        local score = tonumber(job.bottleneckScore) or 0
        local share = tonumber(job.focusShare) or 999
        if best == nil then
            better = true
        elseif score > bestScore then
            better = true
        elseif score == bestScore then
            if share < bestShare then
                better = true
            elseif share == bestShare then
                if crafts > bestCrafts then
                    better = true
                elseif crafts == bestCrafts then
                    if role < bestRole then
                        better = true
                    elseif role == bestRole
                        and (tonumber(job.seedUid) or 0) ~= (tonumber(Grow._lastPlantedSeedUid) or 0)
                        and (tonumber(best.seedUid) or 0) == (tonumber(Grow._lastPlantedSeedUid) or 0)
                    then
                        better = true
                    end
                end
            end
        end
        if better then
            return job, score, share, crafts, plots, role
        end
        return best, bestScore, bestShare, bestCrafts, bestPlots, bestRole
    end
    if best == nil then
        better = true
    elseif crafts > bestCrafts then
        better = true
    elseif crafts == bestCrafts then
        if plots < bestPlots then
            better = true
        elseif plots == bestPlots and role < bestRole then
            better = true
        elseif plots == bestPlots and role == bestRole
            and (tonumber(job.seedUid) or 0) ~= (tonumber(Grow._lastPlantedSeedUid) or 0)
            and (tonumber(best.seedUid) or 0) == (tonumber(Grow._lastPlantedSeedUid) or 0)
        then
            better = true
        end
    end
    if better then
        return job, bestScore, bestShare, crafts, plots, role
    end
    return best, bestScore, bestShare, bestCrafts, bestPlots, bestRole
end

local function JobFromDemandRow(row, SM)
    if type(row) ~= "table" or type(SM) ~= "table" then
        return nil
    end
    local deficit = tonumber(row.deficit) or 0
    local craftsShort = tonumber(row.craftsShort)
    if craftsShort == nil then
        craftsShort = deficit
    end
    local spec = row.spec
    if deficit <= 0 or craftsShort <= 0 or type(spec) ~= "table" then
        return nil
    end
    if SM.IsGrowableSpec and SM.IsGrowableSpec(spec) ~= true then
        return nil
    end
    local seed = SM.ResolveSeedForSpec and SM.ResolveSeedForSpec(spec)
    if type(seed) ~= "table" then
        return nil
    end
    local seedUid = tonumber(seed.uniqueID) or 0
    if seedUid <= 0 then
        return nil
    end
    if not CanUseSeedUid(seedUid) then
        return nil
    end
    local bag = OpaqueSeedCredit(seedUid, LiveSeedBag(seedUid))
    if SM.CountSeedsInBagsForSpec then
        local n = tonumber(SM.CountSeedsInBagsForSpec(spec)) or 0
        if n > bag then
            bag = OpaqueSeedCredit(seedUid, n)
        end
    end
    local committed = tonumber(Grow._seedCommitted[seedUid]) or 0
    local avail = bag - committed
    if avail < 1 then
        return nil
    end
    local plantable = math.min(avail, craftsShort)
    if plantable < 1 then
        return nil
    end
    return {
        spec = spec,
        specKey = row.specKey,
        seed = seed,
        seedUid = seedUid,
        plantUid = tonumber(row.plantUid) or tonumber(spec.plantUid) or 0,
        seedHave = bag,
        plantable = plantable,
        deficit = deficit,
        craftsShort = craftsShort,
        role = SpecRole(spec),
        plantReason = "potion_stock",
        plotCount = CountInGroundSeeds(seedUid),
    }
end

local function PotionStockNeedsRefineFirst(demand, SM)
    if type(demand) ~= "table" or type(SM) ~= "table" then
        return false
    end
    local Refine = StockPiler3.Refine
    for _, row in pairs(demand) do
        if type(row) == "table" and (tonumber(row.deficit) or 0) > 0 and type(row.spec) == "table" then
            if SM.IsGrowableSpec and SM.IsGrowableSpec(row.spec) == true then
                local seed = SM.ResolveSeedForSpec and SM.ResolveSeedForSpec(row.spec)
                local seedUid = type(seed) == "table" and (tonumber(seed.uniqueID) or 0) or 0
                local have = seedUid > 0 and LiveSeedBag(seedUid) or 0
                local committed = tonumber(Grow._seedCommitted[seedUid]) or 0
                if (have - committed) <= 0 then
                    local plantUid = tonumber(row.plantUid) or 0
                    local refinable = 0
                    if Refine and Refine.CountRefinablePlants then
                        refinable = tonumber(Refine.CountRefinablePlants(plantUid, row.spec)) or 0
                    end
                    if refinable > 0 then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function PickBufferGrowCandidate(lines, SM, focusKeys, demand, focusGap)
    if type(lines) ~= "table" then
        return nil
    end
    focusGap = tonumber(focusGap) or 0
    -- While focus still needs bottles, only buffer seeds for short demand mats
    -- (never covered main/extender from the same recipe).
    local restrictToShorts = focusGap > 0
    local shortDemandKeys = nil
    if restrictToShorts and type(demand) == "table" then
        shortDemandKeys = {}
        for specKey, row in pairs(demand) do
            if type(row) == "table" and (tonumber(row.craftsShort) or 0) > 0 then
                shortDemandKeys[tostring(specKey)] = true
                if row.specKey then
                    shortDemandKeys[tostring(row.specKey)] = true
                end
            end
        end
    end
    local function LineAllowedForFocus(line)
        if not restrictToShorts then
            return true
        end
        if type(shortDemandKeys) ~= "table" then
            return false
        end
        local sk = tostring(line.specKey or "")
        if sk ~= "" and shortDemandKeys[sk] == true then
            return true
        end
        if type(line.spec) == "table" then
            local MS = StockPiler3.MaterialSpec
            local pk = ""
            if MS and MS.ProductKey then
                pk = tostring(MS.ProductKey(line.spec) or "")
            elseif MS and MS.Key then
                pk = tostring(MS.Key(line.spec) or "")
            end
            if pk ~= "" and shortDemandKeys[pk] == true then
                return true
            end
        end
        return false
    end
    local Watch = StockPiler3.Watch
    local buffer = Watch and Watch.GetSeedBufferMin and Watch.GetSeedBufferMin() or 5
    local Refine = StockPiler3.Refine
    local best, bestWant = nil, -1
    for i = 1, #lines do
        local line = lines[i]
        local seedUid = tonumber(line.seedUid) or 0
        if seedUid > 0 and CanUseSeedUid(seedUid) and LineAllowedForFocus(line) then
            local credit = BufferCredit(seedUid)
            local committed = tonumber(Grow._seedCommitted[seedUid]) or 0
            local bag = OpaqueSeedCredit(seedUid, LiveSeedBag(seedUid))
            local avail = bag - committed
            if avail > 0 and credit < buffer then
                local refinable = 0
                if Refine and Refine.CountRefinablePlants then
                    refinable = tonumber(Refine.CountRefinablePlants(line.plantUid, line.spec)) or 0
                end
                -- Must not buffer-grow while refinable plants remain.
                if refinable <= 0 then
                    local want = buffer - credit
                    if want > bestWant then
                        bestWant = want
                        best = {
                            spec = line.spec,
                            specKey = line.specKey,
                            seed = line.seed or { uniqueID = seedUid },
                            seedUid = seedUid,
                            plantUid = tonumber(line.plantUid) or 0,
                            seedHave = bag,
                            plantable = math.min(avail, want),
                            deficit = want,
                            craftsShort = want,
                            role = SpecRole(line.spec),
                            plantReason = "seed_buffer",
                        }
                    end
                end
            end
        end
    end
    return best
end

local function PickSurplusCandidate(lines)
    local Refine = StockPiler3.Refine
    -- SHORT surplus block when buffer SHORT or buffer refine pending.
    if Refine then
        if Refine.HasAnyBufferShort and Refine.HasAnyBufferShort() == true then
            return nil
        end
        if Refine.HasPendingBufferRefine and Refine.HasPendingBufferRefine() == true then
            return nil
        end
    end
    local Watch = StockPiler3.Watch
    local buffer = Watch and Watch.GetSeedBufferMin and Watch.GetSeedBufferMin() or 5
    local best, bestSurplus = nil, -1
    if type(lines) ~= "table" then
        return nil
    end
    for i = 1, #lines do
        local line = lines[i]
        local seedUid = tonumber(line.seedUid) or 0
        if seedUid > 0 and CanUseSeedUid(seedUid) then
            local live = OpaqueSeedCredit(seedUid, LiveSeedBag(seedUid))
            local committed = tonumber(Grow._seedCommitted[seedUid]) or 0
            if Refine and Refine.GetSeedBudget then
                local b = Refine.GetSeedBudget(seedUid)
                if type(b) == "table" then
                    if (tonumber(b.headroom) or 0) > 0 then
                        live = -1
                    else
                        live = tonumber(b.live) or live
                    end
                end
            end
            if live >= 0 then
                local surplus = live - buffer - committed
                if surplus > bestSurplus and surplus > 0 then
                    bestSurplus = surplus
                    best = {
                        spec = line.spec,
                        specKey = line.specKey,
                        seed = line.seed or { uniqueID = seedUid },
                        seedUid = seedUid,
                        plantUid = tonumber(line.plantUid) or 0,
                        seedHave = live,
                        plantable = surplus,
                        deficit = surplus,
                        craftsShort = surplus,
                        role = SpecRole(line.spec),
                        plantReason = "surplus",
                    }
                end
            end
        end
    end
    return best
end

local function ClearPendingPlot(plotNum, opts)
    plotNum = tonumber(plotNum) or 0
    opts = type(opts) == "table" and opts or {}
    if plotNum <= 0 then
        return
    end
    if opts.rollbackCommit == true and Grow._pendingSeedHeld[plotNum] == true then
        local seedUid = tonumber(Grow._pendingSeedUid[plotNum]) or 0
        if seedUid > 0 then
            local n = (tonumber(Grow._seedCommitted[seedUid]) or 0) - 1
            Grow._seedCommitted[seedUid] = n > 0 and n or nil
            local w = (tonumber(Grow._wavePlantedBySeed[seedUid]) or 0) - 1
            Grow._wavePlantedBySeed[seedUid] = w > 0 and w or nil
        end
    end
    Grow._pendingSeedHeld[plotNum] = nil
    Grow._pendingPlant[plotNum] = nil
    Grow._pendingPlantAt[plotNum] = nil
    Grow._pendingSeedUid[plotNum] = nil
end

--- After PlantSeed succeeds: bag is truth — drop seed reservation but keep plot reserved
--- until soil confirms so FindNextEmptyPlot cannot double-plant.
local function ReleaseSeedReservation(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or Grow._pendingSeedHeld[plotNum] ~= true then
        return
    end
    local seedUid = tonumber(Grow._pendingSeedUid[plotNum]) or 0
    if seedUid > 0 then
        local n = (tonumber(Grow._seedCommitted[seedUid]) or 0) - 1
        Grow._seedCommitted[seedUid] = n > 0 and n or nil
        local w = (tonumber(Grow._wavePlantedBySeed[seedUid]) or 0) - 1
        Grow._wavePlantedBySeed[seedUid] = w > 0 and w or nil
    end
    Grow._pendingSeedHeld[plotNum] = false
end

local function ReleaseCommit(plotNum, ok)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return
    end
    -- ok==true: soil confirmed (seed commit already released after PlantSeed).
    -- ok==false: plant failed or pending expired — roll back commit only if still held.
    ClearPendingPlot(plotNum, { rollbackCommit = (ok ~= true) })
end

--- Drop stale seed reservations that exceed live bag (inventory caught up).
local function ClampSeedCommitsToBag()
    local Inv = StockPiler3.Inventory
    if not (Inv and Inv.CountByUid) then
        return
    end
    for seedUid, committed in pairs(Grow._seedCommitted) do
        seedUid = tonumber(seedUid) or 0
        committed = tonumber(committed) or 0
        if seedUid > 0 and committed > 0 then
            local bag = tonumber(Inv.CountByUid(seedUid)) or 0
            if committed > bag then
                if bag <= 0 then
                    Grow._seedCommitted[seedUid] = nil
                else
                    Grow._seedCommitted[seedUid] = bag
                end
            end
        end
    end
end

local function GetReadyHarvestPlots()
    local ready = {}
    local plots = StockPiler3.Garden and StockPiler3.Garden.GetPlots and StockPiler3.Garden.GetPlots()
    if type(plots) ~= "table" then
        return ready
    end
    for plotNum, row in pairs(plots) do
        plotNum = tonumber(plotNum) or 0
        if plotNum > 0 and type(row) == "table" and not IsPlotLocked(row, plotNum) then
            if IsPlotGrownStage(row.stage) then
                ready[#ready + 1] = plotNum
            end
        end
    end
    table.sort(ready)
    return ready
end

local function HasPlotGrowing()
    local plots = StockPiler3.Garden and StockPiler3.Garden.GetPlots and StockPiler3.Garden.GetPlots()
    if type(plots) ~= "table" then
        return false
    end
    local empty = StageEmpty()
    local grown = StageGrown()
    local harvesting = StageHarvesting()
    for plotNum, row in pairs(plots) do
        if type(row) == "table" and not IsPlotLocked(row, tonumber(plotNum) or 0) then
            local s = NormalizeStage(row.stage)
            if s ~= empty and s ~= grown and s ~= harvesting then
                return true
            end
        end
    end
    return false
end

local function AllPlantedPlotsHarvestReady()
    local plots = StockPiler3.Garden and StockPiler3.Garden.GetPlots and StockPiler3.Garden.GetPlots()
    if type(plots) ~= "table" then
        return false
    end
    local anyPlanted = false
    for plotNum, row in pairs(plots) do
        if type(row) == "table" and not IsPlotLocked(row, tonumber(plotNum) or 0) then
            if not IsPlotEmptyRow(row) then
                anyPlanted = true
                if not IsPlotGrownStage(row.stage)
                    and NormalizeStage(row.stage) ~= StageHarvesting()
                then
                    return false
                end
            end
        end
    end
    return anyPlanted
end

----------------------------------------------------------------
-- Public: buffer / fill / plots
----------------------------------------------------------------

function Grow.StageEmpty()
    return StageEmpty()
end

function Grow.IsEnabled()
    local Watch = StockPiler3.Watch
    if not Watch or not Watch.IsAutoGrowEnabled or Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    return true
end

function Grow.HasEmptyPlot()
    local plots = StockPiler3.Garden and StockPiler3.Garden.GetPlots and StockPiler3.Garden.GetPlots()
    if type(plots) ~= "table" then
        return false
    end
    for plotNum, row in pairs(plots) do
        if not IsPlotLocked(row, tonumber(plotNum) or 0) and IsPlotEmptyRow(row) then
            if (tonumber(Grow._pendingPlant[plotNum]) or 0) <= 0 then
                return true
            end
        end
    end
    return false
end

function Grow.FindNextEmptyPlot()
    local CA = StockPiler3.CultivatorAdapter
    local maxPlots = CA and CA.NumPlots and CA.NumPlots() or 4
    local start = tonumber(Grow._fillCursor) or 1
    if start < 1 or start > maxPlots then
        start = 1
    end
    for i = 0, maxPlots - 1 do
        local plotNum = ((start - 1 + i) % maxPlots) + 1
        local row = StockPiler3.Garden and StockPiler3.Garden.GetPlot and StockPiler3.Garden.GetPlot(plotNum)
        if not IsPlotLocked(row, plotNum) and IsPlotEmptyRow(row) then
            if (tonumber(Grow._pendingPlant[plotNum]) or 0) <= 0 then
                Grow._fillCursor = plotNum + 1
                return plotNum
            end
        end
    end
    return 0
end

function Grow.CountInGroundSeeds(seedUid)
    return CountInGroundSeeds(seedUid)
end

function Grow.HasPendingBufferRefine()
    local Refine = StockPiler3.Refine
    if Refine and Refine.HasPendingBufferRefine then
        return Refine.HasPendingBufferRefine() == true
    end
    return false
end

function Grow.HasAnyBufferShort()
    local Refine = StockPiler3.Refine
    if Refine and Refine.HasAnyBufferShort then
        return Refine.HasAnyBufferShort() == true
    end
    return false
end

function Grow.IsSeedBufferSatisfied()
    local Refine = StockPiler3.Refine
    if Refine and Refine.IsSeedBufferSatisfied then
        return Refine.IsSeedBufferSatisfied() == true
    end
    return true
end

function Grow.SetFillBlocked(blocked, waitTicks)
    if blocked == true then
        Grow._fillBlocked = true
        waitTicks = tonumber(waitTicks) or 0
        local cur = tonumber(Grow._plantWaitTicks) or 0
        if waitTicks > cur then
            Grow._plantWaitTicks = waitTicks
        end
        -- Mirror Orch wait without calling Orch.SetFillBlocked (that re-enters Grow).
        local Orch = StockPiler3.Orchestrator
        if Orch then
            Orch._fillBlocked = true
            local ow = tonumber(Orch._fillBlockedWait) or 0
            local gw = tonumber(Grow._plantWaitTicks) or 0
            if gw > ow then
                Orch._fillBlockedWait = gw
            end
        end
    else
        Grow.ClearFillBlocked()
    end
end

function Grow.ClearFillBlocked()
    Grow._fillBlocked = false
    Grow._plantWaitTicks = 0
end

function Grow.IsFillBlocked()
    return Grow._fillBlocked == true
end

function Grow.DecayPlantWaitTicks()
    local wait = tonumber(Grow._plantWaitTicks) or 0
    if wait > 0 then
        Grow._plantWaitTicks = wait - 1
        if Grow._plantWaitTicks <= 0 then
            Grow._fillBlocked = false
            Grow._plantWaitTicks = 0
        end
    end
end

function Grow.InvalidatePlantQueue(opts)
    opts = type(opts) == "table" and opts or {}
    Grow._plantQueueDirty = true
    Grow._cachedPlantJob = nil
    if opts.force == true then
        Grow._seedCommitted = {}
        Grow._wavePlantedBySeed = {}
        if opts.keepCommitForceCleared ~= true then
            Grow._commitForceCleared = false
        end
    end
end

function Grow.MarkPlantJobDirty(reason)
    Grow.InvalidatePlantQueue({ reason = reason })
end

----------------------------------------------------------------
-- Plant pick — watch deficit → craftable-lift bottlenecks → spare plots
----------------------------------------------------------------

--- AutoGrow watches with potion deficit (target - have), largest first.
local function CollectPlantWatchOrder(RS)
    local list = {}
    local Watch = StockPiler3.Watch
    local PS = StockPiler3.PlanSnapshot
    local plan = PS and PS.Get and PS.Get() or nil
    local planRows = type(plan) == "table" and plan.rows or nil
    local BottleGap = StockPiler3.Planner and StockPiler3.Planner.BottleGap

    local function push(potionKey, name, deficit, recipe, have, target, craftable, bottleGap)
        potionKey = tostring(potionKey or "")
        deficit = tonumber(deficit) or 0
        if potionKey == "" or deficit <= 0 or type(recipe) ~= "table" then
            return
        end
        if RS.ShouldAutoGrowPotion and RS.ShouldAutoGrowPotion(potionKey, nil) ~= true then
            return
        end
        have = tonumber(have) or 0
        target = tonumber(target) or 0
        craftable = tonumber(craftable) or 0
        local gap = tonumber(bottleGap)
        if gap == nil and type(BottleGap) == "function" then
            gap = BottleGap(target, have, craftable)
        end
        gap = tonumber(gap) or math.max(0, target - have - craftable)
        list[#list + 1] = {
            potionKey = potionKey,
            name = name,
            deficit = deficit,
            recipe = recipe,
            have = have,
            target = target,
            craftable = craftable,
            bottleGap = gap,
        }
    end

    if type(planRows) == "table" and #planRows > 0 then
        for i = 1, #planRows do
            local row = planRows[i]
            if type(row) == "table" then
                local key = tostring(row.potionKey or row.potionRecipeKey or row.id or "")
                local target = tonumber(row.potionMin) or tonumber(row.target) or 0
                local have = tonumber(row.potionHave) or 0
                local deficit = tonumber(row.potionDeficit)
                if deficit == nil then
                    deficit = math.max(0, target - have)
                end
                local recipe = row.recipe
                if type(recipe) ~= "table" and RS.RecipeSpecForPotion then
                    recipe = RS.RecipeSpecForPotion(key)
                end
                push(
                    key,
                    row.name,
                    deficit,
                    recipe,
                    have,
                    target,
                    row.craftable,
                    row.bottleGap
                )
            end
        end
    else
        local watches = Watch and Watch.GetWatches and Watch.GetWatches() or {}
        if type(watches) == "table" then
            for watchKey, watch in pairs(watches) do
                if RS.ShouldAutoGrowPotion and RS.ShouldAutoGrowPotion(watchKey, watch) == true then
                    local resolved = RS.ResolveWatchPotion and RS.ResolveWatchPotion(watchKey)
                    local potion = resolved and resolved.potion
                    local recipe = RS.RecipeSpecForPotion and RS.RecipeSpecForPotion(watchKey)
                    if type(potion) == "table" and type(recipe) == "table" then
                        local target = tonumber(watch.targetStock) or 0
                        local have = 0
                        if RS.PotionHaveCombined then
                            have = tonumber(RS.PotionHaveCombined(potion)) or 0
                        end
                        local craftable = 0
                        if RS.CountCraftsPossible then
                            local n = tonumber(RS.CountCraftsPossible(recipe)) or 0
                            local yield = tonumber(recipe.recipeYield) or 5
                            craftable = math.max(0, math.floor(n * yield + 0.5))
                        end
                        push(
                            watchKey,
                            potion.name,
                            math.max(0, target - have),
                            recipe,
                            have,
                            target,
                            craftable,
                            nil
                        )
                    end
                end
            end
        end
    end

    -- Match CollectFocus water-fill: max bottleGap first, then lowest craftable.
    table.sort(list, function(a, b)
        local ga = tonumber(a.bottleGap) or 0
        local gb = tonumber(b.bottleGap) or 0
        if ga ~= gb then
            return ga > gb
        end
        local ca = tonumber(a.craftable) or 0
        local cb = tonumber(b.craftable) or 0
        if ca ~= cb then
            return ca < cb
        end
        local da = tonumber(a.deficit) or 0
        local db = tonumber(b.deficit) or 0
        if da ~= db then
            return da > db
        end
        return tostring(a.potionKey) < tostring(b.potionKey)
    end)
    return list
end

local function ResolveSeedForLiftSpec(spec, SM, demandRow)
    local plantUid = 0
    local seedUid = 0
    local seed = nil
    if type(demandRow) == "table" then
        plantUid = tonumber(demandRow.plantUid) or 0
        seedUid = tonumber(demandRow.seedUid) or 0
    end
    if SM.FindPlantUidForSpec and type(spec) == "table" then
        local found = tonumber(SM.FindPlantUidForSpec(spec)) or 0
        if found > 0 then
            plantUid = found
        end
    end
    if seedUid <= 0 and SM.ResolveSeedForSpec and type(spec) == "table" then
        seed = SM.ResolveSeedForSpec(spec)
        if type(seed) == "table" then
            seedUid = tonumber(seed.uniqueID or seed.uid) or 0
            if plantUid <= 0 then
                plantUid = tonumber(seed.plantUid) or 0
            end
        end
    end
    -- Plant known but seed unmapped: still try PickBestSeedUid (learned grows / bag).
    if seedUid <= 0 and plantUid > 0 and SM.PickBestSeedUid then
        seedUid = tonumber(SM.PickBestSeedUid(plantUid)) or 0
        if seedUid > 0 then
            seed = { uniqueID = seedUid, plantUid = plantUid }
        end
    end
    if type(seed) ~= "table" and seedUid > 0 then
        seed = { uniqueID = seedUid, plantUid = plantUid }
    end
    return seed, seedUid, plantUid
end

--- Pick one seed that raises craftable for this watch, or why it cannot.
--- Returns job, why — why is nil on success; "refine-first" | "non-growable" | "no-seed" | "none".
local function PickCraftableLiftJobForWatch(watch, SM, RS, demand)
    if type(watch) ~= "table" or type(watch.recipe) ~= "table" then
        return nil, "none"
    end
    local recipe = watch.recipe
    if RS.HydrateRecipeSlots then
        RS.HydrateRecipeSlots(recipe)
    end
    local slots = recipe.slots
    if type(slots) ~= "table" or #slots == 0 then
        return nil, "none"
    end

    local snaps = {}
    local minCrafts = nil
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" then
            local spec = slot.spec
            if type(spec) ~= "table" and RS.ResolveSlotSpec then
                spec = RS.ResolveSlotSpec(slot)
            end
            if type(spec) == "table" then
                local perCraft = 1
                if RS.EffectiveSpecPerCraft then
                    perCraft = math.max(1, tonumber(RS.EffectiveSpecPerCraft(slot, slots)) or 1)
                else
                    perCraft = math.max(1, tonumber(slot.perCraft) or 1)
                end
                local specKey = nil
                local MS = StockPiler3.MaterialSpec
                if MS and MS.Key then
                    local bound = nil
                    if spec.incomplete == true then
                        bound = tonumber(spec.boundUid) or tonumber(spec.uid) or nil
                    end
                    specKey = MS.Key(spec, bound)
                end
                if (specKey == nil or specKey == "") and MS and MS.ProductKey then
                    specKey = MS.ProductKey(spec)
                end
                local demandRow = nil
                if type(demand) == "table" and specKey ~= nil and tostring(specKey) ~= "" then
                    demandRow = demand[specKey] or demand[tostring(specKey)]
                end
                local seed, seedUid, plantUid = ResolveSeedForLiftSpec(spec, SM, demandRow)
                local bag = 0
                if RS.CountItemsMatchingSpec then
                    bag = tonumber(RS.CountItemsMatchingSpec(spec)) or 0
                end
                local ground = CountInGroundSeeds(seedUid)
                local pending = tonumber(Grow._seedCommitted[seedUid]) or 0
                local have = bag + ground + pending
                local craftsHave = math.floor(have / perCraft)
                if craftsHave < 0 then
                    craftsHave = 0
                end
                local growable = SM.IsGrowableSpec and SM.IsGrowableSpec(spec) == true
                local isByproduct = SM.IsHarvestByproduct and SM.IsHarvestByproduct(spec) == true
                local demandShort = 0
                if type(demandRow) == "table" then
                    demandShort = math.max(
                        tonumber(demandRow.craftsShort) or 0,
                        tonumber(demandRow.deficit) or 0
                    )
                end
                snaps[#snaps + 1] = {
                    spec = spec,
                    specKey = specKey,
                    role = tostring(slot.role or SpecRole(spec)),
                    perCraft = perCraft,
                    seed = seed,
                    seedUid = seedUid,
                    plantUid = plantUid,
                    have = have,
                    craftsHave = craftsHave,
                    growable = growable == true,
                    isByproduct = isByproduct == true,
                    demandShort = demandShort,
                    demandRow = demandRow,
                }
                -- Only demand-short growables set the lift floor (ignore buy-only and stocked plants).
                if growable == true and demandShort > 0 then
                    if minCrafts == nil or craftsHave < minCrafts then
                        minCrafts = craftsHave
                    end
                end
            end
        end
    end
    -- No growable demand-short on this watch → hand off (buy/convert-only or fully stocked plants).
    if minCrafts == nil then
        return nil, "non-growable"
    end
    minCrafts = tonumber(minCrafts) or 0

    local plantable = {}
    local needsRefine = false
    local Refine = StockPiler3.Refine
    for i = 1, #snaps do
        local s = snaps[i]
        if s.growable == true and (tonumber(s.demandShort) or 0) > 0 and s.craftsHave <= minCrafts then
            local seedUid = tonumber(s.seedUid) or 0
            local bag = OpaqueSeedCredit(seedUid, LiveSeedBag(seedUid))
            local committed = tonumber(Grow._seedCommitted[seedUid]) or 0
            local avail = bag - committed
            if seedUid > 0 and CanUseSeedUid(seedUid) and avail >= 1 then
                plantable[#plantable + 1] = s
            else
                local refinable = 0
                if Refine and Refine.CountRefinablePlants then
                    refinable = tonumber(Refine.CountRefinablePlants(s.plantUid, s.spec)) or 0
                end
                if refinable > 0 then
                    needsRefine = true
                end
            end
        end
    end

    if #plantable <= 0 then
        if needsRefine then
            return nil, "refine-first"
        end
        return nil, "no-seed"
    end

    -- Among growable bottlenecks: fewest plants to next craft, then role, then diversify seed.
    local best = nil
    local bestNeed = 999
    local bestRole = 99
    for i = 1, #plantable do
        local s = plantable[i]
        local rem = s.have % s.perCraft
        local needToNext = (rem == 0) and s.perCraft or (s.perCraft - rem)
        local role = RoleRank(s.role)
        local better = false
        if best == nil then
            better = true
        elseif needToNext < bestNeed then
            better = true
        elseif needToNext == bestNeed then
            if role < bestRole then
                better = true
            elseif role == bestRole
                and (tonumber(s.seedUid) or 0) ~= (tonumber(Grow._lastPlantedSeedUid) or 0)
                and (tonumber(best.seedUid) or 0) == (tonumber(Grow._lastPlantedSeedUid) or 0)
            then
                better = true
            end
        end
        if better then
            best = s
            bestNeed = needToNext
            bestRole = role
        end
    end
    if best == nil then
        return nil, "none"
    end

    local craftsShort = math.max(1, bestNeed)
    return {
        spec = best.spec,
        specKey = best.specKey,
        seed = best.seed or { uniqueID = best.seedUid },
        seedUid = best.seedUid,
        plantUid = best.plantUid,
        seedHave = OpaqueSeedCredit(best.seedUid, LiveSeedBag(best.seedUid)),
        plantable = craftsShort,
        deficit = tonumber(watch.deficit) or 0,
        craftsShort = craftsShort,
        role = best.role,
        plantReason = "potion_stock",
        plotCount = CountInGroundSeeds(best.seedUid),
        pickMode = "watch-lift",
        watchKey = watch.potionKey,
        watchName = watch.name,
        potionDeficit = tonumber(watch.deficit) or 0,
    }, nil
end

local function LogPlantPick(job)
    if type(job) ~= "table" then
        return
    end
    local key = string.format(
        "%s:%s:%s",
        tostring(job.watchKey or ""),
        tostring(job.seedUid or 0),
        tostring(job.role or "")
    )
    if Grow._lastPickLogKey == key then
        return
    end
    Grow._lastPickLogKey = key
    LogGrow(string.format(
        "pick watch=%s deficit=%s role=%s seedUid=%s",
        tostring(job.watchKey or "?"),
        tostring(job.potionDeficit or job.deficit or 0),
        tostring(job.role or "?"),
        tostring(job.seedUid or 0)
    ))
end

function Grow.PickPlantCandidate()
    local Perf = StockPiler3.Perf
    if Perf and Perf.Begin then
        Perf.Begin("PickPlantCandidate")
    end
    local function done(job)
        if Perf and Perf.End then
            Perf.End("PickPlantCandidate")
        end
        return job
    end
    ClampSeedCommitsToBag()
    local RS = StockPiler3.RecipeSpec
    local SM = StockPiler3.SeedMap
    if type(RS) ~= "table" or type(SM) ~= "table"
        or not SM.IsGrowableSpec or not SM.ResolveSeedForSpec
    then
        return done(nil)
    end

    local demand = RS.BuildBalancedSpecDemand and RS.BuildBalancedSpecDemand() or nil
    local watches = CollectPlantWatchOrder(RS)
    local maxGap = 0
    for i = 1, #watches do
        local g = tonumber(watches[i].bottleGap) or 0
        if g > maxGap then
            maxGap = g
        end
    end
    local needsRefine = false
    for i = 1, #watches do
        local watch = watches[i]
        local job, why = PickCraftableLiftJobForWatch(watch, SM, RS, demand)
        if type(job) == "table" then
            LogPlantPick(job)
            return done(job)
        end
        if why == "refine-first" then
            -- Focus watch has plants to convert — idle plots until refine, do not fill
            -- lower-gap watches while those seeds are pending.
            needsRefine = true
            break
        end
        -- no-seed / non-growable → fall back to next watch (lower bottleGap OK).
        -- Bottle-gap order already preferred focus; empty plots should not idle when
        -- another watch has plantable seeds.
    end
    if needsRefine then
        return done(nil)
    end
    if type(demand) == "table" and PotionStockNeedsRefineFirst(demand, SM) then
        return done(nil)
    end

    local Watch = StockPiler3.Watch
    if not (Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true) then
        return done(nil)
    end
    if not RS.CollectAutoGrowSeedLines then
        return done(nil)
    end
    local lines = RS.CollectAutoGrowSeedLines() or {}
    local focusGap = maxGap
    if focusGap <= 0 then
        for i = 1, #watches do
            local d = tonumber(watches[i].deficit) or 0
            if d > focusGap then
                focusGap = d
            end
        end
    end
    local best = PickBufferGrowCandidate(lines, SM, nil, demand, focusGap)
    if best ~= nil then
        best.pickMode = "buffer"
        LogPlantPick(best)
        return done(best)
    end
    if focusGap > 0 then
        return done(nil)
    end
    best = PickSurplusCandidate(lines)
    if best ~= nil then
        best.pickMode = "surplus"
        LogPlantPick(best)
    end
    return done(best)
end

function Grow.GetPlantJob()
    if Grow._plantQueueDirty ~= true and type(Grow._cachedPlantJob) == "table" then
        return Grow._cachedPlantJob
    end
    local job = Grow.PickPlantCandidate()
    Grow._cachedPlantJob = job
    Grow._plantQueueDirty = false
    return job
end

function Grow.PeekSeedsForNextPlant()
    if Grow._plantQueueDirty == true then
        return false, "dirty"
    end
    local job = Grow._cachedPlantJob
    if type(job) == "table" and (tonumber(job.seedUid) or 0) > 0 then
        return true, job
    end
    if Grow._plantQueueDirty ~= true and Grow._cachedPlantJob == nil then
        return false, "none"
    end
    return false, "unprobed"
end

function Grow.HasSeedsForNextPlant()
    local job = Grow.GetPlantJob()
    return type(job) == "table" and (tonumber(job.seedUid) or 0) > 0
end

function Grow.HasPendingPlant()
    for _, n in pairs(Grow._pendingPlant) do
        if (tonumber(n) or 0) > 0 then
            return true
        end
    end
    return false
end

----------------------------------------------------------------
-- IssuePlantOne
----------------------------------------------------------------

function Grow.LogSkipPlant(reason)
    LogOnce("skip-" .. tostring(reason or "?"), "skip plant reason=" .. tostring(reason or "?"))
end

function Grow.IssuePlantOne(opId)
    if Grow._chatHarvestNeedsForce == true then
        local now = NowSec()
        local lastForce = tonumber(Grow._lastHarvestForceAt) or 0
        local debounce = tonumber(Grow.HARVEST_FORCE_DEBOUNCE_SEC) or 1.5
        Grow._chatHarvestNeedsForce = false
        if lastForce <= 0 or now <= 0 or (now - lastForce) >= debounce then
            Grow.WakeAfterHarvest(0)
        end
    end
    if StockPiler3.Orchestrator and StockPiler3.Orchestrator.IsBrewSessionActive
        and StockPiler3.Orchestrator.IsBrewSessionActive() == true
    then
        return false
    end
    if not Grow.IsEnabled() then
        return false
    end
    local Sch = StockPiler3.Scheduler
    if Sch and Sch.ShouldDeferAutoGrowPlant then
        local deferPlant, deferReason = Sch.ShouldDeferAutoGrowPlant()
        if deferPlant == true then
            Grow.LogSkipPlant(tostring(deferReason or "combat"))
            return false
        end
    end
    local quietUntil = tonumber(Grow._plantQuietUntil) or 0
    if quietUntil > 0 then
        local now = NowSec()
        if now > 0 and now < quietUntil then
            return false
        end
        Grow._plantQuietUntil = 0
    end
    if Grow.ShouldHoldPlantForReadyHarvest() == true then
        return false
    end

    local Perf = StockPiler3.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Grow.IssuePlantOne")
    end
    local function done(ok)
        if Perf and Perf.End then
            Perf.End("Grow.IssuePlantOne")
        end
        return ok == true
    end

    local plotNum = Grow.FindNextEmptyPlot()
    if plotNum <= 0 then
        return done(false)
    end
    local CA = StockPiler3.CultivatorAdapter
    local BA = StockPiler3.BagAdapter
    if not CA or not CA.PlantSeed then
        return done(false)
    end
    if CA.ReadPlot then
        local live = CA.ReadPlot(plotNum)
        if type(live) == "table" then
            if live.locked == true or NormalizeStage(live.stage) ~= StageEmpty() then
                return done(false)
            end
        end
    end

    local job = Grow.GetPlantJob()
    if job == nil and Grow.HasEmptyPlot() and Grow._commitForceCleared ~= true then
        Grow.InvalidatePlantQueue({ force = true, keepCommitForceCleared = true })
        Grow._commitForceCleared = true
        job = Grow.GetPlantJob()
    end
    if type(job) ~= "table" then
        if Grow.HasPendingBufferRefine() then
            if StockPiler3.Refine and StockPiler3.Refine.MarkRefineDue then
                StockPiler3.Refine.MarkRefineDue("seed-buffer")
            end
            Grow.ClearFillBlocked()
        else
            Grow.SetFillBlocked(true, 5)
        end
        return done(false)
    end

    local seedUid = tonumber(job.seedUid) or 0
    local slot, item, backpackType = 0, nil, nil
    if BA and BA.FindSeedSlot then
        slot, item, backpackType = BA.FindSeedSlot(seedUid)
    end
    if slot <= 0 or type(item) ~= "table" then
        Grow.SetFillBlocked(true, 5)
        return done(false)
    end

    Grow._pendingPlant[plotNum] = 1
    Grow._pendingPlantAt[plotNum] = NowSec()
    Grow._pendingSeedUid[plotNum] = seedUid
    Grow._pendingSeedHeld[plotNum] = true
    Grow._seedCommitted[seedUid] = (tonumber(Grow._seedCommitted[seedUid]) or 0) + 1
    Grow._wavePlantedBySeed[seedUid] = (tonumber(Grow._wavePlantedBySeed[seedUid]) or 0) + 1

    local CC = StockPiler3.CraftChatAdapter
    if CC and CC.StashSoilPending then
        CC.StashSoilPending(plotNum, {
            reason = tostring(job.plantReason or "potion_stock"),
            name = item.name,
            seedUid = seedUid,
        })
    end

    CA.SetCurrentPlot(plotNum)
    local ok = CA.PlantSeed(plotNum, slot, backpackType)
    if ok ~= true then
        ReleaseCommit(plotNum, false)
        if CC and CC.ClearSoilPending then
            CC.ClearSoilPending(plotNum)
        end
        Grow.SetFillBlocked(true, 5)
        return done(false)
    end

    -- Seed left the bag; keep _pendingPlant until soil confirm so plots are not reused.
    ReleaseSeedReservation(plotNum)
    Grow._lastPlantedSeedUid = seedUid
    Grow._commitForceCleared = false
    Grow.InvalidatePlantQueue({})
    LogGrow(string.format(
        "plant P%d seedUid=%d role=%s watch=%s reason=%s opId=%s",
        plotNum,
        seedUid,
        tostring(job.role or "?"),
        tostring(job.watchKey or "?"),
        tostring(job.plantReason or ""),
        tostring(opId or "?")
    ))
    return done(true)
end

function Grow.TryPlantOne(opId)
    return Grow.IssuePlantOne(opId)
end

----------------------------------------------------------------
-- Additives
----------------------------------------------------------------

function Grow.NeedsCurrentStageAdditive()
    local Watch = StockPiler3.Watch
    if not Watch or not Watch.IsAutoGrowAdditivesEnabled or Watch.IsAutoGrowAdditivesEnabled() ~= true then
        return false
    end
    local Add = StockPiler3.Additives
    if not Add or not Add.NeedsCurrentStage then
        return Grow._additiveDirty == true
    end
    return Add.NeedsCurrentStage() == true
end

function Grow.TryAdditive(opId)
    if Grow.NeedsCurrentStageAdditive() ~= true then
        return false
    end
    local Add = StockPiler3.Additives
    local CA = StockPiler3.CultivatorAdapter
    if not (Add and Add.PickNext and CA and CA.AddAdditive) then
        Grow._additiveDirty = false
        return false
    end
    local Perf = StockPiler3.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Grow.TryAdditive")
    end
    local pick = Add.PickNext()
    local ok = false
    if type(pick) == "table" and (tonumber(pick.plotNum) or 0) > 0 and (tonumber(pick.slot) or 0) > 0 then
        ok = CA.AddAdditive(pick.plotNum, pick.slot, pick.backpackType) == true
        if ok then
            LogGrow("additive P" .. tostring(pick.plotNum) .. " opId=" .. tostring(opId or "?"))
        end
    end
    Grow._additiveDirty = false
    if Perf and Perf.End then
        Perf.End("Grow.TryAdditive")
    end
    return ok
end

function Grow.MarkAdditiveDue()
    Grow._additiveDirty = true
end

----------------------------------------------------------------
-- Harvest
----------------------------------------------------------------

function Grow.GetReadyHarvestPlots()
    return GetReadyHarvestPlots()
end

function Grow.ShouldHoldPlantForReadyHarvest()
    local ready = GetReadyHarvestPlots()
    if #ready <= 0 then
        return false
    end
    if HasPlotGrowing() then
        return false
    end
    return true
end

function Grow.ArmHarvestOpLock(seconds)
    seconds = tonumber(seconds) or Grow.HARVEST_OP_LOCK_SEC
    local untilT = NowSec() + seconds
    local cur = tonumber(Grow._harvestOpLockUntil) or 0
    if untilT > cur then
        Grow._harvestOpLockUntil = untilT
    end
end

function Grow.IsHarvestOpActive()
    local untilT = tonumber(Grow._harvestOpLockUntil) or 0
    if untilT <= 0 then
        return false
    end
    if NowSec() < untilT then
        return true
    end
    Grow._harvestOpLockUntil = 0
    return false
end

function Grow.CanHarvestNow()
    if StockPiler3.Brew and StockPiler3.Brew.BlocksHarvest and StockPiler3.Brew.BlocksHarvest() == true then
        return false
    end
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local ready = GetReadyHarvestPlots()
    return #ready > 0
end

--- True when every planted plot is grown (empty ignored). Mid-batch stays lit without re-chime.
function Grow.AllPlantedPlotsHarvestReady()
    local plots = StockPiler3.Garden and StockPiler3.Garden.GetPlots and StockPiler3.Garden.GetPlots()
    if type(plots) ~= "table" then
        return false, 0, 0
    end
    local planted = 0
    local ready = 0
    for i = 1, #plots do
        local row = plots[i]
        if type(row) == "table" and not IsPlotEmptyRow(row) then
            planted = planted + 1
            if IsPlotGrownStage(row.stage) then
                ready = ready + 1
            end
        end
    end
    return planted > 0 and ready == planted, ready, planted
end

--- User chat for one plot harvest (main plant only).
function Grow.NotifyHarvestOutcome(plotNum, opts)
    opts = type(opts) == "table" and opts or {}
    plotNum = tonumber(plotNum) or 0
    local function NotifyChat(msg)
        if StockPiler3.Debug and StockPiler3.Debug.Notify then
            StockPiler3.Debug.Notify(msg)
        elseif StockPiler3.Debug and StockPiler3.Debug.Print then
            StockPiler3.Debug.Print(msg)
        end
    end
    local function T(key, tokens)
        if StockPiler3.T then
            return StockPiler3.T(key, tokens)
        end
        return towstring(tostring(key or ""))
    end
    if opts.critFail == true then
        NotifyChat(T("grow.harvest_crit_fail", { plot = tostring(plotNum) }))
        return
    end
    local count = tonumber(opts.count) or 0
    local name = opts.name
    if name == nil or name == L"" or name == "" then
        return
    end
    local uid = tonumber(opts.uniqueID) or 0
    local CC = StockPiler3.CraftChatAdapter
    if CC and CC.ItemLink and uid > 0 then
        name = CC.ItemLink(uid, name)
    elseif type(name) == "string" then
        name = towstring(name)
    end
    NotifyChat(T("grow.harvest_outcome", {
        plot = tostring(plotNum),
        count = tostring(math.max(1, count)),
        name = name,
    }))
end

--- One-shot harvest-ready chat + HELP_TIPS_NEW; clear latch when not ready.
function Grow.MaybeNotifyHarvestReady()
    local allReady, readyN = Grow.AllPlantedPlotsHarvestReady()
    local canHarvest = Grow.CanHarvestNow() == true
    local ready = allReady == true and canHarvest == true
    local wasReady = Grow._harvestReadyLatched == true
    -- Enable Harvest as soon as any plot is harvestable (not only all-planted latch).
    if canHarvest and StockPiler3Window and StockPiler3Window.SyncActionReadiness then
        if Grow._canHarvestLatched ~= true then
            StockPiler3Window.SyncActionReadiness({ immediate = true })
            Grow._canHarvestLatched = true
        elseif StockPiler3Window.RequestFooterRefresh then
            StockPiler3Window.RequestFooterRefresh()
        end
    elseif Grow._canHarvestLatched == true then
        Grow._canHarvestLatched = false
        if StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
            StockPiler3Window.RequestFooterRefresh()
        end
    end
    if ready then
        if not wasReady then
            if StockPiler3Window and StockPiler3Window.SyncActionReadiness then
                StockPiler3Window.SyncActionReadiness({ immediate = true })
            elseif StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
                StockPiler3Window.RequestFooterRefresh()
            end
        elseif StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
            StockPiler3Window.RequestFooterRefresh()
        end
        Grow._harvestReadyLatched = true
        if Grow._harvestReadyChatSent ~= true then
            Grow._harvestReadyChatSent = true
            local msg = L"Harvest: Ready - " .. towstring(tostring(readyN)) .. L" plot(s)."
            if StockPiler3.T then
                msg = StockPiler3.T("grow.harvest_ready", { count = tostring(readyN) })
            end
            if StockPiler3.Debug and StockPiler3.Debug.Print then
                StockPiler3.Debug.Print(msg)
            end
            local soundId = GameData and GameData.Sound and GameData.Sound.HELP_TIPS_NEW
            if soundId and Sound and Sound.Play then
                Sound.Play(soundId)
            end
        end
    else
        if wasReady and StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
            StockPiler3Window.RequestFooterRefresh()
        end
        Grow._harvestReadyLatched = false
        Grow._harvestReadyChatSent = false
    end
end

function Grow.PrepareHarvest(manual)
    if Grow.IsHarvestOpActive() then
        return false
    end
    local ready = GetReadyHarvestPlots()
    if #ready <= 0 then
        return false
    end
    local plotNum = ready[1]
    local last = tonumber(Grow._lastPreparedHarvestPlot) or 0
    if last == plotNum and manual ~= true then
        return true
    end
    local CA = StockPiler3.CultivatorAdapter
    if CA and CA.SetCurrentPlot then
        CA.SetCurrentPlot(plotNum)
    end
    Grow._lastPreparedHarvestPlot = plotNum
    return true
end

function Grow.PrepareHarvestPlot(manual)
    return Grow.PrepareHarvest(manual)
end

function Grow.HarvestClick()
    if not Grow.CanHarvestNow() then
        return false
    end
    local Perf = StockPiler3.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Grow.HarvestClick")
    end
    Grow.ArmHarvestOpLock(Grow.HARVEST_OP_LOCK_SEC)
    local ok = Grow.PrepareHarvest(true)
    if ok then
        local plotNum = tonumber(Grow._lastPreparedHarvestPlot) or 0
        local CA = StockPiler3.CultivatorAdapter
        if CA and CA.HarvestPlot and plotNum > 0 then
            ok = CA.HarvestPlot(plotNum) == true
        end
    end
    if Perf and Perf.End then
        Perf.End("Grow.HarvestClick")
    end
    return ok == true
end

function Grow.HarvestNext(opId)
    return Grow.HarvestClick()
end

function Grow.WakeAfterHarvest(plotNum, opts)
    opts = type(opts) == "table" and opts or {}
    local now = NowSec()
    local plantDelay = tonumber(Grow.POST_HARVEST_PLANT_DELAY_SEC) or 0.75
    local Sch = StockPiler3.Scheduler
    local stormFloor = (Sch and tonumber(Sch.HARVEST_STORM_MIN_SEC)) or 1.5
    local stormSec = math.max(plantDelay, stormFloor)
    if Sch and Sch.ArmHarvestStorm then
        Sch.ArmHarvestStorm(stormSec)
    end
    if Sch and Sch.ArmPlantQuiet then
        Sch.ArmPlantQuiet(stormSec)
    end
    local quietUntil = now + stormSec
    if quietUntil > (tonumber(Grow._plantQuietUntil) or 0) then
        Grow._plantQuietUntil = quietUntil
    end
    Grow.ClearFillBlocked()
    if opts.soft == true then
        Grow._chatHarvestNeedsForce = true
        if Sch and Sch.WakeAutoGrow then
            Sch.WakeAutoGrow()
        end
        return
    end
    local debounce = tonumber(Grow.HARVEST_FORCE_DEBOUNCE_SEC) or 1.5
    local lastForce = tonumber(Grow._lastHarvestForceAt) or 0
    local doForce = lastForce <= 0 or now <= 0 or (now - lastForce) >= debounce
    if doForce then
        Grow._lastHarvestForceAt = now
        -- Single force plant-queue invalidate across multi-plot wake.
        Grow.InvalidatePlantQueue({ force = true, keepPlanCache = true })
        if Sch and Sch.EnqueuePlanRebuild then
            Sch.EnqueuePlanRebuild()
        end
        if StockPiler3.Refine and StockPiler3.Refine.MarkRefineDue then
            StockPiler3.Refine.MarkRefineDue("harvest")
        end
    end
    Grow._chatHarvestNeedsForce = false
    if Sch and Sch.WakeAutoGrow then
        Sch.WakeAutoGrow()
    end
    LogOnce(
        "harvest-wake-" .. tostring(plotNum or 0),
        string.format("harvest-wake P%s force=%s", tostring(plotNum or "?"), tostring(doForce))
    )
end

function Grow.WakeAfterHarvestChat()
    Grow.WakeAfterHarvest(0, { soft = true })
end

function Grow.ExpireStalePending()
    local now = NowSec()
    local ttl = tonumber(Grow.PENDING_TTL_SEC) or 10
    local grace = tonumber(Grow.PENDING_EMPTY_GRACE_SEC) or 5
    for plotNum, at in pairs(Grow._pendingPlantAt) do
        at = tonumber(at) or 0
        if at > 0 and now > 0 and (now - at) > (ttl + grace) then
            ReleaseCommit(plotNum, false)
            local untilT = now + (tonumber(Grow.UNCONFIRMED_PLANT_COOLDOWN_SEC) or 6)
            Grow._plantFailCooldownUntil[plotNum] = untilT
            local quiet = now + (tonumber(Grow.UNCONFIRMED_GARDEN_QUIET_SEC) or 8)
            if quiet > (tonumber(Grow._plantQuietUntil) or 0) then
                Grow._plantQuietUntil = quiet
            end
        end
    end
    local CC = StockPiler3.CraftChatAdapter
    if CC and CC.ExpireStaleChatMeta then
        CC.ExpireStaleChatMeta()
    end
end

function Grow.OnCultivationUpdated(plotNum)
    plotNum = tonumber(plotNum) or 0
    local row = StockPiler3.Garden and StockPiler3.Garden.GetPlot and StockPiler3.Garden.GetPlot(plotNum)
    local CC = StockPiler3.CraftChatAdapter
    if CC and CC.TryConfirmFromPlot then
        CC.TryConfirmFromPlot(plotNum, row)
    end
    if type(row) == "table" and not IsPlotEmptyRow(row) then
        if (tonumber(Grow._pendingPlant[plotNum]) or 0) > 0 then
            ReleaseCommit(plotNum, true)
        end
    elseif type(row) == "table" and IsPlotEmptyRow(row) then
        if CC and CC.OnSoilStillEmpty then
            CC.OnSoilStillEmpty(plotNum, {})
        end
    end
    Grow.MaybeNotifyHarvestReady()
end

----------------------------------------------------------------
-- Dump
----------------------------------------------------------------

function Grow.DumpDiagnostics(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler3.Debug and StockPiler3.Debug.Print then
            StockPiler3.Debug.Print(msg)
        end
    end
    emit("=== grow plan ===")
    emit("enabled=" .. tostring(Grow.IsEnabled()))
    emit("fillBlocked=" .. tostring(Grow.IsFillBlocked())
        .. " wait=" .. tostring(Grow._plantWaitTicks or 0))
    emit("emptyPlot=" .. tostring(Grow.HasEmptyPlot())
        .. " seeds=" .. tostring(Grow.HasSeedsForNextPlant()))
    emit("bufferSatisfied=" .. tostring(Grow.IsSeedBufferSatisfied())
        .. " pendingRefine=" .. tostring(Grow.HasPendingBufferRefine())
        .. " bufferShort=" .. tostring(Grow.HasAnyBufferShort()))
    emit("holdHarvestBatch=" .. tostring(Grow.ShouldHoldPlantForReadyHarvest())
        .. " canHarvest=" .. tostring(Grow.CanHarvestNow()))
    emit("lastPlantedSeedUid=" .. tostring(Grow._lastPlantedSeedUid or 0))
    local job = Grow._cachedPlantJob
    if type(job) == "table" then
        emit(string.format(
            "job seedUid=%s role=%s watch=%s deficit=%s reason=%s mode=%s",
            tostring(job.seedUid),
            tostring(job.role),
            tostring(job.watchKey),
            tostring(job.potionDeficit or job.deficit),
            tostring(job.plantReason),
            tostring(job.pickMode)
        ))
    else
        emit("job=(none)")
    end
    local ready = GetReadyHarvestPlots()
    emit("readyPlots=" .. table.concat(ready, ","))
    emit("=== end grow plan ===")
end

function Grow.DumpGrowPlan(emit)
    Grow.DumpDiagnostics(emit)
end
