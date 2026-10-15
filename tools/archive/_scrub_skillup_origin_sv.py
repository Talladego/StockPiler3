#!/usr/bin/env python3
"""Offline scrub: remove unwatched skillUpOrigin recipes/potions from Account SV.

Does not live in the addon runtime. Client must be shut down.
"""
from __future__ import annotations

import re
import shutil
from datetime import datetime
from pathlib import Path

ACCOUNT_SV = Path(
    r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3\SavedVariables.lua"
)
SETTINGS_SV = Path(
    r"C:\Games\Return of Reckoning\user\settings\Martyrs Square"
    r"\SharedProfile\SharedProfile\StockPiler3\SavedVariables.lua"
)
PRE_SCRUB_BAK = Path(
    r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler3"
    r"\SavedVariables.lua.bak-skillup-scrub-20260921"
)

LSTR = re.compile(r'L"((?:\\.|[^"\\])*)"')
TABLE_KEY = re.compile(r'\[["\']([^"\']+)["\']\]\s*=')


def extract_lstrings(text: str) -> list[str]:
    return [m.group(1) for m in LSTR.finditer(text)]


def watched_recipe_keys(settings_text: str) -> set[str]:
    watched: set[str] = set()
    for m in re.finditer(r"watches\s*=\s*\{", settings_text):
        start = m.end()
        depth = 1
        i = start
        while i < len(settings_text) and depth > 0:
            ch = settings_text[i]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            i += 1
        block = settings_text[start : i - 1]
        for key in TABLE_KEY.findall(block):
            if "|rk:" in key:
                watched.add(key.split("|rk:", 1)[1])
            else:
                watched.add(key)
    return watched


def find_balanced_table(text: str, open_brace: int) -> tuple[int, int]:
    """Return [start, end) spanning the {...} that begins at open_brace."""
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
            if ch == '"' and i > 0 and text[i - 1] == "L":
                in_string = True
                quote = '"'
            elif ch == '"':
                in_string = True
                quote = '"'
            elif ch == "'":
                in_string = True
                quote = "'"
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


def section_span(text: str, name: str) -> tuple[int, int] | None:
    m = re.search(rf"\b{name}\s*=\s*\{{", text)
    if not m:
        return None
    brace = text.find("{", m.start())
    return find_balanced_table(text, brace)


def top_level_entries(section_text: str) -> list[tuple[str, int, int]]:
    """Parse top-level [\"key\"] = { ... }, entries inside a section body."""
    body_start = section_text.find("{") + 1
    body = section_text
    entries: list[tuple[str, int, int]] = []
    i = body_start
    while i < len(body) - 1:
        while i < len(body) and body[i] in " \t\r\n,":
            i += 1
        if i >= len(body) or body[i] == "}":
            break
        km = re.match(r'\[["\']([^"\']+)["\']\]\s*=\s*\{', body[i:])
        if not km:
            i += 1
            continue
        key = km.group(1)
        brace_abs = i + km.end() - 1
        s, e = find_balanced_table(body, brace_abs)
        end = e
        if end < len(body) and body[end] == ",":
            end += 1
        while end < len(body) and body[end] in "\r\n":
            end += 1
        entries.append((key, i, end))
        i = end
    return entries


def rebuild_section(section_text: str, kept_entries: list[str]) -> str:
    """Rebuild `{...}` only — no trailing comma (comma lives outside the span)."""
    parts = ["{\n"]
    for entry in kept_entries:
        if not entry.endswith("\n"):
            entry = entry + "\n"
        # Ensure entry starts with tab indent like stock SV (\t\t["key"])
        if entry.lstrip().startswith("[") and not entry.startswith("\t"):
            entry = "\t\t" + entry.lstrip()
        parts.append(entry)
    parts.append("\t}")
    return "".join(parts)


