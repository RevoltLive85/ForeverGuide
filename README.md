# ForeverGuide

Free, data-driven leveling guide engine for **WoW Forever** (beta 1.60.x, Retail 12.x engine, TOC `16001`).
It reads game state and shows you the next step. It never automates anything: no casting, no movement,
no chat, no combat assistance.

```
ForeverGuide DB (JSON)  ->  tools/compile_guides.py  ->  Guides/*.lua  ->  addon engine  ->  WoW Forever
```

## License

The [MIT license](LICENSE) covers only original ForeverGuide code and assets owned by RevoltLive85. It does **not** grant rights to redistribute the bundled Questie-derived database or other third-party-sourced material; see [Data/README.md](Data/README.md) for attribution and check those sources' terms separately.

## Install

1. Download `ForeverGuide-<version>.zip` from the [releases page](https://github.com/RevoltLive85/ForeverGuide/releases)
   (or clone this repo) and unzip it so that you get `World of Warcraft\_classic_beta_\Interface\AddOns\ForeverGuide\ForeverGuide.toc`.
2. Log in, enable **ForeverGuide** on the AddOns screen. If the beta has moved to a newer build than the addon's
   TOC number, tick **Load out of date AddOns** on that screen - the addon reads game state defensively and keeps
   working across builds.
3. First login: the Quest Guide window picks the leveling route for your race and level on its own and the gold
   diamond in the world points at the first step. **Guides** (button or `/fg guides`) lists every route of your
   faction, the chapters of the one you follow, and standalone zone guides - the race route is only a
   recommendation. **Guide** opens the step details with Back / Skip / Auto / Resync.
4. Alt-click the minimap button (or `/fg hideall`) hides everything while the guide keeps running.

**Beta caveat:** this client build never reads SavedVariables back, so the addon mirrors your progress and settings
into CVars every 30 s and restores them at login ("beta workaround" line in chat). Step edits and reports live in the
SavedVariables file and can be lost - `tools/apply_edits.py` folds them into the guide source.

Developers: the addon folder doubles as the repo (`tools/`, `guides-src/`, `data-src/` are not loaded by the game);
`python tools/package.py` builds the release zip, `lua5.1 tools/test/run_tests.lua` runs the engine tests.
Then:

| command | what |
|---|---|
| `/fg` | status: level, zone, map id + coords, quest log with objective progress, current guide step, target info |
| `/fg help` | every command |
| `/fg guides` / `/fg guide <name>` | list / start a guide |
| `/fg skip` `/fg back` `/fg step <n>` `/fg reset` | move through the guide |
| `/fg pos` | your uiMapID + coordinates, printed as a ready-to-paste TRAVEL step |
| `/fg target` | npc id, level, reaction of your target |
| `/fg way 42.3 71.8` | point the arrow at a coordinate on your current map |
| `/fg rec dump 20` | last 20 recorded facts (quest accepts/turn-ins with NPC + coords, kills, zones) |
| `/fg mode auto` | navigate your quest log directly (nearest objective / turn-in), no guide needed; `/fg mode guide` to follow the guide |
| `/fg quest 783` / `/fg quest kobold` | everything the database knows: giver, objectives with coordinates, turn-in, prerequisites |
| `/fg avail` | quests you could pick up in the current zone, with their givers and distances |
| `/fg auto accept on\|off\|guide`, `/fg auto turnin on\|off` | auto-accept / auto-turn-in at NPCs (on by default; hold SHIFT to do it by hand; multi-choice rewards are left to you) |
| `/fg minimap on\|off` | minimap button: left click window, right click guide picker, shift-click arrow, **alt-click hide everything**, drag to move |
| `/fg waypoint on\|off`, `/fg route on\|off` | the in-world gold waypoint and the dotted path towards it (`/fg wpdbg` prints what places it; `/fg waypoint engine on` rides the client's own pin instead of our projection - off by default, the Forever client cannot project it) |
| `/fg skull on\|off`, `/fg skull others\|plates on\|off` | skull over the nearest untagged mob of the current kill/collect step, small skulls over the other quest mobs around, none on mobs tagged by others; the skull button in the window (or its key binding) targets the nearest mob of the step; enemy nameplates are switched on during kill steps (the skulls ride on them) |
| `/fg path` / `/fg path dwarf` / `/fg path race` | leveling routes are a **choice**: list every route of your faction, follow another race's one, or go back to your race's own (the recommended default) |
| `/fg qg scale\|opacity\|width\|rows\|wpsize <n>` | Quest Guide look; `/fg qg completed\|distances\|subtitles on\|off` |
| `/fg hideall [on\|off]` | hide the window *and* the arrow at once (same as alt-clicking the minimap button); the guide keeps running in the background |
| `/fg scan` | ask the server about every quest id 1-100000; log out, then `python tools/scan_diff.py` lists Forever's new quests vs Questie |
| `/fg wrong <text>` / `/fg reports` | report the current step as wrong (saved with your position + target); `python tools/collect_reports.py` turns the reports into a review list |
| `/fg options` | options panel (also Esc -> Options -> AddOns -> ForeverGuide); key bindings under Key Bindings -> AddOns |
| `/fg persist [save]` | state of the SavedVariables workaround (see *Beta caveats*) |
| `/fg resync` | levelled elsewhere? skips the quests that would give 20% xp or less and continues from the first open step |
| `/fg edit here` / `npc` / `note <text>` / `radius <yd>` / `clear`, `/fg edits` | fix the current step in place (position = where you stand, npc = your target); saved per guide, `python tools/apply_edits.py` folds the edits into the guide source |

The window and the floating arrow are draggable while unlocked (`/fg unlock` / `/fg lock`); `/fg arrow off` hides the arrow, `/fg bliz off` disables the Blizzard map-pin arrow. The **Guides** button opens a picker (auto mode or any installed guide); **Auto**/**Guide** switches modes.

## Layout

```
ForeverGuide/
  ForeverGuide.toc
  Core.lua          namespace, secret-value-safe helpers, module registry, lifecycle
  Database.lua      SavedVariables (ForeverGuideDB account, ForeverGuideCharDB per char)
  Events.lua        one event frame + internal FG_* message bus + debounce
  Persist.lua       beta workaround: mirrors guide/progress/settings into CVars (SavedVariables are not read back)
  Player.lua        level, faction, class, race, map, zone, coords, facing, target/npc info
  Quest.lua         quest log snapshot, states, objective diffing, titles, Blizzard waypoints
  Navigation.lua    map coords -> distance/direction, arrival detection, Blizzard user waypoint
  Guide.lua         guide registry + the step interpreter (advance / recovery / skip)
  DB.lua            access to the bundled quest database (where does a quest start / end / its objectives)
  Tracker.lua       auto mode: navigates the quest log using the database
  Recorder.lua      Phase 10 data recorder (quest -> npc -> coords -> level) into SavedVariables
  Scanner.lua       quest id scanner (/fg scan) -> which quest ids exist on Forever's server
  UI.lua            coordinator of the interface + the guide picker
  UI/Theme.lua      textures, colours, fonts, backdrops, buttons, pulse ticker (Textures/*.tga from tools/make_textures.py)
  UI/QuestGuideFrame.lua   the Quest Guide window (parchment + gold), header, list, Guide / Guides buttons
  UI/QuestGuideHeader.lua, QuestList.lua, QuestRow.lua   the rows: number ring, kind icon, title, objective line, distance
  UI/QuestWaypoint.lua     the in-world gold waypoint: rides on the engine's super-tracked pin when the client can
                           project it, otherwise placed by a chase-camera perspective model; the camera's direction is
                           recovered from where the engine parks its (invalid) pin (+ QuestRoute.lua dotted path)
  UI/MobMarker.lua         skulls over quest mobs, anchored to enemy nameplates (raid icons are blocked for addons here)
  UI/QuestGuideConfig.lua  settings (/fg qg ..., options panel)
  Arrow.lua         compact gold chevron - fallback when the world pin cannot show (Textures/chevron.tga)
  AutoQuest.lua     auto-accept / auto-turn-in through the normal quest windows
  Minimap.lua       minimap button
  Options.lua       options panel (Settings canvas category)
  Editor.lua        in-game step corrections (/fg edit) applied over the guide data
  Keybinds.lua      key binding names + functions for Bindings.xml
  Commands.lua      /fg
  Init.lua          boots the lifecycle (last in the TOC)
  Data/             bundled quest database built from Questie's Classic data (see Data/README.md)
                    + ForeverDB.lua: WoW Forever additions (recorded in-game / client tables), merged at load
  data-src/         forever.json (collected Forever data), corrections.json (hand fixes, win over everything),
                    db2/ (the wago.tools CSV exports of the client's quest tables)
  Guides/           compiled guides (generated - do not edit)
  guides-src/       guide sources in JSON (SCHEMA.md documents the format)
  tools/
    compile_guides.py   JSON -> Lua  (python tools/compile_guides.py)
    build_questdb.lua   Questie Classic DB (+ corrections) -> Data/*.lua   (lua5.1 tools/build_questdb.lua <Questie> .)
    plan_route.lua      Data/*.lua -> guides-src/GEN_*.json  (one 1-60 route per starting race, see Route logic)
    lib/route_model.lua xp / time model; lib/route_data.lua zones, map sizes, travel graph, overlay
    import_rxp.py       factual quest positions from RestedXP's free Forever guides -> overlay
    questie_lookup.py   quest/NPC/object/item facts + step JSON from the Questie DB
    scan_diff.py        /fg scan results vs Questie: new / removed / renamed quests
    merge_recorded.py   SavedVariables (recorder/harvest/scan, incl. .bak, every account) -> data-src/forever.json -> Data/ForeverDB.lua
    import_db2.py       wago.tools CSV exports of Forever's own quest tables (QuestV2, QuestObjective, QuestPOI*) -> same overlay
    collect_reports.py  "/fg wrong" reports -> data-src/reports.json + review list
    apply_edits.py      "/fg edit" corrections -> guides-src/*.json (then compile_guides.py)
    sync_to_github.cmd  commit + push this folder to github.com/RevoltLive85/ForeverGuide (double-click after editing)
    package.py          dist/ForeverGuide-<version>.zip (--dev includes tools and sources)
    test/               headless engine test: lua5.1 tools/test/run_tests.lua
```

## WoW Forever data (the ~1000 new quests)

Vanilla quests come from Questie. Everything Forever adds is collected into `data-src/forever.json`
and shipped as `Data/ForeverDB.lua`, which `DB.lua` merges over the vanilla tables at load (vanilla
records only gain what they lack; unknown ids become new records flagged `forever`). Two sources:

* **Playing with the recorder on** (default): quest accepts / turn-ins with NPC id + coordinates,
  objective progress with position, gossip lists, zone maps. After a session:
  `python tools/merge_recorded.py` (reads every `WTF\Account\*\SavedVariables\ForeverGuide.lua` and `.bak`).
* **The client's own tables**: export `QuestV2`, `QuestV2CliTask`, `QuestObjective`, `QuestPOIBlob`,
  `QuestPOIPoint` as CSV from `https://wago.tools/db2/<Table>?build=1.60.1.69913` into a folder, then
  `python tools/import_db2.py <folder>`. Objective positions are world coordinates (`spw`) and are
  converted to map coordinates in-game.

Hand fixes go into `data-src/corrections.json` (applied last). Player reports (`/fg wrong`) are
collected with `tools/collect_reports.py`. Rebuild the guides after the data changes.

What the client's tables actually contain on build 69913: `QuestV2` is only the **list of quest ids**
(6600 - no titles, levels or zones; those are server-side), and the POI tables hold ~50 static
points. The id list is still gold: it is shipped as `Data/ForeverQuestIDs.lua` and tells the addon
which vanilla quests are gone from Forever (711 - later-phase content, battlegrounds, mount
exchanges; they are excluded from routes and `/fg avail`) and which ids are Forever's own (3054).
**`/fg scan new`** asks the server for exactly those ids and records title, level and objective texts
as they arrive (the server throttles; run it in the background over a few sessions, `/fg scan status`
shows progress), then `tools\sync_to_github.cmd` / `merge_recorded.py` folds them in. Positions of
the new quests come from the recorder while you play them.

## Route logic (the planner)

`tools/plan_route.lua` builds **one continuous 1-60 route per starting race** (Human, Dwarf/Gnome,
Night Elf, Orc/Troll, Tauren, Undead, and Skyborne for both factions), written as a chain of zone
chapters (`guides-src/GEN_<FACTION>_<RACE>_<nn>_<ZONE>.json`, ~45 per race). "Fastest" means xp per
second of modelled play:

* `tools/lib/route_model.lua` prices everything in seconds - walking (yards from the real map sizes,
  run speed, mount at 40), kills (mob level, drop rates, elites), gathering, escorts, talking - and pays
  the real quest reward (Questie's xp table, Classic grey reduction) plus kill xp (Classic formula).
* The yardstick is the **grind rate**: xp/s from killing even-level mobs. A quest that pays less than
  60% of that, with its share of the travel and what it unlocks down its chain counted, is skipped -
  grinding would be faster. Elite/group quests, class quests, dungeon-only chains are skipped.
* The player state carries through the whole route: xp, quest log (cap 20), finished quests (so chains
  continue across zones), position, hearthstone. Deliveries to a zone the route will not revisit are
  never accepted; a full log gets its stuck deliveries abandoned (the guide says so).
* The next chapter is chosen by **simulating every plausible zone** (and the capital, for turn-ins and
  new quests) from the current state and taking the best xp / (travel + chapter time). A zone is left
  when what remains is not worth the time and revisited later when it is - Joana's Barrens x4. When no
  chapter beats 70% of the grind rate the route says *grind here* and names a mob spot.
* Inside a chapter: hubs (clusters of givers / turn-ins). Everything tied to the current hub is done as
  one loop out of town (objectives; nearest-neighbour + 2-opt in seconds, quests about to go grey first),
  hand-ins on the way back, then the next hub by a tour over the hubs with something waiting, each hub
  kept only if what waits there pays for the detour. Travel between zones uses a graph of walks, boats
  and zeppelins; the hearthstone is used when it saves time.
* Cross-reference: RestedXP's free WoW Forever guides supplied the positions of the new Forever quests
  (see Data/README.md); Joana's and RestedXP's routes were used to sanity-check the zone order.

Regenerate after a database change (about a minute for all races):

    lua5.1 tools/plan_route.lua && python tools/compile_guides.py

`FG_TRACE=1` prints every chapter decision, `FG_STEPS=<areaID> FG_WHY=1` explains every quest of a zone,
`FG_VALUE`, `FG_GRINDF`, `FG_KILLTIME`, `FG_DROP`, `FG_LOGCAP`, `FG_MOUNTLVL` tune the model. The
modelled total (about 115 h without rested xp, dungeons or Forever's ~1000 new quests) is a yardstick
for comparing routes, not a promise.

## Writing a guide

Steps only need a type and a quest id when the bundled database knows the quest:
`{ "type": "ACCEPT", "quest": 783 }`, `{ "type": "KILL", "quest": 7 }`, `{ "type": "TURNIN", "quest": 7 }`.
Names and coordinates come from the database at runtime (explicit `x`/`y` override them).

1. `python tools/questie_lookup.py steps 783 7 33` prints ACCEPT/KILL/COLLECT/TURNIN steps with IDs and
   Questie coordinates for those quests. Paste them into `guides-src/<ID>.json`, order them, add notes.
2. `python tools/compile_guides.py` validates and writes `Guides/<ID>.lua` + `Guides/Guides.xml`.
3. `/reload` in game.

Coordinates use `map` (uiMapID) plus a `zone` name as fallback: if Forever does not know the Classic
Era uiMapID, the engine matches the zone by name against the player's current map. Run `/fg pos` in
each zone to learn Forever's real IDs; the recorder also stores every map it sees.

## Beta caveats (1.60.1)

* **SavedVariables are written at logout but never read back at login** (confirmed on build 69913 -
  every session started from scratch). `Persist.lua` works around it: the active guide, step, progress,
  mode, settings and step edits are mirrored into addon-registered CVars (which the client does persist)
  and restored when the SavedVariables come back empty. `/fg persist` shows the state. Big data
  (recorder entries, `/fg wrong` reports) still only lives in the SavedVariables *files*, which are
  overwritten at every reload - `tools\sync_to_github.cmd` harvests them (merge_recorded / collect_reports)
  before committing, so run it regularly.
* Everything from the game can be a secret value in combat. All reads go through `ns.Plain*` helpers.
* The classic quest IDs / NPC IDs in the sample guide come from Questie's Classic Era data and must be
  verified on Forever (`/fg rec dump`).
