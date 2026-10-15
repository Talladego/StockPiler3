from pathlib import Path
import re

def balanced(text, brace):
    depth = 0
    i = brace
    ins = False
    q = ""
    while i < len(text):
        ch = text[i]
        if ins:
            if ch == "\\" and i + 1 < len(text):
                i += 2
                continue
            if ch == q:
                ins = False
            i += 1
            continue
        if ch in ("'", '"'):
            ins = True
            q = ch
            i += 1
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return brace, i + 1
        i += 1
    raise ValueError("unbalanced")

def section(text, name):
    m = re.search(rf"\b{name}\s*=\s*\{{", text)
    a, b = balanced(text, text.find("{", m.start()))
    return text[a:b]

acc = Path(r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3\SavedVariables.lua").read_text(encoding="utf-8", errors="replace").rstrip()
mod = Path(r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3\ModSettings.xml").read_text(encoding="utf-8")
settings = Path(
    r"C:\Games\Return of Reckoning\user\settings\Martyrs Square\SharedProfile\SharedProfile\StockPiler3\SavedVariables.lua"
).read_text(encoding="utf-8", errors="replace")

print("ModSettings enabled=true", 'enabled="true"' in mod)
print("Account brace", acc.count("{") - acc.count("}"), "nul", "\x00" in acc)
for s in ("recipes", "potions", "grows", "refines", "items"):
    body = section(acc, s)
    keys = re.findall(r'\n\t\t\["([^"]+)"\]\s*=\s*\{', body)
    print(f"  {s}: {len(keys)}")
g = section(acc, "grows")
r = section(acc, "refines")
print("climb grows 3010034", '["3010034"]' in g)
print("climb refine 3020034 seed", '["3020034"]' in r and '["seedUid"] = 3010034' in r)
print("settings watches enabled", settings.count("enabled = true"))
print("settings plant:3020038", "plant:3020038" in settings)
print("version file", Path(r"C:\Games\Return of Reckoning\Interface\AddOns\StockPiler3\Source\Bootstrap.lua").read_text(encoding="utf-8").split("Version")[1][:30])
