-- ============================================================
-- ForeverGuide / UI/QuestGuideConfig.lua
-- Settings of the Quest Guide window and the waypoint, with one Apply()
-- that pushes them to the live frames. Defaults live in Database.lua
-- (ns.db.ui / ns.db.nav.waypoint); this is the accessor + the option
-- items the Options panel and /fg commands share.
-- ============================================================

local _, ns = ...
local Config = {}
ns.QuestGuideConfig = Config

local function clamp(v, lo, hi) v = tonumber(v) if not v then return nil end if v < lo then return lo elseif v > hi then return hi end return v end

function Config.UI() return ns.db.ui end
function Config.Waypoint()
    ns.db.nav.waypoint = ns.db.nav.waypoint or { enabled = false, size = 1.0, animate = true, route = false }
    return ns.db.nav.waypoint
end

--- Push scale / opacity / width / rows to the window and the waypoint.
function Config.Apply()
    if ns.QuestGuide and ns.QuestGuide.Apply then ns.QuestGuide:Apply() end
    if ns.Waypoint and ns.Waypoint.Apply then ns.Waypoint:Apply() end
end

-- the settable numbers: key -> { get, set, min, max, label }
Config.NUMBERS = {
    scale   = { min = 0.5, max = 2.0, label = "window scale",  get = function() return ns.db.ui.scale or 1 end,      set = function(v) ns.db.ui.scale = v end },
    opacity = { min = 0.3, max = 1.0, label = "window opacity", get = function() return ns.db.ui.opacity or 0.92 end, set = function(v) ns.db.ui.opacity = v end },
    width   = { min = 240, max = 520, label = "window width",   get = function() return ns.db.ui.width or 300 end,    set = function(v) ns.db.ui.width = math.floor(v) end },
    rows    = { min = 3,   max = 15,  label = "rows shown",     get = function() return ns.db.ui.maxRows or 7 end,    set = function(v) ns.db.ui.maxRows = math.floor(v) end },
    wpsize  = { min = 0.5, max = 2.0, label = "waypoint size",  get = function() return Config.Waypoint().size or 1 end, set = function(v) Config.Waypoint().size = v end },
    arrowsize = { min = 0.5, max = 2.5, label = "arrow size", get = function() return ns.Arrow and ns.Arrow:GetScale() or (ns.db.ui.arrow and ns.db.ui.arrow.scale) or 1 end,
                  set = function(v) if ns.Arrow then ns.Arrow:SetScale(v) else ns.db.ui.arrow = ns.db.ui.arrow or {} ns.db.ui.arrow.scale = v end end },
}

function Config.SetNumber(key, value)
    local n = Config.NUMBERS[key]
    if not n then return false, "unknown setting " .. tostring(key) end
    local v = clamp(value, n.min, n.max)
    if not v then return false, string.format("%s: give a number between %s and %s", n.label, tostring(n.min), tostring(n.max)) end
    n.set(v)
    Config.Apply()
    return true, string.format("%s = %s", n.label, tostring(n.get()))
end

