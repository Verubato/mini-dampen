-- MatchState.lua never draws anything, so these drive it entirely through tests/Helpers/Arena.lua
-- and read back state.ally, state.enemy, state.roundIndex, and state.roundResults.

local fw = require("TestFramework")
local Arena = require("Arena")

local GATED_EVENT_COUNT = 6

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

	fw.it("registers exactly the six gated events and one ticker on entering", function()
		env.Enter()

		local frame = gatedFrame(env)

		fw.not_nil(frame, "the gated frame registered ARENA_OPPONENT_UPDATE")
		fw.eq(countEvents(frame), GATED_EVENT_COUNT, "event count")
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

	fw.it("closes scope once the match reaches Complete, not only Inactive", function()
		env.Enter()
		env.SetState(2) -- StartUp
		env.SetState(3) -- Engaged
		env.SetWinner(0)
		env.SetState(4) -- PostRound
		env.SetState(5) -- Complete

		fw.falsy(env.Addon.MatchState.State.inScope, "closed once the results screen is up")
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

	fw.it("marks a destroyed opponent dead immediately, even while its own death read stays secret", function()
		env.MarkDeathSecret("arena3")
		env.Destroyed("arena3")

		local entry = env.Addon.MatchState.State.enemy[3]

		fw.eq(entry.Alive, false, "destroyed sets Alive directly, not only through the poll")
		fw.truthy(entry.EverDead, "also latches EverDead")
	end)
end)

fw.describe("MiniDampen - round settling", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	local function startRound()
		env.SetState(2) -- StartUp
		env.SetState(3) -- Engaged
	end

	fw.it("records a win when the winner API answers the player's faction, loss for the other", function()
		startRound()
		env.SetWinner(0)
		env.SetState(4) -- PostRound

		fw.eq(env.Addon.MatchState.State.roundResults[1], "win", "own faction wins")

		env.SetState(2)
		env.SetState(3)
		env.SetWinner(1)
		env.SetState(4)

		fw.eq(env.Addon.MatchState.State.roundResults[2], "loss", "other faction loses")
	end)

	fw.it("falls back to the corpse latch when the winner API answers neither faction", function()
		startRound()
		env.SetWinner(nil)
		env.Kill("arena1")
		env.Kill("arena2")
		env.Kill("arena3")
		env.Tick(0.5)
		env.SetState(4)

		fw.eq(env.Addon.MatchState.State.roundResults[1], "win", "every enemy latched dead")

		-- Corpses release between rounds, so the mock's death table has to be cleared the same
		-- way or round two would inherit round one's kills.
		env.Deaths = {}

		env.SetState(2)
		env.SetState(3)
		env.SetWinner(nil)
		env.Kill("player")
		env.Kill("party1")
		env.Kill("party2")
		env.Tick(0.5)
		env.SetState(4)

		fw.eq(env.Addon.MatchState.State.roundResults[2], "loss", "every ally latched dead")
	end)

	fw.it("settles unknown when an enemy clears before dying", function()
		startRound()
		env.SetWinner(nil)
		env.Kill("arena1")
		env.Kill("arena2")
		env.Tick(0.5)
		env.Cleared("arena3")
		env.SetState(4)

		fw.eq(env.Addon.MatchState.State.roundResults[1], "unknown", "arena3 never latched dead")
	end)

	fw.it("settles unknown when the winner API disagrees with a conclusive corpse latch", function()
		startRound()
		env.SetWinner(1) -- claims the enemy won
		env.Kill("arena1")
		env.Kill("arena2")
		env.Kill("arena3")
		env.Tick(0.5) -- every enemy latched dead: the corpse latch says the player's side won
		env.SetState(4)

		fw.eq(env.Addon.MatchState.State.roundResults[1], "unknown", "winner and corpse latch conclusively disagree")
	end)

	fw.it("never settles a win from a bare nil == nil when both winner and mine are unknown", function()
		env.MyFaction = nil
		startRound()
		env.SetWinner(nil)
		env.SetState(4)

		fw.neq(env.Addon.MatchState.State.roundResults[1], "win", "mine is nil, winner can't be trusted either way")
	end)

	fw.it("clears everDead on the next StartUp", function()
		startRound()
		env.Kill("arena1")
		env.Tick(0.5)

		fw.eq(env.Addon.MatchState.State.enemy[1].EverDead, true, "latched dead before the clear")

		env.SetState(4)
		env.SetState(2)
		env.SetState(3)

		fw.eq(env.Addon.MatchState.State.enemy[1].EverDead, false, "round two starts clean")
	end)

	fw.it("leaves roundIndex nil when entering already Engaged with nothing to adopt", function()
		-- A fresh env for this one: the shared before_each already entered at the default
		-- Waiting state, and this case is specifically about never having observed StartUp.
		local fresh = Arena.Build()
		fresh.MatchState = 3 -- Engaged, with no StartUp edge ever seen
		fresh.Enter()

		fw.is_nil(fresh.Addon.MatchState.State.roundIndex, "nothing to adopt, no StartUp edge seen")
	end)

	fw.it("does not error when a round edge follows PVP_MATCH_COMPLETE before scope closes", function()
		startRound()
		env.SetWinner(0)
		env.SetState(4) -- PostRound, round one settles

		env.Context.Mock.FireEvent("PVP_MATCH_COMPLETE")

		fw.no_error(function()
			startRound() -- StartUp -> Engaged again, before EvaluateGate has closed scope
			env.SetWinner(0)
			env.SetState(4) -- PostRound, settling with db.ActiveMatch already nil
		end, "round activity after PVP_MATCH_COMPLETE, before the scope closes")
	end)
end)

fw.describe("MiniDampen - the reload key", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	-- Reload() re-runs every Lua file, and MatchState:Init() re-evaluates the gate as its last
	-- step, so a reload while env.InArena is still true reopens scope and adopts on its own,
	-- the way a real /reload does. None of these need a fresh Enter() afterward.
	fw.it("round-trips a reload: two rounds settle, then roundIndex and roundResults survive", function()
		env.Enter()
		env.SetState(2)
		env.SetState(3)
		env.SetWinner(0)
		env.SetState(4)
		env.SetState(2)
		env.SetState(3)
		env.SetWinner(0)
		env.SetState(4)

		env.Reload()

		fw.eq(env.Addon.MatchState.State.roundIndex, 2, "round index survived")
		fw.eq(env.Addon.MatchState.State.roundResults[1], "win", "round one survived")
		fw.eq(env.Addon.MatchState.State.roundResults[2], "win", "round two survived")
	end)

	-- GetActiveMatchDuration is a time_t, so the pre-reload and post-reload computations of
	-- time() - duration can land a second or two apart even for the same match. MatchStartEpoch
	-- stands in directly for that computed instant, since duration is derived from it and a
	-- shift in one shifts the other by exactly as much.
	fw.it("still adopts when the computed start instant moved on by two seconds, inside MATCH_KEY_TOLERANCE", function()
		env.Enter()
		env.SetState(2)
		env.SetState(3)
		env.SetWinner(0)
		env.SetState(4)

		env.MatchStartEpoch = env.MatchStartEpoch + 2
		env.Reload()

		fw.eq(env.Addon.MatchState.State.roundIndex, 1, "adopted despite the two second drift")
	end)

	fw.it("round index survives a reload mid-round-3, before that round settles", function()
		env.Enter()
		env.SetState(2) -- StartUp, round one
		env.SetState(3) -- Engaged
		env.SetWinner(0)
		env.SetState(4) -- PostRound, round one settles
		env.SetState(2) -- StartUp, round two
		env.SetState(3) -- Engaged
		env.SetWinner(0)
		env.SetState(4) -- PostRound, round two settles
		env.SetState(2) -- StartUp, round three
		env.SetState(3) -- Engaged, round three is current and has not settled

		env.Reload()

		fw.eq(env.Addon.MatchState.State.roundIndex, 3, "round index is written on increment, not only at settle")
		fw.eq(env.Addon.MatchState.State.roundResults[1], "win", "round one survived")
		fw.eq(env.Addon.MatchState.State.roundResults[2], "win", "round two survived")
		fw.is_nil(env.Addon.MatchState.State.roundResults[3], "round three has not settled yet")
	end)

	fw.it("discards the saved record when the instance id differs beyond tolerance", function()
		env.Enter()
		env.SetState(2)
		env.SetState(3)
		env.SetWinner(0)
		env.SetState(4)

		env.InstanceId = env.InstanceId + 1
		env.Reload()

		fw.is_nil(env.Addon.MatchState.State.roundIndex, "a different instance id is a different match")
	end)

	fw.it("discards the saved record when the bracket differs beyond tolerance", function()
		env.Enter()
		env.SetState(2)
		env.SetState(3)
		env.SetWinner(0)
		env.SetState(4)

		env.Bracket = env.Bracket + 1
		env.Reload()

		fw.is_nil(env.Addon.MatchState.State.roundIndex, "a different bracket is a different match")
	end)

	fw.it("discards the saved record when StartedAt differs beyond tolerance", function()
		env.Enter()
		env.SetState(2)
		env.SetState(3)
		env.SetWinner(0)
		env.SetState(4)

		env.MatchStartEpoch = env.MatchStartEpoch + 30
		env.Reload()

		fw.is_nil(env.Addon.MatchState.State.roundIndex, "a match starting 30 seconds later is a different match")
	end)

	fw.it("clears db.ActiveMatch on leaving, so a later login outside an arena finds nothing", function()
		env.Enter()
		env.SetState(2)
		env.SetState(3)
		env.SetWinner(0)
		env.SetState(4)

		env.Leave()

		fw.is_nil(_G.MiniDampenDB.ActiveMatch, "cleared on leaving")

		env.Reload()

		fw.is_nil(_G.MiniDampenDB.ActiveMatch, "still nothing to adopt outside an arena")
	end)
end)

fw.describe("MiniDampen - dampening", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	fw.it("reads a whole percent from points[1]", function()
		env.SetDampening(30)
		env.Tick(0.5)

		fw.eq(env.Addon.MatchState.State.dampening, 30, "points[1] read straight through")
	end)

	fw.it("is nil when the aura is absent", function()
		env.SetDampening(nil)
		env.Tick(0.5)

		fw.is_nil(env.Addon.MatchState.State.dampening, "no aura, no dampening")
	end)

	fw.it("is nil when the point value is secret", function()
		env.SetDampening(Arena.SECRET)
		env.Tick(0.5)

		fw.is_nil(env.Addon.MatchState.State.dampening, "a secret point value gives nil")
	end)

	fw.it("does not error and stays nil when the whole aura is secret", function()
		env.SetAuraSecret(true)

		fw.no_error(function()
			env.Tick(0.5)
		end, "secret aura read")

		fw.is_nil(env.Addon.MatchState.State.dampening, "a secret aura gives nil")
	end)

	fw.it("does not error and stays nil when the points field itself is secret", function()
		env.SetPointsSecret(true)

		fw.no_error(function()
			env.Tick(0.5)
		end, "secret points read")

		fw.is_nil(env.Addon.MatchState.State.dampening, "secret points gives nil")
	end)

	fw.it("is nil when the point value is not a number", function()
		env.SetDampening("30")
		env.Tick(0.5)

		fw.is_nil(env.Addon.MatchState.State.dampening, "a non-number point value gives nil")
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
		fw.truthy(entry.DeathSecret, "set so Debug() and the display can say this entry's fate is unreadable")
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

fw.describe("MiniDampen - Debug()", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	local function FindLine(lines, needle)
		for _, line in ipairs(lines) do
			if line:find(needle, 1, true) then
				return line
			end
		end
	end

	fw.it("names the API values a team size was derived from", function()
		env.Specs = 3
		env.Opponents = 2
		env.Enter()

		local line = FindLine(env.Addon.MatchState:Debug(), "teamSize=")

		fw.truthy(line:find("GetNumArenaOpponents=2", 1, true) ~= nil, "raw opponents value present")
		fw.truthy(line:find("GetNumArenaOpponentSpecs=3", 1, true) ~= nil, "raw specs value present")
	end)

	fw.it("names the raw GetActiveMatchBracket value beside the other team-size sources", function()
		env.Bracket = 4
		env.Enter()

		local line = FindLine(env.Addon.MatchState:Debug(), "teamSize=")

		fw.truthy(line:find("GetActiveMatchBracket=4", 1, true) ~= nil, "raw bracket value present")
	end)

	fw.it("doesn't error when GetActiveMatchBracket is missing from the client", function()
		env.Enter()
		_G.C_PvP.GetActiveMatchBracket = nil

		local line = FindLine(env.Addon.MatchState:Debug(), "teamSize=")

		fw.truthy(line:find("GetActiveMatchBracket=nil", 1, true) ~= nil, "guarded call falls back to nil rather than erroring")
	end)

	fw.it("lists every tracked token with its alive, hidden, cleared, and everDead state", function()
		env.Enter()
		env.Kill("arena1")
		env.Unseen("arena2")
		env.Tick(2)

		local lines = env.Addon.MatchState:Debug()

		local dead = FindLine(lines, "enemy arena1")
		local hidden = FindLine(lines, "enemy arena2")

		fw.truthy(dead:find("alive=false", 1, true) ~= nil, "arena1 reported dead")
		fw.truthy(dead:find("everDead=true", 1, true) ~= nil, "arena1's death latched")
		fw.truthy(hidden:find("hidden=true", 1, true) ~= nil, "arena2 reported hidden after the expiry delay")
	end)

	fw.it("flags an enemy's death read as secret in its Debug() line too, not just an ally's", function()
		env.Enter()
		env.MarkDeathSecret("arena1")
		env.Tick(0.5)

		local line = FindLine(env.Addon.MatchState:Debug(), "enemy arena1")

		fw.truthy(line:find("deathSecret=true", 1, true) ~= nil, "enemy arena1's unreadable death read is surfaced")
	end)

	fw.it("reports a secret aura without reading through it", function()
		env.Enter()
		env.SetAuraSecret(true)

		local line = FindLine(env.Addon.MatchState:Debug(), "dampening ")

		fw.truthy(line:find("auraSecret=true", 1, true) ~= nil, "flags the aura itself as secret")
		fw.truthy(line:find("rawValue=nil", 1, true) ~= nil, "never indexed into the secret aura for a raw value")
		fw.truthy(line:find("auraFound=secret", 1, true) ~= nil, "can't even tell whether the aura is applied, distinct from finding none")
	end)

	fw.it("reports auraFound=no before dampening has ever been applied, distinct from an unreadable aura", function()
		env.Enter()

		local line = FindLine(env.Addon.MatchState:Debug(), "dampening ")

		fw.truthy(line:find("auraFound=no", 1, true) ~= nil, "no aura yet is not the same reading as an unreadable one")
	end)

	fw.it("reports auraFound=yes once the dampening aura is actually applied", function()
		env.Enter()
		env.SetDampening(25)
		env.Tick(0.5)

		local line = FindLine(env.Addon.MatchState:Debug(), "dampening ")

		fw.truthy(line:find("auraFound=yes", 1, true) ~= nil, "aura present and readable")
	end)

	fw.it("routes every Debug() field through SafeString, so a secret value is never interpolated raw", function()
		env.Enter()
		-- Bypasses the normal read path, which never stores a secret value in state, to prove
		-- the formatting itself is safe regardless of how a secret got there.
		env.Addon.MatchState.State.dampening = Arena.SECRET

		local line = FindLine(env.Addon.MatchState:Debug(), "dampening displayed=")

		fw.truthy(line:find("displayed=secret", 1, true) ~= nil, "rendered as \"secret\" rather than tostring'd or indexed")
	end)

	fw.it("tells a live reading from the unlocked sample preview", function()
		env.Enter()
		env.SetDampening(25)
		env.Tick(0.5)

		fw.truthy(FindLine(env.Addon.MatchState:Debug(), "onScreenValues=live") ~= nil, "live while locked and in scope")

		_G.MiniDampenDB.Locked = false

		fw.truthy(FindLine(env.Addon.MatchState:Debug(), "onScreenValues=sample") ~= nil, "sample once unlocked")
	end)
end)
