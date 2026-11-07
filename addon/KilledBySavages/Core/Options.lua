local _, ns = ...

--------------------------------------------------------------------------------
-- Options: a page of our own in the game's Settings (a canvas category),
-- which keeps the Settings search untouched. Three settings and a button.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local L = ns.L

local Options = {}
ns.Options = Options

local category

local function Checkbox(parent, label, get, set)
	local box = Theme.TryCreate("CheckButton", nil, parent, { "UICheckButtonTemplate", "InterfaceOptionsCheckButtonTemplate" })
	box:SetSize(26, 26)
	local text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("LEFT", box, "RIGHT", 4, 0)
	text:SetText(label)
	box.label = text
	box:SetScript("OnClick", function(self)
		set(self:GetChecked() and true or false)
	end)
	box:SetScript("OnShow", function(self)
		self:SetChecked(get() and true or false)
	end)
	return box
end

local function Build()
	local panel = CreateFrame("Frame")
	panel.name = L.ADDON_NAME
	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(L.ADDON_NAME)
	title:SetTextColor(Theme.Color("gold"))
	local version = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	version:SetPoint("LEFT", title, "RIGHT", 8, -2)
	version:SetText(ns.VERSION)
	version:SetTextColor(Theme.Color("muted"))

	local minimap = Checkbox(panel, L.OPTIONS_MINIMAP,
		function() return not ns.db.settings.minimap.hide end,
		function(value) ns.MinimapButton.SetShown(value) end)
	minimap:SetPoint("TOPLEFT", 16, -56)

	local announce = Checkbox(panel, L.OPTIONS_ANNOUNCE,
		function() return ns.db.settings.announce end,
		function(value) ns.db.settings.announce = value end)
	announce:SetPoint("TOPLEFT", minimap, "BOTTOMLEFT", 0, -8)

	local scaleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	scaleLabel:SetPoint("TOPLEFT", announce, "BOTTOMLEFT", 4, -16)
	scaleLabel:SetText(L.OPTIONS_SCALE)
	local slider = Theme.TryCreate("Slider", nil, panel, { "OptionsSliderTemplate" })
	slider:SetPoint("TOPLEFT", scaleLabel, "BOTTOMLEFT", 0, -12)
	slider:SetSize(200, 16)
	slider:SetMinMaxValues(0.6, 1.4)
	slider:SetValueStep(0.05)
	if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
	local scaleValue = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	scaleValue:SetPoint("LEFT", slider, "RIGHT", 12, 0)
	slider:SetScript("OnValueChanged", function(self, value)
		local applied = ns.UI.SetScale(value)
		scaleValue:SetText(("%d%%"):format(applied * 100 + 0.5))
	end)
	slider:SetScript("OnShow", function(self)
		self:SetValue(tonumber(ns.db.settings.scale) or 1)
	end)
	if slider.Low then slider.Low:SetText("60%") end
	if slider.High then slider.High:SetText("140%") end

	local open = Theme.TryCreate("Button", nil, panel, { "UIPanelButtonTemplate" })
	open:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -24)
	open:SetSize(180, 24)
	open:SetText(L.OPTIONS_OPEN)
	open:SetScript("OnClick", function() ns.ToggleWindow() end)

	local help = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -16)
	help:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	help:SetJustifyH("LEFT")
	help:SetTextColor(Theme.Color("muted"))
	help:SetText(L.OPTIONS_HELP)
	return panel
end

local function Register()
	if not (type(Settings) == "table" and Util.Fn(Settings.RegisterCanvasLayoutCategory)) then return end
	local panel = Build()
	local ok, created = pcall(Settings.RegisterCanvasLayoutCategory, panel, L.ADDON_NAME)
	if not ok or not created then return end
	category = created
	if Util.Fn(Settings.RegisterAddOnCategory) then pcall(Settings.RegisterAddOnCategory, category) end
end

function Options.Open()
	if category and type(Settings) == "table" and Util.Fn(Settings.OpenToCategory) then
		local id = category.GetID and category:GetID() or category
		pcall(Settings.OpenToCategory, id)
		return true
	end
	ns.Print(L.OPTIONS_SOON)
	return false
end

ns.Hook("Login", function()
	Util.Guard("options", Register)
end)
