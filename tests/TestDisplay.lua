-- Display.lua never reads WoW APIs directly, so these drive it through tests/Helpers/Arena.lua
-- the same way TestMatchState.lua does, and read back the container and the rows it built in
-- Init.

local fw = require("TestFramework")
local Arena = require("Arena")

local function StripColor(text)
	return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function ColorCode(color)
	return string.format("%02x%02x%02x", color[1] * 255, color[2] * 255, color[3] * 255)
end

-- Display.lua's own VALUE_GAP, which it does not export.
local VALUE_GAP = 8

---Where a row's content centre must land, given LayoutRow reserves legend + gap + content and
---centres the content in the last of those.
local function ExpectedContentCentre(block)
	local legendWidth = block.Legend:GetStringWidth()
	local gap = legendWidth > 0 and VALUE_GAP or 0

	return (block.Frame:GetWidth() + legendWidth + gap) / 2
end

fw.describe("MiniDampen - counts value text", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
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

	fw.it("marks an ally with ? on a secret death read, without undercounting the alive tally", function()
		env.MarkDeathSecret("player")
		env.Tick(0.5)
		env.Addon.Display:Refresh()

		local text = StripColor(env.Addon.Display.CountsBlock.Value:GetText())

		fw.eq(text, "3? vs 3", "all three allies still counted alive, marked uncertain rather than assumed dead or dropped")
	end)

	fw.it("marks an opponent with ? on a secret death read too, not just an ally", function()
		env.MarkDeathSecret("arena1")
		env.Tick(0.5)
		env.Addon.Display:Refresh()

		local text = StripColor(env.Addon.Display.CountsBlock.Value:GetText())

		fw.eq(text, "3 vs 3?", "all three opponents still counted alive, marked uncertain rather than assumed dead or cleared")
	end)

	fw.it("clears the ? once a later death read for that ally comes back readable", function()
		env.MarkDeathSecret("player")
		env.Tick(0.5)
		env.Addon.Display:Refresh()

		fw.truthy(StripColor(env.Addon.Display.CountsBlock.Value:GetText()):find("?", 1, true) ~= nil, "starts marked uncertain")

		env.SecretDeaths.player = false
		env.Tick(0.5)
		env.Addon.Display:Refresh()

		local text = StripColor(env.Addon.Display.CountsBlock.Value:GetText())

		fw.eq(text, "3 vs 3", "the ? clears once the read is readable again, not left latched")
	end)
end)

