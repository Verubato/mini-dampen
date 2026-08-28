local addonName, addon = ...
---@type MiniFramework
local mini = addon.Framework
local Colors = addon.Colors
local FONT_PATH = "Fonts\\FRIZQT__.TTF"
local FONT_FLAGS = "OUTLINE"
local BLOCK_WIDTH = 220
local BLOCK_HEIGHT = 20
local LABEL_WIDTH = 130
local PIP_BACKING_SIZE = 12
local PIP_CURRENT_BACKING_SIZE = 14
local PIP_SPACING = 4
local PIP_TEAM_GAP = 10
local MAX_ROUNDS = 6
-- Arena teams cap at 3, so the counts row never needs more than this many pips a side.
local MAX_TEAM_SIZE = 3
local LIGHTS = "Lights"
-- Sample content drawn everywhere, unlocked, so the two blocks can be positioned outside a
-- match.
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
local DEFAULT_COUNTS_ANCHOR = { Point = "TOP", RelativeTo = "UIParent", RelativePoint = "TOP", X = 0, Y = -140 }
local DEFAULT_DAMPENING_ANCHOR = { Point = "TOP", RelativeTo = "UIParent", RelativePoint = "TOP", X = 0, Y = -164 }
local db
local state
local countsBlock
local dampeningBlock
-- Never restore an alpha this addon did not set itself.
local didWeHide = false
local preexistingAlpha
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
	elseif entry.Cleared or entry.Hidden then
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

		-- A latched death is a known fact, not an uncertainty. Only mark ? when clearing is
		-- the only reason this entry's fate is unknown.
		if entry.Cleared and not entry.EverDead then
			allyHidden = true
		end
	end

	for _, entry in ipairs(effState.enemy) do
		if entry.Alive and not entry.Cleared then
			enemyAlive = enemyAlive + 1
		end

		if (entry.Cleared or entry.Hidden) and not entry.EverDead then
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

local function DampeningValueText(effState)
	local color = { Colors:ForDampening(effState.dampening) }

	return ColorText(effState.dampening .. "%", color)
end

local function RenderCountsBlock(effState, lights)
	local mode = CountsMode(effState)

	countsBlock.Legend:SetText(mode == "rounds" and "Rounds" or "Us vs Opponent")

	if lights then
		if mode == "rounds" then
			RenderRoundPips(countsBlock, effState)
		else
			RenderCountsPips(countsBlock, effState)
		end
	else
		countsBlock.Value:SetText(mode == "rounds" and RoundsValueText(effState) or CountsValueText(effState))
	end
end

-- Lights applies to the counts and round-record row only: MiniDampen's whole point is the
-- dampening percentage, and a single gradient pip is not legible on its own.
local function RenderDampeningBlock(effState)
	dampeningBlock.Legend:SetText("Dampening")
	dampeningBlock.Value:SetText(DampeningValueText(effState))
end

local function ApplyFonts()
	countsBlock.Legend:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
	countsBlock.Value:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
	dampeningBlock.Legend:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
	dampeningBlock.Value:SetFont(FONT_PATH, db.FontSize, FONT_FLAGS)
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

---The dampening block never draws Lights, a single gradient pip is not legible alone, so it
---passes withPips = false and gets no pip widgets.
local function BuildBlock(frameName, anchorDb, defaultAnchor, withPips)
	local frame = CreateFrame("Frame", frameName, UIParent)
	frame:SetSize(BLOCK_WIDTH, BLOCK_HEIGHT)

	local legend = frame:CreateFontString(nil, "OVERLAY")
	legend:SetJustifyH("LEFT")
	legend:SetPoint("LEFT", frame, "LEFT", 0, 0)

	local value = frame:CreateFontString(nil, "OVERLAY")
	value:SetJustifyH("LEFT")
	value:SetPoint("LEFT", frame, "LEFT", LABEL_WIDTH, 0)

	local pips, pipWidgets

	if withPips then
		pips = CreateFrame("Frame", nil, frame)
		pips:SetHeight(PIP_BACKING_SIZE)
		pips:SetPoint("LEFT", frame, "LEFT", LABEL_WIDTH, 0)

		pipWidgets = {}

		for i = 1, MAX_ROUNDS do
			pipWidgets[i] = CreatePip(pips)
		end
	end

	mini:MakeMovable(frame, anchorDb, { IsLocked = function() return db.Locked end })
	mini:ApplyPosition(frame, anchorDb, defaultAnchor)

	return { Frame = frame, Legend = legend, Value = value, Pips = pips, PipWidgets = pipWidgets }
end

function M:SetStyle(style)
	local lights = style == LIGHTS

	countsBlock.Value:SetShown(not lights)
	countsBlock.Pips:SetShown(lights)
end

function M:Refresh()
	ApplyWidgetDimming(state.inScope)
	self:SetStyle(db.DisplayStyle)
	ApplyFonts()

	local unlocked = not db.Locked
	local effState = unlocked and SAMPLE_STATE or state
	local visible = unlocked or state.inScope
	local lights = db.DisplayStyle == LIGHTS
	local showCounts = visible and db.ShowCounts
	local showDampening = visible and db.ShowDampening and effState.dampening ~= nil

	countsBlock.Frame:SetShown(showCounts)
	dampeningBlock.Frame:SetShown(showDampening)

	mini:SetPositionLocked(countsBlock.Frame, db.Locked)
	mini:SetPositionLocked(dampeningBlock.Frame, db.Locked)

	if showCounts then
		RenderCountsBlock(effState, lights)
	end

	if showDampening then
		RenderDampeningBlock(effState)
	end
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
