----------------------------------------------------------------
-- StockPiler3TabWatch -- watched potion dashboard
----------------------------------------------------------------

StockPiler3TabWatch = {}
StockPiler3TabWatch.listData = {}
StockPiler3TabWatch.displayOrder = {}

local function T(key, tokens)
    if StockPiler3.T then
        return StockPiler3.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

local TAB_ROOT = "SP3TabWatch"
local ENABLE_WIN = "SP3TabWatchEnable"
local ADDITIVES_WIN = "SP3TabWatchAdditives"
local AUTOBUY_WIN = "SP3TabWatchAutoBuy"
local SEED_BUFFER_ENABLE_WIN = "SP3TabWatchSeedBufferEnable"
local COMBAT_PAUSE_WIN = "SP3TabWatchCombatPause"

local COLOR_OK = { 80, 200, 80 }
local COLOR_WARN = { 220, 180, 60 }
local COLOR_BLOCK = { 220, 70, 70 }
local COLOR_GRAY = { 140, 140, 140 }

local ICON_SCALE = 0.34
local TARGET_MAX = 200
local syncingUi = false

local function CharRow(create)
    if StockPiler3.Persistence and StockPiler3.Persistence.GetCharacterBucket then
        return StockPiler3.Persistence.GetCharacterBucket(create ~= false)
    end
    return nil
end

local function CanAutoGrowUi()
    local Caps = StockPiler3.TradeSkillCaps
    return Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true
end

local function CanAutoBuyUi()
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.CanApothecary and Caps.CanApothecary() == true then
        return true
    end
    return CanAutoGrowUi()
end

local function OnOff(flag)
    return flag and T("boot.on") or T("boot.off")
end

local function NotifySettings(msg)
    if StockPiler3.Ui and StockPiler3.Ui.Print then
        StockPiler3.Ui.Print(msg)
    elseif StockPiler3.Debug and StockPiler3.Debug.Print then
        StockPiler3.Debug.Print(msg)
    end
end

local function TintStepper(bgWin)
    if DoesWindowExist(bgWin) and WindowSetTintColor then
        WindowSetTintColor(bgWin, 40, 40, 40)
    end
end

local function SetChipNumber(valueWin, chipWin, value)
    if DoesWindowExist(valueWin) then
        LabelSetText(valueWin, towstring(tostring(value)))
        LabelSetTextColor(valueWin, 255, 255, 255)
    end
    if DoesWindowExist(chipWin) then
        TintStepper(chipWin .. "Bg")
    end
end

local function ChipDelta(flags, dir)
    local step = 1
    if SystemData and SystemData.ButtonFlags and flags == SystemData.ButtonFlags.SHIFT then
        step = 10
    elseif type(flags) == "number" and flags ~= 0 then
        -- Some clients pass combined flags; treat nonzero as shift-ish when SHIFT bit present.
        if SystemData and SystemData.ButtonFlags and SystemData.ButtonFlags.SHIFT then
            if bit and bit.band and bit.band(flags, SystemData.ButtonFlags.SHIFT) ~= 0 then
                step = 10
            end
        end
    end
    return step * (dir or 1)
end

local function Clamp(n, lo, hi)
    n = tonumber(n) or lo
    if n < lo then
        return lo
    end
    if n > hi then
        return hi
    end
    return math.floor(n)
end

local function SetIconTexture(iconWin, iconNum)
    if not DoesWindowExist(iconWin) then
        return
    end
    if iconNum and iconNum > 0 and type(GetIconData) == "function" then
        local ok, texture, x, y = pcall(GetIconData, iconNum)
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

local function ApplyStatusColor(labelWin, statusKey)
    statusKey = tostring(statusKey or "")
    local c = COLOR_GRAY
    if statusKey == "potion_stocked" or statusKey == "ready_to_craft" then
        c = COLOR_OK
    elseif statusKey == "ready_to_craft_shared"
        or statusKey == "restocking"
        or statusKey == "need_seeds"
    then
        c = COLOR_WARN
    elseif statusKey == "no_recipe"
        or statusKey == "enable_autogrow"
        or statusKey == "need_apothecary"
        or statusKey == "need_skill"
        or statusKey == "buy_ingredients"
    then
        c = COLOR_BLOCK
    end
    LabelSetTextColor(labelWin, c[1], c[2], c[3])
end

local function EnsureWatchNameRarityColors(data)
    if type(data) ~= "table" then
        return 255, 255, 255
    end
    if data.nameR then
        return tonumber(data.nameR) or 255, tonumber(data.nameG) or 255, tonumber(data.nameB) or 255
    end
    local itemData = data.itemData
    if itemData and DataUtils and DataUtils.GetItemRarityColor then
        local ok, color = pcall(DataUtils.GetItemRarityColor, itemData)
        if ok and type(color) == "table" then
            data.nameR = tonumber(color.r) or 255
            data.nameG = tonumber(color.g) or 255
            data.nameB = tonumber(color.b) or 255
            return data.nameR, data.nameG, data.nameB
        end
    end
    return 255, 255, 255
end

