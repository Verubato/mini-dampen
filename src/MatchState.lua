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

-- Read by Display.lua. The table itself is never replaced, only its fields, so this reference
-- stays valid for the addon's whole life.
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

		if not issecretvalue(dead) then
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
	local points = aura and aura.points
	local value = points and points[1]

	if value ~= nil and not issecretvalue(value) and type(value) == "number" then
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
			entries[#entries + 1] = { Token = token, Alive = true, Hidden = false, UnseenSince = nil, EverDead = false }
		end
	end

	return entries
end

local function BuildEnemy(teamSize)
	local entries = {}

	for i = 1, teamSize do
		entries[i] = { Token = ENEMY_TOKENS[i], Alive = true, Hidden = false, UnseenSince = nil, EverDead = false }
	end

	return entries
end

local function CurrentMatchKey()
	local _, _, _, _, _, _, _, instanceId = GetInstanceInfo()
	local bracket = C_PvP.GetActiveMatchBracket and C_PvP.GetActiveMatchBracket()
	local duration = C_PvP.GetActiveMatchDuration and C_PvP.GetActiveMatchDuration()
	local startedAt = duration and (time() - duration)

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

local function OnArenaOpponentUpdate(token, reason)
	local index = FindEnemyIndex(token)

	if not index then
		return
	end

	if reason == "cleared" then
		table.remove(state.enemy, index)
		Notify()
		return
	end

	local entry = state.enemy[index]

	if reason == "seen" then
		entry.UnseenSince = nil
		entry.Hidden = false
	elseif reason == "unseen" then
		entry.UnseenSince = entry.UnseenSince or GetTime()
	elseif reason == "destroyed" then
		entry.UnseenSince = nil
		entry.Hidden = false
		entry.EverDead = true
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
	end
end

---The fallback when the winner API has nothing to say: one side's whole roster has to have
---died at some point in the round, and the other side must have someone who never did.
local function CorpseLatchResult()
	if #state.enemy == 0 or #state.ally == 0 then
		return "unknown"
	end

	-- An opponent who clears without dying shrinks the roster below teamSize, and that must
	-- block a win the same way a still-living opponent would.
	local enemyAllDead = #state.enemy == state.teamSize
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

local function DetermineResult()
	local winner = C_PvP.GetActiveMatchWinner()
	local mine = GetBattlefieldArenaFaction and GetBattlefieldArenaFaction()

	if winner == mine then
		return "win"
	end

	if winner == 0 or winner == 1 then
		return "loss"
	end

	return CorpseLatchResult()
end

local function SettleRound()
	if not state.roundIndex then
		return
	end

	state.roundResults[state.roundIndex] = DetermineResult()

	db.ActiveMatch.RoundIndex = state.roundIndex
	db.ActiveMatch.Results = state.roundResults
end

local function OnMatchStateChanged()
	local newState = C_PvP.GetActiveMatchState()

	if newState == Enum.PvPMatchState.Engaged and lastMatchState == Enum.PvPMatchState.StartUp then
		state.roundIndex = math.min((state.roundIndex or 0) + 1, MAX_ROUNDS)
		ClearEverDeadAndHidden()
	elseif newState == Enum.PvPMatchState.PostRound and lastMatchState ~= Enum.PvPMatchState.PostRound then
		SettleRound()
	end

	lastMatchState = newState
	Notify()
end

---Fills in a party member who was still loading when the match opened, without disturbing
---anyone already being tracked.
local function OnGroupRosterUpdate()
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
			state.ally[#state.ally + 1] = { Token = token, Alive = true, Hidden = false, UnseenSince = nil, EverDead = false }
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

local function OnUnitAura()
	ReadDampening()
	Notify()
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

local function EvaluateGate()
	local _, instanceType = IsInInstance()
	local matchState = C_PvP.GetActiveMatchState()

	local inScope = db.Enabled
		and instanceType == "arena"
		and matchState ~= Enum.PvPMatchState.Inactive
		and matchState ~= nil

	if inScope then
		if not state.inScope then
			OpenScope()
		end
	else
		CloseScope()
	end
end

function M:Init()
	db = mini:GetSavedVars()

	bootstrap = CreateFrame("Frame")
	bootstrap:RegisterEvent("PLAYER_ENTERING_WORLD")
	bootstrap:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	bootstrap:SetScript("OnEvent", EvaluateGate)

	gated = CreateFrame("Frame")
	gated:SetScript("OnEvent", OnGatedEvent)

	EvaluateGate()
end
