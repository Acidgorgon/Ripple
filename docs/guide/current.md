# Riding on Current

By default Ripple creates one `RemoteEvent` in `ReplicatedStorage` (named `Ripple`, change it with
`option RemoteName = "Name"` in the schema) and sends one buffer per player per frame through it.

If you use [Current](https://acidgorgon.github.io/Current/) for your networking, Ripple can send through
a Current event instead, so all your traffic shares one channel and one place to monitor.

## 1. Add an event to your Current schema

```blink
event RippleSync {
	From: Server,
	Type: Reliable,
	Call: SingleSync,
	Data: buffer,
}
```

## 2. Point Ripple at it

```lua
-- server
local Net = require(ReplicatedStorage.Shared.Net.Server)
local Ripple = require(ReplicatedStorage.Shared.Ripple.Server)

Ripple.setTransport(
	function(player, data) Net.RippleSync.Fire(player, data) end,
	function(data) Net.RippleSync.FireAll(data) end -- optional: shared updates go out once
)
```

```lua
-- client
local Net = require(ReplicatedStorage.Shared.Net.Client)
local Ripple = require(ReplicatedStorage.Shared.Ripple.Client)

Net.RippleSync.On(Ripple.receive)
```

Without the second function, updates to `Scope: All` states are appended to each player's buffer instead of
being sent once to everyone.

## Ordering

Ripple flushes on `Heartbeat`. When Ripple rides on Current, its buffer joins Current's ordered stream
at the moment Ripple flushes. If a Current event must arrive after a state change (for example "match
ended" after the final score), write the state, call `Ripple.flush()`, then fire the event.
