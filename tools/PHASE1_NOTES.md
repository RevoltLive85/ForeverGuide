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

## Update 2026-09-18 (late) — full recheck, review fixes, editor, GitHub

**Verification**: every global / C_ API / template / texture / event the addon uses was checked against the live 1.60.1
function list (all present); the mock is now strict (undefined global reads error, Settings API mocked, OnUpdate ticked)
and the test suite fails on any swallowed error. Two subagent code reviews (engine + UI/automation) -> 30 findings, all fixed:
- Guide: `StepObjectiveIndex` (multi-objective quests: each KILL/COLLECT step tracks its own objective by target name),
  `/fg back` holds, recovery note persists, chained-guide event order, optional steps self-complete, `Resync()`.
- Tracker ticker pcall'd + always re-armed; rethink only when active; no writes into cached DB location tables.
- Navigation: arrival detection moved into `Nav:Update` + an invisible poller (works with the window hidden); target `owner`
  (guide vs tracker) so the tracker's arrivals do not complete guide TRAVEL steps; Blizzard pin only cleared if still ours;
  `SetBlizzardWaypointEnabled`; `Update(true)` shares one result per 40 ms across window/arrow/poller.
- Quest: `IsCompleted` trusts a turn-in for 30 s (flag lag), `RequestLoadQuestByID` once per id, collapsed-header warning.
- DB: `QuestObjectives` cached (rebuilt after ApplyOverlay), `MatchObjective` positional-first, `WorldToMap` guarded.
- Core `Safe` hole-safe (`select("#")`), Events error keys per handler.
- AutoQuest: direct QUEST_DETAIL path now filters trivial/repeatable (`C_QuestLog.IsQuestTrivial/IsRepeatableQuest`) and
  player-shared quests (`UnitIsPlayer("questnpc")`), ignores a closed window (id 0); greeting path uses the quest id
  returned by `GetAvailableQuestInfo`; defaults materialised at load (options panel shows the truth).
- Arrow: placeholder only in explicit drag mode (`FG_LOCK_CHANGED` carries the boolean), grey when facing unknown.
- Scanner tick generation, Harvest re-entrancy, picker label layout + clamp, header widths, TOC note wording.
**Routing**: hub visiting order is itself a tour (NN + 2-opt over hubs with pending work) -> no trailing treks (Dun Morogh
now: Coldridge -> Kharanos -> Brewnall -> Rumbleshot -> Kharanos -> east -> Ironforge/Loch Modan hand-ins). Elite/group
quests are routed as `optional`; objective steps with many spawns carry `near` (runtime picks the nearest DB spawn).
**Editor** (`Editor.lua`): `/fg edit here|npc|note|radius|clear`, `/fg edits`, applied at runtime via `Editor:Effective`,
folded into guides-src by `tools/apply_edits.py`. `/fg resync` skips out-levelled quests.
**GitHub**: the AddOns folder is a git checkout of https://github.com/RevoltLive85/ForeverGuide (initialised and pushed from
the PC through the cc-shell tool, `core.autocrlf=false`); `tools/sync_to_github.cmd` for manual edits. Claude commits + pushes
after every install via `cc_run` in that folder. Tests: 96 checks.

## Update 2026-09-18 (night) — live in-game verification, SavedVariables workaround (v0.2.2)
- Live test through computer use on the running client (WowB.exe, char Sniff-Yahbooty lvl 11 dwarf in Dun Morogh): v0.2.1/0.2.2
  load without Lua errors; window, arrow, level tags, `/fg` readout, guide switching all render correctly.
- **Root cause of "wrong guide on login"**: the beta client writes `WTF\...\SavedVariables\ForeverGuide.lua` at every
  logout/reload but never reads it back (both account and per-character files) -> every session starts with nil SVs,
  `AutoPick` ran and (before the fix) could pick Darkshore for a dwarf; progress was lost each reload.
  Evidence: after reload N the file only ever contains data produced since reload N-1 (compared .lua vs .lua.bak).
