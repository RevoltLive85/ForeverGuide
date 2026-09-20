-- ============================================================
-- ForeverGuide / Corpse.lua
-- Dead? Then the only place worth walking to is your corpse. While the
-- player is a ghost the navigation target (diamond, dotted route, arrow)
-- points at the corpse - C_DeathInfo.GetCorpseMapPosition(uiMapID) - and
-- the guide / tracker are kept from overriding it. Back in the body, the
-- guide's own target returns.
-- ============================================================

local _, ns = ...
local Corpse = ns:NewModule("Corpse")

local ticker

local function isGhost()
    return ns.Plain(ns.Safe(rawget(_G, "UnitIsGhost"), "player")) == true
end

--- map id + 0-100 coordinates of the corpse, on the map the ghost is on (or its parents)
function Corpse:Position()
    local DI = rawget(_G, "C_DeathInfo")
    if not DI or type(DI.GetCorpseMapPosition) ~= "function" then return nil end
    local mapID = ns.Player:GetMapID()
    local tries = 0
    while mapID and tries < 4 do
        local pos = ns.Safe(DI.GetCorpseMapPosition, mapID)
        if type(pos) == "table" then
            local x, y = ns.PlainNumber(pos.x), ns.PlainNumber(pos.y)
            if x and y and (x > 0 or y > 0) then return mapID, x * 100, y * 100 end
        end
        local info = ns.Call("C_Map.GetMapInfo", mapID)
        mapID = type(info) == "table" and ns.PlainNumber(info.parentMapID) or nil
        tries = tries + 1
    end
    return nil
end

function Corpse:Refresh()
    local Nav = ns.Navigation
    if isGhost() then
        local map, x, y = self:Position()
        if map then
            local t = Nav.target
            if not (t and t.owner == "corpse" and t.map == map and math.abs(t.x - x) < 0.05 and math.abs(t.y - y) < 0.05) then
                Nav.override = "corpse"
                Nav:SetTarget({ map = map, x = x, y = y, label = "Your corpse - run back", radius = 10, owner = "corpse" })
            end
        end
        if not ticker then
            ticker = CreateFrame("Frame")
            ticker.elapsed = 0
            ticker:SetScript("OnUpdate", function(self, elapsed)
                self.elapsed = self.elapsed + (elapsed or 0)
                if self.elapsed < 1 then return end
                self.elapsed = 0
                local ok, err = pcall(Corpse.Refresh, Corpse)
                if not ok then ns.ReportOnce("corpse:refresh", err) end
            end)
        end
        ticker:Show()
    elseif Nav.override == "corpse" then
        Nav.override = nil
        if ticker then ticker:Hide() end
        if Nav.target and Nav.target.owner == "corpse" then Nav:Clear() end
        -- hand navigation back to whoever owns it
        if ns.Tracker and ns.Tracker:IsActive() then ns.Tracker:Rethink() elseif ns.Guide then ns.Guide:UpdateNavigation() end
    elseif ticker then
        ticker:Hide()
    end
end

function Corpse:OnInit()
    ns.Events:RegisterMany({ "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "ZONE_CHANGED_NEW_AREA", "PLAYER_MAP_CHANGED" },
        function() Corpse:Refresh() end)
end

function Corpse:OnEnterWorld()
    self:Refresh()
end
