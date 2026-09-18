-- Minimal mock of the WoW API surface ForeverGuide touches, so the engine
-- can be exercised outside the game with plain Lua 5.1:
--     lua5.1 tools/test/run_tests.lua
-- Only what the addon calls is implemented. Game state lives in `world`.

local world = {
    level = 1, faction = "Alliance", class = { "Warrior", "WARRIOR", 1 }, race = { "Human", "Human" },
    mapID = 1429, mapName = "Elwynn Forest", zone = "Northshire Valley", subzone = "",
    mapX = 0.48, mapY = 0.43, worldX = 0, worldY = 0, instance = 0, facing = 0,
    log = {},          -- questID -> { title, level, objectives = { {text, finished, numFulfilled, numRequired} } }
    logOrder = {},
    completed = {},    -- questID -> true
    items = {},        -- itemID -> count
    spells = {},       -- spellID -> true
    target = nil,
    npc = nil,
    bind = "Northshire Abbey",
    time = 0,
}
_G.MOCK = world

-- ---- frames / widgets -------------------------------------------------
local frames = {}
local function NewRegion(kind)
    local r = { kind = kind, points = {}, shown = true, scripts = {}, events = {}, text = "" }
    function r:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function r:ClearAllPoints() self.points = {} end
    function r:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
    function r:SetSize(w, h) self.w, self.h = w, h end
    function r:SetWidth(w) self.w = w end
    function r:SetHeight(h) self.h = h end
    function r:GetWidth() return self.w or 0 end
    function r:GetHeight() return self.h or 0 end
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false end
    function r:IsShown() return self.shown end
    function r:SetShown(v) self.shown = v end
    function r:SetScale() end
    function r:SetFrameStrata() end
    function r:SetMovable() end
    function r:SetClampedToScreen() end
    function r:EnableMouse() end
    function r:RegisterForDrag() end
    function r:StartMoving() end
    function r:StopMovingOrSizing() end
    function r:SetBackdrop() end
    function r:SetBackdropColor() end
    function r:SetBackdropBorderColor() end
    function r:SetScript(name, fn) self.scripts[name] = fn end
    function r:GetScript(name) return self.scripts[name] end
    function r:RegisterEvent(ev) self.events[ev] = true end
    function r:UnregisterEvent(ev) self.events[ev] = nil end
    function r:SetText(t) self.text = t or "" end
    function r:GetText() return self.text end
    function r:SetFont() end
    function r:SetJustifyH() end
    function r:SetJustifyV() end
    function r:SetTextColor() end
    function r:SetWordWrap() end
    function r:SetNonSpaceWrap() end
    function r:GetStringHeight() return 14 end
    function r:SetTexture() end
    function r:SetColorTexture() end
    function r:SetRotation(a) self.rotation = a end
    function r:SetVertexColor(...) self.vertex = { ... } end
    function r:SetAlpha(a) self.alpha = a end
    function r:SetEnabled(e) self.enabled = e end
    function r:SetMaxLines(n) self.maxLines = n end
    function r:SetTexCoord() end
    function r:SetFrameLevel() end
    function r:RegisterForClicks() end
    function r:SetBlendMode() end
    function r:GetCenter() return 0, 0 end
    function r:GetEffectiveScale() return 1 end
    function r:SetAllPoints() end
    function r:SetNormalFontObject() end
    function r:SetHighlightFontObject() end
    function r:SetNormalTexture() end
    function r:SetHighlightTexture() end
    function r:CreateTexture() return NewRegion("Texture") end
    function r:CreateFontString() return NewRegion("FontString") end
    return r
end

