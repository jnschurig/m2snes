---
created: 2026-09-16T16:35:11Z
updated:
  - 2026-09-16T16:35:11Z
  - 2026-09-16T17:52:25Z
  - 2026-09-16T18:17:51Z
  - 2026-09-17T01:16:54Z
  - 2026-09-17T02:53:04Z
  - 2026-09-17T03:30:49Z
  - 2026-09-21T03:40:53Z
  - 2026-09-21T22:21:07Z
  - 2026-09-22T02:09:32Z
  - 2026-09-22T03:18:00Z
  - 2026-09-22T04:29:59Z
  - 2026-09-22T04:57:41Z
  - 2026-09-22T16:01:52Z
working_directory: /Users/james/git/snes_game_dev
---

# Requirements

## Status: Final

## Overview

Give the Metroid II port its sound. Everything the 0b slice reaches (music, sound effects,
and the earthquake's interruption and restore) plays on the SNES. It comes from the original
sound engine, rewritten to run **on the SPC700**, driving the GB-APU shim that
`2026-09-01-gb-apu-spc700-shim` proved. This is Phase 0c. It lands while 0b's bug sweep is
still open, so audio bugs can be fixed as part of that sweep.

### The architecture, stated first

```
65816 NMI ──tick count + request bytes──► $2140 ──► SPC700
                                                        ├─ bank-4 sound engine  (m2snes, SPC700 asm)
                                                        │     └─ calls the shim's register-write entry
                                                        └─ GB-APU shim binary   (snes_game_dev, vendored)
                                                              └─► S-DSP voices 0–3
◄── "playing" state bytes ─────────────────── $2140 ◄───────────┘
```

- The 65816 sends **requests, not register writes**. The stubs 0b already records (`!Song`,
  `!SongInt`, `!Sfx1`, `!SfxNoise`, …) become the requests, and the feed and its per-frame
  65816 cost go away.
- The engine's register writes are **local calls into the shim's register file**, so there is
  no ring buffer and no one-record-per-pass apply (the verdict's lever 2 disappears).
- Song, instrument, SFX and wave-table data are **extracted from the user's ROM at build
  time** and placed in the ARAM image by the m2snes builder. Nothing copyrighted is committed.

### Timing is lockstep with the game's `handleAudio` calls

On the Game Boy, bank 4's handler runs once per `handleAudio` call. That is usually once per
frame from `waitOneFrame`, but wait loops also call it, and main-loop lag can leave a frame with
no call. The port keeps that: **one engine tick per `handleAudio` call**. The 65816 counts the
calls it stands in for and sends that **tick count** (0, 1 or more) with the frame's requests.
The engine is not driven by the SPC700 timer. The shim's 512 Hz frame sequencer stays
timer-driven, as on the hardware.

- Engine tick N always sees exactly the requests in force at the game's Nth `handleAudio`
  call, so the comparison with the Game Boy is deterministic.
- What happens when the SPC700 has not acked the previous frame's message is defined by the
  protocol and tested. It is never left to chance.
- The 60.10 Hz SNES rate plays music 0.6% faster than the Game Boy's 59.73 Hz. That is
  accepted, since it is inaudible.
- The game reads the "playing" state back **one frame after** the message whose ticks set it. That
  latency is stated in the protocol, compared against when the Game Boy's game code reads the
  same variables, and verified. It is not assumed.

### The oracle is exact, and hearing is still the last rung

The GB core already captures what bank 4 writes to `$FF10`–`$FF3F`. With the same request
sequence, the SPC700 engine has to write **the same registers, in the same values and order,
on the same engine tick**. That is asserted byte for byte, like the rest of the port.
Past the register file, the shim's DSP output is already graded exactly against the
expected-value model. Fidelity of the result is still judged by ear, on hardware.

## Features

### A1. The CPU gate: lever 1, and a measured engine spike

The shim verdict's condition: no four-channel work until the load is re-measured after lever 1.
Moving the engine onto the SPC700 adds its own work, so that work is **measured on the SPC700**
before the rest of the engine is ported.

**Acceptance Criteria:**
- `sequencer_tick` pushes a voice to the DSP only when a sequencer event changed that voice
  (lever 1). The 0-disagreement result on the three captured tracks and seven corpus files
  still holds.
- The two-channel load is re-measured in resident mode on the FXPak Pro for `title`, `surface`
  and `attract`, against a recalibrated silent baseline, using the verdict's method.
- **The GB engine's per-frame cost is measured on the SM83** (T-cycles in bank 4's frame
  handler, per frame, for the three tracks). This is a lead for choosing what the spike has to
  cover, not a number anything is gated on.
- **The spike:** the engine's hot path is ported to SPC700: the per-frame loop and one
  channel's song processing, running real `surface` song data. Its cost is measured in the
  offline bench and on the FXPak Pro, and a four-channel figure is extrapolated from it and
  labelled as an extrapolation.
- **Gate:** the spike's extrapolated engine cost plus the measured shim cost is ≤ 50% on
  `surface`. If it isn't, the cycle stops here with a written finding. `title` is reported
  alongside it, not gated on (per the verdict).
- The spike's code is kept if it passes. It is not a throwaway.

**Out of Scope:**
- Pulling lever 2 (fed-mode drain). Fed mode is not used by the port.

### A2. CH3 wave and CH4 noise in the shim

**Acceptance Criteria:**
- CH3: `NR30`–`NR34` and wave RAM `$FF30`–`$FF3F`, with volume shift (`NR32`) and length.
  **Wave samples are BRR-encoded at build time, not on the SPC700.** The m2snes builder encodes
  every wave table bank 4 contains. The shim maps the wave RAM contents written to a
  precomputed sample by lookup, so register writes stay exact. Wave RAM contents with no
  precomputed sample are counted, and that count is readable from the bench.
- The shim's lookup table is generic (a table of wave contents → sample, supplied in the ARAM
  image). It contains nothing Metroid II-specific.
