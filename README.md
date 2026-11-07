# Killed by Savages

A guild kill board for World of Warcraft: Forever. It counts the enemies each
member kills, by player (all characters together), by character and for the
whole guild, in the open world and in battlegrounds, and shows leaderboards,
the latest kills and deaths, the enemies the guild kills the most and those
who kill it. Every member running the addon shares its journal with the
guild, so everyone sees the same board.

Built for the guild Savages; it works for any guild, on either faction: the
enemy is the opposite faction of whoever runs it.

## How it counts

On Forever the combat log is closed to addons and many values are secret.
The addon rests on what the client still gives, measured with a probe before
it was written (see `probe/`):

- **Kills** are the honorable kills the server grants (`PLAYER_PVP_KILLS_CHANGED`
  and the lifetime counter), so an assist counts like a killing blow, as in
  the game. A few seconds after each one the addon names the victim: a
  killing blow by you, your pet or your group (`PARTY_KILL`), or else the enemy
  player who died next to you at that moment (`UNIT_DIED`). Killing blows and
  assists are shown apart.
- **Deaths** come from the death recap, which names the killer (player or pet)
  and the spell. Deaths to creatures are not recorded.
- **Battlegrounds**: enemies are secret inside, so each HK is recorded live
  with its time and subzone only. When the match ends the scoreboard becomes
  readable and is kept as a match record: your row, and the row of every
  guild teammate on the board, credited with or without the addon. The
  "enemies killed" of a battleground are the guild's killing blows on that
  board.
- **The guild total** counts each enemy death once, whoever took part.
- **Players** are the characters of one Battle.net account that are still in
  the guild, grouped by a salted hash of the BattleTag; the tag itself is
  never kept or sent. A character that leaves the guild drops out of its
  player's total; the guild keeps what it did.
- Periods are weeks aligned on the server's weekly reset, plus all time.

Each character keeps an append-only journal of its records, chained by the
server's lifetime count, and broadcasts new ones to the guild. History moves
between members by whisper, page by page, deflated, from whoever holds it,
so a member who logs in later still ends up with everything, including the
journals of members who are offline. Records of a character are accepted
live only from that character; pages from a third party must pass validation
and the chain, and are dropped if the author's own count contradicts them.

## Commands

| Command | What it does |
|---|---|
| `/kbs` | Open or close the kill board |
| `/kbs status` | Where the addon stands on this character |
| `/kbs options` | Open the options |
| `/kbs import` | Take the probe's records into this character's journal (see below) |
| `/kbs debug` | Errors and sync state, for bug reports |

Options: minimap button, chat announcements of guild kills, window scale. The
display name of a player is set in the Me tab.

## Import from the probe

A character that ran the probe (below) before installing the addon does not
start from zero: at its first login, if its journal is still empty, the
addon reads the probe's SavedVariables and turns what they hold for that
character into its first records, chained by the server's counter like live
ones: kills with their victim and place, deaths with their killer, each
battleground's final scoreboard, and counter records for the HKs the probe
did not see. The probe's file is account-wide; its session list says which
character was playing when. A file left by a probe older than 0.1.3, which
did not match HKs with the blows and deaths around them, is matched by the
import itself with the same rule. Nothing is written unless every record
validates and the chain ends at the counter the server shows now; `/kbs
import` says why otherwise. The import happens once, and only while the
journal is empty, so install the addon before the next kill.

## Install

Unzip `KilledBySavages-<version>.zip` into `World of Warcraft\_forever_\Interface\AddOns`
and restart the game. Interface 16001 (Forever). Embedded libraries: LibStub,
CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0, LibDeflate.

## Development

- Lint: `luacheck .`
- Tests: `luajit tests/addon_harness.lua` and `luajit tests/harness.lua`
  (the probe). Fake Forever clients in `tests/forever_mock.lua` load the real
  files, a fake guild channel links them (GUILD, WHISPER, lockdown, throttle),
  secret values are an object that fails on any read, and every SavedVariables
  write goes through a serializer that refuses what the game could not save.
  A client given `client.probe = { ... }` logs in with that table as the
  probe's SavedVariables.
- Deploy to the game: `scripts\dev.ps1 -Addon KilledBySavages` (or `dev.cmd`).
  Targets come from `-WowAddOnsPath`, the `KBS_WOW_ADDONS_PATH` variable, or
  a gitignored `scripts\dev.local.ps1` setting `$WowAddOnsPaths`. A new addon
  needs a full game restart; updates only need `/reload`.
- Package: `scripts\package-addon.ps1` writes `dist\KilledBySavages-<version>.zip`.
  A GitHub release triggers `.github/workflows/publish-curseforge.yml` once
  the CurseForge project id is set in it and the `CURSEFORGE_API_TOKEN`
  secret exists.

## The probe (KBSProbe)

`probe/KBSProbe` is the throwaway dev addon that measured what the client
gives before the addon was written. It records, per context (world,
battleground): every `PARTY_KILL` and who landed it, the honor lines, the
server HK counters, the battleground scoreboard during and after the match,
the death recap, the map position, name formats, whether hidden addon
messages go through, and each HK matched with what was seen around it. It
is silent unless `/kbsp` asks, shares compact reports with the other probes
of the guild, and relays them for offline ones.

- Package: `scripts\package-probe.ps1` -> `dist\KBSProbe-<version>.zip`.
- Read results: `luajit tools/probe_report.lua <path to KBSProbe.lua>` prints
  a Markdown table, one column per probe.
