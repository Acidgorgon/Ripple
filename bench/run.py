#!/usr/bin/env python3
"""Networking-library benchmark + correctness runner.

Single variant (default adapter: blink):
    python3 run.py <sourceDir> <label> [--adapter blink] [options]

Several variants, runs interleaved A,B,A,B,... so machine drift hits all of
them equally (recommended for comparisons):
    python3 run.py --variant stock=blink:/path/to/blink-stock \\
                   --variant plus=blink:/path/to/blink [options]

Options: --runs N (default 7)  --frames F (default 600, scaled per scenario by
frames_scale in scenarios/manifest.json)  --warmup W (default 120)
--scenarios a,b  --modes interp,native  --cpu N (taskset pin, -1 = off)

For every variant:
1. Build: adapters/<adapter>/build.sh <sourceDir> gen/<label> must leave
   gen/<label>/<schema>/ok (or `failed` + compile.log) for every schema it
   provides. Library code shared by all schemas may go in gen/<label>/_shared.
2. Static metrics for every .luau file under gen/<label>/<schema>/ and
   gen/<label>/_shared/: source bytes/lines, bytecode size
   (luau-compile --binary -O2, Roblox vector settings), native code size and
   compiled-chunk heap (luau-bench --codegen).
3. Every scenario runs in a fresh luau-bench process per (mode, run):
   interp = -O2 bytecode interpreter, native = -O2 --codegen. Each run checks
   received == sent and aborts on mismatch.
4. results/<label>.json gets, per scenario and mode, the MEDIAN over runs of
   every metric, min/max of phase timings, and any errors/skips.
"""

import argparse
import datetime
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Directory holding lune / luau-compile; anything on PATH is used as a fallback.
TOOLS = os.environ.get("BENCH_TOOLS", os.path.join(HERE, "tools"))
LUAU_BENCH = os.path.join(HERE, "host", "build", "luau-bench")
LUAU_COMPILE = (os.path.join(TOOLS, "luau-compile") if os.path.exists(os.path.join(TOOLS, "luau-compile"))
                else shutil.which("luau-compile") or "luau-compile")
