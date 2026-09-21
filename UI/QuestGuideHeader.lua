-- ============================================================
-- ForeverGuide / UI/QuestGuideHeader.lua
--   (compass)  QUEST GUIDE                       6 / 14
--   Elwynn Forest 1-11 (Human)  ·  Lv 7
--   ---------------- gold separator ----------------
-- ============================================================

local _, ns = ...
local Theme = ns.Theme
local Header = {}
ns.QuestGuideHeader = Header

Header.HEIGHT = 50

function Header.Create(parent)
    local h = CreateFrame("Frame", nil, parent)
    h:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    h:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    h:SetHeight(Header.HEIGHT)

    h.icon = h:CreateTexture(nil, "ARTWORK")
    h.icon:SetSize(24, 24)
    h.icon:SetPoint("TOPLEFT", h, "TOPLEFT", 11, -8)
    pcall(h.icon.SetTexture, h.icon, Theme.TEX.compass)

    h.title = Theme.NewText(h, { fancy = true, size = 16, color = Theme.C.goldLight, oneLine = true })
    h.title:SetPoint("LEFT", h.icon, "RIGHT", 7, 0)
    h.title:SetPoint("RIGHT", h, "RIGHT", -70, 0)
    pcall(h.title.SetJustifyV, h.title, "MIDDLE")
    h.title:SetText("QUEST GUIDE")

    h.count = Theme.NewText(h, { fancy = true, size = 14, color = Theme.C.gold, justify = "RIGHT", oneLine = true })
    h.count:SetPoint("TOPRIGHT", h, "TOPRIGHT", -12, -11)
    h.count:SetWidth(64)

    h.sub = Theme.NewText(h, { size = 10, color = Theme.C.textDim, oneLine = true })
    h.sub:SetPoint("TOPLEFT", h, "TOPLEFT", 14, -33)
    h.sub:SetPoint("TOPRIGHT", h, "TOPRIGHT", -12, -33)

    h.line = h:CreateTexture(nil, "ARTWORK")
    h.line:SetHeight(8)
    h.line:SetPoint("BOTTOMLEFT", h, "BOTTOMLEFT", 6, 0)
    h.line:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", -6, 0)
    pcall(h.line.SetTexture, h.line, Theme.TEX.headerLine)

    h.Set = Header.Set
    return h
end

--- title (nil keeps "QUEST GUIDE"), countText ("6 / 14"), subText
function Header.Set(h, countText, subText, title)
    h.title:SetText(title or "QUEST GUIDE")
    h.count:SetText(countText or "")
    h.sub:SetText(subText or "")
end
