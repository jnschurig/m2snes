---
created: 2026-09-02T18:54:00Z
updated:
  - 2026-09-02T18:54:00Z
  - 2026-09-02T22:49:54Z
working_directory: /Users/james/git/snes_game_dev
---

# The measurement

## Status: Final

**Verdict: PASS.** The extrapolated Metroid II soundtrack is **32–50 KB**
compressed, against F1's 512 KB pass line. The approach is not size-limited,
and it is not close to being size-limited.

Reproduce with `zig build gbmeasure`. Everything below is that command's
output plus the reasoning behind it.

## The driver tick, derived

F1 requires the tick to be measured, not assumed, because quantizing to a
guessed tick is the one way to make the whole measurement quietly wrong — too
fine and the size inflates with timing nobody hears, too coarse and notes
vanish into each other.

The method: cluster writes into bursts (a driver tick is a burst — a handful of
registers written tens of cycles apart, then silence), take the intervals
between burst onsets, and find the coarsest period that explains at least 90% of
them.

| Track | Writes | Bursts | Tick (T-cycles) | = frames | Intervals explained | Worst miss |
|---|---:|---:|---:|---:|---:|---:|
| `title` | 19001 | 3205 | 70224 | 1.00 | 99.8% | 5924 cycles |
| `attract` | 3768 | 407 | 210672 | 3.00 | 99.0% | 5204 cycles |
| `surface` | 6961 | 608 | 280896 | 4.00 | 99.7% | 3704 cycles |

**Reconciled: 70224 T-cycles = exactly one LCD frame = 59.73 Hz.**

The three rows do not disagree. A track can only support the coarsest period it
demonstrates: `surface`'s driver is silent on three frames out of four, and from
that track alone a four-frame tick is indistinguishable from a one-frame tick
used sparsely. The driver's own tick has to divide all three, so it is their
greatest common divisor — and `title`, which speaks every frame, shows the real
thing directly.

Two pieces of corroboration that were not needed to reach the answer but agree
with it:

- **Every burst starts at the same point in the frame** — intra-frame cycle
  ~15,900–22,400 across all three tracks, a spread of under a tenth of a frame.
  A driver called on a fixed cadence looks like this; one called opportunistically
  does not. (It is *not* the VBlank vector: VBlank begins at cycle 65,664. The
  writes land around scanline 35, which is where a main loop that waits for
  VBlank, does its graphics work, and then calls the sound engine would end up.)
- **The worst misses are all under 8.5% of a frame**, which is the wobble you get
  when the sound call sits behind a variable amount of other per-frame work.

## The three stages

Defined in `audio/log.zig`. Each has its own magic and version byte and can be
read and written on its own, because this table is a comparison *between* the
stages and a middle term nobody can dump is a number nobody can check.

1. **raw** — every write with its frame and the cycle within it, 12 bytes each.
2. **quantized + delta** — writes assigned to the tick above, the intra-tick
   cycle discarded, and writes that cannot change what the APU does removed.
   A byte-oriented command stream: `wait n`, `write reg value`, `end`.
3. **compressed** — stage 2 through `assets/lzss.zig`, the repository's existing
   2 KB-window LZSS, already validated against real FF6 data. Chosen so the
   codec is not itself a variable here, and because the 65816 can decode it.

Stage 2 is deliberately byte-oriented and repetitive rather than bit-packed. A
bit-packed stage 2 would be smaller on its own and larger after compression,
and the second number is the one that decides anything.

## Sizes

| Track | Seconds | Writes | Events | Raw | Delta | **LZSS** | B/s | zstd\* |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `title` (dense) | 54.2 | 19001 | 7570 | 228023 | 18012 | **3387** | 62.4 | 1875 |
| `attract` (sparse) | 78.7 | 3768 | 2059 | 45227 | 4546 | **1475** | 18.7 | 1129 |
| `surface` (between) | 60.0 | 6961 | 3914 | 83543 | 8458 | **1735** | 28.9 | 1251 |

\* zstd -19 is a **lower bound, not a shippable codec**. The 65816 has to decode
this on the cart, and measuring with something it cannot run would flatter the
result into a GO it has not earned. It is here only to separate "LZSS is leaving
a lot on the table" from "this data is simply this size" — and the answer is
that LZSS gives up a factor of ~1.5 against a codec with no such constraint.

Where the reduction comes from: **raw → delta is 12.7×**, and **delta → LZSS is
another 5.0×**, for 63× overall on the dense track. The delta stage does most of
the work, and it does it by dropping writes, not by encoding them cleverly:
`title` writes 19001 times and only 7570 of those change anything.

## What the delta stage drops, and what it must not

A write is dropped when the register already holds that value. Two exceptions,
both of which would be silent bugs:

- **`NRx4` with bit 7 set is a note-on, not a value.** Writing `$87` to NR14
  twice starts the note twice and leaves the same byte behind. In `surface`,
  **989 of 6961 writes** — one in seven — are exactly this. A delta coder that
  dropped them would have looked like a further 14% saving and produced a track
  with most of its note-ons missing.
