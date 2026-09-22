----------------------------------------------------------------
-- StockPiler3 UpgradeSeed - watch-driven family climb
-- buy L1 -> plant -> crit harvest -> refine -> repeat toward watch skillReq.
-- Shared seed economy (SeedDeficit / PlantableSurplus / GetSeedBudget) and
-- ladder scan helpers also used by SkillUp (mains-only, TargetMaxSkill cap).
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.UpgradeSeed = StockPiler3.UpgradeSeed or {}
local US = StockPiler3.UpgradeSeed

US._stallLatch = nil
US._active = nil -- last pick { familyKey, haveReq, needReq, why }
US._upgradeTargetsCache = nil
US._upgradeTargetsKey = nil

local function CharRow(create)
    return StockPiler3.Util.CharacterRow(create == true)
end

function US.IsEnabled()
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local row = CharRow(false)
    return type(row) == "table" and row.upgradeSeedsEnabled == true
end

function US.SetEnabled(enabled)
    local row = CharRow(true)
    if type(row) ~= "table" then
        return false
    end
    row.upgradeSeedsEnabled = enabled == true
    US.InvalidateUpgradeTargetsCache()
    local Watch = StockPiler3.Watch
    if Watch and Watch.BumpGen then
        Watch.BumpGen()
    end
    return true
end

function US.GetCultSkill()
    -- SkillUp owns the Caps facade; fall back if SkillUp is unavailable.
    local SkillUp = StockPiler3.SkillUp
    if SkillUp and SkillUp.GetCultSkill then
        return tonumber(SkillUp.GetCultSkill()) or 0
    end
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.GetCultSkill then
        return tonumber(Caps.GetCultSkill()) or 0
    end
    if Caps and Caps.GetCultivationSkill then
        return tonumber(Caps.GetCultivationSkill()) or 0
    end
    return 0
end

--- Cult seed/plant floor (1, 25, ...). Canonical implementation is SkillUp.FloorCultTier.
function US.FloorCultTier(cultSkill)
    local SkillUp = StockPiler3.SkillUp
    if SkillUp and SkillUp.FloorCultTier then
        return SkillUp.FloorCultTier(cultSkill)
    end
    cultSkill = tonumber(cultSkill) or 0
    local tiers = { 1, 25, 50, 75, 100, 125, 150, 175 }
    local best = 0
    for i = 1, #tiers do
        if cultSkill >= tiers[i] then
            best = tiers[i]
        end
    end
    return best
end

--- Climb cap for a watch need: min(needed skillReq, Cult floor).
function US.ClimbCap(neededReq)
    neededReq = tonumber(neededReq) or 0
    local floor = US.FloorCultTier(US.GetCultSkill())
    if floor < 1 then
        floor = 1
    end
    if neededReq < 1 then
        return floor
    end
    if neededReq < floor then
        return neededReq
    end
    return floor
end

--- Shared seed budget facade (Refine.GetSeedBudget).
function US.GetSeedBudget(seedUid)
    local Refine = StockPiler3.Refine
    if Refine and Refine.GetSeedBudget then
        local b = Refine.GetSeedBudget(seedUid)
        if type(b) == "table" then
            return b
        end
    end
    return {
        live = 0,
        ground = 0,
        outstanding = 0,
        credit = 0,
        headroom = 0,
        bufferMin = 0,
    }
end

function US.CountEmptyPlots()
    local Grow = StockPiler3.Grow
    if Grow and Grow.CountEmptyPlots then
        return tonumber(Grow.CountEmptyPlots()) or 0
    end
    return 0
end

--- Seeds still needed for planting / AutoBuy.
--- mode "climb" (default): with buffer on, buy to (buffer + empty) so climb surplus exists.
--- mode "skillup": max(headroom, empty-plot need) - SkillUp fills all plots.
function US.SeedDeficit(seedUid, mode)
    seedUid = tonumber(seedUid) or 0
    mode = tostring(mode or "climb")
    local empty = US.CountEmptyPlots()
    local budget = US.GetSeedBudget(seedUid)
    local buffer = tonumber(budget.bufferMin) or 0
    local live = tonumber(budget.live) or 0
    local headroom = tonumber(budget.headroom) or 0
    local needPlots = empty
    if live >= empty then
        needPlots = 0
    else
        needPlots = empty - live
    end
    if mode == "skillup" then
        return math.max(headroom, needPlots)
    end
    -- Climb planting only uses surplus above the seed buffer, so AutoBuy must
    -- top up to (buffer + empty plots) or every harvest can wipe the rung.
    if buffer > 0 then
        return math.max(0, buffer + empty - live)
    end
    return math.max(headroom, needPlots)
end

--- How many bag seeds may be planted without dipping the keep cushion.
--- opts.mode "climb" (default): L1 prefers buffer but never stalls empty plots;
--- intermediate rungs keep 0 (not vendor-restocked).
--- opts.mode "skillup": plant up to headroom when buffer-short, else fill empties.
--- opts.intermediate: climb-only - treat as non-vendor intermediate rung.
function US.PlantableSurplus(seedUid, bagSeeds, empty, opts)
    seedUid = tonumber(seedUid) or 0
    bagSeeds = tonumber(bagSeeds) or 0
    empty = tonumber(empty) or 0
    opts = type(opts) == "table" and opts or {}
    if bagSeeds < 1 or empty < 1 then
        return 0
    end
    local budget = US.GetSeedBudget(seedUid)
    local buffer = tonumber(budget.bufferMin) or 0
    local mode = tostring(opts.mode or "climb")
    if mode == "skillup" then
        local headroom = tonumber(budget.headroom) or 0
        if buffer > 0 and headroom > 0 then
            return math.min(bagSeeds, empty, headroom)
        end
        return math.min(bagSeeds, empty)
    end
    -- Climb: intermediate rungs keep 0 - those seeds are not at the vendor; holding
    -- even 1 seed with empty plots stalls the climb (seen: have=50, plantable=0).
    if buffer <= 0 or opts.intermediate == true then
        return math.min(bagSeeds, empty)
    end
    -- L1 / vendor floor: prefer surplus above the seed buffer so AutoBuy can
    -- restock. If AutoBuy only filled the cushion (e.g. plots were full then),
    -- still plant into empties — otherwise Majestic Goldweed stays need_buy
    -- forever with 5 L1 seeds and open plots.
    local live = tonumber(budget.live) or bagSeeds
    local surplus = live - buffer
    if surplus >= 1 then
        return math.min(bagSeeds, empty, surplus)
    end
    return math.min(bagSeeds, empty)
end

local function SeedBudget(seedUid)
    return US.GetSeedBudget(seedUid)
end

local function CountEmptyPlots()
    return US.CountEmptyPlots()
end

local function PlantableSurplus(seedUid, bagSeeds, empty, opts)
    return US.PlantableSurplus(seedUid, bagSeeds, empty, opts)
end

