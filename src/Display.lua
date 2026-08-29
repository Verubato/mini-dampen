local addonName, addon = ...
---@type MiniFramework
local mini = addon.Framework
local GUI = mini.GUI
local Colors = addon.Colors
local FONT_PATH = "Fonts\\FRIZQT__.TTF"
local FONT_FLAGS = "OUTLINE"
local BLOCK_HEIGHT = 20
-- Top-to-top distance between stacked rows.
local ROW_GAP = 24
-- The counts or round record, the solo shuffle round line, then dampening.
local MAX_ROWS = 3
-- Fixed gap after a legend, so nothing that follows it is ever crowded by a long label.
local VALUE_GAP = 8
local PIP_BACKING_SIZE = 12
local PIP_CURRENT_BACKING_SIZE = 14
local PIP_SPACING = 4
local PIP_TEAM_GAP = 10
local MAX_ROUNDS = 6
-- Arena teams cap at 3, so the counts row never needs more than this many pips a side.
local MAX_TEAM_SIZE = 3
local LIGHTS = "Lights"
local DAMPENING_LEGEND = "Dampening"
-- Widest text each row can produce, measured but never drawn, so the block width never jitters
-- as the live value's character count changes tick to tick.
local WIDEST_COUNTS_VALUE = "3? vs 3?"
local WIDEST_ROUNDS_VALUE = "6W - 6L?"
local WIDEST_ROUND_LINE = "Round 6/6"
-- Reserves room for a three digit percent plus a forced value's brackets, both expected readings.
local WIDEST_DAMPENING_VALUE = "[300%]"
local COUNTS_PIPS_WIDTH = (MAX_TEAM_SIZE * 2 * PIP_BACKING_SIZE) + ((MAX_TEAM_SIZE * 2 - 1) * PIP_SPACING) + PIP_TEAM_GAP
local ROUND_PIPS_WIDTH = (MAX_ROUNDS * PIP_CURRENT_BACKING_SIZE) + ((MAX_ROUNDS - 1) * PIP_SPACING)
-- Sample content drawn everywhere while unlocked, including a continuously sweeping dampening
-- value, so the display can be positioned and every colour tier previewed without a real match.
local SAMPLE_STATE = {
	isSoloShuffle = false,
	teamSize = 3,
	ally = {
		{ Alive = true, Hidden = false },
		{ Alive = true, Hidden = false },
		{ Alive = true, Hidden = false },
	},
	enemy = {
		{ Alive = true, Hidden = false },
		{ Alive = true, Hidden = false },
		{ Alive = true, Hidden = false },
	},
	dampening = 10,
	roundIndex = nil,
	roundResults = {},
}
-- Four rounds in with two won, so every pip state except unknown gets drawn.
local SAMPLE_SHUFFLE_STATE = {
	isSoloShuffle = true,
	roundIndex = 4,
	roundResults = { "win", "loss", "win" },
}
-- A full up-and-down cycle of the unlocked dampening sweep, topping out at the last colour
-- stop, which is the highest reading a match ever shows.
local SWEEP_PERIOD = 20
local SWEEP_MIN = 0
local SWEEP_MAX = 100
local UNLOCKED_REFRESH_INTERVAL = 0.2
-- Distinct from every dampening tier colour, so the border never reads as part of the reading
-- it is warning about.
local PREVIEW_BORDER = { r = 0.81, g = 0.66, b = 0.31 }
local PREVIEW_FILL = { r = 0.12, g = 0.11, b = 0.10 }
local PREVIEW_FILL_ALPHA = 0.55
-- Extra room the backdrop gets on both sides of the widest visible row, so the border never
-- hugs the text edge to edge.
local PREVIEW_PADDING = 14
-- Room above and below the rows, so the border never sits right on the text.
local PREVIEW_BACKDROP_PADDING = 6
local DEFAULT_COUNTS_ANCHOR = { Point = "TOP", RelativeTo = "UIParent", RelativePoint = "TOP", X = 0, Y = -140 }
local db
local state
local container
local countsBlock
local roundBlock
local dampeningBlock
-- Filled once in Init, so the font pass allocates nothing on a path that runs five times a
-- second while unlocked.
local allBlocks = {}
-- Refilled every Refresh, for the same reason, out of a fixed set of row slots.
local visibleRows = {}
local rowSlots = {}

for i = 1, MAX_ROWS do
	rowSlots[i] = {}
