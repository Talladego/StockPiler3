----------------------------------------------------------------
-- StockPiler3 Knowledge/SeedMap — single facade (observe / resolve / stats)
-- Learn/snapshot ONLY on harvest complete attempts.
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.SeedMap = StockPiler3.SeedMap or {}
local SM = StockPiler3.SeedMap

SM.REFINE_CONVERT_FAIL_COOLDOWN_SEC = 45
SM.REFINE_FAST_FAIL_SEC = 1.5
SM._refineConvertFailed = SM._refineConvertFailed or {}
SM._refineConvertFailedUntil = SM._refineConvertFailedUntil or {}
SM._pendingHarvest = nil
SM._pendingRefine = nil
SM._plotSeeds = SM._plotSeeds or {}
SM._harvestWatch = SM._harvestWatch or {}
SM._plantUidCache = SM._plantUidCache or {}
SM._plantUidCacheSnap = nil

-- Permanent purple (Eternal *) — never consumed.
local ETERNAL_SEED_UID = {
    [199801] = true, [199802] = true, [199803] = true, [199804] = true,
    [199805] = true, [199806] = true, [199809] = true, [199810] = true,
    [199811] = true, [199812] = true,
}
-- Charged purple (Exceptional *) — ~250 grows then spent.
local EXCEPTIONAL_SEED_UID = {
    [2018021] = true, [2018022] = true, [2018023] = true,
    [2018024] = true, [2018025] = true, [2018026] = true,
}
-- One-shot hybrid seeds (infertile for sustainable regrowth). waremu probe 2026-09-16.
local INFERTILE_SEED_UID = {
    [2017641] = true, [2017642] = true, [2017643] = true, [2017644] = true,
    [2017645] = true, [2017646] = true, [2017647] = true, [2017648] = true,
    [2017649] = true, [2017650] = true, [2017651] = true, [2017652] = true,
}

----------------------------------------------------------------
-- Helpers (callees first)
----------------------------------------------------------------

local function ToNarrow(text)
    return StockPiler3.Util.ToNarrow(text)
end

local function NowSec()
    return StockPiler3.Util and StockPiler3.Util.NowSec and StockPiler3.Util.NowSec() or 0
end

local function GrowsTable()
    return StockPiler3.Knowledge and StockPiler3.Knowledge.Grows and StockPiler3.Knowledge.Grows() or nil
end

local function RefinesTable()
    return StockPiler3.Knowledge and StockPiler3.Knowledge.Refines and StockPiler3.Knowledge.Refines() or nil
end

