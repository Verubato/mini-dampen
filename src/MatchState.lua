local _, addon = ...
---@type MiniFramework
local mini = addon.Framework
local ALLY_TOKENS = { "player", "party1", "party2" }
local ENEMY_TOKENS = { "arena1", "arena2", "arena3" }
local POLL_INTERVAL = 0.5
-- How long an opponent has to stay unseen before the display treats it as hidden rather than
-- flickering behind every pillar and line of sight break.
local HIDDEN_DELAY = 1.5
local MAX_ROUNDS = 6
-- The client only ever hands out arena1..3, so this also bounds however many opponents an
-- API claims to see.
local MAX_TEAM_SIZE = 3
-- The ids the two record widgets were captured under. Only ever a tie-break, since a patch that
-- renumbers them must not silently stop the record.
local OBSERVED_ROUND_WIDGET_ID = 3521
local OBSERVED_WINS_WIDGET_ID = 4457
local db
local bootstrap
local gated
local ticker
local lastMatchState
-- The board has given the exact final record, so nothing after it may move the record again.
local recordSettled = false
-- One request per match. A board that never arrives is not chased for.
local scoreAsked = false
-- A board read before this arrives could be a stale one left over from the previous match.
local scoreArrived = false
-- Ratchets up only, never down, so a transient undercount after a reload can't shrink a
-- roster already proven real.
local teamSizeSeen = 0
local state = {
	inScope = false,
	isSoloShuffle = false,
	teamSize = 0,
	ally = {},
	enemy = {},
	dampening = nil,
	-- All four come from one accepted widget reading, or none of them do.
	roundIndex = nil,
	roundTotal = nil,
	recordWins = nil,
	recordLosses = nil,
}
---@class MatchState
local M = {}
addon.MatchState = M

-- The table itself is never replaced, only its fields, so this reference stays valid for the
-- addon's whole life.
M.State = state
-- MiniDampen.lua points this at Display:Refresh() once every module is initialised.
M.OnChanged = nil

local function Notify()
	if M.OnChanged then
		M.OnChanged()
	end
end

---A secret read leaves Alive untouched rather than assuming dead, since inventing a kill is
---the worst failure this addon can have. DeathSecret is re-derived from this same read every
---call, the way Cleared is from UnitExists, so a later readable poll clears it again too.
---Nothing resurrects inside a round, so a unit that reads alive again was never really dead.
local function ReadDeaths(entries)
	for _, entry in ipairs(entries) do
		local dead = UnitIsDeadOrGhost(entry.Token)
		local feign = UnitIsFeignDeath(entry.Token)
		-- A feigning hunter reads dead. An unreadable feign counts as one, so a corpse is never
		-- latched from a read that could not rule a feign out.
		local feigning = mini:IsSecret(feign) or feign == true

		entry.DeathSecret = mini:IsSecret(dead)
		entry.Feigning = feigning

		-- A token that stops resolving reads nil, not secret. That is not a reading either, so
		-- Alive and EverDead both keep their last known value the same way a secret read does.
		if not entry.DeathSecret and dead ~= nil then
			entry.Alive = dead ~= true or feigning

			if dead == true and not feigning then
				entry.EverDead = true
			elseif dead == false then
				entry.EverDead = false
			end
		end
	end
end

local function ExpireHidden(entries)
	local now = GetTime()

	for _, entry in ipairs(entries) do
		if entry.UnseenSince and not entry.Hidden and (now - entry.UnseenSince) >= HIDDEN_DELAY then
			entry.Hidden = true
		end
	end
end

---Player auras are secret for the whole match, so dampening cannot come from spell 110310.
---The commentator API answers a plain number for a normal player, not only a spectator.
local function ReadDampening()
	if type(C_Commentator) ~= "table" or type(C_Commentator.GetDampeningPercent) ~= "function" then
		state.dampening = nil
		return
	end

	local value = C_Commentator.GetDampeningPercent()

	if not mini:IsSecret(value) and type(value) == "number" then
		state.dampening = math.floor(value + 0.5)
	else
		state.dampening = nil
	end
end

