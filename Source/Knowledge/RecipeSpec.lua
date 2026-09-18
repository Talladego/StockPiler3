----------------------------------------------------------------
-- StockPiler3 Knowledge/RecipeSpec — learned brew fingerprints + craft counts
-- Callees above callers (RoR Lua has no local hoist).
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.RecipeSpec = StockPiler3.RecipeSpec or {}
local RS = StockPiler3.RecipeSpec

local ROLE_ORDER = {
    container = 1,
    main = 2,
    stabilizer = 3,
    goldweed = 3,
    extender = 4,
    multiplier = 5,
    stimulant = 5,
    ingredient = 6,
}

local CRAFT_BONUS = {
    STABILITY = 1,
    POWER = 2,
    MULTIPLIER = 4,
    SPECIAL_CHANCE = 14,
}

----------------------------------------------------------------
-- Account / narrow helpers
----------------------------------------------------------------

local function ToNarrow(text)
    if StockPiler3.Persistence and StockPiler3.Persistence.ToNarrow then
        return StockPiler3.Persistence.ToNarrow(text)
    end
    if type(text) == "wstring" and type(WStringToString) == "function" then
        return WStringToString(text) or ""
    end
    return tostring(text or "")
end

--- Prefer Account tables directly so migrate/hydrate never re-enter EnsureAccount.
local function RecipesTable()
    local acct = StockPiler3.Account
    if type(acct) == "table" then
        if type(acct.recipes) ~= "table" then
            acct.recipes = {}
        end
        return acct.recipes
    end
    if StockPiler3.Knowledge and StockPiler3.Knowledge.Recipes then
        return StockPiler3.Knowledge.Recipes()
    end
    return nil
end

local function PotionsTable()
    local acct = StockPiler3.Account
    if type(acct) == "table" then
        if type(acct.potions) ~= "table" then
            acct.potions = {}
        end
        return acct.potions
    end
    if StockPiler3.Knowledge and StockPiler3.Knowledge.Potions then
        return StockPiler3.Knowledge.Potions()
    end
    return nil
end

local function CharacterRow()
    if StockPiler3.Persistence and StockPiler3.Persistence.GetCharacterBucket then
        return StockPiler3.Persistence.GetCharacterBucket(false)
    end
    return nil
end

local function MS()
    return StockPiler3.MaterialSpec
end

local function SpecFingerprint(spec, boundUid)
    if type(spec) ~= "table" then
        return ""
    end
    local M = MS()
    local uid = tonumber(boundUid) or tonumber(spec.boundUid) or 0
    if spec.incomplete == true then
        if uid <= 0 then
            uid = tonumber(spec.uid) or 0
        end
        if M and M.Key then
            return M.Key(spec, uid)
        end
        if uid > 0 then
            return "uid:" .. tostring(uid)
        end
    end
    if M and M.Key then
        return M.Key(spec, nil)
    end
    if M and M.ProductKey then
        return M.ProductKey(spec) or ""
    end
    return string.format(
        "r:%s|p:%d|s:%d",
        tostring(spec.role or "?"),
        tonumber(spec.power) or 0,
        tonumber(spec.stability) or 0
    )
end

local function BonusValue(spec, ref)
    if type(spec) ~= "table" then
        return 0
    end
    if type(spec.bonuses) == "table" then
        local v = spec.bonuses[ref]
        if type(v) == "table" then
            return tonumber(v[1]) or 0
        end
        return tonumber(v) or 0
    end
    if ref == CRAFT_BONUS.POWER then
        return tonumber(spec.power) or 0
    end
    if ref == CRAFT_BONUS.STABILITY then
        return tonumber(spec.stability) or 0
    end
    return 0
end

local function StabilityOf(spec)
    return BonusValue(spec, CRAFT_BONUS.STABILITY)
end

----------------------------------------------------------------
-- Slot hydrate / slim (callees first)
----------------------------------------------------------------

local function ResolveSlotSpec(slot)
    if type(slot) ~= "table" then
        return nil
    end
    local uid = tonumber(slot.uid) or 0
    if type(slot.spec) == "table" then
        uid = uid > 0 and uid or (tonumber(slot.spec.uid) or tonumber(slot.spec.uniqueID) or 0)
    end
    -- Prefer live Items.ToSpec so incomplete/zero brew-learn stubs get real bonuses.
    if uid > 0 and StockPiler3.Items and StockPiler3.Items.ToSpec then
        local live = StockPiler3.Items.ToSpec(uid)
        if type(live) == "table" then
            if type(slot.spec) == "table" and slot.spec.role and (not live.role or live.role == "ingredient") then
                live.role = slot.spec.role or slot.role or live.role
            elseif slot.role and (not live.role or live.role == "ingredient") then
                live.role = slot.role
            end
            if live.incomplete == true then
                live.boundUid = tonumber(slot.uid) or tonumber(live.boundUid) or uid
            end
            -- Prefer recipe-slot role over classifier guess.
            if slot.role then
                live.role = slot.role
            end
            slot.spec = live
            return live
        end
    end
    if type(slot.spec) == "table" then
        if slot.spec.incomplete == true and (tonumber(slot.spec.boundUid) or 0) <= 0 then
            slot.spec.boundUid = tonumber(slot.uid) or tonumber(slot.spec.uid) or nil
        end
        return slot.spec
    end
    return nil
end

local function CollectSlotBuckets(slots)
    local buckets = {}
    local index = {}
    if type(slots) ~= "table" then
        return buckets
    end
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" then
            local spec = ResolveSlotSpec(slot)
            if type(spec) == "table" then
                local role = tostring(slot.role or spec.role or "")
                local boundUid = 0
                if spec.incomplete == true then
                    boundUid = tonumber(slot.uid)
                        or tonumber(slot.boundUid)
                        or tonumber(spec.boundUid)
                        or tonumber(spec.uid)
                        or 0
                end
                local fp = SpecFingerprint(spec, boundUid)
                local k = role .. "\0" .. fp
                local idx = index[k]
                local per = math.max(1, tonumber(slot.perCraft) or 1)
                if idx then
                    buckets[idx].perCraft = (tonumber(buckets[idx].perCraft) or 0) + per
                    -- Prefer an incomplete exemplar with a bound uid.
                    if buckets[idx].boundUid <= 0 and boundUid > 0 then
                        buckets[idx].boundUid = boundUid
                        buckets[idx].slot = slot
                        buckets[idx].spec = spec
                    end
                else
                    buckets[#buckets + 1] = {
                        role = role,
                        fp = fp,
                        perCraft = per,
                        boundUid = boundUid,
                        slot = slot,
                        spec = spec,
                    }
                    index[k] = #buckets
                end
            end
        end
    end
    table.sort(buckets, function(a, b)
        local oa = ROLE_ORDER[a.role] or 99
        local ob = ROLE_ORDER[b.role] or 99
        if oa ~= ob then
            return oa < ob
        end
        return tostring(a.fp) < tostring(b.fp)
    end)
    return buckets
end

