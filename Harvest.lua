-- ============================================================
-- ForeverGuide / Harvest.lua
-- Passive quest discovery. The server does not answer standalone
-- C_QuestLog.RequestLoadQuestByID calls on this beta (see Scanner.lua),
-- but the client still loads quest data through its normal channels.
-- This module collects it from three places:
--
--   1. Quest lines per map (C_QuestLine): what the world map uses to draw
--      available quests. Gives quest ID, title AND start position for
--      every zone map, without visiting it.       /fg harvest
--   2. NPC gossip windows: quest IDs + titles offered / turned in there,
--      with the NPC id and your position (recorder already logs the NPC).
--   3. A sweep of HaveQuestData over the id space: anything the client
--      cached while you played (map pins, quest givers, tooltips) is read
--      out with its title.                        /fg harvest sweep
--
-- Everything is stored next to the scanner's data so scan_diff.py sees it:
--   ForeverGuideDB.scan.quests[id] = title
--   ForeverGuideDB.harvest.lines[id] = { map, x, y, line, lineName, name }
--   ForeverGuideDB.harvest.maps[uiMapID] = { name, lines = n, at = time }
-- ============================================================

local _, ns = ...
local Harvest = ns:NewModule("Harvest")

local PlainNumber, PlainString, PlainBool = ns.PlainNumber, ns.PlainString, ns.PlainBool

local SWEEP_FROM, SWEEP_TO, SWEEP_CHUNK = 1, 120000, 3000
local CONTINENTS = { 1414, 1415, 947 }   -- Kalimdor, Eastern Kingdoms, Azeroth (Classic Era uiMapIDs)

Harvest.pendingMaps = {}       -- uiMapID -> true, waiting for QUESTLINE_UPDATE
Harvest.sweeping = nil

local function Store()
    ns.db.scan = type(ns.db.scan) == "table" and ns.db.scan or {}
    local s = ns.db.scan
    s.quests = type(s.quests) == "table" and s.quests or {}
    ns.db.harvest = type(ns.db.harvest) == "table" and ns.db.harvest or {}
    local h = ns.db.harvest
    h.lines = type(h.lines) == "table" and h.lines or {}
    h.maps = type(h.maps) == "table" and h.maps or {}
    return s, h
end

local function RecordQuest(id, title, source)
    if not id or id <= 0 then return false end
    local s = Store()
    local isNew = s.quests[id] == nil
    if title and title ~= "" then
        s.quests[id] = title
    elseif s.quests[id] == nil then
        s.quests[id] = ""
    end
    if isNew then ns.Debug("harvest", source, id, title) end
    return isNew
end

-- ------------------------------------------------------------
-- 1. Quest lines per map
-- ------------------------------------------------------------
function Harvest:ReadMap(mapID)
    local s, h = Store()
    local lines = ns.Call("C_QuestLine.GetAvailableQuestLines", mapID)
    if type(lines) ~= "table" then return 0, 0 end
    local n, new = 0, 0
    for _, q in ipairs(lines) do
        if type(q) == "table" then
            local questID = PlainNumber(q.questID)
            if questID then
                n = n + 1
                if RecordQuest(questID, PlainString(q.questName), "line") then new = new + 1 end
                local x, y = PlainNumber(q.x), PlainNumber(q.y)
                h.lines[questID] = {
                    map = PlainNumber(q.startMapID) or mapID,
                    x = x and ns.Round(x * 100, 2), y = y and ns.Round(y * 100, 2),
                    line = PlainNumber(q.questLineID), lineName = PlainString(q.questLineName),
                    name = PlainString(q.questName),
                    hidden = PlainBool(q.isHidden) or nil, start = PlainBool(q.isQuestStart) or nil,
                }
                -- the other quests of that line are ids too
                local ids = ns.Call("C_QuestLine.GetQuestLineQuests", PlainNumber(q.questLineID) or 0)
                if type(ids) == "table" then
                    for _, other in ipairs(ids) do
                        other = PlainNumber(other)
                        if other then
                            local title = PlainString(ns.Call("C_QuestLog.GetTitleForQuestID", other))
                            if RecordQuest(other, title, "linequest") then new = new + 1 end
                        end
                    end
                end
            end
        end
    end
    local info = ns.Call("C_Map.GetMapInfo", mapID)
    h.maps[mapID] = { name = type(info) == "table" and PlainString(info.name) or nil, lines = n,
                      at = PlainNumber(ns.Safe(GetServerTime)) or 0 }
    return n, new
end

function Harvest:RequestMap(mapID)
    self.pendingMaps[mapID] = true
    ns.Call("C_QuestLine.RequestQuestLinesForMap", mapID)
end

