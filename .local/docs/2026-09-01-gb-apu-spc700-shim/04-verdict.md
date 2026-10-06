---
created: 2026-09-04T19:12:00Z
updated:
  - 2026-09-04T19:12:00Z
working_directory: /Users/james/git/snes_game_dev
---

# Verdict: the GB APU → SPC700 shim

## Status: Final

## GO-WITH-CAVEATS

The approach is sound and the arithmetic is right. **The current
implementation cannot carry four channels**, and the reason is one measured
number with three unpulled levers behind it.

---

## What was asked, and what came back

### F1 — will a log fit in a ROM? **PASS, by two orders of magnitude**

| Track | Raw | Delta | LZSS |
|---|---:|---:|---:|
| `title` | 228023 | 18012 | **3387** |
| `attract` | 45227 | 4546 | **1475** |
| `surface` | 83543 | 8458 | **1735** |

2.1 KB per track on average. A 15-track soundtrack extrapolates to **32–50 KB
against F1's 512 KB pass line**; break-even is 238 tracks. This verdict
survives the extrapolation being wrong by a factor of ten.

The driver tick was *derived* (70224 T-cycles, one LCD frame) rather than
assumed, which is the one way the whole measurement could have been quietly
wrong.

### F3 ARAM — **PASS, comfortably**

| | pulse-only | four-channel (est.) |
|---|---:|---:|
| shim code | 1402 | ~2200 |
| sample banks | 144 | ~2650 |
| **fixed total** | **6120** | **~9500** |
| left for streaming | 59416 | **~55800** |

Under 15% of ARAM even at four channels. The bound worth watching is not the
total but the **code region**: `$0200`–`$0e00` is 3072 bytes and the estimate
uses 72% of it, with `STATS_ADDR` as a hard ceiling. That ceiling is a line in
the map, so it is a bound with an answer rather than a wall.

### F3 CPU — **FAIL on the busiest track**

Budget was ≤50% under the busiest captured track. Measured on an FXPak Pro, in
fed mode, two runs each:

| track | busy | rest | **load** | overruns/s | of its ticks |
|---|---:|---:|---:|---:|---:|
| **`title`** | 642/s | 7180/s | **91.1%** | 126 | 24.6% |
| `surface` | 3091/s | 7180/s | **57.0%** | 32 | 6.2% |
| `attract` | 3808/s | 7180/s | **47.0%** | 12 | 2.3% |

**`title` is at 91.1% with two of four channels implemented.** That is not a
margin another channel fits into.

The two numbers on each row are the same fact. At rest the shim completes 120
main-loop passes a frame; under `title`, 10.7. It owes 8.5 sequencer ticks and
5.8 register writes a frame, and `apply_pending` takes one record per pass —
14.3 passes of work into a 10.7-pass budget. That arithmetic *is* the 24.6%
overrun rate.

### Which track has to fit

`title` is the title screen. Nothing else in the game plays it, and while it is
playing the SNES is not running a game — no sprites, no collision, no scripts.
The track that has to fit *during play* is `surface`, at **57.0%**.

That does not retire the caveat, and it changes the shape of it rather than the
size:

- 57% is **still over F3's 50% budget**, with two of four channels.
- The SPC700 does not care what the 65816 is doing; a title screen's idle main
  CPU buys the shim nothing. What a title screen buys is that an overrun there
  costs less, and overruns are already established as inaudible at these rates.
- `attract` is *the same song as `title`*, 3239 driver frames further in, and it
  measures 47%. So one song spans 5.9 writes a frame to 0.8. `title`'s 91% is
  that song's dense opening, sustained across the whole 54-second capture — a
  real sustained peak, not a transient, but also the peak of the soundtrack's
  worst case rather than a typical load.

So the honest reading is: **the gameplay case has ~43% of headroom for two more
channels, and the worst case has 9%.** Whether the worst case must hold at four
channels is a design decision — a simpler title arrangement is a legitimate
answer, and so is accepting overruns on a screen where they have already been
listened to.

---

## The listening verdict

| track | Mesen2 | hardware |
|---|---|---|
| `title` | good | **good** |
| `attract` | good | **good** |
| `surface` | good | **good** |

Judged by ear on the console by James, on the same excerpts the offline bench
rendered. Nothing measured substitutes for this and nothing here pretends to.

Corroborating, but *not* the verdict: **0 disagreements with the
expected-value model** on all three tracks and all seven corpus files, compared
per tick on the DSP's own registers.

---

## Observed gaps, predicted gaps, and bugs

Kept separate on purpose — they carry very different weight.

### Observed, on hardware or in a rendered file

- **`title` at 91.1% CPU.** Above. The headline.
- **Two loud voices clip.** `title` puts 0.72% of samples at the rail, `attract`
  0.076%, because `MVOL` is `$7f` and NR50 is already modelled per-voice. The
  headroom decision was deferred to this step and is deferred again
  deliberately: it should be made once wave and noise exist, because they change
  what the mix has to hold.
