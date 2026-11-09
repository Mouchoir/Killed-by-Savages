local _, ns = ...

--------------------------------------------------------------------------------
-- The window
--
-- The client's bronze nine-slice frame over tiled dark rock, a title bar,
-- a row of tabs under a bronze hairline, then the band: the enemies killed
-- over the period, the guild's progress to its next milestone, and the
-- period and bucket filters. Each tab fills the content area below.
--------------------------------------------------------------------------------

local Util = ns.Util
local Theme = ns.Theme
local Stats = ns.Stats
local L = ns.L

local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 820, 560
local TITLE_BAR = 21
local PAD = Theme.PAD
local BAND = 48
local FOOTER = 14
local NAME = "KilledBySavagesFrame"
local ROSTER_REFRESH = 60         -- seconds between guild roster requests while the board is open

UI.tabs = {}
UI.tabOrder = {}
local frame
local state = { tab = "players", period = "week", bucket = "all" }

function UI.RegisterTab(definition)
	UI.tabs[definition.key] = definition
	UI.tabOrder[#UI.tabOrder + 1] = definition.key
end

--------------------------------------------------------------------------------
-- Shell
--------------------------------------------------------------------------------

local function Settings()
	return ns.db and ns.db.settings or {}
end

local function SavePosition()
	if not frame then return end
	local point, _, relativePoint, x, y = frame:GetPoint(1)
	if point then
		Settings().window = { point = point, relativePoint = relativePoint, x = x, y = y }
	end
end

local function RestorePosition()
	local saved = Settings().window
	frame:ClearAllPoints()
	if type(saved) == "table" and saved.point then
		frame:SetPoint(saved.point, UIParent, saved.relativePoint or saved.point, saved.x or 0, saved.y or 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
	end
end

-- One line on where the sync with the guild stands, for the footer and
-- /kbs status: what is coming, what is here, who is around.
function UI.SyncText(status)
	if status.phase == "noguild" then return L.SYNC_NO_GUILD end
	if status.phase == "recovery" then return L.SYNC_RECOVERY end
	if status.phase == "paused" then return L.SYNC_PAUSED end
	if status.phase == "waiting" then return L.SYNC_WAITING:format(math.ceil(status.helloIn or 0)) end
	if status.phase == "busy" then return L.SYNC_BUSY:format(status.pagesIn or 0, status.requests or 0) end
	if (status.peers or 0) == 0 and (status.held or 0) == 0 then return L.SYNC_ALONE end
	return L.SYNC_IDLE:format(status.held or 0, status.peers or 0)
end

local function RefreshFooter()
	if not frame or not frame.footer or not ns.Sync then return end
	local status = ns.Sync.Status()
	frame.footer:SetText(UI.SyncText(status))
	frame.footer:SetTextColor(Theme.Color(status.phase == "busy" and "title" or "muted"))
end

local function BuildShell()
	frame = CreateFrame("Frame", NAME, UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition()
	end)
	frame:Hide()

	-- The bronze metal frame of the client, or a gold dialog border.
	local framed = false
	if type(NineSliceUtil) == "table" and Util.Fn(NineSliceUtil.ApplyLayoutByName) then
		local ok, nine = pcall(CreateFrame, "Frame", nil, frame, "NineSlicePanelTemplate")
		if ok and nine and pcall(NineSliceUtil.ApplyLayoutByName, nine, "ButtonFrameTemplateNoPortrait") then
			nine:SetAllPoints()
			nine:SetFrameLevel(frame:GetFrameLevel())
			framed = true
		end
	end
	if not framed and frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
			tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
	end

	-- Dark rock under everything, darkened so small print reads.
	local rock = frame:CreateTexture(nil, "BACKGROUND")
	rock:SetPoint("TOPLEFT", 6, -TITLE_BAR)
	rock:SetPoint("BOTTOMRIGHT", -2, 3)
	if rock:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT") == false then
		rock:SetColorTexture(unpack(Theme.COLORS.rock))
	end
	rock:SetHorizTile(true)
	rock:SetVertTile(true)
	local shade = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
	shade:SetAllPoints(rock)
	shade:SetColorTexture(0, 0, 0, 0.45)

	-- Title
	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 30, -4)
	title:SetPoint("TOPRIGHT", -30, -4)
	title:SetJustifyH("CENTER")
	frame.title = title

	local close = Theme.TryCreate("Button", nil, frame, { "UIPanelCloseButton" })
	close:SetPoint("TOPRIGHT", 1, 0)
	close:SetFrameLevel(frame:GetFrameLevel() + 20)
	close:SetHitRectInsets(-4, -4, -4, -4)
	-- HideUIPanel is blocked in combat; a plain Hide is not.
	close:SetScript("OnClick", function() UI.Hide() end)
	if not close.GetNormalTexture or not close:GetNormalTexture() then
		close:SetSize(22, 22)
		local x = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		x:SetPoint("CENTER")
		x:SetText("x")
	end

	-- Tabs: the boards from the left; a tab that sets the addon up sits at
	-- the right end, in a colour of its own, so it never reads as a board.
	frame.tabButtons = {}
	local previous, previousRight
	for _, key in ipairs(UI.tabOrder) do
		local definition = UI.tabs[key]
		local button = Theme.DarkButton(frame, definition.title, 104, 22)
		if definition.side == "right" then
			if previousRight then
				button:SetPoint("RIGHT", previousRight, "LEFT", -4, 0)
			else
				button:SetPoint("TOPRIGHT", -PAD, -(TITLE_BAR + 10))
			end
			previousRight = button
		else
			if previous then
				button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
			else
				button:SetPoint("TOPLEFT", PAD, -(TITLE_BAR + 10))
			end
			previous = button
		end
		if definition.accent and Theme.COLORS[definition.accent] then button:SetAccent(Theme.COLORS[definition.accent]) end
		button:SetScript("OnClick", function() UI.SelectTab(key) end)
		frame.tabButtons[key] = button
	end
	local rule = Theme.Rule(frame, 0.5)
	rule:SetPoint("TOPLEFT", PAD, -(TITLE_BAR + 10 + 22 + 6))
	rule:SetPoint("TOPRIGHT", -PAD, -(TITLE_BAR + 10 + 22 + 6))

	-- Band: the number, the milestone bar, the filters
	local band = CreateFrame("Frame", nil, frame)
	band:SetPoint("TOPLEFT", PAD, -(TITLE_BAR + 10 + 22 + 6 + 12))
	band:SetPoint("TOPRIGHT", -PAD, -(TITLE_BAR + 10 + 22 + 6 + 12))
	band:SetHeight(BAND)
	frame.band = band

	local number = band:CreateFontString(nil, "OVERLAY")
	Theme.DisplayFont(number, 24)
	number:SetPoint("TOPLEFT", 2, 0)
	number:SetTextColor(Theme.Color("gold"))
	number:SetText("0")
	band.number = number
	local label = band:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("BOTTOMLEFT", number, "BOTTOMRIGHT", 8, 3)
	label:SetTextColor(Theme.Color("head"))
	label:SetText(L.HEADER_ENEMIES_KILLED)
	band.label = label

	-- The milestone bar: the honor bar of the PvP queue when the client has
	-- it, else a leather box with the same gold fill.
	local bar = CreateFrame("Frame", nil, band, "BackdropTemplate")
	bar:SetPoint("TOPLEFT", number, "BOTTOMLEFT", 0, -6)
	bar:SetSize(280, 14)
	local barBg = bar:CreateTexture(nil, "BACKGROUND")
	local fill = bar:CreateTexture(nil, "ARTWORK")
	local barFrame = bar:CreateTexture(nil, "OVERLAY")
	if Theme.HasAtlas("pvpqueue-conquestbar-background") and Theme.HasAtlas("pvpqueue-conquestbar-frame") then
		barBg:SetAtlas("pvpqueue-conquestbar-background")
		barBg:SetAllPoints()
		barFrame:SetAtlas("pvpqueue-conquestbar-frame")
		barFrame:SetPoint("TOPLEFT", -2, 2)
		barFrame:SetPoint("BOTTOMRIGHT", 2, -2)
		fill:SetPoint("TOPLEFT", 1, -1)
		fill:SetPoint("BOTTOMLEFT", 1, 1)
	else
		Theme.Panel(bar, 8, 2, { 0.06, 0.05, 0.04, 0.95 }, Theme.COLORS.leatherBorder)
		barBg:Hide()
		barFrame:Hide()
		fill:SetPoint("TOPLEFT", 3, -3)
		fill:SetPoint("BOTTOMLEFT", 3, 3)
	end
	fill:SetColorTexture(Theme.COLORS.selected[1], Theme.COLORS.selected[2], Theme.COLORS.selected[3], 0.9)
	fill:SetWidth(1)
	bar.fill = fill
	local barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	barText:SetPoint("CENTER")
	bar.text = barText
	bar:SetScript("OnEnter", function(self)
		local milestone = Stats.Milestone()
		if Theme.TooltipStart(self, L.MILESTONE_TITLE) then
			Theme.TooltipLine(L.MILESTONE_NEXT:format(milestone.next))
			Theme.TooltipLine(L.MILESTONE_DISTINCT:format(milestone.distinct))
			Theme.TooltipLine(L.MILESTONE_SCOPE)
			Theme.TooltipShow()
		end
	end)
	bar:SetScript("OnLeave", Theme.TooltipHide)
	band.bar = bar

	local periods = Theme.ButtonGroup(band, {
		{ value = "week", text = L.PERIOD_WEEK, width = 96 },
		{ value = "last", text = L.PERIOD_LAST, width = 116 },
		{ value = "all", text = L.PERIOD_ALL, width = 108 },
	}, 100, function(value) UI.SetPeriod(value) end)
	periods.buttons[1]:SetPoint("TOPRIGHT", band, "TOPRIGHT", -(periods:Width() - periods.buttons[1]:GetWidth()), 0)
	band.periods = periods
	local buckets = Theme.ButtonGroup(band, {
		{ value = "w", text = L.BUCKET_WORLD, width = 96 },
		{ value = "b", text = L.BUCKET_BG, width = 116 },
		{ value = "all", text = L.BUCKET_ALL, width = 108 },
	}, 100, function(value) UI.SetBucket(value) end)
	buckets.buttons[1]:SetPoint("TOPRIGHT", band, "TOPRIGHT", -(buckets:Width() - buckets.buttons[1]:GetWidth()), -26)
	band.buckets = buckets

	-- Content
	local content = CreateFrame("Frame", nil, frame)
	content:SetPoint("TOPLEFT", band, "BOTTOMLEFT", 0, -10)
	content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD - 4 + FOOTER)
	frame.content = content
	frame.tabFrames = {}

	-- Footer: where the sync with the guild stands, kept current while shown.
	local footer = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	footer:SetPoint("BOTTOMLEFT", PAD + 2, PAD - 7)
	footer:SetPoint("BOTTOMRIGHT", -PAD - 2, PAD - 7)
	footer:SetJustifyH("LEFT")
	footer:SetWordWrap(false)
	footer:SetTextColor(Theme.Color("muted"))
	frame.footer = footer
	local sinceTick, sinceRoster = 0, 0
	frame:SetScript("OnUpdate", function(_, elapsed)
		elapsed = tonumber(elapsed) or 0
		sinceTick = sinceTick + elapsed
		sinceRoster = sinceRoster + elapsed
		-- Who is online comes from the guild roster, which the client only
		-- refreshes on request: once a minute while the board is open.
		if sinceRoster >= ROSTER_REFRESH then
			sinceRoster = 0
			Util.Guard("roster", ns.Identity.RequestRoster)
		end
		if sinceTick >= 1 then
			sinceTick = 0
			Util.Guard("footer", RefreshFooter)
		end
	end)

	if type(UISpecialFrames) == "table" then
		table.insert(UISpecialFrames, NAME)
	end
	frame:SetScript("OnShow", function()
		if Util.Fn(PlaySound) and type(SOUNDKIT) == "table" and SOUNDKIT.IG_CHARACTER_INFO_OPEN then
			pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_OPEN)
		end
	end)
	frame:SetScript("OnHide", function()
		if Util.Fn(PlaySound) and type(SOUNDKIT) == "table" and SOUNDKIT.IG_CHARACTER_INFO_CLOSE then
			pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
		end
	end)
	RestorePosition()
	frame:SetScale(tonumber(Settings().scale) or 1)
	return frame
