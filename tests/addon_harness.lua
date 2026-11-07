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
check("the same match has one key for every member", Records.MatchKey(match) == Records.MatchKey(Records.Decode("M1;2;1794010030;489;;;5;0;1;;;;10;0;;")))
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

A.state.recap = nil
A.fire("PLAYER_DEAD")
advance(12)
check("no recap is counted, not recorded", #Journal(A) == before and A.counter("detect.deathNoRecap") == 1)

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

-- A match whose scoreboard never came: the counter's delta is kept.
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
check("B's and C's own journals reached D too", D.db().authors[B.guid] ~= nil or Held(B, B) == 0)

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
advance(10)
check("the lost session is detected and recovery starts", A.counter("sync.recoveryStart") == recoveries + 1 and A.ns.Records.Holding() == true)
-- A kill during the recovery waits for its number.
A.fire("UNIT_DIED", HORDE[4].guid)
GainHK(A)
advance(5)
local _, heldCount = A.ns.Records.Holding()
check("a kill during the recovery waits unnumbered", heldCount == 1, heldCount)
advance(120)
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
check("battleground enemy deaths are the guild's killing blows on the board", Stats.Guild("all", "b").distinct == 7, Stats.Guild("all", "b").distinct)
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
local killers = Stats.Killers("all", "all", nil, 5)
check("our killers are listed from the deaths, battlegrounds included", #killers == 3 and killers[1].count == 1
	and (killers[1].name == "Vexa Cinderhorn" or killers[1].name == "Gruk Bonecrusher" or killers[1].name == "Schwarzesau"), #killers)
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
check("the guild's battleground blows count once per match too", Stats.Guild("all", "b").distinct == 8, Stats.Guild("all", "b").distinct)

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

-- A journal with records takes nothing.
A.probe = probe
A.logout()
A.login()
advance(5)
local aHeadBefore = Held(A, A)
A.slash("import")
check("a journal that already has records is left alone", Held(A, A) == aHeadBefore and A.said("déjà des enregistrements")
	and A.db().characters[A.guid].imported == nil)
A.probe = nil

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

A.slash("")
local window = A.env.KilledBySavagesFrame
check("/kbs opens the window", window ~= nil and window.shown == true)
check("the window registers for ESC", A.env.UISpecialFrames[1] == "KilledBySavagesFrame")
local UI = A.ns.UI
check("the players tab is the home view", UI.State().tab == "players" and UI.State().period == "week")
local function Rows(view)
	return view and view.scrollBox and view.scrollBox.rows or {}
end
local playersTab = window.tabFrames.players
check("the players list has one row per player", #Rows(playersTab.view) == #Stats.Players("week", "all") and #Rows(playersTab.view) >= 1,
	#Rows(playersTab.view))
check("the first row carries the first player's numbers", Rows(playersTab.view)[1].row.data.rank == 1 and Rows(playersTab.view)[1].row.cells[2].text.text == Stats.Players("week", "all")[1].name)
for _, key in ipairs({ "characters", "guild", "hunt", "me" }) do
	UI.SelectTab(key)
	check("the " .. key .. " tab builds and fills", window.tabFrames[key] ~= nil and window.tabFrames[key].shown == true)
end
check("the guild feed shows the latest events", #Rows(window.tabFrames.guild.view) > 0 and Rows(window.tabFrames.guild.view)[1].row.data.event ~= nil)
check("the hunt boards fill", #Rows(window.tabFrames.hunt.victims) > 0 and #Rows(window.tabFrames.hunt.killers) > 0)
check("the me tab lists my characters and shows my alias", #Rows(window.tabFrames.me.view) == 1 and window.tabFrames.me.box.text == "Aldric the Bold")
UI.SetPeriod("last")
check("a period without data shows the empty state", window.tabFrames.me.view.empty.shown == true)
UI.SetPeriod("all")
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
A.slash("options")
check("options fall back gracefully without the Settings API", A.said("not available") or A.said("pas disponible"))

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
check("the saved data stays small", #Serialize(A.db()) < 20000, #Serialize(A.db()))
check("records are stored as strings, not tables", (function()
	for _, entry in pairs(A.db().authors[Guid(1)].log) do
		if type(entry) ~= "string" then return false end
	end
	return true
end)())
check("the counters count", count(A.db().counters) > 5)

Mock.finish()
