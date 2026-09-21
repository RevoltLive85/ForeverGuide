-- ============================================================
-- ForeverGuide / Minimap.lua
-- A minimap button (no libraries):
--   left click        show / hide the guide window
--   right click       open the guide picker
--   shift-left click  toggle the floating arrow
--   alt-left click    hide / show everything (window + arrow) at once
--   drag              move it around the minimap edge
-- ============================================================

local _, ns = ...
local MM = ns:NewModule("Minimap")

local ICON = "Interface\\AddOns\\ForeverGuide\\Textures\\compass.tga"
local button

local function Cfg()
    ns.db.minimap = ns.db.minimap or {}
    local m = ns.db.minimap
    if m.shown == nil then m.shown = true end
    if m.angle == nil then m.angle = 220 end
    return m
end

local function Reposition()
    if not button then return end
    local minimap = rawget(_G, "Minimap")
    if not minimap then return end
    local angle = math.rad(Cfg().angle)
    local radius = (minimap:GetWidth() or 140) / 2 + 6
    button:ClearAllPoints()
    button:SetPoint("CENTER", minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
    local minimap = rawget(_G, "Minimap")
    if not minimap then return end
    local mx, my = minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = minimap:GetEffectiveScale()
    if not mx or not cx or not scale or scale == 0 then return end
    cx, cy = cx / scale, cy / scale
    Cfg().angle = math.deg(math.atan2(cy - my, cx - mx))
    Reposition()
end

function MM:Create()
    if button then return button end
    local minimap = rawget(_G, "Minimap")
    if not minimap then return nil end
    local b = CreateFrame("Button", "ForeverGuideMinimapButton", minimap)
    button = b
    b:SetSize(32, 32)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:SetMovable(true)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")

    local overlay = b:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(54, 54)
    overlay:SetPoint("TOPLEFT")
    pcall(overlay.SetTexture, overlay, "Interface\\Minimap\\MiniMap-TrackingBorder")

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(22, 22)
    bg:SetPoint("CENTER", -1, 1)
    pcall(bg.SetTexture, bg, "Interface\\Minimap\\UI-Minimap-Background")

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", -1, 1)
    pcall(icon.SetTexture, icon, ICON)
    pcall(icon.SetTexCoord, icon, 0, 1, 0, 1)
    b.icon = icon

    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    pcall(hl.SetTexture, hl, "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    pcall(hl.SetBlendMode, hl, "ADD")

    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", OnDragUpdate)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    b:SetScript("OnClick", function(_, mouse)
        local ok, err = pcall(function()
            if mouse == "RightButton" then
                ns.UI:TogglePicker()
            elseif rawget(_G, "IsAltKeyDown") and IsAltKeyDown() then
                local hidden = ns.UI:ToggleAll()
                ns.Printf("everything %s - alt-click the minimap button again to bring it back.",
                    hidden and "hidden" or "back")
            elseif rawget(_G, "IsShiftKeyDown") and IsShiftKeyDown() then
                ns.Arrow:SetEnabled(not (ns.db.ui.arrow and ns.db.ui.arrow.enabled))
            else
                ns.UI:Toggle()
            end
        end)
        if not ok then ns.ReportOnce("minimap:click", err) end
    end)
    b:SetScript("OnEnter", function(self)
        local tt = rawget(_G, "GameTooltip")
        if not tt then return end
        tt:SetOwner(self, "ANCHOR_LEFT")
        tt:AddLine("ForeverGuide", 0.31, 0.82, 0.77)
        if ns.UI:AllHidden() then tt:AddLine("hidden (still tracking)", 1, 0.82, 0.2) end
        local G = ns.Guide
        if ns.Tracker and ns.Tracker:IsActive() and (not G.active or ns.char.mode == "auto") then
            tt:AddLine("auto mode - quest log", 0.9, 0.9, 0.9)
            if ns.Tracker.current then tt:AddLine(ns.Tracker:Describe(), 0.7, 0.7, 0.7, true) end
        elseif G.active then
            local cur, total = G:GetStepCount()
            tt:AddLine(string.format("%s  (step %d/%d)", G.active.name or G.active.id, math.min(cur, total), total), 0.9, 0.9, 0.9)
            local step = G:GetCurrentStep()
            if step then tt:AddLine(G:GetStepText(step), 1, 0.85, 0.3, true) end
        else
            tt:AddLine("no guide active", 0.7, 0.7, 0.7)
        end
        tt:AddLine(" ")
        tt:AddLine("Left click: guide window", 0.6, 0.6, 0.6)
        tt:AddLine("Right click: pick a guide / auto mode", 0.6, 0.6, 0.6)
        tt:AddLine("Shift-click: toggle the arrow", 0.6, 0.6, 0.6)
        tt:AddLine(ns.UI:AllHidden() and "Alt-click: show everything again" or "Alt-click: hide everything (window + arrow)", 0.6, 0.6, 0.6)
        tt:AddLine("Drag: move the button", 0.6, 0.6, 0.6)
        tt:Show()
    end)
    b:SetScript("OnLeave", function()
        local tt = rawget(_G, "GameTooltip")
        if tt then tt:Hide() end
    end)
    Reposition()
    MM:UpdateIcon()
    if not Cfg().shown then b:Hide() end
    return b
end

--- Dim the button while everything is hidden, so the state is visible.
function MM:UpdateIcon()
    if not button or not button.icon then return end
    local hidden = ns.UI.AllHidden and ns.UI:AllHidden()
    pcall(button.icon.SetDesaturated, button.icon, hidden and true or false)
    button.icon:SetAlpha(hidden and 0.5 or 1)
end

function MM:SetShown(shown)
    Cfg().shown = shown
    if button then button:SetShown(shown) end
end

function MM:OnEnable()
    self:Create()
    ns.Events:Register("FG_HIDDEN_ALL_CHANGED", function() MM:UpdateIcon() end)
end
