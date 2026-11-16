# Security

Most replication libraries are built for convenience and leave security to you. Ripple's design closes
the common holes by default.

## The client can't write

Ripple has no client-to-server path. State flows one way: server to client. An exploiter can change
their own local copy, which only fools their own screen, and the next server update overwrites it.

The default `RemoteEvent` has a server listener that ignores everything, so firing junk at it does nothing
and doesn't pile up in Roblox's event queue.

Requests ("buy this pack", "equip this card") should go through [Current](https://acidgorgon.github.io/Current/),
whose schema validates arguments, and your server code decides whether to write to Ripple state.

## Every write is validated

The generated server module checks every write against the schema before storing or sending it:

| Check | Example that errors |
|---|---|
| Type | `club.Cash = "lots"` |
| Integer range and whole numbers | `card.Level = 300` on a `u8`, `card.Level = 1.5` |
| NaN | `club.Cash = 0 / 0` (NaN breaks every comparison, a classic dupe and corruption bug) |
| Unknown fields | `club.Cahs = 5` (typos don't silently create data) |
| Key types | `club.Owned[42] = card` on a `map { [string]: Card }` |
| Array holes | `club.Slots[10] = "x"` on a 3-element array |
| Your own limits | `Level: u8(1..99)`, `Name: string(..20)`, `Slots: string[..11]` in the schema |
| Whole tables | `club.Owned.i9 = { CardId = 9 }` (missing fields) is rejected in full |
| `any` fields | Instances, functions, NaN, metatables and self-containing tables are rejected on write |

The error is raised at the line that made the bad write, before anything changes. So a server bug, or a
remote argument someone forgot to check, can't corrupt the save or crash every client that receives it.

## Server-only data stays on the server

Fields marked `server` are kept, validated and saved like any other field, but are never encoded. Not the
value, not the fact that it changed. Use them for anything a client must not see: purchase history,
moderation flags, hidden odds, anti-cheat state.

## Private data reaches only its owner

A `Scope: Player` state is sent only to its owner unless you explicitly `Ripple.subscribe` someone else.
Other players never receive another player's inventory or currency in the first place, so there is
nothing to sniff.

## Leaving players

When a player leaves, Ripple removes them from every state's subscriber list and destroys their own
`Player`-scope states in `PlayerRemoving`. Nothing is queued for a player who is gone.

## Stale references

If code keeps a reference to a nested table that has since been replaced (`local c = club.Owned.i7`,
then `club.Owned.i7 = newCard`), writes through the old reference warn and do nothing, instead of
changing data the client no longer shows.

## What Ripple doesn't do

- **Trades and duplication across saves.** Making both sides of a trade commit or roll back together, even
  if one player leaves mid-trade, is a saving problem. [Anchor](https://acidgorgon.github.io/Anchor/)
  handles it on top of Ripple.
- **Rate limits and request validation.** These belong at the point where clients send requests
  (Current events), not in replication.