local function GetRowCraftUiState(data)
    local Brew = StockPiler3.Brew
    if not Brew or type(data) ~= "table" then
        return "idle"
    end
    local session = Brew.GetSession and Brew.GetSession()
    if type(session) ~= "table" then
        return "idle"
    end
    local phase = tostring(session.phase or "idle")
    if phase == "idle" then
        return "idle"
    end
    local rowKey = tostring(data.potionRecipeKey or data.id or data.potionKey or "")
    local sessKey = tostring(session.potionRecipeKey or session.potionKey or session.rowId or "")
    if rowKey ~= "" and sessKey ~= "" and rowKey == sessKey then
        if phase == "loading" then
            return "load"
        end
        if phase == "loaded" then
            return "brew"
        end
    end
    return "idle"
end

--- True when Craftable label is green: bags can craft and seed buffer is safe.
--- Shared mats do not block green (Status may still show Ready-shared).
local function RowCraftableGreen(data)
    if type(data) ~= "table" then
        return false
    end
    if data.craftableSafe == true then
        return true
    end
    if data.craftableSafe == false then
        return false
    end
    -- Fallback if plan row lacks stamp (tests / partial rows).
    if (tonumber(data.craftable) or 0) <= 0 then
        return false
    end
    return data.seedBufferShort ~= true
end

local function SetButtonTextColorAll(windowName, r, g, b)
    if not windowName or not DoesWindowExist(windowName) or type(ButtonSetTextColor) ~= "function" then
        return
    end
    local states = { 0, 1, 2, 3, 4 }
    if Button and Button.ButtonState then
        states = {
            Button.ButtonState.NORMAL or 0,
            Button.ButtonState.HIGHLIGHTED or 1,
            Button.ButtonState.PRESSED or 2,
            Button.ButtonState.PRESSED_HIGHLIGHTED or 3,
            Button.ButtonState.DISABLED or 4,
        }
    end
    for i = 1, #states do
        pcall(ButtonSetTextColor, windowName, states[i], r, g, b)
    end
end

local function ApplyRowBrewButton(btnWin, data)
    if not DoesWindowExist(btnWin) then
        return
    end
    local craftableGreen = RowCraftableGreen(data)
    local state = GetRowCraftUiState(data)
    -- This row's apo session is loaded: always show Brew (ready to perform).
    if state == "brew" then
        ButtonSetText(btnWin, T("watch.chip_brew"))
        ButtonSetDisabledFlag(btnWin, false)
        SetButtonTextColorAll(btnWin, COLOR_OK[1], COLOR_OK[2], COLOR_OK[3])
        return
    end
    if not craftableGreen then
        ButtonSetText(btnWin, T("watch.chip_load"))
        ButtonSetDisabledFlag(btnWin, true)
        SetButtonTextColorAll(btnWin, COLOR_GRAY[1], COLOR_GRAY[2], COLOR_GRAY[3])
        return
    end
    -- Idle or loading: yellow Load (green Craftable, apo not ready to perform).
    ButtonSetDisabledFlag(btnWin, false)
    ButtonSetText(btnWin, T("watch.chip_load"))
    SetButtonTextColorAll(btnWin, COLOR_WARN[1], COLOR_WARN[2], COLOR_WARN[3])
end

local function PatchWatchRowsLiveCounts(rows)
    if type(rows) ~= "table" then
        return
    end
    if StockPiler3.Planner and StockPiler3.Planner.PatchWatchRowsLiveCounts then
        StockPiler3.Planner.PatchWatchRowsLiveCounts(rows)
        return
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local uid = tonumber(row.uniqueID) or tonumber(row.outputUid) or 0
            if uid > 0 and StockPiler3.Inventory and StockPiler3.Inventory.CountByUid then
                local have = tonumber(StockPiler3.Inventory.CountByUid(uid)) or 0
                row.potionHave = have
                row.stockText = towstring(tostring(have))
                local target = tonumber(row.target) or 0
                row.potionDeficit = math.max(0, target - have)
            end
        end
    end
end

local function BumpWatch()
    if StockPiler3.Watch and StockPiler3.Watch.BumpGen then
        StockPiler3.Watch.BumpGen()
    end
    if StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Invalidate then
        StockPiler3.PlanSnapshot.Invalidate()
    end
end

--- Soft demand change: Bump + immediate AutoGrow status reconcile + coalesced PlanRebuild.
local function AfterWatchSettingsChanged()
    BumpWatch()
    -- Flip Enable AutoGrow ↔ Restocking now (UI throttle / plan gap must not leave stale status).
    if StockPiler3.Planner and StockPiler3.Planner.ReconcileAutoGrowStatusesNow then
        StockPiler3.Planner.ReconcileAutoGrowStatusesNow(StockPiler3TabWatch.listData)
    end
    local Sch = StockPiler3.Scheduler
    if Sch and Sch.EnqueuePlanRebuild then
        Sch.EnqueuePlanRebuild({ nudge = true })
    end
    if StockPiler3.Ui then
        -- Bypass 5s Watch flush throttle so status text updates on this click.
        StockPiler3.Ui._watchUiLastKey = nil
        StockPiler3.Ui._watchUiFlushedAt = 0
        if StockPiler3.Ui.MarkWatchUiDirty then
            StockPiler3.Ui.MarkWatchUiDirty()
        end
    end
    if StockPiler3.Buy and StockPiler3.Buy.IsEnabled and StockPiler3.Buy.IsEnabled() == true then
        local VA = StockPiler3.VendorAdapter
        if VA and VA.IsStoreOpen and VA.IsStoreOpen() == true then
            if StockPiler3.Buy.InvalidateJobsCache then
                StockPiler3.Buy.InvalidateJobsCache()
            end
            if Sch and Sch.WakeAutoBuy then
                Sch.WakeAutoBuy()
            end
        end
    end