local function LadderLowestReq(ladder)
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" or #ladder.rungs < 1 then
        return 1
    end
    local lowest = tonumber(ladder.rungs[1].skillReq) or 1
    for i = 2, #ladder.rungs do
        local req = tonumber(ladder.rungs[i].skillReq) or 0
        if req >= 1 and req < lowest then
            lowest = req
        end
    end
    return lowest
end

--- True when bag seeds are not the vendor L1 cushion seed.
--- Multiplier/main ladders often start at 100+; treating that floor as "L1 buffer"
--- trapped Fusk 3010034 (live=1, buffer=5, plantable=0) while Spumepetal refined.
local function IsIntermediateClimb(ladder, ownedReq)
    ownedReq = tonumber(ownedReq) or 0
    local lowest = LadderLowestReq(ladder)
    if ownedReq > lowest then
        return true
    end
    if ownedReq > 1 then
        return true
    end
    return false
end

--- Plantable climb count for one upgrade target (0 if none / cannot plant).
local function TargetPlantableCount(t)
    if type(t) ~= "table" or type(t.ladder) ~= "table" then
        return 0, nil, 0
    end
    local needReq = tonumber(t.needReq) or 0
    local climbCap = US.ClimbCap(needReq)
    local owned = US.PickBestOwnedSeed({
        ladder = t.ladder,
        climbCap = climbCap,
    })
    if type(owned) ~= "table" or (tonumber(owned.seedUid) or 0) <= 0 then
        return 0, owned, climbCap
    end
    local seedUid = tonumber(owned.seedUid) or 0
    local ownedReq = tonumber(owned.skillReq) or 0
    local bagSeeds = tonumber(owned.count) or 0
    local empty = CountEmptyPlots()
    local intermediate = IsIntermediateClimb(t.ladder, ownedReq)
    local plantable = PlantableSurplus(seedUid, bagSeeds, empty, {
        intermediate = intermediate,
    })
    return plantable, owned, climbCap
end

--- Refine scan for one target (plants above owned seed rung).
local function TargetUpgradePlant(t)
    if type(t) ~= "table" or type(t.ladder) ~= "table" then
        return nil, 0
    end
    local needReq = tonumber(t.needReq) or 0
    local climbCap = US.ClimbCap(needReq)
    local owned = US.PickBestOwnedSeed({
        ladder = t.ladder,
        climbCap = climbCap,
    })
    local ownedReq = type(owned) == "table" and (tonumber(owned.skillReq) or 0) or 0
    local refineCap = US.FloorCultTier(US.GetCultSkill())
    if refineCap < climbCap then
        refineCap = climbCap
    end
    local up = US.ScanUpgradePlant({
        ladder = t.ladder,
        climbCap = refineCap,
        ownedSeedReq = ownedReq,
    })
    return up, ownedReq
end

