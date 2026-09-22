-- ============================================================
-- ForeverGuide / Reminders.lua
-- Two things a levelling character forgets:
--
--   * the flight point right next to the road. C_TaxiMap.GetTaxiNodesForMap
--     knows every node on the zone's map and whether it is still undiscovered,
--     so when one of your faction's is close the addon says so once - and
--     `/fg fp` walks you to the nearest one.
--   * the trainer. Every couple of levels there are new ranks waiting; the
--     module remembers the last trainer you used (and at what level) and
--     names it when you ding.
--
-- `/fg remind` turns either of them off.
-- ============================================================

local _, ns = ...
local Rem = ns:NewModule("Reminders")

local NEAR_YD = 400          -- "you are basically there" for a flight point
local ZONE_YD = 4000         -- worth mentioning when you arrive in the zone
local RECHECK = 20           -- seconds between position checks while a node is undiscovered
local TRAIN_EVERY = 2        -- levels between trainer nudges

local function cfg()
    ns.db.reminders = ns.db.reminders or {}
    local c = ns.db.reminders
    if c.flight == nil then c.flight = true end
    if c.trainer == nil then c.trainer = true end
    return c
end
Rem.Cfg = cfg

-- ---- flight points --------------------------------------------------------------------------

local function myFlightFaction()
    local E = rawget(_G, "Enum")
    local F = E and E.FlightPathFaction
    if not F then return nil end
    local faction = ns.Player:GetFaction()
    if faction == "Alliance" then return F.Alliance end
    if faction == "Horde" then return F.Horde end
    return nil
end

--- The continent map the character is on (taxi nodes are listed per continent).
local function continentMap()
    local mapID, tries = ns.Player:GetMapID(), 0
    while mapID and tries < 6 do
        local info = ns.Call("C_Map.GetMapInfo", mapID)
        if type(info) ~= "table" then return mapID end
        if ns.PlainNumber(info.mapType) == 2 then return mapID end       -- 2 = continent
        local parent = ns.PlainNumber(info.parentMapID)
        if not parent or parent == 0 then return mapID end
        mapID = parent
        tries = tries + 1
    end
    return ns.Player:GetMapID()
end

--- Flight points this character has already taken. The Forever client does not fill in
--- `isUndiscovered` (Thunder Bluff comes back "discovered" for an Alliance dwarf), so the
--- known ones are learned instead: every node the flight map offers while you stand at a
--- flight master is one you have, and "New flight path discovered!" adds the one you just took.
local function known()
    ns.char.flightpoints = ns.char.flightpoints or {}
    return ns.char.flightpoints
end
Rem.Known = known

--- Read the taxi map that is open right now (the only moment the client tells the truth).
function Rem:LearnFromTaxiMap()
    local T = rawget(_G, "C_TaxiMap")
    if not T or type(T.GetAllTaxiNodes) ~= "function" then return 0 end
    local nodes = ns.Safe(T.GetAllTaxiNodes, continentMap())
    if type(nodes) ~= "table" then return 0 end
    local E = rawget(_G, "Enum")
    local unreachable = E and E.FlightPathState and E.FlightPathState.Unreachable
    local learned = 0
    for _, node in ipairs(nodes) do
        local name = ns.PlainString(node.name)
        local state = ns.PlainNumber(node.state)
        if name and (unreachable == nil or state ~= unreachable) and not known()[name] then
            known()[name] = true
            learned = learned + 1
        end
    end
    if learned > 0 then self.said = {} end     -- the picture changed: let the rest be mentioned again
    return learned
end

--- Every flight point of your faction on this continent, with the ones you already have
--- filtered out: { { name, x, y, map, distance, nodeID }, ... } nearest first.
function Rem:FlightPoints(mapID)
    local T = rawget(_G, "C_TaxiMap")
    if not T or type(T.GetTaxiNodesForMap) ~= "function" then return {} end
    mapID = mapID or continentMap()
    if not mapID then return {} end
    local nodes = ns.Safe(T.GetTaxiNodesForMap, mapID)
    if type(nodes) ~= "table" then return {} end
    local E = rawget(_G, "Enum")
    local neutral = E and E.FlightPathFaction and E.FlightPathFaction.Neutral
    local mine = myFlightFaction()
    local px, py, pInst = ns.Player:GetWorldPosition()
    local have = known()
    local out = {}
    for _, node in ipairs(nodes) do
        local name = ns.PlainString(node.name)
        -- the client's own isUndiscovered is unreliable here, so only our own list decides;
        -- "zzOLD..." nodes are the client's retired entries and are not real flight masters
        if type(node) == "table" and name and not have[name] and not name:match("^zz") then
            local faction = ns.PlainNumber(node.faction)
            if not mine or faction == nil or faction == mine or faction == neutral then
                local pos = node.position
                local x, y
                if type(pos) == "table" then
                    if type(pos.GetXY) == "function" then
                        local ok, a, b = pcall(pos.GetXY, pos)
                        if ok then x, y = ns.PlainNumber(a), ns.PlainNumber(b) end
                    end
                    x = x or ns.PlainNumber(pos.x)
                    y = y or ns.PlainNumber(pos.y)
                end
                if x and y then
                    local entry = { name = name, map = mapID, x = x * 100, y = y * 100, nodeID = ns.PlainNumber(node.nodeID) }
                    local inst, wx, wy = ns.Navigation:MapToWorld(entry.map, entry.x, entry.y)
                    if inst and px and inst == pInst and wx then
                        entry.distance = math.sqrt((wx - px) ^ 2 + (wy - py) ^ 2)
                        out[#out + 1] = entry            -- same continent only: the rest is noise
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return (a.distance or 1e9) < (b.distance or 1e9) end)
    return out
