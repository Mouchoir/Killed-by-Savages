local _, ns = ...

--------------------------------------------------------------------------------
-- Detection
--
-- The server counts an honorable kill (HK) for each enemy we helped kill,
-- killing blow or not, and PLAYER_PVP_KILLS_CHANGED says when its lifetime
-- counter moved. A few seconds later each HK is matched with what was seen
-- around that moment: a killing blow by us or our group (PARTY_KILL), or
-- else an enemy player who died near us (UNIT_DIED). That gives the victim
-- of most kills; the rest are recorded as HKs with no victim.
--
-- Our own deaths come from PLAYER_DEAD and the death recap, which names the
-- killer. Inside a battleground nothing is matched: the HKs it gave are
-- counted from the counter when we leave. Everything here was measured on the
-- live client with the KBSProbe probe before being written.
--------------------------------------------------------------------------------

local Util = ns.Util
local Get, Safe, SECRET, Fn = Util.Get, Util.Safe, Util.SECRET, Util.Fn
local Records = ns.Records
local Identity = ns.Identity

local Detect = {}
ns.Detect = Detect

local MATCH_WINDOW = 2        -- seconds between an enemy's death and the HK it gave
local MATCH_DELAY = 3         -- an HK is matched this long after it, once all is in
local RING_SECONDS = 90       -- how long kills and deaths seen are kept around
local RECAP_DELAYS = { 0.5, 1, 1.5, 3, 4 }
local JUMP_DELAY = 1          -- a counter jump at login waits this long for a recovery
local DEATH_WINDOW = 3        -- a second PLAYER_DEAD this soon after one is the same death

local recentKills = {}        -- PARTY_KILL on players, newest last
local recentDeaths = {}       -- UNIT_DIED on players, newest last
local lastHK                  -- last readable lifetime count
local inBattleground = false
local bgEntry                 -- the match we are in: { lifeHK, at, name, instanceID, live, done }
local started = false
local lastDeathAt             -- when PLAYER_DEAD last fired
local SCORE_DELAYS = { 1, 3, 6 }

--------------------------------------------------------------------------------
-- Reading the counter
--------------------------------------------------------------------------------

-- The lifetime HK count, or nil when the client will not say (secret, error).
function Detect.ReadLifeHK()
	local lifetime = Get(GetPVPLifetimeStats)
	if type(lifetime) == "number" and lifetime >= 0 and lifetime == lifetime then return lifetime end
	return nil
end

function Detect.ReadTodayHK()
	local today = Get(GetPVPSessionStats)
	if type(today) == "number" then return today end
	return nil
end

local function Char()
	return ns.Db.Character(Identity.me.guid)
end

local function Trim(ring)
	local now = Util.Clock()
	while ring[1] and now - ring[1].clock > RING_SECONDS do
		table.remove(ring, 1)
	end
end

local function Bucket()
	local bucket = Util.Bucket()
	if bucket == "bg" then return "b" end
	if bucket == "world" then return "w" end
	return nil
end

--------------------------------------------------------------------------------
-- Who landed a killing blow, seen from here
--------------------------------------------------------------------------------

local function RoleOf(guid)
	local myGuid = Identity.PlainGuid("player")
	if guid == myGuid then return "me" end
	if guid == Identity.PlainGuid("pet") then return "mypet" end
	if Get(IsInRaid) == true then
		local count = Get(GetNumGroupMembers)
		if type(count) ~= "number" then count = 0 end
		for index = 1, count do
			if guid == Identity.PlainGuid("raid" .. index) then return "raid" end
			if guid == Identity.PlainGuid("raidpet" .. index) then return "raidpet" end
		end
		return "other"
	end
	for index = 1, 4 do
		if guid == Identity.PlainGuid("party" .. index) then return "party" end
		if guid == Identity.PlainGuid("partypet" .. index) then return "partypet" end
	end
	return "other"
end

local HOW_BY_ROLE = { me = "kb", mypet = "pet", party = "grp", partypet = "grp", raid = "grp", raidpet = "grp" }

