-- ============================================================
-- ForeverGuide / tools/build_questdb.lua
-- Builds the addon's quest database from Questie's Classic Era data:
--
--   lua5.1 tools/build_questdb.lua <Questie folder> [<addon folder>]
--
-- Loads Questie's base tables (Database/Classic/*.lua), applies Questie's
-- own corrections (Database/Corrections/classic*Fixes.lua, the way
-- QuestieCorrections:Initialize does it), marks blacklisted quests, and
-- writes compact Lua tables:
--
--   Data/QuestDB.lua     ns.QuestDB   [questID]  = { ... }
--   Data/NpcDB.lua       ns.NpcDB     [npcID]    = { ... }   quest-relevant NPCs only
--   Data/ObjectDB.lua    ns.ObjectDB  [objectID] = { ... }   quest-relevant objects only
--   Data/ItemDB.lua      ns.ItemDB    [itemID]   = { ... }   quest-relevant items only
--   Data/ZoneDB.lua      ns.ZoneDB    areaID -> uiMapID (+ names)
--
-- Field reference: see Data/README.md (generated alongside).
-- Data (c) the Questie project, https://github.com/Questie/Questie - check
-- Questie's license before redistributing the generated files.
-- ============================================================

local questieRoot = arg[1]
local addonRoot = arg[2] or "."
if not questieRoot then
    print("usage: lua5.1 tools/build_questdb.lua <Questie folder> [<addon folder>]")
    os.exit(1)
end
questieRoot = questieRoot:gsub("[/\\]$", "")
addonRoot = addonRoot:gsub("[/\\]$", "")

local MAX_SPAWNS_PER_ZONE = 12

-- ------------------------------------------------------------
-- A permissive fake Questie environment
-- ------------------------------------------------------------
local autoviv
local autovivMeta = {
    __index = function(t, k)
        local v = autoviv()
        rawset(t, k, v)
        return v
    end,
    __call = function() return autoviv() end,
    __add = function(a, b) return (tonumber(a) or 0) + (tonumber(b) or 0) end,
    __concat = function(a, b) return tostring(a) .. tostring(b) end,
    __tostring = function() return "" end,
}
function autoviv() return setmetatable({}, autovivMeta) end

local modules = {}
QuestieLoader = {
    CreateModule = function(_, name)
        modules[name] = modules[name] or { private = {} }
        return modules[name]
    end,
    ImportModule = function(_, name)
        modules[name] = modules[name] or { private = {} }
        return modules[name]
    end,
}
Questie = {
    IsClassic = true, IsEra = true, IsTBC = false, IsWotlk = false, IsCata = false, IsMoP = false, IsSoD = false,
    IsHardcore = false, IsAnniversaryEra = false, IsAnniversaryHardcore = false,
    ICON_TYPE_SLAY = 1, ICON_TYPE_LOOT = 2, ICON_TYPE_EVENT = 3, ICON_TYPE_OBJECT = 4, ICON_TYPE_TALK = 5,
    ICON_TYPE_INTERACT = 6, ICON_TYPE_NODE_FISH = 7, ICON_TYPE_NODE = 8, ICON_TYPE_MOUNT = 9, ICON_TYPE_PET = 10,
    ICON_TYPE_COMPLETE = 11, ICON_TYPE_AVAILABLE = 12, ICON_TYPE_REPEATABLE = 13, ICON_TYPE_ITEM = 14,
    ICON_TYPE_NODE_HERB = 15, ICON_TYPE_NODE_ORE = 16, ICON_TYPE_SOD_LOOT = 17, ICON_TYPE_TALK_SOD = 18,
    DEBUG_DEVELOP = 1,
    Debug = function() end, Warning = function() end, Error = function() end,
    db = { global = {}, profile = {} },
}
setmetatable(Questie, { __index = function(_, k) if k:match("^ICON_TYPE_") then return 99 end return nil end })
bit = bit or {
    band = function(a, b)
        local r, m = 0, 1
        while a > 0 and b > 0 do
            if a % 2 == 1 and b % 2 == 1 then r = r + m end
            a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
        end
        return r
    end,
}
setmetatable(_G, { __index = function(_, k) local v = autoviv() rawset(_G, k, v) return v end })

