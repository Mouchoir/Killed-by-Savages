local _, ns = ...

--------------------------------------------------------------------------------
-- Import from the probe
--
-- KBSProbe, the dev probe that measured the client before this addon was
-- written, kept in its own SavedVariables what the addon now records: every
-- move of the HK counter matched with a killing blow or an enemy death, our
-- deaths with their killer, and the final scoreboard of each battleground.
-- On a character whose journal is still empty, those become the first
-- records of the journal, chained by the counter like live ones, so the
-- evenings spent with the probe count. The probe's file is account-wide and
-- mixes characters: its session list says who was playing when.
--
-- Nothing is written unless every record validates and the chain reaches
-- the counter the server shows now.
--------------------------------------------------------------------------------

local Util = ns.Util
local L = ns.L
local Records = ns.Records
local Identity = ns.Identity

local Import = {}
ns.Import = Import

local PROBE_SECRET = "<secret>"   -- how the probe wrote a value it could not read
local MATCH_WINDOW = 4            -- seconds between an HK entry and the kill it matched
local MATCH_MARGIN = 120          -- seconds before a match's start that still belong to it
local RUN_GAP = 1800              -- battleground HKs closer than this share a fallback match
local HOW_BY_ROLE = { me = "kb", mypet = "pet", party = "grp", partypet = "grp", raid = "grp", raidpet = "grp" }
local BUCKET = { world = "w", bg = "b" }

--------------------------------------------------------------------------------
-- Reading the probe's values
--------------------------------------------------------------------------------

-- A value as the probe saved it: nil when it was secret or not plain.
local function Val(value)
	local kind = type(value)
	if kind == "string" then
		if value == PROBE_SECRET or value == "" then return nil end
		return value
	end
	if kind == "number" or kind == "boolean" then return value end
	return nil
end

local function Num(value)
	value = Val(value)
	if type(value) == "number" and value == value then return value end
	return nil
end

local function Str(value)
	value = Val(value)
	if type(value) == "string" then return value end
	return nil
end

local function Tbl(value)
	if type(value) == "table" then return value end
	return nil
end

local function Lifetime(entry)
	local lifetime = entry.lifetime
	if type(lifetime) == "table" then return Num(lifetime[1]) end
	return Num(lifetime)
end

local function Position(pos)
	if type(pos) ~= "table" then return nil, nil, nil end
	return Num(pos.mapID), Num(pos.x), Num(pos.y)
end

local function VictimFields(facts)
	if type(facts) ~= "table" or facts.kind ~= "Player" then return nil end
	local tail = Util.Tail(Str(facts.guid))
	if not tail then return nil end
	local level = Num(facts.level)
	return {
		vtail = tail, vname = Str(facts.name), vclass = Str(facts.class), vrace = Str(facts.race),
		vlevel = level and level > 0 and level or nil,
	}
end

--------------------------------------------------------------------------------
-- Whose entries
--------------------------------------------------------------------------------

-- The session keys the probe gave this character: its own "First Last-Realm",
-- and the first name alone, as probes before 0.1.2 wrote it.
local function OwnKeys()
	local me = Identity.me
	local keys = {}
	if me.key then keys[me.key] = true end
	if me.first and me.realm then keys[Util.Clean(me.first .. "-" .. me.realm)] = true end
	return keys
end

