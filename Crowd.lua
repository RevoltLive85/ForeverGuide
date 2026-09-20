-- ============================================================
-- ForeverGuide / Crowd.lua
-- Too many people on the same mobs? Then the fastest thing is to leave.
-- The nameplate scan (UI/MobMarker.lua) reports every quest mob it sees,
-- tagged by others or free, plus the players it sees. Over a rolling
-- window that gives a competition ratio; past the threshold a banner
-- says so and offers somewhere else to go:
--
--   [!] Crowded: 7 of 9 quest mobs are taken by other players
--       Dire Condor also spawn 310 yd NE  [Go there]   ·  or: Selling Fish (360 yd)
--
-- Alternatives: another spawn cluster of the same mobs from the database
-- (at least ALT_MIN_YD away), else a different open step of the guide
-- elsewhere. "Go there" navigates to the spot until you arrive.
-- ============================================================

local _, ns = ...
local Crowd = ns:NewModule("Crowd")

local WINDOW = 90            -- seconds of observations kept
local MIN_TAGGED = 3         -- at least this many taken mobs before "crowded"
local RATIO = 0.6            -- taken / (taken + free) at or above this
local MIN_PLAYERS = 5        -- or this many distinct players seen around
local ALT_MIN_YD = 150       -- an alternative spot must be this far away
local CLUSTER_YD = 120       -- spawn points closer than this are one spot
local REPEAT_SEC = 180       -- chat reminder cadence

local samples = {}           -- { t, free, tagged, players = {guid=true} }

local function cfg()
    ns.db.crowd = ns.db.crowd or { enabled = true }
    return ns.db.crowd
end

--- Called by the mob scan: counts of wanted mobs free / tagged, and player GUIDs seen.
function Crowd:Observe(free, tagged, players)
    local now = ns.Now()
    samples[#samples + 1] = { t = now, free = free or 0, tagged = tagged or 0, players = players or {} }
    while samples[1] and now - samples[1].t > WINDOW do table.remove(samples, 1) end
end

--- Competition over the window: tagged, free, distinct players, crowded (bool).
function Crowd:Level()
    local tagged, free, players = 0, 0, {}
    local maxTagged, maxFree = 0, 0
    for _, s in ipairs(samples) do
        -- each sample is a snapshot; use the busiest snapshot rather than a sum over time
        if s.tagged > maxTagged then maxTagged = s.tagged end
        if s.free > maxFree then maxFree = s.free end
        for g in pairs(s.players) do players[g] = true end
    end
    tagged, free = maxTagged, maxFree
    local n = 0
    for _ in pairs(players) do n = n + 1 end
    local total = tagged + free
    local crowded = (tagged >= MIN_TAGGED and total > 0 and tagged / total >= RATIO) or n >= MIN_PLAYERS
    return tagged, free, n, crowded
end

-- ---- alternatives ---------------------------------------------------------------------------
local function compass(dx, dy)
    -- world axes: +x north, +y west
    local ang = math.deg(math.atan2(-dy, dx))    -- 0 = north, 90 = east
    if ang < 0 then ang = ang + 360 end
    local names = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
    return names[math.floor((ang + 22.5) / 45) % 8 + 1]
end

--- Other spawn clusters of the current objective's mobs: { {label, map, x, y, dist, dir}, ... } nearest first
function Crowd:SpawnAlternatives()
    local step = ns.Guide and ns.Guide:GetCurrentStep()
    local DB = ns.DB
    if not step or not step.quest or not DB or not DB:IsLoaded() then return {} end
    local objIdx = ns.Guide:StepObjectiveIndex(step)
    local live = ns.Quest:GetObjectives(step.quest) or {}
    local o = objIdx and live[objIdx]
    local dbo = DB:MatchObjective(step.quest, objIdx or 1, o and o.text)
    local locs = dbo and dbo.locations or {}
    if #locs < 2 then
        -- a kill step names its mob: use every spawn of that npc
        if step.npc then locs = DB:NPCLocations(step.npc) end
    end
    local px, py, pInst = ns.Player:GetWorldPosition()
    if not px or #locs < 2 then return {} end
    -- world points, greedy clustering
    local clusters = {}
    for _, l in ipairs(locs) do
        local inst, wx, wy = ns.Navigation:MapToWorld(l.map, l.x, l.y)
        if inst and inst == pInst and wx then
            local placed
            for _, c in ipairs(clusters) do
                if (c.wx - wx) ^ 2 + (c.wy - wy) ^ 2 < CLUSTER_YD ^ 2 then
                    c.n = c.n + 1
                    c.wx = c.wx + (wx - c.wx) / c.n
                    c.wy = c.wy + (wy - c.wy) / c.n
                    placed = true
                    break
                end
            end
            if not placed then clusters[#clusters + 1] = { wx = wx, wy = wy, n = 1, map = l.map, x = l.x, y = l.y, name = l.name or (dbo and dbo.name) } end
        end
    end
    local out = {}
    for _, c in ipairs(clusters) do
        local dx, dy = c.wx - px, c.wy - py
        local d = math.sqrt(dx * dx + dy * dy)
        if d >= ALT_MIN_YD then
            out[#out + 1] = { label = string.format("%s also spawn %s %s (%d spot%s)", c.name or "they", ns.Navigation:FormatDistance(d), compass(dx, dy), c.n, c.n == 1 and "" or "s"),
                              map = c.map, x = c.x, y = c.y, dist = d, dir = compass(dx, dy), n = c.n }
        end
    end
    table.sort(out, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.dist < b.dist end)
    return out
end

--- Another open step of the guide that is somewhere else: { label, index, dist } or nil
function Crowd:StepAlternative()
    local G = ns.Guide
    if not G or not G.active or not G.current then return nil end
    local steps = G.active.steps
    local px, py, pInst = ns.Player:GetWorldPosition()
    if not px then return nil end
    for i = G.current + 1, #steps do
        local s = steps[i]
        if (s.type == "KILL" or s.type == "COLLECT" or s.type == "COMPLETE" or s.type == "TURNIN") and G:StepApplies(s) and not s.optional
            and (s.quest and ns.Quest:IsOnQuest(s.quest)) and not G:IsStepDone(s, i) then
            local map, x, y = ns.Navigation:ResolveStep(s)
            if map then
                local inst, wx, wy = ns.Navigation:MapToWorld(map, x, y)
                if inst == pInst and wx then
                    local d = math.sqrt((wx - px) ^ 2 + (wy - py) ^ 2)
                    if d >= ALT_MIN_YD then
                        return { label = string.format("%s (%s)", G:GetStepText(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""), ns.Navigation:FormatDistance(d)), index = i, dist = d }
                    end
                end
            end
        end
    end
    return nil
end

-- ---- banner --------------------------------------------------------------------------------------
local banner
local function Banner()
    if banner then return banner end
    local Theme = ns.Theme
    local ok, f = pcall(CreateFrame, "Frame", "ForeverGuideCrowdBanner", UIParent, "BackdropTemplate")
    if not ok or not f then f = CreateFrame("Frame", "ForeverGuideCrowdBanner", UIParent) end
    banner = f
    f:SetSize(460, 56)
    f:SetPoint("TOP", UIParent, "TOP", 0, -210)
    f:SetFrameStrata("HIGH")
    if Theme and Theme.Backdrop then Theme.Backdrop(f, "panel", 0.92) end
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(28, 28)
    f.icon:SetPoint("LEFT", f, "LEFT", 12, 0)
    pcall(f.icon.SetTexture, f.icon, "Interface\\Icons\\Ability_Rogue_Sprint")
    pcall(f.icon.SetTexCoord, f.icon, 0.08, 0.92, 0.08, 0.92)
    f.title = Theme and Theme.NewText(f, { fancy = true, size = 14, color = { 1, 0.7, 0.3 }, oneLine = true, shadow = true }) or f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, 1)
    f.title:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    f.sub = Theme and Theme.NewText(f, { size = 11, color = Theme.C.text, oneLine = true }) or f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.sub:SetPoint("BOTTOMLEFT", f.icon, "BOTTOMRIGHT", 10, 0)
    f.sub:SetPoint("RIGHT", f, "RIGHT", -100, 0)
    f.go = Theme and Theme.NewButton(f, "Go there", 84, 22, function() Crowd:GoToAlternative() end) or CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.go:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 8)
    f.close = Theme and Theme.NewButton(f, "x", 22, 18, function() Crowd.snoozedUntil = ns.Now() + 300 f:Hide() end) or CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)
    f:Hide()
    return f
