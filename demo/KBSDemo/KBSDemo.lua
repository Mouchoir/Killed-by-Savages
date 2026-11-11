--------------------------------------------------------------------------------
-- KBSDemo
--
-- Plays a scripted tour of the Killed by Savages board so that a screen
-- recorder (demo/record.py) can turn it into one GIF per feature. Dev only,
-- never packaged with the addon.
--
--   /kbsdemo                      the whole tour
--   /kbsdemo 3                    one scene (or several: /kbsdemo 2,5)
--   /kbsdemo player=xx enemy=yy   what scenes 1 and 5 type in the search box
--   /kbsdemo stop                 ends it and puts everything back
--
-- It only drives the board's own widgets (its buttons' OnClick, its edit
-- boxes' text), reached through the board's global frame, so the addon under
-- it is the released one, untouched. While it runs:
--   - the board sits in the middle of the screen on a plain dark ground;
--   - a fake pointer shows where the clicks land (the real one is not on a
--     screen capture) and an unseen frame keeps the real mouse off the UI;
--   - four squares in the top left corner of the screen tell the recorder
--     what is going on: [magenta][phase][scene][cyan]. Phase: white while the
--     recorder finds the board (two more markers sit in its corners then),
--     blue between scenes, red during one, black when it is over.
-- The display name and the role it changes for two of the scenes are put
-- back as they were, as are the tab, the period and the board's place.
--
-- No name is written here. Scene 1 types the start of the name of one of
-- the player's own alts, scene 5 the name of the enemy killed most, unless
-- the command says otherwise; what the command said is remembered in the
-- saved variables of this machine. The names of the players who have not
-- updated (scene 6) are replaced on screen before any frame shows them.
--------------------------------------------------------------------------------

local After, Now = C_Timer.After, GetTime

local STRINGS = {
	enUS = {
		STARTED = "tour started, hands off for a minute and a half. /kbsdemo stop ends it.",
		DONE = "tour over.",
		STOPPED = "tour stopped (%s).",
		RUNNING = "the tour is already running. /kbsdemo stop ends it.",
		NONE = "no tour running.",
		NO_BOARD = "the Killed by Savages board does not open: nothing to show.",
		ERROR = "error in scene %d: %s",
		START_ERROR = "could not start: %s",
		NOT_RANKED = "this character is not on the characters ranking of the period shown: the role scene will not find its line. Run the tour on a character that is, if you can.",
		PLAYER = "Player %d",
	},
	frFR = {
		STARTED = "démo lancée, ne touche à rien pendant une minute et demie. /kbsdemo stop pour l'arrêter.",
		DONE = "démo terminée.",
		STOPPED = "démo arrêtée (%s).",
		RUNNING = "la démo tourne déjà. /kbsdemo stop pour l'arrêter.",
		NONE = "aucune démo en cours.",
		NO_BOARD = "le tableau Killed by Savages ne s'ouvre pas : rien à montrer.",
		ERROR = "erreur dans la scène %d : %s",
		START_ERROR = "erreur au lancement : %s",
		NOT_RANKED = "ce personnage n'est pas au classement des personnages de la période affichée : la scène du rôle ne trouvera pas sa ligne. Lance plutôt la démo sur un personnage qui y figure.",
		PLAYER = "Joueur %d",
	},
}
local L = STRINGS[type(GetLocale) == "function" and GetLocale() or "enUS"] or STRINGS.enUS
if L ~= STRINGS.enUS then setmetatable(L, { __index = STRINGS.enUS }) end

local config = {}                 -- player, enemy: what the search scenes type, when the command said so
local only                        -- the scenes to play, when the command named some
local running = false
local generation = 0              -- bumps at every start and stop: timers of an older run do nothing
local sceneIndex = 0
local saved = {}
local focused                     -- the edit box the fake pointer typed in last
local lit                         -- the row or button whose highlight is held

local function Say(text)
	if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffffd14dKBSDemo|r: " .. tostring(text)) end
end

local function Db()
	KBSDemoDB = type(KBSDemoDB) == "table" and KBSDemoDB or {}
	return KBSDemoDB
end

