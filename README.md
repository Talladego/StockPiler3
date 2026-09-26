# StockPiler3

Lean Cultivation + Apothecary stock automation for Return of Reckoning.

**Version 0.3.231** — SkillUp Apo crafts no longer race into Known potions after session clear.

Parallel-safe with StockPiler and StockPiler2 (distinct folder, saved vars, macros, slash).

## Quick start

1. Install under `Interface/AddOns/StockPiler3/`
2. Optional: LibSlash (`/sp3`), LibPerf (`/libperf StockPiler3 on 250`)
3. Reload UI; open with `/sp3`

## Slash

| Command | Purpose |
| :--- | :--- |
| `/sp3` | Toggle window |
| `/sp3 potions` / `watch` / `plants` | Open tab |
| `/sp3 help` | Command list |
| `/sp3 debug` / `on` / `off` | Structured uilog |
| `/sp3 dumpall` | Bags + every plan/diagnostic dump (one shot) |
| `/sp3 plan` / `watchplan` / `state` / `growplan` / `brewplan` / `buyplan` / `skillplan` / `families` / `upgradeplan` | Dumps |
| `/sp3 stats` / `bags` / `events` / `mem` / `audit` / `harvest` | Diagnostics |
| `/sp3 stats clear` | Wipe Cult/Apo skill-up rate samples |
| `/sp3 perf` | In-addon hitch summary when LibPerf absent |

## Tabs

### Potions

Learned recipe catalog (one row per fingerprint). Watch / Forget / recipe tips. SkillUp Apo crafts are not recorded; any leftover `skillUpOrigin` rows stay hidden.

### Watch

Master **AutoGrow**, additives, **Combat pause**, seed buffer, **Upgrade seeds**, **AutoBuy** (reserve + hard lifetime gold allowance + Reset). Per-watch Prio / Target / AutoGrow / Brew.

**Level up Cultivating / Apothecary** (when under 200 and watches are done): ephemeral status rows (not saved watches). Cult row mirrors master AutoGrow; Apo keeps Brew when a stable board is ready.

### Plants

Catalog of harvested plants that refine back to a seed (resin/byproducts excluded). Stats (Pwr/Stab/Mult/Dur/SCrit/Effect) come from learned `Account.items` even at stock 0. Watch a plant → Watch row with **Prio -**, blank Craftable/Brew; edit **Target** there (default 40). AutoGrow plants raw floors **only after every enabled potion watch is stocked**.

## Upgrade seeds

Toggle **Upgrade seeds** on the Watch tab (default off; needs Cultivation + AutoGrow).

When a watched growable mat is missing at its skillReq, climb that family:

1. AutoBuy the lowest **vendor** rung (L1 only — intermediate rungs are not sold)
2. Plant the best owned rung ≤ Cult floor
3. Harvest (normal yield, crit upgrades, **Special Moment** tier-ups)
4. Refine upgraded plants back to seeds
5. Repeat until the watch’s tier seed exists, then grow for stock / seed buffer

**Behaviour notes (verified on a single L200 Draught watch):**

- Multi-family recipes (e.g. Spumepetal main + Fusk multiplier) climb both genera; tip Have/Need notes show per-slot climb (row status lists all genera when more than one is climbing).
- Prefer the behind genus for plots; do not let one family’s refine starve the other’s plant jobs.
- Never plant or buffer a lower-tier seed once the plant’s skill-matched seed is known (owned L1 Dusty/Glossy must not beat missing L200).
- Intermediate climb seeds keep 0 cushion; L1 vendor seeds may keep the seed buffer.
- Status flips to Restocking when climb targets are done and AutoGrow is stocking the watch.

Diagnose: `/sp3 families`, `/sp3 upgradeplan`, `/sp3 dumpall`.

## Skill up

Ideal path from Cult 1 + Apo 1: one level-1 main seed → plant → harvest → refine (1 seed + 1 same-level **Arboreal Resin**) → crit/upgrade the same family. Diagnose with `/sp3 skillplan`.

### Cultivating

- Toggle **Level up Cultivating** while Cult is under 200 (needs master AutoGrow + watches done).
- Plant main-ingredient seeds at `TargetMaxSkill` (Apo floor when Level up Apo is on); fall back to lower rungs when climbing; refine to replant.
- Prefer a bag line already at seed buffer, or with enough plants to refine into it; otherwise AutoBuy tops up `SeedDeficit`.
- Fill **every unlocked plot** (skill 1→1, 50→2, 100→3, 150→4).
- Crit upgrades refine up to Cult floor even when Apo-paced planting is lower.

### Apothecary

- Toggle **Level up Apothecary** while Apo is under 200.
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

Creates **StockPiler3 Harvest**, **StockPiler3 Brew**, and **StockPiler3 Craft**. Drag to a hotbar. Craft is context-aware (harvest vs brew): latched icon (starts as Harvest, grey when idle), smart tooltip shows the next click and any follow-up. Does not hijack stock craft skills. Ignores SP1/SP2 macro names.

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