fw.describe("MiniDampen - round record value text", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.SoloShuffle = true
		env.Enter()
	end)

	local function round(winner)
		env.SetState(2) -- StartUp
		env.SetState(3) -- Engaged
		env.SetWinner(winner)
		env.SetState(4) -- PostRound
	end

	fw.it("renders wins against losses, the wins in the won colour and the losses in the lost one", function()
		round(0) -- win
		round(0) -- win
		round(1) -- loss
		round(1) -- loss
		env.Addon.Display:Refresh()

		local text = env.Addon.Display.CountsBlock.Value:GetText()

		fw.eq(StripColor(text), "2W - 2L", "two won and two lost, with no round fraction")
		fw.truthy(text:find(ColorCode(env.Addon.Colors.ROUND_WON) .. "2W", 1, true), "the wins wrapped in the won colour")
		fw.truthy(text:find(ColorCode(env.Addon.Colors.ROUND_LOST) .. "2L", 1, true), "the losses wrapped in the lost colour")
	end)

	fw.it("puts the current round on its own row below the record", function()
		round(0)
		env.SetState(2) -- StartUp, round two
		env.SetState(3) -- Engaged
		env.Addon.Display:Refresh()

		fw.truthy(env.Addon.Display.RoundBlock.Frame:IsShown(), "the round row is drawn alongside the record")
		fw.eq(StripColor(env.Addon.Display.RoundBlock.Value:GetText()), "Round 2/6", "reads the current round out of the six a shuffle always runs")
		fw.truthy(env.Addon.Display.RoundBlock.Value:GetText():find(ColorCode(env.Addon.Colors.ROUND_NUMBER) .. "2/6", 1, true), "with the fraction coloured apart from its label")

		local _, _, _, _, recordY = env.Addon.Display.CountsBlock.Frame:GetPoint(1)
		local _, _, _, _, roundY = env.Addon.Display.RoundBlock.Frame:GetPoint(1)

		fw.truthy(roundY < recordY, "the round row sits below the record, not above it")
	end)

	fw.it("shows ? for the win count when a round settled unknown", function()
		env.SetWinner(nil)
		env.SetState(2)
		env.SetState(3)
		env.Cleared("arena1") -- never latches dead, so the corpse latch can't decide either
		env.SetState(4)
		env.Addon.Display:Refresh()

		local text = StripColor(env.Addon.Display.CountsBlock.Value:GetText())

		fw.eq(text, "0W - 0L?", "the tally reads ? rather than a wrong number")
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

	fw.it("dragging the container writes CountsAnchor", function()
		local frame = env.Addon.Display.Container.Frame

		frame:ClearAllPoints()
		frame:SetPoint("TOP", UIParent, "TOP", 42, -99)
		frame:GetScript("OnDragStop")(frame)

		fw.eq(_G.MiniDampenDB.CountsAnchor.X, 42, "counts anchor x written")
		fw.eq(_G.MiniDampenDB.CountsAnchor.Y, -99, "counts anchor y written")
	end)

	fw.it("a reload restores the container's saved position", function()
		local frame = env.Addon.Display.Container.Frame

		frame:ClearAllPoints()
		frame:SetPoint("TOP", UIParent, "TOP", 10, -20)
		frame:GetScript("OnDragStop")(frame)

		env.Reload()
		env.Enter()

		local _, _, _, x, y = env.Addon.Display.Container.Frame:GetPoint(1)

		fw.eq(x, 10, "container anchor x survived the reload")
		fw.eq(y, -20, "container anchor y survived the reload")
	end)

	fw.it("carries an existing saved CountsAnchor across to the container, so a user who already placed their display keeps its position", function()
		_G.MiniDampenDB.CountsAnchor.X = 7
		_G.MiniDampenDB.CountsAnchor.Y = -55

		env.Reload()
		env.Enter()

		local _, _, _, x, y = env.Addon.Display.Container.Frame:GetPoint(1)

		fw.eq(x, 7, "existing counts anchor x reused for the container")
		fw.eq(y, -55, "existing counts anchor y reused for the container")
	end)

	fw.it("declares no second anchor, so neither row can be positioned on its own", function()
		env.Reload()
		env.Enter()

		fw.is_nil(_G.MiniDampenDB.DampeningAnchor, "the dampening row's own saved anchor is gone from the defaults")
	end)
end)

fw.describe("MiniDampen - counts row layout", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	fw.it("centres the value within the whole frame when the counts row draws no legend", function()
		local point, relativeTo, relativePoint, x = env.Addon.Display.CountsBlock.Value:GetPoint(1)

		fw.eq(point, "CENTER", "value's own anchor point")
		fw.eq(relativeTo, env.Addon.Display.CountsBlock.Frame, "measured from the row itself, so a blank legend is never an anchor target")
		fw.eq(relativePoint, "LEFT", "off the row's own left edge")
		fw.eq(x, env.Addon.Display.CountsBlock.Frame:GetWidth() / 2, "a blank legend leaves no gap, so the value's centre lands on the frame's own midpoint")
	end)

	fw.it("centres the value within its own reserved slot in rounds mode", function()
		local roundsEnv = Arena.Build()
		roundsEnv.SoloShuffle = true
		roundsEnv.Enter()
		roundsEnv.SetState(2) -- StartUp
		roundsEnv.SetState(3) -- Engaged, so roundIndex is no longer nil
		roundsEnv.Addon.Display:Refresh()

		local point, relativeTo, relativePoint, x = roundsEnv.Addon.Display.CountsBlock.Value:GetPoint(1)

		fw.eq(point, "CENTER", "value's own anchor point")
		fw.eq(relativeTo, roundsEnv.Addon.Display.CountsBlock.Frame, "measured from the row itself")
		fw.eq(relativePoint, "LEFT", "off the row's own left edge")
		fw.eq(x, ExpectedContentCentre(roundsEnv.Addon.Display.CountsBlock), "centred in the slot reserved for the widest record, not flush left")
	end)

	fw.it("does not move the block's edge as the counts value's own width changes", function()
		env.Addon.Display:Refresh()

		local textBefore = StripColor(env.Addon.Display.CountsBlock.Value:GetText())
		local widthBefore = env.Addon.Display.CountsBlock.Frame:GetWidth()

		-- Marks both sides ?, "3? vs 3?", the widest reading this row ever draws, versus the
		-- plain "3 vs 3" above: a real length change, not just a different digit.
		env.MarkDeathSecret("player")
		env.MarkDeathSecret("arena1")
		env.Tick(0.5)
		env.Addon.Display:Refresh()

		local textAfter = StripColor(env.Addon.Display.CountsBlock.Value:GetText())
		local widthAfter = env.Addon.Display.CountsBlock.Frame:GetWidth()

		fw.eq(textBefore, "3 vs 3", "starting value has no ? markers")
		fw.eq(textAfter, "3? vs 3?", "widest value has a ? marker on each side")
		fw.eq(widthAfter, widthBefore, "block width reserved for the widest value, not the live one")
	end)

	fw.it("draws no legend on the counts row", function()
		env.Addon.Display:Refresh()

		fw.eq(env.Addon.Display.CountsBlock.Legend:GetText(), "", "the \"Us vs Opponent\" label is gone")
	end)
end)

