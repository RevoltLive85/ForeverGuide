-- ============================================================
-- ForeverGuide / UI.lua
-- The guide window.
--
--   FOREVERGUIDE                    Lv 10 - Ironforge
--   auto mode - quest log                   10 quests
--   ------------------------------------------------
--   Stocking Jetsteam                                 <- current (large)
--   1/4 Chunk of Boar Meat                            <- progress
--   Large Crag Boar - Dun Morogh 43.9, 29.7           <- where (dim)
--   [^] 746 yd, left                                  <- navigation
--   ------------------------------------------------
--   > Stocking Jetsteam                       746 yd  <- rows: one line each,
--     Beer Basted Boar Ribs                   1.0 km     right column = distance
--     Frostmane Hold                          1.0 km     or step progress
--   ------------------------------------------------
--   [Back] [Skip]                          [Guides]
--
-- Widget notes for Forever: base widgets only, BackdropTemplate (confirmed),
-- every FontString created with a real font template so SetText never hits
-- "Font not set". Single-line rows use SetMaxLines(1) for an ellipsis.
-- ============================================================

local _, ns = ...
local UI = ns:NewModule("UI")

local FONT = rawget(_G, "STANDARD_TEXT_FONT") or "Fonts\\FRIZQT__.TTF"
local ARROW_TEXTURE = "Interface\\AddOns\\ForeverGuide\\Textures\\arrow.tga"
local PAD = 12
local ROW_H = 16
local ROW_GAP = 3
local SECTION_GAP = 9
local frame, arrow

local C = {
    accent = { 0.31, 0.82, 0.77 },
    text   = { 0.95, 0.95, 0.95 },
    dim    = { 0.62, 0.62, 0.62 },
    done   = { 0.50, 0.50, 0.50 },
    now    = { 1.00, 0.85, 0.30 },
    next   = { 0.88, 0.88, 0.88 },
    warn   = { 1.00, 0.60, 0.30 },
}

-- ------------------------------------------------------------
-- Widget helpers
-- ------------------------------------------------------------
local function NewText(parent, size, template, justify, oneLine)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    fs:SetFont(FONT, size, "")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetJustifyV("TOP")
    fs:SetTextColor(unpack(C.text))
    fs:SetWordWrap(true)
    fs:SetNonSpaceWrap(false)
    if oneLine then
        local ok = pcall(fs.SetMaxLines, fs, 1)
        if not ok then fs:SetWordWrap(false) end
    end
    return fs
end

local function NewButton(parent, label, width, onClick)
    local ok, btn = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if not ok or not btn then
        btn = CreateFrame("Button", nil, parent)
        btn:SetNormalFontObject("GameFontNormal")
        btn:SetHighlightFontObject("GameFontHighlight")
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.2, 0.2, 0.2, 0.9)
    end
    btn:SetSize(width, 20)
    btn:SetText(label)
    btn:SetScript("OnClick", function() local okc, err = pcall(onClick) if not okc then ns.ReportOnce("button:" .. label, err) end end)
    return btn
end

local function ApplyBackdrop(f)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        f:SetBackdropColor(0.05, 0.05, 0.07, 0.88)
        f:SetBackdropBorderColor(0.31, 0.82, 0.77, 0.55)
    else
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.05, 0.05, 0.07, 0.88)
    end
end

local function Divider(f, anchor, gap)
    local d = f:CreateTexture(nil, "ARTWORK")
    d:SetHeight(1)
    d:SetColorTexture(0.31, 0.82, 0.77, 0.3)
    d:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, 0)
    d:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, 0)
    return d
end