- Fixes: (1) `Guide:AutoPick` now scores level fit, current zone (guides carry `map`/`zone` headers), same continent,
  and the race's `next` chain -> Loch Modan for a level-11 dwarf in Dun Morogh. (2) `Persist.lua`: mirrors
  activeGuide/step/done ranges/mode/autoPick + settings (ui/arrow/minimap/nav/auto/recorder) + step edits into
  addon-registered CVars (`ForeverGuideA0..5` account, `ForeverGuideC<NameRealm>0..5` per char, 200 chars each) via
  `C_CVar.RegisterCVar/SetCVar/GetCVar`; `Database.freshAccount/freshChar` detect the empty load; restore in
  `Persist:OnInit` (TOC: right after Events.lua); saved on FG_* events (2 s debounce), every 30 s, and at logout.
  Verified in game: `/reload` -> "restored your guide, progress and settings from the cvar mirror", Dun Morogh step 36 kept.
- Recorder / reports data is still SV-file-only (overwritten every reload, one generation in .bak):
  `tools\sync_to_github.cmd` now runs merge_recorded.py + collect_reports.py before committing.
- Tests: 103 checks (mock C_CVar + a simulated empty-SV login).

## Update 2026-09-19 — client quest tables imported (v0.2.3)
- Ilya exported QuestV2 / QuestPOIBlob / QuestPOIPoint / QuestInfo / QuestLabel from wago.tools for build 1.60.1.69913 (no
  QuestV2CliTask / QuestObjective offered). On this build QuestV2 = ids only (6600 rows: ID, UniqueBitFlag, UiQuestDetailsThemeID);
  POI tables hold 54 blobs / 99 points (Mount Hyjal 2482 etc). Files kept in data-src/db2/.
- Result: 3546 ids shared with Questie, **3054 Forever-only ids** (1742 in 90104-99234, ~1100 in 60000-89999, 217 low ids Questie
  blacklists), **711 Questie quests absent from the client** (Naxx 72, Silithus 61, AQ 49, EPL 44, BGs, mount exchanges, hidden).
  The shipped routes already contained none of the 711 (other filters caught them) - verified.
- `Data/ForeverQuestIDs.lua` (ranges -> `ns.ForeverQuestIDs`, `ns.ForeverNewQuestIDRanges`, counts). `DB:ApplyOverlay` flags
  vanilla quests missing from it `removed`; `IsAvailable` -> "not in WoW Forever"; `Guide:StepApplies` skips them; generator skips them.
- `/fg scan new`: scans exactly the Forever-only id ranges; on QUEST_DATA_LOAD_RESULT also stores `scan.info[id] = { lvl, obj }`
  via `C_QuestLog.GetQuestDifficultyLevel` / `GetQuestObjectives`; `merge_recorded.py` folds level + objective texts into the overlay.
- `import_db2.py` matches wago's `Table.<build>.csv` names and no longer creates empty quest stubs from id-only rows.
- Tests: 104.

## Update 2026-09-19 (later) — `/fg scan new` results folded in
- Ilya ran `/fg scan new`: 372 s, **800 of the 3064 Forever-only ids answered** (title + level + objective texts), 2264 silent
  (never load => treated as not existing on this build). Because the beta client never reads SavedVariables back, the scan
  survived only in `ForeverGuide.lua.bak` (one reload older); copy kept as `data-src/sv/ForeverGuide.scan-new.2026-09-19.lua`.
- Overlay now: **769 quests (754 Forever-only), 756 titled, 705 with level, 128 with real objective wording**. Level spread
  is mostly 60 (162), 6 (111), 10 (70), 11, 20, ... - the new content sits at the level-60 end plus the starter zones.
- `merge_recorded.py`: PLACEHOLDER now also drops `[Never used]`, `[DNT] ...`, `[PH]`, `[NYI]`, `[TEMP]`, `UNUSED...`;
  `clean_objective()` strips progress counters and drops objective texts that are only a counter (`0/5`) - the client
  gives no wording for ~300 of the scanned quests until the quest is in the log, so those slots stay without text.
