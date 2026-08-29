local addonName, addon = ...
---@type MiniFramework
local mini = addon.Framework
local GUI = mini.GUI
local Colors = addon.Colors
local FONT_PATH = "Fonts\\FRIZQT__.TTF"
local FONT_FLAGS = "OUTLINE"
local BLOCK_HEIGHT = 20
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
-- Only the round record needs a legend; "(2)-4/6" does not read on its own the way "3 vs 3" does.
local ROUNDS_LEGEND = "Rounds"
local DAMPENING_LEGEND = "Dampening"
-- Widest text each row can produce, measured but never drawn, so the block width never jitters
-- as the live value's character count changes tick to tick.
local WIDEST_COUNTS_VALUE = "3? vs 3?"
local WIDEST_ROUNDS_VALUE = "(6)-6/6"
-- Reserves room for a three digit percent plus a forced value's brackets, both expected readings.
local WIDEST_DAMPENING_VALUE = "[300%]"
local COUNTS_PIPS_WIDTH = (MAX_TEAM_SIZE * 2 * PIP_BACKING_SIZE) + ((MAX_TEAM_SIZE * 2 - 1) * PIP_SPACING) + PIP_TEAM_GAP
local ROUND_PIPS_WIDTH = (MAX_ROUNDS * PIP_CURRENT_BACKING_SIZE) + ((MAX_ROUNDS - 1) * PIP_SPACING)
-- Sample content drawn everywhere while unlocked, including a continuously sweeping dampening
-- value, so both blocks can be positioned and every colour tier previewed without a real match.
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
		{ Alive = true, Hidden = true },
		{ Alive = false, Hidden = false },
	},
	dampening = 10,
	roundIndex = nil,
	roundResults = {},
}
-- A full up-and-down cycle of the unlocked dampening sweep, ranging past the 100 stop so the
-- clamped top tier is visible too, not just the four named stops below it.
local SWEEP_PERIOD = 20
local SWEEP_MIN = 0
local SWEEP_MAX = 130
local UNLOCKED_REFRESH_INTERVAL = 0.2
-- Distinct from every dampening tier colour, so the border never reads as part of the reading
-- it is warning about.
local PREVIEW_BORDER = { r = 0.81, g = 0.66, b = 0.31 }
local PREVIEW_FILL = { r = 0.12, g = 0.11, b = 0.10 }
local PREVIEW_FILL_ALPHA = 0.55
-- Extra room the backdrop gets on both sides of the snug legend+content fit, so the border
-- never hugs the text edge to edge.
local PREVIEW_PADDING = 14
local PREVIEW_BACKDROP_HEIGHT = BLOCK_HEIGHT + 6
local DEFAULT_COUNTS_ANCHOR = { Point = "TOP", RelativeTo = "UIParent", RelativePoint = "TOP", X = 0, Y = -140 }
local DEFAULT_DAMPENING_ANCHOR = { Point = "TOP", RelativeTo = "UIParent", RelativePoint = "TOP", X = 0, Y = -164 }
local db
local state
local countsBlock
local dampeningBlock
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
M.CountsBlock = nil
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

local function RoundsValueText(effState)
	local wins = 0
	local hasUnknown = false

	for i = 1, MAX_ROUNDS do
		local result = effState.roundResults[i]

		if result == "win" then
			wins = wins + 1
		elseif result == "unknown" then
			hasUnknown = true
		end
	end

	local winsText = hasUnknown and "?" or tostring(wins)

	return "(" .. ColorText(winsText, Colors.LIGHT_WON) .. ")-" .. (effState.roundIndex or 0) .. "/" .. MAX_ROUNDS
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

