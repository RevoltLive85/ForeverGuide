# ForeverGuide — Phase 1 status (2026-09-18)

Free, data-driven leveling guide addon for WoW Forever (TOC 16001). Installed at
`C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\ForeverGuide\` (the addon folder is also the
source repo: `guides-src/`, `tools/` live inside it; WoW ignores files not listed in the TOC).
Questie 11.21.7 source is at `_classic_beta_\Interface\Questie-11.21.7` (read-only reference DB: Classic quest/NPC/object/item tables).

## What exists (untested in-game as of this note — needs first login test)
- Core.lua: `ns` namespace, secret-value-safe helpers (`Plain/PlainNumber/Safe/ns.Call("C_X.Y", ...)`), module registry, lifecycle
  (ADDON_LOADED -> Database:Init + OnInit; first PLAYER_ENTERING_WORLD -> OnEnable; every -> OnEnterWorld; PLAYER_LOGOUT -> OnLogout).
- Database.lua: `ForeverGuideDB` (account: ui, nav, recorder, debug) and `ForeverGuideCharDB` (activeGuide, guides[id] = {step, done{}, version}).
- Events.lua: single event frame, `ns.Events:Register(event, fn)`, internal `FG_*` bus, `Debounce(key, delay, fn)`.
- Player.lua: level/xp/faction/class/race, `GetMapPosition()` (uiMapID, x, y 0-100 via C_Map.GetPlayerMapPosition),
  `GetWorldPosition()` (UnitPosition), `GetFacing()`, `GetUnitInfo("target"/"npc")` incl. npcID parsed from GUID.
- Quest.lua: log snapshot via C_QuestLog.GetNumQuestLogEntries/GetInfo/GetQuestObjectives; states NOT_STARTED/IN_PROGRESS/
  READY_TO_TURN_IN/COMPLETED/FAILED; objective diffing -> FG_OBJECTIVE_PROGRESS; QUEST_REMOVED disambiguated to FG_QUEST_ABANDONED
  (0.5 s later, if not flagged completed); titles via GetTitleForQuestID / QuestUtils_GetQuestName / RequestLoadQuestByID.
- Navigation.lua: map coord -> world via C_Map.GetWorldPosFromMapPos + UnitPosition; angle = atan2(dy, dx) - GetPlayerFacing
  (X north, Y west, facing CCW from north); map-space fallback via GetMapWorldSize; optional Blizzard user waypoint
  (UiMapPoint.CreateFromCoordinates + C_Map.SetUserWaypoint + C_SuperTrack.SetSuperTrackedUserWaypoint). Unknown map IDs fall back
  to zone-name matching (guide data uses Classic Era uiMapIDs, e.g. Elwynn 1429 — Forever's real IDs still unknown; `/fg pos` reveals them).
- Guide.lua: registry (`ns.RegisterGuide{}`), step interpreter. Types ACCEPT/TURNIN/COMPLETE/KILL/COLLECT/GRIND/BUY/TRAIN/HEARTH/
  TRAVEL/FLY/TALK/NOTE. Rules: any step whose quest is flagged completed is done; objective/turn-in step with quest missing jumps back to
  its ACCEPT step; manual steps auto-complete when the next automatic step is done; class/race/faction filters; skip on ACCEPT skips whole quest;
  persisted step index only moves forward on its own (`/fg back`, `/fg step n`, `/fg reset` move it back).
- Recorder.lua: records ACCEPT/TURNIN/ABANDON/OFFER/ENDNPC/GOSSIP/VENDOR/TRAINER/OBJ/LEVEL entries with npcID, mapID, x, y, level, zone
  into ForeverGuideDB.recorder (on by default, `/fg rec off`). Also collects uiMapID -> name table.
- UI.lua: plain movable window (BackdropTemplate, GameFont templates), current step, progress, arrow texture (MinimapArrow, SetRotation),
  distance + direction word, step list, Back/Skip/Guides buttons.
- Commands.lua: `/fg` status readout, help, show/hide/toggle, guides/guide, skip/back/step/reset, quests, pos, target, nav, way, lock/unlock,
  scale, resetpos, rec, bliz, debug, eval.
- guides-src/SCHEMA.md + HUMAN_NORTHSHIRE_1_6.json (40 steps, IDs/coords from Questie Classic DB); tools/compile_guides.py (JSON -> Guides/*.lua
  + Guides.xml); tools/questie_lookup.py (quest/npc/object/item lookups + `steps <questIDs>` emitting step JSON);
  tools/test/run_tests.lua + mock_wow.lua (headless engine test, 35 checks pass with lua5.1).

- Scanner.lua: `/fg scan [from] [to]` requests every quest id via C_QuestLog.RequestLoadQuestByID, collects QUEST_DATA_LOAD_RESULT
  successes + titles into ForeverGuideDB.scan; tools/scan_diff.py diffs against Questie -> Forever's ~1000 new quests (ids+titles only;
  NPCs/coords for those still come from the recorder while playing, or C_QuestLog.GetQuestsOnMap / C_QuestLine.GetAvailableQuestLines).
  Questie's Classic DB (4244 quests) has all vanilla quests but none of the new Forever quests.

## Findings from the first in-game session (2026-09-18, char Sniff, build 69913)
- Addon loads and runs; recorder works (GOSSIP/TRAINER entries with npcID, map, coords).
- Forever uses the **Classic Era uiMapIDs**: Ironforge 1455, Eastern Kingdoms 1415 (parent 947). So Questie's map IDs (Elwynn 1429 …) apply.
- New Forever NPC seen: Eldrun Stormbreaker, npcID 258098 (trainer, Ironforge, The Forlorn Cavern) — new NPC IDs are ~258k.
- `/fg scan` v1 (burst 1000 req/s) answered only ids 1-~1300 and then almost nothing: the server throttles quest-data requests.
  Rewritten with a flow-control window (4-60 in flight, 4 s timeout, 3 retries, resumable: `/fg scan resume`).
- Every id 1-999 "exists" on the server incl. placeholder rows titled `None`, `<UNUSED>`, `<NYI>`, `<TEST>` — scan_diff.py filters those.
- New Forever quests reuse some old unused ids (490 Bounty: Gnarlpine Furbolg, 785 A Strategic Alliance, 999 When Dreams Turn to
  Nightmares, 1005/1006 What Lurks/Lies Beyond, 1099 Goblins Win!, 1174 Gnomes Win!, 1500 Waking Naralex) and also live in the
  86000-100000 range (86585 Banner of the Fallen, 91751 Rough Wolf Pelts, 94449-94467 Call of Fire, 96390-96408 Dun Morogh chain,
  97919-97925 Camping 101: <profession>, 98319-98323 Secure the Mountain, 99127-99159 …). Default scan ranges: 1-12000 and 80000-120000.

- Session 2 (later on 2026-09-18): the server no longer answers ANY standalone RequestLoadQuestByID (single uncached real quests
  1027/1031/3000/3001/4001/5001 stayed `false nil` after 5 s, on a fresh login). Either the first flood got the account flagged for a
  while, or the beta blocks quest queries — retry another day (`/fg scan 1 50` is a cheap probe). Scanner v3 (rate based + vanilla
  canaries + auto re-ask passes) is installed for when it works again.
- Ids Questie lists but Forever returns as `None` / silent: 1-4, 10 (Scrimshank Redemption), 17 (Uldaman Reagent Run), 2 (Sharptalon's Claw),
  23-25, 32, 41-44 … → vanilla quests removed/gutted on Forever.
- `/fg harvest` (C_QuestLine.GetAvailableQuestLines per map): 57 zone maps answered, **0 quest lines everywhere** — Classic-ruleset maps do
  not populate quest lines. Door closed. `/fg harvest sweep` (HaveQuestData cache sweep) works but only returns what the client cached.
- The map children list revealed **new Forever zones**: 2482 Mount Hyjal, 2521 Zephras Isle, 2524 Darkspear Islands, 2548 Riverglades,
  2652 Shen'dralas (all Classic-era ids 1411-1461 present too).
- Remaining bulk source to try: the client's own DB2 tables in CASC (`_classic_beta_\Data`): QuestV2.db2 (every quest id), QuestObjective,
  QuestPOIPoint/QuestPOIBlob (objective coordinates), QuestLineXQuest, QuestXP — read-only extraction with a CASC tool
  (wow.tools.local / CASCExplorer + WoWDBDefs). Titles are server-side, so titles still come from gameplay (gossip/quest frames/log —
  Harvest.lua records those automatically).

## Phase 5 (2026-09-18, later): bundled quest database
- tools/build_questdb.lua (lua5.1) loads Questie's Classic tables + applies its corrections (2439 quest / 1411 npc / 733 item / 148 object
  fixes + item-start fixes + blacklist) and writes Data/QuestDB.lua (4257 quests), NpcDB (5482 quest-relevant NPCs, <=12 spawns/zone),
  ObjectDB (889), ItemDB (2859), ZoneDB (304 areaID->uiMapID). ~2 MB Lua. Questie quirk: the generated Classic files carry an OLD copy of
  the key tables — load questDB.lua/npcDB.lua/... AFTER them. sortKeys is not in Database/; rebuilt from lookupQuestCategories.
- DB.lua: QuestStarts/QuestEnds/QuestObjectives/ItemLocations -> locations {map,x,y,name,count}; MatchObjective(questID, idx, gameText)
  matches live objective text to DB objectives; Nearest(locations) by world distance; IsAvailable(questID) (level/race/class/pre/excl/chain);
  Search; AvailableInZone.
- Navigation:ResolveStep: explicit coords > zone-name coords > DB (giver / ender / unfinished objective spawns / npc / item sources) >
  Blizzard waypoint. Guide steps therefore only need {type, quest}. Guide:GetStepText fills names from the DB.
- Tracker.lua (/fg mode auto): picks the nearest progress location across the whole quest log; UI shows the candidate list.
- Commands: /fg mode, /fg quest <id|name>, /fg avail [n], /fg track.
- Tests: 53 checks incl. lean-guide resolution and tracker (lua5.1 tools/test/run_tests.lua).

## Route generator (2026-09-18, later)
- tools/generate_guides.lua: per zone+faction candidate filter (zone via ZoneDB.parent, faction races mask, no hidden/repeatable/daily/
  skill/item-started/breadcrumb, prereqs in set, giver + objectives + ender in zone, exclusive groups -> lowest id), simulated walk
  (hub accept/turn-in within 4 map units, nearest-progress greedy, log cap 20, GRIND step when only level blocks), XP model
  (per-level 40L^2+360L cumulative; quest ~2*(50L+1.5L^2)). Item objectives with a single NPC source become KILL <npc> (loot item).
  55 guides (GEN_<FACTION>_<ZONE>), ~860 KB compiled; chains via next resolved to existing guides. Elwynn 1-10 = 40 quests / 102 steps.
- UI picker lists applicable guides sorted by level (dims those outside level+-3), max 18 rows.
- Arrow.lua (floating TomTom-style arrow, Textures/arrow.tga 128x128 32-bit TGA — confirmed rendering in-game), new window layout.

## Later on 2026-09-18
- Quest level tags everywhere (Quest:LevelTag/TitleWithLevel, GetQuestDifficultyColor colours).
- AutoQuest.lua: auto-accept (on|off|guide) + auto-turn-in via GOSSIP_SHOW/QUEST_GREETING/QUEST_DETAIL/QUEST_PROGRESS/QUEST_COMPLETE;
  SHIFT bypass; multi-reward turn-ins left open; trivial/repeatable skipped unless in the guide.
- Minimap.lua: hand-rolled minimap button (angle saved in db.minimap).
- In-game confirmed: arrow.tga renders, C_Map.GetWorldPosFromMapPos works for Classic Era map ids, distances + directions correct,
  generated Dun Morogh route being played.

## Next
1. First in-game test: `/fg`, `/fg pos` (learn Forever uiMapIDs), `/fg rec dump`, check for Lua errors (`/console scriptErrors 1`).
2. Verify Northshire quest IDs / NPC IDs on Forever with the recorder; fix the sample guide JSON, recompile.
3. Phase 2+: more guides from Questie data, guide editor, route optimizer.

## Update 2026-09-18 (evening) — "do them all" batch: Forever data, route logic, polish (v0.2.0)

**Forever data pipeline**
- `tools/foreverdb.py` (shared): `data-src/forever.json` overlay -> `Data/ForeverDB.lua` (`ns.ForeverDB = { quests, npcs, objects, maps }`).
  Points: `spm` = map coords per uiMapID, `spw` = world coords `{inst, wx, wy}` per uiMapID (converted in-game via
  `C_Map.GetMapPosFromWorldPos`, cached). `data-src/corrections.json` is applied last (`apply_corrections`, `src = fix`).
- `tools/merge_recorded.py`: reads every `WTF\Account\*\SavedVariables\ForeverGuide.lua` + `.bak` (beta sometimes resets SVs),
  additive only: npc points/names, giver/ender links (ACCEPT/OFFER/TURNIN/ENDNPC/PROGRESS/GOSSIP), OBJ progress -> objective points
  (kill npc only trusted when the objective text names the npc; otherwise stored as `near` hint), harvest lines, scan titles.
  Current overlay: 16 quests (6 Forever-only), 2 npcs from the one staged SV file.
- `tools/import_db2.py <folder>`: wago.tools CSV exports (QuestV2, QuestV2CliTask, QuestObjective, QuestPOIBlob, QuestPOIPoint, QuestXP);
  tolerant column lookup; POI points -> `spw`. wago.tools is robots-blocked for fetching — user exports by hand. Untested on real CSVs.
- `DB.lua`: `ApplyOverlay()` at OnInit (vanilla records only gain what they lack; new ids get `forever = true`), `SpawnLocations` handles
  `sp`/`spm`/`spw`, `QuestObjectives` uses `fobj` evidence where vanilla has no locations, `QuestStarts` falls back to `fstart`,
  `ZoneDB.mapNames` for uiMapID names. TOC loads `Data\ForeverDB.lua` before `DB.lua`.
- `build_questdb.lua` now emits `xp` (Questie `QuestXP/DB/xpDB-classic.lua`; 3494 of 4257 quests).

**Route logic (generate_guides.lua)** — user asked for "logical routes" and grey-quest awareness:
- Hubs = clusters of givers/turn-ins (HUB_RADIUS 8). Everything tied to the current hub is done before leaving (objectives of quests
  ending there unless > FAR_OBJ 25 away, turn-ins, givers, objectives within OBJ_RADIUS 22); planned as one tour (NN + 2-opt with
  turn-in-after-objectives constraint, urgency weighted by position). Exhausted hub -> next hub by (waiting score - distance), taking
  on-the-way tasks (DETOUR 8). Tour re-planned whenever the log changes.
- XP: real `q.xp` (+80% for kills), Classic reduction table (<=5 levels above: 100%, then 80/60/40/20, 10%). `worthStarting` skips
  quests at <=20% unless a chain needs them. `URGENCY` = 4 map units per level of headroom; hub accepts sorted lowest level first.
- Result: 1394 turn-ins across 55 guides, 0 leftovers (greedy before: 1085 turn-ins, 23 leftovers), ~26 map units walked per quest.
  Env knobs for experiments: FG_GREEDY, FG_NO2OPT, FG_HUBR, FG_OBJR, FG_FAR, FG_DETOUR, FG_URGW, FG_ACCEPT_NEAR.
- In game: `Quest:XPMultiplier/LevelsUntilGrey/GreyWarning`; Tracker ranks by distance + 60 yd per level of headroom; UI note warns
  "only N% xp - out-levelled" / "loses xp at your next level"; generator writes a note on reduced-xp turn-ins.

**Polish**
- `Options.lua`: Settings canvas category (window/arrow/minimap/lock/hide-in-combat/Blizzard pin, auto-accept all|guide, auto-turn-in,
  announce, auto-pick guide, recorder) + buttons; `/fg options`.
- Hide in combat (`ns.db.ui.hideInCombat`, PLAYER_REGEN_*), `Arrow:HideTemporarily`.
- `Bindings.xml` + `Keybinds.lua` (toggle window/picker/arrow, skip, back, mode, report wrong).
- Picker shows per-guide progress (`step n/N` / `done`).
- `/fg wrong <text>` -> `ns.db.reports` (guide/step/quest/expected loc/player pos/target); `/fg reports [clear]`; `tools/collect_reports.py`.
- `tools/package.py` -> `dist/ForeverGuide-<ver>.zip` (`--dev` adds tools/sources). Version 0.2.0.
- Tests: 72 checks (`lua5.1 tools/test/run_tests.lua`).

**Still open**: terrain-aware distances (roads/cliffs) — deferred; the DB2 import needs real CSVs to validate; recorder-only quests have
no `zone`, so `AvailableInZone` skips them (could derive from spm map); Forever's real quest XP is unknown (vanilla values assumed).
