# GB APU → SPC700 shim

**Date:** 2026-08-06
**Status:** Proposed. Standalone tooling — worth building independent of whether
[Metroid II](2026-08-06-metroid2-snes-port-feasibility.md) ever happens.
**Idea:** Emulate the Game Boy APU on the SPC700, so that Game Boy music and sound
effects play on SNES hardware without transcribing a single note.

## Why this exists

The Metroid II feasibility study flagged audio as the worst part of any GB→SNES
project: 4 fixed channels → sample-based SPC700, with music **hand-transcribed**
into TAD MML. Weeks of unrewarding work that teaches nothing transferable.

This inverts that. Instead of translating *music*, emulate the *chip*. The GB APU
is small, fully documented, and has a stable interface — 23 registers plus 16 bytes
of wave RAM. Emulating it is a bounded, self-contained problem, and the result is
generic across every Game Boy game ever made.

It is also useful on its own terms: a SNES project that wants authentic DMG-style
chiptune gets it for free, with 4 spare DSP voices left over for sample layering.

## Architecture

```
  offline                          ROM                    SNES                SPC700
┌──────────┐   capture   ┌──────────────────┐   stream   ┌─────┐   $2140-3  ┌──────────┐
│ GB emu + │ ──────────► │ delta-coded      │ ─────────► │65816│ ─────────► │ GB APU   │
│ ROM      │  reg writes │ register-write   │  ~60 Hz    │ thin│  4-byte    │ emulator │
└──────────┘             │ log, LZ'd        │            │ feed│  handshake │ → DSP    │
                         └──────────────────┘            └─────┘            └──────────┘
```

Three pieces, each independently testable:

1. **Capture tool** (Zig, offline) — drives a GB emulator core, records every write
   to `$FF10–$FF26` and `$FF30–$FF3F` with frame timestamps, quantizes to the driver
   tick, delta-encodes, compresses.
2. **Feed** (65816, tiny) — decompresses the next frame's writes from ROM and pushes
   `(register, value)` pairs through the APU I/O ports. Near-zero engine coupling.
3. **Shim** (SPC700 asm) — maintains a virtual GB APU register file, and on each
   write recomputes the affected DSP voice state. This is the actual work.

The virtue of the interface being *hardware registers* rather than *music* is that
the shim doesn't care where writes come from. A pre-captured log, a hand-written
sequencer on the 65816 side, or (in principle) recompiled driver code all drive it
identically.

## Channel mapping

GB has 4 channels; the SNES DSP has 8 voices. The mapping is deliberately
non-competitive — see "Voice allocation" below.

### CH1 / CH2 — pulse (`NR10–NR14`, `NR21–NR24`)

Play a looped square-wave BRR sample. Duty (`NR11`/`NR21` bits 7–6) selects one of
four sample banks: 12.5% / 25% / 50% / 75%.

Pitch: GB pulse frequency is `f = 131072 / (2048 - x)`. The DSP plays at
`32000 × PITCH / 4096`, so for a sample whose loop is `N` samples per period,
`PITCH = f × N × 4096 / 32000`.

**Sample length must vary by octave.** With a 32-sample period, `PITCH` overflows its
14-bit range (max 16383) at about 4 kHz. Provide 2–3 period lengths per duty (32 / 16
/ 8 samples) and select on octave. A 1-block BRR loop (16 samples) is the practical
floor.

CH1's frequency sweep (`NR10`) ticks at 128 Hz and just rewrites the pitch — compute
it in the shim rather than trying to map it onto anything in the DSP.

### CH3 — wave (`NR30–NR34`, wave RAM `$FF30–$FF3F`)

GB wave RAM is 32 4-bit samples in 16 bytes. Re-encode to BRR on write: 32 samples =
2 BRR blocks = 18 bytes, with filter 0 and a fixed shift, which makes the encode
essentially a nibble-expand-and-shift rather than a real BRR compression pass. Cheap
enough to redo every time the game rewrites wave RAM.

Note `f = 65536 / (2048 - x)` here — half the pulse formula. Easy to get wrong.

Volume is a 2-bit shift (`NR32`: 0%/100%/50%/25%), folded into the DSP voice volume.

### CH4 — noise (`NR41–NR44`)

Route a voice through the DSP noise generator (`NON`), and pick the `NCK` rate
(0–31, ~0 Hz to 32 kHz) nearest to GB's
`f = 262144 / (divisor × 2^shift)` from `NR43`.

**This is the one channel that stays approximate**, for two reasons: the DSP's 32
fixed rates don't line up with GB's divisor/shift grid, and — more audibly — GB's
7-bit LFSR mode (`NR43` bit 3) produces a short periodic, metallic tone that the DSP
noise generator simply cannot produce. If 7-bit mode matters for a given game's
percussion, approximate it with a short looped noise-like BRR sample instead of the
noise generator. Percussion will be close, not exact.

### Envelopes, panning, master volume

