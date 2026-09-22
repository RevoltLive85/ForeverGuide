-- ============================================================
-- ForeverGuide / Pace.lua
-- How fast you are levelling, and what that means for the rest of the route:
--
--     /fg xp
--     Level 18: 42% (8 240 / 19 600), 11 360 to go
--     11 200 xp/h (last 30 min)  ->  level 19 in about 1h 0m
--     Chapter 5. Redridge Mountains 17-19: step 15/46, 50 min in - the model
--       allows 2h 25m for it, so you are running about 1.2x its pace
--     Level 60 in about 78 h of play at this rate (39 chapters left)
--
-- The rate is measured over a rolling window of real play (gaps longer than
-- five minutes are dropped, so a break does not ruin the average). The route
-- estimate uses the planner's own model: every generated chapter carries the
-- minutes it budgeted, so the remaining chapters can be scaled by how fast
-- you are actually going.
-- ============================================================

local _, ns = ...
local Pace = ns:NewModule("Pace")

local WINDOW = 1800          -- seconds of play the "recent" rate looks back over
local GAP = 300              -- a pause longer than this is not counted as play
local MIN_SAMPLE = 120       -- seconds before a rate is worth showing

Pace.samples = {}            -- { { at = played seconds, xp = xp earned by then }, ... }
Pace.played = 0              -- seconds of real play seen this session
Pace.earned = 0              -- xp earned this session

local function levelXP()
    local xp, max = ns.Player:GetXP()
    return xp or 0, max or 0
end

