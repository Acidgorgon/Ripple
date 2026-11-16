#!/usr/bin/env bash
# loleris' ReplicaService (github.com/MadStudioRoblox/ReplicaService) build step.
#   adapters/replicaservice/build.sh <sourceDir> <outDir>
#
# <sourceDir> is a checkout of the ReplicaService repo. Nothing is compiled: the library's
# src/ReplicatedStorage and src/ServerScriptService trees are copied to <outDir>/_shared/replicaservice/
# (adapter.luau mounts them into the mock DataModel where the Rojo project puts them), and the
# hand-written per-schema modules are copied to <outDir>/<schema>/.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$1"
OUT_DIR="$2"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

LIB="$OUT_DIR/_shared/replicaservice"
rm -rf "$LIB"
mkdir -p "$LIB"
lib_ok=1
cp -R "$SRC/src/ReplicatedStorage" "$SRC/src/ServerScriptService" "$LIB/" || lib_ok=0
(cd "$SRC" && git rev-parse HEAD 2>/dev/null) > "$LIB/VERSION" || true

for src in "$HERE"/modules/*/; do
	name="$(basename "$src")"
	dir="$OUT_DIR/$name"
	rm -rf "$dir"
	mkdir -p "$dir"
	if [ "$lib_ok" = 1 ] && cp "$src/server.luau" "$src/client.luau" "$dir/" > "$dir/compile.log" 2>&1; then
		touch "$dir/ok"
		echo "copied    $name"
	else
		echo "library copy failed" >> "$dir/compile.log"
		touch "$dir/failed"
		echo "FAILED    $name (see $dir/compile.log)"
	fi
done
