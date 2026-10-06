---
created: 2026-09-02T04:47:50Z
updated:
  - 2026-09-02T04:47:50Z
  - 2026-09-02T05:16:35Z
  - 2026-09-02T05:34:42Z
  - 2026-09-02T05:34:49Z
working_directory: /Users/james/git/snes_game_dev
---

# Requirements

## Status: Final

## Overview

Emulate the Game Boy APU on the SPC700 so Game Boy music plays on SNES hardware
without transcribing a note. This cycle builds steps 1–3 of the design doc's
build order — **measure the log size, build the capture tool, build the
pulse-only shim** — which that doc names "the honest go/no-go."

Design doc: [`2026-08-06-gb-apu-spc700-shim.md`](../2026-08-06-gb-apu-spc700-shim.md).
It is the architectural source of truth; this file is the contract for what gets
built and how it is judged.

### Nothing is derived from audio

One point governs the whole design and is stated first because it is the easiest
thing to misread:

```
GB ROM ──► register-write log ──┬──► SPC700 shim ──► SNES audio
                                └──► GB APU       ──► GB audio (the reference)
```

The shim re-derives sound from **register writes** — the same 23 numbers the
Game Boy's own hardware received. A rendered waveform is never an input to
anything. Where this document mentions rendering audio, that audio exists solely
to be *listened to* beside the result. No stage converts sound into sound.

### The go/no-go is a human ear

**Fidelity is judged by listening, per track and per sound effect, by hand.** A
song does not have to be numerically perfect; if it sounds right, it is right.
There is deliberately no numeric fidelity threshold in this document, because a
threshold on a quantity nobody actually cares about is a worse gate than a
person with speakers.

Two things are *not* matters of taste, and they can independently sink the
approach no matter how good it sounds:

- **ROM size** — a log that does not fit is not shippable at any fidelity.
- **ARAM and SPC700 CPU** — 64 KB and 1.024 MHz are physical ceilings.

Those carry stated budgets (F1, F3) fixed before measurement. Everything else is
decided by ear.

### Standalone tooling

The shim is generic across Game Boy titles by construction — its interface is 23
hardware registers, not a music format. Metroid II is the proving ROM, not the
client. Nothing here touches `m2snes`, and the Metroid II port's
`01-requirements.md` (F8, Phase 0c) is **not** amended by this cycle. If the
verdict is GO, redirecting Phase 0c is a separate decision made afterwards.

## Features

### F1. Register-write log: format, encoder, and the measurement

The single assumption the whole approach rests on is that a captured
register-write log compresses to a size a ROM can carry. The design doc puts it
at ~10–25 KB/track and says, in bold, to measure it before building anything.

**Acceptance Criteria:**

- A documented, versioned on-disk log format exists, covering: raw capture
  (every write with frame + intra-frame cycle), quantized-and-delta-coded, and
  compressed. Each stage is separately inspectable.
- The encoder quantizes writes to the driver's own tick, emits only registers
  whose value *changed*, and compresses the result.
- **The driver tick is derived from the capture, not assumed.** It is measured
  from the observed period of the driver's write bursts and reported alongside
  the sizes, with the evidence for it. Quantizing to a guessed tick is the one
  way to make this whole measurement quietly wrong — too fine and the size
  inflates, too coarse and notes disappear.
- **Compressed size is reported per track in bytes**, alongside raw and
  delta-only sizes, so the contribution of each stage is visible.
- At least **three Metroid II tracks** are measured, spanning the soundtrack's
  character (a dense one, a sparse/ambient one, and one between). One track is
  not a measurement.
- The full-soundtrack figure is stated as an **extrapolation and labelled as
  one**, with the per-track measurements it extrapolates from shown.
- Decoding a compressed log reproduces the quantized log byte-for-byte
  (round-trip test in the unit suite).
- Capture is **deterministic**: the same ROM and the same input schedule produce
  a byte-identical raw log across runs and across machines.

**Budget, fixed before measurement:**

- **Pass:** the extrapolated full soundtrack fits in **≤ 512 KB**. On a 4 MB
  cart that is an eighth of the ROM for all music, which leaves the approach
  comfortably viable.
