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
  PITCH 17 deg down (a flatter guess: far markers land a bit short on the ground rather than in the sky - the 23 deg first try floated above Lake Everstill), far targets capped at 74% of the height (a horizon guess), aiming at the chest; the target's ground point (distance + angle from Navigation) is projected
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
- Follow-up (Ilya: "the objective marker now and then disappears, and gets bugged when I rotate"): (1) the engine-pin
  mode is now opt-in (`/fg waypoint engine on`, account key `we`, default off) - on this client the state can flip
  and the diamond would jump to the parked frame near the character; (2) targets beside/behind the camera no longer go
  through the perspective formula (which explodes as the point crosses the camera plane and dumped the marker in a
  corner) - they take the ground direction from the character and a **ray clamp** pins them to the edge in that
  direction (left = left edge at the character's height, behind = bottom edge), drawn at 70% alpha; (3) a marker holds
  its last position for 1.5 s across a momentary gap in position/facing data instead of blinking. Tests: 171.

## Update 2026-09-20 (night) — full code audit (two reviewers over every Lua file), v0.3.2
Confirmed and fixed (each with a regression test; 183 tests):
- Guide.IsStepDone: an objective step whose `target` wording matched no live objective text counted as DONE (allCovered
  started true) when the index came from the DB npc/item name - kill steps were skipped at 0/6. Now a text match is
  required; with none, the objective the index points at decides.
- Guide.UpdateNavigation deduped the target by map/x/y only: two steps at one spot (accept then turn in at an npc,
  ~23% of consecutive step pairs) kept the previous label/radius on the arrow, and a TRAVEL to a spot already reached
  could never complete (arrival latch already fired). The target now carries guide id + step index + label.
- Guide.Evaluate: a quest deferred for level that the player then took by hand was never returned to (its objective
  steps stayed "passed over"); the guide now jumps back to it ("<quest> is in your log - back to it").
- Persist: the edit-record separator `|` was stripped by `esc` -> a second `/fg edit` corrupted the first and lost the
  rest after a beta login; `ui.width`, `hideTracker`, `hideOnMap` were never mirrored (snapped back every login);
  WriteChunks now verifies the write (SetCVar false / read-back) and warns once when the 1200-char budget is exceeded;
  the character key falls back to the realm-less key on restore; half-truncated edits no longer crash `/fg edits`.
- Editor.Effective set `edited` for a note/radius-only edit, which switched the resolver away from the nearest spawn /
  Forever npc position (the opposite of what the note-writer wanted). `edited` now means "position or npc pinned";
  `hasEdit` drives the "(edited)" tooltip suffix.
- Quest.Refresh cached the "Quest <id>" placeholder when the title came back secret (combat) and kept it after the
  quest left the log; AutoQuest read the quest id from `info[#info]` (holes -> `frequency`); GetStepText formatted a
  TRAVEL with x but no y; ClearBlizzardWaypoint compared a nil y; the waypoint used raw tonumber on GetCameraZoom;
  `/fg wrong` reports are capped at 300.
- Test harness: the scanner test left stubbed C_QuestLog.GetQuestObjectives/GetQuestDifficultyLevel in place for every
  later test (restored now).
Known limitation (not a bug): the in-world marker's direction is relative to the character's facing, not the camera -
no camera-yaw API exists; a left-drag camera orbit around a standing character does not update it, moving does.

## Update 2026-09-20 (late) — camera-aware marker, skulls over quest mobs (v0.3.3)
- Ilya: "when I right-click-rotate the marker updates, when I left-click-rotate the camera it does not" — solved.
  There is no camera-yaw API, but the engine still moves SuperTrackedFrame for the (Invalid) user waypoint: it parks
  it on an ELLIPSE (500 x 200 UI units) around the screen centre along the target's SCREEN direction as the camera
  sees it. Measured by turning the character in 8 steps (frame walks around the ellipse) and by orbiting the camera
  with the left button (frame moves, facing does not). `Waypoint:EngineDirection()` reads that direction,
  `CameraBearing()` inverts it through the chase-camera model (pitch 25 deg fitted, rms 2.5 deg over 9 samples,
  recovered camera offset 41-60 deg for a true ~55) and `CameraCorrected()` swaps the facing-relative bearing for the
  camera-relative one when they differ by more than 10 deg (smoothed 0.35/tick). `/fg wpdbg` prints both.
- Skulls (Ilya: "like RestedXP: closest targetable quest mob, switch if tagged, also other quest mobs near"):
  `SetRaidTarget` is ADDON_ACTION_FORBIDDEN on this client (RXP disables its markers on >= 12.0 for the same reason),
  so UI/MobMarker.lua draws its own skull textures anchored to enemy nameplates. Wanted names come from the current
  KILL/COLLECT/COMPLETE step (target parts, step npc, DB objective npc / item-dropping npcs); other quest mobs via
  C_QuestLog.UnitIsRelatedToActiveQuest. Big pulsing skull = nearest untagged wanted mob (your current target wins;
  "nearest" = nameplate scale, then lower on screen - UnitPosition is nil for non-group units here); small skulls on
  the rest. Enemy nameplates (cvar nameplateShowEnemies, 45 yd here) are switched on during kill steps and restored
  after / on logout (`plates` setting). Settings mirrored (`sk so sp`), `/fg skull`, options panel section.
  Tests: nameplate mock (MOCK_PLATE), 192 tests.
- Retargeting (Ilya: "when the mob is tagged, remove the skull and target another quest mob"): a tagged mob (by
  someone else) now gets no skull at all. Addons cannot change the target from Lua (protected), so the retarget is a
  SecureActionButton `ForeverGuideTargetButton` (macro "/targetexact <mob>" per wanted name, rewritten out of combat
  only, deferred to PLAYER_REGEN_ENABLED in combat): the skull button between Guide and Guides in the window, and a
  key binding "CLICK ForeverGuideTargetButton:LeftButton" (Key Bindings > AddOns > ForeverGuide > Target the nearest
  quest mob). When the player's own target gets taken, one chat line says so and names the key. /targetexact cannot
  skip tagged mobs itself - press again. Tests: 196.

## Update 2026-09-21 — v0.3.4: group quests, real log cap, corpse run, profiler, lazy guides
- Planner `addGroupQuests`: elite quests whose giver stands at a hub the route already visits (within 2.5 map
  units) are added as OPTIONAL steps (accept + objectives + turn-in, note "group quest - only with company"),
  level/prereq-checked; 9-21 per race route. Engine: optional QUEST steps are walked past unless the player took
  the quest (then guided normally); GRIND optional (no quest) keeps the old "current until passed" behaviour.
- Quest log cap: `C_QuestLog.GetMaxNumQuestsCanAccept()` is **40** on Forever (GetMaxNumQuests 175); planner
  LOG_CAP default 40 (routes unchanged - the cap never bound). Engine: on an ACCEPT step with a full log the note
  names up to 4 log quests the guide does not need ("abandon one").
- Corpse.lua: while a ghost, Navigation.override = "corpse" and the target is C_DeathInfo.GetCorpseMapPosition
  (current map, then parents), "Your corpse - run back"; Guide/Tracker do not touch the target until alive again.
- `/fg perf`: C_AddOnProfiler metrics (12.x). Measured in Redridge: 0.10-0.13 ms per frame steady, all 50 frames
  over 5 ms at login/reload, memory 43 MB -> 31 MB after making compiled guides lazy (steps are a closure built on
  first use; `stepCount` for lists; `Guide.StepCount(g)`). Ilya's 25-41 fps is the GPU, not the addon.
- Tests: 205 (group quests, full log, corpse, restricted nameplates, secure target macro).
- v0.3.5: Bags.lua (C_Container: free/total, grey items with a sell value, never quest items; nearest vendor from
  ItemDB vendors + NPCLocations; header tag, chat on threshold crossing / loot step, popup line). MobMarker: wanted
  names only from OPEN objectives; `FinishedNames()` = mobs of finished objectives across the log (minus those an
  open objective still needs) get no skull; `liveToDB` is strict (DB objective name must appear in the live text -
  Forever's "Kill Dire Condor" has no counterpart in the old data, and the same-position fallback pointed at the
  goretusks). 211 tests. Release zip: `python tools/package.py` -> dist/ForeverGuide-<ver>.zip; CHANGELOG.md.
- Bags banner (top centre, red FULL / orange nearly full, click = snooze 2 min); bag tag first in the header.
- ItemTips.lua: item tooltips get quest lines - "Quest item: <quest> (1/5)" from the live log (objective text
  naming the item, works for Forever rewrites), "Quest item for: <quest>" from QuestDB item objectives
  (orange "later in your guide - keep it" when ahead on the route), "Starts a quest", and "No longer needed:
  <quest> is done - safe to sell" once the quest is turned in and nothing else (log / route / untaken DB quest)
  wants it; session memory of item->quest from objective texts. Bags counts such leftovers as sellable.
- Crowd.lua (Ilya: "when there are too many people near our questing area, go somewhere else"): MobMarker
  reports free/tagged wanted mobs + player GUIDs per scan; over a 90 s window the busiest snapshot decides:
  >= 3 taken and >= 60% taken, or >= 5 players -> banner "Crowded: 7 of 9 quest mobs are taken by others" with
  the nearest other spawn cluster of the same mobs (DB spawn points clustered at 120 yd, >= 150 yd away,
  compass direction) and a "Go there" button (navigation override "crowd" until arrival), else another open
  step of the guide elsewhere; chat reminder every 3 min; x snoozes 5 min. 226 tests.
- Zone population (Ilya: "use /targetfriend to count players"): TargetNearestFriendPlayer is protected for addons,
  but /who is not - `C_FriendList.SetWhoToUi(true)` + `SendWho('z-"<zone>" L-3..L+4')` every 150 s while on a kill
  step, WHO_LIST_UPDATE -> GetNumWhoResults (client caps at 49 -> "50+"). >= 25 same-faction players of our level
  band in the zone = busy: the crowd banner adds "38 players of your level in Redridge Mountains · quieter zone:
  Duskwood" and the button becomes "Switch zone" (activates the fitting zone guide, or another race's route chapter
  for starter zones). `/fg who` prints and re-asks. 230 tests.
