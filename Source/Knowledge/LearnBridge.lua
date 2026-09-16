----------------------------------------------------------------
-- StockPiler3 Knowledge/LearnBridge — harvest-complete queue + hooks
-- Do not pull Refine into the harvest trail.
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.LearnBridge = StockPiler3.LearnBridge or {}
local LB = StockPiler3.LearnBridge

LB._prevPlotStages = {}
LB._harvestCompletePending = false
LB._harvestCompleteSeenUpdate = false
LB._apothecaryHooked = false
LB._useItemRefineHooked = false
LB._busTokens = {}

local function StageGrown()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.GROWN or 4
    end
    return 4
end

local function StageEmpty()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.EMPTY or 0
    end
    return 0
end

local function SkipPlanAndUiThisFrame()
    local Sch = StockPiler3.Scheduler
    if Sch and Sch.SkipPlanThisFrame then
        Sch.SkipPlanThisFrame()
    end
    if Sch and Sch.SkipUiThisFrame then
        Sch.SkipUiThisFrame()
    end
end

local function QueueHarvestCompleteLearn(plotNum, seedUid)
    LB._harvestCompletePending = true
    LB._harvestCompleteSeenUpdate = false
    local SM = StockPiler3.SeedMap
    if SM and SM.BeginPendingHarvest then
        SM.BeginPendingHarvest(plotNum, seedUid)
    end
end

local function DrainHarvestCompleteLearn(force)
    local SM = StockPiler3.SeedMap
    if not SM or not SM.TryCompletePendingHarvest then
        return false
    end
    -- Harvest trail only — do not call Refine here.
    local learned = SM.TryCompletePendingHarvest(force == true) == true
    SkipPlanAndUiThisFrame()
    return learned
end

function LB.EnsureApothecaryHook()
    if type(ApothecaryWindow) ~= "table" then
        return false
    end
    if LB._apothecaryHooked == true or ApothecaryWindow._StockPiler3Hooked == true then
        LB._apothecaryHooked = true
        return true
    end
    local origPerform = ApothecaryWindow.Perform
    if type(origPerform) == "function" then
        ApothecaryWindow.Perform = function()
            if StockPiler3.BrewLearn and StockPiler3.BrewLearn.BeginPendingCraft then
                pcall(StockPiler3.BrewLearn.BeginPendingCraft)
            end
            origPerform()
        end
    end
    local origHide = ApothecaryWindow.Hide
    if type(origHide) == "function" then
        ApothecaryWindow.Hide = function(...)
            if StockPiler3.BrewLearn and StockPiler3.BrewLearn.CompletePendingCraftLearn
                and GameData and GameData.CraftingStatus and GameData.CraftingStates
                and tonumber(GameData.CraftingStatus.State) == GameData.CraftingStates.FAIL
            then
                pcall(StockPiler3.BrewLearn.CompletePendingCraftLearn, { failed = true })
            end
            origHide(...)
        end
    end
    ApothecaryWindow._StockPiler3Hooked = true
    LB._apothecaryHooked = true
    return true
end

local function ResolveItemForUse(location, slot)
    location = tonumber(location)
    slot = tonumber(slot) or 0
    if location == nil or slot <= 0 then
        return nil
    end
    local bagType = nil
    if Cursor then
        if location == Cursor.SOURCE_CRAFTING_ITEM then
            bagType = "craft"
        elseif location == Cursor.SOURCE_INVENTORY then
            bagType = "main"
        end
    end
    local BA = StockPiler3.BagAdapter
    if BA and BA.ReadSlot then
        if bagType then
            local _, _, item = BA.ReadSlot(bagType, slot)
            if type(item) == "table" then
                return item
            end
        end
        local _, _, craftItem = BA.ReadSlot("craft", slot)
        if type(craftItem) == "table" then
            return craftItem
        end
        local _, _, mainItem = BA.ReadSlot("main", slot)
        return mainItem
    end
    return nil
end

