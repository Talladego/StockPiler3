----------------------------------------------------------------
-- StockPiler3 CraftTooltip -- dual Craft macro tip (live while hovered)
-- Primary line = what this click does; optional follow-up = queued next.
-- Then one section per planted plot: seed (icon + tier color), full time
-- left (TotalTimer), and applied additives.
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.CraftTooltip = StockPiler3.CraftTooltip or {}
local CraftTooltip = StockPiler3.CraftTooltip

local function T(key, tokens)
    return StockPiler3.Util.T(key, tokens)
end

local function WName(name)
    if name == nil or name == L"" then
        return nil
    end
    return name
end

local function SessionBrewName(session)
    if type(session) ~= "table" then
        return nil
    end
    local phase = tostring(session.phase or "idle")
    if phase ~= "loading" and phase ~= "loaded" then
        return nil
    end
    return WName(session.name)
end

local function ReadyBrewName()
    local Brew = StockPiler3.Brew
    local session = Brew and Brew.GetSession and Brew.GetSession()
    local loaded = SessionBrewName(session)
    if loaded ~= nil then
        return loaded
    end
    if Brew and Brew.PickReadyWatch then
        local row = Brew.PickReadyWatch()
        if type(row) == "table" then
            return WName(row.name)
        end
    end
    return T("brew.potion_fallback")
end

local function NameKey(name)
    if name == nil then
        return ""
    end
    if type(name) == "wstring" and type(WStringToString) == "function" then
        return WStringToString(name) or ""
    end
    return tostring(name)
end

local function SoftReadyCount()
    local Grow = StockPiler3.Grow
    if Grow and Grow.GetReadyHarvestPlots then
        local plots = Grow.GetReadyHarvestPlots()
        if type(plots) == "table" then
            return #plots
        end
    end
    return 0
end

local function StageEmpty()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.EMPTY or 0
    end
    return 0
end

local function StageGrown()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.GROWN or 4
    end
    return 4
end

local function StageHarvesting()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.HARVESTING or 5
    end
    return 5
end

local function IconMarkup(iconNum)
    iconNum = tonumber(iconNum) or 0
    if iconNum <= 0 then
        return L""
    end
    return towstring(string.format("<icon%05d> ", iconNum))
end

