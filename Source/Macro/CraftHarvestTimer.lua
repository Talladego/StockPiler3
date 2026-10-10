----------------------------------------------------------------
-- Craft macro harvest countdown.
-- Stock stack-count label (ActionButton m_Windows[7] / Action…Count),
-- the same slot WarTriage, EZGuard, and GCDsaver write.
-- Shown only while the Craft icon is the harvest icon.
-- Growing: whole seconds plus "s" (longest string "999s").
-- Harvest ready: that plot's seed icon replaces the countdown.
-- User wait (buy vials/mats, garden idle): pet_stay.dds (icon 33).
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.CraftHarvestTimer = StockPiler3.CraftHarvestTimer or {}

local Timer = StockPiler3.CraftHarvestTimer

local DISPLAY_CAP = 999
local LABEL_WIDTH = 58
local LABEL_HEIGHT = 20
local STOCK_LABEL_WIDTH = 45
local STACK_COUNT_TEXT = 7
-- eatemplate_icons: <Icon id="33" texture="Textures/pet_stay.dds" />
local STAY_ICON = 33

Timer._acc = 0
Timer._hooked = false
Timer._orgUpdateInventory = nil

local fitted = {}

local function StageNum(key, fallback)
    local stages = GameData and GameData.CultivationStage
    if type(stages) == "table" and stages[key] ~= nil then
        return tonumber(stages[key]) or fallback
    end
    return fallback
end

local function LabelOf(button)
    local windows = button and button.m_Windows
    return windows and windows[STACK_COUNT_TEXT]
end

local function LabelName(label, button)
    if label and label.GetName then
        local name = label:GetName()
        if name ~= nil and name ~= "" then
            return name
        end
    end
    if button and button.GetName then
        local buttonName = button:GetName()
        if buttonName ~= nil and buttonName ~= "" then
            return buttonName .. "ActionCount"
        end
    end
    return nil
end

local function HarvestIconMode()
    local Macro = StockPiler3.Macro
    if not Macro then
        return false
    end
    return (Macro._craftIconMode or "harvest") ~= "brew"
end

--- Smallest totalTimer among planted plots that are still growing.
--- Nil when nothing is growing. Live cultivator read, same as the Craft tip.
function Timer.ShortestSeconds()
    local CA = StockPiler3.CultivatorAdapter
    if not (CA and CA.GetPlotInfo) then
        return nil
    end
    local n = 4
    if CA.MaxPlotSlots then
        n = tonumber(CA.MaxPlotSlots()) or n
    end
    local empty = StageNum("EMPTY", 0)
    local grown = StageNum("GROWN", 4)
    local harvestable = StageNum("HARVESTABLE", grown)
    local harvesting = StageNum("HARVESTING", 5)
    local best = nil
    for plotNum = 1, n do
        local plot = CA.GetPlotInfo(plotNum)
        if type(plot) == "table" then
            local stage = tonumber(plot.stage) or 0
            local seedUid = tonumber(plot.seedUid) or 0
            local total = tonumber(plot.totalTimer) or 0
            if seedUid > 0 and stage ~= empty and stage ~= 255
                and stage ~= grown and stage ~= harvestable and stage ~= harvesting
                and total > 0
            then
                if best == nil or total < best then
                    best = total
                end
            end
        end
    end
    return best
end

local function EachPlot(fn)
    local CA = StockPiler3.CultivatorAdapter
    if not (CA and CA.GetPlotInfo) then
        return
    end
    local n = 4
    if CA.MaxPlotSlots then
        n = tonumber(CA.MaxPlotSlots()) or n
    end
    for plotNum = 1, n do
        local plot = CA.GetPlotInfo(plotNum)
        if type(plot) == "table" then
            fn(plot)
        end
    end
end

local function SeedIconNum(plot)
    local icon = tonumber(plot.seedIconNum) or 0
    if icon <= 0 and type(plot.seed) == "table" then
        icon = tonumber(plot.seed.iconNum) or 0
    end
    if icon <= 0 then
        local uid = tonumber(plot.seedUid) or 0
        local Items = StockPiler3.Items
        local item = uid > 0 and Items and Items.Get and Items.Get(uid) or nil
        if type(item) == "table" then
            icon = tonumber(item.iconNum) or 0
        end
    end
    return icon
end

--- Icon of a plot that is already grown. Nil while every planted plot is still growing.
function Timer.ReadySeedIcon()
    local grown = StageNum("GROWN", 4)
    local harvestable = StageNum("HARVESTABLE", grown)
    local empty = StageNum("EMPTY", 0)
    local icon = nil
    EachPlot(function(plot)
        if icon ~= nil then
            return
        end
        local stage = tonumber(plot.stage) or 0
        local seedUid = tonumber(plot.seedUid) or 0
        if seedUid > 0 and stage ~= empty and stage ~= 255
            and (stage == grown or stage == harvestable)
        then
            local n = SeedIconNum(plot)
            if n > 0 then
                icon = n
            end
        end
    end)
    return icon
end

