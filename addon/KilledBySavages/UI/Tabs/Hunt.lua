local _, ns = ...

--------------------------------------------------------------------------------
-- Hunt tab: the enemies the guild kills the most, and those who kill us.
-- One bar above both boards finds an enemy by its name and keeps the
-- classes chosen. No level there: a death does not say its killer's.
--------------------------------------------------------------------------------

local Theme = ns.Theme
local Stats = ns.Stats
local ListView = ns.ListView
local Filters = ns.Filters
local L = ns.L

local function VictimRows(period, bucket, filter)
	local rows = {}
	for _, victim in ipairs(Stats.Victims(period, bucket, filter, 300)) do
		rows[#rows + 1] = {
			name = victim.name or victim.tail, race = victim.race, class = ns.UI.ClassName(victim.class), classFile = victim.class,
			count = victim.count, kb = victim.kb, by = victim.byCount, last = Theme.Time(victim.lastAt),
		}
	end
	return rows
end

local function KillerRows(period, bucket, filter)
	local rows = {}
	for _, killer in ipairs(Stats.Killers(period, bucket, filter, 300)) do
		rows[#rows + 1] = {
			name = killer.name or killer.key, race = killer.race,
			class = killer.kind == "e" and L.TOOLTIP_PET or ns.UI.ClassName(killer.class),
			classFile = killer.kind ~= "e" and killer.class or nil,
			count = killer.count, victims = killer.victimCount, last = Theme.Time(killer.lastAt),
		}
	end
	return rows
end

-- Both boards through the bar, when the tab has one.
local function ShowBoards(frame)
	local victims, killers = frame.victimRows or {}, frame.killerRows or {}
	local bar = frame.filters
	if not bar then
		frame.victims:SetData(victims)
		frame.killers:SetData(killers)
		return
	end
	local all = {}
	for _, row in ipairs(victims) do all[#all + 1] = row end
	for _, row in ipairs(killers) do all[#all + 1] = row end
	bar:SetClasses(all)
	local shownVictims = Filters.Fill(bar, frame.victims, victims, L.EMPTY_HUNT)
	local shownKillers = Filters.Fill(bar, frame.killers, killers, L.EMPTY_KILLERS)
	bar:SetCount(#shownVictims + #shownKillers, #all)
end

-- filterFn narrows the boards to a player or a character (the Me tab);
-- searchable puts the bar above them (the Hunt tab).
local function BuildBoards(frame, filterFn, searchable)
	local top = 0
	if searchable then
		frame.filters = Filters.New(frame, { search = true, classes = true, searchTip = L.FILTER_SEARCH_TIP_ENEMIES },
			{ class = function(row) return row.classFile end }, function() ShowBoards(frame) end)
		frame.filters.frame:SetPoint("TOPLEFT", 0, 0)
		frame.filters.frame:SetPoint("TOPRIGHT", 0, 0)
		top = Filters.HEIGHT + 6
	end
	local half = (frame:GetWidth() > 0 and frame:GetWidth() or 788) / 2
	local leftTitle = Theme.Divider(frame, L.HUNT_MOST_KILLED, half - 12)
	leftTitle:SetPoint("TOPLEFT", 0, -2 - top)
	-- Each board is half the tab wide: 352 px of columns fit beside its
	-- scrollbar in the 820 px window.
	frame.victims = ListView.New(frame, {
		{ key = "name", title = L.COL_ENEMY, width = 158, icon = "race", sort = "text" },
		{ key = "class", title = L.COL_CLASS, width = 62, muted = true, classColor = "classFile" },
		{ key = "count", title = L.COL_KILLS, width = 46, align = "RIGHT", sort = "number", format = Theme.Number, tip = L.COL_HUNT_KILLS_TIP },
		{ key = "kb", title = L.COL_KB_SHORT, width = 42, align = "RIGHT", sort = "number", format = Theme.Number },
		{ key = "by", title = L.COL_BY, width = 44, align = "RIGHT", sort = "number", format = Theme.Number, tip = L.COL_BY_TIP },
	}, { emptyText = L.EMPTY_HUNT, sortKey = "count" })
	frame.victims.panel:SetPoint("TOPLEFT", 0, -24 - top)
	frame.victims.panel:SetPoint("BOTTOMRIGHT", frame, "BOTTOM", -6, 0)
	local rightTitle = Theme.Divider(frame, L.HUNT_KILLERS, half - 12)
	rightTitle:SetPoint("TOPRIGHT", 0, -2 - top)
	frame.killers = ListView.New(frame, {
		{ key = "name", title = L.COL_ENEMY, width = 170, icon = "race", sort = "text" },
		{ key = "class", title = L.COL_CLASS, width = 62, muted = true, classColor = "classFile" },
		{ key = "count", title = L.COL_DEATHS, width = 56, align = "RIGHT", sort = "number", format = Theme.Number, tip = L.COL_HUNT_DEATHS_TIP },
		{ key = "victims", title = L.COL_VICTIMS, width = 56, align = "RIGHT", sort = "number", format = Theme.Number, tip = L.COL_VICTIMS_TIP },
	}, { emptyText = L.EMPTY_KILLERS, sortKey = "count" })
	frame.killers.panel:SetPoint("TOPLEFT", frame, "TOP", 6, -24 - top)
	frame.killers.panel:SetPoint("BOTTOMRIGHT", 0, 0)
	frame.filterFn = filterFn
end
ns.UI.BuildBoards = BuildBoards

local function RefreshBoards(frame, period, bucket)
	local filter = frame.filterFn and frame.filterFn() or nil
	frame.victimRows = VictimRows(period, bucket, filter)
	frame.killerRows = KillerRows(period, bucket, filter)
	ShowBoards(frame)
end
ns.UI.RefreshBoards = RefreshBoards

ns.UI.RegisterTab({
	key = "hunt",
	title = L.TAB_HUNT,
	Build = function(frame) BuildBoards(frame, nil, true) end,
	Refresh = RefreshBoards,
})
