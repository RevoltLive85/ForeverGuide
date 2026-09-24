# Changelog

## 0.3.9 - 2026-09-24
- Arrow size is now a real slider in the options panel (Esc -> Options -> AddOns -> ForeverGuide), not just `/fg arrow size` - drag it and the chevron above your head resizes live. `/fg arrow <anything else>` now tells you it didn't understand instead of quietly flipping the arrow off, which is what a mistyped option used to do.

## 0.3.8 - 2026-09-24
- The chevron above your head can now be resized: `/fg arrow size <0.5-2.5>` (or `/fg qg arrowsize <value>`), saved and restored like everything else.

## 0.3.7 - 2026-09-24
- The compact chevron above your head is the everyday direction indicator again, the way it was before the in-world waypoint diamond existed. Reported live as "the guide arrow feels sluggish when rotating my character": the diamond's default placement guessed a screen position from your facing plus an estimate of which way the camera itself was pointed, blended in with a smoother so the guess would not jitter - and that smoothing is exactly what made it lag a beat behind when you turned. The chevron has no guess to smooth: it turns straight from your real facing, instantly. `/fg waypoint engine on` still puts the diamond up for players who want it and whose pin the client can genuinely project (it now only ever rides the real pin - it no longer falls back to the guessed placement, so there is nothing left in it that can feel sluggish).
- Fixed a reentrancy bug this change surfaced: a navigation target already inside its arrival radius the moment it is set (standing right next to the flight point you just asked `/fg fp` to walk you to, say) could fire "arrived" from inside the very call that set the target, and a handler reacting to that (releasing the flight-point override, handing navigation back to the guide) reassigned the target before the original caller had finished with it - so `/fg fp` could hand you straight back to your quest step instead of pointing at the flight point. Arrival is now announced one tick later, which costs nothing a player would notice and closes the reentrancy off.

## 0.3.6 - 2026-09-21
- Dungeons: inside a party or raid instance (and in battlegrounds / arenas) the guide steps aside - window, arrow, in-world marker, skulls and banners - and Blizzard's own objective tracker comes back for the dungeon quests. Everything returns as it was on the way out, without touching your settings. `/fg dungeon off` keeps the guide up inside.
- Flight points: a node of your faction you have not taken yet is named when you enter the zone and again when you come within 400 yd of it; `/fg fp` lists them and walks you to the nearest one (the guide gets its marker back when you arrive).
- Trainer: two levels after the last time you trained, a line at the ding - with the trainer you used last, its zone and how far away it is. `/fg remind flight|trainer on|off`, switches in the options panel, both kept in the cvar mirror.
- A chapter belonging to another race's route (a dwarf left on the Night Elf route by a zone switch or a hand-picked chapter) says so once, names the chapter of your own route that fits your level, and auto-pick no longer wanders onto one.
- `/fg xp`: levelling pace - xp per hour over a rolling window of real play, how long the next level will take at that rate, how you compare with the minutes the route planner budgeted for the chapter you are in, and what that means for the rest of the route to 60. The next-level estimate also sits in the Quest Guide header.
- The bags banner does repairs too: gear under 25% (or any broken piece) raises the same banner with the worst piece and the nearest vendor; full bags still come first.
- The options panel scrolls: the checkbox list had grown past the bottom of the settings window and drew over the game. The wheel moves it, and the footer text wraps inside the panel.
- Level-up announcement: "ForeverGuide: I leveled up to 18 in 1h 24m" goes to your party (raid / instance group when you are in one) and as an emote when you are solo. The time is the time played at the level you just left, taken from the server's own counter. `/fg ding on|off|test|time` or a channel (auto, party, raid, guild, emote, say, yell), and a switch in the options panel.
- Quests your race or class can never take are no longer part of the route: the planner offered them to the whole faction, so the Dwarf chapter asked for the Human-only "A Swift Message" and sat at a quartermaster with nothing to say. The step and its turn-in are skipped with one line in chat, and the route planner now plans each race route with that race's own quest mask.
- An optional group (elite) quest taken by hand brings the guide back to it, wherever it had walked past it.
- A chapter's "travel to <zone>" step finishes when you reach the zone (not only within 60 yd of the hub it names), and a zone change re-evaluates the guide - the Westfall chapter no longer sits on "Travel to Westfall" while you stand in Westfall. Travel steps inside a zone still need the arrival.
- Resync moves forward: travel/note/talk steps before the furthest thing you have actually done are marked done, the walk restarts from the top, and the chat line names the step it landed on.
- Artwork: ComfyUI-rendered gold ornaments (tools/make_art.py from tools/art-src/): the in-world waypoint diamond, a compass emblem for the header and minimap button, a skull medallion on the target button, corner scrolls on the Quest Guide panel and info popup, and a new row icon set (! ? swords bag boot check).
- Crowd safeguard: quest mobs tagged by others, player nameplates and `/who` zone counts decide when an area is too busy; a crowded step (unless kill-x / loot-item) is postponed for 10 minutes with a quieter spawn, step or zone offered.
- Group-up banner on any open kill objective with others around: kill credit is shared in a group, so an Invite button asks the players seen near you; banner laid out in two lines with the buttons clear of the text.
- Corpse marker while dead, on-screen bags-full banner, quest-item tooltip lines (in your log / later on your route / left over and safe to sell).

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
