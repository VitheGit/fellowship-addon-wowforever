# Changelog

## 0.17.3

- **Name suggestions for @mentions.** Type `@` in the Fellowship window's chat box and a list of members pops up above it, narrowing as you type (`@ka` shows Kara Dunmore, Kai...). Click a name, or press Tab or Enter to pick the highlighted one, and use Up/Down to move through the list. `@all` is in the list too. Escape closes it.
- When two members share a first name, picking one fills in the full name so the right person is tagged.

## 0.17.2

- **"I have" column in Fellowship Wishes.** Next to "Wanted by", you now see how many of each wanted item you have in your bags and bank, in green when you have some. Glance down the list to spot anything you could hand over. It updates as your bags change.

## 0.17.1

- If the game ever shows "Fellowship has been blocked from an action only available to the Blizzard UI", Fellowship now notes which action it was. Type `/fship blocked` to see it, along with whether you were in combat, using a controller, or running ConsolePort. Send a screenshot of it so the cause can be fixed.

## 0.17.0

- **@mentions in Fellowship chat.** Type `@` and a name, like `@Kara`, to tag a member. They hear a short sound, see "Kara mentioned you in Fellowship chat" in the middle of the screen, and the game's icon flashes on their taskbar if the game is in the background.
- Tags work on any of a member's characters. Use the first name (`@Kara`), or the full name (`@Kara Dunmore`) when two members share a first name. `@all` or `@everyone` tags the whole fellowship.
- Tagged names are shown in orange in chat, so you can spot them.
- Press **Tab** in the chat box after `@` and a few letters to finish the name.
- Missed a mention while offline? The login summary now says "You were mentioned 2 times."
- Don't want the sound? Turn off "Sound and alert when someone @mentions you" in Settings.
- Nothing new is sent, so members on older versions still see the message, just without the sound or the orange name.

## 0.16.0

- **A cleaner Fellowship window.** The row of buttons along the top is gone. Pages are now in a sidebar on the left, each with an icon: Chat, Calendar, Wishlist, Achievements and Members.
- Red badges on the sidebar show new chat and activity while you're on another page, and how many calendar events are waiting for your answer.
- The window uses the game's portrait frame, with the Fellowship icon in the corner, your fellowship's name as the title and "4 of 5 online" under it. Settings is now a gear next to the close button.
- **Chat and Activity are now one feed.** Filters along the top let you show All, Chat, Loot, Dungeons, Levels, Deaths or More (achievements, collections, rare mobs). Your choice is remembered. The member list on the right can be hidden with the Members switch.
- Dungeons/Raids and My Wishlist/Fellowship Wishes are now small switches instead of big buttons.
- Input boxes show what to type ("Message Loot Kills...", "Search items to add..."), and the wishlist instructions moved into a "?" you can hover.
- The window can be resized from the bottom-right corner, and remembers its size and position.

## 0.15.0

- New **Calendar** tab for planning dungeon runs, raids and anything else. Any member can plan an event: click **New Event** (or click a day first), choose **Dungeon**, **Raid** or **Other**, pick the dungeon or raid from the list (or type a name for Other), then set the date, time and an optional note.
- Everyone answers **Going**, **Maybe** or **Can't**. The event shows who's going, who might come, who can't, and who hasn't answered yet. You can change your answer any time.
- The month view shows how many events each day has. The list on the right shows upcoming events, or the events on the day you clicked, with your answer next to each one.
- Only the person who planned an event can edit or cancel it. Everyone sees when it's cancelled.
- Notices in Fellowship chat when someone plans an event, and (for the person who planned it) when members answer.
- At login you see what's coming up in the next 24 hours, and how many events still need your answer. A reminder with a sound pops up 15 minutes before an event starts, unless you said you can't come.
- Times are shown in each person's own time zone.
- Events sync like wishlists, so members who were offline get them when they log in. Everyone needs 0.15.0 to see the calendar.
- New commands: `/fship calendar` opens the Calendar tab, and `/fship events` lists upcoming events in chat.
- The Fellowship window is a little wider, to fit the new tab.

## 0.14.1

- Fixed item search finding nothing. WoW Forever only offers item lookups through the game's newer item functions, so the background scan couldn't read any names, and wishlist counts could read 0. The scan now starts over once, by itself, and fills in properly.
- New `/fship items` command shows how many items search knows and how far the scan has got.

## 0.14.0

- **Item search in the Wishlist box.** Start typing a name, like "ore", and a list pops up with Copper Ore, Tin Ore, Iron Ore and so on. Click one to add it, or press Enter to add the top match. Typing several words narrows it down ("iron ore").
- The game doesn't let addons search items by name, so Fellowship learns item names itself. It remembers every item you loot, hover or see linked, and slowly asks the game about the rest in the background. This takes about 20 to 30 minutes of play the first time, and it pauses in combat and in dungeons and raids. It's done once per account, and again only to pick up new items after a patch. Until it finishes, the list shows how far along it is.

## 0.13.1