end

--- Reserve/Budget: no PlanRebuild; clear money-gate + wake AutoBuy if store open.
local function AfterSoftMoneySetting()
    if StockPiler3.Buy and StockPiler3.Buy.OnMoneySettingsChanged then
        StockPiler3.Buy.OnMoneySettingsChanged()
    end
    if StockPiler3.Ui and StockPiler3.Ui.MarkWatchUiDirty then
        StockPiler3.Ui.MarkWatchUiDirty()
    end
    StockPiler3TabWatch.RefreshSkillGates()
end

local function ApplyTargetOptimistic(data, target)
    if type(data) ~= "table" then
        return
    end
    target = tonumber(target) or 0
    data.target = target
    data.targetText = towstring(tostring(target))
    data.potionMin = target
    local have = tonumber(data.potionHave) or 0
    data.potionDeficit = math.max(0, target - have)
    StockPiler3TabWatch._rowPaintKey = nil
    if StockPiler3TabWatch.UpdateRows then
        StockPiler3TabWatch.UpdateRows()
    end
end

local function PatchPlanSnapshotTarget(potionKey, target, have)
    if potionKey == nil then
        return
    end
    target = tonumber(target) or 0
    have = tonumber(have)
    local PS = StockPiler3.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) ~= "table" or type(plan.rows) ~= "table" then
        return
    end
    local keyStr = tostring(potionKey)
    for i = 1, #plan.rows do
        local row = plan.rows[i]
        if type(row) == "table" then
            local rowKey = row.potionRecipeKey or row.id or row.potionKey
            if rowKey ~= nil and tostring(rowKey) == keyStr then
                row.target = target
                row.potionMin = target
                local rowHave = have
                if rowHave == nil then
                    rowHave = tonumber(row.potionHave) or 0
                end
                row.potionDeficit = math.max(0, target - rowHave)
            end
        end
    end
end

local function TargetChangeIsDemandNoop(have, oldTarget, newTarget)
    have = tonumber(have) or 0
    oldTarget = tonumber(oldTarget) or 0
    newTarget = tonumber(newTarget) or 0
    local oldDeficit = math.max(0, oldTarget - have)
    local newDeficit = math.max(0, newTarget - have)
    if oldDeficit > 0 or newDeficit > 0 then
        return false
    end
    if (oldTarget > 0) ~= (newTarget > 0) then
        return false
    end
    return true
end

local function AfterTargetChipChanged(data, potionKey, oldTarget, newTarget)
    local have = tonumber(data and data.potionHave) or 0
    if TargetChangeIsDemandNoop(have, oldTarget, newTarget) then
        ApplyTargetOptimistic(data, newTarget)
        PatchPlanSnapshotTarget(potionKey, newTarget, have)
        return
    end
    ApplyTargetOptimistic(data, newTarget)
    AfterWatchSettingsChanged()
end

local function HasEnabledWatch()
    local watches = StockPiler3.Watch and StockPiler3.Watch.GetWatches and StockPiler3.Watch.GetWatches()
    if type(watches) ~= "table" then
        return false
    end
    for _, w in pairs(watches) do
        if type(w) == "table" and w.enabled == true then
            return true
        end
    end
    return false
end

local function BuildVisibleList(opts)
    opts = type(opts) == "table" and opts or {}
    local prevList = StockPiler3TabWatch.listData
    local prevOrder = StockPiler3TabWatch.displayOrder
    local plan = nil
    local forcePlan = opts.forcePlan == true
    -- Enabled watches but empty/stale plan: sync-build so Watch tab is never blank after toggle.
    if not forcePlan and HasEnabledWatch() then
        local snap = StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Get
            and StockPiler3.PlanSnapshot.Get()
        local snapRows = type(snap) == "table" and snap.rows or nil
        if type(snapRows) ~= "table" or #snapRows == 0 then
            forcePlan = true
        end
    end
    if forcePlan and StockPiler3.Planner and StockPiler3.Planner.Build then
        plan = StockPiler3.Planner.Build({ force = true })
    elseif StockPiler3.Planner and StockPiler3.Planner.GetOrBuild then
        plan = StockPiler3.Planner.GetOrBuild({ refresh = false })
    elseif StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Get then
        plan = StockPiler3.PlanSnapshot.Get()
    end
    local rows = type(plan) == "table" and plan.rows or nil
    if type(rows) ~= "table" or #rows == 0 then
        local keepPrev = type(prevList) == "table" and #prevList > 0
        if keepPrev then
            local keep = type(plan) ~= "table"
            if not keep and HasEnabledWatch() then
                keep = true
            end
            if keep then
                PatchWatchRowsLiveCounts(prevList)
                -- Prefer current snapshot rows when they exist (avoid orphaned stale listData).
                local snap = StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Get
                    and StockPiler3.PlanSnapshot.Get()
                local snapRows = type(snap) == "table" and snap.rows or nil
                if type(snapRows) == "table" and #snapRows > 0 then
                    PatchWatchRowsLiveCounts(snapRows)
                    StockPiler3TabWatch.listData = snapRows
                else
                    StockPiler3TabWatch.listData = prevList
                end
                StockPiler3TabWatch.displayOrder = {}
                for i = 1, #StockPiler3TabWatch.listData do
                    StockPiler3TabWatch.displayOrder[i] = i
                end
                return
            end
        end
        rows = {}
    end
    PatchWatchRowsLiveCounts(rows)
    StockPiler3TabWatch.listData = rows
    StockPiler3TabWatch.displayOrder = {}
    for i = 1, #StockPiler3TabWatch.listData do
        StockPiler3TabWatch.displayOrder[i] = i
    end
