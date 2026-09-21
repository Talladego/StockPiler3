----------------------------------------------------------------
-- StockPiler3 UpgradeSeed — watch-driven family climb
-- buy L1 → plant → crit harvest → refine → repeat toward watch skillReq.
-- Shared ladder helpers also used by SkillUp (mains-only, TargetMaxSkill cap).
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.UpgradeSeed = StockPiler3.UpgradeSeed or {}
local US = StockPiler3.UpgradeSeed

US._stallLatch = nil
US._active = nil -- last pick { familyKey, haveReq, needReq, why }

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
    local Watch = StockPiler3.Watch
    if Watch and Watch.BumpGen then
        Watch.BumpGen()
    end
    return true
end

function US.GetCultSkill()
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.GetCultSkill then
        return tonumber(Caps.GetCultSkill()) or 0
    end
    -- Legacy alias (some older Caps builds).
    if Caps and Caps.GetCultivationSkill then
        return tonumber(Caps.GetCultivationSkill()) or 0
    end
    return 0
end

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

local function SeedBudget(seedUid)
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

local function CountEmptyPlots()
    local Grow = StockPiler3.Grow
    if Grow and Grow.CountEmptyPlots then
        return tonumber(Grow.CountEmptyPlots()) or 0
    end
    return 0
end

function US.SeedDeficit(seedUid)
    seedUid = tonumber(seedUid) or 0
    local empty = CountEmptyPlots()
    local budget = SeedBudget(seedUid)
    local buffer = tonumber(budget.bufferMin) or 0
    local live = tonumber(budget.live) or 0
    -- Climb planting only uses surplus above the seed buffer, so AutoBuy must
    -- top up to (buffer + empty plots) or every harvest can wipe the rung.
    if buffer > 0 then
        return math.max(0, buffer + empty - live)
    end
    local headroom = tonumber(budget.headroom) or 0
    local needPlots = empty
    if live >= empty then
        needPlots = 0
    else
        needPlots = empty - live
    end
    return math.max(headroom, needPlots)
end

--- How many bag seeds of this uid may be planted without dipping the keep cushion.
--- L1 / cold-start: keep full seed buffer (vendor can restock).
--- Intermediate climb rungs: keep 0 — those seeds are not at the vendor; holding
--- even 1 seed with empty plots stalls the climb (seen: have=50, plantable=0).
local function PlantableSurplus(seedUid, bagSeeds, empty, opts)
    seedUid = tonumber(seedUid) or 0
    bagSeeds = tonumber(bagSeeds) or 0
    empty = tonumber(empty) or 0
    opts = type(opts) == "table" and opts or {}
    if bagSeeds < 1 or empty < 1 then
        return 0
    end
    local budget = SeedBudget(seedUid)
    local buffer = tonumber(budget.bufferMin) or 0
    if buffer <= 0 or opts.intermediate == true then
        return math.min(bagSeeds, empty)
    end
    local live = tonumber(budget.live) or bagSeeds
    local surplus = live - buffer
    if surplus < 1 then
        return 0
    end
    return math.min(bagSeeds, empty, surplus)
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

--- Have the target-tier seed/plant for this climb need?
--- Only the needReq rung counts — owned lower-tier seeds must not end the climb
--- (ResolveSeedForSpec prefers bag seeds and would falsely "arrive" at L25).
local function HaveTargetRung(ladder, needReq, plantUid, seedUid)
    needReq = tonumber(needReq) or 0
    local Inv = StockPiler3.Inventory
    if not Inv or not Inv.CountByUid then
        return false
    end
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0

    local function haveUid(uid)
        uid = tonumber(uid) or 0
        return uid > 0 and (tonumber(Inv.CountByUid(uid)) or 0) >= 1
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
        -- Prefer skill-matched plant→seed link; ResolveSeedForSpec prefers any
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

