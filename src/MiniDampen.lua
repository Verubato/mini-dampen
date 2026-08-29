local _, addon = ...
---@type MiniFramework
local mini = addon.Framework

-- Config seeds the saved-variable defaults the other two modules read from, so it has to run
-- first.
-- True only once every Init has returned, so a callback arriving part way through the sequence
-- never reads a module that is still half built.
local initialised = false

local function OnAddonLoad()
	addon.Config:Init()
	addon.MatchState:Init()
	addon.Display:Init()

	addon.MatchState.OnChanged = function()
		addon.Display:Refresh()
	end

	initialised = true
end

function addon:Refresh()
	if not initialised then
		return
	end

	addon.MatchState:Evaluate()
	addon.Display:Refresh()
end

mini:WaitForAddonLoad(OnAddonLoad)
