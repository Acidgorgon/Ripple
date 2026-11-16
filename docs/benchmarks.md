# Benchmarks

Measured 2026-11-16 with the harness in `bench/` (Luau 0.700, native codegen, -O2, a Roblox mock with
50 clients; median of 7 interleaved runs, 300 frames each). Libraries: Replica 9cae236, ReplicaService aaeb1c6,
DataService e0b5783 (+ Networker), Reflex 935f3e4 (+ broadcaster), Charm 0.11.1 + charm-sync 0.4.1. Every run checks that every
client's state matches the server's exactly.

## The cost you don't see: Roblox serializing tables

Most libraries pass Luau tables to `FireClient`. Roblox serializes them in C++, so the cost never shows in
the script profiler, and the mock harness can't time it either. We measured it in Studio (Ryzen 7 7700X,
Play Solo, empty baseplate, two runs):

| Sent with one `FireClient` | Engine cost |
|---|---:|
| 300-card club table | 290 to 340 µs |
| one card table | 4.6 to 4.8 µs |
| path set `(1, {"Cash"}, n)` | 2.8 µs |
| single number | 2.3 µs |
| 24 B buffer | 2.8 to 2.9 µs |
| 4,550 B buffer (the whole 300-card club) | 3.6 to 3.9 µs |
| 22-player match table, `FireAllClients` | 19 to 22 µs |

A call costs about 2.3 µs plus roughly 2.3x what a Luau deep copy of its arguments costs (the club table's
deep copy took 116 to 142 µs). A buffer costs about 3 µs whatever its size. The tables below add that
estimate to each library's server time: `fires × 2.3 µs + 2.3 × (time to copy each fired value once)`.
The engine's client-side deserialization isn't counted at all, which flatters the table-based libraries.

## Cash tick

50 players, each owning a private 300-card club. Once a second (every 30th frame) every player's Cash changes on the same frame, like a coin loop. Rarely: a stat change, a pack, a level-up or a sale.

| Library | Server µs/frame (Luau + est. engine send) | Server Luau µs | Client Luau µs (all 50) | Bytes sent / frame | Luau alloc B/frame |
|---|---:|---:|---:|---:|---:|
| Replica | 19 | 5.5 | 37.3 | 54 | 137 |
| ReplicaService | 20 | 6.0 | 34.3 | 54 | 132 |
| DataService | 22 | 9.2 | 39.4 | 54 | 144 |
| **Ripple** | 23 | 11.9 | 35.4 | 28 | 98 |
| Reflex | 113 | 53.2 | 53.2 | 119 | 36,851 |
| Charm + charm-sync | 134 | 117.4 | 48.2 | 108 | 38,692 |
| Full snapshot (baseline) | 1952 | 5.8 | 36.7 | 51,397 | 24 |

## Inventory churn

The same clubs with heavy inventory traffic. Per player: a pack of 5 new cards every 10 frames, a card level-up and a stat change every 5, a card sale every 15, plus the Cash tick.

| Library | Server µs/frame (Luau + est. engine send) | Server Luau µs | Client Luau µs (all 50) | Bytes sent / frame | Luau alloc B/frame |
|---|---:|---:|---:|---:|---:|
| **Ripple** | 202 | 114.1 | 99.1 | 794 | 15,234 |
| ReplicaService | 339 | 50.1 | 78.9 | 3,509 | 4,123 |
| Replica | 352 | 51.1 | 133.6 | 3,509 | 5,652 |
| DataService | 419 | 110.3 | 144.3 | 3,509 | 6,392 |
| Reflex | 1632 | 1194.3 | 418.6 | 4,485 | 2,043,680 |
| Charm + charm-sync | 2988 | 2522.1 | 359.7 | 3,773 | 1,470,492 |
| Full snapshot (baseline) | 25951 | 39.2 | 76.6 | 756,598 | 287 |

## Joins

One player per frame rejoins: their club is destroyed and created again from a full 300-card table, which must reach them in full.

| Library | Server µs/frame (Luau + est. engine send) | Server Luau µs | Client Luau µs (all 50) | Bytes sent / frame | Luau alloc B/frame |
|---|---:|---:|---:|---:|---:|
| **Ripple** | 147 | 126.3 | 223.6 | 4,835 | 139,218 |
| Replica | 871 | 17.3 | 61.3 | 26,557 | 4,404 |
| DataService | 900 | 30.9 | 61.5 | 26,514 | 11,809 |
| ReplicaService | 927 | 16.8 | 62.2 | 26,555 | 4,635 |
| Charm + charm-sync | 1079 | 191.9 | 62.0 | 26,584 | 44,050 |
| Reflex | 1139 | 98.1 | 80.2 | 26,712 | 55,699 |
| Full snapshot (baseline) | 2319 | 8.7 | 37.9 | 69,685 | 248 |

## Shared match

One match state shared by all 50 players (scoreboard + 22 match players). Every frame the clock moves and 4 stamina values change; every 90 frames the score and phase change.

| Library | Server µs/frame (Luau + est. engine send) | Server Luau µs | Client Luau µs (all 50) | Bytes sent / frame | Luau alloc B/frame |
|---|---:|---:|---:|---:|---:|
| **Ripple** | 13 | 8.9 | 80.9 | 2,051 | 159 |
| Full snapshot (baseline) | 36 | 3.7 | 36.9 | 44,900 | 0 |
| Charm + charm-sync | 572 | 96.1 | 246.4 | 7,352 | 238,801 |
| Reflex | 717 | 78.1 | 326.3 | 12,352 | 391,418 |
| ReplicaService | 1024 | 28.9 | 98.4 | 10,797 | 451 |
| Replica | 1040 | 29.4 | 185.9 | 10,797 | 451 |
| DataService | 1398 | 308.8 | 355.1 | 12,564 | 31,930 |

## Reading the results

- **Server time** (first column) is what matters for the server frame budget. Ripple is lowest in every
  scenario except the Cash tick, ahead of the next library by 1.7x in inventory churn, 5.9x on joins and
  43x in the shared match, and it sends 2 to 6 times fewer bytes than any of them.
- **Cash tick** is a near tie: every library makes one remote call per player per second, and that fixed
  call cost dominates. Ripple spends about 4 µs per frame more in Luau (it batches into buffers on Heartbeat)
  and sends half the bytes.
- **Joins**: Ripple does more Luau work than the path libraries (it encodes the 300 cards itself, and the
  client decodes them), but skips the ~300 µs Roblox spends serializing the same table, and sends 5x fewer
  bytes. The client-side Luau decode (~0.2 ms per join) replaces Roblox's own table deserialization,
  which the mock doesn't measure.
- **Full snapshot** is the do-nothing baseline: cheap in Luau, but 45 KB to 750 KB per frame on the wire and
  milliseconds of engine time.

Reproduce with `python3 bench/run.py --variant ripple=ripple:. --variant replicaservice=replicaservice:<src> ...`
and `python3 bench/make_results.py`.
