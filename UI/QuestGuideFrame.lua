-- ============================================================
-- ForeverGuide / UI/QuestGuideFrame.lua
-- The Quest Guide window: plain panel,
-- header, the step list, two buttons. Reads the guide engine / tracker,
-- never changes them. UI.lua (the coordinator) shows / hides it.
--
--   ┌──────────────────────────────┐
--   │ (◎) QUEST GUIDE       6 / 14 │
--   │ Elwynn Forest 1-11 · Lv 7    │
--   │ ───────────────────────────  │
--   │ (5) ✓ Renegade Quistian  312 │
--   │ (6) ◆ Hilary's Necklace   85 │  <- active: outline, glow, bar
--   │       Find Hilary's Necklace │
--   │ (7) ! A Little More Trouble  │
--   │ ...                          │
--   │ [ ◎ Guide ]     [ Guides → ] │
--   └──────────────────────────────┘
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local QG = ns:NewModule("QuestGuide")

local FOOTER = 40
local frame

local ICON_FOR = { ACCEPT = "accept", TURNIN = "turnin", KILL = "kill", COLLECT = "collect", COMPLETE = "collect",
                   GRIND = "kill", TRAVEL = "travel", FLY = "travel", HEARTH = "travel", TALK = "accept", NOTE = "travel",
                   BUY = "collect", TRAIN = "accept" }

