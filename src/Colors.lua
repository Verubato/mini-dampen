local _, addon = ...
local COUNT_FULL = { 0.20, 0.90, 0.30 }
local COUNT_HURT = { 1.00, 0.82, 0.20 }
local COUNT_CRITICAL = { 1.00, 0.30, 0.25 }
local COUNT_WIPED = { 0.45, 0.45, 0.45 }
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
---@class Colors
local M = {}
addon.Colors = M

M.COUNT_FULL = COUNT_FULL
M.COUNT_HURT = COUNT_HURT
M.COUNT_CRITICAL = COUNT_CRITICAL
M.COUNT_WIPED = COUNT_WIPED
M.COUNT_HIDDEN = COUNT_HIDDEN
M.ROUND_WON = ROUND_WON
M.ROUND_LOST = ROUND_LOST

local function Lerp(a, b, t)
	return a + (b - a) * t
end

---Picks a colour from the alive fraction, so 2v2 and 3v3 both land on the same four states.
---@return number r, number g, number b
function M:ForCount(alive, total)
	if not total or total <= 0 then
		return unpack(COUNT_WIPED)
	end

	local fraction = alive / total

	if fraction <= 0 then
		return unpack(COUNT_WIPED)
	elseif fraction < 0.5 then
		return unpack(COUNT_CRITICAL)
	elseif fraction < 1 then
		return unpack(COUNT_HURT)
	end

	return unpack(COUNT_FULL)
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
