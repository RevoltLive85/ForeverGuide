-- ============================================================
-- ForeverGuide / tools/plan_route.lua
-- Route planner: one continuous 1-60 leveling route per starting race,
-- written as a chain of zone chapters (guides-src/GEN_*.json) for
-- tools/compile_guides.py.
--
--   lua5.1 tools/plan_route.lua                 # every race, both factions
--   lua5.1 tools/plan_route.lua Human           # one starting race
--   FG_TRACE=1 ...                              # per-chapter reasoning on stderr
--
-- What "fastest" means here: xp per second of modelled play time.
--   * tools/lib/route_model.lua prices everything in seconds - walking
--     (yards / run or mount speed), kills (mob level, drop rates, elites),
--     gathering, escorts, talking - and pays real quest rewards plus kill xp.
--   * the yardstick is the grind rate: xp/s from killing even-level mobs.
--     A quest that pays less than VALUE_MIN of that (work + travel included)
--     is skipped, because grinding would be faster. Elite quests are skipped.
--   * the player state (xp, quest log, finished quests, position, hearth)
--     carries through the whole route: chains continue across zones, city
--     turn-ins pile up and are collected in one trip, and a zone is left
--     when its remaining quests are not worth the time - and revisited
--     later when they are (Joana's Barrens x4).
--   * the next chapter is chosen by simulating every reasonable candidate
--     zone (and grinding) from the current state and taking the best
--     xp / (travel + chapter time).
--   * inside a chapter: hub logic (accept everything worth it at a hub,
--     do the objectives tied to it, hand in, move to the next hub) with
--     nearest-neighbour + 2-opt tours in seconds, urgency for quests about
--     to go grey, and hubs pruned when their detour is not paid for.
-- ============================================================

local root = arg and arg[0] and arg[0]:match("^(.*)tools[/\\]plan_route%.lua$") or "./"
if root == "" then root = "./" end
package.path = root .. "tools/lib/?.lua;" .. package.path
local D = require("route_data").load(root)
D.loadMapSizes(root)
local X = require("route_model")
local Q, N, Z = D.Q, D.N, D.Z

local onlyRace = arg[1]
local TRACE = os.getenv("FG_TRACE")
local function env(name, default) return tonumber(os.getenv(name) or "") or default end

local RACE_ALLIANCE, RACE_HORDE = 77, 178
local CLASS_NAMES = { [1] = "WARRIOR", [2] = "PALADIN", [4] = "HUNTER", [8] = "ROGUE", [16] = "PRIEST", [64] = "SHAMAN",
                      [128] = "MAGE", [256] = "WARLOCK", [1024] = "DRUID" }

-- planner knobs (seconds unless noted)
local HUB_SEC = env("FG_HUB", 25)            -- things this close together are "here"
local HUB_CLUSTER = env("FG_HUBR", 60)       -- givers / turn-ins this close form one hub
local OBJ_NEAR = env("FG_OBJNEAR", 150)      -- objectives this close to the hub are done before leaving
local OBJ_FAR = env("FG_OBJFAR", 200)        -- objectives farther than this wait until the route passes
local DETOUR = env("FG_DETOUR", 45)          -- extra seconds accepted to take something along on the way
local URGENCY = env("FG_URGENCY", 25)        -- seconds of detour per level of headroom before a quest goes grey
local GREY_SKIP = 0.2
local GRIND_FACTOR = env("FG_GRINDF", 0.7)   -- grind instead when the best chapter pays less than this share of the grind rate
local ZONE_SWITCH = env("FG_SWITCH", 180)    -- fixed cost of changing zones (orientation, flight master, loading)
local MIN_CHAPTER = env("FG_MINCH", 600)     -- a trip to another zone must be worth at least this many seconds of play
local CROSS_SEA = env("FG_CROSSSEA", 0.85)   -- rate factor for a chapter on the other continent
local MAX_CHAPTERS = 150
local REMOTE = 1e6                           -- "in another zone" marker distance

-- ---- static quest records --------------------------------------------------------
local function classesOf(mask)
    if not mask or mask == 0 then return nil end
    local out = {}
    for bit, name in pairs(CLASS_NAMES) do if D.band(mask, bit) ~= 0 then out[#out + 1] = name end end
    table.sort(out)
    return #out > 0 and out or nil
end

local recCache = {}
local function rec(id)
    local r = recCache[id]
    if r then return r end
    local q = Q[id]
    r = { id = id, q = q, starts = D.questStarts(q), ends = D.questEnds(q), objs = D.questObjectives(q),
          escort = D.isEscort(q), classes = classesOf(q.classes) }
    for _, o in ipairs(r.objs) do
        if o.elite then r.elite = true end
        o.static = (#o.locs == 0)     -- no known place: counts as done when accepted (talk / use item)
    end
    -- quests other quests need (chain links)
    recCache[id] = r
    return r
end
local neededBy, unlocks = {}, {}
for id, q in pairs(Q) do
    for _, pre in ipairs(q.pregroup or {}) do neededBy[pre] = true unlocks[pre] = unlocks[pre] or {} table.insert(unlocks[pre], id) end
    for _, pre in ipairs(q.pre or {}) do neededBy[pre] = true unlocks[pre] = unlocks[pre] or {} table.insert(unlocks[pre], id) end
    if q.parent then neededBy[q.parent] = true unlocks[q.parent] = unlocks[q.parent] or {} table.insert(unlocks[q.parent], id) end
    if q.next and Q[q.next] then unlocks[id] = unlocks[id] or {} table.insert(unlocks[id], q.next) end
end
--- xp this quest unlocks further down its chain (discounted per hop): a 245-xp
--- "Welcome to the Jungle" is worth doing because of the Mastery chains behind it
local function chainValue(id, L, mask, depth, seen)
    depth = depth or 0
    seen = seen or {}
    if depth >= 4 or seen[id] then return 0 end
    seen[id] = true
    local total = 0
    for _, f in ipairs(unlocks[id] or {}) do
        local fq = Q[f]
        if fq and not seen[f] and not fq.hidden and not fq.removed and not (fq.classes and fq.classes ~= 0)
           and (not fq.races or fq.races == 0 or D.band(fq.races, mask) ~= 0) then
            local mult = X.xpMultiplier(L, fq.lvl)
            if mult > GREY_SKIP then
                total = total + 0.7 * (X.questReward(fq) * mult + chainValue(f, L, mask, depth + 1, seen))
            end
        end
    end
    return total
end

-- base filter: could this quest ever be on the route for this faction?
local baseOK = {}
local function questOK(id, factionMask)
    local key = id * 2 + (factionMask == RACE_ALLIANCE and 0 or 1)
    if baseOK[key] ~= nil then return baseOK[key] end
    local q = Q[id]
    local ok = q.zone and q.zone > 0 and not q.hidden and not q.removed
    if ok and q.races and q.races ~= 0 and D.band(q.races, factionMask) == 0 then ok = false end
    if ok and q.special and D.band(q.special, 1) ~= 0 then ok = false end                        -- repeatable
    if ok and q.flags and (D.band(q.flags, 4096) ~= 0 or D.band(q.flags, 32768) ~= 0) then ok = false end -- daily / weekly
    if ok and (q.skill or q.spellreq) then ok = false end                                        -- profession / spell gated
    if ok and q.sitem and #q.sitem > 0 and not (q.snpc and #q.snpc > 0) then ok = false end      -- item started
    if ok and q.breadcrumb then ok = false end
    if ok and q.classes and q.classes ~= 0 then ok = false end                                   -- class quests: not modelled
    if ok then
        local r = rec(id)
        if #r.starts == 0 or #r.ends == 0 then ok = false end
        if ok and r.elite and not os.getenv("FG_ELITE") then ok = false end
    end
    baseOK[key] = ok and true or false
    return baseOK[key]
end

-- ---- geometry in seconds ----------------------------------------------------------------
local function yards(a, b)
    local size = D.MAP_SIZE[a.map or -1] or D.MAP_SIZE[Z.areaToMap[a.zone] or -1] or { 4000, 2667 }
    local dx, dy = (a.x - b.x) * size[1] / 100, (a.y - b.y) * size[2] / 100
    return math.sqrt(dx * dx + dy * dy)
end

-- ---- the chapter walk ------------------------------------------------------------------
--- state: { xp, time, pos = {zone,x,y,map}, qs = { [id] = { accepted, done = {[i]=true}, turnedIn } },
---          hearth = {zone,x,y,map,name}, hearthReady, visits = {[zone]=n}, faction, mask }
local function qstate(state, id)
    local s = state.qs[id]
    if not s then s = { done = {} } state.qs[id] = s end
    return s
end
local function level(state) return X.levelAt(state.xp) end
local function travelZones(state, a, b)
    if a == b then return 0 end
    return state.travel(a, b) + ZONE_SWITCH
end
--- seconds from pos to loc
local function secs(state, pos, loc)
    if not pos or not loc then return REMOTE end
    if pos.zone ~= loc.zone then return travelZones(state, pos.zone, loc.zone) + 45 end
    return yards(pos, loc) / X.speed(level(state))
end
local function nearest(state, pos, locs)
    local best, bd
    for _, l in ipairs(locs or {}) do
        local d = secs(state, pos, l)
        if not bd or d < bd then best, bd = l, d end
    end
    return best, bd
end
local function inZone(locs, zone)
    for _, l in ipairs(locs or {}) do if l.zone == zone then return true end end
    return false
end
local function objDone(state, r, i) return r.objs[i].static or qstate(state, r.id).done[i] end
local function questDone(state, r)
    for i in ipairs(r.objs) do if not objDone(state, r, i) then return false end end
    return true
end
local function prereqsDone(state, r)
    local q = r.q
    for _, pre in ipairs(q.pregroup or {}) do if not (state.qs[pre] and state.qs[pre].turnedIn) then return false end end
    if q.pre and #q.pre > 0 then
        local any = false
        for _, pre in ipairs(q.pre) do if state.qs[pre] and state.qs[pre].turnedIn then any = true end end
        if not any then return false end
    end
    if q.parent and not (state.qs[q.parent] and state.qs[q.parent].accepted) then return false end
    for _, ex in ipairs(q.excl or {}) do
        local s = state.qs[ex]
        if s and (s.turnedIn or s.accepted) then return false end
    end
    return true
end
local function logCount(state)
    local n = 0
    for _, s in pairs(state.qs) do if s.accepted then n = n + 1 end end
    return n
end

--- Where do this quest's objectives happen (centroid of the nearest spawn of each)?
local function objectiveTravel(state, r, from)
    local total, cur = 0, from
    for i, o in ipairs(r.objs) do
        if not objDone(state, r, i) and #o.locs > 0 then
            local l, d = nearest(state, cur, o.locs)
            if l then total = total + d cur = l end
        end
    end
    return total, cur
end

--- Is the quest worth starting from `from` at this level? (xp per second vs grind rate)
local function packageValue(state, r, from)
    local L = level(state)
    local work, xp = X.questCost(r, L)
    local travel, last = objectiveTravel(state, r, from)
    local endLoc, endTravel = nearest(state, last or from, r.ends)
    if endLoc and from and endLoc.zone ~= from.zone then
        travel = travel * X.SHARED_TRAVEL + (endTravel or 0) * 0.8   -- a trip to another zone is mostly this quest's own cost
    else
        travel = (travel + (endTravel or 0)) * X.SHARED_TRAVEL
    end
    -- a chain link: what it unlocks counts too (discounted; the follow-ups are usually close by)
    local bonus = 0.5 * chainValue(r.id, L, state.mask)
    return (xp + bonus) / (work + travel), work, xp
end
local function worthIt(state, r, from)
    local L = level(state)
    if X.xpMultiplier(L, r.q.lvl) <= GREY_SKIP and not neededBy[r.id] then return false end
    local v = packageValue(state, r, from)
    return v >= X.VALUE_MIN * X.grindRate(L)
end

local function eligible(state, r, zone)
    -- accept-able now: not taken, prereqs, level, giver known
    local s = state.qs[r.id]
    if s and (s.accepted or s.turnedIn) then return false end
    if not prereqsDone(state, r) then return false end
    if (r.q.req or 0) > level(state) then return false end
    if not inZone(r.starts, zone) then return false end
    -- objectives must be in this zone (or nowhere in particular)
    for i, o in ipairs(r.objs) do
        if #o.locs > 0 and not inZone(o.locs, zone) then return false end
    end
    -- a turn-in elsewhere must be somewhere we will actually go: our capital, or a
    -- zone of the current level band (deliveries to a zone we have out-levelled clog the log)
    if not inZone(r.ends, zone) then
        local ok = false
        local L = level(state)
        for _, l in ipairs(r.ends) do
            local zd = D.zoneByID[l.zone]
            if zd and (zd.faction == nil or zd.faction == state.faction) then
                if zd.city and zd.faction == state.faction then ok = true end
                if not zd.city and zd.min <= L + 4 and zd.max >= L - 2 then ok = true end
            end
        end
        if not ok then return false end
    end
    return true
end

local function runChapter(state, zone, emit)
    local L0 = level(state)
    local t0, xp0 = state.time, state.xp
    local steps = {}
    local function out(step) steps[#steps + 1] = step end
    local visits = state.visits[zone] or 0
    state.visits[zone] = visits + 1

    -- candidate set: quests to accept here + log quests with work here
    local quests = {}
    for id in pairs(Q) do
        if questOK(id, state.mask) then
            local r = rec(id)
            local s = state.qs[id]
            local useful = false
            if s and s.accepted then
                if inZone(r.ends, zone) then useful = true end
                for i, o in ipairs(r.objs) do if not objDone(state, r, i) and inZone(o.locs, zone) then useful = true end end
            elseif not (s and s.turnedIn) and inZone(r.starts, zone) then
                -- any quest that starts here, whatever its chain state: prerequisites get
                -- done during the chapter and the follow-up must then be on the table
                useful = true
            end
            if useful then quests[id] = r end
        end
    end

    if os.getenv("FG_STEPS") and tonumber(os.getenv("FG_STEPS")) == zone and os.getenv("FG_WHY") then
        local L = level(state)
        for id in pairs(Q) do
            if questOK(id, state.mask) then
                local r = rec(id)
                if inZone(r.starts, zone) then
                    local s = state.qs[id]
                    local why
                    if s and s.turnedIn then why = "done"
                    elseif s and s.accepted then why = "in log"
                    elseif not prereqsDone(state, r) then why = "prereq"
                    elseif (r.q.req or 0) > L then why = "needs L" .. r.q.req
                    elseif not eligible(state, r, zone) then why = "objectives elsewhere"
                    else
                        local v, w, xp = packageValue(state, r, state.pos)
                        why = string.format("value %.1f (%s %.1f) work %.0f xp %.0f", v, v >= X.VALUE_MIN * X.grindRate(L) and "ok" or "LOW <", X.VALUE_MIN * X.grindRate(L), w, xp)
                    end
                    io.stderr:write(string.format("      q%-6d L%2d %-30s %s\n", id, r.q.lvl or 0, r.q.n, why))
                end
            end
        end
    end
    -- hubs in this zone: clusters of givers / turn-ins
    local hubs = {}
    local function addHubLoc(l)
        if l.zone ~= zone then return end
        for _, h in ipairs(hubs) do
            if yards(h, l) / X.RUN_SPEED <= HUB_CLUSTER then
                h.n = h.n + 1
                h.x = h.x + (l.x - h.x) / h.n
                h.y = h.y + (l.y - h.y) / h.n
                return
            end
        end
        hubs[#hubs + 1] = { id = #hubs + 1, x = l.x, y = l.y, zone = zone, map = l.map, area = l.area, n = 1 }
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
    local function hubDist(h, l) return secs(state, h, l) end
    local function hubOf(l)
        if not l or l.zone ~= zone then return nil end
        local best, bd
        for _, h in ipairs(hubs) do
            local d = hubDist(h, l)
            if d <= HUB_CLUSTER * 1.5 and (not bd or d < bd) then best, bd = h, d end
        end
        return best
    end
    local function hubOfLocs(locs, from)
        local l = nearest(state, from, locs)
        return l and hubOf(l) or nil
    end

    -- arrive: at the biggest hub (town) unless already inside the zone
    local pos = state.pos
    if not pos or pos.zone ~= zone then
        local best
        for _, h in ipairs(hubs) do if not best or h.n > best.n then best = h end end
        if not best then return steps, 0, 0 end
        local from = state.pos
        local tt = from and travelZones(state, from.zone, zone) or 0
        -- hearthstone: use it when it saves time and is off cooldown
        local hs = state.hearth
        if from and hs and state.time >= (state.hearthReady or 0) then
            local viaHearth = 20 + travelZones(state, hs.zone, zone)
            if viaHearth + 60 < tt then
                out({ type = "TRAVEL", map = hs.map, zone = Z.names[hs.area] or Z.names[hs.zone], x = hs.x, y = hs.y, radius = 60,
                      note = "use your hearthstone (" .. (Z.names[hs.area] or Z.names[hs.zone] or "inn") .. ")" })
                state.hearthReady = state.time + X.HEARTH_CD
                tt = viaHearth
            end
        end
        state.time = state.time + tt
        pos = { zone = zone, x = best.x, y = best.y, map = best.map }
        out({ type = "TRAVEL", map = best.map, zone = Z.names[best.area] or Z.names[zone], x = pos.x, y = pos.y, radius = 60,
              note = string.format("travel to %s (%s)", Z.names[zone] or zone, Z.names[best.area] or "town") })
        state.pos = pos
    end
    local currentHub = hubOf(pos)
    -- a real town (4+ givers / turn-ins) we have just arrived at: set the hearthstone here
    if currentHub and currentHub.n >= 4 and (not state.hearth or state.hearth.zone ~= zone) and visits == 0 then
        state.hearth = { zone = zone, x = currentHub.x, y = currentHub.y, map = currentHub.map, area = currentHub.area }
        out({ type = "NOTE", map = currentHub.map, zone = Z.names[currentHub.area] or Z.names[zone], x = currentHub.x, y = currentHub.y,
              text = "set your hearthstone at the inn in " .. (Z.names[currentHub.area] or Z.names[zone] or "town") .. " (if there is one)" })
    end

    local function cur() return state.pos end
    local STEPTRACE = os.getenv("FG_STEPS") and tonumber(os.getenv("FG_STEPS")) == zone
    local function moveTo(l)
        local d = secs(state, state.pos, l)
        if STEPTRACE then io.stderr:write(string.format("      walk %4.0fs  %s -> %s %.1f,%.1f\n", d, state.pos and state.pos.zone or "?", l.zone, l.x, l.y)) end
        state.tTravel = (state.tTravel or 0) + d
        state.time = state.time + d
        state.pos = { zone = l.zone, x = l.x, y = l.y, map = l.map, area = l.area }
    end
    local function locFields(l) return { map = l.map, zone = Z.names[l.area] or Z.names[l.zone], x = l.x, y = l.y } end
    local function withLoc(step, l)
        if l then for k, v in pairs(locFields(l)) do step[k] = v end end
        return step
    end
    local function available(r)
        return eligible(state, r, zone) and logCount(state) < X.LOG_CAP and worthIt(state, r, cur())
    end
    local function accept(r, l)
        local s = qstate(state, r.id)
        s.accepted = true
        moveTo(l)
        state.time = state.time + X.TALK_TIME
        local h = hubOf(l) if h then currentHub = h end
        local step = { type = "ACCEPT", quest = r.id, questName = r.q.n }
        if l.kind == "npc" then step.npc = l.id step.npcName = l.name end
        withLoc(step, l)
        out(step)
    end
    local function turnIn(r, l)
        local s = qstate(state, r.id)
        s.turnedIn = true s.accepted = false
        moveTo(l)
        state.time = state.time + X.TALK_TIME
        local h = hubOf(l) if h then currentHub = h end
        local L = level(state)
        local mult = X.xpMultiplier(L, r.q.lvl)
        state.xp = state.xp + X.questReward(r.q) * mult
        local step = { type = "TURNIN", quest = r.id, questName = r.q.n }
        if mult < 1 then step.note = string.format("reduced xp (%d%%) - you out-levelled it", math.floor(mult * 100 + 0.5)) end
        if l.kind == "npc" then step.npc = l.id step.npcName = l.name end
        withLoc(step, l)
        out(step)
    end
    local function doObjective(r, i, l)
        local o = r.objs[i]
        moveTo(l)
        local L = level(state)
        local w, kxp = X.objectiveCost(o, L, r.escort)
        if STEPTRACE then io.stderr:write(string.format("      %s %s x%s: work %.0fs, %.0f kill xp  (%s)\n", o.kind, o.name, tostring(o.count or "?"), w, kxp, r.q.n)) end
        state.tWork = (state.tWork or 0) + w
        state.time = state.time + w
        state.xp = state.xp + kxp
        qstate(state, r.id).done[i] = true
        local step = { type = o.kind, quest = r.id, questName = r.q.n, target = o.name }
        if o.count then step.count = o.count end
        if l.kind == "npc" and o.kind == "KILL" then step.npc = l.id end
        if o.text then step.note = o.text end
        if r.escort then step.note = "escort - stay close, it can fail" .. (o.text and (": " .. o.text) or "") end
        if #o.locs > 1 then step.near = true end
        withLoc(step, l)
        local prev = steps[#steps]
        if prev and prev.quest == r.id and prev.type ~= "ACCEPT" and prev.type ~= "TURNIN" and prev.x and step.x
            and math.abs(prev.x - step.x) < 2 and math.abs(prev.y - step.y) < 2 then
            prev.target = prev.target .. " / " .. o.name
            if prev.type ~= step.type then prev.type = "COMPLETE" end
        else
            out(step)
        end
    end

    local function urgency(r) return math.min(X.marginOf(level(state), r.q.lvl), 8) * URGENCY end
    local guard, tour = 0, nil
    while guard < 4000 do
        guard = guard + 1
        local progressed = false
        -- 1. accept everything worth it at this hub (lowest level first)
        local list = {}
        for id, r in pairs(quests) do
            if available(r) then
                local l, d = nearest(state, cur(), r.starts)
                if l and d <= HUB_SEC then list[#list + 1] = { r = r, l = l, d = d } end
            end
        end
        table.sort(list, function(a, b)
            local la, lb = a.r.q.lvl or 0, b.r.q.lvl or 0
            if la ~= lb then return la < lb end
            if a.d ~= b.d then return a.d < b.d end
            return a.r.id < b.r.id
        end)
        for _, e in ipairs(list) do if available(e.r) then accept(e.r, e.l) progressed = true end end
        -- 2. hand in everything finished at this hub
        list = {}
        for id, r in pairs(quests) do
            local s = state.qs[id]
            if s and s.accepted and questDone(state, r) then
                local l, d = nearest(state, cur(), r.ends)
                if l and d <= HUB_SEC then list[#list + 1] = { r = r, l = l, d = d } end
            end
        end
        table.sort(list, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.r.id < b.r.id end)
        for _, e in ipairs(list) do turnIn(e.r, e.l) progressed = true end
        if progressed then tour = nil else
            -- 3. plan a tour through everything tied to this hub, or move to the best next hub
            local function taskValid(t)
                local s = state.qs[t.r.id]
                if t.kind == "obj" then return s and s.accepted and not objDone(state, t.r, t.i) end
                if t.kind == "turnin" then return s and s.accepted and questDone(state, t.r) end
                return available(t.r)
            end
            if not tour or #tour == 0 then
                local tasks = {}
                local function addObj(r, i, o, extra) tasks[#tasks + 1] = { kind = "obj", r = r, i = i, o = o, locs = o.locs, order = r.id * 10 + i, extra = extra } end
                local here = currentHub or hubOf(cur())
                currentHub = here
                local homeCount = 0
                for id, r in pairs(quests) do
                    local s = state.qs[id]
                    if s and s.accepted and not questDone(state, r) then
                        local endHub = hubOfLocs(r.ends, cur())
                        for i, o in ipairs(r.objs) do
                            if not objDone(state, r, i) and inZone(o.locs, zone) then
                                local l = nearest(state, cur(), o.locs)
                                local nearHub = here and l and hubDist(here, l) <= OBJ_NEAR
                                local farObj = here and l and hubDist(here, l) > OBJ_FAR
                                if l and ((here and endHub == here and not farObj) or nearHub) then addObj(r, i, o, urgency(r)) homeCount = homeCount + 1 end
                            end
                        end
                    elseif s and s.accepted and questDone(state, r) then
                        local l = nearest(state, cur(), r.ends)
                        if l and here and hubOf(l) == here then tasks[#tasks + 1] = { kind = "turnin", r = r, locs = r.ends, order = id, extra = urgency(r), home = true } homeCount = homeCount + 1 end
                    elseif available(r) then
                        local l = nearest(state, cur(), r.starts)
                        if l and here and hubOf(l) == here then tasks[#tasks + 1] = { kind = "accept", r = r, locs = r.starts, order = id, extra = 60 + urgency(r) } homeCount = homeCount + 1 end
                    end
                end
                -- objectives first, in one loop out of town; the hand-ins at this hub wait for the way back
                do
                    local objTasks = 0
                    for _, t in ipairs(tasks) do if t.kind == "obj" then objTasks = objTasks + 1 end end
                    if objTasks > 0 then
                        local kept = {}
                        for _, t in ipairs(tasks) do if not t.home then kept[#kept + 1] = t end end
                        tasks = kept
                    end
                end
                if homeCount == 0 then
                    -- nothing left here: what waits at the other hubs, and is it worth the walk?
                    local hubValue, turninAt = {}, {}
                    local function bump(h, v) if h then hubValue[h] = (hubValue[h] or 0) + v end end
                    local L = level(state)
                    for id, r in pairs(quests) do
                        local s = state.qs[id]
                        if s and s.accepted and questDone(state, r) then
                            local h = hubOfLocs(r.ends, cur())
                            bump(h, X.questReward(r.q) * X.xpMultiplier(L, r.q.lvl))
                            if h then turninAt[h] = true end
                        elseif s and s.accepted then
                            for i, o in ipairs(r.objs) do
                                if not objDone(state, r, i) and inZone(o.locs, zone) then
                                    local _, kxp = X.objectiveCost(o, L, r.escort)
                                    bump(hubOfLocs(o.locs, cur()), kxp + 0.5 * X.questReward(r.q) * X.xpMultiplier(L, r.q.lvl))
                                end
                            end
                        elseif available(r) then
                            local _, w, xp = packageValue(state, r, cur())
                            bump(hubOfLocs(r.starts, cur()), 0.6 * xp)
                        end
                    end
                    local list2 = {}
                    for h, v in pairs(hubValue) do if h ~= here and v > 0 then list2[#list2 + 1] = h end end
                    table.sort(list2, function(a, b) return a.id < b.id end)
                    local target
                    if #list2 > 0 then
                        -- open tour through the hubs (NN + 2-opt, seconds), a little pull towards hand-ins
                        local function hd(a, b) return yards(a, b) / X.speed(L) end
                        local order, remaining, c = {}, {}, { x = cur().x, y = cur().y, map = cur().map, zone = zone }
                        for _, h in ipairs(list2) do remaining[#remaining + 1] = h end
                        while #remaining > 0 do
                            local bi, bd
                            for i, h in ipairs(remaining) do
                                local d = hd(c, h) - (turninAt[h] and 20 or 0)
                                if not bd or d < bd then bi, bd = i, d end
                            end
                            local h = table.remove(remaining, bi)
                            order[#order + 1] = h
                            c = h
                        end
                        local function plen(lst)
                            local total, prev = 0, { x = cur().x, y = cur().y, map = cur().map, zone = zone }
                            for _, h in ipairs(lst) do total = total + hd(prev, h) prev = h end
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
                        -- prune: a hub whose detour is not paid for by what waits there is skipped
                        local pruned = true
                        while pruned and #order > 0 do
                            pruned = false
                            local base = plen(order)
                            for i = #order, 1, -1 do
                                local without = {}
                                for k, h in ipairs(order) do if k ~= i then without[#without + 1] = h end end
                                local detour = base - plen(without)
                                local h = order[i]
                                if detour > 0 and hubValue[h] / detour < X.VALUE_MIN * X.grindRate(L) and not turninAt[h] then
                                    table.remove(order, i)
                                    pruned = true
                                    break
                                end
                            end
                        end
                        target = order[1]
                    end
                    if TRACE then
                        io.stderr:write(string.format("    [%d] L%d at %.0f,%.0f here=%s -> %s (%d hubs)\n", #steps, level(state), cur().x, cur().y, here and here.id or "-", target and target.id or "-", #list2))
                    end
                    if target then
                        local straight = hubDist(target, cur())
                        local function onTheWay(locs)
                            local l = nearest(state, cur(), locs)
                            if not l then return false end
                            return secs(state, cur(), l) + hubDist(target, l) - straight <= DETOUR
                        end
                        for id, r in pairs(quests) do
                            local s = state.qs[id]
                            if s and s.accepted and not questDone(state, r) then
                                local endHub = hubOfLocs(r.ends, cur())
                                for i, o in ipairs(r.objs) do
                                    if not objDone(state, r, i) and inZone(o.locs, zone) and (endHub == target or onTheWay(o.locs) or hubOfLocs(o.locs, cur()) == target) then addObj(r, i, o, urgency(r)) end
                                end
                            elseif s and s.accepted and questDone(state, r) then
                                if hubOfLocs(r.ends, cur()) == target or onTheWay(r.ends) then tasks[#tasks + 1] = { kind = "turnin", r = r, locs = r.ends, order = id, extra = urgency(r) } end
                            elseif available(r) then
                                if hubOfLocs(r.starts, cur()) == target or onTheWay(r.starts) then tasks[#tasks + 1] = { kind = "accept", r = r, locs = r.starts, order = id, extra = 60 + urgency(r) } end
                            end
                        end
                        currentHub = target
                    else
                        -- objectives far from any hub: nearest one, re-plan after it
                        for id, r in pairs(quests) do
                            local s = state.qs[id]
                            if s and s.accepted and not questDone(state, r) then
                                for i, o in ipairs(r.objs) do if not objDone(state, r, i) and inZone(o.locs, zone) then addObj(r, i, o, urgency(r)) end end
                            elseif s and s.accepted and questDone(state, r) and inZone(r.ends, zone) then
                                tasks[#tasks + 1] = { kind = "turnin", r = r, locs = r.ends, order = id, extra = urgency(r) }
                            elseif available(r) then
                                tasks[#tasks + 1] = { kind = "accept", r = r, locs = r.starts, order = id, extra = 60 + urgency(r) }
                            end
                        end
                        if #tasks > 0 then
                            local bi, bd
                            for i, t in ipairs(tasks) do local _, d = nearest(state, cur(), t.locs) if d and (not bd or d + t.extra < bd) then bi, bd = i, d + t.extra end end
                            tasks = bi and { tasks[bi] } or {}
                        end
                    end
                end
                tour = {}
                if #tasks > 0 then
                    local remaining, c = {}, cur()
                    for _, t in ipairs(tasks) do remaining[#remaining + 1] = t end
                    while #remaining > 0 do
                        local bi, bc
                        for i, t in ipairs(remaining) do
                            local l, d = nearest(state, c, t.locs)
                            if l then
                                local cost = d + t.extra
                                if not bc or cost < bc or (cost == bc and t.order < remaining[bi].order) then bi, bc = i, cost end
                            end
                        end
                        if not bi then break end
                        local t = table.remove(remaining, bi)
                        t.l = nearest(state, c, t.locs)
                        c = t.l
                        tour[#tour + 1] = t
                    end
                    local function tdist(a, b) return secs(state, a and a.l or cur(), b.l) end
                    local function ordered(lst)
                        local placed = {}
                        for _, t in ipairs(lst) do
                            if t.kind == "turnin" then
                                for _, tt in ipairs(lst) do
                                    if tt.kind == "obj" and tt.r.id == t.r.id and not placed[tt] then return false end
                                end
                            end
                            placed[t] = true
                        end
                        return true
                    end
                    local function length(lst)
                        local total, prev, n = 0, nil, #lst
                        for i, t in ipairs(lst) do total = total + tdist(prev, t) + t.extra * (n - i + 1) / n prev = t end
                        return total
                    end
                    local improved, rounds = true, 0
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
                                if len < base - 0.01 and ordered(cand) then tour, base, improved = cand, len, true end
                            end
                        end
                    end
                end
            end
            local act
            while tour and #tour > 0 do
                local t = table.remove(tour, 1)
                if taskValid(t) then
                    local l = nearest(state, cur(), t.locs) or t.l
                    act = { t = t, l = l }
                    break
                end
            end
            if not act then break end
            local t = act.t
            if t.kind == "obj" then doObjective(t.r, t.i, act.l)
            elseif t.kind == "turnin" then turnIn(t.r, act.l)
            else accept(t.r, act.l) end
        end
    end
    return steps, state.xp - xp0, state.time - t0, L0
end

-- ---- grinding ---------------------------------------------------------------------------
--- Best grind spot near the position: non-elite mobs around the player's level with many spawns.
local function grindSpot(state, zone)
    local L = level(state)
    local best, bs
    for id, n in pairs(N) do
        if n.rank == 0 and n.sp and n.sp and (n.zone == zone or D.parentZone(n.zone or 0) == zone) and n.min and n.max then
            local mobL = (n.min + n.max) / 2
            if mobL >= L - 1 and mobL <= L + 1.5 then
                local locs = D.spawnLocs(n, {}, "npc", id)
                local count = 0
                for _, pts in pairs(n.sp) do count = count + (pts.n or #pts) end
                if #locs > 0 and count >= 8 then
                    local l, d = nearest(state, state.pos, locs)
                    local score = count * 10 - d
                    if not bs or score > bs then best, bs = { n = n, id = id, l = l }, score end
                end
            end
        end
    end
    return best
end

-- ---- the route ----------------------------------------------------------------------------
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepcopy(v) end
    return out
end
local function copyState(s)
    return { xp = s.xp, time = s.time, pos = s.pos and deepcopy(s.pos), qs = deepcopy(s.qs), hearth = s.hearth and deepcopy(s.hearth),
             hearthReady = s.hearthReady, visits = deepcopy(s.visits), faction = s.faction, mask = s.mask, travel = s.travel,
             tTravel = s.tTravel, tWork = s.tWork, tGrind = s.tGrind }
end

--- pending reward xp of quests done but not handed in (credited half to the chapter that did the work)
local function pendingReward(state)
    local L, total = level(state), 0
    for id, s in pairs(state.qs) do
        if s.accepted then
            local r = rec(id)
            if questDone(state, r) then total = total + X.questReward(r.q) * X.xpMultiplier(L, r.q.lvl) end
        end
    end
    return total
end

--- rough "is there anything for me there" check, cheaper than a trial
local function zonePromising(state, zd)
    local L = level(state)
    local n = 0
    for id in pairs(Q) do
        if questOK(id, state.mask) then
            local r = rec(id)
            local s = state.qs[id]
            if s and s.accepted and (inZone(r.ends, zd.id) or (function() for i, o in ipairs(r.objs) do if not objDone(state, r, i) and inZone(o.locs, zd.id) then return true end end return false end)()) then n = n + 2
            elseif eligible(state, r, zd.id) and X.xpMultiplier(L, r.q.lvl) > GREY_SKIP then n = n + 1 end
        end
    end
    return n
end

local function planRoute(startZone)
    local faction = startZone.faction
    local state = { xp = 0, time = 0, pos = nil, qs = {}, visits = {}, faction = faction,
                    mask = faction == "Alliance" and RACE_ALLIANCE or RACE_HORDE, travel = D.buildTravel(faction) }
    -- start at the lowest-level giver of the starting zone
    do
        local bestR
        for id in pairs(Q) do
            if questOK(id, state.mask) then
                local r = rec(id)
                if inZone(r.starts, startZone.id) and (not bestR or (r.q.req or 0) < (bestR.q.req or 0) or ((r.q.req or 0) == (bestR.q.req or 0) and r.id < bestR.id)) then bestR = r end
            end
        end
        for _, l in ipairs(bestR.starts) do if l.zone == startZone.id then state.pos = { zone = l.zone, x = l.x, y = l.y, map = l.map, area = l.area } break end end
    end
    local chapters = {}
    local zone = startZone.id
    local grinds = 0
    while level(state) < 60 and #chapters < MAX_CHAPTERS do
        local L = level(state)
        -- candidates: the current zone first (if we are in it), then every zone with something for us
        local cands = {}
        for _, zd in ipairs(D.ZONES) do
            if (not zd.faction or zd.faction == faction) and not (zd.races and zd.id ~= startZone.id) then
                local fits = (zd.city or (zd.min <= L + 4 and zd.max >= L - 2))
                if fits and zonePromising(state, zd) >= (zd.city and 1 or 3) then cands[#cands + 1] = zd end
            end
        end
        local best
        for _, zd in ipairs(cands) do
            local trial = copyState(state)
            local pend0 = pendingReward(trial)
            local steps, xpG, tSpent = runChapter(trial, zd.id)
            local pend1 = pendingReward(trial)
            local credit = xpG + 0.5 * (pend1 - pend0)
            local rate = tSpent > 0 and credit / tSpent or 0
            -- crossing the sea costs more than the model sees (waiting for ships, no hearth, no flight
            -- paths over there yet): a mild preference for the continent we are on
            if state.pos and D.continent(state.pos.zone) ~= D.continent(zd.id) then rate = rate * CROSS_SEA end
            if TRACE then io.stderr:write(string.format("  L%d cand %-22s xp %6.0f  %5.0fs  %.2f xp/s  (%d steps, travel %.0fs work %.0fs)\n", L, Z.names[zd.id] or zd.id, credit, tSpent, rate, #steps, (trial.tTravel or 0) - (state.tTravel or 0), (trial.tWork or 0) - (state.tWork or 0))) end
            local bigEnough = tSpent >= MIN_CHAPTER or zd.city or (state.pos and zd.id == state.pos.zone)
            if #steps > 2 and xpG > 0 and credit > 0 and bigEnough and (not best or rate > best.rate) then best = { zd = zd, trial = trial, steps = steps, rate = rate, xp = xpG, t = tSpent } end
        end
        local grindRate = X.grindRate(L)
        -- log nearly full of finished quests whose turn-in is nowhere we are going: abandon the cheapest
        do
            local stuck = {}
            local n = 0
            for id, s in pairs(state.qs) do
                if s.accepted then
                    n = n + 1
                    local r = rec(id)
                    if questDone(state, r) then
                        local reachable = false
                        for _, zd in ipairs(cands) do if inZone(r.ends, zd.id) then reachable = true end end
                        if not reachable then stuck[#stuck + 1] = { id = id, r = r, xp = X.questReward(r.q) * X.xpMultiplier(L, r.q.lvl) } end
                    end
                end
            end
            if n >= X.LOG_CAP - 4 and #stuck > 0 then
                table.sort(stuck, function(a, b) return a.xp < b.xp end)
                local drop = math.min(#stuck, n - (X.LOG_CAP - 8))
                for i = 1, drop do
                    local st = stuck[i]
                    state.qs[st.id].accepted = false
                    state.qs[st.id].abandoned = true
                    local ch = chapters[#chapters]
                    if ch then ch.steps[#ch.steps + 1] = { type = "NOTE", quest = st.id, questName = st.r.q.n,
                        text = string.format("abandon %s - its turn-in is far off the route and the quest log is full", st.r.q.n) } end
                    if TRACE then io.stderr:write(string.format("  L%d abandon q%d %s (%.0f xp, turn-in off the route)\n", L, st.id, st.r.q.n, st.xp)) end
                end
            end
        end
        if TRACE then
            local pend, n = 0, 0
            for id, s in pairs(state.qs) do if s.accepted then n = n + 1 local r = rec(id) if questDone(state, r) then pend = pend + 1 end end end
            io.stderr:write(string.format("  L%d log %d (%d finished, waiting for a turn-in) grind rate %.2f best %s %.2f\n", L, n, pend, grindRate, best and (Z.names[best.zd.id] or "?") or "-", best and best.rate or 0))
            if os.getenv("FG_LOG") then
                for id, s in pairs(state.qs) do
                    if s.accepted then
                        local r = rec(id)
                        local e = r.ends[1]
                        io.stderr:write(string.format("      log q%d L%d %s  ends in %s (%s)\n", id, r.q.lvl or 0, r.q.n, e and (Z.names[e.zone] or e.zone) or "?", questDone(state, r) and "finished" or "open"))
                    end
                end
            end
        end
        if not best or best.rate < GRIND_FACTOR * grindRate then
            -- grind a level where we stand, then look again
            grinds = grinds + 1
            if grinds > 30 then break end
            local spot = grindSpot(state, state.pos.zone) or (best and grindSpot(best.trial, best.zd.id))
            local need = X.xpToLevel(L + 1) - state.xp
            local step = { type = "GRIND", level = L + 1, note = string.format("nothing worth questing at level %d - grind to %d", L, L + 1) }
            if spot then
                step.target = spot.n.n
                step.npc = spot.id
                step.near = true
                step.note = string.format("grind %s (level %d-%d) to level %d - nothing worth questing at %d", spot.n.n, spot.n.min, spot.n.max, L + 1, L)
                for k, v in pairs({ map = spot.l.map, zone = Z.names[spot.l.area] or Z.names[spot.l.zone], x = spot.l.x, y = spot.l.y }) do step[k] = v end
                state.time = state.time + secs(state, state.pos, spot.l)
                state.pos = { zone = spot.l.zone, x = spot.l.x, y = spot.l.y, map = spot.l.map, area = spot.l.area }
            end
            state.time = state.time + need / grindRate
            state.tGrind = (state.tGrind or 0) + need / grindRate
            state.xp = X.xpToLevel(L + 1)
            local ch = chapters[#chapters]
            if ch and ch.zone == state.pos.zone then ch.steps[#ch.steps + 1] = step ch.endLevel = level(state) ch.time = ch.time + need / grindRate
            else chapters[#chapters + 1] = { zone = state.pos.zone, steps = { step }, startLevel = L, endLevel = L + 1, xp = need, time = need / grindRate, grindOnly = true } end
            if TRACE then io.stderr:write(string.format("GRIND L%d -> %d (%.0f s)%s\n", L, L + 1, need / grindRate, spot and (" on " .. spot.n.n) or "")) end
        else
            state = best.trial
            local prev = chapters[#chapters]
            if prev and prev.zone == best.zd.id then
                for _, st in ipairs(best.steps) do prev.steps[#prev.steps + 1] = st end
                prev.endLevel, prev.xp, prev.time = level(state), prev.xp + best.xp, prev.time + best.t
                prev.grindOnly = nil
            else
                chapters[#chapters + 1] = { zone = best.zd.id, steps = best.steps, startLevel = L, endLevel = level(state), xp = best.xp, time = best.t }
            end
            if TRACE then io.stderr:write(string.format("CHAPTER %-22s L%d -> %d  %6.0f xp in %5.0f s (%.0f xp/h)  %d steps  total %.1f h\n", Z.names[best.zd.id], L, level(state), best.xp, best.t, best.xp / best.t * 3600, #best.steps, state.time / 3600)) end
        end
    end
    return chapters, state
end

-- ---- JSON --------------------------------------------------------------------
local KEY_ORDER = { "type", "quest", "questName", "npc", "npcName", "target", "count", "class", "level", "map", "zone", "x", "y", "radius", "near", "note", "text", "optional" }
local function jsonString(s)
    s = tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
    return '"' .. s .. '"'
end
local function jsonValue(v)
    local t = type(v)
    if t == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.1f", v)
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "string" then return jsonString(v)
    elseif t == "table" then
        if #v > 0 then
            local parts = {}
            for _, x in ipairs(v) do parts[#parts + 1] = jsonValue(x) end
            return "[" .. table.concat(parts, ", ") .. "]"
        end
        local parts = {}
        for _, k in ipairs(KEY_ORDER) do if v[k] ~= nil then parts[#parts + 1] = jsonString(k) .. ": " .. jsonValue(v[k]) end end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return "null"
end

-- ---- main -----------------------------------------------------------------------
-- stale output from earlier runs
do
    local p = io.popen('ls "' .. root .. 'guides-src" 2>/dev/null')
    if p then
        for name in p:lines() do
            local mine = not onlyRace or name:upper():find("_" .. onlyRace:upper() .. "_", 1, true)
            if name:match("^GEN_") and mine then os.remove(root .. "guides-src/" .. name) end
        end
        p:close()
    end
end
local summary = {}
local runs = {}
for _, zd in ipairs(D.ZONES) do
    if zd.races and (not onlyRace or (function() for _, r in ipairs(zd.races) do if r:lower() == onlyRace:lower() then return true end end return false end)()) then
        if zd.faction then runs[#runs + 1] = { zd = zd, faction = zd.faction }
        else
            -- a neutral start (Skyborne): one route per faction
            for _, f in ipairs({ "Alliance", "Horde" }) do
                local copy = {}
                for k, v in pairs(zd) do copy[k] = v end
                copy.faction = f
                runs[#runs + 1] = { zd = copy, faction = f }
            end
        end
    end
end
for _, run in ipairs(runs) do
    local zd = run.zd
    do
        local key = zd.races[1]
        io.stderr:write(string.format("== %s route (%s) ==\n", key, zd.faction))
        local chapters, state = planRoute(zd)
        local prefix = "GEN_" .. zd.faction:upper() .. "_" .. key:upper()
        local ids = {}
        for i, ch in ipairs(chapters) do
            local zoneName = Z.names[ch.zone] or tostring(ch.zone)
            ids[i] = string.format("%s_%02d_%s", prefix, i, D.slug(zoneName))
        end
        local totalSteps = 0
        for i, ch in ipairs(chapters) do
            local zoneName = Z.names[ch.zone] or tostring(ch.zone)
            local guide = {
                id = ids[i],
                name = string.format("%d. %s %d-%d (%s)", i, zoneName, ch.startLevel, ch.endLevel, key == "Scourge" and "Undead" or (key == "NightElf" and "Night Elf" or key)),
                version = 2, faction = zd.faction, race = zd.races,
                minLevel = ch.startLevel, maxLevel = math.max(ch.endLevel, ch.startLevel),
                map = Z.areaToMap[ch.zone], zone = zoneName,
                author = "ForeverGuide route planner",
                notes = string.format("Chapter %d of the %s route: level %d to %d, %d steps, ~%d min of play in the model (%.0f xp/h). Route tuned for xp per hour: low-value quests, elites and long escorts are skipped on purpose.",
                    i, key, ch.startLevel, ch.endLevel, #ch.steps, math.floor(ch.time / 60 + 0.5), ch.time > 0 and ch.xp / ch.time * 3600 or 0),
                next = ids[i + 1],
            }
            local lines = { "{" }
            for _, k in ipairs({ "id", "name", "version", "faction", "race", "minLevel", "maxLevel", "map", "zone", "next", "author", "notes" }) do
                if guide[k] ~= nil then lines[#lines + 1] = "  " .. jsonString(k) .. ": " .. jsonValue(guide[k]) .. "," end
            end
            lines[#lines + 1] = '  "steps": ['
            for j, s in ipairs(ch.steps) do lines[#lines + 1] = "    " .. jsonValue(s) .. (j < #ch.steps and "," or "") end
            lines[#lines + 1] = "  ]"
            lines[#lines + 1] = "}"
            local f = assert(io.open(root .. "guides-src/" .. ids[i] .. ".json", "w"))
            f:write(table.concat(lines, "\n") .. "\n")
            f:close()
            totalSteps = totalSteps + #ch.steps
            print(string.format("%-48s L%2d-%2d %4d steps %5.0f min %6.0f xp/h", ids[i], ch.startLevel, ch.endLevel, #ch.steps, ch.time / 60, ch.time > 0 and ch.xp / ch.time * 3600 or 0))
        end
        summary[#summary + 1] = string.format("%-9s %-8s reaches level %2d in %5.1f h modelled play (%.1f h of it grinding, %.1f h walking; %d chapters, %d steps)", key, zd.faction, level(state), state.time / 3600, (state.tGrind or 0) / 3600, (state.tTravel or 0) / 3600, #chapters, totalSteps)
    end
end
-- ---- zone guides: one standalone chapter per zone and faction, for anyone who wants that zone ----
-- (the race routes above are the fast path; these are the "I am in Westfall, guide me here" fallbacks)
local zoneGuides = 0
for _, zd in ipairs(D.ZONES) do
    if not zd.city and not zd.races and (not onlyRace or onlyRace:lower() == "zones") then
        for _, faction in ipairs({ "Alliance", "Horde" }) do
            local state = { xp = X.xpToLevel(zd.min), time = 0, pos = nil, qs = {}, visits = {}, faction = faction,
                            mask = faction == "Alliance" and RACE_ALLIANCE or RACE_HORDE, travel = D.buildTravel(faction) }
            local steps, guard = {}, 0
            local startLevel = level(state)
            while guard < 12 do
                guard = guard + 1
                local part, xpG, tSpent = runChapter(state, zd.id)
                if #part == 0 or xpG <= 0 then break end
                for _, st in ipairs(part) do
                    if st.type ~= "TRAVEL" or #steps == 0 then steps[#steps + 1] = st end
                end
                if level(state) > zd.max + 2 then break end
                -- nothing left at this level: pretend the levels came from elsewhere and look again
                local L = level(state)
                if X.grindRate(L) > 0 then
                    local before = #steps
                    -- only continue while the zone still has something for the next level
                    local probe = copyState(state)
                    probe.xp = X.xpToLevel(L + 1)
                    local p2, xp2 = runChapter(probe, zd.id)
                    if #p2 == 0 or xp2 <= 0 then break end
                    state.xp = X.xpToLevel(L + 1)
                end
            end
            local turnins = 0
            for _, st in ipairs(steps) do if st.type == "TURNIN" then turnins = turnins + 1 end end
            if turnins >= 6 then
                local zoneName = Z.names[zd.id] or tostring(zd.id)
                local id = "GEN_ZONE_" .. faction:upper() .. "_" .. D.slug(zoneName)
                local guide = {
                    id = id, name = string.format("Zone: %s %d-%d (%s)", zoneName, zd.min, zd.max, faction), version = 2, faction = faction,
                    minLevel = zd.min, maxLevel = zd.max, map = Z.areaToMap[zd.id], zone = zoneName, author = "ForeverGuide route planner",
                    notes = string.format("Every quest worth doing in %s for a %s character, %d quests. The race routes are the faster path; pick this when you just want to quest here.", zoneName, faction, turnins),
                }
                local lines = { "{" }
                for _, k in ipairs({ "id", "name", "version", "faction", "minLevel", "maxLevel", "map", "zone", "author", "notes" }) do
                    if guide[k] ~= nil then lines[#lines + 1] = "  " .. jsonString(k) .. ": " .. jsonValue(guide[k]) .. "," end
                end
                lines[#lines + 1] = '  "steps": ['
                for j, st in ipairs(steps) do lines[#lines + 1] = "    " .. jsonValue(st) .. (j < #steps and "," or "") end
                lines[#lines + 1] = "  ]"
                lines[#lines + 1] = "}"
                local f = assert(io.open(root .. "guides-src/" .. id .. ".json", "w"))
                f:write(table.concat(lines, "\n") .. "\n")
                f:close()
                zoneGuides = zoneGuides + 1
                print(string.format("%-48s L%2d-%2d %4d steps  %d quests", id, zd.min, zd.max, #steps, turnins))
            end
        end
    end
end
if zoneGuides > 0 then summary[#summary + 1] = string.format("%d standalone zone guides", zoneGuides) end

print("")
for _, s in ipairs(summary) do print(s) end
