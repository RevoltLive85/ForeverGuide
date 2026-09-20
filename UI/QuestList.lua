-- ============================================================
-- ForeverGuide / UI/QuestList.lua
-- The vertical list of rows (a pool of QuestRow frames, reused), stacked
-- top-down; distances refreshed on a throttle, rows only re-set when the
-- entries change.
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local Row = ns.QuestRow
local List = {}
ns.QuestList = List

local GAP = 3

function List.Create(parent)
    local l = CreateFrame("Frame", nil, parent)
    l.rows = {}
    l.entries = {}
    l.height = 0
    l.Set = List.Set
    l.Layout = List.Layout
    l.UpdateDistances = List.UpdateDistances
    l.empty = Theme.NewText(l, { size = 11, color = Theme.C.textDim, justify = "CENTER", maxLines = 3 })
    l.empty:SetPoint("TOPLEFT", l, "TOPLEFT", 14, -10)
    l.empty:SetPoint("TOPRIGHT", l, "TOPRIGHT", -14, -10)
    l.empty:Hide()
    return l
end

local function row(l, i)
    local r = l.rows[i]
    if not r then
        r = Row.Create(l, i)
        l.rows[i] = r
    end
    return r
end

--- entries: list of row entries (see QuestRow.Set). emptyText shown when there are none.
function List.Set(l, entries, emptyText)
    l.entries = entries or {}
    local showSub = ns.db.ui.showSubtitles ~= false
    for i, e in ipairs(l.entries) do
        local r = row(l, i)
        r:Set(e, showSub)
        r:Show()
    end
    for i = #l.entries + 1, #l.rows do l.rows[i]:Hide() end
    if #l.entries == 0 then
        l.empty:SetText(emptyText or "")
        l.empty:Show()
    else
        l.empty:Hide()
    end
    l:Layout()
    l:UpdateDistances(true)
end

function List.Layout(l)
    local y = 4
    for i, e in ipairs(l.entries) do
        local r = l.rows[i]
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", l, "TOPLEFT", 2, -y)
        r:SetPoint("TOPRIGHT", l, "TOPRIGHT", -2, -y)
        y = y + r:GetHeight() + GAP
    end
    if #l.entries == 0 then y = y + 40 end
    l.height = y + 2
    l:SetHeight(l.height)
end

--- Distances: the active row shows the navigation distance, the others their own.
function List.UpdateDistances(l, force)
    if ns.db.ui.showDistances == false then
        for i in ipairs(l.entries) do l.rows[i]:SetDistance("") end
        return
    end
    local Nav, DB = ns.Navigation, ns.DB
    for i, e in ipairs(l.entries) do
        local r = l.rows[i]
        local text
        if e.state == "active" and Nav.target and Nav.state and Nav.state.distance then
            text = Nav:FormatDistance(Nav.state.distance)
        elseif e.distanceText then
            text = e.distanceText
        elseif e.step and DB and DB:IsLoaded() then
            if e._loc == nil or force then
                local map, x, y, _, loc = Nav:ResolveStep(e.step)
                e._loc = (map and { map = map, x = x, y = y }) or loc or false
            end
            local d = e._loc and DB:DistanceTo(e._loc)
            text = d and Nav:FormatDistance(d) or ""
        elseif e.loc then
            local d = DB and DB:DistanceTo(e.loc)
            text = d and Nav:FormatDistance(d) or ""
        end
        r:SetDistance(text or "")
    end
end
