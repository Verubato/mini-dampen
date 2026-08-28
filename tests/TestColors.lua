-- Colors.lua has no WoW API surface, so it runs against plain Lua rather than the harness.

local fw = require("TestFramework")

local addon = {}
loadfile("src/Colors.lua")("MiniDampen", addon)

local Colors = addon.Colors

local function assertColor(actual, expected, label)
	local ar, ag, ab = actual[1], actual[2], actual[3]
	local er, eg, eb = expected[1], expected[2], expected[3]

	fw.eq(ar, er, label .. " r")
	fw.eq(ag, eg, label .. " g")
	fw.eq(ab, eb, label .. " b")
end

fw.describe("MiniDampen - Colors:ForCount", function()
	fw.it("returns full, hurt, critical, wiped across 3v3", function()
		assertColor({ Colors:ForCount(3, 3) }, Colors.COUNT_FULL, "3/3")
		assertColor({ Colors:ForCount(2, 3) }, Colors.COUNT_HURT, "2/3")
		assertColor({ Colors:ForCount(1, 3) }, Colors.COUNT_CRITICAL, "1/3")
		assertColor({ Colors:ForCount(0, 3) }, Colors.COUNT_WIPED, "0/3")
	end)

	fw.it("returns full, hurt, wiped across 2v2, proving it is fraction-based", function()
		assertColor({ Colors:ForCount(2, 2) }, Colors.COUNT_FULL, "2/2")
		assertColor({ Colors:ForCount(1, 2) }, Colors.COUNT_HURT, "1/2")
		assertColor({ Colors:ForCount(0, 2) }, Colors.COUNT_WIPED, "0/2")
	end)

	fw.it("does not divide by zero", function()
		assertColor({ Colors:ForCount(0, 0) }, Colors.COUNT_WIPED, "0/0")
	end)
end)

fw.describe("MiniDampen - Colors:ForDampening", function()
	fw.it("returns each stop's exact colour", function()
		assertColor({ Colors:ForDampening(0) }, { 1.00, 1.00, 1.00 }, "0")
		assertColor({ Colors:ForDampening(30) }, { 1.00, 0.85, 0.20 }, "30")
		assertColor({ Colors:ForDampening(50) }, { 1.00, 0.30, 0.25 }, "50")
		assertColor({ Colors:ForDampening(70) }, { 0.78, 0.40, 0.95 }, "70")
		assertColor({ Colors:ForDampening(100) }, { 0.55, 0.15, 0.85 }, "100")
	end)

	fw.it("sits between white and yellow at 10, on every channel", function()
		local r, g, b = Colors:ForDampening(10)

		fw.eq(r, 1.00, "red channel stays at 1.00 between white and yellow")
		fw.truthy(g < 1.00 and g > 0.85, "green channel moves from white toward yellow")
		fw.truthy(b < 1.00 and b > 0.20, "blue channel moves from white toward yellow")
	end)

	fw.it("clamps outside the first and last stop", function()
		assertColor({ Colors:ForDampening(-5) }, { 1.00, 1.00, 1.00 }, "-5")
		assertColor({ Colors:ForDampening(250) }, { 0.55, 0.15, 0.85 }, "250")
	end)
end)
