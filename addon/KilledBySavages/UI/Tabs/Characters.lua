local _, ns = ...

--------------------------------------------------------------------------------
-- Characters tab: one line per character, ranked.
--------------------------------------------------------------------------------

local Theme = ns.Theme
local Stats = ns.Stats
local ListView = ns.ListView
local L = ns.L

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
	Theme.TooltipLine(L.TOOLTIP_LAST_KILLS, Theme.Color("head"))
	for _, kill in ipairs(Stats.LastKills(data.guid, 5)) do
		local record = kill.record
		local victim = record.vname or L.EVENT_UNKNOWN_VICTIM
		local where = record.sub or Theme.ZoneName(record.mapID)
		Theme.TooltipDouble(("%s  %s"):format(EventLabel(record), victim), (where and (where .. "  ") or "") .. Theme.Time(record.t))
	end
	Theme.TooltipShow()
end

ns.UI.RegisterTab({
	key = "characters",
	title = L.TAB_CHARACTERS,
	Build = function(frame)
		frame.view = ListView.New(frame, {
			{ key = "rank", title = L.COL_RANK, width = 44, align = "RIGHT", muted = true },
			{ key = "name", title = L.COL_CHARACTER, width = 210, icon = "class", classColor = true, sort = "text" },
			{ key = "level", title = L.COL_LEVEL, width = 50, align = "RIGHT", muted = true, sort = "number" },
			{ key = "kills", title = L.COL_KILLS, width = 84, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "kb", title = L.COL_KB, width = 106, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "assists", title = L.COL_ASSISTS, width = 84, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "deaths", title = L.COL_DEATHS, width = 80, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "kd", title = L.COL_KD, width = 66, align = "RIGHT", sort = "number", format = Theme.Ratio },
		}, { emptyText = L.EMPTY_PLAYERS, tooltip = Tooltip })
		frame.view.panel:SetAllPoints(frame)
	end,
	Refresh = function(frame, period, bucket)
		frame.view:SetData(Stats.Characters(period, bucket))
	end,
})
