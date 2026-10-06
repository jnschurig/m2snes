---
created: 2026-09-02T05:18:59Z
updated:
  - 2026-09-02T05:18:59Z
  - 2026-09-02T05:37:00Z
  - 2026-09-02T05:42:22Z
  - 2026-09-02T17:13:52Z
  - 2026-09-02T18:54:00Z
  - 2026-09-03T02:26:01Z
  - 2026-09-03T04:42:58Z
  - 2026-09-03T04:50:23Z
  - 2026-09-03T05:07:42Z
  - 2026-09-03T22:44:00Z
  - 2026-09-04T04:18:39Z
  - 2026-09-04T05:15:16Z
  - 2026-09-04T05:47:13Z
  - 2026-09-04T05:48:10Z
  - 2026-09-04T19:57:39Z
working_directory: /Users/james/git/snes_game_dev
---

# Implementation Plan

## Status: Complete

## Overview

Get to the measurement as fast as possible, stop there if the number is bad, and
only then build anything. Then a pulse-only SPC700 shim, an offline bench that
makes it correct, and a bench ROM that lets a person judge it on a console.

Fourteen steps. **Step 4 is a hard gate** and Steps 5–14 do not begin until it
passes.

**The gate is deliberately cheap to reach.** Capturing a track needs only that
the game be *running* — boot it, drive a short scripted input sequence, record
what the sound driver writes. Locating the driver's song-init entry points is
open-ended reverse engineering that could take an hour or two days, and it buys
convenience rather than evidence, so it sits at Step 5, *after* the gate. Steps
1–4 are the fast path to the one number that decides everything.

Two steps exist so the work is testable without a commercial ROM (F6): Step 3's
original Game Boy test ROM and Step 7's synthetic log corpus. CI runs on
`ubuntu-latest` with no ROM and no `vendor/`, so without them none of this cycle
would be visible to it.

Everything lands under a new `audio/` directory — the one `PLAN.md` reserved and
never created.

## What already exists, and is therefore not built

Established by survey before planning; each is load-bearing for a step below.

| Piece | Where | Used by |
|---|---|---|
| `m2snes/src/gb/harness.zig` — a bootable SM83 machine, and `Call{bank, addr, regs, writes, budget}` running a routine to a sentinel return | `~/git/m2snes/src/gb/` | Steps 1, 5 |
| `assets/lzss.zig` — general LZSS, 2 KB window, 3–34 matches, compress + decompress, already validated against real FF6 data, so the codec is not itself a variable in the measurement | `assets/lzss.zig` | Step 4 |
| `spc700asm` — SPC700 assembler, MIT, `-o out.bin [-m mlb] src.asm`; TAD's own driver is the worked example of its syntax | `vendor/tad-src/crates/spc700asm` | Steps 9, 11 |
| `shvc-sound-emu` — cycle-accurate SPC700 + S-DSP; exposes ARAM, DSP regs, IO ports, `emulate()` | `vendor/tad-src/crates/shvc-sound-emu` | Step 10 |
| `runtime-pc/tadshim` — worked precedent for wrapping a `vendor/tad-src` crate as a C-ABI staticlib, **and proof the IPL ROM is not needed** (`iplrom = [0u8; 64]`, ARAM written directly, reset to an explicit PC) | `runtime-pc/tadshim/src/lib.rs` | Step 10 |
| `engine/bench.zig` — subsystem-agnostic on-screen bench: fields, readouts, actions, generated legend, all from a `Config` | `engine/bench.zig` | Step 13 |
| `ff6/audiobench_gen.zig` — the worked precedent for driving it | `ff6/audiobench_gen.zig` | Step 13 |
| `engine/tad.zig` — the S-SMP **IPL handshake already emitted in 65816**: upload bytes to ARAM and execute | `engine/tad.zig` ~line 293 | Step 13 |
| `update-goldens` — the sanctioned pattern for regenerating checked-in expectations | `build.zig` ~line 277 | Steps 7, 10 |
| The proving ROM | `.local/roms/Metroid II - Return of Samus (W).gb` | Steps 2+ |
| `rgbds` — installed locally, **not** in `mise.toml`, **not** in CI. Step 3 pins it as a rebuild-only tool and commits the assembled `.gb`, the way `m2snes` commits `engine.bin` and TAD commits `audio-driver.bin`. | new pin | Step 3 |

## Steps

- [x] **Step 1: Adopt the Game Boy core**

  - [x] Create `audio/` and `audio/gb/`. Copy the capture-relevant subset of
        `~/git/m2snes/src/gb/` — `cpu.zig`, `bus.zig`, `cart.zig`, `timer.zig`,
        `lcd.zig`, `apu.zig`, `system.zig`, `harness.zig`. Leave `ppu.zig`,
        `disasm.zig`, `probe.zig`, `sameboy.zig`, `blargg.zig` and `trace.zig`
        behind — none are on the capture path.
  - [x] Resolve `harness.zig`'s `probe.zig` import (it needs `probe.sentinel` and
        little else); inline what is needed rather than dragging the door-script
        prober across.
  - [x] **Pin the fork.** Each copied file's header names the source repo, the
        source **commit hash**, the date, and what was trimmed. A provenance note
        without a commit says where code came from but not whether it is current.
  - [x] **Add a drift check**: a step that diffs `audio/gb/` against
        `~/git/m2snes/src/gb/` when that path exists and reports divergence.
        Skips silently when it does not, so it never breaks CI or a fresh clone.
        This turns a silent fork into a visible one.
  - [x] Wire an `audio` module in `build.zig`; add its tests to `zig build test`.
  - [x] **Verify:** the copied core's own unit tests pass; booting a ROM for a
        fixed frame count twice produces identical state.

