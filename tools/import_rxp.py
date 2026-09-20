#!/usr/bin/env python3
"""
Cross-reference with RestedXP's free WoW Forever guides (RXPGuides >= 4.11):
pull the *factual* world data they contain for quests our database has no
positions for - quest title, giver / turn-in NPC (name, id when given, map
position) and objective areas (mob name, map points) - into the Forever
overlay (data-src/forever.json -> Data/ForeverDB.lua).

Only facts are taken (where an NPC stands, where mobs are). The guides' own
route, step texts and ordering are theirs and are not copied; our routes come
from tools/plan_route.lua.

    python3 tools/import_rxp.py <folder with RXP Forever guide .lua files>
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import foreverdb  # noqa: E402

GOTO = re.compile(r"^\.goto\s+(\d+),\s*([\d.]+),\s*([\d.]+)")
GOTO_WORLD = re.compile(r"^\.goto\s+(\d+)/(\d+),\s*(-?[\d.]+),\s*(-?[\d.]+)")
ACCEPT = re.compile(r"^\.accept\s+(\d+)(?:\s*>>\s*Accept\s+(.*))?")
TURNIN = re.compile(r"^\.turnin\s+(\d+)")
COMPLETE = re.compile(r"^\.complete\s+(\d+),(\d+)(?:\s*--\s*\|?\s*(.*))?")
TARGET = re.compile(r"^\.target\s+\+?([^:\n]+?)(?::+(\d+))?\s*$")
MOB = re.compile(r"^\.mob\s+\+?([^:\n]+?)(?::+(\d+))?\s*$")
NAME = re.compile(r"^#name\s+(.*)")
MAP_NAMES = {2521: "Zephras Isle"}
CLASS_BITS = {"warrior": 1, "paladin": 2, "hunter": 4, "rogue": 8, "priest": 16, "shaman": 64, "mage": 128, "warlock": 256, "druid": 1024}


def strip_markup(s):
    s = re.sub(r"\|c[^_]*_", "", s)
    s = re.sub(r"\|T[^|]*\|t", "", s)
    s = s.replace("|r", "")
    return s.strip()


def parse_guide(text):
    """Yield step dicts: {gotos:[(map,x,y)], accept:[(id,title)], turnin:[id], complete:[(id,idx,text)], target:(name,id), mobs:[..], text:[..]}"""
    steps = []
    cur = None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("step"):
            cur = {"gotos": [], "wgotos": [], "accept": [], "turnin": [], "complete": [], "target": None, "mobs": [], "text": [], "click": False, "classes": 0}
            # "step << Hunter" / "step << Mage/Warlock": class-restricted step
            tag = line.split("<<", 1)[1] if "<<" in line else ""
            for word in re.split(r"[/\s]+", tag.strip()):
                w = word.lower().lstrip("!")
                if w in CLASS_BITS and not word.startswith("!"):
                    cur["classes"] |= CLASS_BITS[w]
            steps.append(cur)
            continue
        if cur is None or line.startswith("--"):
            continue
        m = GOTO.match(line)
        if m:
            cur["gotos"].append((int(m.group(1)), float(m.group(2)), float(m.group(3))))
            continue
        m = GOTO_WORLD.match(line)
        if m:
            # ".goto map/instance,east-west,north-south" -> world (x = north-south, y = east-west)
            cur["wgotos"].append((int(m.group(1)), int(m.group(2)), float(m.group(4)), float(m.group(3))))
            continue
        m = ACCEPT.match(line)
        if m:
            cur["accept"].append((int(m.group(1)), strip_markup((m.group(2) or "").split("<<")[0])))
            continue
        m = TURNIN.match(line)
        if m:
            cur["turnin"].append(int(m.group(1)))
            continue
        m = COMPLETE.match(line)
        if m:
            cur["complete"].append((int(m.group(1)), int(m.group(2)), strip_markup(m.group(3) or "")))
            continue
        m = TARGET.match(line)
        if m and not cur["target"]:
            cur["target"] = (strip_markup(m.group(1)), int(m.group(2)) if m.group(2) else None)
            continue
        m = MOB.match(line)
        if m:
            cur["mobs"].append((strip_markup(m.group(1)), int(m.group(2)) if m.group(2) else None))
            continue
        if line.startswith(">>"):
            t = strip_markup(line[2:])
            cur["text"].append(t)
            if re.search(r"\b(click|pick up|gather|collect|use the|open)\b", t, re.I) and "kill" not in t.lower():
                cur["click"] = True
    return steps


def harvest(steps, known_pos, want, npcs):
    """want(qid) -> bool: which quest ids to take. Returns quests dict keyed by id; npc positions go into npcs."""
    quests = {}
    prev_gotos = []
    for st in steps:
        gotos = st["gotos"] or prev_gotos
        # remember this block's points for a following "complete" block without its own,
        # but never hand a giver / turn-in spot down as an objective area
        if st["accept"] or st["turnin"]:
            prev_gotos = []
        elif st["gotos"]:
            prev_gotos = st["gotos"]
        tname, tid = st["target"] or (None, None)
        if tname and (st["accept"] or st["turnin"]) and (st["gotos"] or st["wgotos"]):
            npcs.setdefault(tname, {"id": tid, "spm": [], "spw": []})
            if tid and not npcs[tname]["id"]:
                npcs[tname]["id"] = tid
            for g in st["gotos"][:1]:
                if g not in npcs[tname]["spm"]:
                    npcs[tname]["spm"].append(g)
            for g in st["wgotos"][:1]:
                if g not in npcs[tname]["spw"]:
                    npcs[tname]["spw"].append(g)
        for qid, title in st["accept"]:
            if not want(qid):
                continue
            q = quests.setdefault(qid, {"obj": {}})
            if title and not q.get("n"):
                q["n"] = title
            q.setdefault("_accepts", []).append(st["classes"])
            # handed in and picked up in one go at the same NPC: the new quest follows the old one
            if st["turnin"] and tname:
                q.setdefault("pre", [])
                for pid in st["turnin"]:
                    if pid != qid and pid not in q["pre"]:
                        q["pre"].append(pid)
            if gotos and not q.get("start"):
                mp, x, y = gotos[0]
                q["start"] = {"map": mp, "x": x, "y": y, "npc": tname, "npcID": tid}
        for qid in st["turnin"]:
            if not want(qid):
                continue
            q = quests.setdefault(qid, {"obj": {}})
            if gotos and not q.get("fin"):
                mp, x, y = gotos[0]
                q["fin"] = {"map": mp, "x": x, "y": y, "npc": tname, "npcID": tid}
        for qid, idx, text in st["complete"]:
            if not want(qid):
                continue
            q = quests.setdefault(qid, {"obj": {}})
            o = q["obj"].setdefault(idx, {"points": [], "mobs": [], "text": None, "click": False})
            if text and not o["text"]:
                o["text"] = text
            if not (st["accept"] or st["turnin"]):
                for g in gotos:
                    if g not in o["points"] and len(o["points"]) < foreverdb.MAX_POINTS:
                        o["points"].append(g)
            for mob in st["mobs"]:
                if mob not in o["mobs"]:
                    o["mobs"].append(mob)
            if st["click"]:
                o["click"] = True
    return quests


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    folder = sys.argv[1]
    # which ids are Forever-only (no vanilla positions)? everything >= 60000 plus vanilla ids without a giver
    vanilla = set()
    with open(os.path.join(foreverdb.ROOT, "Data", "QuestDB.lua"), "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = re.match(r"^\[(\d+)\]=\{(.*)", line)
            if m and ("snpc=" in m.group(2) or "sobj=" in m.group(2)):
                vanilla.add(int(m.group(1)))

    def want(qid):
        return qid not in vanilla

    found = {}
    npcs = {}
    # vanilla NPC names -> ids (unique names only), to attach RestedXP's positions to Questie's records
    name_to_id = {}
    dup = set()
    with open(os.path.join(foreverdb.ROOT, "Data", "NpcDB.lua"), "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = re.match(r"^\[(\d+)\]=\{.*?n=\"((?:[^\"\\]|\\.)*)\"", line)
            if m:
                nid, nm = int(m.group(1)), m.group(2).replace('\\"', '"')
                if nm in name_to_id:
                    dup.add(nm)
                name_to_id[nm] = nid
    for nm in dup:
        name_to_id.pop(nm, None)
    files = sorted(f for f in os.listdir(folder) if f.lower().endswith(".lua"))
    for fn in files:
        with open(os.path.join(folder, fn), "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        steps = parse_guide(text)
        got = harvest(steps, None, want, npcs)
        for qid, q in got.items():
            dst = found.setdefault(qid, {"obj": {}})
            for k in ("n", "start", "fin", "pre"):
                if q.get(k) and not dst.get(k):
                    dst[k] = q[k]
            dst.setdefault("_accepts", []).extend(q.get("_accepts", []))
            for idx, o in q["obj"].items():
                d = dst["obj"].setdefault(idx, {"points": [], "mobs": [], "text": None, "click": False})
                if o["text"] and not d["text"]:
                    d["text"] = o["text"]
                for p in o["points"]:
                    if p not in d["points"] and len(d["points"]) < foreverdb.MAX_POINTS:
                        d["points"].append(p)
                for mob in o["mobs"]:
                    if mob not in d["mobs"]:
                        d["mobs"].append(mob)
                d["click"] = d["click"] or o["click"]
        print(f"{fn:40s} {len(got):4d} quests")

    # -> overlay
    db = foreverdb.load()
    stats = {"quests": 0, "starts": 0, "ends": 0, "objs": 0, "npcs": 0}
    for qid, q in sorted(found.items()):
        rec = db["quests"].setdefault(str(qid), {})
        stats["quests"] += 1
        if q.get("n") and not rec.get("n"):
            rec["n"] = q["n"]
        accepts = q.get("_accepts", [])
        if qid >= 60000 and accepts and all(accepts):
            rec["classes"] = 0
            for c in accepts:
                rec["classes"] |= c
        if q.get("pre"):
            rec["pre"] = q["pre"]
        for key, field in (("start", "snpc"), ("fin", "enpc")):
            s = q.get(key)
            if not s:
                continue
            if s.get("npcID"):
                n = db["npcs"].setdefault(str(s["npcID"]), {})
                n["n"] = s["npc"] or n.get("n")
                foreverdb.add_point(n.setdefault("spm", {}), s["map"], [s["x"], s["y"]])
                foreverdb.add_unique(n.setdefault("starts" if key == "start" else "ends", []), qid)
                foreverdb.add_unique(rec.setdefault(field, []), s["npcID"])
                foreverdb.note_source(n, "rxp")
                stats["npcs"] += 1
            else:
                pos = rec.setdefault(key, {})
                if s.get("npc"):
                    pos["n"] = s["npc"]
                foreverdb.add_point(pos.setdefault("spm", {}), s["map"], [s["x"], s["y"]])
            stats["starts" if key == "start" else "ends"] += 1
        if q["obj"]:
            objs = rec.setdefault("obj", [])
            for idx in sorted(q["obj"]):
                while len(objs) < idx:
                    objs.append({})
                o = objs[idx - 1]
                src = q["obj"][idx]
                text = src["text"]
                if text:
                    clean = re.sub(r"^\s*\d+\s*/\s*\d+\s*", "", text).strip()
                    if clean:
                        o["text"] = clean
                    mcount = re.match(r"^\s*(\d+)\s*/\s*(\d+)", text)
                    if mcount:
                        o["count"] = int(mcount.group(2))
                if src["mobs"]:
                    itemish = text and not re.search(r"slain|killed|kill\b", text, re.I) and re.search(r"\b(loot|mask|head|talon|core|pelt|hide|meat|sample|scale|feather|tusk|ear|fang|claw|ring|key)\b", text, re.I)
                    o["kind"] = "item" if itemish else "kill"
                    o["name"] = src["mobs"][0][0]
                    if src["mobs"][0][1]:
                        o["id"] = src["mobs"][0][1]
                        n = db["npcs"].setdefault(str(o["id"]), {})
                        n["n"] = src["mobs"][0][0]
                        for mp, x, y in src["points"]:
                            foreverdb.add_point(n.setdefault("spm", {}), mp, [x, y])
                        foreverdb.note_source(n, "rxp")
                    if len(src["mobs"]) > 1:
                        o["also"] = [m[0] for m in src["mobs"][1:]]
                elif src["click"]:
                    o["kind"] = "object"
                    o["name"] = o.get("name") or (text and re.sub(r"^\s*\d+\s*/\s*\d+\s*", "", text).strip())
                else:
                    o.setdefault("kind", "event")
                for mp, x, y in src["points"]:
                    foreverdb.add_point(o.setdefault("spm", {}), mp, [x, y])
                stats["objs"] += 1
        foreverdb.note_source(rec, "rxp")
    # NPC positions from every guide step that talks to a named NPC (RestedXP's Forever positions;
    # the addon and the planner prefer these over Questie's vanilla spot)
    npc_pos = 0
    for nm, info in npcs.items():
        nid = info["id"] or name_to_id.get(nm)
        if not nid or not (info["spm"] or info["spw"]):
            continue
        n = db["npcs"].setdefault(str(nid), {})
        n["n"] = n.get("n") or nm
        for mp, x, y in info["spm"]:
            foreverdb.add_point(n.setdefault("spm", {}), mp, [x, y])
            npc_pos += 1
        for mp, inst, wx, wy in info["spw"]:
            lst = n.setdefault("spw", {}).setdefault(str(mp), [])
            if [inst, wx, wy] not in lst and len(lst) < foreverdb.MAX_POINTS:
                lst.append([inst, wx, wy])
                npc_pos += 1
        foreverdb.note_source(n, "rxp")
    stats["npcs"] += npc_pos
    for mp, name in MAP_NAMES.items():
        db["maps"].setdefault(str(mp), {})["name"] = name
    foreverdb.save(db)
    counts = foreverdb.emit_lua(db)
    print("rxp cross-reference: %(quests)d quests, %(starts)d givers, %(ends)d turn-ins, %(objs)d objectives, %(npcs)d npc points" % stats)
    print("overlay now: %(quests)d quests, %(npcs)d npcs, %(objects)d objects, %(maps)d maps -> Data/ForeverDB.lua" % counts)


if __name__ == "__main__":
    main()