end

local function UpdateEnableCheckbox()
    if not DoesWindowExist(ENABLE_WIN) then
        return
    end
    local canGrow = CanAutoGrowUi()
    local row = CharRow(false)
    local on = canGrow and type(row) == "table" and row.autoGrowEnabled == true
    syncingUi = true
    ButtonSetCheckButtonFlag(ENABLE_WIN, true)
    ButtonSetPressedFlag(ENABLE_WIN, on)
    ButtonSetDisabledFlag(ENABLE_WIN, not canGrow)
    syncingUi = false
end

local function UpdateAdditivesCheckbox()
    if not DoesWindowExist(ADDITIVES_WIN) then
        return
    end
    local canGrow = CanAutoGrowUi()
    local row = CharRow(false)
    local on = canGrow and type(row) == "table" and row.autoGrowAdditives == true
    syncingUi = true
    ButtonSetCheckButtonFlag(ADDITIVES_WIN, true)
    ButtonSetPressedFlag(ADDITIVES_WIN, on)
    ButtonSetDisabledFlag(ADDITIVES_WIN, not canGrow)
    syncingUi = false
end

local function UpdateAutoBuyCheckbox()
    if not DoesWindowExist(AUTOBUY_WIN) then
        return
    end
    local canBuy = CanAutoBuyUi()
    local row = CharRow(false)
    local on = canBuy and type(row) == "table" and row.autoBuyEnabled == true
    syncingUi = true
    ButtonSetCheckButtonFlag(AUTOBUY_WIN, true)
    ButtonSetPressedFlag(AUTOBUY_WIN, on)
    ButtonSetDisabledFlag(AUTOBUY_WIN, not canBuy)
    syncingUi = false
end

local function UpdateCombatPauseCheckbox()
    if not DoesWindowExist(COMBAT_PAUSE_WIN) then
        return
    end
    local row = CharRow(false)
    local on = type(row) ~= "table" or row.autoGrowPauseCombat ~= false
    syncingUi = true
    ButtonSetCheckButtonFlag(COMBAT_PAUSE_WIN, true)
    ButtonSetPressedFlag(COMBAT_PAUSE_WIN, on)
    syncingUi = false
end

local function UpdateSeedBufferEnableCheckbox()
    if not DoesWindowExist(SEED_BUFFER_ENABLE_WIN) then
        return
    end
    local row = CharRow(false)
    local on = type(row) ~= "table" or row.growSeedBufferEnabled ~= false
    syncingUi = true
    ButtonSetCheckButtonFlag(SEED_BUFFER_ENABLE_WIN, true)
    ButtonSetPressedFlag(SEED_BUFFER_ENABLE_WIN, on)
    syncingUi = false
end

local function UpdateSeedBufferLabel()
    local buf = StockPiler3.Watch and StockPiler3.Watch.GetSeedBufferMin
        and StockPiler3.Watch.GetSeedBufferMin() or 5
    SetChipNumber("SP3TabWatchSeedBufferChipValue", "SP3TabWatchSeedBufferChip", buf)
end

local function UpdateAutoBuyChips()
    local row = CharRow(false)
    local reserve = type(row) == "table" and tonumber(row.autoBuyReserveGold) or 10
    local budget = type(row) == "table" and tonumber(row.autoBuyBudgetGold) or 50
    SetChipNumber("SP3TabWatchReserveChipValue", "SP3TabWatchReserveChip", reserve)
    SetChipNumber("SP3TabWatchBudgetChipValue", "SP3TabWatchBudgetChip", budget)
end

local function RowDataFromActiveChild()
    local win = SystemData.ActiveWindow and SystemData.ActiveWindow.name
    for _ = 1, 6 do
        if win == nil or win == "" then
            break
        end
        local rowIndex = WindowGetId(win)
        if rowIndex and rowIndex > 0 and DoesWindowExist("SP3TabWatchList") then
            local dataIndex = ListBoxGetDataIndex("SP3TabWatchList", rowIndex)
            local data = StockPiler3TabWatch.listData[dataIndex]
            if data then
                return data, win
            end
        end
        if type(WindowGetParent) == "function" then
            win = WindowGetParent(win)
        else
            break
        end
    end
    return nil
end

local function AdjustTarget(data, delta)
    if type(data) ~= "table" then
        return
    end
    local potionKey = data.potionRecipeKey or data.id or data.potionKey
    local oldTarget = tonumber(data.target) or 0
    local newTarget = Clamp(oldTarget + delta, 0, TARGET_MAX)
    if newTarget == oldTarget then
        return
    end
    if StockPiler3.Watch and StockPiler3.Watch.SetTarget then
        StockPiler3.Watch.SetTarget(potionKey, newTarget)
    end
    if newTarget > 0 and StockPiler3.Watch and StockPiler3.Watch.SetEnabled then
        local watch = StockPiler3.Watch.EnsureWatch and StockPiler3.Watch.EnsureWatch(potionKey)
        if type(watch) == "table" and watch.enabled ~= true then
            StockPiler3.Watch.SetEnabled(potionKey, true)
        end
    end
    AfterTargetChipChanged(data, potionKey, oldTarget, newTarget)
