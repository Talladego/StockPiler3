----------------------------------------------------------------
-- StockPiler3TabPotions -- known potions list (watch / filters / forget)
----------------------------------------------------------------

StockPiler3TabPotions = {}

local function T(key, tokens)
    if StockPiler3.T then
        return StockPiler3.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

StockPiler3TabPotions.listData = {}
StockPiler3TabPotions.displayOrder = {}

local ICON_SCALE = 0.34
local TAB_ROOT = "SP3TabPotions"

local SORT_IDS = {
    [1] = "name",
    [2] = "effect",
    [3] = "power",
    [4] = "stability",
    [5] = "superCrit",
    [6] = "yield",
    [7] = "have",
    [8] = "watch",
    [9] = "level",
    [10] = "multiplier",
}

local SORT_HEADERS = {
    watch = "SP3TabPotionsSortWatch",
    name = "SP3TabPotionsSortName",
    level = "SP3TabPotionsSortLevel",
    effect = "SP3TabPotionsSortEffect",
    power = "SP3TabPotionsSortPower",
    stability = "SP3TabPotionsSortStability",
    multiplier = "SP3TabPotionsSortMultiplier",
    superCrit = "SP3TabPotionsSortSuperCrit",
    yield = "SP3TabPotionsSortYield",
    have = "SP3TabPotionsSortHave",
}

local function ToNarrow(text)
    if StockPiler3.Persistence and StockPiler3.Persistence.ToNarrow then
        return StockPiler3.Persistence.ToNarrow(text)
    end
    return tostring(text or "")
end

local function GetSettings()
    if StockPiler3.Persistence and StockPiler3.Persistence.EnsureSettings then
        return StockPiler3.Persistence.EnsureSettings()
    end
    return StockPiler3.Settings
end

local function EffectTextForRow(effectKey)
    if type(effectKey) ~= "string" or effectKey == "" then
        return L""
    end
    if StockPiler3.Classify and StockPiler3.Classify.EffectShortLabel then
        return StockPiler3.Classify.EffectShortLabel(effectKey)
    end
    return towstring(string.upper(effectKey))
end

local function ItemRarityNameColor(itemData)
    if itemData and DataUtils and DataUtils.GetItemRarityColor then
        local ok, color
        if StockPiler3.Debug and StockPiler3.Debug.TryCallQuiet then
            ok, color = StockPiler3.Debug.TryCallQuiet("DataUtils.GetItemRarityColor", DataUtils.GetItemRarityColor, itemData)
        else
            ok, color = pcall(DataUtils.GetItemRarityColor, itemData)
        end
        if ok and type(color) == "table" then
            return tonumber(color.r) or 255, tonumber(color.g) or 255, tonumber(color.b) or 255
        end
    end
    return 255, 255, 255
end

local function FormatSignedStat(value)
    value = tonumber(value) or 0
    if value > 0 then
        return towstring("+" .. tostring(value))
    end
    return towstring(tostring(value))
end

local function FormatPercentStat(value)
    value = tonumber(value) or 0
    if value == 0 then
        return T("ui.dash")
    end
    return towstring(tostring(value) .. "%")
end

local function FormatYieldStat(value)
    value = tonumber(value) or 0
    if value <= 0 then
        return T("ui.dash")
    end
    local rounded = math.floor(value + 0.5)
    if math.abs(value - rounded) < 0.05 then
        return towstring(tostring(rounded))
    end
    return towstring(string.format("%.1f", value))
end

local function ApplyPotionStats(row, itemData)
    local dash = T("ui.dash")
    row.rankNum = 0
    row.levelNum = 0
    row.levelText = dash
    if StockPiler3.Classify and StockPiler3.Classify.GetPotionStats then
        local stats = StockPiler3.Classify.GetPotionStats(itemData)
        if type(stats) == "table" then
            row.rankNum = tonumber(stats.rank) or tonumber(stats.level) or 0
            row.levelNum = tonumber(stats.level) or row.rankNum
            if type(stats.levelText) == "wstring" and stats.levelText ~= L"" then
                row.levelText = stats.levelText
            elseif row.levelNum > 0 then
                row.levelText = towstring(tostring(row.levelNum))
            end
            if (not row.effectKey or row.effectKey == "") and stats.effectKey then
                row.effectKey = stats.effectKey
                row.effectText = stats.effectText or EffectTextForRow(stats.effectKey)
            end
            return
        end
    end
    if type(itemData) == "table" then
        local lvl = tonumber(itemData.iLevel) or tonumber(itemData.level) or 0
        row.rankNum = lvl
        row.levelNum = lvl
        if lvl > 0 then
            row.levelText = towstring(tostring(lvl))
        end
    end
