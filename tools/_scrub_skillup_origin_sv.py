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
            # L"..." or plain strings
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
            # skip unknown junk
            i += 1
            continue
        key = km.group(1)
        brace_abs = i + km.end() - 1
        s, e = find_balanced_table(body, brace_abs)
        # include trailing comma/newline if present
        end = e
        if end < len(body) and body[end] == ",":
            end += 1
        while end < len(body) and body[end] in "\r\n":
            end += 1
        entries.append((key, i, end))
        i = end
    return entries


def scrub(account_text: str, watched: set[str]) -> tuple[str, dict]:
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

    # Work potions after recipes; edit from end so offsets stay valid.
    # First collect recipe deletions.
    r_start, r_end = recipes_span
    recipes_block = account_text[r_start:r_end]
    recipe_entries = top_level_entries(recipes_block)
    deleted: set[str] = set()
    keep_recipe_parts: list[str] = []
    # rebuild recipes section
    header_end = recipes_block.find("{") + 1
    keep_recipe_parts.append(recipes_block[:header_end])
    if not keep_recipe_parts[0].endswith("\n"):
        keep_recipe_parts[0] += "\n"

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
        keep_recipe_parts.append(entry if entry.endswith("\n") else entry + "\n")
    keep_recipe_parts.append("\t},")
    new_recipes = "".join(keep_recipe_parts)
    # fix trailing: original ends with },
    if not new_recipes.rstrip().endswith("},"):
        new_recipes = new_recipes.rstrip().rstrip(",") + "\n\t},"

    # Rebuild account with new recipes first (potions offsets change)
    account_text = account_text[:r_start] + new_recipes + account_text[r_end:]

    potions_span = section_span(account_text, "potions")
    assert potions_span
    p_start, p_end = potions_span
    potions_block = account_text[p_start:p_end]
    potion_entries = top_level_entries(potions_block)
    header_end = potions_block.find("{") + 1
    keep_potion_parts: list[str] = [potions_block[:header_end]]
    if not keep_potion_parts[0].endswith("\n"):
        keep_potion_parts[0] += "\n"

    for key, s, e in potion_entries:
        entry = potions_block[s:e]
        # Collect L"..." recipe key strings inside recipeKeys / recipeSpecKey / active*
        # Simpler: strip any L"fp" that is in deleted from the entry text.
        new_entry = entry
        for fp in list(deleted):
            # Remove array lines: \t\t\t\tL"fp",\n
            pat = re.compile(
                r"^[ \t]*L\"" + re.escape(fp) + r"\",?[ \t]*\r?\n",
                re.M,
            )
            new_entry2, n = pat.subn("", new_entry)
            if n:
                stats["potion_links_removed"] += n
                new_entry = new_entry2
            # Clear pointer fields that equal deleted fp
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

        # Remaining recipe key L-strings inside recipeKeys block
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
            # Clear flag if any remaining recipe is not in deleted (user or kept)
            # After scrub, remaining recipes exist in recipes table; if any lack skillUp
            # we can't know from potion alone — clear flag when potion had mixed links
            # and still has remaining keys (user may have re-learned). Safer: clear
            # skillUpOrigin on potion whenever it still has remaining keys after scrub.
            new_entry2 = re.sub(
                r'^[ \t]*\["skillUpOrigin"\]\s*=\s*true,?[ \t]*\r?\n',
                "",
                new_entry,
                flags=re.M,
            )
            if new_entry2 != new_entry:
                stats["potion_flags_cleared"] += 1
                new_entry = new_entry2

        # Fix active/recipeSpecKey if emptied: point to first remaining
        if remaining:
            for field in ("recipeSpecKey", "activeRecipeKey", "activeRecipeSpecKey"):
                if not re.search(rf'\["{field}"\]\s*=', new_entry):
                    # insert after potionKey if missing
                    pass
            # If recipeSpecKey line missing, add from remaining[0]
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
                # rewrite empty-removed pointers already handled; ensure they match remaining
                for field in ("recipeSpecKey", "activeRecipeKey", "activeRecipeSpecKey"):
                    m = re.search(rf'\["{field}"\]\s*=\s*L"([^"]*)"', new_entry)
                    if m and m.group(1) not in remaining:
                        new_entry = re.sub(
                            rf'\["{field}"\]\s*=\s*L"[^"]*"',
                            f'["{field}"] = L"{remaining[0]}"',
                            new_entry,
                            count=1,
                        )

        keep_potion_parts.append(new_entry if new_entry.endswith("\n") else new_entry + "\n")

    keep_potion_parts.append("\t},")
    new_potions = "".join(keep_potion_parts)
    account_text = account_text[:p_start] + new_potions + account_text[p_end:]

    # Drop migrate flag if present (we are not using in-addon scrub)
    account_text = re.sub(
        r'^[ \t]*\["?skillUpOriginLearnScrubV1"?\]\s*=\s*true,?[ \t]*\r?\n',
        "",
        account_text,
        flags=re.M,
    )

    return account_text, stats


def main() -> None:
    if not ACCOUNT_SV.is_file():
        raise SystemExit(f"missing {ACCOUNT_SV}")
    settings_text = (
        SETTINGS_SV.read_text(encoding="utf-8", errors="replace")
        if SETTINGS_SV.is_file()
        else ""
    )
    watched = watched_recipe_keys(settings_text)
    print(f"watched recipe fingerprints: {len(watched)}")

    raw = ACCOUNT_SV.read_bytes()
    target_size = len(raw)
    original = raw.decode("utf-8", errors="replace").rstrip(" \t\r\n\x00")
    scrubbed, stats = scrub(original + "\n", watched)
    scrubbed = scrubbed.rstrip(" \t\r\n\x00") + "\n"
    if len(scrubbed) > target_size:
        raise SystemExit(
            f"scrubbed ({len(scrubbed)}) larger than mapped pad slot ({target_size})"
        )
    padded = (scrubbed + (" " * (target_size - len(scrubbed)))).encode("utf-8")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bak = ACCOUNT_SV.with_suffix(f".lua.bak-skillup-scrub-{stamp}")
    shutil.copy2(ACCOUNT_SV, bak)
    # Same-size overwrite: RoR often keeps SV memory-mapped (no truncate/rename).
    with open(ACCOUNT_SV, "r+b") as f:
        f.write(padded)
        f.flush()
    ACCOUNT_SV.with_suffix(".lua.new").write_bytes(padded)

    print(f"backup: {bak}")
    print(f"wrote:  {ACCOUNT_SV} (padded {target_size})")
    print(f"recipes_deleted: {stats['recipes_deleted']}")
    print(f"recipes_kept_watched: {stats['recipes_kept_watched']}")
    print(f"potions_deleted: {stats['potions_deleted']}")
    print(f"potion_links_removed: {stats['potion_links_removed']}")
    print(f"potion_flags_cleared: {stats['potion_flags_cleared']}")
    logical = ACCOUNT_SV.read_bytes().rstrip(b" \t\r\n\x00").decode("utf-8", errors="replace")
    print(f"skillUpOrigin remaining: {logical.count('skillUpOrigin')}")
    print(f"brace balance: {logical.count('{') - logical.count('}')}")


if __name__ == "__main__":
    main()