---Sizes both blocks to one shared column pair, a legend width covering both labels and a
---value width covering both blocks' widest content, so the two rows line up as one table
---instead of each block centring on its own independent width.
local function ApplySharedWidth(legendWidth, countsContentWidth, dampeningContentWidth, unlocked)
	local contentWidth = math.max(countsContentWidth, dampeningContentWidth)
	local halfPadding = unlocked and (PREVIEW_PADDING / 2) or 0
	local width = legendWidth + VALUE_GAP + contentWidth + (halfPadding * 2)

	countsBlock.Legend:SetWidth(legendWidth)
	countsBlock.Legend:ClearAllPoints()
	countsBlock.Legend:SetPoint("LEFT", countsBlock.Frame, "LEFT", halfPadding, 0)
	countsBlock.Frame:SetWidth(width)

	dampeningBlock.Legend:SetWidth(legendWidth)
	dampeningBlock.Legend:ClearAllPoints()
	dampeningBlock.Legend:SetPoint("LEFT", dampeningBlock.Frame, "LEFT", halfPadding, 0)
	dampeningBlock.Frame:SetWidth(width)
end

local function RenderCountsBlock(effState, lights)
	local mode = CountsMode(effState)

	-- The legend column itself still exists, sized by ApplySharedWidth, so the value stays in
	-- the same column both rows share.
	countsBlock.Legend:SetText(mode == "rounds" and ROUNDS_LEGEND or "")

	if lights then
		if mode == "rounds" then
			RenderRoundPips(countsBlock, effState)
			return ROUND_PIPS_WIDTH
		end

		RenderCountsPips(countsBlock, effState)
		return COUNTS_PIPS_WIDTH
	end

	countsBlock.Value:SetText(mode == "rounds" and RoundsValueText(effState) or CountsValueText(effState))

	return MeasureWidth(countsBlock, mode == "rounds" and WIDEST_ROUNDS_VALUE or WIDEST_COUNTS_VALUE)
end

-- Lights applies to the counts and round-record row only: MiniDampen's whole point is the
-- dampening percentage, and a single gradient pip is not legible on its own.
local function RenderDampeningBlock(value)
	dampeningBlock.Legend:SetText(DAMPENING_LEGEND)
	dampeningBlock.Value:SetText(DampeningValueText(value))

	return MeasureWidth(dampeningBlock, WIDEST_DAMPENING_VALUE)
end

local function ApplyFonts()
	countsBlock.Legend:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
	countsBlock.Value:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
	countsBlock.Measure:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
	dampeningBlock.Legend:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
	dampeningBlock.Value:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
	dampeningBlock.Measure:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
end

---SetAlpha rather than Hide, because UIWidgetTopCenterContainerFrame's own visibility gate
---undoes a Hide whenever its widget set re-registers.
local function ApplyWidgetDimming(inScope)
	local container = _G.UIWidgetTopCenterContainerFrame

	if not container then
		return
	end

	local shouldHide = inScope and db.HideBlizzardWidgets

	if shouldHide and not didWeHide then
		preexistingAlpha = container:GetAlpha()
		container:SetAlpha(0)
		didWeHide = true
	elseif not shouldHide and didWeHide then
		container:SetAlpha(preexistingAlpha)
		didWeHide = false
	end
end

local function SetPreviewShown(block, shown)
	block.PreviewFrame:SetShown(shown)
	block.PreviewLabel:SetShown(shown)
end

