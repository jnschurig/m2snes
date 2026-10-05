#!/bin/sh
# Fetch + build spc700asm, the SPC700 assembler for the sound engine.
#
# Pinned to the same Terrific Audio Driver tag snes_game_dev assembles the shim
# with. That is not a coincidence to be maintained by hand later: the engine and
# the shim are assembled by the same program so that a directive one accepts is
# a directive the other accepts, and `.assert PC == ENGINE__TICK` means the same
# thing on both sides of the ABI.
#
# spc700asm runs at DEV TIME ONLY, like asar. `engine/audio.bin` and
# `engine/audio.mlb` are committed and the shipped builder places them in ARAM;
# someone running `m2snes their-rom.gb` needs the single Zig binary and nothing
# else.
#
# Optional tooling: needs a Rust toolchain and curl. `zig build verify` does not
# depend on it -- it says `not rechecked: no assembler` instead.
set -e
TAD_TAG=v0.4.2
cd "$(dirname "$0")/.."
mkdir -p vendor
cd vendor
if [ -x spc700asm/spc700asm ]; then
  echo "spc700asm already built: vendor/spc700asm/spc700asm"
  exit 0
fi
command -v cargo >/dev/null || { echo "no cargo: spc700asm needs a Rust toolchain" >&2; exit 1; }
if [ ! -d tad-src ]; then
  curl -fsSL -o tad-src.tar.gz \
    "https://github.com/undisbeliever/terrific-audio-driver/archive/refs/tags/$TAD_TAG.tar.gz"
  mkdir tad-src
  tar xzf tad-src.tar.gz -C tad-src --strip-components=1
  rm tad-src.tar.gz
fi
( cd tad-src && CARGO_TARGET_DIR="$PWD/../tad-build" \
    cargo build --locked --release -p spc700asm >/dev/null )
mkdir -p spc700asm
cp tad-build/release/spc700asm spc700asm/spc700asm
echo "built: vendor/spc700asm/spc700asm (TAD $TAD_TAG)"
