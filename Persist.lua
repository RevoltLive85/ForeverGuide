-- ============================================================
-- ForeverGuide / Persist.lua
-- Workaround for the WoW Forever beta bug where SavedVariables are written
-- at logout but never read back at login (every session started from
-- scratch and auto-picked a guide).
--
-- The essentials - active guide, step, progress, mode, settings, step
-- edits - are mirrored into addon-registered CVars, which the client does
-- persist (config-cache.wtf). At login, when the SavedVariables came back
-- empty, the mirror is restored. Once Blizzard fixes SavedVariables the
-- mirror is simply never needed (a loaded SV always wins).
--
-- Big data (recorder entries, reports) stays in SavedVariables: the files
-- ARE written, tools/merge_recorded.py and collect_reports.py read them
-- (and the .bak) from disk, so run them before two more reloads.
-- ============================================================

local _, ns = ...
local Persist = ns:NewModule("Persist")

local CHUNK = 200            -- characters per cvar (kept small to be safe)
local ACCT_CHUNKS = 6        -- settings + edits
local CHAR_CHUNKS = 6        -- per character
local ACCT_PREFIX = "ForeverGuideA"

local function CVar()
    local c = rawget(_G, "C_CVar")
    if c and c.RegisterCVar and c.SetCVar and c.GetCVar then return c end
    return nil
end

local function CharKey()
    local name = ns.PlainString(ns.Safe(rawget(_G, "UnitName"), "player")) or "char"
    local realm = ns.PlainString(ns.Safe(rawget(_G, "GetRealmName"))) or ""
    local key = (name .. realm):gsub("[^%w]", "")
    if key == "" then key = "char" end
    -- cvar names must stay short and plain
    if #key > 24 then key = key:sub(1, 24) end
    return "ForeverGuideC" .. key
end

local registered = {}
local function Register(prefix, n)
    local c = CVar()
    if not c or registered[prefix] then return end
    for i = 0, n - 1 do pcall(c.RegisterCVar, prefix .. i, "") end
    registered[prefix] = true
end

