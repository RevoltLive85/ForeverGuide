-- ============================================================
-- ForeverGuide / Options.lua
-- Options panel (Esc -> Options -> AddOns -> ForeverGuide, or /fg options).
-- Plain checkboxes on a canvas category; everything here also has a slash
-- command, the panel just makes it discoverable.
-- ============================================================

local _, ns = ...
local Options = ns:NewModule("Options")

local panel, category
local widgets = {}

local function Bool(v) return v and true or false end

-- ---- the settings this panel edits: get/set pairs ---------------------------------
local ITEMS = {
    { key = "window", label = "Show the guide window",
      get = function() return Bool(ns.db.ui.shown) end,
      set = function(v) if v then ns.UI:Show() else ns.UI:Hide() end end },
    { key = "arrow", label = "Show the compact chevron arrow above your head (the everyday indicator)",
      get = function() return Bool(ns.db.ui.arrow and ns.db.ui.arrow.enabled ~= false) end,
      set = function(v) ns.Arrow:SetEnabled(v) end },
    { key = "minimap", label = "Show the minimap button",
      get = function() return Bool(ns.db.minimap == nil or ns.db.minimap.shown ~= false) end,
      set = function(v) ns.Minimap:SetShown(v) end },
    { key = "lock", label = "Lock the window and the arrow (no dragging)",
      get = function() return Bool(ns.db.ui.locked) end,
      set = function(v) ns.db.ui.locked = v ns.Events:Fire("FG_LOCK_CHANGED", v) end },
    { key = "hideall", label = "Hide everything (window + arrow) - the guide keeps running",
      get = function() return Bool(ns.db.ui.hiddenAll) end,
      set = function(v) ns.UI:SetAllHidden(v) end,
      refresh = { "window", "arrow" } },
    { key = "combat", label = "Hide the window and arrow while in combat",
      get = function() return Bool(ns.db.ui.hideInCombat) end,
      set = function(v) ns.db.ui.hideInCombat = v end },
    { key = "bliz", label = "Also use Blizzard's own map pin / super-track arrow",
      get = function() return Bool(ns.db.nav.blizzardWaypoint) end,
      set = function(v) ns.Navigation:SetBlizzardWaypointEnabled(v) end },
    { header = "Quests" },
    { key = "acceptAll", label = "Auto-accept every quest an NPC offers",
      get = function() return ns.AutoQuest.Cfg().accept == "on" end,
      set = function(v) ns.AutoQuest:Set("accept", v and "on" or "guide") end,
      refresh = { "acceptGuide" } },
    { key = "acceptGuide", label = "Auto-accept only quests of the active guide",
      get = function() return ns.AutoQuest.Cfg().accept == "guide" end,
      set = function(v) ns.AutoQuest:Set("accept", v and "guide" or "off") end,
      refresh = { "acceptAll" } },
    { key = "turnin", label = "Auto-turn-in finished quests (a reward choice is left to you)",
      get = function() return Bool(ns.AutoQuest.Cfg().turnin) end,
      set = function(v) ns.AutoQuest:Set("turnin", v and "on" or "off") end },
    { key = "announce", label = "Announce auto-accepted / turned-in quests in chat",
      get = function() return Bool(ns.AutoQuest.Cfg().announce) end,
      set = function(v) ns.AutoQuest.Cfg().announce = v end },
    { key = "autopick", label = "Pick a fitting guide automatically when none is active",
      get = function() return Bool(ns.char.autoPickGuide) end,
      set = function(v) ns.char.autoPickGuide = v end },
    { header = "Data" },
    { key = "recorder", label = "Record quest / NPC / coordinate data while playing (helps map WoW Forever's new quests)",
      get = function() return Bool(ns.db.recorder.enabled) end,
      set = function(v) ns.db.recorder.enabled = v end },
}

-- ---- widgets --------------------------------------------------------------------------
local function MakeCheck(parent, item, y)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    local label = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText(item.label)
    cb.label = label
    cb:SetScript("OnClick", function(self)
        local ok, err = pcall(item.set, self:GetChecked() and true or false)
        if not ok then ns.ReportOnce("options:" .. item.key, err) end
        Options:Refresh()
    end)
    return cb
end