- **The shortest sample bank is quiet.** At N = 8 and 12.5% duty the bank
  reaches +16389 of a possible +28672 — a real loss in the highest octave, and a
  consequence of a period too short to hold the duty at that resolution.

### Predicted, not yet observed

- **CH4's 15-bit LFSR cannot be encoded exactly.** Its period is 32767 samples,
  18.4 KB of BRR. A 4096-sample loop is 2304 bytes and **repeats audibly at low
  rates**. That is a fidelity decision, not a size one, and it is not this
  cycle's to make.
- **The fed handshake costs the 65816 a third of a frame** at `title`'s density,
  because the shim takes one `(register, value)` per main-loop pass. Measured,
  not asserted: 228 frames of 3260 hit the ceiling, with nothing dropped.

### Bugs found and fixed in this step

- **Two silent baselines, not one.** The idle rate differs 10% between fed and
  resident modes (`cmpw logPtr, logEnd` against `cmp A, lastSeq`). The first
  Step 14 pass divided resident measurements by the fed baseline and reported
  `title` at 61.5% instead of 57.1%. Now one constant per mode, with a test for
  each and a test that the gap is real so they are not merged back.
- **Three published counters were 8-bit windows on 16-bit values.** `OVR`
  wrapped six or seven times per track and read differently every run of the
  same music. Width is now recovered on the S-CPU side by accumulating
  `(now - last) & $ff` per frame.
- **`tools/build-gate.sh` exited 1 on success** — its last statement is an `if`
  whose test is false when everything passes. Pre-existing and unrelated.

### Not a gap

`SENT` equalled the shim's applied count **to the byte on all six hardware
runs**, with `DROP` zero. The port protocol — two independent latches at one
address, which had two emulators behind it and no silicon — is correct on
hardware. Console and Mesen2 agree on `POS` exactly, `SENT` within five counts
of 18,814, deferrals within two, and the load stall at 8 frames.

---

## Why GO-WITH-CAVEATS and not NO-GO

F3 anticipated this outcome: it said that above 50% "headroom for wave and noise
is gone and the writeup must say so." So it is said. The reason it is not a
NO-GO is that **the 91% is not a property of the approach.** Three levers are
identified, none has been pulled, and all three were built around rather than
into the design.

1. **`sequencer_tick` pushes the DSP unconditionally, every tick.** It sets
   `dirty = 0` and calls `apply_voices` regardless — deliberately bypassing the
   guard `flush_voices` uses. But length runs at 256 Hz, sweep at 128, envelope
   at 64; most of the 512 ticks a second change nothing. Step 11 measured the
   filled-in sequencer and its push together at **35% of the idle loop with
   nothing playing at all**. This is the biggest lever and the cheapest.

2. **`apply_pending` takes one record per main-loop pass.** This one is
   *instrumentation*: `shim.asm:1435` says a drain that ran to empty "would hide
   a burst inside a single pass instead of showing it as the load it is." It
   makes the idle counter honest and it costs `title` 5.8 passes a frame out of
   10.7. Draining the ring is free — but it changes what the idle counter
   measures, so it must be pulled *after* a verdict, not underneath one.

3. **Fed mode is not the only mode.** Resident playback costs the 65816 nothing
   and the shim far less: `title` overruns 3.5/s resident against 126/s fed.
   Music that does not react to gameplay can stream from ARAM. This is not a
   whole answer — a real port runs the Game Boy's sound driver live, and that is
   fed mode by definition — but it removes the feed cost wherever it applies.

**The condition on the GO:** four-channel work does not begin until the CPU
load is re-measured after lever 1. The number to hold to 50% is **`surface`**,
the gameplay track — if it does not come down well under that with two channels,
it will not hold four, and that is the point to reconsider the approach rather
than after wave and noise are written. `title` is reported alongside it as the
soundtrack's worst case, and whether the worst case must also fit is a design
decision rather than a gate.

---

## What this cycle established

- A log fits, with room to spare, and the tick it is quantized to was derived
  from evidence rather than assumed.
- Two pulse channels reproduce the model exactly — 0 disagreements, per tick,
  on the DSP's own registers, across three captured tracks and seven authored
  corpus files.
- They sound right to a person, on real hardware.
- The port protocol is correct on silicon, and the emulator agrees with the
  console on every counter that reproduces.
- ARAM is not the constraint and will not become one.
- **CPU is the constraint**, it is concentrated in the densest track, and the
  largest contributor to it is a known unconditional DSP push.

## What it did not

- Wave (CH3) and noise (CH4) — F3 Out of Scope, and the reason the CPU number
  matters.
- ROM streaming and compressed log playback — F5 Out of Scope. The bench ROM
  carries the thin `$2140`–`$2143` slice and nothing more.
- Coexisting with TAD in one ARAM. The shim runs alone this cycle.
- Any change to `m2snes`. Redirecting Phase 0c is a separate decision, made
  afterwards, and this verdict does not make it.
