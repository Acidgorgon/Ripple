# Reading state (client)

The client module gives you plain tables. Read them like any table: no getters, no proxies.

## Getting a state

```lua
local Ripple = require(ReplicatedStorage.Shared.Ripple.Client)

local club = Ripple.Club.get()      -- your Club, or nil if it hasn't arrived yet
local club = Ripple.Club.wait()     -- yields until it arrives
local theirs = Ripple.Club.get(otherPlayer) -- someone else's, if the server subscribed you to it
local match = Ripple.Match.get()    -- Scope All / Manual: the newest one you hold
local all = Ripple.Room.all()       -- every Room you hold
```

For states that come and go, use `added` and `removed`. `added` also runs for those you already hold:

```lua
Ripple.Match.added(function(match)
	print("match started", match.Clock)
end)
Ripple.Match.removed(function(match)
	print("match over")
end)
```

## Reacting to changes

```lua
-- one key
local conn = Ripple.changed(club, "Cash", function(new, old)
	print("cash", old, "->", new)
end)

-- one key, and run now with the current value
Ripple.observe(club, "Cash", function(cash)
	cashLabel.Text = tostring(cash)
end)

-- anything in a table (fires once per update, however many keys changed)
Ripple.changed(club.Owned, function(owned)
	refreshCollection(owned)
end)

conn:Disconnect()
```

A listener on a key also fires when a table under that key changes. `Ripple.changed(club, "Owned", fn)`
fires when any card is added, removed or edited.

Listeners run after the whole update is applied, so inside a listener every field is already up to date.

## Identity

Tables keep their identity across updates. `club.Owned.i42` is the same table after its `Level` changes,
so you can keep references in UI code or use tables as keys. A table is replaced only when the server
replaced it (for example `club.Owned.i42 = newCard`).

## Don't write on the client

The client copy is a mirror. Writing to it changes only your local copy, and the next server update to
that field overwrites it. Send requests to the server with Current (or a RemoteEvent) and let the server
write.
