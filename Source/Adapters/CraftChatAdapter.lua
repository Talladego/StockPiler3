----------------------------------------------------------------
-- StockPiler3 Adapters/CraftChatAdapter — chat print + soil confirm
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.CraftChatAdapter = StockPiler3.CraftChatAdapter or {}
local CC = StockPiler3.CraftChatAdapter

-- Pending plant meta awaiting soil confirm (plot leaves EMPTY).
CC._soilPending = CC._soilPending or {}
CC._soilChatMeta = CC._soilChatMeta or {}

local PLANT_CHAT_META_TTL_SEC = 30
local PENDING_EMPTY_GRACE_SEC = 5.0

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function TryQuiet(label, fn, ...)
    if StockPiler3.Debug and StockPiler3.Debug.TryCallQuiet then
        return StockPiler3.Debug.TryCallQuiet(label, fn, ...)
    end
    return pcall(fn, ...)
end

local function ToWString(value)
    if type(value) == "wstring" then
        return value
    end
    if value == nil then
        return L""
    end
    return towstring(tostring(value))
end

local function StageEmpty()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.EMPTY or 0
    end
    return 0
end

local function ResolveItemData(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler3.Inventory and StockPiler3.Inventory.GetSample then
        local sample = StockPiler3.Inventory.GetSample(uid)
        if type(sample) == "table" then
            return sample
        end
    end
    if type(GetDatabaseItemData) == "function" then
        local ok, data = TryQuiet("GetDatabaseItemData", GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            return data
        end
    end
    return nil
end

--- Clickable ITEM:uid hyperlink (same shape as EA_ChatWindow.InsertItemLink).
function CC.ItemLink(uid, fallbackName)
    uid = tonumber(uid) or 0
    local itemData = ResolveItemData(uid)
    local name = nil
    if type(itemData) == "table" and itemData.name ~= nil and itemData.name ~= L"" then
        name = itemData.name
    elseif fallbackName ~= nil and fallbackName ~= L"" and fallbackName ~= "" then
        name = ToWString(fallbackName)
    else
        name = L"item"
    end
    local text = L"[" .. name .. L"]"
    if uid <= 0 or type(CreateHyperLink) ~= "function" then
        return text
    end
    local r, g, b = 255, 255, 255
    if type(itemData) == "table" and DataUtils and DataUtils.GetItemRarityColor then
        local ok, color = TryQuiet("DataUtils.GetItemRarityColor", DataUtils.GetItemRarityColor, itemData)
        if ok and type(color) == "table" then
            r = tonumber(color.r) or r
            g = tonumber(color.g) or g
            b = tonumber(color.b) or b
        end
    end
    local data = L"ITEM:" .. uid
    local ok, link = TryQuiet("CreateHyperLink", CreateHyperLink, data, text, { r, g, b }, {})
    if ok and link ~= nil then
        if type(link) == "wstring" then
            return link
        end
        return towstring(link)
    end
    return text
end

function CC.Print(msg)
    if msg == nil then
        return
    end
    if StockPiler3.Debug and StockPiler3.Debug.Print then
        StockPiler3.Debug.Print(msg)
        return
    end
    if type(EA_ChatWindow) == "table" and type(EA_ChatWindow.Print) == "function" then
        if type(msg) == "wstring" then
            EA_ChatWindow.Print(msg)
        else
            EA_ChatWindow.Print(towstring(tostring(msg)))
        end
    end
end

--- Print a line that may include ITEM links (wstring parts joined).
function CC.PrintParts(...)
    local parts = { ... }
    local out = L""
    for i = 1, #parts do
        local p = parts[i]
        if p ~= nil then
            out = out .. ToWString(p)
        end
    end
    if out ~= L"" then
        CC.Print(out)
    end
end

function CC.PrintWithItem(prefix, uid, fallbackName, suffix)
    local link = CC.ItemLink(uid, fallbackName)
    CC.PrintParts(prefix or "", link, suffix or "")
end

--- Stash plant meta until soil leaves EMPTY (chat once on confirm).
function CC.StashSoilPending(plotNum, meta)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or type(meta) ~= "table" then
        return
    end
    local newSeed = tonumber(meta.seedUid) or 0
    local existing = CC._soilPending[plotNum]
    if type(existing) ~= "table" then
        existing = CC._soilChatMeta[plotNum]
    end
    if type(existing) == "table" and existing.chatted ~= true then
        local oldSeed = tonumber(existing.seedUid) or 0
        if oldSeed > 0 and newSeed > 0 and oldSeed ~= newSeed then
            -- Do not clobber an in-flight plant announce with a different seed.
            return
        end
        -- Same seed (or unknown): refresh timestamp only.
        existing.at = NowSec()
        existing.reason = tostring(meta.reason or existing.reason or "potion_stock")
        if meta.name ~= nil then
            existing.name = meta.name
        end
        if newSeed > 0 then
            existing.seedUid = newSeed
        end
        CC._soilPending[plotNum] = existing
        CC._soilChatMeta[plotNum] = {
            reason = existing.reason,
            name = existing.name,
            seedUid = existing.seedUid,
            at = existing.at,
            chatted = false,
        }
        return
    end
    local row = {
        reason = tostring(meta.reason or "potion_stock"),
        name = meta.name,
        seedUid = newSeed,
        at = NowSec(),
        chatted = false,
    }
    CC._soilPending[plotNum] = row
    CC._soilChatMeta[plotNum] = {
        reason = row.reason,
        name = row.name,
        seedUid = row.seedUid,
        at = row.at,
        chatted = false,
    }
end

function CC.ClearSoilPending(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return
    end
    CC._soilPending[plotNum] = nil
end

local function EmitPlantedChat(plotNum, meta)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or type(meta) ~= "table" then
        return
    end
    if meta.chatted == true then
        return
    end
    meta.chatted = true
    local stash = CC._soilChatMeta[plotNum]
    if type(stash) == "table" then
        stash.chatted = true
    end
    local seedUid = tonumber(meta.seedUid) or 0
    local namePart = meta.name
    if seedUid > 0 then
        namePart = CC.ItemLink(seedUid, meta.name)
    else
        namePart = ToWString(meta.name or "seed")
    end
    local reason = tostring(meta.reason or "potion_stock")
    local msg = nil
    if StockPiler3.T then
        msg = StockPiler3.T("grow.planted", {
            plot = tostring(plotNum),
            name = namePart,
            reason = towstring(reason),
        })
    end
    if msg == nil then
        msg = L"Harvest: Plot " .. towstring(tostring(plotNum))
            .. L" planted " .. ToWString(namePart)
            .. L" (" .. towstring(reason) .. L")."
    end
    CC.Print(msg)
end

--- Call when a plot leaves EMPTY after PlantSeed. Returns true if chat fired.
function CC.OnSoilConfirmed(plotNum, plotInfo)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return false
    end
    local pending = CC._soilPending[plotNum]
    local stash = CC._soilChatMeta[plotNum]
    local meta = pending
    if type(meta) ~= "table" then
        meta = stash
    end
    if type(meta) ~= "table" then
        return false
    end
    if meta.chatted == true or (type(stash) == "table" and stash.chatted == true) then
        CC._soilPending[plotNum] = nil
        return false
    end
    if type(plotInfo) == "table" then
        local plotSeed = tonumber(plotInfo.seedUid) or 0
        local metaSeed = tonumber(meta.seedUid) or 0
        if plotSeed > 0 and metaSeed > 0 and plotSeed ~= metaSeed then
            -- Prefer what actually grew; still announce instead of silent drop.
            meta = {
                reason = tostring(meta.reason or "potion_stock"),
                name = meta.name,
                seedUid = plotSeed,
                at = meta.at,
                chatted = false,
            }
        end
    end
    EmitPlantedChat(plotNum, meta)
    CC._soilPending[plotNum] = nil
    return true
end

--- Handle empty-while-pending (grace before drop). keepChatMeta for late soil.
function CC.OnSoilStillEmpty(plotNum, opts)
    plotNum = tonumber(plotNum) or 0
    opts = type(opts) == "table" and opts or {}
    local pending = CC._soilPending[plotNum]
    if type(pending) ~= "table" then
        return false
    end
    local at = tonumber(pending.at) or 0
    local now = NowSec()
    local grace = tonumber(opts.graceSec) or PENDING_EMPTY_GRACE_SEC
    if at > 0 and now > 0 and (now - at) < grace then
        return false
    end
    if opts.keepChatMeta ~= true then
        CC._soilChatMeta[plotNum] = nil
    end
    CC._soilPending[plotNum] = nil
    return true
end

--- Sync helper: confirm from plot snapshot (stage != EMPTY).
function CC.TryConfirmFromPlot(plotNum, plotInfo)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or type(plotInfo) ~= "table" then
        return false
    end
    local stage = tonumber(plotInfo.stage) or 0
    if stage == StageEmpty() then
        CC.OnSoilStillEmpty(plotNum, { keepChatMeta = true })
        return false
    end
    return CC.OnSoilConfirmed(plotNum, plotInfo)
end

function CC.ExpireStaleChatMeta()
    local now = NowSec()
    if now <= 0 then
        return
    end
    for plotNum, meta in pairs(CC._soilChatMeta) do
        if type(meta) == "table" then
            local at = tonumber(meta.at) or 0
            if at > 0 and (now - at) > PLANT_CHAT_META_TTL_SEC then
                CC._soilChatMeta[plotNum] = nil
            end
        end
    end
end

function CC.HasSoilPending(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return false
    end
    return type(CC._soilPending[plotNum]) == "table"
end

----------------------------------------------------------------
-- Crafting-channel harvest cues ("Your creation failed.", Critical Success, …)
-- Chat arrives before plot-empty often; sticky cues bridge until BeginPendingHarvest.
----------------------------------------------------------------

local HARVEST_CUE_STICKY_SEC = 5
CC._harvestFailStickyAt = 0
CC._harvestOkStickyAt = 0
CC._chatRegistered = false

local function ToNarrow(value)
    if StockPiler3.Persistence and StockPiler3.Persistence.ToNarrow then
        return StockPiler3.Persistence.ToNarrow(value) or ""
    end
    if type(value) == "string" then
        return value
    end
    if type(value) == "wstring" and type(WStringToString) == "function" then
        local ok, text = pcall(WStringToString, value)
        if ok and type(text) == "string" then
            return text
        end
    end
    return tostring(value or "")
end

local function NormalizeChat(text)
    local s = ToNarrow(text)
    s = string.gsub(s, "<LINK[^>]*>", "")
    s = string.gsub(s, "</LINK>", "")
    s = string.gsub(s, "<[^>]+>", "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function StickyFresh(at)
    at = tonumber(at) or 0
    if at <= 0 then
        return false
    end
    local age = NowSec() - at
    return age >= 0 and age <= HARVEST_CUE_STICKY_SEC
end

function CC.ConsumeHarvestCriticalFailureSticky()
    local at = CC._harvestFailStickyAt
    CC._harvestFailStickyAt = 0
    return StickyFresh(at)
end

function CC.ConsumeHarvestCriticalSuccessSticky()
    local at = CC._harvestOkStickyAt
    CC._harvestOkStickyAt = 0
    return StickyFresh(at)
end

local function NoteHarvestCriticalFailure()
    local pending = StockPiler3.SeedMap and StockPiler3.SeedMap._pendingHarvest
    if type(pending) == "table" then
        pending.chatCriticalFailure = true
        if StockPiler3.SeedMap.CompletePendingHarvestAsCritFail then
            StockPiler3.SeedMap.CompletePendingHarvestAsCritFail()
        end
        return
    end
    CC._harvestFailStickyAt = NowSec()
end

local function NoteHarvestCriticalSuccess()
    local pending = StockPiler3.SeedMap and StockPiler3.SeedMap._pendingHarvest
    if type(pending) == "table" then
        pending.chatCriticalSuccess = true
        return
    end
    CC._harvestOkStickyAt = NowSec()
end

local function ParseCraftingLine(text)
    if text == "" then
        return nil
    end
    local lower = string.lower(text)
    if string.find(lower, "your creation failed", 1, true) == 1
        or string.find(lower, "critical failure", 1, true) == 1
        or lower == "critical failure."
        or string.find(lower, "^critical failure%.?")
    then
        return { kind = "critical_failure" }
    end
    if string.find(lower, "critical success", 1, true) == 1
        or lower == "critical success."
        or string.find(lower, "^critical success%.?")
    then
        return { kind = "critical_success" }
    end
    local qty, plant = string.match(text, "^You have harvested (%d+) (.+)%.?$")
    if qty and plant then
        return { kind = "harvested", count = tonumber(qty), name = plant }
    end
    local created = string.match(text, "^You created (.+)%.?$")
    if created then
        created = string.gsub(created, "%.$", "")
        return { kind = "created", name = created }
    end
    return nil
end

function CC.OnChatTextArrived()
    if not GameData or not GameData.ChatData then
        return
    end
    local filters = SystemData and SystemData.ChatLogFilters
    local craftFilter = filters and filters.CRAFTING
    local msgType = tonumber(GameData.ChatData.type)
    if craftFilter ~= nil and msgType ~= tonumber(craftFilter) then
        return
    end
    local text = NormalizeChat(GameData.ChatData.text)
    local parsed = ParseCraftingLine(text)
    if type(parsed) ~= "table" then
        return
    end
    if parsed.kind == "critical_failure" then
        NoteHarvestCriticalFailure()
    elseif parsed.kind == "critical_success" then
        NoteHarvestCriticalSuccess()
    elseif parsed.kind == "harvested" then
        if StockPiler3.SeedMap and StockPiler3.SeedMap.MarkHarvestLootDirty then
            StockPiler3.SeedMap.MarkHarvestLootDirty()
        end
        if StockPiler3.Grow and StockPiler3.Grow.WakeAfterHarvestChat then
            StockPiler3.Grow.WakeAfterHarvestChat()
        end
    elseif parsed.kind == "created" then
        if StockPiler3.BrewLearn and StockPiler3.BrewLearn.OnCreatedChat then
            StockPiler3.BrewLearn.OnCreatedChat(parsed.name)
        end
    end
end

function CC.RegisterChat()
    if CC._chatRegistered == true then
        return
    end
    local ev = SystemData and SystemData.Events and SystemData.Events.CHAT_TEXT_ARRIVED
    if ev == nil then
        return
    end
    if type(RegisterEventHandler) == "function" then
        RegisterEventHandler(ev, "StockPiler3.CraftChatAdapter.OnChatTextArrived")
        CC._chatRegistered = true
    end
end

function CC.UnregisterChat()
    if CC._chatRegistered ~= true then
        return
    end
    local ev = SystemData and SystemData.Events and SystemData.Events.CHAT_TEXT_ARRIVED
    if ev ~= nil and type(UnregisterEventHandler) == "function" then
        UnregisterEventHandler(ev, "StockPiler3.CraftChatAdapter.OnChatTextArrived")
    end
    CC._chatRegistered = false
    CC._harvestFailStickyAt = 0
    CC._harvestOkStickyAt = 0
end
