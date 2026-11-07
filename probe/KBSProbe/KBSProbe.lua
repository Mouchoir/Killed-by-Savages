local ADDON_NAME = ...

--------------------------------------------------------------------------------
-- Killed by Savages - probe
--
-- A throwaway dev tool. The guild addon will count Horde kills per player,
-- per character and for the whole guild, split between battlegrounds and
-- world PvP. On Forever the combat log is closed to addons, so before writing
-- that addon we need answers only the live client can give:
--
--   * PARTY_KILL: readable in the world, secret in battlegrounds? Does it fire
--     for pets, and for raid members outside our own subgroup?
--   * The honor line (CHAT_MSG_COMBAT_HONOR_GAIN): its exact text in each
--     client language, and whether it turns secret in battlegrounds.
--   * The server HK counters (GetPVPSessionStats, GetPVPLifetimeStats): do
--     they move inside a battleground, and can we read them there?
--   * The battleground scoreboard: secret during the match, readable once it
--     is over?
--   * Hidden addon messages: delivered between players, refused in
--     battlegrounds?
--   * The death recap: can we tell who killed us?
--   * Our own map position, for the heatmap.
--   * Name formats (roster, scoreboard, GetPlayerInfoByGUID, senders), and
--     whether the BattleTag is readable to group alts. Only a hash of it is
--     ever kept, never the tag.
--   * Kill keys (victim GUID + server time) from several probes in one group,
--     to check that the same kill gets the same key everywhere.
--   * Each HK matched with what was seen around it: a killing blow by our
--     group, or else an enemy player dying near us, which names the victim of
--     an assist (or of a DoT kill, if those fire no PARTY_KILL: /kbsp mark
--     after letting a DoT finish a mob tells which). And the reverse: does a
--     killing blow by our group always give us the HK?
--
-- Everything goes to KBSProbeDB, which the game writes on /reload or logout.
-- Each probe also shares a compact report with the other probes of the guild
-- over a hidden addon channel, and relays the reports of probes that are
-- offline, so a single SavedVariables file ends up holding everybody's
-- answers.
--
-- It is silent: nothing is printed unless a slash command asks for it, or
-- /kbsp verbose was turned on (meant for the developer, not the volunteers).
--------------------------------------------------------------------------------

local VERSION = "0.1.3"
local PREFIX = "KBSProbe"
local SECRET = "<secret>"

-- Ring sizes. A busy evening stays at a few hundred KB of SavedVariables.
local CAP = {
	kills = 400, killsNpc = 60, unitDied = 300, honor = 400, hk = 300, deaths = 100,
	matches = 30, restrictions = 200, comms = 150, inspects = 30, marks = 100,
	errors = 50, zones = 200, assists = 200,
}

local REPORT_CHUNK = 190     -- bytes of report per hidden message (limit is 255)
local REPORT_MAX = 4000
local SEND_GAP = 1.1         -- seconds between two hidden messages
local SHARE_MIN_GAP = 120    -- never re-share our report more often than this
local SHARE_TICK = 600       -- look for a changed report this often
local MATCH_WINDOW = 2       -- seconds between an enemy's death and the HK it gave
local MATCH_DELAY = 3        -- an HK is matched this long after it, once all is in

local db
local announced = {}
local registration = {}
local prefixResult
local me = {}
local roster = {}
local rosterAt = 0
local honorPatterns = {}
local match
local lastBucket
local lastHK
local pendingInspect

-- Defined further down, used by handlers above them.
local Ping, ShareOwn, SendHello, MatchHK, MatchKill

--------------------------------------------------------------------------------
-- Safe access
--
-- On Forever an API can hand back a "secret" value: an addon can pass it
-- around but not read, compare or print it, and trying raises an error. Every
-- value is turned into something plain before it is kept or looked at, and
-- every call goes through pcall, so a refusal is a finding, not a crash.
--------------------------------------------------------------------------------

local function Fn(value)
	return type(value) == "function" and value or nil
end

local isSecret = Fn(issecretvalue) or function() return false end
local isSecretTable = Fn(issecrettable) or function() return false end

local function Safe(value)
	if isSecret(value) then return SECRET end
	local kind = type(value)
	if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
		return value
	end
	return "<" .. kind .. ">"
end

local function SafeAll(ok, ...)
	if not ok then return nil end
	local count = select("#", ...)
	local values = {}
	for index = 1, count do
		values[index] = Safe((select(index, ...)))
	end
	return unpack(values, 1, count)
end

-- Every value a call returns, made safe. Nothing when the API is missing or
-- the call failed.
local function Get(fn, ...)
	if not Fn(fn) then return nil end
	return SafeAll(pcall(fn, ...))
end

local function Pack(ok, ...)
	local out = { n = select("#", ...) }
	if not ok then
		out.n = 0
		out.error = Safe((...))
		return out
	end
	for index = 1, out.n do
		out[index] = Safe((select(index, ...)))
	end
	return out
end

-- Like Get, but keeps every return in a table, and the error of a failed
-- call: what an API answers is itself a finding.
local function Call(fn, ...)
	if not Fn(fn) then return { missing = true } end
	return Pack(pcall(fn, ...))
end

-- A readable copy of a table: secrets become the marker, depth is bounded.
local function Dump(value, depth)
	if isSecret(value) then return SECRET end
	if type(value) ~= "table" then return Safe(value) end
	if isSecretTable(value) then return "<secret table>" end
	depth = depth or 2
	if depth <= 0 then return "<table>" end
	local out = {}
	local ok = pcall(function()
		for key, item in pairs(value) do
			local plainKey = Safe(key)
			if type(plainKey) ~= "string" and type(plainKey) ~= "number" then
				plainKey = tostring(plainKey)
			end
			out[plainKey] = Dump(item, depth - 1)
		end
	end)
	if not ok then out["<dump failed>"] = true end
	return out
end

local function Round(number, places)
	local scale = 10 ^ (places or 4)
	return math.floor(number * scale + 0.5) / scale
end

local function Now()
	local value = Get(GetServerTime)
	if type(value) == "number" then return value end
	return Fn(time) and time() or 0
end

local function Clock()
	local value = Get(GetTime)
	return type(value) == "number" and value or 0
end

local function Stamp(at)
	local format = Fn(date)
	return format and format("%Y-%m-%d %H:%M", at) or tostring(at)
end

--------------------------------------------------------------------------------
-- Text helpers
--------------------------------------------------------------------------------

-- At most max bytes, never splitting a UTF-8 character in two.
local function Cut(text, max)
	if #text <= max then return text, "" end
	local stop = max
	while stop > 1 do
		local byte = text:byte(stop + 1)
		if byte and byte >= 0x80 and byte < 0xC0 then
			stop = stop - 1
		else
			break
		end
	end
	return text:sub(1, stop), text:sub(stop + 1)
end

-- Report fields travel as key=value;key=value inside messages that use ^ and
-- commas as separators, so those characters and UI escapes are flattened.
local function Clean(value)
	return (tostring(value):gsub("[;=%^|,\r\n]", " "))
end

