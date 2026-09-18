-- ============================================================
-- ForeverGuide / Events.lua
-- One event frame for the whole addon, plus an internal message bus.
--
--   ns.Events:Register("QUEST_ACCEPTED", fn)     game event
--   ns.Events:Register("FG_STEP_CHANGED", fn)    internal message (FG_ prefix)
--   ns.Events:Fire("FG_STEP_CHANGED", ...)       broadcast internal message
--   ns.Events:Debounce("questlog", 0.2, fn)      coalesce bursts of events
--
-- Every handler runs inside pcall and a failing handler is reported
-- once, so one bug never kills the rest of the addon.
-- ============================================================

local _, ns = ...
local Events = ns:NewModule("Events")

local frame = CreateFrame("Frame", "ForeverGuideEventFrame")
local handlers = {}      -- event -> { fn, fn, ... }
local registered = {}    -- game events registered on the frame
local pending = {}       -- debounce keys

local function IsInternal(event)
    return string.sub(event, 1, 3) == "FG_"
end

function Events:Register(event, fn)
    if type(fn) ~= "function" then return end
    local list = handlers[event]
    if not list then
        list = {}
        handlers[event] = list
    end
    list[#list + 1] = fn
    if not IsInternal(event) and not registered[event] then
        local ok = pcall(frame.RegisterEvent, frame, event)
        registered[event] = ok
        if not ok then
            ns.Debug("event does not exist on this client:", event)
        end
    end
end

function Events:RegisterMany(events, fn)
    for _, ev in ipairs(events) do self:Register(ev, fn) end
end

function Events:Unregister(event, fn)
    local list = handlers[event]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then table.remove(list, i) end
    end
end

function Events:Fire(event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], event, ...)
        if not ok then ns.ReportOnce(event, err) end
    end
end

--- Run fn once, `delay` seconds after the first call, ignoring repeats in between.
function Events:Debounce(key, delay, fn)
    if pending[key] then return end
    pending[key] = true
    C_Timer.After(delay, function()
        pending[key] = nil
        local ok, err = pcall(fn)
        if not ok then ns.ReportOnce("debounce:" .. key, err) end
    end)
end

function Events:After(delay, fn)
    C_Timer.After(delay, function()
        local ok, err = pcall(fn)
        if not ok then ns.ReportOnce("after", err) end
    end)
end

function Events:IsRegistered(event)
    return registered[event] == true
end

frame:SetScript("OnEvent", function(_, event, ...)
    Events:Fire(event, ...)
end)

Events.frame = frame
