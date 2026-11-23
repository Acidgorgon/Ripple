# Getting started

## 1. Install the `ripple` command

Ripple is a compiler: it turns a `.ripple` schema into two Luau modules, so there is no runtime package to
install. Get the command with [Rokit](https://github.com/rojo-rbx/rokit):

```sh
rokit add Acidgorgon/Ripple
```

or pin it in your project's `rokit.toml`:

```toml
[tools]
ripple = "Acidgorgon/Ripple@0.1.0"
```

::: details Without Rokit
Download the zip for your platform from the [releases page](https://github.com/Acidgorgon/Ripple/releases),
or run the compiler from a checkout with [Lune](https://github.com/lune-org/lune):
`lune run path/to/Ripple/src/init.luau -- game.ripple --out src/shared/Ripple`.
:::

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
ripple game.ripple --out src/shared/Ripple
```

This writes `Server.luau` and `Client.luau`. They are self-contained (no packages to install) and fully
typed; commit them like any other source file and sync them into `ReplicatedStorage` with Rojo.

While you work on the schema, add `--watch` (`-w`) and Ripple regenerates every time you save it. A schema
error is printed and the last good output is kept.

### Keep the server module away from clients

Everything in `ReplicatedStorage` is downloaded by every client, so an exploiter can read the server
module, including your `server` fields and validation. Clients cannot change state either way, but the
server module has no reason to be there. Give each module its own path at the top of the schema (relative
to the schema file, like Current's options):

```ripple
option ServerOutput = "src/server/Ripple/Server.luau"  -- ServerScriptService
option ClientOutput = "src/shared/Ripple/Client.luau"  -- ReplicatedStorage
```

These options win over `--out` for their file. The server then requires
`ServerScriptService.Server.Ripple.Server`. Needs Ripple 0.1.1 or later.

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
