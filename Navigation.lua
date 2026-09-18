-- ============================================================
-- ForeverGuide / Navigation.lua
-- Distance and direction from the player to a map coordinate.
--
-- Coordinates in guides are uiMapID + x/y in 0-100 (the usual "42.3, 71.8").
--
-- Distance: map coordinate -> continent world position with
--   C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y)) -> instanceID, vector2
-- player world position with UnitPosition("player") -> x, y, z, instanceID.
-- WoW's world axes: X points north, Y points west. GetPlayerFacing() is
-- 0 = north and grows counter-clockwise, so the relative angle to the
-- target is atan2(dy, dx) - facing, positive = to the left.
-- Fallback (instances, where UnitPosition is nil): map-space distance
-- scaled by C_Map.GetMapWorldSize(mapID).
--
-- Optional: also sets Blizzard's own user waypoint + super-track so the
-- built-in in-world arrow points to the step (C_Map.SetUserWaypoint,
-- C_SuperTrack.SetSuperTrackedUserWaypoint — both present on 1.60.1).
-- ============================================================

local _, ns = ...
local Nav = ns:NewModule("Navigation")

local Plain, PlainNumber, Safe = ns.Plain, ns.PlainNumber, ns.Safe
local atan2, sqrt, pi = math.atan2, math.sqrt, math.pi

Nav.target = nil        -- { map, x, y, label, radius, worldX, worldY, instanceID }
Nav.state = nil         -- last Update() result
Nav.ownsWaypoint = false

-- ------------------------------------------------------------
-- Conversions
-- ------------------------------------------------------------
--- Map coordinate (0-100) -> instanceID, worldX, worldY (yards). nil if unknown.
function Nav:MapToWorld(mapID, x, y)
    local vec = Safe(CreateVector2D, x / 100, y / 100)
    if not vec then return nil end
    local instanceID, pos = ns.Call("C_Map.GetWorldPosFromMapPos", mapID, vec)
    instanceID = PlainNumber(instanceID)
    if type(pos) ~= "table" or type(pos.GetXY) ~= "function" then return nil end
    local ok, wx, wy = pcall(pos.GetXY, pos)
    wx, wy = PlainNumber(wx), PlainNumber(wy)
    if not ok or not wx or not wy then return nil end
    return instanceID, wx, wy
end

--- Width/height of a map in yards.
function Nav:MapWorldSize(mapID)
    local w, h = ns.Call("C_Map.GetMapWorldSize", mapID)
    return PlainNumber(w), PlainNumber(h)
end

-- ------------------------------------------------------------
-- Target management
-- ------------------------------------------------------------
function Nav:SetTarget(target)
    if not target or not target.map or not target.x or not target.y then
        self:Clear()
        return
    end
    local t = {
        map = target.map,
        x = target.x,
        y = target.y,
        label = target.label,
        owner = target.owner,
        radius = target.radius or (ns.db and ns.db.nav.arrivalRadius) or 15,
    }
    t.instanceID, t.worldX, t.worldY = self:MapToWorld(t.map, t.x, t.y)
    self.target = t
    self.state = nil
    self:UpdateBlizzardWaypoint()
    ns.Events:Fire("FG_NAV_TARGET_CHANGED", t)
end

function Nav:Clear()
    if not self.target then return end
    self.target = nil
    self.state = nil
    self:ClearBlizzardWaypoint()
    ns.Events:Fire("FG_NAV_TARGET_CHANGED", nil)
end

--- Turn the Blizzard map pin on/off and apply it to the current target right away.
function Nav:SetBlizzardWaypointEnabled(on)
    ns.db.nav.blizzardWaypoint = on and true or false
    if on then
        self:UpdateBlizzardWaypoint()
    else
        self:ClearBlizzardWaypoint()
    end
end

--- Remove the Blizzard pin only if it is still the one we placed (the player
--- may have set their own since).
function Nav:ClearBlizzardWaypoint()
    if not self.ownsWaypoint then return end
    self.ownsWaypoint = false
    local own = self.ownPoint
    self.ownPoint = nil
    local has = Plain(ns.Call("C_Map.HasUserWaypoint"))
    if has == false then return end
    local cur = ns.Call("C_Map.GetUserWaypoint")
    if type(cur) == "table" and own then
        local pos = cur.position
        local cx, cy = pos and PlainNumber(pos.x), pos and PlainNumber(pos.y)
        if PlainNumber(cur.uiMapID) ~= own.map or not cx or math.abs(cx - own.x) > 1e-3 or math.abs(cy - own.y) > 1e-3 then
            return   -- not ours any more
        end
    end
    ns.Call("C_Map.ClearUserWaypoint")
end

