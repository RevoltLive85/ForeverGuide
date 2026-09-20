-- ============================================================
-- ForeverGuide / UI/QuestWaypoint.lua
-- The in-world waypoint:
--
--            Hilary's Necklace
--                  85 yd
--                    ◆            <- gold diamond, soft glow, gentle pulse
--                    ·
--                    ·            <- QuestRoute: dotted path from the player
--
-- How it works: Navigation already sets Blizzard's user waypoint and
-- super-tracks it (Retail engine: C_Map.SetUserWaypoint +
-- C_SuperTrack.SetSuperTrackedUserWaypoint). When the engine can project
-- that point (C_Navigation.GetTargetState() ~= Invalid, frame alpha > 0)
-- we dress SuperTrackedFrame: its own icon/text are faded out, our
-- diamond, quest name and distance ride on its position.
--
-- On the Forever client the projection is not available in the open
-- world: GetTargetState() reports Invalid, the engine fades its frame to
-- alpha 0 and parks it at a meaningless spot near the character (that
-- was the "the diamond is next to me but the target is 78 yd away" bug).
-- Then we place the diamond ourselves: on a ring around the character's
-- on-screen position, in the direction of the target relative to the
-- player's facing (ahead = above the character, right = right of it),
-- with the ring radius growing with the distance. It still reads as an
-- in-world marker and the dotted route still leads towards it.
-- No target direction at all (other continent, no facing) -> the compact
-- gold chevron in Arrow.lua takes over.
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local WP = ns:NewModule("Waypoint")

local overlay, stf
local hiddenRegions = {}
local suppressed = {}
local lastUpdate = 0

local function cfg() return ns.QuestGuideConfig.Waypoint() end

local function fadeBlizzard(on)
    if not stf then return end
    if on then
        if #hiddenRegions > 0 then return end
        local ok, regions = pcall(function() return { stf:GetRegions() } end)
        if ok and regions then
            for _, r in ipairs(regions) do
                if r and r.GetAlpha and r.SetAlpha then
                    hiddenRegions[#hiddenRegions + 1] = { r = r, a = r:GetAlpha() }
                    pcall(r.SetAlpha, r, 0)
                end
            end
        end
        local okc, children = pcall(function() return { stf:GetChildren() } end)
        if okc and children then
            for _, c in ipairs(children) do
                if c and c.GetAlpha and c.SetAlpha then
                    hiddenRegions[#hiddenRegions + 1] = { r = c, a = c:GetAlpha() }
                    pcall(c.SetAlpha, c, 0)
                end
            end
        end
    else
        for _, h in ipairs(hiddenRegions) do pcall(h.r.SetAlpha, h.r, h.a) end
        hiddenRegions = {}
    end
end

function WP:Create()
    if overlay then return overlay end
    stf = rawget(_G, "SuperTrackedFrame")
    local o = CreateFrame("Frame", "ForeverGuideWaypoint", UIParent)
    overlay = o
    o:SetSize(64, 64)
    o:SetFrameStrata("HIGH")
    o:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    o.diamond = o:CreateTexture(nil, "ARTWORK")
    o.diamond:SetAllPoints()
    pcall(o.diamond.SetTexture, o.diamond, Theme.TEX.waypoint)
    pcall(o.diamond.SetBlendMode, o.diamond, "ADD")
    o.name = Theme.NewText(o, { size = 13, justify = "CENTER", color = Theme.C.goldLight, oneLine = true, outline = "OUTLINE" })
    o.name:SetPoint("BOTTOM", o, "TOP", 0, 26)
    o.name:SetWidth(320)
    o.what = Theme.NewText(o, { size = 10, justify = "CENTER", color = Theme.C.text, oneLine = true, outline = "OUTLINE" })
    o.what:SetPoint("BOTTOM", o, "TOP", 0, 14)
    o.what:SetWidth(320)
    o.dist = Theme.NewText(o, { size = 12, justify = "CENTER", color = Theme.C.gold, oneLine = true, outline = "OUTLINE" })
    o.dist:SetPoint("BOTTOM", o, "TOP", 0, 0)
    o.dist:SetWidth(120)
    Theme.Pulse(o.diamond, 1.8, 0.7, 1.0)
    o:Hide()
    o.elapsed = 0
    o:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + (elapsed or 0)
        if self.elapsed < 0.05 then return end
        self.elapsed = 0
        local ok, err = pcall(WP.Tick, WP)
        if not ok then ns.ReportOnce("waypoint:tick", err) end
    end)
    -- the ticker frame runs even while the overlay is hidden (it decides when to show it)
    local ticker = CreateFrame("Frame")
    ticker.elapsed = 0
    ticker:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + (elapsed or 0)
        if self.elapsed < 0.1 then return end
        self.elapsed = 0
        if not overlay:IsShown() then
            local ok, err = pcall(WP.Tick, WP)
            if not ok then ns.ReportOnce("waypoint:tick", err) end
        end
    end)
    self.overlay = o
    self:Apply()
    return o
