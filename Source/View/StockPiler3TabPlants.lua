----------------------------------------------------------------
-- StockPiler3TabPlants -- known harvested plants (watch / filters / forget)
----------------------------------------------------------------

StockPiler3TabPlants = {}

local function T(key, tokens)
    if StockPiler3.T then
        return StockPiler3.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

StockPiler3TabPlants.listData = {}
StockPiler3TabPlants.displayOrder = {}

local ICON_SCALE = 0.34

local SORT_IDS = {
    [1] = "name",
    [2] = "effect",
    [3] = "power",
    [4] = "stability",
    [5] = "superCrit",
    [6] = "stock",
    [7] = "stock",
    [8] = "watch",
    [9] = "level",
    [10] = "multiplier",
    [11] = "duration",
}

local SORT_HEADERS = {
    watch = "SP3TabPlantsSortWatch",
    name = "SP3TabPlantsSortName",
    level = "SP3TabPlantsSortLevel",
    effect = "SP3TabPlantsSortEffect",
    power = "SP3TabPlantsSortPower",
    stability = "SP3TabPlantsSortStability",
    multiplier = "SP3TabPlantsSortMultiplier",
    duration = "SP3TabPlantsSortDuration",
    superCrit = "SP3TabPlantsSortSuperCrit",
    stock = "SP3TabPlantsSortStock",
}

local function ToNarrow(text)
    if StockPiler3.Persistence and StockPiler3.Persistence.ToNarrow then
        return StockPiler3.Persistence.ToNarrow(text)
    end
    return tostring(text or "")
end

local function GetSettings()
    if StockPiler3.Persistence and StockPiler3.Persistence.GetSettings then
        return StockPiler3.Persistence.GetSettings()
    end
    StockPiler3.Settings = StockPiler3.Settings or {}
    return StockPiler3.Settings
end

local function ItemRarityNameColor(itemData)
    if itemData and DataUtils and DataUtils.GetItemRarityColor then
        local ok, color = pcall(DataUtils.GetItemRarityColor, itemData)
        if ok and type(color) == "table" then
            return tonumber(color.r) or 255, tonumber(color.g) or 255, tonumber(color.b) or 255
        end
    end
    return 255, 255, 255
end

local function FormatSignedStat(n)
    n = tonumber(n) or 0
    if n == 0 then
        return T("ui.dash")
    end
    if n > 0 then
        return towstring("+" .. tostring(n))
    end
    return towstring(tostring(n))
end

-- Match Potions tab: SPECIAL_CHANCE is already a percent points value (1 → "1%").
local function FormatPercentStat(n)
    n = tonumber(n) or 0
    if n == 0 then
        return T("ui.dash")
    end
    return towstring(tostring(n) .. "%")
end

local function EffectTextForRow(effectKey)
    if type(effectKey) == "string" and effectKey ~= "" then
        local RS = StockPiler3.RecipeSpec
        if RS and RS.NormalizeEffectKeyForUi then
            effectKey = RS.NormalizeEffectKeyForUi(effectKey) or effectKey
        end
        if StockPiler3.Classify and StockPiler3.Classify.EffectShortLabel then
            local label = StockPiler3.Classify.EffectShortLabel(effectKey)
            if label ~= nil and label ~= L"" then
                return label
            end
        end
    end
    return T("ui.dash")
end

local function IconMarkup(iconNum)
    iconNum = tonumber(iconNum) or 0
    if iconNum <= 0 then
        return L""
    end
    return towstring(string.format("<icon%05d> ", iconNum))
end

local function CompareName(a, b)
    return string.lower(ToNarrow(a.name)) < string.lower(ToNarrow(b.name))
end