end

--------------------------------------------------------------------------------
-- State and refresh
--------------------------------------------------------------------------------

local function TabFrame(key)
	local definition = UI.tabs[key]
	if not definition then return nil end
	local tabFrame = frame.tabFrames[key]
	if not tabFrame then
		tabFrame = CreateFrame("Frame", nil, frame.content)
		tabFrame:SetAllPoints()
		tabFrame:Hide()
		Util.Guard("tab-build:" .. key, definition.Build, tabFrame)
		frame.tabFrames[key] = tabFrame
	end
	return tabFrame
end

local function RefreshBand()
	local guild = Stats.Guild(state.period, state.bucket)
	frame.band.number:SetText(Theme.Number(guild.distinct))
	local milestone = Stats.Milestone()
	local bar = frame.band.bar
	local width = math.max(1, math.floor((bar:GetWidth() - 6) * milestone.progress))
	bar.fill:SetWidth(width)
	bar.text:SetText(L.MILESTONE_FORMAT:format(milestone.distinct, milestone.next))
	frame.band.periods:Select(state.period)
	frame.band.buckets:Select(state.bucket)
	-- The guild's name follows the title, unless the title already says it.
	local guildName = ns.Identity.me.guild
	if type(guildName) ~= "string" or guildName == "" or L.ADDON_NAME:lower():find(guildName:lower(), 1, true) then
		guildName = nil
	end
	frame.title:SetText(L.ADDON_NAME .. (guildName and (" |cff998866" .. guildName .. "|r") or ""))
