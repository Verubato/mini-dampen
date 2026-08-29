-- Arena API stubs the shared mock (build/Lua/WowMock.lua) does not carry, plus test controls
-- for them. Nothing under build/ is edited; this is the addon-specific extension point the
-- fleet's other test suites use the same way (see MiniResourceDisplay/tests/Helpers/Env.lua).

local harness = require("AddonHarness")

local M = {}

-- Identity marker for a value the addon must treat as secret. Indexing it raises, so code
-- that indexes this before checking issecretvalue fails the test instead of quietly reading
-- through it. No __eq or __lt: Lua 5.1 only invokes __eq when both operands share the same
-- handler, so a comparison against a plain value never reaches one anyway.
M.SECRET = setmetatable({}, {
	__index = function()
		error("indexed a secret value before checking issecretvalue", 2)
	end,
})

---(Re)installs every override this addon's WoW API surface needs onto the mocked globals.
---Called once after the initial load and again after every simulated Reload, because
---WowMock.Install() replaces _G.C_PvP, _G.C_UnitAuras, _G.Enum and friends with fresh tables.
local function InstallOverrides(env)
	-- Real values rather than the mock's auto-vivifying members in first-access order, so a
	-- comparison against Enum.PvPMatchState.PostRound and friends resolves the same way here
	-- as it does in game.
	_G.Enum.PvPMatchState = {
		Inactive = 0,
		Waiting = 1,
		StartUp = 2,
		Engaged = 3,
		PostRound = 4,
		Complete = 5,
	}

	-- Real values, so the probe's reverse lookup from a widget's type to its getter name
	-- resolves the way it does in game rather than against an auto-vivified empty group.
	_G.Enum.UIWidgetVisualizationType = {
		IconAndText = 0,
		CaptureBar = 1,
		StatusBar = 2,
	}

	_G.GetTime = function()
		return env.Time
	end

	-- Independently controllable from GetTime, the way a wall clock is independent of client
	-- uptime: a reload advances both, but only time() is meant to survive one.
	_G.time = function()
		return env.Epoch
	end

	_G.IsInInstance = function()
		return env.InArena, env.InArena and "arena" or "none"
	end

	_G.GetInstanceInfo = function()
		return "Test Arena", env.InArena and "arena" or "none", 0, "", 0, 0, false, env.InstanceId, 0, 0
	end

	_G.GetNumArenaOpponentSpecs = function()
		return env.Specs
	end

	_G.GetNumArenaOpponents = function()
		return env.Opponents
	end

	_G.GetBattlefieldArenaFaction = function()
		return env.MyFaction
	end

	_G.UnitExists = function(unit)
		return env.Exists[unit] == true
	end

	_G.UnitIsDeadOrGhost = function(unit)
		if env.SecretDeaths[unit] then
			return M.SECRET
		end

		return env.Deaths[unit] == true
	end

	_G.UnitIsFeignDeath = function(unit)
		if env.SecretFeigns[unit] then
			return M.SECRET
		end

		return env.Feigns[unit] == true
	end

	-- rawequal, so this never depends on whether some other test value carries its own __eq.
	_G.issecretvalue = function(value)
		return rawequal(value, M.SECRET)
	end

	_G.C_UnitAuras.GetPlayerAuraBySpellID = function()
		if env.AuraSecret then
			return M.SECRET
		end

		if env.PointsSecret then
			return { points = M.SECRET }
		end

		if env.Dampening == nil then
			return nil
		end

		return { points = { env.Dampening } }
	end

	-- Slot numbers are the index into env.Auras[filter], so the probe's two-call enumeration
	-- lands back on the same list the test authored.
	_G.C_UnitAuras.GetAuraSlots = function(_, filter)
		local auras = env.Auras[filter]

		if not auras then
			return nil
		end

		return nil, unpack(auras.Slots)
	end

	_G.C_UnitAuras.GetAuraDataBySlot = function(_, slot)
		for _, auras in pairs(env.Auras) do
			if auras.BySlot[slot] then
				return auras.BySlot[slot]
			end
		end
	end

	_G.C_UIWidgetManager = {
		GetTopCenterWidgetSetID = function()
			return env.WidgetSetId
		end,
		GetAllWidgetsBySetID = function()
			return env.Widgets
		end,
		GetIconAndTextWidgetVisualizationInfo = function()
			return env.WidgetInfo
		end,
	}

	_G.C_Commentator = {
		GetDampeningPercent = function()
			if env.CommentatorRefuses then
				error("commentator only")
			end

			return env.CommentatorDampening
		end,
	}

	_G.C_PvP.IsSoloShuffle = function()
		return env.SoloShuffle
	end

	_G.C_PvP.IsMatchConsideredArena = function()
		return env.InArena
	end

	_G.C_PvP.IsMatchActive = function()
		return env.MatchState == _G.Enum.PvPMatchState.Engaged
	end

	_G.C_PvP.IsMatchComplete = function()
		return env.MatchState == _G.Enum.PvPMatchState.Complete
	end

	_G.C_PvP.GetActiveMatchState = function()
		return env.MatchState
	end

	_G.C_PvP.GetActiveMatchWinner = function()
		return env.Winner
	end

	_G.C_PvP.GetActiveMatchBracket = function()
		return env.Bracket
	end

	-- Derived from the clock rather than a field of its own, so advancing time during a
	-- simulated reload keeps duration and time() moving together the way a real match does.
	_G.C_PvP.GetActiveMatchDuration = function()
		return env.Epoch - env.MatchStartEpoch
	end

	local realNewTicker = _G.C_Timer.NewTicker

	-- WowMock stores its own ticker list privately and never drains it, so the callback has to
	-- be captured here for Tick() to invoke on demand.
	_G.C_Timer.NewTicker = function(interval, callback)
		local ticker = realNewTicker(interval, callback)
		env.Tickers[#env.Tickers + 1] = { Ticker = ticker, Callback = callback }
		return ticker
	end
end

---Builds a client with MiniDampen loaded and logged in, out of an arena, and hands back the
---environment plus the controls that drive it through a match.
---@return table env
function M.Build()
	-- harness.Load preserves declared saved variables across calls, the way a real client
	-- carries them across a reload. A fresh Build() is a new test, not a reload, so it has to
	-- start clean or one test's saved-variable writes would leak into the next.
	_G.MiniDampenDB = nil

	local context = harness.Load("MiniDampen")

	local env = {
		Context = context,
		Addon = context.Addon,
		Time = 10000,
		Epoch = 1700000000,
		MatchStartEpoch = 1700000000,
		InArena = false,
		MatchState = 1, -- Waiting, so a bare Enter() opens scope without implying StartUp
		-- Independently controllable, the way the two real APIs can disagree: specs is an early
		-- estimate that can be wrong, opponents counts real tokens once they exist.
		Specs = 3,
		Opponents = 3,
		SoloShuffle = false,
		MyFaction = 0,
		Winner = nil,
		Bracket = 1,
		InstanceId = 1,
		NextAuraSlot = 0,
		Dampening = nil,
		AuraSecret = false,
		PointsSecret = false,
		Deaths = {},
		SecretDeaths = {},
		Feigns = {},
		SecretFeigns = {},
		Auras = {},
		WidgetSetId = 0,
		Widgets = {},
		WidgetInfo = nil,
		CommentatorDampening = nil,
		CommentatorRefuses = false,
		Exists = { player = true, party1 = true, party2 = true, arena1 = true, arena2 = true, arena3 = true },
		Tickers = {},
	}

	InstallOverrides(env)
	harness.Login(context)

	-- Leaves env.MatchState as whatever the test already set it to, defaulting to Waiting, so a
	-- test can enter already Engaged without a StartUp edge ever having been observed.
	function env.Enter()
		env.InArena = true
		env.MatchStartEpoch = env.Epoch
		context.Mock.FireEvent("PLAYER_ENTERING_WORLD", true, false)
	end

	function env.Leave()
		env.InArena = false
		context.Mock.FireEvent("PLAYER_ENTERING_WORLD", true, false)
	end

	function env.SetState(state)
		env.MatchState = state
		context.Mock.FireEvent("PVP_MATCH_STATE_CHANGED")
	end

	function env.Kill(token)
		env.Deaths[token] = true
	end

	---A feigning hunter reads dead to UnitIsDeadOrGhost, so this sets both the way the client
	---does rather than standing in for a death on its own.
	function env.Feign(token)
		env.Deaths[token] = true
		env.Feigns[token] = true
	end

	---Ends the feign while the unit stays down, which is what a real death after a feign looks
	---like from the addon's side.
	function env.StopFeigning(token)
		env.Feigns[token] = nil
		env.SecretFeigns[token] = nil
	end

	---Publishes one aura on the player under a filter, so /minidampen probe's slot enumeration
	---has something to walk.
	function env.AddAura(filter, aura)
		local auras = env.Auras[filter]

		if not auras then
			auras = { Slots = {}, BySlot = {} }
			env.Auras[filter] = auras
		end

		local slot = (env.NextAuraSlot or 0) + 1
		env.NextAuraSlot = slot

		auras.Slots[#auras.Slots + 1] = slot
		auras.BySlot[slot] = aura
	end

	---Marks a token's next death read as secret rather than a real boolean.
	function env.MarkDeathSecret(token)
		env.SecretDeaths[token] = true
	end

	function env.Unseen(token)
		context.Mock.FireEvent("ARENA_OPPONENT_UPDATE", token, "unseen")
	end

	function env.Seen(token)
		context.Mock.FireEvent("ARENA_OPPONENT_UPDATE", token, "seen")
	end

	function env.Cleared(token)
		context.Mock.FireEvent("ARENA_OPPONENT_UPDATE", token, "cleared")
	end

	function env.Destroyed(token)
		context.Mock.FireEvent("ARENA_OPPONENT_UPDATE", token, "destroyed")
	end

	function env.SetWinner(faction)
		env.Winner = faction
	end

	function env.SetDampening(value)
		env.Dampening = value
	end

	---Makes the next GetPlayerAuraBySpellID call return the aura table itself as secret.
	function env.SetAuraSecret(value)
		env.AuraSecret = value
	end

	---Makes the next GetPlayerAuraBySpellID call return an aura whose points field is secret,
	---distinct from a secret points[1].
	function env.SetPointsSecret(value)
		env.PointsSecret = value
	end

	---Simulates a /reload: fresh Lua state, saved variables preserved, everything else the
	---addon reads from the mock has to be wired back up because WowMock.Install() replaces it.
	function env.Reload()
		env.Tickers = {}

		context = harness.Load("MiniDampen")
		env.Context = context
		env.Addon = context.Addon

		InstallOverrides(env)
		harness.Login(context)
	end

	---Advances both clocks together and drains every timer and ticker, standing in for one
	---frame of real play.
	function env.Tick(seconds)
		env.Time = env.Time + (seconds or 0)
		env.Epoch = env.Epoch + (seconds or 0)

		for _, entry in ipairs(env.Tickers) do
			if not entry.Ticker:IsCancelled() then
				entry.Callback()
			end
		end

		context.Mock.RunTimers()
	end

	return env
end

return M