-- the toggles: key -> { get, set, label }
Config.TOGGLES = {
    questguide = { label = "Quest Guide window", get = function() return ns.db.ui.shown ~= false end,
                   set = function(v) if v then ns.UI:Show() else ns.UI:Hide() end end },
    waypoint   = { label = "in-world waypoint diamond (advanced - needs the engine pin below)", get = function() return Config.Waypoint().enabled ~= false end,
                   set = function(v) if ns.Waypoint then ns.Waypoint:SetEnabled(v) else Config.Waypoint().enabled = v end end },
    route      = { label = "dotted route line (only while the waypoint diamond shows)", get = function() return Config.Waypoint().route ~= false end,
                   set = function(v) Config.Waypoint().route = v Config.Apply() end },
    wpanim     = { label = "waypoint diamond animation", get = function() return Config.Waypoint().animate ~= false end,
                   set = function(v) Config.Waypoint().animate = v Config.Apply() end },
    skull      = { label = "skull over the nearest quest mob", get = function() return ns.MobMarker and ns.MobMarker.Cfg().enabled ~= false end,
                   set = function(v) if ns.MobMarker then ns.MobMarker:SetEnabled(v) end end },
    skullothers = { label = "small skulls over the other quest mobs around", get = function() return ns.MobMarker and ns.MobMarker.Cfg().others ~= false end,
                   set = function(v) if ns.MobMarker then ns.MobMarker.Cfg().others = v ns.MobMarker:Scan() end end },
    skullfriends = { label = "show other players' nameplates during kill steps (crowd detection)", get = function() return ns.MobMarker and ns.MobMarker.Cfg().friendplates ~= false end,
                   set = function(v) if ns.MobMarker then ns.MobMarker.Cfg().friendplates = v ns.MobMarker:Scan() end end },
    skullplates = { label = "switch enemy nameplates on during kill steps (needed for the skulls)", get = function() return ns.MobMarker and ns.MobMarker.Cfg().plates ~= false end,
                   set = function(v) if ns.MobMarker then ns.MobMarker.Cfg().plates = v ns.MobMarker:Scan() end end },
    wpengine   = { label = "ride the client's own pin instead of the plain arrow (off by default - most Forever clients cannot project it, and guessing felt sluggish)", get = function() return Config.Waypoint().engine == true end,
                   set = function(v) Config.Waypoint().engine = v if ns.Waypoint then ns.Waypoint:Tick() end end },
    map        = { label = "hide the Quest Guide while the world map is open", get = function() return ns.db.ui.hideOnMap ~= false end,
                   set = function(v) ns.db.ui.hideOnMap = v end },
    tracker    = { label = "hide Blizzard's objective tracker while the Quest Guide shows", get = function() return ns.db.ui.hideTracker ~= false end,
                   set = function(v) ns.db.ui.hideTracker = v if ns.QuestGuide and ns.QuestGuide.ApplyTracker then ns.QuestGuide:ApplyTracker() end end },
    completed  = { label = "show completed steps", get = function() return ns.db.ui.showCompleted ~= false end,
                   set = function(v) ns.db.ui.showCompleted = v ns.UI:Refresh() end },
    distances  = { label = "show distances", get = function() return ns.db.ui.showDistances ~= false end,
                   set = function(v) ns.db.ui.showDistances = v ns.UI:Refresh() end },
    subtitles  = { label = "show objective lines", get = function() return ns.db.ui.showSubtitles ~= false end,
                   set = function(v) ns.db.ui.showSubtitles = v ns.UI:Refresh() end },
    dungeon    = { label = "put the guide away while you are in a dungeon", get = function() return ns.Instance == nil or ns.Instance.Cfg().hide ~= false end,
                   set = function(v) if ns.Instance then ns.Instance:SetHide(v) end end },
    flightpoints = { label = "point out flight points you have not taken yet", get = function() return ns.Reminders == nil or ns.Reminders.Cfg().flight ~= false end,
                   set = function(v) if ns.Reminders then ns.Reminders.Cfg().flight = v end end },
    trainer    = { label = "remind me about the class trainer every couple of levels", get = function() return ns.Reminders == nil or ns.Reminders.Cfg().trainer ~= false end,
                   set = function(v) if ns.Reminders then ns.Reminders.Cfg().trainer = v end end },
    ding       = { label = "announce a level-up to your party (an emote when solo)", get = function() return ns.Ding == nil or ns.Ding.Cfg().enabled ~= false end,
                   set = function(v) if ns.Ding then ns.Ding.Cfg().enabled = v end end },
}

function Config.SetToggle(key, value)
    local t = Config.TOGGLES[key]
    if not t then return false, "unknown setting " .. tostring(key) end
    if value == nil then value = not t.get() end
    t.set(value and true or false)
    return true, string.format("%s %s", t.label, t.get() and "on" or "off")
end

--- Option-panel items (same shape Options.lua uses)
function Config.OptionItems()
    local items = { { header = "Quest Guide" } }
    for _, key in ipairs({ "questguide", "tracker", "map", "completed", "distances", "subtitles" }) do
        local t = Config.TOGGLES[key]
        items[#items + 1] = { key = "qg_" .. key, label = t.label:sub(1, 1):upper() .. t.label:sub(2), get = t.get, set = t.set }
    end
    items[#items + 1] = { header = "Waypoint" }
    for _, key in ipairs({ "waypoint", "route", "wpanim", "wpengine" }) do
        local t = Config.TOGGLES[key]
        items[#items + 1] = { key = "qg_" .. key, label = t.label:sub(1, 1):upper() .. t.label:sub(2), get = t.get, set = t.set }
    end
    items[#items + 1] = { header = "Levelling" }
    for _, key in ipairs({ "ding", "flightpoints", "trainer", "dungeon" }) do
        local t = Config.TOGGLES[key]
        items[#items + 1] = { key = "qg_" .. key, label = t.label:sub(1, 1):upper() .. t.label:sub(2), get = t.get, set = t.set }
    end
    items[#items + 1] = { header = "Quest mobs" }
    for _, key in ipairs({ "skull", "skullothers", "skullplates", "skullfriends" }) do
        local t = Config.TOGGLES[key]
        items[#items + 1] = { key = "qg_" .. key, label = t.label:sub(1, 1):upper() .. t.label:sub(2), get = t.get, set = t.set }
    end
    return items
end
