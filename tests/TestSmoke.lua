-- Loads the whole addon into a mocked client and drives it through login.
-- The shared body lives in build/Lua/SmokeTest.lua.

local fw = require("TestFramework")
local smoke = require("SmokeTest")

---The section rule is built by the framework and never handed back to the addon, so a test
---finds it the way a player sees it, by its label.
---@param context table
---@param text string
---@return boolean
local function HasDivider(context, text)
	for _, frame in ipairs(context.Mock.Frames) do
		if frame.Label and frame.Label.GetText and frame.Label:GetText() == text then
			return true
		end
	end

	return false
end

---A plain open-world login never opens the arena scope, so no frame should carry any of
---MatchState.lua's gated events. Mirrors the gatedFrame helper in TestMatchState.lua.
---@param context table
local function CheckNoArenaEventsAfterLogin(context)
	for _, frame in ipairs(context.Mock.Frames) do
		fw.falsy(frame.__events["ARENA_OPPONENT_UPDATE"], "no frame left ARENA_OPPONENT_UPDATE registered")
	end

	fw.eq(context.Addon.Framework.CustomStyling, true, "custom styling on")
	fw.eq(context.Addon.Framework.CustomStylingOverrides.Button, false, "stock buttons")
	fw.truthy(HasDivider(context, "SETTINGS"), "the settings section rule under the header")
end

smoke.Run("MiniDampen", { extra = CheckNoArenaEventsAfterLogin })
