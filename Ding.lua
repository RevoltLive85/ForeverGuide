-- ============================================================
-- ForeverGuide / Ding.lua
-- Level-up announcement:
--
--     ForeverGuide: I leveled up to 18 in 1h 24m
--
-- goes to the party (or raid / instance group) when you are grouped, and as an
-- emote when you are not - so the people around you see it either way.
--
-- The time is the time PLAYED at the level you just left. The server answers
-- TIME_PLAYED_MSG(total, thisLevel), but a request made after the ding already
-- counts the new level, so the module keeps the last answer and adds the time
-- since: exact while you are online, and refreshed from the server at every
-- login and after every level. `/fg ding` turns it off or picks a channel.
-- ============================================================

local _, ns = ...
local Ding = ns:NewModule("Ding")

local CHANNELS = {          -- what /fg ding <name> means
    auto = "auto", party = "PARTY", raid = "RAID", guild = "GUILD",
    emote = "EMOTE", say = "SAY", yell = "YELL",
}

local function cfg()
    ns.db.ding = ns.db.ding or {}
    local c = ns.db.ding
    if c.enabled == nil then c.enabled = false end
    if c.channel == nil then c.channel = "auto" end
    return c
end
Ding.Cfg = cfg

-- ---- time played --------------------------------------------------------------------------

local silenceOnce      -- defined below, used by Request

--- "42 sec" / "18 min" / "1h 24m" / "2d 3h"
function Ding.FormatTime(seconds)
    local s = math.floor(tonumber(seconds) or 0)
    if s < 60 then return string.format("%d sec", s) end
    local d = math.floor(s / 86400)
    local h = math.floor(s % 86400 / 3600)
    local m = math.floor(s % 3600 / 60)
    if d > 0 then return string.format("%dd %dh", d, h) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%d min", m)
end

--- Ask the server, quietly: the "Total time played / Time played this level" lines that answer
--- OUR request are swallowed for a few seconds; a /played the player types still prints.
function Ding:Request()
    local f = rawget(_G, "RequestTimePlayed")
    if type(f) ~= "function" then return false end
    silenceOnce()
    self.quietUntil = ns.Now() + 4
    self.requestedAt = ns.Now()
    local ok = pcall(f)
    if not ok then self.quietUntil = nil end
    return ok
end

--- Seconds played at the level the player is on now, or nil when the server never answered.
function Ding:Elapsed()
    if self.played then
        return math.max(0, self.played.level + (ns.Now() - self.played.at))
    end
    if self.levelSince then return math.max(0, ns.Now() - self.levelSince) end
    return nil
end

-- Every request answers with "Total time played: ..." and "Time played this level: ...". The client
-- prints them through ChatFrame_DisplayTimePlayed, and the Forever server also sends them as plain
-- system messages, so both paths are held shut while one of our own requests is in flight.
local function quiet()
    return Ding.quietUntil ~= nil and ns.Now() <= Ding.quietUntil
end

local function headOf(globalName, fallback)
    local fmt = rawget(_G, globalName)
    local text = type(fmt) == "string" and fmt or fallback
    return (string.gsub(text, "%%s.*", ""))
end

function silenceOnce()
    if not Ding.hookedPrint then
        local orig = rawget(_G, "ChatFrame_DisplayTimePlayed")
        if type(orig) == "function" then
            Ding.hookedPrint = true
            _G.ChatFrame_DisplayTimePlayed = function(...)
                if quiet() then return end
                return orig(...)
            end
        end
    end
    local total = headOf("TIME_PLAYED_TOTAL", "Total time played: ")
    local level = headOf("TIME_PLAYED_LEVEL", "Time played this level: ")
    local function isPlayedLine(message)
        return type(message) == "string"
            and (string.find(message, total, 1, true) == 1 or string.find(message, level, 1, true) == 1)
    end
    Ding.IsPlayedLine = isPlayedLine

    if not Ding.hookedFilter then
        local add = rawget(_G, "ChatFrame_AddMessageEventFilter")
        if type(add) == "function" then
            Ding.hookedFilter = true
            pcall(add, "CHAT_MSG_SYSTEM", function(_, _, message)
                return quiet() and isPlayedLine(message) or false
            end)
        end
    end

    -- last line of defence: the client may print the two lines straight into the chat frame,
    -- past both the event filter and ChatFrame_DisplayTimePlayed (it does on Forever 1.60.1).
    if not Ding.hookedFrames then
        Ding.hookedFrames = true
        local n = rawget(_G, "NUM_CHAT_WINDOWS") or 10
        for i = 1, n do
            local frame = rawget(_G, "ChatFrame" .. i)
            if frame and type(frame.AddMessage) == "function" and not frame.fgDingWrapped then
                frame.fgDingWrapped = true
                local orig = frame.AddMessage
                frame.AddMessage = function(self, message, ...)
                    if quiet() and isPlayedLine(message) then return end
                    return orig(self, message, ...)
                end
            end
        end
    end
