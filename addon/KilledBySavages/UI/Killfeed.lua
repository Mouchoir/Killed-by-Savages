local _, ns = ...

--------------------------------------------------------------------------------
-- Kill feed: one line per kill or death of the guild, "X killed Y (2-1)", in
-- a chat tab of its own. The score is the kills of the one named first on
-- the other against the other's on them, from the member's own journal.
--
-- Off by default. Ticked, the lines go to a chat tab named after the feed,
-- opened for it and docked with the others; the main chat only gets them
-- when the client has no chat window to spare. The option is account-wide
-- while chat tabs belong to each character: a character without the tab
-- gets it at login. Closing the tab turns the feed off; unticking the feed
-- closes the tab it opened.
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

local HOLD_CAP = 50              -- lines kept while the tab cannot open yet
local SETUP_DELAY = 3            -- seconds after the client set its chat windows up
local SETUP_LATEST = 10          -- seconds after entering the world, at the latest

local tab                        -- the chat frame the lines go to
local held = {}                  -- lines waiting for the tab
local warned = false             -- the main chat was named as the fallback
local chatReady = false          -- the client has set its chat windows up
local entered = false            -- the character is in the world
local setupDone = false          -- the login check ran
local afterCombat = false        -- the tab opens when the fight ends

local function Settings()
	return ns.db and ns.db.settings or {}
end

-- This character's own state, which keeps the index of the tab the feed
-- opened.
local function Mine()
	local me = ns.Identity and ns.Identity.me
	return me and me.guid and ns.Db.Character(me.guid) or nil
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

-- A tab found by its name becomes the feed's own, to close with it, when it
-- receives nothing but our lines: closing it then takes nothing from the
-- player.
local function Adopt(window)
	local mine = Mine()
	if not mine then return end
	local groups, channels = window.messageTypeList, window.channelList
	if (type(groups) == "table" and next(groups) ~= nil) or (type(channels) == "table" and next(channels) ~= nil) then return end
	mine.feedTab = window:GetID()
end

local function Selected()
	if not (Util.Fn(FCFDock_GetSelectedWindow) and GENERAL_CHAT_DOCK) then return nil end
	local ok, window = pcall(FCFDock_GetSelectedWindow, GENERAL_CHAT_DOCK)
	return ok and window or nil
end

-- Opens the tab, docked with the others. Without default channels the
-- client removes every message group from it, so it gets nothing but our
-- lines. Quiet, the tab the player was reading stays selected. Returns the
-- window, or nil and why not: "combat" or "full".
local function OpenTab(quiet)
	if not Util.Fn(FCF_OpenNewWindow) then return nil, "full" end
	if Util.Fn(InCombatLockdown) and InCombatLockdown() then return nil, "combat" end
	local previous = quiet and Selected() or nil
	local ok, window = pcall(FCF_OpenNewWindow, L.KILLFEED_TAB, true)
	if not ok then
		ns.Error("killfeed", window)
		return nil, "full"
	end
	-- Nothing back: every chat window is in use.
	if type(window) ~= "table" or not window.AddMessage or not window.GetID then return nil, "full" end
	if previous and previous ~= window and Util.Fn(FCFDock_SelectWindow) then
		pcall(FCFDock_SelectWindow, GENERAL_CHAT_DOCK, previous)
	end
	local mine = Mine()
	if mine then mine.feedTab = window:GetID() end
	window:AddMessage(L.KILLFEED_ON)
	ns.Count("killfeed.tabOpened")
	return window
end

-- Closes the tab the feed opened on this character. In combat it waits for
-- the fight to end, or the next login.
local function CloseTab()
	local mine = Mine()
	local index = mine and mine.feedTab
	if not index then return end
	if Util.Fn(InCombatLockdown) and InCombatLockdown() then return end
	mine.feedTab = nil
	local window = Window(index)
	if not (window and NameOf(index) == L.KILLFEED_TAB and Active(index) and Util.Fn(FCF_Close)) then return end
	local ok, problem = pcall(FCF_Close, window)
	if ok then ns.Count("killfeed.tabClosed") else ns.Error("killfeed", problem) end
end