-- ---- building ----------------------------------------------------------------------
function QG:Create()
    if frame then return frame end
    local cfg = ns.db.ui
    cfg.width = math.max(cfg.width or 300, 240)
    local ok, f = pcall(CreateFrame, "Frame", "ForeverGuideFrame", UIParent, "BackdropTemplate")
    if not ok or not f then f = CreateFrame("Frame", "ForeverGuideFrame", UIParent) end
    frame = f
    f:SetSize(cfg.width, 200)
    f:SetPoint(cfg.point or "TOPRIGHT", UIParent, cfg.point or "TOPRIGHT", cfg.x or -40, cfg.y or -200)
    f:SetFrameStrata("HIGH")            -- above the objective tracker, below dialogs
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not ns.db.ui.locked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        ns.db.ui.point, ns.db.ui.x, ns.db.ui.y = point or "TOPRIGHT", x or 0, y or 0
    end)
    Theme.Backdrop(f, "panel", cfg.opacity or 0.75)
    f:SetResizable(true)
    pcall(f.SetResizeBounds, f, 240, 120, 520, 800)
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(20, 20)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    grip:SetFrameLevel(f:GetFrameLevel() + 3)
    local handle = grip:CreateTexture(nil, "ARTWORK")
    handle:SetAllPoints()
    handle:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetScript("OnMouseDown", function()
        if not ns.db.ui.locked then f.resizing = true f:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function()
        f.resizing = false
        f:StopMovingOrSizing()
        ns.db.ui.width = math.floor(math.max(240, math.min(520, f:GetWidth())) + 0.5)
        ns.db.ui.height = math.floor(math.max(120, math.min(800, f:GetHeight())) + 0.5)
        local rowHeight = ns.db.ui.showSubtitles ~= false and ns.QuestRow.HEIGHT_TWO + 3 or ns.QuestRow.HEIGHT_ONE + 3
        ns.db.ui.maxRows = math.max(3, math.min(15,
            math.floor((ns.db.ui.height - ns.QuestGuideHeader.HEIGHT - FOOTER - 6) / rowHeight)))
        QG:Apply()
        QG:Refresh()
    end)
    grip:SetShown(not cfg.locked)
    f.resizeGrip = grip

    f.header = ns.QuestGuideHeader.Create(f)
    local scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", f.header, "BOTTOMLEFT", 6, -2)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, FOOTER + 4)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local viewport = f:GetHeight() - ns.QuestGuideHeader.HEIGHT - 2 - 4 - FOOTER
        local range = math.max(self:GetVerticalScrollRange(), f.list.height - viewport, 0)
        self:SetVerticalScroll(math.max(0, math.min(range, self:GetVerticalScroll() - delta * 40)))
    end)
    f.scroll = scroll
    f.list = ns.QuestList.Create(scroll)
    f.list:SetSize(cfg.width - 12, 40)
    f.list:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    scroll:SetScrollChild(f.list)

    f.footerLine = f:CreateTexture(nil, "ARTWORK")
    f.footerLine:SetHeight(1)
    pcall(f.footerLine.SetTexture, f.footerLine, Theme.TEX.separator)
    f.footerLine:SetVertexColor(0.3, 0.3, 0.3, 1)
    f:SetScript("OnSizeChanged", function(self, width, height)
        if not self.resizing then return end
        self.list:SetWidth(width - 12)
        self.footerLine:ClearAllPoints()
        self.footerLine:SetPoint("TOPLEFT", self, "TOPLEFT", 12, -(height - FOOTER))
        self.footerLine:SetPoint("TOPRIGHT", self, "TOPRIGHT", -12, -(height - FOOTER))
    end)

    f.guideBtn = Theme.NewButton(f, "Details", 104, 24, function() QG:ToggleInfo() end, "compass")
    f.guidesBtn = Theme.NewButton(f, "Guides", 104, 24, function() ns.UI:TogglePicker() end, "current")
    f.guideBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 9)
    f.guidesBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 9)

    -- the skull button: a secure button whose click runs "/targetexact <mob>" for the current kill
    -- step (the one way an addon may change the target). Secure frames cannot be moved or shown in
    -- combat, so it is anchored once, between Guide and Guides, and simply stays.
    if ns.MobMarker and ns.MobMarker.TargetButton then
        local tb = ns.MobMarker:TargetButton()
        if tb then
            tb:SetParent(f)
            tb:ClearAllPoints()
            tb:SetSize(30, 24)
            tb:SetPoint("BOTTOM", f, "BOTTOM", 0, 9)
            tb:SetFrameLevel(f:GetFrameLevel() + 5)
            local normal = tb:CreateTexture(nil, "BACKGROUND")
            normal:SetAllPoints()
            pcall(normal.SetTexture, normal, Theme.TEX.button)
            normal:SetVertexColor(0.18, 0.18, 0.18, 1)
            local hl = tb:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            pcall(hl.SetTexture, hl, Theme.TEX.buttonHl)
            hl:SetVertexColor(0.35, 0.35, 0.35, 1)
            pcall(hl.SetBlendMode, hl, "ADD")
            pcall(hl.SetAlpha, hl, 0.35)
            local skull = tb:CreateTexture(nil, "ARTWORK")
            skull:SetSize(20, 20)
            skull:SetPoint("CENTER")
            pcall(skull.SetTexture, skull, Theme.TEX.skullBtn)
            tb:SetScript("OnEnter", function(self)
                local tt = rawget(_G, "GameTooltip")
                if not tt then return end
                tt:SetOwner(self, "ANCHOR_TOP")
                tt:AddLine("Target the nearest quest mob", 1, 0.88, 0.55)
                local key = ns.MobMarker:TargetKey()
                tt:AddLine(key and ("Key: " .. key) or "Bind a key: Key Bindings > AddOns > ForeverGuide", 0.85, 0.82, 0.75, true)
                tt:AddLine("Press again if the first one is taken.", 0.66, 0.61, 0.52, true)
                tt:Show()
            end)
            tb:SetScript("OnLeave", function() local tt = rawget(_G, "GameTooltip") if tt then tt:Hide() end end)
            f.targetBtn = tb
        end
    end

    f.elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + (elapsed or 0)
        if self.elapsed < math.max(0.25, ns.db.nav.updateInterval or 0.1) then return end
        self.elapsed = 0
        local okU, err = pcall(function() self.list:UpdateDistances(false) end)
        if not okU then ns.ReportOnce("qg:distances", err) end
    end)

    f:SetScript("OnShow", function() QG:ApplyTracker() end)
    f:SetScript("OnHide", function() QG:ApplyTracker() end)
    self.frame = f
    self:Apply()
    if not cfg.shown then f:Hide() end
    return f
end

