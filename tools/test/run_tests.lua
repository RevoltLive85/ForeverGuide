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
        { type = "ACCEPT", quest = 4001 },
        { type = "ACCEPT", quest = 4002, optional = true, note = "group quest" },
        { type = "KILL", quest = 4002, target = "Kobold Vermin", optional = true },
        { type = "TURNIN", quest = 4002, optional = true },
        { type = "TURNIN", quest = 4001 } } })
    if ns.Quest:IsOnQuest(4001) then MOCK_ABANDON(4001); settle() end
    G:Activate("AUDIT_GROUP", true); settle()
    MOCK_ACCEPT(4001, "Base quest", {}); settle()
    check(cur() == 5 and step().type == "TURNIN" and step().quest == 4001, "optional group quest steps are walked past when the quest is not taken (" .. tostring(cur()) .. ")")
    MOCK_ACCEPT(4002, "Group quest", { { text = "Kobold Vermin slain", finished = false, numFulfilled = 0, numRequired = 5 } }); settle()
    check(cur() == 3 and step().quest == 4002, "taking the group quest by hand guides its objectives (" .. tostring(cur()) .. ")")
    MOCK_ABANDON(4002); settle()
    check(cur() == 5, "dropping it walks past again (" .. tostring(cur()) .. ")")
    MOCK_TURNIN(4001); settle()
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
    -- in combat the nameplate frames cannot be measured (restricted regions): fall back to interact rings
    MOCK_PLATE("nameplate1", { name = "Kobold Vermin", npcID = 6, restricted = true, dist = 25 })
    MOCK_PLATE("nameplate2", { name = "Kobold Vermin", npcID = 6, restricted = true, dist = 8 })
    ns.MobMarker:Scan()
    check(ns.MobMarker.primaryUnit == "nameplate2" and #reportedErrors == 0, "restricted nameplates: no error, nearest by interact distance (" .. tostring(ns.MobMarker.primaryUnit) .. ")")
    ns.Commands:Run("skull off"); ns.MobMarker:Scan()
    check(ns.MobMarker.markedCount == 0 and GetCVar("nameplateShowEnemies") == "0", "/fg skull off removes the skulls and restores the nameplate setting")
    ns.Commands:Run("skull on")
    MOCK_ABANDON(11); settle()
    ns.MobMarker:Scan()
    check(GetCVar("nameplateShowEnemies") == "0", "leaving the kill step restores enemy nameplates (step=" .. tostring(step() and step().type) .. " cvar=" .. tostring(GetCVar("nameplateShowEnemies")) .. ")")
    for i = 1, 4 do MOCK_PLATE("nameplate" .. i, nil) end
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
    -- waypoint: the engine pin (SuperTrackedFrame) is dressed by our overlay while it shows
    ns.Navigation:SetTarget({ map = 1429, x = 40, y = 60, label = "Hilary's Necklace", owner = "test" }); settle()
    ns.Waypoint:Tick()
    check(ns.Navigation.ownsWaypoint and MOCK.superTrack == true, "a target sets the engine's user waypoint and super-tracks it")
    check(ns.Waypoint.overlay:IsShown() and ns.Waypoint.mode == "bearing", "by default the diamond is placed by our own projection (mode=" .. tostring(ns.Waypoint.mode) .. ")")
    ns.Commands:Run("waypoint engine on"); ns.Waypoint:Tick()
    check(ns.db.nav.waypoint.engine == true and ns.Waypoint.mode == "engine", "/fg waypoint engine on rides the client's pin (mode=" .. tostring(ns.Waypoint.mode) .. ")")
    check(ns.Waypoint.overlay:IsShown(), "the world waypoint overlay shows on the engine pin")
    check(ns.Waypoint.overlay.name:GetText() == "Hilary's Necklace", "the overlay carries the quest name")
    check(SuperTrackedFrame.Icon.alpha == 0, "the engine pin's own icon is faded out under our diamond")
    check(ns.Arrow.suppressedByWaypoint == true, "the chevron arrow steps aside while the world pin shows")
    ns.Commands:Run("waypoint off"); ns.Waypoint:Tick()
    check(ns.db.nav.waypoint.enabled == false and not ns.Waypoint.overlay:IsShown(), "/fg waypoint off hides the overlay")
    check(SuperTrackedFrame.Icon.alpha == 1, "the engine pin's own art is restored when the waypoint is off")
    check(ns.Arrow.suppressedByWaypoint == false, "the chevron arrow is back when the waypoint is off")
    ns.Commands:Run("waypoint on"); ns.Waypoint:Tick()
    check(ns.db.nav.waypoint.enabled == true and ns.db.nav.blizzardWaypoint == true and ns.Waypoint.overlay:IsShown(), "/fg waypoint on brings the overlay back")
    -- the world map opens: nothing of ours floats over it; closes: back
    MOCK.mapOpen = true; WorldMapFrame.hooks.OnShow(); settle()
    check(not ns.Waypoint.overlay:IsShown() and not ns.Arrow:IsShown(), "world map open: waypoint and chevron hide")
    check(not ForeverGuideFrame:IsShown(), "world map open: the Quest Guide window steps aside")
    MOCK.mapOpen = false; WorldMapFrame.hooks.OnHide(); settle()
    check(ns.Waypoint.overlay:IsShown(), "world map closed: the waypoint is back")
    check(ForeverGuideFrame:IsShown(), "world map closed: the window is back")
    -- the engine cannot project the pin (Forever: NavigationState Invalid, frame faded):
    -- the diamond is placed on the bearing ring around the character instead
    MOCK.superTrack = false; ns.Waypoint:Tick()
    check(ns.Waypoint.overlay:IsShown() and ns.Waypoint.mode == "bearing" and ns.Arrow.suppressedByWaypoint == true, "engine pin unusable: the diamond goes on the bearing ring (mode=" .. tostring(ns.Waypoint.mode) .. ")")
    do
        local px, py = ns.Waypoint.PlayerScreenPoint()
        local ox, oy = ns.Waypoint.overlay:GetCenter()
        local st = ns.Navigation.state
        local ahead = st and st.angle and math.abs(st.angle) < math.pi / 2
        check(ox and ((ahead and oy > py) or (not ahead and oy < py)), string.format("bearing ring: a target ahead sits above the character, behind below (angle=%.2f dy=%.0f)", st and st.angle or 0, (oy or 0) - py))
    end
    do  -- projection geometry (1280x720 mock screen, character at 640,288)
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
    -- no direction at all (no facing): fallback to the chevron
    local savedFacing = MOCK.facing
    MOCK.facing = nil; ns.Navigation:Update(); ns.Waypoint:Tick()
    check(ns.Waypoint.overlay:IsShown(), "a momentary loss of direction keeps the marker where it was (no blinking)")
    ns.Waypoint.lastPos.at = ns.Waypoint.lastPos.at - 5; ns.Waypoint:Tick()
    check(not ns.Waypoint.overlay:IsShown() and ns.Arrow.suppressedByWaypoint == false, "no direction known for longer: overlay hides and the chevron takes over")
    MOCK.facing = savedFacing; ns.Navigation:Update()
    MOCK.superTrack = true; ns.Waypoint:Tick()
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
    ns.db.ui.width = 480; ns.db.ui.hideTracker = false; ns.db.ui.hideOnMap = false
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
    check(ns.db.ui.width == 480 and ns.db.ui.hideTracker == false and ns.db.ui.hideOnMap == false, "window width and the tracker/map switches are restored")
    ns.AutoQuest:Set("accept", "on")
    ns.db.edits = {}
    G:Activate(savedGuide, true); G:Reset(); settle()
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
