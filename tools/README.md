# StockPiler3 tools

## waremu_special_mats_probe.py

Paginated GraphQL probe against https://production-api.waremu.com/graphql/ for liniment / hybrid / infertile special apo materials.

```text
python tools/waremu_special_mats_probe.py
```

Writes (gitignored) under `tools/out/`:

- `waremu_special_mats_report.json` — full search results + potion family histogram
- `uid_tables.lua` — snippet for Eternal / Exceptional / Infertile / special-main uid tables

Re-run after game content patches; sync uid tables into `MaterialExceptions.lua` / `SeedMap.lua` when new specials appear.

## _scrub_skillup_origin_sv.py

Offline (client shut down): strip unwatched `skillUpOrigin` recipes/potions from Account `SavedVariables.lua`. Same-size padded overwrite for memory-mapped SV files. Not part of the addon runtime.
