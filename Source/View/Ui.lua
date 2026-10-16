----------------------------------------------------------------
-- StockPiler3 View/Ui -- window show/hide + coalesced Watch flush
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Ui = StockPiler3.Ui or {}
local Ui = StockPiler3.Ui

local function T(key, tokens)
    return StockPiler3.Util.T(key, tokens)
end

Ui.WATCH_UI_MIN_INTERVAL_SEC = 5.0
-- When the Watch tab is visible, react faster to stock/status without a full 5s wait.
Ui.WATCH_UI_OPEN_INTERVAL_SEC = 0.5
Ui.BREW_WATCH_CATCHUP_SEC = 1.0
Ui._watchUiDirty = false
Ui._watchUiFlushedAt = 0
Ui._watchUiBrewCatchupAt = 0
Ui._watchUiLastKey = nil
Ui._watchUiLastKnowledgeGen = 0
Ui._watchUiLastPlanGen = 0
Ui._watchUiLastBrewKey = nil
-- True after Knowledge.Touch structural learn (new potion/recipe). PatchLiveHave
-- only updates Have on existing rows; the Potions list needs a full Refresh.
Ui._catalogStructureDirty = false

--- Drop the Watch paint throttle so the next flush is not skipped.
--- Clears both _watchUiLastKey and _watchUiFlushedAt. The trade-skill load path
--- clears only the key; clearing FlushedAt there would change flush timing.
function Ui.BypassWatchThrottle()
    Ui._watchUiLastKey = nil
    Ui._watchUiFlushedAt = 0
end

local function IsWatchTabVisible()
    if not DoesWindowExist("StockPiler3Window") then
        return false
    end
    if WindowGetShowing("StockPiler3Window") ~= true then
        return false
    end
    local selected = StockPiler3Window and StockPiler3Window.SelectedTab
    local watchTab = StockPiler3Window and StockPiler3Window.TABS_WATCH
    return selected ~= nil and watchTab ~= nil and selected == watchTab
end

local function IsCatalogTabVisible()
    if not DoesWindowExist("StockPiler3Window") then
        return false
    end
    if WindowGetShowing("StockPiler3Window") ~= true then
        return false
    end
    local selected = StockPiler3Window and StockPiler3Window.SelectedTab
    if selected == nil then
        return false
    end
    local potions = StockPiler3Window.TABS_POTIONS
    local plants = StockPiler3Window.TABS_PLANTS
    return selected == potions or selected == plants
end

local function IsAnyTabVisible()
    return IsWatchTabVisible() or IsCatalogTabVisible()
end

function Ui.Print(msg)
    if StockPiler3.Debug and StockPiler3.Debug.Reply then
        StockPiler3.Debug.Reply(msg)
    elseif StockPiler3.Debug and StockPiler3.Debug.Print then
        StockPiler3.Debug.Print(msg, "user")
    end
end

function Ui.ToggleWindow()
    if not DoesWindowExist("StockPiler3Window") then
        Ui.Print(T("ui.window_missing"))
        return
    end
    if WindowUtils and WindowUtils.ToggleShowing then
        WindowUtils.ToggleShowing("StockPiler3Window")
        return
    end
    local showing = WindowGetShowing("StockPiler3Window") == true
    WindowSetShowing("StockPiler3Window", not showing)
end

function Ui.ShowWindow(tabId)
    if not DoesWindowExist("StockPiler3Window") then
        return
    end
    WindowSetShowing("StockPiler3Window", true)
    if tabId and StockPiler3Window and StockPiler3Window.SelectTab then
        StockPiler3Window.SelectTab(tabId)
    end
end

local function CurrentPlanGen()
    if StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Get then
        local plan = StockPiler3.PlanSnapshot.Get()
        if type(plan) == "table" then
            return tonumber(plan.planGen) or 0
        end
    end
    return 0
end

local function BrewChromeKey()
    local Brew = StockPiler3.Brew
    if not Brew or not Brew.GetSession then
        return "idle"
    end
    local session = Brew.GetSession()
    if type(session) ~= "table" then
        return "idle"
    end
    return tostring(session.phase or "idle")
        .. ":" .. tostring(session.potionRecipeKey or session.potionKey or "")
        .. ":" .. tostring(session.rowId or "")
        .. ":" .. tostring(Brew._loadSource or "")
end

