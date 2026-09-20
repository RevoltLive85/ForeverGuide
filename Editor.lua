-- ============================================================
-- ForeverGuide / Editor.lua
-- In-game corrections to guide steps (Phase 11, the small version):
--   /fg edit here            the current step's location = where I stand
--   /fg edit npc             the current step's npc = my target
--   /fg edit note <text>     replace the step's note
--   /fg edit radius <yards>  arrival radius for TRAVEL steps
--   /fg edit clear           forget my edits for this step
--   /fg edits [clear]        list (or wipe) every edit of the active guide
-- Edits live in ForeverGuideDB.edits[guideID][stepIndex] and are applied
-- at runtime (Navigation:ResolveStep / Guide:GetStepText); the route
-- fixer folds them into guides-src/*.json with tools/apply_edits.py.
-- ============================================================

local _, ns = ...
local Editor = ns:NewModule("Editor")

local function Store(guideID, create)
    ns.db.edits = ns.db.edits or {}
    if not guideID then return nil end
    if create then ns.db.edits[guideID] = ns.db.edits[guideID] or {} end
    return ns.db.edits[guideID]
end

--- The edit record for a step of a guide (nil if none).
function Editor:Get(guideID, idx)
    local g = Store(guideID)
    return g and g[idx] or nil
end

local function Current()
    local G = ns.Guide
    if not G.active then return nil, nil, "no guide active" end
    local step = G:GetCurrentStep()
    if not step then return nil, nil, "guide finished" end
    return G.active, step
end

local function Touch(guide, step)
    local edits = Store(guide.id, true)
    local e = edits[step.index] or {}
    e.type, e.quest, e.t = step.type, step.quest, ns.Now()
    e.version = guide.version
    edits[step.index] = e
    return e
end

function Editor:Here()
    local guide, step, why = Current()
    if not guide then return false, why end
    local map, x, y = ns.Player:GetMapPosition()
    if not map or not x then return false, "no map position here (instance?)" end
    local e = Touch(guide, step)
    e.map, e.x, e.y = map, ns.Round(x, 2), ns.Round(y, 2)
    e.zone = ns.Player:GetMapName(map)
    ns.Guide:Evaluate("edit")
    return true, string.format("step %d now points at %s %.1f, %.1f", step.index, e.zone or map, e.x, e.y)
end

function Editor:NPC()
    local guide, step, why = Current()
    if not guide then return false, why end
    local u = ns.Player:GetUnitInfo("target")
    if not u or not u.npcID then return false, "target an NPC first" end
    local e = Touch(guide, step)
    e.npc, e.npcName = u.npcID, u.name
    local map, x, y = ns.Player:GetMapPosition()
    if map and x and not e.x then e.map, e.x, e.y, e.zone = map, ns.Round(x, 2), ns.Round(y, 2), ns.Player:GetMapName(map) end
    ns.Guide:Evaluate("edit")
    return true, string.format("step %d now uses %s (%d)", step.index, u.name, u.npcID)
end

function Editor:Note(text)
    local guide, step, why = Current()
    if not guide then return false, why end
    local e = Touch(guide, step)
    e.note = text ~= "" and text or nil
    ns.Events:Fire("FG_STEP_UPDATED", step, guide, "edit")
    return true, e.note and ("note set on step " .. step.index) or ("note cleared on step " .. step.index)
end

function Editor:Radius(yards)
    local guide, step, why = Current()
    if not guide then return false, why end
    yards = tonumber(yards)
    if not yards or yards < 3 or yards > 500 then return false, "radius must be 3-500 yards" end
    local e = Touch(guide, step)
    e.radius = yards
    ns.Guide:Evaluate("edit")
    return true, string.format("step %d arrival radius = %d yd", step.index, yards)
end

function Editor:Clear()
    local guide, step, why = Current()
    if not guide then return false, why end
    local edits = Store(guide.id)
    if not edits or not edits[step.index] then return false, "no edits on this step" end
    edits[step.index] = nil
    ns.Guide:Evaluate("edit")
    return true, "edits on step " .. step.index .. " removed"
end

function Editor:ClearGuide()
    local G = ns.Guide
    if not G.active then return false, "no guide active" end
    ns.db.edits = ns.db.edits or {}
    ns.db.edits[G.active.id] = nil
    G:Evaluate("edit")
    return true, "all edits of " .. (G.active.name or G.active.id) .. " removed"
end

function Editor:List()
    local G = ns.Guide
    if not G.active then ns.Print("no guide active.") return end
    local edits = Store(G.active.id)
    local n = 0
    if edits then
        local idx = {}
        for i in pairs(edits) do idx[#idx + 1] = i end
        table.sort(idx)
        for _, i in ipairs(idx) do
            local e = edits[i]
            local parts = {}
            if e.x and e.y then parts[#parts + 1] = string.format("%s %.1f,%.1f", e.zone or tostring(e.map), e.x, e.y) end
            if e.npc then parts[#parts + 1] = string.format("npc %s (%d)", e.npcName or "?", e.npc) end
            if e.note then parts[#parts + 1] = '"' .. e.note .. '"' end
            if e.radius then parts[#parts + 1] = e.radius .. " yd" end
            ns.Printf("  step %d %s%s: %s", i, e.type or "", e.quest and (" quest " .. e.quest) or "", table.concat(parts, ", "))
            n = n + 1
        end
    end
    ns.Printf("%d edited step%s in %s. tools/apply_edits.py folds them into the guide source.", n, n == 1 and "" or "s", G.active.name or G.active.id)
end

--- Apply the edit on top of a step for navigation: returns a step-like table
--- (the original when nothing is edited).
function Editor:Effective(step)
    local G = ns.Guide
    if not step or not G.active then return step end
    local e = self:Get(G.active.id, step.index)
    if not e then return step end
    local out = {}
    for k, v in pairs(step) do out[k] = v end
    if e.x then out.map, out.x, out.y, out.zone = e.map, e.x, e.y, e.zone end
    if e.npc then out.npc = e.npc out.npcName = e.npcName end
    if e.note then out.note = e.note end
    if e.radius then out.radius = e.radius end
    out.hasEdit = true                               -- "(edited)" in the tooltip
    out.edited = (e.x ~= nil) or (e.npc ~= nil)      -- only a pinned spot/npc overrides the resolver's better guesses
    return out
end
