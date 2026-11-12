# Killed by Savages

A guild kill board for World of Warcraft: Forever. It counts the enemies each
member kills, by player (all characters together), by character and for the
whole guild, in the open world and in battlegrounds, and shows leaderboards,
the latest kills and deaths, the enemies the guild kills the most and those
who kill it. Every member running the addon shares its journal with the
guild, so everyone sees the same board.

Built for the guild Savages; it works for any guild, on either faction: the
enemy is the opposite faction of whoever runs it.

Discord (new versions, bug reports, ideas): https://discord.gg/wqYecPR8yC

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
  and the spell. Deaths to creatures are not recorded. The client fires
  PLAYER_DEAD twice at times: within a few seconds it is one death.
- **Battlegrounds**: enemies are secret inside, so each HK is recorded live
  with its time and subzone only. When the match ends the scoreboard becomes
  readable and is kept as a match record: your row, and the row of every
  guild teammate on the board, credited with or without the addon. The
  "enemies killed" of a battleground are the guild's killing blows on that
  board or, when higher, the HKs of the member who took part in the most
  deaths: a floor, since members' HKs overlap when they fight together.
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
| `/kbs discord` | The Discord link, in the chat and selected in the Options tab, ready to copy |
| `/kbs preview` | Example lines of the kill feed, to see how it reads on this client; nothing is recorded |
| `/kbs import` | Take the probe's records into this character's journal (see below) |
| `/kbs debug` | Errors and sync state, for bug reports |

Options, in the board's Options tab (at the right end of the tab row; the
game's Settings page for the addon opens it too): minimap button, reminders
of new versions, window scale and the kill feed. The scale applies when the
slider is let go. The
kill feed is off by default. Ticked, every kill and death of the guild in
the world is a line of the chat, the member of the guild always first: "X
(38) killed Y (41) (2-1)", "X (38) was killed by Y (41) (2-2)". The score
is the member's kills on that enemy against the enemy's on the member, in
the world. A name is followed by its level: the member's from the guild
roster (its profile when the roster has none), the enemy's as the member's
client read it at that kill or death, in the colour the game itself rated
it with against the member (grey, green, yellow, orange or red, as on the
target frame), and as the target frame's skull when the game hid it as too
high. The addon rates nothing by itself: a level recorded by a version
before 1.0.3 has no rating and shows plain, and an enemy whose level the
client did not read gets none. A battleground hides whom a member kills,
so its kills and deaths give no line: the match gives one when it ends,
from its scoreboard, "X (38) finished a match in Arathi Basin: 12 kills, 3
killing blows, 4 deaths".
The lines go to a chat tab named "Kills" when there is one, else to the
main chat, with a line once per session saying how to make the tab; the
second box, "In the chat tab named Kills", unticked, sends them to the main
chat anyway. The tab is the player's to make (right-click the General tab,
"New Window", name it Kills), or the Options tab makes it: while the feed
wants a tab that is not there, a button, "Create the Kills tab (reloads the
interface)", opens it and reloads the interface in the same breath. Closing
the tab turns the feed off. That button aside, the addon never opens,
closes or selects a chat window: run from an addon, the game's chat window
code marks the chat edit box as the addon's, and for the rest of the
session a group message fails on a secret value and `/invite` is refused as
a protected call (seen with 1.0.0, fixed in 1.0.1). The reload that follows
the button ends that session, and the mark with it.

`/kbs preview` writes a dozen example lines where the feed's lines go (its
tab when there is one and it is wanted, else the main chat), made by the
code of the real lines from kills and deaths that never happened, with the
character played as the member: a way to see the colours, the skull and the
wording on one's own client. Each line is marked as an example; nothing is
recorded, nothing is sent to the guild, and no setting changes.

The Options tab also holds the link to the addon's Discord, in a box: an
addon cannot open a browser, so the box keeps its text whatever is typed in
it and selects it whole when clicked, for the copy shortcut to take it.
`/kbs discord` says the link in the chat and opens the tab with the link
selected.

