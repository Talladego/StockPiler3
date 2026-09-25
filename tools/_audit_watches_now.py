from pathlib import Path
import re

SETTINGS = Path(
    r"C:\Games\Return of Reckoning\user\settings\Martyrs Square"
    r"\SharedProfile\SharedProfile\StockPiler3\SavedVariables.lua"
)
GLOBAL_MOD = Path(r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3\ModSettings.xml")
PROFILE_MOD = Path(
    r"C:\Games\Return of Reckoning\user\settings\Martyrs Square"
    r"\SharedProfile\SharedProfile\StockPiler3\ModSettings.xml"
)

print("=== GLOBAL Mod ===")
print(GLOBAL_MOD.read_text(encoding="utf-8", errors="replace"))
print("=== PROFILE Mod ===")
print(PROFILE_MOD.read_text(encoding="utf-8", errors="replace")[:500])

st = SETTINGS.read_text(encoding="utf-8", errors="replace")
print("settings size", len(st), "mtime ok")
# character names (bare keys under characters)
chars = re.findall(r"\n\t\t([A-Za-z0-9_]+)\s*=\s*\n\t\t\{", st)
print("characters", chars)
for char in chars:
    m = re.search(rf"\n\t\t{re.escape(char)}\s*=\s*\n\t\t\{{", st)
    if not m:
        continue
    chunk = st[m.start() : m.start() + 25000]
    wm = re.search(r"\bwatches\s*=\s*\{", chunk)
    pm = re.search(r"\bplantWatches\s*=\s*\{", chunk)
    w_enabled = 0
    w_keys = []
    if wm:
        # approximate until plantWatches or next top-level-ish
        end = chunk.find("plantWatches", wm.start())
        if end < 0:
            end = wm.start() + 8000
        block = chunk[wm.start() : end]
        w_keys = re.findall(r'\["(uid:[^"]+)"\]', block)
        w_enabled = len(re.findall(r"enabled\s*=\s*true", block))
    p_keys = []
    p_enabled = 0
    if pm:
        pb = chunk[pm.start() : pm.start() + 4000]
        p_keys = re.findall(r'\["(plant:[^"]+)"\]', pb)
        p_enabled = len(re.findall(r"enabled\s*=\s*true", pb))
    print(f"  {char}: potionWatches={len(w_keys)} enabledTrue~{w_enabled} plantWatches={len(p_keys)} plantEnabled~{p_enabled}")
    if w_keys:
        print("    potions:", [k.split("|")[0] for k in w_keys[:8]])
    if p_keys:
        print("    plants:", p_keys[:8])
