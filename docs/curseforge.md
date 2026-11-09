# CurseForge project page

The texts of the CurseForge project, kept here so the page and the repo say
the same thing. Game: World of Warcraft, game version 1.60.1 (Forever,
interface 16001). Category: PvP. License: GNU General Public License
version 3.0. Source: https://github.com/Mouchoir/Killed-by-Savages.

## Name

Killed by Savages

## Summary

Guild kill board for WoW: Forever: who killed how many enemies, per player,
per character and for the whole guild, in the world and in battlegrounds.

## Description

**Killed by Savages** is a guild kill board for World of Warcraft: Forever.
It counts the enemies each member kills and shows them by player (all
characters of one account together), by character and for the whole guild,
in the open world and in battlegrounds, over the current week, the last
week or all time. Built for the guild Savages; it works for any guild, on
either faction.

**The board** (`/kbs`, or the minimap button): the players ranking, the
characters ranking, the guild tab with the enemies killed, the next
milestone and the latest kills and deaths, the hunting board with the
enemies the guild kills the most and those who kill it, a Me tab with your
own characters and boards, and the Options tab at the right end of the tab
row. Every member running the addon shares its journal with the guild, so
everyone sees the same board, including the records of members who are
offline.

**Kill feed.** Off by default. Tick it in the Options tab and a chat tab
named "Kills" docks with your other chat tabs. Every kill and death of the
guild in the world lands there as "X killed Y (2-1)": the score counts,
between that member and that enemy, the kills of the one named first
against the other's. A battleground match gives one line when it ends,
with the member's kills, killing blows and deaths. Nothing goes to your
main chat. Close the tab and the feed turns off.

**Updates.** When a guildmate runs a newer version of the addon, you are
told once in the chat.

**How it counts.** Kills are the honorable kills the server grants, so an
assist counts like a killing blow, as in the game; the addon names the
victim a few seconds later from the killing blow of you, your pet or your
group, or from the enemy who died next to you. Killing blows and assists are
shown apart. Deaths come from the death recap, with the killer and the
spell. In a battleground the enemies are secret, so the final scoreboard is
kept instead, with every guild teammate on it, credited with or without the
addon. The guild total counts each enemy death once, whoever took part.
Players are the characters of one Battle.net account still in the guild,
grouped by a salted hash of the BattleTag; the tag itself is never kept or
sent.

**What leaves your client.** Only hidden addon messages to your own guild,
never chat text, never anything outside the game: your kill and death
records, your battleground scoreboards and your profile (name, class, race,
realm, level, the BattleTag hash, your display name, the addon version).
There is no server.

**Commands.** `/kbs` opens the board, `/kbs status` says where the addon
stands on this character, `/kbs options` opens the board on its Options
tab (minimap button, window scale, kill feed), `/kbs debug` prints the sync
state and errors for a bug report.

Source, issues and the test harness: https://github.com/Mouchoir/Killed-by-Savages

---

**Killed by Savages** est un tableau de chasse de guilde pour World of
Warcraft: Forever : les ennemis tués par chaque membre, par joueur (tous
ses personnages réunis), par personnage et pour toute la guilde, en monde
ouvert et en champ de bataille, sur la semaine, la semaine passée ou depuis
toujours. Conçu pour la guilde Savages, il marche pour n'importe quelle
guilde, dans les deux factions. Un kill est une victoire honorable accordée
par le serveur, avec la victime nommée quand le client le permet ; les morts
viennent du récapitulatif de mort ; en champ de bataille c'est le tableau de
score final qui compte, pour tous les coéquipiers de guilde. Un onglet
Options, au bout de la rangée d'onglets, règle le bouton de minicarte,
l'échelle et le fil des kills. Désactivé par défaut, ce fil ouvre une fois
coché un onglet de chat dédié où chaque kill et chaque mort de la guilde en
monde ouvert s'affiche avec le score entre le membre et l'ennemi, et chaque
match de champ de bataille en une ligne à sa fin, sans rien écrire dans le
chat principal. Quand un membre de la guilde a une version plus récente de
l'addon, un message dans le chat le signale. Rien ne sort du jeu : les
données circulent entre membres par messages d'addon cachés.