--- Have the target-tier seed/plant for this climb need?
--- Only the needReq rung counts - owned lower-tier seeds must not end the climb
--- (ResolveSeedForSpec prefers bag seeds and would falsely "arrive" at L25).
--- In-ground target seeds count: bag-only checks left "Upgrading fusk 0->200 /
--- need_buy" after AutoGrow planted L200 for the seed buffer.
local function HaveTargetRung(ladder, needReq, plantUid, seedUid)
    needReq = tonumber(needReq) or 0
    local Inv = StockPiler3.Inventory
    if not Inv or not Inv.CountByUid then
        return false
    end
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    local Grow = StockPiler3.Grow

    local function haveUid(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return false
        end
        if (tonumber(Inv.CountByUid(uid)) or 0) >= 1 then
            return true
        end
        if Grow and Grow.CountSeedPlotCredit then
            return (tonumber(Grow.CountSeedPlotCredit(uid)) or 0) >= 1
        end
        if Grow and Grow.CountInGroundSeeds then
            return (tonumber(Grow.CountInGroundSeeds(uid)) or 0) >= 1
        end
        return false
    end

    if type(ladder) == "table" and type(ladder.rungs) == "table" and needReq >= 1 then
        for i = 1, #ladder.rungs do
            local rung = ladder.rungs[i]
            if (tonumber(rung.skillReq) or 0) == needReq then
                if haveUid(rung.seedUid) or haveUid(rung.plantUid) then
                    return true
                end
            end
        end
        return false
    end
    -- Ladder missing: only trust explicit target plant/seed uids.
    return haveUid(plantUid) or haveUid(seedUid)
end

--- Shared: scan bags for a refinable upgrade plant (any main family when no ladder).
--- opts: climbCap, mainsOnly, familyKey / ladder, ownedSeedReq
function US.ScanUpgradePlant(opts)
    opts = type(opts) == "table" and opts or {}
    local SM = StockPiler3.SeedMap
    local climbCap = tonumber(opts.climbCap) or 0
    if climbCap < 1 then
        return nil
    end
    local ladder = opts.ladder
    if type(ladder) ~= "table" and opts.familyKey and SM and SM.GetFamilyLadder then
        ladder = SM.GetFamilyLadder(opts.familyKey)
    end
    if type(ladder) == "table" and SM and SM.BestUpgradePlantOnLadder then
        return SM.BestUpgradePlantOnLadder(ladder, climbCap, opts.ownedSeedReq or 0, {
            mainsOnly = opts.mainsOnly == true,
        })
    end
    -- Opportunistic (SkillUp): any main plant under climbCap above ownedSeedReq.
    local Inv = StockPiler3.Inventory
    local Items = StockPiler3.Items
    local Refine = StockPiler3.Refine
    if not (Inv and Inv.ForEachItem) then
        return nil
    end
    local ownedSeedReq = tonumber(opts.ownedSeedReq) or 0
    local best = nil
    local bestReq = -1
    Inv.ForEachItem(function(item)
        if type(item) ~= "table" then
            return
        end
        if SM and SM.IsBagSeedOrSpore and SM.IsBagSeedOrSpore(item) then
            return
        end
        if SM and SM.ItemLooksLikeRefinablePlant
            and SM.ItemLooksLikeRefinablePlant(item) ~= true
            and item.isRefinable ~= true
        then
            return
        end
        local pUid = tonumber(item.uniqueID) or 0
        if pUid <= 0 then
            return
        end
        local spec = Items and Items.ToSpec and Items.ToSpec(pUid) or nil
        local role = tostring(spec and spec.role or "")
        if opts.mainsOnly == true and role ~= "" and role ~= "main" then
            return
        end
        local req = tonumber(spec and spec.skillLevel) or 0
        if req < 1 then
            req = tonumber(item.craftingSkillRequirement) or 0
        end
        if req <= ownedSeedReq or req > climbCap then
            return
        end
        local sUid = 0
        if SM and SM.ResolveSeedUidForPlant then
            sUid = tonumber(SM.ResolveSeedUidForPlant(pUid, spec)) or 0
        end
        if sUid <= 0 and SM and SM.GetSeedUidsForPlant then
            local seeds = SM.GetSeedUidsForPlant(pUid) or {}
            if type(seeds) == "table" and #seeds > 0 then
                sUid = tonumber(seeds[1]) or 0
            end
        end
        if sUid <= 0 then
            return
        end
        local refinable = 0
        if Refine and Refine.CountRefinablePlants then
            refinable = tonumber(Refine.CountRefinablePlants(pUid, spec)) or 0
        end
        if refinable <= 0 then
            return
        end
        if req > bestReq then
            bestReq = req
            best = {
                seedUid = sUid,
                plantUid = pUid,
                skillReq = req,
                refinable = refinable,
                upgrade = true,
            }
        end
    end)
    return best
end

function US.PickBestOwnedSeed(opts)
    opts = type(opts) == "table" and opts or {}
    local SM = StockPiler3.SeedMap
    local climbCap = tonumber(opts.climbCap) or 0
    if climbCap < 1 then
        return nil
    end
    local ladder = opts.ladder
    if type(ladder) ~= "table" and opts.familyKey and SM and SM.GetFamilyLadder then
        ladder = SM.GetFamilyLadder(opts.familyKey)
    end
    if type(ladder) == "table" and SM and SM.BestOwnedSeedOnLadder then
        return SM.BestOwnedSeedOnLadder(ladder, climbCap, { mainsOnly = opts.mainsOnly == true })
    end
    return nil
end

--- Collect short growable demand + plant watches that need a genus climb.
local function CollectUpgradeTargets()
    local RS = StockPiler3.RecipeSpec
    local SM = StockPiler3.SeedMap
    local Watch = StockPiler3.Watch
    local Items = StockPiler3.Items
    local MS = StockPiler3.MaterialSpec
    local Catalog = StockPiler3.Catalog
    local Inv = StockPiler3.Inventory
    if not (SM and Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true) then
        return {}
    end
    local out = {}
    local seenPlant = {}

    local function LadderFor(spec)
        if SM.GetGenusLadderForSpec then
            return SM.GetGenusLadderForSpec(spec)
        end
        return SM.GetFamilyLadderForSpec and SM.GetFamilyLadderForSpec(spec) or nil
    end

    local function NeedReqFor(spec, plantUid)
        local needReq = tonumber(spec and spec.skillLevel) or 0
        if needReq < 1 and plantUid > 0 and Inv and Inv.GetSample then
            local sample = Inv.GetSample(plantUid)
            needReq = tonumber(sample and sample.craftingSkillRequirement) or 0
        end
        if needReq < 1 then
            needReq = 1
        end
        return needReq
    end

    local function Consider(spec, short, plantUidHint)
        if type(spec) ~= "table" or (tonumber(short) or 0) < 1 then
            return
        end
        if not (SM.IsGrowableSpec and SM.IsGrowableSpec(spec) == true) then
            return
        end
        if SM.IsHarvestByproduct and SM.IsHarvestByproduct(spec) == true then
            return
        end
        local plantUid = tonumber(plantUidHint) or 0
        if plantUid <= 0 and SM.FindPlantUidForSpec then
            plantUid = tonumber(SM.FindPlantUidForSpec(spec)) or 0
        end
        if plantUid > 0 and seenPlant[plantUid] == true then
            return
        end
        local needReq = NeedReqFor(spec, plantUid)
        local ladder = LadderFor(spec)
        local seedUid = 0
        -- Prefer skill-matched plant->seed link; ResolveSeedForSpec prefers any
        -- owned genus seed in bags and would pin climb to L25 Gobswort spores.
        if plantUid > 0 and SM.ResolveSeedUidForPlant then
            seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, spec)) or 0
        end
        if seedUid <= 0 and type(ladder) == "table" and type(ladder.rungs) == "table" then
            for i = 1, #ladder.rungs do
                local rung = ladder.rungs[i]
                if (tonumber(rung.skillReq) or 0) == needReq then
                    seedUid = tonumber(rung.seedUid) or 0
                    if seedUid > 0 then
                        break
                    end
                end
            end
        end
        if seedUid <= 0 and SM.ResolveSeedForSpec then
            local seed = SM.ResolveSeedForSpec(spec)
            if type(seed) == "table" then
                seedUid = tonumber(seed.uniqueID or seed.uid) or 0
            end
        end
        if seedUid <= 0 and plantUid > 0 and SM.GetSeedUidsForPlant then
            local seeds = SM.GetSeedUidsForPlant(plantUid)
            if type(seeds) == "table" and #seeds > 0 then
                seedUid = tonumber(seeds[1]) or 0
            end
        end
        if HaveTargetRung(ladder, needReq, plantUid, seedUid) then
            return
        end
        if plantUid > 0 then
            seenPlant[plantUid] = true
        end
        out[#out + 1] = {
            spec = spec,
            needReq = needReq,
            short = tonumber(short) or 0,
            ladder = ladder,
            plantUid = plantUid,
            seedUid = seedUid,
            familyKey = ladder and ladder.key or nil,
        }
    end

    -- Potion / balanced demand (growable mats short).
    local demand = RS and RS.BuildBalancedSpecDemand and RS.BuildBalancedSpecDemand() or nil
    if type(demand) == "table" then
        for _, row in pairs(demand) do
            if type(row) == "table" and type(row.spec) == "table" then
                local absNeed = tonumber(row.absolute) or tonumber(row.brewAbsolute) or 0
                local have = 0
                if RS.CountItemsMatchingSpec then
                    have = tonumber(RS.CountItemsMatchingSpec(row.spec)) or 0
                end
                local short = math.max(0, absNeed - have)
                if short < 1 then
                    short = tonumber(row.craftsShort) or 0
                end
                Consider(row.spec, short, nil)
            end
        end
    end

    -- Explicit plant watches (e.g. Taut Gobswort stock target).
    local plantWatches = Watch.GetPlantWatches and Watch.GetPlantWatches() or {}
    if type(plantWatches) == "table" then
        for plantKey, watch in pairs(plantWatches) do
            if type(watch) == "table" and watch.enabled == true
                and (Watch.ShouldAutoGrowPlant == nil or Watch.ShouldAutoGrowPlant(plantKey) == true)
            then
                local plantUid = Watch.ParsePlantKey and Watch.ParsePlantKey(plantKey) or 0
                plantUid = tonumber(plantUid) or 0
                if plantUid > 0 then
                    local have = 0
                    if Catalog and Catalog.PlantHave then
                        have = tonumber(Catalog.PlantHave(plantUid)) or 0
                    elseif Inv and Inv.CountByUid then
                        have = tonumber(Inv.CountByUid(plantUid)) or 0
                    end
                    local target = tonumber(watch.targetStock) or 40
                    local short = target - have
                    if short >= 1 then
                        local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
                        if type(spec) ~= "table" and MS and MS.FromUid then
                            spec = MS.FromUid(plantUid)
                        end
                        Consider(spec, short, plantUid)
                    end
                end
            end
        end
    end

    table.sort(out, function(a, b)
        return (tonumber(a.short) or 0) > (tonumber(b.short) or 0)
    end)
    return out
end