- [x] **Step 2: Capture by running the game**

  The cheap path to the gate. No reverse engineering: the game runs, the sound
  driver plays, we record what it writes.

  - [x] `audio/descriptor.zig` — minimal for now: ROM identification (header
        title + checksum) and a list of named captures, each a **scripted input
        sequence** (joypad state per frame) plus a capture window. Entry points
        come later, in Step 5.
  - [x] `audio/capture.zig`: boot, run the input script, and record every write
        to `$FF10`–`$FF26` / `$FF30`–`$FF3F` with frame and intra-frame cycle,
        via `apu.Apu.log`.
  - [x] Author input scripts for **two concrete starting tracks, named rather
        than described**: the title/menu theme (reached at boot) and the first
        surface/cave theme (reached with Start plus a few hundred frames of
        walking). Add a third once those two work and their character is known —
        "spanning the soundtrack's character" is something the captures tell us,
        not something we can assert in advance.
        *(Done: `title` 5.9 writes/frame, `surface` 1.9, `attract` 0.8. The
        third arrived in this step rather than later — it is reached by
        pressing nothing and waiting, so it cost one survey run. Confirmed
        distinct from `surface` by note sequence, not assumed.)*
  - [x] `zig build gbcapture -- <rom.gb>`. **ROM precedence, implemented once and
        shared by every ROM-taking step:** explicit argument, else the Metroid II
        ROM in `.local/roms/` if present, else Step 3's committed test ROM. The
        ROM is registered as a build file input so changing it invalidates the
        cache.
  - [x] **Every step prints which ROM it used, by name.** A precedence rule that
        resolves differently per machine is only safe if the machine says which
        branch it took.
  - [x] A ROM matching no descriptor → a named error listing the descriptors that
        exist. Not a crash, not a silent empty capture.
  - [x] **Verify:** capturing the same track twice yields byte-identical raw
        logs; a ROM with no descriptor produces the named error.

- [x] **Step 3: Original Game Boy test ROM** *(F6 — no copyrighted bytes)*

  Before the gate deliberately: if capture is wrong, Step 4 measures the wrong
  bytes and the gate decides on a meaningless number. A fixture whose register
  sequence we authored is the only way to show capture is *right* rather than
  merely repeatable — determinism alone proves only the latter.

  - [x] `audio/fixtures/gbtest/` — original SM83 source plus a minimal driver,
        assembled with `rgbds`. Two selectable tracks:
        - **track 0, register coverage:** every APU register, both envelope
          directions, sweep including the overflow mute, all four duties, the
          pitch range end to end, the `NR52` power bit.
        - **track 1, a short original tune**, composed for this purpose, so there
          is something to listen to that we are free to distribute.
  - [x] Commit the assembled `.gb`. Add `zig build gbtestrom` to rebuild it and
        pin `rgbds` in `mise.toml` as a **rebuild-only** tool. CI consumes the
        committed binary and never installs an assembler.
        *(rgbds is not in mise's registry and cannot be a `[tools]` pin, so the
        version lives in `[env]` as `RGBDS_VERSION` and `build.zig` warns on a
        mismatch. `rgbfix` is run with `-f hg`, not `-v`: the Nintendo logo is
        Nintendo's and this binary is committed, and the capture harness boots
        with no boot ROM so nothing checks it.)*
  - [x] Write its descriptor — the second entry in `descriptor.zig`, and the
        first real test that the mechanism holds more than one game.
        *(Its capture windows are computed from the track data rather than
        written down, so editing a track cannot leave a window too short.)*
  - [x] Emit, from the ROM's own source, the register sequence it is *known* to
        write, and compare the capture against it.
        *(One array in `tracks.zig` is compiled three ways: the ROM's byte
        table, the expected write sequence, and a decoder that reads the table
        back out of the committed `.gb` — so the binary and the expectation
        cannot drift apart silently either.)*
  - [x] **Verify:** in CI, with no ROM and no `vendor/`: capture from the test ROM
        matches the expected sequence exactly, and is byte-identical across runs.