local function CompareRows(a, b, column, ascending)
    local function finish(less)
        if ascending then
            return less
        end
        return not less
    end
    if column == "level" then
        if (a.levelNum or 0) == (b.levelNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.levelNum or 0) < (b.levelNum or 0))
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
    elseif column == "duration" then
        if (a.durationNum or 0) == (b.durationNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.durationNum or 0) < (b.durationNum or 0))
    elseif column == "superCrit" then
        if (a.superCritNum or 0) == (b.superCritNum or 0) then
            return CompareName(a, b)
        end
        return finish((a.superCritNum or 0) < (b.superCritNum or 0))
    elseif column == "stock" or column == "have" then
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
    local column = s.plantSortColumn or "name"
    local ascending = s.plantSortAscending ~= false
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
    local w = "SP3TabPlantsEffectCombo"
    if not DoesWindowExist(w) then
        return
    end
    local cycle = EffectCycle()
    local cur = (GetSettings().plantEffectFilter) or ""
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
    local w = "SP3TabPlantsEffectCombo"
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
        name = T("plants.sort.name"),
        level = T("plants.sort.level"),
        effect = T("plants.sort.effect"),
        power = T("plants.sort.power"),
        stability = T("plants.sort.stability"),
        multiplier = T("plants.sort.multiplier"),
        duration = T("plants.sort.duration"),
        superCrit = T("plants.sort.super_crit"),
        stock = T("plants.sort.stock"),
    }
    for key, win in pairs(SORT_HEADERS) do
        if DoesWindowExist(win) and labels[key] then
            ButtonSetText(win, labels[key])
        end
    end
    if DoesWindowExist("SP3TabPlantsSortRecipes") then
        ButtonSetText("SP3TabPlantsSortRecipes", T("plants.sort.recipes"))
    end
    if DoesWindowExist("SP3TabPlantsSortForget") then
        ButtonSetText("SP3TabPlantsSortForget", T("plants.sort.forget"))
    end
end

local function UpdateSortHeaders()
    UpdateSortHeaderLabels()
    local s = GetSettings()
    local col = s.plantSortColumn or "name"
    local asc = s.plantSortAscending ~= false
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

local function BuildVisibleList()
    local s = GetSettings()
    if type(s) ~= "table" then
        return
    end
    local nameFilter = string.lower(tostring(s.plantNameFilter or ""))
    local effectFilter = s.plantEffectFilter or ""
    local rows = {}

    if StockPiler3.Inventory and StockPiler3.Inventory.RefreshAllIfNeeded then
        StockPiler3.Inventory.RefreshAllIfNeeded()
    end

    local Catalog = StockPiler3.Catalog
    local plants = Catalog and Catalog.ListPlantEntries and Catalog.ListPlantEntries() or {}

    for i = 1, #plants do
        local plant = plants[i]
        local plantKey = plant.plantKey
        local watch = Catalog and Catalog.GetPlantWatch and Catalog.GetPlantWatch(plantKey)
            or { enabled = false, targetStock = 40 }
        local watched = watch.enabled == true
        local have = tonumber(plant.have) or 0
        if Catalog and Catalog.PlantHave then
            have = Catalog.PlantHave(plant.plantUid)
        end
        local effectKey = plant.effectKey
        local include = true
        if nameFilter ~= "" then
            local nm = string.lower(ToNarrow(plant.name))
            if string.find(nm, nameFilter, 1, true) == nil then
                include = false
            end
        end
        if include and effectFilter ~= "" and tostring(effectKey or "") ~= effectFilter then
            include = false
        end
        if include then
            local powerNum = tonumber(plant.power) or 0
            local stabilityNum = tonumber(plant.stability) or 0
            local durationNum = tonumber(plant.duration) or 0
            local multiplierNum = tonumber(plant.multiplier) or 0
            local superCritNum = tonumber(plant.superCrit) or 0
            local levelNum = tonumber(plant.apoLevel) or 0
            local stockW = towstring(tostring(have))
            local nameR, nameG, nameB = ItemRarityNameColor(plant.itemData)
            rows[#rows + 1] = {
                id = plantKey,
                plantKey = plantKey,
                plantUid = plant.plantUid,
                seedUid = plant.seedUid,
                name = plant.name,
                effectKey = effectKey,
                effectText = EffectTextForRow(effectKey),
                powerNum = powerNum,
                powerText = FormatSignedStat(powerNum),
                stabilityNum = stabilityNum,
                stabilityText = FormatSignedStat(stabilityNum),
                durationNum = durationNum,
                durationText = FormatSignedStat(durationNum),
                multiplierNum = multiplierNum,
                multiplierText = FormatSignedStat(multiplierNum),
                superCritNum = superCritNum,
                superCritText = FormatPercentStat(superCritNum),
                stockText = stockW,
                haveText = L"",
                yieldText = stockW,
                levelNum = levelNum,
                levelText = towstring(levelNum > 0 and tostring(levelNum) or ""),
                have = have,
                watched = watched,
                iconNum = tonumber(plant.iconNum) or 0,
                itemData = plant.itemData,
                recipes = plant.recipes,
                recipeCount = tonumber(plant.recipeCount) or 0,
                hasRecipes = (tonumber(plant.recipeCount) or 0) > 0,
                nameR = nameR,
                nameG = nameG,
                nameB = nameB,
                kind = "plant",
            }
        end
    end

    SortRows(rows)
    StockPiler3TabPlants.listData = rows
    local order = {}
    for i = 1, #rows do
        order[i] = i
    end
    StockPiler3TabPlants.displayOrder = order
