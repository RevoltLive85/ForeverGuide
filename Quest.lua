-- ============================================================
-- ForeverGuide / Quest.lua
-- Quest log snapshot, quest states and objective tracking.
--
-- API used (all confirmed present on 1.60.1):
--   C_QuestLog.GetNumQuestLogEntries, GetInfo(index), GetQuestObjectives,
--   IsOnQuest, IsComplete, ReadyForTurnIn, IsFailed, IsQuestFlaggedCompleted,
--   GetTitleForQuestID, RequestLoadQuestByID, GetLogIndexForQuestID,
--   GetNextWaypoint, GetAllCompletedQuestIDs
-- Events: QUEST_ACCEPTED(questId), QUEST_TURNED_IN(questID, xp, money),
--   QUEST_REMOVED(questID, wasReplayQuest), QUEST_LOG_UPDATE,
--   UNIT_QUEST_LOG_CHANGED(unit), QUEST_WATCH_UPDATE(questID),
--   QUEST_LOG_CRITERIA_UPDATE(questID, treeID, desc, fulfilled, required),
--   QUEST_DATA_LOAD_RESULT(questID, success)
--
-- Internal messages fired:
--   FG_QUEST_ACCEPTED(questID, title)
--   FG_QUEST_TURNED_IN(questID, title)
--   FG_QUEST_ABANDONED(questID, title)
--   FG_QUEST_READY(questID, title)            all objectives done
--   FG_OBJECTIVE_PROGRESS(questID, index, fulfilled, required, finished, text)
--   FG_QUEST_LOG_CHANGED()
-- ============================================================

local _, ns = ...
local Quest = ns:NewModule("Quest")

local Plain, PlainNumber, PlainString, PlainBool, Safe = ns.Plain, ns.PlainNumber, ns.PlainString, ns.PlainBool, ns.Safe

Quest.STATE = {
    NOT_STARTED      = "NOT_STARTED",
    IN_PROGRESS      = "IN_PROGRESS",
    READY_TO_TURN_IN = "READY_TO_TURN_IN",
    COMPLETED        = "COMPLETED",
    FAILED           = "FAILED",
}

Quest.log = {}            -- questID -> entry (see Refresh)
Quest.order = {}          -- questIDs in log order
Quest.titles = {}         -- questID -> title cache (also for quests not in the log)
Quest.recentTurnIns = {}  -- questID -> time
Quest.requested = {}      -- questID -> true once RequestLoadQuestByID was sent

-- ------------------------------------------------------------
-- Reading the log
-- ------------------------------------------------------------
local function CopyObjectives(questID)
    local list = ns.Call("C_QuestLog.GetQuestObjectives", questID)
    local out = {}
    if type(list) ~= "table" then return out end
    for i, o in ipairs(list) do
        if type(o) == "table" then
            out[i] = {
                index = i,
                text = PlainString(o.text) or "",
                type = PlainString(o.type) or "",
                finished = PlainBool(o.finished) == true,
                numFulfilled = PlainNumber(o.numFulfilled) or 0,
                numRequired = PlainNumber(o.numRequired) or 0,
            }
        end
    end
    return out
end