- [x] **Step 4: Log format, encoder, and THE MEASUREMENT — the gate**

  > **Nothing past this step is written until this step has a verdict.**

  - [x] `audio/log.zig`: the three-stage format — raw (frame + intra-frame cycle
        + addr + value), quantized-and-delta-coded, LZSS-compressed — each stage
        separately readable and writable, with a version byte.
  - [x] **Derive the driver tick from the capture**: measure the period of the
        driver's write bursts across a track and report it with its evidence. Do
        not assume 60 Hz, and do not put a tick in the descriptor until it has
        been measured once.
  - [x] Quantize to that tick; emit only registers whose value changed.
        *(With two exceptions that would otherwise be silent bugs: `NRx4` with
        bit 7 set is a note-on rather than a value — 989 of `surface`'s 6961
        writes are exactly that — and an NR52 power-down zeroes the register
        file, so every shadow goes back to unknown.)*
  - [x] Compress with `assets/lzss.zig`. Report `zstd` alongside as a lower
        bound, labelled clearly as **not a shippable codec** — the 65816 has to
        decode this, and measuring with a codec the target cannot run would
        flatter the result into a GO it has not earned.
  - [x] Round-trip test in the unit suite: compressed → quantized byte-identical.
        Runs in CI on Step 3's fixture.
        *(And a stronger one: replaying stage 2 leaves the same register file at
        every tick as replaying the raw log, with the same note-ons and
        wave-DAC toggles. It found a real defect in its own first version.)*
  - [x] Report raw / delta / LZSS per track, plus the labelled full-soundtrack
        extrapolation.
  - [ ] **Contingency (did not fire — Step 2 reached three tracks):** F1 requires at least three tracks. If Step 2's input
        scripts cannot cheaply reach three, do Step 5 first and return here —
        that is the one condition under which song-init work comes before the
        gate, and it is a deliberate exception rather than a silent reordering.
  - [x] Write `03-measurement.md`: the numbers, the derived tick and its
        evidence, and the verdict against F1's budget (≤512 KB pass /
        512 KB–1 MB caveat / >1 MB stop).
  - [x] **Verify — the gate:** if the extrapolation exceeds 1 MB, stop, report,
        and do not start Step 5. **That is a successful Step 4.**
        *(**PASS.** 2.1 KB per measured track, 3.3 KB for the largest; 15 tracks
        extrapolates to 32–50 KB against a 512 KB pass line. Break-even is 238
        tracks. Steps 5–14 begin.)*

- [x] **Step 5: Song-init capture and the full track list**

  Convenience, not evidence — which is why it is here and not before the gate.
  Reaching an arbitrary track by input script is tedious and some tracks are not
  practically reachable at all.

  - [x] **Locate Metroid II's sound entry points in the ROM and confirm them
        against the ROM itself.** `m2snes` names `audio_initialize`,
        `audio_handle` and `audio_silence`; treat those as a lead to verify, not
        an answer to copy. Three `JP` trampolines at bank 4 `$4000`/`$4003`/
        `$4006`; which is which was settled by calling them and watching what
        they did, not by adopting the names. The request byte `$CEDC` and the
        latch `$CEDD` were found by watching WRAM while the game played itself.
  - [x] Extend the descriptor with entry points, the per-frame handler, and the
        track id list. `SoundDriver` holds the addresses; the *list* is read out
        of the ROM's own tables at capture time rather than transcribed, so it
        cannot drift from the ROM.
  - [x] Extend `capture.zig`: boot, `Call` the initializer, `Call` song-init for
        a track id, then step frames calling the per-frame handler. `runSong`.
        It switches the LCD off, because with it on the log's frame counter
        advances twice on about one call in thirty and the music comes out 3%
        slow.
  - [x] **Verify:** a track captured via song-init and the same track captured by
        running the game produce the same register sequence once both are
        quantized — which is what shows song-init is driving the driver the way
        the game does. `zig build gbsongs` checks all three named captures, and
        the raw logs match too: same addresses, same values, same frame spacing.
        The check was shown able to fail by pointing a capture at the wrong id.

- [x] **Step 6: Reference player — what it is supposed to sound like**

  - [x] Take the first of these that works, **with a half-day budget on (a)**
        before falling through:
        (a) SameBoy's Core built as a static lib, fed the captured log through
        its own APU write path — authoritative, and log-driven so it aligns with
        the shim by construction. **Note `Core/apu.c` includes `gb.h` and pulls
        the whole `GB_gameboy_t` in with it, so "link just the APU" may not be
        the small job it looks like**;
        (b) any standalone GB APU implementation with a feedable write API;
        (c) **record the game running in an ordinary Game Boy emulator.** The
        gate is a human ear, so (c) is a real answer, not a defeat.
        *(**(a), inside budget.** The warning was right — the APU does not come
        apart from the machine — so it was not taken apart: all 21 `Core/*.c`
        compile clean under our `build.zig`, with no RGBDS, no SDL and no
        changes to SameBoy. `audio/sbref.c` + `audio/gbref.zig`, pinned v1.0.2.)*
  - [x] Render references for the measured Metroid II tracks and for the test
        ROM's two tracks, into a gitignored output directory.
        *(All five, to `zig-out/audio/reference/` — gitignored via `zig-out/`.)*
  - [ ] **If (c) is taken, say so plainly in the docs**: the references are then a
        *manual, local, gitignored artifact* that a person re-records by hand
        after a change — not something the build produces. The test ROM's
        references can still be committed, since that music is ours.
        *(Not applicable: (a) was taken, so the references are reproducible from
        `zig build gbref` rather than hand-recorded. Left unchecked because the
        condition never arose, not because it was skipped.)*
  - [x] Record which option was taken and why the earlier ones were not.
        *(`audio/README.md`, "The reference player" — which option, why (b)/(c)
        were never reached, and what (a) buys: reference and shim consume the
        identical log by construction.)*
  - [x] **Verify:** the reference audio is recognisably the track, by ear.
        *(**PASS**, by the user, 2026-09-03: "very accurate sounding and
        immediately recognizable". This is the step's real gate and it is the
        one thing here that could not be self-certified. The machine's half
        agrees: pulse-1 pitch matches the log on 17/17 `title`, 34/34
        `attract`, 281/281 `surface`, 5/5 `coverage`, 30/30 `tune`, and the
        check was shown able to fail — a 6%-fast render drops those to 3/7,
        21/40 and 63/212 and fails the build.)*

