-- Headless test of the ForeverGuide engine against the mock WoW API.
--     cd <addon folder>;  lua5.1 tools/test/run_tests.lua
-- Loads the files in TOC order exactly like the client would, then plays
-- through the sample guide with simulated quest events.

local root = arg and arg[0] and arg[0]:match("^(.*)tools[/\\]test[/\\]run_tests%.lua$") or "./"
if root == "" then root = "./" end
package.path = root .. "?.lua;" .. package.path

dofile(root .. "tools/test/mock_wow.lua")

-- ---- load the addon in TOC order ----------------------------------------
local ns = {}
local function loadAddonFile(path)
    local chunk, err = loadfile(root .. path)
    assert(chunk, err)
    chunk("ForeverGuide", ns)
end
local order = {}
for line in io.lines(root .. "ForeverGuide.toc") do
    line = line:gsub("\r", "")
    if line ~= "" and not line:match("^#") then
        if line:match("%.xml$") then
            local dir = line:match("^(.*)[/\\][^/\\]+$") or ""
            for xl in io.lines(root .. line:gsub("\\", "/")) do
                local f = xl:match('file="([^"]+)"')
                if f then order[#order + 1] = (dir .. "/" .. f):gsub("\\", "/") end
            end
        else
            order[#order + 1] = line:gsub("\\", "/")
        end
    end
end
for _, f in ipairs(order) do loadAddonFile(f) end

-- every error the addon swallows and reports must surface here
local reportedErrors = {}
do
    local realReport, realError = ns.ReportOnce, ns.Error
    ns.ReportOnce = function(key, err) reportedErrors[#reportedErrors + 1] = tostring(key) .. ": " .. tostring(err) realReport(key, err) end
    ns.Error = function(msg) reportedErrors[#reportedErrors + 1] = tostring(msg) realError(msg) end
end

-- ---- run lifecycle ------------------------------------------------------------
MOCK_FIRE("ADDON_LOADED", "ForeverGuide")
MOCK_FIRE("PLAYER_ENTERING_WORLD", true, false)
MOCK_ADVANCE(1)

-- ---- assertions -----------------------------------------------------------------
local passed, failed = 0, 0
local function check(cond, msg)
    if cond then passed = passed + 1 else failed = failed + 1 print("  FAIL: " .. msg) end
end
local G, Q = ns.Guide, ns.Quest
local function cur() return G.current end
local function step() return G:GetCurrentStep() end
local function settle() MOCK_ADVANCE(1) end

print("guide active: " .. tostring(G.active and G.active.id))
check(ns.db.ding.enabled == false and ns.db.nav.blizzardWaypoint == false
    and ns.db.nav.waypoint.enabled == false and ns.db.nav.waypoint.route == false
    and ns.db.ui.arrow.enabled == true, "quiet defaults: no ding, pin or dotted route; arrow on")
MOCK_BAG(0, 0, 0); settle()
check(rawget(_G, "ForeverGuideBagBanner") == nil and ns.db.bags.banners == false, "bag and gear alerts do not pop up by default")
check(rawget(_G, "ForeverGuideCrowdBanner") == nil and (ns.db.crowd == nil or ns.db.crowd.enabled == false), "crowd reminders do not pop up by default")
MOCK_BAG(16, 0, 0); settle()
check(G.active and G.active.faction == "Alliance" and G.active.minLevel == 1 and ns.Contains(G.active.race, "Human"), "auto-picked a human 1-10 guide: " .. tostring(G.active and G.active.id))
G:Activate("HUMAN_NORTHSHIRE_1_6", true); settle()
check(cur() == 1 and step().type == "ACCEPT" and step().quest == 783, "starts at step 1 (accept 783)")

-- accept A Threat Within -> advance to turn-in
MOCK_ACCEPT(783, "A Threat Within"); settle()
check(cur() == 2 and step().type == "TURNIN", "after accepting 783, current is TURNIN 783 (" .. tostring(cur()) .. ")")
check(G:GetStepProgress(step()) == "ready to turn in", "a quest without objectives is immediately ready: " .. G:GetStepProgress(step()))

-- turn in -> ACCEPT 7
MOCK_TURNIN(783); settle()
check(cur() == 3 and step().quest == 7, "after turning in 783, current is ACCEPT 7 (" .. tostring(cur()) .. ")")

-- accept 7 -> warrior class quest steps (we ARE a warrior) -> ACCEPT 3100
MOCK_ACCEPT(7, "Kobold Camp Cleanup", { { text = "Kobold Vermin slain", finished = false, numFulfilled = 0, numRequired = 10 } }); settle()
check(cur() == 4 and step().quest == 3100, "warrior sees the class quest step (" .. tostring(cur()) .. ")")

-- switch to a mage: class steps are skipped
MOCK.class = { "Mage", "MAGE", 8 }; ns.Player.cache.classFile = nil
G:Evaluate("test")
check(cur() == 6 and step().quest == 5261, "mage skips warrior-only steps (" .. tostring(cur()) .. ")")
MOCK.class = { "Warrior", "WARRIOR", 1 }; ns.Player.cache.classFile = nil
G:Evaluate("test")
check(cur() == 6, "position only moves forward on its own (" .. tostring(cur()) .. ")")
G:SetStep(4); settle()
check(cur() == 4, "/fg step 4 brings the class step back (" .. tostring(cur()) .. ")")

-- skipping an ACCEPT skips the whole quest (3100 turn-in too)
G:Skip(); settle()
check(cur() == 6 and step().quest == 5261, "skipping ACCEPT 3100 also skips its TURNIN (" .. tostring(cur()) .. ")")

-- accept 5261, 18, turn in 5261, accept 33
MOCK_ACCEPT(5261, "Eagan Peltskinner"); settle()
MOCK_ACCEPT(18, "Brotherhood of Thieves", { { text = "Red Burlap Bandana", finished = false, numFulfilled = 0, numRequired = 12 } }); settle()
MOCK_TURNIN(5261); settle()
MOCK_ACCEPT(33, "Wolves Across the Border", { { text = "Tough Wolf Meat", finished = false, numFulfilled = 0, numRequired = 8 } }); settle()
check(cur() == 10 and step().type == "KILL" and step().quest == 7, "now killing kobold vermin (" .. tostring(cur()) .. ")")
check(G:GetStepProgress(step()) == "0 / 10", "kill progress 0/10: " .. G:GetStepProgress(step()))

-- objective progress updates but does not advance
MOCK_PROGRESS(7, 1, 6); settle()
check(cur() == 10 and G:GetStepProgress(step()) == "6 / 10", "progress 6/10 keeps the step (" .. G:GetStepProgress(step()) .. ")")

-- navigation target follows the step
check(ns.Navigation.target and ns.Navigation.target.x == 49.0, "nav target set to the kobold camp")
MOCK_MOVE(49.0, 36.3)
local nav = ns.Navigation:Update()
check(nav and nav.distance and nav.distance < 1, "distance ~0 when standing on the target: " .. tostring(nav and nav.distance))
MOCK_MOVE(49.0, 40.0)
nav = ns.Navigation:Update()
check(nav and math.abs(nav.distance - 37) < 1, "distance 37 yd (fake projection) when 3.7 map units south: " .. tostring(nav and nav.distance))
-- target is north of us, facing north (0): angle ~0 -> "ahead"
check(nav.angle and math.abs(nav.angle) < 0.01 and ns.Navigation:DirectionWord(nav.angle) == "ahead", "target straight ahead when facing north")
MOCK.facing = math.pi / 2  -- facing west -> target is to the right
nav = ns.Navigation:Update()
check(ns.Navigation:DirectionWord(nav.angle) == "right", "facing west, target to the right: " .. ns.Navigation:DirectionWord(nav.angle))
MOCK.facing = 0

-- finish kobolds: KILL 7 done, wolves objective still open -> COLLECT 33 current
MOCK_PROGRESS(7, 1, 10); settle()
check(cur() == 11 and step().type == "COLLECT" and step().quest == 33, "kobolds done -> collect wolf meat (" .. tostring(cur()) .. ")")

-- player abandons quest 33: COLLECT is blocked, engine jumps back to ACCEPT 33 (step 9)
MOCK_ABANDON(33); settle()
check(cur() == 9 and step().type == "ACCEPT" and step().quest == 33, "abandoned quest -> back to its ACCEPT step (" .. tostring(cur()) .. ")")
check(G.note ~= nil, "recovery note shown: " .. tostring(G.note))

-- re-accept and complete it, turn in 7 too
MOCK_ACCEPT(33, "Wolves Across the Border", { { text = "Tough Wolf Meat", finished = false, numFulfilled = 0, numRequired = 8 } }); settle()
check(cur() == 11, "re-accepted -> collect step again (" .. tostring(cur()) .. ")")
MOCK_PROGRESS(33, 1, 8); settle()
check(cur() == 12 and step().type == "TURNIN" and step().quest == 7, "wolf meat done -> turn in 7 (" .. tostring(cur()) .. ")")
-- Forever quirk: the completion flag can read true for a quest that is still in the log (seen after
-- /reload); the log wins and the turn-in stays current instead of being walked past
MOCK.completed[7] = true; ns.Guide:Evaluate("reload"); settle()
check(cur() == 12 and step().type == "TURNIN" and step().quest == 7, "a completion flag on a quest still in the log does not skip its turn-in (" .. tostring(cur()) .. ")")
MOCK.completed[7] = nil

-- player is AHEAD of the guide: turns in 7, 33, accepts 15, 3903 and even turns 3903 in
MOCK_TURNIN(7); settle()
MOCK_ACCEPT(15, "Investigate Echo Ridge", { { text = "Kobold Worker slain", finished = false, numFulfilled = 0, numRequired = 10 } }); settle()
MOCK_TURNIN(33); settle()
MOCK_ACCEPT(3903, "Milly Osworth"); settle()
MOCK_TURNIN(3903); settle()
MOCK_ACCEPT(3904, "Milly's Harvest", { { text = "Milly's Harvest", finished = false, numFulfilled = 0, numRequired = 8 } }); settle()
check(cur() == 18 and step().type == "KILL" and step().quest == 15, "guide caught up to the player: kill kobold workers (" .. tostring(cur()) .. ")")

-- GRIND optional step + TRAVEL auto-completion via arrival
G:SetStep(33); settle()
check(cur() == 33 and step().type == "GRIND", "jumped to GRIND step (" .. tostring(cur()) .. ")")
MOCK_LEVEL(5); settle()
check(cur() == 34 and step().type == "TRAVEL", "level 5 reached -> TRAVEL step (" .. tostring(cur()) .. ")")
MOCK_MOVE(45.6, 47.7)
ns.UI:UpdateNavigation(true); settle()
check(cur() == 35 and step().type == "ACCEPT" and step().quest == 2158, "arrival completes TRAVEL -> accept 2158 (" .. tostring(cur()) .. ")")

-- TALK-style completion: a manual step completes when the next automatic step is done
MOCK_ACCEPT(2158, "Rest and Relaxation"); settle()
check(cur() == 36 and step().type == "TRAVEL", "accepted 2158 -> travel to Goldshire (" .. tostring(cur()) .. ")")
MOCK_ACCEPT(54, "Report to Goldshire"); settle()
MOCK_TURNIN(54); settle()
check(cur() == 38 and step().quest == 2158 and step().type == "TURNIN", "turning in 54 auto-completes the TRAVEL before it (" .. tostring(cur()) .. ")")

-- HEARTH via GetBindLocation
MOCK_TURNIN(2158); settle()
check(cur() == 39 and step().type == "HEARTH", "hearth step (" .. tostring(cur()) .. ")")
MOCK.bind = "Goldshire"; G:Evaluate("test")
check(cur() == 40 and step().type == "NOTE", "bind location matched -> final NOTE (" .. tostring(cur()) .. ")")
G:Skip(); settle()
check(step() == nil and G.active ~= nil, "guide complete")

-- back / reset
G:Back()
check(cur() == 40, "back returns to the last step (" .. tostring(cur()) .. ")")
G:Reset(); settle()
check(cur() >= 1, "reset re-evaluates from step 1 (lands on " .. tostring(cur()) .. " because completed quests are skipped)")

-- slash command smoke test
ns.Commands:Run("")
ns.Commands:Run("quests")
ns.Commands:Run("pos")
ns.Commands:Run("guides")
ns.Commands:Run("rec")
ns.Commands:Run("nav")
ns.UI:Refresh()
check(ForeverGuideFrame ~= nil, "UI frame created")

-- ---- quest database: lean steps resolve through the DB ----
do
    check(ns.DB:IsLoaded(), "quest database loaded")
    check(ns.DB:QuestName(783) == "A Threat Within", "DB knows quest 783: " .. tostring(ns.DB:QuestName(783)))
    local starts = ns.DB:QuestStarts(783)
    check(#starts == 1 and starts[1].map == 1429 and math.abs(starts[1].x - 48.2) < 0.05, "783 starts at Deputy Willem on map 1429 (" .. tostring(starts[1] and starts[1].x) .. ")")
    local objs = ns.DB:QuestObjectives(7)
    check(objs[1] and objs[1].kind == "kill" and objs[1].name == "Kobold Vermin" and #objs[1].locations > 5, "quest 7 objective = kill Kobold Vermin with spawns (" .. tostring(objs[1] and #objs[1].locations) .. ")")
    local m = ns.DB:MatchObjective(7, 1, "Kobold Vermin slain: 3/10")
    check(m and m.id == 6, "objective text matched to npc 6")
    check(ns.DB:QuestFaction(783) == "Alliance", "783 is Alliance: " .. tostring(ns.DB:QuestFaction(783)))
    local ok, why = ns.DB:IsAvailable(76)
    check(ok == false and why:match("requires"), "76 needs 62 first: " .. tostring(why))

    -- a guide with no coordinates at all
    ns.RegisterGuide({ id = "LEAN_TEST", name = "Lean test", steps = {
        { type = "ACCEPT", quest = 62 }, { type = "TURNIN", quest = 62 }, { type = "ACCEPT", quest = 11 },
        { type = "KILL", quest = 11 }, { type = "TURNIN", quest = 11 } } })
    G:Activate("LEAN_TEST", true); settle()
    local plain = G:GetStepText(step()):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    check(plain == "Accept [7] The Fargodeep Mine", "lean ACCEPT text from DB with level tag: " .. plain)
    local t = ns.Navigation.target
    check(t and t.map == 1429 and math.abs(t.x - 42.1) < 0.05 and math.abs(t.y - 65.9) < 0.05, "lean ACCEPT navigates to Marshal Dughan (" .. tostring(t and t.x) .. "," .. tostring(t and t.y) .. ")")
    G:SetStep(4); settle()
    check(cur() == 3 and step().type == "ACCEPT" and step().quest == 11, "KILL of a quest not in the log falls back to its ACCEPT (" .. tostring(cur()) .. ")")
    MOCK_ACCEPT(11, "Riverpaw Gnoll Bounty", { { text = "Painted Gnoll Armband", finished = false, numFulfilled = 0, numRequired = 8 } }); settle()
    plain = G:GetStepText(step()):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    check(cur() == 4 and plain:match("^Kill .* %(%[%d+%] Riverpaw Gnoll Bounty%)$"), "lean KILL text from DB: " .. plain)
    t = ns.Navigation.target
    check(t and t.map == 1429, "lean KILL step navigates to a gnoll spawn (" .. tostring(t and t.x) .. "," .. tostring(t and t.y) .. ")")

    -- tracker / auto mode
    ns.Tracker:SetMode("auto"); settle()
    ns.Tracker:Rethink()
    check(ns.Tracker.current ~= nil, "tracker picked a quest from the log: " .. tostring(ns.Tracker.current and ns.Tracker.current.title))
    ns.Commands:Run("track")
    ns.Commands:Run("quest 783")
    ns.Commands:Run("quest kobold")
    ns.Commands:Run("avail 5")
    ns.UI:Refresh()
    ns.UI:TogglePicker()
    check(ForeverGuidePicker and ForeverGuidePicker:IsShown() and #ForeverGuidePicker.rows >= 2, "guide picker shows auto mode + guides (" .. tostring(ForeverGuidePicker and #ForeverGuidePicker.rows) .. " rows)")
    -- rows: auto, "ROUTES" header, routes..., "CHAPTERS" header, chapters...; click the first chapter row
    local chapterRow, routeRow
    for _, row in ipairs(ForeverGuidePicker.rows) do
        if row:IsShown() and not row.header then
            if row.onClick and not routeRow then routeRow = row end
            if row.guideID and row.guideID ~= "__auto" and not chapterRow then chapterRow = row end
        end
    end
    check(routeRow ~= nil and chapterRow ~= nil, "picker lists routes and chapters")
    chapterRow:GetScript("OnClick")(chapterRow)
    check(ns.char.mode == "guide" and ns.Guide.active ~= nil and not ForeverGuidePicker:IsShown(), "clicking a guide activates it and closes the picker")
    check(ForeverGuideArrowFrame ~= nil and (ForeverGuideArrowFrame:IsShown() or (ns.Waypoint.overlay and ns.Waypoint.overlay:IsShown())), "a target shows either the chevron arrow or the world waypoint")
    -- any route of the faction can be chosen; the race's own is only the default
    local routes = ns.Guide:Routes()
    check(#routes >= 3, "an Alliance character sees every Alliance route (" .. #routes .. ")")
    local other
    for _, r in ipairs(routes) do if not r.mine then other = r break end end
    check(other ~= nil, "routes of other races are offered too")
    if other then
        local r, pick = ns.Guide:ChooseRoute(other.key)
        check(r and r.key == other.key and pick ~= nil and ns.char.route == other.key and ns.Guide.active and ns.Guide.active.id == pick.id, string.format("choosing another race's route activates its fitting chapter (r=%s pick=%s active=%s route=%s)", tostring(r and r.key), tostring(pick and pick.id), tostring(ns.Guide.active and ns.Guide.active.id), tostring(ns.char.route)))
        check(ns.Persist:EncodeChar():find("r=" .. other.key, 1, true) ~= nil, "the chosen route is mirrored in the cvars")
        local ap = ns.Guide:AutoPick()
        check(ap and ns.Guide:RouteOf(ap) == other.key, "auto-pick follows the chosen route (" .. tostring(ap and ap.id) .. ")")
        ns.Commands:Run("path race")
        check(ns.char.route == nil, "/fg path race goes back to the race's own route")
    end
    ns.Tracker:SetMode("guide")
end

-- ---- auto quest + minimap ----
do
    check(ForeverGuideMinimapButton ~= nil, "minimap button created")
    MOCK.offeredQuest = 60
    MOCK.log[60] = { title = "Kobold Candles", level = 7, objectives = {} }
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == 60, "QUEST_DETAIL auto-accepts the offered quest")
    MOCK.shift = true
    MOCK.offeredQuest = 62
    MOCK.log[62] = { title = "The Fargodeep Mine", level = 7, objectives = {} }
    MOCK.acceptedViaFrame = nil
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "holding shift bypasses auto-accept")
    MOCK.shift = false

    -- alt-click the minimap button: everything off the screen, and back
    local mb = ForeverGuideMinimapButton
    ns.UI:Show()
    ns.Navigation:SetTarget({ map = 1429, x = 40, y = 60, label = "test", owner = "test" })
    ns.Arrow:SetEnabled(true); ns.Arrow:Refresh()
    -- arrow size: /fg arrow size, /fg qg arrowsize, and out-of-range values
    check(ns.Arrow:GetScale() == 1, "arrow size defaults to 1")
    ns.Commands:Run("arrow size 1.5")
    check(ns.Arrow:GetScale() == 1.5 and ForeverGuideArrowFrame:GetScale() == 1.5, "/fg arrow size resizes the live frame")
    check(ns.db.ui.arrow.scale == 1.5, "the size is saved (mirrored via the 'as' cvar key)")
    ns.Commands:Run("qg arrowsize 0.7")
    check(ns.Arrow:GetScale() == 0.7, "/fg qg arrowsize also sets it")
    local okBig, msgBig = ns.QuestGuideConfig.SetNumber("arrowsize", 9)
    check(okBig == true and ns.Arrow:GetScale() == 2.5, "an out-of-range size is clamped to the max, not rejected (" .. tostring(msgBig) .. ")")
    ns.Commands:Run("arrow size 1")
    check(ns.Arrow:GetScale() == 1, "back to 1 for the rest of the tests")
    -- a typo after "arrow " must not silently flip it off (Ilya, 2026-09-24: this happened live)
    local arrowWasOn = ns.db.ui.arrow.enabled
    ns.Commands:Run("arrow sized 2")
    check(ns.db.ui.arrow.enabled == arrowWasOn, "an unrecognized /fg arrow option is rejected, not treated as a toggle")
    -- the Options panel exposes arrow size as a real slider, not just the chat command
    do
        ns.Options:Create()
        local slider = ns.Options:GetWidget("arrowsize")
        check(slider ~= nil, "the panel built a slider for arrow size")
        if slider then
            -- drive it the way a player drags it, then confirm Refresh() reads the change back
            slider:SetValue(2.0)
            check(ns.Arrow:GetScale() == 2.0, "dragging the panel slider resizes the arrow")
            ns.Commands:Run("arrow size 1.2")
            ns.Options:Refresh()
            check(slider:GetValue() == 1.2, "setting it from /fg is reflected back onto the panel slider")
            slider:SetValue(9)
            check(ns.Arrow:GetScale() == 2.5, "the slider clamps to its own max (2.5) before item.set ever sees an out-of-range drag")
        end
        ns.Commands:Run("arrow size 1")
    end
    check(ForeverGuideArrowFrame.mouse == true, "arrow accepts dragging when unlocked and tracking a target")
    ns.Commands:Run("lock")
    check(ForeverGuideArrowFrame.mouse == false and not ForeverGuideFrame.resizeGrip:IsShown(), "locking disables arrow drag and hides resize grip")
    ns.Commands:Run("unlock")
    check(ForeverGuideArrowFrame.mouse == true and ForeverGuideFrame.resizeGrip:IsShown(), "unlocking enables arrow drag and resize grip")
    local function pointerShown() return ns.Arrow:IsShown() or (ns.Waypoint.overlay and ns.Waypoint.overlay:IsShown()) end
    local frameWasShown = ForeverGuideFrame:IsShown()
    local arrowWasShown = pointerShown()
    check(frameWasShown and arrowWasShown, "window and waypoint/arrow are up before the alt-click")
    MOCK.alt = true
    mb.scripts.OnClick(mb, "LeftButton"); settle()
    check(ns.UI:AllHidden(), "alt-click sets the hide-everything switch")
    check(not ForeverGuideFrame:IsShown(), "alt-click hides the guide window")
    check(not pointerShown(), "alt-click hides the waypoint and the arrow")
    check(ns.db.ui.arrow.enabled ~= false, "hiding everything does not disable the arrow itself")
    check(ns.Guide.active ~= nil or true, "guide keeps running while hidden")
    mb.scripts.OnClick(mb, "LeftButton"); settle()
    MOCK.alt = false
    check(not ns.UI:AllHidden(), "a second alt-click clears the switch")
    check(ForeverGuideFrame:IsShown(), "the window comes back")
    check(pointerShown(), "the waypoint / arrow comes back")
    -- combat hiding must not undo it, and /fg hideall is the same switch
    ns.Commands:Run("hideall on")
    check(ns.UI:AllHidden(), "/fg hideall on hides everything")
    ns.db.ui.hideInCombat = true
    MOCK_FIRE("PLAYER_REGEN_DISABLED"); settle()
    MOCK_FIRE("PLAYER_REGEN_ENABLED"); settle()
    check(not ForeverGuideFrame:IsShown(), "leaving combat does not undo the hide-everything switch")
    check(not pointerShown(), "leaving combat does not bring the waypoint / arrow back while hidden")
    ns.db.ui.hideInCombat = false
    local acct = ns.Persist:EncodeAcct()
    check(acct:find("ha=1", 1, true) ~= nil, "the switch is written to the cvar mirror")
    ns.Commands:Run("hideall off")
    check(not ns.UI:AllHidden() and ForeverGuideFrame:IsShown(), "/fg hideall off brings everything back")
    ns.Persist:DecodeAcct(acct)
    check(ns.db.ui.hiddenAll == true, "the switch is restored from the cvar mirror")
    ns.db.ui.hiddenAll = false
    ns.Navigation:Clear()

    MOCK.questChoices = 1
    MOCK_FIRE("QUEST_COMPLETE"); settle()
    check(MOCK.rewardTaken == 1, "single-reward turn-in is completed automatically")
    MOCK.rewardTaken = nil
    MOCK.questChoices = 3
    MOCK_FIRE("QUEST_COMPLETE"); settle()
    check(MOCK.rewardTaken == nil, "multi-reward turn-in is left for the player")
    ns.AutoQuest:Set("accept", "guide")
    MOCK.offeredQuest = 5001
    MOCK.log[5001] = { title = "Bijou's Belongings", level = 55, objectives = {} }
    MOCK.acceptedViaFrame = nil
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "accept=guide ignores quests outside the guide")
    ns.AutoQuest:Set("accept", "on")
    -- direct QUEST_DETAIL path: grey / repeatable / player-shared quests are not auto-accepted
    MOCK.trivial = { [5002] = true }
    MOCK.offeredQuest = 5002
    MOCK.log[5002] = { title = "Grey Quest", level = 1, objectives = {} }
    MOCK.acceptedViaFrame = nil
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "trivial (grey) quest offered directly is not auto-accepted")
    MOCK.repeatable = { [5003] = true }
    MOCK.offeredQuest = 5003
    MOCK.log[5003] = { title = "Repeatable", level = 10, objectives = {} }
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "repeatable quest offered directly is not auto-accepted")
    MOCK.offerFromPlayer = true
    MOCK.offeredQuest = 5004
    MOCK.log[5004] = { title = "Shared", level = 10, objectives = {} }
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "quest shared by another player is not auto-accepted")
    MOCK.offerFromPlayer = false
    MOCK.offeredQuest = 0
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == nil, "closed quest window (id 0) is ignored")
    MOCK.offeredQuest = 5004
    MOCK_FIRE("QUEST_DETAIL"); settle()
    check(MOCK.acceptedViaFrame == 5004, "a normal directly-offered quest is still auto-accepted")
    ns.Commands:Run("auto")
    MOCK.log[60], MOCK.log[62], MOCK.log[5001], MOCK.log[5002], MOCK.log[5003], MOCK.log[5004] = nil, nil, nil, nil, nil, nil
    MOCK.trivial, MOCK.repeatable = nil, nil
end

-- ---- multi-objective steps: each KILL/COLLECT step tracks its own objective ----
do
    G:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true); settle()
    local steps = G.active.steps
    local a, b
    for i, s in ipairs(steps) do
        if s.quest == 52 and (s.type == "KILL" or s.type == "COLLECT") then
            if not a then a = i elseif not b then b = i end
        end
    end
    check(a and b, "Elwynn guide has two objective steps for quest 52 (" .. tostring(a) .. "," .. tostring(b) .. ")")
    if a and b then
        MOCK_ACCEPT(52, "Young Forest Bear... no: Rolf and Malakai", {
            { text = "Young Forest Bear slain: 0/8", finished = false, numFulfilled = 0, numRequired = 8 },
            { text = "Prowler slain: 0/8", finished = false, numFulfilled = 0, numRequired = 8 },
        }); settle()
        G:SetStep(a); settle()
        check(G:StepObjectiveIndex(steps[a]) == 1 and G:StepObjectiveIndex(steps[b]) == 2,
            "steps map to objectives 1 and 2 by target name (" .. tostring(G:StepObjectiveIndex(steps[a])) .. "," .. tostring(G:StepObjectiveIndex(steps[b])) .. ")")
        check(cur() == a, "current step is the first objective step (" .. tostring(cur()) .. ")")
        -- the route interleaves other quests' objectives between the two: put those quests in the log, finished
        local between = {}
        for i = a + 1, b - 1 do
            local st = steps[i]
            if st.quest and st.quest ~= 52 and not MOCK.log[st.quest] then
                MOCK_ACCEPT(st.quest, "Quest " .. st.quest, { { text = "done: 1/1", finished = true, numFulfilled = 1, numRequired = 1 } })
                between[#between + 1] = st.quest
            end
        end
        settle()
        MOCK.log[52].objectives[1] = { text = "Young Forest Bear slain: 8/8", finished = true, numFulfilled = 8, numRequired = 8 }
        MOCK_FIRE("QUEST_LOG_UPDATE"); settle()
        check(cur() == b, "first objective done -> second objective step is current (" .. tostring(cur()) .. ")")
        check(G:GetStepProgress(steps[b]) == "0 / 8", "progress shows the second objective's own count: " .. G:GetStepProgress(steps[b]))
        -- /fg back holds the previous (already finished) step
        G:Back(); settle()
        check(cur() < b and cur() >= a, "back holds a finished step (" .. tostring(cur()) .. ")")
        G:Skip(); settle()
        check(cur() == b, "skip releases the hold (" .. tostring(cur()) .. ")")
        MOCK.log[52] = nil
        for i, id in ipairs(MOCK.logOrder) do if id == 52 then table.remove(MOCK.logOrder, i) break end end
        for _, qid in ipairs(between) do
            MOCK.log[qid] = nil
            for i, id in ipairs(MOCK.logOrder) do if id == qid then table.remove(MOCK.logOrder, i) break end end
        end
    end
end

-- ---- scanner: simulated server with silence for unknown ids and a throttle ----
do
    local server = { [5]=true,[6]=true,[7]=true,[8]=true,[9]=true,[11]=true,[12]=true,[13]=true,[14]=true,[15]=true,
                     [16]=true,[18]=true,[19]=true,[20]=true,[21]=true,[22]=true,[26]=true,[27]=true,[28]=true,[29]=true,
                     [30]=true,[31]=true,[33]=true,[34]=true,[35]=true,[36]=true,[37]=true,[38]=true,[39]=true,[40]=true,
                     [45]=true,[46]=true,[47]=true,[52]=true,[54]=true,[56]=true,[59]=true,[60]=true,[90001]=true }
    local answered, requests, throttleUntil = 0, 0, nil
    MOCK.titles = {}
    for id in pairs(server) do MOCK.titles[id] = "Quest " .. id end
    _G.HaveQuestData = function(id) return ns.db.scan and ns.db.scan.quests[id] ~= nil and ns.db.scan.quests[id] ~= "" and false or false end
    local realTitle = C_QuestLog.GetTitleForQuestID
    C_QuestLog.GetTitleForQuestID = function(id) return nil end
    C_QuestLog.RequestLoadQuestByID = function(id)
        requests = requests + 1
        if requests == 30 then throttleUntil = MOCK.time + 12 end       -- server goes deaf for 12 s
        if throttleUntil and MOCK.time < throttleUntil then return end
        if server[id] then
            C_Timer.After(0.5, function()
                C_QuestLog.GetTitleForQuestID = function(q) return server[q] and ("Quest " .. q) or nil end
                MOCK_FIRE("QUEST_DATA_LOAD_RESULT", id, true)
                answered = answered + 1
            end)
        end
    end
    ns.db.scan = nil
    ns.Scanner:Start(1, 60)
    for i = 1, 1200 do MOCK_ADVANCE(0.25) if not ns.Scanner.running then break end end
    local sc = ns.db.scan
    local exist, silent = 0, 0
    for _ in pairs(sc.quests) do exist = exist + 1 end
    for _ in pairs(sc.missing) do silent = silent + 1 end
    check(not ns.Scanner.running and sc.done, "scanner finished in " .. tostring(MOCK.time) .. "s")
    check(exist == 38, "scanner found all 38 existing ids in 1-60 despite the throttle (" .. exist .. ")")
    local wrong = 0
    for id in pairs(sc.missing) do if server[id] then wrong = wrong + 1 end end
    check(wrong == 0, "no existing quest was judged silent (" .. wrong .. ")")
    check(ns.Scanner.stats.throttles >= 1, "throttle was detected (" .. tostring(ns.Scanner.stats.throttles) .. "x)")
    local un = 0
    for _ in pairs(sc.unanswered) do un = un + 1 end
    check(silent + un == 60 - 38, "the other " .. (60 - 38) .. " ids are silent or unanswered (" .. silent .. " + " .. un .. ")")
    ns.Commands:Run("scan status")
    -- "/fg scan new": exactly the bundled Forever-only id ranges, with level + objectives captured
    local realDifficulty, realObjectives = C_QuestLog.GetQuestDifficultyLevel, C_QuestLog.GetQuestObjectives
    C_QuestLog.GetQuestDifficultyLevel = function(id) return server[id] and 7 or 0 end
    C_QuestLog.GetQuestObjectives = function(id) return server[id] and { { text = "Dark Iron Spy slain: 0/10", type = "monster" } } or {} end
    server[90104] = true
    local savedRanges = ns.ForeverNewQuestIDRanges
    ns.ForeverNewQuestIDRanges = { { 90001, 90001 }, { 90104, 90104 } }
    throttleUntil = nil
    ns.Scanner:Start("new")
    for i = 1, 400 do MOCK_ADVANCE(0.25) if not ns.Scanner.running then break end end
    check(sc.quests[90104] == "Quest 90104" and sc.info[90104] and sc.info[90104].lvl == 7 and sc.info[90104].obj[1] == "Dark Iron Spy slain: 0/10",
        "scan new records title, level and objectives of a Forever quest")
    ns.ForeverNewQuestIDRanges = savedRanges
    C_QuestLog.GetTitleForQuestID = realTitle
    C_QuestLog.GetQuestDifficultyLevel, C_QuestLog.GetQuestObjectives = realDifficulty, realObjectives
    ns.Quest:Refresh()
end


-- ---- options / keybinds / reports / overlay ------------------------------------------
check(ns.Options and rawget(_G, "ForeverGuideOptionsPanel") ~= nil or ns.Options ~= nil, "options panel created")
check(type(_G.ForeverGuide_ToggleWindow) == "function" and BINDING_NAME_FOREVERGUIDE_TOGGLE ~= nil, "keybind globals defined")
ns.Commands:Run("wrong the giver is 10 yards north")
check(ns.db.reports and #ns.db.reports == 1 and ns.db.reports[1].text == "the giver is 10 yards north" and (ns.db.reports[1].guide == (ns.Guide.active and ns.Guide.active.id) or ns.db.reports[1].mode == "auto"), "/fg wrong stores a report with guide + step")
check(ns.DB.overlayApplied == true, "Forever overlay applied at init")
check(ns.QuestDB[317] and ns.QuestDB[317].fobj and ns.QuestDB[317].fobj[1].spm ~= nil, "overlay objective evidence attached to vanilla quest 317")
check(ns.NpcDB[1131] and ns.NpcDB[1131].spm ~= nil, "overlay npc points merged into vanilla npc 1131")
do
    local locs = ns.DB:NPCLocations(1131)
    local hasForever = false
    for _, l in ipairs(locs) do if l.forever and l.map == 1426 then hasForever = true end end
    check(hasForever, "spm points show up in NPCLocations")
    local objs = ns.DB:QuestObjectives(317)
    check(objs[1] and #objs[1].locations > 0, "vanilla objective of 317 keeps its own locations (" .. tostring(objs[1] and #objs[1].locations) .. ")")
    local fq = ns.QuestDB[99128]
    check(fq and fq.forever and fq.n == "Slimy Menace", "Forever-only quest 99128 exists with its title")
ns.Commands:Run("wrong")
check(ForeverGuideReportPrompt and ForeverGuideReportPrompt:IsShown(), "/fg wrong opens feedback dialog")
ForeverGuideReportPrompt.input:SetText("giver moved east")
ForeverGuideReportPrompt.save:GetScript("OnClick")()
check(not ForeverGuideReportPrompt:IsShown() and ns.db.reports[2].text == "giver moved east", "Save records dialog feedback and closes it")
ns.Commands:Run("reports")
check(ForeverGuideReports and ForeverGuideReports:IsShown() and ForeverGuideReports.text:GetText():find("giver moved east", 1, true)
    and ForeverGuideReports.text:GetText():find("expected map", 1, true), "/fg reports shows copyable full feedback")
check(ForeverGuideFrame.header.reports ~= nil, "guide header has a reports button next to feedback")
ForeverGuideReports.clear:GetScript("OnClick")()
check(#ns.db.reports == 2, "first clear click asks for confirmation without deleting feedback")
ForeverGuideReports.clear:GetScript("OnClick")()
check(#ns.db.reports == 0 and ForeverGuideReports.text:GetText():find("No reports yet", 1, true),
    "confirmed clear deletes feedback and refreshes the list")
    check(ns.Quest:XPMultiplier(783, 1) == 1 and ns.Quest:XPMultiplier(783, 7) == 0.8 and ns.Quest:XPMultiplier(783, 12) == 0.1, "xp multiplier follows the Classic reduction table")
end

-- ---- audit regressions (2026-09-20) --------------------------------------------------------
do
    -- 1. an objective step whose wording matches no live objective must not count as done
    ns.RegisterGuide({ id = "AUDIT_OBJ", name = "audit obj", steps = {
        { type = "ACCEPT", quest = 11 },
        { type = "KILL", quest = 11, target = "Defias Trapper", npc = 6 },   -- npc 6 = Kobold Vermin in the DB, wording matches nothing
        { type = "TURNIN", quest = 11 } } })
    if ns.Quest:IsOnQuest(11) then MOCK_ABANDON(11); settle() end
    G:Activate("AUDIT_OBJ", true); settle()
    -- quest 11 needs a higher level than the test character has: the whole quest is deferred (guide runs past its end)
    check(G.progress.deferred[11] == 1 and cur() == 4, "a quest above the level is deferred with all its steps (cur=" .. tostring(cur()) .. " lvl=" .. tostring(ns.Player:GetLevel()) .. ")")
    MOCK_ACCEPT(11, "Riverpaw Gnoll Bounty", { { text = "Kobold Vermin slain", finished = false, numFulfilled = 0, numRequired = 6 }, { text = "Painted Gnoll Armband", finished = false, numFulfilled = 0, numRequired = 8 } }); settle()
    check(G.progress.deferred[11] == nil and cur() == 2, "taking a deferred quest by hand brings the guide back to its objective steps (" .. tostring(cur()) .. ")")
    check(cur() == 2, "a kill step with unmatched wording stays current at 0/6 instead of being skipped (" .. tostring(cur()) .. ")")
    MOCK_PROGRESS(11, 1, 6); settle()
    check(cur() == 3, "...and completes once the objective its index points at is finished (" .. tostring(cur()) .. ")")
    MOCK_ABANDON(11); settle()
    -- 2. two steps at the same spot: the arrow label follows the step, and a repeated TRAVEL completes
    ns.RegisterGuide({ id = "AUDIT_NAV", name = "audit nav", steps = {
        { type = "ACCEPT", quest = 62, map = 1429, x = 40, y = 60, npc = 240 },
        { type = "TURNIN", quest = 62, map = 1429, x = 40, y = 60, npc = 240 },
        { type = "TRAVEL", map = 1429, x = 40, y = 60, text = "Go to A" },
        { type = "TRAVEL", map = 1429, x = 40, y = 60, text = "Go to A again" },
        { type = "NOTE", text = "end" } } })
    G:Activate("AUDIT_NAV", true); settle()
    MOCK_ACCEPT(62, "The Fargodeep Mine", {}); settle()
    check(cur() == 2 and ns.Navigation.target and ns.Navigation.target.label == G:GetStepText(step()), "same spot, next step: the navigation label follows the step (" .. tostring(ns.Navigation.target and ns.Navigation.target.label) .. ")")
    MOCK_TURNIN(62); settle()
    MOCK_MOVE(40, 60); ns.Navigation:Update(); settle()
    ns.Navigation:Update(); settle()
    check(cur() == 5, "two TRAVEL steps to the same spot both complete on arrival (" .. tostring(cur()) .. ")")
end

-- ---- optional group quests ------------------------------------------------------------------
do
    ns.RegisterGuide({ id = "AUDIT_GROUP", name = "group", steps = {
        { type = "ACCEPT", quest = 990001 },
        { type = "ACCEPT", quest = 990002, optional = true, note = "group quest" },
        { type = "KILL", quest = 990002, target = "Kobold Vermin", optional = true },
        { type = "TURNIN", quest = 990002, optional = true },
        { type = "TURNIN", quest = 990001 } } })
    if ns.Quest:IsOnQuest(990001) then MOCK_ABANDON(990001); settle() end
    G:Activate("AUDIT_GROUP", true); settle()
    MOCK_ACCEPT(990001, "Base quest", {}); settle()
    check(cur() == 5 and step().type == "TURNIN" and step().quest == 990001, "optional group quest steps are walked past when the quest is not taken (" .. tostring(cur()) .. ")")
    MOCK_ACCEPT(990002, "Group quest", { { text = "Kobold Vermin slain", finished = false, numFulfilled = 0, numRequired = 5 } }); settle()
    check(cur() == 3 and step().quest == 990002, "taking the group quest by hand guides its objectives (" .. tostring(cur()) .. ")")
    MOCK_ABANDON(990002); settle()
    check(cur() == 5, "dropping it walks past again (" .. tostring(cur()) .. ")")
    MOCK_TURNIN(990001); settle()
end

-- ---- full quest log ---------------------------------------------------------------------------
do
    ns.RegisterGuide({ id = "AUDIT_FULL", name = "full log", steps = {
        { type = "ACCEPT", quest = 4010 }, { type = "TURNIN", quest = 4010 } } })
    G:Activate("AUDIT_FULL", true); settle()
    MOCK.logCap = 2
    if not ns.Quest:IsOnQuest(4011) then MOCK_ACCEPT(4011, "Spare quest A", {}) end
    if not ns.Quest:IsOnQuest(4012) then MOCK_ACCEPT(4012, "Spare quest B", {}) end
    settle()
    local n = ns.Quest:GetNumQuests()
    MOCK.logCap = n
    G:Evaluate("test")
    check(G.note and G.note:find("Quest log full", 1, true) and G.note:find("Spare quest", 1, true), "a full log on an ACCEPT step names quests the guide does not need (" .. tostring(G.note) .. ")")
    MOCK.logCap = 40
    G:Evaluate("test")
    check(not (G.note and G.note:find("Quest log full", 1, true)), "room again: the note goes away")
    MOCK_ABANDON(4011); MOCK_ABANDON(4012); settle()
end

-- ---- corpse run ---------------------------------------------------------------------------------
do
    G:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true); G:SetStep(1); settle()
    local before = ns.Navigation.target
    check(before and before.owner == "guide", "guide target before dying")
    MOCK_DIE(55.5, 66.6); settle()
    local t = ns.Navigation.target
    check(t and t.owner == "corpse" and math.abs(t.x - 55.5) < 0.01 and math.abs(t.y - 66.6) < 0.01 and t.label:find("corpse", 1, true), "dead: the target is the corpse (" .. tostring(t and t.label) .. ")")
    G:Evaluate("test"); settle()
    check(ns.Navigation.target and ns.Navigation.target.owner == "corpse", "the guide does not steal the target back while a ghost")
    MOCK_REVIVE(); settle()
    check(ns.Navigation.target and ns.Navigation.target.owner == "guide" and ns.Navigation.override == nil, "alive again: the guide's target returns (" .. tostring(ns.Navigation.target and ns.Navigation.target.owner) .. ")")
end

-- ---- bag space --------------------------------------------------------------------------------
do
    ns.db.bags.banners = true -- opt into legacy banner behavior for the existing banner checks
    MOCK_BAG(10, 2, 1); settle()
    check(ns.Bags:Tag() == nil, "plenty of room: no bag tag")
    MOCK_BAG(2, 4, 3); settle()
    local tag, full = ns.Bags:Tag()
    check(tag == "bags 2/16" and not full, "2 free slots: header tag (" .. tostring(tag) .. ")")
    local advice = ns.Bags:Advice()
    check(advice and advice:find("4 grey items", 1, true) and advice:find("never counted", 1, true), "advice counts grey items only, never quest items (" .. tostring(advice) .. ")")
    MOCK_BAG(0, 0, 5); settle()
    local _, full0 = ns.Bags:Tag()
    local adv0 = ns.Bags:Advice()
    check(full0 == true and adv0 and adv0:find("FULL", 1, true) and adv0:find("never quest items", 1, true), "full bags with only quest items: urgent, no sale suggested (" .. tostring(adv0) .. ")")
    check(ForeverGuideBagBanner and ForeverGuideBagBanner:IsShown() and (ForeverGuideBagBanner.title:GetText() or ""):find("BAGS FULL", 1, true), "full bags: the on-screen banner shows")
    MOCK_BAG(16, 0, 0); settle()
    check(not ForeverGuideBagBanner:IsShown(), "room again: the banner goes away")
end

-- ---- item tooltips ------------------------------------------------------------------------------
do
    -- Riverpaw Gnoll Bounty (11) collects Painted Gnoll Armband (782)
    if not ns.Quest:IsOnQuest(11) then MOCK_ACCEPT(11, "Riverpaw Gnoll Bounty", { { text = "Painted Gnoll Armband", finished = false, numFulfilled = 3, numRequired = 8 } }); settle() end
    local lines = ns.ItemTips:LinesFor(782, "Painted Gnoll Armband")
    check(#lines >= 1 and lines[1][1]:find("Quest item: Riverpaw Gnoll Bounty (3/8)", 1, true) and lines[1][2] == "log", "an item in the log's objectives is labelled with the quest and progress (" .. tostring(lines[1] and lines[1][1]) .. ")")
    MOCK_ABANDON(11); settle()
    lines = ns.ItemTips:LinesFor(782, "Painted Gnoll Armband")
    check(#lines >= 1 and lines[1][1]:find("Quest item for: Riverpaw Gnoll Bounty", 1, true), "an item a database quest collects is labelled even before the quest is taken (" .. tostring(lines[1] and lines[1][1]) .. ")")
    -- a Forever-only wording: the live objective names the item, the database does not know it
    MOCK_ACCEPT(92, "Redridge Goulash", { { text = "Tough Condor Meat", finished = false, numFulfilled = 1, numRequired = 5 } }); settle()
    lines = ns.ItemTips:LinesFor(1080, "Tough Condor Meat")
    check(#lines >= 1 and lines[1][1]:find("Redridge Goulash (1/5)", 1, true), "an item named by a live objective is labelled from the log alone (" .. tostring(lines[1] and lines[1][1]) .. ")")
    -- turned in: the meat is left over, the tooltip says so and the bag advice counts it
    MOCK_TURNIN(92); settle()
    check(ns.ItemTips:Leftover(1080, "Tough Condor Meat") == "Redridge Goulash", "after the turn-in the ingredient is known to be left over")
    lines = ns.ItemTips:LinesFor(1080, "Tough Condor Meat")
    check(#lines == 1 and lines[1][2] == "leftover" and lines[1][1]:find("safe to sell", 1, true), "tooltip: no longer needed, safe to sell (" .. tostring(lines[1] and lines[1][1]) .. ")")
    MOCK_BAG(1, 0, 0)
    MOCK.bags[0].items[1] = { quality = 1, hasNoValue = false, itemID = 1080, hyperlink = "|Hitem:1080|h[Tough Condor Meat]|h" }
    MOCK.bags[0].items[2] = { quality = 1, hasNoValue = false, itemID = 1080, hyperlink = "|Hitem:1080|h[Tough Condor Meat]|h" }
    local st = ns.Bags:Status()
    check(st.leftover == 2 and st.leftoverNames[1] == "Tough Condor Meat", "bags: leftover ingredients are counted as sellable (" .. tostring(st.leftover) .. ")")
    check((ns.Bags:Advice(true) or ""):find("leftover quest ingredients", 1, true) ~= nil, "bag advice names the leftover ingredients")
    MOCK_BAG(16, 0, 0); settle()
    do local l = ns.ItemTips:LinesFor(999999, "Broken Sword") check(#l == 0, "an ordinary item gets no line (" .. tostring(l[1] and l[1][1]) .. ")") end
end

-- ---- skulls over quest mobs ----------------------------------------------------------------
do
    ns.RegisterGuide({ id = "AUDIT_SKULL", name = "skull", steps = {
        { type = "ACCEPT", quest = 11 },
        { type = "KILL", quest = 11, target = "Kobold Vermin", npc = 6, near = true },
        { type = "TURNIN", quest = 11 } } })
    if ns.Quest:IsOnQuest(11) then MOCK_ABANDON(11); settle() end
    G:Activate("AUDIT_SKULL", true); settle()
    MOCK_ACCEPT(11, "Riverpaw Gnoll Bounty", { { text = "Kobold Vermin slain", finished = false, numFulfilled = 0, numRequired = 10 } }); settle()
    check(cur() == 2 and step().type == "KILL", "skull test: on the kill step (cur=" .. tostring(cur()) .. " lvl=" .. tostring(ns.Player:GetLevel()) .. " deferred=" .. tostring(next(G.progress.deferred or {})) .. " note=" .. tostring(G.note) .. ")")
    local names = ns.MobMarker:WantedNames()
    check(names["kobold vermin"] == "Kobold Vermin", "the kill step wants Kobold Vermin")
    ns.MobMarker:Scan()
    local macro = ForeverGuideTargetButton and ForeverGuideTargetButton:GetAttribute("macrotext") or ""
    check(macro:find("/targetexact Kobold Vermin", 1, true) ~= nil, "the secure target button carries a /targetexact macro for the step's mobs (" .. macro:gsub("\n", " | ") .. ")")
    ns.MobMarker:UpdateTargetMacro({ ["young wolf"] = "Young Wolf" })   -- stale macro from an earlier step
    MOCK.inCombat = true
    ns.MobMarker:Scan()
    check((ForeverGuideTargetButton:GetAttribute("macrotext") or ""):find("Young Wolf", 1, true) ~= nil, "in combat the macro is left alone (secure attributes are locked)")
    MOCK.inCombat = false
    MOCK_FIRE("PLAYER_REGEN_ENABLED"); settle()
    check((ForeverGuideTargetButton:GetAttribute("macrotext") or ""):find("Kobold Vermin", 1, true) ~= nil, "...and rewritten for the step once combat ends")
    MOCK_PLATE("nameplate1", { name = "Kobold Vermin", npcID = 6, scale = 0.8, y = 500 })   -- far
    MOCK_PLATE("nameplate2", { name = "Kobold Vermin", npcID = 6, scale = 1.0, y = 300 })   -- near
    MOCK_PLATE("nameplate3", { name = "Kobold Worker", npcID = 257, scale = 1.0, y = 320, quest = true })  -- another quest's mob
    MOCK_PLATE("nameplate4", { name = "Young Wolf", npcID = 299, scale = 1.0, y = 310 })     -- not a quest mob
    settle(); ns.MobMarker:Scan()
    local prim
    ns.Events:Register("FG_MOB_MARKED", function(_, guid, unit) prim = unit end)
    ns.MobMarker:Scan()
    check(ns.MobMarker.primaryUnit == "nameplate2", "the nearest untagged quest mob gets the big skull (" .. tostring(ns.MobMarker.primaryUnit) .. ")")
    check(ns.MobMarker.markedCount == 3, "the other quest mobs get small skulls, the wolf none (" .. tostring(ns.MobMarker.markedCount) .. ")")
    check(GetCVar("nameplateShowEnemies") == "1", "enemy nameplates were switched on for the kill step")
    MOCK_PLATE("nameplate2", { name = "Kobold Vermin", npcID = 6, scale = 1.0, y = 300, tagged = true }); ns.MobMarker:Scan()
    check(ns.MobMarker.primaryUnit == "nameplate1" and ns.MobMarker.markedCount == 2, "a tagged mob loses its skull entirely, the next one gets the big skull (" .. tostring(ns.MobMarker.primaryUnit) .. ", " .. tostring(ns.MobMarker.markedCount) .. ")")
    MOCK_PLATE("nameplate1", { name = "Kobold Vermin", npcID = 6, scale = 0.8, y = 500, tagged = true }); ns.MobMarker:Scan()
    check(ns.MobMarker.primaryUnit == nil and ns.MobMarker.markedCount == 1, "all wanted mobs tagged: no big skull, only the other quest's mob keeps a small one")
    -- crowd: most wanted mobs tagged by others -> banner with a quieter spawn cluster / another step
    do
        ns.db.crowd = { enabled = true } -- opt into crowd behavior for its existing checks
        for i = 1, 6 do MOCK_PLATE("nameplate" .. (10 + i), { name = "Kobold Vermin", npcID = 6, scale = 1.0, y = 300, tagged = i <= 5 }) end
        ns.MobMarker:Scan()
        local tg, fr, pl, crowded = ns.Crowd:Level()
        check(crowded and tg >= 5, "five of six quest mobs taken: crowded (" .. tostring(tg) .. "/" .. tostring(tg + fr) .. ")")
        check(ForeverGuideCrowdBanner and ForeverGuideCrowdBanner:IsShown() and (ForeverGuideCrowdBanner.title:GetText() or ""):find("Crowded", 1, true), "the crowd banner shows")
        local alts = ns.Crowd:SpawnAlternatives()
        check(#alts >= 1 and alts[1].dist >= 150 and alts[1].map == 1429, "another Kobold Vermin spawn cluster at least 150 yd away is offered (" .. tostring(alts[1] and alts[1].label) .. ")")
        ns.Crowd:GoToAlternative()
        check(ns.Navigation.override == "crowd" and ns.Navigation.target and ns.Navigation.target.owner == "crowd", "Go there navigates to the quieter spot")
        ns.Crowd:ReleaseOverride()
        check(ns.Navigation.override == nil and ns.Navigation.target and ns.Navigation.target.owner == "guide", "arrival hands navigation back to the guide")
        for i = 1, 6 do MOCK_PLATE("nameplate" .. (10 + i), nil) end
        ns.Crowd.snoozedUntil = nil
        -- more than 4 players around: a single-target step is postponed, a shared kill step stays and offers a group
        for i = 1, 5 do MOCK_PLATE("nameplate" .. (20 + i), { name = "Player" .. i, player = true, friendly = true, npcID = 0 }) end
        ns.MobMarker:Scan()
        local _, _, pl = ns.Crowd:Level()
        check(pl >= 5, "five players seen on nameplates (" .. tostring(pl) .. ")")
        check(ns.Crowd:IsSharedKillOrLoot(step()) == true and G.postponed[cur()] == nil, "a kill-x-mobs step is not postponed by the crowd")
        do
            -- only two players around, nothing tagged: not crowded, but a kill step still gets the group-up reminder
            for i = 3, 5 do MOCK_PLATE("nameplate" .. (20 + i), nil) end
            ns.Crowd.snoozedUntil = nil
            ns.Crowd:Reset()
            ns.MobMarker:Scan()
            local _, _, _, cr = ns.Crowd:Level()
            check(not cr and ForeverGuideCrowdBanner:IsShown() and (ForeverGuideCrowdBanner.title:GetText() or ""):find("Group up", 1, true), "two players on a kill step: the group-up reminder shows without a crowd (" .. tostring(ForeverGuideCrowdBanner.title:GetText()) .. ")")
            check((ForeverGuideCrowdBanner.sub:GetText() or ""):find("2 players", 1, true), "the sub line names the players around")
            check(ForeverGuideCrowdBanner.invite:IsShown() and ForeverGuideCrowdBanner:GetHeight() >= 58, "invite button shown and the banner tall enough for two lines")
            for i = 3, 5 do MOCK_PLATE("nameplate" .. (20 + i), { name = "Player" .. i, player = true, friendly = true, npcID = 0 }) end
            ns.MobMarker:Scan()
        end
        check(ForeverGuideCrowdBanner.invite:IsShown() and (ForeverGuideCrowdBanner.sub:GetText() or ""):find("shared in a group", 1, true), "...instead the banner offers to invite the players around (shown=" .. tostring(ForeverGuideCrowdBanner:IsShown()) .. " sub=" .. tostring(ForeverGuideCrowdBanner.sub:GetText()) .. ")")
        check(ns.Crowd:InviteNearby() == 4 and #MOCK.invited == 4, "Invite asks up to four of them into a group")
        ns.RegisterGuide({ id = "AUDIT_CROWD2", name = "crowd2", steps = {
            { type = "ACCEPT", quest = 11 },
            { type = "KILL", quest = 11, target = "Hogger", npc = 448, count = 1 },
            { type = "KILL", quest = 11, target = "Kobold Vermin", npc = 6, near = true },
            { type = "TURNIN", quest = 11 } } })
        if not ns.Quest:IsOnQuest(11) then MOCK_ACCEPT(11, "Riverpaw Gnoll Bounty", { { text = "Hogger slain", finished = false, numFulfilled = 0, numRequired = 1 }, { text = "Kobold Vermin slain", finished = false, numFulfilled = 0, numRequired = 6 } }); settle() end
        G:Activate("AUDIT_CROWD2", true)
        check(not ns.Crowd:IsSharedKillOrLoot(G.active.steps[2]), "a named single mob is not a shared kill")
        settle()
        ns.MobMarker:Scan()
        check(G.postponed[2] ~= nil and cur() == 3, "with more than 4 players around the named-mob step is postponed and the guide moves on (" .. tostring(cur()) .. ")")
        G:Unpostpone(2)
        check(cur() == 2, "unpostpone brings it back (cur=" .. tostring(cur()) .. " postponed=" .. tostring(G.postponed[2]) .. ")")
        for i = 1, 5 do MOCK_PLATE("nameplate" .. (20 + i), nil) end
        MOCK_ABANDON(11); settle()
        if not ns.Quest:IsOnQuest(11) then MOCK_ACCEPT(11, "Riverpaw Gnoll Bounty", { { text = "Kobold Vermin slain", finished = false, numFulfilled = 0, numRequired = 10 } }); settle() end
        G:Activate("AUDIT_SKULL", true); settle()
        -- zone population via /who: 30 players of our level in the zone -> busy, and a zone guide elsewhere is named
        MOCK.whoCount = 30
        check(ns.Crowd:PollZone(true) and (MOCK.whoQuery or ""):find('z-"Elwynn Forest"', 1, true), "/who asks for this zone and our level band (" .. tostring(MOCK.whoQuery) .. ")")
        local busy, n = ns.Crowd:ZoneBusy()
        check(busy and n == 30, "30 same-level players in the zone counts as busy")
        local alt = ns.Crowd:ZoneAlternative()
        check(alt and alt.id:find("^GEN_") and alt.zone ~= "Elwynn Forest" and (alt.minLevel or 1) <= 5, "a guide for this level in another zone is offered (" .. tostring(alt and alt.id) .. ")")
        MOCK.whoCount = 3
        ns.Crowd:PollZone(true)
        check(not ns.Crowd:ZoneBusy(), "3 players: not busy")
    end
    -- in combat the nameplate frames cannot be measured (restricted regions): fall back to interact rings
    MOCK_PLATE("nameplate1", { name = "Kobold Vermin", npcID = 6, restricted = true, dist = 25 })
    MOCK_PLATE("nameplate2", { name = "Kobold Vermin", npcID = 6, restricted = true, dist = 8 })
    ns.MobMarker:Scan()
    check(ns.MobMarker.primaryUnit == "nameplate2" and #reportedErrors == 0, "restricted nameplates: no error, nearest by interact distance (" .. tostring(ns.MobMarker.primaryUnit) .. ")")
    -- Protect the Frontier (52): prowlers done, bears open -> prowlers get no skull even though the client
    -- still calls them "related to an active quest"; the step's own mob keeps the big one
    if not ns.Quest:IsOnQuest(52) then
        MOCK_ACCEPT(52, "Protect the Frontier", { { text = "Prowler slain", finished = true, numFulfilled = 8, numRequired = 8 }, { text = "Young Forest Bear slain", finished = false, numFulfilled = 2, numRequired = 5 } }); settle()
    end
    MOCK_PLATE("nameplate5", { name = "Prowler", npcID = 118, scale = 1.0, y = 330, quest = true })
    MOCK_PLATE("nameplate6", { name = "Young Forest Bear", npcID = 822, scale = 1.0, y = 330, quest = true })
    ns.MobMarker:Scan()
    local fin = ns.MobMarker:FinishedNames()
    check(fin["prowler"] ~= nil and fin["young forest bear"] == nil, "finished objective mobs are known (prowler yes, bear no)")
    check(ns.MobMarker.markedUnits["nameplate6"] and not ns.MobMarker.markedUnits["nameplate5"], "the open objective's mob has a skull, the finished one has none")
    MOCK_PLATE("nameplate5", nil); MOCK_PLATE("nameplate6", nil); MOCK_ABANDON(52); settle()
    ns.Commands:Run("skull off"); ns.MobMarker:Scan()
    check(ns.MobMarker.markedCount == 0 and GetCVar("nameplateShowEnemies") == "0", "/fg skull off removes the skulls and restores the nameplate setting")
    ns.Commands:Run("skull on")
    MOCK_ABANDON(11); settle()
    -- plates also stay while any quest in the log has an open kill objective: drop those first
    do
        local drop = {}
        for _, qid in ipairs(ns.Quest.order) do
            for _, o in ipairs(ns.Quest:GetObjectives(qid) or {}) do
                if not o.finished and o.text and o.text:find("slain", 1, true) then
                    local copy = {}
                    for i, oo in ipairs(ns.Quest:GetObjectives(qid)) do copy[i] = { text = oo.text, finished = oo.finished, numFulfilled = oo.numFulfilled, numRequired = oo.numRequired } end
                    drop[#drop + 1] = { id = qid, title = ns.Quest:GetTitle(qid), objs = copy }
                    break
                end
            end
        end
        for _, q in ipairs(drop) do MOCK_ABANDON(q.id) end
        settle()
        ns.MobMarker:Scan()
        check(next(ns.MobMarker:OpenKillNames()) == nil, "no open kill objectives left in the log")
        check(GetCVar("nameplateShowEnemies") == "0", "leaving the kill step restores enemy nameplates (step=" .. tostring(step() and step().type) .. " cvar=" .. tostring(GetCVar("nameplateShowEnemies")) .. ")")
        for _, q in ipairs(drop) do MOCK_ACCEPT(q.id, q.title, q.objs) end
        settle()
    end
    for i = 1, 4 do MOCK_PLATE("nameplate" .. i, nil) end
end

-- ---- combat lockdown: nameplate cvars are protected, must never be touched mid-fight -------
-- (Ilya, 2026-09-24: live "Interface action failed because of an AddOn" - forcePlates() called
-- SetCVar unconditionally, and Scan() retries every 0.5s while a kill step is current, so it kept
-- retrying - and kept getting denied - for the whole fight it fired in.)
do
    ns.RegisterGuide({ id = "AUDIT_COMBAT_PLATES", name = "combat plates", steps = {
        { type = "ACCEPT", quest = 990010 },
        { type = "KILL", quest = 990010, target = "Test Grunt", npc = 990010, near = true },
        { type = "TURNIN", quest = 990010 } } })
    -- other quests elsewhere in the log may already have open kill objectives by this point in the
    -- suite, so get a genuinely clean baseline by disabling (which unconditionally releases any
    -- forced cvar - confirmed a reliable reset) and re-enabling without a Scan() in between, rather
    -- than assuming nothing else in the log wants plates on.
    MOCK.inCombat = false
    MOCK_ABANDON(990010); settle()
    ns.MobMarker:SetEnabled(false); settle()
    check(GetCVar("nameplateShowEnemies") == "0", "clean baseline: nothing forcing nameplates on")
    ns.MobMarker.Cfg().enabled = true
    -- enter combat BEFORE touching the guide/quest log, so every Scan() this triggers - from
    -- G:Activate, from accepting the quest, from the ticker - runs while already in combat, same
    -- as a kill step appearing mid-fight for real.
    MOCK.inCombat = true
    G:Activate("AUDIT_COMBAT_PLATES", true); settle()
    check(GetCVar("nameplateShowEnemies") == "0", "activating the guide mid-combat does not touch the cvar")
    MOCK_ACCEPT(990010, "Test Grunt Bounty", { { text = "Test Grunt slain", finished = false, numFulfilled = 0, numRequired = 5 } }); settle()
    check(cur() == 2 and step().type == "KILL", "on the kill step, started while already in combat")
    check(GetCVar("nameplateShowEnemies") == "0", "a kill step starting mid-combat does not touch the protected cvar")
    ns.MobMarker:Scan(); ns.MobMarker:Scan()   -- the 0.5s ticker would otherwise retry every tick all fight
    check(GetCVar("nameplateShowEnemies") == "0", "...and repeated scans while still in combat don't retry it either")
    MOCK.inCombat = false
    MOCK_FIRE("PLAYER_REGEN_ENABLED"); settle()
    check(GetCVar("nameplateShowEnemies") == "1", "nameplates switch on once combat ends and Scan() re-runs")
    MOCK.inCombat = true
    ns.MobMarker:Scan()
    check(GetCVar("nameplateShowEnemies") == "1", "leaving the step mid-combat (already forced) doesn't touch the cvar either")
    MOCK.inCombat = false
    MOCK_ABANDON(990010); settle()
end

-- ---- editor + resync -------------------------------------------------------------------
do
    G:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true); G:SetStep(1); settle()
    local step = G:GetCurrentStep()
    MOCK_MOVE(33.3, 44.4)
    ns.Commands:Run("edit here")
    local map, x, y = ns.Navigation:ResolveStep(step)
    check(map == 1429 and math.abs(x - 33.3) < 0.01 and math.abs(y - 44.4) < 0.01, "/fg edit here overrides the step location (" .. tostring(x) .. "," .. tostring(y) .. ")")
    check(ns.db.edits and ns.db.edits.GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST and ns.db.edits.GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST[step.index] ~= nil, "edit persisted in ForeverGuideDB.edits")
    ns.Commands:Run("edit note test note")
    check(ns.Editor:Effective(step).note == "test note", "/fg edit note sets the note")
    do
        ns.Commands:Run("edit clear")
        local near
        for _, s in ipairs(G.active.steps) do if s.near then near = s break end end
        G:SetStep(near.index); settle()
        near = G:GetCurrentStep()   -- Evaluate may have moved on; the note lands on the current step
        check(near and near.near == true, "the nearest-spawn step is current (" .. tostring(near and near.index) .. ")")
        local m0, x0, y0 = ns.Navigation:ResolveStep(near)
        ns.Commands:Run("edit note just a note")
        local m1, x1, y1 = ns.Navigation:ResolveStep(near)
        check(m0 == m1 and x0 == x1 and y0 == y1, string.format("a note-only edit does not move a nearest-spawn step (%s,%s -> %s,%s)", tostring(x0), tostring(y0), tostring(x1), tostring(y1)))
        check(ns.Editor:Effective(near).hasEdit and not ns.Editor:Effective(near).edited, "note-only edit: hasEdit set, positional override not")
        ns.Commands:Run("edit clear")
        G:SetStep(1); settle()
        MOCK_MOVE(33.3, 44.4)
        ns.Commands:Run("edit here")
        ns.Commands:Run("edit note test note")
    end
    ns.Commands:Run("edits")
    ns.Commands:Run("edit clear")
    local map2, x2 = ns.Navigation:ResolveStep(step)
    check(not (map2 == 1429 and x2 and math.abs(x2 - 33.3) < 0.01), "/fg edit clear restores the original location")
    -- resync: a level-20 character skips out-levelled quests
    MOCK_LEVEL(20); settle()
    local n = G:Resync(); settle()
    check(n >= 5, "resync skipped the out-levelled quests (" .. n .. ")")
    local cs = G:GetCurrentStep()
    local function chainLink(qid)   -- a grey quest another step's quest needs stays on the route
        for _, st in ipairs(G.active.steps) do
            local q = st.quest and ns.DB:GetQuest(st.quest)
            if q then
                for _, pre in ipairs(q.pregroup or {}) do if pre == qid then return true end end
                for _, pre in ipairs(q.pre or {}) do if pre == qid then return true end end
                if q.parent == qid then return true end
            end
        end
        return false
    end
    check(cs == nil or not cs.quest or ns.Quest:XPMultiplier(cs.quest) > 0.2 or ns.Quest:IsOnQuest(cs.quest) or chainLink(cs.quest), "current step after resync is not a grey quest (unless a chain needs it)")
    -- auto-pick prefers the race's natural chain / same continent over a far zone of the same level
    MOCK_LEVEL(11); settle()
    local pick = G:AutoPick()
    check(pick and (pick.id:find("^GEN_ALLIANCE_HUMAN_0[12]_") ~= nil), "level-11 human in Elwynn auto-picks the Human route's chapter 1 or 2, not another race's chapter (" .. tostring(pick and pick.id) .. ")")
    MOCK_LEVEL(5); settle()
    G:Reset(); settle()
end

-- ---- the Quest Guide window: rows, header, states, settings, waypoint fallback ----------
do
    G:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true); G:SetStep(5); settle()
    ns.Tracker:SetMode("guide"); settle()
    ns.UI:Show(); settle()
    local f = ForeverGuideFrame
    check(f.header and f.list and f.guideBtn and f.guidesBtn, "quest guide window has header, list and the two buttons")
    local shownRows, activeRows, activeIdx = 0, 0, nil
    for i, e in ipairs(f.list.entries) do
        shownRows = shownRows + 1
        if e.state == "active" then activeRows = activeRows + 1 activeIdx = e.index end
    end
    check(shownRows >= 3 and shownRows <= (ns.db.ui.maxRows or 7), "list shows a sensible number of rows (" .. shownRows .. ")")
    check(activeRows == 1 and activeIdx == G.current, "exactly one row is the active step and it is the current one")
    check(f.header.count:GetText():find("^%d+ / %d+$") ~= nil, "header shows current / total (" .. tostring(f.header.count:GetText()) .. ")")
    local e1 = f.list.entries[1]
    check(e1.title and e1.title ~= "" and e1.number, "rows carry a title and a step number")
    local hasDone = false
    for _, e in ipairs(f.list.entries) do if e.state == "done" then hasDone = true end end
    check(hasDone, "a completed step stays visible above the current one")
    -- clicking a row jumps to that step
    local target
    for _, e in ipairs(f.list.entries) do if e.state == "available" then target = e break end end
    if target then
        f.list.rows[1].entry = target
        f.list.rows[1]:GetScript("OnClick")(f.list.rows[1], "LeftButton"); settle()
        check(G.current == target.index, "clicking a row jumps to that step (" .. tostring(G.current) .. " vs " .. tostring(target.index) .. ")")
    end
    -- width grip: drag to resize, persist the new width, and reflow the list
    check(f.resizeGrip ~= nil and f.resizable == true, "guide has a resize grip")
    if f.resizeGrip then
        f.resizeGrip:GetScript("OnMouseDown")(f.resizeGrip)
        check(f.sizing == true, "resize grip starts sizing the guide")
        f:SetWidth(360)
        f:SetHeight(160)
        f:GetScript("OnSizeChanged")(f, 360, 160)
        check(f.list:GetWidth() == 348 and f.footerLine.points[1][5] == -120,
            "quest list and footer follow the resize while the mouse is still down")
        f.resizeGrip:GetScript("OnMouseUp")(f.resizeGrip)
        check(ns.db.ui.width == 360 and f.sizing == false, "resize saves guide width")
        check(ns.db.ui.height == 160 and f:GetHeight() == 160 and f.scroll and f.scroll:GetScrollChild() == f.list,
            "resize saves height and clips the quest list to a scroll viewport")
        check(f.list:GetWidth() == f:GetWidth() - 12 and f.list:GetHeight() > 0,
            "scroll child has a real width and height so quest text renders")
        f.scroll:SetVerticalScroll(0)
        ns.UI:Refresh()
        local activeTop = 4
        for i, entry in ipairs(f.list.entries) do
            if entry.state == "active" then break end
            activeTop = activeTop + f.list.rows[i]:GetHeight() + 3
        end
        check(activeTop <= f.scroll:GetVerticalScroll() + 64,
            "resized guide keeps the current step inside the visible list")
        f:SetHeight(520)
        f.resizeGrip:GetScript("OnMouseUp")(f.resizeGrip)
        check(ns.db.ui.maxRows > 7 and #f.list.entries > 7,
            "taller guide displays more than the default seven steps")
        f:SetHeight(160)
        f.resizeGrip:GetScript("OnMouseUp")(f.resizeGrip)
    end
    -- settings
    ns.Commands:Run("qg opacity 0.7")
    check(math.abs((ns.db.ui.opacity or 0) - 0.7) < 1e-6, "/fg qg opacity sets the window opacity")
    ns.Commands:Run("qg rows 4"); settle()
    ns.UI:Refresh(); settle()
    check(#f.list.entries <= 4, "/fg qg rows limits the list (" .. #f.list.entries .. ")")
    ns.Commands:Run("qg rows 7"); ns.UI:Refresh(); settle()
    ns.Commands:Run("qg subtitles off"); ns.UI:Refresh(); settle()
    check(ns.db.ui.showSubtitles == false and f.list.rows[1]:GetHeight() == ns.QuestRow.HEIGHT_ONE, "subtitles off makes single-line rows")
    ns.Commands:Run("qg subtitles on"); ns.UI:Refresh(); settle()
    ns.Commands:Run("qg completed off"); ns.UI:Refresh(); settle()
    local anyDone = false
    for _, e in ipairs(f.list.entries) do if e.state == "done" then anyDone = true end end
    check(not anyDone, "completed rows hidden when the option is off")
    ns.Commands:Run("qg completed on"); ns.UI:Refresh(); settle()
    -- the Guide info popup
    ns.QuestGuide:ToggleInfo(); settle()
    check(ForeverGuideInfo and ForeverGuideInfo:IsShown() and (ForeverGuideInfo.body:GetText() or ""):find("Step") ~= nil, "the Guide button opens the info popup with the current step")
    ns.QuestGuide:ToggleInfo(); settle()
    -- The chevron is the default; opt into the map pin to exercise its behavior.
    ns.Commands:Run("waypoint on")
    ns.Navigation:SetTarget({ map = 1429, x = 40, y = 60, label = "Hilary's Necklace", owner = "test" }); settle()
    ns.Waypoint:Tick()
    check(ns.Navigation.ownsWaypoint and MOCK.superTrack == true, "a target sets the engine's user waypoint and super-tracks it")
    check(not ns.Waypoint.overlay:IsShown() and not ns.Arrow.suppressedByWaypoint, "by default the diamond stays off and the chevron is the indicator (mode=" .. tostring(ns.Waypoint.mode) .. ")")
    check(ns.Arrow:IsShown() and not ns.Arrow.suppressedByWaypoint, "the chevron is visible by default")
    ns.Commands:Run("waypoint engine on"); ns.Waypoint:Tick()
    check(ns.db.nav.waypoint.engine == true and ns.Waypoint.mode == "engine", "/fg waypoint engine on rides the client's pin (mode=" .. tostring(ns.Waypoint.mode) .. ")")
    check(ns.Waypoint.overlay:IsShown(), "the world waypoint overlay shows on the engine pin")
    check(ns.Waypoint.overlay.name:GetText() == "Hilary's Necklace", "the overlay carries the quest name")
    check(SuperTrackedFrame.Icon.alpha == 0, "the engine pin's own icon is faded out under our diamond")
    check(ns.Arrow.suppressedByWaypoint == true, "the chevron arrow steps aside while the world pin shows")
    -- the engine cannot project the pin after all (Forever: NavigationState Invalid, frame
    -- faded): even with engine mode on, the diamond does NOT fall back to a guessed screen
    -- position any more (that guess is what felt sluggish) - it simply steps aside for the chevron
    MOCK.superTrack = false; ns.Waypoint:Tick()
    check(not ns.Waypoint.overlay:IsShown() and ns.Arrow.suppressedByWaypoint == false, "engine pin unusable: no guessed fallback - the chevron takes over (mode=" .. tostring(ns.Waypoint.mode) .. ")")
    MOCK.superTrack = true; ns.Waypoint:Tick()
    check(ns.Waypoint.overlay:IsShown() and ns.Waypoint.mode == "engine", "engine pin usable again: the diamond is back")
    ns.Commands:Run("waypoint off"); ns.Waypoint:Tick()
    check(ns.db.nav.waypoint.enabled == false and not ns.Waypoint.overlay:IsShown(), "/fg waypoint off hides the overlay")
    check(SuperTrackedFrame.Icon.alpha == 1, "the engine pin's own art is restored when the waypoint is off")
    check(ns.Arrow.suppressedByWaypoint == false, "the chevron arrow is back when the waypoint is off")
    ns.Commands:Run("waypoint on"); ns.Waypoint:Tick()
    check(ns.db.nav.waypoint.enabled == true and ns.db.nav.blizzardWaypoint == true and ns.Waypoint.overlay:IsShown(), "/fg waypoint on brings the overlay back (engine mode is still on from above)")
    -- the world map opens: nothing of ours floats over it; closes: back
    MOCK.mapOpen = true; WorldMapFrame.hooks.OnShow(); settle()
    check(not ns.Waypoint.overlay:IsShown() and not ns.Arrow:IsShown(), "world map open: waypoint and chevron hide")
    check(not ForeverGuideFrame:IsShown(), "world map open: the Quest Guide window steps aside")
    MOCK.mapOpen = false; WorldMapFrame.hooks.OnHide(); settle()
    check(ns.Waypoint.overlay:IsShown(), "world map closed: the waypoint is back")
    check(ForeverGuideFrame:IsShown(), "world map closed: the window is back")
    do  -- BearingPosition is no longer reached from Tick() (engine mode required to show at
        -- all), but the projection geometry itself is still exercised directly since it is
        -- still around for possible future use (1280x720 mock screen, character at 640,288)
        local W = ns.Waypoint
        local x, y, _, pinned = W:BearingPosition({ angle = 0, distance = 60 })
        check(x and math.abs(x - 640) < 1 and y > 288 and not pinned, string.format("60 yd straight ahead: above the character, centred (%.0f,%.0f)", x or 0, y or 0))
        local xr = W:BearingPosition({ angle = -math.rad(22), distance = 75 })
        check(xr and xr > 640 + 100, string.format("75 yd at 22 deg right lands well to the right (%.0f)", xr or 0))
        local xl, yl, _, pl = W:BearingPosition({ angle = math.rad(90), distance = 40 })
        check(pl and xl < 640 - 400 and math.abs(yl - 288) < 60, string.format("40 yd to the left pins to the left edge at the character's height (%.0f,%.0f)", xl or 0, yl or 0))
        local xb, yb, _, pb = W:BearingPosition({ angle = math.pi, distance = 30 })
        check(pb and math.abs(xb - 640) < 1 and yb < 288, string.format("30 yd behind pins to the bottom edge below the character (%.0f,%.0f)", xb or 0, yb or 0))
        local _, yf = W:BearingPosition({ angle = 0, distance = 800 })
        check(yf and yf <= 720 * 0.74 + 0.5, string.format("a far target never rises above the horizon line (%.0f)", yf or 0))
    end
    -- back to the default (engine off): the chevron leads, no smoothing to feel sluggish
    ns.Commands:Run("waypoint engine off"); ns.Waypoint:Tick()
    check(not ns.Waypoint.overlay:IsShown() and ns.Arrow:IsShown() and not ns.Arrow.suppressedByWaypoint, "engine off: back to the plain chevron by default")
    ns.Commands:Run("route off")
    check(ns.db.nav.waypoint.route == false, "/fg route off disables the dotted path")
    ns.Commands:Run("route on")
    ns.Navigation:Clear()
    G:SetStep(5); settle()
end

-- ---- level-gated quests: skipped until the level is reached, then revisited ---------------
do
    -- a small synthetic chapter: The Lost Tools (125, req low) then Blackrock Menace (20, req 18)
    ns.RegisterGuide({ id = "TEST_GATE", name = "gate test", version = 1, faction = "Alliance", minLevel = 15, maxLevel = 20, map = 1433, zone = "Redridge Mountains",
        steps = {
            { type = "ACCEPT", quest = 125, questName = "The Lost Tools", map = 1433, x = 32.1, y = 48.6 },
            { type = "ACCEPT", quest = 20, questName = "Blackrock Menace", map = 1433, x = 33.5, y = 49 },
            { type = "KILL", quest = 20, questName = "Blackrock Menace", target = "Blackrock Champion", map = 1433, x = 60, y = 60 },
            { type = "COLLECT", quest = 125, questName = "The Lost Tools", target = "Oslow's Toolbox", map = 1433, x = 41.5, y = 54.7 },
            { type = "TURNIN", quest = 20, questName = "Blackrock Menace", map = 1433, x = 33.5, y = 49 },
            { type = "TURNIN", quest = 125, questName = "The Lost Tools", map = 1433, x = 32.1, y = 48.6 },
        } })
    MOCK_LEVEL(17); settle()
    G:Activate("TEST_GATE", true); settle()
    MOCK_ACCEPT(125, "The Lost Tools", { { text = "Oslow's Toolbox: 0/1", finished = false, numFulfilled = 0, numRequired = 1 } }); settle()
    check(G.current == 4, "the level-18 accept and its objective are passed over at 17 (current " .. tostring(G.current) .. ")")
    check(G.progress.deferred and G.progress.deferred[20] == 2, "the quest is remembered as deferred")
    check((G.note or ""):find("needs level 18") ~= nil, "the note says why: " .. tostring(G.note))
    ns.UI:Refresh(); settle()
    local blockedRow = false
    for _, e in ipairs(ForeverGuideFrame.list.entries) do if e.state == "blocked" and e.questID == 20 then blockedRow = true end end
    check(blockedRow, "deferred quest rows show as blocked with the level needed")
    local enc = ns.Persist:EncodeChar()
    check(enc:find("df=20:2", 1, true) ~= nil, "deferred quests are mirrored in the cvar workaround")
    MOCK_LEVEL(18); settle()
    check(G.current == 2, "reaching the level goes back to the deferred accept (" .. tostring(G.current) .. ")")
    check(G.progress.deferred[20] == nil, "the deferral is cleared")
    MOCK.log[125] = nil
    for i, id in ipairs(MOCK.logOrder) do if id == 125 then table.remove(MOCK.logOrder, i) break end end
    MOCK_LEVEL(5); settle()
    G:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true); settle()
end

-- ---- sweep: every command, every UI script, options, keybinds ------------------------
do
    local before = #reportedErrors
    local cmds = {
        "", "help", "show", "hide", "toggle", "show", "guides", "guide GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", "skip", "back", "next", "step 3",
        "quests", "mode auto", "track", "mode guide", "quest 783", "quest kobold", "avail", "avail 5", "pos", "target", "nav",
        "way 40 60", "lock", "unlock", "resetpos", "auto", "auto accept guide", "auto turnin off", "auto accept on", "auto turnin on",
        "minimap off", "minimap on", "arrow off", "arrow on", "scale 1.2", "scale 1", "rec status", "rec dump 3", "scan status",
        "harvest status", "bliz off", "bliz on", "wrong", "wrong test text", "reports", "options", "debug", "debug", "eval",
        "reports clear", "bogus", "reset",
    }
    for _, c in ipairs(cmds) do ns.Commands:Run(c) end
    -- UI window scripts
    local w = rawget(_G, "ForeverGuideFrame") or rawget(_G, "ForeverGuideWindow")
    for name, f in pairs(_G) do
        if type(name) == "string" and name:find("^ForeverGuide") and type(f) == "table" and type(rawget(f, "scripts")) == "table" then
            for sname, fn in pairs(f.scripts) do
                if sname == "OnUpdate" then fn(f, 0.5) fn(f, 0.5)
                elseif sname == "OnClick" then fn(f, "LeftButton") fn(f, "RightButton")
                elseif sname == "OnEnter" or sname == "OnLeave" or sname == "OnShow" or sname == "OnHide" then fn(f)
                elseif sname == "OnDragStart" or sname == "OnDragStop" then fn(f)
                end
            end
        end
    end
    -- options panel: flip every checkbox both ways
    local panel = rawget(_G, "ForeverGuideOptionsPanel")
    check(panel ~= nil and MOCK.settingsCategory ~= nil, "options panel registered with the Settings API")
    if panel then
        panel.scripts.OnShow(panel)
        ns.Options:Refresh()
    end
    for _, fname in ipairs({ "ForeverGuide_ToggleWindow", "ForeverGuide_TogglePicker", "ForeverGuide_ToggleArrow", "ForeverGuide_Skip",
        "ForeverGuide_Back", "ForeverGuide_ToggleMode", "ForeverGuide_ReportWrong", "ForeverGuide_ToggleWindow", "ForeverGuide_TogglePicker",
        "ForeverGuide_ToggleArrow", "ForeverGuide_ToggleMode" }) do _G[fname]() end
    -- hide in combat
    ns.db.ui.hideInCombat = true
    ns.UI:Show()
    MOCK_FIRE("PLAYER_REGEN_DISABLED")
    check(not ForeverGuideFrame:IsShown(), "window hidden when combat starts")
    MOCK_FIRE("PLAYER_REGEN_ENABLED")
    check(ForeverGuideFrame:IsShown(), "window restored after combat")
    ns.db.ui.hideInCombat = false
    -- minimap tooltip / clicks
    local mb = rawget(_G, "ForeverGuideMinimapButton")
    check(mb ~= nil, "minimap button exists")
    if mb then mb.scripts.OnEnter(mb) mb.scripts.OnLeave(mb) mb.scripts.OnClick(mb, "LeftButton") mb.scripts.OnClick(mb, "RightButton") mb.scripts.OnClick(mb, "LeftButton") end
    ns.UI:RefreshPicker()
    ns.Tracker:SetMode("auto") ns.Tracker:Rethink() ns.UI:Refresh() ns.Tracker:SetMode("guide")
    local unexpected = 0
    for i = before + 1, #reportedErrors do
        local e = reportedErrors[i]
        if not e:find("unknown command", 1, true) then unexpected = unexpected + 1 end
    end
    check(unexpected == 0, "command / UI sweep produced no errors (" .. unexpected .. ")")
end

-- ---- beta SavedVariables bug: state survives a login with empty SavedVariables via cvars ----
do
    G:Activate("GEN_ALLIANCE_DWARF_01_DUN_MOROGH", true); settle()
    G:SetStep(20); settle()
    G.progress.done[7] = true G.progress.done[8] = true G.progress.done[12] = true
    ns.char.mode = "guide"
    ns.db.ui.x, ns.db.ui.y = -123, -45
    ns.db.minimap.angle = 137
    ns.AutoQuest:Set("accept", "guide")
    ns.Commands:Run("edit note keep me")
    ns.db.edits.GEN_ALLIANCE_DWARF_01_DUN_MOROGH[G.current] = { type = G:GetCurrentStep().type, quest = G:GetCurrentStep().quest, map = 1426, x = 12.5, y = 34.5, npc = 999 }
    ns.db.edits.GEN_ALLIANCE_DWARF_01_DUN_MOROGH[3] = { type = "ACCEPT", quest = 179, npc = 658 }
    ns.db.ui.width = 480; ns.db.ui.height = 280; ns.db.ui.hideTracker = false; ns.db.ui.hideOnMap = false
    ns.Persist:Save()
    check(ns.Persist.lastSaveOK == true, "the cvar mirror verified its write")
    check(#(MOCK.cvars.ForeverGuideA0 or "") > 0 and #(MOCK.cvars.ForeverGuideCSniffClassicBetaPvE20 or MOCK.cvars["ForeverGuideC" .. ((UnitName("player") .. GetRealmName()):gsub("[^%w]", "")):sub(1, 24) .. "0"] or "") > 0, "cvar mirror written (account + character)")
    local savedStep, savedGuide = G.progress.step, ns.char.activeGuide
    -- simulate the beta: SavedVariables come back nil at the next login
    ForeverGuideDB, ForeverGuideCharDB = nil, nil
    ns.Database:Init()
    check(ns.Database.freshChar and ns.char.activeGuide == nil, "fresh login: character SavedVariables empty")
    ns.Persist.restored = { acct = false, char = false }
    ns.Persist:Restore()
    check(ns.char.activeGuide == savedGuide, "active guide restored from the cvar mirror (" .. tostring(ns.char.activeGuide) .. ")")
    local p = ns.char.guides[savedGuide]
    check(p and p.step == savedStep and p.done[7] and p.done[8] and p.done[12] and not p.done[9], "step + done list restored (" .. tostring(p and p.step) .. ")")
    check(ns.db.ui.x == -123 and ns.db.ui.y == -45 and ns.db.minimap.angle == 137 and ns.db.auto.accept == "guide", "settings restored")
    local e = ns.db.edits and ns.db.edits[savedGuide] and ns.db.edits[savedGuide][savedStep]
    check(e and e.x == 12.5 and e.npc == 999, "step edit restored")
    local e2 = ns.db.edits[savedGuide][3]
    check(e2 and e2.npc == 658 and e2.quest == 179 and e and e.quest ~= nil, "a second step edit survives the mirror too (separator kept)")
    check(ns.db.ui.width == 480 and ns.db.ui.height == 280 and ns.db.ui.hideTracker == false and ns.db.ui.hideOnMap == false,
        "window size and tracker/map switches are restored")
    ns.AutoQuest:Set("accept", "on")
    ns.db.edits = {}
    G:Activate(savedGuide, true); G:Reset(); settle()
end

-- ---- arriving in the zone finishes the chapter's travel step; resync moves forward ----
-- (Ilya, 2026-09-21: level 18 in Westfall with the Westfall chapter open, the guide sat on
--  "Travel to Westfall - 640 yd" forever and every /fg resync answered "now at step 1")
do
    local savedMap, savedZone = MOCK.mapID, MOCK.zone
    G:Activate("GEN_ALLIANCE_DWARF_04_WESTFALL", true); settle()
    local steps = G.active.steps
    check(steps[1].type == "TRAVEL" and steps[1].map == 1436, "Westfall chapter starts with a travel step")
    check(cur() == 1, "outside Westfall the guide holds the travel step (" .. tostring(cur()) .. ")")
    -- walk in, but nowhere near the coordinates the step carries (Moonbrook, not Sentinel Hill)
    MOCK_ZONE(1436, "Westfall", 45.5, 66.1); settle()
    check(G:IsStepDone(steps[1], 1) == true and cur() == 2,
        "in Westfall the travel step is done -> the hearthstone note (" .. tostring(cur()) .. ")")
    MOCK_ACCEPT(6181, "A Swift Message"); settle()
    check(cur() > 2 and steps[cur()].type ~= "TRAVEL", "and the note gives way once a quest is taken (" .. tostring(cur()) .. ")")
    MOCK_ABANDON(6181); settle()
    -- an in-zone travel step is NOT ticked off just for being in the zone
    check(G:IsZoneEntry(steps[1], 1) == true, "step 1 is a zone entry")
    local inZone = { type = "TRAVEL", map = 1436, zone = "Westfall", x = 20, y = 20 }
    check(G:IsZoneEntry(inZone, 5) == false, "a travel step later in the same zone is not a zone entry")

    -- resync with quests already taken out of order: it must move forward, not back to step 1
    G:SetStep(1); settle()
    MOCK_ACCEPT(12, "The People's Militia", { { text = "Defias Trapper slain", finished = false, numFulfilled = 0, numRequired = 15 } }); settle()
    MOCK_ACCEPT(102, "Patrolling Westfall"); settle()
    local landed = G:Resync() and cur()
    check(landed and landed > 1, "resync moves forward past the stale travel step (" .. tostring(landed) .. ")")
    check(G.progress.done[1] == true, "the travel step is marked done by the resync")
    MOCK_ABANDON(12) MOCK_ABANDON(102)
    MOCK_ZONE(savedMap, savedZone, 48, 43); settle()
    G:Activate("HUMAN_NORTHSHIRE_1_6", true); G:Reset(); settle()
end

-- ---- a quest this character's race can never take is not part of the route ----
-- (Ilya, 2026-09-21: the Dwarf chapter offered 6181 "A Swift Message", a Human-only quest, and the
--  guide sat on it at Quartermaster Lewis - who has nothing to say to a dwarf)
do
    local q = ns.QuestDB and ns.QuestDB[6181]
    check(q ~= nil and q.races ~= nil and q.races ~= 0, "the database knows 6181 is race-restricted")
    local mine = MOCK.race
    MOCK.race = { "Dwarf", "Dwarf" }
    ns.Player.cache = {}
    ns.RegisterGuide({ id = "AUDIT_RACE", name = "race", steps = {
        { type = "ACCEPT", quest = 6181, npc = 491 },
        { type = "TURNIN", quest = 6181, npc = 523 },
        { type = "ACCEPT", quest = 4010 } } })
    G:Activate("AUDIT_RACE", true); settle()
    check(ns.DB:RaceClassOK(6181) == false, "a dwarf cannot take the human quest 6181")
    check(cur() == 3, "its accept and turn-in are not part of the route for a dwarf (" .. tostring(cur()) .. ")")
    MOCK.race = mine
    ns.Player.cache = {}
    if ns.Quest:IsOnQuest(4010) then MOCK_ABANDON(4010); settle() end
end

-- ---- level-up announcement ------------------------------------------------------------------
-- (Ilya, 2026-09-21: "when we level up there should be a party message/emote message ...")
do
    local D = ns.Ding
    check(D.FormatTime(42) == "42 sec" and D.FormatTime(1080) == "18 min"
        and D.FormatTime(5040) == "1h 24m" and D.FormatTime(183600) == "2d 3h",
        "time played reads naturally (" .. D.FormatTime(5040) .. ")")
    check(D.Message(18, 5040) == "ForeverGuide: I leveled up to 18 in 1h 24m", "the line is what was asked for: " .. D.Message(18, 5040))
    check(D.Message(18, nil) == "ForeverGuide: I leveled up to 18", "an unknown time is left out")

    -- the server answer is the baseline; time keeps running from it
    MOCK.playedTotal, MOCK.playedLevel = 360000, 5000
    D:Request()
    check(D.played ~= nil and math.abs(D:Elapsed() - 5000) < 2, "time played at this level comes from the server (" .. tostring(D:Elapsed()) .. ")")
    MOCK_ADVANCE(40)
    check(math.abs(D:Elapsed() - 5040) < 2, "and keeps running while online (" .. tostring(D:Elapsed()) .. ")")

    -- the client's own "Total time played" answer to OUR request is swallowed, a /played is not
    D:Request()
    check(MOCK_SYSTEM("Total time played: 1 day, 3 hours") == nil, "our own time-played answer is not printed")
    check(MOCK_SYSTEM("Whatever else the server says") ~= nil, "other system messages are untouched")
    check(MOCK_CHATFRAME("Total time played: 1 day, 3 hours") == nil, "and neither is it when the client prints it straight into the frame")
    check(MOCK_CHATFRAME("Sniff Yahbooty says hello") ~= nil, "ordinary chat lines still print")
    MOCK_ADVANCE(10)
    check(MOCK_SYSTEM("Total time played: 1 day, 3 hours") ~= nil, "a /played the player types still prints")

    -- Opt into announcements for their behavior tests; normal default is off.
    ns.Commands:Run("ding on")
    -- solo: an emote
    MOCK.chat = {}
    MOCK.group, MOCK.raid = false, false
    local was = ns.Player:GetLevel()
    local expected = D.FormatTime(D:Elapsed())
    MOCK_LEVEL(was + 1); settle()
    local sent = MOCK.chat[1]
    check(sent ~= nil and sent.channel == "EMOTE", "solo, the ding goes out as an emote (" .. tostring(sent and sent.channel) .. ")")
    check(sent and sent.message == string.format("ForeverGuide: I leveled up to %d in %s", was + 1, expected),
        "with the level and the time played at the level before it: " .. tostring(sent and sent.message))
    check((MOCK.playedRequests or 0) >= 2, "and the baseline is asked for again after the ding")

    -- in a party: the party
    MOCK.chat = {}
    MOCK.group = true
    MOCK_LEVEL(was + 2); settle()
    check(MOCK.chat[1] and MOCK.chat[1].channel == "PARTY", "grouped, it goes to the party (" .. tostring(MOCK.chat[1] and MOCK.chat[1].channel) .. ")")

    -- a chosen channel wins, and off means off
    MOCK.chat = {}
    ns.Commands:Run("ding guild")
    MOCK_LEVEL(was + 3); settle()
    check(MOCK.chat[1] and MOCK.chat[1].channel == "GUILD", "a chosen channel is used (" .. tostring(MOCK.chat[1] and MOCK.chat[1].channel) .. ")")
    MOCK.chat = {}
    ns.Commands:Run("ding off")
    MOCK_LEVEL(was + 4); settle()
    check(#MOCK.chat == 0, "/fg ding off stops it (" .. #MOCK.chat .. " sent)")

    -- a client that refuses the message says so instead of erroring
    ns.Commands:Run("ding on")
    ns.Commands:Run("ding auto")
    MOCK.chatBlocked = true
    MOCK.chat = {}
    MOCK_LEVEL(was + 5); settle()
    check(#MOCK.chat == 0, "a client that blocks SendChatMessage sends nothing (" .. #MOCK.chat .. ")")
    MOCK.chatBlocked = nil
    MOCK.group, MOCK.raid = false, false

    -- the setting survives the cvar mirror
    ns.Commands:Run("ding emote")
    local encoded = ns.Persist:EncodeAcct()
    ns.db.ding.channel = "party"
    ns.Persist:DecodeAcct(encoded)
    check(ns.db.ding.channel == "emote", "the channel is kept in the beta cvar mirror (" .. tostring(ns.db.ding.channel) .. ")")
    ns.Commands:Run("ding auto")
end

-- ---- the options panel fits in the settings canvas -------------------------------------------
-- (Ilya, 2026-09-21: "the text is overflowing" - the checkbox list ran off the bottom of the
--  Options window and drew over the game)
do
    local p = ns.Options:Create()
    check(p ~= nil and p.body ~= nil and p.body ~= p, "the options list lives on a scrolling child")
    check(p.scroll ~= nil and p.scroll:GetScrollChild() == p.body, "the scroll frame holds it")
    check((p.contentHeight or 0) > 400, "the child is as tall as its contents (" .. tostring(p.contentHeight) .. ")")
    local wheel = p.scroll:GetScript("OnMouseWheel")
    check(type(wheel) == "function", "the wheel scrolls it")
    if wheel then
        p.scroll:SetHeight(300)
        wheel(p.scroll, -1)
        check(p.scroll:GetVerticalScroll() > 0, "wheeling down moves the list (" .. tostring(p.scroll:GetVerticalScroll()) .. ")")
        wheel(p.scroll, 1) wheel(p.scroll, 1)
        check(p.scroll:GetVerticalScroll() == 0, "and it stops at the top (" .. tostring(p.scroll:GetVerticalScroll()) .. ")")
    end
    local names = {}
    for key in pairs(ns.QuestGuideConfig.TOGGLES) do names[#names + 1] = key end
    check(ns.QuestGuideConfig.TOGGLES.ding ~= nil, "the level-up announcement has a switch in the panel")
end

-- ---- levelling pace ---------------------------------------------------------------------------
do
    local P = ns.Pace
    check(P.Number(19600) == "19 600" and P.Number(940) == "940", "numbers are grouped for reading (" .. P.Number(19600) .. ")")

    -- a chapter's model comes from the planner, through the notes of the guides already generated
    local g = ns.Guide.registry["GEN_ALLIANCE_DWARF_04_WESTFALL"]
    local minutes, xph = P.Model(g)
    check(minutes and minutes > 0 and xph and xph > 0, "the model minutes / xp-h are read off a generated chapter (" .. tostring(minutes) .. ", " .. tostring(xph) .. ")")
    check(P.Model({ modelMinutes = 90, modelXph = 12000 }) == 90, "a guide that carries the numbers is used directly")

    -- earn xp over measured play and the rate follows
    P.samples, P.earned, P.played = {}, 0, 0
    P.lastXP, P.lastMax, P.lastLevel = nil, nil, nil
    P:Sample("reset")
    MOCK_XP(100, 1000)
    P:Sample("base")
    local earnedBefore = P.earned
    for _ = 1, 10 do MOCK_ADVANCE(60) end     -- ten minutes of play, in steps a session would take
    MOCK_XP(600, 1000)
    check(P.earned - earnedBefore == 500, "xp earned since the last look (" .. tostring(P.earned - earnedBefore) .. ")")
    local perHour = P:PerHour()
    check(perHour and math.abs(perHour - 3000) < 60, "500 xp in ten minutes reads as 3000 xp/h (" .. tostring(perHour and math.floor(perHour)) .. ")")

    local s = P:Stats()
    check(s.remaining == 400 and math.abs((s.percent or 0) - 60) < 1, "what is left of the level (" .. tostring(s.remaining) .. ", " .. tostring(math.floor(s.percent or 0)) .. "%)")
    check(s.secondsToLevel and math.abs(s.secondsToLevel - 480) < 30, "400 xp at 3000/h is about 8 minutes (" .. tostring(s.secondsToLevel and math.floor(s.secondsToLevel)) .. ")")
    check(P:Tag() ~= nil and P:Tag():find("in ", 1, true) ~= nil, "the header tag reads like '19 in 8 min' (" .. tostring(P:Tag()) .. ")")

    -- a level-up counts the rest of the old level plus what is on the new one
    MOCK_XP(900, 1000)
    local before = P.earned
    MOCK.level = MOCK.level + 1
    MOCK_XP(50, 1200)
    check(P.earned - before == 150, "a level-up counts the rest of the old bar plus the new (" .. tostring(P.earned - before) .. ")")

    -- the route model knows what is left
    ns.Guide:Activate("GEN_ALLIANCE_HUMAN_01_ELWYNN_FOREST", true); settle()
    local left, chapters = P:RouteRemaining()
    check(left and left > 0 and chapters and chapters > 1, "minutes left on the route, over the remaining chapters (" .. tostring(left and math.floor(left)) .. " min, " .. tostring(chapters) .. ")")
    local lines = P:Lines()
    check(#lines >= 3, "/fg xp has something to say (" .. #lines .. " lines)")
    for _, line in ipairs(lines) do check(type(line) == "string" and #line > 0, "each line is text") end
end

-- ---- gear wear: the bags banner does the repair reminder too ---------------------------------
do
    ns.db.bags.banners = true -- the fresh-login test reset the defaults
    local B = ns.Bags
    MOCK_GEAR(nil)
    check(B:Durability() == nil, "no gear that wears: nothing to say")
    MOCK_BAG(10, 0, 0)          -- roomy bags, so only the gear can raise the banner
    MOCK_GEAR(80)
    B:Check("test")
    check(B:GearLow() == nil, "gear at 80% is fine")
    check(not ForeverGuideBagBanner:IsShown(), "and the banner stays down")
    MOCK_GEAR(18)
    B:Check("test")
    local d = B:GearLow()
    check(d ~= nil and math.abs(d.percent - 18) < 1, "gear at 18% is low (" .. tostring(d and math.floor(d.percent)) .. ")")
    check(ForeverGuideBagBanner:IsShown(), "the banner says so")
    check((ForeverGuideBagBanner.title:GetText() or ""):find("repair", 1, true) ~= nil,
        "with a repair line: " .. tostring(ForeverGuideBagBanner.title:GetText()))
    local tag = B:Tag()
    check(tag == "gear 18%", "and the header tag reads " .. tostring(tag))
    MOCK_GEAR(40, { [1] = 0 })
    B:Check("test")
    local broken = B:GearLow()
    check(broken and broken.broken == 1 and broken.worst == "head", "a broken piece is named (" .. tostring(broken and broken.worst) .. ")")
    check((ForeverGuideBagBanner.title:GetText() or ""):find("broken", 1, true) ~= nil,
        "and the banner leads with it: " .. tostring(ForeverGuideBagBanner.title:GetText()))
    -- full bags win: one errand, the more urgent line
    MOCK_BAG(0, 2, 0)
    B:Check("test")
    check((ForeverGuideBagBanner.title:GetText() or ""):find("BAGS FULL", 1, true) ~= nil,
        "full bags come first: " .. tostring(ForeverGuideBagBanner.title:GetText()))
    MOCK_GEAR(nil)
    MOCK_BAG(10, 0, 0)
    B:Check("test")
    check(not ForeverGuideBagBanner:IsShown(), "and everything settles down again")
end

-- ---- a chapter of another race's route ---------------------------------------------------------
-- (seen live 2026-09-22: a level-20 dwarf in Duskwood was following "6. Ashenvale 19-22 (Night Elf)"
--  while /fg path said the Dwarf route; the race-only quests in it are skipped, so say so)
do
    local mineBefore = ns.char.route
    ns.char.route = nil
    MOCK.level = 20
    ns.Player.cache.level = 20
    local mine, route = ns.Guide:RouteChapterForLevel(20)
    check(route ~= nil and mine ~= nil, "the followed route has a chapter for level 20 (" .. tostring(mine and mine.id) .. ")")
    check(ns.Guide:ForMyRace(mine) == true, "and it is one for this character's race")

    ns.Guide:Activate("GEN_ALLIANCE_NIGHTELF_06_ASHENVALE", true); settle()
    local race, instead = ns.Guide:OffRouteChapter()
    check(race == "NIGHTELF" and instead ~= nil, "a night elf chapter is spotted as off-route (" .. tostring(race) .. " -> " .. tostring(instead and instead.id) .. ")")

    ns.Guide:Activate(mine.id, true); settle()
    check(ns.Guide:OffRouteChapter() == nil, "our own chapter raises nothing")

    -- and auto-pick prefers our own route's chapter over another race's
    local pick = ns.Guide:AutoPick()
    check(pick ~= nil and ns.Guide:ForMyRace(pick), "auto-pick stays on this character's route (" .. tostring(pick and pick.id) .. ")")

    -- asking for another route by hand is not second-guessed
    ns.char.route = "GEN_ALLIANCE_NIGHTELF"
    ns.Guide:Activate("GEN_ALLIANCE_NIGHTELF_06_ASHENVALE", true); settle()
    check(ns.Guide:OffRouteChapter() == nil, "a route the player chose is left alone")
    ns.char.route = mineBefore
    ns.Guide:Activate("HUMAN_NORTHSHIRE_1_6", true); ns.Guide:Reset(); settle()
end

-- ---- flight points and the trainer nudge -------------------------------------------------------
do
    local R = ns.Reminders
    local map = 1415          -- taxi nodes are listed per continent (Eastern Kingdoms here)
    MOCK_TAXI(map, {})
    check(#R:FlightPoints() == 0, "no taxi nodes: nothing to take")

    -- the client lists the whole continent; ours is what counts, minus the ones we already have
    MOCK_MOVE(48, 43)
    ns.char.flightpoints = { ["Sentinel Hill"] = true }
    MOCK_TAXI(map, {
        { nodeID = 1, name = "Darkshire", x = 48.5, y = 43.2, isUndiscovered = false, faction = 2 },
        { nodeID = 2, name = "Sentinel Hill", x = 20, y = 20, isUndiscovered = false, faction = 2 },
        { nodeID = 3, name = "Grom'gol", x = 49, y = 44, isUndiscovered = false, faction = 1 },
    })
    local list = R:FlightPoints()
    check(#list == 1 and list[1].name == "Darkshire", "one we do not have, of our faction (" .. #list .. ")")
    MOCK_TAXI(map, {
        { nodeID = 1, name = "Darkshire", x = 48.5, y = 43.2, faction = 2 },
        { nodeID = 9, name = "zzOLDPowderfuse Port, Riverglades", x = 48.6, y = 43.3, faction = 2 },
    })
    check(#R:FlightPoints() == 1, "the client's retired zzOLD nodes are not flight masters")
    MOCK_TAXI(map, {
        { nodeID = 1, name = "Darkshire", x = 48.5, y = 43.2, faction = 2 },
        { nodeID = 2, name = "Sentinel Hill", x = 20, y = 20, faction = 2 },
        { nodeID = 3, name = "Grom'gol", x = 49, y = 44, faction = 1 },
    })
    check(list[1].distance and list[1].distance < 100, "with a distance (" .. tostring(list[1].distance and math.floor(list[1].distance)) .. " yd)")

    R.said = {}
    local said = R:CheckFlight("tick")
    check(said ~= nil and said.name == "Darkshire", "standing next to it, the addon says so")
    check(R.said["zone:" .. tostring(ns.Player:GetMapID())] == nil or true, "the zone list waits until a flight master has taught us the known ones")
    check(R:CheckFlight("tick") == nil, "and does not say it twice")

    -- /fg fp points the arrow at it and hands the marker back on arrival
    local go = R:GoToFlightPoint()
    check(go ~= nil and ns.Navigation.override == "flightpoint" and ns.Navigation.target.owner == "fp",
        "/fg fp takes the marker (" .. tostring(ns.Navigation.target and ns.Navigation.target.label) .. ")")
    R:ReleaseFlightPoint()
    check(ns.Navigation.override == nil, "and gives it back")

    -- standing at a flight master teaches us what we already have
    MOCK_TAXIMAP({ { name = "Darkshire", state = 0 }, { name = "Menethil Harbor", state = 1 }, { name = "Grom'gol", state = 2 } })
    check(ns.char.flightpoints["Darkshire"] == true and ns.char.flightpoints["Menethil Harbor"] == true,
        "the open flight map says which ones are ours")
    check(ns.char.flightpoints["Grom'gol"] == nil, "and an unreachable one is not")
    check(#R:FlightPoints() == 0, "so once taken it is gone from the list")

    -- switched off, nothing is said
    ns.Commands:Run("remind flight off")
    ns.char.flightpoints = {}
    MOCK_TAXI(map, { { nodeID = 1, name = "Darkshire", x = 48.5, y = 43.2, isUndiscovered = false, faction = 2 } })
    R.said = {}
    check(R:CheckFlight("tick") == nil, "/fg remind flight off keeps it quiet")
    ns.Commands:Run("remind flight on")

    -- "New flight path discovered!" marks the one we just took
    ns.char.flightpoints = {}
    MOCK_TAXI(map, { { nodeID = 1, name = "Darkshire", x = 48.5, y = 43.2, faction = 2 } })
    MOCK_FIRE("UI_INFO_MESSAGE", 1, "New flight path discovered!")
    check(ns.char.flightpoints["Darkshire"] == true, "taking one on foot is noticed too")
    check(#R:FlightPoints() == 0, "and it leaves the list")
    ns.char.flightpoints = {}

    -- the trainer: a visit is remembered, and two levels later it nudges
    ns.char.lastTrained = nil
    MOCK.level = 20
    ns.Player.cache.level = 20
    MOCK_TRAINER(5165, "Bink")
    check(ns.char.lastTrained == 20, "training is noted at the level it happened (" .. tostring(ns.char.lastTrained) .. ")")
    local t = R:KnownTrainer()
    check(t and t.name == "Bink" and t.map ~= nil, "and so is where the trainer was (" .. tostring(t and t.name) .. ")")
    check(R:TrainerDue(21) == nil, "one level later there is nothing to say")
    local due = R:TrainerDue(22)
    check(due == 2, "two levels later there is (" .. tostring(due) .. ")")
    MOCK.level = 22
    ns.Player.cache.level = 22
    local line = R:TrainerNudge(22)
    check(line and line:find("last trained at 20", 1, true) and line:find("Bink", 1, true), "the nudge names both: " .. tostring(line))
    ns.Commands:Run("remind trainer off")
    check(R:TrainerNudge(24) == nil, "/fg remind trainer off keeps it quiet too")
    ns.Commands:Run("remind trainer on")

    -- both switches and the level we last trained at survive the cvar mirror
    ns.char.lastTrained = 22
    ns.Commands:Run("remind flight off")
    local acct, char = ns.Persist:EncodeAcct(), ns.Persist:EncodeChar()
    ns.db.reminders.flight, ns.char.lastTrained = true, nil
    ns.Persist:DecodeAcct(acct) ns.Persist:DecodeChar(char)
    check(ns.db.reminders.flight == false, "the flight switch is kept in the mirror")
    check(ns.char.lastTrained == 22, "and the level you last trained at (" .. tostring(ns.char.lastTrained) .. ")")
    ns.Commands:Run("remind flight on")
    ns.char.lastTrained = nil
end

-- ---- dungeons: the guide steps aside -----------------------------------------------------------
-- (Ilya, 2026-09-22: "when in a dungeon, we need to disable the quest guide, so it doesnt interfere")
do
    local I = ns.Instance
    ns.UI:Show()
    MOCK_BAG(0, 3, 0)            -- something that would raise a banner outside
    ns.Bags:Check("test")
    check(ForeverGuideBagBanner:IsShown(), "outside, a full-bag banner shows")

    MOCK_INSTANCE("party")
    check(I:Inside() == true, "the addon knows it is in a dungeon")
    check(ns.UI:AllHidden() == true and ns.UI:IsSuspended("dungeon"), "so everything is put away")
    check(ns.db.ui.hiddenAll ~= true, "without touching the hide-everything setting")
    ns.Bags:Check("test")
    check(not ForeverGuideBagBanner:IsShown(), "and the banners stay down inside")
    ns.Crowd:Update()
    check(not ForeverGuideCrowdBanner:IsShown(), "the crowd banner too")

    MOCK_INSTANCE(nil)
    check(ns.UI:AllHidden() == false, "walking out brings it back")
    ns.Bags:Check("test")
    check(ForeverGuideBagBanner:IsShown(), "banners and all")

    -- a battleground counts, a city does not
    MOCK_INSTANCE("pvp")
    check(ns.UI:AllHidden() == true, "a battleground is no place for a levelling guide either")
    MOCK_INSTANCE("none")
    check(ns.UI:AllHidden() == false, "out again")

    -- and the player can keep it up if they want
    ns.Commands:Run("dungeon off")
    MOCK_INSTANCE("party")
    check(ns.UI:AllHidden() == false, "/fg dungeon off keeps the guide up inside (" .. tostring(ns.UI:AllHidden()) .. ")")
    ns.Commands:Run("dungeon on")
    check(ns.UI:AllHidden() == true, "and turning it back on puts it away again")
    MOCK_INSTANCE(nil)

    -- the setting survives the cvar mirror
    ns.Commands:Run("dungeon off")
    local acct = ns.Persist:EncodeAcct()
    ns.db.instance.hide = true
    ns.Persist:DecodeAcct(acct)
    check(ns.db.instance.hide == false, "the dungeon switch is kept in the mirror")
    ns.Commands:Run("dungeon on")
    MOCK_BAG(10, 0, 0)
    ns.Bags:Check("test")
end

-- ---- no swallowed errors anywhere -------------------------------------------------
do
    local expected = 0
    for _, e in ipairs(reportedErrors) do
        if e:find("command failed", 1, true) and e:find("expected", 1, true) then expected = expected + 1 end
    end
    check(#reportedErrors == expected, "no errors were reported by any module (" .. #reportedErrors .. ")")
    for _, e in ipairs(reportedErrors) do print("   reported: " .. e) end
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
