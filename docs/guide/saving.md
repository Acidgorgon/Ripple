# Saving with Anchor / ProfileStore

Ripple doesn't save anything. It replicates a table you already own, and writes through to it. That makes
saving simple: hand the same table to your saving library.

## With ProfileStore

```lua
local profile = PlayerStore:StartSessionAsync(`Player_{player.UserId}`, { Cancel = ... })
profile:AddUserId(player.UserId)
profile:Reconcile()

local club = Ripple.Club.new(player, profile.Data)  -- profile.Data stays a plain table

-- gameplay code writes through `club`
club.Cash += 50

-- ProfileStore saves profile.Data as usual; it is always up to date
```

When the player leaves, ProfileStore ends the session and Ripple destroys the player's `Player`-scope states
by itself. Destroying a Ripple state never touches the data table.

## With Anchor

[Anchor](https://acidgorgon.github.io/Anchor/) is built to sit under Ripple. Pass the profile's data the
same way:

```lua
local club = Ripple.Club.new(player, profile.Data)
```

Trades and other multi-player changes go through Anchor, which writes both sides through their Ripple
objects, so both players see the result in the same frame and both saves stay consistent. Anchor uses
`Ripple.isDirty` and `Ripple.clearDirty` to know when a state has unsaved changes.

## Knowing when to save

```lua
if Ripple.isDirty(club) then
	saveNow(Ripple.raw(club))
	Ripple.clearDirty(club)
end
```

`isDirty` is true after any tracked write since the last `clearDirty`, including writes to `server`
fields, which never replicate but do need saving.

## Rules

- Make all changes through the Ripple object (`club.Cash += 1`), not through `profile.Data` directly.
  Direct writes are saved but not replicated, and not validated.
- `Ripple.raw(club)` is the same table as `profile.Data`. Use it when you need the plain table, for example
  to deep-copy it.
- Keep derived values (prices, multipliers, display strings) out of saved state. Compute them on the
  client from replicated fields, so changing one field doesn't rebuild and resend everything.
