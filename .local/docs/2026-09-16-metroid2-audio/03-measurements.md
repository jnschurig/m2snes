---
created: 2026-09-17T01:42:39Z
updated:
  - 2026-09-17T01:42:39Z
  - 2026-09-21T02:27:19Z
  - 2026-09-21T02:47:07Z
working_directory: /Users/james/git/snes_game_dev
---

# Measurements

## Status: Draft

## Step 1: lever 1, push only what changed

**The change.** `dirty` is one bit per voice. A register write sets both bits.
`tick_length`, `tick_envelope` and `tick_sweep` set a voice's bit only when
they change what that voice plays: length reaching zero on an enabled channel,
an envelope step, a sweep write-back, or a sweep overflow on an enabled channel.
`sequencer_tick` pushes only when a bit is set, and `apply_voices` pushes only
the dirty voices. `koffMask` persists between pushes. The `STATS__BUSY` bracket
still covers the push and the `STATS__TICKS` increment.

A sweep write-back marks the voice dirty even when the period comes out the same.
It still overwrites any NR13/NR14 write made since the trigger, so skipping it
would be a behaviour change (caught before it was graded).

### Grading: unchanged

| | before | after |
|---|---:|---:|
| `gbbench` corpus disagreements (7 files) | 0 | **0** |
| `gbgrade` `title` disagreements / compared | 0 / 2677 | **0 / 5746** |
| `gbgrade` `attract` | 0 / 5117 | **0 / 9544** |
| `gbgrade` `surface` | 0 / 3711 | **0 / 6962** |

About twice as many ticks are compared after the change, because fewer
observations land while the shim is busy.

### Silent baselines, re-measured

| | before | after |
|---|---:|---:|
| fed | 7198 /s | **8860 /s** (+23%) |
| resident | 6460 /s | **7952 /s** (+23%) |
| gap | 10.3% | **10.2%** |

The gap is still real, so the "two baselines" test stays and passes.
`gbbench` now prints the resident rate beside the fed one.

### Offline resident load (`zig build gbgrade`)

Before and after were both run on this tree today. "Before" is `HEAD`'s
`shim.asm` divided by the old baselines, and "after" is the new shim divided
by the new ones.

| track | load before | **load after** | overruns before | overruns after |
|---|---:|---:|---:|---:|
| `title` | 57.1% | **11.9%** | 190 | 35 |
| `attract` | 39.5% | **−2.6%** | 245 | 87 |
| `surface` | 43.0% | **2.6%** | 718 | 262 |

`attract` reads below zero. The idle measure has noise of a few percent, and
that track's load is inside it. Read it as "about zero", not as a gain.

Why the drop is this large: the old tick pushed both voices every tick, and on
a *live* voice the push is a pitch-table lookup plus two multiplies and a divide.
The silent baseline only ever paid for the cheap silent path, so the old load
figures were mostly that live push, 512 times a second.

Overruns here are an artefact of the emulator's 8 ms step (the verdict says so),
so they are not a hardware prediction.

### A test that had to get harder

`grade.test "a track dense enough to make the shim fall behind…"` asserts the
shim *does* fall behind (`overruns > 0`), and its 6 writes a frame no longer
make it. It now sends two note-ons per channel per frame, in one burst:
**264 overruns, 448 compared, 0 disagreements**.

**A lead, not a regression.** At three or more note-ons per frame in a burst,
the model disagrees on both shims:

| burst | old shim | new shim |
|---|---|---|
| 3 notes/frame | not run | 5 of 392 |
| 4 notes/frame | **150 of 190**, 1921 overruns | 13 of 341, 600 overruns |

The new shim is far better on this input, but neither holds exact time past that
density. A real driver writes ~6 registers a frame at `title`'s peak, and this is
24. Record it for the four-channel load re-check (Step 11).

### Verification

- `zig build test`: all pass.
- `zig build gbbench`: 0 disagreements. `zig build gbgrade`: 0 on all three.
- `zig build audiobench`: builds, and the Mesen2 smoke test passes. The shim is
  1449 bytes (was 1402).

### Environment note

The Command Line Tools updated to SDK 27.0 on 2026-09-14. Its `math.h` takes
`INFINITY` from `float.h` via `__need_infinity_nan`, which zig 0.16.0's clang
does not provide, so libcxx fails to compile and every C++-linking step fails.
Workaround used here: `zig libc > libc.txt`, point it at `MacOSX26.5.sdk`, and
pass `--libc libc.txt`. `SDKROOT` does not help, because zig asks
`xcrun --sdk macosx`.

### Hardware (FXPak Pro)