- [x] **Step 7: Synthetic log corpus and the expected-value model** *(F6)*

  - [x] A readable text form for authoring register-write logs directly, and a
        compiler from it to the log format. The log — not a ROM — is the shim's
        real interface, so an authored log is a first-class input, not a mock.
        *(`audio/corpus.zig`. Two commands, `wait` and `reg = value`; hex,
        binary and decimal. No note, channel or pitch — those are a driver's
        concepts, and inventing them would test our idea of a note rather than
        the hardware's idea of a register. Writes get spaced 24 T-cycles apart
        inside a frame so `absTime` stays strictly increasing and the tick
        derivation is not reading simultaneous events no machine could produce.)*
  - [x] Author the coverage corpus: every register, both envelope directions,
        sweep including overflow mute, all four duties, the pitch range end to
        end, the power bit, and the note-on burst pattern.
        *(Seven files in `audio/fixtures/corpus/`, each isolating one unit so a
        failure points at one. `corpus_test.zig` asserts the coverage claim
        against the parsed writes — including all 39 addresses — so the list
        cannot quietly stop being true.)*
  - [x] `audio/expect.zig`: compute expected DSP `PITCH` and `VOL(L/R)` for a
        synthetic log from the published GB formulas. **Only ever applied to
        synthetic input**, where the correct answer is known by construction —
        never to captured music, where it would be our arithmetic grading our
        arithmetic against our own reading of the same spec.
        *(Enforced structurally, not by comment: `expect` takes a
        `corpus.Program`, which only `corpus.parse` produces. Captured music is
        a `capture.Result`, so pointing the model at Metroid II is a compile
        error rather than a judgement call somebody makes under deadline.)*
  - [x] Store expectations as a checked-in golden, regenerated through
        `zig build update-goldens`, following the existing pattern.
        *(`audio/corpus.golden.txt`, written by `gbcorpus --golden` the way
        gfxgen and fontgen write theirs. A change log — a row only where the
        expectation moved — so a diff points at the frame behaviour changed.)*
  - [x] **Verify:** the corpus compiles, round-trips, and its goldens are stable;
        all of it runs in CI with no ROM and no `vendor/`.
        *(All seven parse and round-trip through parse→print→parse; the golden
        is byte-identical across regenerations. The no-ROM/no-`vendor/` claim
        was checked in a clean tree built the way `tools/ff6-standalone.sh`
        builds one — and shown non-vacuous: corrupting one golden value fails
        the test there.)*

  **A measurement Step 8 inherits.** The design doc estimated that a 32-sample
  BRR period saturates `PITCH` "at about 4 kHz". `pitch.gblog` brackets it:
  2048 Hz gives 8388, 4096 Hz saturates. So a 32-sample period covers the range
  to 2 kHz, and Step 8's "how many period lengths" is now a measurement rather
  than the doc's estimate.

- [x] **Step 8: Square-wave BRR sample banks**

  - [x] `audio/samples.zig`: looped square-wave BRR for the four GB duties
        (12.5 / 25 / 50 / 75%) at the period lengths the pitch range needs. Start
        from the design doc's 32 / 16 / 8 and let the `PITCH` range calculation
        decide the real set.

        The set is 32 / 16 / 8, and the calculation says so rather than the doc.
        Two constraints fix the candidates: a period must be a multiple of eight
        (a duty *is* an eight-step pattern; four samples cannot express 12.5%),
        and the loop must be a whole number of 16-sample blocks. 8 samples is one
        block holding two periods, which is how a period shorter than a block is
        reachable at all. 12 samples, 144 bytes, built at comptime.

        Nibble levels are chosen for **zero DC**: `+(8−h)` and `−h` for a duty
        high on `h` of eight steps. Mean exactly zero, span exactly eight for
        every duty. The Game Boy's output capacitor removes its offset; the
        S-DSP has no capacitor, so an uncentred wave would carry the offset into
        the mix and click on every key-on.

  - [x] BRR filter 0 with a fixed shift, so encoding is a nibble-pack rather than
        a compression search. Emit the DSP sample directory entries too.

        Shift 12 — the largest the DSP treats as a shift at all, and at twelve
        nothing in the bank reaches the decoder's 15-bit ceiling. The directory
        is a function of an ARAM base rather than a baked address: Step 9 owns
        the memory map.

  - [x] Compute `PITCH` for each (GB frequency, period length) pair and confirm
        nothing in the GB's range saturates 14 bits — this determines how many
        period lengths are actually required.

        All three lengths are required, and the "nothing saturates" form of the
        claim turns out to be unachievable and not worth achieving. Periods
        2040–2047 saturate at every length, and they ask for 16384 Hz and up —
        above the DSP's own 32 kHz Nyquist, so no encoding reproduces them. The
        table (0–2015 → 32, 2016–2031 → 16, 2032–2039 → 8) covers everything the
        SNES can play; a fourth length would chase arithmetic, not music.

        This also caught a real defect in Step 7's `expect.zig`: it computed
        frequency first and `PITCH` second, and the intermediate truncation cost
        a unit of `PITCH` at the top of the range. Fixed by substitution. No
        value in `corpus.golden.txt` moved — the corpus never reached a period
        where it mattered, and Step 11's shim would have.

  - [x] **Verify** what can be verified without the DSP: the bank's shape —
        levels, headers, loop flags, the duty ratio and period of the nibble
        stream, the selection thresholds — plus the cross-check against
        `expect.zig`, and the golden shown non-vacuous by corrupting it.

        The DSP half of this sub-task **moved to Step 10**, where the emulator
        that can answer it lives. It is not a loose end here: a check that reads
        the nibbles back with our own idea of BRR cannot catch a misreading of
        BRR, so there was never a version of it Step 8 could pass honestly.
        `samples.golden.txt` is the fixed target Step 10 grades against.

  - [x] Generated by our own code from first principles; nothing from any ROM.

        And the mapping is stated **twice** — `samples.zig` and `expect.zig` do
        not import each other — because Step 11 grades the shim's `PITCH` against
        `expect.zig` while the shim's table comes from `samples.zig`. Wiring them
        together would make that comparison tautological. A test asserts they
        agree across all 2048 periods and all three lengths.

