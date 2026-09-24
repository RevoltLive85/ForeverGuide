-- ============================================================
-- ForeverGuide / Arrow.lua
-- The compact gold chevron above your character: rotates towards the
-- destination straight from your real facing (Navigation's angle, no
-- smoothing, no guessing), with the destination name and distance under
-- it. Warm gold when you face the target, cooler / dimmer the further it
-- is to the side or behind. This is the everyday indicator; the fancier
-- in-world diamond (UI/QuestWaypoint.lua) only takes over when a player
-- opts into "/fg waypoint engine on" and the client's own pin can
-- genuinely project it - otherwise this chevron is what shows.
--
--   /fg arrow on|off        show / hide
--   /fg arrow size <0.5-2.5>   bigger / smaller (also /fg qg arrowsize <value>)
--   /fg unlock              drag it (and the window) somewhere else
-- ============================================================

local _, ns = ...
local Arrow = ns:NewModule("Arrow")

local TEXTURE = "Interface\\AddOns\\ForeverGuide\\Textures\\chevron.tga"
local FONT = rawget(_G, "STANDARD_TEXT_FONT") or "Fonts\\FRIZQT__.TTF"
local SIZE = 36
local frame

local function Cfg()
    local ui = ns.db.ui
    ui.arrow = ui.arrow or {}
    local a = ui.arrow
    if a.enabled == nil then a.enabled = true end
    a.point = a.point or "CENTER"
    a.x = a.x or 0
    a.y = a.y or 170
    a.scale = a.scale or 1
    return a
end

function Arrow:Create()
    if frame then return frame end
    local a = Cfg()
    local f = CreateFrame("Frame", "ForeverGuideArrowFrame", UIParent)
    frame = f
    f:SetSize(160, SIZE + 40)
    f:SetPoint(a.point, UIParent, a.point, a.x, a.y)
    f:SetScale(a.scale)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not ns.db.ui.locked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        local c = Cfg()
        c.point, c.x, c.y = point or "CENTER", x or 0, y or 0
    end)

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetSize(SIZE, SIZE)
    tex:SetPoint("TOP", 0, 0)
    pcall(tex.SetTexture, tex, TEXTURE)
    f.tex = tex

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetFont(FONT, 12, "OUTLINE")
    label:SetPoint("TOP", tex, "BOTTOM", 0, -2)
    label:SetWidth(220)
    label:SetJustifyH("CENTER")
    pcall(label.SetWordWrap, label, true)
    pcall(label.SetMaxLines, label, 1)
    label:SetTextColor(1, 0.88, 0.55)
    f.label = label

    local dist = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dist:SetFont(FONT, 11, "OUTLINE")
    dist:SetPoint("TOP", label, "BOTTOM", 0, -1)
    dist:SetJustifyH("CENTER")
    dist:SetTextColor(0.93, 0.89, 0.80)
    f.dist = dist

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetFont(FONT, 10, "OUTLINE")
    hint:SetPoint("BOTTOM", tex, "TOP", 0, 2)
    hint:SetText("drag me  (/fg lock)")
    hint:SetTextColor(1, 0.8, 0.3)
    hint:Hide()
    f.hint = hint

    f.elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed < 0.05 then return end
        self.elapsed = 0
        local ok, err = pcall(Arrow.Tick, Arrow)
        if not ok then ns.ReportOnce("arrow", err) end
    end)
    f:Hide()
    return f
end

-- The placeholder ("no destination - drag me") only shows while the player
-- explicitly unlocked the UI this session (/fg unlock or the option), not just
-- because the saved setting is unlocked - a fresh install must not show it.
Arrow.dragMode = false

function Arrow:Tick()
    local f = frame
    local Nav = ns.Navigation
    local unlocked = Arrow.dragMode
    f:EnableMouse(not ns.db.ui.locked and (unlocked or Nav.target ~= nil))
    f.hint:SetShown(unlocked)
    local t = Nav.target
    if not t then
        if unlocked then
            f.tex:SetRotation(0)
            f.tex:SetVertexColor(0.6, 0.6, 0.6)
            f.label:SetText("no destination")
            f.dist:SetText("")
        else
            f:Hide()
        end
        return
    end
    local s = Nav:Update(true)
    f.label:SetText(t.label or "")
    if not s or not s.distance then
        f.tex:SetRotation(0)
        f.tex:SetVertexColor(0.6, 0.6, 0.6)
        f.dist:SetText(Nav:Describe())
        return
    end
    if not s.angle then
        -- distance known but no facing (indoors / instances): grey, no direction claim
        f.tex:SetRotation(0)
        f.tex:SetVertexColor(0.6, 0.6, 0.6)
        f.dist:SetText(Nav:FormatDistance(s.distance) .. (s.arrived and "  - here" or ""))
        return
    end
    local angle = s.angle
    f.tex:SetRotation(angle)
    -- gold when facing it, dimming towards a dusty orange when it is behind you
    local a = math.abs(angle)
    local k = math.min(1, a / math.pi)
    f.tex:SetVertexColor(1, 0.92 - 0.35 * k, 0.55 - 0.35 * k)
    f.dist:SetText(Nav:FormatDistance(s.distance) .. (s.arrived and "  - here" or ""))
end

-- Suppression has channels so that two reasons to hide the arrow (combat, and the
-- alt-click "hide everything" switch) cannot undo each other.
local suppressed = {}
function Arrow:HideTemporarily(on, reason)
    suppressed[reason or "combat"] = on and true or nil
    self:Refresh()
end

function Arrow:IsSuppressed()
    return next(suppressed) ~= nil
end

function Arrow:IsShown()
    return frame and frame:IsShown() or false
end

function Arrow:Refresh()
    if not frame then return end
    local c = Cfg()
    if c.enabled and not self:IsSuppressed() and (ns.Navigation.target or Arrow.dragMode) then
        frame:Show()
        self:Tick()
    else
        frame:Hide()
    end
end

function Arrow:SetEnabled(on)
    Cfg().enabled = on
    self:Refresh()
end

--- Bigger / smaller (0.5-2.5, /fg arrow size <value> or the qg "arrowsize" number).
function Arrow:SetScale(v)
    v = tonumber(v)
    if not v then return end
    Cfg().scale = v
    if frame then frame:SetScale(v) end
end

function Arrow:GetScale()
    return Cfg().scale or 1
end

function Arrow:ResetPosition()
    local c = Cfg()
    c.point, c.x, c.y = "CENTER", 0, 170
    if frame then
        frame:ClearAllPoints()
        frame:SetPoint(c.point, UIParent, c.point, c.x, c.y)
    end
end

function Arrow:OnInit()
    ns.Events:RegisterMany({ "FG_NAV_TARGET_CHANGED", "FG_STEP_CHANGED", "FG_TRACKER_CHANGED", "FG_MODE_CHANGED" },
        function() Arrow:Refresh() end)
    ns.Events:Register("FG_LOCK_CHANGED", function(_, locked)
        Arrow.dragMode = (locked == false)
        Arrow:Refresh()
    end)
end

function Arrow:OnEnable()
    self:Create()
    self:Refresh()
end
