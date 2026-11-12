local _, ns = ...

--------------------------------------------------------------------------------
-- Who we are, who the guild is
--
-- A character is its GUID. A player is the salted hash of their BattleTag,
-- which every character of the account reads the same; the tag itself is
-- never kept. The guild roster maps "First Last" names to GUIDs and ranks.
--------------------------------------------------------------------------------

local Util = ns.Util
local Get, Safe, SECRET, Fn = Util.Get, Util.Safe, Util.SECRET, Util.Fn

local Identity = {}
ns.Identity = Identity

local me = {}
Identity.me = me

local roster = { byCanon = {}, byTail = {}, count = 0, at = 0 }
Identity.roster = roster

local ROSTER_MIN_GAP = 10
-- Index of "speak in officer chat" in the rank permission table of the retail
-- guild control UI. Checked against C_GuildInfo.IsGuildOfficer at login; when
-- they disagree the addon falls back to the two top ranks.
local OFFICER_SPEAK_FLAG = 4
local officerFlagTrusted = true

local RACE_FACTION = {
	Human = "Alliance", Dwarf = "Alliance", NightElf = "Alliance", Gnome = "Alliance",
	Draenei = "Alliance", Worgen = "Alliance",
	Orc = "Horde", Scourge = "Horde", Tauren = "Horde", Troll = "Horde",
	BloodElf = "Horde", Goblin = "Horde",
}
Identity.RACE_FACTION = RACE_FACTION

local function PlainGuid(unit)
	if not Fn(UnitGUID) then return nil end
	local ok, guid = pcall(UnitGUID, unit)
	if not ok or Util.IsSecret(guid) or type(guid) ~= "string" then return nil end
	return guid
end
Identity.PlainGuid = PlainGuid

-- The realm names a name may end with, kept between calls: Canon runs once
-- per roster member and several times per addon message.
local realms = {}

function Identity.Canon(name)
	return Util.Canon(name, realms)
end

-- Whether the BattleTag is readable, and its salted hash. Only the hash is
-- ever kept or sent.
local function BattleTagHash()
	if not Fn(BNGetInfo) then return "missing", nil end
	local ok, _, tag = pcall(BNGetInfo)
	if not ok then return "error", nil end
	if Util.IsSecret(tag) then return "secret", nil end
	if type(tag) ~= "string" or tag == "" then return "nil", nil end
	return "ok", Util.Hash("KBS:" .. tag)
end