-- ------------------------------------------------------------
-- Frame construction
-- ------------------------------------------------------------
function UI:Create()
    if frame then return frame end
    local cfg = ns.db.ui
    cfg.width = math.max(cfg.width or 300, 300)
    local ok, f = pcall(CreateFrame, "Frame", "ForeverGuideFrame", UIParent, "BackdropTemplate")
    if not ok or not f then f = CreateFrame("Frame", "ForeverGuideFrame", UIParent) end
    frame = f
    f:SetSize(cfg.width, 200)
    f:SetPoint(cfg.point or "CENTER", UIParent, cfg.point or "CENTER", cfg.x or 0, cfg.y or 0)
    f:SetScale(cfg.scale or 1)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not ns.db.ui.locked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        ns.db.ui.point, ns.db.ui.x, ns.db.ui.y = point or "CENTER", x or 0, y or 0
    end)
    ApplyBackdrop(f)

    local w = cfg.width - 2 * PAD
    local fs = cfg.fontSize or 12

    -- header
    f.title = NewText(f, fs + 1, "GameFontNormal", "LEFT", true)
    f.title:SetWidth(104)
    f.title:SetTextColor(unpack(C.accent))
    f.title:SetText("FOREVERGUIDE")

    f.player = NewText(f, fs - 1, "GameFontHighlightSmall", "RIGHT", true)
    f.player:SetWidth(w - 108)
    f.player:SetTextColor(unpack(C.next))

    f.mode = NewText(f, fs - 2, "GameFontHighlightSmall", "LEFT", true)
    f.mode:SetWidth(w * 0.6)
    f.mode:SetTextColor(unpack(C.dim))

    f.count = NewText(f, fs - 2, "GameFontHighlightSmall", "RIGHT", true)
    f.count:SetWidth(w * 0.4)
    f.count:SetTextColor(unpack(C.dim))

    f.div1 = Divider(f)

    -- current block
    f.current = NewText(f, fs + 3, "GameFontNormalLarge")
    f.current:SetWidth(w)
    pcall(f.current.SetMaxLines, f.current, 2)
    f.current:SetTextColor(unpack(C.now))

    f.progress = NewText(f, fs, "GameFontHighlight", "LEFT", true)
    f.progress:SetWidth(w)

    f.where = NewText(f, fs - 1, "GameFontHighlightSmall", "LEFT", true)
    f.where:SetWidth(w)
    f.where:SetTextColor(unpack(C.dim))

    f.note = NewText(f, fs - 1, "GameFontHighlightSmall")
    f.note:SetWidth(w)
    pcall(f.note.SetMaxLines, f.note, 2)
    f.note:SetTextColor(unpack(C.warn))

    arrow = f:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(18, 18)
    pcall(arrow.SetTexture, arrow, ARROW_TEXTURE)
    f.arrow = arrow

    f.nav = NewText(f, fs, "GameFontHighlight", "LEFT", true)
    f.nav:SetWidth(w - 24)

    f.div2 = Divider(f)

    -- rows
    f.rows = {}
    local maxRows = (cfg.showPrevious or 2) + (cfg.showUpcoming or 4) + 1
    for i = 1, maxRows do
        local left = NewText(f, fs - 1, "GameFontHighlightSmall", "LEFT", true)
        local right = NewText(f, fs - 1, "GameFontHighlightSmall", "RIGHT", true)
        left:SetWidth(w - 62)
        right:SetWidth(58)
        right:SetTextColor(unpack(C.dim))
        f.rows[i] = { left = left, right = right }
    end

    f.div3 = Divider(f)

    -- buttons
    f.back = NewButton(f, "Back", 58, function() ns.Guide:Back() end)
    f.skip = NewButton(f, "Skip", 58, function() ns.Guide:Skip() end)
    f.auto = NewButton(f, "Auto", 58, function() ns.Tracker:SetMode(ns.char.mode == "auto" and "guide" or "auto") end)
    f.guide = NewButton(f, "Guides", 68, function() UI:TogglePicker() end)

    f.elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed < (ns.db.nav.updateInterval or 0.1) then return end
        self.elapsed = 0
        local okU, err = pcall(UI.UpdateNavigation, UI)
        if not okU then ns.ReportOnce("ui:nav", err) end
    end)

    if not cfg.shown then f:Hide() end
    return f
end

-- ------------------------------------------------------------
-- Layout: stack everything top-down, hide empty parts
-- ------------------------------------------------------------
local function Place(region, y, x)
    region:ClearAllPoints()
    region:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (x or 0), -y)
end

