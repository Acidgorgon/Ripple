#!/usr/bin/env bash
# Ripple adapter build step.
#   adapters/ripple/build.sh <rippleRepoDir> <outDir>
# Compiles schemas/<schema>.ripple with that repo's compiler into <outDir>/<schema>/{Server,Client}.luau
# and copies the contract modules next to them.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$1" && pwd)"
OUT_DIR="$2"
LUNE="${BENCH_TOOLS:-$HERE/../../tools}/lune"
[ -x "$LUNE" ] || LUNE=lune
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
for schema in "$HERE"/schemas/*.ripple; do
	name="$(basename "$schema" .ripple)"
	dir="$OUT_DIR/$name"
	rm -rf "$dir"
	mkdir -p "$dir"
	if (cd "$SRC" && "$LUNE" run src/init.luau -- "$schema" --out "$dir") > "$dir/compile.log" 2>&1 \
		&& cp "$HERE/modules/$name/server.luau" "$HERE/modules/$name/client.luau" "$dir/"; then
		touch "$dir/ok"
		echo "compiled  $name"
	else
		touch "$dir/failed"
		echo "FAILED    $name (see $dir/compile.log)"
	fi
done
