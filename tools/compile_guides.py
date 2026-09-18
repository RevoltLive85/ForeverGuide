#!/usr/bin/env python3
"""
ForeverGuide guide compiler.

    guides-src/*.json  ->  Guides/<ID>.lua  +  Guides/Guides.xml

Usage (from the addon folder, or anywhere):
    python tools/compile_guides.py            # compile everything
    python tools/compile_guides.py --check    # validate only, write nothing
    python tools/compile_guides.py --src guides-src --out Guides

No dependencies beyond the Python standard library.
"""

import argparse
import json
import os
import re
import sys

STEP_TYPES = {
    "ACCEPT", "TURNIN", "COMPLETE", "KILL", "COLLECT", "GRIND", "BUY", "TRAIN",
    "HEARTH", "TRAVEL", "FLY", "TALK", "NOTE",
}
REQUIRES = {
    "ACCEPT": ["quest"], "TURNIN": ["quest"], "COMPLETE": ["quest"], "KILL": ["quest"],
    "COLLECT": ["quest"], "GRIND": ["level"], "BUY": ["item"], "TRAIN": ["spell"],
    "HEARTH": ["zone"], "TRAVEL": ["x", "y"], "FLY": ["x", "y"], "TALK": ["npc"], "NOTE": ["text"],
}
STEP_FIELDS = {
    "type": str, "text": str, "note": str, "quest": int, "questName": str, "objective": int,
    "npc": int, "npcName": str, "target": str, "count": int, "item": int, "itemName": str,
    "spell": int, "spellName": str, "level": int, "map": int, "zone": str, "x": (int, float),
    "y": (int, float), "radius": (int, float), "optional": bool, "near": bool, "faction": str,
    "class": list, "race": list,
}
GUIDE_FIELDS = {
    "id": str, "name": str, "version": int, "faction": str, "race": list, "class": list,
    "minLevel": int, "maxLevel": int, "map": int, "zone": str, "next": str, "author": str, "notes": str, "steps": list,
}
ID_RE = re.compile(r"^[A-Z0-9_]+$")


class GuideError(Exception):
    pass


# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------
def check_type(where, value, expected):
    if expected is int:
        ok = isinstance(value, int) and not isinstance(value, bool)
    elif expected is bool:
        ok = isinstance(value, bool)
    elif isinstance(expected, tuple):
        ok = isinstance(value, expected) and not isinstance(value, bool)
    else:
        ok = isinstance(value, expected)
    if not ok:
        raise GuideError(f"{where}: expected {expected}, got {value!r}")


def validate(guide, filename):
    if not isinstance(guide, dict):
        raise GuideError(f"{filename}: top level must be an object")
    for key in ("id", "name", "steps"):
        if key not in guide:
            raise GuideError(f"{filename}: missing '{key}'")
    for key, value in guide.items():
        if key not in GUIDE_FIELDS:
            raise GuideError(f"{filename}: unknown guide field '{key}'")
        check_type(f"{filename}: {key}", value, GUIDE_FIELDS[key])
    if not ID_RE.match(guide["id"]):
        raise GuideError(f"{filename}: id '{guide['id']}' must match [A-Z0-9_]+")
    if not guide["steps"]:
        raise GuideError(f"{filename}: no steps")

    for i, step in enumerate(guide["steps"], start=1):
        where = f"{filename} step {i}"
        if not isinstance(step, dict):
            raise GuideError(f"{where}: must be an object")
        stype = str(step.get("type", "NOTE")).upper()
        if stype not in STEP_TYPES:
            raise GuideError(f"{where}: unknown type '{stype}'")
        step["type"] = stype
        for key, value in step.items():
            if key not in STEP_FIELDS:
                raise GuideError(f"{where}: unknown field '{key}'")
            check_type(f"{where}: {key}", value, STEP_FIELDS[key])
        for req in REQUIRES[stype]:
            if req not in step:
                raise GuideError(f"{where} ({stype}): missing '{req}'")
        if ("x" in step) != ("y" in step):
            raise GuideError(f"{where}: x and y must be given together")
        if "x" in step and not (0 <= step["x"] <= 100 and 0 <= step["y"] <= 100):
            raise GuideError(f"{where}: coordinates must be 0-100")
        if "x" in step and "map" not in step and "zone" not in step:
            raise GuideError(f"{where}: coordinates need 'map' or 'zone'")
        for listkey in ("class", "race"):
            if listkey in step and not all(isinstance(v, str) for v in step[listkey]):
                raise GuideError(f"{where}: {listkey} must be a list of strings")
        if "class" in step:
            step["class"] = [c.upper() for c in step["class"]]
    if "class" in guide:
        guide["class"] = [c.upper() for c in guide["class"]]
    return guide


