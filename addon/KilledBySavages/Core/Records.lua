local _, ns = ...

--------------------------------------------------------------------------------
-- Records
--
-- Every character is the author of its own journal: an append-only list of
-- records numbered 1..head. A record is a compact string, versioned by its
-- first field, stored as is and decoded on demand. The journal travels
-- between guild members unchanged, so the format is frozen from v0.1: a
-- client ignores record types and versions it does not know.
--
--   K1  kill      seq;t;bucket;how;vtail;vname;vclass;vrace;vlevel;mapID;x;y;guild;lifeHK;sub;vcon
--                 (vcon since 1.0.3: how the game rated the victim against
--                 the author, T E F D I, or S for a level it hid; see Identity.Con)
--   B1  backfill  the same fields: a kill the character's probe saw before
--                 the addon's first count (see Import), counted like a kill
--                 at its own time, but outside the chain: lifeHK repeats the
--                 record before it, since the count the addon started from
--                 already held this HK
--   D1  death     seq;t;bucket;ktail;kname;kclass;krace;kkind;spell;mapID;x;y;lifeHK;sub;klevel;kcon
--                 (klevel and kcon since 1.0.3: the killer's level and rating,
--                 when the client still knew it as a unit)
--   M1  match     seq;t;instanceID;duration;winner;hk;kb;deaths;honor;damage;healing;lifeHK;live;mapID;lines
--   C1  backfill  the same fields: a match the probe saw before the addon's
--                 first count, credited like a match, outside the chain
--   X1  counter   seq;t;bucket;fromHK;toHK            (HKs the server counted with no detail)
--   P1  profile   name;class;race;realm;playerKey;alias;level;baselineHK;lifeHK;version;role;main
--                 (role since 1.0.1; main since 1.0.3: the tail of the player's
--                 main character, "-" when its player names none)
--
-- A match record is the end-of-battleground scoreboard: my own row, then
-- one line per guild teammate on the board (tail:name:kb:hk:deaths:honor,
-- comma separated), credited to them with or without the addon. live is
-- how many of the match's HKs were already recorded live as kills. A
-- scoreboard with instanceID 0 is one outside any instance: a guild raid in
-- the world written by hand, whose lines credit world kills.
--
-- lifeHK is the character's lifetime honorable kills right after the event:
-- the server's own count, which chains the records of an author together.
--------------------------------------------------------------------------------

local Util = ns.Util
local Clean = Util.Clean

local Records = {}
ns.Records = Records

Records.HOW = { kb = true, pet = true, grp = true, ast = true, unk = true, bg = true }
Records.MAX_LINES = 40
Records.BUCKET = { w = true, b = true, u = true }
Records.PAGE = 200
-- No journal is that long: 270 records a day for ten years. A seq or a head
-- above it is nobody's, whoever says it, and every loop over a journal is
-- bounded by it.
Records.MAX_SEQ = 1000000
local MAX_FUTURE = 300
local MAX_LEVEL = 60
local MAX_COUNT = 100000000     -- no lifetime count is that high
local MAX_TEXT = 64             -- bytes of a name, a spell or a place

-- Decoded records, by their text. Kept for the session on purpose: the
-- stats hold the same tables for as long as they hold a journal's numbers.
local decoded = {}

-- A number, or nothing: neither a NaN nor an infinity ever leaves here.
local function Num(text)
	if text == nil or text == "" then return nil end
	local number = tonumber(text)
	if number ~= number or number == math.huge or number == -math.huge then return nil end
	return number
end

local function Str(text)
	if text == nil or text == "" then return nil end
	return text
end

-- A text another client wrote: a name, a spell, a place. Cut when it is
-- longer than any of those can be.
local function Text(text)
	if text == nil or text == "" then return nil end
	if #text > MAX_TEXT then return (Util.Cut(text, MAX_TEXT)) end
	return text
end

-- What no honest client writes into a record (Util.Clean takes them out
-- when encoding): the UI's escape character and control characters. The
-- bytes are named one by one, so no locale decides what a control
-- character is. Sync takes them out of whatever another client sends, as
-- it comes in; here a record is only searched for the escape character,
-- which costs next to nothing, in case it was stored before that.
Records.UNCLEAN = "[%z\1-\31\127|]"

-- The fields of a record or a profile that carries such bytes, each made
-- plain.
local function Plain(fields)
	for index = 1, #fields do
		fields[index] = fields[index]:gsub(Records.UNCLEAN, " ")
	end
	return fields
