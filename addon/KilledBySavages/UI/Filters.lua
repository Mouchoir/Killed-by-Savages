local _, ns = ...

--------------------------------------------------------------------------------
-- Filters: the bar above a list
--
-- A search box that finds a name from any part of it, whatever the case or
-- the accents, and on the lists of characters a toggle per class, two
-- bounds for the level and a toggle per role. Nothing set shows everything.
-- A row a filter cannot judge (no level known, no role chosen) is left out
-- while that filter is set: the list never shows a guess.
--
-- Buttons and edit boxes only. No dropdown and no menu anywhere in the
-- addon: the client's own trips a menu assertion on Forever.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local Identity = ns.Identity
local L = ns.L

local Filters = {}
ns.Filters = Filters

local HEIGHT = 24
local ICON = 20
local ICON_GAP = 2
Filters.HEIGHT = HEIGHT

local ROLE_TEXT = { T = L.ROLE_TANK, H = L.ROLE_HEALER, D = L.ROLE_DAMAGE }
Filters.ROLE_TEXT = ROLE_TEXT

local function Trim(text)
	return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ClassName(classFile)
	return ns.UI and ns.UI.ClassName and ns.UI.ClassName(classFile) or classFile
end

-- A small dark button, its border thin enough for a 20 px bar.
local function SmallButton(parent, text, width)
	local button = Theme.DarkButton(parent, text, width, 20)
	Theme.Panel(button, 10, 3, Theme.COLORS.buttonBg, Theme.COLORS.buttonBorder)
	button.label:SetFontObject("GameFontHighlightSmall")
	button:SetSelected(false)
	return button
end
Filters.SmallButton = SmallButton

local Tip = Theme.Tip
Filters.Tip = Tip