--- Comma-grouped for the readout ("19 600").
function Pace.Number(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^%s+", ""))
end

--- "1h 0m" / "35 min" / "2d 3h" - the same shape the level-up line uses.
function Pace.Duration(seconds)
    return ns.Ding and ns.Ding.FormatTime(seconds) or string.format("%d min", math.floor((seconds or 0) / 60))
end

-- ---- measuring ------------------------------------------------------------------------------

function Pace:Tick()
    local now = ns.Now()
    local last = self.lastTick or now
    local delta = now - last
    self.lastTick = now
    if delta > 0 and delta < GAP then self.played = self.played + delta end
    return self.played
end

--- xp earned since the last look, level-ups included.
function Pace:Sample(reason)
    local xp, max = levelXP()
    local level = ns.Player:GetLevel()
    local before = self.lastXP
    local gained = 0
    if before and self.lastLevel then
        if level == self.lastLevel then
            gained = xp - before
        elseif level > self.lastLevel then
            -- the rest of the old level plus what is already on the new one
            gained = math.max(0, (self.lastMax or before) - before) + xp
        end
    end
    self.lastXP, self.lastMax, self.lastLevel = xp, max, level
    if gained <= 0 then return 0 end
    self.earned = self.earned + gained
    local at = self:Tick()
    self.samples[#self.samples + 1] = { at = at, xp = self.earned }
    -- keep the window (and a little before it, so the oldest sample can bracket it)
    while #self.samples > 2 and self.samples[2].at < at - WINDOW do table.remove(self.samples, 1) end
    return gained
end

--- xp per hour over the rolling window, then over the session. nil until there is enough play.
function Pace:PerHour()
    local at = self:Tick()
    local first = self.samples[1]
    if first and at - first.at >= MIN_SAMPLE then
        local span, xp = at - first.at, self.earned - first.xp
        if span > 0 and xp > 0 then return xp / span * 3600, span end
    end
    if self.played >= MIN_SAMPLE and self.earned > 0 then return self.earned / self.played * 3600, self.played end
    return nil
end

-- ---- the route model ------------------------------------------------------------------------

--- The minutes the planner budgeted for a chapter, and the xp/h it assumed.
--- Newer guides carry the numbers; the ones already generated keep them in `notes`.
function Pace.Model(guide)
    if not guide then return nil end
    if guide.modelMinutes then return guide.modelMinutes, guide.modelXph end
    local notes = guide.notes
    if type(notes) ~= "string" then return nil end
    local minutes = tonumber(notes:match("~(%d+)%s*min of play"))
    local xph = tonumber(notes:match("%((%d+)%s*xp/h%)"))
    return minutes, xph
end

--- How you compare with the model on the chapter you are in:
--- elapsed minutes, the model's minutes for the part you have done, and the ratio.
function Pace:Chapter()
    local g = ns.Guide and ns.Guide.active
    if not g then return nil end
    local minutes = Pace.Model(g)
    local step, total = ns.Guide:GetStepCount()
    if not minutes or not total or total <= 0 then return { guide = g, step = step, total = total } end
    local doneFraction = math.min(1, math.max(0, (step - 1) / total))
    local elapsed = (self.chapterStart and (self:Tick() - self.chapterStart)) or nil
    local budget = minutes * 60 * doneFraction
    local ratio
    if elapsed and elapsed > MIN_SAMPLE and budget > 60 then ratio = budget / elapsed end
    return { guide = g, step = step, total = total, minutes = minutes, elapsed = elapsed, budget = budget, ratio = ratio }
end

--- Model minutes left on the route: the rest of this chapter plus every chapter after it.
function Pace:RouteRemaining()
    local G = ns.Guide
    if not G or not G.active then return nil end
    local route = G:CurrentRoute()
    if not route then return nil end
    local total, chapters, seen = 0, 0, false
    for _, g in ipairs(route.chapters) do
        local minutes = Pace.Model(g)
        if g.id == G.active.id then
            seen = true
            local step, steps = G:GetStepCount()
            local left = (steps and steps > 0) and math.max(0, 1 - (step - 1) / steps) or 1
            if minutes then total = total + minutes * left end
            chapters = chapters + 1
        elseif seen then
            if minutes then total = total + minutes end
            chapters = chapters + 1
        end
    end
    if not seen or total <= 0 then return nil end
    return total, chapters
end

-- ---- the readout ----------------------------------------------------------------------------

--- { level, xp, max, percent, remaining, perHour, secondsToLevel, chapter, routeMinutes, chapters }
function Pace:Stats()
    self:Sample("stats")
    local xp, max = levelXP()
    local perHour, span = self:PerHour()
    local remaining = math.max(0, (max or 0) - (xp or 0))
    local out = {
        level = ns.Player:GetLevel(), xp = xp, max = max, remaining = remaining,
        percent = (max and max > 0) and (xp / max * 100) or nil,
        perHour = perHour, span = span,
        atLevel = ns.Ding and ns.Ding:Elapsed() or nil,
        chapter = self:Chapter(),
    }
    if perHour and perHour > 0 and max and max > 0 then out.secondsToLevel = remaining / perHour * 3600 end
    local minutes, chapters = self:RouteRemaining()
    if minutes then
        out.routeMinutes, out.chapters = minutes, chapters
        -- the model's minutes, stretched by how fast you actually are
        local ratio = out.chapter and out.chapter.ratio
        if ratio and ratio > 0 then out.routeSeconds = minutes * 60 / math.max(0.3, math.min(3, ratio)) end
    end
    return out
end

--- The lines /fg xp prints.
function Pace:Lines()
    local s = self:Stats()
    local out = {}
    if s.max and s.max > 0 then
        out[#out + 1] = string.format("Level %d: %d%% (%s / %s), %s to go%s", s.level, math.floor(s.percent or 0),
            Pace.Number(s.xp), Pace.Number(s.max), Pace.Number(s.remaining),
            s.atLevel and (" - " .. Pace.Duration(s.atLevel) .. " at this level") or "")
    else
        out[#out + 1] = string.format("Level %d - no more xp to earn.", s.level)
    end
    if s.perHour then
        out[#out + 1] = string.format("%s xp/h (last %s of play)%s", Pace.Number(s.perHour), Pace.Duration(s.span or 0),
            s.secondsToLevel and string.format("  ->  level %d in about %s", s.level + 1, Pace.Duration(s.secondsToLevel)) or "")
    else
        out[#out + 1] = "not enough play yet for a rate - come back in a couple of minutes."
    end
    local c = s.chapter
    if c and c.guide then
        if c.ratio then
            out[#out + 1] = string.format("%s: step %d/%d, %s in - the model allows %s for the chapter, so you are running about %.1fx its pace",
                c.guide.name or c.guide.id, c.step, c.total, Pace.Duration(c.elapsed), Pace.Duration((c.minutes or 0) * 60), c.ratio)
        else
            out[#out + 1] = string.format("%s: step %d/%d%s", c.guide.name or c.guide.id, c.step, c.total,
                c.minutes and (" - the model allows " .. Pace.Duration(c.minutes * 60) .. " for it") or "")
        end
    end
    if s.routeMinutes then
        out[#out + 1] = string.format("Level 60 in about %s of play%s (%d chapter%s left in the model)",
            Pace.Duration((s.routeSeconds or s.routeMinutes * 60)),
            s.routeSeconds and "" or " by the model's own pace",
            s.chapters, s.chapters == 1 and "" or "s")
    end
    return out, s
end

--- Short header tag: "19 in 1h 0m", or nil while the rate is unknown.
function Pace:Tag()
    local perHour = self:PerHour()
    if not perHour then return nil end
    local xp, max = levelXP()
    if not max or max <= 0 then return nil end
    local seconds = (max - xp) / perHour * 3600
    if seconds <= 0 then return nil end
    return string.format("%d in %s", ns.Player:GetLevel() + 1, Pace.Duration(seconds))
end

-- ---- events ---------------------------------------------------------------------------------

function Pace:OnInit()
    ns.Events:RegisterMany({ "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP" }, function() Pace:Sample("xp") end)
    ns.Events:Register("FG_GUIDE_CHANGED", function()
        Pace.chapterStart = Pace:Tick()
    end)
end

function Pace:OnEnterWorld()
    self.lastTick = ns.Now()
    self.lastXP, self.lastMax, self.lastLevel = nil, nil, nil
    self:Sample("login")
    self.chapterStart = self.chapterStart or self:Tick()
    -- a slow heartbeat keeps "played" honest even while no xp comes in
    if not self.ticker then
        self.ticker = true
        local function beat()
            Pace:Tick()
            ns.Events:After(30, beat)
        end
        ns.Events:After(30, beat)
    end
end