end
-- Never restore an alpha this addon did not set itself.
local didWeHide = false
local preexistingAlpha
-- Runs only while unlocked, so the sweep animates and the preview stays live even outside an
-- arena, where nothing else calls Refresh on its own.
local unlockedTicker
-- Never written to saved variables, so a forced value can't survive a reload or be mistaken
-- for a real setting.
local forcedDampening
---@class Display
local M = {}
addon.Display = M

-- Read by tests. Set once in Init and never replaced.
M.Container = nil
M.CountsBlock = nil
M.RoundBlock = nil
M.DampeningBlock = nil

local function ColorText(text, color)
	return string.format("|cff%02x%02x%02x%s|r", color[1] * 255, color[2] * 255, color[3] * 255, text)
end

local function CreatePip(parent)
	local backing = parent:CreateTexture(nil, "BACKGROUND")
	backing:SetSize(PIP_BACKING_SIZE, PIP_BACKING_SIZE)
	backing:SetColorTexture(0.08, 0.08, 0.08, 1)

	local fill = parent:CreateTexture(nil, "ARTWORK")
	fill:SetPoint("CENTER", backing, "CENTER", 0, 0)

	return { Backing = backing, Fill = fill }
end

local function SetPip(pip, backingSize, fillWidth, fillHeight, color)
	pip.Backing:Show()
	pip.Backing:SetSize(backingSize, backingSize)
	pip.Fill:SetSize(fillWidth, fillHeight)
	pip.Fill:SetColorTexture(color[1], color[2], color[3])
	pip.Fill:Show()
end

-- A slot within range but with nothing to draw yet, such as a party member still loading.
local function BlankPip(pip)
	pip.Backing:Show()
	pip.Backing:SetSize(PIP_BACKING_SIZE, PIP_BACKING_SIZE)
	pip.Fill:Hide()
end

-- A slot outside teamSize * 2, such as the unused pair in a 2v2's six-pip row.
local function HidePip(pip)
	pip.Backing:Hide()
	pip.Fill:Hide()
end

local function SetPipForEntry(pip, entry)
	if not entry.Alive then
		SetPip(pip, PIP_BACKING_SIZE, 10, 2, Colors.LIGHT_DEAD)
	elseif entry.Cleared or entry.Hidden or entry.DeathSecret then
		SetPip(pip, PIP_BACKING_SIZE, 4, 4, Colors.COUNT_HIDDEN)
	else
		SetPip(pip, PIP_BACKING_SIZE, 10, 10, Colors.LIGHT_WON)
	end
end

---Chains every pip's left edge off the one before it, with an extra gap inserted before
---midGapIndex to separate the ally and enemy halves of the counts row. nil skips the gap.
local function LayoutPips(pipsFrame, pipWidgets, midGapIndex)
	for i, pip in ipairs(pipWidgets) do
		pip.Backing:ClearAllPoints()

		if i == 1 then
			pip.Backing:SetPoint("LEFT", pipsFrame, "LEFT", 0, 0)
		else
			local gap = PIP_SPACING + ((i == midGapIndex) and PIP_TEAM_GAP or 0)
			pip.Backing:SetPoint("LEFT", pipWidgets[i - 1].Backing, "RIGHT", gap, 0)
		end
	end
end

local function RenderCountsPips(block, effState)
	local teamSize = effState.teamSize
	local pipWidgets = block.PipWidgets

	for i = 1, MAX_TEAM_SIZE * 2 do
		if i <= teamSize then
			local entry = effState.ally[i]

			if entry then
				SetPipForEntry(pipWidgets[i], entry)
			else
				BlankPip(pipWidgets[i])
			end
		elseif i <= teamSize * 2 then
			local entry = effState.enemy[i - teamSize]

			if entry then
				SetPipForEntry(pipWidgets[i], entry)
			else
				BlankPip(pipWidgets[i])
			end
		else
			HidePip(pipWidgets[i])
		end
	end

	LayoutPips(block.Pips, pipWidgets, teamSize + 1)
end