local function UpgradeTargetsCacheKey()
    local Inv = StockPiler3.Inventory
    local Watch = StockPiler3.Watch
    local snapGen = 0
    local watchGen = 0
    if Inv and Inv.GetSnapGen then
        snapGen = tonumber(Inv.GetSnapGen()) or 0
    end
    if Watch and Watch.GetGen then
        watchGen = tonumber(Watch.GetGen()) or 0
    end
    -- Cult floor gates ClimbCap; include so skill-ups invalidate without bag churn.
    local cult = 0
    if US.GetCultSkill then
        cult = math.floor((tonumber(US.GetCultSkill()) or 0) / 25)
    end
    return tostring(snapGen) .. ":" .. tostring(watchGen) .. ":" .. tostring(cult)
        .. ":" .. tostring(US.IsEnabled() == true)
end

function US.InvalidateUpgradeTargetsCache()
    US._upgradeTargetsCache = nil
    US._upgradeTargetsKey = nil
end

--- Snap/watch-keyed cache over CollectUpgradeTargets (NeedsRefineFirst / PickPlantJob / status).
local function GetUpgradeTargets()
    local key = UpgradeTargetsCacheKey()
    if US._upgradeTargetsKey == key and type(US._upgradeTargetsCache) == "table" then
        return US._upgradeTargetsCache
    end
    local out = CollectUpgradeTargets()
    US._upgradeTargetsCache = out
    US._upgradeTargetsKey = key
    return out
end

function US.NeedsRefineFirst()
    if US.IsEnabled() ~= true then
        return false
    end
    local targets = GetUpgradeTargets()
    local anyRefine = false
    local anyPlantable = false
    for i = 1, #targets do
        local t = targets[i]
        local climbCap = US.ClimbCap(t.needReq)
        if climbCap < t.needReq and climbCap < 1 then
            -- gated
        else
            local up = TargetUpgradePlant(t)
            if type(up) == "table" and (tonumber(up.plantUid) or 0) > 0 then
                anyRefine = true
            end
            local plantable = TargetPlantableCount(t)
            if (tonumber(plantable) or 0) >= 1 then
                anyPlantable = true
            end
        end
    end
    -- Only skip demand/plant when refine is the only climb work.
    -- Spumepetal refine must not starve Fusk (or other) plantable climb seeds.
    return anyRefine == true and anyPlantable ~= true
end

--- Hold empty plots for climb status only when no target has plantable seeds
--- or refinable plants (need_buy / climbing must not starve another genus).
function US.ShouldHoldEmptyPlots(climb)
    if US.IsEnabled() ~= true then
        return false
    end
    local why = tostring(type(climb) == "table" and climb.why or "")
    if why == "refining" then
        -- Refine armed and PickPlantJob found no plantable elsewhere.
        return true
    end
    if why ~= "climbing" and why ~= "need_buy" and why ~= "no_family" then
        return false
    end
    local targets = GetUpgradeTargets()
    for i = 1, #targets do
        local t = targets[i]
        local plantable = TargetPlantableCount(t)
        if (tonumber(plantable) or 0) >= 1 then
            return false
        end
        local up = TargetUpgradePlant(t)
        if type(up) == "table" and (tonumber(up.plantUid) or 0) > 0 then
            return false
        end
    end
    return true
end