end

function StockPiler3TabPlants.Initialize()
    if DoesWindowExist("SP3TabPlantsBannerTitle") then
        LabelSetText("SP3TabPlantsBannerTitle", T("plants.banner_title"))
    end
    if DoesWindowExist("SP3TabPlantsBannerText") then
        LabelSetText("SP3TabPlantsBannerText", T("plants.banner_text"))
    end
    if DoesWindowExist("SP3TabPlantsSearchLabel") then
        LabelSetText("SP3TabPlantsSearchLabel", T("potions.search"))
    end
    if DoesWindowExist("SP3TabPlantsEffectLabel") then
        LabelSetText("SP3TabPlantsEffectLabel", T("potions.effect"))
    end
    if DoesWindowExist("SP3TabPlantsFilterUnused") then
        WindowSetShowing("SP3TabPlantsFilterUnused", false)
    end
    if DoesWindowExist("SP3TabPlantsFilterUnusedLabel") then
        WindowSetShowing("SP3TabPlantsFilterUnusedLabel", false)
    end
    local s = GetSettings()
    if DoesWindowExist("SP3TabPlantsSearchBox") then
        TextEditBoxSetText("SP3TabPlantsSearchBox", towstring(s.plantNameFilter or ""))
    end
    InitEffectCombo()
    UpdateSortHeaders()
    StockPiler3TabPlants.Refresh()
end

function StockPiler3TabPlants.Refresh()
    UpdateSortHeaders()
    BuildVisibleList()
    if DoesWindowExist("SP3TabPlantsList") then
        ListBoxSetDisplayOrder("SP3TabPlantsList", {})
        ListBoxSetDisplayOrder("SP3TabPlantsList", StockPiler3TabPlants.displayOrder)
        StockPiler3TabPlants.UpdateRows()
    end
end

function StockPiler3TabPlants.UpdateRows()
    if not SP3TabPlantsList then
        return
    end
    local numVisible = tonumber(SP3TabPlantsList.numVisibleRows) or 12
    local indices = SP3TabPlantsList.PopulatorIndices
    local listData = StockPiler3TabPlants.listData
    for rowIndex = 1, numVisible do
        local rowName = "SP3TabPlantsListRow" .. tostring(rowIndex)
        if DoesWindowExist(rowName) then
            local dataIndex = type(indices) == "table" and indices[rowIndex] or nil
            local data = type(listData) == "table" and dataIndex and listData[dataIndex] or nil
            if type(data) == "table" then
                WindowSetShowing(rowName, true)
                if DefaultColor and DefaultColor.SetListRowTint then
                    DefaultColor.SetListRowTint(rowName .. "Background", rowIndex, false)
                end
                if DoesWindowExist(rowName .. "Watch") then
                    ButtonSetPressedFlag(rowName .. "Watch", data.watched == true)
                end
                if DoesWindowExist(rowName .. "Icon") then
                    if data.iconNum and data.iconNum > 0 then
                        local tex, x, y = GetIconData(data.iconNum)
                        DynamicImageSetTexture(rowName .. "Icon", tex, x, y)
                        DynamicImageSetTextureScale(rowName .. "Icon", ICON_SCALE)
                        WindowSetShowing(rowName .. "Icon", true)
                    else
                        WindowSetShowing(rowName .. "Icon", false)
                    end
                end
                if DoesWindowExist(rowName .. "Name") then
                    LabelSetText(rowName .. "Name", data.name or L"")
                    LabelSetTextColor(rowName .. "Name", data.nameR or 255, data.nameG or 255, data.nameB or 255)
                end
                if DoesWindowExist(rowName .. "Recipe") then
                    WindowSetShowing(rowName .. "Recipe", data.hasRecipes == true)
                end
            else
                WindowSetShowing(rowName, false)
            end
        end
    end
