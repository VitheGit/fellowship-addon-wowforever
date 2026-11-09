# Fellowship

A WoW Forever addon for small friend groups: a private group chat and a shared
achievement feed that **persists**, so anyone who was offline can open the window
and read everything they missed.

- Private chat between fellowship members (`/fsay hello!`)
- Achievements and level-ups are shared automatically
- Full history saved on every member's machine; when you log in, whoever is online
  fills in what you missed, even if the original author is offline now
- "New since you were last here" divider and a login summary
  ("While you were away: 12 messages and 3 achievements")
- Members tab with online status, founder, achievements shared and last activity
- Names shown in class colors (works with class-color addons too)
- Works across realms (invite `Name-Realm`)

## Install

Copy the `Fellowship` folder into your WoW Forever AddOns folder:

```
<WoW Forever install>/Interface/AddOns/Fellowship/Fellowship.toc
```

Everyone in the group needs the addon installed.

> **Interface version:** `Fellowship.toc` uses `## Interface: 16001` for game version
> 1.60.1. If the AddOns list shows Fellowship as "out of date", run
> `/dump (select(4, GetBuildInfo()))` in game and put that number in the `.toc`.

## Use

| Command | What it does |
| --- | --- |
| `/fs` | Open or close the Fellowship window (also in the addon compartment menu) |
| `/fsay <message>` | Talk to your fellowship |
| `/fs create <name>` | Start a fellowship |
| `/fs invite <player>` | Invite someone (`Name` or `Name-Realm`) |
| `/fs who` | List members and who is online |
| `/fs leave` | Leave (your copy of the history is deleted) |
| `/fs remove <player>` | Remove a member (founder only) |
| `/fs sync` | Ask online members for anything you missed right now |
| `/fs echo` / `/fs levels` | Toggle chat echo in the main chat frame / level-up sharing |

## How offline catch-up works

Every chat line, achievement, level-up and membership change is an event numbered by
its author (Anna #1, #2, #3...). Every member stores the whole log in
SavedVariables. When two members meet (login, a 5 minute ping, or a new member
joining) they swap a tiny summary of what they have and each asks for only the
pieces it's missing. See [docs/DESIGN.md](docs/DESIGN.md) for the protocol.

The one limit: history can only reach you from a member who is online at the same
time as you and has it. If you and the author are never online with anyone who
saw the message, you'll get it the next time your paths cross.

History is capped at 3000 events / 180 days per fellowship (membership records
are kept forever). Adjust in `FellowshipDB.settings`.

## Development

The sync engine is tested in a simulated WoW world (several clients, whispers,
throttling, logouts and SavedVariables) that loads the real addon files:

```
lua5.1 tests/test_sync.lua
```
