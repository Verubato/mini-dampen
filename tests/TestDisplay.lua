-- Display.lua never reads WoW APIs directly, so these drive it through tests/Helpers/Arena.lua
-- the same way TestMatchState.lua does, and read back the two blocks it built in Init.

local fw = require("TestFramework")
local Arena = require("Arena")

fw.describe("MiniDampen - style swap", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	fw.it("Lights hides the value and shows the pips, Numbers is the inverse", function()
		env.Addon.Display:SetStyle("Lights")

		fw.falsy(env.Addon.Display.CountsBlock.Value:IsShown(), "value hidden in Lights")
		fw.truthy(env.Addon.Display.CountsBlock.Pips:IsShown(), "pips shown in Lights")

		env.Addon.Display:SetStyle("Numbers")

		fw.truthy(env.Addon.Display.CountsBlock.Value:IsShown(), "value shown in Numbers")
		fw.falsy(env.Addon.Display.CountsBlock.Pips:IsShown(), "pips hidden in Numbers")
	end)

	fw.it("a second Refresh creates no new frames", function()
		env.Addon.Display:Refresh()

		local before = env.Context.Mock.AddonFrameCount()

		env.Addon.Display:Refresh()

		fw.eq(env.Context.Mock.AddonFrameCount(), before, "no new frames created")
	end)
end)

fw.describe("MiniDampen - counts pips", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
		-- Refresh() re-derives style from db on every call, including the ones the ticker
		-- triggers via Tick below, so the setting has to move rather than SetStyle alone.
		_G.MiniDampenDB.DisplayStyle = "Lights"
	end)

	fw.it("dead, hidden, and alive states draw three distinct fill sizes", function()
		env.Kill("arena1")
		env.Unseen("arena2")
		env.Tick(2)

		local pips = env.Addon.Display.CountsBlock.PipWidgets
		-- ally fills pips 1-3, enemy fills pips 4-6 at the default team size of three.
		local deadFill = pips[4].Fill
		local hiddenFill = pips[5].Fill
		local aliveFill = pips[6].Fill

		fw.eq(deadFill:GetWidth(), 10, "dead fill width")
		fw.eq(deadFill:GetHeight(), 2, "dead fill height, a flatline")
		fw.eq(hiddenFill:GetWidth(), 4, "hidden fill width")
		fw.eq(hiddenFill:GetHeight(), 4, "hidden fill height, a dot")
		fw.eq(aliveFill:GetWidth(), 10, "alive fill width")
		fw.eq(aliveFill:GetHeight(), 10, "alive fill height, a solid block")
	end)
end)

fw.describe("MiniDampen - round pips", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.SoloShuffle = true
		env.Enter()
	end)

	fw.it("the current round's pip is larger than its settled neighbours", function()
		env.SetState(2) -- StartUp, round one
		env.SetState(3) -- Engaged
		env.SetWinner(0)
		env.SetState(4) -- PostRound, round one settles

		env.SetState(2) -- StartUp, round two
		env.SetState(3) -- Engaged, round two is now current and unsettled

		_G.MiniDampenDB.DisplayStyle = "Lights"
		env.Addon.Display:Refresh()

		local pips = env.Addon.Display.CountsBlock.PipWidgets

		fw.truthy(pips[2].Backing:GetWidth() > pips[1].Backing:GetWidth(), "bigger than round one")
		fw.truthy(pips[2].Backing:GetWidth() > pips[3].Backing:GetWidth(), "bigger than round three")
	end)
end)

fw.describe("MiniDampen - dampening visibility", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	fw.it("dampening == nil hides the whole block and leaves counts in place", function()
		env.SetDampening(nil)
		env.Tick(0.5)

		fw.falsy(env.Addon.Display.DampeningBlock.Frame:IsShown(), "dampening block hidden")
		fw.truthy(env.Addon.Display.CountsBlock.Frame:IsShown(), "counts block still shown")
	end)
end)

fw.describe("MiniDampen - anchors", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	fw.it("dragging the counts block writes CountsAnchor and leaves DampeningAnchor untouched", function()
		local frame = env.Addon.Display.CountsBlock.Frame

		frame:ClearAllPoints()
		frame:SetPoint("TOP", UIParent, "TOP", 42, -99)
		frame:GetScript("OnDragStop")(frame)

		fw.eq(_G.MiniDampenDB.CountsAnchor.X, 42, "counts anchor x written")
		fw.eq(_G.MiniDampenDB.CountsAnchor.Y, -99, "counts anchor y written")
		fw.eq(_G.MiniDampenDB.DampeningAnchor.Y, -164, "dampening anchor untouched")
	end)

	fw.it("a reload restores both anchors independently from saved variables", function()
		local countsFrame = env.Addon.Display.CountsBlock.Frame

		countsFrame:ClearAllPoints()
		countsFrame:SetPoint("TOP", UIParent, "TOP", 10, -20)
		countsFrame:GetScript("OnDragStop")(countsFrame)

		env.Reload()
		env.Enter()

		local _, _, _, x, y = env.Addon.Display.CountsBlock.Frame:GetPoint(1)

		fw.eq(x, 10, "counts anchor x survived the reload")
		fw.eq(y, -20, "counts anchor y survived the reload")

		local _, _, _, dampX, dampY = env.Addon.Display.DampeningBlock.Frame:GetPoint(1)

		fw.eq(dampX, 0, "dampening anchor still at its default x")
		fw.eq(dampY, -164, "dampening anchor still at its default y")
	end)
end)

fw.describe("MiniDampen - Blizzard widget dimming", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		_G.UIWidgetTopCenterContainerFrame = CreateFrame("Frame")
	end)

	fw.it("dims on entering and restores on leaving", function()
		env.Enter()

		fw.eq(_G.UIWidgetTopCenterContainerFrame:GetAlpha(), 0, "dimmed on entering")

		env.Leave()

		fw.eq(_G.UIWidgetTopCenterContainerFrame:GetAlpha(), 1, "restored on leaving")
	end)

	fw.it("never raises an alpha it did not set", function()
		_G.UIWidgetTopCenterContainerFrame:SetAlpha(0)
		_G.MiniDampenDB.HideBlizzardWidgets = false

		env.Enter()
		env.Leave()

		fw.eq(_G.UIWidgetTopCenterContainerFrame:GetAlpha(), 0, "left exactly as found")
	end)
end)

fw.describe("MiniDampen - solo shuffle before the first round", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.SoloShuffle = true
	end)

	fw.it("draws the counts row rather than the record row when roundIndex is still nil", function()
		env.Enter()
		env.Addon.Display:SetStyle("Numbers")
		env.Addon.Display:Refresh()

		fw.is_nil(env.Addon.MatchState.State.roundIndex, "no StartUp observed yet")
		fw.eq(env.Addon.Display.CountsBlock.Legend:GetText(), "Us vs Opponent", "falls back to the counts row")
	end)
end)
