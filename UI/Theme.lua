-- ============================================================
-- ForeverGuide / UI/Theme.lua
-- One place for the look: textures (Textures/*.tga, drawn by
-- tools/make_textures.py), colours, fonts, backdrops, buttons and the
-- shared pulse ticker. Dark parchment, thin gold, warm glows.
-- ============================================================

local _, ns = ...
local Theme = {}
ns.Theme = Theme

local PATH = "Interface\\AddOns\\ForeverGuide\\Textures\\"
Theme.PATH = PATH
Theme.TEX = {
    panel = PATH .. "panel_bg.tga",
    border = PATH .. "border_gold.tga",
    glow = PATH .. "glow_gold.tga",
    thin = PATH .. "border_thin.tga",
    rowActive = PATH .. "row_active.tga",
    rowBar = PATH .. "row_bar.tga",
    headerLine = PATH .. "header_line.tga",
    separator = PATH .. "separator.tga",
    button = PATH .. "button.tga",
    buttonHl = PATH .. "button_hl.tga",
    icons = PATH .. "icons.tga",
    ring = PATH .. "ring.tga",
    waypoint = PATH .. "waypoint.tga",
    dot = PATH .. "dot.tga",
    chevron = PATH .. "chevron.tga",
    white = "Interface\\Buttons\\WHITE8x8",
}

Theme.FONT = rawget(_G, "STANDARD_TEXT_FONT") or "Fonts\\FRIZQT__.TTF"
Theme.FANCY = "Fonts\\MORPHEUS.TTF"      -- the quest-title font that ships with the game
Theme.NUMBER = "Fonts\\ARIALN.TTF"

Theme.C = {
    gold      = { 0.87, 0.70, 0.29 },
    goldLight = { 1.00, 0.88, 0.55 },
    goldDim   = { 0.58, 0.45, 0.18 },
    text      = { 0.93, 0.89, 0.80 },
    textDim   = { 0.66, 0.61, 0.52 },
    muted     = { 0.46, 0.43, 0.37 },
    done      = { 0.50, 0.47, 0.41 },
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

--- Backdrops. kind: "panel" (parchment + ornate gold), "glow" (soft outer glow only), "thin" (1px gold)
function Theme.Backdrop(f, kind, alpha)
    if not f.SetBackdrop then
        if kind == "panel" then
            local bg = f:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.06, 0.045, 0.03, alpha or 0.92)
        end
        return
    end
    if kind == "panel" then
        f:SetBackdrop({ bgFile = Theme.TEX.panel, edgeFile = Theme.TEX.border, edgeSize = 16, tile = true, tileSize = 256,
                        insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        f:SetBackdropColor(1, 1, 1, alpha or 0.92)
        f:SetBackdropBorderColor(1, 1, 1, 1)
    elseif kind == "glow" then
        f:SetBackdrop({ edgeFile = Theme.TEX.glow, edgeSize = 32 })
        f:SetBackdropBorderColor(1, 1, 1, alpha or 0.9)
    elseif kind == "thin" then
        f:SetBackdrop({ edgeFile = Theme.TEX.thin, edgeSize = 8 })
        f:SetBackdropBorderColor(1, 1, 1, alpha or 0.9)
    elseif kind == "plain" then
        f:SetBackdrop({ bgFile = Theme.TEX.white, edgeFile = Theme.TEX.white, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        f:SetBackdropColor(0.06, 0.045, 0.03, alpha or 0.92)
        f:SetBackdropBorderColor(0.58, 0.45, 0.18, 0.9)
    end
end

--- Compact textured button: dark plate, gold rim, brighter on hover. icon: atlas name (optional)
function Theme.NewButton(parent, text, width, height, onClick, icon, opts)
    opts = opts or {}
    local b = CreateFrame("Button", opts.name, parent, opts.template)
    b:SetSize(width, height or 24)
    local normal = b:CreateTexture(nil, "BACKGROUND")
    normal:SetAllPoints()
    pcall(normal.SetTexture, normal, Theme.TEX.button)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    pcall(hl.SetTexture, hl, Theme.TEX.buttonHl)
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

-- ---- pulse ticker: one OnUpdate for every breathing region ----------------------------------
local pulses, ticker = {}, nil
local function tick(self, elapsed)
    self.elapsed = (self.elapsed or 0) + (elapsed or 0)
    if self.elapsed < 0.05 then return end
    local dt = self.elapsed
    self.elapsed = 0
    local now = ns.Now and ns.Now() or 0
    for region, p in pairs(pulses) do
        if p.enabled and region:IsShown() then
            local phase = (now % p.period) / p.period
            local v = 0.5 + 0.5 * math.sin(phase * 2 * math.pi)
            local a = p.min + (p.max - p.min) * v
            pcall(region.SetAlpha, region, a)
            if p.scale and region.SetScale then pcall(region.SetScale, region, 1 + (p.scale - 1) * v) end
        end
    end
end
--- Make a region breathe between min and max alpha (and optionally scale) with the given period.
function Theme.Pulse(region, period, minA, maxA, scale)
    if not ticker then
        ticker = CreateFrame("Frame")
        ticker:SetScript("OnUpdate", tick)
    end
    pulses[region] = { period = period or 2.0, min = minA or 0.6, max = maxA or 1.0, scale = scale, enabled = true }
end
function Theme.SetPulseEnabled(region, on)
    local p = pulses[region]
    if p then
        p.enabled = on and true or false
        if not on then pcall(region.SetAlpha, region, p.max) if p.scale then pcall(region.SetScale, region, 1) end end
    end
end
function Theme.Unpulse(region) pulses[region] = nil end
