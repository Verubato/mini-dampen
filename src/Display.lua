local addonName, addon = ...
---@type MiniFramework
local mini = addon.Framework
local GUI = mini.GUI
local Colors = addon.Colors
local Fonts = addon.Fonts
local BLOCK_HEIGHT = 20
-- Top-to-top distance between stacked rows.
local ROW_GAP = 24
-- The counts or round record, the solo shuffle round line, then dampening.
local MAX_ROWS = 3
-- Fixed gap after a legend, so nothing that follows it is ever crowded by a long label.
local VALUE_GAP = 8
local MAX_ROUNDS = 6
local DAMPENING_LEGEND = "Dampening"
-- Widest text each row can produce, measured but never drawn, so the block width never jitters
-- as the live value's character count changes tick to tick.
local WIDEST_COUNTS_VALUE = "3? vs 3?"
local WIDEST_ROUNDS_VALUE = "6W - 6L?"
local WIDEST_ROUND_LINE = "Round 6/6"
-- Reserves room for a three digit percent plus a forced value's brackets, both expected readings.
local WIDEST_DAMPENING_VALUE = "[300%]"
-- Sample content drawn everywhere while unlocked, so the display can be positioned without a
-- real match.
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
	-- The round line draws in both halves of the alternation, so it needs a number here.
	roundIndex = 4,
	roundResults = {},
}
-- Part way through, so the record reads as a real scoreline rather than a fresh 0W - 0L.
local SAMPLE_SHUFFLE_STATE = {
	isSoloShuffle = true,
	roundIndex = 4,
	roundResults = { "win", "loss", "win" },
}
-- One full swap between the two samples and back.
local SAMPLE_PERIOD = 20
-- Mid-range, so the preview reads as a plausible match rather than an extreme.
local PREVIEW_DAMPENING = 50
-- Only has to catch the sample swap, which is ten seconds wide.
local UNLOCKED_REFRESH_INTERVAL = 1
-- Distinct from every dampening tier colour, so the border never reads as part of the reading
-- it is warning about.
local PREVIEW_BORDER = { r = 0.81, g = 0.66, b = 0.31 }
local PREVIEW_FILL = { r = 0.12, g = 0.11, b = 0.10 }
local PREVIEW_FILL_ALPHA = 0.55
-- Below every row's own size, so the caption never competes with the rows it labels.
local PREVIEW_LABEL_FONT_SIZE = 10
-- Extra room the backdrop gets on both sides of the widest visible row, so the border never
-- hugs the text edge to edge.
local PREVIEW_PADDING = 14
-- Room above and below the rows, so the border never sits right on the text.
local PREVIEW_BACKDROP_PADDING = 6
local DEFAULT_COUNTS_ANCHOR = { Point = "TOP", RelativeTo = "UIParent", RelativePoint = "TOP", X = 0, Y = -140 }
local db
local state
local initialised = false
local container
local countsBlock
local roundBlock
local dampeningBlock
-- Filled once in Init, so the font pass allocates nothing on a path the unlocked ticker runs.
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
-- Runs only while unlocked, so the sample swap keeps happening outside an arena, where nothing
-- else calls Refresh on its own.
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

	local text = ColorText(wins .. "W", Colors.ROUND_WON) .. " - " .. ColorText(losses .. "L", Colors.ROUND_LOST)

	if hasUnknown then
		text = text .. ColorText("?", Colors.COUNT_HIDDEN)
	end

	return text
end

local function RoundLineText(effState)
	local fraction = (effState.roundIndex or 0) .. "/" .. MAX_ROUNDS

	return "Round " .. ColorText(fraction, Colors.ROUND_NUMBER)
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

---Swaps the sample halfway through each period, so the solo shuffle round record gets previewed too.
local function SampleState()
	if GetTime() % SAMPLE_PERIOD < SAMPLE_PERIOD / 2 then
		return SAMPLE_STATE
	end

	return SAMPLE_SHUFFLE_STATE
end

local function MeasureWidth(block, text)
	block.Measure:SetText(text)

	return block.Measure:GetStringWidth()
end

local function RenderCountsBlock(effState)
	local mode = CountsMode(effState)

	countsBlock.Value:SetText(mode == "rounds" and RoundsValueText(effState) or CountsValueText(effState))

	local widestValue = mode == "rounds" and WIDEST_ROUNDS_VALUE or WIDEST_COUNTS_VALUE

	return LayoutRow(countsBlock, "", countsBlock.Value, MeasureWidth(countsBlock, widestValue))
end

local function RenderRoundBlock(effState)
	roundBlock.Value:SetText(RoundLineText(effState))

	return LayoutRow(roundBlock, "", roundBlock.Value, MeasureWidth(roundBlock, WIDEST_ROUND_LINE))
end

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

