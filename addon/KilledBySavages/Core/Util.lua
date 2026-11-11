local _, ns = ...

--------------------------------------------------------------------------------
-- Utilities shared by every module
--
-- On Forever an API can hand back a "secret" value: an addon can pass it
-- around but not read, compare or print it, and trying raises an error. Every
-- value is turned into something plain before it is kept or looked at, and
-- every call goes through pcall, so a refusal is recorded, never a crash.
--------------------------------------------------------------------------------

local Util = {}
ns.Util = Util

local SECRET = "<secret>"
Util.SECRET = SECRET

local function Fn(value)
	return type(value) == "function" and value or nil
end
Util.Fn = Fn

local isSecret = Fn(issecretvalue) or function() return false end
local isSecretTable = Fn(issecrettable) or function() return false end
Util.IsSecret = isSecret
Util.IsSecretTable = isSecretTable

-- A plain copy of a value: secrets become a marker, tables and functions a
-- type name.
local function Safe(value)
	if isSecret(value) then return SECRET end
	local kind = type(value)
	if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
		return value
	end
	return "<" .. kind .. ">"
end
Util.Safe = Safe

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
function Util.Get(fn, ...)
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

-- Like Get, but keeps every return in a table, and the error of a failed call.
function Util.Call(fn, ...)
	if not Fn(fn) then return { n = 0, missing = true } end
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
Util.Dump = Dump

function Util.Round(number, places)
	local scale = 10 ^ (places or 4)
	return math.floor(number * scale + 0.5) / scale
end

-- Server time: the same on every client, which is what records carry.
function Util.Now()
	local value = Util.Get(GetServerTime)
	if type(value) == "number" then return value end
	return Fn(time) and time() or 0
end

-- Client uptime, with fractions: for ordering events within a second.
function Util.Clock()
	local value = Util.Get(GetTime)
	return type(value) == "number" and value or 0
end

function Util.Stamp(at, withSeconds)
	local format = Fn(date)
	if not format or type(at) ~= "number" then return tostring(at) end
	return format(withSeconds and "%Y-%m-%d %H:%M:%S" or "%Y-%m-%d %H:%M", at)
end

--------------------------------------------------------------------------------
-- Text
--------------------------------------------------------------------------------

-- At most max bytes, never splitting a UTF-8 character in two.
function Util.Cut(text, max)
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

-- A name as a search compares it: lower case, accents and ligatures taken
-- off, so "sor" finds "Søren" and "MELI" finds "Méliné". Latin letters
-- only, which is what Forever names are made of; anything else stays as is.
local FOLD = {}
do
	local letters = {
		a = "àáâãäåāăąÀÁÂÃÄÅĀĂĄ", c = "çćĉċčÇĆĈĊČ", d = "ďđĎĐ", e = "èéêëēĕėęěÈÉÊËĒĔĖĘĚ", g = "ĝğġģĜĞĠĢ", h = "ĥħĤĦ",
		i = "ìíîïĩīĭįıÌÍÎÏĨĪĬĮİ", j = "ĵĴ", k = "ķĶ", l = "ĺļľŀłĹĻĽĿŁ", n = "ñńņňÑŃŅŇ", o = "òóôõöøōŏőÒÓÔÕÖØŌŎŐ",
		r = "ŕŗřŔŖŘ", s = "śŝşšŚŜŞŠ", t = "ţťŧŢŤŦ", u = "ùúûüũūŭůűųÙÚÛÜŨŪŬŮŰŲ", w = "ŵŴ", y = "ýÿŷÝŸŶ", z = "źżžŹŻŽ",
		ae = "æÆ", oe = "œŒ", ss = "ß", th = "þÞ",
	}
	for plain, accented in pairs(letters) do
		for character in accented:gmatch("[\195-\197][\128-\191]") do FOLD[character] = plain end
	end
end

function Util.Fold(text)
	if type(text) ~= "string" or text == SECRET then return "" end
	return (text:lower():gsub("[\195-\197][\128-\191]", FOLD))
end

-- Records use ';' between fields and messages use '^'; names and zone texts
-- never need those characters, nor UI escapes, so they are flattened.
function Util.Clean(value)
	return (tostring(value):gsub("[;=%^|,\r\n]", " "))
end

-- Forever names are a first name and a surname. The client spells them
-- "First Last" in the roster and GetPlayerInfoByGUID, keeps them apart in
-- UnitName, and "First-Last" in WTF folders; a realm suffix may also follow.
-- Canon brings any of these to one comparable form.
function Util.Canon(name, realms)
	if type(name) ~= "string" or name == SECRET or name == "" then return nil end
	for _, realm in ipairs(realms or {}) do
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

