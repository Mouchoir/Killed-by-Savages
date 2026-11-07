-- Headless test of probe/KBSProbe/KBSProbe.lua against fake Forever clients.
-- Run from the repo root with LuaJIT (Lua 5.1, like the game):
--
--   luajit tests/harness.lua
--
-- Every fake client loads the real addon file in its own environment, and a
-- fake guild channel carries hidden messages between them, so pings, reports
-- and relays are exercised end to end. Secret values are a stand-in object
-- that raises an error on any read, and every SavedVariables write goes
-- through a serializer that refuses anything the game could not save.

local bit = require("bit")

local ADDON_FILE = "probe/KBSProbe/KBSProbe.lua"
local REPORT_TOOL = "tools/probe_report.lua"
local SAVED_OUT = "tests/last-savedvariables.lua"
local WARDENS_OUT = "tests/last-savedvariables-wardens.lua"

local source = assert(io.open(ADDON_FILE, "rb")):read("*a")
math.randomseed(7)

local failures, checks = 0, 0
local function check(label, condition, extra)
	checks = checks + 1
	if condition then
		print("  ok    " .. label)
	else
		failures = failures + 1
		print("  FAIL  " .. label .. (extra ~= nil and ("   [" .. tostring(extra) .. "]") or ""))
	end
end

local function section(title)
	print("")
	print("## " .. title)
end

