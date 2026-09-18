-- ============================================================
-- ForeverGuide / Guide.lua
-- Guide registry and the step engine (the "interpreter").
--
-- A guide is data (see guides-src/SCHEMA.md). The engine answers one
-- question from live game state: "what is the player doing now?"
--
-- Step types and how they complete:
--   ACCEPT   quest           on quest (or already completed)
--   TURNIN   quest           quest flagged completed
--   COMPLETE quest [objective] objective(s) finished / ready to turn in
--   KILL     quest [objective] same as COMPLETE (display only)
--   COLLECT  quest [objective] same as COMPLETE (display only)
--   GRIND    level           player level >= level
--   BUY      item count      bag count >= count
--   TRAIN    spell           spell known
--   HEARTH   zone            bind location == zone (GetBindLocation), else manual
--   TRAVEL   map x y [radius] arriving within radius (Navigation) — auto
--   FLY      map x y         same as TRAVEL (flight path hint)
--   TALK     npc             interacting with that NPC (gossip/quest/vendor/trainer windows)
--   NOTE     text            manual: /fg skip (or auto when a later step is done)
--
-- Recovery rules:
--   * a step whose quest is already completed is done, whatever its type
--   * an objective/turn-in step whose quest is missing from the log jumps
--     back to that quest's ACCEPT step (unless the player skipped it)
--   * manual steps are auto-completed once the next automatic step is done
--   * steps filtered by class/race/faction are skipped
-- ============================================================

local _, ns = ...
local Guide = ns:NewModule("Guide")

local PlainNumber, Plain = ns.PlainNumber, ns.Plain

Guide.registry = {}      -- id -> guide
Guide.list = {}          -- ordered ids (registration order)
Guide.active = nil       -- guide table
Guide.progress = nil     -- ns.char.guides[id]
Guide.current = nil      -- current step index
Guide.note = nil         -- recovery note shown in UI
Guide.blocked = nil      -- current step is blocked (quest missing, no accept step)

local MANUAL = { TRAVEL = true, FLY = true, TALK = true, NOTE = true }
local OBJECTIVE = { COMPLETE = true, KILL = true, COLLECT = true }
Guide.MANUAL, Guide.OBJECTIVE = MANUAL, OBJECTIVE