- Still missing for routing: **positions**. None of the 754 new quests has a giver / turn-in / objective location yet;
  the recorder (on by default) collects them while playing, `tools/sync_to_github.cmd` folds them in. Until then the new
  quests show up in auto mode / objective tracking by title and level, but the shipped guides don't include them.
- Tests: 104.

## Update 2026-09-19 — "hide everything" switch (v0.2.4)
- **Alt-click the minimap button** hides the guide window *and* the arrow in one go; alt-click again puts back exactly
  what was showing. Also `/fg hideall [on|off]`, a key binding ("Hide / show everything"), and an Options checkbox.
- The addon keeps running while hidden (steps advance, auto-accept/turn-in still fire, the tracker still thinks) - it
  just draws nothing. The minimap icon is desaturated/dimmed while hidden, and the tooltip says "hidden (still tracking)".
- `Arrow:HideTemporarily(on, reason)` now takes a channel, so combat-hide and the hide-all switch cannot undo each
  other; `UI:OnCombat` skips both hide and restore while the switch is on.
- State lives in `ns.db.ui.hiddenAll` (+ `hiddenAllPrev.window`), mirrored in the cvar workaround as `ha`, so it
  survives the beta's SavedVariables bug. `UI:Show()` (any explicit show path) clears the switch.
- Tests: 119 (15 new: alt-click hide/restore, combat interaction, command, cvar round-trip).

## Update 2026-09-20 — route planner rewrite (v0.3.0), RestedXP cross-reference, Skyborne
- Old per-zone generator replaced by `tools/plan_route.lua` + `tools/lib/route_model.lua` + `tools/lib/route_data.lua`:
  time model (yards from map sizes, kill xp/time by mob level, drop rates, escorts, grind rate as the yardstick), one
  continuous 1-60 route per starting race (8 routes incl. Skyborne A/H), chapters chosen by simulating every candidate
  zone from the carried state, value-filtered quests (60% of grind rate incl. chain unlock value), abandon rule for
  stuck deliveries, hearthstone use, GRIND steps with a mob spot. 372 chapters, 3.3 MB compiled.
- Big bugs found by the harness on the way: chapter candidate set was frozen at chapter start (chain follow-ups never
  eligible -> thin chapters, 41 h grinding); home-hub turn-ins interleaved with objectives (zig-zag walks); deliveries to
  out-levelled zones clogging the log; chain starters valued without what they unlock.
- Modelled totals: ~116 h Alliance / ~118 h Horde without rested xp, dungeons or Forever's new content; 29-35 h of that
  is grinding, nearly all at 42-44 and 52-60 (Classic's thin non-elite pool there; Forever's 162 new level-60 quests are
  not routable yet - no positions).
- Cross-reference (user request): Joana's Horde route (zone order, revisits), expcarry's Forever guide (new zones:
  Riverglades 35-45 ~200 quests, Zephras Isle Skyborne start, 9 new dungeons, mount granted with riding skill),
  RestedXP 4.11.x free Forever guides (`Interface\Guides\Forever`, CC BY-NC-SA): `tools/import_rxp.py` takes only the
  facts - 226 quests: titles, giver/turn-in positions (npc ids where given), objective areas, class tags, inferred
  chains - into the overlay. 156 Forever quests are now routable, incl. all of Zephras Isle (map 2521, synthetic areaID
  102521). RXP's paid guides are encrypted and untouched. Our Human 1-11 now does 39 quests vs RXP's 112 for 1-13
  (theirs includes class quests and Stormwind trips).
