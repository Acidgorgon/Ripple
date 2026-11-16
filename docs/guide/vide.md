# Vide

Ripple turns any field into a [Vide](https://centau.github.io/vide/) source, so UI updates itself when the
server changes the value.

## Setup

Call `useVide` once, before creating sources (Ripple doesn't depend on Vide, you hand it in):

```lua
local vide = require(ReplicatedStorage.Packages.vide)
local Ripple = require(ReplicatedStorage.Shared.Ripple.Client)

Ripple.useVide(vide)
```

## Sources

```lua
local create = vide.create

local function CashLabel(club)
	local cash = Ripple.source(club, "Cash")   -- a Vide source that follows club.Cash

	return create "TextLabel" {
		Size = UDim2.fromOffset(200, 40),
		Text = function()
			return `{cash()} coins`
		end,
	}
end

local club = Ripple.Club.wait()
CashLabel(club).Parent = screenGui
```

`Ripple.source(t, key)` is cached per table and key, so calling it from several components gives the same
source. It works on any table in the state, not just the root:

```lua
local level = Ripple.source(club.Owned.i42, "Level")
local wins  = Ripple.source(club.Stats, "Wins")
```

## Lists

For a map or array, take a source of the field that holds it. It updates whenever anything inside
changes, and the table keeps its identity, so pair it with Vide's `indexes`/`values`:

```lua
local owned = Ripple.source(club, "Owned")

create "ScrollingFrame" {
	vide.indexes(function()
		return owned()
	end, function(card, id)
		return CardTile { card = card, id = id }
	end),
}
```

Inside a tile, take sources of that card's own fields (`Ripple.source(card(), "Level")`) so only that tile
re-renders when one card changes.

## UI Labs stories

In a story there is no server. Build a plain table that matches your schema and pass it to your
components. Ripple listeners and sources work on any table, so components written against
`Ripple.source` render in UI Labs with mock data.