end

-- ---- the announcement ---------------------------------------------------------------------

--- PARTY / RAID / INSTANCE_CHAT / EMOTE ... for the current setting and group state.
function Ding:Channel()
    local want = cfg().channel or "auto"
    if want ~= "auto" then return CHANNELS[want] or "EMOTE" end
    local E = rawget(_G, "Enum")
    local instance = E and E.PartyCategory and E.PartyCategory.Instance
    if instance and ns.Plain(ns.Safe(rawget(_G, "IsInGroup"), instance)) == true then return "INSTANCE_CHAT" end
    if ns.Plain(ns.Safe(rawget(_G, "IsInRaid"))) == true then return "RAID" end
    if ns.Plain(ns.Safe(rawget(_G, "IsInGroup"))) == true then return "PARTY" end
    return "EMOTE"
end

--- The line itself. `seconds` nil = the time is unknown, so it is left out.
function Ding.Message(level, seconds)
    if seconds then
        return string.format("ForeverGuide: I leveled up to %d in %s", level or 0, Ding.FormatTime(seconds))
    end
    return string.format("ForeverGuide: I leveled up to %d", level or 0)
end

--- Say it. Returns true when the client took the message, false (and why) when it did not.
function Ding:Send(message, channel)
    local CI = rawget(_G, "C_ChatInfo")
    if CI and CI.InChatMessagingLockdown and ns.Plain(ns.Safe(CI.InChatMessagingLockdown)) == true then
        return false, "chat is locked down right now"
    end
    local send = rawget(_G, "SendChatMessage")
    local ok, err
    if type(send) == "function" then
        ok, err = pcall(send, message, channel)
    elseif CI and CI.SendChatMessage then
        ok, err = pcall(CI.SendChatMessage, message, channel)
    else
        return false, "this client has no SendChatMessage"
    end
    if not ok then return false, tostring(err) end
    return true
end

--- The whole thing: build the line, send it, and say so in chat when the client refused.
function Ding:Announce(level, seconds, why)
    local message = Ding.Message(level, seconds)
    local channel = self:Channel()
    local ok, err = self:Send(message, channel)
    if ok then
        self.lastSent = { message = message, channel = channel, at = ns.Now() }
        return true, message, channel
    end
    ns.Printf("%s  (could not send it to %s: %s - /fg ding off to stop trying)", message, string.lower(channel), err or "refused")
    return false, message, channel
end

function Ding:OnLevelUp(level)
    if cfg().enabled == false then return end
    local seconds = self:Elapsed()
    self:Announce(level or ns.Player:GetLevel(), seconds)
    -- the new level starts now; re-baseline from the server in a moment
    self.levelSince = ns.Now()
    self.played = nil
    ns.Events:After(3, function() Ding:Request() end)
end

-- ---- events -------------------------------------------------------------------------------

function Ding:OnInit()
    ns.Events:Register("TIME_PLAYED_MSG", function(_, total, atLevel)
        local t, l = ns.PlainNumber(total), ns.PlainNumber(atLevel)
        if not l then return end
        Ding.played = { total = t or 0, level = l, at = ns.Now() }
        Ding.levelSince = ns.Now() - l
        if Ding.pendingPrint then
            Ding.pendingPrint = nil
            ns.Printf("time played: %s at level %d, %s in total.", Ding.FormatTime(l), ns.Player:GetLevel(), Ding.FormatTime(t or 0))
        end
    end)
    ns.Events:Register("PLAYER_LEVEL_UP", function(_, level)
        Ding:OnLevelUp(ns.PlainNumber(level))
    end)
end

function Ding:OnEnterWorld()
    silenceOnce()
    if not self.asked then
        self.asked = true
        ns.Events:After(5, function() Ding:Request() end)   -- after the login chatter
    end
end