function US.PickPlantJob()
    if US.IsEnabled() ~= true then
        US._active = nil
        return nil
    end
    local Watch = StockPiler3.Watch
    if not (Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true) then
        return nil
    end
    if CountEmptyPlots() <= 0 then
        return nil
    end
    local SM = StockPiler3.SeedMap
    local targets = GetUpgradeTargets()
    local refineActive = nil
    local stallActive = nil
    local plantCandidates = {}
    for i = 1, #targets do
        local t = targets[i]
        local needReq = tonumber(t.needReq) or 0
        local climbCap = US.ClimbCap(needReq)
        local cultFloor = US.FloorCultTier(US.GetCultSkill())
        if cultFloor < 1 then
            US._active = {
                familyKey = t.familyKey,
                haveReq = 0,
                needReq = needReq,
                why = "need_cult",
                genus = t.ladder and t.ladder.genus,
                needCult = needReq,
            }
            return nil
        end
        if type(t.ladder) ~= "table" or type(t.ladder.rungs) ~= "table" or #t.ladder.rungs == 0 then
            stallActive = stallActive or {
                familyKey = t.familyKey,
                haveReq = 0,
                needReq = needReq,
                why = "no_family",
                genus = SM and SM.GenusKeyFromName and SM.GenusKeyFromName(t.spec and t.spec.name),
            }
        else
            local up, ownedReq = TargetUpgradePlant(t)
            local upgradePlantReq = 0
            if type(up) == "table" and (tonumber(up.plantUid) or 0) > 0 then
                upgradePlantReq = tonumber(up.skillReq) or 0
                if StockPiler3.Refine and StockPiler3.Refine.MarkRefineDue then
                    StockPiler3.Refine.MarkRefineDue("upgrade-seed")
                end
                refineActive = refineActive or {
                    familyKey = t.ladder.key,
                    haveReq = ownedReq,
                    needReq = needReq,
                    why = "refining",
                    genus = t.ladder.genus,
                }
                -- Continue: another family (e.g. Fusk) may still have plantable seeds.
            end
            local plantable, owned = TargetPlantableCount(t)
            if type(owned) == "table" and (tonumber(owned.seedUid) or 0) > 0 then
                local seedUid = tonumber(owned.seedUid) or 0
                ownedReq = tonumber(owned.skillReq) or 0
                local budget = SeedBudget(seedUid)
                local headroom = tonumber(budget.headroom) or 0
                local buffer = tonumber(budget.bufferMin) or 0
                local bagSeeds = tonumber(owned.count) or 0
                local empty = CountEmptyPlots()
                local plantUid = tonumber(owned.plantUid) or 0
                local refinable = 0
                if plantUid > 0 and StockPiler3.Refine and StockPiler3.Refine.CountRefinablePlants then
                    local Items = StockPiler3.Items
                    local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
                    refinable = tonumber(StockPiler3.Refine.CountRefinablePlants(plantUid, spec)) or 0
                end
                local intermediate = IsIntermediateClimb(t.ladder, ownedReq)
                -- Do not plant a lower rung while higher-tier plants sit in bag
                -- (L1 Fusk 3010030 filled all plots while Cloudy Fusk waited to refine).
                local plantGoesBackward = upgradePlantReq > ownedReq
                local plotCredit = 0
                local Grow = StockPiler3.Grow
                if Grow and Grow.CountSeedPlotCredit then
                    plotCredit = tonumber(Grow.CountSeedPlotCredit(seedUid)) or 0
                elseif Grow and Grow.CountInGroundSeeds then
                    plotCredit = tonumber(Grow.CountInGroundSeeds(seedUid)) or 0
                end
                -- In-ground seeds are refundable; settle buffer only after harvest outcome.
                if buffer > 0 and headroom > 0 and refinable > 0
                    and plotCredit < 1
                    and (not intermediate or bagSeeds < 1)
                then
                    if StockPiler3.Refine and StockPiler3.Refine.MarkRefineDue then
                        StockPiler3.Refine.MarkRefineDue("upgrade-seed-buffer")
                    end
                    refineActive = refineActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "refining",
                        genus = t.ladder.genus,
                    }
                elseif plantable < 1 and empty > 0 and refinable > 0 then
                    if StockPiler3.Refine and StockPiler3.Refine.MarkRefineDue then
                        StockPiler3.Refine.MarkRefineDue("upgrade-seed-reseed")
                    end
                    refineActive = refineActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "refining",
                        genus = t.ladder.genus,
                    }
                elseif plantable >= 1 and plantGoesBackward ~= true then
                    plantCandidates[#plantCandidates + 1] = {
                        seedUid = seedUid,
                        plantUid = plantUid,
                        bagSeeds = bagSeeds,
                        plantable = plantable,
                        ownedReq = ownedReq,
                        needReq = needReq,
                        short = tonumber(t.short) or 0,
                        intermediate = intermediate == true,
                        familyKey = t.ladder.key,
                        genus = t.ladder.genus,
                        targetIndex = i,
                    }
                elseif plantable >= 1 and plantGoesBackward == true then
                    if StockPiler3.Refine and StockPiler3.Refine.MarkRefineDue then
                        StockPiler3.Refine.MarkRefineDue("upgrade-seed-no-backslide")
                    end
                    refineActive = refineActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "refining",
                        genus = t.ladder.genus,
                    }
                elseif empty < 1 then
                    stallActive = stallActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "climbing",
                        genus = t.ladder.genus,
                    }
                elseif climbCap < needReq and ownedReq >= climbCap then
                    stallActive = stallActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "need_cult",
                        genus = t.ladder.genus,
                        needCult = needReq,
                    }
                elseif not intermediate and US.SeedDeficit(seedUid) >= 1 then
                    stallActive = stallActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "need_buy",
                        genus = t.ladder.genus,
                    }
                else
                    stallActive = stallActive or {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "climbing",
                        genus = t.ladder.genus,
                    }
                end
            elseif climbCap < needReq and ownedReq >= climbCap and ownedReq > 0 then
                stallActive = stallActive or {
                    familyKey = t.ladder.key,
                    haveReq = ownedReq,
                    needReq = needReq,
                    why = "need_cult",
                    genus = t.ladder.genus,
                    needCult = needReq,
                }
            else
                stallActive = stallActive or {
                    familyKey = t.ladder.key,
                    haveReq = ownedReq,
                    needReq = needReq,
                    why = "need_buy",
                    genus = t.ladder.genus,
                }
            end
        end
    end
    if #plantCandidates > 0 then
        -- Prefer the behind family (lowest owned seed rung), not the largest potion short.
        -- Spumepetal@150 with short=24 used to starve Fusk@125 before any Fusk seeds landed.
        table.sort(plantCandidates, function(a, b)
            local oa = tonumber(a.ownedReq) or 0
            local ob = tonumber(b.ownedReq) or 0
            if oa ~= ob then
                return oa < ob
            end
            return (tonumber(a.short) or 0) > (tonumber(b.short) or 0)
        end)
        local function SiblingBehind(cand)
            for i = 1, #targets do
                if i ~= (tonumber(cand.targetIndex) or 0) then
                    local t2 = targets[i]
                    local owned2 = US.PickBestOwnedSeed({
                        ladder = t2.ladder,
                        climbCap = US.ClimbCap(t2.needReq),
                    })
                    local req2 = type(owned2) == "table" and (tonumber(owned2.skillReq) or 0) or 0
                    if req2 < (tonumber(cand.ownedReq) or 0) then
                        return true
                    end
                end
            end
            return false
        end
        local function PlotsHoldingSeed(seedUid)
            seedUid = tonumber(seedUid) or 0
            if seedUid <= 0 then
                return 0
            end
            local Grow = StockPiler3.Grow
            if Grow and Grow.CountSeedPlotCredit then
                return tonumber(Grow.CountSeedPlotCredit(seedUid)) or 0
            end
            if Grow and Grow.CountInGroundSeeds then
                return tonumber(Grow.CountInGroundSeeds(seedUid)) or 0
            end
            return 0
        end
        local best = nil
        for ci = 1, #plantCandidates do
            local cand = plantCandidates[ci]
            local behind = SiblingBehind(cand)
            -- Cap is per-wave, not per-job: plantable=1 still re-picked every tick and
            -- filled all 4 plots. Skip an ahead family that already holds a plot.
            if behind == true and cand.intermediate == true
                and PlotsHoldingSeed(cand.seedUid) >= 1
            then
                cand = nil
            end
            if cand ~= nil then
                best = cand
                if behind == true and best.intermediate == true then
                    best.plantable = 1
                end
                break
            end
        end
        if best == nil then
            -- Ahead family already occupies a plot; leave empties for the behind family.
            if refineActive then
                US._active = refineActive
            elseif stallActive then
                US._active = stallActive
            end
            return nil
        end
        US._active = {
            familyKey = best.familyKey,
            haveReq = best.ownedReq,
            needReq = best.needReq,
            why = "planting",
            genus = best.genus,
            seedUid = best.seedUid,
            plantUid = best.plantUid,
        }
        US._stallLatch = nil
        local Inv = StockPiler3.Inventory
        local sample = Inv and Inv.GetSample and Inv.GetSample(best.seedUid)
        return {
            seedUid = best.seedUid,
            plantUid = best.plantUid,
            seed = sample or { uniqueID = best.seedUid },
            seedHave = best.bagSeeds,
            plantable = tonumber(best.plantable) or 1,
            deficit = tonumber(best.plantable) or 1,
            plantReason = "upgrade_seed",
            pickMode = "upgrade_seed",
            familyKey = best.familyKey,
            skillReq = best.ownedReq,
            needReq = best.needReq,
        }
    end
    if refineActive then
        US._active = refineActive
        return nil
    end
    if stallActive then
        US._active = stallActive
    end
    return nil
end