`audiobench` (`zig-out/gbbench.sfc`), fed mode (the bench ROM's only mode, and
the verdict's method), whole tracks, two runs each. James read the latched
screen, 2026-09-17. `busy = IDL@ x 256 / (POS / 60.0988)` and
`rest = (IDLR - IDL@) x 256 / (600 / 60.0988)`.

Raw readouts (hex):

| track | run | POS | SENT | IDL@ | IDLR | DEFR | OVR | DROP | LD |
|---|---|---|---|---|---|---|---|---|---|
| `title` | 1 | 0CBC | 4A47 | 03EB | 0545 | 001B | 0000 | 0000 | 0008 |
| `title` | 2 | 0CBC | 4A47 | 03EC | 0545 | 001B | 0000 | 0000 | 0008 |
| `attract` | 1 | 125D | 0EC0 | 09C7 | 0B1F | 0021 | 0000 | 0000 | 0008 |
| `attract` | 2 | 125D | 0EC0 | 09C6 | 0B1F | 0021 | 0000 | 0000 | 0008 |
| `surface` | 1 | 0E14 | 1AD4 | 069C | 07F5 | 0086 | 0000 | 0000 | 0008 |
| `surface` | 2 | 0E14 | 1AD5 | 069B | 07F4 | 0086 | 0000 | 0000 | 0008 |

| track | verdict load (before) | **load after** (runs 1 / 2) | busy | rest | overruns/s before | **after** |
|---|---:|---:|---:|---:|---:|---:|
| `title` | 91.1% | **46.6% / 46.4%** | 4736/s | 8860/s | 126 | **0** |
| `surface` | 57.0% | **18.4% / 18.4%** | 7221/s | 8847/s | 32 | **0** |
| `attract` | 47.0% | **7.1% / 7.4%** | 8190/s | 8834/s | 12 | **0** |

**The console's rest rate is 8821–8872/s, against the offline fed baseline of
8860.** Silicon and the emulator agree within 0.5%, as they did before (7180
against 7198).

**No overruns on any run.** DROP is zero, and the runs repeat each other within
one count.

**`surface`, the number the verdict's condition holds to 50%, is 18.4% with two
channels.** `title`, the soundtrack's worst case, is 46.5%, under the budget.
Most of what is left on `title` is the fed path: `apply_pending` takes one
record per main-loop pass (lever 2, still unpulled on purpose). Resident
offline, the same track is 11.9%.

**Listening:** James, on the console: all three tracks sound good.

## Step 2: what the engine costs on the Game Boy

**SM83 measurements. They are a lead, not a gate.** T-cycles don't convert to SPC700 time;
what carries over is where the time goes and how a busy frame compares with a
quiet one. Reproduce with `zig build audiocost` in m2snes. Routine names come
from `tools/get-bank4-sym.sh`: M2RoS bank 4 assembled alone, and checked byte
for byte against the user's bank 4 before its symbols are used.

Method: a cold machine, `initializeAudio` once, the request written, then
`handleAudio` (bank 4 `$4000`) called once per frame for 1792 calls (30 s).
The `callFar` trampoline is excluded. One LCD frame is 70224 T-cycles.

| case | song | max | p95 | mean | mean, % of a frame |
|---|---|---:|---:|---:|---:|
| `title` | `$11` | 13520 | 2796 | 2890 | 4.12% |
| `attract` | `$11`, 3239 calls in | 14212 | 3888 | 1951 | 2.78% |
| `surface` | `$04` | 13448 | 7688 | 2316 | 3.30% |
| `surface` + SFX burst | `$04` | 13540 | 7852 | 2807 | 4.00% |

The SFX burst is one request every 8 frames from frame 120 on, rotating missile,
enemy killed, beam, enemy explosion, beam dink and enemy projectile across
square 1 and noise. It is denser than play on purpose.

The worst call is about 5× the mean on every case. `surface`'s p95 is 2.6× its
mean: the cost comes in bursts on note boundaries, not evenly.

### Where the cycles go

| routine | `title` | `attract` | `surface` | `surface`+SFX |
|---|---:|---:|---:|---:|
| `handleSongPlaying` | 41.5% | 43.6% | 36.3% | 28.9% |
| `handleSongSoundChannelEffect` | 26.6% | <0.8% | <1.4% | <1.6% |
| `copyChannelSongProcessingState` | 2.3% | 7.1% | 13.7% | 11.3% |
| `handleSongAndSoundEffects` | 9.3% | 13.7% | 11.6% | 9.5% |
| `loadNextSound` | 1.7% | 5.5% | 9.2% | 7.5% |
| `handleChannelSoundEffect_*` (four) | 10.0% | 14.8% | 12.4% | 13.3% |
| `handleSong_loadNextChannelSound_*` | ≥1.0% | ≥3.7% | ≥6.6% | ≥1.6% |
| `loadPointerFromTable`, `setChannelOptionSet`, SFX playback | | | | ≥9.7% |

**What the spike has to cover:** `handleAudio` → `handleSongAndSoundEffects` →
`handleSongPlaying`, with `copyChannelSongProcessingState`, `loadNextSound` and
the per-channel `handleSong_loadNextChannelSound_*`. Those cover 60% (`title`) to 83%
(`surface`) of the music-only cases. `handleSongSoundChannelEffect` (vibrato-style effects) is
a quarter of `title` and almost nothing on `surface`, so the `surface`-only
spike does not exercise it. The four-channel extrapolation in Step 7 has to
account for that, and `title` is its test.

### The ids

`docs/audio_ids.md` in m2snes has them, each with its source. Findings that later steps
depend on:

- **The port stubs 14 square-1 ids plus the shot table, 12 noise ids, 4 interruptions and the slice's songs**
  (`$04`, `$0C`, `$0F`, `$15` = room song + `$11`, the post-quake song, `$FF`).
- **No door on the slice's route in `slice.md` carries a `SONG`.** The slice's music changes
  come from the save's room song, the Metroid fight and kill, and the earthquake.
- **The port has no stub for some requests the slice certainly makes**, starting with
  jump / hi-jump (00:$1509, 00:$167F). Also unstubbed: the low-health beep
  (01:$58C8, wave channel), pause, and several Samus transition and noise ids.
  Step 16a has to add stubs for them, or they stay silent.
- A live watch over James's recording wasn't possible: our Game Boy emulator
  loses it at frame 28 796, and the Mesen2 reference trace does not record the
  request bytes. The ids come from the port's stubs plus a ROM scan instead.

## Step 3a: hosted mode, and what it cost the other two

Hosted mode is a third entry in the input dispatch. Done as a chain of
compares, it cost fed 4.0% of its silent baseline (8860 → 8502). Checking fed
first cost resident 3.7% instead (7952 → 7659). As a jump table indexed by the
mode, both got cheaper:

| silent baseline | before | compare chain | fed first | **table** |
|---|---:|---:|---:|---:|
| fed | 8860 /s | 8502 | 8826 | **8911** (+0.6%) |
| resident | 7952 /s | 7921 | 7659 | **8129** (+2.2%) |

`bench.silent_baseline_idle_hz` is re-stated to the table's numbers.

`gbgrade` on the new shim: 0 disagreements on all three tracks. Resident load
`title` 11.8%, `attract` −2.8%, `surface` 2.4% (Step 1: 11.9, −2.6, 2.6).
`gbbench`: 0 disagreements. `audiobench`: builds, and the Mesen2 smoke test
passes. The shim is 1950 bytes (was 1449).

**A fault the grade caught.** The first cut cleared hosted mode's reply block
at boot in every mode. That block is inside the resident log's span, so 12 log
bytes became wait records, and `grade.zig`'s dense-track test went from 0 to
475 disagreements. Hosted setup now runs only in hosted mode.

## Step 7: the gate, the engine spike

**The port is wider than the spike the plan described, and for a reason found
during it.** Step 7 planned "the instruction reader for square 1". Three pieces
of state the square-1 stream depends on are shared with the other three
channels: `songTranspose` and `songInstructionTimerArrayPointer` are set by
instructions $F3 and $F2 from whichever channel's stream reaches them, and
`songSoundChannelEffectTimer` is one timer for all four. A square-1-only reader
would drift from the Game Boy the first time square 2 changed the tempo. So the
whole song player is ported — `handleAudio`'s frame path, `handleSong`,
`loadSongHeader`, `handleSongPlaying`, `loadNextSound` with its five
instructions, the four `loadNextChannelSound` routines and the pitch effects —
and the *comparison* is what narrows to square 1.

Still not ported, and returning without doing anything at the label the Game Boy
reaches: the four channels' sound effects (Steps 13-14), the song interruptions,
the fade and the pause (Step 15). A script that requests any of them diverges at
the first register write; Step 7's scripts request none.

`engine/audio.bin` is 3204 bytes of the 10 KiB the shim reserves.

### The grade: exact, and wider than the gate asked for

`zig build audiocmp -- <script>` in m2snes. Every write and every read-back
byte, tick for tick.

| script | filter | ticks | writes compared | result |
|---|---|---:|---:|---|
| `surface-2s` | `square1` | 120 | 84 | **exact** |
| `surface-30s` | `square1` | 1792 | 986 | **exact** |
| `surface-30s` | all | 1792 | 3032 | **exact** |
| `title-30s` | all | 1792 | 11158 | **exact** |
| `lag` | all | 9 | 68 | **exact** |

`title-30s.req` is new here. `surface` barely touches
`handleSongSoundChannelEffect` (<1.4% of its cycles in Step 2); `title` spends a
quarter of its time there, so a port exact on `surface` and not on `title` has
not ported the effects. It is exact on both.

**Two faults the grade caught**, both of them writes rather than sounds:

- The shim set the write trace's head before calling `ENGINE__INIT` and left it
  there, so `initializeAudio`'s NR52/NR50/NR51 writes were tagged tick 0 — the
  number the first real tick carries — against a Game Boy log that attaches
  after `initializeAudio` returns. Fixed in the shim (snes_game_dev 1c818eb):
  reset the head again after `init`. `gbbench` and `gbgrade` on all three
  tracks: 0 disagreements, load unchanged.
- The Game Boy sets NR51's bits 6 and 2 on a wave note with two `set b,[hl]`
  instructions on the register itself, which the APU sees as **two** writes. The
  port folded them into one `or`. Same note, one write short.

### Offline load

`zig build audioload -- <script>` in m2snes, new here. The same script twice
through `vendor/spcrun`: once with `engine/audio.bin` and once with a null
engine whose `init` and `tick` both return at once. Hosted mode, trace off.

| script | silent | busy | **load** | overruns |
|---|---:|---:|---:|---:|
| `surface-30s` | 8060 /s | 7119 /s | **11.7%** | 489 |
| `title-30s` | 8060 /s | 6389 /s | **20.7%** | 1283 |
| `surface-2s` | 8062 /s | 7154 /s | 11.3% | 49 |

The difference between the two runs is the engine's own work **plus** the shim
work its register writes cause — a live pulse voice costs the shim a pitch-table
lookup, two multiplies and a divide per sequencer tick, and the silent baseline
never pays for it. So this is the decision's "engine + measured two-channel
shim", measured together rather than added. What it does not cover is CH3/CH4
synthesis, which this shim does not do yet.

`audioload.silent_baseline_idle_hz = 8060` is recorded and compared each run, so
a change in the shim's own per-tick cost announces itself instead of moving the
baseline and the measurement together. For comparison, snes_game_dev's own
silent baselines on the same shim are 8911/s fed and 8129/s resident.

Overruns are the emulator's 8 ms step, as in Step 1 — not a hardware prediction.

### Hardware: not yet

`audiobench` has no hosted mode, so the console number the verdict's condition
is held to is still missing. See Step 7's open sub-tasks.

### Splitting the offline number, and estimating CH3/CH4

`audioload` measures the engine and the two-channel shim together, because the
only honest denominator is the same machine with nothing in it. The decision
wants them apart, and Step 1 already measured the shim half: resident mode
replaying `surface`'s captured log is the shim doing exactly the register writes
this engine makes, and it cost **2.4%** (Step 3a's re-measurement; 2.6% in Step
1 before hosted mode moved the baseline).

| `surface`, offline | |
|---|---:|
| engine + two-channel shim (`audioload`) | 11.7% |
| less the two-channel shim (Step 3a, resident) | −2.4% |
| **the engine's own share** | **≈ 9.3%** |

The subtraction is across two modes, so read it as a split and not a
measurement: resident walks a log out of ARAM where hosted takes a record off
the ports, and the two paths are not the same handful of instructions.

**The CH3/CH4 estimate.** The shim does not synthesise the wave or noise
channels yet (Steps 9-10), so what they will cost is an estimate, and this is
its reasoning:

- The shim's per-tick cost is per *live voice*, not per write: Step 1's lever
  pushes only voices whose state changed, and a live pulse voice's push is a
  pitch-table lookup, two multiplies and a divide.
- `surface` writes 3032 registers over thirty seconds across four channels, and
  986 of them are square 1's. The four channels are within a factor of two of
  each other, so CH3 and CH4 will be live about as often as CH1 and CH2.
- So the shim's live-voice work roughly **doubles**: ≈ 2.4% becomes ≈ 5%.
- CH3 adds a wave-RAM lookup on each trigger, which Step 9 will size. Metroid
  II changes wave patterns on instrument changes rather than on notes, so it is
  a handful of lookups a second, not one per note. Allow a point for it.

**Offline, `surface`, four channels: ≈ 9.3% engine + ≈ 6% shim ≈ 15%.** Against
the 50% the decision is held to that is a wide margin — but the condition names
a console, and Step 1 is why: on `title` the console read 46.5% where the
emulator read 11.9%, because the fed path costs on silicon what it does not cost
in an 8 ms buffer. Hosted mode does not use that path, so the gap should be much
smaller here. That is a prediction, and the FXPak run is what settles it.

### The console run, when it happens

`zig build hostedbench` in snes_game_dev, around a `--no-trace` image built
here; `docs/setup.md` in m2snes has the command and the arithmetic. START
uploads, runs one tick a frame for EXCERPT seconds, silences the engine and
measures 600 frames at rest, with the tick counter, overruns and idle counter
latched together by the shim.

Two runs each of `SURFACE` and `TITLE`, and the numbers to write down are POS,
TCK, SENT, DEFR, OVR, IDL@, IDLR and LD.

## Step 7: the console

`zig build hostedbench` in snes_game_dev, around a `--no-trace` image from
m2snes. James, on the FXPak Pro, 2026-09-21. EXCERPT $3C, so 3601 ticks — the
SNES counts its own frames at 60.0988 Hz, which is 59.9 s and not a round number
of Game Boy seconds.

Raw readouts (hex):

| image | run | ST | POS | TCK | SENT | IDLE | IDL@ | IDLR | DEFR | OVR | LD |
|---|---|---|---|---|---|---|---|---|---|---|---|
| SURFACE | 1 | 01 | 0E11 | 0E11 | 1068 | 0797 | 065F | 0797 | 0000 | 04D4 | 0032 |
| SURFACE | 2 | 01 | 0E11 | 1C22 | 1068 | 0799 | 0660 | 0799 | 0000 | 04D4 | 0032 |
| TITLE | 1 | 01 | 0E11 | 2A33 | 1068 | 0722 | 05EA | 0722 | 0000 | 0A03 | 0032 |
| TITLE | 2 | 01 | 0E11 | 3844 | 1068 | 0722 | 05EA | 0722 | 0000 | 09C0 | 0032 |

`busy = IDL@ x 256 / (POS / 60.0988)`, `rest = (IDLR - IDL@) x 256 / (600 /
60.0988)`, `load = 1 - busy / rest`.

### The offline figure and the console's, over the same music

| track | window | offline | console run 1 | console run 2 |
|---|---|---:|---:|---:|
| `surface` | 60 s | **12.8%** | **12.9%** | **13.1%** |
| `title` | 60 s | **19.1%** | **19.1%** | **19.1%** |

**They agree to a tenth of a point on `title` and three on `surface`.** So do the
overruns: offline 1167 against the console's 1236 on `surface`, offline 2228
against 2563 and 2496 on `title`.

That is the opposite of Step 1's result, where the console read 46.5% on `title`
and the emulator read 11.9%, and it is the same explanation from the other side.
The gap there was the *fed* path — `apply_pending` taking one record per
main-loop pass, which costs on silicon what it does not cost inside an 8 ms
emulator buffer. Hosted mode does not use that path at all. What is left is the
engine's own cycles and the shim's, and on those the emulator was always
trustworthy: the rest rate here is 8000–8026/s against the offline baseline of
8060, 0.6% apart, as it was 0.5% apart in Step 1.

The 60 s scripts (`surface-60s.req`, `title-60s.req`) were written for this
comparison and are graded exact, all four channels: 7023 writes and 19287.

### The tick counter did not reset between runs

`TCK` came back at exactly 1x, 2x, 3x and 4x `POS` across the four runs, and
James spotted it on the console before the arithmetic did here.

It is a fault in the bench, not in the engine. `TCK` is the shim's
`STATS__HOSTED_TICKS`, which counts from the shim's *boot* — and the shim boots
once per power cycle, because the S-CPU cannot reset the S-SMP. START baselined
the idle counter and not this one. Run 1 is therefore the only row where the
check was checking anything, and there it passed exactly: POS 3601, TCK 3601.

Fixed by giving it the baseline `IDLE` already had. Both are now "since START",
and the screen says so.

### The title theme goes quiet before the excerpt ends

James saw the music stop near the end of `title` while the counters kept
climbing. It does, and the Game Boy does the same thing: the 60 s comparison is
exact on all four channels, so this is the music and not the port.

Writes per five seconds, per channel, over the run:

| window | CH1 | CH2 | CH3 | CH4 |
|---|---:|---:|---:|---:|
| 0–50 s | ~600 | ~600 | 96–697 | 8–20 |
| 50–55 s | 495 | 492 | 511 | 8 |
| 55–60 s | **45** | **36** | **114** | 12 |

The last write is at tick 3583, 59.6 s in. `songPlaying` stays at $11 throughout
— the engine still has the song loaded and is playing very long notes, which is
why nothing on screen stopped.

**It biases `title`'s 60 s figure low**, because the last sixth of the window is
nearly silent. The denser 30 s window reads 20.7% offline, and that is the
number to treat as `title`'s cost.

### Overruns, which fed mode never had

| track | offline | console run 1 | console run 2 | per second |
|---|---:|---:|---:|---:|
| `surface` | 1167 | 1236 | 1236 | 20.6 |
| `title` | 2228 | 2563 | 2496 | 42.8 / 41.7 |

Step 1's hardware pass had **no overruns on any run**, and the offline ones it
did see were called an artefact of the emulator's 8 ms step. Neither reading
carries over, because both were about fed mode. Here the emulator and the
console agree within 6–15%, which means these are real.

The cause is in the shape of hosted mode rather than in anything being too slow.
The shim runs **one engine tick per pass of its main loop**, and a `surface`
tick averages about 2200 SPC cycles against the 512 Hz sequencer's period of
2000. So a tick that lands on a note boundary — Step 2 measured the worst
`handleAudio` call at 5x the mean — pushes the next sequencer tick late. At
20/s on `surface` that is one frame in three; on `title`, closer to two in
three.

What a late sequencer tick costs is the length counter, the envelope and the
sweep moving one 512 Hz step later than they should. It is inaudible as a glitch
by construction — nothing is dropped, only deferred — and whether it is audible
as anything is Step 18's question, which is now carrying a specific thing to
listen for. If it turns out to matter, the lever is on the shim's side: service
the sequencer between engine ticks rather than after them.

## Step 7: the decision

**The condition.** Extrapolated engine + measured two-channel shim + estimated
CH3/CH4 shim ≤ 50% on `surface`, with `title` alongside.

Three of the four terms are now measured rather than extrapolated, and on the
console rather than offline. What is still an estimate is CH3/CH4, which the
shim does not synthesise yet.

| | `surface` | `title` |
|---|---:|---:|
| engine + two-channel shim, **measured on the console** | 13.0% | 20.7%¹ |
| of which the two-channel shim (Step 3a, resident) | 2.4% | 3.6% |
| of which the engine | 10.6% | 17.1% |
| CH3/CH4 shim, **estimated** (the shim's live-voice work doubled, plus a point for the wave lookup) | +3.4% | +4.6% |
| **four channels** | **16.4%** | **25.3%** |
| Steps 13-15's sound effects, **estimated** (Step 2: `surface`+SFX cost 22% more than `surface`) | +2.3% | +3.8% |
| **four channels, whole engine** | **18.7%** | **29.1%** |

¹ `title`'s 30 s figure, because its 60 s window ends in six nearly silent
seconds. `surface` loops and its two windows agree.

**The gate passes, with room.** `surface` lands at 18.7% of a 50% budget even
after both estimates are added, and `title` — the soundtrack's worst case — at
29.1%. The two terms still estimated would both have to be about three times
what they are projected to be before the condition came under threat.

**What the margin does not cover**, stated so it is not read as covered:

- CH3/CH4 synthesis is an estimate from the pulse channels' cost. Steps 9-10
  measure it, and Step 11 re-checks this figure with all four channels real.
- Sound effects, the interruptions, the fade and the pause are not written yet.
  The 22% comes from Step 2's SM83 measurement of a deliberately dense SFX
  burst, which is a lead and not a gate.
- The overruns above are not in the load figure and are not a load problem.

**Step 7's verdict: go.** The port is exact, it fits, and Steps 8-18 proceed.

## Step 11: four channels, measured

### A fault first: the catch-up applied writes late

Step 10's captured music disagreed after overruns (`title` 8, `surface` 48).
`service_timer` ran every elapsed sequencer tick and only then let
`service_resident` apply the log records owed to them, so a trigger due before
an envelope step landed after it. The records are now applied between the ticks.
Step 9's `catchUp`, which held STATS__BUSY through the catch-up so the grade
would not look, is removed.

| | before | **after** |
|---|---:|---:|
| `gbgrade` `title` differ / checked | 8 / 5461 | **0 / 5490** |
| `gbgrade` `attract` | 0 / 9436 | **0 / 9454** |
| `gbgrade` `surface` | 48 / 6753 | **0 / 6778** |
| dense burst, 4 note-ons a frame, stepping envelope | 3 (21 with the exclusion off) | **0** |

Step 1's lead (3-4 note-ons a frame disagreeing) was the same fault. It is a
test now (`runDense(4, 1)`).

### ARAM by region (`zig build gbbench`, hosted mode, waves counted full)

| region | span | size | used | free |
|---|---|---:|---:|---:|
| direct page, shim | `$0000-$00C0` | 192 | 192 | 0 |
| **shim code** | `$0200-$0D80` | 2944 | **2802** | **142** |
| noise clock table | `$0D80-$0E00` | 128 | 112 | 16 |
| stats + config | `$0E00-$0E38` | 56 | 56 | 0 |
| square bank | `$0E38-$0F00` | 200 | 144 | 56 |
| **DSP directory** | `$0F00-$1000` | 256 | **252** | **4** |
| pitch table | `$1000-$2000` | 4096 | 4096 | 0 |
| wave lookup | `$C000-$C400` | 1024 | 257 | 767 |
| wave + noise samples | `$C400-$FF00` | 15104 | 4437 | 10667 |
| **the shim's own bytes** | | | **12348** (18.8%) | |

The F3 verdict estimated ~9,500 fixed bytes at four channels. The measured
12,348 is higher mostly because of the noise samples (3,429 bytes, three
oversampled tiers, Step 10). ARAM passes F3 comfortably. Room for streaming
and the engine is unchanged, because the engine regions are fixed. **The bound
to watch is the code region: 142 bytes free.** The next shim feature (Step
7's "service the sequencer between engine ticks", if Step 18 asks for it) has
to fit there or move `SHIM_CODE_END`. Metroid II uses 7 of the 16 wave slots
(113 of the lookup's bytes, 441 of BRR).

### Silent baselines moved

Two more channel blocks on every length and envelope tick: fed 8911 → **8779**,
resident 8129 → **8009** (`bench.silent_baseline_idle_hz`), and m2snes's hosted
null engine 8060 → **7936** (`audioload.silent_baseline_idle_hz`).

### Load, offline

Shim alone, resident (`gbgrade`, captured logs):

| track | two channels (Step 3a) | **four channels** |
|---|---:|---:|
| `title` | 11.8% | **15.0%** |
| `attract` | −2.8% | **−1.7%** (about zero) |
| `surface` | 2.4% | **5.3%** |

Engine + shim, hosted (`audioload` in m2snes, measured together):

| script | two channels (Step 7) | **four channels** | overruns |
|---|---:|---:|---:|
| `surface-30s` | 11.7% | **14.7%** | 636 |
| `surface-60s` | 12.8% | **16.0%** | 1468 |
| `title-30s` | 20.7% | **25.3%** | 1811 |
| `title-60s` | 19.1% | **22.8%** | 3059 |

`audiocmp`: exact on all six scripts on the four-channel shim.

### The gate, re-checked

| | `surface` | `title` |
|---|---:|---:|
| engine + four-channel shim, **measured** offline | 16.0% (60 s) | 25.3% (30 s)¹ |
| Steps 13-15's sound effects, estimated as in Step 7 (+22% of the whole) | +3.5% | +5.6% |
| **whole engine, four channels** | **19.5%** | **30.9%** |

¹ `title`'s 30 s window, for Step 7's reason (its 60 s window ends quietly).

**Passes: `surface` 19.5% against 50%.** Step 7's estimate for the CH3/CH4 shim
was +3.4 points on `surface`; the measured difference is +3.2 (60 s). Offline
and console agreed within 0.3 points in Step 7 on this path, and the console
run below confirms or corrects that.

### The mix

The S-DSP clamps the sum of the voices before `MVOL` scales it, so lowering
`MVOL` cannot remove clipping. The per-voice full scale has to come down.
Samples within 800 of the rail (32511), per full scale (pulse and wave; the
noise generator is scaled in proportion from 96):

| full scale | `title` | `attract` | `surface` | `title` RMS |
|---:|---:|---:|---:|---:|
| 127 (now) | 0.825% | 0.375% | 0.041% | 8046 |
| 112 | 0.414% | 0.191% | 0.018% | 7196 |
| 96 | 0.098% | 0.082% | 0.000% | 6227 |
| 80 | 0.016% | 0.019% | 0.000% | 5196 |
| 64 | 0.000% | 0.005% | 0.000% | 4159 |

No clamp at all under the worst case (four voices at envelope 15, NR50 7)
needs about 37, which is 11 dB quieter than now and not worth it for a case
the music never reaches.

**What was heard as clipping was key-on.** `attract` 6-9 s clicked at every full
scale, and none of its samples came near the rail. At 7.067 s the output reads
`11168, 6426, 6421, 6425, 0, 0, 0, 0, 0, 19286`: two unison squares retriggered
mid-note, each cut to the S-DSP's five-sample key-on silence and restarted.
The Game Boy's trigger keeps a square's duty position (SameBoy `apu.c`), so it
has no gap. A pulse voice already sounding is no longer keyed on again. The
largest jump in the window went from 19,286 to about 8,100 (the reference, at
its own level, peaks near 4,600 there, and ours plays 3.55x louder).

**Decision (James, 2026-09-21): keep full scale 127 and `MVOL` $7f.** With
the clicks gone, "the 127 tracks are clean." The near-rail samples that remain
(`title` 0.80%) are not audible.

**Superseded 2026-09-25 (0b cycle, Step 24f), on level rather than clipping.**
James's playtest found the cart far too loud: 3.5x the Game Boy's RMS, the
ratio this section had set aside. Full scale is now 64 (noise 48) and `MVOL`
$46, which puts the slice at SameBoy's level (the set −0.0 dB) with nothing
near the rail. m2snes's `audio level` rung holds it.

### The console (FXPak Pro, James, 2026-09-21)

Both ROMs built on the final shim (snes_game_dev b1e213f; the m2snes image from
f2d6759). `busy = IDL@ x 256 / (POS / 60.0988)`, `rest = (IDLR - IDL@) x 256 /
(600 / 60.0988)`, `load = 1 - busy / rest`.

`gbbench.sfc`, fed mode, the shim alone (hex):

| track | run | ST | POS | SENT | IDL@ | IDLR | DEFR | OVR | DROP | LD | **load** |
|---|---|---|---|---|---|---|---|---|---|---|---:|
| `title` | 1 | 01 | 0CBC | 4A60 | 0524 | 067B | 0002 | 0000 | 0000 | 0010 | **29.4%** |
| `title` | 2 | 01 | 0CBC | 4A60 | 0524 | 067B | 0002 | 0000 | 0000 | 0010 | 29.4% |
| `title` | 3 | 01 | 0CBC | 4A60 | 0524 | 067B | 0002 | 0000 | 0000 | 0010 | 29.4% |
| `attract` | 1 | 01 | 125C | 0EDF | 09E2 | 0B38 | 0002 | 0002 | 0000 | 0010 | **5.6%** |
| `attract` | 2 | 01 | 125C | 0EDF | 09E1 | 0B37 | 0002 | 0001 | 0000 | 0010 | 5.6% |
| `attract` | 3 | 01 | 125C | 0EDF | 09E2 | 0B38 | 0003 | 0001 | 0000 | 0010 | 5.6% |
| `surface` | 1 | 01 | 0E14 | 1B57 | 06CD | 0823 | 0003 | 0004 | 0000 | 0010 | **15.3%** |
| `surface` | 2 | 01 | 0E14 | 1B56 | 06CC | 0822 | 0004 | 0003 | 0000 | 0010 | 15.3% |
| `surface` | 3 | 01 | 0E14 | 1B56 | 06CD | 0823 | 0004 | 0004 | 0000 | 0010 | 15.3% |

Rest rate 8770-8795/s, against the offline fed baseline of 8779. Against Step
1's two-channel console figures (`title` 46.5%, `surface` 18.4%, `attract`
7.2%) four channels read *lower*. Why is not established. Fed mode is the
bench's path and not what ships, so this is a lead and not a finding.

`gbhosted.sfc`, the engine and the four-channel shim (hex):

| image | run | ST | POS | TCK | SENT | IDLE | IDL@ | IDLR | DEFR | OVR | LD | **load** |
|---|---|---|---|---|---|---|---|---|---|---|---|---:|
| SURFACE | 1 | 01 | 0E11 | 0E11 | 1066 | 073D | 060B | 073D | 0002 | 05F0 | 0050 | **15.8%** |
| SURFACE | 2 | 01 | 0E11 | 0E11 | 1066 | 073E | 060C | 073E | 0002 | 05F0 | 0050 | 15.7% |
| TITLE | 1 | 01 | 0E11 | 0E11 | 1067 | 06C0 | 058E | 06C0 | 0001 | 0D21 | 0050 | **22.6%** |
| TITLE | 2 | 01 | 0E11 | 0E11 | 1067 | 06C0 | 058E | 06C0 | 0001 | 0D15 | 0050 | 22.6% |

| hosted | offline (60 s) | **console** | overruns/s, console |
|---|---:|---:|---:|
| `surface` | 16.0% | **15.8%** | 25.4 |
| `title` | 22.8% | **22.6%** | 56 |

**They agree within 0.2 points**, as they did within 0.3 at two channels.
TCK equals POS on every run, now that both count from START. The rest rate is
7846/s against the offline hosted baseline of 7936. With Step 7's
sound-effects allowance, `surface` is **≈19.3% on the console**, against 50%.

James heard TITLE end early. That is the music: Step 7 traced its last write
to 59.6 s of the 60 s window, and the script is graded exact against the Game
Boy. Overruns rose with CH3/CH4 (`surface` 20.6/s → 25.4/s, `title` 42/s →
56/s). They are lateness and not loss (see Step 7), and Step 18 listens for them.
