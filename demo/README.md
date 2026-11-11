# Demo tour and GIFs

`KBSDemo` is a dev addon that plays a scripted tour of the Killed by Savages
board. Two Python scripts turn a screen recording of that tour into one GIF
per scene, for release announcements. Nothing here is packaged with the
addon.

## What you need

- Windows, with the game in a window or borderless.
- Python 3 with Pillow and numpy (`pip install pillow numpy`).

## Steps

1. Install the tour next to the addon: `scripts\dev.ps1 -Addon KBSDemo`,
   then `/reload` in game.
2. Start the recorder. It waits for the tour and ends with it:
   `python demo\record.py dist\demo-recording`
3. In game, outside an instance, on a character that is on the characters
   ranking: `/kbsdemo`. Hands off the mouse and the keyboard for a minute
   and a half, until the chat says the tour is over.
4. Build the GIFs: `python demo\makegif.py dist\demo-recording dist\gif`
5. Look before posting: `python demo\sheet.py dist\demo-recording 3` writes
   a contact sheet of scene 3 into the recording folder.
6. Remove `KBSDemo` from the AddOns folder when done, or leave it: it does
   nothing until `/kbsdemo`.

`dist/` is git-ignored. Recordings and GIFs show real names: they stay out
of the repository.

## The command

| Command | What it does |
|---|---|
| `/kbsdemo` | The whole tour, six scenes |
| `/kbsdemo 3` | One scene; `/kbsdemo 2,5` for several |
| `/kbsdemo player=abc` | What scene 1 types in the players' search box |
| `/kbsdemo enemy=some name` | What scene 5 types in the hunt's search box |
| `/kbsdemo stop` | Ends the tour and puts everything back |

What `player=` and `enemy=` say is kept in the tour's saved variables, on
that machine, for the next time; an empty text (`player=`) gives the choice
back to the tour. Left to itself it types the start of the name of one of
the player's own alts in scene 1, and the name of the enemy killed most in
scene 5. No name is written in the code.

## The scenes

1. A player found by a part of the name of one of its alts, with the
   tooltip that lists its characters.
2. The characters ranking narrowed by two classes, a level range, then a
   role.
3. The role of the character, chosen in the Me tab, then its line on the
   ranking.
4. The name of an alt taken as display name in one click, seen on the
   players ranking, then put back.
5. An enemy found on both hunting boards, then the boards by class.
6. The players who have not updated the addon, their names replaced by
   "Player 1", "Player 2" before any frame shows them.

The tour picks the first period that has ten players or more (this week,
else last week, else all time), since the weekly reset empties the week.

## How it works

The tour drives the board's own widgets through its global frame
(`KilledBySavagesFrame`): their `OnClick` handlers, the text of their edit
boxes. The addon under it is the released one, untouched. While it runs,
the board sits in the middle of the screen on a plain dark ground, a fake
pointer shows where the clicks land (a screen capture does not have the
real one), and an unseen frame keeps the real mouse off the UI. At the end
the display name, the role, the tab, the period and the board's place are
as they were. Scenes 3 and 4 do change the role and the display name for a
few seconds: the guild sees it pass.

Four squares in the top left corner of the screen tell the recorder what is
going on: `[magenta][phase][scene][cyan]`. The phase is white while the
recorder finds the board from two markers in its corners, blue between
scenes, red during one, black when the tour is over. The recorder copies
only the board's rectangle, about 15 times a second, keeps the frames that
differ, and writes nothing before the tour starts. `record.py --selftest`
checks the marker reading on a drawn screen and times the screen copy.

`makegif.py` crops each scene to the board, gives it one palette of 255
colours (a share of it cut from the vivid pixels hue by hue, so that class
colours seen on one line survive the browns of the board), and stores only
what changes from one frame to the next. Options: `--scale 0.85`,
`--only 1,2`, `--drop 3:18-25` (takes frames out of a scene),
`--names 1=one-name,2=another`.

The tour also runs in the test harness, on a fake client (section "The demo
tour" of `tests/addon_harness.lua`): it fails there when the board's
widgets change under it.
