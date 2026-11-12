local _, ns = ...

--------------------------------------------------------------------------------
-- Options tab: the addon's settings, in the board itself. Two leather
-- panels, the window on the left and the chat on the right, with the
-- client's own checkboxes and slider, and the help underneath.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local Identity = ns.Identity
local L = ns.L

local PANEL_HEIGHT = 212
local TOP = 40                    -- first control, under the panel's title
-- The copy shortcut, as the player's keyboard names it.
local COPY_KEY = (Util.Fn(IsMacClient) and Util.Get(IsMacClient)) and "Cmd+C" or "Ctrl+C"

local function Settings()
	return ns.db.settings
end

-- The client's checkbox with its label. A long label wraps instead of
-- ending in an ellipsis: a panel is only half the window wide.
local function Checkbox(parent, label, get, set)
	local box = Theme.TryCreate("CheckButton", nil, parent, { "UICheckButtonTemplate", "InterfaceOptionsCheckButtonTemplate" })
	box:SetSize(26, 26)
	local text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, -6)
	text:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
	text:SetJustifyH("LEFT")
	text:SetJustifyV("TOP")
	text:SetWordWrap(true)
	text:SetTextColor(Theme.Color("text"))
	text:SetText(label)
	box.label = text
	box.get = get
	box:SetScript("OnClick", function(self)
		set(self:GetChecked() and true or false)
	end)
	return box
end

-- The help under a checkbox, aligned on its label.
local function Hint(parent, box, text)
	local hint = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", box.label, "BOTTOMLEFT", 0, -3)
	hint:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
	hint:SetJustifyH("LEFT")
	hint:SetTextColor(Theme.Color("muted"))
	hint:SetText(text)
	return hint
end

local function Panel(parent, title)
	local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	Theme.Panel(panel, 14, 4)
	Theme.Parchment(panel, 0.16)
	local divider = Theme.Divider(panel, title, 220)
	divider:SetPoint("TOP", 0, -12)
	return panel
end

local function Percent(value)
	return ("%d%%"):format(value * 100 + 0.5)
end