- **Caveat:** 512 KB – 1 MB. Viable, but the writeup must say what it costs and
  what would reduce it.
- **Fail:** over 1 MB. The cycle stops at F1 and the approach is reconsidered
  before any shim code is written. **That outcome is a successful F1.**

**Out of Scope:**

- Choosing a final compression scheme for the ROM. This measures; the shipping
  codec is a later cycle's concern once bandwidth and decode cost matter.
- Streaming, banking, or any ROM-side layout of the logs.

### F2. Capture tool

Drive a Game Boy emulator core over the user's own ROM and record every write to
`$FF10`–`$FF26` and `$FF30`–`$FF3F`.

**Capture and reference are separate jobs, done by separate code.** Capture
needs a core that can be driven to a song-init entry point; reference playback
needs an APU implementation that actually synthesizes. Requiring one component
to do both would likely be unsatisfiable — the core in `m2snes` can be driven to
an arbitrary entry point but has no synthesis at all, by design, while SameBoy
synthesizes accurately but is not built to be steered into a game's internals.
Splitting them costs nothing, because **both take the same log as input**, so
the shim and the reference are aligned by construction anyway.

**Acceptance Criteria:**

- Exposed as a `zig build` step, consistent with the repo's existing tool steps,
  writing to a gitignored output directory.
- **The ROM is an argument, not a constant.** The step takes a ROM path in the
  `zig build <step> -- <rom.gb>` form the repo already uses (`b.args`; bare
  positional words after a step name are parsed by Zig as step names, so `--` is
  required). **ROM precedence when no argument is given, and it is stated in one
  place and obeyed by every step:** the Metroid II ROM in `.local/roms/` if it is
  present, otherwise F6's committed test ROM. So the bare form works on a
  developer machine, works in CI, and never fails for want of an argument.
- **Every step reports which ROM it actually used**, by name, in its output. A
  precedence rule that silently produces different results on different machines
  is only safe if the machine says which branch it took.
- **The supplied ROM is registered as a build file input**, not merely passed as
  a string, so changing ROMs invalidates the cache. A stale artifact silently
  returned for a different ROM is the failure mode this criterion exists to
  prevent.
- Captures a named track by driving the game's own sound engine to a song-init
  entry point, so a track can be captured without playing through the game to
  reach it.
- Every write to the APU register range is logged with frame number and
  intra-frame cycle offset. Writes to a powered-down APU are logged too — what
  the driver *did* is the artifact.
- **Per-game knowledge lives in a descriptor, not in code.** The shim is generic;
  knowing where a given game's song-init routine lives is not. Entry points,
  track lists and the driver's tick rate come from a per-game descriptor file,
  with Metroid II's as the first and only one written this cycle.
- An unsupported ROM **fails with a message naming what is missing** — no
  descriptor for this ROM — rather than crashing, hanging, or producing a silent
  capture that looks like a working one.

**Out of Scope:**

- Writing a new SM83 CPU core or a new GB APU synthesizer. Existing
  implementations are adopted for both halves.
- Automatic song discovery. Track entry points are supplied as data.
- Sound-effect capture (design doc step 6).

### F3. Pulse-only shim — CH1 and CH2 on the SPC700

An SPC700 program holding a virtual GB APU register file, running its own
512 Hz frame sequencer, and driving two DSP voices to reproduce the GB's two
pulse channels.

**Acceptance Criteria:**

- Maintains a virtual register file for `NR10`–`NR14`, `NR21`–`NR24`, `NR50`,
  `NR51`, `NR52` and updates DSP voice state on write.
- **Frame sequencer runs at 512 Hz off the SPC700's own timer**, not derived
  from the feed rate: length at 256 Hz, envelope at 64 Hz, sweep at 128 Hz.
- **Pitch** implements `f = 131072 / (2048 - x)` and maps it to DSP `PITCH` for
  a looped square sample, selecting sample period length by octave so `PITCH`
  never saturates its 14-bit range.
- **Duty** (`NR11`/`NR21` bits 7–6) selects among 12.5% / 25% / 50% / 75%
  sample banks. All four duties are present at every period length in use.
