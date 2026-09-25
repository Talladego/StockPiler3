"""Audit Settings watches + Account potions health."""
from pathlib import Path
import re

SETTINGS = Path(
    r"C:\Games\Return of Reckoning\user\settings\Martyrs Square"
    r"\SharedProfile\SharedProfile\StockPiler3\SavedVariables.lua"
)
ACCOUNT = Path(
    r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3\SavedVariables.lua"
)
GLOBAL_MOD = Path(
    r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3\ModSettings.xml"
)


def find_balanced(text: str, open_brace: int) -> tuple[int, int]:
    depth = 0
    i = open_brace
    in_string = False
    quote = ""
    while i < len(text):
        ch = text[i]
        if in_string:
            if ch == "\\" and i + 1 < len(text):
                i += 2
                continue
            if ch == quote:
                in_string = False
            i += 1
            continue
        if ch in ('"', "'"):
            in_string = True
            quote = ch
            i += 1
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return open_brace, i + 1
        i += 1
    raise ValueError("unbalanced")


def section(text: str, name: str) -> str:
    m = re.search(rf"\b{name}\s*=\s*\{{", text)
    if not m:
        return ""
    a, b = find_balanced(text, text.find("{", m.start()))
    return text[a:b]


print("=== GLOBAL ModSettings ===")
print(GLOBAL_MOD.read_text(encoding="utf-8", errors="replace"))

print("=== Settings ===")
st = SETTINGS.read_text(encoding="utf-8", errors="replace")
print("size", len(st), "brace", st.count("{") - st.count("}"))
# character buckets
chars_m = re.search(r"\bcharacters\s*=\s*\{", st)
if chars_m:
    ca, cb = find_balanced(st, st.find("{", chars_m.start()))
    chars = st[ca:cb]
    # top-level character keys
    keys = re.findall(r'\n\t\t\["([^"]+)"\]\s*=\s*\{', chars)
    print("character keys:", keys)
    for key in keys:
        km = re.search(rf'\["{re.escape(key)}"\]\s*=\s*\{{', chars)
        if not km:
            continue
        ba, bb = find_balanced(chars, chars.find("{", km.start()))
        body = chars[ba:bb]
        watches = section("watches = " + body if False else body, "watches")
        # watches nested inside char
        wm = re.search(r"\bwatches\s*=\s*\{", body)
        if wm:
            wa, wb = find_balanced(body, body.find("{", wm.start()))
            wbody = body[wa:wb]
            wkeys = re.findall(r'\n\t\t\t\["([^"]+)"\]\s*=\s*\{', wbody)
            enabled = len(re.findall(r"enabled\s*=\s*true", wbody))
            print(f"  {key}: watchEntries={len(wkeys)} enabledTrue={enabled} bytes={len(wbody)}")
        pm = re.search(r"\bplantWatches\s*=\s*\{", body)
        if pm:
            pa, pb = find_balanced(body, body.find("{", pm.start()))
            pbody = body[pa:pb]
            pkeys = re.findall(r'\n\t\t\t\["([^"]+)"\]\s*=\s*\{', pbody)
            print(f"  {key}: plantWatchEntries={len(pkeys)}")
        else:
            print(f"  {key}: plantWatches absent or empty marker", "plantWatches" in body)

print("=== Account potions/recipes names (sample) ===")
raw = ACCOUNT.read_bytes()
at = raw.rstrip(b"\x00").decode("utf-8", errors="replace")
for sec in ("recipes", "potions"):
    body = section(at, sec)
    keys = re.findall(r'\n\t\t\["([^"]+)"\]\s*=\s*\{', body)
    print(f"{sec} count={len(keys)}")
    for k in keys[:8]:
        print(" ", k[:100])