end

--- What the client says about the continent's nodes: total, ours, and how many we know
--- (/fg fp when the list comes back empty).
function Rem:FlightCounts()
    local T = rawget(_G, "C_TaxiMap")
    if not T or type(T.GetTaxiNodesForMap) ~= "function" then return nil end
    local nodes = ns.Safe(T.GetTaxiNodesForMap, continentMap())
    if type(nodes) ~= "table" then return nil end
    local E = rawget(_G, "Enum")
    local neutral = E and E.FlightPathFaction and E.FlightPathFaction.Neutral
    local mine = myFlightFaction()
    local have = known()
    local total, ours, taken = 0, 0, 0
    for _, node in ipairs(nodes) do
        total = total + 1
        local faction = ns.PlainNumber(node.faction)
        local name = ns.PlainString(node.name)
        if not mine or faction == nil or faction == mine or faction == neutral then
            ours = ours + 1
            if name and have[name] then taken = taken + 1 end
        end
    end
    return total, ours, taken
end

--- Point the arrow at the nearest undiscovered flight point (used by /fg fp).
function Rem:GoToFlightPoint()
    local fp = self:FlightPoints()[1]
    if not fp then return nil end
    ns.Navigation.override = "flightpoint"
    ns.Navigation:SetTarget({ map = fp.map, x = fp.x, y = fp.y, radius = 20,
                              label = "Flight point - " .. fp.name, owner = "fp" })
    return fp
end

function Rem:ReleaseFlightPoint()
    if ns.Navigation.override == "flightpoint" then
        ns.Navigation.override = nil
        if ns.Navigation.target and ns.Navigation.target.owner == "fp" then ns.Navigation:Clear() end
        if ns.Tracker and ns.Tracker:IsActive() then ns.Tracker:Rethink() elseif ns.Guide then ns.Guide:UpdateNavigation() end
    end
end

