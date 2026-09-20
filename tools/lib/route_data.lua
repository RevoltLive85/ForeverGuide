-- ============================================================
-- ForeverGuide / tools/lib/route_data.lua
-- Shared data for the route planner: the bundled database, zone
-- definitions, map sizes in yards, the zone travel graph and the
-- per-quest location tables.
-- ============================================================
local M = {}

function M.load(root)
    local ns = {}
    local function loadData(file)
        local chunk = assert(loadfile(root .. "Data/" .. file))
        chunk("ForeverGuide", ns)
    end
    loadData("ZoneDB.lua") loadData("QuestDB.lua") loadData("NpcDB.lua") loadData("ObjectDB.lua") loadData("ItemDB.lua")
    local Q, N, O, I, Z = ns.QuestDB, ns.NpcDB, ns.ObjectDB, ns.ItemDB, ns.ZoneDB
    local f = io.open(root .. "Data/ForeverQuestIDs.lua", "r")
    local gone = 0
    if f then
        f:close()
        loadData("ForeverQuestIDs.lua")
        for id, q in pairs(Q) do
            if not ns.ForeverQuestIDs[id] then q.removed = true gone = gone + 1 end
        end
    end
    M.Q, M.N, M.O, M.I, M.Z, M.removed = Q, N, O, I, Z, gone
    M.applyOverlay(root, ns)
    return M
end

-- ---- WoW Forever overlay (Data/ForeverDB.lua) ----------------------------------------
-- New quests / npcs recorded in-game or cross-referenced from other sources get
-- synthetic areaIDs for maps the vanilla tables do not know (100000 + uiMapID).
function M.mapToArea(map)
    local Z = M.Z
    if not M._mapToArea then
        M._mapToArea = {}
        for area, mp in pairs(Z.areaToMap) do
            if not Z.parent[area] then M._mapToArea[mp] = area end
        end
    end
    local area = M._mapToArea[map]
    if not area then
        area = 100000 + map
        Z.areaToMap[area] = map
        M._mapToArea[map] = area
    end
    return area