- **Envelope** (`NR12`/`NR22`) — initial volume, direction and period — is
  computed in the shim and written to DSP `VOL(L/R)` directly. DSP ADSR is not
  used.
- **Sweep** (`NR10`) is computed in the shim at 128 Hz, including the overflow
  mute, and rewrites pitch.
- **Length counters** and the `NR52` power bit are honoured.
- **Panning** (`NR51`) maps the per-channel L/R enable bits to full-or-zero
  `VOLL`/`VOLR`; **master volume** (`NR50`) scales both sides 0–7.
- Music occupies DSP voices 0 and 1 only. Voices 2–7 are left untouched, and
  the no-stealing allocation from the design doc is respected.
- Assembles reproducibly from checked-in source into a checked-in binary, with
  the build step to regenerate it — following the repo's existing pattern for
  assembled artifacts.
- **Overrun has a defined behaviour.** If a frame's incoming writes plus
  sequencer work exceed the time available, the shim's response is specified,
  implemented and documented — it does not simply fall behind. Whatever the
  policy, the event is counted in a location the bench ROM can read, so an
  overrun is a number rather than an unexplained glitch.
- **ARAM cost is reported**: shim code, virtual register file, and sample banks,
  in bytes, as measured from the assembler's own output. The report carries a
  **labelled four-channel extrapolation** — pulse-only is a third of the
  eventual problem, and a GO based on measuring the easy third would be
  measuring the part that was never in doubt.
- **SPC700 CPU cost is reported** as a percentage of available time, measured
  under the busiest captured track, by a method documented in the plan and
  calibrated against a silent baseline.

**Budget, fixed before measurement:**

- **ARAM:** measured pulse-only cost plus the four-channel extrapolation must
  leave room for the eventual streaming buffers within 64 KB. Over budget is a
  caveat, not an automatic fail, and the writeup says what would have to give.
- **SPC700 CPU:** ≤ 50% under the busiest captured track. Above that, headroom
  for wave and noise is gone and the writeup must say so.

**Out of Scope:**

- CH3 wave and its wave-RAM → BRR re-encode (design doc step 4).
- CH4 noise (design doc step 4).
- ROM streaming, log compression on the ROM side, and bank management (the bulk
  of design doc step 5). The bench ROM in F5 carries a **minimal** feed — the
  `$2140`–`$2143` handshake and nothing else — and that thin slice is the only
  part of step 5 in this cycle.
- SFX on voices 4–7 (design doc step 6).
- Coexisting with TAD in the same ARAM. The shim runs alone this cycle.

### F4. Offline bench — a development instrument, not the gate

Run the shim in an SPC700 + S-DSP emulator, feed it a captured log, and expose
what it did. **The go/no-go is F5's listening test; this exists to make the shim
correct before a person spends time on it**, and to localize a fault once one is
heard. An ear is the worst available instrument for finding an arithmetic bug.

**Acceptance Criteria:**

- A bench harness loads the assembled shim into emulated ARAM, feeds a captured
  log at the captured timing, and runs it.
- **It renders both sides to WAV for listening** — the shim's output, and the
  reference from the same log played through an existing GB APU implementation —
  named and playable side by side. This is a convenience, not machinery: the
  same comparison can be made by running a Game Boy emulator next to the bench
  ROM, and neither WAV is an input to anything.
- **It exposes the DSP registers the shim actually wrote** — `PITCH` and
  `VOL(L/R)` sampled over time — next to values computed from the GB register
  log. On a *captured* log this is diagnostic output, read when something sounds
  wrong: no threshold gates anything and a discrepancy is a lead, not a failure.
  On F6's *synthetic* corpus the same output is asserted exactly, because there
  the correct answer is known by construction rather than judged.
- **Sequencer rate is verified at 512 Hz** against the emulator's cycle count.
  This one *is* asserted in the test suite, because it is exact, cheap, and
  wrong-by-construction if it drifts.
