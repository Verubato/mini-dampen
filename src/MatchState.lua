local _, addon = ...
---@type MiniFramework
local mini = addon.Framework
local ALLY_TOKENS = { "player", "party1", "party2" }
local ENEMY_TOKENS = { "arena1", "arena2", "arena3" }
local DAMPENING_SPELL_ID = 110310
local POLL_INTERVAL = 0.5
-- How long an opponent has to stay unseen before the display treats it as hidden rather than
-- flickering behind every pillar and line of sight break.
local HIDDEN_DELAY = 1.5
-- A reload's time() and GetActiveMatchDuration() both drift by a second or two of latency, so
-- the two computed start times only need to land within this many seconds of each other.
local MATCH_KEY_TOLERANCE = 3
local MAX_ROUNDS = 6
local db
local bootstrap
local gated
local ticker
local lastMatchState
local state = {
	inScope = false,
	isSoloShuffle = false,
	teamSize = 0,
	ally = {},
	enemy = {},
	dampening = nil,
	roundIndex = nil,
	roundResults = {},
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

local function ReadDeaths(entries)
	for _, entry in ipairs(entries) do
		local dead = UnitIsDeadOrGhost(entry.Token)

		if not mini:IsSecret(dead) then
			entry.Alive = dead ~= true
			entry.EverDead = entry.EverDead or dead == true
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

local function ReadDampening()
	local aura = C_UnitAuras.GetPlayerAuraBySpellID(DAMPENING_SPELL_ID)

	if mini:IsSecret(aura) then
		state.dampening = nil
		return
	end

	local points = aura and aura.points

	if mini:IsSecret(points) then
		state.dampening = nil
		return
	end

	local value = points and points[1]

	if not mini:IsSecret(value) and type(value) == "number" then
		state.dampening = math.floor(value + 0.5)
	else
		state.dampening = nil
	end
end

local function Poll()
	ReadDeaths(state.ally)
	ReadDeaths(state.enemy)
	ExpireHidden(state.enemy)
	ReadDampening()
	Notify()
end

---Blizzard's own spec count lags the roster count during prep, so the higher of the two wins.
local function ArenaTeamSize()
	local specs = GetNumArenaOpponentSpecs and GetNumArenaOpponentSpecs() or 0
	local opponents = GetNumArenaOpponents and GetNumArenaOpponents() or 0

	return math.min(math.max(specs, opponents), 3)
end

local function BuildAlly(teamSize)
	local entries = {}

	for _, token in ipairs(ALLY_TOKENS) do
		if #entries >= teamSize then
			break
		end

		if UnitExists(token) then
			entries[#entries + 1] = { Token = token, Alive = true, Hidden = false, UnseenSince = nil, EverDead = false, Cleared = false }
		end
	end

	return entries
end

local function BuildEnemy(teamSize)
	local entries = {}

	for i = 1, teamSize do
		entries[i] = {
			Token = ENEMY_TOKENS[i],
			Alive = true,
			Hidden = false,
			UnseenSince = nil,
			EverDead = false,
			Cleared = false,
		}
	end

	return entries
end

local function CurrentMatchKey()
	local _, _, _, _, _, _, _, instanceId = GetInstanceInfo()
	local bracket = C_PvP.GetActiveMatchBracket()
	local duration = C_PvP.GetActiveMatchDuration()
	local startedAt = time() - duration

	return instanceId, bracket, startedAt
end

local function KeysMatch(instanceId, bracket, startedAt, savedInstanceId, savedBracket, savedStartedAt)
	if instanceId == nil or bracket == nil or startedAt == nil then
		return false
	end

	if savedInstanceId == nil or savedBracket == nil or savedStartedAt == nil then
		return false
	end

	return instanceId == savedInstanceId
		and bracket == savedBracket
		and math.abs(startedAt - savedStartedAt) <= MATCH_KEY_TOLERANCE
end

local function AdoptOrCreateRecord()
	local instanceId, bracket, startedAt = CurrentMatchKey()
	local saved = db.ActiveMatch

	if saved and KeysMatch(instanceId, bracket, startedAt, saved.InstanceId, saved.Bracket, saved.StartedAt) then
		state.roundIndex = saved.RoundIndex
		state.roundResults = saved.Results or {}
		return
	end

	db.ActiveMatch = {
		InstanceId = instanceId,
		Bracket = bracket,
		StartedAt = startedAt,
		RoundIndex = nil,
		Results = {},
	}

	state.roundIndex = nil
	state.roundResults = {}
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
		entry.Cleared = false
		entry.UnseenSince = nil
		entry.Hidden = false
		entry.EverDead = true
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

---A cleared opponent who never latched dead leaves enemyAllDead false, blocking a win the
---same way a still-living opponent would.
local function CorpseLatchResult()
	if #state.enemy == 0 or #state.ally == 0 then
		return "unknown"
	end

	local enemyAllDead = true
	local allyAllDead = true

	for _, entry in ipairs(state.enemy) do
		if not entry.EverDead then
			enemyAllDead = false
		end
	end

	for _, entry in ipairs(state.ally) do
		if not entry.EverDead then
			allyAllDead = false
		end
	end

	if enemyAllDead and not allyAllDead then
		return "win"
	end

	if allyAllDead and not enemyAllDead then
		return "loss"
	end

	return "unknown"
end

---GetActiveMatchWinner is Nilable = false, so with no winner decided it still answers some
---sentinel number rather than nil, which can land on a real faction index.
local function DetermineResult()
	local winner = C_PvP.GetActiveMatchWinner()
	local mine = GetBattlefieldArenaFaction and GetBattlefieldArenaFaction()
	local corpseResult = CorpseLatchResult()

	if mine == nil or (winner ~= 0 and winner ~= 1) then
		return corpseResult
	end

	local winnerResult = (winner == mine) and "win" or "loss"

	if corpseResult ~= "unknown" and corpseResult ~= winnerResult then
		return "unknown"
	end

	return winnerResult
end

local function SettleRound()
	if not state.roundIndex then
		return
	end

	state.roundResults[state.roundIndex] = DetermineResult()

	if db.ActiveMatch then
		db.ActiveMatch.RoundIndex = state.roundIndex
		db.ActiveMatch.Results = state.roundResults
	end
end

local function OnMatchStateChanged()
	local newState = C_PvP.GetActiveMatchState()

	if newState == Enum.PvPMatchState.Engaged and lastMatchState == Enum.PvPMatchState.StartUp then
		state.roundIndex = math.min((state.roundIndex or 0) + 1, MAX_ROUNDS)

		if db.ActiveMatch then
			db.ActiveMatch.RoundIndex = state.roundIndex
		end

		ClearEverDeadAndHidden()
	elseif newState == Enum.PvPMatchState.PostRound and lastMatchState ~= Enum.PvPMatchState.PostRound then
		SettleRound()
	end

	lastMatchState = newState
	Notify()
end

---Fills in a party member who was still loading when the match opened. A tracked ally whose
---token stops resolving is marked cleared rather than dropped, the same as a departed
---opponent, so teamSize remains the ally denominator too.
local function OnGroupRosterUpdate()
	for _, entry in ipairs(state.ally) do
		entry.Cleared = not UnitExists(entry.Token)
	end

	for _, token in ipairs(ALLY_TOKENS) do
		if #state.ally >= state.teamSize then
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
			state.ally[#state.ally + 1] = { Token = token, Alive = true, Hidden = false, UnseenSince = nil, EverDead = false, Cleared = false }
		end
	end

	Notify()
end

local function OnPrepOpponentSpecializations()
	local teamSize = ArenaTeamSize()

	if teamSize > 0 and teamSize ~= state.teamSize then
		state.teamSize = teamSize
		state.enemy = BuildEnemy(teamSize)
	end

	Notify()
end

---UNIT_AURA fires many times a second in arena, so notifying only on an actual change spares
---Display a full Refresh on every no-op firing.
local function OnUnitAura()
	local previous = state.dampening

	ReadDampening()

	if state.dampening ~= previous then
		Notify()
	end
end

local function OnGatedEvent(_, event, ...)
	if event == "PVP_MATCH_STATE_CHANGED" then
		OnMatchStateChanged()
	elseif event == "ARENA_OPPONENT_UPDATE" then
		OnArenaOpponentUpdate(...)
	elseif event == "ARENA_PREP_OPPONENT_SPECIALIZATIONS" then
		OnPrepOpponentSpecializations()
	elseif event == "GROUP_ROSTER_UPDATE" then
		OnGroupRosterUpdate()
	elseif event == "PVP_MATCH_COMPLETE" then
		db.ActiveMatch = nil
		state.roundIndex = nil
		state.roundResults = {}
		Notify()
	elseif event == "UNIT_AURA" then
		OnUnitAura()
	end
end

local function OpenScope()
	state.inScope = true
	state.isSoloShuffle = (C_PvP.IsSoloShuffle and C_PvP.IsSoloShuffle()) or false
	state.teamSize = ArenaTeamSize()
	state.ally = BuildAlly(state.teamSize)
	state.enemy = BuildEnemy(state.teamSize)
	state.dampening = nil
	lastMatchState = C_PvP.GetActiveMatchState()

	AdoptOrCreateRecord()

	gated:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	gated:RegisterEvent("ARENA_OPPONENT_UPDATE")
	gated:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
	gated:RegisterEvent("GROUP_ROSTER_UPDATE")
	gated:RegisterEvent("PVP_MATCH_COMPLETE")
	gated:RegisterUnitEvent("UNIT_AURA", "player")

	ticker = C_Timer.NewTicker(POLL_INTERVAL, Poll)

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
	state.roundResults = {}

	gated:UnregisterAllEvents()

	if ticker then
		ticker:Cancel()
		ticker = nil
	end

	db.ActiveMatch = nil

	Notify()
end

---In scope for as long as a match is running: not Inactive before it starts, not Complete
---once the results screen is up.
local function EvaluateGate()
	local _, instanceType = IsInInstance()
	local matchState = C_PvP.GetActiveMatchState()

	local inScope = db.Enabled
		and instanceType == "arena"
		and matchState ~= Enum.PvPMatchState.Inactive
		and matchState ~= Enum.PvPMatchState.Complete

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