- Engine: `ffin` (turn-in position without npc id), overlay `classes`/`pre` for new quests, tests updated (119).
- Open: verify in-game that Darkshore-at-11 for humans (the model's pick over Westfall) is really faster; elite quests
  as optional steps; cross-zone objectives; real quest-log cap (`C_QuestLog.GetMaxNumQuestsCanAccept`); Forever xp
  values; the recorder should log map sizes (`data-src/mapsizes.json`) for the new maps.

## Update 2026-09-20 — Quest Guide UI redesign (v0.3.0 UI)
- Spec from Ilya: premium fantasy panel on the right (dark parchment, thin gold rim, soft glow), header "QUEST GUIDE 6/14",
  rows = number ring + kind icon + title + objective line + distance, active row outlined/glowing/pulsing with a gold bar,
  completed rows dimmed, two compact buttons [Guide] [Guides], and the big green arrow replaced by an in-world gold
  diamond waypoint with name + distance and a dotted route.
- Built as UI/*.lua modules on top of the untouched engine: Theme (textures drawn procedurally by tools/make_textures.py:
  panel_bg, border_gold, glow_gold, border_thin, row_active, row_bar, header_line, separator, button(_hl), icons atlas,
  ring, waypoint, dot, chevron - all 32-bit TGA, power of two, top-left origin), QuestGuideConfig (ui.opacity/maxRows/
  showCompleted/showDistances/showSubtitles, nav.waypoint{enabled,size,animate,route}; /fg qg, /fg waypoint, /fg route;
  Options panel items; cvar mirror keys op rows sc sd ss wp rt wa ws), QuestGuideHeader, QuestRow (states available/
  active/done/blocked/optional/future, click = jump, right-click current = skip, tooltip with note/grey warning), QuestList
  (row pool, distances on a 0.25 s throttle, resolution cached per refresh), QuestGuideFrame (window + "Guide" info popup
  with Back/Skip/Auto/Resync), QuestWaypoint (fades SuperTrackedFrame's own art, overlays diamond + name + distance at
  its screen position; falls back to Arrow.lua's compact gold chevron when the engine has no pin), QuestRoute (14 dots
  between the player's feet and the pin, BACKGROUND strata). UI.lua is now the coordinator + restyled picker with the
  same public API (tests: 142).
- The world pin relies on the Retail engine's user waypoint / super-track (already used by /fg bliz); if a client build
  lacks SuperTrackedFrame the chevron shows instead.
- ComfyUI (on Ilya's PC) is the plan for real artwork (compass, corner ornaments, diamond) - NOT while the game runs: the
  GPU is already at ~88% of its budget and losing the device (see the crash analysis above).

## Update 2026-09-20 (later) — in-game test fixes
- Level gate: planner accepted quests at req-1 (wrong: `req <= L` now); engine `Guide:LevelGate` skips an ACCEPT the
  level does not allow yet (`progress.deferred[quest] = idx`, note "needs level N - skipped until then", rows shown as
  blocked), jumps back to it on FG_LEVEL_CHANGED; deferred list mirrored in the cvar workaround (`df`). Test added.
- Position precedence: Forever evidence beats Questie. `DB.SpawnLocations` uses overlay `spm`/`spw` instead of vanilla
  `sp` when present (falls back when world points cannot be converted); `Navigation:ResolveStep` prefers a Forever npc
  position for ACCEPT/TURNIN/TALK steps over the planned coordinates; planner `spawnLocs` uses overlay map points
  (`fsp`) and can convert world points offline once `data-src/mapbounds.json` exists (the recorder now logs each map's
  world bounds; merge_recorded writes mapbounds.json + mapsizes.json). merge_recorded: the first recorded interaction
  position of an npc replaces guide-sourced points. import_rxp: world-coordinate gotos (`map/inst,ew,ns`) and named
  vanilla NPCs (unique names -> Questie ids) -> 441 npc records with RestedXP positions (380 in world coords).
  Marshal Marris: Questie == RestedXP == reality (near the bridge) - the "pin in the lake" was the viewing angle.
- UI: Quest Guide panel strata HIGH; Blizzard objective tracker faded + click-through while the panel shows
  (`hideTracker`, /fg tracker on|off); info popup 360 wide, close button top-right, height from real text; edge
  textures: top/bottom tiles are stored rotated 90 deg by the client (make_textures handles it); picker hint width.
- Screen coordinates for computer use: click coordinates are in the reported frame (1456x819 here), not in the
  scaled screenshot's pixels.
- Zone guides: `plan_route.lua` also writes 43 standalone `GEN_ZONE_<FACTION>_<ZONE>` guides (unraced, "Zone: Westfall
  10-20") so any character can quest a zone outside its race route (Ilya: "missing the Westfall guide" on a dwarf).
- Planner fixes from that: Forever quests without recorded objectives were free deliveries in the model (Darkshore looked
  like 55k xp/h) -> `questCost` charges an average kill quest for them; boat / zeppelin edges cost 8-15 min; a mild
  same-continent preference (`CROSS_SEA` 0.85). Dwarf route is now Dun Morogh > IF > Loch Modan > Westfall > Redridge >
  Duskwood > Wetlands ..., Human: Elwynn > IF > Westfall > Loch Modan > Redridge > Duskwood > Wetlands.

## Update 2026-09-20 (evening) — routes are a choice; the waypoint bug
- Routes: `Guide:Routes()` lists every generated route of the faction (`GEN_<FACTION>_<RACE>` chapters), `mine` marks
  the race's own; `Guide:ChooseRoute(key|label|race)` stores `ns.char.route` (cvar mirror `r`) and activates the
  chapter fitting the level; `CurrentRoute()` = chosen or the race's own; AutoPick prefers the followed route (+8
  penalty off-route when one is chosen, +2 otherwise). `Guide:Applicable` no longer locks guides to the race (faction
  and class only). Picker sections: Auto, ROUTES, CHAPTERS - <route>, ZONE GUIDES, OTHER GUIDES. `/fg path`.
  Ilya: "players should be able to choose their leveling route, we can only recommend it".
- Waypoint bug ("the diamond is next to me but the target is 78 yd away"): `/fg wpdbg` showed why. On the Forever
  client `C_Navigation.GetTargetState()` is 0 (Invalid) for a user waypoint in the open world, the engine fades
  SuperTrackedFrame to alpha 0 and parks it at a meaningless spot near the character (clamped=true, position
  unrelated to the direction). The distance from C_Navigation matches ours, so the pin's world point is right - only
  the projection is missing in this build. Fix: `Waypoint:EngineUsable()` (frame shown, state ~= Invalid,
  HasValidScreenPosition, alpha > 0) gates the "ride the engine pin" mode; otherwise the diamond is placed by a small
  **chase-camera perspective model** (`Waypoint:BearingPosition`): camera GetCameraZoom() yards behind the character,
  PITCH 23 deg down, aiming at the chest; the target's ground point (distance + angle from Navigation) is projected
  with a ~90 deg horizontal FOV (focal length = half the UIParent width). Verified in Lakeshire: Hilary 75 yd at
  ~22 deg right lands on the NPC (0.67 w, 0.79 h). A plain ring around the character was tried first and was far too
  compressed sideways ("the marker isn't pointing to the NPC"). Behind the camera -> pushed below the character at
  70% alpha; x clamped to 6..94% of the width, y to 8..90% of the height. Same limitation as every Classic arrow:
  the direction is relative to the player's facing, not the camera (no camera-yaw API), so it is exact while moving
  and off while the camera is swung around a standing character. No direction at all -> chevron.
- Reload quirk: `C_QuestLog.IsQuestFlaggedCompleted` came back true for Hilary's Necklace (3741) right after /reload
  while the quest was still in the log, ready to turn in, and the guide walked past the turn-in (`/fg quest hilary`
  and a later /run both said flag=false). `Guide:IsStepDone` now takes the flag only when the quest is NOT in the
  log (ACCEPT steps are done either way); regression test added.
- Tests: mock `GetCenter` now honours a CENTER-on-BOTTOMLEFT anchor, UIParent is 1280x720; route tests compare ids
  (Routes() builds fresh tables). 163 tests.
