-- ============================================================
-- ForeverGuide / UI.lua
-- Coordinator of the on-screen parts. The window itself is
-- UI/QuestGuideFrame.lua (header, list, rows), the in-world waypoint is
-- UI/QuestWaypoint.lua (+ QuestRoute.lua), the compact chevron is
-- Arrow.lua. This module keeps the public surface the rest of the addon
-- and the tests use: Show / Hide / Toggle / Refresh / Layout /
-- UpdateNavigation / TogglePicker / hide-in-combat / hide-everything.
-- ============================================================

local _, ns = ...
local UI = ns:NewModule("UI")
local Theme = ns.Theme

local function frame() return ns.QuestGuide and ns.QuestGuide.frame end

function UI:Create()
    return ns.QuestGuide:Create()
end

function UI:Layout()
    ns.QuestGuide:Layout()
end

function UI:Refresh()
    if not frame() then return end
    local ok, err = pcall(ns.QuestGuide.Refresh, ns.QuestGuide)
    if not ok then ns.ReportOnce("ui:refresh", err) end
    self:UpdateNavigation(true)
end

--- Distances of the rows (the waypoint and the arrow keep themselves current).
function UI:UpdateNavigation(force)
    local f = frame()
    if not f or (not f:IsShown() and not force) then return end
    if ns.Navigation.target then ns.Navigation:Update(true) end
    if f.list then f.list:UpdateDistances(false) end
end

-- ------------------------------------------------------------
-- Guide picker
-- ------------------------------------------------------------
local picker
local PAD = 12

function UI:CreatePicker()
    if picker then return picker end
    local ok, p = pcall(CreateFrame, "Frame", "ForeverGuidePicker", UIParent, "BackdropTemplate")
    if not ok or not p then p = CreateFrame("Frame", "ForeverGuidePicker", UIParent) end
    picker = p
    p:SetSize(math.max(ns.db.ui.width or 300, 300), 100)
    p:SetFrameStrata("DIALOG")
    p:EnableMouse(true)
    p:SetClampedToScreen(true)
    Theme.Backdrop(p, "panel", 0.75)

    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(18, 18)
    p.icon:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -10)
    p.icon:Hide()
    p.title = Theme.NewText(p, { fancy = true, size = 15, color = Theme.C.goldLight, oneLine = true })
    p.title:SetPoint("LEFT", p.icon, "RIGHT", 6, 0)
    p.title:SetText("GUIDES")
    p.hint = Theme.NewText(p, { size = 10, color = Theme.C.textDim, oneLine = true })
    p.hint:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 2, -32)
    p.hint:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, -32)
    p.hint:SetText("pick a route, a chapter, or a single zone - dimmed = outside your level")
    p.line = p:CreateTexture(nil, "ARTWORK")
    p.line:SetHeight(1)
    p.line:SetPoint("TOPLEFT", p, "TOPLEFT", 6, -44)
    p.line:SetPoint("TOPRIGHT", p, "TOPRIGHT", -6, -44)
    pcall(p.line.SetTexture, p.line, Theme.TEX.headerLine)
    p.line:SetVertexColor(0.3, 0.3, 0.3, 1)

    p.close = Theme.NewButton(p, "x", 26, 20, function() p:Hide() end)
    p.close:SetPoint("TOPRIGHT", p, "TOPRIGHT", -8, -8)

    p.rows = {}
    p:Hide()
    return p
end

local function PickerRow(p, i)
    local row = p.rows[i]
    if row then return row end
    local btn = CreateFrame("Button", nil, p)
    btn:SetHeight(22)
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    pcall(hl.SetTexture, hl, Theme.TEX.rowActive)
    hl:SetVertexColor(0.3, 0.3, 0.3, 0.7)
    btn.active = btn:CreateTexture(nil, "BACKGROUND")
    btn.active:SetAllPoints()
    pcall(btn.active.SetTexture, btn.active, Theme.TEX.rowActive)
    btn.active:SetVertexColor(0.24, 0.28, 0.34, 0.65)
    btn.active:Hide()
    btn.label = Theme.NewText(btn, { size = 12, oneLine = true })
    btn.label:SetPoint("LEFT", btn, "LEFT", 8, 0)
    pcall(btn.label.SetJustifyV, btn.label, "MIDDLE")
    btn.sub = Theme.NewText(btn, { size = 10, justify = "RIGHT", color = Theme.C.textDim, oneLine = true })
    btn.sub:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
    btn.sub:SetWidth(112)
    pcall(btn.sub.SetJustifyV, btn.sub, "MIDDLE")
    btn.label:SetPoint("RIGHT", btn.sub, "LEFT", -4, 0)
    btn:SetScript("OnClick", function(self)
        if self.header then return end
        if self.onClick then
            local okc, err = pcall(self.onClick)
            if not okc then ns.ReportOnce("picker:route", err) end
        elseif self.guideID == "__auto" then
            ns.Tracker:SetMode("auto")
        elseif self.guideID then
            ns.Guide:Activate(self.guideID)
            ns.Tracker:SetMode("guide")
        end
        p:Hide()
        UI:Refresh()
    end)
    -- the tests drive rows through SetText / GetText like a plain button
    btn.SetText = function(self, t) self.label:SetText(t) end
    btn.GetText = function(self) return self.label:GetText() end
    p.rows[i] = btn
    return btn
