# StockPiler3 Code Quality Review

An in-depth review of **StockPiler3** (version 0.3.220, ~54 Lua files, ~1.69 MB of code) was performed across **Architecture**, **Separation of Responsibilities**, **Code Duplication**, and **Obvious Bugs & Fragilities**.

---

## 1. Architecture

### 1.1 Intent vs. Reality: Decay of the Unidirectional Pipeline
The build specification in [`docs/STOCKPILER3_BUILD_PROMPT.md`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/docs/STOCKPILER3_BUILD_PROMPT.md#L121-L135) mandated a clean, unidirectional, storm-safe pipeline:
```
Events -> EngineEventBridge -> EventBus -> Stores -> Orchestrator -> Planner -> Domain/Executors -> Adapters -> View
```
In practice, the system has decayed into a circular mesh:
- **Abandonment of the [EventBus](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/EventBus.lua):** Across 54 files, only [`LearnBridge.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/LearnBridge.lua#L306) and [`Orchestrator.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Orchestrator.lua#L660) subscribe to events. Rather than decoupling systems via events, modules make direct synchronous calls across layer boundaries.
- **Upward coupling:** Domain executors ([`Grow.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Grow.lua#L2068), [`Brew.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Brew.lua#L825), [`Buy.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Buy.lua#L645)), the bridge ([`EngineEventBridge.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/EngineEventBridge.lua#L148)), and the planner ([`Planner.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Planner/Planner.lua#L3818)) all directly invoke UI window methods like `StockPiler3Window.RequestFooterRefresh()`.
- **Downward knowledge coupling:** The data/knowledge modules ([`RecipeSpec.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/RecipeSpec.lua#L2472) and [`SeedMap.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/SeedMap.lua#L781)) reach up into dynamic stores ([`InventoryStore`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Stores/InventoryStore.lua), [`WatchStore`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Stores/WatchStore.lua)) and the [`Planner`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Planner/Planner.lua).

### 1.2 "God Files" and Monolithic Module Sizes
Rather than decomposing concerns into focused, testable modules, several components have grown into massive monolithic files:
- [`Planner.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Planner/Planner.lua): **4,883 lines** (combines demand solvers, cache warming, UI row patching, and garden patching).
- [`SkillUp.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/SkillUp.lua): **3,872 lines** (an entire shadow addon within the addon: custom seed economics, stability solvers, rate trackers, empirical statistics, and ephemeral UI synthesis).
- [`SeedMap.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/SeedMap.lua): **3,059 lines** (handles seed-to-plant mapping, ladder navigation, inventory querying, and craft cycle stats).
- [`Grow.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Grow.lua): **2,632 lines** (merges plot querying, candidate planning, planting execution, additives, and harvesting macros).
- [`StockPiler3TabWatch.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/View/StockPiler3TabWatch.lua): **2,433 lines** (view file containing heavy business logic, status resolution, and live count recalculations).
- [`UpgradeSeed.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/UpgradeSeed.lua): **2,287 lines** (parallel climb policy and ladder logic).
- [`Brew.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Brew.lua): **2,307 lines** (crafting FSM mixed with live plan mutation).

### 1.3 Accumulation of Workaround Layers (Repeating SP2 Patterns)
While the build prompt specifically warned: *"Do not reproduce StockPiler2's module sprawl, patch-layered caches, or historical workarounds as an architecture template"*, StockPiler3 has re-accumulated that exact complexity:
- In [`Scheduler.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Scheduler.lua#L13-L25) and [`FrameWork.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/FrameWork.lua#L70-L92), there are over 15 interlocking cooldowns, quiet periods, suppression ticks, and bypass flags (`_skipPlanThisFrame`, `_skipUiThisFrame`, `_skipUiHoldFooter`, `_skipOrchThisFrame`, `_suppressInvTicks`, `_pendingBagFlushAfterSuppress`, `plantQuiet`, `harvestStorm`, `fillBlocked`).
- Rather than fixing the core cost of plan updates, layers of deferral and pre-warming were stacked to mask it.

### 1.4 Frame-Slicing Anti-Pattern (`FrameWork.lua`) & Temporal Desync
[`FrameWork.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/FrameWork.lua) implements an asynchronous, cooperative time-sliced background job queue designed to avoid frame hitches by spreading prewarm work across 6+ frames:
- **Temporal State Tearing:** Because calculations span 80–130ms across multiple frames, the game state changes *while* a calculation is in-flight (items harvested, seeds planted, bags moved). This invalidates intermediate steps and forces frequent job cancellations and restarts.
- **UI Freezes and Stagnation:** [`Scheduler.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Scheduler.lua#L217) explicitly holds full plan rebuilds and Watch UI paints while `FW.IsPrewarmBusy()` is true. During rapid planting, harvesting, or buying storms, prewarm jobs are repeatedly re-enqueued, causing the Watch tab and macro tooltips to freeze on stale data (e.g. `craftable = 0` or `Restocking`) for 3 to 5 seconds after materials are already present in bags.
- **Treating the Symptom:** Slicing was only introduced because bag matching performed unindexed linear scans and `RebuildFromBags` generated heavy GC allocation churn. With $O(1)$ indexed bag lookup tables, the entire planning calculation takes < 1.5ms, rendering multi-frame slicing an expensive, bug-inducing anti-pattern.

---


## 2. Separation of Responsibilities

### 2.1 Planning Leaked into Execution and Domain Modules
- **[`Grow.PickPlantCandidate`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Grow.lua#L1523):** The domain executor [`Grow.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Grow.lua) calculates bottle gaps, waterfill priorities, and demand traversal instead of executing an intent supplied by [`Planner.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Planner/Planner.lua).
- **[`RecipeSpec.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/RecipeSpec.lua#L2472-L2536):** A knowledge spec module contains Planner shims ([`RS.BuildBalancedSpecDemand`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/RecipeSpec.lua#L2472), [`RS.CollectAutoGrowFocus`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/RecipeSpec.lua#L2480), [`RS.WatchHasSeedBufferShort`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/RecipeSpec.lua#L2542)) because callers in domain logic were routed through `RecipeSpec` instead of `Planner`.

### 2.2 Execution Modules Mutating Planning Snapshots In-Place
- In [`Brew.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Brew.lua#L1976-L1984) and [`Buy.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Buy.lua#L625-L633), after performing an action, instead of letting the planner invalidate and rebuild or issuing an event, the code fetches `PlanSnapshot.Get().rows` and mutates the rows directly via [`Planner.PatchWatchRowsLiveCounts`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Planner/Planner.lua#L4320).
- This violates snapshot immutability: downstream consumers reading the snapshot receive altered data without the snapshot generation counter changing.

### 2.3 Presentation Layer Heavily Polluted with Domain Logic
- [`StockPiler3TabWatch.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/View/StockPiler3TabWatch.lua): View controllers should bind data to XML widgets. Instead, `StockPiler3TabWatch.lua` evaluates complex business logic, manages ephemeral row creation ([`IsEphemeralWatchRow`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/View/StockPiler3TabWatch.lua#L191)), evaluates skill criteria, updates trade skill data, and recomputes status colors and priority tiers.

### 2.4 Private Field Coupling Across Modules
Modules frequently inspect and modify internal underscore-prefixed fields of other modules:
- [`Orchestrator.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Orchestrator.lua#L104) directly checks `Refine._refineDirty` and `Refine._refineDirtyReason`.
- [`Buy.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Buy.lua#L623) directly writes `Planner._closedLiveSnapGen = nil`.
- [`UpgradeSeed.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/UpgradeSeed.lua) and [`Orchestrator.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Orchestrator.lua#L316) call `Grow.MarkPlantJobProbed(nil)` and `Grow.MarkPlantJobDirty("refine-miss")`.

---

## 3. Code Duplication

### 3.1 Parallel Systems for Seed & Skill Progression
The addon contains two massive, parallel implementations of seed ladder traversal, deficit calculations, and tier capping:
1. [`UpgradeSeed.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/UpgradeSeed.lua) (2,287 lines)
2. [`SkillUp.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/SkillUp.lua) (3,872 lines)
Both calculate seed deficits, rung counts, ladder rungs, genus merges, and plantable surpluses independently, with slightly diverging rules.

### 3.2 Repeated Domain Functions
- **TradeSkill & Tier resolution:** [`FloorCultTier`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/SkillUp.lua#L76), [`FloorApoTier`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/SkillUp.lua#L62), and [`GetCultSkill`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/SkillUp.lua#L89) are defined in [`TradeSkillCaps.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Adapters/TradeSkillCaps.lua), re-implemented/wrapped in [`SkillUp.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/SkillUp.lua), and re-implemented again in [`UpgradeSeed.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/UpgradeSeed.lua#L61-L75).
- **In-ground seed accounting:** `CountInGroundSeeds` logic is implemented in [`Grow.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Grow.lua#L184), wrapped in [`Grow.CountInGroundSeeds`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Grow.lua#L972), and re-queried or mirrored in [`Refine.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Refine.lua#L160) and [`UpgradeSeed.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/UpgradeSeed.lua#L589).
- **Demand balancing:** [`BuildBalancedSpecDemand`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Planner/Planner.lua#L912) exists in [`Planner.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Planner/Planner.lua) and is cloned as shims in [`RecipeSpec.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/RecipeSpec.lua#L2472).

### 3.3 Redundant Boilerplate Helpers
Identical utility functions are copy-pasted locally across dozens of files instead of leveraging [`Util.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Util.lua):
- `ToNarrow`: Defined in **14 files** ([`Catalog.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/View/Catalog.lua), [`SeedMap.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/SeedMap.lua), [`MaterialSpec.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/MaterialSpec.lua), etc.).
- `NowSec`: Defined in **9 files** ([`SkillUp.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/SkillUp.lua), [`Brew.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Brew.lua), [`Grow.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Grow.lua), [`Refine.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Refine.lua), [`Buy.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Buy.lua), etc.).
- `TryQuiet` / `TryCall`: Defined locally across **6 files**.
- `StageEmpty`: Defined in **5 files**.
- `T()` boilerplate: Repeated across **17 files**.

---

## 4. Obvious Bugs & Fragilities

### 4.1 Modifying Tables During `pairs()` Traversal
In [`RefinePipelineStore.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Stores/RefinePipelineStore.lua#L148-L177) (`RP.ExpireStuck`):
```lua
for seedUid, row in pairs(RP._outstanding) do
    ...
    if type(row) ~= "table" then
        row = { count = tonumber(row) or 0, at = now, softTried = false }
        RP._outstanding[seedUid] = row   -- Mutating value in-place during pairs
    end
    ...
    RP._outstanding[seedUid] = nil       -- Deleting key during pairs
```
In Lua 5.1, reassigning table keys during `pairs` iteration can cause keys to be skipped or the iterator to behave unpredictably.

### 4.2 Triplicated Plant-Execution Logic in Orchestrator Tick
In [`Orchestrator.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Orchestrator.lua):
The exact sequence to plant a candidate seed is written in 3 separate locations within [`_TickBody`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Orchestrator.lua#L273):
- Lines [328–341](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Orchestrator.lua#L328-L341) (`fillBlocked` branch)
- Lines [475–488](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Orchestrator.lua#L475-L488) (main plant branch)
- Lines [562–577](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Orchestrator.lua#L562-L577) (fallback after failed refine)
Crucially, line 330 only calls `Grow.IssuePlantOne`, while lines 478 and 566 call `Grow.IssuePlantOne` with a fallback to `Grow.TryPlantOne`. This divergence creates subtle behavioral discrepancies depending on which tick branch executes.

### 4.3 Fragile SavedVariables State (Evidenced by External Repair Scripts)
The repository includes several external Python repair scripts in [`tools/`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/tools):
- [`_repair_climb_links_sv.py`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/tools/_repair_climb_links_sv.py): Patches broken seed-plant climb links in `SavedVariables.lua` because in-game learning links crit plants to lower-tier seeds.
- [`_scrub_skillup_origin_sv.py`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/tools/_scrub_skillup_origin_sv.py): Cleans `skillUpOrigin` test recipes from the account saved variables because `SkillUp` brewing polluted the persistent learned recipe catalog.
- [`_check_nulls.py`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/tools/_check_nulls.py): Fixes null-byte (`\0`) corruption in `SavedVariables.lua`.

The existence of these offline scripts demonstrates that:
1. In-game observe/learning logic in [`LearnBridge.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/LearnBridge.lua) lacks sufficient input validation.
2. The persistence layer lacks schema validation and serialization safeguards to reject corrupted data at runtime.

### 4.4 High Memory Churn in High-Frequency Paths
In [`InventoryStore.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Stores/InventoryStore.lua#L80-L100) (`RebuildFromBags`), new tables are instantiated on every bag refresh:
```lua
local counts = {}
local slotIndex = { main = {}, craft = {} }
local itemBySlot = { main = {}, craft = {} }
local sampleByUid = {}
```
In the Warhammer Online client (32-bit Lua 5.1 with incremental GC), generating tables of this size during harvest storms or bag flushes causes frequent GC spikes and micro-stutters. Reusing static tables (`wipe(t)`) would eliminate this allocation pressure.

---

## 5. Summary Recommendation

| Area | Rating | Priority Action |
| :--- | :---: | :--- |
| **Architecture** | ⚠️ Needs Work | Restore unidirectional data flow: eliminate multi-frame slicing (`FrameWork.lua`) in favor of fast $O(1)$ indexed matching and debouncing; decouple View and Executors from UI refresh via event dispatch. |
| **Separation of Responsibilities** | ⚠️ Needs Work | Move candidate picking logic from [`Grow.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Grow.lua) into [`Planner.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Planner/Planner.lua). Stop mutating `PlanSnapshot.Get().rows` in [`Brew.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Brew.lua) and [`Buy.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Buy.lua). |
| **Code Duplication** | ❌ Poor | Merge the parallel ladder and seed economy code in [`UpgradeSeed.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/UpgradeSeed.lua) and [`SkillUp.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/SkillUp.lua). Consolidate copy-pasted helpers (`ToNarrow`, `NowSec`, `consider`) into [`Util.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Util.lua). |
| **Obvious Bugs & Stability** | ⚠️ Needs Work | Fix the table mutation during iteration in [`RefinePipelineStore.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Stores/RefinePipelineStore.lua#L151). Unify the duplicated plant execution branches in [`Orchestrator.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Orchestrator.lua#L328). Add runtime sanity validation for `Account.grows` and `Account.refines` to prevent corrupt ladder links. |


---

## 6. Next Steps & Architectural Roadmap

For the detailed strategic evaluation between in-place fixes and a parallel StockPiler4 refactor, see [`docs/REFACTORING_RECOMMENDATIONS.md`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/docs/REFACTORING_RECOMMENDATIONS.md).

