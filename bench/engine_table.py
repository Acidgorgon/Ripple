#!/usr/bin/env python3
"""Comparison table with a Roblox engine-cost estimate.

Studio calibration (Ryzen 7 7700X, Play Solo, see RESULTS.md): a FireClient costs ~2.3 us plus Roblox's C++
serialization of the arguments, which measured ~2.3x a Luau deep copy of the same table (club table: 290 us
per FireClient vs 126 us deep copy); a buffer of any size costs ~3 us. The mock copies each fired record once
per recipient; s2c_fire_copy_us times ONE copy per server-side Fire, so
    engine_us ~= fires * 2.3 + 2.3 * fire_copy_us
Client-side deserialization in the engine is not modelled (it favours the table libraries)."""
import json, sys
BASE, K = 2.3, 2.3
libs = sys.argv[1:] or ['ripple', 'replicaservice', 'replica', 'dataservice', 'reflex', 'charm', 'snapshot']
data = {l: json.load(open(f"results/{l}.json")) for l in libs}
scen = list(data[libs[0]]["scenarios"].keys())
print("| scenario | library | server Luau µs | + engine send µs (est.) | = server µs | client Luau µs | wire B/frame | alloc B/frame |")
print("|---|---|---:|---:|---:|---:|---:|---:|")
for s in scen:
    rows = []
    for l in libs:
        r = data[l]["scenarios"][s]["native"]
        ph, w = r["phases"], r["wire"]
        srv = ph["server_send"]["us"] + ph["server_step"]["us"] + ph["server_recv"]["us"]
        cli = ph["client_recv"]["us"] + ph["client_step"]["us"]
        eng = w["s2c_fires_per_frame"] * BASE + K * w["s2c_fire_copy_us_per_frame"]
        rows.append((srv + eng, l, srv, eng, cli, w["s2c_bytes_per_frame"], ph["total"]["alloc_bytes"]))
    for tot, l, srv, eng, cli, wire, alloc in sorted(rows):
        name = f"**{l}**" if l == "ripple" else l
        print(f"| {s} | {name} | {srv:.1f} | {eng:.1f} | {tot:.1f} | {cli:.1f} | {wire:,.0f} | {alloc:,.0f} |")