A player shows on the players ranking under its display name alone, its
characters in the tooltip. The name is set in the Me tab: any name, or the
name of one of its characters with the button next to it. The name is the
account's: a player shows under the one its characters stated last, so an
alt that has not logged in since a change does not bring the old one back.

A player can also say which of its characters is its main, with the button
next to it in the Me tab; the button again names none. The main goes out
with the profile of whichever of its characters is played, and is the one
its characters stated last. A player with no display name goes by its main,
else by its character with the most kills. The Me tab lists every character
of the player the board knows, with or without a kill in the period.

A bar above the lists finds and narrows. Its search box takes any part of
a name, whatever the case or the accents ("sor" finds "Søren"): on the
Players tab a player by its name or the name of any of its characters, on
the Characters tab a character by its name or its player's, on the Hunt tab
an enemy on both boards. The Characters tab adds an icon per class on the
list, two level bounds (the levels are the guild roster's) and the three
roles; the Hunt tab the classes. Several classes or roles can be chosen at
once, "Clear" takes everything off, and the bar says how many rows are left
of how many ("6 of 22", "6/22" where the room is short, nothing where there
is none). A row a filter cannot judge (no level known, no role chosen)
is left out while that filter is set. There is no dropdown anywhere: the
client's own trips a menu assertion on Forever.

The week shown starts at the server's weekly reset, where its counts start
again, and the board says so rather than leave an empty list to be wondered
at. Next to the big number: since when the week runs ("since Wednesday
11/11 at 05:00"), or the dates of last week. On hover of a period's button:
its dates in full and, for the week, when it starts again. In place of an
empty list, in a guild that has a history: that the counts started again,
when, and that what came before is under "Last week" and "All time". Reset
times are shown to the nearest minute, in the player's local time.

The role (tank, healer, damage) is what each player says its character
plays, chosen with three buttons on the character's line in the Me tab;
the chosen one clicked again removes it. The role of the character played
goes out with its profile. The role of another character of the same game
account is said to the guild by the one played (it cannot speak while it
is offline), taken when both characters stated the same BattleTag hash in
their own profiles, and said again by the character itself at its next
login. A character of the player on another game account keeps its own
role: its buttons rest. The role is not read from the client:
Forever's talents are one free tree and nothing in it names a role, so the
addon does not guess one. `/kbs debug` prints what the client answers to
the spec and role calls, to see whether it could be read one day. A member
on a version before 1.0.1, or who chose nothing, has no role.

Guild ranks to give. The character that holds the guild's first rank (the
guild master's, whatever the guild calls it) has a button in the Options tab
that opens a small dialog: the rank a main must hold at least once it runs
the addon, the rank of alts (or none: alts are then not looked at), and the
rank from which members see who falls short. The rule goes out in a guild
message taken only from the roster's first rank, and only when newer than
the one held; that character says it again at its login and to members who
log in while it is online, so a member gets it the first time both are
online. It is kept with the names of its ranks: when one is renamed or
moved, the rule rests until it is sent again, rather than point at another
rank. For the members allowed to see, an orange square before the rank
marks a character (Characters tab) or a player (Players tab) with a rank to
give, the tooltip says which rank it holds and which is expected, and on
the Players tab the "Ranks to give" button keeps only those players, with
or without a kill in the period. The right to see is read from the rank
held each time it is asked: a demotion takes the marks, the button and its
filter away, a promotion brings them back. With a main named, the main is
held to the expected rank or above and the player's other characters to
the rank of alts, no other; with none named nothing is guessed, and the
player is marked only when none of its characters holds the expected rank.
Only characters whose profile is held, which is what running the addon
leaves, are looked at. None of this is secret: every member reads every
rank in the game's own guild panel.

The window's footer says where the sync with the guild stands: the seconds
before the login announcement, the pages coming in, or how many journals are
held and how many members with the addon are online (the guild roster's
online members whose addon we know of). `/kbs status` prints the same line.
A member who held nothing of the guild is told once in chat when the first
journals arrive.

A member who runs an older version than a guildmate is told once per
session in the chat: "A new version (0.1.16) is available. Please update!",
with where to find help (`/kbs discord`). From 1.0.3 the board says it too:
the first time it opens in the session, or at once when it is open, a
small dialog names the version that is out and the one that runs, with how
to update. "Later" closes it until the next session. "Skip this version"
stops the reminders of that release, the chat line included, until the next
one. "Never remind me" stops them for good, and the Options tab's box "Tell
me when a new version is out" turns them back on, the release set aside
included. The Options tab's version line names the newer release whatever
was answered, as does `/kbs status`; the minimap button's tooltip only
while the reminders hold.
Hellos and profiles carry the version; a member who logs in with an older
one gets the newer one back from a member who runs it, and the profiles it
holds tell it at login when nobody newer is online. The login after an
update says hello however recent the last one, and from 1.0.0 every client
also tells the guild its version every 10 minutes (a presence message),
for members who logged in after its hello. The footer's right end reads
"6 players have an outdated addon" when some guild members run an older
version than the newest release around, our own player never among them:
hover the dotted number for
their names, versions and when each was last heard from. A player counts
once, judged by the character heard from last, so it drops off as soon as
any of its characters runs the new version. Builds deployed by
`scripts\dev.ps1` say `X.Y.Z-dev` and are never announced.

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
import` says why otherwise. The import happens once.

A journal that already has records, because the probe folder was gone when
the addon first ran, takes the probe's data from before the addon's first
count as backfill: kills appended after the head as `B1` records, each at
its own time with its victim, matches as `C1` records with their
scoreboard, both outside the counter chain (that first count already held
them), deaths as they are. The "before the addon" count shown in the
tooltips and `/kbs status` shrinks by the kills placed in the world and the
HKs of the matches placed. Put the probe folder back, keep its
SavedVariables, log in: the backfill runs on its own.

## What leaves your client

Only hidden addon messages to your own guild (the guild channel and whispers
to guild members), never chat text, and never anything outside the game:
your kill and death records (time, the victim's or killer's name, class,
race and level, how the game rated that level against your character, the
map position, your lifetime honorable kill count), the
scoreboard rows of your battlegrounds, and your profile (character name,
class, race, realm, level, the salted BattleTag hash, your display name, the
role you chose for the character, which of your characters is your main,
the addon version), the role you set for another character of your account,
the rule on ranks if you hold your guild's first rank, the version and the
BattleTag hash again in the presence
message every 10 minutes. There is no server; the guild's members hold the
data.

## Install

From CurseForge (Killed by Savages, for World of Warcraft: Forever) or the
zip of the latest GitHub release: unzip `KilledBySavages-<version>.zip` into
`World of Warcraft\_forever_\Interface\AddOns` and restart the game.
Interface 16001 (Forever). Embedded libraries: LibStub, CallbackHandler-1.0,
LibDataBroker-1.1, LibDBIcon-1.0, LibDeflate. Members should run the same
version: a client keeps records of a kind it does not know, but only shows
the kinds it knows.

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
  a gitignored `scripts\dev.local.ps1` setting `$WowAddOnsPaths`. The deployed
  TOC says `X.Y.Z-dev`, so the guild is never told of a version that is not
  out; once the release tag is pushed, `-Release` deploys the build as
  published. A `/reload` in game loads it.
- Demo GIFs for announcements: `demo\KBSDemo` plays a scripted tour of the
  board in game, `demo\record.py` records it and `demo\makegif.py` makes
  one GIF per scene. See `demo\README.md`. The tour also runs in the test
  harness, so it fails there when the board's widgets change under it.
- Icon: `scripts\make-icon.ps1` draws `Media\Logo.tga`, the icon of the
  minimap button and of the addon list, from `art\savages-logo.svg`, the
  guild's logo: a disc with the claws, 64 px, a 32-bit TGA with alpha.
- Package: `scripts\package-addon.ps1` writes `dist\KilledBySavages-<version>.zip`.
  Pushing a tag `vX.Y.Z` runs `.github/workflows/publish.yml`: it builds the
  zip from the tag, creates the GitHub release with the zip (Wago Addons
  imports it from there) and uploads it to CurseForge. A `0.x` version or a
  `-beta` suffix is a beta, `-alpha` an alpha. `CURSEFORGE_API_TOKEN` is a
  repository secret.

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