end

function StockPiler3TabWatch.Initialize()
    LabelSetText("SP3TabWatchBannerTitle", T("watch.banner_title"))
    LabelSetText("SP3TabWatchBannerText", T("watch.banner_text"))
    LabelSetText("SP3TabWatchEnableLabel", T("watch.enable_autogrow"))
    LabelSetText("SP3TabWatchAdditivesLabel", T("watch.use_additives"))
    LabelSetText("SP3TabWatchSeedBufferLabel", T("watch.seed_buffer_label"))
    LabelSetText("SP3TabWatchAutoBuyLabel", T("watch.autobuy_label"))
    LabelSetText("SP3TabWatchCombatPauseLabel", T("watch.combat_pause_label"))
    LabelSetText("SP3TabWatchReserveLabel", T("watch.reserve_label"))
    LabelSetText("SP3TabWatchBudgetLabel", T("watch.budget_label"))
    TintStepper("SP3TabWatchSeedBufferChipBg")
    TintStepper("SP3TabWatchReserveChipBg")
    TintStepper("SP3TabWatchBudgetChipBg")
    ButtonSetText("SP3TabWatchColPotion", T("watch.col.potion"))
    ButtonSetText("SP3TabWatchColStock", T("watch.col.stock"))
    ButtonSetText("SP3TabWatchColStatus", T("watch.col.status"))
    ButtonSetText("SP3TabWatchColCraftable", T("watch.col.craftable"))
    ButtonSetText("SP3TabWatchColTarget", T("watch.col.target"))
    ButtonSetText("SP3TabWatchColPriority", T("watch.col.autogrow"))
    ButtonSetText("SP3TabWatchColBrew", T("watch.col.brew"))
    StockPiler3TabWatch.RefreshSkillGates()
end

function StockPiler3TabWatch.RefreshSkillGates()
    if not DoesWindowExist(TAB_ROOT) then
        return
    end
    local canGrow = CanAutoGrowUi()
    local canBuy = CanAutoBuyUi()
    local row = CharRow(false)
    local autoGrow = canGrow and type(row) == "table" and row.autoGrowEnabled == true
    local additives = canGrow and type(row) == "table" and row.autoGrowAdditives == true
    local autoBuy = canBuy and type(row) == "table" and row.autoBuyEnabled == true
    local combatPause = type(row) ~= "table" or row.autoGrowPauseCombat ~= false
    local seedBufOn = type(row) ~= "table" or row.growSeedBufferEnabled ~= false
    local seedBuf = StockPiler3.Watch and StockPiler3.Watch.GetSeedBufferMin and StockPiler3.Watch.GetSeedBufferMin() or 5
    local reserve = type(row) == "table" and tonumber(row.autoBuyReserveGold) or 10
    local budget = type(row) == "table" and tonumber(row.autoBuyBudgetGold) or 50
    local gatesKey = table.concat({
        tostring(canGrow), tostring(canBuy), tostring(autoGrow), tostring(additives),
        tostring(autoBuy), tostring(combatPause), tostring(seedBufOn), tostring(seedBuf),
        tostring(reserve), tostring(budget),
    }, ":")
    if StockPiler3TabWatch._skillGatesKey == gatesKey then
        return
    end
    StockPiler3TabWatch._skillGatesKey = gatesKey
    local prev = StockPiler3TabWatch._lastCanAutoGrow
    StockPiler3TabWatch._lastCanAutoGrow = canGrow
    UpdateEnableCheckbox()
    UpdateAdditivesCheckbox()
    UpdateAutoBuyCheckbox()
    UpdateCombatPauseCheckbox()
    UpdateSeedBufferEnableCheckbox()
    UpdateSeedBufferLabel()
    UpdateAutoBuyChips()
    if prev == false and canGrow == true then
        if StockPiler3.Ui and StockPiler3.Ui.MarkWatchUiDirty then
            StockPiler3.Ui.MarkWatchUiDirty()
        end
    end
end

function StockPiler3TabWatch.ClearRowPaintCache()
    StockPiler3TabWatch._rowPaintKey = {}
    StockPiler3TabWatch._rowIconNum = {}
end

function StockPiler3TabWatch.InvalidateBrewChrome()
    StockPiler3TabWatch._rowPaintKey = nil
    if StockPiler3.Ui then
        StockPiler3.Ui._watchUiLastKey = nil
        StockPiler3.Ui._watchUiLastBrewKey = nil
    end
end

function StockPiler3TabWatch.Refresh(opts)
    opts = type(opts) == "table" and opts or {}
    if not DoesWindowExist(TAB_ROOT) then
        return
    end
    StockPiler3TabWatch.RefreshSkillGates()
    local prevOrder = StockPiler3TabWatch.displayOrder
    BuildVisibleList(opts)
    if not DoesWindowExist("SP3TabWatchList") then
        return
    end
    local order = StockPiler3TabWatch.displayOrder
    local orderChanged = type(prevOrder) ~= "table" or type(order) ~= "table" or #prevOrder ~= #order
    if not orderChanged and type(prevOrder) == "table" and type(order) == "table" then
        for i = 1, #order do
            if prevOrder[i] ~= order[i] then
                orderChanged = true
                break
            end
        end
    end
    if orderChanged then
        StockPiler3TabWatch._rowPaintKey = {}
        StockPiler3TabWatch._rowIconNum = {}
        ListBoxSetDisplayOrder("SP3TabWatchList", order or {})
    else
        StockPiler3TabWatch.UpdateRows()
    end