local Expansions = QuestieLoader:ImportModule("Expansions")
Expansions.Classic, Expansions.Tbc, Expansions.Wotlk, Expansions.Cata, Expansions.MoP = 1, 2, 3, 4, 5
Expansions.Current = 1

-- profession / specialization / phasing keys: any name -> a stable number
local function keyTable()
    local n = 0
    return setmetatable({}, { __index = function(t, k) n = n + 1 rawset(t, k, n) return n end })
end
local QuestieProfessions = QuestieLoader:ImportModule("QuestieProfessions")
QuestieProfessions.professionKeys = keyTable()
QuestieProfessions.specializationKeys = keyTable()
local Phasing = QuestieLoader:ImportModule("Phasing")
Phasing.phases = keyTable()
local l10n = QuestieLoader:ImportModule("l10n")
setmetatable(l10n, { __call = function(_, s) return s end })
local ContentPhases = QuestieLoader:ImportModule("ContentPhases")
ContentPhases.activePhases = { Era = 6 }

local function run(path)
    local chunk, err = loadfile(path)
    if not chunk then error("cannot load " .. path .. ": " .. tostring(err)) end
    local ok, e = pcall(chunk)
    if not ok then error("error running " .. path .. ": " .. tostring(e)) end
end

local D = questieRoot .. "/Database/"
run(D .. "Zones/data/zoneIds.lua")
run(D .. "QuestieDB.lua")
local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
run(questieRoot .. "/Modules/QuestieProfessions.lua")
run(questieRoot .. "/Localization/lookups/lookupQuestCategories.lua")
-- QuestieDB.sortKeys: QuestSort names in UPPER_CASE -> negative sort id; city names fall back to their areaID
do
    local lookup = modules["l10n"].questCategoryLookup or {}
    local keys = {}
    for id, name in pairs(lookup) do
        keys[name:upper():gsub("[%s'%-]", "_")] = id
    end
    QuestieDB.sortKeys = setmetatable(keys, { __index = function(_, k) return modules["ZoneDB"].zoneIDs[k] end })
end
-- the generated Classic files carry an older copy of the key tables; the
-- current key tables (questDB.lua etc.) must be loaded after them
run(D .. "Classic/classicQuestDB.lua")
run(D .. "Classic/classicNpcDB.lua")
run(D .. "Classic/classicObjectDB.lua")
run(D .. "Classic/classicItemDB.lua")
run(D .. "questDB.lua")
run(D .. "npcDB.lua")
run(D .. "objectDB.lua")
-- real quest reward xp (QuestXP.db[questId] = { level, xp }), optional
local QuestXP = QuestieLoader:ImportModule("QuestXP")
pcall(run, D .. "QuestXP/DB/xpDB-classic.lua")
run(D .. "itemDB.lua")
run(D .. "Zones/data/areaIdToUiMapId.lua")
run(D .. "Zones/data/subZoneToParentZone.lua")

local function loadTable(str)
    if type(str) == "table" then return str end
    local chunk = assert(loadstring(str))
    return chunk()
end
QuestieDB.questData = loadTable(QuestieDB.questData)
QuestieDB.npcData = loadTable(QuestieDB.npcData)
QuestieDB.objectData = loadTable(QuestieDB.objectData)
QuestieDB.itemData = loadTable(QuestieDB.itemData)
local ZoneDB = QuestieLoader:ImportModule("ZoneDB")
local areaToMap = loadTable(ZoneDB.private.areaIdToUiMapId)
for k, v in pairs(loadTable(ZoneDB.private.areaIdToUiMapIdOverride)) do areaToMap[k] = v end
local subToParent = loadTable(ZoneDB.private.subZoneToParentZone)
for k, v in pairs(loadTable(ZoneDB.private.subZoneToParentZoneOverride)) do subToParent[k] = v end

local qk, nk, ok_, ik = QuestieDB.questKeys, QuestieDB.npcKeys, QuestieDB.objectKeys, QuestieDB.itemKeys

-- ------------------------------------------------------------
-- Corrections (same order as QuestieCorrections:Initialize for Classic)
-- ------------------------------------------------------------
local QuestieCorrections = QuestieLoader:ImportModule("QuestieCorrections")
QuestieCorrections.killCreditObjectiveFirst = {}
QuestieCorrections.objectObjectiveFirst = {}
QuestieCorrections.itemObjectiveFirst = {}
QuestieCorrections.eventObjectiveFirst = {}
QuestieCorrections.spellObjectiveFirst = {}