fw.describe("MiniDampen - container layout", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
		env.Enter()
	end)

	fw.it("the container is movable and neither row is draggable on its own", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		fw.eq(env.Addon.Display.Container.Frame:IsMovable(), true, "the container can be dragged")
		fw.eq(env.Addon.Display.CountsBlock.Frame:IsMovable(), false, "the counts row cannot be dragged on its own")
		fw.eq(env.Addon.Display.DampeningBlock.Frame:IsMovable(), false, "the dampening row cannot be dragged on its own")
		fw.is_nil(env.Addon.Display.CountsBlock.Frame:GetScript("OnDragStart"), "the counts row has no drag script of its own")
		fw.is_nil(env.Addon.Display.DampeningBlock.Frame:GetScript("OnDragStart"), "the dampening row has no drag script of its own")
	end)

	fw.it("anchors both rows top-centre on the container", function()
		env.SetDampening(10)
		env.Tick(0.5)

		local cPoint, cRelativeTo, cRelativePoint, cx = env.Addon.Display.CountsBlock.Frame:GetPoint(1)

		fw.eq(cPoint, "TOP", "counts row anchor point")
		fw.eq(cRelativeTo, env.Addon.Display.Container.Frame, "counts row anchored to the container")
		fw.eq(cRelativePoint, "TOP", "off the container's own top-centre")
		fw.eq(cx, 0, "no horizontal offset, so the row's own centre matches the container's")

		local dPoint, dRelativeTo, dRelativePoint, dx = env.Addon.Display.DampeningBlock.Frame:GetPoint(1)

		fw.eq(dPoint, "TOP", "dampening row anchor point")
		fw.eq(dRelativeTo, env.Addon.Display.Container.Frame, "dampening row anchored to the container")
		fw.eq(dRelativePoint, "TOP", "off the container's own top-centre")
		fw.eq(dx, 0, "no horizontal offset, so the row's own centre matches the container's")
	end)

	fw.it("centres the dampening value in its own slot, past its legend", function()
		env.SetDampening(10)
		env.Tick(0.5)

		local point, relativeTo, relativePoint, x = env.Addon.Display.DampeningBlock.Value:GetPoint(1)

		fw.eq(point, "CENTER", "value's own anchor point")
		fw.eq(relativeTo, env.Addon.Display.DampeningBlock.Frame, "measured from the row itself")
		fw.eq(relativePoint, "LEFT", "off the row's own left edge")
		fw.eq(x, ExpectedContentCentre(env.Addon.Display.DampeningBlock), "centred in the slot past the legend, not flush against it")
	end)

	fw.it("sizes the container to the wider of the two rows", function()
		env.SetDampening(10)
		env.Tick(0.5)

		local widest = math.max(env.Addon.Display.CountsBlock.Frame:GetWidth(), env.Addon.Display.DampeningBlock.Frame:GetWidth())

		fw.eq(env.Addon.Display.Container.Frame:GetWidth(), widest, "no padding while locked, so the container is exactly the wider row")
		fw.eq(env.Addon.Display.Container.Frame:GetHeight(), 44, "two stacked rows, a 24 gap plus the second row's own 20")
	end)

	fw.it("hiding the counts row leaves the dampening row at the top with no gap", function()
		-- Out of scope is the only way left to hide the counts row.
		env.Leave()
		env.Addon.Display:SetForcedDampening(10)

		local point, relativeTo, relativePoint, x, y = env.Addon.Display.DampeningBlock.Frame:GetPoint(1)

		fw.eq(point, "TOP", "dampening row anchor point")
		fw.eq(relativeTo, env.Addon.Display.Container.Frame, "dampening row anchored straight to the container")
		fw.eq(relativePoint, "TOP", "off the container's own top")
		fw.eq(x, 0, "no horizontal offset")
		fw.eq(y, 0, "no gap left behind by the hidden counts row")
		fw.eq(env.Addon.Display.Container.Frame:GetHeight(), 20, "container shrinks to the one visible row's height")

		env.Addon.Display:SetForcedDampening(nil)
	end)

	fw.it("stacks the record, the round line, and dampening as three rows in solo shuffle", function()
		local shuffle = Arena.Build()
		shuffle.SoloShuffle = true
		shuffle.Enter()
		shuffle.SetState(2) -- StartUp
		shuffle.SetState(3) -- Engaged, so the round line has a number to draw
		shuffle.SetDampening(10)
		shuffle.Tick(0.5)

		local _, _, _, _, recordY = shuffle.Addon.Display.CountsBlock.Frame:GetPoint(1)
		local _, _, _, _, roundY = shuffle.Addon.Display.RoundBlock.Frame:GetPoint(1)
		local _, _, _, _, dampeningY = shuffle.Addon.Display.DampeningBlock.Frame:GetPoint(1)

		fw.eq(recordY, 0, "the record sits at the container's top")
		fw.eq(roundY, -24, "the round line one row down")
		fw.eq(dampeningY, -48, "dampening below both")
		fw.eq(shuffle.Addon.Display.Container.Frame:GetHeight(), 68, "three rows, two 24 gaps plus the last row's own 20")
	end)

	fw.it("leaves the round row out entirely outside solo shuffle", function()
		env.SetDampening(10)
		env.Tick(0.5)

		fw.falsy(env.Addon.Display.RoundBlock.Frame:IsShown(), "no round line where there are no rounds")
		fw.eq(env.Addon.Display.Container.Frame:GetHeight(), 44, "the container holds two rows, not three")
	end)

	fw.it("keeps the container at the height its one backdrop was built for", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		fw.truthy(env.Addon.Display.Container.PreviewBackdrop:IsVisible(), "the backdrop is up while unlocked")
		fw.eq(env.Addon.Display.Container.Frame:GetHeight(), 68, "three rows drawn while unlocked")

		_G.MiniDampenDB.Locked = true
		env.Addon.Display:Refresh()

		fw.falsy(env.Addon.Display.Container.PreviewBackdrop:IsVisible(), "and gone once locked, so it never frames a live reading")
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

		fw.falsy(env.Addon.Display.Container.PreviewLabel:IsShown(), "hidden while locked")

		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		fw.truthy(env.Addon.Display.Container.PreviewLabel:IsShown(), "shown while unlocked")
	end)

	fw.it("stays draggable while unlocked with no arena entered", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		fw.truthy(env.Addon.Display.CountsBlock.Frame:IsShown(), "sample content visible outside an arena")
		fw.eq(env.Addon.Display.Container.Frame:IsMovable(), true, "still draggable with no match running")
	end)

	fw.it("previews both teams at full strength, with no ? and nobody dead", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		fw.eq(StripColor(env.Addon.Display.CountsBlock.Value:GetText()), "3 vs 3", "sample counts read full strength on both sides")
	end)

	fw.it("alternates the preview between the alive counts and the solo shuffle round record", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		local seen = {}
		local roundLines = {}

		-- A full sample period, so both halves of the alternation are sampled.
		for _ = 1, 20 do
			env.Tick(1)
			seen[StripColor(env.Addon.Display.CountsBlock.Value:GetText())] = true
			roundLines[StripColor(env.Addon.Display.RoundBlock.Value:GetText())] = true
		end

		fw.truthy(seen["3 vs 3"], "the alive counts appear in the preview")
		fw.truthy(seen["2W - 1L"], "the solo shuffle round record appears in the preview, without needing a shuffle")
		fw.truthy(roundLines["Round 4/6"], "the round line reads a real round in both halves")
		fw.falsy(roundLines["Round 0/6"], "and never the empty fallback")
	end)
