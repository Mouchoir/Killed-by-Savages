local _, ns = ...

--------------------------------------------------------------------------------
-- Kill feed: one line per kill or death of the guild in the world, and one
-- per battleground match. The member of the guild always comes first: "X
-- killed Y (2-1)", "X was killed by Y (2-2)". The score is the member's
-- kills on that enemy against the enemy's on the member, in the world,
-- from the member's own journal.
--
-- Off by default. Ticked, the lines go to the chat tab named after the feed
-- when the player has one, else to the main chat; the second option sends
-- them to the main chat anyway. Closing that tab turns the feed off.
--
-- The addon never opens, closes or selects a chat window. Run from an
-- addon, Blizzard's chat window code (FCF_OpenNewWindow, FCF_Close,
-- FCFDock_SelectWindow) writes the active chat edit box as the addon's:
-- every chat line and slash command the player types afterwards runs
-- tainted, for the rest of the session. In 12.x a message to the group then
-- fails on a secret value and /invite is refused as a protected call (both
-- seen in game with 1.0.0). So the player makes the tab, from the General
-- tab's menu, and the addon says how, once per session; it only reads the
-- chat windows and adds lines to them. One exception, asked for by the
-- player with a button of the Options tab: CreateTab opens the tab and
-- reloads the interface in the same breath, so the session that carries
-- the mark ends there and the next one starts clean, the tab in place.
--
-- In Forever's chat code (1.60.1) a closed window keeps its name, hidden
-- and out of the dock, and a docked tab behind another is hidden but still
-- docked: a window is the feed's tab when it carries the name and is in use.
--
-- A tab that stops looking like the feed's is never judged on one look. In
-- game the feed once turned itself off while its tab sat docked under its
-- name (2026-11-11: no error, the saved chat setup intact, the cause not
-- found). So the lines wait while the windows are looked at again, and the
-- feed turns off only when a tab named after it is seen closed twice,
-- CONFIRM seconds apart, by every sign the client gives. What each such
-- look saw is kept in the saved data, for /kbs debug.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local Stats = ns.Stats
local L = ns.L

local Killfeed = {}
ns.Killfeed = Killfeed

local HOLD_CAP = 50              -- lines kept while the chat windows cannot take them
local SETUP_DELAY = 3            -- seconds after the client set its chat windows up
local SETUP_LATEST = 10          -- seconds after entering the world, at the latest
local CONFIRM = 10               -- seconds between two looks at a tab that seems gone
local PATIENCE = 6               -- looks that tell nothing clear, before the lines leave the tab
local TRAIL_CAP = 8              -- looks kept in the saved data

local tab                        -- the feed's tab, once a line went to it
local held = {}                  -- lines waiting for the chat windows
local hinted = false             -- the player was told how to make the tab, this session
local chatReady = false          -- the client has set its chat windows up
local entered = false            -- the character is in the world
local setupDone = false          -- the chat windows can be looked at
local doubt                      -- the tab seems gone: { state, looks, waits }, until it is settled
local setups = 0                 -- times the client set its chat windows up, this session
local lastSetup                  -- when it last did, in client uptime
local lastWorld                  -- when the character last entered the world, in client uptime

local function Settings()
	return ns.db and ns.db.settings or {}
end

-- The lines go to the feed's tab when there is one, unless the player chose
-- the main chat.
local function InTab()
	return Settings().killfeedTab ~= false
end

-- Chat tabs belong to each character: this one's own state, when it has any.
local function Character()
	local guid = ns.Identity and ns.Identity.me and ns.Identity.me.guid
	local characters = ns.db and ns.db.characters
	return type(guid) == "string" and characters and characters[guid] or nil
end

-- Lines went to a tab on this character (true), or it has none any more (nil).
local function Used(value)
	local character = Character()
	if character then character.feedTabUsed = value end
end

local function WindowCount()
	local constants = Constants and Constants.ChatFrameConstants
	return tonumber(constants and constants.MaxChatWindows) or tonumber(NUM_CHAT_WINDOWS) or 10
end

local function Window(index)
	local window = _G["ChatFrame" .. index]
	if type(window) == "table" and window.AddMessage and window.GetID then return window end
	return nil
end

