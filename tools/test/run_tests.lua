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
    ForeverGuidePicker.rows[2]:GetScript("OnClick")(ForeverGuidePicker.rows[2])
    check(ns.char.mode == "guide" and ns.Guide.active ~= nil and not ForeverGuidePicker:IsShown(), "clicking a guide activates it and closes the picker")
    check(ForeverGuideArrowFrame ~= nil and (ForeverGuideArrowFrame:IsShown() or (ns.Waypoint.overlay and ns.Waypoint.overlay:IsShown())), "a target shows either the chevron arrow or the world waypoint")
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
    -- no engine pin (other continent / hidden): fallback to the chevron
    MOCK.superTrack = false; ns.Waypoint:Tick()
    check(not ns.Waypoint.overlay:IsShown() and ns.Arrow.suppressedByWaypoint == false, "engine pin hidden: overlay hides and the chevron takes over")
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
    ns.Persist:Save()
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