--- Look around: one line when a flight point you have not taken is close.
function Rem:CheckFlight(reason)
    if cfg().flight == false then return nil end
    local list = self:FlightPoints()
    self.pending = #list
    if #list == 0 then return nil end
    self.said = self.said or {}
    local zoneName = ns.Player:GetMapName() or "this zone"
    -- until a flight master has told us which ones you already have, the list would be guesswork:
    -- say nothing about the zone and keep to the "you are standing next to one" nudge
    local learned = next(known()) ~= nil
    -- arriving in a zone: name them once, so you can plan the detour
    if learned and reason == "zone" and not self.said["zone:" .. tostring(ns.Player:GetMapID())] then
        self.said["zone:" .. tostring(ns.Player:GetMapID())] = true
        local names = {}
        for _, fp in ipairs(list) do
            if fp.distance and fp.distance <= ZONE_YD and #names < 3 then
                names[#names + 1] = fp.name .. " (" .. ns.Navigation:FormatDistance(fp.distance) .. ")"
            end
        end
        if #names > 0 then
            ns.Printf("flight point%s you have not taken near %s: %s  (/fg fp walks you to the nearest one)",
                #names == 1 and "" or "s", zoneName, table.concat(names, ", "))
        end
    end
    local fp = list[1]
    if fp.distance and fp.distance <= NEAR_YD then
        local key = "fp:" .. tostring(fp.nodeID or fp.name)
        if not self.said[key] then
            self.said[key] = true
            ns.Printf("%s%s%s is %s away%s - take the flight path while you are here.",
                ns.COLOR_OK, fp.name, ns.COLOR_END, ns.Navigation:FormatDistance(fp.distance),
                learned and " and not one of yours" or "")
            return fp
        end
    end
    return nil
end

-- ---- the trainer ----------------------------------------------------------------------------

local function trainers()
    ns.db.trainers = ns.db.trainers or {}
    return ns.db.trainers
end

--- Remember where we trained (per class), and at what level.
function Rem:NoteTrainer()
    local npc = ns.Player:GetInteractionNPC()
    local _, classFile = ns.Player:GetClass()
    local map, x, y = ns.Player:GetMapPosition()
    ns.char.lastTrained = ns.Player:GetLevel()
    if not classFile or not npc or not npc.name then return end
    trainers()[classFile] = { name = npc.name, npcID = npc.npcID, map = map, x = x, y = y,
                              zone = ns.Player:GetMapName(map), level = ns.Player:GetLevel() }
end

--- The trainer we have used before, with its distance when it is on this map.
function Rem:KnownTrainer()
    local _, classFile = ns.Player:GetClass()
    local t = classFile and trainers()[classFile]
    if not t or not t.map then return nil end
    local px, py, pInst = ns.Player:GetWorldPosition()
    local inst, wx, wy = ns.Navigation:MapToWorld(t.map, t.x or 50, t.y or 50)
    local distance
    if inst and px and inst == pInst and wx then distance = math.sqrt((wx - px) ^ 2 + (wy - py) ^ 2) end
    return t, distance
end

--- Are there levels to train for? (nil = nothing to say)
function Rem:TrainerDue(level)
    if cfg().trainer == false then return nil end
    level = level or ns.Player:GetLevel()
    local last = ns.char.lastTrained or 0
    if level - last < TRAIN_EVERY then return nil end
    return level - last, last
end

function Rem:TrainerNudge(level)
    local since, last = self:TrainerDue(level)
    if not since then return nil end
    level = level or ns.Player:GetLevel()
    local line
    if last > 0 then
        line = string.format("level %d - new ranks at your class trainer (you last trained at %d).", level, last)
    else
        line = string.format("level %d - worth a visit to your class trainer.", level)
    end
    local t, distance = self:KnownTrainer()
    if t then
        line = line .. string.format(" Last one you used: %s%s%s.", t.name,
            t.zone and (" in " .. t.zone) or "",
            distance and (" - " .. ns.Navigation:FormatDistance(distance) .. " away") or "")
    end
    ns.Print(line)
    self.lastNudge = level
    return line
end

-- ---- events ---------------------------------------------------------------------------------

function Rem:OnInit()
    ns.Events:Register("TRAINER_SHOW", function() Rem:NoteTrainer() end)
    ns.Events:Register("FG_LEVEL_CHANGED", function(_, level)
        ns.Events:Debounce("remind:train", 2, function() Rem:TrainerNudge(level) end)
    end)
    ns.Events:Register("FG_ZONE_CHANGED", function()
        ns.Events:Debounce("remind:zone", 3, function() Rem:CheckFlight("zone") end)
    end)
    ns.Events:RegisterMany({ "TAXIMAP_OPENED", "TAXI_NODE_STATUS_CHANGED" }, function()
        local learned = Rem:LearnFromTaxiMap()
        if learned > 0 then ns.Printf("noted %d flight point%s you already have.", learned, learned == 1 and "" or "s") end
    end)
    ns.Events:Register("TAXIMAP_CLOSED", function()
        Rem.said = {}
        ns.Events:Debounce("remind:taxi", 2, function() Rem:CheckFlight("taxi") end)
    end)
    -- "New flight path discovered!": whatever we are standing next to is ours now
    ns.Events:Register("UI_INFO_MESSAGE", function(_, _, message)
        local text = ns.PlainString(message)
        local want = rawget(_G, "ERR_NEWTAXIPATH")
        if not text or (want and text ~= want) then return end
        local near = Rem:FlightPoints()[1]
        if near and (near.distance or 1e9) < 300 then known()[near.name] = true end
        Rem.said = {}
    end)
    ns.Events:Register("FG_NAV_ARRIVED", function(_, target)
        if target and target.owner == "fp" then Rem:ReleaseFlightPoint() end
    end)
end

function Rem:OnEnterWorld()
    self.said = self.said or {}
    ns.Events:After(8, function() Rem:CheckFlight("zone") end)
    if not self.ticker then
        self.ticker = true
        local function beat()
            if cfg().flight ~= false and (Rem.pending or 0) > 0 then
                local ok, err = pcall(Rem.CheckFlight, Rem, "tick")
                if not ok then ns.ReportOnce("reminders:flight", err) end
            end
            ns.Events:After(RECHECK, beat)
        end
        ns.Events:After(RECHECK, beat)
    end
end
