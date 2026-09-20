----------------------------------------------------------------
-- StockPiler3 Adapters/VendorAdapter — NPC store + AutoBuy match index
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.VendorAdapter = StockPiler3.VendorAdapter or {}
local VA = StockPiler3.VendorAdapter

local STORE_WIN = "EA_Window_InteractionStore"
VA._storeHooked = false
VA._matchIndex = nil
VA._matchIndexGen = 0
VA._storeRefreshDue = false

local function TryQuiet(context, fn, ...)
    if StockPiler3.Debug and StockPiler3.Debug.TryCallQuiet then
        return StockPiler3.Debug.TryCallQuiet(context, fn, ...)
    end
    if type(fn) ~= "function" then
        return false, nil
    end
    return pcall(fn, ...)
end

local function TryCall(context, fn, ...)
    if StockPiler3.Debug and StockPiler3.Debug.TryCall then
        return StockPiler3.Debug.TryCall(context, fn, ...)
    end
    return pcall(fn, ...)
end

--- Persist new store rows only (Touch once per new uid batch — no per-page spam).
--- Only Cultivation / Apothecary craft mats — never mounts, dyes, junk.
local function ApothecarySkillId()
    return (GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY) or 4
end

local function CultivationSkillId()
    return (GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION) or 3
end

local function CraftingFamilyBonus(item)
    if type(item) ~= "table" then
        return 0
    end
    local bonuses = item.craftingBonus or item.bonuses
    if type(bonuses) ~= "table" then
        return 0
    end
    for _, b in pairs(bonuses) do
        if type(b) == "table" then
            local ref = tonumber(b.bonusReference) or tonumber(b.reference) or 0
            -- CRAFTING_FAMILY / trade skill family is bonus 5 in WAR apo tooling.
            if ref == 5 then
                return tonumber(b.bonusValue) or tonumber(b.value) or 0
            end
        end
    end
    if bonuses[5] ~= nil then
        return tonumber(bonuses[5]) or 0
    end
    return 0
end

local function IsCraftRelevantVendorItem(item)
    if type(item) ~= "table" then
        return false
    end
    local cult = tonumber(item.cultivationType) or 0
    if cult ~= 0 then
        return true
    end
    local apo = ApothecarySkillId()
    local cultSkill = CultivationSkillId()
    local ts = tonumber(item.tradeSkill) or 0
    if ts == apo or ts == cultSkill then
        return true
    end
    local family = CraftingFamilyBonus(item)
    if family == apo or family == cultSkill then
        return true
    end
    local uid = tonumber(item.uniqueID) or tonumber(item.id) or 0
    if uid > 0 and StockPiler3.Items and StockPiler3.Items.GetByUid then
        local row = StockPiler3.Items.GetByUid(uid)
        if type(row) == "table" then
            if (tonumber(row.cultivationType) or 0) ~= 0 then
                return true
            end
            local rts = tonumber(row.tradeSkill) or 0
            if rts == apo or rts == cultSkill then
                return true
            end
        end
    end
    local MS = StockPiler3.MaterialSpec
    if MS and MS.FromItemData then
        local ok, spec = pcall(MS.FromItemData, item)
        if ok == true and type(spec) == "table" then
            if (tonumber(spec.cultivationType) or 0) ~= 0 then
                return true
            end
            local sts = tonumber(spec.tradeSkill) or 0
            if sts == apo or sts == cultSkill then
                return true
            end
        end
    end
    return false
end