- Crowd rules (Ilya): "more than 4 players around -> skip the current quest step, unless it is kill-x-mobs or
  loot-from-mobs; for kill quests we can join a party". `Crowd:IsSharedKillOrLoot(step)`: KILL with count > 1 or
  unnamed, COLLECT/COMPLETE whose DB objective is an item dropped by mobs or a kill -> shared (crowd only slows
  it; the quieter-spot advice applies); a named single mob (count 1 + npc), an object, an event, an escort -> not
  shared -> `Guide:Postpone(idx, 600, "5 players around")` walks past it for 10 min (`Guide.postponed`, row shown
  dimmed "postponed - crowded (back in N min)"), `Guide:Unpostpone` pulls the persisted step index back. Only the
  player-count rule (>= 5 players seen on nameplates / target / mouseover) postpones, not the tag ratio. For shared
  KILL steps out of a group the banner adds "kill credit is shared in a group - invite them" and an Invite button:
  `C_PartyInfo.InviteUnit` for up to 4 same-faction players seen in the last 3 min (nameplates, target, mouseover) -
  player-initiated only. 237 tests.
- Group-up reminder (Ilya: "in a kill-x area we need a warning like the bags one"): the crowd banner now also shows
  green "Kill quest with N players around - group up, kill credit is shared" + Invite when a shared kill step (or
  any OPEN kill objective in the log - `MobMarker:OpenKillNames()`, so a quest picked up off-guide counts) has
  >= 2 other players or any tagged mob around, below the crowded threshold. To actually see the players, friendly
  PLAYER nameplates (nameplateShowFriends=1, NPC/pet/guardian/totem/minion sub-cvars 0) are switched on during
  kill steps and restored after (`/fg skull friends off`, option "show other players' nameplates"). 239 tests.
