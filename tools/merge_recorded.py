#!/usr/bin/env python3
"""
Fold what the addon recorded in-game into the Forever data overlay.

    python tools/merge_recorded.py                 # every ForeverGuide.lua(.bak) under WTF\\Account
    python tools/merge_recorded.py <file> [...]    # specific SavedVariables files

Reads ForeverGuideDB.recorder.entries (quest accepts / turn-ins / offers /
objective progress with NPC ids and coordinates), .harvest.lines, .scan.quests
and .recorder.maps, merges them into data-src/forever.json and rewrites
Data/ForeverDB.lua. Vanilla quests only gain what the database lacks (Forever
moved or renamed some NPCs); unknown quests become full new entries.

Because the beta sometimes fails to load SavedVariables on login and then
overwrites them, the .bak files and every account/character are read too,
and evidence is only ever added, never removed.
"""

import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import foreverdb  # noqa: E402

DEFAULT_WTF = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF\Account"
PLACEHOLDER = re.compile(r"^\s*(None|<[^>]*>.*|REUSE|reuse|.*\(\d+\)aa|\[DEPRECATED\].*)\s*$", re.I)


def vanilla_ids():
    """Quest / npc ids the vanilla database already knows (from Data/*.lua)."""
    ids = {"quests": set(), "npcs": set()}
    for fn, key in (("QuestDB.lua", "quests"), ("NpcDB.lua", "npcs")):
        path = os.path.join(foreverdb.ROOT, "Data", fn)
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    m = re.match(r"^\[(\d+)\]=", line)
                    if m:
                        ids[key].add(int(m.group(1)))
    return ids


