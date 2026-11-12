local _, ns = ...

--------------------------------------------------------------------------------
-- Guild ranks to hand out
--
-- The guild's first rank (the guild master's, whatever the guild calls it)
-- sets a rule: the rank the main of a member must hold at least once it
-- runs the addon, the rank its other characters must hold, and from which
-- rank up the members see who falls short. The board marks those
-- characters and players for the ranks allowed to see, and for nobody else.
--
-- The rule travels in a guild message taken only from the character that
-- holds the first rank in the roster, the way a kill is taken only from its
-- author. It is kept per guild, with the names of the ranks it points at:
-- when a rank no longer carries the name it had, the rule rests until it
-- is set again, rather than point at another rank.
--
-- Nothing here is secret: every member reads every rank in the game's own
-- guild panel. Who sees the marks is a rule of display, read from the
-- viewer's rank each time it is asked, so a demotion takes them away and a
-- promotion brings them back with no memory of either.
--
-- A main is what its player says it is (see Identity). With one named, the
-- main is held to the expected rank and the player's other characters to
-- the rank of alts. With none, nothing is guessed: the player falls short
-- only when none of its characters holds the expected rank.
--------------------------------------------------------------------------------

local Util = ns.Util
local Identity = ns.Identity
local Stats = ns.Stats
local L = ns.L

local Ranks = {}
ns.Ranks = Ranks

local RESEND_GAP = 60            -- seconds between two sends of the rule to members who say hello
local LOGIN_SEND = 40            -- seconds after the login, once the hello is out
local MAX_FUTURE = 300           -- a rule dated further ahead than this is refused
local MAX_INDEX = 19
local NAME_MAX = 24

local index                      -- who falls short, by character and by player, until something changes
local lastSent = 0
local sendDue = false            -- a send waits for the gap since the last one to pass

local function Guild()
	return Identity.InGuild() and Identity.me.guild or nil
end

local function Stored()
	local guild = Guild()
	local rules = ns.db and ns.db.rules
	return guild and rules and rules[guild] or nil
end

