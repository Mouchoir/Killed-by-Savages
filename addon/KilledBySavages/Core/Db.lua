local _, ns = ...

--------------------------------------------------------------------------------
-- SavedVariables
--
-- KilledBySavagesDB is account-wide, written by the game at logout or
-- /reload. It holds every character's own journal and the journals received
-- from the guild, keyed by character GUID, never by name.
--------------------------------------------------------------------------------

local Util = ns.Util

local Db = {}
ns.Db = Db

local SCHEMA = 1
local ERROR_CAP = 50

local DEFAULT_SETTINGS = {
	minimap = { hide = false },
	killfeed = false,                     -- the guild's kill lines in the chat, off by default
	killfeedTab = true,                   -- in a chat tab of their own, else the main chat
	scale = 1,
	window = {},
	verbose = false,
	updates = true,                       -- remind of a newer release: chat line, dialog on the board
	-- updateSkip: the one release not to remind of, a version, set from the dialog
	-- main: the GUID of the character its player calls its main, set in the Me tab
}

local function Fill(target, defaults)
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			if type(target[key]) ~= "table" then target[key] = {} end
			Fill(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
	return target
end

local function Migrate(db)
	-- Nothing to migrate yet: schema 1 is the first shape.
	db.schema = SCHEMA
end

function Db.Init()
	local db = KilledBySavagesDB
	if type(db) ~= "table" then db = {} end
	KilledBySavagesDB = db
	ns.db = db
	db.schema = db.schema or SCHEMA
	db.settings = Fill(db.settings or {}, DEFAULT_SETTINGS)
	-- Up to 0.1.13 guild kills were also announced in the main chat, on by
	-- default; since 0.1.14 the kill lines only go to the kill feed's tab.
	db.settings.announce = nil
	db.characters = db.characters or {}   -- own characters: [guid] = their state
	-- Up to 1.0.0 the kill feed opened its own chat tab and kept its index
	-- here; the player makes the tab now.
	for _, character in pairs(db.characters) do
		if type(character) == "table" then character.feedTab = nil end
	end
	db.authors = db.authors or {}         -- every journal held, own ones included
	db.pending = db.pending or {}         -- HKs not matched yet (a /reload may interrupt)
	db.rules = db.rules or {}             -- the rule on ranks of each guild, by guild name (see Ranks)
	db.errors = db.errors or {}
	db.counters = db.counters or {}
	db.debug = db.debug or {}
	if type(db.accountId) ~= "string" or #db.accountId ~= 8 then
		-- Groups the characters of this WoW account when the BattleTag is not
		-- readable. Random, never derived from anything personal.
		db.accountId = Util.RandomHex(8)
	end
	if db.schema < SCHEMA then Migrate(db) end
	return db
end

function Db.Settings()
	return ns.db.settings
end

-- The state of one of our own characters.
function Db.Character(guid)
	local characters = ns.db.characters
	local entry = characters[guid]
	if not entry then
		entry = { createdAt = Util.Now() }
		characters[guid] = entry
	end
	return entry
end

function Db.Verbose()
	return ns.db and ns.db.settings.verbose
end

--------------------------------------------------------------------------------
-- Diagnostics, kept in the SavedVariables for /kbs debug
--------------------------------------------------------------------------------

function ns.Count(key, amount)
	if not ns.db then return end
	local counters = ns.db.counters
	counters[key] = (counters[key] or 0) + (amount or 1)
end

function ns.Error(where, message)
	if not ns.db then return end
	local errors = ns.db.errors
	errors[#errors + 1] = { at = Util.Now(), where = tostring(where), message = Util.Safe(message) }
	while #errors > ERROR_CAP do
		table.remove(errors, 1)
	end
	ns.Count("errors")
	if Db.Verbose() and ns.Print then
		ns.Print(("error in %s: %s"):format(tostring(where), tostring(Util.Safe(message))))
	end
end
