#!/usr/bin/env python3
"""Offline repair: patch Account grows/refines climb links for Fusk + Spumepetal.

Ground truth from uilog refine ops + 16:32 family dump (session before 0.3.168 reload).
Client must be shut down. Does not touch recipes/potions.
"""
from __future__ import annotations

import re
import shutil
from datetime import datetime
from pathlib import Path

ACCOUNT_SV = Path(
    r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3\SavedVariables.lua"
)

# Majority refine plant -> seed from uilog + distinct L125 Fusk spore (3010035).
# Crit harvest of L100 spore can yield L125 plant, but that plant's canonical seed
# is the same-tier spore when present — not the lower planted seed.
REFINE_LINKS: list[tuple[int, int, int]] = [
    # plantUid, seedUid, samples
    (3020030, 3010030, 5),
    (3020031, 3010030, 9),
    (3020032, 3010032, 23),
    (3020033, 3010032, 15),
    (3020034, 3010034, 9),
    (3020035, 3010035, 4),  # Shaded Shadow Fusk -> Shaded Shadow Fusk Spore
    (83500, 84236, 25),
    (83501, 84237, 16),
    (83502, 84238, 7),
    (83503, 84238, 4),
    (83504, 84240, 4),
    (83505, 84241, 1),
]

# seedUid -> list of (plantUid, samples) for grows.products
# Do not attach crit-upgraded plants to a lower seed (no 3010034 -> 3020035).
GROW_PRODUCTS: dict[int, list[tuple[int, int]]] = {
    3010030: [(3020030, 5), (3020031, 9)],
    3010032: [(3020032, 23), (3020033, 15)],
    3010034: [(3020034, 9)],
    3010035: [(3020035, 4)],
    84235: [],  # L1 vendor seed (ingredient); plant optional
    84236: [(83500, 25)],
    84237: [(83501, 16)],
    84238: [(83502, 7), (83503, 4)],
    84240: [(83504, 4)],
    84241: [(83505, 1)],
}


def find_balanced_table(text: str, open_brace: int) -> tuple[int, int]:
    assert text[open_brace] == "{"
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
    raise ValueError("unbalanced table")


def section_span(text: str, name: str) -> tuple[int, int]:
    m = re.search(rf"\b{name}\s*=\s*\{{", text)
    if not m:
        raise ValueError(f"missing section {name}")
    brace = text.find("{", m.start())
    return find_balanced_table(text, brace)


def entry_span(section: str, key: str) -> tuple[int, int] | None:
    """Relative [start,end) of ["key"] = {...}, inside section (key through table)."""
    pat = re.compile(rf'\["{re.escape(key)}"\]\s*=\s*\{{')
    m = pat.search(section)
    if not m:
        return None
    brace = section.find("{", m.start())
    _, end = find_balanced_table(section, brace)
    # Include trailing comma if present.
    if end < len(section) and section[end] == ",":
        end += 1
    return m.start(), end


def format_grow_bucket(seed_uid: int, products: list[tuple[int, int]]) -> str:
    lines = [
        f'\t\t["{seed_uid}"] = {{',
        '\t\t\t["chatCriticalFailure"] = 0,',
        '\t\t\t["chatCriticalSuccess"] = 0,',
        '\t\t\t["cultSkillHits"] = 0,',
        '\t\t\t["harvestAttempts"] = 0,',
        '\t\t\t["plantAttempts"] = 0,',
        '\t\t\t["products"] = {',
    ]
    for plant_uid, samples in products:
        lines.append(f'\t\t\t\t["{plant_uid}"] = {{')
        lines.append(f'\t\t\t\t\t["qtySum"] = {samples},')
        lines.append(f'\t\t\t\t\t["samples"] = {samples},')
        lines.append(f'\t\t\t\t\t["uid"] = {plant_uid},')
        lines.append("\t\t\t\t},")
    lines.append("\t\t\t},")
    lines.append(f'\t\t\t["seedUid"] = {seed_uid},')
    lines.append('\t\t\t["specialMomentHits"] = 0,')
    lines.append("\t\t},")
    return "\n".join(lines)


