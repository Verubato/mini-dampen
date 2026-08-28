local addonName, _ = ...
local frame
local db
local dbDefaults = {
	Enabled = true,
	DisplayStyle = "Numbers",
	CountsAnchor = { point = "CENTER", x = 0, y = 200 },
	DampeningAnchor = { point = "CENTER", x = 0, y = 180 },
}

local function CopyTable(src, dst)
	if type(dst) ~= "table" then
		dst = {}
	end

	for k, v in pairs(src) do
		if type(v) == "table" then
			dst[k] = CopyTable(v, dst[k])
		elseif dst[k] == nil then
			dst[k] = v
		end
	end

	return dst
end

local function OnEnteringWorld()
	if not db.Enabled then
		return
	end

	-- Real display lives in a module this scaffold does not implement yet.
end

local function OnEvent(_, event)
	if event == "PLAYER_ENTERING_WORLD" then
		OnEnteringWorld()
	end
end

local function Init()
	MiniDampenDB = MiniDampenDB or {}
	db = CopyTable(dbDefaults, MiniDampenDB)
end

frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")

frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == addonName then
		Init()

		frame:UnregisterEvent("ADDON_LOADED")
		frame:RegisterEvent("PLAYER_ENTERING_WORLD")
		frame:SetScript("OnEvent", OnEvent)
	end
end)