local function NameOf(index)
	if not Util.Fn(GetChatWindowInfo) then return nil end
	local ok, name = pcall(GetChatWindowInfo, index)
	return ok and name or nil
end

-- A value the client keeps to itself says neither yes nor no.
local function Yes(value)
	return value ~= nil and value ~= false and value ~= Util.SECRET
end

local function No(value)
	return value == nil or value == false
end

-- What the client says of a chat window, in plain values: its saved setup
-- (name, shown, docked) and the frame itself (docked, shown, its tab button).
local function Look(window)
	local index = window:GetID()
	local info = Util.Call(GetChatWindowInfo, index)
	local look = {
		index = index, name = info[1], shown = info[7], docked = info[9],
		failed = info.error or (info.missing and "no GetChatWindowInfo") or nil,
		frameDocked = Util.Safe(window.isDocked),
	}
	if Util.Fn(window.IsShown) then look.frameShown = Util.Get(window.IsShown, window) end
	local button = _G["ChatFrame" .. tostring(index) .. "Tab"]
	if type(button) == "table" and Util.Fn(button.IsShown) then look.tabShown = Util.Get(button.IsShown, button) end
	look.named = look.name == L.KILLFEED_TAB
	look.inUse = Yes(look.shown) or Yes(look.docked) or Yes(look.frameDocked) or Yes(look.frameShown) or Yes(look.tabShown)
	return look
end

-- "ok": named after the feed and in use. "closed": still named after the
-- feed, and neither shown nor docked by any sign, which is what closing a
-- tab leaves. "renamed": in use under another name. Anything else is
-- "unclear": the client can be between two setups of its chat windows, or
-- keep a value to itself. A tab the lines already go to (known) stays the
-- feed's while it is in use and its name cannot be read.
local function State(look, known)
	if look.inUse then
		if look.named then return "ok" end
		local name = look.name
		if type(name) == "string" and name ~= "" and name ~= Util.SECRET then return "renamed" end
		return known and "ok" or "unclear"
	end
	if look.named and No(look.shown) and No(look.docked) and No(look.frameDocked)
		and look.frameShown == false and No(look.tabShown) then
		return "closed"
	end
	return "unclear"
end

local function FindTab()
	for index = 1, WindowCount() do
		local window = Window(index)
		if window then
			local look = Look(window)
			if State(look, false) == "ok" then return window, look end
		end
	end
	return nil
end

-- Where the lines can go now, or what became of the tab: a state and the
-- look it comes from. The feed's tab is the one already in use while it
-- holds, else any window named after the feed and in use.
local function Survey()
	local state, look
	if tab then
		look = Look(tab)
		state = State(look, true)
		if state == "ok" then return state, look end
	end
	local found, foundLook = FindTab()
	if found then
		tab = found
		return "ok", foundLook
	end
	if state == "renamed" then return state, look end
	for index = 1, WindowCount() do
		local window = Window(index)
		if window then
			local other = Look(window)
			if State(other, false) == "closed" then return "closed", other end
		end
	end
	return "unclear", look
end

-- A tab is expected: lines went to one on this character, this session or
-- an earlier one.
local function Expected()
	local character = Character()
	return character ~= nil and character.feedTabUsed == true
end

--------------------------------------------------------------------------------
-- The looks kept for /kbs debug
--------------------------------------------------------------------------------

local function Flag(value)
	if value == Util.SECRET then return "?" end
	if value == nil then return "-" end
	return value and "y" or "n"
end

-- The name itself stays out of the saved data: only what kind it is.
local function NameKind(look)
	local name = look.name
	if look.named then return "feed" end
	if name == nil then return "none" end
	if name == Util.SECRET then return "secret" end
	if name == "" then return "empty" end
	if type(name) == "string" then return "other, " .. #name .. " bytes" end
	return type(name)
end

