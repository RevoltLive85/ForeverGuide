#!/usr/bin/env python3
"""
Fold in-game step edits ("/fg edit here|npc|note|radius") into the guide sources.

    python tools/apply_edits.py                 # every ForeverGuide.lua(.bak) under WTF\\Account
    python tools/apply_edits.py <file> [...]    # specific SavedVariables files
    python tools/apply_edits.py --dry-run ...   # only print what would change

Reads ForeverGuideDB.edits[guideID][stepIndex] and rewrites the matching step
in guides-src/<guideID>.json (map/x/y/zone, npc/npcName, note, radius). An edit
is skipped when the guide's version changed since it was made or the step no
longer has the same type/quest. Run tools/compile_guides.py afterwards.
"""

import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import foreverdb  # noqa: E402
from merge_recorded import DEFAULT_WTF  # noqa: E402

SRC = os.path.join(foreverdb.ROOT, "guides-src")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    files = args or glob.glob(os.path.join(DEFAULT_WTF, "*", "SavedVariables", "ForeverGuide.lua*"))
    if not files:
        print("no SavedVariables files found; pass them as arguments")
        return 1
    applied, skipped = 0, 0
    touched = {}
    for f in files:
        sv, _ = foreverdb.load_saved_variables(f)
        for guide_id, steps in ((sv or {}).get("edits") or {}).items():
            if not isinstance(steps, dict):
                continue
            path = os.path.join(SRC, "%s.json" % guide_id)
            if not os.path.isfile(path):
                print("  %s: no source file, skipped" % guide_id)
                skipped += 1
                continue
            g = touched.get(path)
            if g is None:
                with open(path, "r", encoding="utf-8") as fh:
                    g = json.load(fh)
                touched[path] = g
            for idx, e in steps.items():
                if not isinstance(e, dict) or not isinstance(idx, (int, float)):
                    continue
                i = int(idx) - 1
                if i < 0 or i >= len(g.get("steps", [])):
                    skipped += 1
                    continue
                step = g["steps"][i]
                if e.get("version") not in (None, g.get("version")) or e.get("type") != step.get("type") or e.get("quest") != step.get("quest"):
                    print("  %s step %d: guide changed since the edit, skipped" % (guide_id, i + 1))
                    skipped += 1
                    continue
                changes = []
                if e.get("x") is not None:
                    step["map"], step["x"], step["y"] = int(e["map"]), round(float(e["x"]), 2), round(float(e["y"]), 2)
                    if e.get("zone"):
                        step["zone"] = e["zone"]
                    changes.append("pos %.1f,%.1f" % (step["x"], step["y"]))
                if e.get("npc"):
                    step["npc"] = int(e["npc"])
                    if e.get("npcName"):
                        step["npcName"] = e["npcName"]
                    changes.append("npc %s" % step["npc"])
                if e.get("note"):
                    step["note"] = e["note"]
                    changes.append("note")
                if e.get("radius"):
                    step["radius"] = int(e["radius"])
                    changes.append("radius %s" % step["radius"])
                if changes:
                    print("  %s step %d: %s" % (guide_id, i + 1, ", ".join(changes)))
                    applied += 1
    if not dry:
        for path, g in touched.items():
            with open(path, "w", encoding="utf-8", newline="\n") as fh:
                json.dump(g, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
    print("%d edit(s) applied, %d skipped%s. Now: python tools/compile_guides.py" % (applied, skipped, " (dry run)" if dry else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
