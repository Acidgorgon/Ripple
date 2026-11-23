# Schema language

A `.ripple` file declares types and states. The syntax is close to Blink and Current, so the two schemas
read the same way.

```ripple
-- comments run to the end of the line
--[[ or span
     several lines ]]

option RemoteName = "Ripple"

enum Rarity = { Common, Rare, Epic, Legendary }

struct Card {
	CardId: u16,
	Level: u8(1..99),
	Rarity: Rarity,
	Locked: boolean,
}

type CardMap = map { [string(1..16)]: Card }

state Club {
	Scope: Player,
	Data: struct {
		Cash: f64(0..),
		Name: string(..20),
		Owned: CardMap,
		Slots: string[..11],
		Settings: struct { Music: boolean, Volume: f32(0..1) },
		Nickname: string?,
		server Purchases: map { [string]: u32 },
	},
}
```

## Primitives

| Type | Values | Size on the wire |
|---|---|---|
| `u8` `u16` `u32` | whole numbers 0..255, 0..65535, 0..4294967295 | 1, 2, 4 bytes |
| `i8` `i16` `i32` | whole numbers -128..127, -32768..32767, -2^31..2^31-1 | 1, 2, 4 bytes |
| `uint` | whole numbers 0..2^53 | 1 byte under 128, up to 8 |
| `int` | whole numbers ±2^53 | 1 byte for -64..63, up to 8 |
| `f32` `f64` | numbers (NaN rejected) | 4, 8 bytes |
| `boolean` | `true` / `false` | 1 byte |
| `string` | any string | length (1 byte under 128) + bytes |
| `buffer` | a buffer | length + bytes |
| `vector` | `Vector3` (NaN rejected) | 12 bytes |

Pick the smallest type that fits. Integer types reject fractions and out-of-range values, so they double as
validation.

## Ranges

Add a range in parentheses to limit a number's value or a string's or buffer's length:

```ripple
Level: u8(1..99),      -- 1 to 99
Volume: f32(0..1),
Cash: f64(0..),         -- no upper limit
Name: string(..20),     -- at most 20 bytes
Code: string(6),        -- exactly 6 bytes
```

A range on an array limits its length: `Slots: string[..11]`, `Team: u16[1..5]`. Ranges are enforced on
every write. They don't change the wire size.

## Optional

Add `?` to allow `nil`: `Nickname: string?`, `Pet: Pet?`. Map and array values can't be optional; setting a
key to `nil` removes it.

## Enums

```ripple
enum Phase = { Lobby, Playing, Ended }
```

Values are strings in Luau (`match.Phase = "Playing"`) and one byte on the wire. Up to 256 values.

## Structs

Named, reusable:

```ripple
struct Card { CardId: u16, Level: u8 }
```

or inline: `Settings: struct { Music: boolean, Volume: f32 }`. Up to 255 fields. Each field has a change
bit, so a patch to a struct carries a small mask plus only the fields that changed.

## Maps

```ripple
Owned: map { [string]: Card },
Scores: map { [u16]: u32 },
```

Keys must be a non-optional primitive or enum. Only added, changed and removed keys are sent.

## Arrays

`T[]`, with an optional length range: `string[..11]`. Changing or appending elements sends only those
elements. Inserting or removing in the middle (`Ripple.insert` / `Ripple.remove`) resends the array once.

## `any`

`Extra: any` accepts any table, string, number, boolean, vector or buffer. Changes are still tracked,
but values carry type tags and keys are sent in full, so keep `any` out of data that changes often.

## Type aliases

```ripple
type CardMap = map { [string]: Card }
type Percent = f32(0..1)
```

## `server` fields

Prefix a struct field with `server` to keep it on the server. It's validated and saved like any other
field and counts towards `isDirty`, but it's never sent:

```ripple
server Purchases: map { [string]: u32 },
```

## States

```ripple
state Name {
	Scope: Player | All | Manual,
	Data: <struct type>,
}
```

`Data` must be a struct (inline or named). Each state becomes `Ripple.Name` on the server and the client.

| Scope | `new` | Sent to |
|---|---|---|
| `Player` | `Ripple.Name.new(player, data)` | the owner (destroyed when they leave) |
| `All` | `Ripple.Name.new(data)` | everyone, including late joiners |
| `Manual` | `Ripple.Name.new(data, players?)` | whoever you subscribe |

## Options

| Option | Default | Effect |
|---|---|---|
| `RemoteName` | `"Ripple"` | name of the RemoteEvent created in ReplicatedStorage |
| `ServerOutput` | `<out>/Server.luau` | where the server module is written, relative to the schema. Put it in `ServerScriptService` or `ServerStorage` so clients never download it. Wins over `--out`. (0.1.1) |
| `ClientOutput` | `<out>/Client.luau` | where the client module is written, relative to the schema. Wins over `--out`. (0.1.1) |
