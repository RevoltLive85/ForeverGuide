# ForeverGuide guide format (JSON)

Guides are written as JSON in `guides-src/`, compiled to Lua by
`tools/compile_guides.py`, and loaded by the addon from `Guides/`.
The addon never contains quest logic for a specific guide; it only
interprets these steps.

```
guides-src/*.json  --compile_guides.py-->  Guides/<ID>.lua + Guides/Guides.xml
```

## Guide

| field      | type     | required | notes |
|------------|----------|----------|-------|
| `id`       | string   | yes      | unique, `[A-Z0-9_]`, used as file name and saved-variable key |
| `name`     | string   | yes      | shown in the UI |
| `version`  | int      | no       | bump when steps are re-ordered; manual completions are reset |
| `faction`  | string   | no       | `"Alliance"` / `"Horde"` |
| `race`     | [string] | no       | English race file names: `"Human"`, `"Orc"`, `"NightElf"`, ... |
| `class`    | [string] | no       | `"WARRIOR"`, `"MAGE"`, ... |
| `minLevel` | int      | no       | used for auto-picking a guide |
| `maxLevel` | int      | no       | |
| `next`     | string   | no       | guide id to continue with when this one is finished |
| `author`   | string   | no       | |
| `notes`    | string   | no       | free text |
| `steps`    | [step]   | yes      | |

## Step

Coordinates and names are optional whenever the bundled quest database knows the quest / NPC /
item: `{ "type": "ACCEPT", "quest": 783 }` is a complete step - the engine looks up the giver,
its position, and the quest title itself, and `KILL`/`COLLECT` steps navigate to the spawns of
whatever objective is still unfinished. Give explicit `map`/`x`/`y` only to override (a specific
camp, a better path) or for quests the database does not have yet (Forever's new quests).

Common fields (all optional unless the type needs them):

| field       | type   | notes |
|-------------|--------|-------|
| `type`      | string | one of the types below (case-insensitive) |
| `text`      | string | what the UI shows; generated from the type when omitted |
| `note`      | string | extra hint shown under the step ("in the cellar", "elite - group up") |
| `quest`     | int    | quest ID |
| `questName` | string | for display before the client has cached the title |
| `objective` | int    | 1-based objective index inside the quest (default: all objectives) |
| `npc`       | int    | creature ID |
| `npcName`   | string | |
| `target`    | string | mob name for KILL/COLLECT display |
| `count`     | int    | amount for KILL/COLLECT/BUY display |
| `item`      | int    | item ID (BUY) |
| `itemName`  | string | |
| `spell`     | int    | spell ID (TRAIN) |
| `spellName` | string | |
| `level`     | int    | GRIND target level |
| `map`       | int    | uiMapID for the coordinates |
| `zone`      | string | map name; fallback when `map` is unknown to the client, required for HEARTH |
| `x`, `y`    | number | 0-100 map coordinates |
| `radius`    | number | yards; TRAVEL completes within this distance (default 15) |
| `optional`  | bool   | shown dimmed; skipped automatically when the following step is done |
| `faction`   | string | step only for this faction |
| `class`     | [string] | step only for these classes |
| `race`      | [string] | step only for these races |

### Types and completion

| type       | needs                | complete when |
|------------|----------------------|---------------|
| `ACCEPT`   | `quest`              | quest is in the log (or already completed) |
| `TURNIN`   | `quest`              | quest flagged completed |
| `COMPLETE` | `quest` [`objective`]| objective(s) finished / quest ready to turn in |
| `KILL`     | same as COMPLETE     | (display: "Kill N target") |
| `COLLECT`  | same as COMPLETE     | (display: "Collect N target") |
| `GRIND`    | `level`              | player level >= level |
| `BUY`      | `item`, `count`      | bag count >= count |
| `TRAIN`    | `spell`              | spell known |
| `HEARTH`   | `zone`               | hearthstone bound to that location name |
| `TRAVEL`   | `map`/`zone`, `x`, `y` | player within `radius` yards |
| `FLY`      | like TRAVEL          | (display: "Fly to") |
| `TALK`     | `npc`                | a gossip / quest / vendor / trainer window opens with that NPC |
| `NOTE`     | `text`               | manual (`/fg skip`), or when the next automatic step completes |

Any step with a `quest` counts as done once that quest is flagged completed,
so a player who is ahead of the guide is moved forward automatically. An
objective/turn-in step whose quest is not in the log sends the player back
to that quest's `ACCEPT` step.

## Example

```json
{
  "id": "HUMAN_NORTHSHIRE_1_6",
  "name": "Northshire Valley 1-6 (Human)",
  "faction": "Alliance",
  "race": ["Human"],
  "minLevel": 1,
  "maxLevel": 6,
  "steps": [
    { "type": "ACCEPT", "quest": 783, "questName": "A Threat Within", "npc": 823, "npcName": "Deputy Willem",
      "map": 1429, "zone": "Elwynn Forest", "x": 48.2, "y": 42.9 },
    { "type": "KILL", "quest": 7, "questName": "Kobold Camp Cleanup", "target": "Kobold Vermin", "count": 10,
      "map": 1429, "zone": "Elwynn Forest", "x": 49.0, "y": 36.3 }
  ]
}
```