function UI:Layout()
    if not frame then return end
    local f = frame
    local w = ns.db.ui.width - 2 * PAD
    local y = PAD

    Place(f.title, y)
    f.player:ClearAllPoints()
    f.player:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -y)
    y = y + ROW_H + 1
    Place(f.mode, y)
    f.count:ClearAllPoints()
    f.count:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -y)
    y = y + ROW_H - 2 + SECTION_GAP

    f.div1:ClearAllPoints()
    f.div1:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y)
    f.div1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -y)
    y = y + 1 + SECTION_GAP

    Place(f.current, y)
    y = y + math.max(ROW_H + 2, f.current:GetStringHeight()) + 4

    local function optionalLine(region, gap)
        local text = region:GetText()
        if text and text ~= "" then
            region:Show()
            Place(region, y)
            y = y + math.max(ROW_H - 2, region:GetStringHeight()) + (gap or ROW_GAP)
        else
            region:Hide()
        end
    end
    optionalLine(f.progress)
    optionalLine(f.where)
    optionalLine(f.note)

    if f.nav:GetText() ~= "" then
        f.arrow:ClearAllPoints()
        f.arrow:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y + 1)
        Place(f.nav, y, 24)
        y = y + ROW_H + 2
    end
    y = y + SECTION_GAP - 2

    f.div2:ClearAllPoints()
    f.div2:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y)
    f.div2:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -y)
    y = y + 1 + SECTION_GAP - 2

    local shown = 0
    for _, row in ipairs(f.rows) do
        local text = row.left:GetText()
        if text and text ~= "" then
            row.left:Show() row.right:Show()
            Place(row.left, y)
            row.right:ClearAllPoints()
            row.right:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -y)
            y = y + ROW_H + ROW_GAP
            shown = shown + 1
        else
            row.left:Hide() row.right:Hide()
        end
    end
    if shown > 0 then y = y - ROW_GAP end
    y = y + SECTION_GAP

    f.div3:ClearAllPoints()
    f.div3:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y)
    f.div3:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -y)
    y = y + 1 + SECTION_GAP - 2

    local autoMode = ns.Tracker and ns.Tracker:IsActive() and (not ns.Guide.active or ns.char.mode == "auto")
    f.back:SetShown(not autoMode and ns.Guide.active ~= nil)
    f.skip:SetShown(not autoMode and ns.Guide.active ~= nil)
    f.auto:SetShown(ns.Guide.active ~= nil and ns.DB and ns.DB:IsLoaded())
    f.auto:SetText(ns.char.mode == "auto" and "Guide" or "Auto")
    f.back:ClearAllPoints()
    f.back:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y)
    f.skip:ClearAllPoints()
    f.skip:SetPoint("LEFT", f.back, "RIGHT", 6, 0)
    f.auto:ClearAllPoints()
    if autoMode or not ns.Guide.active then
        f.auto:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y)
    else
        f.auto:SetPoint("LEFT", f.skip, "RIGHT", 6, 0)
    end
    f.guide:ClearAllPoints()
    f.guide:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -y)
    y = y + 20 + PAD

    f:SetHeight(y)
end

-- ------------------------------------------------------------
-- Refresh
-- ------------------------------------------------------------
local function SetRow(row, left, right, color)
    row.left:SetText(left or "")
    row.right:SetText(right or "")
    row.left:SetTextColor(unpack(color or C.next))
end

