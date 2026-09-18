#!/usr/bin/env python3
"""
Look up quests / NPCs / objects / items in Questie's Classic database and
print them as ForeverGuide step JSON. Research helper for writing guides.

    python tools/questie_lookup.py quest 783 7 18
    python tools/questie_lookup.py npc 823 197
    python tools/questie_lookup.py object 161557
    python tools/questie_lookup.py item 752
    python tools/questie_lookup.py steps 783 7 33      # emits ACCEPT/KILL/TURNIN steps for the quests
    python tools/questie_lookup.py search "Kobold"     # search quest and NPC names

Questie path: --questie <folder> or the QUESTIE env var, default
  C:\\Program Files (x86)\\World of Warcraft\\_classic_beta_\\Interface\\Questie-11.21.7
Only the Classic (Era) tables are read: Database/Classic/classic*DB.lua.
Reads only; nothing is modified.
"""

import argparse
import json
import os
import re
import sys

DEFAULT_QUESTIE = r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\Questie-11.21.7"

QUEST_KEYS = ["name", "startedBy", "finishedBy", "requiredLevel", "questLevel", "requiredRaces", "requiredClasses",
              "objectivesText", "triggerEnd", "objectives", "sourceItemId", "preQuestGroup", "preQuestSingle",
              "childQuests", "inGroupWith", "exclusiveTo", "zoneOrSort", "requiredSkill", "requiredMinRep",
              "requiredMaxRep", "requiredSourceItems", "nextQuestInChain", "questFlags", "specialFlags",
              "parentQuest", "reputationReward", "breadcrumbForQuestId", "breadcrumbs", "extraObjectives",
              "requiredSpell", "requiredSpecialization", "requiredMaxLevel"]
NPC_KEYS = ["name", "minLevelHealth", "maxLevelHealth", "minLevel", "maxLevel", "rank", "spawns", "waypoints",
            "zoneID", "questStarts", "questEnds", "factionID", "friendlyToFaction", "subName", "npcFlags"]
OBJECT_KEYS = ["name", "questStarts", "questEnds", "spawns", "zoneID", "factionID", "waypoints"]
ITEM_KEYS = ["name", "npcDrops", "objectDrops", "itemDrops", "startQuest", "questRewards", "flags", "foodType",
             "itemLevel", "requiredLevel", "ammoType", "class", "subClass", "vendors", "relatedQuests", "teachesSpell"]

# Questie areaID -> Classic Era uiMapID (subset; full table in Database/Zones/data/areaIdToUiMapId.lua)
AREA_TO_UIMAP = {
    1: 1416, 3: 1417, 4: 1418, 8: 1419, 10: 1422, 11: 1425, 12: 1429, 14: 1411, 15: 1445, 16: 1447, 17: 1413,
    28: 1423, 33: 1434, 36: 1416, 38: 1432, 40: 1436, 41: 1435, 44: 1433, 45: 1424, 46: 1428, 47: 1437, 51: 1427,
    85: 1420, 130: 1421, 139: 1423, 141: 1438, 148: 1439, 215: 1412, 267: 1424, 331: 1440, 357: 1444, 361: 1448,
    400: 1441, 405: 1443, 406: 1442, 440: 1446, 490: 1449, 493: 1450, 618: 1452, 1377: 1451, 1497: 1458,
    1519: 1453, 1537: 1455, 1637: 1454, 1638: 1456, 1657: 1457, 2597: 1459, 3277: 1460, 3358: 1461,
}
AREA_NAMES = {
    1: "Dun Morogh", 3: "Badlands", 4: "Blasted Lands", 8: "Swamp of Sorrows", 10: "Duskwood", 11: "Wetlands",
    12: "Elwynn Forest", 14: "Durotar", 15: "Dustwallow Marsh", 16: "Azshara", 17: "The Barrens", 28: "Western Plaguelands",
    33: "Stranglethorn Vale", 36: "Alterac Mountains", 38: "Loch Modan", 40: "Westfall", 41: "Deadwind Pass",
    44: "Redridge Mountains", 45: "Arathi Highlands", 46: "Burning Steppes", 47: "The Hinterlands", 51: "Searing Gorge",
    85: "Tirisfal Glades", 130: "Silverpine Forest", 139: "Eastern Plaguelands", 141: "Teldrassil", 148: "Darkshore",
    215: "Mulgore", 267: "Hillsbrad Foothills", 331: "Ashenvale", 357: "Feralas", 361: "Felwood", 400: "Thousand Needles",
    405: "Desolace", 406: "Stonetalon Mountains", 440: "Tanaris", 490: "Un'Goro Crater", 493: "Moonglade",
    618: "Winterspring", 1377: "Silithus", 1497: "Undercity", 1519: "Stormwind City", 1537: "Ironforge",
    1637: "Orgrimmar", 1638: "Thunder Bluff", 1657: "Darnassus", 2597: "Alterac Valley", 3277: "Warsong Gulch",
    3358: "Arathi Basin",
}


