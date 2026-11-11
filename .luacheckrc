-- Luacheck config for WoW Forever addon Lua (Lua 5.1 runtime, 12.x API).
std = "lua51"
max_line_length = false   -- report strings and long API lists
unused_args = false       -- WoW callbacks pass arguments we often ignore

read_globals = {
	-- Lua helpers the game adds
	"issecretvalue", "issecrettable", "date", "time",

	-- Client, frames, timers
	"CreateFrame", "C_Timer", "GetTime", "GetServerTime", "GetLocale", "GetBuildInfo", "WOW_PROJECT_ID",
	"UIParent", "UISpecialFrames", "DEFAULT_CHAT_FRAME", "ChatFontNormal", "GameFontHighlightSmall",
	"Enum", "C_RestrictedActions", "C_Secrets", "C_DateAndTime", "C_AddOns", "GetAddOnMetadata",
	"LibStub", "InCombatLockdown", "PlaySound", "SOUNDKIT", "GameTooltip", "CreateColor", "IsMouseButtonDown", "NEW_CHAT_WINDOW",
	"C_SpecializationInfo", "GetSpecialization", "GetSpecializationRole", "UnitGroupRolesAssigned",
	"C_Texture", "C_XMLUtil", "C_ClassColor", "RAID_CLASS_COLORS", "NineSliceUtil",
	"ScrollUtil", "CreateScrollBoxListLinearView", "CreateDataProvider", "ScrollBoxConstants",
	"PanelTemplates_SelectTab", "PanelTemplates_DeselectTab", "PanelTemplates_SetNumTabs", "PanelTemplates_TabResize",
	"Settings", "STANDARD_TEXT_FONT", "GameFontNormalHuge", "GameFontNormalLarge", "LOCALIZED_CLASS_NAMES_MALE",
	"ChatFrame_AddMessageEventFilter", "ERR_CHAT_PLAYER_NOT_FOUND_S",
	"FCF_OpenNewWindow", "FCF_Close", "FCF_IsChatWindowIndexActive", "FCFDock_GetSelectedWindow",
	"FCFDock_SelectWindow", "GENERAL_CHAT_DOCK", "GetChatWindowInfo", "NUM_CHAT_WINDOWS", "Constants",
	"HideUIPanel", "SettingsPanel",

	-- Where we are
	"IsInInstance", "GetInstanceInfo", "GetRealZoneText", "GetSubZoneText", "C_Map", "C_PvP",
	"IsInRaid", "IsInGroup", "GetNumGroupMembers", "GetRaidRosterInfo",

	-- Units and players
	"UnitGUID", "UnitName", "UnitFullName", "GetUnitName", "UnitClass", "UnitRace", "UnitLevel", "UnitFactionGroup",
	"UnitExists", "UnitIsPlayer", "UnitIsPVP", "UnitTokenFromGUID", "GetPlayerInfoByGUID",
	"GetRealmName", "GetNormalizedRealmName", "BNGetInfo",

	-- Guild
	"IsInGuild", "GetGuildInfo", "GetNumGuildMembers", "GetGuildRosterInfo", "GuildRoster", "C_GuildInfo",
	"GuildControlGetRankFlags",

	-- PvP
	"GetPVPSessionStats", "GetPVPLifetimeStats", "GetPVPYesterdayStats",
	"GetNumBattlefieldScores", "RequestBattlefieldScoreData", "GetBattlefieldWinner", "C_DeathRecap",

	-- Inspect
	"CanInspect", "NotifyInspect", "ClearInspectPlayer", "GetInspectHonorData", "HasInspectHonorData",
	"RequestInspectHonorData", "InspectFrame",

	-- Hidden messages
	"C_ChatInfo",
}

globals = {
	-- SavedVariables, slash and compartment handlers
	"KBSProbeDB", "SLASH_KBSPROBE1", "SlashCmdList",
	"KilledBySavagesDB", "SLASH_KILLEDBYSAVAGES1", "KilledBySavages_OnAddonCompartmentClick",
}

-- Written by the test run, not source; third-party libraries are not ours to lint.
exclude_files = { "tests/last-savedvariables*.lua", "addon/KilledBySavages/Libs/**/*.lua", "dist/**" }

-- The demo tour is a dev addon of its own, with its own saved variables and slash command.
files["demo/**/*.lua"] = { globals = { "KBSDemoDB", "SLASH_KBSDEMO1" }, read_globals = { "GetFileIDFromPath" } }

-- The test harness and the report tool run under LuaJIT, outside the game.
files["tests/**/*.lua"] = { std = "luajit", read_globals = {}, globals = {} }
files["tools/**/*.lua"] = { std = "luajit", read_globals = {}, globals = {} }
