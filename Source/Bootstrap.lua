----------------------------------------------------------------
-- StockPiler3 Bootstrap -- init, shutdown, slash commands
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Version = L"0.3.89"

local function T(key, tokens)
    if StockPiler3.T then
        return StockPiler3.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

local function EmitLog(msg)
    if StockPiler3.Debug and StockPiler3.Debug.LogAlways then
        StockPiler3.Debug.LogAlways(msg)
    end
end

local function Print(msg)
    if StockPiler3.Debug and StockPiler3.Debug.Print then
        StockPiler3.Debug.Print(msg)
    end
end

local function OnOff(on)
    return on and T("boot.on") or T("boot.off")
end

local function SetDebugEnabled(on)
    local s = StockPiler3.Persistence.EnsureSettings()
    s.debugEnabled = on == true
    StockPiler3.Debug.Enabled = s.debugEnabled
    EmitLog("settings| debug=" .. (StockPiler3.Debug.Enabled and "ON" or "OFF"))
    Print(T("boot.debug", { state = OnOff(StockPiler3.Debug.Enabled) }))
end

local function SetEventTrace(on)
    local s = StockPiler3.Persistence.EnsureSettings()
    s.eventTrace = on == true
    StockPiler3.Debug.EventTrace = s.eventTrace
    Print(T("boot.event_trace", { state = OnOff(s.eventTrace) }))
end

local function PrintHelp()
    Print(T("boot.help.header"))
    Print(T("boot.help.open"))
    Print(T("boot.help.help"))
    Print(T("boot.help.tabs"))
    Print(T("boot.help.debug"))
    Print(T("boot.help.dumps"))
    Print(T("boot.help.bags"))
    Print(T("boot.help.fingerprint"))
    Print(T("boot.help.events"))
    Print(T("boot.help.perf"))
    Print(T("boot.help.audit"))
    Print(T("boot.help.mem"))
    Print(T("boot.help.harvest"))
end

local function DumpMem(emit)
    emit = emit or EmitLog
    local function count(t)
        if StockPiler3.Debug and StockPiler3.Debug.SafeKeyCount then
            return StockPiler3.Debug.SafeKeyCount(t, 0, {})
        end
        if type(t) ~= "table" then
            return 0
        end
        local n = 0
        for _ in pairs(t) do
            n = n + 1
        end
        return n
    end
    emit("mem| StockPiler3 top keys=" .. tostring(count(StockPiler3)))
    if type(StockPiler3.Account) == "table" then
        emit("mem| Account keys=" .. tostring(count(StockPiler3.Account)))
        for _, name in ipairs({ "items", "grows", "refines", "recipes", "potions", "additives", "vendorItems" }) do
            emit("mem| Account." .. name .. "=" .. tostring(count(StockPiler3.Account[name])))
        end
    end
    if type(StockPiler3.Settings) == "table" then
        emit("mem| Settings keys=" .. tostring(count(StockPiler3.Settings)))
        emit("mem| Settings.characters=" .. tostring(count(StockPiler3.Settings.characters)))
    end
end