# ------------------------------------------------------------
# Tiny Lua table-literal parser (enough for Questie's generated DB files)
# ------------------------------------------------------------
class LuaParser:
    def __init__(self, text):
        self.s = text
        self.i = 0

    def ws(self):
        s, n = self.s, len(self.s)
        while self.i < n:
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("--", self.i):
                while self.i < n and s[self.i] != "\n":
                    self.i += 1
            else:
                break

    def value(self):
        self.ws()
        s = self.s
        c = s[self.i]
        if c == "{":
            return self.table()
        if c in "\"'":
            return self.string()
        m = re.match(r"-?\d+(\.\d+)?", s[self.i:])
        if m:
            self.i += m.end()
            return float(m.group()) if m.group(1) else int(m.group())
        for word, val in (("nil", None), ("true", True), ("false", False)):
            if s.startswith(word, self.i):
                self.i += len(word)
                return val
        raise ValueError(f"unexpected {s[self.i:self.i+20]!r}")

    def string(self):
        q = self.s[self.i]
        self.i += 1
        out = []
        while self.s[self.i] != q:
            c = self.s[self.i]
            if c == "\\":
                self.i += 1
                c = self.s[self.i]
                c = {"n": "\n", "t": "\t"}.get(c, c)
            out.append(c)
            self.i += 1
        self.i += 1
        return "".join(out)

    def table(self):
        self.i += 1  # {
        items, keyed = [], {}
        while True:
            self.ws()
            if self.s[self.i] == "}":
                self.i += 1
                break
            if self.s[self.i] == "[":
                self.i += 1
                key = self.value()
                self.ws()
                assert self.s[self.i] == "]"
                self.i += 1
                self.ws()
                assert self.s[self.i] == "="
                self.i += 1
                keyed[key] = self.value()
            else:
                items.append(self.value())
            self.ws()
            if self.s[self.i] == ",":
                self.i += 1
        if keyed and not items:
            return keyed
        if keyed:
            for n, v in enumerate(items, start=1):
                keyed[n] = v
            return keyed
        return items


def load_db(path, keys):
    """Parse lines of the form  [id] = {...},  into {id: {key: value}}."""
    out = {}
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = re.match(r"^\[(\d+)\]\s*=\s*(\{.*\}),?\s*$", line.strip())
            if not m:
                continue
            values = LuaParser(m.group(2)).value()
            rec = {}
            for idx, key in enumerate(keys):
                if idx < len(values) and values[idx] is not None:
                    rec[key] = values[idx]
            out[int(m.group(1))] = rec
    return out


