-- Drives the /minidampen slash command the same way a player types it, and reads back what it
-- printed or changed. Config.lua's widget layout itself is not asserted here: the mock harness
-- has no notion of pixel alignment, so that part of Issue 2's fix is untested by design.

local fw = require("TestFramework")
local Arena = require("Arena")

local function StripColor(text)
	return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

fw.describe("MiniDampen - slash command aliases", function()
	fw.before_each(function()
		Arena.Build()
	end)

	fw.it("registers every alias against the one handler", function()
		local registered = {}

		for i = 1, 8 do
			local command = _G["SLASH_MINIDAMPEN" .. i]

			if command then
				registered[command] = true
			end
		end

		fw.truthy(registered["/minidampen"], "the full name")
		fw.truthy(registered["/mdampen"], "the medium alias")
		fw.truthy(registered["/md"], "the short alias")
	end)

	fw.it("opens the settings panel on a bare command", function()
		local opened = false
		local previous = Settings.OpenToCategory

		Settings.OpenToCategory = function()
			opened = true
		end

		SlashCmdList.MINIDAMPEN("")
		Settings.OpenToCategory = previous

		fw.truthy(opened, "a bare /minidampen opens the options rather than printing usage")
	end)
end)

fw.describe("MiniDampen - /minidampen dampening", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	fw.it("forces the displayed value, bracket-marked, until cleared", function()
		SlashCmdList.MINIDAMPEN("dampening 42")

		local text = StripColor(env.Addon.Display.DampeningBlock.Value:GetText())

		fw.eq(text, "Dampening [42%]", "forced through the slash command the same way SetForcedDampening renders it")

		SlashCmdList.MINIDAMPEN("dampening clear")

		fw.falsy(env.Addon.Display.DampeningBlock.Frame:IsShown(), "cleared, and nothing real to show outside an arena")
	end)

	fw.it("rejects a non-numeric argument with a usage message, and leaves any forced value alone", function()
		SlashCmdList.MINIDAMPEN("dampening 10")
		local before = #env.Context.Mock.State.Prints

		SlashCmdList.MINIDAMPEN("dampening banana")

		fw.eq(#env.Context.Mock.State.Prints, before + 1, "one usage message printed")

		local text = StripColor(env.Addon.Display.DampeningBlock.Value:GetText())

		fw.eq(text, "Dampening [10%]", "the earlier forced value survives a bad argument")
	end)

	fw.it("clamps an out-of-range value instead of letting it overflow the display", function()
		SlashCmdList.MINIDAMPEN("dampening -50")

		fw.eq(StripColor(env.Addon.Display.DampeningBlock.Value:GetText()), "Dampening [0%]", "negative clamps to zero")

		SlashCmdList.MINIDAMPEN("dampening 100000")

		fw.eq(StripColor(env.Addon.Display.DampeningBlock.Value:GetText()), "Dampening [999%]", "an overflow clamps to the display's ceiling")

		SlashCmdList.MINIDAMPEN("dampening clear")
	end)

	fw.it("rejects a bare argument with a usage message", function()
		local before = #env.Context.Mock.State.Prints

		SlashCmdList.MINIDAMPEN("dampening")

		fw.eq(#env.Context.Mock.State.Prints, before + 1, "one usage message printed")
	end)

	fw.it("falls through to the usage message for the retired lock and unlock commands", function()
		local before = #env.Context.Mock.State.Prints

		SlashCmdList.MINIDAMPEN("lock")

		local lines = {}

		for i = before + 1, #env.Context.Mock.State.Prints do
			lines[#lines + 1] = env.Context.Mock.State.Prints[i]
		end

		fw.truthy(#lines > 1, "the usage list printed rather than silently doing nothing")

		for _, line in ipairs(lines) do
			fw.falsy(line:find("lock", 1, true) ~= nil, "the usage list no longer advertises lock or unlock: " .. line)
		end
	end)
end)

fw.describe("MiniDampen - saved variable retirement", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	fw.it("clears the match logging flag 1.0.4 left in saved variables", function()
		_G.MiniDampenDB.Logging = true

		env.Reload()

		fw.is_nil(_G.MiniDampenDB.Logging, "nothing reads this key any more, so nothing is left behind")
	end)
end)
