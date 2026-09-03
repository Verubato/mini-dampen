-- MatchState.lua never draws anything, so these drive it entirely through tests/Helpers/Arena.lua
-- and read back state.ally, state.enemy, and the four fields the round record is carried in.

local fw = require("TestFramework")
local Arena = require("Arena")

local GATED_EVENT_COUNT = 8

local function gatedFrame(env)
	for _, frame in ipairs(env.Context.Mock.Frames) do
		if frame.__scripts.OnEvent and next(frame.__events) and frame.__events["ARENA_OPPONENT_UPDATE"] ~= nil then
			return frame
		end
	end
end

local function countEvents(frame)
	local count = 0

	for _ in pairs(frame.__events) do
		count = count + 1
	end

	return count
end

fw.describe("MiniDampen - scope gate", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	fw.it("has no registrations and no ticker out of an arena", function()
		local frame = gatedFrame(env)

		fw.is_nil(frame, "no frame has registered ARENA_OPPONENT_UPDATE")
		fw.eq(#env.Tickers, 0, "no ticker created")
	end)

	fw.it("registers exactly the eight gated events and one ticker on entering", function()
		env.Enter()

		local frame = gatedFrame(env)

		fw.not_nil(frame, "the gated frame registered ARENA_OPPONENT_UPDATE")
		fw.eq(countEvents(frame), GATED_EVENT_COUNT, "event count")
		fw.not_nil(frame.__events["UPDATE_BATTLEFIELD_SCORE"], "the board event is among them")
		fw.eq(#env.Tickers, 1, "one ticker created")
	end)

	fw.it("unregisters everything and cancels the ticker on leaving", function()
		env.Enter()
		env.Leave()

		local frame = gatedFrame(env)

		fw.is_nil(frame, "no frame still carries ARENA_OPPONENT_UPDATE")
		fw.truthy(env.Tickers[1].Ticker:IsCancelled(), "the ticker was cancelled")
	end)

	fw.it("keeps the gate shut when Enabled is false", function()
		_G.MiniDampenDB.Enabled = false
		env.Enter()

		fw.falsy(env.Addon.MatchState.State.inScope, "scope did not open")
		fw.eq(#env.Tickers, 0, "no ticker created")
	end)

	fw.it("opens once the match leaves Inactive, with no fresh PLAYER_ENTERING_WORLD", function()
		-- Entering while still Inactive leaves the gate shut; only the bootstrap frame's own
		-- PVP_MATCH_STATE_CHANGED registration gives it another chance to open.
		env.MatchState = 0 -- Inactive
		env.Enter()

		fw.falsy(env.Addon.MatchState.State.inScope, "still shut while Inactive")

		env.SetState(1) -- Waiting

		fw.truthy(env.Addon.MatchState.State.inScope, "opened once the match left Inactive")
	end)

	fw.it("stays open once the match reaches Complete, and closes when the player leaves", function()
		env.Enter()
		env.SetState(2) -- StartUp
		env.SetState(3) -- Engaged
		env.SetState(4) -- PostRound
		env.SetState(5) -- Complete

		fw.truthy(env.Addon.MatchState.State.inScope, "the finished record stays up over the results screen")

		env.Leave()

		fw.falsy(env.Addon.MatchState.State.inScope, "closed on leaving the arena")
	end)

	fw.it("closes immediately when Evaluate runs after Enabled turns false", function()
		env.Enter()

		fw.truthy(env.Addon.MatchState.State.inScope, "scope open")

		_G.MiniDampenDB.Enabled = false
		env.Addon.MatchState:Evaluate()

		fw.falsy(env.Addon.MatchState.State.inScope, "closed the moment Evaluate re-checks Enabled")
	end)
end)

fw.describe("MiniDampen - visibility", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	fw.it("hides an unseen opponent only after HIDDEN_DELAY, count unchanged throughout", function()
		env.Unseen("arena2")
		env.Tick(0.5)

		local entry = env.Addon.MatchState.State.enemy[2]

		fw.falsy(entry.Hidden, "still within HIDDEN_DELAY")
		fw.eq(entry.Alive, true, "alive count unaffected by visibility")

		env.Tick(2)

		fw.truthy(entry.Hidden, "past HIDDEN_DELAY")
		fw.eq(entry.Alive, true, "alive count still unaffected")
	end)

	fw.it("clears hidden on seen without waiting", function()
		env.Unseen("arena2")
		env.Tick(2)

		local entry = env.Addon.MatchState.State.enemy[2]

		fw.truthy(entry.Hidden, "hidden after the delay")

		env.Seen("arena2")

		fw.falsy(entry.Hidden, "cleared immediately, no tick needed")
	end)

	fw.it("distinguishes a kill from a vanish", function()
		env.Kill("arena2")
		env.Tick(0.5)

		local entry = env.Addon.MatchState.State.enemy[2]

		fw.eq(entry.Alive, false, "the kill dropped this entry")
		fw.falsy(entry.Hidden, "a kill does not hide")

		local aliveCount = 0

		for _, e in ipairs(env.Addon.MatchState.State.enemy) do
			if e.Alive then
				aliveCount = aliveCount + 1
			end
		end

		fw.eq(aliveCount, 2, "enemy alive count dropped to 2")
	end)

	fw.it("does not error when a death read is secret", function()
		env.MarkDeathSecret("arena2")

		fw.no_error(function()
			env.Tick(0.5)
		end, "secret death read")
	end)

	fw.it("does not resurrect a corpse when its next death read comes back secret", function()
		env.Kill("arena3")
		env.Tick(0.5)

		fw.eq(env.Addon.MatchState.State.enemy[3].Alive, false, "dead before the secret read")

		env.MarkDeathSecret("arena3")
		env.Tick(0.5)

		fw.eq(env.Addon.MatchState.State.enemy[3].Alive, false, "still dead, an unresolved read must not overwrite it")
	end)

	fw.it("keeps a feigning hunter counted alive, even though the death read says otherwise", function()
		env.Feign("arena2")
		env.Tick(0.5)

		local entry = env.Addon.MatchState.State.enemy[2]

		fw.eq(entry.Alive, true, "a feign is not a kill")

		local aliveCount = 0

		for _, e in ipairs(env.Addon.MatchState.State.enemy) do
			if e.Alive then
				aliveCount = aliveCount + 1
			end
		end

		fw.eq(aliveCount, 3, "the enemy count never dips")
	end)

	fw.it("does not latch EverDead for a feign, so the killed-versus-vanished split survives it", function()
		env.Feign("arena2")
		env.Tick(0.5)

		fw.falsy(env.Addon.MatchState.State.enemy[2].EverDead, "no confirmed kill recorded")

		env.StopFeigning("arena2")
		env.Deaths.arena2 = nil
		env.Tick(0.5)

		fw.falsy(env.Addon.MatchState.State.enemy[2].EverDead, "still nothing latched once the hunter stands up")
	end)

	fw.it("still records the real death when a feigning hunter is killed afterwards", function()
		env.Feign("arena2")
		env.Tick(0.5)

		env.StopFeigning("arena2")
		env.Tick(0.5)

		local entry = env.Addon.MatchState.State.enemy[2]

		fw.eq(entry.Alive, false, "dead once the feign is no longer what the death read means")
		fw.truthy(entry.EverDead, "the real death latches")
	end)

	fw.it("treats an unreadable feign read as a feign, since inventing a kill is the worse failure", function()
		env.Kill("arena2")
		env.SecretFeigns.arena2 = true
		env.Tick(0.5)

		local entry = env.Addon.MatchState.State.enemy[2]

		fw.eq(entry.Alive, true, "an unreadable feign never drops the count")
		fw.falsy(entry.EverDead, "and never latches a kill")
	end)

	fw.it("drops a destroyed opponent's Alive immediately, even while its own death read stays secret, but leaves EverDead to the poll", function()
		env.MarkDeathSecret("arena3")
		env.Destroyed("arena3")

		local entry = env.Addon.MatchState.State.enemy[3]

		fw.eq(entry.Alive, false, "destroyed sets Alive directly, not only through the poll")
		fw.falsy(entry.EverDead, "a confirmed kill can only come from the poll's own readable death read")
	end)

	fw.it("clears EverDead once a latched enemy reads alive again, with the feign API answering false throughout", function()
		env.Kill("arena2")
		env.Tick(0.5)

		fw.truthy(env.Addon.MatchState.State.enemy[2].EverDead, "latched dead on the first readable death")

		env.Deaths.arena2 = nil
		env.Tick(0.5)

		fw.falsy(env.Addon.MatchState.State.enemy[2].EverDead, "a readable alive reading reverses a latch that was never a real kill")
	end)

	fw.it("keeps EverDead latched when the token stops resolving afterward", function()
		env.Kill("arena2")
		env.Tick(0.5)

		env.Exists.arena2 = false
		env.Tick(0.5)

		fw.truthy(env.Addon.MatchState.State.enemy[2].EverDead, "an unreadable nil reading can't clear the latch")
	end)

	fw.it("keeps EverDead latched when a later death read comes back secret, pinning the release to exactly dead == false rather than a loosened dead ~= true", function()
		env.Kill("arena2")
		env.Tick(0.5)

		env.MarkDeathSecret("arena2")
		env.Tick(0.5)

		fw.truthy(env.Addon.MatchState.State.enemy[2].EverDead, "a secret reading can't clear the latch")
	end)
end)

fw.describe("MiniDampen - round edges and the shuffle flag", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	local function startRound()
		env.SetState(2) -- StartUp
		env.SetState(3) -- Engaged
	end

	fw.it("clears everDead on the next StartUp", function()
		startRound()
		env.Kill("arena1")
		env.Tick(0.5)

		fw.eq(env.Addon.MatchState.State.enemy[1].EverDead, true, "latched dead before the clear")

		env.SetState(4)
		env.Deaths = {}
		startRound()

		fw.eq(env.Addon.MatchState.State.enemy[1].EverDead, false, "round two starts clean")
	end)

	fw.it("clears everDead on entering Engaged, with no StartUp edge in between", function()
		env.SetState(3) -- Engaged
		env.Kill("arena1")
		env.Tick(0.5)

		fw.eq(env.Addon.MatchState.State.enemy[1].EverDead, true, "latched dead before the clear")

		env.SetState(4) -- PostRound
		env.Deaths = {}
		env.SetState(3) -- Engaged again, straight from PostRound

		fw.eq(env.Addon.MatchState.State.enemy[1].EverDead, false, "the entry edge is what clears, not StartUp alone")
	end)

	fw.it("calls it a shuffle when the client only answers true after the scope has opened", function()
		-- The scope opens as early as the prep room, so a reading taken once at OpenScope is
		-- taken before the client necessarily has the match data to answer with.
		local fresh = Arena.Build()
		fresh.SoloShuffle = false
		fresh.Enter()

		fw.falsy(fresh.Addon.MatchState.State.isSoloShuffle, "nothing to go on when the scope opened")

		fresh.SoloShuffle = true
		fresh.Context.Mock.FireEvent("GROUP_ROSTER_UPDATE")

		fw.truthy(fresh.Addon.MatchState.State.isSoloShuffle, "any gated event asks the client again")
	end)

	fw.it("calls it a shuffle on a match state change too, not only a roster one", function()
		local fresh = Arena.Build()
		fresh.SoloShuffle = false
		fresh.Enter()
		fresh.SoloShuffle = true
		fresh.SetState(2) -- StartUp

		fw.truthy(fresh.Addon.MatchState.State.isSoloShuffle, "read on the transition as well")
	end)

	fw.it("follows the client back down rather than latching a reading it cannot re-verify", function()
		local fresh = Arena.Build()
		fresh.SoloShuffle = true
		fresh.Enter()

		fw.truthy(fresh.Addon.MatchState.State.isSoloShuffle, "read at scope open")

		fresh.SoloShuffle = false
		fresh.SetState(2)

		fw.falsy(fresh.Addon.MatchState.State.isSoloShuffle, "no stale true outlives the client's own answer")
	end)

	fw.it("redraws on a UNIT_AURA that moves the flag but leaves dampening alone", function()
		-- UNIT_AURA is the one gated handler that can decline to notify, so it is the one that
		-- could otherwise sit on a changed flag until the next event.
		local fresh = Arena.Build()
		fresh.SoloShuffle = false
		fresh.Enter()
		fresh.SoloShuffle = true
		fresh.Context.Mock.FireEvent("UNIT_AURA", "player")

		fw.truthy(fresh.Addon.MatchState.State.isSoloShuffle, "the flag moved on a bare aura event")
	end)

	fw.it("does not call a plain arena a shuffle on a secret reading", function()
		local fresh = Arena.Build()
		fresh.SoloShuffle = Arena.SECRET
		fresh.Enter()

		fw.falsy(fresh.Addon.MatchState.State.isSoloShuffle, "a secret value is truthy, so it must be tested for true")
	end)

	fw.it("forgets the shuffle flag on leaving, so the next plain arena starts clean", function()
		local fresh = Arena.Build()
		fresh.SoloShuffle = true
		fresh.Enter()

		fw.truthy(fresh.Addon.MatchState.State.isSoloShuffle, "set while in the shuffle")

		fresh.Leave()

		fw.falsy(fresh.Addon.MatchState.State.isSoloShuffle, "cleared with the rest of the scope")
	end)

	fw.it("leaves roundIndex nil in a shuffle with nothing readable in the widget set", function()
		local fresh = Arena.Build()
		fresh.SoloShuffle = true
		fresh.MatchState = 3 -- Engaged
		fresh.Enter()

		fw.is_nil(fresh.Addon.MatchState.State.roundIndex, "no reading, so no round line")
	end)

	fw.it("does not error when round activity follows PVP_MATCH_COMPLETE before scope closes", function()
		env.SoloShuffle = true
		env.SetRecordWidgets(1, 6, 0)
		startRound()
		env.SetState(4) -- PostRound

		env.Context.Mock.FireEvent("PVP_MATCH_COMPLETE")

		fw.no_error(function()
			startRound() -- StartUp -> Engaged again, before EvaluateGate has closed scope
			env.SetState(4)
		end, "round activity after PVP_MATCH_COMPLETE, before the scope closes")
	end)
end)

fw.describe("MiniDampen - the round record from the widgets", function()
	local env
	local state

	fw.before_each(function()
		env = Arena.Build()
		env.SoloShuffle = true
		env.Enter()
		state = env.Addon.MatchState.State
	end)

	fw.it("reads the round, the total, and both halves of the record off one widget update", function()
		env.SetRecordWidgets(3, 6, 1)
		env.FireWidgetUpdate()

		fw.eq(state.roundIndex, 3, "the round being played")
		fw.eq(state.roundTotal, 6, "out of the total the widget names")
		fw.eq(state.recordWins, 1, "the wins widget's own number")
		fw.eq(state.recordLosses, 1, "two rounds finished, one of them won")
	end)

	fw.it("reads on a match state change with no widget event of its own", function()
		env.SetRecordWidgets(3, 6, 1)
		env.SetState(3) -- Engaged

		fw.eq(state.roundIndex, 3, "the state change is a trigger in its own right")
	end)

	fw.it("rejects the hidden widget and the wrong-typed one, which both match the round text shape", function()
		-- Ids off the observed pair, so a decoy that survived the filter would be a second
		-- candidate with no tie-break to settle it.
		env.SetRecordWidgets(3, 6, 1, { RoundId = 3600, WinsId = 4600 })
		env.FireWidgetUpdate()

		fw.eq(state.roundIndex, 3, "read off shape alone, with the decoys filtered out")
		fw.eq(state.recordWins, 1, "and the wins with it")
	end)

	fw.it("lets the observed id settle a tie between two wins-shaped widgets", function()
		env.SetRecordWidgets(3, 6, 1, { ExtraWins = 2 })
		env.FireWidgetUpdate()

		fw.eq(state.recordWins, 1, "widget 4457 is the one the record was captured on")
	end)

	fw.it("refuses two wins-shaped widgets when neither carries the observed id", function()
		env.SetRecordWidgets(2, 6, 1)
		env.FireWidgetUpdate()

		fw.eq(state.recordWins, 1, "a clean reading first")

		env.SetRecordWidgets(3, 6, 2, { WinsId = 4600, ExtraWins = 2 })
		env.FireWidgetUpdate()

		fw.eq(state.roundIndex, 2, "the previous round still stands")
		fw.eq(state.recordWins, 1, "and the record with it")
	end)

	fw.it("never draws a negative loss count when the wins widget has run ahead of the round", function()
		env.SetRecordWidgets(3, 6, 3)
		env.FireWidgetUpdate()

		fw.eq(state.recordWins, 3, "three wins")
		fw.eq(state.recordLosses, 0, "out of the three rounds they prove were finished")
	end)

	fw.it("shows a stale record through the PostRound of a lost round, then corrects", function()
		env.SetRecordWidgets(3, 6, 1)
		env.FireWidgetUpdate()

		fw.eq(state.recordLosses, 1, "one loss during round three")

		env.SetState(4) -- PostRound, with neither widget having moved

		fw.eq(state.recordWins, 1, "the round just lost is not on the record yet")
		fw.eq(state.recordLosses, 1, "which is a stale number rather than a wrong one")

		env.SetRecordWidgets(4, 6, 1)
		env.FireWidgetUpdate()

		fw.eq(state.recordLosses, 2, "and lands once the round number advances")
	end)

	fw.it("counts the last round at Complete, which is the round the local counter used to lose", function()
		env.SetState(3) -- Engaged
		env.SetRecordWidgets(6, 6, 2)
		env.FireWidgetUpdate()

		fw.eq(state.recordWins, 2, "two wins during round six")
		fw.eq(state.recordLosses, 3, "against the five rounds finished so far")

		env.SetBoard(2, 6)

		-- Straight from Engaged to Complete, with no PostRound in between.
		env.SetState(5)
		env.FireScoreUpdate()

		fw.eq(state.recordWins, 2, "the wins are unchanged")
		fw.eq(state.recordLosses, 4, "and the sixth round lands")
	end)

	fw.it("holds the five-round figure at Complete when no board arrives to book the sixth", function()
		env.SetState(3) -- Engaged
		env.SetRecordWidgets(6, 6, 2)
		env.FireWidgetUpdate()

		env.SetState(5)

		fw.eq(state.recordWins, 2, "the wins stand at the five-round figure")
		fw.eq(state.recordLosses, 3, "the final round is not booked without a board")
	end)

	fw.it("does not count rounds nobody played when the match is abandoned part way through", function()
		env.SetRecordWidgets(4, 6, 2)
		env.FireWidgetUpdate()
		env.SetState(5) -- Complete at round four

		fw.eq(state.recordWins, 2, "the wins stand")
		fw.eq(state.recordLosses, 1, "three rounds were played, not six")
	end)

	fw.it("keeps the record right when a round boundary is missed entirely", function()
		env.SetRecordWidgets(2, 6, 1)
		env.FireWidgetUpdate()

		fw.eq(state.recordWins, 1, "one win")
		fw.eq(state.recordLosses, 0, "off the one round finished")

		-- Nothing fired for round three, so the next reading arrives two rounds on.
		env.SetRecordWidgets(4, 6, 2)
		env.FireWidgetUpdate()

		fw.eq(state.recordWins, 2, "the wins the widget names")
		fw.eq(state.recordLosses, 1, "and three rounds finished, whatever was seen in between")
	end)

	fw.it("refuses a reading whose numbers cannot be right", function()
		local cases = {
			{ 7, 6, 1, "a round past the total" },
			{ 0, 6, 0, "a round before the first" },
			{ 7, 7, 1, "a total past the six a shuffle has" },
			{ 3, 6, 7, "more wins than the match has rounds" },
		}

		for _, case in ipairs(cases) do
			env.SetRecordWidgets(case[1], case[2], case[3])
			env.FireWidgetUpdate()

			fw.is_nil(state.roundIndex, case[4])
		end
	end)

	fw.it("refuses a widget carrying no digits at all", function()
		env.SetRecordWidgets(3, 6, 1, { RoundText = "Sudden Death" })
		env.FireWidgetUpdate()

		fw.is_nil(state.roundIndex, "nothing that reads as a round number")
	end)

	fw.it("does not take a timer-flagged single-integer widget as the wins widget", function()
		env.SetRecordWidgets(3, 6, 1, { Timer = true })
		env.FireWidgetUpdate()

		fw.is_nil(state.roundIndex, "a clock is not a wins count, and round three has no other candidate")
	end)

	fw.it("refuses wins that outrun the round itself, not just the total", function()
		env.SetRecordWidgets(1, 6, 5, { WinsText = "Dampening 5%" })
		env.FireWidgetUpdate()

		fw.is_nil(state.roundIndex, "five wins before round one has finished cannot be real")
	end)

	fw.it("refuses without erroring wherever the client answers secret", function()
		local fields = { "SecretSetId", "SecretWidgetList", "SecretInfo", "SecretText", "SecretState", "SecretTimer" }

		for _, field in ipairs(fields) do
			local options = {}
			options[field] = true

			fw.no_error(function()
				env.SetRecordWidgets(3, 6, 1, options)
				env.FireWidgetUpdate()
			end, field .. " is never read through")

			fw.is_nil(state.roundIndex, field .. " commits nothing")
		end
	end)

	fw.it("refuses a reading that would take the record backwards", function()
		env.SetRecordWidgets(4, 6, 2)
		env.FireWidgetUpdate()

		fw.eq(state.recordWins, 2, "two wins out of three finished rounds")
		fw.eq(state.recordLosses, 1, "so one loss")

		env.SetRecordWidgets(4, 6, 1)
		env.FireWidgetUpdate()

		fw.eq(state.recordWins, 2, "a wins count that dropped is a widget caught mid-update")

		env.SetRecordWidgets(2, 6, 2)
		env.FireWidgetUpdate()

		fw.eq(state.roundIndex, 4, "and so is a round count that dropped")
	end)

	fw.it("holds the last accepted record once the widgets stop reading", function()
		env.SetRecordWidgets(3, 6, 1)
		env.FireWidgetUpdate()

		env.Widgets = {}
		env.FireWidgetUpdate()

		fw.eq(state.roundIndex, 3, "the round still stands")
		fw.eq(state.recordWins, 1, "and the record with it")

		env.RemoveWidgetApi()

		fw.no_error(function()
			env.FireWidgetUpdate()
		end, "a client with no widget system at all")

		fw.eq(state.recordLosses, 1, "nothing but leaving clears the record")
	end)

	fw.it("reads nothing in a plain arena, which has no rounds to record", function()
		env.SoloShuffle = false
		env.SetRecordWidgets(3, 6, 1)
		env.FireWidgetUpdate()

		fw.is_nil(state.roundIndex, "a non-shuffle top-center set is never parsed")

		env.SoloShuffle = true
		env.FireWidgetUpdate()

		fw.eq(state.roundIndex, 3, "the same widgets read in a shuffle")
	end)

	fw.it("redraws only when the record actually moved", function()
		env.SetRecordWidgets(3, 6, 1)
		env.FireWidgetUpdate()

		local notifies = 0
		local previous = env.Addon.MatchState.OnChanged

		env.Addon.MatchState.OnChanged = function()
			notifies = notifies + 1
			previous()
		end

		env.FireWidgetUpdate()

		fw.eq(notifies, 0, "an unrelated widget update draws nothing")

		env.SetRecordWidgets(4, 6, 2)
		env.FireWidgetUpdate()

		fw.eq(notifies, 1, "a moved record draws once")
	end)

	fw.it("redraws when a widget event is what flips the shuffle flag, even though the record itself declines to read", function()
		env.SetRecordWidgets(3, 6, 1)
		env.FireWidgetUpdate()

		local notifies = 0
		local previous = env.Addon.MatchState.OnChanged

		env.Addon.MatchState.OnChanged = function()
			notifies = notifies + 1
			previous()
		end

		env.SoloShuffle = false
		env.FireWidgetUpdate()

		fw.eq(notifies, 1, "the flag moving off is itself a reason to redraw, so the record row leaves with it")
	end)

	fw.it("re-reads the record from the client after a reload", function()
		env.SetRecordWidgets(4, 6, 2)
		env.FireWidgetUpdate()

		env.Reload()

		local reloaded = env.Addon.MatchState.State

		fw.eq(reloaded.roundIndex, 4, "read back off the widgets rather than out of saved variables")
		fw.eq(reloaded.recordWins, 2, "with the wins")
		fw.eq(reloaded.recordLosses, 1, "and the losses")
	end)

	fw.it("clears the round record 1.0.3 left in saved variables", function()
		_G.MiniDampenDB.ActiveMatch = { RoundIndex = 3 }

		env.Reload()

		fw.is_nil(_G.MiniDampenDB.ActiveMatch, "nothing persists now, so nothing is left behind")
	end)

	fw.it("keeps the finished record over the results screen and clears it on leaving", function()
		env.SetRecordWidgets(6, 6, 2)
		env.FireWidgetUpdate()
		env.SetBoard(2, 6)
		env.SetState(5) -- Complete
		env.FireScoreUpdate()

		fw.eq(state.recordLosses, 4, "the final record")

		env.Context.Mock.FireEvent("PVP_MATCH_COMPLETE")
		env.Widgets = {}
		env.FireWidgetUpdate()

		fw.eq(state.recordWins, 2, "held once the widget set is torn down")
		fw.eq(state.recordLosses, 4, "both halves of it")

		env.Leave()

		fw.is_nil(state.roundIndex, "the round goes with the scope")
		fw.is_nil(state.roundTotal, "and the total")
		fw.is_nil(state.recordWins, "and the wins")
		fw.is_nil(state.recordLosses, "and the losses")
	end)
end)

fw.describe("MiniDampen - the final round from the scoreboard", function()
	local env
	local state

	fw.before_each(function()
		env = Arena.Build()
		env.SoloShuffle = true
		env.Enter()
		state = env.Addon.MatchState.State
	end)

	---Drives the widgets to round six of six, the round the wins widget never itself takes,
	---leaving Complete as the only step still needed to reach the board branch.
	local function reachFinalRound(wins)
		env.SetState(3) -- Engaged
		env.SetRecordWidgets(6, 6, wins)
		env.FireWidgetUpdate()
	end

	fw.it("books a won final round from the board, which the widgets alone would lose", function()
		reachFinalRound(4)
		env.SetBoard(5, 6)

		env.SetState(5) -- Complete
		env.FireScoreUpdate()

		fw.eq(state.recordWins, 5, "the board's own count of the final round")
		fw.eq(state.recordLosses, 1, "five rounds out of six")
	end)

	fw.it("books a lost final round from the board when it agrees with the widget", function()
		reachFinalRound(4)
		env.SetBoard(4, 6)

		env.SetState(5) -- Complete
		env.FireScoreUpdate()

		fw.eq(state.recordWins, 4, "the board agrees with the widget's own floor")
		fw.eq(state.recordLosses, 2, "the final round was lost")
	end)

	fw.it("refuses a board that has not been reported by an UPDATE_BATTLEFIELD_SCORE this scope", function()
		reachFinalRound(4)
		env.SetBoard(5, 6)

		env.SetState(5) -- Complete, the board sits on the client but nothing has reported it

		fw.eq(state.recordWins, 4, "the direct read is refused")
		fw.eq(state.recordLosses, 1, "held")
	end)

	fw.it("takes the same board once UPDATE_BATTLEFIELD_SCORE has arrived", function()
		reachFinalRound(4)
		env.SetBoard(5, 6)
		env.SetState(5) -- Complete

		env.FireScoreUpdate()

		fw.eq(state.recordWins, 5, "the board the event brought")
		fw.eq(state.recordLosses, 1, "the final round lands")
	end)

	fw.it("books the final round from the board when the widgets tear down before Complete", function()
		reachFinalRound(4)

		fw.eq(state.recordWins, 4, "settled from the widgets while still Engaged")
		fw.eq(state.recordLosses, 1, "five rounds played")

		env.Widgets = {}
		env.SetBoard(5, 6)
		env.SetState(5) -- Complete, with the widgets already gone
		env.FireScoreUpdate()

		fw.eq(state.recordWins, 5, "the board's own count of the final round")
		fw.eq(state.recordLosses, 1, "five rounds out of six")
		fw.eq(env.ScoreRequests, 1, "asked exactly once")
	end)

	fw.it("holds at the five-round figure when no board ever arrives", function()
		reachFinalRound(4)

		env.SetState(5) -- Complete

		fw.eq(state.recordWins, 4, "the widget's own floor")
		fw.eq(state.recordLosses, 1, "five rounds counted, not six")
		fw.eq(state.roundIndex, 6, "the round line still reads the true round")
		fw.eq(state.roundTotal, 6, "out of six")
	end)

	fw.it("holds without erroring on a secret row and a row with no stats table", function()
		reachFinalRound(4)
		env.SetBoard(5, 6, { Secret = true })

		fw.no_error(function()
			env.SetState(5) -- Complete
		end, "a secret own row")

		fw.eq(state.recordWins, 4, "held at the widget's floor")
		fw.eq(state.recordLosses, 1, "five rounds")

		env.SetBoard(5, 6, { NoStats = true })

		fw.no_error(function()
			env.FireScoreUpdate()
		end, "a row with no stats table")

		fw.eq(state.recordWins, 4, "still held")
		fw.eq(state.recordLosses, 1, "still five rounds")
	end)

	fw.it("settles a board that arrives late over one still crediting the round in progress", function()
		reachFinalRound(4)
		env.SetBoard(4, 5) -- fifteen across five rounds, the sixth not yet credited

		env.SetState(5) -- Complete

		fw.eq(state.recordWins, 4, "held while the board still sums to five rounds")
		fw.eq(state.recordLosses, 1, "five rounds, not six")

		env.SetBoard(5, 6) -- the full eighteen
		env.FireScoreUpdate()

		fw.eq(state.recordWins, 5, "settles once the board catches up")
		fw.eq(state.recordLosses, 1, "the final round lands")
		fw.eq(env.ScoreRequests, 1, "never asked a second time for it")
	end)

	fw.it("refuses a board whose own wins undercut the widget's floor", function()
		-- The monotonic guard would refuse this board as backwards once a round has already
		-- committed, so this starts from a reload with nothing committed yet.
		env.MatchState = 5 -- Complete, as if reloaded straight to the results screen
		env.Reload()

		state = env.Addon.MatchState.State

		env.SetRecordWidgets(6, 6, 4)
		env.SetBoard(3, 6)
		env.FireScoreUpdate()

		fw.is_nil(state.recordWins, "the floor alone refuses it, with nothing committed to fall back on")
		fw.is_nil(state.recordLosses, "held")
	end)

	fw.it("refuses a board whose own wins outrun the six rounds played", function()
		reachFinalRound(4)
		env.SetBoard(7, 6)

		env.SetState(5) -- Complete

		fw.eq(state.recordWins, 4, "seven wins out of six rounds cannot be real")
		fw.eq(state.recordLosses, 1, "held")
	end)

	fw.it("refuses a board carrying two rows under the player's own name", function()
		reachFinalRound(4)
		-- Carries the same wins as the real row, so every other check clears and ownRows is
		-- the only one left to refuse it.
		env.SetBoard(5, 6, { Duplicate = 5 })

		env.SetState(5) -- Complete
		env.FireScoreUpdate()

		fw.eq(state.recordWins, 4, "ambiguous between two own rows, so held")
		fw.eq(state.recordLosses, 1, "held")
	end)

	fw.it("holds without erroring when the scoreboard api is absent entirely", function()
		reachFinalRound(4)
		env.RemoveScoreApi()

		fw.no_error(function()
			env.SetState(5) -- Complete
		end, "no GetNumBattlefieldScores or GetScoreInfo")

		fw.eq(state.recordWins, 4, "held")
		fw.eq(state.recordLosses, 1, "held")
	end)

	fw.it("asks the server exactly once, however many widget and score events arrive with a refusing board", function()
		reachFinalRound(4)
		env.SetState(5) -- Complete, no board ever set, so every reading refuses

		for _ = 1, 10 do
			env.FireWidgetUpdate()
		end

		for _ = 1, 10 do
			env.FireScoreUpdate()
		end

		fw.eq(env.ScoreRequests, 1, "one request for the whole match")
	end)

	fw.it("never asks before Complete, at any round", function()
		env.SetRecordWidgets(3, 6, 1)
		env.FireWidgetUpdate()
		env.SetState(3) -- Engaged

		fw.eq(env.ScoreRequests, 0, "mid-match reads never touch the board")
	end)

	fw.it("never asks when the match completes below its last round", function()
		env.SetRecordWidgets(4, 6, 2)
		env.FireWidgetUpdate()
		env.SetState(5) -- Complete at round four

		fw.eq(env.ScoreRequests, 0, "an abandoned match never asks for the board")
	end)

	fw.it("settles from the direct board read on a client with no request call at all", function()
		reachFinalRound(4)
		env.SetBoard(5, 6)
		env.RemoveScoreRequestApi()

		fw.no_error(function()
			env.SetState(5) -- Complete
			env.FireScoreUpdate()
		end, "no RequestBattlefieldScoreData on this client")

		fw.eq(state.recordWins, 5, "the direct read still settles it")
		fw.eq(state.recordLosses, 1, "the final round lands")
	end)

	fw.it("makes its own single request and settles its own board in a second match", function()
		reachFinalRound(4)
		env.SetBoard(5, 6)
		env.SetState(5) -- Complete
		env.FireScoreUpdate()

		fw.eq(env.ScoreRequests, 1, "the first match's request")

		env.Leave()
		env.MatchState = 1 -- Waiting, a fresh match's prep room
		env.Widgets = {}
		env.Scores = {}
		env.Enter()

		state = env.Addon.MatchState.State

		fw.is_nil(state.roundIndex, "a fresh match starts with no record")

		reachFinalRound(3)
		env.SetBoard(4, 6)
		env.SetState(5) -- Complete
		env.FireScoreUpdate()

		fw.eq(state.recordWins, 4, "the second match's own board")
		fw.eq(state.recordLosses, 2, "settled independently of the first")
		fw.eq(env.ScoreRequests, 2, "one request per match")
	end)

	fw.it("once settled, a stale widget reading changes nothing", function()
		reachFinalRound(4)
		env.SetBoard(5, 6)
		env.SetState(5) -- Complete
		env.FireScoreUpdate()

		fw.eq(state.recordWins, 5, "settled")

		env.SetRecordWidgets(6, 6, 4)
		env.FireWidgetUpdate()

		fw.eq(state.recordWins, 5, "the stale widget reading changes nothing")
		fw.eq(state.recordLosses, 1, "nor this")
	end)

	fw.it("once settled, a further score update changes nothing", function()
		reachFinalRound(4)
		env.SetBoard(5, 6)
		env.SetState(5) -- Complete
		env.FireScoreUpdate() -- settles the record at 5W-1L

		-- Without recordSettled, this board clears every check BoardWins runs, including the
		-- monotonic guard, and would silently move the record to 6W-0L.
		env.SetBoard(6, 6)
		env.FireScoreUpdate()

		fw.eq(state.recordWins, 5, "the settled record does not move again")
		fw.eq(state.recordLosses, 1, "held")
	end)

	fw.it("the settled record survives PVP_MATCH_COMPLETE and the widget set tearing down, and clears on leaving", function()
		reachFinalRound(4)
		env.SetBoard(5, 6)
		env.SetState(5) -- Complete
		env.FireScoreUpdate()

		env.Context.Mock.FireEvent("PVP_MATCH_COMPLETE")
		env.Widgets = {}
		env.FireWidgetUpdate()

		fw.eq(state.recordWins, 5, "still settled")
		fw.eq(state.recordLosses, 1, "both halves")

		env.Leave()

		fw.is_nil(state.recordWins, "cleared with the rest of the scope")
		fw.is_nil(state.recordLosses, "and the losses")
	end)

	fw.it("re-reads the widgets and the board on a reload at the results screen", function()
		reachFinalRound(4)
		env.SetBoard(5, 6)
		env.SetState(5) -- Complete
		env.FireScoreUpdate()

		env.Reload()
		env.FireScoreUpdate()

		local reloaded = env.Addon.MatchState.State

		fw.eq(reloaded.recordWins, 5, "read back off the widgets and the board")
		fw.eq(reloaded.recordLosses, 1, "with nothing persisted")
	end)

	fw.it("counts the widgets alone when the match is abandoned part way through, and never asks for the board", function()
		env.SetRecordWidgets(4, 6, 2)
		env.FireWidgetUpdate()
		env.SetBoard(9, 6) -- a full board present but never consulted
		env.SetState(5) -- Complete at round four

		fw.eq(state.recordWins, 2, "the widgets alone")
		fw.eq(state.recordLosses, 1, "three rounds played")
		fw.eq(env.ScoreRequests, 0, "the board is never asked for")
	end)

	fw.it("holds the five-round figure when the match is abandoned during the final round", function()
		reachFinalRound(2)
		env.SetBoard(2, 5) -- fifteen across five rounds, the sixth never credited

		env.SetState(5) -- Complete

		fw.eq(state.recordWins, 2, "the five-round figure")
		fw.eq(state.recordLosses, 3, "the abandoned final round is not counted")
	end)
end)

fw.describe("MiniDampen - dampening", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	fw.it("reads a whole percent from the commentator API", function()
		env.SetDampening(30)
		env.Tick(0.5)

		fw.eq(env.Addon.MatchState.State.dampening, 30, "GetDampeningPercent read straight through")
	end)

	fw.it("displays a reading of 0 as 0, distinct from no reading at all", function()
		env.SetDampening(0)
		env.Tick(0.5)

		fw.eq(env.Addon.MatchState.State.dampening, 0, "0 is a real reading before the display's own nil check")
	end)

	fw.it("is nil when the reading is secret", function()
		env.SetDampening(Arena.SECRET)
		env.Tick(0.5)

		fw.is_nil(env.Addon.MatchState.State.dampening, "a secret reading gives nil")
	end)

	fw.it("is nil when the reading is not a number", function()
		env.SetDampening("30")
		env.Tick(0.5)

		fw.is_nil(env.Addon.MatchState.State.dampening, "a non-number reading gives nil")
	end)

	fw.it("does not error and stays nil when the commentator API is absent from the client", function()
		env.RemoveCommentatorApi()

		fw.no_error(function()
			env.Tick(0.5)
		end, "missing C_Commentator")

		fw.is_nil(env.Addon.MatchState.State.dampening, "no API, nothing to display")
	end)

	fw.it("notifies on UNIT_AURA only when the dampening percent actually changes", function()
		env.SetDampening(30)
		env.Tick(0.5) -- establishes dampening = 30 through the poll, ahead of the assertions below

		local calls = 0
		env.Addon.MatchState.OnChanged = function()
			calls = calls + 1
		end

		env.Context.Mock.FireEvent("UNIT_AURA", "player")

		fw.eq(calls, 0, "no notify when the aura fires but the percent is unchanged")

		env.SetDampening(31)
		env.Context.Mock.FireEvent("UNIT_AURA", "player")

		fw.eq(calls, 1, "notifies once the percent actually moves")
	end)
end)

fw.describe("MiniDampen - the enemy denominator", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	fw.it("keeps a cleared opponent's entry, so teamSize stays the denominator", function()
		fw.eq(#env.Addon.MatchState.State.enemy, 3, "starts at three")

		env.Cleared("arena3")

		fw.eq(#env.Addon.MatchState.State.enemy, 3, "arena3's entry stays in place")
		fw.truthy(env.Addon.MatchState.State.enemy[3].Cleared, "flagged cleared")
	end)

	fw.it("reverses cleared when the same token is seen again", function()
		env.Cleared("arena3")
		env.Seen("arena3")

		fw.falsy(env.Addon.MatchState.State.enemy[3].Cleared, "seen reverses the clear")
	end)
end)

fw.describe("MiniDampen - team size derivation", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	fw.it("falls back to specs before any opponent token exists", function()
		-- The prep room: tokens haven't spawned yet, so opponents reads 0 and specs is the only
		-- early estimate available.
		env.Specs = 3
		env.Opponents = 0
		env.Enter()

		fw.eq(env.Addon.MatchState.State.teamSize, 3, "specs used as the early estimate")
	end)

	fw.it("clamps to three even if an API answers more", function()
		env.Specs = 0
		env.Opponents = 5
		env.Enter()

		fw.eq(env.Addon.MatchState.State.teamSize, 3, "clamped to the arena1..3 ceiling")
	end)

	fw.it("grows as opponent tokens are individually seen after the gates open", function()
		-- A bot arena: no queued bracket to broadcast a spec count, so the roster only grows as
		-- real tokens are confirmed one at a time.
		env.Specs = 0
		env.Opponents = 0
		env.Enter()

		fw.eq(env.Addon.MatchState.State.teamSize, 0, "nothing seen yet in the prep room")

		env.Opponents = 1
		env.Seen("arena1")
		fw.eq(env.Addon.MatchState.State.teamSize, 1, "grows to one as the first token is seen")

		env.Opponents = 2
		env.Seen("arena2")
		fw.eq(env.Addon.MatchState.State.teamSize, 2, "grows to two as the second token is seen")

		env.Opponents = 3
		env.Seen("arena3")
		fw.eq(env.Addon.MatchState.State.teamSize, 3, "grows to three as the third token is seen")
		fw.eq(#env.Addon.MatchState.State.enemy, 3, "enemy roster grew to match")
	end)

	fw.it("grows the ally roster, including the player, alongside teamSize, even though nothing enemy-side drives it", function()
		-- Before GrowAlly ran on every RefreshTeamSize call, BuildAlly built the ally array once
		-- at OpenScope with teamSize still 0 in the prep room, so the roster never grew again for
		-- the rest of the match even once teamSize itself climbed from enemy-only events.
		env.Specs = 0
		env.Opponents = 0
		env.Enter()

		fw.eq(#env.Addon.MatchState.State.ally, 0, "nothing to grow into yet in the prep room")

		env.Opponents = 1
		env.Seen("arena1")

		fw.eq(#env.Addon.MatchState.State.ally, 1, "ally roster grows in step with teamSize")
		fw.eq(env.Addon.MatchState.State.ally[1].Token, "player", "the player is the first ally slot")

		env.Opponents = 3
		env.Seen("arena2")

		fw.eq(#env.Addon.MatchState.State.ally, 3, "ally roster grew to match teamSize")
		fw.eq(env.Addon.MatchState.State.ally[2].Token, "party1", "second slot is party1")
		fw.eq(env.Addon.MatchState.State.ally[3].Token, "party2", "third slot is party2")
	end)

	fw.it("derives the team size from the player's own group when neither enemy-side count answers", function()
		-- The bot arena prep room the defect was reported from: both enemy-side counts read zero
		-- until the gates open, so the counts row sat at 0 vs 0 for the whole prep room.
		env.Specs = 0
		env.Opponents = 0
		env.Context.Mock.State.GroupMembers = 3
		env.Enter()

		fw.eq(env.Addon.MatchState.State.teamSize, 3, "the group stands in for the shared team size")
		fw.eq(#env.Addon.MatchState.State.enemy, 3, "enemy roster sized from it")
		fw.eq(#env.Addon.MatchState.State.ally, 3, "ally roster sized from it")
	end)

	fw.it("ratchets up as a still-loading teammate joins the group, and never back down", function()
		env.Specs = 0
		env.Opponents = 0
		env.Context.Mock.State.GroupMembers = 2
		env.Enter()

		fw.eq(env.Addon.MatchState.State.teamSize, 2, "only two members in the group so far")

		env.Context.Mock.State.GroupMembers = 3
		env.Context.Mock.FireEvent("GROUP_ROSTER_UPDATE")

		fw.eq(env.Addon.MatchState.State.teamSize, 3, "grows as the third member finishes loading")

		env.Context.Mock.State.GroupMembers = 2
		env.Context.Mock.FireEvent("GROUP_ROSTER_UPDATE")

		fw.eq(env.Addon.MatchState.State.teamSize, 3, "a member dropping out doesn't shrink the roster")
	end)

	fw.it("still takes the live opponent count once the gates open on a short group", function()
		env.Specs = 0
		env.Opponents = 0
		env.Context.Mock.State.GroupMembers = 2
		env.Enter()

		fw.eq(env.Addon.MatchState.State.teamSize, 2, "the short group is all there is in the prep room")

		env.Opponents = 3
		env.Seen("arena1")

		fw.eq(env.Addon.MatchState.State.teamSize, 3, "the opponent count outgrows the group reading")
		fw.eq(#env.Addon.MatchState.State.enemy, 3, "enemy roster grew to match")
	end)

	fw.it("clamps an over-large group to the arena1..3 ceiling", function()
		env.Specs = 0
		env.Opponents = 0
		env.Context.Mock.State.GroupMembers = 5
		env.Enter()

		fw.eq(env.Addon.MatchState.State.teamSize, 3, "clamped to the arena1..3 ceiling")
		fw.eq(#env.Addon.MatchState.State.enemy, 3, "no fourth enemy slot with no token behind it")
	end)

	fw.it("never shrinks the roster once a higher team size has been confirmed", function()
		env.Specs = 3
		env.Opponents = 3
		env.Enter()

		fw.eq(env.Addon.MatchState.State.teamSize, 3, "starts at three, all opponents already visible")

		-- A transient undercount, the kind GROUP_ROSTER_UPDATE can report mid-fight without any
		-- opponent actually having left.
		env.Opponents = 2
		env.Context.Mock.FireEvent("GROUP_ROSTER_UPDATE")

		fw.eq(env.Addon.MatchState.State.teamSize, 3, "the high-water mark holds, the roster doesn't shrink")
		fw.eq(#env.Addon.MatchState.State.enemy, 3, "enemy roster still sized to three")
	end)

	fw.it("re-derives after a mid-match reload, so a token not yet visible again isn't lost", function()
		env.Specs = 3
		env.Opponents = 3
		env.Enter()

		fw.eq(env.Addon.MatchState.State.teamSize, 3, "all three opponents visible before the reload")

		-- Simulates a real /reload: fresh Lua state, but the client hasn't reported arena3's
		-- token back to the API yet.
		env.Opponents = 2
		env.Reload()

		fw.eq(env.Addon.MatchState.State.teamSize, 2, "only two opponents visible immediately after the reload")

		env.Opponents = 3
		env.Seen("arena3")

		fw.eq(env.Addon.MatchState.State.teamSize, 3, "climbs back to three as the missing token is seen")
		fw.eq(#env.Addon.MatchState.State.enemy, 3, "enemy roster grew back to three")
		fw.eq(env.Addon.MatchState.State.enemy[3].Token, "arena3", "the third slot is the token that was just seen")
	end)
end)

fw.describe("MiniDampen - the ally roster", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	fw.it("keeps an ally's entry when its token stops resolving, so teamSize stays the denominator", function()
		fw.eq(#env.Addon.MatchState.State.ally, 3, "starts with three allies")

		env.Exists.party2 = false
		env.Context.Mock.FireEvent("GROUP_ROSTER_UPDATE")

		fw.eq(#env.Addon.MatchState.State.ally, 3, "party2's entry stays in place")
		fw.truthy(env.Addon.MatchState.State.ally[3].Cleared, "flagged cleared")
	end)

	fw.it("reverses cleared when the same ally is seen again in the roster", function()
		env.Exists.party2 = false
		env.Context.Mock.FireEvent("GROUP_ROSTER_UPDATE")

		env.Exists.party2 = true
		env.Context.Mock.FireEvent("GROUP_ROSTER_UPDATE")

		fw.falsy(env.Addon.MatchState.State.ally[3].Cleared, "roster update reverses the clear")
	end)

	fw.it("sets DeathSecret rather than assuming a kill when an ally's death read comes back secret", function()
		env.MarkDeathSecret("player")
		env.Tick(0.5)

		local entry = env.Addon.MatchState.State.ally[1]

		-- Alive already defaults true at GrowAlly, so this alone would pass even without the
		-- guard: the SECRET sentinel's dead ~= true never raises or resolves equal against a
		-- plain boolean, so it happens to "fail open" by accident in this mock too. DeathSecret
		-- has no such default, so it is the assertion that actually proves the guard ran.
		fw.truthy(entry.Alive, "never assumes a kill from an unreadable read")
		fw.truthy(entry.DeathSecret, "set so the display can say this entry's fate is unreadable")
	end)

	fw.it("clears DeathSecret again once a later death read for the same ally comes back readable", function()
		env.MarkDeathSecret("player")
		env.Tick(0.5)

		fw.truthy(env.Addon.MatchState.State.ally[1].DeathSecret, "secret on the first read")

		env.SecretDeaths.player = false
		env.Tick(0.5)

		fw.falsy(env.Addon.MatchState.State.ally[1].DeathSecret, "cleared by the next readable poll, not left latched")
	end)
end)
