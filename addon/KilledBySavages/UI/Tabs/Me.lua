local _, ns = ...

--------------------------------------------------------------------------------
-- Me tab: my display name, my characters with the role each one plays and
-- which of them is my main, my own hunting board.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local Stats = ns.Stats
local ListView = ns.ListView
local Identity = ns.Identity
local Filters = ns.Filters
local L = ns.L

local CHARACTER_ROWS = 5          -- rows shown for my characters before scrolling

local function MyPlayerKey()
	return Identity.me.playerKey
end

-- The name the board shows for me: my alias, else my main character's.
local function ShownName()
	local alias = Identity.Alias()
	if alias then return alias end
	for _, row in ipairs(Stats.Players("all", "all", true)) do
		if row.me then return row.name end
	end
	return nil
end

-- Every character of mine the board knows, with or without a kill in the
-- period: each has a role to choose, and one of them is my main.
local function MyCharacters(period, bucket)
	local rows = {}
	local key = MyPlayerKey()
	for _, row in ipairs(Stats.Characters(period, bucket, true)) do
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
		frame.apply = apply
		-- A name takes effect as soon as it is chosen: Apply only wakes up while
		-- the box holds another name than the one in use.
		local function UpdateApply()
			apply:SetEnabled(Identity.CleanAlias(box:GetText()) ~= (Identity.Alias() or ""))
		end
		frame.UpdateApply = UpdateApply
		box:HookScript("OnTextChanged", UpdateApply)
		local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		hint:SetPoint("LEFT", apply, "RIGHT", 12, 0)
		hint:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
		hint:SetJustifyH("LEFT")
		hint:SetTextColor(Theme.Color("muted"))
		hint:SetText(L.ME_ALIAS_HINT)
		local summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		summary:SetPoint("TOPLEFT", 4, -34)
		summary:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -34)
		summary:SetJustifyH("LEFT")
		summary:SetWordWrap(false)
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
		-- The character I call my main; the one named again names none.
		local function SetMain(data)
			Identity.SetMain(data.guid ~= Identity.Main() and data.guid or nil)
			ns.UI.Refresh()
		end
		-- 752 px of columns: the three roles close the row, each a button of
		-- its own on every character of this account.
		local columns = {
			{ key = "name", title = L.COL_CHARACTER, width = 180, icon = "class", classColor = true, sort = "text" },
			{ key = "level", title = L.COL_LEVEL, width = 40, align = "RIGHT", muted = true },
			{ key = "kills", title = L.COL_KILLS, width = 54, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "kb", title = L.COL_KB_SHORT, width = 50, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "deaths", title = L.COL_DEATHS, width = 50, align = "RIGHT", sort = "number", format = Theme.Number },
			{ key = "main", title = "", width = 104, button = {
				text = L.ME_MAIN_SET, selectedText = L.ME_MAIN, again = true, onClick = SetMain,
				selected = function(data) return data.guid == Identity.Main() end,
				tip = function() return L.ME_MAIN, L.ME_MAIN_TIP end,
			} },
			{ key = "useName", title = "", width = 124, button = {
				text = L.ME_USE_NAME, selectedText = L.ME_NAME_IN_USE, onClick = UseName,
				selected = function(data) return data.name == ShownName() end,
			} },
		}
		-- The role each character plays: one of three, chosen by its player;
		-- the chosen one again removes it. It shows on the characters ranking
		-- and feeds its role filter. A character of another game account
		-- keeps its own: its buttons rest.
		for index, role in ipairs(Identity.ROLES) do
			columns[#columns + 1] = { key = "role" .. role, title = index == 1 and L.COL_ROLE or "", width = 50, button = {
				text = Filters.ROLE_TEXT[role], again = true,
				selected = function(data) return data.role == role end,
				enabled = function(data) return Identity.IsOwn(data.guid) end,
				onClick = function(data)
					Identity.SetRole(data.role ~= role and role or nil, data.guid)
					ns.UI.Refresh()
				end,
				tip = function(data)
					return Filters.ROLE_TEXT[role], Identity.IsOwn(data.guid) and L.ME_ROLE_TIP or L.ME_ROLE_ELSEWHERE
				end,
			} }
		end
		frame.view = ListView.New(frame, columns, { emptyText = L.EMPTY_ME, sortKey = "kills", tooltip = ns.UI.CharacterTooltip })
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
		frame.UpdateApply()
		local rows = MyCharacters(period, bucket)
		local sum = { kills = 0, kb = 0, deaths = 0 }
		for _, row in ipairs(rows) do
			sum.kills, sum.kb, sum.deaths = sum.kills + row.kills, sum.kb + row.kb, sum.deaths + row.deaths
		end
		local kd = sum.deaths > 0 and sum.kills / sum.deaths or sum.kills
		frame.summary:SetText(L.ME_SUMMARY:format(sum.kills, sum.kb, sum.kills - sum.kb, sum.deaths, Theme.Ratio(kd)))
		frame.view:SetEmptyText(ns.UI.EmptyText(L.EMPTY_ME, period))
		frame.view:SetData(rows)
		Util.Guard("me-boards", ns.UI.RefreshBoards, frame.boards, period, bucket)
	end,
})