end

function StockPiler3TabWatch.UpdateRows()
    if not SP3TabWatchList then
        return
    end
    if StockPiler3.Perf and StockPiler3.Perf.Begin then
        StockPiler3.Perf.Begin("WatchRows")
    end
    local numVisible = tonumber(SP3TabWatchList.numVisibleRows) or 11
    local indices = SP3TabWatchList.PopulatorIndices
    local active = {}
    if type(indices) == "table" then
        for rowIndex, dataIndex in ipairs(indices) do
            active[rowIndex] = dataIndex
        end
    end
    StockPiler3TabWatch._rowPaintKey = StockPiler3TabWatch._rowPaintKey or {}
    local canGrow = CanAutoGrowUi()
    local listData = StockPiler3TabWatch.listData
    for rowIndex = 1, numVisible do
        local rowName = "SP3TabWatchListRow" .. rowIndex
        if DoesWindowExist(rowName) then
            local dataIndex = active[rowIndex]
            local data = dataIndex and type(listData) == "table" and listData[dataIndex] or nil
            if data then
                WindowSetShowing(rowName, true)
                if DefaultColor and DefaultColor.SetListRowTint then
                    DefaultColor.SetListRowTint(rowName .. "Background", rowIndex, false)
                end
                local brewState = GetRowCraftUiState(data)
                local craftableGreen = RowCraftableGreen(data)
                local nameR, nameG, nameB = EnsureWatchNameRarityColors(data)
                local paintKey = table.concat({
                    tostring(data.iconNum or 0),
                    tostring(data.name or ""),
                    tostring(nameR), tostring(nameG), tostring(nameB),
                    tostring(data.statusText or ""),
                    tostring(data.stockText or data.potionHave or 0),
                    tostring(data.craftableText or ""),
                    tostring(data.craftable or 0),
                    tostring(data.targetText or data.target or 0),
                    tostring(data.statusKey or ""),
                    tostring(data.autoGrow == true),
                    tostring(data.craftableShared == true),
                    tostring(data.seedBufferShort == true),
                    tostring(craftableGreen),
                    tostring(brewState),
                    tostring(canGrow),
                }, "|")
                if StockPiler3TabWatch._rowPaintKey[rowIndex] ~= paintKey then
                    local lastIcon = StockPiler3TabWatch._rowIconNum
                    if type(lastIcon) ~= "table" then
                        lastIcon = {}
                        StockPiler3TabWatch._rowIconNum = lastIcon
                    end
                    if lastIcon[rowIndex] ~= data.iconNum then
                        lastIcon[rowIndex] = data.iconNum
                        SetIconTexture(rowName .. "Icon", data.iconNum)
                    end
                    LabelSetText(rowName .. "Name", data.name or L"")
                    LabelSetTextColor(rowName .. "Name", nameR, nameG, nameB)
                    LabelSetText(rowName .. "Status", data.statusText or L"")
                    LabelSetText(rowName .. "Stock", data.stockText or towstring(tostring(data.potionHave or 0)))
                    LabelSetText(rowName .. "Craftable", data.craftableText or T("ui.dash"))
                    LabelSetText(rowName .. "Target", data.targetText or towstring(tostring(data.target or 0)))
                    TintStepper(rowName .. "TargetChipBg")
                    ApplyStatusColor(rowName .. "Status", data.statusKey)
                    local autoGrowWin = rowName .. "AutoGrow"
                    if DoesWindowExist(autoGrowWin) then
                        syncingUi = true
                        ButtonSetCheckButtonFlag(autoGrowWin, true)
                        ButtonSetPressedFlag(autoGrowWin, canGrow and data.autoGrow == true)
                        ButtonSetDisabledFlag(autoGrowWin, not canGrow)
                        syncingUi = false
                    end
                    LabelSetTextColor(rowName .. "Target", 255, 255, 255)
                    local target = tonumber(data.target) or 0
                    local have = tonumber(data.potionHave) or 0
                    local craftable = tonumber(data.craftable) or 0
                    local stockColor = { 255, 255, 255 }
                    if target > 0 then
                        if have >= target then
                            stockColor = COLOR_OK
                        elseif (have + craftable) >= target then
                            stockColor = COLOR_WARN
                        else
                            stockColor = COLOR_BLOCK
                        end
                    end
                    LabelSetTextColor(rowName .. "Stock", stockColor[1], stockColor[2], stockColor[3])
                    local craftColor = COLOR_BLOCK
                    if craftable > 0 then
                        -- Yellow: craftable but seed buffer short. Green: buffer-safe (shared OK).
                        if data.seedBufferShort == true or data.craftableSafe == false then
                            craftColor = COLOR_WARN
                        else
                            craftColor = COLOR_OK
                        end
                    end
                    LabelSetTextColor(rowName .. "Craftable", craftColor[1], craftColor[2], craftColor[3])
                    ApplyRowBrewButton(rowName .. "Load", data)
                    StockPiler3TabWatch._rowPaintKey[rowIndex] = paintKey
                end
            else
                WindowSetShowing(rowName, false)
                StockPiler3TabWatch._rowPaintKey[rowIndex] = nil
            end
        end
    end
    if StockPiler3.Perf and StockPiler3.Perf.End then
        StockPiler3.Perf.End("WatchRows")
    end
