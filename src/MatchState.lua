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
-- The client only ever hands out arena1..3, so this also bounds however many opponents an
-- API claims to see.
local MAX_TEAM_SIZE = 3
local db
local bootstrap
local gated
local ticker
local lastMatchState
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

---A secret read leaves Alive untouched rather than assuming dead, since inventing a kill is
---the worst failure this addon can have. DeathSecret is re-derived from this same read every
---call, the way Cleared is from UnitExists, so a later readable poll clears it again too.
local function ReadDeaths(entries)
	for _, entry in ipairs(entries) do
		local dead = UnitIsDeadOrGhost(entry.Token)

		entry.DeathSecret = mini:IsSecret(dead)

		if not entry.DeathSecret then
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
			state.ally[#state.ally + 1] =
				{ Token = token, Alive = true, Hidden = false, UnseenSince = nil, EverDead = false, Cleared = false, DeathSecret = false }
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

	RefreshTeamSize()

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
	teamSizeSeen = 0
	state.teamSize = 0
	state.ally = {}
	state.enemy = {}
	RefreshTeamSize()
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
	teamSizeSeen = 0

	gated:UnregisterAllEvents()

	if ticker then
		ticker:Cancel()
		ticker = nil
	end

	db.ActiveMatch = nil

	Notify()
end

---Every /minidampen debug field is funnelled through here, so a value that turns out secret
---can never be interpolated straight into the chat line that is meant to be diagnosing it.
local function SafeString(value)
	if mini:IsSecret(value) then
		return "secret"
	end

	return tostring(value)
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

---Reads everything /minidampen debug needs to tell a real reading from a preview, or a gate
---defect from an empty arena, without a round trip.
function M:Debug()
	local lines = {}
	local _, instanceType = IsInInstance()
	local matchState = C_PvP.GetActiveMatchState()
	local specs = GetNumArenaOpponentSpecs and GetNumArenaOpponentSpecs()
	local opponents = GetNumArenaOpponents and GetNumArenaOpponents()
	local group = GetNumGroupMembers and GetNumGroupMembers()

	lines[#lines + 1] = string.format(
		"inScope=%s locked=%s instanceType=%s matchState=%s",
		SafeString(state.inScope),
		SafeString(db.Locked),
		SafeString(instanceType),
		SafeString(matchState)
	)

	local source

	if not db.Locked then
		source = "sample (unlocked preview)"
	elseif state.inScope then
		source = "live"
	else
		source = "none, out of scope and locked"
	end

	lines[#lines + 1] = string.format("onScreenValues=%s", source)

	lines[#lines + 1] = string.format(
		"teamSize=%s allyCount=%s enemyCount=%s GetNumArenaOpponents=%s GetNumArenaOpponentSpecs=%s GetNumGroupMembers=%s",
		SafeString(state.teamSize),
		SafeString(#state.ally),
		SafeString(#state.enemy),
		SafeString(opponents),
		SafeString(specs),
		SafeString(group)
	)

	-- Mirrors ReadDampening's own guard order, so a secret aura or points table is never
	-- indexed further here either.
	local aura = C_UnitAuras.GetPlayerAuraBySpellID(DAMPENING_SPELL_ID)
	local auraSecret = mini:IsSecret(aura)
	local points, pointsSecret, rawValue, rawSecret
	local auraFound

	if auraSecret then
		auraFound = "secret"
	else
		auraFound = (aura ~= nil) and "yes" or "no"
		points = aura and aura.points
		pointsSecret = mini:IsSecret(points)

		if not pointsSecret then
			rawValue = points and points[1]
			rawSecret = mini:IsSecret(rawValue)
		end
	end

	-- auraFound separates "no aura yet" from "aura unreadable", which displayed=nil alone
	-- cannot: both a match with no dampening started and a restricted read land there.
	lines[#lines + 1] = string.format(
		"dampening displayed=%s auraFound=%s auraSecret=%s pointsSecret=%s rawValue=%s rawSecret=%s",
		SafeString(state.dampening),
		SafeString(auraFound),
		SafeString(auraSecret),
		SafeString(pointsSecret),
		SafeString(rawValue),
		SafeString(rawSecret)
	)

	lines[#lines + 1] = string.format("forcedDampening=%s", SafeString(addon.Display:GetForcedDampening()))

	for _, entry in ipairs(state.ally) do
		lines[#lines + 1] = string.format(
			"ally %s alive=%s hidden=%s cleared=%s everDead=%s deathSecret=%s",
			SafeString(entry.Token),
			SafeString(entry.Alive),
			SafeString(entry.Hidden),
			SafeString(entry.Cleared),
			SafeString(entry.EverDead),
			SafeString(entry.DeathSecret)
		)
	end

	for _, entry in ipairs(state.enemy) do
		lines[#lines + 1] = string.format(
			"enemy %s alive=%s hidden=%s cleared=%s everDead=%s deathSecret=%s",
			SafeString(entry.Token),
			SafeString(entry.Alive),
			SafeString(entry.Hidden),
			SafeString(entry.Cleared),
			SafeString(entry.EverDead),
			SafeString(entry.DeathSecret)
		)
	end

	return lines
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
