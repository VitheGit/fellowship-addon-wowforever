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
| `K` | member removed (founder only) | member |
| `C` | chat | text |
| `A` | achievement | id, name, points |
| `M` | milestone | "level", level |

Membership is computed by replaying `N/J/L/K` in time order, so the roster is part of
the same log and syncs the same way.

For each author every member tracks a **high-water mark** (hwm): the highest `n` such
that events `1..n` are all present. The vector of hwms is a compact "what I have".

## Protocol

| Message | Records | Purpose |
| --- | --- | --- |
| `HI fid 1 wantReply` | `author hwm`... | presence and summary |
| `REQ fid 1` | `author fromSeq`... | ask for events after `fromSeq` |
| `EV fid 1 live` | event... | events (`live=1` when just created) |
| `FL fid 1` | `author floor`... | "I pruned up to `floor`, don't wait for those" |
| `INV fid 1 name` / `ACC` / `DEC reason` | | invitations |

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
while joining). User text is escaped (`|` becomes `||`) before display.

## Persistence and pruning

`FellowshipDB` (account-wide SavedVariables) holds every fellowship's log, plus per
character the active fellowship and the "last read" time. At login, chat and
achievements beyond 3000 events or 180 days are pruned; membership events are never
pruned. Pruning raises a per-author `floor` so peers stop asking for removed events.

## Known limits / ideas

- One fellowship per character (alts on the same account share storage, but each
  alt is invited separately).
- Catch-up only happens when you overlap online with a member who has the history.
- Founder leaving means nobody can remove members.
- Ideas: minimap button, toast popups for achievements, multiple fellowships,
  sharing guild-wide or account-wide achievements as an option.
