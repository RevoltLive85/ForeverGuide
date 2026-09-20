# Changelog

## 0.3.5 - 2026-09-21
- Bag space: "bags 2/16" tag in the header, a chat line when space runs low or a loot step starts, the info popup names how many grey items to sell and the nearest vendor; quest items are never counted.
- Skulls follow objective completion: a mob whose objective is already complete (5/5 snouts) gets no skull even while its quest is still in the log; strict matching against the live objective text for quests Forever rewrote.

## 0.3.4 - 2026-09-21
- Group (elite) quests offered as optional steps at hubs the route visits; taken by hand, they are guided normally.
- Quest log cap read from the client (40 on WoW Forever); a full log on an accept step names quests the guide does not need.
- Corpse run: while a ghost the marker points at your corpse and hands back to the guide once you are alive.
- `/fg perf` (Blizzard's addon profiler) and lazy guide loading: memory 43 MB -> 31 MB, ~0.1 ms per frame.

## 0.3.3 - 2026-09-20
- In-world marker follows the camera: the camera's direction is recovered from the client's own (invalid) pin.
- Skulls over quest mobs on enemy nameplates: big skull on the nearest untagged mob of the current step, small ones on other quest mobs, none on mobs tagged by others; skull button / key binding targets the nearest one (`/targetexact`, the one way an addon may change your target).
- Enemy nameplates switched on during kill steps and restored afterwards.

## 0.3.2 - 2026-09-20
- Full code audit: objective steps need real evidence to complete; navigation target per step; deferred quests taken by hand are resumed; cvar mirror keeps every step edit, window width and tracker/map toggles; note-only edits no longer move the waypoint; assorted nil guards.

## 0.3.1 - 2026-09-20
- Routes are a choice: `/fg path`, ROUTES section in the picker; the race route is the recommended default.
- Waypoint placed by a chase-camera projection when the client cannot project the pin; horizon cap; edge pinning for targets beside or behind you.
- Quest log wins over a stale completion flag right after `/reload`.

## 0.3.0 - 2026-09-20
- Route planner rewrite (xp-per-hour model, per-race 1-60 routes, 43 standalone zone guides), RestedXP cross-reference, Skyborne routes.
- Quest Guide UI redesign: parchment panel, numbered rows, gold diamond waypoint with dotted route, world-map handling.

## 0.2.x - 2026-09-18/19
- Bundled quest database, client quest tables, `/fg scan`, hide-everything switch, SavedVariables workaround.
