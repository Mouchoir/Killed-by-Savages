local ADDON_NAME, ns = ...

--------------------------------------------------------------------------------
-- Start-up, events, slash command
--
-- Modules register event handlers with ns.On and internal hooks with
-- ns.Hook; everything runs guarded, so one failing module never takes the
-- others down.
--------------------------------------------------------------------------------

local Util = ns.Util
local L = ns.L

ns.VERSION = (C_AddOns and Util.Fn(C_AddOns.GetAddOnMetadata) and Util.Get(C_AddOns.GetAddOnMetadata, ADDON_NAME, "Version"))
	or (Util.Fn(GetAddOnMetadata) and Util.Get(GetAddOnMetadata, ADDON_NAME, "Version"))
	or "0.0.0"

function ns.Print(text)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(L.CHAT_PREFIX .. tostring(text))
	end
end

--------------------------------------------------------------------------------
-- Event and hook buses
--------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local handlers = {}
local hooks = {}
local registration = {}

function ns.On(event, fn)
	local list = handlers[event]
	if not list then
		list = {}
		handlers[event] = list
		-- An event this client does not know is recorded, not a load error.
		registration[event] = (pcall(frame.RegisterEvent, frame, event))
	end
	list[#list + 1] = fn
end

frame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for index = 1, #list do
		Util.Guard(event, list[index], ...)
	end
end)

function ns.Hook(name, fn)
	local list = hooks[name]
	if not list then
		list = {}
		hooks[name] = list
	end
	list[#list + 1] = fn
end

function ns.Fire(name, ...)
	local list = hooks[name]
	if not list then return end
	for index = 1, #list do
		Util.Guard("hook:" .. name, list[index], ...)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local loaded = false

ns.On("ADDON_LOADED", function(name)
	if name ~= ADDON_NAME or loaded then return end
	loaded = true
	ns.Db.Init()
	ns.db.debug.events = registration
	ns.Fire("Init")
end)

ns.On("PLAYER_LOGIN", function()
	ns.Identity.Refresh()
	ns.Identity.RequestRoster()
	ns.Fire("Login")
	Util.After(5, "officer-check", ns.Identity.CheckOfficerFlag)
end)

ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
	ns.Identity.Refresh()
	ns.Fire("EnteringWorld", isLogin, isReload)
end)

ns.On("PLAYER_GUILD_UPDATE", function(unit)
	if unit ~= nil and unit ~= "player" then return end
	ns.Identity.Refresh()
	ns.Identity.RequestRoster()
	ns.Fire("GuildChanged")
end)

ns.On("GUILD_ROSTER_UPDATE", function()
	ns.Identity.UpdateRoster()
end)

ns.On("PLAYER_LEVEL_UP", function(level)
	ns.Identity.me.level = Util.Safe(level)
end)

ns.On("PLAYER_LOGOUT", function()
	ns.Fire("Logout")
end)

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------

local function Status()
	local me = ns.Identity.me
	ns.Print(L.STATUS_VERSION:format(ns.VERSION, tostring(me.name), tostring(me.realmName)))
	if ns.Identity.InGuild() then
		ns.Print(L.STATUS_GUILD:format(tostring(me.guild), tostring(me.rankName),
			ns.Identity.IsOfficer() and L.STATUS_GUILD_OFFICER or ""))
	else
		ns.Print(L.STATUS_NO_GUILD)
	end
	ns.Print(me.bnetHash and L.STATUS_PLAYER_KEY_BNET or L.STATUS_PLAYER_KEY_FALLBACK)
	if ns.Sync and ns.UI and ns.UI.SyncText then ns.Print(ns.UI.SyncText(ns.Sync.Status())) end
	local imported = me.guid and ns.Db.Character(me.guid).imported
	if imported then ns.Print(L.IMPORT_ALREADY:format(imported.records or 0)) end
	local errors = #ns.db.errors
	ns.Print(errors > 0 and L.STATUS_ERRORS:format(errors) or L.STATUS_NO_ERRORS)
end

-- Developer output, in English on purpose: it gets pasted into bug reports.
local function Debug()
	local me = ns.Identity.me
	ns.Print(L.DEBUG_HEADER:format(ns.VERSION))
	ns.Print(("character %s (%s) guid %s key %s"):format(tostring(me.name), tostring(me.class), tostring(me.guid), tostring(me.playerKey)))
	ns.Print(("guild %s rank %s (%s) officer %s"):format(tostring(me.guild), tostring(me.rankName), tostring(me.rankIndex), tostring(ns.Identity.IsOfficer())))
	local officer = ns.db.debug.officerFlag
	if officer then
		ns.Print(("officer flag check: client says %s, flag %d says %s, true flags [%s]"):format(
			tostring(officer.isOfficer), 4, tostring(officer.byFlag), tostring(officer.trueFlags)))
	end
	ns.Print(("roster %d members, %d with a guid"):format(ns.Identity.roster.count, (function()
		local n = 0
		for _ in pairs(ns.Identity.roster.byTail) do n = n + 1 end
		return n
	end)()))
	local keys = {}
	for key in pairs(ns.db.counters) do keys[#keys + 1] = key end
	table.sort(keys)
	for _, key in ipairs(keys) do
		ns.Print(("  %s = %s"):format(key, tostring(ns.db.counters[key])))
	end
	ns.Fire("Debug")
	local errors = ns.db.errors
	if #errors == 0 then
		ns.Print(L.STATUS_NO_ERRORS)
	else
		for index = math.max(1, #errors - 9), #errors do
			local entry = errors[index]
			ns.Print(("  %s %s: %s"):format(Util.Stamp(entry.at, true), tostring(entry.where), tostring(entry.message)))
		end
	end
end

local function Help()
	ns.Print(L.HELP_INTRO)
	ns.Print(L.HELP_OPEN)
	ns.Print(L.HELP_STATUS)
	ns.Print(L.HELP_OPTIONS)
	ns.Print(L.HELP_IMPORT)
	ns.Print(L.HELP_DEBUG)
end

function ns.ToggleWindow()
	if ns.UI and ns.UI.Toggle then
		ns.UI.Toggle()
	else
		ns.Print(L.STATUS_WINDOW_SOON)
	end
end

function ns.OpenOptions()
	if ns.Options and ns.Options.Open then
		ns.Options.Open()
	else
		ns.Print(L.OPTIONS_SOON)
	end
end

local function HandleSlash(input)
	local command = (input or ""):match("^%s*(%S*)"):lower()
	if command == "" then
		ns.ToggleWindow()
	elseif command == "status" then
		Status()
	elseif command == "options" or command == "config" then
		ns.OpenOptions()
	elseif command == "debug" then
		Debug()
	elseif command == "import" then
		ns.Import.Manual()
	elseif command == "verbose" then
		ns.db.settings.verbose = not ns.db.settings.verbose
		ns.Print("verbose " .. (ns.db.settings.verbose and "on" or "off"))
	else
		Help()
	end
end

SLASH_KILLEDBYSAVAGES1 = "/kbs"
SlashCmdList.KILLEDBYSAVAGES = function(input)
	Util.Guard("slash", HandleSlash, input)
end

function KilledBySavages_OnAddonCompartmentClick()
	Util.Guard("compartment", ns.ToggleWindow)
end
