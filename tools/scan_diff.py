#!/usr/bin/env python3
"""
Compare the in-game quest ID scan (/fg scan) with Questie's Classic quest DB.

    python tools/scan_diff.py                       # auto-finds ForeverGuide.lua under WTF\Account\*\SavedVariables
    python tools/scan_diff.py --sv <path\ForeverGuide.lua> --questie <Questie folder>
    python tools/scan_diff.py --out new_quests.json # also write the new quests (id -> title) as JSON

Prints:
  * quests the server knows that Questie's vanilla DB does not  -> Forever's NEW quests
  * vanilla quests the server does not know                     -> removed / not yet scanned
  * quests whose title changed
Reads only.
"""

import argparse
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from questie_lookup import LuaParser, load_db, QUEST_KEYS, DEFAULT_QUESTIE  # noqa: E402

DEFAULT_WTF = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF\Account"


def find_saved_variables():
    hits = glob.glob(os.path.join(DEFAULT_WTF, "*", "SavedVariables", "ForeverGuide.lua"))
    return hits[0] if hits else None


def load_scan(path):
    """Extract ForeverGuideDB.scan from the SavedVariables file."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    m = re.search(r"ForeverGuideDB\s*=\s*", text)
    if not m:
        raise SystemExit("ForeverGuideDB not found in " + path)
    db = LuaParser(text[m.end():]).value()
    scan = db.get("scan") if isinstance(db, dict) else None
    if not scan or not scan.get("quests"):
        raise SystemExit("no scan data in the file - run /fg scan or /fg harvest in game and /reload first")
    quests = {int(k): v for k, v in scan["quests"].items() if isinstance(k, (int, float))}
    harvest = db.get("harvest") if isinstance(db, dict) else None
    scan["_lines"] = {int(k): v for k, v in ((harvest or {}).get("lines") or {}).items() if isinstance(k, (int, float))}
    return scan, quests


PLACEHOLDER = re.compile(r"^\s*(None|<[^>]*>.*|.*\(\d+\)aa|\[DEPRECATED\].*|TEST.*|test.*|DEPRECATED.*)\s*$", re.I)


def is_placeholder(title):
    return not title or PLACEHOLDER.match(title) is not None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sv", default=None, help="path to ForeverGuide.lua (SavedVariables)")
    ap.add_argument("--questie", default=os.environ.get("QUESTIE", DEFAULT_QUESTIE))
    ap.add_argument("--out", default=None, help="write new quests as JSON")
    ap.add_argument("--limit", type=int, default=60, help="max lines per list to print")
    args = ap.parse_args()

    sv = args.sv or find_saved_variables()
    if not sv or not os.path.isfile(sv):
        raise SystemExit("SavedVariables file not found; pass --sv")
    scan, server = load_scan(sv)
    ranges = scan.get("ranges") or ([scan["range"]] if scan.get("range") else [])
    ranges = [(r.get(1), r.get(2)) if isinstance(r, dict) else (r[0], r[1]) for r in ranges]
    missing = {int(k) for k in (scan.get("missing") or {}) if isinstance(k, (int, float))}
    unanswered = {int(k) for k in (scan.get("unanswered") or {}) if isinstance(k, (int, float))}
    print(f"scan from {sv}: build {scan.get('build')}, ranges {ranges}, {len(server)} quests exist, "
          f"{len(missing)} ids do not, {len(unanswered)} unanswered, done={scan.get('done')}")

    questie = load_db(os.path.join(args.questie, "Database", "Classic", "classicQuestDB.lua"), QUEST_KEYS)
    vanilla = {qid: rec.get("name", "") for qid, rec in questie.items()}
    print(f"questie classic DB: {len(vanilla)} quests")

    def in_range(q):
        return not ranges or any((lo is None or q >= lo) and (hi is None or q <= hi) for lo, hi in ranges)

    new = {q: t for q, t in server.items() if q not in vanilla and not is_placeholder(t)}
    placeholders = {q: t for q, t in server.items() if q not in vanilla and is_placeholder(t)}
    confirmed_gone = {q: t for q, t in vanilla.items() if q in missing}
    unknown = {q: t for q, t in vanilla.items() if in_range(q) and q not in server and q not in missing}
    renamed = {q: (vanilla[q], server[q]) for q in server if q in vanilla and server[q] and vanilla[q] != server[q]}

    def show(title, items, fmt):
        print(f"\n== {title}: {len(items)} ==")
        for i, (q, v) in enumerate(sorted(items.items())):
            if i >= args.limit:
                print(f"   ... {len(items) - args.limit} more")
                break
            print("   " + fmt(q, v))

    show("NEW on Forever (not in Questie vanilla)", new, lambda q, t: f"{q}: {t}")
    show("vanilla quests the server says do NOT exist (removed)", confirmed_gone, lambda q, t: f"{q}: {t}")
    show("vanilla quests with no answer yet (scan incomplete - /fg scan resume)", unknown, lambda q, t: f"{q}: {t}")
    show("title changed", renamed, lambda q, v: f"{q}: {v[0]!r} -> {v[1]!r}")
    show("placeholder rows (exist on the server, not real quests)", placeholders, lambda q, t: f"{q}: {t}")

    lines = scan.get("_lines") or {}
    if lines:
        with_pos = sum(1 for q in new if q in lines and lines[q].get("x") is not None)
        print(f"\n{len(lines)} quest-line positions harvested; {with_pos} of the new quests have a start position")
    if args.out:
        out = {}
        for q, t in sorted(new.items()):
            rec = {"title": t}
            if q in lines:
                rec.update({k: v for k, v in lines[q].items() if v is not None})
            out[str(q)] = rec
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(out, fh, indent=2, ensure_ascii=False)
        print(f"wrote {len(new)} new quests to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
