local addonName, addon = ...
---@type MiniFramework
local mini = addon.Framework
---@type DB
local db
---@class DB
local dbDefaults = {
	Enabled = true,
	DisplayStyle = "Numbers",
	ShowCounts = true,
	ShowDampening = true,
	HideBlizzardWidgets = true,
	Locked = true,
	FontSize = 16,
	CountsAnchor = { Point = "TOP", RelativeTo = "UIParent", RelativePoint = "TOP", X = 0, Y = -140 },
	DampeningAnchor = { Point = "TOP", RelativeTo = "UIParent", RelativePoint = "TOP", X = 0, Y = -164 },
}
---@class Config
local M = {}
addon.Config = M

function M:Init()
	db = mini:GetSavedVars(dbDefaults)

	local panel = CreateFrame("Frame")
	panel.name = addonName

	local category = mini:AddCategory(panel)

	if not category then
		return
	end

	local verticalSpacing = mini.VerticalSpacing
	local horizontalSpacing = mini.HorizontalSpacing

	local header = mini:PanelHeader({
		Parent = panel,
		Description = "Shows a team alive-count, the current dampening percentage, and your solo shuffle round record in arena.",
		Gap = 6,
	})

	local enabledChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Enabled",
		Tooltip = "Master switch. Off leaves the addon dormant everywhere, including in arena.",
		GetValue = function()
			return db.Enabled
		end,
		SetValue = function(value)
			db.Enabled = value
			addon:Refresh()
		end,
	})

	enabledChk:SetPoint("TOPLEFT", header.Anchor, "BOTTOMLEFT", 0, -verticalSpacing)

	local lockedChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Locked",
		Tooltip = "Unlock to show both blocks everywhere with sample data, and drag them into place.",
		GetValue = function()
			return db.Locked
		end,
		SetValue = function(value)
			db.Locked = value
			addon:Refresh()
		end,
	})

	lockedChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)
	lockedChk:SetPoint("LEFT", panel, "LEFT", 200, 0)

	local showCountsChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Show counts",
		Tooltip = "Draws the alive-count block, or the round record in solo shuffle.",
		GetValue = function()
			return db.ShowCounts
		end,
		SetValue = function(value)
			db.ShowCounts = value
			addon:Refresh()
		end,
	})

	showCountsChk:SetPoint("TOPLEFT", enabledChk, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local showDampeningChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Show dampening",
		Tooltip = "Draws the current dampening percentage block.",
		GetValue = function()
			return db.ShowDampening
		end,
		SetValue = function(value)
			db.ShowDampening = value
			addon:Refresh()
		end,
	})

	showDampeningChk:SetPoint("TOP", showCountsChk, "TOP", 0, 0)
	showDampeningChk:SetPoint("LEFT", panel, "LEFT", 200, 0)

	local hideWidgetsChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Hide Blizzard widgets",
		Tooltip = "Dims Blizzard's own top-center arena widgets while in an arena.",
		GetValue = function()
			return db.HideBlizzardWidgets
		end,
		SetValue = function(value)
			db.HideBlizzardWidgets = value
			addon:Refresh()
		end,
	})

	hideWidgetsChk:SetPoint("TOPLEFT", showCountsChk, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local styleDivider = mini:Divider({
		Parent = panel,
		Text = "Style",
	})

	styleDivider:SetPoint("TOP", hideWidgetsChk, "BOTTOM", 0, -verticalSpacing)
	styleDivider:SetPoint("LEFT", panel, "LEFT")
	styleDivider:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)

	local styleDdl = mini:Dropdown({
		Parent = panel,
		Width = 160,
		LabelText = "Display style",
		Tooltip = "Numbers shows counts and percentages. Lights replaces them with shape-coded pips.",
		Items = { "Numbers", "Lights" },
		GetValue = function()
			return db.DisplayStyle
		end,
		SetValue = function(value)
			db.DisplayStyle = value
			addon:Refresh()
		end,
	})

	styleDdl.Label:SetPoint("TOPLEFT", styleDivider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local fontSizeSlider = mini:Slider({
		Parent = panel,
		Min = 10,
		Max = 24,
		Step = 1,
		Width = 160,
		LabelText = "Font size",
		GetValue = function()
			return db.FontSize
		end,
		SetValue = function(value)
			db.FontSize = mini:ClampInt(value, 10, 24, dbDefaults.FontSize)
			addon:Refresh()
		end,
	})

	fontSizeSlider.Slider:SetPoint("TOPLEFT", styleDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	panel:HookScript("OnShow", function()
		styleDdl:MiniRefresh()
	end)

	mini:RegisterSlashCommand(category, panel, {
		"/minidampen",
		"/mdampen",
	})

	local openPanel = SlashCmdList.MINIDAMPEN

	SlashCmdList.MINIDAMPEN = function(msg)
		msg = (msg or ""):lower():match("^%s*(.-)%s*$")

		if msg == "lock" then
			db.Locked = true
			addon:Refresh()
			return
		elseif msg == "unlock" then
			db.Locked = false
			addon:Refresh()
			return
		end

		openPanel(msg)
	end
end