end

function StockPiler3TabWatch.OnToggleEnabled()
    if syncingUi then
        return
    end
    if not CanAutoGrowUi() then
        UpdateEnableCheckbox()
        return
    end
    local row = CharRow(true)
    if type(row) ~= "table" then
        return
    end
    row.autoGrowEnabled = ButtonGetPressedFlag(ENABLE_WIN) == true
    NotifySettings(T("watch.autogrow", { state = OnOff(row.autoGrowEnabled) }))
    if row.autoGrowEnabled ~= true and StockPiler3.Orchestrator and StockPiler3.Orchestrator.OnAutoGrowDisabled then
        StockPiler3.Orchestrator.OnAutoGrowDisabled()
    end
    AfterWatchSettingsChanged()
    StockPiler3TabWatch.RefreshSkillGates()
    StockPiler3TabWatch._rowPaintKey = nil
    StockPiler3TabWatch.UpdateRows()
end

function StockPiler3TabWatch.OnToggleAdditives()
    if syncingUi then
        return
    end
    if not CanAutoGrowUi() then
        UpdateAdditivesCheckbox()
        return
    end
    local row = CharRow(true)
    if type(row) ~= "table" then
        return
    end
    row.autoGrowAdditives = ButtonGetPressedFlag(ADDITIVES_WIN) == true
    NotifySettings(T("watch.additives", { state = OnOff(row.autoGrowAdditives) }))
    AfterWatchSettingsChanged()
end

function StockPiler3TabWatch.OnToggleSeedBuffer()
    if syncingUi then
        return
    end
    local row = CharRow(true)
    if type(row) ~= "table" then
        return
    end
    row.growSeedBufferEnabled = ButtonGetPressedFlag(SEED_BUFFER_ENABLE_WIN) == true
    NotifySettings(T("watch.seed_buffer", { state = OnOff(row.growSeedBufferEnabled) }))
    AfterWatchSettingsChanged()
end

function StockPiler3TabWatch.OnToggleAutoBuy()
    if syncingUi then
        return
    end
    if not CanAutoBuyUi() then
        UpdateAutoBuyCheckbox()
        return
    end
    local row = CharRow(true)
    if type(row) ~= "table" then
        return
    end
    row.autoBuyEnabled = ButtonGetPressedFlag(AUTOBUY_WIN) == true
    NotifySettings(T("watch.autobuy", { state = OnOff(row.autoBuyEnabled) }))
    AfterSoftMoneySetting()
    if row.autoBuyEnabled == true and StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoBuy then
        StockPiler3.Scheduler.WakeAutoBuy()
    end
    if StockPiler3.Buy and StockPiler3.Buy.InvalidateJobsCache then
        StockPiler3.Buy.InvalidateJobsCache()
    end
end

function StockPiler3TabWatch.OnToggleCombatPause()
    if syncingUi then
        return
    end
    local row = CharRow(true)
    if type(row) ~= "table" then
        return
    end
    row.autoGrowPauseCombat = ButtonGetPressedFlag(COMBAT_PAUSE_WIN) == true
    NotifySettings(T("watch.combat_pause", { state = OnOff(row.autoGrowPauseCombat) }))
    AfterSoftMoneySetting()
end

local function AdjustSeedBuffer(flags, dir)
    local row = CharRow(true)
    if type(row) ~= "table" then
        return
    end
    local cur = tonumber(row.growSeedBufferMin) or 5
    local nextVal = Clamp(cur + ChipDelta(flags, dir), 4, 20)
    if nextVal == cur then
        return
    end
    row.growSeedBufferMin = nextVal
    NotifySettings(T("watch.setting_eq", {
        label = T("watch.setting.seed_buffer"),
        value = tostring(nextVal),
    }))
    UpdateSeedBufferLabel()
    AfterWatchSettingsChanged()
end

local function AdjustReserve(flags, dir)
    local row = CharRow(true)
    if type(row) ~= "table" then
        return
    end
    local cur = tonumber(row.autoBuyReserveGold) or 10
    local nextVal = Clamp(cur + ChipDelta(flags, dir), 1, 99)
    if nextVal == cur then
        return
    end
    row.autoBuyReserveGold = nextVal
    NotifySettings(T("watch.setting_eq", {
        label = T("watch.setting.reserve"),
        value = tostring(nextVal),
    }))
    UpdateAutoBuyChips()
    AfterSoftMoneySetting()
end

local function AdjustBudget(flags, dir)
    local row = CharRow(true)
    if type(row) ~= "table" then
        return
    end
    local cur = tonumber(row.autoBuyBudgetGold) or 50
    local nextVal = Clamp(cur + ChipDelta(flags, dir), 1, 999)
    if nextVal == cur then
        return
    end
    row.autoBuyBudgetGold = nextVal
    NotifySettings(T("watch.setting_eq", {
        label = T("watch.setting.budget"),
        value = tostring(nextVal),
    }))
    UpdateAutoBuyChips()
    AfterSoftMoneySetting()
end

function StockPiler3TabWatch.OnSeedBufferLButtonUp(flags)
    AdjustSeedBuffer(flags, 1)
end

function StockPiler3TabWatch.OnSeedBufferRButtonUp(flags)
    AdjustSeedBuffer(flags, -1)
end

function StockPiler3TabWatch.OnReserveLButtonUp(flags)
    AdjustReserve(flags, 1)
end