local function ReadChunks(prefix, n)
    local c = CVar()
    if not c then return nil end
    Register(prefix, n)
    local parts = {}
    for i = 0, n - 1 do
        local v = ns.PlainString(ns.Safe(c.GetCVar, prefix .. i))
        if not v or v == "" then break end
        parts[#parts + 1] = v
    end
    local s = table.concat(parts)
    return s ~= "" and s or nil
end

local warnedFull = {}
local function WriteChunks(prefix, n, str)
    local c = CVar()
    if not c then return false end
    Register(prefix, n)
    str = str or ""
    if #str > CHUNK * n then
        if not warnedFull[prefix] then
            warnedFull[prefix] = true
            ns.Warn(string.format("cvar mirror: %s state is %d characters, only %d fit - the tail (step edits) will not survive a beta login. Fold edits in with tools/apply_edits.py.", prefix == ACCT_PREFIX and "account" or "character", #str, CHUNK * n))
        end
        str = str:sub(1, CHUNK * n)
    end
    local ok = true
    for i = 0, n - 1 do
        local piece = str:sub(i * CHUNK + 1, (i + 1) * CHUNK)
        local okc, res = pcall(c.SetCVar, prefix .. i, piece)
        if not okc or res == false then ok = false end
    end
    -- SetCVar answers false (no error) for a cvar the client refused to register: read the first chunk back
    if ok then
        local okr, back = pcall(c.GetCVar, prefix .. "0")
        if not okr or ns.PlainString(back) ~= str:sub(1, CHUNK) then ok = false end
    end
    return ok
end

-- ---- encoding: k=v pairs joined by ';' (values never contain ';' or '=') ------
local function esc(s) return (tostring(s):gsub("[;=]", "_")) end   -- '|' is the edit-record separator, keep it
local function escField(s) return (tostring(s):gsub("[;=|:]", "_")) end

local function encodePairs(t, order)
    local out = {}
    for _, k in ipairs(order) do
        if t[k] ~= nil then out[#out + 1] = k .. "=" .. esc(t[k]) end
    end
    return table.concat(out, ";")
end

local function decodePairs(s)
    local t = {}
    for k, v in string.gmatch(s or "", "([^;=]+)=([^;]*)") do t[k] = v end
    return t
end

local function num(v) return tonumber(v) end
local function bool(v) if v == nil then return nil end return v == "1" or v == "true" end
local function b01(v) if v == nil then return nil end return v and "1" or "0" end

-- done indices -> "3-5,8,12"
local function encodeRanges(done)
    local idx = {}
    for i, v in pairs(done or {}) do if v and type(i) == "number" then idx[#idx + 1] = i end end
    table.sort(idx)
    local out, i = {}, 1
    while i <= #idx do
        local j = i
        while idx[j + 1] == idx[j] + 1 do j = j + 1 end
        out[#out + 1] = (j > i) and (idx[i] .. "-" .. idx[j]) or tostring(idx[i])
        i = j + 1
    end
    return table.concat(out, ",")
end

local function decodeRanges(s, into)
    for part in string.gmatch(s or "", "[^,]+") do
        local a, b = part:match("^(%d+)%-(%d+)$")
        if a then
            for i = tonumber(a), tonumber(b) do into[i] = true end
        elseif tonumber(part) then
            into[tonumber(part)] = true
        end
    end
    return into
end

-- ---- character state ------------------------------------------------------------
function Persist:EncodeChar()
    local ch = ns.char
    local t = { v = 1, g = ch.activeGuide, m = ch.mode, a = b01(ch.autoPickGuide ~= false), r = ch.route, tr = ch.lastTrained }
    local active = ch.activeGuide and ch.guides[ch.activeGuide]
    if active then
        t.s = active.step
        t.gv = active.version
        t.d = encodeRanges(active.done)
        local df = {}
        for quest, idx in pairs(active.deferred or {}) do df[#df + 1] = quest .. ":" .. idx end
        table.sort(df)
        if #df > 0 then t.df = table.concat(df, ",") end
    end
    -- other guides: step only
    local others = {}
    for id, p in pairs(ch.guides or {}) do
        if id ~= ch.activeGuide and type(p) == "table" and (p.step or 1) > 1 then others[#others + 1] = id .. ":" .. p.step end
    end
    table.sort(others)
    if #others > 0 then t.p = table.concat(others, ",") end
    return encodePairs(t, { "v", "g", "m", "a", "r", "tr", "s", "gv", "d", "df", "p" })
end

function Persist:DecodeChar(s)
    local t = decodePairs(s)
    if not t.v then return false end
    local ch = ns.char
    if t.g and t.g ~= "" then ch.activeGuide = t.g end
    if t.m and t.m ~= "" then ch.mode = t.m end
    if t.a then ch.autoPickGuide = bool(t.a) end
    if t.r and t.r ~= "" then ch.route = t.r end
    if num(t.tr) then ch.lastTrained = num(t.tr) end
    if ch.activeGuide and t.s then
        local p = ch.guides[ch.activeGuide] or { step = 1, done = {}, version = 1 }
        p.step = num(t.s) or 1
        p.version = num(t.gv) or p.version
        p.done = decodeRanges(t.d, {})
        p.deferred = {}
        if t.df and t.df ~= "" then
            for quest, idx in string.gmatch(t.df, "(%d+):(%d+)") do p.deferred[tonumber(quest)] = tonumber(idx) end
        end
        ch.guides[ch.activeGuide] = p
    end
    for id, step in string.gmatch(t.p or "", "([^,:]+):(%d+)") do
        ch.guides[id] = ch.guides[id] or { step = tonumber(step), done = {}, version = 1 }
    end
    return true
end

-- ---- account settings + edits ----------------------------------------------------
local ACCT_KEYS = { "v", "shown", "locked", "scale", "point", "x", "y", "hic", "fs", "ar", "ap", "ax", "ay", "as", "mm", "ma", "bliz", "rad", "acc", "ti", "ann", "rec", "ha", "op", "rows", "wp", "rt", "wa", "ws", "we", "sk", "so", "sp", "w", "h", "ht", "hm", "sc", "sd", "ss", "dg", "dc", "rmf", "rmt", "dn", "e" }

function Persist:EncodeAcct()
    local db = ns.db
    local ui, arrow, mm, nav, auto = db.ui, db.ui.arrow or {}, db.minimap or {}, db.nav, db.auto or {}
    local t = {
        v = 1,
        shown = b01(ui.shown ~= false), locked = b01(ui.locked), scale = ui.scale, point = ui.point, x = ui.x, y = ui.y,
        hic = b01(ui.hideInCombat), fs = ui.fontSize, ha = b01(ui.hiddenAll),
        op = ui.opacity, rows = ui.maxRows, w = ui.width, h = ui.height, ht = b01(ui.hideTracker ~= false), hm = b01(ui.hideOnMap ~= false),
        sc = b01(ui.showCompleted ~= false), sd = b01(ui.showDistances ~= false), ss = b01(ui.showSubtitles ~= false),
        wp = b01(nav.waypoint == nil or nav.waypoint.enabled ~= false), rt = b01(nav.waypoint == nil or nav.waypoint.route ~= false),
        wa = b01(nav.waypoint == nil or nav.waypoint.animate ~= false), ws = nav.waypoint and nav.waypoint.size,
        we = b01(nav.waypoint ~= nil and nav.waypoint.engine == true),
        sk = b01(nav.skull == nil or nav.skull.enabled ~= false), so = b01(nav.skull == nil or nav.skull.others ~= false),
        sp = b01(nav.skull == nil or nav.skull.plates ~= false),
        ar = b01(arrow.enabled ~= false), ap = arrow.point, ax = arrow.x, ay = arrow.y, as = arrow.scale,
        mm = b01(mm.shown ~= false), ma = mm.angle,
        bliz = b01(nav.blizzardWaypoint), rad = nav.arrivalRadius,
        acc = auto.accept, ti = b01(auto.turnin), ann = b01(auto.announce),
        rec = b01(db.recorder and db.recorder.enabled),
        dg = b01(db.ding == nil or db.ding.enabled ~= false), dc = db.ding and db.ding.channel,
        rmf = b01(db.reminders == nil or db.reminders.flight ~= false), rmt = b01(db.reminders == nil or db.reminders.trainer ~= false),
        dn = b01(db.instance == nil or db.instance.hide ~= false),
    }
    -- step edits: guide:step:map:x:y:npc:radius|...  (note text is not kept here)
    local edits = {}
    for gid, steps in pairs(db.edits or {}) do
        for idx, e in pairs(steps) do
            edits[#edits + 1] = table.concat({ escField(gid), idx, e.map or "", e.x or "", e.y or "", e.npc or "", e.radius or "", escField(e.type or ""), e.quest or "" }, ":")
        end
    end
    table.sort(edits)
    if #edits > 0 then t.e = table.concat(edits, "|") end
    return encodePairs(t, ACCT_KEYS)
end

function Persist:DecodeAcct(s)
    local t = decodePairs(s)
    if not t.v then return false end
    local db = ns.db
    db.ui.arrow = db.ui.arrow or {}
    db.minimap = db.minimap or {}
    db.auto = db.auto or {}
    local ui, arrow, mm, nav, auto = db.ui, db.ui.arrow, db.minimap, db.nav, db.auto
    if t.shown then ui.shown = bool(t.shown) end
    if t.locked then ui.locked = bool(t.locked) end
    if num(t.scale) then ui.scale = num(t.scale) end
    if t.point and t.point ~= "" then ui.point = t.point end
    if num(t.x) then ui.x = num(t.x) end
    if num(t.y) then ui.y = num(t.y) end
    if t.hic then ui.hideInCombat = bool(t.hic) end
    if t.ha then ui.hiddenAll = bool(t.ha) end
    if num(t.op) then ui.opacity = num(t.op) end
    if num(t.rows) then ui.maxRows = num(t.rows) end
    if num(t.w) then ui.width = num(t.w) end
    if num(t.h) then ui.height = num(t.h) end
    if t.ht then ui.hideTracker = bool(t.ht) end
    if t.hm then ui.hideOnMap = bool(t.hm) end
    if t.sc then ui.showCompleted = bool(t.sc) end
    if t.sd then ui.showDistances = bool(t.sd) end
    if t.ss then ui.showSubtitles = bool(t.ss) end
    nav.waypoint = nav.waypoint or { enabled = true, size = 1.0, animate = true, route = true }
    if t.wp then nav.waypoint.enabled = bool(t.wp) end
    if t.rt then nav.waypoint.route = bool(t.rt) end
    if t.wa then nav.waypoint.animate = bool(t.wa) end
    if num(t.ws) then nav.waypoint.size = num(t.ws) end
    if t.we then nav.waypoint.engine = bool(t.we) end
    nav.skull = nav.skull or { enabled = true, plates = true, others = true }
    if t.sk then nav.skull.enabled = bool(t.sk) end
    if t.so then nav.skull.others = bool(t.so) end
    if t.sp then nav.skull.plates = bool(t.sp) end
    if num(t.fs) then ui.fontSize = num(t.fs) end
    if t.ar then arrow.enabled = bool(t.ar) end
    if t.ap and t.ap ~= "" then arrow.point = t.ap end
    if num(t.ax) then arrow.x = num(t.ax) end
    if num(t.ay) then arrow.y = num(t.ay) end
    if num(t.as) then arrow.scale = num(t.as) end
    if t.mm then mm.shown = bool(t.mm) end
    if num(t.ma) then mm.angle = num(t.ma) end
    if t.bliz then nav.blizzardWaypoint = bool(t.bliz) end
    if num(t.rad) then nav.arrivalRadius = num(t.rad) end
    if t.acc and t.acc ~= "" then auto.accept = t.acc end
    if t.ti then auto.turnin = bool(t.ti) end
    if t.ann then auto.announce = bool(t.ann) end
    if t.rec and db.recorder then db.recorder.enabled = bool(t.rec) end
    if t.dn then
        db.instance = db.instance or {}
        db.instance.hide = bool(t.dn)
    end
    if t.rmf or t.rmt then
        db.reminders = db.reminders or {}
        if t.rmf then db.reminders.flight = bool(t.rmf) end
        if t.rmt then db.reminders.trainer = bool(t.rmt) end
    end
    if t.dg or (t.dc and t.dc ~= "") then
        db.ding = db.ding or {}
        if t.dg then db.ding.enabled = bool(t.dg) end
        if t.dc and t.dc ~= "" then db.ding.channel = t.dc end
    end
    if t.e and t.e ~= "" then
        db.edits = db.edits or {}
        for entry in string.gmatch(t.e, "[^|]+") do
            local f = {}
            for piece in string.gmatch(entry .. ":", "([^:]*):") do f[#f + 1] = piece end
            local gid, idx = f[1], tonumber(f[2])
            if gid and idx then
                db.edits[gid] = db.edits[gid] or {}
                local e = db.edits[gid][idx] or {}
                if tonumber(f[3]) and tonumber(f[4]) and tonumber(f[5]) then e.map, e.x, e.y = tonumber(f[3]), tonumber(f[4]), tonumber(f[5]) end
                if tonumber(f[6]) then e.npc = tonumber(f[6]) end
                if tonumber(f[7]) then e.radius = tonumber(f[7]) end
                if f[8] and f[8] ~= "" then e.type = f[8] end
                if tonumber(f[9]) then e.quest = tonumber(f[9]) end
                db.edits[gid][idx] = e
            end
        end
    end
    return true
end

-- ---- save / restore ----------------------------------------------------------------
Persist.available = false
Persist.restored = { acct = false, char = false }

function Persist:Save()
    if not self.available then return false end
    local okA = WriteChunks(ACCT_PREFIX, ACCT_CHUNKS, self:EncodeAcct())
    local okC = WriteChunks(CharKey(), CHAR_CHUNKS, self:EncodeChar())
    self.lastSave = ns.Now()
    self.lastSaveOK = okA and okC
    if not self.lastSaveOK and not self.warnedWrite then
        self.warnedWrite = true
        ns.Warn("cvar mirror: the client did not store the state (SetCVar refused) - progress will not survive a beta login.")
    end
    return self.lastSaveOK
end

function Persist:Restore()
    if not self.available then return end
    local D = ns.Database
    if D.freshAccount then
        local s = ReadChunks(ACCT_PREFIX, ACCT_CHUNKS)
        if s and self:DecodeAcct(s) then self.restored.acct = true end
    end
    if D.freshChar then
        local s = ReadChunks(CharKey(), CHAR_CHUNKS)
        if not s then
            -- the realm name may not have been readable when an earlier save built the key
            local name = ns.PlainString(ns.Safe(rawget(_G, "UnitName"), "player"))
            if name then s = ReadChunks("ForeverGuideC" .. (name:gsub("[^%w]", "")), CHAR_CHUNKS) end
        end
        if s and self:DecodeChar(s) then self.restored.char = true end
    end
end

function Persist:Status()
    if not self.available then return "cvar mirror unavailable on this client" end
    local D = ns.Database
    return string.format("SavedVariables %s at login; cvar mirror %s (last save %s)",
        (D.freshAccount or D.freshChar) and "were EMPTY (beta bug)" or "loaded",
        (self.restored.acct or self.restored.char) and "restored the state" or "on standby",
        self.lastSave and (math.floor(ns.Now() - self.lastSave) .. "s ago" .. (self.lastSaveOK == false and ", NOT STORED" or "")) or "never")
end

function Persist:OnInit()
    self.available = CVar() ~= nil
    self:Restore()
    local function save() ns.Events:Debounce("persist", 2, function() Persist:Save() end) end
    ns.Events:RegisterMany({ "FG_STEP_CHANGED", "FG_GUIDE_CHANGED", "FG_MODE_CHANGED", "FG_LOCK_CHANGED", "FG_STEP_UPDATED" }, save)
end

function Persist:OnEnable()
    local D = ns.Database
    if (D.freshAccount or D.freshChar) and (self.restored.acct or self.restored.char) then
        ns.Print("beta workaround: the client did not load SavedVariables - restored your guide, progress and settings from the cvar mirror.")
    end
    -- settings can change without an event (options panel, drag); mirror every 30 s and at logout
    local function tick()
        local ok, err = pcall(Persist.Save, Persist)
        if not ok then ns.ReportOnce("persist:tick", err) end
        C_Timer.After(30, tick)
    end
    C_Timer.After(30, tick)
    self:Save()
end

function Persist:OnLogout()
    self:Save()
end
