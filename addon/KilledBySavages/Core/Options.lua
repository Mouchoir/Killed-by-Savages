local _, ns = ...

--------------------------------------------------------------------------------
-- Options: the settings live in the board's Options tab. The game's
-- Settings get a page of our own (a canvas category, which keeps the
-- Settings search untouched) that says so and opens it.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local L = ns.L

local Options = {}
ns.Options = Options

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

	local where = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	where:SetPoint("TOPLEFT", 16, -56)
	where:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	where:SetJustifyH("LEFT")
	where:SetText(L.OPTIONS_IN_BOARD)
	local open = Theme.TryCreate("Button", nil, panel, { "UIPanelButtonTemplate" })
	open:SetPoint("TOPLEFT", where, "BOTTOMLEFT", 0, -16)
	open:SetSize(180, 24)
	open:SetText(L.OPTIONS_OPEN_TAB)
	open:SetScript("OnClick", function() ns.OpenOptions() end)

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
	local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, L.ADDON_NAME)
	if not ok or not category then return end
	if Util.Fn(Settings.RegisterAddOnCategory) then pcall(Settings.RegisterAddOnCategory, category) end
end

ns.Hook("Login", function()
	Util.Guard("options", Register)
end)