-- Forever names are a first name and a surname. The client spells them
-- "First Last" in the roster and GetPlayerInfoByGUID, keeps them apart in
-- UnitName, and "First-Last" in WTF folders; a realm suffix may also follow.
-- Canon brings any of these to one comparable form.
local function Canon(name)
	if type(name) ~= "string" or name == SECRET or name == "" then return nil end
	for _, realm in ipairs({ me.realm, me.realmName }) do
		if type(realm) == "string" and realm ~= "" then
			local suffix = "-" .. realm
			if #name > #suffix and name:sub(-#suffix) == suffix then
				name = name:sub(1, -#suffix - 1)
			end
		end
	end
	return (name:gsub("%-", " "):lower())
end

-- FNV-1a, 32 bits, in plain arithmetic so it needs no bit library. Used to
-- recognise a BattleTag without ever keeping or sending the tag itself.
local function Xor8(a, b)
	local result, value = 0, 1
	for _ = 1, 8 do
		local bitA, bitB = a % 2, b % 2
		if bitA ~= bitB then result = result + value end
		a, b, value = (a - bitA) / 2, (b - bitB) / 2, value * 2
	end
	return result
end

local function Hash(text)
	local hash = 2166136261
	for index = 1, #text do
		local low = hash % 256
		hash = hash - low + Xor8(low, text:byte(index))
		-- hash * 16777619 mod 2^32, with 16777619 = 2^24 + 403, kept exact.
		hash = ((hash % 256) * 16777216 + hash * 403) % 4294967296
	end
	return ("%04x%04x"):format(math.floor(hash / 65536), hash % 65536)
end

--------------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------------

local function InitDB()
	if type(KBSProbeDB) ~= "table" then KBSProbeDB = {} end
	db = KBSProbeDB
	db.schema = 1
	db.settings = db.settings or {}
	db.log = db.log or {}
	for name in pairs(CAP) do
		db.log[name] = db.log[name] or {}
	end
	db.counters = db.counters or {}
	db.examples = db.examples or {}
	db.reports = db.reports or {}
	db.sessions = db.sessions or {}
	return db
end

local function Push(listName, entry)
	if not db then InitDB() end
	local list = db.log[listName]
	list[#list + 1] = entry
	local cap = CAP[listName] or 100
	while #list > cap do
		table.remove(list, 1)
	end
	return entry
end

local function Count(key, amount)
	if not db then InitDB() end
	key = Clean(key)
	db.counters[key] = (db.counters[key] or 0) + (amount or 1)
end

-- The first few distinct examples of something: they show formats.
local function Example(name, value, keep)
	if value == nil then return end
	if not db then InitDB() end
	local list = db.examples[name] or {}
	db.examples[name] = list
	for _, known in ipairs(list) do
		if known == value then return end
	end
	if #list < (keep or 3) then
		list[#list + 1] = value
	end
end

--------------------------------------------------------------------------------
-- Output and errors
--------------------------------------------------------------------------------

local function Print(text)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffc41f3bKbS probe|r: " .. tostring(text))
	end
end

local function Verbose()
	return db and db.settings and db.settings.verbose
end

-- The first sighting of something, told once per session and only in
-- verbose mode. Volunteers never see a line from the probe.
local function Announce(key, text)
	if announced[key] then return end
	announced[key] = true
	if Verbose() then Print(text) end
end

local function RecordError(where, message)
	Count("ERR.total")
	Push("errors", { at = Now(), where = where, message = Safe(message) })
	if Verbose() then
		Print("error in " .. tostring(where) .. ": " .. tostring(Safe(message)))
	end
end

-- Every handler runs through here: a failure is recorded, never shown to a
-- volunteer, and never stops the next event from being handled.
local function Guard(where, fn, ...)
	if not Fn(fn) then return end
	local ok, message = pcall(fn, ...)
	if not ok then pcall(RecordError, where, message) end
end

local function After(delay, where, fn, a, b)
	if not (C_Timer and Fn(C_Timer.After)) then return end
	C_Timer.After(delay, function() Guard(where, fn, a, b) end)
end

local function Every(interval, where, fn, a)
	local function tick()
		Guard(where, fn, a)
		After(interval, where, tick)
	end
	After(interval, where, tick)
end

--------------------------------------------------------------------------------
-- Where we are
--------------------------------------------------------------------------------

local function EnumName(enumTable, value)
	if type(enumTable) == "table" then
		for name, known in pairs(enumTable) do
			if known == value then return name end
		end
	end
	return tostring(value)
end

local function Restrictions()
	local api = C_RestrictedActions
	local types = Enum and Enum.AddOnRestrictionType
	if not (api and Fn(api.IsAddOnRestrictionActive) and type(types) == "table") then return nil end
	local out = {}
	for name, value in pairs(types) do
		local active = Get(api.IsAddOnRestrictionActive, value)
		if active == nil then active = "err" end
		out[name] = active
	end
	return out
end

-- The three buckets the guild addon will use, plus the odd cases.
local function Bucket()
	local _, instanceType = Get(IsInInstance)
	if instanceType == "pvp" then return "bg" end
	if instanceType == "arena" then return "arena" end
	if instanceType == nil or instanceType == "none" then return "world" end
	if instanceType == SECRET then return "unknown" end
	return "instance"
end

local function Context()
	local context = { bucket = Bucket() }
	context.inInstance, context.instanceType = Get(IsInInstance)
	local instanceName, _, difficultyID, _, maxPlayers, _, _, instanceID = Get(GetInstanceInfo)
	context.instanceName, context.difficultyID = instanceName, difficultyID
	context.maxPlayers, context.instanceID = maxPlayers, instanceID
	context.zone = Get(GetRealZoneText)
	context.subzone = Get(GetSubZoneText)
	if C_PvP then
		context.isBattleground = Get(C_PvP.IsBattleground)
		context.matchState = Get(C_PvP.GetActiveMatchState)
	end
	if Get(IsInRaid) == true then
		context.group = "raid"
	elseif Get(IsInGroup) == true then
		context.group = "party"
	else
		context.group = "solo"
	end
	context.groupSize = Get(GetNumGroupMembers)
	context.pvpFlag = Get(UnitIsPVP, "player")
	if C_ChatInfo then
		context.chatLockdown = Get(C_ChatInfo.InChatMessagingLockdown)
	end
	context.restrictions = Restrictions()
	if C_Secrets then
		context.identitySecret = Get(C_Secrets.ShouldUnitIdentityBeSecret, "target")
	end
	return context
end

-- Our own position on the zone map: where a kill happened, give or take the
-- distance to the victim. Status tells whether the client let us read it.
local function Position()
	local position = {}
	if not (C_Map and Fn(C_Map.GetBestMapForUnit) and Fn(C_Map.GetPlayerMapPosition)) then
		position.status = "missing"
		return position
	end
	local okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player")
	if not okMap then
		position.status = "error"
		position.error = Safe(mapID)
		return position
	end
	if isSecret(mapID) then
		position.status = "secret"
		return position
	end
	position.mapID = mapID
	if type(mapID) ~= "number" then
		position.status = "nomap"
		return position
	end
	local okInfo, info = pcall(C_Map.GetMapInfo, mapID)
	if okInfo and not isSecret(info) and type(info) == "table" and not isSecretTable(info) then
		position.mapName = Safe(info.name)
	end
	local okPos, vector = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
	if not okPos then
		position.status = "error"
		position.error = Safe(vector)
	elseif isSecret(vector) then
		position.status = "secret"
	elseif type(vector) ~= "table" then
		position.status = "nil"
	else
		local x, y
		if Fn(vector.GetXY) then
			x, y = Get(vector.GetXY, vector)
		else
			x, y = Safe(vector.x), Safe(vector.y)
		end
		if x == SECRET or y == SECRET then
			position.status = "secret"
		elseif type(x) == "number" and type(y) == "number" then
			position.status = "ok"
			position.x, position.y = Round(x, 4), Round(y, 4)
		else
			position.status = "nil"
		end
	end
	return position
end

--------------------------------------------------------------------------------
-- Who is who
--------------------------------------------------------------------------------

local function PlainGuid(unit)
	if not Fn(UnitGUID) then return nil end
	local ok, guid = pcall(UnitGUID, unit)
	if not ok or isSecret(guid) or type(guid) ~= "string" then return nil end
	return guid
end

local function RefreshMe()
	me.guid = PlainGuid("player")
	-- On Forever UnitName returns the first name and the surname, not a realm.
	local first, surname = Get(UnitName, "player")
	local hasSurname = type(surname) == "string" and surname ~= "" and surname ~= SECRET
	local full = Get(GetUnitName, "player", true)
	if type(full) ~= "string" or full == "" or full == SECRET then
		full = hasSurname and (tostring(first) .. " " .. surname) or first
	end
	me.name = full
	me.dashName = hasSurname and (tostring(first) .. "-" .. surname) or nil
	me.realm = Get(GetNormalizedRealmName) or Get(GetRealmName)
	me.realmName = Get(GetRealmName)
	me.key = Clean(tostring(me.name) .. "-" .. tostring(me.realm))
end

local function IsMe(name, guid)
	if guid ~= nil and guid ~= SECRET and me.guid ~= nil and guid == me.guid then return true end
	local canon = Canon(name)
	return canon ~= nil and canon == Canon(me.name)
end

-- Who landed a killing blow, seen from here. The raid part is what tells
-- whether PARTY_KILL also covers raid members outside our subgroup.
local function RoleOf(guid)
	local myGuid = PlainGuid("player")
	if guid == myGuid then return "me" end
	if guid == PlainGuid("pet") then return "mypet" end
	if Get(IsInRaid) == true then
		local count = Get(GetNumGroupMembers)
		if type(count) ~= "number" then count = 0 end
		local mySubgroup, theirSubgroup, petSubgroup
		for index = 1, count do
			local _, _, subgroup = Get(GetRaidRosterInfo, index)
			local unitGuid = PlainGuid("raid" .. index)
			if unitGuid and unitGuid == myGuid then mySubgroup = subgroup end
			if unitGuid and unitGuid == guid then theirSubgroup = subgroup end
			local petGuid = PlainGuid("raidpet" .. index)
			if petGuid and petGuid == guid then petSubgroup = subgroup end
		end
		if theirSubgroup ~= nil then
			return theirSubgroup == mySubgroup and "raid-samegroup" or "raid-othergroup"
		end
		if petSubgroup ~= nil then
			return petSubgroup == mySubgroup and "raidpet-samegroup" or "raidpet-othergroup"
		end
		return "other"
	end
	for index = 1, 4 do
		if guid == PlainGuid("party" .. index) then return "party" end
		if guid == PlainGuid("partypet" .. index) then return "partypet" end
	end
	return "other"
end

local RACE_FACTION = {
	Human = "Alliance", Dwarf = "Alliance", NightElf = "Alliance", Gnome = "Alliance",
	Draenei = "Alliance", Worgen = "Alliance",
	Orc = "Horde", Scourge = "Horde", Tauren = "Horde", Troll = "Horde",
	BloodElf = "Horde", Goblin = "Horde",
}

-- What the client tells about a GUID we are allowed to read. quiet keeps it
-- out of the victim name examples (a killer is not a victim).
local function GuidFacts(guid, quiet)
	local facts = { kind = guid:match("^(%a+)") or "?" }
	if facts.kind ~= "Player" then return facts end
	facts.guid = guid
	local _, class, _, race, _, name, realm = Get(GetPlayerInfoByGUID, guid)
	facts.class, facts.race, facts.name, facts.realm = class, race, name, realm
	facts.factionGuess = type(race) == "string" and RACE_FACTION[race] or nil
	local token = Get(UnitTokenFromGUID, guid)
	if type(token) == "string" and token ~= SECRET then
		facts.token = token
		facts.level = Get(UnitLevel, token)
		facts.faction = Get(UnitFactionGroup, token)
		facts.guild = Get(GetGuildInfo, token)
	end
	if not quiet and type(name) == "string" and name ~= SECRET then
		Example("victimName", name .. " / " .. tostring(realm), 3)
	end
	return facts
end

-- COMBATLOG_OBJECT_TYPE_PLAYER is bit 0x400 of the unit flags.
local function FlagsSayPlayer(flags)
	if type(flags) ~= "number" then return nil end
	return math.floor(flags / 1024) % 2 == 1
end

-- One line for a unit in the shared report, e.g. "Player Ralf Sj Orc ROGUE Horde".
local function Describe(facts, fallbackName)
	if type(facts) ~= "table" then
		return fallbackName ~= nil and tostring(fallbackName) or nil
	end
	if facts.kind ~= "Player" then
		return tostring(facts.kind) .. " " .. tostring(fallbackName or "")
	end
	return ("Player %s %s %s %s"):format(tostring(facts.name), tostring(facts.race), tostring(facts.class),
		tostring(facts.factionGuess or facts.faction))
end

--------------------------------------------------------------------------------
-- Guild roster
--------------------------------------------------------------------------------

local function RequestRoster()
	if C_GuildInfo and Fn(C_GuildInfo.GuildRoster) then
		pcall(C_GuildInfo.GuildRoster)
	elseif Fn(GuildRoster) then
		pcall(GuildRoster)
	end
end

local function OnRoster()
	if not db or Now() - rosterAt < 30 then return end
	local count = Get(GetNumGuildMembers)
	if type(count) ~= "number" or count <= 0 then return end
	rosterAt = Now()
	local set = {}
	for index = 1, count do
		local canon = Canon((Get(GetGuildRosterInfo, index)))
		if canon then set[canon] = true end
	end
	roster = set
	if not db.guild or not db.guild.capturedAt or Now() - db.guild.capturedAt > 3600 then
		local sample = {}
		for index = 1, math.min(3, count) do
			local values = Call(GetGuildRosterInfo, index)
			sample[index] = {
				returns = values.n, name = values[1], rankIndex = values[3], level = values[4],
				class = values[11], guid = values[17],
			}
			if index == 1 then Example("rosterName", values[1], 1) end
		end
		db.guild = { name = Get(GetGuildInfo, "player"), members = count, sample = sample, capturedAt = Now() }
	end
end

--------------------------------------------------------------------------------
-- The honor line
--
-- The client holds the honor sentences as printf-style globals. Turning them
-- into patterns tells which sentence a line is and pulls the victim name out,
-- whatever the client language.
--------------------------------------------------------------------------------

local MAGIC = "[%^%$%(%)%.%[%]%*%+%-%?]"

local function FormatToPattern(format)
	local out, index, length = { "^" }, 1, #format
	while index <= length do
		local char = format:sub(index, index)
		if char == "%" then
			local spec = format:match("^%%(%d*%$?[-+ #0]*%d*%.?%d*[sdifgu])", index)
			if spec then
				out[#out + 1] = "(.-)"
				index = index + 1 + #spec
			else
				out[#out + 1] = "%%"
				index = index + ((format:sub(index + 1, index + 1) == "%") and 2 or 1)
			end
		else
			out[#out + 1] = char:find(MAGIC) and ("%" .. char) or char
			index = index + 1
		end
	end
	out[#out + 1] = "$"
	return table.concat(out)
end

local function CaptureStrings()
	local found = {}
	for key, value in pairs(_G) do
		if type(key) == "string" and type(value) == "string"
			and (key:find("^COMBATLOG_HONOR") or key:find("^COMBATLOG_DISHONOR")) then
			found[key] = value
		end
	end
	db.strings = found
	local patterns = {}
	for key, format in pairs(found) do
		patterns[#patterns + 1] = { key = key, pattern = FormatToPattern(format), length = #format }
	end
	-- Longest first, so a specific sentence wins over a shorter, looser one.
	table.sort(patterns, function(a, b)
		if a.length ~= b.length then return a.length > b.length end
		return a.key < b.key
	end)
	honorPatterns = patterns
end

local function MatchHonor(text)
	for _, entry in ipairs(honorPatterns) do
		local captures = { text:match(entry.pattern) }
		if captures[1] ~= nil then
			return { key = entry.key, captures = captures }
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- The server HK counters
--------------------------------------------------------------------------------

local function SnapshotHK(reason)
	if not db then return nil end
	local bucket = Bucket()
	local entry = {
		at = Now(), t = Clock(), reason = reason, bucket = bucket,
		session = Call(GetPVPSessionStats),
		lifetime = Call(GetPVPLifetimeStats),
		yesterday = Call(GetPVPYesterdayStats),
	}
	local lifetime, session = entry.lifetime[1], entry.session[1]
	entry.secret = lifetime == SECRET or session == SECRET
	-- Deltas run from the last value we could read, so leaving a battleground
	-- tells how many HKs it gave even if the counter was secret inside.
	if lastHK and type(lifetime) == "number" and type(lastHK.lifetime) == "number" then
		entry.lifetimeDelta = lifetime - lastHK.lifetime
	end
	if lastHK and type(session) == "number" and type(lastHK.session) == "number" then
		entry.sessionDelta = session - lastHK.session
	end
	lastHK = {
		lifetime = type(lifetime) == "number" and lifetime or (lastHK and lastHK.lifetime),
		session = type(session) == "number" and session or (lastHK and lastHK.session),
	}
	Push("hk", entry)
	-- A live HK is matched with the kill it came from once the events around
	-- it are in. The batch counted when leaving a battleground is not.
	if reason == "PLAYER_PVP_KILLS_CHANGED" and entry.lifetimeDelta and entry.lifetimeDelta > 0 then
		entry.pos = Position()
		entry.zone, entry.subzone = Get(GetRealZoneText), Get(GetSubZoneText)
		After(MATCH_DELAY, "hk-match", MatchHK, entry)
	end
	local source = reason == "PLAYER_PVP_KILLS_CHANGED" and "event" or "poll"
	Count(("HK.%s.%s.%s"):format(source, bucket, entry.secret and "secret" or "ok"))
	if entry.lifetimeDelta then
		local moved = entry.lifetimeDelta > 0 and "moved" or "still"
		Count(("HKD.%s.%s"):format(bucket, moved))
		if reason == "left-bg" then Count("HKD.leftbg." .. moved) end
	end
	local returns = {}
	for index = 1, (entry.lifetime.n or 0) do
		returns[index] = tostring(entry.lifetime[index])
	end
	Example("lifetimeReturns", table.concat(returns, " "), 1)
	return entry
end

--------------------------------------------------------------------------------
-- Kills, honor lines, deaths around us
--------------------------------------------------------------------------------

local function OnPartyKill(attackerGuid, targetGuid)
	local bucket = Bucket()
	local attackerSecret, targetSecret = isSecret(attackerGuid), isSecret(targetGuid)
	local targetKind, role
	if targetSecret then
		targetKind = "secret"
	elseif type(targetGuid) == "string" then
		targetKind = targetGuid:match("^(%a+)") or "?"
	else
		targetKind = "nil"
	end
	if attackerSecret then
		role = "secret"
	elseif type(attackerGuid) == "string" then
		role = RoleOf(attackerGuid)
	else
		role = "nil"
	end
	Count(("PK.%s.%s.%s"):format(bucket, targetKind, role))

	local entry = {
		at = Now(), t = Clock(), bucket = bucket, role = role, targetKind = targetKind,
		attackerSecret = attackerSecret, targetSecret = targetSecret,
	}
	if targetKind ~= "Player" and targetKind ~= "secret" then
		-- Which mob, so a test on one (like letting a DoT finish it) reads back.
		if type(targetGuid) == "string" then
			entry.npc = tonumber(targetGuid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)%-"))
			local token = Get(UnitTokenFromGUID, targetGuid)
			if type(token) == "string" and token ~= SECRET then
				local name = Get(UnitName, token)
				if type(name) == "string" and name ~= SECRET then entry.targetName = name end
			end
		end
		Push("killsNpc", entry)
		Announce("PKNPC." .. role, ("NPC kill seen: attacker %s"):format(role))
		return
	end

	if targetKind == "Player" then
		entry.target = GuidFacts(targetGuid)
		-- The key the guild addon would use to count a kill once: victim GUID
		-- plus server time. Several probes in one group should agree on it.
		entry.key = targetGuid:sub(-8) .. ":" .. tostring(entry.at)
	end
	entry.context = Context()
	entry.pos = Position()
	Count(("POS.kill.%s.%s"):format(bucket, entry.pos.status))
	Push("kills", entry)
	if targetKind == "Player" then
		After(MATCH_DELAY + MATCH_WINDOW + 1, "kill-hk", MatchKill, entry)
	end

	local victim = targetKind
	if entry.target then
		victim = ("%s (%s %s)"):format(tostring(entry.target.name), tostring(entry.target.race), tostring(entry.target.class))
	end
	Announce("PK." .. bucket .. "." .. targetKind .. "." .. role,
		("kill seen in %s: attacker %s, victim %s"):format(bucket, role, victim))
end

local function OnHonorGain(...)
	local text = (...)
	local playerName, playerName2, guid = (select(2, ...)), (select(5, ...)), (select(12, ...))
	local bucket = Bucket()
	local secret = isSecret(text)
	local entry = {
		at = Now(), t = Clock(), bucket = bucket, secret = secret,
		playerName = Safe(playerName), playerName2 = Safe(playerName2), guid = Safe(guid),
		zone = Get(GetRealZoneText), subzone = Get(GetSubZoneText),
	}
	if not secret and type(text) == "string" then
		entry.text = text
		entry.match = MatchHonor(text)
		local key = entry.match and entry.match.key or "nomatch"
		Example("honorText", text, 3)
		Example("honorKey", key, 3)
		Count("HGM." .. key)
	end
	Count(("HG.%s.%s"):format(bucket, secret and "secret" or "ok"))
	Push("honor", entry)
	Announce("HG." .. bucket .. "." .. tostring(secret),
		secret and ("honor line in " .. bucket .. ": secret")
		or ("honor line in " .. bucket .. ": " .. tostring(entry.text)))
end

local function OnUnitDied(guid)
	local bucket = Bucket()
	if isSecret(guid) then
		Count("UD." .. bucket .. ".secret")
		return
	end
	local kind = type(guid) == "string" and (guid:match("^(%a+)") or "?") or "nil"
	Count(("UD.%s.%s"):format(bucket, kind))
	if kind == "Player" then
		Push("unitDied", {
			at = Now(), t = Clock(), bucket = bucket, target = GuidFacts(guid),
			zone = Get(GetRealZoneText), subzone = Get(GetSubZoneText),
		})
	end
end

--------------------------------------------------------------------------------
-- Which kill an HK came from
--
-- The server counts an HK for each enemy we helped kill, killing blow or not.
-- A few seconds after the counter moves, the HK is matched with what was seen
-- around that moment: a killing blow by us or our group (PARTY_KILL), or else
-- an enemy player who died near us. The second case is called an assist here;
-- it would also cover a kill by one of our DoTs if those fire no PARTY_KILL.
--------------------------------------------------------------------------------

local function Copy(source)
	if type(source) ~= "table" then return nil end
	local out = {}
	for key, value in pairs(source) do
		if type(value) ~= "table" then out[key] = value end
	end
	return out
end

-- The entries of a log ring close in time to an event, newest first, that
-- keep() accepts. keep() only ever sees entries inside the window.
local function Around(listName, event, keep)
	local found = {}
	local list = db.log[listName]
	for index = #list, 1, -1 do
		local item = list[index]
		if type(item.at) == "number" and item.at < event.at - 10 then break end
		if type(item.t) == "number" and math.abs(item.t - event.t) <= MATCH_WINDOW
			and type(item.at) == "number" and math.abs(item.at - event.at) <= MATCH_WINDOW + 2
			and keep(item) then
			found[#found + 1] = item
		end
	end
	return found
end

-- Our own killing blows first, then our pet's, then the group's.
local function RoleRank(role)
	if role == "me" then return 1 end
	if role == "mypet" then return 2 end
	if type(role) == "string" and (role:find("^party") or role:find("^raid")) then return 3 end
	return 4
end

-- A player death our HK may come from: anyone not of our side. A race both
-- factions can play shows no faction without a unit token; such a death
-- stays a candidate, since only enemies give HKs.
local function MaybeEnemy(death, faction)
	local target = death.target
	if type(target) ~= "table" or target.kind ~= "Player" or target.guid == nil then return false end
	if target.guid == me.guid then return false end
	local theirs = target.faction
	if theirs == nil or theirs == SECRET then theirs = target.factionGuess end
	return theirs == nil or theirs ~= faction
end

MatchHK = function(hk)
	if not db then return end
	local count = math.min(hk.lifetimeDelta or 0, 5)
	if count <= 0 then return end
	local results = {}
	local killed = {}
	local kills = Around("kills", hk, function(kill)
		if type(kill.target) == "table" and kill.target.guid then killed[kill.target.guid] = true end
		return not kill.hkMatched
	end)
	table.sort(kills, function(a, b)
		local rankA, rankB = RoleRank(a.role), RoleRank(b.role)
		if rankA ~= rankB then return rankA < rankB end
		return math.abs(a.t - hk.t) < math.abs(b.t - hk.t)
	end)
	for index = 1, math.min(count, #kills) do
		local kill = kills[index]
		kill.hkMatched = true
		results[#results + 1] = "kb:" .. tostring(kill.role)
		Count(("HKM.%s.kb.%s"):format(hk.bucket, tostring(kill.role)))
	end

	local left = count - #results
	if left <= 0 then
		hk.match = table.concat(results, " ")
		return
	end
	-- No blow of ours for the rest: enemies who died around that moment,
	-- leaving out those a killing blow already explains.
	local faction = Get(UnitFactionGroup, "player")
	local deaths = Around("unitDied", hk, function(death)
		return not death.hkMatched and MaybeEnemy(death, faction) and not killed[death.target.guid]
	end)
	local assists = {}
	if #deaths > left then
		-- More enemies died than HKs came: not guessed.
		local names, gaps = {}, {}
		for index = 1, math.min(3, #deaths) do
			names[index] = tostring(deaths[index].target.name)
			gaps[index] = tostring(Round(hk.t - deaths[index].t, 2))
		end
		for _ = 1, left do
			assists[#assists + 1] = {
				how = "ambiguous", candidates = #deaths,
				names = table.concat(names, " / "), gaps = table.concat(gaps, " / "),
			}
		end
	else
		for _, death in ipairs(deaths) do
			death.hkMatched = true
			assists[#assists + 1] = { how = "named", death = death }
		end
		for _ = #deaths + 1, left do
			assists[#assists + 1] = { how = "unseen" }
		end
	end

	for _, assist in ipairs(assists) do
		local record = {
			at = hk.at, t = hk.t, bucket = hk.bucket, how = assist.how,
			pos = Copy(hk.pos), zone = hk.zone, subzone = hk.subzone,
			candidates = assist.candidates, names = assist.names, gaps = assist.gaps,
		}
		local death = assist.death
		if death then
			record.victim = Copy(death.target)
			record.gap = Round(hk.t - death.t, 2)
			-- Keyed like a kill, on the death, so probes can compare.
			record.key = death.target.guid:sub(-8) .. ":" .. tostring(death.at)
		end
		Push("assists", record)
		results[#results + 1] = "assist:" .. assist.how
		Count(("HKM.%s.assist.%s"):format(hk.bucket, assist.how))
		Announce("HKM.assist." .. assist.how, ("HK without a killing blow in the group (%s): %s"):format(
			assist.how, tostring(record.victim and record.victim.name or record.names)))
	end
	hk.match = table.concat(results, " ")
end

-- Did a killing blow by us or our group give us the HK? Looked at once the
-- HKs around it were matched.
MatchKill = function(kill)
	if not db then return end
	local state = kill.hkMatched and "hk" or "nohk"
	if state == "nohk" and #Around("hk", kill, function(hk) return hk.secret == true end) > 0 then
		state = "secret"
	end
	kill.hk = state
	Count(("PKH.%s.%s.%s"):format(kill.bucket, tostring(kill.role), state))
end

-- The time from which a log ring still holds everything: its first entry
-- once it is full and drops old ones, else since ever.
local function KeptSince(listName)
	local list = db.log[listName]
	if #list < (CAP[listName] or 100) or not list[1] then return 0 end
	return list[1].at or 0
end

-- Probes before 0.1.3 logged HKs and kills without matching them. Done once
-- at login for what the log still holds, so the first report of a new
-- version already answers for the fights before it.
local function MatchPast()
	if not db then return end
	local since = math.max(KeptSince("kills"), KeptSince("unitDied"))
	for _, hk in ipairs(db.log.hk) do
		if hk.match == nil and hk.reason == "PLAYER_PVP_KILLS_CHANGED" and type(hk.lifetimeDelta) == "number"
			and hk.lifetimeDelta > 0 and type(hk.t) == "number" and type(hk.at) == "number" and hk.at >= since then
			MatchHK(hk)
		end
	end
	since = KeptSince("hk")
	for _, kill in ipairs(db.log.kills) do
		if kill.hk == nil and kill.targetKind == "Player" and type(kill.t) == "number" and type(kill.at) == "number"
			and kill.at >= since then
			MatchKill(kill)
		end
	end
end

--------------------------------------------------------------------------------
-- Our deaths
--
-- The recap can arrive after PLAYER_DEAD, so it is polled a few times.
--------------------------------------------------------------------------------

local RECAP_DELAYS = { 0.5, 1, 1.5, 3, 4 }

local function ReadRecap(entry)
	if not (C_DeathRecap and Fn(C_DeathRecap.GetRecapEvents)) then
		entry.recapStatus = "missing"
		return true
	end
	if Get(C_DeathRecap.HasRecapEvents) ~= true then return false end
	local ok, events = pcall(C_DeathRecap.GetRecapEvents)
	if not ok then
		entry.recapStatus = "error"
		entry.recapError = Safe(events)
		return true
	end
	if isSecret(events) or isSecretTable(events) then
		entry.recapStatus = "secret"
		return true
	end
	if type(events) ~= "table" then
		entry.recapStatus = "empty"
		return true
	end
	entry.recapCount = #events
	entry.recap = {}
	for index = 1, math.min(3, #events) do
		entry.recap[index] = Dump(events[index], 2)
	end
	local first = entry.recap[1]
	if type(first) ~= "table" then
		entry.recapStatus = "empty"
	elseif first.sourceName == SECRET then
		entry.recapStatus = "secret"
	else
		entry.recapStatus = "ok"
		local keys = {}
		for key in pairs(first) do
			keys[#keys + 1] = tostring(key)
		end
		table.sort(keys)
		Example("recapKeys", table.concat(keys, " "), 1)
	end
	-- Who killed us: the killing hit carries the killer's GUID and flags.
	if type(first) == "table" then
		local guid = first.sourceGUID
		if type(guid) == "string" and guid ~= SECRET then
			entry.killer = GuidFacts(guid, true)
		end
		entry.killerIsPlayer = FlagsSayPlayer(first.sourceFlags)
		Count(("DRK.%s.%s"):format(entry.bucket, entry.killer and entry.killer.kind or "unknown"))
	end
	return true
end

local function OnPlayerDead()
	local bucket = Bucket()
	local entry = Push("deaths", { at = Now(), t = Clock(), bucket = bucket, context = Context(), pos = Position() })
	Count("DEATH." .. bucket)
	Count(("POS.death.%s.%s"):format(bucket, entry.pos.status))
	local attempt = 0
	local function try()
		attempt = attempt + 1
		entry.recapTries = attempt
		if ReadRecap(entry) then
			Count(("DR.%s.%s"):format(bucket, entry.recapStatus or "?"))
			Announce("DR." .. bucket .. "." .. tostring(entry.recapStatus),
				("death in %s: recap %s"):format(bucket, tostring(entry.recapStatus)))
			return
		end
		if attempt >= #RECAP_DELAYS then
			entry.recapStatus = "none"
			Count(("DR.%s.none"):format(bucket))
			return
		end
		After(RECAP_DELAYS[attempt + 1], "recap", try)
	end
	After(RECAP_DELAYS[1], "recap", try)
end

--------------------------------------------------------------------------------
-- Battlegrounds
--------------------------------------------------------------------------------

local function ScoreTable(allRows)
	local snapshot = { at = Now(), count = Get(GetNumBattlefieldScores), readable = 0, secret = 0, rows = {} }
	local count = snapshot.count
	if type(count) ~= "number" or not (C_PvP and Fn(C_PvP.GetScoreInfo)) then return snapshot end
	for index = 1, count do
		local ok, info = pcall(C_PvP.GetScoreInfo, index)
		if not ok then
			snapshot.error = Safe(info)
		elseif isSecret(info) or isSecretTable(info) then
			snapshot.secret = snapshot.secret + 1
		elseif type(info) == "table" then
			local row = {
				name = Safe(info.name), guid = Safe(info.guid),
				kb = Safe(info.killingBlows), hk = Safe(info.honorableKills),
				deaths = Safe(info.deaths), honor = Safe(info.honorGained),
				faction = Safe(info.faction), class = Safe(info.classToken), race = Safe(info.raceName),
			}
			if row.kb == SECRET or row.hk == SECRET then
				snapshot.secret = snapshot.secret + 1
			else
				snapshot.readable = snapshot.readable + 1
			end
			row.me = IsMe(row.name, row.guid) or nil
			local canon = Canon(row.name)
			if canon then
				row.guildmate = roster[canon] or nil
				Example("scoreName", row.name, 2)
			end
			if allRows or row.me or index == 1 then
				snapshot.rows[#snapshot.rows + 1] = row
			end
		end
	end
	return snapshot
end

local function ScoreState(snapshot)
	if not snapshot then return "none" end
	if snapshot.count == SECRET then return "secret" end
	if type(snapshot.count) ~= "number" or snapshot.count == 0 then return "empty" end
	if snapshot.secret > 0 and snapshot.readable > 0 then return "mixed" end
	if snapshot.secret > 0 then return "secret" end
	if snapshot.readable > 0 then return "ok" end
	return "unknown"
end

local function NewMatch(how)
	local record = { startedAt = Now(), how = how, context = Context(), during = {} }
	Push("matches", record)
	return record
end

local function PollScores(record)
	if record ~= match or record.completeAt or Bucket() ~= "bg" then return end
	pcall(RequestBattlefieldScoreData)
	After(45, "score-poll", PollScores, record)
end

--------------------------------------------------------------------------------
-- Hidden messages
--
-- Pings say whether a channel works where we are. Reports carry this probe's
-- findings to the other probes of the guild; a hello lists the reports a
-- probe holds, and whoever holds a newer one sends it after a random pause,
-- unless someone else already started. That way a report reaches probes that
-- were never online at the same time as its author.
--------------------------------------------------------------------------------

local queue = {}
local pumping = false
local partial = {}
local seenAt = {}    -- report key -> when its first chunk last went by, from anyone
local sending = {}   -- report key -> true while our copy is queued or going out
local pending = {}   -- report key -> true while a relay waits for its turn
local lastShare = { at = 0 }
local shareRetry = false
local lastHello = 0
local pingSeq = 0
local RECENT = 85    -- a report seen this recently reached whoever is online now

local function ResultName(code)
	if code == nil then return "nil" end
	if code == SECRET then return SECRET end
	if type(code) == "boolean" then return code and "true" or "false" end
	local enum = Enum and Enum.SendAddonMessageResult
	if type(enum) ~= "table" and code == 0 then return "Success" end
	return EnumName(enum, code)
end

local function SendRaw(text, channel, target)
	if not (C_ChatInfo and Fn(C_ChatInfo.SendAddonMessage)) then return "missing" end
	local ok, code = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, channel, target)
	if not ok then return "error" end
	return ResultName(Safe(code))
end

local function ChatBlocked()
	if C_ChatInfo and Get(C_ChatInfo.InChatMessagingLockdown) == true then return true end
	local types = Enum and Enum.AddOnRestrictionType
	if C_RestrictedActions and type(types) == "table" and types.Chat ~= nil then
		if Get(C_RestrictedActions.IsAddOnRestrictionActive, types.Chat) == true then return true end
	end
	return false
end

local function Pump()
	local item = queue[1]
	if not item then
		pumping = false
		return
	end
	if ChatBlocked() then
		Count("AM.wait.blocked")
		After(15, "pump", Pump)
		return
	end
	-- A relay that someone else started while it waited is dropped whole.
	if item.relay and item.index == 1 and (seenAt[item.key] or 0) >= item.queuedAt then
		local kept = {}
		for _, other in ipairs(queue) do
			if other.key ~= item.key then kept[#kept + 1] = other end
		end
		queue = kept
		sending[item.key] = nil
		Count("RP.suppressed")
		After(0.2, "pump", Pump)
		return
	end
	local result = SendRaw(item.text, item.channel)
	Count(("AM.%s.%s.%s"):format(item.channel, Bucket(), result))
	if result:find("Throttle") then
		Count("AM.throttled")
		After(3, "pump", Pump)
		return
	end
	table.remove(queue, 1)
	if item.key and item.index == item.total then sending[item.key] = nil end
	After(SEND_GAP, "pump", Pump)
end

local function Enqueue(item)
	queue[#queue + 1] = item
	if not pumping then
		pumping = true
		After(0.2, "pump", Pump)
	end
end

Ping = function(reason)
	if not db then return end
	pingSeq = pingSeq + 1
	local bucket = Bucket()
	local channels = { "GUILD" }
	if bucket == "bg" then
		channels[#channels + 1] = "INSTANCE_CHAT"
	elseif Get(IsInRaid) == true then
		channels[#channels + 1] = "RAID"
	elseif Get(IsInGroup) == true then
		channels[#channels + 1] = "PARTY"
	end
	local blocked = ChatBlocked()
	for _, channel in ipairs(channels) do
		local result = SendRaw(("P^%d^%s^%s"):format(pingSeq, Clean(reason), bucket), channel)
		Count(("AM.%s.%s.%s"):format(channel, bucket, result))
		Push("comms", {
			at = Now(), t = Clock(), dir = "out", kind = "ping", seq = pingSeq, reason = reason,
			channel = channel, bucket = bucket, result = result, blocked = blocked,
		})
		Announce("AMP." .. channel .. "." .. bucket .. "." .. result,
			("hidden message on %s in %s: %s"):format(channel, bucket, result))
	end
	-- Our own guild messages do not always come back to us on Forever, so a
	-- whisper to ourselves is what tells whether delivery works at all here.
	-- Both name forms are tried: which one a whisper target takes is a finding.
	local variants = { { "space", me.name }, { "dash", me.dashName } }
	for _, variant in ipairs(variants) do
		local form, target = variant[1], variant[2]
		if type(target) == "string" and target ~= SECRET then
			local text = ("P^%d^%s:w%s^%s"):format(pingSeq, Clean(reason), form, bucket)
			local result = SendRaw(text, "WHISPER", target)
			Count(("AM.whisper.%s.%s.%s"):format(form, bucket, result))
			Push("comms", {
				at = Now(), t = Clock(), dir = "out", kind = "ping", seq = pingSeq, reason = reason,
				channel = "WHISPER", form = form, bucket = bucket, result = result, blocked = blocked,
			})
		end
	end
end

-- Counters first, in this order: if the report ever gets cut, the tail is
-- what goes.
local REPORT_ORDER = { "PK", "HG", "HK", "HKD", "HKM", "PKH", "SB", "BG", "DR", "DRK", "DEATH", "AM", "POS", "INS", "UD", "RS", "RP", "HGM", "ERR" }

local function BuildReport()
	local fields = {}
	local function add(key, value)
		if value == nil then return end
		fields[#fields + 1] = Clean(key) .. "=" .. Clean(value)
	end
	local client = db.client or {}
	local mine = db.me or {}
	add("v", VERSION)
	add("build", client.build)
	add("loc", client.locale)
	add("class", mine.class)
	local level = Get(UnitLevel, "player")
	add("level", type(level) == "number" and level or mine.level)
	add("faction", mine.faction)
	add("gname", db.guild and db.guild.name)
	add("bnet", mine.bnet)
	add("bnetHash", mine.bnetHash)

	-- The last death, kill and honor line, in words: what a volunteer's
	-- counters cannot say. Deaths logged by 0.1.0 have no killer yet, so it
	-- is looked up now from the recap.
	local deaths = db.log.deaths
	local lastDeath = deaths[#deaths]
	if lastDeath then
		local first = type(lastDeath.recap) == "table" and lastDeath.recap[1] or nil
		local killer = lastDeath.killer
		if not killer and type(first) == "table" and type(first.sourceGUID) == "string" and first.sourceGUID ~= SECRET then
			killer = GuidFacts(first.sourceGUID, true)
		end
		local isPlayer = lastDeath.killerIsPlayer
		if isPlayer == nil and type(first) == "table" then isPlayer = FlagsSayPlayer(first.sourceFlags) end
		add("last.death", ("%s %s recap:%s killer:%s flagsPlayer:%s spell:%s"):format(
			Stamp(lastDeath.at), tostring(lastDeath.bucket), tostring(lastDeath.recapStatus),
			tostring(Describe(killer, first and first.sourceName)), tostring(isPlayer),
			tostring(first and first.spellName)))
	end
	local lastKill = db.log.kills[#db.log.kills]
	if lastKill then
		add("last.kill", ("%s %s role:%s victim:%s"):format(Stamp(lastKill.at), tostring(lastKill.bucket),
			tostring(lastKill.role), tostring(Describe(lastKill.target, lastKill.targetKind))))
	end
	local honors = db.log.honor
	local lastHonor = honors[#honors]
	if lastHonor then
		add("last.honor", lastHonor.secret and "secret" or tostring(lastHonor.text))
	end
	local assists = db.log.assists
	local lastAssist = assists[#assists]
	if lastAssist then
		add("last.assist", ("%s %s %s victim:%s gap:%s"):format(Stamp(lastAssist.at), tostring(lastAssist.bucket),
			tostring(lastAssist.how), tostring(Describe(lastAssist.victim, lastAssist.names)), tostring(lastAssist.gap)))
	end
	local marks = db.log.marks
	local lastMark = marks[#marks]
	if lastMark then
		local blow = lastMark.lastKill
		add("last.mark", ("%s %s lastKB:%s"):format(Stamp(lastMark.at), (Cut(tostring(lastMark.text), 40)),
			blow and ("%s %ss ago %s %s"):format(tostring(blow.role), tostring(blow.ago), tostring(blow.targetKind),
				tostring(blow.name or blow.npc)) or "none"))
	end

	local groups = {}
	for key, value in pairs(db.counters) do
		local head = key:match("^([^%.]+)") or key
		groups[head] = groups[head] or {}
		groups[head][#groups[head] + 1] = { key = key, value = value }
	end
	local done = {}
	local function addGroup(head)
		local list = groups[head]
		if not list or done[head] then return end
		done[head] = true
		table.sort(list, function(a, b) return a.key < b.key end)
		for _, item in ipairs(list) do add(item.key, item.value) end
	end
	for _, head in ipairs(REPORT_ORDER) do addGroup(head) end
	local rest = {}
	for head in pairs(groups) do
		if not done[head] then rest[#rest + 1] = head end
	end
	table.sort(rest)
	for _, head in ipairs(rest) do addGroup(head) end

	local function first(name)
		local list = db.examples[name]
		return list and list[1]
	end
	add("fmt.honor", first("honorText"))
	add("fmt.honorKey", first("honorKey"))
	add("fmt.victim", first("victimName"))
	add("fmt.roster", first("rosterName"))
	add("fmt.score", first("scoreName"))
	add("fmt.sender", first("senderName"))
	add("fmt.lifetime", first("lifetimeReturns"))
	add("fmt.recap", first("recapKeys"))
	add("fmt.me", first("myName"))

	-- The last kill keys, to compare across probes that were in one group.
	-- An assist with a named victim has a key too.
	local recent = {}
	local kills = db.log.kills
	for index = #kills, math.max(1, #kills - 7), -1 do
		local kill = kills[index]
		if kill.key then recent[#recent + 1] = { at = kill.at, text = kill.key .. ":" .. kill.role } end
	end
	for index = #assists, math.max(1, #assists - 7), -1 do
		local assist = assists[index]
		if assist.key then recent[#recent + 1] = { at = assist.at, text = assist.key .. ":assist" } end
	end
	table.sort(recent, function(a, b) return a.at > b.at end)
	local keys = {}
	for index = 1, math.min(8, #recent) do keys[index] = recent[index].text end
	if #keys > 0 then add("kk", table.concat(keys, " ")) end

	local errors = db.log.errors
	add("err.n", #errors)
	if errors[1] then
		add("err.first", (tostring(errors[1].where) .. ": " .. tostring(errors[1].message)):sub(1, 150))
	end
	return (Cut(table.concat(fields, ";"), REPORT_MAX))
end

local function SplitText(text, size)
	local chunks, rest = {}, text
	while #rest > 0 do
		local head
		head, rest = Cut(rest, size)
		if head == "" then
			head, rest = rest:sub(1, size), rest:sub(size + 1)
		end
		chunks[#chunks + 1] = head
	end
	if #chunks == 0 then chunks[1] = "" end
	return chunks
end

local function Broadcast(origin, report, relay)
	local key = origin .. "@" .. report.ts
	local chunks = SplitText(report.data, REPORT_CHUNK)
	sending[key] = true
	local queuedAt = Now()
	for index, chunk in ipairs(chunks) do
		Enqueue({
			text = ("R^%s^%d^%d^%d^%s"):format(origin, report.ts, index, #chunks, chunk), channel = "GUILD",
			key = key, index = index, total = #chunks, relay = relay, queuedAt = queuedAt,
		})
	end
end

local function OwnReport()
	if not me.key then RefreshMe() end
	-- 0.1.0 keyed our report by first name only; drop such a leftover.
	for origin, report in pairs(db.reports) do
		if report.own and origin ~= me.key then db.reports[origin] = nil end
	end
	local data = BuildReport()
	local own = db.reports[me.key]
	if not own or own.data ~= data then
		own = { ts = Now(), data = data, own = true }
		db.reports[me.key] = own
	end
	return own
end

SendHello = function()
	if not db or not me.key then return end
	lastHello = Now()
	local parts = {}
	for origin, report in pairs(db.reports) do
		parts[#parts + 1] = origin .. "=" .. tostring(report.ts)
	end
	table.sort(parts)
	local inventory = Cut(table.concat(parts, ","), 200)
	Enqueue({ text = "H^" .. me.key .. "^" .. inventory, channel = "GUILD" })
	Count("RP.hello.sent")
end

ShareOwn = function(reason)
	if not db then return end
	local own = OwnReport()
	if Get(IsInGuild) ~= true then
		Count("RP.noguild")
		return
	end
	local forced = reason == "login" or reason == "manual"
	if not forced then
		if lastShare.data == own.data then return end
		-- Too soon after the last share: try again once the gap is over rather
		-- than waiting for the next tick.
		local wait = SHARE_MIN_GAP - (Now() - lastShare.at)
		if wait > 0 then
			if not shareRetry then
				shareRetry = true
				After(wait + 1, "share", function()
					shareRetry = false
					ShareOwn(reason)
				end)
			end
			return
		end
	end
	if sending[me.key .. "@" .. own.ts] then return end
	lastShare.at, lastShare.data = Now(), own.data
	if forced then SendHello() end
	Broadcast(me.key, own, false)
	Count("RP.sent.own")
end

local function OnReportChunk(text, sender)
	local origin, ts, index, total, data = text:match("^R%^([^%^]+)%^(%d+)%^(%d+)%^(%d+)%^(.*)$")
	ts, index, total = tonumber(ts), tonumber(index), tonumber(total)
	if not (origin and ts and index and total) or total < 1 or index < 1 or index > total then
		Count("RP.bad")
		return
	end
	local key = origin .. "@" .. ts
	if index == 1 then seenAt[key] = Now() end
	if origin == me.key then return end
	local have = db.reports[origin]
	if have and have.ts >= ts then return end
	local part = partial[key]
	if not part then
		part = { total = total, got = 0, pieces = {} }
		partial[key] = part
	end
	if not part.pieces[index] then
		part.pieces[index] = data
		part.got = part.got + 1
	end
	if part.got < part.total then return end
	partial[key] = nil
	db.reports[origin] = { ts = ts, data = table.concat(part.pieces), via = sender, receivedAt = Now() }
	Count("RP.received")
	if Verbose() then
		local via = (sender ~= origin) and (" via " .. tostring(sender)) or ""
		Print(("report received from %s%s"):format(origin, via))
	end
end

local function OnHello(text, sender)
	local origin, inventory = text:match("^H%^([^%^]+)%^(.*)$")
	if not origin or origin == me.key then return end
	Count("RP.hello.received")
	local theirs = {}
	for name, ts in inventory:gmatch("([^,=]+)=(%d+)") do
		theirs[name] = tonumber(ts)
	end
	-- Relay what they lack, after a random pause, unless someone else does,
	-- or it went by so recently that they got it anyway.
	for name, report in pairs(db.reports) do
		local key = name .. "@" .. report.ts
		local recent = seenAt[key] and Now() - seenAt[key] < RECENT
		if (theirs[name] or 0) < report.ts and not pending[key] and not sending[key] and not recent then
			pending[key] = true
			local scheduledAt = Now()
			After(2 + math.random() * 6, "relay", function()
				pending[key] = nil
				local current = db.reports[name]
				if not current or current.ts ~= report.ts then return end
				if (seenAt[key] or 0) >= scheduledAt or sending[key] then
					Count("RP.suppressed")
					return
				end
				Broadcast(name, report, true)
				Count(name == me.key and "RP.sent.own" or "RP.sent.relay")
			end)
		end
	end
	-- They hold something newer than us: say hello back so they relay it.
	for name, ts in pairs(theirs) do
		local mine = db.reports[name]
		if name ~= me.key and (not mine or mine.ts < ts) then
			if Now() - lastHello > 60 then
				lastHello = Now()
				After(3 + math.random() * 5, "hello", SendHello)
			end
			break
		end
	end
	Announce("HELLO." .. tostring(sender), "hello from " .. tostring(sender))
end

--------------------------------------------------------------------------------
-- Inspecting a guildmate's honor (/kbsp inspect)
--------------------------------------------------------------------------------

local function FinishInspect(reason)
	local record = pendingInspect
	if not record then return end
	pendingInspect = nil
	record.reason = reason
	record.data = Call(GetInspectHonorData)
	record.hasData = Get(HasInspectHonorData)
	Push("inspects", record)
	local lifetime = record.data[5]
	local state = (lifetime == SECRET and "secret") or (type(lifetime) == "number" and "ok") or "empty"
	Count(("INS.%s.%s"):format(reason, state))
	Print(("inspect %s: lifetime HK %s, today HK %s (%s)."):format(
		tostring(record.name), tostring(lifetime), tostring(record.data[1]), reason))
	local frame = InspectFrame
	if not (type(frame) == "table" and Fn(frame.IsShown) and frame:IsShown()) then
		pcall(ClearInspectPlayer)
	end
end

local function StartInspect()
	if Get(UnitExists, "target") ~= true or Get(UnitIsPlayer, "target") ~= true then
		Print("target a player first (a guildmate close to you works best).")
		return
	end
	if Get(CanInspect, "target") ~= true then
		Print("cannot inspect that target right now (too far?).")
		Count("INS.cannot")
		return
	end
	local record = { at = Now(), name = Get(UnitName, "target"), guid = PlainGuid("target"), events = {} }
	pendingInspect = record
	pcall(NotifyInspect, "target")
	if Fn(RequestInspectHonorData) then
		record.requested = true
		pcall(RequestInspectHonorData)
	end
	Print("inspecting " .. tostring(record.name) .. "...")
	After(6, "inspect-timeout", function()
		if pendingInspect == record then FinishInspect("timeout") end
	end)
end

--------------------------------------------------------------------------------
-- What does not change during a session
--------------------------------------------------------------------------------

local API = {
	"GetPVPSessionStats", "GetPVPLifetimeStats", "GetPVPYesterdayStats", "GetInspectHonorData",
	"HasInspectHonorData", "RequestInspectHonorData", "NotifyInspect", "CanInspect",
	"GetPlayerInfoByGUID", "UnitTokenFromGUID", "GetNumBattlefieldScores",
	"RequestBattlefieldScoreData", "GetBattlefieldWinner", "BNGetInfo",
	"issecretvalue", "issecrettable", "canaccessvalue",
	"C_PvP.GetScoreInfo", "C_PvP.GetScoreInfoByPlayerGuid", "C_PvP.IsBattleground",
	"C_PvP.GetActiveMatchState", "C_DeathRecap.GetRecapEvents", "C_DeathRecap.HasRecapEvents",
	"C_ChatInfo.SendAddonMessage", "C_ChatInfo.InChatMessagingLockdown",
	"C_RestrictedActions.IsAddOnRestrictionActive", "C_Secrets.ShouldUnitIdentityBeSecret",
	"C_Map.GetPlayerMapPosition", "C_DateAndTime.GetSecondsUntilWeeklyReset",
	"C_GuildInfo.GuildRoster", "C_BattleNet.GetAccountInfoByGUID",
}

local function Resolve(path)
	local node = _G
	for part in path:gmatch("[^%.]+") do
		if type(node) ~= "table" then return nil end
		node = node[part]
	end
	return node
end

-- Whether the BattleTag is readable, to group alts across WoW accounts of one
-- Battle.net account. Only a salted hash is kept; the tag never leaves here.
local function BattleTagState()
	if not Fn(BNGetInfo) then return "missing", nil end
	local ok, _, tag = pcall(BNGetInfo)
	if not ok then return "error", nil end
	if isSecret(tag) then return "secret", nil end
	if type(tag) ~= "string" or tag == "" then return "nil", nil end
	return "ok", Hash("KBS:" .. tag)
end

local function CaptureStatic()
	RefreshMe()
	local version, build, buildDate, toc = Get(GetBuildInfo)
	db.client = {
		version = version, build = build, buildDate = buildDate, toc = toc,
		locale = Get(GetLocale), project = Safe(WOW_PROJECT_ID),
		secrets = C_Secrets and Get(C_Secrets.HasSecretRestrictions) or nil,
	}
	local _, classFile = Get(UnitClass, "player")
	local bnet, bnetHash = BattleTagState()
	db.me = {
		key = me.key, guid = me.guid, class = classFile, level = Get(UnitLevel, "player"),
		faction = Get(UnitFactionGroup, "player"), bnet = bnet, bnetHash = bnetHash,
		unitName = Call(UnitName, "player"), fullName = Call(UnitFullName, "player"),
		getUnitName = Call(GetUnitName, "player", true),
		byGuid = me.guid and Call(GetPlayerInfoByGUID, me.guid) or nil,
		realm = Get(GetRealmName), normalizedRealm = Get(GetNormalizedRealmName),
	}
	Example("myName", ("%s / %s %s / %s"):format(tostring(db.me.unitName[1]), tostring(db.me.fullName[1]),
		tostring(db.me.fullName[2]), tostring(db.me.getUnitName[1])), 1)
	local api = {}
	for _, path in ipairs(API) do
		api[path] = Fn(Resolve(path)) ~= nil
	end
	db.api = api
	db.events = registration
	db.prefix = prefixResult
	db.reset = { serverTime = Now() }
	if C_DateAndTime then
		db.reset.weekly = Get(C_DateAndTime.GetSecondsUntilWeeklyReset)
		db.reset.daily = Get(C_DateAndTime.GetSecondsUntilDailyReset)
	end
	Guard("strings", CaptureStrings)
	local sessions = db.sessions
	sessions[#sessions + 1] = { at = Now(), key = me.key, version = VERSION }
	while #sessions > 30 do
		table.remove(sessions, 1)
	end
end

--------------------------------------------------------------------------------
-- Reading it back
--------------------------------------------------------------------------------

local function Sum(pattern)
	local total = 0
	for key, value in pairs(db.counters) do
		if key:find(pattern) then total = total + value end
	end
	return total
end

local function Status()
	local others = 0
	for origin in pairs(db.reports) do
		if origin ~= me.key then others = others + 1 end
	end
	local sentWorld, okWorld = Sum("^AM%.[%u_]+%.world%."), Sum("^AM%.[%u_]+%.world%.Success$")
	local sentBg, okBg = Sum("^AM%.[%u_]+%.bg%."), Sum("^AM%.[%u_]+%.bg%.Success$")
	Print(("v%s, verbose %s, reports from %d other probe(s)."):format(VERSION, Verbose() and "on" or "off", others))
	Print(("World kills seen: %d players (me %d, my pet %d, party %d, raid same group %d, raid other group %d, other %d), %d NPCs."):format(
		Sum("^PK%.world%.Player%."), Sum("^PK%.world%.Player%.me$"), Sum("^PK%.world%.Player%.mypet$"),
		Sum("^PK%.world%.Player%.party"), Sum("^PK%.world%.Player%.raid%-samegroup$"),
		Sum("^PK%.world%.Player%.raid%-othergroup$"), Sum("^PK%.world%.Player%.other$"), Sum("^PK%.world%.Creature%.")))
	Print(("Battleground kills seen: %d readable, %d secret."):format(Sum("^PK%.bg%.Player%."), Sum("^PK%.bg%.secret%.")))
	Print(("Honor lines: world %d ok, %d secret; battlegrounds %d ok, %d secret."):format(
		Sum("^HG%.world%.ok$"), Sum("^HG%.world%.secret$"), Sum("^HG%.bg%.ok$"), Sum("^HG%.bg%.secret$")))
	Print(("HK counter: world %d ok, %d secret; battlegrounds %d ok, %d secret."):format(
		Sum("^HK%.%a+%.world%.ok$"), Sum("^HK%.%a+%.world%.secret$"), Sum("^HK%.%a+%.bg%.ok$"), Sum("^HK%.%a+%.bg%.secret$")))
	Print(("HKs matched: %d to a killing blow in the group, %d without one (victim named %d, several candidates %d, not seen %d)."):format(
		Sum("^HKM%.%a+%.kb%."), Sum("^HKM%.%a+%.assist%."), Sum("^HKM%.%a+%.assist%.named$"),
		Sum("^HKM%.%a+%.assist%.ambiguous$"), Sum("^HKM%.%a+%.assist%.unseen$")))
	Print(("Player kills by me or my group that gave me no HK: %d of %d."):format(Sum("^PKH%..-%.nohk$"), Sum("^PKH%.")))
	Print(("Battlegrounds finished: %d; scoreboard during the match %d ok, %d secret; at the end %d ok, %d secret."):format(
		Sum("^BG%.complete$"), Sum("^SB%.during%.ok$"), Sum("^SB%.during%.secret$"),
		Sum("^SB%.final%.ok$"), Sum("^SB%.final%.secret$")))
	Print(("Deaths: %d; killer readable %d, secret %d, no recap %d."):format(
		Sum("^DEATH%."), Sum("^DR%.%a+%.ok$"), Sum("^DR%.%a+%.secret$"), Sum("^DR%.%a+%.none$")))
	Print(("Hidden messages: world %d sent, %d refused; battlegrounds %d sent, %d refused; %d received from others."):format(
		okWorld, sentWorld - okWorld, okBg, sentBg - okBg, Sum("^AM%.in%.[%u_]+%.%a+%.%u%.peer$")))
	Print(("Errors: %d. /reload writes everything to disk."):format(#db.log.errors))
end

local function ExportText()
	local lines = {}
	local client = db.client or {}
	lines[#lines + 1] = ("Killed by Savages probe %s - %s"):format(VERSION, tostring(me.key))
	lines[#lines + 1] = ("client %s (%s), %s"):format(tostring(client.version), tostring(client.build), tostring(client.locale))
	lines[#lines + 1] = ""
	lines[#lines + 1] = (OwnReport().data:gsub(";", "\n"))
	lines[#lines + 1] = ""
	lines[#lines + 1] = "reports held:"
	for origin, report in pairs(db.reports) do
		local how = report.own and "mine" or ("via " .. tostring(report.via))
		lines[#lines + 1] = ("  %s  %s  %s"):format(origin, Stamp(report.ts), how)
	end
	return table.concat(lines, "\n")
end

local exportFrame

local function ShowExport()
	if not exportFrame then
		local ok, frame = pcall(function()
			local f = CreateFrame("Frame", "KBSProbeExportFrame", UIParent)
			f:SetSize(600, 400)
			f:SetPoint("CENTER")
			f:SetFrameStrata("DIALOG")
			f:EnableMouse(true)
			f:SetMovable(true)
			f:RegisterForDrag("LeftButton")
			f:SetScript("OnDragStart", f.StartMoving)
			f:SetScript("OnDragStop", f.StopMovingOrSizing)
			local background = f:CreateTexture(nil, "BACKGROUND")
			background:SetAllPoints()
			background:SetColorTexture(0.05, 0.05, 0.06, 0.94)
			local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			title:SetPoint("TOPLEFT", 12, -10)
			title:SetText("Killed by Savages probe. Ctrl+A then Ctrl+C to copy.")
			local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
			close:SetPoint("TOPRIGHT", -2, -2)
			local scroll = CreateFrame("ScrollFrame", "KBSProbeExportScroll", f, "UIPanelScrollFrameTemplate")
			scroll:SetPoint("TOPLEFT", 12, -34)
			scroll:SetPoint("BOTTOMRIGHT", -32, 12)
			local edit = CreateFrame("EditBox", nil, scroll)
			edit:SetMultiLine(true)
			edit:SetAutoFocus(false)
			edit:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
			edit:SetWidth(550)
			edit:SetScript("OnEscapePressed", function() f:Hide() end)
			scroll:SetScrollChild(edit)
			f.edit = edit
			if type(UISpecialFrames) == "table" then
				table.insert(UISpecialFrames, "KBSProbeExportFrame")
			end
			return f
		end)
		if not ok then
			RecordError("export", frame)
			Print("the report window did not open; the same data is in the SavedVariables file.")
			return
		end
		exportFrame = frame
	end
	exportFrame.edit:SetText(ExportText())
	exportFrame:Show()
	exportFrame.edit:SetFocus()
	exportFrame.edit:HighlightText()
end

local function ListReports()
	local count = 0
	for origin, report in pairs(db.reports) do
		count = count + 1
		local how = report.own and "mine" or ("via " .. tostring(report.via))
		Print(("%s, %s, %s"):format(origin, Stamp(report.ts), how))
	end
	if count == 0 then Print("no report yet.") end
end

-- Our last killing blow seen, on a player or a mob, and how long ago: what
-- /kbsp mark tells, so a test like "let a DoT finish a mob, then mark" reads
-- itself.
local function LastOwnKill()
	local best
	for _, listName in ipairs({ "kills", "killsNpc" }) do
		local list = db.log[listName]
		for index = #list, 1, -1 do
			local item = list[index]
			if item.role == "me" or item.role == "mypet" then
				if not best or (item.at or 0) > (best.at or 0) then best = item end
				break
			end
		end
	end
	if not best then return nil end
	local ago = Now() - (best.at or 0)
	if type(best.t) == "number" then
		local precise = Clock() - best.t
		if precise >= 0 and math.abs(precise - ago) <= 2 then ago = Round(precise, 1) end
	end
	return {
		ago = ago, role = best.role, targetKind = best.targetKind, npc = best.npc,
		name = best.targetName or (type(best.target) == "table" and best.target.name or nil),
	}
end

local function Help()
	Print("/kbsp - summary of what the probe saw")
	Print("/kbsp verbose - tell me when something is seen for the first time")
	Print("/kbsp mark <text> - leave a note in the log and see your last killing blow, like: /kbsp mark dot")
	Print("/kbsp inspect - read the honor of your target (a guildmate close to you)")
	Print("/kbsp share - send this report to the other probes now")
	Print("/kbsp reports - list the reports received from other probes")
	Print("/kbsp export - open the report in a window you can copy from")
	Print("/kbsp reset - forget everything this probe recorded on this account")
end

local function HandleSlash(input)
	if not db then InitDB() end
	local command, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	command = (command or ""):lower()
	if command == "" or command == "status" then
		Status()
	elseif command == "verbose" then
		db.settings.verbose = not db.settings.verbose
		Print("verbose " .. (db.settings.verbose and "on" or "off") .. ".")
	elseif command == "mark" then
		local blow = LastOwnKill()
		Push("marks", {
			at = Now(), t = Clock(), text = rest, bucket = Bucket(),
			zone = Get(GetRealZoneText), subzone = Get(GetSubZoneText), context = Context(), lastKill = blow,
		})
		if blow then
			Print(("noted: %s. Last killing blow seen: %s, %s s ago (%s)."):format(tostring(rest), tostring(blow.role),
				tostring(blow.ago), tostring(blow.name or blow.npc or blow.targetKind)))
		else
			Print(("noted: %s. No killing blow of yours seen yet."):format(tostring(rest)))
		end
	elseif command == "inspect" then
		StartInspect()
	elseif command == "share" then
		ShareOwn("manual")
		Print("report queued for the other probes.")
	elseif command == "ping" then
		Ping("manual")
		Print("ping sent.")
	elseif command == "reports" then
		ListReports()
	elseif command == "export" then
		ShowExport()
	elseif command == "reset" then
		local verbose = db.settings.verbose
		KBSProbeDB = nil
		InitDB()
		db.settings.verbose = verbose
		CaptureStatic()
		Print("cleared.")
	else
		Help()
	end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local on = {}

on.ADDON_LOADED = function(name)
	if name == ADDON_NAME then InitDB() end
end

on.PLAYER_LOGIN = function()
	InitDB()
	-- Each step on its own: one failing must not cancel the timers below.
	Guard("static", CaptureStatic)
	Guard("hk", SnapshotHK, "login")
	Guard("roster", RequestRoster)
	After(5, "match-past", MatchPast)
	After(20, "ping", Ping, "login")
	After(90, "share", ShareOwn, "login")
	Every(SHARE_TICK, "share", ShareOwn, "tick")
	Announce("loaded", "loaded in verbose mode. /kbsp for the summary.")
end

on.PLAYER_LOGOUT = function()
	if not db then return end
	db.lastLogout = Now()
	OwnReport()
end

on.PLAYER_ENTERING_WORLD = function(isLogin, isReload)
	RefreshMe()
	local bucket = Bucket()
	-- Logged apart, so a failure here never skips the battleground bookkeeping.
	Guard("pew-log", function()
		local position = Position()
		Count(("POS.pew.%s.%s"):format(bucket, position.status))
		Push("zones", {
			at = Now(), event = "PLAYER_ENTERING_WORLD", login = Safe(isLogin), reload = Safe(isReload),
			context = Context(), pos = position,
		})
	end)
	if bucket == "bg" and lastBucket ~= "bg" then
		SnapshotHK("enter-bg")
		After(8, "ping", Ping, "enter-bg")
	elseif lastBucket == "bg" and bucket ~= "bg" then
		SnapshotHK("left-bg")
		match = nil
		After(10, "ping", Ping, "left-bg")
		After(30, "share", ShareOwn, "left-bg")
	end
	lastBucket = bucket
end

on.ZONE_CHANGED_NEW_AREA = function()
	local bucket = Bucket()
	local position = Position()
	Count(("POS.zone.%s.%s"):format(bucket, position.status))
	Push("zones", {
		at = Now(), event = "ZONE_CHANGED_NEW_AREA", bucket = bucket,
		zone = Get(GetRealZoneText), subzone = Get(GetSubZoneText), pos = position,
	})
end

on.PARTY_KILL = OnPartyKill
on.UNIT_DIED = OnUnitDied
on.CHAT_MSG_COMBAT_HONOR_GAIN = OnHonorGain
on.PLAYER_DEAD = OnPlayerDead

on.PLAYER_PVP_KILLS_CHANGED = function(unit)
	local entry = SnapshotHK("PLAYER_PVP_KILLS_CHANGED")
	if not entry then return end
	entry.unit = Safe(unit)
	Announce("HK." .. entry.bucket .. "." .. tostring(entry.secret),
		("HK counter moved in %s: %s"):format(entry.bucket, entry.secret and "secret" or ("lifetime " .. tostring(entry.lifetime[1]))))
end

on.PVP_MATCH_ACTIVE = function()
	match = NewMatch("active")
	Count("BG.active")
	PollScores(match)
end

on.UPDATE_BATTLEFIELD_SCORE = function()
	local record = match
	if not record then return end
	if record.completeAt then
		if not record.final then
			record.final = ScoreTable(true)
			Count("SB.final." .. ScoreState(record.final))
		end
		return
	end
	local now = Now()
	if now - (record.lastDuring or 0) < 30 then return end
	record.lastDuring = now
	local snapshot = ScoreTable(false)
	if #record.during < 10 then record.during[#record.during + 1] = snapshot end
	local state = ScoreState(snapshot)
	Count("SB.during." .. state)
	Announce("SB.during." .. state, "scoreboard during the match: " .. state)
end

on.PVP_MATCH_COMPLETE = function(winner, duration)
	local record = match or NewMatch("complete")
	match = record
	record.completeAt = Now()
	record.winner, record.duration = Safe(winner), Safe(duration)
	record.battlefieldWinner = Get(GetBattlefieldWinner)
	record.atEnd = Context()
	record.immediate = ScoreTable(true)
	Count("BG.complete")
	Count("SB.immediate." .. ScoreState(record.immediate))
	if me.guid and C_PvP and Fn(C_PvP.GetScoreInfoByPlayerGuid) then
		local ok, info = pcall(C_PvP.GetScoreInfoByPlayerGuid, me.guid)
		record.mine = ok and Dump(info, 1) or ("error: " .. tostring(Safe(info)))
	end
	pcall(RequestBattlefieldScoreData)
	After(3, "score-final", function()
		if not record.final then
			record.final = ScoreTable(true)
			Count("SB.final." .. ScoreState(record.final))
		end
		Announce("SB.final." .. ScoreState(record.final), "scoreboard at the end: " .. ScoreState(record.final))
	end)
	SnapshotHK("match-complete")
	After(1, "ping", Ping, "match-complete")
end

on.PVP_MATCH_INACTIVE = function()
	if match then match.inactiveAt = Now() end
end

on.ADDON_RESTRICTION_STATE_CHANGED = function(kind, state)
	local bucket = Bucket()
	local typeName = EnumName(Enum and Enum.AddOnRestrictionType, Safe(kind))
	local stateName = EnumName(Enum and Enum.AddOnRestrictionState, Safe(state))
	Count(("RS.%s.%s.%s"):format(typeName, bucket, stateName))
	-- Combat flips with every fight: counted, not logged one by one, so it
	-- never pushes the battleground and chat changes out of the log.
	if typeName == "Combat" or typeName == "Encounter" then return end
	local _, instanceType = Get(IsInInstance)
	Push("restrictions", {
		at = Now(), t = Clock(), type = typeName, state = stateName, bucket = bucket,
		zone = Get(GetRealZoneText), instanceType = instanceType,
	})
end

on.CHAT_MSG_ADDON = function(prefix, text, channel, sender)
	if isSecret(prefix) then
		Count("AM.in.secretprefix")
		return
	end
	if prefix ~= PREFIX then return end
	local bucket = Bucket()
	if isSecret(text) or isSecret(sender) or isSecret(channel) then
		Count("AM.in.secret." .. bucket)
		return
	end
	if type(text) ~= "string" or text == "" then return end
	local mine = sender == me.key or IsMe(sender, nil)
	Example("senderName", sender, 2)
	local kind = text:sub(1, 1)
	Count(("AM.in.%s.%s.%s.%s"):format(tostring(channel), bucket, kind, mine and "self" or "peer"))
	if kind == "P" then
		local seq, reason, theirBucket = text:match("^P%^(%d+)%^([^%^]*)%^(.*)$")
		local form = reason and reason:match(":w(%a+)$")
		if form then Count(("AM.whisper.%s.%s.received"):format(form, bucket)) end
		Push("comms", {
			at = Now(), t = Clock(), dir = "in", kind = "ping", channel = channel, sender = sender,
			mine = mine, seq = seq, reason = reason, theirBucket = theirBucket, bucket = bucket,
		})
		if not mine then
			Announce("AMIN." .. tostring(channel), ("hidden message received on %s from %s"):format(tostring(channel), tostring(sender)))
		end
	elseif kind == "R" then
		OnReportChunk(text, sender)
	elseif kind == "H" then
		OnHello(text, sender)
	end
end

on.INSPECT_HONOR_UPDATE = function()
	local record = pendingInspect
	if not record then return end
	record.events[#record.events + 1] = "INSPECT_HONOR_UPDATE"
	FinishInspect("honor-update")
end

on.INSPECT_READY = function(guid)
	local record = pendingInspect
	if not record then return end
	record.events[#record.events + 1] = "INSPECT_READY"
	if not isSecret(guid) and record.guid ~= nil then
		record.readyGuidMatches = guid == record.guid
	end
	After(2, "inspect-ready", function()
		if pendingInspect == record then FinishInspect("ready") end
	end)
end

on.GUILD_ROSTER_UPDATE = OnRoster

on.PLAYER_LEVEL_UP = function(level)
	if db and db.me then db.me.level = Safe(level) end
end

local EVENTS = {
	"ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LOGOUT", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
	"PARTY_KILL", "UNIT_DIED", "CHAT_MSG_COMBAT_HONOR_GAIN", "PLAYER_PVP_KILLS_CHANGED", "PLAYER_DEAD",
	"PVP_MATCH_ACTIVE", "PVP_MATCH_COMPLETE", "PVP_MATCH_INACTIVE", "UPDATE_BATTLEFIELD_SCORE",
	"ADDON_RESTRICTION_STATE_CHANGED", "CHAT_MSG_ADDON", "INSPECT_READY", "INSPECT_HONOR_UPDATE",
	"GUILD_ROSTER_UPDATE", "PLAYER_LEVEL_UP",
}

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, ...)
	Guard(event, on[event], ...)
end)
for _, event in ipairs(EVENTS) do
	-- An event this client does not know is a finding, not a load error.
	registration[event] = (pcall(frame.RegisterEvent, frame, event))
end

if C_ChatInfo and Fn(C_ChatInfo.RegisterAddonMessagePrefix) then
	prefixResult = Call(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
end

SLASH_KBSPROBE1 = "/kbsp"
SlashCmdList.KBSPROBE = function(input)
	Guard("slash", HandleSlash, input)
end