function StockPiler3TabWatch.OnReserveRButtonUp(flags)
    AdjustReserve(flags, -1)
end

function StockPiler3TabWatch.OnBudgetLButtonUp(flags)
    AdjustBudget(flags, 1)
end

function StockPiler3TabWatch.OnBudgetRButtonUp(flags)
    AdjustBudget(flags, -1)
end

function StockPiler3TabWatch.OnToggleRowAutoGrow()
    if syncingUi then
        return
    end
    local data = RowDataFromActiveChild()
    if not data or not CanAutoGrowUi() then
        return
    end
    local potionKey = data.potionRecipeKey or data.id or data.potionKey
    local enabled = ButtonGetPressedFlag(SystemData.ActiveWindow.name) == true
    if StockPiler3.Watch and StockPiler3.Watch.SetAutoGrow then
        StockPiler3.Watch.SetAutoGrow(potionKey, enabled)
    end
    data.autoGrow = enabled
    AfterWatchSettingsChanged()
    StockPiler3TabWatch._rowPaintKey = nil
    -- UpdateRows alone used to paint pre-reconcile status; Refresh re-patches listData.
    StockPiler3TabWatch.UpdateRows()
end

function StockPiler3TabWatch.OnTargetLButtonUp(flags)
    local data = RowDataFromActiveChild()
    AdjustTarget(data, ChipDelta(flags, 1))
end

function StockPiler3TabWatch.OnTargetRButtonUp(flags)
    local data = RowDataFromActiveChild()
    AdjustTarget(data, ChipDelta(flags, -1))
end

function StockPiler3TabWatch.OnLoadRow()
    local data = RowDataFromActiveChild()
    if not data or not StockPiler3.Brew then
        return
    end
    if StockPiler3.Brew.OnRowCraftClick then
        StockPiler3.Brew.OnRowCraftClick(data)
    end
    if StockPiler3.BrewChrome and StockPiler3.BrewChrome.RefreshBrewUi then
        StockPiler3.BrewChrome.RefreshBrewUi()
    end
end

function StockPiler3TabWatch.OnLoadRowRightClick()
    local data = RowDataFromActiveChild()
    if StockPiler3.Brew and StockPiler3.Brew.OnRowCraftRightClick then
        StockPiler3.Brew.OnRowCraftRightClick(data)
    end
    if StockPiler3.BrewChrome and StockPiler3.BrewChrome.RefreshBrewUi then
        StockPiler3.BrewChrome.RefreshBrewUi()
    end
end

local function Tip(text)
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, text)
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler3TabWatch.OnMouseOverEnabled()
    Tip(T("tip.watch.autogrow_master"))
end

function StockPiler3TabWatch.OnMouseOverAdditives()
    Tip(T("tip.watch.additives"))
end

function StockPiler3TabWatch.OnMouseOverAutoBuy()
    Tip(T("tip.watch.autobuy"))
end

function StockPiler3TabWatch.OnMouseOverCombatPause()
    Tip(T("tip.watch.combat_pause"))
end

function StockPiler3TabWatch.OnMouseOverSeedBufferEnable()
    Tip(T("tip.watch.seed_buffer"))
end

function StockPiler3TabWatch.OnMouseOverSeedBuffer()
    Tip(T("tip.watch.seed_buffer"))
end

function StockPiler3TabWatch.OnMouseOverReserve()
    Tip(T("tip.watch.reserve_chip"))
end

function StockPiler3TabWatch.OnMouseOverBudget()
    Tip(T("tip.watch.budget_chip"))
end

function StockPiler3TabWatch.OnMouseOverIcon()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    local itemData = data.itemData
    -- Stock CraftingSystem.GetCraftingData ipairs(itemData.craftingBonus) with no nil guard.
    if type(itemData) == "table" and Tooltips and Tooltips.CreateItemTooltip then
        if type(itemData.craftingBonus) ~= "table" then
            itemData.craftingBonus = {}
        end
        Tooltips.CreateItemTooltip(itemData, SystemData.ActiveWindow.name, Tooltips.ANCHOR_WINDOW_RIGHT, false)
        return
    end
    Tip(data.name or T("ui.potion_fallback"))
end

function StockPiler3TabWatch.OnMouseOverStatus()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    Tip(data.statusText or T("ui.dash"))
end

function StockPiler3TabWatch.OnMouseOverStock()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    Tip(T("tip.watch.have_target", {
        have = tostring(data.potionHave or 0),
        target = tostring(data.target or 0),
    }))
end

function StockPiler3TabWatch.OnMouseOverCraftable()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    Tip(data.craftableText or T("ui.dash"))
end

function StockPiler3TabWatch.OnMouseOverTarget()
    Tip(T("tip.watch.target_chip"))
end

function StockPiler3TabWatch.OnMouseOverRowAutoGrow()
    Tip(T("tip.watch.row_autogrow"))
end

function StockPiler3TabWatch.OnMouseOverLoad()
    local data = RowDataFromActiveChild()
    if StockPiler3.BrewTooltip and StockPiler3.BrewTooltip.ShowRow then
        StockPiler3.BrewTooltip.ShowRow(SystemData.ActiveWindow.name, data)
        return
    end
    Tip(T("watch.col.brew"))
end

function StockPiler3TabWatch.OnMouseOverCraftableHeader()
    Tip(T("watch.col.craftable"))
end

function StockPiler3TabWatch.OnCraftableHeaderClick()
end
