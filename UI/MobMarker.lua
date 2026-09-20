-- ============================================================
-- ForeverGuide / UI/MobMarker.lua
-- Skulls over the mobs the current step wants killed (or looted):
--
--        [ skull ]   <- the best pick: nearest untagged quest mob
--       Great Goretusk
--
--        [skull]     <- smaller: every other quest mob around (this step's
--                       and any other active quest's)
--
-- Raid target icons (SetRaidTarget) are blocked for addons on this client
-- (ADDON_ACTION_FORBIDDEN, the same reason RestedXP disables them on 12.x),
-- so the skulls are our own textures anchored to the enemy nameplates.
-- That needs enemy nameplates on; with `plates` set (default) they are
-- switched on while a kill/collect step is current and restored afterwards.
-- "Nearest" without UnitPosition (nil for non-group units here): the
-- nameplate's engine-set scale, then its height on screen (a chase camera
-- looks down: lower on screen = closer). A mob tagged by someone else
-- (UnitIsTapDenied) gets no skull at all.
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local MM = ns:NewModule("MobMarker")

local SKULL_TEX = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
local SKULL_COORDS = { 0.75, 1, 0.25, 0.5 }    -- 4x4 atlas, index 8

local pool, used = {}, {}
local wanted, wantedAt = {}, 0     -- lower-case npc names for the current step
local forcedPlates = nil           -- previous nameplateShowEnemies value when we switched them on
local lastPrimary

local function cfg()
    ns.db.nav.skull = ns.db.nav.skull or { enabled = true, plates = true, others = true }
    return ns.db.nav.skull
end
MM.Cfg = cfg

-- ---- what the step wants -----------------------------------------------------------
local OBJECTIVE = { KILL = true, COLLECT = true, COMPLETE = true }

local function addName(set, name)
    if type(name) == "string" and name ~= "" then set[string.lower(name)] = name end   -- lower -> as written
end

-- the mobs behind one database objective (killed, credited, or dropping the item)
local function objectiveMobs(DB, d, set)
    if d.kind == "kill" or d.kind == "credit" then
        addName(set, d.name)
    elseif d.kind == "item" then
        local it = DB:GetItem(d.id)
        for _, npc in ipairs(it and it.npc or {}) do addName(set, DB:NPCName(npc)) end
    end
end

-- which database objective a live objective is (by wording), so a finished "Goretusk Snout 5/5"
-- takes the goretusks off the list even while the quest's other objectives are open
local function liveToDB(DB, questID, k, live)
    local o = live[k]
    local d = DB:MatchObjective(questID, k, o and o.text)
    if not d then return nil end
    -- strict: the database objective must be named in the live text. Forever rewrote some quests
    -- (Redridge Goulash: "Kill Dire Condor" where the old data has an item), and MatchObjective's
    -- last resort - same position - would hand back the wrong mobs
    local text = o and o.text and string.lower(o.text)
    local name = d.name and string.lower(d.name)
    if text and name and name ~= "" and string.find(text, name, 1, true) then return d end
    if text and d.kind == "item" then
        local it = DB:GetItem(d.id)
        if it and it.n and string.find(text, string.lower(it.n), 1, true) then return d end
    end
    return nil
end

--- lower-case names of the mobs the current step still needs ({} when it is not a kill/loot step)
function MM:WantedNames()
    local step = ns.Guide and ns.Guide:GetCurrentStep()
    local set = {}
    if not step or not OBJECTIVE[step.type] then return set, nil end
    local DB = ns.DB
    if step.npc and DB then addName(set, DB:NPCName(step.npc)) end
    if step.type == "KILL" and step.target then
        for part in string.gmatch(step.target, "[^/]+") do addName(set, ns.Trim(part)) end
    end
    if step.quest and DB and DB:IsLoaded() then
        local objIdx = ns.Guide:StepObjectiveIndex(step)
        local live = ns.Quest:GetObjectives(step.quest) or {}
        if objIdx then
            local d = liveToDB(DB, step.quest, objIdx, live)
            if d and not (live[objIdx] and live[objIdx].finished) then objectiveMobs(DB, d, set) end
        elseif #live > 0 then
            -- no single objective identified: every objective that is still open
            for k, o in ipairs(live) do
                if not o.finished then
                    local d = liveToDB(DB, step.quest, k, live)
                    if d then objectiveMobs(DB, d, set) end
                end
            end
        else
            for _, d in ipairs(DB:QuestObjectives(step.quest) or {}) do objectiveMobs(DB, d, set) end
        end
    end
    return set, step
