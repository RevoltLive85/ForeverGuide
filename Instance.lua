-- ============================================================
-- ForeverGuide / Instance.lua
-- Inside a dungeon the levelling guide has nothing useful to say: its steps
-- are outside, its marker points through a wall and its skulls sit on mobs
-- the group is pulling in its own order. So the whole thing steps aside -
-- window, arrow, in-world marker, skulls and banners - and Blizzard's own
-- objective tracker comes back for the dungeon quests.
--
-- Everything returns exactly as it was when you walk out. `/fg dungeon off`
-- keeps the guide up inside if you would rather have it.
-- ============================================================

local _, ns = ...
local Instance = ns:NewModule("Instance")

-- instance types that count as "leave me alone": party = dungeon, raid, and the
-- battlegrounds / arenas, where a levelling guide is just as much in the way.
local QUIET = { party = true, raid = true, scenario = true, pvp = true, arena = true }
local LABEL = { party = "dungeon", raid = "raid", scenario = "scenario", pvp = "battleground", arena = "arena" }

local function cfg()
    ns.db.instance = ns.db.instance or {}
    local c = ns.db.instance
    if c.hide == nil then c.hide = true end
    return c
end
Instance.Cfg = cfg

--- true plus the type ("party") while the character is somewhere the guide should be quiet.
function Instance:Inside()
    local inside, kind = ns.Player:IsInInstance()
    if not inside or not kind then return false, nil end
    if not QUIET[kind] then return false, kind end
    return true, kind
end

--- Step aside / come back. Returns true when something changed.
function Instance:Check(reason)
    local inside, kind = self:Inside()
    local want = inside and cfg().hide ~= false
    if want == (self.hidden or false) then return false end
    self.hidden = want
    ns.UI:Suspend(want, "dungeon")
    if want then
        self.kind = kind
        ns.Printf("%s - the guide is out of the way until you leave (/fg dungeon off keeps it up).",
            (LABEL[kind] or "instance"):gsub("^%l", string.upper))
    else
        ns.Print("out of the instance - the guide is back.")
    end
    ns.Events:Fire("FG_INSTANCE_CHANGED", want, kind)
    return true
end

--- /fg dungeon on|off
function Instance:SetHide(on)
    cfg().hide = on and true or false
    if not cfg().hide and self.hidden then
        self.hidden = false
        ns.UI:Suspend(false, "dungeon")
    else
        self:Check("setting")
    end
    return cfg().hide
end

function Instance:OnInit()
    ns.Events:RegisterMany({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_DIFFICULTY_CHANGED" },
        function(event) Instance:Check(event) end)
end

function Instance:OnEnterWorld()
    self:Check("login")
end
