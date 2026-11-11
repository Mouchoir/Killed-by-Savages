local _, ns = ...

--------------------------------------------------------------------------------
-- Characters tab: one line per character, ranked. The bar above the list
-- finds a character by its name or its player's, and keeps the classes,
-- the levels and the roles chosen.
--------------------------------------------------------------------------------

local Theme = ns.Theme
local Stats = ns.Stats
local ListView = ns.ListView
local Filters = ns.Filters
local L = ns.L

-- A character answers to its name and to the name of its player.
local function Names(row)
	return { row.name, row.player }
end

local function EventLabel(record)
	if record.how == "kb" or record.how == "pet" then return L.EVENT_KB end
	if record.how == "bg" then return L.EVENT_BG end
	return L.EVENT_ASSIST
end
ns.UI.EventLabel = EventLabel

local function Tooltip(row, data)
	if not Theme.TooltipStart(row, data.name) then return end
	if data.provisional and data.provisional > 0 then
		Theme.TooltipLine(L.TOOLTIP_UNCONFIRMED:format(data.provisional), Theme.Color("disabled"))
	end
	if data.before and data.before > 0 then
		Theme.TooltipLine(L.TOOLTIP_BEFORE_ADDON:format(data.before), Theme.Color("muted"))
	end
	Theme.TooltipLine(L.TOOLTIP_LAST_KILLS, Theme.Color("head"))
	for _, kill in ipairs(Stats.LastKills(data.guid, 5)) do
		local record = kill.record
		local victim = record.vname or L.EVENT_UNKNOWN_VICTIM
		local where = record.sub or Theme.ZoneName(record.mapID)
		Theme.TooltipDouble(("%s  %s"):format(EventLabel(record), victim), (where and (where .. "  ") or "") .. Theme.Time(record.t))
	end
	Theme.TooltipShow()
end
ns.UI.CharacterTooltip = Tooltip

ns.UI.RegisterTab({
	key = "characters",
	title = L.TAB_CHARACTERS,
	Build = function(frame)
		frame.Fill = function()
			local rows = frame.rows or {}
			frame.filters:SetClasses(rows)
			local shown = Filters.Fill(frame.filters, frame.view, rows, L.EMPTY_PLAYERS)
			frame.filters:SetCount(#shown, #rows)
		end
		frame.filters = Filters.New(frame, { search = true, classes = true, levels = true, roles = true,
			searchTip = L.FILTER_SEARCH_TIP_CHARACTERS }, { names = Names }, function() frame.Fill() end)
		frame.filters.frame:SetPoint("TOPLEFT", 0, 0)
		frame.filters.frame:SetPoint("TOPRIGHT", 0, 0)
		-- 724 px of columns, as before the role had one: the name gave it room.
		frame.view = ListView.New(frame, {
			{ key = "rank", title = L.COL_RANK, width = 44, align = "RIGHT", muted = true },
			{ key = "name", title = L.COL_CHARACTER, width = 186, icon = "class", classColor = true, sort = "text" },
			{ key = "level", title = L.COL_LEVEL, width = 46, align = "RIGHT", muted = true, sort = "number" },
			{ key = "roleText", title = L.COL_ROLE, width = 58, muted = true, sort = "text", tip = L.COL_ROLE_TIP },
			{ key = "kills", title = L.COL_KILLS, width = 76, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "kb", title = L.COL_KB, width = 96, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "assists", title = L.COL_ASSISTS, width = 76, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "deaths", title = L.COL_DEATHS, width = 76, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "kd", title = L.COL_KD, width = 66, align = "RIGHT", sort = "number", format = Theme.Ratio },
		}, { emptyText = L.EMPTY_PLAYERS, tooltip = Tooltip })
		frame.view.panel:SetPoint("TOPLEFT", 0, -(Filters.HEIGHT + 6))
		frame.view.panel:SetPoint("BOTTOMRIGHT", 0, 0)
	end,
	Refresh = function(frame, period, bucket)
		-- The name each character's player shows under, as on the players tab.
		local players = {}
		for _, player in ipairs(Stats.Players("all", "all")) do players[player.key] = player.name end
		local rows = Stats.Characters(period, bucket)
		for _, row in ipairs(rows) do
			row.player = players[row.playerKey or ("char:" .. row.guid)]
			row.roleText = Filters.ROLE_TEXT[row.role] or ""
		end
		frame.rows = rows
		frame.Fill()
	end,
})
