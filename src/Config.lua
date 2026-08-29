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
	local columns = 2
	local columnStep = mini:ColumnWidth(columns, horizontalSpacing, 0)

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
		Tooltip = "Unlock to show the display everywhere with sample data, and drag it into place.",
		GetValue = function()
			return db.Locked
		end,
		SetValue = function(value)
			db.Locked = value
			addon:Refresh()
		end,
	})

	lockedChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)
	lockedChk:SetPoint("LEFT", panel, "LEFT", columnStep, 0)

	local showCountsChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Show counts",
		Tooltip = "Draws the alive-count row, or the round record in solo shuffle.",
		GetValue = function()
			return db.ShowCounts
		end,
		SetValue = function(value)
			db.ShowCounts = value
			addon:Refresh()
		end,
	})

	showCountsChk:SetPoint("TOPLEFT", enabledChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local showDampeningChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Show dampening",
		Tooltip = "Draws the current dampening percentage row.",
		GetValue = function()
			return db.ShowDampening
		end,
		SetValue = function(value)
			db.ShowDampening = value
			addon:Refresh()
		end,
	})

	showDampeningChk:SetPoint("TOP", showCountsChk, "TOP", 0, 0)
	showDampeningChk:SetPoint("LEFT", panel, "LEFT", columnStep, 0)

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

	hideWidgetsChk:SetPoint("TOPLEFT", showCountsChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local styleDivider = mini:Divider({
		Parent = panel,
		Text = "Appearance",
	})

	styleDivider:SetPoint("TOP", hideWidgetsChk, "BOTTOM", 0, -verticalSpacing)
	styleDivider:SetPoint("LEFT", panel, "LEFT")
	styleDivider:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)

	-- One column. The label is kept short because Dropdown subtracts it from Width, and a long
	-- one squeezes the box itself.
	local styleDdl = mini:Dropdown({
		Parent = panel,
		Width = columnStep,
		LabelText = "Style",
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

	-- Full width, so the slider has enough travel to land on a value precisely.
	local fontSizeSlider = mini:Slider({
		Parent = panel,
		Min = 10,
		Max = 24,
		Step = 1,
		Width = columnStep * columns - horizontalSpacing,
		LabelText = "Font size",
		GetValue = function()
			return db.FontSize
		end,
		SetValue = function(value)
			db.FontSize = mini:ClampInt(value, 10, 24, dbDefaults.FontSize)
			addon:Refresh()
		end,
	})

	-- Anchored to the dropdown's label, not the control, since LabelText offsets the control to
	-- the label's right and anchoring to the control would drift "Font size" off Style's left
	-- edge.
	fontSizeSlider.Slider:SetPoint("TOPLEFT", styleDdl.Label, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	panel:HookScript("OnShow", function()
		styleDdl:MiniRefresh()
	end)

	mini:RegisterSlashCommand(category, panel, {
		"/minidampen",
		"/mdampen",
		"/md",
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
		elseif msg == "debug" then
			-- Never gated on combat, since reading these values mid-fight, where /dump itself
			-- is refused, is the entire point of this command.
			for _, line in ipairs(addon.MatchState:Debug()) do
				mini:NotifyWithPrefix(line)
			end
			return
		elseif msg == "probe" then
			-- Passed as an argument rather than as the format string, because a widget's own
			-- text carries a literal percent sign.
			for _, line in ipairs(addon.MatchState:Probe()) do
				mini:NotifyWithPrefix("%s", line)
			end
			return
		end

		if msg == "dampening" then
			mini:NotifyWithPrefix("/minidampen dampening <percent> or /minidampen dampening clear")
			return
		end

		local dampeningArg = msg:match("^dampening%s+(.+)$")

		if dampeningArg then
			if dampeningArg == "clear" then
				addon.Display:SetForcedDampening(nil)
				return
			end

			local value = mini:ClampInt(dampeningArg, 0, 999, nil)

			if not value then
				mini:NotifyWithPrefix("/minidampen dampening <percent> or /minidampen dampening clear")
				return
			end

			addon.Display:SetForcedDampening(value)
			return
		end

		if msg ~= "" then
			mini:NotifyWithPrefix("Commands:")
			mini:NotifyWithPrefix("/minidampen lock")
			mini:NotifyWithPrefix("/minidampen unlock")
			mini:NotifyWithPrefix("/minidampen debug")
			mini:NotifyWithPrefix("/minidampen probe")
			mini:NotifyWithPrefix("/minidampen dampening <percent>")
			mini:NotifyWithPrefix("/minidampen dampening clear")
			return
		end

		openPanel(msg)
	end
end
