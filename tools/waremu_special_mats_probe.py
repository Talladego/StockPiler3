#!/usr/bin/env python3
"""Probe waremu GraphQL for liniment / hybrid / infertile special apo materials.

Run:
  python tools/waremu_special_mats_probe.py

Writes tools/out/waremu_special_mats_report.json and tools/out/uid_tables.lua snippet.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.request
from collections import Counter
from pathlib import Path

URI = "https://production-api.waremu.com/graphql/"
UA = "Mozilla/5.0 StockPiler3-waremu-probe/1.0"
PAGE = 50

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "out"


def gql(query: str, variables: dict | None = None) -> dict:
    payload: dict = {"query": query}
    if variables is not None:
        payload["variables"] = variables
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        URI,
        data=data,
        headers={
            "Content-Type": "application/json",
            "User-Agent": UA,
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_all(where_expr: str, label: str = "") -> list[dict]:
    nodes: list[dict] = []
    after = None
    while True:
        after_arg = f', after: "{after}"' if after else ""
        q = (
            f"query {{ items(where: {where_expr}, first: {PAGE}{after_arg}) {{ "
            f"totalCount pageInfo {{ hasNextPage endCursor }} "
            f"nodes {{ id name description type rarity itemLevel }} }} }}"
        )
        r = gql(q)
        if r.get("errors"):
            raise RuntimeError(f"{label}: {r['errors']}")
        conn = r["data"]["items"]
        nodes.extend(conn.get("nodes") or [])
        total = conn.get("totalCount")
        print(f"[{label}] {len(nodes)}/{total}", flush=True)
        if not conn["pageInfo"]["hasNextPage"]:
            break
        after = conn["pageInfo"]["endCursor"]
        time.sleep(0.08)
    return nodes


def fetch_potion_names() -> list[dict]:
    nodes: list[dict] = []
    after = None
    while True:
        after_arg = f', after: "{after}"' if after else ""
        q = (
            f"query {{ items(where: {{ type: {{ eq: POTION }} }}, first: {PAGE}{after_arg}) {{ "
            f"totalCount pageInfo {{ hasNextPage endCursor }} nodes {{ id name }} }} }}"
        )
        r = gql(q)
        if r.get("errors"):
            raise RuntimeError(r["errors"])
        conn = r["data"]["items"]
        nodes.extend(conn.get("nodes") or [])
        if len(nodes) % 500 == 0 or not conn["pageInfo"]["hasNextPage"]:
            print(f"[potions] {len(nodes)}/{conn['totalCount']}", flush=True)
        if not conn["pageInfo"]["hasNextPage"]:
            break
        after = conn["pageInfo"]["endCursor"]
        time.sleep(0.05)
    return nodes


def potion_families(nodes: list[dict]) -> dict[str, int]:
    families: Counter[str] = Counter()
    keys = [
        ("liniment", "liniment"),
        ("unguent", "unguent"),
        ("draught", "draught"),
        ("elixir", "elixir"),
        ("tonic", "tonic"),
        ("salve", "salve"),
        ("balm", "balm"),
        ("potion", "potion"),
        ("concoction", "concoction"),
        ("concotion", "concoction"),
        ("bomb", "bomb"),
        ("flask", "flask"),
        ("brew", "brew"),
        ("stimulant", "stimulant"),
        ("hybrid", "hybrid"),
    ]
    for n in nodes:
        nl = (n.get("name") or "").lower()
        fam = "other"
        for needle, label in keys:
            if needle in nl:
                fam = label
                break
        families[fam] += 1
    return dict(families.most_common())


def classify_special(nodes: list[dict]) -> dict[str, list[dict]]:
    buckets = {
        "hybrid_main": [],
        "liniment_main": [],
        "other_special": [],
    }
    for n in nodes:
        d = (n.get("description") or "").lower()
        row = {
            "id": int(n["id"]),
            "name": n.get("name"),
            "type": n.get("type"),
            "description": n.get("description"),
        }
        if "create hybrid" in d:
            buckets["hybrid_main"].append(row)
        elif "liniment" in d:
            buckets["liniment_main"].append(row)
        else:
            buckets["other_special"].append(row)
    return buckets


def lua_uid_table(name: str, uids: list[int], comment: str) -> str:
    lines = [f"-- {comment}", f"local {name} = {{"]
    for uid in sorted(uids):
        lines.append(f"    [{uid}] = true,")
    lines.append("}")
    return "\n".join(lines)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)

    searches = {
        "name_Liniment": '{ name: { contains: "Liniment" } }',
        "very_special": '{ description: { contains: "very special ingredient" } }',
        "infertile": '{ description: { contains: "infertile" } }',
        "eternal_magical": '{ description: { contains: "regrows its ingredients" } }',
        "Bloodseed": '{ name: { contains: "Bloodseed" } }',
        "create_Liniment": '{ description: { contains: "create a Liniment" } }',
        "create_Liniments": '{ description: { contains: "create Liniments" } }',
        "create_hybrid": '{ description: { contains: "create hybrid potions" } }',
    }

    report: dict = {"searches": {}, "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    for label, where in searches.items():
        nodes = fetch_all(where, label=label)
        report["searches"][label] = {
            "total": len(nodes),
            "nodes": nodes,
        }

    special = classify_special(report["searches"]["very_special"]["nodes"])
    report["specialBuckets"] = {
        k: [{"id": x["id"], "name": x["name"]} for x in v] for k, v in special.items()
    }

    potions = fetch_potion_names()
    report["potionFamilies"] = potion_families(potions)
    report["potionTotal"] = len(potions)

    infertile_uids = [int(n["id"]) for n in report["searches"]["infertile"]["nodes"]]
    eternal_uids = [int(n["id"]) for n in report["searches"]["eternal_magical"]["nodes"]]
    exceptional_uids = [
        int(n["id"])
        for n in report["searches"]["Bloodseed"]["nodes"]
        if "exceptional" in (n.get("name") or "").lower()
    ]
    force_uids = sorted(
        {x["id"] for x in special["hybrid_main"]}
        | {x["id"] for x in special["liniment_main"]}
    )

    report["uidTables"] = {
        "INFERTILE_SEED_UID": infertile_uids,
        "ETERNAL_SEED_UID": eternal_uids,
        "EXCEPTIONAL_SEED_UID": exceptional_uids,
        "FORCE_NOT_REFINABLE_SPECIAL_MAIN_UID": force_uids,
    }

    report_path = OUT / "waremu_special_mats_report.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Wrote {report_path}", flush=True)

    lua = "\n\n".join(
        [
            lua_uid_table(
                "INFERTILE_SEED_UID",
                infertile_uids,
                "One-shot hybrid seeds (infertile for sustainable regrowth).",
            ),
            lua_uid_table(
                "ETERNAL_SEED_UID",
                eternal_uids,
                "Permanent purple Eternal seeds.",
            ),
            lua_uid_table(
                "EXCEPTIONAL_SEED_UID",
                exceptional_uids,
                "Charged Exceptional Bloodseeds (~250 grows).",
            ),
            lua_uid_table(
                "FORCE_NOT_REFINABLE_SPECIAL_MAIN_UID",
                force_uids,
                "Hybrid / liniment-ingredient mains (very special ingredient).",
            ),
        ]
    )
    lua_path = OUT / "uid_tables.lua"
    lua_path.write_text(lua + "\n", encoding="utf-8")
    print(f"Wrote {lua_path}", flush=True)

    print("\n=== summary ===")
    print("potion families:", report["potionFamilies"])
    print("infertile seeds:", len(infertile_uids), infertile_uids)
    print("eternal seeds:", len(eternal_uids))
    print("exceptional bloodseeds:", len(exceptional_uids))
    print("special mains (force not refinable):", len(force_uids))
    print("hybrid mains:", len(special["hybrid_main"]))
    print("liniment mains:", len(special["liniment_main"]))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print("FAIL:", exc, file=sys.stderr)
        raise