local function last(list)
	return list and list[#list]
end

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

local function advance(seconds)
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

local function Roundtrip(value)
	if value == nil then return nil end
	return assert(loadstring("return " .. Serialize(value)))()
end

--------------------------------------------------------------------------------
-- The world: players, the guild, Horde victims
--------------------------------------------------------------------------------

local REALM = "Ashbringer"
local RESULT = {
	Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3, InvalidChatType = 4,
	NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7, ChannelThrottle = 8, GeneralError = 9,
	NotInGuild = 10, AddOnMessageLockdown = 11,
}

local function Guid(number) return ("Player-1234-%08X"):format(number) end

local players = {}
local guildRoster = {}
local clients = {}
local network = { sent = {} }

local function AddPlayer(guid, facts)
	facts.realm = facts.realm or ""
	facts.level = facts.level or 60
	players[guid] = facts
	return facts
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
	AddPlayer(horde.guid, { name = horde.name, class = horde.class, race = horde.race, faction = "Horde", guild = horde.guild })
end

local function deliver(from, prefix, text, channel, target)
	network.sent[#network.sent + 1] = { from = from.name, channel = channel, text = text, at = now }
	for _, client in ipairs(clients) do
		if client.online and client.prefixes[prefix] then
			local st, fs = client.state, from.state
			local reach = false
			if channel == "GUILD" then
				-- In game on 2026-11-06 our own guild messages came back on
				-- some characters and not on others; the probe must cope with
				-- both, and this mock takes the harder case: no echo.
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
-- Frames: just enough widget API for the probe and its export window.
--------------------------------------------------------------------------------

local function NewFrame(client, kind, name)
	local frame = { kind = kind or "Frame", name = name, shown = true, scripts = {}, events = {}, text = "" }
	local methods = {}
	function methods.RegisterEvent(self, event)
		if client.forbidden[event] then error(("Frame:RegisterEvent(): %s is forbidden"):format(event)) end
		self.events[event] = true
	end
	function methods.UnregisterEvent(self, event) self.events[event] = nil end
	function methods.SetScript(self, handler, fn) self.scripts[handler] = fn end
	function methods.GetScript(self, handler) return self.scripts[handler] end
	function methods.Show(self) self.shown = true end
	function methods.Hide(self) self.shown = false end
	function methods.IsShown(self) return self.shown end
	function methods.SetText(self, text) self.text = text end
	function methods.GetText(self) return self.text end
	function methods.CreateTexture() return NewFrame(client, "Texture") end
	function methods.CreateFontString() return NewFrame(client, "FontString") end
	setmetatable(frame, {
		__index = function(_, key)
			return methods[key] or function() end
		end,
	})
	client.frames[#client.frames + 1] = frame
	return frame
end

--------------------------------------------------------------------------------
-- A fake Forever client
--------------------------------------------------------------------------------

local function NewClient(spec)
	local client = {
		name = spec.name, guid = spec.guid, online = false, prefixes = {}, chat = {},
		frames = {}, forbidden = {}, saved = spec.saved, generation = 0,
	}
	local first, surname = spec.name:match("^(%S+) (.+)$")
	local st = {
		name = spec.name, first = first, surname = surname,
		realm = REALM, fullName = spec.name .. "-" .. REALM, guid = spec.guid,
		class = spec.class, guild = spec.guild, pet = spec.pet, locale = spec.locale or "frFR",
		battleTag = spec.battleTag,
		bucket = "world", zone = "Contreforts de Hautebrande", subzone = "Moulin-de-Tarren",
		mapID = 1424, x = 0.6123, y = 0.2034,
		secretIdentity = false, secretStats = false, secretScore = false, chatLocked = false,
		restrictions = { Combat = false, Encounter = false, ChallengeMode = false, PvPMatch = false, Map = false, Chat = false },
		session = 0, lifetime = spec.lifetime or 100, recapReadyAt = 0, throttle = 0,
	}
	client.state = st
	client.key = st.fullName
	AddPlayer(spec.guid, {
		name = spec.name, class = spec.class, race = spec.race or "Human", faction = "Alliance",
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

		-- Client, frames, timers
		env.CreateFrame = function(kind, name)
			local frame = NewFrame(client, kind, name)
			if name then env[name] = frame end
			return frame
		end
		env.UIParent = NewFrame(client, "Frame", "UIParent")
		env.UISpecialFrames = {}
		env.ChatFontNormal = {}
		env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) client.chat[#client.chat + 1] = text end }
		env.C_Timer = { After = function(delay, fn) later(delay, fn) end }
		env.GetTime = function() return now end
		env.GetServerTime = function() return math.floor(server) end
		env.GetBuildInfo = function() return "1.60.1", "70790", "Nov 4 2026", 16001 end
		env.GetLocale = function() return st.locale end

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
			if unit == "player" then return st.guild, "Membre", 3 end
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
			local guid = guildRoster[index]
			local facts = guid and players[guid]
			if not facts then return nil end
			return facts.name, "Membre", 3, 60, facts.class, st.zone, "", "", true, 0,
				facts.class, 0, 0, false, false, 0, guid
		end
		env.C_GuildInfo = {
			GuildRoster = function() later(0.3, function() client.fire("GUILD_ROSTER_UPDATE") end) end,
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

		local chunk = assert(loadstring(source, "@" .. ADDON_FILE))
		setfenv(chunk, env)
		chunk("KBSProbe", {})
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
		client.env.KBSProbeDB = Roundtrip(client.saved)
		client.fire("ADDON_LOADED", "KBSProbe")
		client.fire("PLAYER_LOGIN")
		client.fire("PLAYER_ENTERING_WORLD", true, false)
	end

	function client.logout()
		client.fire("PLAYER_LOGOUT")
		client.saved = Roundtrip(client.env.KBSProbeDB)
		client.online = false
	end

	function client.slash(text)
		client.env.SlashCmdList.KBSPROBE(text)
	end

	function client.db() return client.env.KBSProbeDB end
	function client.log(name) return client.env.KBSProbeDB.log[name] end
	function client.counter(key) return client.env.KBSProbeDB.counters[key] or 0 end

	function client.said(fragment)
		for _, text in ipairs(client.chat) do
			if text:find(fragment, 1, true) then return true end
		end
		return false
	end

	clients[#clients + 1] = client
	return client
end

-- FNV-1a with the bit library, to check the probe's plain-arithmetic one.
local function Fnv(text)
	local hash = bit.tobit(2166136261)
	for index = 1, #text do
		hash = bit.bxor(hash, text:byte(index))
		hash = bit.tobit(bit.tobit(hash * 403) + bit.lshift(hash, 24))
	end
	return bit.tohex(hash)
end

--------------------------------------------------------------------------------
-- The cast
--------------------------------------------------------------------------------

local A = NewClient({
	name = "Aldric Stormhand", guid = Guid(1), class = "HUNTER", race = "Human", guild = "Savages",
	pet = "Pet-0-1234-1-0000AAA1", lifetime = 500, battleTag = "Aldric#2101",
	saved = { settings = { verbose = true } },
})
local B = NewClient({
	name = "Brenna Ironvale", guid = Guid(2), class = "WARLOCK", race = "Dwarf", guild = "Savages",
	pet = "Pet-0-1234-1-0000BBB2", lifetime = 1200, battleTag = "Brenna#1188",
})
local C = NewClient({ name = "Corwin Ashdown", guid = Guid(3), class = "WARRIOR", guild = "Savages", lifetime = 80 })
local D = NewClient({ name = "Dalia Brightwater", guid = Guid(4), class = "PRIEST", race = "NightElf", guild = "Savages", lifetime = 300 })
AddPlayer(Guid(5), { name = "Edric Vale", class = "PALADIN", race = "Human", faction = "Alliance", guild = "Savages" })
guildRoster = { A.guid, B.guid, C.guid, D.guid, Guid(5) }

--------------------------------------------------------------------------------
section("Login, silence, first reports")
--------------------------------------------------------------------------------

A.login()
B.login()
D.login()
advance(100)

local a = A.db()
check("build captured", a.client and a.client.build == "70790")
check("honor sentences found", a.strings and a.strings.COMBATLOG_HONORGAIN ~= nil)
check("PARTY_KILL registered", a.events and a.events.PARTY_KILL == true)
check("BattleTag readable", a.me.bnet == "ok", a.me.bnet)
check("only a hash of the BattleTag is kept", a.me.bnetHash == Fnv("KBS:Aldric#2101"), a.me.bnetHash)
check("the tag itself is nowhere in the saved data", not Serialize(a):find("Aldric#2101", 1, true))
check("guild roster captured", a.guild and a.guild.name == "Savages" and a.guild.members == 5)
check("B and D hold A's report", B.db().reports[A.key] ~= nil and D.db().reports[A.key] ~= nil)
check("A holds B's and D's reports", a.reports[B.key] ~= nil and a.reports[D.key] ~= nil)
local pingFromB = false
for _, entry in ipairs(A.log("comms")) do
	if entry.dir == "in" and entry.kind == "ping" and not entry.mine and entry.sender == B.state.name then pingFromB = true end
end
check("A received B's login ping", pingFromB)
check("the key carries the surname", a.me.key == "Aldric Stormhand-Ashbringer", a.me.key)
check("own guild messages are not echoed, as on Forever", A.counter("AM.in.GUILD.world.P.self") == 0)
check("a whisper to 'First Last' reaches ourselves", A.counter("AM.whisper.space.world.received") == 1,
	A.counter("AM.whisper.space.world.received"))
check("the 'First-Last' whisper is tried too", A.counter("AM.whisper.dash.world.Success") == 1)
local logged = #A.log("restrictions")
A.fire("ADDON_RESTRICTION_STATE_CHANGED", 0, 1)
A.fire("ADDON_RESTRICTION_STATE_CHANGED", 0, 0)
check("combat flips are counted, not logged", A.counter("RS.Combat.world.Activating") == 1 and #A.log("restrictions") == logged)
check("volunteers print nothing", #B.chat == 0 and #D.chat == 0, #B.chat + #D.chat)
check("the developer sees first sightings", A.said("loaded in verbose mode"))

--------------------------------------------------------------------------------
section("World kills")
--------------------------------------------------------------------------------

A.state.target = HORDE[1].guid
A.fire("PARTY_KILL", A.guid, HORDE[1].guid)
A.fire("CHAT_MSG_COMBAT_HONOR_GAIN",
	"Gruk Bonecrusher meurt (victoire honorable : Grunt). Vous gagnez 198 points d’honneur.",
	"", "", "", "", "", 0, 0, "", 0, 77, "")
A.state.lifetime, A.state.session = A.state.lifetime + 1, A.state.session + 1
A.fire("PLAYER_PVP_KILLS_CHANGED", "player")

local kill = last(A.log("kills"))
check("own kill: role me", kill.role == "me", kill.role)
check("own kill: victim named", kill.target.name == "Gruk Bonecrusher" and kill.target.race == "Orc" and kill.target.class == "WARRIOR")
check("own kill: faction from race", kill.target.factionGuess == "Horde")
check("own kill: level and guild through the target", kill.target.level == 60 and kill.target.guild == "Blood Pact")
check("own kill: key is GUID tail and server time", kill.key == HORDE[1].guid:sub(-8) .. ":" .. kill.at, kill.key)
check("own kill: position read", kill.pos.status == "ok" and kill.pos.x == 0.6123 and kill.pos.mapID == 1424)
local honor = last(A.log("honor"))
check("honor line matched to its sentence", honor.match and honor.match.key == "COMBATLOG_HONORGAIN")
check("honor line gives the victim name", honor.match and honor.match.captures[1] == "Gruk Bonecrusher")
check("HK counter moved by one", last(A.log("hk")).lifetimeDelta == 1)

-- A and B in one party: both probes see B's kill.
A.state.group = { kind = "party", others = { { guid = B.guid, pet = B.state.pet } } }
B.state.group = { kind = "party", others = { { guid = A.guid, pet = A.state.pet } } }
A.state.groupId, B.state.groupId = "party-1", "party-1"
A.fire("PARTY_KILL", B.guid, HORDE[2].guid)
B.fire("PARTY_KILL", B.guid, HORDE[2].guid)
check("party member's kill seen as party", last(A.log("kills")).role == "party")
check("the killer's own probe says me", last(B.log("kills")).role == "me")
check("both probes give the kill the same key", last(A.log("kills")).key == last(B.log("kills")).key)
A.fire("PARTY_KILL", A.state.pet, HORDE[3].guid)
check("my pet's kill", last(A.log("kills")).role == "mypet")
A.fire("PARTY_KILL", B.state.pet, HORDE[4].guid)
check("party pet's kill", last(A.log("kills")).role == "partypet")

-- A raid of four, two subgroups.
A.state.group = { kind = "raid", members = {
	{ guid = A.guid, pet = A.state.pet, subgroup = 1 }, { guid = B.guid, pet = B.state.pet, subgroup = 1 },
	{ guid = D.guid, subgroup = 2 }, { guid = C.guid, subgroup = 2 },
} }
A.fire("PARTY_KILL", D.guid, HORDE[5].guid)
check("raid member in another group", last(A.log("kills")).role == "raid-othergroup")
A.fire("PARTY_KILL", B.guid, HORDE[6].guid)
check("raid member in my group", last(A.log("kills")).role == "raid-samegroup")
local killCount = #A.log("kills")
A.fire("PARTY_KILL", A.guid, "Creature-0-1234-0-1-2738-0000ABCD")
check("NPC kills stay out of the player kills", #A.log("kills") == killCount and #A.log("killsNpc") == 1)
A.fire("PARTY_KILL", "Player-1234-0000FFFF", HORDE[1].guid)
check("a killer outside the group", last(A.log("kills")).role == "other")
A.state.group, A.state.groupId, B.state.group, B.state.groupId = nil, nil, nil, nil

A.fire("UNIT_DIED", HORDE[3].guid)
A.fire("UNIT_DIED", "Creature-0-1234-0-1-2738-0000ABCE")
check("player deaths around us are kept", last(A.log("unitDied")).target.name == "Moro Stillwind")
check("NPC deaths are only counted", A.counter("UD.world.Creature") == 1)

--------------------------------------------------------------------------------
section("Deaths")
--------------------------------------------------------------------------------

-- The fields seen in a real Forever recap; 0x548 = a hostile player.
A.state.recap = { {
	sourceName = "Gruk Bonecrusher", sourceGUID = HORDE[1].guid, sourceFlags = 0x548,
	destName = "Aldric Stormhand", destGUID = A.guid, spellName = "Frappe mortelle", spellId = 12294,
	amount = 1450, overkill = 120, hideCaster = false, timestamp = 12345.6, event = "SPELL_DAMAGE",
} }
A.state.recapReadyAt = now + 1.2
A.fire("PLAYER_DEAD")
B.fire("PLAYER_DEAD")
advance(12)
local death = last(A.log("deaths"))
check("recap read once it arrives", death.recapStatus == "ok" and death.recap[1].sourceName == "Gruk Bonecrusher" and death.recapTries >= 2,
	tostring(death.recapStatus) .. " after " .. tostring(death.recapTries))
check("no recap is a finding too", last(B.log("deaths")).recapStatus == "none")
check("the killer is identified from the recap GUID", death.killer and death.killer.name == "Gruk Bonecrusher"
	and death.killer.race == "Orc" and death.killer.factionGuess == "Horde")
check("the recap flags say the killer is a player", death.killerIsPlayer == true and A.counter("DRK.world.Player") == 1)

--------------------------------------------------------------------------------
section("A battleground: secret inside, readable at the end")
--------------------------------------------------------------------------------

local function EnterBG(client)
	local st = client.state
	st.bucket, st.zone, st.subzone, st.mapID = "bg", "Vallée d'Alterac", "Pic de Dun Baldar", 1459
	st.secretIdentity, st.secretStats, st.secretScore, st.chatLocked = true, true, true, true
	st.restrictions.PvPMatch, st.restrictions.Chat = true, true
	st.score = {
		{ name = "Aldric Stormhand", guid = A.guid, kb = 3, hk = 21, deaths = 2, honor = 900, faction = 1, class = "HUNTER", race = "Humain" },
		{ name = "Brenna Ironvale", guid = B.guid, kb = 1, hk = 18, deaths = 4, honor = 850, faction = 1, class = "WARLOCK", race = "Nain" },
		{ name = "Edric Vale", guid = Guid(5), kb = 4, hk = 25, deaths = 1, honor = 950, faction = 1, class = "PALADIN", race = "Humain" },
		{ name = "Gruk Bonecrusher", guid = HORDE[1].guid, kb = 6, hk = 30, deaths = 5, honor = 700, faction = 0, class = "WARRIOR", race = "Orc" },
	}
	client.fire("ADDON_RESTRICTION_STATE_CHANGED", 3, 2)
	client.fire("ADDON_RESTRICTION_STATE_CHANGED", 5, 2)
	client.fire("PLAYER_ENTERING_WORLD", false, false)
	client.fire("PVP_MATCH_ACTIVE")
end

EnterBG(A)
EnterBG(B)
advance(10)
check("guild ping refused in the BG", A.counter("AM.GUILD.bg.AddOnMessageLockdown") >= 1)
check("instance chat tried in the BG", A.counter("AM.INSTANCE_CHAT.bg.AddOnMessageLockdown") >= 1)

A.fire("PARTY_KILL", SECRET, SECRET)
local bgKill = last(A.log("kills"))
check("BG kill kept as secret", bgKill.role == "secret" and bgKill.targetKind == "secret" and bgKill.target == nil)
A.fire("CHAT_MSG_COMBAT_HONOR_GAIN", SECRET, SECRET, "", "", SECRET, "", 0, 0, "", 0, 90, SECRET)
check("BG honor line kept as secret", last(A.log("honor")).secret == true)
A.state.lifetime = A.state.lifetime + 3
A.fire("PLAYER_PVP_KILLS_CHANGED", "player")
check("HK counter secret in the BG", last(A.log("hk")).secret == true)
A.fire("UNIT_DIED", SECRET)
check("secret deaths around us are counted", A.counter("UD.bg.secret") == 1)
advance(50)
check("scoreboard secret during the match (read at the start, then every 45 s)",
	A.counter("SB.during.secret") == 2 and A.counter("SB.during.ok") == 0, A.counter("SB.during.secret"))

for _, client in ipairs({ A, B }) do
	local st = client.state
	st.secretScore, st.secretIdentity = false, false
	st.restrictions.PvPMatch = false
	st.winner = 1
	client.fire("ADDON_RESTRICTION_STATE_CHANGED", 3, 0)
	client.fire("PVP_MATCH_COMPLETE", 1, 905)
end
advance(5)
local matchA = last(A.log("matches"))
check("scoreboard readable at the end", matchA.final and matchA.final.readable == 4 and matchA.final.secret == 0)
local rows = {}
for _, row in ipairs(matchA.final.rows) do rows[row.name] = row end
check("my own row is flagged", rows["Aldric Stormhand"].me == true)
check("a guildmate without the probe is recognised", rows["Edric Vale"].guildmate == true and rows["Edric Vale"].kb == 4)
check("the Horde row is not a guildmate", rows["Gruk Bonecrusher"].guildmate == nil)
check("my row read by GUID", type(matchA.mine) == "table" and matchA.mine.killingBlows == 3)

for _, client in ipairs({ A, B }) do
	local st = client.state
	st.bucket, st.zone, st.subzone, st.mapID = "world", "Contreforts de Hautebrande", "Moulin-de-Tarren", 1424
	st.secretStats, st.chatLocked = false, false
	st.restrictions.Chat = false
	client.fire("ADDON_RESTRICTION_STATE_CHANGED", 5, 0)
	client.fire("PVP_MATCH_INACTIVE")
	client.fire("PLAYER_ENTERING_WORLD", false, false)
end
-- The share after a BG waits out the two-minute gap since the login share.
advance(90)
local leftBG
for _, entry in ipairs(A.log("hk")) do
	if entry.reason == "left-bg" then leftBG = entry end
end
check("HKs earned inside show up when leaving", leftBG and leftBG.lifetimeDelta == 3, leftBG and leftBG.lifetimeDelta)
check("pings go through again after the BG", A.counter("AM.GUILD.world.Success") >= 2)
local bReport = B.db().reports[A.key]
check("B got A's report with the BG findings", bReport and bReport.data:find("PK.bg.secret.secret=1", 1, true) ~= nil)
check("the shared report names A's last killer", bReport and bReport.data:find("killer:Player Gruk Bonecrusher Orc WARRIOR Horde flagsPlayer:true", 1, true) ~= nil)
check("the shared report has the last kill and honor line", bReport and bReport.data:find("last.kill=", 1, true) ~= nil
	and bReport.data:find("last.honor=secret", 1, true) ~= nil)
check("restriction changes are logged", A.counter("RS.PvPMatch.bg.Active") == 1 and A.counter("RS.Chat.world.Inactive") == 1)

--------------------------------------------------------------------------------
section("Inspect, throttling")
--------------------------------------------------------------------------------

A.state.target = B.guid
A.slash("inspect")
advance(3)
local inspect = last(A.log("inspects"))
check("inspect reads the target's lifetime HK", inspect and inspect.data[5] == 1200 and inspect.reason == "honor-update")
check("inspect answers in chat", A.said("lifetime HK 1200"))
A.state.target = nil

A.state.throttle = 2
A.fire("PARTY_KILL", A.guid, HORDE[2].guid)
A.slash("share")
advance(90)
check("throttled sends are retried", A.counter("AM.throttled") >= 1)
check("B still gets the newest report", B.db().reports[A.key].ts == A.db().reports[A.key].ts)

--------------------------------------------------------------------------------
section("Relay to a probe that never met the author")
--------------------------------------------------------------------------------

A.logout()
local before = #network.sent
C.login()
advance(150)
local c = C.db()
check("C got A's report while A was offline", c.reports[A.key] ~= nil)
local via = c.reports[A.key] and c.reports[A.key].via
check("relayed by B or D", via == B.state.name or via == D.state.name, via)
local sends = 0
for index = before + 1, #network.sent do
	if network.sent[index].text:find("^R%^Aldric Stormhand%-Ashbringer%^%d+%^1%^") then sends = sends + 1 end
end
check("A's report sent once, not by every probe", sends == 1, sends)
check("C also got B's and D's reports", c.reports[B.key] ~= nil and c.reports[D.key] ~= nil)
check("C prints nothing", #C.chat == 0)

--------------------------------------------------------------------------------
section("Reading the results back")
--------------------------------------------------------------------------------

local file = assert(io.open(SAVED_OUT, "wb"))
file:write("KBSProbeDB = " .. Serialize(C.db()) .. "\n")
file:close()
local tool = assert(loadfile(REPORT_TOOL))
local ok, text = pcall(tool, SAVED_OUT, true)
check("the report tool runs", ok, text)
if ok then
	check("one column per probe", text:find("| Question | Aldric | Brenna | Corwin | Dalia |", 1, true) ~= nil)
	check("world kills by me are counted", text:find("| World kills: me | 2 |", 1, true) ~= nil)
	check("the shared kill is found in two probes", text:find("Aldric (party) and Brenna (me)", 1, true) ~= nil
		or text:find("Brenna (me) and Aldric (party)", 1, true) ~= nil)
	check("BG HKs seen on leaving", text:find("| HKs from a BG seen on leaving | 1 |", 1, true) ~= nil)
end

--------------------------------------------------------------------------------
section("Which kill an HK came from")
--------------------------------------------------------------------------------

-- Two probes of another guild, in one party, apart from the Savages ones.
local E = NewClient({ name = "Elwyn Thornfield", guid = Guid(6), class = "WARRIOR", guild = "Wardens", lifetime = 40 })
local G = NewClient({ name = "Gaelen Marsh", guid = Guid(7), class = "PALADIN", guild = "Wardens", lifetime = 60 })
E.state.group = { kind = "party", others = { { guid = G.guid } } }
G.state.group = { kind = "party", others = { { guid = E.guid } } }
E.state.groupId, G.state.groupId = "party-w", "party-w"
E.login()
G.login()
advance(100)

-- One HK on a client. Forever fires the event twice for it.
local function GainHK(client, amount)
	local st = client.state
	st.lifetime, st.session = st.lifetime + (amount or 1), st.session + (amount or 1)
	client.fire("PLAYER_PVP_KILLS_CHANGED", "player")
	client.fire("PLAYER_PVP_KILLS_CHANGED", "player")
end

local function Both(event, ...)
	E.fire(event, ...)
	G.fire(event, ...)
end

-- Plays a scene, lets the matching settle, and returns the counters it moved
-- on E and on G.
local function Scene(run)
	local start = {}
	for _, client in ipairs({ E, G }) do
		local copy = {}
		for key, value in pairs(client.db().counters) do copy[key] = value end
		start[client] = copy
	end
	run()
	advance(10)
	local moved = {}
	for _, client in ipairs({ E, G }) do
		local changes = {}
		for key, value in pairs(client.db().counters) do
			local change = value - (start[client][key] or 0)
			if change ~= 0 then changes[key] = change end
		end
		moved[#moved + 1] = changes
	end
	return moved[1], moved[2]
end

-- E lands the blow; both get the HK.
local e, g = Scene(function()
	Both("PARTY_KILL", E.guid, HORDE[1].guid)
	Both("UNIT_DIED", HORDE[1].guid)
	GainHK(E)
	GainHK(G)
end)
check("my killing blow and my HK are matched", e["HKM.world.kb.me"] == 1 and e["PKH.world.me.hk"] == 1)
check("a groupmate's HK goes to my blow", g["HKM.world.kb.party"] == 1 and g["PKH.world.party.hk"] == 1)
check("the victim's death is not counted again as an assist",
	e["HKM.world.assist.named"] == nil and g["HKM.world.assist.named"] == nil)

-- G lands the blow and E gets no HK, as seen in game on 2026-11-07.
e, g = Scene(function()
	Both("PARTY_KILL", G.guid, HORDE[2].guid)
	Both("UNIT_DIED", HORDE[2].guid)
	GainHK(G)
end)
check("a groupmate's blow that gave me no HK is told", e["PKH.world.party.nohk"] == 1 and e["HKM.world.kb.party"] == nil)
check("the groupmate's own probe has the HK", g["PKH.world.me.hk"] == 1)

-- An assist, as seen in game on 2026-11-07: a Horde player dies next to us,
-- the HK comes 0.24 s later, the honor line 1 s after the death, and nobody
-- in the group landed the blow.
local deathAt
e, g = Scene(function()
	E.state.nameplates = { nameplate1 = HORDE[4].guid }
	Both("UNIT_DIED", HORDE[4].guid)
	deathAt = last(E.log("unitDied")).at
	advance(0.24)
	GainHK(E)
	GainHK(G)
	advance(0.76)
	Both("CHAT_MSG_COMBAT_HONOR_GAIN", "Vous avez reçu 2 points d’honneur.", "", "", "", "", "", 0, 0, "", 0, 78, "")
end)
local assistE, assistG = last(E.log("assists")), last(G.log("assists"))
check("an HK without a killing blow names the enemy who died",
	e["HKM.world.assist.named"] == 1 and g["HKM.world.assist.named"] == 1
	and assistE.victim.name == "Sylas Mournhollow" and assistE.victim.factionGuess == "Horde")
check("... 0.24 s after the death", assistE.gap == 0.24, assistE.gap)
check("... with what the nameplate tells", assistE.victim.token == "nameplate1" and assistE.victim.level == 60)
check("... keyed on the death, the same on both probes", assistE.key == HORDE[4].guid:sub(-8) .. ":" .. deathAt
	and assistG.key == assistE.key, assistE.key)
check("... and placed on the map", assistE.pos and assistE.pos.status == "ok" and assistE.subzone == "Moulin-de-Tarren")
E.state.nameplates = nil

-- A guildmate dying at that moment is never the victim.
e = Scene(function()
	E.fire("UNIT_DIED", G.guid)
	GainHK(E)
end)
check("a friendly death is not taken for the victim", e["HKM.world.assist.unseen"] == 1 and e["HKM.world.assist.named"] == nil)

-- Two enemies die together for one HK: not guessed.
e = Scene(function()
	E.fire("UNIT_DIED", HORDE[5].guid)
	E.fire("UNIT_DIED", HORDE[6].guid)
	GainHK(E)
end)
check("one HK for two enemy deaths is left open", e["HKM.world.assist.ambiguous"] == 1)
check("... with both names kept", last(E.log("assists")).names == "Vexa Cinderhorn / Thrag Ironhide",
	last(E.log("assists")).names)

-- Two HKs at once for two enemy deaths: both named.
e = Scene(function()
	E.fire("UNIT_DIED", HORDE[5].guid)
	E.fire("UNIT_DIED", HORDE[6].guid)
	GainHK(E, 2)
end)
check("two HKs for two enemy deaths name both", e["HKM.world.assist.named"] == 2)

-- The death may come just after the HK; one seconds before it is not its victim.
e = Scene(function()
	GainHK(E)
	advance(0.3)
	E.fire("UNIT_DIED", HORDE[3].guid)
end)
check("a death just after the HK is matched", e["HKM.world.assist.named"] == 1)
e = Scene(function()
	E.fire("UNIT_DIED", HORDE[1].guid)
	advance(4)
	GainHK(E)
end)
check("a death 4 s before the HK is not its victim", e["HKM.world.assist.unseen"] == 1)

-- /kbsp mark tells the last killing blow seen: let a DoT finish a mob, mark,
-- and the answer is in the line it prints.
E.fire("PARTY_KILL", E.guid, "Creature-0-1234-0-1-2738-0000ABD0")
advance(2)
E.slash("mark dot")
local mark = last(E.log("marks"))
check("a mark records the last killing blow", mark.lastKill and mark.lastKill.role == "me"
	and mark.lastKill.ago == 2 and mark.lastKill.npc == 2738, mark.lastKill and mark.lastKill.ago)
check("... and says it", E.said("noted: dot. Last killing blow seen: me, 2 s ago (2738)."))

E.slash("share")
G.slash("share")
advance(60)
local shared = G.db().reports[E.key]
check("the shared report has the last assist", shared and shared.data:find("last.assist=", 1, true) ~= nil)
check("... the last mark with its killing blow", shared and shared.data:find("lastKB:me 2s ago Creature 2738", 1, true) ~= nil)
check("... and assist keys among the kill keys", shared and shared.data:find(":assist", 1, true) ~= nil)

local wardens = assert(io.open(WARDENS_OUT, "wb"))
wardens:write("KBSProbeDB = " .. Serialize(G.db()) .. "\n")
wardens:close()
local okTool, toolText = pcall(tool, WARDENS_OUT, true)
check("the report tool counts the assists per probe", okTool
	and toolText:find("| HKs, no killing blow seen: victim named | 4 | 1 |", 1, true) ~= nil,
	okTool and toolText:match("| HKs, no killing blow seen: victim named[^\n]*") or toolText)
check("the same assist is found in both probes", okTool and toolText:find("Elwyn (assist) and Gaelen (assist)", 1, true) ~= nil)

-- An older probe logged HKs and kills without matching them: done once at
-- the next login, from what the log still holds.
E.logout()
local oldLog, oldAt, oldT = E.saved.log, math.floor(server) - 7200, now - 7200
table.insert(oldLog.unitDied, 1, { at = oldAt, t = oldT, bucket = "world", target = { kind = "Player",
	guid = HORDE[6].guid, name = "Vexa Cinderhorn", race = "Tauren", class = "HUNTER", factionGuess = "Horde" } })
table.insert(oldLog.hk, 1, { at = oldAt, t = oldT + 0.24, reason = "PLAYER_PVP_KILLS_CHANGED", bucket = "world", lifetimeDelta = 1 })
table.insert(oldLog.kills, 1, { at = oldAt + 60, t = oldT + 60, bucket = "world", role = "party", targetKind = "Player",
	target = { kind = "Player", guid = HORDE[5].guid, name = "Thrag Ironhide", race = "Orc", class = "ROGUE", factionGuess = "Horde" } })
local namedBefore = E.saved.counters["HKM.world.assist.named"] or 0
local nohkBefore = E.saved.counters["PKH.world.party.nohk"] or 0
E.login()
advance(10)
check("an older log is matched at login", E.counter("HKM.world.assist.named") == namedBefore + 1
	and E.counter("PKH.world.party.nohk") == nohkBefore + 1 and E.log("hk")[1].match == "assist:named",
	E.log("hk")[1].match)
E.logout()
E.login()
advance(10)
check("... and only once", E.counter("HKM.world.assist.named") == namedBefore + 1 and E.counter("PKH.world.party.nohk") == nohkBefore + 1)

--------------------------------------------------------------------------------
section("Restart and slash commands")
--------------------------------------------------------------------------------

A.login()
advance(100)
check("saved data survives a restart", #A.log("kills") >= 9 and A.db().reports[C.key] ~= nil)
A.chat = {}
A.slash("")
check("summary printed", #A.chat >= 8, #A.chat)
check("summary counts world kills", A.said("World kills seen: 8 players"))
A.slash("mark raid 40 test")
check("mark stored", last(A.log("marks")).text == "raid 40 test")
A.slash("export")
local export = A.env.KBSProbeExportFrame
check("export window filled", export and export.shown and export.edit.text:find("PK.world.Player.me", 1, true) ~= nil)
A.slash("reports")
A.slash("verbose")
check("verbose toggled off", A.db().settings.verbose == false)
A.slash("reset")
check("reset clears the logs and keeps the static facts", #A.log("kills") == 0 and A.db().client ~= nil)

--------------------------------------------------------------------------------
section("Nothing went wrong anywhere")
--------------------------------------------------------------------------------

for _, client in ipairs(clients) do
	if client.online then
		local errors = client.db().log.errors
		local first = errors[1] and (tostring(errors[1].where) .. ": " .. tostring(errors[1].message))
		check(client.name .. ": no error recorded", #errors == 0, first)
		local okSave, message = pcall(Serialize, client.db())
		check(client.name .. ": SavedVariables clean", okSave, message)
	end
end
check("every hidden message fits in 255 bytes", (function()
	for _, sent in ipairs(network.sent) do
		if #sent.text > 255 then return false end
	end
	return true
end)())
check("volunteers stayed silent all along", #B.chat == 0 and #C.chat == 0 and #D.chat == 0)

print("")
print(("%d checks, %d failed"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