function LB.EnsureUseItemRefineHook()
    if LB._useItemRefineHooked == true then
        return true
    end
    if type(SendUseItem) ~= "function" then
        return false
    end
    local orig = SendUseItem
    SendUseItem = function(location, slot, a, b, c)
        local item = ResolveItemForUse(location, slot)
        local SM = StockPiler3.SeedMap
        if type(item) == "table" and SM and SM.ItemLooksLikeRefinablePlant
            and SM.ItemLooksLikeRefinablePlant(item) == true
            and SM.BeginPendingRefine
        then
            pcall(SM.BeginPendingRefine, item)
        end
        return orig(location, slot, a, b, c)
    end
    LB._useItemRefineHooked = true
    return true
end

function LB.OnInventoryUpdated()
    if StockPiler3.SeedMap and StockPiler3.SeedMap.MarkHarvestLootDirty then
        StockPiler3.SeedMap.MarkHarvestLootDirty()
    end
    if StockPiler3.BrewLearn and StockPiler3.BrewLearn.MarkInventoryCraftPollDue then
        StockPiler3.BrewLearn.MarkInventoryCraftPollDue()
    end
    -- Do not call Refine from harvest/inventory learn path.
end

function LB.OnCraftingUpdated()
    LB.EnsureApothecaryHook()
    LB.EnsureUseItemRefineHook()
    if StockPiler3.BrewLearn and StockPiler3.BrewLearn.OnCraftingUpdated then
        StockPiler3.BrewLearn.OnCraftingUpdated()
    end
    -- Pending refine progress is SeedMap's job; EngineEventBridge runs Refine later.
    if StockPiler3.SeedMap and StockPiler3.SeedMap.TryCompletePendingRefine then
        StockPiler3.SeedMap.TryCompletePendingRefine()
    end
end

function LB.OnCultivationUpdated()
    local plotNum = 0
    if GameData and GameData.Player and GameData.Player.Cultivation then
        plotNum = tonumber(GameData.Player.Cultivation.UpdatedIndex) or 0
    end
    local grown = StageGrown()
    local empty = StageEmpty()

    local function HandleEmpty(pn, prevStage, newStage, seedUid)
        if newStage ~= empty or prevStage == nil or prevStage == empty then
            return
        end
        -- Queue harvest-complete learn; drain on UPDATE_PROCESSED.
        QueueHarvestCompleteLearn(pn, seedUid)
        if StockPiler3.Grow and StockPiler3.Grow.WakeAfterHarvest then
            StockPiler3.Grow.WakeAfterHarvest(pn)
        elseif StockPiler3.Scheduler and StockPiler3.Scheduler.WakeAutoGrow then
            StockPiler3.Scheduler.WakeAutoGrow()
        end
    end

    local function NotePlot(pn, row, prevStage)
        if type(row) ~= "table" then
            return
        end
        if StockPiler3.Additives and StockPiler3.Additives.LearnFromPlotRow then
            StockPiler3.Additives.LearnFromPlotRow(row)
        end
        local SM = StockPiler3.SeedMap
        if not SM then
            return
        end
        local stage = tonumber(row.stage) or 0
        local liveSeed = tonumber(row.seedUid) or 0
        if liveSeed > 0 and SM.NotePlotSeed then
            SM.NotePlotSeed(pn, liveSeed)
        end
        if stage == empty then
            return
        end
        local resolved = liveSeed
        if SM.ResolvePlotSeed then
            resolved = SM.ResolvePlotSeed(pn, liveSeed)
        end
        local justPlanted = (prevStage == nil or prevStage == empty) and resolved > 0
        if justPlanted and SM.ObservePlant then
            SM.ObservePlant(pn, resolved)
        end
        if stage == grown or resolved > 0 then
            if SM.RefreshHarvestWatch then
                SM.RefreshHarvestWatch(pn, { Seed = { uniqueID = resolved } })
            end
        end
    end

    if plotNum <= 0 then
        local Garden = StockPiler3.Garden
        if Garden and Garden.GetPlotsCopy then
            local plots = Garden.GetPlotsCopy()
            for pn, row in pairs(plots) do
                if type(row) == "table" then
                    local prev = LB._prevPlotStages[pn]
                    NotePlot(pn, row, prev)
                    HandleEmpty(pn, prev, row.stage, row.seedUid)
                    LB._prevPlotStages[pn] = row.stage
                end
            end
        end
        return
    end

    local CA = StockPiler3.CultivatorAdapter
    local row = CA and CA.ReadPlot and CA.ReadPlot(plotNum) or nil
    local prev = LB._prevPlotStages[plotNum]
    NotePlot(plotNum, row, prev)
    if type(row) == "table" then
        LB._prevPlotStages[plotNum] = row.stage
        HandleEmpty(plotNum, prev, row.stage, row.seedUid)
    end