-- ---- Blizzard's own objective tracker: out of the way while the Quest Guide shows ----
local trackerHooked = false
function QG:ApplyTracker()
    local tracker = rawget(_G, "ObjectiveTrackerFrame") or rawget(_G, "QuestWatchFrame")
    if not tracker then return end
    -- the tracker lives in an Edit-Mode managed container that keeps re-showing it, so
    -- it is faded out and made click-through rather than hidden
    -- while the guide is away (hidden, or stepped aside in a dungeon) Blizzard's tracker is the
    -- only thing left to read the dungeon quests from, so it goes back to normal
    local away = (ns.UI and ns.UI.AllHidden and ns.UI:AllHidden()) or ns.db.ui.hiddenAll
    local want = ns.db.ui.hideTracker ~= false and frame and frame:IsShown() and not away
    if want then
        pcall(tracker.SetAlpha, tracker, 0)
        pcall(tracker.EnableMouse, tracker, false)
        if not trackerHooked and tracker.HookScript then
            trackerHooked = true
            pcall(tracker.HookScript, tracker, "OnShow", function(self)
                if QG.trackerHidden then pcall(self.SetAlpha, self, 0) end
            end)
        end
        QG.trackerHidden = true
    elseif QG.trackerHidden then
        QG.trackerHidden = false
        pcall(tracker.SetAlpha, tracker, 1)
        pcall(tracker.EnableMouse, tracker, true)
    end
end

--- Push scale / opacity / width from the settings to the frame.
function QG:Apply()
    if not frame then return end
    local cfg = ns.db.ui
    pcall(frame.SetScale, frame, cfg.scale or 1)
    frame:SetWidth(math.max(cfg.width or 300, 240))
    frame.list:SetWidth(frame:GetWidth() - 12)
    if frame.SetBackdropColor then pcall(frame.SetBackdropColor, frame, 0, 0, 0, cfg.opacity or 0.75) end
    self:Layout()
end

function QG:Layout()
    if not frame then return end
    local f = frame
    local natural = ns.QuestGuideHeader.HEIGHT + 2 + (f.list.height or 40) + 4 + FOOTER
    local height = math.max(120, math.min(800, ns.db.ui.height or natural))
    f:SetHeight(height)
    f.footerLine:ClearAllPoints()
    f.footerLine:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -(height - FOOTER))
    f.footerLine:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -(height - FOOTER))
    if f.scroll then
        local viewport = height - ns.QuestGuideHeader.HEIGHT - 2 - 4 - FOOTER
        local at = f.scroll:GetVerticalScroll()
        local top = 4
        for i, entry in ipairs(f.list.entries) do
            if entry.state == "active" then
                local bottom = top + f.list.rows[i]:GetHeight()
                if top < at then at = top elseif bottom > at + viewport then at = bottom - viewport end
                break
            end
            top = top + f.list.rows[i]:GetHeight() + 3
        end
        f.scroll:SetVerticalScroll(math.max(0, math.min(at, math.max(0, f.list.height - viewport))))
    end
end

-- ---- entries ---------------------------------------------------------------------------
local function questTitle(step)
    if step.questName and step.questName ~= "" then return step.questName end
    if step.quest and ns.DB and ns.DB:IsLoaded() then
        local q = ns.DB:GetQuest(step.quest)
        if q and q.n then return q.n end
    end
    return nil
end

--- What the row says under the quest name.
local function subtitle(G, step, idx)
    local t = step.type
    local DB = ns.DB
    if t == "ACCEPT" then
        local who = step.npcName or (step.npc and DB and DB:NPCName(step.npc))
        return who and ("Accept from " .. who) or "Accept the quest"
    elseif t == "TURNIN" then
        local who = step.npcName or (step.npc and DB and DB:NPCName(step.npc))
        return who and ("Turn in to " .. who) or "Turn in"
    elseif t == "KILL" or t == "COLLECT" or t == "COMPLETE" then
        local verb = t == "KILL" and "Kill" or (t == "COLLECT" and "Collect" or "Complete")
        local target = step.target
        if not target and step.quest and DB and DB:IsLoaded() then
            local objs = DB:QuestObjectives(step.quest)
            local o = objs[G:StepObjectiveIndex(step) or 1]
            target = o and o.name
        end
        local text = target and string.format("%s%s %s", verb, step.count and (" " .. step.count) or "", target) or (step.note or verb)
        local prog = G:GetStepProgress(step)
        if prog and prog:find("^%d+ / %d+") then text = text .. "  (" .. prog .. ")" end
        return text
    elseif t == "GRIND" then
        return step.note or ("Grind to level " .. tostring(step.level))
    elseif t == "TRAVEL" or t == "FLY" then
        return step.note or ("Go to " .. tostring(step.zone or ""))
    elseif t == "NOTE" then
        return nil
    end
    return G:GetStepText(step)