- Crowd banner layout (Ilya: "visual bug" - title ran under the x button, sub text cut off): 560 wide, title
  anchored RIGHT to the close button's LEFT, sub wraps to 2 lines (maxLines) anchored RIGHT to the leftmost visible
  button, `Layout(f, showInvite, showGo)` re-anchors and grows the frame from GetStringHeight (min 58). Title
  shortened to "Group up - kill credit is shared", the player count lives in the sub line. `/fg crowd test` previews
  the banner for 10 s (`Crowd:Preview`, Update() is held while `Crowd.preview`); `/fg crowd on|off`. v0.3.6, 241 tests.
- Travel steps / resync (Ilya: "the resync button doesnt work it seems" - level 18 standing in Westfall, the
  Westfall chapter stuck on "Travel to Westfall 640 yd", every /fg resync answering "now at step 1"): a chapter's
  TRAVEL/FLY step only completed on FG_NAV_ARRIVED inside its 60 yd radius, so being in the zone was not enough and
  resync (which just re-runs Evaluate) came straight back to it. `Guide:IsZoneEntry(step, idx)` = the first mapped
  step of a chapter, or one whose map differs from the nearest earlier mapped step; such a step is done once
  `Guide:OnStepMap` finds the player on that map (parents walked, GetZoneText as a fallback). In-zone travel steps
  ("follow the road south", the hand-written Northshire guide) keep needing the arrival. FG_ZONE_CHANGED now
  re-evaluates while a travel step is current instead of only re-aiming the arrow. A manual step (TRAVEL/NOTE/TALK)
  goes stale when any of the next LOOKAHEAD=6 automatic steps is done (was: only the very next one) - quests
  accepted out of order prove the player is past it. `Guide:Resync` additionally marks manual steps before the
  furthest done step as done, restarts the walk from step 1 (done steps are skipped in one pass) and the chat line
  names where it landed ("resynced: nothing to skip, still at step 3/55: Accept [10] A Swift Message").
  `MOCK_ZONE(mapID, zone, x, y)` added to the mock; 249 tests.
