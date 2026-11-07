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
--   K1  kill      seq;t;bucket;how;vtail;vname;vclass;vrace;vlevel;mapID;x;y;guild;lifeHK;sub
--   B1  backfill  the same fields: a kill the character's probe saw before
--                 the addon's first count (see Import), counted like a kill
--                 at its own time, but outside the chain: lifeHK repeats the
--                 record before it, since the count the addon started from
--                 already held this HK
--   D1  death     seq;t;bucket;ktail;kname;kclass;krace;kkind;spell;mapID;x;y;lifeHK;sub
--   M1  match     seq;t;instanceID;duration;winner;hk;kb;deaths;honor;damage;healing;lifeHK;live;mapID;lines
--   C1  backfill  the same fields: a match the probe saw before the addon's
--                 first count, credited like a match, outside the chain
--   X1  counter   seq;t;bucket;fromHK;toHK            (HKs the server counted with no detail)
--   P1  profile   name;class;race;realm;playerKey;alias;level;baselineHK;lifeHK;version
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
local MAX_FUTURE = 300
local MAX_LEVEL = 60

local decoded = setmetatable({}, { __mode = "k" })

local function Num(text)
	if text == nil or text == "" then return nil end
	return tonumber(text)
end

local function Str(text)
	if text == nil or text == "" then return nil end
	return text
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

local function Split(text)
	local fields = {}
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
		r.mapID, r.x, r.y, r.guild, r.lifeHK, r.sub)
end

function Records.EncodeDeath(r)
	return Join("D1", r.seq, r.t, r.bucket, r.ktail, r.kname, r.kclass, r.krace, r.kkind, r.spell,
		r.mapID, r.x, r.y, r.lifeHK, r.sub)
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
			lines[#lines + 1] = { tail = tail ~= "" and tail or nil, name = name ~= "" and name or nil,
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
	return Join("P1", p.name, p.class, p.race, p.realm, p.playerKey, p.alias, p.level, p.baselineHK, p.lifeHK, p.version)
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
		return {
			type = "K", backfill = kind == "B1" or nil, seq = Num(f[2]), t = Num(f[3]), bucket = Str(f[4]), how = Str(f[5]),
			vtail = Str(f[6]), vname = Str(f[7]), vclass = Str(f[8]), vrace = Str(f[9]), vlevel = Num(f[10]),
			mapID = Num(f[11]), x = Num(f[12]), y = Num(f[13]), guild = Str(f[14]), lifeHK = Num(f[15]), sub = Str(f[16]),
		}
	elseif kind == "D1" then
		return {
			type = "D", seq = Num(f[2]), t = Num(f[3]), bucket = Str(f[4]),
			ktail = Str(f[5]), kname = Str(f[6]), kclass = Str(f[7]), krace = Str(f[8]), kkind = Str(f[9]),
			spell = Str(f[10]), mapID = Num(f[11]), x = Num(f[12]), y = Num(f[13]), lifeHK = Num(f[14]), sub = Str(f[15]),
		}
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
	local record = DecodeFields(Split(text))
	decoded[text] = record or false
	return record
end

function Records.DecodeProfile(text)
	if type(text) ~= "string" then return nil end
	local f = Split(text)
	if f[1] ~= "P1" then return nil end
	return {
		name = Str(f[2]), class = Str(f[3]), race = Str(f[4]), realm = Str(f[5]), playerKey = Str(f[6]),
		alias = Str(f[7]), level = Num(f[8]), baselineHK = Num(f[9]), lifeHK = Num(f[10]), version = Str(f[11]),
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
	if type(r.seq) ~= "number" or r.seq < 1 or r.seq % 1 ~= 0 then return false, "seq" end
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
		if type(r.lifeHK) ~= "number" or r.lifeHK < 0 then return false, "lifeHK" end
	elseif r.type == "D" then
		if not Records.BUCKET[r.bucket] or r.bucket == "u" then return false, "bucket" end
		if r.kkind ~= "p" and r.kkind ~= "e" then return false, "killer" end
		if r.ktail ~= nil and not IsTail(r.ktail) then return false, "killer" end
		if r.kclass ~= nil and not IsToken(r.kclass) then return false, "class" end
		if type(r.lifeHK) ~= "number" or r.lifeHK < 0 then return false, "lifeHK" end
	elseif r.type == "M" then
		if type(r.hk) ~= "number" or r.hk < 0 or r.hk > 500 then return false, "hk" end
		if type(r.kb) ~= "number" or r.kb < 0 or r.kb > 200 then return false, "kb" end
		if type(r.deaths) ~= "number" or r.deaths < 0 or r.deaths > 200 then return false, "deaths" end
		if type(r.live) ~= "number" or r.live < 0 or r.live > r.hk then return false, "live" end
		if type(r.lifeHK) ~= "number" or r.lifeHK < 0 then return false, "lifeHK" end
		if #(r.lines or {}) > Records.MAX_LINES then return false, "lines" end
		for _, line in ipairs(r.lines or {}) do
			if line.tail ~= nil and not IsTail(line.tail) then return false, "lines" end
			if line.hk > 500 or line.kb > 200 or line.deaths > 200 then return false, "lines" end
		end
	elseif r.type == "X" then
		if not Records.BUCKET[r.bucket] then return false, "bucket" end
		if type(r.fromHK) ~= "number" or type(r.toHK) ~= "number" or r.toHK <= r.fromHK then return false, "range" end
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

-- A match is the same for every member who was in it: the instance and
-- the minute it ended.
function Records.MatchKey(r)
	return tostring(r.instanceID or "?") .. ":" .. tostring(math.floor((r.t or 0) / 120))
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
	end
	return author
end

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

-- Every record of an author, decoded, in seq order (holes skipped).
function Records.Each(guid, fn)
	local author = ns.db.authors[guid]
	if not author then return end
	for seq = 1, author.head or 0 do
		local text = Records.Line(guid, seq)
		if text then
			local record = Records.Decode(text)
			if record then fn(record, text, seq) end
		end
	end
end

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
	local raw = deflate:CompressDeflate(table.concat(lines, "\n"), { level = 9 })
	author.pages = author.pages or {}
	author.pages[page] = deflate:EncodeForPrint(raw)
	for seq = from, to do
		author.log[seq] = nil
	end
	if unpacked[author] then unpacked[author][page] = nil end
	return true
end

-- Packs every complete page whose records are all older than a time, for
-- every author. Returns the number of pages packed.
function Records.Compact(olderThan)
	local packed = 0
	for guid, author in pairs(ns.db.authors) do
		local lastPage = PageOf(math.max(author.head or 0, 1)) - 1
		for page = 1, lastPage do
			if not (author.pages and author.pages[page]) then
				local _, to = Records.PageRange(page)
				local last = author.log[to] and Records.Decode(author.log[to])
				if last and type(last.t) == "number" and last.t < olderThan and Records.PackPage(guid, page) then
					packed = packed + 1
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
	return true, "added"
end

-- While Sync recovers the records a crash lost, new ones wait unnumbered:
-- their seq must come after the recovered head.
local held = {}
local holding = false

-- HoldOwn(false) stops holding without appending what waits: ReleaseOwn
-- does that, once whatever must come first is in.
function Records.HoldOwn(state)
	holding = state ~= false
end

function Records.ReleaseOwn()
	holding = false
	local list = held
	held = {}
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
		version = ns.VERSION,
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
