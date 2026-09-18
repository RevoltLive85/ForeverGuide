-- ============================================================
-- ForeverGuide / Commands.lua
-- /fg and /foreverguide
-- ============================================================

local _, ns = ...
local Commands = ns:NewModule("Commands")

local C, D, OK, END = ns.COLOR, ns.COLOR_DIM, ns.COLOR_OK, ns.COLOR_END

local HELP = {
    "/fg                 status readout (level, zone, coords, quests, current step)",
    "/fg show|hide|toggle   guide window",
    "/fg guides          list guides   |  /fg guide <name>   start a guide",
    "/fg skip | back | step <n> | reset     move through the guide",
    "/fg quests          quest log with objectives and states",
    "/fg mode auto|guide   auto = navigate your quest log (no guide needed), guide = follow the active guide",
    "/fg quest <id|name>   everything the database knows about a quest (giver, turn-in, objectives, coords)",
    "/fg avail [n]       quests you could pick up in this zone, with their givers",
    "/fg track           what the auto tracker would point you to right now",
    "/fg pos             map id + coordinates (for writing guides)",
    "/fg target          info about your target (npc id etc.)",
    "/fg nav             distance/direction to the current step",
    "/fg way <x> <y>     point the arrow at x,y on your current map",
    "/fg lock|unlock     lock or unlock the window and the arrow  |  /fg scale <0.5-2>  |  /fg resetpos",
    "/fg arrow on|off    the floating direction arrow",
    "/fg minimap on|off  the minimap button",
    "/fg auto [accept on|off|guide] [turnin on|off]   auto-accept / auto-turn-in quests (hold SHIFT at an NPC to do it by hand)",
    "/fg rec on|off|status|dump [n]|clear   data recorder (Phase 10)",
    "/fg scan [from] [to] | stop | resume | status   find every quest id the server knows (diff vs Questie with tools/scan_diff.py)",
    "/fg harvest [sweep [from to] | status]   passive quest discovery: quest lines of every zone map / client cache sweep",
    "/fg bliz on|off     also use Blizzard's own waypoint arrow",
    "/fg wrong [text]    report the current step as wrong (coords/npc/quest) - saved with your position for the route fixer",
    "/fg reports [clear] what you reported so far (tools/collect_reports.py turns them into corrections)",
    "/fg options         open the options panel",
    "/fg debug           toggle debug output",
}

local function StateMark(state)
    local S = ns.Quest.STATE
    if state == S.COMPLETED then return "[x]" end
    if state == S.READY_TO_TURN_IN then return "[!]" end
    if state == S.FAILED then return "[F]" end
    if state == S.IN_PROGRESS then return "[ ]" end
    return "[-]"
end

-- ------------------------------------------------------------
-- Sub commands
-- ------------------------------------------------------------
local handlers = {}

function handlers.status()
    local P, Q, G, N = ns.Player, ns.Quest, ns.Guide, ns.Navigation
    local build = ns.PlainString(select(2, ns.Safe(GetBuildInfo))) or "?"
    ns.Printf("%sForeverGuide v%s%s (build %s)", C, ns.version, END, build)
    ns.Print(P:Describe())

    local mapID, x, y = P:GetMapPosition()
    local zone, sub = P:GetZone()
    local mapName = P:GetMapName(mapID)
    ns.Printf("Zone: %s%s  |  map %s (%s) @ %s",
        zone ~= "" and zone or "?", sub ~= "" and (" - " .. sub) or "",
        tostring(mapID or "?"), mapName or "?",
        x and string.format("%.1f, %.1f", x, y) or "n/a")

    local num, max = Q:GetNumQuests()
    ns.Printf("Quests (%d%s):", num, max > 0 and ("/" .. max) or "")
    local shown = 0
    for entry in Q:Iterate() do
        if not entry.isHidden then
            local state = Q:GetState(entry.questID)
            local f, r = Q:GetProgress(entry.questID)
            local prog = r > 0 and string.format(" %d/%d", f, r) or ""
            ns.Printf("  %s %s%s%s", StateMark(state), Q:TitleWithLevel(entry.questID, entry.title), prog,
                state == Q.STATE.READY_TO_TURN_IN and (OK .. " ready" .. END) or "")
            shown = shown + 1
        end
    end
    if shown == 0 then ns.Print("  (none)") end

    if G.active then
        local cur, total = G:GetStepCount()
        ns.Printf("Guide: %s%s%s  [step %d/%d]", OK, G.active.name or G.active.id, END, math.min(cur, total), total)
        local step = G:GetCurrentStep()
        if step then
            ns.Printf("Now:  %s> %s%s  (%s)", OK, G:GetStepText(step), END, G:GetStepProgress(step))
            if N.target then ns.Printf("      %s", N:Describe()) end
            if G.note then ns.Warn(G.note) end
            local nxt = G.active.steps[cur + 1]
            if nxt then ns.Printf("Next: %s%s%s", D, G:GetStepText(nxt), END) end
        else
            ns.Print("Guide complete.")
        end
    else
        ns.Print("Guide: none active (/fg guides)")
    end

    local t = P:GetTargetInfo()
    if t then
        ns.Printf("Target: %s (npc %s, lvl %s, %s%s)", t.name, tostring(t.npcID or "-"), tostring(t.level or "?"),
            t.reaction, t.isQuestRelated and ", quest related" or "")
    end