---The dampening block never draws Lights, a single gradient pip is not legible alone, so it
---passes withPips = false and gets no pip widgets.
local function BuildBlock(frameName, anchorDb, defaultAnchor, withPips)
	local frame = CreateFrame("Frame", frameName, UIParent)
	frame:SetHeight(BLOCK_HEIGHT)

	local legend = frame:CreateFontString(nil, "OVERLAY")
	legend:SetJustifyH("LEFT")
	legend:SetPoint("LEFT", frame, "LEFT", 0, 0)

	local value = frame:CreateFontString(nil, "OVERLAY")
	value:SetJustifyH("LEFT")
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

	-- A dedicated child, so the whole backdrop toggles with one SetShown instead of touching
	-- GUI.RoundedField's ThreeSlice pieces, which Namespace.lua marks as not public API.
	local previewFrame = CreateFrame("Frame", nil, frame)
	previewFrame:SetAllPoints(frame)
	-- BACKGROUND strata keeps it behind the block's own text regardless of frame level.
	previewFrame:SetFrameStrata("BACKGROUND")

	-- Bordered and tinted, shown only while unlocked, so sample content can never be mistaken
	-- for a live reading.
	local previewBackdrop = GUI.RoundedField(previewFrame, PREVIEW_BACKDROP_HEIGHT, "BACKGROUND")
	previewBackdrop.Fill:SetColor(PREVIEW_FILL.r, PREVIEW_FILL.g, PREVIEW_FILL.b, PREVIEW_FILL_ALPHA)
	previewBackdrop.Border:SetColor(PREVIEW_BORDER.r, PREVIEW_BORDER.g, PREVIEW_BORDER.b, 1)

	local previewLabel = frame:CreateFontString(nil, "OVERLAY")
	previewLabel:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
	previewLabel:SetFont(FONT_PATH, 10, FONT_FLAGS)
	previewLabel:SetText("PREVIEW")
	previewLabel:SetTextColor(PREVIEW_BORDER.r, PREVIEW_BORDER.g, PREVIEW_BORDER.b, 1)

	mini:MakeMovable(frame, anchorDb, { IsLocked = function() return db.Locked end })
	mini:ApplyPosition(frame, anchorDb, defaultAnchor)

	local block = {
		Frame = frame,
		Legend = legend,
		Value = value,
		Measure = measure,
		Pips = pips,
		PipWidgets = pipWidgets,
		PreviewFrame = previewFrame,
		PreviewLabel = previewLabel,
	}

	-- Otherwise both blocks draw a PREVIEW caption at width 0 for the moment between Init and
	-- the first Refresh.
	SetPreviewShown(block, false)

	return block
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

	local effState = unlocked and SAMPLE_STATE or state
	local dampeningValue = unlocked and SweepDampening() or effState.dampening
	local visible = unlocked or state.inScope
	local lights = db.DisplayStyle == LIGHTS
	local showCounts = visible and db.ShowCounts
	-- A forced value only wins while no real arena is in scope, since it is an explicit
	-- diagnostic the user just asked for, not a reading that should outlive a real match starting.
	local forcedActive = forcedDampening ~= nil and not state.inScope
	local showDampening = db.ShowDampening and (forcedActive or (visible and dampeningValue ~= nil))

	countsBlock.Frame:SetShown(showCounts)
	dampeningBlock.Frame:SetShown(showDampening)

	mini:SetPositionLocked(countsBlock.Frame, db.Locked)
	mini:SetPositionLocked(dampeningBlock.Frame, db.Locked)

	SetPreviewShown(countsBlock, unlocked)
	SetPreviewShown(dampeningBlock, unlocked)

	-- Measured ahead of the content below, so the two placeholder reads land here rather than
	-- clobbering whatever content width Render*Block just measured into the same scratch string.
	-- ROUNDS_LEGEND stands in for the counts row's own blank legend: whichever of the two is
	-- wider still sets the shared legend column, so the value in both rows stays aligned.
	local legendWidth = math.max(MeasureWidth(countsBlock, ROUNDS_LEGEND), MeasureWidth(dampeningBlock, DAMPENING_LEGEND))
	local countsContentWidth, dampeningContentWidth = 0, 0

	if showCounts then
		countsContentWidth = RenderCountsBlock(effState, lights)
	end

	if showDampening then
		dampeningContentWidth = RenderDampeningBlock(dampeningValue)
	end

	ApplySharedWidth(legendWidth, countsContentWidth, dampeningContentWidth, unlocked)
end

function M:Init()
	db = mini:GetSavedVars()
	state = addon.MatchState.State

	countsBlock = BuildBlock(addonName .. "CountsFrame", db.CountsAnchor, DEFAULT_COUNTS_ANCHOR, true)
	dampeningBlock = BuildBlock(addonName .. "DampeningFrame", db.DampeningAnchor, DEFAULT_DAMPENING_ANCHOR, false)

	M.CountsBlock = countsBlock
	M.DampeningBlock = dampeningBlock

	self:SetStyle(db.DisplayStyle)
end