local function WatchContentKey()
    local snapGen = 0
    if StockPiler3.Inventory and StockPiler3.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler3.Inventory.GetSnapGen()) or 0
    end
    local planGen = CurrentPlanGen()
    local knowledgeGen = 0
    if StockPiler3.Knowledge and StockPiler3.Knowledge.GetGen then
        knowledgeGen = tonumber(StockPiler3.Knowledge.GetGen()) or 0
    end
    local watchGen = 0
    if StockPiler3.Watch and StockPiler3.Watch.GetGen then
        watchGen = tonumber(StockPiler3.Watch.GetGen()) or 0
    end
    local autoGrowOn = false
    if StockPiler3.Watch and StockPiler3.Watch.IsAutoGrowEnabled then
        autoGrowOn = StockPiler3.Watch.IsAutoGrowEnabled() == true
    end
    local skillKey = "0"
    local Caps = StockPiler3.TradeSkillCaps
    if Caps and Caps.LevelsHash then
        skillKey = tostring(Caps.LevelsHash())
    end
    local SkillUp = StockPiler3.SkillUp
    local skillShow = SkillUp and SkillUp.ShouldShowWatchStatus
        and SkillUp.ShouldShowWatchStatus() == true
    -- Plant/empty/lock (not stage-timer GetGen) so garden dirty actually paints.
    local gardenPlanGen = 0
    local Garden = StockPiler3.Garden
    if Garden and Garden.GetPlanGen then
        gardenPlanGen = tonumber(Garden.GetPlanGen()) or 0
    end
    return tostring(snapGen)
        .. ":" .. tostring(planGen)
        .. ":" .. tostring(knowledgeGen)
        .. ":" .. tostring(watchGen)
        .. ":" .. tostring(autoGrowOn)
        .. ":" .. tostring(skillKey)
        .. ":" .. tostring(skillShow)
        .. ":" .. tostring(gardenPlanGen)
        .. ":" .. BrewChromeKey()
end

local function IsWatchPlanStale()
    local Sch = StockPiler3.Scheduler
    if Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true then
        return true
    end
    local Planner = StockPiler3.Planner
    if not Planner or not Planner.CacheKeyFromGens then
        return false
    end
    local wantKey = Planner.CacheKeyFromGens()
    local plan = StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Get and StockPiler3.PlanSnapshot.Get()
    if type(plan) ~= "table" then
        return false
    end
    return tostring(plan.cacheKey or "") ~= tostring(wantKey or "")
end

local function OpenPaintActive()
    return StockPiler3Window and StockPiler3Window._openPaintPending == true
end

local function WatchMissingSkillUpRows()
    local SkillUp = StockPiler3.SkillUp
    if not (SkillUp and SkillUp.ShouldShowWatchStatus and SkillUp.ShouldShowWatchStatus() == true) then
        local US = StockPiler3.UpgradeSeed
        if not (US and US.ShouldShowWatchStatus and US.ShouldShowWatchStatus() == true) then
            return false
        end
    end
    local list = StockPiler3TabWatch and StockPiler3TabWatch.listData
    if type(list) ~= "table" or #list == 0 then
        return true
    end
    for i = 1, #list do
        local row = list[i]
        if type(row) == "table" and (row.skillUp == true or row.upgradeWatch == true
            or row.addonOwned == true)
        then
            return false
        end
    end
    return true
end

function Ui.WatchNeedsSkillUpPaint()
    return WatchMissingSkillUpRows()
end

--- Hold Watch paint during harvest storm, refine outstanding, buffer refine,
--- AutoBuy visit, FrameWork prewarm, or session settle.
local function ShouldDeferWatchFlush()
    -- First open / re-show: never leave Watch rows PrimeRowChrome-hidden.
    if OpenPaintActive() then
        return false
    end
    -- SkillUp-only Watch (no potion watches): do not wait on plan/prewarm/settle
    -- or rows stay missing until /sp3 dumpall or an AutoGrow toggle.
    if WatchMissingSkillUpRows() then
        local SchFast = StockPiler3.Scheduler
        if SchFast and SchFast.SkipUiThisFrameActive and SchFast.SkipUiThisFrameActive() == true then
            return true
        end
        if SchFast and SchFast._skipUiThisFrame == true then
            return true
        end
        if SchFast and SchFast.IsHarvestStorm and SchFast.IsHarvestStorm() == true then
            return true
        end
        if SchFast and SchFast.IsPlantQuiet and SchFast.IsPlantQuiet() == true then
            return true
        end
        return false
    end
    local Sch = StockPiler3.Scheduler
    if Sch and Sch.SkipUiThisFrameActive and Sch.SkipUiThisFrameActive() == true then
        return true
    end
    if Sch and Sch._skipUiThisFrame == true then
        return true
    end
    if Sch and Sch.IsSessionSettling and Sch.IsSessionSettling() == true then
        return true
    end
    if Sch and Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
        return true
    end
    if Sch and Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true then
        return true
    end
    if Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true then
        return true
    end
    local FW = StockPiler3.FrameWork
    if FW and FW.IsPrewarmBusy and FW.IsPrewarmBusy() == true then
        return true
    end
    if FW and FW.Busy and FW.Busy() == true then
        return true
    end
    local RP = StockPiler3.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        return true
    end
    -- Peek only: HasPendingBufferRefine rebuilds BufferFlags after every snap invalidate.
    local Refine = StockPiler3.Refine
    if Refine and Refine.PeekCachedBufferPending and Refine.PeekCachedBufferPending() == true then
        return true
    end
    local Buy = StockPiler3.Buy
    if Buy and Buy.ShouldDeferWatchPaint and Buy.ShouldDeferWatchPaint() == true then
        return true
    end
    return false
end