- [x] **Step 9: SPC700 shim — skeleton, register file, timer, instrumentation**

  - [x] `audio/gbapu/shim.asm`, assembled by `spc700asm`. Follow TAD's
        `audio-driver/src/` for house style (`.include`, `.codebank`, `.proc`,
        `.assert`, `.p0`). Write our own `registers.inc` rather than including
        TAD's zlib file, keeping the licence boundary clean.
  - [x] Memory map: shim code, virtual GB register file, sample banks, DSP sample
        directory, and the ARAM-resident log buffer — fixed addresses with
        `.assert`ed bounds.
  - [x] **512 Hz frame sequencer off Timer 2, divisor 125.** This is the only
        choice that works: Timers 0 and 1 run at 8 kHz and 8000/512 = 15.625, so
        neither can produce an exact 512 Hz. Timer 2 runs at 64 kHz and
        64000/512 = 125 exactly, which fits the 8-bit divider. Picking an 8 kHz
        timer would bake a permanent 0.4% drift into every envelope and sweep.
        `.assert` the arithmetic rather than commenting it.
  - [x] Derive length 256 Hz, envelope 64 Hz and sweep 128 Hz from that tick.
  - [x] **Two input modes**, because the shim has two consumers:
        - **fed** — `(register, value)` pairs arrive through `$F4`–`$F7` with a
          handshake, into a ring buffer the main loop drains. This is what the
          bench ROM and the offline bench use.
        - **ARAM-resident** — a pointer walks a log already in ARAM, with no
          external feed at all. **This is what makes a `.spc` dump possible**: an
          `.spc` is autonomous, and nothing exists to feed it. Without this mode
          the Step 12 `.spc` deliverable cannot work.
  - [x] **Define and implement the overrun policy** (F3): what happens when a
        frame's writes plus sequencer work exceed the time available, plus a
        counter at a fixed ARAM address recording it.
  - [x] **Build the CPU-cost instrument now, not in Step 14**: an idle-loop
        counter at a fixed ARAM address, incremented in the main loop's spare
        time, so load is `1 - (counter / silent-baseline counter)`. Discovering
        this at measurement time would mean modifying the shim after it has been
        graded.
  - [x] `zig build spcshim` invoking `spc700asm`, emitting binary and `.mlb`,
        following the `tad-compiler` cargo-step pattern.
  - [x] **Verify** what assembling can settle: it assembles clean, and the
        assertions were shown non-vacuous — misaligning `DSP_DIR_ADDR` and
        setting timer 2's rate to 8 kHz both fail the build, and shrinking the
        code bank is caught by the assembler itself. `gbapu.zig` mirrors the map
        and a test parses `memmap.inc` to check every constant, shown
        non-vacuous by moving `LOG_RING_ADDR`.

        **The running half moved to Step 10**, where the emulator that can
        answer it is built: boots, reaches its idle loop, acknowledges a fed
        register write, walks an ARAM-resident log, and the idle counter moves
        against a recorded silent baseline.