- CH4: `NR41`–`NR44`, with envelope and length as for pulse. The 15-bit and 7-bit LFSR modes
  and the clock divider map to a noise source and pitch. **The noise implementation is a
  choice this cycle makes and records** (S-DSP noise vs. looped LFSR BRR, per the verdict's
  predicted gap), and it is chosen by ear on the slice's actual noise uses.
- The expected-value model and the synthetic corpus are extended to CH3 and CH4, and DSP
  `PITCH`/`VOL`/source selection are asserted exactly.
- ARAM and CPU are re-measured at four channels against the shim's F3 budgets.
- **Mix headroom is decided here**, now that four channels exist (the verdict deferred it to
  this point). Clipping is measured on rendered slice tracks, and the chosen `MVOL`/per-voice
  scaling is recorded with its reasoning.

**Out of Scope:**
- DMG hardware quirks bank 4 never exercises.

### A3. Bank 4 on the SPC700

**Acceptance Criteria:**
- The Metroid II sound engine (M2RoS `bank_004.asm`) is rewritten in SPC700 assembly, with
  M2RoS as the behavioural spec, the way the rest of the port treats it. It covers:
  - song processing on all four channels,
  - SFX on each channel (square 1, square 2, wave, noise), with priority/preemption between
    SFX and music,
  - the song interruption and restore that the earthquake and item jingles use,
  - fades and stop.
- Its request interface is the original's request variables (`songRequest`,
  `sfxRequest_square1`, `sfxRequest_noise`, `songInterruptionRequest`, …), delivered with the
  tick count over `$2140`–`$2143`. The "playing" state the game reads back
  (`sfxPlaying_square1`, `songInterruptionPlaying`, …) is reported to the 65816. The protocol,
  including its one-frame read-back latency, is documented.
- **Exact against the GB:** for a scripted request sequence (song starts, SFX over music, SFX
  preemption, interruption and restore, stop), the offline bench runs the SPC700 engine and the
  GB core runs bank 4. Their register-write streams are compared per engine tick and must
  match byte for byte. The comparison reports the first divergent tick.
- **The read-back values are compared too:** the "playing" bytes reported per tick match the
  Game Boy's RAM values for the same tick.
- Song and SFX data are read from ARAM through the layout header (A4). The engine holds no
  song data.
- Every song and SFX id the slice can request is covered by the scripted comparison. The full
  id range is compared where the data extracts cleanly, and any id that is not is listed.

**Out of Scope:**
- Redesigning the engine, or any QoL audio change.

### A4. Where the code lives, and the m2snes wiring

**Acceptance Criteria:**
- **Every piece of code has exactly one home.**
  - **`snes_game_dev/audio/`** owns the generic GB-APU shim and its bench. It contains nothing
    Metroid II-specific.
  - **`m2snes`** owns the Metroid II sound engine source (SPC700 asm), the data extraction, the
    ARAM layout, the 65816 request side, and A3's comparison.
- **The shim reaches m2snes as a vendored binary package**, generated in snes_game_dev and
  committed to m2snes by a sync script (like `engine.bin`), with a manifest carrying the
  snes_game_dev commit and a sha256 per file. A hash or ABI-version mismatch fails the build
  with a named reason. A cart build needs no network fetch and no cargo. m2snes never carries a
  copy of the shim's source.