function US.AppendRefineIntents(intents, appendFn)
    if type(appendFn) ~= "function" then
        return
    end
    if US.IsEnabled() ~= true then
        return
    end
    local targets = GetUpgradeTargets()
    local SM = StockPiler3.SeedMap
    for i = 1, #targets do
        local t = targets[i]
        if type(t.ladder) == "table" then
            local climbCap = US.ClimbCap(t.needReq)
            local owned = US.PickBestOwnedSeed({
                ladder = t.ladder,
                climbCap = climbCap,
            })
            local ownedReq = type(owned) == "table" and (tonumber(owned.skillReq) or 0) or 0
            local refineCap = US.FloorCultTier(US.GetCultSkill())
            if refineCap < climbCap then
                refineCap = climbCap
            end
            local up = US.ScanUpgradePlant({
                ladder = t.ladder,
                climbCap = refineCap,
                ownedSeedReq = ownedReq,
            })
            if type(up) == "table" and (tonumber(up.plantUid) or 0) > 0 then
                local seedUid = tonumber(up.seedUid) or 0
                local plantUid = tonumber(up.plantUid) or 0
                if seedUid <= 0 and SM and SM.ResolveSeedUidForPlant then
                    seedUid = tonumber(SM.ResolveSeedUidForPlant(plantUid, nil)) or 0
                end
                local budget = SeedBudget(seedUid)
                local Items = StockPiler3.Items
                local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
                local Refine = StockPiler3.Refine
                local refinable = tonumber(up.refinable) or 0
                if refinable < 1 and Refine and Refine.CountRefinablePlants then
                    refinable = tonumber(Refine.CountRefinablePlants(plantUid, spec)) or 0
                end
                local uses = math.min(refinable, 5)
                if uses >= 1 then
                    appendFn({
                        spec = spec,
                        seedUid = seedUid,
                        plantUid = plantUid,
                        specKey = "upgrade_seed:" .. tostring(seedUid),
                    }, "upgrade-seed", uses, budget)
                    return
                end
            end
            -- Buffer refine for owned climb seed (only after plots clear for this seed).
            if type(owned) == "table" and (tonumber(owned.seedUid) or 0) > 0 then
                local seedUid = tonumber(owned.seedUid) or 0
                local plantUid = tonumber(owned.plantUid) or 0
                local Refine = StockPiler3.Refine
                local settleDeferred = false
                if Refine and Refine.SeedBufferSettleDeferred then
                    settleDeferred = Refine.SeedBufferSettleDeferred(seedUid) == true
                else
                    local Grow = StockPiler3.Grow
                    if Grow and Grow.CountSeedPlotCredit then
                        settleDeferred = (tonumber(Grow.CountSeedPlotCredit(seedUid)) or 0) > 0
                    end
                end
                local budget = SeedBudget(seedUid)
                local headroom = tonumber(budget.headroom) or 0
                if headroom > 0 and plantUid > 0 and settleDeferred ~= true then
                    local Items = StockPiler3.Items
                    local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
                    local refinable = 0
                    if Refine and Refine.CountRefinablePlants then
                        refinable = tonumber(Refine.CountRefinablePlants(plantUid, spec)) or 0
                    end
                    local uses = math.min(refinable, headroom, 5)
                    if uses >= 1 then
                        appendFn({
                            spec = spec,
                            seedUid = seedUid,
                            plantUid = plantUid,
                            specKey = "upgrade_seed:" .. tostring(seedUid),
                        }, "upgrade-seed-buffer", uses, budget)
                        return
                    end
                end
            end
        end
    end
end

function US.CollectBuyJobs()
    local jobs = {}
    if US.IsEnabled() ~= true then
        return jobs
    end
    local Watch = StockPiler3.Watch
    if not (Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true) then
        return jobs
    end
    local SM = StockPiler3.SeedMap
    local targets = GetUpgradeTargets()
    local seenBuy = {}
    for i = 1, #targets do
        local t = targets[i]
        if type(t.ladder) == "table" then
            -- L1 vendor seed only for cold-start / wiped vendor rung.
            -- Owning mid/high seeds (Spumepetal@150+) must not trigger L1 top-up:
            -- SeedDeficit(L1) only counts that uid's live stack, so buffer=5 with
            -- live(L1)=0 bought 5x 84235 while L150/L175 seeds were already owned.
            local buy = SM.LowestBuySeedOnLadder and SM.LowestBuySeedOnLadder(t.ladder) or nil
            if type(buy) == "table" and (tonumber(buy.seedUid) or 0) > 0 then
                local seedUid = tonumber(buy.seedUid) or 0
                local buyReq = tonumber(buy.skillReq) or 1
                if buyReq < 1 then
                    buyReq = 1
                end
                local owned = US.PickBestOwnedSeed({
                    ladder = t.ladder,
                    climbCap = US.ClimbCap(t.needReq),
                })
                local ownedReq = type(owned) == "table" and (tonumber(owned.skillReq) or 0) or 0
                if ownedReq > buyReq then
                    -- Family already past vendor rung; climb via plant/refine only.
                elseif seenBuy[seedUid] ~= true then
                    local deficit = US.SeedDeficit(seedUid)
                    if deficit >= 1 then
                        seenBuy[seedUid] = true
                        local MS = StockPiler3.MaterialSpec
                        local Inv = StockPiler3.Inventory
                        local sample = Inv and Inv.GetSample and Inv.GetSample(seedUid)
                        local spec = nil
                        if MS and MS.FromItemData and type(sample) == "table" then
                            spec = MS.FromItemData(sample, tostring(t.ladder.role or "main"))
                        elseif MS and MS.FromUid then
                            spec = MS.FromUid(seedUid)
                        end
                        jobs[#jobs + 1] = {
                            uid = seedUid,
                            uniqueID = seedUid,
                            deficit = deficit,
                            upgradeSeed = true,
                            skillUp = true, -- allow growable purchase path
                            growable = true,
                            isGrowable = true,
                            role = tostring(t.ladder.role or "main"),
                            spec = spec or t.spec,
                            specKey = "upgrade_seed:" .. tostring(seedUid),
                            acquireKey = "upgrade_seed:" .. tostring(seedUid),
                            skillReq = buyReq,
                            familyKey = t.ladder.key,
                        }
                    end
                end
            end
            -- Never AutoBuy intermediate climb seeds (L25/L50/...) - vendor only sells L1.
            -- Progress those rungs via plant / crit / refine.
        end
    end
    return jobs
end

function US.MaybeNotifyStall()
    if US.IsEnabled() ~= true then
        US._stallLatch = nil
        return
    end
    local active = US._active
    if type(active) ~= "table" then
        US._stallLatch = nil
        return
    end
    local why = tostring(active.why or "")
    -- Progress: clear latch so a later real stall can warn once.
    if why == "planting" then
        US._stallLatch = nil
        return
    end
    -- Refining / waiting on plots: not a user-action stall. Keep any latch so
    -- need_buy <-> climbing <-> refining flicker cannot spam chat.
    if why == "refining" or why == "climbing" then
        return
    end
    local reason = why
    if reason == "" then
        reason = "need_buy"
    end
    if reason == "need_buy" then
        local Watch = StockPiler3.Watch
        if not (Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true) then
            reason = "autobuy_off"
        else
            local VA = StockPiler3.VendorAdapter
            if VA and VA.IsStoreOpen and VA.IsStoreOpen() == true then
                -- Vendor open / AutoBuy can run - not a stall warn.
                return
            end
            reason = "need_vendor"
        end
    end
    -- One chat warn per stall episode (any reason). Reason flips must not re-fire.
    if US._stallLatch ~= nil then
        return
    end
    US._stallLatch = reason
    local genus = tostring(active.genus or "seed")
    local haveReq = tonumber(active.haveReq) or 0
    local needReq = tonumber(active.needReq) or 0
    local msg
    if StockPiler3.T then
        msg = StockPiler3.T("upgrade.stall." .. reason, {
            genus = genus,
            have = haveReq,
            need = needReq,
            cult = tonumber(active.needCult) or needReq,
        })
    else
        msg = L"<icon02486> Upgrade seed stalled."
    end
    if StockPiler3.Debug and StockPiler3.Debug.Notify then
        StockPiler3.Debug.Notify(msg)
    elseif StockPiler3.Debug and StockPiler3.Debug.Print then
        StockPiler3.Debug.Print(msg)
    end
    if type(PlaySound) == "function" and GameData and GameData.Sound
        and GameData.Sound.RESPAWN ~= nil
    then
        pcall(PlaySound, GameData.Sound.RESPAWN)
    elseif type(PlaySound) == "function" then
        pcall(PlaySound, 216)
    end
