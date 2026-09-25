# -*- coding: utf-8 -*-
from pathlib import Path
import re

log = Path(r"c:\Games\Return of Reckoning\logs\uilog.log")
out = []
with log.open(encoding="utf-8", errors="replace") as f:
    for line in f:
        if "[26/09/21][21:21:" not in line and "[26/09/21][21:22:" not in line and "[26/09/21][21:23:" not in line:
            # also catch later if any
            if "[26/09/21][21:2" not in line:
                continue
            # only 21:21+
            m = re.search(r"\[21:(\d\d):", line)
            if not m or int(m.group(1)) < 21:
                continue
        if "StockPiler3" not in line:
            continue
        # skip bag dump noise
        if any(x in line for x in ("slot=", "craftingBonus=", "bonus={", "description=", "fields type=", "flags isStackable", "classify special")):
            continue
        m = re.search(r"\[(\d{2}:\d{2}:\d{2})\].*?StockPiler3\|?\s*(.*)$", line)
        if m:
            msg = m.group(2).strip()
            if msg.startswith("StockPiler3|"):
                msg = msg[len("StockPiler3|"):].strip()
            # keep interesting
            keep_keys = (
                "grow|", "orch|", "refine|", "init", "caps|", "event|", "sch|",
                "plantJob", "emptyPlots", "why=", "buy[", "active ", "harvest",
                "fillBlocked", "skip", "phase", "demand", "seedBuffer", "upgrade",
                "merged[", "target[", "no-bag", "plantable", "stall",
            )
            low = msg.lower()
            if any(k.lower() in low for k in keep_keys) or msg.startswith("---") or msg.startswith("==="):
                out.append(f"{m.group(1)}| {msg}")

Path(r"c:\Games\Return of Reckoning\Interface\AddOns\StockPiler3\tools\_wake_timeline.txt").write_text(
    "\n".join(out), encoding="utf-8"
)
print("lines", len(out))
for L in out:
    print(L)
