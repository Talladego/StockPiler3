# StockPiler3 tools

## deploy.ps1

Copy **runtime-only** addon files from this repo into the live RoR AddOns folder:
`StockPiler3.mod` + `Source\`. Prunes anything else under dest (`docs`, `tools`, `README`, `.git`, …).

```text
.\tools\deploy.ps1
.\tools\deploy.ps1 -WhatIf
.\tools\deploy.ps1 -Dest "D:\Games\Return of Reckoning\Interface\AddOns\StockPiler3"
```

Default dest: `C:\Users\talla\Games\Return of Reckoning\Interface\AddOns\StockPiler3`. Reload UI after deploy (`/reload`).

## waremu_special_mats_probe.py

Paginated GraphQL probe against https://production-api.waremu.com/graphql/ for liniment / hybrid / infertile special apo materials.

```text
python tools/waremu_special_mats_probe.py
```

Writes (gitignored) under `tools/out/`:

- `waremu_special_mats_report.json` — full search results + potion family histogram
- `uid_tables.lua` — snippet for Eternal / Exceptional / Infertile / special-main uid tables

Re-run after game content patches; sync uid tables into `MaterialExceptions.lua` / `SeedMap.lua` when new specials appear.

## archive/

One-off SavedVariables scripts from earlier debugging. They are not part of the addon and several hardcode paths, uids, or character names. `_scrub_skillup_origin_sv.py` restores a 2026-09-21 backup over the live SavedVariables file unless you pass `--no-restore`. Do not run that script against a current account.
