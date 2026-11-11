local _, ns = ...

--------------------------------------------------------------------------------
-- Kill feed: one line per kill or death of the guild in the world, "X
-- killed Y (2-1)", and one per battleground match. The score is the kills of
-- the one named first on the other against the other's on them in the
-- world, from the member's own journal.
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
-- chat windows and adds lines to them.
--
-- In Forever's chat code (1.60.1) a closed window keeps its name, hidden
-- and out of the dock, and a docked tab behind another is hidden but still
-- docked: a window is the feed's tab when it carries the name and is in use.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local Stats = ns.Stats
local L = ns.L

local Killfeed = {}
ns.Killfeed = Killfeed

local HOLD_CAP = 50              -- lines kept until the chat windows are set up
local SETUP_DELAY = 3            -- seconds after the client set its chat windows up
local SETUP_LATEST = 10          -- seconds after entering the world, at the latest

local tab                        -- the feed's tab, once a line went to it
local held = {}                  -- lines waiting for the chat windows
local hinted = false             -- the player was told how to make the tab, this session
local chatReady = false          -- the client has set its chat windows up
local entered = false            -- the character is in the world
local setupDone = false          -- the chat windows can be looked at

local function Settings()
	return ns.db and ns.db.settings or {}
end

-- The lines go to the feed's tab when there is one, unless the player chose
-- the main chat.
local function InTab()
	return Settings().killfeedTab ~= false
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

-- In use: shown, or docked behind another tab.
local function Active(index)
	if Util.Fn(FCF_IsChatWindowIndexActive) then
		local ok, active = pcall(FCF_IsChatWindowIndexActive, index)
		if ok then return active and true or false end
	end
	if not Util.Fn(GetChatWindowInfo) then return false end
	local ok, _, _, _, _, _, _, shown, _, docked = pcall(GetChatWindowInfo, index)
	return (ok and (shown or docked)) and true or false
end

-- Still the feed's tab: the player may have closed or renamed it since.
local function Valid(window)
	if type(window) ~= "table" or not window.AddMessage or not window.GetID then return false end
	local index = window:GetID()
	return NameOf(index) == L.KILLFEED_TAB and Active(index)
end

local function FindTab()
	for index = 1, WindowCount() do
		local window = Window(index)
		if window and Valid(window) then return window end
	end
	return nil
end

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

-- The tab the lines were going to is gone: the player closed or renamed it.
-- That turns the feed off, said in the main chat (not at logout).
local function Closed(quiet)
	tab = nil
	held = {}
	Settings().killfeed = false
	ns.Count("killfeed.closedByPlayer")
	if not quiet then ns.Print(L.KILLFEED_CLOSED) end
	ns.Fire("SettingsChanged")
end

-- A line to the feed's tab, or to the main chat when the player has none or
-- chose it.
local function Deliver(line)
	if InTab() then
		if tab and not Valid(tab) then
			Closed(false)
			return
		end
		tab = tab or FindTab()
		if tab then
			tab:AddMessage(line)
			return
		end
		Hint()
	end
	ns.Print(line)
end

local function Hold(line)
	if #held >= HOLD_CAP then table.remove(held, 1) end
	held[#held + 1] = line
end

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

local function Sentence(first, second, mine, theirs, zone)
	local score = mine and ("%d-%d"):format(mine, theirs) or nil
	if score and zone then return L.KILLFEED_KILL:format(first, second, score, zone) end
	if score then return L.KILLFEED_KILL_NOZONE:format(first, second, score) end
	if zone then return L.KILLFEED_KILL_NOSCORE:format(first, second, zone) end
	return L.KILLFEED_KILL_BARE:format(first, second)
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
	local member = Coloured(info.name, info.class)
	if record.type == "M" then return MatchLine(member, record) end
	local agg = Stats.AuthorAggregate(guid)
	local zone = Theme.ZoneName(record.mapID) or record.sub
	if record.type == "K" then
		if not record.vname then
			return zone and L.KILLFEED_UNKNOWN:format(member, zone) or L.KILLFEED_UNKNOWN_NOZONE:format(member)
		end
		local kills, deaths = Score(agg, record.vtail)
		return Sentence(member, Coloured(record.vname, record.vclass), kills, deaths, zone)
	end
	-- A version before 0.1.13 writes some deaths twice: the board counts the
	-- copy once, the feed gives it no line of its own.
	if seq and agg.repeats[seq] then return nil end
	local enemy
	if record.kkind == "p" then
		enemy = Coloured(record.kname or "?", record.kclass)
	else
		enemy = (record.kname or "?") .. " (" .. L.TOOLTIP_PET .. ")"
	end
	local kills, deaths = Score(agg, record.ktail)
	-- The enemy comes first: its kills on the member, then the member's on it.
	return Sentence(enemy, member, deaths, kills, zone)
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
-- that waited go out.
local function Setup()
	if setupDone then return end
	setupDone = true
	local waiting = held
	held = {}
	for index = 1, #waiting do
		Deliver(waiting[index])
	end
end

-- Ticked, or the second option changed: a line says where the lines will go,
-- in that place, and how to make the tab when it is wanted and missing.
function Killfeed.Enable()
	Settings().killfeed = true
	setupDone = true
	tab = InTab() and FindTab() or nil
	if tab then
		tab:AddMessage(L.KILLFEED_ON)
		return tab
	end
	ns.Print(L.KILLFEED_ON_MAIN)
	if InTab() then Hint(true) end
	return nil
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
	tab = nil
	held = {}
end

ns.Hook("RecordStored", function(guid, seq, record) Feed(guid, seq, record) end)
ns.Hook("RecordAdded", function(guid, seq, _, record, source) Feed(guid, seq, record, source) end)

ns.On("UPDATE_CHAT_WINDOWS", function()
	if chatReady then return end
	chatReady = true
	if entered then Util.After(SETUP_DELAY, "killfeed", Setup) end
end)

ns.Hook("EnteringWorld", function()
	if entered then return end
	entered = true
	Util.After(chatReady and SETUP_DELAY or SETUP_LATEST, "killfeed", Setup)
end)

-- A tab the player closed with no line since still turns the feed off.
ns.Hook("Logout", function()
	if Settings().killfeed and InTab() and tab and not Valid(tab) then Closed(true) end
end)
