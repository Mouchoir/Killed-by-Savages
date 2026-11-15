local _, ns = ...

--------------------------------------------------------------------------------
-- Statistics
--
-- Everything the window shows is computed here from the journals: per
-- character, per player (the characters of one Battle.net account that are
-- still in the guild), for the whole guild (every journal held, departed
-- members included, each enemy death counted once), the hunting board and
-- the kill feed. Periods are weeks aligned on the server's weekly reset.
--
-- A journal is read once into an aggregate, kept until that journal
-- changes: its numbers by week, and its kills, deaths and matches, in one
-- list and by week. Everything else is put together from the aggregates,
-- week by week, so that what a new record costs is its own journal and its
-- own week, however long the guild's history grows.
--------------------------------------------------------------------------------

local Util = ns.Util
local Records = ns.Records
local Identity = ns.Identity

local Stats = {}
ns.Stats = Stats

local WEEK = Util.WEEK
local FALLBACK_ANCHOR = 1793764800     -- 2026-11-04 04:00 UTC, a weekly reset
local DEDUPE_WINDOW = 5                -- seconds between two reports of one enemy death
local DEDUPE_DISTANCE = 0.03           -- map units between two unnamed kills counted once
local REPEAT_WINDOW = 3                -- seconds within which one killer's second death record is the same death
local COMPACT_DELAY = 20
local COMPACT_GAP = 2                  -- seconds between two pages packed
local NONE = {}
local MATCH_LATE = 300                 -- seconds after a teammate's scoreboard within which a match left with none is still that match

Stats.MILESTONES = { 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000 }
Stats.PERIODS = { "week", "last", "all" }
Stats.BUCKETS = { "w", "b", "all" }

-- authors: each journal's aggregate. distinct: the enemy deaths of each
-- week, by week index. The others are what the window asks for, by period.
local cache = { authors = {}, guild = {}, players = {}, feed = {}, credits = nil, distinct = {} }

--------------------------------------------------------------------------------
-- Weeks
--------------------------------------------------------------------------------

function Stats.Anchor()
	local anchor = ns.db and ns.db.weekAnchor
	return type(anchor) == "number" and anchor or FALLBACK_ANCHOR
end

-- Any instant at which a weekly reset happens is a valid anchor; the client
-- says when the next one is.
function Stats.RefreshAnchor()
	if not (C_DateAndTime and Util.Fn(C_DateAndTime.GetSecondsUntilWeeklyReset)) then return end
	local seconds = Util.Get(C_DateAndTime.GetSecondsUntilWeeklyReset)
	if type(seconds) == "number" and seconds >= 0 and seconds <= WEEK then
		ns.db.weekAnchor = Util.Now() + seconds
		-- Weeks are counted from the anchor: nothing worked out before holds.
		cache.authors, cache.guild, cache.players, cache.feed, cache.credits, cache.distinct = {}, {}, {}, {}, nil, {}
	end
end

function Stats.WeekIndex(t)
	return math.floor((t - Stats.Anchor()) / WEEK)
end

function Stats.CurrentWeek()
	return Stats.WeekIndex(Util.Now())
end

function Stats.WeekStart(index)
	return Stats.Anchor() + index * WEEK
end

-- When a period starts and ends, in server time, and for the running week
-- when its counts start again. All time has neither start nor end.
function Stats.PeriodRange(period)
	local current = Stats.CurrentWeek()
	if period == "week" then return Stats.WeekStart(current), nil, Stats.WeekStart(current + 1) end
	if period == "last" then return Stats.WeekStart(current - 1), Stats.WeekStart(current), nil end
	return nil, nil, nil
end

local function InPeriod(period, week, current)
	if period == "all" then return true end
	if period == "week" then return week == current end
	if period == "last" then return week == current - 1 end
	return false
end

--------------------------------------------------------------------------------
-- Per author
--------------------------------------------------------------------------------

local function NewCounts()
	return { hk = 0, kb = 0, deaths = 0 }
end

local function NewWeek()
	return { w = NewCounts(), b = NewCounts(), u = NewCounts() }
end

local function Bump(week, bucket, field, amount)
	local counts = week[bucket] or week.u
	counts[field] = (counts[field] or 0) + (amount or 1)
end

local function IsKillingBlow(record)
	return record.how == "kb" or record.how == "pet"
end