local function CultSeedType()
    return (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
end

local function CultSporeType()
    return (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
end

local function BagSample(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler3.Inventory and StockPiler3.Inventory.GetSample then
        local s = StockPiler3.Inventory.GetSample(uid)
        if type(s) == "table" then
            return s
        end
    end
    if StockPiler3.Items and StockPiler3.Items.AsItemData then
        return StockPiler3.Items.AsItemData(uid)
    end
    return nil
end

local function NormalizeGrowName(nameNarrow)
    local s = string.lower(nameNarrow or "")
    if StockPiler3.Items and StockPiler3.Items.StripEternalExceptionalBunchedPrefixes then
        s = StockPiler3.Items.StripEternalExceptionalBunchedPrefixes(s)
    else
        s = string.gsub(s, "^bunched%s+", "")
        s = string.gsub(s, "^eternal%s+", "")
        s = string.gsub(s, "^exceptional%s+", "")
    end
    s = string.gsub(s, "%s+seed%s+packet$", "")
    s = string.gsub(s, "%s+spore%s+packet$", "")
    s = string.gsub(s, "%s+bloodseed$", "")
    s = string.gsub(s, "bloodseed$", "")
    s = string.gsub(s, "%s+seed$", "")
    s = string.gsub(s, "%s+spore$", "")
    s = string.gsub(s, "seed$", "")
    s = string.gsub(s, "spore$", "")
    s = string.gsub(s, "%s+powder$", "")
    s = string.gsub(s, "%s+extract$", "")
    s = string.gsub(s, "%s+blood$", "")
    s = string.gsub(s, "%s+dust$", "")
    s = string.gsub(s, "%s+oil$", "")
    s = string.gsub(s, "%s+pulp$", "")
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function GrowNamesRelated(plantName, seedName)
    local a = NormalizeGrowName(ToNarrow(plantName))
    local b = NormalizeGrowName(ToNarrow(seedName))
    if a == "" or b == "" then
        return false
    end
    if a == b then
        return true
    end
    if string.gsub(a, " ", "") == string.gsub(b, " ", "") then
        return true
    end
    -- Genus token (last word) match for crit tiers.
    local ta = string.match(a, "([^%s]+)$") or a
    local tb = string.match(b, "([^%s]+)$") or b
    return ta ~= "" and ta == tb
end

local function SeedReplantTier(seedUid, nameHint)
    seedUid = tonumber(seedUid) or 0
    if seedUid > 0 and ETERNAL_SEED_UID[seedUid] then
        return 3
    end
    if seedUid > 0 and EXCEPTIONAL_SEED_UID[seedUid] then
        return 2
    end
    local n = string.lower(ToNarrow(nameHint))
    if n == "" then
        local data = BagSample(seedUid)
        n = string.lower(ToNarrow(data and data.name))
    end
    if string.find(n, "eternal", 1, true) then
        return 3
    end
    if string.find(n, "exceptional", 1, true) then
        return 2
    end
    return 1
end

local function IsBagSeedOrSporeItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local cult = tonumber(itemData.cultivationType) or 0
    if cult == CultSeedType() or cult == CultSporeType() then
        return true
    end
    local n = string.lower(ToNarrow(itemData.name))
    return string.find(n, "seed", 1, true) ~= nil or string.find(n, "spore", 1, true) ~= nil
end

local function IsSeedPacketItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local n = string.lower(ToNarrow(itemData.name))
    return string.find(n, "seed packet", 1, true) ~= nil
        or string.find(n, "spore packet", 1, true) ~= nil
end

local function LooksSpecialSquigBits(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local n = string.lower(ToNarrow(itemData.name))
    return string.find(n, "special squig", 1, true) ~= nil
        or string.find(n, "squig bits", 1, true) ~= nil
end

local function LooksButcher(nameNarrow)
    local n = string.lower(nameNarrow or "")
    return string.find(n, "tooth", 1, true)
        or string.find(n, "scale", 1, true)
        or string.find(n, "chitin", 1, true)
        or string.find(n, "zoic", 1, true)
        or string.find(n, "gore", 1, true)
        or string.find(n, "squig", 1, true)
        or string.find(n, "daemonic", 1, true)
        or string.find(n, "khornish", 1, true)
end

local function DescLooksInfertileSeed(description)
    local d = string.lower(ToNarrow(description))
    if d == "" then
        return false
    end
    return string.find(d, "infertile for sustainable regrowth", 1, true) ~= nil
        or string.find(d, "infertile", 1, true) ~= nil
end

local function LookupDescription(specOrItem)
    if type(specOrItem) ~= "table" then
        return ""
    end
    local desc = specOrItem.description or specOrItem.desc or specOrItem.descriptionNarrow
    if desc ~= nil and ToNarrow(desc) ~= "" then
        return desc
    end
    local uid = tonumber(specOrItem.uid) or tonumber(specOrItem.uniqueID) or tonumber(specOrItem.boundUid) or 0
    if uid > 0 and StockPiler3.Items and StockPiler3.Items.GetByUid then
        local row = StockPiler3.Items.GetByUid(uid)
        if type(row) == "table" then
            local rd = row.description or row.descriptionNarrow
            if rd ~= nil and ToNarrow(rd) ~= "" then
                return rd
            end
        end
    end
    if uid > 0 and type(GetDatabaseItemData) == "function" then
        local ok, data = pcall(GetDatabaseItemData, uid)
        if ok and type(data) == "table" and data.description ~= nil then
            return data.description
        end
    end
    return ""
end

local function TouchIfStructural(reason)
    if StockPiler3.Knowledge and StockPiler3.Knowledge.Touch then
        StockPiler3.Knowledge.Touch(reason or "seedmap")
    end
end

local function EnsureGrowBucket(seedUid)
    local grows = GrowsTable()
    if type(grows) ~= "table" then
        return nil
    end
    local key = tostring(seedUid)
    local bucket = grows[key]
    if type(bucket) ~= "table" then
        bucket = {
            seedUid = seedUid,
            products = {},
            plantAttempts = 0,
            harvestAttempts = 0,
            cultSkillHits = 0,
            specialMomentHits = 0,
            chatCriticalSuccess = 0,
            chatCriticalFailure = 0,
        }
        grows[key] = bucket
    end
    return bucket
end

local function EnsureRefineEntry(plantUid)
    local refines = RefinesTable()
    if type(refines) ~= "table" then
        return nil
    end
    local key = tostring(plantUid)
    local entry = refines[key]
    if type(entry) ~= "table" then
        entry = {
            plantUid = plantUid,
            refineAttempts = 0,
            seedUid = 0,
            seedOut = {},
        }
        refines[key] = entry
    end
    return entry
end

local function HasProvenSeedConvert(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return false
    end
    local entry = RefinesTable() and RefinesTable()[tostring(plantUid)]
    if type(entry) == "table" and type(entry.seedOut) == "table" then
        for _, row in pairs(entry.seedOut) do
            if type(row) == "table" and (tonumber(row.samples) or 0) > 0 then
                return true
            end
        end
    end
    local uids = SM.GetSeedUidsForPlant(plantUid)
    return type(uids) == "table" and #uids > 0
end

--- EFFECT id from a seed item (bag / learned / DB). Seeds parse as non-main unless hinted.
function SM.ResolveSeedEffectId(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    if SM.IsSeedPacketUid(seedUid) then
        return 0
    end
    local MS = StockPiler3.MaterialSpec
    local sample = BagSample(seedUid)
    if type(sample) == "table" and MS and MS.FromItemData then
        local spec = MS.FromItemData(sample, "main")
        local eid = type(spec) == "table" and tonumber(spec.effectId) or 0
        if eid > 0 then
            return eid
        end
    end
    local Items = StockPiler3.Items
    if Items and Items.GetByUid then
        local row = Items.GetByUid(seedUid)
        if type(row) == "table" then
            local eid = tonumber(row.effectId) or 0
            if eid <= 0 and type(row.bonuses) == "table" then
                eid = tonumber(row.bonuses[6]) or 0
            end
            if eid > 0 then
                return eid
            end
        end
    end
    if type(GetDatabaseItemData) == "function" and MS and MS.FromItemData then
        local ok, data = pcall(GetDatabaseItemData, seedUid)
        if ok and type(data) == "table" then
            local spec = MS.FromItemData(data, "main")
            local eid = type(spec) == "table" and tonumber(spec.effectId) or 0
            if eid > 0 then
                return eid
            end
        end
    end
    return 0
end

local function PlantLooksLikeByproduct(plantUid, plantData)
    plantUid = tonumber(plantUid) or 0
    if type(plantData) == "table" and SM.IsHarvestByproduct(plantData) then
        return true
    end
    if plantUid > 0 and StockPiler3.Items and StockPiler3.Items.GetByUid then
        local learned = StockPiler3.Items.GetByUid(plantUid)
        if type(learned) == "table" and SM.IsHarvestByproduct(learned) then
            return true
        end
    end
    return false
end

local function StampPlantEffectFromSeedLink(seedUid, plantUid, plantData)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    if seedUid <= 0 or plantUid <= 0 then
        return 0
    end
    if SM.IsSeedPacketUid(seedUid) or PlantLooksLikeByproduct(plantUid, plantData) then
        return 0
    end
    local effectId = SM.ResolveSeedEffectId(seedUid)
    if effectId <= 0 then
        return 0
    end
    if StockPiler3.Items and StockPiler3.Items.StampPlantEffectFromSeed then
        StockPiler3.Items.StampPlantEffectFromSeed(plantUid, effectId, plantData)
    end
    return effectId
end

local function RecordHarvestProduct(seedUid, plantUid, qty)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    if seedUid <= 0 or plantUid <= 0 then
        return false
    end
    local plantData = BagSample(plantUid)
    local seedData = BagSample(seedUid)
    -- Relatedness filter: never learn unrelated products.
    if type(plantData) == "table" and type(seedData) == "table" then
        if not GrowNamesRelated(plantData.name, seedData.name) then
            return false
        end
    end
    -- Skip butcher substitutes as primary harvest products.
    if type(plantData) == "table" and LooksButcher(ToNarrow(plantData.name))
        and not GrowNamesRelated(plantData.name, seedData and seedData.name)
    then
        return false
    end
    local bucket = EnsureGrowBucket(seedUid)
    if type(bucket) ~= "table" then
        return false
    end
    local products = bucket.products
    if type(products) ~= "table" then
        products = {}
        bucket.products = products
    end
    local pk = tostring(plantUid)
    local row = products[pk]
    local isNew = type(row) ~= "table"
    if isNew then
        row = { uid = plantUid, samples = 0, qtySum = 0 }
        products[pk] = row
    end
    row.samples = (tonumber(row.samples) or 0) + 1
    row.qtySum = (tonumber(row.qtySum) or 0) + (tonumber(qty) or 1)
    -- Stamp plant EFFECT from seed (harvest + refine share this path).
    local stampedFx = StampPlantEffectFromSeedLink(seedUid, plantUid, plantData)
    if stampedFx > 0 then
        row.effectId = stampedFx
    end
    -- Infertile / special apo harvest products are never plant→seed refinable.
    local ME = StockPiler3.MaterialExceptions
    local markSpecial = SM.IsInfertileSeed(seedUid, seedData and seedData.name)
        or (ME and ME.LooksSpecialApoMain and type(plantData) == "table" and ME.LooksSpecialApoMain(plantData))
    if markSpecial and ME and ME.MarkForceNotRefinable then
        local reason = SM.IsInfertileSeed(seedUid) and "infertile-harvest" or "special-harvest"
        ME.MarkForceNotRefinable(plantUid, reason)
    end
    if markSpecial and StockPiler3.Items and StockPiler3.Items.StoreItem and type(plantData) == "table" then
        plantData.isRefinable = false
        StockPiler3.Items.StoreItem(plantData, "mat")
    end
    return isNew
end

----------------------------------------------------------------
-- Public: seed tiers / packets / relatedness
----------------------------------------------------------------

function SM.IsSeedPacketItem(itemData)
    return IsSeedPacketItem(itemData)
end

function SM.IsSeedPacketUid(uid)
    return IsSeedPacketItem(BagSample(uid))
end

function SM.IsBagSeedOrSpore(itemOrSpec)
    if type(itemOrSpec) ~= "table" then
        return false
    end
    if itemOrSpec.uniqueID or itemOrSpec.name then
        return IsBagSeedOrSporeItem(itemOrSpec)
    end
    local uid = tonumber(itemOrSpec.uid) or 0
    return IsBagSeedOrSporeItem(BagSample(uid))
end

function SM.GrowNamesRelated(plantName, seedName)
    return GrowNamesRelated(plantName, seedName)
end

function SM.SeedReplantTier(seedUid, nameHint)
    return SeedReplantTier(seedUid, nameHint)
end

function SM.IsEternalSeed(seedUid, nameHint)
    return SeedReplantTier(seedUid, nameHint) >= 3
end

function SM.IsExceptionalSeed(seedUid, nameHint)
    return SeedReplantTier(seedUid, nameHint) == 2
end

function SM.IsOpaqueReplantSeed(seedUid, nameHint)
    return SeedReplantTier(seedUid, nameHint) >= 2
end

--- One-shot hybrid seeds (infertile) — never Eternal/Exceptional opaque credit.
function SM.IsInfertileSeed(seedUid, nameHint)
    seedUid = tonumber(seedUid) or 0
    if seedUid > 0 and INFERTILE_SEED_UID[seedUid] then
        return true
    end
    local data = (seedUid > 0) and BagSample(seedUid) or nil
    local n = string.lower(ToNarrow(nameHint))
    if n == "" then
        n = string.lower(ToNarrow(data and data.name))
    end
    local desc = LookupDescription(data or { uid = seedUid, name = nameHint })
    if DescLooksInfertileSeed(desc) then
        return true
    end
    if string.find(n, "infertile", 1, true) then
        return true
    end
    return false
end

--- Eternal: full plot wave while owned; Exceptional: same while charges remain (~250).
--- Also covers the configured seed-buffer floor: with buffer=5 and 4 plots, returning
--- only `plots` left Eternal owners permanently stuck on Seed buffer (credit 4 < 5).
function SM.EffectiveSeedCredit(seedUid, bagCount)
    bagCount = tonumber(bagCount) or 0
    if bagCount <= 0 then
        return 0
    end
    if not SM.IsOpaqueReplantSeed(seedUid) then
        return bagCount
    end
    local plots = 4
    local CA = StockPiler3.CultivatorAdapter
    if CA and CA.NumPlots then
        plots = tonumber(CA.NumPlots()) or 4
    end
    if plots < 1 then
        plots = 4
    end
    local buffer = 5
    local Watch = StockPiler3.Watch
    if Watch and Watch.GetSeedBufferMin then
        buffer = tonumber(Watch.GetSeedBufferMin()) or 5
    end
    if buffer < 1 then
        buffer = 1
    end
    -- Owned opaque seed = infinite replant capacity for cushion math.
    return math.max(plots, buffer, bagCount)
end

function SM.GetSeedUidsForPlant(plantUid)
    plantUid = tonumber(plantUid) or 0
    local out = {}
    if plantUid <= 0 then
        return out
    end
    local seen = {}
    local grows = GrowsTable()
    if type(grows) == "table" then
        for seedKey, bucket in pairs(grows) do
            if type(bucket) == "table" and type(bucket.products) == "table" then
                local prod = bucket.products[tostring(plantUid)]
                if type(prod) == "table" then
                    local seedUid = tonumber(seedKey) or tonumber(bucket.seedUid) or 0
                    if seedUid > 0 and not seen[seedUid] and not SM.IsSeedPacketUid(seedUid) then
                        seen[seedUid] = true
                        out[#out + 1] = seedUid
                    end
                end
            end
        end
    end
    local entry = RefinesTable() and RefinesTable()[tostring(plantUid)]
    if type(entry) == "table" then
        local seedUid = tonumber(entry.seedUid) or 0
        if seedUid > 0 and not seen[seedUid] and not SM.IsSeedPacketUid(seedUid) then
            out[#out + 1] = seedUid
        end
    end
    return out
end

function SM.HarvestProducts(seedUid)
    seedUid = tonumber(seedUid) or 0
    local list = {}
    if seedUid <= 0 then
        return list
    end
    local bucket = GrowsTable() and GrowsTable()[tostring(seedUid)]
    if type(bucket) ~= "table" or type(bucket.products) ~= "table" then
        return list
    end
    for _, row in pairs(bucket.products) do
        if type(row) == "table" and (tonumber(row.uid) or 0) > 0 then
            list[#list + 1] = {
                uid = tonumber(row.uid),
                samples = tonumber(row.samples) or 0,
            }
        end
    end
    table.sort(list, function(a, b)
        return (a.samples or 0) > (b.samples or 0)
    end)
    return list
end

--- Cultivation linkage wins; PrimaryPlant never returns unrelated products.
function SM.PrimaryPlantForSeed(seedUid)
    seedUid = tonumber(seedUid) or 0
    local products = SM.HarvestProducts(seedUid)
    if #products == 0 then
        return 0
    end
    local seedData = BagSample(seedUid)
    local bestUid, bestSamples = 0, -1
    for i = 1, #products do
        local plantUid = tonumber(products[i].uid) or 0
        if plantUid > 0 then
            local plantData = BagSample(plantUid)
            local related = false
            if type(seedData) == "table" and type(plantData) == "table" then
                related = GrowNamesRelated(plantData.name, seedData.name)
            end
            -- Never mark cult mains not-growable solely because butcher filled ProductKey —
            -- skip butcher-looking unrelated products here.
            if related and not (LooksButcher(ToNarrow(plantData and plantData.name))
                and not GrowNamesRelated(plantData.name, seedData.name))
            then
                local samples = tonumber(products[i].samples) or 0
                if samples > bestSamples then
                    bestSamples = samples
                    bestUid = plantUid
                end
            end
        end
    end
    return bestUid
end

function SM.GetPlantUidForSeed(seedUid)
    return SM.PrimaryPlantForSeed(seedUid)
end

--- Prefer Eternal ≫ Exceptional ≫ blue; exclude Seed Packets.
function SM.PickBestSeedUid(plantUid, seedUids, _spec)
    plantUid = tonumber(plantUid) or 0
    local candidates = {}
    local seen = {}
    local function addUid(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 or seen[uid] or SM.IsSeedPacketUid(uid) then
            return
        end
        local item = BagSample(uid)
        if not IsBagSeedOrSporeItem(item) then
            return
        end
        if plantUid > 0 then
            local plantData = BagSample(plantUid)
            if type(plantData) == "table" and type(item) == "table" then
                if not GrowNamesRelated(plantData.name, item.name) then
                    return
                end
            end
        end
        seen[uid] = true
        candidates[#candidates + 1] = uid
    end

    if type(seedUids) == "table" then
        for i = 1, #seedUids do
            addUid(seedUids[i])
        end
    end
    if plantUid > 0 then
        local mapped = SM.GetSeedUidsForPlant(plantUid)
        for i = 1, #mapped do
            addUid(mapped[i])
        end
    end
    if StockPiler3.Inventory and StockPiler3.Inventory.ForEachItem then
        StockPiler3.Inventory.ForEachItem(function(item)
            if IsBagSeedOrSporeItem(item) then
                addUid(item.uniqueID)
            end
        end)
    end

    -- Prefer seeds actually in bags. Eternal/Exceptional with count 0 used to beat
    -- owned blue seeds (tier*100000), so buffer math tracked a UID you cannot plant.
    local bestUid, bestScore = 0, -1
    for i = 1, #candidates do
        local uid = candidates[i]
        local count = 0
        if StockPiler3.Inventory and StockPiler3.Inventory.CountByUid then
            count = tonumber(StockPiler3.Inventory.CountByUid(uid)) or 0
        end
        local ownedBoost = count > 0 and 1000000 or 0
        local score = ownedBoost + (SeedReplantTier(uid) * 100000) + count
        if score > bestScore then
            bestScore = score
            bestUid = uid
        end
    end
    return bestUid
end

--- Seed UID for buffer / refine / Apo plant-hold math.
--- Prefer the seed this plant refines into, then same skillReq as the plant.
--- Do NOT use PickBestSeedUid alone: that prefers Eternal L1 in bags and lets
--- Apo burn a rare higher-tier plant while counting L1 seeds as "buffer OK".
function SM.ResolveSeedUidForPlant(plantUid, plantSpec)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return 0
    end
    local plantReq = 0
    if type(plantSpec) == "table" then
        plantReq = tonumber(plantSpec.skillLevel) or tonumber(plantSpec.craftingSkillRequirement) or 0
    end
    if plantReq <= 0 then
        local plantData = BagSample(plantUid)
        if type(plantData) == "table" then
            plantReq = tonumber(plantData.craftingSkillRequirement) or tonumber(plantData.skillReq) or 0
            if plantReq <= 0 and type(plantData.bonuses) == "table" then
                plantReq = tonumber(plantData.bonuses[9]) or 0
            end
        end
    end
    if plantReq <= 0 and StockPiler3.Items and StockPiler3.Items.ToSpec then
        local spec = StockPiler3.Items.ToSpec(plantUid)
        plantReq = tonumber(spec and spec.skillLevel) or 0
    end

    local function seedSkillReq(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return 0
        end
        local item = BagSample(uid)
        if type(item) == "table" then
            local req = tonumber(item.craftingSkillRequirement) or tonumber(item.skillReq) or 0
            if req <= 0 and type(item.bonuses) == "table" then
                req = tonumber(item.bonuses[9]) or 0
            end
            if req > 0 then
                return req
            end
        end
        if StockPiler3.Items and StockPiler3.Items.GetByUid then
            local row = StockPiler3.Items.GetByUid(uid)
            if type(row) == "table" then
                local req = tonumber(row.craftingSkillRequirement) or tonumber(row.skillReq) or 0
                if req <= 0 and type(row.bonuses) == "table" then
                    req = tonumber(row.bonuses[9]) or 0
                end
                return req
            end
        end
        return 0
    end

    -- 1) Observed refine product → seed (exact ladder rung for this plant).
    local entry = RefinesTable() and RefinesTable()[tostring(plantUid)]
    local refineSeed = type(entry) == "table" and (tonumber(entry.seedUid) or 0) or 0
    if refineSeed > 0 and not SM.IsSeedPacketUid(refineSeed) then
        return refineSeed
    end

    -- 2) Among grow/refine-linked seeds, prefer matching plant skillReq.
    local linked = SM.GetSeedUidsForPlant(plantUid) or {}
    local matchUid, anyUid = 0, 0
    for i = 1, #linked do
        local uid = tonumber(linked[i]) or 0
        if uid > 0 and not SM.IsSeedPacketUid(uid) then
            if anyUid <= 0 then
                anyUid = uid
            end
            if plantReq > 0 and seedSkillReq(uid) == plantReq then
                matchUid = uid
                break
            end
        end
    end
    if matchUid > 0 then
        return matchUid
    end

    -- 3) Same-skillReq via PickBest among filtered list only.
    if plantReq > 0 and #linked > 0 then
        local same = {}
        for i = 1, #linked do
            local uid = tonumber(linked[i]) or 0
            if uid > 0 and seedSkillReq(uid) == plantReq then
                same[#same + 1] = uid
            end
        end
        if #same > 0 and SM.PickBestSeedUid then
            local best = tonumber(SM.PickBestSeedUid(plantUid, same, plantSpec)) or 0
            if best > 0 then
                return best
            end
            return same[1]
        end
    end

    if anyUid > 0 then
        return anyUid
    end
    if SM.PickBestSeedUid then
        return tonumber(SM.PickBestSeedUid(plantUid, linked, plantSpec)) or 0
    end
    return 0
end

function SM.IsOneWayHarvestSpec(spec)
    if type(spec) ~= "table" then
        return false
    end
    if StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.IsLinimentClass
        and StockPiler3.RecipeSpec.IsLinimentClass(spec)
    then
        return true
    end
    local ME = StockPiler3.MaterialExceptions
    if ME and ME.LooksSpecialApoMain and ME.LooksSpecialApoMain(spec) == true then
        return true
    end
    local name = spec.name
    local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or 0
    if (not name or name == "") and uid > 0 then
        local row = StockPiler3.Items and StockPiler3.Items.GetByUid and StockPiler3.Items.GetByUid(uid)
        name = row and row.name
    end
    local n = string.lower(ToNarrow(name))
    if string.find(n, "powder", 1, true) or string.find(n, "extract", 1, true)
        or string.find(n, "liniment", 1, true)
    then
        return true
    end
    if uid > 0 then
        local row = StockPiler3.Items and StockPiler3.Items.GetByUid and StockPiler3.Items.GetByUid(uid)
        if type(row) == "table" and row.isRefinable == false then
            local seeds = SM.GetSeedUidsForPlant(uid)
            -- Linked to grow but not refinable → one-way.
            if type(seeds) == "table" and #seeds > 0 then
                return true
            end
            -- Also: seed primary plant is this uid with no refine entry.
            local grows = GrowsTable()
            if type(grows) == "table" then
                for _, bucket in pairs(grows) do
                    if type(bucket) == "table" and type(bucket.products) == "table"
                        and type(bucket.products[tostring(uid)]) == "table"
                    then
                        local entry = RefinesTable() and RefinesTable()[tostring(uid)]
                        if type(entry) ~= "table" or (tonumber(entry.seedUid) or 0) <= 0 then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

--- True/false when known from spec or learned item; nil when never observed.
--- MaterialExceptions can force false when the engine lies (Squig Bits, etc.).
function SM.ResolveIsRefinable(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local ME = StockPiler3.MaterialExceptions
    if ME and ME.IsForceNotRefinable and ME.IsForceNotRefinable(spec) == true then
        return false
    end
    if spec.isRefinable ~= nil then
        return spec.isRefinable == true
    end
    local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
    if uid <= 0 then
        return nil
    end
    if ME and ME.IsForceNotRefinable and ME.IsForceNotRefinable(uid) == true then
        return false
    end
    if StockPiler3.Items and StockPiler3.Items.GetByUid then
        local learned = StockPiler3.Items.GetByUid(uid)
        if type(learned) == "table" then
            if ME and ME.IsForceNotRefinable and ME.IsForceNotRefinable(learned) == true then
                return false
            end
            if learned.isRefinable ~= nil then
                return learned.isRefinable == true
            end
        end
    end
    return nil
end

--- Byproduct stabilizer (Arboreal Resin etc.) — not planted / not butcher mains.
function SM.IsHarvestByproduct(spec)
    if type(spec) ~= "table" then
        return false
    end
    local role = tostring(spec.role or "")
    -- Recipe mains (armor chitin, scales, etc.) are never cultivation convert byproducts.
    if role == "main" or role == "container" then
        return false
    end
    local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
    local learned = nil
    if uid > 0 and StockPiler3.Items and StockPiler3.Items.GetByUid then
        learned = StockPiler3.Items.GetByUid(uid)
    end
    if type(learned) == "table" and tostring(learned.kind or "") == "resin" then
        return true
    end
    local n = string.lower(ToNarrow(spec.name))
    if n == "" and type(learned) == "table" then
        n = string.lower(ToNarrow(learned.name))
    end
    -- Resin / Arboreal only — do not treat chitin/scales or isRefinable==false as byproduct.
    if string.find(n, "resin", 1, true) or string.find(n, "arboreal", 1, true) then
        return true
    end
    return false
end

local function SpecLinkedToGrowOrRefine(spec)
    local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
    if uid <= 0 then
        return false
    end
    local seeds = SM.GetSeedUidsForPlant(uid)
    if type(seeds) == "table" and #seeds > 0 then
        return true
    end
    local entry = RefinesTable() and RefinesTable()[tostring(uid)]
    if type(entry) == "table" and (tonumber(entry.seedUid) or 0) > 0 then
        return true
    end
    local grows = GrowsTable()
    if type(grows) == "table" then
        for _, bucket in pairs(grows) do
            if type(bucket) == "table" and type(bucket.products) == "table"
                and type(bucket.products[tostring(uid)]) == "table"
            then
                return true
            end
        end
    end
    return false
end

local function SpecLooksButchering(spec)
    local n = string.lower(ToNarrow(spec and spec.name))
    if n == "" then
        local uid = tonumber(spec and spec.uid) or tonumber(spec and spec.uniqueID) or 0
        if uid > 0 and StockPiler3.Items and StockPiler3.Items.GetByUid then
            local row = StockPiler3.Items.GetByUid(uid)
            n = string.lower(ToNarrow(row and row.name))
        end
    end
    if n == "" then
        return false
    end
    return LooksButcher(n)
end

--- Goldweed-class stabilizer fingerprint: MULTIPLIER bonus present (SP2 SpecHasGoldweedMultiplier).
function SM.SpecHasGoldweedMultiplier(spec)
    if type(spec) ~= "table" or type(spec.bonuses) ~= "table" then
        return false
    end
    local B = StockPiler3.MaterialSpec and StockPiler3.MaterialSpec.CraftBonusRefs
        and StockPiler3.MaterialSpec.CraftBonusRefs()
    local ref = (B and B.MULTIPLIER) or 4
    local val = tonumber(spec.bonuses[ref]) or tonumber(spec.bonuses[tostring(ref)])
    return val ~= nil and val ~= 0
end

local function IsGrowProducerItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if IsBagSeedOrSporeItem(itemData) or IsSeedPacketItem(itemData) then
        return false
    end
    local n = string.lower(ToNarrow(itemData.name))
    if string.find(n, "resin", 1, true) or string.find(n, "arboreal", 1, true) then
        return false
    end
    if LooksButcher(n) and not string.find(n, "goldweed", 1, true)
        and not string.find(n, "gobswort", 1, true)
    then
        return false
    end
    return true
end

local function SpecProductCacheKey(spec)
    local MS = StockPiler3.MaterialSpec
    if not MS then
        return ""
    end
    if MS.ProductKey then
        local k = tostring(MS.ProductKey(spec) or "")
        if k ~= "" then
            return k
        end
    end
    if MS.Key then
        return tostring(MS.Key(spec) or "")
    end
    return ""
end

local function PlantUidCacheGen()
    local snap = 0
    if StockPiler3.Inventory and StockPiler3.Inventory.GetSnapGen then
        snap = tonumber(StockPiler3.Inventory.GetSnapGen()) or 0
    end
    local know = 0
    if StockPiler3.Knowledge and StockPiler3.Knowledge.GetGen then
        know = tonumber(StockPiler3.Knowledge.GetGen()) or 0
    end
    return tostring(snap) .. ":" .. tostring(know)
end

--- Cultivation main/extender/stimulant/goldweed growable; resin byproducts not.
--- Cultivation linkage (grows/refines) wins over butcher ProductMatches.
--- Explicit isRefinable==false blocks optimistic cult-role → plant (chitin/scales/etc.).
function SM.IsGrowableSpec(spec)
    if type(spec) ~= "table" then
        return false
    end
    local role = tostring(spec.role or "")
    if role == "container" then
        return false
    end
    if SM.IsHarvestByproduct(spec) then
        return false
    end
    if SpecLinkedToGrowOrRefine(spec) then
        return true
    end
    if SpecLooksButchering(spec) then
        return false
    end
    -- Unlinked hybrid/liniment specials: growable only when a related seed resolves
    -- (Eternal / infertile / Bloodseed). Dungeon drops (Primal / Daemonic) stay non-growable.
    local ME = StockPiler3.MaterialExceptions
    if ME and ME.LooksSpecialApoMain and ME.LooksSpecialApoMain(spec) == true then
        local seed = SM.ResolveSeedForSpec and SM.ResolveSeedForSpec(spec)
        local seedUid = type(seed) == "table"
            and (tonumber(seed.uniqueID) or tonumber(seed.uid) or 0) or 0
        return seedUid > 0
    end
    local refinable = SM.ResolveIsRefinable(spec)
    if refinable == false then
        return false
    end
    if refinable == true then
        return true
    end
    -- Unknown isRefinable: cult-role heuristic so unlearned fingerprints still AutoGrow.
    if role == "main" or role == "extender" or role == "multiplier"
        or role == "stimulant" or role == "goldweed"
    then
        return true
    end
    if role == "stabilizer" then
        -- Goldweed-class stabilizers are planted; resin handled above.
        if SM.SpecHasGoldweedMultiplier(spec) then
            return true
        end
        local n = string.lower(ToNarrow(spec.name))
        if string.find(n, "goldweed", 1, true) or string.find(n, "gobswort", 1, true) then
            return true
        end
    end
    return false
end

--- Resolve plant uid for fingerprint specs (no bound uid) via ProductMatches.
function SM.FindPlantUidForSpec(spec)
    if type(spec) ~= "table" then
        return 0
    end
    -- Resin / byproduct mats are never cultivable plants (even with bound uid).
    if SM.IsHarvestByproduct(spec) then
        return 0
    end
    -- Apo containers (vials/flasks) bind a uid but are never plants to refine/grow.
    if tostring(spec.role or "") == "container" then
        return 0
    end
    local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
    if uid > 0 then
        return uid
    end
    local MS = StockPiler3.MaterialSpec
    if not (MS and MS.ProductMatches) then
        return 0
    end
    local cacheKey = SpecProductCacheKey(spec)
    local gen = PlantUidCacheGen()
    if SM._plantUidCacheSnap ~= gen then
        SM._plantUidCache = {}
        SM._plantUidCacheSnap = gen
    end
    if cacheKey ~= "" and SM._plantUidCache[cacheKey] ~= nil then
        return tonumber(SM._plantUidCache[cacheKey]) or 0
    end

    local bestUid = 0
    local function considerItem(itemData, considerUid)
        considerUid = tonumber(considerUid) or 0
        if considerUid <= 0 or not IsGrowProducerItem(itemData) then
            return
        end
        if MS.ProductMatches(itemData, spec) == true then
            bestUid = considerUid
        end
    end

    -- 1) Live bags
    local Inv = StockPiler3.Inventory
    if Inv and Inv.ForEachItem then
        Inv.ForEachItem(function(item)
            if type(item) == "table" and bestUid <= 0 then
                considerItem(item, item.uniqueID or item.uniqueId or item.uid)
            end
        end)
    end

    -- 2) Learned Items store
    if bestUid <= 0 then
        local items = nil
        if StockPiler3.Account and type(StockPiler3.Account.items) == "table" then
            items = StockPiler3.Account.items
        elseif StockPiler3.Knowledge and StockPiler3.Knowledge.Items then
            items = StockPiler3.Knowledge.Items()
        end
        if type(items) == "table" then
            for uidKey, row in pairs(items) do
                if bestUid > 0 then
                    break
                end
                if type(row) == "table" then
                    local kind = tostring(row.kind or "")
                    if kind ~= "seed" and kind ~= "spore" and kind ~= "resin" then
                        local rowUid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
                        local asItem = nil
                        if StockPiler3.Items and StockPiler3.Items.AsItemData then
                            asItem = StockPiler3.Items.AsItemData(rowUid)
                        end
                        considerItem(asItem or row, rowUid)
                    end
                end
            end
        end
    end

    -- 3) Grows product tables
    if bestUid <= 0 then
        local grows = GrowsTable()
        if type(grows) == "table" then
            for _, bucket in pairs(grows) do
                if bestUid > 0 then
                    break
                end
                if type(bucket) == "table" and type(bucket.products) == "table" then
                    for plantKey, _ in pairs(bucket.products) do
                        if bestUid > 0 then
                            break
                        end
                        local plantUid = tonumber(plantKey) or 0
                        if plantUid > 0 then
                            local sample = BagSample(plantUid)
                            if type(sample) == "table" then
                                considerItem(sample, plantUid)
                            elseif StockPiler3.Items and StockPiler3.Items.AsItemData then
                                considerItem(StockPiler3.Items.AsItemData(plantUid), plantUid)
                            end
                        end
                    end
                end
            end
        end
    end

    if cacheKey ~= "" then
        SM._plantUidCache[cacheKey] = bestUid
    end
    return bestUid
end

local function SeedUidsFromGrowsMatchingSpec(spec)
    local out = {}
    local MS = StockPiler3.MaterialSpec
    if not (MS and MS.ProductMatches) then
        return out
    end
    local grows = GrowsTable()
    if type(grows) ~= "table" then
        return out
    end
    for seedKey, bucket in pairs(grows) do
        local seedUid = tonumber(seedKey) or (type(bucket) == "table" and tonumber(bucket.seedUid)) or 0
        if seedUid > 0 and type(bucket) == "table" and type(bucket.products) == "table" then
            for plantKey, _ in pairs(bucket.products) do
                local plantUid = tonumber(plantKey) or 0
                if plantUid > 0 then
                    local sample = BagSample(plantUid)
                    if type(sample) ~= "table" and StockPiler3.Items and StockPiler3.Items.AsItemData then
                        sample = StockPiler3.Items.AsItemData(plantUid)
                    end
                    if type(sample) == "table" and IsGrowProducerItem(sample)
                        and MS.ProductMatches(sample, spec) == true
                    then
                        out[#out + 1] = seedUid
                        break
                    end
                end
            end
        end
    end
    return out
end

--- Resolve best seed for a plant/spec. Uses grows/refines; falls back to bag name match.
function SM.ResolveSeedForSpec(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local plantUid = SM.FindPlantUidForSpec(spec)
    local seedUids = {}
    if plantUid > 0 then
        seedUids = SM.GetSeedUidsForPlant(plantUid) or {}
    end
    if (not seedUids or #seedUids == 0) then
        seedUids = SeedUidsFromGrowsMatchingSpec(spec)
        if plantUid <= 0 and #seedUids > 0 then
            -- Infer plant from first matching grow product.
            local grows = GrowsTable()
            local seedUid = seedUids[1]
            local bucket = type(grows) == "table" and grows[tostring(seedUid)]
            if type(bucket) == "table" and type(bucket.products) == "table" then
                local MS = StockPiler3.MaterialSpec
                for plantKey, _ in pairs(bucket.products) do
                    local pUid = tonumber(plantKey) or 0
                    local sample = BagSample(pUid)
                    if type(sample) ~= "table" and StockPiler3.Items and StockPiler3.Items.AsItemData then
                        sample = StockPiler3.Items.AsItemData(pUid)
                    end
                    if pUid > 0 and type(sample) == "table" and MS and MS.ProductMatches
                        and MS.ProductMatches(sample, spec) == true
                    then
                        plantUid = pUid
                        break
                    end
                end
            end
        end
    end
    local best = SM.PickBestSeedUid(plantUid, seedUids, spec)
    if best > 0 then
        return { uniqueID = best, uid = best, plantUid = plantUid }
    end
    if plantUid <= 0 then
        return nil
    end
    -- Empty grows: match bag seeds/spores by name relatedness to plant.
    local plantName = spec.name
    if (not plantName or plantName == "") and StockPiler3.Items and StockPiler3.Items.GetByUid then
        local row = StockPiler3.Items.GetByUid(plantUid)
        plantName = row and row.name
    end
    if (not plantName or plantName == "") and StockPiler3.Inventory and StockPiler3.Inventory.GetSample then
        local sample = StockPiler3.Inventory.GetSample(plantUid)
        plantName = sample and sample.name
    end
    local candidates = {}
    local Inv = StockPiler3.Inventory
    if Inv and Inv.ForEachItem then
        Inv.ForEachItem(function(item)
            if type(item) ~= "table" then
                return
            end
            if not SM.IsBagSeedOrSpore(item) then
                return
            end
            local seedUid = tonumber(item.uniqueID) or 0
            if seedUid <= 0 or SM.IsSeedPacketUid(seedUid) then
                return
            end
            if GrowNamesRelated(plantName, item.name) then
                candidates[#candidates + 1] = seedUid
            end
        end)
    end
    -- Learned Items store (seeds not currently in bags).
    if #candidates == 0 and StockPiler3.Items and StockPiler3.Items.GetByUid then
        local items = nil
        if StockPiler3.Account and type(StockPiler3.Account.items) == "table" then
            items = StockPiler3.Account.items
        elseif StockPiler3.Knowledge and StockPiler3.Knowledge.Items then
            items = StockPiler3.Knowledge.Items()
        end
        if type(items) == "table" then
            for uidKey, row in pairs(items) do
                if type(row) == "table" then
                    local kind = tostring(row.kind or "")
                    if kind == "seed" or kind == "spore" or IsBagSeedOrSporeItem(row) then
                        local seedUid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
                        if seedUid > 0 and not SM.IsSeedPacketUid(seedUid)
                            and GrowNamesRelated(plantName, row.name)
                        then
                            candidates[#candidates + 1] = seedUid
                        end
                    end
                end
            end
        end
    end
    best = SM.PickBestSeedUid(plantUid, candidates, spec)
    if best > 0 then
        return { uniqueID = best, uid = best, plantUid = plantUid }
    end
    return nil
end

----------------------------------------------------------------
-- Observe plant / refine / harvest (learn only on complete)
----------------------------------------------------------------

function SM.NotePlotSeed(plotNum, seedUid)
    plotNum = tonumber(plotNum) or 0
    seedUid = tonumber(seedUid) or 0
    if plotNum <= 0 or seedUid <= 0 then
        return
    end
    SM._plotSeeds[plotNum] = seedUid
end

function SM.ResolvePlotSeed(plotNum, liveSeed)
    liveSeed = tonumber(liveSeed) or 0
    if liveSeed > 0 then
        SM.NotePlotSeed(plotNum, liveSeed)
        return liveSeed
    end
    return tonumber(SM._plotSeeds[tonumber(plotNum) or 0]) or 0
end

function SM.ObservePlant(plotNum, seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return
    end
    SM.NotePlotSeed(plotNum, seedUid)
    local bucket = EnsureGrowBucket(seedUid)
    if type(bucket) == "table" then
        bucket.plantAttempts = (tonumber(bucket.plantAttempts) or 0) + 1
    end
end

function SM.RefreshHarvestWatch(plotNum, info)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return
    end
    local seedUid = 0
    if type(info) == "table" and type(info.Seed) == "table" then
        seedUid = tonumber(info.Seed.uniqueID) or 0
    end
    if seedUid <= 0 then
        seedUid = SM.ResolvePlotSeed(plotNum, 0)
    end
    if seedUid <= 0 then
        return
    end
    SM._harvestWatch[plotNum] = {
        seedUid = seedUid,
        armedAt = NowSec(),
    }
end

function SM.MarkHarvestLootDirty()
    if type(SM._pendingHarvest) == "table" then
        SM._pendingHarvest.lootDirty = true
    end
end

function SM.ShouldAttemptHarvestComplete(force)
    if type(SM._pendingHarvest) ~= "table" then
        return false
    end
    if force == true then
        return true
    end
    return SM._pendingHarvest.lootDirty == true
end

--- Arm pending harvest; actual learn runs in TryCompletePendingHarvest.
function SM.BeginPendingHarvest(plotNum, seedUid)
    plotNum = tonumber(plotNum) or 0
    seedUid = tonumber(seedUid) or SM.ResolvePlotSeed(plotNum, 0)
    if seedUid <= 0 then
        seedUid = tonumber(SM._harvestWatch[plotNum] and SM._harvestWatch[plotNum].seedUid) or 0
    end
    local chatFail = false
    local chatOk = false
    local CC = StockPiler3.CraftChatAdapter
    if CC and CC.ConsumeHarvestCriticalFailureSticky then
        chatFail = CC.ConsumeHarvestCriticalFailureSticky() == true
    end
    if CC and CC.ConsumeHarvestCriticalSuccessSticky then
        chatOk = CC.ConsumeHarvestCriticalSuccessSticky() == true
    end
    SM._pendingHarvest = {
        plotNum = plotNum,
        seedUid = seedUid,
        startedAt = NowSec(),
        before = {},
        lootDirty = false,
        chatCriticalFailure = chatFail,
        chatCriticalSuccess = chatOk,
    }
    -- Snapshot plant counts for delta (no learn yet).
    if StockPiler3.Inventory and StockPiler3.Inventory.ForEachItem then
        StockPiler3.Inventory.ForEachItem(function(item)
            local uid = tonumber(item.uniqueID) or 0
            if uid > 0 and not IsBagSeedOrSporeItem(item) then
                local stack = tonumber(item.stackCount) or tonumber(item.Count) or 1
                SM._pendingHarvest.before[uid] = (SM._pendingHarvest.before[uid] or 0) + stack
            end
        end)
    end
end

function SM.NoteCultSkillHit(seedUid, delta)
    seedUid = tonumber(seedUid) or 0
    delta = tonumber(delta) or 1
    if seedUid <= 0 or delta <= 0 then
        return false
    end
    local bucket = EnsureGrowBucket(seedUid)
    if type(bucket) ~= "table" then
        return false
    end
    bucket.cultSkillHits = (tonumber(bucket.cultSkillHits) or 0) + delta
    return true
end

--- Chat "Your creation failed." with an armed pending: close without learning bag trash.
function SM.CompletePendingHarvestAsCritFail()
    local pending = SM._pendingHarvest
    if type(pending) ~= "table" then
        return false
    end
    local seedUid = tonumber(pending.seedUid) or 0
    local plotNum = tonumber(pending.plotNum) or 0
    local bucket = seedUid > 0 and EnsureGrowBucket(seedUid) or nil
    if type(bucket) == "table" then
        bucket.harvestAttempts = (tonumber(bucket.harvestAttempts) or 0) + 1
        bucket.chatCriticalFailure = (tonumber(bucket.chatCriticalFailure) or 0) + 1
    end
    SM._pendingHarvest = nil
    if StockPiler3.Grow and StockPiler3.Grow.NotifyHarvestOutcome then
        StockPiler3.Grow.NotifyHarvestOutcome(plotNum, { critFail = true })
    end
    return true
end

function SM.TryCompletePendingHarvest(force)
    if not SM.ShouldAttemptHarvestComplete(force) then
        return false
    end
    local pending = SM._pendingHarvest
    if type(pending) ~= "table" then
        return false
    end
    -- Crafting chat said the harvest failed: do not learn any bag delta as a product.
    if pending.chatCriticalFailure == true then
        return SM.CompletePendingHarvestAsCritFail()
    end
    -- Snapshot / learn ONLY on complete attempt.
    local after = {}
    if StockPiler3.Inventory and StockPiler3.Inventory.ForEachItem then
        StockPiler3.Inventory.ForEachItem(function(item)
            local uid = tonumber(item.uniqueID) or 0
            if uid > 0 and not IsBagSeedOrSporeItem(item) then
                local stack = tonumber(item.stackCount) or tonumber(item.Count) or 1
                after[uid] = (after[uid] or 0) + stack
            end
        end)
    end
    local seedUid = tonumber(pending.seedUid) or 0
    local plotNum = tonumber(pending.plotNum) or 0
    local learned = false
    local structural = false
    local bestUid, bestDelta, bestName = 0, 0, nil
    local bucket = nil
    if seedUid > 0 then
        bucket = EnsureGrowBucket(seedUid)
        if type(bucket) == "table" then
            bucket.harvestAttempts = (tonumber(bucket.harvestAttempts) or 0) + 1
            if pending.chatCriticalSuccess == true then
                bucket.chatCriticalSuccess = (tonumber(bucket.chatCriticalSuccess) or 0) + 1
            end
        end
        for uid, count in pairs(after) do
            local prev = tonumber(pending.before[uid]) or 0
            local delta = count - prev
            if delta > 0 then
                local isNew = RecordHarvestProduct(seedUid, uid, delta)
                if isNew then
                    structural = true
                end
                learned = true
                local sample = BagSample(uid)
                if StockPiler3.Items and StockPiler3.Items.StoreItem then
                    if sample then
                        StockPiler3.Items.StoreItem(sample, "plant")
                    end
                end
                -- Prefer largest non-seed plant gain for harvest chat.
                if delta > bestDelta and sample and not IsBagSeedOrSporeItem(sample) then
                    local skip = SM.IsHarvestByproduct(sample) == true
                    if not skip then
                        bestDelta = delta
                        bestUid = uid
                        bestName = sample.name
                    end
                end
            end
        end
    end
    SM._pendingHarvest = nil
    if structural then
        TouchIfStructural("harvest")
    end
    if learned and bestUid > 0 and StockPiler3.Grow and StockPiler3.Grow.NotifyHarvestOutcome then
        StockPiler3.Grow.NotifyHarvestOutcome(plotNum, {
            name = bestName,
            count = bestDelta,
            uniqueID = bestUid,
        })
    end
    return learned
end

function SM.BeginPendingRefine(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local plantUid = tonumber(itemData.uniqueID) or 0
    if plantUid <= 0 then
        return false
    end
    if SM.IsRefineConvertFailed(plantUid) then
        return false
    end
    local expected = SM.GetSeedUidsForPlant(plantUid)
    local best = SM.PickBestSeedUid(plantUid, expected)
    SM._pendingRefine = {
        plantUid = plantUid,
        expectedSeedUid = best,
        startedAt = NowSec(),
        beforeSeed = best > 0 and (StockPiler3.Inventory and StockPiler3.Inventory.CountByUid(best) or 0) or 0,
    }
    return true
end

function SM.IsRefineConvertFailed(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return false
    end
    local untilT = tonumber(SM._refineConvertFailedUntil[uid]) or 0
    if untilT > 0 then
        if NowSec() < untilT then
            return true
        end
        SM._refineConvertFailedUntil[uid] = nil
    end
    if HasProvenSeedConvert(uid) then
        return false
    end
    if SM._refineConvertFailed[uid] == true then
        return true
    end
    local row = StockPiler3.Items and StockPiler3.Items.GetByUid and StockPiler3.Items.GetByUid(uid)
    return type(row) == "table" and row.refineConvertFailed == true
end

function SM.MarkRefineConvertFailed(plantUid, reason)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return
    end
    local item = BagSample(plantUid)
    -- Special Squig Bits-class: permanent block + exception registry.
    if LooksSpecialSquigBits(item) then
        SM._refineConvertFailed[plantUid] = true
        local ME = StockPiler3.MaterialExceptions
        if ME and ME.MarkForceNotRefinable then
            ME.MarkForceNotRefinable(plantUid, reason or "refine-fail-squig")
        end
        if StockPiler3.Items and StockPiler3.Items.GetByUid then
            local row = StockPiler3.Items.GetByUid(plantUid)
            if type(row) == "table" then
                row.refineConvertFailed = true
            elseif StockPiler3.Items.StoreItem and item then
                local stored = StockPiler3.Items.StoreItem(item, "mat")
                if type(stored) == "table" then
                    stored.refineConvertFailed = true
                end
            end
        end
        return
    end
    if HasProvenSeedConvert(plantUid) then
        -- Session cooldown only — not permanent blacklist.
        local sec = tonumber(SM.REFINE_CONVERT_FAIL_COOLDOWN_SEC) or 45
        SM._refineConvertFailedUntil[plantUid] = NowSec() + sec
        SM._refineConvertFailed[plantUid] = nil
        return
    end
    -- Unproven: session cooldown (not sticky SV) except squig class above.
    local sec = tonumber(SM.REFINE_CONVERT_FAIL_COOLDOWN_SEC) or 45
    SM._refineConvertFailedUntil[plantUid] = NowSec() + sec
end

function SM.ObserveRefineComplete(plantUid, seedUid, seedDelta)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    seedDelta = tonumber(seedDelta) or 0
    if plantUid <= 0 then
        return false
    end
    local entry = EnsureRefineEntry(plantUid)
    if type(entry) ~= "table" then
        return false
    end
    entry.refineAttempts = (tonumber(entry.refineAttempts) or 0) + 1
    local structural = false
    if seedUid > 0 and seedDelta > 0 then
        if (tonumber(entry.seedUid) or 0) ~= seedUid then
            entry.seedUid = seedUid
            structural = true
        end
        local so = entry.seedOut
        if type(so) ~= "table" then
            so = {}
            entry.seedOut = so
        end
        local row = so[tostring(seedUid)]
        if type(row) ~= "table" then
            row = { samples = 0, qtySum = 0 }
            so[tostring(seedUid)] = row
            structural = true
        end
        row.samples = (tonumber(row.samples) or 0) + 1
        row.qtySum = (tonumber(row.qtySum) or 0) + seedDelta
        -- Link grow products via cultivation path (not butcher ProductMatches).
        RecordHarvestProduct(seedUid, plantUid, 1)
    end
    if structural then
        TouchIfStructural("refine")
    end
    return true
end

function SM.TryCompletePendingRefine()
    local pending = SM._pendingRefine
    if type(pending) ~= "table" then
        return false
    end
    local elapsed = NowSec() - (tonumber(pending.startedAt) or 0)
    local plantUid = tonumber(pending.plantUid) or 0
    local seedUid = tonumber(pending.expectedSeedUid) or 0
    local after = 0
    if seedUid > 0 and StockPiler3.Inventory and StockPiler3.Inventory.CountByUid then
        after = StockPiler3.Inventory.CountByUid(seedUid)
    end
    local delta = after - (tonumber(pending.beforeSeed) or 0)
    if delta > 0 then
        SM.ObserveRefineComplete(plantUid, seedUid, delta)
        SM._pendingRefine = nil
        return true
    end
    -- Fast-fail ~1.5s with no convert.
    if elapsed >= (tonumber(SM.REFINE_FAST_FAIL_SEC) or 1.5) then
        SM.MarkRefineConvertFailed(plantUid, "fast-fail")
        local entry = EnsureRefineEntry(plantUid)
        if type(entry) == "table" then
            entry.refineAttempts = (tonumber(entry.refineAttempts) or 0) + 1
        end
        SM._pendingRefine = nil
        return false
    end
    return false
end

function SM.ItemLooksLikeRefinablePlant(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if IsBagSeedOrSporeItem(itemData) or IsSeedPacketItem(itemData) then
        return false
    end
    local ME = StockPiler3.MaterialExceptions
    if ME and ME.IsForceNotRefinable and ME.IsForceNotRefinable(itemData) == true then
        return false
    end
    -- Apo containers share cult=0 + craftingBonus with some plants; never refine them.
    local role = tostring(itemData.craftingRole or itemData.role or "")
    if role == "container" then
        return false
    end
    local cit = GameData and GameData.CraftingItemType
    if type(itemData.craftingBonus) == "table" and cit then
        for _, bonus in pairs(itemData.craftingBonus) do
            if type(bonus) == "table" then
                local ref = tonumber(bonus.bonusReference) or 0
                local val = tonumber(bonus.bonusValue) or 0
                if ref == 8 and (val == cit.CONTAINER or val == cit.CONTAINER_DYE) then
                    return false
                end
            end
        end
    end
    if itemData.isRefinable == true then
        return true
    end
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.uid) or 0
    if uid > 0 and StockPiler3.Items and StockPiler3.Items.GetByUid then
        local learned = StockPiler3.Items.GetByUid(uid)
        if type(learned) == "table" then
            if ME and ME.IsForceNotRefinable and ME.IsForceNotRefinable(learned) == true then
                return false
            end
            if tostring(learned.role or learned.craftingRole or "") == "container" then
                return false
            end
            if learned.isRefinable == true then
                return true
            end
        end
    end
    local n = string.lower(ToNarrow(itemData.name))
    if string.find(n, "goldweed", 1, true) or string.find(n, "gobswort", 1, true) then
        return true
    end
    local cult = tonumber(itemData.cultivationType) or 0
    return cult == 0 and type(itemData.craftingBonus) == "table"
end

----------------------------------------------------------------
-- Migrate: stamp plant effectId from known seed links
-- V1 one-shot; V2 retries plants still missing EFFECT (e.g. resist
-- families whose description patterns landed after V1).
----------------------------------------------------------------

function SM.MigratePlantEffectsFromSeeds()
    local acct = StockPiler3.Account
    if type(acct) ~= "table" then
        return 0
    end
    local forceRetry = acct.plantEffectFromSeedMigrateV2 ~= true
    if acct.plantEffectFromSeedMigrateV1 == true and not forceRetry then
        return 0
    end
    -- plantUid -> { seedUid, samples }
    local best = {}
    local grows = GrowsTable()
    if type(grows) == "table" then
        for seedKey, bucket in pairs(grows) do
            if type(bucket) == "table" and type(bucket.products) == "table" then
                local seedUid = tonumber(seedKey) or tonumber(bucket.seedUid) or 0
                if seedUid > 0 and not SM.IsSeedPacketUid(seedUid) then
                    for plantKey, prod in pairs(bucket.products) do
                        if type(prod) == "table" then
                            local plantUid = tonumber(plantKey) or tonumber(prod.uid) or 0
                            local samples = tonumber(prod.samples) or 0
                            if plantUid > 0 and samples > 0
                                and not PlantLooksLikeByproduct(plantUid, BagSample(plantUid))
                            then
                                local cur = best[plantUid]
                                if type(cur) ~= "table" or samples > (tonumber(cur.samples) or 0) then
                                    best[plantUid] = { seedUid = seedUid, samples = samples }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local refines = RefinesTable()
    if type(refines) == "table" then
        for plantKey, entry in pairs(refines) do
            if type(entry) == "table" then
                local plantUid = tonumber(plantKey) or tonumber(entry.plantUid) or 0
                local seedUid = tonumber(entry.seedUid) or 0
                if plantUid > 0 and seedUid > 0 and not SM.IsSeedPacketUid(seedUid)
                    and not PlantLooksLikeByproduct(plantUid, BagSample(plantUid))
                then
                    local samples = 0
                    if type(entry.seedOut) == "table" then
                        local so = entry.seedOut[tostring(seedUid)]
                        samples = type(so) == "table" and (tonumber(so.samples) or 0) or 0
                    end
                    local cur = best[plantUid]
                    if type(cur) ~= "table" or samples > (tonumber(cur.samples) or 0) then
                        -- Prefer grow-link when samples equal or higher; only fill missing.
                        if type(cur) ~= "table" then
                            best[plantUid] = { seedUid = seedUid, samples = samples }
                        elseif samples > (tonumber(cur.samples) or 0) then
                            best[plantUid] = { seedUid = seedUid, samples = samples }
                        end
                    end
                end
            end
        end
    end

    local changed = 0
    local Items = StockPiler3.Items
    for plantUid, info in pairs(best) do
        if type(info) == "table" then
            local seedUid = tonumber(info.seedUid) or 0
            local effectId = seedUid > 0 and SM.ResolveSeedEffectId(seedUid) or 0
            if effectId > 0 and Items and Items.StampPlantEffectFromSeed then
                local row = Items.GetByUid and Items.GetByUid(plantUid) or nil
                local existing = type(row) == "table" and tonumber(row.effectId) or 0
                if existing <= 0 and type(row) == "table" and type(row.bonuses) == "table" then
                    existing = tonumber(row.bonuses[6]) or 0
                end
                if existing <= 0 then
                    if Items.StampPlantEffectFromSeed(plantUid, effectId, BagSample(plantUid)) then
                        changed = changed + 1
                    end
                end
            end
        end
    end

    acct.plantEffectFromSeedMigrateV1 = true
    acct.plantEffectFromSeedMigrateV2 = true
    if changed > 0 and StockPiler3.Knowledge and StockPiler3.Knowledge.Touch then
        StockPiler3.Knowledge.Touch("plant-effect-seed")
    end
    return changed
end

----------------------------------------------------------------
-- Craft-cycle stats (/sp3 stats)
----------------------------------------------------------------

function SM.DumpCraftCycleStats(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler3.Debug and StockPiler3.Debug.Print then
            StockPiler3.Debug.Print(msg)
        end
    end
    emit("=== StockPiler3 craft-cycle stats ===")

    local grows = GrowsTable() or {}
    emit("--- grows (seed) ---")
    local growN = 0
    for seedKey, bucket in pairs(grows) do
        if type(bucket) == "table" then
            local plants = tonumber(bucket.plantAttempts) or 0
            local harvests = tonumber(bucket.harvestAttempts) or 0
            if plants > 0 or harvests > 0 then
                growN = growN + 1
                local cultHits = tonumber(bucket.cultSkillHits) or 0
                local cultPct = harvests > 0 and (cultHits / harvests * 100) or 0
                local sample = BagSample(tonumber(seedKey) or 0)
                emit(string.format(
                    "  %s uid=%s plant=%d harvest=%d cultSkillUp=%.0f%%",
                    tostring(ToNarrow(sample and sample.name) ~= "" and ToNarrow(sample.name) or seedKey),
                    tostring(seedKey),
                    plants,
                    harvests,
                    cultPct
                ))
            end
        end
    end
    if growN == 0 then
        emit("  (none)")
    end

    local SkillUp = StockPiler3.SkillUp
    if SkillUp and SkillUp.DumpRates then
        SkillUp.DumpRates(emit)
    end

    local refines = RefinesTable() or {}
    emit("--- refines (plant) ---")
    local refineN = 0
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            local attempts = tonumber(entry.refineAttempts) or 0
            if attempts > 0 then
                refineN = refineN + 1
                local sample = BagSample(tonumber(plantKey) or 0)
                emit(string.format(
                    "  %s uid=%s refineAttempts=%d seedUid=%d",
                    tostring(ToNarrow(sample and sample.name) ~= "" and ToNarrow(sample.name) or plantKey),
                    tostring(plantKey),
                    attempts,
                    tonumber(entry.seedUid) or 0
                ))
            end
        end
    end
    if refineN == 0 then
        emit("  (none)")
    end

    local recipes = StockPiler3.Knowledge and StockPiler3.Knowledge.Recipes and StockPiler3.Knowledge.Recipes() or {}
    emit("--- brew (recipe) ---")
    local brewN = 0
    for key, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            local attempts = tonumber(recipe.brewAttempts) or 0
            if attempts > 0 then
                brewN = brewN + 1
                local ok = tonumber(recipe.brewSuccesses) or 0
                local pct = attempts > 0 and (ok / attempts * 100) or 0
                emit(string.format(
                    "  key=%s attempts=%d success=%.0f%% yield=%.2f",
                    tostring(key):sub(1, 48),
                    attempts,
                    pct,
                    tonumber(recipe.recipeYield) or 0
                ))
            end
        end
    end
    if brewN == 0 then
        emit("  (none)")
    end
end

----------------------------------------------------------------
-- Family ladders (Upgrade Seed / SkillUp graduation)
----------------------------------------------------------------

local function ItemSkillReq(item)
    if type(item) ~= "table" then
        return 0
    end
    local req = tonumber(item.craftingSkillRequirement) or tonumber(item.skillReq) or 0
    if req <= 0 and type(item.bonuses) == "table" then
        req = tonumber(item.bonuses[9]) or 0
    end
    if req <= 0 then
        local Items = StockPiler3.Items
        local uid = tonumber(item.uniqueID) or tonumber(item.uid) or 0
        if uid > 0 and Items and Items.ToSpec then
            local spec = Items.ToSpec(uid)
            req = tonumber(spec and spec.skillLevel) or 0
        end
    end
    return req
end

--- Last-token genus after normalize (e.g. "majestic goldweed" → "goldweed").
function SM.GenusKeyFromName(name)
    local n = NormalizeGrowName(ToNarrow(name))
    if n == "" then
        return ""
    end
    return string.match(n, "([^%s]+)$") or n
end

function SM.FamilyKeyParts(genus, role, effectId)
    genus = string.lower(tostring(genus or ""))
    role = string.lower(tostring(role or "unknown"))
    if role == "" then
        role = "unknown"
    end
    effectId = tonumber(effectId) or 0
    if genus == "" then
        return nil
    end
    return genus .. "|" .. role .. "|" .. tostring(effectId), genus, role, effectId
end

function SM.FamilyKeyFromSpec(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local genus = SM.GenusKeyFromName(spec.name)
    if genus == "" then
        local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
        local sample = BagSample(uid)
        genus = SM.GenusKeyFromName(sample and sample.name)
    end
    local role = tostring(spec.role or "unknown")
    if role == "" then
        role = "unknown"
    end
    local effectId = tonumber(spec.effectId) or 0
    return SM.FamilyKeyParts(genus, role, effectId)
end

function SM.FamilyKeyFromUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    local Items = StockPiler3.Items
    local spec = Items and Items.ToSpec and Items.ToSpec(uid) or nil
    if type(spec) == "table" then
        local key = SM.FamilyKeyFromSpec(spec)
        if key then
            return key
        end
    end
    local sample = BagSample(uid)
    local genus = SM.GenusKeyFromName(sample and sample.name)
    return SM.FamilyKeyParts(genus, "unknown", 0)
end

local function EnsureRung(bucket, skillReq)
    skillReq = tonumber(skillReq) or 0
    if skillReq < 1 then
        return nil
    end
    local rungs = bucket.rungs
    for i = 1, #rungs do
        if rungs[i].skillReq == skillReq then
            return rungs[i]
        end
    end
    local rung = { skillReq = skillReq, seedUid = 0, plantUid = 0, name = "" }
    rungs[#rungs + 1] = rung
    return rung
end

local function SortRungs(rungs)
    table.sort(rungs, function(a, b)
        return (tonumber(a.skillReq) or 0) < (tonumber(b.skillReq) or 0)
    end)
end

local function NoteSeedPlant(families, seedUid, plantUid, skillReq, name, role, effectId)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    skillReq = tonumber(skillReq) or 0
    if skillReq < 1 then
        return
    end
    local genus = SM.GenusKeyFromName(name)
    if genus == "" and plantUid > 0 then
        local plantSample = BagSample(plantUid)
        genus = SM.GenusKeyFromName(plantSample and plantSample.name)
    end
    if genus == "" and seedUid > 0 then
        local seedSample = BagSample(seedUid)
        genus = SM.GenusKeyFromName(seedSample and seedSample.name)
    end
    local key, g, r, e = SM.FamilyKeyParts(genus, role, effectId)
    if not key then
        return
    end
    local bucket = families[key]
    if type(bucket) ~= "table" then
        bucket = { key = key, genus = g, role = r, effectId = e, rungs = {} }
        families[key] = bucket
    end
    local rung = EnsureRung(bucket, skillReq)
    if not rung then
        return
    end
    if seedUid > 0 then
        rung.seedUid = seedUid
    end
    if plantUid > 0 then
        rung.plantUid = plantUid
    end
    if name and name ~= "" and (rung.name == nil or rung.name == "") then
        rung.name = ToNarrow(name)
    end
end

--- Build all known family ladders from grows/refines/bags/account/vendor.
--- Returns map familyKey → { key, genus, role, effectId, rungs[] }.
function SM.BuildAllFamilyLadders()
    local families = {}
    local Items = StockPiler3.Items
    local MS = StockPiler3.MaterialSpec

    local function roleEffectForUid(uid)
        uid = tonumber(uid) or 0
        local role, effectId = "unknown", 0
        if uid > 0 and Items and Items.ToSpec then
            local spec = Items.ToSpec(uid)
            if type(spec) == "table" then
                role = tostring(spec.role or "unknown")
                effectId = tonumber(spec.effectId) or 0
            end
        end
        if (role == "" or role == "unknown") and uid > 0 and MS and MS.FromUid then
            local spec = MS.FromUid(uid)
            if type(spec) == "table" then
                if role == "unknown" or role == "" then
                    role = tostring(spec.role or "unknown")
                end
                if effectId <= 0 then
                    effectId = tonumber(spec.effectId) or 0
                end
            end
        end
        return role, effectId
    end

    local grows = GrowsTable()
    if type(grows) == "table" then
        for seedKey, bucket in pairs(grows) do
            local seedUid = tonumber(seedKey) or 0
            if seedUid > 0 and type(bucket) == "table" then
                local seedSample = BagSample(seedUid)
                local seedReq = ItemSkillReq(seedSample or {})
                if seedReq < 1 then
                    seedReq = ItemSkillReq(bucket)
                end
                if type(bucket.products) == "table" then
                    for plantKey, _ in pairs(bucket.products) do
                        local plantUid = tonumber(plantKey) or 0
                        local plantSample = BagSample(plantUid)
                        local plantReq = ItemSkillReq(plantSample or {})
                        local req = plantReq > 0 and plantReq or seedReq
                        local role, effectId = roleEffectForUid(plantUid > 0 and plantUid or seedUid)
                        local name = (plantSample and plantSample.name) or (seedSample and seedSample.name) or ""
                        NoteSeedPlant(families, seedUid, plantUid, req, name, role, effectId)
                    end
                elseif seedReq >= 1 then
                    local role, effectId = roleEffectForUid(seedUid)
                    NoteSeedPlant(families, seedUid, 0, seedReq, seedSample and seedSample.name, role, effectId)
                end
            end
        end
    end

    local refines = RefinesTable()
    if type(refines) == "table" then
        for plantKey, entry in pairs(refines) do
            if type(entry) == "table" then
                local plantUid = tonumber(plantKey) or 0
                local seedUid = tonumber(entry.seedUid) or 0
                local plantSample = BagSample(plantUid)
                local req = ItemSkillReq(plantSample or {})
                if req < 1 and seedUid > 0 then
                    req = ItemSkillReq(BagSample(seedUid) or {})
                end
                local role, effectId = roleEffectForUid(plantUid > 0 and plantUid or seedUid)
                NoteSeedPlant(families, seedUid, plantUid, req, plantSample and plantSample.name, role, effectId)
            end
        end
    end

    local function considerItem(item)
        if type(item) ~= "table" then
            return
        end
        local uid = tonumber(item.uniqueID) or tonumber(item.uid) or 0
        if uid <= 0 then
            return
        end
        if SM.IsSeedPacketUid and SM.IsSeedPacketUid(uid) then
            return
        end
        local req = ItemSkillReq(item)
        if req < 1 then
            return
        end
        if IsBagSeedOrSporeItem(item) then
            local plantUid = tonumber(SM.PrimaryPlantForSeed and SM.PrimaryPlantForSeed(uid)) or 0
            local role, effectId = roleEffectForUid(plantUid > 0 and plantUid or uid)
            NoteSeedPlant(families, uid, plantUid, req, item.name, role, effectId)
        elseif SM.ItemLooksLikeRefinablePlant and SM.ItemLooksLikeRefinablePlant(item) == true then
            local seedUid = 0
            if SM.ResolveSeedUidForPlant then
                seedUid = tonumber(SM.ResolveSeedUidForPlant(uid, nil)) or 0
            end
            local role, effectId = roleEffectForUid(uid)
            NoteSeedPlant(families, seedUid, uid, req, item.name, role, effectId)
        end
    end

    local Inv = StockPiler3.Inventory
    if Inv and Inv.ForEachItem then
        Inv.ForEachItem(considerItem)
    end

    local items = StockPiler3.Account and StockPiler3.Account.items
    if type(items) == "table" then
        for key, row in pairs(items) do
            if type(row) == "table" then
                if row.uniqueID == nil and tonumber(key) then
                    row = { uniqueID = tonumber(key), name = row.name, craftingSkillRequirement = row.craftingSkillRequirement }
                end
                considerItem(row)
            end
        end
    end

    local VA = StockPiler3.VendorAdapter
    if VA and VA.GetMatchIndex then
        local index = VA.GetMatchIndex()
        if type(index) == "table" and type(index.rows) == "table" then
            for i = 1, #index.rows do
                local row = index.rows[i]
                considerItem(row and row.item)
            end
        end
    end

    for _, bucket in pairs(families) do
        SortRungs(bucket.rungs)
    end
    return families
end

function SM.GetFamilyLadder(familyKey)
    familyKey = tostring(familyKey or "")
    if familyKey == "" then
        return nil
    end
    local all = SM.BuildAllFamilyLadders()
    return all[familyKey]
end

function SM.GetFamilyLadderForSpec(spec)
    local key = SM.FamilyKeyFromSpec(spec)
    if not key then
        return nil
    end
    return SM.GetFamilyLadder(key)
end

--- Merge all role/effect buckets that share a genus into one climb ladder.
--- Needed when L1 vendor seed is labeled ingredient and the watch plant is extender
--- (e.g. Gobswort Spore @1 vs Taut Gobswort @200).
function SM.GetGenusLadder(genus)
    genus = string.lower(tostring(genus or ""))
    if genus == "" then
        return nil
    end
    local all = SM.BuildAllFamilyLadders()
    local merged = nil
    local roles = {}
    for _, bucket in pairs(all) do
        if type(bucket) == "table" and tostring(bucket.genus or "") == genus then
            if type(merged) ~= "table" then
                merged = {
                    key = genus .. "|*|0",
                    genus = genus,
                    role = tostring(bucket.role or "unknown"),
                    effectId = tonumber(bucket.effectId) or 0,
                    rungs = {},
                    merged = true,
                }
            end
            local role = tostring(bucket.role or "")
            if role ~= "" and role ~= "unknown" then
                roles[role] = true
                -- Prefer a concrete cult role over "ingredient" for buy-path labeling.
                if merged.role == "unknown" or merged.role == "ingredient" then
                    merged.role = role
                end
            end
            if type(bucket.rungs) == "table" then
                for i = 1, #bucket.rungs do
                    local src = bucket.rungs[i]
                    local rung = EnsureRung(merged, tonumber(src.skillReq) or 0)
                    if rung then
                        local seedUid = tonumber(src.seedUid) or 0
                        local plantUid = tonumber(src.plantUid) or 0
                        if seedUid > 0 and (tonumber(rung.seedUid) or 0) <= 0 then
                            rung.seedUid = seedUid
                        end
                        if plantUid > 0 and (tonumber(rung.plantUid) or 0) <= 0 then
                            rung.plantUid = plantUid
                        end
                        if src.name and src.name ~= "" and (rung.name == nil or rung.name == "") then
                            rung.name = src.name
                        end
                    end
                end
            end
        end
    end
    if type(merged) ~= "table" then
        return nil
    end
    SortRungs(merged.rungs)
    if next(roles) ~= nil then
        -- Keep a stable preferred role for dump/status (extender/main/etc. over ingredient).
        local prefer = { "extender", "stabilizer", "multiplier", "stimulant", "main", "goldweed" }
        for i = 1, #prefer do
            if roles[prefer[i]] == true then
                merged.role = prefer[i]
                break
            end
        end
    end
    return merged
end

function SM.GetGenusLadderForSpec(spec)
    if type(spec) ~= "table" then
        return nil
    end
    local _, genus = SM.FamilyKeyFromSpec(spec)
    if not genus or genus == "" then
        genus = SM.GenusKeyFromName(spec.name)
    end
    if (not genus or genus == "") then
        local uid = tonumber(spec.uid) or tonumber(spec.uniqueID) or tonumber(spec.boundUid) or 0
        if uid > 0 then
            local sample = BagSample(uid)
            genus = SM.GenusKeyFromName(sample and sample.name)
        end
    end
    return SM.GetGenusLadder(genus)
end

--- Best owned (bag) seed on the ladder with skillReq <= climbCap.
--- Skips infertile climb seeds. Prefers highest skillReq then Eternal tier.
function SM.BestOwnedSeedOnLadder(ladder, climbCap, opts)
    opts = type(opts) == "table" and opts or {}
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" then
        return nil
    end
    climbCap = tonumber(climbCap) or 0
    if climbCap < 1 then
        return nil
    end
    local Inv = StockPiler3.Inventory
    local best = nil
    local bestScore = -1
    for i = 1, #ladder.rungs do
        local rung = ladder.rungs[i]
        local req = tonumber(rung.skillReq) or 0
        if req >= 1 and req <= climbCap then
            local seedUid = tonumber(rung.seedUid) or 0
            if seedUid > 0 and not (SM.IsInfertileSeed and SM.IsInfertileSeed(seedUid)) then
                local count = Inv and Inv.CountByUid and tonumber(Inv.CountByUid(seedUid)) or 0
                if count > 0 then
                    if opts.mainsOnly == true then
                        local role = tostring(ladder.role or "")
                        if role ~= "" and role ~= "main" and role ~= "unknown" then
                            count = 0
                        end
                    end
                end
                if count > 0 then
                    local tier = SeedReplantTier(seedUid)
                    local score = (req * 100000) + (tier * 1000) + count
                    if score > bestScore then
                        bestScore = score
                        best = {
                            seedUid = seedUid,
                            plantUid = tonumber(rung.plantUid) or 0,
                            skillReq = req,
                            count = count,
                            familyKey = ladder.key,
                            genus = ladder.genus,
                            role = ladder.role,
                        }
                    end
                end
            end
        end
    end
    return best
end

--- Refinable plant on the ladder with skillReq > ownedSeedReq and <= climbCap.
function SM.BestUpgradePlantOnLadder(ladder, climbCap, ownedSeedReq, opts)
    opts = type(opts) == "table" and opts or {}
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" then
        return nil
    end
    climbCap = tonumber(climbCap) or 0
    ownedSeedReq = tonumber(ownedSeedReq) or 0
    if climbCap < 1 then
        return nil
    end
    local Refine = StockPiler3.Refine
    local Items = StockPiler3.Items
    local best = nil
    local bestReq = -1
    for i = 1, #ladder.rungs do
        local rung = ladder.rungs[i]
        local req = tonumber(rung.skillReq) or 0
        local plantUid = tonumber(rung.plantUid) or 0
        if plantUid > 0 and req > ownedSeedReq and req <= climbCap then
            if opts.mainsOnly == true then
                local role = tostring(ladder.role or "")
                if role ~= "" and role ~= "main" and role ~= "unknown" then
                    plantUid = 0
                end
            end
            if plantUid > 0 and Refine and Refine.CountRefinablePlants then
                local spec = Items and Items.ToSpec and Items.ToSpec(plantUid) or nil
                local refinable = tonumber(Refine.CountRefinablePlants(plantUid, spec)) or 0
                if refinable > 0 and req > bestReq then
                    bestReq = req
                    best = {
                        seedUid = tonumber(rung.seedUid) or 0,
                        plantUid = plantUid,
                        skillReq = req,
                        refinable = refinable,
                        familyKey = ladder.key,
                        genus = ladder.genus,
                        role = ladder.role,
                        upgrade = true,
                    }
                end
            end
        end
    end
    return best
end

--- Lowest buyable seed rung on ladder (usually skillReq 1), skipping infertile.
function SM.LowestBuySeedOnLadder(ladder)
    if type(ladder) ~= "table" or type(ladder.rungs) ~= "table" then
        return nil
    end
    for i = 1, #ladder.rungs do
        local rung = ladder.rungs[i]
        local seedUid = tonumber(rung.seedUid) or 0
        local req = tonumber(rung.skillReq) or 0
        if seedUid > 0 and req >= 1 and not (SM.IsInfertileSeed and SM.IsInfertileSeed(seedUid)) then
            return {
                seedUid = seedUid,
                plantUid = tonumber(rung.plantUid) or 0,
                skillReq = req,
                familyKey = ladder.key,
                genus = ladder.genus,
                role = ladder.role,
            }
        end
    end
    return nil
end

function SM.DumpFamilies(emit)
    emit = emit or print
    local all = SM.BuildAllFamilyLadders()
    local keys = {}
    for k in pairs(all) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    emit("--- seed families (" .. tostring(#keys) .. ") ---")
    for i = 1, #keys do
        local bucket = all[keys[i]]
        local parts = {}
        for r = 1, #bucket.rungs do
            local rung = bucket.rungs[r]
            parts[#parts + 1] = string.format(
                "%d:s%d/p%d",
                tonumber(rung.skillReq) or 0,
                tonumber(rung.seedUid) or 0,
                tonumber(rung.plantUid) or 0
            )
        end
        emit(string.format(
            "  %s [%s/%s/fx%s] %s",
            tostring(bucket.key),
            tostring(bucket.genus),
            tostring(bucket.role),
            tostring(bucket.effectId),
            table.concat(parts, " ")
        ))
    end
end
