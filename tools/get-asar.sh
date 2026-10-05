#!/bin/sh
# Fetch + build asar, the 65816 assembler for the engine image.
#
# Pinned to an exact release. asar runs at DEV TIME ONLY: it assembles
# `engine/` into a committed image (Step 11), and the shipped builder injects
# converted assets into that image. An end user running `m2snes their-rom.gb`
# never needs an assembler, a Rust toolchain, or anything but the single Zig
# binary — that is the whole point of the pre-assembled decision in
# `01-requirements.md`.
#
# Optional tooling: nothing before Step 11 needs it, and `zig build verify`
# does not depend on it.
set -e
VERSION=1.91
cd "$(dirname "$0")/.."
mkdir -p vendor
cd vendor
if [ -x asar/asar ]; then
  echo "asar already built: vendor/asar/asar"
  exit 0
fi
if [ ! -d asar-src ]; then
  curl -fsSL -o asar-src.tar.gz \
    "https://github.com/RPGHacker/asar/archive/refs/tags/v$VERSION.tar.gz"
  mkdir asar-src
  tar xzf asar-src.tar.gz -C asar-src --strip-components=1
  rm asar-src.tar.gz
fi
mkdir -p asar
cmake -S asar-src/src -B asar-build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build asar-build --config Release -j >/dev/null
find asar-build -name 'asar' -type f -perm -u+x -exec cp {} asar/asar \; -quit
test -x asar/asar || { echo "build produced no asar binary" >&2; exit 1; }
echo "built: vendor/asar/asar ($(./asar/asar --version | head -1))"