- **The shim's binary interface is versioned.** It exposes a fixed jump table (register write,
  version) and a layout header. In hosted mode the shim keeps its reset, main loop, timer and
  ports, and calls the engine through a tick vector once per counted tick. The header gives load addresses for engine
  code, song data, wave samples and the wave lookup table. The m2snes builder reads and checks
  the header version before placing anything. An incompatible header fails the build and never
  produces a cart that reads the wrong addresses.
- m2snes's rebuild-only dependencies are **`spc700asm`** (to reassemble the engine, with the
  assembled engine binary committed as `engine.bin` is) and **an SPC700 + S-DSP emulator** for
  A3's comparison. Both are fetched by script. Building a cart from a ROM still needs only the
  Zig builder and the ROM.
- The m2snes builder extracts bank 4's data from the user's ROM, lays out the ARAM image
  (shim + engine + samples + data), and injects it into the cart. The layout and its sizes are
  reported.
- **Boot:** the upload through the IPL has a bounded timeout. The upload's duration is
  measured and reported. On timeout the cart continues without audio and a debug readout says
  so. Debug readouts sit outside the 160×144 play window, so reference-frame conformance is
  unaffected.
- The recording stubs become real requests. The recorded values stay assertable, so 0b's
  existing conformance assertions on `!Song`/`!Sfx*` keep passing unchanged.
- The game's reads of "playing" state (e.g. `!Sfx1Playing`) come from the SPC700's reports,
  with the documented latency. Gameplay branches that depend on them stay in parity with the
  recorded reference trace.
- Sending requests costs the 65816 a bounded, measured number of cycles per frame and never
  blocks.
- m2snes changes land on `remote-init`, never `main`.

### A5. Verification and the listening pass

**Acceptance Criteria:**
- A3's register-stream comparison runs as a repeatable `zig build` step in m2snes. Where it
  needs the ROM or the fetched emulator, it skips with a named reason.
- The synthetic corpus and expected-value assertions for four channels run in snes_game_dev CI
  without a ROM.
- An audio A/B (F9) renders, for a named song or SFX id, the GB reference and the SNES result
  to adjacent WAVs.
- **Listening pass, per track and per SFX the slice reaches**, in Mesen2 and on the FXPak Pro,
  recorded in plain words ("sounds right" is a pass). This includes the earthquake interruption
  and restore and SFX over music during play.
- SPC700 load is measured on hardware during play on `surface` with SFX firing. Overruns are
  counted and shown in a debug readout.
- Audio bugs found in play are logged in m2snes `docs/bug_tracker.md` like any other 0b bug.

### A6. Documents amended

**Acceptance Criteria:**
- The port's `01-requirements.md` F8 is amended. The shim, with bank 4 on the SPC700, replaces
  TAD transcription. The decision table's Music/SFX rows and the "standalone repo, no shared
  code" row are updated (a vendored binary, not shared source), with the rationale and a
  pointer to this cycle and the shim verdict.
- m2snes `docs/feature_tracker.md` F8 and the 0b requirements' audio deferral are updated to
  match.

## Out of Scope (whole cycle)

- Music and SFX outside the 0b slice's reach, beyond what A3's full-id comparison covers
  for free.
- TAD, transcription, correction diffs, and BRR one-shot SFX (F8's original path).
- Fed mode as a runtime path in the port. It stays a bench instrument.

## Constraints & Dependencies

- **A1 gates A2–A5.** No wave/noise work or engine work beyond the spike happens before the
  gate has a number.
- **One home per piece of code** (A4). The generic shim lives in snes_game_dev, and Metroid
  II-specific code lives in m2snes.
- **No copyrighted bytes committed** in either repo. Song data, wave tables, captures, WAVs
  and `.spc` dumps are build products.
- SPC700 assembler: `spc700asm`, rebuild-only in both repos, with binaries committed.
- Reuse: the GB core's capture (`m2snes/src/gb/apu.zig`, `audio/gbcapture.zig`), the offline
  bench (`audio/bench.zig`), `shvc-sound-emu`, `tools/fxpak.sh`.
- ARAM ≤ 64 KB total. SPC700 CPU ≤ 50% during play (`surface`).
- Nothing automated can hear. The last rung is a person with speakers, on the console.
- 0b's bug sweep (Steps 20–27) continues in parallel. Audio work must not break 0b's gate or
  its recorded-trace parity.