end)

fw.describe("MiniDampen - preview rows", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	fw.it("draws every row for the whole alternation", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		local hiddenRows = {}

		for _ = 1, 20 do
			env.Tick(1)

			for _, name in ipairs({ "CountsBlock", "RoundBlock", "DampeningBlock" }) do
				if not env.Addon.Display[name].Frame:IsShown() then
					hiddenRows[name] = true
				end
			end
		end

		fw.is_nil(next(hiddenRows), "no row drops out of the preview at any point")
	end)
end)

fw.describe("MiniDampen - preview dampening", function()
	local env

	fw.before_each(function()
		env = Arena.Build()
	end)

	fw.it("holds the sample dampening at one fixed reading, with nothing animating", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		local first = StripColor(env.Addon.Display.DampeningBlock.Value:GetText())

		env.Tick(10)

		local second = StripColor(env.Addon.Display.DampeningBlock.Value:GetText())

		fw.eq(first, "50%", "the sample reads a plain mid-range percent")
		fw.eq(second, first, "and never moves on its own")
	end)

	fw.it("creates exactly one preview ticker, not a fresh one on every Refresh", function()
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

		fw.eq(live, 1, "one live ticker driving the preview")
	end)

	fw.it("cancels the preview ticker on locking again", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		_G.MiniDampenDB.Locked = true
		env.Addon.Display:Refresh()

		fw.truthy(env.Tickers[1].Ticker:IsCancelled(), "ticker cancelled once locked")
	end)

	fw.it("forces a bracketed value that overrides the sample reading", function()
		_G.MiniDampenDB.Locked = false
		env.Addon.Display:Refresh()

		local unforced = StripColor(env.Addon.Display.DampeningBlock.Value:GetText())

		env.Addon.Display:SetForcedDampening(42)

		local forced = StripColor(env.Addon.Display.DampeningBlock.Value:GetText())

		fw.falsy(unforced:find("[", 1, true), "the sample's own reading isn't bracketed")
		fw.eq(forced, "[42%]", "bracket-marked, replacing the sample's own reading")

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
		env.Addon.Display:Refresh()

		fw.is_nil(env.Addon.MatchState.State.roundIndex, "no StartUp observed yet")
		fw.eq(StripColor(env.Addon.Display.CountsBlock.Value:GetText()), "3 vs 3", "falls back to the alive counts, not an empty record")
		fw.falsy(env.Addon.Display.RoundBlock.Frame:IsShown(), "and no round line, since there is no round yet")
	end)
end)

fw.describe("MiniDampen - refresh before init", function()
	fw.it("builds nothing rather than erroring when a refresh arrives before Init ran", function()
		local env = Arena.Build({ SkipLogin = true })

		-- The config panel's own setters and the media callback both refresh through here, and
		-- Config initialises before the other two modules.
		local ok, err = pcall(function()
			env.Addon:Refresh()
		end)

		fw.truthy(ok, "a refresh before Init is a no-op, not an error: " .. tostring(err))
		fw.truthy(env.Addon.Display.Container == nil, "and it built nothing on the way through")
	end)

	fw.it("gives the preview label a font at build time, since it draws text there", function()
		local env = Arena.Build()

		fw.truthy(env.Addon.Display.Container.PreviewLabel.__template ~= nil,
			"SetText refuses a string with no font, and this one is written before any font pass")
	end)
end)
