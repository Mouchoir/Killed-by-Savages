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
	type = "K", seq = 7, t = 1794009143, bucket = "w", how = "kb", vtail = "6938-001DF7A9", vname = "Rikkoshet Greyjoy",
	vclass = "WARRIOR", vrace = "Orc", vlevel = 16, mapID = 52, x = 0.4321, y = 0.6789, guild = "Savages", lifeHK = 12,
}
local text = Records.Encode(kill)
check("a kill encodes to one line", text == "K1;7;1794009143;w;kb;6938-001DF7A9;Rikkoshet Greyjoy;WARRIOR;Orc;16;52;0.4321;0.6789;Savages;12", text)
local back = Records.Decode(text)
check("and decodes back", back.type == "K" and back.seq == 7 and back.vname == "Rikkoshet Greyjoy" and back.x == 0.4321 and back.lifeHK == 12)
check("decoding is cached", Records.Decode(text) == back)
check("fields with separators are flattened", Records.Encode({ type = "K", seq = 1, t = 1, bucket = "w", how = "unk",
	guild = "A;B^C", lifeHK = 1 }):find("A B C", 1, true) ~= nil)
local death = Records.Decode(Records.EncodeDeath({ seq = 8, t = 1794009577, bucket = "w", ktail = "6938-00AA00BB",
	kname = "Walter Zornickel", kclass = "HUNTER", krace = "Orc", kkind = "p", spell = "Tir des arcanes", mapID = 52, x = 0.1, y = 0.2, lifeHK = 12 }))
check("a death decodes", death.type == "D" and death.kname == "Walter Zornickel" and death.kkind == "p" and death.spell == "Tir des arcanes")
local match = Records.Decode("M1;9;1794010000;1459;7;19")
check("a match decodes with its bucket", match.type == "M" and match.bucket == "b" and match.hk == 7 and match.lifeHK == 19)
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
	Records.Decode("M1;4;130;1459;3;505"),
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

local function EnterBG(client)
	local st = client.state
	st.bucket, st.zone, st.mapID = "bg", "Vallée d'Alterac", 1459
	st.secretIdentity, st.secretStats, st.chatLocked = true, true, true
	client.fire("PLAYER_ENTERING_WORLD", false, false)
end

local function LeaveBG(client)
	local st = client.state
	st.bucket, st.zone, st.mapID = "world", "Contreforts de Hautebrande", 1424
	st.secretIdentity, st.secretStats, st.chatLocked = false, false, false
	client.fire("PLAYER_ENTERING_WORLD", false, false)
end

before = #Journal(A)
EnterBG(A)
A.fire("PARTY_KILL", SECRET, SECRET)
A.fire("UNIT_DIED", SECRET)
A.state.lifetime = A.state.lifetime + 3
A.fire("PLAYER_PVP_KILLS_CHANGED", "player")
advance(10)
check("nothing is recorded inside the battleground", #Journal(A) == before and A.ns.Detect.InBattleground() == true)
LeaveBG(A)
advance(1)
record = Last(A)
check("leaving records the HKs the battleground gave", record.type == "M" and record.hk == 3 and record.bucket == "b", record and record.hk)
check("with the counter after the match", record.lifeHK == A.state.lifetime and a.characters[Guid(1)].lifeHK == A.state.lifetime)
check("the chain still holds across the match", Records.CheckChain(Journal(A)) == true)

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
