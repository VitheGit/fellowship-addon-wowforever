# Fellowship design

## Goals

1. Private chat and an achievement feed for a small group (roughly 2 to 20 people).
2. Persistence: someone who was offline can read what happened while they were away.
3. No server, no external tools: only what the game client provides.

## Transport

Addon messages (`C_ChatInfo.SendAddonMessage`, prefix `Fellowship`) sent as
**whispers** to each member. Whispers are private (unlike a custom chat channel that
anyone can join), work across connected realms, and arrive in order.

- Frames are at most 255 bytes: `<msgId>:<index>:<total>:<data>`. Long messages are
  chunked at UTF-8 character boundaries and reassembled.
- Sending uses a token bucket (10 burst, 1 per second, retried if the server returns
  `AddonMessageThrottle`). Live traffic (chat, presence) jumps ahead of bulk catch-up.
- New events (chat, announcements) are also broadcast once on a **hidden fellowship
  channel** (Channel.lua), so one message reaches every member listening there. Its name
  and password are codes made from the fellowship id (and the number of removals, so a
  removal moves everyone to a new channel). A taken name makes everyone try `<name>2`..`5`
  in the same order. Members we haven't heard on the channel (older versions, no free
  channel slot) still get whispers; catch-up, requests and presence stay on whispers.
- Whispering an offline member produces "No player named X is currently playing".
  A chat filter hides those for players we just messaged, and marks them offline.

## Data model: a replicated event log

Each event is `(author, seq, time, kind, fields...)`. `seq` counts up per author, so
`(author, seq)` is a globally unique id and duplicates are free to drop.

| Kind | Meaning | Fields |
| --- | --- | --- |
| `N` | fellowship created (author is founder) | name |
| `J` | member joined (author is the inviter) | new member |
| `L` | author left | |
| `K` | member removed (Admin only) | member |
| `V` | roles switched on (Admin) | |
| `R` | set role (Admin only) | member, `inviter` or `member` |
| `T` | Admin offers the Admin role (`""` cancels) | member |
| `X` | offer accepted: author becomes Admin, old Admin becomes Inviter | offer author, offer seq |
| `W` | offer declined | offer author, offer seq |
| `Q` | this character belongs to account `id` | account id, account secret |
| `Y` | an alt joins through its account | account id, account secret |
| `C` | chat | text |
| `A` | achievement | id, name, points |
| `M` | milestone | "level", level |

Membership and roles are computed by replaying these events in time order, so the
roster is part of the same log and syncs the same way, including to members who were
offline. The founder starts as Admin. Invites (`J`) count only from the Admin or an
Inviter once roles are on (`V`); fellowships made before roles existed let any member
invite until the Admin's client publishes `V`. A role change only counts if its author
was Admin at that point in the history, and an Admin hand-off needs the target's own
`X` event, so nobody can take Admin without accepting it. If an Admin's `L` ever
appears, the longest-standing Inviter (else Member) takes over.

For each author every member tracks a **high-water mark** (hwm): the highest `n` such
that events `1..n` are all present. The vector of hwms is a compact "what I have".

### Accounts

Members are WoW accounts. Each account's SavedVariables hold a random account id and
secret. A member character publishes `Q` (id + secret) once it's in, so every member
learns the secret. When another character on that account logs in, it sees the
fellowship in the shared SavedVariables, publishes `Y` with the same id + secret, and
sends it ahead of its `HI` in an `LNK` message; members check the secret before
trusting it. Characters invited separately before this existed merge into one account
when both publish `Q`. Roles, Admin, `L` and `K` apply to the whole account. The secret
is only ever sent to members, so outsiders can't join as someone's "alt".

## Protocol

| Message | Records | Purpose |
| --- | --- | --- |
| `HI fid 1 wantReply` | `author hwm class`... | presence, summary and class colors |
| `REQ fid 1` | `author fromSeq`... | ask for events after `fromSeq` |
| `EV fid 1 live` | event... | events (`live=1` when just created) |
| `FL fid 1` | `author floor`... | "I pruned up to `floor`, don't wait for those" |
| `INV fid 1 name` / `ACC` / `DEC reason` | | invitations |
| `PI fid 1` | | presence ping every 60s to members seen online; a bounce marks them offline |

Records are separated by byte `\30`, fields by `\31`; both are stripped from user text.

**Catch-up:** on login (and every 5 minutes) a member sends `HI` to every other
member. Each recipient compares vectors, sends `REQ` for anything it is behind on,
and replies with its own `HI` so the newcomer can do the same. Any member can serve
any author's events, which is what lets history reach you when the author is offline.
A `REQ` for a given author is not repeated for 60 seconds, so when several members
answer a login at once the history is only downloaded once.

**Live:** a new event is whispered to every member currently seen online.

**Joining:** the inviter sends `INV`; the invitee accepts, sends `ACC` + `HI`; the
inviter publishes a `J` event; the newcomer then downloads the whole log from the
inviter and says `HI` to everyone else once it sees itself in the roster.

**Trust:** messages are only accepted from current roster members (plus the inviter
while joining). If a former member (removed or left while offline) says `HI`, members
don't trust it, but reply once with the membership events it's missing, so its client
sees the removal and cleans up. User text is escaped (`|` becomes `||`) before display.

## Wishlists

Each character's wishlist is one replicated record, newest version wins (`WL fid 1 | author
version | item...`, items as id, mode, want, have, notify, note, name, quality). It lives in
`f.wishes`, outside the event log, so older versions ignore it and it is never pruned. A `WV`
summary (author, version pairs) goes with every HI reply; the other side sends back any list
it holds a newer version of, and answers with its own summary when it is behind. Changes are
broadcast like events (channel, then whispers). Loot of a wished-for item is posted as an `M`
loot event with field 5 `"1"` (wish granted) and field 6 the wanters' names, so older versions
still show "X looted [Item]".

## Persistence and pruning

`FellowshipDB` (account-wide SavedVariables) holds every fellowship's log, plus per
character the active fellowship and the "last read" time. At login, chat and
achievements beyond 3000 events or 180 days are pruned; membership events and
Fellowship Achievements (`M` events with subtype `feat`, see Feats.lua) are never
pruned and are always included in a catch-up. Pruning raises a per-author `floor` so peers stop asking for removed events.

## Known limits / ideas

- One fellowship per account.
- Catch-up only happens when you overlap online with a member who has the history.
- Ideas: toast popups for achievements, multiple fellowships,
  sharing guild-wide or account-wide achievements as an option.