end

--- lower-case names of mobs of every OPEN kill objective in the log (any quest, not just the guide's step)
function MM:OpenKillNames()
    local set = {}
    local DB = ns.DB
    if not DB or not DB:IsLoaded() or not ns.Quest then return set end
    for _, questID in ipairs(ns.Quest.order or {}) do
        local live = ns.Quest:GetObjectives(questID) or {}
        for k, o in ipairs(live) do
            if not o.finished then
                local d = liveToDB(DB, questID, k, live)
                if d and (d.kind == "kill" or d.kind == "credit") then addName(set, d.name) end
                -- "X slain: 4/10" with no database match: the wording itself names the mob
                if not d and o.text then
                    local mob = o.text:match("^(.-)%s+slain")
                    if mob and mob ~= "" then addName(set, mob) end
                end
            end
        end
    end
    return set
end

--- lower-case names of mobs whose objective is already complete for every quest in the log:
--- they may still count as "related to an active quest" for the client, but there is nothing to get
function MM:FinishedNames()
    local set = {}
    local DB = ns.DB
    if not DB or not DB:IsLoaded() or not ns.Quest then return set end
    for _, questID in ipairs(ns.Quest.order or {}) do
        local live = ns.Quest:GetObjectives(questID) or {}
        local open = {}
        for k, o in ipairs(live) do
            if o.finished then
                local d = liveToDB(DB, questID, k, live)
                if d then objectiveMobs(DB, d, set) end
            end
        end
        -- a mob wanted by another, still open objective of the same quest stays
        for k, o in ipairs(live) do
            if not o.finished then
                local d = liveToDB(DB, questID, k, live)
                if d then objectiveMobs(DB, d, open) end
            end
        end
        for k in pairs(open) do set[k] = nil end
    end
    return set
end

-- ---- nameplates -----------------------------------------------------------------------
local function plateUnit(plate)
    return plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
end

local function isMob(u)
    if ns.Plain(ns.Safe(UnitCanAttack, "player", u)) ~= true then return false end
    if ns.Plain(ns.Safe(UnitIsDead, u)) == true then return false end
    if ns.Plain(ns.Safe(UnitIsPlayer, u)) == true then return false end
    return true
end

local function tagged(u)
    return ns.Plain(ns.Safe(UnitIsTapDenied, u)) == true
end

local function questRelated(u)
    return ns.Plain(ns.Call("C_QuestLog.UnitIsRelatedToActiveQuest", u)) == true
end

-- Closeness proxy. Nameplate frames are "restricted regions" on this client:
-- measuring them (GetCenter/GetScale) throws in combat, anchoring to them is
-- fine. So: measure when allowed (scale, then lower on screen = closer), else
-- fall back to the interact-distance rings (10 / 28 yd), else everything ties.
local function closeness(plate, u)
    local okS, s = pcall(plate.GetScale, plate)
    local okC, _, cy = pcall(plate.GetCenter, plate)
    if okS and okC and type(cy) == "number" then
        local ui = rawget(_G, "UIParent")
        local h = ui and ui:GetHeight() or 1000
        return (ns.PlainNumber(s) or 1) * 1000 - cy / h * 100
    end
    local CID = rawget(_G, "CheckInteractDistance")
    if CID then
        if ns.Plain(ns.Safe(CID, u, 3)) == true then return 300 end   -- within ~10 yd
        if ns.Plain(ns.Safe(CID, u, 4)) == true then return 200 end   -- within ~28 yd
    end
    return 100
end

-- ---- skull frames ---------------------------------------------------------------------
local function newSkull()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("HIGH")
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    pcall(f.tex.SetTexture, f.tex, SKULL_TEX)
    pcall(f.tex.SetTexCoord, f.tex, unpack(SKULL_COORDS))
    f.ring = f:CreateTexture(nil, "BACKGROUND")
    f.ring:SetPoint("CENTER")
    pcall(f.ring.SetTexture, f.ring, Theme.TEX.ring)
    pcall(f.ring.SetBlendMode, f.ring, "ADD")
    pcall(f.ring.SetVertexColor, f.ring, 1, 0.85, 0.4)
    f.label = Theme.NewText(f, { size = 9, justify = "CENTER", color = Theme.C.goldLight, oneLine = true, outline = "OUTLINE" })
    f.label:SetPoint("TOP", f, "BOTTOM", 0, -1)
    f.label:SetWidth(160)
    f:Hide()
    return f
end

local function acquire()
    local f = table.remove(pool) or newSkull()
    used[#used + 1] = f
    return f
end

local function releaseAll()
    for _, f in ipairs(used) do
        f:Hide()
        f:ClearAllPoints()
        Theme.SetPulseEnabled(f.ring, false)
        pool[#pool + 1] = f
    end
    used = {}
end

local function dress(f, plate, primary, size)
    f:ClearAllPoints()
    f:SetSize(size, size)
    f:SetPoint("BOTTOM", plate, "TOP", 0, primary and 6 or 2)
    f.ring:SetSize(size * 1.9, size * 1.9)
    f.ring:SetShown(primary)
    if primary then
        Theme.Pulse(f.ring, 1.6, 0.35, 0.8)
        Theme.SetPulseEnabled(f.ring, cfg().animate ~= false)
        f.label:SetText("kill")
        f.label:Show()
    else
        Theme.SetPulseEnabled(f.ring, false)
        f.label:Hide()
    end
    pcall(f.SetAlpha, f, primary and 1 or 0.75)
    f:Show()
end

-- ---- enemy nameplates on/off -----------------------------------------------------------
local function getCVar(name)
    local C = rawget(_G, "C_CVar")
    local v = C and C.GetCVar and ns.Safe(C.GetCVar, name)
    if v == nil then v = ns.Safe(rawget(_G, "GetCVar"), name) end
    return ns.PlainString(v)
end
local function setCVar(name, value)
    local C = rawget(_G, "C_CVar")
    if C and C.SetCVar then return ns.Safe(C.SetCVar, name, value) end
    return ns.Safe(rawget(_G, "SetCVar"), name, value)
end

-- Friendly PLAYER nameplates (not npcs / pets / totems) during kill steps: the one way to see who
-- is hunting next to you (the crowd rules and the group-up reminder count them). Restored after.
local FRIEND_CVARS = { nameplateShowFriends = "1", nameplateShowFriendlyNPCs = "0", nameplateShowFriendlyPets = "0",
                       nameplateShowFriendlyGuardians = "0", nameplateShowFriendlyTotems = "0", nameplateShowFriendlyMinions = "0" }
local forcedFriends = nil

local function forcePlates(want)
    if not cfg().plates then return end
    if want then
        if forcedPlates == nil and getCVar("nameplateShowEnemies") ~= "1" then
            forcedPlates = getCVar("nameplateShowEnemies") or "0"
            setCVar("nameplateShowEnemies", "1")
        end
        if cfg().friendplates ~= false and forcedFriends == nil then
            forcedFriends = {}
            for k, v in pairs(FRIEND_CVARS) do
                forcedFriends[k] = getCVar(k) or "0"
                if forcedFriends[k] ~= v then setCVar(k, v) end
            end
        end
    else
        if forcedPlates ~= nil then
            setCVar("nameplateShowEnemies", forcedPlates)
            forcedPlates = nil
        end
        if forcedFriends ~= nil then
            for k, v in pairs(forcedFriends) do setCVar(k, v) end
            forcedFriends = nil
        end
    end
end

-- ---- the secure "target the next quest mob" button ----------------------------------------
-- Addons may not change the player's target from Lua; a SecureActionButton with
-- a /targetexact macro may, when the PLAYER clicks it or presses its key. The
-- macro is rewritten out of combat only (secure attributes are locked in combat);
-- the names of a kill step do not change mid-fight, so it is right when it matters.
local targetBtn, macroNames, macroPending
function MM:TargetButton()
    if targetBtn then return targetBtn end
    local ok, b = pcall(CreateFrame, "Button", "ForeverGuideTargetButton", UIParent, "SecureActionButtonTemplate")
    if not ok or not b then return nil end
    targetBtn = b
    pcall(b.SetAttribute, b, "type", "macro")
    pcall(b.RegisterForClicks, b, "AnyDown", "AnyUp")
    b:SetSize(1, 1)
    b:SetPoint("CENTER")
    return b
end

local function inCombat()
    return ns.Plain(ns.Safe(rawget(_G, "InCombatLockdown"))) == true
end

--- Point the button's macro at the current step's mobs (deferred while in combat).
function MM:UpdateTargetMacro(names)
    local b = self:TargetButton()
    if not b then return end
    local list = {}
    for _, name in pairs(names or {}) do list[#list + 1] = name end
    table.sort(list)
    local key = table.concat(list, "|")
    if key == macroNames then return end
    if inCombat() then macroPending = names return end
    local lines = {}
    for _, name in ipairs(list) do lines[#lines + 1] = "/targetexact " .. name end
    pcall(b.SetAttribute, b, "macrotext", table.concat(lines, "\n"))
    macroNames, macroPending = key, nil
    ns.Events:Fire("FG_TARGET_MACRO_CHANGED", list)
end

function MM:TargetKey()
    local k = ns.PlainString(ns.Safe(rawget(_G, "GetBindingKey"), "CLICK ForeverGuideTargetButton:LeftButton"))
    return k
end

-- ---- the scan ---------------------------------------------------------------------------
function MM:Scan()
    releaseAll()
    local c = cfg()
    self.primaryUnit, self.markedCount, self.markedUnits = nil, 0, {}
    if c.enabled == false or (ns.UI and ns.UI.AllHidden and ns.UI:AllHidden()) then forcePlates(false) return end
    local names, step = self:WantedNames()
    local finished = self:FinishedNames()
    local openKills = self:OpenKillNames()
    local killStep = step ~= nil
    -- plates (and the crowd watch) also while an off-guide kill objective is open, e.g. a quest the
    -- player picked up on their own
    local anyKill = killStep or next(openKills) ~= nil
    forcePlates(anyKill)
    self:UpdateTargetMacro(names)
    local NP = rawget(_G, "C_NamePlate")
    if not NP or type(NP.GetNamePlates) ~= "function" then return end
    local plates = ns.Safe(NP.GetNamePlates) or {}
    local best, bestScore, mine
    local others = {}
    local targetGUID = ns.PlainString(ns.Safe(UnitGUID, "target"))
    local seenFree, seenTagged, seenPlayers, seenNames = 0, 0, {}, {}
    local killFree, killTagged = 0, 0      -- mobs of any open kill objective in the log
    for _, plate in ipairs(plates) do
        local u = plateUnit(plate)
        if u and ns.Plain(ns.Safe(UnitIsPlayer, u)) == true then
            local g = ns.PlainString(ns.Safe(UnitGUID, u))
            if g and g ~= ns.PlainString(ns.Safe(UnitGUID, "player")) then
                seenPlayers[g] = true
                if ns.Plain(ns.Safe(UnitCanAttack, "player", u)) ~= true then
                    local nm = ns.PlainString(ns.Safe(UnitName, u))
                    if nm then seenNames[nm] = true end
                end
            end
        end
        if u and isMob(u) then
            local name = ns.PlainString(ns.Safe(UnitName, u))
            local lower = name and string.lower(name)
            local isWanted = lower and names[lower] ~= nil
            if isWanted then if tagged(u) then seenTagged = seenTagged + 1 else seenFree = seenFree + 1 end end
            if lower and openKills[lower] then if tagged(u) then killTagged = killTagged + 1 else killFree = killFree + 1 end end
            -- objective complete for this mob's quest(s): no skull, whatever the client says
            local related = isWanted or (not (lower and finished[lower]) and questRelated(u))
            -- a mob tagged by someone else is nobody's kill: no skull at all
            if related and not tagged(u) then
                local isTarget = targetGUID and ns.PlainString(ns.Safe(UnitGUID, u)) == targetGUID
                if isWanted then
                    local score = closeness(plate, u) + (isTarget and 5000 or 0)
                    if not bestScore or score > bestScore then
                        if best then others[#others + 1] = best end
                        best, bestScore = plate, score
                    else
                        others[#others + 1] = plate
                    end
                elseif c.others ~= false then
                    others[#others + 1] = plate
                end
            end
        end
    end
    if best then dress(acquire(), best, true, 30 * (c.size or 1)) end
    if c.others ~= false then
        for _, plate in ipairs(others) do dress(acquire(), plate, false, 18 * (c.size or 1)) end
    end
    self.primaryUnit = best and plateUnit(best) or nil
    self.markedCount = #used
    self.markedUnits = {}
    if best then self.markedUnits[plateUnit(best)] = "primary" end
    if c.others ~= false then for _, plate in ipairs(others) do self.markedUnits[plateUnit(plate)] = "other" end end
    -- the player's own target got taken by someone else: say so once (we cannot retarget for them)
    if killStep and targetGUID and not self.taggedWarned then
        local tName = ns.PlainString(ns.Safe(UnitName, "target"))
        local tl = tName and string.lower(tName)
        if tl and names[tl] and tagged("target") then
            self.taggedWarned = targetGUID
            local key = self:TargetKey()
            ns.Printf("%s is taken - %s to target the next one.", tName, key and ("press " .. key) or "click the skull button (or bind a key: Key Bindings > AddOns > ForeverGuide)")
        end
    end
    if not targetGUID or self.taggedWarned ~= targetGUID then self.taggedWarned = nil end
    if anyKill and ns.Crowd then
        ns.Crowd:Observe(seenFree, seenTagged, seenPlayers, seenNames, killFree, killTagged)
        ns.Crowd:Update()
    end
    local guid = best and ns.PlainString(ns.Safe(UnitGUID, plateUnit(best)))
    if guid ~= lastPrimary then
        lastPrimary = guid
        ns.Events:Fire("FG_MOB_MARKED", guid, best and plateUnit(best))
    end
end

function MM:SetEnabled(on)
    cfg().enabled = on and true or false
    self:Scan()
end

function MM:OnInit()
    ns.Events:RegisterMany({ "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED", "UNIT_FLAGS", "PLAYER_REGEN_ENABLED" },
        function() ns.Events:Debounce("mobmarker", 0.1, function() MM:Scan() end) end)
    ns.Events:Register("PLAYER_REGEN_ENABLED", function() if macroPending then MM:UpdateTargetMacro(macroPending) end end)
    ns.Events:RegisterMany({ "FG_STEP_CHANGED", "FG_GUIDE_CHANGED", "FG_MODE_CHANGED", "FG_QUEST_LOG_CHANGED", "FG_HIDDEN_ALL_CHANGED" },
        function() ns.Events:Debounce("mobmarker", 0.1, function() MM:Scan() end) end)
end

function MM:OnEnable()
    self:TargetButton()
    -- a slow ticker catches tap changes and deaths the events miss
    local t = CreateFrame("Frame")
    t.elapsed = 0
    t:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + (elapsed or 0)
        if self.elapsed < 0.5 then return end
        self.elapsed = 0
        local ok, err = pcall(MM.Scan, MM)
        if not ok then ns.ReportOnce("mobmarker:scan", err) end
    end)
    self:Scan()
end

function MM:OnLogout()
    forcePlates(false)
end