---Cached only because Display reads the flag out of state alongside the rest of the row. The
---scope can open before the client has the match data to answer with, so every gated event
---asks again rather than trusting the one reading taken at OpenScope.
local function ReadSoloShuffle()
	local value = type(C_PvP.IsSoloShuffle) == "function" and C_PvP.IsSoloShuffle()

	-- A secret reading is truthy, so testing it for true is what keeps a normal arena from
	-- drawing a round record it has no rounds for.
	state.isSoloShuffle = not mini:IsSecret(value) and value == true
end

---One widget's IconAndText info, taken only where the widget is live on screen. The first
---return says a secret was met, which throws out the whole reading rather than this one widget.
---@return boolean secret, table? info, number? widgetId
local function LiveWidgetInfo(widget)
	if mini:IsSecret(widget) then
		return true
	end

	if type(widget) ~= "table" then
		return false
	end

	local widgetType = widget.widgetType

	if mini:IsSecret(widgetType) then
		return true
	end

	if widgetType ~= Enum.UIWidgetVisualizationType.IconAndText then
		return false
	end

	local widgetId = widget.widgetID

	if mini:IsSecret(widgetId) then
		return true
	end

	if type(widgetId) ~= "number" then
		return false
	end

	local info = C_UIWidgetManager.GetIconAndTextWidgetVisualizationInfo(widgetId)

	if mini:IsSecret(info) then
		return true
	end

	if type(info) ~= "table" then
		return false
	end

	local shown = info.state

	if mini:IsSecret(shown) then
		return true
	end

	local states = Enum and Enum.IconAndTextWidgetState

	if type(states) ~= "table" then
		return false
	end

	-- Blizzard's own visibility gate for this type. The set carries every widget defined for it,
	-- not the handful actually on screen.
	if type(shown) ~= "number" or shown <= states.Hidden then
		return false
	end

	return false, info, widgetId
end

