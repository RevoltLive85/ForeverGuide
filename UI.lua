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
    Theme.Backdrop(p, "panel", 0.96)

    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(18, 18)
    p.icon:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -10)
    Theme.SetIcon(p.icon, "current")
    p.title = Theme.NewText(p, { fancy = true, size = 15, color = Theme.C.goldLight, oneLine = true })
    p.title:SetPoint("LEFT", p.icon, "RIGHT", 6, 0)
    p.title:SetText("GUIDES")
    p.hint = Theme.NewText(p, { size = 10, color = Theme.C.textDim, oneLine = true })
    p.hint:SetPoint("TOPLEFT", p, "TOPLEFT", PAD + 2, -32)
    p.hint:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, -32)
    p.hint:SetText("your route, chapter by chapter - dimmed = outside your level")
    p.line = p:CreateTexture(nil, "ARTWORK")
    p.line:SetHeight(8)
    p.line:SetPoint("TOPLEFT", p, "TOPLEFT", 6, -44)
    p.line:SetPoint("TOPRIGHT", p, "TOPRIGHT", -6, -44)
    pcall(p.line.SetTexture, p.line, Theme.TEX.headerLine)

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
    pcall(hl.SetAlpha, hl, 0.7)
    btn.active = btn:CreateTexture(nil, "BACKGROUND")
    btn.active:SetAllPoints()
    pcall(btn.active.SetTexture, btn.active, Theme.TEX.rowActive)
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
        if self.guideID == "__auto" then
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
    p:SetWidth(math.max(ns.db.ui.width or 300, 300))
    local y = 54
    local i = 0
    local function add(text, sub, id, dim, active)
        i = i + 1
        local row = PickerRow(p, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", p, "TOPLEFT", PAD - 4, -y)
        row:SetPoint("TOPRIGHT", p, "TOPRIGHT", -(PAD - 4), -y)
        row:SetText(text)
        row.sub:SetText(sub or "")
        row.guideID = id
        Theme.Color(row.label, active and Theme.C.goldLight or (dim and Theme.C.muted or Theme.C.text))
        row.active:SetShown(active and true or false)
        row:SetAlpha(dim and 0.6 or 1)
        row:Show()
        row.sub:Show()
        y = y + 22 + 2
    end
    if ns.DB and ns.DB:IsLoaded() then
        add("Auto mode - follow my quest log", ns.char.mode == "auto" and "active" or "", "__auto", false, ns.char.mode == "auto")
    end
    local list = {}
    for _, id in ipairs(G.list) do
        local g = G.registry[id]
        if G:Applicable(g) then list[#list + 1] = g end
    end
    local showingAll = false
    if #list == 0 then
        for _, id in ipairs(G.list) do list[#list + 1] = G.registry[id] end
        showingAll = true
    end
    table.sort(list, function(a, b)
        if (a.minLevel or 0) ~= (b.minLevel or 0) then return (a.minLevel or 0) < (b.minLevel or 0) end
        return (a.name or a.id) < (b.name or b.id)
    end)
    local level = ns.Player:GetLevel()
    -- show the chapters around the player's level (the route can be 45 chapters long)
    local start = 1
    for k, g in ipairs(list) do if (g.maxLevel or 60) >= level - 2 then start = math.max(1, k - 2) break end end
    for k = start, #list do
        local g = list[k]
        if i >= 18 then break end
        local fits = (g.minLevel or 1) <= level + 3 and (g.maxLevel or 60) >= level - 2
        local prog = ns.char.guides and ns.char.guides[g.id]
        local progText = ""
        if prog and prog.step and prog.step > 1 then
            if prog.step > #g.steps then progText = "  done"
            else progText = string.format("  step %d/%d", prog.step, #g.steps) end
        end
        local active = G.active == g and ns.char.mode ~= "auto"
        local sub = string.format("%s-%s  %d steps%s", tostring(g.minLevel or "?"), tostring(g.maxLevel or "?"), #g.steps, progText)
        add((g.name or g.id) .. (showingAll and "  [other faction/race]" or ""), sub, g.id, not fits, active)
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
function UI:AllHidden()
    return ns.db.ui.hiddenAll and true or false
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