local function IconMarkup(iconNum)
    iconNum = tonumber(iconNum) or 0
    if iconNum <= 0 then
        return nil
    end
    return towstring(string.format("<icon%05d>", iconNum))
end

local USER_STALL = {
    buy_ingredients = true,
    need_container_vendor = true,
    no_vendor_container = true,
    need_vendor = true,
    autobuy_off = true,
    no_vendor_seed = true,
    need_buy = true,
}

local function SeedBufferSettled()
    local Watch = StockPiler3.Watch
    if not (Watch and Watch.IsSeedBufferEnabled and Watch.IsSeedBufferEnabled() == true) then
        return true
    end
    local Grow = StockPiler3.Grow
    return Grow and Grow.IsSeedBufferSatisfied and Grow.IsSeedBufferSatisfied() == true
end

local function VendorBuyInProgress()
    local Watch = StockPiler3.Watch
    if not (Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true) then
        return false
    end
    local VA = StockPiler3.VendorAdapter
    return VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
end

local function HasPendingPlant()
    local CC = StockPiler3.CraftChatAdapter
    if not (CC and CC.HasSoilPending) then
        return false
    end
    local n = 4
    local CA = StockPiler3.CultivatorAdapter
    if CA and CA.MaxPlotSlots then
        n = tonumber(CA.MaxPlotSlots()) or n
    end
    for plotNum = 1, n do
        if CC.HasSoilPending(plotNum) == true then
            return true
        end
    end
    return false
end

--- Garden / buffer / buy still moving: stay icon must wait.
local function HasActiveWork()
    if Timer.ShortestSeconds() ~= nil then
        return true
    end
    if Timer.ReadySeedIcon() ~= nil then
        return true
    end
    local Grow = StockPiler3.Grow
    if Grow and Grow.IsHarvestOpActive and Grow.IsHarvestOpActive() == true then
        return true
    end
    local Refine = StockPiler3.Refine
    if Refine and Refine.HasOutstanding and Refine.HasOutstanding() == true then
        return true
    end
    if HasPendingPlant() then
        return true
    end
    if SeedBufferSettled() ~= true then
        return true
    end
    if VendorBuyInProgress() then
        return true
    end
    return false
end

local function PlanUserBuyInfo()
    local PS = StockPiler3.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    local rows = plan and plan.rows
    if type(rows) ~= "table" then
        return nil
    end
    local Watch = StockPiler3.Watch
    local autoGrow = Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() == true
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local sk = tostring(row.statusKey or "")
            if USER_STALL[sk] == true then
                local match = autoGrow == true
                    or row.kind == "skillup"
                    or row.skillUp == true
                    or row.addonOwned == true
                if match then
                    return {
                        key = sk,
                        text = row.statusText,
                        name = row.name,
                    }
                end
            end
        end
    end
    return nil
end

--- Why the Craft overlay is on stay. Nil when not waiting on the player.
--- key is a USER_STALL reason; text/name are optional plan-row hints.
function Timer.UserStayInfo()
    if HasActiveWork() == true then
        return nil
    end
    local SkillUp = StockPiler3.SkillUp
    if SkillUp then
        if SkillUp.ShouldApoBrew and SkillUp.ShouldApoBrew() == true
            and SkillUp.ShouldApoBuyContainer and SkillUp.ShouldApoBuyContainer() == true
        then
            return { key = "need_container_vendor" }
        end
        local apo = tostring(SkillUp._apoStallLatch or "")
        if USER_STALL[apo] == true then
            return { key = apo }
        end
        if SkillUp.CultStallReason then
            local cult = SkillUp.CultStallReason()
            if cult ~= nil and USER_STALL[tostring(cult)] == true then
                return { key = tostring(cult) }
            end
        end
    end
    local US = StockPiler3.UpgradeSeed
    if US then
        local latch = tostring(US._stallLatch or "")
        if USER_STALL[latch] == true then
            return { key = latch }
        end
        local active = US._active
        if type(active) == "table" then
            local why = tostring(active.why or "")
            if USER_STALL[why] == true then
                return {
                    key = why,
                    name = active.genus or active.name,
                }
            end
        end
    end
    return PlanUserBuyInfo()
end

--- True when SP3 is waiting on the player (vendor / buy) and AutoGrow has
--- nothing left to plant, harvest, refine, or buy on an open store.
function Timer.NeedsUserStay()
    return Timer.UserStayInfo() ~= nil
end

local function LocaleHit(key)
    if not (StockPiler3.T and key ~= nil and key ~= "") then
        return nil
    end
    local text = StockPiler3.T(key)
    if text == nil or text == L"" then
        return nil
    end
    if text == L"[" .. towstring(tostring(key)) .. L"]" then
        return nil
    end
    return text
end

--- Tip / chat-friendly stay reason (no leading harvest icon).
function Timer.UserStayReasonText()
    local info = Timer.UserStayInfo()
    if type(info) ~= "table" then
        return nil
    end
    local key = tostring(info.key or "")
    if key == "" then
        return nil
    end
    if info.text ~= nil and info.text ~= L"" and info.text ~= "" then
        if type(info.text) == "wstring" then
            return info.text
        end
        return towstring(tostring(info.text))
    end
    return LocaleHit("macro.craft_tip_stay." .. key)
        or LocaleHit("plan.status." .. key)
        or towstring(key)
