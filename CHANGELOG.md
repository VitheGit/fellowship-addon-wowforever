# Changelog

## 0.11.3

- The Dungeons tab no longer lists every zone and battleground. WoW Forever's group finder list includes those, so it's now used only to add level ranges and pictures to real dungeons and raids.
- Level ranges of "LV 1" from that list are ignored, so each dungeon keeps its real range.

## 0.11.2

- Fixed the Achievements tab showing "No dungeons to show yet". Fellowship now has its own list of every dungeon and raid, with level ranges, so the cards always show. If the game also provides its dungeon list, its level ranges and pictures are used.
- New `/fship dungeons` command, which shows what the game's dungeon lists give the addon. It helps with fixing missing pictures.

## 0.11.1

- The Achievements tab now has **Dungeons** and **Raids** sub-tabs, with a card for each one showing its picture and level range, like the game's dungeon picker.
- Each card says **Completed: date** in green, or **Incomplete** in red. Hover a card to see who was there and on which difficulty.
- Cards are sorted by level. Any difficulty completes a card.

## 0.11.0

- New Achievements tab with Fellowship Achievements, earned together. Complete a dungeon or clear a raid (final boss down) where everyone in your group is in the fellowship, and it's marked complete with the date and who was there.
- Each dungeon and raid is its own achievement per difficulty, so Deadmines (Normal) and Deadmines (Heroic) count separately. Groups need at least two players; NPC followers don't count against you.
- The fellowship sees "Fellowship Achievement: completed [Deadmines (Normal)] with ..." once, even though everyone in the group's addon notices it.
- Dungeons and raids you haven't done together yet are listed in grey underneath, so you can see what's left.
- Fellowship Achievements are kept forever (never trimmed with old history), and new members get them when they join.
- Everyone needs 0.11.0 to earn them; older versions still store them and show them as a milestone.

## 0.10.2

- Fixed chat lines that some members never saw. A message that got lost on the way is now noticed and fetched as soon as the next message arrives, or within two minutes at most, and it shows up in chat (marked with how long ago it was sent) instead of only in the window.
- Messages the game refuses to send for a moment (for example while addon messages are locked down in combat) are kept and sent shortly after, instead of being dropped.

## 0.10.1

- Death messages now say what killed you, using the game's Death Recap: "was killed by Hogger (Vicious Slice)", "fell to their death", "drowned", "burned to death in lava", and so on.
- If there's no recap, Fellowship notices falling and drowning itself, or names the enemy you were fighting ("died fighting Defias Bandit").
- Still no combat log reading, so no "blocked action" popups.

## 0.10.0

- Rare mob announcements: when you come across a rare, the fellowship sees "Vithe Valestrider has encountered RareMob01! in Elwynn Forest [Map Pin]". Click the map pin to set a waypoint to it.
- Rares are found the same way RareScanner finds them (the rare markers on the minimap), plus rare nameplates, targets and mouseovers. You don't need RareScanner installed.
- Each rare is announced once: not again by you for 10 minutes, and not at all if someone in the fellowship called it out in the last 5 minutes. Open-world rares only.
- New "Rare mobs spotted" row in Settings to switch sharing and showing on or off.

## 0.9.9

- Update notices: when someone in your fellowship has a newer version of Fellowship, you get a message in Fellowship chat telling you to update, repeated at most once an hour until you do. (Addons can't check the internet, so this works by comparing versions with other members.)

## 0.9.8

- The Members tab is now a roster like the guild window: Name, Level, Zone, Rank and Last Online columns. Online members are in their class color, offline members are greyed out.
- Click a column header to sort by it (click again to reverse). Scroll with the mouse wheel.
- **Show offline members** checkbox to hide or show offline members.
- Hover a member for details (characters, member since, achievements shared). Right-click for Whisper and Invite to Group, and for the Admin: Make Inviter/Member, Pass Admin and Remove from Fellowship.

## 0.9.7

- Item links work in Fellowship chat. Shift-click an item, spell or achievement while typing `/fs` (or in the Fellowship window's chat box) and everyone sees a clickable link. Other formatting codes are still blocked for safety.

## 0.9.6

- When you're not in a fellowship, the Fellowship window (and the minimap button) now opens a "Create Fellowship" screen: type a name and click Create.
- Inviters now get a message when someone accepts ("... accepted your invitation and joined ..."), declines, or lets the invitation time out.

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
