# StockPiler3 — Complete Build Prompt

Use this document as the sole **product + performance** specification for a greenfield **StockPiler3** addon for Return of Reckoning (Warhammer Online). It is written for **any** AI-powered build environment that can fetch the public GitHub references below—no local game install sibling folders, no private workspace paths, and no dependency on sibling addons.

## Design mandate (read first)

1. **Performance and responsiveness first.** Frame hitch avoidance during harvest, refine, bag, and vendor storms is the primary success criterion. A feature that “works” but stalls the client fails acceptance.
2. **Core functionality, not SP2 clone.** Deliver the player-facing capabilities in §7 / §9 (watch potions, AutoGrow + seed buffer, refine, harvest, brew, AutoBuy, macros, learned recipes). Do **not** reproduce StockPiler2’s module sprawl, patch-layered caches, or historical workarounds as an architecture template.
3. **Steal the lessons, improve the design.** SP2’s *performance patterns* (§2.1, §6, §18) are hard-won and may be reused, simplified, or improved. SP2 Lua is a behavioral reference for edge cases—not a blueprint to copy. Prefer fewer moving parts when they meet the same hitch contracts.
4. **Reimplement all logic.** Do **not** copy StockPiler / StockPiler2 Lua for Core, Stores, Planner, domain, Executors, Knowledge, Macro, or Persistence.

**Capability baseline (UX contracts):** StockPiler2 **0.4.174** user-facing behavior (README changelog through late 0.4.15x–0.4.174 + this prompt). Match *what the player can do* and *storm-safe behavior*; invent a leaner internal design.

---

## 1. Mission

StockPiler3 is a Cultivation + Apothecary stock-automation addon. Players watch potions (one row per learned recipe fingerprint), set bag stock targets, AutoGrow plots from deficits and a seed buffer, refine plants to seeds when needed, harvest ready plots via footer/macro, brew Ready watches, and AutoBuy craft mats at vendors—without hijacking native craft skills.

**Primary goal:** stay snappy under load. Architecture exists to serve that goal and the core loop above—not to mirror SP2’s folder tree.

---

## 2. References (public only)