end

function Timer.Format(seconds)
    local n = math.floor((tonumber(seconds) or 0) + 0.5)
    if n < 0 then
        n = 0
    end
    if n > DISPLAY_CAP then
        n = DISPLAY_CAP
    end
    return towstring(tostring(n) .. "s")
end

local function FitLabel(label, button)
    local name = LabelName(label, button)
    if name == nil or fitted[name] == true then
        return
    end
    if WindowSetDimensions then
        WindowSetDimensions(name, LABEL_WIDTH, LABEL_HEIGHT)
    end
    if label.SetFont then
        local spacing = 0
        if WindowUtils and WindowUtils.FONT_DEFAULT_TEXT_LINESPACING ~= nil then
            spacing = WindowUtils.FONT_DEFAULT_TEXT_LINESPACING
        end
        label:SetFont("font_chat_text", spacing)
    end
    if label.SetTextColor then
        label:SetTextColor(255, 255, 0)
    end
    fitted[name] = true
end

local function RestoreLabel(label, button)
    local name = LabelName(label, button)
    if name ~= nil and fitted[name] == true and WindowSetDimensions then
        WindowSetDimensions(name, STOCK_LABEL_WIDTH, LABEL_HEIGHT)
    end
    if name ~= nil then
        fitted[name] = nil
    end
    if label then
        if label.SetText then
            label:SetText(L"")
        end
        if label.Show then
            label:Show(false)
        end
    end
end

function Timer.Paint(button)
    local label = LabelOf(button)
    if not label then
        return
    end
    local Macro = StockPiler3.Macro
    if not (Macro and Macro.IsCraftMacroButton and Macro.IsCraftMacroButton(button) == true) then
        if LabelName(label, button) ~= nil and fitted[LabelName(label, button)] == true then
            RestoreLabel(label, button)
        end
        return
    end
    if HarvestIconMode() ~= true then
        if label.SetText then
            label:SetText(L"")
        end
        if label.Show then
            label:Show(false)
        end
        return
    end
    local readyIcon = Timer.ReadySeedIcon()
    local stay = false
    local text = nil
    if readyIcon ~= nil then
        text = IconMarkup(readyIcon)
    else
        local seconds = Timer.ShortestSeconds()
        if seconds ~= nil then
            text = Timer.Format(seconds)
        elseif Timer.NeedsUserStay() == true then
            stay = true
            text = IconMarkup(STAY_ICON)
        end
    end
    if text == nil or text == L"" then
        if label.SetText then
            label:SetText(L"")
        end
        if label.Show then
            label:Show(false)
        end
        return
    end
    FitLabel(label, button)
    if label.SetTextColor then
        if readyIcon ~= nil or stay == true then
            label:SetTextColor(255, 255, 255)
        else
            label:SetTextColor(255, 255, 0)
        end
    end
    if label.SetText then
        label:SetText(text)
    end
    if label.Show then
        label:Show(true)
    end
end

local function EachActionButton(fn)
    if not ActionBars or not ActionBars.m_Bars then
        return
    end
    for _, bar in pairs(ActionBars.m_Bars) do
        local buttons = bar and bar.m_Buttons
        if type(buttons) == "table" then
            for _, button in pairs(buttons) do
                if type(button) == "table" then
                    fn(button)
                end
            end
        end
    end
end

function Timer.Refresh()
    local Macro = StockPiler3.Macro
    if not (Macro and Macro.IsCraftMacroButton) then
        return
    end
    EachActionButton(function(button)
        if Macro.IsCraftMacroButton(button) then
            Timer.Paint(button)
        end
    end)
end

function Timer.OnUpdate(timeElapsed)
    Timer._acc = (tonumber(Timer._acc) or 0) + (tonumber(timeElapsed) or 0)
    if Timer._acc < 1 then
        return
    end
    Timer._acc = 0
    Timer.Refresh()
end

function Timer.Install()
    if Timer._hooked == true then
        return
    end
    if not ActionButton or type(ActionButton.UpdateInventory) ~= "function" then
        return
    end
    local org = ActionButton.UpdateInventory
    Timer._orgUpdateInventory = org
    ActionButton.UpdateInventory = function(self)
        org(self)
        Timer.Paint(self)
    end
    Timer._hooked = true
end

function Timer.Shutdown()
    if Timer._hooked == true and ActionButton and Timer._orgUpdateInventory then
        ActionButton.UpdateInventory = Timer._orgUpdateInventory
    end
    Timer._hooked = false
    Timer._orgUpdateInventory = nil
    Timer._acc = 0
    EachActionButton(function(button)
        local label = LabelOf(button)
        if label and fitted[LabelName(label, button) or ""] == true then
            RestoreLabel(label, button)
        end
    end)
end