end

local function RowDataFromSender()
    local rowIndex = WindowGetId(WindowGetParent(SystemData.ActiveWindow.name))
    local dataIndex = ListBoxGetDataIndex("SP3TabPlantsList", rowIndex)
    return StockPiler3TabPlants.listData[dataIndex]
end

function StockPiler3TabPlants.OnToggleWatch()
    local data = RowDataFromSender()
    if type(data) ~= "table" or data.plantKey == nil then
        return
    end
    local Watch = StockPiler3.Watch
    if not (Watch and Watch.SetPlantEnabled) then
        return
    end
    local cur = Watch.GetPlantWatch and Watch.GetPlantWatch(data.plantKey)
    local enable = not (cur and cur.enabled == true)
    Watch.SetPlantEnabled(data.plantKey, enable, { fromPlantsToggle = true })
    data.watched = enable
    if DoesWindowExist(SystemData.ActiveWindow.name) then
        ButtonSetPressedFlag(SystemData.ActiveWindow.name, enable)
    end
    if StockPiler3.Scheduler and StockPiler3.Scheduler.EnqueuePlanRebuild then
        StockPiler3.Scheduler.EnqueuePlanRebuild()
    end
    if StockPiler3TabWatch and StockPiler3TabWatch.Refresh then
        StockPiler3TabWatch.Refresh({ forcePlan = true })
    end
end

function StockPiler3TabPlants.OnSortColumn()
    local id = WindowGetId(SystemData.ActiveWindow.name)
    local col = SORT_IDS[id]
    if col == nil then
        return
    end
    local s = GetSettings()
    if s.plantSortColumn == col then
        s.plantSortAscending = not (s.plantSortAscending ~= false)
    else
        s.plantSortColumn = col
        s.plantSortAscending = true
    end
    UpdateSortHeaders()
    StockPiler3TabPlants.Refresh()
end

function StockPiler3TabPlants.OnSearchChanged()
    local s = GetSettings()
    if DoesWindowExist("SP3TabPlantsSearchBox") then
        s.plantNameFilter = ToNarrow(TextEditBoxGetText("SP3TabPlantsSearchBox"))
    end
    StockPiler3TabPlants.Refresh()
end

function StockPiler3TabPlants.OnEffectComboChanged()
    local s = GetSettings()
    local sel = ComboBoxGetSelectedMenuItem("SP3TabPlantsEffectCombo")
    local cycle = EffectCycle()
    s.plantEffectFilter = cycle[sel] or ""
    StockPiler3TabPlants.Refresh()
end

function StockPiler3TabPlants.OnToggleUnused()
end

function StockPiler3TabPlants.OnMouseOverIcon()
    local data = RowDataFromSender()
    if type(data) ~= "table" then
        return
    end
    local itemData = data.itemData
    local uid = tonumber(data.plantUid) or 0
    if StockPiler3.Inventory and StockPiler3.Inventory.ResolvePotionItemData and uid > 0 then
        itemData = StockPiler3.Inventory.ResolvePotionItemData(nil, uid, itemData) or itemData
    end
    if StockPiler3.Inventory and StockPiler3.Inventory.ShowItemTooltip
        and StockPiler3.Inventory.ShowItemTooltip(itemData, SystemData.ActiveWindow.name, { allowWithoutUse = true })
    then
        return
    end
    -- Same placeholder as Potions when bag/DB tooltip cannot be built.
    if type(Tooltips) == "table" and type(Tooltips.CreateTextOnlyTooltip) == "function" then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            data.name or T("ui.plant_fallback")
        )
        if Tooltips.AnchorTooltip and Tooltips.ANCHOR_WINDOW_RIGHT then
            Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
        end
    end
end

