# Wire format

You never need this to use Ripple. It's here so you can see exactly what goes over the network, and for
anyone writing tools around it.

## One buffer per player per frame

Each flush sends each player at most one buffer: their private ops followed by the shared stream (ops for
`Scope: All` states). If no player has private data that frame, the shared stream goes out once with
`FireAllClients`.

A buffer is a sequence of ops. Every op starts with a 1-byte op code and the entity id as a varint.

| Op | Code | Body |
|---|---|---|
| CREATE | 1 | state index (u8), owner UserId (f64, `Player` scope only), full value |
| PATCH | 2 | patch of the root struct |
| DESTROY | 3 | nothing |
| BPATCH | 4 | length (varint), patch: a shared-stream patch, skippable by clients that don't hold the entity yet |

## Values

| Type | Encoding |
|---|---|
| `u8`…`i32`, `f32`, `f64` | little-endian, fixed size |
| `uint` | varint (7 bits per byte, high bit = more) |
| `int` | zigzag, then varint |
| `boolean` | 1 byte |
| `string`, `buffer` | varint length + bytes |
| `vector` | 3 × f32 |
| enum | 1 byte (index) |
| optional | 1 byte present flag, then the value |
| struct (full) | each replicated field in schema order, no names, no tags |
| map (full) | varint count, then key, value pairs |
| array (full) | varint count, then values |
| `any` | 1 type tag byte, then the value; tables are count + tagged key/value pairs |

Structs whose fields are all fixed-size (like a card: `u16, u8, u8, u8, boolean`) are written as one
fixed-size block, 6 bytes for that card.

## Patches

**Struct patch:** a change mask, then only the changed fields.

- up to 8 fields: 1-byte mask; up to 16: 2-byte mask
- more fields: a count byte and the changed field indexes, or `255` and a full mask, whichever is smaller
- table-typed fields carry a tag: `0` now nil, `1` full value follows, `2` nested patch follows

**Map patch:** varint count of changed keys, then for each: key, tag (`0` removed, `1` full value,
`2` nested patch).

**Array patch:** a tag byte: `1` the whole array follows (after an insert or remove in the middle), or `0`
followed by a keyed patch by index, like a map.

## Example: one Cash change

`club.Cash = 1250` on the `Club` from [Getting started](/guide/getting-started), sent to its owner:

```
02          PATCH
05          entity id 5
01          mask: field 1 (Cash) changed (Club has 5 fields, so 1 byte)
00 00 00 00 00 88 93 40   Cash = 1250 (f64)
```

11 bytes, as one buffer through one `FireClient`. The same change through a path-based table library sends
the op name or code, a path table `{"Cash"}`, and the value, all serialized by Roblox as tagged values.
