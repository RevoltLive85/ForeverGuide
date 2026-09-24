-- ============================================================
-- ForeverGuide / Core.lua
-- Shared namespace, secret-value-safe helpers, module registry,
-- and the addon lifecycle (Boot is called from Init.lua).
--
-- Design rules for WoW Forever (1.60.x, Retail 12.x engine):
--  * Every value that comes from the game may be a "secret value"
--    (mostly in combat). Comparing / tonumber()-ing one throws.
--    All game reads go through Plain()/PlainNumber()/Safe().
--  * Never call protected functions. We only READ state and DRAW.
--  * No taint-sensitive templates, no secure frames.
--  * Port from Retail 12.1.5 code, not from Classic Era code:
--    GetQuestLogTitle / QuestPOIGetIconInfo etc. do not exist here.
-- ============================================================

local ADDON_NAME, ns = ...

ns.name    = ADDON_NAME
ns.version = "0.1.0"
do
    local addons = rawget(_G, "C_AddOns")
    if addons and type(addons.GetAddOnMetadata) == "function" then
        local ok, v = pcall(addons.GetAddOnMetadata, ADDON_NAME, "Version")
        if ok and type(v) == "string" and v ~= "" then ns.version = v end
    end
end

-- Expose for /dump ForeverGuide and for other addons (read-only use).
_G.ForeverGuide = ns

-- ------------------------------------------------------------
-- Secret-value helpers
-- ------------------------------------------------------------
local issecretvalue = rawget(_G, "issecretvalue")

local function IsSecret(value)
    if issecretvalue then
        return issecretvalue(value) == true
    end
    return false
end
ns.IsSecret = IsSecret

--- Returns nil for a secret value; callers must still check game results at runtime.
---@generic T
---@param value T
---@return T?
local function Plain(value)
    if value == nil or IsSecret(value) then return nil end
    return value
end
ns.Plain = Plain

--- value if it is a plain number, otherwise nil.
---@param value any
---@return number?
local function PlainNumber(value)
    value = Plain(value)
    if type(value) == "number" then return value end
    return nil
end
ns.PlainNumber = PlainNumber

--- value if it is a plain string, otherwise nil.
---@param value any
---@return string?
local function PlainString(value)
    value = Plain(value)
    if type(value) == "string" then return value end
    return nil
end
ns.PlainString = PlainString

--- value if it is a plain boolean, otherwise nil.
---@param value any
---@return boolean?
local function PlainBool(value)
    value = Plain(value)
    if type(value) == "boolean" then return value end
    return nil
end
ns.PlainBool = PlainBool

--- pcall a game function; returns its results, or nil on error/missing.
local function pack(...) return { n = select("#", ...), ... } end
local function Safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = pack(pcall(fn, ...))
    if not r[1] then return nil end
    return unpack(r, 2, r.n)     -- explicit count: results with nils in the middle survive
end
ns.Safe = Safe

--- Resolve "C_Namespace.Func" to a function, or nil if it does not exist.
---@param path string
---@return function?
local function API(path)
    local tbl = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(tbl) ~= "table" then return nil end
        tbl = rawget(tbl, part)
    end
    if type(tbl) == "function" then return tbl end
    return nil
end
ns.API = API

--- Call a namespaced API by string path, safely. ns.Call("C_Map.GetBestMapForUnit", "player")
--- Results may be secret; pass them through Plain* before use.
---@param path string
function ns.Call(path, ...)
    local fn = API(path)
    if not fn then return nil end
    return Safe(fn, ...)
end

-- ------------------------------------------------------------
-- Output
-- ------------------------------------------------------------
ns.COLOR      = "|cff4fd1c5"   -- teal
ns.COLOR_DIM  = "|cff9a9a9a"
ns.COLOR_OK   = "|cff55ff55"
ns.COLOR_WARN = "|cffffcc33"
ns.COLOR_ERR  = "|cffff5555"
ns.COLOR_END  = "|r"

