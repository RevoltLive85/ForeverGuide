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
    ns.db.bags = ns.db.bags or { warn = WARN_FREE, banners = false }
    return ns.db.bags
end

local function getContainer()
    local C = rawget(_G, "C_Container")
    if C and C.GetContainerNumFreeSlots then return C end
    return nil
end

local function itemName(info)
    local link = info.hyperlink or info.itemLink
    local name = type(link) == "string" and link:match("%[(.-)%]")
    if not name and info.itemID then name = ns.PlainString(ns.Call("C_Item.GetItemNameByID", ns.PlainNumber(info.itemID))) end
    return name
end

--- { free, total, junk, leftover, leftoverNames } for bags 0-4 (nil when the container API is missing)
function Bags:Status()
    local C = getContainer()
    if not C then return nil end
    local free, total, junk, leftover, leftoverNames = 0, 0, 0, 0, {}
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
                    elseif type(info) == "table" and ns.ItemTips and ns.ItemTips.Leftover then
                        -- quest ingredients from a quest already turned in: clutter, safe to sell
                        local id = ns.PlainNumber(info.itemID)
                        local name = itemName(info)
                        if (id or name) and ns.ItemTips:Leftover(id, name) then
                            leftover = leftover + 1
                            if name and not leftoverNames[name] then leftoverNames[name] = true leftoverNames[#leftoverNames + 1] = name end
                        end
                    end
                end
            end
        end
    end
    return { free = free, total = total, junk = junk, leftover = leftover, leftoverNames = leftoverNames }
end

local DURABILITY_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 16, 17, 18 }   -- head..ranged; the rest never wears
local SLOT_NAME = { [1] = "head", [3] = "shoulders", [5] = "chest", [6] = "belt", [7] = "legs", [8] = "boots",
                    [9] = "bracers", [10] = "gloves", [16] = "main hand", [17] = "off hand", [18] = "ranged" }
local WARN_DURABILITY = 25   -- percent

--- Gear wear: percent left over everything you are wearing, how many pieces are broken,
--- and the worst piece. nil when the client cannot say (or you wear nothing that wears).
function Bags:Durability()
    local f = rawget(_G, "GetInventoryItemDurability")
    if type(f) ~= "function" then return nil end
    local cur, max, broken, worst, worstPct = 0, 0, 0, nil, nil
    for _, slot in ipairs(DURABILITY_SLOTS) do
        local c, m = ns.Safe(f, slot)
        c, m = ns.PlainNumber(c), ns.PlainNumber(m)
        if c and m and m > 0 then
            cur, max = cur + c, max + m
            local pct = c / m * 100
            if c <= 0 then broken = broken + 1 end
            if not worstPct or pct < worstPct then worst, worstPct = SLOT_NAME[slot] or ("slot " .. slot), pct end
        end
    end
    if max <= 0 then return nil end
    return { percent = cur / max * 100, broken = broken, worst = worst, worstPercent = worstPct }
end

--- Is the gear worth a trip to a vendor? (returns the reading when it is)
function Bags:GearLow()
    local d = self:Durability()
    if not d then return nil end
    if d.broken > 0 or d.percent <= (cfg().durability or WARN_DURABILITY) then return d end
    return nil
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

--- short tag for the header ("bags 2/16" / "gear 18%"), or nil when nothing needs doing
function Bags:Tag()
    local st = self.last or self:Status()
    if st and st.total > 0 and st.free <= (cfg().warn or WARN_FREE) then
        return string.format("bags %d/%d", st.free, st.total), st.free == 0
    end
    local d = self:GearLow()
    if d then return string.format("gear %d%%", math.floor(d.percent)), d.broken > 0 end
    return nil
end