local function Hold(line)
	if #held >= HOLD_CAP then table.remove(held, 1) end
	held[#held + 1] = line
end

-- The feed's tab, found or opened, with the lines that waited for it.
-- Returns the window, or nil and why not.
local function Open(quiet)
	local window = FindTab()
	if window then
		Adopt(window)
	else
		local why
		window, why = OpenTab(quiet)
		if not window then
			afterCombat = why == "combat"
			if why == "full" then
				if not warned then
					warned = true
					ns.Print(L.KILLFEED_NO_TAB)
				end
				for index = 1, #held do
					ns.Print(held[index])
				end
				held = {}
			end
			return nil, why
		end
	end
	afterCombat = false
	tab = window
	for index = 1, #held do
		window:AddMessage(held[index])
	end
	held = {}
	return window
end

-- The tab the feed had is gone: the player closed or renamed it. That turns
-- the feed off, said in the main chat.
local function Closed(quiet)
	tab = nil
	held = {}
	afterCombat = false
	local mine = Mine()
	if mine then mine.feedTab = nil end
	Settings().killfeed = false
	ns.Count("killfeed.closedByPlayer")
	if not quiet then ns.Print(L.KILLFEED_CLOSED) end
	ns.Fire("SettingsChanged")
end

-- Where the next line goes: the tab, or nil and why not.
local function Target()
	if Valid(tab) then return tab end
	if tab then
		Closed(false)
		return nil, "closed"
	end
	return Open(true)
end

-- Kills of the member on the enemy, and the enemy's on the member.
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

-- The line for a kill or death of a member, or nil when the record says
-- nothing worth one: a battleground HK names nobody, its match is on the
-- board.
local function Line(guid, record)
	if record.type ~= "K" and record.type ~= "D" then return nil end
	if record.type == "K" and record.bucket == "b" then return nil end
	local info = Stats.AuthorInfo(guid)
	local agg = Stats.AuthorAggregate(guid)
	local member = Coloured(info.name, info.class)
	local zone = Theme.ZoneName(record.mapID) or record.sub
	if record.type == "K" then
		if not record.vname then
			return zone and L.KILLFEED_UNKNOWN:format(member, zone) or L.KILLFEED_UNKNOWN_NOZONE:format(member)
		end
		local kills, deaths = Score(agg, record.vtail)
		return Sentence(member, Coloured(record.vname, record.vclass), kills, deaths, zone)
	end
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

local function Feed(guid, record, source)
	if not Settings().killfeed or source ~= nil or type(record) ~= "table" then return end
	local line = Line(guid, record)
	if not line then return end
	ns.Count("killfeed.lines")
	if not setupDone then
		Hold(line)                   -- the chat windows are not set up yet
		return
	end
	local target, why = Target()
	if target then
		target:AddMessage(line)
	elseif why == "combat" then
		Hold(line)
	elseif why == "full" then
		ns.Print(line)
	end
end

-- Once per session, after the client set its chat windows up: the tab
-- found or opened when the feed is on. When it is off, the tab it opened
-- here closes (the feed was turned off on another character).
local function Setup()
	if setupDone then return end
	setupDone = true
	if Settings().killfeed then
		Open(true)
	else
		held = {}
		CloseTab()
	end
end

-- Ticked: the tab opens now, selected, so the player sees where the lines go.
function Killfeed.Enable()
	Settings().killfeed = true
	setupDone = true
	warned = false
	local window, why = Open(false)
	if not window and why == "combat" then ns.Print(L.KILLFEED_AFTER_COMBAT) end
	return window
end

-- Unticked: no more lines, and the tab the feed opened closes.
function Killfeed.Disable()
	Settings().killfeed = false
	tab = nil
	held = {}
	afterCombat = false
	CloseTab()
end

ns.Hook("RecordStored", function(guid, _, record) Feed(guid, record) end)
ns.Hook("RecordAdded", function(guid, _, _, record, source) Feed(guid, record, source) end)

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

-- After a fight: the tab that had to wait opens, the one to close closes.
ns.On("PLAYER_REGEN_ENABLED", function()
	if not setupDone then return end
	if Settings().killfeed then
		if afterCombat then Open(true) end
	else
		CloseTab()
	end
end)

-- A tab the player closed with no line since still turns the feed off.
ns.Hook("Logout", function()
	if Settings().killfeed and tab and not Valid(tab) then Closed(true) end
end)
