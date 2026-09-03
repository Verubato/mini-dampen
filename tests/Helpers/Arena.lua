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

-- What the shared mock's UnitName("player") answers, so a scoreboard row can be authored to
-- match the player.
M.PLAYER_NAME = "Tester"

-- The ids the two record widgets were captured under in a live shuffle, which is what the
-- addon's own tie-break keys on.
M.ROUND_WIDGET_ID = 3521
M.WINS_WIDGET_ID = 4457

---A LibStub stand-in carrying only LibSharedMedia-3.0, backed by env.Media so a test can
---register a font the way another addon's media pack would, without vendoring the real library.
---@param env table
local function LibStubMock(env)
	local media = {
		List = function(_, mediaType)
			local names = {}

			if mediaType ~= "font" then
				return names
			end

			for name in pairs(env.Media) do
				names[#names + 1] = name
			end

			table.sort(names)

			return names
		end,
		IsValid = function(_, mediaType, name)
			return mediaType == "font" and env.Media[name] ~= nil
		end,
		Fetch = function(_, mediaType, name)
			return mediaType == "font" and env.Media[name] or nil
		end,
		-- CallbackHandler's own signature: called with the target first, not with a colon.
		RegisterCallback = function(target, event, callback)
			local list = env.MediaCallbacks[event]

			if list then
				list[#list + 1] = callback
			end
		end,
	}

	local stub = setmetatable({}, {
		__call = function(_, name, silent)
			if name == "LibSharedMedia-3.0" then
				return media
			end

			if not silent then
				error("no such library: " .. tostring(name))
			end

			return nil
		end,
	})

	-- Dropdown.lua's legacy fallback path calls LibStub:GetLibrary(...), not LibStub(...).
	function stub:GetLibrary(name, silent)
		return stub(name, silent)
	end

	return stub
end

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

	-- Real values, so a comparison against Enum.UIWidgetVisualizationType.IconAndText
	-- resolves the same way here as it does in game.
	_G.Enum.UIWidgetVisualizationType = {
		IconAndText = 0,
		CaptureBar = 1,
		StatusBar = 2,
		TextWithState = 8,
	}

	-- Real values, so the record read's visibility gate compares against the same numbers
	-- Blizzard's own IconAndText template does.
	_G.Enum.IconAndTextWidgetState = {
		Hidden = 0,
		Shown = 1,
		ShownWithDynamicIconFlashing = 2,
		ShownWithDynamicIconNotFlashing = 3,
	}

	_G.LibStub = LibStubMock(env)

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

	_G.GetNumArenaOpponentSpecs = function()
		return env.Specs
	end

	_G.GetNumArenaOpponents = function()
		return env.Opponents
	end

	_G.UnitExists = function(unit)
		return env.Exists[unit] == true
	end

	_G.UnitIsDeadOrGhost = function(unit)
		if env.SecretDeaths[unit] then
			return M.SECRET
		end

		-- A token that does not resolve answers nil rather than false, matching the real client.
		if not env.Exists[unit] then
			return nil
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

	_G.C_UIWidgetManager = {
		GetTopCenterWidgetSetID = function()
			return env.WidgetSetId
		end,
		GetAllWidgetsBySetID = function()
			if env.SecretWidgetList then
				return M.SECRET
			end

			return env.Widgets
		end,
		GetIconAndTextWidgetVisualizationInfo = function(widgetId)
			return env.WidgetInfoById[widgetId]
		end,
	}

	_G.C_Commentator = {
		GetDampeningPercent = function()
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

	_G.C_PvP.GetActiveMatchBracket = function()
		return env.Bracket
	end

	_G.GetNumBattlefieldScores = function()
		return #env.Scores
	end

	-- The stat carrying round wins sits at index 1, under an id that differs between matches,
	-- so the row is shaped by position here too.
	_G.C_PvP.GetScoreInfo = function(index)
		local row = env.Scores[index]

		if not row then
			return nil
		end

		if row.Secret then
			return M.SECRET
		end

		if row.NoStats then
			return { name = row.Name }
		end

		return { name = row.Name, stats = { { pvpStatValue = row.Wins } } }
	end

	_G.RequestBattlefieldScoreData = function()
		env.ScoreRequests = env.ScoreRequests + 1
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

---Builds a client with MiniDampen loaded, out of an arena, and hands back the
---environment plus the controls that drive it through a match.
---@param options table? SkipLogin stops before the modules initialise
---@return table env
function M.Build(options)
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
		InArena = false,
		MatchState = 1, -- Waiting, so a bare Enter() opens scope without implying StartUp
		-- Independently controllable, the way the two real APIs can disagree: specs is an early
		-- estimate that can be wrong, opponents counts real tokens once they exist.
		Specs = 3,
		Opponents = 3,
		SoloShuffle = false,
		Bracket = 1,
		-- One row per player, each { Name = "...", Wins = 2 }, in the order GetScoreInfo hands
		-- them out.
		Scores = {},
		-- Counts every RequestBattlefieldScoreData call, so a test can prove the match asked
		-- the server for its board exactly once.
		ScoreRequests = 0,
		Deaths = {},
		SecretDeaths = {},
		Feigns = {},
		SecretFeigns = {},
		WidgetSetId = 0,
		Widgets = {},
		-- Widget id -> its own visualization info.
		WidgetInfoById = {},
		SecretWidgetList = false,
		CommentatorDampening = nil,
		Exists = { player = true, party1 = true, party2 = true, arena1 = true, arena2 = true, arena3 = true },
		Tickers = {},
		-- Font name -> file, standing in for whatever another addon has registered with
		-- LibSharedMedia-3.0 this session.
		Media = {},
		-- Event name -> list of callbacks, standing in for CallbackHandler's own registry.
		MediaCallbacks = { LibSharedMedia_Registered = {}, LibSharedMedia_SetGlobal = {} },
	}

	InstallOverrides(env)

	if not (options and options.SkipLogin) then
		harness.Login(context)
	end

	---Fires LibSharedMedia_Registered synchronously, the way the real library fires once per
	---entry, so a media pack registering several fonts in one frame is a test calling this
	---several times before the next env.Tick.
	function env.RegisterFont(name, file)
		env.Media[name] = file

		for _, callback in ipairs(env.MediaCallbacks.LibSharedMedia_Registered) do
			callback("LibSharedMedia_Registered")
		end
	end

	-- Leaves env.MatchState as whatever the test already set it to, defaulting to Waiting, so a
	-- test can enter already Engaged without a StartUp edge ever having been observed.
	function env.Enter()
		env.InArena = true
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

	---Stands in for a client with no widget system at all, which the record read has to survive
	---rather than error on.
	function env.RemoveWidgetApi()
		_G.C_UIWidgetManager = nil
	end

	---Publishes the top-center set the way a live shuffle carries it: the round and wins widgets
	---plus two decoys whose text matches but whose type or state does not.
	---@param widgets table? RoundId, WinsId, RoundText, WinsText, ExtraWins, NoRound, NoWins,
	---SecretSetId, SecretWidgetList, SecretInfo, SecretText, SecretState, SecretTimer, or Timer
	---for a wins-shaped clock
	function env.SetRecordWidgets(round, total, wins, widgets)
		widgets = widgets or {}

		local iconAndText = _G.Enum.UIWidgetVisualizationType.IconAndText
		local shown = _G.Enum.IconAndTextWidgetState.Shown

		env.WidgetSetId = widgets.SecretSetId and M.SECRET or 7
		env.SecretWidgetList = widgets.SecretWidgetList == true
		env.Widgets = {}
		env.WidgetInfoById = {}

		local function publish(widgetId, widgetType, info)
			env.Widgets[#env.Widgets + 1] = { widgetID = widgetId, widgetType = widgetType }
			env.WidgetInfoById[widgetId] = info
		end

		if not widgets.NoRound then
			publish(widgets.RoundId or M.ROUND_WIDGET_ID, iconAndText, {
				state = widgets.SecretState and M.SECRET or shown,
				text = widgets.SecretText and M.SECRET
					or widgets.RoundText
					or string.format("Round: %d/%d", round, total),
			})
		end

		if not widgets.NoWins then
			publish(
				widgets.WinsId or M.WINS_WIDGET_ID,
				iconAndText,
				widgets.SecretInfo and M.SECRET or {
					state = shown,
					text = widgets.WinsText or string.format("Wins: %d", wins),
					hasTimer = widgets.SecretTimer and M.SECRET or (widgets.Timer == true),
				}
			)
		end

		-- The second single-integer widget a non-shuffle arena was seen carrying, which is the
		-- whole reason the tie-break exists.
		if widgets.ExtraWins then
			publish(916, iconAndText, {
				state = shown,
				text = string.format("Gold Team: %d Players Remaining", widgets.ExtraWins),
			})
		end

		publish(6064, iconAndText, { state = _G.Enum.IconAndTextWidgetState.Hidden, text = "Round: 1/6" })
		publish(6065, _G.Enum.UIWidgetVisualizationType.TextWithState, { state = shown, text = "0/6 Players Ready" })
	end

	---Stands in for the client reporting that a widget's own numbers moved.
	function env.FireWidgetUpdate()
		context.Mock.FireEvent("UPDATE_UI_WIDGET")
	end

	---Publishes a six-row scoreboard the way SummariseScoreboard reads it: the player's own row
	---carrying ownWins, the other five sharing what is left of rounds * 3.
	---@param board table? Secret marks the player's own row unreadable, NoStats leaves it with
	---no stats table, Duplicate (a number) adds a second row under the player's own name carrying
	---that many wins, drawn out of the other rows' share so the total is unchanged, Total overrides
	---the board's whole sum instead of deriving it from rounds
	function env.SetBoard(ownWins, rounds, board)
		board = board or {}

		local duplicateWins = board.Duplicate and (type(board.Duplicate) == "number" and board.Duplicate or 0) or 0
		local total = board.Total or (rounds * 3)
		local remainder = total - ownWins - duplicateWins
		local others = 5
		local share = math.floor(remainder / others)
		local extra = remainder - share * others

		env.Scores = { { Name = M.PLAYER_NAME, Wins = ownWins } }

		if board.Secret then
			env.Scores[1].Secret = true
		end

		if board.NoStats then
			env.Scores[1].NoStats = true
		end

		for i = 1, others do
			env.Scores[#env.Scores + 1] = { Name = "Other" .. i, Wins = share + (i == 1 and extra or 0) }
		end

		if board.Duplicate then
			env.Scores[#env.Scores + 1] = { Name = M.PLAYER_NAME, Wins = duplicateWins }
		end
	end

	---Stands in for the server volunteering the board it was asked for.
	function env.FireScoreUpdate()
		context.Mock.FireEvent("UPDATE_BATTLEFIELD_SCORE")
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

	---Controls the live dampening reading, which comes from C_Commentator.GetDampeningPercent.
	function env.SetDampening(value)
		env.CommentatorDampening = value
	end

	---The table is removed outright rather than left with a missing function, since
	---ReadDampening's guard checks C_Commentator's own type first.
	function env.RemoveCommentatorApi()
		_G.C_Commentator = nil
	end

	---Stands in for a client with no scoreboard to read, which the final round's board read has
	---to survive rather than error on.
	function env.RemoveScoreApi()
		_G.GetNumBattlefieldScores = nil
		_G.C_PvP.GetScoreInfo = nil
	end

	---Stands in for a client with no request call at all, which RequestBoardOnce has to survive
	---by settling from the direct board read instead.
	function env.RemoveScoreRequestApi()
		_G.RequestBattlefieldScoreData = nil
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