- **Clearing bit 7 of NR52 powers the APU down**, which zeroes the whole
  register file on hardware. After that the driver's next write to *any*
  register is meaningful again, so the shadows go back to unknown.

There is a third case the raw log turned up that neither a size figure nor a
register snapshot would have shown. Every track writes `$FF1A` (NR30, the wave
DAC) as `$00` then `$80` **28 cycles apart** — 106 times in `title`, 214 in
`surface`, 246 in `attract`, always exactly that pair, always exactly 7 machine
cycles apart. It is the wave-channel restart idiom, and it is a within-tick
sequence rather than two ticks. It survives quantization because both writes
change the register; it is counted explicitly in the equivalence check below
because a snapshot at the end of the tick cannot see it.

## Why the sizes are trustworthy

Three checks, all of which run in CI on the Step 3 fixture and all of which ran
on the real tracks before these numbers were printed:

- **Stage 3 decodes to stage 2, byte for byte.**
- **Stage 2 parses back to the exact event list it was built from.**
- **Replaying stage 2 leaves the same register file at the end of every tick as
  replaying the raw log, with the same number of note-ons on each channel and
  the same number of wave-DAC toggles.** This is the check that says the
  quantized log is the same *music*, not merely the same size. It found a real
  defect in its own first version, and it has a test that proves it can fail.

The delta event counts were also reproduced independently, from the `.rawlog`
files, by a script that shares no code with the encoder: 19001 − 11431 = 7570,
6961 − 3047 = 3914, 3768 − 1709 = 2059. All three match.

## The extrapolation — labelled as one

Measured: 3 tracks, 192.9 s of music, 6597 compressed bytes.

- **34.2 compressed bytes per second of music**, or **2.0 KB per minute**.
- **2.1 KB per measured track** on average; **3.3 KB** for the largest.

The design doc estimated a **15-track** soundtrack, and at the time this
document was written that count was the one input here that was *not* measured.

**Step 5 replaced it with a count: 25.** The driver's song table holds 32 ids;
six alias another id's data and one points into the driver's own code, and the
aliasing was established by capturing every id and comparing the logs rather
than by reading the table. `zig build gbsongs` prints it. The revised
extrapolation, with the original alongside it:

| Basis | Estimate |
|---|---:|
| 25 tracks × mean measured track | **54 KB** (was 32 KB at 15) |
| 25 tracks × **largest** measured track | **83 KB** (was 50 KB at 15) |
| Break-even for the 512 KB pass line | 238 tracks, or 256 minutes of music |
| Break-even for the 1 MB fail line | 477 tracks, or 511 minutes of music |

**The verdict does not depend on the track count being right**, which is the
useful thing about the count having gone up by two thirds and changed nothing.
It survives the figure being wrong by a factor of ten in either direction: 250
tracks at the largest measured size is 810 KB — past the pass line, but that is
ten times a *counted* number now rather than ten times a guess. The design doc's
own estimate of 10–25 KB/track was pessimistic by roughly an order of magnitude.

What is still an extrapolation is the **rate**: three measured tracks standing
in for twenty-five. The break-even line is the number that does not depend on
it.

## What this does not measure, and what could still bite

Stated because a PASS this wide invites less scrutiny than it should get.

- **Three tracks are three tracks.** They were chosen to span the soundtrack's
  character (5.9, 1.9 and 0.8 writes per frame) and the largest-track column is
  the hedge, but a track substantially denser than `title` would move the mean.
  The `title` figure is the relevant ceiling: it already rewrites all three tone
  channels' frequency registers *every single frame*.
- **Sound effects are not in these logs.** The captures are music with no input
  after the track starts. A game mixing SFX into the same registers writes more,
  and Phase 0c would have to measure that separately. Step 5 confirmed the two
  are separate at the driver's own interface: `$CEDC` carries music ids only,
  and the driver refuses anything above `$20`. Effects go through a different
  path (`$CEDE`, `$CFC7`, `$CFC8`) that nothing has yet measured.
- **Decode cost is not measured.** F1 explicitly scopes this to size. Whether
  the 65816 can feed the shim at 60 Hz from an LZSS stream is F3/F5's problem,
  and the relevant number for it is not in this document.
- **`title`'s log opens with an 8-frame LCD-off stretch** (frame 1, ~593k
  cycles) in which the driver's initialisation writes all land in one tick. That
  is init code rather than music, and the derivation drops those intervals
  rather than pretending to have measured them.
- **The intra-tick cycle is discarded.** Nothing in the shim's design needs
  sub-frame timing, since the driver only acts once per frame, but if that ever
  changes the raw stage still has it.

## Consequence

Step 4's gate passes. Steps 5–13 begin.

Since the log is not the constraint anyone expected it to be, one thing worth
carrying forward: the pressure on the format is now decode cost and BRR sample
budget, not bytes. There is no reason to spend effort making stage 2 smaller.