end

function UI.Refresh()
	if not frame or not frame:IsShown() then return end
	Util.Guard("band", RefreshBand)
	Util.Guard("footer", RefreshFooter)
	local tabFrame = TabFrame(state.tab)
	local definition = UI.tabs[state.tab]
	if tabFrame and definition then
		Util.Guard("tab-refresh:" .. state.tab, definition.Refresh, tabFrame, state.period, state.bucket)
	end
end

function UI.SelectTab(key)
	if not UI.tabs[key] then return end
	state.tab = key
	Settings().tab = key
	if not frame then return end
	for tabKey, button in pairs(frame.tabButtons) do
		button:SetSelected(tabKey == key)
		local tabFrame = frame.tabFrames[tabKey]
		if tabFrame and tabKey ~= key then tabFrame:Hide() end
	end
	local tabFrame = TabFrame(key)
	if tabFrame then tabFrame:Show() end
	UI.Refresh()
end

function UI.SetPeriod(period)
	state.period = period
	Settings().period = period
	UI.Refresh()
end

function UI.SetBucket(bucket)
	state.bucket = bucket
	Settings().bucket = bucket
	UI.Refresh()
end

function UI.State()
	return state
end

function UI.Show()
	if not frame then
		local settings = Settings()
		if UI.tabs[settings.tab] then state.tab = settings.tab end
		if settings.period == "week" or settings.period == "last" or settings.period == "all" then state.period = settings.period end
		if settings.bucket == "w" or settings.bucket == "b" or settings.bucket == "all" then state.bucket = settings.bucket end
		Util.Guard("window-build", BuildShell)
		if not frame then return end
	end
	Util.Guard("roster", ns.Identity.RequestRoster)
	frame:Show()
	frame:Raise()
	UI.SelectTab(state.tab)
