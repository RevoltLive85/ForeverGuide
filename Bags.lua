-- ============================================================
-- ForeverGuide / Bags.lua
-- Quest loot needs a free slot. This module watches the bags and, when
-- space runs low, says so where it matters: a "bags 2/16" tag in the
-- Quest Guide header, one chat line per threshold crossed, and the info
-- popup - with the number of grey items to sell and the nearest vendor
-- the database knows (any npc that sells something, nearest known spawn).
-- ============================================================

local _, ns = ...
local Bags = ns:NewModule("Bags")

local WARN_FREE = 3          -- "getting full" at this many free slots
local vendorIDs              -- npcID -> true, built on first use from ItemDB

local function cfg()
    ns.db.bags = ns.db.bags or { warn = WARN_FREE }
    return ns.db.bags
end

local function getContainer()
    local C = rawget(_G, "C_Container")
    if C and C.GetContainerNumFreeSlots then return C end
    return nil
end

--- { free, total, junk } for bags 0-4 (nil when the container API is missing)
function Bags:Status()
    local C = getContainer()
    if not C then return nil end
    local free, total, junk = 0, 0, 0
    for bag = 0, 4 do
        local n = ns.PlainNumber(ns.Safe(C.GetContainerNumSlots, bag)) or 0
        if n > 0 then
            total = total + n
            local f = ns.PlainNumber(ns.Safe(C.GetContainerNumFreeSlots, bag))
            free = free + (f or 0)
            if C.GetContainerItemInfo then
                for slot = 1, n do
                    local info = ns.Safe(C.GetContainerItemInfo, bag, slot)
                    -- only grey (poor) items with a sell value are "junk"; quest items (no value, or
                    -- flagged) are never suggested for sale
                    if type(info) == "table" and ns.PlainNumber(info.quality) == 0 and ns.Plain(info.hasNoValue) ~= true
                        and ns.Plain(info.isQuestItem) ~= true then
                        junk = junk + 1
                    end
                end
            end
        end
    end
    return { free = free, total = total, junk = junk }
end

--- nearest npc that sells anything, with a known position: name, distance (yards) or nil
function Bags:NearestVendor()
    local DB = ns.DB
    if not DB or not DB:IsLoaded() or not ns.ItemDB then return nil end
    if not vendorIDs then
        vendorIDs = {}
        for _, it in pairs(ns.ItemDB) do
            for _, v in ipairs(it.vendors or {}) do vendorIDs[v] = true end
        end
    end
    local best, bestD
    local px, py, pInst = ns.Player:GetWorldPosition()
    if not px then return nil end
    for id in pairs(vendorIDs) do
        local locs = DB:NPCLocations(id)
        if #locs > 0 then
            local loc = DB:Nearest(locs)
            if loc then
                local inst, wx, wy = ns.Navigation:MapToWorld(loc.map, loc.x, loc.y)
                if inst and inst == pInst and wx then
                    local d = math.sqrt((wx - px) ^ 2 + (wy - py) ^ 2)
                    if not bestD or d < bestD then best, bestD = loc, d end
                end
            end
        end
    end
    if not best then return nil end
    return best.name or DB:NPCName(best.id) or "a vendor", bestD, best
end

--- short tag for the header ("bags 2/16"), or nil when there is room
function Bags:Tag()
    local st = self.last or self:Status()
    if not st or st.total == 0 then return nil end
    if st.free > (cfg().warn or WARN_FREE) then return nil end
    return string.format("bags %d/%d", st.free, st.total), st.free == 0
end

--- the full advice line, or nil
function Bags:Advice(force)
    local st = self:Status()
    self.last = st
    if not st or st.total == 0 then return nil end
    if not force and st.free > (cfg().warn or WARN_FREE) then return nil end
    local parts = {}
    if st.free == 0 then parts[#parts + 1] = "Bags are FULL - quest loot will be missed."
    else parts[#parts + 1] = string.format("Bags nearly full (%d free of %d).", st.free, st.total) end
    if st.junk > 0 then parts[#parts + 1] = string.format("%d grey item%s to sell (quest items are never counted).", st.junk, st.junk == 1 and "" or "s")
    else parts[#parts + 1] = "Nothing grey to sell - bank or vendor gear you do not need (never quest items)." end
    local name, d = self:NearestVendor()
    if name then parts[#parts + 1] = string.format("Nearest vendor: %s (%s).", name, ns.Navigation:FormatDistance(d)) end
    return table.concat(parts, " ")
end

-- a chat line when the bags cross a threshold (once per crossing), and on a loot step with low space
local lastBand
function Bags:Check(reason)
    local st = self:Status()
    self.last = st
    if not st or st.total == 0 then return end
    local band = st.free == 0 and 2 or (st.free <= (cfg().warn or WARN_FREE) and 1 or 0)
    local step = ns.Guide and ns.Guide:GetCurrentStep()
    local lootStep = step and (step.type == "COLLECT" or step.type == "KILL" or step.type == "COMPLETE")
    if band > (lastBand or 0) or (reason == "step" and band > 0 and lootStep and self.warnedStep ~= (step and step.index)) then
        local advice = self:Advice(true)
        if advice then ns.Print(advice) end
        if reason == "step" and step then self.warnedStep = step.index end
    end
    lastBand = band
    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
end

function Bags:OnInit()
    ns.Events:Register("BAG_UPDATE_DELAYED", function() ns.Events:Debounce("bags", 0.5, function() Bags:Check("bags") end) end)
    ns.Events:RegisterMany({ "FG_STEP_CHANGED", "FG_GUIDE_CHANGED" }, function() ns.Events:Debounce("bags:step", 0.5, function() Bags:Check("step") end) end)
end

function Bags:OnEnable()
    self.last = self:Status()
end
