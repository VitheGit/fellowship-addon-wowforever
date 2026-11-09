# Fellowship

A WoW Forever addon for small friend groups: a private group chat and a shared
achievement feed that **persists**, so anyone who was offline can open the window
and read everything they missed.

- Private chat between fellowship members (`/fs hello!`)
- Achievements and level-ups are shared automatically
- Full history saved on every member's machine; when you log in, whoever is online
  fills in what you missed, even if the original author is offline now
- "New since you were last here" divider and a login summary
  ("While you were away: 12 messages and 3 achievements")
- Members tab and `/fship who` show who is Online/Offline (with "last seen"), founder, achievements shared and last activity
- Names shown in class colors (works with class-color addons too)
- Right-click a player (portrait, party/raid frame, name in chat) and pick "Invite to Fellowship"
- Choose which chat tabs show Fellowship messages, like Guild or Party
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
| `/fs <message>` | Talk to your fellowship |
| `/fs` or `/fship` | Open or close the Fellowship window (also in the addon compartment menu) |
| `/fship create <name>` | Start a fellowship |
| `/fship invite <player>` | Invite someone (`Name` or `Name-Realm`) |
| `/fship who` | List members and who is online |
| `/fship leave` | Leave (your copy of the history is deleted) |
| `/fship remove <player>` | Remove a member (Admin only) |
| `/fship promote <player>` | Make a member an Inviter, so they can invite people (Admin only) |
| `/fship demote <player>` | Make an Inviter a regular Member again (Admin only) |
| `/fship admin <player>` | Offer Admin to someone; they get a Yes/No pop-up (Admin only, `/fship admin cancel`) |
| `/fship sync` | Ask online members for anything you missed right now |
| `/fship color <hex>` | Change the chat text color (default sea green `4fd1b5`; `/fship color reset`) |
| `/fship tab` | Show/hide Fellowship messages in the chat tab you are typing in (`/fship tab 2`, `/fship tab reset`). You can also right-click a chat tab and tick **Show Fellowship** |
| `/fship echo` / `/fship levels` | Toggle chat echo in the main chat frame / level-up sharing |

## Roles

- **Admin**: whoever created the fellowship, until they pass it on. Can invite, remove,
  promote/demote and pass Admin. The Admin can't leave while others are in the
  fellowship; pass Admin first.
- **Inviter**: can invite people.
- **Member**: everyone who joins starts here. Can chat and share achievements.

Passing Admin asks the other player to accept. If they're offline they're asked the next
time they log in. Once they accept, the old Admin becomes an Inviter.

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
