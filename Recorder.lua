-- ============================================================
-- ForeverGuide / Recorder.lua  (Phase 10 "debug mode", lite)
-- Quietly records the facts a guide database needs while you play:
--   quest accepted / turned in / abandoned  -> quest ID, title, NPC, map, coords, level
--   quest offered / turn-in window          -> which NPC gives / ends which quest
--   objective progress                      -> where objectives are completed and on what
--   gossip windows                          -> NPC id/name + quests available there
--   zone/map changes                        -> uiMapID <-> zone name table
-- Everything goes to ForeverGuideDB.recorder (account-wide SavedVariables):
--   WTF\Account\<acct>\SavedVariables\ForeverGuide.lua
-- Nothing is sent anywhere. /fg rec off disables it.
-- ============================================================

local _, ns = ...
local Recorder = ns:NewModule("Recorder")

local PlainNumber, PlainString = ns.PlainNumber, ns.PlainString

local lastTarget = nil     -- last hostile target snapshot (for kill locations)

local function Enabled()
    return ns.db and ns.db.recorder and ns.db.recorder.enabled
end

local function Location()
    local mapID, x, y = ns.Player:GetMapPosition()
    local zone, sub = ns.Player:GetZone()
    return mapID, x and ns.Round(x, 2), y and ns.Round(y, 2), zone, sub
end

function Recorder:Add(kind, fields)
    if not Enabled() then return end
    local rec = ns.db.recorder
    local mapID, x, y, zone, sub = Location()
    local e = fields or {}
    e.e = kind
    e.t = PlainNumber(ns.Safe(GetServerTime)) or 0
    e.lvl = ns.Player:GetLevel()
    e.m, e.x, e.y = mapID, x, y
    e.zone, e.sub = zone, sub
    rec.entries[#rec.entries + 1] = e
    local max = rec.maxEntries or 4000
    while #rec.entries > max do table.remove(rec.entries, 1) end
    ns.Debug("rec", kind, e.q or "", e.npc or "", e.n or e.npcName or "", mapID or "?", x or "?", y or "?")
end

function Recorder:NoteMap()
    if not Enabled() then return end
    local mapID = ns.Player:GetMapID()
    if not mapID then return end
    local name, mapType, parent = ns.Player:GetMapName(mapID)
    local zone = ns.Player:GetZone()
    ns.db.recorder.maps[mapID] = { name = name, zone = zone, type = mapType, parent = parent }
end

local function NPCFields(unitInfo)
    if not unitInfo then return {} end
    return { npc = unitInfo.npcID, npcName = unitInfo.name, npcLevel = unitInfo.level }
end

function Recorder:OnInit()
    local E = ns.Events

    E:Register("FG_QUEST_ACCEPTED", function(_, questID, title)
        local f = NPCFields(ns.Player:GetInteractionNPC())
        f.q, f.n = questID, title
        Recorder:Add("ACCEPT", f)
    end)

    E:Register("FG_QUEST_TURNED_IN", function(_, questID, title, xp, money)
        local f = NPCFields(ns.Player:GetInteractionNPC())
        f.q, f.n, f.xp, f.money = questID, title, xp, money
        Recorder:Add("TURNIN", f)
    end)

    E:Register("FG_QUEST_ABANDONED", function(_, questID, title)
        Recorder:Add("ABANDON", { q = questID, n = title })
    end)

    -- quest offer window: this NPC starts that quest
    E:Register("QUEST_DETAIL", function()
        local questID = PlainNumber(ns.Safe(rawget(_G, "GetQuestID")))
        local title = PlainString(ns.Safe(rawget(_G, "GetTitleText")))
        local f = NPCFields(ns.Player:GetInteractionNPC())
        f.q, f.n = questID, title
        Recorder:Add("OFFER", f)
    end)

    -- turn-in window: this NPC ends that quest
    E:RegisterMany({ "QUEST_PROGRESS", "QUEST_COMPLETE" }, function(event)
        local questID = PlainNumber(ns.Safe(rawget(_G, "GetQuestID")))
        local title = PlainString(ns.Safe(rawget(_G, "GetTitleText")))
        local f = NPCFields(ns.Player:GetInteractionNPC())
        f.q, f.n = questID, title
        Recorder:Add(event == "QUEST_COMPLETE" and "ENDNPC" or "PROGRESS", f)
    end)

    E:Register("GOSSIP_SHOW", function()
        local f = NPCFields(ns.Player:GetInteractionNPC())
        local avail, active = {}, {}
        local a = ns.Call("C_GossipInfo.GetAvailableQuests")
        if type(a) == "table" then
            for _, q in ipairs(a) do avail[#avail + 1] = PlainNumber(q.questID) end
        end
        local b = ns.Call("C_GossipInfo.GetActiveQuests")
        if type(b) == "table" then
            for _, q in ipairs(b) do active[#active + 1] = PlainNumber(q.questID) end
        end
        if #avail > 0 then f.avail = avail end
        if #active > 0 then f.active = active end
        Recorder:Add("GOSSIP", f)
    end)

    E:Register("MERCHANT_SHOW", function()
        Recorder:Add("VENDOR", NPCFields(ns.Player:GetInteractionNPC()))
    end)
    E:Register("TRAINER_SHOW", function()
        Recorder:Add("TRAINER", NPCFields(ns.Player:GetInteractionNPC()))
    end)

    E:Register("FG_TARGET_CHANGED", function(_, info)
        if info and not info.isPlayer and info.reaction == "hostile" then lastTarget = info end
    end)

    E:Register("FG_OBJECTIVE_PROGRESS", function(_, questID, idx, fulfilled, required, finished, text)
        local f = { q = questID, obj = idx, f = fulfilled, r = required, done = finished, txt = text }
        if lastTarget and ns.Now() - (lastTarget.seen or 0) < 60 then
            f.npc, f.npcName = lastTarget.npcID, lastTarget.name
        end
        Recorder:Add("OBJ", f)
    end)
    E:Register("PLAYER_TARGET_CHANGED", function()
        if lastTarget then lastTarget.seen = ns.Now() end
    end)

    E:Register("FG_LEVEL_CHANGED", function(_, level)
        Recorder:Add("LEVEL", { l = level })
    end)

    E:Register("FG_ZONE_CHANGED", function()
        Recorder:NoteMap()
    end)
end

function Recorder:OnEnterWorld()
    self:NoteMap()
end

function Recorder:Count()
    return ns.db and #ns.db.recorder.entries or 0
end

function Recorder:Clear()
    if ns.db then ns.db.recorder.entries = {} end
end

--- Print the last n entries to chat.
function Recorder:Dump(n)
    local entries = ns.db.recorder.entries
    n = math.min(n or 10, #entries)
    for i = #entries - n + 1, #entries do
        local e = entries[i]
        ns.Printf("%s %s q=%s npc=%s %s @ map %s (%s, %s) lvl %s %s",
            e.e, e.n or e.txt or "", tostring(e.q or "-"), tostring(e.npc or "-"), e.npcName or "",
            tostring(e.m or "?"), tostring(e.x or "?"), tostring(e.y or "?"), tostring(e.lvl), e.zone or "")
    end
    ns.Printf("%d entries recorded in total.", #entries)
end