def format_refine_entry(plant_uid: int, seed_uid: int, samples: int) -> str:
    return "\n".join(
        [
            f'\t\t["{plant_uid}"] = {{',
            f'\t\t\t["plantUid"] = {plant_uid},',
            f'\t\t\t["refineAttempts"] = {samples},',
            '\t\t\t["seedOut"] = {',
            f'\t\t\t\t["{seed_uid}"] = {{',
            f'\t\t\t\t\t["qtySum"] = {samples},',
            f'\t\t\t\t\t["samples"] = {samples},',
            "\t\t\t\t},",
            "\t\t\t},",
            f'\t\t\t["seedUid"] = {seed_uid},',
            "\t\t},",
        ]
    )


def upsert_grow(section: str, seed_uid: int, products: list[tuple[int, int]]) -> tuple[str, str]:
    key = str(seed_uid)
    span = entry_span(section, key)
    new_entry = format_grow_bucket(seed_uid, products)
    if span is None:
        # Insert before closing of grows (section ends with }\n relative — last char is })
        insert_at = len(section) - 1
        while insert_at > 0 and section[insert_at - 1] in " \t\r\n":
            insert_at -= 1
        # section is `{ ... }`; insert before final `}`
        return section[:insert_at] + "\n" + new_entry + "\n" + section[insert_at:], "added"
    # Merge products into existing bucket when present
    old = section[span[0] : span[1]]
    if '["products"]' not in old:
        return section[: span[0]] + new_entry + section[span[1] :], "replaced"
    # Ensure each product plant key exists; if seedUid products empty and we have products, patch.
    missing = []
    for plant_uid, samples in products:
        if f'["{plant_uid}"]' not in old:
            missing.append((plant_uid, samples))
    if not missing and products:
        return section, "ok"
    if not products:
        return section, "ok"
    # Rebuild with union of products
    existing_plants = set(re.findall(r'\["(\d+)"\]\s*=\s*\{', old.split('["products"]', 1)[-1].split("},", 1)[0] if '["products"]' in old else ""))
    merged: dict[int, int] = {}
    for plant_uid, samples in products:
        merged[plant_uid] = samples
    for m in re.finditer(
        r'\["(\d+)"\]\s*=\s*\{[^}]*\["samples"\]\s*=\s*(\d+)',
        old,
    ):
        merged.setdefault(int(m.group(1)), int(m.group(2)))
    # Only product uids under products — filter seedUid key appearing in bucket
    prod_merged = [(p, s) for p, s in merged.items() if p != seed_uid]
    if not prod_merged and products:
        prod_merged = products
    new_entry = format_grow_bucket(seed_uid, sorted(prod_merged))
    return section[: span[0]] + new_entry + section[span[1] :], "updated"


def upsert_refine(section: str, plant_uid: int, seed_uid: int, samples: int) -> tuple[str, str]:
    key = str(plant_uid)
    span = entry_span(section, key)
    new_entry = format_refine_entry(plant_uid, seed_uid, samples)
    if span is None:
        insert_at = len(section) - 1
        while insert_at > 0 and section[insert_at - 1] in " \t\r\n":
            insert_at -= 1
        return section[:insert_at] + "\n" + new_entry + "\n" + section[insert_at:], "added"
    old = section[span[0] : span[1]]
    cur_seed = 0
    m = re.search(r'\["seedUid"\]\s*=\s*(\d+)', old)
    if m:
        cur_seed = int(m.group(1))
    if cur_seed == seed_uid and f'["{seed_uid}"]' in old:
        return section, "ok"
    return section[: span[0]] + new_entry + section[span[1] :], "updated"


