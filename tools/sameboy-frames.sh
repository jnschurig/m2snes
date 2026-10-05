#!/usr/bin/env bash
# Reference frames from SameBoy, for grading our own PPU against.
#
# SameBoy is the accuracy benchmark for DMG background rendering, and its
# `tester` target runs a ROM headlessly and dumps the framebuffer as a BMP.
# Background-only rasterisation admits no tolerance -- there is no filtering,
# no blending, and no sprite priority to argue about -- so any disagreement
# with SameBoy is a bug in us.
#
# Building it needs RGBDS, because SameBoy assembles its *own* boot ROMs from
# source rather than shipping Nintendo's. That is also why this is safe to use
# here: no proprietary boot ROM is involved, and nothing it produces is tracked.
#
# Usage: tools/sameboy-frames.sh [seconds ...]      (default: 2 4 6 10)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${M2_ROM:?set M2_ROM to your Metroid II ROM (see docs/setup.md)}"
SB=vendor/sameboy
TESTER="$SB/build/bin/tester/sameboy_tester"

if [ ! -x "$TESTER" ]; then
  echo "Building SameBoy's tester (needs rgbds: brew install rgbds)..."
  [ -d "$SB" ] || git clone --depth 1 --branch v1.0.2 https://github.com/LIJI32/SameBoy.git "$SB"
  make -C "$SB" tester -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
fi

OUT=reference/sameboy
mkdir -p "$OUT"

capture() {   # kind, extra-args, seconds...
  local kind=$1 extra=$2; shift 2
  for secs in "$@"; do
    local d="$OUT/$kind-$secs"
    mkdir -p "$d"
    # The tester writes its BMP beside the ROM, so give each run its own copy
    # in an untracked directory rather than writing next to the user's file.
    cp "$M2_ROM" "$d/m2.gb"
    # shellcheck disable=SC2086
    "$TESTER" --dmg $extra --length "$secs" "$d/m2.gb" >/dev/null 2>&1 || true
    rm -f "$d/m2.gb"
    if [ -f "$d/m2.bmp" ]; then
      echo "  $d/m2.bmp   (tick $((secs * 60)) from power-on)"
    else
      echo "  $d: no BMP produced" >&2
    fi
  done
}

# `still` leaves the game on its title screen; `start` runs the tester's Start/A
# schedule, which is what gets us into play -- where scrolling, the window and
# the status-bar split actually happen.
capture still ""        2 4 6 10
capture start --start   8 12 16 20 24 30