end

function Crowd:GoToAlternative()
    local alt = self.alt
    if not alt then return end
    if alt.map then
        ns.Navigation.override = "crowd"
        ns.Navigation:SetTarget({ map = alt.map, x = alt.x, y = alt.y, label = "Quieter spot - " .. (alt.dir or "") .. " (crowd)", radius = 30, owner = "crowd" })
        ns.Printf("navigating to the quieter spot %s; the guide's own marker returns when you arrive.", alt.dir or "")
    elseif alt.index then
        ns.Guide:SetStep(alt.index)
    end
    if banner then banner:Hide() end
    self.snoozedUntil = ns.Now() + 300
end

function Crowd:ReleaseOverride()
    if ns.Navigation.override == "crowd" then
        ns.Navigation.override = nil
        if ns.Navigation.target and ns.Navigation.target.owner == "crowd" then ns.Navigation:Clear() end
        if ns.Tracker and ns.Tracker:IsActive() then ns.Tracker:Rethink() elseif ns.Guide then ns.Guide:UpdateNavigation() end
    end
end

function Crowd:Update()
    local f = Banner()
    if cfg().enabled == false or (ns.UI and ns.UI.AllHidden and ns.UI:AllHidden()) then f:Hide() return end
    local tagged, free, players, crowded = self:Level()
    if not crowded or (self.snoozedUntil and ns.Now() < self.snoozedUntil) then f:Hide() return end
    local total = tagged + free
    local title
    if tagged >= MIN_TAGGED then title = string.format("Crowded: %d of %d quest mobs are taken by others", tagged, total)
    else title = string.format("Crowded: %d players hunting the same mobs", players) end
    f.title:SetText(title)
    local spawn = self:SpawnAlternatives()[1]
    local stepAlt = self:StepAlternative()
    self.alt = spawn or stepAlt
    local sub
    if spawn then sub = spawn.label .. (stepAlt and ("  ·  or: " .. stepAlt.label) or "")
    elseif stepAlt then sub = "meanwhile: " .. stepAlt.label
    else sub = "no other spot known - grind nearby or come back in a few minutes" end
    f.sub:SetText(sub)
    f.go:SetShown(self.alt ~= nil)
    if not f:IsShown() then
        f:Show()
        local now = ns.Now()
        if not self.lastChat or now - self.lastChat > REPEAT_SEC then
            self.lastChat = now
            ns.Printf("%s. %s", title, sub)
        end
    end
end

function Crowd:OnInit()
    ns.Events:Register("FG_NAV_ARRIVED", function(_, target) if target and target.owner == "crowd" then Crowd:ReleaseOverride() end end)
    ns.Events:RegisterMany({ "FG_STEP_CHANGED", "FG_GUIDE_CHANGED" }, function() Crowd:ReleaseOverride() samples = {} Crowd:Update() end)
    ns.Events:Register("FG_HIDDEN_ALL_CHANGED", function() Crowd:Update() end)
end