---Stacks rows from the container's top down.
local function LayoutContainer(rows, unlocked)
	local width = 1

	for i, row in ipairs(rows) do
		row.Block.Frame:ClearAllPoints()
		row.Block.Frame:SetPoint("TOP", container.Frame, "TOP", 0, -(i - 1) * ROW_GAP)

		width = math.max(width, row.Width)
	end

	container.Frame:SetHeight(ContainerHeight(#rows))

	container.Frame:SetWidth(width + (unlocked and PREVIEW_PADDING or 0))
	container.Frame:SetShown(#rows > 0)
end

---Attaches a font object only when it actually changed, so the unlocked ticker's repeat call
---allocates nothing once the display has settled on a face.
local function ApplyFontObject(fontString, object)
	if fontString:GetFontObject() == object then
		return
	end

	fontString:SetFontObject(object)

	-- A string keeps drawing its old glyphs after SetFontObject until something dirties it.
	-- Every row's Legend, Value and Measure gets a fresh SetText later in the same Refresh
	-- regardless, but the preview label's text never changes, so it needs the nudge here.
	local text = fontString:GetText()

	if text ~= nil and text ~= "" then
		fontString:SetText("")
		fontString:SetText(text)
	end
end

local function ApplyFonts()
	local object = Fonts:Object(db.FontFace, db.FontSize, db.FontOutline)

	for _, block in ipairs(allBlocks) do
		ApplyFontObject(block.Legend, object)
		ApplyFontObject(block.Value, object)
		ApplyFontObject(block.Measure, object)
	end

	ApplyFontObject(container.PreviewLabel, Fonts:Object(db.FontFace, PREVIEW_LABEL_FONT_SIZE, db.FontOutline))
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

local function BuildBlock(parent, frameName)
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

	return {
		Frame = frame,
		Legend = legend,
		Value = value,
		Measure = measure,
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

	-- The art bakes its height in. One backdrop only fits because the preview always draws every
	-- row.
	local previewBackdrop = BuildPreviewBackdrop(previewFrame, ContainerHeight(MAX_ROWS))

	-- Inherits a font because it is the one string drawn text here at build time, and SetText
	-- refuses a string with no font set. ApplyFonts replaces the object on its first pass.
	local previewLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	previewLabel:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
	previewLabel:SetText("PREVIEW")
	previewLabel:SetTextColor(PREVIEW_BORDER.r, PREVIEW_BORDER.g, PREVIEW_BORDER.b, 1)

	mini:MakeMovable(frame, anchorDb, { IsLocked = function() return db.Locked end })
	mini:ApplyPosition(frame, anchorDb, defaultAnchor)

	local built = {
		Frame = frame,
		PreviewFrame = previewFrame,
		PreviewLabel = previewLabel,
		PreviewBackdrop = previewBackdrop,
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
	-- SetForcedDampening and the unlocked ticker reach this without going through addon:Refresh.
	if not initialised then
		return
	end

	ApplyWidgetDimming(state.inScope)
	ApplyFonts()

	local unlocked = not db.Locked

	ApplyUnlockedTicker(unlocked)

	local effState = unlocked and SampleState() or state
	local dampeningValue = unlocked and PREVIEW_DAMPENING or effState.dampening
	-- The preview draws every row regardless, so the display is positioned at the full size it
	-- can reach.
	local showCounts = unlocked or state.inScope
	-- A forced value only wins while no real arena is in scope, since it is an explicit
	-- diagnostic the user just asked for, not a reading that should outlive a real match starting.
	local forcedActive = forcedDampening ~= nil and not state.inScope
	local showDampening = unlocked or forcedActive or (state.inScope and dampeningValue ~= nil)
	-- The round line rides the counts row, since it is the other half of the same reading.
	local showRounds = showCounts and (unlocked or CountsMode(effState) == "rounds")

	countsBlock.Frame:SetShown(showCounts)
	roundBlock.Frame:SetShown(showRounds)
	dampeningBlock.Frame:SetShown(showDampening)

	mini:SetPositionLocked(container.Frame, db.Locked)
	SetPreviewShown(container, unlocked)

	wipe(visibleRows)

	if showCounts then
		AddRow(countsBlock, RenderCountsBlock(effState))
	end

	if showRounds then
		AddRow(roundBlock, RenderRoundBlock(effState))
	end

	if showDampening then
		AddRow(dampeningBlock, RenderDampeningBlock(dampeningValue))
	end

	LayoutContainer(visibleRows, unlocked)
end

function M:Init()
	db = mini:GetSavedVars()
	state = addon.MatchState.State

	container = BuildContainer(addonName .. "Frame", db.CountsAnchor, DEFAULT_COUNTS_ANCHOR)
	countsBlock = BuildBlock(container.Frame, addonName .. "CountsFrame")
	roundBlock = BuildBlock(container.Frame, addonName .. "RoundFrame")
	dampeningBlock = BuildBlock(container.Frame, addonName .. "DampeningFrame")

	allBlocks[1] = countsBlock
	allBlocks[2] = roundBlock
	allBlocks[3] = dampeningBlock

	M.Container = container
	M.CountsBlock = countsBlock
	M.RoundBlock = roundBlock
	M.DampeningBlock = dampeningBlock

	initialised = true
end