end

function handlers.help()
    for _, line in ipairs(HELP) do ns.Print(line) end
end

function handlers.show() ns.UI:Show() end
function handlers.hide() ns.UI:Hide() end
function handlers.toggle() ns.UI:Toggle() end

function handlers.guides()
    local G = ns.Guide
    if #G.list == 0 then ns.Print("no guides loaded.") return end
    ns.Print("Guides:")
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        local active = (G.active == g) and (OK .. " (active)" .. END) or ""
        local usable = G:Applicable(g) and "" or (D .. " [not for this character]" .. END)
        ns.Printf("  %s%s%s  %s  %s-%s  %d steps%s%s", C, id, END, g.name or "", tostring(g.minLevel or "?"),
            tostring(g.maxLevel or "?"), #g.steps, active, usable)
    end
    ns.Print("start one with /fg guide <id or name>")
end

function handlers.guide(rest)
    if rest == "" then
        if ns.Guide.active then
            ns.Printf("active guide: %s (%s)", ns.Guide.active.name or "", ns.Guide.active.id)
        else
            ns.Print("no guide active.")
        end
        return
    end
    local g = ns.Guide:Find(rest)
    if not g then ns.Error("no guide matches '" .. rest .. "'") return end
    ns.Guide:Activate(g.id)
end

function handlers.skip() ns.Guide:Skip() end
function handlers.back() ns.Guide:Back() end
function handlers.next() ns.Guide:Skip() end

function handlers.step(rest)
    local n = tonumber(rest)
    if not n then ns.Print("usage: /fg step <number>") return end
    ns.Guide:SetStep(n)
end

function handlers.reset(rest)
    if rest == "all" then
        ns.Database:ResetAll()
        ns.Print("all settings and progress reset. /reload recommended.")
        return
    end
    ns.Guide:Reset()
    ns.Print("guide progress reset.")
end

function handlers.quests()
    local Q = ns.Quest
    for entry in Q:Iterate() do
        local state = Q:GetState(entry.questID)
        ns.Printf("%s %s [%d] id=%d %s%s", StateMark(state), entry.title, entry.level, entry.questID, D, state .. END)
        for _, o in ipairs(entry.objectives) do
            ns.Printf("      %s %s%s", o.finished and "[x]" or "[ ]", o.text,
                o.numRequired > 0 and string.format(" (%d/%d)", o.numFulfilled, o.numRequired) or "")
        end
    end
end

function handlers.mode(rest)
    local m = rest:lower()
    if m ~= "auto" and m ~= "guide" then
        ns.Printf("mode: %s (usage: /fg mode auto|guide)", ns.char.mode or "guide")
        return
    end
    ns.Tracker:SetMode(m)
    ns.Printf("mode: %s", m)
end

function handlers.track()
    local T = ns.Tracker
    T:Rethink()
    if not T.current then ns.Print("nothing to track.") return end
    for i, c in ipairs(T.candidates) do
        ns.Printf("%s %s - %s  %s%s", i == 1 and ">" or " ", ns.Quest:TitleWithLevel(c.questID, c.title), c.what,
            c.distance and ns.Navigation:FormatDistance(c.distance) or "?", D .. "  " .. ns.DB:DescribeLocation(c.loc) .. END)
    end
end

function handlers.quest(rest)
    local DB = ns.DB
    if not DB:IsLoaded() then ns.Error("quest database not loaded") return end
    local ids = DB:Search(rest, 8)
    if #ids == 0 then ns.Printf("no quest matches '%s'", rest) return end
    if #ids > 1 then
        ns.Printf("%d matches:", #ids)
        for _, id in ipairs(ids) do
            local q = DB:GetQuest(id)
            ns.Printf("  %d  %s (lvl %s)%s", id, q.n, tostring(q.lvl), q.hidden and (D .. " [not obtainable]" .. END) or "")
        end
        return
    end
    local id = ids[1]
    local q = DB:GetQuest(id)
    ns.Printf("%s[%d] %s%s  level %s (req %s)  %s  %s", C, id, q.n, END, tostring(q.lvl), tostring(q.req),
        DB:QuestFaction(id) or "both factions", D .. (DB:ZoneName(q.zone) or ("zone " .. tostring(q.zone))) .. END)
    local ok, why = DB:IsAvailable(id)
    ns.Printf("  state: %s%s", ns.Quest:GetState(id), ok and (OK .. "  available" .. END) or (D .. "  (" .. tostring(why) .. ")" .. END))
    for _, loc in ipairs(DB:QuestStarts(id)) do ns.Printf("  starts: %s", DB:DescribeLocation(loc)) break end
    for i, o in ipairs(DB:QuestObjectives(id)) do
        local loc = DB:Nearest(o.locations)
        ns.Printf("  objective %d (%s): %s%s", i, o.kind, o.name or o.text or "?", loc and ("  @ " .. DB:DescribeLocation(loc)) or "")
    end
    for _, loc in ipairs(DB:QuestEnds(id)) do ns.Printf("  ends: %s", DB:DescribeLocation(loc)) break end
    if q.pre and #q.pre > 0 then ns.Printf("  requires: %s", DB:QuestName(q.pre[1]) or q.pre[1]) end
    if q.next then ns.Printf("  next in chain: %s", DB:QuestName(q.next) or q.next) end
    if q.text then for _, t in ipairs(q.text) do ns.Printf("  %s%s%s", D, t, END) end end
end

function handlers.avail(rest)
    local DB = ns.DB
    if not DB:IsLoaded() then ns.Error("quest database not loaded") return end
    local mapID = ns.Player:GetMapID()
    local areaID
    for area, map in pairs(ns.ZoneDB.areaToMap) do
        if map == mapID and ns.ZoneDB.names[area] then areaID = area break end
    end
    if not areaID then ns.Print("this map is not a known zone.") return end
    local ids = DB:AvailableInZone(areaID, tonumber(rest) or 15)
    ns.Printf("quests you could pick up in %s (%d):", DB:ZoneName(areaID) or areaID, #ids)
    for _, id in ipairs(ids) do
        local q = DB:GetQuest(id)
        local loc, dist = DB:Nearest(DB:QuestStarts(id))
        ns.Printf("  [%s] %s  %s%s%s", tostring(q.lvl), q.n, D,
            loc and (DB:DescribeLocation(loc) .. (dist and (" - " .. ns.Navigation:FormatDistance(dist)) or "")) or "giver unknown", END)
    end
end

function handlers.pos()
    local P = ns.Player
    local mapID, x, y = P:GetMapPosition()
    local name, mapType, parent = P:GetMapName(mapID)
    local zone, sub = P:GetZone()
    local wx, wy, inst = P:GetWorldPosition()
    ns.Printf("map %s '%s' (type %s, parent %s) @ %s", tostring(mapID), name or "?", tostring(mapType), tostring(parent),
        x and string.format("%.2f, %.2f", x, y) or "n/a")
    ns.Printf("zone '%s' / '%s'  |  world %s, %s (instance %s)  |  facing %s", zone, sub,
        wx and string.format("%.1f", wx) or "n/a", wy and string.format("%.1f", wy) or "n/a", tostring(inst),
        P:GetFacing() and string.format("%.2f rad", P:GetFacing()) or "n/a")
    if mapID and x then
        ns.Printf("guide step: %s{ \"type\": \"TRAVEL\", \"map\": %d, \"x\": %.1f, \"y\": %.1f }%s", D, mapID, x, y, END)
    end
end

function handlers.target()
    local t = ns.Player:GetTargetInfo()
    if not t then ns.Print("no target.") return end
    ns.Printf("%s  npc=%s  guid=%s", t.name, tostring(t.npcID or "-"), tostring(t.guid or "-"))
    ns.Printf("level %s, %s, %s%s%s", tostring(t.level or "?"), t.reaction, t.creatureType or "?",
        t.isDead and ", dead" or "", t.isQuestRelated and ", quest related" or "")
end

function handlers.nav()
    local N = ns.Navigation
    if not N.target then ns.Print("no destination.") return end
    local s = N:Update()
    ns.Printf("to map %d @ %.1f, %.1f (%s): %s%s", N.target.map, N.target.x, N.target.y, N.target.label or "",
        N:Describe(), s and s.method and (D .. "  [" .. s.method .. "]" .. END) or "")
end

function handlers.way(rest)
    local x, y = rest:match("^(%d*%.?%d+)[%s,]+(%d*%.?%d+)$")
    if not x then
        ns.Navigation:Clear()
        ns.Guide:UpdateNavigation()
        ns.Print("usage: /fg way <x> <y>  (cleared manual waypoint)")
        return
    end
    local mapID = ns.Player:GetMapID()
    if not mapID then ns.Error("unknown map") return end
    ns.Navigation:SetTarget({ map = mapID, x = tonumber(x), y = tonumber(y), label = "manual waypoint" })
    ns.Printf("waypoint set: map %d @ %s, %s", mapID, x, y)
end

function handlers.lock() ns.db.ui.locked = true ns.Events:Fire("FG_LOCK_CHANGED") ns.Print("window and arrow locked.") end
function handlers.unlock() ns.db.ui.locked = false ns.Events:Fire("FG_LOCK_CHANGED") ns.Print("window and arrow unlocked - drag them, then /fg lock.") end
function handlers.resetpos() ns.UI:ResetPosition() ns.Arrow:ResetPosition() ns.Print("window and arrow positions reset.") end

function handlers.auto(rest)
    local what, value = rest:match("^(%S*)%s*(%S*)$")
    if what == "" then ns.Print(ns.AutoQuest:Status()) return end
    if not ns.AutoQuest:Set(what, value) then
        ns.Print("usage: /fg auto accept on|off|guide  |  /fg auto turnin on|off  |  /fg auto announce on|off")
        return
    end
    ns.Print(ns.AutoQuest:Status())
end

function handlers.minimap(rest)
    if rest == "on" then ns.Minimap:SetShown(true)
    elseif rest == "off" then ns.Minimap:SetShown(false)
    else ns.Minimap:SetShown(not (ns.db.minimap and ns.db.minimap.shown)) end
    ns.Printf("minimap button %s", ns.db.minimap.shown and "on" or "off")
end

function handlers.arrow(rest)
    if rest == "on" then ns.Arrow:SetEnabled(true)
    elseif rest == "off" then ns.Arrow:SetEnabled(false)
    else ns.Arrow:SetEnabled(not (ns.db.ui.arrow and ns.db.ui.arrow.enabled)) end
    ns.Printf("arrow %s", ns.db.ui.arrow.enabled and "on" or "off")
end

function handlers.scale(rest)
    local v = tonumber(rest)
    if not v or v < 0.5 or v > 2 then ns.Print("usage: /fg scale 0.5-2") return end
    ns.UI:SetScale(v)
end

function handlers.rec(rest)
    local cmd, arg = rest:match("^(%S*)%s*(.*)$")
    local R = ns.Recorder
    if cmd == "on" then ns.db.recorder.enabled = true ns.Print("recorder on.")
    elseif cmd == "off" then ns.db.recorder.enabled = false ns.Print("recorder off.")
    elseif cmd == "clear" then R:Clear() ns.Print("recorder cleared.")
    elseif cmd == "dump" then R:Dump(tonumber(arg) or 10)
    else
        ns.Printf("recorder %s, %d entries, %d maps seen. Saved to WTF\\...\\SavedVariables\\ForeverGuide.lua on logout.",
            ns.db.recorder.enabled and "ON" or "OFF", R:Count(), (function() local n = 0 for _ in pairs(ns.db.recorder.maps) do n = n + 1 end return n end)())
    end
end

function handlers.scan(rest)
    local S = ns.Scanner
    local a, b = rest:match("^(%S*)%s*(%S*)$")
    if a == "stop" then S:Stop()
    elseif a == "status" then S:Status()
    elseif a == "resume" then S:Resume()
    else S:Start(tonumber(a), tonumber(b)) end
end

function handlers.harvest(rest)
    local H = ns.Harvest
    local a, b, c = rest:match("^(%S*)%s*(%S*)%s*(%S*)$")
    if a == "sweep" then H:Sweep(tonumber(b), tonumber(c))
    elseif a == "status" then H:Status()
    else H:HarvestAllMaps() end
end

function handlers.bliz(rest)
    if rest == "on" then ns.db.nav.blizzardWaypoint = true
    elseif rest == "off" then ns.db.nav.blizzardWaypoint = false ns.Call("C_Map.ClearUserWaypoint")
    else ns.db.nav.blizzardWaypoint = not ns.db.nav.blizzardWaypoint end
    ns.Printf("Blizzard waypoint arrow %s", ns.db.nav.blizzardWaypoint and "on" or "off")
    ns.Guide:UpdateNavigation()
end

-- ------------------------------------------------------------
-- Feedback: "/fg wrong" snapshots the current step + where you really are
-- ------------------------------------------------------------
function handlers.wrong(rest)
    ns.db.reports = ns.db.reports or {}
    local G, T, P = ns.Guide, ns.Tracker, ns.Player
    local map, x, y = P:GetMapPosition()
    local zone, sub = P:GetZone()
    local r = { t = ns.Now(), text = rest ~= "" and rest or nil, m = map, x = x, y = y, zone = zone, sub = sub, lvl = P:GetLevel() }
    local npc = P:GetUnitInfo("target")
    if npc and npc.npcID then r.npc = npc.npcID r.npcName = npc.name end
    if T and T:IsActive() and (not G.active or ns.char.mode == "auto") then
        local c = T.current
        if c then r.mode = "auto" r.q = c.questID r.what = c.what r.loc = { m = c.loc.map, x = c.loc.x, y = c.loc.y, id = c.loc.id, kind = c.loc.kind } end
    elseif G.active then
        local step = G:GetCurrentStep()
        r.guide = G.active.id
        r.step = G.current
        if step then
            r.type = step.type r.q = step.quest r.npcStep = step.npc
            local smap, sx, sy = ns.Navigation:ResolveStep(step)
            if smap then r.loc = { m = smap, x = sx, y = sy } end
        end
    end
    table.insert(ns.db.reports, r)
    ns.Printf("noted (%d report%s). Thanks - run tools/collect_reports.py to turn these into corrections.", #ns.db.reports, #ns.db.reports == 1 and "" or "s")
end
handlers.report = handlers.wrong

function handlers.reports(rest)
    ns.db.reports = ns.db.reports or {}
    if rest == "clear" then ns.db.reports = {} ns.Print("reports cleared.") return end
    if #ns.db.reports == 0 then ns.Print("no reports yet. /fg wrong <what is wrong> while on a bad step.") return end
    for i, r in ipairs(ns.db.reports) do
        ns.Printf("%d. %s%s%s @ %s %.1f,%.1f%s", i,
            r.guide and (r.guide .. " step " .. tostring(r.step) .. " ") or (r.mode == "auto" and "auto " or ""),
            r.q and ("quest " .. r.q .. " ") or "", r.text and ('"' .. r.text .. '"') or "",
            r.zone or "?", r.x or 0, r.y or 0, r.npcName and (" target " .. r.npcName .. " (" .. tostring(r.npc) .. ")") or "")
    end
end

function handlers.options()
    if ns.Options and ns.Options.Open then ns.Options:Open() else ns.Print("options panel not available.") end
end

function handlers.debug()
    ns.db.debug = not ns.db.debug
    ns.Printf("debug %s", ns.db.debug and "on" or "off")
end

function handlers.eval()
    ns.Quest:Refresh()
    ns.Guide:Evaluate("manual")
    ns.Print("re-evaluated.")
end

-- ------------------------------------------------------------
-- Dispatch
-- ------------------------------------------------------------
function Commands:Run(msg)
    msg = ns.Trim(msg)
    local cmd, rest = msg:match("^(%S+)%s*(.-)$")
    cmd = cmd and string.lower(cmd) or ""
    rest = rest or ""
    if cmd == "" then cmd = "status" end
    local fn = handlers[cmd]
    if not fn then
        ns.Printf("unknown command '%s'. /fg help", cmd)
        return
    end
    local ok, err = pcall(fn, rest)
    if not ok then ns.Error("command failed: " .. tostring(err)) end
end

function Commands:OnInit()
    SLASH_FOREVERGUIDE1 = "/fg"
    SLASH_FOREVERGUIDE2 = "/foreverguide"
    SlashCmdList.FOREVERGUIDE = function(msg) Commands:Run(msg) end
end