end

function US.GetActiveStatus()
    return US._active
end

--- Best owned seed/plant skillReq on a ladder at or below climbCap.
--- Counts bag and in-ground seeds (plot credit) so status matches seed-buffer plant.
local function BestOwnedReqOnLadder(ladder, climbCap)
    climbCap = tonumber(climbCap) or 0
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" or climbCap < 1 then
        return 0
    end
    local Inv = StockPiler3.Inventory
    if not (Inv and Inv.CountByUid) then
        return 0
    end
    local Grow = StockPiler3.Grow
    local best = 0
    for i = 1, #ladder.rungs do
        local rung = ladder.rungs[i]
        local req = tonumber(rung.skillReq) or 0
        if req >= 1 and req <= climbCap then
            local seedUid = tonumber(rung.seedUid) or 0
            local plantUid = tonumber(rung.plantUid) or 0
            local have = false
            if seedUid > 0 and (tonumber(Inv.CountByUid(seedUid)) or 0) >= 1 then
                have = true
            elseif plantUid > 0 and (tonumber(Inv.CountByUid(plantUid)) or 0) >= 1 then
                have = true
            elseif seedUid > 0 and Grow then
                local ground = 0
                if Grow.CountSeedPlotCredit then
                    ground = tonumber(Grow.CountSeedPlotCredit(seedUid)) or 0
                elseif Grow.CountInGroundSeeds then
                    ground = tonumber(Grow.CountInGroundSeeds(seedUid)) or 0
                end
                if ground >= 1 then
                    have = true
                end
            end
            if have and req > best then
                best = req
            end
        end
    end
    return best
end

local function RebuildWatchStatusCache()
    local frame = tonumber(StockPiler3.FrameCounter) or 0
    if US._statusCacheFrame == frame and type(US._statusByPlant) == "table" then
        return
    end
    US._statusCacheFrame = frame
    US._statusByPlant = {}
    US._statusByGenus = {}
    if US.IsEnabled() ~= true then
        US._active = nil
        return
    end
    local targets = GetUpgradeTargets()
    if #targets < 1 then
        -- Climb done / no targets: always clear latch. Keeping planting/refining
        -- here made ApplySeedBufferStatus re-paint upgrading_seed via GetActiveStatus.
        US._active = nil
        return
    end
    for i = 1, #targets do
        local t = targets[i]
        local needReq = tonumber(t.needReq) or 0
        local climbCap = US.ClimbCap(needReq)
        local haveReq = BestOwnedReqOnLadder(t.ladder, climbCap)
        -- Target rung already owned in bag or plots: not an upgrade climb.
        if haveReq >= needReq and needReq >= 1 then
            -- Seed-buffer / restock paths own the row status.
        else
            local why = "climbing"
            if haveReq < 1 then
                why = "need_buy"
            elseif climbCap < needReq and haveReq >= climbCap then
                why = "need_cult"
            end
            local genus = t.ladder and t.ladder.genus or nil
            local st = {
                familyKey = t.familyKey or (t.ladder and t.ladder.key),
                genus = genus,
                haveReq = haveReq,
                needReq = needReq,
                climbCap = climbCap,
                why = why,
                plantUid = tonumber(t.plantUid) or 0,
                seedUid = tonumber(t.seedUid) or 0,
            }
            local plantUid = tonumber(t.plantUid) or 0
            if plantUid > 0 then
                US._statusByPlant[plantUid] = st
            end
            if genus and genus ~= "" then
                US._statusByGenus[genus] = st
            end
            -- Keep _active filled so stalls / dumps reflect the climb even when
            -- Grow planted via plant_stock rather than upgrade_seed.
            if i == 1 then
                local curWhy = type(US._active) == "table" and tostring(US._active.why or "") or ""
                if curWhy ~= "planting" and curWhy ~= "refining" then
                    US._active = st
                end
            end
        end
    end
end

--- Merge live PickPlantJob/_active action onto a status snapshot for tips.
local function WithLiveActive(st)
    if type(st) ~= "table" then
        return st
    end
    local active = US._active
    if type(active) ~= "table" then
        return st
    end
    local sameGenus = tostring(active.genus or "") ~= ""
        and tostring(active.genus) == tostring(st.genus or "")
    local sameFamily = tostring(active.familyKey or "") ~= ""
        and tostring(active.familyKey) == tostring(st.familyKey or "")
    if not sameGenus and not sameFamily then
        return st
    end
    local why = tostring(active.why or "")
    if why ~= "planting" and why ~= "refining" and why ~= "need_buy"
        and why ~= "need_cult" and why ~= "climbing" and why ~= "no_family"
    then
        return st
    end
    return {
        familyKey = st.familyKey or active.familyKey,
        genus = st.genus or active.genus,
        haveReq = tonumber(active.haveReq) or tonumber(st.haveReq) or 0,
        needReq = tonumber(st.needReq) or tonumber(active.needReq) or 0,
        climbCap = tonumber(st.climbCap) or tonumber(active.climbCap) or 0,
        why = why,
        plantUid = tonumber(active.plantUid) or tonumber(st.plantUid) or 0,
        seedUid = tonumber(active.seedUid) or 0,
        live = true,
    }
end

--- UI: climb status for a plant watch (or genus), or nil if not climbing.
function US.StatusForPlant(plantUid, spec)
    if US.IsEnabled() ~= true then
        return nil
    end
    RebuildWatchStatusCache()
    plantUid = tonumber(plantUid) or 0
    if plantUid > 0 and type(US._statusByPlant[plantUid]) == "table" then
        return WithLiveActive(US._statusByPlant[plantUid])
    end
    local SM = StockPiler3.SeedMap
    local genus = nil
    if type(spec) == "table" and SM and SM.GenusKeyFromName then
        genus = SM.GenusKeyFromName(spec.name)
        if (not genus or genus == "") and SM.GetGenusLadderForSpec then
            local ladder = SM.GetGenusLadderForSpec(spec)
            genus = ladder and ladder.genus
        end
    end
    if genus and genus ~= "" and type(US._statusByGenus[genus]) == "table" then
        return WithLiveActive(US._statusByGenus[genus])
    end
    return nil