def scrub(account_text: str, watched: set[str]) -> tuple[str, dict]:
    account_text = account_text.rstrip(" \t\r\n\x00")
    if not account_text.endswith("\n"):
        account_text += "\n"

    recipes_span = section_span(account_text, "recipes")
    potions_span = section_span(account_text, "potions")
    if not recipes_span:
        raise SystemExit("recipes section not found")
    if not potions_span:
        raise SystemExit("potions section not found")

    stats = {
        "recipes_deleted": 0,
        "recipes_kept_watched": 0,
        "potions_deleted": 0,
        "potion_links_removed": 0,
        "potion_flags_cleared": 0,
        "deleted_fps": [],
    }

    r_start, r_end = recipes_span
    recipes_block = account_text[r_start:r_end]
    recipe_entries = top_level_entries(recipes_block)
    deleted: set[str] = set()
    kept_recipes: list[str] = []

    for key, s, e in recipe_entries:
        entry = recipes_block[s:e]
        is_skill = '["skillUpOrigin"] = true' in entry or "['skillUpOrigin'] = true" in entry
        if is_skill and key not in watched:
            deleted.add(key)
            stats["recipes_deleted"] += 1
            stats["deleted_fps"].append(key[:80])
            continue
        if is_skill and key in watched:
            stats["recipes_kept_watched"] += 1
        kept_recipes.append(entry)

    new_recipes = rebuild_section(recipes_block, kept_recipes)
    account_text = account_text[:r_start] + new_recipes + account_text[r_end:]

    potions_span = section_span(account_text, "potions")
    assert potions_span
    p_start, p_end = potions_span
    potions_block = account_text[p_start:p_end]
    potion_entries = top_level_entries(potions_block)
    kept_potions: list[str] = []

    for key, s, e in potion_entries:
        entry = potions_block[s:e]
        new_entry = entry
        for fp in list(deleted):
            pat = re.compile(
                r"^[ \t]*L\"" + re.escape(fp) + r"\",?[ \t]*\r?\n",
                re.M,
            )
            new_entry2, n = pat.subn("", new_entry)
            if n:
                stats["potion_links_removed"] += n
                new_entry = new_entry2
            for field in (
                "recipeSpecKey",
                "activeRecipeKey",
                "activeRecipeSpecKey",
            ):
                field_pat = re.compile(
                    rf'(\["{field}"\]\s*=\s*)L"{re.escape(fp)}",'
                )
                if field_pat.search(new_entry):
                    new_entry = field_pat.sub("", new_entry)
                    stats["potion_links_removed"] += 1

        keys_m = re.search(r'\["recipeKeys"\]\s*=\s*\{(.*?)\},', new_entry, re.S)
        remaining: list[str] = []
        if keys_m:
            remaining = extract_lstrings(keys_m.group(1))

        is_skill_potion = (
            '["skillUpOrigin"] = true' in new_entry
            or "['skillUpOrigin'] = true" in new_entry
        )

        if not remaining and (is_skill_potion or any(fp in entry for fp in deleted)):
            stats["potions_deleted"] += 1
            continue

        if is_skill_potion and remaining:
            new_entry2 = re.sub(
                r'^[ \t]*\["skillUpOrigin"\]\s*=\s*true,?[ \t]*\r?\n',
                "",
                new_entry,
                flags=re.M,
            )
            if new_entry2 != new_entry:
                stats["potion_flags_cleared"] += 1
                new_entry = new_entry2

        if remaining:
            if not re.search(r'\["recipeSpecKey"\]\s*=', new_entry):
                new_entry = re.sub(
                    r'(\["potionKey"\]\s*=\s*L"[^"]*",)',
                    rf'\1\n\t\t\t["recipeSpecKey"] = L"{remaining[0]}",',
                    new_entry,
                    count=1,
                )
            if not re.search(r'\["activeRecipeKey"\]\s*=', new_entry):
                new_entry = re.sub(
                    r'(\["recipeSpecKey"\]\s*=\s*L"[^"]*",)',
                    rf'\1\n\t\t\t["activeRecipeKey"] = L"{remaining[0]}",'
                    rf'\n\t\t\t["activeRecipeSpecKey"] = L"{remaining[0]}",',
                    new_entry,
                    count=1,
                )
            else:
                for field in ("recipeSpecKey", "activeRecipeKey", "activeRecipeSpecKey"):
                    m = re.search(rf'\["{field}"\]\s*=\s*L"([^"]*)"', new_entry)
                    if m and m.group(1) not in remaining:
                        new_entry = re.sub(
                            rf'\["{field}"\]\s*=\s*L"[^"]*"',
                            f'["{field}"] = L"{remaining[0]}"',
                            new_entry,
                            count=1,
                        )

        kept_potions.append(new_entry)

    new_potions = rebuild_section(potions_block, kept_potions)
    account_text = account_text[:p_start] + new_potions + account_text[p_end:]

    account_text = re.sub(
        r'^[ \t]*\["?skillUpOriginLearnScrubV1"?\]\s*=\s*true,?[ \t]*\r?\n',
        "",
        account_text,
        flags=re.M,
    )

    if "},," in account_text:
        raise SystemExit("scrub produced },, — aborting")

    brace = account_text.count("{") - account_text.count("}")
    if brace != 0:
        raise SystemExit(f"scrub brace imbalance={brace} — aborting")

    return account_text, stats


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


