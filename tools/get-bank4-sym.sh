#!/bin/sh
# Fetch M2RoS and assemble bank 4 on its own, for its symbol file.
#
# `zig build audiocost` names the routines a `handleAudio` call spends its
# cycles in. The names come from M2RoS (MIT), pinned to an exact commit. Only
# bank 4 is assembled: the full build needs map banks extracted from a ROM, and
# the sound engine needs nothing outside its own bank and the RAM definitions.
#
# The symbols are only trusted if the bank they came from is the user's bank.
# With `M2_ROM` set, the assembled bank 4 is compared byte for byte against the
# ROM's, and a mismatch fails.
#
# Optional tooling: needs rgbds (rgbasm/rgblink) and curl. Nothing in
# `zig build verify` depends on it; `audiocost` reports addresses without it.
set -e
COMMIT=031aea34cb1a6c6aae0f27b55dd2a6fe7c36b810
cd "$(dirname "$0")/.."
mkdir -p vendor/m2ros
cd vendor
if [ ! -d m2ros-src ]; then
  curl -fsSL -o m2ros-src.tar.gz \
    "https://github.com/metroidret/M2RoS/archive/$COMMIT.tar.gz"
  mkdir m2ros-src
  tar xzf m2ros-src.tar.gz -C m2ros-src --strip-components=1
  rm m2ros-src.tar.gz
fi
cat > m2ros/bank4.asm <<'EOF'
INCLUDE "hardware.inc"
INCLUDE "constants.asm"
INCLUDE "data/enemy_nameConstants.asm"
INCLUDE "data/sprites_creditsConstants.asm"
INCLUDE "data/sprites_samusConstants.asm"
INCLUDE "macros.asm"
INCLUDE "ram/vram.asm"
INCLUDE "ram/sram.asm"
INCLUDE "ram/wram.asm"
INCLUDE "ram/hram.asm"
INCLUDE "bank_004.asm"
EOF
rgbasm -o m2ros/bank4.o -I m2ros-src/SRC/ m2ros/bank4.asm
rgblink -n m2ros/bank4.sym -o m2ros/bank4.gb m2ros/bank4.o
if [ -n "$M2_ROM" ] && [ -f "$M2_ROM" ]; then
  # Bank 4 is file offset $10000, $4000 bytes.
  dd if="$M2_ROM" bs=16384 skip=4 count=1 2>/dev/null > m2ros/rom-bank4.bin
  dd if=m2ros/bank4.gb bs=16384 skip=4 count=1 2>/dev/null > m2ros/asm-bank4.bin
  if ! cmp -s m2ros/rom-bank4.bin m2ros/asm-bank4.bin; then
    rm -f m2ros/bank4.sym
    echo "M2RoS's bank 4 does not match $M2_ROM; symbols withheld" >&2
    exit 1
  fi
  echo "bank 4 matches $M2_ROM"
fi
rm -f m2ros/bank4.o m2ros/bank4.gb m2ros/rom-bank4.bin m2ros/asm-bank4.bin
echo "wrote: vendor/m2ros/bank4.sym ($(grep -c '^04:' m2ros/bank4.sym) symbols)"
