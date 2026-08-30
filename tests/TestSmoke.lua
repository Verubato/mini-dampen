-- Loads the whole addon into a mocked client and drives it through login.
-- The shared body lives in build/Lua/SmokeTest.lua.

local fw = require("TestFramework")
local smoke = require("SmokeTest")

---The reload check leaves WowMock's frame list holding a second copy of the addon, so a
---lookup goes through this panel's own children.
---@param context table
---@return table[]
local function PanelChildren(context)
	return { context.Addon.Config.Panel:GetChildren() }
end

---The section rule is built by the framework and never handed back to the addon, so a test
---finds it the way a player sees it, by its label.
---@param context table
---@param text string
---@return boolean
local function HasDivider(context, text)
	for _, frame in ipairs(PanelChildren(context)) do
		if frame.Label and frame.Label.GetText and frame.Label:GetText() == text then
			return true
		end
	end

	return false
end

---The header's buttons are frames the framework owns, so a test reaches them by their label.
---@param context table
---@param label string
---@return table?
local function FindButton(context, label)
	for _, frame in ipairs(PanelChildren(context)) do
		if frame.GetText and frame:GetText() == label and frame.Click then
			return frame
		end
	end

	return nil
end

---A switch carries its label on a child fontstring rather than its own text.
---@param context table
---@param label string
---@return table?
local function FindCheckbox(context, label)
	for _, frame in ipairs(PanelChildren(context)) do
		if frame.GetChecked and frame.Text and frame.Text.GetText and frame.Text:GetText() == label then
			return frame
		end
	end

	return nil
end

---The client does nothing with a prompt in the mock, so a test stands in for it.
---@param open fun()
local function AcceptConfirm(open)
	local seen
	local real = StaticPopup_Show

	StaticPopup_Show = function(which, _, _, data)
		seen = { Which = which, Data = data }
	end

	local ok, err = pcall(open)

	StaticPopup_Show = real

	if not ok then
		error(err, 0)
	end

	if not seen then
		error("no confirmation was opened")
	end

	StaticPopupDialogs[seen.Which].OnAccept(nil, seen.Data)
end

---@param context table
local function CheckPanelButtonsAndReset(context)
	fw.eq(context.Addon.Framework.CustomStyling, true, "custom styling on")
	fw.eq(context.Addon.Framework.CustomStylingOverrides.Button, false, "stock buttons")
	fw.truthy(HasDivider(context, "SETTINGS"), "the settings section rule under the header")

	local test = FindButton(context, "Test")
	local reset = FindButton(context, "Reset to Defaults")

	fw.not_nil(test, "the test button exists")
	fw.not_nil(reset, "the reset button exists")

	local point, relativeTo, relativePoint = test:GetPoint()

	fw.eq(point, "RIGHT", "the test button's own anchor point")
	fw.eq(relativeTo, reset, "anchored off the reset button")
	fw.eq(relativePoint, "LEFT", "onto the reset button's left edge")

	fw.not_nil(FindCheckbox(context, "Enabled"), "FindCheckbox can find a checkbox that is actually there")
	fw.is_nil(FindCheckbox(context, "Locked"), "the Locked checkbox is gone from the panel")

	fw.falsy(context.Addon.Display:IsTestMode(), "test mode starts off")

	test:Click()

	fw.truthy(context.Addon.Display:IsTestMode(), "the Test button switches test mode on")

	test:Click()

	fw.falsy(context.Addon.Display:IsTestMode(), "clicking it again switches test mode back off")

	local db = _G.MiniDampenDB
	db.FontSize = 22

	local container = context.Addon.Display.Container.Frame

	container:ClearAllPoints()
	container:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 111, 222)
	context.Addon.Framework:SavePosition(container, db.CountsAnchor)

	AcceptConfirm(function()
		reset:Click()
	end)

	fw.eq(db.FontSize, context.Addon.Config.DbDefaults.FontSize, "reset restored a changed saved variable")

	local resetPoint, resetRelativeTo, resetRelativePoint, resetX, resetY = container:GetPoint(1)
	local defaultAnchor = context.Addon.Config.DbDefaults.CountsAnchor

	fw.eq(resetPoint, defaultAnchor.Point, "reset moved the frame back to its default point")
	fw.eq(resetRelativeTo, _G[defaultAnchor.RelativeTo], "reset moved the frame back onto its default relative frame")
	fw.eq(resetRelativePoint, defaultAnchor.RelativePoint, "reset moved the frame back to its default relative point")
	fw.eq(resetX, defaultAnchor.X, "reset moved the frame back to its default X")
	fw.eq(resetY, defaultAnchor.Y, "reset moved the frame back to its default Y")
end

smoke.Run("MiniDampen", { extra = CheckPanelButtonsAndReset })