class Questie:
    def __init__(self, root):
        base = os.path.join(root, "Database", "Classic")
        self.quests = load_db(os.path.join(base, "classicQuestDB.lua"), QUEST_KEYS)
        self.npcs = load_db(os.path.join(base, "classicNpcDB.lua"), NPC_KEYS)
        self.objects = load_db(os.path.join(base, "classicObjectDB.lua"), OBJECT_KEYS)
        self.items = load_db(os.path.join(base, "classicItemDB.lua"), ITEM_KEYS)


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
def centroid(spawns):
    """spawns: {areaID: [[x, y], ...]} -> (areaID, x, y) of the biggest cluster (simple mean)."""
    best = None
    for area, coords in (spawns or {}).items():
        pts = [c for c in coords if isinstance(c, list) and len(c) >= 2 and c[0] >= 0]
        if not pts:
            continue
        x = sum(p[0] for p in pts) / len(pts)
        y = sum(p[1] for p in pts) / len(pts)
        if best is None or len(pts) > best[3]:
            best = (area, round(x, 1), round(y, 1), len(pts))
    return best


def loc_fields(area, x, y):
    f = {}
    if area in AREA_TO_UIMAP:
        f["map"] = AREA_TO_UIMAP[area]
    if area in AREA_NAMES:
        f["zone"] = AREA_NAMES[area]
    f["x"], f["y"] = x, y
    return f


def npc_step(db, stype, quest_id, quest, npc_id, note=None):
    npc = db.npcs.get(npc_id, {})
    step = {"type": stype, "quest": quest_id, "questName": quest.get("name"), "npc": npc_id, "npcName": npc.get("name")}
    c = centroid(npc.get("spawns"))
    if c:
        step.update(loc_fields(c[0], c[1], c[2]))
    if note:
        step["note"] = note
    return step


def quest_steps(db, quest_id):
    q = db.quests.get(quest_id)
    if not q:
        return [{"type": "NOTE", "text": f"quest {quest_id} not found in Questie DB"}]
    steps = []
    starters = (q.get("startedBy") or [None])[0] or []
    enders = (q.get("finishedBy") or [None])[0] or []
    if starters:
        steps.append(npc_step(db, "ACCEPT", quest_id, q, starters[0]))
    objectives = q.get("objectives") or []
    creatures = objectives[0] if len(objectives) > 0 and objectives[0] else []
    objects = objectives[1] if len(objectives) > 1 and objectives[1] else []
    items = objectives[2] if len(objectives) > 2 and objectives[2] else []
    for entry in creatures:
        cid = entry[0]
        npc = db.npcs.get(cid, {})
        step = {"type": "KILL", "quest": quest_id, "questName": q.get("name"), "target": npc.get("name"), "npc": cid}
        c = centroid(npc.get("spawns"))
        if c:
            step.update(loc_fields(c[0], c[1], c[2]))
        steps.append(step)
    for entry in items:
        iid = entry[0]
        item = db.items.get(iid, {})
        step = {"type": "COLLECT", "quest": quest_id, "questName": q.get("name"), "target": item.get("name")}
        sources = []
        for nid in item.get("npcDrops") or []:
            sources.append(("npc", nid))
        for oid in item.get("objectDrops") or []:
            sources.append(("object", oid))
        if sources:
            kind, sid = sources[0]
            rec = (db.npcs if kind == "npc" else db.objects).get(sid, {})
            if kind == "npc":
                step["npc"] = sid
            c = centroid(rec.get("spawns"))
            if c:
                step.update(loc_fields(c[0], c[1], c[2]))
            step["note"] = f"item {iid} from {kind} {sid} {rec.get('name', '')}".strip()
        steps.append(step)
    for entry in objects:
        oid = entry[0]
        obj = db.objects.get(oid, {})
        step = {"type": "COMPLETE", "quest": quest_id, "questName": q.get("name"), "target": obj.get("name"),
                "note": f"object {oid}"}
        c = centroid(obj.get("spawns"))
        if c:
            step.update(loc_fields(c[0], c[1], c[2]))
        steps.append(step)
    if q.get("objectivesText") and not (creatures or items or objects):
        steps.append({"type": "COMPLETE", "quest": quest_id, "questName": q.get("name"),
                      "note": "; ".join(q["objectivesText"])})
    if enders:
        steps.append(npc_step(db, "TURNIN", quest_id, q, enders[0]))
    return steps