- **It dumps a playable `.spc` file** for an excerpt whose log fits in ARAM, so a
  converted track can be listened to in any SPC player, shared, and kept as a
  before/after record across changes. An `.spc` is an ARAM image plus register
  state, which the bench already has in hand.
- Runs as a repeatable `zig build` step. Parts needing a ROM skip or fail with a
  named reason when none is present.

**Out of Scope:**

- Numeric fidelity thresholds of any kind. Fidelity is F5's, and it is judged by
  ear.
- Sample-exact waveform comparison. The design doc names Gaussian interpolation
  as an inherent, permanent difference.
- Automated subjective scoring.

### F5. Bench ROM — the shim on real hardware, and the gate

An interactive SNES ROM that uploads the shim, feeds it a captured log, and puts
what the ROM believes is happening on screen. It runs in Mesen2 and deploys to
the FXPak Pro. **This is where the go/no-go verdict is reached.**

**Acceptance Criteria:**

- Built on **`engine/bench.zig`**, the existing subsystem-agnostic bench module —
  a new `Config` plus shim wiring, following `ff6/audiobench_gen.zig` as the
  worked precedent. The bench module is not forked or reimplemented; if it needs
  a capability it lacks, it is extended in place so the FF6 bench keeps working.
- Exposed as a `zig build` step producing an `.sfc` plus its generated Mesen2
  Lua, matching the repo's existing ROM-step pattern.
- **Takes the same ROM argument as F2's capture** —
  `zig build audiobench -- <rom.gb>` — defaulting to the Metroid II ROM in
  `.local/roms/` when none is given, with the same file-input registration and
  the same named failure on a ROM that has no descriptor. Building a bench for a
  different Game Boy game is a command-line argument, not a code change.
- The baked track catalogue is derived from the descriptor for the supplied ROM,
  so the SONG field's range and the on-screen labels describe the game actually
  loaded.
- **Every sound is a button press.** The ROM plays nothing on its own: track
  selection is an editable field, and starting, stopping and restarting playback
  are button actions with a generated legend. A silence following no press is
  the bench working.
- **The feed is bounded and never blocks.** It gets a fixed cycle budget per
  frame; writes that do not fit defer to the next frame rather than spinning on
  the handshake. Gameplay timing is protected unconditionally — the SPC700 is a
  separate processor and the shim costs the 65816 nothing, so the feed is the
  only path by which audio could ever slow the game, and this closes it.
- **Readouts distinguish the kinds of silence**, so a silent bench says which
  silent it is — at minimum: the shim did not come up; the shim is up with no log
  loaded; a log is loaded and the shim believes it is driving voices. A frozen
  playback position under the third is a stalled feed, otherwise
  indistinguishable from a working one.
- **Deferred writes and shim overruns are on screen**, so the design doc's claim
  that port bandwidth is "not a constraint" is measured rather than repeated,
  and F3's overrun counter is visible where a person can see it happen.
- **It plays the same track and excerpt F4 rendered.** An offline-vs-hardware
  disagreement must be attributable to the shim, the feed, or the console —
  which it cannot be if the two benches are playing different music.
- **Runs on real hardware.** Deployed to the FXPak Pro via `tools/fxpak.sh
  deploy`, with the hardware listening pass performed and recorded. A result
  that holds in Mesen2 but not on the console is a finding.
- Its own automated rom-test is a **smoke test and says so in its own
  documentation** — it can assert the ROM boots, draws, and that the shim
  responded, and it cannot assert anything was audible.

**Out of Scope:**

- ROM streaming and compressed log playback (design doc step 5 proper).
- Sound effects, and any second log playing concurrently.
- Making the bench a pass/fail gate for CI. It is an instrument for a person.

### F6. Original test fixtures and CI coverage

> Added 2026-09-02, after the plan was drafted. CI runs on `ubuntu-latest` with
> no ROM and no `vendor/`, so **every step of this cycle as originally specified
> would have been invisible to it.** Nothing in F1–F5 can run on a machine that
> does not own Metroid II.

Original, freely redistributable fixtures that make the pipeline testable
without any commercial ROM.

**Acceptance Criteria:**

