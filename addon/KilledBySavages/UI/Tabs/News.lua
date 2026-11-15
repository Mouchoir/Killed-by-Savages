local _, ns = ...

--------------------------------------------------------------------------------
-- News tab: the guild's announcements. The list on the left, the events to
-- come first; on the right the one chosen, with the link of its Discord
-- message in a box to copy it from. Looking at an announcement is what
-- marks it seen. A member who may publish gets a form in place of the
-- reading panel; the guild's first rank names who may publish, under it.
--
-- Buttons and edit boxes only, as everywhere in the addon.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local Identity = ns.Identity
local News = ns.News
local Filters = ns.Filters
local L = ns.L

local LIST_WIDTH = 250
local ROW_HEIGHT = 36
local ROWS = 9
local INNER = 12                  -- from a panel's edge to what it holds
local WELL_HEIGHT = 94            -- the description's box, with two lines of ranks under it
local WELL_LEAST = 48
local RANK_LINE = 23              -- a line of rank buttons, and the gap under it
local COPY_KEY = (Util.Fn(IsMacClient) and Util.Get(IsMacClient)) and "Cmd+C" or "Ctrl+C"
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local function Leather(parent)
	local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	Theme.Panel(panel, 14, 4)
	Theme.Parchment(panel, 0.16)
	return panel
end

local function Label(parent, text, font, color)
	local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
	label:SetTextColor(Theme.Color(color or "head"))
	label:SetJustifyH("LEFT")
	if text then label:SetText(text) end
	return label
end

local function Box(parent, width, letters, numeric)
	local box = Theme.TryCreate("EditBox", nil, parent, { "InputBoxTemplate" })
	box:SetSize(width, 20)
	box:SetAutoFocus(false)
	box:SetMaxLetters(letters)
	if numeric then
		if box.SetNumeric then box:SetNumeric(true) end
		if box.SetJustifyH then box:SetJustifyH("CENTER") end
	elseif box.SetTextInsets then
		box:SetTextInsets(4, 4, 0, 0)
	end
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	return box
end

