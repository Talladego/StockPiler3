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

## _repair_climb_links_sv.py

Offline (client shut down): patch Account `grows` / `refines` with Fusk + Spumepetal seed↔plant climb links from uilog ground truth.

```text
python tools/_repair_climb_links_sv.py
```

Backs up to `.bak-climb-repair-*`, writes `.lua.new`, and padded in-place overwrite when the live SV is memory-mapped. Validates brace balance / rejects `},,`.

## _scrub_skillup_origin_sv.py

Offline (client shut down): strip unwatched `skillUpOrigin` recipes/potions from Account `SavedVariables.lua`.

```text
python tools/_scrub_skillup_origin_sv.py              # restore pre-scrub bak then scrub
python tools/_scrub_skillup_origin_sv.py --restore-only
python tools/_scrub_skillup_origin_sv.py --no-restore
```

Validates brace balance and rejects `},,`. Uses same-size **space**-padded overwrite when the SV file is memory-mapped (never NUL pad — trailing `\\0` can make WAR fail to load Account, wiping potions/plants in-session). Not part of the addon runtime.