function US.NeedsRefineFirst()
    if US.IsEnabled() ~= true then
        return false
    end
    local targets = CollectUpgradeTargets()
    for i = 1, #targets do
        local t = targets[i]
        local climbCap = US.ClimbCap(t.needReq)
        if climbCap < t.needReq and climbCap < 1 then
            -- gated
        else
            local owned = US.PickBestOwnedSeed({
                ladder = t.ladder,
                climbCap = climbCap,
            })
            local ownedReq = type(owned) == "table" and (tonumber(owned.skillReq) or 0) or 0
            -- Prefer Cult-floor upgrades even above climbCap when plant is already in bags
            -- (same as SkillUp: refine lucky crits). Cap refine scan at FloorCultTier.
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
                US._active = {
                    familyKey = t.familyKey or (t.ladder and t.ladder.key),
                    haveReq = ownedReq,
                    needReq = t.needReq,
                    why = "refining",
                    genus = t.ladder and t.ladder.genus,
                }
                return true
            end
        end
    end
    return false
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
    local targets = CollectUpgradeTargets()
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
        if climbCap < needReq then
            -- Can still climb toward Cult floor; status notes remaining gap after owned max.
        end
        if type(t.ladder) ~= "table" or type(t.ladder.rungs) ~= "table" or #t.ladder.rungs == 0 then
            US._active = {
                familyKey = t.familyKey,
                haveReq = 0,
                needReq = needReq,
                why = "no_family",
                genus = SM and SM.GenusKeyFromName and SM.GenusKeyFromName(t.spec and t.spec.name),
            }
            -- try next target
        else
            local owned = US.PickBestOwnedSeed({
                ladder = t.ladder,
                climbCap = climbCap,
            })
            local ownedReq = type(owned) == "table" and (tonumber(owned.skillReq) or 0) or 0
            local refineCap = cultFloor
            if refineCap < climbCap then
                refineCap = climbCap
            end
            local up = US.ScanUpgradePlant({
                ladder = t.ladder,
                climbCap = refineCap,
                ownedSeedReq = ownedReq,
            })
            if type(up) == "table" then
                US._active = {
                    familyKey = t.ladder.key,
                    haveReq = ownedReq,
                    needReq = needReq,
                    why = "refining",
                    genus = t.ladder.genus,
                }
                if StockPiler3.Refine and StockPiler3.Refine.MarkRefineDue then
                    StockPiler3.Refine.MarkRefineDue("upgrade-seed")
                end
                return nil
            end
            if type(owned) == "table" and (tonumber(owned.seedUid) or 0) > 0 then
                local seedUid = tonumber(owned.seedUid) or 0
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
                local lowestReq = LadderLowestReq(t.ladder)
                local intermediate = ownedReq > lowestReq
                if buffer > 0 and headroom > 0 and refinable > 0
                    and (not intermediate or bagSeeds < 1)
                then
                    US._active = {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "refining",
                        genus = t.ladder.genus,
                    }
                    if StockPiler3.Refine and StockPiler3.Refine.MarkRefineDue then
                        StockPiler3.Refine.MarkRefineDue("upgrade-seed-buffer")
                    end
                    return nil
                end
                -- Intermediate: plant every bag seed into empty plots (no vendor restock).
                -- L1: never plant into full buffer.
                local plantable = PlantableSurplus(seedUid, bagSeeds, empty, {
                    intermediate = intermediate,
                })
                if plantable < 1 and empty > 0 and refinable > 0 then
                    -- Same-tier plants in bags, no plantable seeds: refine into seeds.
                    US._active = {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "refining",
                        genus = t.ladder.genus,
                    }
                    if StockPiler3.Refine and StockPiler3.Refine.MarkRefineDue then
                        StockPiler3.Refine.MarkRefineDue("upgrade-seed-reseed")
                    end
                    return nil
                end
                if plantable >= 1 then
                    US._active = {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "planting",
                        genus = t.ladder.genus,
                    }
                    US._stallLatch = nil
                    local Inv = StockPiler3.Inventory
                    local sample = Inv and Inv.GetSample and Inv.GetSample(seedUid)
                    return {
                        seedUid = seedUid,
                        plantUid = plantUid,
                        seed = sample or { uniqueID = seedUid },
                        seedHave = bagSeeds,
                        plantable = plantable,
                        deficit = plantable,
                        plantReason = "upgrade_seed",
                        pickMode = "upgrade_seed",
                        familyKey = t.ladder.key,
                        skillReq = ownedReq,
                        needReq = needReq,
                    }
                end
                -- Owned this rung but nothing plantable: wait on plots / Cult gate.
                -- Do not flag need_buy for intermediate seeds (not sold at vendor).
                if empty < 1 then
                    US._active = {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "climbing",
                        genus = t.ladder.genus,
                    }
                elseif climbCap < needReq and ownedReq >= climbCap then
                    US._active = {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "need_cult",
                        genus = t.ladder.genus,
                        needCult = needReq,
                    }
                elseif not intermediate and US.SeedDeficit(seedUid) >= 1 then
                    US._active = {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "need_buy",
                        genus = t.ladder.genus,
                    }
                else
                    US._active = {
                        familyKey = t.ladder.key,
                        haveReq = ownedReq,
                        needReq = needReq,
                        why = "climbing",
                        genus = t.ladder.genus,
                    }
                end
            elseif climbCap < needReq and ownedReq >= climbCap and ownedReq > 0 then
                US._active = {
                    familyKey = t.ladder.key,
                    haveReq = ownedReq,
                    needReq = needReq,
                    why = "need_cult",
                    genus = t.ladder.genus,
                    needCult = needReq,
                }
            else
                US._active = {
                    familyKey = t.ladder.key,
                    haveReq = ownedReq,
                    needReq = needReq,
                    why = "need_buy",
                    genus = t.ladder.genus,
                }
            end
        end
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
    local targets = CollectUpgradeTargets()
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
            -- Buffer refine for owned climb seed.
            if type(owned) == "table" and (tonumber(owned.seedUid) or 0) > 0 then
                local seedUid = tonumber(owned.seedUid) or 0
                local plantUid = tonumber(owned.plantUid) or 0
                local budget = SeedBudget(seedUid)
                local headroom = tonumber(budget.headroom) or 0
                if headroom > 0 and plantUid > 0 then
                    local Items = StockPiler3.Items
                    local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
                    local Refine = StockPiler3.Refine
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
    local targets = CollectUpgradeTargets()
    for i = 1, #targets do
        local t = targets[i]
        if type(t.ladder) == "table" then
            local climbCap = US.ClimbCap(t.needReq)
            local owned = US.PickBestOwnedSeed({
                ladder = t.ladder,
                climbCap = climbCap,
            })
            if type(owned) ~= "table" or (tonumber(owned.count) or 0) < 1 then
                local buy = SM.LowestBuySeedOnLadder and SM.LowestBuySeedOnLadder(t.ladder) or nil
                if type(buy) == "table" and (tonumber(buy.seedUid) or 0) > 0 then
                    local seedUid = tonumber(buy.seedUid) or 0
                    local deficit = US.SeedDeficit(seedUid)
                    if deficit < 1 then
                        deficit = math.max(1, CountEmptyPlots())
                        if deficit < 1 then
                            deficit = 1
                        end
                    end
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
                        skillReq = tonumber(buy.skillReq) or 0,
                        familyKey = t.ladder.key,
                    }
                    return jobs
                end
            end
            -- Never AutoBuy intermediate climb seeds (L25/L50/…) — vendor only sells L1.
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
    if why == "planting" or why == "refining" then
        US._stallLatch = nil
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
            if not (VA and VA.IsStoreOpen and VA.IsStoreOpen() == true) then
                reason = "need_vendor"
            end
        end
    end
    if US._stallLatch == reason then
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
    if StockPiler3.Debug and StockPiler3.Debug.Print then
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
local function BestOwnedReqOnLadder(ladder, climbCap)
    climbCap = tonumber(climbCap) or 0
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" or climbCap < 1 then
        return 0
    end
    local Inv = StockPiler3.Inventory
    if not (Inv and Inv.CountByUid) then
        return 0
    end
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
    local targets = CollectUpgradeTargets()
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

