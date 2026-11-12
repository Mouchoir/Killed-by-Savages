local _, ns = ...

--------------------------------------------------------------------------------
-- Guild sync
--
-- Every member ends up holding every member's journal, through hidden addon
-- messages (prefix KBS, 255 bytes each):
--
--   GUILD    H  hello: who I am, my head and lifetime count
--            P  my profile
--            I  inventory: the head and count I hold for every author, once per login
--            A  advance: the authors where I am ahead of a hello or inventory I just saw
--            R  a record of mine, live
--            V  my version, answering a hello from an older one
--   WHISPER  Q  a request for one page (200 seqs) of an author's journal
--            B  a page, deflated, in chunks
--
-- Live records are accepted only from their author. History pages can come
-- from any holder; they must pass validation and the lifetime-HK chain, and
-- stay provisional above the head the author last announced itself. The
-- server takes about one addon message per second per player, no bursts,
-- so everything goes through one paced queue. Custom channels refuse addon
-- messages on Forever; whispers to a bare "First Last" cross realms.
--------------------------------------------------------------------------------

local Util = ns.Util
local L = ns.L
local Clean, Now = Util.Clean, Util.Now
local Records = ns.Records
local Identity = ns.Identity

local Sync = {}
ns.Sync = Sync

local PREFIX = "KBS"
local PROTOCOL = 1
local PAGE = Records.PAGE
local CHUNK = 200                 -- data bytes per page chunk
local SEND_GAP = 1.2              -- seconds between two messages
local LOCKDOWN_WAIT = 15
local THROTTLE_WAIT = 3
local QUEUE_CAP = 400
local HELLO_DELAY_MIN, HELLO_DELAY_MAX = 8, 15
local HELLO_READY_WAIT = 5        -- more to wait, at a time, for the guild and its roster to be known
local HELLO_READY_TRIES = 12      -- a minute of that at most
local HELLO_MIN_GAP = 600         -- never two hellos within this, per character
local HELLO_PERIOD = 1200         -- a hello this often when the head moved
local ADVANCE_MIN, ADVANCE_MAX = 1, 8
local INVENTORY_WAIT = 8          -- after a hello, how long an inventory may take to follow
local LIST_BYTES = 230            -- inventory and advance payload per message
local REQUEST_TIMEOUT = 45        -- before the first chunk of a page
local CHUNK_TIMEOUT = 1.5         -- per chunk once the total is known
local MAX_HOLDERS = 3             -- pages requested in parallel
local OUT_PAGES_CAP = 3           -- pages waiting to go out
local OUT_PAGE_MAX_AGE = 300
local PARTIAL_MAX_AGE = 120
local RECOVERY_WAIT = 120
local ONLINE_WINDOW = 1800        -- a hello this recent means the author is around
local BUSY_WAIT = 20              -- before asking again a holder that said it was busy
local FAIL_RETRY = 300            -- before a holder that failed us gets another chance
local GONE_WINDOW = 120           -- no whisper to a member the server called absent, unless it speaks again
local NOT_FOUND_WINDOW = 15       -- a "not playing" answer this soon after our whisper is about it
local PRESENCE_PERIOD = 600       -- between presence messages: who is here, on which version
local PRESENCE_FIRST_MIN, PRESENCE_FIRST_MAX = 60, 600 -- the first one, spread so logins do not line up

local LibDeflate = LibStub and LibStub("LibDeflate", true)

-- Live state (not saved)
local queue = {}                  -- outgoing messages, by priority then order
local pumping = false
local peers = {}                  -- canon name -> last hello
local holders = {}                -- author tail -> { [holder canon] = { head, count, at } }
local seenHead = {}               -- author tail -> highest head announced by anyone, since my hello
local advancePending = {}         -- author tail -> true while an advance line waits
local requests = {}               -- "tail:page" -> in-flight request
local partial = {}                -- "tail:page" -> chunks received so far
local failedBy = {}               -- author tail -> { [holder canon] = when it failed us }
local busyUntil = {}              -- holder canon -> when it may be asked again
local whispered = {}              -- member canon -> when we last whispered it
local gone = {}                   -- member canon -> when the server said nobody by that name was playing
local heard = {}                  -- member canon -> when any addon message of theirs last came in
local presence = {}               -- member canon -> { version, playerKey, at } from their presence messages
local outPages = 0
local inventorySent = false
local recovery                    -- { from, to, until } while a crash is being recovered
local lastHeadAnnounced
local helloDueAt                  -- when the login hello goes out, until it does
local pagesIn = 0                 -- pages stored this session
local lastPageAt
local heldAtLogin                 -- other journals held when this session began
local firstPagesSaid = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function Me()
	return Identity.me
end

local function GuidOf(tail)
	return "Player-" .. tail
end

local function Char()
	return ns.Db.Character(Me().guid)
end

local function ResultName(code)
	if code == nil then return "nil" end
	if code == Util.SECRET then return "secret" end
	if type(code) == "boolean" then return code and "Success" or "false" end
	local enum = Enum and Enum.SendAddonMessageResult
	if type(enum) ~= "table" and code == 0 then return "Success" end
	return Util.EnumName(enum, code)
end

local function ChatBlocked()
	if C_ChatInfo and Util.Get(C_ChatInfo.InChatMessagingLockdown) == true then return true end
	local types = Enum and Enum.AddOnRestrictionType
	if C_RestrictedActions and type(types) == "table" and types.Chat ~= nil then
		if Util.Get(C_RestrictedActions.IsAddOnRestrictionActive, types.Chat) == true then return true end
	end
	return false
end

local function Jitter(low, high)
	return low + math.random() * (high - low)
end

local function PageOf(seq)
	return math.floor((seq - 1) / PAGE) + 1
end

local function PageRange(page)
	return (page - 1) * PAGE + 1, page * PAGE
end

local function IsAuthorOnline(tail)
	local member = Identity.MemberByTail(tail)
	if member and member.online then return true end
	for _, peer in pairs(peers) do
		if peer.tail == tail and Now() - peer.at < ONLINE_WINDOW then return true end
	end
	return false
end

-- Whether a member can take a whisper: the server did not answer lately
-- that nobody by that name was playing, or the member spoke to us since.
-- Any message of theirs counts, not only a hello: back within ten minutes
-- of its last one, a member does not say it again.
-- The roster's online flag is not trusted here: it lags behind logins by
-- up to a roster rebuild, while the server's answer is immediate and sure.
local function MemberAround(canon)
	if not canon then return false end
	local goneAt = gone[canon]
	if not goneAt or Now() - goneAt >= GONE_WINDOW then return true end
	local heardAt = heard[canon]
	return heardAt ~= nil and heardAt > goneAt
end

-- The holder's "First Last" name of an author tail: its roster entry.
local function NameOfTail(tail)
	local member = Identity.MemberByTail(tail)
	return member and member.name or nil
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

function Sync.SendRaw(text, channel, target)
	if not (C_ChatInfo and Util.Fn(C_ChatInfo.SendAddonMessage)) then return "missing" end
	local ok, code = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, channel, target)
	if not ok then return "error" end
	return ResultName(Util.Safe(code))
end

