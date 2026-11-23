# Ripple

**Docs: https://acidgorgon.github.io/Ripple/**

Schema-first state replication for Roblox. You describe your state once, Ripple generates a typed
server and client module, and from then on you just write to plain-looking tables on the server.
Ripple tracks what changed, packs only those fields into one buffer per player per frame, and keeps a
plain table on every client in sync.

> [!NOTE]
> **Made with Claude.** Most of Ripple was written with [Claude](https://claude.ai), Anthropic's AI, to speed up my own Roblox workflow. Issues and pull requests are welcome.

```lua
-- server
local Ripple = require(ReplicatedStorage.Ripple.Server)

local club = Ripple.Club.new(player, profile.Data) -- profile.Data stays a plain table you save as usual
club.Cash += 250                                   -- sends ~12 bytes to this player next frame
club.Owned.i42.Level = 3                           -- sends just that card's Level
```

```lua
-- client
local Ripple = require(ReplicatedStorage.Ripple.Client)

local club = Ripple.Club.wait()
print(club.Cash)                       -- a plain table, read it like any other
Ripple.observe(club, "Cash", function(cash)
	cashLabel.Text = tostring(cash)
end)
```

It is built to sit next to **Current** (our faster two-way Blink) for events and **Anchor** (saving),
with **Vide** for UI.

## Why

Most Roblox state libraries send Luau tables through RemoteEvents. Roblox then serializes every table in
C++, which never shows up in your script profiler but is real server time. Measured in Studio on a Ryzen
7 7700X, one `FireClient` of a 300-card club table costs **~290 µs**, while a buffer costs **~3 µs no matter
its size** (see [RESULTS.md](bench/RESULTS.md)). Ripple only ever sends buffers, sends only what changed,
and encodes each change once no matter how many players see it.

## Install and generate

1. Write a schema (`game.ripple`):

```
struct Card {
	CardId: u16,
	Level: u8,
	Locked: boolean,
}

state Club {
	Scope: Player,
	Data: struct {
		Cash: f64,
		Tier: u8,
		Owned: map { [string]: Card },
		Slots: string[],
		server LastSave: f64,   -- saved, validated, never sent to anyone
	},
}

state Match {
	Scope: All,
	Data: struct {
		Clock: f32,
		HomeScore: u8,
		AwayScore: u8,
	},
}
```

2. Install the compiler with [Rokit](https://github.com/rojo-rbx/rokit) and generate the modules:

```
rokit add Acidgorgon/Ripple
ripple game.ripple --out src/shared/Ripple        # add --watch to regenerate on save
```

From a checkout you can also run `lune run src/init.luau -- game.ripple --out src/shared/Ripple`.

This writes `Server.luau` and `Client.luau`. Each is self-contained, with no runtime dependency and full
Luau types for your states.

To keep the server module out of `ReplicatedStorage` (where every client downloads it), give each module its
own path in the schema. Paths are relative to the schema and win over `--out`:

```
option ServerOutput = "src/server/Ripple/Server.luau"
option ClientOutput = "src/shared/Ripple/Client.luau"
```

## Schema

| Type | Notes |
|---|---|
| `u8 u16 u32 i8 i16 i32` | integers, range-checked on write |
| `f32 f64` | numbers (NaN rejected) |
| `uint int` | variable length integers (1 byte for small values) |
| `boolean string buffer vector` | `vector` is a Vector3 |
| `enum Name = { A, B, C }` | written as strings, sent as one byte |
| `struct { ... }` / `struct Name { ... }` | named fields |
| `map { [K]: V }` | only changed keys are sent |
| `T[]` | arrays; appends/edits send the touched index only |
| `T?` | optional |
| `any` | untyped tables (tracked, but slower and bigger: avoid in hot data) |
| `server Field: T` | kept and validated on the server, never replicated |

A `state` has a `Scope`:

- `Player`: one per player, sent only to that player. `Ripple.X.new(player, data)`. Destroyed automatically
  when the player leaves.
- `All`: sent to everyone, including late joiners. `Ripple.X.new(data)`. Changes go out once through
  `FireAllClients` when nothing private is pending.
- `Manual`: you choose who sees it. `Ripple.X.new(data, players?)`, then `Ripple.subscribe` and
  `Ripple.unsubscribe`.

## Server API

```lua
local state = Ripple.Club.new(player, data) -- returns a tracked view of `data`
state.Cash = 10                             -- validated, marked dirty, sent next frame
state.Owned.i7 = { CardId = 7, Level = 1, Locked = false }
state.Owned.i7 = nil
Ripple.insert(state.Slots, "i7")            -- table.insert/remove bypass tracking: use these
Ripple.remove(state.Slots, 1)

Ripple.raw(state)            -- the plain table behind it (this is what you save)
Ripple.isDirty(state)        -- any write since the last clearDirty?
Ripple.clearDirty(state)
Ripple.subscribe(state, player) / Ripple.unsubscribe(state, player)
Ripple.destroy(state)        -- stops replicating; the plain table is untouched
Ripple.flush()               -- send now (runs automatically on Heartbeat)
```

The data you pass in stays the source of truth: Ripple writes through to it, so the same table can be
handed straight to ProfileStore/Anchor for saving.

## Client API

```lua
Ripple.Club.get(player?)     -- current table or nil (Player scope: yours by default)
Ripple.Club.wait(player?)    -- yields until it exists
Ripple.Club.all()            -- every Club this client holds
Ripple.Club.added(fn)        -- fn(data, owner?) for existing and future
Ripple.Club.removed(fn)

Ripple.changed(t, "Cash", fn) -- fn(new, old) when t.Cash changes (also when a table inside it changes)
Ripple.changed(t, fn)         -- fn(t) once per update that touched anything in t
Ripple.observe(t, "Cash", fn) -- changed + call now
```

Tables keep their identity across updates: `club.Owned.i7` is the same table after its Level changes, so
you can hold on to it.

### Vide

```lua
Ripple.useVide(require(ReplicatedStorage.Packages.vide))

local cash = Ripple.source(club, "Cash") -- a Vide source that follows club.Cash
return create "TextLabel" { Text = function() return `{cash()}` end }
```

## Riding on Current (Blink+)

By default Ripple uses its own RemoteEvent (`option RemoteName = "..."` to rename it). To share one
channel with your other networking, send its buffer through a Current event:

```
-- current.blink
event RippleSync { From: Server, Type: Reliable, Data: buffer }
```

```lua
-- server
Ripple.setTransport(
	function(player, data) Net.RippleSync.Fire(player, data) end,
	function(data) Net.RippleSync.FireAll(data) end
)
-- client
Net.RippleSync.On(Ripple.receive)
```

## Security

- **Server authoritative.** Ripple has no client-to-server path. Clients cannot write state, and the
  default remote ignores anything fired at it.
- **Every write is validated** against the schema: wrong types, out-of-range integers, NaN, unknown
  fields, wrong key types and holes in arrays all error at the line that did the write, before anything
  is stored or sent. A bug or an unchecked remote argument cannot corrupt the save.
- **`server` fields never leave the server**, not even their change bits.
- **Player scope data only reaches its owner.** Other players never receive it unless you subscribe them.
- **Leaving players** are dropped from every state in `PlayerRemoving`, and their own states are destroyed,
  so nothing is sent to a player who is gone.
- Writing through a table you replaced (`local c = club.Owned.i7; club.Owned.i7 = other; c.Level = 9`)
  warns and does nothing, instead of silently desyncing.

Trading and duplication safety (both sides saved atomically, leave-mid-trade rollback) is Anchor's job.
Ripple supports it with `isDirty`/`clearDirty` per state and by keeping the saved table plain.

## Benchmarks

See [bench/RESULTS.md](bench/RESULTS.md). Short version: Ripple sends 2 to 20 times fewer bytes than
Replica, ReplicaService, Charm (charm-sync), Reflex or DataService, and once Roblox's own table
serialization is counted it uses the least server time in every scenario except the once-a-second
Cash tick, where everything ties on the fixed cost of one remote call per player.

## Layout

- `src/` compiler: `Parser`, `Generator`, `Codec`, `init.luau` (CLI) and `runtime/` (spliced into the output)
- `scripts/bundle.py` + `.github/workflows/release.yml`: single-file build and the release (Actions > Release)
- `tests/` correctness suite (`tests/run.luau`, run with the bench host)
- `bench/` benchmark harness (Luau 0.700 host + Roblox mock) with adapters for every library compared
- `examples/` FM-shaped schema
