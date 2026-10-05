---
created: 2026-09-16T18:00:19Z
updated:
  - 2026-09-16T18:00:19Z
  - 2026-09-16T18:07:39Z
  - 2026-09-16T18:24:28Z
  - 2026-09-17T01:16:54Z
  - 2026-09-17T02:53:04Z
  - 2026-09-17T03:30:49Z
  - 2026-09-18T00:22:42Z
  - 2026-09-18T02:15:47Z
  - 2026-09-18T19:13:05Z
  - 2026-09-21T02:27:19Z
  - 2026-09-21T02:47:07Z
  - 2026-09-21T02:54:22Z
  - 2026-09-21T03:40:53Z
  - 2026-09-21T22:21:07Z
  - 2026-09-22T02:09:32Z
  - 2026-09-22T03:18:00Z
  - 2026-09-22T03:49:45Z
  - 2026-09-22T04:29:59Z
  - 2026-09-22T04:57:41Z
  - 2026-09-22T16:01:52Z
  - 2026-09-22T18:30:50Z
  - 2026-09-22T19:11:41Z
  - 2026-09-24T18:28:29Z
  - 2026-09-24T19:10:27Z
working_directory: /Users/james/git/snes_game_dev
---

# Implementation Plan

## Status: Complete

## Overview

Pull lever 1, then build the smallest path to a **measured engine spike on the SPC700**. That
path is the shim's plug-in interface, m2snes's SPC700 toolchain, bank 4's data, and the exact
comparison harness. **Step 7 is the gate.** Nothing after it starts until it passes. Past the
gate, the plan finishes the shim's four channels, ports the rest of bank 4 in slices (each
graded byte for byte against the Game Boy), wires the cart, and ends with a listening pass
on hardware.

Repos: steps marked **[sgd]** land in `snes_game_dev`, and steps marked **[m2]** land in
`m2snes` on `remote-init`.

## Facts the design rests on (surveyed)

| Fact | Where | Consequence |
|---|---|---|
| `handleAudio` runs from `waitOneFrame` in the main loop, **not** VBlank. It is also called from wait loops (`gameMode_dead`, `handleItemPickup_end`, …) | M2RoS `bank_000.asm:7355`, `:9490`, `:9988` | A lockstep tick is **one `handleAudio` call**, not one NMI. The 65816 counts calls in a frame and sends that count. |
| The game reads engine state: `songPlaying` (6 sites), `sfxPlaying_square1` (2), `sfxPlaying_noise` (1), `sfxPlaying_lowHealthBeep` (1), `songInterruptionPlaying` (3) | banks 0–2 | These five bytes are the read-back set. Each read site's timing relative to its tick is surveyed (Step 16b). |
| The game **writes** `songInterruptionPlaying` directly | `bank_001.asm:4057` | The protocol needs a "set engine variable" message, not just requests. |
| `audioPauseControl` pause and unpause | `bank_000.asm:7471–7526` | The pause is part of the engine port. |
| Bank 4 is ~2,600 instructions, with per-SFX init/playback routines as code | `bank_004.asm` | A3 is split into four steps (12–15). |
| The shim owns reset, the main loop, the timer and the ports. Its direct page is nearly full (`GB_REGS` ends at `$B0`) | `audio/gbapu/memmap.inc` | The engine plugs into the shim through a jump table and a tick vector. The shim stays generic. |
| `shim.bin` is a build product (needs cargo), not committed | `build.zig:1770` | m2snes receives a **generated package**, synced and hash-pinned (Step 4). |
| `image.zig`'s `Segment` list is the single statement of ARAM placement | `audio/image.zig` | The hosted-mode image and the package's layout extend it rather than restate it. |

## Steps