end

function UI.Hide()
	if frame then frame:Hide() end
end

function UI.Toggle()
	if frame and frame:IsShown() then
		UI.Hide()
	else
		UI.Show()
	end
end

function UI.SetScale(scale)
	scale = math.max(0.6, math.min(1.4, tonumber(scale) or 1))
	Settings().scale = scale
	if frame then frame:SetScale(scale) end
	return scale
end

function UI.Frame()
	return frame
end

--------------------------------------------------------------------------------
-- Live updates (the kill lines in the chat are the kill feed's, UI/Killfeed.lua)
--------------------------------------------------------------------------------

local refreshQueued = false
local function QueueRefresh()
	if refreshQueued or not frame or not frame:IsShown() then return end
	refreshQueued = true
	Util.After(0.5, "window-refresh", function()
		refreshQueued = false
		UI.Refresh()
	end)
end

local function ClassName(classFile)
	local names = LOCALIZED_CLASS_NAMES_MALE
	if type(names) == "table" and type(classFile) == "string" and names[classFile] then return names[classFile] end
	return classFile or "?"
end
UI.ClassName = ClassName

local function FooterNow()
	if frame and frame:IsShown() then Util.Guard("footer", RefreshFooter) end
end

ns.Hook("StatsChanged", QueueRefresh)
ns.Hook("RosterUpdated", QueueRefresh)
ns.Hook("SettingsChanged", QueueRefresh)
ns.Hook("SyncChanged", FooterNow)
ns.Hook("PeerSeen", FooterNow)
