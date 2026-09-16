----------------------------------------------------------------
-- StockPiler3 Buy -- AutoBuy at vendor (independent of AutoGrow)
-- Policy + IssueOne purchase. Callees above callers.
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Buy = StockPiler3.Buy or {}
local Buy = StockPiler3.Buy

Buy.BRASS_PER_GOLD = 10000
Buy.MAX_PURCHASES_PER_VISIT = 80
Buy.PENDING_BUY_TIMEOUT_SEC = 1.0
Buy.NO_SPEND_COOLDOWN_SEC = 2.0

Buy._jobsCache = nil
Buy._jobsCacheKey = nil
Buy._storeWasOpen = false
Buy._visitPurchases = 0
Buy._visitSpentBrass = 0
Buy._visitMoneyBrass = 0
Buy._visitBought = 0
Buy._visitStopReason = nil
Buy._visitAcquired = Buy._visitAcquired or {}
Buy._fillChatPending = Buy._fillChatPending or {}
Buy._allowPlantBuys = false
Buy._planArmedAfterFill = false
Buy._pendingBuy = nil
Buy._noSpendCooldownUntil = Buy._noSpendCooldownUntil or {}

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

local function LogBuy(msg)
    if StockPiler3.Debug and StockPiler3.Debug.LogOp then
        StockPiler3.Debug.LogOp("buy", msg)
    end
end

local function Emit(msg, force)
    local line = tostring(msg or "")
    if StockPiler3.Debug and StockPiler3.Debug.LogAlways then
        StockPiler3.Debug.LogAlways(line)
    elseif StockPiler3.Debug and StockPiler3.Debug.LogOp then
        StockPiler3.Debug.LogOp("buy", line)
    end
    if force == true and StockPiler3.Debug and StockPiler3.Debug.Print then
        StockPiler3.Debug.Print(line)
    end
end

local function PlayerMoneyBrass()
    local VA = StockPiler3.VendorAdapter
    if VA and VA.GetPlayerMoneyBrass then
        return tonumber(VA.GetPlayerMoneyBrass()) or 0
    end
    return 0
end

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function BagCountUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return 0
    end
    local Inv = StockPiler3.Inventory
    if Inv and Inv.CountByUid then
        return tonumber(Inv.CountByUid(uid)) or 0
    end
    return 0
end

