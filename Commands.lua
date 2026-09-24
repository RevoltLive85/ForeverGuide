-- ============================================================
-- ForeverGuide / Commands.lua
-- /fg and /foreverguide
-- ============================================================

local _, ns = ...
local Commands = ns:NewModule("Commands")

local C, D, OK, END = ns.COLOR, ns.COLOR_DIM, ns.COLOR_OK, ns.COLOR_END

local HELP = {
    "/fg                 status readout (level, zone, coords, quests, current step)",
    "/fg show|hide|toggle   guide window  |  /fg hideall  hide window + arrow (alt-click the minimap button)",
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
    "/fg arrow on|off|size <0.5-2.5>   the compact chevron above your head (the everyday indicator) and its size",
    "/fg path [name|race] follow another race's leveling route (any of your faction's)",
    "/fg waypoint on|off  the in-world gold waypoint diamond (advanced)  |  /fg waypoint engine on|off  ride the client's own pin instead of the arrow  |  /fg route on|off  its dotted path",
    "/fg skull on|off  skull over the nearest quest mob  |  /fg skull others|plates on|off",
    "/fg who  how many players of your level are in this zone (/who); /fg crowd on|off|test  the crowd safeguard; /fg perf  what the addon costs per frame",
    "/fg qg <scale|opacity|width|rows|wpsize> <value>   Quest Guide look  |  /fg qg completed|distances|subtitles on|off",
    "/fg minimap on|off  the minimap button",
    "/fg auto [accept on|off|guide] [turnin on|off]   auto-accept / auto-turn-in quests (hold SHIFT at an NPC to do it by hand)",
    "/fg rec on|off|status|dump [n]|clear   data recorder (Phase 10)",
    "/fg scan new | [from] [to] | stop | resume | status   ask the server for Forever's own quests (new = exactly the ids Questie lacks; titles, levels, objectives)",
    "/fg harvest [sweep [from to] | status]   passive quest discovery: quest lines of every zone map / client cache sweep",
    "/fg bliz on|off     also use Blizzard's own waypoint arrow",
    "/fg dungeon on|off  put the guide away while you are in an instance (on by default)",
    "/fg fp              list / walk to the flight points in this zone you have not taken yet",
    "/fg remind [flight|trainer] on|off   the flight-point and trainer nudges",
    "/fg xp              levelling pace: xp/h, time to the next level, and how you compare with the route model",
    "/fg ding on|off|test|<channel>   announce a level-up (\"I leveled up to 18 in 1h 24m\") to your party, or as an emote when solo",
    "/fg resync          skip quests you out-levelled (<=20% xp) and continue from the first open step",
    "/fg edit here|npc|note <text>|radius <yd>|clear   correct the current step in place (saved; tools/apply_edits.py folds it into the guide)",
    "/fg edits [clear]   list / wipe your edits of the active guide",
    "/fg wrong [text]    open feedback dialog (or save the supplied text with your step/position)",
    "/fg reports [clear] open a copyable list of feedback (clear deletes it)",
    "/fg options         open the options panel",
    "/fg persist [save]  state of the beta workaround that keeps your guide/settings when the client forgets SavedVariables",
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

function handlers.path(rest)
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local G = ns.Guide
    if rest == "" then
        local cur = G:CurrentRoute()
        for _, r in ipairs(G:Routes()) do
            ns.Printf("  %s route - %d chapters%s%s", r.label, #r.chapters, r.mine and "  (your race)" or "", cur and cur.key == r.key and "  <- following" or "")
        end
        ns.Print("/fg path <name> follows that route (e.g. /fg path dwarf); /fg path race goes back to your race's own.")
        return
    end
    if rest:lower() == "race" or rest:lower() == "default" then
        ns.char.route = nil
        ns.Print("following your race's own route again.")
        ns.UI:Refresh()
        return
    end
    local r, pick = G:ChooseRoute(rest)
    if not r then ns.Print("no such route: " .. rest .. "  (/fg path lists them)") return end
    ns.Printf("following the %s route%s.", r.label, pick and (" - " .. (pick.name or pick.id)) or "")
end

function handlers.waypoint(rest)
    rest = (rest or ""):lower()
    local key = "waypoint"
    if rest:match("^engine") then key = "wpengine" rest = rest:gsub("^engine%s*", "") end
    local on
    if rest == "on" then on = true elseif rest == "off" then on = false end
    local ok, msg = ns.QuestGuideConfig.SetToggle(key, on)
    ns.Print(msg)
end

function handlers.route(rest)
    rest = (rest or ""):lower()
    local on
    if rest == "on" then on = true elseif rest == "off" then on = false end
    local ok, msg = ns.QuestGuideConfig.SetToggle("route", on)
    ns.Print(msg)
end

function handlers.qg(rest)
    local key, value = (rest or ""):match("^(%S+)%s*(.*)$")
    key = key and key:lower()
    local C = ns.QuestGuideConfig
    if not key then
        for k, n in pairs(C.NUMBERS) do ns.Printf("  %s = %s  (%s-%s)", k, tostring(n.get()), tostring(n.min), tostring(n.max)) end
        for k, t in pairs(C.TOGGLES) do ns.Printf("  %s %s", k, t.get() and "on" or "off") end
        return
    end
    if C.NUMBERS[key] then
        local ok, msg = C.SetNumber(key, value)
        ns.Print(msg)
    elseif C.TOGGLES[key] then
        local on
        if value:lower() == "on" then on = true elseif value:lower() == "off" then on = false end
        local ok, msg = C.SetToggle(key, on)
        ns.Print(msg)
    else
        ns.Print("/fg qg scale|opacity|width|rows|wpsize <value>  or  /fg qg completed|distances|subtitles|waypoint|route|wpanim on|off")
    end
end

--- /fg npdbg [mark] - what the client tells us about the nameplates around (mob marker research)
function handlers.npdbg(rest)
    local NP = rawget(_G, "C_NamePlate")
    if not NP then ns.Print("no C_NamePlate") return end
    local plates = ns.Safe(NP.GetNamePlates) or {}
    local px, py = ns.Player:GetWorldPosition()
    local secret = rawget(_G, "issecretvalue")
    local function show(v) if secret and secret(v) then return "SECRET" end return tostring(v) end
    ns.Printf("nameplates: %d (enemies cvar=%s, maxdist=%s)", #plates, tostring(ns.Safe(GetCVar, "nameplateShowEnemies")), tostring(ns.Safe(GetCVar, "nameplateMaxDistance")))
    for i, plate in ipairs(plates) do
        local u = plate.namePlateUnitToken or plate.UnitFrame and plate.UnitFrame.unit
        if u then
            local x, y = ns.Safe(UnitPosition, u)
            local d = "?"
            if type(x) == "number" and type(y) == "number" and px then d = string.format("%.0f", math.sqrt((x - px) ^ 2 + (y - py) ^ 2)) end
            local cx, cy = plate:GetCenter()
            ns.Printf("  %s %s tap=%s attack=%s dead=%s mark=%s pos=%s,%s dist=%s screen=%s,%s guid=%s", tostring(u), show(ns.Safe(UnitName, u)),
                show(ns.Safe(UnitIsTapDenied, u)), show(ns.Safe(UnitCanAttack, "player", u)), show(ns.Safe(UnitIsDead, u)),
                show(ns.Safe(GetRaidTargetIndex, u)), show(x), show(y), d, cx and string.format("%.0f", cx) or "?", cy and string.format("%.0f", cy) or "?",
                tostring((ns.Safe(UnitGUID, u) or ""):match("Creature%-0%-%d+%-%d+%-%d+%-(%d+)")))
            if rest == "mark" and ns.Safe(UnitCanAttack, "player", u) == true then
                local ok, err = pcall(SetRaidTarget, u, 8)
                ns.Printf("  SetRaidTarget(%s, 8): %s %s -> now %s", u, tostring(ok), tostring(err), show(ns.Safe(GetRaidTargetIndex, u)))
                rest = nil
            end
        end
    end
end

function handlers.skull(rest)
    rest = (rest or ""):lower()
    local key = "skull"
    if rest:match("^plates") then key = "skullplates" rest = rest:gsub("^plates%s*", "")
    elseif rest:match("^others") then key = "skullothers" rest = rest:gsub("^others%s*", "")
    elseif rest:match("^friends") then key = "skullfriends" rest = rest:gsub("^friends%s*", "") end
    local on
    if rest == "on" then on = true elseif rest == "off" then on = false end
    local ok, msg = ns.QuestGuideConfig.SetToggle(key, on)
    ns.Print(msg)
end

--- /fg perf - what the addon costs the client (Blizzard's own profiler, 12.x)
--- /fg who - how many same-faction players of your level are in this zone (a /who query)
function handlers.who()
    if not ns.Crowd then return end
    local busy, n, zone, capped = ns.Crowd:ZoneBusy()
    if n then ns.Printf("%s: %s%d players of your level%s (%s)", zone or "zone", capped and "50+ " or "", capped and 49 or n, busy and " - busy" or "", "asked " .. math.floor(ns.Now() - (ns.Crowd.zoneAt or 0)) .. "s ago") end
    if ns.Crowd:PollZone(true) then ns.Print("asking the server (/who) - result in a moment.") else ns.Print("/who is throttled - try again in a minute.") end
end

--- /fg dungeon on|off - step aside while you are in an instance
function handlers.dungeon(rest)
    local I = ns.Instance
    if not I then return end
    rest = (rest or ""):lower()
    if rest == "on" or rest == "off" then I:SetHide(rest == "on") end
    local inside, kind = I:Inside()
    ns.Printf("in dungeons the guide %s (%s)%s", I.Cfg().hide == false and "stays up" or "steps aside",
        "/fg dungeon on|off", inside and ("  -  you are in a " .. (kind or "instance") .. " now") or "")
end

--- /fg fp - walk to the nearest flight point you have not taken yet
function handlers.fp(rest)
    local R = ns.Reminders
    if not R then return end
    rest = (rest or ""):lower()
    if rest == "off" or rest == "stop" then R:ReleaseFlightPoint() ns.Print("flight point marker cleared.") return end
    if rest == "debug" then
        local T = rawget(_G, "C_TaxiMap")
        local map = ns.Player:GetMapID()
        local info = ns.Call("C_Map.GetMapInfo", map)
        local parent = type(info) == "table" and ns.PlainNumber(info.parentMapID)
        for _, id in ipairs({ map, parent }) do
            if id then
                local nodes = T and ns.Safe(T.GetTaxiNodesForMap, id)
                local all = T and ns.Safe(T.GetAllTaxiNodes, id)
                ns.Printf("map %s (%s): ForMap %s nodes, All %s nodes", tostring(id), tostring(ns.Player:GetMapName(id)),
                    type(nodes) == "table" and #nodes or "nil", type(all) == "table" and #all or "nil")
                local n1 = type(nodes) == "table" and nodes[1]
                if n1 then ns.Printf("   ForMap[1]: %s  undiscovered=%s faction=%s", tostring(n1.name), tostring(n1.isUndiscovered), tostring(n1.faction)) end
                local states = {}
                for _, n in ipairs(type(all) == "table" and all or {}) do
                    local st = tostring(n.state)
                    states[st] = (states[st] or 0) + 1
                end
                local parts = {}
                for st, count in pairs(states) do parts[#parts + 1] = st .. "=" .. count end
                if #parts > 0 then ns.Printf("   All states: %s", table.concat(parts, ", ")) end
                local a1 = type(all) == "table" and all[1]
                if a1 then ns.Printf("   All[1]: %s state=%s slot=%s", tostring(a1.name), tostring(a1.state), tostring(a1.slotIndex)) end
            end
        end
        local E = rawget(_G, "Enum")
        if E and E.FlightPathState then
            ns.Printf("FlightPathState: Current=%s Reachable=%s Unreachable=%s", tostring(E.FlightPathState.Current), tostring(E.FlightPathState.Reachable), tostring(E.FlightPathState.Unreachable))
        end
        return
    end
    local list = R:FlightPoints()
    if #list == 0 then
        local total, undiscovered, ours = R:FlightCounts()
        if not total then ns.Print("this client does not answer C_TaxiMap.GetTaxiNodesForMap - no flight point help here.")
        elseif total == 0 then ns.Printf("the client lists no flight points at all on %s.", ns.Player:GetMapName() or "this map")
        else ns.Printf("%d flight point%s on this map, %d still undiscovered (%d of your faction).", total, total == 1 and "" or "s", undiscovered, ours) end
        return
    end
    for i, fp in ipairs(list) do
        ns.Printf("  %s%s", fp.name, fp.distance and ("  -  " .. ns.Navigation:FormatDistance(fp.distance)) or "")
        if i >= 4 then break end
    end
    local go = R:GoToFlightPoint()
    if go then ns.Printf("pointing at %s; /fg fp off gives the guide its marker back.", go.name) end
end

--- /fg remind [flight|trainer] on|off - the two nudges
function handlers.remind(rest)
    local R = ns.Reminders
    if not R then return end
    rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local c = R.Cfg()
    local what, state = rest:match("^(%a*)%s*(%a*)$")
    if what == "flight" or what == "trainer" then
        if state == "on" then c[what] = true elseif state == "off" then c[what] = false end
    elseif what == "on" or what == "off" then
        c.flight, c.trainer = what == "on", what == "on"
    end
    ns.Printf("reminders: flight points %s, trainer %s  (/fg remind flight|trainer on|off)",
        c.flight == false and "off" or "on", c.trainer == false and "off" or "on")
end

--- /fg xp - how fast you are levelling and what the route model says about the rest
function handlers.xp()
    if not ns.Pace then return end
    for _, line in ipairs(ns.Pace:Lines()) do ns.Print(line) end
end

--- /fg ding - announce a level-up to the party (or as an emote when solo)
function handlers.ding(rest)
    local D = ns.Ding
    if not D then return end
    rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local c = D.Cfg()
    if rest == "on" or rest == "off" then
        c.enabled = rest == "on"
    elseif rest == "test" then
        local sec = D:Elapsed()
        local ok, msg, channel = D:Announce(ns.Player:GetLevel(), sec)
        if ok then ns.Printf("sent to %s: %s", string.lower(channel), msg) end
        return
    elseif rest == "time" then
        D.pendingPrint = true
        if not D:Request() then ns.Print("this client has no RequestTimePlayed.") end
        return
    elseif rest ~= "" then
        local key = rest:gsub("^channel%s*", "")
        if not ({ auto = 1, party = 1, raid = 1, guild = 1, emote = 1, say = 1, yell = 1 })[key] then
            ns.Print("/fg ding on|off|test|time, or a channel: auto, party, raid, guild, emote, say, yell.")
            return
        end
        c.channel = key
    end
    local sec = D:Elapsed()
    ns.Printf("level-up announcement %s, channel %s (now: %s)%s", c.enabled == false and "off" or "on",
        c.channel == "auto" and ("auto - " .. string.lower(D:Channel())) or c.channel,
        ns.Ding.Message(ns.Player:GetLevel() + 1, sec),
        sec and "" or "  (time played not known yet - /fg ding time)")
end

--- /fg crowd test - preview the crowd / group-up banner; /fg crowd on|off - the safeguard itself
function handlers.crowd(rest)
    if not ns.Crowd then return end
    rest = (rest or ""):lower()
    if rest == "test" or rest == "preview" then ns.Crowd:Preview() ns.Print("crowd banner preview for 10 s.") return end
    ns.db.crowd = ns.db.crowd or {}
    if rest == "on" then ns.db.crowd.enabled = true elseif rest == "off" then ns.db.crowd.enabled = false end
    ns.Printf("crowd safeguard %s (/fg crowd on|off|test).", ns.db.crowd.enabled == false and "off" or "on")
    ns.Crowd:Update()
end

function handlers.perf()
    local P = rawget(_G, "C_AddOnProfiler")
    local E = rawget(_G, "Enum") and Enum.AddOnProfilerMetric
    local okm, mem = pcall(function() UpdateAddOnMemoryUsage() return GetAddOnMemoryUsage("ForeverGuide") end)
    ns.Printf("ForeverGuide memory: %s KB, framerate %s fps", okm and string.format("%.0f", mem or 0) or "?", string.format("%.0f", ns.PlainNumber(ns.Safe(rawget(_G, "GetFramerate"))) or 0))
    if not P or not E then ns.Print("C_AddOnProfiler not available on this client.") return end
    if ns.Plain(ns.Safe(P.IsEnabled)) == false then ns.Print("the addon profiler is disabled (cvar addonProfilerEnabled 0)") end
    local function m(name, metric) return ns.PlainNumber(ns.Safe(P.GetAddOnMetric, name, metric)) or 0 end
    ns.Printf("  per frame: recent avg %.2f ms, session avg %.2f ms, peak %.1f ms, frames over 1 ms: %d, over 5 ms: %d",
        m("ForeverGuide", E.RecentAverageTime), m("ForeverGuide", E.SessionAverageTime), m("ForeverGuide", E.PeakTime),
        m("ForeverGuide", E.CountTimeOver1Ms), m("ForeverGuide", E.CountTimeOver5Ms))
    local all = ns.PlainNumber(ns.Safe(P.GetOverallMetric, E.RecentAverageTime)) or 0
    ns.Printf("  all addons together: %.2f ms per frame recently", all)
    local top = ns.Safe(P.GetTopKAddOnsForMetric, E.RecentAverageTime, 6)
    if type(top) == "table" then
        for i, r in ipairs(top) do
            ns.Printf("  %d. %s  %.2f ms", i, tostring(r.addOnName), ns.PlainNumber(r.metricValue) or 0)
        end
    end
end

function handlers.wpdbg()
    if ns.Waypoint and ns.Waypoint.Debug then ns.Waypoint:Debug() end
end

function handlers.tracker(rest)
    rest = (rest or ""):lower()
    if rest == "on" or rest == "off" then
        local ok, msg = ns.QuestGuideConfig.SetToggle("tracker", rest == "on")
        ns.Print(msg)
        return
    end
    for _, name in ipairs({ "ObjectiveTrackerFrame", "QuestObjectiveTracker", "QuestWatchFrame", "WatchFrame", "ObjectiveTrackerBlocksFrame", "ScenarioObjectiveTracker" }) do
        local f = rawget(_G, name)
        if f then ns.Printf("  %s: shown=%s alpha=%s parent=%s", name, tostring(f.IsShown and f:IsShown()), tostring(f.GetAlpha and f:GetAlpha()), tostring(f.GetParent and f:GetParent() and f:GetParent():GetName())) end
    end
    ns.Printf("hide Blizzard tracker while the Quest Guide shows: %s   (/fg tracker on|off)", ns.db.ui.hideTracker ~= false and "on" or "off")
end

function handlers.hideall(rest)
    rest = (rest or ""):lower()
    local on
    if rest == "on" then on = true elseif rest == "off" then on = false else on = not ns.UI:AllHidden() end
    ns.UI:SetAllHidden(on)
    ns.Printf("everything %s%s", on and "hidden" or "back",
        on and " - the guide keeps running; /fg hideall or alt-click the minimap button to bring it back." or ".")
end

function handlers.guides()
    local G = ns.Guide
    if #G.list == 0 then ns.Print("no guides loaded.") return end
    ns.Print("Guides:")
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        local active = (G.active == g) and (OK .. " (active)" .. END) or ""
        local usable = G:Applicable(g) and "" or (D .. " [not for this character]" .. END)
        ns.Printf("  %s%s%s  %s  %s-%s  %d steps%s%s", C, id, END, g.name or "", tostring(g.minLevel or "?"),
            tostring(g.maxLevel or "?"), ns.Guide.StepCount(g), active, usable)
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

function handlers.lock() ns.db.ui.locked = true ns.Events:Fire("FG_LOCK_CHANGED", true) ns.Print("window and arrow locked.") end
function handlers.unlock() ns.db.ui.locked = false ns.Events:Fire("FG_LOCK_CHANGED", false) ns.Print("window and arrow unlocked - drag them, then /fg lock.") end
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
    rest = ns.Trim(rest or "")
    local sizeArg = rest:match("^[Ss]ize%s+(.+)$") or rest:match("^[Ss]cale%s+(.+)$")
    if sizeArg then
        local ok, msg = ns.QuestGuideConfig.SetNumber("arrowsize", sizeArg)
        ns.Print(msg)
        return
    end
    -- anything that isn't blank/on/off/a recognized size is a mistyped command, not a toggle -
    -- silently flipping the arrow off on a typo is exactly the kind of surprise a player can't
    -- explain (Ilya, 2026-09-24: a live "/fg arrow size 2" once printed "arrow off" instead of
    -- resizing; this guard turns any repeat of that into a visible error instead of a silent
    -- wrong toggle).
    if rest == "" then
        ns.Arrow:SetEnabled(not (ns.db.ui.arrow and ns.db.ui.arrow.enabled))
    elseif rest == "on" then
        ns.Arrow:SetEnabled(true)
    elseif rest == "off" then
        ns.Arrow:SetEnabled(false)
    else
        ns.Printf("arrow: didn't understand '%s'. /fg arrow on|off|size <0.5-2.5>", rest)
        return
    end
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
    elseif a == "new" then S:Start("new")
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
    local on
    if rest == "on" then on = true elseif rest == "off" then on = false else on = not ns.db.nav.blizzardWaypoint end
    ns.Navigation:SetBlizzardWaypointEnabled(on)
    ns.Printf("Blizzard waypoint arrow %s", on and "on" or "off")
end

-- ------------------------------------------------------------
-- Feedback: "/fg wrong" snapshots the current step + where you really are
-- ------------------------------------------------------------
function handlers.wrong(rest)
    if rest == "" then ns.Reports:Prompt() return end
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
    while #ns.db.reports > 300 do table.remove(ns.db.reports, 1) end
    ns.Printf("noted (%d report%s). Thanks - run tools/collect_reports.py to turn these into corrections.", #ns.db.reports, #ns.db.reports == 1 and "" or "s")
end
handlers.report = handlers.wrong

function handlers.reports(rest)
    ns.db.reports = ns.db.reports or {}
    if rest == "clear" then ns.db.reports = {} ns.Print("reports cleared.") return end
    ns.Reports:ShowList()
end

function handlers.resync()
    if not ns.Guide.active then ns.Print("no guide active.") return end
    local before = ns.Guide.current
    local n = ns.Guide:Resync()
    local step = ns.Guide:GetCurrentStep()
    local _, total = ns.Guide:GetStepCount()      -- (current, total): only the total is wanted here
    local where = step and string.format("step %d/%d: %s", step.index, total or 0, ns.Guide:GetStepText(step)) or "the end of the guide"
    if n > 0 then
        ns.Printf("resynced: %d out-levelled quest%s skipped - now at %s", n, n == 1 and "" or "s", where)
    elseif before == ns.Guide.current then
        ns.Printf("resynced: nothing to skip, still at %s", where)
    else
        ns.Printf("resynced: now at %s", where)
    end
end

function handlers.edit(rest)
    local what, arg = rest:match("^(%S*)%s*(.*)$")
    local E = ns.Editor
    local ok, msg
    if what == "here" then ok, msg = E:Here()
    elseif what == "npc" then ok, msg = E:NPC()
    elseif what == "note" then ok, msg = E:Note(arg)
    elseif what == "radius" then ok, msg = E:Radius(arg)
    elseif what == "clear" then ok, msg = E:Clear()
    else ns.Print("/fg edit here | npc | note <text> | radius <yards> | clear") return end
    if ok then ns.Print(msg) else ns.Warn(msg) end
end

function handlers.edits(rest)
    if rest == "clear" then
        local ok, msg = ns.Editor:ClearGuide()
        if ok then ns.Print(msg) else ns.Warn(msg) end
    else
        ns.Editor:List()
    end
end

function handlers.persist(rest)
    if rest == "save" then ns.Persist:Save() ns.Print("cvar mirror saved.") return end
    ns.Print(ns.Persist:Status())
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