function UI:Refresh()
    if not frame then return end
    local f = frame
    local G, T, Nav = ns.Guide, ns.Tracker, ns.Navigation

    local mapName = ns.Player:GetMapName() or ns.Player:GetZone()
    f.player:SetText(string.format("Lv %d  -  %s", ns.Player:GetLevel(), mapName or ""))
    f.note:SetText("")

    local g = G.active
    if T and T:IsActive() and (not g or ns.char.mode == "auto") then
        f.mode:SetText(g and ("auto mode  (guide paused: " .. (g.name or g.id) .. ")") or "auto mode  -  quest log")
        f.count:SetText(string.format("%d quest%s", #T.candidates, #T.candidates == 1 and "" or "s"))
        local c = T.current
        if c then
            f.current:SetText(ns.Quest:TitleWithLevel(c.questID, c.title))
            f.progress:SetText(c.what)
            f.where:SetText(ns.DB:DescribeLocation(c.loc))
            if c.grey then f.note:SetText("|cffff8040" .. c.grey .. "|r") end
        else
            f.current:SetText("Nothing to track")
            f.progress:SetText(#ns.Quest.order == 0 and "pick up some quests" or "no known locations for your quests")
            f.where:SetText("")
        end
        for i, row in ipairs(f.rows) do
            local cand = T.candidates[i]
            if cand then
                SetRow(row, (i == 1 and "> " or "   ") .. ns.Quest:TitleWithLevel(cand.questID, cand.title),
                    cand.distance and Nav:FormatDistance(cand.distance) or "",
                    i == 1 and C.now or C.next)
            else
                SetRow(row, "", "")
            end
        end
        self:UpdateNavigation(true)
        self:Layout()
        return
    end

    if not g then
        f.mode:SetText("no guide active")
        f.count:SetText("")
        f.current:SetText("/fg guides to pick a guide")
        f.progress:SetText("")
        f.where:SetText("")
        f.nav:SetText("")
        arrow:Hide()
        for _, row in ipairs(f.rows) do SetRow(row, "", "") end
        self:Layout()
        return
    end

    local cur, total = G:GetStepCount()
    f.mode:SetText(g.name or g.id)
    f.count:SetText(string.format("step %d / %d", math.min(cur, total), total))

    local step = G:GetCurrentStep()
    if not step then
        f.current:SetText("Guide complete!")
        f.progress:SetText(g.next and ("Next: " .. g.next) or "")
        f.where:SetText("")
    else
        f.current:SetText(G:GetStepText(step))
        f.progress:SetText(G:GetStepProgress(step))
        local _, _, _, _, loc = Nav:ResolveStep(step)
        f.where:SetText(loc and ns.DB:DescribeLocation(loc) or (step.note or ""))
        local eff = ns.Editor and ns.Editor:Effective(step) or step
        if eff.note and eff.note ~= "" then f.note:SetText(eff.note .. (eff.edited and "  (edited)" or "")) end
        local grey = step.quest and ns.Quest:GreyWarning(step.quest)
        if grey and ns.Quest:IsOnQuest(step.quest) then f.note:SetText("|cffff8040" .. grey .. "|r")
        elseif grey and step.type == "ACCEPT" and ns.Quest:XPMultiplier(step.quest) <= 0.2 then
            f.note:SetText("|cffff8040" .. grey .. " - /fg resync skips it|r")
        end
        if G.note then f.note:SetText(G.note) end
    end

    local first = math.max(1, (cur or 1) - (ns.db.ui.showPrevious or 2))
    local ri = 1
    for idx = first, math.min(total, first + #f.rows * 2) do
        local s = g.steps[idx]
        if ri > #f.rows then break end
        if s and G:StepApplies(s) then
            local text = G:GetStepText(s)
            local color, mark, right = C.next, "   ", ""
            if idx < cur or (idx > cur and G:IsStepDone(s, idx)) then
                color, mark = C.done, "   "
                text = text
            elseif idx == cur then
                color, mark = C.now, "> "
                right = G:GetStepProgress(s)
                if right == "" or #right > 12 then right = "" end
            elseif s.optional then
                color = C.done
            end
            SetRow(f.rows[ri], mark .. text, right, color)
            ri = ri + 1
        end
    end
    for i = ri, #f.rows do SetRow(f.rows[i], "", "") end

    self:UpdateNavigation(true)
    self:Layout()
end

function UI:UpdateNavigation(force)
    if not frame or (not frame:IsShown() and not force) then return end
    local Nav = ns.Navigation
    if not Nav.target then
        frame.nav:SetText("")
        arrow:Hide()
        return
    end
    local s = Nav:Update(true)
    frame.nav:SetText(Nav:Describe())
    if s and s.angle then
        arrow:Show()
        pcall(arrow.SetRotation, arrow, s.angle)
    else
        arrow:Hide()
    end
end

-- ------------------------------------------------------------
-- Guide picker popup
-- ------------------------------------------------------------
local picker

function UI:CreatePicker()
    if picker then return picker end
    local ok, p = pcall(CreateFrame, "Frame", "ForeverGuidePicker", UIParent, "BackdropTemplate")
    if not ok or not p then p = CreateFrame("Frame", "ForeverGuidePicker", UIParent) end
    picker = p
    p:SetSize(ns.db.ui.width, 100)
    p:SetFrameStrata("DIALOG")
    p:EnableMouse(true)
    p:SetClampedToScreen(true)
    ApplyBackdrop(p)

    p.title = NewText(p, (ns.db.ui.fontSize or 12) + 1, "GameFontNormal", "LEFT", true)
    p.title:SetPoint("TOPLEFT", PAD, -PAD)
    p.title:SetTextColor(unpack(C.accent))
    p.title:SetText("GUIDES")

    p.close = NewButton(p, "x", 22, function() p:Hide() end)
    p.close:SetPoint("TOPRIGHT", -6, -6)

    p.rows = {}
    p:Hide()
    return p
end

local function PickerRow(p, i)
    local row = p.rows[i]
    if row then return row end
    local ok, btn = pcall(CreateFrame, "Button", nil, p, "UIPanelButtonTemplate")
    if not ok or not btn then
        btn = CreateFrame("Button", nil, p)
        btn:SetNormalFontObject("GameFontNormal")
    end
    btn:SetSize(ns.db.ui.width - 2 * PAD, 22)
    btn:SetScript("OnClick", function(self)
        if self.guideID == "__auto" then
            ns.Tracker:SetMode("auto")
        else
            ns.Guide:Activate(self.guideID)
            ns.Tracker:SetMode("guide")
        end
        p:Hide()
        UI:Refresh()
    end)
    local sub = NewText(p, (ns.db.ui.fontSize or 12) - 2, "GameFontHighlightSmall", "RIGHT", true)
    sub:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
    sub:SetWidth(120)
    sub:SetTextColor(unpack(C.dim))
    btn.sub = sub
    -- left-aligned label that stops before the sub text instead of the template's centred one
    local label = btn.GetFontString and btn:GetFontString()
    if label then
        label:ClearAllPoints()
        label:SetPoint("LEFT", btn, "LEFT", 8, 0)
        label:SetPoint("RIGHT", sub, "LEFT", -4, 0)
        pcall(label.SetJustifyH, label, "LEFT")
        pcall(label.SetMaxLines, label, 1)
    end
    p.rows[i] = btn
    return btn
end

function UI:RefreshPicker()
    local p = self:CreatePicker()
    local G = ns.Guide
    local y = PAD + ROW_H + 8
    local i = 0
    local function add(text, sub, id, dim)
        i = i + 1
        local row = PickerRow(p, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -y)
        row:SetText(text)
        row.sub:SetText(sub or "")
        row.guideID = id
        row:SetAlpha(dim and 0.55 or 1)
        row:Show()
        row.sub:Show()
        y = y + 22 + 3
    end
    if ns.DB and ns.DB:IsLoaded() then
        add("Auto mode - follow my quest log", ns.char.mode == "auto" and "active" or "", "__auto", false)
    end
    -- guides this character can use, sorted by level; everything else only when nothing fits
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
    for _, g in ipairs(list) do
        if i >= 18 then break end
        local fits = (g.minLevel or 1) <= level + 3 and (g.maxLevel or 60) >= level - 2
        local prog = ns.char.guides and ns.char.guides[g.id]
        local progText = ""
        if prog and prog.step and prog.step > 1 then
            if prog.step > #g.steps then progText = "  done"
            else progText = string.format("  step %d/%d", prog.step, #g.steps) end
        end
        local sub = string.format("%s-%s  %d steps%s%s", tostring(g.minLevel or "?"), tostring(g.maxLevel or "?"), #g.steps, progText,
            (G.active == g and ns.char.mode ~= "auto") and "  (active)" or "")
        add((g.name or g.id) .. (showingAll and "  [other faction/race]" or ""), sub, g.id, not fits)
    end
    if i == 0 then add("no guides installed", "", nil, true) end
    for j = i + 1, #p.rows do p.rows[j]:Hide() p.rows[j].sub:Hide() end
    p:SetHeight(y + PAD - 3)
    p:ClearAllPoints()
    p:SetPoint("TOPRIGHT", frame, "TOPLEFT", -6, 0)
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
    frame:Show()
    ns.db.ui.shown = true
    self:Refresh()
end

function UI:Hide()
    if frame then frame:Hide() end
    ns.db.ui.shown = false
end

function UI:Toggle()
    if frame and frame:IsShown() then self:Hide() else self:Show() end
end

function UI:SetScale(scale)
    ns.db.ui.scale = scale
    if frame then frame:SetScale(scale) end
end

function UI:ResetPosition()
    local d = ns.Database.DEFAULTS.ui
    ns.db.ui.point, ns.db.ui.x, ns.db.ui.y = d.point, d.x, d.y
    if frame then
        frame:ClearAllPoints()
        frame:SetPoint(d.point, UIParent, d.point, d.x, d.y)
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

-- hide in combat (optional): remember what was showing, restore afterwards
local combatHidden
function UI:OnCombat(inCombat)
    if inCombat then
        if not ns.db.ui.hideInCombat then return end
        combatHidden = { window = frame and frame:IsShown(), arrow = ns.Arrow and ns.Arrow.IsShown and ns.Arrow:IsShown() }
        if frame then frame:Hide() end
        if ns.Arrow and ns.Arrow.HideTemporarily then ns.Arrow:HideTemporarily(true) end
    elseif combatHidden then
        if combatHidden.window and frame then frame:Show() end
        if ns.Arrow and ns.Arrow.HideTemporarily then ns.Arrow:HideTemporarily(false) end
        combatHidden = nil
        self:Refresh()
    end
end

function UI:OnEnable()
    self:Create()
    if ns.db.ui.shown then frame:Show() end
    self:Refresh()
    ns.Events:Register("PLAYER_REGEN_DISABLED", function() UI:OnCombat(true) end)
    ns.Events:Register("PLAYER_REGEN_ENABLED", function() UI:OnCombat(false) end)
end
