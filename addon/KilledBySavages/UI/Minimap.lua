local _, ns = ...

--------------------------------------------------------------------------------
-- Minimap button, through LibDataBroker and LibDBIcon so that button
-- managers recognise it. Left click opens the board, right click the options.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local Stats = ns.Stats
local L = ns.L

local Minimap = {}
ns.MinimapButton = Minimap

local ICON = "Interface\\AddOns\\KilledBySavages\\Media\\Logo"

local function Register()
	if not LibStub then return end
	local ldb = LibStub("LibDataBroker-1.1", true)
	local icon = LibStub("LibDBIcon-1.0", true)
	if not (ldb and icon) then return end
	local object = ldb:NewDataObject("KilledBySavages", {
		type = "launcher",
		text = L.ADDON_NAME,
		icon = ICON,
		OnClick = function(_, button)
			if button == "RightButton" then
				ns.OpenOptions()
			else
				ns.ToggleWindow()
			end
		end,
		OnTooltipShow = function(tooltip)
			if not tooltip or not tooltip.AddLine then return end
			tooltip:AddLine(L.ADDON_NAME, Theme.Color("gold"))
			local ok, guild = pcall(Stats.Guild, "week", "all")
			if ok and guild then
				tooltip:AddLine(L.MINIMAP_WEEK:format(guild.kills, guild.distinct), 0.93, 0.84, 0.66)
			end
			tooltip:AddLine(L.MINIMAP_TOOLTIP_LEFT, 0.8, 0.8, 0.8)
			tooltip:AddLine(L.MINIMAP_TOOLTIP_RIGHT, 0.8, 0.8, 0.8)
		end,
	})
	local settings = ns.db.settings.minimap
	local ok, message = pcall(icon.Register, icon, "KilledBySavages", object, settings)
	if ok then
		Minimap.icon = icon
		Minimap.registered = true
	else
		ns.Error("minimap", message)
	end
end

function Minimap.SetShown(shown)
	ns.db.settings.minimap.hide = not shown
	if not Minimap.icon then return end
	if shown then
		pcall(Minimap.icon.Show, Minimap.icon, "KilledBySavages")
	else
		pcall(Minimap.icon.Hide, Minimap.icon, "KilledBySavages")
	end
end

ns.Hook("Login", function()
	Util.Guard("minimap", Register)
end)