end

-- A character level, or nil for anything else.
local function Level(text)
	local level = Num(text)
	if level and level >= 1 and level <= MAX_LEVEL and level % 1 == 0 then return level end
	return nil
end

local function Field(value)
	if value == nil then return "" end
	if type(value) == "number" then
		if value % 1 == 0 then return ("%d"):format(value) end
		return ("%.4f"):format(value):gsub("0+$", ""):gsub("%.$", "")
	end
	return Clean(value)
end

local function Join(...)
	local fields = {}
	for index = 1, select("#", ...) do
		fields[index] = Field((select(index, ...)))
	end
	return table.concat(fields, ";")
end

-- The fields of a record. Kills, deaths and matches have sixteen or
-- seventeen: one pattern cuts them, faster than field by field. Anything
-- else is cut field by field, however many it has.
local FIELD = "([^;]*)"
local SEVENTEEN = "^" .. FIELD .. (";" .. FIELD):rep(15) .. ";?" .. FIELD .. "$"

local function Split(text)
	local fields = { text:match(SEVENTEEN) }
	if fields[1] then return fields end
	for field in (text .. ";"):gmatch("([^;]*);") do
		fields[#fields + 1] = field
	end
	return fields
end

--------------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------------

function Records.EncodeKill(r)
	return Join(r.backfill and "B1" or "K1", r.seq, r.t, r.bucket, r.how, r.vtail, r.vname, r.vclass, r.vrace, r.vlevel,
		r.mapID, r.x, r.y, r.guild, r.lifeHK, r.sub, r.vcon)
end

function Records.EncodeDeath(r)
	return Join("D1", r.seq, r.t, r.bucket, r.ktail, r.kname, r.kclass, r.krace, r.kkind, r.spell,
		r.mapID, r.x, r.y, r.lifeHK, r.sub, r.klevel, r.kcon)
end

-- One scoreboard line: tail:name:kb:hk:deaths:honor. Built from cleaned
-- parts, outside Field, so its own separators survive.
local function EncodeLine(line)
	local name = Clean(line.name or ""):gsub(":", " ")
	return ("%s:%s:%d:%d:%d:%d"):format(line.tail or "", name, line.kb or 0, line.hk or 0, line.deaths or 0, line.honor or 0)
end

local function DecodeLines(text)
	local lines = {}
	if type(text) ~= "string" or text == "" then return lines end
	for piece in (text .. ","):gmatch("([^,]*),") do
		local tail, name, kb, hk, deaths, honor = piece:match("^([^:]*):([^:]*):(%d+):(%d+):(%d+):(%d+)$")
		if tail then
			lines[#lines + 1] = { tail = tail ~= "" and tail or nil, name = Text(name),
				kb = tonumber(kb), hk = tonumber(hk), deaths = tonumber(deaths), honor = tonumber(honor) }
		end
	end
	return lines
end

function Records.EncodeMatch(r)
	local lines = {}
	for index, line in ipairs(r.lines or {}) do
		if index > Records.MAX_LINES then break end
		lines[#lines + 1] = EncodeLine(line)
	end
	return Join(r.backfill and "C1" or "M1", r.seq, r.t, r.instanceID, r.duration, r.winner, r.hk, r.kb, r.deaths, r.honor, r.damage, r.healing,
		r.lifeHK, r.live, r.mapID) .. ";" .. table.concat(lines, ",")
end

function Records.EncodeCounter(r)
	return Join("X1", r.seq, r.t, r.bucket, r.fromHK, r.toHK)
end

function Records.EncodeProfile(p)
	-- "-" is a player who names no main; nothing is a version that says
	-- nothing of it, and must stay nothing when a holder passes it on.
	return Join("P1", p.name, p.class, p.race, p.realm, p.playerKey, p.alias, p.level, p.baselineHK, p.lifeHK, p.version, p.role,
		p.main == false and "-" or p.main)
end

function Records.Encode(r)
	if r.type == "K" then return Records.EncodeKill(r) end
	if r.type == "D" then return Records.EncodeDeath(r) end
	if r.type == "M" then return Records.EncodeMatch(r) end
	if r.type == "X" then return Records.EncodeCounter(r) end
	return nil
end

--------------------------------------------------------------------------------
-- Decoding
--------------------------------------------------------------------------------

local function DecodeFields(f)
	local kind = f[1]
	if kind == "K1" or kind == "B1" then
		-- The fields nearly every kill has, then the rare ones only when they
		-- are there: a table is sized by the fields its constructor names, and
		-- one more than sixteen doubles it. Journals are held by the thousand.
		local record = {
			type = "K", seq = Num(f[2]), t = Num(f[3]), bucket = Str(f[4]), how = Str(f[5]),
			vtail = Str(f[6]), vname = Text(f[7]), vclass = Str(f[8]), vrace = Str(f[9]), vlevel = Num(f[10]),
			mapID = Num(f[11]), x = Num(f[12]), y = Num(f[13]), guild = Text(f[14]), lifeHK = Num(f[15]),
		}
		if kind == "B1" then record.backfill = true end
		local sub = Text(f[16])
		if sub then record.sub = sub end
		-- Since 1.0.3, last. A rating this version does not know reads as none.
		if ns.Identity.CONS[f[17]] then record.vcon = f[17] end
		return record
	elseif kind == "D1" then
		local record = {
			type = "D", seq = Num(f[2]), t = Num(f[3]), bucket = Str(f[4]),
			ktail = Str(f[5]), kname = Text(f[6]), kclass = Str(f[7]), krace = Text(f[8]), kkind = Str(f[9]),
			spell = Text(f[10]), mapID = Num(f[11]), x = Num(f[12]), y = Num(f[13]), lifeHK = Num(f[14]),
		}
		local sub = Text(f[15])
		if sub then record.sub = sub end
		-- Since 1.0.3, last. A level out of range or an unknown rating reads as none.
		local level = Level(f[16])
		if level then record.klevel = level end
		if ns.Identity.CONS[f[17]] then record.kcon = f[17] end
		return record
	elseif kind == "M1" or kind == "C1" then
		return {
			type = "M", backfill = kind == "C1" or nil, seq = Num(f[2]), t = Num(f[3]), bucket = "b", instanceID = Num(f[4]), duration = Num(f[5]),
			winner = Num(f[6]), hk = Num(f[7]) or 0, kb = Num(f[8]) or 0, deaths = Num(f[9]) or 0, honor = Num(f[10]),
			damage = Num(f[11]), healing = Num(f[12]), lifeHK = Num(f[13]), live = Num(f[14]) or 0, mapID = Num(f[15]),
			lines = DecodeLines(f[16]),
		}
	elseif kind == "X1" then
		return { type = "X", seq = Num(f[2]), t = Num(f[3]), bucket = Str(f[4]), fromHK = Num(f[5]), toHK = Num(f[6]) }
	end
	return nil
end

-- A decoded record, or nil for a type this version does not know. Decoded
-- tables are cached per string.
function Records.Decode(text)
	if type(text) ~= "string" then return nil end
	local cached = decoded[text]
	if cached ~= nil then return cached or nil end
	local fields = Split(text)
	if text:find("|", 1, true) then Plain(fields) end
	local record = DecodeFields(fields)
	decoded[text] = record or false
	return record
end

function Records.DecodeProfile(text)
	if type(text) ~= "string" then return nil end
	local f = Split(text)
	if f[1] ~= "P1" then return nil end
	if text:find("|", 1, true) then Plain(f) end
	-- Since 1.0.3, last: the player's main character, by its tail; false when
	-- its player names none; nil from a version that says nothing of it.
	local main
	if f[13] == "-" then
		main = false
	elseif type(f[13]) == "string" then
		main = f[13]:match("^%d+%-%x+$")
	end
	return {
		name = Text(f[2]), class = Text(f[3]), race = Text(f[4]), realm = Text(f[5]), playerKey = Text(f[6]),
		alias = Text(f[7]), level = Num(f[8]), baselineHK = Num(f[9]), lifeHK = Num(f[10]), version = Text(f[11]),
		-- Since 1.0.1, at the end: versions before read the fields by
		-- position and never look this far.
		role = ns.Identity.IsRole(f[12]) and f[12] or nil,
		main = main,
	}
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

local function IsTail(text)
	return type(text) == "string" and text:match("^%d+%-%x+$") ~= nil
end

local function IsToken(text, max)
	return type(text) == "string" and #text <= (max or 16) and text:match("^[%a_]+$") ~= nil
end

-- Whether a decoded record is plausible on its own. now bounds the time.
function Records.Validate(r, now)
	if type(r) ~= "table" then return false, "nil" end
	if type(r.seq) ~= "number" or r.seq < 1 or r.seq > Records.MAX_SEQ or r.seq % 1 ~= 0 then return false, "seq" end
	if type(r.t) ~= "number" or r.t < 1 then return false, "time" end
	if now and r.t > now + MAX_FUTURE then return false, "future" end
	if r.type == "K" then
		if not Records.BUCKET[r.bucket] or r.bucket == "u" then return false, "bucket" end
		if not Records.HOW[r.how] then return false, "how" end
		if r.vtail ~= nil and not IsTail(r.vtail) then return false, "victim" end
		if r.how ~= "unk" and r.how ~= "bg" and r.vtail == nil then return false, "victim" end
		if r.vclass ~= nil and not IsToken(r.vclass) then return false, "class" end
		if r.vrace ~= nil and not IsToken(r.vrace) then return false, "race" end
		if r.vlevel ~= nil and (r.vlevel < 1 or r.vlevel > MAX_LEVEL) then return false, "level" end
		if type(r.lifeHK) ~= "number" or r.lifeHK < 0 or r.lifeHK > MAX_COUNT then return false, "lifeHK" end
	elseif r.type == "D" then
		if not Records.BUCKET[r.bucket] or r.bucket == "u" then return false, "bucket" end
		if r.kkind ~= "p" and r.kkind ~= "e" then return false, "killer" end
		if r.ktail ~= nil and not IsTail(r.ktail) then return false, "killer" end
		if r.kclass ~= nil and not IsToken(r.kclass) then return false, "class" end
		if type(r.lifeHK) ~= "number" or r.lifeHK < 0 or r.lifeHK > MAX_COUNT then return false, "lifeHK" end
	elseif r.type == "M" then
		if type(r.hk) ~= "number" or r.hk < 0 or r.hk > 500 then return false, "hk" end
		if type(r.kb) ~= "number" or r.kb < 0 or r.kb > 200 then return false, "kb" end
		if type(r.deaths) ~= "number" or r.deaths < 0 or r.deaths > 200 then return false, "deaths" end
		if type(r.live) ~= "number" or r.live < 0 or r.live > r.hk then return false, "live" end
		if type(r.lifeHK) ~= "number" or r.lifeHK < 0 or r.lifeHK > MAX_COUNT then return false, "lifeHK" end
		if #(r.lines or {}) > Records.MAX_LINES then return false, "lines" end
		for _, line in ipairs(r.lines or {}) do
			if line.tail ~= nil and not IsTail(line.tail) then return false, "lines" end
			if line.hk > 500 or line.kb > 200 or line.deaths > 200 then return false, "lines" end
		end
	elseif r.type == "X" then
		if not Records.BUCKET[r.bucket] then return false, "bucket" end
		if type(r.fromHK) ~= "number" or type(r.toHK) ~= "number" or r.toHK <= r.fromHK then return false, "range" end
		if r.fromHK < 0 or r.toHK > MAX_COUNT then return false, "range" end
	else
		return false, "type"
	end
	return true
end

-- How many HKs a record adds to the author's lifetime count. A match adds
-- only the HKs not already recorded live during it; a backfill kill adds
-- none, the count the addon started from already had it.
function Records.Gain(r)
	if r.backfill then return 0 end
	if r.type == "K" then return 1 end
	if r.type == "M" then return math.max(0, (r.hk or 0) - (r.live or 0)) end
	if r.type == "X" then return r.toHK - r.fromHK end
	return 0
end

-- Whether two match records describe the same battleground: the same
-- instance, closed within two minutes of each other. Members write theirs
-- within seconds; a fixed window would split a match closed across its edge.
local MATCH_TOLERANCE = 120
function Records.SameMatch(a, b)
	if a.instanceID ~= b.instanceID then return false end
	return math.abs((a.t or 0) - (b.t or 0)) <= MATCH_TOLERANCE
end

-- Whether a match record was written with no scoreboard read: the counter's
-- delta at leaving, or what the journal held of a match nothing closed. It
-- knows its author's honorable kills and the deaths the journal wrote: no
-- killing blow, no honor, no teammate. A scoreboard written by hand
-- (instance 0) and a backfilled match are scoreboards.
function Records.NoScoreboard(r)
	return r.type == "M" and r.instanceID ~= 0 and not r.backfill and r.damage == nil and r.healing == nil
		and (r.kb or 0) == 0 and (r.honor or 0) == 0 and (r.lines == nil or #r.lines == 0)
end

-- The lifetime count a record leaves behind.
function Records.LifeAfter(r)
	if r.type == "X" then return r.toHK end
	return r.lifeHK
end

-- Checks that consecutive records (seq n and n+1) agree on the lifetime
-- count: each K adds one, a match adds its hk, a counter record jumps to
-- its toHK, a death changes nothing. Gaps are not checked. Returns false and
-- the first seq that breaks the chain.
function Records.CheckChain(list)
	table.sort(list, function(a, b) return a.seq < b.seq end)
	for index = 2, #list do
		local previous, current = list[index - 1], list[index]
		if current.seq == previous.seq + 1 then
			local before = Records.LifeAfter(previous)
			local after = Records.LifeAfter(current)
			if type(before) == "number" and type(after) == "number" then
				local expected = current.type == "X" and current.fromHK or (before + Records.Gain(current))
				if current.type == "X" then
					if before ~= expected then return false, current.seq end
				elseif after ~= expected then
					return false, current.seq
				end
			end
		end
	end
	return true
end

--------------------------------------------------------------------------------
-- Journals
--------------------------------------------------------------------------------

-- The journal of an author, created empty when unknown.
function Records.Author(guid)
	local authors = ns.db.authors
	local author = authors[guid]
	if not author then
		author = { head = 0, count = 0, log = {}, pages = {}, missing = {} }
		authors[guid] = author
		-- A member's journal counts from the start, before its first record.
		Records.Rescope()
	end
	return author
end

--------------------------------------------------------------------------------
-- The journals of the guild
--
-- The saved data is the account's: it holds the journals of every guild
-- any of its characters plays in, and of members who left. Only those of
-- the guild played now count on the board and are handed to its members.
-- A journal is the guild's when its character is in the roster; else the
-- guild it was last seen in is kept with it (a member who left stays the
-- guild's), and a journal never seen in a roster goes by the guild its
-- last kill names. Out of a guild, the character played has its own alone.
-- A journal belongs to one guild at a time: that of its character.
--------------------------------------------------------------------------------

local GUILD_LOOK = 400           -- how far back from its head a journal is read for a kill that names a guild
local scope                      -- guid -> true, for the guild played now
local unnamed = {}               -- guid -> the head at which no kill of the journal named a guild

-- The guild of a journal: its name, false for none, nil when nothing says.
local function GuildOf(guid, author)
	local Identity = ns.Identity
	local me = Identity.me
	local playing = Identity.InGuild() and me.guild or false
	if guid == me.guid or (playing and Identity.MemberByTail(Util.Tail(guid))) then
		author.guild = playing
		return playing
	end
	if author.guild ~= nil then return author.guild end
	local head = author.head or 0
	if unnamed[guid] == head then return nil end
	for seq = head, math.max(1, head - GUILD_LOOK), -1 do
		local record = Records.Get(guid, seq)
		if record and record.type == "K" and record.guild then
			author.guild = record.guild
			return author.guild
		end
	end
	unnamed[guid] = head
	return nil
end

function Records.Scope()
	if scope then return scope end
	scope = {}
	local me = ns.Identity.me
	local playing = ns.Identity.InGuild() and me.guild or nil
	for guid, author in pairs(ns.db.authors) do
		local guild = GuildOf(guid, author)
		if guid == me.guid or (playing and guild == playing) then scope[guid] = true end
	end
	return scope
end

function Records.InGuild(guid)
	return Records.Scope()[guid] == true
end

-- Whether a journal is known to be another guild's. One nothing says the
-- guild of is not: it is not counted, and is still asked for, since the
-- page that names its guild may be the next one.
function Records.Foreign(guid)
	if Records.Scope()[guid] then return false end
	local author = ns.db.authors[guid]
	return author ~= nil and author.guild ~= nil
end

-- The roster, the guild or the journals held changed: the set is made
-- again, and whoever keeps numbers of it is told when it is another.
function Records.Rescope()
	local before = scope
	if not before or not ns.db then
		scope = nil
		return
	end
	scope = nil
	local now = Records.Scope()
	local same = true
	for guid in pairs(before) do
		if not now[guid] then same = false end
	end
	for guid in pairs(now) do
		if not before[guid] then same = false end
	end
	if not same then ns.Fire("ScopeChanged") end
end

ns.Hook("RosterUpdated", Records.Rescope)
ns.Hook("GuildChanged", Records.Rescope)
ns.Hook("JournalChanged", Records.Rescope)
ns.Hook("Login", Records.Rescope)
-- The client can be late saying who we are and in which guild: looked at
-- again once the world is there.
ns.Hook("EnteringWorld", Records.Rescope)

--------------------------------------------------------------------------------
-- Packed pages
--
-- A page of 200 records that is complete and old is kept as one deflated
-- string instead of 200 entries: the SavedVariables stay small and the
-- game loads them faster. Packed pages are unpacked on demand and cached.
--------------------------------------------------------------------------------

local unpacked = setmetatable({}, { __mode = "k" })   -- author -> { [page] = { [seq] = text } }

local function PageOf(seq)
	return math.floor((seq - 1) / Records.PAGE) + 1
end
Records.PageOf = PageOf

function Records.PageRange(page)
	return (page - 1) * Records.PAGE + 1, page * Records.PAGE
end

local function LibDeflate()
	return LibStub and LibStub("LibDeflate", true)
end

-- The records of a packed page, seq -> text, or nil when not packed.
function Records.UnpackPage(author, page)
	local packed = author.pages and author.pages[page]
	if not packed then return nil end
	local cache = unpacked[author]
	if cache and cache[page] then return cache[page] end
	local deflate = LibDeflate()
	if not deflate then return nil end
	local raw = deflate:DecodeForPrint(packed)
	local text = raw and deflate:DecompressDeflate(raw)
	if not text then return nil end
	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		if line ~= "" then
			local seq = tonumber(line:match("^%a%d+;(%d+);"))
			if seq then lines[seq] = line end
		end
	end
	cache = cache or {}
	cache[page] = lines
	unpacked[author] = cache
	return lines
end

-- The raw deflated bytes of a packed page, for Sync to re-encode for the
-- addon channel without inflating it.
function Records.PackedBytes(author, page)
	local packed = author.pages and author.pages[page]
	local deflate = LibDeflate()
	if not packed or not deflate then return nil end
	return deflate:DecodeForPrint(packed)
end

-- The text of one record, wherever it is kept.
function Records.Line(guid, seq)
	local author = ns.db.authors[guid]
	if not author then return nil end
	local text = author.log[seq]
	if text then return text end
	if author.pages and author.pages[PageOf(seq)] then
		local lines = Records.UnpackPage(author, PageOf(seq))
		return lines and lines[seq] or nil
	end
	return nil
end

function Records.Has(author, seq)
	if author.log[seq] then return true end
	return author.pages ~= nil and author.pages[PageOf(seq)] ~= nil
end

-- A journal with far more room than records: the newest page of a long
-- one fetched first, or a head nobody could have earned. It is walked by
-- what it holds, in seq order, whatever its head says.
local SPARSE_SLACK = 1000
local function EachSparse(author, head, fn)
	ns.Count("records.walkedSparse")
	local seqs = {}
	for seq in pairs(author.log) do
		if type(seq) == "number" and seq <= head then seqs[#seqs + 1] = seq end
	end
	for page in pairs(author.pages or {}) do
		local lines = Records.UnpackPage(author, page)
		for seq in pairs(lines or {}) do
			if seq <= head and not author.log[seq] then seqs[#seqs + 1] = seq end
		end
	end
	table.sort(seqs)
	for index = 1, #seqs do
		local seq = seqs[index]
		local text = author.log[seq]
		if not text then
			local lines = Records.UnpackPage(author, PageOf(seq))
			text = lines and lines[seq]
		end
		local record = text and Records.Decode(text)
		if record then fn(record, text, seq) end
	end
end

-- Every record of an author, decoded, in seq order (holes skipped). Page
-- by page: a packed page is unpacked once, and each seq costs one lookup.
function Records.Each(guid, fn)
	local author = ns.db.authors[guid]
	if not author then return end
	local head = author.head or 0
	if head < 1 then return end
	if head > (author.count or 0) * 4 + SPARSE_SLACK then return EachSparse(author, head, fn) end
	local log, pages, size = author.log, author.pages, Records.PAGE
	for page = 1, PageOf(head) do
		local packed = pages and pages[page] and Records.UnpackPage(author, page) or nil
		local last = page * size
		if last > head then last = head end
		for seq = (page - 1) * size + 1, last do
			local text = log[seq] or (packed and packed[seq])
			if text then
				local record = decoded[text]
				if record == nil then record = Records.Decode(text) end
				if record then fn(record, text, seq) end
			end
		end
	end
end

-- The head and the count of a journal, from what it holds: after a purge,
-- or when the saved data says something no journal can be. A packed page
-- is complete by construction.
function Records.Recount(author)
	local head, count = 0, 0
	for seq in pairs(author.log) do
		if type(seq) == "number" and seq >= 1 and seq <= Records.MAX_SEQ and seq % 1 == 0 then
			count = count + 1
			if seq > head then head = seq end
		else
			author.log[seq] = nil
		end
	end
	for page in pairs(author.pages or {}) do
		local _, last = Records.PageRange(page)
		count = count + Records.PAGE
		if last > head then head = last end
	end
	author.head, author.count = head, count
	return head, count
end

-- Saved data is taken as it is, but for a head no journal can have: loops
-- run up to it.
ns.Hook("Init", function()
	for _, author in pairs(ns.db.authors) do
		if type(author) == "table" then
			if type(author.log) ~= "table" then author.log = {} end
			local head = author.head
			if type(head) ~= "number" or head < 0 or head > Records.MAX_SEQ or head % 1 ~= 0 then
				Records.Recount(author)
				ns.Count("records.headRepaired")
			end
		end
	end
end)

-- Packs one complete page of an author. Returns true when done.
function Records.PackPage(guid, page)
	local author = ns.db.authors[guid]
	local deflate = LibDeflate()
	if not author or not deflate then return false end
	if author.pages and author.pages[page] then return true end
	local from, to = Records.PageRange(page)
	local lines = {}
	for seq = from, to do
		local text = author.log[seq]
		if not text then return false end
		lines[#lines + 1] = text
	end
	-- Level 5: half the time of the highest level for two percent more bytes.
	local raw = deflate:CompressDeflate(table.concat(lines, "\n"), { level = 5 })
	author.pages = author.pages or {}
	author.pages[page] = deflate:EncodeForPrint(raw)
	for seq = from, to do
		author.log[seq] = nil
	end
	if unpacked[author] then unpacked[author][page] = nil end
	return true
end

-- Packs the complete pages whose records are all older than a time, for
-- every author: all of them, or a number of them at most. Returns the
-- number of pages packed.
function Records.Compact(olderThan, limit)
	local packed = 0
	for guid, author in pairs(ns.db.authors) do
		local lastPage = PageOf(math.max(author.head or 0, 1)) - 1
		for page = 1, lastPage do
			if not (author.pages and author.pages[page]) then
				local _, to = Records.PageRange(page)
				local last = author.log[to] and Records.Decode(author.log[to])
				if last and type(last.t) == "number" and last.t < olderThan and Records.PackPage(guid, page) then
					packed = packed + 1
					if limit and packed >= limit then
						ns.Count("records.packed", packed)
						return packed
					end
				end
			end
		end
	end
	if packed > 0 then ns.Count("records.packed", packed) end
	return packed
end

function Records.Get(guid, seq)
	local text = Records.Line(guid, seq)
	return text and Records.Decode(text) or nil, text
end

-- Puts a received record into an author's journal. source is "author",
-- "page" or "relay". An existing seq with different content is replaced only
-- by the author's own copy.
function Records.Store(guid, seq, text, source)
	local author = Records.Author(guid)
	if author.pages and author.pages[PageOf(seq)] then return false, "packed" end
	local existing = author.log[seq]
	if existing then
		if existing == text then return false, "same" end
		if source ~= "author" then
			ns.Count("records.conflictKept")
			return false, "conflict"
		end
		ns.Count("records.conflictReplaced")
		author.log[seq] = text
		return true, "replaced"
	end
	author.log[seq] = text
	author.count = (author.count or 0) + 1
	if seq > (author.head or 0) then author.head = seq end
	if source ~= "author" then author.relayed = (author.relayed or 0) + 1 end
	-- A journal no roster ever named goes by its kills: this record may be
	-- the one that says whose guild it is.
	if author.guild == nil and scope and not scope[guid] then Records.Rescope() end
	return true, "added"
end

-- While Sync recovers the records a crash lost, new ones wait unnumbered:
-- their seq must come after the recovered head. They are saved with the
-- character while they wait: a /reload then must not lose them.
local held = {}
local holding = false

local function KeepHeld()
	local me = ns.Identity.me
	if me.guid then ns.Db.Character(me.guid).held = #held > 0 and held or nil end
end

-- The records the last session left waiting, back in their order. Returns
-- how many.
function Records.RestoreHeld()
	local me = ns.Identity.me
	if not me.guid then return 0 end
	local saved = ns.Db.Character(me.guid).held
	if type(saved) == "table" then
		for _, record in ipairs(saved) do
			if type(record) == "table" and type(record.type) == "string" then
				record.seq = nil
				held[#held + 1] = record
			end
		end
	end
	KeepHeld()
	return #held
end

-- HoldOwn(false) stops holding without appending what waits: ReleaseOwn
-- does that, once whatever must come first is in.
function Records.HoldOwn(state)
	holding = state ~= false
end

function Records.ReleaseOwn()
	holding = false
	local list = held
	held = {}
	KeepHeld()
	for _, record in ipairs(list) do
		Records.AppendOwn(record)
	end
end

function Records.Holding()
	return holding, #held
end

-- Appends a record to our own journal and tells the other modules. source
-- says where it came from when it is not a live event ("import").
function Records.AppendOwn(record, source)
	local me = ns.Identity.me
	if not me.guid then return nil end
	if holding then
		held[#held + 1] = record
		KeepHeld()
		return nil
	end
	local author = Records.Author(me.guid)
	author.own = true
	record.seq = (author.head or 0) + 1
	-- A record that adds no HK carries the count the chain stands at, not
	-- the counter of the moment: a death during the seconds an HK waits to
	-- be matched would otherwise carry the HK of the kill written after it.
	if Records.Gain(record) == 0 and record.type ~= "X" then
		local previous = Records.Get(me.guid, record.seq - 1)
		local after = previous and Records.LifeAfter(previous)
		if type(after) == "number" then record.lifeHK = after end
	end
	local text = Records.Encode(record)
	if not text then return nil end
	author.log[record.seq] = text
	author.head = record.seq
	author.count = (author.count or 0) + 1
	author.confirmedHead = record.seq
	ns.Count("records.own." .. record.type)
	ns.Fire("RecordAdded", me.guid, record.seq, text, record, source)
	return record.seq, text
end

-- Repairs our own journal where a record that adds no HK (a death, a
-- backfill) carries a count the chain does not stand at: versions before
-- 0.1.10 wrote a death during a pending kill with the kill's count, and
-- the page then failed every member's chain check. Records that add HKs
-- are never touched. Returns how many records were rewritten.
function Records.HealOwn()
	local me = ns.Identity.me
	if not me.guid then return 0 end
	local author = ns.db.authors[me.guid]
	if not author or (author.head or 0) == 0 then return 0 end
	local healed = 0
	local previous
	for seq = 1, author.head do
		local text = author.log[seq]
		local record = text and Records.Decode(text) or nil
		if record then
			if previous and record.seq == previous.seq + 1 and Records.Gain(record) == 0 and record.type ~= "X" then
				local after = Records.LifeAfter(previous)
				if type(after) == "number" and record.lifeHK ~= after then
					local copy = {}
					for key, value in pairs(record) do copy[key] = value end
					copy.lifeHK = after
					local fixed = Records.Encode(copy)
					if fixed then
						author.log[seq] = fixed
						record = Records.Decode(fixed)
						healed = healed + 1
					end
				end
			end
			previous = record
		end
	end
	if healed > 0 then
		ns.Count("records.healed", healed)
		ns.Fire("JournalChanged", me.guid)
	end
	return healed
end

-- Our own profile, from what the client says now.
function Records.OwnProfile()
	local me = ns.Identity.me
	local char = ns.Db.Character(me.guid)
	local profile = {
		name = me.name, class = me.class, race = me.race, realm = me.realm, playerKey = me.playerKey,
		alias = ns.Identity.Alias(), level = me.level, baselineHK = char.baselineHK, lifeHK = char.lifeHK,
		version = ns.VERSION, role = ns.Identity.Role(), main = Util.Tail(ns.Identity.Main()) or false,
	}
	local author = Records.Author(me.guid)
	author.own = true
	author.profile = profile
	return profile
end

-- The records of an author in a seq range, decoded, holes skipped.
function Records.Range(guid, from, to)
	local list = {}
	for seq = from, to do
		local record = Records.Get(guid, seq)
		if record then list[#list + 1] = record end
	end
	return list
end