- [x] **Step 10: Offline bench harness — the first machine that runs the shim**

      *Was the first half of Step 11. Promoted ahead of the pulse channels
      because Step 9 already deferred its running verify to "the step that can
      run it", and the old Step 10's only verify — the corpus producing exact
      `PITCH` and `VOL` — needed that same machine. A step whose verification
      lives in a later step is a step that is not verified, and the arithmetic
      of the pulse channels is the last thing in this cycle that should be
      written without execution feedback.*

  - [x] `audio/spcshim/` — a small Rust C-ABI staticlib over `shvc-sound-emu`,
        modelled on `runtime-pc/tadshim`: load an ARAM image, reset to a PC,
        write IO ports, `emulate()` a buffer, read DSP registers, dump ARAM.
        Generic; no TAD dependency.
  - [x] `audio/bench.zig`: the Zig side. Build an ARAM image from the assembled
        shim, the Step 8 sample bank and directory, and a configuration block —
        the placement `gbapu.zig` already describes, applied for the first time.
  - [x] Feed logs **through the IO ports**, not by poking ARAM, so the offline
        bench exercises the same handshake the bench ROM will use. Poking ARAM
        would leave the handshake untested until Step 13, where a fault is
        ambiguous between shim, feed and console.
  - [x] `zig build gbbench`, skipping with a named reason when `vendor/tad-src`
        is absent, per the FF6 vendor-independence invariant.
  - [x] **Verify (moved here from Step 9):** the shim boots, reaches its idle
        loop (`STATS__RUNNING` becomes `$5a`), acknowledges a fed register write
        through the port handshake, and walks an ARAM-resident log to its end.
        Record the silent-baseline idle counter here too — Step 14's CPU-load
        figure is `1 - (counter / baseline)` and is meaningless without it.
        Nothing before this step has run a single SPC700 instruction; until it
        does, the shim is only known to assemble.
  - [x] **Verify:** assert the sequencer rate is 512 Hz against the emulator's
        cycle count. Exact, cheap, and wrong-by-construction if it drifts.
  - [x] **Verify (moved here from Step 8):** the real S-DSP decodes each of the
        twelve BRR samples into a square wave of the intended duty and period.
        Decoded by the DSP, not by a decoder of ours — otherwise a misreading of
        BRR passes both sides. Grade against `audio/samples.golden.txt`, which
        Step 8 checked in for exactly this. This is the *only* thing that has
        ever confirmed the sample bank is what it says it is; if it ships
        without this, the bank remains ungraded no matter how green Step 8
        looks. It belongs here and not later because Step 11 selects samples out
        of that bank, and a wrong note is easier to read when the bank under it
        is known good.

- [x] **Step 11: SPC700 shim — the two pulse channels**

      *Was Step 10. Unchanged in content; it now runs on the machine Step 10
      builds.*

  - [x] Pitch: `f = 131072 / (2048 - x)` → DSP `PITCH`, with period-length
        selection by octave. Table-driven; a division does not belong on a 1 MHz
        CPU at 512 Hz. **The table is generated by `samples.zig`**, which states
        the mapping independently of `expect.zig` — that independence is what
        makes the verify below evidence rather than a tautology, and it is why
        Step 8 wrote the mapping out twice.
  - [x] Duty from `NR11`/`NR21` bits 7–6 → sample bank selection.
  - [x] Envelope from `NR12`/`NR22` at 64 Hz → DSP `VOL(L/R)` directly. No ADSR.
  - [x] Sweep from `NR10` at 128 Hz, including the overflow mute.
  - [x] Length counters at 256 Hz; the `NR52` power bit.
  - [x] `NR51` panning → full-or-zero `VOLL`/`VOLR`; `NR50` master volume scaling
        both sides.
  - [x] Key-on / key-off on channel trigger (`NRx4` bit 7). Voices 0 and 1 only;
        voices 2–7 untouched.
  - [x] **Verify:** Step 7's synthetic corpus, fed through Step 10's harness,
        produces exactly the `PITCH` and `VOL` `expect.zig` predicts — asserted
        in the test suite, per corpus file, on the real S-DSP's registers.

- [x] **Step 12: Grading a captured track — WAV, `.spc`, and the ear**

      *Was the second half of Step 11.*

  - [x] `audio/grade.zig`: run a captured log through the bench, render the
        shim's output to WAV, and place it beside Step 6's reference for the
        same track. Same track names in `zig-out/audio/graded/` and
        `zig-out/audio/reference/`; `wav.zig` is shared so the pair cannot
        disagree about its own format.
  - [x] Dump DSP `PITCH` and `VOL(L/R)` over time beside values computed from the
        GB log — **diagnostic on captured music, asserted on synthetic input.**
        The assertion is Step 11's; this is the read-when-something-sounds-wrong
        half of the same instrument.

        **It earned its keep on the first run.** Metroid II disagreed with the
        model at 89% of comparable moments on `surface`, and the dump said the
        envelope was one step late at four seconds and two at nine — a late
        answer, not a wrong one. The shim decremented its log-wait counter
        inside the tick catch-up loop, where a decrement at zero throws the tick
        away, so every moment it ran late moved the rest of the log a tick
        further out: over a second lost in a minute, heard as tempo. Fixed by
        counting ticks (`logDue`) and letting the log spend them. **Seven
        synthetic corpus files could not have found it** — none of them makes
        the shim late — and the Step 11 grade stayed at zero throughout. A
        driver-shaped synthetic load now guards it, asserted both to agree
        everywhere and to genuinely overrun.
  - [x] Dump a playable `.spc` for an excerpt, using Step 9's **ARAM-resident
        mode**: ARAM image plus register state in the standard header. Snapshot
        taken at reset, because in resident mode that is a complete description
        of the run — and because the emulator exposes only PC, so a mid-run dump
        would have to invent A/X/Y/PSW/SP.
  - [x] `zig build gbgrade -- <rom.gb>`, with Step 2's ROM precedence, skipping
        with a named reason when `vendor/tad-src` is absent.
  - [x] **Verify:** the `.spc` plays in an ordinary SPC player and sounds like the
        WAV the bench rendered.

        **Both halves done, and they are different kinds of evidence.**

        The machine's half, by test: the `.spc` is written, parsed back, loaded
        the way a player loads one — ARAM verbatim, 128 DSP registers in order,
        CPU started at the header's PC — rendered, and required to produce
        samples **identical** to the bench's. That settles that the file carries
        the whole machine, which is the half that fails silently.

        The ear's half, by a person: the tracks were played in an SPC player and
        judged to sound good (2026-09-04). No SPC player is installed on this
        machine, so nothing here could have stood in for that — which is the
        point of the step.