local function RenderRoundPips(block, effState)
	local pipWidgets = block.PipWidgets

	for i = 1, MAX_ROUNDS do
		local pip = pipWidgets[i]
		local result = effState.roundResults[i]

		if result == "win" then
			SetPip(pip, PIP_BACKING_SIZE, 10, 10, Colors.LIGHT_WON)
		elseif result == "loss" then
			SetPip(pip, PIP_BACKING_SIZE, 10, 2, Colors.LIGHT_LOST)
		elseif result == "unknown" then
			SetPip(pip, PIP_BACKING_SIZE, 4, 4, Colors.LIGHT_PENDING)
		elseif i == effState.roundIndex then
			SetPip(pip, PIP_CURRENT_BACKING_SIZE, 12, 12, Colors.LIGHT_CURRENT)
		else
			SetPip(pip, PIP_BACKING_SIZE, 4, 4, Colors.LIGHT_PENDING)
		end
	end

	LayoutPips(block.Pips, pipWidgets, nil)
end

---Centres the content inside a slot reserved at contentWidth, so a reading shorter than the
---widest placeholder does not hug the legend.
---@return number the row's width
local function LayoutRow(block, legendText, region, contentWidth)
	block.Legend:SetText(legendText)

	local hasLegend = legendText ~= ""
	local legendWidth = hasLegend and block.Legend:GetStringWidth() or 0
	local gap = hasLegend and VALUE_GAP or 0

	-- Measured from the row's own left rather than the legend's right, so a blank legend needs
	-- no zero-width string to anchor against.
	region:ClearAllPoints()
	region:SetPoint("CENTER", block.Frame, "LEFT", legendWidth + gap + contentWidth / 2, 0)

	local rowWidth = legendWidth + gap + contentWidth
	block.Frame:SetWidth(rowWidth)

	return rowWidth
end

local function CountsMode(effState)
	if effState.isSoloShuffle and effState.roundIndex ~= nil then
		return "rounds"
	end

	return "counts"
end

local function CountsValueText(effState)
	local allyAlive, allyTotal, allyHidden = 0, #effState.ally, false
	local enemyAlive, enemyTotal, enemyHidden = 0, #effState.enemy, false

	for _, entry in ipairs(effState.ally) do
		if entry.Alive and not entry.Cleared then
			allyAlive = allyAlive + 1
		end

		-- A latched death is a known fact. Only mark ? when clearing is the only reason this
		-- entry's fate is unknown, or when a death read has actually come back secret.
		if entry.DeathSecret or (entry.Cleared and not entry.EverDead) then
			allyHidden = true
		end
	end

	for _, entry in ipairs(effState.enemy) do
		if entry.Alive and not entry.Cleared then
			enemyAlive = enemyAlive + 1
		end

		if entry.DeathSecret or ((entry.Cleared or entry.Hidden) and not entry.EverDead) then
			enemyHidden = true
		end
	end

	local allyColor = { Colors:ForCount(allyAlive, allyTotal) }
	local enemyColor = { Colors:ForCount(enemyAlive, enemyTotal) }
	local allyText = ColorText(tostring(allyAlive), allyColor)
	local enemyText = ColorText(tostring(enemyAlive), enemyColor)

	if allyHidden then
		allyText = allyText .. ColorText("?", Colors.COUNT_HIDDEN)
	end

	if enemyHidden then
		enemyText = enemyText .. ColorText("?", Colors.COUNT_HIDDEN)
	end

	return allyText .. " vs " .. enemyText
end

---A round that settled unknown is neither a win nor a loss, so a ? marks a tally that does
---not add up yet.
local function RoundsValueText(effState)
	local wins, losses, hasUnknown = 0, 0, false

	for i = 1, MAX_ROUNDS do
		local result = effState.roundResults[i]

		if result == "win" then
			wins = wins + 1
		elseif result == "loss" then
			losses = losses + 1
		elseif result == "unknown" then
			hasUnknown = true
		end
	end

	local text = ColorText(wins .. "W", Colors.LIGHT_WON) .. " - " .. ColorText(losses .. "L", Colors.LIGHT_LOST)

	if hasUnknown then
		text = text .. ColorText("?", Colors.COUNT_HIDDEN)
	end

	return text
end

local function RoundLineText(effState)
	return "Round " .. (effState.roundIndex or 0) .. "/" .. MAX_ROUNDS
end

---A forced value never wins once a real match is in scope, so a preview left running from
---outside an arena can never be mistaken for what a live match is actually reading.
local function DampeningValueText(value)
	local forced = forcedDampening ~= nil and not state.inScope
	local shown = forced and forcedDampening or value
	local color = { Colors:ForDampening(shown) }
	local text = ColorText(shown .. "%", color)

	if forced then
		-- Brackets sit outside the coloured span deliberately, in the default text colour, so
		-- a forced reading can never be mistaken for the plain percent a live one draws.
		return "[" .. text .. "]"
	end

	return text
