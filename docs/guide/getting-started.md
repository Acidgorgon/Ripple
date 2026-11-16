# Getting started

## 1. Get the compiler

Ripple is a compiler that turns a `.ripple` schema into two Luau modules. It runs on
[Lune](https://github.com/lune-org/lune). With [Rokit](https://github.com/rojo-rbx/rokit):

```toml
# rokit.toml
[tools]
lune = "lune-org/lune@0.10.4"
```

Then clone or download Ripple next to your project.

## 2. Write a schema

Create `game.ripple`:

```ripple
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
		server LastLogin: f64,
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

`Club` is private to each player. `Match` is shared with everyone. `LastLogin` is a `server` field: kept and
validated on the server, never sent. The [schema reference](/reference/schema) lists every type.

## 3. Generate

```sh
lune run path/to/ripple/src/init.luau -- game.ripple --out src/shared/Ripple
```

This writes `Server.luau` and `Client.luau`. They are self-contained (no packages to install) and fully
typed. Regenerate whenever you change the schema. Sync them into `ReplicatedStorage` with Rojo as usual.

## 4. Use it on the server

```lua
local Ripple = require(ReplicatedStorage.Shared.Ripple.Server)

Players.PlayerAdded:Connect(function(player)
	local data = loadProfile(player) -- any plain table that matches the schema
	local club = Ripple.Club.new(player, data)

	club.Cash += 100
	club.Owned.i42 = { CardId = 42, Level = 1, Locked = false }
	club.Owned.i42.Level += 1
end)

local match = Ripple.Match.new({ Clock = 0, HomeScore = 0, AwayScore = 0 })
RunService.Heartbeat:Connect(function(dt)
	match.Clock += dt
end)
```

Every write is checked against the schema and sent at the end of the frame. When a player leaves, their
`Player`-scope states are cleaned up for you.

## 5. Read it on the client

```lua
local Ripple = require(ReplicatedStorage.Shared.Ripple.Client)

local club = Ripple.Club.wait()
print(club.Cash, club.Owned.i42.Level)

Ripple.observe(club, "Cash", function(cash)
	cashLabel.Text = tostring(cash)
end)

Ripple.Match.added(function(match)
	Ripple.changed(match, "HomeScore", function(score)
		print("Goal! Home has", score)
	end)
end)
```

That's it. Next: [Writing state](/guide/server), [Reading state](/guide/client), or [Vide](/guide/vide).
