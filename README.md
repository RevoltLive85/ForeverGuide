# ForeverGuide

Free, data-driven leveling guide engine for **WoW Forever** (beta 1.60.x, Retail 12.x engine, TOC `16001`).
It reads game state and shows you the next step. It never automates anything: no casting, no movement,
no chat, no combat assistance.

```
ForeverGuide DB (JSON)  ->  tools/compile_guides.py  ->  Guides/*.lua  ->  addon engine  ->  WoW Forever
```

## Install / test

The folder is already in `_classic_beta_\Interface\AddOns\ForeverGuide`. Log in, enable it on the
AddOns screen, then:

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
| `/fg minimap on\|off` | minimap button: left click window, right click guide picker, shift-click arrow, drag to move |
| `/fg scan` | ask the server about every quest id 1-100000; log out, then `python tools/scan_diff.py` lists Forever's new quests vs Questie |
| `/fg wrong <text>` / `/fg reports` | report the current step as wrong (saved with your position + target); `python tools/collect_reports.py` turns the reports into a review list |
| `/fg options` | options panel (also Esc -> Options -> AddOns -> ForeverGuide); key bindings under Key Bindings -> AddOns |

The window and the floating arrow are draggable while unlocked (`/fg unlock` / `/fg lock`); `/fg arrow off` hides the arrow, `/fg bliz off` disables the Blizzard map-pin arrow. The **Guides** button opens a picker (auto mode or any installed guide); **Auto**/**Guide** switches modes.

## Layout

```
ForeverGuide/
  ForeverGuide.toc
  Core.lua          namespace, secret-value-safe helpers, module registry, lifecycle
  Database.lua      SavedVariables (ForeverGuideDB account, ForeverGuideCharDB per char)
  Events.lua        one event frame + internal FG_* message bus + debounce
  Player.lua        level, faction, class, race, map, zone, coords, facing, target/npc info
  Quest.lua         quest log snapshot, states, objective diffing, titles, Blizzard waypoints
  Navigation.lua    map coords -> distance/direction, arrival detection, Blizzard user waypoint
  Guide.lua         guide registry + the step interpreter (advance / recovery / skip)
  DB.lua            access to the bundled quest database (where does a quest start / end / its objectives)
  Tracker.lua       auto mode: navigates the quest log using the database
  Recorder.lua      Phase 10 data recorder (quest -> npc -> coords -> level) into SavedVariables
  Scanner.lua       quest id scanner (/fg scan) -> which quest ids exist on Forever's server
  UI.lua            the guide window + guide picker
  Arrow.lua         floating direction arrow (Textures/arrow.tga)
  AutoQuest.lua     auto-accept / auto-turn-in through the normal quest windows
  Minimap.lua       minimap button
  Options.lua       options panel (Settings canvas category)
  Keybinds.lua      key binding names + functions for Bindings.xml
  Commands.lua      /fg
  Init.lua          boots the lifecycle (last in the TOC)
  Data/             bundled quest database built from Questie's Classic data (see Data/README.md)
                    + ForeverDB.lua: WoW Forever additions (recorded in-game / client tables), merged at load
  data-src/         forever.json (collected Forever data), corrections.json (hand fixes, win over everything)
  Guides/           compiled guides (generated - do not edit)
  guides-src/       guide sources in JSON (SCHEMA.md documents the format)
  tools/
    compile_guides.py   JSON -> Lua  (python tools/compile_guides.py)
    build_questdb.lua   Questie Classic DB (+ corrections) -> Data/*.lua   (lua5.1 tools/build_questdb.lua <Questie> .)
    generate_guides.lua Data/*.lua -> guides-src/GEN_*.json  (one route per zone and faction)
    questie_lookup.py   quest/NPC/object/item facts + step JSON from the Questie DB
    scan_diff.py        /fg scan results vs Questie: new / removed / renamed quests
    merge_recorded.py   SavedVariables (recorder/harvest/scan, incl. .bak, every account) -> data-src/forever.json -> Data/ForeverDB.lua
    import_db2.py       wago.tools CSV exports of Forever's own quest tables (QuestV2, QuestObjective, QuestPOI*) -> same overlay
    collect_reports.py  "/fg wrong" reports -> data-src/reports.json + review list
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

## Route logic

The generator thinks in hubs (clusters of givers / turn-ins): everything tied to the current hub is
finished before the route moves on - objectives of quests that turn in there, turn-ins, givers,
objectives close by - planned as one tour (nearest-neighbour + 2-opt). When a hub is exhausted the
next one is the hub with the most waiting, and givers / objectives on the way are taken along.
Quest XP is the real reward (Questie's XP table) with the Classic reduction for out-levelled quests,
so lower-level quests are ordered first and never left to turn grey; quests that would give 20% or
less are skipped unless a chain needs them. In game, auto mode ranks the quest log the same way
(distance + levels of headroom before the reward shrinks) and the window warns when a quest is about
to lose xp.

## Generated zone guides

`tools/generate_guides.lua` builds a guide for every classic zone and faction from the database
(55 guides, `guides-src/GEN_*.json`): it picks the quests the faction can do in the zone, drops
repeatables / dailies / profession and item-started quests / breadcrumbs / chains whose
prerequisites live elsewhere, then simulates a hub-by-hub walk (see *Route logic*) with a real XP
model so quests are picked up at the right level.
Starting zones are race-locked and chain into the faction's next zone via `next`. Regenerate after
a database rebuild:

    lua5.1 tools/generate_guides.lua && python tools/compile_guides.py

They are sensible routes, not speedrun routes; the engine adapts as you play.

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

* SavedVariables are written on logout but reportedly not always read back on login. The addon works
  from defaults when that happens; progress may need `/fg step <n>` after a fresh login.
* Everything from the game can be a secret value in combat. All reads go through `ns.Plain*` helpers.
* The classic quest IDs / NPC IDs in the sample guide come from Questie's Classic Era data and must be
  verified on Forever (`/fg rec dump`).
