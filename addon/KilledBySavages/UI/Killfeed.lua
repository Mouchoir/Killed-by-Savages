local _, ns = ...

--------------------------------------------------------------------------------
-- Kill feed: one line per kill or death of the guild in a chat tab of its
-- own, "X killed Y (2-1)". The score is the kills of the one named first on
-- the other against the other's on them, from the member's own journal. The
-- tab is found by its name or opened when the option is on; when the client
-- has no chat window to spare, the lines go to the general chat.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local Stats = ns.Stats
local L = ns.L

local Killfeed = {}
ns.Killfeed = Killfeed

local tab                        -- the chat frame the lines go to
local lost = false               -- the tab we had is gone: the player closed it
local warned = false             -- the general chat was named as the fallback

local function Settings()
	return ns.db and ns.db.settings or {}
end

local function Coloured(name, classFile)
	if type(classFile) ~= "string" then return name end
	local r, g, b = Theme.ClassColor(classFile)
	return ("|cff%02x%02x%02x%s|r"):format(r * 255 + 0.5, g * 255 + 0.5, b * 255 + 0.5, name)
end

-- The chat window that carries the feed's name, if the player has one.
local function FindTab()
	if not Util.Fn(GetChatWindowInfo) then return nil end
	for index = 1, (tonumber(NUM_CHAT_WINDOWS) or 10) do
		local ok, name = pcall(GetChatWindowInfo, index)
		if ok and name == L.KILLFEED_TAB then
			local window = _G["ChatFrame" .. index]
			if type(window) == "table" and window.AddMessage then return window end
		end
	end
	return nil
end

-- Opens the tab, docked with the others, with nothing but our lines in it.
local function OpenTab()
	if not Util.Fn(FCF_OpenNewWindow) then return nil end
	if Util.Fn(InCombatLockdown) and InCombatLockdown() then return nil end
	local ok, window = pcall(FCF_OpenNewWindow, L.KILLFEED_TAB, true)
	if not ok or type(window) ~= "table" or not window.AddMessage then return nil end
	if Util.Fn(ChatFrame_RemoveAllMessageGroups) then pcall(ChatFrame_RemoveAllMessageGroups, window) end
	if Util.Fn(ChatFrame_RemoveAllChannels) then pcall(ChatFrame_RemoveAllChannels, window) end
	window:AddMessage(L.KILLFEED_ON)
	ns.Count("killfeed.tabOpened")
	return window
end

-- Whether the window still is the feed's tab: the player may have closed
-- or renamed it since.
local function Valid(window)
	if type(window) ~= "table" or not window.AddMessage then return false end
	if not (window.GetID and Util.Fn(GetChatWindowInfo)) then return true end
	local ok, name = pcall(GetChatWindowInfo, window:GetID())
	return ok and name == L.KILLFEED_TAB
end

-- At login and when the option is turned on: the tab, found or opened.
function Killfeed.Open()
	if not Settings().killfeed then return nil end
	lost = false
	tab = FindTab() or OpenTab()
	if not tab and not warned then
		warned = true
		ns.Print(L.KILLFEED_NO_TAB)
	end
	return tab
end

-- Where the next line goes. A tab the player closed is not opened again
-- before the next login; one that could not open yet (combat) is retried.
local function Target()
	if Valid(tab) then return tab end
	if tab then lost = true end
	tab = FindTab()
	if not tab and not lost then tab = OpenTab() end
	return tab
end

-- Kills of the member on the enemy, and the enemy's on the member.
local function Score(agg, tail)
	if not tail then return nil end
	local kills = agg.victims[tail] and agg.victims[tail].count or 0
	local deaths = agg.killers[tail] and agg.killers[tail].count or 0
	return kills, deaths
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
			return zone and L.ANNOUNCE_KILL_UNKNOWN:format(member, zone) or L.KILLFEED_UNKNOWN_NOZONE:format(member)
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
	local target = Target()
	if target then
		target:AddMessage(line)
	else
		ns.Print(line)
	end
	ns.Count("killfeed.lines")
end

ns.Hook("RecordStored", function(guid, _, record) Feed(guid, record) end)
ns.Hook("RecordAdded", function(guid, _, _, record, source) Feed(guid, record, source) end)
ns.Hook("Login", function()
	Util.Guard("killfeed", Killfeed.Open)
end)
