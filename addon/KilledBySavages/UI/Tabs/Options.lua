local _, ns = ...

--------------------------------------------------------------------------------
-- Options tab: the addon's settings, in the board itself. Two leather
-- panels, the window on the left and the chat on the right, with the
-- client's own checkboxes and slider, and the help underneath.
--------------------------------------------------------------------------------

local Theme = ns.Theme
local L = ns.L

local PANEL_HEIGHT = 168
local TOP = 40                    -- first control, under the panel's title

local function Settings()
	return ns.db.settings
end

local function Checkbox(parent, label, get, set)
	local box = Theme.TryCreate("CheckButton", nil, parent, { "UICheckButtonTemplate", "InterfaceOptionsCheckButtonTemplate" })
	box:SetSize(26, 26)
	local text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("LEFT", box, "RIGHT", 4, 0)
	text:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
	text:SetJustifyH("LEFT")
	text:SetWordWrap(false)
	text:SetTextColor(Theme.Color("text"))
	text:SetText(label)
	box.label = text
	box.get = get
	box:SetScript("OnClick", function(self)
		set(self:GetChecked() and true or false)
	end)
	return box
end

local function Panel(parent, title)
	local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	Theme.Panel(panel, 14, 4)
	Theme.Parchment(panel, 0.16)
	local divider = Theme.Divider(panel, title, 220)
	divider:SetPoint("TOP", 0, -12)
	return panel
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
		slider:SetScript("OnValueChanged", function(_, value)
			local applied = ns.UI.SetScale(value)
			scaleValue:SetText(("%d%%"):format(applied * 100 + 0.5))
		end)
		if slider.Low then slider.Low:SetText("60%") end
		if slider.High then slider.High:SetText("140%") end
		frame.slider, frame.scaleValue = slider, scaleValue

		-- The chat: the kill feed, off by default, in a tab of its own when on.
		local killfeed = Checkbox(chat, L.OPTIONS_KILLFEED,
			function() return Settings().killfeed end,
			function(value)
				if value then ns.Killfeed.Enable() else ns.Killfeed.Disable() end
			end)
		killfeed:SetPoint("TOPLEFT", 12, -TOP)
		local hint = chat:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		hint:SetPoint("TOPLEFT", killfeed, "BOTTOMLEFT", 30, -2)
		hint:SetPoint("RIGHT", chat, "RIGHT", -12, 0)
		hint:SetJustifyH("LEFT")
		hint:SetTextColor(Theme.Color("muted"))
		hint:SetText(L.OPTIONS_KILLFEED_HINT:format(L.KILLFEED_TAB))
		frame.boxes = { minimap, killfeed }

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
		local scale = tonumber(Settings().scale) or 1
		frame.slider:SetValue(scale)
		frame.scaleValue:SetText(("%d%%"):format(scale * 100 + 0.5))
	end,
})
