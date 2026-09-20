-- ============================================================
-- ForeverGuide / tools/lib/route_model.lua
-- The xp / time model behind the route planner.
--   * real Classic xp-to-level table
--   * kill xp per mob (Classic formula: base 45+5L, +5% per level above,
--     linear fall-off below, grey at L - ZD(L), elite x2)
--   * how long a quest's objectives take (kills, drop rates, gathering,
--     escorts) and what they pay
--   * the grind rate: xp per second from just killing even-level mobs,
--     the yardstick every quest is measured against
-- Everything is in seconds and xp. Knobs via environment variables.
-- ============================================================
local M = {}

local function env(name, default) return tonumber(os.getenv(name) or "") or default end

-- xp needed to go from level L to L+1 (Classic 1.12 table)
M.XP_TABLE = {
    400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200,
    25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400, 50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800,
    85700, 90700, 95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500, 153900, 160400, 167100, 173900,
    180800, 187900, 195000, 202300, 209800,
}
local cumulative = { [1] = 0 }
for L = 2, 61 do cumulative[L] = cumulative[L - 1] + (M.XP_TABLE[L - 1] or M.XP_TABLE[59]) end
function M.xpToLevel(L) return cumulative[math.max(1, math.min(61, math.floor(L)))] end
function M.levelAt(xp)
    local L = 1
    while L < 60 and xp >= cumulative[L + 1] do L = L + 1 end
    return L
end
function M.xpForLevel(L) return M.XP_TABLE[math.max(1, math.min(59, L))] end

-- ---- knobs -------------------------------------------------------------------
M.RUN_SPEED = env("FG_RUN", 7.0)            -- yards / second on foot
M.MOUNT_LEVEL = env("FG_MOUNTLVL", 40)
M.MOUNT_SPEED = env("FG_MOUNTSPEED", 11.2)  -- 60% mount
M.KILL_TIME = env("FG_KILLTIME", 15)        -- base seconds per even-level kill incl. looting and regen (see killBase)
M.DROP_RATE = env("FG_DROP", 0.55)          -- assumed quest item drop chance from mobs
M.GATHER_TIME = env("FG_GATHER", 18)        -- seconds per ground object (walk to it, respawn waits)
M.EVENT_TIME = env("FG_EVENT", 25)          -- a trigger / "explore" objective
M.ESCORT_TIME = env("FG_ESCORT", 330)       -- an escort quest
M.TALK_TIME = env("FG_TALK", 8)             -- accept / turn-in / talk
M.DEFAULT_KILLS = env("FG_KILLS", 8)        -- kill count when the text does not say
M.DEFAULT_ITEMS = env("FG_ITEMS", 6)
M.VALUE_MIN = env("FG_VALUE", 0.6)          -- a quest package must pay at least this share of the grind rate
M.SHARED_TRAVEL = env("FG_SHARED", 0.5)     -- share of a quest's travel it really pays itself (the rest is shared with neighbours)
M.LOG_CAP = env("FG_LOGCAP", 40)     -- WoW Forever: C_QuestLog.GetMaxNumQuestsCanAccept() == 40 (Classic had 20)
M.HEARTH_CD = env("FG_HEARTHCD", 3600)      -- Classic hearthstone cooldown

function M.speed(L) return L >= M.MOUNT_LEVEL and M.MOUNT_SPEED or M.RUN_SPEED end

-- ---- kill xp ------------------------------------------------------------------
local function zeroDiff(L)
    if L < 8 then return 5 elseif L < 10 then return 6 elseif L < 12 then return 7 elseif L < 16 then return 8
    elseif L < 20 then return 9 elseif L < 30 then return 11 elseif L < 40 then return 12 elseif L < 45 then return 13
    elseif L < 50 then return 14 elseif L < 55 then return 15 elseif L < 60 then return 16 else return 17 end
end
M.zeroDiff = zeroDiff
function M.killXP(playerL, mobL, elite)
    local base = 45 + 5 * playerL
    local xp
    if mobL >= playerL then
        xp = base * (1 + 0.05 * (mobL - playerL))
    else
        local zd = zeroDiff(playerL)
        if playerL - mobL >= zd then return 0 end
        xp = base * (1 - (playerL - mobL) / zd)
    end
    if elite then xp = xp * 2 end
    return xp
end
-- seconds per even-level kill at this player level (solo, average class, incl. loot,
-- regen and walking to the next mob): slow at 1-9 (few abilities, lots of resting),
-- then creeping up with mob health
function M.killBase(L)
    if L < 10 then return M.KILL_TIME + 5 - 0.25 * L end
    return M.KILL_TIME + 0.25 * L
end
function M.killTime(playerL, mobL, elite)
    local t = M.killBase(playerL) * (1 + 0.12 * (mobL - playerL))
    if t < 5 then t = 5 end
    if elite then t = t * 4 end
    return t
end
-- xp per second from grinding even-level mobs: the opportunity cost of everything else
function M.grindRate(L)
    return M.killXP(L, L, false) / (M.killBase(L) + 2)
end

-- ---- quest reward ------------------------------------------------------------------
M.REDUCTION = { [6] = 0.8, [7] = 0.6, [8] = 0.4, [9] = 0.2 }
function M.xpMultiplier(playerL, questL)
    local diff = playerL - (questL or 1)
    if diff <= 5 then return 1 end
    return M.REDUCTION[diff] or 0.1
end
function M.marginOf(playerL, questL) return math.max(0, (questL or 1) + 5 - playerL) end
function M.questReward(q)
    local lvl = q.lvl or 1
    return q.xp or (50 * lvl + 1.5 * lvl * lvl)
end

-- ---- objective cost -------------------------------------------------------------------
--- Seconds of work and kill xp for one objective at player level L (no travel).
function M.objectiveCost(o, L, escort)
    if o.done then return 0, 0 end
    local count = o.count
    if o.kind == "KILL" then
        count = count or M.DEFAULT_KILLS
        local mobL = o.mob and math.floor((o.mob.min + o.mob.max) / 2 + 0.5) or L
        local kills = count
        if o.drop then kills = math.ceil(count / M.DROP_RATE) end
        return kills * M.killTime(L, mobL, o.elite), kills * M.killXP(L, mobL, o.elite)
    elseif o.kind == "COLLECT" then
        count = count or M.DEFAULT_ITEMS
        if o.drop and o.mob then
            local mobL = math.floor((o.mob.min + o.mob.max) / 2 + 0.5)
            local kills = math.ceil(count / M.DROP_RATE)
            return kills * M.killTime(L, mobL, o.elite), kills * M.killXP(L, mobL, o.elite)
        end
        return count * M.GATHER_TIME, 0
    else -- COMPLETE / trigger / event
        if escort then return M.ESCORT_TIME, 0 end
        return (count or 1) * M.EVENT_TIME, 0
    end
end

--- Total work (seconds) and xp (reward + kills) of a quest at level L, no travel.
function M.questCost(qq, L)
    local work, xp = M.TALK_TIME * 2, M.questReward(qq.q) * M.xpMultiplier(L, qq.q.lvl)
    local escort = qq.escort
    for _, o in ipairs(qq.objs) do
        local w, x = M.objectiveCost(o, L, escort)
        work, xp = work + w, xp + x
    end
    -- a Forever quest whose objectives nobody has recorded yet is not a free delivery:
    -- assume an average kill quest's work (and no kill xp, since we do not know the mobs)
    if qq.q.forever and #qq.objs == 0 then
        work = work + M.DEFAULT_KILLS * M.killTime(L, L, false) + 60
    end
    return work, xp
end

return M
