-- ============================================================
-- ForeverGuide / Scanner.lua  (v3: rate based, canary throttled)
-- Quest ID scanner: asks the server for every quest ID in a range and
-- records which ones exist (and their titles). Questie's Classic DB has
-- the vanilla quests; diffing against this scan reveals Forever's new
-- quests and the vanilla ones that were removed.
--
--   /fg scan                 scan the default ranges (1-12000 and 80000-120000)
--   /fg scan 1 20000         custom range
--   /fg scan resume          continue a paused scan
--   /fg scan stop | status
--
-- What we learned on 1.60.1:
--   * C_QuestLog.RequestLoadQuestByID(id) -> QUEST_DATA_LOAD_RESULT(id, true)
--     for real quests; for ids that do not exist the server stays SILENT
--     (no success=false answer). Silence therefore means "no such quest"...
--   * ...except when the server throttles us: then real quests go silent
--     too. A burst of 1000 requests/s answered ~1300 and then nothing.
--   * Quest data the client has cached (HaveQuestData) never produces an
--     event, so cached ids are read directly.
-- So: send at a steady rate; silence on an unknown id = does not exist;
-- known vanilla quests (Data/VanillaQuestIDs.lua) are canaries: when
-- canaries go silent we are throttled -> halve the rate and re-ask the ids
-- that went silent meanwhile. Clean canary answers grow the rate again.
--
-- Results: ForeverGuideDB.scan = {
--   quests = { [id] = title },     exists (event or cache)
--   missing = { [id] = true },     silent while not throttled -> assumed not to exist
--   unanswered = { [id] = true },  canaries that never answered (re-asked by /fg scan resume)
--   ranges, cursor = { rangeIndex, nextID }, done, build
-- }
-- ============================================================

local _, ns = ...
local Scanner = ns:NewModule("Scanner")

local PlainNumber, PlainString, PlainBool = ns.PlainNumber, ns.PlainString, ns.PlainBool

local DEFAULT_RANGES = { { 1, 12000 }, { 80000, 120000 } }
local RATE_START, RATE_MIN, RATE_MAX = 8, 1, 40     -- requests per second
local TICK = 0.25
local TIMEOUT = 5.0            -- seconds of silence before an id is judged
local CANARY_EVERY = 60        -- inject one reserved canary per this many sends outside vanilla ranges
local CANARY_RESERVE_EVERY = 12 -- reserve every Nth uncached vanilla id as a canary
local CANARY_HISTORY = 6       -- throttle = the last 6 canaries ALL silent (removed vanilla quests are silent too)
local CANARY_RETRIES = 2
local GROW_AFTER = 8           -- clean canary answers before the rate grows
local SILENT_REPLAY = 20       -- seconds: silent ids from this window are re-asked after a throttle
local THROTTLE_PAUSE = 10      -- seconds to stop sending after a throttle is detected
local MAX_PASSES = 3           -- automatic re-ask passes for ids left unanswered by throttling

Scanner.running = false
Scanner.rate = RATE_START
Scanner.budget = 0
Scanner.lastTick = 0
Scanner.inflight = {}          -- id -> { sentAt, tries, canary }
Scanner.inflightCount = 0
Scanner.retryQueue = {}        -- { id, tries, canary }
Scanner.canaryPool = {}        -- reserved vanilla ids, popped one at a time
Scanner.reserved = {}          -- id -> true while in the pool
Scanner.canaryHistory = {}     -- recent canary outcomes: true = answered, false = silent
Scanner.cleanCanaries = 0
Scanner.sinceCanary = 0
Scanner.recentSilent = {}      -- { id, at } judged silent recently
Scanner.lastThrottleAt = -1000
Scanner.stats = {}
Scanner.startedAt = 0

local vanilla = {}
local function BuildVanilla()
    if next(vanilla) then return end
    for _, id in ipairs(ns.VanillaQuestIDs or {}) do vanilla[id] = true end