function _G.CreateFrame(kind, name, parent, template)
    local f = NewRegion(kind)
    f.name, f.template = name, template
    if name then _G[name] = f end
    frames[#frames + 1] = f
    return f
end
_G.UIParent = NewRegion("Frame")
_G.Minimap = NewRegion("Frame"); _G.Minimap.w = 140
function _G.Minimap:GetCenter() return 500, 500 end
function _G.Minimap:GetEffectiveScale() return 1 end
_G.GetCursorPosition = function() return 600, 500 end
_G.GameTooltip = NewRegion("GameTooltip")
function _G.GameTooltip:SetOwner() end
function _G.GameTooltip:AddLine() end
_G.IsShiftKeyDown = function() return world.shift == true end
_G.GetNumQuestChoices = function() return world.questChoices or 0 end
_G.IsQuestCompletable = function() return true end
_G.QuestGetAutoAccept = function() return false end
_G.AcceptQuest = function() world.acceptedViaFrame = world.offeredQuest end
_G.CompleteQuest = function() world.completedViaFrame = world.offeredQuest end
_G.GetQuestReward = function(choice) world.rewardTaken = choice end
_G.GetNumActiveQuests = function() return 0 end
_G.GetNumAvailableQuests = function() return 0 end
_G.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
_G.SlashCmdList = {}
_G.strsplit = function(sep, s)
    local out = {}
    for piece in string.gmatch(s .. sep, "(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = piece end
    return unpack(out)
end
_G.CreateVector2D = function(x, y)
    return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
end

-- ---- timers -------------------------------------------------------------
local timers = {}
_G.C_Timer = {
    After = function(delay, fn) timers[#timers + 1] = { at = world.time + delay, fn = fn } end,
}
function _G.MOCK_ADVANCE(seconds)
    world.time = world.time + (seconds or 1)
    local due = {}
    for i = #timers, 1, -1 do
        if timers[i].at <= world.time then due[#due + 1] = table.remove(timers, i) end
    end
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do t.fn() end
end
_G.GetTime = function() return world.time end
_G.GetServerTime = function() return 1700000000 + world.time end
_G.GetBuildInfo = function() return "1.60.1", "69913", "Sep 17 2026", 16001 end

-- ---- player -------------------------------------------------------------
_G.UnitLevel = function(unit) if unit == "player" then return world.level end return world.target and world.target.level end
_G.UnitXP = function() return 100 end
_G.UnitXPMax = function() return 400 end
_G.GetXPExhaustion = function() return 0 end
_G.UnitFactionGroup = function() return world.faction, world.faction end
_G.UnitClass = function() return unpack(world.class) end
_G.UnitRace = function() return unpack(world.race) end
_G.UnitName = function(unit)
    if unit == "player" then return "Tester" end
    local u = unit == "npc" and world.npc or world.target
    return u and u.name
end
_G.UnitExists = function(unit)
    if unit == "player" then return true end
    if unit == "npc" then return world.npc ~= nil end
    if unit == "target" then return world.target ~= nil end
    return false
end
_G.UnitGUID = function(unit)
    if unit == "player" then return "Player-1-000001" end
    local u = unit == "npc" and world.npc or world.target
    return u and ("Creature-0-1-1-1-" .. u.npcID .. "-0000000001")
end
_G.UnitIsPlayer = function() return false end
_G.UnitIsDead = function() return false end
_G.UnitReaction = function(_, unit)
    local u = unit == "npc" and world.npc or world.target
    return u and (u.hostile and 2 or 5)
end
_G.UnitCreatureType = function() return "Humanoid", 7 end
_G.UnitPosition = function() return world.worldX, world.worldY, 0, world.instance end
_G.GetPlayerFacing = function() return world.facing end
_G.GetZoneText = function() return world.zone end
_G.GetSubZoneText = function() return world.subzone end
_G.IsInInstance = function() return false, "none" end
_G.GetBindLocation = function() return world.bind end
_G.IsSpellKnown = function(id) return world.spells[id] == true end
_G.GetQuestID = function() return world.offeredQuest end
_G.GetTitleText = function() return world.offeredQuest and world.log[world.offeredQuest] and world.log[world.offeredQuest].title end

-- ---- map -------------------------------------------------------------------
_G.C_Map = {
    GetBestMapForUnit = function() return world.mapID end,
    GetMapInfo = function(id)
        if id == 1429 then return { name = "Elwynn Forest", mapType = 3, parentMapID = 1415 } end
        return nil
    end,
    GetPlayerMapPosition = function() return CreateVector2D(world.mapX, world.mapY) end,
    -- fake projection: 1 map unit (0-1) = 1000 yards, x east -> -worldY (west), y south -> -worldX (north)
    GetWorldPosFromMapPos = function(_, v) return 0, CreateVector2D(-v.y * 1000, -v.x * 1000) end,
    GetMapWorldSize = function() return 1000, 1000 end,
    CanSetUserWaypointOnMap = function() return true end,
    SetUserWaypoint = function(p) world.waypoint = p return true end,
    ClearUserWaypoint = function() world.waypoint = nil end,
}
_G.UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { map = m, x = x, y = y } end }
_G.C_SuperTrack = { SetSuperTrackedUserWaypoint = function(v) world.superTrack = v end }

-- ---- quests -----------------------------------------------------------------
_G.C_QuestLog = {
    GetNumQuestLogEntries = function() return #world.logOrder + 1, #world.logOrder end,
    GetInfo = function(i)
        if i == 1 then return { isHeader = true, title = "Elwynn Forest" } end
        local qid = world.logOrder[i - 1]
        local q = qid and world.log[qid]
        if not q then return nil end
        return { questID = qid, title = q.title, level = q.level or 1, isHeader = false }
    end,
    GetQuestObjectives = function(qid)
        local q = world.log[qid]
        if not q then return {} end
        local out = {}
        for i, o in ipairs(q.objectives or {}) do
            out[i] = { text = o.text, type = "monster", finished = o.finished, numFulfilled = o.numFulfilled, numRequired = o.numRequired }
        end
        return out
    end,
    IsOnQuest = function(qid) return world.log[qid] ~= nil end,
    IsComplete = function(qid)
        local q = world.log[qid]
        if not q then return false end
        for _, o in ipairs(q.objectives or {}) do if not o.finished then return false end end
        return true
    end,
    ReadyForTurnIn = function(qid) return C_QuestLog.IsComplete(qid) end,
    IsFailed = function() return false end,
    IsQuestFlaggedCompleted = function(qid) return world.completed[qid] == true end,
    GetTitleForQuestID = function(qid) return world.titles and world.titles[qid] end,
    RequestLoadQuestByID = function() end,
    GetNextWaypoint = function() return nil end,
    GetMaxNumQuestsCanAccept = function() return 20 end,
    UnitIsRelatedToActiveQuest = function() return false end,
}
_G.C_Item = { GetItemCount = function(id) return world.items[id] or 0 end }
_G.C_SpellBook = { IsSpellKnown = function(id) return world.spells[id] == true end }
_G.C_GossipInfo = { GetAvailableQuests = function() return {} end, GetActiveQuests = function() return {} end }
_G.C_AddOns = { GetAddOnMetadata = function() return "0.1.0-test" end }

-- ---- helpers for tests ---------------------------------------------------------
local function fire(event, ...)
    for _, f in ipairs(frames) do
        if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end
_G.MOCK_FIRE = fire

function _G.MOCK_ACCEPT(qid, title, objectives)
    world.log[qid] = { title = title, level = 1, objectives = objectives or {} }
    world.logOrder[#world.logOrder + 1] = qid
    fire("QUEST_ACCEPTED", qid)
    fire("QUEST_LOG_UPDATE")
end

function _G.MOCK_PROGRESS(qid, idx, fulfilled)
    local o = world.log[qid].objectives[idx]
    o.numFulfilled = fulfilled
    o.finished = fulfilled >= o.numRequired
    fire("QUEST_LOG_UPDATE")
end

local function remove(qid)
    world.log[qid] = nil
    for i, id in ipairs(world.logOrder) do if id == qid then table.remove(world.logOrder, i) break end end
end

function _G.MOCK_TURNIN(qid)
    world.completed[qid] = true
    fire("QUEST_TURNED_IN", qid, 100, 0)
    remove(qid)
    fire("QUEST_REMOVED", qid, false)
    fire("QUEST_LOG_UPDATE")
end

function _G.MOCK_ABANDON(qid)
    remove(qid)
    fire("QUEST_REMOVED", qid, false)
    fire("QUEST_LOG_UPDATE")
end

function _G.MOCK_TALK(npcID, name)
    world.npc = { npcID = npcID, name = name, level = 10 }
    fire("GOSSIP_SHOW")
    world.npc = nil
end

function _G.MOCK_LEVEL(level)
    world.level = level
    fire("PLAYER_LEVEL_UP", level)
end

function _G.MOCK_MOVE(mapX, mapY)
    world.mapX, world.mapY = mapX / 100, mapY / 100
    world.worldX, world.worldY = -world.mapY * 1000, -world.mapX * 1000
end

return world