end

---Swaps the sample halfway through each sweep, so the solo shuffle round record gets previewed too.
local function SampleState()
	if GetTime() % SWEEP_PERIOD < SWEEP_PERIOD / 2 then
		return SAMPLE_STATE
	end

	return SAMPLE_SHUFFLE_STATE
end

---Triangle wave over SWEEP_MIN..SWEEP_MAX, rising for the first half of SWEEP_PERIOD and
---falling for the second, so a colour tier is crossed going up and again coming back down.
local function SweepDampening()
	local half = SWEEP_PERIOD / 2
	local phase = GetTime() % SWEEP_PERIOD
	local progress = phase <= half and (phase / half) or (2 - phase / half)

	return math.floor(SWEEP_MIN + (SWEEP_MAX - SWEEP_MIN) * progress + 0.5)
end

local function MeasureWidth(block, text)
	block.Measure:SetText(text)

	return block.Measure:GetStringWidth()
end

local function RenderCountsBlock(effState, lights)
	local mode = CountsMode(effState)

	if lights then
		local contentWidth

		if mode == "rounds" then
			RenderRoundPips(countsBlock, effState)
			contentWidth = ROUND_PIPS_WIDTH
		else
			RenderCountsPips(countsBlock, effState)
			contentWidth = COUNTS_PIPS_WIDTH
		end

		-- A CENTER anchor needs a real width to centre around.
		countsBlock.Pips:SetWidth(contentWidth)

		return LayoutRow(countsBlock, "", countsBlock.Pips, contentWidth)
	end

	countsBlock.Value:SetText(mode == "rounds" and RoundsValueText(effState) or CountsValueText(effState))

	local widestValue = mode == "rounds" and WIDEST_ROUNDS_VALUE or WIDEST_COUNTS_VALUE

	return LayoutRow(countsBlock, "", countsBlock.Value, MeasureWidth(countsBlock, widestValue))
end

---The widest the counts row gets in either mode. The unlocked preview alternates between the
---two, and a container sized to whichever is showing would resize under the cursor mid-drag.
local function PreviewCountsWidth(lights)
	local counts = lights and COUNTS_PIPS_WIDTH or MeasureWidth(countsBlock, WIDEST_COUNTS_VALUE)
	local rounds = lights and ROUND_PIPS_WIDTH or MeasureWidth(countsBlock, WIDEST_ROUNDS_VALUE)

	return math.max(counts, rounds)
end

local function RenderRoundBlock(effState)
	roundBlock.Value:SetText(RoundLineText(effState))

	return LayoutRow(roundBlock, "", roundBlock.Value, MeasureWidth(roundBlock, WIDEST_ROUND_LINE))
end

-- Lights applies to the counts and round-record row only: MiniDampen's whole point is the
-- dampening percentage, and a single gradient pip is not legible alone.
local function RenderDampeningBlock(value)
	dampeningBlock.Value:SetText(DampeningValueText(value))

	return LayoutRow(dampeningBlock, DAMPENING_LEGEND, dampeningBlock.Value, MeasureWidth(dampeningBlock, WIDEST_DAMPENING_VALUE))
end

local function AddRow(block, width)
	local index = #visibleRows + 1
	local row = rowSlots[index]

	row.Block = block
	row.Width = width
	visibleRows[index] = row
end

local function ContainerHeight(rows)
	return math.max(rows - 1, 0) * ROW_GAP + BLOCK_HEIGHT
end

