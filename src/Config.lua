local addonName, addon = ...
---@type MiniFramework
local mini = addon.Framework
---@type DB
local db
---@class DB
local dbDefaults = {
	Enabled = true,
	HideBlizzardWidgets = true,
	FontSize = 16,
	-- false means the game's own default face; a shared media font name string otherwise.
	FontFace = false,
	-- The look every existing user already has, so nothing moves under them.
	FontOutline = "OUTLINE",
	CountsAnchor = { Point = "TOP", RelativeTo = "UIParent", RelativePoint = "TOP", X = 0, Y = -140 },
}
---@class Config
local M = {}
addon.Config = M

M.DbDefaults = dbDefaults
-- Read by tests. Set once in Init and never replaced.
M.Panel = nil
M.FontItems = nil

function M:Init()
	-- A styled button clashes with the stock Blizzard art around it in the settings screen.
	mini:SetCustomStyling(true, { Button = false })

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
		Divider = true,
		Test = {
			OnClick = function()
				addon.Display:SetTestMode(not addon.Display:IsTestMode())
			end,
		},
		Reset = {
			OnAccept = function()
				mini:ResetSavedVars(dbDefaults)
				addon.Display:ApplyPosition()
				addon:Refresh()
			end,
		},
	})

	local enabledChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Enabled",
		Tooltip = "Whether to enable or disable this addon.",
		GetValue = function()
			return db.Enabled
		end,
		SetValue = function(value)
			db.Enabled = value
			addon:Refresh()
		end,
	})

	enabledChk:SetPoint("TOPLEFT", header.Anchor, "BOTTOMLEFT", 0, -verticalSpacing)

	local hideWidgetsChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Hide Blizzard",
		Tooltip = "Whether to hide the Blizzard top arena widget.",
		GetValue = function()
			return db.HideBlizzardWidgets
		end,
		SetValue = function(value)
			db.HideBlizzardWidgets = value
			addon:Refresh()
		end,
	})

	hideWidgetsChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)
	hideWidgetsChk:SetPoint("LEFT", panel, "LEFT", columnStep, 0)

	local appearanceDivider = mini:Divider({
		Parent = panel,
		Text = "Appearance",
	})

	appearanceDivider:SetPoint("TOP", enabledChk, "BOTTOM", 0, -verticalSpacing)
	appearanceDivider:SetPoint("LEFT", panel, "LEFT")
	appearanceDivider:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)

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

	fontSizeSlider.Slider:SetPoint("TOPLEFT", appearanceDivider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local Fonts = addon.Fonts
	-- Resolves to the same file as leaving FontFace unset.
	local gameDefaultLabel = "Game Default"
	local fontItems = {}

	local function RebuildFontItems()
		wipe(fontItems)

		fontItems[1] = gameDefaultLabel

		for _, name in ipairs(Fonts:Names()) do
			fontItems[#fontItems + 1] = name
		end
	end

	RebuildFontItems()

	-- Catches whatever a media pack registers after Init, which runs off MiniDampen's own
	-- ADDON_LOADED and so fires before any other addon's media pack has had a chance to.
	panel:HookScript("OnShow", RebuildFontItems)

	M.Panel = panel
	M.FontItems = fontItems

	local fontLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	fontLabel:SetText("Font")
	fontLabel:SetPoint("TOPLEFT", fontSizeSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local fontDropdown = mini:Dropdown({
		Parent = panel,
		Items = fontItems,
		Tooltip = "The face every row draws in. A font registered by another addon is listed too.",
		TooltipTitle = "Font",
		Width = columnStep - horizontalSpacing,
		GetValue = function()
			return db.FontFace or gameDefaultLabel
		end,
		SetValue = function(value)
			local name = value ~= gameDefaultLabel and value or false

			if name == db.FontFace then
				return
			end

			db.FontFace = name
			addon:Refresh()
		end,
		-- Each row previews the font it names. Menu rows are pooled, so the stock face is
		-- remembered the first time a row comes through here and put back on rows that
		-- preview nothing: the Game Default row, and any font that resolves to nothing.
		DecorateItem = function(button, value)
			local text = button.fontString

			if not text then
				return
			end

			if button.MiniDampenStockFont == nil then
				button.MiniDampenStockFont = text:GetFontObject() or false
			end

			local preview = value ~= gameDefaultLabel and Fonts:PreviewObject(value) or nil

			if preview then
				text:SetFontObject(preview)
			elseif button.MiniDampenStockFont then
				text:SetFontObject(button.MiniDampenStockFont)
			end
		end,
	})

	fontDropdown:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", 0, -4)

	-- Media addons register their fonts whenever they happen to load, which is routinely after
	-- this dropdown was built.
	Fonts:OnChanged(function()
		RebuildFontItems()

		if fontDropdown.MiniRefresh then
			fontDropdown:MiniRefresh()
		end

		-- A saved face the display could not resolve draws the default until the pack carrying it
		-- arrives, so the rows need the same catch-up the list just had.
		addon:Refresh()
	end)

	local outlineItems = { "NONE", "OUTLINE", "THICKOUTLINE" }
	local outlineText = {
		NONE = "None",
		OUTLINE = "Outline",
		THICKOUTLINE = "Thick outline",
	}

	local outlineLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	outlineLabel:SetText("Outline")
	outlineLabel:SetPoint("TOP", fontLabel, "TOP", 0, 0)
	outlineLabel:SetPoint("LEFT", panel, "LEFT", columnStep, 0)

	local outlineDropdown = mini:Dropdown({
		Parent = panel,
		Items = outlineItems,
		Tooltip = "The text outline style every row draws with.",
		TooltipTitle = "Outline",
		Width = columnStep - horizontalSpacing,
		GetText = function(value)
			return outlineText[value]
		end,
		GetValue = function()
			return Fonts:SanitizeOutline(db.FontOutline)
		end,
		SetValue = function(value)
			db.FontOutline = value
			addon:Refresh()
		end,
	})

	outlineDropdown:SetPoint("TOPLEFT", outlineLabel, "BOTTOMLEFT", 0, -4)

	mini:RegisterSlashCommand(category, panel, {
		"/minidampen",
		"/mdampen",
		"/md",
	})

	local openPanel = SlashCmdList.MINIDAMPEN

	SlashCmdList.MINIDAMPEN = function(msg)
		msg = (msg or ""):lower():match("^%s*(.-)%s*$")

		if msg == "debug" then
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
			mini:NotifyWithPrefix("/minidampen debug")
			mini:NotifyWithPrefix("/minidampen probe")
			mini:NotifyWithPrefix("/minidampen dampening <percent>")
			mini:NotifyWithPrefix("/minidampen dampening clear")
			return
		end

		openPanel(msg)
	end
end
