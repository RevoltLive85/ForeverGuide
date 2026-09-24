-- ============================================================
-- ForeverGuide / UI/QuestRow.lua
-- One row of the quest list:
--   (06) [icon]  Hilary's Necklace                     85 yd
--                Find Hilary's Necklace
-- States: available | active | done | blocked | optional | future
-- Rows are created once and reused (QuestList keeps the pool).
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local Row = {}
ns.QuestRow = Row

Row.HEIGHT_TWO = 36    -- title + subtitle
Row.HEIGHT_ONE = 24    -- title only
local LEFT = 44        -- x of the title (after ring + icon)
local RING = 20
local ICON = 16

local STATE = {
    available = { title = Theme.C.text,      sub = Theme.C.textDim, dist = Theme.C.textDim, icon = 1.0,  alpha = 1.0,  ring = Theme.C.gold },
    active    = { title = Theme.C.goldLight, sub = Theme.C.text,    dist = Theme.C.goldLight, icon = 1.0, alpha = 1.0, ring = Theme.C.goldLight },
    done      = { title = Theme.C.done,      sub = Theme.C.muted,   dist = Theme.C.muted,   icon = 0.55, alpha = 0.62, ring = Theme.C.muted },
    blocked   = { title = Theme.C.blocked,   sub = Theme.C.muted,   dist = Theme.C.muted,   icon = 0.8,  alpha = 0.8,  ring = Theme.C.blocked },
    optional  = { title = Theme.C.textDim,   sub = Theme.C.muted,   dist = Theme.C.muted,   icon = 0.7,  alpha = 0.7,  ring = Theme.C.goldDim },
    future    = { title = Theme.C.textDim,   sub = Theme.C.muted,   dist = Theme.C.muted,   icon = 0.75, alpha = 0.78, ring = Theme.C.goldDim },
}

function Row.Create(parent, index)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(Row.HEIGHT_TWO)
    r.index = index

    -- active-row dressing (hidden unless active)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetPoint("TOPLEFT", r, "TOPLEFT", 2, 0)
    r.bg:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -2, 0)
    pcall(r.bg.SetTexture, r.bg, Theme.TEX.rowActive)
    r.bg:SetVertexColor(0.24, 0.28, 0.34, 0.65)
    r.bg:Hide()

    local ok, outline = pcall(CreateFrame, "Frame", nil, r, "BackdropTemplate")
    if ok and outline then
        outline:SetPoint("TOPLEFT", r, "TOPLEFT", 1, 1)
        outline:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -1, -1)
        Theme.Backdrop(outline, "thin", 0.85)
        outline:Hide()
        r.outline = outline
    end

    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetSize(6, Row.HEIGHT_TWO - 6)
    r.bar:SetPoint("LEFT", r, "LEFT", 0, 0)
    pcall(r.bar.SetTexture, r.bar, Theme.TEX.rowBar)
    r.bar:SetVertexColor(0.75, 0.80, 0.87, 1)
    r.bar:Hide()

    -- number ring
    r.ring = r:CreateTexture(nil, "ARTWORK")
    r.ring:SetSize(RING, RING)
    r.ring:SetPoint("LEFT", r, "LEFT", 8, 0)
    r.ring:Hide()
    r.number = Theme.NewText(r, { number = true, size = 10, justify = "CENTER", color = Theme.C.gold, oneLine = true, shadow = false })
    r.number:SetPoint("CENTER", r.ring, "CENTER", 0, 0)
    r.number:SetWidth(RING)
    pcall(r.number.SetJustifyV, r.number, "MIDDLE")

    -- kind icon
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ICON, ICON)
    r.icon:SetPoint("LEFT", r.ring, "RIGHT", 4, 0)

    -- texts
    r.title = Theme.NewText(r, { size = 12, oneLine = true })
    r.title:SetPoint("TOPLEFT", r, "TOPLEFT", LEFT + 8, -4)
    r.sub = Theme.NewText(r, { size = 10, color = Theme.C.textDim, oneLine = true })
    r.sub:SetPoint("TOPLEFT", r, "TOPLEFT", LEFT + 8, -19)
    r.dist = Theme.NewText(r, { size = 11, justify = "RIGHT", color = Theme.C.textDim, oneLine = true })
    r.dist:SetPoint("TOPRIGHT", r, "TOPRIGHT", -8, -5)
    r.dist:SetWidth(62)
    r.title:SetPoint("RIGHT", r.dist, "LEFT", -6, 0)
    r.sub:SetPoint("RIGHT", r, "RIGHT", -8, 0)

    -- separator under the row
    r.sep = r:CreateTexture(nil, "ARTWORK")
    r.sep:SetHeight(1)
    r.sep:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 10, -2)
    r.sep:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -10, -2)
    pcall(r.sep.SetTexture, r.sep, Theme.TEX.separator)
    r.sep:SetVertexColor(0.25, 0.25, 0.25, 1)

    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button)
        local e = self.entry
        if not e then return end
        local fn = button == "RightButton" and e.onRightClick or e.onClick
        if fn then
            local okc, err = pcall(fn, e)
            if not okc then ns.ReportOnce("row:click", err) end
        end
    end)
    r:SetScript("OnEnter", function(self)
        if self.entry and self.entry.tooltip then
            local tt = rawget(_G, "GameTooltip")
            if tt then
                tt:SetOwner(self, "ANCHOR_LEFT")
                tt:AddLine(self.entry.title or "", 1, 0.88, 0.55)
                for _, line in ipairs(self.entry.tooltip) do tt:AddLine(line, 0.85, 0.82, 0.75, true) end
                tt:Show()
            end
        end
        if self.state ~= "active" then self.bg:Show() pcall(self.bg.SetAlpha, self.bg, 0.35) end
    end)
    r:SetScript("OnLeave", function(self)
        local tt = rawget(_G, "GameTooltip")
        if tt then tt:Hide() end
        if self.state ~= "active" then self.bg:Hide() else pcall(self.bg.SetAlpha, self.bg, 1) end
    end)

    r.Set = Row.Set
    r.SetDistance = Row.SetDistance
    return r