end

local function BuildRecipeDataForPotion(potionName, recipe, potionLevel, potionUid, potionBase)
    if type(recipe) ~= "table" then
        return nil
    end
    local uid = tonumber(potionUid) or tonumber(recipe.outputUid) or 0
    local attempts = tonumber(recipe.brewAttempts) or 0
    local successes = tonumber(recipe.brewSuccesses) or 0
    local successRate = nil
    if attempts > 0 then
        successRate = successes / attempts
    end
    local recipeYield = tonumber(recipe.recipeYield) or 0
    local RS = StockPiler3.RecipeSpec
    if RS and RS.RecipeFingerprintStats then
        local stats = RS.RecipeFingerprintStats(recipe, uid)
        if type(stats) == "table" and tonumber(stats.yield) and tonumber(stats.yield) > 0 then
            recipeYield = tonumber(stats.yield)
        end
    end
    local effectKey = nil
    if type(potionBase) == "table" and type(potionBase.effectKey) == "string" and potionBase.effectKey ~= "" then
        effectKey = potionBase.effectKey
    end
    if (type(effectKey) ~= "string" or effectKey == "") and RS and RS.ResolveEffectKeyForPotion
        and type(potionBase) == "table"
    then
        effectKey = RS.ResolveEffectKeyForPotion(potionBase, {
            recipe = recipe,
            stamp = false,
            allowClassify = true,
        })
    end
    if type(effectKey) == "string" and effectKey ~= "" and RS and RS.NormalizeEffectKeyForUi then
        effectKey = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
    end
    return {
        name = potionName,
        potionLevel = tonumber(potionLevel) or 0,
        potionUid = uid,
        recipeSpecKey = recipe.recipeSpecKey,
        recipe = recipe,
        recipeYield = recipeYield,
        brewAttempts = attempts,
        brewSuccesses = successes,
        successRate = successRate,
        effectKey = effectKey,
        materials = recipe.slots or {},
    }
end

local function MatchesNameFilter(name, filter)
    if filter == nil or filter == "" then
        return true
    end
    return string.find(string.lower(ToNarrow(name)), string.lower(filter), 1, true) ~= nil
end

local function MatchesEffectFilter(effectKey, filter)
    if filter == nil or filter == "" then
        return true
    end
    return effectKey == filter
end

local function PassesFilters(row, nameFilter, effectFilter)
    if not MatchesNameFilter(row.name, nameFilter)
        and not MatchesNameFilter(row.baseName, nameFilter)
        and not MatchesNameFilter(row.recipeLabel, nameFilter)
    then
        return false
    end
    return MatchesEffectFilter(row.effectKey, effectFilter)
end

local function CompareName(a, b)
    local na = string.lower(ToNarrow(a.baseName or a.name))
    local nb = string.lower(ToNarrow(b.baseName or b.name))
    if na == nb then
        return ToNarrow(a.id) < ToNarrow(b.id)
    end
    return na < nb
end

local function CompareRows(a, b, column, ascending)
    local function finish(lt)
        if lt then
            return ascending
        end
        return not ascending
    end
    if column == "name" then
        local na = string.lower(ToNarrow(a.name))
        local nb = string.lower(ToNarrow(b.name))
        if na == nb then
            return CompareName(a, b)
        end
        return finish(na < nb)
    elseif column == "level" then
        local la = a.levelNum or a.rankNum or 0
        local lb = b.levelNum or b.rankNum or 0
        if la == lb then
            return CompareName(a, b)
        end
        return finish(la < lb)
    elseif column == "effect" then
        local ea = ToNarrow(a.effectText)
        local eb = ToNarrow(b.effectText)
        if ea == eb then
            return CompareName(a, b)
        end
        return finish(ea < eb)
    elseif column == "power" then
        if (a.powerNum or 0) == (b.powerNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.powerNum or 0) < (b.powerNum or 0))
    elseif column == "stability" then
        if (a.stabilityNum or 0) == (b.stabilityNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.stabilityNum or 0) < (b.stabilityNum or 0))
    elseif column == "multiplier" then
        if (a.multiplierNum or 0) == (b.multiplierNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.multiplierNum or 0) < (b.multiplierNum or 0))
    elseif column == "superCrit" then
        if (a.superCritNum or 0) == (b.superCritNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.superCritNum or 0) < (b.superCritNum or 0))
    elseif column == "yield" then
        if (a.yieldNum or 0) == (b.yieldNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.yieldNum or 0) < (b.yieldNum or 0))
    elseif column == "have" then
        if (a.have or 0) == (b.have or 0) then
            return CompareName(a, b)
        end
        return finish((a.have or 0) < (b.have or 0))
    elseif column == "watch" then
        local wa = a.watched == true
        local wb = b.watched == true
        if wa == wb then
            return CompareName(a, b)
        end
        return finish(wa and not wb)
    end
    return CompareName(a, b)
