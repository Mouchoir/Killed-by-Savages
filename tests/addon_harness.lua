-- Headless test of addon/KilledBySavages against fake Forever clients.
-- Run from the repo root with LuaJIT (Lua 5.1, like the game):
--
--   luajit tests/addon_harness.lua
--
-- The fake client is tests/forever_mock.lua. Names are fictional.

local Mock = dofile("tests/forever_mock.lua")

math.randomseed(11)

local check, section = Mock.check, Mock.section
local SECRET, advance, Serialize = Mock.SECRET, Mock.advance, Mock.Serialize
local Guid, HORDE = Mock.Guid, Mock.HORDE

local function NewClient(spec)
	spec.addon = Mock.ADDON
	return Mock.NewClient(spec)
end

local function count(table_)
	local n = 0
	for _ in pairs(table_) do n = n + 1 end
	return n
end

-- The decoded records of a client's own journal, in seq order.
local function Journal(client)
	local ns = client.ns
	local author = client.db().authors[client.guid]
	local list = {}
	if not author then return list end
	for seq = 1, author.head or 0 do
		local text = author.log[seq]
		if text then list[#list + 1] = ns.Records.Decode(text) end
	end
	return list
end

local function Last(client)
	local list = Journal(client)
	return list[#list]
end

-- One HK on a client. Forever fires the event twice for it.
local function GainHK(client, amount)
	local st = client.state
	st.lifetime, st.session = st.lifetime + (amount or 1), st.session + (amount or 1)
	client.fire("PLAYER_PVP_KILLS_CHANGED", "player")
	client.fire("PLAYER_PVP_KILLS_CHANGED", "player")
end

--------------------------------------------------------------------------------
-- The cast
--------------------------------------------------------------------------------

local A = NewClient({
	name = "Aldric Stormhand", guid = Guid(1), class = "HUNTER", race = "Human", guild = "Savages",
	pet = "Pet-0-1234-1-0000AAA1", lifetime = 500, battleTag = "Aldric#2101", rank = 0,
})
local B = NewClient({
	name = "Brenna Ironvale", guid = Guid(2), class = "WARLOCK", race = "Dwarf", guild = "Savages",
	pet = "Pet-0-1234-1-0000BBB2", lifetime = 1200, battleTag = "Brenna#1188", rank = 2,
})
local C = NewClient({ name = "Corwin Ashdown", guid = Guid(3, 1235), class = "WARRIOR", guild = "Savages", lifetime = 80, rank = 4 })
Mock.AddPlayer(Guid(5), { name = "Edric Vale", class = "PALADIN", race = "Human", faction = "Alliance", guild = "Savages" })
Mock.SetGuildRoster({ { guid = A.guid, rank = 0 }, { guid = B.guid, rank = 2 }, { guid = C.guid, rank = 4 }, { guid = Guid(5), rank = 3 } })

--------------------------------------------------------------------------------
section("Records: codec, validation, chain")
--------------------------------------------------------------------------------

A.login()
advance(10)
local Records = A.ns.Records
local kill = {
	type = "K", seq = 7, t = 1794009143, bucket = "w", how = "kb", vtail = "6938-00ABCDEF", vname = "Grol Ashtusk",
	vclass = "WARRIOR", vrace = "Orc", vlevel = 16, mapID = 52, x = 0.4321, y = 0.6789, guild = "Savages", lifeHK = 12,
}
local text = Records.Encode(kill)
check("a kill encodes to one line", text == "K1;7;1794009143;w;kb;6938-00ABCDEF;Grol Ashtusk;WARRIOR;Orc;16;52;0.4321;0.6789;Savages;12;", text)
local back = Records.Decode(text)
check("and decodes back", back.type == "K" and back.seq == 7 and back.vname == "Grol Ashtusk" and back.x == 0.4321 and back.lifeHK == 12)
check("decoding is cached", Records.Decode(text) == back)
check("fields with separators are flattened", Records.Encode({ type = "K", seq = 1, t = 1, bucket = "w", how = "unk",
	guild = "A;B^C", lifeHK = 1 }):find("A B C", 1, true) ~= nil)
local death = Records.Decode(Records.EncodeDeath({ seq = 8, t = 1794009577, bucket = "w", ktail = "6938-00AA00BB",
	kname = "Walter Zornickel", kclass = "HUNTER", krace = "Orc", kkind = "p", spell = "Tir des arcanes", mapID = 52, x = 0.1, y = 0.2, lifeHK = 12 }))
check("a death decodes", death.type == "D" and death.kname == "Walter Zornickel" and death.kkind == "p" and death.spell == "Tir des arcanes")
local match = Records.Decode("M1;9;1794010000;489;900;1;21;3;2;450;12000;300;523;21;1459;1234-00000005:Edric Vale:4:25:1:300,1234-00000002:Brenna Ironvale:1:9:3:80")
check("a match decodes with its scoreboard", match.type == "M" and match.bucket == "b" and match.hk == 21 and match.kb == 3 and match.live == 21
	and match.instanceID == 489 and match.lifeHK == 523 and #match.lines == 2 and match.lines[1].name == "Edric Vale" and match.lines[1].hk == 25
	and match.lines[2].tail == "1234-00000002")
check("a match round-trips through its encoder", Records.Encode(match) == "M1;9;1794010000;489;900;1;21;3;2;450;12000;300;523;21;1459;1234-00000005:Edric Vale:4:25:1:300,1234-00000002:Brenna Ironvale:1:9:3:80", Records.Encode(match))
check("the same match is recognised from every member's record", Records.SameMatch(match, Records.Decode("M1;2;1794010030;489;;;5;0;1;;;;10;0;;")) == true
	and Records.SameMatch(match, Records.Decode("M1;2;1794010030;529;;;5;0;1;;;;10;0;;")) == false
	and Records.SameMatch(match, Records.Decode("M1;2;1794010200;489;;;5;0;1;;;;10;0;;")) == false)
check("live HKs of a match do not count twice in the chain", Records.Gain(match) == 0 and Records.Gain(Records.Decode("M1;2;1794010030;489;;;5;0;1;;;;10;2;;")) == 3)
local counter = Records.Decode("X1;10;1794010100;u;19;24")
check("a counter record decodes", counter.type == "X" and counter.fromHK == 19 and counter.toHK == 24)
check("an unknown record type is ignored", Records.Decode("Z9;1;2;3") == nil and Records.Decode("K2;1;2") == nil)
local profile = Records.DecodeProfile(Records.EncodeProfile({ name = "Aldric Stormhand", class = "HUNTER", race = "Human",
	realm = "Ashbringer", playerKey = "a1bf6c73", alias = "Aldric", level = 60, baselineHK = 500, lifeHK = 512, version = "0.1.0" }))
check("a profile round-trips", profile.name == "Aldric Stormhand" and profile.playerKey == "a1bf6c73" and profile.baselineHK == 500)

local now = Mock.Server()
local plausible = Records.Decode((text:gsub("1794009143", tostring(now - 60))))
check("a plausible kill validates", Records.Validate(plausible, now) == true, select(2, Records.Validate(plausible, now)))
check("a kill from the future is refused", select(2, Records.Validate(Records.Decode(Records.Encode({ type = "K", seq = 1,
	t = now + 3600, bucket = "w", how = "unk", lifeHK = 1 })), now)) == "future")
check("a named kill needs a victim tail", select(2, Records.Validate(Records.Decode("K1;1;100;w;kb;;Someone;MAGE;Orc;;;;;;1"), now)) == "victim")
check("a level over 60 is refused", select(2, Records.Validate(Records.Decode("K1;1;100;w;kb;1-00000001;X Y;MAGE;Orc;99;;;;;1"), now)) == "level")
check("a counter record must go up", select(2, Records.Validate(Records.Decode("X1;1;100;u;5;5"), now)) == "range")

local chain = {
	Records.Decode("K1;1;100;w;unk;;;;;;;;;;501"),
	Records.Decode("K1;2;110;w;unk;;;;;;;;;;502"),
	Records.Decode("D1;3;120;w;;;;;p;;;;;502"),
	Records.Decode("M1;4;130;489;600;1;3;1;0;100;;;505;0;1459;"),
	Records.Decode("X1;5;140;u;505;509"),
	Records.Decode("K1;6;150;w;unk;;;;;;;;;;510"),
}
check("a consistent chain passes", Records.CheckChain(chain) == true)
chain[6] = Records.Decode("K1;6;150;w;unk;;;;;;;;;;512")
local okChain, breakAt = Records.CheckChain(chain)
check("a jump in the chain is caught at its seq", okChain == false and breakAt == 6, breakAt)
local gapped = { Records.Decode("K1;1;100;w;unk;;;;;;;;;;501"), Records.Decode("K1;5;150;w;unk;;;;;;;;;;540") }
check("a gap is not a break", Records.CheckChain(gapped) == true)

--------------------------------------------------------------------------------
section("Login: identity, baseline, roster, officers")
--------------------------------------------------------------------------------

local a = A.db()
local me = A.ns.Identity.me
check("the character is known by guid and tail", me.guid == Guid(1) and me.tail == "1234-00000001", me.tail)
check("the name carries the surname", me.name == "Aldric Stormhand" and me.surname == "Stormhand")
check("the enemy is the other faction", me.faction == "Alliance" and me.enemyFaction == "Horde")
check("the player key is the salted BattleTag hash", me.playerKey == Mock.Fnv("KBS:Aldric#2101"), me.playerKey)
check("the tag itself is nowhere in the saved data", not Serialize(a):find("Aldric#2101", 1, true))
local char = a.characters[Guid(1)]
check("the first run sets the HK baseline", char and char.baselineHK == 500 and char.lifeHK == 500)
check("the own profile is kept with the journal", a.authors[Guid(1)].own == true and a.authors[Guid(1)].profile.baselineHK == 500)
check("the roster maps names to guids and ranks", A.ns.Identity.Member("Brenna Ironvale").tail == "1234-00000002"
	and A.ns.Identity.MemberByTail("1235-00000003").rankIndex == 4)
check("a realm suffix or a dash still finds the member", A.ns.Identity.Member("Corwin-Ashdown-Ashbringer") ~= nil)
check("officers are the ranks with officer chat, not a fixed count",
	A.ns.Identity.IsOfficerRank(2) == true and A.ns.Identity.IsOfficerRank(3) == false)
check("the guild master is an officer", A.ns.Identity.IsOfficer() == true)
check("the officer flag check agreed with the client", a.debug.officerFlag and a.debug.officerFlag.byFlag == true and a.counter == nil
	and A.counter("officerFlagMismatch") == 0)
check("every frFR string has an English key", (function()
	for key in pairs(A.ns.LocaleKeys.frFR) do
		if not A.ns.LocaleKeys.enUS[key] then return false end
	end
	return true
end)())
check("the version comes from the TOC", A.ns.VERSION == "0.1.0-test", A.ns.VERSION)
A.slash("status")
check("/kbs status answers", A.said("Version 0.1.0-test") and A.said("Savages"))

--------------------------------------------------------------------------------
section("Kills in the world")
--------------------------------------------------------------------------------

-- My own killing blow: PARTY_KILL, the enemy's death, then the HK.
A.state.target = HORDE[1].guid
A.fire("PARTY_KILL", A.guid, HORDE[1].guid)
A.fire("UNIT_DIED", HORDE[1].guid)
GainHK(A)
advance(5)
local record = Last(A)
check("my killing blow becomes a kill record", record and record.type == "K" and record.how == "kb", record and record.how)
check("with the victim named from the GUID", record.vtail == "1234-00000065" and record.vname == "Gruk Bonecrusher" and record.vrace == "Orc" and record.vclass == "WARRIOR")
check("with level and position", record.vlevel == 60 and record.mapID == 1424 and record.x == 0.6123)
check("with the guild and the counter after the kill", record.guild == "Savages" and record.lifeHK == 501)
check("the counter is remembered for the next login", a.characters[Guid(1)].lifeHK == 501)
check("the pending HK was cleared", #a.pending == 0)

-- A groupmate's blow that gives me the HK too.
A.state.group = { kind = "party", others = { { guid = B.guid, pet = B.state.pet } } }
A.fire("PARTY_KILL", B.guid, HORDE[2].guid)
A.fire("UNIT_DIED", HORDE[2].guid)
GainHK(A)
advance(5)
check("a groupmate's blow with my HK is a group kill", Last(A).how == "grp" and Last(A).vname == "Zaljin Darkspear")

-- A groupmate's pet.
A.fire("PARTY_KILL", B.state.pet, HORDE[3].guid)
GainHK(A)
advance(5)
check("a groupmate's pet counts as the group's blow", Last(A).how == "grp" and Last(A).vname == "Moro Stillwind")

-- My own pet.
A.fire("PARTY_KILL", A.state.pet, HORDE[4].guid)
GainHK(A)
advance(5)
check("my pet's blow is a pet kill", Last(A).how == "pet")

-- A groupmate's blow with no HK for me is nothing for me.
local before = #Journal(A)
A.fire("PARTY_KILL", B.guid, HORDE[5].guid)
advance(5)
check("a group blow without my HK is not my kill", #Journal(A) == before)

-- An assist, as seen in game: the enemy dies next to us, the HK comes 0.24 s
-- later, nobody in the group landed the blow.
A.state.nameplates = { nameplate1 = HORDE[6].guid }
A.fire("UNIT_DIED", HORDE[6].guid)
advance(0.24)
GainHK(A)
advance(5)
record = Last(A)
check("an HK with no blow in the group names the enemy who died", record.how == "ast" and record.vname == "Vexa Cinderhorn" and record.vrace == "Tauren")
A.state.nameplates = nil

-- A friendly death at that moment is never the victim.
A.fire("UNIT_DIED", Guid(5))
GainHK(A)
advance(5)
check("a friendly death is not taken for the victim", Last(A).how == "unk" and Last(A).vtail == nil)

-- Two enemies die together for one HK: not guessed.
A.fire("UNIT_DIED", HORDE[1].guid)
A.fire("UNIT_DIED", HORDE[2].guid)
GainHK(A)
advance(5)
check("one HK for two enemy deaths stays unnamed", Last(A).how == "unk" and A.counter("detect.ambiguous") == 1)

-- Two HKs at once for two enemy deaths: both named, counters in order.
A.fire("UNIT_DIED", HORDE[3].guid)
A.fire("UNIT_DIED", HORDE[4].guid)
GainHK(A, 2)
advance(5)
local journal = Journal(A)
local penultimate, ultimate = journal[#journal - 1], journal[#journal]
check("two HKs for two enemy deaths name both", penultimate.how == "ast" and ultimate.how == "ast" and penultimate.vname ~= ultimate.vname)
check("and chain their counters", penultimate.lifeHK + 1 == ultimate.lifeHK and ultimate.lifeHK == A.state.lifetime)
check("the chain of the whole journal holds", Records.CheckChain(Journal(A)) == true)
A.state.group = nil

-- A death 4 s before the HK is not its victim.
A.fire("UNIT_DIED", HORDE[5].guid)
advance(4)
GainHK(A)
advance(5)
check("a death 4 s before the HK is not its victim", Last(A).how == "unk")

-- A kill by someone outside the group is not ours even with an HK nearby.
before = #Journal(A)
A.fire("PARTY_KILL", "Player-1234-0000FFFF", HORDE[6].guid)
advance(5)
check("a blow by a stranger records nothing", #Journal(A) == before and A.counter("detect.killByOther") == 1)

-- Every record so far was broadcast to the modules.
check("each record fired RecordAdded", A.counter("records.own.K") == #Journal(A))

--------------------------------------------------------------------------------
section("Deaths")
--------------------------------------------------------------------------------

A.state.recap = { {
	sourceName = "Gruk Bonecrusher", sourceGUID = HORDE[1].guid, sourceFlags = 0x548,
	destName = "Aldric Stormhand", destGUID = A.guid, spellName = "Frappe mortelle", spellId = 12294,
	amount = 1450, overkill = 120, hideCaster = false, timestamp = 12345.6, event = "SPELL_DAMAGE",
} }
A.state.recapReadyAt = Mock.Now() + 1.2
A.fire("PLAYER_DEAD")
advance(6)
record = Last(A)
check("a PvP death is recorded with its killer", record.type == "D" and record.kkind == "p" and record.kname == "Gruk Bonecrusher" and record.krace == "Orc")
check("with the spell and the position", record.spell == "Frappe mortelle" and record.mapID == 1424)
check("and the unchanged counter", record.lifeHK == A.state.lifetime)

A.state.recap = { { sourceName = "Schwarzesau", sourceGUID = "Pet-0-1234-1-0000CCC3", sourceFlags = 0x1148, spellName = "Morsure" } }
A.state.recapReadyAt = Mock.Now()
A.fire("PLAYER_DEAD")
advance(6)
check("a pet's blow is recorded as a pet with its name", Last(A).type == "D" and Last(A).kkind == "e" and Last(A).kname == "Schwarzesau")

before = #Journal(A)
A.state.recap = { { sourceName = "Chok'sul", sourceGUID = "Creature-0-1234-0-1-2738-0000ABCD", sourceFlags = 0xA48, spellName = nil } }
A.fire("PLAYER_DEAD")
advance(6)
check("a death to a creature is not recorded", #Journal(A) == before and A.counter("detect.deathNotPvp") == 1)

-- A death in the seconds an HK still waits to be matched: the death is
-- written first and must carry the count the chain stands at, not the
-- counter already moved by the kill written after it.
local beforePending = A.state.lifetime
GainHK(A)
A.state.recap = { {
	sourceName = "Gruk Bonecrusher", sourceGUID = HORDE[1].guid, sourceFlags = 0x548,
	destName = "Aldric Stormhand", destGUID = A.guid, spellName = "Frappe mortelle", spellId = 12294,
} }
A.state.recapReadyAt = Mock.Now()
A.fire("PLAYER_DEAD")
advance(6)
local journalA = Journal(A)
local pendingDeath, pendingKill = journalA[#journalA - 1], journalA[#journalA]
check("a death during a pending kill comes first with the count before the kill", pendingDeath.type == "D" and pendingKill.type == "K"
	and pendingDeath.lifeHK == beforePending and pendingKill.lifeHK == beforePending + 1 and Records.CheckChain(journalA) == true,
	("%s %s / %s %s"):format(pendingDeath.type, tostring(pendingDeath.lifeHK), pendingKill.type, tostring(pendingKill.lifeHK)))

before = #Journal(A)
A.state.recap = nil
A.fire("PLAYER_DEAD")
advance(12)
check("no recap is counted, not recorded", #Journal(A) == before and A.counter("detect.deathNoRecap") == 1)

-- The client fires PLAYER_DEAD twice at times, within the same second: one
-- death, one record.
before = #Journal(A)
A.state.recap = { { sourceName = "Gruk Bonecrusher", sourceGUID = HORDE[1].guid, sourceFlags = 0x548, spellName = "Frappe mortelle" } }
A.state.recapReadyAt = Mock.Now()
A.fire("PLAYER_DEAD")
A.fire("PLAYER_DEAD")
advance(6)
check("a second PLAYER_DEAD in the same second is the same death", #Journal(A) == before + 1 and A.counter("detect.deathRepeated") == 1,
	#Journal(A) - before)
advance(10)
A.fire("PLAYER_DEAD")
advance(6)
check("a death seconds later is a new one", #Journal(A) == before + 2 and A.counter("detect.deathRepeated") == 1)

-- A journal written before that fix can hold the same death twice in a
-- row: the stats count it once.
-- In a guild of its own, so nothing of it reaches the others.
local Thane = NewClient({ name = "Thane Ironward", guid = Guid(41), class = "WARRIOR", race = "Dwarf", guild = "Ironward Company", lifetime = 40, rank = 3 })
Thane.login()
advance(5)
local twice = {
	type = "D", t = Mock.Server(), bucket = "w", ktail = Thane.ns.Util.Tail(HORDE[1].guid), kname = "Gruk Bonecrusher", kclass = "WARRIOR",
	krace = "Orc", kkind = "p", spell = "Frappe mortelle", mapID = 1424, x = 0.4, y = 0.5, lifeHK = 40,
}
for _ = 1, 2 do
	local copy = {}
	for key, value in pairs(twice) do copy[key] = value end
	Thane.ns.Records.AppendOwn(copy)
end
local tStats = Thane.ns.Stats.Character(Thane.guid, "all", "w")
check("the same death twice in a row counts once in the stats", #Journal(Thane) == 2 and tStats.deaths == 1
	and Thane.ns.Stats.AuthorAggregate(Thane.guid).repeated == 1, tStats.deaths)
check("and shows once in the feed", #Thane.ns.Stats.Feed(10, "w") == 1, #Thane.ns.Stats.Feed(10, "w"))

--------------------------------------------------------------------------------
section("Battlegrounds")
--------------------------------------------------------------------------------

-- As seen in game: the counter and the recap stay readable in a
-- battleground, enemies and the scoreboard are secret until the match ends,
-- and chat is in lockdown.
local function EnterBG(client)
	local st = client.state
	st.bucket, st.zone, st.subzone, st.mapID = "bg", "Vallée d'Alterac", "Pic de Dun Baldar", 1459
	st.secretIdentity, st.secretStats, st.secretScore, st.chatLocked = true, false, true, true
	st.score = nil
	client.fire("PLAYER_ENTERING_WORLD", false, false)
end

local function LeaveBG(client)
	local st = client.state
	st.bucket, st.zone, st.subzone, st.mapID = "world", "Contreforts de Hautebrande", "Moulin-de-Tarren", 1424
	st.secretIdentity, st.secretStats, st.secretScore, st.chatLocked = false, false, false, false
	st.score = nil
	client.fire("PLAYER_ENTERING_WORLD", false, false)
end

before = #Journal(A)
EnterBG(A)
A.fire("PARTY_KILL", SECRET, SECRET)
A.fire("UNIT_DIED", SECRET)
A.state.lifetime = A.state.lifetime + 3
A.fire("PLAYER_PVP_KILLS_CHANGED", "player")
advance(5)
check("HKs inside a battleground are kills with no victim, placed by subzone", #Journal(A) == before + 3 and Last(A).type == "K"
	and Last(A).how == "bg" and Last(A).bucket == "b" and Last(A).vtail == nil and Last(A).sub == "Pic de Dun Baldar", Last(A).how)
check("their counters chain", Last(A).lifeHK == A.state.lifetime and Records.CheckChain(Journal(A)) == true)
A.state.recap = { { sourceName = "Ren Steelfeather", sourceGUID = HORDE[6].guid, sourceFlags = 0x548, spellName = "Morsure de serpent" } }
A.state.recapReadyAt = Mock.Now()
A.fire("PLAYER_DEAD")
advance(6)
check("a death in a battleground is recorded with its killer", Last(A).type == "D" and Last(A).bucket == "b" and Last(A).kname == "Vexa Cinderhorn"
	and Last(A).sub == "Pic de Dun Baldar")
A.state.recap = nil

-- The match ends: the scoreboard opens up, with a guildmate who has no addon.
A.state.score = {
	{ name = "Aldric Stormhand", guid = A.guid, kb = 3, hk = 3, deaths = 1, honor = 120, faction = 1, class = "HUNTER", race = "Humain" },
	{ name = "Edric Vale", guid = Guid(5), kb = 4, hk = 25, deaths = 1, honor = 300, faction = 1, class = "PALADIN", race = "Humain" },
	{ name = "Gruk Bonecrusher", guid = HORDE[1].guid, kb = 6, hk = 30, deaths = 5, honor = 700, faction = 0, class = "WARRIOR", race = "Orc" },
}
A.state.secretScore = false
A.state.winner = 1
before = #Journal(A)
A.fire("PVP_MATCH_COMPLETE", 1, 905)
advance(8)
record = Last(A)
check("the end of the match writes the scoreboard", #Journal(A) == before + 1 and record.type == "M" and record.hk == 3 and record.kb == 3
	and record.deaths == 1 and record.honor == 120 and record.live == 3 and record.winner == 1, record and record.type)
check("with the guild teammates on the board, not the enemies", #record.lines == 1 and record.lines[1].tail == "1234-00000005"
	and record.lines[1].name == "Edric Vale" and record.lines[1].kb == 4 and record.lines[1].hk == 25)
check("the match adds nothing to the chain the live kills already counted", Records.Gain(record) == 0 and Records.CheckChain(Journal(A)) == true)
LeaveBG(A)
advance(1)
check("leaving a finished match records nothing more", #Journal(A) == before + 1)

-- A match whose scoreboard never came, in another battleground: the
-- counter's delta is kept.
A.state.instanceID, A.state.instanceName = 489, "Goulet des Chanteguerres"
EnterBG(A)
A.state.lifetime = A.state.lifetime + 2
A.fire("PLAYER_PVP_KILLS_CHANGED", "player")
advance(5)
LeaveBG(A)
advance(1)
record = Last(A)
check("without a scoreboard, leaving keeps the counter's delta", record.type == "M" and record.hk == 2 and record.live == 2 and #record.lines == 0
	and A.counter("detect.bgMatchFallback") == 1, record and record.type)
check("the chain still holds", Records.CheckChain(Journal(A)) == true)
A.state.instanceID, A.state.instanceName = nil, nil

-- A battleground that gave nothing records nothing.
before = #Journal(A)
EnterBG(A)
LeaveBG(A)
advance(1)
check("a battleground without HKs records nothing", #Journal(A) == before)

--------------------------------------------------------------------------------
section("Reload, crash, counter jumps")
--------------------------------------------------------------------------------

-- A /reload right after an HK: the match is done at the next login, with no
-- victim since the events around it are gone.
A.fire("UNIT_DIED", HORDE[1].guid)
GainHK(A)
A.logout()
check("the unmatched HK is saved as pending", #A.saved.pending == 1)
A.login()
advance(10)
check("it becomes a kill without a victim at login", Last(A).type == "K" and Last(A).how == "unk" and #A.db().pending == 0
	and A.counter("detect.pendingAtLogin") == 1)

-- A crash loses the session: the counter moved while nothing was saved.
local headBefore = A.db().authors[Guid(1)].head
GainHK(A, 2)
advance(5)
check("two kills were recorded before the crash", A.db().authors[Guid(1)].head == headBefore + 2)
A.crash()
A.login()
advance(5)
check("the jump is deferred while the guild may hold the lost records", A.ns.Records.Holding() == true and Last(A).type ~= "X")
-- Nobody else is online: the recovery times out.
advance(130)
check("the next login starts from the last save", A.db().authors[Guid(1)].head == headBefore + 1, A.db().authors[Guid(1)].head)
record = Last(A)
check("the lost HKs are kept as a counter record", record.type == "X" and record.toHK - record.fromHK == 2 and record.bucket == "u"
	and A.counter("detect.jump") == 1, record and record.type)
check("the HK left pending by the last session was settled before the jump", Journal(A)[#Journal(A) - 1].how == "unk")
check("the chain still holds after the jump", Records.CheckChain(Journal(A)) == true)

-- HKs earned in a dungeon are counted without a place.
A.state.bucket = "instance"
GainHK(A)
advance(5)
check("an HK outside world and battleground is a counter record", Last(A).type == "X" and Last(A).bucket == "u")
A.state.bucket = "world"

--------------------------------------------------------------------------------
section("Sync: hellos, live records, catch-up by whisper")
--------------------------------------------------------------------------------

local network = Mock.network

local function RefreshRosters()
	advance(11)
	for _, client in ipairs(Mock.clients) do
		if client.online then client.fire("GUILD_ROSTER_UPDATE") end
	end
end

local function SentSince(mark, channel, kind)
	local n = 0
	for index = mark + 1, #network.sent do
		local sent = network.sent[index]
		if sent.channel == channel and sent.text:sub(1, 1) == kind then n = n + 1 end
	end
	return n
end

local function Held(client, author)
	local entry = client.db().authors[author.guid]
	return entry and entry.head or 0, entry and entry.count or 0
end

local Atail = A.ns.Identity.me.tail
local aHead = A.db().authors[A.guid].head
check("A has a journal to share", aHead >= 10, aHead)

local mark = #network.sent
B.login()
C.login()
advance(70)
check("hellos go out on GUILD within a minute of login", SentSince(mark, "GUILD", "H") >= 2)
check("B and C know each other", B.ns.Sync.State().peers["corwin ashdown"] ~= nil and C.ns.Sync.State().peers["brenna ironvale"] ~= nil)
check("A, logged in long before, does not hello again", A.counter("sync.hello.login") == A.counter("sync.helloReceived") - A.counter("sync.helloReceived") + A.counter("sync.hello.login"))
advance(200)
local bHead, bCount = Held(B, A)
check("B caught up with A's whole journal", bHead == aHead and bCount == aHead, bHead .. "/" .. bCount)
local cHead = Held(C, A)
check("so did C", cHead == aHead, cHead)
check("pages travelled by whisper, not on the guild channel", SentSince(mark, "WHISPER", "B") > 0 and SentSince(mark, "GUILD", "B") == 0)
check("the copies are the same text", B.db().authors[A.guid].log[3] == A.db().authors[A.guid].log[3])
check("A's profile reached B from A itself", B.db().authors[A.guid].profile and B.db().authors[A.guid].profile.name == "Aldric Stormhand"
	and B.db().authors[A.guid].profileVerified == true)
check("B's copy of A is confirmed up to A's head", B.db().authors[A.guid].confirmedHead == aHead)

-- A live kill reaches everyone within seconds.
mark = #network.sent
A.fire("PARTY_KILL", A.guid, HORDE[1].guid)
A.fire("UNIT_DIED", HORDE[1].guid)
GainHK(A)
advance(8)
check("a live record goes out once on GUILD", SentSince(mark, "GUILD", "R") == 1)
check("and reaches B and C with the same text", B.db().authors[A.guid].log[aHead + 1] == A.db().authors[A.guid].log[aHead + 1]
	and C.db().authors[A.guid].log[aHead + 1] ~= nil)
check("B counts it as confirmed", B.db().authors[A.guid].confirmedHead == aHead + 1 and B.counter("sync.recordReceived") >= 1)
aHead = aHead + 1

-- A record claiming A's journal from someone else is refused.
B.ns.Sync.SendRaw(("R^%s^%d^K1;%d;%d;w;unk;;;;;;;;;;999"):format(Atail, aHead + 1, aHead + 1, Mock.Server()), "GUILD")
advance(3)
check("a record from someone who is not the author is refused", C.counter("sync.recordNotAuthor") == 1 and Held(C, A) == aHead)

-- A hole before a live record is asked back from the author.
B.db().authors[A.guid].log[aHead] = nil
B.db().authors[A.guid].head, B.db().authors[A.guid].count = aHead - 1, aHead - 1
GainHK(A)
advance(60)
check("a gap before a live record is filled from the author", B.db().authors[A.guid].log[aHead] ~= nil and Held(B, A) == aHead + 1)
aHead = aHead + 1

-- Throttled sends are retried, and the record still arrives.
A.state.throttle = 2
GainHK(A)
advance(15)
check("throttled sends are retried", A.counter("sync.out.R.AddonMessageThrottle") >= 1 and Held(C, A) == aHead + 1)
aHead = aHead + 1

--------------------------------------------------------------------------------
section("Sync: an offline author, relays, forgeries")
--------------------------------------------------------------------------------

A.logout()
local D = NewClient({ name = "Dalia Brightwater", guid = Guid(4), class = "PRIEST", race = "NightElf", guild = "Savages", lifetime = 300, rank = 3 })
Mock.SetGuildRoster({ { guid = A.guid, rank = 0 }, { guid = B.guid, rank = 2 }, { guid = C.guid, rank = 4 }, { guid = Guid(5), rank = 3 }, { guid = D.guid, rank = 3 } })
RefreshRosters()
mark = #network.sent
D.login()
advance(400)
check("a newcomer gets an offline author's journal from a holder", Held(D, A) == aHead, Held(D, A))
check("relayed by B or C, and marked so", D.db().authors[A.guid].relayed and D.db().authors[A.guid].relayed > 0)
check("holders answered the newcomer's inventory with what they had more of", SentSince(mark, "GUILD", "A") >= 1)
check("only one holder served each page", SentSince(mark, "WHISPER", "B") <= 2 * math.ceil(aHead / 200) + 2)
check("B's and C's own journals reached D too", Held(D, B) == Held(B, B) and Held(D, C) == Held(C, C), Held(D, B) .. "/" .. Held(B, B))

-- A forged inventory: C claims a huge head for A; nobody has those pages.
local dCount = D.counter("sync.request")
C.ns.Sync.SendRaw(("I^%s=999/999"):format(Atail), "GUILD")
advance(120)
check("a forged inventory yields no records", Held(D, A) == aHead and B.counter("sync.pageEmpty") + C.counter("sync.pageEmpty") >= 1)
check("but it did cost a request", D.counter("sync.request") > dCount)

-- A forged page: C invents two records for A that chain correctly, and
-- advertises them. They spread, until A's own hello contradicts them.
local lastA = A.ns.Records.Decode(A.saved.authors[A.guid].log[aHead])
local forged1 = A.ns.Records.Encode({ type = "K", seq = aHead + 1, t = Mock.Server(), bucket = "w", how = "unk", lifeHK = lastA.lifeHK + 1 })
local forged2 = A.ns.Records.Encode({ type = "K", seq = aHead + 2, t = Mock.Server(), bucket = "w", how = "unk", lifeHK = lastA.lifeHK + 2 })
C.ns.Records.Store(A.guid, aHead + 1, forged1, "page")
C.ns.Records.Store(A.guid, aHead + 2, forged2, "page")
C.ns.Sync.SendRaw(("A^%s=%d/%d"):format(Atail, aHead + 2, aHead + 2), "GUILD")
advance(120)
check("a well-chained forged page is accepted for now", Held(D, A) == aHead + 2)
A.login()
advance(70)
check("the author's hello purges records its counter cannot cover", Held(D, A) == aHead and D.counter("sync.purged") == 2
	and Held(B, A) == aHead, Held(D, A))

--------------------------------------------------------------------------------
section("Sync: crash recovery, lockdown, timeouts")
--------------------------------------------------------------------------------

-- A makes two kills that everyone receives, then crashes: nothing saved.
advance(60)
A.fire("UNIT_DIED", HORDE[2].guid)
GainHK(A)
advance(5)
A.fire("UNIT_DIED", HORDE[3].guid)
GainHK(A)
advance(10)
check("two kills went out before the crash", Held(B, A) == aHead + 2)
local recoveries = A.counter("sync.recoveryStart")
local crashMark = #network.sent
A.crash()
A.login()
advance(1)
check("the lost session is detected and recovery starts", A.counter("sync.recoveryStart") == recoveries + 1 and A.ns.Records.Holding() == true)
-- A kill during the recovery (before the holders could answer) waits for
-- its number; the kill becomes a record 3 s later, once matched.
A.fire("UNIT_DIED", HORDE[4].guid)
GainHK(A)
advance(3.5)
local _, heldCount = A.ns.Records.Holding()
check("a kill during the recovery waits unnumbered", heldCount == 1, heldCount)
advance(131)
check("the lost records came back from a holder", Held(A, A) == aHead + 3 and A.counter("sync.recovered") == 1, Held(A, A))
check("the holders answered on the guild channel and served by whisper", SentSince(crashMark, "GUILD", "A") >= 1
	and SentSince(crashMark, "GUILD", "B") == 0 and SentSince(crashMark, "WHISPER", "B") >= 1)
check("no counter record was written", (function()
	for _, item in ipairs(Journal(A)) do
		if item.type == "X" and item.seq > aHead then return false end
	end
	return true
end)())
check("the kill made during the recovery got the next number", Last(A).type == "K" and Last(A).seq == aHead + 3 and Last(A).vname == "Sylas Mournhollow")
check("the chain holds through the recovery", Records.CheckChain(Journal(A)) == true)
check("and B holds the same journal", Held(B, A) == aHead + 3)
aHead = aHead + 3

-- Chat lockdown: in a battleground nothing is sent, and it goes out after.
EnterBG(B)
mark = #network.sent
B.ns.Sync.SendHello("recovery")
advance(40)
check("nothing is sent during the chat lockdown", SentSince(mark, "GUILD", "H") == 0 and B.counter("sync.wait.blocked") >= 1)
LeaveBG(B)
advance(40)
check("the queue drains after the battleground", SentSince(mark, "GUILD", "H") == 1)

-- A holder that never answers times out, and the next one is tried.
local E = NewClient({ name = "Elwyn Thornfield", guid = Guid(6), class = "WARRIOR", guild = "Savages", lifetime = 40, rank = 3 })
Mock.SetGuildRoster({ { guid = A.guid, rank = 0 }, { guid = B.guid, rank = 2 }, { guid = C.guid, rank = 4 }, { guid = Guid(5), rank = 3 },
	{ guid = D.guid, rank = 3 }, { guid = E.guid, rank = 3 } })
RefreshRosters()
A.logout()
EnterBG(B)
E.login()
advance(5)
local state = E.ns.Sync.State()
state.holders[Atail] = { ["brenna ironvale"] = { head = aHead, count = aHead, at = Mock.Server() } }
E.ns.Sync.Schedule()
advance(1)
local pending = 0
for _, request in pairs(state.requests) do
	if request.holder == "Brenna Ironvale" then pending = pending + 1 end
end
check("the request went to the silent holder", pending == 1)
advance(60)
check("it timed out", E.counter("sync.requestTimeout") == 1)
state.holders[Atail]["corwin ashdown"] = { head = aHead, count = aHead, at = Mock.Server() }
E.ns.Sync.Schedule()
advance(120)
check("and the next holder served the page", Held(E, A) == aHead, Held(E, A))
LeaveBG(B)
advance(5)

-- A holder that logged off since the roster was last read: the server
-- answers the whisper that nobody by that name is playing. The line stays
-- out of the chat, the holder is dropped at once, the next one serves.
A.login()
advance(30)
local Gc = NewClient({ name = "Garrick Stoneholm", guid = Guid(17), class = "PALADIN", guild = "Savages", lifetime = 12, rank = 3 })
Mock.SetGuildRoster({ { guid = A.guid, rank = 0 }, { guid = B.guid, rank = 2 }, { guid = C.guid, rank = 4 }, { guid = Guid(5), rank = 3 },
	{ guid = D.guid, rank = 3 }, { guid = E.guid, rank = 3 }, { guid = Gc.guid, rank = 3 } })
RefreshRosters()
Gc.login()
advance(5)
check("the newcomer's roster shows the author online", Gc.ns.Identity.Member("Aldric Stormhand") ~= nil
	and Gc.ns.Identity.Member("Aldric Stormhand").online == true)
A.logout()
local gState = Gc.ns.Sync.State()
gState.holders[Atail] = { ["aldric stormhand"] = { head = aHead, count = aHead, at = Mock.Server() } }
Gc.ns.Sync.Schedule()
advance(3)
check("the whisper to the departed member got the server's answer, hidden", Gc.counter("sync.notFoundHidden") == 1, Gc.counter("sync.notFoundHidden"))
check("the chat never showed it", not Gc.sawSystem("Aucun joueur nommé"))
check("the holder was dropped at once, not at the timeout", Gc.counter("sync.holderGone") == 1 and Gc.counter("sync.requestTimeout") == 0,
	Gc.counter("sync.holderGone"))
gState.holders[Atail]["corwin ashdown"] = { head = aHead, count = aHead, at = Mock.Server() }
Gc.ns.Sync.Schedule()
advance(120)
check("and the next holder served the page", Held(Gc, A) == aHead, Held(Gc, A))
check("no further whisper went to the departed member", Gc.counter("sync.notFoundHidden") == 1)

--------------------------------------------------------------------------------
section("Stats: characters, players, guild, hunting board, feed")
--------------------------------------------------------------------------------

A.login()
advance(70)
local Stats = A.ns.Stats

-- What a journal should add up to, computed here with the plain rules.
local function Expected(client, bucket)
	local sum = { kills = 0, kb = 0, deaths = 0 }
	local lifeKs, counters = {}, {}
	for _, r in ipairs(Journal(client)) do
		local wanted = bucket == "all" or r.bucket == bucket
		if r.type == "K" then
			lifeKs[#lifeKs + 1] = r.lifeHK
			-- Battleground kills are counted from the match's scoreboard.
			if wanted and r.bucket ~= "b" then
				sum.kills = sum.kills + 1
				if r.how == "kb" or r.how == "pet" then sum.kb = sum.kb + 1 end
			end
		elseif r.type == "D" and wanted and r.bucket ~= "b" then
			sum.deaths = sum.deaths + 1
		elseif r.type == "M" and wanted then
			sum.kills, sum.kb, sum.deaths = sum.kills + r.hk, sum.kb + r.kb, sum.deaths + r.deaths
		elseif r.type == "X" and wanted then
			counters[#counters + 1] = r
		end
	end
	for _, x in ipairs(counters) do
		local inside = 0
		for _, lifeHK in ipairs(lifeKs) do
			if lifeHK > x.fromHK and lifeHK <= x.toHK then inside = inside + 1 end
		end
		sum.kills = sum.kills + math.max(0, (x.toHK - x.fromHK) - inside)
	end
	return sum
end

local all = Stats.Character(A.guid, "all", "all")
local want = Expected(A, "all")
check("a character's totals match its journal", all.kills == want.kills and all.kb == want.kb and all.deaths == want.deaths,
	("%d/%d/%d vs %d/%d/%d"):format(all.kills, all.kb, all.deaths, want.kills, want.kb, want.deaths))
check("assists are the kills that were not killing blows", all.assists == all.kills - all.kb and all.assists > 0)
check("the K/D divides kills by deaths", math.abs(all.kd - all.kills / all.deaths) < 0.001)
local world, bg = Stats.Character(A.guid, "all", "w"), Stats.Character(A.guid, "all", "b")
check("the battleground bucket holds the matches' numbers", bg.kills == Expected(A, "b").kills and bg.kills == 5 and bg.kb == 3 and bg.deaths == 1, bg.kills)
check("counter records count in the total only", world.kills + bg.kills < all.kills and world.kills == Expected(A, "w").kills)
check("a guildmate without the addon is credited from the scoreboard", Stats.Character(Guid(5), "all", "b").kills == 25
	and Stats.Character(Guid(5), "all", "b").kb == 4)
local credited = false
for _, row in ipairs(Stats.Characters("all", "b")) do
	if row.guid == Guid(5) and row.name == "Edric Vale" and row.kills == 25 then credited = true end
end
check("and ranked with the others in the battleground view", credited)
-- The first board holds 7 killing blows of ours, but Edric took part in 25
-- deaths; the second battleground had 2 HKs and no blow.
check("battleground enemy deaths are the most honorable kills of one member on the board", Stats.Guild("all", "b").distinct == 27, Stats.Guild("all", "b").distinct)
check("live battleground kills never count as enemy deaths of their own", Stats.Guild("all", "all").distinct == Stats.Guild("all", "w").distinct + 27,
	Stats.Guild("all", "all").distinct .. "/" .. Stats.Guild("all", "w").distinct)
check("everything happened this week", Stats.Character(A.guid, "week", "all").kills == all.kills and Stats.Character(A.guid, "last", "all").kills == 0)
check("the week anchor came from the client", A.db().weekAnchor == Mock.Server() + 30 * 3600 or math.abs(A.db().weekAnchor - (Mock.Server() + 30 * 3600)) < 200)

local players = Stats.Players("all", "all")
check("players are ranked, A first", players[1] and players[1].name == "Aldric Stormhand" and players[1].me == true and players[1].rank == 1,
	players[1] and players[1].name)
check("a player's numbers are its characters' numbers", players[1].kills == all.kills and #players[1].characters == 1)
check("members without kills or deaths this period stay out of the ranking", #players == 2, #players)
A.ns.Identity.SetAlias("  Aldric^the;Bold  ")
advance(10)
check("an alias is cleaned and shown as the player's name", Stats.Players("all", "all")[1].name == "Aldric the Bold")
check("the new profile reached the others", B.db().authors[A.guid].profile.alias == "Aldric the Bold")

-- B kills the same enemy A assists on: two kills for the members, one
-- enemy death for the guild.
local guildBefore = Stats.Guild("all", "all")
B.fire("PARTY_KILL", B.guid, HORDE[5].guid)
B.fire("UNIT_DIED", HORDE[5].guid)
A.fire("UNIT_DIED", HORDE[5].guid)
GainHK(B)
advance(1)
GainHK(A)
advance(10)
local guildAfter = Stats.Guild("all", "all")
check("the guild total counts both members' kills", guildAfter.kills == guildBefore.kills + 2, guildAfter.kills - guildBefore.kills)
check("but the enemy died once", guildAfter.distinct == guildBefore.distinct + 1, guildAfter.distinct - guildBefore.distinct)
check("the guild total includes every journal held", guildAfter.authors >= 3, guildAfter.authors)
check("B's live kill is in A's view of B", Stats.Character(B.guid, "all", "all").kills == 1)

-- A character that leaves the guild drops out of the rankings, not of the total.
Mock.SetGuildRoster({ { guid = A.guid, rank = 0 }, { guid = C.guid, rank = 4 }, { guid = Guid(5), rank = 3 }, { guid = D.guid, rank = 3 }, { guid = E.guid, rank = 3 } })
RefreshRosters()
local found = false
for _, row in ipairs(Stats.Characters("all", "all")) do
	if row.guid == B.guid then found = true end
end
check("a departed character is out of the rankings", not found)
check("its kills stay in the guild total", Stats.Guild("all", "all").kills == guildAfter.kills)

local victims = Stats.Victims("all", "all", nil, 5)
check("the hunting board names the most killed enemy", victims[1] and victims[1].name == "Sylas Mournhollow" and victims[1].count >= 2, victims[1] and victims[1].name)
check("with how many members killed it", victims[1].byCount >= 1 and victims[1].class == "MAGE")
local mine = Stats.Victims("all", "all", { guid = A.guid })
check("a character's own board is a subset", #mine <= #Stats.Victims("all", "all"))
-- Gruk killed Aldric twice in the deaths section, then twice more around
-- the doubled PLAYER_DEAD.
local killers = Stats.Killers("all", "all", nil, 5)
check("our killers are listed from the deaths, battlegrounds included", #killers == 3 and killers[1].count == 4
	and killers[1].name == "Gruk Bonecrusher", #killers .. "/" .. tostring(killers[1] and killers[1].count))
local feed = Stats.Feed(10, "all")
check("the feed is newest first with the author's name", feed[1] and feed[1].t >= feed[2].t and feed[1].info and feed[1].info.name ~= nil)
local milestone = Stats.Milestone()
check("the next milestone is the first one not reached", milestone.next == 100 and milestone.previous == 0 and milestone.progress == milestone.distinct / 100)

-- B saw the same battleground as A: its record credits Edric once more,
-- which counts once; B's own row counts for B.
local matchTime
for _, r in ipairs(Journal(A)) do
	if r.type == "M" and #r.lines == 1 then matchTime = r.t end
end
Mock.SetGuildRoster({ { guid = A.guid, rank = 0 }, { guid = B.guid, rank = 2 }, { guid = C.guid, rank = 4 }, { guid = Guid(5), rank = 3 },
	{ guid = D.guid, rank = 3 }, { guid = E.guid, rank = 3 } })
RefreshRosters()
B.state.lifetime = B.state.lifetime + 5
B.ns.Records.AppendOwn({ type = "M", t = matchTime, instanceID = 30, hk = 5, kb = 1, deaths = 2, honor = 90,
	lifeHK = B.state.lifetime, live = 0,
	lines = { { tail = "1234-00000005", name = "Edric Vale", kb = 4, hk = 25, deaths = 1, honor = 300 } } })
advance(8)
check("a second member's record of the same match counts the teammate once", Stats.Character(Guid(5), "all", "b").kills == 25
	and Stats.Character(B.guid, "all", "b").kills == 5 and Stats.Character(B.guid, "all", "b").kb == 1,
	Stats.Character(Guid(5), "all", "b").kills .. "/" .. Stats.Character(B.guid, "all", "b").kills)
check("the guild's battleground deaths count once per match too", Stats.Guild("all", "b").distinct == 27, Stats.Guild("all", "b").distinct)

--------------------------------------------------------------------------------
section("Compaction: old pages packed, still served and counted")
--------------------------------------------------------------------------------

local synthGuid, synthTail = "Player-1234-00000AAA", "1234-00000AAA"
local old = Mock.Server() - 3 * 7 * 24 * 3600
for seq = 1, 450 do
	local line = A.ns.Records.Encode({ type = "K", seq = seq, t = old + seq, bucket = "w", how = "unk", lifeHK = 1000 + seq })
	A.ns.Records.Store(synthGuid, seq, line, "page")
end
Stats.Invalidate()
local sizeBefore = #Serialize(A.db())
local countBefore = Stats.Character(synthGuid, "all", "all").kills
check("a 450-record journal counts 450 kills", countBefore == 450, countBefore)
local packed = A.ns.Records.Compact(Mock.Server() - 7 * 24 * 3600)
Stats.Invalidate()
local synth = A.db().authors[synthGuid]
check("two full old pages were packed, the partial one kept", packed == 2 and synth.pages[1] and synth.pages[2] and not synth.pages[3]
	and synth.log[401] ~= nil and synth.log[400] == nil)
check("the saved data shrank", #Serialize(A.db()) < sizeBefore - 10000, sizeBefore - #Serialize(A.db()))
check("a packed record still reads", A.ns.Records.Get(synthGuid, 150) and A.ns.Records.Get(synthGuid, 150).lifeHK == 1150)
check("and still counts", Stats.Character(synthGuid, "all", "all").kills == 450)
check("a store into a packed page is refused", select(2, A.ns.Records.Store(synthGuid, 10, "K1;10;1;w;unk;;;;;;;;;;1", "page")) == "packed")
check("recent pages are never packed", A.db().authors[A.guid].pages == nil or next(A.db().authors[A.guid].pages) == nil)

-- A packed page is served to a member who asks for it.
local eState = E.ns.Sync.State()
eState.holders[synthTail] = { ["aldric stormhand"] = { head = 450, count = 450, at = Mock.Server() } }
E.ns.Sync.Schedule()
advance(200)
check("packed pages are served and stored elsewhere", (E.db().authors[synthGuid] and E.db().authors[synthGuid].count or 0) == 450,
	E.db().authors[synthGuid] and E.db().authors[synthGuid].count)
check("the copy reads the same", E.ns.Records.Get(synthGuid, 150) and E.ns.Records.Get(synthGuid, 150).lifeHK == 1150)

--------------------------------------------------------------------------------
section("Import from the probe")
--------------------------------------------------------------------------------

-- A member who ran the probe before installing the addon: its file holds
-- another character's evening too, and must be read by session.
local F = NewClient({ name = "Fenwick Oakhollow", guid = Guid(7), class = "WARRIOR", guild = "Savages", lifetime = 42, rank = 3 })
local G = NewClient({ name = "Gaelan Rook", guid = Guid(8), class = "ROGUE", guild = "Savages", lifetime = 10, rank = 3 })
local H = NewClient({ name = "Hollis Marrow", guid = Guid(9), class = "MAGE", guild = "Savages", lifetime = 35, rank = 3 })
local I = NewClient({ name = "Isolde Thorne", guid = Guid(10), class = "HUNTER", guild = "Savages", lifetime = 26, rank = 3 })
Mock.SetGuildRoster({ { guid = A.guid, rank = 0 }, { guid = B.guid, rank = 2 }, { guid = C.guid, rank = 4 }, { guid = Guid(5), rank = 3 },
	{ guid = D.guid, rank = 3 }, { guid = E.guid, rank = 3 }, { guid = F.guid, rank = 3 }, { guid = G.guid, rank = 3 }, { guid = H.guid, rank = 3 },
	{ guid = I.guid, rank = 3 } })
RefreshRosters()

local T = Mock.Server() - 3600
local function Pos(x, y) return { mapID = 1424, mapName = "Contreforts de Hautebrande", status = "ok", x = x, y = y } end
local function Facts(h, level)
	return { kind = "Player", guid = h.guid, name = h.name, class = h.class, race = h.race, factionGuess = "Horde", faction = "Horde", level = level, realm = "" }
end
local function Hk(at, t, reason, bucket, lifetime, delta, matched, extra)
	local entry = { at = at, t = t, reason = reason, bucket = bucket, lifetime = { lifetime, 0, n = 2 }, session = { 0, 0, n = 2 }, secret = false }
	if delta then entry.lifetimeDelta = delta end
	if matched then entry.match = matched end
	for key, value in pairs(extra or {}) do entry[key] = value end
	return entry
end
local OTHER, MINE = "Someone Else-" .. Mock.REALM, "Fenwick Oakhollow-" .. Mock.REALM
local probe = {
	schema = 1,
	me = { guid = F.guid, key = MINE, name = "Fenwick Oakhollow" },
	guild = { name = "Savages", members = 9 },
	sessions = {
		{ at = T - 7200, key = OTHER, version = "0.1.2" },
		{ at = T, key = MINE, version = "0.1.3" },
		{ at = T + 1000, key = MINE, version = "0.1.3" },
	},
	log = {
		hk = {
			-- the other character's evening
			Hk(T - 7100, 100, "login", "world", 5),
			Hk(T - 7000, 200, "PLAYER_PVP_KILLS_CHANGED", "world", 6, 1, "kb:me", { pos = Pos(0.1, 0.1) }),
			-- Fenwick, first session
			Hk(T + 1, 1000, "login", "world", 30),
			Hk(T + 100, 1100, "PLAYER_PVP_KILLS_CHANGED", "world", 31, 1, "kb:me", { pos = Pos(0.31, 0.42), zone = "Contreforts de Hautebrande", subzone = "Moulin-de-Tarren" }),
			Hk(T + 100, 1100.05, "PLAYER_PVP_KILLS_CHANGED", "world", 31, 0),
			Hk(T + 200, 1200, "PLAYER_PVP_KILLS_CHANGED", "world", 32, 1, "assist:named", { pos = Pos(0.33, 0.44) }),
			Hk(T + 300, 1300, "PLAYER_PVP_KILLS_CHANGED", "world", 34, 2, "kb:party assist:unseen", { pos = Pos(0.35, 0.46) }),
			-- second session: one HK came in between, unseen
			Hk(T + 1000, 2000, "login", "world", 35),
			Hk(T + 1100, 2100, "enter-bg", "bg", 35, 0),
			Hk(T + 1200, 2200, "PLAYER_PVP_KILLS_CHANGED", "bg", 36, 1, "kb:secret", { zone = "Vallée d'Alterac", subzone = "Pic de Dun Baldar" }),
			Hk(T + 1300, 2300, "PLAYER_PVP_KILLS_CHANGED", "bg", 37, 1, "assist:unseen", { zone = "Vallée d'Alterac", subzone = "" }),
			Hk(T + 1400, 2400, "PLAYER_PVP_KILLS_CHANGED", "bg", 38, 1, "assist:unseen", { zone = "Vallée d'Alterac", subzone = "Cimetière des Stormpike" }),
			Hk(T + 1600, 2600, "match-complete", "bg", 38, 0),
			-- a second battleground, left before the end: no scoreboard
			Hk(T + 2000, 3000, "enter-bg", "bg", 38, 0),
			Hk(T + 2100, 3100, "PLAYER_PVP_KILLS_CHANGED", "bg", 39, 1, "assist:unseen", { zone = "Goulet des Chanteguerres", subzone = "Fort" }),
			Hk(T + 2200, 3200, "PLAYER_PVP_KILLS_CHANGED", "bg", 40, 1, "kb:secret", { zone = "Goulet des Chanteguerres", subzone = "Fort" }),
			Hk(T + 2300, 3300, "left-bg", "world", 40, 0),
		},
		kills = {
			{ at = T - 7000, t = 200, bucket = "world", role = "me", targetKind = "Player", hkMatched = true, hk = "hk", target = Facts(HORDE[5], 30), pos = Pos(0.1, 0.1) },
			-- a teammate's blow that gave Fenwick no HK: not his kill
			{ at = T + 50, t = 1050, bucket = "world", role = "party", targetKind = "Player", hk = "nohk", target = Facts(HORDE[6], 28), pos = Pos(0.30, 0.41) },
			{ at = T + 100, t = 1100, bucket = "world", role = "me", targetKind = "Player", hkMatched = true, hk = "hk", target = Facts(HORDE[1], 27), pos = Pos(0.31, 0.42) },
			{ at = T + 300, t = 1300, bucket = "world", role = "party", targetKind = "Player", hkMatched = true, hk = "hk", target = Facts(HORDE[3], 25), pos = Pos(0.35, 0.46) },
			{ at = T + 1200, t = 2200, bucket = "bg", role = "secret", targetKind = "secret", attackerSecret = true, targetSecret = true },
		},
		assists = {
			{ at = T + 200, t = 1200, bucket = "world", how = "named", victim = Facts(HORDE[2], 26), gap = 0.8, pos = Pos(0.33, 0.44) },
			{ at = T + 300, t = 1300, bucket = "world", how = "unseen", pos = Pos(0.35, 0.46) },
			{ at = T + 1300, t = 2300, bucket = "bg", how = "unseen" },
			{ at = T + 1400, t = 2400, bucket = "bg", how = "unseen" },
			{ at = T + 2100, t = 3100, bucket = "bg", how = "unseen" },
		},
		deaths = {
			-- by a creature: not a PvP death
			{ at = T + 150, t = 1150, bucket = "world", recapStatus = "ok", killer = { kind = "Creature" }, killerIsPlayer = false, pos = Pos(0.32, 0.43),
				recap = { { sourceName = "Loup des collines", sourceGUID = "Creature-0-1-2-3-4-5", sourceFlags = 0xa48, spellName = "Morsure" } } },
			{ at = T + 250, t = 1250, bucket = "world", recapStatus = "ok", killer = Facts(HORDE[4], 29), killerIsPlayer = true, pos = Pos(0.34, 0.45),
				recap = { { sourceName = HORDE[4].name, sourceGUID = HORDE[4].guid, sourceFlags = 0x548, spellName = "Boule de feu" } } },
			{ at = T + 350, t = 1350, bucket = "world", recapStatus = "ok", killer = { kind = "Pet" }, killerIsPlayer = false, pos = Pos(0.36, 0.47),
				recap = { { sourceName = "Crocs", sourceGUID = "Pet-0-1234-1-0000CCC3", sourceFlags = 0x1148, spellName = "Griffure" } } },
			{ at = T + 1350, t = 2350, bucket = "bg", recapStatus = "ok", killer = Facts(HORDE[6]), killerIsPlayer = true, pos = { mapID = 1459, status = "secret" },
				context = { bucket = "bg", instanceID = 30, subzone = "Pic de Dun Baldar" },
				recap = { { sourceName = HORDE[6].name, sourceGUID = HORDE[6].guid, sourceFlags = 0x548, spellName = "Tir des arcanes" } } },
			-- with no readable recap: dropped
			{ at = T + 1450, t = 2450, bucket = "bg", recapStatus = "secret", context = { bucket = "bg" } },
		},
		matches = {
			{ how = "active", startedAt = T + 1100, context = { bucket = "bg", instanceID = 30, instanceName = "Vallée d'Alterac" }, during = {} },
			{ how = "complete", startedAt = T + 1600, completeAt = T + 1600, duration = 480, winner = 1, battlefieldWinner = 1, inactiveAt = T + 1620,
				atEnd = { bucket = "bg", instanceID = 30, instanceName = "Vallée d'Alterac", subzone = "Pic de Dun Baldar" },
				mine = { honorableKills = 3, killingBlows = 1, deaths = 1, honorGained = 50, damageDone = 1000, healingDone = 0, name = "Fenwick Oakhollow", guid = F.guid },
				final = { at = T + 1600, count = 4, readable = 4, secret = 0, rows = {
					{ name = "Fenwick Oakhollow", guid = F.guid, kb = 1, hk = 3, deaths = 1, honor = 50, faction = 1, class = "WARRIOR", race = "Humain", me = true, guildmate = true },
					{ name = "Edric Vale", guid = Guid(5), kb = 2, hk = 10, deaths = 0, honor = 90, faction = 1, class = "PALADIN", race = "Humain", guildmate = true },
					{ name = "Random Ally", guid = Guid(900), kb = 4, hk = 12, deaths = 2, honor = 80, faction = 1, class = "MAGE", race = "Gnome" },
					{ name = HORDE[1].name, guid = HORDE[1].guid, kb = 5, hk = 9, deaths = 3, honor = 70, faction = 0, class = "WARRIOR", race = "Orc" },
				} },
				immediate = { count = 4, readable = 0, secret = 4, rows = {} },
			},
			{ how = "active", startedAt = T + 2000, context = { bucket = "bg", instanceID = 489, instanceName = "Goulet des Chanteguerres" }, during = {} },
		},
	},
}

F.probe = probe
mark = #network.sent
F.login()
advance(5)
local fStatus = F.ns.Sync.Status()
check("a newcomer is told the sync is coming", fStatus.phase == "waiting" and fStatus.helloIn > 2 and fStatus.helloIn <= 15
	and F.ns.UI.SyncText(fStatus):find("dans %d+ s") ~= nil, fStatus.phase)
local imported = Journal(F)
local fChar = F.db().characters[F.guid]
check("the probe's records of this character came in at login", #imported == 16 and F.said("repris de la sonde"), #imported)
check("the baseline is the count the probe first knew, the lifetime count the server's", fChar.baselineHK == 30 and fChar.lifeHK == 42)
check("the chain holds from the first record to the counter", F.ns.Records.CheckChain(Journal(F)) == true and Last(F).type == "X" and Last(F).toHK == 42)
check("the other character's kill stayed out", (function()
	for _, r in ipairs(imported) do
		if r.vtail == F.ns.Util.Tail(HORDE[5].guid) then return false end
	end
	return true
end)())
check("a killing blow keeps its victim and place", imported[1].type == "K" and imported[1].how == "kb" and imported[1].vname == HORDE[1].name
	and imported[1].vclass == HORDE[1].class and imported[1].vlevel == 27 and imported[1].mapID == 1424 and imported[1].x == 0.31 and imported[1].lifeHK == 31,
	imported[1].how)
check("an assist named by the enemy's death keeps it", imported[2].how == "ast" and imported[2].vname == HORDE[2].name and imported[2].lifeHK == 32)
check("a death keeps its killer and spell", imported[3].type == "D" and imported[3].kkind == "p" and imported[3].kname == HORDE[4].name
	and imported[3].spell == "Boule de feu" and imported[3].lifeHK == 32)
check("a teammate's blow is a group kill, the unseen HK a kill with no victim", imported[4].how == "grp" and imported[4].vname == HORDE[3].name
	and imported[5].how == "unk" and imported[5].vtail == nil and imported[5].lifeHK == 34)
check("a death to a pet keeps the pet's name", imported[6].type == "D" and imported[6].kkind == "e" and imported[6].kname == "Crocs")
check("HKs between two sessions are a counter record", imported[7].type == "X" and imported[7].fromHK == 34 and imported[7].toHK == 35)
check("battleground HKs are kills placed by subzone", imported[8].how == "bg" and imported[8].sub == "Pic de Dun Baldar" and imported[9].sub == nil
	and imported[11].sub == "Cimetière des Stormpike" and imported[11].lifeHK == 38)
check("a death in a battleground keeps its subzone", imported[10].type == "D" and imported[10].bucket == "b" and imported[10].kname == HORDE[6].name
	and imported[10].sub == "Pic de Dun Baldar" and imported[10].mapID == nil)
local fMatch = imported[12]
check("the final scoreboard is a match record with the guild teammate's line", fMatch.type == "M" and fMatch.hk == 3 and fMatch.kb == 1 and fMatch.deaths == 1
	and fMatch.honor == 50 and fMatch.damage == 1000 and fMatch.live == 3 and fMatch.lifeHK == 38 and fMatch.instanceID == 30 and fMatch.duration == 480
	and #fMatch.lines == 1 and fMatch.lines[1].name == "Edric Vale" and fMatch.lines[1].kb == 2 and fMatch.lines[1].hk == 10, #fMatch.lines)
check("a battleground left before the end is a match from the counter", imported[15].type == "M" and imported[15].hk == 2 and imported[15].kb == 0
	and imported[15].live == 2 and imported[15].instanceID == 489 and imported[15].lifeHK == 40)
local fStats = F.ns.Stats.Character(F.guid, "all", "all")
local fWanted = Expected(F, "all")
check("the stats add the imported records up", fStats.kills == 12 and fStats.kb == 2 and fStats.deaths == 3
	and fStats.kills == fWanted.kills and fStats.kb == fWanted.kb and fStats.deaths == fWanted.deaths, fStats.kills)
check("they fall in this week", F.ns.Stats.Character(F.guid, "week", "all").kills == 12)
check("imported records are not broadcast one by one", SentSince(mark, "GUILD", "R") == 0, SentSince(mark, "GUILD", "R"))
advance(70)
check("the hello after the import announces the head", SentSince(mark, "GUILD", "H") >= 1 and network.sent[#network.sent] ~= nil)
advance(120)
check("a member takes the imported journal by whisper", Held(A, F) == 16, Held(A, F))
-- The newcomer's inventory lists only its own journal: the others answer
-- with what it lacks, so it does not stay alone on its board.
check("and the newcomer takes the journals the others hold", Held(F, A) == Held(A, A) and Held(A, A) > 0 and Held(F, B) == Held(B, B),
	("A %d/%d B %d/%d, requests %d, timeouts %d, busy answers %d"):format(Held(F, A), Held(A, A), Held(F, B), Held(B, B),
		F.counter("sync.request"), F.counter("sync.requestTimeout"), F.counter("sync.pageBusy")))
check("a holder with enough going out says so instead of staying silent", F.counter("sync.pageBusy") >= 1 and F.counter("sync.requestTimeout") == 0,
	F.counter("sync.pageBusy") .. "/" .. F.counter("sync.requestTimeout"))
fStatus = F.ns.Sync.Status()
check("then that it is up to date, the first journals announced once in chat", fStatus.phase == "idle" and fStatus.held >= 2 and fStatus.pagesIn >= 2
	and F.said("Premiers journaux de guilde") and F.ns.UI.SyncText(fStatus):find("À jour") ~= nil, fStatus.phase .. "/" .. fStatus.held)
F.logout()
F.login()
advance(5)
check("a second login imports nothing twice", #Journal(F) == 16 and F.counter("import.records") == 16, F.counter("import.records"))
F.slash("import")
check("/kbs import says it is done", F.said("Déjà repris"))

-- The probe's file holds nothing of this character: nothing comes in.
G.probe = { schema = 1, me = { guid = Guid(99) }, sessions = { { at = T, key = OTHER, version = "0.1.3" } }, log = probe.log }
G.login()
advance(5)
check("another character's evening is not imported", #Journal(G) == 0 and G.db().characters[G.guid].imported == nil)
G.slash("import")
check("/kbs import says why", G.said("rien pour ce personnage") and G.counter("import.noData") == 1)

-- The probe's count runs past this character's counter: refused whole.
local wrong = Mock.Roundtrip(probe)
wrong.me.guid = H.guid
for _, session in ipairs(wrong.sessions) do
	if session.key == MINE then session.key = "Hollis Marrow-" .. Mock.REALM end
end
H.probe = wrong
H.login()
advance(5)
check("data past the counter is refused, nothing written", #Journal(H) == 0 and H.counter("import.mismatch") == 1
	and H.db().characters[H.guid].baselineHK == 35)
H.slash("import")
check("/kbs import says the counts do not fit", H.said("ne colle pas"))

-- A journal with records and a probe file of someone else: nothing to take.
A.probe = probe
A.logout()
A.login()
advance(5)
local aHeadBefore = Held(A, A)
A.slash("import")
check("a journal that already has records takes nothing from another character's probe", Held(A, A) == aHeadBefore
	and A.said("rien pour ce personnage") and A.db().characters[A.guid].imported == nil)
A.probe = nil

-- A member whose probe folder was gone when the addon first ran: its
-- journal has records by the time the probe's file is read again. What the
-- probe kept from before the addon's first count comes in as backfill,
-- appended after the head, outside the chain.
local J = NewClient({ name = "Jorund Blackbriar", guid = Guid(11), class = "PALADIN", guild = "Savages", lifetime = 40, rank = 3 })
local K = NewClient({ name = "Kestrel Vane", guid = Guid(12), class = "MAGE", guild = "Savages", lifetime = 35, rank = 3 })
Mock.SetGuildRoster({ { guid = A.guid, rank = 0 }, { guid = B.guid, rank = 2 }, { guid = C.guid, rank = 4 }, { guid = Guid(5), rank = 3 },
	{ guid = D.guid, rank = 3 }, { guid = E.guid, rank = 3 }, { guid = F.guid, rank = 3 }, { guid = G.guid, rank = 3 }, { guid = H.guid, rank = 3 },
	{ guid = I.guid, rank = 3 }, { guid = J.guid, rank = 3 }, { guid = K.guid, rank = 3 } })
RefreshRosters()
advance(1800)
J.login()
advance(20)
J.state.target = HORDE[2].guid
J.fire("PARTY_KILL", J.guid, HORDE[2].guid)
J.fire("UNIT_DIED", HORDE[2].guid)
GainHK(J)
advance(5)
check("the addon started on this character from the server's count", #Journal(J) == 1 and J.db().characters[J.guid].baselineHK == 40
	and Last(J).lifeHK == 41, #Journal(J))
J.logout()
local function ProbeOf(client, key)
	local copy = Mock.Roundtrip(probe)
	copy.me.guid = client.guid
	for _, session in ipairs(copy.sessions) do
		if session.key == MINE then session.key = key end
	end
	return copy
end
J.probe = ProbeOf(J, "Jorund Blackbriar-" .. Mock.REALM)
mark = #network.sent
J.login()
advance(5)
local jRecords = Journal(J)
check("the probe's data from before the addon came in as backfill", #jRecords == 15 and J.said("d'avant l'addon repris")
	and J.counter("import.backfill") == 14, #jRecords)
check("kills are backfill records at their own time, outside the chain", jRecords[2].type == "K" and jRecords[2].backfill == true
	and jRecords[2].how == "kb" and jRecords[2].vname == HORDE[1].name and jRecords[2].t < jRecords[1].t and jRecords[2].lifeHK == 41
	and jRecords[15].lifeHK == 41 and J.ns.Records.Encode(jRecords[2]):sub(1, 2) == "B1", jRecords[2].lifeHK)
check("counter records stay out, a match keeps its board as a backfill match", (function()
	local matches = 0
	for _, r in ipairs(jRecords) do
		if r.type == "X" then return false end
		if r.type == "M" then
			matches = matches + 1
			if r.backfill ~= true or J.ns.Records.Encode(r):sub(1, 2) ~= "C1" or r.lifeHK ~= 41 then return false end
		end
	end
	return matches == 2
end)())
check("the chain still holds through the backfill", J.ns.Records.CheckChain(Journal(J)) == true)
local jStats = J.ns.Stats.Character(J.guid, "all", "all")
check("the stats count the backfill like kills", jStats.kills == 10 and jStats.kb == 3 and jStats.deaths == 3,
	("%d/%d/%d"):format(jStats.kills, jStats.kb, jStats.deaths))
check("the count before the addon shrinks by the kills the probe placed", J.ns.Stats.AuthorInfo(J.guid).before == 31,
	J.ns.Stats.AuthorInfo(J.guid).before)
check("the baseline and the counter are untouched", J.db().characters[J.guid].baselineHK == 40 and J.db().characters[J.guid].lifeHK == 41)
check("backfill is not broadcast one by one", SentSince(mark, "GUILD", "R") == 0)
advance(200)
check("a member takes the backfilled journal and reads it the same", Held(A, J) == 15 and A.ns.Stats.Character(J.guid, "all", "all").kills == 10
	and A.ns.Stats.AuthorInfo(J.guid).before == 31, ("%d held, before %s"):format(Held(A, J), tostring(A.ns.Stats.AuthorInfo(J.guid).before)))
J.logout()
J.login()
advance(5)
check("a second login backfills nothing twice", #Journal(J) == 15 and J.counter("import.backfill") == 14)
J.slash("import")
check("/kbs import says the backfill is done", J.said("Déjà repris"))

-- The probe numbered kills past the count the addon started from: they
-- cannot be from before it, so nothing is appended.
K.login()
advance(20)
K.state.target = HORDE[3].guid
K.fire("PARTY_KILL", K.guid, HORDE[3].guid)
K.fire("UNIT_DIED", HORDE[3].guid)
GainHK(K)
advance(5)
K.logout()
K.probe = ProbeOf(K, "Kestrel Vane-" .. Mock.REALM)
K.login()
advance(5)
check("backfill past the addon's first count is refused whole", #Journal(K) == 1 and K.counter("import.mismatch") == 1
	and K.db().characters[K.guid].imported == nil, #Journal(K))
K.slash("import")
check("/kbs import says the counts do not fit", K.said("ne colle pas"))

-- A scoreboard outside any instance (instanceID 0): a guild raid in the
-- world, written by hand for members who had neither the probe nor the
-- addon. Its lines credit world kills, by tail; the guild's distinct deaths
-- do not move, the witnesses' journals already count them.
Mock.AddPlayer(Guid(13), { name = "Maren Holt", class = "PRIEST", race = "Dwarf", faction = "Alliance" })
Mock.AddPlayer(Guid(14), { name = "Tobin Ashgrove", class = "WARLOCK", race = "Human", faction = "Alliance" })
Mock.SetGuildRoster({ { guid = A.guid, rank = 0 }, { guid = B.guid, rank = 2 }, { guid = C.guid, rank = 4 }, { guid = Guid(5), rank = 3 },
	{ guid = D.guid, rank = 3 }, { guid = E.guid, rank = 3 }, { guid = F.guid, rank = 3 }, { guid = G.guid, rank = 3 }, { guid = H.guid, rank = 3 },
	{ guid = I.guid, rank = 3 }, { guid = J.guid, rank = 3 }, { guid = K.guid, rank = 3 }, { guid = Guid(13), rank = 5 }, { guid = Guid(14), rank = 5 } })
RefreshRosters()
if not B.online then
	B.login()
	advance(20)
end
local distinctBefore = { w = A.ns.Stats.Guild("week", "w").distinct, b = A.ns.Stats.Guild("week", "b").distinct }
A.ns.Records.AppendOwn({
	type = "M", t = Mock.Server() - 600, instanceID = 0, duration = 9000, hk = 0, kb = 0, deaths = 0, honor = 0, live = 0, mapID = 1442,
	lifeHK = A.ns.Records.LifeAfter(Last(A)),
	lines = {
		{ tail = A.ns.Util.Tail(Guid(13)), name = "Maren Holt", kb = 0, hk = 7, deaths = 0, honor = 0 },
		{ tail = A.ns.Util.Tail(Guid(14)), name = "Tobin Ashgrove", kb = 0, hk = 7, deaths = 0, honor = 0 },
	},
})
advance(5)
check("a world scoreboard credits its lines in the world", A.ns.Stats.Character(Guid(13), "week", "w").kills == 7
	and A.ns.Stats.Character(Guid(13), "week", "b").kills == 0 and A.ns.Stats.Character(Guid(14), "week", "all").kills == 7
	and A.ns.Stats.Character(Guid(14), "week", "all").kb == 0, A.ns.Stats.Character(Guid(13), "week", "w").kills)
check("the credited members are listed under the world filter", (function()
	for _, row in ipairs(A.ns.Stats.Characters("week", "w")) do
		if row.guid == Guid(13) and row.kills == 7 and row.name == "Maren Holt" then return true end
	end
	return false
end)())
check("the chain holds and the guild's distinct deaths do not move", A.ns.Records.CheckChain(Journal(A)) == true
	and A.ns.Stats.Guild("week", "w").distinct == distinctBefore.w and A.ns.Stats.Guild("week", "b").distinct == distinctBefore.b,
	A.ns.Stats.Guild("week", "w").distinct .. "/" .. distinctBefore.w)
advance(10)
check("a member reads the raid credit the same", B.ns.Stats.Character(Guid(13), "week", "w").kills == 7
	and B.ns.Stats.Character(Guid(14), "week", "b").kills == 0, B.ns.Stats.Character(Guid(13), "week", "w").kills)

-- A journal written by a version that gave a death during a pending kill
-- the kill's count: its page failed every member's chain check. At login
-- the author repairs it; records that add HKs are never touched.
local Lc = NewClient({ name = "Lysander Crane", guid = Guid(15), class = "DRUID", guild = "Savages", lifetime = 12, rank = 3 })
local Mc = NewClient({ name = "Marcus Thorne", guid = Guid(16), class = "WARRIOR", guild = "Savages", lifetime = 8, rank = 3 })
Mock.SetGuildRoster({ { guid = A.guid, rank = 0 }, { guid = B.guid, rank = 2 }, { guid = C.guid, rank = 4 }, { guid = Guid(5), rank = 3 },
	{ guid = D.guid, rank = 3 }, { guid = E.guid, rank = 3 }, { guid = F.guid, rank = 3 }, { guid = G.guid, rank = 3 }, { guid = H.guid, rank = 3 },
	{ guid = I.guid, rank = 3 }, { guid = J.guid, rank = 3 }, { guid = K.guid, rank = 3 }, { guid = Guid(13), rank = 5 }, { guid = Guid(14), rank = 5 },
	{ guid = Lc.guid, rank = 3 }, { guid = Mc.guid, rank = 3 } })
RefreshRosters()
Lc.login()
advance(20)
Lc.state.target = HORDE[4].guid
Lc.fire("PARTY_KILL", Lc.guid, HORDE[4].guid)
Lc.fire("UNIT_DIED", HORDE[4].guid)
GainHK(Lc)
advance(5)
Lc.logout()
local lJournal = Lc.saved.authors[Lc.guid]
local brokenDeath = Lc.ns.Records.Encode({
	type = "D", seq = 2, t = Mock.Server() - 30, bucket = "w", kkind = "p", ktail = Lc.ns.Util.Tail(HORDE[1].guid), kname = HORDE[1].name,
	kclass = HORDE[1].class, krace = HORDE[1].race, lifeHK = 14,
})
lJournal.log[2] = brokenDeath
lJournal.head, lJournal.count, lJournal.confirmedHead = 2, 2, 2
Lc.login()
advance(5)
local healedDeath = Lc.ns.Records.Get(Lc.guid, 2)
check("the author repairs a death that carried the wrong count", healedDeath and healedDeath.lifeHK == 13 and Lc.counter("records.healed") == 1
	and Lc.ns.Records.CheckChain(Journal(Lc)) == true, healedDeath and healedDeath.lifeHK)
local badKill = Lc.ns.Records.Encode({ type = "K", seq = 3, t = Mock.Server(), bucket = "w", how = "unk", lifeHK = 20 })
Lc.db().authors[Lc.guid].log[3] = badKill
Lc.db().authors[Lc.guid].head, Lc.db().authors[Lc.guid].count = 3, 3
check("a kill with a wrong count is never rewritten", Lc.ns.Records.HealOwn() == 0 and Lc.db().authors[Lc.guid].log[3] == badKill)
Lc.db().authors[Lc.guid].log[3] = nil
Lc.db().authors[Lc.guid].head, Lc.db().authors[Lc.guid].count = 2, 2
advance(120)
check("the repaired page is taken by a member", Held(A, Lc) == 2 and A.ns.Records.Get(Lc.guid, 2).lifeHK == 13, Held(A, Lc))

-- A relayed page that breaks the chain: its holder is set aside for a
-- while, without error, the page comes from another holder, and the
-- records around the break are kept for /kbs debug.
Lc.logout()
advance(5)
B.db().authors[Lc.guid].log[2] = brokenDeath
local lTail = Lc.ns.Util.Tail(Lc.guid)
Mc.login()
advance(1)
Mc.ns.Sync.State().holders[lTail] = { ["brenna ironvale"] = { head = 2, count = 2, at = Mock.Server() } }
Mc.ns.Sync.Schedule()
-- Checked before Mc's hello: the members who answer it may name Brenna
-- again, and a holder that announces again gets another chance.
advance(4)
check("a page that breaks the chain is refused and its holder set aside", Mc.counter("sync.pageChainBroken") == 1
	and Mc.db().debug.lastChainBreak and Mc.db().debug.lastChainBreak.seq == 2 and #Mc.db().debug.lastChainBreak.around == 2,
	Mc.counter("sync.pageChainBroken"))
-- Another holder announces a sound copy. Left to the answers to Mc's
-- hello, Brenna may answer first and the others then stay quiet.
Mc.fire("CHAT_MSG_ADDON", "KBS", "A^" .. lTail .. "=2/2", "GUILD", "Aldric Stormhand")
advance(56)
Mc.fire("GUILD_ROSTER_UPDATE")
advance(120)
check("the journal comes from another holder and nothing errored", Held(Mc, Lc) == 2 and Mc.ns.Records.Get(Lc.guid, 2).lifeHK == 13
	and #Mc.db().errors == 0, ("%d held, %d errors"):format(Held(Mc, Lc), #Mc.db().errors))
B.db().authors[Lc.guid].log[2] = A.db().authors[Lc.guid].log[2]

-- A member whose probe was older than 0.1.3: its file matched nothing, has
-- no assists ring and no place or subzone on the HKs. The import matches
-- them itself, by the probe's rule, from the blows and the deaths it kept.
local OLD = "Isolde Thorne-" .. Mock.REALM
local function Died(at, t, facts)
	return { at = at, t = t, bucket = "world", target = facts, zone = "Contreforts de Hautebrande", subzone = "Moulin-de-Tarren" }
end
I.probe = {
	schema = 1,
	me = { guid = I.guid, key = OLD, name = "Isolde Thorne" },
	guild = { name = "Savages", members = 10 },
	sessions = { { at = T, key = OLD, version = "0.1.2" } },
	log = {
		hk = {
			Hk(T + 1, 1000, "login", "world", 20),
			Hk(T + 100, 1100, "PLAYER_PVP_KILLS_CHANGED", "world", 21, 1),
			Hk(T + 200, 1200, "PLAYER_PVP_KILLS_CHANGED", "world", 22, 1),
			Hk(T + 300, 1300, "PLAYER_PVP_KILLS_CHANGED", "world", 23, 1),
			Hk(T + 400, 1400, "PLAYER_PVP_KILLS_CHANGED", "world", 25, 2),
			Hk(T + 1000, 2000, "enter-bg", "bg", 25, 0),
			Hk(T + 1100, 2100, "PLAYER_PVP_KILLS_CHANGED", "bg", 26, 1),
			Hk(T + 1200, 2200, "left-bg", "world", 26, 0),
		},
		kills = {
			{ at = T + 100, t = 1099.5, bucket = "world", role = "me", targetKind = "Player", target = Facts(HORDE[1], 27), pos = Pos(0.41, 0.52) },
			{ at = T + 400, t = 1399.6, bucket = "world", role = "party", targetKind = "Player", target = Facts(HORDE[5], 30), pos = Pos(0.45, 0.56) },
			{ at = T + 1100, t = 2100, bucket = "bg", role = "secret", targetKind = "secret", attackerSecret = true, targetSecret = true },
		},
		unitDied = {
			-- the blow's own victim
			Died(T + 100, 1099.5, Facts(HORDE[1], 27)),
			-- alone next to an HK with no blow: names the assist
			Died(T + 200, 1199.2, Facts(HORDE[2], 26)),
			-- an ally who died at the same moment: never a candidate
			Died(T + 200, 1199.4, { kind = "Player", guid = Guid(5), name = "Edric Vale", class = "PALADIN", race = "Humain", faction = "Alliance", factionGuess = "Alliance" }),
			-- two enemies for one HK: nobody is guessed
			Died(T + 300, 1299.5, Facts(HORDE[3], 25)),
			Died(T + 300, 1299.8, Facts(HORDE[4], 29)),
			-- a move of two: one explained by the group's blow, the other by the enemy who died with him
			Died(T + 400, 1399.6, Facts(HORDE[5], 30)),
			Died(T + 400, 1399.9, Facts(HORDE[6], 28)),
		},
		deaths = {},
		matches = {
			{ how = "active", startedAt = T + 1000, context = { bucket = "bg", instanceID = 489, instanceName = "Goulet des Chanteguerres" }, during = {} },
		},
	},
}
I.login()
advance(5)
local legacy = Journal(I)
check("an older probe's file is matched by the import itself", #legacy == 7 and I.said("repris de la sonde")
	and I.ns.Records.CheckChain(Journal(I)) == true, #legacy)
check("its killing blow keeps the victim and the blow's place", legacy[1].how == "kb" and legacy[1].vname == HORDE[1].name and legacy[1].vlevel == 27
	and legacy[1].mapID == 1424 and legacy[1].x == 0.41 and legacy[1].lifeHK == 21, legacy[1].how)
check("an enemy who died alone next to an HK names the assist, an ally never does", legacy[2].how == "ast" and legacy[2].vname == HORDE[2].name
	and legacy[2].mapID == nil and legacy[2].lifeHK == 22, legacy[2].how)
check("two enemies dead for one HK name nobody", legacy[3].how == "unk" and legacy[3].vtail == nil and legacy[3].lifeHK == 23, legacy[3].how)
check("a move of two: the group's blow, then the other enemy who died", legacy[4].how == "grp" and legacy[4].vname == HORDE[5].name
	and legacy[5].how == "ast" and legacy[5].vname == HORDE[6].name and legacy[5].lifeHK == 25, tostring(legacy[4].how) .. "/" .. tostring(legacy[5].how))
check("its battleground HK has no subzone to keep, and its match comes from the counter", legacy[6].how == "bg" and legacy[6].sub == nil
	and legacy[6].lifeHK == 26 and legacy[7].type == "M" and legacy[7].hk == 1 and legacy[7].instanceID == 489, legacy[6].how)
local iStats = I.ns.Stats.Character(I.guid, "all", "all")
check("the stats add them up", iStats.kills == 6 and iStats.kb == 1 and iStats.deaths == 0 and iStats.kills == Expected(I, "all").kills, iStats.kills)

--------------------------------------------------------------------------------
section("The window")
--------------------------------------------------------------------------------

-- A logged in again since the stats alias was taken: its modules were reloaded.
Stats = A.ns.Stats
A.slash("")
local window = A.env.KilledBySavagesFrame
check("/kbs opens the window", window ~= nil and window.shown == true)
check("the window registers for ESC", A.env.UISpecialFrames[1] == "KilledBySavagesFrame")
check("the footer says where the sync stands", type(window.footer.text) == "string"
	and (window.footer.text:find("À jour") ~= nil or window.footer.text:find("Synchronisation") ~= nil), window.footer.text)
local UI = A.ns.UI
check("the players tab is the home view", UI.State().tab == "players" and UI.State().period == "week")
local function Rows(view)
	return view and view.scrollBox and view.scrollBox.rows or {}
end
local playersTab = window.tabFrames.players
check("the players list has one row per player", #Rows(playersTab.view) == #Stats.Players("week", "all") and #Rows(playersTab.view) >= 1,
	#Rows(playersTab.view))
check("the first row carries the first player's numbers", Rows(playersTab.view)[1].row.data.rank == 1 and Rows(playersTab.view)[1].row.cells[2].text.text == Stats.Players("week", "all")[1].name)
for _, key in ipairs({ "characters", "guild", "hunt", "me", "options" }) do
	UI.SelectTab(key)
	check("the " .. key .. " tab builds and fills", window.tabFrames[key] ~= nil and window.tabFrames[key].shown == true)
end
check("the options tab reads the settings", window.tabFrames.options.boxes[1].checked == true and window.tabFrames.options.boxes[2].checked == false)
local optionsTab = window.tabFrames.options
check("the feed's tab box sits under the feed: ticked by default, resting while the feed is off",
	optionsTab.boxes[3].checked == true and optionsTab.boxes[3].enabled == false)

-- The scale: scaling the window moves the slider under the cursor, so while
-- the thumb is held only the number follows, and the window takes the scale
-- when the button comes up.
local slider = optionsTab.slider
local scaleBefore = A.db().settings.scale
slider:GetScript("OnMouseDown")(slider, "LeftButton")
slider:SetValue(1.2)
check("while the scale slider is held, only its number moves", (window.scale or 1) == scaleBefore
	and A.db().settings.scale == scaleBefore and optionsTab.scaleValue.text == "120%", optionsTab.scaleValue.text)
UI.Refresh()
check("a refresh meanwhile leaves the number alone", optionsTab.scaleValue.text == "120%" and slider.value == 1.2)
slider:GetScript("OnMouseUp")(slider, "LeftButton")
check("released, the window takes the new scale", window.scale == 1.2 and A.db().settings.scale == 1.2
	and optionsTab.scaleValue.text == "120%")
slider:SetValue(1)
check("set without the mouse, the scale applies at once", window.scale == 1 and A.db().settings.scale == 1
	and optionsTab.scaleValue.text == "100%")
check("the guild feed shows the latest events", #Rows(window.tabFrames.guild.view) > 0 and Rows(window.tabFrames.guild.view)[1].row.data.event ~= nil)
check("a character's kills from before the addon travel with its profile", (function()
	for _, row in ipairs(Stats.Characters("all", "all")) do
		if row.guid == F.guid then return row.before == 30 end
	end
	return false
end)())
check("the hunt boards fill", #Rows(window.tabFrames.hunt.victims) > 0 and #Rows(window.tabFrames.hunt.killers) > 0)
UI.SelectTab("me")
check("the me tab lists my characters and shows my alias", #Rows(window.tabFrames.me.view) == 1 and window.tabFrames.me.box.text == "Aldric the Bold")

-- A player is the name it chose, with no class of its own to show. Next to
-- each of my characters, a button makes its name mine in one click.
local function ChosenNames()
	local nameCell = Rows(playersTab.view)[1] and Rows(playersTab.view)[1].row.cells[2]
	local sand = A.ns.Theme.COLORS.text
	check("a player shows its name alone: no class icon, no class colour", nameCell ~= nil and nameCell.icon == nil
		and nameCell.text.color ~= nil and nameCell.text.color[1] == sand[1] and nameCell.text.color[2] == sand[2]
		and nameCell.text.color[3] == sand[3])
	local meView = window.tabFrames.me.view
	local function UseButton()
		local first = Rows(meView)[1]
		return first and first.row.cells[6] and first.row.cells[6].button, first and first.row.data
	end
	local function MyPlayerName()
		for _, row in ipairs(Stats.Players("all", "all")) do
			if row.me then return row.name end
		end
		return nil
	end
	local button, character = UseButton()
	local box, apply = window.tabFrames.me.box, window.tabFrames.me.apply
	check("each of my characters has a button for its name, unlit while another name is shown", button ~= nil and character ~= nil
		and button.label.text == A.ns.L.ME_USE_NAME and button.selected ~= true and MyPlayerName() ~= character.name, MyPlayerName())
	check("Apply rests while the box shows the name in use", apply ~= nil and box.text == "Aldric the Bold" and apply:IsEnabled() == false)
	button:GetScript("OnClick")(button)
	advance(10)
	button = UseButton()
	check("the button makes that name mine: in the box, on the board, for the guild, and lit", A.db().settings.alias == character.name
		and box.text == character.name and MyPlayerName() == character.name
		and B.db().authors[A.guid].profile.alias == character.name and button.selected == true, A.db().settings.alias)
	check("chosen, the name needs nothing more: its button says it is the current one and Apply rests",
		button.label.text == A.ns.L.ME_NAME_IN_USE and apply:IsEnabled() == false, button.label.text)
	local profilesSent = A.counter("sync.out.P.Success")
	button:GetScript("OnClick")(button)
	advance(10)
	check("lit, it does nothing more", A.db().settings.alias == character.name and A.counter("sync.out.P.Success") == profilesSent,
		A.counter("sync.out.P.Success") - profilesSent)
	-- A name typed by hand wakes Apply up; Apply takes it and rests again.
	box:SetText("Grim Warden")
	check("a name typed in the box wakes Apply up", apply:IsEnabled() == true)
	box:SetText("  " .. character.name .. " ")
	check("the name in use typed again leaves Apply resting", apply:IsEnabled() == false)
	box:SetText("Grim Warden")
	apply:GetScript("OnClick")(apply)
	advance(10)
	button = UseButton()
	check("Apply takes the typed name and rests, the character's button offers its name again", A.db().settings.alias == "Grim Warden"
		and B.db().authors[A.guid].profile.alias == "Grim Warden" and apply:IsEnabled() == false
		and button.label.text == A.ns.L.ME_USE_NAME and button.selected ~= true, A.db().settings.alias)
	profilesSent = A.counter("sync.out.P.Success")
	box:GetScript("OnEnterPressed")(box)
	advance(10)
	check("Enter on the name in use sends nothing", A.counter("sync.out.P.Success") == profilesSent,
		A.counter("sync.out.P.Success") - profilesSent)
	A.ns.Identity.SetAlias("Aldric the Bold")
	A.ns.UI.Refresh()
	advance(10)
end
ChosenNames()
UI.SetPeriod("last")
check("a period without data shows the empty state", window.tabFrames.me.view.empty.shown == true)
UI.SetPeriod("all")
-- The list hands the same buttons back with other data: dressed once, so
-- refreshed or scrolled rows never draw over what they showed before.
local reused = Rows(window.tabFrames.guild.view)[1]
check("a row handed back by the list keeps one set of cells", reused ~= nil and #reused.children == 1 and reused.row == reused.children[1],
	reused and #reused.children)
UI.SetBucket("b")
check("the battleground bucket keeps the matches' HKs", Rows(window.tabFrames.me.view)[1] and Rows(window.tabFrames.me.view)[1].row.data.kills == 5,
	Rows(window.tabFrames.me.view)[1] and Rows(window.tabFrames.me.view)[1].row.data.kills)
UI.SetBucket("all")
UI.SelectTab("players")
A.slash("")
check("/kbs closes the window", window.shown == false)
A.logout()
A.login()
advance(5)
check("the window remembers its tab and filters", A.db().settings.tab == "players" and A.db().settings.period == "all" and A.db().settings.bucket == "all")
check("the minimap button registered", A.ns.MinimapButton.registered == true)

-- The icon is the guild's logo, drawn by scripts\make-icon.ps1: a 32-bit
-- TGA the game loads, a disc on transparent corners.
local function LogoIcon()
	local backslash = string.char(92)
	local object = A.env.LibStub("LibDataBroker-1.1"):GetDataObjectByName("KilledBySavages")
	local toc = io.open("addon/KilledBySavages/KilledBySavages.toc", "rb")
	local tocText = toc and toc:read("*a") or ""
	if toc then toc:close() end
	local tocIcon = tocText:match("## IconTexture: ([^\r\n]+)")
	local prefix = table.concat({ "Interface", "AddOns", "KilledBySavages", "" }, backslash)
	local icon = object and object.icon or ""
	local file = icon:sub(1, #prefix) == prefix and ("addon/KilledBySavages/" .. icon:sub(#prefix + 1):gsub(backslash, "/") .. ".tga") or nil
	check("the minimap button and the addon list show the guild's logo", file ~= nil and tocIcon == icon, icon)
	local tga = file and io.open(file, "rb")
	local data = tga and tga:read("*a") or ""
	if tga then tga:close() end
	local width = (data:byte(13) or 0) + (data:byte(14) or 0) * 256
	local height = (data:byte(15) or 0) + (data:byte(16) or 0) * 256
	local function Alpha(x, y) return data:byte(18 + (y * width + x) * 4 + 4) end
	check("the logo is a 64 px 32-bit TGA, a disc on transparent corners", data:byte(3) == 2 and width == 64 and height == 64
		and data:byte(17) == 32 and data:byte(18) == 8 and #data == 18 + 64 * 64 * 4 and Alpha(0, 0) == 0 and Alpha(63, 63) == 0
		and Alpha(32, 32) == 255, #data)
end
LogoIcon()
A.slash("options")
check("/kbs options opens the board on its options tab", A.env.KilledBySavagesFrame.shown == true and A.ns.UI.State().tab == "options"
	and A.env.KilledBySavagesFrame.tabFrames.options ~= nil and A.env.KilledBySavagesFrame.tabFrames.options.shown == true)
A.slash("")

--------------------------------------------------------------------------------
section("Kill feed")
--------------------------------------------------------------------------------

-- Off by default: no tab, and no kill line in the main chat. On, every kill
-- or death of the guild lands in a chat tab of its own with the score
-- between the two, and still nothing in the main chat. Records are appended
-- straight here, so each line is exact.
local function FeedWindow(client)
	for _, w in pairs(client.windows) do
		if w.name == client.ns.L.KILLFEED_TAB and (w.shown or w.docked) then return w end
	end
	return nil
end
local function CountSince(client, from, needle)
	local n = 0
	for index = from + 1, #client.chat do
		if client.chat[index]:find(needle, 1, true) then n = n + 1 end
	end
	return n
end
local function ChatSince(client, from, needle)
	return CountSince(client, from, needle) > 0
end
-- A new session. The kills here move the server's counter without the
-- client's event, so a login sees a jump and holds new records while the
-- guild is asked, up to 120 s: the wait covers it.
local function Relog(client, between)
	client.logout()
	if between then between() end
	client.login()
	advance(130)
end
local zaljin = A.ns.Util.Tail(HORDE[2].guid)
local function KillZaljin(client)
	client.state.lifetime = client.state.lifetime + 1
	client.ns.Records.AppendOwn({ type = "K", t = Mock.Server(), bucket = "w", how = "kb", vtail = zaljin, vname = "Zaljin Darkspear",
		vclass = "SHAMAN", vrace = "Troll", mapID = 1424, x = 0.4, y = 0.5, lifeHK = client.state.lifetime })
	advance(1)
end
-- A guildmate's kill as the sync hands it over when it arrives live.
local function MateKill(client, mate)
	client.ns.Fire("RecordStored", mate.guid, 1, { type = "K", seq = 1, t = Mock.Server(), bucket = "w", how = "kb",
		vtail = zaljin, vname = "Zaljin Darkspear", vclass = "SHAMAN", vrace = "Troll", mapID = 1424 }, "")
	advance(1)
end
local function FeedBox(client)
	client.slash("options")
	return client.env.KilledBySavagesFrame.tabFrames.options.boxes[2]
end
local function Tick(client, value)
	local box = FeedBox(client)
	box:SetChecked(value)
	box:GetScript("OnClick")(box)
	client.slash("")
	advance(1)
end

-- The main chat announcement of 0.1.13 is gone, its setting dropped.
A.db().settings.announce = true
Relog(A)
check("the kill feed is off by default, the old announcement setting dropped", A.db().settings.killfeed == false
	and A.db().settings.announce == nil and FeedWindow(A) == nil)
local chatMark = #A.chat
KillZaljin(A)
MateKill(A, B)
check("off, neither my kills nor a guildmate's write anything in the chat", not ChatSince(A, chatMark, "Zaljin Darkspear") and FeedWindow(A) == nil)

-- Ticked with no tab of that name: the lines go to the main chat, and a line
-- there says how to make the tab, once, naming the General tab and its menu
-- entry in the client's words. The addon opens no chat window: run from an
-- addon, the game's chat window code taints the chat edit box.
local howTo = A.ns.L.KILLFEED_MAKE_TAB:format(A.ns.L.KILLFEED_TAB, "General", "New Window", A.ns.L.KILLFEED_TAB)
local windowsBefore = count(A.windows)
chatMark = #A.chat
Tick(A, true)
KillZaljin(A)
KillZaljin(A)
check("ticked with no Kills tab, the lines go to the main chat, told once how to make the tab, and no window opens",
	A.db().settings.killfeed == true and FeedWindow(A) == nil and count(A.windows) == windowsBefore
	and ChatSince(A, chatMark, A.ns.L.KILLFEED_ON_MAIN) and CountSince(A, chatMark, "Zaljin Darkspear") == 2
	and CountSince(A, chatMark, howTo) == 1, CountSince(A, chatMark, howTo))

-- The player makes the tab: the lines land there from the next one on.
A.asPlayer(A.env.FCF_OpenNewWindow, A.ns.L.KILLFEED_TAB, true)
local feedTab = FeedWindow(A)

-- A named kill of mine: the line carries both names and my score on the enemy.
before = #feedTab.lines
chatMark = #A.chat
KillZaljin(A)
local feedAgg = A.ns.Stats.AuthorAggregate(A.guid)
local killScore = ("(%d-%d)"):format(feedAgg.victims[zaljin] and feedAgg.victims[zaljin].count or 0, feedAgg.killers[zaljin] and feedAgg.killers[zaljin].count or 0)
local feedLine = feedTab.lines[#feedTab.lines] or ""
check("a kill lands in the tab with the score between the two", #feedTab.lines == before + 1 and feedLine:find("Aldric Stormhand", 1, true) ~= nil
	and feedLine:find("Zaljin Darkspear", 1, true) ~= nil and feedLine:find(killScore, 1, true) ~= nil, feedLine)
before = #feedTab.lines
MateKill(A, B)
feedLine = feedTab.lines[#feedTab.lines] or ""
check("a guildmate's kill lands there too", #feedTab.lines == before + 1 and feedLine:find("Brenna Ironvale", 1, true) ~= nil
	and feedLine:find("Zaljin Darkspear", 1, true) ~= nil, feedLine)
check("on, nothing goes to the main chat", not ChatSince(A, chatMark, "Zaljin Darkspear"))

-- A death of mine: the killer comes first, with its score on me.
before = #feedTab.lines
local gruk = A.ns.Util.Tail(HORDE[1].guid)
A.ns.Records.AppendOwn({ type = "D", t = Mock.Server(), bucket = "w", ktail = gruk, kname = "Gruk Bonecrusher", kclass = "WARRIOR",
	krace = "Orc", kkind = "p", spell = "Frappe mortelle", mapID = 1424, x = 0.4, y = 0.5, lifeHK = A.state.lifetime })
advance(1)
feedAgg = A.ns.Stats.AuthorAggregate(A.guid)
local deathScore = ("(%d-%d)"):format(feedAgg.killers[gruk] and feedAgg.killers[gruk].count or 0, feedAgg.victims[gruk] and feedAgg.victims[gruk].count or 0)
feedLine = feedTab.lines[#feedTab.lines] or ""
check("a death lands there too, the killer first with its score on me", #feedTab.lines == before + 1
	and feedLine:find("Gruk Bonecrusher", 1, true) ~= nil and feedLine:find("Aldric Stormhand", 1, true) ~= nil
	and feedLine:find(deathScore, 1, true) ~= nil
	and feedLine:find("Gruk Bonecrusher", 1, true) < feedLine:find("Aldric Stormhand", 1, true), feedLine)

-- A battleground HK names nobody: its match is on the board, not the feed.
before = #feedTab.lines
A.state.lifetime = A.state.lifetime + 1
A.ns.Records.AppendOwn({ type = "K", t = Mock.Server(), bucket = "b", how = "bg", sub = "Pic de Dun Baldar", lifeHK = A.state.lifetime })
advance(1)
check("a battleground HK is not a feed line", #feedTab.lines == before)

-- A battleground hides whom a member kills: its deaths give no line either,
-- and the match gives one at its end, from the scoreboard. The score of a
-- line counts the world only.
local function BattlegroundFeed()
	local L = A.ns.L
	local function LastLine() return feedTab.lines[#feedTab.lines] or "" end
	local function Has(line, needle) return line:find(needle, 1, true) ~= nil end
	local agg = A.ns.Stats.AuthorAggregate(A.guid)
	local gruksBefore = agg.killers[gruk] and agg.killers[gruk].count or 0
	advance(5)
	before = #feedTab.lines
	A.ns.Records.AppendOwn({ type = "D", t = Mock.Server(), bucket = "b", ktail = gruk, kname = "Gruk Bonecrusher", kclass = "WARRIOR",
		krace = "Orc", kkind = "p", spell = "Frappe mortelle", sub = "Pic de Dun Baldar", lifeHK = A.state.lifetime })
	advance(1)
	A.ns.Fire("RecordStored", B.guid, 1, { type = "D", seq = 1, t = Mock.Server(), bucket = "b", ktail = gruk,
		kname = "Gruk Bonecrusher", kclass = "WARRIOR", krace = "Orc", kkind = "p", sub = "Pic de Dun Baldar" }, "")
	advance(1)
	check("a battleground death is no feed line either, mine or a guildmate's", #feedTab.lines == before)

	A.state.lifetime = A.state.lifetime + 2
	A.ns.Records.AppendOwn({ type = "M", t = Mock.Server(), instanceID = 30, duration = 900, winner = 1, hk = 3, kb = 1, deaths = 2,
		honor = 120, lifeHK = A.state.lifetime, live = 1, mapID = 1459, lines = {} })
	advance(1)
	local line = LastLine()
	check("the match gives one line at its end, with my kills, killing blows and deaths", #feedTab.lines == before + 1
		and Has(line, "Aldric Stormhand") and Has(line, L.KILLFEED_N_KILLS:format(3)) and Has(line, L.KILLFEED_ONE_BLOW:format(1))
		and not Has(line, L.KILLFEED_N_BLOWS:format(1)) and Has(line, L.KILLFEED_N_DEATHS:format(2)), line)

	before = #feedTab.lines
	A.ns.Fire("RecordStored", B.guid, 2, { type = "M", seq = 2, t = Mock.Server(), instanceID = 30, winner = 1, hk = 5, kb = 0,
		deaths = 1, honor = 90, live = 5, mapID = 1459, lines = {} }, "")
	advance(1)
	line = LastLine()
	check("a guildmate's match too, with its own numbers", #feedTab.lines == before + 1 and Has(line, "Brenna Ironvale")
		and Has(line, L.KILLFEED_N_KILLS:format(5)) and Has(line, L.KILLFEED_ONE_DEATH:format(1)), line)

	-- Left before the scoreboard was read: the record only has the HKs
	-- the counter moved by.
	before = #feedTab.lines
	A.ns.Fire("RecordStored", B.guid, 3, { type = "M", seq = 3, t = Mock.Server(), instanceID = 30, hk = 4, kb = 0, deaths = 0,
		honor = 0, live = 4, mapID = 1459, lines = {} }, "")
	advance(1)
	line = LastLine()
	check("a match left before its scoreboard gives its kills only", #feedTab.lines == before + 1 and Has(line, "Brenna Ironvale")
		and Has(line, L.KILLFEED_N_KILLS:format(4)) and not Has(line, L.KILLFEED_N_BLOWS:format(0))
		and not Has(line, L.KILLFEED_N_DEATHS:format(0)), line)

	before = #feedTab.lines
	A.ns.Fire("RecordStored", B.guid, 4, { type = "M", seq = 4, t = Mock.Server(), instanceID = 0, hk = 0, kb = 0, deaths = 0,
		honor = 0, live = 0, lines = {} }, "")
	advance(1)
	check("a scoreboard written by hand for a world raid gives no line", #feedTab.lines == before)

	-- Gruk's kill on me in the battleground stays out of the score.
	advance(5)
	before = #feedTab.lines
	A.ns.Records.AppendOwn({ type = "D", t = Mock.Server(), bucket = "w", ktail = gruk, kname = "Gruk Bonecrusher", kclass = "WARRIOR",
		krace = "Orc", kkind = "p", spell = "Frappe mortelle", mapID = 1424, x = 0.4, y = 0.5, lifeHK = A.state.lifetime })
	advance(1)
	agg = A.ns.Stats.AuthorAggregate(A.guid)
	local score = ("(%d-%d)"):format(gruksBefore + 1, agg.victims[gruk] and agg.victims[gruk].count or 0)
	line = LastLine()
	check("the score of a line counts the world only", #feedTab.lines == before + 1 and Has(line, score), line)
end
BattlegroundFeed()

-- A member on a version before 0.1.13 writes some deaths twice in the same
-- second (the client fires PLAYER_DEAD twice): the board counts the death
-- once, and the feed gives it one line. A death a while later is a line
-- again, its score one up.
local function RepeatedDeathFeed()
	if not B.online then
		B.login()
		advance(20)
	end
	local function Death()
		return { type = "D", t = Mock.Server(), bucket = "w", ktail = gruk, kname = "Gruk Bonecrusher", kclass = "WARRIOR",
			krace = "Orc", kkind = "p", spell = "Frappe mortelle", mapID = 1424, x = 0.4, y = 0.5, lifeHK = B.state.lifetime }
	end
	local function Lines(from)
		local hits = {}
		for index = from + 1, #feedTab.lines do
			local line = feedTab.lines[index]
			if line:find("Gruk Bonecrusher", 1, true) and line:find("Brenna Ironvale", 1, true) then hits[#hits + 1] = line end
		end
		return hits
	end
	local function Deaths()
		local agg = A.ns.Stats.AuthorAggregate(B.guid)
		return agg.killers[gruk] and agg.killers[gruk].count or 0
	end
	local function Score(deaths)
		local agg = A.ns.Stats.AuthorAggregate(B.guid)
		return ("(%d-%d)"):format(deaths, agg.victims[gruk] and agg.victims[gruk].count or 0)
	end
	advance(5)
	local deathsBefore = Deaths()
	local start = #feedTab.lines
	local first = B.ns.Records.AppendOwn(Death())
	local second = B.ns.Records.AppendOwn(Death())
	advance(6)
	local lines = Lines(start)
	check("both copies of a death written twice reach the guild", first ~= nil and second ~= nil
		and A.ns.Records.Get(B.guid, first) ~= nil and A.ns.Records.Get(B.guid, second) ~= nil, tostring(first) .. " " .. tostring(second))
	check("a death a guildmate's old version wrote twice gives one feed line, counted once", #lines == 1
		and Deaths() == deathsBefore + 1 and lines[1]:find(Score(deathsBefore + 1), 1, true) ~= nil,
		#lines .. ": " .. table.concat(lines, " | "))
	advance(10)
	start = #feedTab.lines
	B.ns.Records.AppendOwn(Death())
	advance(4)
	lines = Lines(start)
	check("a death a while later is a line again, its score one up", #lines == 1
		and lines[1]:find(Score(deathsBefore + 2), 1, true) ~= nil, #lines .. ": " .. table.concat(lines, " | "))
end
RepeatedDeathFeed()

-- The tab outlives a login: the lines find it again, nothing is opened.
before = #feedTab.lines
Relog(A)
KillZaljin(A)
local feedCount = 0
for _, w in pairs(A.windows) do
	if w.name == A.ns.L.KILLFEED_TAB then feedCount = feedCount + 1 end
end
check("at the next login the lines find the tab again, and no tab is opened", FeedWindow(A) == feedTab and feedCount == 1
	and #feedTab.lines == before + 1)

-- The option is account-wide, chat tabs belong to each character: one
-- without the tab gets the lines in the main chat, told once how to make it.
Relog(A, function() A.windows = {} end)
chatMark = #A.chat
KillZaljin(A)
KillZaljin(A)
check("a character without the tab gets the lines in the main chat, told once how to make the tab",
	FeedWindow(A) == nil and CountSince(A, chatMark, "Zaljin Darkspear") == 2 and CountSince(A, chatMark, howTo) == 1)

-- The player makes the tab, then closes it: the feed turns off, said once
-- in the main chat, and the next kill goes nowhere.
A.asPlayer(A.env.FCF_OpenNewWindow, A.ns.L.KILLFEED_TAB, true)
feedTab = FeedWindow(A)
KillZaljin(A)
A.asPlayer(A.env.FCF_Close, feedTab.frame)
before = #feedTab.lines
chatMark = #A.chat
KillZaljin(A)
check("closing the tab turns the feed off, said in the main chat", A.db().settings.killfeed == false
	and ChatSince(A, chatMark, A.ns.L.KILLFEED_CLOSED) and not ChatSince(A, chatMark, "Zaljin Darkspear") and #feedTab.lines == before)

-- Ticked again with the tab still closed: the main chat again, with how to
-- make the tab; unticked, no line goes anywhere.
chatMark = #A.chat
Tick(A, true)
KillZaljin(A)
check("ticked again with no tab, the lines go to the main chat with how to make it", A.db().settings.killfeed == true
	and FeedWindow(A) == nil and ChatSince(A, chatMark, howTo) and ChatSince(A, chatMark, "Zaljin Darkspear"))
Tick(A, false)
chatMark = #A.chat
KillZaljin(A)
check("unticked, no line goes anywhere", A.db().settings.killfeed == false and not ChatSince(A, chatMark, "Zaljin Darkspear"))

-- The second box says where the lines go: the feed's own tab (ticked by
-- default) or the main chat. It only matters, and only wakes up, while the
-- feed is on.
local function OptionsBox(client, index)
	client.slash("options")
	local box = client.env.KilledBySavagesFrame.tabFrames.options.boxes[index]
	client.slash("")
	return box
end
local function TickTab(client, value)
	client.slash("options")
	local box = client.env.KilledBySavagesFrame.tabFrames.options.boxes[3]
	box:SetChecked(value)
	box:GetScript("OnClick")(box)
	client.slash("")
	advance(1)
end
local tabBox = OptionsBox(A, 3)
local restingR, restingG = A.ns.Theme.Color("disabled")
check("off, the feed's tab box rests, greyed", tabBox.enabled == false and tabBox.label.color[1] == restingR
	and tabBox.label.color[2] == restingG)
-- The player makes the tab again: ticked, the feed wakes its box up and
-- says so in the tab.
A.asPlayer(A.env.FCF_OpenNewWindow, A.ns.L.KILLFEED_TAB, true)
Tick(A, true)
feedTab = FeedWindow(A)
check("ticked, the feed wakes its tab box up at once and says so in the player's tab", tabBox.enabled == true
	and feedTab ~= nil and feedTab.lines[#feedTab.lines] == A.ns.L.KILLFEED_ON)
chatMark = #A.chat
before = #feedTab.lines
TickTab(A, false)
KillZaljin(A)
check("unticked, the lines go to the main chat, said there, and the player's tab stays as it is", FeedWindow(A) == feedTab
	and #feedTab.lines == before and A.db().settings.killfeed == true and A.db().settings.killfeedTab == false
	and ChatSince(A, chatMark, A.ns.L.KILLFEED_ON_MAIN) and ChatSince(A, chatMark, "Zaljin Darkspear"))
Relog(A)
chatMark = #A.chat
KillZaljin(A)
check("after a login the lines still go to the main chat", ChatSince(A, chatMark, "Zaljin Darkspear") and #feedTab.lines == before)
Tick(A, false)
chatMark = #A.chat
Tick(A, true)
check("ticked with the main chat chosen, the feed says so there", ChatSince(A, chatMark, A.ns.L.KILLFEED_ON_MAIN)
	and not ChatSince(A, chatMark, howTo))
TickTab(A, true)
chatMark = #A.chat
KillZaljin(A)
check("ticked again, the lines go back to the player's tab", (feedTab.lines[#feedTab.lines] or ""):find("Zaljin Darkspear", 1, true) ~= nil
	and not ChatSince(A, chatMark, "Zaljin Darkspear"))
Tick(A, false)

-- Closed with no line before the logout: the feed is off all the same.
A.ns.Killfeed.Enable()
A.asPlayer(A.env.FCF_Close, FeedWindow(A).frame)
A.logout()
check("a tab closed before the logout leaves the feed off", A.saved.settings.killfeed == false)
A.login()
advance(130)
check("and no tab opens at the next login", FeedWindow(A) == nil)

-- In a fight the lines go to the tab as ever: nothing waits.
A.asPlayer(A.env.FCF_OpenNewWindow, A.ns.L.KILLFEED_TAB, true)
feedTab = FeedWindow(A)
A.ns.Killfeed.Enable()
A.state.combat = true
KillZaljin(A)
check("in a fight the lines still go to the tab", (feedTab.lines[#feedTab.lines] or ""):find("Zaljin Darkspear", 1, true) ~= nil)
A.state.combat = false
A.ns.Killfeed.Disable()
check("unticked, the player's tab stays open", FeedWindow(A) == feedTab)
A.asPlayer(A.env.FCF_Close, feedTab.frame)

-- Through all of it the addon opened, closed and selected no chat window,
-- and no file of it calls the game's code that does: run from an addon,
-- that code taints the chat edit box for the rest of the session (in game,
-- /invite was refused and group chat failed on a secret value).
check("the addon never opens, closes or selects a chat window", (A.addonChatWrites or 0) == 0,
	table.concat(A.addonChatWriteNames or {}, ", "))
check("no addon file calls the game's chat window functions that write", (function()
	local offenders = {}
	for tocLine in io.lines("addon/KilledBySavages/KilledBySavages.toc") do
		local file = tocLine:match("^([%w_\\/%.%-]+%.lua)%s*$")
		if file then
			local handle = assert(io.open("addon/KilledBySavages/" .. file:gsub("\\", "/"), "rb"))
			local code = handle:read("*a")
			handle:close()
			code = code:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
			for _, name in ipairs({ "FCF_OpenNewWindow", "FCF_Close", "FCFDock_SelectWindow", "FCF_SelectDockFrame",
				"FCF_DockFrame", "SetLastActiveWindow" }) do
				if code:find(name, 1, true) then offenders[#offenders + 1] = file .. ": " .. name end
			end
		end
	end
	return #offenders == 0, table.concat(offenders, ", ")
end)())

-- Same reason for the game's Settings panel: HideUIPanel run by an addon
-- taints the panel manager, so the options close it only when it is open.
local panelHides = 0
A.env.HideUIPanel = function() panelHides = panelHides + 1 end
A.env.SettingsPanel = { shown = false, IsShown = function(self) return self.shown end }
A.slash("options")
A.slash("")
local hidesWhileClosed = panelHides
A.env.SettingsPanel.shown = true
A.slash("options")
A.slash("")
check("the options leave the game's Settings panel alone unless it is open", hidesWhileClosed == 0 and panelHides == 1, panelHides)
A.env.HideUIPanel, A.env.SettingsPanel = nil, nil

--------------------------------------------------------------------------------
section("Newer versions")
--------------------------------------------------------------------------------

-- Hellos and profiles state the version. A member is told of a newer release
-- once per session, one who logs in on an older version is answered by one
-- who runs the newer, and a dev build is never announced. Every other client
-- here runs "0.1.0-test", which answers nothing. In a function of its own:
-- the main chunk is near Lua's limit of locals.
local function NewerVersions()
	local function Told(client, from, version)
		local needle = client.ns.L.UPDATE_AVAILABLE:format(version)
		local n = 0
		for index = from + 1, #client.chat do
			if client.chat[index]:find(needle, 1, true) then n = n + 1 end
		end
		return n
	end
	local function SentBy(from, client, kind)
		local n = 0
		for index = from + 1, #network.sent do
			local sent = network.sent[index]
			if sent.from == client.name and sent.channel == "GUILD" and sent.text:sub(1, 1) == kind then n = n + 1 end
		end
		return n
	end
	-- A new session on a version. The login hello goes out again only 10 min
	-- after the last one: the wait is lifted here.
	local function Session(client, version, between)
		if client.online then client.logout() end
		client.version = version
		local own = client.saved and client.saved.characters and client.saved.characters[client.guid]
		if own then own.lastHello = 0 end
		if between then between() end
		client.login()
		advance(130)
	end
	-- The copy of a guildmate's profile a client holds, made older.
	local function OlderCopy(client, of)
		local entry = client.saved.authors[of.guid]
		if entry and entry.profile then entry.profile.version = "0.1.15" end
	end

	Session(B, "0.1.15")
	Session(C, "0.1.15")
	local chatB, chatC = #B.chat, #C.chat
	Session(A, "0.1.16")
	check("a hello from a newer release tells the member once, in the chat", Told(B, chatB, "0.1.16") == 1
		and Told(C, chatC, "0.1.16") == 1, Told(B, chatB, "0.1.16"))
	A.ns.Sync.SendHello("recovery")
	advance(10)
	check("the same version again says nothing more this session", Told(B, chatB, "0.1.16") == 1)

	-- B logs in again on 0.1.15. Its copy of A's profile is made older, so
	-- only A's answer can tell it.
	chatB = #B.chat
	local netMark = #network.sent
	Session(B, "0.1.15", function() OlderCopy(B, A) end)
	check("a member who logs in on an older version gets one answer, from the member on the newer one",
		SentBy(netMark, A, "V") == 1 and SentSince(netMark, "GUILD", "V") == 1, SentSince(netMark, "GUILD", "V"))
	check("and is told once", Told(B, chatB, "0.1.16") == 1)

	-- Two members on the newer version: one answers, the other hears it and
	-- keeps quiet. Both answer only when they send within the time an
	-- answer takes to arrive, which costs one message.
	Session(C, "0.1.16")
	chatB, netMark = #B.chat, #network.sent
	local quiet = A.counter("sync.versionAnswerSuppressed") + C.counter("sync.versionAnswerSuppressed")
		+ A.counter("sync.skipped.V") + C.counter("sync.skipped.V")
	Session(B, "0.1.15", function() OlderCopy(B, A) OlderCopy(B, C) end)
	local answeredAt = {}
	for index = netMark + 1, #network.sent do
		local message = network.sent[index]
		if message.channel == "GUILD" and message.text:sub(1, 2) == "V^" then answeredAt[#answeredAt + 1] = message.at end
	end
	local hushed = A.counter("sync.versionAnswerSuppressed") + C.counter("sync.versionAnswerSuppressed")
		+ A.counter("sync.skipped.V") + C.counter("sync.skipped.V") == quiet + 1
	check("with two members on the newer version, one answers, or both when they send at once",
		(#answeredAt == 1 and hushed) or (#answeredAt == 2 and math.abs(answeredAt[1] - answeredAt[2]) < 0.1), #answeredAt)
	check("and the member is told once", Told(B, chatB, "0.1.16") == 1)

	-- Nobody on the newer version online: the profiles held tell it at login.
	A.ns.Sync.SendHello("recovery")
	advance(10)
	A.logout()
	C.logout()
	chatB, netMark = #B.chat, #network.sent
	Session(B, "0.1.15")
	check("alone among older versions, the profiles held tell it at login", Told(B, chatB, "0.1.16") == 1
		and SentSince(netMark, "GUILD", "V") == 0)

	-- A dev build: never announced, and it answers nobody.
	chatB = #B.chat
	Session(A, "0.1.17-dev")
	check("a dev build is never announced", Told(B, chatB, "0.1.17-dev") == 0 and Told(B, chatB, "0.1.17") == 0)
	chatB, netMark = #B.chat, #network.sent
	Session(B, "0.1.15")
	check("and answers nobody", SentBy(netMark, A, "V") == 0 and Told(B, chatB, "0.1.17") == 0)

	-- A dev build hears of a newer release like anyone, and a newer one
	-- still in the same session is told too.
	local chatA = #A.chat
	Session(C, "0.1.18")
	check("a dev build hears of a newer release", Told(A, chatA, "0.1.18") == 1)
	check("so does an older one", Told(B, chatB, "0.1.18") == 1)
	chatA = #A.chat
	Session(A, "0.1.19")
	check("a newer one again in the same session is told too", Told(B, chatB, "0.1.19") == 1 and Told(B, chatB, "0.1.18") == 1)
	check("the member on the newest version is never told", not ChatSince(A, chatA, A.ns.L.UPDATE_AVAILABLE:match("^(.-)%(")))

	-- Only plain digits: the field goes to the chat.
	local bad = B.counter("sync.versionBad")
	chatB = #B.chat
	C.ns.Sync.SendRaw("V^0.2.0|cffff0000 now", "GUILD")
	C.ns.Sync.SendRaw("V^0.2.0.1", "GUILD")
	advance(2)
	check("a version that is not plain digits is ignored", not ChatSince(B, chatB, "0.2.0") and B.counter("sync.versionBad") == bad + 2)

	-- A version from before 0.1.15 cannot tell its player: no answer.
	netMark = #network.sent
	Session(B, "0.1.14")
	check("no answer to a version too old to tell its player", SentSince(netMark, "GUILD", "V") == 0)

	-- /kbs status says it again.
	chatB = #B.chat
	B.slash("status")
	check("/kbs status names the newer version", Told(B, chatB, "0.1.19") == 1)
end
NewerVersions()

--------------------------------------------------------------------------------
section("Members online with the addon")
--------------------------------------------------------------------------------

-- The footer counts the members online with the addon: those the roster
-- shows online whose profile we hold or who spoke to us this session. The
-- hellos heard since our own login are not enough: members already online
-- never say hello again.
local function OnlineMembers()
	local function MembersWithProfile()
		local online, offline = 0, 0
		for _, client in ipairs(Mock.clients) do
			local author = A.db().authors[client.guid]
			if client ~= A and author and author.profile and A.ns.Identity.MemberByTail(A.ns.Util.Tail(client.guid)) then
				if client.online then online = online + 1 else offline = offline + 1 end
			end
		end
		return online, offline
	end
	if C.online then C.logout() end
	A.logout()
	A.login()
	advance(30)
	A.ns.Identity.UpdateRoster(true)
	local expectedOnline, knownOffline = MembersWithProfile()
	local countedOnline = A.ns.Sync.Status().peers
	check("after a login every member online with the addon counts, not only the hellos heard since, and nobody offline",
		countedOnline == expectedOnline and expectedOnline >= 2 and knownOffline >= 1,
		("%d counted, %d online, %d offline"):format(countedOnline, expectedOnline, knownOffline))

	-- A member whose profile we lack counts once a message of theirs came in.
	local bProfile = A.db().authors[B.guid].profile
	A.db().authors[B.guid].profile = nil
	B.ns.Sync.SendRaw("Z^here", "GUILD")
	advance(1)
	check("a member we only heard from counts too", B.online and A.ns.Sync.Status().peers == expectedOnline,
		A.ns.Sync.Status().peers)
	A.db().authors[B.guid].profile = bProfile

	-- Who is online comes from the roster: asked again when the board opens,
	-- and once a minute while it stays open.
	local rosterAsked = 0
	local guildInfo = A.env.C_GuildInfo
	local askRoster = guildInfo.GuildRoster
	guildInfo.GuildRoster = function(...)
		rosterAsked = rosterAsked + 1
		return askRoster(...)
	end
	A.slash("")
	local board = A.env.KilledBySavagesFrame
	local askedAtOpening = rosterAsked
	board:GetScript("OnUpdate")(board, 61)
	check("the board asks for the roster when it opens, and once a minute while open", askedAtOpening >= 1
		and rosterAsked == askedAtOpening + 1, ("%d at opening, %d after a minute"):format(askedAtOpening, rosterAsked))
	A.slash("")
	guildInfo.GuildRoster = askRoster
	C.login()
	advance(20)
end
OnlineMembers()

--------------------------------------------------------------------------------
section("Players on an older addon")
--------------------------------------------------------------------------------

-- The players whose addon is older than the newest release, by player and
-- judged by the character heard from last. A hello goes out at the login
-- after an update however recent the last one, a presence message now and
-- then tells the version to those who missed it, and an alt that logs in
-- with the new addon clears its player. The board says how many, the
-- number underlined with dots, and names them on hover. Here A runs
-- 0.1.19, B 0.1.14, C 0.1.18 and the others 0.1.0-test.
local function OutdatedAddons()
	local Sync, L = A.ns.Sync, A.ns.L
	local function NameOf(client)
		local author = A.db().authors[client.guid]
		return author and author.profile and author.profile.alias or client.name
	end
	local function Listed(name)
		for _, player in ipairs(Sync.Outdated().players) do
			if player.name == name then return player end
		end
		return nil
	end
	local function NewSession(client, version)
		client.logout()
		client.version = version
		client.login()
		advance(30)
	end
	A.ns.Identity.UpdateRoster(true)
	local listB, listC = Listed(NameOf(B)), Listed(NameOf(C))
	check("the players on an older addon than the newest release are listed with their version, not ourselves",
		Sync.Outdated().newest == "0.1.19" and listB and listB.version == "0.1.14" and listB.silent == true
		and listC and listC.version == "0.1.18" and not listC.silent and Listed(NameOf(A)) == nil,
		listB and listB.version)

	-- C updates and logs in again two minutes after its last hello.
	local skipped = C.counter("sync.helloSkipped")
	NewSession(C, "0.1.19")
	check("an update is said at the next login however recent the last hello, and its player drops off",
		Listed(NameOf(C)) == nil and C.counter("sync.helloSkipped") == skipped)

	-- D updated while A was away: A's copy still says the old version, until
	-- D's next presence message.
	NewSession(D, "0.1.19")
	A.db().authors[D.guid].profile.version = "0.1.0-test"
	local wasListed = Listed(NameOf(D)) ~= nil
	local presences = A.counter("sync.presenceReceived")
	advance(600)
	check("a presence message brings the version a member runs now", wasListed and Listed(NameOf(D)) == nil
		and A.counter("sync.presenceReceived") > presences and A.db().authors[D.guid].profile.version == "0.1.19")

	-- B's alt logs in with the new addon: B's player is up to date, whatever
	-- B itself was last heard on.
	local alt = NewClient({ name = "Bryn Ironvale", guid = Guid(30), class = "PRIEST", race = "Dwarf", guild = "Savages",
		lifetime = 5, battleTag = "Brenna#1188", rank = 5 })
	Mock.SetGuildRoster({ { guid = A.guid, rank = 0 }, { guid = B.guid, rank = 2 }, { guid = C.guid, rank = 4 }, { guid = Guid(5), rank = 3 },
		{ guid = D.guid, rank = 3 }, { guid = E.guid, rank = 3 }, { guid = F.guid, rank = 3 }, { guid = G.guid, rank = 3 }, { guid = H.guid, rank = 3 },
		{ guid = I.guid, rank = 3 }, { guid = J.guid, rank = 3 }, { guid = K.guid, rank = 3 }, { guid = Guid(13), rank = 5 }, { guid = Guid(14), rank = 5 },
		{ guid = Lc.guid, rank = 3 }, { guid = Mc.guid, rank = 3 }, { guid = alt.guid, rank = 5 } })
	RefreshRosters()
	-- One account plays one character at a time: B logs out, its alt in.
	B.logout()
	advance(5)
	alt.version = "0.1.19"
	alt.login()
	advance(30)
	A.ns.Identity.UpdateRoster(true)
	local stillBehind = false
	for _, player in ipairs(Sync.Outdated().players) do
		if player.version == "0.1.14" or player.name == "Bryn Ironvale" or player.name == NameOf(B) then stillBehind = true end
	end
	check("an alt that logs in with the new addon clears its player", not stillBehind)
	alt.logout()
	advance(5)
	B.version = "0.1.19"
	B.login()
	advance(30)

	-- E on 0.1.16: behind, but its addon tells it of the new one.
	if E.online then E.logout() end
	E.version = "0.1.16"
	E.login()
	advance(30)

	-- The board: how many, the number dotted, the names on hover.
	local behind = #Sync.Outdated().players
	A.slash("")
	local board = A.env.KilledBySavagesFrame
	board:GetScript("OnUpdate")(board, 1)
	local notice = board.outdated
	check("the board says how many players have an outdated addon", behind >= 1 and notice.shown
		and notice.count.text == tostring(behind) and notice.rest.text == (behind == 1 and L.OUTDATED_ONE or L.OUTDATED_MANY)
		and #notice.dots >= 1, notice.count.text)
	notice:GetScript("OnEnter")(notice)
	local tip = A.env.GameTooltip.tooltipLines or {}
	local namesOld = false
	for index = 2, #tip do
		if tip[index]:find("0.1.0-test", 1, true) then namesOld = true end
	end
	check("hovering it lists them with their version", tip[1] == L.OUTDATED_TITLE:format("0.1.19") and namesOld, tip[1])
	-- Those too old to be told are in orange, the whole line; the others not.
	local warnR, warnG, warnB = A.ns.Theme.Color("warn")
	local colors = A.env.GameTooltip.tooltipColors or {}
	local lineE, oldInOrange = nil, false
	for index = 2, #tip do
		if tip[index]:find(NameOf(E) .. " | ", 1, true) == 1 then lineE = index end
		local c = colors[index]
		if tip[index]:find("0.1.0-test", 1, true) and c and c[1] == warnR and c[2] == warnG and c[3] == warnB
			and c[4] == warnR and c[5] == warnG and c[6] == warnB then
			oldInOrange = true
		end
	end
	local colorE = lineE and colors[lineE]
	check("the players too old to be told are in orange, the whole line, the others not, and the note says what orange means",
		oldInOrange and colorE ~= nil and colorE[1] ~= warnR and colorE[4] ~= warnR and tip[#tip] == L.OUTDATED_SILENT,
		lineE and tip[lineE])
	-- The footer ticks every second; who is outdated is a pass over the
	-- whole roster, looked at again when something says it changed or once
	-- in a while.
	local real = Sync.Outdated
	local asked = 0
	A.ns.UI.Refresh()
	Sync.Outdated = function()
		asked = asked + 1
		return { newest = "0.1.19", players = {} }
	end
	board:GetScript("OnUpdate")(board, 1)
	check("the footer's tick alone does not go through the roster again", asked == 0 and board.outdated.shown == true, asked)
	Mock.advance(16)
	board:GetScript("OnUpdate")(board, 1)
	check("it does once in a while", asked >= 1, asked)
	check("with everyone up to date there is no notice", not board.outdated.shown)
	Sync.Outdated = real
	A.slash("")
end
OutdatedAddons()

--------------------------------------------------------------------------------
section("Search, filters and roles")
--------------------------------------------------------------------------------

-- A bar above the lists: a search box that finds a name from any part of
-- it, and on the characters a toggle per class, level bounds and a toggle
-- per role. The role is what each player says its character plays, chosen
-- in the Me tab and sent with the profile.
local function Click(button)
	button:GetScript("OnClick")(button)
end

local function SearchAndFilters()
	local ns, L = A.ns, A.ns.L
	check("a name folds to lower case, its accents and ligatures off", ns.Util.Fold("Søren MÉLINÉ d'Œil") == "soren meline d'oeil",
		ns.Util.Fold("Søren MÉLINÉ d'Œil"))

	-- The bar on its own.
	local changes = 0
	local bar = ns.Filters.New(A.env.CreateFrame("Frame"), { search = true, classes = true, levels = true, roles = true }, nil,
		function() changes = changes + 1 end)
	local rows = {
		{ name = "Søren Åsgard", class = "MAGE", level = 34, role = "H" },
		{ name = "Elda Méliné", class = "WARRIOR", level = 12, role = "T" },
		{ name = "Mira Sorel", class = "MAGE", level = 60 },
		{ name = "Tobin Ashe", class = "ROGUE" },
	}
	local function Kept()
		local names = {}
		for index, row in ipairs(bar:Apply(rows)) do names[index] = row.name end
		return table.concat(names, ",")
	end
	check("with nothing set every row shows and no clear button", bar:Apply(rows) == rows and not bar:Active() and bar.reset.shown == false)
	bar.searchBox:SetText("  SOR ")
	check("a part of a name finds it, whatever the case or the accents", Kept() == "Søren Åsgard,Mira Sorel" and changes == 1, Kept())
	bar.searchBox:SetText("meline")
	check("an accent left out still finds the name", Kept() == "Elda Méliné", Kept())
	bar.searchBox:SetText("")
	bar:SetClasses(rows)
	local function ClassButton(classFile)
		for _, button in ipairs(bar.classButtons) do
			if button.classFile == classFile and button.shown then return button end
		end
		return nil
	end
	check("the bar shows one icon per class on the list, by class name", #bar.classButtons == 3 and bar.classButtons[1].classFile == "WARRIOR"
		and bar.classButtons[2].classFile == "MAGE" and bar.classButtons[3].classFile == "ROGUE", bar.classButtons[1].classFile)
	Click(ClassButton("MAGE"))
	check("a class chosen keeps its characters only, marked under its icon", Kept() == "Søren Åsgard,Mira Sorel"
		and ClassButton("MAGE").mark.shown == true and ClassButton("ROGUE").mark.shown == false, Kept())
	Click(ClassButton("ROGUE"))
	check("several classes add up", Kept() == "Søren Åsgard,Mira Sorel,Tobin Ashe", Kept())
	bar.minBox:SetText("30")
	check("a level bound leaves out the lower levels and the levels unknown", Kept() == "Søren Åsgard,Mira Sorel", Kept())
	bar.maxBox:SetText("40")
	check("both bounds keep the levels between them", Kept() == "Søren Åsgard", Kept())
	bar.minBox:SetText("60")
	check("bounds typed the wrong way round are read the right way", Kept() == "Mira Sorel", Kept())
	Click(bar.reset)
	check("the clear button takes every filter off and empties the boxes", not bar:Active() and bar.minBox:GetText() == ""
		and bar.maxBox:GetText() == "" and bar.reset.shown == false and bar:Apply(rows) == rows)
	Click(bar.roleButtons.T)
	check("a role chosen keeps the characters of that role, not those without one, and lights its button",
		Kept() == "Elda Méliné" and bar.roleButtons.T.selected == true and bar.roleButtons.H.selected ~= true and bar.reset.shown == true, Kept())
	Click(bar.roleButtons.H)
	check("several roles add up", Kept() == "Søren Åsgard,Elda Méliné", Kept())
	Click(bar.roleButtons.T)
	Click(bar.roleButtons.H)
	Click(ClassButton("ROGUE"))
	bar:SetClasses({ rows[1], rows[2] })
	check("a class chosen that left the list is dropped rather than hiding everything", not bar:Active() and #bar:Apply(rows) == 4)

	-- The role in the profile: one more field at the end, where versions
	-- before 1.0.1 never look.
	local sample = { name = "Aldric Stormhand", class = "HUNTER", race = "Human", realm = "Ashbringer", playerKey = "a1bf6c73",
		alias = "Aldric", level = 60, baselineHK = 500, lifeHK = 512, version = "1.0.1", role = "H" }
	local line = ns.Records.EncodeProfile(sample)
	check("a profile carries the role as its last field", line == "P1;Aldric Stormhand;HUNTER;Human;Ashbringer;a1bf6c73;Aldric;60;500;512;1.0.1;H", line)
	check("and reads it back, a profile without one or with something else giving none", ns.Records.DecodeProfile(line).role == "H"
		and ns.Records.DecodeProfile("P1;Aldric Stormhand;HUNTER;Human;Ashbringer;a1bf6c73;Aldric;60;500;512;1.0.0").role == nil
		and ns.Records.DecodeProfile("P1;Aldric Stormhand;HUNTER;Human;Ashbringer;a1bf6c73;Aldric;60;500;512;1.0.1;Boss").role == nil)

	-- A member chooses the role of its character in the Me tab.
	local alt
	for _, client in ipairs(Mock.clients) do
		if client.name == "Bryn Ironvale" then alt = client end
	end
	-- One account plays one character at a time.
	if B.online then
		B.logout()
		advance(5)
	end
	if not alt.online then
		alt.login()
		advance(30)
	end
	GainHK(alt)
	advance(10)
	alt.ns.UI.Show()
	alt.ns.UI.SelectTab("me")
	local meTab = alt.ns.UI.Frame().tabFrames.me
	local profilesBefore = SentSince(0, "GUILD", "P")
	Click(meTab.roleButtons.H)
	advance(5)
	check("a role chosen in the Me tab is kept for the character, lit, and goes out with its profile at once",
		alt.ns.Identity.Role() == "H" and alt.db().characters[alt.guid].role == "H" and meTab.roleButtons.H.selected == true
		and meTab.roleButtons.T.selected ~= true and ns.Stats.AuthorInfo(alt.guid).role == "H"
		and SentSince(0, "GUILD", "P") > profilesBefore, tostring(ns.Stats.AuthorInfo(alt.guid).role))
	Click(meTab.roleButtons.H)
	advance(5)
	check("the chosen role clicked again removes it, for the guild too",
		alt.ns.Identity.Role() == nil and meTab.roleButtons.H.selected ~= true and ns.Stats.AuthorInfo(alt.guid).role == nil)
	Click(meTab.roleButtons.T)
	advance(5)
	alt.ns.UI.Hide()

	-- On A's board.
	ns.UI.Show()
	ns.UI.SetPeriod("all")
	ns.UI.SetBucket("all")
	local board = ns.UI.Frame()
	local function Data(view)
		local list = {}
		for index, row in ipairs(Rows(view)) do list[index] = row.row.data end
		return list
	end

	-- Characters: the role column and filter, the search by the player's name.
	ns.UI.SelectTab("characters")
	local characters = board.tabFrames.characters
	local everyone = #Data(characters.view)
	local altRow
	for _, data in ipairs(Data(characters.view)) do
		if data.guid == alt.guid then altRow = data end
	end
	check("the characters ranking says the role of those who chose one", everyone == #ns.Stats.Characters("all", "all") and altRow ~= nil
		and altRow.roleText == L.ROLE_TANK, altRow and altRow.roleText)
	Click(characters.filters.roleButtons.T)
	local tanks = Data(characters.view)
	check("the role filter keeps the characters of that role, and says how many of how many",
		#tanks == 1 and tanks[1].guid == alt.guid and characters.filters.count.shown == true
		and characters.filters.count.text == L.FILTER_COUNT:format(1, everyone), #tanks)
	Click(characters.filters.roleButtons.T)
	local player
	for _, row in ipairs(ns.Stats.Players("all", "all")) do
		for _, character in ipairs(row.characters) do
			if character.guid == alt.guid then player = row end
		end
	end
	local expected = {}
	for _, character in ipairs(player.characters) do
		for _, row in ipairs(ns.Stats.Characters("all", "all")) do
			if row.guid == character.guid then expected[row.guid] = true end
		end
	end
	characters.filters.searchBox:SetText(player.name:upper())
	local hits, others = 0, 0
	for _, data in ipairs(Data(characters.view)) do
		if expected[data.guid] then hits = hits + 1 else others = others + 1 end
	end
	check("a character is found by the name of its player: all of that player's characters show",
		hits == count(expected) and hits >= 2 and others == 0, ("%d of %d, %d others"):format(hits, count(expected), others))
	characters.filters.searchBox:SetText("zzzz")
	check("a search that finds nothing says so, not that nobody killed anyone",
		#Data(characters.view) == 0 and characters.view.empty.shown == true and characters.view.empty.text == L.EMPTY_FILTERED)
	Click(characters.filters.reset)
	check("cleared, the whole ranking is back with its usual empty text", #Data(characters.view) == everyone
		and characters.view.empty.text == L.EMPTY_PLAYERS and characters.filters.searchBox:GetText() == "")
	characters.filters.minBox:SetText("1")
	local levelled = 0
	for _, row in ipairs(ns.Stats.Characters("all", "all")) do
		if type(row.level) == "number" and row.level >= 1 then levelled = levelled + 1 end
	end
	check("the level filter goes by the roster's levels", #Data(characters.view) == levelled, #Data(characters.view))
	Click(characters.filters.reset)

	-- Players: found by the name of any character.
	ns.UI.SelectTab("players")
	local playerList = board.tabFrames.players
	local everyPlayer = ns.Stats.Players("all", "all")
	local target, fragment
	for _, row in ipairs(everyPlayer) do
		for _, character in ipairs(row.characters) do
			local part = ns.Util.Fold(character.name):sub(3, 8)
			if not target and not ns.Util.Fold(row.name):find(part, 1, true) then target, fragment = row, part end
		end
	end
	check("the players tab has a search box and nothing else to filter by", playerList.filters.searchBox ~= nil and playerList.filters.minBox == nil
		and playerList.filters.classStrip == nil and next(playerList.filters.roleButtons) == nil and target ~= nil)
	local matching = 0
	for _, row in ipairs(everyPlayer) do
		local hit = ns.Util.Fold(row.name):find(fragment, 1, true) ~= nil
		for _, character in ipairs(row.characters) do
			if ns.Util.Fold(character.name):find(fragment, 1, true) then hit = true end
		end
		if hit then matching = matching + 1 end
	end
	playerList.filters.searchBox:SetText(fragment:upper())
	local shownTarget = false
	for _, data in ipairs(Data(playerList.view)) do
		if data.key == target.key then shownTarget = true end
	end
	check("a player is found by a part of the name of one of its characters, with its numbers and its rank",
		shownTarget and #Data(playerList.view) == matching and matching < #everyPlayer and Data(playerList.view)[1].rank ~= nil
		and Data(playerList.view)[1].kd ~= nil, ("%s: %d shown, %d expected"):format(fragment, #Data(playerList.view), matching))
	Click(playerList.filters.reset)
	check("cleared, every player is back", #Data(playerList.view) == #everyPlayer)

	-- Hunt: one bar for both boards, name and class; none on the Me tab's.
	ns.UI.SelectTab("hunt")
	local hunt = board.tabFrames.hunt
	local victim = hunt.victimRows[1]
	hunt.filters.searchBox:SetText(ns.Util.Fold(victim.name):sub(1, 5):upper())
	local allMatch = #Data(hunt.victims) >= 1
	for _, data in ipairs(Data(hunt.victims)) do
		if not ns.Util.Fold(data.name):find(ns.Util.Fold(victim.name):sub(1, 5), 1, true) then allMatch = false end
	end
	for _, data in ipairs(Data(hunt.killers)) do
		if not ns.Util.Fold(data.name):find(ns.Util.Fold(victim.name):sub(1, 5), 1, true) then allMatch = false end
	end
	check("the hunt tab finds an enemy by name on both boards, by name and class only", allMatch and #Data(hunt.victims) < #hunt.victimRows
		and hunt.filters.classStrip ~= nil and hunt.filters.minBox == nil and next(hunt.filters.roleButtons) == nil,
		#Data(hunt.victims))
	Click(hunt.filters.reset)
	local withClass
	for _, row in ipairs(hunt.victimRows) do
		if not withClass and row.classFile then withClass = row.classFile end
	end
	local classButton
	for _, button in ipairs(hunt.filters.classButtons) do
		if button.classFile == withClass then classButton = button end
	end
	Click(classButton)
	local sameClass = #Data(hunt.victims) >= 1
	for _, data in ipairs(Data(hunt.victims)) do
		if data.classFile ~= withClass then sameClass = false end
	end
	for _, data in ipairs(Data(hunt.killers)) do
		if data.classFile ~= withClass then sameClass = false end
	end
	check("and keeps the enemies of a class on both boards", sameClass, withClass)
	Click(hunt.filters.reset)
	ns.UI.SelectTab("me")
	check("my own boards on the Me tab have no bar", board.tabFrames.me.boards.filters == nil and board.tabFrames.me.boards.victims ~= nil)
	ns.UI.Hide()
end
SearchAndFilters()

--------------------------------------------------------------------------------
section("Review fixes of 1.0.1")
--------------------------------------------------------------------------------

local function ReviewFixes()
	local ns = A.ns
	local alt
	for _, client in ipairs(Mock.clients) do
		if client.name == "Bryn Ironvale" then alt = client end
	end
	local function PlayerOf(guid)
		for _, row in ipairs(ns.Stats.Players("all", "all")) do
			for _, character in ipairs(row.characters) do
				if character.guid == guid then return row end
			end
		end
		return nil
	end

	-- A player's name is the one its characters stated last: an alt that
	-- has not logged in since still carries the old one.
	local authors = A.db().authors
	local main, other = authors[B.guid], authors[alt.guid]
	local keep = { main.profile.alias, main.lastHello, main.profileAt, other.profile.alias, other.lastHello, other.profileAt }
	local nowAt = Mock.Server()
	main.profile.alias, main.lastHello, main.profileAt = "Old Name", nowAt - 5000, nil
	other.profile.alias, other.lastHello, other.profileAt = "New Name", nowAt - 9000, nowAt - 60
	ns.Stats.Invalidate()
	local first = PlayerOf(B.guid).name
	main.lastHello, other.profileAt = nowAt - 30, nowAt - 60
	ns.Stats.Invalidate()
	local second = PlayerOf(B.guid).name
	other.profile.alias, other.profileAt = nil, nowAt - 10
	ns.Stats.Invalidate()
	local third = PlayerOf(B.guid).name
	check("a player shows under the name its characters stated last, whichever the roster lists first",
		first == "New Name" and second == "Old Name", first .. " / " .. second)
	check("a name taken off on the character heard last is off, whatever an alt still says",
		third ~= "Old Name" and third ~= "New Name", third)
	main.profile.alias, main.lastHello, main.profileAt, other.profile.alias, other.lastHello, other.profileAt = unpack(keep, 1, 6)
	local own = authors[A.guid].profile
	local ownAlias = own.alias
	own.alias = "Stale Name"
	ns.Stats.Invalidate()
	check("my own name is the one set here, whatever my stored profile says", PlayerOf(A.guid).name ~= "Stale Name", PlayerOf(A.guid).name)
	own.alias = ownAlias
	ns.Stats.Invalidate()

	-- A death older than the one before it in the journal (the probe's
	-- backfill) by the same killer is a death of its own, and the feed of
	-- a period is cut to its limit after the period is applied.
	local killer = { kkind = "p", ktail = "6938-00CC00DD", kname = "Vorga Blackmaw", kclass = "ROGUE", krace = "Orc", bucket = "w", mapID = 52 }
	local function Death(t)
		local entry = { type = "D", t = t }
		for key, value in pairs(killer) do entry[key] = value end
		return ns.Records.AppendOwn(entry)
	end
	local lastWeek = ns.Stats.WeekStart(ns.Stats.CurrentWeek()) - 3600
	Death(nowAt - 100)
	local older = Death(lastWeek)
	advance(5)
	local byKiller
	for _, row in ipairs(ns.Stats.Killers("all", "all", { guid = A.guid })) do
		if row.tail == "6938-00CC00DD" then byKiller = row end
	end
	check("a death older than the one before it by the same killer still counts",
		byKiller ~= nil and byKiller.count == 2 and not ns.Stats.AuthorAggregate(A.guid).repeats[older], byKiller and byKiller.count)
	local lastFeed = ns.Stats.Feed(1, "all", "last")
	check("the feed of last week is cut to its limit after the week is taken, not before",
		#ns.Stats.Feed(1, "all") == 1 and ns.Stats.Feed(1, "all")[1].t > lastWeek and #lastFeed == 1 and lastFeed[1].t == lastWeek, #lastFeed)

	-- The feed's time column sorts on the time itself and keeps its order.
	ns.UI.Show()
	ns.UI.SetPeriod("all")
	ns.UI.SetBucket("all")
	ns.UI.SelectTab("guild")
	local view = ns.UI.Frame().tabFrames.guild.view
	local function Ordered(descending)
		local previous
		for _, row in ipairs(Rows(view)) do
			local t = row.row.data.t
			if previous and ((descending and t > previous) or (not descending and t < previous)) then return false end
			previous = t
		end
		return #Rows(view) >= 2
	end
	local newestFirst = Ordered(true)
	Click(view.headers[1])
	local oldestFirst = Ordered(false)
	ns.UI.Refresh()
	check("the feed lists the newest first, its time column sorts on the time, and a refresh keeps the order chosen",
		newestFirst and oldestFirst and Ordered(false) and view.sortField == "t", tostring(view.sortField))
	Click(view.headers[1])
	ns.UI.Hide()

	-- A roster update inside the gap after a rebuild is read when the gap ends.
	ns.Identity.UpdateRoster(true)
	local at = ns.Identity.roster.at
	advance(2)
	A.fire("GUILD_ROSTER_UPDATE")
	local waiting = ns.Identity.roster.at == at and ns.Identity.roster.pending == true
	advance(10)
	check("a roster update that comes too soon after a rebuild is read once the gap is over",
		waiting and ns.Identity.roster.at > at and not ns.Identity.roster.pending, ns.Identity.roster.at - at)

	-- A page whose chunks the queue refuses is not counted as going out.
	local sync = ns.Sync.State()
	local queued = #sync.queue
	for _ = 1, 400 do
		sync.queue[#sync.queue + 1] = { kind = "pad", text = "", channel = "GUILD", priority = 9 }
	end
	local full = A.counter("sync.queueFull")
	A.fire("CHAT_MSG_ADDON", "KBS", ("Q^%s^1"):format(ns.Identity.me.tail), "WHISPER", C.name)
	local refused = A.counter("sync.queueFull") - full
	for index = #sync.queue, 1, -1 do
		if sync.queue[index].kind == "pad" then table.remove(sync.queue, index) end
	end
	check("a page whose chunks the full queue refuses does not stay counted as going out",
		refused >= 1 and ns.Sync.State().outPages == 0 and #sync.queue == queued, ("%d refused, %d out"):format(refused, ns.Sync.State().outPages))

	-- A killing blow on a player of our own faction is no candidate for an HK.
	Mock.AddPlayer(Guid(45), { name = "Perrin Holt", class = "MAGE", race = "Human", faction = "Alliance" })
	local notEnemy = A.counter("detect.killNotEnemy")
	A.fire("PARTY_KILL", A.guid, Guid(45))
	GainHK(A)
	advance(5)
	check("a killing blow on a player of our own faction is not the victim of the HK that comes with it",
		A.counter("detect.killNotEnemy") == notEnemy + 1 and Last(A).type == "K" and Last(A).vname == nil, tostring(Last(A).vname))
end
ReviewFixes()

--------------------------------------------------------------------------------
section("A new week")
--------------------------------------------------------------------------------

-- The week's counts start again at the server's weekly reset. The board
-- says since when the week runs next to its number, each period's button
-- says its dates on hover, and an empty week in a guild that has a history
-- says that the counts started again and where the rest is.
local function NewWeek()
	local ns, L = A.ns, A.ns.L
	local db = A.db()
	local keep = db.weekAnchor
	local week = 7 * 86400
	-- The reset is this very second: everything recorded is last week's or older.
	local reset = Mock.Server()
	db.weekAnchor = reset
	ns.Stats.Invalidate()
	ns.UI.Show()
	ns.UI.SetBucket("all")
	ns.UI.SetPeriod("week")
	ns.UI.SelectTab("players")
	local board = ns.UI.Frame()
	local day = os.date("%A", reset)
	if L.DATE_WEEKDAY_LOWER == "1" then day = day:lower() end
	check("an instant reads as a weekday, a date and a time",
		ns.Theme.DayTime(reset) == L.DATE_DAY_TIME:format(day, os.date("%d/%m", reset), os.date("%H:%M", reset)), ns.Theme.DayTime(reset))
	-- The board shows a reset to the nearest minute: the client's count of
	-- seconds left lands a second short of the hour now and then.
	local function Minute(t) return math.floor((t + 30) / 60) * 60 end
	local began = ns.Theme.DayTime(Minute(reset))
	local newWeek = L.EMPTY_NEW_WEEK:format(began, L.PERIOD_LAST, L.PERIOD_ALL)
	db.weekAnchor = Minute(reset) + 3600 - 1
	check("a reset a second short of the hour reads as the hour", ns.UI.PeriodText("week") == L.PERIOD_SINCE:format(ns.Theme.DayTime(Minute(reset) + 3600 - 7 * 86400)),
		ns.UI.PeriodText("week"))
	db.weekAnchor = reset
	local list = board.tabFrames.players.view
	check("a week that just began is empty, and says when the counts started again and where the rest is",
		#Rows(list) == 0 and list.empty.shown == true and list.empty.text == newWeek, list.empty.text)
	check("the header says since when the week runs", board.band.since.text == L.PERIOD_SINCE:format(began), board.band.since.text)
	local said = true
	for _, key in ipairs({ "characters", "guild", "me" }) do
		ns.UI.SelectTab(key)
		if board.tabFrames[key].view.empty.text ~= newWeek then said = false end
	end
	ns.UI.SelectTab("hunt")
	local hunt = board.tabFrames.hunt
	check("every list says it: characters, guild feed, my characters, the hunting boards and my own",
		said and hunt.victims.empty.text == newWeek and hunt.killers.empty.text == newWeek
		and board.tabFrames.me.boards.victims.empty.text == newWeek and board.tabFrames.me.boards.killers.empty.text == newWeek)

	-- On hover of the period buttons.
	local function TipOf(button)
		button:GetScript("OnEnter")(button)
		local lines = A.env.GameTooltip.tooltipLines or {}
		return lines[1], lines[2]
	end
	local title, body = TipOf(board.band.periods.buttons[1])
	check("the week's button says on hover since when it runs and when it starts again",
		title == L.PERIOD_WEEK and body == L.PERIOD_WEEK_TIP:format(began, ns.Theme.DayTime(Minute(reset + week))), body)
	ns.UI.SelectTab("players")
	ns.UI.SetPeriod("last")
	title, body = TipOf(board.band.periods.buttons[2])
	check("last week holds what came before the reset, with its dates in the header and on hover",
		#Rows(list) >= 1 and board.band.since.text == L.PERIOD_RANGE:format(ns.Theme.Day(Minute(reset - week)), ns.Theme.Day(Minute(reset)))
		and title == L.PERIOD_LAST and body == L.PERIOD_LAST_TIP:format(ns.Theme.DayTime(Minute(reset - week)), began),
		board.band.since.text)
	ns.UI.SetPeriod("all")
	title, body = TipOf(board.band.periods.buttons[3])
	check("all time has no dates", board.band.since.text == "" and title == L.PERIOD_ALL and body == L.PERIOD_ALL_TIP, board.band.since.text)

	-- A guild with nothing at all, or another period, keeps the plain words.
	local realGuild = ns.Stats.Guild
	ns.Stats.Guild = function() return { kills = 0, deaths = 0 } end
	local plain = ns.UI.EmptyText(L.EMPTY_PLAYERS, "week")
	ns.Stats.Guild = realGuild
	check("a guild with no history keeps the plain words, as does any other period",
		plain == L.EMPTY_PLAYERS and ns.UI.EmptyText(L.EMPTY_PLAYERS, "last") == L.EMPTY_PLAYERS
		and ns.UI.EmptyText(L.EMPTY_FEED, "week") == newWeek)
	db.weekAnchor = keep
	ns.Stats.Invalidate()
	ns.UI.SetPeriod("week")
	ns.UI.Hide()

	-- The count of a full bar: "2 of 4" when it fits between the last
	-- toggle and the clear button, else "2/4", else nothing, never a text
	-- that runs under a button.
	local bar = ns.Filters.New(A.env.CreateFrame("Frame"), { search = true, classes = true, levels = true, roles = true }, nil, nil)
	bar.searchBox:SetText("a")
	bar:SetCount(2, 4)
	local unmeasured = bar.count.text
	bar.lastPart.GetRight = function() return 700 end
	bar.count.GetStringWidth = function(self) return #self.text * 6 end
	local forms = {}
	for _, left in ipairs({ 760, 740, 720 }) do
		bar.reset.GetLeft = function() return left end
		bar:SetCount(2, 4)
		forms[#forms + 1] = bar.count.text
	end
	check("the count shortens, then goes, when the room before the clear button runs out",
		unmeasured == L.FILTER_COUNT:format(2, 4) and forms[1] == L.FILTER_COUNT:format(2, 4)
		and forms[2] == L.FILTER_COUNT_SHORT:format(2, 4) and forms[3] == "" and bar.count.shown == true,
		table.concat(forms, " | "))
end
NewWeek()

--------------------------------------------------------------------------------
section("The demo tour")
--------------------------------------------------------------------------------

-- demo/KBSDemo plays a scripted tour of the board for screen recordings. It
-- drives the board through its global frame and its widgets' own fields, so
-- it breaks when they change: it runs here, on a fake client, with the rest.
local function DemoTour()
	local client
	for _, candidate in ipairs(Mock.clients) do
		if candidate.name == "Bryn Ironvale" then client = candidate end
	end
	local chunk = assert(loadfile("demo/KBSDemo/KBSDemo.lua"))
	setfenv(chunk, client.env)
	chunk("KBSDemo", {})
	local function State()
		local settings = client.db().settings
		return ("alias=%s role=%s tab=%s period=%s bucket=%s"):format(tostring(settings.alias),
			tostring(client.db().characters[client.guid].role), tostring(settings.tab), tostring(settings.period or "week"),
			tostring(settings.bucket or "all"))
	end
	local function Has(trace, needle)
		for _, line in ipairs(trace) do
			if line:find(needle, 1, true) then return true end
		end
		return false
	end
	local function RowsSaid(trace, scene)
		for _, line in ipairs(trace) do
			local rows = line:match("^scene " .. scene .. ": (%d+) ")
			if rows then return tonumber(rows) end
		end
		return nil
	end
	-- Plays a command to its end and says what the tour traced, what went
	-- wrong, and the roles and display names the character went through.
	local function Play(command)
		client.env.SlashCmdList.KBSDEMO(command)
		local roles, names = {}, {}
		for _ = 1, 3200 do
			advance(0.1)
			roles[tostring(client.db().characters[client.guid].role)] = true
			names[tostring(client.db().settings.alias)] = true
			if Has((client.env.KBSDemoDB or {}).trace or {}, "stopped:") then break end
		end
		advance(3)
		local db = client.env.KBSDemoDB or {}
		return db.trace or {}, db.errors or {}, roles, names
	end
	local initial = State()
	local trace, errors, roles, names = Play("")
	local scenes = 0
	for index = 1, 6 do
		if Has(trace, "scene " .. index .. " starts") then scenes = scenes + 1 end
	end
	check("the demo tour plays its six scenes to the end without an error",
		scenes == 6 and #errors == 0 and Has(trace, "stopped: end"), errors[1] or table.concat(trace, " | "))
	check("it finds a player by one of its alts, narrows the ranking and finds an enemy, with no name written in it",
		(RowsSaid(trace, 1) or 0) >= 1 and RowsSaid(trace, 2) ~= nil and (RowsSaid(trace, 5) or 0) >= 1 and Has(trace, "scene 4: another name to take"),
		table.concat(trace, " | "))
	local idle = true
	local board = client.ns.UI.Frame()
	for _, key in ipairs({ "players", "characters", "hunt" }) do
		if board.tabFrames[key].filters:Active() then idle = false end
	end
	check("it goes through the roles and another display name, then leaves the character, the tab, the period and the bars as they were",
		count(roles) >= 3 and count(names) >= 2 and State() == initial and idle, State() .. " / " .. initial)
	trace, errors = Play("3")
	check("a scene can be played alone", Has(trace, "scene 3 starts") and not Has(trace, "scene 1 starts")
		and not Has(trace, "scene 4 starts") and #errors == 0 and State() == initial, errors[1] or table.concat(trace, " | "))
	trace, errors = Play("1 player=ZZZZ")
	check("the command can say what the search types, kept for the next time on this machine",
		RowsSaid(trace, 1) == 0 and client.env.KBSDemoDB.config.player == "zzzz" and #errors == 0, table.concat(trace, " | "))
	trace, errors = Play("1 player=")
	check("an empty text gives the choice back to the tour", (RowsSaid(trace, 1) or 0) >= 1 and client.env.KBSDemoDB.config.player == nil
		and #errors == 0 and State() == initial, table.concat(trace, " | "))
end
DemoTour()

--------------------------------------------------------------------------------
section("Nothing went wrong anywhere")
--------------------------------------------------------------------------------

for _, client in ipairs(Mock.clients) do
	if client.online then
		local errors = client.db().errors
		local first = errors[1] and (tostring(errors[1].where) .. ": " .. tostring(errors[1].message))
		check(client.name .. ": no error recorded", #errors == 0, first)
		local okSave, message = pcall(Serialize, client.db())
		check(client.name .. ": SavedVariables clean", okSave, message)
	end
end
-- 25000 since 1.0.0: one more member (an alt) and the time each member was
-- last heard from add about 700 bytes. 26000 since 1.0.1: when each member
-- last stated its profile, about 250 bytes.
check("the saved data stays small", #Serialize(A.db()) < 26000, #Serialize(A.db()))
check("records are stored as strings, not tables", (function()
	for _, entry in pairs(A.db().authors[Guid(1)].log) do
		if type(entry) ~= "string" then return false end
	end
	return true
end)())
check("the counters count", count(A.db().counters) > 5)

Mock.finish()
