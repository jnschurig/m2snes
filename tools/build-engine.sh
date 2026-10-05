#!/bin/sh
# Assemble engine/main.asm into the committed engine image and symbol file.
#
# DEV TIME ONLY. The outputs are checked in, so an end user running `m2snes
# their-rom.gb` needs no assembler - see the header of src/snes_inject.zig.
# Run this after touching engine/main.asm, then `zig build verify`, then commit
# main.asm, engine.bin and engine.sym together.
#
# --fix-checksum=off: the checksum belongs to the finished cart, not to the
# engine image, and the builder patches it once it knows the cart's size.
# --no-title-check: the output file is created empty each time, so there is no
# prior title to verify against.
set -e
cd "$(dirname "$0")/.."
ASAR=vendor/asar/asar
if [ ! -x "$ASAR" ]; then
  echo "no assembler: run tools/get-asar.sh first" >&2
  exit 1
fi
: > engine/engine.bin
"$ASAR" --no-title-check --fix-checksum=off \
        --symbols=wla --symbols-path=engine/engine.sym \
        engine/main.asm engine/engine.bin
echo "assembled engine/engine.bin ($(wc -c < engine/engine.bin | tr -d ' ') bytes) and engine/engine.sym"
