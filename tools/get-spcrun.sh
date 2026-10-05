#!/bin/sh
# Build spcrun, the offline SPC700 runner the audio comparison grades on.
#
# spcrun loads an ARAM image, plays the 65816's side of the shim's port protocol
# from a script, and prints every register write the engine made, the reply each
# message read back, and the idle counter for load. It lives in snes_game_dev
# beside the shim it drives, and `zig build audiocmp` (Step 6) runs it here.
#
# IT IS BUILT FROM THE COMMIT THE SHIM PACKAGE CAME FROM, not from whatever the
# checkout happens to be sitting on. spcrun links the shim's own emulator
# wrapper and embeds a shim binary; running a newer one against the committed
# `audio/shim/` would grade the engine against a machine this repository has
# never seen. So the commit in `audio/shim/MANIFEST` is the pin, and this script
# refuses a checkout that is not on it.
#
# A local path rather than a fetch: snes_game_dev is not public, and a private
# tarball URL is a pin nobody else can resolve either. The MANIFEST commit is
# what makes the local checkout trustworthy.
#
# Optional tooling: needs a snes_game_dev checkout, Zig and a Rust toolchain.
# `zig build verify` does not depend on it.
#
#   tools/get-spcrun.sh ~/git/snes_game_dev
#
# spcrun links libc++, so anything wrong with the host's C++ toolchain shows up
# here and nowhere else in this repository. $ZIG_BUILD_FLAGS is passed through
# for that: on macOS with Command Line Tools 27 installed, zig 0.16 cannot build
# its own libc++ against that SDK, and the way past it is
#
#   zig libc > libc.txt && sed -i '' 's|MacOSX.sdk|MacOSX26.5.sdk|' libc.txt
#   ZIG_BUILD_FLAGS="--libc $PWD/libc.txt" tools/get-spcrun.sh ~/git/snes_game_dev
set -e
SRC=$1
if [ -z "$SRC" ]; then
  echo "usage: tools/get-spcrun.sh <path-to-snes_game_dev>" >&2
  exit 2
fi
cd "$(dirname "$0")/.."
MANIFEST=audio/shim/MANIFEST
test -f "$MANIFEST" || { echo "no $MANIFEST: run tools/sync-shim.sh first" >&2; exit 1; }
PINNED=$(awk '$1=="commit" {print $2}' "$MANIFEST")
HEAD=$(git -C "$SRC" rev-parse HEAD)
if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
  HEAD="$HEAD-dirty"
fi
if [ "$HEAD" != "$PINNED" ]; then
  echo "$SRC is at $HEAD, but audio/shim/ came from $PINNED" >&2
  echo "check that commit out there, or re-run tools/sync-shim.sh" >&2
  exit 1
fi

# Unquoted on purpose: $ZIG_BUILD_FLAGS is a flag list, not one argument.
# shellcheck disable=SC2086
(cd "$SRC" && zig build spcrun $ZIG_BUILD_FLAGS)
mkdir -p vendor/spcrun
cp "$SRC/zig-out/bin/spcrun" vendor/spcrun/spcrun
echo "built: vendor/spcrun/spcrun (snes_game_dev $PINNED)"