local function MakeButton(parent, text, x, y, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(150, 22)
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    b:SetText(text)
    b:SetScript("OnClick", function()
        local ok, err = pcall(onClick)
        if not ok then ns.ReportOnce("options:button", err) end
    end)
    return b
end

function Options:Refresh()
    for key, cb in pairs(widgets) do
        local item = cb.item
        local ok, v = pcall(item.get)
        cb:SetChecked(ok and v and true or false)
    end
end

--- The settings canvas is only so tall and does not clip what we draw on it, so the checkboxes
--- go on a scrolling child: the list can grow without spilling over the game (Ilya, 2026-09-21).
local function MakeScroller(parent, topOffset)
    local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, parent)
    if not ok or not scroll then return parent, nil end
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, topOffset)
    scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -24, 8)
    pcall(scroll.SetClipsChildren, scroll, true)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(560, 10)
    pcall(scroll.SetScrollChild, scroll, content)
    pcall(scroll.EnableMouseWheel, scroll, true)
    -- the client's own range can lag the child's height, so take whichever is larger
    local function range(self)
        local child = self.GetScrollChild and self:GetScrollChild()
        local byChild = child and math.max(0, (child:GetHeight() or 0) - (self:GetHeight() or 0)) or 0
        local byApi = self.GetVerticalScrollRange and self:GetVerticalScrollRange() or 0
        return math.max(byApi or 0, byChild)
    end
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local at = (self.GetVerticalScroll and self:GetVerticalScroll() or 0) - (delta or 0) * 60
        self:SetVerticalScroll(math.max(0, math.min(range(self), at)))
    end)
    scroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 0 then content:SetWidth(w) end
    end)
    return content, scroll
end

function Options:Create()
    if panel then return panel end
    panel = CreateFrame("Frame", "ForeverGuideOptionsPanel")
    panel.name = "ForeverGuide"
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("ForeverGuide")
    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    sub:SetWidth(600)
    sub:SetJustifyH("LEFT")
    sub:SetText("Free leveling guide engine for WoW Forever. Everything here is also available as /fg commands (/fg help).")
    local more = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    more:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -2)
    more:SetText("Scroll for the rest of the settings.")

    local body, scroll = MakeScroller(panel, -80)
    panel.body, panel.scroll = body, scroll
    local y = body == panel and -80 or -4
    -- the Quest Guide / waypoint toggles live with their settings module
    local items = {}
    for _, it in ipairs(ITEMS) do items[#items + 1] = it end
    if ns.QuestGuideConfig then for _, it in ipairs(ns.QuestGuideConfig.OptionItems()) do items[#items + 1] = it end end
    for _, item in ipairs(items) do
        if item.header then
            local h = body:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            h:SetPoint("TOPLEFT", 16, y - 6)
            h:SetText(item.header)
            y = y - 26
        else
            local cb = MakeCheck(body, item, y)
            cb.item = item
            widgets[item.key] = cb
            y = y - 26
        end
    end
    y = y - 10
    MakeButton(body, "Reset positions", 16, y, function() ns.UI:ResetPosition() ns.Arrow:ResetPosition() end)
    MakeButton(body, "Pick a guide", 176, y, function() ns.UI:TogglePicker() end)
    MakeButton(body, "Show reports", 336, y, function() ns.Commands:Run("reports") end)
    y = y - 34
    local hint = body:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, y)
    hint:SetWidth(560)
    hint:SetJustifyH("LEFT")
    hint:SetText("Something wrong with a step? Stand where it should be and type  /fg wrong <what is wrong>  - the report is saved with your position and turned into a correction by tools/collect_reports.py.\nLook: /fg qg scale|opacity|width|rows|wpsize|arrowsize <value>   (e.g. /fg qg opacity 0.8, or /fg arrow size 1.5)\nKey bindings: Esc -> Options -> Key Bindings -> AddOns -> ForeverGuide.")

    -- the scrolling child is exactly as tall as what we put on it
    if body ~= panel then
        body:SetHeight(math.abs(y) + 70)
        panel.contentHeight = body:GetHeight()
    end

    panel:SetScript("OnShow", function()
        Options:Refresh()
        if panel.scroll and panel.scroll.SetVerticalScroll then pcall(panel.scroll.SetVerticalScroll, panel.scroll, 0) end
    end)

    -- register with whichever settings API this client has
    local S = rawget(_G, "Settings")
    if S and S.RegisterCanvasLayoutCategory and S.RegisterAddOnCategory then
        local ok, cat = pcall(S.RegisterCanvasLayoutCategory, panel, panel.name)
        if ok and cat then
            category = cat
            pcall(S.RegisterAddOnCategory, cat)
        end
    elseif rawget(_G, "InterfaceOptions_AddCategory") then
        pcall(InterfaceOptions_AddCategory, panel)
    end
    return panel
end

function Options:Open()
    self:Create()
    local S = rawget(_G, "Settings")
    if category and S and S.OpenToCategory then
        pcall(S.OpenToCategory, category:GetID())
    elseif rawget(_G, "InterfaceOptionsFrame_OpenToCategory") then
        pcall(InterfaceOptionsFrame_OpenToCategory, panel)
        pcall(InterfaceOptionsFrame_OpenToCategory, panel)
    else
        ns.Print("options panel could not be opened on this client; use /fg commands.")
    end
end

function Options:OnEnable()
    self:Create()
end
