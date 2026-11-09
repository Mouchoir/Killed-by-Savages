local _, ns = ...

--------------------------------------------------------------------------------
-- Options tab: the addon's settings, in the board itself. Two leather
-- panels, the window on the left and the chat on the right, with the
-- client's own checkboxes and slider, and the help underneath.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local L = ns.L

local PANEL_HEIGHT = 184
local TOP = 40                    -- first control, under the panel's title

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

		-- The window: minimap button, scale.
		local minimap = Checkbox(window, L.OPTIONS_MINIMAP,
			function() return not Settings().minimap.hide end,
			function(value) ns.MinimapButton.SetShown(value) end)
		minimap:SetPoint("TOPLEFT", 12, -TOP)
		local scaleLabel = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		scaleLabel:SetPoint("TOPLEFT", minimap, "BOTTOMLEFT", 4, -14)
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
			function(value) ns.Killfeed.SetTab(value) end)
		feedTab:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", -4, -8)
		Hint(chat, feedTab, L.OPTIONS_KILLFEED_TAB_HINT)
		function frame.UpdateFeedTab()
			local on = Settings().killfeed == true
			feedTab:SetEnabled(on)
			feedTab.label:SetTextColor(Theme.Color(on and "text" or "disabled"))
		end
		frame.boxes = { minimap, killfeed, feedTab }

		local help = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		help:SetPoint("TOPLEFT", window, "BOTTOMLEFT", 4, -14)
		help:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
		help:SetJustifyH("LEFT")
		help:SetTextColor(Theme.Color("muted"))
		help:SetText(L.OPTIONS_HELP)
		local version = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		version:SetPoint("BOTTOMRIGHT", -4, 2)
		version:SetTextColor(Theme.Color("disabled"))
		version:SetText(L.OPTIONS_VERSION:format(tostring(ns.VERSION)))
	end,
	Refresh = function(frame)
		for _, box in ipairs(frame.boxes) do
			box:SetChecked(box.get() and true or false)
		end
		frame.UpdateFeedTab()
		-- A refresh while the thumb is held leaves the number it shows.
		if not frame.slider.held then
			local scale = tonumber(Settings().scale) or 1
			frame.slider:SetValue(scale)
			frame.scaleValue:SetText(Percent(scale))
		end
	end,
})
