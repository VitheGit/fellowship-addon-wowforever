# Changelog

## 0.9.5

- The minimap button now uses the standard LibDBIcon library when it's available, so minimap-button collectors and minimap addons treat it like any other button (no more "custom button" warning, and it's listed as "Fellowship"). Your button position carries over.

## 0.9.4

- Fixed invites never finishing on WoW Forever. Character names have a first and last name ("Vithe Valestrider"), and Fellowship was mistaking the last name for a realm and dropping the space, so replies went to a player that doesn't exist. Names are now handled the WoW Forever way everywhere.
- Names show in full ("Vithe Valestrider") in chat, the member list and the sidebar.
- `/fship invite` takes a full name: `/fship invite Valtri Brinkforge`. Right-click > Invite to Fellowship works as before.

## 0.9.3

- Fixed invites that could get stuck at "(Joining...)". Invitations now survive a /reload by the inviter, a lost accept is retried automatically, and the join finishes as soon as the fellowship history arrives.
- You now get a notice when you and the inviter are on different Fellowship versions.
- New `/fship version` and `/fship debug` commands to help track down sync problems.

## 0.9.2

- The chat window now has a member list on the right, like the guild window: online members in their class color (listed first), offline members greyed out, and the Admin marked with a gold *.

## 0.9.1 (first public release)

Fellowship gives a small group of friends a private chat and a shared adventure feed, with history that catches you up on whatever you missed while offline.

### Chat
- Private fellowship chat: `/fs <message>`; `/fs` on its own opens the window
- Names in class colors; chat text in its own color (change it in Settings)
- Choose which chat tabs show Fellowship: right-click a chat tab and tick **Show Fellowship**, or `/fship tab`

### Offline catch-up
- Every member keeps the full history; when you log in, any online member fills in what you missed
- "New since you were last here" divider and a "While you were away…" login summary

### Shared announcements
- Achievements, level-ups, new mounts/pets/toys
- Loot: Rare, Epic or Legendary and up (each person picks their minimum)
- Dungeon and raid completions, including keystone level and timing
- Deaths (in red) and online/offline notices
- Every announcement can be switched off for sharing and for showing in the Settings window

### Members
- Membership is per account: alts and new characters join automatically with the same role
- Roles: Admin, Inviter, Member. Admin can be passed on (the new Admin must accept)
- Members tab: who's online, which character they're on, zone and level, last seen
- Invite from the right-click menu on players, or `/fship invite <player>`; guild-style invite popup
- Members removed while offline are told when they next log in

### Interface
- Fellowship window with Chat, Activity and Members tabs
- Settings window (`/fship settings`)
- Minimap button: left-click opens Fellowship, right-click for the menu, drag to move
