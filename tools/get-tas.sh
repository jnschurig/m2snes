#!/bin/sh
# Fetch the published Metroid II tool-assisted runs the oracle uses as its
# reference input stream.
#
# These are not ours and are never tracked: they land in `vendor/tas/`, which
# `.gitignore` excludes, alongside the test ROMs. They are dev-time only — the
# shipped builder converts the user's ROM and has no use for a movie.
#
# Both are by Cardboard, both are VBM (VisualBoyAdvance) recordings made from
# power-on with no BIOS, and both name the same cartridge our ingest demands:
# their headers carry title "METROID2", header checksum $97 and global checksum
# $581F, which is byte-for-byte what `metroid2.gb` has at $134, $14D and $14E.
# `src/tas.zig` re-checks all three against the configured ROM rather than
# trusting this comment.
#
#   949M — any%, 45:08.42, 162 505 frames
#   979M — 100%, 49:22.82, 177 769 frames. The one to reach for when the
#          question is coverage or the loadout, because it collects every item
#          in the game and therefore sets every equipment bit there is.
#
# TASVideos serves each publication's movie file as a zip from the same URL the
# site's own download button uses.
set -e
cd "$(dirname "$0")/.."
DEST=vendor/tas
mkdir -p "$DEST"

fetch() {
  # $1 = publication id, $2 = the name we file it under
  if [ -f "$DEST/$2.vbm" ]; then
    echo "have  $DEST/$2.vbm"
    return 0
  fi
  curl -fsSL -o "$DEST/$2.zip" "https://tasvideos.org/${1}M?handler=Download"
  # -j flattens, -o overwrites; the archive holds exactly one .vbm whose name
  # is the author's, which we do not want to depend on.
  unzip -joq "$DEST/$2.zip" -d "$DEST/.unpack"
  mv "$DEST/.unpack/"*.vbm "$DEST/$2.vbm"
  rm -rf "$DEST/.unpack" "$DEST/$2.zip"
  echo "got   $DEST/$2.vbm"
}

fetch 949 metroid2-any
fetch 979 metroid2-100

echo
echo "movies in $DEST (untracked). Run: zig build tas"

# ---------------------------------------------------------------------------
# The recorded reference run, which is not fetched.
#
# Phase 0b grades against a run James recorded himself, because zero Metroid
# kills fall inside the any% horizon our own emulator can replay to — see
# `docs/slice.md`. It is a Mesen2 `.mmo`, it is his, and there is nowhere to
# download it from, so this script cannot get it: it reports whether it is
# there and says what to do when it is not.
#
# It lives in `reference/`, which `.gitignore` excludes and `src/policy.zig`
# skips, for the same reason `vendor/` does — it is a recording of the user's
# own cartridge and is never tracked.
echo
if [ -d reference ] && ls reference/*.mmo >/dev/null 2>&1; then
  for f in reference/*.mmo; do
    echo "have  $f"
  done
  echo
  echo "Run: zig build gbtrace"
else
  echo "missing: reference/metroid2.mmo"
  echo
  echo "  Record it in the Mesen2 GUI against your own metroid2.gb and save the"
  echo "  .mmo into reference/. `zig build gbtrace` checks the SHA-1 the .mmo"
  echo "  names against the configured ROM, so a recording made on another"
  echo "  cartridge is refused rather than traced."
fi

# The 100% run (1.0 Step 24a): ordered segments in one directory, taken as one
# recording. Also James's, also never tracked.
echo
if ls reference/metroid2-100p-recording/*.mmo >/dev/null 2>&1; then
  echo "have  reference/metroid2-100p-recording/ ($(ls reference/metroid2-100p-recording/*.mmo | wc -l | tr -d ' ') segments)"
  echo
  echo "Run: zig build gbtrace -- reference/metroid2-100p-recording set"
else
  echo "missing: reference/metroid2-100p-recording/ (the 100% run, in segments)"
fi