- **A Game Boy test ROM, written by us, containing no copyrighted bytes.** It is
  original SM83 source plus a small driver, and it ships two selectable tracks:
  - a **register-coverage exercise** — every APU register, both envelope
    directions, sweep including the overflow mute, all four duties, the pitch
    range end to end, and the `NR52` power bit. It deliberately reaches cases no
    real track reaches.
  - a **short original tune**, composed for this purpose, so there is something
    to *listen* to that we are free to distribute.
- **The assembled `.gb` is committed; the assembler is a rebuild-only
  dependency.** `rgbds` is needed only by someone editing the source, exactly as
  `asar` is for `m2snes`'s `engine.bin` and as TAD ships its own
  `audio-driver.bin`. CI consumes the committed binary and never installs an
  assembler.
- **A synthetic register-write log corpus**, authored directly in a readable text
  form and compiled to the log format. It needs no emulator, no ROM and no
  assembler, and it exists because the log — not the ROM — is the shim's actual
  interface.
- **Expected DSP `PITCH` and `VOL(L/R)` for the synthetic corpus are computed
  from the published GB formulas and asserted exactly in the test suite.** This
  is not a fidelity threshold and does not contradict the ear being the gate:
  fidelity is judged on real music by a person, while this asserts arithmetic on
  an input whose correct answer is known by construction. It is the assertion
  that catches a regression.