local function DumpAudit(emit)
    emit = emit or EmitLog
    local unexpected = {}
    if StockPiler3.Persistence and StockPiler3.Persistence.AuditAccountKeys then
        unexpected = StockPiler3.Persistence.AuditAccountKeys() or {}
    end
    emit("audit| unexpected Account keys=" .. tostring(#unexpected))
    for i = 1, #unexpected do
        emit("audit|  " .. tostring(unexpected[i]))
    end
end

function StockPiler3.OnSlash(input)
    local text = ""
    if input ~= nil then
        text = tostring(input)
    end
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    local lower = string.lower(text)

    if lower == "" then
        if StockPiler3.Ui and StockPiler3.Ui.ToggleWindow then
            StockPiler3.Ui.ToggleWindow()
        end
        return
    end
    if lower == "help" then
        PrintHelp()
        return
    end
    if lower == "potions" then
        if StockPiler3.Ui and StockPiler3.Ui.ShowWindow then
            StockPiler3.Ui.ShowWindow(1)
        end
        return
    end
    if lower == "plants" then
        if StockPiler3.Ui and StockPiler3.Ui.ShowWindow then
            StockPiler3.Ui.ShowWindow(2)
        end
        return
    end
    if lower == "watch" then
        if StockPiler3.Ui and StockPiler3.Ui.ShowWindow then
            StockPiler3.Ui.ShowWindow(3)
        end
        return
    end
    if lower == "open" or lower == "show" then
        if StockPiler3.Ui and StockPiler3.Ui.ToggleWindow then
            StockPiler3.Ui.ToggleWindow()
        end
        return
    end
    if lower == "debug" or lower == "debug on" then
        SetDebugEnabled(true)
        return
    end
    if lower == "debug off" then
        SetDebugEnabled(false)
        return
    end
    if lower == "plan" then
        if StockPiler3.Planner and StockPiler3.Planner.Dump then
            StockPiler3.Planner.Dump(function(msg) EmitLog(msg) end)
            Print(T("boot.plan_dumped"))
        end
        return
    end
    if lower == "watchplan" then
        if StockPiler3.Planner and StockPiler3.Planner.DumpWatchPlan then
            StockPiler3.Planner.DumpWatchPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.watchplan_dumped"))
        end
        return
    end
    if lower == "state" then
        if StockPiler3.Orchestrator and StockPiler3.Orchestrator.DumpState then
            StockPiler3.Orchestrator.DumpState(function(msg) EmitLog(msg) end)
            Print(T("boot.state_dumped"))
        end
        return
    end
    if lower == "growplan" then
        if StockPiler3.Planner and StockPiler3.Planner.DumpGrowPlan then
            StockPiler3.Planner.DumpGrowPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.growplan_dumped"))
        elseif StockPiler3.Grow and StockPiler3.Grow.DumpGrowPlan then
            StockPiler3.Grow.DumpGrowPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.growplan_dumped"))
        end
        return
    end
    if lower == "brewplan" then
        if StockPiler3.Planner and StockPiler3.Planner.DumpBrewPlan then
            StockPiler3.Planner.DumpBrewPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.brewplan_dumped"))
        elseif StockPiler3.Brew and StockPiler3.Brew.DumpPlan then
            StockPiler3.Brew.DumpPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.brewplan_dumped"))
        end
        return
    end
    if lower == "buyplan" then
        if StockPiler3.Buy and StockPiler3.Buy.DumpBuyPlan then
            StockPiler3.Buy.DumpBuyPlan({ force = true })
            Print(T("boot.buyplan_dumped"))
        end
        return
    end
    if lower == "stats" then
        if StockPiler3.SeedMap and StockPiler3.SeedMap.DumpCraftCycleStats then
            StockPiler3.SeedMap.DumpCraftCycleStats(function(msg) EmitLog(msg) end)
            Print(T("boot.stats_dumped"))
        else
            EmitLog("stats| craft-cycle dump unavailable")
            Print(T("boot.stats_dumped"))
        end
        return
    end
    if lower == "bags" or lower == "bags force" then
        if StockPiler3.BagAdapter and StockPiler3.BagAdapter.Dump then
            local force = string.find(lower, "force", 1, true) ~= nil
            StockPiler3.BagAdapter.Dump(function(msg) EmitLog(msg) end, { force = force })
            Print(T("boot.bags_dumped"))
        elseif StockPiler3.Inventory and StockPiler3.Inventory.RefreshAllIfNeeded then
            StockPiler3.Inventory.RefreshAllIfNeeded({ force = true })
            Print(T("boot.bags_dumped"))
        end
        return
    end
    -- /sp3 fingerprint <uidA> [uidB] — ProductKey + ProductMatches (butcher twin check).
    local fpA, fpB = string.match(lower, "^fingerprint%s+(%d+)%s*(%d*)$")
    if fpA then
        if StockPiler3.MaterialSpec and StockPiler3.MaterialSpec.DumpFingerprintCompare then
            StockPiler3.MaterialSpec.DumpFingerprintCompare(
                tonumber(fpA),
                (fpB ~= nil and fpB ~= "") and tonumber(fpB) or nil,
                function(msg) EmitLog(msg) end
            )
            Print(T("boot.fingerprint_dumped"))
        end
        return
    end
    if lower == "events on" then
        SetEventTrace(true)
        return
    end
    if lower == "events off" then
        SetEventTrace(false)
        return
    end
    if lower == "events dump" then
        if StockPiler3.Debug and StockPiler3.Debug.DumpEventRing then
            StockPiler3.Debug.DumpEventRing(function(msg) EmitLog(msg) end)
            Print(T("boot.events_dumped"))
        end
        return
    end
    if lower == "events" then
        local s = StockPiler3.Persistence.EnsureSettings()
        SetEventTrace(not (s.eventTrace == true))
        return
    end
    if lower == "mem" then
        DumpMem(function(msg) EmitLog(msg) end)
        Print(T("boot.mem_dumped"))
        return
    end
    if lower == "audit" then
        DumpAudit(function(msg) EmitLog(msg) end)
        Print(T("boot.audit_dumped"))
        return
    end
    if lower == "harvest" then
        local B = StockPiler3.EventBus
        local E = StockPiler3.Events
        if B and E and E.CMD_HARVEST then
            B.Fire(E.CMD_HARVEST, {})
        elseif StockPiler3.Grow and StockPiler3.Grow.PrepareHarvestPlot then
            StockPiler3.Grow.PrepareHarvestPlot(true)
        end
        return
    end
    if lower == "perf" or string.sub(lower, 1, 5) == "perf " then
        if StockPiler3.Perf and StockPiler3.Perf.PrintSummary then
            StockPiler3.Perf.PrintSummary()
        else
            Print(T("boot.help.perf"))
        end
        return
    end
    Print(T("boot.unknown_cmd"))
end

function StockPiler3.Initialize()
    StockPiler3.Persistence.EnsureSettings()
    if StockPiler3.Locale and StockPiler3.Locale.Initialize then
        StockPiler3.Locale.Initialize()
    end
    StockPiler3.T = StockPiler3.Locale and StockPiler3.Locale.Format or StockPiler3.T
    StockPiler3.Persistence.EnsureAccount()
    if StockPiler3.Knowledge and StockPiler3.Knowledge.Ensure then
        StockPiler3.Knowledge.Ensure()
    end
    -- After Account exists: fingerprint migrate (must not run inside EnsureAccount).
    if StockPiler3.Knowledge and StockPiler3.Knowledge.MigrateFingerprints then
        StockPiler3.Knowledge.MigrateFingerprints()
    elseif StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.MigrateRecipeFingerprintsV2 then
        StockPiler3.RecipeSpec.MigrateRecipeFingerprintsV2()
    end
    if StockPiler3.Watch and StockPiler3.Watch.MigratePriorityTiersIfNeeded then
        StockPiler3.Watch.MigratePriorityTiersIfNeeded()
    end
    local s = StockPiler3.Settings
    if type(s) == "table" and StockPiler3Window then
        -- 0.3.89 inserted Plants as tab 2; bump old Watch (2) → 3 once.
        if s._sp389WatchTabBump ~= true then
            if tonumber(s.selectedTab) == 2 then
                s.selectedTab = 3
            end
            s._sp389WatchTabBump = true
        end
        local tab = tonumber(s.selectedTab) or 1
        if tab < 1 or tab > 3 then
            tab = 1
        end
        StockPiler3Window.SelectedTab = tab
    end
    if StockPiler3.Scheduler and StockPiler3.Scheduler.Initialize then
        StockPiler3.Scheduler.Initialize()
    end
    if StockPiler3.Orchestrator and StockPiler3.Orchestrator.Initialize then
        StockPiler3.Orchestrator.Initialize()
    end
    if StockPiler3.Macro and StockPiler3.Macro.Initialize then
        StockPiler3.Macro.Initialize()
    end
    if StockPiler3.EngineEventBridge and StockPiler3.EngineEventBridge.Register then
        StockPiler3.EngineEventBridge.Register()
    end
    if StockPiler3.CraftChatAdapter and StockPiler3.CraftChatAdapter.RegisterChat then
        StockPiler3.CraftChatAdapter.RegisterChat()
    end
    if StockPiler3.VendorAdapter and StockPiler3.VendorAdapter.EnsureStoreHook then
        StockPiler3.VendorAdapter.EnsureStoreHook()
    end
    if StockPiler3.LearnBridge and StockPiler3.LearnBridge.Initialize then
        StockPiler3.LearnBridge.Initialize()
    end
    if StockPiler3.Ui and StockPiler3.Ui.InitializeWindow then
        StockPiler3.Ui.InitializeWindow()
    end
    if StockPiler3.Ui and StockPiler3.Ui.RegisterEventRefresh then
        StockPiler3.Ui.RegisterEventRefresh()
    end
    if StockPiler3.Brew and StockPiler3.Brew.RegisterEventHandlers then
        StockPiler3.Brew.RegisterEventHandlers()
    end
    if StockPiler3.Debug and StockPiler3.Debug.InstallChatLinkHook then
        StockPiler3.Debug.InstallChatLinkHook()
    end
    if LibSlash and LibSlash.RegisterWSlashCmd then
        LibSlash.RegisterWSlashCmd("sp3", StockPiler3.OnSlash)
        LibSlash.RegisterWSlashCmd("stockpiler3", StockPiler3.OnSlash)
    else
        EmitLog("init LibSlash missing - /sp3 may need manual binding; addon still loads")
    end
    EmitLog("init v" .. tostring(StockPiler3.Version)
        .. " debug=" .. tostring(StockPiler3.Debug and StockPiler3.Debug.Enabled == true))
    Print(T("boot.loaded", { version = StockPiler3.Version }))
    if StockPiler3.Scheduler and StockPiler3.Scheduler.EnqueueBagFlush then
        StockPiler3.Scheduler.EnqueueBagFlush(true)
    end
end

function StockPiler3.Shutdown()
    if StockPiler3.Debug and StockPiler3.Debug.UninstallChatLinkHook then
        StockPiler3.Debug.UninstallChatLinkHook()
    end
    if StockPiler3.Macro and StockPiler3.Macro.Shutdown then
        StockPiler3.Macro.Shutdown()
    end
    if StockPiler3.Brew and StockPiler3.Brew.UnregisterEventHandlers then
        StockPiler3.Brew.UnregisterEventHandlers()
    end
    if StockPiler3.Ui and StockPiler3.Ui.UnregisterEventRefresh then
        StockPiler3.Ui.UnregisterEventRefresh()
    end
    if StockPiler3.Orchestrator and StockPiler3.Orchestrator.Shutdown then
        StockPiler3.Orchestrator.Shutdown()
    end
    if StockPiler3.LearnBridge and StockPiler3.LearnBridge.Shutdown then
        StockPiler3.LearnBridge.Shutdown()
    end
    if StockPiler3.EngineEventBridge and StockPiler3.EngineEventBridge.Unregister then
        StockPiler3.EngineEventBridge.Unregister()
    end
    if StockPiler3.CraftChatAdapter and StockPiler3.CraftChatAdapter.UnregisterChat then
        StockPiler3.CraftChatAdapter.UnregisterChat()
    end
    if StockPiler3.Scheduler and StockPiler3.Scheduler.Shutdown then
        StockPiler3.Scheduler.Shutdown()
    end
    if StockPiler3.RecipeSpec and StockPiler3.RecipeSpec.SlimAllRecipesForStorage then
        StockPiler3.RecipeSpec.SlimAllRecipesForStorage()
    end
    if StockPiler3.Persistence and StockPiler3.Persistence.StripUnexpectedAccountKeys then
        StockPiler3.Persistence.StripUnexpectedAccountKeys()
    end
    EmitLog("shutdown")
end
