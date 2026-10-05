#!/bin/sh
# Sync the GB APU shim package from a snes_game_dev checkout into audio/shim/.
#
# The shim is the SPC700 machine the sound engine's register writes land on. It
# is developed, graded and measured in snes_game_dev, and arrives here as a
# package: the assembled binary, the ABI names an engine assembles against, the
# constants the image builder needs, and a MANIFEST that says which commit they
# came from with a sha256 for each.
#
# It is copied rather than submoduled because the two repositories move at
# different rates and for different reasons: this one should be able to sit on a
# known-good shim for weeks while the shim's own tree churns, and the day it
# moves should be a commit here with a diff a reader can see.
#
# A DIRTY SOURCE TREE IS REFUSED. The MANIFEST's whole job is to name the commit
# the bytes came from, and bytes built from uncommitted edits have no commit to
# name -- `zig build shimpkg` marks them `-dirty`, and a `-dirty` package
# committed here is a package nobody can rebuild. Commit there first.
#
# Optional tooling: only needed when the shim moves. `zig build verify` checks
# the committed package against its own MANIFEST without going near the source.
#
#   tools/sync-shim.sh ~/git/snes_game_dev
set -e
SRC=$1
if [ -z "$SRC" ]; then
  echo "usage: tools/sync-shim.sh <path-to-snes_game_dev>" >&2
  exit 2
fi
if [ ! -f "$SRC/audio/gbapu/shim.asm" ]; then
  echo "$SRC does not look like snes_game_dev: no audio/gbapu/shim.asm" >&2
  exit 1
fi
cd "$(dirname "$0")/.."
DEST=$PWD/audio/shim

if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
  echo "$SRC has uncommitted changes; the package would be marked -dirty" >&2
  echo "commit there first, then re-run" >&2
  exit 1
fi

(cd "$SRC" && zig build shimpkg)
PKG=$SRC/zig-out/shimpkg
for f in MANIFEST shim.bin shim_abi.inc shimpkg.zig wave.zig noise.zig; do
  test -f "$PKG/$f" || { echo "the package is missing $f" >&2; exit 1; }
done
case "$(awk '$1=="commit" {print $2}' "$PKG/MANIFEST")" in
  *-dirty) echo "the package names a -dirty commit; refusing" >&2; exit 1 ;;
  "")      echo "the package's MANIFEST names no commit" >&2; exit 1 ;;
esac

mkdir -p "$DEST"
cp "$PKG/MANIFEST" "$PKG/shim.bin" "$PKG/shim_abi.inc" "$PKG/shimpkg.zig" "$PKG/wave.zig" "$PKG/noise.zig" "$DEST/"
echo "synced audio/shim/ from $(awk '$1=="commit" {print $2}' "$DEST/MANIFEST")"
echo "next: zig build verify, then commit audio/shim/ as one change"