--- All zone-type maps under the classic continents (+ the current map).
function Harvest:AllZoneMaps()
    local seen, list = {}, {}
    local function add(id)
        if id and not seen[id] then seen[id] = true list[#list + 1] = id end
    end
    add(ns.Player:GetMapID())
    local zoneType = rawget(_G, "Enum") and Enum.UIMapType and Enum.UIMapType.Zone or 3
    for _, cont in ipairs(CONTINENTS) do
        local children = ns.Call("C_Map.GetMapChildrenInfo", cont, zoneType, true)
        if type(children) == "table" then
            for _, c in ipairs(children) do add(PlainNumber(c.mapID)) end
        end
        add(cont)
    end
    return list
end

function Harvest:HarvestAllMaps()
    local maps = self:AllZoneMaps()
    if #maps == 0 then ns.Warn("harvest: no maps found (C_Map.GetMapChildrenInfo returned nothing)") return end
    ns.Printf("harvest: requesting quest lines for %d maps...", #maps)
    local i = 0
    local totalLines, totalNew = 0, 0
    local function step()
        for _ = 1, 4 do
            i = i + 1
            local mapID = maps[i]
            if not mapID then
                -- give the last answers a moment, then read everything once more
                ns.Events:After(3, function()
                    for _, m in ipairs(maps) do
                        local n, new = Harvest:ReadMap(m)
                        totalLines, totalNew = totalLines + n, totalNew + new
                    end
                    local s = Store()
                    local total = 0
                    for _ in pairs(s.quests) do total = total + 1 end
                    ns.Printf("harvest: %d quest-line entries across %d maps, %d quests new; %d quests known in total. /reload to save, then tools/scan_diff.py.",
                        totalLines, #maps, totalNew, total)
                end)
                return
            end
            self:RequestMap(mapID)
        end
        ns.Events:After(0.5, step)
    end
    step()
end

-- ------------------------------------------------------------
-- 3. Cache sweep
-- ------------------------------------------------------------
function Harvest:Sweep(from, to)
    if self.sweeping then ns.Print("sweep already running") return end
    local have = rawget(_G, "HaveQuestData")
    if type(have) ~= "function" then ns.Warn("HaveQuestData is not available on this client") return end
    from, to = tonumber(from) or SWEEP_FROM, tonumber(to) or SWEEP_TO
    self.sweeping = { id = from, to = to, found = 0, new = 0 }
    ns.Printf("harvest: sweeping the client's quest cache for ids %d-%d...", from, to)
    local function step()
        local sw = self.sweeping
        if not sw then return end
        local last = math.min(sw.to, sw.id + SWEEP_CHUNK - 1)
        for id = sw.id, last do
            local ok, cached = pcall(have, id)
            if ok and cached == true then
                sw.found = sw.found + 1
                local title = PlainString(ns.Call("C_QuestLog.GetTitleForQuestID", id))
                if RecordQuest(id, title, "sweep") then sw.new = sw.new + 1 end
            end
        end
        sw.id = last + 1
        if sw.id > sw.to then
            ns.Printf("harvest: sweep done - %d quests in the client cache, %d of them new.", sw.found, sw.new)
            self.sweeping = nil
            return
        end
        ns.Events:After(0.05, step)
    end
    step()
end

-- ------------------------------------------------------------
-- Events
-- ------------------------------------------------------------
function Harvest:OnInit()
    -- 2. gossip windows: quests offered / active at this NPC
    ns.Events:Register("GOSSIP_SHOW", function()
        local new = 0
        for _, fn in ipairs({ "C_GossipInfo.GetAvailableQuests", "C_GossipInfo.GetActiveQuests" }) do
            local list = ns.Call(fn)
            if type(list) == "table" then
                for _, q in ipairs(list) do
                    if type(q) == "table" and RecordQuest(PlainNumber(q.questID), PlainString(q.title), "gossip") then new = new + 1 end
                end
            end
        end
        if new > 0 then ns.Debug("harvest: gossip added", new, "quests") end
    end)

    -- quest offer / turn-in windows
    ns.Events:RegisterMany({ "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE" }, function()
        local id = PlainNumber(ns.Safe(rawget(_G, "GetQuestID")))
        local title = PlainString(ns.Safe(rawget(_G, "GetTitleText")))
        RecordQuest(id, title, "questframe")
    end)

    -- any quest data the client loads for whatever reason
    ns.Events:Register("QUEST_DATA_LOAD_RESULT", function(_, questID, success)
        questID = PlainNumber(questID)
        if questID and PlainBool(success) then
            RecordQuest(questID, PlainString(ns.Call("C_QuestLog.GetTitleForQuestID", questID)), "load")
        end
    end)

    -- quest lines answered
    ns.Events:Register("QUESTLINE_UPDATE", function()
        for mapID in pairs(self.pendingMaps) do
            self:ReadMap(mapID)
        end
        self.pendingMaps = {}
    end)

    -- every zone you enter gets its quest lines requested once per session
    local requested = {}
    ns.Events:Register("FG_ZONE_CHANGED", function(_, mapID)
        if mapID and not requested[mapID] then
            requested[mapID] = true
            self:RequestMap(mapID)
        end
    end)

    -- quests in the log
    ns.Events:Register("FG_QUEST_LOG_CHANGED", function()
        for entry in ns.Quest:Iterate() do RecordQuest(entry.questID, entry.title, "log") end
    end)
end

function Harvest:OnEnterWorld()
    local mapID = ns.Player:GetMapID()
    if mapID then self:RequestMap(mapID) end
end

function Harvest:Status()
    local s, h = Store()
    local quests, lines, maps = 0, 0, 0
    for _ in pairs(s.quests) do quests = quests + 1 end
    for _ in pairs(h.lines) do lines = lines + 1 end
    for _ in pairs(h.maps) do maps = maps + 1 end
    ns.Printf("harvest: %d quests known, %d quest-line positions, %d maps read%s", quests, lines, maps,
        self.sweeping and string.format(" | sweep at id %d", self.sweeping.id) or "")
end