---Sorts every live widget in the top-center set by the shape of its text. Only the digits are
---matched, since the words around them do not survive translation.
---@return table? found
local function CollectRecordCandidates()
	local setId = C_UIWidgetManager.GetTopCenterWidgetSetID()

	if mini:IsSecret(setId) then
		return nil
	end

	if type(setId) ~= "number" then
		return nil
	end

	local widgets = C_UIWidgetManager.GetAllWidgetsBySetID(setId)

	if mini:IsSecret(widgets) then
		return nil
	end

	if type(widgets) ~= "table" then
		return nil
	end

	local found = { rounds = {}, wins = {} }

	for _, widget in ipairs(widgets) do
		local secret, info, widgetId = LiveWidgetInfo(widget)

		if secret then
			return nil
		end

		if info then
			local text = info.text

			if mini:IsSecret(text) then
				return nil
			end

			local hasTimer = info.hasTimer

			if mini:IsSecret(hasTimer) then
				return nil
			end

			if type(text) == "string" then
				local round, total = text:match("(%d+)%s*/%s*(%d+)")
				local only = text:match("^%D*(%d+)%D*$")

				if round then
					found.rounds[#found.rounds + 1] = {
						id = widgetId,
						round = tonumber(round),
						total = tonumber(total),
					}
				elseif only and hasTimer ~= true then
					-- A clock is the other single integer a live widget can carry.
					found.wins[#found.wins + 1] = { id = widgetId, wins = tonumber(only) }
				end
			end
		end
	end

	return found
end

---Where two widgets share a text shape, the id the widget was captured under decides. A single
---candidate needs no tie-break, and none at all leaves the caller to refuse.
local function PickCandidate(candidates, observedId)
	if #candidates == 1 then
		return candidates[1]
	end

	for _, candidate in ipairs(candidates) do
		if candidate.id == observedId then
			return candidate
		end
	end
end

---The whole reading or none of it, so the display never draws half a record.
---@return table? reading
local function ReadRecordWidgets()
	if type(C_UIWidgetManager) ~= "table" then
		return nil
	end

	local found = CollectRecordCandidates()

	if not found then
		return nil
	end

	local round = PickCandidate(found.rounds, OBSERVED_ROUND_WIDGET_ID)

	if not round then
		return nil
	end

	if round.round < 1 or round.round > round.total or round.total > MAX_ROUNDS then
		return nil
	end

	local wins = PickCandidate(found.wins, OBSERVED_WINS_WIDGET_ID)

	if not wins then
		-- No round can have finished before round one, so the record is exactly 0W-0L whether
		-- or not the client has put a wins widget up yet.
		if round.round == 1 then
			return { round = round.round, total = round.total, wins = 0 }
		end

		return nil
	end

	-- Bounded by the round played, not the total: a round-six reading of Wins: 6 would commit
	-- 6W-0L before completion, and the real board of 5 would then be refused as backwards.
	if wins.wins < 0 or wins.wins > round.round then
		return nil
	end

	return {
		round = round.round,
		total = round.total,
		wins = wins.wins,
	}
end

---The scoreboard reports a "Name-Realm" the player's own token answers without.
local function IsPlayerRow(name, playerName)
	if mini:IsSecret(name) or type(name) ~= "string" then
		return false
	end

	return name == playerName or name:match("^[^-]+") == playerName
end

---Every row has to read, since a total missing one player's wins divides into a round count
---that is simply wrong.
local function SummariseScoreboard()
	local summary = { total = 0, ownRows = 0 }

	if type(GetNumBattlefieldScores) ~= "function" or type(C_PvP.GetScoreInfo) ~= "function" then
		summary.refused = true
		return summary
	end

	local playerName = UnitName("player")

	if mini:IsSecret(playerName) or type(playerName) ~= "string" then
		summary.refused = true
		return summary
	end

	local count = GetNumBattlefieldScores()

	if mini:IsSecret(count) or type(count) ~= "number" then
		summary.refused = true
		return summary
	end

	for i = 1, count do
		local info = C_PvP.GetScoreInfo(i)

		if mini:IsSecret(info) or type(info) ~= "table" then
			summary.refused = true
			return summary
		end

		local stats = info.stats

		if mini:IsSecret(stats) or type(stats) ~= "table" then
			summary.refused = true
			return summary
		end

		-- The stat's own id changes between matches, so wins are reached by position.
		local stat = stats[1]

		if mini:IsSecret(stat) or type(stat) ~= "table" then
			summary.refused = true
			return summary
		end

		local wins = stat.pvpStatValue

		if mini:IsSecret(wins) or type(wins) ~= "number" then
			summary.refused = true
			return summary
		end

		local own = IsPlayerRow(info.name, playerName)

		summary.total = summary.total + wins

		if own then
			summary.ownWins = wins
			summary.ownRows = summary.ownRows + 1
		end
	end

	return summary
end

---The last round is the only one whose result the wins widget never takes, since a match that
---completes has no post-round window for that round to update in.
local function IsFinalRound(matchState, round, total)
	return matchState == Enum.PvPMatchState.Complete and round == total
end

---Rounds the round widget alone proves are finished. A lower round number at Complete is a match
---somebody left, whose remaining rounds were never played.
local function PlayedRounds(matchState, round, total)
	if IsFinalRound(matchState, round, total) then
		return total
	end

	return round - 1
end

---The server's own count of the rounds this player won, taken only where the whole board adds up
---to the rounds the widgets say were played.
---@return number? wins
local function BoardWins(played, floor)
	local summary = SummariseScoreboard()

	if summary.refused then
		return nil
	end

	-- Two players can share a name across realms, and picking the wrong one's wins would draw a
	-- record that looks real.
	if summary.ownRows ~= 1 then
		return nil
	end

	-- Every round credits one win per team slot, so a board still crediting the last round does
	-- not add up to the rounds that were played.
	if summary.total ~= played * MAX_TEAM_SIZE then
		return nil
	end

	-- The wins widget never overstates, so a board under it is the one that is wrong.
	if summary.ownWins < floor or summary.ownWins > played then
		return nil
	end

	-- A board this shape can also be a cached one from the match just left, since every
	-- completed shuffle sums to the same eighteen and the floor rarely rules a stale one out.
	if not scoreArrived then
		return nil
	end

	return summary.ownWins
end

---The server answers with UPDATE_BATTLEFIELD_SCORE rather than filling the tables in place, so
---nothing is readable on this call.
local function RequestBoardOnce()
	if scoreAsked then
		return
	end

	scoreAsked = true

	if type(RequestBattlefieldScoreData) == "function" then
		RequestBattlefieldScoreData()
	end
end

---The final round is booked from the board, since the wins widget never takes it.
---@return boolean changed
local function ReadRecord()
	if not state.isSoloShuffle or recordSettled then
		return false
	end

	local reading = ReadRecordWidgets()
	local matchState = C_PvP.GetActiveMatchState()

	if not reading then
		-- The widgets can tear down at Complete before this ever reads them again. The last
		-- accepted reading already proved the round count, so the board is still worth asking.
		if matchState ~= Enum.PvPMatchState.Complete or not state.roundIndex or not state.roundTotal
			or state.roundIndex ~= state.roundTotal then
			return false
		end

		reading = { round = state.roundIndex, total = state.roundTotal, wins = state.recordWins }
	end

	local played = PlayedRounds(matchState, reading.round, reading.total)
	local wins = reading.wins
	local completed = played
	local fromBoard = false

	if IsFinalRound(matchState, reading.round, reading.total) then
		RequestBoardOnce()

		local boardWins = BoardWins(played, wins)

		if not boardWins then
			return false
		end

		wins = boardWins
		fromBoard = true
	else
		completed = math.max(played, wins)
	end

	local won = state.recordWins or 0
	local settled = won + (state.recordLosses or 0)

	-- A widget or board caught part way through its own update can read behind the record
	-- already drawn.
	if wins < won or completed < settled then
		return false
	end

	local losses = completed - wins
	local changed = state.roundIndex ~= reading.round
		or state.roundTotal ~= reading.total
		or state.recordWins ~= wins
		or state.recordLosses ~= losses

	state.roundIndex = reading.round
	state.roundTotal = reading.total
	state.recordWins = wins
	state.recordLosses = losses

	if fromBoard then
		recordSettled = true
	end

	return changed
end

local function Poll()
	ReadDeaths(state.ally)
	ReadDeaths(state.enemy)
	ExpireHidden(state.enemy)
	ReadDampening()
	Notify()
end

---Opponents only answers once tokens exist, and specs stays zero in a bot arena, so the
---player's own group is what carries the prep room. Arena teams are the same size on both sides.
local function ArenaTeamSize()
	local opponents = GetNumArenaOpponents and GetNumArenaOpponents() or 0

	if opponents > 0 then
		return math.min(opponents, MAX_TEAM_SIZE)
	end

	local specs = GetNumArenaOpponentSpecs and GetNumArenaOpponentSpecs() or 0
	local group = GetNumGroupMembers and GetNumGroupMembers() or 0

	return math.min(math.max(specs, group), MAX_TEAM_SIZE)
end

---Grows state.ally in place, the same way ResizeEnemy grows the enemy array, so a token that
---only resolves once teamSize catches up is not lost for the rest of the match. teamSize reads
---0 at OpenScope whenever opponents haven't spawned yet.
local function GrowAlly(size)
	for _, token in ipairs(ALLY_TOKENS) do
		if #state.ally >= size then
			break
		end

		local tracked = false

		for _, entry in ipairs(state.ally) do
			if entry.Token == token then
				tracked = true
				break
			end
		end

		if not tracked and UnitExists(token) then
			state.ally[#state.ally + 1] = {
				Token = token,
				Alive = true,
				Hidden = false,
				UnseenSince = nil,
				EverDead = false,
				Cleared = false,
				DeathSecret = false,
				Feigning = false,
			}
		end
	end
end

---Grows state.enemy in place rather than replacing it, so an entry a token update already
---touched this scope keeps its Alive/Hidden/EverDead history instead of resetting on regrow.
local function ResizeEnemy(size)
	for i = #state.enemy + 1, size do
		state.enemy[i] = {
			Token = ENEMY_TOKENS[i],
			Alive = true,
			Hidden = false,
			UnseenSince = nil,
			EverDead = false,
			Cleared = false,
			DeathSecret = false,
			Feigning = false,
		}
	end

	for i = #state.enemy, size + 1, -1 do
		state.enemy[i] = nil
	end
end

---Re-derived on every roster event, not just OpenScope, so a token not yet seen when the scope
---opened, a mid-match reload or a late spawn, is not lost for the rest of the match. Ally growth
---runs every call, not only when teamSize itself changes, since teamSize can already be at its
---final value while UnitExists("player") only starts answering true a moment later.
local function RefreshTeamSize()
	teamSizeSeen = math.max(teamSizeSeen, ArenaTeamSize())

	if teamSizeSeen ~= state.teamSize then
		state.teamSize = teamSizeSeen
		ResizeEnemy(teamSizeSeen)
	end

	GrowAlly(teamSizeSeen)
end

local function FindEnemyIndex(token)
	for i, entry in ipairs(state.enemy) do
		if entry.Token == token then
			return i
		end
	end
end

---"cleared" means Blizzard dropped its visibility override, on a disconnect, a leave, or
---routinely between shuffle rounds. The entry stays so teamSize remains the denominator.
local function OnArenaOpponentUpdate(token, reason)
	RefreshTeamSize()

	local index = FindEnemyIndex(token)

	if not index then
		return
	end

	local entry = state.enemy[index]

	if reason == "cleared" then
		entry.Cleared = true
		entry.Hidden = false
		entry.UnseenSince = nil
	elseif reason == "seen" then
		entry.Cleared = false
		entry.UnseenSince = nil
		entry.Hidden = false
	elseif reason == "unseen" then
		entry.UnseenSince = entry.UnseenSince or GetTime()
	elseif reason == "destroyed" then
		-- A kill latched here could never be walked back, since a destroyed token stops
		-- resolving and every later poll reads nil. The poll owns EverDead instead.
		entry.Cleared = false
		entry.UnseenSince = nil
		entry.Hidden = false
		entry.Alive = false
	end

	Notify()
end

local function ClearEverDeadAndHidden()
	for _, entry in ipairs(state.ally) do
		entry.EverDead = false
	end

	for _, entry in ipairs(state.enemy) do
		entry.EverDead = false
		entry.Hidden = false
		entry.UnseenSince = nil
		entry.Cleared = false
	end
end

local function OnMatchStateChanged()
	local newState = C_PvP.GetActiveMatchState()

	RefreshTeamSize()

	-- Nobody can die before the gates open, so a round's corpses clear on the way into it.
	if newState ~= lastMatchState
		and (newState == Enum.PvPMatchState.StartUp or newState == Enum.PvPMatchState.Engaged) then
		ClearEverDeadAndHidden()
	end

	-- Read here as well as on the widget event, since the Complete branch changes the answer
	-- with no widget having moved.
	ReadRecord()

	lastMatchState = newState
	Notify()
end

---Fills in a party member who was still loading when the match opened, via RefreshTeamSize's
---own GrowAlly call. A tracked ally whose token stops resolving is marked cleared rather than
---dropped, the same as a departed opponent, so teamSize remains the ally denominator too.
local function OnGroupRosterUpdate()
	RefreshTeamSize()

	for _, entry in ipairs(state.ally) do
		entry.Cleared = not UnitExists(entry.Token)
	end

	Notify()
end

local function OnPrepOpponentSpecializations()
	RefreshTeamSize()
	Notify()
end

---UNIT_AURA fires many times a second in arena, so notifying only on an actual change spares
---Display a full Refresh on every no-op firing.
local function OnUnitAura(shuffleChanged)
	local previous = state.dampening

	ReadDampening()

	if shuffleChanged or state.dampening ~= previous then
		Notify()
	end
end

local function OnGatedEvent(_, event, ...)
	local wasSoloShuffle = state.isSoloShuffle

	ReadSoloShuffle()

	if event == "PVP_MATCH_STATE_CHANGED" then
		OnMatchStateChanged()
	elseif event == "ARENA_OPPONENT_UPDATE" then
		OnArenaOpponentUpdate(...)
	elseif event == "ARENA_PREP_OPPONENT_SPECIALIZATIONS" then
		OnPrepOpponentSpecializations()
	elseif event == "GROUP_ROSTER_UPDATE" then
		OnGroupRosterUpdate()
	elseif event == "UPDATE_UI_WIDGET" then
		-- Fires for widgets this addon knows nothing about, so a reading that moved nothing draws nothing.
		if ReadRecord() or state.isSoloShuffle ~= wasSoloShuffle then
			Notify()
		end
	elseif event == "UPDATE_BATTLEFIELD_SCORE" then
		-- The server volunteered this, so it is read the same way as a direct read.
		scoreArrived = true

		if ReadRecord() then
			Notify()
		end
	elseif event == "PVP_MATCH_COMPLETE" then
		-- A second chance at the one reading that has to be right.
		ReadRecord()
		Notify()
	elseif event == "UNIT_AURA" then
		-- Can decline to notify too, the same as the widget branch, so both are told the flag
		-- moved.
		OnUnitAura(state.isSoloShuffle ~= wasSoloShuffle)
	end
end

local function OpenScope()
	state.inScope = true
	state.isSoloShuffle = false
	teamSizeSeen = 0
	state.teamSize = 0
	state.ally = {}
	state.enemy = {}
	RefreshTeamSize()
	ReadSoloShuffle()
	state.dampening = nil
	state.roundIndex = nil
	state.roundTotal = nil
	state.recordWins = nil
	state.recordLosses = nil
	recordSettled = false
	scoreAsked = false
	scoreArrived = false
	lastMatchState = C_PvP.GetActiveMatchState()

	gated:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	gated:RegisterEvent("ARENA_OPPONENT_UPDATE")
	gated:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
	gated:RegisterEvent("GROUP_ROSTER_UPDATE")
	gated:RegisterEvent("PVP_MATCH_COMPLETE")
	gated:RegisterEvent("UPDATE_UI_WIDGET")
	gated:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
	gated:RegisterUnitEvent("UNIT_AURA", "player")

	ticker = C_Timer.NewTicker(POLL_INTERVAL, Poll)

	-- Nothing is persisted across a reload, so the record comes back from the client rather than
	-- waiting for the next event to ask for it.
	ReadRecord()
	Notify()
end

local function CloseScope()
	state.inScope = false
	state.isSoloShuffle = false
	state.teamSize = 0
	state.ally = {}
	state.enemy = {}
	state.dampening = nil
	state.roundIndex = nil
	state.roundTotal = nil
	state.recordWins = nil
	state.recordLosses = nil
	recordSettled = false
	scoreAsked = false
	scoreArrived = false
	teamSizeSeen = 0

	gated:UnregisterAllEvents()

	if ticker then
		ticker:Cancel()
		ticker = nil
	end

	Notify()
end

---In scope from the moment a match leaves Inactive until the player leaves the arena, so the
---finished record stays on screen over the results.
local function EvaluateGate()
	local _, instanceType = IsInInstance()
	local matchState = C_PvP.GetActiveMatchState()

	local inScope = db.Enabled
		and instanceType == "arena"
		and matchState ~= Enum.PvPMatchState.Inactive

	if inScope then
		if not state.inScope then
			OpenScope()
		end
	else
		CloseScope()
	end
end

function M:Evaluate()
	EvaluateGate()
end

function M:Init()
	db = mini:GetSavedVars()

	-- 1.0.3 persisted a round record here. Nothing persists now.
	db.ActiveMatch = nil

	bootstrap = CreateFrame("Frame")
	bootstrap:RegisterEvent("PLAYER_ENTERING_WORLD")
	bootstrap:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	-- Permanently registered, not only opened by OpenScope, so a match that is still Inactive
	-- at PLAYER_ENTERING_WORLD still gets a chance to open scope once it starts.
	bootstrap:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	bootstrap:SetScript("OnEvent", EvaluateGate)

	gated = CreateFrame("Frame")
	gated:SetScript("OnEvent", OnGatedEvent)

	EvaluateGate()
end
