# Writing state (server)

## Creating a state

Each `state` in your schema becomes `Ripple.<Name>` with a `new` function. What `new` takes depends on the
state's `Scope`:

```lua
local club  = Ripple.Club.new(player, data)       -- Scope: Player  (sent to that player only)
local match = Ripple.Match.new(data)              -- Scope: All     (sent to everyone, late joiners too)
local room  = Ripple.Room.new(data, { p1, p2 })   -- Scope: Manual  (you choose; players list optional)
```

`data` is a plain table that must match the schema. It is validated in full when you call `new`. Ripple
keeps using **that same table**: every write you make through the returned object is applied to it. So
`data` is always current and can be saved as it is.

## Writing

The object you get back reads and writes like the table itself:

```lua
club.Cash += 250
club.Tier = 3
club.Owned.i42 = { CardId = 42, Level = 1, Locked = false }   -- add a map entry
club.Owned.i42.Level += 1                                     -- change one field inside it
club.Owned.i42 = nil                                          -- remove it
club.Stats.Wins += 1
```

Each write is checked against the schema immediately. A wrong type, an out-of-range integer, NaN, an
unknown field or a bad key raises an error at that line, naming the field:

```
Ripple: Club.Owned[].Level expects u8 (integer 0..255), got number 300
Ripple: Club has no field 'Cahs' (add it to the schema)
```

Nothing is sent right away. At the end of the frame (on `Heartbeat`) Ripple sends each player one buffer
holding every change they should see. Writing the same field ten times in a frame sends it once.

## Arrays

Index writes and appends work as usual. `table.insert` and `table.remove` can't be tracked (they bypass
the object), so use Ripple's versions:

```lua
club.Slots[1] = "i42"                -- set
club.Slots[#club.Slots + 1] = "i7"   -- append
Ripple.insert(club.Slots, "i9")      -- append
Ripple.insert(club.Slots, 1, "i3")   -- insert at index 1
Ripple.remove(club.Slots)            -- remove last
Ripple.remove(club.Slots, 2)         -- remove at index 2
```

Changing or appending elements sends only those elements. Inserting or removing in the middle resends the
array once.

## Reading

Reads go through the object and cost about one table lookup:

```lua
if club.Cash >= price then
	club.Cash -= price
end
for id, card in club.Owned do   -- iteration works
	print(id, card.Level)
end
print(#club.Slots)               -- so does #
```

`Ripple.raw(t)` returns the plain table behind any Ripple object (or any table inside it). Use it for
saving, deep copies, or passing data to code that should not trigger replication.

## Holding on to sub-tables

You can keep a reference to a nested table and write through it later:

```lua
local card = club.Owned.i42
card.Level += 1   -- fine
```

If that entry is replaced or removed, the old reference is detached. Writing through it then warns and
does nothing, so a stale reference can't silently desync the client.

## Server-only fields

Mark a field `server` in the schema to keep it on the server:

```ripple
state Club {
	Scope: Player,
	Data: struct {
		Cash: f64,
		server Purchases: map { [string]: u32 },
		server Flags: u32,
	},
}
```

Server-only fields are validated and saved like any other field and count towards `isDirty`, but no bytes
about them are ever sent, not even the fact that they changed.

## Who receives what

| Scope | Receives it | Lifetime |
|---|---|---|
| `Player` | the owner | destroyed automatically when the owner leaves |
| `All` | every player, including those who join later | until `Ripple.destroy` |
| `Manual` | players you pass to `new` or `Ripple.subscribe` | until `Ripple.destroy` |

```lua
Ripple.subscribe(room, player)     -- sends a full snapshot next frame, then changes
Ripple.unsubscribe(room, player)   -- the client drops its copy
Ripple.destroy(room)               -- stops replicating everywhere; data stays as it is
```

New subscribers get one full snapshot, encoded once and copied to everyone who joined that frame.

## Flushing

Ripple flushes on every `Heartbeat`. Call `Ripple.flush()` to send immediately, for example right before
teleporting a player.