end

function WP:Apply()
    if not overlay then return end
    local c = cfg()
    local size = 64 * (c.size or 1)
    overlay:SetSize(size, size)
    Theme.SetPulseEnabled(overlay.diamond, c.animate ~= false)
    if ns.Route and ns.Route.Apply then ns.Route:Apply() end
end

function WP:IsSuppressed() return next(suppressed) ~= nil end
function WP:HideTemporarily(on, reason)
    suppressed[reason or "combat"] = on and true or nil
    self:Tick()
end

function WP:SetEnabled(on)
    cfg().enabled = on and true or false
    if on then
        if not ns.db.nav.blizzardWaypoint then ns.Navigation:SetBlizzardWaypointEnabled(true) end
        ns.Navigation:UpdateBlizzardWaypoint()
    end
    self:Tick()
end

--- Is the world pin usable right now? (engine frame present, shown, and our point)
--- The fullscreen world map covers the pin: nothing of ours should float over it.
local function mapOpen()
    local wm = rawget(_G, "WorldMapFrame")
    if not wm then return false end
    local ok, shown = pcall(wm.IsShown, wm)
    return ok and shown == true
end
WP.MapOpen = mapOpen

function WP:PinShown()
    if not cfg().enabled or self:IsSuppressed() then return false end
    if mapOpen() then return false end
    if not ns.Navigation.target then return false end
    return true
end

--- Does the engine's SuperTrackedFrame sit where the target really is?
--- Only then may the diamond ride on it. Blizzard's own mixin fades the frame
--- to 0 when C_Navigation says the position is invalid; we honour both signals.
function WP:EngineUsable()
    if cfg().engine ~= true then return false end   -- opt-in: /fg waypoint engine on
    if not stf or not ns.Navigation.ownsWaypoint then return false end
    local ok, shown = pcall(stf.IsShown, stf)
    if not ok or not shown then return false end
    local okv, visible = pcall(stf.IsVisible, stf)
    if okv and visible == false then return false end
    local N = rawget(_G, "C_Navigation")
    if N then
        if type(N.GetTargetState) == "function" then
            local oks, state = pcall(N.GetTargetState)
            local invalid = (rawget(_G, "Enum") and Enum.NavigationState and Enum.NavigationState.Invalid) or 0
            if oks and state ~= nil and state == invalid then return false end
        end
        if type(N.HasValidScreenPosition) == "function" then
            local okp, valid = pcall(N.HasValidScreenPosition)
            if okp and valid == false then return false end
        end
    end
    local oka, alpha = pcall(stf.GetAlpha, stf)
    if oka and type(alpha) == "number" and alpha <= 0.01 then return false end
    return true
end