def merge_file(path, db, known, stats):
    sv, _ = foreverdb.load_saved_variables(path)
    if not sv:
        return
    rec = sv.get("recorder") or {}
    for mid, info in (rec.get("maps") or {}).items():
        if isinstance(mid, (int, float)) and isinstance(info, dict) and info.get("name"):
            m = db["maps"].setdefault(str(int(mid)), {})
            m["name"] = info["name"]
            if info.get("parent"):
                m["parent"] = int(info["parent"])
    for e in foreverdb.as_list(rec.get("entries")):
        if not isinstance(e, dict):
            continue
        kind = e.get("e")
        qid = e.get("q")
        npc = e.get("npc")
        mid = e.get("m")
        x, y = e.get("x"), e.get("y")
        title = e.get("n")
        if npc and e.get("npcName") and mid and x is not None:
            n = db["npcs"].setdefault(str(int(npc)), {})
            n["n"] = e["npcName"]
            if e.get("npcLevel"):
                n["lvl"] = int(e["npcLevel"])
            if foreverdb.add_point(n.setdefault("spm", {}), int(mid), [x, y]):
                stats["npc_points"] += 1
            foreverdb.note_source(n, "rec")
        if qid and kind in ("ACCEPT", "OFFER", "TURNIN", "ENDNPC", "PROGRESS", "ABANDON", "OBJ"):
            q = db["quests"].setdefault(str(int(qid)), {})
            if title and not PLACEHOLDER.match(title):
                q["n"] = title
            foreverdb.note_source(q, "rec")
            q["seen"] = int(q.get("seen", 0)) + 1
            if kind in ("ACCEPT", "OFFER") and npc:
                foreverdb.add_unique(q.setdefault("snpc", []), int(npc))
                n = db["npcs"].setdefault(str(int(npc)), {})
                foreverdb.add_unique(n.setdefault("starts", []), int(qid))
                stats["starts"] += 1
            if kind in ("TURNIN", "ENDNPC", "PROGRESS") and npc:
                foreverdb.add_unique(q.setdefault("enpc", []), int(npc))
                n = db["npcs"].setdefault(str(int(npc)), {})
                foreverdb.add_unique(n.setdefault("ends", []), int(qid))
                stats["ends"] += 1
            if kind == "ACCEPT" and e.get("lvl"):
                q.setdefault("seenlvl", int(e["lvl"]))
            if kind == "OBJ" and mid and x is not None:
                idx = int(e.get("obj") or 1)
                objs = q.setdefault("obj", [])
                while len(objs) < idx:
                    objs.append({})
                o = objs[idx - 1]
                txt = e.get("txt")
                if txt:
                    clean = re.sub(r"[:\s]*\d+\s*/\s*\d+\s*$", "", txt)      # "Wolves slain: 3/10"
                    clean = re.sub(r"^\s*\d+\s*/\s*\d+\s*", "", clean)        # "4/4 Chunk of Boar Meat"
                    o["text"] = clean.strip() or txt
                # the npc is the last hostile target when progress happened; only trust it as
                # the kill target when the objective text names it (else it is just a hint)
                npc_name = e.get("npcName")
                if npc and npc_name and txt and npc_name.lower() in txt.lower():
                    o["kind"] = "kill"
                    o["id"] = int(npc)
                    o["name"] = npc_name
                elif not o.get("kind"):
                    o["kind"] = "item" if txt and re.search(r"^\s*\d+\s*/\s*\d+", txt) else "event"
                if npc and not o.get("id"):
                    foreverdb.add_unique(o.setdefault("near", []), int(npc))
                if foreverdb.add_point(o.setdefault("spm", {}), int(mid), [x, y]):
                    stats["obj_points"] += 1
        if kind == "GOSSIP" and npc:
            for k, field in (("avail", "starts"), ("active", "ends")):
                for q2 in foreverdb.as_list(e.get(k)):
                    if isinstance(q2, (int, float)):
                        n = db["npcs"].setdefault(str(int(npc)), {})
                        foreverdb.add_unique(n.setdefault(field, []), int(q2))
                        q = db["quests"].setdefault(str(int(q2)), {})
                        foreverdb.add_unique(q.setdefault("snpc" if field == "starts" else "enpc", []), int(npc))
                        foreverdb.note_source(q, "rec")
    # harvest: titles + quest line positions
    harvest = sv.get("harvest") or {}
    for qid, info in (harvest.get("lines") or {}).items():
        if isinstance(qid, (int, float)) and isinstance(info, dict):
            q = db["quests"].setdefault(str(int(qid)), {})
            if info.get("name") and not PLACEHOLDER.match(info["name"]):
                q["n"] = info["name"]
            if info.get("map") and info.get("x") is not None:
                q.setdefault("start", {})
                foreverdb.add_point(q["start"].setdefault("spm", {}), int(info["map"]), [info["x"], info["y"]])
            foreverdb.note_source(q, "harvest")
    # scan / harvest quest titles
    scan = sv.get("scan") or {}
    for qid, title in (scan.get("quests") or {}).items():
        if isinstance(qid, (int, float)) and isinstance(title, str) and title and not PLACEHOLDER.match(title):
            q = db["quests"].setdefault(str(int(qid)), {})
            q.setdefault("n", title)
            foreverdb.note_source(q, "scan")
            stats["titles"] += 1


def main():
    files = sys.argv[1:]
    if not files:
        files = glob.glob(os.path.join(DEFAULT_WTF, "*", "SavedVariables", "ForeverGuide.lua*"))
    if not files:
        print("no SavedVariables files found; pass them as arguments")
        return 1
    db = foreverdb.load()
    known = vanilla_ids()
    stats = {"npc_points": 0, "starts": 0, "ends": 0, "obj_points": 0, "titles": 0}
    for f in files:
        print("reading", f)
        merge_file(f, db, known, stats)
    # drop entries that carry nothing useful
    for qid in list(db["quests"].keys()):
        q = db["quests"][qid]
        if not any(k in q for k in ("n", "snpc", "enpc", "obj", "start")):
            del db["quests"][qid]
    foreverdb.save(db)
    counts = foreverdb.emit_lua(db)
    new_q = sum(1 for k in db["quests"] if int(k) not in known["quests"])
    new_n = sum(1 for k in db["npcs"] if int(k) not in known["npcs"])
    print("merged: %(starts)d giver links, %(ends)d turn-in links, %(npc_points)d npc points, %(obj_points)d objective points, %(titles)d titles" % stats)
    print("overlay now: %d quests (%d not in vanilla), %d npcs (%d new), %d objects, %d maps -> Data/ForeverDB.lua" % (
        counts["quests"], new_q, counts["npcs"], new_n, counts["objects"], counts["maps"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
