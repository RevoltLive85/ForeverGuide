-- ============================================================
-- ForeverGuide / UI/Theme.lua
-- Shared fonts, colours and plain UI surfaces.
-- ============================================================

local _, ns = ...
local Theme = {}
ns.Theme = Theme

local PATH = "Interface\\AddOns\\ForeverGuide\\Textures\\"
Theme.PATH = PATH
Theme.TEX = {
    rowActive = "Interface\\Buttons\\WHITE8x8",
    rowBar = "Interface\\Buttons\\WHITE8x8",
    headerLine = "Interface\\Buttons\\WHITE8x8",
    separator = "Interface\\Buttons\\WHITE8x8",
    button = "Interface\\Buttons\\WHITE8x8",
    buttonHl = "Interface\\Buttons\\WHITE8x8",
    icons = PATH .. "icons.tga",
    ring = PATH .. "ring.tga",
    waypoint = PATH .. "waypoint.tga",
    dot = PATH .. "dot.tga",
    chevron = PATH .. "chevron.tga",
    skullBtn = PATH .. "skull_btn.tga",
    white = "Interface\\Buttons\\WHITE8x8",
}

Theme.FONT = rawget(_G, "STANDARD_TEXT_FONT") or "Fonts\\FRIZQT__.TTF"
Theme.FANCY = Theme.FONT
Theme.NUMBER = "Fonts\\ARIALN.TTF"

Theme.C = {
    gold      = { 0.75, 0.80, 0.87 },
    goldLight = { 1.00, 1.00, 1.00 },
    goldDim   = { 0.45, 0.49, 0.55 },
    text      = { 0.92, 0.92, 0.92 },
    textDim   = { 0.68, 0.68, 0.68 },
    muted     = { 0.48, 0.48, 0.48 },
    done      = { 0.52, 0.52, 0.52 },
    warn      = { 1.00, 0.50, 0.30 },
    blocked   = { 0.85, 0.35, 0.25 },
    green     = { 0.55, 0.85, 0.45 },
}

-- icons.tga atlas: 8 tiles of 32px
Theme.ICON = { compass = 1, accept = 2, turnin = 3, kill = 4, collect = 5, travel = 6, done = 7, current = 8 }

function Theme.SetIcon(tex, name)
    local i = Theme.ICON[name] or Theme.ICON.accept
    pcall(tex.SetTexture, tex, Theme.TEX.icons)
    pcall(tex.SetTexCoord, tex, (i - 1) / 8, i / 8, 0, 1)
end

local function color(fs, c) if c then fs:SetTextColor(c[1], c[2], c[3]) end end
Theme.Color = color

--- A font string with a real font object behind it (Forever needs one) and our font on top.
--- opts: fancy (Morpheus), size, justify, color, oneLine, outline, number
function Theme.NewText(parent, opts)
    opts = opts or {}
    local fs = parent:CreateFontString(nil, "OVERLAY", opts.template or "GameFontNormal")
    local face = opts.fancy and Theme.FANCY or (opts.number and Theme.NUMBER or Theme.FONT)
    local ok = pcall(fs.SetFont, fs, face, opts.size or 12, opts.outline or "")
    if not ok or (fs.GetFont and not fs:GetFont()) then pcall(fs.SetFont, fs, Theme.FONT, opts.size or 12, opts.outline or "") end
    fs:SetJustifyH(opts.justify or "LEFT")
    fs:SetJustifyV(opts.justifyV or "TOP")
    fs:SetWordWrap(not opts.oneLine)
    fs:SetNonSpaceWrap(false)
    if opts.oneLine then
        local okm = pcall(fs.SetMaxLines, fs, 1)
        if not okm then fs:SetWordWrap(false) end
    elseif opts.maxLines then
        pcall(fs.SetMaxLines, fs, opts.maxLines)
    end
    color(fs, opts.color or Theme.C.text)
    if opts.shadow ~= false and fs.SetShadowOffset then
        pcall(fs.SetShadowOffset, fs, 1, -1)
        pcall(fs.SetShadowColor, fs, 0, 0, 0, 0.8)
    end
    return fs
end

--- A solid panel, with an optional subtle outline. No decorative textures.
function Theme.Backdrop(f, kind, alpha)
    if kind == "glow" then return end
    if not f.SetBackdrop then
        if kind == "panel" or kind == "plain" then
            local bg = f:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0, 0, 0, alpha or 0.75)
        end
        return
    end
    f:SetBackdrop({ bgFile = Theme.TEX.white, edgeFile = Theme.TEX.white, edgeSize = 1 })
    f:SetBackdropColor(0, 0, 0, kind == "thin" and 0 or (alpha or 0.75))
    f:SetBackdropBorderColor(0.3, 0.3, 0.3, kind == "thin" and 0.7 or 0.9)
end

--- Compact textured button: dark plate, gold rim, brighter on hover. icon: atlas name (optional)
function Theme.NewButton(parent, text, width, height, onClick, icon, opts)
    opts = opts or {}
    local b = CreateFrame("Button", opts.name, parent, opts.template)
    b:SetSize(width, height or 24)
    local normal = b:CreateTexture(nil, "BACKGROUND")
    normal:SetAllPoints()
    pcall(normal.SetTexture, normal, Theme.TEX.button)
    normal:SetVertexColor(0.18, 0.18, 0.18, 1)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    pcall(hl.SetTexture, hl, Theme.TEX.buttonHl)
    hl:SetVertexColor(0.35, 0.35, 0.35, 1)
    pcall(hl.SetBlendMode, hl, "ADD")
    pcall(hl.SetAlpha, hl, 0.35)
    local label = Theme.NewText(b, { size = 12, justify = "CENTER", color = Theme.C.gold, oneLine = true, shadow = true })
    label:ClearAllPoints()
    if icon then
        local ic = b:CreateTexture(nil, "ARTWORK")
        ic:SetSize(14, 14)
        Theme.SetIcon(ic, icon)
        ic:SetPoint("LEFT", b, "LEFT", 10, 0)
        label:SetPoint("LEFT", ic, "RIGHT", 4, 0)
        label:SetPoint("RIGHT", b, "RIGHT", -8, 0)
        b.icon = ic
    else
        label:SetPoint("LEFT", b, "LEFT", 8, 0)
        label:SetPoint("RIGHT", b, "RIGHT", -8, 0)
    end
    pcall(label.SetJustifyV, label, "MIDDLE")
    label:SetText(text)
    b.label = label
    if onClick then
        b:SetScript("OnClick", function()
            local ok, err = pcall(onClick)
            if not ok then ns.ReportOnce("button:" .. tostring(text), err) end
        end)
    end
    b:SetScript("OnEnter", function() color(label, Theme.C.goldLight) end)
    b:SetScript("OnLeave", function() color(label, Theme.C.gold) end)
    return b
end

function Theme.Pulse() end
function Theme.SetPulseEnabled() end
function Theme.Unpulse() end
