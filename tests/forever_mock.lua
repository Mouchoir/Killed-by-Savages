-- A fake WoW Forever client for headless tests, shared by the probe harness
-- and the addon harness. Run under LuaJIT (Lua 5.1, like the game) from the
-- repo root.
--
-- Every fake client loads the real addon files in its own environment, and a
-- fake guild channel carries hidden messages between clients (GUILD, PARTY,
-- RAID, INSTANCE_CHAT, WHISPER), so pings, records and relays are exercised
-- end to end. Secret values are a stand-in object that raises an error on
-- any read, and every SavedVariables write goes through a serializer that
-- refuses anything the game could not save.

local Mock = {}

--------------------------------------------------------------------------------
-- Secrets: any read of this object fails, like a secret value on Forever.
--------------------------------------------------------------------------------

local function refuse(what)
	return function() error("attempt to " .. what .. " a secret value", 2) end
end

local SECRET = setmetatable({}, {
	__tostring = refuse("tostring"), __concat = refuse("concatenate"), __index = refuse("index"),
	__newindex = refuse("write into"), __len = refuse("take the length of"), __call = refuse("call"),
	__lt = refuse("compare"), __le = refuse("compare"), __unm = refuse("negate"),
	__add = refuse("add"), __sub = refuse("subtract"), __mul = refuse("multiply"), __div = refuse("divide"),
})
Mock.SECRET = SECRET

--------------------------------------------------------------------------------
-- Time: GetTime and GetServerTime move only when the test advances them.
--------------------------------------------------------------------------------

local now = 1000
local server = 1793973600 -- 2026-11-06 14:00 UTC
local timers, sequence = {}, 0

