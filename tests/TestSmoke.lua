-- Loads the whole addon into a mocked client and drives it through login.
-- The shared body lives in build/Lua/SmokeTest.lua.

local fw = require("TestFramework")
local smoke = require("SmokeTest")

---A plain open-world login never opens the arena scope, so no frame should carry any of
---MatchState.lua's gated events. Mirrors the gatedFrame helper in TestMatchState.lua.
---@param context table
local function CheckNoArenaEventsAfterLogin(context)
	for _, frame in ipairs(context.Mock.Frames) do
		fw.falsy(frame.__events["ARENA_OPPONENT_UPDATE"], "no frame left ARENA_OPPONENT_UPDATE registered")
	end
end

smoke.Run("MiniDampen", { extra = CheckNoArenaEventsAfterLogin })