run(D .. "Corrections/classicQuestFixes.lua")
run(D .. "Corrections/classicNPCFixes.lua")
run(D .. "Corrections/classicObjectFixes.lua")
run(D .. "Corrections/classicItemFixes.lua")
run(D .. "Corrections/Automatic/itemStartFixes.lua")
run(D .. "Corrections/QuestieQuestBlacklist.lua")

local function applyCorrections(tableName, corrections, noOverwrites, noNewEntries)
    local data = QuestieDB[tableName]
    local n = 0
    for id, fields in pairs(corrections or {}) do
        if type(fields) == "table" then
            for key, value in pairs(fields) do
                if not data[id] and not noNewEntries then data[id] = {} end
                if data[id] then
                    if noOverwrites then
                        if data[id][key] == nil then data[id][key] = value end
                    else
                        data[id][key] = value
                    end
                    n = n + 1
                end
            end
        end
    end
    return n
end

local QuestieQuestFixes = modules["QuestieQuestFixes"]
if QuestieQuestFixes.LoadMissingQuests then QuestieQuestFixes:LoadMissingQuests() end
print("quest corrections:  " .. applyCorrections("questData", QuestieQuestFixes:Load()))
print("npc corrections:    " .. applyCorrections("npcData", modules["QuestieNPCFixes"]:Load()))
print("item corrections:   " .. applyCorrections("itemData", modules["QuestieItemFixes"]:Load()))
print("object corrections: " .. applyCorrections("objectData", modules["QuestieObjectFixes"]:Load()))
print("item start fixes:   " .. applyCorrections("itemData", modules["QuestieItemStartFixes"]:LoadAutomaticQuestStarts(), true, true))

-- faction guess for quests without requiredRaces (as Questie does)
for _, quest in pairs(QuestieDB.questData) do
    if not quest[qk.requiredRaces] or quest[qk.requiredRaces] == 0 then
        local starts = quest[qk.startedBy] and quest[qk.startedBy][1]
        if starts then
            local a, h = false, false
            for _, id in pairs(starts) do
                local npc = QuestieDB.npcData[id]
                local f = npc and npc[nk.friendlyToFaction]
                if f == "A" then a = true elseif f == "H" then h = true elseif f == "AH" then a, h = true, true end
            end
            if a ~= h then quest[qk.requiredRaces] = a and 77 or 178 end
        end
    end
end

local hidden = {}
local okBL, blacklist = pcall(function() return modules["QuestieQuestBlacklist"]:Load() end)
if okBL and type(blacklist) == "table" then
    for id, v in pairs(blacklist) do if v then hidden[id] = true end end
end
print("blacklisted quests: " .. (function() local c = 0 for _ in pairs(hidden) do c = c + 1 end return c end)())

-- ------------------------------------------------------------
-- Build the ForeverGuide tables
-- ------------------------------------------------------------
local usedNpc, usedObj, usedItem = {}, {}, {}
local function mark(set, list)
    if type(list) ~= "table" then return end
    for _, v in pairs(list) do
        local id = type(v) == "table" and v[1] or v
        if type(id) == "number" then set[id] = true end
    end
end