--- Light in-place stock/status paint while Watch is open (no ListBox rebind).
--- Defined after ShouldDeferWatchFlush (Lua local visibility).
--- opts.ignoreDefer: plant quiet / harvest storm still need status recount.
--- opts.forceRecount / allowBrewHold: post-brew event path (session may stay loaded).
local function TryWatchLiveCatchup(opts)
    opts = type(opts) == "table" and opts or {}
    if not IsWatchTabVisible() then
        return false
    end
    if opts.ignoreDefer ~= true and ShouldDeferWatchFlush() then
        return false
    end
    local Orch = StockPiler3.Orchestrator
    local Brew = StockPiler3.Brew
    local brewHold = (Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true)
        or (Brew and Brew.IsWatchUiHold and Brew.IsWatchUiHold() == true)
    if brewHold and opts.allowBrewHold ~= true then
        -- Brew path has its own catch-up / BREW_SESSION_CHANGED handler.
        return false
    end
    local listData = StockPiler3TabWatch and StockPiler3TabWatch.listData
    if type(listData) ~= "table" or #listData == 0 then
        return false
    end
    local Planner = StockPiler3.Planner
    if not (Planner and Planner.LiveRecount) then
        return false
    end
    if opts.forceRecount == true then
        Planner.LiveRecount({
            invalidateStamps = true,
            allowWarmHave = true,
            syncSnapshot = true,
            forceRecountCraftable = true,
        })
    else
        Planner.LiveRecount({
            allowWarmHave = false,
            syncSnapshot = false,
            recountCraftable = false,
        })
    end
    if StockPiler3TabWatch.UpdateRows then
        StockPiler3TabWatch.UpdateRows({ keepVisible = true })
    end
    return true
end

--- True while FrameWork.Pump will not run (Scheduler skips it for the whole brew).
local function BrewSessionBlocksRecount()
    local Orch = StockPiler3.Orchestrator
    return Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true
end

--- One forced craftable recount per inventory snapGen (coalesced to end of frame).
--- Mid-brew: do not queue ui-force-watch-recount. Pump skips that job until the
--- session ends, and stamping the snap done before the paint used to drop the
--- post-brew recount.
--- Hidden Watch: keep pending only — do not StartOnce a no-op each snapGen.
local function RequestForcedWatchRecount(_reason)
    local Inv = StockPiler3.Inventory
    local snapGen = Inv and Inv.GetSnapGen and tonumber(Inv.GetSnapGen()) or 0
    if BrewSessionBlocksRecount() then
        Ui._forceRecountPendingSnapGen = snapGen
        Ui._forceRecountDeferredDuringBrew = true
        return
    end
    if Ui._forceRecountDeferredDuringBrew == true then
        -- Bags can move during brew without a new snapGen (inventory side
        -- effects suppressed). A stamp from before the brew must not skip this.
        Ui._forceRecountDeferredDuringBrew = false
        Ui._forceRecountDoneSnapGen = nil
    end
    if not IsWatchTabVisible() then
        Ui._forceRecountPendingSnapGen = snapGen
        Ui._forceRecountDeferredWhileHidden = true
        return
    end
    if Ui._forceRecountDeferredWhileHidden == true then
        Ui._forceRecountDeferredWhileHidden = false
        Ui._forceRecountDoneSnapGen = nil
    end
    if snapGen > 0 and Ui._forceRecountDoneSnapGen == snapGen then
        return
    end
    Ui._forceRecountPendingSnapGen = snapGen
    local FW = StockPiler3.FrameWork
    local genKey = snapGen > 0 and snapGen or ((tonumber(Ui._forceRecountOnceGen) or 0) + 1)
    Ui._forceRecountOnceGen = genKey
    local function run()
        local doneSnap = tonumber(Ui._forceRecountPendingSnapGen) or 0
        if doneSnap > 0 and Ui._forceRecountDoneSnapGen == doneSnap then
            return
        end
        local painted = TryWatchLiveCatchup({
            ignoreDefer = true,
            allowBrewHold = true,
            forceRecount = true,
        }) == true
        if painted and doneSnap > 0 then
            Ui._forceRecountDoneSnapGen = doneSnap
        end
    end
    if FW and FW.StartOnce then
        FW.StartOnce("ui-force-watch-recount", genKey, run)
    else
        run()
    end
end

--- Watch became paintable (tab select / window open). Flush bag snaps that
--- arrived while the tab was hidden without queuing no-op FrameWork jobs.
function Ui.FlushDeferredWatchRecount()
    if Ui._forceRecountDeferredWhileHidden == true then
        RequestForcedWatchRecount("watch-visible")
    end
end

--- Rebuild Potions/Plants list after a structural knowledge learn.
--- The structure-dirty flag still needs a full refresh after a brew-hold or
--- plan-defer flush. Have-only patching does not clear it.
local function FlushCatalogIfStructureDirty()
    if Ui._catalogStructureDirty ~= true then
        return false
    end
    if not IsCatalogTabVisible() then
        return false
    end
    local selected = StockPiler3Window and StockPiler3Window.SelectedTab
    if selected == StockPiler3Window.TABS_POTIONS
        and StockPiler3TabPotions
        and StockPiler3TabPotions.Refresh
    then
        StockPiler3TabPotions.Refresh()
        Ui._catalogStructureDirty = false
        return true
    end
    if selected == StockPiler3Window.TABS_PLANTS
        and StockPiler3TabPlants
        and StockPiler3TabPlants.Refresh
    then
        StockPiler3TabPlants.Refresh()
        Ui._catalogStructureDirty = false
        return true
    end
    return false
