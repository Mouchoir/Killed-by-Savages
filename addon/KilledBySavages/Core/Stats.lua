local _, ns = ...

--------------------------------------------------------------------------------
-- Statistics
--
-- Everything the window shows is computed here from the journals: per
-- character, per player (the characters of one Battle.net account that are
-- still in the guild), for the whole guild (every journal held, departed
-- members included, each enemy death counted once), the hunting board and
-- the kill feed. Periods are weeks aligned on the server's weekly reset.
-- Aggregates are cached and dropped whenever a journal changes.
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

Stats.MILESTONES = { 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000 }
Stats.PERIODS = { "week", "last", "all" }
Stats.BUCKETS = { "w", "b", "all" }

local cache = { authors = {}, guild = {}, players = {}, feed = {}, credits = nil }

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

-- Everything one journal says, by week and bucket, plus the lists the
-- hunting board and the feed need. victims and killers hold the score
-- between the author and each enemy, in the world; repeats holds the seq
-- of the death records that only repeat the death before them.
local function Aggregate(guid)
	local author = ns.db.authors[guid]
	local agg = {
		weeks = {}, kills = {}, deaths = {}, victims = {}, killers = {}, repeats = {},
		provisional = 0, records = 0, backfilled = 0, repeated = 0,
	}
	if not author then return agg end
	local lifeKs = {}
	local counters = {}
	local lastDeath
	Records.Each(guid, function(record, _, seq)
		agg.records = agg.records + 1
		local week = Stats.WeekIndex(record.t)
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
			else
				lifeKs[#lifeKs + 1] = record.lifeHK
			end
			agg.kills[#agg.kills + 1] = { seq = seq, record = record, provisional = provisional }
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
			if lastDeath and key and key == lastDeath.key and math.abs(record.t - lastDeath.t) <= REPEAT_WINDOW then
				agg.repeated = agg.repeated + 1
				agg.repeats[seq] = true
			else
				if record.bucket ~= "b" then Bump(weekly, record.bucket, "deaths") end
				agg.deaths[#agg.deaths + 1] = { seq = seq, record = record, provisional = provisional }
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
				lastDeath = { t = record.t, key = key }
			end
		elseif record.type == "X" then
			counters[#counters + 1] = { week = week, bucket = record.bucket, from = record.fromHK, to = record.toHK }
		elseif record.type == "M" and record.backfill then
			agg.backfilled = agg.backfilled + (record.hk or 0)
		end
	end)
	-- A counter record covers HKs the server counted with no detail; kills
	-- recovered later inside its range are not counted twice.
	if #counters > 0 then
		table.sort(lifeKs)
		for _, counter in ipairs(counters) do
			local inside = 0
			for _, lifeHK in ipairs(lifeKs) do
				if lifeHK > counter.from and lifeHK <= counter.to then inside = inside + 1 end
			end
			local net = (counter.to - counter.from) - inside
			if net > 0 then
				local weekly = agg.weeks[counter.week] or NewWeek()
				agg.weeks[counter.week] = weekly
				Bump(weekly, counter.bucket, "hk", net)
			end
		end
	end
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
--------------------------------------------------------------------------------

local function MatchCredits()
	if cache.credits then return cache.credits end
	local credits = { matches = {}, byTail = {} }
	for guid in pairs(ns.db.authors) do
		local authorTail = Util.Tail(guid)
		Records.Each(guid, function(record)
			if record.type == "M" then
				local match
				for _, known in ipairs(credits.matches) do
					if Records.SameMatch(known, record) then
						match = known
						break
					end
				end
				if not match then
					-- A scoreboard outside any instance (instanceID 0) is a guild
					-- raid in the world, written by hand: its lines credit world
					-- kills instead of battleground ones.
					match = {
						t = record.t, week = Stats.WeekIndex(record.t), instanceID = record.instanceID,
						world = record.instanceID == 0, lines = {},
					}
					credits.matches[#credits.matches + 1] = match
				end
				if authorTail then
					match.lines[authorTail] = { tail = authorTail, hk = record.hk or 0, kb = record.kb or 0, deaths = record.deaths or 0, own = true }
				end
				for _, line in ipairs(record.lines or {}) do
					if line.tail and not match.lines[line.tail] then
						match.lines[line.tail] = { tail = line.tail, name = line.name, hk = line.hk, kb = line.kb, deaths = line.deaths }
					end
				end
			end
		end)
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
	for guid in pairs(ns.db.authors) do set[guid] = true end
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
-- for the period, ranked.
function Stats.Characters(period, bucket)
	local rows = {}
	local known = KnownGuids()
	for tail, member in pairs(Identity.roster.byTail) do
		local guid = member.guid or ("Player-" .. tail)
		if known[guid] then
			local sum = Stats.Character(guid, period, bucket)
			if sum.kills > 0 or sum.deaths > 0 then
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
-- in the guild count. The name is the alias the player chose, else the
-- character with the most kills ever.
function Stats.Players(period, bucket)
	local key = period .. ":" .. bucket
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
			group.characters[#group.characters + 1] = { guid = guid, name = info.name, class = info.class, kills = sum.kills, ever = ever.kills, deaths = sum.deaths }
			local word = { guid = guid, alias = info.alias, at = info.statedAt or 0 }
			if not group.word or StatedLater(word, group.word) then group.word = word end
			if guid == Identity.me.guid then group.me = true end
		end
	end
	local rows = {}
	for _, group in pairs(groups) do
		if group.kills > 0 or group.deaths > 0 then
			table.sort(group.characters, function(a, b)
				if a.ever ~= b.ever then return a.ever > b.ever end
				return a.name < b.name
			end)
			local main = group.characters[1]
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

-- All world kill records held, from every journal, filtered and sorted by
-- time. Battleground kills name nobody and carry no position, so they
-- would each count as an enemy death of their own: matches count them
-- instead (see Stats.Guild).
local function AllKills(period, bucket)
	local list = {}
	local current = Stats.CurrentWeek()
	for guid in pairs(ns.db.authors) do
		local agg = Stats.AuthorAggregate(guid)
		for _, kill in ipairs(agg.kills) do
			local record = kill.record
			if record.bucket ~= "b" and (bucket == "all" or record.bucket == bucket)
				and InPeriod(period, Stats.WeekIndex(record.t), current) then
				list[#list + 1] = { t = record.t, record = record, author = guid, provisional = kill.provisional }
			end
		end
	end
	table.sort(list, function(a, b)
		if a.t ~= b.t then return a.t < b.t end
		return a.author < b.author
	end)
	return list
end

local function Near(a, b)
	if a.mapID == nil or a.mapID ~= b.mapID then return false end
	if a.x == nil or b.x == nil then return true end
	return math.abs(a.x - b.x) <= DEDUPE_DISTANCE and math.abs(a.y - b.y) <= DEDUPE_DISTANCE
end

-- Enemy deaths counted once: a named kill repeats one reported within the
-- window by another member; an unnamed kill is absorbed by any named one
-- near it in time, or by another unnamed one from someone else next to it.
local function DistinctKills(list)
	local distinct = 0
	local lastSeen = {}
	for index, item in ipairs(list) do
		local record = item.record
		if record.vtail then
			local last = lastSeen[record.vtail]
			if not last or item.t - last > DEDUPE_WINDOW then distinct = distinct + 1 end
			lastSeen[record.vtail] = item.t
		else
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

function Stats.Guild(period, bucket)
	local key = period .. ":" .. bucket
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
	sum.distinct = bucket == "b" and 0 or DistinctKills(AllKills(period, bucket))
	if bucket ~= "w" then
		local current = Stats.CurrentWeek()
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
		for guid in pairs(ns.db.authors) do guids[#guids + 1] = guid end
	end
	return guids
end

-- The enemies most killed, by the guild, a player or a character.
function Stats.Victims(period, bucket, filter, limit)
	local current = Stats.CurrentWeek()
	local byTail = {}
	for _, guid in ipairs(Scoped(filter)) do
		local agg = Stats.AuthorAggregate(guid)
		for _, kill in ipairs(agg.kills) do
			local record = kill.record
			if record.vtail and (bucket == "all" or record.bucket == bucket) and InPeriod(period, Stats.WeekIndex(record.t), current) then
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
		for _, death in ipairs(agg.deaths) do
			local record = death.record
			local key = record.ktail or (record.kname and ("pet:" .. record.kname)) or nil
			if key and (bucket == "all" or record.bucket == bucket) and InPeriod(period, Stats.WeekIndex(record.t), current) then
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
	local key = tostring(limit) .. ":" .. tostring(bucket) .. ":" .. period
	if cache.feed[key] then return cache.feed[key] end
	local list = {}
	local current = Stats.CurrentWeek()
	local function Take(items, guid)
		for _, item in ipairs(items) do
			local record = item.record
			if (bucket == "all" or record.bucket == bucket) and InPeriod(period, Stats.WeekIndex(record.t), current) then
				list[#list + 1] = { t = record.t, record = record, author = guid, provisional = item.provisional }
			end
		end
	end
	for guid in pairs(ns.db.authors) do
		local agg = Stats.AuthorAggregate(guid)
		Take(agg.kills, guid)
		Take(agg.deaths, guid)
	end
	table.sort(list, function(a, b)
		if a.t ~= b.t then return a.t > b.t end
		return a.author < b.author
	end)
	while limit and #list > limit do table.remove(list) end
	for _, item in ipairs(list) do item.info = Stats.AuthorInfo(item.author) end
	cache.feed[key] = list
	return list
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

function Stats.Invalidate(guid)
	if guid then cache.authors[guid] = nil else cache.authors = {} end
	cache.guild, cache.players, cache.feed, cache.credits = {}, {}, {}, nil
	ns.Fire("StatsChanged", guid)
end

ns.Hook("RecordAdded", function(guid) Stats.Invalidate(guid) end)
ns.Hook("RecordStored", function(guid) Stats.Invalidate(guid) end)
ns.Hook("JournalChanged", function(guid) Stats.Invalidate(guid) end)
ns.Hook("ProfileChanged", function() Stats.Invalidate() end)
ns.Hook("RosterUpdated", function() cache.guild, cache.players, cache.feed = {}, {}, {} end)
ns.Hook("Login", function()
	Stats.RefreshAnchor()
	-- Old complete pages are packed once at login, out of the way.
	Util.After(COMPACT_DELAY, "compact", function()
		local olderThan = Stats.WeekStart(Stats.CurrentWeek() - 1)
		if Records.Compact(olderThan) > 0 then Stats.Invalidate() end
	end)
end)
ns.Hook("Debug", function()
	local guild = Stats.Guild("all", "all")
	ns.Print(("stats: %d journal(s), %d kills, %d distinct enemy deaths, %d deaths, week %d since anchor %s"):format(
		guild.authors, guild.kills, guild.distinct, guild.deaths, Stats.CurrentWeek(), Util.Stamp(Stats.Anchor())))
end)
