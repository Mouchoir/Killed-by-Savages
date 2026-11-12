local _, ns = ...

--------------------------------------------------------------------------------
-- Players tab: every member's characters together, ranked. The home view.
-- A player is the name it chose, with no class to show: its characters
-- are in the tooltip. The search box finds a player by its name or by the
-- name of any of its characters. For the members the guild lets see it, a
-- mark before the rank says one of its characters lacks the guild rank
-- expected, and a button keeps only those players: the ranks to give.
--------------------------------------------------------------------------------

local Theme = ns.Theme
local Stats = ns.Stats
local ListView = ns.ListView
local Filters = ns.Filters
local L = ns.L

-- The names a player answers to: the one shown, and its characters'.
local function Names(row)
	local names = { row.name }
	for _, character in ipairs(row.characters or {}) do
		names[#names + 1] = character.name
	end
	return names
end

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
	if data.rankIssues then
		Theme.TooltipLine(L.RANKS_TOOLTIP, Theme.Color("head"))
		for _, issue in ipairs(data.rankIssues) do
			Theme.TooltipLine(ns.Ranks.Line(issue), Theme.Color("warn"))
		end
	end
	Theme.TooltipShow()
end

ns.UI.RegisterTab({
	key = "players",
	title = L.TAB_PLAYERS,
	Build = function(frame)
		frame.Fill = function()
			local rows = frame.rows or {}
			local shown = Filters.Fill(frame.filters, frame.view, rows, ns.UI.EmptyText(L.EMPTY_PLAYERS, frame.period))
			frame.filters:SetCount(#shown, #rows)
		end
		frame.filters = Filters.New(frame, { search = true, ranks = true, searchTip = L.FILTER_SEARCH_TIP_PLAYERS }, { names = Names },
			function()
				-- The ranks to give are asked of every player, not only of those
				-- with a kill in the period: the rows are built again.
				if (frame.filters.ranks == true) ~= (frame.everyone == true) then
					ns.UI.Refresh()
				else
					frame.Fill()
				end
			end)
		frame.filters.frame:SetPoint("TOPLEFT", 0, 0)
		frame.filters.frame:SetPoint("TOPRIGHT", 0, 0)
		frame.view = ListView.New(frame, {
			{ key = "rank", title = L.COL_RANK, width = 44, align = "RIGHT", muted = true, mark = "rankMark" },
			{ key = "name", title = L.COL_PLAYER, width = 250, sort = "text" },
			{ key = "kills", title = L.COL_KILLS, width = 90, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "kb", title = L.COL_KB, width = 110, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "assists", title = L.COL_ASSISTS, width = 90, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "deaths", title = L.COL_DEATHS, width = 80, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "kd", title = L.COL_KD, width = 70, align = "RIGHT", sort = "number", format = Theme.Ratio },
		}, { emptyText = L.EMPTY_PLAYERS, tooltip = Tooltip })
		frame.view.panel:SetPoint("TOPLEFT", 0, -(Filters.HEIGHT + 6))
		frame.view.panel:SetPoint("BOTTOMRIGHT", 0, 0)
	end,
	Refresh = function(frame, period, bucket)
		-- The button and the marks come and go with the right to see them,
		-- read from the rank held now.
		local sees = ns.Ranks.CanSee()
		frame.filters:SetRanksShown(sees)
		frame.everyone = frame.filters.ranks == true
		local rows = Stats.Players(period, bucket, frame.everyone)
		for _, row in ipairs(rows) do
			row.rankIssues = ns.Ranks.PlayerIssues(row.key)
			row.rankMark = row.rankIssues ~= nil
		end
		frame.rows, frame.period = rows, period
		frame.Fill()
	end,
})
