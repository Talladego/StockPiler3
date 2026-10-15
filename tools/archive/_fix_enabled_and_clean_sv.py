"""Fix: re-enable StockPiler3 GLOBAL mod + rewrite Account SV without NUL padding."""
from __future__ import annotations

import re
import shutil
from datetime import datetime
from pathlib import Path

DIR = Path(r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3")
ACCOUNT = DIR / "SavedVariables.lua"
MOD = DIR / "ModSettings.xml"


def validate(text: str) -> None:
    if "},," in text:
        raise SystemExit("},, present")
    if text.count("{") - text.count("}") != 0:
        raise SystemExit("brace imbalance")
    for name in ("grows", "refines", "recipes", "potions", "items"):
        if not re.search(rf"\b{name}\s*=\s*\{{", text):
            raise SystemExit(f"missing {name}")
    for needle in ('["3010034"]', '["3020034"]', '["seedUid"] = 3010034'):
        if needle not in text:
            raise SystemExit(f"missing climb link {needle}")


def main() -> None:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")

    # 1) Re-enable GLOBAL module (client wrote enabled=false on last shutdown).
    if MOD.is_file():
        xml = MOD.read_text(encoding="utf-8", errors="replace")
        bak_xml = MOD.with_suffix(f".xml.bak-enable-{stamp}")
        shutil.copy2(MOD, bak_xml)
        xml2 = xml.replace('enabled="false"', 'enabled="true"', 1)
        if 'enabled="true"' not in xml2:
            raise SystemExit("failed to set enabled=true")
        MOD.write_text(xml2, encoding="utf-8", newline="\n")
        print(f"ModSettings: enabled=true (bak {bak_xml.name})")
    else:
        print("ModSettings missing")

    # 2) Rewrite Account SV as clean logical Lua (strip NUL pad that can break loaders).
    raw = ACCOUNT.read_bytes()
    text = raw.rstrip(b"\x00").decode("utf-8", errors="replace")
    if not text.endswith("\n"):
        text += "\n"
    validate(text)

    bak = ACCOUNT.with_suffix(f".lua.bak-cleanrewrite-{stamp}")
    shutil.copy2(ACCOUNT, bak)
    payload = text.encode("utf-8")
    clean = ACCOUNT.with_suffix(".lua.clean")
    clean.write_bytes(payload)

    # Prefer replace via temp rename (client shut down).
    tmp = ACCOUNT.with_suffix(".lua.swap")
    if tmp.exists():
        tmp.unlink()
    clean.replace(tmp)
    try:
        ACCOUNT.unlink()
    except OSError as exc:
        print(f"unlink live failed ({exc}); leaving {tmp.name}")
        # Fall back to padded overwrite into mapped file
        mapped = len(raw)
        write = payload + (b"\x00" * max(0, mapped - len(payload)))
        try:
            with open(ACCOUNT, "r+b") as fh:
                fh.write(write[:mapped] if len(write) >= mapped else write)
                if len(payload) <= mapped:
                    # keep size if mapped; content is valid Lua then NULs
                    pass
            print("fallback padded overwrite used")
            tmp.unlink(missing_ok=True)
            return
        except OSError as exc2:
            raise SystemExit(f"cannot replace Account SV: {exc} / {exc2}") from exc2

    tmp.replace(ACCOUNT)
    print(f"Account SV cleaned: {ACCOUNT.stat().st_size} bytes (was {len(raw)})")
    print(f"backup: {bak.name}")
    # quick counts
    for sec in ("recipes", "potions", "grows", "refines", "items"):
        m = re.search(rf"\b{sec}\s*=\s*\{{", text)
        print(f"  has {sec}:", bool(m))


if __name__ == "__main__":
    main()