- Fixed adding items to the wishlist. With the Wishlist tab open, shift-clicking an item in your bags, a loot window, a vendor or a chat link now adds it straight away, instead of opening the "split stack" box.
- Fixed dragging an item onto the Wishlist tab. There's now an empty slot next to the box to drop items on, and dropping anywhere on the tab works too.

## 0.13.0

- New **Wishlist** tab. Add the items you're hunting for by shift-clicking them into the box, dragging them from your bags, right-clicking an item link in chat, or typing `/fship wish [item]`.
- **One-time wishes** (gear, mounts, recipes): when a fellowship member loots one, you get a ping and a sound, and everyone sees "Bob looted [Item] - Brad wanted this!". When you loot it yourself it comes off your list with "Wish granted!".
- **Always wanted** (trade goods and reagents like ore, herbs and cloth): these stay on your list and don't post anything when you loot them. You can set an amount (right-click, "Set amount wanted"), and friends see your bag and bank count, like "14/40", or "stocked" once you have enough. Pings for these are off unless you turn them on for that item.
- New items default to "always wanted" if they're trade goods or reagents, and one-time otherwise. Right-click a row to switch, set an amount, add a note, or remove it.
- Hovering any item shows "Fellowship: wanted by ..." with each friend's count.
- When a wanted item comes up in a loot roll, you see who wants it. When you open a mailbox with something a friend wants in your bags, you get one quiet reminder.
- "Fellowship Wishes" view shows everything the fellowship wants, grouped by item.
- Wishlists sync like chat, so offline members' lists still reach you. Older versions of Fellowship ignore them, so everyone needs 0.13.0 to see each other's lists.

## 0.12.0

- Fellowship chat and announcements now go through a hidden, password-protected chat channel. One message reaches everyone online at once, instead of one whisper per member, so big fellowships no longer see messages arrive late.
- Each fellowship gets its own channel. The name and password are codes only members' addons know, not your fellowship's name. If the name is ever taken, everyone moves to the same backup name automatically. Removing a member moves the fellowship to a new channel and password.
- The channel is hidden from your chat windows, and its join notices are hidden too.
- Members without the channel still get every message by whisper. That covers anyone on an older version, or with all 10 channel slots in use.
- New `/fship channel` command shows whether you're on the channel and how many members are heard on it.

## 0.11.10

- Fixed the X button not closing the Fellowship window (and the Settings window) while you're in combat.

## 0.11.9

- Fellowship Achievements now read "Loot Kills has completed Gnomeregan!" (your fellowship's name), instead of naming one member. The difficulty is added when it isn't Normal.
- When everyone in the group is in the fellowship, the separate "<name> completed Gnomeregan" lines from each member are no longer posted.

## 0.11.8

- City of Dalaran now completes when Shade of the Archmage dies.
- The Barrow Deeps raid (coming December 9) is ready: it completes when Sonya Darkhallow dies.

## 0.11.7

- Added WoW Forever's new dungeons to the Dungeons tab and to the final-boss list: Hall of Thanes (Durgen Dirgehammer), Ruins of Lordaeron (Rath'mael), Excavation Site (Relic Guardian), The Drowned City (Min'loth the Serpent), Krol'dok Stronghold (Overseer Mugg), Alcaz Prison (Blazeroar), Blackmaw Hold (the Unbound Spirit) and Shaper's Terrace (Nanaya). City of Dalaran and the Barrow Deeps raid get cards too, but their last bosses aren't known yet.
- Level ranges now match WoW Forever's dungeon list.

## 0.11.6

- Excavation Site counts now: killing the Relic Guardian finishes it, in any zone's Excavation Site. Its card shows up in the Dungeons tab once your fellowship has completed it.
- A dungeon also counts as finished when the game's own lockout shows every boss is dead, or when a scenario is completed.

## 0.11.5

- Fixed the Stockade not counting. WoW Forever calls it "Stormwind Stockade", which Fellowship didn't recognise, so killing Bazil Thredd or Dextren Ward didn't finish the run. If a dungeon's name isn't recognised, a known final boss now counts on its own.
- Another way to notice a finished dungeon: if the game doesn't report the boss fight, seeing the final boss dead (targeted, on its nameplate or boss frame) now counts too. Clicking the boss's corpse to loot it is enough.
- Added the newer final bosses in case WoW Forever uses them: Randolph Moloch (Stockade), Captain Cookie and Vanessa VanCleef (Deadmines), Lord Godfrey (Shadowfang Keep), Lava Guard Gordoth (Ragefire Chasm).
- The `/fship dungeons` boss log is now saved, so you can check it after a reload or on your next login.

## 0.11.4

- Fixed dungeon and raid completions not being noticed in WoW Forever, which meant no Fellowship Achievement (for example, The Stockade). The game doesn't say which boss is the last one, so Fellowship now has its own list of final bosses for every classic dungeon and raid. Any wing's last boss counts for Scarlet Monastery and Dire Maul.
- Finishing a dungeon you queued for through the group finder also counts.
- `/fship dungeons` now lists the boss kills it has seen since you logged in. With `/fship debug` on, it also says why a run didn't earn an achievement (for example, someone in the group isn't in the fellowship).

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
