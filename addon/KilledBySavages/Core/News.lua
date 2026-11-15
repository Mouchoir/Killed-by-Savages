local _, ns = ...

--------------------------------------------------------------------------------
-- Guild announcements
--
-- An addon reads nothing outside the game: an announcement made on Discord
-- gets here when a member allowed to publish writes it in the board (title,
-- date of the event, a few lines, the link of the Discord message, and whom
-- it is for). The guild then holds it the way it holds the journals: said
-- once on the guild channel, and handed by whoever has it to a member who
-- logs in later.
--
-- Whom it is for is told with what the addon knows of a character: its
-- guild rank, its class, the role its player chose, its level. A member it
-- is not for does not see it, and is not told of it.
--
-- A member it is for is told while the event is still to come and the
-- announcement has not been looked at: a line in the chat, a count on the
-- board's tab, a minimap button that blinks. Looking at it once ends that;
-- an event that passes ends it too, seen or not. The player can turn the
-- telling off for good.
--
-- Who may publish is a rule of the guild's first rank, like the rule on
-- ranks: every rank from the first down to the one it names. Until it says
-- otherwise, the two first ranks.
--
-- Nothing here is proved: there is no server, and a copy handed on by a
-- third member cannot be told from its author's own. What is checked is
-- that every field is within bounds, that the one who wrote it is a member
-- of the guild and, each time it is to be shown, that it holds a rank
-- allowed to publish in the roster now. See the README on trust.
--
--   N  one chunk of an announcement   N^id^rev^index^total^data
--   L  what a member holds            L^ruleAt^part^parts^id=rev,id=rev
--   W  a member wants one             W^id        (W^rule: the rule)
--   T  who may publish                T^at^rankIndex^rankName
--
-- An id is its first author's tail and the second it was written. rev is
-- when it was last written: the latest wins, a removal included.
--------------------------------------------------------------------------------

local Util = ns.Util
local Identity = ns.Identity
local L = ns.L

local News = {}
ns.News = News

News.TITLE_MAX, News.TEXT_MAX, News.LINK_MAX = 60, 600, 160
local CHUNK = 180                 -- bytes of an announcement in one message
local MAX_CHUNKS = 10
local MAX_FUTURE = 300            -- a writing dated further ahead than this is refused
local HORIZON = 400 * 86400       -- an event is at most this far ahead
local KEEP = 14 * 86400           -- a past event is kept this long
local LISTED = 86400              -- and still told to the guild this long, so a late correction or removal gets around
local MAX_ITEMS = 30
local MAX_LISTED = 12
local LIST_BYTES = 200
local PARTIAL_LIFE = 90
local WANT_GAP = 30               -- seconds before the same announcement is asked for again
local SERVE_GAP = 20              -- seconds before the same member is served the same one again
local ANSWER_MIN, ANSWER_MAX = 2, 20
local LOGIN_LIST = 50             -- seconds after login, once the hello is out
local LOGIN_TELL = 12
local DEFAULT_RANK = 1            -- until the first rank says otherwise: the two first ranks publish
local MAX_INDEX = 19
local MAX_LEVEL = 100
local ID = "^%d+%-%x+%.%d+$"

local partial = {}                -- chunks of announcements not whole yet, by sender, id and rev
local wanted = {}                 -- id -> when it was last asked for
local served = {}                 -- member and id -> when it was last handed over
local lists = {}                  -- sender -> the parts of its list heard so far
local heard = { at = 0, ruleAt = 0, revs = {} }   -- what the lists heard lately said, for an answer not to repeat them
local answerDue = false
local lastUnseen = 0
local remindAt                    -- from when the login's reminder may be said, until it is

local function Now()
	return Util.Now()
end

local function Guild()
	return Identity.InGuild() and Identity.me.guild or nil
end

-- What is kept for the guild played now: the announcements, which of them
-- this account looked at, and which it was told of in the chat.
local function Store()
	local guild = Guild()
	if not guild or not ns.db then return nil end
	local store = ns.db.news[guild]
	if type(store) ~= "table" then
		store = {}
		ns.db.news[guild] = store
	end
	store.items = type(store.items) == "table" and store.items or {}
	store.seen = type(store.seen) == "table" and store.seen or {}
	store.told = type(store.told) == "table" and store.told or {}
	return store
