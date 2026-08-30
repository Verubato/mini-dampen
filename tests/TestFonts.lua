-- Font face and outline drive Display.lua through the mocked font object API (CreateFontFamily,
-- SetFontObject, GetFontObject), which is why these run through the full Arena harness rather
-- than loading Fonts.lua standalone the way TestColors.lua does.

local fw = require("TestFramework")
local Arena = require("Arena")

local DEFAULT_FACE_FILE = "Fonts\\FRIZQT__.TTF"

---One entry per fontstring the four font sites touch: every row's Legend, Value and Measure.
local function FontSites(display)
	return {
		{ Name = "counts legend", Object = display.CountsBlock.Legend:GetFontObject() },
		{ Name = "counts value", Object = display.CountsBlock.Value:GetFontObject() },
		{ Name = "counts measure", Object = display.CountsBlock.Measure:GetFontObject() },
		{ Name = "round legend", Object = display.RoundBlock.Legend:GetFontObject() },
		{ Name = "round value", Object = display.RoundBlock.Value:GetFontObject() },
		{ Name = "round measure", Object = display.RoundBlock.Measure:GetFontObject() },
		{ Name = "dampening legend", Object = display.DampeningBlock.Legend:GetFontObject() },
		{ Name = "dampening value", Object = display.DampeningBlock.Value:GetFontObject() },
		{ Name = "dampening measure", Object = display.DampeningBlock.Measure:GetFontObject() },
	}
end

fw.describe("MiniDampen - font defaults", function()
	fw.it("adds FontFace and FontOutline to the saved defaults", function()
		Arena.Build()

		fw.eq(_G.MiniDampenDB.FontFace, false, "no face picked out of the box")
		fw.eq(_G.MiniDampenDB.FontOutline, "OUTLINE", "matches the look MiniDampen drew before this was an option")
	end)
end)

