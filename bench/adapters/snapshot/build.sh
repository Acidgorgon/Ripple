#!/usr/bin/env bash
# Full-snapshot baseline build step.
#   adapters/remotes/build.sh <sourceDir> <outDir>
#
# There is nothing to compile: <sourceDir> is ignored (pass `-`). The hand-written
# per-schema modules in adapters/remotes/modules/<schema>/{server,client}.luau
# are copied to <outDir>/<schema>/ (so static metrics cover them) and each
# schema dir is marked `ok`.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$2"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

for src in "$HERE"/modules/*/; do
	name="$(basename "$src")"
	dir="$OUT_DIR/$name"
	rm -rf "$dir"
	mkdir -p "$dir"
	if cp "$src/server.luau" "$src/client.luau" "$dir/" > "$dir/compile.log" 2>&1; then
		touch "$dir/ok"
		echo "copied    $name"
	else
		touch "$dir/failed"
		echo "FAILED    $name (see $dir/compile.log)"
	fi
done
