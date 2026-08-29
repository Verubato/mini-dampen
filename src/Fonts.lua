local addonName, addon = ...

-- Client faces offered even where nothing has registered a font with LibSharedMedia-3.0.
-- FRIZQT__.TTF is also what an existing user's display already draws, so it doubles as the
-- game's own default face.
local BUILTIN_FACES = {
	{ Name = "Friz Quadrata", File = "Fonts\\FRIZQT__.TTF" },
	{ Name = "Arial Narrow", File = "Fonts\\ARIALN.TTF" },
	{ Name = "Skurri", File = "Fonts\\SKURRI.TTF" },
	{ Name = "Morpheus", File = "Fonts\\MORPHEUS.TTF" },
}
local DEFAULT_FACE_FILE = "Fonts\\FRIZQT__.TTF"
local VALID_OUTLINES = { NONE = true, OUTLINE = true, THICKOUTLINE = true }
local DEFAULT_OUTLINE = "OUTLINE"
-- Dropdown rows are menu rows, so their preview text matches the menu's own size.
local PREVIEW_FONT_SIZE = 13
-- A FontFamilyMember is keyed by alphabet, one per alphabet the client distinguishes.
local FAMILY_ALPHABETS = { "roman", "korean", "simplifiedchinese", "traditionalchinese", "russian" }
local LOCALE_ALPHABETS = {
	koKR = "korean",
	zhCN = "simplifiedchinese",
	zhTW = "traditionalchinese",
	ruRU = "russian",
}
local builtinFiles = {}

for _, entry in ipairs(BUILTIN_FACES) do
	builtinFiles[entry.Name] = entry.File
end

-- One table, refilled in place on every call. Consumers hold onto the returned table and
-- re-ask for its contents rather than the table itself, since a media addon can register a
-- font any time after this list was last built.
local nameScratch = {}
-- SetFont on a font object hits the same lazy file loading a fontstring does, answering false
-- for a file the client is still loading, so objects are built once through CreateFontFamily
-- and never edited after.
local fontObjects = {}
local fontObjectCount = 0
-- Fired when the media list changes, so anything showing or drawing it can catch up.
---@type fun()[]
local changeCallbacks = {}
local subscribedToMedia = false
local queued = false

---@class Fonts
local M = {}
addon.Fonts = M

---Looked up fresh on every call rather than cached at load time, so it does not matter
---whether the addon supplying it loads before or after MiniDampen.
---@return table? library
local function SharedMedia()
	return LibStub and LibStub("LibSharedMedia-3.0", true)
end

local function NotifyChanged()
	for _, fn in ipairs(changeCallbacks) do
		fn()
	end
end

---Runs the change fan-out once at the end of the frame however many times it is asked for in
---one, since LibSharedMedia fires once per registered entry and a media pack registers its
---whole set inside a single frame.
local function QueueChanged()
	if queued then
		return
	end

	queued = true

	C_Timer.After(0, function()
		queued = false
		NotifyChanged()
	end)
end

---Only sets the flag on success, so a call before the library has loaded retries the next time
---anything asks rather than giving up for the session.
local function EnsureMediaSubscription()
	if subscribedToMedia then
		return
	end

	local media = SharedMedia()

	if not media or not media.RegisterCallback then
		return
	end

	subscribedToMedia = true

	media.RegisterCallback(M, "LibSharedMedia_Registered", QueueChanged)
	media.RegisterCallback(M, "LibSharedMedia_SetGlobal", QueueChanged)
end

---@param name string?
---@return string? file nil when the name is unset or nothing this session has registered it
local function ResolveFile(name)
	if not name then
		return nil
	end

	local builtin = builtinFiles[name]

	if builtin then
		return builtin
	end

	local media = SharedMedia()

	if media and media:IsValid("font", name) then
		return media:Fetch("font", name)
	end

	return nil
end

