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

	fw.it("Lights leaves the dampening block on Numbers, a single pip is not legible alone", function()
		env.Addon.Display:SetStyle("Lights")

		fw.truthy(env.Addon.Display.DampeningBlock.Value:IsShown(), "dampening value still shown in Lights")
		fw.is_nil(env.Addon.Display.DampeningBlock.Pips, "dampening block has no pip widgets to show")
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

	fw.it("draws a cleared opponent as a dot, the same shape as hidden", function()
		env.Cleared("arena3")
		env.Tick(2)

		local pips = env.Addon.Display.CountsBlock.PipWidgets
		local clearedFill = pips[6].Fill

		fw.eq(clearedFill:GetWidth(), 4, "cleared fill width, a dot")
		fw.eq(clearedFill:GetHeight(), 4, "cleared fill height, a dot")
	end)
end)

local function StripColor(text)
	return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function ColorCode(color)
	return string.format("%02x%02x%02x", color[1] * 255, color[2] * 255, color[3] * 255)
end

fw.describe("MiniDampen - counts value text", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
		_G.MiniDampenDB.DisplayStyle = "Numbers"
	end)

	fw.it("renders the counts row as \"N vs N\"", function()
		env.Addon.Display:Refresh()

		local text = env.Addon.Display.CountsBlock.Value:GetText()

		fw.eq(StripColor(text), "3 vs 3", "full strength on both sides")
	end)

	fw.it("renders a single ? no matter how many opponents are hidden", function()
		env.Unseen("arena1")
		env.Unseen("arena2")
		env.Tick(2)
		env.Addon.Display:Refresh()

		local text = StripColor(env.Addon.Display.CountsBlock.Value:GetText())
		local _, markerCount = text:gsub("?", "")

		fw.eq(markerCount, 1, "one ? marker even with two opponents hidden")
	end)

	fw.it("does not count a cleared opponent among the living, and marks it with ?", function()
		env.Cleared("arena3")
		env.Addon.Display:Refresh()

		local text = StripColor(env.Addon.Display.CountsBlock.Value:GetText())

		fw.eq(text, "3 vs 2?", "cleared opponent excluded from the alive tally, marked ?")
	end)

	fw.it("does not count a departed ally among the living, and marks it with ?", function()
		env.Exists.party2 = false
		env.Context.Mock.FireEvent("GROUP_ROSTER_UPDATE")
		env.Addon.Display:Refresh()

		local text = StripColor(env.Addon.Display.CountsBlock.Value:GetText())

		fw.eq(text, "2? vs 3", "departed ally excluded from the alive tally, marked ?")
	end)

	fw.it("does not mark a dead-then-cleared opponent with ?, its fate is already known", function()
		env.Kill("arena3")
		env.Tick(0.5)
		env.Cleared("arena3")
		env.Addon.Display:Refresh()

		local text = StripColor(env.Addon.Display.CountsBlock.Value:GetText())

		fw.eq(text, "3 vs 2", "a latched death needs no ?, unlike clearing before ever dying")
	end)
end)

