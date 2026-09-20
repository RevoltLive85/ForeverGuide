-- ============================================================
-- ForeverGuide / ItemTips.lua
-- Item tooltips get the quest side of the story:
--
--     Tough Condor Meat
--     Crafting Reagent
--     Sell Price: 78c
--     ─────────────────────────────
--     Quest item: Redridge Goulash (1/5)        <- in your log: keep it
--     Quest item for: Some Later Quest          <- on your route, not taken yet
--     Starts a quest: Gold Pickup Schedule      <- right-click to start
--
-- Sources: the live quest log (objective text naming the item, so it
-- works for Forever's rewritten quests too), the database (quests whose
-- objectives collect the item, items that start quests) and the active
-- guide (quests still ahead of you).
-- ============================================================

local _, ns = ...
local Tips = ns:NewModule("ItemTips")

local itemQuests          -- itemID -> { questID, ... } built on first use from QuestDB

local function index()
    if itemQuests then return itemQuests end
    itemQuests = {}
    for qid, q in pairs(ns.QuestDB or {}) do
        for _, e in ipairs(q.item or {}) do
            local id = e[1]
            if id then
                itemQuests[id] = itemQuests[id] or {}
                table.insert(itemQuests[id], qid)
            end
        end
    end
    return itemQuests
end

--- Lines to add for an item: { { text, kind }, ... }  kind = "log" | "route" | "starts"
function Tips:LinesFor(itemID, itemName)
    local out = {}
    local seen = {}
    local Q = ns.Quest
    local lower = itemName and string.lower(itemName)
    -- 1. the live log: any objective whose text names the item
    if Q and lower and lower ~= "" then
        for _, questID in ipairs(Q.order or {}) do
            for _, o in ipairs(Q:GetObjectives(questID) or {}) do
                if o.text and string.find(string.lower(o.text), lower, 1, true) then
                    local title = Q:GetTitle(questID) or ("quest " .. questID)
                    local prog = (o.numRequired and o.numRequired > 0) and string.format(" (%d/%d)", o.numFulfilled or 0, o.numRequired) or ""
                    out[#out + 1] = { string.format("Quest item: %s%s", title, prog), o.finished and "done" or "log" }
                    seen[questID] = true
                    break
                end
            end
        end
    end
    -- 2. the database: quests collecting this item that are not in the log
    if itemID and ns.DB and ns.DB:IsLoaded() then
        local active = ns.Guide and ns.Guide.active
        local ahead = {}
        if active and rawget(active, "steps") then
            for i = (ns.Guide.current or 1), #active.steps do
                local s = active.steps[i]
                if s.quest then ahead[s.quest] = true end
            end
        end
        for _, qid in ipairs(index()[itemID] or {}) do
            if not seen[qid] and not ns.DB:IsRemoved(qid) and not (Q and Q:IsCompleted(qid)) then
                local name = ns.DB:QuestName(qid) or ("quest " .. qid)
                if ahead[qid] then
                    out[#out + 1] = { "Quest item for: " .. name .. " (later in your guide - keep it)", "route" }
                elseif Q and Q:IsOnQuest(qid) then
                    out[#out + 1] = { "Quest item: " .. name, "log" }
                else
                    out[#out + 1] = { "Quest item for: " .. name, "other" }
                end
                seen[qid] = true
            end
        end
        local it = ns.DB:GetItem(itemID)
        if it and it.startq and not (Q and Q:IsCompleted(it.startq)) and not (Q and Q:IsOnQuest(it.startq)) then
            out[#out + 1] = { "Starts a quest: " .. (ns.DB:QuestName(it.startq) or ("quest " .. it.startq)) .. " - right-click it", "starts" }
        end
    end
    return out
end

local COLORS = { log = { 1, 0.82, 0.2 }, done = { 0.6, 0.75, 0.5 }, route = { 1, 0.7, 0.3 }, other = { 0.8, 0.75, 0.6 }, starts = { 0.55, 0.85, 0.45 } }

local function decorate(tooltip, itemID, itemName)
    if not tooltip or not tooltip.AddLine then return end
    local ok, lines = pcall(Tips.LinesFor, Tips, itemID, itemName)
    if not ok then ns.ReportOnce("itemtips", lines) return end
    if #lines == 0 then return end
    pcall(tooltip.AddLine, tooltip, " ")
    for _, l in ipairs(lines) do
        local c = COLORS[l[2]] or COLORS.other
        pcall(tooltip.AddLine, tooltip, "|TInterface\\GossipFrame\\ActiveQuestIcon:12|t " .. l[1], c[1], c[2], c[3], true)
    end
    if tooltip.Show then pcall(tooltip.Show, tooltip) end
end

local function itemFromTooltip(tooltip, data)
    local id = data and ns.PlainNumber(data.id)
    local name
    if data and type(data.lines) == "table" and data.lines[1] then name = ns.PlainString(data.lines[1].leftText) end
    if not name and tooltip.GetItem then
        local okn, n = pcall(tooltip.GetItem, tooltip)
        if okn then name = ns.PlainString(n) end
    end
    if not name and id then name = ns.PlainString(ns.Call("C_Item.GetItemNameByID", id)) end
    return id, name
end

function Tips:OnEnable()
    local TDP = rawget(_G, "TooltipDataProcessor")
    local E = rawget(_G, "Enum")
    if TDP and TDP.AddTooltipPostCall and E and E.TooltipDataType and E.TooltipDataType.Item then
        TDP.AddTooltipPostCall(E.TooltipDataType.Item, function(tooltip, data)
            if tooltip ~= rawget(_G, "GameTooltip") and tooltip ~= rawget(_G, "ItemRefTooltip") then return end
            local id, name = itemFromTooltip(tooltip, data)
            if id or name then decorate(tooltip, id, name) end
        end)
        self.hooked = "TooltipDataProcessor"
    else
        local gt = rawget(_G, "GameTooltip")
        if gt and gt.HookScript then
            pcall(gt.HookScript, gt, "OnTooltipSetItem", function(tooltip)
                local okn, name, link = pcall(tooltip.GetItem, tooltip)
                local id = link and tonumber(string.match(link, "item:(%d+)"))
                if okn and (id or name) then decorate(tooltip, id, ns.PlainString(name)) end
            end)
            self.hooked = "OnTooltipSetItem"
        end
    end
end