local function LearnVendorRows(list)
    if type(list) ~= "table" then
        return 0
    end
    local Know = StockPiler3.Knowledge
    local vendorItems = Know and Know.VendorItems and Know.VendorItems()
    if type(vendorItems) ~= "table" then
        return 0
    end
    local added = 0
    local function consider(item)
        if type(item) ~= "table" then
            return
        end
        local uid = tonumber(item.uniqueID) or tonumber(item.id) or 0
        if uid <= 0 then
            return
        end
        if not IsCraftRelevantVendorItem(item) then
            return
        end
        -- Seed Items DB so fingerprint Matches can enrich thin store rows (flasks).
        if StockPiler3.Items and StockPiler3.Items.StoreItem then
            StockPiler3.Items.StoreItem(item, "vendor")
        end
        local key = tostring(uid)
        if type(vendorItems[key]) == "table" then
            return
        end
        vendorItems[key] = {
            uniqueID = uid,
            name = item.name,
            iconNum = tonumber(item.iconNum) or 0,
            cost = tonumber(item.cost) or 0,
            cultivationType = tonumber(item.cultivationType) or 0,
            tradeSkill = tonumber(item.tradeSkill) or CraftingFamilyBonus(item) or 0,
        }
        added = added + 1
    end
    local n = 0
    for _, item in ipairs(list) do
        consider(item)
        n = n + 1
    end
    if n == 0 then
        for _, item in pairs(list) do
            consider(item)
        end
    end
    if added > 0 and Know.Touch then
        Know.Touch("vendor")
    end
    return added
end

local function NotifyStoreUpdated()
    VA.InvalidateMatchIndex()
    local index = VA.RefreshMatchIndex()
    local list = VA.GetStoreItems()
    LearnVendorRows(list)
    local B = StockPiler3.EventBus
    local E = StockPiler3.Events
    if B and E and E.VENDOR_UPDATED then
        B.Fire(E.VENDOR_UPDATED, { gen = VA._matchIndexGen })
    end
    if StockPiler3.Buy and StockPiler3.Buy.OnStoreUpdated then
        StockPiler3.Buy.OnStoreUpdated({ refreshLists = true })
    end
    if StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
        StockPiler3.Scheduler.WakeAutoBuy()
    end
    return index
end

--- Coalesce ShowStore / UpdateStoreList storms into one refresh (Scheduler / Poll).
function VA.RequestStoreRefresh()
    VA._storeRefreshDue = true
end

function VA.FlushPendingStoreRefresh()
    if VA._storeRefreshDue ~= true then
        return false
    end
    VA._storeRefreshDue = false
    NotifyStoreUpdated()
    return true
end

function VA.IsStoreOpen()
    if type(DoesWindowExist) ~= "function" or type(WindowGetShowing) ~= "function" then
        return false
    end
    if not DoesWindowExist(STORE_WIN) then
        return false
    end
    return WindowGetShowing(STORE_WIN) == true
end

function VA.IsBuybackView()
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" then
        return false
    end
    return store.displayData ~= nil and store.displayData == store.buyBackData
end

--- Visible store listing (not buyback). Pages arrive over time.
function VA.GetStoreItems()
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" then
        return nil
    end
    if store.displayData ~= nil and store.displayData == store.buyBackData then
        return nil
    end
    local list = store.displayData
    if type(list) ~= "table" then
        list = store.storedata
    end
    if type(list) ~= "table" and type(GetStoreData) == "function" then
        local ok, data = TryQuiet("GetStoreData", GetStoreData)
        if ok then
            list = data
        end
    end
    if type(list) ~= "table" then
        return nil
    end
    return list
end

-- Alias for SP2 callers
function VA.StoreRows()
    return VA.GetStoreItems()
end

function VA.GetPlayerMoneyBrass()
    if type(Player) ~= "table" or type(Player.GetMoney) ~= "function" then
        return 0
    end
    local ok, value = TryQuiet("Player.GetMoney", Player.GetMoney)
    if not ok then
        return 0
    end
    return tonumber(value) or 0
end

function VA.BuyItem(itemData, buyCount)
    buyCount = tonumber(buyCount) or 0
    if type(itemData) ~= "table" or buyCount < 1 then
        return false, "invalid-args"
    end
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" or type(store.BuyItem) ~= "function" then
        return false, "no-api"
    end
    local ok, err = TryCall("VendorAdapter.BuyItem", store.BuyItem, itemData, buyCount)
    if not ok then
        return false, err
    end
    return true
