# Client API

```lua
local Ripple = require(ReplicatedStorage.Shared.Ripple.Client)
```

All tables you get are plain tables. Don't write to them; the server's next update would overwrite it.

## Per state

| Function | Returns |
|---|---|
| `Ripple.Club.get(player?)` | the table, or `nil`. `Player` scope: that player's (yours by default). Other scopes: the newest one you hold. |
| `Ripple.Club.wait(player?)` | like `get`, but yields until it exists |
| `Ripple.Club.all()` | an array of every table of this state you hold |
| `Ripple.Club.added(fn)` | `fn(data, owner?)` for each existing and future one. Returns a connection. |
| `Ripple.Club.removed(fn)` | `fn(data, owner?)` when one is destroyed or you're unsubscribed. Returns a connection. |

## `Ripple.changed(t, key, fn)`

`fn(new, old)` runs when `t[key]` changes, including when a table under `t[key]` changes (then `new` and
`old` are the same table). Returns a connection with `:Disconnect()`.

## `Ripple.changed(t, fn)`

`fn(t)` runs once per update that changed anything in `t`, at any depth.

## `Ripple.observe(t, key, fn)`

Like `changed(t, key, fn)`, and also calls `fn(t[key])` right away.

## `Ripple.useVide(vide)` / `Ripple.source(t, key)`

`useVide` hands Ripple your Vide module once. `source(t, key)` then returns a Vide source that follows
`t[key]`, cached per table and key. See [Vide](/guide/vide).

## `Ripple.receive(data: buffer)`

Applies one update buffer. Only needed with a custom transport (`setTransport` on the server).

## Timing

Updates are applied in one go per buffer. Listeners run after the whole buffer is applied, so a listener always sees
a consistent state, never a half-applied update.
