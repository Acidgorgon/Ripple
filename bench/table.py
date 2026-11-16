#!/usr/bin/env python3
"""Quick table: python3 table.py [mode] label1 label2 ... (reads results/<label>.json)."""
import json, sys
mode = "native"
labels = sys.argv[1:]
if labels and labels[0] in ("native", "interp"):
    mode, labels = labels[0], labels[1:]
data = {l: json.load(open(f"results/{l}.json")) for l in labels}
scen = list(next(iter(data.values()))["scenarios"].keys())
print(f"| scenario | lib | total µs | server µs | client µs (all) | alloc B/f | wire B/f | calls/f |")
print("|---|---|---|---|---|---|---|---|")
for s in scen:
    for l in labels:
        sc = data[l]["scenarios"].get(s, {})
        r = sc.get(mode) or {}
        if not r or "phases" not in r:
            print(f"| {s} | {l} | {sc.get('error','-')[:40] if isinstance(sc.get('error'),str) else 'n/a'} |")
            continue
        ph = r["phases"]
        srv = ph["server_send"]["us"] + ph["server_step"]["us"] + ph["server_recv"]["us"]
        cli = ph["client_send"]["us"] + ph["client_step"]["us"] + ph["client_recv"]["us"]
        w = r["wire"]
        print(f"| {s} | {l} | {ph['total']['us']:.1f} | {srv:.1f} | {cli:.1f} | {ph['total']['alloc_bytes']:.0f} | {w['s2c_bytes_per_frame']:.0f} | {w['s2c_calls_per_frame']:.1f} |")
