# Killed by Savages

A guild addon for World of Warcraft: Forever, in design. It will count Horde
players killed by each member (all alts together), by each character and by the
whole guild, split between battlegrounds and world PvP, with leaderboards, a
kill feed, guild milestones, a hunting board, officer bounties and a heatmap.

On Forever the combat log is closed to addons, so the design rests on the few
signals the client still gives: `PARTY_KILL`, the honor line, the server HK
counters, the end-of-match scoreboard, the death recap. Before writing the
addon, the probe in this repo measures what those signals really give in game.

## The addon (KilledBySavages)

`addon/KilledBySavages` is the addon itself, in development. Planned for the
first version: each honorable kill of a member recorded with its victim
(killing blow or assist), the PvP deaths with their killer, the kills made in
battlegrounds, a guild-wide sync over hidden addon messages so every member
ends up with the whole history, and a window with leaderboards by player (all
characters together) and by character, the guild total, a kill feed, a hunting
board and personal stats.

Current state: the skeleton loads (`/kbs status`, `/kbs debug`); detection,
sync, stats and the window follow.

| Command | What it does |
|---|---|
| `/kbs` | Open or close the kill board |
| `/kbs status` | Where the addon stands on this character |
| `/kbs options` | Open the options |
| `/kbs debug` | Errors and sync state, for bug reports |

Embedded libraries, copied from versions already running on this client:
LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0, LibDeflate.

## The probe (KBSProbe)

`probe/KBSProbe` is a throwaway dev addon. It records, per context (world,
battleground):

- every `PARTY_KILL`: who landed the blow (me, my pet, party, raid same or other
  subgroup, outside the group) and the victim, or whether it was secret;
- every honor line, matched against the client's own honor sentences, so the
  victim name comes out in any client language;
- the server HK counters, including how many HKs a battleground gave once we
  leave it;
- each HK, matched with what was seen around it: a killing blow by the group,
  or else an enemy player who died near us (an assist, victim named); and
  whether the group's killing blows gave us the HK. A log written by an older
  version is matched once at login;
- the battleground scoreboard, during the match and at the end, flagging
  guildmates (with or without the probe);
- the death recap, our map position, the guild roster and name formats;
- whether hidden addon messages go through (pings on GUILD, INSTANCE_CHAT,
  PARTY or RAID);
- whether the BattleTag is readable, to group alts. Only a salted hash of it is
  kept or sent, never the tag itself.

It is silent: it prints nothing unless a slash command asks for it.
`/kbsp verbose` turns on first-sighting messages for the developer.

Each probe shares a compact report (counters and a few format samples) with the
other probes of the guild over a hidden addon channel (prefix `KBSProbe`). A
probe that logs in says which reports it holds, and whoever has a newer one
relays it, so one SavedVariables file ends up holding every probe's report.

Commands:

| Command | What it does |
|---|---|
| `/kbsp` | Summary of what the probe saw |
| `/kbsp verbose` | Tell me when something is seen for the first time |
| `/kbsp mark <text>` | Leave a note in the log and print your last killing blow, like `/kbsp mark dot` after letting a DoT finish a mob |
| `/kbsp inspect` | Read the honor (lifetime HK) of the target, a guildmate close by |
| `/kbsp share` | Send this report to the other probes now |
| `/kbsp reports` | List the reports received from other probes |
| `/kbsp export` | Open the report in a window to copy from |
| `/kbsp reset` | Forget everything recorded on this account |

The data is in `WTF\Account\<ACCOUNT>\SavedVariables\KBSProbe.lua`, written by
the game on `/reload` or logout.

## Development

- Deploy: `scripts\dev.ps1` (or `dev.cmd`). Targets come from `-WowAddOnsPath`,
  the `KBS_WOW_ADDONS_PATH` variable, or a gitignored `scripts\dev.local.ps1`
  setting `$WowAddOnsPaths`. A new addon needs a full game restart.
- Package the probe for volunteers: `scripts\package-probe.ps1`, which writes
  `dist\KBSProbe-<version>.zip`.
- Lint: `luacheck .`
- Tests: `luajit tests/harness.lua`. Fake Forever clients load the real probe,
  a fake guild channel links them, and secret values are an object that fails
  on any read.
- Read results: `luajit tools/probe_report.lua <path to KBSProbe.lua>` prints a
  Markdown table, one column per probe.