local quests = {}
for id, q in pairs(QuestieDB.questData) do
    if type(id) == "number" and q[qk.name] then
        local starts, ends = q[qk.startedBy] or {}, q[qk.finishedBy] or {}
        local objs = q[qk.objectives] or {}
        local out = {
            n = q[qk.name],
            lvl = q[qk.questLevel], req = q[qk.requiredLevel], maxlvl = q[qk.requiredMaxLevel],
            races = q[qk.requiredRaces], classes = q[qk.requiredClasses],
            zone = q[qk.zoneOrSort],
            text = q[qk.objectivesText],
            snpc = starts[1], sobj = starts[2], sitem = starts[3],
            enpc = ends[1], eobj = ends[2],
            kill = objs[1], obj = objs[2], item = objs[3], rep = objs[4], credit = objs[5], spell = objs[6],
            trig = q[qk.triggerEnd],
            srcitem = q[qk.sourceItemId], reqitems = q[qk.requiredSourceItems],
            pre = q[qk.preQuestSingle], pregroup = q[qk.preQuestGroup],
            next = q[qk.nextQuestInChain], excl = q[qk.exclusiveTo], parent = q[qk.parentQuest], children = q[qk.childQuests],
            group = q[qk.inGroupWith], skill = q[qk.requiredSkill], spellreq = q[qk.requiredSpell],
            flags = q[qk.questFlags], special = q[qk.specialFlags],
            breadcrumb = q[qk.breadcrumbForQuestId], breadcrumbs = q[qk.breadcrumbs],
            hidden = hidden[id] or nil,
            xp = QuestXP.db and QuestXP.db[id] and QuestXP.db[id][2] or nil,
        }
        quests[id] = out
        mark(usedNpc, out.snpc) mark(usedNpc, out.enpc) mark(usedNpc, out.kill)
        if out.credit and out.credit[1] then mark(usedNpc, out.credit[1]) end
        mark(usedObj, out.sobj) mark(usedObj, out.eobj) mark(usedObj, out.obj)
        mark(usedItem, out.sitem) mark(usedItem, out.item) mark(usedItem, out.reqitems)
        if out.srcitem then usedItem[out.srcitem] = true end
    end
end

-- items first: their drop sources are relevant NPCs / objects too
local items = {}
for id, it in pairs(QuestieDB.itemData) do
    if type(id) == "number" and (usedItem[id] or it[ik.startQuest]) and it[ik.name] then
        items[id] = { n = it[ik.name], npc = it[ik.npcDrops], obj = it[ik.objectDrops], startq = it[ik.startQuest],
                      vendors = it[ik.vendors], quests = it[ik.relatedQuests] }
        mark(usedNpc, it[ik.npcDrops]) mark(usedObj, it[ik.objectDrops])
        if it[ik.startQuest] and quests[it[ik.startQuest]] then usedItem[id] = true end
    end
end