end

--- entry: { number, icon, title, subtitle, state, distance (text or nil), onClick, onRightClick, tooltip }
function Row.Set(r, entry, showSubtitle)
    r.entry = entry
    r.state = entry.state or "available"
    local st = STATE[r.state] or STATE.available
    r.number:SetText(entry.number and tostring(entry.number) or "")
    Theme.Color(r.number, st.ring)
    pcall(r.ring.SetVertexColor, r.ring, st.ring[1], st.ring[2], st.ring[3], 1)
    Theme.SetIcon(r.icon, entry.state == "done" and "done" or (entry.state == "active" and "current" or (entry.icon or "accept")))
    pcall(r.icon.SetAlpha, r.icon, st.icon)
    r.title:SetText(entry.title or "")
    Theme.Color(r.title, st.title)
    local sub = showSubtitle and entry.subtitle or nil
    r.sub:SetText(sub or "")
    Theme.Color(r.sub, st.sub)
    if sub and sub ~= "" then r.sub:Show() r:SetHeight(Row.HEIGHT_TWO) else r.sub:Hide() r:SetHeight(Row.HEIGHT_ONE) end
    r.bar:SetHeight(r:GetHeight() - 6)
    Theme.Color(r.dist, st.dist)
    r:SetDistance(entry.distance)
    pcall(r.SetAlpha, r, st.alpha)
    local active = r.state == "active"
    r.bg:SetShown(active)
    pcall(r.bg.SetAlpha, r.bg, 1)
    if r.outline then r.outline:SetShown(active) end
    r.bar:SetShown(active)
    if entry.state == "done" then
        pcall(r.sep.SetAlpha, r.sep, 0.5)
    else
        pcall(r.sep.SetAlpha, r.sep, 1)
    end
end

function Row.SetDistance(r, text)
    r.dist:SetText(text or "")
end