-- A function telling whether a moment belonged to this character, from the
-- probe's session list, and whether any of its sessions did.
local function SessionJudge(probe)
	local sessions = {}
	for _, session in ipairs(Tbl(probe.sessions) or {}) do
		if type(session) == "table" and type(session.at) == "number" and type(session.key) == "string" then
			sessions[#sessions + 1] = { at = session.at, key = session.key }
		end
	end
	table.sort(sessions, function(a, b) return a.at < b.at end)
	if #sessions == 0 then
		-- Probes before the session list: the file is this character's only
		-- when the identity it kept is ours.
		local probeMe = Tbl(probe.me) or {}
		local mine = probeMe.guid ~= nil and probeMe.guid == Identity.me.guid
		return function() return mine end, mine
	end
	local keys = OwnKeys()
	local any = false
	for _, session in ipairs(sessions) do
		if keys[session.key] then any = true end
	end
	return function(at)
		if type(at) ~= "number" then return false end
		local current
		for _, session in ipairs(sessions) do
			if session.at <= at then current = session else break end
		end
		return current ~= nil and keys[current.key] == true
	end, any
end

--------------------------------------------------------------------------------
-- From the probe's rings to records
--------------------------------------------------------------------------------

-- The probe's killing blow an HK result like "kb:me" came from: on a player,
-- by that role, matched to an HK, within the window, not used yet.
local function TakeKill(kills, hk, role, used)
	local best
	for _, kill in ipairs(kills) do
		if type(kill) == "table" and not used[kill] and kill.hkMatched == true and kill.targetKind == "Player"
			and kill.role == role and type(kill.at) == "number" and math.abs(kill.at - hk.at) <= MATCH_WINDOW
			and (type(kill.t) ~= "number" or type(hk.t) ~= "number" or math.abs(kill.t - hk.t) <= MATCH_WINDOW) then
			if not best or math.abs(kill.at - hk.at) < math.abs(best.at - hk.at) then best = kill end
		end
	end
	if best then used[best] = true end
	return best
end

-- The enemy death the probe named for an HK with no killing blow of ours.
local function TakeAssist(assists, hk, used)
	for _, assist in ipairs(assists) do
		if type(assist) == "table" and not used[assist] and assist.how == "named" and type(assist.at) == "number"
			and math.abs(assist.at - hk.at) <= 1
			and (type(assist.t) ~= "number" or type(hk.t) ~= "number" or math.abs(assist.t - hk.t) < 0.01) then
			used[assist] = true
			return assist
		end
	end
	return nil
end

local function Results(hk)
	local results = {}
	for result in tostring(hk.match or ""):gmatch("%S+") do results[#results + 1] = result end
	return results
end

-- One kill record for the index-th HK of a live counter move.
local function KillRecord(hk, bucket, result, rings, used, guild)
	local record = { type = "K", t = hk.at, bucket = bucket, guild = guild }
	if bucket == "b" then
		-- Enemies are secret in a battleground: the HK is placed by subzone.
		record.how = "bg"
		record.sub = Str(hk.subzone)
		return record
	end
	local role = result and result:match("^kb:(%S+)$")
	local how = role and HOW_BY_ROLE[role] or nil
	local kill = how and TakeKill(rings.kills, hk, role, used) or nil
	local facts = kill and VictimFields(kill.target) or nil
	local pos = kill and kill.pos or nil
	if not facts and result == "assist:named" then
		local assist = TakeAssist(rings.assists, hk, used)
		facts = assist and VictimFields(assist.victim) or nil
		pos = assist and assist.pos or nil
		how = "ast"
	end
	if facts then
		for key, value in pairs(facts) do record[key] = value end
		record.how = how
	else
		record.how = "unk"
		pos = nil
	end
	record.mapID, record.x, record.y = Position(pos or hk.pos)
	return record
end

local function DeathRecord(death)
	local bucket = BUCKET[death.bucket]
	local killer = Tbl(death.killer)
	if not bucket or not killer or death.recapStatus ~= "ok" then return nil end
	local recap = Tbl(death.recap)
	local first = recap and Tbl(recap[1]) or {}
	local record
	if killer.kind == "Player" and Util.Tail(Str(killer.guid)) then
		record = {
			kkind = "p", ktail = Util.Tail(Str(killer.guid)), kname = Str(killer.name) or Str(first.sourceName),
			kclass = Str(killer.class), krace = Str(killer.race),
		}
	elseif killer.kind == "Pet" then
		-- The recap does not name a pet's owner; the pet's name is kept.
		record = { kkind = "e", kname = Str(first.sourceName) }
	else
		return nil
	end
	record.type, record.t, record.bucket, record.spell = "D", death.at, bucket, Str(first.spellName)
	if bucket == "b" then
		local context = Tbl(death.context)
		record.sub = context and Str(context.subzone) or nil
	else
		record.mapID, record.x, record.y = Position(death.pos)
	end
	return record
end

-- A finished match with its scoreboard: my row and the guild teammates'.
local function MatchRecord(match)
	local final = Tbl(match.final)
	local rows = final and Tbl(final.rows) or {}
	local mineRow = Tbl(match.mine)
	local me
	if mineRow and Num(mineRow.honorableKills) then
		me = {
			hk = Num(mineRow.honorableKills), kb = Num(mineRow.killingBlows) or 0, deaths = Num(mineRow.deaths) or 0,
			honor = Num(mineRow.honorGained), damage = Num(mineRow.damageDone), healing = Num(mineRow.healingDone),
		}
	end
	local lines = {}
	for _, row in ipairs(rows) do
		if type(row) == "table" then
			local guid = Str(row.guid)
			local name = Str(row.name)
			local isMe = row.me == true or (guid ~= nil and guid == Identity.me.guid)
			if isMe then
				if not me and Num(row.hk) then
					me = { hk = Num(row.hk), kb = Num(row.kb) or 0, deaths = Num(row.deaths) or 0, honor = Num(row.honor) }
				end
			elseif Num(row.hk) and #lines < Records.MAX_LINES then
				local member = Identity.Member(name)
				if row.guildmate == true or member then
					local tail = Util.Tail(guid) or (member and member.tail) or nil
					if tail then
						lines[#lines + 1] = {
							tail = tail, name = name, kb = Num(row.kb) or 0, hk = Num(row.hk),
							deaths = Num(row.deaths) or 0, honor = Num(row.honor) or 0,
						}
					end
				end
			end
		end
	end
	if not me then return nil end
	local context = Tbl(match.atEnd) or Tbl(match.context) or {}
	local duration = Num(match.duration)
	return {
		type = "M", t = match.completeAt, instanceID = Num(context.instanceID), duration = duration,
		winner = Num(match.battlefieldWinner) or Num(match.winner), hk = me.hk, kb = me.kb, deaths = me.deaths,
		honor = me.honor, damage = me.damage, healing = me.healing, live = me.hk, lines = lines,
	}, match.completeAt - (duration or RUN_GAP) - MATCH_MARGIN
end

-- The instance a battleground HK was in: the match the probe entered last
-- before it.
local function InstanceAt(matches, at)
	local best
	for _, match in ipairs(matches) do
		if type(match) == "table" and type(match.startedAt) == "number" and match.startedAt <= at
			and (not best or match.startedAt > best.startedAt) then
			best = match
		end
	end
	local context = best and (Tbl(best.context) or Tbl(best.atEnd)) or nil
	return context and Num(context.instanceID) or nil
end

-- Everything of this character the probe kept, as records in time order,
-- with the counter value the probe first knew and the one it last knew.
-- Returns nil and a reason when the probe's own numbers do not add up.
local function Build(probe, mine, guild)
	local log = Tbl(probe.log) or {}
	local rings = {
		hk = Tbl(log.hk) or {}, kills = Tbl(log.kills) or {}, assists = Tbl(log.assists) or {},
		deaths = Tbl(log.deaths) or {}, matches = Tbl(log.matches) or {},
	}
	local used = {}
	local events = {}
	local order = 0
	local function Add(at, record)
		order = order + 1
		events[#events + 1] = { at = at, order = order, record = record }
	end

	-- Counter moves, in the probe's order: live kills, or a batch the probe
	-- counted without detail (leaving a battleground, a poll).
	local start, running
	for _, hk in ipairs(rings.hk) do
		if type(hk) == "table" and mine(hk.at) then
			local lifetime = Lifetime(hk)
			local delta = Num(hk.lifetimeDelta) or 0
			if lifetime then
				local before = delta > 0 and lifetime - delta or lifetime
				if running == nil then
					start, running = before, before
				elseif before > running then
					-- HKs the probe did not see, between two of its sessions.
					Add(hk.at, { type = "X", t = hk.at, bucket = "u", fromHK = running, toHK = before })
					running = before
				elseif before < running then
					return nil, "backwards"
				end
				if delta > 0 then
					local bucket = BUCKET[hk.bucket]
					if hk.reason == "PLAYER_PVP_KILLS_CHANGED" and bucket then
						local results = Results(hk)
						for index = 1, delta do
							local record = KillRecord(hk, bucket, results[index], rings, used, guild)
							record.lifeHK = before + index
							Add(hk.at, record)
						end
					else
						Add(hk.at, { type = "X", t = hk.at, bucket = "u", fromHK = before, toHK = lifetime })
					end
					running = lifetime
				end
			end
		end
	end
	if running == nil then return events, nil, nil end

	for _, death in ipairs(rings.deaths) do
		if type(death) == "table" and mine(death.at) then
			local record = DeathRecord(death)
			if record then Add(death.at, record) end
		end
	end

	local covered = {}
	for _, match in ipairs(rings.matches) do
		if type(match) == "table" and match.how == "complete" and mine(match.completeAt) then
			local record, from = MatchRecord(match)
			if record then
				covered[#covered + 1] = { from = from, to = match.completeAt }
				Add(match.completeAt, record)
			end
		end
	end

	-- Battleground HKs no scoreboard covers (the probe left or reloaded before
	-- the end): a match from the counter, like the addon's own fallback.
	local run
	local function CloseRun()
		if not run then return end
		Add(run.last + 1, {
			type = "M", t = run.last + 1, instanceID = run.instanceID, duration = run.last - run.first,
			hk = run.count, kb = 0, deaths = 0, honor = 0, live = run.count, lines = {},
		})
		run = nil
	end
	for _, event in ipairs(events) do
		local record = event.record
		if record.type == "K" and record.bucket == "b" then
			local inside = false
			for _, span in ipairs(covered) do
				if event.at >= span.from and event.at <= span.to then inside = true end
			end
			if not inside then
				if run and event.at - run.last > RUN_GAP then CloseRun() end
				if not run then
					run = { first = event.at, last = event.at, count = 0, instanceID = InstanceAt(rings.matches, event.at) }
				end
				run.last, run.count = event.at, run.count + 1
			end
		end
	end
	CloseRun()

	table.sort(events, function(a, b)
		if a.at ~= b.at then return a.at < b.at end
		return a.order < b.order
	end)
	return events, start, running
end

--------------------------------------------------------------------------------
-- The import itself
--------------------------------------------------------------------------------

-- Turns the probe's data for this character into its journal. current is the
-- lifetime count the server shows now. Returns a status and details:
-- "done" with the counts, or why nothing was written.
function Import.FromProbe(probe, current)
	local me = Identity.me
	if not me.guid then return "noData" end
	local author = ns.db.authors[me.guid]
	if author and (author.head or 0) > 0 then return "notEmpty" end
	if type(probe) ~= "table" then return "noProbe" end
	if Records.Holding() or #ns.db.pending > 0 then return "later" end
	if type(current) ~= "number" then return "noCounter" end
	local mine, any = SessionJudge(probe)
	if not any then return "noData" end
	local probeGuild = Tbl(probe.guild)
	local guild = (probeGuild and Str(probeGuild.name)) or me.guild
	local events, start, last = Build(probe, mine, guild)
	if not events then return "invalid", tostring(start) end
	if #events == 0 or start == nil then return "noData" end
	if last > current then return "mismatch", last, current end
	if current > last then
		-- Between the probe's last look and now: counted, not placed.
		local now = Util.Now()
		events[#events + 1] = { at = now, order = math.huge, record = { type = "X", t = now, bucket = "u", fromHK = last, toHK = current } }
	end

	-- Numbered and chained, then checked the way a page from a stranger is:
	-- all or nothing.
	local now = Util.Now()
	local list, decoded = {}, {}
	local running = start
	for index, event in ipairs(events) do
		local record = event.record
		record.seq = index
		if record.type == "X" then
			running = record.toHK
		elseif record.type ~= "K" then
			record.lifeHK = running
		else
			running = record.lifeHK
		end
		local text = Records.Encode(record)
		local copy = text and Records.Decode(text)
		if not copy then return "invalid", tostring(record.type) .. ":encode" end
		local ok, why = Records.Validate(copy, now)
		if not ok then return "invalid", tostring(record.type) .. ":" .. tostring(why) end
		list[index], decoded[index] = record, copy
	end
	local chained, breakAt = Records.CheckChain(decoded)
	if not chained then return "invalid", "chain:" .. tostring(breakAt) end

	local char = ns.Db.Character(me.guid)
	char.baselineHK = start
	char.lifeHK = current
	local counts = { records = 0, kills = 0, deaths = 0, matches = 0 }
	for _, record in ipairs(list) do
		record.seq = nil
		if Records.AppendOwn(record, "import") then
			counts.records = counts.records + 1
			if record.type == "K" then counts.kills = counts.kills + 1 end
			if record.type == "D" then counts.deaths = counts.deaths + 1 end
			if record.type == "M" then counts.matches = counts.matches + 1 end
		end
	end
	char.imported = { at = now, records = counts.records, kills = counts.kills, deaths = counts.deaths, matches = counts.matches }
	ns.Count("import.records", counts.records)
	Records.OwnProfile()
	ns.Fire("Imported", counts)
	return "done", counts
end

local function Report(manual, status, a, b)
	if status == "done" then
		ns.Print(L.IMPORT_DONE:format(a.records, a.kills, a.deaths, a.matches))
		return
	end
	-- Data that was there but could not be taken is worth a line in /kbs
	-- debug; having nothing to take is the usual case and stays quiet.
	if manual or status == "mismatch" or status == "invalid" then ns.Count("import." .. tostring(status)) end
	if not manual then return end
	if status == "notEmpty" then
		ns.Print(L.IMPORT_NOT_EMPTY)
	elseif status == "noProbe" then
		ns.Print(L.IMPORT_NO_PROBE)
	elseif status == "noData" then
		ns.Print(L.IMPORT_NO_DATA)
	elseif status == "mismatch" then
		ns.Print(L.IMPORT_MISMATCH:format(a, b))
	elseif status == "invalid" then
		ns.Print(L.IMPORT_INVALID:format(tostring(a)))
	elseif status == "noCounter" or status == "later" then
		ns.Print(L.IMPORT_NO_COUNTER)
	end
end

-- At login, once the counter is readable: the probe's data comes in on its
-- own the first time, silently when there is nothing to take.
function Import.AtLogin(current)
	local char = ns.Db.Character(Identity.me.guid)
	if char.imported then return end
	Report(false, Import.FromProbe(rawget(_G, "KBSProbeDB"), current))
end

-- /kbs import: the same, with the outcome said.
function Import.Manual()
	local char = ns.Db.Character(Identity.me.guid)
	if char.imported then
		ns.Print(L.IMPORT_ALREADY:format(char.imported.records or 0))
		return
	end
	Report(true, Import.FromProbe(rawget(_G, "KBSProbeDB"), ns.Detect.ReadLifeHK()))
end

ns.Hook("Debug", function()
	local char = Identity.me.guid and ns.Db.Character(Identity.me.guid) or nil
	local imported = char and char.imported
	if imported then
		ns.Print(("import: %d records from the probe at %s"):format(imported.records or 0, Util.Stamp(imported.at, true)))
	end
end)