end
local function spmToSp(spm)
    local sp = {}
    for mp, pts in pairs(spm or {}) do
        local area = M.mapToArea(tonumber(mp) or mp)
        sp[area] = sp[area] or {}
        for _, p in ipairs(pts) do sp[area][#sp[area] + 1] = { p[1], p[2] } end
    end
    return sp
end
function M.applyOverlay(root, ns)
    local f = io.open(root .. "Data/ForeverDB.lua", "r")
    if not f then return end
    f:close()
    local chunk = assert(loadfile(root .. "Data/ForeverDB.lua"))
    chunk("ForeverGuide", ns)
    local F = ns.ForeverDB
    if not F then return end
    local Q, N, Z = M.Q, M.N, M.Z
    for mp, info in pairs(F.maps or {}) do
        local area = M.mapToArea(tonumber(mp) or mp)
        if info.name and not Z.names[area] then Z.names[area] = info.name end
    end
    for id, n in pairs(F.npcs or {}) do
        if not N[id] then
            N[id] = { n = n.n, min = n.lvl, max = n.lvl, rank = 0, sp = spmToSp(n.spm), forever = true }
        elseif n.spm and not N[id].sp then
            N[id].sp = spmToSp(n.spm)
        end
    end
    local added = 0
    -- level guess for new quests without one: median level of the quests on the same map
    local lvlByMap = {}
    for id, fq in pairs(F.quests or {}) do
        local mp = fq.start and fq.start.spm and next(fq.start.spm)
        if not mp and fq.snpc then
            local n = F.npcs and F.npcs[fq.snpc[1]]
            mp = n and n.spm and next(n.spm)
        end
        if mp and fq.lvl then lvlByMap[mp] = lvlByMap[mp] or {} table.insert(lvlByMap[mp], fq.lvl) end
    end
    local median = {}
    for mp, list in pairs(lvlByMap) do table.sort(list) median[mp] = list[math.ceil(#list / 2)] end
    for id, fq in pairs(F.quests or {}) do
        local q = Q[id]
        if not q then
            q = { n = fq.n, forever = true, snpc = fq.snpc, enpc = fq.enpc, races = 0 }
            Q[id] = q
            added = added + 1
        end
        if fq.lvl then q.lvl = q.lvl or fq.lvl end
        if q.forever then
            if fq.classes then q.classes = fq.classes end
            if fq.pre and not q.pre then q.pre = fq.pre end
        end
        if fq.start then q.fstart = fq.start end
        if fq.fin then q.ffin = fq.fin end
        if fq.obj and not (q.kill or q.item or q.obj or q.credit or q.trig) then q.fobj = fq.obj end
        if q.forever then
            local mp = fq.start and fq.start.spm and next(fq.start.spm)
            if not mp and q.snpc and N[q.snpc[1]] and N[q.snpc[1]].sp then
                local area = next(N[q.snpc[1]].sp)
                mp = area and Z.areaToMap[area]
            end
            q.lvl = q.lvl or (mp and median[tostring(mp)]) or (mp and median[mp]) or 1
            q.req = q.req or math.max(1, q.lvl - 2)
            q.zone = mp and M.mapToArea(tonumber(mp) or mp) or 0
            if fq.snpc == nil and fq.start == nil then q.hidden = true end     -- no giver known: cannot be routed
        end
    end
    M.overlayAdded = added
end

-- ---- zones -------------------------------------------------------------------
-- Questie areaIDs. min/max are the level band the zone is *meant* for (only a
-- hint for the planner: what gets done is decided by the xp model).
-- races: starting zones. capital: city of the faction on that continent.
M.ZONES = {
    -- Alliance starting zones
    { id = 12,   min = 1,  max = 10, races = { "Human" },          faction = "Alliance", capital = 1519 },
    { id = 1,    min = 1,  max = 10, races = { "Dwarf", "Gnome" }, faction = "Alliance", capital = 1537 },
    { id = 141,  min = 1,  max = 10, races = { "NightElf" },       faction = "Alliance", capital = 1657 },
    -- Horde starting zones
    { id = 14,   min = 1,  max = 10, races = { "Orc", "Troll" },   faction = "Horde", capital = 1637 },
    { id = 215,  min = 1,  max = 10, races = { "Tauren" },         faction = "Horde", capital = 1638 },
    { id = 85,   min = 1,  max = 10, races = { "Scourge" },        faction = "Horde", capital = 1497 },
    -- WoW Forever: Skyborne start on Zephras Isle (uiMap 2521; both factions)
    { id = 102521, min = 1, max = 14, races = { "Skyborne" } },
    -- capitals
    { id = 1519, min = 1, max = 60, faction = "Alliance", city = true },   -- Stormwind
    { id = 1537, min = 1, max = 60, faction = "Alliance", city = true },   -- Ironforge
    { id = 1657, min = 1, max = 60, faction = "Alliance", city = true },   -- Darnassus
    { id = 1637, min = 1, max = 60, faction = "Horde", city = true },      -- Orgrimmar
    { id = 1638, min = 1, max = 60, faction = "Horde", city = true },      -- Thunder Bluff
    { id = 1497, min = 1, max = 60, faction = "Horde", city = true },      -- Undercity
    -- 10-20
    { id = 40,   min = 10, max = 20 },   -- Westfall
    { id = 38,   min = 10, max = 20 },   -- Loch Modan
    { id = 148,  min = 10, max = 20 },   -- Darkshore
    { id = 17,   min = 10, max = 25 },   -- Barrens
    { id = 130,  min = 10, max = 20 },   -- Silverpine
    -- 15-30
    { id = 44,   min = 15, max = 25 },   -- Redridge
    { id = 10,   min = 18, max = 30 },   -- Duskwood
    { id = 11,   min = 20, max = 30 },   -- Wetlands
    { id = 331,  min = 18, max = 30 },   -- Ashenvale
    { id = 406,  min = 15, max = 27 },   -- Stonetalon
    { id = 267,  min = 20, max = 30 },   -- Hillsbrad
    { id = 400,  min = 25, max = 35 },   -- Thousand Needles
    { id = 36,   min = 27, max = 39 },   -- Alterac
    -- 30-45
    { id = 45,   min = 30, max = 40 },   -- Arathi
    { id = 405,  min = 30, max = 40 },   -- Desolace
    { id = 33,   min = 30, max = 45 },   -- Stranglethorn
    { id = 15,   min = 35, max = 45 },   -- Dustwallow
    { id = 3,    min = 35, max = 45 },   -- Badlands
    { id = 8,    min = 35, max = 45 },   -- Swamp of Sorrows
    -- 40-50
    { id = 47,   min = 40, max = 50 },   -- Hinterlands
    { id = 440,  min = 40, max = 50 },   -- Tanaris
    { id = 357,  min = 40, max = 50 },   -- Feralas
    { id = 51,   min = 43, max = 50 },   -- Searing Gorge
    -- 45-55
    { id = 4,    min = 45, max = 55 },   -- Blasted Lands
    { id = 490,  min = 48, max = 55 },   -- Un'Goro
    { id = 16,   min = 45, max = 55 },   -- Azshara
    { id = 361,  min = 48, max = 55 },   -- Felwood
    -- 50-60
    { id = 46,   min = 50, max = 58 },   -- Burning Steppes
    { id = 28,   min = 51, max = 58 },   -- Western Plaguelands
    { id = 139,  min = 53, max = 60 },   -- Eastern Plaguelands
    { id = 618,  min = 53, max = 60 },   -- Winterspring
    { id = 1377, min = 55, max = 60 },   -- Silithus
}
M.zoneByID = {}
for _, zd in ipairs(M.ZONES) do M.zoneByID[zd.id] = zd end

-- ---- map sizes (uiMapID -> width, height in yards; Classic WorldMapArea data) ----
M.MAP_SIZE = {
    [1411] = { 5287.5, 3525 }, [1412] = { 5137.5, 3425 }, [1413] = { 10133.3, 6756.2 }, [1440] = { 5766.7, 3843.7 },
    [1441] = { 4400, 2933.3 }, [1442] = { 4883.3, 3256.2 }, [1443] = { 4495.8, 2997.9 }, [1444] = { 6950, 4633.3 },
    [1445] = { 5250, 3500 }, [1446] = { 6900, 4600 }, [1447] = { 5070.8, 3381.2 }, [1448] = { 5750, 3833.3 },
    [1449] = { 3700, 2466.7 }, [1450] = { 2308.3, 1539.6 }, [1451] = { 3483.3, 2322.9 }, [1452] = { 7100, 4733.3 },
    [1438] = { 5091.7, 3393.7 }, [1439] = { 6550, 4366.7 }, [1454] = { 1402.6, 935.4 }, [1456] = { 1043.7, 695.8 },
    [1457] = { 1058.3, 705.6 },
    [1416] = { 2800, 1866.7 }, [1417] = { 3600, 2400 }, [1418] = { 2487.5, 1658.3 }, [1419] = { 3487.5, 2325 },
    [1420] = { 4518.7, 3012.5 }, [1421] = { 4200, 2800 }, [1422] = { 4300, 2866.7 }, [1423] = { 4031.2, 2687.5 },
    [1424] = { 3200, 2133.3 }, [1425] = { 3850, 2566.7 }, [1426] = { 4925, 3283.3 }, [1427] = { 2231.2, 1487.5 },
    [1428] = { 2929.2, 1952.1 }, [1429] = { 3470.8, 2314.6 }, [1430] = { 2500, 1666.7 }, [1431] = { 2700, 1800 },
    [1432] = { 2758.3, 1839.6 }, [1433] = { 2170.8, 1447.9 }, [1434] = { 6381.2, 4254.2 }, [1435] = { 2293.7, 1529.2 },
    [1436] = { 3500, 2333.3 }, [1437] = { 4135.4, 2756.2 }, [1453] = { 1737.5, 1158.3 }, [1455] = { 790.6, 527.6 },
    [1458] = { 959.4, 640.6 },
    [2521] = { 3500, 2333.3 },   -- Zephras Isle (Forever): size unknown, assumed Westfall-like
}
-- optional override recorded in-game (tools/merge_recorded.py writes data-src/mapsizes.json)
function M.loadMapSizes(root)
    local f = io.open(root .. "data-src/mapsizes.json", "r")
    if not f then return end
    local s = f:read("*a") f:close()
    for id, w, h in s:gmatch('"(%d+)"%s*:%s*%[%s*([%d%.]+)%s*,%s*([%d%.]+)%s*%]') do
        M.MAP_SIZE[tonumber(id)] = { tonumber(w), tonumber(h) }
    end
end

-- ---- travel graph between zones (seconds on foot between the main hubs) ----------
-- A Alliance-only, H Horde-only (boats / zeppelins), else both.
M.EDGES = {
    -- Eastern Kingdoms
    { 12, 1519, 80 }, { 12, 40, 150 }, { 12, 44, 240 }, { 12, 10, 240 }, { 12, 1, 400 },    -- Elwynn (Deeprun tram counts as a walk)
    { 1519, 1537, 120, "A" },                                                                  -- Deeprun tram
    { 40, 10, 200 }, { 10, 33, 200 }, { 10, 44, 200 }, { 10, 8, 320 }, { 44, 46, 240 },
    { 1, 1537, 80 }, { 1, 38, 180 }, { 38, 11, 240 }, { 38, 3, 220 }, { 3, 51, 180 }, { 51, 46, 150 },
    { 11, 45, 260 }, { 45, 267, 220 }, { 45, 47, 240 }, { 267, 130, 220 }, { 267, 36, 120 }, { 267, 28, 220 },
    { 130, 85, 200 }, { 85, 1497, 80 }, { 28, 139, 220 }, { 8, 4, 220 }, { 33, 8, 500 }, { 47, 28, 400 },
    -- Kalimdor
    { 141, 1657, 80 }, { 141, 148, 240, "A" }, { 148, 331, 240 }, { 331, 406, 240 }, { 331, 17, 240 }, { 331, 361, 240 },
    { 331, 16, 260 }, { 361, 618, 320 }, { 361, 493, 160 }, { 14, 1637, 80 }, { 14, 17, 200 }, { 215, 1638, 80 }, { 215, 17, 240 },
    { 17, 406, 240 }, { 17, 400, 220 }, { 17, 15, 220 }, { 406, 405, 240 }, { 400, 357, 260 }, { 400, 440, 240 },
    { 357, 405, 320 }, { 440, 490, 220 }, { 490, 1377, 220 }, { 357, 1377, 320 }, { 405, 357, 320 },
    -- boats / zeppelins
    { 11, 148, 420, "A" }, { 11, 15, 420, "A" }, { 33, 17, 360 }, { 85, 14, 300, "H" }, { 85, 33, 300, "H" }, { 1657, 148, 300, "A" },
    -- Zephras Isle (Forever): RestedXP sends Alliance on to Darkshore and Horde to the Barrens
    { 102521, 148, 300, "A" }, { 102521, 17, 300, "H" },
}
function M.buildTravel(faction)
    local adj = {}
    local function add(a, b, s) adj[a] = adj[a] or {} adj[a][b] = math.min(adj[a][b] or 1e9, s) end
    for _, e in ipairs(M.EDGES) do
        local a, b, s, f = e[1], e[2], e[3], e[4]
        if not f or (f == "A" and faction == "Alliance") or (f == "H" and faction == "Horde") then add(a, b, s) add(b, a, s) end
    end
    local cache = {}
    return function(a, b)
        if a == b then return 0 end
        local key = a .. ":" .. b
        if cache[key] then return cache[key] end
        -- Dijkstra (small graph)
        local dist, done = { [a] = 0 }, {}
        while true do
            local u, ud
            for k, d in pairs(dist) do if not done[k] and (not ud or d < ud) then u, ud = k, d end end
            if not u then break end
            done[u] = true
            if u == b then break end
            for v, s in pairs(adj[u] or {}) do
                if not dist[v] or ud + s < dist[v] then dist[v] = ud + s end
            end
        end
        local d = dist[b] or 1800
        cache[key] = d
        return d
    end
end

-- ---- helpers ------------------------------------------------------------------
function M.parentZone(area)
    local Z = M.Z
    local guard = 0
    while Z.parent[area] and guard < 8 do area = Z.parent[area] guard = guard + 1 end
    return area
end

function M.slug(name)
    return (name:upper():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

function M.band(a, b)
    local r, m = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + m end
        a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
    end
    return r
end

function M.spawnLocs(rec, out, kind, id)
    if not rec or not rec.sp then return out end
    for area, pts in pairs(rec.sp) do
        local zone = M.parentZone(area)
        for _, p in ipairs(pts) do
            out[#out + 1] = { zone = zone, area = area, map = M.Z.areaToMap[area], x = p[1], y = p[2], name = rec.n, kind = kind, id = id }
        end
    end
    return out
end

local function posLocs(pos, out, kind, name)
    if not pos or not pos.spm then return out end
    for mp, pts in pairs(pos.spm) do
        local map = tonumber(mp) or mp
        local area = M.mapToArea(map)
        for _, p in ipairs(pts) do
            out[#out + 1] = { zone = M.parentZone(area), area = area, map = map, x = p[1], y = p[2], name = pos.n or name, kind = kind }
        end
    end
    return out
end

function M.questStarts(q)
    local out = {}
    for _, id in ipairs(q.snpc or {}) do M.spawnLocs(M.N[id], out, "npc", id) end
    for _, id in ipairs(q.sobj or {}) do M.spawnLocs(M.O[id], out, "object", id) end
    if #out == 0 and q.fstart then posLocs(q.fstart, out, "start", q.n) end
    return out
end

function M.questEnds(q)
    local out = {}
    for _, id in ipairs(q.enpc or {}) do M.spawnLocs(M.N[id], out, "npc", id) end
    for _, id in ipairs(q.eobj or {}) do M.spawnLocs(M.O[id], out, "object", id) end
    if #out == 0 and q.ffin then posLocs(q.ffin, out, "end", q.n) end
    return out
end

function M.itemLocs(itemID, out)
    local it = M.I[itemID]
    if not it then return out end
    for _, id in ipairs(it.npc or {}) do M.spawnLocs(M.N[id], out, "npc", id) end
    for _, id in ipairs(it.obj or {}) do M.spawnLocs(M.O[id], out, "object", id) end
    return out
end

local function isElite(n) return n and (n.rank == 1 or n.rank == 2 or n.rank == 3) or false end

--- The number in the objective text that belongs to this objective ("Kill 10 Kobold
--- Vermin", "Bring 8 Boar Meat"), else nil.
local function countIn(texts, name)
    if not name then return nil end
    local first = name:match("^(%S+)") or name
    first = first:gsub("%p", "")
    for _, t in ipairs(texts or {}) do
        -- "<verb> N <name...>" with up to two words between the number and the name
        for num, rest in t:gmatch("(%d+)%s+([^%.,;]+)") do
            local r = rest:gsub("%p", "")
            if r:lower():find(first:lower(), 1, true) then return tonumber(num) end
        end
    end
    return nil
end

--- Objectives with their locations, mob levels, elite flags and counts.
function M.questObjectives(q)
    local N, O, I = M.N, M.O, M.I
    local out = {}
    local texts = q.text
    local function mobInfo(n)
        if not n then return nil end
        local lo, hi = n.min or n.max or q.lvl or 1, n.max or n.min or q.lvl or 1
        return { min = lo, max = hi, elite = isElite(n), rare = n.rank == 4 }
    end
    for _, e in ipairs(q.kill or {}) do
        local n = N[e[1]]
        local name = n and n.n or ("npc " .. e[1])
        out[#out + 1] = { kind = "KILL", name = name, text = e[2], locs = M.spawnLocs(n, {}, "npc", e[1]),
            elite = isElite(n), mob = mobInfo(n), count = countIn(texts, name) or ((n and n.sp and #(M.spawnLocs(n, {}, "npc", e[1])) <= 1) and 1 or nil) }
    end
    for _, e in ipairs(q.obj or {}) do
        local o = O[e[1]]
        local name = o and o.n or ("object " .. e[1])
        out[#out + 1] = { kind = "COMPLETE", name = name, text = e[2], locs = M.spawnLocs(o, {}, "object", e[1]), count = countIn(texts, name) }
    end
    for _, e in ipairs(q.item or {}) do
        local it = I[e[1]]
        local itemName = it and it.n or ("item " .. e[1])
        if it and it.npc and #it.npc == 1 and (not it.obj or #it.obj == 0) and N[it.npc[1]] then
            local nn = N[it.npc[1]]
            out[#out + 1] = { kind = "KILL", name = nn.n, text = "loot " .. itemName, locs = M.spawnLocs(nn, {}, "npc", it.npc[1]),
                elite = isElite(nn), mob = mobInfo(nn), drop = true, count = countIn(texts, itemName) }
        else
            local locs = M.itemLocs(e[1], {})
            local fromMobs = it and it.npc and #it.npc > 0
            local lo, hi
            for _, id in ipairs(it and it.npc or {}) do
                local n = N[id]
                if n then lo, hi = math.min(lo or 99, n.min or 99), math.max(hi or 0, n.max or 0) end
            end
            out[#out + 1] = { kind = "COLLECT", name = itemName, text = e[2], locs = locs, count = countIn(texts, itemName),
                drop = fromMobs, mob = fromMobs and { min = lo or q.lvl or 1, max = hi or q.lvl or 1 } or nil }
        end
    end
    if q.credit and q.credit[1] then
        local locs = {}
        local lo, hi, elite = nil, nil, false
        for _, id in ipairs(q.credit[1]) do
            M.spawnLocs(N[id], locs, "npc", id)
            local n = N[id]
            if n then lo, hi = math.min(lo or 99, n.min or 99), math.max(hi or 0, n.max or 0) elite = elite or isElite(n) end
        end
        local name = q.credit[3] or (N[q.credit[2]] and N[q.credit[2]].n) or "targets"
        out[#out + 1] = { kind = "KILL", name = name, locs = locs, elite = elite, mob = { min = lo or q.lvl or 1, max = hi or q.lvl or 1 }, count = countIn(texts, name) }
    end
    if q.fobj and #out == 0 then
        for _, fo in ipairs(q.fobj) do
            local n = fo.id and N[fo.id]
            local locs = {}
            if n and n.sp then M.spawnLocs(n, locs, "npc", fo.id) end
            if #locs == 0 and fo.spm then posLocs({ spm = fo.spm, n = fo.name }, locs, fo.kind == "kill" and "npc" or "object", fo.name) end
            local mobL = n and n.min or q.lvl or 1
            local mob = { min = mobL, max = n and n.max or mobL }
            if fo.kind == "kill" then
                out[#out + 1] = { kind = "KILL", name = fo.name or fo.text, text = fo.text, locs = locs, mob = mob, count = fo.count, forever = true }
            elseif fo.kind == "item" then
                out[#out + 1] = { kind = "KILL", name = fo.name or fo.text, text = "loot " .. (fo.text or "items"), locs = locs, mob = mob, drop = true, count = fo.count, forever = true }
            elseif fo.kind == "object" then
                out[#out + 1] = { kind = "COLLECT", name = fo.name or fo.text, text = fo.text, locs = locs, count = fo.count, forever = true }
            else
                out[#out + 1] = { kind = "COMPLETE", name = fo.name or fo.text or "objective", text = fo.text, locs = locs, count = fo.count, forever = true }
            end
        end
    end
    if q.trig and q.trig[2] then
        local locs = {}
        for area, pts in pairs(q.trig[2]) do
            for _, p in ipairs(pts) do
                locs[#locs + 1] = { zone = M.parentZone(area), area = area, map = M.Z.areaToMap[area], x = p[1], y = p[2], name = q.trig[1] }
            end
        end
        out[#out + 1] = { kind = "COMPLETE", name = q.trig[1], text = q.trig[1], locs = locs, trigger = true }
    end
    return out
end

--- Is this an escort quest? (long, slow, often fails - the model charges it)
function M.isEscort(q)
    for _, t in ipairs(q.text or {}) do if t:lower():find("escort", 1, true) then return true end end
    if q.trig and q.trig[1] and tostring(q.trig[1]):lower():find("escort", 1, true) then return true end
    return false
end

return M
