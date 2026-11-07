local _, ns = ...

--------------------------------------------------------------------------------
-- Theme
--
-- The window is the Forever client's own bronze frame over dark rock
-- (the OpenMap shell), with brown leather panels grained like parchment,
-- gold hairlines and gold titles inside (the DungeonJournal recipe). Only
-- game textures and fonts are used; every atlas and template is checked
-- before use and has a fallback, so the window never fails to open.
--------------------------------------------------------------------------------

local Util = ns.Util

local Theme = {}
ns.Theme = Theme

Theme.COLORS = {
	bronze = { 0.66, 0.49, 0.28 },
	lit = { 1, 0.82, 0.3 },
	gold = { 1, 0.82, 0 },
	title = { 1, 0.80, 0.34 },
	head = { 0.96, 0.80, 0.50 },
	text = { 0.93, 0.84, 0.66 },
	muted = { 0.82, 0.74, 0.60 },
	disabled = { 0.6, 0.53, 0.4 },
	leather = { 0.17, 0.12, 0.07, 0.96 },
	leatherBorder = { 0.52, 0.36, 0.16, 1 },
	band = { 0.26, 0.18, 0.09, 0.94 },
	buttonBg = { 0.12, 0.115, 0.105, 0.98 },
	buttonBorder = { 0.48, 0.40, 0.27, 1 },
	selected = { 0.75, 0.55, 0.1 },
	rock = { 0.1, 0.09, 0.08, 1 },
	horde = { 0.749, 0.29, 0.29 },
	alliance = { 0.29, 0.478, 0.749 },
	green = { 0.12, 1, 0.25 },
}

Theme.PAD = 16
Theme.ROW = 22
Theme.FONT_PATH = "Fonts\\MORPHEUS.TTF"

local WHITE = "Interface\\Buttons\\WHITE8X8"
local TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"
local PARCHMENT = "Interface\\QuestFrame\\QuestBG"
local HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

local function Color(name)
	return unpack(Theme.COLORS[name])
end
Theme.Color = Color

function Theme.HasAtlas(name)
	if not (C_Texture and Util.Fn(C_Texture.GetAtlasInfo)) then return false end
	local ok, info = pcall(C_Texture.GetAtlasInfo, name)
	return ok and type(info) == "table"
end

-- A frame from the first template the client knows, with the name of the
-- template that worked.
function Theme.TryCreate(kind, name, parent, templates)
	for _, template in ipairs(templates) do
		local ok, frame = pcall(CreateFrame, kind, name, parent, template)
		if ok and frame then return frame, template end
	end
	local frame = CreateFrame(kind, name, parent, "BackdropTemplate")
	return frame, nil
end

--------------------------------------------------------------------------------
-- Panels
--------------------------------------------------------------------------------

-- A leather panel: flat fill with the tooltip border tinted brown, and the
-- quest parchment laid over it at low alpha for the paper grain.
function Theme.Panel(frame, edge, inset, fill, border)
	if not frame.SetBackdrop then return frame end
	frame:SetBackdrop({
		bgFile = WHITE, edgeFile = TOOLTIP_BORDER, tile = true, tileSize = 16,
		edgeSize = edge or 14, insets = { left = inset or 4, right = inset or 4, top = inset or 4, bottom = inset or 4 },
	})
	frame:SetBackdropColor(unpack(fill or Theme.COLORS.leather))
	frame:SetBackdropBorderColor(unpack(border or Theme.COLORS.leatherBorder))
	return frame
end

function Theme.Parchment(frame, alpha)
	local texture = frame:CreateTexture(nil, "BACKGROUND", nil, -2)
	texture:SetPoint("TOPLEFT", 3, -3)
	texture:SetPoint("BOTTOMRIGHT", -3, 3)
	texture:SetTexture(PARCHMENT)
	texture:SetTexCoord(0, 1, 0, 1)
	texture:SetVertexColor(1, 0.95, 0.83)
	texture:SetAlpha(alpha or 0.16)
	return texture
end

-- A 1 px bronze hairline.
function Theme.Rule(parent, alpha)
	local line = parent:CreateTexture(nil, "ARTWORK")
	line:SetColorTexture(Theme.COLORS.bronze[1], Theme.COLORS.bronze[2], Theme.COLORS.bronze[3], alpha or 0.5)
	line:SetHeight(1)
	return line
end

-- A gold title with a hairline on each side.
function Theme.Divider(parent, text, width)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(width or 200, 16)
	local label = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("CENTER")
	label:SetText(text)
	label:SetTextColor(Color("title"))
	local left = holder:CreateTexture(nil, "ARTWORK")
	left:SetColorTexture(0.54, 0.39, 0.17, 0.72)
	left:SetHeight(1)
	left:SetPoint("LEFT", holder, "LEFT", 0, 0)
	left:SetPoint("RIGHT", label, "LEFT", -8, 0)
	local right = holder:CreateTexture(nil, "ARTWORK")
	right:SetColorTexture(0.54, 0.39, 0.17, 0.72)
	right:SetHeight(1)
	right:SetPoint("RIGHT", holder, "RIGHT", 0, 0)
	right:SetPoint("LEFT", label, "RIGHT", 8, 0)
	holder.label = label
	return holder
end

function Theme.Highlight(frame)
	local highlight = frame:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture(HIGHLIGHT)
	highlight:SetBlendMode("ADD")
	highlight:SetAlpha(0.6)
	return highlight
end

--------------------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------------------

