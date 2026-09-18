----------------------------------------------------------------
-- StockPiler3 Brew -- session FSM + load job + IssueOne perform
-- Phases idle -> loading -> loaded. Load: reset -> open -> clear -> load.
-- Callees above callers.
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Brew = StockPiler3.Brew or {}
local Brew = StockPiler3.Brew

Brew.ADOPT_BLOCK_SEC = 1.5
Brew.BREW_OP_LOCK_SEC = 1.25
-- After load-done, engine SuccessChance / GetSlottedItem can lag a few frames.
-- Unloading immediately loops load→unload while the footer stays lit.
Brew.LOAD_SETTLE_SEC = 1.25

Brew._session = Brew._session or { phase = "idle" }
Brew._job = nil
Brew._loadSource = nil -- "auto" | "manual"
Brew._brewOpLockUntil = 0
Brew._adoptBlockUntil = 0
Brew._loadSettleUntil = 0
Brew._canBrewCache = nil
Brew._canBrewCacheKey = nil
Brew._brewReadyLatched = false
Brew._readyNotifyKeys = nil -- nil = uninitialized (seed on first observe, no chat)
Brew._lastHasReady = nil
Brew._wasBusy = false
Brew._awaitingBrewComplete = false
Brew._busTokens = nil
Brew._eventHandlers = nil

local ROLE_LOAD_ORDER = {
    container = 1,
    main = 2,
    stabilizer = 3,
    goldweed = 3,
    extender = 4,
    multiplier = 5,
    stimulant = 5,
    ingredient = 6,
}

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function LogBrew(msg)
    if StockPiler3.Debug and StockPiler3.Debug.LogOp then
        StockPiler3.Debug.LogOp("brew", msg)
    end
end

local function AA()
    return StockPiler3.ApothecaryAdapter
end

local function GetSession()
    if type(Brew._session) ~= "table" then
        Brew._session = { phase = "idle" }
    end
    return Brew._session
end

local function SetSessionPhase(phase, reason)
    local session = GetSession()
    local prev = tostring(session.phase or "idle")
    phase = tostring(phase or "idle")
    session.phase = phase
    local Orch = StockPiler3.Orchestrator
    if Orch and Orch.SetBrewPhase then
        Orch.SetBrewPhase(phase == "idle" and nil or phase)
    end
    if prev ~= phase then
        LogBrew("session " .. prev .. "->" .. phase .. " reason=" .. tostring(reason or "?"))
    end
end

local function CurrentPlan()
    if StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.GetOrBuild then
        return StockPiler3.PlanSnapshot.GetOrBuild({ refresh = false })
    end
    if StockPiler3.Planner and StockPiler3.Planner.GetOrBuild then
        return StockPiler3.Planner.GetOrBuild({ refresh = false })
    end
    return StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Get and StockPiler3.PlanSnapshot.Get()
end

local function PotionOutputUid(rowOrSession)
    if type(rowOrSession) ~= "table" then
        return 0
    end
    local uid = tonumber(rowOrSession.uniqueID)
        or tonumber(rowOrSession.outputUid)
        or tonumber(rowOrSession.potionUid)
        or 0
    if uid <= 0 and type(rowOrSession.potionKey) == "string" then
        local m = string.match(rowOrSession.potionKey, "uid:(%d+)")
        uid = tonumber(m) or 0
    end
    if uid <= 0 and type(rowOrSession.potionRecipeKey) == "string" then
        local m = string.match(rowOrSession.potionRecipeKey, "uid:(%d+)")
        uid = tonumber(m) or 0
    end
    if uid <= 0 and type(rowOrSession.potionBaseKey) == "string" then
        local m = string.match(rowOrSession.potionBaseKey, "uid:(%d+)")
        uid = tonumber(m) or 0
    end
    return uid
end

--- Live bag count for the watch potion (nil if uid unknown / no inventory).
local function LivePotionHave(rowOrSession)
    local uid = PotionOutputUid(rowOrSession)
    if uid <= 0 then
        return nil
    end
    local Inv = StockPiler3.Inventory
    if Inv and Inv.CountByUid then
        return tonumber(Inv.CountByUid(uid)) or 0
    end
    return nil
end

local function PotionTargetMin(rowOrSession)
    if type(rowOrSession) ~= "table" then
        return 0
    end
    return tonumber(rowOrSession.potionMin) or tonumber(rowOrSession.target) or 0
end

--- True while bag stock is still below the watch target (live bags preferred).
local function RowNeedsMorePotions(rowOrSession)
    if type(rowOrSession) ~= "table" then
        return false
    end
    local min = PotionTargetMin(rowOrSession)
    if min <= 0 then
        return false
    end
    local live = LivePotionHave(rowOrSession)
    local have = live
    if have == nil then
        have = tonumber(rowOrSession.potionHave) or 0
    end
    return have < min
end

local function RowIsReadyToCraft(row)
    if type(row) ~= "table" then
        return false
    end
    -- Live bags win over stale plan deficit (prevents over-brew after target met).
    if not RowNeedsMorePotions(row) then
        return false
    end
    if (tonumber(row.potionDeficit) or 0) <= 0 then
        return false
    end
    if row.statusKey ~= "ready_to_craft" then
        return false
    end
    -- Cultivators: AutoBrew only for AutoGrow-armed watches.
    -- Apo/Butcher-only: Ready status is enough (no Cultivation to arm).
    local Caps = StockPiler3.TradeSkillCaps
    local canGrow = Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true
    if canGrow then
        local pk = row.potionKey or row.potionRecipeKey or row.id
        local Watch = StockPiler3.Watch
        local RS = StockPiler3.RecipeSpec
        if RS and RS.ShouldAutoGrowPotion then
            if RS.ShouldAutoGrowPotion(pk, nil) ~= true then
                return false
            end
        elseif Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() ~= true then
            return false
        elseif row.autoGrow ~= true then
            return false
        end
    end
    local craftable = tonumber(row.craftable) or 0
    if craftable <= 0 then
        return false
    end
    if row.craftableShared == true then
        return false
    end
    -- Wait until bags+craftable cover the watch target (partial mats → AutoGrow first).
    local have = tonumber(row.potionHave) or 0
    local target = tonumber(row.potionMin) or tonumber(row.target) or 0
    if target > 0 and (have + craftable) < target then
        return false
    end
    return true
end

local function RowCanPrematureLoad(row)
    -- Manual load: green Craftable only (buffer-safe; shared mats OK).
    if type(row) ~= "table" then
        return false
    end
    if row.craftableSafe == true then
        return true
    end
    if row.craftableSafe == false then
        return false
    end
    if (tonumber(row.craftable) or 0) <= 0 then
        return false
    end
    return row.seedBufferShort ~= true
end

local function CompareReadyWatch(a, b)
    local da = tonumber(a.potionDeficit) or 0
    local db = tonumber(b.potionDeficit) or 0
    if da ~= db then
        return da > db
    end
    return tostring(a.name or "") < tostring(b.name or "")
end

local function FindSessionRow()
    local session = GetSession()
    if session.phase == "idle" and session.potionKey == nil and session.rowId == nil then
        return nil
    end
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    if type(rows) ~= "table" then
        return nil
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            if session.rowId ~= nil and row.id == session.rowId then
                return row
            end
            if session.potionKey ~= nil and row.potionKey == session.potionKey then
                return row
            end
        end
    end
    return nil
end

local function SyncSessionStockFromBags(session)
    if type(session) ~= "table" then
        return
    end
    local live = LivePotionHave(session)
    if live == nil then
        local row = FindSessionRow()
        if type(row) == "table" then
            live = LivePotionHave(row)
            if (tonumber(session.uniqueID) or 0) <= 0 then
                session.uniqueID = PotionOutputUid(row)
            end
            if session.potionMin == nil then
                session.potionMin = PotionTargetMin(row)
            end
        end
    end
    if live == nil then
        return
    end
    session.potionHave = live
    local min = PotionTargetMin(session)
    if min > 0 then
        session.potionDeficit = math.max(0, min - live)
    end
end