function Identity.Refresh()
	me.guid = PlainGuid("player")
	me.tail = Util.Tail(me.guid)
	-- On Forever UnitName returns the first name and the surname, not a realm.
	local first, surname = Get(UnitName, "player")
	local hasSurname = type(surname) == "string" and surname ~= "" and surname ~= SECRET
	local full = Get(GetUnitName, "player", true)
	if type(full) ~= "string" or full == "" or full == SECRET then
		full = hasSurname and (tostring(first) .. " " .. surname) or tostring(first)
	end
	me.name = full
	me.first = Safe(first)
	me.surname = hasSurname and surname or nil
	me.realm = Get(GetNormalizedRealmName) or Get(GetRealmName)
	me.realmName = Get(GetRealmName)
	for index = #realms, 1, -1 do realms[index] = nil end
	for _, realm in ipairs({ me.realm or false, me.realmName or false }) do
		if type(realm) == "string" and realm ~= SECRET then realms[#realms + 1] = realm end
	end
	me.key = Util.Clean(tostring(me.name) .. "-" .. tostring(me.realm))
	local _, classFile = Get(UnitClass, "player")
	me.class = classFile
	local _, raceFile = Get(UnitRace, "player")
	me.race = raceFile
	me.faction = Get(UnitFactionGroup, "player")
	if me.faction == "Alliance" then
		me.enemyFaction = "Horde"
	elseif me.faction == "Horde" then
		me.enemyFaction = "Alliance"
	else
		me.enemyFaction = nil
	end
	me.level = Get(UnitLevel, "player")
	me.guild, me.rankName, me.rankIndex = Get(GetGuildInfo, "player")
	if me.guild == SECRET then me.guild = nil end
	me.bnet, me.bnetHash = BattleTagHash()
	me.playerKey = me.bnetHash or (ns.db and ("acc:" .. ns.db.accountId)) or nil
	return me
end

function Identity.IsMe(name, guid)
	if guid ~= nil and guid ~= SECRET and me.guid ~= nil and guid == me.guid then return true end
	local canon = Identity.Canon(name)
	return canon ~= nil and canon == Identity.Canon(me.name)
end

function Identity.InGuild()
	return Get(IsInGuild) == true and type(me.guild) == "string" and me.guild ~= ""
end

--------------------------------------------------------------------------------
-- Roster
--------------------------------------------------------------------------------

function Identity.RequestRoster()
	if C_GuildInfo and Fn(C_GuildInfo.GuildRoster) then
		pcall(C_GuildInfo.GuildRoster)
	elseif Fn(GuildRoster) then
		pcall(GuildRoster)
	end
end

-- GUILD_ROSTER_UPDATE fires often; the roster is rebuilt at most every few
-- seconds. An update that comes too soon is not lost: the roster is read
-- once more when the gap is over, or a member who just joined or logged in
-- would stay unknown until the client fires the event again.
-- GetGuildRosterInfo gives the GUID as its 17th return on Forever.
function Identity.UpdateRoster(force)
	local now = Util.Now()
	if not force and now - roster.at < ROSTER_MIN_GAP then
		if not roster.pending then
			roster.pending = true
			Util.After(ROSTER_MIN_GAP - (now - roster.at) + 0.5, "roster", function()
				roster.pending = false
				Identity.UpdateRoster(true)
			end)
		end
		return false
	end
	local count = Get(GetNumGuildMembers)
	if type(count) ~= "number" or count <= 0 then
		if not Identity.InGuild() then
			roster.byCanon, roster.byTail, roster.count = {}, {}, 0
		end
		return false
	end
	roster.at = now
	local byCanon, byTail = {}, {}
	for index = 1, count do
		local values = Util.Call(GetGuildRosterInfo, index)
		local name = values[1]
		local canon = Identity.Canon(name)
		if canon then
			local guid = values[17]
			local entry = {
				name = name, canon = canon, rankName = values[2], rankIndex = values[3],
				level = values[4], class = values[11], online = values[9] == true,
				guid = type(guid) == "string" and guid or nil,
			}
			entry.tail = Util.Tail(entry.guid)
			byCanon[canon] = entry
			if entry.tail then byTail[entry.tail] = entry end
		end
	end
	roster.byCanon, roster.byTail, roster.count = byCanon, byTail, count
	-- A promotion changes the roster and our own rank together.
	local guild, rankName, rankIndex = Get(GetGuildInfo, "player")
	if guild ~= nil and guild ~= SECRET then me.rankName, me.rankIndex = rankName, rankIndex end
	if ns.Fire then ns.Fire("RosterUpdated") end
	return true
end

-- Whether the roster has been read at least once, with members in it.
function Identity.RosterKnown()
	return (roster.count or 0) > 0 and next(roster.byCanon) ~= nil
end

function Identity.Member(name)
	local canon = Identity.Canon(name)
	return canon and roster.byCanon[canon] or nil
end

function Identity.MemberByTail(tail)
	return tail and roster.byTail[tail] or nil
end

-- The guild's ranks, the first one first: { index, name }, the index
-- counted from 0 as the roster counts. From the client's own list, else
-- from the ranks the roster's members hold.
function Identity.Ranks()
	local list = {}
	local count = Get(GuildControlGetNumRanks)
	if type(count) == "number" and count > 0 and Fn(GuildControlGetRankName) then
		for order = 1, math.min(count, 20) do
			local name = Get(GuildControlGetRankName, order)
			if type(name) == "string" and name ~= "" and name ~= SECRET then
				list[#list + 1] = { index = order - 1, name = name }
			end
		end
		if #list > 0 then return list end
	end
	local seen = {}
	for _, member in pairs(roster.byCanon) do
		local index, name = member.rankIndex, member.rankName
		if type(index) == "number" and type(name) == "string" and name ~= SECRET and not seen[index] then
			seen[index] = true
			list[#list + 1] = { index = index, name = name }
		end
	end
	table.sort(list, function(a, b) return a.index < b.index end)
	return list
end

-- The rank of the character played now, 0 for the guild's first. The
-- roster and the client each say it: when they differ, a promotion or a
-- demotion is on its way, and the lower rank is the one believed.
function Identity.MyRankIndex()
	local member = me.tail and roster.byTail[me.tail]
	local listed = member and type(member.rankIndex) == "number" and member.rankIndex or nil
	local own = type(me.rankIndex) == "number" and me.rankIndex or nil
	if listed and own then return math.max(listed, own) end
	return listed or own
end

-- The permission table of a guild rank, 0-based index like the roster gives.
function Identity.RankFlags(rankIndex)
	if type(rankIndex) ~= "number" then return nil end
	local fn = C_GuildInfo and Fn(C_GuildInfo.GuildControlGetRankFlags) or Fn(GuildControlGetRankFlags)
	if not fn then return nil end
	local ok, flags = pcall(fn, rankIndex + 1)
	if not ok or type(flags) ~= "table" or Util.IsSecretTable(flags) then return nil end
	return flags
end

-- Officers are the ranks allowed to speak in officer chat, whatever their
-- names, so the addon works for any guild without settings.
function Identity.IsOfficerRank(rankIndex)
	if type(rankIndex) ~= "number" then return false end
	if officerFlagTrusted then
		local flags = Identity.RankFlags(rankIndex)
		if flags then
			local flag = Safe(flags[OFFICER_SPEAK_FLAG])
			if type(flag) == "boolean" then return flag end
		end
	end
	return rankIndex <= 1
end

function Identity.IsOfficer()
	if C_GuildInfo and Fn(C_GuildInfo.IsGuildOfficer) then
		local value = Get(C_GuildInfo.IsGuildOfficer)
		if type(value) == "boolean" then return value end
	end
	return Identity.IsOfficerRank(me.rankIndex)
end

-- Compares the flag reading with the client's own answer for our rank, once
-- per login, and records what the rank table looks like for the developer.
function Identity.CheckOfficerFlag()
	if not ns.db or type(me.rankIndex) ~= "number" then return end
	local flags = Identity.RankFlags(me.rankIndex)
	local answer = C_GuildInfo and Fn(C_GuildInfo.IsGuildOfficer) and Get(C_GuildInfo.IsGuildOfficer) or nil
	local trueFlags = {}
	if flags then
		for index = 1, 32 do
			if Safe(flags[index]) == true then trueFlags[#trueFlags + 1] = index end
		end
	end
	local byFlag = flags and Safe(flags[OFFICER_SPEAK_FLAG]) or nil
	ns.db.debug.officerFlag = {
		at = Util.Now(), rankIndex = me.rankIndex, rankName = me.rankName,
		isOfficer = answer, byFlag = byFlag, trueFlags = table.concat(trueFlags, " "),
	}
	if type(answer) == "boolean" and type(byFlag) == "boolean" and answer ~= byFlag then
		officerFlagTrusted = false
		ns.Count("officerFlagMismatch")
	end
end

--------------------------------------------------------------------------------
-- Other players
--------------------------------------------------------------------------------

-- How the game itself rates a unit against the character played, the way
-- it colours a level on the target frame: T trivial (grey), E easy (green),
-- F fair (yellow), D difficult (orange), I impossible (red), and S when the
-- level is hidden, too high to be told (the skull). nil when the client
-- does not say: the addon rates nothing by itself.
local CON_LETTER = { Trivial = "T", Easy = "E", Fair = "F", Difficult = "D", Impossible = "I" }
Identity.CONS = { T = true, E = true, F = true, D = true, I = true, S = true }

function Identity.Con(token, level)
	if type(level) == "number" and level < 0 then return "S" end
	local rate = type(C_PlayerInfo) == "table" and Fn(C_PlayerInfo.GetContentDifficultyCreatureForPlayer)
	local names = type(Enum) == "table" and Enum.RelativeContentDifficulty
	if not rate or type(names) ~= "table" then return nil end
	local value = Get(rate, token)
	if type(value) ~= "number" then return nil end
	for name, letter in pairs(CON_LETTER) do
		if names[name] == value then return letter end
	end
	return nil
end

-- What the client tells about a player GUID we are allowed to read.
function Identity.PlayerFacts(guid)
	local facts = { kind = Util.GuidKind(guid) }
	if facts.kind ~= "Player" then return facts end
	facts.guid = guid
	facts.tail = Util.Tail(guid)
	local _, class, _, race, _, name, realm = Get(GetPlayerInfoByGUID, guid)
	facts.class, facts.race, facts.name, facts.realm = class, race, name, realm
	facts.factionGuess = type(race) == "string" and RACE_FACTION[race] or nil
	local token = Get(UnitTokenFromGUID, guid)
	if type(token) == "string" and token ~= SECRET then
		facts.token = token
		facts.level = Get(UnitLevel, token)
		facts.con = Identity.Con(token, facts.level)
		facts.faction = Get(UnitFactionGroup, token)
		facts.guild = Get(GetGuildInfo, token)
	end
	return facts
end

-- The faction a GUID belongs to, from a unit token when one exists, else from
-- the race. nil when unknown.
function Identity.FactionOf(facts)
	if type(facts) ~= "table" then return nil end
	if type(facts.faction) == "string" and facts.faction ~= SECRET then return facts.faction end
	return facts.factionGuess
end

function Identity.IsEnemy(facts)
	local faction = Identity.FactionOf(facts)
	return faction ~= nil and me.enemyFaction ~= nil and faction == me.enemyFaction
end

--------------------------------------------------------------------------------
-- Role of a character
--
-- Tank, healer or damage: what the character's player says it plays, chosen
-- in the Me tab. Forever's talents are one free tree, with nothing in the
-- client that names a role for it, so the addon does not guess one.
--------------------------------------------------------------------------------

Identity.ROLES = { "T", "H", "D" }
local IS_ROLE = { T = true, H = true, D = true }

function Identity.IsRole(value)
	return IS_ROLE[value] == true
end

-- Whether a character is one of this game account's: its state is kept here.
function Identity.IsOwn(guid)
	return type(guid) == "string" and ns.db ~= nil and ns.db.characters[guid] ~= nil
end

-- The role of one of this account's characters, the one played now when
-- none is named; nil until one is chosen.
function Identity.Role(guid)
	guid = guid or me.guid
	if not (guid and ns.db) then return nil end
	local character = ns.db.characters[guid]
	local role = character and character.role
	return IS_ROLE[role] and role or nil
end

-- Takes effect at once; nil removes it. The role of the character played
-- now goes out with its profile. Another character of the account cannot
-- speak while it is offline: the one played says its role for it.
function Identity.SetRole(role, guid)
	guid = guid or me.guid
	if not (guid and ns.db) then return nil end
	role = IS_ROLE[role] and role or nil
	local character = guid == me.guid and ns.Db.Character(guid) or ns.db.characters[guid]
	if not character then return nil end
	if character.role == role then return role end
	character.role = role
	if ns.Fire then
		if guid == me.guid then
			ns.Fire("RoleChanged", role)
		else
			ns.Fire("CharacterRoleChanged", guid, role)
		end
	end
	return role
end

--------------------------------------------------------------------------------
-- Display name of a player
--------------------------------------------------------------------------------

function Identity.Alias()
	local alias = ns.db and ns.db.settings.alias
	if type(alias) == "string" and alias ~= "" then return alias end
	return nil
end

-- A display name as it is kept: trimmed, cleaned, at most 24 letters ("" for none).
function Identity.CleanAlias(text)
	if type(text) ~= "string" then return "" end
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	text = Util.Clean(text)
	if #text > 24 then text = (Util.Cut(text, 24)) end
	return text
end

-- Takes effect at once and goes out with the profile; the same name again does nothing.
function Identity.SetAlias(text)
	text = Identity.CleanAlias(text)
	local alias = text ~= "" and text or nil
	if alias == Identity.Alias() then return alias end
	ns.db.settings.alias = alias
	if ns.Fire then ns.Fire("AliasChanged", alias) end
	return alias
end

--------------------------------------------------------------------------------
-- Main character of a player
--
-- Which of its characters a player calls its main: chosen in the Me tab,
-- kept for the account, and said to the guild in the profile of whichever
-- of its characters is played. The others are then its alts.
--------------------------------------------------------------------------------

function Identity.Main()
	local guid = ns.db and ns.db.settings.main
	if type(guid) == "string" and Util.Tail(guid) then return guid end
	return nil
end

-- Takes effect at once and goes out with the profile; nil says none.
function Identity.SetMain(guid)
	if type(guid) ~= "string" or not Util.Tail(guid) then guid = nil end
	if guid == Identity.Main() then return guid end
	ns.db.settings.main = guid
	if ns.Fire then ns.Fire("MainChanged", guid) end
	return guid
end