-- The dark button: tooltip border, near-black fill, gold text; lit when
-- selected.
function Theme.DarkButton(parent, text, width, height)
	local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
	button:SetSize(width or 90, height or 22)
	Theme.Panel(button, 12, 4, Theme.COLORS.buttonBg, Theme.COLORS.buttonBorder)
	local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	label:SetPoint("CENTER", 0, 0)
	label:SetText(text)
	label:SetTextColor(1, 0.82, 0.27)
	button.label = label
	Theme.Highlight(button)
	function button:SetSelected(selected)
		self.selected = selected
		if selected then
			self:SetBackdropBorderColor(Color("lit"))
			self.label:SetTextColor(1, 1, 1)
		else
			self:SetBackdropBorderColor(unpack(Theme.COLORS.buttonBorder))
			self.label:SetTextColor(1, 0.82, 0.27)
		end
	end
	function button:SetLabel(value)
		self.label:SetText(value)
	end
	return button
end

-- A row of dark buttons where one is selected at a time.
function Theme.ButtonGroup(parent, options, width, onSelect)
	local group = { buttons = {}, value = nil }
	local previous
	for _, option in ipairs(options) do
		local button = Theme.DarkButton(parent, option.text, option.width or width)
		button.value = option.value
		if previous then
			button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
		end
		button:SetScript("OnClick", function()
			group:Select(option.value)
			if onSelect then onSelect(option.value) end
		end)
		group.buttons[#group.buttons + 1] = button
		previous = button
	end
	function group:Select(value)
		self.value = value
		for _, button in ipairs(self.buttons) do
			button:SetSelected(button.value == value)
		end
	end
	function group:Width()
		local total = 0
		for _, button in ipairs(self.buttons) do total = total + button:GetWidth() + 4 end
		return total - 4
	end
	return group
end

--------------------------------------------------------------------------------
-- Text, icons, colours
--------------------------------------------------------------------------------

function Theme.ClassColor(classFile)
	if type(classFile) ~= "string" then return 0.9, 0.9, 0.9 end
	if C_ClassColor and Util.Fn(C_ClassColor.GetClassColor) then
		local ok, color = pcall(C_ClassColor.GetClassColor, classFile)
		if ok and type(color) == "table" and color.r then return color.r, color.g, color.b end
	end
	local colors = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
	if type(colors) == "table" and colors.r then return colors.r, colors.g, colors.b end
	return 0.9, 0.9, 0.9
end

function Theme.ClassIcon(texture, classFile)
	if type(classFile) == "string" then
		local atlas = "classicon-" .. classFile:lower()
		if Theme.HasAtlas(atlas) then
			texture:SetTexCoord(0, 1, 0, 1)
			texture:SetAtlas(atlas)
			texture:Show()
			return true
		end
	end
	texture:Hide()
	return false
end

local RACE_ATLAS = {
	Scourge = "undead", NightElf = "nightelf", BloodElf = "bloodelf", Human = "human", Dwarf = "dwarf", Gnome = "gnome",
	Draenei = "draenei", Worgen = "worgen", Orc = "orc", Tauren = "tauren", Troll = "troll", Goblin = "goblin",
}

function Theme.RaceIcon(texture, raceFile)
	local race = type(raceFile) == "string" and RACE_ATLAS[raceFile] or nil
	if race then
		local atlas = "raceicon-" .. race .. "-male"
		if Theme.HasAtlas(atlas) then
			texture:SetTexCoord(0, 1, 0, 1)
			texture:SetAtlas(atlas)
			texture:Show()
			return true
		end
	end
	texture:Hide()
	return false
end

-- The big number of the header, in the game's display face.
function Theme.DisplayFont(fontString, size)
	if not fontString:SetFont(Theme.FONT_PATH, size or 24, "") then
		fontString:SetFontObject(GameFontNormalHuge or GameFontNormalLarge)
	end
	fontString:SetShadowColor(0, 0, 0, 1)
	fontString:SetShadowOffset(1, -1)
	return fontString
end

-- Numbers read better aligned on the right; the K/D keeps one decimal.
function Theme.Number(value)
	if type(value) ~= "number" then return "" end
	return ("%d"):format(value)
end

function Theme.Ratio(value)
	if type(value) ~= "number" then return "" end
	if value >= 100 then return ("%d"):format(value) end
	return ("%.1f"):format(value)
end

function Theme.Time(t)
	if type(t) ~= "number" then return "" end
	local format = Util.Fn(date)
	if not format then return tostring(t) end
	local today = format("%Y-%m-%d", Util.Now())
	if format("%Y-%m-%d", t) == today then return format("%H:%M", t) end
	return format("%d/%m %H:%M", t)
end

function Theme.ZoneName(mapID)
	if type(mapID) ~= "number" or not (C_Map and Util.Fn(C_Map.GetMapInfo)) then return nil end
	local ok, info = pcall(C_Map.GetMapInfo, mapID)
	if ok and type(info) == "table" and type(info.name) == "string" then return info.name end
	return nil
end

--------------------------------------------------------------------------------
-- Tooltips
--------------------------------------------------------------------------------

function Theme.TooltipStart(owner, title)
	if not GameTooltip then return false end
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:ClearLines()
	GameTooltip:AddLine(title, Color("gold"))
	return true
end

function Theme.TooltipLine(text, r, g, b)
	if not GameTooltip then return end
	GameTooltip:AddLine(text, r or 0.8, g or 0.8, b or 0.8, true)
end

function Theme.TooltipDouble(left, right, r, g, b)
	if not GameTooltip then return end
	GameTooltip:AddDoubleLine(left, right, r or 0.8, g or 0.8, b or 0.8, 0.93, 0.84, 0.66)
end

function Theme.TooltipShow()
	if GameTooltip then GameTooltip:Show() end
end

function Theme.TooltipHide()
	if GameTooltip then GameTooltip:Hide() end
end