-- A link to copy: an addon cannot open a browser. The box keeps its text
-- whatever is typed in it and selects it whole when it takes the keyboard
-- or is clicked, so the copy shortcut takes the link.
local function LinkBox(parent, url, width)
	local box = Theme.TryCreate("EditBox", nil, parent, { "InputBoxTemplate" })
	box:SetSize(width, 24)
	box:SetAutoFocus(false)
	if box.SetTextInsets then box:SetTextInsets(6, 6, 0, 0) end
	box:SetText(url)
	box:SetCursorPosition(0)
	box:SetScript("OnTextChanged", function(self, userInput)
		if userInput and self:GetText() ~= url then
			self:SetText(url)
			self:HighlightText()
		end
	end)
	box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	box:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)
	box:SetScript("OnMouseUp", function(self)
		if self:HasFocus() then self:HighlightText() end
	end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	return box
end

ns.UI.RegisterTab({
	key = "options",
	title = L.TAB_OPTIONS,
	side = "right",
	accent = "patina",
	Build = function(frame)
		local window = Panel(frame, L.OPTIONS_WINDOW)
		window:SetPoint("TOPLEFT", 0, 0)
		window:SetPoint("RIGHT", frame, "CENTER", -6, 0)
		window:SetHeight(PANEL_HEIGHT)
		local chat = Panel(frame, L.OPTIONS_CHAT)
		chat:SetPoint("TOPLEFT", frame, "TOP", 6, 0)
		chat:SetPoint("TOPRIGHT", 0, 0)
		chat:SetHeight(PANEL_HEIGHT)

		-- The window: minimap button, reminders of a newer release, scale.
		local minimap = Checkbox(window, L.OPTIONS_MINIMAP,
			function() return not Settings().minimap.hide end,
			function(value) ns.MinimapButton.SetShown(value) end)
		minimap:SetPoint("TOPLEFT", 12, -TOP)
		-- Unticked by the dialog's "Never remind me", ticked again here.
		local updates = Checkbox(window, L.OPTIONS_UPDATES,
			function() return Settings().updates ~= false end,
			function(value) ns.Sync.SetReminders(value) end)
		updates:SetPoint("TOPLEFT", minimap, "BOTTOMLEFT", 0, -2)
		local scaleLabel = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		scaleLabel:SetPoint("TOPLEFT", updates, "BOTTOMLEFT", 4, -14)
		scaleLabel:SetTextColor(Theme.Color("head"))
		scaleLabel:SetText(L.OPTIONS_SCALE)
		local slider = Theme.TryCreate("Slider", nil, window, { "OptionsSliderTemplate" })
		slider:SetPoint("TOPLEFT", scaleLabel, "BOTTOMLEFT", 0, -16)
		slider:SetSize(220, 16)
		slider:SetMinMaxValues(0.6, 1.4)
		slider:SetValueStep(0.05)
		if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
		local scaleValue = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		scaleValue:SetPoint("LEFT", slider, "RIGHT", 12, 0)
		scaleValue:SetTextColor(Theme.Color("text"))
		-- Scaling the window moves the slider under the cursor: while the
		-- mouse button is down only the number follows, and the window takes
		-- the new scale when the button comes up.
		local function Apply(value)
			scaleValue:SetText(Percent(ns.UI.SetScale(value)))
		end
		local function Release(self)
			if not self.held then return end
			self.held = false
			self:SetScript("OnUpdate", nil)
			Apply(self:GetValue())
		end
		slider:SetScript("OnValueChanged", function(self, value)
			if self.held then
				scaleValue:SetText(Percent(value))
			else
				Apply(value)
			end
		end)
		slider:SetScript("OnMouseDown", function(self)
			self.held = true
			-- The button may come up away from the slider: watch it.
			self:SetScript("OnUpdate", function(watched)
				if Util.Fn(IsMouseButtonDown) and not IsMouseButtonDown("LeftButton") then Release(watched) end
			end)
		end)
		slider:SetScript("OnMouseUp", Release)
		slider:SetScript("OnHide", Release)
		if slider.Low then slider.Low:SetText("60%") end
		if slider.High then slider.High:SetText("140%") end
		frame.slider, frame.scaleValue = slider, scaleValue

		-- The chat: the kill feed, off by default; when on, in a tab of its
		-- own unless the box under it sends the lines to the main chat.
		local killfeed = Checkbox(chat, L.OPTIONS_KILLFEED,
			function() return Settings().killfeed end,
			function(value)
				if value then ns.Killfeed.Enable() else ns.Killfeed.Disable() end
				frame.UpdateFeedTab()
			end)
		killfeed:SetPoint("TOPLEFT", 12, -TOP)
		local hint = Hint(chat, killfeed, L.OPTIONS_KILLFEED_HINT)
		-- Where the lines go: under the feed, indented, and only while it is on.
		local feedTab = Checkbox(chat, L.OPTIONS_KILLFEED_TAB:format(L.KILLFEED_TAB),
			function() return Settings().killfeedTab ~= false end,
			function(value)
				ns.Killfeed.SetTab(value)
				frame.UpdateFeedTab()
			end)
		feedTab:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", -4, -8)
		-- The tab is the player's to make: the hint names the menu entry in the
		-- client's own words.
		local entry = type(NEW_CHAT_WINDOW) == "string" and NEW_CHAT_WINDOW or L.KILLFEED_NEW_WINDOW
		local tabHint = Hint(chat, feedTab, L.OPTIONS_KILLFEED_TAB_HINT)
		-- Or the addon's to make, on this button: it shows while the feed wants
		-- a tab this character does not have, and its tooltip says why the
		-- interface reloads after, and how to make the tab by hand instead.
		local create = ns.Filters.SmallButton(chat, L.OPTIONS_KILLFEED_CREATE:format(L.KILLFEED_TAB), 290)
		create:SetPoint("TOPLEFT", tabHint, "BOTTOMLEFT", 0, -6)
		create:SetScript("OnClick", function() ns.Killfeed.CreateTab() end)
		Theme.Tip(create, L.OPTIONS_KILLFEED_CREATE:format(L.KILLFEED_TAB), L.OPTIONS_KILLFEED_CREATE_TIP:format(entry, L.KILLFEED_TAB))
		create:Hide()
		frame.createTab = create
		function frame.UpdateFeedTab()
			local on = Settings().killfeed == true
			feedTab:SetEnabled(on)
			feedTab.label:SetTextColor(Theme.Color(on and "text" or "disabled"))
			if ns.Killfeed.NeedsTab() then create:Show() else create:Hide() end
		end
		frame.boxes = { minimap, killfeed, feedTab, updates }

		local help = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		help:SetPoint("TOPLEFT", window, "BOTTOMLEFT", 4, -14)
		help:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
		help:SetJustifyH("LEFT")
		help:SetTextColor(Theme.Color("muted"))
		help:SetText(L.OPTIONS_HELP)

		-- The Discord link, in a box to copy it from: /kbs discord selects it.
		local discordLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		discordLabel:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -22)
		discordLabel:SetTextColor(Theme.Color("title"))
		discordLabel:SetText(L.DISCORD_LABEL)
		local link = LinkBox(frame, ns.DISCORD_URL, 236)
		link:SetPoint("LEFT", discordLabel, "RIGHT", 12, 0)
		local linkHint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		linkHint:SetPoint("LEFT", link, "RIGHT", 12, 0)
		linkHint:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
		linkHint:SetJustifyH("LEFT")
		linkHint:SetTextColor(Theme.Color("muted"))
		linkHint:SetText(L.DISCORD_HINT:format(COPY_KEY))
		frame.discord = link

		-- The guild's rule on ranks: a button for the guild's first rank only,
		-- which opens a small dialog over the board (below).
		local ranks = Theme.DarkButton(frame, L.OPTIONS_RANKS_BUTTON, 200, 22)
		ranks:SetPoint("BOTTOMLEFT", 4, 0)
		ranks:SetScript("OnClick", function() ns.UI.ShowRanksDialog() end)
		ranks:Hide()
		frame.ranksButton = ranks

		-- The version that runs and, when a guildmate runs a newer release,
		-- that one next to it, in orange.
		local version = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		version:SetPoint("BOTTOMRIGHT", -4, 2)
		frame.version = version
	end,
	Refresh = function(frame)
		for _, box in ipairs(frame.boxes) do
			box:SetChecked(box.get() and true or false)
		end
		frame.UpdateFeedTab()
		-- The rule on ranks is the first rank's to set, read from the rank
		-- held now: without it the button goes, and its dialog with it.
		if ns.Ranks.IsMaster() then
			frame.ranksButton:Show()
		else
			frame.ranksButton:Hide()
			ns.UI.HideRanksDialog()
		end
		-- A refresh while the thumb is held leaves the number it shows.
		if not frame.slider.held then
			local scale = tonumber(Settings().scale) or 1
			frame.slider:SetValue(scale)
			frame.scaleValue:SetText(Percent(scale))
		end
		local newer = ns.Sync and ns.Sync.NewerVersion()
		if newer then
			frame.version:SetText(L.OPTIONS_VERSION_OUTDATED:format(tostring(ns.VERSION), newer))
			frame.version:SetTextColor(Theme.Color("warn"))
		else
			frame.version:SetText(L.OPTIONS_VERSION:format(tostring(ns.VERSION)))
			frame.version:SetTextColor(Theme.Color("disabled"))
		end
	end,
})

