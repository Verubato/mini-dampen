local _, addon = ...
---@type MiniFramework
local mini = addon.Framework
local ALLY_TOKENS = { "player", "party1", "party2" }
local ENEMY_TOKENS = { "arena1", "arena2", "arena3" }
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
-- /minidampen probe enumerates every aura on the player plus a whole widget set, so its output
-- is capped rather than flooding chat.
local PROBE_LINE_LIMIT = 60
local PROBE_AURA_SLOTS = 40
local PROBE_FILTERS = { "HELPFUL", "HARMFUL" }
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

---Appends a probe line, or the one truncation notice once the cap is reached.
local function Append(lines, text)
	if #lines > PROBE_LINE_LIMIT then
		return
	end

	if #lines == PROBE_LINE_LIMIT then
		lines[#lines + 1] = string.format("... capped at %d lines", PROBE_LINE_LIMIT)
		return
	end

	lines[#lines + 1] = text
end

---A diagnostic reports what each source does, so a section that throws is itself the result
---being collected. That is why this catches an error it cannot otherwise handle.
local function SafeSection(lines, label, fn)
	local ok, err = pcall(fn)

	if not ok then
		Append(lines, label .. " failed: " .. SafeString(err))
	end
end

---Renders an aura's points array, which is where a dampening percentage would sit.
local function PointsText(points)
	if mini:IsSecret(points) then
		return "secret"
	end

	if type(points) ~= "table" then
		return SafeString(points)
	end

	local parts = {}

	for i = 1, #points do
		parts[i] = SafeString(points[i])
	end

	return "{" .. table.concat(parts, ",") .. "}"
end

---The first vararg is GetAuraSlots' continuation token rather than a slot. One page is enough
---for a probe, so the token is dropped instead of paged through.
local function AppendSlotLines(lines, filter, ...)
	for i = 2, select("#", ...) do
		local aura = C_UnitAuras.GetAuraDataBySlot("player", (select(i, ...)))

		if mini:IsSecret(aura) then
			Append(lines, string.format("aura %s secret", filter))
		elseif type(aura) == "table" then
			Append(
				lines,
				string.format(
					"aura %s name=%s spellId=%s points=%s",
					filter,
					SafeString(aura.name),
					SafeString(aura.spellId),
					PointsText(aura.points)
				)
			)
		end
	end
end

local function AppendAuraLines(lines, filter)
	if type(C_UnitAuras.GetAuraSlots) ~= "function" or type(C_UnitAuras.GetAuraDataBySlot) ~= "function" then
		Append(lines, "aura slot enumeration unavailable")
		return
	end

	AppendSlotLines(lines, filter, C_UnitAuras.GetAuraSlots("player", filter, PROBE_AURA_SLOTS))
end

---Reverses the visualization type enum so a widget can name its own per-type getter.
local function WidgetTypeName(widgetType)
	local types = Enum and Enum.UIWidgetVisualizationType

	if type(types) ~= "table" then
		return nil
	end

	for name, value in pairs(types) do
		if value == widgetType then
			return name
		end
	end
end

---Some getters carry "Widget" in their name and some do not, so both spellings are tried.
local function WidgetInfo(widgetId, typeName)
	local getter = C_UIWidgetManager["Get" .. typeName .. "WidgetVisualizationInfo"]
		or C_UIWidgetManager["Get" .. typeName .. "VisualizationInfo"]

	if not getter then
		return nil
	end

	return getter(widgetId)
end

---Flattens whatever scalar fields a visualization info table happens to carry, since the shape
---differs per widget type and the interesting one is whichever holds a percentage.
local function InfoText(info)
	if mini:IsSecret(info) then
		return "secret"
	end

	if type(info) ~= "table" then
		return SafeString(info)
	end

	local parts = {}

	for key, value in pairs(info) do
		if mini:IsSecret(value) then
			parts[#parts + 1] = tostring(key) .. "=secret"
		elseif type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
			parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
		end
	end

	table.sort(parts)

	return table.concat(parts, " ")
end

local function AppendWidgetLines(lines)
	if type(C_UIWidgetManager) ~= "table" then
		Append(lines, "widgets C_UIWidgetManager unavailable")
		return
	end

	local setId = C_UIWidgetManager.GetTopCenterWidgetSetID()

	Append(lines, string.format("topCenterWidgetSet=%s", SafeString(setId)))

	if mini:IsSecret(setId) or type(setId) ~= "number" then
		return
	end

	local widgets = C_UIWidgetManager.GetAllWidgetsBySetID(setId)

	if mini:IsSecret(widgets) or type(widgets) ~= "table" then
		Append(lines, string.format("widgets %s", SafeString(widgets)))
		return
	end

	for _, widget in ipairs(widgets) do
		if mini:IsSecret(widget) or type(widget) ~= "table" then
			Append(lines, "widget secret")
			break
		end

		local widgetId = widget.widgetID
		local widgetType = widget.widgetType
		local typeName = not mini:IsSecret(widgetType) and WidgetTypeName(widgetType) or nil
		local info = (typeName and not mini:IsSecret(widgetId)) and WidgetInfo(widgetId, typeName) or nil

		Append(
			lines,
			string.format(
				"widget id=%s type=%s (%s) %s",
				SafeString(widgetId),
				SafeString(widgetType),
				SafeString(typeName),
				InfoText(info)
			)
		)
	end
end

---GetDampeningPercent is documented without a spectator gate, but it lives in the commentator
---namespace, so a refusal is caught rather than killing the rest of the probe.
local function AppendCommentatorLine(lines)
	if type(C_Commentator) ~= "table" or type(C_Commentator.GetDampeningPercent) ~= "function" then
		Append(lines, "C_Commentator.GetDampeningPercent unavailable")
		return
	end

	local ok, percent = pcall(C_Commentator.GetDampeningPercent)

	if not ok then
		Append(lines, "C_Commentator.GetDampeningPercent refused")
		return
	end

	Append(lines, string.format("C_Commentator.GetDampeningPercent=%s", SafeString(percent)))
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

	-- Mirrors ReadDampening's own guard order, so a secret reading is never indexed further
	-- here either.
	local apiAvailable = type(C_Commentator) == "table" and type(C_Commentator.GetDampeningPercent) == "function"
	local rawValue, rawSecret

	if apiAvailable then
		rawValue = C_Commentator.GetDampeningPercent()
		rawSecret = mini:IsSecret(rawValue)
	end

	lines[#lines + 1] = string.format(
		"dampening displayed=%s apiAvailable=%s rawValue=%s rawSecret=%s",
		SafeString(state.dampening),
		SafeString(apiAvailable),
		SafeString(rawValue),
		SafeString(rawSecret)
	)

	lines[#lines + 1] = string.format("forcedDampening=%s", SafeString(addon.Display:GetForcedDampening()))

	for _, entry in ipairs(state.ally) do
		lines[#lines + 1] = string.format(
			"ally %s alive=%s hidden=%s cleared=%s everDead=%s deathSecret=%s feigning=%s",
			SafeString(entry.Token),
			SafeString(entry.Alive),
			SafeString(entry.Hidden),
			SafeString(entry.Cleared),
			SafeString(entry.EverDead),
			SafeString(entry.DeathSecret),
			SafeString(entry.Feigning)
		)
	end

	for _, entry in ipairs(state.enemy) do
		lines[#lines + 1] = string.format(
			"enemy %s alive=%s hidden=%s cleared=%s everDead=%s deathSecret=%s feigning=%s",
			SafeString(entry.Token),
			SafeString(entry.Alive),
			SafeString(entry.Hidden),
			SafeString(entry.Cleared),
			SafeString(entry.EverDead),
			SafeString(entry.DeathSecret),
			SafeString(entry.Feigning)
		)
	end

	return lines
end

---Dumps every place retail could be keeping the dampening number: the player's own auras, the
---top-center widget set, and the commentator API. Nothing here feeds the display.
function M:Probe()
	local lines = {}
	local _, instanceType = IsInInstance()

	Append(
		lines,
		string.format(
			"probe instanceType=%s inScope=%s",
			SafeString(instanceType),
			SafeString(state.inScope)
		)
	)

	-- Ordered by value, with the section known to throw in an active match last, so a live
	-- arena still reports the commentator reading and the widget dump.
	SafeSection(lines, "commentator", function()
		AppendCommentatorLine(lines)
	end)

	SafeSection(lines, "widgets", function()
		AppendWidgetLines(lines)
	end)

	for _, filter in ipairs(PROBE_FILTERS) do
		SafeSection(lines, "aura " .. filter, function()
			AppendAuraLines(lines, filter)
		end)
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