local function Trace(text)
	local db = Db()
	db.trace = db.trace or {}
	db.trace[#db.trace + 1] = tostring(text)
end

local function Trim(text)
	return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The letters of a text, one UTF-8 character each: a name is typed and cut
-- by letters, never through the middle of an accented one.
local function Letters(text)
	local list = {}
	for letter in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do list[#list + 1] = letter end
	return list
end

local function Head(text, count)
	local letters, out = Letters(text), {}
	for index = 1, math.min(count, #letters) do out[index] = letters[index] end
	return Trim(table.concat(out))
end

--------------------------------------------------------------------------------
-- The board
--------------------------------------------------------------------------------

local function Board()
	return _G.KilledBySavagesFrame
end

local function Settings()
	local db = _G.KilledBySavagesDB
	return type(db) == "table" and type(db.settings) == "table" and db.settings or {}
end

local function TabFrame(key)
	local board = Board()
	return board and board.tabFrames and board.tabFrames[key] or nil
end

local function Run(button)
	local handler = button and button.GetScript and button:GetScript("OnClick")
	if handler then handler(button, "LeftButton", false) end
end

local function SelectTab(key)
	local board = Board()
	Run(board and board.tabButtons and board.tabButtons[key])
end

-- A button of the period or bucket group, by its value.
local function Choose(group, value)
	for _, button in ipairs(group and group.buttons or {}) do
		if button.value == value then
			Run(button)
			return true
		end
	end
	return false
end

-- The rows a list shows now, top first.
local function Rows(view)
	local list = {}
	if type(view) ~= "table" then return list end
	local box = view.scrollBox
	if box then
		local frames = box.GetFrames and box:GetFrames() or nil
		if type(frames) ~= "table" then frames = box.rows end
		for _, frame in ipairs(frames or {}) do
			local row = frame.row
			if row and row.data and (not frame.IsShown or frame:IsShown()) then list[#list + 1] = row end
		end
	else
		for _, row in ipairs(view.rows or {}) do
			if row.data and row:IsShown() then list[#list + 1] = row end
		end
	end
	table.sort(list, function(a, b) return (a:GetTop() or 0) > (b:GetTop() or 0) end)
	return list
end

local function FindRow(view, wanted)
	for _, row in ipairs(Rows(view)) do
		if wanted(row.data) then return row end
	end
	return nil
end

local function ResetBar(tab)
	local bar = tab and tab.filters
	if bar and bar.Active and bar:Active() then bar:Reset() end
end

local function ClassButton(bar, classFile)
	for _, button in ipairs(bar and bar.classButtons or {}) do
		if button.classFile == classFile and button:IsShown() then return button end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Markers for the recorder
--------------------------------------------------------------------------------

local COLORS = {
	K = { 0, 0, 0 }, R = { 1, 0, 0 }, G = { 0, 1, 0 }, B = { 0, 0, 1 }, Y = { 1, 1, 0 }, W = { 1, 1, 1 },
	M = { 1, 0, 1 }, C = { 0, 1, 1 },
}
local SCENE_CODES = { "R", "G", "B", "Y", "W", "K" }
local PHASES = { armed = "W", idle = "B", scene = "R", done = "K" }
local SQUARE = 16

local marker, cells, corners, blocker, pointer, shade

local function Paint(texture, code)
	local color = COLORS[code]
	texture:SetColorTexture(color[1], color[2], color[3], 1)
end

local function Overlay(level, width, height)
	local frame = CreateFrame("Frame", nil, UIParent)
	frame:SetFrameStrata("TOOLTIP")
	frame:SetFrameLevel(level)
	frame:SetSize(width, height)
	return frame
end

local function Squares(frame, codes, size)
	local list = {}
	for index, code in ipairs(codes) do
		local texture = frame:CreateTexture(nil, "OVERLAY")
		texture:SetSize(size, size)
		texture:SetPoint("TOPLEFT", (index - 1) * size, 0)
		Paint(texture, code)
		list[index] = texture
	end
	return list
end

local function SetMarker(phase, scene)
	if not marker then return end
	Paint(cells[2], PHASES[phase] or "B")
	Paint(cells[3], SCENE_CODES[scene or 0] or "K")
	marker:Show()
end

local function BuildOverlays(board)
	if not marker then
		marker = Overlay(200, SQUARE * 4, SQUARE)
		marker:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
		cells = Squares(marker, { "M", "B", "K", "C" }, SQUARE)
		-- The board's corners, for the recorder to find it: magenta then
		-- yellow at the top left, yellow then magenta at the bottom right.
		corners = { Overlay(210, 24, 12), Overlay(210, 24, 12) }
		Squares(corners[1], { "M", "Y" }, 12)
		Squares(corners[2], { "Y", "M" }, 12)
		-- Keeps the real mouse off the UI and the world: no stray highlight
		-- or tooltip in the recording.
		blocker = CreateFrame("Frame", nil, UIParent)
		blocker:SetAllPoints(UIParent)
		blocker:SetFrameStrata("FULLSCREEN_DIALOG")
		blocker:EnableMouse(true)
		-- The fake pointer: the game's own glove, its fingertip at the top left.
		pointer = Overlay(250, 28, 28)
		pointer.texture = pointer:CreateTexture(nil, "OVERLAY")
		pointer.texture:SetPoint("TOPLEFT", 0, 0)
		pointer.texture:SetSize(28, 28)
		local known = true
		if type(GetFileIDFromPath) == "function" then
			local ok, id = pcall(GetFileIDFromPath, "Interface\\Cursor\\Point")
			known = ok and type(id) == "number" and id > 0
		end
		if known then
			pointer.texture:SetTexture("Interface\\Cursor\\Point")
		else
			-- No glove on this client: a gold lozenge on a dark one.
			local under = pointer:CreateTexture(nil, "ARTWORK")
			under:SetColorTexture(0, 0, 0, 1)
			under:SetSize(15, 15)
			under:SetPoint("CENTER", pointer, "TOPLEFT", 0, 0)
			under:SetRotation(math.rad(45))
			pointer.texture:ClearAllPoints()
			pointer.texture:SetPoint("CENTER", pointer, "TOPLEFT", 0, 0)
			pointer.texture:SetSize(11, 11)
			pointer.texture:SetColorTexture(1, 0.82, 0.2, 1)
			pointer.texture:SetRotation(math.rad(45))
			pointer.plain = true
		end
	end
	if not shade then
		-- A plain dark ground around the board, drawn with it: the world
		-- behind would move in every frame of the recording.
		shade = board:CreateTexture(nil, "BACKGROUND", nil, -8)
		shade:SetColorTexture(0.04, 0.036, 0.032, 1)
		shade:SetPoint("TOPLEFT", board, "TOPLEFT", -48, 48)
		shade:SetPoint("BOTTOMRIGHT", board, "BOTTOMRIGHT", 48, -48)
	end
	corners[1]:ClearAllPoints()
	corners[1]:SetPoint("TOPLEFT", board, "TOPLEFT", 0, 0)
	corners[2]:ClearAllPoints()
	corners[2]:SetPoint("BOTTOMRIGHT", board, "BOTTOMRIGHT", 0, 0)
	shade:Show()
	blocker:Show()
	pointer:Show()
end

--------------------------------------------------------------------------------
-- The fake pointer
--------------------------------------------------------------------------------

local function ScaleOf(region)
	local scale = region.GetEffectiveScale and region:GetEffectiveScale()
	if type(scale) ~= "number" then
		local parent = region.GetParent and region:GetParent()
		scale = parent and parent.GetEffectiveScale and parent:GetEffectiveScale()
	end
	return type(scale) == "number" and scale > 0 and scale or 1
end

-- A point of a region, in UIParent units from the bottom left of the
-- screen: fx and fy say where in the region (0 to 1, from its left and its
-- bottom), dx and dy move it by so many of the region's own units.
local function PointOf(region, fx, fy, dx, dy)
	local left, bottom = region:GetLeft(), region:GetBottom()
	local width, height = region:GetWidth(), region:GetHeight()
	if type(left) ~= "number" or type(bottom) ~= "number" or type(width) ~= "number" or type(height) ~= "number" then
		return nil
	end
	local parentScale = UIParent:GetEffectiveScale()
	local scale = ScaleOf(region) / (type(parentScale) == "number" and parentScale > 0 and parentScale or 1)
	return (left + width * (fx or 0.5) + (dx or 0)) * scale, (bottom + height * (fy or 0.5) + (dy or 0)) * scale
end

local function Place(x, y)
	pointer.x, pointer.y = x, y
	pointer:ClearAllPoints()
	pointer:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
end

--------------------------------------------------------------------------------
-- Scenes run as coroutines: Wait hands the hand back for a while
--------------------------------------------------------------------------------

local Advance                     -- resumes the scene's coroutine (defined below)

local function Wait(seconds)
	local co, run = coroutine.running(), generation
	After(seconds, function()
		if run ~= generation then return end
		Advance(co)
	end)
	coroutine.yield()
end

-- The pointer glides to a region, eased, at about the pace of a hand.
local function MoveTo(region, fx, fy, dx, dy)
	local x, y = PointOf(region, fx, fy, dx, dy)
	if not x then
		Wait(0.05)
		return
	end
	local fromX, fromY = pointer.x or x, pointer.y or y
	local distance = math.sqrt((x - fromX) ^ 2 + (y - fromY) ^ 2)
	local duration = math.max(0.3, math.min(0.85, distance / 650))
	local start, spins = Now(), 0
	while true do
		local progress = (Now() - start) / duration
		spins = spins + 1
		if progress >= 1 or spins > 600 then break end
		local eased = progress * progress * (3 - 2 * progress)
		Place(fromX + (x - fromX) * eased, fromY + (y - fromY) * eased)
		Wait(0)
	end
	Place(x, y)
end

local function Pulse()
	if pointer.plain then return end
	pointer.texture:SetSize(24, 24)
	local run = generation
	After(0.11, function()
		if run == generation then pointer.texture:SetSize(28, 28) end
	end)
end

local function Unfocus()
	if focused and focused.ClearFocus then focused:ClearFocus() end
	focused = nil
end

local function Unlight()
	if lit and lit.UnlockHighlight then lit:UnlockHighlight() end
	lit = nil
end

local function Light(region)
	Unlight()
	if region and region.LockHighlight then
		region:LockHighlight()
		lit = region
	end
end

-- The pointer goes to a button and clicks it.
local function Click(button, fx, fy, dx, dy)
	if not button then return end
	Unfocus()
	MoveTo(button, fx, fy, dx, dy)
	Light(button)
	Wait(0.12)
	Pulse()
	Wait(0.08)
	Run(button)
	Wait(0.16)
	Unlight()
end

-- The pointer clicks in an edit box and types, a letter at a time.
local function Type(box, text, pace, fx)
	if not box then return end
	Unfocus()
	MoveTo(box, fx or 0.35, 0.5)
	Pulse()
	Wait(0.12)
	if box.SetFocus then box:SetFocus() end
	focused = box
	Wait(0.3)
	local typed = ""
	for _, letter in ipairs(Letters(text)) do
		typed = typed .. letter
		box:SetText(typed)
		if box.SetCursorPosition then box:SetCursorPosition(#typed) end
		Wait(pace or 0.14)
	end
end

-- The tooltip a region shows on hover, put where the recording keeps it:
-- inside the board, not beside it.
local function ShowTip(region, point, anchor, relativePoint, x, y)
	local handler = region and region.GetScript and region:GetScript("OnEnter")
	if not handler or not GameTooltip then return false end
	handler(region)
	if GameTooltip.SetAnchorType then GameTooltip:SetAnchorType("ANCHOR_NONE") end
	GameTooltip:ClearAllPoints()
	GameTooltip:SetPoint(point, anchor, relativePoint, x, y)
	GameTooltip:Show()
	return true
end

local function HideTip()
	if GameTooltip then GameTooltip:Hide() end
end

-- The names of a tooltip's two-column lines become "Player 1", "Player 2":
-- who has not updated is nobody's business in an announcement. Done in the
-- same script run as the tooltip is filled, so no frame shows a name.
local function Anonymize()
	local lines = GameTooltip.NumLines and GameTooltip:NumLines() or 0
	local number = 0
	for line = 2, type(lines) == "number" and lines or 0 do
		local left, right = _G["GameTooltipTextLeft" .. line], _G["GameTooltipTextRight" .. line]
		local text = right and right.GetText and right:GetText() or nil
		if left and type(text) == "string" and text ~= "" and (not right.IsShown or right:IsShown()) then
			number = number + 1
			left:SetText(L.PLAYER:format(number))
		end
	end
	GameTooltip:Show()
	return number
end

--------------------------------------------------------------------------------
-- Putting things back
--------------------------------------------------------------------------------

local ROLES = { "T", "H", "D" }

local function RoleShown(tab)
	for _, role in ipairs(ROLES) do
		local button = tab and tab.roleButtons and tab.roleButtons[role]
		if button and button.selected then return role end
	end
	return nil
end

-- The role this character had before the role scene, quietly.
local function RestoreRole()
	if not saved.roleKnown then return end
	local tab = TabFrame("me")
	local now = RoleShown(tab)
	if now == saved.role then return end
	-- The chosen role clicked again removes it; another one replaces it.
	Run(tab.roleButtons[saved.role or now])
end

-- The display name as it was, to the letter (none stays none).
local function RestoreAlias()
	if not saved.aliasKnown then return end
	local tab = TabFrame("me")
	if (Settings().alias or "") == (saved.alias or "") or not (tab and tab.box and tab.apply) then return end
	tab.box:SetText(saved.alias or "")
	Run(tab.apply)
end

local function Cleanup()
	Unfocus()
	Unlight()
	HideTip()
	local board = Board()
	if board then
		pcall(RestoreRole)
		pcall(RestoreAlias)
		for _, key in ipairs({ "players", "characters", "hunt" }) do ResetBar(TabFrame(key)) end
		if saved.period then Choose(board.band and board.band.periods, saved.period) end
		if saved.bucket then Choose(board.band and board.band.buckets, saved.bucket) end
		if saved.tab then SelectTab(saved.tab) end
		if saved.point and saved.point[1] then
			board:ClearAllPoints()
			board:SetPoint(saved.point[1], saved.point[2], saved.point[3], saved.point[4], saved.point[5])
		end
	end
	if shade then shade:Hide() end
	if blocker then blocker:Hide() end
	if pointer then pointer:Hide() end
	if corners then
		corners[1]:Hide()
		corners[2]:Hide()
	end
end

local function Stop(why)
	if not running then return end
	generation = generation + 1
	running = false
	Cleanup()
	SetMarker("done")
	local run = generation
	After(2.5, function()
		if run == generation and marker then marker:Hide() end
	end)
	Trace("stopped: " .. tostring(why))
	Say(why == "end" and L.DONE or L.STOPPED:format(tostring(why)))
end

--------------------------------------------------------------------------------
-- The scenes, one GIF each
--------------------------------------------------------------------------------

local function Counts(rows, field)
	local counts, order = {}, {}
	for _, row in ipairs(rows or {}) do
		local value = row[field]
		if type(value) == "string" then counts[value] = (counts[value] or 0) + 1 end
	end
	for value, count in pairs(counts) do order[#order + 1] = { value = value, count = count } end
	table.sort(order, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.value < b.value
	end)
	return order
end

local function HasName(rows, needle)
	for _, row in ipairs(rows or {}) do
		if type(row.name) == "string" and row.name:lower():find(needle, 1, true) then return true end
	end
	return false
end

-- What scene 1 types: the start of the name of one of my alts, one my
-- display name does not hold, so that the search shows a player found by
-- an alt. With no alt, the start of the name shown.
local function PlayerSearch()
	if config.player then return config.player end
	local rows = (TabFrame("players") or {}).rows or {}
	local mine = rows[1]
	for _, row in ipairs(rows) do
		if row.me then
			mine = row
			break
		end
	end
	if not mine then return "a" end
	local shown = tostring(mine.name):lower()
	for _, character in ipairs(mine.characters or {}) do
		local name = tostring(character.name)
		if not shown:find(name:lower(), 1, true) then return Head(name, 4):lower() end
	end
	return Head(mine.name, 4):lower()
end

-- What scene 5 types: the enemy killed most over the period shown.
local function EnemySearch()
	if config.enemy then return config.enemy end
	local tab = TabFrame("hunt") or {}
	local first = (tab.victimRows or {})[1] or (tab.killerRows or {})[1]
	return first and type(first.name) == "string" and Head(first.name, 12):lower() or "a"
end

local SCENES = {
	-- 1. A player found by a part of the name of one of its alts.
	{
		tab = "players",
		play = function()
			local tab = TabFrame("players")
			local bar = tab.filters
			local text = PlayerSearch()
			Type(bar.searchBox, text)
			Wait(1.5)
			local row = Rows(tab.view)[1]
			Trace(("scene 1: %d row(s) for the search"):format(#Rows(tab.view)))
			if row then
				Unfocus()
				MoveTo(row, 0.16, 0.45)
				Light(row)
				ShowTip(row, "TOPLEFT", pointer, "BOTTOMRIGHT", 2, -2)
				Wait(3)
				HideTip()
				Unlight()
			end
			Click(bar.reset)
			Wait(1.2)
		end,
	},
	-- 2. The characters ranking narrowed by class, level and role.
	{
		tab = "characters",
		play = function()
			local tab = TabFrame("characters")
			local bar = tab.filters
			local classes = Counts(tab.rows, "class")
			local chosen = {}
			for index = 1, math.min(2, #classes) do
				local button = ClassButton(bar, classes[index].value)
				if button then
					Click(button)
					chosen[classes[index].value] = true
					Wait(1.4)
				end
			end
			local levels = {}
			for _, row in ipairs(tab.rows or {}) do
				if chosen[row.class] and type(row.level) == "number" then levels[#levels + 1] = row.level end
			end
			table.sort(levels)
			if #levels >= 3 and bar.minBox and bar.maxBox then
				Type(bar.minBox, tostring(levels[math.max(1, math.floor(#levels * 0.35))]), 0.22, 0.5)
				Wait(1)
				Type(bar.maxBox, tostring(levels[math.max(1, math.ceil(#levels * 0.8))]), 0.22, 0.5)
				Wait(1.8)
			end
			Trace(("scene 2: %d row(s) after class and level"):format(#Rows(tab.view)))
			Click(bar.reset)
			Wait(1)
			local role
			for _, wanted in ipairs({ "D", "T", "H" }) do
				for _, row in ipairs(tab.rows or {}) do
					if not role and row.role == wanted then role = wanted end
				end
			end
			if role and bar.roleButtons and bar.roleButtons[role] then
				Click(bar.roleButtons[role])
				Wait(2)
				Trace(("scene 2: %d row(s) for a role"):format(#Rows(tab.view)))
				Click(bar.reset)
				Wait(1)
			end
		end,
	},
	-- 3. The role of this character, chosen in the Me tab, shown on the ranking.
	{
		tab = "me",
		play = function()
			local tab = TabFrame("me")
			saved.role, saved.roleKnown = RoleShown(tab), true
			-- The two other roles, then the one it had: never a click on the
			-- chosen one, which would take it off.
			local order = {}
			for _, role in ipairs(ROLES) do
				if role ~= saved.role then order[#order + 1] = role end
			end
			if saved.role then order[#order + 1] = saved.role end
			for _, role in ipairs(order) do
				Click(tab.roleButtons[role])
				Wait(1)
			end
			Trace(("scene 3: role %s, was %s"):format(tostring(RoleShown(tab)), tostring(saved.role)))
			-- The last role stays lit until the scene is over: a character
			-- that had none gets it taken off after, out of the recording.
			Click(Board().tabButtons.characters)
			Wait(0.5)
			local mine = FindRow(TabFrame("characters").view, function(data) return data.me end)
			if mine then
				MoveTo(mine, 0.41, 0.4)
				Light(mine)
			end
			Wait(2.4)
			Unlight()
		end,
		after = function()
			RestoreRole()
		end,
	},
	-- 4. The name of an alt as my display name, in one click.
	{
		tab = "me",
		play = function()
			local tab = TabFrame("me")
			local function UseButton(row)
				for _, cell in ipairs(row and row.cells or {}) do
					if cell.button then return cell.button end
				end
				return nil
			end
			local current, other
			for _, row in ipairs(Rows(tab.view)) do
				local button = UseButton(row)
				if button and button.selected then
					current = current or row.data.name
				elseif button and not other then
					other = row
				end
			end
			Trace(("scene 4: %s"):format(other and "another name to take" or "no other name"))
			if not other then
				Wait(1)
				return
			end
			saved.alias, saved.aliasKnown = Settings().alias, true
			Click(UseButton(other))
			Wait(1.8)
			Click(Board().tabButtons.players)
			Wait(0.5)
			local mine = FindRow(TabFrame("players").view, function(data) return data.me end)
			if mine then
				MoveTo(mine, 0.16, 0.4)
				Light(mine)
			end
			Wait(2.6)
			Unlight()
			Click(Board().tabButtons.me)
			Wait(0.6)
			local back = current and FindRow(tab.view, function(data) return data.name == current end)
			if back and UseButton(back) then
				Click(UseButton(back))
				Wait(1.5)
			end
			RestoreAlias()
			Wait(0.3)
		end,
	},
	-- 5. An enemy found on the hunt boards, then the boards by class.
	{
		tab = "hunt",
		before = function()
			-- An enemy the command named has to be on the boards of the period shown.
			local tab = TabFrame("hunt")
			if config.enemy and not HasName(tab.victimRows, config.enemy) and not HasName(tab.killerRows, config.enemy) then
				saved.periodSwitched = Choose(Board().band.periods, "all")
			end
		end,
		play = function()
			local tab = TabFrame("hunt")
			local bar = tab.filters
			Type(bar.searchBox, EnemySearch(), 0.12)
			Wait(2.6)
			Trace(("scene 5: %d victim row(s), %d killer row(s) for the search"):format(#Rows(tab.victims), #Rows(tab.killers)))
			Click(bar.reset)
			Wait(0.9)
			local classes = Counts(tab.victimRows, "classFile")
			local button = classes[1] and ClassButton(bar, classes[1].value)
			if button then
				Click(button)
				Wait(2.2)
				Click(bar.reset)
				Wait(0.9)
			end
		end,
		after = function()
			if saved.periodSwitched then
				Choose(Board().band.periods, saved.demoPeriod)
				saved.periodSwitched = nil
			end
		end,
	},
	-- 6. Who has not updated the addon, names hidden.
	{
		tab = "players",
		play = function()
			local notice = Board().outdated
			if not (notice and notice:IsShown()) then
				Trace("scene 6: no notice")
				Wait(1)
				return
			end
			Wait(0.4)
			MoveTo(notice, 0, 0.5, 5, 0)
			Wait(0.25)
			if ShowTip(notice, "BOTTOMRIGHT", notice, "TOPRIGHT", 0, 8) then
				Trace(("scene 6: %d name(s) hidden"):format(Anonymize()))
			end
			Wait(4.5)
			HideTip()
			Wait(0.6)
		end,
	},
}

--------------------------------------------------------------------------------
-- The run
--------------------------------------------------------------------------------

local StartScene

local function Fail(message)
	local db = Db()
	db.errors = db.errors or {}
	db.errors[#db.errors + 1] = ("scene %d: %s"):format(sceneIndex, tostring(message))
	Say(L.ERROR:format(sceneIndex, tostring(message)))
	Unfocus()
	Unlight()
	HideTip()
end

function Advance(co)
	local ok, message = coroutine.resume(co)
	if not ok then Fail(message) end
	if not ok or coroutine.status(co) == "dead" then
		if not running then return end
		SetMarker("idle")
		local run, nextIndex = generation, sceneIndex + 1
		After(0.6, function()
			if run == generation then StartScene(nextIndex) end
		end)
	end
end

function StartScene(index)
	while SCENES[index] and only and not only[index] do index = index + 1 end
	sceneIndex = index
	local scene = SCENES[index]
	if not scene then
		Stop("end")
		return
	end
	Trace("scene " .. index .. " starts")
	Advance(coroutine.create(function()
		for _, key in ipairs({ "players", "characters", "hunt" }) do ResetBar(TabFrame(key)) end
		SelectTab(scene.tab)
		if scene.before then scene.before() end
		Wait(0.5)
		SetMarker("scene", index)
		Wait(0.9)
		scene.play()
		Wait(0.7)
		SetMarker("idle")
		if scene.after then scene.after() end
	end))
end

local function Start()
	if running then
		Say(L.RUNNING)
		return
	end
	local board = Board()
	if not (board and board:IsShown()) and type(KilledBySavages_OnAddonCompartmentClick) == "function" then
		KilledBySavages_OnAddonCompartmentClick()
		board = Board()
	end
	if not (board and board:IsShown() and board.tabButtons and board.band) then
		Say(L.NO_BOARD)
		return
	end
	local db = Db()
	db.trace, db.errors, db.startedAt = {}, {}, time and time() or 0
	generation = generation + 1
	running = true
	-- What the board shows now, read off its own buttons: the settings
	-- only hold what the player changed.
	saved = { period = board.band.periods.value, bucket = board.band.buckets.value, point = { board:GetPoint(1) } }
	for key, button in pairs(board.tabButtons) do
		if button.selected then saved.tab = key end
	end
	board:ClearAllPoints()
	board:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	-- Every tab built, every bar empty, the world, and the first period
	-- that has enough to show: the week, else last week, else all time.
	for _, key in ipairs({ "me", "hunt", "characters", "players" }) do
		SelectTab(key)
		ResetBar(TabFrame(key))
	end
	Choose(board.band.buckets, "w")
	saved.demoPeriod = "all"
	for _, period in ipairs({ "week", "last", "all" }) do
		Choose(board.band.periods, period)
		if #(TabFrame("players").rows or {}) >= 10 then
			saved.demoPeriod = period
			break
		end
	end
	Choose(board.band.periods, saved.demoPeriod)
	Trace("period " .. saved.demoPeriod)
	-- The role scene ends on this character's line of the ranking.
	SelectTab("characters")
	local ranked = false
	for _, row in ipairs(TabFrame("characters").rows or {}) do
		if row.me then ranked = true end
	end
	SelectTab("players")
	if not ranked and (not only or only[3]) then Say(L.NOT_RANKED) end
	BuildOverlays(board)
	local x, y = PointOf(board, 0.5, 0.5)
	if x then Place(x, y) end
	corners[1]:Show()
	corners[2]:Show()
	SetMarker("armed")
	Say(L.STARTED)
	local run = generation
	After(3, function()
		if run ~= generation then return end
		corners[1]:Hide()
		corners[2]:Hide()
		SetMarker("idle")
		After(0.8, function()
			if run == generation then StartScene(1) end
		end)
	end)
	After(300, function()
		if run == generation then Stop("timeout") end
	end)
end

-- "/kbsdemo 2,5 player=abc enemy=some name": the scenes before the first
-- key, then each key's text up to the next key.
local function Parse(input)
	input = tostring(input or "")
	local keys = {}
	for position, key in input:gmatch("()(%a+)=") do keys[#keys + 1] = { at = position, key = key:lower() } end
	local options = {}
	for index, item in ipairs(keys) do
		local from = item.at + #item.key + 1
		local to = keys[index + 1] and keys[index + 1].at - 1 or #input
		options[item.key] = (Trim(input:sub(from, to)):gsub('^"(.*)"$', "%1"))
	end
	local head = keys[1] and input:sub(1, keys[1].at - 1) or input
	local scenes
	for number in head:gmatch("%d+") do
		scenes = scenes or {}
		scenes[tonumber(number)] = true
	end
	return head:lower():find("stop", 1, true) ~= nil, scenes, options
end

SLASH_KBSDEMO1 = "/kbsdemo"
SlashCmdList.KBSDEMO = function(input)
	local stop, scenes, options = Parse(input)
	if stop then
		if running then Stop("stop") else Say(L.NONE) end
		return
	end
	-- What the command says the search scenes type is kept for the next
	-- time, on this machine only; an empty text goes back to the tour's own choice.
	local db = Db()
	db.config = type(db.config) == "table" and db.config or {}
	for _, key in ipairs({ "player", "enemy" }) do
		if options[key] ~= nil then db.config[key] = options[key] ~= "" and options[key]:lower() or nil end
		config[key] = db.config[key]
	end
	only = scenes
	local ok, message = pcall(Start)
	if not ok then
		Say(L.START_ERROR:format(tostring(message)))
		running = false
	end
end
