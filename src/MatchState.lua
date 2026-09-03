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
-- /minidampen probe enumerates every aura on the player plus every widget set, so its output
-- is capped rather than flooding chat.
local PROBE_LINE_LIMIT = 60
local PROBE_AURA_SLOTS = 40
local PROBE_FILTERS = { "HELPFUL", "HARMFUL" }
local db
local bootstrap
local gated
local ticker
local lastMatchState
-- A reason that holds for a whole round would otherwise be logged on every widget update the
-- client fires.
local lastRecordRefusal
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

---Every diagnostic field is funnelled through here, so a value that turns out secret can never
---be interpolated straight into the line that is meant to be diagnosing it.
local function SafeString(value)
	if mini:IsSecret(value) then
		return "secret"
	end

	return tostring(value)
end

local function LogEnabled()
	return db ~= nil and db.Logging == true and state.inScope
end

local function Stamp()
	local now = GetTime()

	if mini:IsSecret(now) or type(now) ~= "number" then
		return "?"
	end

	return string.format("%.2f", now)
end

local function LogLine(format, ...)
	mini:NotifyWithPrefix("%s", string.format("[%s] " .. format, Stamp(), ...))
end

---A throw here would cost the owner the very capture this exists to produce, so a bad line is
---dropped rather than taken out through the event handler that wrote it.
local function Log(format, ...)
	if not LogEnabled() then
		return
	end

	pcall(LogLine, format, ...)
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