-- A rank's name as the rule carries it.
local function Short(name)
	name = Util.Clean(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if #name > NAME_MAX then name = (Util.Cut(name, NAME_MAX)) end
	return name
end

local function NameAt(position)
	for _, rank in ipairs(Identity.Ranks()) do
		if rank.index == position then return rank.name end
	end
	return nil
end

-- A part of the rule still points at the rank it named. A name the client
-- does not give proves nothing either way.
local function Holds(part)
	if not part or part.name == "" then return true end
	local name = NameAt(part.index)
	return name == nil or Short(name) == part.name
end

-- The rule in force. Nothing when the guild has none; nothing and
-- "renamed" when a rank it names no longer carries that name.
function Ranks.Rule()
	local rule = Stored()
	if not rule or not rule.expected then return nil end
	if not (Holds(rule.expected) and Holds(rule.reroll) and Holds(rule.view)) then return nil, "renamed" end
	return rule
end

-- The rule as it is kept, in force or not: for the one who sets it.
function Ranks.Stored()
	return Stored()
end

function Ranks.IsMaster()
	return Guild() ~= nil and Identity.MyRankIndex() == 0
end

-- Whether the marks show for the character played now.
function Ranks.CanSee()
	local rule = Ranks.Rule()
	local mine = Identity.MyRankIndex()
	if not rule or not mine then return false end
	return mine <= rule.view.index
end

--------------------------------------------------------------------------------
-- Setting the rule, and telling the guild
--------------------------------------------------------------------------------

local function Part(position)
	return { index = position, name = Short(NameAt(position)) }
end

local function Encode(rule)
	if not rule.expected then return ("G^%d^-"):format(rule.at) end
	local reroll = rule.reroll
	return ("G^%d^%d^%s^%s^%s^%d^%s"):format(rule.at, rule.expected.index, rule.expected.name,
		reroll and tostring(reroll.index) or "-", reroll and reroll.name or "", rule.view.index, rule.view.name)
end

local function Send()
	local rule = Stored()
	if not rule or not Ranks.IsMaster() or not ns.Sync then return false end
	lastSent = Util.Now()
	return ns.Sync.Say("G", Encode(rule), 1)
end

local function Changed()
	index = nil
	ns.Fire("RanksChanged")
	ns.Fire("SettingsChanged")
end

-- The first rank sets the rule and tells the guild: the rank expected of a
-- main, the rank of alts (none: alts are not looked at), and the rank from
-- which the marks show. No expected rank removes the rule.
function Ranks.Set(expected, reroll, view)
	if not Ranks.IsMaster() then return false end
	local rule = { at = Util.Now(), by = Identity.me.tail }
	local previous = Stored()
	if previous and previous.at >= rule.at then rule.at = previous.at + 1 end
	if type(expected) == "number" then
		rule.expected = Part(expected)
		if type(reroll) == "number" and reroll ~= expected then rule.reroll = Part(reroll) end
		rule.view = Part(type(view) == "number" and view or 0)
	end
	ns.db.rules[Guild()] = rule
	ns.Count("ranks.set")
	Changed()
	Send()
	return true
end

local function ValidIndex(value)
	return type(value) == "number" and value >= 0 and value <= MAX_INDEX and value % 1 == 0
end

-- A rule heard on the guild channel: taken from the roster's first rank
-- only, and only when newer than the one held.
function Ranks.OnRule(sender, text)
	local member = Identity.Member(sender)
	if not member or member.rankIndex ~= 0 or not Guild() then
		ns.Count("ranks.notMaster")
		return false
	end
	local fields = {}
	for field in (text .. "^"):gmatch("([^%^]*)%^") do fields[#fields + 1] = field end
	local at = tonumber(fields[2])
	if not at or at > Util.Now() + MAX_FUTURE then
		ns.Count("ranks.bad")
		return false
	end
	local stored = Stored()
	if stored and stored.at >= at then return false end
	local rule = { at = at, by = member.tail }
	if fields[3] ~= "-" then
		local expected, reroll, view = tonumber(fields[3]), tonumber(fields[5]), tonumber(fields[7])
		if not (ValidIndex(expected) and ValidIndex(view)) then
			ns.Count("ranks.bad")
			return false
		end
		rule.expected = { index = expected, name = Short(fields[4]) }
		if ValidIndex(reroll) and reroll ~= expected then rule.reroll = { index = reroll, name = Short(fields[6]) } end
		rule.view = { index = view, name = Short(fields[8]) }
	end
	ns.db.rules[Guild()] = rule
	ns.Count("ranks.received")
	Changed()
	return true
end

--------------------------------------------------------------------------------
-- Who falls short
--------------------------------------------------------------------------------

local function Issue(character, kind, part)
	return {
		guid = character.guid, name = character.name, class = character.class, kind = kind,
		have = character.rankName, want = part.name ~= "" and part.name or NameAt(part.index) or "?",
	}
end

-- Every roster member the board holds a profile of, which is what running
-- the addon leaves, grouped by player and judged by the rule.
local function Build()
	local built = { byGuid = {}, byPlayer = {}, list = {} }
	local rule = Ranks.Rule()
	if not rule then return built end
	local players = {}
	for tail, member in pairs(Identity.roster.byTail) do
		local guid = member.guid or ("Player-" .. tail)
		local author = ns.db.authors[guid]
		if author and author.profile and type(member.rankIndex) == "number" then
			local info = Stats.AuthorInfo(guid)
			local key = info.playerKey or ("char:" .. guid)
			local player = players[key]
			if not player then
				player = { key = key, characters = {} }
				players[key] = player
			end
			player.characters[#player.characters + 1] = {
				guid = guid, tail = tail, name = info.name, class = info.class, rankIndex = member.rankIndex,
				rankName = type(member.rankName) == "string" and member.rankName or "?", main = info.main, at = info.statedAt or 0,
			}
			if guid == Identity.me.guid then player.me = true end
		end
	end
	for key, player in pairs(players) do
		-- The main its characters named last; mine is the one set here.
		local mainTail, wordAt, wordGuid
		for _, character in ipairs(player.characters) do
			if character.main ~= nil and (not wordAt or character.at > wordAt or (character.at == wordAt and character.guid < wordGuid)) then
				mainTail, wordAt, wordGuid = character.main, character.at, character.guid
			end
		end
		if player.me then mainTail = Util.Tail(Identity.Main()) end
		local main
		for _, character in ipairs(player.characters) do
			if mainTail and character.tail == mainTail then main = character end
		end
		local issues = {}
		if main then
			for _, character in ipairs(player.characters) do
				if character == main then
					if character.rankIndex > rule.expected.index then issues[#issues + 1] = Issue(character, "main", rule.expected) end
				elseif rule.reroll and character.rankIndex ~= rule.reroll.index then
					issues[#issues + 1] = Issue(character, "reroll", rule.reroll)
				end
			end
		else
			-- No main named: nothing is guessed. The player falls short when
			-- none of its characters holds the expected rank; those at the
			-- rank of alts are left alone unless it has no other.
			local reached, others = false, false
			for _, character in ipairs(player.characters) do
				if character.rankIndex <= rule.expected.index then reached = true end
				if not (rule.reroll and character.rankIndex == rule.reroll.index) then others = true end
			end
			if not reached then
				for _, character in ipairs(player.characters) do
					if not others or not (rule.reroll and character.rankIndex == rule.reroll.index) then
						issues[#issues + 1] = Issue(character, "nomain", rule.expected)
					end
				end
			end
		end
		if #issues > 0 then
			table.sort(issues, function(a, b) return a.name < b.name end)
			built.byPlayer[key] = issues
			for _, issue in ipairs(issues) do
				built.byGuid[issue.guid] = issue
				built.list[#built.list + 1] = issue
			end
		end
	end
	table.sort(built.list, function(a, b) return a.name < b.name end)
	return built
end

local function Index()
	if not index then index = Build() end
	return index
end

-- What a character falls short of, for a viewer allowed to see: nil when
-- it is fine, and nil for everyone else.
function Ranks.Issue(guid)
	if not Ranks.CanSee() then return nil end
	return Index().byGuid[guid]
end

-- The same for a player, by its key on the players' board: a list, or nil.
function Ranks.PlayerIssues(key)
	if not Ranks.CanSee() then return nil end
	return Index().byPlayer[key]
end

-- Every character that falls short, by name: empty for who may not see.
function Ranks.Issues()
	if not Ranks.CanSee() then return {} end
	return Index().list
end

-- One line saying what a character holds and what is expected of it.
function Ranks.Line(issue)
	local form = issue.kind == "main" and L.RANKS_ISSUE_MAIN or issue.kind == "reroll" and L.RANKS_ISSUE_REROLL or L.RANKS_ISSUE_NOMAIN
	return form:format(issue.name, issue.have, issue.want)
end

ns.Hook("RosterUpdated", function() index = nil end)
ns.Hook("StatsChanged", function() index = nil end)
ns.Hook("MainChanged", function() index = nil end)

-- The first rank says the rule again once logged in, and to members who
-- say hello, so one that was offline when it was set still gets it.
ns.Hook("Login", function() Util.After(LOGIN_SEND, "ranks-send", Send) end)
local function Resend()
	local wait = RESEND_GAP - (Util.Now() - lastSent)
	if wait <= 0 then
		Send()
	elseif not sendDue then
		sendDue = true
		Util.After(wait + 1, "ranks-send", function()
			sendDue = false
			Send()
		end)
	end
end
-- A hello, or the inventory every login sends even when its hello is not due.
ns.Hook("PeerSeen", Resend)
ns.Hook("InventoryHeard", Resend)

ns.Hook("Debug", function()
	local rule, why = Ranks.Rule()
	local stored = Stored()
	ns.Print(("ranks: my rank %s, master %s, can see %s, rule %s%s, %d falling short"):format(tostring(Identity.MyRankIndex()),
		tostring(Ranks.IsMaster()), tostring(Ranks.CanSee()),
		rule and ("expected %d, alts %s, seen from %d"):format(rule.expected.index, rule.reroll and tostring(rule.reroll.index) or "-", rule.view.index)
			or (stored and stored.expected and "kept but not in force" or "none"),
		why and (" (" .. why .. ")") or "", #Ranks.Issues()))
end)
