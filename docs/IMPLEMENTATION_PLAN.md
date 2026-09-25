# StockPiler4 Implementation Plan

This document defines the step-by-step engineering plan for implementing the **StockPiler4** refactor, translating the findings in [`docs/CODE_QUALITY_REVIEW.md`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/docs/CODE_QUALITY_REVIEW.md) and the architectural blueprint in [`docs/REFACTORING_RECOMMENDATIONS.md`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/docs/REFACTORING_RECOMMENDATIONS.md) into actionable phases.

---

## Overview & Guiding Rules

1. **Parallel Safety First:** All files, variables, macros, slash commands, and saved variables use the `StockPiler4` namespace. Existing `StockPiler3` installations remain fully functional and isolated.
2. **Preserve Battle-Tested Code:** Directly import high-value adapters, exception maps, and XML templates from StockPiler3. Do not rewrite solved client quirks.
3. **Strict Unidirectional Flow:** UI renders from read-only snapshots. Executors only execute discrete intents. No domain module may call window handles or mutate snapshots in-place.
4. **Zero Code Duplication:** Consolidate [`UpgradeSeed`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/UpgradeSeed.lua) and [`SkillUp`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/SkillUp.lua) into a unified genus ladder and deficit engine.

```
       Phase 0                   Phase 1                   Phase 2                    Phase 3                   Phase 4                 Phase 5
┌────────────────────┐    ┌────────────────────┐    ┌────────────────────┐    ┌────────────────────┐    ┌────────────────────┐    ┌────────────────────┐
│ Scaffolding &      │───▶│ Knowledge & Ladder │───▶│ Store Integrity &  │───▶│ Pure Planning &    │───▶│ Event-Driven UI &  │───▶│ Verification &     │
│ Isolation          │    │ Consolidation      │    │ Immutability       │    │ Decoupled Execution│    │ Macro Sync         │    │ Acceptance         │
└────────────────────┘    └────────────────────┘    └────────────────────┘    └────────────────────┘    └────────────────────┘    └────────────────────┘
```

---

## Phase 0: Scaffolding & Isolation (Parallel-Safety)

Establish the clean `StockPiler4` workspace alongside `StockPiler3`.

### Step 0.1: Directory Structure & Mod Manifest
Create `Interface/AddOns/StockPiler4/` with the manifest `StockPiler4.mod`:
- **UiMod Name:** `StockPiler4`
- **SavedVariables:** `StockPiler4.Settings` and `StockPiler4.Account` (global)
- **Slash Commands:** Register `/sp4` and `/stockpiler4` (via `LibSlash` with fallback)
- **Window Names:** `StockPiler4Window`, `SP4TabWatchList`, etc.

### Step 0.2: Import Battle-Tested Assets from SP3
Copy unchanged files from `StockPiler3` into `StockPiler4`:
- **Adapters:**
  - `Source/Adapters/ApothecaryAdapter.lua`
  - `Source/Adapters/CultivatorAdapter.lua`
  - `Source/Adapters/VendorAdapter.lua`
  - `Source/Adapters/BagAdapter.lua`
  - `Source/Adapters/TradeSkillCaps.lua`
  - `Source/Adapters/CraftChatAdapter.lua`
- **Knowledge Catalogs & Dictionaries:**
  - `Source/Knowledge/MaterialExceptions.lua`
  - `Source/Knowledge/Classify.lua`
  - `Source/Knowledge/Items.lua`
  - `Source/Knowledge/Additives.lua`
- **View XML:**
  - `Source/View/StockPiler3Templates.xml` → `StockPiler4Templates.xml` (renaming namespace prefix)
  - `Source/View/StockPiler3Tab*.xml` → `StockPiler4Tab*.xml`

### Step 0.3: Centralize Core Utilities
Consolidate repeated local helpers into `Source/Core/Util.lua`:
- Centralize `ToNarrow`, `NowSec`, `consider`, `StageEmpty`, `TryCall`, `TryQuiet`, `T`.
- Ensure all modules consume `StockPiler4.Util` rather than declaring private copies.