local function FormatTotalTime(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 0 then
        seconds = 0
    end
    if seconds > 0 and TimeUtils and TimeUtils.FormatTime then
        local ok, text = pcall(TimeUtils.FormatTime, seconds)
        if ok and text ~= nil and text ~= L"" then
            return text
        end
    end
    local s = math.floor(seconds + 0.5)
    local m = math.floor(s / 60)
    s = s - m * 60
    local h = math.floor(m / 60)
    m = m - h * 60
    if h > 0 then
        return towstring(string.format("%d:%02d:%02d", h, m, s))
    end
    return towstring(string.format("%d:%02d", m, s))
end

local function AdditiveCultOrder()
    local types = GameData and GameData.CultivationTypes
    if type(types) == "table" then
        return {
            tonumber(types.SOIL) or 2,
            tonumber(types.WATERCAN) or 3,
            tonumber(types.NUTRIENT) or 4,
        }
    end
    return { 2, 3, 4 }
end

local function SeedItemData(plot)
    if type(plot) ~= "table" then
        return nil
    end
    local seed = plot.seed
    if type(seed) == "table" then
        return seed
    end
    local uid = tonumber(plot.seedUid) or 0
    if uid <= 0 then
        return nil
    end
    local Items = StockPiler3.Items
    if Items and Items.Get then
        local item = Items.Get(uid)
        if type(item) == "table" then
            return item
        end
    end
    return {
        uniqueID = uid,
        name = plot.seedName,
        iconNum = tonumber(plot.seedIconNum) or 0,
    }
end

local function SeedRarityColor(itemData)
    local VL = StockPiler3.ViewList
    if VL and VL.ItemRarityNameColor then
        local r, g, b = VL.ItemRarityNameColor(itemData)
        return { r = r, g = g, b = b }
    end
    return nil
end

--- Live plot rows from the cultivator (not the soft Garden cache) so TotalTimer ticks.
local function CollectPlantedPlots()
    local CA = StockPiler3.CultivatorAdapter
    if not CA then
        return {}
    end
    local n = 4
    if CA.MaxPlotSlots then
        n = tonumber(CA.MaxPlotSlots()) or n
    elseif CA.NumPlots then
        n = tonumber(CA.NumPlots()) or n
    end
    local empty = StageEmpty()
    local out = {}
    for plotNum = 1, n do
        local plot = CA.GetPlotInfo and CA.GetPlotInfo(plotNum) or nil
        if type(plot) == "table" then
            local stage = tonumber(plot.stage) or 0
            local seedUid = tonumber(plot.seedUid) or 0
            if stage ~= empty and stage ~= 255 and seedUid > 0 then
                out[#out + 1] = plot
            end
        end
    end
    return out
end

local function BuildActionRows()
    local Macro = StockPiler3.Macro
    local snap = nil
    if Macro and Macro.ResolveCraftMode then
        snap = Macro.ResolveCraftMode({ readonly = true })
    end
    snap = type(snap) == "table" and snap or {}

    local mode = tostring(snap.mode or "idle")
    local ready = tonumber(snap.readyPlots) or SoftReadyCount()
    local canHarvest = snap.canHarvest == true
    local canBrew = snap.canBrew == true
    local brewPhase = tostring(snap.brewPhase or "idle")
    local brewName = snap.brewName
    if brewName == nil or brewName == L"" then
        if mode == "brew" or canBrew or brewPhase == "loading" or brewPhase == "loaded" then
            brewName = ReadyBrewName()
        end
    end
    if brewName == nil or brewName == L"" then
        brewName = T("brew.potion_fallback")
    end

    local rows = {}
    local function push(text, kind)
        if text == nil or text == L"" then
            return
        end
        rows[#rows + 1] = { text = text, kind = kind or "body" }
    end

    if mode == "harvest" then
        if canHarvest and ready > 0 then
            push(T("macro.craft_tip_harvest", { count = tostring(ready) }), "title")
        elseif ready > 0 then
            push(T("macro.craft_tip_harvest_wait", { count = tostring(ready) }), "title")
        else
            push(T("macro.craft_tip_idle"), "title")
        end
        if ready > 1 then
            push(T("macro.craft_tip_then_harvest", { count = tostring(ready - 1) }), "meta")
        end
        if canBrew then
            push(T("macro.craft_tip_then_brew", { name = ReadyBrewName() }), "meta")
        end
    elseif mode == "brew" then
        if brewPhase == "loading" then
            push(T("macro.craft_tip_brew_loading", { name = brewName }), "title")
        elseif brewPhase == "loaded" then
            if canBrew then
                push(T("macro.craft_tip_brew", { name = brewName }), "title")
            else
                push(T("macro.craft_tip_brew_loading", { name = brewName }), "title")
            end
        elseif canBrew then
            push(T("macro.craft_tip_brew_load", { name = brewName }), "title")
            push(T("macro.craft_tip_then_brew", { name = brewName }), "meta")
        else
            push(T("macro.craft_tip_idle"), "title")
        end
        if ready > 0 then
            push(T("macro.craft_tip_then_harvest_ready", { count = tostring(ready) }), "meta")
        end
    else
        push(T("macro.craft_tip_idle"), "title")
        if ready > 0 then
            push(T("macro.craft_tip_then_harvest_ready", { count = tostring(ready) }), "meta")
        elseif canBrew then
            push(T("macro.craft_tip_then_brew", { name = brewName }), "meta")
        else
            local Brew = StockPiler3.Brew
            local why = Brew and Brew.AutoBrewBlockedReason and Brew.AutoBrewBlockedReason()
            if why == "buffer" then
                push(T("brew.blocked_buffer"), "warning")
            elseif why == "pending-plant" then
                push(T("brew.blocked_plant"), "warning")
            elseif why == "refine" then
                push(T("brew.blocked_refine"), "warning")
            elseif why == "harvest" then
                push(T("brew.blocked_harvest"), "warning")
            end
        end
    end
    return rows
end

local function AppendPlotSections(rows, plots)
    if type(rows) ~= "table" or type(plots) ~= "table" or #plots == 0 then
        return
    end
    local RT = StockPiler3.RecipeTooltip
    local grown = StageGrown()
    local harvesting = StageHarvesting()
    local order = AdditiveCultOrder()

    for i = 1, #plots do
        local plot = plots[i]
        if RT and RT.AppendSeparator then
            RT.AppendSeparator(rows)
        else
            rows[#rows + 1] = { text = T("recipe.sep"), kind = "separator" }
        end

        local plotNum = tonumber(plot.plotNum) or i
        rows[#rows + 1] = {
            text = T("macro.craft_tip_plot", { plot = tostring(plotNum) }),
            kind = "title",
        }

        local itemData = SeedItemData(plot)
        local iconNum = tonumber(plot.seedIconNum) or 0
        if iconNum <= 0 and type(itemData) == "table" then
            iconNum = tonumber(itemData.iconNum) or 0
        end
        local name = WName(plot.seedName)
        if name == nil and type(itemData) == "table" then
            name = WName(itemData.name)
        end
        if name == nil then
            name = T("macro.craft_tip_seed_fallback")
        end
        rows[#rows + 1] = {
            text = IconMarkup(iconNum) .. name,
            kind = "ingredient",
            color = SeedRarityColor(itemData),
        }

        local stage = tonumber(plot.stage) or 0
        local total = tonumber(plot.totalTimer) or 0
        if stage == grown or stage == harvesting then
            rows[#rows + 1] = {
                text = T("macro.craft_tip_time_ready"),
                kind = "stocked",
            }
        else
            rows[#rows + 1] = {
                text = T("macro.craft_tip_time", { time = FormatTotalTime(total) }),
                kind = "meta",
            }
        end

        local additives = plot.additives
        local anyAdd = false
        if type(additives) == "table" then
            for oi = 1, #order do
                local ct = order[oi]
                local slot = additives[ct]
                if type(slot) == "table" and (slot.filled == true
                    or (tonumber(slot.uniqueID) or 0) > 0
                    or (tonumber(slot.id) or 0) ~= 0)
                then
                    anyAdd = true
                    local aIcon = tonumber(slot.iconNum) or 0
                    local aName = WName(slot.name) or T("macro.craft_tip_additive_fallback")
                    rows[#rows + 1] = {
                        text = IconMarkup(aIcon) .. aName,
                        kind = "body",
                        color = SeedRarityColor(slot),
                    }
                end
            end
        end
        if not anyAdd then
            rows[#rows + 1] = {
                text = T("macro.craft_tip_additives_none"),
                kind = "meta",
            }
        end
    end
end

local function BuildTipRows()
    local rows = BuildActionRows()
    AppendPlotSections(rows, CollectPlantedPlots())
    return rows
end

local function Fingerprint()
    local Macro = StockPiler3.Macro
    local snap = nil
    if Macro and Macro.ResolveCraftMode then
        snap = Macro.ResolveCraftMode({ readonly = true })
    end
    snap = type(snap) == "table" and snap or {}
    local brewName = snap.brewName
    if (brewName == nil or brewName == L"") and (snap.mode == "brew" or snap.canBrew == true) then
        brewName = ReadyBrewName()
    end
    local blocked = ""
    if tostring(snap.mode or "idle") == "idle" then
        local Brew = StockPiler3.Brew
        blocked = tostring(Brew and Brew.AutoBrewBlockedReason and Brew.AutoBrewBlockedReason() or "")
    end

    local parts = {
        tostring(snap.mode or "idle"),
        tostring(snap.iconMode or ""),
        tostring(snap.readyPlots or 0),
        tostring(snap.canHarvest == true),
        tostring(snap.canBrew == true),
        tostring(snap.brewPhase or "idle"),
        NameKey(brewName),
        blocked,
    }

    local plots = CollectPlantedPlots()
    parts[#parts + 1] = "n=" .. tostring(#plots)
    for i = 1, #plots do
        local p = plots[i]
        local addKey = ""
        if type(p.additives) == "table" then
            local bits = {}
            for ct, slot in pairs(p.additives) do
                if type(slot) == "table" and (slot.filled == true
                    or (tonumber(slot.uniqueID) or 0) > 0
                    or (tonumber(slot.id) or 0) ~= 0)
                then
                    bits[#bits + 1] = tostring(ct) .. ":"
                        .. tostring(tonumber(slot.uniqueID) or tonumber(slot.id) or 0)
                end
            end
            table.sort(bits)
            addKey = table.concat(bits, ",")
        end
        -- Floor totalTimer so the tip refreshes about once per second while hovered.
        parts[#parts + 1] = table.concat({
            tostring(tonumber(p.plotNum) or i),
            tostring(tonumber(p.seedUid) or 0),
            tostring(tonumber(p.stage) or 0),
            tostring(math.floor(tonumber(p.totalTimer) or 0)),
            addKey,
        }, "/")
    end
    return table.concat(parts, ":")
end

function CraftTooltip.Show(mouseoverWindow, anchor)
    mouseoverWindow = mouseoverWindow
        or (SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    if mouseoverWindow == nil or mouseoverWindow == "" then
        return
    end
    CraftTooltip._liveWindow = mouseoverWindow
    CraftTooltip._liveAnchor = anchor
        or (Tooltips and Tooltips.ANCHOR_WINDOW_TOP)
        or nil
    CraftTooltip._liveFp = Fingerprint()

    local rows = BuildTipRows()
    local RT = StockPiler3.RecipeTooltip
    if RT and RT.ShowColoredRows then
        RT.ShowColoredRows(mouseoverWindow, rows, CraftTooltip._liveAnchor, #rows + 2)
        return
    end
    -- Fallback: flatten to a text tip.
    local chunks = {}
    for i = 1, #rows do
        local entry = rows[i]
        if type(entry) == "table" and entry.text ~= nil and entry.text ~= L"" then
            chunks[#chunks + 1] = entry.text
        end
    end
    local text = L""
    for i = 1, #chunks do
        if i > 1 then
            text = text .. L"\n"
        end
        text = text .. chunks[i]
    end
    if Tooltips and Tooltips.CreateTextOnlyTooltip then
        Tooltips.CreateTextOnlyTooltip(mouseoverWindow, text)
        Tooltips.AnchorTooltip(CraftTooltip._liveAnchor)
    end
end

function CraftTooltip.ClearLive()
    CraftTooltip._liveWindow = nil
    CraftTooltip._liveFp = nil
end

function CraftTooltip.MaybeRefresh()
    local win = CraftTooltip._liveWindow
    if win == nil or win == "" then
        return
    end
    local fp = Fingerprint()
    if fp == CraftTooltip._liveFp then
        return
    end
    CraftTooltip.Show(win, CraftTooltip._liveAnchor)
end

function CraftTooltip.TickLive()
    CraftTooltip.MaybeRefresh()
end