end

local function rowTitle(G, step)
    local t = step.type
    if step.quest then return questTitle(step) or G:GetStepText(step) end
    if t == "NOTE" then return step.text or "Note" end
    if t == "GRIND" then return "Grind to level " .. tostring(step.level) end
    if t == "TRAVEL" or t == "FLY" then return (step.zone and ("Travel to " .. step.zone)) or "Travel" end
    if t == "HEARTH" then return "Set your hearthstone" end
    return G:GetStepText(step)
end

function QG:BuildGuideEntries()
    local G = ns.Guide
    local g = G.active
    local cur, total = G:GetStepCount()
    local cfg = ns.db.ui
    local maxRows = math.max(3, cfg.maxRows or 7)
    local prevWanted = cfg.showCompleted ~= false and math.min(cfg.showPrevious or 2, 2) or 0
    local entries = {}
    -- previous (done) rows
    local prev = {}
    local i = cur - 1
    while i >= 1 and #prev < prevWanted do
        local s = g.steps[i]
        if s and G:StepApplies(s) then table.insert(prev, 1, i) end
        i = i - 1
    end
    -- current + upcoming
    local idxs = {}
    for _, p in ipairs(prev) do idxs[#idxs + 1] = p end
    local j = cur
    while j <= total and #idxs < maxRows do
        local s = g.steps[j]
        if s and G:StepApplies(s) and (j == cur or not G:IsStepDone(s, j) or cfg.showCompleted ~= false) then idxs[#idxs + 1] = j end
        j = j + 1
    end
    local upcoming = 0
    for _, idx in ipairs(idxs) do
        local s = g.steps[idx]
        local state
        if idx < cur or (idx > cur and G:IsStepDone(s, idx)) then state = "done"
        elseif idx == cur then state = "active"
        elseif s.optional or (G.postponed and G.postponed[idx] and ns.Now() < G.postponed[idx]) then state = "optional"
        else
            upcoming = upcoming + 1
            state = upcoming <= 2 and "available" or "future"
        end
        if idx == cur and G.IsStepBlocked and G:IsStepBlocked(s) and G.note then state = "blocked" end
        local sub = subtitle(G, s, idx)
        if G.postponed and G.postponed[idx] and ns.Now() < G.postponed[idx] and state ~= "done" then
            sub = string.format("postponed - crowded (back in %d min)", math.ceil((G.postponed[idx] - ns.Now()) / 60))
        end
        local gate = G.LevelGate and G:LevelGate(s)
        local deferred = s.quest and G.progress and G.progress.deferred and G.progress.deferred[s.quest]
        if state ~= "done" and (gate or (deferred and not ns.Quest:IsOnQuest(s.quest))) then
            state = "blocked"
            local q = ns.DB and ns.DB:GetQuest(s.quest)
            sub = string.format("Needs level %d - skipped until then", gate or (q and q.req) or 0)
        end
        local e = {
            number = idx, index = idx, step = s, icon = ICON_FOR[s.type] or "accept", state = state,
            title = rowTitle(G, s), subtitle = sub, questID = s.quest,
            onClick = function() G:SetStep(idx) end,
            onRightClick = function() if idx == G.current then G:Skip() end end,
        }
        local tip = {}
        local eff = ns.Editor and ns.Editor:Effective(s) or s
        if eff.note and eff.note ~= "" then tip[#tip + 1] = eff.note .. (eff.hasEdit and "  (edited)" or "") end
        if s.quest and ns.Quest then
            local grey = ns.Quest:GreyWarning(s.quest)
            if grey then tip[#tip + 1] = "|cffff8040" .. grey .. "|r" end
        end
        tip[#tip + 1] = "|cff8a8070Left click: jump here.  Right click on the current step: skip it.|r"
        e.tooltip = tip
        entries[#entries + 1] = e
    end
    return entries, cur, total
end

function QG:BuildTrackerEntries()
    local T = ns.Tracker
    local entries = {}
    for i, c in ipairs(T.candidates) do
        if i > (ns.db.ui.maxRows or 7) then break end
        entries[#entries + 1] = {
            number = i, icon = c.kind == "turnin" and "turnin" or (c.kind == "kill" and "kill" or "collect"), state = i == 1 and "active" or (i <= 3 and "available" or "future"),
            title = ns.Quest:TitleWithLevel(c.questID, c.title), subtitle = c.what, loc = c.loc, questID = c.questID,
            tooltip = { c.loc and ns.DB:DescribeLocation(c.loc) or "", c.grey and ("|cffff8040" .. c.grey .. "|r") or nil },
        }
    end
    return entries
end

-- ---- refresh -------------------------------------------------------------------------------
function QG:Refresh()
    if not frame then return end
    local f = frame
    self:ApplyTracker()
    local G, T = ns.Guide, ns.Tracker
    local g = G.active
    local level = ns.Player:GetLevel()
    local zone = ns.Player:GetMapName() or ns.Player:GetZone() or ""

    if T and T:IsActive() and (not g or ns.char.mode == "auto") then
        local entries = self:BuildTrackerEntries()
        f.header:Set(string.format("%d", #T.candidates), string.format("Auto mode  ·  quest log  ·  Lv %d  %s", level, zone))
        f.list:Set(entries, #ns.Quest.order == 0 and "Pick up some quests - auto mode tracks your quest log." or "No known locations for your quests yet.")
        self:Layout()
        return
    end
    if not g then
        f.header:Set("", string.format("Lv %d  ·  %s", level, zone))
        f.list:Set({}, "No guide active.\nClick Guides to pick a route (or /fg guides).")
        self:Layout()
        return
    end
    local entries, cur, total = self:BuildGuideEntries()
    local bagTag, bagFull = ns.Bags and ns.Bags:Tag()
    local sub = string.format("%s  ·  Lv %d", g.name or g.id, level)
    -- "Lv 18 -> 19 in 1h 0m" while the pace is known
    local pace = ns.Pace and ns.Pace:Tag()
    if pace then sub = sub .. "  ·  " .. pace end
    if bagTag then sub = (bagFull and "|cffff5040" or "|cffffa040") .. bagTag .. "|r  ·  " .. sub end
    f.header:Set(string.format("%d / %d", math.min(cur, total), total), sub)
    if cur > total then
        f.list:Set({}, "Guide complete!" .. (g.next and ("\nNext chapter: " .. g.next) or ""))
    else
        f.list:Set(entries)
    end
    self:Layout()
end

-- ---- the "Details" info popup --------------------------------------------------------------
local info
function QG:CreateInfo()
    if info then return info end
    local ok, p = pcall(CreateFrame, "Frame", "ForeverGuideInfo", UIParent, "BackdropTemplate")
    if not ok or not p then p = CreateFrame("Frame", "ForeverGuideInfo", UIParent) end
    info = p
    p:SetSize(360, 200)
    p:SetFrameStrata("DIALOG")
    p:EnableMouse(true)
    p:SetMovable(true)
    p:SetClampedToScreen(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", function(self) self:StartMoving() end)
    p:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    Theme.Backdrop(p, "panel", 0.75)
    p.title = Theme.NewText(p, { fancy = true, size = 15, color = Theme.C.goldLight, maxLines = 2 })
    p.title:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -12)
    p.title:SetPoint("TOPRIGHT", p, "TOPRIGHT", -44, -12)
    p.body = Theme.NewText(p, { size = 11, color = Theme.C.text, maxLines = 12 })
    p.body:SetPoint("TOPLEFT", p.title, "BOTTOMLEFT", 0, -8)
    p.body:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, 0)
    p.back = Theme.NewButton(p, "Back", 66, 22, function() ns.Guide:Back() QG:RefreshInfo() end)
    p.skip = Theme.NewButton(p, "Skip", 66, 22, function() ns.Guide:Skip() QG:RefreshInfo() end)
    p.auto = Theme.NewButton(p, "Auto", 66, 22, function() ns.Tracker:SetMode(ns.char.mode == "auto" and "guide" or "auto") QG:RefreshInfo() end)
    p.resync = Theme.NewButton(p, "Resync", 66, 22, function() ns.Commands:Run("resync") QG:RefreshInfo() end)
    p.close = Theme.NewButton(p, "x", 26, 20, function() info:Hide() end)
    p.back:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 12, 10)
    p.skip:SetPoint("LEFT", p.back, "RIGHT", 6, 0)
    p.auto:SetPoint("LEFT", p.skip, "RIGHT", 6, 0)
    p.resync:SetPoint("LEFT", p.auto, "RIGHT", 6, 0)
    p.close:SetPoint("TOPRIGHT", p, "TOPRIGHT", -8, -8)
    p:Hide()
    return p
end

function QG:RefreshInfo()
    if not info or not info:IsShown() then return end
    local G = ns.Guide
    local g = G.active
    local lines = {}
    if g then
        info.title:SetText(g.name or g.id)
        local cur, total = G:GetStepCount()
        lines[#lines + 1] = string.format("|cffdeb24aStep %d of %d|r", math.min(cur, total), total)
        local step = G:GetCurrentStep()
        if step then
            lines[#lines + 1] = G:GetStepText(step)
            local prog = G:GetStepProgress(step)
            if prog and prog ~= "" then lines[#lines + 1] = "|cffa89e8e" .. prog .. "|r" end
            local _, _, _, _, loc = ns.Navigation:ResolveStep(step)
            if loc then lines[#lines + 1] = "|cffa89e8e" .. ns.DB:DescribeLocation(loc) .. "|r" end
            local eff = ns.Editor and ns.Editor:Effective(step) or step
            if eff.note and eff.note ~= "" then lines[#lines + 1] = "|cffff8040" .. eff.note .. "|r" end
        else
            lines[#lines + 1] = "Guide complete!" .. (g.next and ("  Next: " .. g.next) or "")
        end
        if G.note then lines[#lines + 1] = "|cffff8040" .. G.note .. "|r" end
        local bags = ns.Bags and ns.Bags:Advice()
        if bags then lines[#lines + 1] = "|cffffa040" .. bags .. "|r" end
        if g.notes then lines[#lines + 1] = " " lines[#lines + 1] = "|cff8a8070" .. g.notes .. "|r" end
        info.auto:SetText(ns.char.mode == "auto" and "Guide" or "Auto")
        info.auto.label:SetText(ns.char.mode == "auto" and "Guide" or "Auto")
    else
        info.title:SetText("No guide active")
        lines[#lines + 1] = "Pick a route with the Guides button, or /fg guides. Auto mode tracks your quest log without a guide."
    end
    info.body:SetText(table.concat(lines, "\n"))
    local titleH = info.title.GetStringHeight and info.title:GetStringHeight() or 18
    local bodyH = info.body.GetStringHeight and info.body:GetStringHeight() or 60
    info:SetHeight(math.max(140, 12 + titleH + 8 + bodyH + 16 + 22 + 12))
    info.back:SetShown(g ~= nil) info.skip:SetShown(g ~= nil) info.resync:SetShown(g ~= nil)
end

function QG:ToggleInfo()
    local p = self:CreateInfo()
    if p:IsShown() then p:Hide() return end
    p:ClearAllPoints()
    if frame then p:SetPoint("TOPRIGHT", frame, "TOPLEFT", -12, 0) else p:SetPoint("CENTER") end
    p:Show()
    self:RefreshInfo()
end

function QG:OnInit()
    ns.Events:Register("FG_LOCK_CHANGED", function(_, locked)
        if frame and frame.resizeGrip then frame.resizeGrip:SetShown(not locked) end
    end)
    ns.Events:RegisterMany({ "FG_STEP_CHANGED", "FG_STEP_UPDATED", "FG_GUIDE_CHANGED", "FG_MODE_CHANGED", "FG_QUEST_LOG_CHANGED" },
        function() if info and info:IsShown() then ns.Events:Debounce("qginfo", 0.1, function() QG:RefreshInfo() end) end end)
end
