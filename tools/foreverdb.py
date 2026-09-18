#!/usr/bin/env python3
"""
Shared code for the Forever data overlay.

Vanilla data lives in Data/QuestDB.lua etc. (built from Questie). Everything
Forever adds or changes is accumulated in data-src/forever.json by two tools
    tools/merge_recorded.py   evidence collected in-game by the addon (recorder / harvest / scan)
    tools/import_db2.py       the client's own DB2 tables (CSV exports from wago.tools)
and emitted to Data/ForeverDB.lua, which DB.lua merges over the vanilla tables at load.

forever.json / ForeverDB.lua shape:
  quests[id] = { n: title, lvl, req, snpc: [npcID..], enpc: [npcID..],
                 obj: [ { kind: "kill"|"item"|"object"|"event", id, name, text, spm: {uiMapID: [[x,y]..]}, spw: {uiMapID: [[inst,wx,wy]..]} } ],
                 seen: n, src: ["rec","db2"] }
  npcs[id]   = { n: name, lvl, spm: {uiMapID: [[x,y]..]}, starts: [..], ends: [..] }
  objects[id]= { n, spm }
  maps[uiMapID] = { name, parent }
spm = map coordinates (0-100) on a uiMapID; spw = world coordinates (converted in-game).
"""

import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "data-src", "forever.json")
OUT = os.path.join(ROOT, "Data", "ForeverDB.lua")

MAX_POINTS = 12


def load():
    if os.path.isfile(SRC):
        with open(SRC, "r", encoding="utf-8") as fh:
            db = json.load(fh)
    else:
        db = {}
    for k in ("quests", "npcs", "objects", "maps"):
        db.setdefault(k, {})
    return db


def save(db):
    os.makedirs(os.path.dirname(SRC), exist_ok=True)
    with open(SRC, "w", encoding="utf-8") as fh:
        json.dump(db, fh, indent=1, ensure_ascii=False, sort_keys=True)


def add_point(table, key, point, limit=MAX_POINTS, tol=1.5):
    """Add a coordinate pair to table[key] unless an equal-ish point is already there."""
    key = str(key)
    pts = table.setdefault(key, [])
    for p in pts:
        if all(abs(a - b) <= tol for a, b in zip(p[-2:], point[-2:])):
            return False
    if len(pts) >= limit:
        return False
    pts.append([round(v, 2) for v in point])
    return True


def add_unique(lst, value):
    if value is None:
        return
    if value not in lst:
        lst.append(value)


def note_source(rec, src):
    srcs = rec.setdefault("src", [])
    if src not in srcs:
        srcs.append(src)


# ------------------------------------------------------------
# Lua emission
# ------------------------------------------------------------
def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def lua_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return ("%.2f" % v).rstrip("0").rstrip(".")
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, list):
        return "{" + ",".join(lua_value(x) for x in v) + "}"
    if isinstance(v, dict):
        parts = []
        for k in sorted(v.keys(), key=lambda x: (not str(x).lstrip("-").isdigit(), str(x))):
            val = v[k]
            if val is None or val == [] or val == {}:
                continue
            ks = str(k)
            key = "[%s]" % ks if ks.lstrip("-").isdigit() else (ks if re.match(r"^[A-Za-z_]\w*$", ks) else "[%s]" % lua_str(ks))
            parts.append("%s=%s" % (key, lua_value(val)))
        return "{" + ",".join(parts) + "}"
    return "nil"


CORRECTIONS = os.path.join(ROOT, "data-src", "corrections.json")


def apply_corrections(db, path=CORRECTIONS):
    """
    Hand-written fixes win over everything collected automatically.
    data-src/corrections.json:
      { "quests": { "<id>": { "n": "Title", "lvl": 7, "snpc": [258098], "enpc": [..],
                              "obj": [ { "kind": "kill", "id": 1131, "spm": { "1426": [[45.4, 41.4]] } } ],
                              "_delete": true } },
        "npcs":   { "<id>": { "n": "Name", "spm": { "<uiMapID>": [[x, y]] } } },
        "objects": { ... }, "maps": { "<uiMapID>": { "name": "...", "parent": 1415 } } }
    A field replaces the collected value; "_delete": true drops the record.
    Returns the number of records touched.
    """
    if not os.path.isfile(path):
        return 0
    with open(path, "r", encoding="utf-8") as fh:
        fixes = json.load(fh)
    n = 0
    for section in ("quests", "npcs", "objects", "maps"):
        for key, fields in (fixes.get(section) or {}).items():
            key = str(key)
            if not isinstance(fields, dict):
                continue
            if fields.get("_delete"):
                db[section].pop(key, None)
                n += 1
                continue
            rec = db[section].setdefault(key, {})
            for k, v in fields.items():
                if k.startswith("_"):
                    continue
                rec[k] = v
            note_source(rec, "fix")
            n += 1
    return n


def emit_lua(db, path=OUT):
    apply_corrections(db)
    lines = [
        "-- AUTO-GENERATED by tools/merge_recorded.py / tools/import_db2.py from data-src/forever.json - DO NOT EDIT",
        "-- WoW Forever additions and changes, merged over the vanilla tables by DB.lua at load.",
        "local _, ns = ...",
        "ns.ForeverDB = {",
    ]
    for section in ("quests", "npcs", "objects", "maps"):
        lines.append("%s = {" % section)
        for key in sorted(db[section].keys(), key=lambda x: int(x)):
            lines.append("[%s]=%s," % (key, lua_value(db[section][key])))
        lines.append("},")
    lines.append("}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    return {k: len(db[k]) for k in ("quests", "npcs", "objects", "maps")}


# ------------------------------------------------------------
# SavedVariables reading (shared by the merge / report tools)
# ------------------------------------------------------------
def load_saved_variables(path):
    """Return (ForeverGuideDB, ForeverGuideCharDB) dicts from a SavedVariables file."""
    import sys
    sys.path.insert(0, HERE)
    from questie_lookup import LuaParser
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    out = {}
    for name in ("ForeverGuideDB", "ForeverGuideCharDB"):
        m = re.search(r"%s\s*=\s*" % name, text)
        if m:
            try:
                out[name] = LuaParser(text[m.end():]).value()
            except Exception as e:  # noqa: BLE001
                print("could not parse %s in %s: %s" % (name, path, e))
    return out.get("ForeverGuideDB") or {}, out.get("ForeverGuideCharDB") or {}


def as_list(v):
    """Lua arrays come back as dict {1:..,2:..} or list; normalise to a list."""
    if isinstance(v, list):
        return v
    if isinstance(v, dict):
        keys = sorted(k for k in v if isinstance(k, (int, float)))
        return [v[k] for k in keys]
    return []