- [x] **Step 13: Bench ROM**

  - [x] `audio/benchrom_gen.zig`: an `engine.bench.Config` — SONG and EXCERPT
        fields; readouts for shim state, playback position, deferred writes and
        overruns; actions for start / stop / restart — following
        `ff6/audiobench_gen.zig`.

        EXCERPT is seconds to play, `00` meaning the whole track, defaulting to
        the 20 the `.spc` covers. L and R walk the catalogue as well, so three
        tracks can be compared without moving the cursor.
  - [x] Upload shim and sample banks to ARAM via the IPL handshake, reusing the
        sequence `engine/tad.zig` already emits. A ~1 s load stall is acceptable
        and is stated on screen, as the FF6 bench does.

        **8 frames, not a second.** 5706 bytes as five blocks straight through
        the boot ROM; TAD's two-stage loader exists for megabytes of samples and
        buys nothing here. `LD` states it anyway. One build-time assert replaces
        a runtime trap: a block length ending in `$FE` makes the next block's
        start byte zero, which is what the boot ROM waits for to begin sending.
  - [x] **The shim publishes what the S-CPU cannot read.** *(Not in the plan as
        drafted, and unavoidable: F5 asks for the shim's overrun count on
        screen, and the S-CPU cannot read ARAM.)* Three counters mirrored onto
        the three ports the handshake's reply does not use, plus a `$5a` on port
        3 at the end of boot that is both the liveness signal and the first
        acknowledgement. Safe because a port is two latches at one address —
        asserted in `gbbench.zig`, not assumed, since a wrong answer would break
        only on hardware. Costs 2.4% of the silent baseline.
  - [x] **Bounded, non-blocking feed:** a fixed cycle budget per frame; writes
        that do not fit defer to the next frame and increment a counter. Never
        spin on the handshake.

        A ceiling on 65816 time, not a cost: the loop stops when the owed ticks
        are spent. Measured across five budgets against the densest track — 1024
        polls cannot keep up at all, 4096 (a third of a frame) is the knee, and
        the ceiling is set by the shim taking one pair per main-loop pass rather
        than by the ports. Time owed is counted and carried, never dropped,
        which is Step 12's lesson on the other side of the wire.
  - [x] Readouts distinguish the three silences: shim not up / no log loaded /
        log playing and the shim driving voices.
  - [x] Bake the same track and excerpt Step 12 rendered.

        Byte-for-byte: the same `benchlog.program` and `benchlog.compile` on the
        same capture, asserted by recompiling in a test. `benchlog` is where
        `grade.program` moved to, because the ROM generator cannot link the
        emulator `grade.zig` is built on.
  - [x] `zig build audiobench -- <rom.gb>` producing `.sfc` + generated Mesen2
        Lua, with Step 2's ROM precedence — so the bare form builds a working
        bench from the test ROM on a machine with no commercial ROM.
  - [x] A smoke-test Lua asserting boot, draw, and shim-responded — **whose own
        header states it cannot assert audibility.**

        It walks the whole control map and both ends of the feed, and asserts
        the log is not falling behind. It does not assert `OVR` is zero: the
        shim overruns under playback load, Step 12 measured that offline before
        this ROM existed, and pinning it here would fail on a property of the
        shim. Shown non-vacuous by two breaks — no execute command (65), and a
        budget of 8 polls (88).
  - [x] **Verify:** `zig build audiobench` then the Mesen2 smoke test exits 0;
        then listen in Mesen2.

        Build and smoke test: green. `zig build test`, `zig build conformance`
        and `tools/build-gate.sh` are green with nothing retired. **The listening
        pass is still owed** — it is a person's, and it is the same ear Step 14
        needs on hardware.

        The gate script itself was exiting 1 on success: its last statement is
        an `if` whose test is false when everything passed, and a script's status
        is its last command's. Fixed with an explicit `exit 0`.