end

local function Store()
    local s = ns.db.scan
    if type(s) ~= "table" then
        s = {}
        ns.db.scan = s
    end
    s.quests = type(s.quests) == "table" and s.quests or {}
    s.missing = type(s.missing) == "table" and s.missing or {}
    s.unanswered = type(s.unanswered) == "table" and s.unanswered or {}
    return s
end

local function Known(s, id)
    return s.quests[id] ~= nil or s.missing[id]
end

-- quest data the client already holds never produces an event
local function CachedTitle(id)
    local have = ns.Safe(rawget(_G, "HaveQuestData"), id)
    if have == false then return nil end
    local title = PlainString(ns.Call("C_QuestLog.GetTitleForQuestID", id))
    if title and title ~= "" then return title end
    if have == true then return "" end
    return nil
end

local function Record(s, id, title)
    s.quests[id] = title
    s.missing[id] = nil
    s.unanswered[id] = nil
end

-- next id from the cursor that still needs asking, or nil when exhausted
local function NextID(s)
    local cur = s.cursor
    while cur and s.ranges[cur[1]] do
        local range = s.ranges[cur[1]]
        if cur[2] > range[2] then
            local nextRange = s.ranges[cur[1] + 1]
            cur[1], cur[2] = cur[1] + 1, nextRange and nextRange[1] or (range[2] + 1)
        else
            local id = cur[2]
            cur[2] = id + 1
            if not Known(s, id) and not Scanner.reserved[id] then return id end
        end
    end
    return nil
end

local function NewStats()
    return { sent = 0, found = 0, cached = 0, silent = 0, canaryOK = 0, canarySilent = 0, throttles = 0, replayed = 0 }
end

-- ------------------------------------------------------------
-- Sending / judging
-- ------------------------------------------------------------
local function Send(id, tries, canary)
    local s = Store()
    local cached = CachedTitle(id)
    if cached then
        Record(s, id, cached)
        Scanner.stats.found = Scanner.stats.found + 1
        Scanner.stats.cached = Scanner.stats.cached + 1
        return
    end
    Scanner.inflight[id] = { sentAt = ns.Now(), tries = tries or 1, canary = canary or vanilla[id] == true }
    Scanner.inflightCount = Scanner.inflightCount + 1
    Scanner.stats.sent = Scanner.stats.sent + 1
    if Scanner.inflight[id].canary then Scanner.sinceCanary = 0 else Scanner.sinceCanary = Scanner.sinceCanary + 1 end
    ns.Call("C_QuestLog.RequestLoadQuestByID", id)
end

local function Remove(id)
    local info = Scanner.inflight[id]
    if info then
        Scanner.inflight[id] = nil
        Scanner.inflightCount = Scanner.inflightCount - 1
    end
    return info
end

