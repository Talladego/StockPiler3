# StockPiler3

Lean Cultivation + Apothecary stock automation for Return of Reckoning.

**Version 0.3.128** — Cult SkillUp cold-start: prefer bag mains already at buffer (or plant-refinable to it); AutoBuy tops up `SeedDeficit` even when bags already hold some seeds; buy target stays on the chosen/plant-linked line.

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
| `/sp3 plan` / `watchplan` / `state` / `growplan` / `brewplan` / `buyplan` / `skillplan` | Dumps |
| `/sp3 stats` / `bags` / `events` / `mem` / `audit` / `harvest` | Diagnostics |
| `/sp3 stats clear` | Wipe Cult/Apo skill-up rate samples |
| `/sp3 perf` | In-addon hitch summary when LibPerf absent |

## Tabs

### Potions

Learned recipe catalog (one row per fingerprint). Watch / Forget / recipe tips. **Hide Skill up** (default on) hides potions stamped `skillUpOrigin` from SkillUp Apo brews.

### Watch

Master **AutoGrow**, additives, **Combat pause**, seed buffer, **AutoBuy** (reserve + hard lifetime gold allowance + Reset). Per-watch Prio / Target / AutoGrow / Brew.

**Level up Cultivating / Apothecary** (when under 200 and watches are done): ephemeral status rows (not saved watches). Cult row mirrors master AutoGrow; Apo keeps Brew when a stable board is ready.

### Plants

Catalog of harvested plants that refine back to a seed (resin/byproducts excluded). Stats (Pwr/Stab/Mult/Dur/SCrit/Effect) come from learned `Account.items` even at stock 0. Watch a plant → Watch row with **Prio -**, blank Craftable/Brew; edit **Target** there (default 40). AutoGrow plants raw floors **only after every enabled potion watch is stocked**.

## Skill up

Ideal path from Cult 1 + Apo 1: one level-1 main seed → plant → harvest → refine (1 seed + 1 same-level **Arboreal Resin**) → crit/upgrade the same family. Diagnose with `/sp3 skillplan`.

### Cultivating

- Toggle **Level up Cultivating** while Cult is under 200 (needs master AutoGrow + watches done).
- Plant main-ingredient seeds at `TargetMaxSkill` (Apo floor when Level up Apo is on); fall back to lower rungs when climbing; refine to replant.
- Prefer a bag line already at seed buffer, or with enough plants to refine into it; otherwise AutoBuy tops up `SeedDeficit` (empty plots + buffer) even if bags already hold some seeds.
- Fill **every unlocked plot** (skill 1→1, 50→2, 100→3, 150→4).
- At Cult 200 with Level up Apo on: keep planting Apo-tier mains (no more Cult skill samples).
- Crit upgrades refine up to Cult floor even when Apo-paced planting is lower.

### Apothecary

- Toggle **Level up Apothecary** while Apo is under 200.
- Brew **only at `FloorApoTier`**. After a tier-up, wait for Cult to supply that tier’s main — do not keep brewing the old rung.
- Stabilizer: **Arboreal Resin only**. Board must be engine HIGH (stability sum > 0).
- Resin short → refine leftover mains below Apo floor first, then surplus of the exact-floor brew main (keep ≥1). Same seed-buffer rules as potion watches.
- Vial AutoBuy stocks one remaining tier band using SkillUp-only rate samples (`/sp3 stats`); vials may pre-buy while the brew main is held for seed buffer.
- Recipes from SkillUp brew are stamped `skillUpOrigin` (manual brew while Level up Apo is on is not).

### Stats

- `/sp3 stats` — hits/attempts per skill level (Cult + Apo).
- `/sp3 stats clear` — wipe samples (also used for vial E[crafts] estimates).

## AutoGrow

- Master **AutoGrow** + per-watch AutoGrow; requires Cultivation.
- Plants **one seed per tick** into an empty plot (plant-first before refine when a plantable job exists).
- **Priority tiers:** leftmost Watch **Prio** chip (`1..N`). Lower tier first among AutoGrow-armed watches that still need work.
- **Watch water-fill:** largest bottle gap (`Target − Stock − Craftable`); among equals, lowest craftable.
- **Material pick:** unique limiting ingredient for focus recipes first, then highest `craftsShort`, then role/plot fairness.
- Seed buffer (optional): keep minimum seed credit (bags + in-ground + outstanding); refine converts surplus plants when buffer is short.
- Combat pause (default on) defers planting in combat/scenario.

Diagnose with `/sp3 growplan`.

## AutoBuy

- Independent of AutoGrow when the vendor is open.
- Gold **reserve** (keep in pocket) + hard **lifetime allowance** (persisted spent); **Reset** clears spent. Chip is green under allowance, red when exhausted.
- Watch mats: no growables while Cultivation can AutoGrow (SkillUp seed/vial jobs are the exception).
- SkillUp seed buys use `SeedDeficit`; SkillUp vials use one-tier band targets.

## Seed map (learn in-game)

Account `grows` / `refines` link seed ↔ plant from plant / harvest / refine observes. Empty on install — plant and refine once so AutoGrow can resolve seeds. Seed Packets are never preferred. Harvest stamps the seed’s EFFECT onto `Account.items[plantUid].effectId` for the Plants tab.

## Macros

Creates **StockPiler3 Harvest** and **StockPiler3 Brew**. Drag to a hotbar. Does not hijack stock craft skills. Ignores SP1/SP2 macro names.

## Design

Performance-first: adapters → gen-keyed stores → pure planner → domain Issue paths → snapshot-only UI.

Recipe mats match by craft **fingerprints** (not exact uid), so Fabricated and normal vials count together. Incomplete mains stay uid-bound until classified.

Spec: [docs/STOCKPILER3_BUILD_PROMPT.md](docs/STOCKPILER3_BUILD_PROMPT.md)

## Saved variables

- `StockPiler3.Settings` — profile / per-character watches and toggles (incl. SkillUp + AutoBuy spent)
- `StockPiler3.Account` — learned recipes, seed maps, `skillUpRates` (empty maps on install; relearn in-game)

No migration from StockPiler / StockPiler2.

## Recent changelog

| Ver | Notes |
| :--- | :--- |
| 0.3.128 | Cult SkillUp cold-start: settle-ready seed pick; AutoBuy on SeedDeficit |
| 0.3.127 | SkillUp review: Cult 200 Apo-assist; stall one-shot; vial buy vs buffer; SkillUp-only Apo rates; harvest extendOnly; quiet brew-row; skillUpOrigin scope |
| 0.3.126–124 | Watch chrome layout / labels / Budget Reset / plant tip parity |
| 0.3.123 | Plants tab stats from learned store at stock 0 |
| 0.3.122 | AutoBuy Budget = hard lifetime allowance + Reset |
| 0.3.121 | Persist `skillUpRates` on Account allow-list |
| 0.3.120 | `/sp3 skillplan` |
| 0.3.119–108 | Cult/Apo SkillUp plant, refine, vial, Watch row behavior |
| 0.3.89 | Plants tab + plant-stock AutoGrow; Eternal/Exceptional buffer credit |