function Nav:UpdateBlizzardWaypoint()
    local t = self.target
    if not t then return end
    if not (ns.db and ns.db.nav.blizzardWaypoint) then return end
    if Plain(ns.Call("C_Map.CanSetUserWaypointOnMap", t.map)) ~= true then return end
    local UiMapPoint = rawget(_G, "UiMapPoint")
    if not UiMapPoint or type(UiMapPoint.CreateFromCoordinates) ~= "function" then return end
    local point = Safe(UiMapPoint.CreateFromCoordinates, t.map, t.x / 100, t.y / 100)
    if not point then return end
    local set = ns.Call("C_Map.SetUserWaypoint", point)
    if Plain(set) == true then
        self.ownsWaypoint = true
        self.ownPoint = { map = t.map, x = t.x / 100, y = t.y / 100 }
        ns.Call("C_SuperTrack.SetSuperTrackedUserWaypoint", true)
    end
end

-- ------------------------------------------------------------
-- Live update
-- ------------------------------------------------------------
--- Returns a state table (also stored in Nav.state):
---   distance (yards or nil), angle (relative radians, nil if unknown),
---   sameContinent (bool), method ("world"|"map"|nil), arrived (bool)
function Nav:Update(allowCached)
    local t = self.target
    if not t then
        self.state = nil
        return nil
    end
    -- the window, the arrow and the poller all tick; with allowCached they share one result per 40 ms
    if allowCached and self.state and self.stateTarget == t and ns.Now() - (self.stateAt or 0) < 0.04 then return self.state end
    local state = { distance = nil, angle = nil, sameContinent = true, method = nil, arrived = false }

    local px, py, pInstance = ns.Player:GetWorldPosition()
    if px and t.worldX then
        if pInstance and t.instanceID and pInstance ~= t.instanceID then
            state.sameContinent = false
        else
            local dx, dy = t.worldX - px, t.worldY - py
            state.distance = sqrt(dx * dx + dy * dy)
            state.method = "world"
            local facing = ns.Player:GetFacing()
            if facing then
                local bearing = atan2(dy, dx)
                local rel = bearing - facing
                while rel > pi do rel = rel - 2 * pi end
                while rel < -pi do rel = rel + 2 * pi end
                state.angle = rel
            end
        end
    end

    if not state.distance and state.sameContinent then
        -- fallback: map-space (works in instances if both are on the same map)
        local mapID, mx, my = ns.Player:GetMapPosition()
        if mapID and mx and mapID == t.map then
            local w, h = self:MapWorldSize(mapID)
            if w and h then
                local dx, dy = (t.x - mx) / 100 * w, (t.y - my) / 100 * h
                state.distance = sqrt(dx * dx + dy * dy)
                state.method = "map"
                local facing = ns.Player:GetFacing()
                if facing then
                    -- map axes: +x east, +y south. north component = -dy, west component = -dx
                    local rel = atan2(-dx, -dy) - facing
                    while rel > pi do rel = rel - 2 * pi end
                    while rel < -pi do rel = rel + 2 * pi end
                    state.angle = rel
                end
            end
        elseif mapID and mapID ~= t.map then
            state.otherMap = true
        end
    end

    state.arrived = state.distance ~= nil and state.distance <= (t.radius or 15)
    self.state, self.stateAt, self.stateTarget = state, ns.Now(), t
    if state.arrived and not t.arrivedFired then
        t.arrivedFired = true
        ns.Events:Fire("FG_NAV_ARRIVED", t)
    end
    return state
end

-- arrival must be noticed even when the window and the arrow are hidden
local poller = CreateFrame("Frame")
poller.elapsed = 0
poller:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = self.elapsed + (elapsed or 0)
    if self.elapsed < 0.25 or not Nav.target then return end
    self.elapsed = 0
    local ok, err = pcall(Nav.Update, Nav, true)
    if not ok then ns.ReportOnce("nav:poll", err) end
end)

-- ------------------------------------------------------------
-- Formatting
-- ------------------------------------------------------------
function Nav:FormatDistance(yards)
    if not yards then return "?" end
    if yards >= 1000 then return string.format("%.1f km", yards / 1000 * 0.9144) end
    return string.format("%d yd", math.floor(yards + 0.5))
end

--- "ahead", "ahead-left", "left", "behind-left", "behind", ... from a relative angle.
function Nav:DirectionWord(angle)
    if not angle then return "?" end
    local deg = angle * 180 / pi   -- positive = left
    local a = math.abs(deg)
    local side = deg > 0 and "left" or "right"
    if a < 22.5 then return "ahead" end
    if a < 67.5 then return "ahead-" .. side end
    if a < 112.5 then return side end
    if a < 157.5 then return "behind-" .. side end
    return "behind"
end

--- Clock-face direction ("12 o'clock" = straight ahead).
function Nav:ClockWord(angle)
    if not angle then return "?" end
    local deg = -angle * 180 / pi       -- clockwise positive
    local hour = math.floor((deg + 15) / 30) % 12
    if hour == 0 then hour = 12 end
    return hour .. " o'clock"
