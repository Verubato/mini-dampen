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
end)