--------------------------------------------------------------------------------
-- Events seen around us
--------------------------------------------------------------------------------

function Detect.OnPartyKill(attackerGuid, targetGuid)
	if inBattleground or Util.IsSecret(attackerGuid) or Util.IsSecret(targetGuid) then return end
	if Util.GuidKind(targetGuid) ~= "Player" or type(attackerGuid) ~= "string" then return end
	local role = RoleOf(attackerGuid)
	if not HOW_BY_ROLE[role] then
		ns.Count("detect.killByOther")
		return
	end
	-- Only an enemy gives an honorable kill: a player of our own faction
	-- killed where everyone fights everyone would otherwise be named as
	-- the victim of an HK that came for someone else at that moment.
	local facts = Identity.PlayerFacts(targetGuid)
	local faction = Identity.FactionOf(facts)
	if faction ~= nil and Identity.me.enemyFaction ~= nil and faction ~= Identity.me.enemyFaction then
		ns.Count("detect.killNotEnemy")
		return
	end
	Trim(recentKills)
	recentKills[#recentKills + 1] = {
		at = Util.Now(), clock = Util.Clock(), role = role, guid = targetGuid,
		facts = facts, pos = Util.Position(),
	}
	ns.Count("detect.kill." .. role)
end

function Detect.OnUnitDied(guid)
	if inBattleground or Util.IsSecret(guid) or Util.GuidKind(guid) ~= "Player" then return end
	if guid == Identity.me.guid then return end
	Trim(recentDeaths)
	recentDeaths[#recentDeaths + 1] = {
		at = Util.Now(), clock = Util.Clock(), guid = guid, facts = Identity.PlayerFacts(guid),
	}
end

--------------------------------------------------------------------------------
-- Matching an HK with its kill
--------------------------------------------------------------------------------

