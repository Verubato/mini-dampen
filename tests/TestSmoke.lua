-- Loads the whole addon into a mocked client and drives it through login.
-- The shared body lives in build/Lua/SmokeTest.lua.

local smoke = require("SmokeTest")

smoke.Run("MiniDampen")
