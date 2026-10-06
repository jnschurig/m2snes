#!/bin/sh
# Fetch the SM83 test-ROM suites the emulator is graded against.
#
# These are not ours and are never tracked: they land in `vendor/testroms/`,
# which `.gitignore` excludes. They are also dev-time only — the shipped
# builder runs the emulator against the *user's* ROM and has no use for them.
#
# blargg's suite is the standard correctness bar for an SM83 core. The
# combined `cpu_instrs.gb` is 64 KiB and therefore also exercises MBC1 bank
# switching, which the individual 32 KiB ROMs do not; the individual ones are
# fetched too because they name the failing group instead of just stopping.
#
# Mooneye's acceptance suite is deliberately NOT fetched. Gekkio publishes no
# prebuilt artifacts — no releases, no tags — so using it means assembling the
# suite with RGBDS, which is a toolchain this project does not otherwise need.
# The plan called for it "where cheap"; it is not cheap, so it is skipped and
# said out loud rather than quietly dropped.
set -e
cd "$(dirname "$0")/.."
DEST=vendor/testroms
# Pinned to a commit (master since 2015), so CI fetches the same bytes.
BASE=https://raw.githubusercontent.com/retrio/gb-test-roms/c240dd7d700e5c0b00a7bbba52b53e4ee67b5f15

mkdir -p "$DEST/cpu_instrs"

fetch() {
  # $1 = url path, $2 = destination path
  if [ -f "$2" ]; then
    echo "have  $2"
    return 0
  fi
  curl -fsSL -o "$2.part" "$BASE/$1"
  mv "$2.part" "$2"
  echo "got   $2"
}

fetch "cpu_instrs/cpu_instrs.gb" "$DEST/cpu_instrs.gb"
fetch "instr_timing/instr_timing.gb" "$DEST/instr_timing.gb"

# The eleven individual groups. Names carry spaces and commas, so the URL
# form and the on-disk form differ; the on-disk names are what
# `src/gb/blargg.zig` looks for.
set -- \
  "01-special" \
  "02-interrupts" \
  "03-op%20sp%2Chl:03-op-sp-hl" \
  "04-op%20r%2Cimm:04-op-r-imm" \
  "05-op%20rp:05-op-rp" \
  "06-ld%20r%2Cr:06-ld-r-r" \
  "07-jr%2Cjp%2Ccall%2Cret%2Crst:07-jr-jp-call-ret-rst" \
  "08-misc%20instrs:08-misc-instrs" \
  "09-op%20r%2Cr:09-op-r-r" \
  "10-bit%20ops:10-bit-ops" \
  "11-op%20a%2C%28hl%29:11-op-a-hl"
for spec in "$@"; do
  url=${spec%%:*}
  name=${spec#*:}
  [ "$name" = "$spec" ] && name=$url
  fetch "cpu_instrs/individual/$url.gb" "$DEST/cpu_instrs/$name.gb"
done

echo
echo "test ROMs in $DEST (untracked). Run: zig build test"