- [x] **Step 1: Lever 1: push only what changed** [sgd]
  - [x] Per-voice dirty bits in `shim.asm`: `tick_length`, `tick_sweep` and `tick_envelope`
        set a voice's bit only when they change its state. `sequencer_tick` calls
        `apply_voices` only for dirty voices. The `STATS__BUSY` bracket keeps its meaning.
  - [x] `zig build gbbench` and `zig build gbgrade` (title, attract, surface): 0 disagreements
        with the model, per tick, on all three tracks and all seven corpus files.
  - [x] Recalibrate the resident silent baseline (keeping the "two baselines are different"
        test), and re-measure offline resident load for all three tracks.
  - [x] Hardware: `audiobench` on the FXPak Pro, fed mode (the bench ROM's only mode, and
        the verdict's method), two runs per track.
  - [x] Record the before/after table in `03-measurements.md` (this directory).

- [x] **Step 2: What the engine costs on the Game Boy, and what the slice asks for** [m2]
  - [x] `zig build audiocost`: on the harness, song-init each of title/surface/attract. Call
        `handleAudio` once per frame for 30 s and record the T-cycles per call (max, p95,
        mean). Also record an SFX-over-music case (surface plus a scripted missile/beam/enemy
        SFX burst).
  - [x] Attribute the cycles to routines with the harness's execution watch, to show which
        path the spike has to cover.
  - [x] Enumerate every song, SFX and interruption id the slice can request: from
        `engine/main.asm`'s `!SFX_*`/`!Song` constants and from the recorded reference trace's
        request stubs. Commit it as `docs/audio_ids.md`, with each id's source.
  - [x] Record the costs in `03-measurements.md`, labelled as SM83 measurements that are a lead
        and not a gate.

- [x] **Step 3a: The shim's plug-in interface: hosted mode, jump table, trace** [sgd]
  - [x] Re-cut `memmap.inc` for hosted mode. Add regions for engine code, engine RAM (its own
        page, not the shim's direct page), engine data, and a write trace buffer, with every
        bound `.assert`ed and mirrored in `gbapu.zig` plus its parse test.
  - [x] A fixed jump table at `SHIM_CODE_ADDR`: `shim_write_reg` (X = `addr - $FF10`, A =
        value), `shim_version`, and a versioned **layout header** (engine code/RAM/data
        addresses, sample directory, wave lookup table, trace buffer).
  - [x] `CONFIG_MODE__HOSTED`: the main loop keeps the timer and sequencer. When a frame
        message completes it calls the engine's tick vector once per counted tick, passing the
        message bytes (one tick per main-loop pass). Fed and resident modes are unchanged.
  - [x] The port message format is documented in `memmap.inc` (decided 2026-09-17, since the
        four reply ports cannot hold five read-back bytes, an ack and a latched load readout
        at once). **Chunks:** P0 = chunk counter (bit 7 = the first chunk of a message),
        P1–P3 = three stream bytes. **Message:** sequence byte, tick count, then **one record
        per tick**, `len` + `len` bytes (request bytes and set-variable ops in force at that
        `handleAudio` call). The shim reads only the lengths. **Reply:** each chunk's ack
        echoes the counter on P3 and puts 3 bytes of a 12-byte reply on P0–P2, the k-th
        chunk's page being bytes `3k..3k+3`. The reply is copied when a message's first chunk
        is taken, so all its pages match: the last completed message's sequence byte, the
        engine tick counter (u16), overruns, idle bytes 1–2, and 6 engine reply bytes. A first
        chunk isn't taken while the previous message's ticks are still running.
  - [x] The busy rule, documented with the format: the 65816 never merges two ticks' records.
        While a message is unacked it holds it and queues later ticks' records in a bounded
        pending queue, sent in order once acked. Queue overflow is counted and shown in the
        debug readout, and never blocks.
  - [x] Write trace: when `CONFIG__TRACE` is set, `shim_write_reg` appends `(tick, reg,
        value)` to the trace buffer, and the bench drains it.

- [x] **Step 3b: `spcrun` and the shim package** [sgd]
  - [x] `zig build spcrun`: a CLI over `spcshim`. It loads an image, sends a scripted
        message per frame, and emits the per-tick write trace and read-back bytes as text. It
        also reports the idle counter for load. `--ack-delay <frames>` makes it withhold acks,
        to exercise the busy rule.
        *(Done: `audio/spcrun.zig` → `zig-out/bin/spcrun`. The script is one line a frame of
        bracketed hex records, `-` for a lag frame. `--image` takes a whole ARAM image and
        checks the header's magic and ABI. `--engine` builds one around the shim it was built
        with. `--no-trace` is for load. It exits 1 on discarded messages, a lost trace, queue
        overflow, or a tick count that doesn't match. Emulator granularity means a message takes
        at least 4 buffers, so messages carry 2–3 ticks here. The writes aren't affected. This
        is documented in its header.)*
  - [x] Tests: a stub engine (in `audio/fixtures/`) that writes a fixed register sequence per
        tick and echoes a request byte back. `gbbench` asserts the trace, the tick count and
        the read-back bytes. Existing fed/resident tests still pass.
        *(The stub assembles against the generated `shim_abi.inc` and replaces Step 3a's
        hand-assembled bytes. It calls `shim_version` at init, so the jump table is exercised.)*
  - [x] Busy-rule test: the stub engine under `spcrun --ack-delay 3` receives every tick's
        record in order, with the same trace as with no delay.
        *(Its first run found a Step 3a bug. The emulator can stop mid-`trace_write`, and a
        drain there reset a head the shim then overwrote, so records were read twice (203 and
        233 writes for 158). Fixed with `STATS__TRACE_BUSY` (stats `$17`): the bench skips a
        drain while it is set.)*
  - [x] `zig build shimpkg`: writes the package, which is `shim.bin`, `shim_abi.inc` (symbols
        for the engine's assembly), `shimpkg.zig` (the ABI version, layout constants, pitch
        table, square BRR bank, sample directory builder), and `MANIFEST` (snes_game_dev
        commit, sha256 per file).
        *(`audio/shimpkg_gen.zig` → `zig-out/shimpkg/`. `shim_abi.inc` is read out of
        `memmap.inc` by `gbapu.incSymbols`, filtered to the ABI prefixes. The `REG__` register
        indices moved into `memmap.inc` for it. `shimpkg.zig` reflects every `gbapu.zig`
        constant, and `segments()` follows `image.layout`'s order. `shimpkg_test.zig` compiles the
        generated file and checks it against `image.layout` byte for byte. The commit gets
        `-dirty` appended on a dirty tree. Also checked by hand: an ARAM image built from only
        `zig-out/shimpkg` plus the stub gives the same `spcrun` output as `--engine`.)*

- [x] **Step 4: m2snes's audio toolchain** [m2]
  - [x] `tools/sync-shim.sh <path-to-snes_game_dev>`: refuses a dirty tree. It runs `zig build
        shimpkg` there and copies the package into committed `audio/shim/`, marked generated and
        do-not-edit.
        *(It also refuses a package whose MANIFEST names a `-dirty` commit, which is the same
        rule from the other end: `shimpkg` marks one even when the dirt arrived between the
        status check and the build.)*
  - [x] `zig build verify`: every file in `audio/shim/` matches `MANIFEST`'s sha256, and the
        ABI version matches what `engine/audio/` expects. On a mismatch it fails with a named
        reason.
        *(`src/audio_shim.zig`, the gate's 33rd rung, plus a unit test so `zig build test`
        catches a half-finished sync with no ROM and no assembler. The expected ABI is read
        out of `engine/audio/main.asm`'s `SHIM_ABI_EXPECTED`, the same constant the assembler
        asserts against the package's header, so the two checks cannot drift apart. The file
        list is named in Zig rather than taken from the MANIFEST's own lines, so a MANIFEST
        that forgot a file fails instead of passing shorter. Fault checks run by hand: an
        edited `shim_abi.inc` byte, `SHIM_ABI_EXPECTED = 2`, and a stale `audio.bin` each fail
        with their own reason.)*
  - [x] `tools/get-spc700asm.sh` fetches and builds `spc700asm` at a pinned TAD tag into
        `vendor/`. `tools/get-spcrun.sh` builds `spcrun` from the pinned snes_game_dev commit
        into `vendor/`. Both are rebuild-only.
        *(TAD v0.4.2, the tag snes_game_dev assembles the shim with, so one assembler reads
        both sides of the ABI. `get-spcrun.sh` takes a local checkout rather than fetching:
        snes_game_dev is not public, so a tarball URL would be a pin nobody else could resolve
        either. It reads the pin from `audio/shim/MANIFEST` and refuses a checkout that is not
        on that commit — a newer spcrun embeds a newer shim, and grading against a machine
        this repository has never seen is the failure it exists to stop.)*
  - [x] `zig build spcengine`: assembles `engine/audio/main.asm` (with `audio/shim/
        shim_abi.inc`) into committed `engine/audio.bin` + `.sym`, like `zig build engine`.
        *(The symbol file is `engine/audio.mlb`, not `.sym`: spc700asm emits Mesen label files
        and asar's extension would invite reading it as a WLA symbol file. `engine/audio/
        main.asm` is the seat, not the engine — it plugs into the jump table, names the five
        read-back reply bytes, publishes the shim's version as a liveness byte, and plays
        nothing, which is the honest state of the port before Step 7. `verify` reassembles it
        and compares both outputs, as it does for the 65816 engine.)*
  - [x] Update `docs/setup.md` and the README tool list.
        *(setup.md gains a "The sound engine" section; `docs/conformance.md` gains the rung
        and the roster row, and `rung_count` goes to 33.)*
  - [x] End to end, by hand: `spcrun --engine engine/audio.bin` over a four-tick script loads
        the committed image beside the shim, runs `init` (the reply's liveness byte comes back
        as the shim's version), delivers every tick, and makes no register write. The full gate
        with the ROM is green at 33 rungs.

- [x] **Step 5: Bank 4's data, extracted and placed in ARAM** [m2]
  - [x] Offsets entries, each recording how we know it: `songDataTable`, the channel headers,
        instruction timer arrays, `musicNotes`, `wavePatterns`, the option set tables, the
        noise option sets, and the SFX data tables the per-SFX routines index.
        *(14 entries, and eight new `Kind`s so each format states its own round-trip claim.
        The primary evidence is shared and stated once: `tools/get-bank4-sym.sh` assembles
        M2RoS's bank 4 and compares it against the cartridge byte for byte, so the labels are
        labels on the player's own bytes. Each note then adds arithmetic that closes without
        them — every option-set region divides exactly by its channel's width, the data block
        tiles with no gaps from $4009 to `handleAudio`'s $42B3, and the song data's far end is
        the cartridge's own $00 freespace. Six new shape checks in `verifyAgainstRom`, none of
        which consults M2RoS: the tempo ladder's doubling at a stride of 13, the noise sets'
        counter-control bits, the song table's pointers against the data region, one stereo
        mask per song, the first header read field by field, and the tiling.)*
  - [x] A typed reader and re-encoder per class, with the round-trip identity test the other
        asset classes have.
        *(`src/audio_data.zig`. The gate now reports 175/175 entries re-encoding byte for
        byte, 0 raw, and claimed coverage went from 191 to 200 KiB. Three format facts were
        read out of the engine rather than assumed, and each corrected a first guess that the
        ROM then rejected: `musicNotes` is an NR13/NR14 register pair, not a bare period (bit
        15 is the trigger, and bits 11-13 are refused rather than carried); a header's first
        byte is two fields, since `loadSongHeader` tests bit 0 as the square-2 frequency tweak
        and clears it before storing the transpose; and a channel pointer of $0000 means the
        song does not use that channel, which nine of them do.)*
  - [x] Relocation: the builder rewrites every bank-4 pointer to its ARAM address at build
        time, so the engine never adds a bank offset at runtime. Pointer fields are known from
        the format, not guessed. An unrelocatable pointer fails the build.
        *(The pointer sites come from a walk that follows the table into headers, channels and
        instruction streams, and every rule it uses is read out of the engine: a channel list
        is words whose high byte tells a pointer from a control word, `$00F0` is a goto, and
        exactly two instructions carry pointers — `$F2` always, and `$F1` **only on the wave
        channel**, which is why a section is walked knowing which channel reached it. The walk
        covers over 90% of the region; the rest is unreferenced, and the re-encoder carries it
        through so the round-trip compares the whole block rather than a shrinking subset.
        `relocate` returns a named error per unplaceable pointer instead of passing it
        through. The one that genuinely cannot be carried is the song table's `Nothing` entry,
        which points into `initializeAudio`: it becomes a sentinel, and the substitution is
        returned rather than done quietly.)*
  - [x] `src/aram_layout.zig`: shim + engine + data + samples in one `Segment` list, checked
        against the shim's layout header, and reported by size (the `zig build convert`
        report gains an ARAM section).
        *(Region bounds are read from the package's generated `shimpkg.zig`, not copied, so a
        shim that moves a region moves the layout with it. `check` refuses an overflow by name
        and asserts no two segments overlap. Bank 4's data is 9480 bytes in the 24 KiB engine
        data region — 61% headroom. Also the gate's 34th rung, `aram layout`, which needs
        neither the ROM nor an assembler.)*

- [x] **Step 6: The exact comparison harness** [m2]
  - [x] `src/aram_image.zig`: emit the image Step 5 only planned. The shim's segments from the
        package, `engine/audio.bin`, and bank 4's entries read from the ROM and relocated onto
        `aram_layout.plan`'s placement, into one 64 KiB image with hosted mode and the trace
        flag set in the shim's configuration block. `zig build aramimage` writes it to
        `build-out/aram.bin`. (Added during Step 6: Step 5 placed segments but nothing emitted
        bytes, and `spcrun` needs an image.)
  - [x] The record encoding: a tick's record is `(slot, value)` pairs. The slot numbers are
        declared once in `engine/audio/main.asm` as `REQ_*` equates and read out of it by Zig,
        the way `SHIM_ABI_EXPECTED` already is, so the comparator and the engine cannot drift.
        *(Nine slots, numbered in the WRAM order of the bytes they stand for — a stated order
        rather than a chosen one, checkable against M2RoS `ram/wram.asm`. Eight are the request
        bytes that file's own header names; the ninth is `songInterruptionPlaying`, which is a
        `set` kind and not a request. `audio_req.checkAgainstEngine` reads every `REQ_*` equate
        and, with its own small parser for the expression form, every `REPLY_*` offset — so the
        reply's byte order is held to the engine's too. A unit test fails on any drift, and a
        fault check confirmed it bites: `REQ_SFX_NOISE = 7` reported "should be 3, engine says
        7" by name.)*
  - [x] Request scripts (`test/audio/*.req`, a text format): per tick, the request variables
        set, set-variable ops, and the tick count. It compiles to WRAM writes for the GB side
        and to `spcrun` records for the SNES side, from the one file.
  - [x] GB side: the harness applies the script to WRAM, calls `handleAudio` per tick, and
        records APU writes per tick (`apu.zig`) and the five read-back bytes.
        *(`audiocmp.runGb`. The APU log is attached after `initializeAudio`, so only the
        scripted ticks are in the comparison, and each tick's writes are the slice the log grew
        by across its `handleAudio` call. Tick numbering lines up with the SPC700's for a reason
        that was read out of the shim rather than assumed: `trace_write` tags a write with
        `STATS__HOSTED_TICKS`, which `hosted_run` increments *after* `ENGINE__TICK` returns, so
        the first tick's writes are tagged 0 on both sides. The ROM-backed test asserts
        `songPlaying` reaches $04, so a comparison cannot be two silent engines agreeing.)*
  - [x] SNES side: `vendor/spcrun` with the ARAM image in hosted+trace mode runs the same
        script. Its `write`/`reply` lines are parsed; the reply's cumulative tick counter is
        what aligns a read-back with the GB tick it should match.
        *(Driven through `spcrun`'s own script file rather than a private channel, so a
        divergence is replayable by hand from the two files left in `.zig-cache/audiocmp/`.
        Confirmed on the real image: the smoke run showed replies with `seq=00 ticks=0`, then
        `ticks=2`, then `ticks=3` — cumulative, so a reply's read-back is the state after that
        many ticks, and `engine=…01` is the seat's liveness byte. Output with no `summary` line
        is refused rather than read as an empty run. 1792 ticks (29.9 emulated seconds) parse in
        0.39 s wall, which is what makes Steps 12-15's per-song scripts affordable.)*
  - [x] `zig build audiocmp -- <script>`: reports the first divergent tick (register, value,
        both sides, and the preceding N writes). It skips with a named reason when there's no ROM
        or no `spcrun`. `--regs` filters to a channel's registers, which is what Step 7 grades
        through.
        *(Skips name which piece is missing — ROM, `engine/audio.bin`, or `spcrun` — and exit 0;
        a divergence is exit 1, and a slot drift is its own exit-1 failure before either engine
        runs. `--regs square1` cut the `lag` script's 68 compared writes to 18 and masked
        `NR51`'s $FF down to square 1's $11, which is the mechanism Step 7 needs. Three scripts
        committed: `surface-2s`, `surface-30s` (1792 ticks, the window `audiocost` measures
        over) and `lag`, which carries the frames with no tick and with two or three that a
        per-frame protocol could not express.)*
  - [x] A self-test: an engine that does nothing diverges at the first write, and the report
        names that tick.
        *(Not a fixture — the seat engine really does write nothing, so the first real run of
        the harness was the self-test: `DIVERGE tick 0, filtered write #0`, Game Boy `$FF25 =
        $FF (NR51 panning)`, SPC700 `(nothing: its sequence ended here)`. Also held as a unit
        test over hand-built sequences, alongside one that a filter hides another channel's
        divergence and keeps its own, and one that a read-back is compared at the tick its
        reply was latched at.)*

- [x] **Step 7: THE GATE: the engine spike** [m2 + sgd]
  - [x] Port the hot path Step 2 attributed: `handleAudio`'s frame loop, `handleSong`,
        `handleSongPlaying` and the instruction reader for **square 1**, plus `loadSongHeader`
        for `surface`. The comparison is filtered to square 1's registers (`NR10`–`NR14` and
        the square-1 bits of `NR51`/`NR52`); other channels still play on the GB side and are
        not compared.
        *(Done, and wider than planned, for a reason found during it: `songTranspose`,
        `songInstructionTimerArrayPointer` and `songSoundChannelEffectTimer` are **shared**
        across the four channels, so a square-1-only reader drifts the first time square 2
        changes the tempo. The whole song player is ported -- all four
        `loadNextChannelSound` routines, `loadNextSound`'s five instructions and the pitch
        effects -- and the comparison is what narrows. Still unported, returning at the Game
        Boy's own label: the four SFX handlers (Steps 13-14), the interruptions, the fade and
        the pause (Step 15). `engine/audio.bin` is 3204 B of the 10 KiB reserved. Two
        supporting pieces: a generated `engine/audio/aram_data.inc`, so the assembly reads
        bank 4's ARAM addresses out of `aram_layout.plan` rather than restating them, and the
        gate's 35th rung `aram symbols`, which fails on a stale one.)*
  - [x] `audiocmp` with a `surface` 30 s script, filtered to square 1's registers: exact.
        *(Exact -- and also exact unfiltered on all four channels, on `surface-30s` (3032
        writes) and on a new `title-30s.req` (11158 writes). `title` is where
        `handleSongSoundChannelEffect` lives, a quarter of its cycles against `surface`'s
        under 1.4%, so it is the script that says the effects are ported. Two faults caught,
        both writes rather than sounds: the shim tagged `init`'s three register writes with
        tick 0 (fixed in snes_game_dev 1c818eb; `gbbench` and `gbgrade` unchanged), and the
        port folded the Game Boy's two `set b,[hl]` NR51 writes on a wave note into one.)*
  - [x] Offline load: `spcrun` idle counter against a hosted-mode silent baseline (a new
        constant, with its own test).
        *(`zig build audioload`. The same script twice, once with `engine/audio.bin` and once
        with a null engine that returns from every tick, so the baseline is the same machine
        doing the same protocol work with nothing in it. `surface-30s` **11.7%**,
        `title-30s` **20.7%**. That covers the engine *and* the shim work its writes cause,
        which is the decision's first two terms measured together rather than added.
        `audioload.silent_baseline_idle_hz = 8060` is recorded and compared each run.)*
  - [x] Hardware load: `audiobench` gains `--image <aram.bin>`, which uploads a prebuilt
        hosted-mode image and sends one tick per frame, and shows the published idle byte.
        The idle counter and the tick number it belongs to are latched together by the SPC700
        before publishing, so the readout is a matched pair. Two FXPak runs.
        *(**Run on the FXPak Pro 2026-09-21: `surface` 12.9% and 13.1%, `title` 19.1%
        twice, against offline figures of 12.8% and 19.1% over the same 60 s — they agree
        to a tenth of a point on `title`.** Done as a bench of its own, `zig build hostedbench` in snes_game_dev, rather
        than a mode bolted into the fed bench: the fed one is built around a baked log
        catalogue and shares only the boot ROM's upload sequence. `--image <aram.bin>`,
        with per-entry `--start` records the bench carries and never reads, so the shim
        and the bench stay ignorant of what Metroid II's engine wants. Two chunks a
        frame: the first carries the message and its ack brings back the engine's tick
        counter, the second is a poll whose ack brings back overruns and the idle
        counter -- one latched set, as the plan asked. The rest window **keeps sending**,
        with a tick count of zero, so the baseline is the same shim doing the same port
        work with the engine idle: the hardware counterpart of `audioload`'s null engine.
        Two faults the Mesen2 smoke test found, both of which read as a dead console: the
        upload started at ARAM $0000, over the S-SMP boot ROM's own stack while it was
        still running; and a second START would have spun forever, because the boot ROM
        answers once per power cycle. A third, which only the console could show: `TCK`
        came back at 1x, 2x, 3x and 4x `POS` across four runs, because it is the shim's
        counter since *its* boot and START baselined the idle counter but not that one.
        James saw it on the screen before the arithmetic here did. Fixed, and both
        counters now read since START.)*
  - [x] Extrapolate to four channels from the spike's per-channel cost and Step 2's attribution,
        labelled as an extrapolation.
        *(Not an extrapolation at all in the end: all four channels are ported, graded exact
        and measured on the console. What is extrapolated is the other direction — what
        Steps 13-15's sound effects will add, taken from Step 2's SM83 burst at +22% and
        labelled as the lead it is.)*
  - [x] Estimate the shim's CH3/CH4 cost from Step 1's per-voice pulse cost plus the wave
        lookup's cost, labelled as an estimate.
        *(≈5% offline on `surface`, from doubling the two-channel shim's measured 2.4%,
        plus about a point for CH3's wave lookup. The reasoning and its weak joint — a
        subtraction across resident and hosted modes — are in `03-measurements.md`.
        Offline four-channel total: ≈15%, against a budget of 50%.)*
  - [x] **Decide:** extrapolated engine + measured two-channel shim (Step 1) + estimated
        CH3/CH4 shim ≤ 50% on `surface`. Record
        it in `03-measurements.md` with `title` alongside. **If it fails, stop the cycle and
        write the finding.**
        *(**Go.** `surface` 18.7% and `title` 29.1% of the 50% budget, with all four
        channels and Steps 13-15's sound effects allowed for. Both remaining estimates —
        CH3/CH4 synthesis and the sound effects — would have to be about three times their
        projection before the condition came under threat. The margin does not cover them
        being wrong in kind, and `03-measurements.md` says so.)*

- [x] **Step 8: The documents catch up with the decision** [m2 + sgd]
  - [x] Port `01-requirements.md`: amend F8 and the decision table's Music, Sound effects and
        "Relationship to snes_game_dev" rows, pointing to this cycle and the shim verdict.
        *(Also the lines that would otherwise contradict F8: the builder bullet (the SM83 core
        and APU no longer ship for audio), F2's and F3's out-of-scope audio lines ("impossible
        by construction" held only for transcription), Phase 0c's description, the toolchain's
        "TAD is the audio driver", and the unmeasured-assumption list, where transcription
        quality is retired. TAD survives only in F9's `snes_game_dev` precedent, which is
        still true.)*
  - [x] 0b `01-requirements.md` audio deferral, and m2snes `docs/feature_tracker.md` F8.
        *(The 0b amendment closes the open decision and records that the stub's obligation paid
        off. The ids 0b records become 0c's requests unchanged. The tracker's F8 now says what
        was decided, why, what exists and what doesn't, and stays `[ ]`.)*

- [x] **Step 9: CH3 wave** [sgd]
  - [x] `shim.asm`: `NR30`–`NR34`, wave RAM writes into the register file, a DAC enable, and
        `NR32` shift mapped to volume. Length is 256 steps.
        *(Voice 2, from a third channel block. The length counter is nine bits for all three
        channels. NR32's shift is given to the volume formula as the loudest sample it leaves,
        15, 7 or 3, in the envelope's place. Two changes to shared paths, both found by
        `gbgrade` rather than planned. **A write marks only its own channel's voice** (NR50-NR52
        all three), through a 48-byte `voice_bits` table: marking every voice on every write
        made each vibrato write push three voices, and `title`'s overruns rose from 34 to 165.
        **STATS__BUSY stays set through an overrun's catch-up**, until the writes the skipped
        ticks were owed are applied and pushed. Until then the counter reads ahead of the DSP.
        It always did, but no grade had landed an observation in that window until CH3 added
        load. Separately, the ABI goes to 2: STATS grew by 8 bytes, which moved CONFIG and the
        square bank.)*
  - [x] Wave lookup: a table of (32-nibble contents → sample index) supplied in the image. On
        a trigger the shim looks up the current wave RAM, and a miss counts
        `STATS__WAVE_MISSES` and plays silence.
        *(A count byte, then 16 bytes per wave, up to 17 waves, which is what the DSP
        directory's page has room for. Only when wave RAM has been written since the last
        lookup. **The table's address comes from the config block** (`CONFIG__WAVE_LUT`):
        `WAVE_LUT_ADDR` in hosted mode, and right after the log in resident mode. `title`'s
        45 KB log reaches past $c000, and a fixed-address table was written over its last six
        seconds. That was the first `gbgrade` run's 511 disagreements.)*
  - [x] `samples.zig`: a wave BRR encoder (32 4-bit samples → looped BRR at the period lengths
        in use) and CH3's pitch mapping (`65536 / (2048 - x)`), in the package.
        *(The encoder is `audio/wave.zig`, not `samples.zig`, because it ships in the package as
        its own file and imports only `std`. The pitch mapping is in `samples.zig`. The lengths
        are 64/32/16, twice the square bank's, so CH3 reads the square bank's pitch table
        unchanged. A test holds that equality for all 2048 periods, and another holds it against
        `expect.zig`'s independent statement. Shift 11, with a per-wave offset for DC. At full
        level a wave swings 15/16 of a pulse at envelope 15, which is left to Step 11's mix.)*
  - [x] Corpus: a wave `.gblog` covering every NR32 shift, trigger, length, and a pattern change
        mid-note. `expect.zig` extended, and PITCH/VOL/SRCN asserted exactly.
        *(`wave.gblog`: two waves, all four levels, both length paths, the DAC off under a note,
        wave RAM rewritten with the DAC on (heard at the next trigger in both the model and the
        shim), and the 32-sample loop, the 16-sample loop and above Nyquist. 117 CH3
        comparisons, 0 disagreements. Also: a coverage test on the writes, and a test that both
        waves, all three loop lengths and every level are reached. A test with the image
        withholding a wave shows silence and the miss count. A fault injection (SRCN always
        wave 0) gave 41 disagreements.)*
  - [x] `gbgrade` on a captured track that uses wave: 0 disagreements. Render and listen.
        *(0 disagreements on all three tracks: `title` 5466, `attract` 9471, `surface` 6885
        observations. Overruns 137/116/328, against 34/87/261 before CH3. Resident load 15.1%/
        -1.5%/3.5%, against 11.8%/-2.8%/2.4%. The mix now clips: 0.6% of `title`'s samples and
        0.2% of `attract`'s are within 800 of the rail. **By ear (James, 2026-09-20): all three
        tracks identical to SameBoy's reference, or close enough.**)*

- [x] **Step 10: CH4 noise** [sgd]
  - [x] `NR41`–`NR44` with envelope and length through the pulse units.
        *(Voice 3, from a fourth channel block (`$70`, which fills the direct page to `GB_REGS`).
        NR41/NR42/NR44 reuse the pulse paths: `write_nrx2`, `trigger` (X is not 0, so no sweep),
        `tick_length_one`, `tick_envelope_one`. NR43 is decoded once, when it is written, into the
        width, a `PITCH` and an NCK. The power reset decodes NR43 = 0, which is the fastest rate
        and not "no rate". ABI 3.)*
  - [x] Build both candidates: S-DSP noise (`FLG` noise clock, `NON`) and a looped LFSR BRR
        (15-bit and 7-bit), each with a pitch mapping from `NR43`.
        *(One shim, both candidates, chosen per image by `CONFIG_FLAG__NOISE_DSP`. `audio/noise.zig`
        (ships in the package) holds the LFSR, the samples and the NCK table. **LFSR:** 15-bit is
        the first 8192 steps from the trigger state (4608 bytes). 7-bit is 16 periods of 127
        (2032 samples, 1143 bytes), because 127 is not a whole number of blocks; the verdict's
        "72 bytes" was wrong for that reason. Source numbers 60/61, after the waves', so
        `WAVE_LUT_MAX` drops from 17 to 16. `PITCH = 2^31 / (32000 x r2 x 2^s)`, from eight 17-bit
        constants shifted right `s` times, which is exact. Above 14 bits the shim plays eight
        steps a sample, which is sound because both LFSRs are maximal-length: every eighth step
        is the same sequence, rotated. `noise.zig` asserts that for both widths. Shifts 14-15
        stop the clock (silence), and a clocked rate below 1 unit gets 1. **DSP:** NON on voice
        3, FLG's clock the nearest of the 31 by ratio, from a 112-entry table the image places at
        `$0d80` (the code region gives up 128 bytes while both candidates exist). The model states
        both rules on its own, the PITCH in integers and the nearest clock in floating point.
        **Graded:** `noise.gblog` holds each of the 256 NR43 values for two frames under one note,
        plus envelope, length, DAC-off, routing and a trigger after the power reset. 0
        disagreements under both candidates, with every NR43 value compared (a test). Fault
        injection: one pitch constant off by one gave 8 LFSR disagreements and 0 DSP; an NCK index
        without the divisor gave 798 DSP and 0 LFSR; the width ignored gave 576 LFSR and 0 DSP.)*
  - [x] Render the slice's noise-heavy material both ways (a captured track plus captured noise
        SFX from Step 2's list). **James chooses by ear.** Record the choice and the reason.
        *(Rendered: `gbgrade --noise both` writes `<track>-lfsr`/`<track>-dsp`. `--sfx-noise <id>`
        in `gbgrade` and `gbref` captures one noise effect by calling the driver
        (`capture.runSfxNoise`, request `$CED5`, which refuses an id that writes none of
        NR41-NR44). All 15 of the slice's ids were taken. What the ear is choosing between: the
        slice's music is mostly **7-bit** noise (NR43 `$3d`/`$3e`/`$4b`/`$4d`/`$6e`/`$6f` on
        `surface`), which the DSP generator cannot make. Its peak is about twice the LFSR's, and its
        RMS about 1 dB higher.
        CH4 matches the model exactly on all 15 effects under both candidates. **Captured music
        now differs:** `title` 8, `surface` 44 (both candidates), against 0 at Step 9. Traced to
        lateness: overruns rose with CH4's work (`surface` 328 → 464, `title` 137 → 164; the NR43
        decode, the push and the length/envelope ticks each add some). A catch-up runs every
        elapsed tick before applying the writes those ticks were owed, so a trigger due just
        before an envelope step lands just after it, and the note's envelope runs one step (8
        ticks) behind. 6 of the 10 disagreement runs on `surface` follow an overrun directly.
        Carried to Step 11. Also found: effect `$05` (Metroid hurt) disagrees on **square 1's
        sweep** (20 rows, no CH4), a lead for Step 13.
        **James's choice: a hybrid, by NR43's width.** By ear: DSP was better on the 15-bit
        effects (01, 0B, 0C, 0D, 11, 12) and on the slow 7-bit ones (03, 04). LFSR was *much*
        better on the fast 7-bit "electrical" metroid sounds (06, 07, 1A). 10 was a tie. DSP was
        too loud everywhere, drowning the music. Two causes, one in each candidate. (1) The DSP
        has no 7-bit mode. (2) The LFSR sample is one step per sample, and Gaussian interpolation
        rounds the Game Boy's square steps off. On `03` the reference has 25% of its energy above
        500 Hz, DSP 27%, LFSR 0.6%. Fixable by storing each step as several identical samples.
        So: **15-bit through the DSP generator, with its volume scaled to a square's RMS; 7-bit
        through an oversampled LFSR sample.** Cost: the DSP's single noise generator (and `FLG`)
        belongs to CH4, and 15-bit noise does not restart on a trigger.)*
  - [x] Keep the hybrid: 15-bit on the DSP generator (volume matched), 7-bit on the LFSR sample
        oversampled so interpolation keeps its edges. Drop the 15-bit sample, the DSP's 7-bit
        path and `CONFIG_FLAG__NOISE_DSP`. Corpus and `expect.zig` extended, and asserted
        exactly. Re-render only the hybrid for James to re-evaluate.
        *(Built. Seven bits: three copies of the 2032-sample loop at 1, 4 and 16 samples a step
        (source numbers 60-62, 3429 bytes, down from 5751). `noise_rate` starts from 16x
        constants and takes two more exact shifts per tier until `PITCH` fits, then eight
        steps a sample at one. Fifteen bits: `NON` on voice 3, `volume_for` at full scale
        `NOISE_DSP_VOLUME_FULL` = 96, not 127. That is measured: against the Game Boy reference,
        pulse-only tracks render at 3.55x its RMS and the generator at 127 rendered at 4.7x
        (median, fifteen-bit effects), and 127 x 3.55 / 4.7 = 96. `CONFIG_FLAG__NOISE_DSP`,
        `NoiseImpl`, `--noise` and the 15-bit sample are gone. **Graded:** 0 disagreements, every NR43
        value compared, and a test that the corpus sounds all five ways: the generator, each
        tier, and eight steps a sample. Fault injection: the generator at 127 gave 456; no 16x
        tier gave 577; seven bits on the generator gave 2219. **Rendered** (all 15 effects and
        title/attract/surface, the old files deleted): noise effects now 3.0-3.9x the reference
        RMS against pulse's 3.55x (they were 3.7-6.9x DSP and 2.2-3.9x LFSR). `11`/`12` stay high
        (5.2x/4.1x), and `10` low (0.76x), under both old candidates as well. Brightness now
        matches: on `03`, 20% of the energy above 500 Hz against the reference's 25% (LFSR was
        0.6%); on `06`, 46% above 2 kHz against 49%. Captured music differs as before (`title` 8,
        `surface` 48) for the lateness carried to Step 11.
        **James's re-listen:** the music sounds good, and the effects accurate except `05`,
        whose high "animal" chirp was missing. The render's overall level runs 3.55x the
        reference's (Step 11's `MVOL`). **Cause, a shim bug on every channel:** a voice
        silenced while its channel still runs (a pulse or wave period above the DSP's Nyquist,
        NR32 at mute, NR43's clock stopped) was keyed off. A period, level or rate written back
        into range needs no trigger on the Game Boy, so the voice stayed released: every
        register right, nothing audible. `05` triggers square 1, sweeps it past 16 kHz at
        72 ms, then writes NR13 each frame with no trigger. Its sweep snaps back to the shadow
        register every 31 ms, and those blips are the chirp. Found by soloing pulse 1: the
        reference sounded for 850 ms, ours for 80 ms. (Filtering the reference to below 16 kHz
        first ruled out the DSP's Nyquist: James heard it as perfect.) **Why grading missed
        it:** it compared PITCH, SRCN and VOL, and a released voice holds all three. It now
        reads `ENVX` as well: a voice the model wants sounding must not sit at zero for two
        comparable observations running. One was not enough, because captured music caught
        six retriggers inside the DSP's key-on delay. **Fix:** those silences keep the voice
        keyed on, at volume and PITCH zero. The corpus gained a return from each without a
        trigger (`pitch`, `noise`). The old shim fails them: 24, 17 and 19 on pitch, noise and
        wave, the last on `wave.gblog`'s existing NR32 mute. The fixed shim gives 0. `05` now
        renders at 3.37x the reference against 2.5x before, with the reference's envelope.
        **James confirmed `05` by ear.** The overall level goes to Step 11's `MVOL` work, chosen
        against headroom rather than to match the reference: the music peaks at the rail.)*

- [x] **Step 11: Four channels measured, and the mix** [sgd]
  - [x] *(Added: carried from Step 10.)* The captured-music disagreements after an overrun.
        *(Cause: `service_timer` ran every elapsed tick, then `service_resident` applied the
        records owed to them, so a trigger landed after an envelope step it preceded. Now the
        log's records are applied between the ticks. Step 9's `catchUp`, which held
        STATS__BUSY through the catch-up so the grade would not look, is removed: every tick
        now has a defined answer. `gbgrade`: 0 on all three (was 8/0/48), with more graded
        (`surface` 6778 against 6743). Step 1's lead is the same fault: dense bursts at 3 and 4
        note-ons a frame now give 0. Guard: `runDense(4, 1)` (four note-ons a frame, an
        envelope that steps). The committed shim fails it with 3, and with 21 once the
        `catchUp` exclusion is off.)*
  - [x] ARAM by region and SPC700 load for title/surface/attract at four channels, offline and
        on the FXPak, against the shim F3 budgets, in `03-measurements.md`.
        *(**FXPak, 2026-09-21:** hosted `surface` 15.8%/15.7% and `title` 22.6% twice, against
        offline 16.0% and 22.8%. Fed: `title` 29.4%, `attract` 5.6%, `surface` 15.3%, lower than
        Step 1's two-channel figures for reasons not established (a lead; fed mode doesn't ship).
        Readouts in `03-measurements.md`. Offline, earlier: **ARAM:** `gbbench` now prints it by region.
        12,348 bytes (18.8%) against the verdict's ~9,500, mostly the noise tiers. Passes F3,
        but the **code region has 142 bytes free** and the DSP directory 4. **Load**, resident
        shim alone: `title` 15.0%, `attract` ≈0, `surface` 5.3%. Engine + shim, hosted
        (`audioload`): `surface` 14.7%/16.0%, `title` 25.3%/22.8% (30 s/60 s). Silent baselines
        re-stated: fed 8779, resident 8009, hosted 7936. Ready for the console: `zig-out/gbbench.sfc`
        (fed, three tracks) and `zig-out/gbhosted.sfc` (the four-channel m2snes image), both
        passing their Mesen2 smoke tests.)*
  - [x] **Re-check the gate** with the measured four-channel shim plus Step 7's extrapolated
        engine: ≤ 50% on `surface`. **If it fails, stop the cycle and write the finding**
        before any bank-4 porting beyond the spike.
        *(**Passes.** Engine and four-channel shim measured together, not added: `surface`
        16.0%, plus Step 7's +22% for sound effects = **19.5%**; `title` 25.3% → 30.9%. The
        CH3/CH4 estimate was +3.4 on `surface`, and the measured difference is +3.2.)*
  - [x] Clipping: rail-hit percentage per rendered track. Choose `MVOL` and per-voice scaling,
        and record them with the reasoning.
        *(**Kept: `MVOL` $7f, full scale 127 (noise generator 96).** The DSP clamps the voice sum
        before `MVOL`, so the lever would have been the per-voice full scale. Near-rail samples
        at 127: `title` 0.80%, `attract` 0.38%, `surface` 0.04%; renders at 96/80/64 are in
        `03-measurements.md`. **What James heard as clipping was not the clamp:** `attract`
        6-9 s clicked at every full scale, and the reference faintly too. The cause was key-on.
        The shim keyed the DSP voice on at every trigger, and the S-DSP restarts the sample after
        five samples of exact silence. The Game Boy's trigger leaves a square's duty position
        alone (SameBoy `apu.c`), so its retrigger is seamless. On the unison swells both voices
        dropped to zero and jumped back 19,286 steps. **Fix:** a pulse voice already sounding
        (its key-off bit clear) is not keyed on again; the push carries the new volume, pitch and
        sample. Wave and noise keep the key-on, because those channels restart on the Game Boy.
        Largest jump in the window: 19,286 → ~8,100. `gbgrade` 0/0/0, corpus 0. Guard: a square
        retriggered every frame with no four-sample run of zero; the old shim gives 59. With the
        clicks gone, **James: "the 127 tracks are clean."**)*
  - [x] CI: add `zig build gbbench` (synthetic corpus and four-channel `expect.zig`
        assertions, no ROM) to `.github/workflows/ci.yml`, and confirm it green on a CI run.
        *(Added. `gbbench` used to print its disagreement count and exit 0; it now fails
        with `CorpusDisagrees` after printing the report. With the full scale one unit off it
        gave 1578 and exit 1. **Green on CI** (run 35670087941, b1e213f): the step ran and
        printed "0 disagreement(s) with the model".)*
  - [x] `tools/sync-shim.sh` into m2snes, and verify green.
        *(m2snes b2db271, from snes_game_dev 5a22704, ABI 1 → 3. It was more than a copy: the
        package's `wave.zig`/`noise.zig` were never synced, and the image builder did not place
        CH3/CH4's data. It now places the seven `wavePatterns` (offsets from bank 4's symbols)
        as the lookup and their BRR, the noise samples, and a full DSP directory. A ROM test holds
        every `$F1` in the song data to the seven. Dropping any of six fails it; wave5 is
        reached only from code. `audiocmp` exact on all six scripts; `zig build verify` green,
        35 rungs. `vendor/spcrun` rebuilt, because it refused the ABI 3 image by name.)*

- [x] **Step 12: Bank 4 — song processing on all four channels** [m2]
  - [x] Extend the spike to square 2, wave and noise: `handleSong_loadNextChannelSound_*`, the
        wave/noise option sets, `handleSongSoundChannelEffect`, and every `songInstruction_*`.
        *(Done in Step 7 already, which ported the whole player. The sweep below found three
        places where it read what the Game Boy reads out of bounds, and the port did not.)*
  - [x] `writeToWavePatternRam` goes through `shim_write_reg`, like every other write.
        *(Also Step 7's.)*
  - [x] A `.req` script per song id that extracts cleanly: song-init plus 60 s. `audiocmp`
        exact on all four channels.
        *(**31 of 32, exact.** `test/audio/songs/`, from `tools/gen-song-reqs.sh`.
        `audiocmp` now takes several scripts and stops at the first that diverges. It runs
        all 31 in 25 s. 26 were exact on the first run. The other five failed on four faults,
        none of them in a routine. Each one was the Game Boy reading past what we had placed:
        (1) a length byte before `$F4` makes the `$F4` a note, which indexes `musicNotes`
        past its end into the tempo tables (subCaves3, finalCaves, hive with intro);
        (2) the shared effect timer's index `$10` on table `$A` reads the byte after the
        tables, `handleAudio`'s first opcode `$FA` (finalCaves' square 2);
        (3) because (1) ate the `$F4`, the `$F5` repeats to the `$0000` that initializeAudio
        left, and the Game Boy reads its own ROM header `C3 FB 01 00` as song data
        (subCaves3 without intro, tick 217);
        (4) the walk never followed a `$00F0` goto to a list no header names, so the hive
        intro's loop list kept Game Boy addresses. Fixes: `aram_layout.overreads` places
        ROM bytes after `musicNotes` ($6F), the tempo tables ($48) and the effect tables (1);
        a 4-byte `rom0000` segment that the engine's `$F5` redirects a `$0000` repeat point to;
        and the walk now follows goto targets. Each fix has a ROM-derived test, and I checked
        that each test fails with its fix reverted. `$10` doesn't extract: its table entry is
        engine code. It is logged in `docs/audio_ids.md` for Step 15.
        `zig build verify` green, 35 rungs.)*
  - [x] Unit-level `.req` scripts for goto, repeat and transpose instructions, found by the
        attribution in Step 2.
        *(Found by this step's sweep rather than Step 2's attribution, which only covered
        title and surface: `goto-hive-intro` (7 s, the goto-only list at tick 301),
        `repeat-unset-point` (5 s, tick 217) and `transpose-wrap` (23 s, chozoRuins'
        `$FE` at tick 1261, found by zeroing `$F3` in the port). Each was checked by
        breaking its fix, or `$F3`, and seeing it fail at that tick.)*

- [x] **Step 13: Bank 4 — square-channel SFX and priority** [m2]
  - [x] `sfxRequest_square1` / `square2` / `fakeWave`: init and playback routine tables, and
        `sfxActive_*` suppressing the song on that channel.
        *(All of square 1's table, $01-$1E, and all of square 2's, $01-$07, one procedure per
        Game Boy routine. `fakeWave` has no tables: bank 4 only clears its request, which the
        port already did. `sfxActive_*` on the song side was Step 7's. The 124 option sets are
        named by the M2RoS address of each; an assert holds the last one to the block's end.
        Engine 3,214 → 5,698 bytes of the 10 KB region.)*
  - [x] Preemption and priority, plus the short jump/hi-jump and screw-attack remember/resume
        paths.
        *(The resume reads `samusPose` and `samusItems`, which are game state and not audio
        RAM. They are two new record slots, `REQ_SAMUS_POSE` = 9 and `REQ_SAMUS_ITEMS` = 10,
        of a new kind, `game`, that persists across ticks. Step 16a has to send them. The
        `call nz` bug in `square1Sfx_init_18` is kept `call` for `call`.)*
  - [x] `.req` scripts: each slice SFX id alone, each over `surface`, and a preempted-mid-SFX
        case. `audiocmp` exact, including the read-back bytes.
        *(**Every id, not only the slice's: 64 generated scripts** (`test/audio/sfx/`, from
        `tools/gen-sfx-reqs.sh`), each id alone and at tick 60 over song $04. Also six
        hand-written ones: `sfx-priority` (the $0C and $18 guards, jump vs beam/spazer,
        $04 vs a jump, $FF), `sfx-chozo-jump`, `sfx-screw-resume`, `sfx-screw-noitem`,
        `sfx-health-repeat` and `sfx-square2-over-square1`. All 70 were exact on the first
        run, so each was checked with a fault injected: both priority guards, the resume
        flag, pose and item tests, the Chozo branch, the `call nz`, one option-set address,
        the beam guard, and square 2's stop. All ten diverged in the script meant to catch
        them. Left out: square 1's $1B and square 2's $03-$06 seed a pitch from `rDIV`, and
        the ROM requests none of them. They diverge at the first variable-frequency write
        and nowhere before it, and they are logged in `docs/audio_ids.md`. The 46 older
        scripts are still exact; `zig build verify` green, 35 rungs.)*

- [x] **Step 14: Bank 4 — noise and wave SFX, and the low-health beep** [m2]
  - [x] `handleChannelSoundEffect_noise` / `_wave`, `sfxRequest_noise`, `sfxRequest_wave`
        (low-health beep), and the channel clear/disable routines.
        *(All 26 noise ids and the 5 wave ids, one procedure per Game Boy routine, with two
        exceptions. The ten `setPolynomialCounterXX` routines are one shared NR43 write,
        with the constant loaded at the call site. The four copies of the beep's playback
        body are one routine, `lowHealthBeepPlayback`, and the three init copies are
        `lowHealthBeepInit`. The writes are the same. Kept as on the Game Boy: `init_5`
        *calls* `playNoiseSweepSfx` and runs on into its playback, so its first tick counts
        down once; the earthquake drops a noise request *and* that tick's playback; a wave
        request of $06 or more skips that tick's beep; footsteps give way to a playing
        effect and to the song's noise channel. The clear/disable routines were Step 7's.
        One more overread: wave `$FF` with no song pattern set (at boot, or under the
        earthquake, whose wave channel never runs `$F1`) copies GB `$0000-$000F` into wave
        RAM. `rom0000` grew from 4 to 16 bytes (ROM-derived test), and a `$0000` pointer is
        redirected to it, as `$F5` already was. Engine 5,698 → 7,367 bytes.)*
  - [x] `.req` scripts: each slice id, over music, and the death sound's `sfxPlaying_noise`
        wait. `audiocmp` exact.
        *(**Every id, not only the slice's.** `tools/gen-sfx-reqs.sh` now writes all four
        channels: 136 scripts, each id alone and at tick 60 over song $04. Plus nine
        hand-written ones: `noise-priority` ($0D/$0E/$0F guards, $FF), `noise-earthquake`,
        `noise-footsteps`, `noise-death-wait` (the $B0-tick wait, graded on the read-back
        tick by tick, and song $0F clearing a playing bomb), `noise-metroid-hurt` (two rDIV
        values, and the cry refused under square 1's $0C and $18 guards),
        `noise-square2-cries`, `wave-beep-stop` (level change, $FF restore, $06 ignored
        idle and mid-beep), `wave-beep-earthquake` and `wave-beep-stop-nosong`. All 191
        scripts in the tree are exact. Seventeen injected faults each diverged in the
        script meant to catch them: the three priority guards, the earthquake guard, the
        `init_5` fall-through, both footsteps guards, the quake's no-restore, the `rom0000`
        redirect, the $06 return, the loud-run length, a polynomial constant, acid's set,
        the cry request, song $0F's noise clear, and, on the harness side, the DIV pin
        ignored. `zig build verify` green, 35 rungs; 6,773 unit tests.)*
  - [x] **The divider is carried** (decided at this step's start). Noise $05 (Metroid hurt,
        in the slice), $09, $0A, $16 and $17 request square 1 $1B or square 2 $03-$06, whose
        pitch is seeded from `rDIV`, so Step 13's "no site requests them" was wrong. Slot 11,
        `rDIV`, a new `divider` kind: the Game Boy harness pins $FF04 reads to the script's
        value (0 until a script sets it), and the engine reads `ram_div` from the record.
        Square 1 $1B and square 2 $03-$06 join the generated scripts, and `docs/audio_ids.md`
        drops them from the unmatched list.
        *(`Bus.div_pin` in `src/gb/bus.zig`, with a unit test; the generated cries run at
        rDIV $A7, which found nothing Step 13 had missed.)*

- [x] **Step 15: Bank 4 — interruption, fade, pause, and the full-id sweep** [m2]
  - [x] Song interruption: item get, missile pickup, earthquake, end, clear, and the backup
        and restore of `songPlaying` and the low-health beep.
        *(One procedure per Game Boy routine. The whole $61-byte song processing state is
        copied aside and back, its length read from the ROM's `songProcessingStateSize`, and
        the end replays all twenty of $CF10-$CF23 into $FF10-$FF23, the two unused registers
        included, as the Game Boy walks them by address. Kept as on the Game Boy: three of
        these return without running the song, so the `songRequest` they set is played on the
        next tick and the end's $FF stops survive into the tick after `finish`; the earthquake
        neither backs up nor stops the beep; an end request with nothing to end copies the
        backup back anyway. `finish` redirects a $0000 wave pattern to `rom0000`, as the wave
        channel's stop does.)*
  - [x] Fade out, `silenceAudio`, `initializeAudio`, `muteSoundChannels`, and
        `audioPause`/`audioUnpause` with the paused noise SFX.
        *(`muteSoundChannels`, `initializeAudio` (as `init`) and `silenceAudio` (reached from
        `$F6+` in a stream) were already ported. **The game calls `silenceAudio` outside
        `handleAudio`**, at a death, the boot and two unused modes, so it is now **record
        slot 12**, a new `call` kind: it runs where it stands in the record, so a request
        before it is cleared and one after it survives, and its writes are that tick's. The
        Game Boy harness calls bank 4's $4003 trampoline, held to the ROM by a test, and now
        charges the ops' writes to the tick. Step 16a has to send it. The pause's eight option
        sets are read from the placed `pausedOptionSets`. Engine 7,367 → 7,897 bytes.)*
  - [x] `.req` scripts: earthquake over a song and its restore, item-get jingle and restore,
        pause and unpause mid-song, fade to silence. `audiocmp` exact.
        *(Ten: `int-earthquake-restore`, `int-earthquake-end`, `int-item-get`,
        `int-missile-pickup`, `int-item-get-while-quake`, `int-clear`, `fade-out`,
        `pause-mid-song`, `pause-short` and `silence-death`, each asking in the order the game's
        own site does. All exact on the first run, so 21 faults were injected, and each
        diverged in the script meant to catch it. Two were missed at first, and the scripts
        changed rather than the faults: an off-by-one at the fade's $70 step shows only if a
        note starts on that tick (swapped for a wrong envelope value there, which is caught),
        and a fade that fails to clear `songPlaying` is undone one tick later by
        `handleSongPlaying` finding every channel off, so `fade-out` now starts a jingle on
        exactly tick 269 (60 + $D0 + 1), whose backup makes it permanent.)*
  - [x] Sweep every song and SFX id in the ROM's full range. List the ids that don't extract
        or don't match in `docs/audio_ids.md`, each with its reason.
        *(`tools/gen-sweep-reqs.sh` → `test/audio/sweep/`: every value $00-$FF of each of the
        eight request bytes, 20 ticks apart, over the surface theme. All eight exact. Four
        injected faults at the table bounds: three diverged in their sweep, and the fourth,
        the interruption $FF clear, needed `int-clear` because the quake's song has ended by
        the time the sweep reaches $FF. Song $10 is still the one unmatched id (diverges at
        tick 1) and stays listed with its reason. All 209 scripts in the tree are exact;
        `zig build verify` green, 35 rungs; 6,858 unit tests.)*

- [x] **Step 16a: The cart plays it: boot and messages** [m2]
  - [x] Boot: upload the ARAM image through the IPL with a bounded timeout, and measure the
        duration (frames), reported in the ROM build output and in a debug readout outside the
        160×144 window. On timeout the cart runs without audio and the readout says so.
        *(`AudioBoot`/`AudioUpload`/`AudioProbe`; every wait bounded. The readout shows state,
        upload frames, drops and cost. `zig build rom` prints the image (31,187 bytes in 18
        blocks). The frames can only be measured by running the cart, so the new `zig build audioboot`
        does it in Mesen2: with sound, state 2 and a 60-frame upload (1.0 s), first pass at frame
        65; with every APU port read forced to 0, state 0 (down), first pass at frame 27. Not in
        `verify` yet, like the other audio tools.)*
  - [x] Every place the rewrite stands in for `handleAudio_longJump` counts a tick. Per-tick
        records and the tick count are sent once per frame by the busy rule (Step 3a), never
        blocking, measured in cycles per frame.
        *(`AudioFrame`/`AudioTick`, with `DeathAudio` and the door's entry wait taking over
        the implicit tick. `audioparity` grades the tick count of every frame. The pump never
        blocks (`AudioIrq`); measured at 6 scanlines a frame, down from 40, as `!AudCost`.)*
  - [x] A lag case: a `.req` with a frame of 0 ticks and a frame of 2 ticks, and an
        `--ack-delay` run, both `audiocmp` exact.
        *(`test/audio/lag-sfx.req`: requests on the second of two ticks, across lag
        frames and in a four-tick frame. `audiocmp` gained `--ack-delay <frames>`, passed
        to `spcrun`. Exact both ways, and the delay did work: 9 messages against 17 for
        the 40 ticks, queue max 9. This grades `spcrun`'s client, not the cart's.)*
  - [x] The recording stubs (`!Song`, `!SongInt`, `!Sfx1`, `!SfxNoise`, …) stay as they are and
        are also sent.
        *(`%audio_put(slot)` after each of the 57 stores that stand for a Game Boy write,
        checked against its citation. Not sent: `KillSamus`'s imitation of `silenceAudio`,
        the save load's `currentRoomSong`, the $FF inits, `!SongAfterQuake`/`!QueenRoar`,
        and `!SongPlaying`'s stores (the driver's, or 16b's set op).)*
  - [x] `samusPose` and `samusItems` (slots 9 and 10, Step 13) are sent whenever they change.
        The engine reads them when an energy drop's sound ends mid screw attack.
        *(`AudioTick`. Graded by `audio_parity.compareState`: the Game Boy capture records both
        bytes at every `handleAudio` call, and the cart's last send must equal them on every
        tick. Stretch 0: 392 ticks, pose sent 32×, items 1×; stretch 6: 27 ticks.)*
  - [x] `silenceAudio` (slot 12, Step 15) is sent at the four places the game calls it,
        in the record of the next tick, after anything requested before the call and before
        anything requested after it. `KillSamus`'s own clearing of the request bytes stays.
        *(Sent at the two ported call sites, 00:$2FA2 (`KillSamus`) and 00:$3E4B (boot), in
        order through `AudioPut`. The other two, 00:$3ACE and 00:$3B43, are in routines that
        aren't ported; the ledger fails once one of them is ported without the send. Slot 12 is
        graded by `audioparity`.)*
  - [x] `rDIV` (slot 11, Step 14) is sent with every tick that could start a cry: a byte
        that varies from tick to tick, so the Metroid cries vary in pitch as on the Game Boy.
        The cart already keeps an rDIV substitute, `!DivClock` (advanced by NMI; the HUD
        scramble and enemy coin tosses read it), which is the byte to send.
        *(`!DivClock+1` on every tick. `compareState` fails a tick with no `rDIV` or two, and a
        stretch over 60 ticks with fewer than 2 distinct values: stretch 0 sends 155 distinct. The
        trace now closes a tick at `AudioTickClose`, after `AudioTick`'s own puts; at the old hook
        the check failed on tick 0, which is how that was found.)*
  - [x] *(Added 2026-09-22, option A.)* Request-site ledger: every Game Boy write of a
        request byte outside bank 4 (199 sites), derived from the ROM, each with the byte it
        writes and the port routine that stands for it, or "not ported". A test fails when a
        ported routine lacks one of its sites, so a routine ported later can't arrive silent.
        *(`src/audio_sites.zig`, `zig build audiosites [status]`. 203 sites: `audiocost`'s 199
        request stores plus the four `silenceAudio` calls, agreeing with M2RoS bank by bank.
        Every `%audio_put`/`%audio_request` names its `$BBAAAA` site(s). A site is **missing**
        (test fails) when a claimed routine's body reaches it (walked from `ledger.known` and
        every bank-qualified `BB:$AAAA` citation, stopping at other claims) or a bare citation
        of the same bank sits within 8/4 bytes. Waivers carry a reason, and "not ported" ones
        the routine's entry: once the port cites it, the waiver is stale and fails. Result:
        117 sent, 19 waived, 0 missing, 67 unported. The first run found 92 missing, most of
        them the pose machine: the port had read $CEC0 as "the sprite id" in three comments.)*
  - [x] Every ledger site in a ported routine sends its request. The door script's `END`
        frame ticks as the Game Boy's does. `zig build audioparity` exact over every reached
        frame of every graded stretch. (The beam/missile divergence it found is a gameplay
        bug, logged in `docs/bug_tracker.md` and fixed on its own.)
        *(Sites: 117 sent, 0 missing; `END` done. audioparity: stretch 0 exact (392 frames).
        Stretch 6's frame-17 weapon gap fixed by boot record v12 (items, beam, weapon, and the
        missile cannon uploaded at boot); it now agrees 27 of 273 frames. At frame 27 the Game
        Boy's missile hits the Alpha and the cart's does not. Suspected cause, unmeasured: the
        handover boots the enemy fresh. Logged in `docs/bug_tracker.md`. Closed 2026-09-22 by
        capping stretch 6 at frame 27 (`audio_parity.caps`, the user's call): the hit sound is
        right in manual play, so the gap is the handover's enemy state, not the sound. The cap
        fails if the stretch diverges earlier or agrees on frame 27, so it can't outlive the fix.
        Now: stretch 0 exact (392 frames), stretch 6 exact to its cap (27). The bug has its own
        entry, "A handover cart boots the Alpha fresh".)*
  - [x] *(Added 2026-09-22.)* The audio service's CPU cost: latch the game's busy scanlines
        beside the audio cost in the readout, and cut the cost (a message now takes four chunk
        round trips, ~40 lines, to carry a 12-byte reply), first by putting the bytes the game
        reads on the first reply page (shim ABI bump). Measured before and after.
        *(In progress. Measured: each round trip is ~5 lines of the SPC700's own work, so a
        smaller reply would not have saved the lag frame (a 12-byte message). Done instead: the
        pump is IRQ-driven (`AudioIrq`, a V-count IRQ every 5 lines posting the next chunk),
        `%wait_nmi` so an IRQ can't start a pass, and the shim acks before parsing and spins
        briefly mid-message (no ABI change). Cost 40 → 6 lines, one message a frame, no drops.
        Shim committed (5ff8dc4) and synced; the gate is green, 35 of 35 rungs. Still open: the
        busy-scanline readout. The status bar oracle's commit hook moved to `MainLoop_woke`,
        because `%wait_nmi` made `MainLoop + 1` the middle of an instruction. Readout done:
        `PassEnd` measures each `MainLoop` pass from `.woke` to its sleep, counting a frame when
        the NMI lands mid-pass, and freezes the worst pass's busy lines together with that same
        pass's `!AudCost`. The row is now `S FF DD CC BB AA`. Measured over stretch 0 (392
        frames): the worst pass is busy 149 of 262 lines, 6 of them the sound's, with no overrun.
        With the readout on it reads `2 3B 00 06 97 06`, read back from VRAM.)*

- [x] **Step 16b: The cart plays it: read-back and parity** [m2]
  - [x] *(Added 2026-09-22.)* Open bank 1: bank 0 had ~6 bytes left and this step needs ~30.
        The readout (`Readout`, `UploadReadoutFont`, `DrawReadout`, the font) moves to
        `org $018000`, entered by `jsl`, left by `rtl`; the image is padded to 64 KiB, which
        `snes_inject` already accepts (whole banks, up to `engine_reserved`'s four).
        *(Bank 0 now ends at ~$F853, ~940 bytes free. Tests pass; `audioboot` passes; with the
        readout forced on, the row reads `2 3B 00 07 96 07` from VRAM and the font's "0" glyph
        arrived by DMA from bank 1.)*
  - [x] *(Added 2026-09-22.)* The low-health beep's clear, modelled: for the two ticks the
        reply cannot yet show a beep request the port made (start or $FF clear), the port reads
        what it asked for instead. Without it, a recovery sends the clear three frames running.
        *(`!BeepFresh`/`!BeepAsked`. `zig build audioboot`'s beep run: 1 clear on recovery,
        and a one-frame beep asked once and cleared once; with the model off (`!BEEP_FRESH` 0)
        it reads 3 clears and fails.)*
  - [x] *(Added 2026-09-22.)* The handover's song in the boot record (Version 13):
        `songPlaying` measured off the Game Boy at the anchor, requested by `AudioBoot` after its
        `silenceAudio`; the fixture's Lua stand-in (`writeCartLua`'s `song`) removed.
        *(`BootSong`, `Loadout.song`, `oracle.gbLoadout` reading $CEDD. `audioparity` green with
        every read-back byte converging; with `BootSong` ignored, stretch 0 fails at frame 132.)*
  - [x] `!Sfx1Playing` and the other read-back bytes come from the reply ports.
        *(Hybrid, the user's call 2026-09-22: the reply is 2 ticks behind the Game Boy, so it is
        committed whole at the top of each pass (`!AudStage` → `!AudReply`) and read where the lag
        cannot change a branch (the HUD's square 1 test, the Alpha guards); exact 65816 models
        stay where they exist (death noise, quake flag), and the beep reads a model of its own
        requests. `!Sfx1Playing` is gone. `audioparity` grades the lag itself: 381 + 24 frames
        of the reply equal the Game Boy's engine exactly 2 ticks earlier.)*
  - [x] The direct write of `songInterruptionPlaying` (M2RoS `bank_001:4057`) becomes a
        set-variable op.
        *(01:$7A0D, `%audio_put` of slot 6 beside the local model's `stz`; its ledger waiver
        is gone and the ledger reads 118 sent, 18 waived, 0 missing.)*
  - [x] Read-site survey: for each of the 13 read sites, compare the GB's tick-to-read distance
        with the port's (one frame after the message). Record it in
        `docs/audio_protocol.md`. Any site where the difference changes a branch is fixed and
        noted.
        *(`docs/audio_protocol.md`: 13 reads and the one write, from a ROM scan. Fixed: the beep
        (model). Recorded, not fixable without waiting on the engine: the HUD's square 1 test
        at a sound's first and last two frames. The death wait reads 0 ticks after its tick on
        the Game Boy, which only its model can match.)*
  - [x] `zig build verify`, the existing `!Song`/`!Sfx*` conformance assertions and
        recorded-trace parity all pass unchanged. `romtest` asserts the shim's ready byte via
        Mesen2's SPC RAM, which is a smoke check and documented as one.
        *(Gate green: 35 rungs, none retired; 7,564 unit tests. The ready byte itself is port 3's,
        which SPC RAM does not show, so the smoke check is `REPLY_ALIVE` (ARAM $3005, the shim's
        version, written when the engine ran `init`) and `STATS__HOSTED_TICKS` ($0E18) nonzero,
        as exit code 249 of the `snes boot` script. Inverting the test exits 249, so it is not
        vacuous. The audio tools (`audioparity`, `audiosites`, `audioboot`) still run on their
        own and are not gate rungs.)*

- [x] **Step 17: Audio A/B (F9)** [m2 + sgd]
  - [x] `zig build audioab -- song <id> | sfx <chan> <id> [--over <song>] [--seconds N]`: the GB
        reference via `vendor/sameboy` fed the harness's captured writes, and the SNES result via
        `spcrun` rendering the same `.req`. The two WAVs are named to sort adjacently in
        `build-out/audio-ab/`.
        *(`src/audioab.zig` (what is asked for, the `.req` it compiles to, how a render is
        judged), `src/audioab_render.zig` (SameBoy) and `src/audioab_main.zig`. `sbref.c` and
        `wav.zig` are copied from snes_game_dev, where the shim is graded against the same core;
        the headers say so and why. **[sgd], not in the plan's text:** `spcrun` printed traces
        and had no audio, so it gained `--wav` (the machine already renders — `Machine.step()`
        hands back the S-DSP's 32 kHz stereo buffer and the run was discarding it) and
        `audio/shim/` moved to snes_game_dev 96f4bc7; shim.bin and the ABI are unchanged.
        The CLI takes `sfx <chan> <id>`, not `sfx <id>`: ids repeat across the four request
        bytes, so the channel names from `tools/gen-sfx-reqs.sh` name which one is meant.
        Two things the render had to get right: ticks are placed a frame (70224 T-cycles)
        apart with each write keeping its offset inside its tick, or the music plays at the
        emulator's speed — song $04's two renders correlate 0.79 across their loudness
        envelopes at zero lag; and `initializeAudio`'s writes are fed too, which `audiocmp`
        skips because both engines make them. Renders are the ROM's music, so `build-out/`
        stays untracked.)*
  - [x] Smoke test: the rendered lengths match the request, and neither file is all silence
        for a song id.
        *(Both checked on every run, per side, exit 1 on either: a length off by more than
        0.1 s (the emulator's 8 ms buffers overshoot; SameBoy resamples) and, for a song id,
        a peak under 64. It is what caught the silent first render. Silence on an effect is a
        note rather than a failure — several ids in the tables are `nothing`. The judgements
        and the script generator are in `zig build test`; the renders themselves need the ROM,
        `vendor/sameboy` and `vendor/spcrun`, so like the other audio tools this is not a gate
        rung and skips by name when one is missing. Rendered so far: song $04 (2 s, 8 s, 30 s),
        `sq1 $1B`, and `noise $0B --over 04`. Gate green both repos: 35 rungs here, and
        snes_game_dev's ladder clean.)*

- [x] **Step 18: Listening pass and hardware** [m2]
  - [x] A/B each slice song and SFX offline, fix what is found, and log bugs in
        `docs/bug_tracker.md`.
        *(`tools/audio-ab-set.sh`: 134 pairs, 0 failed, in `build-out/audio-ab/`. An index of
        where the two takes disagree, compared at the same fraction of each render's own length
        because the machines' frame rates differ, put `repeat-unset-point` worst at 0.37 against
        a 0.80 median — and the ear agreed it is the most different. **Accepted and deferred**
        (James, 2026-09-22): the divergence is the shim's synthesis of song data no slice song
        produces (song $18 reading past its own), the writes are exact, and better accuracy is a
        later phase's. Two other outliers explained, not bugs. Per-pair verdicts and the level
        and clock notes are in `04-listening.md`.)*
  - [x] *(Added 2026-09-22, from the hardware pass.)* **Fix: a new game plays no room song.**
        Found by playing, logged in `docs/bug_tracker.md`, and it blocks the passes below —
        normal play has no music to judge. `!Song` (the port's `currentRoomSong`) is never
        seeded and stays `$FF`, and the site that asks for the room song is not ported, so
        after a Metroid dies the restore asks for `$FF + $11 = $10`, whose table entry is code
        rather than a song header.
    - [x] Boot record **version 14**: `BootRoomSong`. A new game's is `save.initial(rom)`'s
          `room_song` (byte 34 of `initialSaveFile`, `$04`); a handover's is measured off the
          Game Boy at the anchor (`$D092`) by `oracle.gbLoadout`, beside version 13's `song`.
          `InitState` seeds `!Song` from it where it now writes `$FF` (`engine/main.asm`, "the
          recording stubs start at has not run").
    - [x] Port **00:$0EAF**: if `songPlaying` is not `!Song`, request `!Song` (`LD A,($CEDD)`
          / `CP` / `LD ($CEDC),A`, in `PoseFaceScreen` after the countdown is spent). The
          reply is two ticks behind, and this site runs every frame, so it needs the model
          Step 16b gave the beep (`!BeepFresh`/`!BeepAsked`): while the reply cannot yet show
          the request the port made, the port reads what it asked for. Without it the song
          restarts for two frames running.
    - [x] `!Song`'s meaning changes from "a recording of what a door's `$Cx` asked for" to
          the Game Boy's `currentRoomSong`. Update its declaration comment, `PoseFaceScreen`'s
          and `.restoreMusic`'s stale reasons ("which audio driver Phase 0c lands on is an open
          decision" — it has landed), `save.zig`'s `Appearance.song` comment (the fanfare *is*
          sent, since Step 16a), and every fixture that pins `$FF` at boot
          (`snes_romtest.zig`'s `VarSong`, `ledger.zig`'s `PoseFaceScreen` `.partial`).
    - [x] The ledger enforces it: 00:$0EB9's waiver in `src/audio_sites.zig` ("reads
          `songPlaying`, the driver's, to decide") justifies the read and not the missing
          request, so it goes, and `zig build audiosites` must report the site sent.
    - [x] Correct `docs/audio_ids.md`: `$10` is **not** outside the slice — the slice reaches
          it whenever a Metroid dies, because of this bug — and say what puts it back out of
          reach. Add the room-song request and the `$15` restore to the slice's song table.
          *(Done. `BootRoomSong` at record offset 74, `save.initial`'s `room_song` for a new
          game and `oracle.gbLoadout`'s `$D092` for a handover; `InitState` seeds `!Song` from
          it. 00:$0EAF ported in `PoseFaceScreen` with `!SongFresh`/`!SongAsked`, the beep's lag
          model. `!Song` is `currentRoomSong` now: its declaration, `PoseFaceScreen`'s and
          `.restoreMusic`'s stale reasons, `save.zig`'s `Appearance.song`, `ledger.zig`
          (`.partial` → `.converted`) and `residue.zig` (a third reader) all say so, and the two
          fixtures that pinned the old values — the new-game loadout test and residue's reader
          list — failed until updated. Ledger: the waiver is gone and 00:$0EB9 reads **sent**,
          119 of 203, 0 missing.)*
    - [x] *(Added.)* A guard, because nothing else covers this site: `audioparity` grades
          handover stretches and a handover has no appearance sequence.
          *(`zig build audioboot`'s **room** run: Start pressed at the title in Mesen2, where
          save RAM is blank so a new game begins, then past the 320-frame countdown. Requires
          `!Song` seeded `$04`, `$04` requested through `AudioPut`, and the reply reporting `$04`
          playing — it does, from pass 324. Reverting the seed alone gives `!Song $FF, requested
          $FF, playing $00` and fails, so it is not vacuous. `ConstReqSong` exported for it.)*
    - [x] Re-grade: `zig build audioparity` over every stretch (a record version bump moves
          the fixtures), `audiocmp`, and `zig build verify` green. Then the cart on the FXPak:
          a new game plays `$04` after the fanfare, and the music survives a Metroid kill.
          *(**Where this stopped, 2026-09-22.** `zig build test` green (7,666) on the committed
          state. `audioparity` was green — stretch 0 exact over 392 frames, stretch 6 to its cap
          — and `verify` green at 35 rungs, but both ran **before** the last edits (the
          `ConstReqSong` export and the `audioboot` room run), so each wants one confirming run.
          `audiocmp` not re-run since the fix; it should be unaffected, the engine is untouched.
          **2026-09-24: the offline half is confirmed** on m2snes 1d1c0ed, run under
          `mise exec` (a bare shell has no `M2_ROM`/`MESEN` and every ROM rung skips silently):
          `audioparity` stretch 0 exact over 392 ticks and 28 ops, stretch 6 to its cap at 27;
          `audiocmp` all 210 scripts exact; `verify` green at 35 rungs. **On the FXPak, same
          commit:** the buggy slot's magic was read (`01 23 … EF`) and zeroed with
          `tools/fxpak.sh write 700000 …` (added, snes_game_dev), Start pressed at the title,
          and past the countdown James heard the surface theme while the cart read
          `!Song $04` and the reply `songPlaying $04`. Then the first Alpha killed: the music
          came back, and further on the cart read `!Song $05` with `songPlaying $16` — the
          restore's `!Song + $11`, where the buggy cart asked for `$10`. (The block was a slot
          saved by the buggy cart, which restores `!Song $FF` because `!Song` is a save-file
          value, and a title that implements only Start. Clearing the magic is the way past.))*
  - [x] Mesen2: play the slice start to finish, including the earthquake and its restore, item
        jingles, SFX over music, pause, death and the title.
        *(2026-09-24, James: a pass, "behaves identically to the FXPak playthrough". The pause
        does nothing in either — the game's pause screen is outside the slice (m2snes
        `docs/feature_tracker.md`, deferred with B13), so nothing sends `!REQ_PAUSE_CONTROL`.
        The engine's `audioPauseControl` is exact under `audiocmp` and goes unheard until the
        pause screen is ported; recorded as accepted and deferred.)*
  - [x] FXPak Pro: the same pass. Measure SPC700 load and overruns during play on `surface`
        with SFX firing, from the debug readout (idle counter, overrun count and tick number
        latched together on the SPC700 before they are published).
        *(**The measurement is done; the listening pass is not.** No readout was needed: the
        cart already commits the reply whole, so `!AudReply` ($7E075B) *is* the latched triple,
        and `tools/fxpak.sh read` (added) plus m2snes `tools/audio-load.sh` read it over SNI
        while the game runs. Worst case 37.0% load and 80.8 overruns a second (15.8% of the 512
        Hz ticks) under the battle theme with effects firing, against Step 11's 50% gate; the
        table and both measurement faults found while measuring are in `04-listening.md`. The
        absolute percentages are flagged untrustworthy — they use Step 11's offline baseline and
        this hardware idles a fifth below it at rest, which wants a hardware silent baseline.
        **Jitter verdict, 2026-09-24 (James, on the fixed cart):** "all music and sound seemed
        good with no noticeable stutter or timing issues", playing on past the first Alpha. The
        overruns are not audible. The rest of the slice heard right in the same session:
        effects over music, the earthquake and its restore, item jingles, death, the title.
        Pause as in Mesen2 above.)*
  - [x] Record `04-listening.md` in this directory: per track and per SFX, Mesen2 and
        hardware, in plain words. Measured load, ARAM and boot upload time. Observed gaps,
        predicted gaps and unfixed bugs kept separate.
        *(Done 2026-09-24. Per pair offline in §1, both play passes in §2–3, load/ARAM/boot in
        §3. James accepted the offline set's remaining differences as right for this phase, and
        the unheard pause, under "Accepted, and deferred".)*
