local _, ns = ...

--------------------------------------------------------------------------------
-- Me tab: my display name, my characters, my own hunting board.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local Stats = ns.Stats
local ListView = ns.ListView
local Identity = ns.Identity
local L = ns.L

local CHARACTER_ROWS = 5          -- rows shown for my characters before scrolling

local function MyPlayerKey()
	return Identity.me.playerKey
end

-- The name the board shows for me: my alias, else my main character's.
local function ShownName()
	local alias = Identity.Alias()
	if alias then return alias end
	for _, row in ipairs(Stats.Players("all", "all")) do
		if row.me then return row.characters[1] and row.characters[1].name or row.name end
	end
	return nil
end

local function MyCharacters(period, bucket)
	local rows = {}
	local key = MyPlayerKey()
	for _, row in ipairs(Stats.Characters(period, bucket)) do
		if row.playerKey == key or row.guid == Identity.me.guid then rows[#rows + 1] = row end
	end
	return rows
end

ns.UI.RegisterTab({
	key = "me",
	title = L.TAB_ME,
	Build = function(frame)
		local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		label:SetPoint("TOPLEFT", 4, -4)
		label:SetTextColor(Theme.Color("title"))
		label:SetText(L.ME_ALIAS_LABEL)
		local box = Theme.TryCreate("EditBox", nil, frame, { "InputBoxTemplate" })
		box:SetPoint("LEFT", label, "RIGHT", 12, 0)
		box:SetSize(200, 24)
		box:SetAutoFocus(false)
		box:SetMaxLetters(24)
		if box.SetTextInsets then box:SetTextInsets(6, 6, 0, 0) end
		box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		box:SetScript("OnEnterPressed", function(self)
			Identity.SetAlias(self:GetText())
			self:ClearFocus()
			ns.UI.Refresh()
		end)
		frame.box = box
		local apply = Theme.TryCreate("Button", nil, frame, { "UIPanelButtonTemplate" })
		apply:SetPoint("LEFT", box, "RIGHT", 8, 0)
		apply:SetSize(100, 22)
		apply:SetText(L.ME_ALIAS_APPLY)
		apply:SetScript("OnClick", function()
			Identity.SetAlias(box:GetText())
			box:ClearFocus()
			ns.UI.Refresh()
		end)
		local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		hint:SetPoint("LEFT", apply, "RIGHT", 12, 0)
		hint:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
		hint:SetJustifyH("LEFT")
		hint:SetTextColor(Theme.Color("muted"))
		hint:SetText(L.ME_ALIAS_HINT)
		local summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		summary:SetPoint("TOPLEFT", 4, -34)
		summary:SetTextColor(Theme.Color("text"))
		frame.summary = summary

		-- My characters across the top (a few rows), my two hunting boards
		-- side by side below, as wide as the hunt tab's so their columns fit.
		-- A character's name as my display name, in one click.
		local function UseName(data)
			Identity.SetAlias(data.name)
			box:SetText(Identity.Alias() or "")
			box:ClearFocus()
			ns.UI.Refresh()
		end
		frame.view = ListView.New(frame, {
			{ key = "name", title = L.COL_CHARACTER, width = 220, icon = "class", classColor = true, sort = "text" },
			{ key = "level", title = L.COL_LEVEL, width = 46, align = "RIGHT", muted = true },
			{ key = "kills", title = L.COL_KILLS, width = 64, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "kb", title = L.COL_KB_SHORT, width = 60, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "deaths", title = L.COL_DEATHS, width = 60, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "useName", title = "", width = 140, button = {
				text = L.ME_USE_NAME, onClick = UseName,
				selected = function(data) return data.name == ShownName() end,
			} },
		}, { emptyText = L.EMPTY_ME, sortKey = "kills", tooltip = ns.UI.CharacterTooltip })
		frame.view.panel:SetPoint("TOPLEFT", 0, -56)
		frame.view.panel:SetPoint("TOPRIGHT", 0, -56)
		frame.view.panel:SetHeight(Theme.ROW * CHARACTER_ROWS + ListView.HEADER + 12)

		local boards = CreateFrame("Frame", nil, frame)
		boards:SetPoint("TOPLEFT", frame.view.panel, "BOTTOMLEFT", 0, -8)
		boards:SetPoint("BOTTOMRIGHT", 0, 0)
		frame.boards = boards
		ns.UI.BuildBoards(boards, function() return { playerKey = MyPlayerKey() } end)
	end,
	Refresh = function(frame, period, bucket)
		if not frame.box:HasFocus() then frame.box:SetText(Identity.Alias() or "") end
		local rows = MyCharacters(period, bucket)
		local sum = { kills = 0, kb = 0, deaths = 0 }
		for _, row in ipairs(rows) do
			sum.kills, sum.kb, sum.deaths = sum.kills + row.kills, sum.kb + row.kb, sum.deaths + row.deaths
		end
		local kd = sum.deaths > 0 and sum.kills / sum.deaths or sum.kills
		frame.summary:SetText(L.ME_SUMMARY:format(sum.kills, sum.kb, sum.kills - sum.kb, sum.deaths, Theme.Ratio(kd)))
		frame.view:SetData(rows)
		Util.Guard("me-boards", ns.UI.RefreshBoards, frame.boards, period, bucket)
	end,
})
