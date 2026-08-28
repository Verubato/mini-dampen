local _, addon = ...
---@type MiniFramework
local mini = addon.Framework

-- Config seeds the saved-variable defaults the other two modules read from, so it has to run
-- first.
local function OnAddonLoad()
	addon.Config:Init()
	addon.MatchState:Init()
	addon.Display:Init()

	addon.MatchState.OnChanged = function()
		addon.Display:Refresh()
	end
end

function addon:Refresh()
	addon.Display:Refresh()
end

mini:WaitForAddonLoad(OnAddonLoad)
