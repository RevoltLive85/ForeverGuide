-- ============================================================
-- ForeverGuide / tools/generate_guides.lua
-- Route generator: builds one guide per zone and faction from the bundled
-- quest database (Data/*.lua) and writes them as guides-src/GEN_*.json,
-- ready for tools/compile_guides.py.
--
--   lua5.1 tools/generate_guides.lua            # all zones, both factions
--   lua5.1 tools/generate_guides.lua 12 Alliance   # one zone (areaID) / faction
--
-- How a route is made (per zone + faction):
--   1. candidate quests: zone (or a sub-zone of it), faction can take it,
--      not hidden / repeatable / daily / profession / item-started /
--      breadcrumb, prerequisites inside the set, giver inside the zone,
--      objectives (if any) reachable inside the zone
--   2. a simulated walk: start at the lowest-level quest giver, then repeat
--        accept every available quest at the current hub (lowest level first)
--        turn in every finished quest at the current hub
--        plan a tour (nearest-neighbour + 2-opt) through everything tied to
--        the current hub: objectives of quests that turn in here, turn-ins
--        and givers here, objectives close by. Nothing is left behind when
--        the route moves on.
--        when the hub is exhausted, move to the hub with the most waiting
--        (turn-ins, givers, objectives) minus the walk, taking along any
--        giver / objective that lies on the way
--      Quest xp is the real reward (Questie's xp table) with the Classic
--      reduction for out-levelled quests, so the level model is realistic;
--      quests about to turn grey are ordered first (URGENCY), quests that
--      would give <= 20% xp are skipped unless a chain needs them.
--      Quest log is capped at 20.
--   3. steps are emitted as the walk happens: ACCEPT / KILL / COLLECT /
--      COMPLETE / TURNIN, with explicit coordinates and names.
-- The result is a decent first route, not a speedrun route; the engine's
-- recovery logic covers whatever the player does differently.
-- ============================================================

local root = arg and arg[0] and arg[0]:match("^(.*)tools[/\\]generate_guides%.lua$") or "./"
if root == "" then root = "./" end
local onlyZone, onlyFaction = tonumber(arg[1]), arg[2]

-- ---- load the database the way the client does ---------------------------
local ns = {}
local function loadData(file)
    local chunk = assert(loadfile(root .. "Data/" .. file))
    chunk("ForeverGuide", ns)
end
loadData("ZoneDB.lua") loadData("QuestDB.lua") loadData("NpcDB.lua") loadData("ObjectDB.lua") loadData("ItemDB.lua")
local Q, N, O, I, Z = ns.QuestDB, ns.NpcDB, ns.ObjectDB, ns.ItemDB, ns.ZoneDB
-- the Forever client's own quest id list (optional): vanilla quests it lacks are not routed
do
    local f = io.open(root .. "Data/ForeverQuestIDs.lua", "r")
    if f then
        f:close()
        loadData("ForeverQuestIDs.lua")
        local gone = 0
        for id, q in pairs(Q) do
            if not ns.ForeverQuestIDs[id] then q.removed = true gone = gone + 1 end
        end
        io.stderr:write(string.format("Forever quest id list: %d vanilla quests are not in the client and are skipped\n", gone))
    end
end

-- ---- zones -----------------------------------------------------------------
-- areaID, min, max, races (starting zones), next zone per faction
local ZONES = {
    -- Alliance starting zones
    { id = 12,   min = 1,  max = 10, races = { "Human" },          nextA = 40 },   -- Elwynn -> Westfall
    { id = 1,    min = 1,  max = 10, races = { "Dwarf", "Gnome" }, nextA = 38 },   -- Dun Morogh -> Loch Modan
    { id = 141,  min = 1,  max = 10, races = { "NightElf" },       nextA = 148 },  -- Teldrassil -> Darkshore
    -- Horde starting zones
    { id = 14,   min = 1,  max = 10, races = { "Orc", "Troll" },   nextH = 17 },   -- Durotar -> Barrens
    { id = 215,  min = 1,  max = 10, races = { "Tauren" },         nextH = 17 },   -- Mulgore -> Barrens
    { id = 85,   min = 1,  max = 10, races = { "Scourge" },        nextH = 130 },  -- Tirisfal -> Silverpine
    -- 10-20
    { id = 40,   min = 10, max = 20, nextA = 44 },                 -- Westfall -> Redridge
    { id = 38,   min = 10, max = 20, nextA = 44 },                 -- Loch Modan -> Redridge
    { id = 148,  min = 10, max = 20, nextA = 331 },                -- Darkshore -> Ashenvale
    { id = 17,   min = 10, max = 25, nextH = 406 },                -- Barrens -> Stonetalon
    { id = 130,  min = 10, max = 20, nextH = 267 },                -- Silverpine -> Hillsbrad
    -- 15-30
    { id = 44,   min = 15, max = 25, nextA = 10 },                 -- Redridge -> Duskwood
    { id = 10,   min = 18, max = 30, nextA = 11 },                 -- Duskwood -> Wetlands
    { id = 11,   min = 20, max = 30, nextA = 267 },                -- Wetlands -> Hillsbrad
    { id = 331,  min = 18, max = 30, nextA = 406, nextH = 400 },   -- Ashenvale
    { id = 406,  min = 15, max = 27, nextA = 45,  nextH = 331 },   -- Stonetalon
    { id = 267,  min = 20, max = 30, nextA = 45,  nextH = 45 },    -- Hillsbrad
    { id = 400,  min = 25, max = 35, nextA = 405, nextH = 405 },   -- Thousand Needles
    -- 30-45
    { id = 45,   min = 30, max = 40, nextA = 33,  nextH = 33 },    -- Arathi
    { id = 405,  min = 30, max = 40, nextA = 15,  nextH = 15 },    -- Desolace
    { id = 33,   min = 30, max = 45, nextA = 15,  nextH = 15 },    -- Stranglethorn
    { id = 15,   min = 35, max = 45, nextA = 3,   nextH = 3 },     -- Dustwallow
    { id = 3,    min = 35, max = 45, nextA = 8,   nextH = 8 },     -- Badlands
    { id = 8,    min = 35, max = 45, nextA = 47,  nextH = 47 },    -- Swamp of Sorrows
    -- 40-50
    { id = 47,   min = 40, max = 50, nextA = 440, nextH = 440 },   -- Hinterlands
    { id = 440,  min = 40, max = 50, nextA = 357, nextH = 357 },   -- Tanaris
    { id = 357,  min = 40, max = 50, nextA = 51,  nextH = 51 },    -- Feralas
    { id = 51,   min = 43, max = 50, nextA = 4,   nextH = 4 },     -- Searing Gorge
    -- 45-55
    { id = 4,    min = 45, max = 55, nextA = 490, nextH = 490 },   -- Blasted Lands
    { id = 490,  min = 48, max = 55, nextA = 16,  nextH = 16 },    -- Un'Goro
    { id = 16,   min = 45, max = 55, nextA = 361, nextH = 361 },   -- Azshara
    { id = 361,  min = 48, max = 55, nextA = 46,  nextH = 46 },    -- Felwood
    -- 50-60
    { id = 46,   min = 50, max = 58, nextA = 28,  nextH = 28 },    -- Burning Steppes
    { id = 28,   min = 51, max = 58, nextA = 139, nextH = 139 },   -- Western Plaguelands
    { id = 139,  min = 53, max = 60, nextA = 618, nextH = 618 },   -- Eastern Plaguelands
    { id = 618,  min = 53, max = 60, nextA = 1377, nextH = 1377 }, -- Winterspring
    { id = 1377, min = 55, max = 60 },                             -- Silithus
}

local RACE_ALLIANCE, RACE_HORDE = 77, 178
local CLASS_NAMES = { [1] = "WARRIOR", [2] = "PALADIN", [4] = "HUNTER", [8] = "ROGUE", [16] = "PRIEST", [64] = "SHAMAN",
                      [128] = "MAGE", [256] = "WARLOCK", [1024] = "DRUID" }
local HUB = 4.0            -- map units: things this close count as "here"
local HUB_RADIUS = tonumber(os.getenv("FG_HUBR") or "8")     -- givers / turn-ins this close together form one hub (a town, a camp)
local OBJ_RADIUS = tonumber(os.getenv("FG_OBJR") or "22")    -- objectives this close to the current hub are done before leaving it
local FAR_OBJ = tonumber(os.getenv("FG_FAR") or "25")  -- objectives farther than this from the hub wait until the route passes by
local W_TURNIN = tonumber(os.getenv("FG_W_TURNIN") or "10")   -- hub score: a finished quest to hand in there
local W_OBJ = tonumber(os.getenv("FG_W_OBJ") or "4")          -- an open objective there
local W_ACCEPT = tonumber(os.getenv("FG_W_ACCEPT") or "6")    -- a quest giver waiting there
local NEAR_TURNIN = tonumber(os.getenv("FG_NEAR_TURNIN") or "15") -- turn-ins this close are done before moving on
local NEAR_PULL = tonumber(os.getenv("FG_NEAR_PULL") or "30")
local DETOUR = tonumber(os.getenv("FG_DETOUR") or "8")         -- extra map units we accept to take something along on the way to the next hub
local CROSS_ZONE = 300     -- cost of leaving the zone
local LOG_CAP = 20

local function band(a, b)
    local r, m = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + m end
        a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
    end
    return r
end

local function parentZone(area)
    local guard = 0
    while Z.parent[area] and guard < 8 do area = Z.parent[area] guard = guard + 1 end
    return area
end

local function slug(name)
    return name:upper():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

-- ---- locations ---------------------------------------------------------------
local function spawnLocs(rec, out, kind, id)
    if not rec or not rec.sp then return out end
    for area, pts in pairs(rec.sp) do
        local zone = parentZone(area)
        for _, p in ipairs(pts) do
            out[#out + 1] = { zone = zone, area = area, map = Z.areaToMap[area], x = p[1], y = p[2], name = rec.n, kind = kind, id = id }
        end
    end
    return out
end

local function questStarts(q)
    local out = {}
    for _, id in ipairs(q.snpc or {}) do spawnLocs(N[id], out, "npc", id) end
    for _, id in ipairs(q.sobj or {}) do spawnLocs(O[id], out, "object", id) end
    return out
end

local function questEnds(q)
    local out = {}
    for _, id in ipairs(q.enpc or {}) do spawnLocs(N[id], out, "npc", id) end
    for _, id in ipairs(q.eobj or {}) do spawnLocs(O[id], out, "object", id) end
    return out
end

local function itemLocs(itemID, out)
    local it = I[itemID]
    if not it then return out end
    for _, id in ipairs(it.npc or {}) do spawnLocs(N[id], out, "npc", id) end
    for _, id in ipairs(it.obj or {}) do spawnLocs(O[id], out, "object", id) end
    return out
end

local function questObjectives(q)
    local out = {}
    for _, e in ipairs(q.kill or {}) do
        out[#out + 1] = { kind = "KILL", name = N[e[1]] and N[e[1]].n or ("npc " .. e[1]), text = e[2], locs = spawnLocs(N[e[1]], {}, "npc", e[1]),
            elite = N[e[1]] and (N[e[1]].rank == 1 or N[e[1]].rank == 2 or N[e[1]].rank == 3) or false }
    end
    for _, e in ipairs(q.obj or {}) do
        out[#out + 1] = { kind = "COMPLETE", name = O[e[1]] and O[e[1]].n or ("object " .. e[1]), text = e[2], locs = spawnLocs(O[e[1]], {}, "object", e[1]) }
    end
    for _, e in ipairs(q.item or {}) do
        local it = I[e[1]]
        local itemName = it and it.n or ("item " .. e[1])
        if it and it.npc and #it.npc == 1 and (not it.obj or #it.obj == 0) and N[it.npc[1]] then
            local nn = N[it.npc[1]]
            out[#out + 1] = { kind = "KILL", name = nn.n, text = "loot " .. itemName, locs = spawnLocs(nn, {}, "npc", it.npc[1]),
                elite = (nn.rank == 1 or nn.rank == 2 or nn.rank == 3) or false }
        else
            out[#out + 1] = { kind = "COLLECT", name = itemName, text = e[2], locs = itemLocs(e[1], {}) }
        end
    end
    if q.credit and q.credit[1] then
        local locs = {}
        for _, id in ipairs(q.credit[1]) do spawnLocs(N[id], locs, "npc", id) end
        out[#out + 1] = { kind = "KILL", name = q.credit[3] or (N[q.credit[2]] and N[q.credit[2]].n) or "targets", locs = locs }
    end
    if q.trig and q.trig[2] then
        local locs = {}
        for area, pts in pairs(q.trig[2]) do
            for _, p in ipairs(pts) do
                locs[#locs + 1] = { zone = parentZone(area), area = area, map = Z.areaToMap[area], x = p[1], y = p[2], name = q.trig[1] }
            end
        end
        out[#out + 1] = { kind = "COMPLETE", name = q.trig[1], text = q.trig[1], locs = locs }
    end
    return out
end

local function dist(pos, loc)
    if not pos or not loc then return CROSS_ZONE end
    if pos.zone ~= loc.zone then return CROSS_ZONE end
    local dx, dy = pos.x - loc.x, pos.y - loc.y
    return math.sqrt(dx * dx + dy * dy)
end

local function nearest(pos, locs)
    local best, bd
    for _, l in ipairs(locs or {}) do
        local d = dist(pos, l)
        if not bd or d < bd then best, bd = l, d end
    end
    return best, bd
end

local function inZone(locs, zone)
    for _, l in ipairs(locs or {}) do if l.zone == zone then return true end end
    return false
end

-- ---- XP model ---------------------------------------------------------------
-- xp needed to go from level L to L+1 (close to the Classic table), and the cumulative total to reach L
local function xpForLevel(L) return 40 * L * L + 360 * L end
local cumulative = { [1] = 0 }
for L = 2, 61 do cumulative[L] = cumulative[L - 1] + xpForLevel(L - 1) end
local function xpToLevel(L) return cumulative[math.max(1, math.min(61, L))] end
-- quest reward (real value from Questie's xp table when known) plus the kills on the way
local function baseXP(q)
    local lvl = q.lvl or 1
    local reward = q.xp or (50 * lvl + 1.5 * lvl * lvl)
    return reward + 0.8 * reward   -- kills / discovery while doing it
end
-- Reward reduction for out-levelled quests (Classic rules): full xp while the
-- player is at most 5 levels above the quest level, then 80/60/40/20%, then 10%.
local REDUCTION = { [6] = 0.8, [7] = 0.6, [8] = 0.4, [9] = 0.2 }
local function xpMultiplier(playerLevel, questLevel)
    local diff = playerLevel - (questLevel or 1)
    if diff <= 5 then return 1 end
    return REDUCTION[diff] or 0.1
end
-- levels left before this quest starts losing xp (0 = it already does)
local function marginOf(playerLevel, questLevel)
    return math.max(0, (questLevel or 1) + 5 - playerLevel)
end
local URGENCY = 4          -- map units of detour we accept per level of margin to save a quest from going grey
local GREY_SKIP = 0.2      -- quests that would only give this share of their xp are not worth starting

-- ---- candidate selection ----------------------------------------------------
local function classesOf(mask)
    if not mask or mask == 0 then return nil end
    local out = {}
    for bit, name in pairs(CLASS_NAMES) do if band(mask, bit) ~= 0 then out[#out + 1] = name end end
    table.sort(out)
    return #out > 0 and out or nil
end

local function candidates(zone, factionMask, minL, maxL)
    local set = {}
    for id, q in pairs(Q) do
        local ok = q.zone and q.zone > 0 and parentZone(q.zone) == zone and not q.hidden and not q.removed
        if ok and q.races and q.races ~= 0 and band(q.races, factionMask) == 0 then ok = false end
        if ok and q.special and band(q.special, 1) ~= 0 then ok = false end                 -- repeatable
        if ok and q.flags and (band(q.flags, 4096) ~= 0 or band(q.flags, 32768) ~= 0) then ok = false end -- daily / weekly
        if ok and (q.skill or q.spellreq) then ok = false end                                -- profession / spell gated
        if ok and q.sitem and #q.sitem > 0 and not (q.snpc and #q.snpc > 0) then ok = false end -- item started
        if ok and q.breadcrumb then ok = false end
        if ok and (q.req or 0) > maxL then ok = false end
        if ok and (q.lvl or 0) < minL - 3 then ok = false end
        if ok then
            local starts = questStarts(q)
            if #starts == 0 or not inZone(starts, zone) then ok = false end
            if ok and #questEnds(q) == 0 then ok = false end     -- nowhere known to turn it in
        end
        if ok then
            for _, o in ipairs(questObjectives(q)) do
                if #o.locs > 0 and not inZone(o.locs, zone) then ok = false break end
            end
        end
        if ok then set[id] = true end
    end
    -- prerequisites must be inside the set (or the chain is unreachable here)
    local changed = true
    while changed do
        changed = false
        for id in pairs(set) do
            local q = Q[id]
            local drop = false
            for _, pre in ipairs(q.pregroup or {}) do if not set[pre] then drop = true end end
            if q.pre and #q.pre > 0 then
                local any = false
                for _, pre in ipairs(q.pre) do if set[pre] then any = true end end
                if not any then drop = true end
            end
            if q.parent and not set[q.parent] then drop = true end
            if drop then set[id] = nil changed = true end
        end
    end
    -- exclusive groups: keep the lowest id
    for id in pairs(set) do
        for _, ex in ipairs(Q[id].excl or {}) do
            if set[ex] and ex < id then set[id] = nil break end
        end
    end
    return set
end

-- ---- the walk -----------------------------------------------------------------
local function generate(zoneDef, faction)
    local zone = zoneDef.id
    local factionMask = faction == "Alliance" and RACE_ALLIANCE or RACE_HORDE
    local set = candidates(zone, factionMask, zoneDef.min, zoneDef.max)
    local quests = {}
    for id in pairs(set) do
        local q = Q[id]
        quests[id] = {
            id = id, q = q, starts = questStarts(q), ends = questEnds(q), objs = questObjectives(q),
            accepted = false, done = false, turnedIn = false, classes = classesOf(q.classes),
        }
        for _, o in ipairs(quests[id].objs) do
            o.done = (#o.locs == 0)
            if o.elite then quests[id].elite = true end     -- group quest: routed as optional
        end
    end
    local count = 0
    for _ in pairs(quests) do count = count + 1 end
    if count == 0 then return nil end

    -- ---- hubs: clusters of quest givers / turn-ins ---------------------------
    local hubs = {}
    local function addHubLoc(l)
        if l.zone ~= zone then return end
        for _, h in ipairs(hubs) do
            local dx, dy = h.x - l.x, h.y - l.y
            if math.sqrt(dx * dx + dy * dy) <= HUB_RADIUS then
                h.n = h.n + 1
                h.x = h.x + (l.x - h.x) / h.n
                h.y = h.y + (l.y - h.y) / h.n
                return
            end
        end
        hubs[#hubs + 1] = { id = #hubs + 1, x = l.x, y = l.y, zone = l.zone, n = 1 }
    end
    do
        local ids = {}
        for id in pairs(quests) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            for _, l in ipairs(quests[id].starts) do addHubLoc(l) end
            for _, l in ipairs(quests[id].ends) do addHubLoc(l) end
        end
    end
    local function hubDist(h, l) return dist({ zone = h.zone, x = h.x, y = h.y }, l) end
    local function hubOf(l)
        local best, bd
        for _, h in ipairs(hubs) do
            local d = hubDist(h, l)
            if d <= HUB_RADIUS * 1.5 and (not bd or d < bd) then best, bd = h, d end
        end
        return best
    end
    local function hubOfLocs(locs, from)
        local l = nearest(from, locs)
        return l and hubOf(l) or nil
    end
    local currentHub

    local xp = xpToLevel(zoneDef.min)
    local function level()
        local L = 1
        while L < 60 and xp >= xpToLevel(L + 1) do L = L + 1 end
        return L
    end

    -- start at the lowest-level giver
    local pos
    do
        local bestQ
        for _, qq in pairs(quests) do
            if not bestQ or (qq.q.req or 0) < (bestQ.q.req or 0) or ((qq.q.req or 0) == (bestQ.q.req or 0) and qq.id < bestQ.id) then bestQ = qq end
        end
        for _, l in ipairs(bestQ.starts) do if l.zone == zone then pos = { zone = l.zone, x = l.x, y = l.y } break end end
    end

    local steps, logCount = {}, 0
    local function emit(step) steps[#steps + 1] = step end
    local function locFields(l)
        return { map = l.map, zone = Z.names[l.area] or Z.names[l.zone], x = l.x, y = l.y }
    end
    local function withLoc(step, l)
        if l then for k, v in pairs(locFields(l)) do step[k] = v end end
        return step
    end
    local function prereqsDone(qq)
        for _, pre in ipairs(qq.q.pregroup or {}) do if not (quests[pre] and quests[pre].turnedIn) then return false end end
        if qq.q.pre and #qq.q.pre > 0 then
            local any = false
            for _, pre in ipairs(qq.q.pre) do if quests[pre] and quests[pre].turnedIn then any = true end end
            if not any then return false end
        end
        if qq.q.parent and not (quests[qq.q.parent] and quests[qq.q.parent].accepted) then return false end
        return true
    end
    -- is this quest still on the way to something (a chain link others need)?
    local neededBy = {}
    for id, qq in pairs(quests) do
        for _, pre in ipairs(qq.q.pregroup or {}) do neededBy[pre] = true end
        for _, pre in ipairs(qq.q.pre or {}) do neededBy[pre] = true end
        if qq.q.parent then neededBy[qq.q.parent] = true end
    end
    local function worthStarting(qq)
        -- out-levelled quests are skipped unless a later quest needs them
        return neededBy[qq.id] or xpMultiplier(level(), qq.q.lvl) > GREY_SKIP
    end
    local function available(qq)
        return not qq.accepted and not qq.turnedIn and prereqsDone(qq) and (qq.q.req or 0) <= level() + 1 and worthStarting(qq)
    end
    local function accept(qq, l)
        qq.accepted = true
        if l then local h = hubOf(l) if h then currentHub = h end end
        logCount = logCount + 1
        local step = { type = "ACCEPT", quest = qq.id, questName = qq.q.n }
        if l and l.kind == "npc" then step.npc = l.id step.npcName = l.name end
        if qq.classes then step.class = qq.classes end
        if qq.elite then step.optional = true step.note = "elite target - bring a group (optional)" end
        withLoc(step, l)
        emit(step)
        local allDone = true
        for _, o in ipairs(qq.objs) do if not o.done then allDone = false end end
        qq.done = allDone
    end
    local function turnIn(qq, l)
        qq.turnedIn = true
        if l then local h = hubOf(l) if h then currentHub = h end end
        qq.accepted = false
        logCount = logCount - 1
        local mult = xpMultiplier(level(), qq.q.lvl)
        xp = xp + baseXP(qq.q) * mult
        local step = { type = "TURNIN", quest = qq.id, questName = qq.q.n }
        if mult < 1 then step.note = string.format("reduced xp (%d%%) - you out-levelled it", math.floor(mult * 100 + 0.5)) end
        if l and l.kind == "npc" then step.npc = l.id step.npcName = l.name end
        if qq.classes then step.class = qq.classes end
        if qq.elite then step.optional = true end
        withLoc(step, l)
        emit(step)
    end
    local function doObjective(qq, o, l)
        o.done = true
        local step = { type = o.kind, quest = qq.id, questName = qq.q.n, target = o.name }
        if l and l.kind == "npc" and o.kind == "KILL" then step.npc = l.id end
        if o.text then step.note = o.text end
        if qq.classes then step.class = qq.classes end
        if qq.elite then step.optional = true step.note = (o.elite and "ELITE - " or "") .. (step.note or "") .. " (group quest, optional)" end
        if #o.locs > 1 then step.near = true end   -- many spawns: the addon points at the nearest one at runtime, x/y is only the planned spot
        withLoc(step, l)
        -- merge with a previous step of the same quest at the same spot
        local prev = steps[#steps]
        if prev and prev.quest == qq.id and prev.type ~= "ACCEPT" and prev.type ~= "TURNIN" and prev.x and step.x
            and math.abs(prev.x - step.x) < 2 and math.abs(prev.y - step.y) < 2 then
            prev.target = prev.target .. " / " .. o.name
            if prev.type ~= step.type then prev.type = "COMPLETE" end
        else
            emit(step)
        end
        local allDone = true
        for _, oo in ipairs(qq.objs) do if not oo.done then allDone = false end end
        qq.done = allDone
    end

    local guard = 0
    local tour
    while guard < 5000 do
        guard = guard + 1
        local progressed = false
        -- 1. accept everything available at this hub
        local hubAccepts = {}
        for id, qq in pairs(quests) do
            if available(qq) and logCount < LOG_CAP then
                local l, d = nearest(pos, qq.starts)
                if l and d <= HUB then hubAccepts[#hubAccepts + 1] = { qq = qq, l = l, d = d } end
            end
        end
        table.sort(hubAccepts, function(a, b)
            local la, lb = a.qq.q.lvl or 0, b.qq.q.lvl or 0
            if la ~= lb then return la < lb end
            if a.d ~= b.d then return a.d < b.d end
            return a.qq.id < b.qq.id
        end)
        for _, h in ipairs(hubAccepts) do
            if logCount < LOG_CAP and available(h.qq) then accept(h.qq, h.l) progressed = true end
        end
        -- 2. turn in everything finished at this hub
        local hubTurnins = {}
        for id, qq in pairs(quests) do
            if qq.accepted and qq.done then
                local l, d = nearest(pos, qq.ends)
                if l and d <= HUB then hubTurnins[#hubTurnins + 1] = { qq = qq, l = l, d = d } end
            end
        end
        table.sort(hubTurnins, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.qq.id < b.qq.id end)
        for _, h in ipairs(hubTurnins) do turnIn(h.qq, h.l) progressed = true end
        if progressed then
            -- the log changed: plan the next tour from scratch
            tour = nil
        else
            -- 3. plan a tour through everything useful, then walk it
            --    (nearest-neighbour with grey-quest urgency, improved by 2-opt,
            --    turn-ins kept after their objectives)
            local L = level()
            local function urgency(qq) return math.min(marginOf(L, qq.q.lvl), 8) * URGENCY + (qq.elite and 10 or 0) end
            local function taskValid(t)
                if t.kind == "obj" then return t.qq.accepted and not t.o.done end
                if t.kind == "turnin" then return t.qq.accepted and t.qq.done end
                return available(t.qq) and logCount < LOG_CAP
            end
            if not tour or #tour == 0 then
                -- ---- hub reasoning ------------------------------------------------
                -- Everything tied to the current hub (objectives of quests that
                -- turn in here, turn-ins here, givers here, objectives close by)
                -- is finished before we leave. When nothing is left, the next hub
                -- is the one with the most waiting for us, and quest givers /
                -- objectives on the way are taken along.
                local tasks = {}
                local function addObj(qq, oi, o, extra) tasks[#tasks + 1] = { kind = "obj", qq = qq, o = o, locs = o.locs, order = qq.id * 10 + oi, extra = extra } end
                local here = currentHub or hubOf(pos)
                currentHub = here
                local homeCount = 0
                for id, qq in pairs(quests) do
                    if qq.accepted and not qq.done then
                        local endHub = hubOfLocs(qq.ends, pos)
                        for oi, o in ipairs(qq.objs) do
                            if not o.done then
                                local l, d = nearest(pos, o.locs)
                                local nearHub = here and l and hubDist(here, l) <= OBJ_RADIUS
                                local farObj = here and l and hubDist(here, l) > FAR_OBJ
                                if l and ((here and endHub == here and not farObj) or nearHub) then addObj(qq, oi, o, urgency(qq)) homeCount = homeCount + 1 end
                            end
                        end
                    elseif qq.accepted and qq.done then
                        local l, d = nearest(pos, qq.ends)
                        if l and here and hubOf(l) == here then tasks[#tasks + 1] = { kind = "turnin", qq = qq, locs = qq.ends, order = id, extra = urgency(qq) } homeCount = homeCount + 1 end
                    elseif available(qq) and logCount < LOG_CAP then
                        local l, d = nearest(pos, qq.starts)
                        if l and here and hubOf(l) == here then tasks[#tasks + 1] = { kind = "accept", qq = qq, locs = qq.starts, order = id, extra = 12 + urgency(qq) } homeCount = homeCount + 1 end
                    end
                end
                if homeCount == 0 then
                    -- nothing left here: pick the next hub by what waits there, minus the walk
                    local hubScore = {}
                    local function bump(h, v) if h then hubScore[h] = (hubScore[h] or 0) + v end end
                    local turninAt = {}
                    for id, qq in pairs(quests) do
                        if qq.accepted and qq.done then
                            local h = hubOfLocs(qq.ends, pos)
                            bump(h, W_TURNIN)
                            if h then turninAt[h] = true end
                        elseif qq.accepted and not qq.done then
                            for _, o in ipairs(qq.objs) do
                                if not o.done then bump(hubOfLocs(o.locs, pos), W_OBJ) bump(hubOfLocs(qq.ends, pos), W_OBJ / 2) end
                            end
                        elseif available(qq) and logCount < LOG_CAP then bump(hubOfLocs(qq.starts, pos), W_ACCEPT) end
                    end
                    local target, targetCost
                    if os.getenv("FG_HUBTOUR") ~= "0" then
                        -- plan the order in which the remaining hubs get visited (open path
                        -- from here, nearest-neighbour + 2-opt) and take its first stop: a
                        -- hub with a finished quest is never left behind for a long trip back
                        local list = {}
                        for h, score in pairs(hubScore) do if h ~= here and score > 0 then list[#list + 1] = h end end
                        table.sort(list, function(a, b) return a.id < b.id end)
                        if #list > 0 then
                            local function hd(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
                            local order, remaining, cur = {}, {}, { x = pos.x, y = pos.y }
                            for _, h in ipairs(list) do remaining[#remaining + 1] = h end
                            while #remaining > 0 do
                                local bi, bd
                                for i, h in ipairs(remaining) do
                                    local d = hubDist(h, pos) >= CROSS_ZONE and CROSS_ZONE or hd(cur, h)
                                    d = d - (turninAt[h] and NEAR_PULL or 0) * 0.2   -- slight preference for handing in
                                    if not bd or d < bd then bi, bd = i, d end
                                end
                                local h = table.remove(remaining, bi)
                                order[#order + 1] = h
                                cur = h
                            end
                            local function plen(list2)
                                local total, prev = 0, { x = pos.x, y = pos.y }
                                for _, h in ipairs(list2) do
                                    total = total + (hubDist(h, pos) >= CROSS_ZONE and CROSS_ZONE or hd(prev, h))
                                    prev = h
                                end
                                return total
                            end
                            local improved, rounds = true, 0
                            while improved and rounds < 30 do
                                improved = false
                                rounds = rounds + 1
                                local base = plen(order)
                                for i = 1, #order - 1 do
                                    for j = i + 1, #order do
                                        local cand = {}
                                        for k = 1, i - 1 do cand[#cand + 1] = order[k] end
                                        for k = j, i, -1 do cand[#cand + 1] = order[k] end
                                        for k = j + 1, #order do cand[#cand + 1] = order[k] end
                                        local len = plen(cand)
                                        if len < base - 0.01 then order, base, improved = cand, len, true end
                                    end
                                end
                            end
                            target = order[1]
                        end
                    else
                        for h, score in pairs(hubScore) do
                            if h ~= here then
                                local d = hubDist(h, pos)
                                if turninAt[h] and d <= NEAR_TURNIN then score = score + NEAR_PULL end
                                local c = d - score
                                if not targetCost or c < targetCost or (c == targetCost and h.id < target.id) then target, targetCost = h, c end
                            end
                        end
                    end
                    if os.getenv("FG_DEBUG") then
                        local names = {}
                        for h, score in pairs(hubScore) do names[#names + 1] = string.format("h%d(%.0f,%.0f) s=%.0f d=%.0f%s", h.id, h.x, h.y, score, hubDist(h, pos), turninAt[h] and " T" or "") end
                        table.sort(names)
                        io.stderr:write(string.format("[%d steps] at %.0f,%.0f here=%s -> %s | %s\n", #steps, pos.x, pos.y, here and here.id or "-", target and target.id or "-", table.concat(names, "  ")))
                    end
                    if target then
                        local straight = hubDist(target, pos)
                        local function onTheWay(locs)
                            local l = nearest(pos, locs)
                            if not l then return false end
                            return dist(pos, l) + hubDist(target, l) - straight <= DETOUR
                        end
                        for id, qq in pairs(quests) do
                            if qq.accepted and not qq.done then
                                local endHub = hubOfLocs(qq.ends, pos)
                                for oi, o in ipairs(qq.objs) do
                                    if not o.done and #o.locs > 0 and (endHub == target or onTheWay(o.locs) or (hubOfLocs(o.locs, pos) == target)) then addObj(qq, oi, o, urgency(qq)) end
                                end
                            elseif qq.accepted and qq.done then
                                if hubOfLocs(qq.ends, pos) == target or onTheWay(qq.ends) then tasks[#tasks + 1] = { kind = "turnin", qq = qq, locs = qq.ends, order = id, extra = urgency(qq) } end
                            elseif available(qq) and logCount < LOG_CAP then
                                if hubOfLocs(qq.starts, pos) == target or onTheWay(qq.starts) then tasks[#tasks + 1] = { kind = "accept", qq = qq, locs = qq.starts, order = id, extra = 12 + urgency(qq) } end
                            end
                        end
                        currentHub = target
                    else
                        -- no hub has anything: whatever is nearest (objectives far from any hub)
                        for id, qq in pairs(quests) do
                            if qq.accepted and not qq.done then
                                for oi, o in ipairs(qq.objs) do if not o.done and #o.locs > 0 then addObj(qq, oi, o, urgency(qq)) end end
                            elseif qq.accepted and qq.done and #qq.ends > 0 then
                                tasks[#tasks + 1] = { kind = "turnin", qq = qq, locs = qq.ends, order = id, extra = urgency(qq) }
                            elseif available(qq) and logCount < LOG_CAP and #qq.starts > 0 then
                                tasks[#tasks + 1] = { kind = "accept", qq = qq, locs = qq.starts, order = id, extra = 12 + urgency(qq) }
                            end
                        end
                        if #tasks > 0 then
                            -- just the nearest one; re-plan after it
                            local bi, bd
                            for i, t in ipairs(tasks) do local _, d = nearest(pos, t.locs) if d and (not bd or d + t.extra < bd) then bi, bd = i, d + t.extra end end
                            tasks = bi and { tasks[bi] } or {}
                        end
                    end
                end
                tour = {}
                if #tasks > 0 then
                    -- nearest neighbour from the current position, urgency-weighted
                    local remaining, cur = {}, pos
                    for _, t in ipairs(tasks) do remaining[#remaining + 1] = t end
                    while #remaining > 0 do
                        local bi, bc
                        for i, t in ipairs(remaining) do
                            local l, d = nearest(cur, t.locs)
                            if l then
                                local c = d + t.extra
                                if not bc or c < bc or (c == bc and t.order < remaining[bi].order) then bi, bc = i, c end
                            end
                        end
                        if not bi then break end
                        local t = table.remove(remaining, bi)
                        t.l = nearest(cur, t.locs)
                        cur = { zone = t.l.zone, x = t.l.x, y = t.l.y }
                        tour[#tour + 1] = t
                    end
                    -- 2-opt: reverse segments while it shortens the walk and keeps every
                    -- turn-in after that quest's objectives
                    local function tdist(a, b) return dist(a and { zone = a.l.zone, x = a.l.x, y = a.l.y } or pos, b.l) end
                    local function ordered(list)
                        local placed = {}
                        for _, t in ipairs(list) do
                            if t.kind == "turnin" then
                                for _, tt in ipairs(list) do
                                    if tt.kind == "obj" and tt.qq.id == t.qq.id and not placed[tt] then return false end
                                end
                            end
                            placed[t] = true
                        end
                        return true
                    end
                    -- walk length plus a position-weighted urgency term: a task
                    -- that can wait (large extra) costs more the earlier it is placed
                    local function length(list)
                        local total, prev, n = 0, nil, #list
                        for i, t in ipairs(list) do total = total + tdist(prev, t) + t.extra * (n - i + 1) / n prev = t end
                        return total
                    end
                    local improved, rounds = true, 0
                    if os.getenv("FG_GREEDY") then improved = false while #tour > 1 do table.remove(tour) end end
                    if os.getenv("FG_NO2OPT") then improved = false end
                    while improved and rounds < 50 do
                        improved = false
                        rounds = rounds + 1
                        local base = length(tour)
                        for i = 1, #tour - 1 do
                            for j = i + 1, #tour do
                                local cand = {}
                                for k = 1, i - 1 do cand[#cand + 1] = tour[k] end
                                for k = j, i, -1 do cand[#cand + 1] = tour[k] end
                                for k = j + 1, #tour do cand[#cand + 1] = tour[k] end
                                local len = length(cand)
                                if len < base - 0.01 and ordered(cand) then
                                    tour, base, improved = cand, len, true
                                end
                            end
                        end
                    end
                end
            end
            local best
            while tour and #tour > 0 do
                local t = table.remove(tour, 1)
                if taskValid(t) then
                    local l = nearest(pos, t.locs) or t.l
                    if t.kind == "obj" then best = { act = { kind = "obj", qq = t.qq, o = t.o, l = l } }
                    elseif t.kind == "turnin" then best = { act = { kind = "turnin", qq = t.qq, l = l } }
                    else best = { act = { kind = "accept", qq = t.qq, l = l } } end
                    break
                end
            end
            if not best then
                -- nothing reachable: are quests only waiting for levels? then "grind" to the lowest requirement
                local needed
                for _, qq in pairs(quests) do
                    if not qq.accepted and not qq.turnedIn and prereqsDone(qq) and logCount < LOG_CAP then
                        local req = qq.q.req or 0
                        if req > level() + 1 and (not needed or req < needed) then needed = req end
                    end
                end
                if not needed or needed > 60 then break end
                emit({ type = "GRIND", level = needed, note = "the next quests need level " .. needed })
                xp = math.max(xp, xpToLevel(needed))
                progressed = true
            else
            local a = best.act
            pos = { zone = a.l.zone, x = a.l.x, y = a.l.y }
            if a.kind == "obj" then doObjective(a.qq, a.o, a.l)
            elseif a.kind == "turnin" then turnIn(a.qq, a.l)
            else accept(a.qq, a.l) end
            end
        end
    end

    -- leftovers (quests never finished because their turn-in is elsewhere etc.)
    local left = 0
    for _, qq in pairs(quests) do if qq.accepted or (not qq.turnedIn and prereqsDone(qq) and worthStarting(qq)) then left = left + 1 end end
    return steps, count, left, level()
end

-- ---- JSON --------------------------------------------------------------------
local KEY_ORDER = { "type", "quest", "questName", "npc", "npcName", "target", "class", "map", "zone", "x", "y", "near", "note", "text", "optional" }
local function jsonString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n" end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end
local function jsonValue(v, indent)
    local t = type(v)
    if t == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.1f", v)
    elseif t == "string" then return jsonString(v)
    elseif t == "boolean" then return tostring(v)
    elseif t == "table" then
        if #v > 0 then
            local parts = {}
            for _, x in ipairs(v) do parts[#parts + 1] = jsonValue(x, indent) end
            return "[" .. table.concat(parts, ", ") .. "]"
        end
        local keys, seen = {}, {}
        for _, k in ipairs(KEY_ORDER) do if v[k] ~= nil then keys[#keys + 1] = k seen[k] = true end end
        local rest = {}
        for k in pairs(v) do if not seen[k] then rest[#rest + 1] = k end end
        table.sort(rest)
        for _, k in ipairs(rest) do keys[#keys + 1] = k end
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = jsonString(k) .. ": " .. jsonValue(v[k], indent) end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return "null"
end

-- ---- main ---------------------------------------------------------------------
local MIN_QUESTS = 8
local factions = onlyFaction and { onlyFaction } or { "Alliance", "Horde" }
local zoneByID = {}
for _, zd in ipairs(ZONES) do zoneByID[zd.id] = zd end
local function guideID(faction, zoneID) return "GEN_" .. faction:upper() .. "_" .. slug(Z.names[zoneID] or tostring(zoneID)) end

-- pass 1: generate
local results, exists = {}, {}
for _, zd in ipairs(ZONES) do
    for _, faction in ipairs({ "Alliance", "Horde" }) do
        local steps, count, left, endLevel = generate(zd, faction)
        if steps and count >= MIN_QUESTS then
            results[#results + 1] = { zd = zd, faction = faction, steps = steps, count = count, left = left, endLevel = endLevel }
            exists[guideID(faction, zd.id)] = true
        elseif (not onlyZone or onlyZone == zd.id) and (not onlyFaction or onlyFaction == faction) then
            print(string.format("%-40s skipped (%s quests)", faction .. " " .. (Z.names[zd.id] or zd.id), tostring(count)))
        end
    end
end
-- follow a faction's zone chain until a generated guide is found
local function resolveNext(faction, zoneID)
    local guard = 0
    while zoneID and guard < 20 do
        guard = guard + 1
        local zd = zoneByID[zoneID]
        if not zd then return nil end
        local nextZone = faction == "Alliance" and zd.nextA or zd.nextH
        if not nextZone then return nil end
        if exists[guideID(faction, nextZone)] then return guideID(faction, nextZone) end
        zoneID = nextZone
    end
    return nil
end

-- pass 2: write
local total = 0
for _, r in ipairs(results) do
    local zd, faction, steps, count, left, endLevel = r.zd, r.faction, r.steps, r.count, r.left, r.endLevel
    if (not onlyZone or onlyZone == zd.id) and (not onlyFaction or onlyFaction == faction) then
        do
            local zoneName = Z.names[zd.id] or tostring(zd.id)
            local nextID = resolveNext(faction, zd.id)
            do
                local id = guideID(faction, zd.id)
                local guide = {
                    id = id,
                    name = string.format("%s %d-%d (%s)", zoneName, zd.min, zd.max, faction),
                    version = 1,
                    faction = faction,
                    minLevel = zd.min, maxLevel = zd.max,
                    map = Z.areaToMap[zd.id], zone = zoneName,
                    author = "ForeverGuide route generator",
                    notes = string.format("Auto-generated from the quest database: %d quests, %d steps, model reaches level %d. Not a speedrun route - a sensible order; the engine adapts as you play.", count, #steps, endLevel),
                    steps = steps,
                }
                if zd.races and (faction == "Alliance") == (zd.nextA ~= nil) then guide.race = zd.races end
                if nextID then guide.next = nextID end
                local lines = { "{" }
                for _, k in ipairs({ "id", "name", "version", "faction", "race", "minLevel", "maxLevel", "map", "zone", "next", "author", "notes" }) do
                    if guide[k] ~= nil then lines[#lines + 1] = "  " .. jsonString(k) .. ": " .. jsonValue(guide[k]) .. "," end
                end
                lines[#lines + 1] = '  "steps": ['
                for i, s in ipairs(steps) do
                    lines[#lines + 1] = "    " .. jsonValue(s) .. (i < #steps and "," or "")
                end
                lines[#lines + 1] = "  ]"
                lines[#lines + 1] = "}"
                local f = assert(io.open(root .. "guides-src/" .. id .. ".json", "w"))
                f:write(table.concat(lines, "\n") .. "\n")
                f:close()
                total = total + 1
                print(string.format("%-40s %3d quests %4d steps  ends ~lvl %d  next %s%s", id, count, #steps, endLevel, tostring(nextID), left > 0 and ("  " .. left .. " left over") or ""))
            end
        end
    end
end
print(total .. " guides written to guides-src/")