end

local function Changed()
	ns.Fire("NewsChanged")
end

--------------------------------------------------------------------------------
-- Who may publish
--------------------------------------------------------------------------------

local function Rule()
	local guild = Guild()
	local rule = guild and ns.db and ns.db.newsRules[guild] or nil
	return type(rule) == "table" and type(rule.index) == "number" and rule or nil
end

-- The last rank that may publish, counted from 0 like the roster. A rule
-- whose rank no longer carries the name it had rests until it is set again:
-- only the first rank publishes meanwhile.
function News.Limit()
	local rule = Rule()
	if not rule then return DEFAULT_RANK end
	if ns.Ranks.Holds(rule) then return rule.index end
	return 0, "renamed"
end

function News.MayPublish(rankIndex)
	return type(rankIndex) == "number" and rankIndex <= (News.Limit())
end

function News.CanPublish()
	return Guild() ~= nil and News.MayPublish(Identity.MyRankIndex())
end

function News.IsMaster()
	return Guild() ~= nil and Identity.MyRankIndex() == 0
end

local function RuleLine(rule)
	return ("T^%d^%d^%s"):format(rule.at, rule.index, rule.name or "")
end

-- The first rank names the last rank that may publish, and tells the guild.
function News.SetLimit(index)
	if not News.IsMaster() or type(index) ~= "number" or index < 0 or index > MAX_INDEX or index % 1 ~= 0 then return false end
	local part = ns.Ranks.Part(index)
	local rule = { at = Now(), index = index, name = part.name }
	local previous = Rule()
	if previous and (previous.at or 0) >= rule.at then rule.at = previous.at + 1 end
	ns.db.newsRules[Guild()] = rule
	ns.Count("news.ruleSet")
	Changed()
	if ns.Sync then ns.Sync.Say("T", RuleLine(rule), 1) end
	return true
end

-- The rule heard from a member: the latest one wins. It is handed on like
-- an announcement, so it reaches a member while the first rank is offline.
local function OnRule(sender, text)
	if not Identity.Member(sender) or not Guild() then return false end
	local at, index, name = text:match("^T%^(%d+)%^(%d+)%^([^%^]*)$")
	at, index = tonumber(at), tonumber(index)
	if not at or at > Now() + MAX_FUTURE or not index or index > MAX_INDEX then
		ns.Count("news.ruleBad")
		return false
	end
	local held = Rule()
	if held and (held.at or 0) >= at then return false end
	ns.db.newsRules[Guild()] = { at = at, index = index, name = ns.Ranks.Short(name) }
	ns.Count("news.ruleReceived")
	Changed()
	-- What the rule now lets through is told like anything new.
	News.Tell()
	return true
end

--------------------------------------------------------------------------------
-- Text in, text out
--------------------------------------------------------------------------------

-- Text as it is kept: no escape code, no control character, trimmed, cut
-- to a number of bytes. A description keeps its line breaks, two in a row
-- at most.
local function Tidy(text, max, lines)
	text = tostring(text or ""):gsub("\r", "")
	if lines then
		text = text:gsub("[%z\1-\9\11-\31\127|]", " "):gsub("\n\n\n+", "\n\n")
	else
		text = text:gsub("[%z\1-\31\127|]", " ")
	end
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	if #text > max then text = (Util.Cut(text, max)):gsub("%s+$", "") end
	return text
end
News.Tidy = Tidy

-- A link is a web address or nothing.
local function Link(text)
	text = Tidy(text, News.LINK_MAX + 1)
	if text == "" or #text > News.LINK_MAX or text:find("%s") or not text:match("^https?://[%w%-%.]+[%w%p]*$") then return nil end
	return text
end
News.Link = Link

local function Escape(text)
	return (text:gsub("~", "~t"):gsub("%^", "~c"):gsub("\n", "~n"))
end

local UNESCAPE = { t = "~", c = "^", n = "\n" }
local function Unescape(text)
	return (text:gsub("~([tcn])", UNESCAPE))
end

local function SetOf(list, valid)
	local set, any = {}, false
	for _, value in ipairs(list) do
		if valid(value) then
			set[value] = true
			any = true
		end
	end
	return any and set or nil
end

