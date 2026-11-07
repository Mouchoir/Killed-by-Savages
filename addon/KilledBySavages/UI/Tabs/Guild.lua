local _, ns = ...

--------------------------------------------------------------------------------
-- Guild tab: the totals, the milestones reached, and the feed of the
-- latest kills and deaths.
--------------------------------------------------------------------------------

local Theme = ns.Theme
local Stats = ns.Stats
local ListView = ns.ListView
local L = ns.L

local function FeedRows(period, bucket)
	local rows = {}
	local current = Stats.CurrentWeek()
	for _, item in ipairs(Stats.Feed(300, bucket)) do
		local week = Stats.WeekIndex(item.t)
		local wanted = period == "all" or (period == "week" and week == current) or (period == "last" and week == current - 1)
		if wanted then
			local record = item.record
			local row = { t = item.t, time = Theme.Time(item.t), member = item.info.name, class = item.info.class, provisional = item.provisional }
			if record.type == "K" then
				row.event = ns.UI.EventLabel(record)
				row.enemy = record.vname or L.EVENT_UNKNOWN_VICTIM
				row.race = record.vrace
				row.enemyClass = ns.UI.ClassName(record.vclass)
			else
				row.event = L.EVENT_DEATH
				row.enemy = record.kname or "?"
				row.race = record.krace
				row.enemyClass = record.kkind == "e" and L.TOOLTIP_PET or ns.UI.ClassName(record.kclass)
			end
			row.zone = record.sub or Theme.ZoneName(record.mapID) or ""
			rows[#rows + 1] = row
		end
	end
	return rows
end

ns.UI.RegisterTab({
	key = "guild",
	title = L.TAB_GUILD,
	Build = function(frame)
		local totals = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		totals:SetPoint("TOPLEFT", 4, -2)
		totals:SetTextColor(Theme.Color("text"))
		frame.totals = totals
		local milestones = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		milestones:SetPoint("TOPRIGHT", -4, -4)
		milestones:SetTextColor(Theme.Color("muted"))
		frame.milestones = milestones
		local divider = Theme.Divider(frame, L.GUILD_FEED, 300)
		divider:SetPoint("TOP", 0, -24)
		frame.view = ListView.New(frame, {
			{ key = "time", title = L.COL_TIME, width = 80, muted = true, sort = "text" },
			{ key = "member", title = L.COL_MEMBER, width = 180, icon = "class", classColor = true, sort = "text" },
			{ key = "event", title = L.COL_EVENT, width = 90, muted = true, sort = "text" },
			{ key = "enemy", title = L.COL_ENEMY, width = 190, icon = "race", sort = "text" },
			{ key = "enemyClass", title = L.COL_CLASS, width = 90, muted = true },
			{ key = "zone", title = L.COL_ZONE, width = 130, muted = true, sort = "text" },
		}, { emptyText = L.EMPTY_FEED })
		frame.view.panel:SetPoint("TOPLEFT", 0, -46)
		frame.view.panel:SetPoint("BOTTOMRIGHT", 0, 0)
	end,
	Refresh = function(frame, period, bucket)
		local guild = Stats.Guild(period, bucket)
		frame.totals:SetText(L.GUILD_TOTALS:format(guild.kills, guild.kb, guild.assists, guild.deaths, Theme.Ratio(guild.kd)))
		local reached = {}
		local milestone = Stats.Milestone()
		for _, step in ipairs(Stats.MILESTONES) do
			if milestone.distinct >= step then reached[#reached + 1] = Theme.Number(step) end
		end
		frame.milestones:SetText(#reached > 0 and L.GUILD_MILESTONES_REACHED:format(table.concat(reached, ", ")) or L.GUILD_NO_MILESTONE)
		frame.view.sortKey = nil
		frame.view:SetData(FeedRows(period, bucket))
	end,
})