- Race-restricted quests in a race route (Ilya: "the quest in the guide has been done already" - standing at
  Quartermaster Lewis, who offered nothing): `/fg quest 6181` said `state: NOT_STARTED (wrong race/faction)`.
  6181 "A Swift Message" is the Human copy of the courier chain; the planner picked quests with the whole
  faction mask (`RACE_ALLIANCE`/`RACE_HORDE`), so the Dwarf route carried it, the client never flags it
  completed, and its turn-in kept the accept step alive. `DB:RaceClassOK(questID)` = the permanent half of
  IsAvailable (race + class bits only, cached per race/class so a test can switch character), used by
  `Guide:StepApplies`, so every step of such a quest falls out of the route with one chat line the first time.
  The planner now uses `raceMask(zd, faction)` (the route's own races OR'd - Dun Morogh = Dwarf|Gnome) and
  `questOK`'s cache key no longer assumes two masks. 6 quests across all generated routes were affected
  (6181/6361/6365/6387, the same courier family), so the guides were NOT regenerated - that would renumber
  every step and lose saved progress mid-play; the engine guard covers them.
- Found by the same test run: the "optional group quest taken by hand" rewind never existed. Its test passed
  because the fixture used ids 4001/4002, which are real level-48 Horde quests, so the LEVEL GATE deferred
  them and the deferred machinery did the rewind. Fixture ids moved to 990001/990002 (outside the database)
  and `Guide.optionalPassed[quest] = idx` (set when an optional step is walked past, consulted in Evaluate
  step 0b) now takes the guide back once the quest is in the log. 252 tests.
