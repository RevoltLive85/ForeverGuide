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
-- C_SuperTrack.SetSuperTrackedUserWaypoint). The engine then projects
-- SuperTrackedFrame onto the screen where the point is in the world and
-- clamps it to the screen edge when it is behind the player. We dress
-- that frame: its own icon/text are faded out, our diamond, quest name
-- and distance ride on its position. No SuperTrackedFrame (or a target
-- the engine cannot show, e.g. another continent) -> the compact gold
-- chevron in Arrow.lua takes over.
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
    if not stf or not cfg().enabled or self:IsSuppressed() then return false end
    if mapOpen() then return false end
    if not ns.Navigation.target or not ns.Navigation.ownsWaypoint then return false end
    local ok, shown = pcall(stf.IsShown, stf)
    if not ok or not shown then return false end
    local okv, visible = pcall(stf.IsVisible, stf)
    if okv and visible == false then return false end
    return true
end

function WP:Tick()
    if not overlay then return end
    local Nav = ns.Navigation
    local show = self:PinShown()
    if show then
        fadeBlizzard(true)
        local cx, cy = stf:GetCenter()
        if not cx then show = false else
            local s = (stf.GetEffectiveScale and stf:GetEffectiveScale() or 1) / (overlay.GetEffectiveScale and overlay:GetEffectiveScale() or 1)
            overlay:ClearAllPoints()
            overlay:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx * s, cy * s)
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