end

function VA.InvalidateMatchIndex()
    VA._matchIndex = nil
end

--- Rebuild AutoBuy match index from current store page (uid -> row).
function VA.RefreshMatchIndex()
    local list = VA.GetStoreItems()
    local index = {
        byUid = {},
        rows = {},
    }
    if type(list) ~= "table" then
        VA._matchIndex = index
        VA._matchIndexGen = (tonumber(VA._matchIndexGen) or 0) + 1
        return index
    end

    local function addRow(item)
        if type(item) ~= "table" then
            return
        end
        local uid = tonumber(item.uniqueID) or tonumber(item.id) or 0
        local slotNum = tonumber(item.slotNum)
        if slotNum == nil and uid <= 0 then
            return
        end
        local cost = tonumber(item.cost) or 0
        local row = {
            item = item,
            uid = uid,
            cost = cost,
            slotNum = slotNum,
            canbuy = item.canbuy ~= false,
        }
        index.rows[#index.rows + 1] = row
        if uid > 0 then
            local bucket = index.byUid[uid]
            if type(bucket) ~= "table" then
                bucket = {}
                index.byUid[uid] = bucket
            end
            bucket[#bucket + 1] = row
        end
    end

    local n = 0
    for _, item in ipairs(list) do
        addRow(item)
        n = n + 1
    end
    if n == 0 then
        for _, item in pairs(list) do
            addRow(item)
        end
    end

    VA._matchIndex = index
    VA._matchIndexGen = (tonumber(VA._matchIndexGen) or 0) + 1
    return index
end

function VA.GetMatchIndex()
    if type(VA._matchIndex) ~= "table" then
        return VA.RefreshMatchIndex()
    end
    return VA._matchIndex
end

function VA.GetMatchIndexGen()
    return tonumber(VA._matchIndexGen) or 0
end

function VA.FindStoreRowsByUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    local index = VA.GetMatchIndex()
    if type(index) ~= "table" or type(index.byUid) ~= "table" then
        return nil
    end
    return index.byUid[uid]
end

function VA.OnStoreShow()
    VA.EnsureStoreHook()
    -- Immediate refresh on show; page updates coalesce via RequestStoreRefresh.
    NotifyStoreUpdated()
end

--- Wrap store UI updates so late pages refresh AutoBuy match index (coalesced).
function VA.EnsureStoreHook()
    if VA._storeHooked == true then
        return true
    end
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" then
        return false
    end
    local function afterStoreUi()
        VA.RequestStoreRefresh()
        if StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
            StockPiler3.Scheduler.WakeAutoBuy()
        end
    end
    if type(store.ShowStore) == "function" and store._sp3ShowStoreWrapped ~= true then
        local orig = store.ShowStore
        store.ShowStore = function(...)
            local a, b, c = orig(...)
            TryCall("VendorAdapter.ShowStore", afterStoreUi)
            return a, b, c
        end
        store._sp3ShowStoreWrapped = true
    end
    if type(store.UpdateStoreList) == "function" and store._sp3UpdateStoreWrapped ~= true then
        local orig = store.UpdateStoreList
        store.UpdateStoreList = function(...)
            local a, b, c = orig(...)
            TryCall("VendorAdapter.UpdateStoreList", afterStoreUi)
            return a, b, c
        end
        store._sp3UpdateStoreWrapped = true
    end
    if type(store.UpdateBuyBackList) == "function" and store._sp3UpdateBuyBackWrapped ~= true then
        local orig = store.UpdateBuyBackList
        store.UpdateBuyBackList = function(...)
            local a, b, c = orig(...)
            TryCall("VendorAdapter.UpdateBuyBackList", afterStoreUi)
            return a, b, c
        end
        store._sp3UpdateBuyBackWrapped = true
    end
    VA._storeHooked = true
    return true
end