-- ------------------------------------------------------------
-- Registry (called by compiled guide files)
-- ------------------------------------------------------------
function ns.RegisterGuide(guide)
    if type(guide) ~= "table" or type(guide.id) ~= "string" then
        ns.Error("RegisterGuide: guide needs a string id")
        return
    end
    guide.version = guide.version or 1
    guide.steps = guide.steps or {}
    for i, step in ipairs(guide.steps) do
        step.index = i
        step.type = string.upper(tostring(step.type or "NOTE"))
    end
    if not Guide.registry[guide.id] then
        Guide.list[#Guide.list + 1] = guide.id
    end
    Guide.registry[guide.id] = guide
end

function Guide:Get(id)
    return self.registry[id]
end

function Guide:Find(text)
    if not text or text == "" then return nil end
    if self.registry[text] then return self.registry[text] end
    local lower = string.lower(text)
    for _, id in ipairs(self.list) do
        local g = self.registry[id]
        if string.lower(id) == lower or string.lower(g.name or "") == lower then return g end
    end
    for _, id in ipairs(self.list) do
        local g = self.registry[id]
        if string.find(string.lower(id), lower, 1, true) or string.find(string.lower(g.name or ""), lower, 1, true) then
            return g
        end
    end
    return nil
end

--- Guides usable by this character (faction / class / race filters).
function Guide:Applicable(guide)
    local faction = ns.Player:GetFaction()
    if guide.faction and faction and string.upper(guide.faction) ~= string.upper(faction) then return false end
    local _, classFile = ns.Player:GetClass()
    if guide.class and classFile and not ns.Contains(guide.class, classFile) then return false end
    local _, raceFile = ns.Player:GetRace()
    if guide.race and raceFile and not ns.Contains(guide.race, raceFile) then return false end
    return true
end

function Guide:AutoPick()
    local level = ns.Player:GetLevel()
    local best, bestScore = nil, nil
    for _, id in ipairs(self.list) do
        local g = self.registry[id]
        if self:Applicable(g) then
            local minL, maxL = g.minLevel or 1, g.maxLevel or 60
            local score
            if level >= minL and level <= maxL then
                score = 0
            else
                score = math.min(math.abs(level - minL), math.abs(level - maxL))
            end
            if not bestScore or score < bestScore then best, bestScore = g, score end
        end
    end
    return best
end

-- ------------------------------------------------------------
-- Step evaluation
-- ------------------------------------------------------------
function Guide:StepApplies(step)
    if step.faction then
        local f = ns.Player:GetFaction()
        if f and string.upper(step.faction) ~= string.upper(f) then return false end
    end
    if step.class then
        local _, classFile = ns.Player:GetClass()
        if classFile and not ns.Contains(step.class, classFile) then return false end
    end
    if step.race then
        local _, raceFile = ns.Player:GetRace()
        if raceFile and not ns.Contains(step.race, raceFile) then return false end
    end
    return true
end

local function ItemCount(itemID)
    return PlainNumber(ns.Call("C_Item.GetItemCount", itemID, true)) or 0
end

local function SpellKnown(spellID)
    local known = Plain(ns.Call("C_SpellBook.IsSpellKnown", spellID))
    if known == nil then known = Plain(ns.Safe(rawget(_G, "IsSpellKnown"), spellID)) end
    if known == nil then known = Plain(ns.Safe(rawget(_G, "IsPlayerSpell"), spellID)) end
    return known == true
end

--- Is a step done according to game state (or manual completion)?
function Guide:IsStepDone(step, idx)
    local p = self.progress
    if p and p.done[idx] then return true, "manual" end
    if not self:StepApplies(step) then return true, "n/a" end

    local Q = ns.Quest
    local t = step.type
    if step.quest and Q:IsCompleted(step.quest) then return true, "quest completed" end

    if t == "ACCEPT" then
        return Q:IsOnQuest(step.quest), nil
    elseif t == "TURNIN" then
        return false, nil                       -- only via the flag check above
    elseif OBJECTIVE[t] then
        if not Q:IsOnQuest(step.quest) then return false, nil end
        if Q:IsReadyForTurnIn(step.quest) then return true, "ready" end
        if step.objective then
            local o = Q:GetObjective(step.quest, step.objective)
            return o ~= nil and o.finished, nil
        end
        local _, _, allDone = Q:GetProgress(step.quest)
        return allDone == true, nil
    elseif t == "GRIND" then
        return ns.Player:GetLevel() >= (step.level or 0), nil
    elseif t == "BUY" then
        return ItemCount(step.item) >= (step.count or 1), nil
    elseif t == "TRAIN" then
        return SpellKnown(step.spell), nil
    elseif t == "HEARTH" then
        local bind = ns.PlainString(ns.Safe(rawget(_G, "GetBindLocation")))
        if bind and step.zone then return bind == step.zone, nil end
        return false, nil
    end
    return false, nil   -- manual types
end

--- A quest step that cannot progress because the quest is not in the log.
function Guide:IsStepBlocked(step)
    if not step.quest then return false end
    if step.type == "TURNIN" or OBJECTIVE[step.type] then
        local Q = ns.Quest
        return not Q:IsOnQuest(step.quest) and not Q:IsCompleted(step.quest)
    end
    return false
end

function Guide:FindAcceptStep(questID, before)
    local steps = self.active.steps
    for i = 1, (before or #steps) do
        local s = steps[i]
        if s.type == "ACCEPT" and s.quest == questID then return i end
    end
    return nil
end

--- Recompute the current step from the persisted position and game state.
function Guide:Evaluate(reason)
    local g, p = self.active, self.progress
    if not g or not p then return end
    local steps = g.steps
    local i = p.step
    self.note, self.blocked = nil, false

    -- 1. advance over done steps; auto-complete manual steps when the next
    --    automatic step is already done
    local guard = 0
    while steps[i] and guard < #steps + 5 do
        guard = guard + 1
        local step = steps[i]
        local done = self:IsStepDone(step, i)
        if not done and MANUAL[step.type] then
            local k = i + 1
            while steps[k] and (MANUAL[steps[k].type] or not self:StepApplies(steps[k])) do k = k + 1 end
            if steps[k] and self:IsStepDone(steps[k], k) then
                p.done[i] = true
                done = true
            end
        end
        if not done then break end
        i = i + 1
    end

    -- 2. recovery: quest missing from the log
    if steps[i] and self:IsStepBlocked(steps[i]) then
        local acceptIdx = self:FindAcceptStep(steps[i].quest, i)
        if acceptIdx and not p.done[acceptIdx] then
            local title = ns.Quest:GetTitle(steps[i].quest) or ("quest " .. steps[i].quest)
            self.note = string.format("%s is not in your quest log - back to accepting it.", title)
            i = acceptIdx
        else
            self.blocked = true
            local title = ns.Quest:GetTitle(steps[i].quest) or ("quest " .. steps[i].quest)
            self.note = string.format("%s is not in your log. Accept it, or /fg skip.", title)
        end
    end

    local changed = (i ~= self.current) or (p.step ~= i)
    p.step = i
    self.current = i

    if not steps[i] then
        -- guide finished
        if g.next and self.registry[g.next] and self.registry[g.next] ~= g and (self.chainDepth or 0) < 10 then
            ns.Printf("Guide '%s' complete - continuing with '%s'.", g.name or g.id, self.registry[g.next].name or g.next)
            self.chainDepth = (self.chainDepth or 0) + 1
            self:Activate(g.next)
            self.chainDepth = self.chainDepth - 1
            return
        end
        ns.Navigation:Clear()
        if changed then ns.Events:Fire("FG_STEP_CHANGED", nil, g) end
        return
    end

    self:UpdateNavigation()
    if changed then
        ns.Events:Fire("FG_STEP_CHANGED", steps[i], g, reason)
    else
        ns.Events:Fire("FG_STEP_UPDATED", steps[i], g, reason)
    end
end

function Guide:UpdateNavigation()
    if ns.Tracker and ns.Tracker:IsActive() and ns.char.mode == "auto" then return end   -- tracker drives navigation
    local step = self:GetCurrentStep()
    if not step then ns.Navigation:Clear() return end
    local mapID, x, y = ns.Navigation:ResolveStep(step)
    if mapID then
        local t = ns.Navigation.target
        if not (t and t.map == mapID and t.x == x and t.y == y) then
            ns.Navigation:SetTarget({ map = mapID, x = x, y = y, label = self:GetStepText(step), radius = step.radius })
        end
    else
        ns.Navigation:Clear()
    end
end

-- ------------------------------------------------------------
-- Activation / manual control
-- ------------------------------------------------------------
function Guide:Activate(id, silent)
    local g = self.registry[id]
    if not g then
        ns.Error("unknown guide: " .. tostring(id))
        return false
    end
    self.active = g
    self.progress = ns.Database:GuideProgress(g.id, g.version)
    self.current = nil
    ns.char.activeGuide = g.id
    if not silent then ns.Printf("Guide: %s%s%s (%d steps)", ns.COLOR_OK, g.name or g.id, ns.COLOR_END, #g.steps) end
    self:Evaluate("activate")
    ns.Events:Fire("FG_GUIDE_CHANGED", g)
    return true
end

function Guide:GetCurrentStep()
    if not self.active or not self.current then return nil end
    return self.active.steps[self.current]
end

--- Mark the given (or current) step done and re-evaluate.
function Guide:MarkDone(idx, reason)
    if not self.active or not self.progress then return end
    idx = idx or self.current
    local step = self.active.steps[idx]
    if not step then return end
    self.progress.done[idx] = true
    -- skipping an ACCEPT step means skipping that quest entirely
    if step.type == "ACCEPT" and step.quest and reason == "skip" then
        for j, s in ipairs(self.active.steps) do
            if s.quest == step.quest then self.progress.done[j] = true end
        end
    end
    self:Evaluate(reason or "done")
end

function Guide:Skip()
    local step = self:GetCurrentStep()
    if not step then return end
    ns.Printf("Skipped step %d: %s", step.index, self:GetStepText(step))
    self:MarkDone(step.index, "skip")
end

function Guide:Back()
    if not self.active or not self.progress then return end
    local i = math.max(1, (self.current or 1) - 1)
    -- walk back over steps that do not apply to this character
    while i > 1 and not self:StepApplies(self.active.steps[i]) do i = i - 1 end
    self.progress.done[i] = nil
    self.progress.step = i
    self.current = nil
    self:Evaluate("back")
end

function Guide:SetStep(n)
    if not self.active or not self.progress then return end
    n = math.max(1, math.min(#self.active.steps, math.floor(n)))
    for j = n, #self.active.steps do self.progress.done[j] = nil end
    self.progress.step = n
    self.current = nil
    self:Evaluate("jump")
end

function Guide:Reset()
    if not self.active then return end
    ns.Database:ResetGuide(self.active.id)
    self.progress = ns.Database:GuideProgress(self.active.id, self.active.version)
    self.current = nil
    self:Evaluate("reset")
end

-- ------------------------------------------------------------
-- Display helpers
-- ------------------------------------------------------------
local VERB = {
    ACCEPT = "Accept", TURNIN = "Turn in", COMPLETE = "Complete", KILL = "Kill", COLLECT = "Collect",
    GRIND = "Grind to level", BUY = "Buy", TRAIN = "Train", HEARTH = "Set hearthstone at",
    TRAVEL = "Go to", FLY = "Fly to", TALK = "Talk to", NOTE = "",
}

function Guide:GetStepText(step)
    if not step then return "" end
    if step.text and step.text ~= "" then return step.text end
    local t = step.type
    local verb = VERB[t] or t
    local DB = ns.DB
    if step.quest and (t == "ACCEPT" or t == "TURNIN" or OBJECTIVE[t]) then
        local title = ns.Quest:TitleWithLevel(step.quest, step.questName or ns.Quest:GetTitle(step.quest))
        local target = step.target
        if OBJECTIVE[t] and not target and DB and DB:IsLoaded() then
            local objs = DB:QuestObjectives(step.quest)
            local o = step.objective and objs[step.objective] or objs[1]
            if o and o.name then target = o.name end
        end
        if OBJECTIVE[t] and target then
            if step.count then return string.format("%s %d %s (%s)", verb, step.count, target, title) end
            return string.format("%s %s (%s)", verb, target, title)
        end
        return verb .. " " .. title
    elseif t == "GRIND" then
        return verb .. " " .. tostring(step.level)
    elseif t == "BUY" then
        return string.format("%s %d x %s", verb, step.count or 1, step.itemName or (DB and DB:ItemName(step.item)) or ("item " .. tostring(step.item)))
    elseif t == "TRAIN" then
        return verb .. " " .. tostring(step.spellName or ("spell " .. tostring(step.spell)))
    elseif t == "TALK" then
        return verb .. " " .. tostring(step.npcName or (DB and DB:NPCName(step.npc)) or ("NPC " .. tostring(step.npc)))
    elseif t == "TRAVEL" or t == "FLY" then
        return verb .. " " .. tostring(step.zone or (step.x and string.format("%.1f, %.1f", step.x, step.y)) or "destination")
    elseif t == "HEARTH" then
        return verb .. " " .. tostring(step.zone or "the inn")
    end
    return step.note or t
end

--- Progress text for the current step ("6 / 8", "ready to turn in", ...).
function Guide:GetStepProgress(step)
    if not step then return "" end
    local Q = ns.Quest
    local t = step.type
    if step.quest then
        if Q:IsCompleted(step.quest) then return "completed" end
        if t == "ACCEPT" then
            return Q:IsOnQuest(step.quest) and "accepted" or "not accepted"
        end
        if not Q:IsOnQuest(step.quest) then return "not in quest log" end
        if Q:IsReadyForTurnIn(step.quest) then return "ready to turn in" end
        if t == "TURNIN" then return "objectives not finished" end
        local f, r = Q:GetProgress(step.quest, step.objective)
        if r > 0 then return string.format("%d / %d", f, r) end
        return "in progress"
    elseif t == "GRIND" then
        return string.format("level %d / %d", ns.Player:GetLevel(), step.level or 0)
    elseif t == "BUY" then
        return string.format("%d / %d", ItemCount(step.item), step.count or 1)
    elseif t == "TRAIN" then
        return SpellKnown(step.spell) and "known" or "not learned"
    elseif t == "TRAVEL" or t == "FLY" then
        return ns.Navigation:Describe()
    end
    return step.note or ""
end

function Guide:GetStepCount()
    if not self.active then return 0, 0 end
    return self.current or 0, #self.active.steps
end

-- ------------------------------------------------------------
-- Events
-- ------------------------------------------------------------
function Guide:OnInit()
    local function reeval(event) Guide:Evaluate(event) end
    ns.Events:RegisterMany({ "FG_QUEST_LOG_CHANGED", "FG_LEVEL_CHANGED", "FG_QUEST_TITLE_LOADED" }, reeval)
    ns.Events:RegisterMany({ "BAG_UPDATE_DELAYED", "SPELLS_CHANGED", "LEARNED_SPELL_IN_SKILL_LINE" }, function(event)
        ns.Events:Debounce("guide:" .. event, 0.3, function() Guide:Evaluate(event) end)
    end)
    ns.Events:Register("FG_ZONE_CHANGED", function() Guide:UpdateNavigation() end)

    -- TALK steps complete when the matching NPC window opens
    ns.Events:RegisterMany({ "GOSSIP_SHOW", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_GREETING", "MERCHANT_SHOW", "TRAINER_SHOW" },
        function()
            local step = Guide:GetCurrentStep()
            if not step or step.type ~= "TALK" then return end
            local npc = ns.Player:GetInteractionNPC()
            if not npc then return end
            if not step.npc or step.npc == npc.npcID then
                Guide:MarkDone(step.index, "talked")
            end
        end)

    -- TRAVEL/FLY steps complete on arrival (Navigation is polled by the UI)
    ns.Events:Register("FG_NAV_ARRIVED", function()
        local step = Guide:GetCurrentStep()
        if step and (step.type == "TRAVEL" or step.type == "FLY") then
            Guide:MarkDone(step.index, "arrived")
        end
    end)
end

function Guide:OnEnable()
    local id = ns.char.activeGuide
    if id and self.registry[id] then
        self:Activate(id, true)
    elseif ns.char.autoPickGuide then
        local g = self:AutoPick()
        if g then self:Activate(g.id) end
    end
    if not self.active then
        ns.Warn("no guide active. /fg guides to list, /fg guide <name> to start one.")
    end
end

function Guide:OnEnterWorld()
    if self.active then self:Evaluate("enter-world") end
end
