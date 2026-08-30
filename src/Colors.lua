local _, addon = ...
local COUNT_FULL = { 0.20, 0.90, 0.30 }
local COUNT_HURT = { 1.00, 0.82, 0.20 }
-- The "?" marker drawn when an opponent is behind cover.
local COUNT_HIDDEN = { 0.65, 0.65, 0.72 }
-- { percent, r, g, b }, ascending by percent. ForDampening interpolates between neighbours.
local DAMPENING_STOPS = {
	{ 0, 1.00, 1.00, 1.00 },
	{ 30, 1.00, 0.85, 0.20 },
	{ 50, 1.00, 0.30, 0.25 },
	{ 70, 0.78, 0.40, 0.95 },
	{ 100, 0.55, 0.15, 0.85 },
}
local ROUND_WON = COUNT_FULL
local ROUND_LOST = { 0.85, 0.20, 0.20 }
-- Set apart from the "Round" label beside it, so the number is what the eye lands on.
local ROUND_NUMBER = COUNT_HURT
-- A team down a member should not read as if it were in trouble.
local COUNT_ALLY = COUNT_FULL
local COUNT_ENEMY = ROUND_LOST
---@class Colors
local M = {}
addon.Colors = M

M.COUNT_HIDDEN = COUNT_HIDDEN
M.ROUND_WON = ROUND_WON
M.ROUND_LOST = ROUND_LOST
M.ROUND_NUMBER = ROUND_NUMBER
M.COUNT_ALLY = COUNT_ALLY
M.COUNT_ENEMY = COUNT_ENEMY

local function Lerp(a, b, t)
	return a + (b - a) * t
end

---Interpolates a colour across DAMPENING_STOPS, clamping outside the first and last stop.
---@return number r, number g, number b
function M:ForDampening(percent)
	percent = percent or 0

	local first = DAMPENING_STOPS[1]
	local last = DAMPENING_STOPS[#DAMPENING_STOPS]

	if percent <= first[1] then
		return first[2], first[3], first[4]
	end

	if percent >= last[1] then
		return last[2], last[3], last[4]
	end

	for i = 1, #DAMPENING_STOPS - 1 do
		local from = DAMPENING_STOPS[i]
		local to = DAMPENING_STOPS[i + 1]

		if percent >= from[1] and percent < to[1] then
			local t = (percent - from[1]) / (to[1] - from[1])
			return Lerp(from[2], to[2], t), Lerp(from[3], to[3], t), Lerp(from[4], to[4], t)
		end
	end
end