--- the full advice line, or nil
function Bags:Advice(force)
    local st = self:Status()
    self.last = st
    if not st or st.total == 0 then return nil end
    if not force and st.free > (cfg().warn or WARN_FREE) and not self:GearLow() then return nil end
    local parts = {}
    if st.free > (cfg().warn or WARN_FREE) then
        local gear = self:GearLow()
        if gear then
            local name, d = self:NearestVendor()
            return (gear.broken > 0 and string.format("%d piece%s of your gear %s broken.", gear.broken, gear.broken == 1 and "" or "s", gear.broken == 1 and "is" or "are")
                or string.format("Your gear is at %d%% (worst: %s at %d%%) - repair when you can.", math.floor(gear.percent), gear.worst or "?", math.floor(gear.worstPercent or 0)))
                .. (name and string.format(" Nearest vendor: %s (%s).", name, ns.Navigation:FormatDistance(d)) or "")
        end
    end
    if st.free == 0 then parts[#parts + 1] = "Bags are FULL - quest loot will be missed."
    else parts[#parts + 1] = string.format("Bags nearly full (%d free of %d).", st.free, st.total) end
    if st.junk > 0 then parts[#parts + 1] = string.format("%d grey item%s to sell (quest items are never counted).", st.junk, st.junk == 1 and "" or "s") end
    if st.leftover > 0 then parts[#parts + 1] = string.format("%d stack%s of leftover quest ingredients you can sell (%s).", st.leftover, st.leftover == 1 and "" or "s", table.concat(st.leftoverNames, ", ")) end
    if st.junk == 0 and st.leftover == 0 then parts[#parts + 1] = "Nothing grey or left over to sell - bank or vendor gear you do not need (never quest items)." end
    local gear = self:GearLow()
    if gear then
        parts[#parts + 1] = gear.broken > 0 and string.format("%d piece%s of gear broken.", gear.broken, gear.broken == 1 and "" or "s")
            or string.format("Gear at %d%% - repair while you are there.", math.floor(gear.percent))
    end
    local name, d = self:NearestVendor()
    if name then parts[#parts + 1] = string.format("Nearest vendor: %s (%s).", name, ns.Navigation:FormatDistance(d)) end
    return table.concat(parts, " ")
end

-- ---- the on-screen banner ------------------------------------------------------------------
--   ┌────────────────────────────────────────────┐
--   │ [bag]  BAGS FULL - quest loot will be missed │   top centre, under the zone text
--   │        3 grey items to sell - Yuka (2.0 km)  │
--   └────────────────────────────────────────────┘
local banner
local function Banner()
    if banner then return banner end
    local Theme = ns.Theme
    local ok, f = pcall(CreateFrame, "Frame", "ForeverGuideBagBanner", UIParent, "BackdropTemplate")
    if not ok or not f then f = CreateFrame("Frame", "ForeverGuideBagBanner", UIParent) end
    banner = f
    f:SetSize(420, 52)
    f:SetPoint("TOP", UIParent, "TOP", 0, -150)
    f:SetFrameStrata("HIGH")
    if Theme and Theme.Backdrop then Theme.Backdrop(f, "panel", 0.75) end
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(30, 30)
    f.icon:SetPoint("LEFT", f, "LEFT", 12, 0)
    pcall(f.icon.SetTexture, f.icon, "Interface\\Icons\\INV_Misc_Bag_08")
    pcall(f.icon.SetTexCoord, f.icon, 0.08, 0.92, 0.08, 0.92)
    f.title = Theme and Theme.NewText(f, { fancy = true, size = 15, color = { 1, 0.35, 0.25 }, oneLine = true, shadow = true }) or f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, 0)
    f.title:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    f.sub = Theme and Theme.NewText(f, { size = 11, color = Theme.C.text, oneLine = true }) or f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.sub:SetPoint("BOTTOMLEFT", f.icon, "BOTTOMRIGHT", 10, 1)
    f.sub:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    f:EnableMouse(true)
    f:SetScript("OnMouseUp", function() Bags.snoozedUntil = ns.Now() + 120 f:Hide() end)
    f:SetScript("OnEnter", function(self)
        local tt = rawget(_G, "GameTooltip")
        if tt then tt:SetOwner(self, "ANCHOR_BOTTOM") tt:AddLine("Click to hide for 2 minutes", 0.85, 0.82, 0.75) tt:Show() end
    end)
    f:SetScript("OnLeave", function() local tt = rawget(_G, "GameTooltip") if tt then tt:Hide() end end)
    f:Hide()
    return f
end

function Bags:UpdateBanner()
    if cfg().banners ~= true then if banner then banner:Hide() end return end
    local st = self.last or self:Status()
    local f = Banner()
    local hidden = ns.UI and ns.UI.AllHidden and ns.UI:AllHidden()
    local bagsLow = st and st.total > 0 and st.free <= (cfg().warn or WARN_FREE)
    local gear = (not bagsLow) and self:GearLow() or nil
    if (not bagsLow and not gear) or hidden or (self.snoozedUntil and ns.Now() < self.snoozedUntil) then
        f:Hide()
        return
    end
    if gear then
        -- the bags are fine but the gear is not: same banner, same errand (a vendor)
        local broken = gear.broken > 0
        f.title:SetText(broken and string.format("%d piece%s of your gear %s broken", gear.broken, gear.broken == 1 and "" or "s", gear.broken == 1 and "is" or "are")
            or string.format("Gear at %d%% - time to repair", math.floor(gear.percent)))
        if ns.Theme then ns.Theme.Color(f.title, broken and { 1, 0.35, 0.25 } or { 1, 0.7, 0.3 }) end
        pcall(f.icon.SetTexture, f.icon, "Interface\\Icons\\INV_Hammer_20")
        local sub = gear.worst and string.format("worst: your %s at %d%%", gear.worst, math.floor(gear.worstPercent or 0)) or "visit a repair vendor"
        local name, d = self:NearestVendor()
        if name then sub = sub .. string.format("  ·  nearest vendor %s (%s)", name, ns.Navigation:FormatDistance(d)) end
        f.sub:SetText(sub)
        if ns.Theme and ns.Theme.Pulse then
            ns.Theme.Pulse(f.icon, 1.4, 0.55, 1.0)
            ns.Theme.SetPulseEnabled(f.icon, broken)
        end
        f:Show()
        return
    end
    pcall(f.icon.SetTexture, f.icon, "Interface\\Icons\\INV_Misc_Bag_08")
    local full = st.free == 0
    f.title:SetText(full and "BAGS FULL - quest loot will be missed" or string.format("Bags nearly full - %d slot%s left", st.free, st.free == 1 and "" or "s"))
    if ns.Theme then ns.Theme.Color(f.title, full and { 1, 0.35, 0.25 } or { 1, 0.7, 0.3 }) end
    local bits = {}
    if st.junk > 0 then bits[#bits + 1] = string.format("%d grey item%s to sell", st.junk, st.junk == 1 and "" or "s") end
    if st.leftover > 0 then bits[#bits + 1] = string.format("%d leftover quest ingredient%s to sell", st.leftover, st.leftover == 1 and "" or "s") end
    local sub = #bits > 0 and table.concat(bits, ", ") or "nothing grey to sell - bank or vendor gear you do not need"
    local name, d = self:NearestVendor()
    if name then sub = sub .. string.format("  ·  nearest vendor %s (%s)", name, ns.Navigation:FormatDistance(d)) end
    f.sub:SetText(sub)
    if ns.Theme and ns.Theme.Pulse then
        ns.Theme.Pulse(f.icon, 1.4, 0.55, 1.0)
        ns.Theme.SetPulseEnabled(f.icon, full)
    end
    f:Show()
end

-- a chat line when the bags cross a threshold (once per crossing), and on a loot step with low space
local lastBand
function Bags:Check(reason)
    local st = self:Status()
    self.last = st
    if not st or st.total == 0 then return end
    local gear = self:GearLow()
    local band = st.free == 0 and 2 or (st.free <= (cfg().warn or WARN_FREE) and 1 or 0)
    if band == 0 and gear then band = gear.broken > 0 and 2 or 1 end
    local step = ns.Guide and ns.Guide:GetCurrentStep()
    local lootStep = step and (step.type == "COLLECT" or step.type == "KILL" or step.type == "COMPLETE")
    if band > (lastBand or 0) or (reason == "step" and band > 0 and lootStep and self.warnedStep ~= (step and step.index)) then
        local advice = self:Advice(true)
        if advice and cfg().banners == true then ns.Print(advice) end
        if reason == "step" and step then self.warnedStep = step.index end
    end
    lastBand = band
    if band == 0 then self.snoozedUntil = nil end
    self:UpdateBanner()
    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
end

function Bags:OnInit()
    ns.Events:Register("BAG_UPDATE_DELAYED", function() ns.Events:Debounce("bags", 0.5, function() Bags:Check("bags") end) end)
    ns.Events:RegisterMany({ "UPDATE_INVENTORY_DURABILITY", "PLAYER_UNGHOST", "PLAYER_ALIVE" },
        function() ns.Events:Debounce("bags:gear", 2, function() Bags:Check("gear") end) end)
    ns.Events:RegisterMany({ "FG_STEP_CHANGED", "FG_GUIDE_CHANGED" }, function() ns.Events:Debounce("bags:step", 0.5, function() Bags:Check("step") end) end)
end

function Bags:OnEnable()
    self.last = self:Status()
    self:UpdateBanner()
    ns.Events:Register("FG_HIDDEN_ALL_CHANGED", function() Bags:UpdateBanner() end)
end