function Util.Hash(text)
	local hash = 2166136261
	for index = 1, #text do
		local low = hash % 256
		hash = hash - low + Xor8(low, text:byte(index))
		-- hash * 16777619 mod 2^32, with 16777619 = 2^24 + 403, kept exact.
		hash = ((hash % 256) * 16777216 + hash * 403) % 4294967296
	end
	return ("%04x%04x"):format(math.floor(hash / 65536), hash % 65536)
end

function Util.RandomHex(length)
	local out = {}
	for index = 1, length do
		out[index] = ("%x"):format(math.random(0, 15))
	end
	return table.concat(out)
end

--------------------------------------------------------------------------------
-- GUIDs
--------------------------------------------------------------------------------

-- "Player-6938-0012ABCD" -> "6938-0012ABCD": the server id stays, because the
-- hex part alone collides between realms of one guild.
function Util.Tail(guid)
	if type(guid) ~= "string" then return nil end
	return guid:match("^Player%-(%d+%-%x+)$")
end

function Util.GuidKind(guid)
	if isSecret(guid) then return "secret" end
	if type(guid) ~= "string" then return "nil" end
	return guid:match("^(%a+)") or "?"
end

-- COMBATLOG_OBJECT_TYPE_PLAYER is bit 0x400 of the unit flags.
function Util.FlagsSayPlayer(flags)
	if type(flags) ~= "number" then return nil end
	return math.floor(flags / 1024) % 2 == 1
end

function Util.EnumName(enumTable, value)
	if type(enumTable) == "table" then
		for name, known in pairs(enumTable) do
			if known == value then return name end
		end
	end
	return tostring(value)
end

--------------------------------------------------------------------------------
-- Where we are
--------------------------------------------------------------------------------

-- The two buckets the board uses, plus the odd cases.
function Util.Bucket()
	local _, instanceType = Util.Get(IsInInstance)
	if instanceType == "pvp" then return "bg" end
	if instanceType == nil or instanceType == "none" then return "world" end
	if instanceType == SECRET then return "unknown" end
	return "instance"
end

-- Our own position on the zone map: where a kill happened, give or take the
-- distance to the victim. status tells whether the client let us read it.
function Util.Position()
	local position = {}
	if not (C_Map and Fn(C_Map.GetBestMapForUnit) and Fn(C_Map.GetPlayerMapPosition)) then
		position.status = "missing"
		return position
	end
	local okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player")
	if not okMap then
		position.status = "error"
		return position
	end
	if isSecret(mapID) then
		position.status = "secret"
		return position
	end
	if type(mapID) ~= "number" then
		position.status = "nomap"
		return position
	end
	position.mapID = mapID
	local okPos, vector = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
	if not okPos then
		position.status = "error"
	elseif isSecret(vector) then
		position.status = "secret"
	elseif type(vector) ~= "table" then
		position.status = "nil"
	else
		local x, y
		if Fn(vector.GetXY) then
			x, y = Util.Get(vector.GetXY, vector)
		else
			x, y = Safe(vector.x), Safe(vector.y)
		end
		if x == SECRET or y == SECRET then
			position.status = "secret"
		elseif type(x) == "number" and type(y) == "number" then
			position.status = "ok"
			position.x, position.y = Util.Round(x, 4), Util.Round(y, 4)
		else
			position.status = "nil"
		end
	end
	return position
end

--------------------------------------------------------------------------------
-- Time periods
--------------------------------------------------------------------------------

local WEEK = 7 * 24 * 3600
Util.WEEK = WEEK

-- The start of the week holding t, given any instant at which a weekly reset
-- happened or will happen (the anchor).
function Util.WeekStart(t, anchor)
	return t - ((t - anchor) % WEEK)
end

--------------------------------------------------------------------------------
-- Guarded execution
--
-- Every handler and timer runs through here: a failure is recorded in the
-- SavedVariables (see Db), never shown to a player, and never stops the next
-- event from being handled.
--------------------------------------------------------------------------------

function Util.Guard(where, fn, ...)
	if not Fn(fn) then return false end
	local ok, message = pcall(fn, ...)
	if not ok and ns.Error then pcall(ns.Error, where, message) end
	return ok
end

function Util.After(delay, where, fn, a, b)
	if not (C_Timer and Fn(C_Timer.After)) then return end
	C_Timer.After(delay, function() Util.Guard(where, fn, a, b) end)
end

function Util.Every(interval, where, fn, a)
	local function tick()
		Util.Guard(where, fn, a)
		Util.After(interval, where, tick)
	end
	Util.After(interval, where, tick)
end
