-- ============================================================
-- ForeverGuide / AutoQuest.lua
-- Auto-accept and auto-turn-in through the normal quest windows.
-- Uses only the regular, non-protected quest-frame calls (the same ones
-- the Blizzard buttons run): SelectAvailableQuest / SelectActiveQuest,
-- AcceptQuest, CompleteQuest, GetQuestReward.
--
--   /fg auto                      status
--   /fg auto accept on|off|guide  accept every offered quest / only quests in the active guide
--   /fg auto turnin on|off        complete quests at the turn-in NPC
--   Hold SHIFT while talking to an NPC to do it by hand.
--
-- Rewards: a turn-in with more than one reward to choose from is left
-- open for you to pick. Trivial (grey) and repeatable quests are only
-- auto-accepted when the active guide asks for them.
-- ============================================================

local _, ns = ...
local Auto = ns:NewModule("AutoQuest")

local PlainNumber, PlainString, PlainBool, Safe = ns.PlainNumber, ns.PlainString, ns.PlainBool, ns.Safe

local function Cfg()
    ns.db.auto = ns.db.auto or {}
    local a = ns.db.auto
    if a.accept == nil then a.accept = "on" end        -- "on" | "off" | "guide"
    if a.turnin == nil then a.turnin = true end
    if a.announce == nil then a.announce = true end
    return a
end

local function Bypass()
    return Safe(rawget(_G, "IsShiftKeyDown")) == true
end

--- Is this quest part of the active guide (an ACCEPT / TURNIN step)?
local function InGuide(questID)
    local g = ns.Guide.active
    if not g or not questID then return false end
    for _, s in ipairs(g.steps) do
        if s.quest == questID then return true end
    end
    return false
end

--- Should we auto-accept this offered quest?
local function WantAccept(questID, title, trivial, repeatable)
    local a = Cfg()
    if a.accept == "off" then return false end
    if InGuide(questID) then return true end
    if a.accept == "guide" then return false end
    if trivial or repeatable then return false end
    return true
end

local function Announce(fmt, ...)
    if Cfg().announce then ns.Printf(fmt, ...) end
end

-- ------------------------------------------------------------
-- Gossip / greeting: pick the quest to hand in or take
-- ------------------------------------------------------------
local function HandleGossip()
    if Bypass() then return end
    local a = Cfg()
    if a.turnin then
        local active = ns.Call("C_GossipInfo.GetActiveQuests")
        if type(active) == "table" then
            for _, q in ipairs(active) do
                if PlainBool(q.isComplete) then
                    ns.Call("C_GossipInfo.SelectActiveQuest", PlainNumber(q.questID))
                    return
                end
            end
        end
    end
    if a.accept ~= "off" then
        local avail = ns.Call("C_GossipInfo.GetAvailableQuests")
        if type(avail) == "table" then
            for _, q in ipairs(avail) do
                local id = PlainNumber(q.questID)
                if WantAccept(id, PlainString(q.title), PlainBool(q.isTrivial), PlainBool(q.repeatable) or (PlainNumber(q.frequency) or 0) > 0) then
                    ns.Call("C_GossipInfo.SelectAvailableQuest", id)
                    return
                end
            end
        end
    end
end

local function HandleGreeting()
    if Bypass() then return end
    local a = Cfg()
    if a.turnin then
        local n = PlainNumber(Safe(rawget(_G, "GetNumActiveQuests"))) or 0
        for i = 1, n do
            local _, isComplete = Safe(rawget(_G, "GetActiveTitle"), i)
            if PlainBool(isComplete) then
                Safe(rawget(_G, "SelectActiveQuest"), i)
                return
            end
        end
    end
    if a.accept ~= "off" then
        local n = PlainNumber(Safe(rawget(_G, "GetNumAvailableQuests"))) or 0
        for i = 1, n do
            local title = PlainString(Safe(rawget(_G, "GetAvailableTitle"), i))
            local isTrivial, frequency, isRepeatable = Safe(rawget(_G, "GetAvailableQuestInfo"), i)
            -- no quest id in the greeting API: match the guide by title
            local questID
            local g = ns.Guide.active
            if g and title then
                for _, s in ipairs(g.steps) do
                    if s.quest and (s.questName == title or ns.DB:QuestName(s.quest) == title) then questID = s.quest break end
                end
            end
            if WantAccept(questID, title, PlainBool(isTrivial), PlainBool(isRepeatable) or (PlainNumber(frequency) or 0) > 0) then
                Safe(rawget(_G, "SelectAvailableQuest"), i)
                return
            end
        end
    end
end

-- ------------------------------------------------------------
-- Quest frames: accept / complete / reward
-- ------------------------------------------------------------
local function HandleDetail()
    if Bypass() then return end
    local questID = PlainNumber(Safe(rawget(_G, "GetQuestID")))
    local title = PlainString(Safe(rawget(_G, "GetTitleText")))
    if not WantAccept(questID, title, false, false) then return end
    if Safe(rawget(_G, "QuestGetAutoAccept")) == true then
        Safe(rawget(_G, "AcknowledgeAutoAcceptQuest"))
    else
        Safe(rawget(_G, "AcceptQuest"))
    end
    Announce("accepted %s", ns.Quest:TitleWithLevel(questID, title))
end

local function HandleProgress()
    if Bypass() or not Cfg().turnin then return end
    if Safe(rawget(_G, "IsQuestCompletable")) == true then
        Safe(rawget(_G, "CompleteQuest"))
    end
end

local function HandleComplete()
    if Bypass() or not Cfg().turnin then return end
    local choices = PlainNumber(Safe(rawget(_G, "GetNumQuestChoices"))) or 0
    local questID = PlainNumber(Safe(rawget(_G, "GetQuestID")))
    local title = PlainString(Safe(rawget(_G, "GetTitleText")))
    if choices > 1 then
        Announce("%s - choose your reward", ns.Quest:TitleWithLevel(questID, title))
        return
    end
    Safe(rawget(_G, "GetQuestReward"), choices)
    Announce("turned in %s", ns.Quest:TitleWithLevel(questID, title))
end

function Auto:OnInit()
    local E = ns.Events
    E:Register("GOSSIP_SHOW", function() E:After(0.05, HandleGossip) end)
    E:Register("QUEST_GREETING", function() E:After(0.05, HandleGreeting) end)
    E:Register("QUEST_DETAIL", function() E:After(0.05, HandleDetail) end)
    E:Register("QUEST_PROGRESS", function() E:After(0.05, HandleProgress) end)
    E:Register("QUEST_COMPLETE", function() E:After(0.05, HandleComplete) end)
end

function Auto:Status()
    local a = Cfg()
    return string.format("auto-accept: %s, auto-turn-in: %s (hold SHIFT at an NPC to do it by hand)",
        a.accept, a.turnin and "on" or "off")
end

function Auto:Set(what, value)
    local a = Cfg()
    if what == "accept" then
        if value == "on" or value == "off" or value == "guide" then a.accept = value else return false end
    elseif what == "turnin" then
        if value == "on" then a.turnin = true elseif value == "off" then a.turnin = false else return false end
    elseif what == "announce" then
        a.announce = (value ~= "off")
    else
        return false
    end
    return true
end