end

--- Drain harvest-complete learn on UPDATE_PROCESSED (EngineEventBridge order).
function LB.OnUpdateProcessed()
    if StockPiler3.BrewLearn and StockPiler3.BrewLearn.DrainInventoryCraftPoll then
        StockPiler3.BrewLearn.DrainInventoryCraftPoll()
    end

    local SM = StockPiler3.SeedMap
    if SM and type(SM._pendingHarvest) == "table" then
        local forceOneShot = false
        if LB._harvestCompletePending == true then
            if LB._harvestCompleteSeenUpdate == true then
                LB._harvestCompletePending = false
                LB._harvestCompleteSeenUpdate = false
                forceOneShot = true
            else
                LB._harvestCompleteSeenUpdate = true
            end
        end
        if forceOneShot then
            DrainHarvestCompleteLearn(true)
        else
            local willAttempt = SM.ShouldAttemptHarvestComplete
                and SM.ShouldAttemptHarvestComplete(false) == true
            if willAttempt then
                DrainHarvestCompleteLearn(false)
            end
        end
    elseif LB._harvestCompletePending == true then
        LB._harvestCompletePending = false
        LB._harvestCompleteSeenUpdate = false
    end
    -- Refine completes outside harvest trail (EngineEventBridge → Refine.OnUpdate).
end

function LB.Initialize()
    LB.EnsureApothecaryHook()
    LB.EnsureUseItemRefineHook()
    if StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.RelinkPotionRecipeKeysFromOutcomes then
        StockPiler3.RecipeSpec.RelinkPotionRecipeKeysFromOutcomes()
    end

    local Bus = StockPiler3.EventBus
    local E = StockPiler3.Events
    if Bus and Bus.Subscribe and E then
        LB._busTokens = {}
        if E.SESSION_LOADED then
            LB._busTokens[#LB._busTokens + 1] = Bus.Subscribe(E.SESSION_LOADED, function()
                LB.EnsureApothecaryHook()
                LB.EnsureUseItemRefineHook()
            end)
        end
        if E.INVENTORY_SNAPSHOT then
            LB._busTokens[#LB._busTokens + 1] = Bus.Subscribe(E.INVENTORY_SNAPSHOT, function()
                LB.OnInventoryUpdated()
            end)
        end
        if E.GARDEN_SNAPSHOT then
            LB._busTokens[#LB._busTokens + 1] = Bus.Subscribe(E.GARDEN_SNAPSHOT, function()
                -- Soft re-arm plots; empty-edge still comes from cultivation events.
                LB.OnCultivationUpdated()
            end)
        end
    end
end

function LB.Shutdown()
    local Bus = StockPiler3.EventBus
    if Bus and Bus.Unsubscribe and type(LB._busTokens) == "table" then
        for i = 1, #LB._busTokens do
            Bus.Unsubscribe(LB._busTokens[i])
        end
    end
    LB._busTokens = {}
    LB._harvestCompletePending = false
    LB._harvestCompleteSeenUpdate = false
    LB._prevPlotStages = {}
end