- **Envelope** (`NR12`/`NR22`/`NR42`): initial volume 0–15, direction, period. Ticks
  at 64 Hz. Compute in the shim and write DSP `VOL(L/R)` directly — do *not* try to
  use DSP ADSR, whose shape is wrong and whose parameters aren't a function of the
  GB ones.
- **Panning** (`NR51`): per-channel L/R *enable* bits, not proportional pan. Maps to
  full-or-zero `VOLL`/`VOLR`. Trivial.
- **Master volume** (`NR50`): 0–7 per side, scales everything.
- **Length counters** (256 Hz) and the power bit (`NR52`) are bookkeeping in the shim.

The GB frame sequencer runs at 512 Hz (length 256 Hz, envelope 64 Hz, sweep 128 Hz).
The shim runs its own timer at 512 Hz rather than deriving anything from the 60 Hz
feed — envelope resolution is audible and 60 Hz is too coarse.

## Voice allocation — don't reproduce channel stealing

The original GB driver arbitrates music against SFX at runtime, stealing channels by
priority. Pre-captured logs can't reproduce that interleaving, and reimplementing the
priority logic would be real work.

Don't. **Music on DSP voices 0–3, SFX on voices 4–7, no stealing.** This is nearly
free, and it's strictly better than the original — sound effects stop punching holes
in the music. It does mean music and SFX must be captured separately, which is the
right structure anyway since SFX are event-triggered, not sequenced.

## Budgets

**Port bandwidth.** A GB music driver emits roughly 20–60 register writes per frame,
bursty at note-on (5–6 per channel) and sparse in steady state. The 4-byte APU I/O
handshake carries a few hundred bytes/frame comfortably. Not a constraint.

**SPC700 CPU.** 1.024 MHz, and the shim's per-frame work is: consume a handful of
register writes, run 512 Hz sequencer ticks, recompute pitch/volume for ≤8 voices.
Should be a small fraction of available time. Wave-RAM re-encode is the one spiky
cost, and it only fires when the game rewrites wave RAM.

**SPC700 RAM.** 64 KB total, shared with samples. The shim never holds a whole song —
it's streamed. Sample banks (4 duties × 3 lengths, plus SFX samples) are small.

**ROM size — the number that needs measuring.** Raw logging is far too fat: ~100
bytes/frame is ~6 KB/s, so a 90-second loop is ~540 KB. But quantized to the driver
tick and delta-encoded (only *changed* registers), steady-state frames drop to a
handful of bytes, and music is extremely repetitive under LZ. Rough estimate:
**~10–25 KB/track compressed**, so a ~15-track soundtrack lands around 150–375 KB in
a 4 MB ROM.

That range is an estimate, not a measurement, and it is the single assumption the
whole approach rests on. Measuring it is a one-day spike: log one track, delta-encode,
compress, look at the number. **Do that before anything else.**

## Known fidelity gaps

Be honest about these up front — they're inherent, not implementation bugs:

- **Gaussian interpolation.** The SNES DSP lowpasses everything it plays. Square waves
  come out slightly softened rather than razor-sharp, most noticeably at high pitch.
  GB-on-SNES will sound a little warmer than the original. Some people will prefer it;
  it is nonetheless not identical.
- **7-bit LFSR noise** has no DSP equivalent (see CH4).
- **Noise rate quantization** to 32 fixed `NCK` values.
- **Timing quantization** to the capture tick, for anything a driver did at finer
  granularity than its own update rate.

## Upgrade path

Once the shim works, voices 4–7 are free whenever SFX aren't playing, so the
soundtrack can go from "authentic GB" to "GB core plus SNES sweetening" — real BRR
instruments layered under the chip channels — without rewriting the shim or
re-capturing anything.

Similarly, because the interface is registers rather than a music format, individual
tracks can be re-authored later as a hand-written sequencer driving the same shim,
trading the log's size for editability. Captured logs get *everything* working
immediately; selective re-authoring is an optimization, not a prerequisite.

## Build order

1. **Measure the log size** (1 day). Capture one Metroid II track, delta-encode,
   compress. If tracks don't compress to something reasonable, rethink before building
   anything.
2. **Capture tool** — GB emulator core + register logger + encoder.
3. **Shim: pulse only** (CH1/CH2). Prove pitch and envelope against a reference
   recording. This is where the design is validated or isn't.
4. **Wave + noise**, including the wave-RAM → BRR re-encode.
5. **65816 feed + streaming**, ROM-side.
6. **SFX path** on voices 4–7, captured separately.

Steps 1–3 are the honest go/no-go. Everything after is filling in.

## Relationship to static recompilation

This shim is the one piece of the [rejected whole-game recompiler
idea](2026-08-06-metroid2-snes-port-feasibility.md#appendix-static-recompilation-considered-and-rejected)
that survives on its own, and the reason is worth stating: **the APU's interface is a
23-register hardware boundary — small, stable, fully documented. The CPU's interface
is the entire game's control flow.** One of those is emulable in isolation; the other
drags in code discovery, indirect jumps, bank switching, and per-game timing quirks.

Emulating the chip is cheap. Emulating the machine is not.