---One member per alphabet the client distinguishes, so a family registers against every one
---of them rather than leaving every alphabet but a single one undeclared.
---@param file string
---@param size number
---@param flags string
---@return table[] members
local function FamilyMembers(file, size, flags)
	local override = LOCALE_ALPHABETS[GetLocale()] or "roman"
	local members = {}

	for _, alphabet in ipairs(FAMILY_ALPHABETS) do
		local memberFile = file

		-- A non-local alphabet borrows the client's own file for it, where the client has one,
		-- rather than drawing the picked face's glyphs for a script it was never built for.
		if alphabet ~= override and GameFontNormal and GameFontNormal.GetFontObjectForAlphabet then
			local gameObject = GameFontNormal:GetFontObjectForAlphabet(alphabet)

			memberFile = (gameObject and gameObject:GetFont()) or file
		end

		members[#members + 1] = {
			alphabet = alphabet,
			file = memberFile,
			height = size,
			flags = flags,
		}
	end

	return members
end

---@param file string
---@param size number
---@param flags string
---@return table object
local function FileFontObject(file, size, flags)
	local bySize = fontObjects[file]

	if not bySize then
		bySize = {}
		fontObjects[file] = bySize
	end

	local byFlags = bySize[size]

	if not byFlags then
		byFlags = {}
		bySize[size] = byFlags
	end

	local object = byFlags[flags]

	if not object then
		fontObjectCount = fontObjectCount + 1

		local name = addonName .. "Font" .. fontObjectCount

		if CreateFontFamily then
			object = CreateFontFamily(name, FamilyMembers(file, size, flags))
		else
			-- Only an old client gets here, where the two-step is all there is.
			object = CreateFont(name)
			object:SetFont(file, size, flags)
		end

		byFlags[flags] = object
	end

	return object
end

---A stored value a hand-edited SavedVariables file could hold anything in, corrected back to
---the look an existing user already has rather than passed on to SetFont.
---@param outline string?
---@return string outline
function M:SanitizeOutline(outline)
	if VALID_OUTLINES[outline] then
		return outline
	end

	return DEFAULT_OUTLINE
end

---The face names to offer in the dropdown: the client's own faces plus whatever LibSharedMedia
---has registered this session, sorted together. Deduplicated by file rather than by name, since
---a media pack can register its own name for a file a built-in already offers.
---@return string[]
function M:Names()
	EnsureMediaSubscription()
	wipe(nameScratch)

	local seenFiles = {}

	for _, entry in ipairs(BUILTIN_FACES) do
		nameScratch[#nameScratch + 1] = entry.Name
		seenFiles[entry.File] = true
	end

	local media = SharedMedia()

	if media then
		for _, name in ipairs(media:List("font") or {}) do
			local file = media:Fetch("font", name)

			if file and not seenFiles[file] then
				nameScratch[#nameScratch + 1] = name
				seenFiles[file] = true
			end
		end
	end

	table.sort(nameScratch)

	return nameScratch
end

---The shared font object for a face at a size and outline. A name this session cannot
---resolve, including false or nil for the game's own default, draws the client's default face
---rather than erroring, which is the normal case for a face whose media addon is disabled.
---@param name string|false|nil
---@param size number
---@param outline string?
---@return table object
function M:Object(name, size, outline)
	local file = ResolveFile(name) or DEFAULT_FACE_FILE
	local flags = self:SanitizeOutline(outline)

	if flags == "NONE" then
		flags = ""
	end

	return FileFontObject(file, size, flags)
end

---A font object wearing this name's own face, for a dropdown row that previews the font it
---names. Nil when the name resolves to nothing, which leaves that row in the menu's own face.
---@param name string?
---@return table? object
function M:PreviewObject(name)
	local file = ResolveFile(name)

	if not file then
		return nil
	end

	return FileFontObject(file, PREVIEW_FONT_SIZE, "")
end

---Registers a function to call when the media list changes, i.e. when Names would now return
---something different, or a name that resolved to nothing now resolves.
---@param fn fun()
function M:OnChanged(fn)
	changeCallbacks[#changeCallbacks + 1] = fn
	EnsureMediaSubscription()
end