-- What may restrict the client at this instant.
local function Where()
	local parts = {}
	if Util.Get(InCombatLockdown) == true then parts[#parts + 1] = "in combat" end
	if C_ChatInfo and Util.Get(C_ChatInfo.InChatMessagingLockdown) == true then parts[#parts + 1] = "chat lockdown" end
	local inInstance, kind = Util.Get(IsInInstance)
	if inInstance == true then parts[#parts + 1] = "instance " .. tostring(kind) end
	return #parts > 0 and table.concat(parts, ", ") or "no restriction"
end

local function Trail(what, look)
	if not ns.db then return end
	local trail = ns.db.debug.killfeed
	if type(trail) ~= "table" then
		trail = {}
		ns.db.debug.killfeed = trail
	end
	local parts = { what }
	if look then
		parts[#parts + 1] = ("window %s: name %s, shown %s, docked %s, frame docked %s, frame shown %s, tab %s"):format(
			tostring(look.index), NameKind(look), Flag(look.shown), Flag(look.docked), Flag(look.frameDocked),
			Flag(look.frameShown), Flag(look.tabShown))
		if look.failed then parts[#parts + 1] = "read failed: " .. tostring(look.failed):sub(1, 80) end
	end
	local clock = Util.Clock()
	parts[#parts + 1] = ("chat setups %d, last %s s ago, in the world for %s s"):format(setups,
		lastSetup and ("%d"):format(clock - lastSetup) or "-", lastWorld and ("%d"):format(clock - lastWorld) or "-")
	parts[#parts + 1] = Where()
	trail[#trail + 1] = { at = Util.Now(), text = table.concat(parts, "; ") }
	while #trail > TRAIL_CAP do
		table.remove(trail, 1)
	end
end

--------------------------------------------------------------------------------
-- Where a line goes
--------------------------------------------------------------------------------

-- How to make the tab, in the client's own words: the General tab's name and
-- the entry of its menu that opens a new window. Once per session.
local function Hint(force)
	if hinted and not force then return end
	hinted = true
	local general = NameOf(1)
	if type(general) ~= "string" or general == "" then general = L.KILLFEED_GENERAL end
	local entry = type(NEW_CHAT_WINDOW) == "string" and NEW_CHAT_WINDOW or L.KILLFEED_NEW_WINDOW
	ns.Print(L.KILLFEED_MAKE_TAB:format(L.KILLFEED_TAB, general, entry, L.KILLFEED_TAB))
end

local function Hold(line)
	if #held >= HOLD_CAP then table.remove(held, 1) end
	held[#held + 1] = line
end

local Deliver

-- The lines that waited go out, in their order.
local function Flush()
	local waiting = held
	held = {}
	for index = 1, #waiting do
		Deliver(waiting[index])
	end
end

-- The feed's tab was closed: that turns the feed off, said in the main chat.
local function Closed()
	tab, doubt = nil, nil
	held = {}
	Settings().killfeed = false
	ns.Count("killfeed.closedByPlayer")
	ns.Print(L.KILLFEED_CLOSED)
	ns.Fire("SettingsChanged")
end

local Settle

-- The tab does not look like the feed's any more. Nothing is concluded
-- from this one look: the lines wait, and the windows are looked at again.
local function Doubt(state, look)
	doubt = { state = state, looks = 1 }
	ns.Count("killfeed.tabDoubt")
	Trail("doubt, " .. state, look)
	Util.After(CONFIRM, "killfeed-settle", Settle, doubt)
end

-- The next look. The tab is back: the lines go to it. Seen closed twice in
-- a row: the feed turns off. Seen renamed twice in a row, or nothing clear
-- for PATIENCE looks: the feed has no tab, as on a character that never
-- made one.
Settle = function(which)
	if doubt ~= which or not doubt then return end
	if lastSetup and Util.Clock() - lastSetup < CONFIRM and (doubt.waits or 0) < PATIENCE then
		-- The client set its chat windows up again a moment ago: look later.
		doubt.waits = (doubt.waits or 0) + 1
		Util.After(CONFIRM, "killfeed-settle", Settle, doubt)
		return
	end
	local state, look = Survey()
	if state == "ok" then
		doubt = nil
		ns.Count("killfeed.tabBack")
		Trail("back", look)
		Flush()
		return
	end
	local again = state == doubt.state
	doubt.state, doubt.looks = state, doubt.looks + 1
	if state == "closed" and again then
		Trail("closed", look)
		Closed()
		return
	end
	if (state == "renamed" and again) or doubt.looks >= PATIENCE then
		tab, doubt = nil, nil
		Used(nil)
		ns.Count("killfeed.tabGone")
		Trail("gone, " .. state, look)
		Flush()
		return
	end
	Util.After(CONFIRM, "killfeed-settle", Settle, doubt)
end

-- A line to the feed's tab, or to the main chat when the player has none or
-- chose it.
Deliver = function(line)
	if InTab() then
		if doubt then
			Hold(line)                   -- the windows are being looked at again
			return
		end
		local state, look = Survey()
		if state == "ok" then
			Used(true)
			tab:AddMessage(line)
			return
		end
		if Expected() then
			Doubt(state, look)
			Hold(line)
			return
		end
		Hint()
	end
	ns.Print(line)
end

--------------------------------------------------------------------------------
-- The lines
--------------------------------------------------------------------------------

-- Kills of the member on the enemy, and the enemy's on the member, in the
-- world (see Stats).
local function Score(agg, tail)
	if not tail then return nil end
	local kills = agg.victims[tail] and agg.victims[tail].count or 0
	local deaths = agg.killers[tail] and agg.killers[tail].count or 0
	return kills, deaths
end

local function Coloured(name, classFile)
	if type(classFile) ~= "string" then return name end
	local r, g, b = Theme.ClassColor(classFile)
	return ("|cff%02x%02x%02x%s|r"):format(r * 255 + 0.5, g * 255 + 0.5, b * 255 + 0.5, name)
end

-- The colours the game gives a level by how it rates it, under the names of
-- its own table (QuestDifficultyColors), and their values should a client
-- not have that table.
local CON_COLOR = {
	T = { "trivial", 0.50, 0.50, 0.50 }, E = { "standard", 0.25, 0.75, 0.25 }, F = { "difficult", 1.00, 0.82, 0.00 },
	D = { "verydifficult", 1.00, 0.50, 0.25 }, I = { "impossible", 1.00, 0.10, 0.10 },
}
local SKULL_ATLAS = "UI-HUD-UnitFrame-Target-HighLevelTarget_Icon"
local skull                      -- the skull as a piece of chat text, once worked out

-- The skull the target frame shows in place of a level too high to be
-- told; the locale's word for it on a client without that art.
local function Skull()
	if skull then return skull end
	skull = L.KILLFEED_SKULL
	if type(C_Texture) == "table" and Util.Fn(C_Texture.GetAtlasInfo) then
		local ok, info = pcall(C_Texture.GetAtlasInfo, SKULL_ATLAS)
		if ok and type(info) == "table" then skull = ("|A:%s:14:14|a"):format(SKULL_ATLAS) end
	end
	return skull
end

-- What follows a name: " (28)", the level. For an enemy the number takes
-- the colour the game rated it with against the member, and a level the
-- game hid is its skull. Nothing when the level is not known.
local function Level(level, con)
	if con == "S" then return " (" .. Skull() .. ")" end
	if type(level) ~= "number" or level < 1 then return "" end
	local spec = CON_COLOR[con]
	if not spec then return (" (%d)"):format(level) end
	local r, g, b = spec[2], spec[3], spec[4]
	local color = type(QuestDifficultyColors) == "table" and QuestDifficultyColors[spec[1]]
	if type(color) == "table" and type(color.r) == "number" and type(color.g) == "number" and type(color.b) == "number" then
		r, g, b = color.r, color.g, color.b
	end
	return (" (|cff%02x%02x%02x%d|r)"):format(r * 255 + 0.5, g * 255 + 0.5, b * 255 + 0.5, level)
end

-- The member first, then the enemy, then the member's kills on it against
-- its kills on the member: "killed" for a kill, "was killed by" for a death.
local function Sentence(member, enemy, kills, deaths, zone, died)
	local score = kills and ("%d-%d"):format(kills, deaths) or nil
	if score and zone then return (died and L.KILLFEED_DEATH or L.KILLFEED_KILL):format(member, enemy, score, zone) end
	if score then return (died and L.KILLFEED_DEATH_NOZONE or L.KILLFEED_KILL_NOZONE):format(member, enemy, score) end
	if zone then return (died and L.KILLFEED_DEATH_NOSCORE or L.KILLFEED_KILL_NOSCORE):format(member, enemy, zone) end
	return (died and L.KILLFEED_DEATH_BARE or L.KILLFEED_KILL_BARE):format(member, enemy)
end

-- "1 death", "9 deaths".
local function Amount(count, one, many)
	return (count == 1 and one or many):format(count)
end

-- The end of a battleground match: the member's row of the scoreboard. A
-- match left before its scoreboard was read only knows the HKs the
-- counter moved by. A scoreboard written by hand for a guild raid in the
-- world (instance 0) is no match.
local function MatchLine(member, record)
	if record.backfill or record.instanceID == 0 then return nil end
	local zone = Theme.ZoneName(record.mapID)
	local kills = Amount(record.hk or 0, L.KILLFEED_ONE_KILL, L.KILLFEED_N_KILLS)
	if (record.kb or 0) == 0 and (record.deaths or 0) == 0 and (record.honor or 0) == 0 then
		return zone and L.KILLFEED_MATCH_LEFT:format(member, zone, kills) or L.KILLFEED_MATCH_LEFT_NOZONE:format(member, kills)
	end
	local blows = Amount(record.kb or 0, L.KILLFEED_ONE_BLOW, L.KILLFEED_N_BLOWS)
	local deaths = Amount(record.deaths or 0, L.KILLFEED_ONE_DEATH, L.KILLFEED_N_DEATHS)
	if zone then return L.KILLFEED_MATCH:format(member, zone, kills, blows, deaths) end
	return L.KILLFEED_MATCH_NOZONE:format(member, kills, blows, deaths)
end

-- What a record says of a member, in words. score(tail) gives the member's
-- kills on that enemy and the enemy's on the member, or nothing.
local function Words(member, record, score)
	if record.type == "M" then return MatchLine(member, record) end
	local zone = Theme.ZoneName(record.mapID) or record.sub
	if record.type == "K" then
		if not record.vname then
			return zone and L.KILLFEED_UNKNOWN:format(member, zone) or L.KILLFEED_UNKNOWN_NOZONE:format(member)
		end
		local kills, deaths = score(record.vtail)
		return Sentence(member, Coloured(record.vname, record.vclass) .. Level(record.vlevel, record.vcon), kills, deaths, zone)
	end
	local enemy
	if record.kkind == "p" then
		enemy = Coloured(record.kname or "?", record.kclass) .. Level(record.klevel, record.kcon)
	else
		enemy = (record.kname or "?") .. " (" .. L.TOOLTIP_PET .. ")"
	end
	local kills, deaths = score(record.ktail)
	return Sentence(member, enemy, kills, deaths, zone, true)
end

-- The line for a record of a member, or nil when it says nothing worth
-- one. A battleground hides whom a member kills while a death there names
-- the killer: line by line the feed would show the member only dying, with
-- scores blind to the kills of the match, and all at once when the match
-- ends, since nothing leaves a battleground before. So its kills and
-- deaths give no line, and the match gives one, from its scoreboard.
local function Line(guid, seq, record)
	if record.type ~= "K" and record.type ~= "D" and record.type ~= "M" then return nil end
	if record.type ~= "M" and record.bucket == "b" then return nil end
	local info = Stats.AuthorInfo(guid)
	local member = Coloured(info.name, info.class) .. Level(info.level)
	if record.type == "M" then return Words(member, record) end
	local agg = Stats.AuthorAggregate(guid)
	-- A version before 0.1.13 writes some deaths twice: the board counts the
	-- copy once, the feed gives it no line of its own.
	if record.type == "D" and seq and agg.repeats[seq] then return nil end
	return Words(member, record, function(tail) return Score(agg, tail) end)
end

local function Feed(guid, seq, record, source)
	if not Settings().killfeed or source ~= nil or type(record) ~= "table" then return end
	local line = Line(guid, seq, record)
	if not line then return end
	ns.Count("killfeed.lines")
	if not setupDone then
		Hold(line)                   -- the chat windows are not set up yet
		return
	end
	Deliver(line)
end

-- Once per session, after the client set its chat windows up: the lines
-- that waited go out. A tab the lines went to in an earlier session, and
-- that is not there now, was closed since, or the client is not done with
-- its chat windows: looked at again before anything is said, with or
-- without a line waiting.
local function Setup()
	if setupDone then return end
	setupDone = true
	if Settings().killfeed and InTab() and Expected() then
		local state, look = Survey()
		if state ~= "ok" then Doubt(state, look) end
	end
	Flush()
end

-- Ticked, or the second option changed: a line says where the lines will go,
-- in that place, and how to make the tab when it is wanted and missing.
function Killfeed.Enable()
	Settings().killfeed = true
	setupDone = true
	doubt = nil
	tab = InTab() and FindTab() or nil
	if InTab() then Used(tab and true or nil) end
	if tab then
		tab:AddMessage(L.KILLFEED_ON)
	else
		ns.Print(L.KILLFEED_ON_MAIN)
		if InTab() then Hint(true) end
	end
	Flush()
	return tab
end

-- The feed is on, wants its tab, and this character has none.
function Killfeed.NeedsTab()
	return Settings().killfeed == true and InTab() and FindTab() == nil
end

-- Asked for by the player: the addon opens the tab, then reloads the
-- interface at once. A chat window opened by an addon leaves the chat edit
-- box marked as the addon's until the session ends (see the top of this
-- file): the reload ends it there. Nothing is opened when the client has
-- no way to reload, or no chat window to spare.
function Killfeed.CreateTab()
	if FindTab() then return true end
	local reload = (type(C_UI) == "table" and Util.Fn(C_UI.Reload)) or Util.Fn(ReloadUI)
	if not Util.Fn(FCF_OpenNewWindow) or not reload then
		ns.Print(L.KILLFEED_CANNOT_CREATE:format(L.KILLFEED_TAB))
		return false
	end
	local ok, window = pcall(FCF_OpenNewWindow, L.KILLFEED_TAB, true)
	if ok and type(window) ~= "table" then
		-- Every chat window is in use: the client opened nothing.
		ns.Count("killfeed.tabNoWindow")
		ns.Print(L.KILLFEED_NO_WINDOW:format(L.KILLFEED_TAB))
		return false
	end
	if ok then
		Settings().killfeed, Settings().killfeedTab = true, true
		doubt = nil
		Used(true)
		ns.Count("killfeed.tabCreated")
		ns.Print(L.KILLFEED_CREATED:format(L.KILLFEED_TAB))
	else
		ns.Print(L.KILLFEED_CANNOT_CREATE:format(L.KILLFEED_TAB))
	end
	-- Opened, or failed half-way: either way this session's chat may carry
	-- the mark, and ends here.
	pcall(reload)
	return ok
end

-- The second option: the feed's tab, when the player has one, or the main
-- chat. The tab itself is the player's: it stays as it is.
function Killfeed.SetTab(value)
	Settings().killfeedTab = value and true or false
	if Settings().killfeed then Killfeed.Enable() end
end

-- Unticked: no more lines. The tab, if any, is the player's to close.
function Killfeed.Disable()
	Settings().killfeed = false
	tab, doubt = nil, nil
	held = {}
end

--------------------------------------------------------------------------------
-- A preview
--
-- How the feed reads on this client, without waiting for a kill: example
-- lines made by the code that makes the real ones, from kills and deaths
-- that never happened. Nothing is written to a journal, nothing is said to
-- the guild, no setting moves. The member is the character played, the
-- enemies are made up, and each line starts with a mark that says so. The
-- lines go where the feed's would: its tab when the player has one and
-- wants it, else the main chat. That tab is only looked for: a preview
-- settles nothing about it.
--------------------------------------------------------------------------------

local PREVIEW_LEVEL = 30         -- the member's level, when the client does not say
local PREVIEW_MAX = 60           -- no example above the highest level
-- Each example is a record that exists nowhere: `level` is the enemy's
-- against the member's (none: not read), `score` the member's kills on it
-- and its kills on the member.
local PREVIEW = {
	{ type = "K", vname = "Gruk Bonecrusher", vclass = "WARRIOR", level = -12, vcon = "T", score = { 1, 0 } },
	{ type = "K", vname = "Zaljin Darkspear", vclass = "SHAMAN", level = -5, vcon = "E", score = { 2, 0 } },
	{ type = "K", vname = "Morga Ashfang", vclass = "ROGUE", level = 0, vcon = "F", score = { 2, 1 } },
	{ type = "K", vname = "Durz Blackmaw", vclass = "HUNTER", level = 3, vcon = "D", score = { 1, 1 } },
	{ type = "K", vname = "Kessa Nightreed", vclass = "MAGE", level = 6, vcon = "I", score = { 1, 3 } },
	{ type = "K", vname = "Ulma Dreadhollow", vclass = "WARLOCK", vcon = "S", score = { 1, 4 } },
	{ type = "K", vname = "Hoggar Flintjaw", vclass = "PRIEST", level = 2, score = { 3, 0 } },
	{ type = "K", vname = "Vex Marrowind", vclass = "DRUID", score = { 1, 0 } },
	{ type = "D", kkind = "p", kname = "Durz Blackmaw", kclass = "HUNTER", level = 3, kcon = "D", score = { 1, 2 } },
	{ type = "D", kkind = "p", kname = "Ulma Dreadhollow", kclass = "WARLOCK", kcon = "S", score = { 1, 5 } },
	{ type = "D", kkind = "e", kname = "Snarl" },
	{ type = "M", instanceID = 1, hk = 12, kb = 3, deaths = 4, honor = 240 },
}

function Killfeed.Preview()
	if not ns.db then return false end
	local me = ns.Identity.me
	local info = type(me.guid) == "string" and Stats.AuthorInfo(me.guid) or {}
	local level = info.level or me.level
	local member = Coloured(me.name or info.name or "?", me.class or info.class) .. Level(level)
	local base = type(level) == "number" and level >= 1 and level or PREVIEW_LEVEL
	local mapID = Util.Position().mapID
	local target = InTab() and FindTab() or nil
	local function Say(text)
		if target then target:AddMessage(text) else ns.Print(text) end
	end
	-- The lines may land in a tab the player is not looking at.
	if target then ns.Print(L.KILLFEED_PREVIEW_IN_TAB:format(L.KILLFEED_TAB)) end
	Say(L.KILLFEED_PREVIEW)
	for _, sample in ipairs(PREVIEW) do
		local record = {}
		for key, value in pairs(sample) do record[key] = value end
		local near = sample.level and math.max(1, math.min(PREVIEW_MAX, base + sample.level)) or nil
		if record.type == "K" then
			record.vlevel, record.mapID = near, mapID
		elseif record.type == "D" then
			record.klevel, record.mapID = near, mapID
		end
		local line = Words(member, record, function()
			if sample.score then return sample.score[1], sample.score[2] end
			return nil
		end)
		if line then Say(("|cff999999[%s]|r %s"):format(L.KILLFEED_PREVIEW_TAG, line)) end
	end
	if not Settings().killfeed then Say(L.KILLFEED_PREVIEW_OFF) end
	ns.Count("killfeed.previews")
	return true
end

ns.Hook("RecordStored", function(guid, seq, record) Feed(guid, seq, record) end)
ns.Hook("RecordAdded", function(guid, seq, _, record, source) Feed(guid, seq, record, source) end)

local function ChatSetup()
	setups = setups + 1
	lastSetup = Util.Clock()
end

ns.On("UPDATE_CHAT_WINDOWS", function()
	ChatSetup()
	if chatReady then return end
	chatReady = true
	if entered then Util.After(SETUP_DELAY, "killfeed", Setup) end
end)

ns.On("UPDATE_FLOATING_CHAT_WINDOWS", ChatSetup)

ns.Hook("EnteringWorld", function()
	lastWorld = Util.Clock()
	if entered then return end
	entered = true
	Util.After(chatReady and SETUP_DELAY or SETUP_LATEST, "killfeed", Setup)
end)

ns.Hook("Debug", function()
	ns.Print(("kill feed: on %s, in its tab %s, tab %s, expected %s, in doubt %s, held %d, chat setups %d"):format(
		tostring(Settings().killfeed), tostring(InTab()), tab and tostring(tab:GetID()) or "none", tostring(Expected()),
		doubt and (doubt.state .. " x" .. doubt.looks) or "no", #held, setups))
	local trail = ns.db.debug.killfeed
	if type(trail) ~= "table" then return end
	for index = 1, #trail do
		ns.Print(("  %s %s"):format(Util.Stamp(trail[index].at, true), tostring(trail[index].text)))
	end
end)
