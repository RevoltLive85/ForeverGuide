-- ============================================================
-- ForeverGuide / Tracker.lua
-- "Auto" mode: navigate the quest log directly, no guide needed.
-- For every quest in the log the database knows, the tracker finds the
-- nearest place that makes progress (an unfinished objective's spawns, or
-- the turn-in NPC once the quest is ready) and points the arrow there.
--
--   /fg mode auto     tracker drives navigation and the window
--   /fg mode guide    the active guide does (default)
-- With no guide active the tracker is used automatically.
-- ============================================================

local _, ns = ...
local Tracker = ns:NewModule("Tracker")

local URGENCY_YARDS = 60  -- see Rethink()
Tracker.current = nil     -- { questID, title, what, loc, distance, score, grey }
Tracker.candidates = {}   -- all quests with their best location, sorted by distance

local RETHINK = 12        -- seconds between automatic re-picks (the nearest target changes as you move)

function Tracker:IsActive()
    if not ns.DB or not ns.DB:IsLoaded() then return false end
    local mode = ns.char and ns.char.mode or "guide"
    if mode == "auto" then return true end
    return ns.Guide.active == nil
end

--- Best location for one quest: nil if the DB cannot help.
function Tracker:BestForQuest(entry)
    local DB, Q = ns.DB, ns.Quest
    local questID = entry.questID
    if not DB:GetQuest(questID) then return nil end
    local locs, what, whatFor = {}, nil, {}
    if entry.ready then
        locs = DB:QuestEnds(questID)
        what = "turn in"
    else
        local unfinished = 0
        for idx, o in ipairs(entry.objectives) do
            if not o.finished then
                unfinished = unfinished + 1
                local dbo = DB:MatchObjective(questID, idx, o.text)
                if dbo then
                    for _, l in ipairs(dbo.locations) do
                        locs[#locs + 1] = l
                        whatFor[l] = o.text        -- do not write into the shared (cached) location tables
                    end
                end
            end
        end
        if unfinished == 0 and #entry.objectives == 0 then
            -- no objectives known to the client: go to the turn-in
            locs = DB:QuestEnds(questID)
            what = "turn in"
        end
    end
    local loc, dist = DB:Nearest(locs)
    if not loc then return nil end
    return { questID = questID, title = entry.title, what = what or whatFor[loc] or loc.name or "objective",
             loc = loc, distance = dist }
end

function Tracker:Rethink()
    local list = {}
    for entry in ns.Quest:Iterate() do
        if not entry.isHidden then
            local best = self:BestForQuest(entry)
            if best then list[#list + 1] = best end
        end
    end
    -- nearest first, but quests about to turn grey pull ahead: every level of
    -- headroom before the reward shrinks is worth URGENCY_YARDS of walking
    local Q = ns.Quest
    for _, c in ipairs(list) do
        local margin = math.min(Q:LevelsUntilGrey(c.questID), 8)
        c.score = (c.distance or 1e9) + margin * URGENCY_YARDS
        c.grey = Q:GreyWarning(c.questID)
    end
    table.sort(list, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        return a.questID < b.questID
    end)
    self.candidates = list
    local changed = (list[1] and list[1].questID) ~= (self.current and self.current.questID)
        or (list[1] and self.current and list[1].what ~= self.current.what)
    self.current = list[1]
    if self:IsActive() and not ns.Navigation.override then
        if self.current then
            local c = self.current
            local t = ns.Navigation.target
            if not (t and t.map == c.loc.map and t.x == c.loc.x and t.y == c.loc.y) then
                ns.Navigation:SetTarget({ map = c.loc.map, x = c.loc.x, y = c.loc.y,
                    label = c.title .. " - " .. c.what, radius = 20, owner = "tracker" })
            end
        else
            ns.Navigation:Clear()
        end
        if changed then ns.Events:Fire("FG_TRACKER_CHANGED", self.current) end
    end
end

function Tracker:Describe()
    local c = self.current
    if not c then return "nothing to track" end
    return string.format("%s: %s (%s)", c.title, c.what, ns.DB:DescribeLocation(c.loc))
end

function Tracker:OnInit()
    local function rethink()
        if not Tracker:IsActive() then return end
        ns.Events:Debounce("tracker", 0.3, function() Tracker:Rethink() end)
    end
    ns.Events:RegisterMany({ "FG_QUEST_LOG_CHANGED", "FG_ZONE_CHANGED", "FG_GUIDE_CHANGED", "FG_MODE_CHANGED" }, rethink)
    ns.Events:Register("FG_NAV_ARRIVED", function()
        if Tracker:IsActive() then ns.Events:After(2, function() Tracker:Rethink() end) end
    end)
end

function Tracker:OnEnable()
    local function tick()
        if Tracker:IsActive() then
            local ok, err = pcall(Tracker.Rethink, Tracker)
            if not ok then ns.ReportOnce("tracker:tick", err) end
        end
        C_Timer.After(RETHINK, tick)   -- always re-armed, even after an error
    end
    C_Timer.After(RETHINK, tick)
end

function Tracker:SetMode(mode)
    ns.char.mode = mode
    ns.Events:Fire("FG_MODE_CHANGED", mode)
    if mode ~= "auto" and ns.Guide.active then
        ns.Guide:UpdateNavigation()
    end
end
