#!/bin/sh
# Assemble engine/audio/main.asm into the committed SPC700 engine image.
#
# DEV TIME ONLY, the same bargain `tools/build-engine.sh` makes for the 65816
# side: the outputs are checked in, so an end user running `m2snes their-rom.gb`
# needs no assembler. Run this after touching engine/audio/main.asm, then
# `zig build verify`, then commit main.asm, audio.bin and audio.mlb together.
#
# The symbol file is `.mlb`, not `.sym`: spc700asm emits Mesen label files, and
# giving it asar's extension would invite someone to read it as a WLA symbol
# file. `zig build romtest` needs the Mesen form anyway.
set -e
cd "$(dirname "$0")/.."
ASM=vendor/spc700asm/spc700asm
if [ ! -x "$ASM" ]; then
  echo "no assembler: run tools/get-spc700asm.sh first" >&2
  exit 1
fi
test -f audio/shim/shim_abi.inc || { echo "no audio/shim/: run tools/sync-shim.sh first" >&2; exit 1; }
"$ASM" -o engine/audio.bin -m engine/audio.mlb engine/audio/main.asm
echo "assembled engine/audio.bin ($(wc -c < engine/audio.bin | tr -d ' ') bytes) and engine/audio.mlb"