end

function Nav:Describe()
    local s = self.state or self:Update()
    if not self.target then return "no destination" end
    if not s then return "?" end
    if not s.sameContinent then return "different continent" end
    if s.otherMap then return "on another map (" .. tostring(ns.Player:GetMapName(self.target.map) or self.target.map) .. ")" end
    if not s.distance then return "position unavailable" end
    local dir = s.angle and (", " .. self:DirectionWord(s.angle)) or ""
    return self:FormatDistance(s.distance) .. dir
end

-- ------------------------------------------------------------
-- Resolve where a guide step points to
-- ------------------------------------------------------------
--- Returns mapID, x, y, label for a step (or nil). Order of preference:
---  1. explicit step.map/x/y
---  2. step.zone name matching the player's current map + x/y
---  3. the bundled quest database (giver / turn-in / objective spawns / npc / item sources)
---  4. Blizzard's quest waypoint for step.quest
local validMap = {}   -- mapID -> true/false (does this client know the map?)
function Nav:IsValidMap(mapID)
    if not mapID then return false end
    if validMap[mapID] == nil then
        local info = ns.Call("C_Map.GetMapInfo", mapID)
        validMap[mapID] = type(info) == "table" and info.name ~= nil
    end
    return validMap[mapID]
end

function Nav:ResolveStep(step)
    if not step then return nil end
    if ns.Editor then step = ns.Editor:Effective(step) end   -- in-game corrections win
    if step.near and not step.edited then
        -- objective with many spawns: the nearest known one beats the planned spot
        local loc = self:DBLocationForStep(step)
        if loc then return loc.map, loc.x, loc.y, step.text or loc.name, loc end
    end
    if step.x and step.y then
        local mapID = step.map
        -- guide data may carry Classic-era map IDs; if Forever does not know
        -- the ID, fall back to matching the zone by name.
        if mapID and not self:IsValidMap(mapID) then mapID = nil end
        if not mapID and step.zone then
            local curMap = ns.Player:GetMapID()
            local curName = ns.Player:GetMapName(curMap)
            if curName and curName == step.zone then mapID = curMap end
            if not mapID and ns.db and ns.db.recorder.maps then
                for id, info in pairs(ns.db.recorder.maps) do
                    if info.name == step.zone then mapID = id break end
                end
            end
        end
        if mapID then return mapID, step.x, step.y, step.text end
    end
    local loc = self:DBLocationForStep(step)
    if loc then return loc.map, loc.x, loc.y, step.text or loc.name, loc end
    if step.quest then
        local mapID, x, y = ns.Quest:GetWaypoint(step.quest)
        if mapID then return mapID, x, y, step.text end
    end
    return nil
end

--- Nearest database location that makes progress on a step, or nil.
function Nav:DBLocationForStep(step)
    local DB = ns.DB
    if not DB or not DB:IsLoaded() then return nil end
    local t = step.type
    local locs
    if step.npc and (t == "TALK" or t == "TRAIN" or t == "FLY" or t == "ACCEPT" or t == "TURNIN" or t == "HEARTH") then
        locs = DB:NPCLocations(step.npc)
    end
    if (not locs or #locs == 0) and step.quest then
        if t == "ACCEPT" then
            locs = DB:QuestStarts(step.quest)
        elseif t == "TURNIN" then
            locs = DB:QuestEnds(step.quest)
        elseif ns.Guide.OBJECTIVE[t] then
            locs = {}
            local game = ns.Quest:GetObjectives(step.quest)
            local objIdx = ns.Guide:StepObjectiveIndex(step)
            if objIdx then
                local o = game and game[objIdx]
                local dbo = DB:MatchObjective(step.quest, objIdx, o and o.text)
                if dbo then for _, l in ipairs(dbo.locations) do locs[#locs + 1] = l end end
            elseif game and #game > 0 then
                for idx, o in ipairs(game) do
                    if not o.finished then
                        local dbo = DB:MatchObjective(step.quest, idx, o.text)
                        if dbo then for _, l in ipairs(dbo.locations) do locs[#locs + 1] = l end end
                    end
                end
            end
            if #locs == 0 then
                if step.npc then
                    locs = DB:NPCLocations(step.npc)
                else
                    for _, dbo in ipairs(DB:QuestObjectives(step.quest)) do
                        for _, l in ipairs(dbo.locations) do locs[#locs + 1] = l end
                    end
                end
            end
        end
    end
    if (not locs or #locs == 0) and step.npc then locs = DB:NPCLocations(step.npc) end
    if (not locs or #locs == 0) and step.item and t == "BUY" then locs = DB:ItemLocations(step.item) end
    if not locs or #locs == 0 then return nil end
    local loc = DB:Nearest(locs)
    return loc
end