- **The test ROM is the last entry in F2's ROM precedence**, so `zig build
  audiobench` with no argument produces a working bench ROM on a machine that
  owns no commercial ROM, rather than failing. A machine holding the Metroid II
  ROM still gets Metroid II, and the go/no-go is still reached against it — the
  fixture makes the tooling *runnable* everywhere, and does not become the
  subject of the verdict.
- **CI covers the pipeline end to end** on `ubuntu-latest` with no ROM and no
  `vendor/`: test ROM → capture → log → encode → round-trip, and, once the shim
  exists, → shim → asserted DSP registers.
- Capture from the test ROM is deterministic, and its register sequence is
  compared against what the source is known to emit — which is the only way to
  show the **capture** is right rather than merely repeatable.

**Out of Scope:**

- Running the SPC700 shim itself in CI where that needs `vendor/tad-src`. Steps
  that need the vendored emulator or assembler skip with a named reason, as the
  FF6 vendor-independence invariant already requires.
- Making the test ROM musically interesting. It is a fixture.
- Any listening assertion. CI still cannot hear.

### F7. Go/no-go writeup

The cycle's actual deliverable: a verdict with the evidence under it.

**Acceptance Criteria:**

- A document in this cycle's directory recording:
  - measured compressed log size per track, the measured driver tick and its
    evidence, and the labelled full-soundtrack extrapolation, against F1's
    budget (F1);
  - measured ARAM cost with its four-channel extrapolation, and SPC700 CPU
    percentage, against F3's budgets (F3);
  - measured deferred writes and shim overruns per frame (F5);
  - **the listening verdict, per track, in plain words** — stating for each
    whether it was reached in Mesen2, on the FXPak Pro, or both (F5).
- **The listening verdict is the fidelity verdict.** Tracks are graded by hand,
  individually. "Sounds right" is a sufficient pass and needs no further
  justification; "sounds wrong" is recorded with what was wrong about it.
- **Every fidelity gap observed in practice** is listed, separated from the ones
  the design doc predicted, and separated again from implementation bugs left
  unfixed.
- A **GO / NO-GO / GO-WITH-CAVEATS verdict** stated outright, with the caveats
  enumerated if any.
- Anything not measured is listed as not measured. No number in this document
  is an estimate unless it is labelled one.

**Out of Scope:**

- Deciding Phase 0c's audio path. That decision is made after this, by James,
  with this document as input.

## Constraints & Dependencies

**Repository and toolchain**

- All code lands in `snes_game_dev`, under the `audio/` directory `PLAN.md`
  already reserves and which does not yet exist. `zig build` is the only entry
  point; tools are pinned through `mise`.
- Rust/cargo is already a required dev dependency of this repo, so Rust-side
  tooling from `vendor/tad-src` is available without adding a new dependency
  class.

**Reuse, not reinvention** — four pieces already exist and building substitutes
for them is out of scope:

- **SPC700 assembler:** `spc700asm`, shipped in `vendor/tad-src/crates` and
  already used to assemble TAD's own driver. Extending `zasm` to the SPC700 is
  not in this cycle.
- **SPC700 + S-DSP emulator:** `shvc-sound-emu` from the same vendored tree,
  which exposes arbitrary ARAM, DSP registers, IO ports and a per-buffer
  `emulate()`. `runtime-pc/tadshim` is the existing precedent for wrapping a
  `vendor/tad-src` crate as a C-ABI staticlib for Zig.
- **On-screen bench:** `engine/bench.zig`, already subsystem-agnostic by
  construction — its own header names "a TAD bench, a palette bench or a
  collision bench" as the intended reuse. It knows the DMA queue, the joypad
  shadow and a glyph sheet; fields, readouts, actions and the generated legend
  all come from a `Config`. `ff6/audiobench_gen.zig` is the worked precedent.
  Any gap is closed by extending the module in place, keeping the FF6 bench
  building.
- **Game Boy emulation:** adopted for both halves, never written (see F2). The
  capture core must be steerable to a song-init entry point; the reference core
  must synthesize. They may be different programs, and probably are.

**Assets and licensing**

- **`rgbds` is a rebuild-only dependency** (F6). It assembles the Game Boy test
  ROM, whose binary is committed; nobody building this repo needs it, and CI
  does not install it. It is pinned in `mise.toml` for whoever edits the source.
- **No copyrighted bytes are committed.** The Metroid II ROM stays in the
  gitignored `.local/roms/`; captured logs, reference WAVs, rendered WAVs and
  `.spc` dumps are build products in gitignored output directories and are never
  tracked.
- Sample banks (the square-wave BRR loops) are generated by our own code from
  first principles, contain nothing derived from any ROM, and may be checked in
  or generated at build time.
- Third-party licensing is recorded the way this repo already records it, in
  `assets/docs/tad-licenses.md` or a sibling.

**Verification posture**

- Everything measurable is measured by a repeatable build step, not by hand.
- Steps that need a ROM skip or fail with a named reason when none is present,
  so the gate stays green on a machine without one — matching how the FF6
  ROM-dependent steps already behave.
- **Nothing we can automate can hear.** Mesen2's test runner has no audio sink,
  so the last rung of every audio claim is a person with speakers. This is a
  standing property of the project, established by the FF6 audio work, not a
  gap to be closed later.
- **Two benches, two jobs, stated wherever either appears.** The offline bench
  (F4) is a development instrument that makes the shim correct and localizes
  faults; the bench ROM (F5) is the gate, and runs on both Mesen2 and the FXPak
  Pro. A verdict names which one it came from.
- Hardware deployment uses the existing `tools/fxpak.sh deploy` path; no new
  console tooling is built.
- **CI must exercise the pipeline, not skip it.** F6 exists so that a push with
  no ROM and no `vendor/` still tests capture, encoding, round-trip and the
  shim's arithmetic. A cycle whose every step needs a commercial ROM is a cycle
  CI cannot defend.

**Accepted fidelity gaps** (inherent, from the design doc; not bugs, and not
grounds for NO-GO on their own)

- Gaussian interpolation softens square waves — GB-on-SNES is warmer than the
  original.
- Timing is quantized to the capture tick for anything the driver did at finer
  granularity than its own update rate. The bench ROM's feed additionally
  delivers a frame's writes as a burst rather than spread across the frame,
  which is the one place that quantization has teeth.

**Sequencing**

- F1's measurement gates F3. No shim code is written until the log-size number
  exists and has a verdict against F1's budget.
- F2 must be far enough along to produce a real capture before F1 can conclude;
  the two are built together, with F1's *decision* the checkpoint between them
  and F3.
- F4 precedes F5. The shim must be correct in the offline bench before a person
  spends time listening to it on a console.
- F5's minimal feed is the only part of design doc step 5 built this cycle, and
  it is built for the bench. It is not a down payment on the streaming feed and
  carries no obligation to be its foundation.