end

local function SortRows(rows)
    local s = GetSettings()
    local column = s.potionSortColumn or "name"
    local ascending = s.potionSortAscending ~= false
    table.sort(rows, function(a, b)
        return CompareRows(a, b, column, ascending)
    end)
end

local function EffectCycle()
    local keys = { "" }
    if StockPiler3.Classify and StockPiler3.Classify.EffectFilterKeys then
        local list = StockPiler3.Classify.EffectFilterKeys()
        for i = 1, #list do
            keys[#keys + 1] = list[i]
        end
    end
    return keys
end

local function SyncEffectComboSelection()
    local w = "SP3TabPotionsEffectCombo"
    if not DoesWindowExist(w) then
        return
    end
    local cycle = EffectCycle()
    local cur = (GetSettings().potionEffectFilter) or ""
    local selected = 1
    for i = 1, #cycle do
        if cycle[i] == cur then
            selected = i
            break
        end
    end
    ComboBoxSetSelectedMenuItem(w, selected)
end

local function InitEffectCombo()
    local w = "SP3TabPotionsEffectCombo"
    if not DoesWindowExist(w) then
        return
    end
    ComboBoxClearMenuItems(w)
    ComboBoxAddMenuItem(w, T("potions.all_effects"))
    local cycle = EffectCycle()
    for i = 2, #cycle do
        ComboBoxAddMenuItem(w, EffectTextForRow(cycle[i]))
    end
    SyncEffectComboSelection()
end

local function UpdateSortHeaderLabels()
    local labels = {
        name = T("potions.sort.name"),
        level = T("potions.sort.level"),
        effect = T("potions.sort.effect"),
        power = T("potions.sort.power"),
        stability = T("potions.sort.stability"),
        multiplier = T("potions.sort.multiplier"),
        superCrit = T("potions.sort.super_crit"),
        yield = T("potions.sort.yield"),
        have = T("potions.sort.have"),
    }
    for key, win in pairs(SORT_HEADERS) do
        if DoesWindowExist(win) and labels[key] then
            ButtonSetText(win, labels[key])
        end
    end
    if DoesWindowExist("SP3TabPotionsSortRecipe") then
        ButtonSetText("SP3TabPotionsSortRecipe", T("potions.sort.recipe"))
    end
    if DoesWindowExist("SP3TabPotionsSortForget") then
        ButtonSetText("SP3TabPotionsSortForget", T("potions.sort.forget"))
    end
end

local function UpdateSortHeaders()
    UpdateSortHeaderLabels()
    local s = GetSettings()
    local col = s.potionSortColumn or "name"
    local asc = s.potionSortAscending ~= false
    for key, win in pairs(SORT_HEADERS) do
        if DoesWindowExist(win) then
            local up = win .. "UpArrow"
            local down = win .. "DownArrow"
            if key == col then
                WindowSetShowing(up, asc)
                WindowSetShowing(down, not asc)
            else
                WindowSetShowing(up, false)
                WindowSetShowing(down, false)
            end
        end
    end
end

local function ResolvePotionItemData(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler3.Inventory and StockPiler3.Inventory.ResolvePotionItemData then
        return StockPiler3.Inventory.ResolvePotionItemData(nil, uid, nil)
    end
    return nil
end

local function BuildVisibleList()
    local s = GetSettings()
    if type(s) ~= "table" then
        return
    end
    local nameFilter = s.potionNameFilter or ""
    local effectFilter = s.potionEffectFilter or ""
    -- Known-recipe filter omitted: never applied even if checkbox exists.
    local rows = {}

    if StockPiler3.Inventory and StockPiler3.Inventory.RefreshAllIfNeeded then
        StockPiler3.Inventory.RefreshAllIfNeeded()
    end
    if StockPiler3.Watch and StockPiler3.Watch.ScrubPristineDisabledStubs then
        StockPiler3.Watch.ScrubPristineDisabledStubs()
    end

    local Catalog = StockPiler3.Catalog
    local RS = StockPiler3.RecipeSpec
    local potions = Catalog and Catalog.ListPotionRecipeEntries and Catalog.ListPotionRecipeEntries() or {}

    for i = 1, #potions do
        local potion = potions[i]
        local potionKey = potion.potionRecipeKey or potion.potionKey
        local potionBase = potion.potion or potion
        local watch = Catalog and Catalog.GetWatch and Catalog.GetWatch(potionKey)
            or { enabled = false, targetStock = 40 }
        local watched = watch.enabled == true
        local have = Catalog and Catalog.PotionHaveCombined and Catalog.PotionHaveCombined(potionBase) or 0
        local uid = tonumber(potion.outputUid or potionBase.outputUid) or 0
        local itemData = ResolvePotionItemData(uid)
        local effectKey = nil
        if RS and RS.ResolveEffectKeyForPotion then
            effectKey = RS.ResolveEffectKeyForPotion(potionBase, {
                recipeKey = potion.recipeSpecKey,
                recipe = potion.recipe,
                itemData = itemData,
                stamp = true,
            })
        else
            effectKey = potion.effectKey or potionBase.effectKey
            if (not effectKey or effectKey == "") and itemData and StockPiler3.Classify and StockPiler3.Classify.GetEffectKey then
                effectKey = StockPiler3.Classify.GetEffectKey(itemData)
            end
        end
        local baseName = potion.name or potionBase.name or towstring(tostring(uid))
        local powerNum = tonumber(potion.power) or 0
        local stabilityNum = tonumber(potion.stability) or 0
        local multiplierNum = tonumber(potion.multiplier) or 0
        local superCritNum = tonumber(potion.superCrit) or 0
        local yieldNum = tonumber(potion.yield) or 0
        local row = {
            id = potionKey,
            potionKey = potionKey,
            potionBaseKey = potion.potionKey or potionBase.potionKey,
            recipeSpecKey = potion.recipeSpecKey,
            recipeLabel = potion.recipeLabel or L"",
            name = baseName,
            baseName = baseName,
            effectKey = effectKey,
            effectText = EffectTextForRow(effectKey),
            powerNum = powerNum,
            powerText = FormatSignedStat(powerNum),
            stabilityNum = stabilityNum,
            stabilityText = FormatSignedStat(stabilityNum),
            multiplierNum = multiplierNum,
            multiplierText = FormatSignedStat(multiplierNum),
            superCritNum = superCritNum,
            superCritText = FormatPercentStat(superCritNum),
            yieldNum = yieldNum,
            yieldText = FormatYieldStat(yieldNum),
            have = have,
            haveText = towstring(tostring(have)),
            watched = watched,
            iconNum = tonumber(potion.iconNum or potionBase.iconNum) or 0,
            itemData = itemData,
            uniqueID = uid,
        }
        ApplyPotionStats(row, itemData)
        row.nameR, row.nameG, row.nameB = ItemRarityNameColor(itemData)
        local recipe = potion.recipe
        if not recipe and RS and RS.GetRecipe and potion.recipeSpecKey then
            recipe = RS.GetRecipe(potion.recipeSpecKey)
        end
        if recipe and RS and RS.RecipeFingerprintStats then
            local stats = RS.RecipeFingerprintStats(recipe, uid)
            row.powerNum = stats.power
            row.powerText = FormatSignedStat(stats.power)
            row.stabilityNum = stats.stability
            row.stabilityText = FormatSignedStat(stats.stability)
            row.multiplierNum = stats.multiplier
            row.multiplierText = FormatSignedStat(stats.multiplier)
            row.superCritNum = stats.superCrit
            row.superCritText = FormatPercentStat(stats.superCrit)
            row.yieldNum = stats.yield
            row.yieldText = FormatYieldStat(stats.yield)
        end
        row.recipeData = BuildRecipeDataForPotion(
            baseName,
            recipe,
            row.levelNum or row.rankNum,
            uid,
            potionBase
        )
        row.hasRecipe = row.recipeData ~= nil
        if PassesFilters(row, nameFilter, effectFilter) then
            rows[#rows + 1] = row
        end
    end

    SortRows(rows)
    local order = {}
    for i = 1, #rows do
        order[i] = i
    end
    StockPiler3TabPotions.listData = rows
    StockPiler3TabPotions.displayOrder = order
end

local function SetIconTexture(iconWin, iconNum)
    if not DoesWindowExist(iconWin) then
        return
    end
    if iconNum and iconNum > 0 and type(GetIconData) == "function" then
        local ok, texture, x, y
        if StockPiler3.Debug and StockPiler3.Debug.TryCallQuiet then
            ok, texture, x, y = StockPiler3.Debug.TryCallQuiet("GetIconData", GetIconData, iconNum)
        else
            ok, texture, x, y = pcall(GetIconData, iconNum)
        end
        if ok and texture and texture ~= "" then
            DynamicImageSetTexture(iconWin, texture, x or 0, y or 0)
            if type(DynamicImageSetTextureScale) == "function" then
                DynamicImageSetTextureScale(iconWin, ICON_SCALE)
            end
            WindowSetShowing(iconWin, true)
            return
        end
    end
    DynamicImageSetTexture(iconWin, "", 0, 0)
    WindowSetShowing(iconWin, false)
end

local function RowDataFromActiveChild()
    local rowWindow = WindowGetParent(SystemData.ActiveWindow.name)
    local rowIndex = WindowGetId(rowWindow)
    local dataIndex = ListBoxGetDataIndex("SP3TabPotionsList", rowIndex)
    return StockPiler3TabPotions.listData[dataIndex]
end

local function AfterWatchToggle()
    if StockPiler3.Watch and StockPiler3.Watch.BumpGen then
        StockPiler3.Watch.BumpGen()
    end
    if StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Invalidate then
        StockPiler3.PlanSnapshot.Invalidate()
    end
    -- Sync-build so Watch tab has rows immediately (coalesce alone left empty plan).
    if StockPiler3.Planner and StockPiler3.Planner.Build then
        StockPiler3.Planner.Build({ force = true })
    else
        local Sch = StockPiler3.Scheduler
        if Sch and Sch.EnqueuePlanRebuild then
            Sch.EnqueuePlanRebuild()
        end
    end
    if StockPiler3.Ui and StockPiler3.Ui.MarkWatchUiDirty then
        StockPiler3.Ui.MarkWatchUiDirty()
    end
    if StockPiler3TabWatch and StockPiler3TabWatch.Refresh
        and StockPiler3Window and StockPiler3Window.SelectedTab == StockPiler3Window.TABS_WATCH
    then
        StockPiler3TabWatch.Refresh({ forcePlan = true })
    end
end

function StockPiler3TabPotions.Initialize()
    LabelSetText("SP3TabPotionsBannerTitle", T("potions.banner_title"))
    LabelSetText("SP3TabPotionsBannerText", T("potions.banner_text"))
    LabelSetText("SP3TabPotionsSearchLabel", T("potions.search"))
    LabelSetText("SP3TabPotionsEffectLabel", T("potions.effect"))
    UpdateSortHeaderLabels()

    local s = GetSettings()
    if DoesWindowExist("SP3TabPotionsSearchBox") then
        TextEditBoxSetText("SP3TabPotionsSearchBox", towstring(s.potionNameFilter or ""))
    end
    -- Omit known-recipe filter: hide checkbox + label; never apply.
    if DoesWindowExist("SP3TabPotionsFilterKnownRecipe") then
        WindowSetShowing("SP3TabPotionsFilterKnownRecipe", false)
    end
    if DoesWindowExist("SP3TabPotionsFilterKnownRecipeLabel") then
        WindowSetShowing("SP3TabPotionsFilterKnownRecipeLabel", false)
    end
    InitEffectCombo()
    UpdateSortHeaders()
end

function StockPiler3TabPotions.Refresh()
    if not DoesWindowExist(TAB_ROOT) then
        return
    end
    SyncEffectComboSelection()
    UpdateSortHeaders()
    BuildVisibleList()
    if DoesWindowExist("SP3TabPotionsList") then
        ListBoxSetDisplayOrder("SP3TabPotionsList", {})
        ListBoxSetDisplayOrder("SP3TabPotionsList", StockPiler3TabPotions.displayOrder)
        StockPiler3TabPotions.UpdateRows()
    end
end

function StockPiler3TabPotions.UpdateRows()
    if not SP3TabPotionsList then
        return
    end
    local numVisible = tonumber(SP3TabPotionsList.numVisibleRows) or 12
    local indices = SP3TabPotionsList.PopulatorIndices
    local active = {}
    if type(indices) == "table" then
        for rowIndex, dataIndex in ipairs(indices) do
            active[rowIndex] = dataIndex
        end
    end
    local listData = StockPiler3TabPotions.listData
    for rowIndex = 1, numVisible do
        local rowName = "SP3TabPotionsListRow" .. rowIndex
        if DoesWindowExist(rowName) then
            local dataIndex = active[rowIndex]
            local data = dataIndex and type(listData) == "table" and listData[dataIndex] or nil
            if data then
                WindowSetShowing(rowName, true)
                DefaultColor.SetListRowTint(rowName .. "Background", rowIndex, false)
                ButtonSetCheckButtonFlag(rowName .. "Watch", true)
                ButtonSetPressedFlag(rowName .. "Watch", data.watched == true)
                SetIconTexture(rowName .. "Icon", data.iconNum)
                LabelSetText(rowName .. "Name", data.name or L"")
                LabelSetTextColor(
                    rowName .. "Name",
                    tonumber(data.nameR) or 255,
                    tonumber(data.nameG) or 255,
                    tonumber(data.nameB) or 255
                )
                LabelSetText(rowName .. "Level", data.levelText or T("ui.dash"))
                LabelSetText(rowName .. "Effect", data.effectText or L"")
                LabelSetText(rowName .. "Power", data.powerText or L"0")
                LabelSetText(rowName .. "Stability", data.stabilityText or L"0")
                LabelSetText(rowName .. "Multiplier", data.multiplierText or L"0")
                LabelSetText(rowName .. "SuperCrit", data.superCritText or T("ui.dash"))
                LabelSetText(rowName .. "Yield", data.yieldText or T("ui.dash"))
                LabelSetText(rowName .. "Have", data.haveText or towstring(tostring(data.have or 0)))
                LabelSetTextColor(rowName .. "Have", 255, 255, 255)
                if DoesWindowExist(rowName .. "Recipe") then
                    WindowSetShowing(rowName .. "Recipe", data.hasRecipe == true)
                end
                if DoesWindowExist(rowName .. "Forget") then
                    WindowSetShowing(rowName .. "Forget", data.hasRecipe == true)
                end
            else
                WindowSetShowing(rowName, false)
            end
        end
    end
end

function StockPiler3TabPotions.OnToggleKnownRecipeFilter()
    -- Omitted: keep checkbox hidden; do not persist or apply filter.
    if DoesWindowExist("SP3TabPotionsFilterKnownRecipe") then
        WindowSetShowing("SP3TabPotionsFilterKnownRecipe", false)
        ButtonSetPressedFlag("SP3TabPotionsFilterKnownRecipe", false)
    end
end

function StockPiler3TabPotions.OnSearchChanged()
    local text = TextEditBoxGetText("SP3TabPotionsSearchBox")
    GetSettings().potionNameFilter = ToNarrow(text)
    StockPiler3TabPotions.Refresh()
end

function StockPiler3TabPotions.OnEffectComboChanged()
    local idx = tonumber(ComboBoxGetSelectedMenuItem("SP3TabPotionsEffectCombo")) or 1
    local cycle = EffectCycle()
    local newFilter = cycle[idx] or ""
    local s = GetSettings()
    if s.potionEffectFilter == newFilter then
        return
    end
    s.potionEffectFilter = newFilter
    StockPiler3TabPotions.Refresh()
end

function StockPiler3TabPotions.OnSortColumn()
    local id = WindowGetId(SystemData.ActiveWindow.name)
    local col = SORT_IDS[id]
    if not col then
        return
    end
    local s = GetSettings()
    if s.potionSortColumn == col then
        s.potionSortAscending = not (s.potionSortAscending ~= false)
    else
        s.potionSortColumn = col
        s.potionSortAscending = true
    end
    StockPiler3TabPotions.Refresh()
end

function StockPiler3TabPotions.OnToggleWatch()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    local potionKey = data.potionKey or data.id
    local enabled = ButtonGetPressedFlag(SystemData.ActiveWindow.name) == true
    if StockPiler3.Watch and StockPiler3.Watch.SetEnabled then
        StockPiler3.Watch.SetEnabled(potionKey, enabled, { fromPotionsToggle = true })
    else
        local watch = StockPiler3.Catalog and StockPiler3.Catalog.EnsureWatch and StockPiler3.Catalog.EnsureWatch(potionKey)
        if type(watch) == "table" then
            watch.enabled = enabled
            if enabled then
                watch.autoGrow = true
            end
        end
        if StockPiler3.Watch and StockPiler3.Watch.BumpGen then
            StockPiler3.Watch.BumpGen()
        end
    end
    data.watched = enabled
    AfterWatchToggle()
    if StockPiler3TabPotions.UpdateRows then
        StockPiler3TabPotions.UpdateRows()
    end
end

function StockPiler3TabPotions.OnMouseOverIcon()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    local itemData = data.itemData
    if StockPiler3.Inventory and StockPiler3.Inventory.ShowItemTooltip
        and StockPiler3.Inventory.ShowItemTooltip(itemData, SystemData.ActiveWindow.name)
    then
        return
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, data.name or T("ui.potion_fallback"))
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler3TabPotions.OnMouseOverRecipe()
    local data = RowDataFromActiveChild()
    if not data or not data.recipeData then
        return
    end
    if StockPiler3.RecipeTooltip and StockPiler3.RecipeTooltip.Show then
        StockPiler3.RecipeTooltip.Show(SystemData.ActiveWindow.name, data.recipeData)
    end
end

function StockPiler3TabPotions.ConfirmForgetRecipe()
    local outputUid = StockPiler3TabPotions._pendingForgetOutputUid
    local recipeSpecKey = StockPiler3TabPotions._pendingForgetRecipeKey
    local label = StockPiler3TabPotions._pendingForgetLabel or recipeSpecKey
    StockPiler3TabPotions._pendingForgetOutputUid = nil
    StockPiler3TabPotions._pendingForgetRecipeKey = nil
    StockPiler3TabPotions._pendingForgetKey = nil
    StockPiler3TabPotions._pendingForgetLabel = nil
    local forgot = false
    if StockPiler3.Catalog and StockPiler3.Catalog.ForgetPotionRecipeLink then
        forgot = StockPiler3.Catalog.ForgetPotionRecipeLink(outputUid, recipeSpecKey) == true
    end
    if forgot then
        if StockPiler3.Ui and StockPiler3.Ui.Print then
            StockPiler3.Ui.Print(T("ui.forgot_recipe", { name = label }))
        end
        StockPiler3TabPotions.Refresh()
    end
end

function StockPiler3TabPotions.OnForgetRow()
    local data = RowDataFromActiveChild()
    if not data or not data.hasRecipe then
        return
    end
    local outputUid = tonumber(data.uniqueID) or 0
    local recipeSpecKey = data.recipeSpecKey
    local label = data.name or T("ui.potion_fallback")
    StockPiler3TabPotions._pendingForgetOutputUid = outputUid
    StockPiler3TabPotions._pendingForgetRecipeKey = recipeSpecKey
    StockPiler3TabPotions._pendingForgetKey = data.potionKey
    StockPiler3TabPotions._pendingForgetLabel = label
    if type(DialogManager) == "table" and type(DialogManager.MakeTwoButtonDialog) == "function" then
        local yes = GetString and GetString(StringTables.Default.LABEL_YES) or T("ui.yes")
        local no = GetString and GetString(StringTables.Default.LABEL_NO) or T("ui.no")
        DialogManager.MakeTwoButtonDialog(
            T("potions.forget_confirm", { name = label }),
            yes,
            StockPiler3TabPotions.ConfirmForgetRecipe,
            no,
            nil
        )
        return
    end
    StockPiler3TabPotions.ConfirmForgetRecipe()
end

function StockPiler3TabPotions.OnMouseOverForget()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("potions.forget_tip"))
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end