fw.describe("MiniDampen - font face application", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
		env.Addon.Display:Refresh()
	end)

	fw.it("changes the object on every row's Legend, Value and Measure", function()
		local display = env.Addon.Display
		local before = FontSites(display)

		_G.MiniDampenDB.FontFace = "Arial Narrow"
		display:Refresh()

		local after = FontSites(display)

		fw.eq(#after, 9, "fixture: still asking about every font site")

		for i = 1, #before do
			fw.truthy(after[i].Object ~= nil, after[i].Name .. " picked up a real object")
			fw.truthy(before[i].Object ~= after[i].Object, before[i].Name .. " picked up the new face's object")
		end
	end)

	fw.it("falls back to the game default when the stored face is not registered this session", function()
		_G.MiniDampenDB.FontFace = "SomeDisabledPack"

		fw.no_error(function()
			env.Addon.Display:Refresh()
		end, "an unresolved face never errors")

		local file = env.Addon.Display.CountsBlock.Value:GetFontObject():GetFont()

		fw.eq(file, DEFAULT_FACE_FILE, "drew the client's own default face instead of erroring")
	end)

	fw.it("draws the file a media pack registered with LibSharedMedia, once it has", function()
		local packFace = "Interface\\AddOns\\SomeMediaPack\\expressway.ttf"

		env.RegisterFont("Expressway", packFace)
		_G.MiniDampenDB.FontFace = "Expressway"
		env.Addon.Display:Refresh()

		local file = env.Addon.Display.CountsBlock.Value:GetFontObject():GetFont()

		fw.eq(file, packFace, "the registered file wins once LibSharedMedia has it")
	end)

	fw.it("builds a family with a member for every alphabet, at the asked size and flags", function()
		local packFace = "Interface\\AddOns\\SomeMediaPack\\expressway.ttf"

		env.RegisterFont("Expressway", packFace)
		_G.MiniDampenDB.FontFace = "Expressway"
		_G.MiniDampenDB.FontSize = 22
		_G.MiniDampenDB.FontOutline = "THICKOUTLINE"
		env.Addon.Display:Refresh()

		local object = env.Addon.Display.CountsBlock.Value:GetFontObject()
		local members = object.__members

		fw.eq(members and #members or 0, 5, "one member per alphabet the client distinguishes")

		for _, member in ipairs(members) do
			fw.truthy(member.alphabet ~= nil, "every member is keyed by its own alphabet")
			fw.eq(member.height, 22, "at the size asked for")
			fw.eq(member.flags, "THICKOUTLINE", "at the flags asked for")
		end
	end)
end)

fw.describe("MiniDampen - font outline application", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	fw.it("'NONE' produces empty flags on the built object", function()
		_G.MiniDampenDB.FontOutline = "NONE"
		env.Addon.Display:Refresh()

		local _, _, flags = env.Addon.Display.CountsBlock.Value:GetFontObject():GetFont()

		fw.eq(flags, "", "no outline flags at all")
	end)

	fw.it("'THICKOUTLINE' produces thick flags on the built object", function()
		_G.MiniDampenDB.FontOutline = "THICKOUTLINE"
		env.Addon.Display:Refresh()

		local _, _, flags = env.Addon.Display.CountsBlock.Value:GetFontObject():GetFont()

		fw.eq(flags, "THICKOUTLINE", "the thick outline flag reaches the built object")
	end)

	fw.it("sanitizes a garbage saved outline back to the default rather than passing it to SetFont", function()
		_G.MiniDampenDB.FontOutline = "GARBAGE"
		env.Addon.Display:Refresh()

		local _, _, flags = env.Addon.Display.CountsBlock.Value:GetFontObject():GetFont()

		fw.eq(flags, "OUTLINE", "corrected back to the default outline")
	end)
end)

fw.describe("MiniDampen - font dropdown items", function()
	fw.it("picks up a font registered after Init the next time the panel opens", function()
		local env = Arena.Build()
		local panel = env.Addon.Config.Panel

		fw.truthy(panel ~= nil, "fixture: the config panel is built and exposed for tests")

		env.RegisterFont("Expressway", "Interface\\AddOns\\SomeMediaPack\\expressway.ttf")

		local foundBefore = false

		for _, name in ipairs(env.Addon.Config.FontItems) do
			foundBefore = foundBefore or name == "Expressway"
		end

		fw.truthy(not foundBefore, "fixture: the font was registered after Init already ran")

		-- A frame starts shown in the mock, so Show() alone would not re-fire OnShow.
		panel:Hide()
		panel:Show()

		local foundAfter = false

		for _, name in ipairs(env.Addon.Config.FontItems) do
			foundAfter = foundAfter or name == "Expressway"
		end

		fw.truthy(foundAfter, "the OnShow rebuild picked up the font the dropdown missed at Init")
	end)

	fw.it("redraws the rows in a saved face once the pack carrying it loads", function()
		local env = Arena.Build()

		_G.MiniDampenDB.FontFace = "Expressway"
		env.Addon.Display:Refresh()

		local drawnBefore = env.Addon.Display.CountsBlock.Value:GetFontObject()

		env.RegisterFont("Expressway", "Interface\\AddOns\\SomeMediaPack\\expressway.ttf")
		env.Tick(0)

		local drawnAfter = env.Addon.Display.CountsBlock.Value:GetFontObject()

		fw.truthy(drawnAfter ~= drawnBefore, "the rows picked up the face without waiting for an arena")
	end)
end)

fw.describe("MiniDampen - font list change notification", function()
	fw.it("coalesces several LibSharedMedia registrations in one frame into a single rebuild", function()
		local env = Arena.Build()
		local notifyCount = 0

		env.Addon.Fonts:OnChanged(function()
			notifyCount = notifyCount + 1
		end)

		env.RegisterFont("Expressway", "Interface\\AddOns\\SomeMediaPack\\expressway.ttf")
		env.RegisterFont("Accidental Presidency", "Interface\\AddOns\\SomeMediaPack\\accidental.ttf")
		env.RegisterFont("Homespun", "Interface\\AddOns\\SomeMediaPack\\homespun.ttf")

		fw.eq(notifyCount, 0, "fixture: the fan-out waits for the end of the frame")

		env.Tick(0)

		fw.eq(notifyCount, 1, "three registrations in one frame produce one rebuild, not three")
	end)
end)