local function SlimSlotsForStorage(slots)
    local slim = {}
    if type(slots) ~= "table" then
        return slim
    end
    -- Canonical: merge same-role same-fingerprint, sort by role then fingerprint.
    local buckets = CollectSlotBuckets(slots)
    for i = 1, #buckets do
        local b = buckets[i]
        local slot = b.slot
        local spec = b.spec
        local entry = {
            role = b.role,
            uid = tonumber(slot and slot.uid) or (b.boundUid > 0 and b.boundUid) or nil,
            perCraft = math.max(1, tonumber(b.perCraft) or 1),
        }
        if type(spec) == "table" and spec.incomplete == true then
            entry.boundUid = b.boundUid > 0 and b.boundUid or entry.uid
        elseif b.boundUid > 0 then
            entry.boundUid = b.boundUid
        end
        if type(spec) == "table" then
            entry.spec = {
                uid = tonumber(spec.uid) or entry.uid,
                role = spec.role or entry.role,
                power = tonumber(spec.power) or 0,
                stability = tonumber(spec.stability) or 0,
                duration = tonumber(spec.duration) or 0,
                tradeSkill = tonumber(spec.tradeSkill) or 0,
                skillLevel = tonumber(spec.skillLevel) or 0,
                cultivationType = tonumber(spec.cultivationType) or 0,
                slotType = tonumber(spec.slotType) or 0,
                effectId = spec.effectId,
                bonuses = type(spec.bonuses) == "table" and spec.bonuses or nil,
                incomplete = spec.incomplete == true,
                boundUid = entry.boundUid,
            }
            if spec.isRefinable ~= nil then
                entry.spec.isRefinable = spec.isRefinable == true
            end
        end
        slim[#slim + 1] = entry
    end
    return slim
end

local function HydrateRecipeSlots(recipe)
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return
    end
    for i = 1, #recipe.slots do
        ResolveSlotSpec(recipe.slots[i])
    end
end

--- Order-independent recipe identity: multiset of (role, SpecFingerprint) with summed perCraft.
local function SlotsFingerprint(slots)
    local buckets = CollectSlotBuckets(slots)
    local parts = {}
    for i = 1, #buckets do
        local b = buckets[i]
        parts[#parts + 1] = tostring(b.role)
            .. "x" .. tostring(b.perCraft)
            .. ":" .. tostring(b.fp)
    end
    return table.concat(parts, "|")
end

--- Merge same-role same-fingerprint slots; stable role + fingerprint order.
local function MergeSlotsByFingerprint(slots)
    local buckets = CollectSlotBuckets(slots)
    local out = {}
    for i = 1, #buckets do
        local b = buckets[i]
        local slot = b.slot
        local uid = tonumber(slot and slot.uid) or 0
        if uid <= 0 and b.boundUid > 0 then
            uid = b.boundUid
        end
        out[#out + 1] = {
            role = b.role,
            uid = uid > 0 and uid or nil,
            boundUid = b.boundUid > 0 and b.boundUid or nil,
            perCraft = math.max(1, tonumber(b.perCraft) or 1),
            spec = b.spec,
        }
    end
    return out
end

local function MaterialsToSpecSlots(materials)
    local slots = {}
    local M = MS()
    if type(materials) ~= "table" or not M or not M.FromItemData then
        return slots
    end
    for i = 1, #materials do
        local mat = materials[i]
        if type(mat) == "table" then
            local itemData = mat.itemData
            local uid = tonumber(mat.uniqueID) or 0
            if type(itemData) ~= "table" and uid > 0 and StockPiler3.Inventory and StockPiler3.Inventory.GetSample then
                itemData = StockPiler3.Inventory.GetSample(uid)
            end
            if uid <= 0 and type(itemData) == "table" then
                uid = tonumber(itemData.uniqueID) or 0
            end
            local spec = M.FromItemData(itemData, mat.role)
            if spec == nil and uid > 0 and StockPiler3.Items and StockPiler3.Items.ToSpec then
                spec = StockPiler3.Items.ToSpec(uid)
            end
            if type(spec) == "table" then
                if uid > 0 and StockPiler3.Items and StockPiler3.Items.StoreItem then
                    StockPiler3.Items.StoreItem(itemData or { uniqueID = uid }, "mat")
                end
                if mat.role then
                    spec.role = mat.role
                end
                if spec.incomplete == true and uid > 0 then
                    spec.boundUid = uid
                end
                slots[#slots + 1] = {
                    role = mat.role or spec.role or "ingredient",
                    uid = uid > 0 and uid or nil,
                    boundUid = spec.boundUid,
                    spec = spec,
                    perCraft = tonumber(mat.perCraft) or 1,
                }
            end
        end
    end
    return MergeSlotsByFingerprint(slots)
end

local function SpecStabilityTotal(slots)
    local total = 0
    if type(slots) ~= "table" then
        return total
    end
    for i = 1, #slots do
        local slot = slots[i]
        local role = slot.role or ""
        if role ~= "extender" and role ~= "multiplier" and role ~= "stimulant" then
            local per = tonumber(slot.perCraft) or 1
            total = total + StabilityOf(ResolveSlotSpec(slot)) * per
        end
    end
    return total
end

--- Apo has 3 shared ingredient slots (not container/main). Multiplier/extender/stimulant
--- consume that budget; stabilizer top-ups must not crowd them out of the load.
local function ApoIngredientSlotCount()
    local first = (ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT1) or 2
    local last = (ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT3) or 4
    return math.max(0, last - first + 1)
end

local function NonStabilizerIngredientUnits(slots)
    local used = 0
    if type(slots) ~= "table" then
        return used
    end
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" then
            local role = tostring(slot.role or "")
            if role ~= ""
                and role ~= "container"
                and role ~= "main"
                and role ~= "stabilizer"
                and role ~= "goldweed"
            then
                used = used + math.max(1, tonumber(slot.perCraft) or 1)
            end
        end
    end
    return used
end

local function StabilizerSlotBudget(slots)
    local budget = ApoIngredientSlotCount() - NonStabilizerIngredientUnits(slots)
    if budget < 0 then
        return 0
    end
    return budget
end

--- Cap a stabilizer/goldweed slot's count so all stab roles share the apo ingredient budget.
local function CapStabilizerPerCraft(slot, slots, want)
    want = math.max(1, tonumber(want) or 1)
    if type(slot) ~= "table" or type(slots) ~= "table" then
        return want
    end
    local budget = StabilizerSlotBudget(slots)
    if budget <= 0 then
        return math.min(want, math.max(1, tonumber(slot.perCraft) or 1))
    end
    local remaining = budget
    for i = 1, #slots do
        local other = slots[i]
        if type(other) == "table" then
            local role = tostring(other.role or "")
            if role == "stabilizer" or role == "goldweed" then
                local base = math.max(1, tonumber(other.perCraft) or 1)
                local otherWant = base
                if other == slot then
                    otherWant = want
                else
                    -- Sibling stabs keep learned perCraft for budget share (avoid recursive eff).
                    otherWant = base
                end
                local alloc = otherWant
                if alloc > remaining then
                    alloc = remaining
                end
                if alloc < 1 and remaining >= 1 and other == slot then
                    alloc = 1
                end
                remaining = remaining - alloc
                if other == slot then
                    if alloc < 1 then
                        return math.min(want, base)
                    end
                    return alloc
                end
            end
        end
    end
    return math.min(want, budget)
end

local function EffectiveSpecPerCraft(slot, slots)
    local perCraft = tonumber(slot and slot.perCraft) or 1
    if type(slot) ~= "table" then
        return perCraft
    end
    local role = slot.role or ""
    if role ~= "stabilizer" and role ~= "goldweed" then
        return perCraft
    end
    local total = SpecStabilityTotal(slots)
    local want = perCraft
    if total <= 0 then
        local stab = StabilityOf(ResolveSlotSpec(slot))
        if stab > 0 then
            -- Push past 0 so engine sees HIGH (total == 0 is MEDIUM).
            local extra = math.ceil((-total + 1) / stab)
            if extra < 1 then
                extra = 1
            end
            want = perCraft + extra
        end
    end
    return CapStabilizerPerCraft(slot, slots, want)
end

local function SumSlotBonus(slots, ref)
    local sum = 0
    if type(slots) ~= "table" then
        return sum
    end
    for i = 1, #slots do
        local slot = slots[i]
        local spec = ResolveSlotSpec(slot)
        local per = 1
        if type(slot) == "table" then
            per = math.max(1, tonumber(slot.perCraft) or 1)
        end
        sum = sum + BonusValue(spec, ref) * per
    end
    return sum
end

local function ObservedRecipeYield(recipe)
    if type(recipe) ~= "table" then
        return 0
    end
    local samples = tonumber(recipe.yieldSamples) or 0
    local sum = tonumber(recipe.yieldProductSum) or 0
    if samples > 0 then
        return sum / samples
    end
    return tonumber(recipe.recipeYield) or 0
end

local function PotionRecipeKeys(potion)
    if type(potion) ~= "table" then
        return nil
    end
    if type(potion.recipeKeys) == "table" then
        return potion.recipeKeys
    end
    return potion.alternateRecipeSpecKeys
end

local function EnsureBrewStats(recipe)
    if type(recipe) ~= "table" then
        return
    end
    recipe.brewAttempts = tonumber(recipe.brewAttempts) or 0
    recipe.brewSuccesses = tonumber(recipe.brewSuccesses) or 0
    recipe.brewCrits = tonumber(recipe.brewCrits) or 0
    recipe.brewSuperCrits = tonumber(recipe.brewSuperCrits) or 0
    recipe.brewFailures = tonumber(recipe.brewFailures) or 0
    recipe.brewVolatiles = tonumber(recipe.brewVolatiles) or 0
    recipe.yieldProductSum = tonumber(recipe.yieldProductSum) or 0
    recipe.yieldSamples = tonumber(recipe.yieldSamples) or 0
    recipe.crafts = tonumber(recipe.crafts) or 0
    if type(recipe.outcomes) ~= "table" then
        recipe.outcomes = {}
    end
end

local function OutputQuality(out)
    if type(out) ~= "table" then
        return "failed"
    end
    local name = string.lower(ToNarrow(out.name) or "")
    if string.find(name, "volatile", 1, true) then
        return "volatile"
    end
    if string.find(name, "potent", 1, true) then
        return "potent"
    end
    return "good"
end

local function RecordOutcome(recipe, potionUid, quality, qty)
    potionUid = tonumber(potionUid) or 0
    qty = tonumber(qty) or 1
    if potionUid <= 0 or type(recipe) ~= "table" then
        return
    end
    EnsureBrewStats(recipe)
    local key = tostring(potionUid)
    local oc = recipe.outcomes[key]
    if type(oc) ~= "table" then
        oc = { successes = 0, productSum = 0, quality = quality }
        recipe.outcomes[key] = oc
    end
    oc.successes = (tonumber(oc.successes) or 0) + 1
    oc.productSum = (tonumber(oc.productSum) or 0) + qty
    oc.quality = quality or oc.quality
    oc.yield = (tonumber(oc.successes) or 0) > 0
        and ((tonumber(oc.productSum) or 0) / oc.successes)
        or qty
end

local function NameLooksLiniment(name)
    local n = string.lower(ToNarrow(name))
    return string.find(n, "liniment", 1, true) ~= nil
end

local function NameLooksOneWayHarvest(name)
    local n = string.lower(ToNarrow(name))
    if n == "" then
        return false
    end
    if NameLooksLiniment(name) then
        return true
    end
    -- Non-refinable harvest products (powder/extract/oil/pulp/dust/blood).
    -- powder/extract: bare substring (align with SeedMap); others keep word boundary.
    return string.find(n, "powder", 1, true)
        or string.find(n, "extract", 1, true)
        or string.find(n, " oil", 1, true)
        or string.find(n, " pulp", 1, true)
        or string.find(n, " dust", 1, true)
        or string.match(n, "%sblood$") ~= nil
end

local function CountItemsMatchingSpec(spec)
    if type(spec) ~= "table" then
        return 0
    end
    local Inv = StockPiler3.Inventory
    -- Incomplete mains: exact uid only.
    if spec.incomplete == true then
        local bound = tonumber(spec.boundUid) or tonumber(spec.uid) or 0
        if bound > 0 and Inv and Inv.CountByUid then
            return tonumber(Inv.CountByUid(bound)) or 0
        end
        return 0
    end
    local M = MS()
    local total = 0
    local function accumulate(item)
        if type(item) ~= "table" then
            return
        end
        if M.IsSeedOrSpore and M.IsSeedOrSpore(item) == true then
            return
        end
        local ok = false
        if M.ProductMatches then
            ok = M.ProductMatches(item, spec) == true
        elseif M.Matches then
            ok = M.Matches(item, spec) == true
        end
        if ok then
            local stack = tonumber(item.stackCount) or tonumber(item.Count) or 1
            if stack < 1 then
                stack = 1
            end
            total = total + stack
        end
    end
    if Inv and Inv.ForEachItem and M then
        Inv.ForEachItem(accumulate)
    end
    return total
end

--- Plants/seeds still needed for AutoGrow seed-buffer (0 when buffer is satisfied).
--- Never subtract the full buffer min from plant stacks — that zeroed brew when
--- seeds were already at buffer (e.g. 5 Spumepetal plants − 5 reserve = 0 craftable).
local function GrowReserveForSpec(spec)
    local Caps = StockPiler3.TradeSkillCaps
    -- Apo/Butcher-only: no Cultivation → never reserve plants for grow/refine.
    if not (Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true) then
        return 0
    end
    local Watch = StockPiler3.Watch
    if Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() ~= true then
        return 0
    end
    local char = CharacterRow()
    if type(char) ~= "table" or char.growSeedBufferEnabled == false then
        return 0
    end
    local minBuf = tonumber(char.growSeedBufferMin) or 5
    if minBuf <= 0 then
        return 0
    end
    -- Only reserve when AutoGrow is in play.
    if Watch and Watch.HasAnyAutoGrow and Watch.HasAnyAutoGrow() ~= true then
        if Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() ~= true then
            return 0
        end
        if char.autoGrowEnabled ~= true then
            return 0
        end
    end

    local SM = StockPiler3.SeedMap
    local plantOrSeedUid = tonumber(spec and (spec.uid or spec.uniqueID or spec.boundUid)) or 0
    local seedUid = 0
    local isSeed = false
    if SM and SM.IsBagSeedOrSpore and SM.IsBagSeedOrSpore(spec) == true then
        isSeed = true
        seedUid = plantOrSeedUid
    elseif plantOrSeedUid > 0 and SM then
        if SM.PickBestSeedUid then
            seedUid = tonumber(SM.PickBestSeedUid(plantOrSeedUid)) or 0
        end
        if seedUid <= 0 and SM.ResolveSeedUidForSpec then
            seedUid = tonumber(SM.ResolveSeedUidForSpec(spec)) or 0
        end
        if seedUid <= 0 and SM.GetSeedUidsForPlant then
            local uids = SM.GetSeedUidsForPlant(plantOrSeedUid)
            seedUid = type(uids) == "table" and (tonumber(uids[1]) or 0) or 0
        end
    end
    if seedUid <= 0 then
        return 0
    end

    -- Prefer Refine budget (live + ground + outstanding); else live seed count.
    local headroom = nil
    local Refine = StockPiler3.Refine
    if Refine and Refine.GetSeedBudget then
        local budget = Refine.GetSeedBudget(seedUid)
        headroom = tonumber(budget and budget.headroom)
    end
    if headroom == nil then
        local live = 0
        local Inv = StockPiler3.Inventory
        if Inv and Inv.CountByUid then
            live = tonumber(Inv.CountByUid(seedUid)) or 0
        end
        headroom = math.max(0, minBuf - live)
    end
    if headroom <= 0 then
        return 0
    end
    -- Seeds: hold buffer headroom. Plants: hold feedstock to fill that headroom.
    return headroom
end

----------------------------------------------------------------
-- Public API
----------------------------------------------------------------

function RS.PotionKeyFromUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    return "uid:" .. tostring(uid)
end

--- Composite: uid:<outputUid>|rk:<recipeSpecKey>
function RS.PotionRecipeKey(outputUid, recipeSpecKey)
    local potionKey = RS.PotionKeyFromUid(outputUid)
    recipeSpecKey = tostring(recipeSpecKey or "")
    if potionKey == nil or recipeSpecKey == "" then
        return nil
    end
    return potionKey .. "|rk:" .. recipeSpecKey
end

function RS.ParsePotionRecipeKey(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    local uidStr, recipeSpecKey = string.match(key, "^uid:(%d+)|rk:(.+)$")
    if uidStr and recipeSpecKey and recipeSpecKey ~= "" then
        local uid = tonumber(uidStr) or 0
        return {
            potionRecipeKey = key,
            outputUid = uid,
            potionKey = RS.PotionKeyFromUid(uid),
            recipeSpecKey = recipeSpecKey,
            isComposite = true,
        }
    end
    local plainUid = string.match(key, "^uid:(%d+)$")
    if plainUid then
        local uid = tonumber(plainUid) or 0
        return {
            potionRecipeKey = key,
            outputUid = uid,
            potionKey = RS.PotionKeyFromUid(uid),
            recipeSpecKey = nil,
            isComposite = false,
        }
    end
    return nil
end

function RS.IsPotionRecipeKey(key)
    local parsed = RS.ParsePotionRecipeKey(key)
    return type(parsed) == "table" and parsed.isComposite == true
end

--- RecipeSpecKey from main/container/extras (+ optional output uid ignored for identity).
function RS.BuildRecipeSpecKey(slots, _outputUid)
    return SlotsFingerprint(slots)
end

function RS.RecipeSpecKey(slotsOrMaterials, _outputUid)
    if type(slotsOrMaterials) ~= "table" then
        return ""
    end
    local first = slotsOrMaterials[1]
    if type(first) == "table" and (first.itemData ~= nil or (first.uniqueID ~= nil and first.spec == nil and first.uid == nil)) then
        return SlotsFingerprint(MaterialsToSpecSlots(slotsOrMaterials))
    end
    return SlotsFingerprint(slotsOrMaterials)
end

function RS.GetRecipe(recipeSpecKey)
    recipeSpecKey = tostring(recipeSpecKey or "")
    if recipeSpecKey == "" then
        return nil
    end
    local recipes = RecipesTable()
    if type(recipes) ~= "table" then
        return nil
    end
    local recipe = recipes[recipeSpecKey]
    if type(recipe) == "table" then
        HydrateRecipeSlots(recipe)
        return recipe
    end
    return nil
end

function RS.GetPotion(potionKeyOrUid)
    local potions = PotionsTable()
    if type(potions) ~= "table" then
        return nil
    end
    local key = potionKeyOrUid
    if type(key) == "number" then
        key = RS.PotionKeyFromUid(key)
    end
    key = tostring(key or "")
    if key == "" then
        return nil
    end
    local parsed = RS.ParsePotionRecipeKey(key)
    if type(parsed) == "table" and parsed.potionKey then
        key = parsed.potionKey
    end
    local potion = potions[key]
    if type(potion) == "table" then
        return potion
    end
    return nil
end

local function PotionActiveRecipeKey(potion)
    if type(potion) ~= "table" then
        return nil
    end
    local key = potion.activeRecipeKey or potion.activeRecipeSpecKey or potion.recipeSpecKey
    if type(key) == "string" and key ~= "" then
        return key
    end
    local keys = PotionRecipeKeys(potion)
    if type(keys) == "table" and type(keys[1]) == "string" and keys[1] ~= "" then
        return keys[1]
    end
    return nil
end

--- Recipe for a composite potionRecipeKey (uid:N|rk:fingerprint).
function RS.RecipeSpecForPotionRecipe(potionRecipeKey)
    local parsed = RS.ParsePotionRecipeKey(potionRecipeKey)
    if type(parsed) ~= "table" or type(parsed.recipeSpecKey) ~= "string" then
        return nil
    end
    local recipe = RS.GetRecipe(parsed.recipeSpecKey)
    if type(recipe) ~= "table" then
        return nil
    end
    local uid = tonumber(parsed.outputUid) or 0
    if uid > 0 then
        recipe.outputUid = uid
    end
    return recipe
end

--- Recipe for a watch/catalog key (composite uid:N|rk:... or plain uid:N).
function RS.RecipeSpecForPotion(potionKey)
    local parsed = RS.ParsePotionRecipeKey(potionKey)
    if type(parsed) == "table" and parsed.isComposite == true then
        return RS.RecipeSpecForPotionRecipe(potionKey)
    end
    local potion = RS.GetPotion(potionKey)
    if type(potion) ~= "table" then
        return nil
    end
    local key = PotionActiveRecipeKey(potion)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    local recipe = RS.GetRecipe(key)
    if type(recipe) ~= "table" then
        return nil
    end
    local uid = tonumber(potion.outputUid) or 0
    if uid > 0 then
        recipe.outputUid = uid
    end
    return recipe
end

--- Resolve watch/catalog key to potion row + recipeSpecKey (legacy uid:N or composite).
function RS.ResolveWatchPotion(watchKey)
    watchKey = tostring(watchKey or "")
    if watchKey == "" then
        return nil
    end
    local potions = PotionsTable()
    if type(potions) ~= "table" then
        return nil
    end
    local parsed = RS.ParsePotionRecipeKey(watchKey)
    if type(parsed) ~= "table" then
        local potion = potions[watchKey]
        if type(potion) ~= "table" then
            return nil
        end
        return {
            potion = potion,
            potionKey = potion.potionKey or watchKey,
            potionRecipeKey = watchKey,
            recipeSpecKey = PotionActiveRecipeKey(potion),
            outputUid = tonumber(potion.outputUid) or 0,
        }
    end
    local potion = potions[parsed.potionKey]
    if type(potion) ~= "table" then
        return nil
    end
    local recipeSpecKey = parsed.recipeSpecKey
    if recipeSpecKey == nil or recipeSpecKey == "" then
        recipeSpecKey = PotionActiveRecipeKey(potion)
    end
    local potionRecipeKey = parsed.isComposite and parsed.potionRecipeKey
        or RS.PotionRecipeKey(parsed.outputUid, recipeSpecKey)
    return {
        potion = potion,
        potionKey = parsed.potionKey,
        potionRecipeKey = potionRecipeKey,
        recipeSpecKey = recipeSpecKey,
        outputUid = parsed.outputUid,
    }
end

function RS.FingerprintStats(recipe, potionUid)
    return RS.RecipeFingerprintStats(recipe, potionUid)
end

function RS.RecipeFingerprintStats(recipe, potionUid)
    local stats = {
        power = 0,
        stability = 0,
        multiplier = 0,
        superCrit = 0,
        yield = 0,
    }
    if type(recipe) ~= "table" then
        return stats
    end
    HydrateRecipeSlots(recipe)
    stats.power = SumSlotBonus(recipe.slots, CRAFT_BONUS.POWER)
    stats.stability = SumSlotBonus(recipe.slots, CRAFT_BONUS.STABILITY)
    stats.multiplier = SumSlotBonus(recipe.slots, CRAFT_BONUS.MULTIPLIER)
    -- SCrit column: SPECIAL_CHANCE (Super-Critical). Display/fingerprint today;
    -- may stop counting for identity later — crit success is a different potion
    -- uid and does not fill the watched target stock.
    stats.superCrit = SumSlotBonus(recipe.slots, CRAFT_BONUS.SPECIAL_CHANCE)
    local yield = ObservedRecipeYield(recipe)
    potionUid = tonumber(potionUid) or 0
    if potionUid > 0 and type(recipe.outcomes) == "table" then
        local oc = recipe.outcomes[tostring(potionUid)]
        if type(oc) == "table" and (tonumber(oc.yield) or 0) > 0 then
            yield = tonumber(oc.yield)
        end
    end
    if yield <= 0 then
        yield = tonumber(recipe.recipeYield) or 0
    end
    stats.yield = yield
    return stats
end

function RS.SlimRecipeForStorage(recipe)
    if type(recipe) ~= "table" then
        return recipe
    end
    if type(recipe.slots) == "table" then
        recipe.slots = SlimSlotsForStorage(recipe.slots)
    end
    return recipe
end

function RS.SlimAllRecipesForStorage()
    local recipes = RecipesTable()
    if type(recipes) ~= "table" then
        return 0
    end
    local n = 0
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            RS.SlimRecipeForStorage(recipe)
            n = n + 1
        end
    end
    return n
end

function RS.IsLinimentClass(specOrItem)
    if type(specOrItem) ~= "table" then
        return false
    end
    if NameLooksLiniment(specOrItem.name) then
        return true
    end
    if specOrItem.linimentClass == true then
        return true
    end
    local uid = tonumber(specOrItem.uid) or tonumber(specOrItem.uniqueID) or 0
    if uid > 0 and StockPiler3.Items and StockPiler3.Items.GetByUid then
        local row = StockPiler3.Items.GetByUid(uid)
        if type(row) == "table" then
            if NameLooksLiniment(row.name) or row.linimentClass == true then
                return true
            end
        end
    end
    if uid > 0 then
        local potions = PotionsTable()
        local pk = RS.PotionKeyFromUid and RS.PotionKeyFromUid(uid)
        local prow = type(potions) == "table" and pk and potions[pk]
        if type(prow) == "table" and (prow.linimentClass == true or NameLooksLiniment(prow.name)) then
            return true
        end
    end
    return false
end

--- One-way mains: delegate to SeedMap (liniment / special / non-refinable harvest).
function RS.IsOneWayMain(specOrItem)
    if type(specOrItem) ~= "table" then
        return false
    end
    local SM = StockPiler3.SeedMap
    if SM and SM.IsOneWayHarvestSpec then
        return SM.IsOneWayHarvestSpec(specOrItem) == true
    end
    if RS.IsLinimentClass(specOrItem) then
        return true
    end
    return NameLooksOneWayHarvest(specOrItem.name)
end

local function CountFromPlannerWarmCache(spec)
    local P = StockPiler3.Planner
    if not (P and P.IsHaveCacheWarmForSnap and P.IsHaveCacheWarmForSnap() == true) then
        return nil
    end
    if not P.CountItemsMatchingSpec then
        return nil
    end
    -- cacheOnly avoids Planner→RS recursion on miss.
    local n = P.CountItemsMatchingSpec(spec, { cacheOnly = true })
    if n == nil then
        return nil
    end
    return tonumber(n) or 0
end

function RS.BrewAvailableForSpec(spec)
    local have = CountFromPlannerWarmCache(spec)
    if have == nil then
        have = CountItemsMatchingSpec(spec)
    end
    local reserve = GrowReserveForSpec(spec)
    if reserve <= 0 then
        return have
    end
    local avail = have - reserve
    if avail < 0 then
        return 0
    end
    return avail
end

function RS.CountItemsMatchingSpec(spec, _opts)
    local have = CountFromPlannerWarmCache(spec)
    if have ~= nil then
        return have
    end
    return CountItemsMatchingSpec(spec)
end

--- How many full crafts bags support.
--- MUST honor brewRespectGrowReserve: opts.respectGrowReserve OR character flag → BrewAvailableForSpec.
function RS.CountCraftsPossible(recipe, opts)
    if type(recipe) ~= "table" then
        return 0
    end
    opts = type(opts) == "table" and opts or {}
    -- Wire brewRespectGrowReserve: opts.respectGrowReserve OR character flag.
    -- Explicit opts.respectGrowReserve == false opts out (non-reserve craftable memo).
    local charRespect = true
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        charRespect = false
    else
        local char = CharacterRow()
        if type(char) == "table" then
            charRespect = char.brewRespectGrowReserve ~= false
        end
    end
    local respect = (opts.respectGrowReserve == true) or charRespect
    if opts.respectGrowReserve == false then
        respect = false
    end
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        respect = false
    end

    HydrateRecipeSlots(recipe)
    local slots = recipe.slots
    if type(slots) ~= "table" or #slots == 0 then
        return 0
    end
    local possible = nil
    for i = 1, #slots do
        local slot = slots[i]
        local spec = ResolveSlotSpec(slot)
        if type(slot) == "table" and type(spec) == "table" then
            local perCraft = EffectiveSpecPerCraft(slot, slots)
            if perCraft < 1 then
                perCraft = 1
            end
            local have
            if respect then
                have = RS.BrewAvailableForSpec(spec)
            else
                have = CountItemsMatchingSpec(spec)
            end
            local craftsHave = math.floor(have / perCraft)
            if craftsHave < 0 then
                craftsHave = 0
            end
            if possible == nil or craftsHave < possible then
                possible = craftsHave
            end
        end
    end
    return possible or 0
end

----------------------------------------------------------------
-- Potion Effect resolve (stored → fx: → main effectId → Classify)
----------------------------------------------------------------

local EFFECT_KEY_UI_ALIASES = {
    rskill = "bs",
    wil = "wp",
    arm = "armor",
    shabs = "absorb",
    regen = "hot",
}

--- Map MaterialSpec / description aliases onto Potions-tab filter keys.
function RS.NormalizeEffectKeyForUi(effectKey)
    if type(effectKey) ~= "string" or effectKey == "" then
        return nil
    end
    local key = string.lower(effectKey)
    return EFFECT_KEY_UI_ALIASES[key] or key
end

local function EffectKeyFromFxInRecipeKey(recipeKey)
    recipeKey = tostring(recipeKey or "")
    if recipeKey == "" then
        return nil
    end
    local fx = string.match(recipeKey, "fx:(%d+)")
    local effectId = tonumber(fx) or 0
    if effectId <= 0 then
        return nil
    end
    local MS = StockPiler3.MaterialSpec
    if not MS or not MS.EffectKeyFromEffectId then
        return nil
    end
    return RS.NormalizeEffectKeyForUi(MS.EffectKeyFromEffectId(effectId))
end

local function EffectKeyFromRecipeMain(recipe)
    if type(recipe) ~= "table" then
        return nil
    end
    HydrateRecipeSlots(recipe)
    local slots = recipe.slots or {}
    local MS = StockPiler3.MaterialSpec
    local Items = StockPiler3.Items
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" and (slot.role == "main" or (type(slot.spec) == "table" and slot.spec.role == "main")) then
            local spec = ResolveSlotSpec(slot)
            local effectId = type(spec) == "table" and tonumber(spec.effectId) or 0
            local uid = tonumber(slot.uid) or (type(spec) == "table" and tonumber(spec.uid)) or 0
            if effectId <= 0 and uid > 0 and Items and Items.GetByUid then
                local row = Items.GetByUid(uid)
                effectId = type(row) == "table" and tonumber(row.effectId) or 0
                -- Incomplete mains often omit craftingBonus EFFECT; enrich from item/DB.
                if effectId <= 0 and MS and MS.FromItemData then
                    local probe = row
                    if type(probe) ~= "table" then
                        probe = { uniqueID = uid }
                    end
                    local enriched = MS.FromItemData(probe, "main")
                    effectId = type(enriched) == "table" and tonumber(enriched.effectId) or 0
                    if effectId > 0 and type(row) == "table" then
                        row.effectId = effectId
                    end
                end
            end
            if effectId > 0 and MS and MS.EffectKeyFromEffectId then
                return RS.NormalizeEffectKeyForUi(MS.EffectKeyFromEffectId(effectId))
            end
        end
    end
    return nil
end

--- Resolve potion Effect column key from the potion / recipe — not the product name.
--- Order: Use: ability → recipe fx: → main EFFECT id → stored.
--- opts.recipe / opts.recipeKey / opts.itemData optional.
--- opts.stamp ~= false stamps potion.effectKey when found.
--- opts.allowClassify == false skips bag/DB Use (fx:/main only).
function RS.ResolveEffectKeyForPotion(potion, opts)
    opts = type(opts) == "table" and opts or {}
    local key = nil
    local stored = nil
    if type(potion) == "table" and type(potion.effectKey) == "string" and potion.effectKey ~= "" then
        stored = RS.NormalizeEffectKeyForUi(potion.effectKey)
    end

    local function ResolveOutputItemData()
        local itemData = opts.itemData
        if type(itemData) ~= "table" and type(opts.out) == "table" then
            itemData = opts.out.itemData or opts.out
        end
        local uid = 0
        if type(potion) == "table" then
            uid = tonumber(potion.outputUid) or 0
        end
        if type(itemData) ~= "table" and uid > 0 and StockPiler3.Inventory and StockPiler3.Inventory.GetSample then
            itemData = StockPiler3.Inventory.GetSample(uid)
        end
        local hasUse = false
        if type(itemData) == "table" and type(itemData.bonus) == "table" then
            for _, b in pairs(itemData.bonus) do
                if type(b) == "table" and tonumber(b.type) == 3 and (tonumber(b.reference) or 0) > 0 then
                    hasUse = true
                    break
                end
            end
        end
        if (not hasUse) and uid > 0 and type(GetDatabaseItemData) == "function" then
            local ok, data = pcall(GetDatabaseItemData, uid)
            if ok and type(data) == "table" then
                itemData = data
            end
        end
        return itemData
    end

    -- Finished potion Use: ability (engine tooltip SoT).
    if opts.allowClassify ~= false
        and StockPiler3.Classify and StockPiler3.Classify.GetEffectKeyFromPotionUse
    then
        local itemData = ResolveOutputItemData()
        if type(itemData) == "table" then
            key = RS.NormalizeEffectKeyForUi(StockPiler3.Classify.GetEffectKeyFromPotionUse(itemData))
            if key and type(potion) == "table" and StockPiler3.Classify.GetPotionUseAbilityId then
                local abilityId = StockPiler3.Classify.GetPotionUseAbilityId(itemData)
                if (tonumber(abilityId) or 0) > 0 then
                    potion.useAbilityId = tonumber(abilityId)
                end
            end
        end
        -- Offline: replay stored Use ability id through GetAbilityDesc.
        if key == nil and type(potion) == "table" and (tonumber(potion.useAbilityId) or 0) > 0
            and type(GetAbilityDesc) == "function"
        then
            local iLevel = tonumber(potion.iLevel) or 0
            local ok, text = pcall(GetAbilityDesc, tonumber(potion.useAbilityId), iLevel)
            if ok and text ~= nil and StockPiler3.Classify.GetEffectKeyFromPotionUse then
                key = RS.NormalizeEffectKeyForUi(
                    StockPiler3.Classify.GetEffectKeyFromPotionUse({
                        bonus = { { type = 3, reference = tonumber(potion.useAbilityId) } },
                        iLevel = iLevel,
                    })
                )
            end
        end
    end

    local recipe = opts.recipe
    local recipeKey = tostring(opts.recipeKey or "")
    if key == nil then
        if recipeKey == "" and type(potion) == "table" then
            recipeKey = tostring(PotionActiveRecipeKey(potion) or "")
            if recipeKey == "" then
                local keys = PotionRecipeKeys(potion)
                if type(keys) == "table" and type(keys[1]) == "string" then
                    recipeKey = keys[1]
                end
            end
        end
        if recipeKey ~= "" then
            key = EffectKeyFromFxInRecipeKey(recipeKey)
        end
        if key == nil and type(potion) == "table" then
            local keys = PotionRecipeKeys(potion)
            if type(keys) == "table" then
                for i = 1, #keys do
                    key = EffectKeyFromFxInRecipeKey(keys[i])
                    if key then
                        break
                    end
                end
            end
        end
    end
    if key == nil then
        if type(recipe) ~= "table" and recipeKey ~= "" then
            local recipes = RecipesTable()
            recipe = type(recipes) == "table" and recipes[recipeKey] or nil
        end
        if type(recipe) ~= "table" and type(potion) == "table" then
            local pk = potion.potionKey or (potion.outputUid and RS.PotionKeyFromUid(potion.outputUid))
            if pk then
                recipe = RS.RecipeSpecForPotion(pk)
            end
        end
        key = EffectKeyFromRecipeMain(recipe)
    end
    if key == nil then
        key = stored
    end
    if key and type(potion) == "table" and opts.stamp ~= false then
        potion.effectKey = key
    end
    return key
end

--- Boot: fill / refresh effectKey from potion Use: or recipe main EFFECT (not product name).
function RS.MigratePotionEffectKeys()
    local potions = PotionsTable()
    if type(potions) ~= "table" then
        return 0
    end
    local stamped = 0
    for _, potion in pairs(potions) do
        if type(potion) == "table" then
            local before = potion.effectKey
            local key = RS.ResolveEffectKeyForPotion(potion, {
                stamp = true,
                allowClassify = true,
            })
            if key and key ~= before then
                stamped = stamped + 1
            elseif key and (type(before) ~= "string" or before == "") then
                stamped = stamped + 1
            else
                local norm = before and RS.NormalizeEffectKeyForUi(before) or nil
                if norm and norm ~= before then
                    potion.effectKey = norm
                    stamped = stamped + 1
                end
            end
        end
    end
    if stamped > 0 and StockPiler3.Knowledge and StockPiler3.Knowledge.Touch then
        StockPiler3.Knowledge.Touch("potion-effect")
    end
    return stamped
end

--- Role names that open a fingerprint segment (`rolexN:spec...`). Spec payloads may
--- contain "|" so fingerprints cannot be split on "|" alone.
local FINGERPRINT_ROLE = {
    container = true,
    main = true,
    stabilizer = true,
    extender = true,
    multiplier = true,
    ingredient = true,
}

--- Split recipe fingerprint into role segments (`rolexN:spec...`).
local function FingerprintRoleParts(key)
    key = tostring(key or "")
    if key == "" then
        return {}
    end
    local starts = {}
    local pos = 1
    local n = string.len(key)
    while pos <= n do
        local s, e, role = string.find(key, "([%a]+)x%d+:", pos)
        if not s then
            break
        end
        if FINGERPRINT_ROLE[role] == true
            and (s == 1 or string.sub(key, s - 1, s - 1) == "|")
        then
            starts[#starts + 1] = s
        end
        pos = e + 1
    end
    local parts = {}
    for i = 1, #starts do
        local from = starts[i]
        local to = n
        if starts[i + 1] then
            to = starts[i + 1] - 2
        end
        if to >= from then
            parts[#parts + 1] = string.sub(key, from, to)
        end
    end
    return parts
end

--- True when shortKey's role segments are a proper subset of longKey's.
--- Covers missing trailing slots and mid-board omissions (e.g. no stabilizer).
local function IsStrictFingerprintSubset(shortKey, longKey)
    shortKey = tostring(shortKey or "")
    longKey = tostring(longKey or "")
    if shortKey == "" or longKey == "" or shortKey == longKey then
        return false
    end
    local shortParts = FingerprintRoleParts(shortKey)
    local longParts = FingerprintRoleParts(longKey)
    if #shortParts > 0 and #longParts > 0 then
        if #shortParts >= #longParts then
            return false
        end
        local longSet = {}
        for i = 1, #longParts do
            longSet[longParts[i]] = true
        end
        for i = 1, #shortParts do
            if longSet[shortParts[i]] ~= true then
                return false
            end
        end
        return true
    end
    -- Fallback: legacy trailing-prefix check (older fingerprints).
    if #shortKey >= #longKey then
        return false
    end
    if string.sub(longKey, 1, #shortKey) ~= shortKey then
        return false
    end
    return string.sub(longKey, #shortKey + 1, #shortKey + 1) == "|"
end

--- Union of recipeKeys + alternateRecipeSpecKeys + active pointers (deduped).
local function CollectPotionRecipeKeyList(potion)
    local seen = {}
    local out = {}
    local function add(k)
        k = tostring(k or "")
        if k ~= "" and seen[k] ~= true then
            seen[k] = true
            out[#out + 1] = k
        end
    end
    if type(potion) ~= "table" then
        return out
    end
    if type(potion.recipeKeys) == "table" then
        for i = 1, #potion.recipeKeys do
            add(potion.recipeKeys[i])
        end
    end
    if type(potion.alternateRecipeSpecKeys) == "table" then
        for i = 1, #potion.alternateRecipeSpecKeys do
            add(potion.alternateRecipeSpecKeys[i])
        end
    end
    add(potion.activeRecipeKey)
    add(potion.activeRecipeSpecKey)
    add(potion.recipeSpecKey)
    return out
end

local function RecipeOutcomeUidSet(recipe)
    local uids = {}
    if type(recipe) ~= "table" then
        return uids
    end
    if type(recipe.outcomes) == "table" then
        for uidStr, _ in pairs(recipe.outcomes) do
            local uid = tonumber(uidStr) or 0
            if uid > 0 then
                uids[uid] = true
            end
        end
    end
    local outUid = tonumber(recipe.outputUid) or tonumber(recipe.activeOutcomeUid) or 0
    if outUid > 0 then
        uids[outUid] = true
    end
    return uids
end

local function RecipeOutcomesOverlap(a, b)
    local ua = RecipeOutcomeUidSet(a)
    local ub = RecipeOutcomeUidSet(b)
    if next(ua) == nil then
        return true
    end
    for uid in pairs(ua) do
        if ub[uid] == true then
            return true
        end
    end
    return false
end

local function ApplyPotionRecipeKeyList(potion, kept)
    potion.recipeKeys = kept
    potion.alternateRecipeSpecKeys = kept
    local active = tostring(potion.activeRecipeKey or potion.activeRecipeSpecKey or "")
    local activeOk = false
    for i = 1, #kept do
        if kept[i] == active then
            activeOk = true
            break
        end
    end
    if not activeOk then
        local best = kept[1] or ""
        for i = 2, #kept do
            if #tostring(kept[i]) > #tostring(best) then
                best = kept[i]
            end
        end
        potion.activeRecipeKey = best ~= "" and best or nil
        potion.activeRecipeSpecKey = potion.activeRecipeKey
        if potion.activeRecipeKey then
            potion.recipeSpecKey = potion.activeRecipeKey
        end
    end
end

function RS.RegisterKnownPotion(outputUid, out, recipeSpecKey, quality)
    outputUid = tonumber(outputUid) or 0
    if outputUid <= 0 then
        return nil, false, false
    end
    local potions = PotionsTable()
    if type(potions) ~= "table" then
        return nil, false, false
    end
    local potionKey = RS.PotionKeyFromUid(outputUid)
    local existing = potions[potionKey]
    local isNew = type(existing) ~= "table"
    if isNew then
        existing = {
            potionKey = potionKey,
            outputUid = outputUid,
            recipeKeys = {},
        }
    end
    existing.name = (out and out.name) or existing.name
    existing.nameNarrow = (out and (out.nameNarrow or ToNarrow(out.name))) or existing.nameNarrow
    existing.iconNum = (out and tonumber(out.iconNum)) or existing.iconNum or 0
    if existing.linimentClass ~= true then
        if RS.IsLinimentClass({ name = existing.name, uid = outputUid }) then
            existing.linimentClass = true
        end
    end
    if StockPiler3.Items and StockPiler3.Items.StoreItem then
        StockPiler3.Items.StoreItem(
            (out and type(out.itemData) == "table") and out.itemData or out or { uniqueID = outputUid },
            "potion"
        )
    end
    recipeSpecKey = tostring(recipeSpecKey or "")
    local recipeKeyAdded = false
    if quality ~= "failed" and recipeSpecKey ~= "" then
        local keys = CollectPotionRecipeKeyList(existing)
        -- Incomplete board snapshots (missing mid/trailing slots) are subsets of the
        -- full fingerprint — do not register them as alternate recipes / active.
        local weaker = false
        for i = 1, #keys do
            local existingKey = tostring(keys[i] or "")
            if existingKey ~= "" and IsStrictFingerprintSubset(recipeSpecKey, existingKey) then
                weaker = true
                break
            end
        end
        if not weaker then
            local seen = false
            for i = 1, #keys do
                if keys[i] == recipeSpecKey then
                    seen = true
                    break
                end
            end
            if not seen then
                keys[#keys + 1] = recipeSpecKey
                recipeKeyAdded = true
            end
            -- Drop any previously linked keys that are strict subsets of this one.
            local kept = {}
            for i = 1, #keys do
                local k = tostring(keys[i] or "")
                if k ~= "" and not IsStrictFingerprintSubset(k, recipeSpecKey) then
                    kept[#kept + 1] = k
                end
            end
            ApplyPotionRecipeKeyList(existing, kept)
            existing.activeRecipeKey = recipeSpecKey
            existing.activeRecipeSpecKey = recipeSpecKey
            existing.recipeSpecKey = recipeSpecKey
            RS.ResolveEffectKeyForPotion(existing, {
                recipeKey = recipeSpecKey,
                out = out,
                itemData = out and (out.itemData or out) or nil,
                stamp = true,
            })
        end
    end
    potions[potionKey] = existing
    return existing, isNew, recipeKeyAdded
end

--- Drop dangling / dominated alternate fingerprints on potions.
--- Removes keys missing from recipes, and role-subset keys of a richer sibling.
function RS.ScrubSubsetPotionRecipeKeys()
    local potions = PotionsTable()
    local recipes = RecipesTable()
    if type(potions) ~= "table" then
        return 0
    end
    local removed = 0
    for _, potion in pairs(potions) do
        if type(potion) == "table" then
            local keys = CollectPotionRecipeKeyList(potion)
            if #keys > 0 then
                local kept = {}
                for i = 1, #keys do
                    local a = tostring(keys[i] or "")
                    local drop = false
                    if a == "" then
                        drop = true
                    elseif type(recipes) ~= "table" or type(recipes[a]) ~= "table" then
                        drop = true
                    else
                        for j = 1, #keys do
                            local b = tostring(keys[j] or "")
                            if a ~= b
                                and type(recipes[b]) == "table"
                                and IsStrictFingerprintSubset(a, b)
                            then
                                drop = true
                                break
                            end
                        end
                    end
                    if drop then
                        removed = removed + 1
                    else
                        kept[#kept + 1] = a
                    end
                end
                ApplyPotionRecipeKeyList(potion, kept)
            end
        end
    end
    return removed
end

--- Delete unreferenced recipes that are role-subsets of a richer recipe sharing outcomes.
function RS.ScrubOrphanSubsetRecipes()
    local recipes = RecipesTable()
    local potions = PotionsTable()
    if type(recipes) ~= "table" then
        return 0
    end
    local referenced = {}
    if type(potions) == "table" then
        for _, potion in pairs(potions) do
            if type(potion) == "table" then
                local keys = CollectPotionRecipeKeyList(potion)
                for i = 1, #keys do
                    referenced[keys[i]] = true
                end
            end
        end
    end
    local allKeys = {}
    for k, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            allKeys[#allKeys + 1] = tostring(k)
        end
    end
    local removed = 0
    for i = 1, #allKeys do
        local a = allKeys[i]
        if referenced[a] ~= true and type(recipes[a]) == "table" then
            local drop = false
            for j = 1, #allKeys do
                local b = allKeys[j]
                if a ~= b
                    and type(recipes[b]) == "table"
                    and IsStrictFingerprintSubset(a, b)
                    and RecipeOutcomesOverlap(recipes[a], recipes[b])
                then
                    drop = true
                    break
                end
            end
            if drop then
                recipes[a] = nil
                removed = removed + 1
            end
        end
    end
    return removed
end

function RS.RelinkPotionRecipeKeysFromOutcomes()
    local recipes = RecipesTable()
    local potions = PotionsTable()
    if type(recipes) ~= "table" or type(potions) ~= "table" then
        return 0
    end
    local added = 0
    for recipeKey, recipe in pairs(recipes) do
        recipeKey = tostring(recipeKey or "")
        if recipeKey ~= "" and type(recipe) == "table" and type(recipe.outcomes) == "table" then
            for uidStr, oc in pairs(recipe.outcomes) do
                local uid = tonumber(uidStr) or 0
                if uid > 0 and type(oc) == "table" then
                    local potionKey = RS.PotionKeyFromUid(uid)
                    local potion = potions[potionKey]
                    if type(potion) ~= "table" then
                        potion = {
                            potionKey = potionKey,
                            outputUid = uid,
                            recipeKeys = {},
                        }
                        potions[potionKey] = potion
                    end
                    local keys = CollectPotionRecipeKeyList(potion)
                    local weaker = false
                    for i = 1, #keys do
                        if IsStrictFingerprintSubset(recipeKey, tostring(keys[i] or "")) then
                            weaker = true
                            break
                        end
                    end
                    if not weaker then
                        local seen = false
                        for i = 1, #keys do
                            if keys[i] == recipeKey then
                                seen = true
                                break
                            end
                        end
                        if not seen then
                            if type(potion.recipeKeys) ~= "table" then
                                potion.recipeKeys = {}
                            end
                            potion.recipeKeys[#potion.recipeKeys + 1] = recipeKey
                            added = added + 1
                        end
                    end
                end
            end
        end
    end
    RS.ScrubSubsetPotionRecipeKeys()
    RS.ScrubOrphanSubsetRecipes()
    return added
end

function RS.StoreLearnedRecipeSpec(materials, outputs, opts)
    if type(materials) ~= "table" or #materials == 0 then
        return false
    end
    if type(outputs) ~= "table" then
        outputs = {}
    end
    opts = type(opts) == "table" and opts or {}
    local recipes = RecipesTable()
    if type(recipes) ~= "table" then
        return false
    end
    local slots = MaterialsToSpecSlots(materials)
    if #slots == 0 then
        return false
    end
    local fingerprint = SlotsFingerprint(slots)
    if fingerprint == "" then
        return false
    end

    local byUid = {}
    local goodUid = nil
    local betterCount = 0
    local volatileCount = 0
    for i = 1, #outputs do
        local out = outputs[i]
        local uid = tonumber(out and out.uniqueID) or 0
        local quality = OutputQuality(out)
        if uid > 0 and quality ~= "failed" then
            byUid[uid] = out
            if quality == "potent" then
                betterCount = betterCount + 1
            elseif quality == "volatile" then
                volatileCount = volatileCount + 1
            elseif quality == "good" and goodUid == nil then
                goodUid = uid
            end
        end
    end
    local producedAny = next(byUid) ~= nil
    local failed = not producedAny
    local mainConsumed = opts.mainConsumed
    if mainConsumed == nil then
        mainConsumed = true
    end

    local recipe = recipes[fingerprint]
    local isNew = type(recipe) ~= "table"
    local structuralChange = isNew
    if isNew then
        recipe = {
            recipeSpecKey = fingerprint,
            slots = SlimSlotsForStorage(slots),
            outcomes = {},
            brewAttempts = 0,
            brewSuccesses = 0,
            brewCrits = 0,
            brewSuperCrits = 0,
            brewFailures = 0,
            brewVolatiles = 0,
            yieldProductSum = 0,
            yieldSamples = 0,
            crafts = 0,
            quality = "good",
        }
    else
        EnsureBrewStats(recipe)
        recipe.slots = SlimSlotsForStorage(slots)
    end

    recipe.brewAttempts = (tonumber(recipe.brewAttempts) or 0) + 1
    if failed then
        recipe.brewFailures = (tonumber(recipe.brewFailures) or 0) + 1
    else
        recipe.brewSuccesses = (tonumber(recipe.brewSuccesses) or 0) + 1
        recipe.crafts = (tonumber(recipe.crafts) or 0) + 1
        local primaryQty = 0
        for uid, out in pairs(byUid) do
            local quality = OutputQuality(out)
            local qty = tonumber(out.lastDelta) or tonumber(out.crafts) or 1
            RecordOutcome(recipe, uid, quality, qty)
            local _, potionIsNew, recipeKeyAdded = RS.RegisterKnownPotion(uid, out, fingerprint, quality)
            if potionIsNew == true or recipeKeyAdded == true then
                structuralChange = true
            end
            if quality == "good" then
                primaryQty = primaryQty + qty
            end
        end
        if primaryQty > 0 then
            recipe.yieldProductSum = (tonumber(recipe.yieldProductSum) or 0) + primaryQty
            recipe.yieldSamples = (tonumber(recipe.yieldSamples) or 0) + 1
            recipe.recipeYield = recipe.yieldProductSum / recipe.yieldSamples
        end
        if betterCount > 0 and goodUid == nil then
            recipe.brewSuperCrits = (tonumber(recipe.brewSuperCrits) or 0) + 1
        end
        if volatileCount > 0 and betterCount == 0 and goodUid == nil then
            recipe.brewVolatiles = (tonumber(recipe.brewVolatiles) or 0) + 1
        end
        if mainConsumed == false then
            recipe.brewCrits = (tonumber(recipe.brewCrits) or 0) + 1
        end
        if goodUid then
            recipe.activeOutcomeUid = goodUid
            recipe.outputUid = goodUid
        elseif recipe.activeOutcomeUid == nil then
            for uid in pairs(byUid) do
                recipe.activeOutcomeUid = uid
                recipe.outputUid = uid
                break
            end
        end
    end

    recipes[fingerprint] = recipe
    -- Defensive: tag liniment-class when main is a special liniment ingredient.
    if recipe.linimentClass ~= true then
        local ME = StockPiler3.MaterialExceptions
        for i = 1, #slots do
            local spec = slots[i] and slots[i].spec
            if type(spec) == "table" and tostring(spec.role or "") == "main" then
                if RS.IsLinimentClass(spec)
                    or (ME and ME.LooksLinimentIngredient and ME.LooksLinimentIngredient(spec))
                then
                    recipe.linimentClass = true
                    break
                end
            end
        end
    end
    if recipe.linimentClass == true then
        for uid in pairs(byUid) do
            local potions = PotionsTable()
            local row = type(potions) == "table" and potions[RS.PotionKeyFromUid(uid)]
            if type(row) == "table" then
                row.linimentClass = true
            end
        end
    end
    RS.SlimRecipeForStorage(recipe)
    local relinked = tonumber(RS.RelinkPotionRecipeKeysFromOutcomes()) or 0
    if relinked > 0 then
        structuralChange = true
    end

    if structuralChange
        and StockPiler3.Knowledge
        and StockPiler3.Knowledge.Touch
    then
        StockPiler3.Knowledge.Touch("recipe")
    end
    return true
end

--- One-time: rebuild recipe keys from MS.Key fingerprints; merge uid-bound duplicates;
--- relink potions + character watches.
function RS.MigrateRecipeFingerprintsV2()
    local acct = StockPiler3.Account
    if type(acct) ~= "table" then
        return false
    end
    local recipes = RecipesTable()
    -- Re-run when flagged complete but recipes still use legacy uid: fingerprints.
    local needsRepair = false
    if type(recipes) == "table" then
        for key, _ in pairs(recipes) do
            if type(key) == "string" and string.find(key, ":uid:", 1, true) then
                needsRepair = true
                break
            end
        end
    end
    if acct.recipeFingerprintMigrateV2 == true and needsRepair ~= true then
        return false
    end
    if type(recipes) ~= "table" then
        acct.recipeFingerprintMigrateV2 = true
        return false
    end
    local keyMap = {} -- oldKey -> newKey
    local rebuilt = {}
    for oldKey, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            HydrateRecipeSlots(recipe)
            local newKey = SlotsFingerprint(recipe.slots)
            if newKey == nil or newKey == "" then
                newKey = tostring(oldKey)
            end
            keyMap[tostring(oldKey)] = newKey
            local dest = rebuilt[newKey]
            if type(dest) ~= "table" then
                recipe.recipeSpecKey = newKey
                recipe.slots = SlimSlotsForStorage(recipe.slots)
                rebuilt[newKey] = recipe
            else
                -- Merge brew stats from duplicate (Fabricated vs normal key forms).
                local function addField(name)
                    dest[name] = (tonumber(dest[name]) or 0) + (tonumber(recipe[name]) or 0)
                end
                addField("brewAttempts")
                addField("brewSuccesses")
                addField("brewCrits")
                addField("brewSuperCrits")
                addField("brewFailures")
                addField("brewVolatiles")
                addField("yieldProductSum")
                addField("yieldSamples")
                addField("crafts")
                if type(recipe.outcomes) == "table" then
                    dest.outcomes = dest.outcomes or {}
                    for uid, row in pairs(recipe.outcomes) do
                        dest.outcomes[uid] = dest.outcomes[uid] or row
                    end
                end
                if (tonumber(dest.yieldSamples) or 0) > 0 then
                    dest.recipeYield = (tonumber(dest.yieldProductSum) or 0)
                        / (tonumber(dest.yieldSamples) or 1)
                end
            end
        end
    end
    -- Replace recipes table in place.
    for k in pairs(recipes) do
        recipes[k] = nil
    end
    for k, v in pairs(rebuilt) do
        recipes[k] = v
    end

    -- Relink potion recipeKeys.
    local potions = PotionsTable()
    if type(potions) == "table" then
        for _, potion in pairs(potions) do
            if type(potion) == "table" and type(potion.recipeKeys) == "table" then
                local seen = {}
                local nextKeys = {}
                for i = 1, #potion.recipeKeys do
                    local old = tostring(potion.recipeKeys[i] or "")
                    local neu = keyMap[old] or old
                    if neu ~= "" and seen[neu] ~= true then
                        seen[neu] = true
                        nextKeys[#nextKeys + 1] = neu
                    end
                end
                potion.recipeKeys = nextKeys
                potion.alternateRecipeSpecKeys = nextKeys
            end
        end
    end

    -- Relink character watches (all characters in Settings).
    local settings = StockPiler3.Settings
    if type(settings) == "table" and type(settings.characters) == "table" then
        for _, char in pairs(settings.characters) do
            if type(char) == "table" and type(char.watches) == "table" then
                local nextWatches = {}
                for watchKey, watch in pairs(char.watches) do
                    if type(watch) == "table" then
                        local parsed = RS.ParsePotionRecipeKey and RS.ParsePotionRecipeKey(watchKey)
                        local newWatchKey = watchKey
                        if type(parsed) == "table" and parsed.recipeSpecKey then
                            local neuRk = keyMap[tostring(parsed.recipeSpecKey)]
                                or tostring(parsed.recipeSpecKey)
                            local outUid = tonumber(parsed.outputUid) or 0
                            if RS.PotionRecipeKey and outUid > 0 then
                                newWatchKey = RS.PotionRecipeKey(outUid, neuRk)
                            end
                        end
                        if watch.recipeSpecKey then
                            watch.recipeSpecKey = keyMap[tostring(watch.recipeSpecKey)]
                                or watch.recipeSpecKey
                        end
                        if watch.potionKey == nil and type(parsed) == "table" then
                            watch.potionKey = parsed.potionKey
                        end
                        nextWatches[newWatchKey] = watch
                    end
                end
                char.watches = nextWatches
            end
        end
    end

    acct.recipeFingerprintMigrateV2 = true
    if StockPiler3.Knowledge and StockPiler3.Knowledge.Touch then
        StockPiler3.Knowledge.Touch("recipe-fingerprint-migrate-v2")
    end
    return true
end

--- One-shot: canonicalize fingerprints (load-order independent); merge order-duplicate recipes.
function RS.MigrateRecipeFingerprintsV3()
    local acct = StockPiler3.Account
    if type(acct) ~= "table" then
        return false
    end
    if acct.recipeFingerprintMigrateV3 == true then
        return false
    end
    local recipes = RecipesTable()
    if type(recipes) ~= "table" then
        acct.recipeFingerprintMigrateV3 = true
        return false
    end

    local function MergeRecipeStats(dest, recipe)
        local function addField(name)
            dest[name] = (tonumber(dest[name]) or 0) + (tonumber(recipe[name]) or 0)
        end
        addField("brewAttempts")
        addField("brewSuccesses")
        addField("brewCrits")
        addField("brewSuperCrits")
        addField("brewFailures")
        addField("brewVolatiles")
        addField("yieldProductSum")
        addField("yieldSamples")
        addField("crafts")
        if type(recipe.outcomes) == "table" then
            dest.outcomes = dest.outcomes or {}
            for uid, row in pairs(recipe.outcomes) do
                local existing = dest.outcomes[uid]
                if type(existing) ~= "table" then
                    dest.outcomes[uid] = row
                elseif type(row) == "table" then
                    existing.successes = (tonumber(existing.successes) or 0)
                        + (tonumber(row.successes) or 0)
                    existing.productSum = (tonumber(existing.productSum) or 0)
                        + (tonumber(row.productSum) or 0)
                    if (tonumber(row.yield) or 0) > (tonumber(existing.yield) or 0) then
                        existing.yield = row.yield
                    end
                end
            end
        end
        if (tonumber(dest.yieldSamples) or 0) > 0 then
            dest.recipeYield = (tonumber(dest.yieldProductSum) or 0)
                / (tonumber(dest.yieldSamples) or 1)
        end
    end

    local keyMap = {}
    local rebuilt = {}
    for oldKey, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            HydrateRecipeSlots(recipe)
            local newKey = SlotsFingerprint(recipe.slots)
            if newKey == nil or newKey == "" then
                newKey = tostring(oldKey)
            end
            keyMap[tostring(oldKey)] = newKey
            local dest = rebuilt[newKey]
            if type(dest) ~= "table" then
                recipe.recipeSpecKey = newKey
                recipe.slots = SlimSlotsForStorage(recipe.slots)
                rebuilt[newKey] = recipe
            else
                MergeRecipeStats(dest, recipe)
            end
        end
    end
    for k in pairs(recipes) do
        recipes[k] = nil
    end
    for k, v in pairs(rebuilt) do
        recipes[k] = v
    end

    local potions = PotionsTable()
    if type(potions) == "table" then
        for _, potion in pairs(potions) do
            if type(potion) == "table" then
                local oldActive = tostring(
                    potion.activeRecipeKey
                        or potion.activeRecipeSpecKey
                        or potion.recipeSpecKey
                        or ""
                )
                local keys = CollectPotionRecipeKeyList(potion)
                local seen = {}
                local nextKeys = {}
                for i = 1, #keys do
                    local old = tostring(keys[i] or "")
                    local neu = keyMap[old] or old
                    if neu ~= "" and seen[neu] ~= true then
                        seen[neu] = true
                        nextKeys[#nextKeys + 1] = neu
                    end
                end
                ApplyPotionRecipeKeyList(potion, nextKeys)
                local neuActive = keyMap[oldActive] or oldActive
                if neuActive ~= "" and seen[neuActive] == true then
                    potion.activeRecipeKey = neuActive
                    potion.activeRecipeSpecKey = neuActive
                    potion.recipeSpecKey = neuActive
                elseif #nextKeys > 0 then
                    potion.activeRecipeKey = nextKeys[1]
                    potion.activeRecipeSpecKey = nextKeys[1]
                    potion.recipeSpecKey = nextKeys[1]
                end
            end
        end
    end

    local settings = StockPiler3.Settings
    if type(settings) == "table" and type(settings.characters) == "table" then
        for _, char in pairs(settings.characters) do
            if type(char) == "table" and type(char.watches) == "table" then
                local nextWatches = {}
                for watchKey, watch in pairs(char.watches) do
                    if type(watch) == "table" then
                        local parsed = RS.ParsePotionRecipeKey and RS.ParsePotionRecipeKey(watchKey)
                        local newWatchKey = watchKey
                        if type(parsed) == "table" and parsed.recipeSpecKey then
                            local neuRk = keyMap[tostring(parsed.recipeSpecKey)]
                                or tostring(parsed.recipeSpecKey)
                            local outUid = tonumber(parsed.outputUid) or 0
                            if RS.PotionRecipeKey and outUid > 0 then
                                newWatchKey = RS.PotionRecipeKey(outUid, neuRk)
                            end
                        end
                        if watch.recipeSpecKey then
                            watch.recipeSpecKey = keyMap[tostring(watch.recipeSpecKey)]
                                or watch.recipeSpecKey
                        end
                        if watch.potionKey == nil and type(parsed) == "table" then
                            watch.potionKey = parsed.potionKey
                        end
                        -- Prefer newer watch row if two keys collapse onto one.
                        if type(nextWatches[newWatchKey]) ~= "table" then
                            nextWatches[newWatchKey] = watch
                        end
                    end
                end
                char.watches = nextWatches
            end
        end
    end

    acct.recipeFingerprintMigrateV3 = true
    if StockPiler3.Knowledge and StockPiler3.Knowledge.Touch then
        StockPiler3.Knowledge.Touch("recipe-fingerprint-migrate-v3")
    end
    return true
end

-- Expose hydrate for planner
function RS.HydrateRecipeSlots(recipe)
    HydrateRecipeSlots(recipe)
end

function RS.ResolveSlotSpec(slot)
    return ResolveSlotSpec(slot)
end

function RS.SpecStabilityTotal(slots)
    return SpecStabilityTotal(slots)
end

--- Tops up stabilizer/goldweed when learned perCraft leaves stability ≤ 0 (MEDIUM/fail).
function RS.EffectiveSpecPerCraft(slot, slots)
    return EffectiveSpecPerCraft(slot, slots)
end

--- Engine HIGH (safe succeed) needs stability total > 0; == 0 is MEDIUM/risky.
function RS.RecipeIsStable(recipe)
    if type(recipe) ~= "table" then
        return false
    end
    HydrateRecipeSlots(recipe)
    return SpecStabilityTotal(recipe.slots) > 0
end

function RS.MaterialsToSpecSlots(materials)
    return MaterialsToSpecSlots(materials)
end

function RS.SlotsFingerprint(slots)
    return SlotsFingerprint(slots)
end

function RS.OutputQuality(out)
    return OutputQuality(out)
end

----------------------------------------------------------------
-- Planner shims — Grow/Refine call RecipeSpec; demand lives on Planner
----------------------------------------------------------------

local function PlannerMod()
    return StockPiler3.Planner
end

function RS.BuildBalancedSpecDemand(opts)
    local P = PlannerMod()
    if P and P.BuildBalancedSpecDemand then
        return P.BuildBalancedSpecDemand(opts)
    end
    return {}
end

function RS.CollectAutoGrowFocus()
    local P = PlannerMod()
    if P and P.CollectAutoGrowFocus then
        return P.CollectAutoGrowFocus()
    end
    return { maxBottleGap = nil, minCraftable = nil, watches = {} }
end

function RS.CollectAutoBuyFocus()
    local P = PlannerMod()
    if P and P.CollectAutoBuyFocus then
        return P.CollectAutoBuyFocus()
    end
    return { maxBottleGap = nil, minCraftable = nil, watches = {} }
end

function RS.WatchStillNeedsGrow(potion, recipe, target, watchKey)
    local P = PlannerMod()
    if P and P.WatchStillNeedsGrow then
        return P.WatchStillNeedsGrow(potion, recipe, target, watchKey) == true
    end
    -- Lean fallback: uncovered deficit.
    target = tonumber(target) or 0
    if target <= 0 or type(potion) ~= "table" then
        return false
    end
    local uid = tonumber(potion.outputUid) or 0
    local have = 0
    if StockPiler3.Inventory and StockPiler3.Inventory.CountByUid and uid > 0 then
        have = tonumber(StockPiler3.Inventory.CountByUid(uid)) or 0
    end
    return have < target
end

function RS.FocusSpecKeys(focus)
    local P = PlannerMod()
    if P and P.FocusSpecKeys then
        return P.FocusSpecKeys(focus)
    end
    return {}
end

function RS.FocusBottleneckForSpec(specKey, focus, demand)
    local P = PlannerMod()
    if P and P.FocusBottleneckForSpec then
        return P.FocusBottleneckForSpec(specKey, focus, demand)
    end
    return 0, 0
end

function RS.CollectAutoGrowSeedLines()
    local P = PlannerMod()
    if P and P.CollectAutoGrowSeedLines then
        return P.CollectAutoGrowSeedLines()
    end
    return {}
end

--- True when Seed Buffer is on and any growable refinable recipe line for this watch
--- is below the buffer (bag + in-ground + outstanding). Memoized per bag snapGen.
--- opts.seedUids: known seed uniqueIDs from plan tip / statusTipSlots — prefer these and
--- skip SeedMap.ResolveSeedForSpec / FindPlantUidForSpec (live Watch hitch path).
function RS.WatchHasSeedBufferShort(recipe, opts)
    if not (StockPiler3.Watch and StockPiler3.Watch.IsSeedBufferEnabled
        and StockPiler3.Watch.IsSeedBufferEnabled() == true)
    then
        return false
    end
    if type(recipe) ~= "table" then
        return false
    end
    opts = type(opts) == "table" and opts or {}
    local Inv = StockPiler3.Inventory
    local snapGen = Inv and Inv.GetSnapGen and tonumber(Inv.GetSnapGen()) or 0
    local recipeId = tostring(
        recipe.specKey or recipe.recipeSpecKey or recipe.key or recipe
    )
    local memo = RS._seedBufferShortMemo
    if type(memo) ~= "table" or tonumber(memo.snapGen) ~= snapGen then
        memo = { snapGen = snapGen, byRecipe = {} }
        RS._seedBufferShortMemo = memo
    end
    if memo.byRecipe[recipeId] ~= nil then
        return memo.byRecipe[recipeId] == true
    end

    local Refine = StockPiler3.Refine
    local buffer = StockPiler3.Watch.GetSeedBufferMin and StockPiler3.Watch.GetSeedBufferMin() or 5

    local function CreditForSeed(seedUid)
        seedUid = tonumber(seedUid) or 0
        if seedUid <= 0 then
            return nil
        end
        if Refine and Refine.GetSeedBudget then
            local budget = Refine.GetSeedBudget(seedUid)
            return tonumber(budget and budget.credit) or 0
        end
        if Inv and Inv.CountByUid then
            return tonumber(Inv.CountByUid(seedUid)) or 0
        end
        return 0
    end

    local function AnyKnownSeedShort(seedUids)
        if type(seedUids) ~= "table" or #seedUids == 0 then
            return nil
        end
        local any = false
        local checked = false
        for i = 1, #seedUids do
            local credit = CreditForSeed(seedUids[i])
            if credit ~= nil then
                checked = true
                if credit < buffer then
                    any = true
                    break
                end
            end
        end
        if not checked then
            return nil
        end
        return any
    end

    -- Hot path: plan tip / row-stamped seedUids — CountByUid budget only.
    local knownShort = AnyKnownSeedShort(opts.seedUids)
    if knownShort ~= nil then
        memo.byRecipe[recipeId] = knownShort
        return knownShort
    end

    local SM = StockPiler3.SeedMap
    if type(SM) ~= "table" or not SM.IsGrowableSpec then
        memo.byRecipe[recipeId] = false
        return false
    end
    if RS.HydrateRecipeSlots then
        RS.HydrateRecipeSlots(recipe)
    end

    -- Prefer snap-cached AutoGrow seed lines (one ResolveSeed storm per snap) over
    -- per-slot ResolveSeed inside this recipe walk.
    local lineByKey = nil
    local lines = RS.CollectAutoGrowSeedLines and RS.CollectAutoGrowSeedLines() or nil
    if type(lines) == "table" and #lines > 0 then
        lineByKey = {}
        for i = 1, #lines do
            local line = lines[i]
            local k = type(line) == "table" and tostring(line.specKey or "") or ""
            if k ~= "" then
                lineByKey[k] = line
            end
        end
    end

    local slots = recipe.slots or {}
    local seen = {}
    local short = false
    for i = 1, #slots do
        local slot = slots[i]
        local spec = slot and (slot.spec or (RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot)))
        if type(spec) == "table" and SM.IsGrowableSpec(spec) then
            if SM.IsOneWayHarvestSpec and SM.IsOneWayHarvestSpec(spec) == true then
                -- One-way: ignore for buffer short.
            else
                local productKey = SpecFingerprint(spec)
                if type(productKey) ~= "string" or productKey == "" then
                    local M = MS()
                    productKey = (M and M.ProductKey and M.ProductKey(spec)) or tostring(i)
                end
                if seen[productKey] ~= true then
                    seen[productKey] = true
                    local seedUid = 0
                    local line = lineByKey and lineByKey[productKey]
                    if type(line) ~= "table" then
                        local M = MS()
                        local pk = M and M.ProductKey and M.ProductKey(spec)
                        if type(pk) == "string" and pk ~= "" and lineByKey then
                            line = lineByKey[pk]
                        end
                    end
                    if type(line) == "table" then
                        seedUid = tonumber(line.seedUid) or 0
                    end
                    -- Cold miss only: ResolveSeed when seed lines cache has no mapping.
                    if seedUid <= 0 then
                        local seed = SM.ResolveSeedForSpec and SM.ResolveSeedForSpec(spec)
                        if type(seed) == "table" then
                            seedUid = tonumber(seed.uniqueID) or 0
                        end
                    end
                    if seedUid > 0 then
                        local credit = CreditForSeed(seedUid) or 0
                        if credit < buffer then
                            short = true
                            break
                        end
                    end
                end
            end
        end
    end
    memo.byRecipe[recipeId] = short
    return short
end

function RS.ShouldAutoGrowPotion(potionKey, watch)
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local Watch = StockPiler3.Watch
    if Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    if type(watch) ~= "table" then
        local watches = Watch and Watch.GetWatches and Watch.GetWatches() or {}
        watch = type(watches) == "table" and watches[tostring(potionKey or "")] or nil
    end
    return type(watch) == "table" and watch.enabled == true and watch.autoGrow == true
end
