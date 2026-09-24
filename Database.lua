-- ============================================================
-- ForeverGuide / Database.lua
-- Saved variables.
--   ForeverGuideDB      account-wide: settings, UI position, recorder data
--   ForeverGuideCharDB  per character: active guide + progress per guide
--
-- Beta note (1.60.1): SavedVariables are written on logout; public
-- reports say they are sometimes not read back on login. Everything
-- here therefore works from defaults when the DB comes back empty.
-- ============================================================

local _, ns = ...
local Database = ns:NewModule("Database")

local DB_VERSION = 1

local DEFAULTS = {
    version = DB_VERSION,
    debug = false,
    ui = {
        shown = true,
        locked = false,
        scale = 1.0,
        width = 280,
        point = "TOPRIGHT",
        x = -40,
        y = -200,
        fontSize = 12,
        showPrevious = 2,     -- completed steps shown above the current one
        showUpcoming = 4,     -- upcoming steps shown below the current one
        -- Quest Guide window (UI/QuestGuide*.lua)
        opacity = 0.75,
        maxRows = 7,          -- rows in the list (the current one is always among them)
        showCompleted = true,
        showDistances = true,
        showSubtitles = true,
        hideTracker = true,   -- Blizzard's objective tracker is hidden while the Quest Guide shows
        hideOnMap = true,     -- the window steps aside while the world map is open
    },
    nav = {
        blizzardWaypoint = false, -- use the addon arrow without placing a map pin
        arrivalRadius = 15,       -- yards: TRAVEL steps complete within this distance
        updateInterval = 0.1,     -- seconds between distance/arrow updates
        waypoint = {              -- optional in-world diamond (UI/QuestWaypoint.lua)
            enabled = false,
            size = 1.0,
            animate = true,
            route = false,        -- no dotted path by default
            -- engine = false: only use the client's own pin when explicitly enabled.
            -- The plain chevron (Arrow.lua) is the default indicator.
        },
        skull = {                 -- skulls over quest mobs (UI/MobMarker.lua)
            enabled = true,
            others = true,        -- small skulls over the other quest mobs around
            plates = true,        -- switch enemy nameplates on during kill steps
        },
    },
    instance = {                  -- step aside inside dungeons (Instance.lua)
        hide = true,
    },
    ding = {                      -- level-up announcement (Ding.lua)
        enabled = false,
        channel = "auto",         -- auto = party/raid when grouped, emote when solo
    },
    recorder = {
        enabled = true,           -- Phase 10: quietly record quest/NPC/coordinate data
        maxEntries = 4000,
        entries = {},
        maps = {},                -- [uiMapID] = { name = ..., zone = ... } seen during play
    },
}

local CHAR_DEFAULTS = {
    version = DB_VERSION,
    activeGuide = nil,            -- guide id
    autoPickGuide = true,
    guides = {},                  -- [guideID] = { step = n, done = { [idx] = true }, version = n }
}

function Database:Init()
    -- the Forever beta writes SavedVariables but does not read them back (Persist.lua mirrors the essentials)
    Database.freshAccount = (ForeverGuideDB == nil)
    Database.freshChar = (ForeverGuideCharDB == nil)
    ForeverGuideDB = ns.CopyDefaults(DEFAULTS, ForeverGuideDB)
    ForeverGuideCharDB = ns.CopyDefaults(CHAR_DEFAULTS, ForeverGuideCharDB)
    ns.db = ForeverGuideDB
    ns.char = ForeverGuideCharDB

    -- migrations go here when DB_VERSION changes
    ns.db.version = DB_VERSION
    ns.char.version = DB_VERSION
end

--- Progress table for a guide (created on first use).
function Database:GuideProgress(guideID, guideVersion)
    local p = ns.char.guides[guideID]
    if not p then
        p = { step = 1, done = {}, version = guideVersion or 1 }
        ns.char.guides[guideID] = p
    elseif guideVersion and p.version ~= guideVersion then
        -- step indices may have shifted between guide versions: keep the
        -- step number (best effort) but drop manual completions.
        p.done = {}
        p.version = guideVersion
    end
    if type(p.done) ~= "table" then p.done = {} end
    if type(p.step) ~= "number" or p.step < 1 then p.step = 1 end
    return p
end

function Database:ResetGuide(guideID)
    ns.char.guides[guideID] = nil
end

function Database:ResetAll()
    for k in pairs(ns.db) do ns.db[k] = nil end
    ns.CopyDefaults(DEFAULTS, ns.db)
    for k in pairs(ns.char) do ns.char[k] = nil end
    ns.CopyDefaults(CHAR_DEFAULTS, ns.char)
end

Database.DEFAULTS = DEFAULTS
Database.CHAR_DEFAULTS = CHAR_DEFAULTS