-- Where the diamond goes when the engine cannot project the point: a small
-- perspective model of the default chase camera. The camera sits `zoom` yards
-- behind the character (GetCameraZoom), tilted PITCH down; the target is d
-- yards away at `angle` from the facing. Its ground point is projected with a
-- ~90 degree horizontal field of view (focal length = half the width), which
-- puts the marker where the spot actually is on screen while the camera is
-- behind the character (it is exact in x, and in y as far as the pitch guess
-- holds). Behind the camera the marker is pushed below the character.
-- PITCH is a guess (the camera's tilt cannot be read); a flatter guess errs
-- towards drawing a far marker a little short of the spot, on the ground,
-- instead of floating in the sky above the horizon - which is what a steeper
-- guess did over Lake Everstill. HORIZON caps far targets for the same reason.
local PITCH = math.rad(17)
local HORIZON = 0.74
local EDGE_X, EDGE_LO, EDGE_HI = 0.06, 0.10, HORIZON
local function screenSize()
    local ui = rawget(_G, "UIParent")
    local w, h = ui and ui:GetWidth() or 1024, ui and ui:GetHeight() or 768
    if not w or w == 0 then w, h = 1024, 768 end
    return w, h
end
local function playerPoint(w, h) return w / 2, h * 0.40 end

-- Keep the marker inside the safe rectangle without losing its direction: the
-- vector from the character to the marker is shortened until it touches the
-- edge (a target far to the left ends up on the left edge, one behind you on
-- the bottom edge, never in a corner it has no business in).
local function rayClamp(px, py, x, y, w, h)
    local x0, x1, y0, y1 = w * EDGE_X, w * (1 - EDGE_X), h * EDGE_LO, h * EDGE_HI
    local dx, dy = x - px, y - py
    local k = 1
    if x < x0 then k = math.min(k, (x0 - px) / dx) end
    if x > x1 then k = math.min(k, (x1 - px) / dx) end
    if y < y0 then k = math.min(k, (y0 - py) / dy) end
    if y > y1 then k = math.min(k, (y1 - py) / dy) end
    if k < 1 then return px + dx * k, py + dy * k, true end
    return x, y, false
end

--- Returns x, y (UIParent units), the angle, and whether the marker had to be
--- pinned to the edge (target off-screen: to the side or behind the camera).
function WP:BearingPosition(state)
    if not state or not state.angle or not state.distance then return nil end
    local w, h = screenSize()
    local px, py = playerPoint(w, h)
    local zoom = tonumber(ns.Safe and ns.Safe(rawget(_G, "GetCameraZoom")) or nil) or 15
    if zoom < 5 then zoom = 5 elseif zoom > 40 then zoom = 40 end
    local D, H = zoom * math.cos(PITCH), zoom * math.sin(PITCH) + 1.5   -- camera aims at the chest
    local f = w / 2
    local a, d = state.angle, state.distance
    local lat = d * math.sin(a)          -- yards to the left of the facing
    local fwd = D + d * math.cos(a)      -- yards in front of the camera
    local x, y
    if fwd > math.max(8, 0.3 * d) then
        -- in front of the camera: real perspective
        x = px - f * lat / fwd
        local depression = math.atan(H / fwd)
        y = h * 0.5 + f * math.tan(PITCH - depression)
        if y > h * HORIZON then y = h * HORIZON end
    else
        -- beside or behind the camera: the ground direction from the character, pushed
        -- far out so the edge clamp pins it (left = left edge, behind = bottom edge)
        x = px - math.sin(a) * w
        y = py + math.cos(a) * w
    end
    local cx, cy, pinned = rayClamp(px, py, x, y, w, h)
    return cx, cy, a, pinned
end
WP.PlayerScreenPoint = function() return playerPoint(screenSize()) end

--- /fg wpdbg - everything that decides where the diamond goes, for bug reports.
function WP:Debug()
    local Nav = ns.Navigation
    local t, st = Nav.target, Nav.state
    local function f(v) if type(v) == "number" then return string.format("%.1f", v) end return tostring(v) end
    ns.Printf("waypoint: stf=%s shown=%s visible=%s alpha=%s scale=%s", tostring(stf and stf:GetName() or stf), tostring(stf and stf:IsShown()), tostring(stf and stf:IsVisible()), f(stf and stf:GetAlpha()), f(stf and stf:GetEffectiveScale()))
    if stf then
        local cx, cy = stf:GetCenter()
        local w, h = stf:GetSize()
        local n = stf:GetNumPoints()
        ns.Printf("  center=%s,%s size=%s x %s points=%s parent=%s", f(cx), f(cy), f(w), f(h), tostring(n), tostring(stf:GetParent() and stf:GetParent():GetName()))
        for i = 1, (n or 0) do
            local pt, rel, rp, x, y = stf:GetPoint(i)
            ns.Printf("  point %d: %s %s %s %s,%s", i, tostring(pt), tostring(rel and rel.GetName and rel:GetName() or rel), tostring(rp), f(x), f(y))
        end
    end
    local ui = rawget(_G, "UIParent")
    ns.Printf("  screen=%s x %s uiscale=%s", f(ui and ui:GetWidth()), f(ui and ui:GetHeight()), f(ui and ui:GetEffectiveScale()))
    local N = rawget(_G, "C_Navigation")
    if N then
        local okd, d = pcall(N.GetDistance)
        local oks, s = pcall(N.GetTargetState)
        local okc, c = pcall(N.WasClampedToScreen)
        local okv, v = pcall(N.HasValidScreenPosition)
        local okf, fr = pcall(N.GetFrame)
        ns.Printf("  C_Navigation: distance=%s state=%s clamped=%s validScreenPos=%s frame=%s", okd and f(d) or "err", oks and tostring(s) or "err", okc and tostring(c) or "err", okv and tostring(v) or "err", okf and tostring(fr and fr.GetName and fr:GetName() or fr) or "err")
    end
    local okw, wp = pcall(C_Map.GetUserWaypoint)
    if okw and type(wp) == "table" then
        ns.Printf("  user waypoint: map=%s x=%s y=%s (ours=%s)", tostring(wp.uiMapID), f(wp.position and wp.position.x), f(wp.position and wp.position.y), tostring(Nav.ownsWaypoint))
    else
        ns.Printf("  user waypoint: none")
    end
    local px, py, pi = ns.Player:GetWorldPosition()
    ns.Printf("  target: %s map=%s %s,%s world=%s,%s inst=%s | player world=%s,%s inst=%s map=%s", tostring(t and t.label), tostring(t and t.map), f(t and t.x), f(t and t.y), f(t and t.worldX), f(t and t.worldY), tostring(t and t.instanceID), f(px), f(py), tostring(pi), tostring(ns.Player:GetMapID()))
    ns.Printf("  our state: distance=%s angle=%s method=%s | overlay mode=%s shown=%s at %s,%s", f(st and st.distance), f(st and st.angle), tostring(st and st.method), tostring(self.mode), tostring(overlay and overlay:IsShown()), f(overlay and overlay:GetCenter()), f(overlay and select(2, overlay:GetCenter())))
end

function WP:Tick()
    if not overlay then return end
    local Nav = ns.Navigation
    local show = self:PinShown()
    if show then
        if stf and Nav.ownsWaypoint then fadeBlizzard(true) end
        local x, y, behind
        if self:EngineUsable() then
            local cx, cy = stf:GetCenter()
            if cx then
                local s = (stf.GetEffectiveScale and stf:GetEffectiveScale() or 1) / (overlay.GetEffectiveScale and overlay:GetEffectiveScale() or 1)
                x, y = cx * s, cy * s
                self.mode = "engine"
            end
        end
        if not x then
            local st = Nav:Update(true)
            local bx, by, _, pinned = self:BearingPosition(st)
            if bx then
                x, y = bx, by
                behind = pinned
                self.mode = "bearing"
                self.lastPos = { x = x, y = y, pinned = pinned, at = ns.Now() }
            elseif self.lastPos and ns.Now() - self.lastPos.at < 1.5 then
                -- a momentary gap in position/facing data must not blink the marker away
                x, y, behind = self.lastPos.x, self.lastPos.y, self.lastPos.pinned
            end
        end
        if not x then show = false self.mode = nil else
            overlay:ClearAllPoints()
            overlay:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
            pcall(overlay.SetAlpha, overlay, behind and 0.7 or 1)
            local t = Nav.target
            local label = t and t.label or ""
            local name, what = label:match("^(.-)%s+[·%-]%s+(.+)$")
            overlay.name:SetText(name or label)
            overlay.what:SetText(name and what or "")
            local st = Nav.state
            overlay.dist:SetText(st and st.distance and Nav:FormatDistance(st.distance) or "")
            if not overlay:IsShown() then overlay:Show() end
        end
    end
    if not show then
        if overlay:IsShown() then overlay:Hide() end
        if #hiddenRegions > 0 and (not cfg().enabled or not ns.Navigation.target) then fadeBlizzard(false) end
    end
    -- while the map is open the chevron stays away too (the map's own pin shows the spot)
    if mapOpen() then
        if ns.Arrow and ns.Arrow.HideTemporarily and not ns.Arrow.suppressedByMap then ns.Arrow.suppressedByMap = true ns.Arrow:HideTemporarily(true, "map") end
        if ns.Route then ns.Route:Update(nil) end
        return
    elseif ns.Arrow and ns.Arrow.suppressedByMap then
        ns.Arrow.suppressedByMap = false
        ns.Arrow:HideTemporarily(false, "map")
    end
    -- the compact chevron covers what the pin cannot (no engine pin, other continent, disabled)
    if ns.Arrow and ns.Arrow.HideTemporarily then
        local want = not show
        if ns.Arrow.suppressedByWaypoint ~= (not want) then
            ns.Arrow.suppressedByWaypoint = not want
            ns.Arrow:HideTemporarily(not want, "waypoint")
        end
    end
    if ns.Route then ns.Route:Update(show and overlay or nil) end
end

function WP:OnInit()
    ns.Events:RegisterMany({ "FG_NAV_TARGET_CHANGED", "FG_STEP_CHANGED", "FG_TRACKER_CHANGED", "FG_MODE_CHANGED" }, function() WP:Tick() end)
end

function WP:OnEnable()
    self:Create()
    local wm = rawget(_G, "WorldMapFrame")
    if wm and wm.HookScript then
        pcall(wm.HookScript, wm, "OnShow", function() WP:Tick() if ns.UI.OnMap then ns.UI:OnMap(true) end end)
        pcall(wm.HookScript, wm, "OnHide", function() WP:Tick() if ns.UI.OnMap then ns.UI:OnMap(false) end end)
    end
    self:Tick()
end
