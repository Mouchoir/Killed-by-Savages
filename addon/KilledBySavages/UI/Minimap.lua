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
local BLINK = 0.6                 -- seconds the button stays red, then dark, while an announcement waits
local RED, DARK = { 1, 0.22, 0.18 }, { 0.34, 0.30, 0.28 }
local blinking, red = false, false

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
			-- Our own addon behind a guildmate's: said here too, in orange,
			-- while the player wants to be reminded of it.
			local newer = ns.Sync and ns.Sync.Reminder()
			if newer then tooltip:AddLine(L.UPDATE_NOTICE:format(newer), Theme.Color("warn")) end
			-- Announcements not looked at yet: what the blinking is about.
			local waiting = ns.News and #ns.News.Unseen() or 0
			if waiting > 0 then
				tooltip:AddLine(waiting == 1 and L.NEWS_MINIMAP_ONE or L.NEWS_MINIMAP_MANY:format(waiting), Theme.Color("warn"))
			end
			tooltip:AddLine(L.MINIMAP_TOOLTIP_LEFT, 0.8, 0.8, 0.8)
			tooltip:AddLine(L.MINIMAP_TOOLTIP_RIGHT, 0.8, 0.8, 0.8)
		end,
	})
	local settings = ns.db.settings.minimap
	local ok, message = pcall(icon.Register, icon, "KilledBySavages", object, settings)
	if ok then
		Minimap.icon = icon
		Minimap.object = object
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

-- The button's icon in a colour: the broker object tells the button.
local function Paint(color)
	local object = Minimap.object
	if not object then return end
	object.iconR, object.iconG, object.iconB = color[1], color[2], color[3]
end

local function Blink()
	if not blinking then return end
	if not ns.News or #ns.News.Unseen() == 0 then
		blinking, Minimap.blinking = false, false
		Paint({ 1, 1, 1 })
		return
	end
	red = not red
	Paint(red and RED or DARK)
	Util.After(BLINK, "minimap-blink", Blink)
end

-- While an announcement waits to be looked at the button goes red, then
-- dark, and back; it takes its own colours again when none does.
function Minimap.Notice()
	local waiting = Minimap.registered and ns.News ~= nil and #ns.News.Unseen() > 0
	if waiting and not blinking then
		blinking, Minimap.blinking, red = true, true, false
		Blink()
	elseif not waiting and blinking then
		blinking, Minimap.blinking = false, false
		Paint({ 1, 1, 1 })
	end
end

ns.Hook("NewsChanged", function() Util.Guard("minimap-notice", Minimap.Notice) end)

ns.Hook("Login", function()
	Util.Guard("minimap", Register)
end)