function StockPiler3TabPlants.OnMouseOverRecipe()
    local data = RowDataFromSender()
    if type(data) ~= "table" or type(data.recipes) ~= "table" then
        return
    end
    local tipRows = {}
    local seen = {}
    for i = 1, #data.recipes do
        local r = data.recipes[i]
        local potions = type(r) == "table" and r.potions or nil
        if type(potions) == "table" then
            for j = 1, #potions do
                local p = potions[j]
                if type(p) == "table" then
                    local uid = tonumber(p.outputUid) or 0
                    local key = uid > 0 and tostring(uid) or ToNarrow(p.name)
                    if key ~= "" and seen[key] ~= true then
                        seen[key] = true
                        local itemData = p.itemData
                        if uid > 0 and StockPiler3.Inventory and StockPiler3.Inventory.ResolvePotionItemData then
                            itemData = StockPiler3.Inventory.ResolvePotionItemData(nil, uid, itemData) or itemData
                        end
                        local iconNum = tonumber(p.iconNum) or tonumber(itemData and itemData.iconNum) or 0
                        local rR, rG, rB = ItemRarityNameColor(itemData or p)
                        tipRows[#tipRows + 1] = {
                            sort = string.lower(ToNarrow(p.name)),
                            text = IconMarkup(iconNum) .. (p.name or L""),
                            kind = "body",
                            color = { r = rR, g = rG, b = rB },
                        }
                    end
                end
            end
        elseif type(r) == "table" and type(r.potionNames) == "table" then
            for j = 1, #r.potionNames do
                local nm = ToNarrow(r.potionNames[j])
                if nm ~= "" and seen[nm] ~= true then
                    seen[nm] = true
                    tipRows[#tipRows + 1] = {
                        sort = string.lower(nm),
                        text = r.potionNames[j],
                        kind = "body",
                    }
                end
            end
        end
    end
    table.sort(tipRows, function(a, b)
        return (a.sort or "") < (b.sort or "")
    end)
    if #tipRows == 0 then
        tipRows[1] = { text = T("plants.recipes_none"), kind = "meta" }
    end
    table.insert(tipRows, 1, {
        text = T("plants.recipes_tip_title"),
        kind = "title",
    })
    if StockPiler3.RecipeTooltip and StockPiler3.RecipeTooltip.ShowColoredRows then
        StockPiler3.RecipeTooltip.ShowColoredRows(
            SystemData.ActiveWindow.name,
            tipRows,
            Tooltips and Tooltips.ANCHOR_WINDOW_RIGHT
        )
        return
    end
    local lines = {}
    for i = 1, #tipRows do
        lines[#lines + 1] = ToNarrow(tipRows[i].text)
    end
    if Tooltips and Tooltips.CreateTextOnlyTooltip then
        Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, towstring(table.concat(lines, "\n")))
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
    end
end

function StockPiler3TabPlants.OnMouseOverForget()
    if Tooltips and Tooltips.CreateTextOnlyTooltip then
        Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("tip.plants.forget"))
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
    end
end

function StockPiler3TabPlants.ConfirmForgetPlant()
    local uid = tonumber(StockPiler3TabPlants._pendingForgetUid) or 0
    StockPiler3TabPlants._pendingForgetUid = nil
    StockPiler3TabPlants._pendingForgetLabel = nil
    if uid <= 0 then
        return
    end
    if StockPiler3.Catalog and StockPiler3.Catalog.ForgetPlant then
        StockPiler3.Catalog.ForgetPlant(uid)
    end
    StockPiler3TabPlants.Refresh()
    if StockPiler3TabWatch and StockPiler3TabWatch.Refresh then
        StockPiler3TabWatch.Refresh({ forcePlan = true })
    end
end

function StockPiler3TabPlants.OnForgetRow()
    local data = RowDataFromSender()
    if type(data) ~= "table" then
        return
    end
    local uid = tonumber(data.plantUid) or 0
    if uid <= 0 then
        return
    end
    local name = ToNarrow(data.name)
    StockPiler3TabPlants._pendingForgetUid = uid
    StockPiler3TabPlants._pendingForgetLabel = name
    if type(DialogManager) == "table" and type(DialogManager.MakeTwoButtonDialog) == "function" then
        local yes = GetString and GetString(StringTables.Default.LABEL_YES) or T("ui.yes")
        local no = GetString and GetString(StringTables.Default.LABEL_NO) or T("ui.no")
        DialogManager.MakeTwoButtonDialog(
            T("plants.forget_confirm", { name = towstring(name) }),
            yes,
            StockPiler3TabPlants.ConfirmForgetPlant,
            no,
            nil
        )
        return
    end
    StockPiler3TabPlants.ConfirmForgetPlant()
end
