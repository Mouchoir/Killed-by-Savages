-- Reads a KBSProbe SavedVariables file and prints what every probe found, as
-- Markdown. One file is enough: each probe keeps the reports of the others.
--
--   luajit tools/probe_report.lua "<WoW>\_forever_\WTF\Account\<ACCOUNT>\SavedVariables\KBSProbe.lua"
--
-- Also usable from a script: loadfile(this)(path, true) returns the text
-- without printing it.

local path, quiet = ...
if not path then
	io.stderr:write("usage: luajit tools/probe_report.lua <KBSProbe.lua>\n")
	os.exit(2)
end

local chunk = assert(loadfile(path))
local env = {}
setfenv(chunk, env)
chunk()
local db = assert(env.KBSProbeDB, "no KBSProbeDB in " .. tostring(path))

local out = {}
local function line(text) out[#out + 1] = text or "" end

local function parse(data)
	local fields = {}
	for key, value in (data or ""):gmatch("([^;=]+)=([^;]*)") do
		-- Counters (PK.*, AM.* ...) are numbers; everything else stays text, so
		-- a hash made of digits only is not turned into a number.
		local counter = key:match("^%u+%.") or key == "err.n" or key == "level"
		fields[key] = counter and tonumber(value) or value
	end
	return fields
end

local probes = {}
for origin, report in pairs(db.reports or {}) do
	probes[#probes + 1] = {
		origin = origin, short = origin:match("^(%S+)") or origin, ts = report.ts,
		via = report.via, own = report.own, fields = parse(report.data),
	}
end
table.sort(probes, function(a, b) return a.origin < b.origin end)

local function sum(fields, pattern)
	local total = 0
	for key, value in pairs(fields) do
		if type(value) == "number" and key:find(pattern) then total = total + value end
	end
	return total
end

-- Each open question, as the counters that answer it.
local QUESTIONS = {
	{ "World kills: me", "^PK%.world%.Player%.me$" },
	{ "World kills: my pet", "^PK%.world%.Player%.mypet$" },
	{ "World kills: party member", "^PK%.world%.Player%.party$" },
	{ "World kills: party pet", "^PK%.world%.Player%.partypet$" },
	{ "World kills: raid, same group", "^PK%.world%.Player%.raid%-samegroup$" },
	{ "World kills: raid, other group", "^PK%.world%.Player%.raid%-othergroup$" },
	{ "World kills: raid pets", "^PK%.world%.Player%.raidpet" },
	{ "World kills: not in group", "^PK%.world%.Player%.other$" },
	{ "NPC kills: raid, other group", "^PK%.%a+%.Creature%.raid%-othergroup$" },
	{ "BG kills: readable", "^PK%.bg%.Player%." },
	{ "BG kills: secret", "^PK%.bg%.secret%." },
	{ "Honor lines, world: ok", "^HG%.world%.ok$" },
	{ "Honor lines, world: secret", "^HG%.world%.secret$" },
	{ "Honor lines, BG: ok", "^HG%.bg%.ok$" },
	{ "Honor lines, BG: secret", "^HG%.bg%.secret$" },
	{ "Honor lines not understood", "^HGM%.nomatch$" },
	{ "HK counter, world: ok", "^HK%.%a+%.world%.ok$" },
	{ "HK counter, world: secret", "^HK%.%a+%.world%.secret$" },
	{ "HK counter, BG: ok", "^HK%.%a+%.bg%.ok$" },
	{ "HK counter, BG: secret", "^HK%.%a+%.bg%.secret$" },
	{ "HKs from a BG seen on leaving", "^HKD%.leftbg%.moved$" },
	-- Each live HK matched with what was seen around it. "No killing blow
	-- seen" is an assist, unless DoT kills fire no PARTY_KILL.
	{ "HKs, killing blow in the group", "^HKM%.%a+%.kb%." },
	{ "HKs, no killing blow seen: victim named", "^HKM%.%a+%.assist%.named$" },
	{ "HKs, no killing blow seen: several candidates", "^HKM%.%a+%.assist%.ambiguous$" },
	{ "HKs, no killing blow seen: victim not seen", "^HKM%.%a+%.assist%.unseen$" },
	{ "My killing blows: HK", "^PKH%.%a+%.m%a*%.hk$" },
	{ "My killing blows: no HK", "^PKH%.%a+%.m%a*%.nohk$" },
	{ "Group's killing blows: HK for me too", "^PKH%.%a+%.[pr][%a%-]*%.hk$" },
	{ "Group's killing blows: no HK for me", "^PKH%.%a+%.[pr][%a%-]*%.nohk$" },
	{ "Battlegrounds finished", "^BG%.complete$" },
	{ "Scoreboard during match: ok", "^SB%.during%.ok$" },
	{ "Scoreboard during match: secret", "^SB%.during%.secret$" },
	{ "Scoreboard at the end: ok", "^SB%.final%.ok$" },
	{ "Scoreboard at the end: secret", "^SB%.final%.secret$" },
	{ "Deaths", "^DEATH%." },
	{ "Deaths, killer readable", "^DR%.%a+%.ok$" },
	{ "Deaths, killer secret", "^DR%.%a+%.secret$" },
	{ "Deaths, no recap", "^DR%.%a+%.none$" },
	{ "Deaths, killer is a player", "^DRK%.%a+%.Player$" },
	{ "Position at kills: ok", "^POS%.kill%.%a+%.ok$" },
	{ "Position in BG: ok", "^POS%.%a+%.bg%.ok$" },
	{ "Position in BG: not readable", "^POS%.%a+%.bg%.[^o]" },
	{ "Hidden msgs, world: sent", "^AM%.[%u_]+%.world%.Success$" },
	{ "Hidden msgs, BG: sent", "^AM%.[%u_]+%.bg%.Success$" },
	{ "Hidden msgs, BG: lockdown", "^AM%.[%u_]+%.bg%.AddOnMessageLockdown$" },
	{ "Hidden msgs: throttled", "^AM%.throttled$" },
	{ "Hidden msgs received from others", "^AM%.in%..-%.peer$" },
	{ "Own guild msgs echoed back", "^AM%.in%.GUILD%.%a+%.%u%.self$" },
	{ "Whisper to self 'First Last': received", "^AM%.whisper%.space%.%a+%.received$" },
	{ "Whisper to self 'First-Last': received", "^AM%.whisper%.dash%.%a+%.received$" },
	{ "Inspect: lifetime HK read", "^INS%.%a[%a%-]*%.ok$" },
	{ "Reports received", "^RP%.received$" },
	{ "Reports relayed", "^RP%.sent%.relay$" },
	{ "Errors", "^ERR%.total$" },
}

line("# Killed by Savages probe results")
line()
line(("%d probe report(s) in %s"):format(#probes, path))
line()

if #probes == 0 then
	line("No report yet.")
else
	local header, rule = { "| Question" }, { "|---" }
	for _, probe in ipairs(probes) do
		header[#header + 1] = probe.short
		rule[#rule + 1] = "---:"
	end
	line(table.concat(header, " | ") .. " |")
	line(table.concat(rule, "|") .. "|")
	for _, question in ipairs(QUESTIONS) do
		local cells = { "| " .. question[1] }
		for _, probe in ipairs(probes) do
			local value = sum(probe.fields, question[2])
			cells[#cells + 1] = value == 0 and "." or tostring(value)
		end
		line(table.concat(cells, " | ") .. " |")
	end

	line()
	line("## Formats and client")
	local FORMAT_KEYS = {
		"v", "build", "loc", "class", "level", "faction", "gname", "bnet",
		"last.death", "last.kill", "last.honor", "last.assist", "last.mark",
		"fmt.honor", "fmt.honorKey", "fmt.victim", "fmt.roster", "fmt.score", "fmt.sender",
		"fmt.lifetime", "fmt.recap", "fmt.me", "err.n", "err.first",
	}
	for _, probe in ipairs(probes) do
		line()
		line(("### %s (%s, %s)"):format(probe.origin, probe.own and "this account" or ("via " .. tostring(probe.via)),
			os.date("%Y-%m-%d %H:%M", probe.ts or 0)))
		for _, key in ipairs(FORMAT_KEYS) do
			local value = probe.fields[key]
			if value ~= nil then line(("- %s: %s"):format(key, tostring(value))) end
		end
	end

	-- The same kill seen by two probes must get the same key: victim GUID
	-- tail plus server time, within two seconds.
	line()
	line("## Same kill seen by several probes")
	local seen = {}
	for _, probe in ipairs(probes) do
		for tail, at, role in tostring(probe.fields.kk or ""):gmatch("(%x+):(%d+):(%S+)") do
			seen[#seen + 1] = { probe = probe.short, tail = tail, at = tonumber(at), role = role }
		end
	end
	local pairsFound = 0
	for i = 1, #seen do
		for j = i + 1, #seen do
			local a, b = seen[i], seen[j]
			if a.probe ~= b.probe and a.tail == b.tail and math.abs(a.at - b.at) <= 2 then
				pairsFound = pairsFound + 1
				line(("- %s: %s (%s) and %s (%s), %d s apart"):format(a.tail, a.probe, a.role, b.probe, b.role, math.abs(a.at - b.at)))
			end
		end
	end
	if pairsFound == 0 then line("- none yet (needs two probes in one group killing together)") end

	-- Alts: probes that share a BattleTag hash belong to one Battle.net account.
	line()
	line("## Characters sharing a Battle.net account")
	local byHash = {}
	for _, probe in ipairs(probes) do
		local hash = probe.fields.bnetHash
		if type(hash) == "string" then
			byHash[hash] = byHash[hash] or {}
			table.insert(byHash[hash], probe.short)
		end
	end
	local groups = 0
	for _, names in pairs(byHash) do
		if #names > 1 then
			groups = groups + 1
			line("- " .. table.concat(names, ", "))
		end
	end
	if groups == 0 then line("- none yet") end
end

local text = table.concat(out, "\n")
if not quiet then print(text) end
return text