# ------------------------------------------------------------
# Lua serialisation
# ------------------------------------------------------------
KEY_ORDER = ["type", "quest", "questName", "objective", "npc", "npcName", "target", "count", "item",
             "itemName", "spell", "spellName", "level", "map", "zone", "x", "y", "radius", "optional", "near",
             "faction", "class", "race", "text", "note"]


def lua_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def lua_value(v, indent=0):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        return lua_string(v)
    if isinstance(v, list):
        return "{ " + ", ".join(lua_value(x, indent) for x in v) + " }"
    if isinstance(v, dict):
        keys = [k for k in KEY_ORDER if k in v] + sorted(k for k in v if k not in KEY_ORDER)
        parts = [f"{k} = {lua_value(v[k], indent)}" for k in keys]
        return "{ " + ", ".join(parts) + " }"
    raise GuideError(f"cannot serialise {v!r}")


def compile_guide(guide):
    lines = [
        "-- AUTO-GENERATED by tools/compile_guides.py from guides-src/%s.json - DO NOT EDIT" % guide["id"],
        "local _, ns = ...",
        "ns.RegisterGuide({",
    ]
    for key in ("id", "name", "version", "faction", "race", "class", "minLevel", "maxLevel", "map", "zone", "next", "author", "notes"):
        if key in guide:
            lines.append(f"    {key} = {lua_value(guide[key])},")
    lines.append("    steps = {")
    for i, step in enumerate(guide["steps"], start=1):
        lines.append(f"        {lua_value(step)}, -- {i}")
    lines.append("    },")
    lines.append("})")
    return "\n".join(lines) + "\n"


def compile_xml(ids):
    lines = ['<Ui xmlns="http://www.blizzard.com/wow/ui/">',
             "    <!-- AUTO-GENERATED by tools/compile_guides.py - lists every compiled guide -->"]
    for gid in ids:
        lines.append(f'    <Script file="{gid}.lua"/>')
    lines.append("</Ui>")
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    ap = argparse.ArgumentParser(description="Compile ForeverGuide JSON guides to Lua.")
    ap.add_argument("--src", default=os.path.join(root, "guides-src"))
    ap.add_argument("--out", default=os.path.join(root, "Guides"))
    ap.add_argument("--check", action="store_true", help="validate only")
    args = ap.parse_args()

    files = sorted(f for f in os.listdir(args.src) if f.lower().endswith(".json") and not f.startswith("_"))
    if not files:
        print(f"no guide files in {args.src}")
        return 1

    guides, errors = [], 0
    for fn in files:
        path = os.path.join(args.src, fn)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            guide = validate(data, fn)
            expected = guide["id"] + ".json"
            if fn != expected:
                raise GuideError(f"{fn}: file must be named {expected}")
            guides.append(guide)
            print(f"ok   {fn}: {guide['name']} ({len(guide['steps'])} steps)")
        except (GuideError, json.JSONDecodeError) as e:
            errors += 1
            print(f"FAIL {fn}: {e}")

    ids = [g["id"] for g in guides]
    if len(ids) != len(set(ids)):
        print("FAIL duplicate guide ids")
        errors += 1
    known = set(ids)
    for g in guides:
        if "next" in g and g["next"] not in known:
            print(f"warn {g['id']}: next guide '{g['next']}' is not compiled (fine if it lives in another addon)")

    if errors:
        print(f"{errors} error(s), nothing written")
        return 1
    if args.check:
        print("all guides valid")
        return 0

    os.makedirs(args.out, exist_ok=True)
    for g in guides:
        out = os.path.join(args.out, g["id"] + ".lua")
        with open(out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(compile_guide(g))
    with open(os.path.join(args.out, "Guides.xml"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(compile_xml(ids))
    # remove stale compiled guides
    for fn in os.listdir(args.out):
        if fn.endswith(".lua") and fn[:-4] not in known:
            os.remove(os.path.join(args.out, fn))
            print(f"removed stale {fn}")
    print(f"wrote {len(guides)} guide(s) to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