Browse **all** of [Talladego’s repositories](https://github.com/Talladego?tab=repositories) for usable RoR patterns, UI/XML idioms, macro/hotbar techniques, event timing, and general client knowledge. Prefer **public** repos in any build environment; private repos only if the builder already has access. Patterns are inspiration—reimplement under StockPiler3 names; do not hard-depend on those addons at runtime.

| Resource | URL | How to use it |
| :--- | :--- | :--- |
| **Talladego org (all repos)** | https://github.com/Talladego?tab=repositories | Index of allowed pattern / RoR-knowledge sources |
| StockPiler (SP1) | https://github.com/Talladego/StockPiler | Historical cult/apo automation; denser UI/work coupling — UX/edge cases only; **do not copy** as architecture |
| StockPiler2 (SP2) | https://github.com/Talladego/StockPiler2 | **UX + hitch contracts** (README changelog); optional View XML; Lua = edge-case / anti-pattern reference — **not** an architecture to re-ship |
| WarTriage | https://github.com/Talladego/WarTriage | Hotbar macro create + appearance sync precedent |
| CustomUIv3 | https://github.com/Talladego/CustomUIv3 | RoR UI layout / window / FrameManager patterns |
| EZGuard | https://github.com/Talladego/EZGuard | Addon scaffolding, events, defensive UI patterns |
| GCDsaver | https://github.com/Talladego/GCDsaver | Combat/GCD / OnUpdate pacing lessons (keep SP3 craft path light) |
| rorplanner3 | https://github.com/Talladego/rorplanner3 | Apothecary / recipe domain knowledge (web tool — not Lua to paste) |
| rorleaderboard | https://github.com/Talladego/rorleaderboard | General RoR data/API familiarity only |
| Stock RoR UI | https://github.com/xyeppp/RoR-Interface | Default `interface/` — templates, skins, `SystemData` / `GameData`, FrameManager; Lua local-order docs |
| GatherButton (macro API) | RoR forums / community addon trees | Same family of `CreateMacro` / `SetMacroData` patterns |
| LibSlash (optional) | CurseForge / community mirrors (`LibSlash`) | Optional `.mod` dependency; register `/sp3` when present; no-LibSlash fallback required |
| LibPerf (optional) | Hitch logger used by SP2 | Optional hitch trail sink; else no-op or minimal in-addon logger (§2.1) |

**Do not assume** a local `Interface/AddOns/…` tree or any Talladego addon is installed next to the build. Fetch from GitHub (or this prompt’s described patterns) and reimplement.

### 2.1 Patterns to reimplement (not “require that addon”)

**ActionBar craft macros (WarTriage / GatherButton / SP1–SP2 family)**

1. Find or create a named macro slot via the game macro APIs (`DataUtils.GetMacros`, `SetMacroData` / equivalent — see stock UI + [WarTriage](https://github.com/Talladego/WarTriage) / GatherButton-style code).
2. Macro body is a `/script Addon.Macro.HarvestClick()` (or Brew) call—**not** a hijack of stock Cultivating / Apothecary skill buttons.
3. Player drags the macro to a hotbar. On activate, run the same prepare/activate path as the window footer.
4. Keep hotbar button icon/enabled state in sync with footer readiness; when gated, use grey tint and/or clear `WindowSetGameActionData` so the bar does not stay lit (SP2: colorful `*_disabled` DDS alone is insufficient—hook `ActionButton.UpdateEnabledState` and force SP3 readiness).
5. On `PLAYER_HOT_BAR_UPDATED` (or equivalent), only re-apply appearance when the Harvest/Brew **slot fingerprint** (slot id + action identity) changed; ignore echoes from your own refresh; coalesce enable sync.
6. Sync macros even when the main window is **closed** (footer readiness + Brew Ready wake — §9.5).

**Optional slash registration**

- If `LibSlash.RegisterWSlashCmd` / `RegisterSlashCmd` exists, register `sp3` and `stockpiler3`.
- Always provide a fallback so the addon still loads and can open via a default keybind or settings entry if LibSlash is absent (match SP2: prefer LibSlash when available).

**Frametime hitch logger (LibPerf preferred; in-addon acceptable)**

- Prefer optional **LibPerf**: register scope `StockPiler3`; enable via `/libperf StockPiler3 on [ms]`. Persist threshold in LibPerf. Floor thresholds at **≥250ms** (client idle floor often ~140–155ms; lower values flood logs).
- If LibPerf is absent: either message and no-op, **or** ship a minimal OnUpdate hitch logger with the same Begin/End/Mark + trail semantics.
- Hold the trail only during real harvest/brew work sections—not idle “op active” flags and not mere `planDue`.
- Empty trail on a hitch usually means engine/DXVK/other UI—not a missing Begin site. Rate-limit empty-trail spike chat (summary still counts).

**FrameWork / frame-slice pattern (SP2 `Core/FrameWork.lua`)**

- Prewarm WarmHave / Demand / seed-lines across frames after storm end / bag flush.
- Fuse Footer refresh after LearnBridge/Scheduler; honor `SkipPlanThisFrame` / `SkipUiThisFrame` / `SkipUiHoldFooter`.
- One StartOnce job per Pump frame; hold PlanRebuild/Orch while prewarm caches lag current snap (capped).

### 2.2 Reuse vs rewrite

- **May study any Talladego public repo** (and private ones if available) for patterns and RoR knowledge; **may copy/adapt** SP2 View XML listed in §8 *if* it saves time (rename `StockPiler2*` → `StockPiler3*`). Prefer rebuilding chrome if a simpler layout still hits §8 contracts.
- **Must rewrite:** all StockPiler3 Lua. Consolidate modules freely when it reduces hitch risk and cognitive load.
- **Do not copy wholesale:** SP1/SP2 Core, Stores, Planner, Grow, Refine, Brew, Buy, Macro, Knowledge, Persistence Lua—or SP2’s accumulation of one-off caches “because SP2 had them.”
- **Do improve:** SP2 performance patterns (§6, FrameWork-style slicing, cheap live Status, O(1) snap work, soft plan invalidate) and any leaner patterns found in other Talladego addons. A smaller design that still passes §15 perf scenarios is preferred.

---

## 3. Priorities

1. **Performance / responsiveness** — §6 doctrine; verify §15 perf scenarios first-class. No storm path may depend on full Demand + Watch rebuild every snap or tick.
2. **Core player loop** — Watch targets, AutoGrow + seed buffer, Refine, Harvest, Brew Ready, AutoBuy, macros, recipe learning (§7 / §9). Match SP2 0.4.174 *capabilities*, not SP2 internals.
3. **Lean architecture** — Clear boundaries (engine I/O vs planning vs UI). Use §5 as **guidance**; merge or omit layers if the hitch contracts stay intact.
4. **Clean product separation** — Distinct folder, `.mod`, saved vars, macro names, slash from SP1/SP2.

---

## 4. Non-goals

- Bank / alt-aware stock targets
- Auction house buying or vendor route planning
- Dedicated Plants tab (raise potion targets instead)
- Idle plant-bag floors without raising potion targets
- Full bulk-refine / craft-queue product
- Export/import watch presets
- Finer scenario/combat pause policies beyond Watch **Combat pause** + Flatten/plan deferral
- Migrating SP1/SP2 saved variables (fresh Account; relearn in-game)
- Depending on LibPerf or any non-listed third-party addon for **core** function (LibPerf hitch logs are optional)
- Secondary language packs beyond enUS (scaffold + `T()` must exist; other packs may fall back per key)
- **Cloning SP2’s design weight** — do not re-create SP2’s patch-layered module count, duplicate Demand entry points, or “invalidate everything” habits for parity theater
- **Feature parity with every SP2 diagnostic quirk** — keep `/sp3` dumps useful; skip half-wired UI (e.g. known-recipe filter: implement fully or omit)

---

## 5. Architecture guidance (performance-serving; not a mandatory SP2 clone)

§5 describes **roles and contracts** that SP2 proved useful under storm. StockPiler3 may fold roles into fewer files or rename layers so long as: (a) UI does not drive craft writes, (b) planning stays pure / gen-keyed or equivalent, (c) §6 hitch rules hold.

### 5.1 Lessons from SP1 → SP2 (keep the lessons, not the bulk)

SP1 mixed UI, planning, and craft work → craft/UI stalls. SP2 separated adapters, gen-keyed stores, a pure planner, domain intents, executors, and one orchestrated tick—then piled on coalescing, deferral, FrameWork prewarm, and cheap/GardenPatch paths to recover from earlier cost. **StockPiler3 should start from the separation that prevents stalls, then implement the cheapest correct storm paths**—not port every SP2 mitigation as a separate subsystem.
### 5.2 Layer diagram

```text
Engine events
    → EngineEventBridge
        → EventBus
            → Stores (generation counters, dirty flags)
                → Orchestrator (phases + paced tick + job priority)
                    → Planner.Build (pure, gen-keyed cache; cheap/GardenPatch paths)
                    → Domain (Grow / Refine / Brew / Buy intents)
                    → Executors (issue actions; pending discipline)
                        → Adapters (Cultivator / Apothecary / Bag / Vendor / CraftChat)
                    → View (snapshots only; coalesced flush; live Status patch)
Macro (named macros + fingerprint-gated appearance — §2.1)
Persistence (character settings vs account knowledge)
Locale (T(key, tokens); enUS pack)
```

### 5.3 Recommended roles (collapse freely if contracts hold)

These are **responsibilities**, not a required file list. Prefer the smallest set of modules that still enforce the boundaries.

| Role | Responsibility |
| :--- | :--- |
| **Adapters** | Thin wrappers: cultivator, apothecary, bags, vendor, craft chat, trade-skill caps. Cache expensive lookups (e.g. FindSeedSlot). No business rules. |
| **Stores** | Inventory, Garden, RefinePipeline, Knowledge, Watch, PlanSnapshot (or equivalent gens/dirty). Soft Invalidate vs Clear (§5.11). |
| **Planner** | Pure plan from store snapshots; gen-keyed cache; no engine writes. Cheap / garden-only paths when possible. Serve last good snapshot while UI coalesce pending. Demand/have caches live with planning—not Knowledge. |
| **Domain** | Grow, Refine, Brew, Buy — *what* to do (may live in fewer files). |
| **Executors** | *How* — plant, refine uses, brew load/perform, vendor buy; **sole** auto plant/additive/brew engine-write path. |
| **Tick / schedule / frame-slice** | Phase FSM; paced tick; plant→additives→refine→buy; fillBlocked; harvest storm; scenario defer; frame-slice prewarm (SP2 FrameWork lessons). |
| **View** | Snapshots only. Never drives refine/grow from list rebuilds. Live Stock/Status overlay without full Build. Closed-window Status patch for macro Ready (§9.5). |
| **Macro** | §2.1 pattern; enable with footer; sync when window closed. |
| **Persistence** | Character settings + account knowledge. |
| **Locale** | `T(key, tokens)` + enUS pack. |
| **Core** | Event bus, debug, hitch logger, audit as needed. |

### 5.4 Example folder layout (optional)

Illustrative only—collapse folders if the hitch contracts stay clear:

```text
StockPiler3/
  StockPiler3.mod
  Source/
    Bootstrap.lua
    Core/         EventBus, Scheduler, Orchestrator, EngineEventBridge, Debug, Perf, Audit, FrameWork
    Stores/       Inventory, Garden, RefinePipeline, Knowledge, Watch, PlanSnapshot
    Planner/      Planner.lua, SpecDemand.lua, SpecHaveCache.lua
    Grow/         Grow.lua (readiness + plant/harvest ops; no footer/tooltip chrome)
    Brew/         Brew.lua (session FSM; no footer/tooltip chrome)
    Refine/       Refine.lua
    Buy/          Buy.lua
    Executors/    Grow, Refine, Brew, Buy
    Adapters/     Bag, Cultivator, Apothecary, Vendor, CraftChat, TradeSkillCaps
    Knowledge/    RecipeSpec, SeedMap (+ split only if needed), BrewLearn, LearnBridge,
                  Classify, MaterialSpec, Additives, Items
    Macro/        Macro.lua
    Persistence/  Settings, Character, Account
    Locale/       Locale.lua, enUS.lua
    View/         Window, Templates, TabPotions, TabWatch, Catalog, Ui,
                  HarvestChrome, HarvestTooltip, BrewChrome, BrewTooltip, RecipeTooltip
```

### 5.5 Orchestrator — phases, tick order, fillBlocked

**Phases (expose in `/sp3 state`):** at least `idle`, `planting`, `refining`, `harvesting`, `buying` (emit phase-changed on the bus when changing). Harvesting is typically macro/prepare-only.

**UPDATE_PROCESSED order (conceptual):**

1. Frame counter; flush pending garden sync → plant confirm / harvest-ready latch
2. Coalesced `Inv.ApplySlots` (main + craft, one bag table each)
3. Flush pending inventory snapGen → publish snapshot event
4. LearnBridge drain (harvest complete; may SkipPlan/SkipUi this frame)
5. Refine OnUpdate (frame-gated Reconcile / ExpireStuck)
6. Scheduler: bag flush → FrameWork prewarm → PlanRebuild → Watch UI flush
7. On auto-tick (~1s busy / store-open; ~5s AutoGrow idle): decay plant/refine waits → `Orchestrator.Tick`

**Tick order (when AutoGrow / related work is due):**

1. Plant (one seed) if a plantable job exists and not in plant quiet / fillBlocked / harvest storm for plant
2. Optional stage additives for in-progress plots when enabled
3. Refine intents (buffer / plant-need / resin-need) subject to plant-first rules
4. After failed refine, may re-probe seeds and plant same tick
5. AutoBuy when vendor open and enabled (runs even if AutoGrow is off; also while brew session active)

**Early returns (must not probe BufferFlags / CollectIntents):**

- AutoGrow off → buy only
- fillBlocked with no pending buffer refine → idle + buy
- plant quiet **or** harvest storm → fast ticks, no grow probes
- brew session loading/loaded → skip grow probes; buy allowed
- no AutoGrow work → idle + buy

**fillBlocked:** after plant fail / no-seeds situations, block further **plant** attempts for N ticks (or a short time window). While fillBlocked: still allow **seed-buffer refine** and **AutoBuy**. Do **not** fill-block solely because refine intents are throttle-gated.

**Sticky fillBlocked pitfall (SP2 0.4.163):** do **not** re-arm `SetFillBlocked(true, N)` every idle tick in a way that resets an active wait forever. Extending wait only when `newWait > cur`. Clear fill-block when seed buffer is satisfied (empty plots + full buffer + buy-only shorts must idle cleanly). Do not reset an active fill-block wait on empty refine / no-job.

**Harvest wake:** after harvest, arm harvest storm + plant quiet (quiet ≥ storm floor **1.5s**; base plant delay may be ~0.75s but storm floor wins). Share **one** force plant-queue invalidate across multi-plot wake; do **not** sync `HasSeeds` / Pick on the hitch frame. Do **not** ClearFillBlocked / WakeAutoGrow on every inventory snap (snap-wake storm / freeze risk). Mid-storm / quiet: skip MarkPlantJobDirty and urgent wake on snap.

**AutoGrow commit release:** when a plant commit completes or fails, release commit state promptly so the next tick can proceed—do not leave sticky commits that stall the pipeline. Soil-confirm chat only (no optimistic PlantSeed chat). Stash plant-chat meta across empty-grace clears so late confirms still chat.

**Combat / scenario:** Watch **Combat pause** (default on) defers plant in combat/scenario. Do **not** block AutoGrow solely because `isInRvRLake` (idle lake stay). Flatten/plan deferral in scenario remains. Orch does not fill-block on combat defer.

**Plot unlocks:** respect Cultivation plot unlocks (1/2/3/4 at skill 1/50/100/150); skip Locked plots.

**Harvest batch hold:** do not plant empties while any plot is Grown/ready unless the garden is a staggered (non-uniform) wave; refine/additives still run.

### 5.6 Scheduler

- Coalesce `planDue` / UI dirty into deferred work; do not rebuild plan every bag event while coalesce pending.
- Distinct AutoGrow idle (~5s) vs busy (~1s) tick intervals; **store-open AutoBuy uses ~1s** even if AutoGrow is idle (§9.6).
- Suppress redundant inventory ticks when a Flatten/snap is already scheduled.
- Distinguish **wake** (intentional) vs **snap** (inventory observation)—only wake paths force plant-queue invalidates.
- Defer PlanRebuild while refine outstanding / pending; one rebuild when clear. Defer PlanRebuild mid-brew session (loading/loaded); one rebuild on session clear.
- Soft PlanSnapshot invalidate keeps stale rows; Clear only on character change / first session.

### 5.7 Inventory tier model (L0–L3)

| Tier | Role |
| :--- | :--- |
| **L0** | Fast per-uid count adjust / live seed counts for refine headroom and harvest mat snapshots |
| **L2** | Flatten / aggregated bag view when structure changed |
| **L3** | Full expensive snap — rare |

Prefer L0 on critical paths. Never let a stale L2/L3 sample `stackCount` stomp L0 live trackers used for headroom.

Trust DataUtils dirty-gated `GetItems` / `GetCraftingItems` for L0 slot reads (one bag table per event). `FetchForce` / full Flatten only for session load or true desync — not refine-expire or soft dirty.

Coalesce ApplySlots (main + craft) once per UPDATE_PROCESSED. Zero-net L0 rearranges must not bump snapGen. When craft bag is full, harvest/refine learning and brew load must also see CRAFTING mats overflowed into inventory.

### 5.8 Planner gen cache

Cache key includes at least: `gardenGen + refinePipelineGen + watchGen + knowledgeGen` (+ inventory gen as needed). Invalidate only when gens change. While UI coalesce pending, return last built plan.

**Build paths (prefer cheapest):**

1. **Cheap rebuild** — structural gens unchanged (gardenPlanGen, watchGen, knowledgeGen, settingsHash); snap/refine changed: patch live counts; keep statusTipSlots; seed-buffer tip via PeekCachedIntents only (no CollectIntents in Build); skip Demand/Status/Tips.
2. **GardenPatch** — recipe-structural gens match: reuse tips, flip restocking, live potion counts, cacheOnly growing notes; no Tips.Slots / Demand.
3. **Full Build** — Demand + Status + Tips.

`Planner.Build` / `BuildBalancedSpecDemand`: one snapGen-keyed `WarmSpecHaveCache` bag pass (CountByUid for incomplete+boundUid specs); do not clear `_specHaveCache` twice or walk the bag once per ingredient spec. Empty have-cache table ≠ warm (require warmed-for-snap flag). Do not pre-zero craftable during brew load WarmHave.

Nested Build sections: `Build.WarmHave`, `Build.Demand`, `Build.Status`, `Build.Tips` (Status.Craftable then Tips). Plan-cache `IsHarvestByproduct`. Build all `RecipeSlotPlanEntry` once per deficit row (status + tipSlots share). Memo `CountCraftsPossible` per recipe key within a Build (non-reserve).

**Live Status overlay** (`PatchWatchRowsLiveCounts` / `ApplyLiveWatchStatus`): update Stock, deficit, statusKey/statusText without Demand rebuild. Skip WarmHave / craftable recount when refine outstanding, brew session, or closed-window sync. Must demote/promote:

| Transition | Rule |
| :--- | :--- |
| Ready → Restocking / Seed buffer | when `have + craftable < target` |
| Potions stocked → materials short | when bag potions removed (vault/mail/bank) while Stock live-patched to 0 |
| Seed buffer → Ready / Restocking | when buffer fills; dirty plant job |
| Restocking ↔ Seed buffer | buffer short flip |
| Container-only short | **Buy flasks**, not Restocking |
| `buy_ingredients` → Ready | live-flippable when craftable covers (Warm SpecHave / container CountByUid only) |

### 5.9 EventBus (illustrative catalog)

Publish/subscribe names such as: inventory dirty/snapshot, garden dirty/snapshot, plan invalidated/updated, phase changed, session loaded, knowledge updated, CMD_HARVEST, CMD_BREW_*, refine outstanding updates. Soften garden dirty so plot noise does not force full rebuilds every frame.

Subscribe returns tokens; Shutdown must Unsubscribe (no duplicate handlers on reload).

### 5.10 Knowledge learning

- **BrewLearn:** brewing a potion once stores recipe slot layout on Account. Recipe key includes main/container/extras (+ optional output uid). Migrate recipeKey versions as needed. Relink potion recipeKeys after StoreLearnedRecipeSpec so alternate/potent fingerprints appear without `/reload`.
- **Composite potion/watch identity:** `uid:<outputUid>|rk:<recipeSpecKey>` — one Potions/Watch row per fingerprint, not per output uid alone.
- **SeedMap / LearnBridge:** seed↔plant maps from plant/harvest/refine observations; learn/snapshot only on real harvest **complete** attempts. Split internal modules (Core / Observe / Resolve / Maintenance) behind a stable SeedMap facade.
- **Knowledge.Touch:** bump knowledgeGen only on **structural** change — new/remapped brew recipes, new seed pairs, new vendor/additive rows, forget. Not on identical re-learn or brew counter-only updates.
- **MaterialSpec:** material roles (main, stabilizer, extender, multiplier/stimulant, container, ingredient) + fingerprint matching for bag/vendor/brew load.
- **Classify / Additives / Items:** supporting catalogs. Items.ToSpec for learned plants (bag AsItemData often lacks craftingBonus).
- **One-way / Liniment-class mains:** some harvest products are not plant→seed refinable; AutoGrow still plants/learns them without expecting refine (skill- and recipe-aware). Skip one-way harvest specs in seed-buffer lines. Classify early via item description (`very special ingredient` / create Liniment|hybrid) plus curated uids (waremu GraphQL probe: `tools/waremu_special_mats_probe.py`). Sticky `forceNotRefinable` on store/harvest.
- **Purple liniment seeds:** Eternal (permanent, never consumed) and Exceptional/charged (~250 grows) keep a bag stack while planting — credit a full plot wave while owned; prefer Eternal ≫ Exceptional ≫ blue when several seeds match. Strip Eternal/Exceptional/Bunched/Bloodseed name prefixes for Bloodseed↔Powder (and Bunched harvest) relatedness.
- **Infertile hybrid seeds:** one-shot blues (`infertile for sustainable regrowth`, uids 2017641–2017652) — bag-count credit only (never opaque); harvest products forced one-way / not refinable.
- **Butcher substitutes (SP2 0.4.164):** cultivation linkage wins over bag ProductMatches + recipe butcher uid. Plant uid resolve skips butcher substitutes; seed match uses learned Items.ToSpec. Never mark cult mains `not-growable` solely because a butcher substitute once filled the same ProductKey. Daemonic/Khornish organs count as butcher-like (non-growable without a seed).
- **False refinable / SeedMap pollution:** fast-fail failed converts (~1.5s), session cooldown (not permanent blacklist of proven converts); Special Squig Bits-class stays blocked. Ignore unrelated grows when matching; PrimaryPlant never returns unrelated products; vendor Seed Packets excluded from PickBestSeedUid / refine seedUid.
- **Resin-need:** convert surplus recipe plants (highest stock) for Arboreal Resin when stabilizer short; skill-tier match 1:1; ignore seed-buffer headroom for resin intents.

### 5.11 PlanSnapshot soft Invalidate vs Clear

| API | Effect |
| :--- | :--- |
| **Invalidate** | Drop cache key; **keep** stale plan for cheap/GardenPatch / GetOrBuild(refresh=false) |
| **Clear** | Drop plan entirely — character change / first session only |
| Mid-session LOADING_END | Soft Invalidate; Clear only on char key change |

`GetOrBuild(refresh=false)` must never sync-build while plan pending.

---

## 6. Performance doctrine (highest priority)

Normative. Violating these fails acceptance even if features “work.” These are the **portable SP2 lessons**—implement them with the simplest durable design you can; improve costs further when safe.

Treat named SP2 helpers (`HasAnyBufferShort`, `WarmHave`, `FrameWork`, …) as **concept labels**. Reimplement the *behavior*; do not require the same function names or module boundaries.
1. **UI deferral during craft-critical ops** — No Watch list rebuild / full RefreshWatch during refine outstanding, buffer refine, AutoBuy visit, or harvest critical windows; coalesced flush after. Mid-brew: hold Watch paint except Load/Brew chrome (allow ~1s Status/Stock catch-up while apo open).
2. **Coalesced UI flush** — List repopulate and expensive labels through one deferred path. Open-window content key must include `knowledgeGen` (not only inventory/plan) so newly learned alternate recipe rows appear without reload. Include brew phase so Load/Brew chips track session. Bypass interval on knowledgeGen / planGen / brew chrome change.
3. **Planner deferral** — No rebuild on every bag tick while coalesce pending; defer Flatten/plan while in scenario; defer mid-refine / mid-brew as in §5.6.
4. **Reconcile / walk cost** — Early-out; walk only outstanding seeds / dirty keys.
5. **Live counts over stale samples** — Seed budget / refine headroom prefer live uid (L0); never stomp live trackers with sample stacks alone. GetSeedBudget must not write reconcile baselines.
6. **Pending discipline** — No same-tick pending-throttle clear + IssueOne retry (burst overshoot). Expire path clears stuck pending. Orphan pending-by-plant when outstanding already 0.
7. **Macro appearance storms** — Fingerprint gate; ignore self-refresh echoes; coalesce enable sync; short-circuit appearance work before opening Perf sections when unchanged; do not wipe dirty-reentry keys in a way that retriggers storms.
8. **Harvest path cost** — Learn/snapshot only on complete attempts; L0 / craft-bag-scoped snaps; nested perf sections for Snapshot vs Complete; LearnBridge work must not pull Refine into the harvest trail. Skip Ui one frame after Complete (avoid Complete+UiFlush fusion).
9. **AutoBuy batching** — No per-purchase Flatten/plan/jobs invalidate; batch after visit. Arm one coalesced PlanRebuild when buy jobs go idle after buys (or visit stop with buys) so Status leaves Buy flasks without `/sp3 watchplan`.
10. **Post-harvest plant quiet** — quiet ≥ harvest storm floor (~1.5s). Orch returns before HasAutoGrowWork during storm/quiet (no BufferFlags probe).
11. **Attribution honesty** — Empty-trail hitches ≈ engine/DXVK/other UI; do not spray Begin to “fix.” Rate-limit empty-trail spike uilog (keep summary counts); low thresholds must not flood every frame. Floor ≥250ms when using LibPerf.
12. **Critical-path budget** — No large allocations, full catalog rebuilds, or all-watch walks on harvest complete / IssueOne / vendor buy.
13. **P1–P4 wake debounce** — One force plant-queue invalidate across multi-plot harvest wake, not one per plot event.
14. **No snap-wake storm** — Do not WakeAutoGrow / ClearFillBlocked on every inventory snap. Snap MarkPlantJobDirty only when AutoGrow has empty plot / additive / buffer work.
15. **Lookup caches** — Cache FindSeedSlot and seed-line lookups; invalidate on real bag structure changes. Seed-line / buffer / plant-job caches key on garden planGen (not stage ticks). Drop snapGen from IntentCacheKey and seed-line cache keys (reuse mid-refine).
16. **Softer garden dirty** — Do not treat every plot pulse as a full UI/plan invalidate.
17. **Trail hold policy** — Hold hitch trail during real harvest/brew sections only; exclude idle harvest-op flags and mere `planDue`. No trail-hold for entire brew session idle.
18. **AutoGrow commit release** — Release sticky plant commits promptly (see §5.5).
19. **DataUtils L0 trust** — Slot events read one warm bag table; no FetchForce on hot paths (see §5.7).
20. **One-pass spec-have** — Planner/demand have-counts via snapGen-keyed `WarmSpecHaveCache` (see §5.8), not N× `ForEachItem` per unique ingredient spec.
21. **Brew coalesce** — No trail-hold for brew session; coalesce `SnapshotPotionCounts`; brew in Watch fill-burst; invalidate + `EnqueuePlanRebuild` (never sync force Build after brew).
22. **O(1) inventory snap invalidate (0.4.173)** — On snapshot when buffer enabled + urgent (refine dirty / outstanding / empty plots): InvalidateIntentCache + clear refine wait. **Do not** call `HasAnyBufferShort` / rebuild BufferFlags / Demand on every snap.
23. **WarmHave skip while refine outstanding (0.4.173)** — Watch live-count patch uses `allowWarmHave=false` while RefinePipeline has outstanding.
24. **Settings soft paths** — Reserve/Budget chips: no BumpWatch/PlanRebuild. Additives/AutoBuy toggles: skip plan invalidate where safe. Seed buffer + AutoGrow: Bump + prewarm + coalesced PlanRebuild (no sync Refresh). Target chip stocked↔stocked noop: optimistic paint only (§9.1).
25. **Tooltip hover cost** — Status / seed-buffer tips are plan-snapshot + live Have overlays only; `cacheOnly` GrowingNotes / CountItemsMatchingSpec; never ResolveSeed bag-walks or mutate plan tip payloads on hover; PeekCachedIntents only (no CollectIntents in Build or hover).
26. **Live Watch seed-buffer short** — `PatchWatchRowsLiveCounts` / Status flip must not pay `ResolveSeedForSpec` / `FindPlantUidForSpec`. Prefer plan tip `seedUid`s / `row.seedBufferSeedUids` + `GetSeedBudget(seedUid)`; ResolveSeed only on cold miss (GitHub #2).
26. **MaterialSpec parse cache** — Key by uid (not item table identity); clear on inventory snap; expose `/sp3 mem` for safe counts — never `d(Addon)` (EA debug walks full bag tables and can freeze/disconnect).

**Minimal Perf/Debug surface:** hitch logger + trail (LibPerf or in-addon); plan/state/grow/brew/buy/stats/mem dumps; debug uilog. Persist hitch threshold (≥250ms recommended).

---

## 7. Product features

### 7.1 Packaging

- Addon folder `StockPiler3`, parallel-safe with StockPiler and StockPiler2 if those are also installed.
- Slash: `/sp3` (LibSlash when available — §2.1).
- Macros: **StockPiler3 Harvest**, **StockPiler3 Brew**. Ignore names `StockPiler Harvest` / `StockPiler Brew` / `StockPiler2 Harvest` / `StockPiler2 Brew`.
- Dependencies: EASystem_Utils, EASystem_WindowUtils, EATemplate_DefaultWindowSkin, EA_SettingsWindow, EA_ChatWindow, EASystem_Tooltips, EA_ActionBars; LibSlash optional; LibPerf optional.
- Category: CRAFTING.

### 7.2 Window and tabs

- **Potions** — learned catalog; name search; effect filter; sort columns; rarity-colored names; one row per recipe fingerprint; live refresh on knowledge gen; watch; forget; recipe/icon tooltips. Columns (§8): Watch, Name, Lvl, Effect, Pwr, Stab, Mult, SCrit, Yield, Stock, Recipe, Forget.
- **Watch** — master AutoGrow, additives, Combat pause, seed buffer enable + min chip, AutoBuy + reserve/budget; leftmost **Prio** chip (shared tiers `1..N`, N = enabled Watch-list rows; AutoGrow-off still counts/editable), Name (rarity colors via `DataUtils.GetItemRarityColor`), Status / Stock / Craftable / Target / AutoGrow / Brew. AutoGrow column header reads AutoGrow (not “Priority”).
- **Footer** — Clear watches (Potions tab); Harvest + Brew (Watch tab); live tooltips that update while hovered when readiness changes.
- **Skill gates** — AutoGrow / additives / seed buffer / Combat pause / row AutoGrow → Cultivation; Brew → Apothecary; AutoBuy → Cultivation **or** Apothecary. Tooltips explain gated state. Re-apply after SESSION_LOADED / window show (tradeSkills often missing at CreateWindow Initialize).

### 7.3 Automation

- AutoGrow, Refine (buffer / plant-need / resin-need), Harvest (manual), Brew (footer vs row), AutoBuy — see §9.

### 7.4 Knowledge

- Empty Account on install; brew once for slots; harvest/refine for seed maps; one-way mains without refine (§5.10).

### 7.5 Slash commands

| Command | Behavior |
| :--- | :--- |
| `/sp3` | Toggle main window |
| `/sp3 potions` / `watch` | Open on tab |
| `/sp3 help` | Command list |
| `/sp3 debug` / `on` / `off` | Structured uilog |
| `/sp3 plan` | Planner dump |
| `/sp3 watchplan` | Watch status / stock / craftable / shared |
| `/sp3 state` | Phase + store generations |
| `/sp3 growplan` | Garden / grow / refine diagnostics |
| `/sp3 brewplan` | Brew session + ready watches |
| `/sp3 buyplan` | Buy jobs |
| `/sp3 stats` | Craft-cycle stats (plant/harvest/crit/SM, refine, brew rates) |
| `/sp3 bags` / `bags force` | Bag snapshot |
| `/sp3 events` / `on` / `off` / `dump` | Event bus trace |
| `/sp3 mem` | Safe table key counts only (never dump full addon table) |
| `/libperf StockPiler3 …` | Hitch logger when LibPerf present; else document in-addon `/sp3 perf` equivalent |
| `/sp3 audit` | Saved-variables health (unexpected Account top-level keys) |
| `/sp3 harvest` | Prepare next ready plot |

---

## 8. UI specification + reuse whitelist

### 8.1 Whitelist (fetch from SP2 GitHub)

From https://github.com/Talladego/StockPiler2 (clone the repo or download these paths):

- `Source/View/StockPiler2Window.xml`
- `Source/View/StockPiler2TabPotions.xml`
- `Source/View/StockPiler2TabWatch.xml`
- `Source/View/StockPiler2Templates.xml`
- Any textures shipped under that addon, if present

Rename `StockPiler2*` → `StockPiler3*`. Rewrite all View Lua. If XML cannot be fetched, rebuild from the window tree + interaction tables below using stock skins from https://github.com/xyeppp/RoR-Interface.

**Note:** SP2 Templates.xml comments may lag column order — trust §8.2 / TabPotions.xml (includes Level + Multiplier).

### 8.2 Window tree map

```text
StockPiler3Window (movable, savesettings)
├─ Background, TitleBar, WindowImage, Close
├─ ButtonBackground
├─ TabButtons → Potions (id=1), Watch (id=2)
├─ WindowSocket
├─ TabPotions
│  ├─ Banner
│  ├─ SearchBox, EffectCombo [, FilterKnownRecipe — optional; see §8.5]
│  ├─ Sort headers: Watch | Name | Lvl | Effect | Pwr | Stab | Mult | SCrit | Yield | Stock | Recipe | Forget
│  └─ List → PotionRow { Watch, Icon, Name, Level, Effect, Power, Stability, Multiplier, SuperCrit, Yield, Have, Recipe, Forget }
├─ TabWatch
│  ├─ Banner
│  ├─ Enable AutoGrow, Additives, Combat pause
│  ├─ SeedBufferEnable, SeedBufferChip (min 4–20)
│  ├─ AutoBuy, ReserveChip (1–99), BudgetChip (1–999)
│  ├─ Column headers (Prio, Name, Status, Stock, Craftable, Target, AutoGrow, Brew)
│  └─ List → WatchRow { PrioChip, Icon, Name, Status, Stock, Craftable, TargetChip, AutoGrow, Load }
└─ ClearWatches (Potions), Harvest (gameactionbutton), Brew (Watch)
```

### 8.3 Potions columns (normative)

| Column | Header label | Sort key | Data | Notes |
| :--- | :--- | :--- | :--- | :--- |
| Watch | (eye checkbox) | `watch` | watched | Toggle watch; EnsureWatch defaults |
| Name | Name | `name` | name + rarity RGB | `DataUtils.GetItemRarityColor` |
| Lvl | Lvl | `level` | levelText / rankNum | From Classify / item; dash if unknown |
| Effect | Effect | `effect` | effectText | Short effect labels |
| Pwr | Pwr | `power` | signed power | **Recipe fingerprint** stat |
| Stab | Stab | `stability` | signed stability | Fingerprint |
| Mult | Mult | `multiplier` | signed multiplier | Fingerprint (0.4.174); between Stab and SCrit |
| SCrit | SCrit | `superCrit` | percent | Fingerprint; 0 → dash |
| Yield | Yield | `yield` | observed yield | Dash if ≤0 |
| Stock | Stock | `have` | bag have | Always white text |
| Recipe | Recipe | — | hasRecipe | Hover → recipe tooltip |
| Forget | Forget | — | — | Confirm; unlink this fingerprint |

**Fingerprint vs icon tip:** Pwr/Stab/Mult/SCrit/Yield come from `RecipeFingerprintStats` (slot bonus sums + observed yield). Effect/rank/buff/duration live on the **icon tooltip**, not as separate list columns beyond Effect/Lvl.

**Row identity:** `uid:<outputUid>|rk:<recipeSpecKey>`.

**Forget:** unlink this potion from its learned recipe; if other potions still share that recipe, keep the shared recipe data.

### 8.4 Watch columns + status keys

| Column | Behavior |
| :--- | :--- |
| Potion | Icon + rarity-colored Name |
| Status | Colored label + hover tip (plan snapshot slots + live Have) |
| Stock | Traffic light vs target; live-patched |
| Craftable | Green = buffer-safe brew (`craftable > 0`, seed cushion met); yellow = craftable but buffer short; red = zero. Shared mats do not force yellow (Status may still be Ready-shared). |
| Target | Chip ±1 (Shift ±10), max 200; L enables watch |
| Prio | Leftmost click-chip; L+/R− (Shift ±10); range 1..N (N = enabled list) |
| AutoGrow | Per-row checkbox; Cultivation-gated |
| Brew | Idle → Load → Brew; R-click unload |

**statusKey → display (enUS `plan.status.*`):**

| statusKey | Typical text | Color |
| :--- | :--- | :--- |
| `no_target` | Set target | gray |
| `no_recipe` | Learn recipe | red |
| `potion_stocked` | Potions stocked | green |
| `ready_to_craft` | Ready to brew | green |
| `ready_to_craft_shared` | Shared materials | yellow |
| `restocking` | Restocking materials / Refine plants / Refine for resin | yellow |
| `need_seeds` | Seed buffer | yellow |
| `enable_autogrow` | Enable AutoGrow | red |
| `need_apothecary` / `need_skill` | Need Apo / skill levels | red |
| `buy_ingredients` | Buy flasks / seeds / materials / plants / seed or mat | red |

**Tip notes — Buy seeds vs refinable plants:**

- Growable short with seedUid and seedCredit ≤ 0 → **Buy seeds** (yellow) when notes empty — matches Seed buffer / restocking, not red buy.
- Prefer Refine / Seed buffer status over Buy seeds when refinable plants remain.
- True buy (containers / butcher / vendor-only) → red Buy flasks/materials.
- Contested Shared-materials slots: **(Shared)** not **(Stocked)**. **(Pooled)** = grow demand across watches.
- Byproduct stabilizer with **no plant feedstock** → red, not yellow.
- Skip “Restocking materials” status when seed lines are empty.
- Stocked AutoGrow watches with seed lines below buffer → yellow Seed buffer (not green Potions stocked while Brew held).
- Red Buy flasks for Shared contest only when every contested key is non-growable; if plants/buffer still contested, stay yellow Shared.

**Seed Buffer tooltip:** recipe/restocking layout with dashed separators; green material headers; yellow detail; traffic-light SHORT / partial / OK for buffer lines; live Have patch; planned refine section from PeekCachedIntents; never write back into plan tip data.

**Row paint cache:** skip repaint unless icon/name/status/stock/craftable/target/autogrow/brewState change. Hide unused ListBox visiblerows (no ghost checkboxes / white bars).

**Empty plan:** if plan pending/nil but enabled watches exist, keep previous rows + live patch (do not blank the list).

### 8.5 Interaction spec

| Control | Behavior |
| :--- | :--- |
| Tabs | Switch; persist `selectedTab` |
| Potion Watch | Toggle watch for recipe key; BumpGen + coalesced plan (optimistic local list ok) |
| Potion Forget | Confirm; unlink fingerprint; chat |
| Sort / Search / Effect | Filter/sort; persist. Effect cycle ~27 short keys |
| Known-recipe filter | SP2 persists `potionKnownRecipeOnly` but hides the checkbox and does not apply it — **either implement fully or omit** |
| Watch Enable / Additives / Combat pause / Seed buffer / AutoBuy | Toggles + chips; skill-gated; chat on settings change. Soft invalidate paths per §6.24 |
| Row Prio / Target / AutoGrow / Load | Prio L/R; Target L/R; AutoGrow flag; Load Idle→Load→Brew, R clears (1.5s board adopt block after R-clear) |
| Target stocked↔stocked | Optimistic row + PlanSnapshot patch only — no BumpGen/PlanRebuild |
| Footer Brew / Harvest | §9.4–9.5; live tooltip ticks while hovered |
| Clear watches | Clear all character watches (confirm) |
| Session load + window open | Force bag/plan + active-tab refresh so stock/craftable/status are not stale until a tab flip |

### 8.6 Traffic lights (summary)

- **Green** — stocked or uncontested Ready; Craftable buffer-safe (`craftable > 0`, seed cushion met)
- **Yellow** — Ready-shared; restocking; need seeds / buffer; Craftable > 0 but buffer short
- **Red** — no recipe; enable AutoGrow; need Apo/skill; buy ingredients; byproduct stabilizer with no feedstock; Craftable zero

---

## 9. Behavior contracts

### 9.1 Watch / shared materials

- Deficit = `max(0, targetStock − bag stock)` per enabled watch.
- **Priority tiers:** each enabled Watch-list row has `priorityTier` in `1..N` where **N = enabled list count** (AutoGrow-off still on the list, still has a Prio chip, still counts in N). Defaults unique by enable/add order; legacy saves migrate once to unique `1..N` by name. Shared tiers allowed after manual chip edits. When a watch leaves the list and its tier becomes empty, densify higher tiers down (holes collapse). List sorts tier asc, then name.
- Stocked watches do not join shared-mat contention.
- Contested craftable uses crafts **needed for deficit**, not max bag crafts.
- Green Ready vs yellow Ready-shared as in §8.4–8.6 (Status only). Craftable **color** ignores shared: both watches may show green counts over the same bags; brewing one recounts both.
- AutoGrow keeps filling contested shared plants until Status can leave Ready-shared.
- **Water-fill of Craftable/Stock (watch layer):** among AutoGrow-armed watches that still need work, take the **best (min) priority tier**, then bottle gap = `max(0, Target − Stock − Craftable)` within that band — prefer largest gap (starve-first). Same focus rule for AutoBuy. Fallback to pooled shorts when focus has nothing actionable (buyable non-growables only; skip shared containers).
- Live Status overlays must work without `/sp3 watchplan` (§5.8).

### 9.2 AutoGrow

- Master on + Cultivation; one seed per tick; plant-first before refine when a plantable job exists.
- **Plant pick (accepted fairness rule — not classic min-deficit round-robin):**
  1. Build pooled growable demand across AutoGrow watches (`craftsShort` per spec).
  2. **Focus** = AutoGrow-armed watches needing work at the **min priority tier**, then at `maxBottleGap` within that band (§9.1). Restrict candidates to those recipes’ specs when plantable.
  3. **Plant watch order** matches focus: priority tier asc, then max `bottleGap`, then lowest craftable, then deficit (not deficit-only uid sort).
  4. Among focus candidates, score: **unique limiting bottlenecks first** (spec is a limiting slot for a focus recipe; prefer low share across focus watches so shared Goldweed/Gobswort does not starve unique recipes), then **maximize** `craftsShort`, then plot fairness / role order (main → stabilizer/goldweed → extender → multiplier/stimulant → …), then avoid last-planted seedUid.
  5. If a higher-priority (lower tier / larger gap) watch returns `no-seed`, **fall back** to the next watch. Do **not** idle empty plots when another watch has plantable seeds.
  6. `refine-first` still blocks lower watches (plants exist to convert for that watch — wait for refine).
  7. Else seed-buffer grow, then surplus grow (buffer on).
- SP2 does **not** water-fill every pooled material evenly (it does not always plant the globally shortest material deficit). SP3 must keep **watch priority + water-fill + shared-mat uniqueness fairness**; scoring may be simplified if hitch contracts hold.
- **SHORT surplus block:** when buffer is SHORT for a seed, do not surplus-grow that seed. Also block surplus while buffer refine pending.
- **Must not** buffer-grow while refinable plants for that seed remain.
- **PotionStockNeedsRefineFirst:** when deficit exists, zero plantable seeds, but refinable plants remain → defer buffer/surplus plant so refine unblocks Shared/yellow watches.
- Buffer credit = bag + in-ground + outstanding (no uproot). Eternal/Exceptional opaque credit = full plot wave while owned.
- Post-harvest quiet ≥ storm floor (~1.5s).
- Skill skip for seeds the character cannot use; respect plot unlocks.
- Optional additives; no plant while brew session loading/crafting.
- One-way / Liniment-class: plant/learn without expecting plant→seed refine (§5.10).
- Combat pause (default on): defer plant in combat/scenario — not lake-only.

### 9.3 Refine

**BufferFlags** (cache; align with CollectIntents):

- Key includes snapGen / gardenPlanGen / watchGen / bufferMin / outstandingSum (structural half reusable mid-refine when garden full).
- `pending` = any line with convertible plants; `short` = credit < bufferMin.
- `IsSeedBufferSatisfied` = not short AND not pending.

**CollectIntents:**

1. Seed-buffer intents (if buffer on): convert up to headroom; batch ≤ ~5; reason `seed-buffer`. Prefer true surplus plants above brew need; **bootstrap** convert up to headroom when brew deficit is 0 but buffer short (0.4.160). Refuse while brew plants are short.
2. Plant-need: live≤0, outstanding≤0, deficit>0, refinable>0; uses=1; reason `plant-need`.
3. Resin-need: byproduct deficit; uses capped at 5; skill-tier match.
4. Sort: plant-need → resin-need → seed-buffer.

**IntentCacheKey:** watchGen + refinePipelineGen + gardenPlanGen + seed-buffer cooldown token + buffer enabled. **No snapGen.** Include active cooldowns; expiry must invalidate cache (0.4.166).

**Empty-cache bust (0.4.170):** cached empty list + `HasPendingBufferRefine` → invalidate and rebuild. Inventory snap (urgent) invalidates intent cache + clears refine wait **without** putting snapGen back into IntentCacheKey.

**Plant-first:** empty plot + plantable job → block refine unless buffer-pending path. Plant-probe-pending: block unless fillBlocked (allow buffer refine while probe stalled). Brew session → no refine.

**Headroom:** `credit = live + ground + outstanding`; `headroom = max(0, bufferMin − credit)`. IssueOne clamps to fresh live headroom. Outstanding TTL ~30s; expire soft MarkDirty then force + 45s seed-buffer fail cooldown. Max outstanding/pending ~6 per seed/plant.

**Prefer** status Refine / Seed buffer over Buy seeds when refinable plants remain. Throttle-only must not fill-block AutoGrow plant path.

### 9.4 Harvest

- Ready chat/sound only when every **planted** plot is grown (empty ignored); keep mid-batch lit without re-chime.
- Enable footer/macro when ready plots exist and brew not loading/crafting; Cultivation-gated.
- Manual/native harvest only.
- Footer Harvest: bind/clear `PERFORM_CRAFTING`/Cultivation only on ready transitions (skip redundant SetGameActionData — strips DefaultResizeable chrome). Keep HandleInput on so tooltips work. Clear bind when leaving Watch.
- After harvest: single wake + storm/quiet; refine due only if no plantable seed job remains; SkipPlan/SkipUi on complete frame.
- Chat: `Harvest: Plot N harvested [Item] xN` with item LINKs; skip non-growables / Arboreal Resin in primary pick; Special Moment chat cue when applicable.
- PrepareHarvest: same-frame dedupe + op-lock no-op before Perf.Begin.

### 9.5 Brew

- Apothecary gated.
- **Session** phases: idle → loading → loaded. **Load job** phases: reset → open → clear → load (stealth apo).
- Footer / macro Ready: `deficit > 0`, `statusKey == ready_to_craft`, `craftable > 0`, not shared. Pick highest deficit.
- Footer enable matches click usefulness: grey while load job / performing / brew op-lock; after auto load, lit for Ready craft (or another Ready pick); **not** lit for manual row loads (R-click clears). Loaded auto sessions may also enable from session deficit/craftable + board validate when plan row lagging (0.4.131).
- Row Load/Brew: **green Craftable only** — `craftable > 0` and seed buffer safe for that watch (buffer off / AutoGrow off ⇒ buffer N/A). Shared mats OK (both watches can show green; brew recounts both). Yellow Craftable = buffer short. Footer/macro stays Ready-only + global buffer.
- Auto footer session clears when target met; manual row may continue.
- Load from crafting bag (+ inventory overflow when craft bag full); no **auto** brew while pending plant commits / buffer unsatisfied / refine outstanding / harvest active.
- R-click clears load; board changes invalidate owned session; 1.5s adopt block after clear.
- Role load order: container → main → stabilizer/goldweed → extender → multiplier/stimulant → ingredient.
- RecipeIsStable: stability total > 0 (match engine HIGH).
- **`brewRespectGrowReserve` (default true):** when brew and AutoGrow compete for the same seed/buffer reserve, prefer not starving AutoGrow’s reserved seeds. Persist the flag. SP2 left `BrewAvailableForSpec` incomplete — SP3 **must** wire character flag → craftable/reserve subtraction.
- **Closed-window Ready wake (0.4.171):** when window closed and Watch UI dirty: live-patch `plan.rows` Status (no WarmHave, no list paint); InvalidateCanBrewCache; `RequestFooterRefresh` **only** when `HasReadyToCraft` flips. Keep dirty so opening the window still paints.
- Brew Ready chat/sound: once per Ready edge; do not re-fire every plant while another Ready watch is only held by pending plant / seed buffer / refine. All-watches-ready notify only when every watch is green **and** at least one is Ready to brew (not all Potions stocked after reload).

### 9.6 AutoBuy

- Independent of AutoGrow when vendor open.
- Cult/Apo craft mats; plant/seed buys only if Cultivation missing (`allowPlantBuys = not CanAutoGrow()`).
- No growables when character can AutoGrow (reject growable store rows in match).
- Fair buy: focus max bottle-gap watches first; fallback to all short watches for buyable non-growable bottlenecks only (skip pooled containers — avoids vial overbuy when focus is growable-only).
- Gold reserve (1–99, default 10) + per-visit budget (1–999, default 50) in gold units × 10k brass; max purchases per visit ~80.
- **Vendor responsiveness (0.4.169):** store-open tick interval ~1s; `WakeAutoBuy` meets that gate (do not stall under AutoGrow idle 5s). Store page updates refresh match index so late vials buy. Watch/plan demand changes while vendor stays open invalidate buy jobs and wake AutoBuy again.
- Store-close detection for reserved/budget stops; resume on close→open or ClearMoneyGateStop (not every store update).
- No alt-currency / non–cult-apo junk.
- Chat: per-material `AutoBuy: Nx Name (spent Xg)` when that type’s need fills; flush leftovers on stop/close; item LINKs.
- Vendor learn: Touch knowledge only when new vendor rows added.

### 9.7 Macros

- Implement §2.1 fully (create, activate, tooltips, grey/disabled when not ready, fingerprint gating, UpdateEnabledState hook).
- Enable with footer; do not hijack stock craft skills.
- Harvest icon / Brew icon stable; tooltip hijack → HarvestTooltip / BrewTooltip.
- Sync when window closed.

### 9.8 Chat / sounds

| Event | Behavior |
| :--- | :--- |
| Harvest all-planted ready | One-shot chat + `HELP_TIPS_NEW`; clear key when not ready; requires CanHarvestNow |
| Footer Brew Ready appears | One-shot chat + `HELP_TIPS_HIGHTLIGHT_WINDOW`; clear when gone; follows CanBrewNow |
| Plant op | Chat on soil confirm with reason; plot format matches harvest |
| Harvest / brew success | Chat with item LINKs where applicable |
| Special Moment | Chat cue |
| AutoBuy | Per-material fill lines + visit stop summary |
| TabWatch settings change | Chat |
| Watch status becomes red | One-shot chat per transition (wait until trade skills ready at login) |
| All watches green + Ready | One-shot notify |
| AutoGrow idle but player action needed | One-shot notify (buy flasks / skill gates) |

ASCII punctuation only in chat locale strings (` - `, `|`, `...`) — no UTF-8 fancy dashes/ellipsis.

---

## 10. Data model / persistence

### 10.1 Saved variables

| Variable | Scope | Contents |
| :--- | :--- | :--- |
| `StockPiler3.Settings` | Shared profile | UI prefs + `characters[name]` |
| `StockPiler3.Account` | Global | Learned knowledge |

Separate from `StockPiler.*` and `StockPiler2.*`.

Strip historical settings-flag leaks from Account on load (`audit` reports unexpected Account top-level keys).

### 10.2 Settings (profile)

- `settingsVersion`, `charactersVersion`, `characters = {}`
- `debugEnabled`, `eventTrace`
- `language` (0 = follow game language)
- `selectedTab`, potion filters/sort fields (`potionNameFilter`, `potionEffectFilter`, `potionKnownRecipeOnly`, `potionSortColumn`, `potionSortAscending`)
- Do **not** persist hitch threshold in Settings if using LibPerf (LibPerf owns enable/threshold)

### 10.3 Character bucket

Key = player name (strip trailing `^…` realm markup); fallback `_default`.

| Field | Default / clamp |
| :--- | :--- |
| `watches` | map recipeKey → `{ enabled, targetStock, autoGrow }` |
| `autoGrowEnabled` / `autoGrowAdditives` | false |
| `autoGrowPauseCombat` | true |
| `autoBuyEnabled` | false |
| `autoBuyReserveGold` | 10 (1–99) |
| `autoBuyBudgetGold` | 50 (1–999) |
| `growSeedBufferMin` | 5 (4–20) |
| `growSeedBufferEnabled` | true |
| `brewMacroEnabled` | false unless explicitly true (SP2 default false; honor in SP3 if you gate macro create) |
| `brewRespectGrowReserve` | true |

Watch defaults: `enabled = false`, `targetStock = 40`, `autoGrow = false` (EnsureWatch may set autoGrow true when created from Potions toggle — match SP2 EnsureWatch behavior). Migrate legacy `uid:N` keys to composite potion recipe keys on load / Potions build.

### 10.4 Account

Empty install: `accountVersion` (SP2 uses 3 for cleanup migrations), `items`, `grows`, `refines`, `recipes`, `potions`, `additives`, `vendorItems`. Relearn in-game. Version bumps may clear false SV flags / polluted grows.

---

## 11. Localization

- English catalog in `Source/Locale/enUS.lua`. User chat and on-screen UI go through `Addon.T(key, tokens)`.
- Templates are `L"..."` wstrings; for chat use ASCII punctuation only.
- Tokens are named `{name}`, `{count}`, etc.; values coerced with `towstring`.
- `settings.language = 0` follows the game language; only enUS required at ship (other packs fall back per key → `[key]`).
- Macro identity **names** stay English for slot lookup stability.
- Key prefix conventions:

| Prefix | Use |
| :--- | :--- |
| `boot.*` | Slash / load |
| `ui.*` | Window chrome |
| `potions.*` | Potions tab (incl. `potions.sort.multiplier` → Mult) |
| `watch.*` | Watch UI + notes |
| `tip.watch.*` / `brew.tip.*` / `grow.tip.*` | Tooltips |
| `plan.status.*` / `plan.line.*` | Status column + tip lines |
| `effect.short.*` / `effect.full.*` | Effect labels |
| `material.*` | MaterialSpec tip meta |
| `brew.*` / `grow.*` / `buy.*` / `macro.*` / `recipe.*` | Domain chat / tips |

---

## 12. Platform constraints

1. RoR Lua does **not** hoist `local function` — define callees above callers (large RecipeSpec-style files). See RoR-Interface `docs/api/lua-local-order.md`.
2. Validate before engine APIs; contextual `TryCall`; never blind `pcall`; report failures with context.
3. Prefer named `SystemData.*` / `GameData.*` as used in https://github.com/xyeppp/RoR-Interface — not unexplained magic numbers.
4. `WindowRegisterEventHandler`; FrameManager / window patterns from stock `interface/`.
5. `.mod` load order: Core → Locale → Stores → Planner → domain → View → Bootstrap. SeedMap split files must load so shared Private symbols exist before Resolve UPDATE_PROCESSED callers.
6. Parallel-safe with StockPiler / StockPiler2 (no shared global mutation; distinct macro names).
7. No hard dependency on LibPerf, PotionBar, or other non-listed addons for core automation.

---

## 13. Invariants (hard lessons)

1. Live uid seed counts for headroom; do not stomp with stale samples.
2. Outstanding refine counts against headroom until delivery or expire.
3. Expire clears pending (no deadlock); IntentCacheKey includes cooldowns; expiry busts empty cache.
4. Shared craftable = deficit crafts only.
5. Contested tooltip **(Shared)**; pooled grow demand **(Pooled)**.
6. Learn/snapshot on harvest complete only; Knowledge.Touch only on structural learns.
7. Macro fingerprint gating + UpdateEnabledState hook.
8. Defer Watch UI during refine outstanding / buffer refine / AutoBuy visit / harvest storm.
9. Scenario Flatten/plan deferral; Combat pause for plant (not lake-only).
10. Post-harvest quiet ≥ storm floor (~1.5s); Orch early-return before BufferFlags.
11. Prefer Refine/Seed buffer status over Buy seeds when refinable plants remain.
12. Empty Account on install is intentional.
13. No snap-wake storm; debounce multi-plot harvest wake; O(1) snap intent invalidate (no HasAnyBufferShort every snap).
14. fillBlocked blocks plant, not buffer refine / AutoBuy; throttle-only ≠ fill-block; do not sticky-rearm wait.
15. One-way mains do not require refine to satisfy AutoGrow learning/planting.
16. Cultivation linkage wins over butcher ProductMatches for growability.
17. Buffer refine bootstraps when brew deficit 0 but buffer short; HasPendingBufferRefine matches convertible gate.
18. Live Status demotes Ready / Potions stocked and promotes out of Seed buffer without full rebuild.
19. Closed-window Status patch wakes Brew macro when Ready flips.
20. AutoBuy store-open uses ~1s tick + WakeAutoBuy; page updates refresh match index.
21. Soft PlanSnapshot.Invalidate keeps stale rows; Clear only on char change.
22. WarmHave skip while refine outstanding; empty have-cache ≠ warm.
23. Never `d(Addon)` for introspection — use `/sp3 mem`.

---

## 14. Diagnostics

Slash-driven: debug uilog (`StockPiler3| …`); plan/watchplan/state/growplan/brewplan/buyplan/stats/bags/mem; event ring; hitch logger (LibPerf or in-addon) + baseline; audit. Empty-trail spikes → likely engine—do not Begin-spam.

Craft-cycle stats: plantAttempts, specialMomentHits, refineAttempts+seedOut, harvest survive/SM/yield helpers, brew success/yield, empirical Cult/Apo skill-up % (n≥5) via TRADE_SKILL_UPDATED attribution. Surface in `/sp3 stats` and Status / footer tips where SP2 does.

---

## 15. Acceptance scenarios

### Feature

1. First install — empty Account; brew once → recipe in catalog (fingerprint row).
2. Watch toggle → Watch tab; target 40; status updates.
3. Shared contention — yellow Shared; footer skips; AutoGrow toward green.
4. Shared tooltip — (Shared) not (Stocked); (Pooled) for pooled grow demand.
5. AutoGrow / AutoBuy focus best priority tier among armed watches needing work, then water-fill (max bottle gap) within that band; plant order matches.
6. Seed buffer — bag+in-ground+outstanding; refine shortfall; batch when plots full; SHORT/partial/OK tooltip.
7. SHORT surplus block — no surplus grow while SHORT or buffer refine pending.
8. No buffer-grow while refinable plants remain; PotionStockNeedsRefineFirst defers buffer/surplus.
9. Mass buffer refine — no live-seed overshoot past headroom.
10. Post-harvest quiet ≥ storm floor; no BufferFlags on storm ticks.
11. Harvest ready chat/sound once; empty plots ignored; mid-batch stays lit without re-chime.
12. Footer Brew Ready-only; session clear after auto target hit.
13. Row Load/Brew = green Craftable only (buffer-safe; shared OK); yellow Craftable = buffer short; footer Ready-only + buffer.
14. Brew R-click clears load; 1.5s adopt block.
15. AutoBuy reserve/budget + reopen resume; ~1s reaction on vendor open; late page vials buy.
16. AutoBuy no growables when Cultivation present; fair bottle-gap focus; fallback skips pooled containers.
17. Skill gates on UI + footer + macros (grey when not ready).
18. Macros created; SP1/SP2 names ignored; enable with footer; sync window closed.
19. Clear watches.
20. Parallel SP1/SP2 installed — SP3 macros/saved vars intact.
21. Forget potion — unlinks fingerprint; keeps shared recipe if siblings remain.
22. One-way / Liniment-class — plants/learns without refine loop; Eternal/Exceptional opaque credit; infertile one-shot seeds; desc/uid special mains force-not-refinable.
23. Restocking — byproduct stabilizer red without feedstock; no Restocking status with empty seed lines.
24. Seed buffer + Watch setting changes produce chat feedback.
25. Potions Mult column between Stab and SCrit; short headers Pwr/Stab/Mult/SCrit; Lvl sortable.
26. Watch Name rarity colors match Potions.
27. Combat pause toggles combat/scenario plant deferral (lake idle still grows when pause off).
28. Closed-window: watch becomes Ready → Brew macro lights without opening window.
29. Live Status: vault removes potions → demotes Potions stocked; buffer fill → leaves Seed buffer; flask-only short → Buy flasks; Ready demotes when have+craftable < target.
30. Buffer refine after harvest when plants land and flags pending — no empty CollectIntents stall.
31. Failed refine expire-stuck — 45s cooldown in cache key; no permanent empty intents with headroom>0.
32. fillBlocked with full buffer + buy-only shorts — wait decays; no sticky re-arm loop.
33. Butcher substitute brew does not mark cult main not-growable.
34. Plot unlocks respected; Locked plots not planted.
35. Localization: UI/chat via T(); ASCII chat punctuation; missing key fallback.

### Performance

36. Refine UI quiet — no per-tick full Watch rebuild; flush after; WarmHave skipped while outstanding.
37. Hotbar noise — no Macro appearance storm (fingerprint).
38. Harvest complete — no LearnBridge every dirty frame; SkipUi fusion avoided.
39. Scenario — no Flatten/plan thrash every bag event.
40. AutoBuy multi-buy — no per-item full invalidate; one rebuild after visit fills.
41. Empty trail honesty — not “fixed” by Begin spam; ≥250ms floor.
42. Multi-plot harvest wake — single force invalidate + quiet (no P1–P4 storm).
43. Inventory snaps — no WakeAutoGrow/ClearFillBlocked storm; O(1) intent invalidate (no HasAnyBufferShort).
44. FindSeedSlot / seed-line caches hit on repeated plant/refine.
45. Cheap PlanRebuild / GardenPatch used mid-refine / plant-harvest; soft Invalidate keeps rows.
46. Target chip stocked↔stocked — no PlanRebuild hitch.
47. Tooltip hover — no CollectIntents / ResolveSeed / plan tip mutation.
48. Settings soft paths — Reserve/Budget/Additives do not force heavy rebuilds.

---

## 16. Build order

Ship a thin responsive skeleton first; add core loop next; polish last.

1. Scaffold `.mod`, Bootstrap, Locale, EventBus, Inventory L0–L3, hitch logger
2. Adapters + trade-skill caps (cache hot lookups)
3. Knowledge learn path (brew → recipes; seed map observe) — keep writes off hot paths
4. Watch persistence + Planner (pure, gen-keyed; one-pass have-cache)
5. Grow intents + plant executor + fillBlocked / quiet / storm gates
6. Scheduler / tick pacing + harvest latch / scenario defer
7. Frame-slice prewarm (Demand / have / seed-lines) — only as needed to meet §6
8. UI — rebuild or adapt SP2 XML; View Lua must stay snapshot-only
9. Harvest prepare/activate + footer/tooltip (complete-only learn)
10. Refine + executor (intents, live headroom, pending discipline, O(1) snap)
11. Brew + executor (footer vs row; grow reserve; closed-window Ready wake)
12. Buy + executor (vendor-open fast tick, WakeAutoBuy, batch invalidate)
13. Macro (§2.1 + closed-window sync)
14. Polish — tooltips, chat/sounds, forget, stats, localization
15. Perf pass — §6 + scenarios 36–48; delete or merge anything that does not earn its hitch cost

Perf review at **each** milestone.

---

## 17. Definition of done

- **Perf:** §6 + §15 performance scenarios pass under harvest/refine/vendor storms (LibPerf ≥250ms or equivalent hitch logger). Prefer equal-or-better hitch profile vs SP2 with less complexity.
- **Core UX:** §7 features + §9 contracts deliver SP2 0.4.174 *capabilities* (Mult column, live Status, closed-window Brew wake, AutoBuy cadence, seed-buffer refine correctness)—without requiring SP2’s internal shape.
- **Lean design:** Clear engine-I/O vs plan vs UI boundaries; no copied SP1/SP2 Core/domain Lua; no hard dependency on unpublished local addons.
- **UI:** §8 columns/interactions complete (XML from SP2 GitHub optional; rebuild allowed).
- **Locale:** §11 scaffold + enUS shipped.
- **Acceptance:** §15 feature scenarios pass.

**Start here:** create `StockPiler3` as a new addon with **performance-first** architecture; keep this file as the spec; clone https://github.com/xyeppp/RoR-Interface for stock UI; browse https://github.com/Talladego?tab=repositories for patterns (StockPiler2 = UX/hitch contracts, not a module template; WarTriage / CustomUIv3 / EZGuard / GCDsaver / etc. as needed). Reimplement under StockPiler3—do not hard-depend on sibling addons.
---

## 18. Explicit pitfalls from SP2 history (do not regress)

Use this as a checklist of **anti-patterns SP2 hit**—encode the *required behavior* in a leaner way. Names are conceptual.
| Area | Failure mode | Required behavior |
| :--- | :--- | :--- |
| Snap wake | WakeAutoGrow / ClearFillBlocked every inventory snap | Freeze / plant storm — wake only intentional paths |
| Intent cache | Empty CollectIntents sticky after harvest / expire-stuck | Bust when BufferFlags pending; cooldowns in cache key |
| Snap probe | HasAnyBufferShort / BufferFlags on every snap | O(1) InvalidateIntentCache only when urgent |
| fillBlocked | Re-arm every idle no-job tick | Sticky wait; clear when buffer satisfied |
| Buffer refine | No convert when Have==Need but buffer short | Bootstrap up to headroom (0.4.160) |
| Live Status | Ready / stocked / Seed buffer stuck until watchplan | ApplyLiveWatchStatus demote/promote paths |
| Closed window | Brew macro stays grey when Ready | SyncLiveStatusClosedWindow + footer refresh on flip |
| AutoBuy idle | 5s AutoGrow idle while vendor open | 1s tick + WakeAutoBuy |
| Butcher | Cult main not-growable after substitute brew | Cultivation linkage wins |
| SeedMap | Unrelated grows / packets pollute PrimaryPlant | Relatedness filters; packets excluded from seedUid |
| Macro bar | DO_MACRO re-enables lit button | UpdateEnabledState hook + clear bind when gated |
| Plan Clear | Clear on every LOADING_END | Soft Invalidate; Clear on char change only |
| WarmHave | Pre-zero craftable on brew load; empty table = warm | Keep prior craftable; warmed-for-snap flag |
| Hover tips | CollectIntents / ResolveSeed / mutate plan tips | cacheOnly + shallow copy |
| mem dump | `d(Addon)` | Freeze — `/sp3 mem` only |
| Local order | Helper below caller | nil global on UPDATE_PROCESSED |
| Chat locale | Unicode em dash | Mojibake — ASCII only |
| Known filter | Half-wired checkbox | Implement or omit |
| brewRespectGrowReserve | Persisted but unwired in SP2 | Wire in SP3 |
