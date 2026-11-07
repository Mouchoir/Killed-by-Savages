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
local HELLO_DELAY_MIN, HELLO_DELAY_MAX = 30, 60
local HELLO_MIN_GAP = 600         -- never two hellos within this, per character
local HELLO_PERIOD = 1200         -- a hello this often when the head moved
local ADVANCE_MIN, ADVANCE_MAX = 2, 20
local INVENTORY_WAIT = 15         -- after a hello, how long an inventory may take to follow
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
	local result = Sync.SendRaw(item.text, item.channel, item.target)
	ns.Count("sync.out." .. item.kind .. "." .. result)
	if result == "AddonMessageThrottle" or result == "ChannelThrottle" then
		Util.After(THROTTLE_WAIT, "pump", Pump)
		return
	end
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

function Sync.SendHello(reason)
	local me = Me()
	if not Identity.InGuild() or not me.tail then return false end
	local char = Char()
	helloDueAt = nil
	if reason ~= "recovery" and reason ~= "import" and Now() - (char.lastHello or 0) < HELLO_MIN_GAP then
		ns.Count("sync.helloSkipped")
		ns.Fire("SyncChanged")
		return false
	end
	char.lastHello = Now()
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

local function InFlightFor(holder)
	local n = 0
	for _, request in pairs(requests) do
		if request.holder == holder then n = n + 1 end
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
	if failedAt ~= nil and Now() - failedAt < FAIL_RETRY then return true end
	return (busyUntil[canon] or 0) > Now()
end

-- Picks the best holder for an author: the author itself when it is around,
-- else the holder with the most complete copy that has not failed us.
local function BestHolder(tail, failed)
	local authorName = NameOfTail(tail)
	local list = holders[tail] or {}
	if authorName and IsAuthorOnline(tail) and list[Identity.Canon(authorName)] and not Unavailable(failed, Identity.Canon(authorName)) then
		return authorName, list[Identity.Canon(authorName)]
	end
	local bestName, best
	for canon, info in pairs(list) do
		if not Unavailable(failed, canon) and InFlightFor(canon) == 0 then
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
		SendWhisper("B", ("B^%s^%d^%d^%d^%s"):format(tail, page, index, #chunks, chunk), sender, 3, expires, done, done)
	end
	ns.Count("sync.pageSent")
end

-- Puts a complete page into the author's journal: validated, chained with
-- what we already hold, provisional above the author's announced head.
local function StorePage(sender, tail, page, text)
	local guid = GuidOf(tail)
	local author = Records.Author(guid)
	local fromAuthor = (Identity.Member(sender) or {}).tail == tail
	local records = {}
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
		failedHolders(tail)[Identity.Canon(sender)] = true
		ns.db.debug.lastChainBreak = { tail = tail, page = page, seq = breakAt, from = sender, at = Now() }
		return false
	end
	local added = 0
	for _, item in ipairs(records) do
		local record = item.record
		if record.seq >= from and record.seq <= to then
			local confirmed = author.confirmedHead
			if confirmed and record.seq > confirmed and not fromAuthor then
				-- Above what the author announced: kept, marked, purged later
				-- if the author's next hello contradicts it.
				author.provisional = author.provisional or {}
				author.provisional[record.seq] = true
			end
			local stored = Records.Store(guid, record.seq, item.text, fromAuthor and "author" or "page")
			if stored then added = added + 1 end
		end
	end
	if profile and (not author.profile or fromAuthor) then
		author.profile = profile
		author.profileVerified = fromAuthor or nil
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
	peers[canon] = { tail = tail, head = head, lifeHK = lifeHK, playerKey = fields[7], version = fields[3], at = Now(), name = sender }
	-- A hello with no inventory behind it is a member who holds nothing yet:
	-- tell them everything we hold, unless their inventory shows up (and
	-- then says what they lack).
	local helloAt = Now()
	Util.After(INVENTORY_WAIT, "advance-newcomer", function()
		local peer = peers[canon]
		if not peer or peer.at ~= helloAt or peer.inventoryAt then return end
		local entries = {}
		for _, entry in ipairs(HeldEntries()) do
			if entry.tail ~= tail then entries[#entries + 1] = entry end
		end
		if #entries > 0 then ScheduleAdvance(entries) end
	end)
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
	elseif channel == "WHISPER" and not author.profile then
		author.profile = profile
		author.profileVerified = nil
	else
		ns.Count("sync.profileNotAuthor")
		return
	end
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
				end
				Compare(sender, ParseList(body), kind == "I")
				ns.Count("sync.listReceived")
			end
		end
	elseif kind == "R" then
		local tail, seq, body = text:match("^R%^([%d%-%x]+)%^(%d+)%^(.*)$")
		if tail then OnRecord(sender, tail, tonumber(seq), body) end
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

-- Members with the addon around: a hello this session, unless the roster
-- says they left since.
local function PeersAround()
	local n = 0
	for _, peer in pairs(peers) do
		local member = Identity.MemberByTail(peer.tail)
		if Now() - peer.at < ONLINE_WINDOW and not (member and member.online == false) then n = n + 1 end
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
	if C_ChatInfo and Util.Fn(C_ChatInfo.RegisterAddonMessagePrefix) then
		Util.Call(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
	end
	heldAtLogin = HeldOthers()
	local delay = Jitter(HELLO_DELAY_MIN, HELLO_DELAY_MAX)
	helloDueAt = Now() + delay
	Util.After(delay, "hello", function()
		helloDueAt = nil
		if recovery then return end
		Sync.SendHello("login")
		Sync.SendInventory()
	end)
	Util.Every(HELLO_PERIOD, "hello-period", function()
		if OwnHead() ~= lastHeadAnnounced then Sync.SendHello("period") end
	end)
	Util.Every(10, "sync-timeouts", CheckTimeouts)
end

-- A new display name goes out as a new profile.
local function OnAliasChanged()
	local me = Me()
	if not me.tail then return end
	local profile = Records.OwnProfile()
	ns.Fire("ProfileChanged", me.guid)
	if Identity.InGuild() then
		SendGuild("P", ("P^%s^%s"):format(me.tail, Records.EncodeProfile(profile)), 1)
	end
end

-- History imported after the login hello went out: a new hello says the head.
local function OnImported()
	if lastHeadAnnounced ~= nil and Identity.InGuild() then Sync.SendHello("import") end
end

ns.On("CHAT_MSG_ADDON", OnAddonMessage)
ns.Hook("Login", OnLogin)
ns.Hook("AliasChanged", OnAliasChanged)
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
end)

-- For tests and the debug command.
function Sync.State()
	return {
		queue = queue, peers = peers, holders = holders, requests = requests, partial = partial, recovery = recovery,
		advancePending = advancePending, seenHead = seenHead,
	}
end