end

--- Potions/Plants Have from L0 CountByUid — does not need Have-warm or plan rebuild.
--- Run even while plan/prewarm defers Watch craftable paint.
local function TryCatalogLiveCatchup()
    if FlushCatalogIfStructureDirty() then
        return true
    end
    if not IsCatalogTabVisible() then
        return false
    end
    local selected = StockPiler3Window and StockPiler3Window.SelectedTab
    if selected == StockPiler3Window.TABS_POTIONS
        and StockPiler3TabPotions
        and StockPiler3TabPotions.PatchLiveHave
    then
        if StockPiler3TabPotions.PatchLiveHave() == true
            and StockPiler3TabPotions.UpdateRows
        then
            StockPiler3TabPotions.UpdateRows()
        end
        return true
    end
    if selected == StockPiler3Window.TABS_PLANTS
        and StockPiler3TabPlants
        and StockPiler3TabPlants.PatchLiveHave
    then
        if StockPiler3TabPlants.PatchLiveHave() == true
            and StockPiler3TabPlants.UpdateRows
        then
            StockPiler3TabPlants.UpdateRows()
        end
        return true
    end
    return false
end

--- Catalog tab: never RefreshActiveTab for bag/plan churn (ListBoxSetDisplayOrder
--- {}→order resets Potions/Plants scroll). Structure learns rebuild once; Have patches in place.
local function FlushCatalogTabUi()
    if not IsCatalogTabVisible() then
        return false
    end
    local knowledgeGen = 0
    if StockPiler3.Knowledge and StockPiler3.Knowledge.GetGen then
        knowledgeGen = tonumber(StockPiler3.Knowledge.GetGen()) or 0
    end
    local structureNeeded = Ui._catalogStructureDirty == true
        or knowledgeGen ~= (tonumber(Ui._watchUiLastKnowledgeGen) or 0)
    if structureNeeded then
        Ui._catalogStructureDirty = true
        FlushCatalogIfStructureDirty()
    else
        TryCatalogLiveCatchup()
    end
    local now = 0
    if type(GetGameTime) == "function" then
        now = tonumber(GetGameTime()) or 0
    end
    Ui._watchUiDirty = false
    Ui._watchUiFlushedAt = now
    Ui._watchUiLastKnowledgeGen = knowledgeGen
    Ui._watchUiLastPlanGen = CurrentPlanGen()
    Ui._watchUiLastBrewKey = BrewChromeKey()
    Ui._watchUiLastKey = WatchContentKey()
    if StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
        StockPiler3Window.RequestFooterRefresh()
    end
    return true
end

function Ui.ClearWatchTipCaches()
    if StockPiler3TabWatch then
        StockPiler3TabWatch._statusTipCache = nil
        StockPiler3TabWatch._seedBufferTipCache = nil
    end
end

function Ui.MarkWatchUiDirty()
    Ui._watchUiDirty = true
end

function Ui.RequestFooterRefresh()
    if StockPiler3Window and StockPiler3Window.RequestFooterRefresh then
        StockPiler3Window.RequestFooterRefresh()
    end
end

function Ui.FlushPendingFooterRefresh()
    if StockPiler3Window and StockPiler3Window.FlushPendingFooterRefresh then
        StockPiler3Window.FlushPendingFooterRefresh()
    end
end

--- FOOTER_DIRTY → footer/macro chrome. payload.immediate syncs readiness now.
local function OnFooterDirty(payload)
    Ui.RequestFooterRefresh()
    if type(payload) ~= "table" or payload.immediate ~= true then
        return
    end
    local Sch = StockPiler3.Scheduler
    if Sch then
        if Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true then
            return
        end
        if Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true then
            return
        end
        if Sch.IsSessionSettling and Sch.IsSessionSettling() == true then
            return
        end
    end
    if StockPiler3Window and StockPiler3Window.SyncActionReadiness then
        StockPiler3Window.SyncActionReadiness({ immediate = true })
    elseif payload.syncMacro == true and StockPiler3.Macro
        and StockPiler3.Macro.RefreshMacroButtonAppearance
    then
        local Brew = StockPiler3.Brew
        local canHarvest = StockPiler3.Grow and StockPiler3.Grow.CanHarvestNow
            and StockPiler3.Grow.CanHarvestNow() == true
        local canBrew = Brew and Brew.CanBrewNow and Brew.CanBrewNow() == true
        StockPiler3.Macro.RefreshMacroButtonAppearance({
            canHarvest = canHarvest,
            canBrew = canBrew,
        })
    end
end