local function Pump()
	local item = queue[1]
	if not item then
		pumping = false
		return
	end
	if ChatBlocked() then
		ns.Count("sync.wait.blocked")
		Util.After(LOCKDOWN_WAIT, "pump", Pump)
		return
	end
	if item.expires and Now() > item.expires then
		table.remove(queue, 1)
		if item.onDrop then item.onDrop() end
		ns.Count("sync.expired")
		Util.After(0.1, "pump", Pump)
		return
	end
	if item.skip and item.skip() then
		table.remove(queue, 1)
		ns.Count("sync.skipped." .. item.kind)
		Util.After(0.1, "pump", Pump)
		return
	end
	if item.channel == "WHISPER" and not MemberAround(Identity.Canon(item.target)) then
		table.remove(queue, 1)
		if item.onDrop then item.onDrop() end
		ns.Count("sync.dropOffline")
		Util.After(0.1, "pump", Pump)
		return
	end
	local result = Sync.SendRaw(item.text, item.channel, item.target)
	ns.Count("sync.out." .. item.kind .. "." .. result)
	if result == "AddonMessageThrottle" or result == "ChannelThrottle" then
		Util.After(THROTTLE_WAIT, "pump", Pump)
		return
	end
	if item.channel == "WHISPER" and result == "Success" then whispered[Identity.Canon(item.target)] = Now() end
	table.remove(queue, 1)
	if item.onSent then item.onSent(result) end
	Util.After(SEND_GAP, "pump", Pump)
end

-- priority: 1 live and hellos, 2 requests, 3 page chunks. Items of equal
-- priority keep their order.
local function Enqueue(item)
	if #queue >= QUEUE_CAP then
		ns.Count("sync.queueFull")
		return false
	end
	local position = #queue + 1
	for index = 1, #queue do
		if queue[index].priority > item.priority then
			position = index
			break
		end
	end
	table.insert(queue, position, item)
	if not pumping then
		pumping = true
		Util.After(0.2, "pump", Pump)
	end
	return true
end

local function SendGuild(kind, text, priority)
	if #text > 255 then
		ns.Count("sync.tooLong." .. kind)
		return false
	end
	return Enqueue({ kind = kind, text = text, channel = "GUILD", priority = priority or 1 })
end

-- A word to the guild from another module (the rule on ranks).
function Sync.Say(kind, text, priority)
	if not Identity.InGuild() then return false end
	return SendGuild(kind, text, priority)
end

local function SendWhisper(kind, text, target, priority, expires, onSent, onDrop)
	if #text > 255 then
		ns.Count("sync.tooLong." .. kind)
		return false
	end
	return Enqueue({
		kind = kind, text = text, channel = "WHISPER", target = target, priority = priority or 2,
		expires = expires, onSent = onSent, onDrop = onDrop,
	})
end

--------------------------------------------------------------------------------
-- Hello, profile, inventory, advance
--------------------------------------------------------------------------------

local function OwnHead()
	local author = ns.db.authors[Me().guid]
	return author and author.head or 0
end

-- Every journal held, our own included, as an inventory lists them.
local function HeldEntries()
	local entries = {}
	for guid, author in pairs(ns.db.authors) do
		local tail = Util.Tail(guid)
		if tail and (author.head or 0) > 0 then
			local own = ns.db.characters[guid]
			entries[#entries + 1] = {
				tail = tail, head = author.head, count = author.count or 0,
				lifeHK = author.own and own and own.lifeHK or nil,
			}
		end
	end
	table.sort(entries, function(a, b) return a.tail < b.tail end)
	return entries
end

function Sync.SendHello(reason)
	local me = Me()
	if not Identity.InGuild() or not me.tail then return false end
	local char = Char()
	helloDueAt = nil
	-- A /reload soon after a hello says nothing new, unless the addon was
	-- updated in between: the guild hears of the new version at once. A
	-- member that holds nothing says hello every time: it has no inventory
	-- to send, and with no hello either it would log in without a word, so
	-- that no holder would tell it what there is to ask for.
	if reason ~= "recovery" and reason ~= "import" and char.helloVersion == ns.VERSION
		and Now() - (char.lastHello or 0) < HELLO_MIN_GAP and #HeldEntries() > 0 then
		ns.Count("sync.helloSkipped")
		ns.Fire("SyncChanged")
		return false
	end
	char.lastHello = Now()
	char.helloVersion = ns.VERSION
	lastHeadAnnounced = OwnHead()
	seenHead = {}
	local lifeHK = char.lifeHK or 0
	SendGuild("H", ("H^%d^%s^%s^%d^%d^%s"):format(PROTOCOL, Clean(ns.VERSION), me.tail, lastHeadAnnounced, lifeHK,
		Clean(me.playerKey or "")))
	local profile = Records.OwnProfile()
	SendGuild("P", ("P^%s^%s"):format(me.tail, Records.EncodeProfile(profile)))
	ns.Count("sync.hello." .. tostring(reason))
	ns.Fire("SyncChanged")
	return true
end

-- Lines "tail=head/count" packed into messages of a kind (I or A); our own
-- characters add their lifetime count, so the line also confirms them.
local function SendList(kind, entries)
	local text = ""
	local sent = 0
	for _, entry in ipairs(entries) do
		local line = ("%s=%d/%d"):format(entry.tail, entry.head, entry.count)
		if entry.lifeHK then line = line .. "/" .. entry.lifeHK end
		if #text + #line + 1 > LIST_BYTES then
			SendGuild(kind, kind .. "^" .. text, 2)
			sent = sent + 1
			text = ""
		end
		text = text .. (text == "" and "" or ",") .. line
	end
	if text ~= "" then
		SendGuild(kind, kind .. "^" .. text, 2)
		sent = sent + 1
	end
	return sent
end

-- Who is here and on which version, now and then: a member who logged in
-- after our hello learns it, and hellos only go out at login and when the
-- journal grows. Clients before 1.0.0 ignore it.
function Sync.SendPresence()
	local me = Me()
	if not Identity.InGuild() or not me.tail then return false end
	SendGuild("O", ("O^%s^%s"):format(Clean(ns.VERSION), Clean(me.playerKey or "")), 2)
	ns.Count("sync.presence")
	return true
end

function Sync.SendInventory()
	if not Identity.InGuild() or inventorySent then return 0 end
	inventorySent = true
	local sent = SendList("I", HeldEntries())
	ns.Count("sync.inventory", sent)
	return sent
end

