# StockPiler3

Lean Cultivation + Apothecary stock automation for Return of Reckoning.

**Version 0.2.0** — material fingerprint matching; AutoGrow plant pick wired to Planner demand (bottle-gap / craftable water-fill).

Parallel-safe with StockPiler and StockPiler2 (distinct folder, saved vars, macros, slash).

## Quick start

1. Install under `Interface/AddOns/StockPiler3/`
2. Optional: LibSlash (`/sp3`), LibPerf (`/libperf StockPiler3 on 250`)
3. Reload UI; open with `/sp3`

## Slash

| Command | Purpose |
| :--- | :--- |
| `/sp3` | Toggle window |
| `/sp3 potions` / `watch` | Open tab |
| `/sp3 help` | Command list |
| `/sp3 debug` / `on` / `off` | Structured uilog |
| `/sp3 plan` / `watchplan` / `state` / `growplan` / `brewplan` / `buyplan` | Dumps |
| `/sp3 stats` / `bags` / `events` / `mem` / `audit` / `harvest` | Diagnostics |
| `/sp3 perf` | In-addon hitch summary when LibPerf absent |

## AutoGrow

- Master **AutoGrow** + per-watch AutoGrow; requires Cultivation.
- Plants **one seed per tick** into an empty plot (plant-first before refine when a plantable job exists).
- **Watch water-fill:** prefer watches with the largest bottle gap (`Target − Stock − Craftable`). Among equal gaps, prefer the **lowest craftable**.
- **Material pick:** unique limiting ingredient for those focus recipes first (so one harvest tends to unlock ~one more brew), then highest `craftsShort`, then role/plot fairness.
- Seed buffer (optional): keep a minimum seed credit (bags + in-ground + outstanding); refine converts surplus plants when buffer is short.
- Combat pause (default on) defers planting in combat/scenario.

Diagnose with `/sp3 growplan` (focus watches, demand shorts, current `plantJob`).

## Seed map (learn in-game)

Account `grows` / `refines` link seed ↔ plant from plant / harvest / refine observes. Empty on install — plant and refine once so AutoGrow can resolve seeds for recipe mains/multipliers. Seed Packets are never preferred for AutoGrow.

## Macros

Creates **StockPiler3 Harvest** and **StockPiler3 Brew**. Drag to a hotbar. Does not hijack stock craft skills. Ignores SP1/SP2 macro names.

## Design

Performance-first: adapters → gen-keyed stores → pure planner → domain Issue paths → snapshot-only UI.

Recipe mats match by craft **fingerprints** (not exact uid), so Fabricated and normal vials count together. Incomplete mains stay uid-bound until classified.

Spec: [docs/STOCKPILER3_BUILD_PROMPT.md](docs/STOCKPILER3_BUILD_PROMPT.md)

## Saved variables

- `StockPiler3.Settings` — profile / per-character watches and toggles
- `StockPiler3.Account` — learned recipes, seed maps (empty on install; relearn in-game)

No migration from StockPiler / StockPiler2.