--- WATCH_UI_DIRTY → coalesced Watch flush; payload.immediate paints rows now.
local function OnWatchUiDirty(payload)
    payload = type(payload) == "table" and payload or {}
    Ui.MarkWatchUiDirty()
    if payload.immediate ~= true then
        return
    end
    if StockPiler3TabWatch and StockPiler3TabWatch.InvalidateBrewChrome then
        StockPiler3TabWatch.InvalidateBrewChrome()
    end
    if payload.recount == true or payload.forceRecount == true then
        RequestForcedWatchRecount(payload.reason or "watch-ui-dirty")
    else
        TryWatchLiveCatchup({
            ignoreDefer = true,
            allowBrewHold = true,
            forceRecount = false,
        })
    end
    TryCatalogLiveCatchup()
end

--- BREW_SESSION_CHANGED → row Brew chrome + live counts without waiting on coalesce.
local function OnBrewSessionChanged(payload)
    payload = type(payload) == "table" and payload or {}
    Ui.MarkWatchUiDirty()
    Ui._watchUiLastBrewKey = nil
    if StockPiler3TabWatch and StockPiler3TabWatch.InvalidateBrewChrome then
        StockPiler3TabWatch.InvalidateBrewChrome()
    end
    local wantsRecount = payload.recount == true or payload.forceRecount == true
    if Ui._forceRecountDeferredDuringBrew == true and not BrewSessionBlocksRecount() then
        wantsRecount = true
    end
    if wantsRecount then
        RequestForcedWatchRecount(payload.reason or "brew-session")
    elseif DoesWindowExist("StockPiler3Window")
        and WindowGetShowing("StockPiler3Window") == true
        and StockPiler3TabWatch
        and StockPiler3TabWatch.UpdateRows
    then
        StockPiler3TabWatch.UpdateRows({ keepVisible = true })
    end
    OnFooterDirty({ immediate = true, syncMacro = true })
end

function Ui.InvalidateSkillGates()
    if StockPiler3TabWatch then
        StockPiler3TabWatch._skillGatesKey = nil
        if StockPiler3TabWatch.RefreshSkillGates then
            StockPiler3TabWatch.RefreshSkillGates()
        end
    end
end

function Ui.RefreshCatalogRows()
    -- Patch Have from L0 first; UpdateRows alone left stale stock after bag moves.
    if StockPiler3TabPotions and StockPiler3TabPotions.PatchLiveHave then
        StockPiler3TabPotions.PatchLiveHave()
    end
    if StockPiler3TabPotions and StockPiler3TabPotions.UpdateRows then
        StockPiler3TabPotions.UpdateRows()
    end
    if StockPiler3TabPlants and StockPiler3TabPlants.PatchLiveHave then
        StockPiler3TabPlants.PatchLiveHave()
    end
    if StockPiler3TabPlants and StockPiler3TabPlants.UpdateRows then
        StockPiler3TabPlants.UpdateRows()
    end
end