---

## Phase 1: Knowledge & Ladder Consolidation

Eliminate the ~6,000-line duplication between [`UpgradeSeed.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/UpgradeSeed.lua) and [`SkillUp.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/SkillUp.lua).

### Step 1.1: Create `Knowledge/GenusLadder.lua`
Extract genus ladder logic into a pure knowledge module:
- Define known plant genera, ladder rungs (1, 25, 50, 75, 100, 125, 150, 175, 200), and skill requirements.
- Port `MergeGenusLadders` to handle split genus naming (e.g., `"Marsh Root"` vs. `"Marshroot"`).
- Provide pure queries:
  - `GenusLadder.GetRung(genus, skillReq)`
  - `GenusLadder.BestOwnedRung(genus, cultFloor, inventoryCounts)`
  - `GenusLadder.VendorRung(genus)` (identifies L1 seed)

### Step 1.2: Consolidate TradeSkill Floor Calculation
- Move `FloorCultTier(cultSkill)` and `FloorApoTier(apoSkill)` directly into `Source/Adapters/TradeSkillCaps.lua`.
- Remove redundant copies from `SkillUp` and `UpgradeSeed`.

### Step 1.3: Add Runtime Invariant Validation to `LearnBridge.lua`
Prevent the SavedVariables corruption documented in [`tools/_repair_climb_links_sv.py`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/tools/_repair_climb_links_sv.py):
- In `LearnBridge.RecordHarvestProduct`:
  - When a harvest produces a plant, verify that its skill level matches the planted seed's tier before linking.
  - If a higher-tier plant is produced via Special Moment or Super-Crit, record it as a *crit product*, but **never** overwrite the canonical seed↔plant link for that higher rung.
- In `BrewLearn`:
  - Enforce a strict filter: if `session.isSkillUp == true`, immediately abort recipe learning so test brews never pollute `Account.recipes`.

---

## Phase 2: Store Integrity & Snapshot Immutability

Ensure stores maintain data integrity and eliminate GC allocations during heavy storms.

