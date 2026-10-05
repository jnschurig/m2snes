#!/usr/bin/env bash
# Render the A/B set for the listening pass: every song and sound effect the
# slice can ask for, each on both engines, into build-out/audio-ab/.
#
# The listening pass (metroid2-audio Step 18) is a person with headphones, and
# this is what it listens to. The ids are the slice's, from docs/audio_ids.md --
# that file derives them from the port's request stubs, so a request the slice
# cannot make is not in here and a stub added later belongs in both.
#
# Three groups, all landing in one directory so that each sound's two takes sort
# next to each other:
#
#   <stem>.gb.wav     bank 4 on the Game Boy harness, through SameBoy's APU
#   <stem>.snes.wav   the ported engine, through the shim and the S-DSP
#   <stem>.req        the script both of them rendered
#
# Effects are rendered twice: alone, and over the main caves theme, because a
# sound that is right by itself can still take a channel the song wanted. The
# hand-written scripts in test/audio/ come last -- they are the cases with no id
# of their own (the quake and its restore, the jingles, pause, the death), and
# they are the same scripts `audiocmp` grades.
#
# Roughly forty minutes, and it needs everything `zig build audioab` needs. A
# render that fails is reported and the set goes on: one bad id should not cost
# the other hundred and fifty.
#
#   tools/audio-ab-set.sh              # the whole set
#   tools/audio-ab-set.sh songs        # one group: songs | sfx | scripts
set -uo pipefail
cd "$(dirname "$0")/.."

group=${1:-all}
log=build-out/audio-ab/SET.log
mkdir -p build-out/audio-ab
: > "$log"

fails=0
total=0

render() {  # any number of `audioab` arguments
    total=$((total + 1))
    printf '%-34s' "$*"
    if out=$(zig build audioab -- "$@" 2>&1); then
        echo "$out" | sed -n '2,3p' | tr -s ' ' | paste -sd'|' -
        printf '== %s\n%s\n' "$*" "$out" >> "$log"
    else
        fails=$((fails + 1))
        echo "FAILED (see $log)"
        printf '== %s   FAILED\n%s\n' "$*" "$out" >> "$log"
    fi
}

# The song the effects are rendered over: the room song the slice starts in.
over=04

if [ "$group" = all ] || [ "$group" = songs ]; then
    echo "--- songs (30s each) ---"
    # docs/audio_ids.md, "The slice > Songs". $FF is silence and has nothing to
    # listen to; the song held across the earthquake is in the scripts below.
    for id in 11 04 0C 0F 15; do
        render song "$id"
    done
fi

if [ "$group" = all ] || [ "$group" = sfx ]; then
    echo "--- square 1 (3s alone, 4s over song \$$over) ---"
    # docs/audio_ids.md, "Square 1 SFX", plus the ids under "Game Boy requests
    # the port has no stub for" that the slice reaches: $01/$02 (jump, hi-jump),
    # $03-$06 (screw attack and the three transitions), and $1B (the Metroid
    # cry, which noise $05 asks for).
    for id in 01 02 03 04 05 06 07 08 09 0A 0B 0C 0E 0F 10 12 13 14 15 16 17 18 19 1A 1B 1C; do
        render sfx sq1 "$id"
        render sfx sq1 "$id" --over "$over"
    done

    echo "--- square 2 ---"
    # $07 is the only square-2 id any site outside bank 4 requests; $03-$06 are
    # reached through the noise channel and are rendered with it.
    render sfx sq2 07
    render sfx sq2 07 --over "$over"

    echo "--- noise ---"
    # docs/audio_ids.md, "Noise SFX", plus $06, $07 and $10 (Samus hurt, acid
    # damage, footsteps) from the no-stub table.
    for id in 01 02 03 04 05 06 07 08 0B 0C 0D 10 11 12 1A; do
        render sfx noise "$id"
        render sfx noise "$id" --over "$over"
    done

    echo "--- wave (the low-health beep, one id per ten points under fifty) ---"
    for id in 01 02 03 04 05; do
        render sfx wave "$id"
        render sfx wave "$id" --over "$over"
    done
fi

if [ "$group" = all ] || [ "$group" = scripts ]; then
    echo "--- the hand-written scripts (test/audio/*.req) ---"
    for f in test/audio/*.req; do
        render "$f"
    done
fi

echo
echo "$total render(s), $fails failed; full output in $log"
echo "listen: build-out/audio-ab/"
exit $((fails > 0))