function Ui.FlushWatchUiIfDirty()
    if Ui._watchUiDirty ~= true then
        return
    end
    local windowOpen = DoesWindowExist("StockPiler3Window")
        and WindowGetShowing("StockPiler3Window") == true
    -- Ready wake must run even while AutoBuy visit defers full Watch paint
    -- (flask fills clear Shared/Buy-flasks without a potion craftable delta).
    local function WakeReadyFromLiveStatus()
        if StockPiler3.Planner and StockPiler3.Planner.SyncLiveStatusClosedWindow then
            StockPiler3.Planner.SyncLiveStatusClosedWindow()
        elseif StockPiler3.Brew and StockPiler3.Brew.SyncLiveStatusClosedWindow then
            StockPiler3.Brew.SyncLiveStatusClosedWindow()
        end
        if StockPiler3.Brew and StockPiler3.Brew.MaybeNotifyBrewReady then
            StockPiler3.Brew.MaybeNotifyBrewReady()
        end
    end
    if not windowOpen then
        WakeReadyFromLiveStatus()
        if ShouldDeferWatchFlush() then
            return
        end
        -- Closed-window: Ready wake done; keep dirty for next open paint.
        return
    end
    -- Bag snaps while on Potions/Plants (or while closed) only set pending;
    -- recount now that Watch can paint.
    if IsWatchTabVisible() then
        Ui.FlushDeferredWatchRecount()
    end
    if ShouldDeferWatchFlush() then
        WakeReadyFromLiveStatus()
        -- While settle/prewarm holds full paint, kill the white ListBox flash.
        if StockPiler3TabWatch and StockPiler3TabWatch.PrimeRowChrome then
            StockPiler3TabWatch.PrimeRowChrome()
        end
        -- Plan coalesce holds RefreshActiveTab, but Load chips must grey as soon as
        -- bag snap advances past row._craftableSnapGen (ApplyRowBrewButton).
        local Sch = StockPiler3.Scheduler
        local planPending = Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true
        local hardHold = (Sch and Sch.SkipUiThisFrameActive and Sch.SkipUiThisFrameActive() == true)
            or (Sch and Sch._skipUiThisFrame == true)
            or (Sch and Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true)
            or (Sch and Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true)
            or (Sch and Sch.IsSessionSettling and Sch.IsSessionSettling() == true)
        if planPending and not hardHold and IsWatchTabVisible()
            and StockPiler3TabWatch and StockPiler3TabWatch.UpdateRows
        then
            StockPiler3TabWatch.UpdateRows({ keepVisible = true })
        end
        -- Catalog Have is L0-only; do not wait for Have-warm / plan like Watch craftable.
        -- Consume dirty on catalog so a later defer-end does not RefreshActiveTab
        -- (empty→full ListBoxSetDisplayOrder) and yank Potions scroll to the top.
        if IsCatalogTabVisible() then
            FlushCatalogTabUi()
            return true
        end
        TryCatalogLiveCatchup()
        -- Plant quiet / harvest storm skip full RefreshWatch; still patch stock/status.
        if hardHold
            and ((Sch and Sch.IsHarvestStorm and Sch.IsHarvestStorm() == true)
                or (Sch and Sch.IsPlantQuiet and Sch.IsPlantQuiet() == true))
        then
            TryWatchLiveCatchup({ ignoreDefer = true })
        end
        return
    end

    local Orch = StockPiler3.Orchestrator
    local Brew = StockPiler3.Brew
    local brewSessionActive = (Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true)
        or (Brew and Brew.IsWatchUiHold and Brew.IsWatchUiHold() == true)
    -- Mid-brew / inter-craft hold: hold full RefreshWatch; chrome via ForceBrewUiRefresh;
    -- ~1s Stock/Status catch-up. Rebind listData only when the ListBox is empty
    -- (stuck session / scenario load). planGen bumps every brew cycle otherwise
    -- caused SkillUp / watch row flicker/disappear via ListBoxSetDisplayOrder.
    if brewSessionActive then
        -- Manual/apo learn can land during Watch brew-hold; still rebuild Potions.
        if IsCatalogTabVisible() then
            FlushCatalogTabUi()
            return true
        end
        FlushCatalogIfStructureDirty()
        local listData = StockPiler3TabWatch and StockPiler3TabWatch.listData
        local listEmpty = type(listData) ~= "table" or #listData == 0
        local planGen = CurrentPlanGen()
        local planChanged = planGen ~= (tonumber(Ui._watchUiLastPlanGen) or 0)
        if planChanged then
            Ui._watchUiLastPlanGen = planGen
            -- Never ListBoxSetDisplayOrder mid-brew (hides all rows). Empty list only.
            if listEmpty and StockPiler3TabWatch and StockPiler3TabWatch.Refresh then
                StockPiler3TabWatch.Refresh({ forcePlan = false, brewHold = true })
            elseif StockPiler3TabWatch and StockPiler3TabWatch.UpdateRows then
                StockPiler3TabWatch.UpdateRows({ keepVisible = true })
            end
            -- Consume dirty during AutoBrew continuum; next plan.updated re-marks.
            -- Leaving dirty true forced a full RefreshActiveTab the instant hold
            -- dropped and cleared the Watch list between crafts.
            Ui._watchUiDirty = false
            return
        end
        local brewKey = BrewChromeKey()
        local brewChanged = brewKey ~= tostring(Ui._watchUiLastBrewKey or "")
        local now = 0
        if type(GetGameTime) == "function" then
            now = tonumber(GetGameTime()) or 0
        end
        if brewChanged then
            Ui._watchUiLastBrewKey = brewKey
            if StockPiler3TabWatch and StockPiler3TabWatch.InvalidateBrewChrome then
                StockPiler3TabWatch.InvalidateBrewChrome()
            end
            if StockPiler3TabWatch and StockPiler3TabWatch.UpdateRows then
                StockPiler3TabWatch.UpdateRows({ keepVisible = true })
            end
            Ui._watchUiDirty = false
            return
        end
        local catchupSec = tonumber(Ui.BREW_WATCH_CATCHUP_SEC) or 1.0
        local lastCatchup = tonumber(Ui._watchUiBrewCatchupAt) or 0
        if lastCatchup > 0 and (now - lastCatchup) < catchupSec then
            return
        end
        Ui._watchUiBrewCatchupAt = now
        listData = StockPiler3TabWatch and StockPiler3TabWatch.listData
        listEmpty = type(listData) ~= "table" or #listData == 0
        local snap = StockPiler3.PlanSnapshot and StockPiler3.PlanSnapshot.Get
            and StockPiler3.PlanSnapshot.Get()
        local planRows = type(snap) == "table" and snap.rows or nil
        -- listData is a sorted copy of plan.rows; compare bound plan identity, not listData.
        local boundPlanRows = StockPiler3TabWatch and StockPiler3TabWatch._boundPlanRows
        if type(planRows) == "table" and planRows ~= boundPlanRows then
            if listEmpty and StockPiler3TabWatch and StockPiler3TabWatch.Refresh then
                StockPiler3TabWatch.Refresh({ forcePlan = false, brewHold = true })
            elseif type(planRows) == "table" and #planRows > 0 and StockPiler3TabWatch then
                -- Rebind sorted copy (never assign unsorted plan.rows as listData).
                if StockPiler3TabWatch.BindSortedList then
                    StockPiler3TabWatch.BindSortedList(planRows)
                else
                    StockPiler3TabWatch.listData = planRows
                    StockPiler3TabWatch._boundPlanRows = planRows
                end
                if StockPiler3TabWatch.UpdateRows then
                    StockPiler3TabWatch.UpdateRows({ keepVisible = true })
                end
            end
            Ui._watchUiDirty = false
            return
        end
        if type(listData) == "table"
            and #listData > 0
            and StockPiler3.Planner
            and StockPiler3.Planner.LiveRecount
        then
            if StockPiler3.Perf and StockPiler3.Perf.Begin then
                StockPiler3.Perf.Begin("UiFlush.BrewCatchup")
            end
            -- Post-brew / bag snap while session stays loaded: recount craftable too
            -- (manual Brew used to leave Craftable stuck until hold expired).
            StockPiler3.Planner.LiveRecount({
                invalidateStamps = true,
                allowWarmHave = true,
                syncSnapshot = true,
                forceRecountCraftable = true,
            })
            if StockPiler3TabWatch.UpdateRows then
                StockPiler3TabWatch.UpdateRows({ keepVisible = true })
            end
            if StockPiler3.Perf and StockPiler3.Perf.End then
                StockPiler3.Perf.End("UiFlush.BrewCatchup")
            end
        end
        Ui._watchUiDirty = false
        return
    end

    -- Potions/Plants selected: Have/structure only — never RefreshActiveTab (scroll jump).
    if FlushCatalogTabUi() then
        return true
    end

    -- Brew hold just dropped (or never held): one ListBox rebind if indices empty.
    if StockPiler3TabWatch and StockPiler3TabWatch.FlushPendingListRebind then
        StockPiler3TabWatch.FlushPendingListRebind()
    end

    local knowledgeGen = 0
    if StockPiler3.Knowledge and StockPiler3.Knowledge.GetGen then
        knowledgeGen = tonumber(StockPiler3.Knowledge.GetGen()) or 0
    end
    local planGen = CurrentPlanGen()
    local brewKey = BrewChromeKey()
    local contentKey = WatchContentKey()
    local planChanged = planGen ~= (tonumber(Ui._watchUiLastPlanGen) or 0)
    local knowledgeChanged = knowledgeGen ~= (tonumber(Ui._watchUiLastKnowledgeGen) or 0)
        or Ui._catalogStructureDirty == true
    local openPaint = OpenPaintActive()
    -- Plan/knowledge can change without stock/craftable deltas; never skip those.
    if not openPaint and Ui._watchUiLastKey == contentKey and not planChanged and not knowledgeChanged then
        if WatchMissingSkillUpRows() then
            -- SkillUp rows never made it into listData; Flatten again.
        else
            Ui._watchUiDirty = false
            return
        end
    end
    local now = 0
    if type(GetGameTime) == "function" then
        now = tonumber(GetGameTime()) or 0
    end
    local last = tonumber(Ui._watchUiFlushedAt) or 0
    local brewChanged = brewKey ~= tostring(Ui._watchUiLastBrewKey or "")
    local interval = Ui.WATCH_UI_MIN_INTERVAL_SEC
    if IsAnyTabVisible() then
        interval = tonumber(Ui.WATCH_UI_OPEN_INTERVAL_SEC) or 0.5
    end
    if not knowledgeChanged and not planChanged and not brewChanged and IsWatchPlanStale() then
        interval = math.min(interval, 1.0)
    end
    if not openPaint
        and not knowledgeChanged
        and not planChanged
        and not brewChanged
        and last > 0
        and (now - last) < interval
    then
        return
    end

    if StockPiler3.Perf and StockPiler3.Perf.Begin then
        StockPiler3.Perf.Begin("UiFlush")
    end
    Ui._watchUiDirty = false
    Ui._watchUiFlushedAt = now
    Ui._watchUiBrewCatchupAt = 0
    Ui._watchUiLastKey = contentKey
    Ui._watchUiLastKnowledgeGen = knowledgeGen
    Ui._watchUiLastPlanGen = planGen
    Ui._watchUiLastBrewKey = brewKey
    if StockPiler3Window and StockPiler3Window.RefreshActiveTab then
        StockPiler3Window.RefreshActiveTab()
    end
    if OpenPaintActive() then
        local watchVisible = IsWatchTabVisible()
        local listCount = 0
        if StockPiler3TabWatch and type(StockPiler3TabWatch.listData) == "table" then
            listCount = #StockPiler3TabWatch.listData
        end
        local populated = false
        if SP3TabWatchList and type(SP3TabWatchList.PopulatorIndices) == "table"
            and next(SP3TabWatchList.PopulatorIndices) ~= nil
        then
            populated = true
        end
        if (not watchVisible) or populated then
            StockPiler3Window._openPaintPending = false
        else
            if listCount > 0 and StockPiler3TabWatch and DoesWindowExist("SP3TabWatchList") then
                local order = StockPiler3TabWatch.displayOrder
                if type(order) == "table" and #order > 0 then
                    ListBoxSetDisplayOrder("SP3TabWatchList", order)
                end
            end
            Ui._watchUiDirty = true
        end
    end
    if StockPiler3.Perf and StockPiler3.Perf.End then
        StockPiler3.Perf.End("UiFlush")
    end
    return true
