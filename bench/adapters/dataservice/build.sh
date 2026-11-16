#!/usr/bin/env bash
# Dataservice (leifstout/dataservice@1.0.0) build step.
#   adapters/dataservice/build.sh <sourceDir> <outDir>
#
# <sourceDir> holds the cloned sources:
#   dataservice/  github.com/leifstout/dataservice  (wally 1.0.0, commit e0b5783)
#   networker/    github.com/leifstout/networker    (wally 0.3.1, commit 5dfa444)
#   rbxutil/      github.com/Sleitnick/RbxUtil      (modules/signal = sleitnick/signal@2.0.3, commit c6bf817)
# They are copied unchanged into a Wally-style Packages folder at <outDir>/_shared/Packages:
#   DataService/ Networker/ Signal/ ProfileStore.luau
# ProfileStore is NOT the real lm-loleris/profilestore: it is this adapter's in-memory fake
# (shims/ProfileStore.luau), since saving is out of scope. Janitor is listed in wally.toml
# but never required by the sources, so it is not copied.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$1"
OUT_DIR="$2"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
PKG="$OUT_DIR/_shared/Packages"
rm -rf "$OUT_DIR/_shared"
mkdir -p "$PKG/Signal"
cp -r "$SRC/dataservice/src" "$PKG/DataService"
cp -r "$SRC/networker/src" "$PKG/Networker"
cp "$SRC/rbxutil/modules/signal/init.luau" "$PKG/Signal/init.luau"
cp "$HERE/shims/ProfileStore.luau" "$PKG/ProfileStore.luau"

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