VECTOR_FLAGS = ["--vector-lib=Vector3", "--vector-ctor=new", "--vector-type=Vector3"]
MODES = {"interp": ["-O2"], "native": ["-O2", "--codegen"]}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def tail(path, n=40):
    try:
        with open(path, errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except OSError:
        return ""


def ensure_host():
    if os.path.exists(LUAU_BENCH):
        return
    log("building luau-bench host ...")
    build = os.path.join(HERE, "host", "build")
    subprocess.check_call(["cmake", "-S", os.path.join(HERE, "host"), "-B", build, "-DCMAKE_BUILD_TYPE=Release"])
    subprocess.check_call(["cmake", "--build", build, "-j4"])


class Variant:
    def __init__(self, label, adapter, source):
        self.label, self.adapter, self.source = label, adapter, os.path.abspath(source)
        self.out_dir = os.path.join(HERE, "gen", label)
        self.static = {}
        self.results = {}

    def build(self):
        script = os.path.join(HERE, "adapters", self.adapter, "build.sh")
        if not os.path.exists(script):
            raise SystemExit(f"unknown adapter {self.adapter!r}: {script} not found")
        log(f"== building {self.label} ({self.adapter} from {self.source})")
        subprocess.check_call([script, self.source, self.out_dir], stdout=sys.stderr)

    def schema_ok(self, schema):
        return os.path.exists(os.path.join(self.out_dir, schema, "ok"))

    def collect_static(self, schemas):
        files = []
        for group in list(schemas) + ["_shared"]:
            d = os.path.join(self.out_dir, group)
            if not os.path.isdir(d):
                continue
            if group != "_shared" and not self.schema_ok(group):
                self.static[group] = {"build_ok": False, "build_log": tail(os.path.join(d, "compile.log"))}
                continue
            entry = {"build_ok": True, "files": {}}
            for root, _, names in os.walk(d):
                for name in sorted(names):
                    if not name.endswith((".luau", ".lua")):
                        continue
                    path = os.path.join(root, name)
                    rel = os.path.relpath(path, d)
                    with open(path, "rb") as f:
                        src = f.read()
                    bc = subprocess.run([LUAU_COMPILE, "--binary", "-O2", *VECTOR_FLAGS, path], capture_output=True)
                    entry["files"][rel] = {
                        "source_bytes": len(src),
                        "source_lines": src.count(b"\n"),
                        "bytecode_bytes": len(bc.stdout) if bc.returncode == 0 else None,
                    }
                    files.append((group, rel, path))
            self.static[group] = entry
        if files:
            res = subprocess.run(
                [LUAU_BENCH, "-O2", "--codegen", os.path.join(HERE, "lib", "static_metrics.luau"), HERE]
                + [p for _, _, p in files],
                capture_output=True, text=True)
            if res.returncode == 0:
                native = json.loads(res.stdout.strip().splitlines()[-1])
                for group, rel, path in files:
                    self.static[group]["files"][rel].update(native[path])
            else:
                log("static_metrics.luau failed:\n" + res.stderr)


def run_once(variant, mode, scenario, frames, warmup, cpu):
    pin = ["taskset", "-c", str(cpu)] if cpu is not None and shutil.which("taskset") else []
    cmd = [*pin, LUAU_BENCH, *MODES[mode], os.path.join(HERE, "lib", "run_scenario.luau"),
           HERE, variant.adapter, scenario, variant.out_dir, str(frames), str(warmup)]
    res = subprocess.run(cmd, capture_output=True, text=True)
    last = res.stdout.strip().splitlines()[-1] if res.stdout.strip() else ""
    data = None
    if last.startswith("{"):
        try:
            data = json.loads(last)
        except json.JSONDecodeError:
            data = None
    if data is not None and "skipped" in data:
        return None, None, data["skipped"]
    if res.returncode != 0 or data is None:
        return None, (res.stderr or res.stdout)[-4000:], None
    return data, None, None


def median_tree(runs):
    """Element-wise median over a list of equally shaped JSON trees."""
    first = runs[0]
    if isinstance(first, dict):
        return {k: median_tree([r[k] for r in runs if k in r]) for k in first}
    if isinstance(first, bool) or not isinstance(first, (int, float)):
        return first
    return statistics.median(runs)


def summarize(runs):
    med = median_tree(runs)
    med["spread"] = {
        phase: [min(r["phases"][phase]["us"] for r in runs), max(r["phases"][phase]["us"] for r in runs)]
        for phase in runs[0]["phases"] if isinstance(runs[0]["phases"][phase], dict)
    }
    med["runs"] = len(runs)
    return med


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", nargs="?")
    ap.add_argument("label", nargs="?")
    ap.add_argument("--adapter", default="blink")
    ap.add_argument("--variant", action="append", default=[], metavar="LABEL=ADAPTER:SOURCE")
    ap.add_argument("--runs", type=int, default=7)
    ap.add_argument("--frames", type=int, default=600)
    ap.add_argument("--warmup", type=int, default=120)
    ap.add_argument("--scenarios", default="")
    ap.add_argument("--modes", default="interp,native")
    ap.add_argument("--cpu", type=int, default=(os.cpu_count() or 1) - 1,
                    help="pin benchmark processes to this CPU with taskset (-1 to disable)")
    args = ap.parse_args()

    variants = []
    if args.source and args.label:
        variants.append(Variant(args.label, args.adapter, args.source))
    for spec in args.variant:
        label, rest = spec.split("=", 1)
        adapter, source = rest.split(":", 1)
        variants.append(Variant(label, adapter, source))
    if not variants:
        ap.error("give <sourceDir> <label> or at least one --variant")

    ensure_host()
    with open(os.path.join(HERE, "scenarios", "manifest.json")) as f:
        manifest = json.load(f)["scenarios"]
    if args.scenarios:
        wanted = set(args.scenarios.split(","))
        manifest = [s for s in manifest if s["name"] in wanted]
    modes = args.modes.split(",")
    cpu = None if args.cpu < 0 else args.cpu

    schemas = sorted({s["schema"] for s in manifest})
    for v in variants:
        v.build()
        v.collect_static(schemas)

    failures = 0
    for sc in manifest:
        name, schema = sc["name"], sc["schema"]
        frames = args.frames * sc.get("frames_scale", 1)
        active = []
        for v in variants:
            entry = {"schema": schema, "fork_only": sc["fork_only"], "desc": sc["desc"], "frames": frames}
            v.results[name] = entry
            if not v.schema_ok(schema):
                if sc["fork_only"]:
                    entry["skipped"] = f"schema {schema} not built by this variant (fork-only feature)"
                    log(f"skip      {v.label:10s} {name}: fork-only schema not built")
                else:
                    entry["error"] = f"schema {schema} failed to build"
                    failures += 1
                    log(f"ERROR     {v.label:10s} {name}: schema failed to build")
                continue
            active.append(v)
        for mode in modes:
            runs = {v.label: [] for v in active}
            dead = {}
            for _ in range(args.runs):
                for v in active:  # interleave variants run by run
                    if v.label in dead:
                        continue
                    data, err, skipped = run_once(v, mode, name, frames, args.warmup, cpu)
                    if skipped:
                        dead[v.label] = ("skipped", skipped)
                    elif err:
                        dead[v.label] = ("error", err)  # deterministic: do not repeat
                    else:
                        runs[v.label].append(data)
            for v in active:
                entry = v.results[name]
                if v.label in dead:
                    kind, msg = dead[v.label]
                    if kind == "skipped":
                        entry["skipped"] = msg
                        log(f"skip      {v.label:10s} {name} [{mode}]: {msg}")
                    else:
                        failures += 1
                        entry[mode] = {"error": msg}
                        log(f"ERROR     {v.label:10s} {name} [{mode}]:\n{msg}")
                    continue
                med = summarize(runs[v.label])
                entry[mode] = med
                p = med["phases"]
                log(f"ok        {v.label:10s} {name:24s} [{mode:6s}] {p['total']['us']:9.1f} us/frame, "
                    f"{p['total']['alloc_bytes']:10.0f} B/frame, recv/client {p['client_recv_per_client']['us']:7.2f} us")

    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    for v in variants:
        out = {
            "label": v.label,
            "adapter": v.adapter,
            "source": v.source,
            "date": datetime.datetime.now().isoformat(timespec="seconds"),
            "host": {"machine": platform.machine(), "cpus": os.cpu_count(), "luau": "0.700 (luau-bench)"},
            "config": {"runs": args.runs, "frames": args.frames, "warmup": args.warmup, "modes": modes,
                       "interleaved_with": [o.label for o in variants if o is not v]},
            "static": v.static,
            "scenarios": v.results,
        }
        path = os.path.join(HERE, "results", f"{v.label}.json")
        with open(path, "w") as f:
            json.dump(out, f, indent=1, sort_keys=True)
        log(f"wrote {path}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