--- UI: climb status for a plant watch (or genus), or nil if not climbing.
function US.StatusForPlant(plantUid, spec)
    if US.IsEnabled() ~= true then
        return nil
    end
    RebuildWatchStatusCache()
    plantUid = tonumber(plantUid) or 0
    if plantUid > 0 and type(US._statusByPlant[plantUid]) == "table" then
        return US._statusByPlant[plantUid]
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
        return US._statusByGenus[genus]
    end
    return nil
end

--- UI: any climb status (first target), for potion seed-buffer rows.
function US.StatusForWatch()
    if US.IsEnabled() ~= true then
        return nil
    end
    RebuildWatchStatusCache()
    if type(US._statusByGenus) == "table" then
        for _, st in pairs(US._statusByGenus) do
            if type(st) == "table" then
                return st
            end
        end
    end
    return nil
end

function US.Dump(emit)
    emit = emit or print
    emit("--- upgrade seed ---")
    emit("  enabled=" .. tostring(US.IsEnabled() == true))
    local cult = US.GetCultSkill()
    emit("  cultSkill=" .. tostring(cult)
        .. " cultFloor=" .. tostring(US.FloorCultTier(cult)))
    local targets = CollectUpgradeTargets()
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
    local SM = StockPiler3.SeedMap
    if SM and SM.DumpFamilies then
        SM.DumpFamilies(emit)
    end
end