-- The names of what an announcement is for, or that it is for everyone.
local function ForText(item)
	local groups = {}
	if item.ranks then
		local names = {}
		for _, rank in ipairs(Identity.Ranks()) do
			if item.ranks[rank.index] then names[#names + 1] = rank.name end
		end
		if #names > 0 then groups[#groups + 1] = table.concat(names, ", ") end
	end
	if item.classes then
		local names = {}
		for _, classFile in ipairs(CLASSES) do
			if item.classes[classFile] then names[#names + 1] = ns.UI.ClassName(classFile) end
		end
		for classFile in pairs(item.classes) do
			local known = false
			for _, listed in ipairs(CLASSES) do
				if listed == classFile then known = true end
			end
			if not known then names[#names + 1] = ns.UI.ClassName(classFile) end
		end
		groups[#groups + 1] = table.concat(names, ", ")
	end
	if item.roles then
		local names = {}
		for _, role in ipairs(Identity.ROLES) do
			if item.roles[role] then names[#names + 1] = Filters.ROLE_TEXT[role] end
		end
		groups[#groups + 1] = table.concat(names, ", ")
	end
	if item.level then groups[#groups + 1] = L.NEWS_FOR_LEVEL:format(item.level) end
	if #groups == 0 then return L.NEWS_FOR_ALL end
	return L.NEWS_FOR:format(table.concat(groups, "; "))
end

local function AuthorName(item)
	local member = Identity.MemberByTail(item.by)
	return member and member.name or "?"
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

local function BuildRow(frame, index)
	local row = CreateFrame("Button", nil, frame.list)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 6, -6 - (index - 1) * ROW_HEIGHT)
	row:SetPoint("TOPRIGHT", -6, -6 - (index - 1) * ROW_HEIGHT)
	Theme.Highlight(row)
	local chosen = row:CreateTexture(nil, "BACKGROUND")
	chosen:SetAllPoints()
	chosen:SetColorTexture(Theme.COLORS.selected[1], Theme.COLORS.selected[2], Theme.COLORS.selected[3], 0.25)
	chosen:Hide()
	row.chosen = chosen
	-- A red mark before an announcement not looked at yet.
	local mark = row:CreateTexture(nil, "OVERLAY")
	mark:SetSize(6, 6)
	mark:SetPoint("LEFT", 4, 0)
	mark:SetColorTexture(0.86, 0.2, 0.14, 1)
	mark:Hide()
	row.mark = mark
	row.title = Label(row, nil, "GameFontHighlight", "text")
	row.title:SetPoint("TOPLEFT", 16, -4)
	row.title:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.title:SetWordWrap(false)
	row.when = Label(row, nil, "GameFontHighlightSmall", "muted")
	row.when:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
	row.when:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.when:SetWordWrap(false)
	local line = Theme.Rule(row, 0.15)
	line:SetPoint("BOTTOMLEFT", 0, 0)
	line:SetPoint("BOTTOMRIGHT", 0, 0)
	row:SetScript("OnClick", function(self)
		if not self.id then return end
		frame.editing = nil
		frame.selected = self.id
		ns.UI.Refresh()
	end)
	return row
end

--------------------------------------------------------------------------------
-- The form
--------------------------------------------------------------------------------

local function Toggle(button, set, value, changed)
	button:SetScript("OnClick", function(self)
		set[value] = (not set[value]) or nil
		self:SetSelected(set[value] == true)
		if changed then changed() end
	end)
end

local function BuildForm(frame)
	local form = CreateFrame("Frame", nil, frame.detail)
	form:SetAllPoints()
	form.ranks, form.classes, form.roles = {}, {}, {}
	form.rankButtons, form.classButtons, form.roleButtons = {}, {}, {}
	local width = frame.detail:GetWidth() > 0 and frame.detail:GetWidth() or 526

	local titleLabel = Label(form, L.NEWS_FORM_TITLE)
	titleLabel:SetPoint("TOPLEFT", INNER, -16)
	form.title = Box(form, 380, News.TITLE_MAX)
	form.title:SetPoint("TOPLEFT", 110, -12)

	local dateLabel = Label(form, L.NEWS_FORM_DATE)
	dateLabel:SetPoint("TOPLEFT", INNER, -44)
	form.day = Box(form, 28, 2, true)
	form.day:SetPoint("TOPLEFT", 110, -40)
	local slash = Label(form, "/", nil, "muted")
	slash:SetPoint("LEFT", form.day, "RIGHT", 5, 0)
	form.month = Box(form, 28, 2, true)
	form.month:SetPoint("LEFT", slash, "RIGHT", 9, 0)
	local at = Label(form, L.NEWS_FORM_AT, nil, "muted")
	at:SetPoint("LEFT", form.month, "RIGHT", 10, 0)
	form.hour = Box(form, 28, 2, true)
	form.hour:SetPoint("LEFT", at, "RIGHT", 12, 0)
	local colon = Label(form, ":", nil, "muted")
	colon:SetPoint("LEFT", form.hour, "RIGHT", 5, 0)
	form.minute = Box(form, 28, 2, true)
	form.minute:SetPoint("LEFT", colon, "RIGHT", 9, 0)
	local dateHint = Label(form, L.NEWS_FORM_DATE_HINT, nil, "muted")
	dateHint:SetPoint("LEFT", form.minute, "RIGHT", 12, 0)
	dateHint:SetPoint("RIGHT", form, "RIGHT", -INNER, 0)
	dateHint:SetWordWrap(false)
	Theme.Tip(form.day, L.NEWS_FORM_DATE, L.NEWS_FORM_DATE_TIP)
	Theme.Tip(form.month, L.NEWS_FORM_DATE, L.NEWS_FORM_DATE_TIP)

	local textLabel = Label(form, L.NEWS_FORM_TEXT)
	textLabel:SetPoint("TOPLEFT", INNER, -70)
	form.count = Label(form, nil, nil, "muted")
	form.count:SetPoint("TOPRIGHT", -INNER, -70)
	local well = CreateFrame("Frame", nil, form, "BackdropTemplate")
	Theme.Panel(well, 10, 3, { 0.045, 0.043, 0.040, 0.98 }, { 0.34, 0.31, 0.27, 1 })
	well:SetPoint("TOPLEFT", INNER, -86)
	well:SetPoint("TOPRIGHT", -INNER, -86)
	well:SetHeight(WELL_HEIGHT)
	well:EnableMouse(true)
	form.well = well
	-- A text longer than the well stays inside it.
	if well.SetClipsChildren then well:SetClipsChildren(true) end
	local text = CreateFrame("EditBox", nil, well)
	text:SetPoint("TOPLEFT", 7, -6)
	text:SetPoint("BOTTOMRIGHT", -7, 6)
	text:SetMultiLine(true)
	text:SetAutoFocus(false)
	text:SetMaxLetters(News.TEXT_MAX)
	text:SetFontObject("GameFontHighlightSmall")
	text:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	text:SetScript("OnTextChanged", function(self)
		local used = #(self:GetText() or "")
		form.count:SetText(("%d / %d"):format(used, News.TEXT_MAX))
		form.count:SetTextColor(Theme.Color(used > News.TEXT_MAX and "warn" or "muted"))
	end)
	well:SetScript("OnMouseDown", function() text:SetFocus() end)
	form.text = text

	local linkLabel = Label(form, L.NEWS_FORM_LINK)
	-- From here down everything hangs under the description, so that the
	-- lines the ranks take move what follows them and nothing else.
	linkLabel:SetPoint("TOPLEFT", well, "BOTTOMLEFT", 0, -12)
	form.link = Box(form, 380, News.LINK_MAX)
	form.link:SetPoint("TOPLEFT", well, "BOTTOMLEFT", 110 - INNER, -8)

	-- Whom it is for: nothing chosen is the whole guild.
	local forLabel = Label(form, L.NEWS_FORM_FOR)
	forLabel:SetPoint("TOPLEFT", well, "BOTTOMLEFT", 0, -40)
	form.forLabel = forLabel
	form.rankHolder = CreateFrame("Frame", nil, form)
	form.rankHolder:SetPoint("TOPLEFT", well, "BOTTOMLEFT", 110 - INNER, -36)
	form.rankHolder:SetSize(width - 110 - INNER, 2 * RANK_LINE - 3)

	local targets = CreateFrame("Frame", nil, form)
	targets:SetPoint("TOPLEFT", form.rankHolder, "BOTTOMLEFT", 0, -6)
	targets:SetSize(width - 110 - INNER, 22)
	for index, classFile in ipairs(CLASSES) do
		local button = CreateFrame("Button", nil, targets)
		button:SetSize(20, 20)
		button:SetPoint("LEFT", (index - 1) * 22, 0)
		button.icon = button:CreateTexture(nil, "ARTWORK")
		button.icon:SetAllPoints()
		if not Theme.ClassIcon(button.icon, classFile) then
			-- No class art on this client: the class's colour stands for it.
			button.icon:SetColorTexture(Theme.ClassColor(classFile))
			button.icon:Show()
		end
		local mark = button:CreateTexture(nil, "OVERLAY")
		mark:SetColorTexture(Theme.COLORS.lit[1], Theme.COLORS.lit[2], Theme.COLORS.lit[3], 1)
		mark:SetHeight(2)
		mark:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, 0)
		mark:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, 0)
		mark:Hide()
		Theme.Highlight(button)
		button.classFile = classFile
		function button:SetSelected(selected)
			if selected then mark:Show() else mark:Hide() end
			self.icon:SetAlpha(selected and 1 or 0.55)
		end
		button:SetSelected(false)
		Toggle(button, form.classes, classFile)
		Theme.Tip(button, function() return ns.UI.ClassName(classFile) end, L.NEWS_FORM_TARGET_TIP)
		form.classButtons[classFile] = button
	end
	local previous
	for index, role in ipairs(Identity.ROLES) do
		local button = Filters.SmallButton(targets, Filters.ROLE_TEXT[role], 48)
		if previous then
			button:SetPoint("LEFT", previous, "RIGHT", 3, 0)
		else
			button:SetPoint("LEFT", #CLASSES * 22 + 12, 0)
		end
		previous = button
		Toggle(button, form.roles, role)
		Theme.Tip(button, Filters.ROLE_TEXT[role], L.NEWS_FORM_ROLE_TIP)
		form.roleButtons[role] = button
		if index == #Identity.ROLES then
			local levelLabel = Label(targets, L.NEWS_FORM_LEVEL, nil, "muted")
			levelLabel:SetPoint("LEFT", button, "RIGHT", 12, 0)
			form.level = Box(targets, 28, 3, true)
			form.level:SetPoint("LEFT", levelLabel, "RIGHT", 10, 0)
		end
	end
	local hint = Label(form, L.NEWS_FORM_FOR_HINT, nil, "muted")
	-- Held within the panel: a sentence longer than the line goes on a second.
	hint:SetPoint("TOPLEFT", targets, "BOTTOMLEFT", 0, -4)
	hint:SetPoint("RIGHT", form, "RIGHT", -INNER, 0)
	hint:SetJustifyV("TOP")
	hint:SetWordWrap(true)
	form.hint = hint

	form.error = Label(form, nil, "GameFontHighlightSmall", "warn")
	form.error:SetPoint("BOTTOMLEFT", INNER, 40)
	form.error:SetPoint("RIGHT", form, "RIGHT", -INNER, 0)
	form.publish = Theme.DarkButton(form, L.NEWS_PUBLISH, 150, 22)
	form.publish:SetPoint("BOTTOMLEFT", INNER, 12)
	form.cancel = Theme.DarkButton(form, L.NEWS_CANCEL, 100, 22)
	form.cancel:SetPoint("LEFT", form.publish, "RIGHT", 8, 0)

	-- The guild's ranks as toggles, on as many lines as they need. What is
	-- under them follows, and the description gives the room a third line
	-- takes, or takes what a single line leaves: the form keeps its height.
	function form.FillRanks()
		local x, y, lines = 0, 0, 1
		local limit = form.rankHolder:GetWidth() > 0 and form.rankHolder:GetWidth() or (width - 110 - INNER)
		local ranks = Identity.Ranks()
		for position, rank in ipairs(ranks) do
			local button = form.rankButtons[position]
			if not button then
				button = Filters.SmallButton(form.rankHolder, "", 60)
				form.rankButtons[position] = button
			end
			button.rankIndex = rank.index
			button:SetLabel(rank.name)
			local wide = math.max(44, math.min(150, (button.label:GetStringWidth() or 0) + 18))
			button:SetWidth(wide)
			if x > 0 and x + wide > limit then x, y, lines = 0, y - RANK_LINE, lines + 1 end
			button:ClearAllPoints()
			button:SetPoint("TOPLEFT", x, y)
			x = x + wide + 3
			button:SetSelected(form.ranks[rank.index] == true)
			button:SetScript("OnClick", function(self)
				form.ranks[self.rankIndex] = (not form.ranks[self.rankIndex]) or nil
				self:SetSelected(form.ranks[self.rankIndex] == true)
			end)
			button:Show()
		end
		for position = #ranks + 1, #form.rankButtons do form.rankButtons[position]:Hide() end
		form.rankHolder:SetHeight(lines * RANK_LINE - 3)
		form.well:SetHeight(math.max(WELL_LEAST, WELL_HEIGHT + (2 - lines) * RANK_LINE))
	end

	-- Empty for a new announcement, or what the one corrected says.
	function form.Fill(item)
		form.ranks, form.classes, form.roles = {}, {}, {}
		for key in pairs(item and item.ranks or {}) do form.ranks[key] = true end
		for key in pairs(item and item.classes or {}) do form.classes[key] = true end
		for key in pairs(item and item.roles or {}) do form.roles[key] = true end
		form.title:SetText(item and item.title or "")
		form.text:SetText(item and item.text or "")
		form.link:SetText(item and item.link or "")
		form.level:SetText(item and item.level and tostring(item.level) or "")
		local day, month, hour, minute = "", "", "", ""
		if item and Util.Fn(date) then
			day, month, hour, minute = date("%d", item.when), date("%m", item.when), date("%H", item.when), date("%M", item.when)
		end
		form.day:SetText(day)
		form.month:SetText(month)
		form.hour:SetText(hour)
		form.minute:SetText(minute)
		for classFile, button in pairs(form.classButtons) do
			button:SetSelected(form.classes[classFile] == true)
			Toggle(button, form.classes, classFile)
		end
		for role, button in pairs(form.roleButtons) do
			button:SetSelected(form.roles[role] == true)
			Toggle(button, form.roles, role)
		end
		form.FillRanks()
		form.error:SetText("")
		form.publish:SetLabel(item and L.NEWS_PUBLISH_AGAIN or L.NEWS_PUBLISH)
		form.count:SetText(("%d / %d"):format(#(form.text:GetText() or ""), News.TEXT_MAX))
	end

	form.publish:SetScript("OnClick", function()
		local when = News.When(form.day:GetText(), form.month:GetText(), form.hour:GetText(), form.minute:GetText())
		local item, why
		if not when then
			why = "when"
		else
			item, why = News.Publish({
				title = form.title:GetText(), when = when, text = form.text:GetText(), link = form.link:GetText(),
				ranks = form.ranks, classes = form.classes, roles = form.roles, level = tonumber(form.level:GetText()),
			}, frame.editing ~= true and frame.editing or nil)
		end
		if not item then
			form.error:SetText(why == "title" and L.NEWS_ERROR_TITLE or why == "when" and L.NEWS_ERROR_WHEN
				or why == "link" and L.NEWS_ERROR_LINK or L.NEWS_ERROR_RIGHT)
			return
		end
		frame.editing = nil
		frame.selected = item.id
		ns.Print(L.NEWS_PUBLISHED)
		ns.UI.Refresh()
	end)
	form.cancel:SetScript("OnClick", function()
		frame.editing = nil
		ns.UI.Refresh()
	end)
	form:Hide()
	return form
end

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

local function Build(frame)
	frame.list = Leather(frame)
	frame.list:SetPoint("TOPLEFT", 0, 0)
	frame.list:SetPoint("BOTTOMLEFT", 0, 58)
	frame.list:SetWidth(LIST_WIDTH)
	frame.rows = {}
	for index = 1, ROWS do frame.rows[index] = BuildRow(frame, index) end
	frame.none = Label(frame.list, L.NEWS_EMPTY, "GameFontDisable", "disabled")
	frame.none:SetPoint("TOPLEFT", INNER, -INNER)
	frame.none:SetPoint("RIGHT", frame.list, "RIGHT", -INNER, 0)
	frame.none:SetWordWrap(true)

	-- A new announcement: for the ranks that may publish.
	frame.newButton = Theme.DarkButton(frame, L.NEWS_NEW, LIST_WIDTH, 22)
	frame.newButton:SetPoint("BOTTOMLEFT", 0, 30)
	frame.newButton:SetScript("OnClick", function()
		frame.editing = true
		frame.form = frame.form or BuildForm(frame)
		frame.form.Fill(nil)
		ns.UI.Refresh()
	end)

	-- Told of announcements or not: the player's own choice, kept.
	local notify = Theme.TryCreate("CheckButton", nil, frame, { "UICheckButtonTemplate", "InterfaceOptionsCheckButtonTemplate" })
	notify:SetSize(26, 26)
	notify:SetPoint("BOTTOMLEFT", -2, -2)
	notify.label = Label(frame, L.NEWS_NOTIFY, "GameFontHighlightSmall", "text")
	notify.label:SetPoint("LEFT", notify, "RIGHT", 2, 0)
	notify:SetScript("OnClick", function(self) News.SetNotify(self:GetChecked() and true or false) end)
	Theme.Tip(notify, L.NEWS_NOTIFY, L.NEWS_NOTIFY_TIP)
	frame.notify = notify

	frame.detail = Leather(frame)
	frame.detail:SetPoint("TOPLEFT", LIST_WIDTH + 12, 0)
	frame.detail:SetPoint("BOTTOMRIGHT", 0, 30)

	-- The announcement chosen.
	local view = CreateFrame("Frame", nil, frame.detail)
	view:SetAllPoints()
	view.title = Label(view, nil, "GameFontNormalLarge", "gold")
	view.title:SetPoint("TOPLEFT", INNER, -14)
	view.title:SetPoint("RIGHT", view, "RIGHT", -INNER, 0)
	view.title:SetWordWrap(true)
	view.when = Label(view, nil, "GameFontHighlight", "text")
	view.when:SetPoint("TOPLEFT", view.title, "BOTTOMLEFT", 0, -8)
	view.when:SetPoint("RIGHT", view, "RIGHT", -INNER, 0)
	view.meta = Label(view, nil, "GameFontHighlightSmall", "muted")
	view.meta:SetPoint("TOPLEFT", view.when, "BOTTOMLEFT", 0, -6)
	view.meta:SetPoint("RIGHT", view, "RIGHT", -INNER, 0)
	view.meta:SetWordWrap(true)
	local rule = Theme.Rule(view, 0.4)
	rule:SetPoint("TOPLEFT", view.meta, "BOTTOMLEFT", 0, -8)
	rule:SetPoint("RIGHT", view, "RIGHT", -INNER, 0)
	view.body = Label(view, nil, "GameFontHighlight", "text")
	view.body:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 0, -10)
	view.body:SetPoint("RIGHT", view, "RIGHT", -INNER, 0)
	-- Held above the link: a text of many short lines is cut, not drawn over it.
	view.body:SetPoint("BOTTOM", view, "BOTTOM", 0, 46)
	view.body:SetJustifyV("TOP")
	view.body:SetWordWrap(true)
	if view.body.SetSpacing then view.body:SetSpacing(2) end
	-- The link of the Discord message, in a box to copy it from: an addon
	-- cannot open a browser.
	view.linkLabel = Label(view, L.NEWS_LINK, "GameFontNormal", "title")
	view.linkLabel:SetPoint("BOTTOMLEFT", INNER, 16)
	local link = Box(view, 280, News.LINK_MAX)
	link:SetPoint("LEFT", view.linkLabel, "RIGHT", 12, 0)
	link:SetScript("OnTextChanged", function(self, userInput)
		if userInput and self:GetText() ~= (self.url or "") then
			self:SetText(self.url or "")
			self:HighlightText()
		end
	end)
	link:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	link:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)
	link:SetScript("OnMouseUp", function(self)
		if self:HasFocus() then self:HighlightText() end
	end)
	view.link = link
	view.linkHint = Label(view, L.NEWS_LINK_HINT:format(COPY_KEY), "GameFontHighlightSmall", "muted")
	view.linkHint:SetPoint("LEFT", link, "RIGHT", 10, 0)
	view.empty = Label(frame.detail, L.NEWS_PICK, "GameFontDisable", "disabled")
	view.empty:SetPoint("CENTER")
	view.empty:SetWidth(420)
	view.empty:SetJustifyH("CENTER")
	view.empty:SetWordWrap(true)
	frame.view = view

	-- Under the reading panel: correcting and removing for who may publish,
	-- and at the right end the first rank's rule on who may.
	frame.edit = Filters.SmallButton(frame, L.NEWS_EDIT, 90)
	frame.edit:SetPoint("BOTTOMLEFT", LIST_WIDTH + 12, 2)
	frame.edit:SetScript("OnClick", function()
		local item = frame.selected and News.Get(frame.selected)
		if not item then return end
		frame.editing = item.id
		frame.form = frame.form or BuildForm(frame)
		frame.form.Fill(item)
		ns.UI.Refresh()
	end)
	frame.remove = Filters.SmallButton(frame, L.NEWS_REMOVE, 90)
	frame.remove:SetPoint("LEFT", frame.edit, "RIGHT", 4, 0)
	frame.remove:SetScript("OnClick", function()
		if frame.selected and News.Remove(frame.selected) then
			frame.selected = nil
			ns.Print(L.NEWS_REMOVED)
		end
		ns.UI.Refresh()
	end)

	local limit = CreateFrame("Frame", nil, frame)
	limit:SetPoint("BOTTOMRIGHT", 0, 2)
	-- 22 + 6 + 100 + 6 + 22 px of stepper, the label before it: it ends
	-- clear of the two buttons at the panel's left.
	limit:SetSize(300, 20)
	limit.more = Filters.SmallButton(limit, ">", 22)
	limit.more:SetPoint("RIGHT", 0, 0)
	limit.name = Label(limit, nil, "GameFontHighlightSmall", "text")
	limit.name:SetPoint("RIGHT", limit.more, "LEFT", -6, 0)
	limit.name:SetWidth(100)
	limit.name:SetJustifyH("CENTER")
	limit.name:SetWordWrap(false)
	limit.less = Filters.SmallButton(limit, "<", 22)
	limit.less:SetPoint("RIGHT", limit.name, "LEFT", -6, 0)
	limit.label = Label(limit, L.NEWS_LIMIT, "GameFontHighlightSmall", "muted")
	limit.label:SetPoint("RIGHT", limit.less, "LEFT", -8, 0)
	local function Step(by)
		local ranks = Identity.Ranks()
		local last = ranks[#ranks] and ranks[#ranks].index or 0
		local now = (News.Limit())
		local target = math.max(0, math.min(last, now + by))
		if target ~= now or select(2, News.Limit()) then News.SetLimit(target) end
		ns.UI.Refresh()
	end
	limit.less:SetScript("OnClick", function() Step(-1) end)
	limit.more:SetScript("OnClick", function() Step(1) end)
	Theme.Tip(limit.less, L.NEWS_LIMIT, L.NEWS_LIMIT_TIP)
	Theme.Tip(limit.more, L.NEWS_LIMIT, L.NEWS_LIMIT_TIP)
	frame.limit = limit
end

local function ShowItem(frame, item)
	local view = frame.view
	view.title:SetText(item.title)
	local past = item.when <= Util.Now()
	view.when:SetText(past and L.NEWS_WHEN_PAST:format(Theme.DayTime(item.when)) or Theme.DayTime(item.when))
	view.when:SetTextColor(Theme.Color(past and "disabled" or "text"))
	view.meta:SetText(L.NEWS_BY:format(AuthorName(item)) .. "  -  " .. ForText(item))
	view.body:SetText(item.text or "")
	if item.link then
		view.link.url = item.link
		view.link:SetText(item.link)
		view.link:SetCursorPosition(0)
		view.linkLabel:Show()
		view.link:Show()
		view.linkHint:Show()
	else
		view.link.url = nil
		view.linkLabel:Hide()
		view.link:Hide()
		view.linkHint:Hide()
	end
end

local function Refresh(frame)
	local items = News.Shown()
	local mayPublish = News.CanPublish()
	local now = Util.Now()

	-- The one shown: the one chosen while it is still there, else the first
	-- not looked at yet, else the first of the list.
	local chosen
	for _, item in ipairs(items) do
		if item.id == frame.selected then chosen = item end
	end
	if not chosen then
		for _, item in ipairs(items) do
			if not chosen and item.when > now and not News.IsSeen(item) and News.ForMe(item) then chosen = item end
		end
		chosen = chosen or items[1]
		frame.selected = chosen and chosen.id or nil
	end

	for index, row in ipairs(frame.rows) do
		local item = items[index]
		if item then
			local past = item.when <= now
			row.id = item.id
			row.title:SetText(item.title)
			row.title:SetTextColor(Theme.Color(past and "disabled" or "text"))
			row.when:SetText(past and L.NEWS_WHEN_PAST:format(Theme.DayTime(item.when)) or Theme.DayTime(item.when))
			-- Looked at here and now: the one chosen is never marked.
			if not past and item ~= chosen and not News.IsSeen(item) and News.ForMe(item) then row.mark:Show() else row.mark:Hide() end
			if item == chosen and frame.editing ~= true then row.chosen:Show() else row.chosen:Hide() end
			row:Show()
		else
			row.id = nil
			row:Hide()
		end
	end
	if #items == 0 then frame.none:Show() else frame.none:Hide() end

	-- The form in place of the reading panel while one is written; a member
	-- who lost the right while writing gets the reading panel back.
	if frame.editing and not mayPublish then frame.editing = nil end
	local form = frame.form
	if frame.editing then
		frame.view:Hide()
		frame.view.empty:Hide()
		form:Show()
	else
		if form then form:Hide() end
		if chosen then
			frame.view.empty:Hide()
			frame.view:Show()
			ShowItem(frame, chosen)
			News.MarkSeen(chosen.id)
		else
			frame.view:Hide()
			frame.view.empty:SetText(#items == 0 and (mayPublish and L.NEWS_PICK_PUBLISH or L.NEWS_PICK_NONE) or L.NEWS_PICK)
			frame.view.empty:Show()
		end
	end

	if mayPublish then frame.newButton:Show() else frame.newButton:Hide() end
	if mayPublish and chosen and not frame.editing then
		frame.edit:Show()
		frame.remove:Show()
	else
		frame.edit:Hide()
		frame.remove:Hide()
	end
	frame.notify:SetChecked(News.Notifies())

	-- Who may publish, for the first rank to set.
	if News.IsMaster() then
		local index, why = News.Limit()
		local name
		for _, rank in ipairs(Identity.Ranks()) do
			if rank.index == index then name = rank.name end
		end
		frame.limit.name:SetText(why and L.NEWS_LIMIT_RENAMED or ("%d. %s"):format(index + 1, name or "?"))
		frame.limit:Show()
	else
		frame.limit:Hide()
	end
end

ns.UI.RegisterTab({
	key = "news",
	title = L.TAB_NEWS,
	Build = Build,
	Refresh = Refresh,
	-- The announcements still to look at, on the tab's button.
	Badge = function() return #News.Unseen() end,
})
