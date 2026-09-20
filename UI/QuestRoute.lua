-- ============================================================
-- ForeverGuide / UI/QuestRoute.lua
-- The faint dotted path from the player's feet towards the waypoint:
-- a pool of small gold dots on a screen-sized frame, laid out along the
-- straight line between the player's on-screen position (bottom-centre
-- of the view) and the waypoint overlay. Updated by QuestWaypoint's
-- ticker only while the waypoint is showing.
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local Route = ns:NewModule("Route")

local DOTS = 14
local canvas, dots

local function cfg() return ns.QuestGuideConfig.Waypoint() end

function Route:Create()
    if canvas then return canvas end
    canvas = CreateFrame("Frame", "ForeverGuideRoute", UIParent)
    canvas:SetAllPoints(UIParent)
    canvas:SetFrameStrata("BACKGROUND")
    pcall(canvas.SetFrameLevel, canvas, 1)
    dots = {}
    for i = 1, DOTS do
        local d = canvas:CreateTexture(nil, "ARTWORK")
        d:SetSize(8, 8)
        pcall(d.SetTexture, d, Theme.TEX.dot)
        pcall(d.SetBlendMode, d, "ADD")
        d:Hide()
        dots[i] = d
    end
    canvas:Hide()
    return canvas
end

function Route:Apply()
    if not canvas then return end
    local size = 8 * (cfg().size or 1)
    for _, d in ipairs(dots) do d:SetSize(size, size) end
end

--- overlay: the waypoint frame (nil hides the path)
function Route:Update(overlay)
    if not canvas then self:Create() end
    local c = cfg()
    if not overlay or c.route == false then
        if canvas:IsShown() then canvas:Hide() end
        return
    end
    local ox, oy = overlay:GetCenter()
    if not ox then canvas:Hide() return end
    local scale = (overlay.GetEffectiveScale and overlay:GetEffectiveScale() or 1) / (canvas.GetEffectiveScale and canvas:GetEffectiveScale() or 1)
    ox, oy = ox * scale, oy * scale
    local w, h = canvas:GetWidth(), canvas:GetHeight()
    if not w or w == 0 then w, h = UIParent:GetWidth(), UIParent:GetHeight() end
    -- the character stands a little below the centre of the view
    local px, py = (w or 0) / 2, (h or 0) * 0.40
    local dx, dy = ox - px, oy - py
    local len = math.sqrt(dx * dx + dy * dy)
    local st = ns.Navigation.state
    if len < 90 or (st and st.distance and st.distance < 12) then canvas:Hide() return end
    if not canvas:IsShown() then canvas:Show() end
    local first, last = 0.12, 0.86
    for i, d in ipairs(dots) do
        local t = first + (last - first) * (i - 1) / (DOTS - 1)
        d:ClearAllPoints()
        d:SetPoint("CENTER", canvas, "BOTTOMLEFT", px + dx * t, py + dy * t)
        pcall(d.SetAlpha, d, 0.25 + 0.55 * t)
        d:Show()
    end
end