local function schedule(delay, fn)
	sequence = sequence + 1
	timers[#timers + 1] = { at = now + delay, seq = sequence, fn = fn }
end
Mock.schedule = schedule

function Mock.advance(seconds)
	local target = now + seconds
	while true do
		local best
		for index, timer in ipairs(timers) do
			if timer.at <= target then
				local current = best and timers[best]
				if not current or timer.at < current.at or (timer.at == current.at and timer.seq < current.seq) then
					best = index
				end
			end
		end
		if not best then break end
		local timer = table.remove(timers, best)
		server = server + (timer.at - now)
		now = timer.at
		timer.fn()
	end
	server = server + (target - now)
	now = target
end

function Mock.Now() return now end
function Mock.Server() return math.floor(server) end

--------------------------------------------------------------------------------
-- SavedVariables: written the way the game does, refused when it could not.
--------------------------------------------------------------------------------

local function Serialize(value, stack)
	if rawequal(value, SECRET) then error("a secret value reached the SavedVariables") end
	local kind = type(value)
	if kind == "string" then return ("%q"):format(value) end
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then error("non-finite number") end
		return ("%.17g"):format(value)
	end
	if kind == "boolean" or kind == "nil" then return tostring(value) end
	if kind ~= "table" then error("cannot save a " .. kind) end
	if getmetatable(value) ~= nil then error("table with a metatable in the SavedVariables") end
	stack = stack or {}
	if stack[value] then error("cycle in the SavedVariables") end
	stack[value] = true
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b)
		if type(a) == type(b) then return a < b end
		return type(a) == "number"
	end)
	local parts = {}
	for _, key in ipairs(keys) do
		local keyText
		if type(key) == "string" then
			keyText = ("[%q]"):format(key)
		elseif type(key) == "number" then
			keyText = ("[%s]"):format(("%.17g"):format(key))
		else
			error("cannot save a " .. type(key) .. " key")
		end
		parts[#parts + 1] = keyText .. " = " .. Serialize(value[key], stack)
	end
	stack[value] = nil
	return "{\n" .. table.concat(parts, ",\n") .. "\n}"
end
Mock.Serialize = Serialize

function Mock.Roundtrip(value)
	if value == nil then return nil end
	return assert(loadstring("return " .. Serialize(value)))()
end

--------------------------------------------------------------------------------
-- Addons: which files a fake client loads
--------------------------------------------------------------------------------

local function ReadFile(path)
	local file = assert(io.open(path, "rb"), "cannot open " .. path)
	local text = file:read("*a")
	file:close()
	return text
end

local function Dir(path)
	return path:match("^(.*)/[^/]*$") or "."
end

-- The Lua files of a TOC, in load order, XML includes resolved to the
-- scripts they name.
function Mock.TocFiles(tocPath)
	local base = Dir(tocPath)
	local files = {}
	local function add(path)
		if path:match("%.xml$") then
			local xml = ReadFile(path)
			for script in xml:gmatch('<Script%s+file="([^"]+)"') do
				add(Dir(path) .. "/" .. script:gsub("\\", "/"))
			end
		else
			files[#files + 1] = path
		end
	end
	for line in ReadFile(tocPath):gmatch("[^\r\n]+") do
		if not line:match("^##") and line:match("%S") then
			add(base .. "/" .. line:gsub("%s+$", ""):gsub("\\", "/"))
		end
	end
	return files
end

Mock.PROBE = { name = "KBSProbe", savedName = "KBSProbeDB", slash = "KBSPROBE", files = { "probe/KBSProbe/KBSProbe.lua" } }
Mock.ADDON = {
	name = "KilledBySavages", savedName = "KilledBySavagesDB", slash = "KILLEDBYSAVAGES",
	files = Mock.TocFiles("addon/KilledBySavages/KilledBySavages.toc"),
}

local sources = {}
local function Source(path)
	if not sources[path] then sources[path] = ReadFile(path) end
	return sources[path]
end

--------------------------------------------------------------------------------
-- The world: players, the guild, Horde victims
--------------------------------------------------------------------------------

local REALM = "Ashbringer"
Mock.REALM = REALM
local RESULT = {
	Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3, InvalidChatType = 4,
	NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7, ChannelThrottle = 8, GeneralError = 9,
	NotInGuild = 10, AddOnMessageLockdown = 11,
}
Mock.RESULT = RESULT

-- Fictional guild ranks, like Forever's "First Last" world: rank 0 is the
-- guild master, ranks 0 to 2 may speak in officer chat.
local RANKS = { "Warlord", "Herald", "Blade", "Scout", "Squire", "Prey" }
local OFFICER_RANKS = { [0] = true, [1] = true, [2] = true }
Mock.RANKS = RANKS

local function Guid(number, server_)
	return ("Player-%d-%08X"):format(server_ or 1234, number)
end
Mock.Guid = Guid

local players = {}
local guildRoster = {}
local clients = {}
local network = { sent = {} }
Mock.players, Mock.clients, Mock.network = players, clients, network

function Mock.AddPlayer(guid, facts)
	facts.realm = facts.realm or ""
	facts.level = facts.level or 60
	players[guid] = facts
	return facts
end

-- Entries are GUIDs (rank 3, a member) or { guid = ..., rank = n }.
function Mock.SetGuildRoster(list)
	guildRoster = {}
	for index, entry in ipairs(list) do
		if type(entry) == "string" then
			guildRoster[index] = { guid = entry, rank = 3 }
		else
			guildRoster[index] = entry
		end
	end
end

local HORDE = {
	{ guid = Guid(101), name = "Gruk Bonecrusher", class = "WARRIOR", race = "Orc", guild = "Blood Pact" },
	{ guid = Guid(102), name = "Zaljin Darkspear", class = "SHAMAN", race = "Troll" },
	{ guid = Guid(103), name = "Moro Stillwind", class = "DRUID", race = "Tauren" },
	{ guid = Guid(104), name = "Sylas Mournhollow", class = "MAGE", race = "Scourge" },
	{ guid = Guid(105), name = "Thrag Ironhide", class = "ROGUE", race = "Orc" },
	{ guid = Guid(106), name = "Vexa Cinderhorn", class = "HUNTER", race = "Tauren" },
}
for _, horde in ipairs(HORDE) do
	Mock.AddPlayer(horde.guid, { name = horde.name, class = horde.class, race = horde.race, faction = "Horde", guild = horde.guild })
end
Mock.HORDE = HORDE

local function deliver(from, prefix, text, channel, target)
	network.sent[#network.sent + 1] = { from = from.name, channel = channel, text = text, at = now, target = target }
	for _, client in ipairs(clients) do
		if client.online and client.prefixes[prefix] then
			local st, fs = client.state, from.state
			local reach = false
			if channel == "GUILD" then
				-- In game our own guild messages came back on some characters
				-- and not on others; the mock takes the harder case: no echo.
				reach = client ~= from and st.guild ~= nil and st.guild == fs.guild
			elseif channel == "WHISPER" then
				reach = target == st.name
			elseif channel == "INSTANCE_CHAT" then
				reach = st.bucket == "bg" and fs.bucket == "bg"
			elseif channel == "PARTY" or channel == "RAID" then
				reach = st.groupId ~= nil and st.groupId == fs.groupId
			end
			if reach then
				local generation = client.generation
				schedule(0.05, function()
					if client.online and client.generation == generation then
						-- The sender comes as "First Last", no realm (seen in game).
						client.fire("CHAT_MSG_ADDON", prefix, text, channel, fs.name)
					end
				end)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Frames: just enough widget API for the addons and their windows.
--------------------------------------------------------------------------------

local FIELD_KEYS = { Low = true, High = true, Text = true, Inset = true, TitleText = true, Bg = true, Icon = true, NineSlice = true, ScrollBar = true }

local function NewFrame(client, kind, name)
	local frame = { kind = kind or "Frame", name = name, shown = true, scripts = {}, events = {}, text = "", children = {} }
	local methods = {}
	function methods.RegisterEvent(self, event)
		if client.forbidden[event] then error(("Frame:RegisterEvent(): %s is forbidden"):format(event)) end
		self.events[event] = true
	end
	function methods.UnregisterEvent(self, event) self.events[event] = nil end
	function methods.RegisterUnitEvent(self, event) self.events[event] = true end
	function methods.SetScript(self, handler, fn) self.scripts[handler] = fn end
	function methods.GetScript(self, handler) return self.scripts[handler] end
	function methods.HookScript(self, handler, fn) self.scripts[handler] = fn end
	function methods.Show(self) self.shown = true end
	function methods.Hide(self) self.shown = false end
	function methods.IsShown(self) return self.shown end
	function methods.IsVisible(self) return self.shown end
	function methods.SetText(self, text) self.text = text end
	function methods.GetText(self) return self.text end
	function methods.GetName(self) return self.name end
	function methods.GetWidth(self) return self.width or 100 end
	function methods.GetHeight(self) return self.height or 100 end
	function methods.SetSize(self, width, height) self.width, self.height = width, height end
	function methods.SetWidth(self, width) self.width = width end
	function methods.SetHeight(self, height) self.height = height end
	function methods.GetStringWidth() return 50 end
	function methods.GetFrameLevel() return 1 end
	function methods.GetParent(self) return self.parent end
	function methods.SetParent(self, parent) self.parent = parent end
	function methods.SetID(self, id) self.id = id end
	function methods.GetID(self) return self.id or 0 end
	function methods.GetPoint() return nil end
	function methods.GetValue(self) return self.value or 1 end
	function methods.SetValue(self, value) self.value = value end
	function methods.GetChecked(self) return self.checked == true end
	function methods.SetChecked(self, checked) self.checked = checked end
	function methods.HasFocus() return false end
	function methods.SetFont() return true end
	function methods.SetTexture() return true end
	function methods.GetNormalTexture() return nil end
	function methods.SetAllPoints() end
	local function Region(self, regionKind)
		local region = NewFrame(client, regionKind)
		region.parent = self
		return region
	end
	function methods.CreateTexture(self) return Region(self, "Texture") end
	function methods.CreateFontString(self) return Region(self, "FontString") end
	function methods.CreateMaskTexture(self) return Region(self, "MaskTexture") end
	function methods.CreateAnimationGroup(self) return Region(self, "AnimationGroup") end
	function methods.CreateAnimation(self) return Region(self, "Animation") end
	-- Unknown methods are no-ops; unknown fields (lower case, or the child
	-- regions templates add) are nil, as on a frame the game creates.
	setmetatable(frame, {
		__index = function(_, key)
			if methods[key] then return methods[key] end
			if type(key) == "string" and key:match("^%u") and not FIELD_KEYS[key] then
				return function() end
			end
			return nil
		end,
	})
	client.frames[#client.frames + 1] = frame
	return frame
end
Mock.NewFrame = NewFrame

--------------------------------------------------------------------------------
-- A fake Forever client
--------------------------------------------------------------------------------

function Mock.NewClient(spec)
	local addon = spec.addon or Mock.PROBE
	local client = {
		name = spec.name, guid = spec.guid, online = false, prefixes = {}, chat = {},
		frames = {}, forbidden = {}, saved = spec.saved, generation = 0, addon = addon,
	}
	local first, surname = spec.name:match("^(%S+) (.+)$")
	local st = {
		name = spec.name, first = first, surname = surname,
		realm = REALM, fullName = spec.name .. "-" .. REALM, guid = spec.guid,
		class = spec.class, race = spec.race or "Human", guild = spec.guild, pet = spec.pet,
		locale = spec.locale or "frFR", battleTag = spec.battleTag, rank = spec.rank or 3,
		bucket = "world", zone = "Contreforts de Hautebrande", subzone = "Moulin-de-Tarren",
		mapID = 1424, x = 0.6123, y = 0.2034,
		secretIdentity = false, secretStats = false, secretScore = false, chatLocked = false,
		restrictions = { Combat = false, Encounter = false, ChallengeMode = false, PvPMatch = false, Map = false, Chat = false },
		session = 0, lifetime = spec.lifetime or 100, recapReadyAt = 0, throttle = 0,
	}
	client.state = st
	client.key = st.fullName
	Mock.AddPlayer(spec.guid, {
		name = spec.name, class = spec.class, race = st.race, faction = "Alliance",
		guild = spec.guild, lifetime = spec.lifetime or 100,
	})

	local function unitGuid(unit)
		if unit == "player" then return st.guid end
		if unit == "pet" then return st.pet end
		if unit == "target" then return st.target end
		local group = st.group
		if group then
			local index = tonumber(unit:match("^party(%d)$") or "")
			if index and group.kind == "party" then return group.others[index] and group.others[index].guid end
			index = tonumber(unit:match("^partypet(%d)$") or "")
			if index and group.kind == "party" then return group.others[index] and group.others[index].pet end
			index = tonumber(unit:match("^raid(%d+)$") or "")
			if index and group.kind == "raid" then return group.members[index] and group.members[index].guid end
			index = tonumber(unit:match("^raidpet(%d+)$") or "")
			if index and group.kind == "raid" then return group.members[index] and group.members[index].pet end
		end
		return nil
	end

	local function playerOf(unit)
		local guid = unitGuid(unit)
		return guid and players[guid]
	end

	local function rankOf(guid)
		for _, entry in ipairs(guildRoster) do
			if entry.guid == guid then return entry.rank end
		end
		return nil
	end

	local function boot()
		client.generation = client.generation + 1
		local generation = client.generation
		client.frames = {}
		local env = setmetatable({}, { __index = _G })
		env._G = env
		client.env = env

		local function later(delay, fn)
			schedule(delay, function()
				if client.online and client.generation == generation then fn() end
			end)
		end

		-- Lua as the game ships it
		env.date, env.time = os.date, os.time
		env.issecretvalue = function(value) return rawequal(value, SECRET) end
		env.issecrettable = function() return false end
		env.canaccessvalue = function(value) return not rawequal(value, SECRET) end
		env.WOW_PROJECT_ID = 18
		env.SlashCmdList = {}
		env.geterrorhandler = function() return function(message) error(message, 0) end end
		env.securecallfunction = function(fn, ...) return fn(...) end
		env.securecall = function(fn, ...) return fn(...) end
		env.hooksecurefunc = function() end
		env.strsplit = function(delimiter, text) return unpack((function()
			local out = {}
			for piece in (text .. delimiter):gmatch("(.-)" .. delimiter:gsub("%p", "%%%0")) do out[#out + 1] = piece end
			return out
		end)()) end
		-- The global aliases the game adds to the string and table libraries.
		env.strmatch, env.strfind, env.strsub, env.strlower, env.strupper = string.match, string.find, string.sub, string.lower, string.upper
		env.strlen, env.strrep, env.strbyte, env.strchar, env.format, env.gsub = string.len, string.rep, string.byte, string.char, string.format, string.gsub
		env.strtrim = function(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end
		env.strjoin = function(delimiter, ...) return table.concat({ ... }, delimiter) end
		env.tinsert, env.tremove, env.wipe = table.insert, table.remove, function(t) for k in pairs(t) do t[k] = nil end return t end
		env.tostringall = function(...)
			local out = {}
			for index = 1, select("#", ...) do out[index] = tostring((select(index, ...))) end
			return unpack(out)
		end
		env.max, env.min, env.floor, env.ceil, env.abs = math.max, math.min, math.floor, math.ceil, math.abs

		-- Client, frames, timers
		env.CreateFrame = function(kind, name, parent)
			local frame = NewFrame(client, kind, name)
			frame.parent = parent
			if name then env[name] = frame end
			return frame
		end
		env.UIParent = NewFrame(client, "Frame", "UIParent")
		env.Minimap = NewFrame(client, "Frame", "Minimap")
		env.MinimapCluster = NewFrame(client, "Frame", "MinimapCluster")
		env.GameTooltip = NewFrame(client, "GameTooltip", "GameTooltip")
		env.UISpecialFrames = {}
		env.ChatFontNormal = {}
		env.LOCALIZED_CLASS_NAMES_MALE = { WARRIOR = "Guerrier", MAGE = "Mage", HUNTER = "Chasseur", ROGUE = "Voleur",
			PALADIN = "Paladin", PRIEST = "Prêtre", SHAMAN = "Chaman", WARLOCK = "Démoniste", DRUID = "Druide" }
		env.SOUNDKIT = { IG_CHARACTER_INFO_OPEN = 839, IG_CHARACTER_INFO_CLOSE = 840 }
		env.PlaySound = function() end
		-- The 12.x list: enough of it to run every row initializer once.
		env.ScrollBoxConstants = { RetainScrollPosition = 1, AlignNearest = 2 }
		env.CreateScrollBoxListLinearView = function()
			local view = {}
			function view:SetElementExtent(extent) self.extent = extent end
			function view:SetElementInitializer(_, fn) self.init = fn end
			function view:SetElementExtentCalculator() end
			function view:SetElementFactory() end
			function view:SetPadding() end
			return view
		end
		env.CreateDataProvider = function(list)
			local provider = { list = list or {} }
			function provider:Insert(item) self.list[#self.list + 1] = item end
			function provider:GetSize() return #self.list end
			return provider
		end
		env.ScrollUtil = {
			InitScrollBoxListWithScrollBar = function(box, _, view)
				box.view = view
				box.SetDataProvider = function(self, provider)
					self.provider = provider
					self.rows = {}
					for _, item in ipairs(provider.list) do
						local row = NewFrame(client, "Button")
						view.init(row, item)
						self.rows[#self.rows + 1] = row
					end
				end
			end,
		}
		env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) client.chat[#client.chat + 1] = text end }
		env.C_Timer = { After = function(delay, fn) later(delay, fn) end }
		env.GetTime = function() return now end
		env.GetServerTime = function() return math.floor(server) end
		env.GetBuildInfo = function() return "1.60.1", "70790", "Nov 4 2026", 16001 end
		env.GetLocale = function() return st.locale end
		env.C_AddOns = { GetAddOnMetadata = function(_, field) if field == "Version" then return "0.1.0-test" end end }
		env.C_CVar = { GetCVar = function() return "0" end, GetCVarBool = function() return false end }
		env.GetCVar = env.C_CVar.GetCVar
		env.InCombatLockdown = function() return false end

		-- The honor sentences of the French Forever client, as read in game.
		env.COMBATLOG_HONORGAIN = "%s meurt (victoire honorable : %s). Vous gagnez %d points d’honneur."
		env.COMBATLOG_HONORGAIN_NO_RANK = "%s meurt (victoire honorable). Vous gagnez %d points d’honneur."
		env.COMBATLOG_HONORGAIN_EXHAUSTION1 = "%s meurt (victoire honorable : %s). Vous gagnez %d points d’honneur (bonus de %s de %s)."
		env.COMBATLOG_HONORGAIN_NO_RANK_EXHAUSTION1 = "%s meurt (victoire honorable). Vous gagnez %d points d’honneur (bonus de %s de %s)."
		env.COMBATLOG_HONORAWARD = "Vous avez reçu %d points d’honneur."
		env.COMBATLOG_DISHONORGAIN = "%s meurt, victoire déshonorante."

		env.Enum = {
			AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
			AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
			SendAddonMessageResult = RESULT,
		}
		local typeNames = {}
		for name, value in pairs(env.Enum.AddOnRestrictionType) do typeNames[value] = name end
		env.C_RestrictedActions = {
			IsAddOnRestrictionActive = function(kind) return st.restrictions[typeNames[kind]] == true end,
		}
		env.C_Secrets = {
			HasSecretRestrictions = function() return true end,
			ShouldUnitIdentityBeSecret = function(unit) return st.secretIdentity and unit ~= "player" end,
		}
		env.C_DateAndTime = {
			GetSecondsUntilWeeklyReset = function() return 30 * 3600 end,
			GetSecondsUntilDailyReset = function() return 5 * 3600 end,
		}

		-- Where we are
		env.IsInInstance = function()
			if st.bucket == "bg" then return true, "pvp" end
			if st.bucket == "instance" then return true, "party" end
			return false, "none"
		end
		env.GetInstanceInfo = function()
			if st.bucket == "bg" then return "Vallée d'Alterac", "pvp", 0, "", 40, 0, false, 30, 40, nil end
			return "Royaumes de l'est", "none", 0, "", 0, 0, false, 0, 0, nil
		end
		env.GetRealZoneText = function() return st.zone end
		env.GetSubZoneText = function() return st.subzone end
		env.C_Map = {
			GetBestMapForUnit = function(unit) if unit == "player" then return st.mapID end end,
			GetPlayerMapPosition = function(_, unit)
				if unit ~= "player" or st.noPosition then return nil end
				local vector = { x = st.x, y = st.y }
				function vector.GetXY(self) return self.x, self.y end
				return vector
			end,
			GetMapInfo = function(mapID) return { mapID = mapID, name = st.zone } end,
		}

		-- Group
		env.IsInRaid = function() return st.group ~= nil and st.group.kind == "raid" end
		env.IsInGroup = function() return st.group ~= nil end
		env.GetNumGroupMembers = function()
			if not st.group then return 0 end
			if st.group.kind == "raid" then return #st.group.members end
			return #st.group.others + 1
		end
		env.GetRaidRosterInfo = function(index)
			local member = st.group and st.group.kind == "raid" and st.group.members[index]
			if not member then return nil end
			local facts = players[member.guid]
			return facts.name, 0, member.subgroup, 60, facts.class, facts.class, st.zone, true, false, nil, nil, false
		end

		-- Units and players
		env.UnitGUID = function(unit)
			local guid = unitGuid(unit)
			if guid and st.secretIdentity and unit ~= "player" then return SECRET end
			return guid
		end
		-- Seen in game: UnitName and UnitFullName give the first name and the
		-- surname; GetUnitName(unit, true) gives "First Last".
		env.UnitName = function(unit)
			if unit == "player" then return st.first, st.surname end
			local facts = playerOf(unit)
			if not facts then return nil end
			if st.secretIdentity then return SECRET end
			return facts.name:match("^(%S+) (.+)$")
		end
		env.UnitFullName = function(unit)
			if unit == "player" then return st.first, st.surname end
			return env.UnitName(unit)
		end
		env.GetUnitName = function(unit)
			if unit == "player" then return st.name end
			local facts = playerOf(unit)
			return facts and facts.name
		end
		env.UnitClass = function(unit)
			if unit == "player" then return "Chasseur", st.class, 3 end
		end
		env.UnitRace = function(unit)
			if unit == "player" then return st.race, st.race, 1 end
		end
		local function factsOf(unit)
			if unit:match("^nameplate") then
				local guid = st.nameplates and st.nameplates[unit]
				return guid and players[guid]
			end
			return playerOf(unit)
		end
		env.UnitLevel = function(unit)
			if unit == "player" then return 60 end
			local facts = factsOf(unit)
			return facts and facts.level or 0
		end
		env.UnitFactionGroup = function(unit)
			if unit == "player" then return "Alliance", "Alliance" end
			local facts = factsOf(unit)
			if facts then return facts.faction, facts.faction end
		end
		env.UnitExists = function(unit) return unitGuid(unit) ~= nil end
		env.UnitIsPlayer = function(unit)
			local guid = unitGuid(unit)
			return guid ~= nil and guid:find("^Player") ~= nil
		end
		env.UnitIsPVP = function() return true end
		env.UnitTokenFromGUID = function(guid)
			if rawequal(guid, SECRET) then error("bad argument #1 to 'UnitTokenFromGUID' (secret)") end
			for _, unit in ipairs({ "player", "pet", "target" }) do
				if unitGuid(unit) == guid then return unit end
			end
			for unit, known in pairs(st.nameplates or {}) do
				if known == guid then return unit end
			end
			return nil
		end
		env.GetPlayerInfoByGUID = function(guid)
			if rawequal(guid, SECRET) then error("bad argument #1 to 'GetPlayerInfoByGUID' (secret)") end
			local facts = players[guid]
			if not facts then return nil end
			return facts.class:lower(), facts.class, facts.race, facts.race, 2, facts.name, facts.realm
		end
		env.GetGuildInfo = function(unit)
			if unit == "player" then
				if not st.guild then return nil end
				return st.guild, RANKS[st.rank + 1], st.rank
			end
			local facts = factsOf(unit)
			return facts and facts.guild
		end
		env.GetRealmName = function() return REALM end
		env.GetNormalizedRealmName = function() return REALM end
		env.BNGetInfo = function() return 1, st.battleTag, 1, "", false, false, false end

		-- Guild
		env.IsInGuild = function() return st.guild ~= nil end
		env.GetNumGuildMembers = function()
			if not st.guild then return 0, 0, 0 end
			return #guildRoster, #guildRoster, 0
		end
		env.GetGuildRosterInfo = function(index)
			local entry = guildRoster[index]
			local facts = entry and players[entry.guid]
			if not facts then return nil end
			local online = false
			for _, other in ipairs(clients) do
				if other.guid == entry.guid and other.online then online = true end
			end
			return facts.name, RANKS[entry.rank + 1], entry.rank, 60, facts.class, st.zone, "", "", online, 0,
				facts.class, 0, 0, false, false, 0, entry.guid
		end
		env.C_GuildInfo = {
			GuildRoster = function() later(0.3, function() client.fire("GUILD_ROSTER_UPDATE") end) end,
			GuildControlGetRankFlags = function(rankOrder)
				local flags = {}
				for index = 1, 20 do flags[index] = false end
				flags[1], flags[2] = true, true
				if OFFICER_RANKS[rankOrder - 1] then flags[3], flags[4] = true, true end
				if rankOrder == 1 then for index = 1, 20 do flags[index] = true end end
				return flags
			end,
			IsGuildOfficer = function() return OFFICER_RANKS[rankOf(st.guid) or st.rank] == true end,
		}

		-- PvP counters and the scoreboard
		env.GetPVPSessionStats = function()
			if st.secretStats then return SECRET, SECRET end
			return st.session, st.session * 100
		end
		env.GetPVPLifetimeStats = function()
			if st.secretStats then return SECRET, SECRET end
			return st.lifetime, 0
		end
		env.GetPVPYesterdayStats = function() return 0, 0 end
		env.GetNumBattlefieldScores = function() return st.score and #st.score or 0 end
		env.C_PvP = {
			IsBattleground = function() return st.bucket == "bg" end,
			GetActiveMatchState = function() return st.bucket == "bg" and 2 or 0 end,
		}
		env.C_PvP.GetScoreInfo = function(index)
			local row = st.score and st.score[index]
			if not row then return nil end
			local hidden = st.secretScore
			return {
				name = row.name, guid = hidden and SECRET or row.guid,
				killingBlows = hidden and SECRET or row.kb, honorableKills = hidden and SECRET or row.hk,
				deaths = hidden and SECRET or row.deaths, honorGained = hidden and SECRET or row.honor,
				faction = row.faction, raceName = row.race, classToken = row.class, className = row.class,
				damageDone = hidden and SECRET or 0, healingDone = hidden and SECRET or 0, stats = {},
			}
		end
		env.C_PvP.GetScoreInfoByPlayerGuid = function(guid)
			for index, row in ipairs(st.score or {}) do
				if row.guid == guid then return env.C_PvP.GetScoreInfo(index) end
			end
		end
		env.RequestBattlefieldScoreData = function()
			later(0.2, function() client.fire("UPDATE_BATTLEFIELD_SCORE") end)
		end
		env.GetBattlefieldWinner = function() return st.winner end

		-- Death recap
		env.C_DeathRecap = {
			HasRecapEvents = function() return st.recap ~= nil and now >= st.recapReadyAt end,
			GetRecapEvents = function() return st.recap end,
		}

		-- Inspect
		env.CanInspect = function(unit) return unit == "target" and st.target ~= nil and not st.outOfRange end
		env.NotifyInspect = function()
			local guid = st.target
			later(0.3, function() client.fire("INSPECT_READY", guid) end)
			later(0.6, function() client.fire("INSPECT_HONOR_UPDATE") end)
		end
		env.GetInspectHonorData = function()
			local facts = st.target and players[st.target]
			return 2, 0, 0, 0, facts and facts.lifetime or 0, 0, 7, 1200, 3000
		end
		env.ClearInspectPlayer = function() client.cleared = (client.cleared or 0) + 1 end

		-- Hidden messages
		env.C_ChatInfo = {
			RegisterAddonMessagePrefix = function(prefix)
				client.prefixes[prefix] = true
				return 0
			end,
			InChatMessagingLockdown = function() return st.chatLocked end,
			SendAddonMessage = function(prefix, text, channel, target)
				if rawequal(text, SECRET) then error("secret argument") end
				if channel == "WHISPER" and not target then return RESULT.TargetRequired end
				assert(type(text) == "string", "message must be a string")
				if #text > 255 or text:find("%z") then return RESULT.InvalidMessage end
				if st.chatLocked then return RESULT.AddOnMessageLockdown end
				if st.throttle > 0 then
					st.throttle = st.throttle - 1
					return RESULT.AddonMessageThrottle
				end
				if channel == "GUILD" and not st.guild then return RESULT.NotInGuild end
				if (channel == "PARTY" or channel == "RAID") and not st.group then return RESULT.NotInGroup end
				if channel == "INSTANCE_CHAT" and st.bucket ~= "bg" then return RESULT.NotInGroup end
				deliver(client, prefix, text, channel, target)
				return RESULT.Success
			end,
		}

		-- Every file of the addon, in TOC order, with one shared namespace.
		local ns = {}
		for _, path in ipairs(addon.files) do
			local chunk = assert(loadstring(Source(path), "@" .. path))
			setfenv(chunk, env)
			chunk(addon.name, ns)
		end
		client.ns = ns
	end

	function client.fire(event, ...)
		for _, frame in ipairs(client.frames) do
			if frame.events[event] and frame.scripts.OnEvent then
				frame.scripts.OnEvent(frame, event, ...)
			end
		end
	end

	function client.login()
		boot()
		client.online = true
		-- A test seam: runs once the files are loaded, before any event.
		if client.onBoot then client.onBoot(client.ns, client.env) end
		client.env[addon.savedName] = Mock.Roundtrip(client.saved)
		client.fire("ADDON_LOADED", addon.name)
		client.fire("PLAYER_LOGIN")
		client.fire("PLAYER_ENTERING_WORLD", true, false)
	end

	function client.logout()
		client.fire("PLAYER_LOGOUT")
		client.saved = Mock.Roundtrip(client.env[addon.savedName])
		client.online = false
	end

	-- A crash: nothing is written, the next login starts from the last save.
	function client.crash()
		client.online = false
	end

	function client.slash(text)
		client.env.SlashCmdList[addon.slash](text)
	end

	function client.db() return client.env[addon.savedName] end
	function client.log(name) return client.db().log[name] end
	function client.counter(key) return client.db().counters[key] or 0 end

	function client.said(fragment)
		for _, text in ipairs(client.chat) do
			if text:find(fragment, 1, true) then return true end
		end
		return false
	end

	clients[#clients + 1] = client
	return client
end

-- FNV-1a with the bit library, to check the addon's plain-arithmetic one.
local bit = require("bit")
function Mock.Fnv(text)
	local hash = bit.tobit(2166136261)
	for index = 1, #text do
		hash = bit.bxor(hash, text:byte(index))
		hash = bit.tobit(bit.tobit(hash * 403) + bit.lshift(hash, 24))
	end
	return bit.tohex(hash)
end

--------------------------------------------------------------------------------
-- Checks
--------------------------------------------------------------------------------

local failures, checks = 0, 0

function Mock.check(label, condition, extra)
	checks = checks + 1
	if condition then
		print("  ok    " .. label)
	else
		failures = failures + 1
		print("  FAIL  " .. label .. (extra ~= nil and ("   [" .. tostring(extra) .. "]") or ""))
	end
end

function Mock.section(title)
	print("")
	print("## " .. title)
end

function Mock.finish()
	print("")
	print(("%d checks, %d failed"):format(checks, failures))
	os.exit(failures == 0 and 0 or 1)
end

return Mock
