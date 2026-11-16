#!/usr/bin/env bash
# Reflex build step.
#   adapters/reflex/build.sh <reflexRepoDir> <outDir>
#
# <reflexRepoDir> is a checkout of github.com/littensy/reflex. Its only dependency, evaera/promise
# (wally.lock: 4.0.0), is read from $PROMISE_DIR (default: <reflexRepoDir>/../promise, a checkout
# of github.com/evaera/roblox-lua-promise at v4.0.0). Sources are copied unchanged (tests and
# typings left out) in the Wally layout:
#   <outDir>/_shared/reflex/reflex/...   (src/)
#   <outDir>/_shared/reflex/Promise.lua  (lib/init.lua)
# so reflex's Promise.lua finds `script.Parent.Parent.Promise` as Wally's _Index link would.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$1" && pwd)"
PROMISE_DIR="${PROMISE_DIR:-$SRC/../promise}"
OUT_DIR="$2"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

LIB="$OUT_DIR/_shared/reflex"
rm -rf "$LIB"
mkdir -p "$LIB"
cp -r "$SRC/src" "$LIB/reflex"
find "$LIB/reflex" \( -name '*.spec.lua' -o -name '*.d.ts' \) -delete
find "$LIB/reflex" -depth -type d -name '*.spec' -exec rm -rf {} \;
PROMISE_OK=1
cp "$PROMISE_DIR/lib/init.lua" "$LIB/Promise.lua" || PROMISE_OK=0

for src in "$HERE"/modules/*/; do
	name="$(basename "$src")"
	dir="$OUT_DIR/$name"
	rm -rf "$dir"
	mkdir -p "$dir"
	if [ "$PROMISE_OK" = 1 ] && cp "$src"/*.luau "$dir/" > "$dir/compile.log" 2>&1; then
		touch "$dir/ok"
		echo "copied    $name"
	else
		echo "missing Promise at $PROMISE_DIR/lib/init.lua" >> "$dir/compile.log"
		touch "$dir/failed"
		echo "FAILED    $name (see $dir/compile.log)"
	fi
done
