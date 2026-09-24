#!/usr/bin/env python3
"""
Collect "/fg wrong" reports from SavedVariables into one review file.

    python tools/collect_reports.py                 # every ForeverGuide.lua(.bak) under WTF\\Account
    python tools/collect_reports.py <file> [...]    # specific SavedVariables files

Writes data-src/reports.json (all reports, de-duplicated) and prints them
grouped by guide / quest, with the step's expected location next to where
the player actually was, so a route or database correction is a copy-paste
away:
    guides-src/GEN_*.json    fix the step, then  python tools/compile_guides.py
    data-src/forever.json    fix npc/objective points, then  python tools/merge_recorded.py
"""

import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import foreverdb  # noqa: E402
from merge_recorded import DEFAULT_WTF  # noqa: E402

OUT = os.path.join(foreverdb.ROOT, "data-src", "reports.json")


def main():
    files = sys.argv[1:] or glob.glob(os.path.join(DEFAULT_WTF, "*", "SavedVariables", "ForeverGuide.lua*"))
    if not files:
        print("no SavedVariables files found; pass them as arguments")
        return 1
    seen = {}
    if os.path.isfile(OUT):
        with open(OUT, "r", encoding="utf-8") as fh:
            for r in json.load(fh):
                r.pop("file", None)  # older exports included the account folder name
                seen[r.get("key")] = r
    for f in files:
        sv, _ = foreverdb.load_saved_variables(f)
        for r in foreverdb.as_list((sv or {}).get("reports")):
            if not isinstance(r, dict):
                continue
            key = "%s|%s|%s|%s" % (r.get("t"), r.get("guide") or r.get("mode"), r.get("step"), r.get("q"))
            r = dict(r)
            r.pop("file", None)
            r["key"] = key
            if "loc" in r and isinstance(r["loc"], dict):
                r["loc"] = {k: v for k, v in r["loc"].items()}
            seen[key] = r
    reports = sorted(seen.values(), key=lambda r: (r.get("guide") or "", r.get("step") or 0, r.get("t") or 0))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(reports, fh, indent=1, ensure_ascii=False)
    if not reports:
        print("no reports")
        return 0
    last = None
    for r in reports:
        head = r.get("guide") or ("auto mode" if r.get("mode") == "auto" else "?")
        if head != last:
            print("\n== %s" % head)
            last = head
        loc = r.get("loc") or {}
        print("  step %-4s %-8s quest %-6s %s" % (r.get("step") or "-", r.get("type") or r.get("what") or "", r.get("q") or "-", ('"%s"' % r["text"]) if r.get("text") else ""))
        print("      expected: map %s %.1f,%.1f%s" % (loc.get("m"), loc.get("x") or 0, loc.get("y") or 0, (" (%s %s)" % (loc.get("kind"), loc.get("id"))) if loc.get("id") else ""))
        print("      player:   map %s %.1f,%.1f  %s%s  lvl %s%s" % (r.get("m"), r.get("x") or 0, r.get("y") or 0, r.get("zone") or "", (" / " + r["sub"]) if r.get("sub") else "", r.get("lvl"),
              ("  target %s (%s)" % (r.get("npcName"), r.get("npc"))) if r.get("npc") else ""))
    print("\n%d report(s) -> %s" % (len(reports), os.path.relpath(OUT, foreverdb.ROOT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