---Stacks rows from the container's top down. reservedRows and reservedWidth are what the
---container sizes itself to, which the preview holds above what is drawn right now.
local function LayoutContainer(rows, reservedRows, reservedWidth, unlocked)
	local width = math.max(reservedWidth, 1)

	for i, row in ipairs(rows) do
		row.Block.Frame:ClearAllPoints()
		row.Block.Frame:SetPoint("TOP", container.Frame, "TOP", 0, -(i - 1) * ROW_GAP)

		width = math.max(width, row.Width)
	end

	container.Frame:SetHeight(ContainerHeight(reservedRows))

	-- The backdrop art bakes its height in when it is built, so the one matching the container's
	-- current height is shown rather than resized.
	for i = 1, MAX_ROWS do
		container.Backdrops[i]:SetShown(i == reservedRows)
	end

	container.Frame:SetWidth(width + (unlocked and PREVIEW_PADDING or 0))
	container.Frame:SetShown(#rows > 0)
end

local function ApplyFonts()
	for _, block in ipairs(allBlocks) do
		block.Legend:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
		block.Value:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
		block.Measure:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
	end
end

---SetAlpha rather than Hide, because UIWidgetTopCenterContainerFrame's own visibility gate
---undoes a Hide whenever its widget set re-registers.
local function ApplyWidgetDimming(inScope)
	local widgetContainer = _G.UIWidgetTopCenterContainerFrame

	if not widgetContainer then
		return
	end

	local shouldHide = inScope and db.HideBlizzardWidgets

	if shouldHide and not didWeHide then
		preexistingAlpha = widgetContainer:GetAlpha()
		widgetContainer:SetAlpha(0)
		didWeHide = true
	elseif not shouldHide and didWeHide then
		widgetContainer:SetAlpha(preexistingAlpha)
		didWeHide = false
	end
end

local function SetPreviewShown(target, shown)
	target.PreviewFrame:SetShown(shown)
	target.PreviewLabel:SetShown(shown)
end

---The dampening row never draws Lights, a single gradient pip is not legible alone, so it
---passes withPips = false and gets no pip widgets.
local function BuildBlock(parent, frameName, withPips)
	local frame = CreateFrame("Frame", frameName, parent)
	frame:SetHeight(BLOCK_HEIGHT)

	local legend = frame:CreateFontString(nil, "OVERLAY")
	legend:SetPoint("LEFT", frame, "LEFT", 0, 0)

	local value = frame:CreateFontString(nil, "OVERLAY")
	value:SetPoint("LEFT", legend, "RIGHT", VALUE_GAP, 0)

	-- Never shown: exists only so GetStringWidth() can be asked about a placeholder without
	-- disturbing whatever text the legend or value is actually displaying.
	local measure = frame:CreateFontString(nil, "OVERLAY")
	measure:Hide()

	local pips, pipWidgets

	if withPips then
		pips = CreateFrame("Frame", nil, frame)
		pips:SetHeight(PIP_BACKING_SIZE)
		pips:SetPoint("LEFT", legend, "RIGHT", VALUE_GAP, 0)

		pipWidgets = {}

		for i = 1, MAX_ROUNDS do
			pipWidgets[i] = CreatePip(pips)
		end
	end

	return {
		Frame = frame,
		Legend = legend,
		Value = value,
		Measure = measure,
		Pips = pips,
		PipWidgets = pipWidgets,
	}
end

---Bordered and tinted, shown only while unlocked, so sample content can never be mistaken for
---a live reading.
local function BuildPreviewBackdrop(parent, containerHeight)
	local box = CreateFrame("Frame", nil, parent)
	box:SetAllPoints(parent)

	local field = GUI.RoundedField(box, containerHeight + PREVIEW_BACKDROP_PADDING, "BACKGROUND")
	field.Fill:SetColor(PREVIEW_FILL.r, PREVIEW_FILL.g, PREVIEW_FILL.b, PREVIEW_FILL_ALPHA)
	field.Border:SetColor(PREVIEW_BORDER.r, PREVIEW_BORDER.g, PREVIEW_BORDER.b, 1)

	return box
end

---Builds the single draggable frame every row sits on.
local function BuildContainer(frameName, anchorDb, defaultAnchor)
	local frame = CreateFrame("Frame", frameName, UIParent)

	-- A dedicated child, so the whole backdrop toggles with one SetShown instead of touching
	-- GUI.RoundedField's ThreeSlice pieces, which Namespace.lua marks as not public API.
	local previewFrame = CreateFrame("Frame", nil, frame)
	previewFrame:SetAllPoints(frame)
	-- BACKGROUND strata keeps it behind the rows' own text regardless of frame level.
	previewFrame:SetFrameStrata("BACKGROUND")

	local backdrops = {}

	for i = 1, MAX_ROWS do
		backdrops[i] = BuildPreviewBackdrop(previewFrame, ContainerHeight(i))
	end

	local previewLabel = frame:CreateFontString(nil, "OVERLAY")
	previewLabel:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
	previewLabel:SetFont(FONT_PATH, 10, FONT_FLAGS)
	previewLabel:SetText("PREVIEW")
	previewLabel:SetTextColor(PREVIEW_BORDER.r, PREVIEW_BORDER.g, PREVIEW_BORDER.b, 1)

	mini:MakeMovable(frame, anchorDb, { IsLocked = function() return db.Locked end })
	mini:ApplyPosition(frame, anchorDb, defaultAnchor)

	local built = {
		Frame = frame,
		PreviewFrame = previewFrame,
		PreviewLabel = previewLabel,
		Backdrops = backdrops,
	}

	-- Otherwise the container draws a PREVIEW caption at width 0 for the moment between Init
	-- and the first Refresh.
	SetPreviewShown(built, false)

	return built
end

local function ApplyUnlockedTicker(unlocked)
	if unlocked and not unlockedTicker then
		unlockedTicker = C_Timer.NewTicker(UNLOCKED_REFRESH_INTERVAL, function()
			M:Refresh()
		end)
	elseif not unlocked and unlockedTicker then
		unlockedTicker:Cancel()
		unlockedTicker = nil
	end
end

function M:SetStyle(style)
	local lights = style == LIGHTS

	countsBlock.Value:SetShown(not lights)
	countsBlock.Pips:SetShown(lights)
end

---Forces the dampening block to a specific percent, bracket-marked so it never reads as a
---live value, until cleared. Yields to a real arena the moment one is in scope, so a forgotten
---preview can never be mistaken for what a live match is actually reading.
---@param value number? nil clears the override
function M:SetForcedDampening(value)
	forcedDampening = value
	self:Refresh()
end

---Read by MatchState:Debug(), so a forced value that would otherwise silently outlive its
---preview still shows up in the one diagnostic meant to catch that.
function M:GetForcedDampening()
	return forcedDampening
end

function M:Refresh()
	ApplyWidgetDimming(state.inScope)
	self:SetStyle(db.DisplayStyle)
	ApplyFonts()

	local unlocked = not db.Locked

	ApplyUnlockedTicker(unlocked)

	local effState = unlocked and SampleState() or state
	local dampeningValue = unlocked and SweepDampening() or effState.dampening
	local visible = unlocked or state.inScope
	local lights = db.DisplayStyle == LIGHTS
	local showCounts = visible and db.ShowCounts
	-- A forced value only wins while no real arena is in scope, since it is an explicit
	-- diagnostic the user just asked for, not a reading that should outlive a real match starting.
	local forcedActive = forcedDampening ~= nil and not state.inScope
	local showDampening = db.ShowDampening and (forcedActive or (visible and dampeningValue ~= nil))
	-- The round line rides the counts toggle, since it is the other half of the same reading.
	local showRounds = showCounts and CountsMode(effState) == "rounds"

	countsBlock.Frame:SetShown(showCounts)
	roundBlock.Frame:SetShown(showRounds)
	dampeningBlock.Frame:SetShown(showDampening)

	mini:SetPositionLocked(container.Frame, db.Locked)
	SetPreviewShown(container, unlocked)

	wipe(visibleRows)

	if showCounts then
		local width = RenderCountsBlock(effState, lights)

		AddRow(countsBlock, unlocked and PreviewCountsWidth(lights) or width)
	end

	if showRounds then
		AddRow(roundBlock, RenderRoundBlock(effState))
	end

	if showDampening then
		AddRow(dampeningBlock, RenderDampeningBlock(dampeningValue))
	end

	-- The preview alternates between a two row and a three row layout, so while unlocked the
	-- container holds every row the current settings can produce rather than what is drawn now.
	local reservedRows = #visibleRows
	local reservedWidth = 0

	if unlocked then
		reservedRows = (showCounts and 2 or 0) + (showDampening and 1 or 0)
		reservedWidth = showCounts and MeasureWidth(roundBlock, WIDEST_ROUND_LINE) or 0
	end

	LayoutContainer(visibleRows, reservedRows, reservedWidth, unlocked)
end

function M:Init()
	db = mini:GetSavedVars()
	state = addon.MatchState.State

	container = BuildContainer(addonName .. "Frame", db.CountsAnchor, DEFAULT_COUNTS_ANCHOR)
	countsBlock = BuildBlock(container.Frame, addonName .. "CountsFrame", true)
	roundBlock = BuildBlock(container.Frame, addonName .. "RoundFrame", false)
	dampeningBlock = BuildBlock(container.Frame, addonName .. "DampeningFrame", false)

	allBlocks[1] = countsBlock
	allBlocks[2] = roundBlock
	allBlocks[3] = dampeningBlock

	M.Container = container
	M.CountsBlock = countsBlock
	M.RoundBlock = roundBlock
	M.DampeningBlock = dampeningBlock

	self:SetStyle(db.DisplayStyle)
end