--------------------------------------------------------------------------------
-- The rule on ranks, set by the guild's first rank (see Ranks)
--------------------------------------------------------------------------------

local ranksDialog

-- A value picked in a list that drops under its button: the guild's ranks
-- from the first to the last, numbered as the game's guild panel numbers
-- them, the one chosen lit. Made of the addon's own buttons: the client's
-- dropdown and its menus trip an assertion on Forever.
local openPicker

local function Picker(parent, label)
	local picker = { options = {}, at = 1, rows = {} }
	local title = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetTextColor(Theme.Color("title"))
	title:SetText(label)
	local button = Theme.DarkButton(parent, "", 206, 22)
	-- A small arrow at the button's right end, drawn line by line.
	for step, width in ipairs({ 7, 5, 3, 1 }) do
		local line = button:CreateTexture(nil, "OVERLAY")
		line:SetColorTexture(1, 0.82, 0.27, 0.9)
		line:SetSize(width, 1)
		line:SetPoint("CENTER", button, "RIGHT", -12, 2 - step)
	end
	local list = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	Theme.Panel(list, 12, 3, { 0.08, 0.06, 0.04, 0.98 }, Theme.COLORS.lit)
	list:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -2)
	list:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -2)
	list:SetFrameLevel(parent:GetFrameLevel() + 20)
	list:EnableMouse(true)
	list:Hide()
	local function Show()
		local option = picker.options[picker.at]
		button:SetLabel(option and option.text or "")
	end
	local function Close()
		list:Hide()
		if openPicker == picker then openPicker = nil end
	end
	local function Open()
		if openPicker and openPicker ~= picker then openPicker.Close() end
		for position, option in ipairs(picker.options) do
			local row = picker.rows[position]
			if not row then
				row = ns.Filters.SmallButton(list, "", 100)
				row:SetPoint("TOPLEFT", 4, -4 - (position - 1) * 20)
				row:SetPoint("TOPRIGHT", -4, -4 - (position - 1) * 20)
				row:SetScript("OnClick", function()
					picker.at = position
					Show()
					Close()
				end)
				picker.rows[position] = row
			end
			row:SetLabel(option.text)
			row:SetSelected(position == picker.at)
			row:Show()
		end
		for position = #picker.options + 1, #picker.rows do
			picker.rows[position]:Hide()
		end
		list:SetHeight(#picker.options * 20 + 8)
		list:Show()
		openPicker = picker
	end
	button:SetScript("OnClick", function()
		if list:IsShown() then Close() else Open() end
	end)
	picker.Close = Close
	function picker:Place(y)
		title:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, y - 4)
		button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, y)
	end
	function picker:SetOptions(options, selected)
		Close()
		self.options, self.at = options, 1
		for position, option in ipairs(options) do
			if option.value == selected then self.at = position end
		end
		Show()
	end
	function picker:Value()
		local option = self.options[self.at]
		return option and option.value
	end
	picker.button, picker.list = button, list
	return picker
