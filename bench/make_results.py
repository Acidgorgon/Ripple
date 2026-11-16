#!/usr/bin/env python3
"""Writes bench/RESULTS.md and docs/benchmarks.md from results/*.json (see engine_table.py for the model)."""
import json, datetime, os
HERE = os.path.dirname(os.path.abspath(__file__))
BASE, K = 2.3, 2.3
LIBS = [("ripple", "Ripple"), ("replicaservice", "ReplicaService"), ("replica", "Replica"),
        ("dataservice", "DataService"), ("reflex", "Reflex"), ("charm", "Charm + charm-sync"),
        ("snapshot", "Full snapshot (baseline)")]
SCEN = {
    "club_tick": ("Cash tick", "50 players, each owning a private 300-card club. Once a second (every 30th frame) every player's Cash changes on the same frame, like a coin loop. Rarely: a stat change, a pack, a level-up or a sale."),
    "club_churn": ("Inventory churn", "The same clubs with heavy inventory traffic. Per player: a pack of 5 new cards every 10 frames, a card level-up and a stat change every 5, a card sale every 15, plus the Cash tick."),
    "club_join": ("Joins", "One player per frame rejoins: their club is destroyed and created again from a full 300-card table, which must reach them in full."),
    "match_shared": ("Shared match", "One match state shared by all 50 players (scoreboard + 22 match players). Every frame the clock moves and 4 stamina values change; every 90 frames the score and phase change."),
}
data = {l: json.load(open(os.path.join(HERE, "results", f"{l}.json"))) for l, _ in LIBS}
cfg = data["ripple"]["config"]

def rows(s):
    out = []
    for l, name in LIBS:
        r = data[l]["scenarios"][s]["native"]
        ph, w = r["phases"], r["wire"]
        srv = ph["server_send"]["us"] + ph["server_step"]["us"] + ph["server_recv"]["us"]
        cli = ph["client_recv"]["us"] + ph["client_step"]["us"]
        eng = w["s2c_fires_per_frame"] * BASE + K * w["s2c_fire_copy_us_per_frame"]
        out.append(dict(l=l, name=name, srv=srv, eng=eng, tot=srv + eng, cli=cli,
                        wire=w["s2c_bytes_per_frame"], alloc=ph["total"]["alloc_bytes"],
                        heap=r["heap"]["steady"] / 1e6))
    return sorted(out, key=lambda x: x["tot"])

def table(s):
    lines = ["| Library | Server µs/frame (Luau + est. engine send) | Server Luau µs | Client Luau µs (all 50) | Bytes sent / frame | Luau alloc B/frame |",
             "|---|---:|---:|---:|---:|---:|"]
    for x in rows(s):
        n = f"**{x['name']}**" if x["l"] == "ripple" else x["name"]
        lines.append(f"| {n} | {x['tot']:.0f} | {x['srv']:.1f} | {x['cli']:.1f} | {x['wire']:,.0f} | {x['alloc']:,.0f} |")
    return "\n".join(lines)

def body(link_prefix):
    parts = []
    parts.append(f"""Measured {datetime.date.today().isoformat()} with the harness in `bench/` (Luau 0.700, native codegen, -O2, a Roblox mock with
50 clients; median of {cfg['runs']} interleaved runs, {cfg['frames']} frames each). Libraries: Replica 9cae236, ReplicaService aaeb1c6,
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
| path set `(1, {{"Cash"}}, n)` | 2.8 µs |
| single number | 2.3 µs |
| 24 B buffer | 2.8 to 2.9 µs |
| 4,550 B buffer (the whole 300-card club) | 3.6 to 3.9 µs |
| 22-player match table, `FireAllClients` | 19 to 22 µs |

A call costs about 2.3 µs plus roughly 2.3x what a Luau deep copy of its arguments costs (the club table's
deep copy took 116 to 142 µs). A buffer costs about 3 µs whatever its size. The tables below add that
estimate to each library's server time: `fires × 2.3 µs + 2.3 × (time to copy each fired value once)`.
The engine's client-side deserialization isn't counted at all, which flatters the table-based libraries.
""")
    for s, (title, desc) in SCEN.items():
        parts.append(f"## {title}\n\n{desc}\n\n{table(s)}\n")
    parts.append("""## Reading the results

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
""")
    return "\n".join(parts)

open(os.path.join(HERE, "RESULTS.md"), "w").write("# Ripple benchmark results\n\n" + body(""))
open(os.path.join(HERE, "..", "docs", "benchmarks.md"), "w").write("# Benchmarks\n\n" + body("/"))
print("wrote RESULTS.md and docs/benchmarks.md")
