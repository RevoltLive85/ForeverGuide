-- Feedback entry and copyable report export. Reports themselves live in ForeverGuideDB.
local _, ns = ...
local Reports = {}
ns.Reports = Reports
local Theme = ns.Theme

local function Window(name, width, height, title)
    local ok, f = pcall(CreateFrame, "Frame", name, UIParent, "BackdropTemplate")
    if not ok or not f then f = CreateFrame("Frame", name, UIParent) end
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    Theme.Backdrop(f, "panel", 0.75)
    local heading = Theme.NewText(f, { size = 15, oneLine = true })
    heading:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -14)
    heading:SetText(title)
    local close = Theme.NewButton(f, "x", 26, 22, function() f:Hide() end)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    f:Hide()
    return f
end

local prompt, list
function Reports:Prompt()
    if not prompt then
        local f = Window("ForeverGuideReportPrompt", 420, 170, "Report a wrong step")
        local hint = Theme.NewText(f, { size = 11, color = Theme.C.textDim, maxLines = 2 })
        hint:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -42)
        hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -42)
        hint:SetText("What is wrong? Stand at the correct location or target the correct NPC first.")
        local input = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        input:SetSize(376, 26)
        input:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -90)
        input:SetAutoFocus(false)
        input:SetMaxLetters(500)
        input:SetScript("OnEscapePressed", function(self) self:ClearFocus() f:Hide() end)
        f.input = input
        local save = Theme.NewButton(f, "Save report", 110, 24, function()
            local text = ns.Trim(input:GetText() or "")
            if text == "" then ns.Warn("describe what is wrong before saving.") return end
            ns.Commands:Run("wrong " .. text)
            input:ClearFocus()
            f:Hide()
        end)
        save:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 12)
        f.save = save
        input:SetScript("OnEnterPressed", function() save:GetScript("OnClick")() end)
        prompt = f
    end
    prompt.input:SetText("")
    prompt:Show()
    prompt.input:SetFocus()
end

local function Export(reports)
    local lines = {}
    for i, r in ipairs(reports) do
        local where = r.loc and string.format("map %s %.1f,%.1f%s", tostring(r.loc.m or "?"), r.loc.x or 0, r.loc.y or 0,
            r.loc.id and (" " .. (r.loc.kind or "target") .. " " .. tostring(r.loc.id)) or "") or "?"
        local actual = string.format("map %s %.1f,%.1f (%s%s)", tostring(r.m or "?"), r.x or 0, r.y or 0,
            r.zone or "?", r.sub and r.sub ~= "" and " / " .. r.sub or "")
        lines[#lines + 1] = string.format("%d. time %s | %s%s | quest %s | %s | expected %s | actual %s | level %s%s | %s",
            i, tostring(r.t or "?"), r.guide and (r.guide .. " step " .. tostring(r.step or "?")) or (r.mode or "unknown mode"),
            r.type and (" " .. r.type) or (r.what and " " .. r.what or ""), tostring(r.q or "?"),
            r.text or "(no description)", where, actual, tostring(r.lvl or "?"),
            r.npc and (" | target NPC " .. tostring(r.npc) .. " " .. (r.npcName or "")) or "",
            r.npcStep and ("expected NPC " .. tostring(r.npcStep)) or "")
    end
    return table.concat(lines, "\n")
end
Reports.Export = Export

function Reports:ShowList()
    if not list then
        local f = Window("ForeverGuideReports", 660, 400, "Reports (select text and copy)")
        local scroll = CreateFrame("ScrollFrame", nil, f)
        scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -44)
        scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
        pcall(scroll.SetClipsChildren, scroll, true)
        scroll:EnableMouseWheel(true)
        local text = CreateFrame("EditBox", nil, scroll)
        text:SetMultiLine(true)
        text:SetAutoFocus(false)
        text:SetFont(Theme.FONT, 12, "")
        text:SetTextColor(1, 1, 1)
        text:SetWidth(620)
        text:SetScript("OnEscapePressed", function() f:Hide() end)
        text:SetScript("OnTextChanged", function(self)
            local ok, height = pcall(self.GetStringHeight, self)
            self:SetHeight(math.max(330, (ok and height or 0) + 20))
        end)
        text:SetHeight(330)
        scroll:SetScrollChild(text)
        local selectAll = Theme.NewButton(f, "Select all", 86, 22, function() text:SetFocus() text:HighlightText() end)
        selectAll:SetPoint("TOPRIGHT", f, "TOPRIGHT", -42, -8)
        local clear = Theme.NewButton(f, "Clear all", 92, 22, function()
            if not f.confirmClear then
                f.confirmClear = true
                f.clear.label:SetText("Confirm clear")
                return
            end
            ns.Commands:Run("reports clear")
            f.confirmClear = false
            f.clear.label:SetText("Clear all")
            Reports:ShowList()
        end)
        clear:SetPoint("RIGHT", selectAll, "LEFT", -8, 0)
        f.clear = clear
        f:SetScript("OnHide", function() f.confirmClear = false clear.label:SetText("Clear all") end)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            self:SetVerticalScroll(math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 60)))
        end)
        f.text, f.scroll = text, scroll
        list = f
    end
    local reports = ns.db.reports or {}
    list.text:SetText(#reports > 0 and Export(reports) or "No reports yet. Use /fg wrong to add one.")
    list.scroll:SetVerticalScroll(0)
    list:Show()
end