local function IsUidOnCooldown(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return false
    end
    local untilT = tonumber(Buy._noSpendCooldownUntil[uid]) or 0
    if untilT <= 0 then
        return false
    end
    local now = NowSec()
    if now <= 0 then
        return false
    end
    if now >= untilT then
        Buy._noSpendCooldownUntil[uid] = nil
        return false
    end
    return true
end

local function ArmNoSpendCooldown(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return
    end
    local now = NowSec()
    if now <= 0 then
        return
    end
    Buy._noSpendCooldownUntil[uid] = now + (tonumber(Buy.NO_SPEND_COOLDOWN_SEC) or 2)
end

local function IsGrowableStoreItem(item)
    if type(item) ~= "table" then
        return false
    end
    local cult = tonumber(item.cultivationType) or 0
    local seed = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local spore = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
    return cult == seed or cult == spore
end

local function HasAltCurrency(item)
    local alt = item and item.altCurrency
    if type(alt) ~= "table" then
        return false
    end
    if #alt > 0 then
        return true
    end
    for _ in pairs(alt) do
        return true
    end
    return false
end

local function VisitAcquired(key)
    if key == nil then
        return 0
    end
    return tonumber(Buy._visitAcquired[key]) or 0
end

local function AddVisitAcquired(key, n)
    if key == nil then
        return
    end
    Buy._visitAcquired[key] = VisitAcquired(key) + (tonumber(n) or 0)
end

local function JobAcquireKey(job, item)
    if type(job) == "table" and job.acquireKey ~= nil then
        return tostring(job.acquireKey)
    end
    local uid = 0
    if type(item) == "table" then
        uid = tonumber(item.uniqueID) or tonumber(item.id) or 0
    end
    if uid <= 0 and type(job) == "table" then
        uid = tonumber(job.uid) or tonumber(job.uniqueID) or 0
    end
    if uid > 0 then
        return "uid:" .. tostring(uid)
    end
    if type(job) == "table" and job.specKey ~= nil then
        return "sk:" .. tostring(job.specKey)
    end
    return nil
end

local function ChatMaterialFill(uid, name, count, spentBrass)
    local CC = StockPiler3.CraftChatAdapter
    local gold = math.floor((tonumber(spentBrass) or 0) / (Buy.BRASS_PER_GOLD or 10000))
    if CC and CC.PrintWithItem then
        CC.PrintWithItem(
            "AutoBuy: " .. tostring(count) .. "x ",
            uid,
            name,
            " (spent " .. tostring(gold) .. "g)"
        )
    elseif CC and CC.Print then
        CC.Print("AutoBuy: " .. tostring(count) .. "x " .. tostring(name or "?")
            .. " (spent " .. tostring(gold) .. "g)")
    end
end

local function FlushFillChat()
    for key, row in pairs(Buy._fillChatPending) do
        if type(row) == "table" and (tonumber(row.count) or 0) > 0 then
            ChatMaterialFill(row.uid, row.name, row.count, row.spent)
        end
        Buy._fillChatPending[key] = nil
    end
end

local function NoteFillProgress(job, item, bought, unitCost)
    local key = JobAcquireKey(job, item) or "?"
    local row = Buy._fillChatPending[key]
    if type(row) ~= "table" then
        row = {
            uid = tonumber(item and item.uniqueID) or tonumber(job and job.uid) or 0,
            name = (item and item.name) or (job and job.name),
            count = 0,
            spent = 0,
            need = tonumber(job and job.deficit) or 0,
        }
        Buy._fillChatPending[key] = row
    end
    bought = tonumber(bought) or 0
    unitCost = tonumber(unitCost) or 0
    row.count = (tonumber(row.count) or 0) + bought
    row.spent = (tonumber(row.spent) or 0) + unitCost * bought
    local need = tonumber(row.need) or 0
    local acquired = VisitAcquired(key)
    if need > 0 and acquired >= need then
        ChatMaterialFill(row.uid, row.name, row.count, row.spent)
        Buy._fillChatPending[key] = nil
    end
end

--- Apply confirmed spend only (money/bag moved).
local function AccountConfirmedBuy(pending, liveMoney)
    if type(pending) ~= "table" then
        return
    end
    local qty = math.max(1, tonumber(pending.qty) or 1)
    local unitCost = tonumber(pending.unitCost) or 0
    local costTotal = tonumber(pending.costTotal) or (unitCost * qty)
    local key = pending.key
    Buy._visitPurchases = (tonumber(Buy._visitPurchases) or 0) + 1
    Buy._visitSpentBrass = (tonumber(Buy._visitSpentBrass) or 0) + costTotal
    Buy._visitBought = (tonumber(Buy._visitBought) or 0) + qty
    Buy._visitMoneyBrass = tonumber(liveMoney) or PlayerMoneyBrass()
    AddVisitAcquired(key, qty)
    if type(pending.job) == "table" and type(pending.item) == "table" then
        NoteFillProgress(pending.job, pending.item, qty, unitCost)
    end
    LogBuy(string.format(
        "purchase uid=%s qty=%d cost=%d spent=%d moneyLeft=%d remainingWas=%d",
        tostring(pending.uid or 0),
        qty,
        costTotal,
        tonumber(Buy._visitSpentBrass) or 0,
        tonumber(Buy._visitMoneyBrass) or 0,
        tonumber(pending.remainingWas) or 0
    ))
end

--- Resolve open pending buy: confirm spend, timeout no-spend, or still waiting.
--- @return "confirmed"|"waiting"|"no-spend"|nil
local function ResolvePendingBuy()
    local pending = Buy._pendingBuy
    if type(pending) ~= "table" then
        return nil
    end
    local live = PlayerMoneyBrass()
    local before = tonumber(pending.beforeMoney) or 0
    local costTotal = tonumber(pending.costTotal) or 0
    local qty = math.max(1, tonumber(pending.qty) or 1)
    local uid = tonumber(pending.uid) or 0
    local bagNow = BagCountUid(uid)
    local bagBefore = tonumber(pending.bagBefore) or 0
    local moneyOk = live > 0 and before > 0 and live <= (before - costTotal + 1)
    local bagOk = uid > 0 and bagNow >= (bagBefore + qty)
    if moneyOk or bagOk then
        AccountConfirmedBuy(pending, live > 0 and live or before)
        Buy._pendingBuy = nil
        return "confirmed"
    end
    local at = tonumber(pending.at) or 0
    local now = NowSec()
    local timeout = tonumber(Buy.PENDING_BUY_TIMEOUT_SEC) or 1
    if at > 0 and now > 0 and (now - at) >= timeout then
        if live <= 0 or live >= before then
            LogBuy(string.format(
                "buy-no-spend uid=%s qty=%d cost=%d before=%d live=%d bag=%d->%d",
                tostring(uid),
                qty,
                costTotal,
                before,
                live,
                bagBefore,
                bagNow
            ))
            ArmNoSpendCooldown(uid)
            Buy._pendingBuy = nil
            return "no-spend"
        end
        -- Money dropped some but not full cost yet — keep waiting briefly.
        if (now - at) < (timeout + 1) then
            return "waiting"
        end
        LogBuy(string.format(
            "buy-no-spend uid=%s partial before=%d live=%d",
            tostring(uid),
            before,
            live
        ))
        ArmNoSpendCooldown(uid)
        Buy._pendingBuy = nil
        return "no-spend"
    end
    return "waiting"
end

local function ChatVisitStop(reason)
    if Buy._visitStopReason ~= nil then
        return
    end
    Buy._visitStopReason = tostring(reason or "stop")
    FlushFillChat()
    local bought = tonumber(Buy._visitBought) or 0
    local spent = tonumber(Buy._visitSpentBrass) or 0
    local gold = math.floor(spent / (Buy.BRASS_PER_GOLD or 10000))
    local CC = StockPiler3.CraftChatAdapter
    if CC and CC.Print and bought > 0 then
        CC.Print("AutoBuy: visit stop (" .. Buy._visitStopReason
            .. ") bought=" .. tostring(bought) .. " spent=" .. tostring(gold) .. "g")
    end
    LogBuy("visit-stop " .. Buy._visitStopReason
        .. " bought=" .. tostring(bought) .. " spent=" .. tostring(spent))
end

local function ArmPlanAfterBuyFill(reason)
    if Buy._planArmedAfterFill == true then
        return
    end
    if (tonumber(Buy._visitBought) or 0) <= 0 then
        return
    end
    Buy._planArmedAfterFill = true
    -- Batch invalidate after visit — no per-purchase Flatten.
    if StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Invalidate then
        StockPiler3.PlanSnapshot.Invalidate()
    end
    if StockPiler3.Scheduler and StockPiler3.Scheduler.EnqueuePlanRebuild then
        StockPiler3.Scheduler.EnqueuePlanRebuild({ reason = reason or "buy-fill" })
    end
end

local function ResetVisit()
    Buy._visitPurchases = 0
    Buy._visitSpentBrass = 0
    Buy._visitMoneyBrass = PlayerMoneyBrass()
    Buy._visitBought = 0
    Buy._visitStopReason = nil
    Buy._visitAcquired = {}
    Buy._fillChatPending = {}
    Buy._planArmedAfterFill = false
    Buy._pendingBuy = nil
    Buy._noSpendCooldownUntil = {}
    Buy.InvalidateJobsCache()
end

local function BeginVisitIfNeeded()
    local VA = StockPiler3.VendorAdapter
    local open = VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
    if open and Buy._storeWasOpen ~= true then
        ResetVisit()
        local Caps = StockPiler3.TradeSkillCaps
        Buy._allowPlantBuys = not (Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true)
        if VA.RefreshMatchIndex then
            VA.RefreshMatchIndex()
        end
        if StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
            StockPiler3.Scheduler.WakeAutoBuy()
        end
        LogBuy("visit-open allowPlantBuys=" .. tostring(Buy._allowPlantBuys))
    elseif not open and Buy._storeWasOpen == true then
        ChatVisitStop("close")
        ArmPlanAfterBuyFill("store-close")
        Buy.InvalidateJobsCache()
    end
    Buy._storeWasOpen = open == true
    return open == true
end

----------------------------------------------------------------
-- Public settings / cache
----------------------------------------------------------------

function Buy.IsEnabled()
    local Watch = StockPiler3.Watch
    if not Watch or not Watch.IsAutoBuyEnabled or Watch.IsAutoBuyEnabled() ~= true then
        return false
    end
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanAutoBuy and Caps.CanAutoBuy() ~= true then
        return false
    end
    return true
end

function Buy.GetReserveGold()
    local Watch = StockPiler3.Watch
    if Watch and Watch.GetAutoBuyReserveGold then
        return Watch.GetAutoBuyReserveGold()
    end
    return 10
end

function Buy.GetBudgetGold()
    local Watch = StockPiler3.Watch
    if Watch and Watch.GetAutoBuyBudgetGold then
        return Watch.GetAutoBuyBudgetGold()
    end
    return 50
end

function Buy.InvalidateJobsCache()
    Buy._jobsCache = nil
    Buy._jobsCacheKey = nil
end

function Buy.ClearMoneyGateStop(via)
    if Buy._visitStopReason ~= "reserve" and Buy._visitStopReason ~= "budget" then
        return false
    end
    local was = Buy._visitStopReason
    Buy._visitStopReason = nil
    Buy._visitSpentBrass = 0
    Buy._visitBought = 0
    Buy._visitPurchases = 0
    Buy._visitAcquired = {}
    Buy._fillChatPending = {}
    Buy._pendingBuy = nil
    Buy._noSpendCooldownUntil = {}
    Buy._planArmedAfterFill = false
    Buy._visitMoneyBrass = PlayerMoneyBrass()
    Buy.InvalidateJobsCache()
    LogBuy(string.format(
        "resume clear-stop was=%s via=%s money=%d reserveGold=%d",
        tostring(was),
        tostring(via or "?"),
        tonumber(Buy._visitMoneyBrass) or 0,
        Buy.GetReserveGold()
    ))
    if StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
        StockPiler3.Scheduler.WakeAutoBuy()
    end
    return true
end

function Buy.OnMoneySettingsChanged()
    Buy.ClearMoneyGateStop("money-chip")
    Buy.InvalidateJobsCache()
    local VA = StockPiler3.VendorAdapter
    if VA and VA.IsStoreOpen and VA.IsStoreOpen() == true then
        if StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
            StockPiler3.Scheduler.WakeAutoBuy()
        end
    end
end

function Buy.OnStoreShow()
    local VA = StockPiler3.VendorAdapter
    if VA and VA.EnsureStoreHook then
        VA.EnsureStoreHook()
    end
    if VA and VA.FlushPendingStoreRefresh then
        VA.FlushPendingStoreRefresh()
    end
    BeginVisitIfNeeded()
    if StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
        StockPiler3.Scheduler.WakeAutoBuy()
    end
end

----------------------------------------------------------------
-- Jobs (fair max bottle-gap focus)
----------------------------------------------------------------

function Buy.CollectBuyJobs()
    local Inv = StockPiler3.Inventory
    local snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    local Caps = StockPiler3.TradeSkillCaps
    local skillHash = Caps and Caps.LevelsHash and Caps.LevelsHash() or ""
    local watchGen = StockPiler3.Watch and StockPiler3.Watch.GetGen and StockPiler3.Watch.GetGen() or 0
    local cacheKey = tostring(snapGen) .. ":" .. tostring(watchGen) .. ":" .. tostring(skillHash)
        .. ":" .. tostring(Buy._allowPlantBuys and 1 or 0)
    if type(Buy._jobsCache) == "table" and Buy._jobsCacheKey == cacheKey then
        return Buy._jobsCache
    end

    local jobs = {}
    local Planner = StockPiler3.Planner
    if Planner and Planner.CollectVendorBuyJobs then
        jobs = Planner.CollectVendorBuyJobs({
            allowPlantBuys = Buy._allowPlantBuys == true,
            fairFocus = true,
        }) or {}
    elseif StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.CollectVendorBuyJobs then
        jobs = StockPiler3.RecipeSpec.CollectVendorBuyJobs({
            allowPlantBuys = Buy._allowPlantBuys == true,
        }) or {}
    end

    -- Reject growables when CanAutoGrow (allowPlantBuys false).
    if Buy._allowPlantBuys ~= true and type(jobs) == "table" then
        local filtered = {}
        for i = 1, #jobs do
            local job = jobs[i]
            local growable = job and (job.growable == true or job.isGrowable == true)
            if not growable then
                filtered[#filtered + 1] = job
            end
        end
        jobs = filtered
    end

    Buy._jobsCache = jobs
    Buy._jobsCacheKey = cacheKey
    return jobs
end

function Buy.FindStoreMatch(job)
    if type(job) ~= "table" then
        return nil, 0
    end
    local VA = StockPiler3.VendorAdapter
    if not VA then
        return nil, 0
    end
    local MS = StockPiler3.MaterialSpec
    local uid = tonumber(job.uid) or tonumber(job.uniqueID) or 0
    local spec = job.spec
    local incomplete = type(spec) == "table" and spec.incomplete == true

    -- Incomplete: exact uid only.
    if incomplete and uid > 0 and VA.FindStoreRowsByUid then
        local rows = VA.FindStoreRowsByUid(uid)
        if type(rows) == "table" then
            for i = 1, #rows do
                local row = rows[i]
                local item = row and row.item or row
                if type(item) == "table" and not HasAltCurrency(item) then
                    return item, tonumber(row.cost) or tonumber(item.cost) or 0
                end
            end
        end
        return nil, 0
    end

    -- Prefer fingerprint match across store (Artisan's vs Fabricated vials, etc.).
    local index = VA.GetMatchIndex and VA.GetMatchIndex()
    if type(spec) == "table" and type(index) == "table" and type(index.rows) == "table"
        and MS and MS.Matches
    then
        local bestItem, bestCost = nil, nil
        for i = 1, #index.rows do
            local row = index.rows[i]
            local item = row and row.item
            if type(item) == "table" and not HasAltCurrency(item) then
                if row.canbuy == false then
                    -- skip sold-out / gated rows
                elseif Buy._allowPlantBuys ~= true and IsGrowableStoreItem(item) then
                    -- reject growables
                elseif MS.Matches(item, spec) == true then
                    local cost = tonumber(row.cost) or tonumber(item.cost) or 0
                    if bestItem == nil or cost < (bestCost or math.huge) then
                        bestItem = item
                        bestCost = cost
                    end
                    -- Exact uid hit wins immediately.
                    if uid > 0 and (tonumber(item.uniqueID) or 0) == uid then
                        return item, cost
                    end
                end
            end
        end
        if bestItem ~= nil then
            return bestItem, bestCost or 0
        end
    end

    -- Fallback: exact uid rows when no spec match.
    if uid > 0 and VA.FindStoreRowsByUid then
        local rows = VA.FindStoreRowsByUid(uid)
        if type(rows) == "table" then
            for i = 1, #rows do
                local row = rows[i]
                local item = row and row.item or row
                if type(item) == "table" and not HasAltCurrency(item) then
                    if Buy._allowPlantBuys ~= true and IsGrowableStoreItem(item) then
                        -- skip
                    else
                        return item, tonumber(row.cost) or tonumber(item.cost) or 0
                    end
                end
            end
        end
    end
    return nil, 0
end

----------------------------------------------------------------
-- IssueOne / tick
----------------------------------------------------------------

function Buy.IssueOne(opId)
    if Buy._visitStopReason ~= nil then
        return false
    end
    if not Buy.IsEnabled() then
        return false
    end
    local VA = StockPiler3.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        return false
    end
    if VA.IsBuybackView and VA.IsBuybackView() == true then
        return false
    end

    local Perf = StockPiler3.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Buy.IssueOne")
    end
    local function done(ok)
        if Perf and Perf.End then
            Perf.End("Buy.IssueOne")
        end
        return ok == true
    end

    -- Confirm or wait on in-flight broadcast before starting another buy.
    -- Waiting must return true so Orch keeps the buy tick (refine must not steal
    -- and SendUseItem a "plant" that closes the vendor).
    local pendingState = ResolvePendingBuy()
    if pendingState == "waiting" then
        if StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
            StockPiler3.Scheduler.WakeAutoBuy()
        end
        return done(true)
    end
    if pendingState == "confirmed" then
        if StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
            StockPiler3.Scheduler.WakeAutoBuy()
        end
        return done(true)
    end
    -- "no-spend" or nil → continue to next purchase attempt.

    local purchases = tonumber(Buy._visitPurchases) or 0
    if purchases >= (Buy.MAX_PURCHASES_PER_VISIT or 80) then
        ChatVisitStop("cap")
        ArmPlanAfterBuyFill("cap")
        return done(false)
    end

    local jobs = Buy.CollectBuyJobs()
    if type(jobs) ~= "table" or #jobs == 0 then
        if (tonumber(Buy._visitBought) or 0) > 0 then
            ArmPlanAfterBuyFill("idle-no-jobs")
        end
        return done(false)
    end

    -- Gate reserve/budget on live gold; spent is confirmed-only.
    local money = PlayerMoneyBrass()
    Buy._visitMoneyBrass = money
    local reserve = Buy.GetReserveGold() * (Buy.BRASS_PER_GOLD or 10000)
    local budget = Buy.GetBudgetGold() * (Buy.BRASS_PER_GOLD or 10000)
    local spent = tonumber(Buy._visitSpentBrass) or 0
    local reserveBlock = false
    local budgetBlock = false

    for i = 1, #jobs do
        local job = jobs[i]
        local item, unitCost = Buy.FindStoreMatch(job)
        unitCost = tonumber(unitCost) or 0
        if type(item) == "table" and unitCost > 0 then
            local key = JobAcquireKey(job, item)
            local slotNum = tonumber(item.slotNum)
            local uid = tonumber(item.uniqueID) or tonumber(item.id) or tonumber(job.uid) or 0
            if key == nil or slotNum == nil then
                LogBuy("skip bad-slot-or-key job=" .. tostring(job.specKey or job.uid or i))
            elseif IsUidOnCooldown(uid) then
                -- Recent buy-no-spend for this uid.
            else
                local deficit = tonumber(job.deficit) or 0
                local remaining = math.max(0, deficit - VisitAcquired(key))
                if remaining >= 1 then
                    local vendorMax = 100
                    local stackCount = tonumber(item.stackCount) or 1
                    if stackCount > 1 then
                        vendorMax = stackCount
                    end
                    local maxByReserve = math.floor((money - reserve) / unitCost)
                    local maxByBudget = math.floor((budget - spent) / unitCost)
                    local qty = math.min(remaining, vendorMax, maxByReserve, maxByBudget)
                    if qty < 1 then
                        if maxByReserve < 1 then
                            reserveBlock = true
                        elseif maxByBudget < 1 then
                            budgetBlock = true
                        end
                    else
                        local costTotal = unitCost * qty
                        if money - costTotal < reserve then
                            reserveBlock = true
                        else
                            local beforeMoney = money
                            local bagBefore = BagCountUid(uid)
                            local ok, err = VA.BuyItem(item, qty)
                            if ok ~= true then
                                LogBuy(string.format(
                                    "fail BuyItem slot=%d qty=%d err=%s",
                                    slotNum,
                                    qty,
                                    tostring(err)
                                ))
                                return done(false)
                            end
                            -- Broadcast only — confirm on money/bag movement next tick.
                            Buy._pendingBuy = {
                                beforeMoney = beforeMoney,
                                bagBefore = bagBefore,
                                unitCost = unitCost,
                                costTotal = costTotal,
                                qty = qty,
                                key = key,
                                uid = uid,
                                at = NowSec(),
                                job = job,
                                item = item,
                                remainingWas = remaining,
                            }
                            LogBuy(string.format(
                                "buy-pending uid=%s slot=%d qty=%d cost=%d before=%d opId=%s",
                                tostring(uid),
                                slotNum,
                                qty,
                                costTotal,
                                beforeMoney,
                                tostring(opId or "?")
                            ))
                            if StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
                                StockPiler3.Scheduler.WakeAutoBuy()
                            end
                            -- Same-frame confirm if money already moved.
                            local immediate = ResolvePendingBuy()
                            if immediate == "confirmed" then
                                return done(true)
                            end
                            if immediate == "no-spend" then
                                return done(false)
                            end
                            return done(true)
                        end
                    end
                end
            end
        end
    end

    if reserveBlock then
        ChatVisitStop("reserve")
        ArmPlanAfterBuyFill("reserve")
        return done(false)
    end
    if budgetBlock then
        ChatVisitStop("budget")
        ArmPlanAfterBuyFill("budget")
        return done(false)
    end
    return done(false)
end

function Buy.TryBuyNext()
    return Buy.IssueOne(nil)
end

function Buy.OnTick()
    if not BeginVisitIfNeeded() then
        return false
    end
    return Buy.IssueOne(nil)
end

function Buy.NeedsTick()
    if not Buy.IsEnabled() then
        return false
    end
    local VA = StockPiler3.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        return false
    end
    if Buy._visitStopReason ~= nil then
        return false
    end
    return true
end

function Buy.PollStorePresence()
    local VA = StockPiler3.VendorAdapter
    if VA and VA.FlushPendingStoreRefresh then
        VA.FlushPendingStoreRefresh()
    end
    BeginVisitIfNeeded()
end

function Buy.OnStoreUpdated(opts)
    opts = type(opts) == "table" and opts or {}
    Buy.InvalidateJobsCache()
    if StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
        StockPiler3.Scheduler.WakeAutoBuy()
    end
end

function Buy.OnPlanUpdated()
    local VA = StockPiler3.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        return
    end
    if not Buy.IsEnabled() then
        return
    end
    Buy.InvalidateJobsCache()
    if Buy._visitStopReason == nil and StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
        StockPiler3.Scheduler.WakeAutoBuy()
    end
end

function Buy.OnInventorySnapshot()
    -- Do not Flatten here; jobs rebuild on next Collect via snapGen key.
    Buy.InvalidateJobsCache()
    -- Bag deficit is truth: drop optimistic visit-acquired while store is open.
    if Buy._storeWasOpen == true then
        Buy._visitAcquired = {}
    end
    -- Inventory may confirm a pending buy via bag gain.
    if type(Buy._pendingBuy) == "table" then
        local state = ResolvePendingBuy()
        if state == "confirmed" and StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
            StockPiler3.Scheduler.WakeAutoBuy()
        end
    end
end

function Buy.DumpBuyPlan(opts)
    opts = type(opts) == "table" and opts or {}
    local force = opts.force == true
    if force and StockPiler3.Inventory and StockPiler3.Inventory.RefreshAllIfNeeded then
        StockPiler3.Inventory.RefreshAllIfNeeded({ force = true })
    end
    Buy.InvalidateJobsCache()
    BeginVisitIfNeeded()
    local jobs = Buy.CollectBuyJobs()
    Emit("=== buy plan ===", force)
    Emit(string.format(
        "enabled=%s reserveGold=%d budgetGold=%d storeOpen=%s allowPlantBuys=%s",
        tostring(Buy.IsEnabled()),
        Buy.GetReserveGold(),
        Buy.GetBudgetGold(),
        tostring(StockPiler3.VendorAdapter and StockPiler3.VendorAdapter.IsStoreOpen
            and StockPiler3.VendorAdapter.IsStoreOpen()),
        tostring(Buy._allowPlantBuys)
    ), force)
    Emit(string.format(
        "visit purchases=%d bought=%d spentBrass=%d stop=%s pending=%s money=%d",
        tonumber(Buy._visitPurchases) or 0,
        tonumber(Buy._visitBought) or 0,
        tonumber(Buy._visitSpentBrass) or 0,
        tostring(Buy._visitStopReason),
        tostring(type(Buy._pendingBuy) == "table"),
        PlayerMoneyBrass()
    ), force)
    Emit("--- jobs (" .. tostring(#jobs) .. ") ---", force)
    local meta = StockPiler3.Planner and StockPiler3.Planner._vendorBuyJobsMeta
    if type(meta) == "table" then
        Emit(string.format(
            "jobsMeta source=%s focusWatches=%s maxBottleGap=%s skippedContainers=%s",
            tostring(meta.source),
            tostring(meta.focusWatchCount),
            tostring(meta.maxBottleGap),
            tostring(meta.skippedContainers == true)
        ), force)
    end
    for i = 1, math.min(#jobs, 40) do
        local j = jobs[i]
        local role = tostring(j.role or "")
        local incomplete = type(j.spec) == "table" and j.spec.incomplete == true
        Emit(string.format(
            "  [%d] uid=%s deficit=%s role=%s incomplete=%s key=%s",
            i,
            tostring(j.uid or j.uniqueID),
            tostring(j.deficit),
            role,
            tostring(incomplete),
            tostring(j.specKey or j.acquireKey)
        ), force)
    end
    Emit("=== end buy plan ===", force)
end
