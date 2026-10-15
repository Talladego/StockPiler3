# -*- coding: utf-8 -*-
from pathlib import Path
import re

t = Path(
    r"c:\Games\Return of Reckoning\user\settings\Martyrs Square"
    r"\SharedProfile\SharedProfile\StockPiler3\SavedVariables.lua"
).read_text(encoding="utf-8", errors="replace")

# character names under characters =
chars = re.findall(r"characters\s*=\s*\{([\s\S]*?)\n\t\},", t)
print("char blocks", len(chars))
# list bare identifiers / quoted keys at characters level
cm = re.search(r"characters\s*=\s*\{", t)
if cm:
    i = cm.end() - 1
    depth = 0
    start = i
    for j in range(i, len(t)):
        c = t[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                block = t[start : j + 1]
                print("characters block len", len(block))
                # top-level keys inside characters (depth 1->2)
                keys = re.findall(r"\n\t\t([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{", block)
                keys += re.findall(r'\n\t\t\["([^"]+)"\]\s*=\s*\{', block)
                print("char keys", keys)
                for k in keys:
                    # count enabled in that char - find subsection
                    pat = re.compile(
                        rf"(\n\t\t{re.escape(k)}\s*=\s*\{{)|(\n\t\t\[\"{re.escape(k)}\"\]\s*=\s*\{{)"
                    )
                    mm = pat.search(block)
                    if not mm:
                        print(k, "not found")
                        continue
                    s = mm.start()
                    d = 0
                    for jj in range(block.find("{", s), len(block)):
                        if block[jj] == "{":
                            d += 1
                        elif block[jj] == "}":
                            d -= 1
                            if d == 0:
                                sub = block[s : jj + 1]
                                et = len(re.findall(r"enabled\s*=\s*true", sub))
                                ef = len(re.findall(r"enabled\s*=\s*false", sub))
                                print(f"  {k}: enabled true={et} false={ef} len={len(sub)}")
                                break
                break
