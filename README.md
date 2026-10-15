# StockPiler3

Lean Cultivation + Apothecary stock automation for Return of Reckoning.

**Version 0.3.402** - AutoBuy equal-cost drops no longer confirm the wrong purchase; foreign spend only credits attempts that still saw the money leave.

Parallel-safe with StockPiler and StockPiler2 (distinct folder, saved vars, macros, slash).

## Quick start

1. Prefer **[Releases](https://github.com/Talladego/StockPiler3/releases)** → download `StockPiler3-*.zip` (addon only). Do not use Code → Download ZIP (full repo).
2. Unzip into `Interface/AddOns/` so you have `Interface/AddOns/StockPiler3/`
3. Optional: LibSlash (`/sp3`), LibPerf (`/libperf StockPiler3 on 250`)
4. Reload UI; open with `/sp3`

Local pack (same layout as Releases): `powershell -File ./scripts/pack.ps1` → `dist/StockPiler3-<version>.zip`.

## Slash

| Command | Purpose |
| :--- | :--- |
| `/sp3` | Toggle window |
| `/sp3 potions` / `watch` / `plants` | Open tab |
| `/sp3 help` | Command list |
| `/sp3 debug` / `on` / `off` | Structured uilog |
| `/sp3 chat` / `on` / `quiet` / `off` | Chat noise: all lines, changes + harvest/brew, or none |
| `/sp3 fingerprint` `<uidA>` `[uidB]` | Dump ProductKey / ProductMatches compare |
| `/sp3 dumpall` | Bags + every plan/diagnostic dump (one shot) |
| `/sp3 plan` / `watchplan` / `state` / `growplan` / `brewplan` / `buyplan` / `skillplan` / `families` / `upgradeplan` | Dumps |
| `/sp3 stats` / `bags` / `events` / `mem` / `audit` / `harvest` | Diagnostics. `audit` reports only; `audit fix` repairs saved data |
| `/sp3 stats clear` | Wipe Cult/Apo skill-up rate samples |
| `/sp3 perf` | In-addon hitch summary when LibPerf absent |

## Tabs

### Potions

Learned recipe catalog (one row per fingerprint). Watch / Forget / recipe tips. SkillUp Apo crafts are not recorded; any leftover `skillUpOrigin` rows stay hidden.

### Watch

Master **AutoGrow**, additives, **Combat pause**, seed buffer, **Upgrade seeds**, **AutoBuy** (reserve + hard lifetime gold allowance + Reset), **AutoBrew** (auto-perform Ready watches to target). Per-watch Prio / Target / AutoGrow / Brew.

**Level up skills** (when under 200 and watches are done): one Watch checkbox for Cultivating + Apothecary Skill up. Ephemeral status rows (not saved watches). Cult row mirrors master AutoGrow; Apo keeps Brew when a stable board is ready.

### Plants

Catalog of harvested plants that refine back to a seed (resin/byproducts excluded). Stats (Pwr/Stab/Mult/Dur/SCrit/Effect) come from learned `Account.items` even at stock 0. Watch a plant → Watch row with **Prio -**, blank Craftable/Brew; edit **Target** there (default 40). AutoGrow plants raw floors **only after every enabled potion watch is stocked**.

## Upgrade seeds

Toggle **Upgrade seeds** on the Watch tab (default off; needs Cultivation + AutoGrow).

Climb watched / short growable genera toward **Cult floor** (200 at max Cult), using the same plant→crit→refine loop as **Level up skills**. Idle gate matches Level up skills (watches stocked / progress-blocked + seed buffer OK).

1. AutoBuy the lowest **vendor** rung (L1 only — intermediate rungs are not sold)
2. Plant the best owned rung ≤ Cult floor
3. Harvest (normal yield, crit upgrades, **Special Moment** tier-ups)
4. Refine upgraded plants back to seeds
5. Repeat until a Cult-floor seed exists (plant watches also fill that seed buffer)

**Sources:** potion / balanced demand mats that are short, plus **enabled** plant watches (arrive at watched tier, then Cult-max + buffer). Unwatching a plant stops that genus climb unless a potion still needs it.

**Behaviour notes:**

- Multi-family recipes climb both genera; tip Have/Need notes show per-slot climb.
- Prefer the behind genus for plots; do not let one family’s refine starve the other’s plant jobs.
- Never plant or buffer a lower-tier seed once the plant’s skill-matched seed is known.
- Intermediate climb seeds keep 0 cushion; L1 vendor seeds may keep the seed buffer.
- Incomplete ladders (e.g. marshroot only L1+L25 discovered) still climb toward Cult floor via Special Moment fishing while watched.
- Status flips to Restocking when climb targets are done and AutoGrow is stocking the watch.

Diagnose: `/sp3 families`, `/sp3 upgradeplan`, `/sp3 dumpall`.

## Skill up

Ideal path from Cult 1 + Apo 1: one level-1 main seed → plant → harvest → refine (1 seed + 1 same-level **Arboreal Resin**) → crit/upgrade the same family. Diagnose with `/sp3 skillplan`.

### Level up skills

Toggle **Level up skills** on Watch while Cult or Apo is under 200 (Cult path needs master AutoGrow + watches done).

**Cultivating**

- Plant main-ingredient seeds at `TargetMaxSkill` (Apo floor when Apo Skill up is on); fall back to lower rungs when climbing; refine to replant.
- Prefer a bag line already at seed buffer, or with enough plants to refine into it; otherwise AutoBuy tops up `SeedDeficit`.
- Fill **every unlocked plot** (skill 1→1, 50→2, 100→3, 150→4).
- Crit upgrades refine up to Cult floor even when Apo-paced planting is lower.

**Apothecary**

- Brew **only at `FloorApoTier`**. After a tier-up, wait for Cult to supply that tier’s main.
- Stabilizer: **Arboreal Resin only**. Board must be engine HIGH (stability sum > 0).
- Resin short → refine leftover lower-tier mains first, then surplus of the exact-floor brew main.
- SkillUp brew recipes are not recorded as known potions.

## AutoGrow

- Master **AutoGrow** + per-watch AutoGrow; requires Cultivation.
- Plants **one seed per tick** into an empty plot (plant-first before refine when a plantable job exists).
- **Priority tiers:** Watch **Prio** chip (`1..N`). Lower tier first among armed watches that still need work.
- **Watch water-fill:** largest bottle gap (`Target − Stock − Craftable`); among equals, lowest craftable.
- Seed buffer (optional): keep minimum seed credit (bags + in-ground + outstanding); refine converts surplus plants when buffer is short.
- Combat pause (default on) defers planting in combat/scenario.
- Cult storms (plant/harvest): avoid full plan rebuilds / Footer Sync so FPS stays usable.

Diagnose with `/sp3 growplan`.

## AutoBuy

- Independent of AutoGrow when the vendor is open.
- Gold **reserve** + hard **lifetime allowance** (persisted spent); **Reset** clears spent.
- Watch mats: no growables while Cultivation can AutoGrow (SkillUp seed/vial jobs are the exception).
- Upgrade Seed only AutoBuys L1 vendor rungs for families that do not already own a higher rung.

## Seed map (learn in-game)

Account `grows` / `refines` link seed ↔ plant from plant / harvest / refine observes. Empty on install — plant and refine once so AutoGrow can resolve seeds. Crit / Special Moment plants must not pin a lower seed onto a higher ladder rung. Seed Packets are never preferred.

Offline climb-link repair (client shut down): `tools/_repair_climb_links_sv.py` — see [tools/README.md](tools/README.md).

## Macros

Creates **StockPiler3 Craft** only. Drag it to a hotbar. Context-aware (brew when Ready, else harvest): latched icon (starts as Harvest, grey when idle), smart tooltip, harvest countdown / stay overlay. Prefer-brew when both are lit (use the footer Harvest button to harvest while Brew is Ready). Footer Harvest / Brew remain. Old Harvest / Brew macros still work if left on a bar but are no longer created. Does not hijack stock craft skills. Ignores SP1/SP2 macro names.

## Design

Performance-first: adapters → gen-keyed stores → pure planner → domain Issue paths → snapshot-only UI.

Recipe mats match by craft **fingerprints** (not exact uid). Incomplete mains stay uid-bound until classified.

Spec: [docs/STOCKPILER3_BUILD_PROMPT.md](docs/STOCKPILER3_BUILD_PROMPT.md)

## Saved variables

- `StockPiler3.Settings` — profile / per-character watches and toggles (incl. SkillUp + AutoBuy spent)
- `StockPiler3.Account` — learned recipes, seed maps, `skillUpRates` (empty maps on install; relearn in-game)

No migration from StockPiler / StockPiler2.

## Recent changelog

| Ver | Notes |
| :--- | :--- |
| 0.3.402 | AutoBuy: pending buy joins money-subset search (equal-cost no longer false-confirms); foreignSpend gated by issueSeq; late cost already dropped is not double-reserved; ResetVisit arms plan after late confirms |
| 0.3.401 | Unreachable bus fallbacks removed. Stage-empty and the green Craftable check each live in one place. Planner calls its own grow check. Account tables, including skill-up rates, come from Persistence. Status colors use one table. Obsolete `tools/_*.py` scripts moved to `tools/archive/`. |
| 0.3.400 | Plan warm-hold expires even while prewarm is busy. A heavy frame keeps the AutoGrow tick owed. `PLAN_UPDATED` fires once per real publish. Apothecary close no longer clears a board StockPiler3 does not own. A manual loaded board unloads after 60s idle. Refine outstanding uses a real soft-grace. Slot updates no longer drop a pending bag rebuild, and an underflow queues one. Explicit trade-skill 0 needs two sources or two pulses. Urgent plan rebuilds survive a bag flush. Fast AutoGrow ticks beat the fill-block interval. Additive wakes wait out storm and quiet. Refine-first does not plant when refine fails. Macro icon latches clear if paint throws. The harvest countdown skips foreign action buttons. |
| 0.3.399 | Skill 0-drops are recorded before the baseline moves. Repair quarantine is session-only. Apothecary open no longer leaves the ability swallowed if init throws. Crafting chat is ignored when the crafting filter id is missing. Vendor buy refuses the buyback tab. Dead seed-line prewarm is gone. Pending harvest falls back when the seed uid is 0. Item specs copy bonus maps. Craft and Harvest buttons pass cursor drops through. Macro lookup requires both name and text. Icon hook restore leaves a later wrapper in place. |
| 0.3.398 | Watch scrub keeps every character's watches, including disabled; `/sp3 audit` is report-only (`audit fix` repairs). AutoBuy reserves unconfirmed spend and will not credit another purchase's gold drop. Refine re-resolves the bag slot before use. |
| 0.3.397 | Hidden Watch: bag snaps keep pending recount only (no StartOnce no-ops); flush on Watch tab show / dirty paint |
| 0.3.396 | Apo ToggleShowing honors the 2.5s suppress TTL; zone mid-load CloseWindow (ability no longer dead until /reload); Watch Craftable recounts on bag snaps (deferred while brewing) |
| 0.3.395 | Crafting chat: Bad seed / add-main-before abort load; blacklist refused main uid (false ProductMatches twins); CloseWindow on load/clear aborts |
| 0.3.393 | AutoBrew load: reserve bag slots only after StepLanded; no ReleaseAllLocks mid-add; abort backoff (stops flask flicker) |
| 0.3.392 | AutoBrew load: wait-confirm each AddCraftingItem (SP1 StepSatisfied) before next step |
| 0.3.382 | Craft bag: Ready when free≥1 (potion output is main bag); AutoBrew preflight aborts when inventory pulls exceed free slots |
| 0.3.381 | AutoBrew: unload vial-only / bad-craft-state partial loads (was stuck loaded; never retried main) |
| 0.3.380 | Incomplete mains: EFFECT-aware bag twin match; stamp from bound main desc; rematerialize prunes wrong-effect outcomes (Conviction/Unguent on snare) |
| 0.3.379 | AutoBuy: snare/glue-bomb mains (Bottled Rat Spittle) no longer misclassified as growable plants; stamp missing main EFFECT from potion Use/name |
| 0.3.360 | Saved-data ValidateAndRepair on load + /sp3 audit (correct twins/mains; drop irreparable) |
| 0.3.359 | Items: stamp main EFFECT from descriptionNarrow |
| 0.3.358 | Recipe storage: UID-agnostic fingerprints (Scale/Chitin twins) |
| 0.3.357 | Catalog: no Potions scroll reset on bag/plan flush; Watch rebinds after eye toggle off-tab |
| 0.3.356 | AutoBrew on: footer Brew stays dark; Craft macro harvest-only (AutoBrew owns perform) |
| 0.3.355 | AutoBrew master toggle: auto-perform Ready watches to target (yields to plant/refine/harvest); SyncTipSlotNeeds forward-declare |
| 0.3.354 | Watch craftable/status recount on settings/knowledge (no /sp3 dumpall needed) |
| 0.3.348 | Seed buffer / Upgrade Seeds: Cult-max plant stock fills buffer when seed uid is unknown (Savage Marshroot s0); Draught stimulant no longer skipped by seed-only hot path |
| 0.3.347 | Potions: composite recipe watches no longer alias sibling recipes for the same output uid; legacy plain uid:N migrates onto the toggled recipe key |
| 0.3.346 | Upgrade Seeds: HaveTargetRung counts same-or-higher rung (L200 satisfies L50 watch arrive); CollectBuyJobs scans owned seeds to Cult floor so mid watches do not AutoBuy L1 |
| 0.3.345 | Upgrade Seeds: destination-tier plants no longer block planting best owned lower seeds while Cult-max seed buffer is short (SM / fail insurance); mid-ladder no-backslide (L1 vs Cloudy) unchanged |
| 0.3.344 | Brew: LivePotionHave returns nil while Inv not ready / snap pending (CountByUid 0 no longer arms Ready on stocked watches) |
| 0.3.343 | UI: eye-clear / Clear Watches no longer KickListBoxLayout-show Watch over Potions/Plants; EnsureSelectedTabShowing restores single-tab chrome |
| 0.3.342 | Upgrade Seeds: unwatch stops that plant's climb (no bag-wide Phase C); clear active + invalidate targets on SetPlantEnabled |
| 0.3.341 | Upgrade Seeds: bag seeds below Cult floor climb to Cult max (idle gate matches Level up skills); Watch status rows for bag climbs; plant-watch buffer-full still applies |
| 0.3.340 | Upgrade Seeds: plant-watch climb destination is Cult floor when the known ladder tops below it (marshroot Fretting L25 no longer ends climb); missing Cult-floor rung is not "buffer full" via lower-tier fallback |
| 0.3.339 | Watch: eye-clear / Forget / Clear Watches force ListBox rebind so rows leave immediately
| 0.3.338 | Fingerprint twins: Planner/RecipeSpec Have, brew bag pick, and vendor AutoBuy use ProductMatches for incomplete mains (no boundUid-only short-circuit) |
| 0.3.337 | Incomplete mains match fingerprint twins (Supple Scale ↔ Preserved Glossy); TYPE/CRAFTING_FAMILY omitted from ProductKey |
| 0.3.334 | Hotbar: `ActionButton.OnLButtonUp` hook passes foreign buttons through with field reads and a tail call only, so hotbar `/assist` macros work |
| 0.3.333 | Macros: verify cached macro ids against name/text; restore DO_MACRO (not NONE) when dropping Craft/Brew Action overrides; stop treating unknown "ours" buttons as Craft |
| 0.3.332 | Macros: keep new occupant's bind when Craft/Brew is replaced on a hotbar slot; drop cached macro ids on MACRO_UPDATED/MACROS_LOADED and release rewritten slots; no longer hijack the Macro window's active slot when flipping the Craft icon |
| 0.3.331 | Clear/Forget: optimistic Watch strip + urgent rebuild; confirm clear kind; potion Forget scrubs watch; blocked eye stays checked |
| 0.3.330 | Watch AutoGrow status: resolve watches by uid when recipe keys drift; keep row checkbox in sync with store |
| 0.3.329 | Craft-only macro (stop creating Harvest/Brew); harvest fire Craft/footer-first; row zebra clears scrollbar + mouseover highlight |
| 0.3.328 | Cleanup: dead Adapter/Core/Planner/Brew/Grow/View code, stale comments, nil guards, unused locale keys |
| 0.3.327 | Headless Apo open (no cascade/backpack); defer refine while vendor open; AutoBuy resume after idle-no-jobs; Craft harvest timer + stay icon; chat item icons; combined buy status; live Craft tooltip times |
| 0.3.296 | Paint SkillUp Watch rows after logon/reload without dumpall |
| 0.3.262 | Watch: Craft bag full status + AutoGrow stall chat (not Restocking when bag has no free slots) |
| 0.3.261 | LibPerf: Orch decision hold remounts have/demand; Pick/Collect cacheOnly Demand; defer BufferFlags + WarmHave bag off BagFlush |
| 0.3.260 | Watch: cloak Apo mid-open; keepVisible rows; scrub never drops watch recipes; heal Learn recipe |
| 0.3.259 | Brew: no HideWindowOnly until SkillType=Apo; open-fail latches (manual/zone clear); Craft brew>soft harvest |
| 0.3.258 | Brew open: OpenWindow every N ticks; open-timeout backoff greys macros (no SendInitCrafting storm) |
| 0.3.257 | Review A–D: CultivationWindow deps; footer/macro key; fingerprint Stim/Goldweed; StoreItem Touch; AutoBuy stop evidence; Seed Lx->Ly; one refine/tick; fill-block seconds; first-error log; 4Hz polls; SeedEconomy; plan reservations |
| 0.3.256 | SkillUp watch rows hide at 200; mid-brew Watch Refresh only if list empty (no flicker) |
| 0.3.255 | SkillUp PickBestBagSeed: skillReq primary; settle bonus <1M (no L150 over L175 in bags) |
| 0.3.254 | Brew ForceBrewUiRefresh: skip WatchRows mid-load/perform; settle hold returns without paint |
| 0.3.253 | SkillUp fill all empty plots from bag (no keep-1); buffer guarded by PreferRefine + Apo reserve |
| 0.3.252 | SkillUp: keep>=1 seed while buffer-short; FindBagPlant cached + not in PickBestBagSeed loop |
| 0.3.251 | SkillUp FindBagPlantForSeed; ladder bag-seed heal; refine never downgrades target seed tier |
| 0.3.250 | SkillUp PlantableSurplus: fill empties when buffer met; hold only while headroom>0 |
| 0.3.249 | Ladder/Resolve: never pin lower seed on higher plant rung; Apo/GrowReserve max linked+ladder headroom |
| 0.3.248 | SkillUp: no plant into seed-buffer cushion; ResolveSeed same-skillReq; Apo reserve max linked same-tier headroom |
| 0.3.247 | Empty intent cache busts on snapGen/harvest only (no 5s CollectIntents poll) |
| 0.3.246 | Skip idle Orch.Tick (no Perf); BufferFlags struct-hold same frame; plan warm-hold retry before cold WarmHave |
| 0.3.245 | Brew-session BufferFlags snapGen hold; skip SkillUp refresh mid-brew; one PickPlantCandidate/frame |
| 0.3.244 | Defer BagFlush while Brew._job; UpdateRows once/frame in ForceBrew; skip Orch during load |
| 0.3.243 | Footer/Macro one-paint-per-frame; BufferFlags snapGen-safe + no snap invalidate; orch PeekFreshBufferPending |
| 0.3.242 | Abort stuck brew on LOADING_END; mid-brew Watch rebinds when planGen moves (SkillUp rows) |
| 0.3.241 | Account.vendorItems session-only; strip legacy SV blob on load |
| 0.3.240 | SkillUp rows mount from CharRow toggles; never wipe sticky on empty pulses; persist last cult/apo |
| 0.3.239 | Ignore empty TRADE_SKILL after LOADING_END; do not drop SkillUp watch rows while toggles on |
| 0.3.238 | Sticky trade-skill levels across combat/scenario empty blips (SkillUp rows + AutoGrow stay up) |
| 0.3.237 | SkillUp rates: each brew/plant counts as attempt; /sp3 stats dumps Apo delta curve + flask/tier |
| 0.3.236 | Potion items only via potion learn; sticky plant/additive/potion kind; harvest StoreItem as plant |
| 0.3.235 | Account.items hard-gate itemType POTION/CRAFTING; always persist itemType |
| 0.3.234 | Remove load-time items/refine scrub; persist gates remain SoT |
| 0.3.233 | Forget removes potion Items stub; no dead refine SV; StoreItem craft-only |
| 0.3.232 | SkillUp Apo plant reserve = watch seed-buffer headroom only (no standing plant cushion) |
| 0.3.231 | SkillUp brew learn: sticky skillUpOrigin + arm on AA.Perform (no Known potions race) |
| 0.3.230 | Soft prio (no PlanRebuild); Potions toggle one rebuild; recipe learn nudge coalesce |
| 0.3.229 | Watch Load/Brew tips match chip state (Load vs Brew; green Craftable) |
| 0.3.228 | Manual Load/Brew when Craftable green even if potion target already met |
| 0.3.227 | Watch tab ListBox visiblerows 11 (was overflowing one row past clip) |
| 0.3.226 | Clear stale Upgrade/SkillUp ephemeral Watch rows when no longer needed |
| 0.3.225 | Status/tooltip climb wording without genus names |
| 0.3.224 | Plant vs Upgrade ephemeral status no longer cross-patch via uniqueID |
| 0.3.223 | Fix UpgradeSeed CultMaxTierBufferFull nil global; tooltip customizedIconNum pad |
| 0.3.222 | Plant watch Need seed / Upgrade status; Upgrade Seeds arrive-climb before stock gate |
| 0.3.221 | Combat pause label fit; Craft macro tip no unhovered flicker; Plants Stimulant Effect (not Mult) |
| 0.3.220 | NormalizeItemDataForTooltip pads careers/races/slots/skills (CreateItemTooltip ipairs nil) |
| 0.3.219 | Orphan Cult-max plant (no seed) does not finish Upgrade; keep climbing/refining |
| 0.3.218 | Plant-watch Upgrade arrives when Cult-max seed buffer is full; refine same-tier plants to fill |
| 0.3.217 | Plant watch status stays Stocked/seed-buffer; upgrading text only on ephemeral Upgrade row |
| 0.3.216 | Plant-watch climb arrives on Cult-max plant; Fretting seeds alone keep planting |
| 0.3.215 | Marsh Root/Marshroot genus merge; climb arrives on Fretting seeds instead of replanting L1 |
| 0.3.214 | Ephemeral Upgrade Seed Watch rows; plant Cult-max climb after watches done |
| 0.3.213 | Seed-buffer settle: refine while empty plots remain (headroom still counts in-ground) |
| 0.3.212 | Plant watches: fill watched stock first; then Upgrade Seed climbs genus to Cult-max |
| 0.3.211 | Upgrade Seeds: plant watches climb to Cult-max genus rung, then restock that tier |
| 0.3.210 | AutoBuy: hold uid through late-confirm grace; no rebuy / ClearLate stash race (#9) |
| 0.3.209 | Drop every-load recipe-subset scrub; allowlist plant EFFECT migrate latch |
| 0.3.208 | Plants SCrit: apo plant SPECIAL_CHANCE only; never copy cult seed Super-Crit |
| 0.3.207 | Plants tab: hide nameless refine/grow uid stubs; DB enrich before list |
| 0.3.206 | Plants tab: Stab/Ext/Mult effect labels; CraftItemInfo fill-gap + seed Super-Crit |
| 0.3.205 | Craft macro tip: per-plot seed (icon/tier), TotalTimer, additives |
| 0.3.204 | Soft plant_stock: fall through to plant floors while potions are buy/brew short |
| 0.3.203 | Soft plant_stock gate: allow plant floors when potions are buy/ready; wait only on Cult need |
| 0.3.202 | Plant watches: Waiting - potions first (not Restocking) while potion watches are short |
| 0.3.201 | Watch tips: stop writing iLevel into item.level (false red Minimum Rank on mats) |
| 0.3.200 | Planner: forward-declare StampRowSeedBufferUids (fix nil call from ApplySeedBufferStatus) |
| 0.3.199 | Upgrade Seed: count in-ground target seeds (no false 0→200 need_buy); climb status only for this watch's seeds |
| 0.3.198 | Seed resolve: trust refine/grow link when seed not in bags; seed-buffer lines skip uid=0 (fixes craftable=0 + no plant) |
| 0.3.197 | AutoBuy: post-buy gap + shorter no-spend cooldown; fix late-confirm double-count; stay armed while cooling |
| 0.3.196 | AutoBuy chat: late bag/money confirm after false buy-no-spend (pending timeout vs bag coalesce) |
| 0.3.195 | Idle AutoGrow: nil plant-job cache + upgrade-targets snap cache (no 5s PickPlant spikes) |
| 0.3.194 | Craft macro: dual Harvest/Brew latch, icon swap, smart next/follow-up tooltip |
| 0.3.193 | Watch: reorder buffer/Upgrade seeds/Combat pause; merge Level up into one checkbox |
| 0.3.192 | Potions: remove Hide Skill up checkbox; always hide unwatched legacy skillUpOrigin |
| 0.3.191 | Upgrade Seed stall notify: once per episode; silence climbing flicker |
| 0.3.190 | Upgrade Seed: L1 seeds plant into empties when bag==buffer (was stuck need_buy) |
| 0.3.189 | Special Moment sticky: 5s TTL + clear on UnregisterChat (#7) |
| 0.3.188 | Watch live craftable: do not stamp snap after selective miss; quiet-end invalidates craftable |
| 0.3.187 | Seed-buffer / upgrade-seed-buffer: do not refine-to-settle while that seed is still in plots |
| 0.3.186 | Seed resolve / seed-buffer: never prefer owned L1 over plant skill-matched seed |
| 0.3.185 | Watch tip: multi-family climb notes on Have/Need slots; row lists genera |
| 0.3.184 | Harvest chat: Special Moment + announce every plant product |
| 0.3.183 | Watch tip: live In progress planting/refining for Upgrade Seed |
| 0.3.182 | BestOwned: bag genus seeds by skillReq (empty ladder seedUid) |
| 0.3.181–180 | SeedMap: L1 / crit plants no longer collapse higher ladder rungs |
| 0.3.179 | `/sp3 dumpall` |
| 0.3.178–175 | Multi-family climb plant/refine fairness; no L1 wave after mid-rung empty |
| 0.3.174–170 | Post-harvest/refine stalls; Cult/Apo tier 200; login watch/UI settle |
| 0.3.169–163 | Climb SV heal; cult-storm FPS (plant quiet, no Footer Sync, FrameWork WarmHave) |
| 0.3.162–147 | AutoBuy visit latch; Brew/SkillUp Ready; SkillUp resin/buffer; Watch Status sync |
| 0.3.146–129 | SkillUp origin scrub; Plants tab; Upgrade Seed family climb introduction |
| 0.3.128 | Cult SkillUp cold-start; AutoBuy SeedDeficit |
| earlier | See git history |
