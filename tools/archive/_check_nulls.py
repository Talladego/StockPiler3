from pathlib import Path

p = Path(r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3\SavedVariables.lua")
b = p.read_bytes()
# find first null
idx = b.find(b"\x00")
print("first_null", idx, "size", len(b))
print("bytes_before_null_tail", repr(b[idx - 30 : idx + 5] if idx > 30 else b[:40]))
# any null before logical end?
logical = b.rstrip(b"\x00")
print("logical_end", repr(logical[-40:]))
interior = b[: len(logical)].find(b"\x00")
print("interior_null_before_logical_end", interior)

# Compare potion counts vs bak-before-rescrub
def count_section_keys(path, name):
    raw = Path(path).read_bytes().rstrip(b"\x00")
    t = raw.decode("utf-8", errors="replace")
    import re
    m = re.search(rf"\b{name}\s*=\s*\{{", t)
    if not m:
        return -1
    return len(re.findall(r'\n\t\t\["([^"]+)"\]\s*=\s*\{', t[m.start() : m.start() + 200000]))

base = r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3"
for f in [
    "SavedVariables.lua",
    "SavedVariables.lua.bak-climb-repair-20260921-165432",
    "SavedVariables.lua.bak-before-rescrub-fixed",
    "SavedVariables.lua.bak-rootfix-20260920-223133",
]:
    print(f, "recipes", count_section_keys(f"{base}/{f}", "recipes"), "potions", count_section_keys(f"{base}/{f}", "potions"))