---Found by name rather than from a list of our own, so a set a later patch adds is dumped
---without a code change. Sorted, so two dumps can be read against each other.
local function WidgetSetGetterNames()
	local names = {}

	for key, value in pairs(C_UIWidgetManager) do
		if type(key) == "string" and type(value) == "function" and key:match("WidgetSetID$") then
			names[#names + 1] = key
		end
	end

	table.sort(names)

	return names
end

---Every widget in one set, each line naming the getter the set came from so the dump says
---where a widget lives.
local function AppendSetWidgetLines(lines, getterName, setId)
	local widgets = C_UIWidgetManager.GetAllWidgetsBySetID(setId)

	if mini:IsSecret(widgets) or type(widgets) ~= "table" then
		Append(lines, string.format("widgets %s %s", getterName, SafeString(widgets)))
		return
	end

	for _, widget in ipairs(widgets) do
		if mini:IsSecret(widget) or type(widget) ~= "table" then
			Append(lines, string.format("widget %s secret", getterName))
			break
		end

		local widgetId = widget.widgetID
		local widgetType = widget.widgetType
		local typeName = not mini:IsSecret(widgetType) and WidgetTypeName(widgetType) or nil
		local info = (typeName and not mini:IsSecret(widgetId)) and WidgetInfo(widgetId, typeName) or nil

		Append(
			lines,
			string.format(
				"widget %s id=%s type=%s (%s) %s",
				getterName,
				SafeString(widgetId),
				SafeString(widgetType),
				SafeString(typeName),
				InfoText(info)
			)
		)
	end
end

---Two getters can name the same set, so whichever asked first is the one that enumerates it.
local function AppendWidgetSet(lines, getterName, setId, seen)
	Append(lines, string.format("widgetSet %s=%s", getterName, SafeString(setId)))

	if mini:IsSecret(setId) or type(setId) ~= "number" or seen[setId] then
		return
	end

	seen[setId] = true

	SafeSection(lines, "widgets " .. getterName, function()
		AppendSetWidgetLines(lines, getterName, setId)
	end)
end

---The leading argument is pcall's own status, and a getter can name more than one set, so every
---return after it is taken.
local function AppendGetterSets(lines, getterName, seen, ok, ...)
	if not ok then
		Append(lines, string.format("widgetSet %s failed: %s", getterName, SafeString((...))))
		return
	end

	local count = select("#", ...)

	if count == 0 then
		Append(lines, string.format("widgetSet %s names none", getterName))
		return
	end

	for i = 1, count do
		AppendWidgetSet(lines, getterName, (select(i, ...)), seen)
	end
end

local function AppendWidgetLines(lines)
	if type(C_UIWidgetManager) ~= "table" then
		Append(lines, "widgets C_UIWidgetManager unavailable")
		return
	end

	local names = WidgetSetGetterNames()

	if #names == 0 then
		Append(lines, "widgets no set getters")
		return
	end

	local seen = {}

	for _, name in ipairs(names) do
		AppendGetterSets(lines, name, seen, pcall(C_UIWidgetManager[name]))
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
---@return table? found, string? refusal
local function CollectRecordCandidates()
	local setId = C_UIWidgetManager.GetTopCenterWidgetSetID()

	if mini:IsSecret(setId) then
		return nil, "secret set id"
	end

	if type(setId) ~= "number" then
		return nil, "no set id"
	end

	local widgets = C_UIWidgetManager.GetAllWidgetsBySetID(setId)

	if mini:IsSecret(widgets) then
		return nil, "secret widget list"
	end

	if type(widgets) ~= "table" then
		return nil, "no widget list"
	end

	local found = { rounds = {}, wins = {}, seen = {} }

	for _, widget in ipairs(widgets) do
		local secret, info, widgetId = LiveWidgetInfo(widget)

		if secret then
			return nil, "secret widget"
		end

		if info then
			local text = info.text

			if mini:IsSecret(text) then
				return nil, "secret text"
			end

			local hasTimer = info.hasTimer

			if mini:IsSecret(hasTimer) then
				return nil, "secret timer flag"
			end

			if type(text) == "string" then
				found.seen[#found.seen + 1] = string.format("%d=%s", widgetId, text)

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
---@return table? reading, string? refusal, string seen
local function ReadRecordWidgets()
	if type(C_UIWidgetManager) ~= "table" then
		return nil, "no widget api", ""
	end

	local found, refusal = CollectRecordCandidates()

	if not found then
		return nil, refusal, ""
	end

	local seen = table.concat(found.seen, " ")
	local round = PickCandidate(found.rounds, OBSERVED_ROUND_WIDGET_ID)

	if not round then
		return nil, #found.rounds > 1 and "round widget ambiguous" or "no round widget", seen
	end

	if round.round < 1 or round.round > round.total or round.total > MAX_ROUNDS then
		return nil, "round out of range", seen
	end

	local wins = PickCandidate(found.wins, OBSERVED_WINS_WIDGET_ID)

	if not wins then
		-- No round can have finished before round one, so the record is exactly 0W-0L whether
		-- or not the client has put a wins widget up yet.
		if round.round == 1 then
			return { round = round.round, total = round.total, wins = 0, roundId = round.id, winsId = nil }, nil, seen
		end

		return nil, #found.wins > 1 and "wins widget ambiguous" or "no wins widget", seen
	end

	-- Bounded by the round played, not the total: a round-six reading of Wins: 6 would commit
	-- 6W-0L before completion, and the real board of 5 would then be refused as backwards.
	if wins.wins < 0 or wins.wins > round.round then
		return nil, "wins out of range", seen
	end

	return {
		round = round.round,
		total = round.total,
		wins = wins.wins,
		roundId = round.id,
		winsId = wins.id,
	}, nil, seen
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
	local summary = { rows = {}, total = 0, ownRows = 0 }

	if type(GetNumBattlefieldScores) ~= "function" or type(C_PvP.GetScoreInfo) ~= "function" then
		summary.refused = "no score api"
		return summary
	end

	local playerName = UnitName("player")

	if mini:IsSecret(playerName) or type(playerName) ~= "string" then
		summary.refused = "own name unreadable"
		return summary
	end

	local count = GetNumBattlefieldScores()

	if mini:IsSecret(count) or type(count) ~= "number" then
		summary.refused = "row count unreadable"
		return summary
	end

	for i = 1, count do
		local info = C_PvP.GetScoreInfo(i)

		if mini:IsSecret(info) or type(info) ~= "table" then
			summary.refused = "row unreadable"
			return summary
		end

		local stats = info.stats

		if mini:IsSecret(stats) or type(stats) ~= "table" then
			summary.refused = "row stats unreadable"
			return summary
		end

		-- The stat's own id changes between matches, so wins are reached by position.
		local stat = stats[1]

		if mini:IsSecret(stat) or type(stat) ~= "table" then
			summary.refused = "wins stat unreadable"
			return summary
		end

		local wins = stat.pvpStatValue

		if mini:IsSecret(wins) or type(wins) ~= "number" then
			summary.refused = "wins unreadable"
			return summary
		end

		local own = IsPlayerRow(info.name, playerName)

		summary.rows[i] = { name = info.name, wins = wins, own = own }
		summary.total = summary.total + wins

		if own then
			summary.ownWins = wins
			summary.ownStats = stats
			summary.ownRows = summary.ownRows + 1
		end
	end

	-- Every round produces exactly one winner per team slot, and a shuffle is always three a
	-- side, so the whole board's wins divide into the rounds played.
	summary.rounds = math.min(math.floor(summary.total / MAX_TEAM_SIZE), MAX_ROUNDS)

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
---@return number? wins, string? refusal
local function BoardWins(played, floor)
	local summary = SummariseScoreboard()

	if summary.refused then
		return nil, "board " .. summary.refused
	end

	-- Two players can share a name across realms, and picking the wrong one's wins would draw a
	-- record that looks real.
	if summary.ownRows ~= 1 then
		return nil, "board own row ambiguous"
	end

	-- Every round credits one win per team slot, so a board still crediting the last round does
	-- not add up to the rounds that were played.
	if summary.total ~= played * MAX_TEAM_SIZE then
		return nil, "board does not add up"
	end

	-- The wins widget never overstates, so a board under it is the one that is wrong.
	if summary.ownWins < floor or summary.ownWins > played then
		return nil, "board contradicts the widgets"
	end

	-- A board this shape can also be a cached one from the match just left, since every
	-- completed shuffle sums to the same eighteen and the floor rarely rules a stale one out.
	if not scoreArrived then
		return nil, "board not yet reported"
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

---Logged once per reason, since a widget that will not read stays that way for a whole round
---while UPDATE_UI_WIDGET keeps firing.
local function RefuseRecord(reason, seen)
	if reason ~= lastRecordRefusal then
		lastRecordRefusal = reason
		Log("record refused %s saw=%s", reason, seen)
	end

	return false
end

---The final round is booked from the board, since the wins widget never takes it.
---@return boolean changed
local function ReadRecord()
	if not state.isSoloShuffle or recordSettled then
		return false
	end

	local reading, refusal, seen = ReadRecordWidgets()
	local matchState = C_PvP.GetActiveMatchState()

	if not reading then
		-- The widgets can tear down at Complete before this ever reads them again. The last
		-- accepted reading already proved the round count, so the board is still worth asking.
		if matchState ~= Enum.PvPMatchState.Complete or not state.roundIndex or not state.roundTotal
			or state.roundIndex ~= state.roundTotal then
			return RefuseRecord(refusal, seen)
		end

		reading = { round = state.roundIndex, total = state.roundTotal, wins = state.recordWins }
	end

	local played = PlayedRounds(matchState, reading.round, reading.total)
	local wins = reading.wins
	local completed = played
	local source = "widgets"

	if IsFinalRound(matchState, reading.round, reading.total) then
		RequestBoardOnce()

		local boardWins, boardRefusal = BoardWins(played, wins)

		if not boardWins then
			return RefuseRecord(boardRefusal, seen)
		end

		wins = boardWins
		source = "board"
	else
		completed = math.max(played, wins)
	end

	local won = state.recordWins or 0
	local settled = won + (state.recordLosses or 0)

	-- A widget or board caught part way through its own update can read behind the record
	-- already drawn.
	if wins < won or completed < settled then
		return RefuseRecord("backwards", seen)
	end

	lastRecordRefusal = nil

	local losses = completed - wins
	local changed = state.roundIndex ~= reading.round
		or state.roundTotal ~= reading.total
		or state.recordWins ~= wins
		or state.recordLosses ~= losses

	state.roundIndex = reading.round
	state.roundTotal = reading.total
	state.recordWins = wins
	state.recordLosses = losses

	if source == "board" then
		recordSettled = true
	end

	if changed then
		Log(
			"record round=%s/%s wins=%s completed=%s roundId=%s winsId=%s source=%s widgetWins=%s",
			reading.round,
			reading.total,
			wins,
			completed,
			SafeString(reading.roundId),
			SafeString(reading.winsId),
			source,
			reading.wins
		)
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

	Log(
		"state %s -> %s round=%s shuffle=%s",
		SafeString(lastMatchState),
		SafeString(newState),
		SafeString(state.roundIndex),
		SafeString(state.isSoloShuffle)
	)

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
	lastRecordRefusal = nil
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

	Log("scope open")

	-- Nothing is persisted across a reload, so the record comes back from the client rather than
	-- waiting for the next event to ask for it.
	ReadRecord()
	Notify()
end

local function CloseScope()
	-- Written before inScope drops, which is what the log itself is gated on.
	Log("scope close")

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
	lastRecordRefusal = nil
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

---Names the wins column by id as well as by position, since nothing else proves position 1 is
---the column the record is read from.
local function AppendStatColumnLines(lines, summary)
	if not mini:IsSecret(summary.ownStats) and type(summary.ownStats) == "table" then
		for i, stat in ipairs(summary.ownStats) do
			if mini:IsSecret(stat) or type(stat) ~= "table" then
				Append(lines, string.format("score ownStat %d %s", i, SafeString(stat)))
			else
				Append(
					lines,
					string.format(
						"score ownStat %d id=%s value=%s",
						i,
						SafeString(stat.pvpStatID),
						SafeString(stat.pvpStatValue)
					)
				)
			end
		end
	end

	if type(C_PvP.GetMatchPVPStatColumns) ~= "function" then
		Append(lines, "score columns unavailable")
		return
	end

	local columns = C_PvP.GetMatchPVPStatColumns()

	if mini:IsSecret(columns) or type(columns) ~= "table" then
		Append(lines, string.format("score columns=%s", SafeString(columns)))
		return
	end

	for i, column in ipairs(columns) do
		Append(lines, string.format("score column %d %s", i, InfoText(column)))
	end
end

---Reports the board itself, so a wrong record can be traced to the reading it came from rather
---than guessed at from the numbers it settled on.
local function AppendScoreLines(lines)
	local summary = SummariseScoreboard()

	Append(
		lines,
		string.format(
			"score total=%s rounds=%s ownWins=%s ownRows=%s refused=%s",
			SafeString(summary.total),
			SafeString(summary.rounds),
			SafeString(summary.ownWins),
			SafeString(summary.ownRows),
			SafeString(summary.refused)
		)
	)

	for i, row in ipairs(summary.rows) do
		Append(
			lines,
			string.format(
				"score row %d name=%s wins=%s own=%s",
				i,
				SafeString(row.name),
				SafeString(row.wins),
				SafeString(row.own)
			)
		)
	end

	AppendStatColumnLines(lines, summary)
end

---The same reading the record is taken from, without committing it, so a blank record can be
---pasted out of one command rather than captured with the log.
local function AppendRecordLines(lines)
	local reading, refusal, seen = ReadRecordWidgets()

	if not reading then
		Append(lines, string.format("record refused=%s saw=%s", refusal, seen))
		return
	end

	Append(
		lines,
		string.format(
			"record round=%s/%s wins=%s roundId=%s winsId=%s saw=%s",
			reading.round,
			reading.total,
			reading.wins,
			SafeString(reading.roundId),
			SafeString(reading.winsId),
			seen
		)
	)
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
		"inScope=%s testMode=%s instanceType=%s matchState=%s",
		SafeString(state.inScope),
		SafeString(addon.Display:IsTestMode()),
		SafeString(instanceType),
		SafeString(matchState)
	)

	local source

	if addon.Display:IsTestMode() then
		source = "sample (test preview)"
	elseif state.inScope then
		source = "live"
	else
		source = "none, out of scope and not testing"
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

	-- Sits above the dampening line because that one calls the commentator API unguarded, and a
	-- refusal there would cost the user the whole paste this line exists to give them.
	local rawShuffle

	if type(C_PvP.IsSoloShuffle) == "function" then
		rawShuffle = C_PvP.IsSoloShuffle()
	end

	local bracket

	if type(C_PvP.GetActiveMatchBracket) == "function" then
		bracket = C_PvP.GetActiveMatchBracket()
	end

	lines[#lines + 1] = string.format(
		"isSoloShuffle=%s rawIsSoloShuffle=%s bracket=%s roundIndex=%s roundTotal=%s recordWins=%s recordLosses=%s settled=%s asked=%s",
		SafeString(state.isSoloShuffle),
		SafeString(rawShuffle),
		SafeString(bracket),
		SafeString(state.roundIndex),
		SafeString(state.roundTotal),
		SafeString(state.recordWins),
		SafeString(state.recordLosses),
		SafeString(recordSettled),
		SafeString(scoreAsked)
	)

	SafeSection(lines, "record", function()
		AppendRecordLines(lines)
	end)

	SafeSection(lines, "scoreboard", function()
		AppendScoreLines(lines)
	end)

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

---Dumps every place retail could be keeping the dampening number: the player's own auras, every
---widget set, and the commentator API. Nothing here feeds the display.
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
