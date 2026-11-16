# Ripple benchmark harness

Compares Ripple with Replica, ReplicaService, DataService, Reflex (+ broadcaster), Charm + charm-sync and a
full-snapshot baseline on the same workloads. Results: [RESULTS.md](RESULTS.md).

- `host/`: a small Luau 0.700 host (`luau-bench`) with native codegen, allocation counters and a GC hook.
  Build: `cmake -S host -B host/build -DCMAKE_BUILD_TYPE=Release && cmake --build host/build`.
- `lib/mock.luau`: a Roblox mock (Players, RemoteEvents, RunService, Instances) with 50 clients. Remote
  arguments are copied the way Roblox does: buffers at fire time, tables at delivery.
- `scenarios/`: `club_tick`, `club_churn`, `club_join`, `match_shared` (see each file's header).
- `adapters/<library>/`: one folder per library: `build.sh <librarySource> <outDir>` plus thin
  `modules/<schema>/{server,client}.luau` implementing the scenario contract.

The third-party libraries are not vendored. Clone each one and pass its folder:

```sh
python3 bench/run.py \
  --variant ripple=ripple:. \
  --variant replicaservice=replicaservice:path/to/ReplicaService \
  --variant replica=replica:path/to/Replica \
  --variant dataservice=dataservice:path/to/dataservice \
  --variant reflex=reflex:path/to/reflex \
  --variant charm=charm:path/to/charm \
  --variant snapshot=snapshot:bench \
  --runs 7 --frames 300 --warmup 60 --modes native
python3 bench/make_results.py   # RESULTS.md + docs/benchmarks.md
python3 bench/engine_table.py   # quick table with the engine-cost estimate
```

`lune` and the host tools are looked up in `$BENCH_TOOLS` (default `bench/tools/`).

The engine-cost estimate comes from a Studio calibration: `calibrate_server.luau` / `calibrate_client.luau`
in an empty baseplate (see RESULTS.md).