end

-- Until a rule says otherwise, the marks are for the officers' ranks.
local function DefaultView(ranks)
	local view = 0
	for _, rank in ipairs(ranks) do
		if Identity.IsOfficerRank(rank.index) then view = math.max(view, rank.index) end
	end
	return view
end

local function BuildRanksDialog()
	local board = ns.UI.Frame()
	local dialog = CreateFrame("Frame", nil, board, "BackdropTemplate")
	dialog:SetSize(460, 250)
	dialog:SetPoint("CENTER", board, "CENTER", 0, 20)
	dialog:SetFrameLevel(board:GetFrameLevel() + 60)
	dialog:EnableMouse(true)
	Theme.Panel(dialog, 14, 4, { 0.10, 0.075, 0.05, 0.98 }, Theme.COLORS.lit)
	Theme.Parchment(dialog, 0.12)
	local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetTextColor(Theme.Color("lit"))
	title:SetText(L.RANKS_TITLE)
	local intro = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	intro:SetPoint("TOPLEFT", 18, -40)
	intro:SetPoint("RIGHT", dialog, "RIGHT", -18, 0)
	intro:SetJustifyH("LEFT")
	intro:SetTextColor(Theme.Color("muted"))
	dialog.intro = intro
	dialog.expected = Picker(dialog, L.RANKS_EXPECTED)
	dialog.expected:Place(-82)
	dialog.reroll = Picker(dialog, L.RANKS_REROLL)
	dialog.reroll:Place(-110)
	dialog.view = Picker(dialog, L.RANKS_VIEW)
	dialog.view:Place(-138)
	local state = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	state:SetPoint("TOPLEFT", 18, -170)
	state:SetPoint("RIGHT", dialog, "RIGHT", -18, 0)
	state:SetJustifyH("LEFT")
	state:SetTextColor(Theme.Color("text"))
	dialog.state = state
	local send = Theme.DarkButton(dialog, L.RANKS_SEND, 160, 22)
	send:SetPoint("BOTTOMLEFT", 18, 14)
	local remove = Theme.DarkButton(dialog, L.RANKS_REMOVE, 140, 22)
	remove:SetPoint("LEFT", send, "RIGHT", 8, 0)
	local close = Theme.DarkButton(dialog, L.RANKS_CLOSE, 90, 22)
	close:SetPoint("BOTTOMRIGHT", -18, 14)
	dialog.send, dialog.remove, dialog.close = send, remove, close

	-- The guild's ranks in the three pickers, on the rule kept when there is
	-- one, and a line on where the rule stands.
	function dialog.Fill()
		local ranks = Identity.Ranks()
		local options, withNone = {}, { { text = L.RANKS_NONE, value = false } }
		for _, rank in ipairs(ranks) do
			local text = ("%d. %s"):format(rank.index + 1, rank.name)
			options[#options + 1] = { text = text, value = rank.index }
			withNone[#withNone + 1] = { text = text, value = rank.index }
		end
		local stored = ns.Ranks.Stored()
		local rule = stored and stored.expected and stored or nil
		intro:SetText(L.RANKS_INTRO:format(ranks[1] and ranks[1].name or "1"))
		-- Until a rule is set the lowest rank shows, which nobody is under.
		dialog.expected:SetOptions(options, rule and rule.expected.index or (ranks[#ranks] and ranks[#ranks].index))
		dialog.reroll:SetOptions(withNone, rule and rule.reroll and rule.reroll.index or false)
		dialog.view:SetOptions(options, rule and rule.view.index or DefaultView(ranks))
		local inForce, why = ns.Ranks.Rule()
		if inForce then
			state:SetText(L.RANKS_STATE_SET:format(Theme.DayTime(inForce.at), inForce.expected.name,
				inForce.reroll and inForce.reroll.name or L.RANKS_NONE, inForce.view.name))
		elseif why == "renamed" then
			state:SetText(L.RANKS_STATE_RENAMED)
		else
			state:SetText(L.RANKS_STATE_NONE)
		end
	end
	send:SetScript("OnClick", function()
		if ns.Ranks.Set(dialog.expected:Value(), dialog.reroll:Value() or nil, dialog.view:Value()) then
			ns.Print(L.RANKS_SENT)
		end
		dialog.Fill()
	end)
	remove:SetScript("OnClick", function()
		if ns.Ranks.Set(nil) then ns.Print(L.RANKS_REMOVED) end
		dialog.Fill()
	end)
	close:SetScript("OnClick", function() dialog:Hide() end)
	-- A list left open goes with the dialog.
	dialog:SetScript("OnHide", function()
		if openPicker then openPicker.Close() end
	end)
	dialog:Hide()
	return dialog
end

-- The dialog, for the guild's first rank only.
function ns.UI.ShowRanksDialog()
	if not ns.Ranks.IsMaster() or not ns.UI.Frame() then return false end
	ranksDialog = ranksDialog or BuildRanksDialog()
	ranksDialog.Fill()
	ranksDialog:Show()
	return true
end

function ns.UI.HideRanksDialog()
	if ranksDialog then ranksDialog:Hide() end
end

function ns.UI.RanksDialog()
	return ranksDialog
end

-- The Discord link's box takes the keyboard, its text selected: one
-- keystroke copies it. For /kbs discord, once the tab is open.
function ns.UI.FocusDiscord()
	local board = ns.UI.Frame()
	local tab = board and board.tabFrames and board.tabFrames.options
	if not (tab and tab.discord) then return false end
	tab.discord:SetFocus()
	return true
end