- Level-up announcement, Ding.lua (Ilya: "when we level up there should be a party message/emote message ...
  I leveled up to 'level' in 'time played this level'"): `ForeverGuide: I leveled up to 18 in 3h 10m` to PARTY /
  RAID / INSTANCE_CHAT when grouped, EMOTE when solo (`/fg ding on|off|test|time|<channel>`, options-panel
  switch, mirrored in the cvar store as `dg`/`dc`). `SendChatMessage` works from an addon on Forever 1.60.1
  (verified live, emote and the /fg ding test path); it is pcall'd and `C_ChatInfo.InChatMessagingLockdown` is
  checked, and a refusal prints the line locally instead of erroring. TIME: `TIME_PLAYED_MSG(total, thisLevel)`
  is requested 5 s after login and 3 s after each ding; a request made AFTER the ding answers ~0 for the new
  level, so the module keeps the last answer and adds the time since (exact while online). The client's two
  "Total time played / Time played this level" lines are swallowed for 4 s around our own request - and on this
  client they pass BOTH `ChatFrame_DisplayTimePlayed` and the CHAT_MSG_SYSTEM filter, so the working suppression
  is a wrapper around each ChatFrame's `AddMessage` (prefixes from TIME_PLAYED_TOTAL/TIME_PLAYED_LEVEL).
- Options panel overflow (Ilya: "the text is overflowing"): the canvas category does not clip, so the growing
  checkbox list drew over the game below the settings window. The list now lives on a ScrollFrame child
  (plain "ScrollFrame", no template - the retail templates are not guaranteed here), wheel-scrolled 60 px a
  notch with the range taken as max(client range, child height - frame height), plus a "Scroll for the rest of
  the settings." hint under the subtitle. 277 tests.
- Pace.lua (`/fg xp`): xp/h over a rolling 30 min window of *measured play* (Tick() drops gaps > 5 min, a 30 s
  heartbeat keeps it honest), time to the next level, and the route model for context: every generated chapter
  carries the planner's budget, read from `modelMinutes`/`modelXph` when present and parsed out of `notes`
  otherwise (the guides on disk predate the fields; plan_route/compile_guides now emit them). `Pace:Chapter()`
  compares elapsed time against the model's share for the steps done (ratio = model/actual, so > 1 is fast);
  `RouteRemaining()` sums the model minutes of the rest of the route and scales them by that ratio for a "level
  60 in about N h of play" line. The next-level estimate also rides in the Quest Guide header subtitle.
- Gear wear folded into the bags banner: `Bags:Durability()` over the 11 slots that wear (GetInventoryItemDurability),
  warning under 25% or on any broken piece, worst piece named, same nearest-vendor line; full bags still win the
  banner. `MOCK_GEAR(percent, overrides)` in the mock.
- Off-route chapters (seen live: a level-20 dwarf in Duskwood following "6. Ashenvale 19-22 (Night Elf)" while
  /fg path said the Dwarf route - a crowd zone-switch or a hand-picked chapter can do this, and with the new
  race guard its Night-Elf-only quests are all skipped): `Guide:OffRouteChapter()` names the race and the
  chapter of the character's own route that fits the level, `Guide:WarnOffRoute()` says it once per guide on
  activation and on level-up, and AutoPick now charges another race's route chapter 12 (vs 2/8) so it never
  drifts there on its own. A route the player chose with /fg path is left alone. 309 tests.
- Reminders.lua (Ilya asked for both): flight points and the trainer.
  FLIGHT: `C_TaxiMap.GetTaxiNodesForMap(map)` on Forever 1.60.1 returns the whole CONTINENT's node list
  (38 on Kalimdor) for any map id, with name/position/faction - but `isUndiscovered` is ALWAYS false
  (Thunder Bluff reads "discovered" for an Alliance dwarf), and `GetAllTaxiNodes` returns 0 unless a flight
  master's map is open. So the known ones are learned instead: TAXIMAP_OPENED / TAXI_NODE_STATUS_CHANGED ->
  `LearnFromTaxiMap()` files every node whose state is not Unreachable into `ns.char.flightpoints`, and
  UI_INFO_MESSAGE == ERR_NEWTAXIPATH files the nearest node. Until something has been learned only the
  "within 400 yd" nudge fires (the zone list would be guesswork); names starting `zz` are the client's
  retired entries and are dropped. `/fg fp` lists the nearest four and points the arrow at one
  (Navigation.override "flightpoint", owner "fp", released on arrival or `/fg fp off`); `/fg fp debug`
  dumps what both APIs answer. Verified live in The Barrens: Ratchet 1.3 km, Talrendis Point 2.7 km, ...
  TRAINER: TRAINER_SHOW records `ns.char.lastTrained` (level) and, per class, the trainer's name/zone/coords
  in `ns.db.trainers[classFile]`; two levels later the ding prints "level 22 - new ranks at your class
  trainer (you last trained at 20). Last one you used: Bink in Ironforge - 1.2 km away". `/fg remind
  flight|trainer on|off`, both in the options panel, `rmf`/`rmt` in the account mirror and `tr` in the char
  mirror. 332 tests.
- Instance.lua (Ilya: "when in a dungeon, we need to disable the quest guide, so it doesnt interfere"):
  `IsInInstance()` types party/raid/scenario/pvp/arena count as quiet places. `UI:Suspend(on, "dungeon")` is a
  new, settings-free suspension: `UI:AllHidden()` now returns true while any reason is suspended, so every
  consumer that already asked it (Bags/gear banner, Crowd banner, MobMarker skulls + its nameplate cvar
  forcing, the minimap button) goes quiet for free; the window is hidden, Arrow/Waypoint get
  HideTemporarily("suspend"), and `QG:ApplyTracker` now keys off AllHidden so Blizzard's own tracker comes
  BACK inside the instance (the dungeon quests need it). `ns.db.ui.hiddenAll` is untouched, so a player who
  had hidden everything themselves stays hidden on the way out. `/fg dungeon on|off` (default on), options
  toggle, `dn` in the account mirror. The Options "hide everything" checkbox now reads `db.ui.hiddenAll`
  directly rather than AllHidden(), or it would tick itself inside a dungeon. 345 tests.
- Arrow/waypoint default swap (Ilya, live: "the guide arrow feels sluggish when rotating my character", then
  "redo the arrow, it should be like the old way, just an arrow pointing above the characters head"): the
  in-world diamond (UI/QuestWaypoint.lua) was the everyday indicator by default, and by default it could not
  ride the engine's own SuperTrackedFrame (GetTargetState Invalid on this client, same old bug), so it placed
  itself by guessing a screen position from a modelled chase camera plus a camera-direction estimate reverse-
  engineered from SuperTrackedFrame's own (wrong) parked position, blended in with an EMA (0.35) so the guess
  did not jitter as the character turned - that smoothing is exactly what read as sluggish. Fix: `WP:PinShown()`
  now also requires `EngineUsable()`, so the diamond only ever shows when `/fg waypoint engine on` is set AND
  the client can genuinely project the pin; there is no more guessed-placement fallback in Tick() at all
  (BearingPosition/CameraCorrected are left in the file, still unit-tested as pure functions, but unreached).
  With the diamond off by default, Arrow.lua (the plain chevron, always instant - it turns straight off
  Navigation's real facing-relative angle, no smoothing) is unsuppressed and is the default indicator again,
  matching how the addon behaved before QuestWaypoint.lua existed. No saved-setting migration needed: `engine`
  already defaulted to false/opt-in, so this took effect on Ilya's live character immediately.
  Reentrancy bug this surfaced (fixed in Navigation.lua): Arrow now calls `Nav:Update(true)` synchronously on
  every FG_NAV_TARGET_CHANGED (it used to be suppressed while the diamond was the default, which is why this
  was never seen live) - so a target already inside its arrival radius the instant it is set (e.g. `/fg fp`
  while already standing next to the flight point) fired FG_NAV_ARRIVED from inside `SetTarget` itself, and
  Reminders' arrival handler released the flight-point override and handed navigation back to
  `Guide:UpdateNavigation()` *before* `Rem:GoToFlightPoint()` had returned - so the caller's own `SetTarget`
  call was immediately overwritten with the guide's step. Caught by the existing `/fg fp takes the marker`
  test (it had been silently passing for the wrong reason: an earlier test left `waypoint engine on`
  lingering, which took Tick() down the "engine" branch that never calls Update() - turning it back off at
  the end of that test block, as the new default now does for real players too, exposed the bug immediately).
  Fix: `Nav:Update()` now fires FG_NAV_ARRIVED a tick later (`ns.Events:After(0, ...)`, guarded against the
  target having already changed by the time it runs) instead of inline, so a caller mid-way through setting a
  target always finishes before anything reacts to arrival. 345 tests.