-- Answers a hello or an inventory that is behind us: after a random pause,
-- the authors where we hold more, unless someone announced as much since.
local function ScheduleAdvance(entries)
	local scheduledAt = Now()
	local pendingNow = {}
	for _, entry in ipairs(entries) do
		if not advancePending[entry.tail] then
			advancePending[entry.tail] = true
			pendingNow[#pendingNow + 1] = entry.tail
		end
	end
	if #pendingNow == 0 then return end
	Util.After(Jitter(ADVANCE_MIN, ADVANCE_MAX), "advance", function()
		local list = {}
		for _, tail in ipairs(pendingNow) do
			advancePending[tail] = nil
			local author = ns.db.authors[GuidOf(tail)]
			local seen = seenHead[tail]
			if author and (author.head or 0) > 0 and not (seen and seen.at >= scheduledAt and seen.head >= author.head) then
				list[#list + 1] = { tail = tail, head = author.head, count = author.count or 0 }
			else
				ns.Count("sync.advanceSuppressed")
			end
		end
		if #list > 0 then
			ns.Count("sync.advance", SendList("A", list))
		end
	end)
end

--------------------------------------------------------------------------------
-- Newer versions
--------------------------------------------------------------------------------

-- Hellos and profiles state the sender's version. A member who meets a newer
-- release than its own is told in the chat, once per session and version,
-- and by a dialog on the board (UI/Window.lua), unless they asked not to be
-- reminded: of that release, or of any (settings.updateSkip, .updates). A
-- hello from an older version gets ours back (V) after a random pause, unless
-- someone states as new a version first: a member who logs in after everyone
-- who updated still hears of it. At login the profiles held tell it too,
-- when nobody newer is around. Only plain releases are announced:
-- scripts\dev.ps1 deploys "X.Y.Z-dev", which never is.
local VERSION_ANSWER_MIN, VERSION_ANSWER_MAX = 2, 12
local VERSION_SCAN_DELAY = 10            -- after login, before the profiles held are read
local VERSION_TELLS_SINCE = { 0, 1, 15 } -- the first version that tells its player

local versionTold                        -- the newest version the chat was told of, this session
local versionAnswerAt                    -- when we chose to answer, while the answer waits
local versionStatedAt = -math.huge       -- when someone last said to the guild a release as new as ours

-- The numbers of a version. Strict, it takes a plain release only: the text
-- goes to the chat, so a dev build or anything forged is left out.
local function Numbers(version, strict)
	if type(version) ~= "string" or #version > 20 then return nil end
	local major, minor, patch = version:match(strict and "^(%d+)%.(%d+)%.(%d+)$" or "^(%d+)%.(%d+)%.(%d+)")
	if not major then return nil end
	return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function Newer(a, b)
	for index = 1, 3 do
		if a[index] ~= b[index] then return a[index] > b[index] end
	end
	return false
end

-- Our own numbers, a dev build's included; nothing when the client could
-- not say (Init falls back to 0.0.0).
local function OwnNumbers()
	local own = Numbers(ns.VERSION)
	if not own or (own[1] == 0 and own[2] == 0 and own[3] == 0) then return nil end
	return own
end

-- Whether the player wants to be reminded of this newer release: not when
-- the reminders are off, nor of the one release they set aside.
function Sync.Reminds(version)
	local settings = ns.db.settings
	return settings.updates ~= false and settings.updateSkip ~= version
end

-- Someone runs this version. Public: it was said on the guild channel, so
-- every member online heard it too. False when it is no plain release.
local function Heard(version, public)
	local theirs, own = Numbers(version, true), OwnNumbers()
	if not theirs then return false end
	if not own then return true end
	if public and not Newer(own, theirs) then versionStatedAt = Util.Clock() end
	local told = Numbers(versionTold, true)
	if Newer(theirs, own) and not (told and not Newer(theirs, told)) then
		versionTold = version
		ns.Count("sync.versionTold")
		if Sync.Reminds(version) then ns.Print(L.UPDATE_AVAILABLE:format(version)) end
		ns.Fire("NewerVersion", version)
	end
	return true
end

-- A hello from a member whose version is older than ours and tells its
-- player: our version, after a pause, unless someone says one as new
-- first. One answer covers every hello that came in meanwhile. A dev build
-- answers nothing: its version is not out.
local function AnswerVersion(theirs)
	local own = Numbers(ns.VERSION, true)
	if not theirs or not own or versionAnswerAt then return end
	if not Newer(own, theirs) or Newer(VERSION_TELLS_SINCE, theirs) then return end
	local chosenAt = Util.Clock()
	versionAnswerAt = chosenAt
	local function Said() return versionStatedAt >= chosenAt end
	Util.After(Jitter(VERSION_ANSWER_MIN, VERSION_ANSWER_MAX), "version-answer", function()
		versionAnswerAt = nil
		if Said() then
			ns.Count("sync.versionAnswerSuppressed")
			return
		end
		Enqueue({ kind = "V", text = "V^" .. ns.VERSION, channel = "GUILD", priority = 2, skip = Said })
		ns.Count("sync.versionAnswer")
	end)
end

-- At login, the newest release among the profiles held: a member who
-- updated may be offline now.
local function ScanProfiles()
	local best, bestNumbers
	for _, author in pairs(ns.db.authors) do
		local version = not author.own and author.profile and author.profile.version
		local numbers = Numbers(version, true)
		if numbers and (not bestNumbers or Newer(numbers, bestNumbers)) then best, bestNumbers = version, numbers end
	end
	if best then Heard(best, false) end
end

-- The newer release heard of this session, if any: /kbs status and the
-- Options tab's version line say it whatever the reminders.
function Sync.NewerVersion()
	return versionTold
end

-- The same, only while the player wants to be reminded of it: for the
-- board's dialog and the minimap button.
function Sync.Reminder()
	if versionTold and Sync.Reminds(versionTold) then return versionTold end
	return nil
end

-- No more reminder of this release; the next one is announced.
function Sync.SkipVersion(version)
	ns.db.settings.updateSkip = version
end

-- Reminders on or off. Asked for again, they come for every release, the
-- one set aside included.
function Sync.SetReminders(on)
	local settings = ns.db.settings
	settings.updates = on and true or false
	if on then settings.updateSkip = nil end
	ns.Fire("SettingsChanged")
end

-- The newest release anyone runs, ours included: what up to date means.
local function NewestRelease()
	local best, bestNumbers
	local function Consider(version)
		local numbers = Numbers(version, true)
		if numbers and (not bestNumbers or Newer(numbers, bestNumbers)) then best, bestNumbers = version, numbers end
	end
	Consider(ns.VERSION)
	Consider(versionTold)
	for _, author in pairs(ns.db.authors) do
		Consider(author.profile and author.profile.version)
	end
	for _, seen in pairs(presence) do
		Consider(seen.version)
	end
	return best, bestNumbers
end

-- The name a player shows under, as on the players ranking: the alias of
-- the character heard from last, else the character with the most kills
-- ever. characters come latest heard first.
local function PlayerName(characters)
	local alias = characters[1] and characters[1].alias
	local main, mainKills
	for _, character in ipairs(characters) do
		local kills = ns.Stats and ns.Stats.Character(character.guid, "all", "all").kills or 0
		if not main or kills > mainKills or (kills == mainKills and character.name < main.name) then
			main, mainKills = character, kills
		end
	end
	return alias or (main and main.name) or "?"
end

-- The guild members whose addon is older than the newest release, by
-- player: each judged by the character heard from last, so a player who
-- updated drops off as soon as any of its characters says so (a hello at
-- login, a presence message). Members still in the guild only, our own
-- player left out. Online players first, then the latest seen.
function Sync.Outdated()
	local newest, newestNumbers = NewestRelease()
	local result = { newest = newest, players = {} }
	if not newestNumbers then return result end
	local mine = Me().playerKey
	local groups = {}
	for tail, member in pairs(Identity.roster.byTail) do
		local guid = member.guid or GuidOf(tail)
		local author = ns.db.authors[guid]
		local profile = author and author.profile
		local seen = member.canon and presence[member.canon]
		local version = (profile and profile.version) or (seen and seen.version)
		local key = (profile and profile.playerKey) or (seen and seen.playerKey) or guid
		if version and not (author and author.own) and key ~= mine then
			local group = groups[key]
			if not group then
				group = { characters = {}, online = false }
				groups[key] = group
			end
			group.characters[#group.characters + 1] = {
				guid = guid, name = (profile and profile.name) or member.name or "?", version = version,
				alias = profile and profile.alias or nil,
				at = math.max(author and author.lastHello or 0, author and author.seenAt or 0, seen and seen.at or 0),
			}
			if member.online then group.online = true end
		end
	end
	for _, group in pairs(groups) do
		table.sort(group.characters, function(a, b)
			if a.at ~= b.at then return a.at > b.at end
			return a.name < b.name
		end)
		local last = group.characters[1]
		local numbers = Numbers(last.version)
		if numbers and Newer(newestNumbers, numbers) then
			result.players[#result.players + 1] = {
				name = PlayerName(group.characters), version = last.version, online = group.online,
				seen = last.at > 0 and last.at or nil, silent = Newer(VERSION_TELLS_SINCE, numbers),
			}
		end
	end
	table.sort(result.players, function(a, b)
		if a.online ~= b.online then return a.online end
		if (a.seen or 0) ~= (b.seen or 0) then return (a.seen or 0) > (b.seen or 0) end
		return a.name < b.name
	end)
	return result
end

--------------------------------------------------------------------------------
-- What we lack, and asking for it
--------------------------------------------------------------------------------

-- The pages of an author where we miss seqs up to the head a holder has.
-- A packed page is complete by construction.
local function MissingPages(tail, holderHead)
	local author = ns.db.authors[GuidOf(tail)]
	local rejected = author and author.rejected or {}
	local pages = {}
	for page = PageOf(holderHead), 1, -1 do
		if not (author and author.pages and author.pages[page]) then
			local from, to = PageRange(page)
			if to > holderHead then to = holderHead end
			for seq = from, to do
				if not (author and author.log[seq]) and not rejected[seq] then
					pages[#pages + 1] = page
					break
				end
			end
		end
	end
	return pages
end

local function NoteHolder(tail, holder, head, count)
	holders[tail] = holders[tail] or {}
	holders[tail][holder] = { head = head, count = count, at = Now() }
	-- A holder that announces again gets another chance.
	if failedBy[tail] then failedBy[tail][holder] = nil end
	local seen = seenHead[tail]
	if not seen or head >= seen.head then seenHead[tail] = { head = head, at = Now() } end
end

-- The requests in flight to a holder, by its canon name: a request keeps
-- the holder's name as the roster spells it.
local function InFlightFor(canon)
	local n = 0
	for _, request in pairs(requests) do
		if Identity.Canon(request.holder) == canon then n = n + 1 end
	end
	return n
end

local function HoldersInFlight()
	local set, n = {}, 0
	for _, request in pairs(requests) do
		if not set[request.holder] then
			set[request.holder] = true
			n = n + 1
		end
	end
	return n
end

local function SendRequest(tail, page, holder)
	local key = tail .. ":" .. page
	local request = { tail = tail, page = page, holder = holder, sentAt = Now(), deadline = Now() + REQUEST_TIMEOUT }
	requests[key] = request
	SendWhisper("Q", ("Q^%s^%d"):format(tail, page), holder, 2, Now() + 120, nil, function()
		requests[key] = nil
	end)
	ns.Count("sync.request")
	ns.Fire("SyncChanged")
end

-- A holder that failed us gets another chance after a while; one that said
-- it was busy, a little later.
local function Unavailable(failed, canon)
	local failedAt = failed[canon]
	if type(failedAt) == "number" and Now() - failedAt < FAIL_RETRY then return true end
	return (busyUntil[canon] or 0) > Now()
end

-- Picks the best holder for an author: the author itself when it is around,
-- else the holder with the most complete copy that has not failed us.
local function BestHolder(tail, failed)
	local authorName = NameOfTail(tail)
	local list = holders[tail] or {}
	local authorCanon = authorName and Identity.Canon(authorName)
	if authorCanon and IsAuthorOnline(tail) and MemberAround(authorCanon) and list[authorCanon] and not Unavailable(failed, authorCanon) then
		return authorName, list[authorCanon]
	end
	local bestName, best
	for canon, info in pairs(list) do
		if not Unavailable(failed, canon) and InFlightFor(canon) == 0 and MemberAround(canon) then
			local member = Identity.Member(canon)
			local complete = info.count >= info.head
			if member and (not best or (complete and best.count < best.head) or info.head > best.head) then
				bestName, best = member.name, info
			end
		end
	end
	return bestName, best
end

local function failedHolders(tail)
	failedBy[tail] = failedBy[tail] or {}
	return failedBy[tail]
end

-- Looks at everything announced and sends the next requests, within the
-- parallel limit. Called whenever something changes.
function Sync.Schedule()
	if not Identity.InGuild() then return end
	local tails = {}
	for tail in pairs(holders) do tails[#tails + 1] = tail end
	-- Our own journal first (crash recovery), then the most recently announced.
	table.sort(tails, function(a, b)
		local mine = Me().tail
		if a == mine then return true end
		if b == mine then return false end
		return (seenHead[a] and seenHead[a].at or 0) > (seenHead[b] and seenHead[b].at or 0)
	end)
	for _, tail in ipairs(tails) do
		if HoldersInFlight() >= MAX_HOLDERS then return end
		local failed = failedHolders(tail)
		local holderName, info = BestHolder(tail, failed)
		if holderName and InFlightFor(Identity.Canon(holderName)) == 0 then
			local pages = MissingPages(tail, info.head)
			for _, page in ipairs(pages) do
				local key = tail .. ":" .. page
				if not requests[key] then
					SendRequest(tail, page, holderName)
					break
				end
			end
		end
	end
end

-- The server answered that nobody by that name is playing: whatever waited
-- for that member is dropped, its requests fail now rather than at their
-- timeout, and the next holder is tried.
local function HolderGone(canon)
	gone[canon] = Now()
	local index = 1
	while index <= #queue do
		local item = queue[index]
		if item.channel == "WHISPER" and Identity.Canon(item.target) == canon then
			table.remove(queue, index)
			if item.onDrop then item.onDrop() end
			ns.Count("sync.dropOffline")
		else
			index = index + 1
		end
	end
	local dropped = 0
	for key, request in pairs(requests) do
		if Identity.Canon(request.holder) == canon then
			requests[key] = nil
			partial[key] = nil
			failedHolders(request.tail)[canon] = Now()
			dropped = dropped + 1
		end
	end
	if dropped > 0 then ns.Count("sync.holderGone", dropped) end
	Sync.Schedule()
	ns.Fire("SyncChanged")
end

-- A whisper to someone who is not playing gets a system line in the chat
-- ("No player named '%s' is currently playing."). When the whisper was
-- ours, the line is ours to hide, and it says the member is gone.
local filterInstalled = false
local function InstallNotFoundFilter()
	if filterInstalled or not Util.Fn(ChatFrame_AddMessageEventFilter) then return end
	local template = ERR_CHAT_PLAYER_NOT_FOUND_S
	if type(template) ~= "string" or not template:find("%s", 1, true) then return end
	local escaped = (template:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
	local pattern = "^" .. (escaped:gsub("%%%%s", "(.+)")) .. "$"
	filterInstalled = true
	ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, message)
		local name = type(message) == "string" and message:match(pattern) or nil
		local canon = name and Identity.Canon(name) or nil
		local at = canon and whispered[canon] or nil
		if not at or Now() - at > NOT_FOUND_WINDOW then return false end
		ns.Count("sync.notFoundHidden")
		Util.Guard("sync-gone", HolderGone, canon)
		return true
	end)
end

local function CheckTimeouts()
	local now = Now()
	for key, request in pairs(requests) do
		if now > request.deadline then
			requests[key] = nil
			local failed = failedHolders(request.tail)
			failed[Identity.Canon(request.holder)] = now
			ns.Count("sync.requestTimeout")
			partial[key] = nil
		end
	end
	for key, part in pairs(partial) do
		if now - part.at > PARTIAL_MAX_AGE then
			partial[key] = nil
			ns.Count("sync.partialExpired")
		end
	end
	Sync.Schedule()
end

--------------------------------------------------------------------------------
-- Pages
--------------------------------------------------------------------------------

local function Compress(text)
	if LibDeflate then
		local packed = LibDeflate:CompressDeflate(text, { level = 5 })
		return "z" .. LibDeflate:EncodeForWoWAddonChannel(packed)
	end
	return "p" .. (text:gsub("\n", "\1"))
end

local function Decompress(data)
	local mode, body = data:sub(1, 1), data:sub(2)
	if mode == "z" then
		if not LibDeflate then return nil end
		local packed = LibDeflate:DecodeForWoWAddonChannel(body)
		if not packed then return nil end
		return LibDeflate:DecompressDeflate(packed)
	elseif mode == "p" then
		return (body:gsub("\1", "\n"))
	end
	return nil
end

-- The lines of a page: the author's profile first, then its records. A
-- packed page is served from its deflated bytes without inflating it, the
-- profile sent apart.
function Sync.BuildPage(tail, page)
	local author = ns.db.authors[GuidOf(tail)]
	if not author then return nil end
	local profileLine = author.profile and Records.EncodeProfile(author.profile) or nil
	local packedBytes = Records.PackedBytes(author, page)
	if packedBytes then return nil, Records.PAGE, packedBytes, profileLine end
	local lines = {}
	if profileLine then lines[#lines + 1] = profileLine end
	local from, to = PageRange(page)
	local n = 0
	for seq = from, to do
		local text = author.log[seq]
		if text then
			lines[#lines + 1] = text
			n = n + 1
		end
	end
	if n == 0 then return nil end
	return table.concat(lines, "\n"), n
end

local function OnRequest(sender, tail, page)
	if not Identity.Member(sender) then return end
	if outPages >= OUT_PAGES_CAP then
		-- Enough pages going out already: the requester asks again later
		-- instead of waiting for a timeout and giving us up.
		SendWhisper("B", ("B^%s^%d^0^0^busy"):format(tail, page), sender, 3)
		ns.Count("sync.pageRefused")
		return
	end
	local text, _, packedBytes, profileLine = Sync.BuildPage(tail, page)
	if not text and not packedBytes then
		-- Nothing here: say so, the requester moves on.
		SendWhisper("B", ("B^%s^%d^0^0^"):format(tail, page), sender, 3)
		ns.Count("sync.pageEmpty")
		return
	end
	local data
	if packedBytes and LibDeflate then
		data = "z" .. LibDeflate:EncodeForWoWAddonChannel(packedBytes)
		if profileLine then SendWhisper("P", ("P^%s^%s"):format(tail, profileLine), sender, 3) end
	else
		data = Compress(text)
	end
	local chunks = {}
	local rest = data
	while #rest > 0 do
		chunks[#chunks + 1] = rest:sub(1, CHUNK)
		rest = rest:sub(CHUNK + 1)
	end
	outPages = outPages + 1
	local left = #chunks
	local function done()
		left = left - 1
		if left == 0 then outPages = outPages - 1 end
	end
	local expires = Now() + OUT_PAGE_MAX_AGE
	for index, chunk in ipairs(chunks) do
		-- A chunk the queue refuses is done with too, or the page would
		-- count as going out for the rest of the session.
		if not SendWhisper("B", ("B^%s^%d^%d^%d^%s"):format(tail, page, index, #chunks, chunk), sender, 3, expires, done, done) then
			done()
		end
	end
	ns.Count("sync.pageSent")
end

-- Puts a complete page into the author's journal: validated, chained with
-- what we already hold, provisional above the author's announced head.
local function StorePage(sender, tail, page, text)
	local guid = GuidOf(tail)
	local author = Records.Author(guid)
	local fromAuthor = (Identity.Member(sender) or {}).tail == tail
	local records, unknown = {}, {}
	local profile
	for line in (text .. "\n"):gmatch("(.-)\n") do
		if line:sub(1, 2) == "P1" then
			profile = Records.DecodeProfile(line)
		elseif line ~= "" then
			local record = Records.Decode(line)
			if record then
				local ok, why = Records.Validate(record, Now())
				if ok then
					records[#records + 1] = { record = record, text = line }
				else
					ns.Count("sync.rejected." .. tostring(why))
					if type(record.seq) == "number" then
						author.rejected = author.rejected or {}
						author.rejected[record.seq] = true
					end
				end
			else
				-- A record of a kind this version does not know: kept as text,
				-- so a later version reads it and the journal shows no hole to
				-- fetch again. Outside the chain, like a gap.
				local seq = tonumber(line:match("^%u%d+;(%d+);"))
				if seq then
					unknown[#unknown + 1] = { seq = seq, text = line }
					ns.Count("sync.unknownKept")
				end
			end
		end
	end
	-- The chain is checked over the page plus our neighbours of it.
	local from, to = PageRange(page)
	local chain = {}
	for _, item in ipairs(records) do chain[#chain + 1] = item.record end
	local before = Records.Get(guid, from - 1)
	local after = Records.Get(guid, to + 1)
	if before then chain[#chain + 1] = before end
	if after then chain[#chain + 1] = after end
	local okChain, breakAt = Records.CheckChain(chain)
	if not okChain then
		ns.Count("sync.pageChainBroken")
		failedHolders(tail)[Identity.Canon(sender)] = Now()
		-- The records around the break, for /kbs debug.
		local around = {}
		for _, item in ipairs(chain) do
			if math.abs((item.seq or 0) - breakAt) <= 1 then around[#around + 1] = Records.Encode(item) end
		end
		table.sort(around)
		ns.db.debug.lastChainBreak = { tail = tail, page = page, seq = breakAt, from = sender, at = Now(), around = around }
		return false
	end
	local added = 0
	local function Keep(seq, line)
		if seq < from or seq > to then return end
		local confirmed = author.confirmedHead
		if confirmed and seq > confirmed and not fromAuthor then
			-- Above what the author announced: kept, marked, purged later
			-- if the author's next hello contradicts it.
			author.provisional = author.provisional or {}
			author.provisional[seq] = true
		end
		local stored = Records.Store(guid, seq, line, fromAuthor and "author" or "page")
		if stored then added = added + 1 end
	end
	for _, item in ipairs(records) do Keep(item.record.seq, item.text) end
	for _, item in ipairs(unknown) do Keep(item.seq, item.text) end
	if profile and (not author.profile or fromAuthor) then
		author.profile = profile
		author.profileVerified = fromAuthor or nil
		Heard(profile.version, false)
	end
	ns.Count("sync.pageStored")
	pagesIn, lastPageAt = pagesIn + 1, Now()
	if added > 0 then ns.Fire("JournalChanged", guid) end
	-- A member who held nothing of the guild hears once that it is coming in.
	if added > 0 and guid ~= Me().guid and heldAtLogin == 0 and not firstPagesSaid then
		firstPagesSaid = true
		ns.Print(L.SYNC_FIRST_PAGES)
	end
	ns.Fire("SyncChanged")
	return true
end

local function OnPageChunk(sender, tail, page, index, total, data)
	local key = tail .. ":" .. page
	local request = requests[key]
	if not request or Identity.Canon(request.holder) ~= Identity.Canon(sender) then
		ns.Count("sync.pageUnexpected")
		return
	end
	if total == 0 then
		requests[key] = nil
		if data == "busy" then
			-- The holder has too much going out: asked again a little later.
			busyUntil[Identity.Canon(sender)] = Now() + BUSY_WAIT
			ns.Count("sync.pageBusy")
			Util.After(BUSY_WAIT + Jitter(0, 5), "sync-busy", Sync.Schedule)
		else
			-- The holder has nothing for that page.
			local failed = failedHolders(tail)
			failed[Identity.Canon(sender)] = Now()
		end
		Sync.Schedule()
		return
	end
	local part = partial[key]
	if not part then
		part = { total = total, got = 0, pieces = {}, at = Now() }
		partial[key] = part
	end
	request.deadline = Now() + CHUNK_TIMEOUT * (total - part.got) + 5
	if not part.pieces[index] then
		part.pieces[index] = data
		part.got = part.got + 1
	end
	if part.got < part.total then return end
	partial[key] = nil
	requests[key] = nil
	local text = Decompress(table.concat(part.pieces))
	if not text then
		ns.Count("sync.pageUndecodable")
		failedHolders(tail)[Identity.Canon(sender)] = Now()
	else
		StorePage(sender, tail, page, text)
	end
	Sync.Schedule()
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

local function ParseList(text)
	local list = {}
	for tail, head, count, lifeHK in text:gmatch("([%d%-%x]+)=(%d+)/(%d+)/?(%d*)") do
		list[#list + 1] = { tail = tail, head = tonumber(head), count = tonumber(count), lifeHK = tonumber(lifeHK) }
	end
	return list
end

-- An author announced its own journal: head and lifetime count. Records we
-- hold above that head are either from a session the author lost (their
-- counter still covers them: kept, and advertised so the author takes them
-- back) or invented by someone (the counter cannot cover them: purged).
local function ConfirmAuthor(tail, head, lifeHK)
	local author = Records.Author(GuidOf(tail))
	author.confirmedHead = head
	if type(lifeHK) == "number" then author.confirmedLifeHK = lifeHK end
	author.lastHello = Now()
	if (author.head or 0) > head and not author.own then
		local purged, kept = 0, 0
		for seq, text in pairs(author.log) do
			if seq > head then
				local record = Records.Decode(text)
				local after = record and Records.LifeAfter(record)
				-- Without a counter to judge by, nothing is purged.
				if type(lifeHK) ~= "number" or (type(after) == "number" and after <= lifeHK) then
					kept = kept + 1
					author.provisional = author.provisional or {}
					author.provisional[seq] = true
				else
					author.log[seq] = nil
					purged = purged + 1
				end
			end
		end
		if purged > 0 then
			local newHead, count = 0, 0
			for seq in pairs(author.log) do
				count = count + 1
				if seq > newHead then newHead = seq end
			end
			author.head, author.count = newHead, count
			ns.Count("sync.purged", purged)
			ns.Fire("JournalChanged", GuidOf(tail))
		end
		if kept > 0 then ns.Count("sync.keptForAuthor", kept) end
	else
		author.provisional = nil
	end
end

-- Where we stand against what someone holds: more than us, or less than us.
-- A complete list (an inventory) also says what they hold nothing of: every
-- journal we hold that it leaves out, their own included after a crash.
local function Compare(sender, list, complete)
	local canon = Identity.Canon(sender)
	local member = Identity.Member(sender)
	local ahead = {}
	local listed = {}
	for _, entry in ipairs(list) do
		listed[entry.tail] = true
		if member and entry.tail == member.tail then ConfirmAuthor(entry.tail, entry.head, entry.lifeHK) end
		local author = ns.db.authors[GuidOf(entry.tail)]
		local myHead, myCount = author and author.head or 0, author and author.count or 0
		-- When they hold more, Schedule asks them; when we do, we say so.
		NoteHolder(entry.tail, canon, entry.head, entry.count)
		if myHead > entry.head or (myHead == entry.head and myCount > entry.count) then
			ahead[#ahead + 1] = { tail = entry.tail, head = myHead, count = myCount }
		end
	end
	if complete then
		for _, entry in ipairs(HeldEntries()) do
			if not listed[entry.tail] then
				ahead[#ahead + 1] = { tail = entry.tail, head = entry.head, count = entry.count }
			end
		end
	end
	if #ahead > 0 then ScheduleAdvance(ahead) end
	Sync.Schedule()
end

local function OnHello(sender, fields)
	local member = Identity.Member(sender)
	if not member then
		ns.Count("sync.helloNotMember")
		return
	end
	local tail, head, lifeHK = fields[4], tonumber(fields[5]), tonumber(fields[6])
	if not tail or not head or member.tail ~= tail then
		ns.Count("sync.helloBadTail")
		return
	end
	local canon = Identity.Canon(sender)
	local before = peers[canon]
	local peer = { tail = tail, head = head, lifeHK = lifeHK, playerKey = fields[7], version = fields[3], at = Now(), name = sender }
	peers[canon] = peer
	Heard(fields[3], true)
	AnswerVersion(Numbers(fields[3]))
	-- A hello that announces no journal, with no inventory behind it, is a
	-- member who holds nothing yet: tell them everything we hold, unless
	-- their inventory shows up (and then says what they lack). A hello that
	-- announces a journal is not a newcomer's: the member held that journal
	-- at login and said its inventory then. It comes now and then as the
	-- journal grows, after a crash, after an import; when it comes while a
	-- newcomer's answer waits (an import right after a first login), the
	-- answer stays due.
	if head == 0 then
		local helloAt = Now()
		peer.emptyAt = helloAt
		Util.After(INVENTORY_WAIT, "advance-newcomer", function()
			local latest = peers[canon]
			if not latest or latest.emptyAt ~= helloAt or latest.inventoryAt then return end
			local entries = {}
			for _, entry in ipairs(HeldEntries()) do
				if entry.tail ~= tail then entries[#entries + 1] = entry end
			end
			if #entries > 0 then ScheduleAdvance(entries) end
		end)
	elseif before then
		peer.emptyAt, peer.inventoryAt = before.emptyAt, before.inventoryAt
	end
	Compare(sender, { { tail = tail, head = head, count = head, lifeHK = lifeHK } })
	ns.Count("sync.helloReceived")
	ns.Fire("PeerSeen", canon, peers[canon])
end

-- A profile from its author is taken as is; one relayed with a packed page
-- (a whisper from a holder) only fills a blank, unverified.
local function OnProfile(sender, tail, text, channel)
	local member = Identity.Member(sender)
	if not member then return end
	local profile = Records.DecodeProfile(text)
	if not profile then return end
	local author = Records.Author(GuidOf(tail))
	if member.tail == tail then
		author.profile = profile
		author.profileVerified = true
		author.profileAt = Now()
	elseif channel == "WHISPER" and not author.profile then
		author.profile = profile
		author.profileVerified = nil
	else
		ns.Count("sync.profileNotAuthor")
		return
	end
	Heard(profile.version, channel == "GUILD")
	ns.Fire("ProfileChanged", GuidOf(tail))
end

local function OnRecord(sender, tail, seq, text)
	local member = Identity.Member(sender)
	if not member or member.tail ~= tail then
		ns.Count("sync.recordNotAuthor")
		return
	end
	if member.canon == Identity.Canon(Me().name) then return end
	local record = Records.Decode(text)
	if not record or record.seq ~= seq then
		ns.Count("sync.recordBad")
		return
	end
	local ok, why = Records.Validate(record, Now())
	if not ok then
		ns.Count("sync.rejected." .. tostring(why))
		return
	end
	local guid = GuidOf(tail)
	local author = Records.Author(guid)
	local previous = Records.Get(guid, seq - 1)
	if previous and not Records.CheckChain({ previous, record }) then
		ns.Count("sync.recordChainBroken")
		return
	end
	local head = author.head or 0
	local stored = Records.Store(guid, seq, text, "author")
	author.confirmedHead = math.max(author.confirmedHead or 0, seq)
	author.confirmedLifeHK = Records.LifeAfter(record) or author.confirmedLifeHK
	if seq > head + 1 then
		-- A hole before it: the author is online, ask it.
		NoteHolder(tail, member.canon, seq, seq)
		Sync.Schedule()
	end
	if stored then
		ns.Count("sync.recordReceived")
		ns.Fire("RecordStored", guid, seq, record, text)
	end
end

-- A member says the role of another character of its player, which cannot
-- speak while it is offline. Taken when both said of themselves, each in
-- its own profile, that they are the same player's; the character says it
-- again itself the next time it logs in.
local function OnCharacterRole(sender, tail, role)
	local member = Identity.Member(sender)
	local speaker = member and member.tail and ns.db.authors[GuidOf(member.tail)]
	local author = ns.db.authors[GuidOf(tail)]
	local key = speaker and speaker.profileVerified and speaker.profile and speaker.profile.playerKey
	if not (key and author and author.profileVerified and author.profile and author.profile.playerKey == key
		and Identity.MemberByTail(tail)) then
		ns.Count("sync.roleRefused")
		return
	end
	author.profile.role = Identity.IsRole(role) and role or nil
	ns.Count("sync.roleReceived")
	ns.Fire("ProfileChanged", GuidOf(tail))
end

-- A member is here and runs this version: kept for the session, and on
-- its profile, which was the author's own word too.
local function OnPresence(sender, version, playerKey)
	local member = Identity.Member(sender)
	if not member or not member.tail or #version > 20 then return end
	presence[member.canon] = { version = version, playerKey = playerKey ~= "" and playerKey or nil, at = Now() }
	local author = ns.db.authors[GuidOf(member.tail)]
	if author then
		author.seenAt = Now()
		if author.profile then author.profile.version = version end
	end
	-- Older clients ignore presence messages: no reason to keep quiet for them.
	Heard(version, false)
	ns.Count("sync.presenceReceived")
	ns.Fire("PresenceChanged", member.canon)
end

local function OnAddonMessage(prefix, text, channel, sender)
	if Util.IsSecret(prefix) or prefix ~= PREFIX then return end
	if Util.IsSecret(text) or Util.IsSecret(sender) or type(text) ~= "string" then
		ns.Count("sync.in.secret")
		return
	end
	local kind = text:sub(1, 1)
	-- Our own guild messages sometimes come back to us on Forever.
	if sender == Me().name or Identity.IsMe(sender) then return end
	ns.Count("sync.in." .. kind)
	local senderCanon = Identity.Canon(sender)
	if senderCanon then heard[senderCanon] = Now() end
	if kind == "H" then
		local fields = {}
		for field in (text .. "^"):gmatch("([^%^]*)%^") do fields[#fields + 1] = field end
		if tonumber(fields[2]) ~= PROTOCOL then
			ns.Count("sync.protocolOther")
			return
		end
		OnHello(sender, fields)
	elseif kind == "P" then
		local tail, body = text:match("^P%^([%d%-%x]+)%^(.*)$")
		if tail then OnProfile(sender, tail, body, channel) end
	elseif kind == "I" or kind == "A" then
		local body = text:match("^[IA]%^(.*)$")
		if body then
			if Identity.Member(sender) then
				if kind == "I" then
					local peer = peers[Identity.Canon(sender)]
					if peer then peer.inventoryAt = Now() end
					-- Every login sends one, even when its hello is not due yet.
					ns.Fire("InventoryHeard", Identity.Canon(sender))
				end
				Compare(sender, ParseList(body), kind == "I")
				ns.Count("sync.listReceived")
			end
		end
	elseif kind == "R" then
		local tail, seq, body = text:match("^R%^([%d%-%x]+)%^(%d+)%^(.*)$")
		if tail then OnRecord(sender, tail, tonumber(seq), body) end
	elseif kind == "V" then
		local version = text:match("^V%^(.+)$")
		if version and Identity.Member(sender) and not Heard(version, channel == "GUILD") then
			ns.Count("sync.versionBad")
		end
	elseif kind == "O" then
		local version, playerKey = text:match("^O%^([^%^]+)%^?([^%^]*)$")
		if version then OnPresence(sender, version, playerKey or "") end
	elseif kind == "G" then
		if ns.Ranks then ns.Ranks.OnRule(sender, text) end
	elseif kind == "C" then
		local tail, role = text:match("^C%^([%d%-%x]+)%^(%a?)$")
		if tail then OnCharacterRole(sender, tail, role) end
	elseif kind == "Q" then
		local tail, page = text:match("^Q%^([%d%-%x]+)%^(%d+)$")
		if tail then OnRequest(sender, tail, tonumber(page)) end
	elseif kind == "B" then
		local tail, page, index, total, data = text:match("^B%^([%d%-%x]+)%^(%d+)%^(%d+)%^(%d+)%^(.*)$")
		if tail then OnPageChunk(sender, tail, tonumber(page), tonumber(index), tonumber(total), data) end
	end
end

--------------------------------------------------------------------------------
-- Our own records, live
--------------------------------------------------------------------------------

local function OnOwnRecord(guid, seq, text, _, source)
	if guid ~= Me().guid or not Identity.InGuild() then return end
	-- Imported history is not news: the hello that follows announces the
	-- head and the guild takes the pages by whisper.
	if source == "import" then return end
	SendGuild("R", ("R^%s^%d^%s"):format(Me().tail, seq, text), 1)
	-- A hello once in a while tells everyone our new head.
	local char = Char()
	if lastHeadAnnounced and seq - lastHeadAnnounced >= 20 and Now() - (char.lastHello or 0) >= HELLO_MIN_GAP then
		Sync.SendHello("head")
	end
end

--------------------------------------------------------------------------------
-- Crash recovery
--
-- The counter moved while nothing was saved: our own records went out live
-- and some member holds them. Ask them back before numbering new ones.
--------------------------------------------------------------------------------

local function EndRecovery(why)
	if not recovery then return end
	local jump = recovery
	recovery = nil
	local author = ns.db.authors[Me().guid]
	local last = author and author.head and Records.Get(Me().guid, author.head)
	local lifeAfter = last and Records.LifeAfter(last)
	if author then
		author.provisional = nil
		author.confirmedHead = author.head
	end
	-- The records are ours again. Whatever the guild could not give back is
	-- a counter record, which comes before the records held meanwhile so the
	-- chain stays in order.
	Records.HoldOwn(false)
	if type(lifeAfter) == "number" and lifeAfter >= jump.to then
		ns.Detect.CancelJump()
		ns.Count("sync.recovered")
	elseif type(lifeAfter) == "number" and lifeAfter > jump.from then
		ns.Detect.CancelJump()
		Records.AppendOwn({ type = "X", t = Now(), bucket = "u", fromHK = lifeAfter, toHK = jump.to })
		ns.Count("sync.recoveredPartly")
	else
		ns.Detect.ResolveJump(jump.from, jump.to)
		ns.Count("sync.recoveryFailed")
	end
	Records.ReleaseOwn()
	ns.Count("sync.recoveryEnd." .. why)
	Sync.SendInventory()
end

local function OnCounterJump(fromHK, toHK)
	if not Identity.InGuild() then return end
	ns.Detect.DeferJump()
	Records.HoldOwn()
	recovery = { from = fromHK, to = toHK }
	ns.Count("sync.recoveryStart")
	Util.After(5, "recovery-hello", function() Sync.SendHello("recovery") end)
	Util.After(RECOVERY_WAIT, "recovery-end", function() EndRecovery("timeout") end)
end

-- Our own journal grew from a page: maybe the lost session is back.
local function OnOwnJournalChanged(guid)
	if guid ~= Me().guid or not recovery then return end
	local author = ns.db.authors[guid]
	local last = author and author.head and Records.Get(guid, author.head)
	local lifeAfter = last and Records.LifeAfter(last)
	if type(lifeAfter) == "number" and lifeAfter >= recovery.to then EndRecovery("recovered") end
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

-- The journals of other characters we hold something of.
local function HeldOthers()
	local n = 0
	local mine = Me().guid
	for guid, author in pairs(ns.db.authors) do
		if guid ~= mine and (author.head or 0) > 0 then n = n + 1 end
	end
	return n
end

-- Members with the addon around: those the roster shows online and who run
-- the addon as far as we know (their profile is held, or a message of theirs
-- came in this session), plus those whose hello came in lately while the
-- roster has not caught up with their login. Hellos alone miss everyone
-- who was online before our own login or /reload: they never say it again.
local function PeersAround()
	local n = 0
	local counted = {}
	local myTail = Me().tail
	for tail, member in pairs(Identity.roster.byTail) do
		if tail ~= myTail and member.online then
			local author = ns.db.authors[member.guid or GuidOf(tail)]
			if (author and author.profile) or (member.canon and heard[member.canon]) then
				n = n + 1
				counted[tail] = true
			end
		end
	end
	for _, peer in pairs(peers) do
		if not counted[peer.tail] and Now() - peer.at < ONLINE_WINDOW then
			local member = Identity.MemberByTail(peer.tail)
			if not (member and member.online == false) then n = n + 1 end
		end
	end
	return n
end

-- Where the sync stands, for the window's footer and /kbs status.
function Sync.Status()
	local status = { peers = PeersAround(), held = HeldOthers(), pagesIn = pagesIn, lastPageAt = lastPageAt, queue = #queue }
	local inFlight, parts = 0, 0
	for _ in pairs(requests) do inFlight = inFlight + 1 end
	for _ in pairs(partial) do parts = parts + 1 end
	status.requests, status.partial = inFlight, parts
	if not Identity.InGuild() then
		status.phase = "noguild"
	elseif recovery then
		status.phase = "recovery"
	elseif ChatBlocked() then
		status.phase = "paused"
	elseif helloDueAt then
		status.phase = "waiting"
		status.helloIn = math.max(0, helloDueAt - Now())
	elseif inFlight > 0 or parts > 0 or next(advancePending) ~= nil or #queue > 0 then
		status.phase = "busy"
	else
		status.phase = "idle"
	end
	return status
end

local function OnLogin()
	InstallNotFoundFilter()
	if C_ChatInfo and Util.Fn(C_ChatInfo.RegisterAddonMessagePrefix) then
		Util.Call(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
	end
	heldAtLogin = HeldOthers()
	-- The guild and its roster can take a few seconds to be known after
	-- login, and the answers to the hello are taken from roster members only.
	local function TryHello(attempt)
		if recovery then
			helloDueAt = nil
			return
		end
		if attempt <= HELLO_READY_TRIES and not (Identity.InGuild() and Identity.RosterKnown()) then
			helloDueAt = Now() + HELLO_READY_WAIT
			Util.After(HELLO_READY_WAIT, "hello", TryHello, attempt + 1)
			return
		end
		helloDueAt = nil
		Sync.SendHello("login")
		Sync.SendInventory()
	end
	local delay = Jitter(HELLO_DELAY_MIN, HELLO_DELAY_MAX)
	helloDueAt = Now() + delay
	Util.After(delay, "hello", TryHello, 1)
	Util.Every(HELLO_PERIOD, "hello-period", function()
		if OwnHead() ~= lastHeadAnnounced then Sync.SendHello("period") end
	end)
	Util.Every(10, "sync-timeouts", CheckTimeouts)
	Util.After(VERSION_SCAN_DELAY, "version-scan", ScanProfiles)
	Util.After(Jitter(PRESENCE_FIRST_MIN, PRESENCE_FIRST_MAX), "presence", function()
		Sync.SendPresence()
		Util.Every(PRESENCE_PERIOD, "presence", Sync.SendPresence)
	end)
end

-- A new display name or role goes out as a new profile.
local function OnProfileEdited()
	local me = Me()
	if not me.tail then return end
	local profile = Records.OwnProfile()
	ns.Fire("ProfileChanged", me.guid)
	if Identity.InGuild() then
		SendGuild("P", ("P^%s^%s"):format(me.tail, Records.EncodeProfile(profile)), 1)
	end
end

-- The role of another character of the account: kept on the profile held
-- here for it, and said to the guild in its place.
local function OnCharacterRoleEdited(guid, role)
	local author = ns.db.authors[guid]
	if author and author.profile then author.profile.role = role end
	ns.Fire("ProfileChanged", guid)
	local tail = Util.Tail(guid)
	if tail and Identity.InGuild() then SendGuild("C", ("C^%s^%s"):format(tail, role or ""), 1) end
end

-- History imported after the login hello went out: a new hello says the head.
local function OnImported()
	if lastHeadAnnounced ~= nil and Identity.InGuild() then Sync.SendHello("import") end
end

ns.On("CHAT_MSG_ADDON", OnAddonMessage)
ns.Hook("Login", OnLogin)
ns.Hook("AliasChanged", OnProfileEdited)
ns.Hook("RoleChanged", OnProfileEdited)
ns.Hook("MainChanged", OnProfileEdited)
ns.Hook("CharacterRoleChanged", OnCharacterRoleEdited)
ns.Hook("RecordAdded", OnOwnRecord)
ns.Hook("Imported", OnImported)
ns.Hook("CounterJump", OnCounterJump)
ns.Hook("JournalChanged", OnOwnJournalChanged)
ns.Hook("RosterUpdated", function() Sync.Schedule() end)
ns.Hook("Debug", function()
	local inFlight, parts = 0, 0
	for _ in pairs(requests) do inFlight = inFlight + 1 end
	for _ in pairs(partial) do parts = parts + 1 end
	local peerCount, holderCount = 0, 0
	for _ in pairs(peers) do peerCount = peerCount + 1 end
	for _ in pairs(holders) do holderCount = holderCount + 1 end
	ns.Print(("sync: queue %d, peers %d, authors announced %d, requests in flight %d, partial pages %d, pages going out %d, recovery %s"):format(
		#queue, peerCount, holderCount, inFlight, parts, outPages, tostring(recovery ~= nil)))
	local unconfirmed = 0
	for _, author in pairs(ns.db.authors) do
		if author.provisional then
			for _ in pairs(author.provisional) do unconfirmed = unconfirmed + 1 end
		end
	end
	ns.Print(("sync: %d unconfirmed record(s)"):format(unconfirmed))
	local brk = ns.db.debug.lastChainBreak
	if brk then
		ns.Print(("sync: last chain break on %s page %s at seq %s, served by %s, %s"):format(tostring(brk.tail), tostring(brk.page),
			tostring(brk.seq), tostring(brk.from), Util.Stamp(brk.at, true)))
		for _, line in ipairs(brk.around or {}) do ns.Print("  " .. line) end
	end
end)

-- For tests and the debug command.
function Sync.State()
	return {
		queue = queue, peers = peers, holders = holders, requests = requests, partial = partial, recovery = recovery,
		advancePending = advancePending, seenHead = seenHead, outPages = outPages,
	}
end