local function Around(ring, clock)
	local found = {}
	for index = #ring, 1, -1 do
		local item = ring[index]
		if clock - item.clock > MATCH_WINDOW + RING_SECONDS then break end
		if math.abs(item.clock - clock) <= MATCH_WINDOW then found[#found + 1] = item end
	end
	return found
end

local function IsEnemyDeath(death, killedGuids)
	if killedGuids[death.guid] then return false end
	local faction = Identity.FactionOf(death.facts)
	-- An unknown faction stays a candidate: only enemies give HKs.
	return faction == nil or faction == Identity.me.enemyFaction
end

local function VictimFields(facts)
	if type(facts) ~= "table" or facts.kind ~= "Player" then return {} end
	return {
		vtail = facts.tail, vname = Safe(facts.name) ~= SECRET and facts.name or nil,
		vclass = Safe(facts.class) ~= SECRET and facts.class or nil,
		vrace = Safe(facts.race) ~= SECRET and facts.race or nil,
		vlevel = type(facts.level) == "number" and facts.level > 0 and facts.level or nil,
	}
end

local function KillRecord(pending, how, facts, index)
	local record = {
		type = "K", t = pending.t, bucket = pending.bucket, how = how,
		mapID = pending.pos and pending.pos.mapID, x = pending.pos and pending.pos.x, y = pending.pos and pending.pos.y,
		guild = pending.guild, lifeHK = pending.lifeHK - pending.count + index,
	}
	for key, value in pairs(VictimFields(facts)) do record[key] = value end
	return record
end

-- Turns one pending HK event (count HKs at once) into kill records.
function Detect.MatchPending(pending)
	local count = pending.count
	local results = {}
	local killed = {}
	local kills = Around(recentKills, pending.clock)
	table.sort(kills, function(a, b)
		local rankA = (a.role == "me" or a.role == "mypet") and 1 or 2
		local rankB = (b.role == "me" or b.role == "mypet") and 1 or 2
		if rankA ~= rankB then return rankA < rankB end
		return math.abs(a.clock - pending.clock) < math.abs(b.clock - pending.clock)
	end)
	for _, kill in ipairs(kills) do
		killed[kill.guid] = true
		if #results < count and not kill.matched then
			kill.matched = true
			results[#results + 1] = { how = HOW_BY_ROLE[kill.role], facts = kill.facts }
		end
	end
	local left = count - #results
	if left > 0 then
		local deaths = {}
		for _, death in ipairs(Around(recentDeaths, pending.clock)) do
			if not death.matched and IsEnemyDeath(death, killed) then deaths[#deaths + 1] = death end
		end
		if #deaths > left then
			-- More enemies died than HKs came: not guessed.
			for _ = 1, left do results[#results + 1] = { how = "unk" } end
			ns.Count("detect.ambiguous")
		else
			for _, death in ipairs(deaths) do
				death.matched = true
				results[#results + 1] = { how = "ast", facts = death.facts }
			end
			for _ = #deaths + 1, left do results[#results + 1] = { how = "unk" } end
		end
	end
	for index, result in ipairs(results) do
		local record = KillRecord(pending, result.how, result.facts, index)
		Records.AppendOwn(record)
		ns.Count("detect.how." .. result.how)
	end
	return results
end

local function Resolve(pending)
	local list = ns.db.pending
	for index = #list, 1, -1 do
		if list[index] == pending then table.remove(list, index) end
	end
	Detect.MatchPending(pending)
end

--------------------------------------------------------------------------------
-- The counter moved
--------------------------------------------------------------------------------

function Detect.OnKillsChanged()
	if not started then return end
	local lifeHK = Detect.ReadLifeHK()
	if lifeHK == nil then
		ns.Count("detect.counterSecret")
		return
	end
	local previous = lastHK
	lastHK = lifeHK
	Char().lifeHK = lifeHK
	if previous == nil or lifeHK <= previous then return end
	local delta = lifeHK - previous
	if inBattleground then
		-- The counter is readable in a battleground but every enemy is
		-- secret: each HK is a kill with no victim, placed by its subzone.
		-- The scoreboard names the numbers at the end of the match.
		for index = 1, delta do
			Records.AppendOwn({
				type = "K", t = Util.Now(), bucket = "b", how = "bg", guild = Identity.me.guild,
				lifeHK = lifeHK - delta + index, sub = Get(GetSubZoneText),
			})
		end
		if bgEntry then bgEntry.live = (bgEntry.live or 0) + delta end
		ns.Count("detect.bgKill", delta)
		return
	end
	local bucket = Bucket()
	if not bucket then
		-- In a dungeon or an unknown place: counted, not placed.
		Records.AppendOwn({ type = "X", t = Util.Now(), bucket = "u", fromHK = previous, toHK = lifeHK })
		return
	end
	local pending = {
		t = Util.Now(), clock = Util.Clock(), bucket = bucket, count = delta, lifeHK = lifeHK,
		guild = Identity.me.guild, pos = Util.Position(),
	}
	local list = ns.db.pending
	list[#list + 1] = pending
	Util.After(MATCH_DELAY, "hk-match", Resolve, pending)
end

-- HKs left unmatched by a /reload or a crash become kills with no victim;
-- the kill events around them are gone.
local function ResolvePending()
	local list = ns.db.pending
	for index = #list, 1, -1 do
		local pending = list[index]
		table.remove(list, index)
		pending.clock = -RING_SECONDS * 10
		Detect.MatchPending(pending)
		ns.Count("detect.pendingAtLogin")
	end
end

--------------------------------------------------------------------------------
-- Login: baseline and counter jumps
--------------------------------------------------------------------------------

-- The counter moved while this addon was not running (a crash lost the
-- session, or HKs were earned before the install). Sync may recover the lost
-- records from the guild first; otherwise a counter record keeps the count.
function Detect.ResolveJump(fromHK, toHK)
	local char = Char()
	if not char.jump or char.jump.from ~= fromHK or char.jump.to ~= toHK then return end
	char.jump = nil
	Records.AppendOwn({ type = "X", t = Util.Now(), bucket = "u", fromHK = fromHK, toHK = toHK })
	ns.Count("detect.jump")
end

function Detect.Start()
	if started then return end
	local char = Char()
	local lifeHK = Detect.ReadLifeHK()
	if lifeHK == nil then
		ns.Count("detect.counterSecretAtLogin")
		Util.After(10, "detect-start", Detect.Start)
		return
	end
	started = true
	lastHK = lifeHK
	-- A journal still empty takes what the probe recorded before the addon
	-- existed; it sets the baseline itself.
	if ns.Import then Util.Guard("import", ns.Import.AtLogin, lifeHK) end
	-- HKs left unmatched by the last session belong before anything the
	-- counter did since: they are settled first. Then the journal is
	-- repaired where an older version broke its own chain.
	ResolvePending()
	Records.HealOwn()
	if char.baselineHK == nil then
		-- First run on this character: everything before is not ours to count.
		char.baselineHK = lifeHK
		char.lifeHK = lifeHK
		ns.Count("detect.baseline")
	elseif type(char.lifeHK) == "number" and lifeHK > char.lifeHK then
		char.jump = { from = char.lifeHK, to = lifeHK, at = Util.Now() }
		-- Sync may take the jump over (Detect.DeferJump) to recover the lost
		-- records from the guild before a counter record is written.
		ns.Fire("CounterJump", char.lifeHK, lifeHK)
		if char.jump and not char.jump.deferred then
			Util.After(JUMP_DELAY, "jump", Detect.ResolveJump, char.lifeHK, lifeHK)
		end
	end
	char.lifeHK = lifeHK
	Records.OwnProfile()
	inBattleground = Util.Bucket() == "bg"
	if inBattleground and not bgEntry then
		local instanceName, _, _, _, _, _, _, instanceID = Get(GetInstanceInfo)
		bgEntry = {
			lifeHK = lifeHK, at = Util.Now(), name = Safe(instanceName),
			instanceID = type(Safe(instanceID)) == "number" and Safe(instanceID) or nil, live = 0,
		}
	end
end

-- Sync calls this from the CounterJump hook to handle the jump itself: it
-- then ends it with Detect.CancelJump (records recovered) or
-- Detect.ResolveJump (nothing came back, write the counter record).
function Detect.DeferJump()
	local jump = Char().jump
	if jump then jump.deferred = true end
	return jump
end

function Detect.CancelJump()
	Char().jump = nil
end

--------------------------------------------------------------------------------
-- Our deaths
--------------------------------------------------------------------------------

local function KillerFields(first)
	local guid = first.sourceGUID
	if type(guid) ~= "string" or guid == SECRET then return nil end
	local kind = Util.GuidKind(guid)
	local fields = { spell = Safe(first.spellName) ~= SECRET and Safe(first.spellName) or nil }
	if kind == "Player" then
		local facts = Identity.PlayerFacts(guid)
		fields.kkind = "p"
		fields.ktail = facts.tail
		fields.kname = Safe(facts.name) ~= SECRET and facts.name or nil
		fields.kclass = Safe(facts.class) ~= SECRET and facts.class or nil
		fields.krace = Safe(facts.race) ~= SECRET and facts.race or nil
		if fields.kname == nil and Safe(first.sourceName) ~= SECRET then fields.kname = Safe(first.sourceName) end
		return fields
	elseif kind == "Pet" then
		-- The recap does not name a pet's owner; the pet's name is kept.
		fields.kkind = "e"
		fields.kname = Safe(first.sourceName) ~= SECRET and Safe(first.sourceName) or nil
		return fields
	end
	return nil
end

local function ReadRecap(death)
	if not (C_DeathRecap and Fn(C_DeathRecap.GetRecapEvents)) then return true, nil end
	if Get(C_DeathRecap.HasRecapEvents) ~= true then return false end
	local ok, events = pcall(C_DeathRecap.GetRecapEvents)
	if not ok or Util.IsSecret(events) or Util.IsSecretTable(events) or type(events) ~= "table" then
		return true, nil
	end
	local first = events[1]
	if type(first) ~= "table" or Util.IsSecretTable(first) then return true, nil end
	local okRead, fields = pcall(KillerFields, first)
	if not okRead then return true, nil end
	return true, fields
end

function Detect.OnPlayerDead()
	if not started then return end
	-- The client fires PLAYER_DEAD twice at times, within the same second:
	-- one death, one record.
	local now = Util.Now()
	if lastDeathAt and now - lastDeathAt < DEATH_WINDOW then
		ns.Count("detect.deathRepeated")
		return
	end
	lastDeathAt = now
	local bucket = Bucket()
	if not bucket then return end
	-- The recap is readable in battlegrounds too; the position is not.
	local death = { t = now, bucket = bucket, pos = Util.Position(), lifeHK = lastHK, sub = Get(GetSubZoneText) }
	local attempt = 0
	local function try()
		attempt = attempt + 1
		local done, fields = ReadRecap(death)
		if done then
			if fields then
				local record = {
					type = "D", t = death.t, bucket = death.bucket, lifeHK = death.lifeHK or Detect.ReadLifeHK() or 0,
					mapID = death.pos.mapID, x = death.pos.x, y = death.pos.y, sub = death.bucket == "b" and death.sub or nil,
				}
				for key, value in pairs(fields) do record[key] = value end
				Records.AppendOwn(record)
				ns.Count("detect.death." .. fields.kkind)
			else
				ns.Count("detect.deathNotPvp")
			end
			return
		end
		if attempt < #RECAP_DELAYS then
			Util.After(RECAP_DELAYS[attempt + 1], "recap", try)
		else
			ns.Count("detect.deathNoRecap")
		end
	end
	Util.After(RECAP_DELAYS[1], "recap", try)
end

--------------------------------------------------------------------------------
-- Battlegrounds
--
-- The scoreboard is secret during a match and fully readable once it is
-- over: my row, and the row of every guild teammate, with or without the
-- addon, go into one match record.
--------------------------------------------------------------------------------

local function ReadRow(info)
	if Util.IsSecret(info) or Util.IsSecretTable(info) or type(info) ~= "table" then return nil end
	local row = {
		name = Safe(info.name), guid = Safe(info.guid), kb = Safe(info.killingBlows), hk = Safe(info.honorableKills),
		deaths = Safe(info.deaths), honor = Safe(info.honorGained), faction = Safe(info.faction),
		damage = Safe(info.damageDone), healing = Safe(info.healingDone),
	}
	for _, key in ipairs({ "kb", "hk", "deaths", "honor" }) do
		if type(row[key]) ~= "number" then return nil end
	end
	return row
end

-- The scoreboard, or nil while it is still secret or empty.
local function ReadScoreboard()
	local me = Identity.me
	if not (C_PvP and Fn(C_PvP.GetScoreInfo)) then return nil end
	local count = Get(GetNumBattlefieldScores)
	if type(count) ~= "number" or count == 0 then return nil end
	local mine
	if me.guid and Fn(C_PvP.GetScoreInfoByPlayerGuid) then
		local ok, info = pcall(C_PvP.GetScoreInfoByPlayerGuid, me.guid)
		if ok then mine = ReadRow(info) end
	end
	local lines = {}
	for index = 1, count do
		local ok, info = pcall(C_PvP.GetScoreInfo, index)
		local row = ok and ReadRow(info) or nil
		if row then
			local guid = type(row.guid) == "string" and row.guid or nil
			local isMe = guid and guid == me.guid or Identity.IsMe(row.name, guid)
			if isMe then
				mine = mine or row
			else
				local member = Identity.Member(row.name)
				local tail = Util.Tail(guid) or (member and member.tail) or nil
				if member and tail and (not member.tail or member.tail == tail) then
					lines[#lines + 1] = { tail = tail, name = row.name, kb = row.kb, hk = row.hk, deaths = row.deaths, honor = row.honor }
				end
			end
		end
	end
	if not mine then return nil end
	return mine, lines
end

local function WriteMatch(entry, mine, lines, lifeHK)
	local pos = Util.Position()
	Records.AppendOwn({
		type = "M", t = Util.Now(), instanceID = entry.instanceID, duration = entry.at and (Util.Now() - entry.at) or nil,
		winner = entry.winner, hk = mine.hk, kb = mine.kb, deaths = mine.deaths, honor = mine.honor,
		damage = type(mine.damage) == "number" and mine.damage or nil, healing = type(mine.healing) == "number" and mine.healing or nil,
		lifeHK = lifeHK, live = math.min(entry.live or 0, mine.hk), mapID = pos.mapID, lines = lines,
	})
	entry.done = true
	ns.Count("detect.bgMatch")
end

local function TryScoreboard(entry, attempt)
	if entry.done or bgEntry ~= entry then return end
	local mine, lines = ReadScoreboard()
	local lifeHK = Detect.ReadLifeHK() or lastHK or 0
	if mine then
		WriteMatch(entry, mine, lines, lifeHK)
		return
	end
	if attempt < #SCORE_DELAYS then
		pcall(RequestBattlefieldScoreData)
		Util.After(SCORE_DELAYS[attempt + 1], "scoreboard", TryScoreboard, entry, attempt + 1)
	else
		ns.Count("detect.scoreboardUnreadable")
	end
end

function Detect.OnMatchComplete(winner)
	if not inBattleground or not bgEntry then return end
	bgEntry.winner = type(Safe(winner)) == "number" and Safe(winner) or Get(GetBattlefieldWinner)
	if type(bgEntry.winner) ~= "number" then bgEntry.winner = nil end
	pcall(RequestBattlefieldScoreData)
	Util.After(SCORE_DELAYS[1], "scoreboard", TryScoreboard, bgEntry, 1)
end

function Detect.OnEnteringWorld()
	local now = Util.Bucket() == "bg"
	if now and not inBattleground then
		inBattleground = true
		local instanceName, _, _, _, _, _, _, instanceID = Get(GetInstanceInfo)
		bgEntry = {
			lifeHK = Detect.ReadLifeHK() or lastHK, at = Util.Now(), name = Safe(instanceName),
			instanceID = type(Safe(instanceID)) == "number" and Safe(instanceID) or nil, live = 0,
		}
		recentKills, recentDeaths = {}, {}
		ns.Count("detect.bgEnter")
	elseif not now and inBattleground then
		inBattleground = false
		local lifeHK = Detect.ReadLifeHK()
		local entry = bgEntry
		bgEntry = nil
		-- No scoreboard came: the counter still says how many HKs the match
		-- gave, and that much is kept.
		if entry and not entry.done and lifeHK and type(entry.lifeHK) == "number" and lifeHK > entry.lifeHK then
			WriteMatch(entry, { hk = lifeHK - entry.lifeHK, kb = 0, deaths = 0, honor = 0 }, {}, lifeHK)
			ns.Count("detect.bgMatchFallback")
		end
		if lifeHK then
			lastHK = lifeHK
			Char().lifeHK = lifeHK
		end
		ns.Count("detect.bgLeave")
	end
end

function Detect.InBattleground()
	return inBattleground
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

ns.On("PARTY_KILL", Detect.OnPartyKill)
ns.On("UNIT_DIED", Detect.OnUnitDied)
ns.On("PLAYER_PVP_KILLS_CHANGED", Detect.OnKillsChanged)
ns.On("PLAYER_DEAD", Detect.OnPlayerDead)
ns.On("PVP_MATCH_COMPLETE", Detect.OnMatchComplete)
ns.Hook("Login", Detect.Start)
ns.Hook("EnteringWorld", Detect.OnEnteringWorld)
ns.Hook("Debug", function()
	ns.Print(("detect: started %s, lifeHK %s, in BG %s, pending %d, recent kills %d, deaths %d"):format(
		tostring(started), tostring(lastHK), tostring(inBattleground), #ns.db.pending, #recentKills, #recentDeaths))
end)
