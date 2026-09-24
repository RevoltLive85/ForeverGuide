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
    function r:SetScale(v) self.scale = v end
    function r:GetScale() return self.scale or 1 end
    function r:SetFrameStrata() end
    function r:SetMovable() end
    function r:SetClampedToScreen() end
    function r:EnableMouse(on) self.mouse = on end
    function r:RegisterForDrag() end
    function r:StartMoving() self.moving = true end
    function r:StartSizing() self.sizing = true end
    function r:StopMovingOrSizing() self.moving = false self.sizing = false end
    function r:SetResizable(on) self.resizable = on end
    function r:SetResizeBounds(minW, minH, maxW, maxH) self.resizeBounds = {minW, minH, maxW, maxH} end
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
    -- ---- slider (base widget type, not a named template - see Options.lua's MakeSlider) ----
    function r:SetOrientation(o) self.orientation = o end
    function r:SetMinMaxValues(lo, hi) self.vmin, self.vmax = lo, hi end
    function r:GetMinMaxValues() return self.vmin or 0, self.vmax or 1 end
    function r:SetValueStep(step) self.vstep = step end
    function r:SetObeyStepOnDrag() end
    function r:SetHitRectInsets() end
    function r:SetThumbTexture(t) self.thumb = t end
    function r:GetThumbTexture() return self.thumb end
    function r:SetValue(v)
        if self.vmin and v < self.vmin then v = self.vmin end
        if self.vmax and v > self.vmax then v = self.vmax end
        self.value = v
        local fn = self.scripts.OnValueChanged
        if fn then fn(self, v) end
    end
    function r:GetValue() return self.value or self.vmin or 0 end
    function r:SetRotation(a) self.rotation = a end
    function r:SetVertexColor(...) self.vertex = { ... } end
    function r:SetAlpha(a) self.alpha = a end
    function r:SetAttribute(k, v) self.attrs = self.attrs or {} self.attrs[k] = v end
    function r:SetParent(p) self.parent = p end
    function r:GetFrameLevel() return self.level or 1 end
    function r:GetAttribute(k) return self.attrs and self.attrs[k] end
    function r:SetEnabled(e) self.enabled = e end
    function r:SetMaxLines(n) self.maxLines = n end
    function r:SetMaxLetters() end
    function r:SetMultiLine() end
    function r:SetAutoFocus() end
    function r:SetFocus() end
    function r:ClearFocus() end
    function r:HighlightText() end
    function r:SetTexCoord() end
    function r:SetFrameLevel() end
    function r:RegisterForClicks() end
    function r:SetBlendMode() end
    function r:GetCenter()
        -- a CENTER anchor on something's BOTTOMLEFT is an absolute position; anything else is 0,0
        local p = self.points[1]
        if p and p[1] == "CENTER" and p[3] == "BOTTOMLEFT" then return p[4] or 0, p[5] or 0 end
        return 0, 0
    end
    function r:GetEffectiveScale() return 1 end
    function r:SetAllPoints() end
    function r:SetNormalFontObject() end
    function r:SetHighlightFontObject() end
    function r:SetNormalTexture() end
    function r:SetHighlightTexture() end
    function r:SetChecked(v) self.checked = v and true or false end
    function r:GetChecked() return self.checked or false end
    function r:GetID() return 1 end
    function r:GetName() return self.name end
    function r:GetParent() return self.parent end
    function r:IsVisible() return self.shown end
    function r:SetScrollChild(c) self.scrollChild = c end
    function r:GetScrollChild() return self.scrollChild end
    function r:SetVerticalScroll(v) self.scroll = v end
    function r:GetVerticalScroll() return self.scroll or 0 end
    function r:GetVerticalScrollRange() return math.max(0, (self.scrollChild and self.scrollChild:GetHeight() or 0) - self:GetHeight()) end
    function r:EnableMouseWheel() end
    function r:SetClipsChildren() end
    function r:CreateTexture() return NewRegion("Texture") end
    function r:CreateFontString() return NewRegion("FontString") end
    return r
end

function _G.CreateFrame(kind, name, parent, template)
    local f = NewRegion(kind)
    f.name, f.template, f.parent = name, template, parent
    if name then _G[name] = f end
    frames[#frames + 1] = f
    return f
end
_G.UIParent = NewRegion("Frame")
_G.UIParent:SetSize(1280, 720)
_G.Minimap = NewRegion("Frame"); _G.Minimap.w = 140
function _G.Minimap:GetCenter() return 500, 500 end
function _G.Minimap:GetEffectiveScale() return 1 end
_G.GetCursorPosition = function() return 600, 500 end
_G.GameTooltip = NewRegion("GameTooltip")
function _G.GameTooltip:SetOwner() end
function _G.GameTooltip:AddLine() end
_G.IsShiftKeyDown = function() return world.shift == true end
_G.IsAltKeyDown = function() return world.alt == true end
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
    -- every shown frame gets one OnUpdate per advance (the client would give it many)
    for _, f in ipairs(frames) do
        local fn = f.scripts.OnUpdate
        if fn and f.shown then fn(f, seconds or 1) end
    end
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
world.xp, world.xpMax = 100, 400
_G.UnitXP = function() return world.xp end
_G.UnitXPMax = function() return world.xpMax end
_G.GetXPExhaustion = function() return 0 end
_G.UnitFactionGroup = function() return world.faction, world.faction end
_G.UnitClass = function() return unpack(world.class) end
_G.UnitRace = function() return unpack(world.race) end
_G.UnitName = function(unit)
    if unit == "player" then return "Tester" end
    if world.plates and world.plates[unit] then return world.plates[unit].name end
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
    if world.plates and world.plates[unit] then return world.plates[unit].guid end
    local u = unit == "npc" and world.npc or world.target
    return u and ("Creature-0-1-1-1-" .. u.npcID .. "-0000000001")
end
_G.UnitIsPlayer = function(unit) if unit == "questnpc" or unit == "npc" then return world.offerFromPlayer == true end local p = world.plates and world.plates[unit] return p and p.player == true or false end
_G.UnitIsDead = function(unit) local p = world.plates and world.plates[unit] return p and p.dead == true or false end
-- ---- nameplates: world.plates["nameplate1"] = { name, tagged, dead, quest, scale, y } ---
world.plates = {}
_G.UnitCanAttack = function(_, unit) local p = world.plates[unit] return p ~= nil and p.friendly ~= true and p.player ~= true end
_G.UnitIsTapDenied = function(unit) local p = world.plates[unit] return p and p.tagged == true or false end
_G.C_NamePlate = {
    GetNamePlates = function()
        local out = {}
        local keys = {}
        for u in pairs(world.plates) do keys[#keys + 1] = u end
        table.sort(keys)
        for _, u in ipairs(keys) do
            local p = world.plates[u]
            p.frame = p.frame or NewRegion("Frame")
            p.frame.namePlateUnitToken = u
            p.frame.GetScale = function() if p.restricted then error("Can't measure restricted regions") end return p.scale or 1 end
            p.frame.GetCenter = function() if p.restricted then error("Can't measure restricted regions") end return 640, p.y or 400 end
            out[#out + 1] = p.frame
        end
        return out
    end,
    GetNamePlateForUnit = function(unit) local p = world.plates[unit] return p and p.frame end,
}

_G.UnitReaction = function(_, unit)
    local u = unit == "npc" and world.npc or world.target
    return u and (u.hostile and 2 or 5)
end
_G.UnitCreatureType = function() return "Humanoid", 7 end
_G.UnitPosition = function() return world.worldX, world.worldY, 0, world.instance end
_G.GetPlayerFacing = function() return world.facing end
_G.GetZoneText = function() return world.zone end
_G.GetSubZoneText = function() return world.subzone end
_G.IsInInstance = function() return world.instanceType ~= nil and world.instanceType ~= "none", world.instanceType or "none" end
_G.GetBindLocation = function() return world.bind end
_G.IsSpellKnown = function(id) return world.spells[id] == true end
_G.GetQuestID = function() return world.offeredQuest end
_G.GetTitleText = function() return world.offeredQuest and world.log[world.offeredQuest] and world.log[world.offeredQuest].title end

-- ---- map -------------------------------------------------------------------
_G.C_Map = {
    GetBestMapForUnit = function() return world.mapID end,
    GetMapInfo = function(id)
        if id == 1429 then return { name = "Elwynn Forest", mapType = 3, parentMapID = 1415 } end
        if id == 1415 then return { name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 } end
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
-- the engine's in-world pin frame (Retail engine): shown while a user waypoint is super-tracked
do
    local stf = NewRegion("Frame")
    stf.name = "SuperTrackedFrame"
    stf.Icon = NewRegion("Texture")
    stf.Icon.alpha = 1
    stf.DistanceText = NewRegion("FontString")
    stf.DistanceText.alpha = 1
    function stf:GetRegions() return self.Icon, self.DistanceText end
    function stf:GetChildren() return end
    function stf:GetCenter() return world.pinX or 640, world.pinY or 360 end
    function stf:IsShown() return world.superTrack == true end
    function stf:IsVisible() return world.superTrack == true end
    stf.Icon.GetAlpha = function(self) return self.alpha or 1 end
    stf.DistanceText.GetAlpha = function(self) return self.alpha or 1 end
    _G.SuperTrackedFrame = stf
    local wm = NewRegion("Frame")
    wm.name = "WorldMapFrame"
    wm.hooks = {}
    function wm:HookScript(name, fn) self.hooks[name] = fn end
    function wm:IsShown() return world.mapOpen == true end
    _G.WorldMapFrame = wm
end

-- ---- quests -----------------------------------------------------------------
_G.C_QuestLog = {
    IsQuestTrivial = function(id) return world.trivial and world.trivial[id] == true end,
    IsRepeatableQuest = function(id) return world.repeatable and world.repeatable[id] == true end,
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
    GetMaxNumQuestsCanAccept = function() return world.logCap or 40 end,
    UnitIsRelatedToActiveQuest = function(unit) local p = world.plates and world.plates[unit] return p and p.quest == true or false end,
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

_G.InCombatLockdown = function() return world.inCombat == true end
_G.UnitInParty = function() return false end
_G.UnitInRaid = function() return false end
_G.UnitIsUnit = function(a, b) return a == b end
_G.IsInGroup = function() return world.group == true or world.raid == true end
_G.IsInRaid = function() return world.raid == true end

-- ---- chat + time played ----------------------------------------------------
world.chat = {}
world.playedTotal, world.playedLevel = 360000, 3600
_G.SendChatMessage = function(msg, chatType, language, target)
    if world.chatBlocked then error("ADDON_ACTION_BLOCKED: SendChatMessage") end
    world.chat[#world.chat + 1] = { message = msg, channel = chatType, target = target }
end
world.chatFilters = {}
world.printed = {}
_G.NUM_CHAT_WINDOWS = 2
for i = 1, 2 do
    local f = NewRegion("Frame")
    function f:AddMessage(message) world.printed[#world.printed + 1] = message end
    _G["ChatFrame" .. i] = f
end
--- what ChatFrame1 actually printed for a line the client pushes straight into it
function _G.MOCK_CHATFRAME(message)
    local before = #world.printed
    _G.ChatFrame1:AddMessage(message)
    return #world.printed > before and world.printed[#world.printed] or nil
end
_G.TIME_PLAYED_TOTAL = "Total time played: %s"
_G.TIME_PLAYED_LEVEL = "Time played this level: %s"
_G.ChatFrame_AddMessageEventFilter = function(event, fn)
    world.chatFilters[event] = world.chatFilters[event] or {}
    table.insert(world.chatFilters[event], fn)
end
--- what the client would print for a system message: nil when a filter swallowed it
function _G.MOCK_SYSTEM(message)
    for _, fn in ipairs(world.chatFilters.CHAT_MSG_SYSTEM or {}) do
        if fn(nil, "CHAT_MSG_SYSTEM", message) then return nil end
    end
    return message
end
_G.RequestTimePlayed = function()
    world.playedRequests = (world.playedRequests or 0) + 1
    fire("TIME_PLAYED_MSG", world.playedTotal, world.playedLevel)
end
world.invited = {}
_G.C_PartyInfo = { InviteUnit = function(name) world.invited[#world.invited + 1] = name end }
_G.C_FriendList = {
    SetWhoToUi = function() end,
    SendWho = function(q) world.whoQuery = q fire("WHO_LIST_UPDATE") end,
    GetNumWhoResults = function() return world.whoCount or 0 end,
}
world.bags = { [0] = { size = 16, items = {} } }   -- items: slot -> { quality, hasNoValue, isQuestItem }
_G.C_Container = {
    GetContainerNumSlots = function(bag) local b = world.bags[bag] return b and b.size or 0 end,
    GetContainerNumFreeSlots = function(bag) local b = world.bags[bag] if not b then return 0 end local used = 0 for _ in pairs(b.items) do used = used + 1 end return b.size - used, 0 end,
    GetContainerItemInfo = function(bag, slot) local b = world.bags[bag] return b and b.items[slot] end,
}
function _G.MOCK_BAG(freeSlots, junk, questItems)
    local b = world.bags[0]
    b.items = {}
    local slot = 1
    for _ = 1, (junk or 0) do b.items[slot] = { quality = 0, hasNoValue = false } slot = slot + 1 end
    for _ = 1, (questItems or 0) do b.items[slot] = { quality = 1, hasNoValue = true, isQuestItem = true } slot = slot + 1 end
    while b.size - (slot - 1) > freeSlots do b.items[slot] = { quality = 1, hasNoValue = false } slot = slot + 1 end
    fire("BAG_UPDATE_DELAYED")
end
_G.UnitIsGhost = function(unit) return unit == "player" and world.ghost == true end
_G.C_DeathInfo = { GetCorpseMapPosition = function(mapID) if world.corpse and world.corpse.map == mapID then return { x = world.corpse.x / 100, y = world.corpse.y / 100 } end return nil end }
function _G.MOCK_DIE(x, y) world.ghost = true world.corpse = { map = world.mapID, x = x, y = y } fire("PLAYER_DEAD") fire("PLAYER_ALIVE") end
function _G.MOCK_REVIVE() world.ghost = false world.corpse = nil fire("PLAYER_UNGHOST") end
_G.CheckInteractDistance = function(unit, ring)
    local p = world.plates and world.plates[unit]
    if not p or not p.dist then return nil end
    return (ring == 3 and p.dist <= 10) or (ring == 4 and p.dist <= 28) or false
end
function _G.MOCK_PLATE(unit, def)
    world.plates[unit] = def
    if def and def.guid == nil then def.guid = "Creature-0-1-1-1-" .. (def.npcID or 0) .. "-" .. unit end
    fire("NAME_PLATE_UNIT_" .. (def and "ADDED" or "REMOVED"), unit)
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

world.durability = {}      -- [slot] = { current, max }
_G.GetInventoryItemDurability = function(slot)
    local d = world.durability[slot]
    if not d then return nil end
    return d[1], d[2]
end

--- wear the gear down: MOCK_GEAR(60) puts everything at 60%, MOCK_GEAR(60, {[1]=0}) breaks the head
function _G.MOCK_GEAR(percent, overrides)
    world.durability = {}
    if percent == nil then return end
    for _, slot in ipairs({ 1, 3, 5, 6, 7, 8, 9, 10, 16, 17, 18 }) do
        world.durability[slot] = { math.floor(100 * percent / 100), 100 }
    end
    for slot, pct in pairs(overrides or {}) do world.durability[slot] = { math.floor(pct), 100 } end
    fire("UPDATE_INVENTORY_DURABILITY")
end

world.taxiNodes = {}       -- [mapID] = { { name, x, y, isUndiscovered, faction }, ... }
_G.Enum = _G.Enum or {}
_G.Enum.FlightPathFaction = { Neutral = 0, Horde = 1, Alliance = 2 }
_G.C_TaxiMap = {
    GetTaxiNodesForMap = function(mapID)
        local out = {}
        for _, n in ipairs(world.taxiNodes[mapID] or {}) do
            out[#out + 1] = { nodeID = n.nodeID or 1, name = n.name, isUndiscovered = n.isUndiscovered,
                              faction = n.faction, position = { x = (n.x or 50) / 100, y = (n.y or 50) / 100 } }
        end
        return out
    end,
    ShouldMapShowTaxiNodes = function() return true end,
}

world.taxiOpen = {}        -- what an open flight master would offer
_G.C_TaxiMap.GetAllTaxiNodes = function() return world.taxiOpen end
_G.Enum.FlightPathState = { Current = 0, Reachable = 1, Unreachable = 2 }
_G.ERR_NEWTAXIPATH = "New flight path discovered!"

--- walk into (or out of) an instance: MOCK_INSTANCE("party") / MOCK_INSTANCE(nil)
function _G.MOCK_INSTANCE(kind)
    world.instanceType = kind
    fire("ZONE_CHANGED_NEW_AREA")
end

--- the player opens a flight master's map: MOCK_TAXIMAP({ {name="Darkshire", state=0}, ... })
function _G.MOCK_TAXIMAP(nodes)
    world.taxiOpen = nodes or {}
    fire("TAXIMAP_OPENED")
end

--- MOCK_TAXI(mapID, { {name="Darkshire", x=74, y=45, isUndiscovered=true, faction=2} })
function _G.MOCK_TAXI(mapID, nodes)
    world.taxiNodes[mapID] = nodes
    fire("TAXI_NODE_STATUS_CHANGED")
end

--- the player opens a trainer window
function _G.MOCK_TRAINER(npcID, name)
    world.npc = { npcID = npcID, name = name, level = 40 }
    fire("TRAINER_SHOW")
    world.npc = nil
end

--- set the xp bar and fire the event the addon listens to
function _G.MOCK_XP(xp, max)
    world.xp = xp
    if max then world.xpMax = max end
    fire("PLAYER_XP_UPDATE")
end

function _G.MOCK_LEVEL(level)
    world.level = level
    fire("PLAYER_LEVEL_UP", level)
end

function _G.MOCK_MOVE(mapX, mapY)
    world.mapX, world.mapY = mapX / 100, mapY / 100
    world.worldX, world.worldY = -world.mapY * 1000, -world.mapX * 1000
end

--- move the player to another zone: map id, zone name, and where on that map
function _G.MOCK_ZONE(mapID, zoneName, mapX, mapY)
    world.mapID, world.zone = mapID, zoneName or world.zone
    world.mapName = zoneName or world.mapName
    if mapX then _G.MOCK_MOVE(mapX, mapY) end
    fire("ZONE_CHANGED_NEW_AREA")
    fire("PLAYER_MAP_CHANGED")
end


-- ---- CVars (addon-registered ones persist in config-cache.wtf) ---------------
world.cvars = { nameplateShowEnemies = "0" }
_G.GetCVar = function(name) return world.cvars[name] end
_G.SetCVar = function(name, value) return _G.C_CVar.SetCVar(name, value) end
_G.C_CVar = {
    RegisterCVar = function(name, default) if world.cvars[name] == nil then world.cvars[name] = default or "" end end,
    SetCVar = function(name, value) if world.cvars[name] == nil then return false end world.cvars[name] = tostring(value or "") return true end,
    GetCVar = function(name) return world.cvars[name] end,
    AreCVarsLoaded = function() return true end,
}
_G.GetRealmName = function() return "Classic Beta PvE 2" end

-- ---- Retail settings API (as on Forever's 12.x engine) ----------------------
_G.Settings = {
    RegisterCanvasLayoutCategory = function(frame, name)
        local cat = { name = name, frame = frame }
        function cat:GetID() return name end
        return cat
    end,
    RegisterAddOnCategory = function(cat) world.settingsCategory = cat end,
    OpenToCategory = function(id) world.settingsOpened = id end,
}

-- ---- strict globals: any read of an undefined global is a bug (the addon
-- probes optional ones with rawget, which bypasses this) --------------------
local NIL_OK = { ForeverGuideDB = true, ForeverGuideCharDB = true }   -- SavedVariables do not exist on a first login
setmetatable(_G, { __index = function(_, k)
    if NIL_OK[k] then return nil end
    error("read of undefined global '" .. tostring(k) .. "'", 2)
end })

return world