local function CanaryOutcome(answered)
    local h = Scanner.canaryHistory
    h[#h + 1] = answered
    while #h > CANARY_HISTORY do table.remove(h, 1) end
    if answered then
        Scanner.stats.canaryOK = Scanner.stats.canaryOK + 1
        Scanner.cleanCanaries = Scanner.cleanCanaries + 1
        if Scanner.cleanCanaries >= GROW_AFTER then
            Scanner.cleanCanaries = 0
            Scanner.rate = math.min(RATE_MAX, Scanner.rate * 1.25)
        end
        return
    end
    Scanner.stats.canarySilent = Scanner.stats.canarySilent + 1
    Scanner.cleanCanaries = 0
    local silent = 0
    for _, ok in ipairs(h) do if not ok then silent = silent + 1 end end
    if #h >= CANARY_HISTORY and silent == #h then
        Scanner:Throttled()
    end
end

function Scanner:Throttled()
    local now = ns.Now()
    local s = Store()
    self.stats.throttles = self.stats.throttles + 1
    self.rate = math.max(RATE_MIN, self.rate / 2)
    self.lastThrottleAt = now
    self.pausedUntil = now + THROTTLE_PAUSE
    self.canaryHistory = {}
    -- ids judged silent while we were (probably already) throttled get another chance
    local replay = 0
    for i = #self.recentSilent, 1, -1 do
        local r = self.recentSilent[i]
        if now - r.at <= SILENT_REPLAY then
            if s.missing[r.id] then
                s.missing[r.id] = nil
                self.retryQueue[#self.retryQueue + 1] = { id = r.id, tries = 2 }
                replay = replay + 1
            end
        end
        table.remove(self.recentSilent, i)
    end
    self.stats.replayed = self.stats.replayed + replay
    ns.Printf("scan: server throttling detected - rate down to %.1f/s, re-asking %d ids.", self.rate, replay)
end

local function Judge(id, info, now)
    local s = Store()
    local late = CachedTitle(id)
    if late then
        Record(s, id, late)
        Scanner.stats.found = Scanner.stats.found + 1
        if info.canary then CanaryOutcome(true) end
        return
    end
    if info.canary then
        CanaryOutcome(false)
        if info.tries < CANARY_RETRIES then
            Scanner.retryQueue[#Scanner.retryQueue + 1] = { id = id, tries = info.tries + 1, canary = true }
        elseif now - Scanner.lastThrottleAt < TIMEOUT + 2 then
            s.unanswered[id] = true          -- silent during a throttle: ask again later
        else
            s.missing[id] = true             -- a vanilla quest Forever removed
            Scanner.stats.silent = Scanner.stats.silent + 1
            Scanner.recentSilent[#Scanner.recentSilent + 1] = { id = id, at = now }
        end
        return
    end
    -- unknown id, silent: assume it does not exist unless we were throttled meanwhile
    if now - Scanner.lastThrottleAt < TIMEOUT + 2 and info.tries < 3 then
        Scanner.retryQueue[#Scanner.retryQueue + 1] = { id = id, tries = info.tries + 1 }
        return
    end
    s.missing[id] = true
    Scanner.stats.silent = Scanner.stats.silent + 1
    Scanner.recentSilent[#Scanner.recentSilent + 1] = { id = id, at = now }
    if #Scanner.recentSilent > 2000 then table.remove(Scanner.recentSilent, 1) end
end

local lastReport = 0
local function Tick(gen)
    if gen ~= Scanner.gen or not Scanner.running then return end   -- a stale chain (stop + quick restart) dies here
    local s = Store()
    local now = ns.Now()
    local dt = math.min(1, now - (Scanner.lastTick or now))
    Scanner.lastTick = now
    Scanner.budget = math.min(Scanner.rate * 2, Scanner.budget + Scanner.rate * dt)

    -- judge silent requests
    for id, info in pairs(Scanner.inflight) do
        if now - info.sentAt > TIMEOUT then
            Remove(id)
            Judge(id, info, now)
        end
    end

    -- send: retries first, an occasional canary, then fresh ids
    local looked = 0
    if Scanner.pausedUntil and now < Scanner.pausedUntil then
        Scanner.budget = 0
        looked = 400
    end
    while Scanner.budget >= 1 and looked < 400 do
        looked = looked + 1
        local item = table.remove(Scanner.retryQueue, 1)
        local id, tries, canary
        if item then
            id, tries, canary = item.id, item.tries, item.canary
        elseif Scanner.sinceCanary >= CANARY_EVERY and #Scanner.canaryPool > 0 then
            id, canary = table.remove(Scanner.canaryPool), true
            Scanner.reserved[id] = nil
        else
            id = NextID(s)
            if not id then
                -- ranges exhausted: drain the canary pool as ordinary ids
                id = table.remove(Scanner.canaryPool)
                if id then Scanner.reserved[id] = nil canary = true end
            end
            if not id then break end
        end
        local before = Scanner.stats.sent
        Send(id, tries, canary)
        if Scanner.stats.sent > before then Scanner.budget = Scanner.budget - 1 end
    end

    if Scanner.inflightCount == 0 and #Scanner.retryQueue == 0 and #Scanner.canaryPool == 0 and not NextID(s)
        and not (Scanner.pausedUntil and now < Scanner.pausedUntil) then
        Scanner:Finish()
        return
    end

    if now - lastReport > 15 then
        lastReport = now
        local st = Scanner.stats
        ns.Printf("scan: at id %s | %d exist (%d cached), %d silent | canaries %d ok / %d silent, throttled %dx | %.1f req/s",
            tostring(s.cursor and s.cursor[2]), st.found, st.cached, st.silent, st.canaryOK, st.canarySilent, st.throttles, Scanner.rate)
    end
    C_Timer.After(TICK, function() Tick(gen) end)
end

-- ------------------------------------------------------------
-- Control
-- ------------------------------------------------------------
local function BuildCanaryPool(s)
    BuildVanilla()
    Scanner.canaryPool, Scanner.reserved = {}, {}
    local n = 0
    for _, id in ipairs(ns.VanillaQuestIDs or {}) do
        local inRange = false
        for _, r in ipairs(s.ranges) do
            if id >= r[1] and id <= r[2] then inRange = true break end
        end
        if inRange and not Known(s, id) and not CachedTitle(id) then
            n = n + 1
            if n % CANARY_RESERVE_EVERY == 0 then
                Scanner.canaryPool[#Scanner.canaryPool + 1] = id
                Scanner.reserved[id] = true
            end
        end
    end
    -- pop from the end: reverse so low ids go first
    local rev = {}
    for i = #Scanner.canaryPool, 1, -1 do rev[#rev + 1] = Scanner.canaryPool[i] end
    Scanner.canaryPool = rev
end

function Scanner:Begin(retryQueue)
    local s = Store()
    self.gen = (self.gen or 0) + 1
    self.running = true
    self.pausedUntil = nil
    self.inflight, self.inflightCount = {}, 0
    self.retryQueue = retryQueue or {}
    self.rate, self.budget = RATE_START, 0
    self.lastTick = ns.Now()
    self.canaryHistory, self.cleanCanaries, self.sinceCanary = {}, 0, 0
    self.recentSilent, self.lastThrottleAt = {}, -1000
    self.stats = NewStats()
    self.startedAt = ns.Now()
    lastReport = ns.Now()
    BuildCanaryPool(s)
    Tick(self.gen)
end

function Scanner:Start(from, to)
    if self.running then ns.Print("scan already running (/fg scan stop)") return end
    local s = Store()
    if from then
        from, to = tonumber(from), tonumber(to) or tonumber(from)
        if from > to then from, to = to, from end
        s.ranges = { { from, to } }
    else
        s.ranges = {}
        for i, r in ipairs(DEFAULT_RANGES) do s.ranges[i] = { r[1], r[2] } end
    end
    s.cursor = { 1, s.ranges[1][1] }
    s.done = false
    s.build = PlainString(select(2, ns.Safe(GetBuildInfo)))
    s.unanswered = {}
    local desc = {}
    for _, r in ipairs(s.ranges) do desc[#desc + 1] = r[1] .. "-" .. r[2] end
    ns.Printf("scanning quest ids %s (ids already known are skipped). /fg scan status | stop | resume", table.concat(desc, ", "))
    self:Begin()
end

function Scanner:Resume()
    if self.running then ns.Print("scan already running") return end
    local s = Store()
    if not s.ranges or not s.cursor then ns.Print("nothing to resume - /fg scan to start") return end
    BuildVanilla()
    local queue = {}
    for id in pairs(s.unanswered) do queue[#queue + 1] = { id = id, tries = 1, canary = vanilla[id] } end
    table.sort(queue, function(a, b) return a.id < b.id end)
    s.unanswered = {}
    if s.done then
        if #queue == 0 then ns.Print("scan is complete and nothing is unanswered.") return end
        s.cursor = { #s.ranges + 1, 0 }
        s.done = false
        ns.Printf("re-asking %d unanswered ids.", #queue)
    else
        ns.Printf("resuming scan at id %d (%d unanswered ids re-asked first).", s.cursor[2], #queue)
    end
    self:Begin(queue)
end

function Scanner:Stop()
    if not self.running then return end
    self.running = false
    local s = Store()
    for id in pairs(self.inflight) do s.unanswered[id] = true end
    for _, r in ipairs(self.retryQueue) do s.unanswered[r.id] = true end
    self.inflight, self.inflightCount, self.retryQueue = {}, 0, {}
    self.canaryPool, self.reserved = {}, {}
    ns.Printf("scan paused at id %s: %d exist so far. /fg scan resume to continue.", tostring(s.cursor and s.cursor[2]), self.stats.found)
end

local function Counts(s)
    local total, missing, un = 0, 0, 0
    for _ in pairs(s.quests) do total = total + 1 end
    for _ in pairs(s.missing) do missing = missing + 1 end
    for _ in pairs(s.unanswered) do un = un + 1 end
    return total, missing, un
end

function Scanner:Finish()
    if not self.running then return end
    self.running = false
    local s = Store()
    s.done = true
    local total, missing, un = Counts(s)
    -- ids left unanswered by throttling get another pass automatically
    self.pass = (self.pass or 1)
    if un > 0 and self.pass < MAX_PASSES then
        self.pass = self.pass + 1
        ns.Printf("scan: pass %d done, %d ids were unanswered during throttling - asking them again.", self.pass - 1, un)
        local pass = self.pass
        self:Resume()
        self.pass = pass
        return
    end
    self.pass = nil
    ns.Printf("scan finished in %ds: %d quests exist, %d ids silent (assumed not to exist / removed), %d unanswered during throttling. /reload to save, then run tools/scan_diff.py.",
        math.floor(ns.Now() - self.startedAt), total, missing, un)
end

function Scanner:Status()
    local s = ns.db.scan
    if not s or not s.ranges then ns.Print("no scan data. /fg scan to start.") return end
    local total, missing, un = Counts(Store())
    local st = self.stats
    ns.Printf("scan %s: cursor id %s, %d exist, %d silent, %d unanswered%s",
        self.running and "RUNNING" or (s.done and "finished" or "paused"), tostring(s.cursor and s.cursor[2]),
        total, missing, un,
        self.running and string.format(" | %.1f req/s, in flight %d, retries %d, canaries left %d, throttled %dx, %ds elapsed",
            self.rate, self.inflightCount, #self.retryQueue, #self.canaryPool, st.throttles or 0,
            math.floor(ns.Now() - self.startedAt)) or "")
end

function Scanner:OnInit()
    ns.Events:Register("QUEST_DATA_LOAD_RESULT", function(_, questID, success)
        questID = PlainNumber(questID)
        if not questID then return end
        local info = Remove(questID)
        if not info then return end
        local s = Store()
        if PlainBool(success) then
            Record(s, questID, PlainString(ns.Call("C_QuestLog.GetTitleForQuestID", questID)) or "")
            self.stats.found = self.stats.found + 1
            if info.canary then CanaryOutcome(true) end
        else
            s.missing[questID] = true
            self.stats.silent = self.stats.silent + 1
            if info.canary then CanaryOutcome(true) end   -- an explicit "no" still proves the server talks to us
        end
    end)

    -- quests seen in the log are free data
    ns.Events:Register("FG_QUEST_LOG_CHANGED", function()
        local s = Store()
        for entry in ns.Quest:Iterate() do
            if entry.title and entry.title ~= "" then Record(s, entry.questID, entry.title) end
        end
    end)
end