end

--- UI: climb status for potion seed-buffer rows.
--- Prefer the live active genus so the tip matches what AutoGrow is doing.
function US.StatusForWatch()
    if US.IsEnabled() ~= true then
        return nil
    end
    RebuildWatchStatusCache()
    local active = US._active
    if type(active) == "table" then
        local genus = tostring(active.genus or "")
        if genus ~= "" and type(US._statusByGenus) == "table"
            and type(US._statusByGenus[genus]) == "table"
        then
            return WithLiveActive(US._statusByGenus[genus])
        end
        local why = tostring(active.why or "")
        if why == "planting" or why == "refining" or why == "need_buy"
            or why == "need_cult" or why == "climbing"
        then
            return WithLiveActive({
                familyKey = active.familyKey,
                genus = active.genus,
                haveReq = tonumber(active.haveReq) or 0,
                needReq = tonumber(active.needReq) or 0,
                climbCap = tonumber(active.climbCap) or 0,
                why = why,
                plantUid = tonumber(active.plantUid) or 0,
                seedUid = tonumber(active.seedUid) or 0,
            })
        end
    end
    if type(US._statusByGenus) == "table" then
        for _, st in pairs(US._statusByGenus) do
            if type(st) == "table" then
                return WithLiveActive(st)
            end
        end
    end
    return nil
end

--- All live climb statuses (one per genus), for multi-family tips.
function US.ListClimbStatuses()
    if US.IsEnabled() ~= true then
        return {}
    end
    RebuildWatchStatusCache()
    local out = {}
    local seen = {}
    if type(US._statusByGenus) == "table" then
        for genus, st in pairs(US._statusByGenus) do
            if type(st) == "table" and seen[tostring(genus)] ~= true then
                seen[tostring(genus)] = true
                out[#out + 1] = WithLiveActive(st)
            end
        end
    end
    table.sort(out, function(a, b)
        local ga = tostring(a and a.genus or "")
        local gb = tostring(b and b.genus or "")
        if ga ~= gb then
            return ga < gb
        end
        return (tonumber(a and a.needReq) or 0) < (tonumber(b and b.needReq) or 0)
    end)
    return out
end

local function ClimbCapShow(climb)
    local needReq = tonumber(climb and climb.needReq) or 0
    local climbCap = tonumber(climb and climb.climbCap) or 0
    if climbCap < 1 and US.ClimbCap then
        climbCap = US.ClimbCap(needReq) or needReq
    end
    local capShow = climbCap
    if needReq > 0 and needReq < capShow then
        capShow = needReq
    end
    return capShow, needReq, tonumber(climb and climb.haveReq) or 0
end

--- Short parenthetical for tip Have/Need notes (per recipe slot).
function US.FormatClimbSlotNote(climb)
    if type(climb) ~= "table" then
        return nil
    end
    local why = tostring(climb.why or "")
    if why ~= "planting" and why ~= "refining" and why ~= "need_buy"
        and why ~= "need_cult" and why ~= "climbing" and why ~= "no_family"
    then
        return nil
    end
    local genus = tostring(climb.genus or "seed")
    local capShow, needReq, haveReq = ClimbCapShow(climb)
    local T = function(key, tokens)
        return StockPiler3.Util.T(key, tokens)
    end
    if why == "planting" then
        return T("watch.note.climb_planting", {
            genus = genus,
            have = tostring(haveReq),
        })
    end
    if why == "refining" then
        return T("watch.note.climb_refining", {
            genus = genus,
            have = tostring(haveReq),
        })
    end
    if why == "need_buy" then
        return T("watch.note.climb_buy", { genus = genus })
    end
    if why == "need_cult" or (needReq > 0 and capShow > 0 and capShow < needReq) then
        return T("watch.note.climb_cult", {
            genus = genus,
            need = tostring(needReq),
            floor = tostring(capShow),
        })
    end
    return T("watch.note.climb_progress", {
        genus = genus,
        have = tostring(haveReq),
        cap = tostring(capShow),
    })
end

function US.Dump(emit)
    emit = emit or print
    emit("--- upgrade seed ---")
    emit("  enabled=" .. tostring(US.IsEnabled() == true))
    local cult = US.GetCultSkill()
    emit("  cultSkill=" .. tostring(cult)
        .. " cultFloor=" .. tostring(US.FloorCultTier(cult)))
    local targets = GetUpgradeTargets()
    emit("  targets=" .. tostring(#targets))
    for i = 1, math.min(5, #targets) do
        local t = targets[i]
        local rungN = (type(t.ladder) == "table" and type(t.ladder.rungs) == "table")
            and #t.ladder.rungs or 0
        emit(string.format(
            "  target[%d] genus=%s needReq=%s short=%s plant=%s seed=%s rungs=%s key=%s",
            i,
            tostring(t.ladder and t.ladder.genus),
            tostring(t.needReq),
            tostring(t.short),
            tostring(t.plantUid),
            tostring(t.seedUid),
            tostring(rungN),
            tostring(t.familyKey)
        ))
    end
    local active = US._active
    if type(active) == "table" then
        emit(string.format(
            "  active family=%s genus=%s have=%s need=%s why=%s",
            tostring(active.familyKey),
            tostring(active.genus),
            tostring(active.haveReq),
            tostring(active.needReq),
            tostring(active.why)
        ))
    else
        emit("  active=(none)")
    end
    local jobs = US.CollectBuyJobs() or {}
    emit("  buyJobs=" .. tostring(#jobs))
    for i = 1, #jobs do
        local j = jobs[i]
        emit(string.format(
            "  buy[%d] uid=%s deficit=%s skillReq=%s family=%s",
            i,
            tostring(j.uid),
            tostring(j.deficit),
            tostring(j.skillReq),
            tostring(j.familyKey)
        ))
    end
    emit("  emptyPlots=" .. tostring(CountEmptyPlots()))
    -- Merged genus ladders for climb targets (from CollectUpgradeTargets cache;
    -- BuildAllFamilyLadders is gen-cached so this stays cheap).
    for i = 1, math.min(5, #targets) do
        local t = targets[i]
        local ladder = t.ladder
        if type(ladder) == "table" and type(ladder.rungs) == "table" then
            local parts = {}
            for r = 1, #ladder.rungs do
                local rung = ladder.rungs[r]
                parts[#parts + 1] = string.format(
                    "%d:s%d/p%d",
                    tonumber(rung.skillReq) or 0,
                    tonumber(rung.seedUid) or 0,
                    tonumber(rung.plantUid) or 0
                )
            end
            emit(string.format(
                "  merged[%s] role=%s %s",
                tostring(ladder.genus or ladder.key),
                tostring(ladder.role),
                table.concat(parts, " ")
            ))
        end
    end
    local SM = StockPiler3.SeedMap
    if SM and SM.DumpFamilies then
        SM.DumpFamilies(emit)
    end
end
