"""Compare Account SV section health across live / bak / new."""
from pathlib import Path
import re

DIR = Path(r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3")
FILES = [
    "SavedVariables.lua",
    "SavedVariables.lua.new",
    "SavedVariables.lua.bak-climb-repair-20260921-165432",
    "SavedVariables.lua.bak-before-rescrub-fixed",
]


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
    brace = text.find("{", m.start())
    a, b = find_balanced(text, brace)
    return text[a:b]


def top_keys(section_text: str) -> list[str]:
    if not section_text:
        return []
    return re.findall(r'\n\t\t\["([^"]+)"\]\s*=\s*\{', section_text)


for name in FILES:
    p = DIR / name
    if not p.is_file():
        print(f"MISSING {name}")
        continue
    raw = p.read_bytes()
    text = raw.rstrip(b"\x00").decode("utf-8", errors="replace")
    print(f"\n=== {name} size={len(raw)} logical={len(text)} brace={text.count('{')-text.count('}')} ===")
    for sec in ("grows", "refines", "recipes", "potions", "items", "additives", "vendorItems"):
        body = section(text, sec)
        keys = top_keys(body)
        print(f"  {sec}: bytes={len(body)} keys={len(keys)}")
    # spot-check climb keys
    g = section(text, "grows")
    r = section(text, "refines")
    print("  climb 3010034 in grows", '["3010034"]' in g)
    print("  climb 3020034 in refines", '["3020034"]' in r)
    print("  },, ", "},," in text)