function ns.Print(msg)
    print(ns.COLOR .. "ForeverGuide" .. ns.COLOR_END .. ": " .. tostring(msg))
end

function ns.Printf(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    ns.Print(ok and s or fmt)
end

function ns.Warn(msg)
    print(ns.COLOR .. "ForeverGuide" .. ns.COLOR_END .. ": " .. ns.COLOR_WARN .. tostring(msg) .. ns.COLOR_END)
end

function ns.Error(msg)
    print(ns.COLOR .. "ForeverGuide" .. ns.COLOR_END .. ": " .. ns.COLOR_ERR .. tostring(msg) .. ns.COLOR_END)
end

function ns.Debug(...)
    if ns.db and ns.db.debug then
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        print(ns.COLOR_DIM .. "[FG] " .. table.concat(parts, " ") .. ns.COLOR_END)
    end
end

-- Report an error once per key so a broken event handler never spams chat.
local reported = {}
function ns.ReportOnce(key, err)
    if reported[key] then return end
    reported[key] = true
    ns.Error("error in " .. tostring(key) .. ": " .. tostring(err))
end

-- ------------------------------------------------------------
-- Small utilities
-- ------------------------------------------------------------
function ns.CopyDefaults(src, dst)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = ns.CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

function ns.Trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function ns.Round(n, places)
    local mult = 10 ^ (places or 0)
    return math.floor(n * mult + 0.5) / mult
end

function ns.Contains(list, value)
    if type(list) ~= "table" then return false end
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

function ns.Now()
    return PlainNumber(Safe(GetTime)) or 0
end

-- ------------------------------------------------------------
-- Module registry + lifecycle
-- ------------------------------------------------------------
ns.modules = {}

--- Create a module table. Optional lifecycle hooks a module may define:
---   OnInit()                       after saved variables are ready
---   OnEnable()                     first PLAYER_ENTERING_WORLD
---   OnEnterWorld(isLogin, isReload) every PLAYER_ENTERING_WORLD
---   OnLogout()                     PLAYER_LOGOUT
function ns:NewModule(name)
    local m = { name = name }
    ns[name] = m
    ns.modules[#ns.modules + 1] = m
    return m
end

local function CallHook(hook, ...)
    for _, m in ipairs(ns.modules) do
        local fn = m[hook]
        if type(fn) == "function" then
            local ok, err = pcall(fn, m, ...)
            if not ok then ns.ReportOnce(m.name .. ":" .. hook, err) end
        end
    end
end
ns.CallHook = CallHook

ns.state = { initialised = false, enabled = false }

--- Called from Init.lua once every file (including guides) is loaded.
function ns.Boot()
    local frame = CreateFrame("Frame", "ForeverGuideBootFrame")
    frame:RegisterEvent("ADDON_LOADED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "ADDON_LOADED" then
            local name = ...
            if name ~= ADDON_NAME then return end
            frame:UnregisterEvent("ADDON_LOADED")
            local ok, err = pcall(function()
                ns.Database:Init()
                CallHook("OnInit")
            end)
            ns.state.initialised = ok
            if not ok then
                ns.Error("failed to initialise: " .. tostring(err))
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            if not ns.state.initialised then return end
            local isLogin, isReload = ...
            if not ns.state.enabled then
                ns.state.enabled = true
                CallHook("OnEnable")
                local build = PlainString(select(2, Safe(GetBuildInfo))) or "?"
                ns.Printf("v%s loaded (build %s). Type %s/fg%s for status, %s/fg help%s for commands.",
                    ns.version, build, ns.COLOR_OK, ns.COLOR_END, ns.COLOR_OK, ns.COLOR_END)
            end
            CallHook("OnEnterWorld", PlainBool(isLogin), PlainBool(isReload))
        elseif event == "PLAYER_LOGOUT" then
            CallHook("OnLogout")
        end
    end)
end
