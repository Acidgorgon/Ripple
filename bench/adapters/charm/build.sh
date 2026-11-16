#!/usr/bin/env bash
# Charm + Charm Sync build step.
#   adapters/charm/build.sh <charmRepoDir> <outDir>
#
# <charmRepoDir> is a checkout of github.com/littensy/charm (monorepo: packages/charm,
# packages/charm-sync). The library sources are copied unchanged to <outDir>/_shared/charm/packages/
# in the repo layout (charm-sync's Charm.luau link resolves `script.Parent.Parent.charm.src`, which
# the adapter mounts as an Instance tree). The per-schema modules are copied to <outDir>/<schema>/.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$1" && pwd)"
OUT_DIR="$2"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

LIB="$OUT_DIR/_shared/charm/packages"
rm -rf "$OUT_DIR/_shared/charm"
mkdir -p "$LIB/charm" "$LIB/charm-sync"
cp -r "$SRC/packages/charm/src" "$LIB/charm/src"
cp -r "$SRC/packages/charm-sync/src" "$LIB/charm-sync/src"
cp "$SRC/packages/charm-sync/Charm.luau" "$LIB/charm-sync/Charm.luau"
find "$LIB" -name '*.d.ts' -delete

for src in "$HERE"/modules/*/; do
	name="$(basename "$src")"
	dir="$OUT_DIR/$name"
	rm -rf "$dir"
	mkdir -p "$dir"
	if cp "$src"/*.luau "$dir/" > "$dir/compile.log" 2>&1; then
		touch "$dir/ok"
		echo "copied    $name"
	else
		touch "$dir/failed"
		echo "FAILED    $name (see $dir/compile.log)"
	fi
done
