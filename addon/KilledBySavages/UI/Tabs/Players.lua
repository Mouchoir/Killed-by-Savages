local _, ns = ...

--------------------------------------------------------------------------------
-- Players tab: every member's characters together, ranked. The home view.
--------------------------------------------------------------------------------

local Theme = ns.Theme
local Stats = ns.Stats
local ListView = ns.ListView
local L = ns.L

local function Tooltip(row, data)
	if not Theme.TooltipStart(row, data.name) then return end
	Theme.TooltipLine(L.TOOLTIP_CHARACTERS, Theme.Color("head"))
	for _, character in ipairs(data.characters or {}) do
		local r, g, b = Theme.ClassColor(character.class)
		Theme.TooltipDouble(character.name, L.TOOLTIP_KILLS_FORMAT:format(character.kills), r, g, b)
	end
	if data.before and data.before > 0 then
		Theme.TooltipLine(L.TOOLTIP_BEFORE_ADDON:format(data.before), Theme.Color("muted"))
	end
	Theme.TooltipShow()
end

ns.UI.RegisterTab({
	key = "players",
	title = L.TAB_PLAYERS,
	Build = function(frame)
		frame.view = ListView.New(frame, {
			{ key = "rank", title = L.COL_RANK, width = 44, align = "RIGHT", muted = true },
			{ key = "name", title = L.COL_PLAYER, width = 250, icon = "class", classColor = true, sort = "text" },
			{ key = "kills", title = L.COL_KILLS, width = 90, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "kb", title = L.COL_KB, width = 110, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "assists", title = L.COL_ASSISTS, width = 90, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "deaths", title = L.COL_DEATHS, width = 80, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "kd", title = L.COL_KD, width = 70, align = "RIGHT", sort = "number", format = Theme.Ratio },
		}, { emptyText = L.EMPTY_PLAYERS, tooltip = Tooltip })
		frame.view.panel:SetAllPoints(frame)
	end,
	Refresh = function(frame, period, bucket)
		frame.view:SetData(Stats.Players(period, bucket))
	end,
})
