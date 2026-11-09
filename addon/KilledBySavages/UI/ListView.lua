local _, ns = ...

--------------------------------------------------------------------------------
-- List view
--
-- A leather panel with a band of sortable column headers and dense rows of
-- 22 px. The rows come from the client's ScrollBox when it has one (the
-- 12.x list that SimpleGuildHerald and SkillUp Forever use on this client);
-- otherwise a fixed pool of rows scrolled by the mouse wheel.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local L = ns.L

local ListView = {}
ns.ListView = ListView

local ROW = Theme.ROW
local HEADER = 22
local GUTTER = 18
ListView.HEADER = HEADER

local function HasScrollBox()
	return Util.Fn(CreateScrollBoxListLinearView) ~= nil and Util.Fn(CreateDataProvider) ~= nil
		and type(ScrollUtil) == "table" and Util.Fn(ScrollUtil.InitScrollBoxListWithScrollBar) ~= nil
end

-- Column: { key, title, width, align = "LEFT"|"RIGHT", sort = "number"|"text", icon = "class"|"race",
--   classColor = true (the row's class) or the row field holding the class file to colour the cell with,
--   tip = a line under the header's name when the mouse rests on it,
--   button = { text, onClick = fn(data), selected = fn(data) }: an action on the row's item, a dark
--   button lit and inert on the rows where it is already done }
-- fill(row, data) is the caller's; rows carry one FontString per column.
function ListView.New(parent, columns, options)
	options = options or {}
	local view = { columns = columns, rows = {}, data = {}, sortKey = options.sortKey, sortDesc = options.sortDesc ~= false }
	local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	Theme.Panel(panel, 12, 3)
	Theme.Parchment(panel, 0.14)
	-- Whatever would run past the panel stays inside it, never over a neighbour.
	if panel.SetClipsChildren then panel:SetClipsChildren(true) end
	view.panel = panel

	-- Column header band
	local band = CreateFrame("Frame", nil, panel)
	band:SetPoint("TOPLEFT", 4, -4)
	band:SetPoint("TOPRIGHT", -4, -4)
	band:SetHeight(HEADER)
	local bandBg = band:CreateTexture(nil, "BACKGROUND")
	bandBg:SetAllPoints()
	bandBg:SetColorTexture(unpack(Theme.COLORS.band))
	view.band = band
	view.headers = {}
	local x = 6
	for index, column in ipairs(columns) do
		local header = CreateFrame("Button", nil, band)
		header:SetPoint("TOPLEFT", x, 0)
		header:SetSize(column.width, HEADER)
		local label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint(column.align == "RIGHT" and "RIGHT" or "LEFT", column.align == "RIGHT" and -4 or 4, 0)
		label:SetText(column.title)
		label:SetTextColor(Theme.Color("title"))
		header.label = label
		header.column = column
		if column.sort then
			Theme.Highlight(header)
			header:SetScript("OnClick", function()
				if view.sortKey == column.key then
					view.sortDesc = not view.sortDesc
				else
					view.sortKey = column.key
					view.sortDesc = column.sort == "number"
				end
				view:Refresh()
			end)
		end
		if column.tip then
			header:SetScript("OnEnter", function(self)
				if Theme.TooltipStart(self, column.title) then
					Theme.TooltipLine(column.tip)
					Theme.TooltipShow()
				end
			end)
			header:SetScript("OnLeave", function() Theme.TooltipHide() end)
		end
		view.headers[index] = header
		x = x + column.width
	end

	-- Empty state
	local empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	empty:SetPoint("TOP", band, "BOTTOM", 0, -40)
	empty:SetPoint("LEFT", panel, "LEFT", 24, 0)
	empty:SetPoint("RIGHT", panel, "RIGHT", -24, 0)
	empty:SetJustifyH("CENTER")
	empty:SetWordWrap(true)
	empty:SetText(options.emptyText or L.LIST_EMPTY)
	empty:Hide()
	view.empty = empty

	-- Rows: one frame per visible line
	local function NewRow(rowParent)
		local row = CreateFrame("Button", nil, rowParent)
		row:SetHeight(ROW)
		local stripe = row:CreateTexture(nil, "BACKGROUND")
		stripe:SetAllPoints()
		stripe:SetColorTexture(Theme.COLORS.selected[1], Theme.COLORS.selected[2], Theme.COLORS.selected[3], 0.25)
		stripe:Hide()
		row.stripe = stripe
		local line = row:CreateTexture(nil, "ARTWORK")
		line:SetColorTexture(Theme.COLORS.bronze[1], Theme.COLORS.bronze[2], Theme.COLORS.bronze[3], 0.15)
		line:SetHeight(1)
		line:SetPoint("BOTTOMLEFT", 2, 0)
		line:SetPoint("BOTTOMRIGHT", -2, 0)
		Theme.Highlight(row)
		row.cells = {}
		local cx = 6
		for index, column in ipairs(columns) do
			if column.button then
				local button = Theme.DarkButton(row, column.button.text, column.width - 8, ROW - 2)
				-- A thinner border than the filters': its corners fit the row.
				Theme.Panel(button, 10, 3, Theme.COLORS.buttonBg, Theme.COLORS.buttonBorder)
				button:SetPoint("LEFT", cx + 4, 0)
				button.label:SetFontObject("GameFontHighlightSmall")
				button:SetScript("OnClick", function()
					local data = row.data
					if not data or (column.button.selected and column.button.selected(data)) then return end
					Util.Guard("list-button", column.button.onClick, data)
				end)
				row.cells[index] = { button = button }
			elseif column.icon then
				local icon = row:CreateTexture(nil, "ARTWORK")
				icon:SetSize(16, 16)
				icon:SetPoint("LEFT", cx + 4, 0)
				row.cells[index] = { icon = icon, text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight") }
				row.cells[index].text:SetPoint("LEFT", cx + 24, 0)
				row.cells[index].text:SetWidth(column.width - 28)
				row.cells[index].text:SetJustifyH("LEFT")
			else
				local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				if column.align == "RIGHT" then
					text:SetPoint("RIGHT", row, "LEFT", cx + column.width - 4, 0)
					text:SetJustifyH("RIGHT")
				else
					text:SetPoint("LEFT", cx + 4, 0)
					text:SetJustifyH("LEFT")
				end
				text:SetWidth(column.width - 8)
				row.cells[index] = { text = text }
			end
			local text = row.cells[index].text
			if text then
				-- One line per row: a long value is cut, never wrapped over the next row.
				text:SetWordWrap(false)
				text:SetTextColor(Theme.Color("text"))
			end
			cx = cx + column.width
		end
		row:SetScript("OnEnter", function(self)
			if self.data and options.tooltip then Util.Guard("list-tooltip", options.tooltip, self, self.data) end
		end)
		row:SetScript("OnLeave", function() Theme.TooltipHide() end)
		if options.onClick then
			row:SetScript("OnClick", function(self)
				if self.data then Util.Guard("list-click", options.onClick, self.data) end
			end)
		end
		return row
	end

	local function Fill(row, data)
		row.data = data
		for index, column in ipairs(columns) do
			local cell = row.cells[index]
			if cell.button then
				cell.button:SetSelected(column.button.selected ~= nil and column.button.selected(data) == true)
			else
				local value = data[column.key]
				if column.format then value = column.format(value, data) end
				cell.text:SetText(value == nil and "" or tostring(value))
				if column.icon == "class" then
					Theme.ClassIcon(cell.icon, data.class)
				elseif column.icon == "race" then
					Theme.RaceIcon(cell.icon, data.race)
				end
				local classFile = column.classColor and data[column.classColor == true and "class" or column.classColor]
				if type(classFile) == "string" then
					cell.text:SetTextColor(Theme.ClassColor(classFile))
				elseif column.muted then
					cell.text:SetTextColor(Theme.Color("muted"))
				else
					cell.text:SetTextColor(Theme.Color("text"))
				end
			end
		end
		if data.me then
			row.stripe:Show()
		else
			row.stripe:Hide()
		end
	end

	local function GuardedFill(row, data)
		local ok, message = pcall(Fill, row, data)
		if not ok then ns.Error("list-fill", message) end
	end

	if HasScrollBox() then
		local scrollBox = Theme.TryCreate("Frame", nil, panel, { "WowScrollBoxList" })
		scrollBox:SetPoint("TOPLEFT", band, "BOTTOMLEFT", 0, -2)
		scrollBox:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -GUTTER - 4, 4)
		local scrollBar = Theme.TryCreate("EventFrame", nil, panel, { "MinimalScrollBar" })
		scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 4, 0)
		scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 4, 0)
		if scrollBar.SetHideIfUnscrollable then scrollBar:SetHideIfUnscrollable(true) end
		local linear = CreateScrollBoxListLinearView(0, 0, 0, 0, 0)
		linear:SetElementExtent(ROW)
		linear:SetElementInitializer("Button", function(button, data)
			if not button.row then
				-- The ScrollBox hands us bare buttons, and hands them again with
				-- other data when the list scrolls or refreshes: dress each once.
				local dressed = NewRow(button)
				dressed:SetAllPoints(button)
				button.row = dressed
			end
			GuardedFill(button.row, data)
		end)
		ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, linear)
		view.scrollBox = scrollBox
		view.mode = "scrollbox"
	else
		local holder = CreateFrame("Frame", nil, panel)
		holder:SetPoint("TOPLEFT", band, "BOTTOMLEFT", 0, -2)
		holder:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
		holder:EnableMouseWheel(true)
		holder:SetScript("OnMouseWheel", function(_, delta)
			view.offset = math.max(0, math.min(math.max(0, #view.data - #view.rows), (view.offset or 0) - delta))
			view:Layout()
		end)
		view.holder = holder
		view.offset = 0
		view.mode = "pool"
		function view:Layout()
			local visible = math.max(1, math.floor((self.holder:GetHeight() or ROW * 10) / ROW))
			for index = 1, visible do
				local row = self.rows[index]
				if not row then
					row = NewRow(self.holder)
					row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW)
					row:SetPoint("TOPRIGHT", 0, -(index - 1) * ROW)
					self.rows[index] = row
				end
				local data = self.data[index + (self.offset or 0)]
				if data then
					GuardedFill(row, data)
					row:Show()
				else
					row.data = nil
					row:Hide()
				end
			end
			for index = visible + 1, #self.rows do
				self.rows[index]:Hide()
			end
		end
	end

	function view:SetData(list)
		self.data = list or {}
		self:Refresh()
	end

	function view:Refresh()
		local list = self.data
		if self.sortKey then
			local key, desc = self.sortKey, self.sortDesc
			table.sort(list, function(a, b)
				local va, vb = a[key], b[key]
				if type(va) == "number" and type(vb) == "number" then
					if va ~= vb then return (va > vb) == desc end
				else
					va, vb = tostring(va or ""), tostring(vb or "")
					if va ~= vb then return (va < vb) ~= desc end
				end
				return (a.rank or 0) < (b.rank or 0)
			end)
		end
		for _, header in ipairs(self.headers) do
			if header.column.key == self.sortKey then
				header.label:SetTextColor(Theme.Color("lit"))
			else
				header.label:SetTextColor(Theme.Color("title"))
			end
		end
		if #list == 0 then self.empty:Show() else self.empty:Hide() end
		if self.mode == "scrollbox" then
			local provider = CreateDataProvider()
			for _, item in ipairs(list) do provider:Insert(item) end
			self.scrollBox:SetDataProvider(provider, ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition or nil)
		else
			self.offset = 0
			self:Layout()
		end
	end

	function view:SetEmptyText(text)
		self.empty:SetText(text)
	end

	return view
end
