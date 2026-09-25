from pathlib import Path
import re

SETTINGS = Path(
    r"C:\Games\Return of Reckoning\user\settings\Martyrs Square"
    r"\SharedProfile\SharedProfile\StockPiler3\SavedVariables.lua"
)
st = SETTINGS.read_text(encoding="utf-8", errors="replace")

# Find Talladegion bucket roughly
for char in ("Talladegion", "Talladegob", "Talladegen"):
    m = re.search(rf"\t\t{char}\s*=\s*\{{", st)
    if not m:
        print(char, "MISSING")
        continue
    # crude: next 15k chars
    chunk = st[m.start() : m.start() + 20000]
    wm = re.search(r"\bwatches\s*=\s*\{", chunk)
    pm = re.search(r"\bplantWatches\s*=\s*\{", chunk)
    wcount = len(re.findall(r"enabled\s*=\s*true", chunk[: chunk.find("plantWatches") if pm else 8000]))
    print(char, "watches_marker", bool(wm), "plantWatches_marker", bool(pm))
    if pm:
        # count plant keys until next top field
        pb = chunk[pm.start() :]
        keys = re.findall(r'\["(\d+)"\]\s*=\s*\{', pb[:5000])
        print("  plant keys sample", keys[:10], "count_in_5k", len(keys))
    # count potion watch keys in watches block
    if wm:
        wb = chunk[wm.start() :]
        end = wb.find("\n\t\t\t},")
        block = wb[: end if end > 0 else 8000]
        pkeys = re.findall(r'\["uid:(\d+)', block)
        print("  potion watch uids", pkeys)

print("total plantWatches occurrences", len(re.findall(r"plantWatches", st)))
print("total enabled true", len(re.findall(r"enabled = true", st)))