--- Mark plan row stocked immediately so PickReadyWatch cannot re-arm from a stale plan.
local function PatchPlanRowTargetMet(session, liveHave)
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    if type(rows) ~= "table" or type(session) ~= "table" then
        return
    end
    local key = tostring(session.potionKey or session.rowId or "")
    local uid = PotionOutputUid(session)
    local have = tonumber(liveHave) or tonumber(session.potionHave) or 0
    local min = PotionTargetMin(session)
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local rowKey = tostring(row.potionKey or row.id or row.potionRecipeKey or "")
            local rowUid = PotionOutputUid(row)
            if (key ~= "" and rowKey == key) or (uid > 0 and rowUid == uid) then
                row.potionHave = have
                row.potionDeficit = math.max(0, min - have)
                if row.potionDeficit <= 0 then
                    local recipe = row.recipe
                    local bufferShort = false
                    local Watch = StockPiler3.Watch
                    local RS = StockPiler3.RecipeSpec
                    if Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true
                        and RS and RS.WatchHasSeedBufferShort and type(recipe) == "table"
                        and RS.ShouldAutoGrowPotion
                        and RS.ShouldAutoGrowPotion(row.potionKey or row.potionRecipeKey or row.id, nil) == true
                    then
                        local seedUids = row.seedBufferSeedUids
                        if type(seedUids) ~= "table" or #seedUids == 0 then
                            seedUids = {}
                            local tips = row.statusTipSlots
                            if type(tips) == "table" then
                                local seen = {}
                                for t = 1, #tips do
                                    local uid = tonumber(tips[t] and tips[t].seedUid) or 0
                                    if uid > 0 and seen[uid] ~= true then
                                        seen[uid] = true
                                        seedUids[#seedUids + 1] = uid
                                    end
                                end
                            end
                        end
                        bufferShort = RS.WatchHasSeedBufferShort(recipe, { seedUids = seedUids }) == true
                    end
                    if bufferShort then
                        row.statusKey = "need_seeds"
                        if StockPiler3.T then
                            row.statusText = StockPiler3.T("plan.status.need_seeds")
                        else
                            row.statusText = L"Seed buffer"
                        end
                    else
                        row.statusKey = "potion_stocked"
                        if StockPiler3.T then
                            row.statusText = StockPiler3.T("plan.status.potion_stocked")
                        else
                            row.statusText = L"Potions stocked"
                        end
                    end
                    row.craftable = 0
                end
                return
            end
        end
    end
end

local function RecipeIsStable(recipe)
    if type(recipe) ~= "table" then
        return false
    end
    local RS = StockPiler3.RecipeSpec
    if RS and RS.RecipeIsStable then
        return RS.RecipeIsStable(recipe) == true
    end
    if RS and RS.HydrateRecipeSlots then
        RS.HydrateRecipeSlots(recipe)
    end
    if RS and RS.SpecStabilityTotal then
        return (tonumber(RS.SpecStabilityTotal(recipe.slots)) or 0) > 0
    end
    -- Fallback: sum live slot.spec stability (exclude optional modifiers).
    local slots = recipe.slots
    if type(slots) ~= "table" then
        return false
    end
    local sum = 0
    for i = 1, #slots do
        local s = slots[i]
        if type(s) == "table" then
            local role = tostring(s.role or "")
            if role ~= "extender" and role ~= "multiplier" and role ~= "stimulant" then
                local spec = s.spec
                local stab = 0
                if type(spec) == "table" then
                    stab = tonumber(spec.stability) or 0
                end
                local per = math.max(1, tonumber(s.perCraft) or 1)
                sum = sum + stab * per
            end
        end
    end
    return sum > 0
end

local function RoleLoadRank(role)
    return ROLE_LOAD_ORDER[tostring(role or "")] or 99
end

local function AssignCraftingSlot(role, supplementSlot)
    role = tostring(role or "")
    if role == "container" then
        return (ApothecaryWindow and ApothecaryWindow.SLOT_CONTAINER) or 0, supplementSlot
    end
    if role == "main" then
        return (ApothecaryWindow and ApothecaryWindow.SLOT_DETERMINENT) or 1, supplementSlot
    end
    local maxSlot = (ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT3) or 4
    if supplementSlot > maxSlot then
        return nil, supplementSlot
    end
    return supplementSlot, supplementSlot + 1
end

--- Expand saved recipe slots into apo craft-slot steps.
--- Phase 1: every fingerprint role at learned perCraft (exact recipe — no skipped modifiers).
--- Phase 2: stabilizer top-ups into leftover slots only (does not drop phase-1 roles).
--- Returns steps, ok — ok=false if a saved role cannot be placed (refuse incomplete load).
local function BuildLoadSteps(recipe)
    local steps = {}
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return steps, false
    end
    local RS = StockPiler3.RecipeSpec
    if RS and RS.HydrateRecipeSlots then
        RS.HydrateRecipeSlots(recipe)
    end
    local sorted = {}
    for i = 1, #recipe.slots do
        local slot = recipe.slots[i]
        if type(slot) == "table" and RS and RS.ResolveSlotSpec then
            RS.ResolveSlotSpec(slot)
        end
        sorted[#sorted + 1] = slot
    end
    table.sort(sorted, function(a, b)
        local ra = RoleLoadRank(a and (a.role or a.materialRole))
        local rb = RoleLoadRank(b and (b.role or b.materialRole))
        if ra ~= rb then
            return ra < rb
        end
        return (tonumber(a and a.index) or 0) < (tonumber(b and b.index) or 0)
    end)

    local function slotUid(slot)
        local uid = tonumber(slot.uniqueID) or tonumber(slot.uid) or 0
        if uid <= 0 and type(slot.spec) == "table" then
            uid = tonumber(slot.spec.uid) or tonumber(slot.spec.uniqueID) or 0
        end
        return uid
    end

    local function appendStep(slot, role, uid, craftingSlot, perCraft)
        steps[#steps + 1] = {
            craftingSlot = craftingSlot,
            uniqueID = uid,
            uid = uid,
            role = role,
            optional = false,
            spec = slot.spec,
            perCraft = perCraft,
        }
    end

    local supplementSlot = (ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT1) or 2
    local placedStab = {}

    for i = 1, #sorted do
        local slot = sorted[i]
        if type(slot) == "table" then
            local perCraft = math.max(1, tonumber(slot.perCraft) or 1)
            local uid = slotUid(slot)
            local role = tostring(slot.role or slot.materialRole or "")
            for _ = 1, perCraft do
                local craftingSlot
                craftingSlot, supplementSlot = AssignCraftingSlot(role, supplementSlot)
                if craftingSlot == nil then
                    LogBrew(string.format(
                        "load phase1 fail role=%s uid=%s (no craft slot) — refuse incomplete recipe load",
                        role, tostring(uid)
                    ))
                    return steps, false
                end
                appendStep(slot, role, uid, craftingSlot, perCraft)
                if role == "stabilizer" or role == "goldweed" then
                    placedStab[slot] = (placedStab[slot] or 0) + 1
                end
            end
        end
    end

    for i = 1, #sorted do
        local slot = sorted[i]
        if type(slot) == "table" then
            local role = tostring(slot.role or slot.materialRole or "")
            if role == "stabilizer" or role == "goldweed" then
                local want = math.max(1, tonumber(slot.perCraft) or 1)
                if RS and RS.EffectiveSpecPerCraft then
                    want = tonumber(RS.EffectiveSpecPerCraft(slot, recipe.slots)) or want
                end
                local have = placedStab[slot] or 0
                local uid = slotUid(slot)
                while have < want do
                    local craftingSlot
                    craftingSlot, supplementSlot = AssignCraftingSlot(role, supplementSlot)
                    if craftingSlot == nil then
                        LogBrew(string.format(
                            "load stab top-up capped have=%d want=%d uid=%s",
                            have, want, tostring(uid)
                        ))
                        break
                    end
                    appendStep(slot, role, uid, craftingSlot, want)
                    have = have + 1
                    placedStab[slot] = have
                end
            end
        end
    end
    return steps, true
end

local function BrewRespectGrowReserve()
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local P = StockPiler3.Persistence
    if P and P.GetCharacterBucket then
        local row = P.GetCharacterBucket(false)
        if type(row) == "table" and row.brewRespectGrowReserve == false then
            return false
        end
    end
    return true
end

--- Find bag item matching recipe slot spec. Prefer non-growable (butcher twins)
--- over cult plants, then craft bag, then smaller stacks.
--- Incomplete mains: exact boundUid only. Rejects seeds/spores for apo load.
--- `reserved` tracks qty already claimed by earlier load steps (same bag slot).
--- Future UI toggle: Persistence brewPreferNonGrowableFirst (default on).
local function FindCraftingBagItemBySpec(wantSpec, exemplarUid, reserved)
    local MS = StockPiler3.MaterialSpec
    local SM = StockPiler3.SeedMap
    local BA = StockPiler3.BagAdapter
    local craftType = (EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING) or 4
    local invType = (EA_Window_Backpack and EA_Window_Backpack.TYPE_INVENTORY) or 2
    reserved = type(reserved) == "table" and reserved or nil

    local preferNonGrowable = true
    local P = StockPiler3.Persistence
    if P and P.GetCharacterBucket then
        local row = P.GetCharacterBucket(false)
        -- Default on; set brewPreferNonGrowableFirst=false to spend cult plants first.
        if type(row) == "table" and row.brewPreferNonGrowableFirst == false then
            preferNonGrowable = false
        end
    end

    local function reserveKey(bagType, bagSlot)
        return tostring(bagType or 0) .. ":" .. tostring(bagSlot or 0)
    end

    local function availQty(bagType, bagSlot, liveQty)
        local qty = tonumber(liveQty) or 1
        if qty < 1 then
            qty = 1
        end
        if not reserved then
            return qty
        end
        local used = tonumber(reserved[reserveKey(bagType, bagSlot)]) or 0
        return qty - used
    end

    --- Butcher / vendor twins are non-growable; cult plants are growable.
    local function itemIsGrowable(item)
        if type(item) ~= "table" or not (SM and SM.IsGrowableSpec) then
            return false
        end
        local probe = item
        if MS and MS.FromItemData then
            local spec = MS.FromItemData(item, nil)
            if type(spec) == "table" then
                if spec.name == nil then
                    spec.name = item.name
                end
                probe = spec
            end
        end
        return SM.IsGrowableSpec(probe) == true
    end

    if type(wantSpec) == "table" and wantSpec.incomplete == true then
        local bound = tonumber(wantSpec.boundUid) or tonumber(exemplarUid) or tonumber(wantSpec.uid) or 0
        if bound > 0 and BA and BA.FindSeedSlot then
            local bagSlot, item, bagType = BA.FindSeedSlot(bound)
            bagType = bagType or craftType
            if bagSlot and bagSlot > 0 then
                local live = tonumber(item and (item.stackCount or item.stackcount)) or 1
                if availQty(bagType, bagSlot, live) >= 1 then
                    return bagSlot, item, bagType, bound
                end
            end
        end
        return 0, nil, nil, bound
    end

    local bestSlot, bestItem, bestType, bestUid = 0, nil, nil, 0
    local bestQty = nil
    local bestIsCraft = false
    local bestIsGrowable = false

    local function consider(bagSlot, item, bagType, isCraft)
        if type(item) ~= "table" or (tonumber(bagSlot) or 0) <= 0 then
            return
        end
        if MS and MS.IsSeedOrSpore and MS.IsSeedOrSpore(item) == true then
            return
        end
        local match = false
        if type(wantSpec) == "table" and MS and MS.Matches then
            match = MS.Matches(item, wantSpec) == true
            -- Bag AsItemData is often bonus-thin; enrich from learned Items.
            if not match and StockPiler3.Items and StockPiler3.Items.ToSpec then
                local iuid = tonumber(item.uniqueID) or 0
                if iuid > 0 then
                    local learned = StockPiler3.Items.ToSpec(iuid)
                    if type(learned) == "table" then
                        match = MS.Matches(learned, wantSpec) == true
                    end
                end
            end
        end
        if not match then
            return
        end
        local liveQty = tonumber(item.stackCount) or tonumber(item.stackcount) or 1
        local qty = availQty(bagType, bagSlot, liveQty)
        if qty < 1 then
            return
        end
        local uid = tonumber(item.uniqueID) or 0
        local growable = itemIsGrowable(item)
        local take = false
        if bestSlot <= 0 then
            take = true
        elseif preferNonGrowable and (not growable) and bestIsGrowable then
            -- Spend butcher/vendor twins before cult plants (bonus stock).
            take = true
        elseif preferNonGrowable and growable and not bestIsGrowable then
            take = false
        elseif isCraft and not bestIsCraft then
            take = true
        elseif (not isCraft) and bestIsCraft then
            take = false
        elseif isCraft == bestIsCraft and qty < (bestQty or 999999) then
            take = true
        end
        if take then
            bestSlot = bagSlot
            bestItem = item
            bestType = bagType
            bestUid = uid
            bestQty = qty
            bestIsCraft = isCraft == true
            bestIsGrowable = growable == true
        end
    end

    if BA and BA.FetchLight and BA.IterateSlots then
        local bags = BA.FetchLight()
        local craftBagType = "craft"
        -- Pass 1: craft bag
        for i = 1, #bags do
            local bag = bags[i]
            if bag and tostring(bag.bagType or "") == craftBagType then
                BA.IterateSlots(bag, function(_bt, slotNum, item)
                    consider(slotNum, item, craftType, true)
                end)
            end
        end
        -- Pass 2: inventory
        for i = 1, #bags do
            local bag = bags[i]
            if bag and tostring(bag.bagType or "") ~= craftBagType then
                BA.IterateSlots(bag, function(_bt, slotNum, item)
                    consider(slotNum, item, invType, false)
                end)
            end
        end
    end

    -- Fallback: Inventory.ForEachItem (no bag slot numbers — try FindSeedSlot on matched uid).
    if bestSlot <= 0 and StockPiler3.Inventory and StockPiler3.Inventory.ForEachItem then
        StockPiler3.Inventory.ForEachItem(function(item)
            if type(item) ~= "table" then
                return
            end
            if MS and MS.IsSeedOrSpore and MS.IsSeedOrSpore(item) == true then
                return
            end
            if type(wantSpec) == "table" and MS and MS.Matches and MS.Matches(item, wantSpec) == true then
                local uid = tonumber(item.uniqueID) or 0
                if uid > 0 and BA and BA.FindSeedSlot then
                    local s, it, bt = BA.FindSeedSlot(uid)
                    if s and s > 0 then
                        consider(s, it or item, bt or craftType, bt == craftType)
                    end
                end
            elseif type(wantSpec) == "table" and MS and MS.Matches and StockPiler3.Items and StockPiler3.Items.ToSpec then
                local iuid = tonumber(item.uniqueID) or 0
                if iuid > 0 then
                    local learned = StockPiler3.Items.ToSpec(iuid)
                    if type(learned) == "table" and MS.Matches(learned, wantSpec) == true then
                        if BA and BA.FindSeedSlot then
                            local s, it, bt = BA.FindSeedSlot(iuid)
                            if s and s > 0 then
                                consider(s, it or item, bt or craftType, bt == craftType)
                            end
                        end
                    end
                end
            end
        end)
    end

    return bestSlot, bestItem, bestType, bestUid
end

--- Auto holds that pause Ready brew (plant/refine/harvest). Seed buffer is per-watch
--- (Ready already means that watch's cushion is met); unrelated shorts must not block.
local function AutoBrewBlocked()
    local Grow = StockPiler3.Grow
    if Grow and Grow.HasPendingPlant and Grow.HasPendingPlant() == true then
        return true, "pending-plant"
    end
    local RP = StockPiler3.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        return true, "refine"
    end
    if Grow and Grow.IsHarvestOpActive and Grow.IsHarvestOpActive() == true then
        return true, "harvest"
    end
    return false, nil
end

--- Green Craftable: bags can craft and seed buffer is safe (shared mats OK).
local function RowCraftableGreen(row)
    if type(row) ~= "table" then
        return false
    end
    if row.craftableSafe == true then
        return true
    end
    if row.craftableSafe == false then
        return false
    end
    if (tonumber(row.craftable) or 0) <= 0 then
        return false
    end
    return row.seedBufferShort ~= true
end

local function TBrew(key, tokens)
    if StockPiler3.T then
        return StockPiler3.T(key, tokens)
    end
    return towstring(tostring(key or ""))
end

local function ChatBrewBlocked(why)
    why = tostring(why or "")
    local CC = StockPiler3.CraftChatAdapter
    if not (CC and CC.Print) then
        return
    end
    local msg
    if why == "buffer" then
        msg = TBrew("brew.blocked_buffer")
    elseif why == "shared" then
        msg = TBrew("brew.blocked_shared")
    elseif why == "nothing" then
        msg = TBrew("brew.nothing_craftable")
    elseif why == "not_ready" then
        msg = TBrew("brew.not_ready")
    elseif why ~= "" then
        msg = TBrew("brew.blocked_engine", { why = why })
    else
        return
    end
    CC.Print(msg)
end

function Brew.AutoBrewBlockedReason()
    local blocked, why = AutoBrewBlocked()
    if blocked then
        return tostring(why or "blocked")
    end
    return nil
end

local function RequestFooterRefresh()
    if StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
        StockPiler3Window.RequestFooterRefresh()
    elseif StockPiler3.Ui and StockPiler3.Ui.RequestFooterRefresh then
        StockPiler3.Ui.RequestFooterRefresh()
    end
end

--- Force footer + macro tint even when CanBrewNow is unchanged (mid-craft greying).
local function ForceBrewUiRefresh()
    Brew.InvalidateCanBrewCache()
    RequestFooterRefresh()
    -- Row Load/Brew chrome must flip as soon as session phase changes.
    if StockPiler3TabWatch and StockPiler3TabWatch.InvalidateBrewChrome then
        StockPiler3TabWatch.InvalidateBrewChrome()
    end
    if StockPiler3.Ui and StockPiler3.Ui.MarkWatchUiDirty then
        StockPiler3.Ui.MarkWatchUiDirty()
    end
    if DoesWindowExist("StockPiler3Window")
        and WindowGetShowing("StockPiler3Window") == true
        and StockPiler3TabWatch
        and StockPiler3TabWatch.UpdateRows
    then
        StockPiler3TabWatch.UpdateRows()
    end
    if StockPiler3Window and StockPiler3Window.SyncActionReadiness then
        StockPiler3Window.SyncActionReadiness({ immediate = true })
    elseif StockPiler3.Macro and StockPiler3.Macro.RefreshMacroButtonAppearance then
        StockPiler3.Macro.RefreshMacroButtonAppearance({
            canBrew = Brew.CanBrewNow() == true,
        })
    end
end

local function ClearSession(opts)
    opts = type(opts) == "table" and opts or {}
    Brew._job = nil
    Brew._loadSource = nil
    Brew._awaitingBrewComplete = false
    Brew._postBrewClearArmed = false
    Brew._brewHaveBefore = nil
    Brew._loadSettleUntil = 0
    local session = GetSession()
    session.potionKey = nil
    session.rowId = nil
    session.name = nil
    session.potionDeficit = nil
    session.craftable = nil
    session.potionHave = nil
    session.potionMin = nil
    session.recipeYield = nil
    session.recipe = nil
    session.recipeSpecKey = nil
    session.potionRecipeKey = nil
    session.uniqueID = nil
    -- Set phase only via SetSessionPhase so loading->idle is logged.
    SetSessionPhase("idle", opts.reason or "clear")
    if opts.adoptBlock == true then
        Brew._adoptBlockUntil = NowSec() + (tonumber(Brew.ADOPT_BLOCK_SEC) or 1.5)
    end
    Brew.InvalidateCanBrewCache()
end

local function InLoadSettle()
    local untilT = tonumber(Brew._loadSettleUntil) or 0
    if untilT <= 0 then
        return false
    end
    local now = NowSec()
    if now <= 0 then
        return false
    end
    if now >= untilT then
        Brew._loadSettleUntil = 0
        return false
    end
    return true
end

--- Auto-unload on engine/board reasons only after post-load settle (and not mid-load).
--- board-incomplete must wait settle too — GetSlottedItem lags after AddCraftingItem.
local function ShouldAutoUnloadForEngine(why)
    why = tostring(why or "")
    local gated = why == "board-incomplete"
        or why == "missing-container-or-main"
        or string.find(why, "engine%-", 1, false) == 1
    if not gated then
        return false
    end
    if InLoadSettle() then
        return false
    end
    return true
end

----------------------------------------------------------------
-- Session / busy
----------------------------------------------------------------

function Brew.GetSession()
    return GetSession()
end

function Brew.ArmBrewOpLock(seconds)
    seconds = tonumber(seconds) or Brew.BREW_OP_LOCK_SEC
    if seconds < 0.4 then
        seconds = 0.4
    end
    local untilT = NowSec() + seconds
    local cur = tonumber(Brew._brewOpLockUntil) or 0
    if untilT > cur then
        Brew._brewOpLockUntil = untilT
    end
end

function Brew.ClearBrewOpLock()
    Brew._brewOpLockUntil = 0
end

function Brew.IsBusy()
    if type(Brew._job) == "table" then
        return true
    end
    local a = AA()
    if a and a.IsPerforming and a.IsPerforming() == true then
        return true
    end
    local lockUntil = tonumber(Brew._brewOpLockUntil) or 0
    if lockUntil > 0 then
        if NowSec() < lockUntil then
            return true
        end
        Brew._brewOpLockUntil = 0
    end
    return false
end

function Brew.BlocksHarvest()
    if type(Brew._job) == "table" then
        return true
    end
    local a = AA()
    if a and a.IsPerforming and a.IsPerforming() == true then
        return true
    end
    -- Only block while the board is mid-load. A sitting "loaded" recipe must not
    -- grey Harvest for minutes until a plan rebuild clears the session (watchplan).
    local phase = tostring(GetSession().phase or "idle")
    return phase == "loading"
end

function Brew.RecipeIsStable(recipe)
    return RecipeIsStable(recipe)
end

function Brew.BrewRespectGrowReserve()
    return BrewRespectGrowReserve()
end

----------------------------------------------------------------
-- Ready pick / CanBrewNow
----------------------------------------------------------------

function Brew.PickReadyWatch()
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() ~= true then
        return nil
    end
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    if type(rows) ~= "table" then
        return nil
    end
    local best = nil
    for i = 1, #rows do
        local row = rows[i]
        if RowIsReadyToCraft(row) then
            if best == nil or CompareReadyWatch(row, best) then
                best = row
            end
        end
    end
    return best
end

function Brew.HasReadyToCraft()
    return type(Brew.PickReadyWatch()) == "table"
end

function Brew.InvalidateCanBrewCache()
    Brew._canBrewCache = nil
    Brew._canBrewCacheKey = nil
end

function Brew.CanBrewNow()
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() ~= true then
        return false
    end
    if Brew.IsBusy() then
        return false
    end
    local session = GetSession()
    local phase = tostring(session.phase or "idle")

    -- Manual row loads: footer not lit for perform.
    if Brew._loadSource == "manual" then
        return false
    end

    if phase == "loaded" then
        -- Target met while still loaded: do not fall through to another watch.
        if not RowNeedsMorePotions(session) then
            return false
        end
        -- Auto board: enable only while this session row is uncontested Ready.
        -- (Drop craftOk loophole — fail/wrong-tier must darken Brew until Ready again.)
        return RowIsReadyToCraft(FindSessionRow())
    end

    local blocked = AutoBrewBlocked()
    if blocked then
        return false
    end

    return type(Brew.PickReadyWatch()) == "table"
end

--- Chat/sound when a watch newly enters uncontested Ready to brew.
--- Latches per potionKey — not CanBrewNow (busy mid-craft would re-fire every brew).
function Brew.MaybeNotifyBrewReady()
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    local nowReady = {}
    if type(rows) == "table" then
        for i = 1, #rows do
            local row = rows[i]
            if RowIsReadyToCraft(row) then
                local key = tostring(row.potionKey or row.potionRecipeKey or row.id or "")
                if key ~= "" then
                    nowReady[key] = row
                end
            end
        end
    end

    local any = next(nowReady) ~= nil
    local wasLatched = Brew._brewReadyLatched == true
    Brew._brewReadyLatched = any

    -- First observe after load: seed latches without chat/sound.
    if Brew._readyNotifyKeys == nil then
        local seeded = {}
        for key, _ in pairs(nowReady) do
            seeded[key] = true
        end
        Brew._readyNotifyKeys = seeded
        if wasLatched ~= any and StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
            StockPiler3Window.RequestFooterRefresh()
        end
        return
    end

    local prev = Brew._readyNotifyKeys
    local newly = {}
    for key, row in pairs(nowReady) do
        if prev[key] ~= true then
            newly[#newly + 1] = row
        end
    end

    local nextKeys = {}
    for key, _ in pairs(nowReady) do
        nextKeys[key] = true
    end
    Brew._readyNotifyKeys = nextKeys

    if wasLatched ~= any and StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
        StockPiler3Window.RequestFooterRefresh()
    end

    if #newly == 0 then
        return
    end

    local best = newly[1]
    for i = 2, #newly do
        if CompareReadyWatch(newly[i], best) then
            best = newly[i]
        end
    end
    local name = best and best.name
    if name == nil or name == L"" then
        if StockPiler3.T then
            name = StockPiler3.T("brew.potion_fallback")
        else
            name = L"potion"
        end
    elseif type(name) ~= "wstring" then
        name = towstring(tostring(name))
    end

    local msg = L"<icon10985> Ready - " .. name .. L"."
    if StockPiler3.T then
        msg = StockPiler3.T("brew.ready", { name = name })
    end
    if StockPiler3.Debug and StockPiler3.Debug.Print then
        StockPiler3.Debug.Print(msg)
    end
    local soundId = GameData and GameData.Sound and GameData.Sound.HELP_TIPS_HIGHTLIGHT_WINDOW
    if soundId and Sound and Sound.Play then
        Sound.Play(soundId)
    end
    if StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
        StockPiler3Window.RequestFooterRefresh()
    end
end

----------------------------------------------------------------
-- Load job FSM
----------------------------------------------------------------

local function BeginLoadJob(row, source)
    if type(row) ~= "table" then
        return false
    end
    local recipe = row.recipe
    if type(recipe) ~= "table" then
        local RS = StockPiler3.RecipeSpec
        local key = row.potionRecipeKey or row.potionKey or row.id
        if RS and RS.RecipeSpecForPotion and key ~= nil then
            recipe = RS.RecipeSpecForPotion(key)
        elseif RS and RS.GetRecipeForWatch then
            recipe = RS.GetRecipeForWatch(row)
        elseif RS and RS.GetRecipe and row.recipeSpecKey then
            recipe = RS.GetRecipe(row.recipeSpecKey)
        end
    end
    if type(recipe) ~= "table" then
        LogBrew("load skip no-recipe")
        return false
    end
    if StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.HydrateRecipeSlots then
        StockPiler3.RecipeSpec.HydrateRecipeSlots(recipe)
    end
    row.recipe = recipe
    Brew._loadSource = source or "auto"
    local steps, stepsOk = BuildLoadSteps(recipe)
    if stepsOk ~= true or type(steps) ~= "table" or #steps <= 0 then
        LogBrew("load skip incomplete-steps")
        return false
    end
    local recipeSpecKey = tostring(recipe.recipeSpecKey or recipe.key or "")
    if recipeSpecKey == "" and StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.SlotsFingerprint then
        recipeSpecKey = tostring(StockPiler3.RecipeSpec.SlotsFingerprint(recipe.slots) or "")
    end
    local stab = 0
    local RS = StockPiler3.RecipeSpec
    if RS and RS.SpecStabilityTotal then
        stab = tonumber(RS.SpecStabilityTotal(recipe.slots)) or 0
    end
    -- Bonus-sum is diagnostic only; perform gate uses engine SuccessChance.
    LogBrew(string.format(
        "load steps=%d bonusStabilitySum=%s recipeKey=%s",
        #steps, tostring(stab), recipeSpecKey
    ))
    for i = 1, #steps do
        local s = steps[i]
        LogBrew(string.format(
            "  step[%d] role=%s uid=%s craftSlot=%s",
            i, tostring(s.role), tostring(s.uid or s.uniqueID), tostring(s.craftingSlot)
        ))
    end
    Brew._job = {
        phase = "reset",
        row = row,
        recipe = recipe,
        recipeSpecKey = recipeSpecKey,
        slots = steps,
        index = 1,
        reserved = {}, -- bagType:bagSlot -> qty claimed by prior steps
        at = NowSec(),
    }
    local session = GetSession()
    session.potionKey = row.potionKey
    session.rowId = row.id
    session.name = row.name
    session.uniqueID = PotionOutputUid(row)
    session.potionDeficit = row.potionDeficit
    session.craftable = row.craftable
    session.potionHave = row.potionHave
    session.potionMin = row.potionMin or row.target
    session.recipeYield = row.recipeYield
        or (row.recipe and row.recipe.recipeYield)
        or 5
    session.recipe = recipe
    session.recipeSpecKey = recipeSpecKey
    session.potionRecipeKey = row.potionRecipeKey or row.id
    SyncSessionStockFromBags(session)
    if not RowNeedsMorePotions(session) then
        LogBrew("load abort target already met have="
            .. tostring(session.potionHave) .. "/" .. tostring(session.potionMin))
        ClearSession({ reason = "target-already-met" })
        return false
    end
    SetSessionPhase("loading", "begin-load")
    Brew.InvalidateCanBrewCache()
    return true
end

local OPEN_WAIT_TICKS = 90
local CLEAR_WAIT_TICKS = 90

--- Every saved recipe step must still be present on the apo board.
local function BoardCoversRecipe(recipe)
    if type(recipe) ~= "table" then
        return true
    end
    local a = AA()
    if not (a and a.GetSlottedItem) then
        return false
    end
    local steps = BuildLoadSteps(recipe)
    for i = 1, #steps do
        local step = steps[i]
        if type(step) == "table" then
            local craftSlot = tonumber(step.craftingSlot)
            if craftSlot == nil or a.GetSlottedItem(craftSlot) == nil then
                return false
            end
        end
    end
    return true
end

local function AbortIncompleteLoad(reason)
    reason = tostring(reason or "load-incomplete")
    LogBrew("load abort " .. reason)
    Brew._job = nil
    local a = AA()
    if a and a.ClearSlots then
        a.ClearSlots()
    end
    ClearSession({ reason = reason })
    ForceBrewUiRefresh()
end

local function AdvanceLoadJob()
    local job = Brew._job
    if type(job) ~= "table" then
        return false
    end
    local a = AA()
    if not a then
        ClearSession({ reason = "no-apo" })
        return false
    end
    local phase = tostring(job.phase or "reset")

    if phase == "reset" then
        job.phase = "open"
        job.waitTicks = 0
        return true
    end
    if phase == "open" then
        -- Stealth OpenWindow hides the apo UI; do not gate on IsWindowOpen.
        job.waitTicks = (tonumber(job.waitTicks) or 0) + 1
        local sessionReady = a.IsCraftingSessionActive and a.IsCraftingSessionActive() == true
        if not sessionReady then
            if a.OpenWindow then
                a.OpenWindow(GetSession())
            end
            if job.waitTicks > OPEN_WAIT_TICKS then
                LogBrew("load abort open-timeout skill="
                    .. tostring(a.CraftingSkillType and a.CraftingSkillType()))
                ClearSession({ reason = "open-timeout" })
                return false
            end
            return true
        end
        job.phase = "clear"
        job.waitTicks = 0
        return true
    end
    if phase == "clear" then
        job.waitTicks = (tonumber(job.waitTicks) or 0) + 1
        if a.ServerHasItems and a.ServerHasItems() == true then
            if a.ClearSlots then
                a.ClearSlots()
            end
            if job.waitTicks > CLEAR_WAIT_TICKS then
                LogBrew("load abort clear-timeout")
                ClearSession({ reason = "clear-timeout" })
                return false
            end
            return true
        end
        job.phase = "load"
        job.index = 1
        job.waitTicks = 0
        return true
    end
    if phase == "load" then
        local slots = job.slots
        local idx = tonumber(job.index) or 1
        if type(slots) ~= "table" or idx > #slots then
            -- All recipe steps were AddItem'd (a miss aborts above). Do not sync-check
            -- GetSlottedItem here — engine bag/board lag one or more frames after Add,
            -- which falsely aborted complete loads as load-incomplete.
            Brew._job = nil
            SetSessionPhase("loaded", "load-done")
            local session = GetSession()
            session.phase = "loaded"
            Brew._loadSettleUntil = NowSec() + (tonumber(Brew.LOAD_SETTLE_SEC) or 0.75)
            ForceBrewUiRefresh()
            return true
        end
        local slot = slots[idx]
        job.index = idx + 1
        if type(slot) ~= "table" then
            return true
        end
        local exemplarUid = tonumber(slot.uniqueID) or tonumber(slot.uid) or 0
        local want = slot.spec
        if type(want) ~= "table" and StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.ResolveSlotSpec then
            want = StockPiler3.RecipeSpec.ResolveSlotSpec(slot)
        end
        if type(job.reserved) ~= "table" then
            job.reserved = {}
        end
        local bagSlot, item, bagType, matchedUid = FindCraftingBagItemBySpec(want, exemplarUid, job.reserved)
        if bagSlot > 0 and a.AddItemToCrafting then
            local craftSlot = tonumber(slot.craftingSlot)
            if craftSlot == nil then
                craftSlot = tonumber(slot.craftSlot) or tonumber(slot.index)
            end
            if craftSlot == nil and slot.role == "container" then
                craftSlot = 0
            end
            local added = a.AddItemToCrafting(craftSlot, bagSlot, bagType)
            if added ~= true then
                LogBrew(string.format(
                    "load add-fail role=%s exemplar=%s bag=%s craftSlot=%s — abort",
                    tostring(slot.role), tostring(exemplarUid), tostring(bagSlot), tostring(craftSlot)
                ))
                AbortIncompleteLoad("load-add-fail-" .. tostring(slot.role or "?"))
                return false
            end
            local rkey = tostring(bagType or 0) .. ":" .. tostring(bagSlot)
            job.reserved[rkey] = (tonumber(job.reserved[rkey]) or 0) + 1
            LogBrew(string.format(
                "load add role=%s exemplar=%s matchedUid=%s bag=%s craftSlot=%s",
                tostring(slot.role),
                tostring(exemplarUid),
                tostring(matchedUid or (item and item.uniqueID) or 0),
                tostring(bagSlot),
                tostring(craftSlot)
            ))
        else
            -- Missing any saved recipe slot → abort (do not invent a stable partial board).
            LogBrew(string.format(
                "load miss role=%s exemplar=%s — abort exact recipe load",
                tostring(slot.role), tostring(exemplarUid)
            ))
            AbortIncompleteLoad("load-miss-" .. tostring(slot.role or "?"))
            return false
        end
        return true
    end
    return false
end

local function KickLoadJob()
    AdvanceLoadJob()
    AdvanceLoadJob()
end

----------------------------------------------------------------
-- Public load / clear / perform
----------------------------------------------------------------

function Brew.BeginForRow(row, opts)
    opts = type(opts) == "table" and opts or {}
    local source = opts.manual == true and "manual" or "auto"
    -- Auto holds: plant/refine/harvest. Seed buffer is per-watch Ready status.
    if source == "auto" then
        local blocked, why = AutoBrewBlocked()
        if blocked then
            LogBrew("auto load blocked " .. tostring(why))
            return false
        end
    end
    -- Manual skips AutoGrow holds (plant/harvest/refine).
    if BeginLoadJob(row, source) then
        KickLoadJob()
        return true
    end
    return false
end

function Brew.ClearLoadedSession(opts)
    opts = type(opts) == "table" and opts or {}
    local session = GetSession()
    local a = AA()
    -- Pass the brew session so CloseWindow honors _brewOwnedSession / stealth and
    -- actually ends the apo crafting session (passing `true` was treated as nil).
    if a and a.CloseWindow then
        a.CloseWindow(session)
    elseif a and a.ClearSlots then
        a.ClearSlots()
    end
    Brew._postBrewClearArmed = false
    ClearSession({ reason = opts.reason or "clear", adoptBlock = opts.adoptBlock == true })
    ForceBrewUiRefresh()
end

function Brew.OnRowCraftRightClick(row)
    -- R-click clear + 1.5s adopt block.
    Brew.ClearLoadedSession({ reason = "row-rclear", adoptBlock = true })
    return true
end

function Brew.OnRowCraftClick(row)
    if type(row) ~= "table" then
        return false
    end
    local session = GetSession()
    local rowKey = tostring(row.potionRecipeKey or row.id or row.potionKey or "")
    local sessKey = tostring(session.potionRecipeKey or session.potionKey or session.rowId or "")
    if session.phase == "loaded"
        and rowKey ~= ""
        and sessKey ~= ""
        and rowKey == sessKey
        and Brew._loadSource == "manual"
    then
        local ok = Brew.TryPerform(nil)
        if ok ~= true then
            ChatBrewBlocked(Brew._lastPerformBlockWhy or "not_ready")
        end
        return ok == true
    end
    if not RowCraftableGreen(row) then
        if (tonumber(row.craftable) or 0) > 0 and row.seedBufferShort == true then
            ChatBrewBlocked("buffer")
        elseif (tonumber(row.craftable) or 0) <= 0 then
            ChatBrewBlocked("nothing")
        else
            ChatBrewBlocked("not_ready")
        end
        return false
    end
    if not RowCanPrematureLoad(row) and not RowIsReadyToCraft(row) then
        ChatBrewBlocked("not_ready")
        return false
    end
    local ok = Brew.BeginForRow(row, { manual = true })
    if ok ~= true then
        ChatBrewBlocked("not_ready")
    end
    return ok == true
end

local function BoardHasContainerAndMain()
    local a = AA()
    if not (a and a.GetSlottedItem) then
        return false
    end
    local containerSlot = (ApothecaryWindow and ApothecaryWindow.SLOT_CONTAINER) or 0
    local mainSlot = (ApothecaryWindow and ApothecaryWindow.SLOT_DETERMINENT) or 1
    return a.GetSlottedItem(containerSlot) ~= nil and a.GetSlottedItem(mainSlot) ~= nil
end

--- Why perform is unsafe right now (or nil if ok). Bypasses stock UI stability cache.
local function PerformBlockReason()
    local a = AA()
    if not a then
        return "no-adapter"
    end
    if a.IsPerforming and a.IsPerforming() == true then
        return "performing"
    end
    if a.ServerHasItems and a.ServerHasItems() ~= true then
        return "empty-board"
    end
    if a.IsBrewableCraftState and a.IsBrewableCraftState() ~= true then
        return "bad-craft-state:" .. tostring(a.CraftingState and a.CraftingState() or "?")
    end
    -- Read GameData directly (not ApothecaryWindow.stabilityCurrentState).
    -- Stock SetStabilityState ignores INVALID(0), so the green hint can stick while
    -- SuccessChance is already INVALID after a mat change / depleting mid-brew.
    if a.SuccessChanceAllowsPerform and a.SuccessChanceAllowsPerform() ~= true then
        local chance = a.SuccessChance and a.SuccessChance() or "?"
        if a.WillDefinitelyFail and a.WillDefinitelyFail() == true then
            return "engine-will-fail:" .. tostring(chance)
        end
        return "engine-chance-unusable:" .. tostring(chance)
    end
    if not BoardHasContainerAndMain() then
        return "missing-container-or-main"
    end
    local session = GetSession()
    local recipe = session and session.recipe
    if type(recipe) ~= "table" and type(Brew._job) == "table" then
        recipe = Brew._job.recipe
    end
    if type(recipe) == "table" and BoardCoversRecipe(recipe) ~= true then
        return "board-incomplete"
    end
    return nil
end

function Brew.ValidateApothecaryPerform()
    return PerformBlockReason() == nil
end

function Brew.TryPerform(opId)
    local a = AA()
    Brew._lastPerformBlockWhy = nil
    -- Seed buffer is enforced via Ready status (and shared demotion); not a global perform gate.
    local why = PerformBlockReason()
    if why ~= nil then
        Brew._lastPerformBlockWhy = why
        LogBrew("perform blocked " .. tostring(why)
            .. " SuccessChance=" .. tostring(a and a.SuccessChance and a.SuccessChance() or "?")
            .. " uiDesync=" .. tostring(a and a.UiStabilityDesync and a.UiStabilityDesync()))
        -- Auto loads must not sit forever on a red / incomplete / INVALID board.
        if Brew._loadSource == "auto" and GetSession().phase == "loaded"
            and ShouldAutoUnloadForEngine(why)
        then
            Brew.ClearLoadedSession({ reason = why })
            ForceBrewUiRefresh()
        end
        return false
    end
    local Perf = StockPiler3.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Brew.TryPerform")
    end
    Brew.ArmBrewOpLock(Brew.BREW_OP_LOCK_SEC)
    local ok = a and a.Perform and a.Perform() == true
    if ok then
        Brew._awaitingBrewComplete = true
        Brew._brewHaveBefore = LivePotionHave(GetSession())
        LogBrew("perform opId=" .. tostring(opId or "?")
            .. " haveBefore=" .. tostring(Brew._brewHaveBefore))
        if StockPiler3.Scheduler and StockPiler3.Scheduler.EnqueueBagFlush then
            StockPiler3.Scheduler.EnqueueBagFlush(true)
        end
        -- Grey immediately; ForceBrewUiRefresh re-lits when busy clears.
        ForceBrewUiRefresh()
    end
    if Perf and Perf.End then
        Perf.End("Brew.TryPerform")
    end
    return ok == true
end

--- Returns "go" | "blocked"
function Brew.TryBrewClick()
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() ~= true then
        return "blocked"
    end
    if Brew.IsBusy() then
        return "blocked"
    end
    local session = GetSession()
    local phase = tostring(session.phase or "idle")

    if phase == "loaded" then
        if Brew._loadSource == "manual" then
            return "blocked"
        end
        SyncSessionStockFromBags(session)
        if not RowNeedsMorePotions(session) then
            PatchPlanRowTargetMet(session, session.potionHave)
            Brew.ClearLoadedSession({ reason = "click-target-met" })
            ForceBrewUiRefresh()
            return "blocked"
        end
        local deficitOk = (tonumber(session.potionDeficit) or 0) > 0
        local row = FindSessionRow()
        if deficitOk and RowNeedsMorePotions(session) and RowIsReadyToCraft(row) then
            if Brew.ValidateApothecaryPerform() == true then
                return "go"
            end
        end
        if not RowIsReadyToCraft(row) then
            Brew.ClearLoadedSession({ reason = "click-not-ready" })
            ForceBrewUiRefresh()
            return "blocked"
        end
        local have = tonumber(session.potionHave) or 0
        local min = tonumber(session.potionMin) or 0
        local covered = min <= 0 or (have + (tonumber(session.craftable) or 0)) >= min
        if not covered then
            Brew.ClearLoadedSession({ reason = "uncovered-wait-grow" })
            ForceBrewUiRefresh()
            return "blocked"
        end
    end

    if NowSec() < (tonumber(Brew._adoptBlockUntil) or 0) then
        return "blocked"
    end

    local nextRow = Brew.PickReadyWatch()
    if type(nextRow) == "table" then
        if BeginLoadJob(nextRow, "auto") then
            KickLoadJob()
            return "blocked" -- load started; perform next click
        end
    end
    return "blocked"
end

function Brew.BrewClick()
    local result = Brew.TryBrewClick()
    if result == "go" then
        return Brew.TryPerform(nil)
    end
    return false
end

function Brew.FirePerform()
    return Brew.TryPerform(nil)
end

----------------------------------------------------------------
-- Tick / closed-window sync
----------------------------------------------------------------

function Brew.Tick()
    if type(Brew._job) == "table" then
        local Perf = StockPiler3.Perf
        if Perf and Perf.Begin then
            Perf.Begin("Brew.LoadJob")
        end
        AdvanceLoadJob()
        if Perf and Perf.End then
            Perf.End("Brew.LoadJob")
        end
        return true
    end
    return false
end

function Brew.OnUpdate(timeElapsed)
    if type(Brew._job) == "table" then
        Brew.Tick()
    end
    local lockUntil = tonumber(Brew._brewOpLockUntil) or 0
    if lockUntil > 0 and NowSec() >= lockUntil then
        Brew._brewOpLockUntil = 0
        ForceBrewUiRefresh()
    end
    local busy = Brew.IsBusy() == true
    if Brew._wasBusy == true and busy ~= true then
        if Brew._awaitingBrewComplete == true then
            Brew._awaitingBrewComplete = false
            Brew.RefreshSessionAfterBrew()
        else
            ForceBrewUiRefresh()
        end
    end
    Brew._wasBusy = busy
end

--- Closed-window: live-patch Status; RequestFooterRefresh only when HasReadyToCraft flips.
function Brew.SyncLiveStatusClosedWindow()
    local had = Brew._lastHasReady
    local has = Brew.HasReadyToCraft()
    Brew._lastHasReady = has
    Brew.InvalidateCanBrewCache()
    if had ~= nil and had ~= has then
        RequestFooterRefresh()
    end
    Brew.MaybeNotifyBrewReady()
    return has
end

function Brew.OnCraftingUpdated()
    if GetSession().phase == "loaded" or GetSession().phase == "loading" then
        Brew.InvalidateCanBrewCache()
    end
    if Brew._awaitingBrewComplete == true then
        local a = AA()
        if not (a and a.IsPerforming and a.IsPerforming() == true) then
            Brew._awaitingBrewComplete = false
            Brew.RefreshSessionAfterBrew()
            return
        end
        return
    end
    -- Skip mid-load slot storms; re-tint after busy clears / lock expiry instead.
    if type(Brew._job) == "table" then
        return
    end
    -- Engine chance / incomplete board after mat change: unload auto (stock UI may still show green).
    if GetSession().phase == "loaded" and Brew._loadSource == "auto" then
        local why = PerformBlockReason()
        if why ~= nil and ShouldAutoUnloadForEngine(why) then
            local a = AA()
            LogBrew("crafting-updated unload auto reason=" .. tostring(why)
                .. " uiDesync=" .. tostring(a and a.UiStabilityDesync and a.UiStabilityDesync()))
            Brew.ClearLoadedSession({ reason = why })
            ForceBrewUiRefresh()
            return
        elseif why ~= nil and InLoadSettle() then
            local a = AA()
            LogBrew("crafting-updated settle hold reason=" .. tostring(why)
                .. " SuccessChance=" .. tostring(a and a.SuccessChance and a.SuccessChance() or "?"))
        end
    end
    -- Re-tint macros: engine greys ActionButtons during craft even when CanBrewNow
    -- stays true, and SyncActionReadiness would otherwise skip as "unchanged".
    ForceBrewUiRefresh()
end

--- After a brew completes: sync live stock; unload when target met or no longer Ready.
function Brew.RefreshSessionAfterBrew()
    local session = GetSession()
    if tostring(session.phase or "") ~= "loaded" then
        Brew._postBrewClearArmed = false
        Brew._brewHaveBefore = nil
        ForceBrewUiRefresh()
        return
    end
    local haveBefore = Brew._brewHaveBefore
    Brew._brewHaveBefore = nil
    -- Prefer live bag count (yield estimates under/over-count crits and lag).
    SyncSessionStockFromBags(session)
    local haveAfter = LivePotionHave(session)
    if haveAfter == nil then
        local yieldAdd = math.max(1, tonumber(session.recipeYield) or 2)
        session.potionHave = (tonumber(session.potionHave) or 0) + yieldAdd
        local min = PotionTargetMin(session)
        if min > 0 then
            session.potionDeficit = math.max(0, min - (tonumber(session.potionHave) or 0))
        elseif session.potionDeficit ~= nil then
            session.potionDeficit = math.max(0, (tonumber(session.potionDeficit) or 0) - yieldAdd)
        end
    end
    if session.craftable ~= nil then
        session.craftable = math.max(0, (tonumber(session.craftable) or 0) - 1)
    end
    -- Live-patch plan so Ready / Shared / Restocking reflects post-brew mats before gate.
    local PS = StockPiler3.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) == "table" and type(plan.rows) == "table"
        and StockPiler3.Planner and StockPiler3.Planner.PatchWatchRowsLiveCounts
    then
        StockPiler3.Planner.PatchWatchRowsLiveCounts(plan.rows, {
            syncSnapshot = true,
            allowWarmHave = true,
        })
    elseif StockPiler3.Scheduler and StockPiler3.Scheduler.EnqueuePlanRebuild then
        StockPiler3.Scheduler.EnqueuePlanRebuild()
    end
    local stillValid = Brew.ValidateApothecaryPerform() == true
    local craftLeft = tonumber(session.craftable) or 0
    local deficit = tonumber(session.potionDeficit)
    if deficit == nil and PotionTargetMin(session) > 0 then
        deficit = math.max(0, PotionTargetMin(session) - (tonumber(session.potionHave) or 0))
        session.potionDeficit = deficit
    end
    deficit = tonumber(deficit) or 0
    -- Live bags are SoT: treat target-met even if deficit field lagged.
    if not RowNeedsMorePotions(session) then
        deficit = 0
        session.potionDeficit = 0
    end

    local advanced = nil
    if haveBefore ~= nil and haveAfter ~= nil then
        advanced = haveAfter > haveBefore
    end

    LogBrew(string.format(
        "after-brew have=%s/%s deficit=%s craftable=%s phase=%s valid=%s advanced=%s",
        tostring(session.potionHave),
        tostring(session.potionMin),
        tostring(deficit),
        tostring(session.craftable),
        tostring(session.phase),
        tostring(stillValid),
        tostring(advanced)
    ))

    if deficit <= 0 then
        PatchPlanRowTargetMet(session, session.potionHave)
        if Brew._loadSource == "manual" and craftLeft > 0 and stillValid then
            -- Manual may keep an overstock board loaded; footer stays dark (CanBrewNow).
            SetSessionPhase("loaded", "after-brew-overstock")
            session.potionDeficit = 0
            Brew._postBrewClearArmed = false
            ForceBrewUiRefresh()
            return
        end
        LogBrew("target met — unload have=" .. tostring(session.potionHave)
            .. "/" .. tostring(session.potionMin))
        Brew.ClearLoadedSession({ reason = "after-brew-target-met" })
        return
    end
    if stillValid ~= true then
        Brew.ClearLoadedSession({ reason = "after-brew-board-empty" })
        return
    end
    -- Auto: leave board when this watch is no longer uncontested Ready (fail / wrong-tier /
    -- shared / buy / restocking). Footer stays dark until PickReadyWatch again.
    if Brew._loadSource ~= "manual" then
        local row = FindSessionRow()
        if not RowIsReadyToCraft(row) then
            Brew.ClearLoadedSession({ reason = "after-brew-not-ready" })
            return
        end
    end
    if Brew.MaybeClearLoadedIfCannotContinue("after-brew") then
        return
    end
    -- Bags often lag one snap behind Perform; re-check Ready / watch-uid advance then.
    Brew._postBrewClearArmed = true
    Brew._brewHaveBefore = haveBefore
    if StockPiler3.Scheduler and StockPiler3.Scheduler.EnqueueBagFlush then
        StockPiler3.Scheduler.EnqueueBagFlush(true)
    end
    ForceBrewUiRefresh()
end

--- Bag snap after brew: unload if target met, no longer Ready, or watch uid did not advance.
function Brew.OnInventorySnapshot()
    if Brew._postBrewClearArmed ~= true then
        return
    end
    local session = GetSession()
    if tostring(session.phase or "") ~= "loaded" then
        Brew._postBrewClearArmed = false
        Brew._brewHaveBefore = nil
        return
    end
    SyncSessionStockFromBags(session)
    if not RowNeedsMorePotions(session) then
        if Brew._loadSource == "manual"
            and (tonumber(session.craftable) or 0) > 0
            and Brew.ValidateApothecaryPerform() == true
        then
            session.potionDeficit = 0
            Brew._postBrewClearArmed = false
            Brew._brewHaveBefore = nil
            ForceBrewUiRefresh()
            return
        end
        PatchPlanRowTargetMet(session, session.potionHave)
        LogBrew("post-brew bag sync — unload have="
            .. tostring(session.potionHave) .. "/" .. tostring(session.potionMin))
        Brew.ClearLoadedSession({ reason = "after-brew-bags" })
        return
    end
    if Brew._loadSource ~= "manual" then
        local PS = StockPiler3.PlanSnapshot
        local plan = PS and PS.Get and PS.Get()
        if type(plan) == "table" and type(plan.rows) == "table"
            and StockPiler3.Planner and StockPiler3.Planner.PatchWatchRowsLiveCounts
        then
            StockPiler3.Planner.PatchWatchRowsLiveCounts(plan.rows, {
                syncSnapshot = true,
                allowWarmHave = true,
            })
        end
        local row = FindSessionRow()
        if not RowIsReadyToCraft(row) then
            Brew.ClearLoadedSession({ reason = "after-brew-inv-not-ready" })
            return
        end
        local haveBefore = Brew._brewHaveBefore
        local haveAfter = LivePotionHave(session)
        if haveBefore ~= nil and haveAfter ~= nil and haveAfter <= haveBefore then
            Brew.ClearLoadedSession({ reason = "after-brew-no-advance" })
            return
        end
    end
    if Brew.MaybeClearLoadedIfCannotContinue("after-brew-inv") then
        return
    end
    Brew._postBrewClearArmed = false
    Brew._brewHaveBefore = nil
end

function Brew.MaybeClearLoadedIfCannotContinue(reason)
    local session = GetSession()
    if tostring(session.phase or "") ~= "loaded" then
        return false
    end
    if Brew._loadSource == "manual" then
        return false
    end
    SyncSessionStockFromBags(session)
    local deficit = tonumber(session.potionDeficit) or 0
    local row = FindSessionRow()
    -- Unload when target met, or when this watch is no longer uncontested Ready
    -- (mats short / shared / buy / restocking — AutoGrow/AutoBuy must refill first).
    if deficit <= 0 or not RowNeedsMorePotions(session) or not RowIsReadyToCraft(row) then
        if deficit <= 0 or not RowNeedsMorePotions(session) then
            PatchPlanRowTargetMet(session, session.potionHave)
        end
        Brew.ClearLoadedSession({ reason = reason or "cannot-continue" })
        return true
    end
    return false
end

----------------------------------------------------------------
-- Events
----------------------------------------------------------------

function Brew.RegisterEventHandlers()
    if Brew._eventHandlers == true then
        return
    end
    Brew._eventHandlers = true
    local B = StockPiler3.EventBus
    local E = StockPiler3.Events
    Brew._busTokens = Brew._busTokens or {}
    if B and E then
        if E.CMD_BREW_LOAD then
            Brew._busTokens[#Brew._busTokens + 1] = B.Subscribe(E.CMD_BREW_LOAD, function(payload)
                local row = type(payload) == "table" and payload.row or nil
                if type(row) == "table" then
                    Brew.BeginForRow(row, { manual = payload and payload.manual == true })
                else
                    local ready = Brew.PickReadyWatch()
                    if ready then
                        Brew.BeginForRow(ready, { manual = false })
                    end
                end
            end)
        end
        if E.PLAN_UPDATED then
            Brew._busTokens[#Brew._busTokens + 1] = B.Subscribe(E.PLAN_UPDATED, function()
                Brew.InvalidateCanBrewCache()
                Brew.MaybeClearLoadedIfCannotContinue("plan-updated")
            end)
        end
        if E.SESSION_LOADED then
            Brew._busTokens[#Brew._busTokens + 1] = B.Subscribe(E.SESSION_LOADED, function()
                Brew._readyNotifyKeys = nil
                Brew._brewReadyLatched = false
                Brew.InvalidateCanBrewCache()
            end)
        end
        if E.INVENTORY_SNAPSHOT then
            Brew._busTokens[#Brew._busTokens + 1] = B.Subscribe(E.INVENTORY_SNAPSHOT, function()
                if Brew.OnInventorySnapshot then
                    Brew.OnInventorySnapshot()
                end
            end)
        end
    end
end

function Brew.UnregisterEventHandlers()
    local B = StockPiler3.EventBus
    local tokens = Brew._busTokens
    if B and B.Unsubscribe and type(tokens) == "table" then
        for i = 1, #tokens do
            B.Unsubscribe(tokens[i])
        end
    end
    Brew._busTokens = nil
    Brew._eventHandlers = nil
end

function Brew.DumpSession(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler3.Debug and StockPiler3.Debug.Print then
            StockPiler3.Debug.Print(msg)
        end
    end
    local session = GetSession()
    local aStat = AA()
    local engChance = aStat and aStat.SuccessChance and aStat.SuccessChance() or "?"
    local willFail = aStat and aStat.WillDefinitelyFail and aStat.WillDefinitelyFail() == true
    local allows = aStat and aStat.SuccessChanceAllowsPerform and aStat.SuccessChanceAllowsPerform() == true
    local uiDesync = aStat and aStat.UiStabilityDesync and aStat.UiStabilityDesync() == true
    local painted = (type(ApothecaryWindow) == "table") and tostring(ApothecaryWindow.stabilityCurrentState) or "?"
    emit(string.format(
        "  session phase=%s source=%s busy=%s canBrew=%s engChance=%s allows=%s willFail=%s uiDesync=%s painted=%s name=%s",
        tostring(session.phase),
        tostring(Brew._loadSource),
        tostring(Brew.IsBusy()),
        tostring(Brew.CanBrewNow()),
        tostring(engChance),
        tostring(allows),
        tostring(willFail),
        tostring(uiDesync),
        painted,
        tostring(session.name)
    ))
    local recipe = session.recipe
    if type(recipe) ~= "table" then
        recipe = Brew._job and Brew._job.recipe
    end
    if type(recipe) == "table" and type(recipe.slots) == "table" then
        local RS = StockPiler3.RecipeSpec
        if RS and RS.HydrateRecipeSlots then
            RS.HydrateRecipeSlots(recipe)
        end
        local stab = RS and RS.SpecStabilityTotal and RS.SpecStabilityTotal(recipe.slots) or "?"
        emit(string.format(
            "  recipe key=%s slots=%d bonusStabilitySum=%s",
            tostring(recipe.specKey or recipe.recipeSpecKey or recipe.key or ""),
            #recipe.slots,
            tostring(stab)
        ))
        for i = 1, #recipe.slots do
            local slot = recipe.slots[i]
            if type(slot) == "table" then
                local uid = tonumber(slot.uid) or 0
                if uid <= 0 and type(slot.spec) == "table" then
                    uid = tonumber(slot.spec.uid) or tonumber(slot.spec.uniqueID) or 0
                end
                local per = tonumber(slot.perCraft) or 1
                local eff = per
                if RS and RS.EffectiveSpecPerCraft then
                    eff = tonumber(RS.EffectiveSpecPerCraft(slot, recipe.slots)) or per
                end
                local stabSlot = 0
                if RS and RS.ResolveSlotSpec then
                    local spec = RS.ResolveSlotSpec(slot)
                    stabSlot = tonumber(spec and spec.stability) or 0
                elseif type(slot.spec) == "table" then
                    stabSlot = tonumber(slot.spec.stability) or 0
                end
                emit(string.format(
                    "    slot role=%s uid=%s per=%s eff=%s stab=%s key=%s",
                    tostring(slot.role), tostring(uid), tostring(per), tostring(eff), tostring(stabSlot),
                    (StockPiler3.MaterialSpec and StockPiler3.MaterialSpec.Key
                        and StockPiler3.MaterialSpec.Key(
                            (RS and RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot)) or slot.spec
                        )) or "?"
                ))
            end
        end
        local steps = BuildLoadSteps(recipe)
        emit(string.format("  loadSteps=%d", type(steps) == "table" and #steps or 0))
        if type(steps) == "table" then
            for i = 1, #steps do
                local s = steps[i]
                emit(string.format(
                    "    step[%d] role=%s uid=%s craftSlot=%s",
                    i, tostring(s.role), tostring(s.uid or s.uniqueID), tostring(s.craftingSlot)
                ))
            end
        end
    end
    if type(Brew._job) == "table" then
        emit(string.format(
            "  loadJob phase=%s index=%s/#%s",
            tostring(Brew._job.phase),
            tostring(Brew._job.index),
            type(Brew._job.slots) == "table" and tostring(#Brew._job.slots) or "?"
        ))
    end
end

function Brew.DumpPlan(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler3.Debug and StockPiler3.Debug.Print then
            StockPiler3.Debug.Print(msg)
        end
    end
    local session = GetSession()
    local blockedWhy = Brew.AutoBrewBlockedReason and Brew.AutoBrewBlockedReason() or nil
    emit("=== brew plan ===")
    emit("phase=" .. tostring(session.phase)
        .. " source=" .. tostring(Brew._loadSource)
        .. " busy=" .. tostring(Brew.IsBusy())
        .. " canBrew=" .. tostring(Brew.CanBrewNow())
        .. " autoBlocked=" .. tostring(blockedWhy or "no"))
    local Grow = StockPiler3.Grow
    local Refine = StockPiler3.Refine
    emit(string.format(
        "  bufferSatisfied=%s bufferShort=%s pendingRefine=%s pendingPlant=%s refineOut=%s",
        tostring(Grow and Grow.IsSeedBufferSatisfied and Grow.IsSeedBufferSatisfied()),
        tostring(Grow and Grow.HasAnyBufferShort and Grow.HasAnyBufferShort()),
        tostring(Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine()),
        tostring(Grow and Grow.HasPendingPlant and Grow.HasPendingPlant()),
        tostring(StockPiler3.RefinePipeline and StockPiler3.RefinePipeline.HasOutstanding
            and StockPiler3.RefinePipeline.HasOutstanding())
    ))
    emit("respectGrowReserve=" .. tostring(BrewRespectGrowReserve()))
    emit("hasReady=" .. tostring(Brew.HasReadyToCraft()))
    local ready = Brew.PickReadyWatch()
    if type(ready) == "table" then
        emit(string.format(
            "ready name=%s deficit=%s craftable=%s autoGrow=%s",
            tostring(ready.name), tostring(ready.potionDeficit), tostring(ready.craftable),
            tostring(ready.autoGrow == true)
        ))
    end
    Brew.DumpSession(emit)
    emit("=== end brew plan ===")
end