### Step 2.1: Fix Table Mutation in `RefinePipelineStore.lua`
Fix the `pairs()` traversal bug identified in [`RefinePipelineStore.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Stores/RefinePipelineStore.lua#L151-L177):
- In `RP.ExpireStuck()`, collect expired keys into a local array `toRemove = {}` during traversal.
- Iterate over `toRemove` after the `pairs()` loop to safely set `RP._outstanding[key] = nil`.
- Standardize entries in `RP._outstanding`: store objects with consistent shape `{ count = N, at = T, plantUid = P }` instead of mixing scalar numbers and tables.

### Step 2.2: Zero-Allocation Bag Snapshot (`InventoryStore.lua`)
Eliminate GC pressure in `InventoryStore.RebuildFromBags`:
- Pre-allocate static tables:
  ```lua
  local STATIC_COUNTS = {}
  local STATIC_SLOTS = { main = {}, craft = {} }
  local STATIC_ITEMS = { main = {}, craft = {} }
  ```
- Use `wipe(STATIC_COUNTS)` (or table-clearing loop) instead of creating `{}` on every bag update.
- Eliminates multi-megabyte garbage collection spikes during harvest storms.

### Step 2.3: Enforce Read-Only `PlanSnapshot`
- Audit all calls to `PlanSnapshot.Get()`.
- Remove lines in [`Brew.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Brew.lua#L1981) and [`Buy.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Buy.lua#L630) that call `Planner.PatchWatchRowsLiveCounts(plan.rows, ...)`.
- When crafts or purchases occur, executors only modify inventory counts and signal dirty state; the Planner rebuilds or garden-patches rows on the next scheduled frame.

### Step 2.4: Eliminate Frame Slicing (`FrameWork.lua`) & Adopt Storm Debouncing
- Remove `FrameWork.lua` prewarm jobs (`prewarm-warm-have`, `prewarm-demand`, `prewarm-seed-lines`) from the core loop.
- Implement single-pass bag indexing in `InventoryStore.lua`: categorize items by role and tier into indexed lookup tables (`Inventory.ByRole[role][tier] = count`).
- In `Planner.lua`, evaluate recipe material demands synchronously against indexed lookup tables in < 1.5ms.
- In `Scheduler.lua`, strip out `FW.IsPrewarmBusy()` holds, `_pendingPrewarmAfterQuiet`, and all 15+ suppression flags.
- Implement a simple 50ms storm debounce timer: when multiple bag update events fire during a harvest or plant storm, debounce them and run the 1.5ms plan update once.

---


## Phase 3: Pure Planning & Decoupled Execution

Move all planning decisions into `Planner` and turn `Grow`, `Brew`, and `Buy` into lean executors.

### Step 3.1: Move Candidate Selection from `Grow.lua` into `Planner`
- Relocate [`PickPlantCandidate`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Grow.lua#L1523) and deficit prioritization from `Grow.lua` into `Planner/PlantPlan.lua`.
- The Planner computes the exact action required:
  ```lua
  Plan.plantIntent = {
      seedUid = bestSeedUid,
      plotNum = targetPlot,
      reason = "watch_deficit" -- or "upgrade_climb", "buffer_fill"
  }
  ```
- Remove Planner shims from [`RecipeSpec.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Knowledge/RecipeSpec.lua#L2472-L2536). Callers query `Planner` directly.

### Step 3.2: Simplify `Grow.lua` into a Pure Executor
- Strip `Grow.lua` down to its core execution responsibilities:
  - `Grow.ExecutePlant(plantIntent)`: validates slot empty, calls `CultivatorAdapter.PlantSeed`, registers pending state.
  - `Grow.ExecuteAdditive(additiveIntent)`: calls `CultivatorAdapter.AddAdditive`.
  - `Grow.ExecuteHarvest(plotNum)`: calls `CultivatorAdapter.HarvestPlot`.
- Eliminate duplicate state flags (`_plantQueueDirty`, `_plantJobProbed`) in favor of reacting directly to `PlanSnapshot.plantIntent`.

### Step 3.3: Consolidate `Orchestrator._TickBody`
Refactor the triplicated planting logic in [`Orchestrator.lua`](file:///c:/Games/Return%20of%20Reckoning/Interface/AddOns/StockPiler3/Source/Core/Orchestrator.lua#L328-L577):
- Replace the three divergent plant execution blocks with a single helper:
  ```lua
  local function TryExecutePlant(opId)
      local intent = Planner.GetPlantIntent()
      if intent and Grow.CanPlantNow(intent) then
          return Grow.IssuePlant(intent, opId)
      end
      return false
  end
  ```
- Establish a clean tick hierarchy:
  1. If ready plots exist and macro harvest queued → Harvest
  2. If empty plots exist and `plantIntent` valid → Plant
  3. If empty plots exist and `refineIntent` valid → Refine
  4. If vendor open and `buyIntent` valid → Buy
  5. Idle

---

## Phase 4: Event-Driven UI & Macro Decoupling

Completely disconnect domain executors from the presentation layer.

### Step 4.1: Eliminate Direct UI Calls from Domain Modules
- Search and remove all occurrences of `StockPiler3Window.RequestFooterRefresh()` and `Ui.MarkWatchUiDirty()` across:
  - `Grow.lua`
  - `Brew.lua`
  - `Buy.lua`
  - `EngineEventBridge.lua`
  - `Planner.lua`
- Replace them with standard event publications via `EventBus`:
  - `EventBus.Fire(Events.PLAN_UPDATED, plan)`
  - `EventBus.Fire(Events.CRAFT_READY_CHANGED, readiness)`

### Step 4.2: Event-Driven View Refresh (`StockPiler4Window.lua`)
- In `StockPiler4Window.lua`:
  - Subscribe to `Events.PLAN_UPDATED` and `Events.CRAFT_READY_CHANGED`.
  - On event, mark internal window flag `_footerRefreshPending = true`.
  - In `OnUpdate`, if `_footerRefreshPending == true` and not in harvest/plant quiet window, execute `UpdateFooterReadiness()` once per frame budget.

### Step 4.3: Thin View Controllers (`StockPiler4TabWatch.lua`)
- Move business logic (ephemeral row generation for SkillUp and UpgradeSeed) into `Planner`.
- The Watch tab simply renders `PlanSnapshot.Get().rows` directly into the list box, binding icons, labels, and status colors without recalculating deficits.

---

## Phase 5: Verification & Acceptance Testing

Verify performance and gameplay parity against live game scenarios.

### Step 5.1: Hitch & Frame Benchmark
- Install `LibPerf`. Run `/libperf StockPiler4 on 250`.
- Trigger a 4-plot harvest storm and consecutive plant tick.
- **Pass Criteria:** Zero hitch trails above 250ms; frame time remains stable under storm.

### Step 5.2: Multi-Family Upgrade Seed Verification
- Test watch on a high-tier recipe with two climbing genera (e.g., Spumepetal + Fusk).
- **Pass Criteria:**
  - AutoBuy buys only L1 vendor seeds for missing families.
  - Empty plots plant the highest owned rung $\le$ Cult skill.
  - Refine converts harvested plants to seeds without starving the other family's planting.
  - Transitions automatically to `Stocked` when target seeds exist.

### Step 5.3: SkillUp Cult & Apo Progression
- Start with Cultivating 1 and Apothecary 1.
- Enable `Level up Cultivating` and `Level up Apothecary`.
- **Pass Criteria:**
  - Plants advance from tier 1 through 25, 50, etc.
  - Apo brews only when stability is HIGH (`sum > 0`).
  - No `skillUpOrigin` test recipes appear in `Account.recipes` or the Potions tab.

### Step 5.4: Parallel Safety Check
- Run `/sp3` and `/sp4` concurrently in the same game session.
- **Pass Criteria:** Independent window state, distinct macros on hotbar, independent saved variables in `user/settings/GLOBAL/`.

---

## File Disposition Summary

| StockPiler3 File | StockPiler4 Action | Rationale |
| :--- | :---: | :--- |
| `Source/Adapters/*` | **Copy as-is** | Highly stable wrappers for game client APIs |
| `Source/Knowledge/MaterialExceptions.lua` | **Copy as-is** | Accurate game catalog exception data |
| `Source/Knowledge/Classify.lua` | **Copy as-is** | Complete effect and role classification |
| `Source/UpgradeSeed.lua` (2,287 lines) | **Delete & Replace** | Merged into `Knowledge/GenusLadder.lua` + `Planner/ClimbPlan.lua` |
| `Source/SkillUp.lua` (3,872 lines) | **Delete & Replace** | Merged into `Knowledge/GenusLadder.lua` + `Planner/ClimbPlan.lua` |
| `Source/Grow.lua` (2,632 lines) | **Refactor (~500 lines)** | Planning logic moved to Planner; becomes pure executor |
| `Source/Planner/Planner.lua` (4,883 lines) | **Decompose & Pure** | Split into sub-planners; returns immutable action intents |
| `Source/Stores/RefinePipelineStore.lua` | **Bugfix & Retain** | Fix `pairs` table deletion and object shape |
| `Source/Stores/InventoryStore.lua` | **Refactor** | Static table reuse (`wipe`) to eliminate GC allocations |
| `Source/Core/Orchestrator.lua` | **Simplify** | Single plant dispatch; no private-field probing |
| `Source/Core/Scheduler.lua` | **Simplify** | Eliminate redundant suppression layers and timer sprawl |