end

function Ui.InitializeWindow()
    if StockPiler3Window and StockPiler3Window.Initialize then
        StockPiler3Window.Initialize()
    end
end

function Ui.RegisterEventRefresh()
    if Ui._eventsRegistered == true then
        return
    end
    local B = StockPiler3.EventBus
    local E = StockPiler3.Events
    if not B or not E then
        return
    end
    Ui._busTokens = Ui._busTokens or {}
    local tokens = Ui._busTokens
    local function track(token)
        if token then
            tokens[#tokens + 1] = token
        end
    end
    local function markDirty()
        Ui.MarkWatchUiDirty()
    end
    track(B.Subscribe(E.PLAN_UPDATED, function()
        Ui.ClearWatchTipCaches()
        Ui.MarkWatchUiDirty()
        Ui.RequestFooterRefresh()
    end))
    track(B.Subscribe(E.PLAN_INVALIDATED, markDirty))
    track(B.Subscribe(E.INVENTORY_SNAPSHOT, function()
        Ui.MarkWatchUiDirty()
        -- Stock/status paints now. Craftable is one WarmHave per snapGen, not
        -- a sync walk on every brew slot event: mid-brew snaps only set the
        -- defer flag (Pump will not run the job until the session is idle).
        RequestForcedWatchRecount("inventory-snapshot")
        TryWatchLiveCatchup({ forceRecount = false })
        TryCatalogLiveCatchup()
    end))
    if E.INVENTORY_DIRTY then
        track(B.Subscribe(E.INVENTORY_DIRTY, markDirty))
    end
    track(B.Subscribe(E.GARDEN_SNAPSHOT, markDirty))
    if E.GARDEN_DIRTY then
        track(B.Subscribe(E.GARDEN_DIRTY, markDirty))
    end
    if E.PHASE_CHANGED then
        track(B.Subscribe(E.PHASE_CHANGED, function()
            Ui.InvalidateSkillGates()
            markDirty()
            Ui.RequestFooterRefresh()
        end))
    end
    if E.REFINE_OUTSTANDING then
        track(B.Subscribe(E.REFINE_OUTSTANDING, markDirty))
    end
    if E.VENDOR_UPDATED then
        track(B.Subscribe(E.VENDOR_UPDATED, function()
            markDirty()
            Ui.RequestFooterRefresh()
        end))
    end
    if E.CRAFT_READY_CHANGED then
        track(B.Subscribe(E.CRAFT_READY_CHANGED, function()
            Ui.RequestFooterRefresh()
            -- Defer recount so we do not re-enter PatchWatchRowsLiveCounts mid-call.
            RequestForcedWatchRecount("craft-ready")
            Ui.MarkWatchUiDirty()
        end))
    end
    if E.FOOTER_DIRTY then
        track(B.Subscribe(E.FOOTER_DIRTY, OnFooterDirty))
    end
    if E.WATCH_UI_DIRTY then
        track(B.Subscribe(E.WATCH_UI_DIRTY, OnWatchUiDirty))
    end
    if E.BREW_SESSION_CHANGED then
        track(B.Subscribe(E.BREW_SESSION_CHANGED, OnBrewSessionChanged))
    end
    if E.KNOWLEDGE_UPDATED then
        track(B.Subscribe(E.KNOWLEDGE_UPDATED, function()
            -- Knowledge can land after an inventory flush already painted Potions.
            -- Bypass Watch throttle for the next coalesced flush - never sync paint
            -- (WarmHave used to hide inside WatchRows on the same frame as CultivationUpdated).
            -- Structural learn needs a full catalog list rebuild, not PatchLiveHave.
            Ui._catalogStructureDirty = true
            Ui.BypassWatchThrottle()
            Ui._watchUiLastKnowledgeGen = 0
            Ui.MarkWatchUiDirty()
            -- Show newly learned potions while the catalog tab is open (no tab flip).
            if IsCatalogTabVisible() then
                FlushCatalogIfStructureDirty()
            end
        end))
    end
    if E.SESSION_LOADED then
        track(B.Subscribe(E.SESSION_LOADED, function()
            if StockPiler3TabWatch and StockPiler3TabWatch.RefreshSkillGates then
                StockPiler3TabWatch.RefreshSkillGates()
            end
            -- Session load: mark dirty only. Sync RefreshActiveTab here caused the
            -- SP2 Flatten hitch (Planner.Build + WarmHave + WatchRows + CultivationUpdated
            -- x4 on the same frame as Garden.SyncAll / first plan rebuild).
            Ui.BypassWatchThrottle()
            Ui._watchUiLastBrewKey = nil
            Ui._watchUiLastPlanGen = 0
            Ui._watchUiLastKnowledgeGen = 0
            Ui.ClearWatchTipCaches()
            Ui.MarkWatchUiDirty()
        end))
    end
    Ui._eventsRegistered = true
end

function Ui.UnregisterEventRefresh()
    local B = StockPiler3.EventBus
    local tokens = Ui._busTokens
    if B and B.Unsubscribe and type(tokens) == "table" then
        for i = 1, #tokens do
            B.Unsubscribe(tokens[i])
        end
    end
    Ui._busTokens = nil
    Ui._eventsRegistered = false
end
