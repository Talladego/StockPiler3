from pathlib import Path
import re

st = Path(
    r"C:\Games\Return of Reckoning\user\settings\Martyrs Square"
    r"\SharedProfile\SharedProfile\StockPiler3\SavedVariables.lua"
).read_text(encoding="utf-8", errors="replace")

for m in re.finditer(r"plantWatches\s*=\s*\{", st):
    start = st.find("{", m.start())
    depth = 0
    for i in range(start, len(st)):
        if st[i] == "{":
            depth += 1
        elif st[i] == "}":
            depth -= 1
            if depth == 0:
                body = st[start : i + 1]
                print("--- plantWatches bytes", len(body), "---")
                print(body[:800])
                print("keys", re.findall(r'\["([^"]+)"\]', body)[:20])
                break
