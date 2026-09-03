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

fw.describe("MiniDampen - /minidampen debug", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	fw.it("prints one chat line per MatchState:Debug() entry, in or out of an arena", function()
		local before = #env.Context.Mock.State.Prints

		SlashCmdList.MINIDAMPEN("debug")

		-- Debug() is side-effect free, so asking it again is what keeps this from re-breaking
		-- every time a line is added to it.
		fw.eq(
			#env.Context.Mock.State.Prints - before,
			#env.Addon.MatchState:Debug(),
			"one NotifyWithPrefix call per debug line"
		)
	end)

	fw.it("works with no arena entered, matching the standing rule that a diagnostic is never combat- or scope-gated", function()
		-- A clean load prints nothing on its own (see TestSmoke.lua), so this is the command's
		-- very first line.
		SlashCmdList.MINIDAMPEN("debug")

		fw.truthy(env.Context.Mock.State.Prints[1]:find("inScope=false", 1, true) ~= nil, "reports out of scope rather than erroring")
	end)

	fw.it("prints a widget's own text even though it carries a percent sign", function()
		env.SoloShuffle = true
		env.Enter()
		env.SetRecordWidgets(3, 6, 1, { WinsText = "100% Ready" })

		fw.no_error(function()
			SlashCmdList.MINIDAMPEN("debug")
		end, "a debug line that is not a safe format string")

		local found = false

		for _, line in ipairs(env.Context.Mock.State.Prints) do
			if line:find("100% Ready", 1, true) then
				found = true
			end
		end

		fw.truthy(found, "the text reached chat unmangled")
	end)
end)

fw.describe("MiniDampen - /minidampen log", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	fw.it("starts off, so the capture costs a chat line to nobody who never asked for one", function()
		fw.eq(_G.MiniDampenDB.Logging, false, "off out of the box")
	end)

	fw.it("turns the log on and back off", function()
		SlashCmdList.MINIDAMPEN("log on")

		fw.truthy(_G.MiniDampenDB.Logging, "on on request")

		SlashCmdList.MINIDAMPEN("log off")

		fw.falsy(_G.MiniDampenDB.Logging, "and back off again")
	end)

	fw.it("reports the setting on a bare log command", function()
		local before = #env.Context.Mock.State.Prints

		SlashCmdList.MINIDAMPEN("log")

		local line = StripColor(env.Context.Mock.State.Prints[before + 1])

		fw.truthy(line:find("Match logging is off.", 1, true) ~= nil, "says where the setting stands")
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

fw.describe("MiniDampen - /minidampen probe", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	local function PrintedSince(before)
		local prints = env.Context.Mock.State.Prints
		local lines = {}

		for i = before + 1, #prints do
			lines[#lines + 1] = prints[i]
		end

		return lines
	end

	local function FindLine(lines, needle)
		for _, line in ipairs(lines) do
			if line:find(needle, 1, true) then
				return line
			end
		end
	end

	fw.it("prints something useful out of an arena rather than erroring", function()
		local before = #env.Context.Mock.State.Prints

		fw.no_error(function()
			SlashCmdList.MINIDAMPEN("probe")
		end, "probe outside an arena")

		local lines = PrintedSince(before)

		fw.truthy(#lines > 0, "at least one line printed")
		fw.truthy(FindLine(lines, "instanceType=none") ~= nil, "says where it was run")
	end)

	fw.it("runs in an arena too", function()
		env.Enter()

		fw.no_error(function()
			SlashCmdList.MINIDAMPEN("probe")
		end, "probe inside an arena")
	end)

	fw.it("reports every aura the client hands back, on both filters", function()
		env.AddAura("HELPFUL", { name = "Dampening", spellId = 110310, points = { 20 } })
		env.AddAura("HARMFUL", { name = "Corruption", spellId = 172, points = {} })

		local before = #env.Context.Mock.State.Prints

		SlashCmdList.MINIDAMPEN("probe")

		local lines = PrintedSince(before)
		local helpful = FindLine(lines, "aura HELPFUL")
		local harmful = FindLine(lines, "aura HARMFUL")

		fw.not_nil(helpful, "the helpful aura was enumerated")
		fw.truthy(helpful:find("name=Dampening", 1, true) ~= nil, "carries the aura name")
		fw.truthy(helpful:find("spellId=110310", 1, true) ~= nil, "carries the spell id")
		fw.truthy(helpful:find("points={20}", 1, true) ~= nil, "carries the whole points array")
		fw.not_nil(harmful, "the harmful aura was enumerated too")
	end)

	fw.it("renders a secret aura field as \"secret\" rather than interpolating it", function()
		env.AddAura("HELPFUL", { name = "Dampening", spellId = Arena.SECRET, points = Arena.SECRET })

		local before = #env.Context.Mock.State.Prints

		SlashCmdList.MINIDAMPEN("probe")

		local line = FindLine(PrintedSince(before), "aura HELPFUL")

		fw.truthy(line:find("spellId=secret", 1, true) ~= nil, "the secret spell id never reached tostring")
		fw.truthy(line:find("points=secret", 1, true) ~= nil, "and the secret points array was never indexed")
	end)

	fw.it("names the top-center widgets and whatever their per-type getter returns", function()
		env.WidgetSetId = 7
		env.Widgets = { { widgetID = 42, widgetType = 0 } }
		env.WidgetInfo = { text = "Dampening 20%", shownState = 1 }

		local before = #env.Context.Mock.State.Prints

		SlashCmdList.MINIDAMPEN("probe")

		local lines = PrintedSince(before)

		fw.truthy(
			FindLine(lines, "widgetSet GetTopCenterWidgetSetID=7") ~= nil,
			"reports the set id it queried, and the getter that named it"
		)

		local widget = FindLine(lines, "widget GetTopCenterWidgetSetID id=42")

		fw.not_nil(widget, "the widget was listed")
		fw.truthy(widget:find("(IconAndText)", 1, true) ~= nil, "named its visualization type")
		fw.truthy(widget:find("text=Dampening 20%", 1, true) ~= nil, "a percent sign in widget text survives the chat path")
	end)

	fw.it("reports the commentator reading, and survives a spectator-only refusal", function()
		env.CommentatorDampening = 30

		local before = #env.Context.Mock.State.Prints

		SlashCmdList.MINIDAMPEN("probe")

		fw.truthy(
			FindLine(PrintedSince(before), "C_Commentator.GetDampeningPercent=30") ~= nil,
			"the commentator value is reported when it answers"
		)

		env.CommentatorRefuses = true
		before = #env.Context.Mock.State.Prints

		fw.no_error(function()
			SlashCmdList.MINIDAMPEN("probe")
		end, "a refused commentator call")

		fw.truthy(FindLine(PrintedSince(before), "GetDampeningPercent refused") ~= nil, "the refusal is reported, not swallowed")
	end)
end)