def validate_sv(text: str) -> None:
    logical = text.rstrip(" \t\r\n\x00")
    if "},," in logical:
        raise SystemExit("validation failed: },, present")
    brace = logical.count("{") - logical.count("}")
    if brace != 0:
        raise SystemExit(f"validation failed: brace imbalance={brace}")
    for name in ("grows", "refines", "recipes", "potions", "items"):
        if not re.search(rf"\b{name}\s*=\s*\{{", logical):
            raise SystemExit(f"validation failed: missing section {name}")


def main() -> None:
    if not ACCOUNT_SV.is_file():
        raise SystemExit(f"missing {ACCOUNT_SV}")
    original = ACCOUNT_SV.read_text(encoding="utf-8", errors="replace")
    validate_sv(original)

    grow_a, grow_b = section_span(original, "grows")
    ref_a, ref_b = section_span(original, "refines")
    grows = original[grow_a:grow_b]
    refines = original[ref_a:ref_b]

    stats: dict[str, int] = {}

    def bump(k: str) -> None:
        stats[k] = stats.get(k, 0) + 1

    for seed_uid, products in GROW_PRODUCTS.items():
        grows, action = upsert_grow(grows, seed_uid, products)
        bump(f"grow_{action}")

    for plant_uid, seed_uid, samples in REFINE_LINKS:
        refines, action = upsert_refine(refines, plant_uid, seed_uid, samples)
        bump(f"refine_{action}")

    # Reassemble (refines may shift if grows length changed — rebuild from spans on mutated copies)
    # grows/refines are independent slices of original; replace both in one pass.
    if grow_a < ref_a:
        text = original[:grow_a] + grows + original[grow_b:ref_a] + refines + original[ref_b:]
    else:
        text = original[:ref_a] + refines + original[ref_b:grow_a] + grows + original[grow_b:]

    text = text.rstrip(" \t\r\n\x00") + "\n"
    validate_sv(text)

    # Acceptance checks
    for needle in (
        '["3010034"]',
        '["3010035"]',
        '["3020034"]',
        '["3020035"]',
        '["seedUid"] = 3010035',
        '["84240"]',
        '["83504"]',
        '["84241"]',
        '["83505"]',
    ):
        if needle not in text:
            raise SystemExit(f"acceptance failed: missing {needle}")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bak = ACCOUNT_SV.with_suffix(f".lua.bak-climb-repair-{stamp}")
    shutil.copy2(ACCOUNT_SV, bak)
    new_path = ACCOUNT_SV.with_suffix(".lua.new")
    payload = text.encode("utf-8")
    if not payload.endswith(b"\n"):
        payload += b"\n"
    new_path.write_bytes(payload)

    mapped_size = ACCOUNT_SV.stat().st_size
    write_bytes = payload
    if len(write_bytes) < mapped_size:
        # Space-pad (not NUL): Lua loaders that read the full mapped size reject \\0.
        write_bytes = write_bytes + (b" " * (mapped_size - len(write_bytes)))

    written = False
    try:
        with open(ACCOUNT_SV, "r+b") as fh:
            fh.write(write_bytes)
            fh.truncate(len(write_bytes))
        written = True
    except OSError as exc:
        print(f"python r+b failed ({exc}); trying .new + note")

    if not written:
        # Leave .new for apply-scrub.bat / manual copy when a user-mapped section is open.
        print(f"backup: {bak.name}")
        print(f"wrote:  {new_path.name} ({len(payload)} bytes logical)")
        print("stats:", stats)
        print("Apply with: copy /Y SavedVariables.lua.new SavedVariables.lua")
        print("Or padded overwrite while mapped (same size as live file).")
        raise SystemExit(2)

    print(f"backup: {bak.name}")
    print(f"wrote:  {ACCOUNT_SV} ({len(write_bytes)} bytes, logical {len(payload)})")
    print("stats:", stats)
    print("brace balance:", text.count("{") - text.count("}"))


if __name__ == "__main__":
    main()
