local _, ns = ...

--------------------------------------------------------------------------------
-- Hunt tab: the enemies the guild kills the most, and those who kill us.
--------------------------------------------------------------------------------

local Theme = ns.Theme
local Stats = ns.Stats
local ListView = ns.ListView
local L = ns.L

local function VictimRows(period, bucket, filter)
	local rows = {}
	for _, victim in ipairs(Stats.Victims(period, bucket, filter, 300)) do
		rows[#rows + 1] = {
			name = victim.name or victim.tail, race = victim.race, class = ns.UI.ClassName(victim.class),
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
			count = killer.count, victims = killer.victimCount, last = Theme.Time(killer.lastAt),
		}
	end
	return rows
end

local function BuildBoards(frame, filterFn)
	local half = (frame:GetWidth() > 0 and frame:GetWidth() or 788) / 2
	local leftTitle = Theme.Divider(frame, L.HUNT_MOST_KILLED, half - 12)
	leftTitle:SetPoint("TOPLEFT", 0, -2)
	-- Each board is half the tab wide: 352 px of columns fit beside its
	-- scrollbar in the 820 px window.
	frame.victims = ListView.New(frame, {
		{ key = "name", title = L.COL_ENEMY, width = 158, icon = "race", sort = "text" },
		{ key = "class", title = L.COL_CLASS, width = 62, muted = true },
		{ key = "count", title = L.COL_KILLS, width = 50, align = "RIGHT", sort = "number", format = Theme.Number },
		{ key = "kb", title = L.COL_KB_SHORT, width = 46, align = "RIGHT", sort = "number", format = Theme.Number },
		{ key = "by", title = L.COL_BY, width = 36, align = "RIGHT", sort = "number", format = Theme.Number },
	}, { emptyText = L.EMPTY_HUNT, sortKey = "count" })
	frame.victims.panel:SetPoint("TOPLEFT", 0, -24)
	frame.victims.panel:SetPoint("BOTTOMRIGHT", frame, "BOTTOM", -6, 0)
	local rightTitle = Theme.Divider(frame, L.HUNT_KILLERS, half - 12)
	rightTitle:SetPoint("TOPRIGHT", 0, -2)
	frame.killers = ListView.New(frame, {
		{ key = "name", title = L.COL_ENEMY, width = 170, icon = "race", sort = "text" },
		{ key = "class", title = L.COL_CLASS, width = 62, muted = true },
		{ key = "count", title = L.COL_DEATHS, width = 56, align = "RIGHT", sort = "number", format = Theme.Number },
		{ key = "victims", title = L.COL_VICTIMS, width = 56, align = "RIGHT", sort = "number", format = Theme.Number },
	}, { emptyText = L.EMPTY_KILLERS, sortKey = "count" })
	frame.killers.panel:SetPoint("TOPLEFT", frame, "TOP", 6, -24)
	frame.killers.panel:SetPoint("BOTTOMRIGHT", 0, 0)
	frame.filterFn = filterFn
end
ns.UI.BuildBoards = BuildBoards

local function RefreshBoards(frame, period, bucket)
	local filter = frame.filterFn and frame.filterFn() or nil
	frame.victims:SetData(VictimRows(period, bucket, filter))
	frame.killers:SetData(KillerRows(period, bucket, filter))
end
ns.UI.RefreshBoards = RefreshBoards

ns.UI.RegisterTab({
	key = "hunt",
	title = L.TAB_HUNT,
	Build = function(frame) BuildBoards(frame, nil) end,
	Refresh = RefreshBoards,
})