function Quest:Refresh()
    local old = self.log
    local new, order = {}, {}
    local numEntries = PlainNumber(ns.Call("C_QuestLog.GetNumQuestLogEntries")) or 0
    local header = nil

    for i = 1, numEntries do
        local info = ns.Call("C_QuestLog.GetInfo", i)
        if type(info) == "table" then
            if PlainBool(info.isHeader) then
                header = PlainString(info.title)
                if PlainBool(info.isCollapsed) and not self.warnedCollapsed then
                    -- entries under a collapsed header are not listed by GetInfo
                    self.warnedCollapsed = true
                    ns.Warn("a collapsed header in your quest log hides its quests from ForeverGuide - expand it (auto mode and objective tracking need the full list).")
                end
            else
                local questID = PlainNumber(info.questID)
                if questID and questID > 0 then
                    local real = PlainString(info.title)
                    local title = real or self.titles[questID] or ("Quest " .. questID)
                    if real then self.titles[questID] = real end   -- never cache the placeholder (secret title in combat)
                    local entry = {
                        questID = questID,
                        title = title,
                        level = PlainNumber(info.level) or 0,
                        logIndex = i,
                        header = header,
                        isTask = PlainBool(info.isTask) == true,
                        isHidden = PlainBool(info.isHidden) == true,
                        isComplete = Plain(ns.Call("C_QuestLog.IsComplete", questID)) == true,
                        isFailed = Plain(ns.Call("C_QuestLog.IsFailed", questID)) == true,
                        objectives = CopyObjectives(questID),
                    }
                    local ready = PlainBool(ns.Call("C_QuestLog.ReadyForTurnIn", questID))
                    entry.ready = ready == true or entry.isComplete
                    new[questID] = entry
                    order[#order + 1] = questID
                end
            end
        end
    end

    self.log, self.order = new, order

    -- diff objectives against the previous snapshot
    for questID, entry in pairs(new) do
        local prev = old[questID]
        if prev then
            for idx, obj in ipairs(entry.objectives) do
                local po = prev.objectives[idx]
                if not po or po.numFulfilled ~= obj.numFulfilled or po.finished ~= obj.finished then
                    ns.Events:Fire("FG_OBJECTIVE_PROGRESS", questID, idx, obj.numFulfilled, obj.numRequired, obj.finished, obj.text)
                end
            end
            if entry.ready and not prev.ready then
                ns.Events:Fire("FG_QUEST_READY", questID, entry.title)
            end
        end
    end

    ns.Events:Fire("FG_QUEST_LOG_CHANGED")
end

-- ------------------------------------------------------------
-- Queries
-- ------------------------------------------------------------
function Quest:IsOnQuest(questID)
    if self.log[questID] then return true end
    return Plain(ns.Call("C_QuestLog.IsOnQuest", questID)) == true
end

--- Quest has been turned in at some point (server-side completion flag).
function Quest:IsCompleted(questID)
    local t = self.recentTurnIns[questID]
    if t and ns.Now() - t < 30 then return true end     -- the server flag can lag the QUEST_TURNED_IN event
    return Plain(ns.Call("C_QuestLog.IsQuestFlaggedCompleted", questID)) == true
end

function Quest:IsReadyForTurnIn(questID)
    local entry = self.log[questID]
    if entry then return entry.ready end
    return PlainBool(ns.Call("C_QuestLog.ReadyForTurnIn", questID)) == true
end

function Quest:IsFailed(questID)
    local entry = self.log[questID]
    if entry then return entry.isFailed end
    return Plain(ns.Call("C_QuestLog.IsFailed", questID)) == true
end

function Quest:GetState(questID)
    if self:IsCompleted(questID) then return self.STATE.COMPLETED end
    if self:IsOnQuest(questID) then
        if self:IsFailed(questID) then return self.STATE.FAILED end
        if self:IsReadyForTurnIn(questID) then return self.STATE.READY_TO_TURN_IN end
        return self.STATE.IN_PROGRESS
    end
    return self.STATE.NOT_STARTED
end

function Quest:GetEntry(questID)
    return self.log[questID]
end

function Quest:GetObjectives(questID)
    local entry = self.log[questID]
    if entry then return entry.objectives end
    return CopyObjectives(questID)
end

function Quest:GetObjective(questID, index)
    local objs = self:GetObjectives(questID)
    return objs and objs[index]
end

--- Objective progress for a quest: fulfilled, required, finished.
--- With no index: sum over all objectives.
function Quest:GetProgress(questID, index)
    local objs = self:GetObjectives(questID)
    if not objs or #objs == 0 then return 0, 0, self:IsReadyForTurnIn(questID) end
    if index then
        local o = objs[index]
        if not o then return 0, 0, false end
        return o.numFulfilled, o.numRequired, o.finished
    end
    local f, r, allDone = 0, 0, true
    for _, o in ipairs(objs) do
        f, r = f + o.numFulfilled, r + o.numRequired
        if not o.finished then allDone = false end
    end
    return f, r, allDone
end

--- Title for any quest ID (log, cache, or the client's quest name cache).
--- Requests the data from the server when unknown; nil until it arrives.
function Quest:GetTitle(questID)
    local entry = self.log[questID]
    if entry then return entry.title end
    if self.titles[questID] then return self.titles[questID] end
    local title = PlainString(ns.Call("C_QuestLog.GetTitleForQuestID", questID))
    if not title or title == "" then
        local getName = rawget(_G, "QuestUtils_GetQuestName")
        if getName then title = PlainString(Safe(getName, questID)) end
    end
    if title and title ~= "" then
        self.titles[questID] = title
        return title
    end
    local dbName = ns.DB and ns.DB:QuestName(questID)
    if dbName then return dbName end
    if not self.requested[questID] then
        self.requested[questID] = true       -- ask the server once per session
        ns.Call("C_QuestLog.RequestLoadQuestByID", questID)
    end
    return nil
end

--- Quest level: from the log, else the database.
function Quest:GetLevel(questID)
    local entry = self.log[questID]
    if entry and entry.level and entry.level > 0 then return entry.level end
    local q = ns.DB and ns.DB:GetQuest(questID)
    return q and q.lvl or nil
end

local COLOR_FALLBACK = {
    trivial = "9d9d9d", easy = "40bf40", normal = "ffff00", hard = "ff8040", impossible = "ff2020",
}

--- "|cff...[6]|r" - the quest level coloured like the quest log (relative to the player).
function Quest:LevelTag(questID)
    local level = self:GetLevel(questID)
    if not level then return "" end
    local hex
    local fn = rawget(_G, "GetQuestDifficultyColor")
    local color = fn and ns.Safe(fn, level)
    if type(color) == "table" and PlainNumber(color.r) then
        hex = string.format("%02x%02x%02x", math.floor(color.r * 255 + 0.5), math.floor(color.g * 255 + 0.5), math.floor(color.b * 255 + 0.5))
    else
        local diff = level - ns.Player:GetLevel()
        if diff >= 5 then hex = COLOR_FALLBACK.impossible
        elseif diff >= 3 then hex = COLOR_FALLBACK.hard
        elseif diff >= -2 then hex = COLOR_FALLBACK.normal
        elseif diff >= -6 then hex = COLOR_FALLBACK.easy
        else hex = COLOR_FALLBACK.trivial end
    end
    return "|cff" .. hex .. "[" .. level .. "]|r"
end

--- Share of the quest's xp the player still gets (Classic rules): 1 while at
--- most 5 levels above the quest, then 0.8 / 0.6 / 0.4 / 0.2, then 0.1.
local REDUCTION = { [6] = 0.8, [7] = 0.6, [8] = 0.4, [9] = 0.2 }
function Quest:XPMultiplier(questID, playerLevel)
    local level = self:GetLevel(questID)
    if not level then return 1 end
    local diff = (playerLevel or ns.Player:GetLevel()) - level
    if diff <= 5 then return 1 end
    return REDUCTION[diff] or 0.1
end

--- Levels the player can still gain before this quest starts losing xp (0 = already reduced).
function Quest:LevelsUntilGrey(questID)
    local level = self:GetLevel(questID)
    if not level then return 99 end
    return math.max(0, level + 5 - ns.Player:GetLevel())
end

--- Short warning for the UI when a quest is (about to be) out-levelled, else nil.
function Quest:GreyWarning(questID)
    local m = self:XPMultiplier(questID)
    if m < 1 then return string.format("only %d%% xp - out-levelled", math.floor(m * 100 + 0.5)) end
    if self:LevelsUntilGrey(questID) == 0 then return "loses xp at your next level" end
    return nil
end

--- "[6] Title" with the level coloured.
function Quest:TitleWithLevel(questID, title)
    title = title or self:GetTitle(questID) or ("quest " .. tostring(questID))
    local tag = self:LevelTag(questID)
    if tag == "" then return title end
    return tag .. " " .. title
end

--- Blizzard's own next-waypoint suggestion for a quest: mapID, x, y (0-100).
function Quest:GetWaypoint(questID)
    local mapID, x, y = ns.Call("C_QuestLog.GetNextWaypoint", questID)
    mapID, x, y = PlainNumber(mapID), PlainNumber(x), PlainNumber(y)
    if mapID and x and y then return mapID, x * 100, y * 100 end
    return nil
end

function Quest:GetNumQuests()
    local shown, num = ns.Call("C_QuestLog.GetNumQuestLogEntries")
    return PlainNumber(num) or #self.order, PlainNumber(ns.Call("C_QuestLog.GetMaxNumQuestsCanAccept")) or 0
end

--- Iterate log entries in log order: for entry in Quest:Iterate() do ... end
function Quest:Iterate()
    local i = 0
    return function()
        i = i + 1
        local questID = self.order[i]
        if questID then return self.log[questID] end
    end
end

-- ------------------------------------------------------------
-- Events
-- ------------------------------------------------------------
local function ScheduleRefresh()
    ns.Events:Debounce("questlog", 0.15, function() Quest:Refresh() end)
end

function Quest:OnInit()
    ns.Events:Register("QUEST_ACCEPTED", function(_, questID)
        questID = PlainNumber(questID)
        if not questID then return end
        self:Refresh()
        ns.Events:Fire("FG_QUEST_ACCEPTED", questID, self:GetTitle(questID))
    end)

    ns.Events:Register("QUEST_TURNED_IN", function(_, questID, xp, money)
        questID = PlainNumber(questID)
        if not questID then return end
        self.recentTurnIns[questID] = ns.Now()
        local title = self:GetTitle(questID)
        ScheduleRefresh()
        ns.Events:Fire("FG_QUEST_TURNED_IN", questID, title, PlainNumber(xp), PlainNumber(money))
    end)

    ns.Events:Register("QUEST_REMOVED", function(_, questID)
        questID = PlainNumber(questID)
        if not questID then return end
        local title = self:GetTitle(questID)
        ScheduleRefresh()
        -- QUEST_REMOVED fires for turn-ins as well as abandons; decide a moment later.
        ns.Events:After(0.5, function()
            local turnedIn = self.recentTurnIns[questID]
            if (turnedIn and ns.Now() - turnedIn < 5) or self:IsCompleted(questID) then return end
            ns.Events:Fire("FG_QUEST_ABANDONED", questID, title)
        end)
    end)

    ns.Events:RegisterMany({ "QUEST_LOG_UPDATE", "QUEST_WATCH_UPDATE", "QUEST_LOG_CRITERIA_UPDATE", "QUEST_POI_UPDATE" },
        ScheduleRefresh)

    ns.Events:Register("UNIT_QUEST_LOG_CHANGED", function(_, unit)
        if PlainString(unit) == "player" then ScheduleRefresh() end
    end)

    ns.Events:Register("QUEST_DATA_LOAD_RESULT", function(_, questID, success)
        questID = PlainNumber(questID)
        if questID and PlainBool(success) then
            self.requested[questID] = nil
            local title = PlainString(ns.Call("C_QuestLog.GetTitleForQuestID", questID))
            if title and title ~= "" then
                self.titles[questID] = title
                ns.Events:Fire("FG_QUEST_TITLE_LOADED", questID, title)
            end
        end
    end)
end

function Quest:OnEnterWorld()
    self:Refresh()
end
