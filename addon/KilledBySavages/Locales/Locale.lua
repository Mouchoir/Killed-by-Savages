local _, ns = ...

--------------------------------------------------------------------------------
-- Strings
--
-- English is the source. Every user-facing string goes through ns.L; a key
-- without a translation falls back to its English text. Developer output
-- (/kbs debug) stays in English on purpose: it gets pasted into bug reports.
--
-- Style: no em dash, no ellipsis character; French puts a space before ":"
-- and ";". Colour codes and format specifiers live inside the strings.
--------------------------------------------------------------------------------

local L = {
	ADDON_NAME = "Killed by Savages",
	CHAT_PREFIX = "|cffffd14dKilled by Savages|r: ",

	-- /kbs
	HELP_INTRO = "Commands:",
	HELP_OPEN = "/kbs - open or close the kill board",
	HELP_STATUS = "/kbs status - where the addon stands on this character",
	HELP_OPTIONS = "/kbs options - open the options",
	HELP_DEBUG = "/kbs debug - errors and sync state, for bug reports",
	STATUS_VERSION = "Version %s, %s on %s.",
	STATUS_GUILD = "Guild: %s, rank %s%s.",
	STATUS_GUILD_OFFICER = " (officer)",
	STATUS_NO_GUILD = "Not in a guild: kills are not counted until this character joins one.",
	STATUS_PLAYER_KEY_BNET = "Characters are grouped by Battle.net account.",
	STATUS_PLAYER_KEY_FALLBACK = "The BattleTag is not readable here: characters are grouped by WoW account instead.",
	STATUS_ERRORS = "%d error(s) recorded. /kbs debug shows them.",
	STATUS_NO_ERRORS = "No error recorded.",
	STATUS_WINDOW_SOON = "The kill board window is not in this version yet.",
	OPTIONS_SOON = "The options page is not in this version yet.",
	DEBUG_HEADER = "Killed by Savages %s, debug",
}

ns.L = setmetatable(L, { __index = function(_, key) return key end })

local translations = {
	frFR = {
		HELP_INTRO = "Commandes :",
		HELP_OPEN = "/kbs - ouvrir ou fermer le tableau de chasse",
		HELP_STATUS = "/kbs status - où en est l'addon sur ce personnage",
		HELP_OPTIONS = "/kbs options - ouvrir les options",
		HELP_DEBUG = "/kbs debug - erreurs et état de la synchro, pour les rapports de bug",
		STATUS_VERSION = "Version %s, %s sur %s.",
		STATUS_GUILD = "Guilde : %s, grade %s%s.",
		STATUS_GUILD_OFFICER = " (officier)",
		STATUS_NO_GUILD = "Pas de guilde : les kills ne comptent pas tant que ce personnage n'en a pas rejoint une.",
		STATUS_PLAYER_KEY_BNET = "Les personnages sont regroupés par compte Battle.net.",
		STATUS_PLAYER_KEY_FALLBACK = "Le BattleTag n'est pas lisible ici : les personnages sont regroupés par compte WoW.",
		STATUS_ERRORS = "%d erreur(s) enregistrée(s). /kbs debug les affiche.",
		STATUS_NO_ERRORS = "Aucune erreur enregistrée.",
		STATUS_WINDOW_SOON = "La fenêtre du tableau de chasse n'est pas encore dans cette version.",
		OPTIONS_SOON = "La page d'options n'est pas encore dans cette version.",
	},
}

-- Every key per locale, for the test that checks translations stay complete.
ns.LocaleKeys = { enUS = {} }
for key in pairs(L) do
	ns.LocaleKeys.enUS[key] = true
end
for locale, table_ in pairs(translations) do
	local keys = {}
	for key in pairs(table_) do
		keys[key] = true
	end
	ns.LocaleKeys[locale] = keys
end

local applied = translations[GetLocale()]
if applied then
	for key, value in pairs(applied) do
		L[key] = value
	end
end