def describe_quest(db, quest_id):
    q = db.quests.get(quest_id)
    if not q:
        print(f"quest {quest_id}: not found")
        return
    print(f"[{quest_id}] {q.get('name')}  level {q.get('questLevel')} (req {q.get('requiredLevel')})  "
          f"zone {q.get('zoneOrSort')} {AREA_NAMES.get(q.get('zoneOrSort'), '')}")
    for label, key in (("starts", "startedBy"), ("ends", "finishedBy")):
        groups = q.get(key) or []
        names = ["npc", "object", "item"]
        for kind, ids in zip(names, groups):
            for i in ids or []:
                rec = {"npc": db.npcs, "object": db.objects, "item": db.items}[kind].get(i, {})
                c = centroid(rec.get("spawns")) if kind != "item" else None
                loc = f" @ {AREA_NAMES.get(c[0], c[0])} {c[1]}, {c[2]}" if c else ""
                print(f"   {label}: {kind} {i} {rec.get('name', '?')}{loc}")
    for t in q.get("objectivesText") or []:
        print(f"   objective: {t}")
    for key in ("preQuestSingle", "preQuestGroup", "nextQuestInChain", "exclusiveTo", "requiredRaces", "requiredClasses"):
        if q.get(key):
            print(f"   {key}: {q[key]}")


def describe_npc(db, npc_id):
    n = db.npcs.get(npc_id)
    if not n:
        print(f"npc {npc_id}: not found")
        return
    c = centroid(n.get("spawns"))
    loc = f" @ {AREA_NAMES.get(c[0], c[0])} (map {AREA_TO_UIMAP.get(c[0], '?')}) {c[1]}, {c[2]} ({c[3]} spawns)" if c else ""
    print(f"[{npc_id}] {n.get('name')} {n.get('subName') or ''} level {n.get('minLevel')}-{n.get('maxLevel')}{loc}")
    if n.get("questStarts"):
        print(f"   starts: {n['questStarts']}")
    if n.get("questEnds"):
        print(f"   ends:   {n['questEnds']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kind", choices=["quest", "npc", "object", "item", "steps", "search"])
    ap.add_argument("ids", nargs="+")
    ap.add_argument("--questie", default=os.environ.get("QUESTIE", DEFAULT_QUESTIE))
    args = ap.parse_args()

    if not os.path.isdir(os.path.join(args.questie, "Database", "Classic")):
        print(f"Questie not found at {args.questie} (use --questie <folder>)")
        return 1
    db = Questie(args.questie)

    if args.kind == "search":
        needle = " ".join(args.ids).lower()
        for qid, q in sorted(db.quests.items()):
            if needle in (q.get("name") or "").lower():
                print(f"quest {qid}: {q['name']} (level {q.get('questLevel')})")
        for nid, n in sorted(db.npcs.items()):
            if needle in (n.get("name") or "").lower():
                print(f"npc {nid}: {n['name']} ({n.get('minLevel')}-{n.get('maxLevel')})")
        return 0

    ids = [int(x) for x in args.ids]
    if args.kind == "quest":
        for i in ids:
            describe_quest(db, i)
    elif args.kind == "npc":
        for i in ids:
            describe_npc(db, i)
    elif args.kind == "object":
        for i in ids:
            o = db.objects.get(i)
            c = centroid(o.get("spawns")) if o else None
            print(f"[{i}] {o.get('name') if o else 'not found'}" + (f" @ {AREA_NAMES.get(c[0], c[0])} {c[1]}, {c[2]}" if c else ""))
    elif args.kind == "item":
        for i in ids:
            it = db.items.get(i)
            print(f"[{i}] {json.dumps(it) if it else 'not found'}")
    elif args.kind == "steps":
        steps = []
        for i in ids:
            steps.extend(quest_steps(db, i))
        print(json.dumps(steps, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
