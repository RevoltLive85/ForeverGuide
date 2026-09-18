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
    check(ForeverGuideArrowFrame ~= nil and ForeverGuideArrowFrame:IsShown(), "floating arrow frame exists and is shown with a target")
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
    ns.Commands:Run("auto")
    MOCK.log[60], MOCK.log[62], MOCK.log[5001] = nil, nil, nil
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

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