def restore_from_backup() -> None:
    if not PRE_SCRUB_BAK.is_file():
        raise SystemExit(f"missing restore backup {PRE_SCRUB_BAK}")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    if ACCOUNT_SV.is_file():
        broken = ACCOUNT_SV.with_suffix(f".lua.broken-{stamp}")
        shutil.copy2(ACCOUNT_SV, broken)
        print(f"saved broken SV as {broken.name}")
    # Full replace (client shut down — truncate/rename OK).
    data = PRE_SCRUB_BAK.read_bytes()
    ACCOUNT_SV.write_bytes(data)
    validate_sv(data.decode("utf-8", errors="replace"))
    print(f"restored {ACCOUNT_SV.name} from {PRE_SCRUB_BAK.name} ({len(data)} bytes)")


def main() -> None:
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--restore-only",
        action="store_true",
        help="Only restore pre-scrub backup; do not scrub",
    )
    ap.add_argument(
        "--no-restore",
        action="store_true",
        help="Scrub current file without restoring first",
    )
    args = ap.parse_args()

    if not args.no_restore:
        restore_from_backup()
    if args.restore_only:
        return

    if not ACCOUNT_SV.is_file():
        raise SystemExit(f"missing {ACCOUNT_SV}")
    settings_text = (
        SETTINGS_SV.read_text(encoding="utf-8", errors="replace")
        if SETTINGS_SV.is_file()
        else ""
    )
    watched = watched_recipe_keys(settings_text)
    print(f"watched recipe fingerprints: {len(watched)}")

    original = ACCOUNT_SV.read_text(encoding="utf-8", errors="replace")
    scrubbed, stats = scrub(original, watched)
    scrubbed = scrubbed.rstrip(" \t\r\n\x00") + "\n"
    validate_sv(scrubbed)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bak = ACCOUNT_SV.with_suffix(f".lua.bak-before-rescrub-{stamp}")
    shutil.copy2(ACCOUNT_SV, bak)
    ACCOUNT_SV.write_text(scrubbed, encoding="utf-8", newline="\n")
    ACCOUNT_SV.with_suffix(".lua.new").write_text(scrubbed, encoding="utf-8", newline="\n")

    print(f"backup: {bak}")
    print(f"wrote:  {ACCOUNT_SV} ({len(scrubbed)} bytes)")
    print(f"recipes_deleted: {stats['recipes_deleted']}")
    print(f"recipes_kept_watched: {stats['recipes_kept_watched']}")
    print(f"potions_deleted: {stats['potions_deleted']}")
    print(f"potion_links_removed: {stats['potion_links_removed']}")
    print(f"potion_flags_cleared: {stats['potion_flags_cleared']}")
    print(f"skillUpOrigin remaining: {scrubbed.count('skillUpOrigin')}")
    print(f"brace balance: {scrubbed.count('{') - scrubbed.count('}')}")
    print(f"}},, count: {scrubbed.count('},,')}")


if __name__ == "__main__":
    main()
