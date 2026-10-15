from pathlib import Path
import re

p = Path(r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3\SavedVariables.lua")
b = p.read_bytes()
t = b.rstrip(b"\x00").decode("utf-8")
print("size", len(b), "logical", len(t), "nulls", len(b) - len(b.rstrip(b"\x00")))
print("brace", t.count("{") - t.count("}"))
print("bad_comma", "},," in t)
for needle in ("3010034", "3020034", "84240", "83504", "84241", "83505", "3010030"):
    print("has", needle, needle in t)
m = re.search(r"refines\s*=\s*\{", t)
chunk = t[m.start() : m.start() + 20000]
print("refine_seed_3010034", '["seedUid"] = 3010034' in chunk)