fw.describe("MiniDampen - round record value text", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.SoloShuffle = true
		env.Enter()
		_G.MiniDampenDB.DisplayStyle = "Numbers"
	end)

	local function round(winner)
		env.SetState(2) -- StartUp
		env.SetState(3) -- Engaged
		env.SetWinner(winner)
		env.SetState(4) -- PostRound
	end

	fw.it("renders \"(2)-4/6\" with the win count in the won colour", function()
		round(0) -- win
		round(0) -- win
		round(1) -- loss
		round(1) -- loss
		env.Addon.Display:Refresh()

		local text = env.Addon.Display.CountsBlock.Value:GetText()

		fw.eq(StripColor(text), "(2)-4/6", "two wins of four rounds played, six total")
		fw.truthy(text:find(ColorCode(env.Addon.Colors.LIGHT_WON), 1, true), "win count wrapped in the won colour")
	end)

	fw.it("shows ? for the win count when a round settled unknown", function()
		env.SetWinner(nil)
		env.SetState(2)
		env.SetState(3)
		env.Cleared("arena1") -- never latches dead, so the corpse latch can't decide either
		env.SetState(4)
		env.Addon.Display:Refresh()

		local text = StripColor(env.Addon.Display.CountsBlock.Value:GetText())

		fw.truthy(text:find("?", 1, true), "win count reads ? rather than a wrong number")
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

fw.describe("MiniDampen - counts row layout", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	fw.it("anchors the value off the legend's own right edge, not a fixed offset", function()
		local point, relativeTo, relativePoint = env.Addon.Display.CountsBlock.Value:GetPoint(1)

		fw.eq(point, "LEFT", "value's own anchor point")
		fw.eq(relativeTo, env.Addon.Display.CountsBlock.Legend, "anchored to the legend, not the frame, so no fixed offset can undershoot a wide label")
		fw.eq(relativePoint, "RIGHT", "off the legend's right edge")
	end)

	fw.it("anchors the pips row the same way as the value, off the legend's right edge", function()
		local _, relativeTo = env.Addon.Display.CountsBlock.Pips:GetPoint(1)

		fw.eq(relativeTo, env.Addon.Display.CountsBlock.Legend, "pips anchored to the legend too")
	end)

	fw.it("keeps a fixed gap regardless of font size, not a fixed label column", function()
		local leftover = {}

		for _, fontSize in ipairs({ 10, 24 }) do
			_G.MiniDampenDB.FontSize = fontSize
			env.Addon.Display:Refresh()

			local block = env.Addon.Display.CountsBlock
			leftover[fontSize] = block.Frame:GetWidth() - block.Legend:GetStringWidth() - block.Measure:GetStringWidth()
		end

		fw.eq(leftover[10], leftover[24], "the only non-text room in the block is a fixed gap that doesn't move with the font, at either slider extreme")
	end)

	fw.it("gives both blocks the same width, so their legends and values share one column", function()
		env.Addon.Display:Refresh()

		fw.eq(
			env.Addon.Display.CountsBlock.Frame:GetWidth(),
			env.Addon.Display.DampeningBlock.Frame:GetWidth(),
			"both blocks share one width, not each sized to its own content"
		)
	end)
end)

fw.describe("MiniDampen - preview affordance", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	fw.it("shows the preview backdrop and label only while unlocked", function()
		_G.MiniDampenDB.Locked = true
		env.Addon.Display:Refresh()

		fw.falsy(env.Addon.Display.CountsBlock.PreviewLabel:IsShown(), "hidden while locked")

		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		fw.truthy(env.Addon.Display.CountsBlock.PreviewLabel:IsShown(), "shown while unlocked")
	end)

	fw.it("stays draggable while unlocked with no arena entered", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		fw.truthy(env.Addon.Display.CountsBlock.Frame:IsShown(), "sample content visible outside an arena")
		fw.eq(env.Addon.Display.CountsBlock.Frame:IsMovable(), true, "still draggable with no match running")
	end)
end)

fw.describe("MiniDampen - dampening tier preview", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	fw.it("sweeps the sample dampening value while unlocked, without a real match", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		local first = StripColor(env.Addon.Display.DampeningBlock.Value:GetText())

		env.Tick(10)

		local second = StripColor(env.Addon.Display.DampeningBlock.Value:GetText())

		fw.neq(first, second, "the sweep moves the sample value on its own, no ticks from a match needed")
	end)

	fw.it("creates exactly one ticker for the sweep, not a fresh one on every Refresh", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()
		env.Addon.Display:Refresh()
		env.Addon.Display:Refresh()

		local live = 0

		for _, entry in ipairs(env.Tickers) do
			if not entry.Ticker:IsCancelled() then
				live = live + 1
			end
		end

		fw.eq(live, 1, "one live ticker driving the sweep")
	end)

	fw.it("cancels the sweep ticker on locking again", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		_G.MiniDampenDB.Locked = true
		env.Addon.Display:Refresh()

		fw.truthy(env.Tickers[1].Ticker:IsCancelled(), "ticker cancelled once locked")
	end)

	fw.it("forces a bracketed value that overrides the sample sweep", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		local unforced = StripColor(env.Addon.Display.DampeningBlock.Value:GetText())

		env.Addon.Display:SetForcedDampening(42)

		local forced = StripColor(env.Addon.Display.DampeningBlock.Value:GetText())

		fw.falsy(unforced:find("[", 1, true), "the sweep's own reading isn't bracketed")
		fw.eq(forced, "[42%]", "bracket-marked, replacing the sweep's own reading")

		env.Addon.Display:SetForcedDampening(nil)
	end)

	fw.it("shows the forced value even locked and outside an arena, and hides once cleared", function()
		-- Deliberately no env.Enter(): the whole point is inspecting a tier without a real match.
		env.Addon.Display:SetForcedDampening(75)

		fw.truthy(env.Addon.Display.DampeningBlock.Frame:IsShown(), "forced value shown with no match and Locked")

		env.Addon.Display:SetForcedDampening(nil)

		fw.falsy(env.Addon.Display.DampeningBlock.Frame:IsShown(), "clearing it leaves nothing real to show")
	end)
end)

fw.describe("MiniDampen - forced dampening safety", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	fw.it("yields to a real match once one is in scope, so a forgotten preview can't leak into it", function()
		env.Addon.Display:SetForcedDampening(90)

		fw.truthy(env.Addon.Display.DampeningBlock.Frame:IsShown(), "forced value shown before any match starts")

		env.Enter()
		env.SetDampening(10)
		env.Tick(0.5)

		local text = StripColor(env.Addon.Display.DampeningBlock.Value:GetText())

		fw.eq(text, "10%", "the real reading wins, the forced value never leaked into the match")

		env.Addon.Display:SetForcedDampening(nil)
	end)

	fw.it("never writes a forced value to saved variables", function()
		local before = {}

		for key in pairs(_G.MiniDampenDB) do
			before[key] = true
		end

		env.Addon.Display:SetForcedDampening(77)

		for key in pairs(_G.MiniDampenDB) do
			fw.truthy(before[key], "no new saved variable key from forcing a value: " .. tostring(key))
		end

		env.Addon.Display:SetForcedDampening(nil)
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

	fw.it("restores the alpha another addon had already set, not a hardcoded 1", function()
		_G.UIWidgetTopCenterContainerFrame:SetAlpha(0.4)

		env.Enter()
		env.Leave()

		fw.eq(_G.UIWidgetTopCenterContainerFrame:GetAlpha(), 0.4, "restored to what was found, not 1")
	end)

	fw.it("restores immediately when the setting is switched off mid-arena", function()
		env.Enter()

		fw.eq(_G.UIWidgetTopCenterContainerFrame:GetAlpha(), 0, "dimmed on entering")

		_G.MiniDampenDB.HideBlizzardWidgets = false
		env.Addon.Display:Refresh()

		fw.eq(_G.UIWidgetTopCenterContainerFrame:GetAlpha(), 1, "restored immediately, still in the arena")
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
