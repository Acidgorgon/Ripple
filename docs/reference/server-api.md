# Server API

```lua
local Ripple = require(ReplicatedStorage.Shared.Ripple.Server)
```

## `Ripple.<State>.new`

```lua
Ripple.Club.new(player: Player, data): Club      -- Scope: Player
Ripple.Match.new(data): Match                   -- Scope: All
Ripple.Room.new(data, players: { Player }?): Room -- Scope: Manual
```

Validates `data` in full, wraps it and returns the tracked object. `data` stays the source of truth:
writes through the object are applied to it. Errors if `data` doesn't match the schema.

`Player` states are destroyed automatically when the owner leaves. `All` states are sent to every current
and future player.

## The state object

Reads, writes, iteration (`for k, v in obj`) and `#obj` work like the plain table. Writes are validated
and queued for the next flush. Nested tables come back as tracked objects too.

## `Ripple.insert(array, value)` / `Ripple.insert(array, index, value)`

Appends, or inserts at `index` and shifts the rest up. Use instead of `table.insert`.

## `Ripple.remove(array, index?)`

Removes the last element, or the one at `index`, and returns it. Use instead of `table.remove`.

## `Ripple.raw(obj)`

Returns the plain table behind a state object or any tracked table inside it.

## `Ripple.subscribe(state, player)` / `Ripple.unsubscribe(state, player)`

Starts or stops sending a state to a player. Subscribing sends a full snapshot on the next flush.
Unsubscribing makes the client drop its copy (and fire `removed`). Works for any scope; unsubscribing a
player from an `All` state turns it into a manually managed one.

## `Ripple.destroy(state)`

Stops replicating the state. Clients drop their copies. The data table is left as it is, and later writes
through the object still change it, but nothing is sent.

## `Ripple.isDirty(state): boolean` / `Ripple.clearDirty(state)`

`isDirty` is true after any tracked write (including `server` fields) since the state was created or since
the last `clearDirty`. Use them to save only when something changed.

## `Ripple.flush()`

Sends all pending changes now. Runs automatically on every `Heartbeat`.

## `Ripple.setTransport(send, sendAll?)`

```lua
Ripple.setTransport(
	function(player: Player, data: buffer) end,
	function(data: buffer) end -- optional
)
```

Replaces the built-in RemoteEvent. `send` gets each player's buffer; `sendAll`, if given, gets updates
for `All` states once for everyone. See [Riding on Current](/guide/current).