-- parts: { search = true, classes = true, levels = true, roles = true },
--   searchTip = the line under the search box's tooltip title.
-- read: how a row answers, each optional: names(row) gives the list of names
--   the search looks in (the row's name by default), class(row), level(row)
--   and role(row) what the toggles and bounds compare (the row's class,
--   level and role fields by default).
-- onChange runs after every change the player makes.
function Filters.New(parent, parts, read, onChange)
	read = read or {}
	local bar = { classes = {}, roles = {}, text = "", classButtons = {}, roleButtons = {} }
	local frame = CreateFrame("Frame", nil, parent)
	frame:SetHeight(HEIGHT)
	bar.frame = frame

	local function ReadClass(row)
		if read.class then return read.class(row) end
		return row.class
	end
	local function ReadLevel(row)
		if read.level then return read.level(row) end
		return row.level
	end
	local function ReadRole(row)
		if read.role then return read.role(row) end
		return row.role
	end

	local function Changed()
		bar:Update()
		if onChange then Util.Guard("filters", onChange) end
	end

	-- Each part sits after the one before it, on one line.
	local last
	local function Place(region, gap)
		if last then
			region:SetPoint("LEFT", last, "RIGHT", gap, 0)
		else
			region:SetPoint("LEFT", frame, "LEFT", gap, 0)
		end
		last = region
	end

	local function EditBox(templates, width, letters)
		local box = Theme.TryCreate("EditBox", nil, frame, templates)
		box:SetSize(width, 20)
		box:SetAutoFocus(false)
		box:SetMaxLetters(letters)
		box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
		box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		return box
	end

	if parts.search then
		-- The client's search box brings its magnifier, its greyed
		-- instructions and its clear button; a plain input box otherwise,
		-- with instructions of our own.
		local box = EditBox({ "SearchBoxTemplate", "InputBoxTemplate" }, 156, 24)
		Place(box, 6)
		local instructions = type(box.Instructions) == "table" and box.Instructions or nil
		if instructions then
			instructions:SetText(L.FILTER_SEARCH)
		else
			instructions = box:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
			instructions:SetPoint("LEFT", 6, 0)
			instructions:SetText(L.FILTER_SEARCH)
			box.ownInstructions = instructions
			box:HookScript("OnEditFocusGained", function() instructions:Hide() end)
			box:HookScript("OnEditFocusLost", function(self)
				if Trim(self:GetText()) == "" then instructions:Show() end
			end)
		end
		box:HookScript("OnTextChanged", function(self)
			local text = Util.Fold(Trim(self:GetText()))
			if box.ownInstructions and text ~= "" then box.ownInstructions:Hide() end
			if text == bar.text then return end
			bar.text = text
			Changed()
		end)
		Tip(box, L.FILTER_SEARCH, parts.searchTip or L.FILTER_SEARCH_TIP)
		bar.searchBox = box
	end

	if parts.classes then
		-- One icon per class on the list, set by SetClasses.
		local strip = CreateFrame("Frame", nil, frame)
		strip:SetSize(ICON, HEIGHT)
		Place(strip, 10)
		bar.classStrip = strip
	end

	local function NewClassButton(index)
		local button = CreateFrame("Button", nil, bar.classStrip)
		button:SetSize(ICON, ICON)
		button:SetPoint("LEFT", (index - 1) * (ICON + ICON_GAP), 0)
		button.icon = button:CreateTexture(nil, "ARTWORK")
		button.icon:SetAllPoints()
		-- A gold line under a chosen class.
		local mark = button:CreateTexture(nil, "OVERLAY")
		local r, g, b = Theme.Color("lit")
		mark:SetColorTexture(r, g, b, 1)
		mark:SetHeight(2)
		mark:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, 0)
		mark:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, 0)
		mark:Hide()
		button.mark = mark
		Theme.Highlight(button)
		button:SetScript("OnClick", function(self)
			if not self.classFile then return end
			bar.classes[self.classFile] = (not bar.classes[self.classFile]) or nil
			Changed()
		end)
		Tip(button, function(self) return ClassName(self.classFile) end, L.FILTER_CLASS_TIP)
		bar.classButtons[index] = button
		return button
	end

	if parts.levels then
		local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		label:SetText(L.FILTER_LEVEL)
		label:SetTextColor(Theme.Color("muted"))
		Place(label, 10)
		local function LevelBox()
			local box = EditBox({ "InputBoxTemplate" }, 28, 3)
			if box.SetNumeric then box:SetNumeric(true) end
			if box.SetJustifyH then box:SetJustifyH("CENTER") end
			box:HookScript("OnTextChanged", function()
				local low = bar.minBox and tonumber(bar.minBox:GetText()) or nil
				local high = bar.maxBox and tonumber(bar.maxBox:GetText()) or nil
				if low == bar.minLevel and high == bar.maxLevel then return end
				bar.minLevel, bar.maxLevel = low, high
				Changed()
			end)
			Tip(box, L.FILTER_LEVEL, L.FILTER_LEVEL_TIP)
			return box
		end
		bar.minBox = LevelBox()
		Place(bar.minBox, 12)
		local dash = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		dash:SetText("-")
		dash:SetTextColor(Theme.Color("muted"))
		Place(dash, 4)
		bar.maxBox = LevelBox()
		Place(bar.maxBox, 9)
	end

	if parts.roles then
		for index, role in ipairs(Identity.ROLES) do
			local button = SmallButton(frame, ROLE_TEXT[role], 48)
			Place(button, index == 1 and 10 or 3)
			button:SetScript("OnClick", function()
				bar.roles[role] = (not bar.roles[role]) or nil
				Changed()
			end)
			Tip(button, ROLE_TEXT[role], L.FILTER_ROLE_TIP)
			bar.roleButtons[role] = button
		end
	end

	if parts.ranks then
		-- Only the rows marked for a guild rank to give. The button shows
		-- for the members allowed to see those marks (SetRanksShown).
		local button = SmallButton(frame, L.FILTER_RANKS, 118)
		Place(button, 10)
		button:SetScript("OnClick", function()
			bar.ranks = (not bar.ranks) or nil
			Changed()
		end)
		Tip(button, L.FILTER_RANKS, L.FILTER_RANKS_TIP)
		button:Hide()
		bar.ranksButton = button
	end

	-- The last part placed from the left: the count must not run under it.
	bar.lastPart = last

	-- At the right end, while something is set: how many rows are left, and
	-- a button that clears it all.
	local reset = SmallButton(frame, L.FILTER_RESET, 70)
	reset:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	reset:SetScript("OnClick", function() bar:Reset() end)
	reset:Hide()
	bar.reset = reset
	local count = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	count:SetPoint("RIGHT", reset, "LEFT", -8, 0)
	count:SetTextColor(Theme.Color("muted"))
	count:Hide()
	bar.count = count

	function bar:Active()
		return self.text ~= "" or next(self.classes) ~= nil or next(self.roles) ~= nil
			or self.minLevel ~= nil or self.maxLevel ~= nil or self.ranks == true
	end

	-- The rank button comes and goes with the right to see the marks; gone,
	-- it takes its filter with it.
	function bar:SetRanksShown(shown)
		if not self.ranksButton then return end
		if shown then
			self.ranksButton:Show()
		else
			self.ranksButton:Hide()
			self.ranks = nil
		end
		self.ranksShown = shown and true or false
		self:Update()
	end

	-- What is chosen shows: the classes left out fade, the roles chosen
	-- light up, the clear button comes with the first filter.
	function bar:Update()
		local anyClass = next(self.classes) ~= nil
		for _, button in ipairs(self.classButtons) do
			local chosen = self.classes[button.classFile] == true
			button.icon:SetAlpha((not anyClass or chosen) and 1 or 0.3)
			if chosen then button.mark:Show() else button.mark:Hide() end
		end
		for role, button in pairs(self.roleButtons) do
			button:SetSelected(self.roles[role] == true)
		end
		if self.ranksButton then self.ranksButton:SetSelected(self.ranks == true) end
		if self:Active() then
			self.reset:Show()
		else
			self.reset:Hide()
			self.count:Hide()
		end
	end

	-- The classes the rows hold, each with its icon, by name. A class
	-- chosen that the list no longer holds is dropped: it would hide
	-- everything with no icon left to take it back.
	function bar:SetClasses(rows)
		if not self.classStrip then return end
		local seen, list = {}, {}
		for _, row in ipairs(rows) do
			local classFile = ReadClass(row)
			if type(classFile) == "string" and not seen[classFile] then
				seen[classFile] = true
				list[#list + 1] = classFile
			end
		end
		table.sort(list, function(a, b)
			local nameA, nameB = ClassName(a), ClassName(b)
			if nameA ~= nameB then return nameA < nameB end
			return a < b
		end)
		for classFile in pairs(self.classes) do
			if not seen[classFile] then self.classes[classFile] = nil end
		end
		for index, classFile in ipairs(list) do
			local button = self.classButtons[index] or NewClassButton(index)
			button.classFile = classFile
			if not Theme.ClassIcon(button.icon, classFile) then
				-- No icon for that class on this client: its colour.
				local r, g, b = Theme.ClassColor(classFile)
				button.icon:SetColorTexture(r, g, b, 1)
				button.icon:Show()
			end
			button:Show()
		end
		for index = #list + 1, #self.classButtons do
			self.classButtons[index].classFile = nil
			self.classButtons[index]:Hide()
		end
		self.classStrip:SetWidth(math.max(1, #list) * (ICON + ICON_GAP) - ICON_GAP)
		self:Update()
	end

	-- The rows that pass, in their order. The same list when nothing is set.
	function bar:Apply(rows)
		if not self:Active() then return rows end
		local low, high = self.minLevel, self.maxLevel
		if low and high and low > high then low, high = high, low end
		local anyClass, anyRole = next(self.classes) ~= nil, next(self.roles) ~= nil
		local needle = self.text
		local shown = {}
		for _, row in ipairs(rows) do
			local keep = true
			if anyClass and not self.classes[ReadClass(row) or false] then keep = false end
			if keep and anyRole and not self.roles[ReadRole(row) or false] then keep = false end
			if keep and self.ranks and not row.rankMark then keep = false end
			if keep and (low or high) then
				local level = ReadLevel(row)
				if type(level) ~= "number" or (low and level < low) or (high and level > high) then keep = false end
			end
			if keep and needle ~= "" then
				keep = false
				for _, name in ipairs(read.names and read.names(row) or { row.name }) do
					if Util.Fold(name):find(needle, 1, true) then
						keep = true
						break
					end
				end
			end
			if keep then shown[#shown + 1] = row end
		end
		return shown
	end

	-- "3 of 42", next to the clear button, while a filter is set.
	-- On a full bar (the characters') the room between the last toggle and
	-- the clear button is short, and a text that runs under a button is a
	-- text nobody reads: "6 of 22" when it fits, else "6/22", else nothing.
	function bar:SetCount(shown, total)
		if not (self:Active() and type(shown) == "number" and type(total) == "number") then
			self.count:Hide()
			return
		end
		self.count:Show()
		local edge = self.lastPart and self.lastPart.GetRight and self.lastPart:GetRight()
		local limit = self.reset.GetLeft and self.reset:GetLeft()
		local room = type(edge) == "number" and type(limit) == "number" and (limit - 8 - edge - 6) or nil
		for _, form in ipairs({ L.FILTER_COUNT, L.FILTER_COUNT_SHORT }) do
			self.count:SetText(form:format(shown, total))
			local width = self.count.GetStringWidth and self.count:GetStringWidth()
			if not room or type(width) ~= "number" or width <= room then return end
		end
		self.count:SetText("")
	end

	function bar:Reset()
		self.classes, self.roles = {}, {}
		self.minLevel, self.maxLevel, self.ranks = nil, nil, nil
		self.text = ""
		-- The boxes say it too; their handlers then find nothing new.
		if self.searchBox then self.searchBox:SetText("") end
		if self.minBox then self.minBox:SetText("") end
		if self.maxBox then self.maxBox:SetText("") end
		Changed()
	end

	bar:Update()
	return bar
end

-- A list's rows through its bar: the list, the count, and an empty state
-- that says so when it is the filters that leave nothing.
function Filters.Fill(bar, view, rows, emptyText)
	local shown = bar:Apply(rows)
	view:SetEmptyText((#rows > 0 and #shown == 0) and L.EMPTY_FILTERED or emptyText)
	view:SetData(shown)
	return shown
end
