-- Drives the /minidampen slash command the same way a player types it, and reads back what it
-- printed or changed. Config.lua's widget layout itself is not asserted here: the mock harness
-- has no notion of pixel alignment, so that part of Issue 2's fix is untested by design.

local fw = require("TestFramework")
local Arena = require("Arena")

local function StripColor(text)
	return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

fw.describe("MiniDampen - /minidampen debug", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	fw.it("prints one chat line per MatchState:Debug() entry, in or out of an arena", function()
		local before = #env.Context.Mock.State.Prints

		SlashCmdList.MINIDAMPEN("debug")

		-- Five fixed lines out of an arena: header, onScreenValues, teamSize, dampening, and
		-- forcedDampening. No ally or enemy lines, since both rosters are empty outside a match.
		fw.eq(#env.Context.Mock.State.Prints - before, 5, "one NotifyWithPrefix call per debug line")
	end)

	fw.it("works with no arena entered, matching the standing rule that a diagnostic is never combat- or scope-gated", function()
		-- A clean load prints nothing on its own (see TestSmoke.lua), so this is the command's
		-- very first line.
		SlashCmdList.MINIDAMPEN("debug")

		fw.truthy(env.Context.Mock.State.Prints[1]:find("inScope=false", 1, true) ~= nil, "reports out of scope rather than erroring")
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

		fw.eq(text, "[42%]", "forced through the slash command the same way SetForcedDampening renders it")

		SlashCmdList.MINIDAMPEN("dampening clear")

		fw.falsy(env.Addon.Display.DampeningBlock.Frame:IsShown(), "cleared, and nothing real to show outside an arena")
	end)

	fw.it("rejects a non-numeric argument with a usage message, and leaves any forced value alone", function()
		SlashCmdList.MINIDAMPEN("dampening 10")
		local before = #env.Context.Mock.State.Prints

		SlashCmdList.MINIDAMPEN("dampening banana")

		fw.eq(#env.Context.Mock.State.Prints, before + 1, "one usage message printed")

		local text = StripColor(env.Addon.Display.DampeningBlock.Value:GetText())

		fw.eq(text, "[10%]", "the earlier forced value survives a bad argument")
	end)

	fw.it("clamps an out-of-range value instead of letting it overflow the display", function()
		SlashCmdList.MINIDAMPEN("dampening -50")

		fw.eq(StripColor(env.Addon.Display.DampeningBlock.Value:GetText()), "[0%]", "negative clamps to zero")

		SlashCmdList.MINIDAMPEN("dampening 100000")

		fw.eq(StripColor(env.Addon.Display.DampeningBlock.Value:GetText()), "[999%]", "an overflow clamps to the display's ceiling")

		SlashCmdList.MINIDAMPEN("dampening clear")
	end)

	fw.it("rejects a bare argument with a usage message", function()
		local before = #env.Context.Mock.State.Prints

		SlashCmdList.MINIDAMPEN("dampening")

		fw.eq(#env.Context.Mock.State.Prints, before + 1, "one usage message printed")
	end)
end)