local function trimSpawns(spawns)
    if type(spawns) ~= "table" then return nil end
    local out, any = {}, false
    for zone, list in pairs(spawns) do
        if type(list) == "table" and #list > 0 then
            local pts = {}
            for _, p in ipairs(list) do
                if type(p) == "table" and type(p[1]) == "number" and p[1] >= 0 and p[2] and p[2] >= 0 then
                    pts[#pts + 1] = { math.floor(p[1] * 10 + 0.5) / 10, math.floor(p[2] * 10 + 0.5) / 10 }
                end
            end
            if #pts > 0 then
                if #pts > MAX_SPAWNS_PER_ZONE then
                    -- keep an even spread, remember how many there were
                    local keep, step = {}, #pts / MAX_SPAWNS_PER_ZONE
                    for i = 1, MAX_SPAWNS_PER_ZONE do keep[i] = pts[math.floor((i - 1) * step) + 1] end
                    keep.n = #pts
                    pts = keep
                end
                out[zone] = pts
                any = true
            end
        end
    end
    return any and out or nil
end

local npcs = {}
for id, npc in pairs(QuestieDB.npcData) do
    if type(id) == "number" and usedNpc[id] and npc[nk.name] then
        npcs[id] = { n = npc[nk.name], min = npc[nk.minLevel], max = npc[nk.maxLevel], rank = npc[nk.rank],
                     zone = npc[nk.zoneID], sp = trimSpawns(npc[nk.spawns]), f = npc[nk.friendlyToFaction],
                     sub = npc[nk.subName], starts = npc[nk.questStarts], ends = npc[nk.questEnds] }
    end
end

local objects = {}
for id, obj in pairs(QuestieDB.objectData) do
    if type(id) == "number" and usedObj[id] and obj[ok_.name] then
        objects[id] = { n = obj[ok_.name], zone = obj[ok_.zoneID], sp = trimSpawns(obj[ok_.spawns]),
                        starts = obj[ok_.questStarts], ends = obj[ok_.questEnds] }
    end
end

-- zone names from the comments in areaIdToUiMapId.lua
local zoneNames = {}
for line in io.lines(D .. "Zones/data/areaIdToUiMapId.lua") do
    local area, map, name = line:match("%[(%d+)%]%s*=%s*(%d+),%s*%-%-%s*(.-)%s*$")
    if area then zoneNames[tonumber(area)] = name end
end

-- ------------------------------------------------------------
-- Serialise
-- ------------------------------------------------------------
local function ser(v, out)
    local t = type(v)
    if t == "number" then
        if v == math.floor(v) then out[#out + 1] = string.format("%d", v) else out[#out + 1] = string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", "") end
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v):gsub("\\\n", "\\n")
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif t == "table" then
        out[#out + 1] = "{"
        local n = #v
        for i = 1, n do
            if v[i] == nil then out[#out + 1] = "nil" else ser(v[i], out) end
            out[#out + 1] = ","
        end
        local keys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then keys[#keys + 1] = k end
        end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then return a < b end
            return type(a) == "number"
        end)
        for _, k in ipairs(keys) do
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                out[#out + 1] = k .. "="
            else
                out[#out + 1] = "["
                ser(k, out)
                out[#out + 1] = "]="
            end
            ser(v[k], out)
            out[#out + 1] = ","
        end
        if out[#out] == "," then out[#out] = nil end
        out[#out + 1] = "}"
    else
        out[#out + 1] = "nil"
    end
end

-- arrays in Questie data may contain nil holes ({nil, nil, {{182}}}); keep positions
local function serEntry(v)
    local out = {}
    ser(v, out)
    return table.concat(out)
end

local function writeTable(file, global, tbl, header)
    local ids = {}
    for id in pairs(tbl) do ids[#ids + 1] = id end
    table.sort(ids)
    local f = assert(io.open(addonRoot .. "/Data/" .. file, "w"))
    f:write("-- AUTO-GENERATED by tools/build_questdb.lua from Questie's Classic Era database - DO NOT EDIT\n")
    f:write("-- " .. header .. "\n")
    f:write("-- Data derived from Questie (https://github.com/Questie/Questie); see Data/README.md.\n")
    f:write("local _, ns = ...\n")
    f:write("ns." .. global .. " = {\n")
    for _, id in ipairs(ids) do
        f:write("[" .. id .. "]=" .. serEntry(tbl[id]) .. ",\n")
    end
    f:write("}\n")
    f:close()
    return #ids
end

os.execute('mkdir -p "' .. addonRoot .. '/Data"')
local nq = writeTable("QuestDB.lua", "QuestDB", quests, "quests (name, levels, races/classes, givers, enders, objectives, chain)")
local nn = writeTable("NpcDB.lua", "NpcDB", npcs, "quest-relevant NPCs (name, level, spawns per areaID)")
local no = writeTable("ObjectDB.lua", "ObjectDB", objects, "quest-relevant game objects (name, spawns per areaID)")
local ni = writeTable("ItemDB.lua", "ItemDB", items, "quest-relevant items (name, drop sources, quest starts)")

local zf = assert(io.open(addonRoot .. "/Data/ZoneDB.lua", "w"))
zf:write("-- AUTO-GENERATED by tools/build_questdb.lua from Questie's Zones/data - DO NOT EDIT\n")
zf:write("-- Questie areaID -> uiMapID (Classic Era ids; confirmed to match WoW Forever 1.60.1) and zone names.\n")
zf:write("local _, ns = ...\nns.ZoneDB = { areaToMap = {\n")
local areas = {}
for a in pairs(areaToMap) do areas[#areas + 1] = a end
table.sort(areas)
for _, a in ipairs(areas) do zf:write(string.format("[%d]=%d,\n", a, areaToMap[a])) end
zf:write("}, names = {\n")
for _, a in ipairs(areas) do
    if zoneNames[a] then zf:write(string.format("[%d]=%q,\n", a, zoneNames[a])) end
end
zf:write("}, parent = {\n")
local subs = {}
for a in pairs(subToParent) do subs[#subs + 1] = a end
table.sort(subs)
for _, a in ipairs(subs) do zf:write(string.format("[%d]=%d,\n", a, subToParent[a])) end
zf:write("} }\n")
zf:close()

print(string.format("wrote %d quests, %d npcs, %d objects, %d items, %d zones to %s/Data/", nq, nn, no, ni, #areas, addonRoot))
