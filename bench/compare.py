#!/usr/bin/env python3
"""Print a markdown comparison of two benchmark result files.

    python3 compare.py [results/stock.json] results/<label>.json [--mode interp|native|both]

Ratios are baseline/candidate, so values > 1 mean the candidate is better
(faster, fewer bytes); e.g. "4.0x" = 4 times less time or memory.
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# (column title, path inside a scenario/mode result)
RUNTIME_TIME = [
    ("frame us", ("phases", "total", "us")),
    ("srv send us", ("phases", "server_send", "us")),
    ("srv step us", ("phases", "server_step", "us")),
    ("cli send us", ("phases", "client_send", "us")),
    ("recv/client us", ("phases", "client_recv_per_client", "us")),
    ("srv recv us", ("phases", "server_recv", "us")),
]

RUNTIME_MEMORY = [
    ("alloc B/frame", ("phases", "total", "alloc_bytes")),
    ("allocs/frame", ("phases", "total", "allocs")),
    ("recv B/client", ("phases", "client_recv_per_client", "alloc_bytes")),
    ("wire s2c B", ("wire", "s2c_bytes_per_frame")),
    ("wire c2s B", ("wire", "c2s_bytes_per_frame")),
]

HEAP_METRICS = [
    ("server module B", ("heap", "server_module")),
    ("client module B", ("heap", "client_module")),
    ("client state B", ("heap", "client_state")),
    ("steady growth B", ("heap", "steady_growth")),
]

STATIC_METRICS = [
    ("lines", ("source_lines",)),
    ("source B", ("source_bytes",)),
    ("bytecode B", ("bytecode_bytes",)),
    ("native code B", ("native_code_bytes",)),
]


def get(d, path):
    for k in path:
        if not isinstance(d, dict) or k not in d:
            return None
        d = d[k]
    return d


def fmt(v):
    if v is None:
        return "-"
    if abs(v) >= 1000:
        return f"{v:,.0f}"
    if abs(v) >= 10:
        return f"{v:.1f}"
    return f"{v:.2f}"


def ratio(base, cand):
    if base is None or cand is None:
        return "-"
    if cand == 0:
        return "inf" if base > 0 else "="
    return f"{base / cand:.2f}x"


def table(title, rows_header, rows):
    print(f"\n### {title}\n")
    print("| " + " | ".join(rows_header) + " |")
    print("|" + "|".join(["---"] * len(rows_header)) + "|")
    for row in rows:
        print("| " + " | ".join(row) + " |")


def compare_runtime(base, cand, mode, metrics, title):
    header = ["scenario"] + [f"{name}" for name, _ in metrics]
    rows = []
    for name, bsc in base["scenarios"].items():
        csc = cand["scenarios"].get(name, {})
        bm, cm = bsc.get(mode), csc.get(mode)
        if bm is None or cm is None or "error" in (bm or {}) or "error" in (cm or {}):
            why = csc.get("skipped") or bsc.get("skipped") or (cm or {}).get("error", "")[:60] or "n/a"
            rows.append([name] + [why.splitlines()[0] if why else "n/a"] + [""] * (len(metrics) - 1))
            continue
        row = [name]
        for _, path in metrics:
            b, c = get(bm, path), get(cm, path)
            row.append(f"{fmt(b)} → {fmt(c)} ({ratio(b, c)})")
        rows.append(row)
    # scenarios only present in the candidate (e.g. fork-only)
    for name, csc in cand["scenarios"].items():
        if name in base["scenarios"] and not base["scenarios"][name].get("skipped"):
            continue
        cm = csc.get(mode)
        if cm and "error" not in cm:
            rows.append([f"{name} (candidate only)"] + [fmt(get(cm, path)) for _, path in metrics])
    table(f"{title} — {mode}", header, rows)


def compare_static(base, cand):
    header = ["file"] + [name for name, _ in STATIC_METRICS]
    rows = []
    groups = list(base["static"]) + [g for g in cand["static"] if g not in base["static"]]
    for group in groups:
        bfiles = base["static"].get(group, {}).get("files", {})
        cfiles = cand["static"].get(group, {}).get("files", {})
        for rel in list(bfiles) + [r for r in cfiles if r not in bfiles]:
            b, c = bfiles.get(rel), cfiles.get(rel)
            row = [f"{group}/{rel}"]
            for _, path in STATIC_METRICS:
                bv, cv = get(b, path), get(c, path)
                row.append(f"{fmt(bv)} → {fmt(cv)} ({ratio(bv, cv)})")
            rows.append(row)
    table("Generated / library code size (baseline → candidate)", header, rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--mode", default="both", choices=["interp", "native", "both"])
    args = ap.parse_args()
    if len(args.files) == 1:
        base_path, cand_path = os.path.join(HERE, "results", "stock.json"), args.files[0]
    else:
        base_path, cand_path = args.files[0], args.files[1]
    with open(base_path) as f:
        base = json.load(f)
    with open(cand_path) as f:
        cand = json.load(f)

    print(f"## Networking benchmark: `{base['label']}` → `{cand['label']}`\n")
    print(f"Cells are `baseline → candidate (baseline/candidate)`; ratio > 1 means the candidate is better. "
          f"Times are µs per frame (median of {cand['config']['runs']} runs × {cand['config']['frames']} frames), "
          f"bytes are per frame unless noted. `frame us` / `alloc B/frame` sum every library phase on the server "
          f"and all clients (mock network copy excluded). Heap = live bytes after a full GC; `client module` = code + state of one client.")
    modes = ["interp", "native"] if args.mode == "both" else [args.mode]
    for mode in modes:
        compare_runtime(base, cand, mode, RUNTIME_TIME, "Time per frame")
        compare_runtime(base, cand, mode, RUNTIME_MEMORY, "Allocation and wire per frame")
    compare_runtime(base, cand, modes[0], HEAP_METRICS, "Heap (live bytes after full GC)")
    compare_static(base, cand)


if __name__ == "__main__":
    main()