end

function UI:RefreshPicker()
    local p = self:CreatePicker()
    local G = ns.Guide
    p:SetWidth(math.max(ns.db.ui.width or 300, 320))
    local y = 54
    local i = 0
    local level = ns.Player:GetLevel()
    local function add(text, sub, id, dim, active, header, onClick)
        i = i + 1
        local row = PickerRow(p, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", p, "TOPLEFT", PAD - 4, -y)
        row:SetPoint("TOPRIGHT", p, "TOPRIGHT", -(PAD - 4), -y)
        row:SetText(text)
        row.sub:SetText(sub or "")
        row.guideID = id
        row.onClick = onClick
        row.header = header
        if header then
            Theme.Color(row.label, Theme.C.gold)
            row.active:Hide()
            row:SetAlpha(1)
            row:EnableMouse(false)
            row:SetHeight(18)
            y = y + 18 + 2
        else
            Theme.Color(row.label, active and Theme.C.goldLight or (dim and Theme.C.muted or Theme.C.text))
            row.active:SetShown(active and true or false)
            row:SetAlpha(dim and 0.6 or 1)
            row:EnableMouse(true)
            row:SetHeight(22)
            y = y + 22 + 2
        end
        row:Show()
        row.sub:Show()
    end
    if ns.DB and ns.DB:IsLoaded() then
        add("Auto mode - follow my quest log", ns.char.mode == "auto" and "active" or "", "__auto", false, ns.char.mode == "auto")
    end
    -- routes: pick any of your faction's, your race's is only the default
    local routes = G:Routes()
    local current = G:CurrentRoute()
    if #routes > 0 then
        add("ROUTES", "", nil, false, false, true)
        for _, r in ipairs(routes) do
            local sub = string.format("%d chapters%s", #r.chapters, r.mine and "  ·  your race" or "")
            add(r.label .. " route", sub, nil, not r.mine and not r.chosen, current and current.key == r.key, false,
                function() G:ChooseRoute(r.key) end)
        end
    end
    -- chapters of the route we follow, around the level
    if current then
        add("CHAPTERS  -  " .. current.label:upper() .. " ROUTE", "", nil, false, false, true)
        local list = current.chapters
        local start = 1
        for k, g in ipairs(list) do if (g.maxLevel or 60) >= level - 2 then start = math.max(1, k - 2) break end end
        local shown = 0
        for k = start, #list do
            local g = list[k]
            if shown >= 9 then break end
            local fits = (g.minLevel or 1) <= level + 3 and (g.maxLevel or 60) >= level - 2
            local prog = ns.char.guides and ns.char.guides[g.id]
            local progText = ""
            if prog and prog.step and prog.step > 1 then
                if prog.step > ns.Guide.StepCount(g) then progText = "  done"
                else progText = string.format("  step %d/%d", prog.step, ns.Guide.StepCount(g)) end
            end
            local active = G.active == g and ns.char.mode ~= "auto"
            add(g.name or g.id, string.format("%s-%s  %d steps%s", tostring(g.minLevel or "?"), tostring(g.maxLevel or "?"), ns.Guide.StepCount(g), progText), g.id, not fits, active)
            shown = shown + 1
        end
    end
    -- zone guides near the level: quest a zone on its own, whatever the route says
    local zones = {}
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if id:match("^GEN_ZONE_") and G:Applicable(g) and (g.maxLevel or 60) >= level - 2 and (g.minLevel or 1) <= level + 6 then zones[#zones + 1] = g end
    end
    table.sort(zones, function(a, b)
        if (a.minLevel or 0) ~= (b.minLevel or 0) then return (a.minLevel or 0) < (b.minLevel or 0) end
        return (a.name or a.id) < (b.name or b.id)
    end)
    if #zones > 0 then
        add("ZONE GUIDES", "", nil, false, false, true)
        for k, g in ipairs(zones) do
            if k > 7 then break end
            local fits = (g.minLevel or 1) <= level + 3 and (g.maxLevel or 60) >= level - 2
            local active = G.active == g and ns.char.mode ~= "auto"
            add((g.name or g.id):gsub("^Zone: ", ""), string.format("%s-%s  %d steps", tostring(g.minLevel or "?"), tostring(g.maxLevel or "?"), ns.Guide.StepCount(g)), g.id, not fits, active)
        end
    end
    -- hand-written guides (anything else registered)
    local others = 0
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if not id:match("^GEN_") and G:Applicable(g) then
            if others == 0 then add("OTHER GUIDES", "", nil, false, false, true) end
            others = others + 1
            if others <= 4 then add(g.name or g.id, string.format("%s-%s", tostring(g.minLevel or "?"), tostring(g.maxLevel or "?")), g.id, false, G.active == g and ns.char.mode ~= "auto") end
        end
    end
    if i == 0 then add("no guides installed", "", nil, true) end
    for j = i + 1, #p.rows do p.rows[j]:Hide() p.rows[j].sub:Hide() end
    p:SetHeight(y + PAD)
    p:ClearAllPoints()
    local f = frame()
    if f then p:SetPoint("TOPRIGHT", f, "TOPLEFT", -12, 0) else p:SetPoint("CENTER") end
end

function UI:TogglePicker()
    local p = self:CreatePicker()
    if p:IsShown() then p:Hide() return end
    self:RefreshPicker()
    p:Show()
end

-- ------------------------------------------------------------
-- Public
-- ------------------------------------------------------------
function UI:Show()
    self:Create()
    if ns.db.ui.hiddenAll then self:SetAllHidden(false, true) end
    frame():Show()
    ns.db.ui.shown = true
    self:Refresh()
end

function UI:Hide()
    local f = frame()
    if f then f:Hide() end
    ns.db.ui.shown = false
end

function UI:Toggle()
    local f = frame()
    if f and f:IsShown() then self:Hide() else self:Show() end
end

-- ------------------------------------------------------------
-- "Hide everything" (alt-click the minimap button, /fg hideall)
-- One switch that takes the window, the waypoint and the arrow off the
-- screen and puts back exactly what was showing. The addon keeps working
-- while hidden - steps still advance, auto-accept still fires.
-- ------------------------------------------------------------
--- "Everything is out of the way right now" - either because the player asked for it
--- (hiddenAll, a setting) or because something suspended it for a while (a dungeon).
--- Every banner and marker asks this before showing itself.
function UI:AllHidden()
    if ns.db.ui.hiddenAll then return true end
    return next(self.suspended or {}) ~= nil
end

--- Put the window, arrow and markers away without touching the player's settings, and give
--- Blizzard's own objective tracker back while they are away. Reasons stack ("dungeon", ...).
function UI:Suspend(on, reason)
    reason = reason or "other"
    self.suspended = self.suspended or {}
    local was = next(self.suspended) ~= nil
    self.suspended[reason] = on and true or nil
    local now = next(self.suspended) ~= nil
    if was == now then return now end
    local f = frame()
    if now then
        if f then f:Hide() end
    elseif not ns.db.ui.hiddenAll and ns.db.ui.shown ~= false then
        self:Create()
        if f or frame() then (f or frame()):Show() end
        self:Refresh()
    end
    if ns.Arrow and ns.Arrow.HideTemporarily then ns.Arrow:HideTemporarily(now, "suspend") end
    if ns.Waypoint and ns.Waypoint.HideTemporarily then ns.Waypoint:HideTemporarily(now, "suspend") end
    if ns.QuestGuide and ns.QuestGuide.ApplyTracker then ns.QuestGuide:ApplyTracker() end
    ns.Events:Fire("FG_HIDDEN_ALL_CHANGED", now)
    return now
end

function UI:IsSuspended(reason)
    if not self.suspended then return false end
    if reason then return self.suspended[reason] == true end
    return next(self.suspended) ~= nil
end

function UI:SetAllHidden(on, keepWindow)
    on = on and true or false
    local u = ns.db.ui
    if on == (u.hiddenAll and true or false) then return on end
    local f = frame()
    if on then
        u.hiddenAllPrev = { window = (f and f:IsShown()) and true or false }
        u.hiddenAll = true
        if f then f:Hide() end
        if ns.Arrow and ns.Arrow.HideTemporarily then ns.Arrow:HideTemporarily(true, "hideall") end
        if ns.Waypoint and ns.Waypoint.HideTemporarily then ns.Waypoint:HideTemporarily(true, "hideall") end
    else
        local prev = u.hiddenAllPrev or { window = true }
        u.hiddenAll = false
        u.hiddenAllPrev = nil
        if ns.Arrow and ns.Arrow.HideTemporarily then ns.Arrow:HideTemporarily(false, "hideall") end
        if ns.Waypoint and ns.Waypoint.HideTemporarily then ns.Waypoint:HideTemporarily(false, "hideall") end
        if not keepWindow then
            if prev.window then self:Show() else self:Hide() end
        end
    end
    if ns.QuestGuide.ApplyTracker then ns.QuestGuide:ApplyTracker() end
    ns.Events:Fire("FG_HIDDEN_ALL_CHANGED", on)
    return on
end

function UI:ToggleAll()
    return self:SetAllHidden(not self:AllHidden())
end

function UI:SetScale(scale)
    ns.db.ui.scale = scale
    ns.QuestGuide:Apply()
end

function UI:ResetPosition()
    local d = ns.Database.DEFAULTS.ui
    ns.db.ui.point, ns.db.ui.x, ns.db.ui.y = d.point, d.x, d.y
    local f = frame()
    if f then
        f:ClearAllPoints()
        f:SetPoint(d.point, UIParent, d.point, d.x, d.y)
    end
end

function UI:OnInit()
    local function refresh() UI:Refresh() end
    ns.Events:RegisterMany({
        "FG_STEP_CHANGED", "FG_STEP_UPDATED", "FG_GUIDE_CHANGED", "FG_QUEST_LOG_CHANGED",
        "FG_LEVEL_CHANGED", "FG_ZONE_CHANGED", "FG_QUEST_TITLE_LOADED", "FG_NAV_TARGET_CHANGED",
        "FG_TRACKER_CHANGED", "FG_MODE_CHANGED",
    }, function() ns.Events:Debounce("ui", 0.05, refresh) end)
end

-- the fullscreen world map: the window steps aside while it is open (option hideOnMap)
local mapHidden
function UI:OnMap(open)
    local f = frame()
    if not f then return end
    if open then
        if ns.db.ui.hideOnMap == false or ns.db.ui.hiddenAll then return end
        if f:IsShown() then mapHidden = true f:Hide() end
    elseif mapHidden then
        mapHidden = nil
        if not ns.db.ui.hiddenAll and ns.db.ui.shown ~= false then f:Show() end
    end
end

-- hide in combat (optional): remember what was showing, restore afterwards
local combatHidden
function UI:OnCombat(inCombat)
    local f = frame()
    if inCombat then
        if not ns.db.ui.hideInCombat or ns.db.ui.hiddenAll then return end
        combatHidden = { window = f and f:IsShown() }
        if f then f:Hide() end
        if ns.Arrow and ns.Arrow.HideTemporarily then ns.Arrow:HideTemporarily(true) end
        if ns.Waypoint and ns.Waypoint.HideTemporarily then ns.Waypoint:HideTemporarily(true) end
    elseif combatHidden then
        if combatHidden.window and f and not ns.db.ui.hiddenAll then f:Show() end
        if ns.Arrow and ns.Arrow.HideTemporarily then ns.Arrow:HideTemporarily(false) end
        if ns.Waypoint and ns.Waypoint.HideTemporarily then ns.Waypoint:HideTemporarily(false) end
        combatHidden = nil
        self:Refresh()
    end
end

function UI:OnEnable()
    self:Create()
    local f = frame()
    if ns.db.ui.hiddenAll then
        f:Hide()
        if ns.Arrow and ns.Arrow.HideTemporarily then ns.Arrow:HideTemporarily(true, "hideall") end
        if ns.Waypoint and ns.Waypoint.HideTemporarily then ns.Waypoint:HideTemporarily(true, "hideall") end
    elseif ns.db.ui.shown then
        f:Show()
    end
    self:Refresh()
    ns.Events:Register("PLAYER_REGEN_DISABLED", function() UI:OnCombat(true) end)
    ns.Events:Register("PLAYER_REGEN_ENABLED", function() UI:OnCombat(false) end)
end