-- One kill or death of a journal as the lists hold it: the record, whose
-- it is and when, so a list made of many journals sorts without one more
-- table per item. Kept in the journal's order and by week: a period is
-- then read without going through the whole history.
local function Item(list, byWeek, week, guid, seq, record, provisional)
	local item = { seq = seq, record = record, author = guid, t = record.t }
	if provisional then item.provisional = true end
	list[#list + 1] = item
	local weekly = byWeek[week]
	if not weekly then
		weekly = {}
		byWeek[week] = weekly
	end
	weekly[#weekly + 1] = item
end

-- The lists of one journal that fall in a period: this week's, last
-- week's, or every week's.
local function PeriodLists(byWeek, period, current)
	if period == "week" then return { byWeek[current] } end
	if period == "last" then return { byWeek[current - 1] } end
	local lists = {}
	if period == "all" then
		for _, list in pairs(byWeek) do lists[#lists + 1] = list end
	end
	return lists
end

-- Everything one journal says, by week and bucket, plus the lists the
-- hunting board and the feed need. victims and killers hold the score
-- between the author and each enemy, in the world; repeats holds the seq
-- of the death records that only repeat the death before them. The rest is
-- what folding one more record in needs: the seq the journal was read up
-- to, the lifetime counts of its kills, its counter records, its last death.
local function NewAggregate()
	return {
		weeks = {}, kills = {}, deaths = {}, victims = {}, killers = {}, repeats = {},
		killWeeks = {}, deathWeeks = {}, matches = {},
		provisional = 0, records = 0, backfilled = 0, repeated = 0,
		maxSeq = 0, lifeKs = {}, counters = {}, anchor = Stats.Anchor(),
	}
end

-- A counter record covers HKs the server counted with no detail; kills
-- recovered later inside its range are not counted twice. What it adds is
-- set again each time a kill falls inside it.
local function Settle(agg, counter)
	local net = math.max(0, (counter.to - counter.from) - counter.inside)
	if net == counter.applied then return end
	local weekly = agg.weeks[counter.week]
	if not weekly then
		weekly = NewWeek()
		agg.weeks[counter.week] = weekly
	end
	Bump(weekly, counter.bucket, "hk", net - counter.applied)
	counter.applied = net
end

-- One more record of the journal, after those the aggregate holds.
local function Fold(agg, author, guid, record, seq)
	agg.records = agg.records + 1
	if seq > agg.maxSeq then agg.maxSeq = seq end
	local week = math.floor((record.t - agg.anchor) / WEEK)
	local weekly = agg.weeks[week]
	if not weekly then
		weekly = NewWeek()
		agg.weeks[week] = weekly
	end
	local provisional = author.provisional ~= nil and author.provisional[seq] == true
	if provisional then agg.provisional = agg.provisional + 1 end
	if record.type == "K" then
		-- Battleground kills are counted from the match's scoreboard, not
		-- one by one; here they only feed the timeline.
		if record.bucket ~= "b" then
			Bump(weekly, record.bucket, "hk")
			if IsKillingBlow(record) then Bump(weekly, record.bucket, "kb") end
		end
		-- A backfill kill sits outside the chain: it never falls inside
		-- a counter record's range, and in the world it takes one HK off
		-- the count the addon started from (in a battleground its match
		-- does, below).
		if record.backfill then
			if record.bucket ~= "b" then agg.backfilled = agg.backfilled + 1 end
		elseif type(record.lifeHK) == "number" then
			local life = record.lifeHK
			agg.lifeKs[#agg.lifeKs + 1] = life
			for _, counter in ipairs(agg.counters) do
				if life > counter.from and life <= counter.to then
					counter.inside = counter.inside + 1
					Settle(agg, counter)
				end
			end
		end
		Item(agg.kills, agg.killWeeks, week, guid, seq, record, provisional)
		-- The score between a member and an enemy counts the world only:
		-- a battleground hides whom the member kills there, so the
		-- deaths there stay out of it too (below).
		if record.vtail and record.bucket ~= "b" then
			local victim = agg.victims[record.vtail]
			if not victim then
				victim = { tail = record.vtail, count = 0, kb = 0 }
				agg.victims[record.vtail] = victim
			end
			victim.count = victim.count + 1
			if IsKillingBlow(record) then victim.kb = victim.kb + 1 end
			if not victim.lastAt or record.t >= victim.lastAt then
				victim.lastAt = record.t
				victim.name, victim.class, victim.race, victim.level = record.vname, record.vclass, record.vrace, record.vlevel
			end
		end
	elseif record.type == "D" then
		local key = record.ktail or (record.kname and ("pet:" .. record.kname)) or nil
		-- The client fires PLAYER_DEAD twice at times; a journal written
		-- before 0.1.13 can hold the same death twice in a row. Once,
		-- and the feed skips the copy too. Seconds apart either way: a
		-- backfilled death, older than the one before it in the journal,
		-- is a death of its own.
		local lastDeath = agg.lastDeath
		if lastDeath and key and key == lastDeath.key and math.abs(record.t - lastDeath.t) <= REPEAT_WINDOW then
			agg.repeated = agg.repeated + 1
			agg.repeats[seq] = true
		else
			if record.bucket ~= "b" then Bump(weekly, record.bucket, "deaths") end
			Item(agg.deaths, agg.deathWeeks, week, guid, seq, record, provisional)
			if key and record.bucket ~= "b" then
				local killer = agg.killers[key]
				if not killer then
					killer = { key = key, tail = record.ktail, kind = record.kkind, count = 0 }
					agg.killers[key] = killer
				end
				killer.count = killer.count + 1
				if not killer.lastAt or record.t >= killer.lastAt then
					killer.lastAt = record.t
					killer.name, killer.class, killer.race = record.kname, record.kclass, record.krace
				end
			end
			agg.lastDeath = { t = record.t, key = key }
		end
	elseif record.type == "X" then
		local counter = { week = week, bucket = record.bucket, from = record.fromHK, to = record.toHK, inside = 0, applied = 0 }
		for _, life in ipairs(agg.lifeKs) do
			if life > counter.from and life <= counter.to then counter.inside = counter.inside + 1 end
		end
		agg.counters[#agg.counters + 1] = counter
		Settle(agg, counter)
	elseif record.type == "M" then
		agg.matches[#agg.matches + 1] = record
		if record.backfill then agg.backfilled = agg.backfilled + (record.hk or 0) end
	end
end

local function Aggregate(guid)
	local author = ns.db.authors[guid]
	local agg = NewAggregate()
	if not author then return agg end
	Records.Each(guid, function(record, _, seq) Fold(agg, author, guid, record, seq) end)
	return agg
end

function Stats.AuthorAggregate(guid)
	local agg = cache.authors[guid]
	if not agg then
		agg = Aggregate(guid)
		cache.authors[guid] = agg
	end
	return agg
end

--------------------------------------------------------------------------------
-- Battlegrounds: the scoreboards
--
-- Every match record held, from any journal, names the guild members who
-- were on the board and what they did. The same match seen by several
-- members counts once; a member's own row beats a teammate's copy of it.
-- The match records come from the journals' aggregates, and a match is
-- looked for among those of its own battleground only.
--------------------------------------------------------------------------------

local function MatchCredits()
	if cache.credits then return cache.credits end
	local credits = { matches = {}, byTail = {}, absorbed = 0 }
	local byInstance = {}
	local function Known(instanceID)
		local known = byInstance[instanceID or false]
		if not known then
			known = {}
			byInstance[instanceID or false] = known
		end
		return known
	end
	local function NewMatch(record, known)
		-- A scoreboard outside any instance (instanceID 0) is a guild raid
		-- in the world, written by hand: its lines credit world kills
		-- instead of battleground ones.
		local match = {
			t = record.t, week = Stats.WeekIndex(record.t), instanceID = record.instanceID,
			world = record.instanceID == 0, lines = {}, from = record.t, to = record.t,
		}
		credits.matches[#credits.matches + 1] = match
		known[#known + 1] = match
		return match
	end
	-- The scoreboards first. Never two rows of one member's own in a match:
	-- its second scoreboard is another match.
	local bare = {}
	for guid in pairs(Records.Scope()) do
		local authorTail = Util.Tail(guid)
		for _, record in ipairs(Stats.AuthorAggregate(guid).matches) do
			if Records.NoScoreboard(record) then
				if authorTail then bare[#bare + 1] = { record = record, tail = authorTail } end
			else
				local known = Known(record.instanceID)
				local match
				for _, candidate in ipairs(known) do
					local line = authorTail and candidate.lines[authorTail]
					if Records.SameMatch(candidate, record) and not (line and line.own) then
						match = candidate
						break
					end
				end
				match = match or NewMatch(record, known)
				-- How long members were in it, for the records below.
				local from = record.t - (record.duration or 0)
				if from < match.from then match.from = from end
				if record.t > match.to then match.to = record.t end
				if authorTail then
					match.lines[authorTail] = { tail = authorTail, hk = record.hk or 0, kb = record.kb or 0, deaths = record.deaths or 0, own = true }
				end
				for _, line in ipairs(record.lines or NONE) do
					if line.tail and not match.lines[line.tail] then
						match.lines[line.tail] = { tail = line.tail, name = line.name, hk = line.hk, kb = line.kb, deaths = line.deaths }
					end
				end
			end
		end
	end
	-- Then the records written with no scoreboard, the latest first. When a
	-- teammate's scoreboard of that battleground has the member's row, and
	-- the record falls while the teammate was in the match or as the
	-- battleground shut, it is that match: the row of the scoreboard stands
	-- (it has the killing blows and the deaths) and the record adds nothing.
	-- One record a row: an earlier one is an earlier match of the member.
	-- Anything else is a match of its own, or joins one closed at the same
	-- time in which the member has no row yet.
	table.sort(bare, function(a, b)
		if a.record.t ~= b.record.t then return a.record.t > b.record.t end
		if a.tail ~= b.tail then return a.tail < b.tail end
		return (a.record.seq or 0) > (b.record.seq or 0)
	end)
	for _, entry in ipairs(bare) do
		local record, tail = entry.record, entry.tail
		local best, bestGap
		for _, match in ipairs(credits.matches) do
			local line = match.lines[tail]
			if line and not line.own and not line.taken and not match.world
				and (record.instanceID == nil or match.instanceID == record.instanceID)
				and record.t >= match.from and record.t <= match.to + MATCH_LATE then
				local gap = math.abs(match.to - record.t)
				if not best or gap < bestGap or (gap == bestGap and match.t < best.t) then best, bestGap = match, gap end
			end
		end
		if best then
			best.lines[tail].taken = true
			credits.absorbed = credits.absorbed + 1
		else
			local known = Known(record.instanceID)
			local match
			for _, candidate in ipairs(known) do
				if Records.SameMatch(candidate, record) and not candidate.lines[tail] then
					match = candidate
					break
				end
			end
			match = match or NewMatch(record, known)
			match.lines[tail] = { tail = tail, hk = record.hk or 0, kb = record.kb or 0, deaths = record.deaths or 0, own = true }
		end
	end
	for _, match in pairs(credits.matches) do
		for tail, line in pairs(match.lines) do
			local byWeek = credits.byTail[tail]
			if not byWeek then
				byWeek = {}
				credits.byTail[tail] = byWeek
			end
			local weekly = byWeek[match.week]
			if not weekly then
				weekly = { b = NewCounts(), w = NewCounts() }
				byWeek[match.week] = weekly
			end
			local counts = weekly[match.world and "w" or "b"]
			counts.hk = counts.hk + (line.hk or 0)
			counts.kb = counts.kb + (line.kb or 0)
			counts.deaths = counts.deaths + (line.deaths or 0)
		end
	end
	cache.credits = credits
	return credits
end
Stats.MatchCredits = MatchCredits

-- Every character the board knows: journals held, plus members credited by
-- a scoreboard without a journal of their own.
local function KnownGuids()
	local set = {}
	for guid in pairs(Records.Scope()) do set[guid] = true end
	for tail in pairs(MatchCredits().byTail) do set["Player-" .. tail] = true end
	return set
end

local function Add(into, counts)
	into.kills = into.kills + (counts.hk or 0)
	into.kb = into.kb + (counts.kb or 0)
	into.deaths = into.deaths + (counts.deaths or 0)
end

local function Finish(sum)
	sum.assists = sum.kills - sum.kb
	if sum.deaths > 0 then
		sum.kd = sum.kills / sum.deaths
	else
		sum.kd = sum.kills
	end
	return sum
end

-- The numbers of one character for a period and a bucket.
function Stats.Character(guid, period, bucket)
	local agg = Stats.AuthorAggregate(guid)
	local sum = { kills = 0, kb = 0, deaths = 0 }
	local current = Stats.CurrentWeek()
	if bucket ~= "b" then
		for week, weekly in pairs(agg.weeks) do
			if InPeriod(period, week, current) then
				if bucket == "all" then
					Add(sum, weekly.w)
					Add(sum, weekly.u)
				else
					Add(sum, weekly[bucket] or NewCounts())
				end
			end
		end
	end
	-- Scoreboard credits: battleground boards, and the hand-written world
	-- ones, each in its bucket.
	local byWeek = MatchCredits().byTail[Util.Tail(guid) or ""]
	for week, weekly in pairs(byWeek or {}) do
		if InPeriod(period, week, current) then
			if bucket == "all" then
				Add(sum, weekly.b)
				Add(sum, weekly.w)
			elseif weekly[bucket] then
				Add(sum, weekly[bucket])
			end
		end
	end
	sum.provisional = agg.provisional
	return Finish(sum)
end

--------------------------------------------------------------------------------
-- Who is who, for display
--------------------------------------------------------------------------------

function Stats.AuthorInfo(guid)
	local author = ns.db.authors[guid]
	local profile = author and author.profile
	local member = Identity.MemberByTail(Util.Tail(guid))
	-- Honorable kills the server counted before the addon's first count,
	-- less those the probe's backfill placed: real, but with no time, victim
	-- or guild to go with them.
	local baseline = profile and profile.baselineHK or nil
	local before = type(baseline) == "number" and math.max(0, baseline - Stats.AuthorAggregate(guid).backfilled) or nil
	return {
		guid = guid,
		name = (profile and profile.name) or (member and member.name) or Util.Tail(guid) or "?",
		class = (profile and profile.class) or (member and member.class) or nil,
		race = profile and profile.race or nil,
		level = (member and member.level) or (profile and profile.level) or nil,
		playerKey = profile and profile.playerKey or nil,
		role = profile and profile.role or nil,
		alias = profile and profile.alias or nil,
		-- The player's main as this character states it: a tail, false for
		-- none, nil when its version says nothing of it.
		main = profile and profile.main,
		tail = Util.Tail(guid),
		rankIndex = member and member.rankIndex or nil,
		rankName = member and member.rankName or nil,
		-- When the character itself last stated its profile: a hello, or a
		-- profile of its own. One relayed with a page states nothing.
		statedAt = author and math.max(author.profileAt or 0, author.lastHello or 0) or 0,
		before = before,
		inGuild = member ~= nil,
		verified = author and author.profileVerified == true,
		own = author and author.own == true,
	}
end

--------------------------------------------------------------------------------
-- Characters and players
--------------------------------------------------------------------------------

local function SortRows(rows)
	table.sort(rows, function(a, b)
		if a.kills ~= b.kills then return a.kills > b.kills end
		if a.kb ~= b.kb then return a.kb > b.kb end
		if a.deaths ~= b.deaths then return a.deaths < b.deaths end
		return (a.name or "") < (b.name or "")
	end)
	for index, row in ipairs(rows) do row.rank = index end
	return rows
end

-- Every guild member whose journal, or whose scoreboards, say something
-- for the period, ranked; with everyone, those with nothing to show too.
function Stats.Characters(period, bucket, everyone)
	local rows = {}
	local known = KnownGuids()
	for tail, member in pairs(Identity.roster.byTail) do
		local guid = member.guid or ("Player-" .. tail)
		if known[guid] then
			local sum = Stats.Character(guid, period, bucket)
			if everyone or sum.kills > 0 or sum.deaths > 0 then
				local info = Stats.AuthorInfo(guid)
				sum.guid, sum.name, sum.class, sum.level, sum.role = guid, info.name, info.class, info.level, info.role
				sum.playerKey, sum.me, sum.before = info.playerKey, guid == Identity.me.guid, info.before
				rows[#rows + 1] = sum
			end
		end
	end
	return SortRows(rows)
end

-- Whether the word of character a on the name of its player beats that of
-- b: the one that stated its profile last, since the name belongs to the
-- account and an alt that has not logged in since still carries the old
-- one. Profiles from before 1.0.1 have no date: one with a name first,
-- then always the same one.
local function StatedLater(a, b)
	if a.at ~= b.at then return a.at > b.at end
	if (a.alias ~= nil) ~= (b.alias ~= nil) then return a.alias ~= nil end
	return a.guid < b.guid
end

-- Characters grouped by Battle.net account: a player. Only characters still
-- in the guild count. The name is the alias the player chose, else that of
-- its main: the character it named so, else the one with the most kills
-- ever. With everyone, the players with nothing to show for the period too.
function Stats.Players(period, bucket, everyone)
	-- The week is part of the key: at the weekly reset "this week" is another.
	local key = period .. ":" .. bucket .. (everyone and ":everyone:" or ":") .. Stats.CurrentWeek()
	if cache.players[key] then return cache.players[key] end
	local groups = {}
	local known = KnownGuids()
	for tail, member in pairs(Identity.roster.byTail) do
		local guid = member.guid or ("Player-" .. tail)
		if known[guid] then
			local info = Stats.AuthorInfo(guid)
			local groupKey = info.playerKey or ("char:" .. guid)
			local group = groups[groupKey]
			if not group then
				group = { key = groupKey, kills = 0, kb = 0, deaths = 0, before = 0, characters = {}, me = false }
				groups[groupKey] = group
			end
			local sum = Stats.Character(guid, period, bucket)
			local ever = Stats.Character(guid, "all", "all")
			group.kills = group.kills + sum.kills
			group.kb = group.kb + sum.kb
			group.deaths = group.deaths + sum.deaths
			group.before = group.before + (info.before or 0)
			group.characters[#group.characters + 1] = { guid = guid, tail = info.tail, name = info.name, class = info.class,
				kills = sum.kills, ever = ever.kills, deaths = sum.deaths }
			local word = { guid = guid, alias = info.alias, at = info.statedAt or 0 }
			if not group.word or StatedLater(word, group.word) then group.word = word end
			-- The main too is the last word of the player's characters, among
			-- those whose version says one.
			if info.main ~= nil and (not group.mainWord or word.at > group.mainWord.at
				or (word.at == group.mainWord.at and guid < group.mainWord.guid)) then
				group.mainWord = { guid = guid, at = word.at, main = info.main }
			end
			if guid == Identity.me.guid then group.me = true end
		end
	end
	local rows = {}
	for _, group in pairs(groups) do
		if everyone or group.kills > 0 or group.deaths > 0 then
			table.sort(group.characters, function(a, b)
				if a.ever ~= b.ever then return a.ever > b.ever end
				return a.name < b.name
			end)
			-- My own main is the one set here, whatever my profiles still say.
			local mainTail = group.mainWord and group.mainWord.main or nil
			if group.me then mainTail = Util.Tail(Identity.Main()) end
			local main
			for _, character in ipairs(group.characters) do
				if mainTail and character.tail == mainTail then main = character end
			end
			group.mainDeclared = main ~= nil
			group.mainWord = nil
			main = main or group.characters[1]
			-- My own name is the one set here, whatever the profiles of
			-- my other characters still say.
			if group.me then
				group.alias = Identity.Alias()
			else
				group.alias = group.word and group.word.alias or nil
			end
			group.word = nil
			group.name = group.alias or main.name
			group.class = main.class
			group.mainGuid = main.guid
			rows[#rows + 1] = Finish(group)
		end
	end
	SortRows(rows)
	cache.players[key] = rows
	return rows
end

--------------------------------------------------------------------------------
-- The guild
--------------------------------------------------------------------------------

local function Oldest(a, b)
	if a.t ~= b.t then return a.t < b.t end
	return a.author < b.author
end

local function Newest(a, b)
	if a.t ~= b.t then return a.t > b.t end
	return a.author < b.author
end

-- The world kills of one week, from every journal, sorted by time, with
-- those of the two weeks next to it that fall within the window of its
-- ends: a death reported twice across a weekly reset is still one death.
-- Battleground kills name nobody and carry no position, so they would each
-- count as an enemy death of their own: matches count them instead (see
-- Stats.Guild). Returns the list and the week's start and end.
local function WeekKills(week)
	local from = Stats.WeekStart(week)
	local to = from + WEEK
	local list = {}
	for guid in pairs(Records.Scope()) do
		local byWeek = Stats.AuthorAggregate(guid).killWeeks
		for _, kill in ipairs(byWeek[week] or NONE) do
			if kill.record.bucket ~= "b" then list[#list + 1] = kill end
		end
		for _, kill in ipairs(byWeek[week - 1] or NONE) do
			if kill.t >= from - DEDUPE_WINDOW and kill.record.bucket ~= "b" then list[#list + 1] = kill end
		end
		for _, kill in ipairs(byWeek[week + 1] or NONE) do
			if kill.t <= to + DEDUPE_WINDOW and kill.record.bucket ~= "b" then list[#list + 1] = kill end
		end
	end
	table.sort(list, Oldest)
	return list, from, to
end

local function Near(a, b)
	if a.mapID == nil or a.mapID ~= b.mapID then return false end
	if a.x == nil or b.x == nil or a.y == nil or b.y == nil then return true end
	return math.abs(a.x - b.x) <= DEDUPE_DISTANCE and math.abs(a.y - b.y) <= DEDUPE_DISTANCE
end

-- Enemy deaths counted once: a named kill repeats one reported within the
-- window by another member; an unnamed kill is absorbed by any named one
-- near it in time, or by another unnamed one from someone else next to it.
-- The list is sorted by time; only the kills from `from` up to `to` are
-- counted, the others are there to be compared with.
local function DistinctKills(list, from, to)
	local distinct = 0
	local lastSeen = {}
	for index, item in ipairs(list) do
		local record = item.record
		local counted = item.t >= from and item.t < to
		if record.vtail then
			local last = lastSeen[record.vtail]
			if counted and (not last or item.t - last > DEDUPE_WINDOW) then distinct = distinct + 1 end
			lastSeen[record.vtail] = item.t
		elseif counted then
			local absorbed = false
			local j = index - 1
			while j >= 1 and item.t - list[j].t <= DEDUPE_WINDOW do
				local other = list[j]
				if other.record.vtail or (other.author ~= item.author and Near(other.record, record)) then
					absorbed = true
					break
				end
				j = j - 1
			end
			j = index + 1
			while not absorbed and j <= #list and list[j].t - item.t <= DEDUPE_WINDOW do
				if list[j].record.vtail then absorbed = true end
				j = j + 1
			end
			if not absorbed then distinct = distinct + 1 end
		end
	end
	return distinct
end

-- The enemy deaths of one week in the world, kept until a kill of that
-- week comes in.
local function WeekDistinct(week)
	local known = cache.distinct[week]
	if not known then
		known = DistinctKills(WeekKills(week))
		cache.distinct[week] = known
	end
	return known
end

-- Those of a period: the sum of its weeks, so all time costs what the
-- weeks not counted yet cost.
local function Distinct(period, current)
	if period == "week" then return WeekDistinct(current) end
	if period == "last" then return WeekDistinct(current - 1) end
	if period ~= "all" then return 0 end
	local seen, total = {}, 0
	for guid in pairs(Records.Scope()) do
		for week in pairs(Stats.AuthorAggregate(guid).killWeeks) do
			if not seen[week] then
				seen[week] = true
				total = total + WeekDistinct(week)
			end
		end
	end
	return total
end

-- A kill stored at a time changes the count of its week, and of the week
-- next to it when it falls within the window of that end.
local function DropDistinct(t)
	local week = Stats.WeekIndex(t)
	local from = Stats.WeekStart(week)
	cache.distinct[week] = nil
	if t - from <= DEDUPE_WINDOW then cache.distinct[week - 1] = nil end
	if from + WEEK - t <= DEDUPE_WINDOW then cache.distinct[week + 1] = nil end
end

function Stats.Guild(period, bucket)
	local current = Stats.CurrentWeek()
	local key = period .. ":" .. bucket .. ":" .. current
	if cache.guild[key] then return cache.guild[key] end
	local sum = { kills = 0, kb = 0, deaths = 0, authors = 0, provisional = 0 }
	for guid in pairs(KnownGuids()) do
		local character = Stats.Character(guid, period, bucket)
		sum.kills = sum.kills + character.kills
		sum.kb = sum.kb + character.kb
		sum.deaths = sum.deaths + character.deaths
		sum.provisional = sum.provisional + character.provisional
		if ns.db.authors[guid] then sum.authors = sum.authors + 1 end
	end
	Finish(sum)
	-- Enemy deaths. In the world each victim once, from the kill records.
	-- In a battleground victims are secret, so each match counts the
	-- guild's killing blows on its scoreboard or, when higher, the
	-- honorable kills of the member who took part in the most deaths: a
	-- floor, never the members' sum, since their honorable kills overlap
	-- when they fight together.
	sum.distinct = bucket == "b" and 0 or Distinct(period, current)
	if bucket ~= "w" then
		for _, match in pairs(MatchCredits().matches) do
			-- A world scoreboard's deaths are already counted from the
			-- witnesses' kill records.
			if not match.world and InPeriod(period, match.week, current) then
				local blows, most = 0, 0
				for _, line in pairs(match.lines) do
					blows = blows + (line.kb or 0)
					most = math.max(most, line.hk or 0)
				end
				sum.distinct = sum.distinct + math.max(blows, most)
			end
		end
	end
	cache.guild[key] = sum
	return sum
end

-- The next milestone of the guild, on enemy deaths of all time.
function Stats.Milestone()
	local distinct = Stats.Guild("all", "all").distinct
	local previous, nextOne = 0, nil
	for _, milestone in ipairs(Stats.MILESTONES) do
		if distinct >= milestone then
			previous = milestone
		elseif not nextOne then
			nextOne = milestone
		end
	end
	nextOne = nextOne or Stats.MILESTONES[#Stats.MILESTONES]
	return { distinct = distinct, previous = previous, next = nextOne, progress = math.min(1, (distinct - previous) / math.max(1, nextOne - previous)) }
end

--------------------------------------------------------------------------------
-- The hunting board
--------------------------------------------------------------------------------

local function Scoped(filter)
	local guids = {}
	if filter and filter.guid then
		guids[#guids + 1] = filter.guid
	elseif filter and filter.playerKey then
		for tail, member in pairs(Identity.roster.byTail) do
			local guid = member.guid or ("Player-" .. tail)
			local info = ns.db.authors[guid] and Stats.AuthorInfo(guid)
			if info and info.playerKey == filter.playerKey then guids[#guids + 1] = guid end
		end
	else
		for guid in pairs(Records.Scope()) do guids[#guids + 1] = guid end
	end
	return guids
end

-- The enemies most killed, by the guild, a player or a character.
function Stats.Victims(period, bucket, filter, limit)
	local current = Stats.CurrentWeek()
	local byTail = {}
	for _, guid in ipairs(Scoped(filter)) do
		local agg = Stats.AuthorAggregate(guid)
		for _, list in ipairs(PeriodLists(agg.killWeeks, period, current)) do
			for index = 1, #list do
				local record = list[index].record
				if record.vtail and (bucket == "all" or record.bucket == bucket) then
					local victim = byTail[record.vtail]
					if not victim then
						victim = { tail = record.vtail, count = 0, kb = 0, by = {}, byCount = 0 }
						byTail[record.vtail] = victim
					end
					victim.count = victim.count + 1
					if IsKillingBlow(record) then victim.kb = victim.kb + 1 end
					if not victim.by[guid] then
						victim.by[guid] = true
						victim.byCount = victim.byCount + 1
					end
					if not victim.lastAt or record.t >= victim.lastAt then
						victim.lastAt = record.t
						victim.name, victim.class, victim.race, victim.level = record.vname, record.vclass, record.vrace, record.vlevel
					end
				end
			end
		end
	end
	local rows = {}
	for _, victim in pairs(byTail) do rows[#rows + 1] = victim end
	table.sort(rows, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		if a.lastAt ~= b.lastAt then return (a.lastAt or 0) > (b.lastAt or 0) end
		return (a.name or "") < (b.name or "")
	end)
	if limit then
		while #rows > limit do table.remove(rows) end
	end
	return rows
end

-- Who kills us the most.
function Stats.Killers(period, bucket, filter, limit)
	local current = Stats.CurrentWeek()
	local byKey = {}
	for _, guid in ipairs(Scoped(filter)) do
		local agg = Stats.AuthorAggregate(guid)
		for _, list in ipairs(PeriodLists(agg.deathWeeks, period, current)) do
			for index = 1, #list do
				local record = list[index].record
				local key = record.ktail or (record.kname and ("pet:" .. record.kname)) or nil
				if key and (bucket == "all" or record.bucket == bucket) then
					local killer = byKey[key]
					if not killer then
						killer = { key = key, tail = record.ktail, kind = record.kkind, count = 0, victims = {}, victimCount = 0 }
						byKey[key] = killer
					end
					killer.count = killer.count + 1
					if not killer.victims[guid] then
						killer.victims[guid] = true
						killer.victimCount = killer.victimCount + 1
					end
					if not killer.lastAt or record.t >= killer.lastAt then
						killer.lastAt = record.t
						killer.name, killer.class, killer.race = record.kname, record.kclass, record.krace
					end
				end
			end
		end
	end
	local rows = {}
	for _, killer in pairs(byKey) do rows[#rows + 1] = killer end
	table.sort(rows, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return (a.lastAt or 0) > (b.lastAt or 0)
	end)
	if limit then
		while #rows > limit do table.remove(rows) end
	end
	return rows
end

--------------------------------------------------------------------------------
-- The feed
--------------------------------------------------------------------------------

-- The latest kills and deaths of the guild, newest first: those of a period
-- when one is given, cut to the limit after the period is applied.
function Stats.Feed(limit, bucket, period)
	period = period or "all"
	local current = Stats.CurrentWeek()
	local key = tostring(limit) .. ":" .. tostring(bucket) .. ":" .. period .. ":" .. current
	if cache.feed[key] then return cache.feed[key] end
	-- The weeks of the period, the newest first. All time stops at the week
	-- that fills the limit: nothing older can come before what it holds.
	local weeks = {}
	if period == "week" then
		weeks[1] = current
	elseif period == "last" then
		weeks[1] = current - 1
	elseif period == "all" then
		local seen = {}
		for guid in pairs(Records.Scope()) do
			local agg = Stats.AuthorAggregate(guid)
			for _, byWeek in ipairs({ agg.killWeeks, agg.deathWeeks }) do
				for week in pairs(byWeek) do
					if not seen[week] then
						seen[week] = true
						weeks[#weeks + 1] = week
					end
				end
			end
		end
		table.sort(weeks, function(a, b) return a > b end)
	end
	local list = {}
	local function Take(items)
		for index = 1, #items do
			local item = items[index]
			if bucket == "all" or item.record.bucket == bucket then list[#list + 1] = item end
		end
	end
	for _, week in ipairs(weeks) do
		for guid in pairs(Records.Scope()) do
			local agg = Stats.AuthorAggregate(guid)
			Take(agg.killWeeks[week] or NONE)
			Take(agg.deathWeeks[week] or NONE)
		end
		if limit and #list >= limit then break end
	end
	table.sort(list, Newest)
	-- The rows are the feed's own: the items belong to the aggregates.
	local rows = {}
	for index = 1, math.min(limit or #list, #list) do
		local item = list[index]
		rows[index] = {
			t = item.t, record = item.record, author = item.author, provisional = item.provisional,
			info = Stats.AuthorInfo(item.author),
		}
	end
	cache.feed[key] = rows
	return rows
end

-- The last kills of one character, newest first.
function Stats.LastKills(guid, limit)
	local agg = Stats.AuthorAggregate(guid)
	local list = {}
	for index = #agg.kills, math.max(1, #agg.kills - (limit or 5) + 1), -1 do
		list[#list + 1] = agg.kills[index]
	end
	return list
end

--------------------------------------------------------------------------------
-- Cache and wiring
--------------------------------------------------------------------------------

-- A journal changed: its aggregate goes, and what is put together from the
-- aggregates. With the one record that was appended or received live, what
-- that record cannot touch stays: the enemy deaths of the other weeks, the
-- scoreboards unless it is a match. Anything else (a page, a purge, a
-- repair, a copy replaced) may have changed any week.
function Stats.Invalidate(guid, record, replaced, seq)
	local one = guid and type(record) == "table" and type(record.t) == "number" and not replaced
	-- That one record, when it comes after everything the journal's
	-- aggregate was made from, is folded into it: a kill then costs its own
	-- count, not a reading of the whole journal. The journal's copy is what
	-- is folded. Anything else, and the aggregate is made again when asked.
	local agg = one and cache.authors[guid] or nil
	local author = agg and ns.db.authors[guid] or nil
	local kept = author and type(seq) == "number" and seq > agg.maxSeq and agg.anchor == Stats.Anchor() and Records.Get(guid, seq) or nil
	if kept then
		Fold(agg, author, guid, kept, seq)
		ns.Count("stats.folded")
	elseif guid then
		cache.authors[guid] = nil
	else
		cache.authors = {}
	end
	cache.guild, cache.players, cache.feed = {}, {}, {}
	if one then
		if record.type == "K" then DropDistinct(record.t) end
		if record.type == "M" then cache.credits = nil end
	else
		cache.distinct, cache.credits = {}, nil
	end
	ns.Fire("StatsChanged", guid)
end

ns.Hook("RecordAdded", function(guid, seq, _, record) Stats.Invalidate(guid, record, nil, seq) end)
ns.Hook("RecordStored", function(guid, seq, record, _, replaced) Stats.Invalidate(guid, record, replaced, seq) end)
ns.Hook("JournalChanged", function(guid) Stats.Invalidate(guid) end)
-- Another set of journals is the guild's (a guild joined or left, a member's journal just come): what one journal says stays, what is put together from them is made again.
ns.Hook("ScopeChanged", function()
	cache.guild, cache.players, cache.feed, cache.distinct, cache.credits = {}, {}, {}, {}, nil
	ns.Fire("StatsChanged")
end)
-- A profile says who a character is, not what it did: the journals'
-- aggregates stay, only the lists that show names are made again.
ns.Hook("ProfileChanged", function(guid)
	cache.players, cache.feed = {}, {}
	ns.Fire("StatsChanged", guid)
end)
-- The roster says who is a member and what they are called: the guild's
-- totals read neither, and stay.
ns.Hook("RosterUpdated", function() cache.players, cache.feed = {}, {} end)

-- Old complete pages are packed after login, out of the way and one at a
-- time: packing is the heaviest thing the addon does, tens of milliseconds
-- a page, and a member who just caught up with a guild has hundreds to
-- pack. Never in combat. Packing changes no record: the stats stay.
local function CompactStep()
	if Util.Get(InCombatLockdown) == true then
		Util.After(COMPACT_GAP * 5, "compact", CompactStep)
		return
	end
	local olderThan = Stats.WeekStart(Stats.CurrentWeek() - 1)
	if Records.Compact(olderThan, 1) > 0 then Util.After(COMPACT_GAP, "compact", CompactStep) end
end

ns.Hook("Login", function()
	Stats.RefreshAnchor()
	Util.After(COMPACT_DELAY, "compact", CompactStep)
end)
ns.Hook("Debug", function()
	local guild = Stats.Guild("all", "all")
	ns.Print(("stats: %d journal(s), %d kills, %d distinct enemy deaths, %d deaths, week %d since anchor %s"):format(
		guild.authors, guild.kills, guild.distinct, guild.deaths, Stats.CurrentWeek(), Util.Stamp(Stats.Anchor())))
end)