- [x] **Step 14: Hardware pass and the go/no-go writeup**

  - [x] Deploy to the FXPak Pro with `tools/fxpak.sh deploy` and listen on the
        console.

        **All three tracks judged good by ear on hardware.** Boot, upload and
        draw all correct; the load stall is 8 frames on console exactly as in
        Mesen2.
  - [x] Record ARAM cost from `spc700asm`'s output, with the labelled
        four-channel extrapolation.

        **6120 bytes fixed, pulse-only** (1402 of it code, 4096 of it the pitch
        table); **~9500 estimated at four channels**, leaving ~55 KB for
        streaming buffers. ARAM is not the constraint. The bound worth watching
        is the code region: `$0200`-`$0e00` is 3072 bytes and the four-channel
        estimate uses 72% of it, with `STATS_ADDR` as a hard ceiling that the
        map could move if it came to that. Table and per-line assumptions in
        `audio/README.md`, "What it costs".

        Noted there as a fidelity decision rather than a size one: CH4's 15-bit
        LFSR has a 32767-sample period, 18.4 KB of BRR. A 4096-sample loop is
        2304 bytes and repeats audibly at low rates. Not this cycle's call.
  - [x] Read SPC700 CPU load from Step 9's idle counter against the silent
        baseline Step 10 recorded, under the busiest track. Document the method
        and its limitations.

        `grade.Run` now counts idle passes from after boot and divides by the
        baseline for the mode it ran in; `gbgrade` prints a `load` column.
        **`title` 57.1%, `surface` 43.0%, `attract` 39.5%** — the busiest track
        is over F3's 50% budget.

        The baseline Step 10 recorded is the *fed* machine's, and every track is
        graded resident. Those idle at different rates — 7198/s against 6460/s,
        because an idle resident pass does a 16-bit `cmpw logPtr, logEnd` where
        a fed one does an 8-bit `cmp A, lastSeq`. The first run of this sub-task
        divided resident measurements by the fed baseline and reported `title`
        at 61.5%. `bench.silent_baseline_idle_hz` now holds one constant per
        mode, with a test that each still matches the shim and a second test
        asserting the gap is real so the two are not merged back.

        Limits, stated where the constants are: a pass is not a fixed unit of
        time, so this is a ratio of work to reference work — good enough for
        "does another channel fit", not for costing instructions — and time
        inside a single long pass is counted once.
  - [x] Record deferred writes and overruns per frame from the bench ROM.

        On hardware, whole tracks, two runs each: `title` 228 frames over budget
        of 3260 (7.0%) and **6800 overruns, 125/s — 24.5% of its ticks**;
        `surface` 384 of 3604 (10.7%), 1913 overruns, 32/s; `attract` 117 of
        4703 (2.5%), 912 overruns, 12/s. **`DROP` zero everywhere, and `SENT`
        equalled the shim's applied count to the byte on all six runs.**
        Console and Mesen2 agree on every reproducible counter.

        Two defects in the instrument, both found here and both fixed:

        `OVR`, `DROP` and `APLY` were published as the low byte of 16-bit
        counters. `title` overruns into the thousands, so the readout wrapped
        six or seven times a track and showed a different value every run of the
        same music. The shim has four ports and no room, so the width is
        recovered on the S-CPU side: `emitAccum` accumulates
        `(now - last) & $ff` each frame, exact for any advance under 256, and
        overruns can advance at most 8.5 a frame. Rebaselined on START so the
        numbers are per-track, and gated on `ST` so the boot ROM's handshake
        bytes are not accumulated as counts.

        `APLY` was then shown redundant by its own measurement, so port 2 now
        carries the second byte of `STATS__IDLE` instead — the only way to get a
        **fed-mode** load figure on real hardware. The offline 57.1% is resident
        mode on an emulator that structurally cannot drive a fed track: its 8 ms
        step tops the fed path out at 125 writes a second and `title` needs 350.
        A `FRM` readout counts frames past the end of the log, so one run gives
        both the busy and the at-rest rate on the same console.

        Smoke test gained an assertion the byte-wide readout could not carry —
        `IDLE` still climbing under sustained playback, i.e. the shim is loaded
        and not saturated. Shown non-vacuous: reverting `emitAccum` to the old
        copy fails at 88.
  - [x] Write `04-verdict.md`: the F1 numbers, ARAM and CPU against F3's budgets,
        the per-track listening verdict naming Mesen2 or hardware or both,
        observed fidelity gaps separated from predicted ones and from unfixed
        bugs, and a stated GO / NO-GO / GO-WITH-CAVEATS.

        **GO-WITH-CAVEATS.** F1 passes by two orders of magnitude; ARAM passes
        comfortably; **CPU fails on `title` at 91.1% fed on hardware, with two
        of four channels implemented**. Not a NO-GO because the 91% is not a
        property of the approach: `sequencer_tick` pushes the DSP unconditionally
        every tick though length/sweep/envelope run at 256/128/64 Hz, and Step 11
        measured that push at 35% of the idle loop with nothing playing. The GO
        carries a hard condition — no four-channel work until the load is
        re-measured after that lever is pulled.
  - [x] Regenerate the plan site (`plan.html` / `plan-progress.js`) via the
        `plan-site` skill, since this cycle adds docs and completed work.

        `audio/README.md` added to `DOCS` in `tools/gen-plan-docs.py` and
        `plan-docs.js` regenerated (24 docs). P4 gained an appended task —
        "GB APU → SPC700 shim" — with `p4_4: true` in `plan-progress.js`
        carrying the verdict's three headline numbers. Task order untouched.
  - [x] **Verify:** `zig build test` passes, CI is green with no ROM present, and
        the `verify-gate` ladder is green with nothing retired.

        Ladder green end to end: `zig build test` 0, `zig build conformance` 0
        (11 scenarios, 3869 dispatches), `tools/build-gate.sh` 0, and the bench
        ROM's Mesen2 smoke test 0. Nothing retired; the smoke test gained two
        assertions this step (`IDLE` climbing under load, and the at-rest window
        closing), both shown non-vacuous by deliberate breaks — 88 and 93.