local function Sorted(set)
	local list = {}
	for value in pairs(set or {}) do list[#list + 1] = value end
	table.sort(list, function(a, b) return tostring(a) < tostring(b) end)
	return list
end

local function IsRank(value)
	return type(value) == "number" and value >= 0 and value <= MAX_INDEX and value % 1 == 0
end

local function IsClass(value)
	return type(value) == "string" and #value <= 16 and value:match("^%u+$") ~= nil
end

local function Encode(item)
	if item.removed then return ("%s^%d^-"):format(item.by, item.when) end
	local roles = table.concat(Sorted(item.roles))
	return table.concat({
		item.by, ("%d"):format(item.when), Escape(item.title), Escape(item.link or ""),
		table.concat(Sorted(item.ranks), "."), table.concat(Sorted(item.classes), "."), roles,
		item.level and ("%d"):format(item.level) or "", Escape(item.text or ""),
	}, "^")
end

-- An announcement from what a member sent, or nothing when a field is not
-- what it should be.
local function Decode(id, rev, payload)
	local fields = {}
	for field in (payload .. "^"):gmatch("([^%^]*)%^") do fields[#fields + 1] = field end
	local by, when = fields[1], tonumber(fields[2])
	local now = Now()
	if type(by) ~= "string" or not by:match("^%d+%-%x+$") then return nil, "by" end
	if not when or when % 1 ~= 0 or when < now - KEEP or when > now + HORIZON then return nil, "when" end
	local created = tonumber(id:match("%.(%d+)$"))
	if not created or rev < created or rev > now + MAX_FUTURE then return nil, "rev" end
	local item = { id = id, rev = rev, by = by, when = when }
	if fields[3] == "-" and #fields == 3 then
		item.removed = true
		return item
	end
	if #fields ~= 9 then return nil, "fields" end
	item.title = Tidy(Unescape(fields[3]), News.TITLE_MAX)
	if item.title == "" then return nil, "title" end
	item.link = Link(Unescape(fields[4]))
	local ranks, classes, roles = {}, {}, {}
	for value in fields[5]:gmatch("[^%.]+") do ranks[#ranks + 1] = tonumber(value) end
	for value in fields[6]:gmatch("[^%.]+") do classes[#classes + 1] = value end
	for value in fields[7]:gmatch(".") do roles[#roles + 1] = value end
	item.ranks, item.classes, item.roles = SetOf(ranks, IsRank), SetOf(classes, IsClass), SetOf(roles, Identity.IsRole)
	local level = tonumber(fields[8])
	if level and level >= 2 and level <= MAX_LEVEL and level % 1 == 0 then item.level = level end
	item.text = Tidy(Unescape(fields[9]), News.TEXT_MAX, true)
	return item
end

--------------------------------------------------------------------------------
-- What is held
--------------------------------------------------------------------------------

-- Past events go after a while, and the oldest when there are too many.
local function Trim(store)
	local now, count = Now(), 0
	for id, item in pairs(store.items) do
		if type(item) ~= "table" or type(item.when) ~= "number" or type(item.rev) ~= "number" or item.when < now - KEEP then
			store.items[id] = nil
		else
			count = count + 1
		end
	end
	while count > MAX_ITEMS do
		local oldest
		for id, item in pairs(store.items) do
			if not oldest or item.when < store.items[oldest].when or (item.when == store.items[oldest].when and id < oldest) then oldest = id end
		end
		store.items[oldest] = nil
		count = count - 1
	end
	for id in pairs(store.seen) do
		if not store.items[id] then store.seen[id] = nil end
	end
	for id in pairs(store.told) do
		if not store.items[id] then store.told[id] = nil end
	end
end

-- Whether the one who wrote it still holds a rank that may publish. The
-- roster says, each time it is asked: a demotion takes the announcement
-- away, with no memory of it.
local function Rightful(item)
	local member = Identity.MemberByTail(item.by)
	return member ~= nil and News.MayPublish(member.rankIndex)
end

-- Whether an announcement is for the character played now. What the addon
-- does not know of it (no role chosen, a level the client hides) never
-- keeps it out: better told once too often than not at all.
function News.ForMe(item)
	local me = Identity.me
	if item.by == me.tail then return true end
	if item.ranks then
		local rank = Identity.MyRankIndex()
		if type(rank) ~= "number" or not item.ranks[rank] then return false end
	end
	if item.classes and me.class and not item.classes[me.class] then return false end
	if item.roles then
		local role = Identity.Role()
		if role and not item.roles[role] then return false end
	end
	if item.level and type(me.level) == "number" and me.level < item.level then return false end
	return true
end

-- The announcements the board shows: those for the character played, and
-- all of them for a member who may publish. Events to come first, the
-- nearest on top, then the past ones, the latest on top.
function News.Shown()
	local store = Store()
	local list = {}
	if not store then return list end
	local now, all = Now(), News.CanPublish()
	for _, item in pairs(store.items) do
		if not item.removed and Rightful(item) and (all or News.ForMe(item)) then list[#list + 1] = item end
	end
	table.sort(list, function(a, b)
		local comingA, comingB = a.when > now, b.when > now
		if comingA ~= comingB then return comingA end
		if a.when ~= b.when then
			if comingA then return a.when < b.when end
			return a.when > b.when
		end
		return a.id < b.id
	end)
	return list
end

function News.Get(id)
	local store = Store()
	return store and store.items[id] or nil
end

function News.IsSeen(item)
	local store = Store()
	return store ~= nil and (store.seen[item.id] or 0) >= item.rev
end

-- Whether the player wants to be told of announcements.
function News.Notifies()
	return ns.db ~= nil and ns.db.settings.news ~= false
end

function News.SetNotify(on)
	ns.db.settings.news = on and true or false
	ns.Count(on and "news.notifyOn" or "news.notifyOff")
	Changed()
	ns.Fire("SettingsChanged")
end

-- What the player is still to be told of: for the character played, the
-- event to come, never looked at since it was last written.
function News.Unseen()
	local store = Store()
	local list = {}
	if not store or not News.Notifies() then return list end
	local now = Now()
	for _, item in pairs(store.items) do
		if not item.removed and item.when > now and (store.seen[item.id] or 0) < item.rev and Rightful(item) and News.ForMe(item) then
			list[#list + 1] = item
		end
	end
	table.sort(list, function(a, b)
		if a.when ~= b.when then return a.when < b.when end
		return a.id < b.id
	end)
	return list
end

function News.MarkSeen(id)
	local store = Store()
	local item = store and store.items[id]
	if not item or (store.seen[id] or 0) >= item.rev then return false end
	store.seen[id] = item.rev
	ns.Count("news.seen")
	Changed()
	return true
end

-- One line in the chat for what the player was not told of yet.
function News.Tell()
	local store = Store()
	if not store then return end
	local fresh = 0
	for _, item in ipairs(News.Unseen()) do
		if (store.told[item.id] or 0) < item.rev then
			store.told[item.id] = item.rev
			fresh = fresh + 1
		end
	end
	if fresh > 0 then
		ns.Print(fresh == 1 and L.NEWS_CHAT_ONE or L.NEWS_CHAT_MANY:format(fresh))
		ns.Count("news.told")
	end
end

--------------------------------------------------------------------------------
-- Telling the guild
--------------------------------------------------------------------------------

local function Send(item, target)
	if not ns.Sync then return 0 end
	local payload = Encode(item)
	local total = math.max(1, math.ceil(#payload / CHUNK))
	for index = 1, total do
		local text = ("N^%s^%d^%d^%d^%s"):format(item.id, item.rev, index, total, payload:sub((index - 1) * CHUNK + 1, index * CHUNK))
		if target then
			ns.Sync.Tell("N", text, target, 3)
		else
			ns.Sync.Say("N", text, 2)
		end
	end
	ns.Count(target and "news.handed" or "news.said")
	return total
end

-- The announcements worth telling the guild of: events to come, and those
-- of the last day. The latest written first when there are too many.
local function Listed()
	local store = Store()
	local list = {}
	if not store then return list end
	local now = Now()
	for _, item in pairs(store.items) do
		if item.when > now - LISTED then list[#list + 1] = item end
	end
	table.sort(list, function(a, b)
		if a.rev ~= b.rev then return a.rev > b.rev end
		return a.id < b.id
	end)
	for index = #list, MAX_LISTED + 1, -1 do list[index] = nil end
	return list
end

-- What this member holds, said to the guild: at login, and to answer a
-- member who holds less.
function News.SendList()
	if not Guild() or not ns.Sync then return 0 end
	local rule = Rule()
	local parts, text = {}, ""
	for _, item in ipairs(Listed()) do
		local entry = ("%s=%d"):format(item.id, item.rev)
		if #text + #entry + 1 > LIST_BYTES then
			parts[#parts + 1] = text
			text = ""
		end
		text = text .. (text == "" and "" or ",") .. entry
	end
	parts[#parts + 1] = text
	for index, part in ipairs(parts) do
		ns.Sync.Say("L", ("L^%d^%d^%d^%s"):format(rule and rule.at or 0, index, #parts, part), 2)
	end
	ns.Count("news.listSaid")
	return #parts
end

local function Want(sender, id)
	local now = Now()
	if wanted[id] and now - wanted[id] < WANT_GAP then return false end
	wanted[id] = now
	ns.Sync.Tell("W", "W^" .. id, sender, 2)
	ns.Count("news.wanted")
	return true
end

-- An answer to a member who holds less than we do, after a pause, unless
-- another member said as much meanwhile.
local function Answer()
	answerDue = false
	local rule = Rule()
	local behind = (rule and rule.at or 0) > heard.ruleAt
	for _, item in ipairs(Listed()) do
		if (heard.revs[item.id] or 0) < item.rev then behind = true end
	end
	if behind then
		News.SendList()
	else
		ns.Count("news.answerSuppressed")
	end
end

-- A member's list, whole: what it has that we lack is asked of it, and
-- what we have that it lacks is told to the guild.
local function Compare(sender, ruleAt, theirs)
	local store = Store()
	if not store then return end
	local now = Now()
	if now - heard.at > ANSWER_MAX + 10 and not answerDue then heard = { at = now, ruleAt = 0, revs = {} } end
	heard.at = now
	if ruleAt > heard.ruleAt then heard.ruleAt = ruleAt end
	for id, rev in pairs(theirs) do
		if rev > (heard.revs[id] or 0) then heard.revs[id] = rev end
		local mine = store.items[id]
		if (not mine or mine.rev < rev) and rev <= now + MAX_FUTURE then Want(sender, id) end
	end
	local rule = Rule()
	local mineAt = rule and rule.at or 0
	if ruleAt > mineAt and ruleAt <= now + MAX_FUTURE then Want(sender, "rule") end
	local ahead = mineAt > ruleAt
	for _, item in ipairs(Listed()) do
		if (theirs[item.id] or 0) < item.rev then ahead = true end
	end
	if ahead and not answerDue then
		answerDue = true
		Util.After(ANSWER_MIN + math.random() * (ANSWER_MAX - ANSWER_MIN), "news-answer", Answer)
	end
end

local function OnList(sender, text)
	if not Identity.Member(sender) or not Guild() then return end
	local ruleAt, index, total, body = text:match("^L%^(%d+)%^(%d+)%^(%d+)%^(.*)$")
	ruleAt, index, total = tonumber(ruleAt), tonumber(index), tonumber(total)
	if not ruleAt or not (total >= 1 and total <= 8 and index >= 1 and index <= total) then
		ns.Count("news.listBad")
		return
	end
	local canon = Identity.Canon(sender)
	local now = Now()
	local list = lists[canon]
	if not list or list.total ~= total or now - list.at > PARTIAL_LIFE or index == 1 then
		list = { total = total, at = now, parts = {} }
		lists[canon] = list
	end
	list.parts[index] = body
	for part = 1, total do
		if not list.parts[part] then return end
	end
	lists[canon] = nil
	local theirs = {}
	for part = 1, total do
		for id, rev in list.parts[part]:gmatch("([^,=]+)=(%d+)") do
			if id:match(ID) then theirs[id] = tonumber(rev) end
		end
	end
	ns.Count("news.listHeard")
	Compare(sender, ruleAt, theirs)
end

-- A member asks for an announcement, or for the rule: handed over by
-- whisper, not twice in a row to the same member.
local function OnWant(sender, text)
	if not Identity.Member(sender) or not Guild() then return end
	local id = text:match("^W%^(.+)$")
	if not id then return end
	local key = Identity.Canon(sender) .. ":" .. id
	local now = Now()
	if served[key] and now - served[key] < SERVE_GAP then
		ns.Count("news.serveSkipped")
		return
	end
	if id == "rule" then
		local rule = Rule()
		if rule then
			served[key] = now
			ns.Sync.Tell("T", RuleLine(rule), sender, 2)
		end
		return
	end
	local store = Store()
	local item = id:match(ID) and store and store.items[id] or nil
	if item then
		served[key] = now
		Send(item, sender)
	end
end

-- An announcement received whole: kept when it is newer than the one held
-- and a member of the guild wrote it. Whether its writer may publish is
-- read when it is shown: the rule that says so may come after it, and a
-- promotion or a demotion changes the answer.
local function Accept(item)
	local store = Store()
	if not store then return false end
	local held = store.items[item.id]
	if held and held.rev >= item.rev then return false end
	if not Identity.MemberByTail(item.by) then
		ns.Count("news.notWriter")
		return false
	end
	store.items[item.id] = item
	wanted[item.id] = nil
	Trim(store)
	ns.Count(item.removed and "news.removedReceived" or "news.received")
	Changed()
	News.Tell()
	return true
end

local function OnChunk(sender, text)
	if not Identity.Member(sender) or not Guild() then
		ns.Count("news.notMember")
		return
	end
	local id, rev, index, total, data = text:match("^N%^([%d%-%x]+%.%d+)%^(%d+)%^(%d+)%^(%d+)%^(.*)$")
	rev, index, total = tonumber(rev), tonumber(index), tonumber(total)
	if not id or not id:match(ID) or not (total >= 1 and total <= MAX_CHUNKS and index >= 1 and index <= total) then
		ns.Count("news.chunkBad")
		return
	end
	local store = Store()
	local held = store and store.items[id]
	if not store or (held and held.rev >= rev) then return end
	local now = Now()
	for key, part in pairs(partial) do
		if now - part.at > PARTIAL_LIFE then partial[key] = nil end
	end
	local key = Identity.Canon(sender) .. ":" .. id .. ":" .. rev
	local part = partial[key]
	if not part or part.total ~= total then
		part = { total = total, at = now, parts = {} }
		partial[key] = part
	end
	part.parts[index] = data
	for piece = 1, total do
		if not part.parts[piece] then return end
	end
	partial[key] = nil
	local item, why = Decode(id, rev, table.concat(part.parts))
	if not item then
		ns.Count("news.bad." .. tostring(why))
		return
	end
	Accept(item)
end

-- Every message of the announcements, from Sync.
function News.OnMessage(kind, sender, text)
	if kind == "N" then
		OnChunk(sender, text)
	elseif kind == "L" then
		OnList(sender, text)
	elseif kind == "W" then
		OnWant(sender, text)
	elseif kind == "T" then
		OnRule(sender, text)
	end
end

--------------------------------------------------------------------------------
-- Publishing
--------------------------------------------------------------------------------

-- The time of an event from a day, a month, an hour and a minute of the
-- player's own clock: the next such date, this year or the one after.
function News.When(day, month, hour, minute)
	day, month, hour, minute = tonumber(day), tonumber(month), tonumber(hour), tonumber(minute)
	if not (day and month and hour and minute) then return nil end
	if day < 1 or day > 31 or month < 1 or month > 12 or hour < 0 or hour > 23 or minute < 0 or minute > 59 then return nil end
	if day % 1 ~= 0 or month % 1 ~= 0 or hour % 1 ~= 0 or minute % 1 ~= 0 then return nil end
	if not (Util.Fn(time) and Util.Fn(date)) then return nil end
	local now = Now()
	local year = tonumber(date("%Y", now))
	if not year then return nil end
	for offset = 0, 1 do
		local at = time({ year = year + offset, month = month, day = day, hour = hour, min = minute, sec = 0 })
		-- A day the month does not have rolls over to the next: refused.
		if type(at) == "number" and tonumber(date("%d", at)) == day and at > now then return at end
	end
	return nil
end

-- A member who may publish writes an announcement, or corrects the one
-- named. fields: title, when, text, link, ranks, classes, roles, level
-- (the three sets as { [value] = true }, nil for everyone). Returns the
-- announcement, or nothing and the field that is wrong.
function News.Publish(fields, id)
	if not News.CanPublish() then return nil, "right" end
	local store = Store()
	local me = Identity.me
	local now = Now()
	local title = Tidy(fields.title, News.TITLE_MAX)
	if title == "" then return nil, "title" end
	local when = fields.when
	if type(when) ~= "number" or when <= now or when > now + HORIZON then return nil, "when" end
	local link
	if Tidy(fields.link, News.LINK_MAX + 1) ~= "" then
		link = Link(fields.link)
		if not link then return nil, "link" end
	end
	local level = tonumber(fields.level)
	local item = {
		by = me.tail, when = math.floor(when), title = title, text = Tidy(fields.text, News.TEXT_MAX, true), link = link,
		ranks = SetOf(Sorted(fields.ranks), IsRank), classes = SetOf(Sorted(fields.classes), IsClass),
		roles = SetOf(Sorted(fields.roles), Identity.IsRole),
		level = level and level >= 2 and level <= MAX_LEVEL and math.floor(level) or nil,
	}
	local previous = id and store.items[id] or nil
	if previous then
		item.id, item.rev = id, math.max(now, previous.rev + 1)
	else
		local stamp = now
		while store.items[me.tail .. "." .. stamp] do stamp = stamp + 1 end
		item.id, item.rev = me.tail .. "." .. stamp, stamp
	end
	store.items[item.id] = item
	store.seen[item.id], store.told[item.id] = item.rev, item.rev
	Trim(store)
	ns.Count(previous and "news.corrected" or "news.published")
	Changed()
	Send(item)
	return item
end

-- Takes an announcement back: what is left of it says so to the guild
-- until its event has passed.
function News.Remove(id)
	if not News.CanPublish() then return false end
	local store = Store()
	local previous = store.items[id]
	if not previous or previous.removed then return false end
	local item = { id = id, rev = math.max(Now(), previous.rev + 1), by = Identity.me.tail, when = previous.when, removed = true }
	store.items[id] = item
	ns.Count("news.removed")
	Changed()
	Send(item)
	return true
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

-- An event that passes while the player is here ends its notice.
local function Tick()
	local count = #News.Unseen()
	if count ~= lastUnseen then
		lastUnseen = count
		Changed()
	end
end

ns.Hook("NewsChanged", function() lastUnseen = #News.Unseen() end)
-- What still waits is said once a session, soon after login: when the
-- roster is there, since it says whose announcements count.
local function Remind()
	if not remindAt or Now() < remindAt or not Identity.RosterKnown() then return end
	remindAt = nil
	local waiting = News.Unseen()
	local store = Store()
	if #waiting > 0 and store then
		for _, item in ipairs(waiting) do store.told[item.id] = item.rev end
		ns.Print(#waiting == 1 and L.NEWS_CHAT_ONE or L.NEWS_CHAT_MANY:format(#waiting))
		ns.Count("news.toldAtLogin")
	end
	Changed()
end

-- A roster that changes may change who may publish, and for whom an
-- announcement is.
ns.Hook("RosterUpdated", function()
	Changed()
	if remindAt then Remind() else News.Tell() end
end)
ns.Hook("GuildChanged", function()
	partial, wanted, served, lists = {}, {}, {}, {}
	Changed()
	if Guild() then Util.After(LOGIN_LIST, "news-list", News.SendList) end
end)
ns.Hook("Login", function()
	local store = Store()
	if store then Trim(store) end
	Util.After(LOGIN_LIST, "news-list", News.SendList)
	remindAt = Now() + LOGIN_TELL
	Util.After(LOGIN_TELL + 1, "news-remind", Remind)
	Util.Every(60, "news-tick", Tick)
end)

ns.Hook("Debug", function()
	local store = Store()
	local held, removed = 0, 0
	for _, item in pairs(store and store.items or {}) do
		held = held + 1
		if item.removed then removed = removed + 1 end
	end
	local limit, why = News.Limit()
	ns.Print(("news: %d held (%d removed), %d shown, %d unseen, notify %s, may publish %s, limit rank %d%s"):format(held, removed,
		#News.Shown(), #News.Unseen(), tostring(News.Notifies()), tostring(News.CanPublish()), limit, why and (" (" .. why .. ")") or ""))
end)
