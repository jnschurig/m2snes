---
created: 2026-08-23T08:03:00Z
updated:
  - 2026-08-23T08:03:00Z
  - 2026-08-23T22:06:54Z
  - 2026-08-23T22:22:35Z
  - 2026-08-24T03:51:00Z
  - 2026-08-24T05:40:38Z
  - 2026-08-24T15:31:00Z
  - 2026-08-24T18:05:25Z
  - 2026-08-24T20:02:48Z
  - 2026-08-24T23:49:43Z
  - 2026-08-25T02:47:58Z
  - 2026-08-25T03:32:00Z
  - 2026-08-25T05:12:00Z
  - 2026-08-26T19:11:44Z
  - 2026-08-27T17:44:00Z
  - 2026-08-27T18:54:07Z
  - 2026-08-27T20:36:53Z
  - 2026-08-28T04:24:06Z
  - 2026-08-28T05:42:07Z
  - 2026-08-30T01:09:21Z
  - 2026-08-30T03:12:12Z
  - 2026-08-30T03:53:18Z
  - 2026-08-30T04:14:52Z
  - 2026-08-31T02:14:34Z
  - 2026-08-31T02:54:09Z
  - 2026-08-31T04:13:55Z
  - 2026-08-31T15:57:58Z
  - 2026-08-31T19:16:35Z
  - 2026-08-31T21:54:22Z
  - 2026-08-31T22:13:30Z
  - 2026-08-31T23:07:00Z
  - 2026-09-01T03:12:33Z
  - 2026-09-01T04:05:00Z
  - 2026-09-01T04:40:00Z
  - 2026-09-01T14:24:04Z
  - 2026-09-01T14:52:00Z
  - 2026-09-01T15:38:00Z
  - 2026-09-01T16:45:00Z
  - 2026-09-01T17:29:02Z
  - 2026-09-01T18:04:16Z
  - 2026-09-01T19:17:33Z
  - 2026-09-02T00:16:37Z
  - 2026-09-02T03:33:19Z
working_directory: /Users/james/git/snes_game_dev
---
# Implementation Plan

## Status: Complete

## Overview

**This plan covers Phase 0a only** — the go/no-go milestone where the entire asset base of
Metroid II is converted, verified, and inspectable, the builder runs end to end against a
pre-assembled engine image, and Samus moves in a booting ROM. Phase 0b (the playable slice)
is stubbed at the bottom and gets its own cycle, because two Phase 0a outputs materially
determine how it should be planned: the table-driven dispatch survey (Step 16) and whether
the pre-assembled image's reserved asset regions are sized correctly (Step 8).

**Amended 2026-09-01: audio is no longer in this plan.** F8 moves whole to **Phase 0c**, stubbed
at Step 17 and getting its own cycle, and `01-requirements.md` is amended to match — D1 drops
its two audio criteria and the Phasing section states what that costs. What remains of Phase 0a
is Step 15b's oracle infrastructure, Step 16's survey and Step 18's gate.

Work is ordered so that verification arrives with the thing it verifies, and so nothing
depends on a later step. The GB emulator lands early (Step 6) because three separate
deliverables need it — reference rendering, the TAS oracle, and audio capture. That third
consumer is now Phase 0c's, which does not change Step 6's placement: it shipped `src/gb/apu.zig`
already, so 0c inherits the capture foundation rather than building it.

That invariant was broken once and repaired on 2026-08-27: the oracle was Step 14 and the
harnesses were Step 15, but a frame-for-frame comparator cannot start until something can
place Samus identically on both machines, which is the room harness. The two steps are now
swapped, and the SNES half of "place her" — a boot-record start position — is a sub-task of
the harness step rather than an assumption of the oracle's.

Target repository is **new, standalone, and private**. Paths below are relative to that repo,
not to `snes_game_dev`.

### Standing decisions for this phase

- **No CI.** Every gate below is a local command (`zig build verify`), not a hosted job. All
  of the interesting gates need the user's retail ROM, which a public runner cannot hold, so
  CI is deferred until the repository move — at which point the ROM-free subset (build, unit
  tests, offsets invariants) can be split out and hosted. Assets extracted from the ROM stay
  untracked regardless, so the option is never closed off.
- **Two disassemblies, used for different things.**
  [M2RoS](https://github.com/metroidret/M2RoS) is the **behavioral spec**: it is hand-labeled,
  and every load-bearing fact in `01-requirements.md` comes from that labeling. It ships no
  LICENSE. Rights are *assumed available* for this phase — the repository is private, and an
  issue was filed against M2RoS on 2026-08-23 asking the owner to add an explicit license.
  Pending that answer, the plan reads M2RoS freely; Step 2's `note` fields and Step 16's
  independent verification are what make the work survive a restrictive answer or no reply.
  [Vashy777/metroid2](https://github.com/Vashy777/metroid2) is **MIT-licensed but mechanical**:
  a `mgbdis` dump (last pushed 2021-11) whose bank 0 carries 765 labels, all auto-generated
  `Call_000_xxxx` / `Jump_` / `Data_` except the ~20 `mgbdis` emits from `hardware.inc`. It
  contains no semantic naming, so it is not a substitute for M2RoS as a spec — but routine
  *boundaries* are mechanical facts, which is exactly what Step 14's ledger needs. Note that
  an MIT file cannot relicense Nintendo's code; it covers the author's own contribution.
  Practical split: **understanding** comes from M2RoS and is laundered into independently
  verified facts by Step 2's `note` fields and Step 16's re-derivation; the **mechanical routine
  inventory** comes from the MIT disassembly, or from running `mgbdis` on the user's own ROM,
  which reproduces it without depending on either repository.
- **Audio driver is TAD** (Terrific Audio Driver, zlib). `snes_game_dev`'s `engine/tad.zig`
  is an existing 65816 port with a working IO protocol, and `vendor/tad-src` carries upstream.
  One wrinkle carries into Phase 0c: `snes_game_dev` compiles songs with the Rust
  `tad-compiler` at build time, which the shipped Metroid 2 builder cannot require, so TAD's
  song binary format must be emitted directly from Zig. That is 0c's largest single piece of
  work and the reason audio became its own phase — see Step 17.
- **SNES-side state traces come from Mesen2 Lua**, matching the house pattern already in
  `test/audio.lua` and `test/engine.lua`.

## Steps

- [x] **Step 1: Repository, toolchain, and ROM ingest**
  - [x] Create the standalone private repo with a Zig build (`build.zig`, `build.zig.zon`)
        — at `~/git/m2snes`, local git only, no remote
  - [x] Define the `zig build verify` entry point that every later step's gate hangs off,
        with a clear "needs the retail ROM" failure message when it is absent
  - [x] Pin `asar` as a dev-time build dependency; document that it never runs on an end
        user's machine — `tools/get-asar.sh`, pinned to 1.91. **The script's build was not
        run**: this sandbox has no network. Confirm it on a connected machine before Step 11
  - [x] Implement ROM ingest: read the user's GB ROM, verify it is the **World (W) revision,
        256KB** by hash, reject anything else with a message naming the expected version
  - [x] Add a `.gitignore` policy mirroring M2RoS's model: extracted assets, reference frames,
        and the ROM itself are never tracked
  - [x] Add a local tracked-file policy check to `verify`: no tracked binary above a small
        size ceiling, and when a ROM is present, scan tracked files for n-gram matches against
        it. This is a hygiene check, not a legal proof — say so in its output
  - [x] Verify: `zig build verify` passes; ingest accepts the known-good ROM and rejects a
        truncated copy and a wrong-revision copy — **both directions now verified**: rejection
        against synthetic fixtures, acceptance against the retail ROM (all six ingest rungs,
        sha1 `74a2fad8…`)
  - [x] Pin the toolchain with `mise` (`mise.toml`: Zig 0.16.0, `M2_ROM`, `MESEN`) — added
        on request, not in the original plan

- [x] **Step 2: Re-derived ROM offsets table**
  - [x] Write `src/offsets.zig` in the style of `snes_game_dev`'s `ff6/offsets.zig`: every
        entry carries kind, address, size, and a `note` recording **how we know**
  - [x] Populate entries for graphics banks, area tilesets, metatile definitions, collision
        and solidity tables, map banks `$9`–`$F`, door script pointers and data, enemy data
        tables, metasprite tables, and the sound driver entry point — 114 entries. Three
        classes left explicitly `pending` rather than guessed: samus pose tables, physics
        constants, title tilemap
  - [x] Independently verify each offset against the retail ROM and record the derivation,
        so the table stands on its own regardless of M2RoS's licensing outcome — **verified
        against the retail ROM** (sha1 `74a2fad8…`, the expected World revision).
        `verifyAgainstRom` ran 21 shape checks over the 114 entries and all passed: solidity
        rows end `$FF`, scroll flags use only bits 0–3, screen pointers land in
        `$4500`–`$8000`, pointer tables address their own paged window, audio trampolines are
        `$C3`. The 3 `pending` classes remain unpinned by design. `mise.toml` now resolves the
        ROM automatically, so `zig build verify` exercises the ROM path with no setup.
  - [x] Verify: a test asserts entries do not overlap, sizes stay in bounds, and every entry
        has a non-empty `note` — plus bank straddling, unique names, paged-window addresses,
        and the two arithmetic claims (bank 8's gapless metatile block; the enemy pointer
        table's size falling out of map geometry). 24/24 tests pass
  - [x] Record the lavaCaves naming discrepancy: M2RoS orders the metatile variants
        Mid/Empty/Full, `01-requirements.md` says Full/Mid/Empty. Addresses agree, naming
        does not — resolve in Step 3
  - [x] **Correction, made during Step 7:** the eight collision tables were named in bank 8's
        *layout* order, which is not the order a `COLLISION` operand indexes. Derived from the
        ROM the same way `tiletable_order` was — every door script issuing `COLLISION $n` loads
        exactly one tileset's graphics, all eight slots pinned by 3–27 scripts each, no operand
        pairing with two tilesets. The true order is plantBubbles, ruinsInside, queen, caveFirst,
        surface, lavaCaves, ruinsExt, finalLab: finalLab moves from first to last and everything
        else shifts up one. `SOLIDITY` indexes the same list. Corroborated without the door
        scripts at all — solidity row 5 thresholds at 66 and lavaCaves is the only tileset with
        fewer than 128 metatiles (69), while layout order would hand lavaCaves row 6, whose 100
        overruns a 69-entry table. Two new tests pin it from those two independent directions,
        and both were confirmed to fail when the old order is injected

- [x] **Step 3: Asset extraction — graphics, metatiles, collision**
  - [x] Extract tile graphics for all classes: area tilesets, Samus, enemies, items/HUD,
        title and credits — `src/gfx.zig` decodes GB 2bpp (16 bytes/tile, low bitplane
        first, bit 7 leftmost) losslessly in both directions; 2,971 tiles across 43
        entries, emitted as raw `.bin` plus a decoded one-byte-per-pixel `.pix` strip.
        Pixel values are palette *indices*: nothing here guesses at colour, which is
        Step 8's problem
  - [x] Extract metatile definitions, including the three `lavaCaves` variants that are
        `$114` bytes where the other seven are `$200` — 1,103 metatiles over 10 tables
        (128 each, 69 for each lavaCaves variant). **The 2×2 byte order was derived, not
        assumed**: TL/TR/BL/BR minimises seam discontinuity on all four single-variant
        tilesets, while the column-major reading scores *worse than a scrambled control*.
        A test re-derives this from the ROM on every run
  - [x] Extract collision and solidity tables per tileset — eight `$100` collision tables
        (one behaviour byte per tile id, gapless and in the same order as the solidity
        rows) and the shared `$20` solidity table, parsed as 8 rows of 3 thresholds with
        `$FF` terminators; a malformed terminator fails extraction rather than shipping
  - [x] Verify: extraction is deterministic across runs; per-class byte counts match the
        sizes declared in `src/offsets.zig` — `zig build verify` runs the extraction
        twice and compares the manifests (which carry a SHA-256 per output file, so a
        reordered or dropped record is caught too, not just changed bytes), and asserts
        every raw output is exactly its declared size. 67 entries reproduce byte-for-byte;
        the other 47 are Step 4 kinds and are counted as deferred, not as covered
  - [x] Settle the `lavaCaves` variant naming left open by Step 2 — measured from the ROM,
        the tables differ by 33 (Mid↔Empty), 28 (Mid↔Full) and 52 (Empty↔Full) metatiles.
        The endpoints are the pair that differs most, so `$5594`/`$56A8` are the extremes
        and `$5480` is the intermediate: M2RoS's **Mid/Empty/Full** labels are correct and
        the positional Full/Mid/Empty reading was wrong. `01-requirements.md` amended
        accordingly (this sub-task was not in the original plan)

- [x] **Step 4: Asset extraction — maps, doors, behavior tables, metasprites**
  - [x] Extract map data for banks `$9`–`$F`: screen pointer tables, per-screen scroll flags,
        room transition indexes, and all screen bodies — `src/map.zig`; 413 distinct screen
        bodies, exactly 7 banks × 59, emitted as per-bank grid and screen text
  - [x] Extract door script data and decode it to a readable operation form — `src/door.zig`
        implements all 16 opcode groups with a matching encoder. Unknown opcodes are
        **refused**, not skipped: the reference extractor ignores them, which would
        desynchronise the stream. Sources resolve against `offsets.zig` by *containment*
        rather than equality, which is what the four `bg_queenHead` rows need
  - [ ] Extract behavioral tables: enemy headers, hitboxes, damage values, physics constants,
        pose tables — **3 of 5 done**. Headers (52 × 11 bytes), hitboxes (44 × 4 signed
        bytes) and damage (255 entries) extract, and the record strides are **derived from
        the pointer tables rather than inherited**: region size alone permits 4, 11, 13, 26,
        44, 52 and 143 for the header region, but 11 is the only stride above 1 that every
        one of the 51 distinct in-region pointers is a multiple of. The hitbox case is
        weaker and the test says so — 1, 2 and 4 all survive, so 4 is the largest
        consistent stride rather than a forced one. Note this is *framing*, not meaning:
        the 9 header bytes and the 4 hitbox bytes are not yet interpreted.
        **Physics constants and pose tables are still the `pending` entries from Step 2** —
        immediates inside bank 0/1 code with no address comments, so pinning them needs
        the disassembly work in Steps 13 and 15, not a table read. Left unchecked
        deliberately
  - [x] Extract metasprite definitions for Samus, enemies, and credits — 308 metasprites,
        2,105 parts, `$FF`-terminated 4-byte parts in GB OAM order with signed placement
  - [x] Verify: the 905 in-use screens are all reached; decoded door scripts round-trip to
        the same operation stream on a re-decode — **both hold, and 905 is now derived
        rather than assumed**: it is exactly the count of grid cells whose pointer is not
        the shared blank at `$4500`. 904 resolve; the 1 that does not is a null `$0000` in
        bank `$A`, counted rather than folded away. The door stream re-encodes to the
        region byte-for-byte across all 1,872 operations
  - [x] Cross-check the decoded stream against figures the requirements recorded
        independently — 171 `IF_MET_LESS` transitions across 13 thresholds, matching
        exactly, reached through our own decoder rather than by reading the other
        disassembly. Every pointer in both tables is accounted for: 512 door pointers =
        497 on an op boundary + 14 empty (`$55A3`) + 1 freespace; 362 metasprite pointers
        = 361 records + 1 at `$C300`, a WRAM address and so a dead slot (not in the
        original plan)
  - [x] Fix the Step 1 file policy, which flagged the user's own gitignored ROM — it
        walked the raw working tree, which cannot distinguish a deliberately ignored
        local ROM from a leak. It now scans `git ls-files --cached --others
        --exclude-standard` (what could actually be committed) and falls back to the tree
        walk when git is absent, reporting which mode ran. Verified both directions: the
        ignored ROM passes, a planted untracked 64-byte ROM slice still fails (not in the
        original plan)

- [x] **Step 5: Round-trip verification and coverage reporting**
  - [x] For every class in Steps 3 and 4, implement encode-back and assert byte-identity
        against the source ROM, run exhaustively over all assets — `src/roundtrip.zig`,
        with the encoders living beside their decoders (`gfx.encodeAll`,
        `tileset.encodeMetatiles`/`encodeSolidity`, `map.encodePointers`/`encodeFlags`/
        `encodeTransitions`/`encodeScreens`, `entity.encodeHeaders`/`encodeHitboxes`/
        `encodeMetasprites`). **112 of the 114 entries re-encode byte-for-byte**;
        the switch over `offsets.Kind` is exhaustive, so a new kind added without
        deciding how it round-trips fails to compile
  - [x] **What a round-trip proves is recorded per class, not averaged away** — three
        levels: `encoding` (bytes are *reconstructed*: 2bpp bitplanes repacked, `$FF`
        terminators re-emitted, door opcode streams rebuilt), `framing` (records
        re-serialised field by field, so stride/count/order/endianness are proven and
        meaning is not), and `raw` (no decoder). Claiming 100% while quietly copying
        the undecoded classes is the exact failure this step exists to prevent, so the
        two raw classes are excluded from the number and named instead. Not in the
        original plan, but the number is misleading without it
  - [x] Wire round-trip into `zig build verify` as a hard local gate — **verified in
        both directions**: with a deliberately corrupted encoder the unit test fails,
        `verify` prints `FAIL round-trip 40 of 112 entries`, names the entries with the
        first differing offset, and exits 1; reverted, it exits 0
  - [x] Write the coverage reporter in the spirit of `ff6/assets_report.zig`: classes covered,
        items derived, bytes reached, and the **named list of what is still missing** —
        `src/coverage.zig`, printed by `zig build coverage` and written to
        `extracted/coverage.txt` by the gate. 26 classes, 17,633 items, 193,578 of
        262,144 bytes claimed (73.8%)
  - [x] Verify: round-trip passes for 100% of extracted assets; coverage report shows no
        silently-unhandled class and flags unclaimed ROM regions — all three hold.
        *No silently-unhandled class*: a test ties every `raw` kind and every `pending`
        offsets entry to a named line in `coverage.not_yet_decoded` with a why and the
        step that needs it (7 entries), so an unread class cannot exist without a work
        item. *Unclaimed regions*: 16 runs / 68,566 bytes, split at bank boundaries and
        listed per bank above 64 bytes, excluding only banks `$0` and `$2` (pure code).
        Banks `$9`–`$F` are 100% claimed and **that is a gate**, not a report — an
        unclaimed byte in pure map data is a table we failed to catalogue
  - [x] Prove the comparison is not vacuous — mutating the *decoded* form (a pixel index,
        a header's little-endian word, a dropped door op) must break the re-encode, or an
        encoder that copied its input instead of rebuilding from the decoded values would
        pass. All three mutations are caught (not in the original plan)

- [x] **Step 6: GB emulator core — CPU, MBC, APU register capture**
  - [x] Implement the SM83 CPU in Zig, deterministic and frame-steppable — `src/gb/cpu.zig`.
        **Decoding is structured, not transcribed**: the 512 opcodes factor into
        `x`/`y`/`z` and the register tables those index, so the tables are written once
        and every instruction using them is right or wrong together — a failure mode a
        test can find, where 512 hand-written cases give 512 independent chances to
        mistype a register index. The eleven illegal opcodes are refused rather than
        executed as something else. The CPU takes any `bus` with `read`/`write`, so it
        runs against a flat 64 KiB array in its own tests
  - [x] Implement MBC banking as the retail cartridge uses it — `src/gb/cart.zig`. MBC1
        with the bank-0→1 rule, mode 0/1, RAM enable and RAM banking; an unknown mapper
        is refused rather than approximated. The cart declares `$03`/`$03`/`$02`:
        MBC1+RAM+battery, 256 KiB, 8 KiB of save RAM
  - [x] Implement APU register capture: log writes to `$FF10`–`$FF26` and `$FF30`–`$FF3F`
        with frame timestamps — `src/gb/apu.zig`. Capture, **not synthesis**: no
        envelopes, no sweeps, no samples. Step 17 needs the write sequence, not audio,
        and a synthesised waveform would be a second thing to be wrong about. Writes to
        a powered-down APU are still logged — what the driver *did* is the artifact
  - [x] Split the module so CPU+APU can ship inside the builder while PPU (Step 7) stays in
        the dev test suite — the seam is `bus.Video`, a plain function pointer, so
        `bus.zig` has no import of a rasteriser at all. `lcd.zig` runs the *timing* the
        CPU can observe (LY, the mode machine, VBlank and the edge-triggered STAT line),
        which is what makes the game run; with nothing registered, VRAM and OAM are plain
        memory and the renderer is unreachable
  - [x] Bring up the standard SM83 test-ROM suites (blargg `cpu_instrs`, `instr_timing`;
        mooneye acceptance where cheap), fetched by a script into an untracked directory —
        `tools/get-testroms.sh` into `vendor/testroms/`. **All eleven `cpu_instrs` groups
        pass, plus the combined 64 KiB build** (the only one that exercises bank
        switching) **and `instr_timing`**. Individual groups are run separately because
        the group name is the diagnosis. **Mooneye is declined, not forgotten**: Gekkio
        publishes no releases or tags, so it means assembling with RGBDS, a toolchain
        nothing else here needs — the plan said "where cheap", it is not, and the script
        records why
  - [x] Verify: the test ROMs report pass via their serial output; a per-frame CPU/memory
        state trace of the retail ROM is byte-reproducible across runs — both hold, and
        the gate reports `600 frames reproduce, 8M instructions, bank 4, 4725/8192 VRAM`.
        **Liveness is checked alongside reproducibility**, because a machine that crashed
        on instruction one is also perfectly reproducible: frames completed, LCD still on,
        VRAM actually written, millions of instructions retired. Comparison is per frame
        rather than end-state, so a divergence that later reconverges is still caught
  - [x] Prove the suite can fail — a one-nibble error in DAA's high-nibble subtract
        correction was injected, and blargg named `01-special` and `11-op-a-hl`. The
        CPU's own DAA unit test did *not* catch it, so that blind spot was closed with
        direct cases for both carry paths (not in the original plan)
  - [x] Fix two bugs found in this step's own test machinery rather than in the emulator:
        the blargg runner computed "passed" from a list it had already emptied, so every
        run would have reported success; and `trace.capture` returned a sub-slice of its
        allocation, which is an invalid free rather than a smaller one (not in the
        original plan)

- [x] **Step 7: GB PPU (background rendering) and reference frames**
  - [x] Implement background rendering sufficient to rasterize any screen: tilemap fetch,
        scroll registers, the scanline-135 status bar split — `src/gb/ppu.zig`, per-scanline,
        driven from the `bus.Video` seam at the *start of mode 3* (the seam previously fired at
        end-of-line, which would have attributed any mid-frame register write to the line already
        drawn). **The status bar is not a scroll split and not scanline 135:** measured against the
        running game there is no mid-frame scroll write at all — it is the *window*, parked at
        WY=136 with WX=7. 135 is the last line of the play area, which is presumably where the
        plan's figure came from. The play window is therefore 160×136 with an 8-line bar below.
  - [x] **Pin the `WARP` operand by surveying the door-script interpreter** — pulled
        forward from Steps 15/16 on the user's call, because Step 7's frames cannot be
        rendered without it and the plan's rule is that no step depends on a later one.
        Scoped to the one question, not the whole ledger: what the interpreter does with a
        `WARP` operand, and where the resulting room/area code lives in RAM. Done by static
        disassembly, on the user's call between three options; the live cross-check turned
        out to be possible after all and was done too
    - [x] Locate the door-script interpreter: run the retail ROM under our own emulator and
          record the PC of every read that falls inside the door-script data region, so the
          fetch loop and its opcode dispatch are found by observation rather than by reading
          someone else's labels — built as `src/gb/probe.zig` (a `bus.ReadWatch` seam, unset
          in the shipped builder) plus `zig build probe`. **Watching did not find it.** The
          exploration monkey never reaches a door, so the script region is never read no
          matter how long it runs; a 90s and a 400s run record identical bank-5 numbers. The
          probe's conclusion that the code "lives in bank 5 beside its data" was about a
          different subsystem — bank 5's own graphics loader at `$40xx`. **The interpreter is
          in bank 0 at `$239C`,** found by searching the ROM for the instruction that loads
          the pointer table's address (`21 E5 42` = `LD HL,$42E5`, at 0:`$23C9`) — one grep,
          after two days of watching. The lesson is recorded in `probe.zig`'s module comment
    - [x] Disassemble the `WARP` handler from the ROM with our own SM83 decoder, and write
          down what the operand is transformed into and which RAM addresses receive it —
          built `src/gb/disasm.zig` and `zig build disasm`. Decoding is structured the same
          way `cpu.zig` decodes but written independently, so a test can run all 512 opcodes
          through both and compare the length this reports against how far the CPU moved PC.
          It follows control flow from named entries rather than sweeping linearly, so bytes
          it never reached stay marked unknown instead of decoding into confident nonsense.
          What the ROM says:
          `$239C` reads a 16-bit door index from `$D08E`/`$D08F` and indexes the 512-entry
          pointer table at 5:`$42E5`; dispatch is a linear if-chain on the opcode's high
          nibble. `$28FB` is the `WARP` handler — **opcode low nibble → `$D058`, written to
          `$2100` to map the map bank; operand high nibble → `$FFC9` (screen row); operand low
          nibble → `$FFCB` (screen column)**, each stored twice, once live and once into the
          save-record block. `$0835` forms the cell index as `row * 16 + col` and indexes the
          screen-pointer table at `$4000` of the mapped bank. Two unplanned confirmations fell
          out: `$242F` shows `SOLIDITY` indexing 8:`$7EFA` in 4-byte rows, and `$0C66` forms
          the same `row * 16 + col` index for the transition table at `$4300`, whose words
          carry a flag in bit 11 that `RES 3` clears — with that cleared, all 394 door indexes
          the map references fall below 512, which independently confirms the 512-entry table
    - [x] Cross-check against the running game: at each warp, compare the operand to the
          bank/screen the game actually lands on. **Directed input was not needed.** The
          interpreter takes its argument in RAM, so a booted machine can be asked to execute
          it directly: `zig build probe -- doors` snapshots after boot, writes the door index
          to `$D08E`, calls `$239C`, and watches which screen-pointer entry the engine reads.
          All 512 scripts ran; **369 loaded a screen and every one read the cell the operand
          names — 0 disagreements.** Run three times with different sub-screen offsets: the
          first screen read moved for 368 of 369, while the row and column the handler wrote
          were identical every time, which is what separates "the operand names Samus's
          screen" from "the operand names the screen that got drawn"
    - [x] Replace `screens.assign`'s grid-cell reading of the operand with the derived one —
          **there was nothing to replace: the reading was already right.** This step's premise
          was that `y*16+x` must be wrong because it "lands on a blank screen 50 of 62 times".
          The observation was true and the conclusion was not. The operand names where Samus's
          *position* lands; the camera is derived from her full 12-bit position (`-$74` in Y,
          `+$50`/`-$60`/`±$80` in X, depending on which way the door is crossed) and the door
          preserves her offset *within* the screen, so the borrow or carry moves the drawn
          screen by at most one cell. That is exactly the distance from those 50 filler cells
          to the room beside them. Recorded instead of replaced: both halves of the derivation
          are now re-derived from the ROM by tests in `screens.zig` that follow the handler's
          stores symbolically through our own disassembler, and swapping the row and column
          constants makes them fail
    - [x] Handing a filler-cell warp to its single in-use neighbour — only where there is
          exactly one, since two is genuinely undecided by the ROM — raises `door` provenance
          from 13 in-use screens to 41, with `conflicts` still 0 (not in the original plan)
    - [x] Verify: report the resulting `by_provenance` split rather than asserting a hoped-for
          number. **41 door, 838 scrolled, 25 bank default**, `conflicts` 0, and every metatile
          index still resolves inside its assigned table. The hoped-for number in the original
          plan — "rises to the number of distinct warp targets" — was never reachable: only 62
          of the 305 distinct warp targets have a metatile table in effect when they warp, and
          50 of those 62 land on filler cells. Most screens still inherit by scrolling, and
          that is a limit of the ROM's data rather than something this step left undone
  - [x] Render a reference frame for each of the ~300 in-use screens, into an untracked
        output directory — **904 frames**, one per in-use cell that resolves to a body (905 in
        use, less the null pointer in bank $A), written to `extracted/frames/` by
        `zig build frames`. Full 256×256 screens rather than the 160×144 the Game Boy shows,
        so Step 9's diff covers the whole room instead of the quarter that fits on screen. The
        loop lives in `screens.zig` behind a `FrameSink` — the same plain function pointer
        shape as `bus.Video` — so the gate renders every screen without linking a PNG writer
        and the tool writes images through the same code rather than a copy that could drift.
        BGP is measured rather than chosen: running all 512 door scripts reports the palette
        each leaves behind, and 274 of the 369 that load a screen leave `$93`
  - [x] Leave OAM and sprite composition unimplemented — deferred with the assembled-metasprite
        view per F9. Held to deliberately: the SameBoy comparison masks object pixels rather than
        rendering them, so no sprite can paper over a background bug.
  - [x] Verify: the title screen and at least five gameplay screens are **pixel-identical** to
        SameBoy's output at the same frame — 10 captures, 4 on the title screen and 6 in play,
        all matching. Alignment is exact rather than searched: the comparison runs from power-on
        with SameBoy's own boot ROM (its reimplementation, assembled from source under `vendor/`,
        never tracked) so both sides share a cycle origin, and `testerButtons` reproduces the
        tester's 69905-cycle input schedule so both receive the same input on the same cycle.
        Residual: on 2 of the 10, our emulator places Samus a few pixels from SameBoy's — 66
        object pixels in total, every one within 8 px of a sprite, with the backgrounds around
        them identical. That is an emulator state divergence, not a rasteriser bug; it is bounded
        by `object_slack`, printed on every run, and gated so it cannot grow past 256 px.
  - [x] Verify: reference frames are byte-stable across runs — checked two ways, and by the
        gate rather than by hand. Every screen is rendered twice from the same inputs and the
        two compared (0 differ), and a SHA-256 over all 904 frames in cell order is printed on
        every run; two separate runs of `zig build frames` produce identical 904-line
        manifests, digest for digest. The gate line is
        `ok frames  904 screens render reproducibly, 05c95b96439a951f`.
        Two numbers are reported rather than smoothed over: 0 metatile indexes are out of
        range, but **72 of the 904 frames draw at least one quarter-metatile from VRAM no
        door script wrote** (103 before Step 8's `LOAD` correction below) — a screen renders through the VRAM of the door that named it, and
        a door does not always load every tile the screens downstream of it use, so those come
        out as colour 0. That is a hole in the picture, not a wrong colour, and Step 9's diff
        should be read knowing it
  - [x] Unplanned: fixed two things this step exposed. The joypad interrupt was never raised on
        a key press (harmless while nothing drove input; wrong the moment something did), and
        `Bus` gained optional boot-ROM mapping with `Cpu.powerOn` so a run can start at $0000.

  **Note — the screen→tileset pairing is only partly in the ROM, and now we know exactly how
  partly.** Map banks hold metatile indexes and nothing else. Door scripts state the pairing
  outright for the screens they warp to, and Step 7 pinned what a warp names: the operand's
  high nibble is the screen row and its low nibble the column, read out of the handler at
  0:`$28FB` and confirmed by executing all 512 door scripts on a booted machine (369 loaded a
  screen; every one read the cell the operand names). What the ROM does **not** carry is
  Samus's offset within that screen, and the camera is derived from her full 12-bit position,
  so the screen actually drawn can be one cell off the one the operand names. Nothing recovers
  that statically.

  The earlier reading of this note was wrong in its conclusion, and it is worth keeping why.
  "The `WARP` operand read as a grid cell lands on a blank screen 50 of 62 times" was a true
  measurement; "so its meaning is not `y*16+x`" did not follow. Those 50 are filler cells one
  step from the room the door opens into, which is exactly the distance the camera arithmetic
  can move. Handing such a warp to its single in-use neighbour — only where there is exactly
  one — raises `door` provenance from 13 screens to 41 with `conflicts` still 0. The other two
  candidate sources still fail: transition indexes name a door for 115 screens but assign bank
  9 a tileset the door warps contradict, and seam-energy scoring does not discriminate between
  tilesets, only between permutations of one.

  So `src/screens.zig` still records a `Provenance` per screen rather than one
  confident-looking answer, and the split is **41 `door`, 838 `scrolled`, 25 `bank`**. The
  remaining 838 are a limit of the ROM's data, not an unfinished survey: only 62 of the 305
  distinct warp targets have a metatile table in effect when they warp at all. **Step 9 should
  be read with this in mind:** its diff stays valid at any provenance, because both sides read
  the same pairing, but the frames are only pictures of the real game where provenance is
  `door`.

  Also found and since fixed: the collision-table names from Step 2 were rotated by one. See
  the Step 2 correction above — it was made during this step.

  **Correction, made during Step 8: `LOAD`'s destination and length were both wrong.**
  `screens.zig` had `LOAD_spr` writing to `$8000` and both `LOAD`s taking their length from
  the source entry's own size. The handler at 0:`$26EB` says otherwise — `LOAD_bg` is dest
  `$9000` len `$0800`, `LOAD_spr` is dest `$8B00` len `$0400`, both written into the same
  six-byte VRAM request block at `$FFB1`-`$FFB6` that `COPY` streams its operands into. That
  block's field order is not assumed either: `COPY`'s handler at 0:`$2747` writes the six in
  exactly the order `door.zig` already decodes them. Neither error was cosmetic. `$8000` is
  outside the background's signed window, so a sprite load could never supply a background
  tile — and `metatiles_surface` reaches id `$EF` while `metatiles_queen` reaches `$FE`, both
  inside the `$8B00` blob. The fix is confirmed by what it moved: frames drawing from VRAM no
  door wrote fell from **103 to 72**, and all 10 SameBoy captures still match pixel-identically.
  The frames digest changed accordingly.

- [x] **Step 8: SNES-target conversion and asset region layout**

  **Read this before starting.** Three questions that look open are not, and one that
  looks settled is not.

  1. **Warp targets do not need resolving, and must not be.** A `WARP` operand is re-emitted
     as-is; the runtime dispatcher (Track B) splits its nibbles and forms `row * 16 + col`
     against the converted map, exactly as 0:`$28FB` and `$0835` do on the Game Boy. Step 7
     derived that rule rather than guessing it, which is what makes reimplementing it safe.
     Pre-resolving would bake in an answer the engine derives for itself.
  2. **The screen→tileset assignment is not a conversion input.** The 41/838/25 provenance
     split exists only to render Step 9's reference frames. The shipped game never consults
     it: door scripts load VRAM and scrolled screens keep whatever is loaded, which is why the
     ROM does not store the pairing either. The 838 measures how much a Step 9 *picture* is
     worth to a human, not a gap to close before converting.
  3. **Palettes are pinned.** The coverage report used to list these as unread and needed by
     this step. They are not: five `LDH` writes to a palette register exist in the whole ROM,
     three of them a VBlank copy at 0:`$0163` from shadows `$D07E`/`$D07F`/`$D080`, and every
     immediate the ROM stores into those shadows is BGP `$93` (and `$90` once), OBP0 `$93`,
     OBP1 `$43`. Derived a second way by running all 512 door scripts. Recorded as
     `screens.live_bgp`; fades write a ramp through the same shadows, which is Step 12's
     problem. **Index→colour was never a ROM question** — the DMG has no colours.
  4. **The BG/OBJ mode has not actually been chosen**, despite the first sub-task's wording.
     `01-requirements.md` pins the tile *format* ("GB 2bpp → SNES 2bpp is a reinterpretation")
     and nothing pins the mode. Decide it first and record it here, because the asset region
     layout below depends on it. Mode 1 with the play field on a 2bpp BG is the obvious
     reading of the requirement, but it is a decision, not a derivation.

     **Decided on the user's call: Mode 1, play field on BG3 (2bpp).** BG1/BG2 stay 4bpp and
     unused in Phase 0a — BG2 is where the HUD band goes, BG1 is left free so the later
     wider-view and parallax work does not need a mode change. OBJ is 4bpp, which the SNES
     does not make optional. The play field keeps GB tiles as a literal reinterpretation with
     no pixel work and no VRAM growth, which is what the requirement's word "reinterpretation"
     buys; the cost of the choice is that BG3 caps at four colours per tile, and the DMG
     source has four shades, so nothing is lost.

  Two facts derived from the ROM while starting this step, both of which move the layout:

  - **BG tile ids are signed-addressed from `$9000`, and the id space overlaps OBJ's.**
    `LOAD_bg` (`$B1`) is a fixed request: dest `$9000`, length `$0800` — 128 tiles, ids
    `$00`-`$7F`. `LOAD_spr` (`$B2`) is dest `$8B00`, length `$0400` — 64 tiles. Both come from
    the handler at 0:`$26EB`, which fills a six-byte VRAM-copy block at `$FFB1`-`$FFB6`
    (src lo/hi, dest lo/hi, len lo/hi) that the opcode itself does not carry. `$8B00` is
    *inside* the BG's signed window as well as the OBJ area, so ids `$B0`-`$FF` name the same
    bytes to both — which is exactly why `metatiles_surface` reaches `$EF` and
    `metatiles_queen` reaches `$FE`, and why `gfx_surfaceSPR` and `gfx_queenSPR` exist beside
    the `BG` sheets. On the SNES that sharing is impossible: BG3 is 2bpp and OBJ is always
    4bpp. A sheet a `spr` op targets is therefore converted **twice**, once per depth, and the
    layout carries both.
  - **`$FF` is not a blank sentinel.** `tileset.zig` documents it as "no tile" and
    `screens.zig` draws it as colour 0, but that is a *rendering* accommodation for VRAM no
    door wrote, not a fact about the data: `COPY_data gfx_commonItems, $8F00, $0100` writes
    ids `$F0`-`$FF` outright. So the id→char mapping is 1:1 with no special case, and a
    converted metatile carries `$FF` through like any other id.

  - [x] Choose and record the SNES BG/OBJ mode (see 4 above), then convert GB 2bpp tiles to
        the SNES format for it — Mode 1 / BG3 / 2bpp, recorded in `src/snes_target.zig` along
        with the VRAM map. `src/snes_chr.zig` converts to both depths. "GB 2bpp is SNES 2bpp"
        is checked rather than asserted: the module carries a SNES decoder written from the
        SNES side of the spec and runs all 2971 graphics tiles through both
  - [x] Convert the 16×16-screen map grid, per-screen scroll flags, and room transition indexes
        to the runtime map format — 256 cells of `{screen: u8, scroll: u8, transition: u16}`
        per bank; the screen index replaces the GB pointer, and index 0 is the shared blank so
        "in use" stays `screen != 0`. `unconvertBank` reproduces the ROM's own pointer table
  - [x] Convert metatile, collision, and solidity tables to runtime form — metatiles become
        four SNES tilemap words each with palette and priority baked from `target.zig`;
        collision and solidity are unchanged. `unconvertMetatiles` closes the loop on all ten
        tables and refuses a word carrying a bit the converter never sets
  - [x] Convert door script data to the runtime bytecode representation — same opcode
        encoding, so the runtime dispatcher keeps 0:`$239C`'s shape; only the operands that
        cannot mean anything on the SNES move. `COPY`/`LOAD` sources become asset ids,
        destinations become absolute VRAM word addresses, `WARP` banks rebase from `$9`-`$F`
        to 0-6, and the operand is re-emitted untouched per point 1 above
  - [x] Define the **asset region layout** as a standalone manifest — reserved size per class,
        plus a validator that checks converted sizes against it independently of the injector.
        `src/snes_layout.zig`: ten classes laid end to end after a bank-aligned engine reserve,
        `measure` + `fits` reporting per-class raw, packed, reserved and headroom. Two things
        the ROM forced that the sub-task did not anticipate: **blobs are bank-packed, not
        concatenated** — the DMA controller's A-bus bank register does not increment, so a
        transfer running off a bank wraps to its start, and any blob the engine will DMA must
        lie inside one bank; the padding that costs is charged to the class. And **regions are
        not bank-aligned** — the first draft aligned them and it cost five banks of nothing
        (`solidity` is 32 bytes, `tilemap` is 256), pushing the cart from 512 KiB to a megabyte
  - [x] Determine final ROM size and mapper choice from the complete converted asset set —
        **LoROM, 512 KiB cart.** 216 KiB packed into 344 KiB reserved, plus a 128 KiB engine
        reserve, ends the image at 472 KiB. Capacity does not force the mapper; the engine's
        addressing does. LoROM's 32 KiB windows sit at `$8000` in every bank, leaving
        `$0000`-`$7FFF` free for the WRAM mirror and registers without a second mapping mode.
        HiROM would buy larger contiguous blobs and nothing needs one — the largest blob in
        the set is `map9_screens` at 15104 bytes, under half a LoROM bank
  - [x] Verify: the validator reports total converted size fits the layout, with per-class
        headroom recorded. `zig build convert` prints the per-class table and exits non-zero
        on overflow; `zig build verify` reports the tightest class. Headroom is reported as a
        *fraction* of the reserve rather than spare bytes, because `solidity` has 4064 bytes
        free over 32 bytes of data while `map_screens` has 47 KiB free and is the class that
        would actually run out first — tightest is `map_screens` at **70%**. The overflow path
        is not hypothetical: the first reserve table failed it, `map_screens` over by 47872
        bytes, which is how the bank-alignment cost above was found. (The injector's overflow
        *error* is verified in Step 11, where the injector exists)

- [x] **Step 9: Render comparison across all screens**

  **Read this with Step 7's provenance note in mind.** The diff is valid at every
  provenance — both sides read the same screen→tileset pairing, so a quadrant, orientation,
  or palette error still fails the comparison. What provenance governs is whether a frame is
  a *picture of the real game*: only where it is `door` is the tileset stated by the ROM.
  Step 7's pulled-forward `WARP` survey is what moves screens into that class, so re-check
  the `by_provenance` split before treating any frame here as reference art rather than as a
  fixed input both sides agree on.

  - [x] Rasterize each screen from *converted* assets — `src/snes_render.zig` decodes the
        converted door bytecode, replays it into a 32K-word VRAM image, and draws from
        converted metatile words and converted 2bpp characters, honouring the tilemap word's
        character, palette, and flip fields. **At the full 256×256 screen, not the 160×144
        play window this sub-task names.** Step 7 rendered whole screens on purpose — a screen
        is four times the window, and diffing only what fits on the Game Boy at once would
        leave most of every room unchecked by the very test meant to prove the conversion
        reads it. The reference is what it is, so this follows it and checks four times as much
  - [x] Diff against Step 7's reference frames; fail on any mismatch — **904/904 screens match
        pixel for pixel.** Both sides read the same screen and the same tileset assignment;
        only the bytes in between differ. Three comparison accommodations are stated in the
        module rather than hidden: shade indexes stand in for CGRAM, character `$FF` draws as
        colour 0 because the reference does, and the palette is `live_bgp` unpacked
  - [x] Confirm the suite catches semantic errors by injecting faults — four, each a mistake a
        real conversion could make: transposed metatile quadrants, a transposed screen body, a
        rotated palette, swapped bitplanes. All four caught, the weakest disturbing 828 of 904
        screens. The bar is a majority of the game, not one pixel — a fault that moved one
        pixel would fail the comparison while proving almost nothing about it
  - [x] Wire the comparison into `zig build verify` — two lines, the clean diff and the fault
        sweep, both failing the gate. Gate runtime 49s
  - [x] Verify: comparison passes across all 904 screens (not ~300 — that estimate predates
        Step 5's map walk); all four injected faults are detected. 1387 unit tests pass

  **What the comparison found.** Three conversion bugs, none of which the Step 8 round-trip
  tests could have caught: a converter and its inverse agreeing proves nothing about a third
  party that reads the bytes.

  - **A `spr` operation has to be emitted twice, and `LOAD` stops being an opcode.** Step 8
    recorded that `$8800`-`$8FFF` is shared between background and object characters and that
    the *layout* carries both depths — but the bytecode named only one asset per operation.
    All 231 `spr` operations in the ROM (228 `LOAD_spr`, 3 `COPY_spr`) target `$8B00`-`$9000`,
    squarely inside the overlap, so this is what `spr` means rather than an edge case. Each
    now emits two copies. `LOAD` folded into `COPY` as a consequence: its operands were
    implied by the handler at 0:`$26EB`, and one implied destination cannot cover two
    transfers at two depths. `$B0`-`$BF` is unallocated in the converted encoding, the stream
    is 2103 operations and 6906 bytes, and `doors` needed its reserve doubled to 16 KiB.
  - **A source offset has to be scaled by the asset's depth.** Three copies carry a nonzero
    source delta, all into `bg_queenHead`, whose converted asset is twice the Game Boy size.
    They were reading half as far in. Found by inspection while fixing the first, then
    confirmed against the ROM before changing anything.
  - **Assets are as long as the loads read, not as long as their entries.** The renderer
    refused a copy running past its asset. `LOAD` takes its length from the handler, not from
    the entry it points at, so the three `$530`-byte `lavaCaves` sheets are read `$2D0` bytes
    past their own end into whatever follows them in the bank. `screens.zig` reproduces that
    over-read deliberately — the frames are meant to be what the Game Boy draws, not what a
    tidier engine would — and an asset cut off at its entry boundary could not. Exactly three
    assets over-read, and the count is asserted so it cannot quietly spread.

- [x] **Step 10: Inspection and A/B tooling**
  - [x] Graphics A/B: side-by-side original/adapted PNG with a diff channel — `zig build
        inspect`, built on `src/inspect.zig` (composition, no judgement) and
        `snes_render.Renderer`, the same code the gate uses. That sharing is the point: a tool
        with its own render path could show a human something the gate never checked, which is
        what an A/B view exists to prevent. Three component levels: `screen` (one room),
        `chars <door>` (the 256 BG3 characters a door script leaves loaded — the level a
        screen view cannot reach, since a screen only draws the characters its metatiles
        happen to name), and `sheet <asset>` (one named asset as a tile grid, at its own
        depth). The diff panel is not a subtraction: agreement goes flat neutral, disagreement
        goes a colour nothing else in the palette uses
  - [x] Contact-sheet output for bulk review across the whole game — one sheet per map bank,
        each screen at quarter size **in its grid position**, so the sheet looks like the map
        and a human can find the room they mean. Any differing screen is ringed
  - [x] Asset viewer: render any screen with any tileset, step through metatile, collision,
        and solidity data — `inspect -- screen <bank> <r> <c> [tiletable]`. The tileset
        override goes through `Renderer.pair`'s optional argument rather than a second code
        path. The dump lists every metatile the screen uses with its count, its four ids, its
        collision byte, and the tileset's solidity thresholds
  - [x] Wire coverage reporting into both tools — printed on every view and written beside the
        images, rather than left to `zig build coverage`. "Does this look right" is not
        separable from "how much of the ROM was reached at all": a picture that looks perfect
        over 73.8% of the ROM is a different claim from one that looks perfect over all of it
  - [x] Verify: a deliberately corrupted conversion is visually obvious in the diff channel —
        measured, not asserted. `fault <name>` is a prefix on every view, so the same pictures
        are available for a broken conversion. Over bank `$9`'s 151 screens the clean channel
        marks **zero** pixels, and each fault marks:

        | fault | screens | loudest screen | overall |
        |---|---|---|---|
        | `metatile_quadrants` | 148/151 | 25.7% | 12.1% |
        | `tilemap_transpose` | 151/151 | 67.1% | 37.5% |
        | `palette_permute` | 151/151 | 100% | 100% |
        | `bitplane_swap` | 151/151 | 70.6% | 24.8% |

  **Two things worth carrying forward.**

  - **"Visually obvious" is not one property.** Three of bank `$9`'s 151 screens never notice
    `metatile_quadrants`, because every metatile they use is symmetric under a transpose —
    `18 19 19 18` transposes to itself, and the ROM has many like it. The test asserts a 95%
    majority rather than unanimity, and the gate now reports the weakest fault's *pixel*
    fraction (15.46%) beside its screen count. A fault that a human staring at one screen
    would miss is still caught in bulk, and that distinction is now a number.
  - **Faulted output is filename-tagged.** Found the hard way: an untagged faulted run
    overwrites the clean image of the same screen, and afterwards nothing distinguishes them.
    For a tool whose entire output is pictures, that is the worst failure available to it

- [x] **Step 11: Pre-assembled engine image and builder injection**
  - [x] Write the minimal 65816 engine source: SNES init, BG mode setup, the 160×144 play
        window on a 256×224 screen, NMI/VBlank structure — `engine/main.asm`, 32 KiB
        assembled. The SNES masks columns and not rows, so the window is two mechanisms: the
        horizontal half is window 1 set to the play span and *inverted*, with `TMW` removing
        each layer outside it, and the vertical half is HDMA rewriting `TM` per scanline
        across a 40/144/40 band. VRAM, CGRAM and OAM are cleared under forced blank, because
        "undefined at power-on" differs between emulators and hardware and that is precisely
        how a bug becomes "works in Mesen, garbage on the FXPak"
  - [x] Assemble with `asar` at dev time; commit the assembled image and its symbol file as
        our own original code — `tools/build-engine.sh`, and `zig build engine`. The gate
        reassembles `main.asm` and compares **both** committed files when an assembler is
        present, and reports `not rechecked: no assembler` when one is not. The symbol file
        is compared too: renaming a label changes `engine.sym` without changing a byte of
        `engine.bin`, so an image-only check would call a stale symbol file current
  - [x] Implement builder injection: place converted assets into Step 8's reserved regions
        and patch pointers — `src/snes_inject.zig`, `zig build rom`. 97 blobs into a 512 KiB
        LoROM cart
  - [x] Raise a build error naming the offending class on region overflow — never silent
        truncation
  - [x] Emit the output ROM plus a symbol file — `build-out/m2snes.sfc` and `m2snes.sym`,
        wla format: the engine's own labels plus one per placed blob. Mesen2 loads it, and
        Step 15's address correspondence map is generated against it
  - [x] Verify: a deliberately oversized fixture triggers the overflow error and names the
        class — twice over, as a `Class` the caller switches on and in a sentence a human
        reads, both asserted. Confirmed end to end as well by shrinking `map_screens`'
        reserve and running `zig build rom`:

        ```
        error: map_screens needs 116224 bytes but only 98304 are reserved: 17920 over
          class map_screens: 98304 bytes reserved at $09B000
          raise its entry in `reserved` in src/snes_layout.zig, or shrink what goes in it
        ```

  - [x] Verify: the same input ROM and builder produce a byte-identical output hash across
        repeated runs — two full runs from the ROM, not two calls to `build` on one set,
        since the conversion is upstream and a hash map iterated in address order there would
        be just as much of a determinism bug. In the gate on every run
  - [ ] Verify: byte-identical across two machines — **not done, no second machine.** What
        was checked instead is a proxy: identical hashes across a different `HOME`, `TMPDIR`,
        `TZ`, `LC_ALL` and working directory. The structural argument is that nothing in the
        injector reads a clock, a path, an environment variable, or a hash map in iteration
        order, but that is an argument and not a measurement

  **Three things worth carrying forward.**

  - **The patch table is the whole interface, and it can refuse.** The engine never names a
    region address: it carries a table at `RegionTable` filled with `$FF`, opening with a
    magic word, a version, a class count and an entry size, and the injector checks all four
    before writing a byte. An assembler and a Zig manifest are two sources of truth, and the
    failure they invite is an image patched at plausible-looking offsets. `$FF` fill matters
    for the same reason: an unpatched image points at an address no 512 KiB cart has, so it
    faults rather than quietly reading bank 0.
  - **Region bases are not enough to find anything.** A converted `COPY` carries an *asset
    id* and a delta, not an address, so the engine has to turn an id into an address at run
    time. That needs a directory — one 8-byte entry per blob, grouped by class in placement
    order — which is a new class in the manifest rather than something the injector sizes as
    it packs. It is appended last, so every region Step 8 measured keeps its offset.
  - **The packing rule is now one function.** `layout.place` decides *where* each blob goes
    for the injector and *how much* a class costs for the validator. Two implementations of
    the same rule would be two things that can disagree, and the disagreement would present
    as a validator reporting green over an image with a character sheet in the wrong place.

- [x] **Step 12: Boot and screen rendering**
  - [x] Render map screens from converted data through the play window. The engine
        resolves a blob by class and id through the patch table and the directory, replays
        the converted door script the builder chose into VRAM, and expands the screen body
        into BG3's tilemap
  - [x] Implement the camera with `VIEW_W`/`VIEW_H` as build-time constants and no hardcoded
        dimensions — `src/snes_screen.zig` is the model and `CameraLimits` in the image is
        the assembler's copy, checked against it by a test
  - [x] Port camera clamping and the per-screen scroll-block check unchanged from the
        original's semantics. **The flag sense in `01-requirements.md` is inverted** — see
        below
  - [x] Verify: the ROM boots in Mesen2 and a converted screen renders in the play window —
        **stronger than "recognizably"**: `zig build romtest` bakes the reference render into
        a Mesen2 script and the gate compares the cart's framebuffer against it pixel for
        pixel across the whole 160x144 window, then drives the d-pad into a wall and into an
        opening and checks the engine's own camera variables
  - [x] Verify on FXPak hardware — deployed over USB via SNI and booted from the FXPak's
        SD card. The play window, the vertical cap and the camera behave identically to
        Mesen2; no hardware-only difference showed up

  **A set scroll bit BLOCKS.** `01-requirements.md` reads "a screen permits scrolling in a
  direction only where valid content exists", and built that way the camera left rooms
  through their walls and stopped against their openings. Two independent measurements
  against the ROM settle the opposite reading, and `src/map.zig` now carries both:

   * The requirements' own independently-derived counts — 274 in-use screens blocking both
     left and right, 328 blocking both up and down, 31 fully pinned. Read as "set blocks"
     the ROM yields exactly 274, 328 and 31; read as "set permits" it yields 198, 258, 42.
   * Of the 1664 directions in-use screens leave unblocked under the first reading, 1621
     lead to a screen that is itself in use; 43 do not.

  The `Scroll` fields are named `block_right`/`block_left`/… so the sense cannot be read the
  other way by accident, and a ROM-backed test pins all five numbers.

  **What is not ported: continuous scrolling across a screen boundary.** The original streams
  a column or row of tiles into the wrapping tilemap as the camera crosses. This step draws
  whole screens, so an unblocked edge is a step into the neighbour rather than a scroll
  through it. The clamp and the flag check are what the sub-tasks ask for and are ported;
  the streaming that makes a crossing smooth is not scoped anywhere in Phase 0a, and Step 13
  only asks that "the camera follows within its clamps". Worth deciding deliberately before
  Step 15's oracle, since a TAS compares camera position frame by frame.

  Seen on hardware, it is a leap of exactly one viewport. A screen is 256x256 and the camera
  centre is clamped to [80,176] horizontally, so at x=80 the view is the screen's left 160
  pixels; one more press crosses, lands the camera at 176 in the neighbour, and shows that
  screen's right 160 pixels. The two views abut exactly - no pixel is skipped and none
  repeats, and every part of every screen is still reachable - but 160 pixels of world go by
  in one 2-pixel step. Vertically the same, a 144-pixel leap between camera y 72 and 184.
  In the original, positions are `(screen, pixel)` byte pairs and a crossing is the carry out
  of the pixel byte, so the motion is continuous and the clamp applies only on a *blocked*
  edge; ours applies the clamp unconditionally and teleports across an open one.

  **Mesen2 headless works, and this cost three round trips to find.** The switch is
  `--testrunner script.lua --timeout=N`; the `--testRunner` / `--testRunnerTimeout` pair I
  had been using runs the ROM and silently never loads the script. `snes_game_dev` has been
  driving Mesen this way all along — its `.claude/skills/rom-test/SKILL.md` documents the
  invocation, that `emu.log` is swallowed and lua `io` sandboxed so the exit code is the
  only channel, and that assertions need a negative control. Two further traps cost a round
  trip each: `emu.getScreenBuffer()` is a **one-based** table, and the frame is 256x239, so
  the visible picture starts 7 rows down and not 8.

  **Five bugs, and what each one taught.** Every one was invisible to a byte-level check and
  obvious the moment a processor executed the image, which is the argument for the gate
  running the cart:

   1. The script dispatcher pushed the opcode eight bits wide and pulled it sixteen, so every
      operation that was neither a `COPY` nor a `TILETABLE` unbalanced the stack.
   2. **asar sizes an immediate by how many digits it is written with, not by the accumulator
      width.** `lda #9` after `rep #$30` assembles to two bytes and the processor reads three.
      Every immediate in the runtime now carries an explicit `.b`/`.w` and the file says why.
   3. The camera, and then the map index and cell, were never seeded — WRAM clears to zero,
      so the cart drew map 0 cell `$00`, the shared blank screen, which looks exactly like a
      cart that never got as far as drawing. Seeding is a table now, and a test checks every
      mutable field of the boot record is seeded exactly once.
   4. `DoCopy` held a transfer length in `!Count` across a call to `FindBlob` that uses
      `!Count` as its loop counter. Scratch is owned per routine now, not shared.
   5. **An HDMA line count is seven bits**: bit 7 selects repeat mode. `VIEW_H` is 144 = `$90`,
      so the play band assembled as "repeat for 16 lines" and there was no vertical mask at
      all. The test that summed the counts passed throughout — it checks the bit now.

- [x] **Step 12a: Continuous scrolling across a screen boundary**
  - [x] Clone M2RoS (MIT) as a read-only reference and read `handleCamera` (`bank_000.asm`
        `00:08FE`) and `prepMapUpdate` (`00:0698`), settling how the original crosses a
        boundary rather than inferring it from the `(screen, pixel)` coordinate format
  - [x] Model it in `snes_screen.zig` first: world position as `(screen, pixel)` with the
        carry, camera advance with **no clamp on an open edge**, and which metatile row or
        column falls due as the camera moves
  - [x] Stream one metatile row or column per frame into the wrapping 32x32 tilemap, chosen
        round-robin by `frameCounter & 3` as the original does, sourcing 16 metatiles that
        may straddle a screen boundary
  - [x] Keep the clamp on a *blocked* edge. In the original that clamp is the door trigger,
        not a wall; room transitions are Phase 0b, so stopping there is the stand-in until then
  - [x] Verify: `zig build verify` green, and the Mesen2 gate walks the camera across a
        boundary asserting it advances by its step every frame with no discontinuity, and
        that the pixels after the crossing are the reference render of the neighbour
  - [x] Verify on FXPak hardware that a crossing scrolls rather than leaps — deferred at
        James's call; the console was powered down and Step 12 already established that this
        cart behaves identically on hardware and in Mesen2

  **The clamps are not the limits of camera travel**, which is what Step 12 had wrong.
  `handleCamera` (M2RoS `bank_000.asm`, `00:08FE`) reads the scroll bit and, when it is
  *clear*, jumps straight past every edge check into ordinary movement: the pixel byte wraps
  and the screen nibble takes the carry (`adc $00 : and $0f`). Nothing decides that a
  crossing happened. The `SCRN/2` clamps run only on a **blocked** edge, and there they are
  the *door trigger* — standing on the clamp with Samus far enough over sets
  `doorScrollDirection` and calls `loadDoorIndex`. So the wall this step stops against is
  standing in for a door until Phase 0b.

  **The tilemap is a mod-256 window on the world**, not a picture of one screen: the tile at
  (tx,ty) always holds world pixel (tx*8, ty*8) with the screen number discarded, which
  `mapUpdate_getSrcAndDest` computes as `$9800 + (y & $F0)*4 + (x & $F0)/8`. `prepMapUpdate`
  writes one metatile row or column per frame, round-robin on `frameCounter & 3`, fetched
  `$30` past the camera — `$20` rightwards, an asymmetry that is the original's. Two pixels a
  frame gives a 16-pixel column four frames to arrive, so `!CAM_STEP * 4 <= 16` is a comptime
  assert rather than a comment.

  **This needed no 64x64 tilemap and no VRAM relayout**, contrary to what the fix was first
  quoted at. The Game Boy's tilemap and BG3's map are both 32x32 tiles of a 256-pixel square,
  and `snes_target.zig` had already said so — "edge streaming ports across unchanged rather
  than being redesigned" — which is worth reading before proposing an architecture.

  **What is deliberately not ported**: the original stages metatiles in `mapUpdateBuffer` for
  the VBlank handler to walk into VRAM. Here the staging buffer is already a whole tilemap in
  WRAM and one 2 KB DMA pushes all of it, which fits VBlank with room to spare. The contents
  are identical; only the journey differs.

  **The down clamp is `$100 - SCRN_Y/2 + $08`.** The extra 8 is the HUD band the Game Boy
  draws over the bottom of its window, so the camera is allowed that much further down. The
  queen's room subtracts a further `$20`; that boss-room case is not ported.

  **A frame of lag between the camera and the picture, measured, which Step 15 has to know
  about.** Comparing the play window on the exact frame the camera reached its target failed.
  Measured by searching for the horizontal shift that does align the two: while scrolling the
  displayed window matches the reference render at **2 pixels — exactly one `!CAM_STEP`**, so
  the picture trails the camera variable by one frame.

  This is not an engine defect. State that `MoveCamera` computes during frame N is displayed
  during frame N+1, which is inherent to waiting on VBlank; the mismatch is an *observer*
  artifact, because a Lua script sampling WRAM at `endFrame` reads a variable `MoveCamera`
  has already advanced past.

  Two further numbers, both measured on the cart: after the camera stops, the interior of the
  window agrees 3 frames later and the whole 160x144 agrees 6 frames later — so one frame
  describes the *scroll*, while the window as a whole takes several frames to settle and its
  periphery lags furthest. And a first attempt to sample the camera at Mesen's `nmi` event
  instead did not line up either. Step 15 therefore has to *establish* its sampling point
  against the engine's commit point deliberately, and prove it, rather than assume `endFrame`
  or `nmi` is the right one. The gate sidesteps all of this by letting the camera stop before
  it compares.

  **The lag is the original's, not ours.** `convertCameraToScroll` (`00:2366`) computes
  `scrollX = hCameraXPixel - SCRN_X/2` into a WRAM shadow during the frame, and
  `VBlankHandler` (`00:0154`) pushes that shadow to `rSCX`/`rSCY` — which is exactly our
  `WriteScroll` running in NMI. One frame between computing a camera and displaying it is
  what the Game Boy does, so there is nothing here to correct.

  Checking that did turn up a real divergence, since fixed: the original's main loop calls
  `prepMapUpdate` **then** `handleCamera`, so a frame services the row or column owed by the
  *previous* frame from the position that frame ended on. Ours serviced after the move,
  landing the same column a frame early and one camera step over. No picture shows the
  difference — both orderings have margin to spare — but a frame-exact trace would.

- [x] **Step 13: Samus movement and collision**

  **The physics constants were never converted in Step 8**, because they were never pinned:
  `offsets.zig` carried `physics_constants` in `pending`, filed as "scattered as immediates
  through bank 0 rather than gathered in a table". Most of them are. But the two that decide
  what a jump feels like are tables — `physics_fallArc` (00:1386), `physics_jumpArc`
  (00:184A) and `physics_spaceJumpArc` (00:1899), per-frame signed speeds indexed by
  `samus_fallArcCounter` / `samus_jumpArcCounter`. M2RoS labels the addresses; the bytes at
  those offsets in the retail ROM match its listing exactly, so they are *located* by the
  reference and *extracted* from James's cartridge, which is the rule this project runs on.
  Pinning them is therefore part of this step, not a prerequisite that was skipped.

  - [x] Pin the jump, fall and space-jump arcs in `offsets.zig` and decode them in
        `physics.zig` as signed per-frame speeds with a `$80` terminator that must land
        exactly last — so the round trip is evidence about the address, not a byte copy
  - [x] Convert the arcs into the cart as a `physics` blob class
  - [x] Implement input handling: held and rising-edge, as `hInputPressed` and
        `hInputRisingEdge`
  - [x] Implement Samus movement: walk, jump, fall, off the arcs above
  - [x] Implement terrain collision against the converted solidity data. Measured: a tile is
        solid to Samus when its **id is below** the tileset's first solidity threshold
        (`collision_samusBottom` does `cp [samusSolidityIndex]`), and the three thresholds per
        row are samus / enemy / beam in that order — corroborated by the `SOLIDITY` door-token
        handler writing them to those three variables in sequence
  - [x] Verify in Mesen2: the gate now *plays* the cart on the boot screen. It waits for her
        to fall onto the floor and compares the picture there, holds jump to the top of the
        arc and requires the converted arc to have lifted her higher than the linear part of
        the ascent managed alone, watches her land on the row she left, walks her into the
        edge the screen blocks, and walks her through the opening until the camera has
        carried into the neighbour — whose picture is compared against a render of that
        screen alone. Faults injected into `CollideHoriz`, the jump arc, the fall arc and
        `!SCROLL_Y_BIAS` come back as four different codes
  - [x] Verify on FXPak hardware, **as a preliminary pass on the camera alone** — James's
        call, 2026-08-27, deployed with `tools/fxpak.sh deploy` and run on the console.
        Movement and jumping read as expected, the camera scrolls smoothly, and different
        jump heights are distinguishable. There is no Samus sprite yet, so the only evidence
        of her is the camera; a second pass comparing the picture by eye waits until
        something draws her, which **no step in this plan currently does** — see the note
        below

  **The camera's lead space was found by eye, not by the gate.** Watching it on the console,
  James noticed that turning around moves the camera faster to open space in front of her.
  That is `CameraGuideX` doing exactly what the original does: the guide is
  `samus - camera + $60`, her centre in OAM space, and the servo drives it to `$40` walking
  right and `$70` walking left — the original's `$38` from whichever edge she is heading
  towards, so 56 pixels behind her and 104 ahead, mirrored by facing. A turnaround is
  therefore 48 pixels of camera travel, taken a pixel a frame on top of the walk.

  Nothing in the gate asserted it. The step bound (at most a walk plus the guide's pixel)
  would have passed with any target at all, so the two constants that decide how the camera
  *feels* were unverified. Now measured at `$70` and held there for the whole walk, asserted
  as exit 18, and a guide moved by four pixels comes back as 18. A person watching hardware
  found a hole in the automated gate, which is worth remembering about what the gate is for.

  **Nothing in Phase 0a draws Samus.** The remaining steps are the ledger and harnesses, the
  TAS oracle, the dispatch survey, audio, and the go/no-go. The requirements defer
  OAM composition only for the *A/B viewer* (`01-requirements.md`, "OAM/sprite composition is
  deferred with the assembled-sprite view"), and D1's acceptance criterion reads "Samus
  moves, jumps, and collides" rather than "is visible" — so Phase 0a can pass its own gate
  with an invisible Samus. James's call, 2026-08-27: it should not. **Step 13a** is inserted
  before the oracle to draw her, on the same footing Step 12a was inserted on.

  **The gate had to stop predicting the camera.** It baked a 160x144 window rendered at the
  camera's start and diffed the framebuffer against it, which worked while the d-pad drove
  the camera from a fixed place. It cannot work now: where the camera comes to rest is a
  consequence of the arcs and the converted collision data, and predicting it means
  reimplementing the pose machine on the Zig side. So the script bakes the whole 256x256
  screen and cuts the window out of it at whatever camera the engine reports. The camera
  position stops being something the test predicts and becomes something it reads.

  **Holding jump only until she is airborne proves nothing about the arc.** A gate that
  released as soon as she had risen 32 pixels passed with the entire jump arc zeroed out:
  `SetJumpArc` starts the counter at `!JUMP_BASE-$0F`, so six frames of the jump-start pose
  (2-3 px each) and fifteen of linear ascent (2 px each) reach ~48 pixels before the table is
  read at all. The gate now holds to the top and records the rise at the moment the counter
  crosses `!JUMP_BASE` — the arc has to beat that. This is the second time this step that a
  check which *looked* like it covered the jump did not; the first was the ascent that never
  ended, below.

  **Holding into the blocked edge does not reach the camera clamp on this screen.** Measured:
  she walks 3 pixels right and the terrain stops her, camera resting at pixel 133 against a
  clamp of 176. That is correct behaviour — Step 12a could assume the clamp was reachable
  only because the d-pad drove the camera and the terrain had no say. The clamp is now
  asserted every frame as a line the camera never crosses, and the *positive* assertion
  accepts either outcome: the terrain stops her, or the camera reaches the clamp.

  **`!Cell` is a frame behind the camera.** `LatchCell` runs at the top of `HandleCamera`,
  before the camera moves, so on the frame the pixel byte wraps past a boundary the camera is
  already in the neighbour and `!Cell` still says it is not. Anything asserting a per-screen
  invariant has to derive the cell from the camera's own screen nibbles, which is the same
  repacking `LatchCell` does.

  **The jump never ended, and the gate did not notice.** `PoseJumpStart` returned when
  `samus_jumpStartCounter` reached 6 instead of falling through to the pose commit, so a held
  jump rose forever — 74 pixels and still climbing when the probe gave up. The original's
  `jr nc, .endIf_A` falls through: six frames is the whole of the start, held button or not.
  Fixed; after it, 132 → apex 64 → land 132, poses $09 → $01 → $07 → $00.

  **The 1 px/frame stretch while walking is faithful.** `!Water` reads `$31` there — the
  left-foot water constant `collision_samusBottom` writes — and `collision_ruinsExt` has
  exactly eight tile ids with bit 0 set (21, 22, 29, 30, 66, 67, 68, 69). `WalkSpeed` gives
  one pixel a frame in water and otherwise `frameCounter & 1` plus one, alternating 2, 1.

  **Collision needed no new data path.** `samus_getTileIndex` (00:1FF5) reaches the tilemap
  through `getTilemapAddress` (00:22BC), which indexes `$9800` at 8-pixel granularity — so
  collision compares an **8x8 tile id**, not a metatile index. `charForTileId` is the
  identity, so the low bytes of `!TilemapBuf` already *are* those ids.

  That correction reaches back into Step 8: nine `offsets.zig` notes and `tileset.zig`'s
  doc comment said the solidity thresholds were metatile-index thresholds. The tileset order
  they corroborate is unchanged — row 5's 66 is still the only row low enough to be
  lavaCaves, whose *graphics* stop at 83 tiles rather than whose metatiles stop at 69 — but
  the argument is weaker than it was written: row 2 thresholds at `$F0`, past the end of any
  tileset, so a row is not obliged to fit inside the one it belongs to. The door scripts
  carry the order; the rows only agree with them.

- [x] **Step 13a: Drawing Samus**

  **Nothing in Phase 0a drew her, and that was not a deliberate deferral** — the requirements
  defer OAM composition only for the A/B viewer, and D1 asks that she "moves, jumps, and
  collides", which she does. Added at James's call on 2026-08-27, before the oracle, because the
  go/no-go at Step 18 is thin if nobody has seen the protagonist, because Step 14's room
  harness ("spawn Samus anywhere with an arbitrary loadout") is far less useful blind, and
  because `OAM_X_OFS`/`OAM_Y_OFS` are flagged in `01-requirements.md` (line 101) as needing
  to become 0 or fold into the sprite origin — a question only drawing something settles.

  **Most of the pieces are already in the cart.** `graphics_samus` converts to 4bpp as the
  `chr_obj` class with 64 KiB reserved; `snes_target.objDest` maps a Game Boy object VRAM
  destination to `obj_char_base` ($6000 words); `!OBSEL_VALUE` already selects that base and
  8x8/16x16 sprites; OAM is cleared under forced blank at boot and OBJ is already in
  `!TM_VALUE`. Three things are missing: the metasprite tables are extracted and round-trip
  but were never converted into the cart, nothing uploads Samus's tiles (the original loads
  them outside the door script), and nothing composes or DMAs OAM.

  **The pose-to-sprite mapping is code, not a table**, which is why `samus_pose_tables` never
  came out of `pending`. `drawSamus` (01:4BD9) builds a nibble-swapped byte from facing and
  the d-pad, dispatches on `samusPose` through `samus_drawJumpTable` — a table of *code*
  pointers — and each `drawSamus_*` routine carries its own two-to-eight-byte
  `db SPRITE_SAMUS_*` table indexed by that byte before falling into `drawSamus_common`
  (01:4DDF). Phase 0a reaches six of them: `_standing`, `_run`, `_crouch`, `_jumpStart`
  (01:4CCC), `_jump` (01:4CBD, shared with falling) and `_spinJump` (01:4CEE). The dispatch
  is logic and gets reimplemented; the little id tables are ROM bytes and get pinned and
  extracted like everything else.

  **The sprite's position is already computed.** `drawSamus_common` sets
  `hSpriteXPixel = samusX - cameraX + SCRN_X/2 + OAM_X_OFS + samusOriginX_toCenter`, which is
  exactly `!GUIDE_BIAS_X` — so `CameraGuideX` / `CameraGuideY` *are* her OAM position, and
  they are the routines Step 13 verified on hardware. That settles the bias question: the two
  Game Boy offsets stay in the guide arithmetic, where they are load-bearing and pinned, and
  are subtracted again at the OAM write, where SNES OAM has no equivalent — `oam_x =
  guide_x - OAM_X_OFS + win_left`, and the same shape vertically.

  **The camera guide is her OAM x, but not her OAM y.** This step's own text said both.
  `handleCamera` (M2RoS `bank_000.asm`:1531) biases vertically by `SCRN_Y/2 + OAM_Y_OFS +
  samusOriginY_toCenter - 2`; `drawSamus_common` uses the same expression *without* the `- 2`.
  The engine already carried the `- 2` in `!GUIDE_BIAS_Y`, so `SamusAnchor` adds it back and
  the divergence stays where the original put it. Horizontally the two really are the same
  number.

  **Four tables, not six.** `drawSamus_crouch` and `drawSamus_jumpStart` load immediates and
  index nothing. Each of the four that do close arithmetically on the next routine, and the
  next routine is identified from the ROM rather than from a label — `3E 0B` at 01:4D65 is
  `ld a, SPRITE_SAMUS_CROUCH_RIGHT`, which names `drawSamus_crouch` without trusting M2RoS.

  **The turnaround is `drawSamus_faceScreen`.** Pose `$83` is `$80 | pose_run` and `drawSamus`
  tests bit 7 before anything else, so the two frames of a turn draw the front-facing sprite.
  It reads like a guard clause and it is the animation. `EnterCrouch` is still a stub, so the
  crouch arm of the dispatch is written and unreachable; that is noted where it sits.

  **No clipping code, and that is a consequence rather than an omission.** A part's x becomes
  `(anchor + part) & $FF - OAM_X_OFS + !WIN_LEFT`, a net `+40`, so Game Boy columns 0-159 land
  on 48-207 — exactly the columns the play window leaves on the main screen. A part the Game
  Boy would have clipped lands outside that span and the window removes it at the same pixel.
  The vertical case is the same argument against the HDMA band. Move the window and this has
  to be re-derived.

  **OAM lags the shadow by one frame, structurally.** `MainLoop` opens with `wai`, so the
  drawing for frame N runs after frame N's NMI has already uploaded what frame N-1 composed.
  The gate holds the previous frame's anchor and checks OAM against that, rather than only
  looking while she stands still — a check that ran only at rest would not notice a sprite
  that lagged by two.

  **A lua error in a Mesen callback is indistinguishable from a hung cart.** `spriteMask` was
  written above the locals it reads, so it captured a global `nil`; the arithmetic error
  disabled the callback and the run went to the 90-second timeout. `emu.log` is swallowed in
  testrunner mode, so finding it needed a temporary `frames > 4000` tripwire reporting the
  phase in the exit code.

  **The behind-background bit is carried, not honoured.** SNES OBJ priority 0 is still above
  BG3 in mode 1, because nothing gives the play field's tiles the priority bit a sprite would
  have to go under. Eleven parts of the samus set set the Game Boy's bit; none of them belongs
  to a sprite the six reachable poses can name, and `sprites.reachableIds` plus a test says so
  rather than the comment asserting it.

  - [x] Pin the six pose routines' sprite-id tables in `offsets.zig`, out of `pending`, each
        with its bank-1 address and how it was found; keep `samus_pose_tables`' remaining
        poses in `pending` with the reason narrowed to the ones Phase 0a does not reach
        — four tables, not six: `_crouch` and `_jumpStart` load immediates and have none.
        Each closes exactly on the next routine's first instruction, read from the ROM
        rather than from a label
  - [x] Convert the samus metasprite set (pointers + data) into the cart as a `metasprites`
        blob class, the shape `physics` took in Step 13, with a round-trip test — six blobs:
        the two samus ones and the four pose tables. The records ship in the Game Boy's own
        shape; the pointer table is the one thing converted, from absolute bank-1 addresses
        to offsets, and every one of the 69 is checked against a linear walk of the data so
        a pointer landing inside a part is refused rather than drawn
  - [x] Upload Samus's converted `chr_obj` tiles to `obj_char_base` at boot, and put her
        palette in CGRAM — the OBJ palettes are a separate half of CGRAM from BG3's. Both
        needed the boot record, so it went to version 2: it now carries the `chr_obj` asset
        id of `gfx_samusPowerSuit` and eight object palette words, OBP0 ($93) and OBP1 ($43)
  - [x] Engine: an OAM shadow in WRAM, a `DrawSamus` that walks a metasprite's `$FF`-terminated
        four-byte parts into it, and a DMA to OAM in NMI beside the tilemap's — first in NMI,
        because OAM is the one transfer that has to be inside vblank rather than merely prefer
        to be. This is where the Game Boy OAM record becomes a SNES one: the two origin biases
        come off, the window offsets go on, the attribute byte's flip and palette bits are
        translated, and the high table's x-sign and size bits are driven
  - [x] Reimplement the six `drawSamus_*` routines and `drawSamus_common`'s position
        arithmetic, reusing `CameraGuideX`/`CameraGuideY` rather than recomputing them —
        seven, in the end: the turnaround pose has bit 7 set and `drawSamus` sends that
        straight to `drawSamus_faceScreen`, which is not a special case but *is* the
        turnaround animation
  - [x] Teach the Mesen2 gate about a sprite. The baked background render cannot match where
        she covers it, so the comparison has to mask her bounding box — computed from the OAM
        position the gate already reads, not from a hardcoded box. Assert the OAM shadow is
        non-empty, that her OAM position is the guide minus the biases plus the window
        offsets, and that the sprite id changes with pose and with facing — done as seven new
        codes, 121-127, with the mask taken per 8x8 part rather than as one box and bounded
        above so a mask that grew could not quietly stop the comparison comparing
  - [x] Verify: `zig build verify` green, with an injected fault in the metasprite walk, in
        the bias arithmetic, and in the pose dispatch each caught by a distinct code —
        advancing the record cursor by five gives **123**, dropping the `- !OAM_X_OFS` gives
        **124**, and pointing the jumping pose at the standing table gives **125**
  - [x] Verify on FXPak: **the by-eye pass Step 13 deferred.** Samus is visible, animates
        through the poses, faces the way she walks, and sits where the camera says she is —
        confirmed on the console by James, 2026-08-27, all four. Including the turnaround
        drawing her facing the camera, which is the one that looks like a bug and is not.

  **The fault sweep leaves a faulted ROM in `build-out/`.** It was deployed to the console
  that way — `zig build verify` builds its image in memory, so a green gate says nothing about
  the file on disk, and nothing between the sweep and the deploy rewrote it. Deploying from
  `build-out/` needs a `zig build rom` first, or a hash check against the digest the gate
  prints. The clean cart is `4cfbece0`.

- [x] **Step 14: Logic ledger and test harnesses**

  **Swapped ahead of the oracle on 2026-08-27, at James's call.** It was Step 15, and the
  oracle was Step 14, which put a step's dependency after it. A frame-for-frame comparator
  needs both machines standing on the same pixel of the same screen at frame 0, and neither
  machine can be told where to start: `chooseBoot` (`src/snes_screen.zig`) picks the boot
  cell as "the first cell, in bank and then grid order, whose tileset a door script *stated*"
  — a deterministic fixture, not the game's start — and `engine/main.asm` drops Samus at the
  camera's centre to fall, because "the original is handed a position by the door transition
  that brought her in; Phase 0a has no transition." The room harness below is the mechanism
  that fixes both halves, so it has to land first. The ledger came with it because it blocks
  nothing and splitting the step three ways would renumber more than it clarified.

  **A static trace cannot find this game's routines, and the number is 22%.** The step's
  first sub-task named `mgbdis`; it now names our own `gb/disasm.zig` plus emulator
  coverage, and `01-requirements.md` was amended to match. The argument that decided it is
  not the Python dependency, it is a measurement: seeded from the reset and interrupt
  vectors, a flow trace of bank 0 reaches 22% of it and stops. Metroid II dispatches through
  `JP HL` over tables of code pointers, and where a `JP HL` goes is not in the bytes.
  `mgbdis` has the same blind spot and linear-sweeps past it, decoding the tables as
  instructions. Statically, the whole ROM yields 40 routines and 1,978 instructions — a
  tenth of the game. With the run: 262 and 11,818.

  **The pose machine is a `RST $28` with its jump table inline after the call site.**
  `samus_handlePose` at 00:$0D21 ends `LD A,($D020) / RST $28` and is *followed* by 27
  little-endian addresses. The thunk at $0028 is `ADD A,A / POP HL / LD E,A / LD D,$00 /
  ADD HL,DE / LD E,(HL) / INC HL / LD D,(HL) / PUSH DE / POP HL / JP HL` — it pops its own
  return address to find the table. That is why the ledger watches for the `$E9` opcode and
  marks whatever executes next as an entry: it is the only mechanical way to learn where
  those 27 entries point.

  **Seeding every executed address as an entry gives one routine per instruction.** The
  first version did, and reported 2,085 dispatch targets against 40 static ones. The tell
  was in the totals it printed beside them — 90,588 instructions summed over routines
  against 10,989 distinct. The fix is to sweep uncovered executed bytes in ascending order
  and walk each new entry's body immediately, so the rest of that body is covered before the
  sweep reaches it. 2,085 became 41.

  **Three bugs in the observation, each of which made the ledger quietly smaller.**
  A frame loop that waits for each frame in turn treats the LCD being off as the machine
  having died — Metroid II turns it off during a screen transition, so every run stopped at
  2,664 frames no matter how long a schedule it was given. Sampling game state between
  chunks restarted the input schedule at frame 0 each chunk, which turned a 24-frame held
  input into a stutter and walked the machine back to the title screen. And the door sweep
  returned one door in sixty-four with IME clear, because a door script's VRAM copy loops
  wait on vblank; `Machine.call` defaults interrupts off, which is right for a unit test and
  wrong for this. 63 of 64 after, 497 of 512 on the full sweep.

  **The explorer morphs her into a ball in the first few seconds and never gets out.**
  `exploreButtons` presses down a quarter of the time and deliberately never presses up.
  Down twice from standing is how Metroid II morphs, a ball with no spring ball cannot jump,
  and up is the only way out — so ninety seconds of random input reached the standing,
  running and crouching handlers and *never once* reached jumping, spin-jumping, falling or
  the jump start. Not luck: a trap with no exit in the schedule's alphabet. The directed
  movement segment presses up first and never presses down.

  **The sentinel return address is inside the RST 0 vector, and resuming from it soft-resets
  the game.** `probe.runDoors` never noticed because it reads state out of a machine and
  throws it away. Anything that runs *frames* after a call does notice: $0001 is the second
  byte of the `JP $01FB` at $0000, so resuming there executes `EI` and then reads a garbage
  operand, and five frames later WRAM is cleared. The room harness spawned Samus perfectly
  and found her gone. `Machine.call` now puts PC back when the routine returns.

  **The room harness is not a save record, and that is the better answer for position and
  the worse one for loadout.** The `WARP` handler at 00:$28FB wants two bytes at `HL` and a
  direction in $D00E; handing it our own bytes reaches rooms no door names and skips the
  file-select path entirely. It also has to be told the transition is over — $D00E is the
  game's "transitioning" flag, and `samus_handlePose` opens with `RET NZ` on it. What the
  save record would have bought is the loadout, and that is deferred with evidence: ninety
  seconds of play writes exactly one byte of cartridge RAM, because the game only writes a
  record at a save station.

  **$D058 and $D04E both look like the map bank and neither is.** $D058 is the handler's
  argument slot; $D04E is a shadow of whatever bank is currently mapped, and reads 4 a
  hundred frames later because the main loop has been in and out of the sound driver. The
  one that survives is $D811.

  **A tile is solid when its id is BELOW the threshold**, which is the opposite of how
  `CP (HL) / RET C` reads. `engine/main.asm:2088` already had it right; the first draft of
  `src/routines.zig` had it backwards and the test caught it, which is a fair advertisement
  for the per-routine layer.

  **Three of the thirty named routines are labels inside other routines, not entries.**
  `drawSamus_run` falls through into `drawSamus_common` — `offsets.zig` pins a pose table's
  far end on exactly that — so 01:$4DDF is a label, and demanding it be an entry would mean
  inventing a boundary the bytes do not have. The ledger reports `entry`, `inside` or
  `absent`, and the gate fails only on `absent`.

  **Partly pulled forward, and better tooled than this step assumed.** Step 7 took the narrow
  slice that pins the `WARP` operand, and left two things behind that this step should start
  from rather than rebuild. `zig build disasm` is an SM83 disassembler that follows control
  flow from named entry points, so routine boundaries can be recovered from the user's own ROM
  without `mgbdis` — worth weighing against the first sub-task below, which still assumes it.
  And `zig build probe -- doors` shows that a booted machine can be made to execute any
  subroutine on demand by writing its argument into RAM and calling it; the "room harness"
  this step was going to need for directed input may be much smaller than it looks. Already
  recorded from the ROM: the interpreter at 0:`$239C`, its dispatch chain, the `WARP` handler
  at `$28FB`, the cell index at `$0835`, and the transition table's bit-11 flag at `$0C66`.

  - [x] Generate the logic inventory ledger from **our own disassembler plus emulator
        coverage**, recording source location, conversion status, test status, and target
        phase. `01-requirements.md` was amended on 2026-08-28 to name this instead of
        `mgbdis`: a static-only tool cannot follow this game's `JP HL` dispatch, which is why
        a vector-seeded trace of bank 0 reaches 22% of it, and dropping `mgbdis` takes a
        Python dependency out of the gate. Boundaries come from three mechanical seeds — the
        static flow trace from the reset and interrupt vectors, every `CALL`/`JP`/`JR` target
        named anywhere in the ROM, and the PCs the emulator is observed to execute
  - [x] Attach **our own** routine names as we understand each one, so the ledger's semantic
        layer is original work rather than transcribed M2RoS labels
  - [x] Track unconverted and untested as distinct states; emit the "N of ~20,000" figure
  - [x] Build the per-routine unit-test harness: set up state, call a routine, assert registers
        and memory — `src/gb/harness.zig`, generalised from `probe.runDoors`'s proven
        push-a-sentinel-and-jump, plus `src/routines.zig`, which is what it is for
  - [ ] Build the room test harness on the **GB** side: spawn Samus at arbitrary bank/screen/
        position with arbitrary equipment, beam, energy, missiles, and Metroid count, by
        synthesizing a save record — `src/room.zig`. **Position: done and verified.**
        **Loadout: mechanism only, addresses deferred to Step 15, with evidence.** Not a
        save record, and not for want of trying: the shorter lever is the `WARP` handler at
        0:$28FB, whose entire interface is two operand bytes at `HL` and a direction in
        $D00E, so handing it our own bytes reaches rooms no door names and skips the whole
        file-select path. The loadout is where the save record would have earned its place,
        and `watchSave` is the mechanical way in — watch the game write a record and every
        field's offset falls out with the routine that copies it. Ninety seconds of booting
        and directed play writes exactly one byte of cartridge RAM, the file counter at
        $A0C0, because the game only writes a record at a save station and the exploration
        schedule never reaches one. So `Spawn.writes` ships as an address/value list and the
        named fields wait for Step 15's TAS, which does save. A test asserts the one byte,
        so the deferral has evidence rather than a shrug
  - [x] Give the **SNES** side the matching control: extend the boot record to version 3 with
        Samus's start position as screen+pixel pairs on both axes, and a starting pose, so the
        injector can place her rather than the engine dropping her at the camera's centre.
        Default the new fields to today's behaviour — centre of the boot cell, `!POSE_FALL` —
        so an unseeded record still boots exactly as it does now, and extend
        `snes_inject.zig`'s "every mutable field of the boot record is actually seeded" test
        to cover them — done, but *not* by that test, and the
        difference matters. `BootSeed` is the table for record bytes that become direct-page
        variables; the three new fields are read straight out of the record by `InitState`
        with an absolute load and are deliberately absent from it. So the new test scans the
        assembled engine image for an `$AD` absolute load of each field's address. Without
        something like it, a start position could be written into every cart and never read,
        and it would look exactly like working — because the default is where she was going
        anyway
  - [x] Verify: the ledger's routine count is within a stated margin of the ~20,000-line
        figure; the GB room harness spawns correctly in several distinct areas across banks;
        and the two harnesses agree — the same bank/screen/position requested of each puts
        Samus at the same world coordinates, which is the precondition the oracle needs —
        **262 routines and 11,818 instructions, 59% of the stated ~20,000**, with the
        residual named against the ROM rather than as the complement of that percentage: two
        different denominators, and subtracting one from the other would produce a number
        that means nothing. 75,067 of the 98,304 bytes in banks 0-5 are claimed by no
        routine, most of it data a body should decline to decode; the part that is not is
        31,772 bytes of banks 0, 2 and 4, which is logic no run has reached and the number
        Step 15's TAS should move. Room harness: five cases across banks $9, $B, $E and $F,
        each read back out of the machine rather than echoed. Agreement: five more, plus the
        actual boot cell, comparing the Game Boy's `(screen<<8)|pixel` read out of $FFC9/
        $FFC8 and $FFCB/$FFCA after the warp ran against `snes_screen.samusAt`'s arithmetic
        — two routes to the same 16-bit number, so a row/column transposition on either side
        would fail it

- [x] **Step 15: TAS oracle and SNES-side trace extraction**

  > **Closed 2026-09-01, and the box was not ticked for tidiness.** This step stayed unchecked
  > for a month on one stated condition — its own verify sub-task, `zig build verify` green
  > *including* the oracle rung — and that condition is now met: `ok oracle 320 frames of the
  > original, frame for frame`, inside a gate green end to end at 101/101 steps and 4245/4245
  > tests. Nothing was relaxed to get there and no rung was retired.
  >
  > **The banner it replaces was wrong twice, which is worth leaving on the record.** It first
  > said the red rung was the synthetic spawn's camera, and that closing it meant apparatus
  > serving only a spawn Step 15b removes; the residue audit falsified that — the movie needs
  > `BootCamX`/`BootCamY` more than the segment did. It then said the rung was red on **Samus's
  > position at frame 124 of 320** and called that "a port defect, not a fixture artefact ...
  > the first honest one this comparator has reported". That was wrong too, and in the same
  > direction: frame 124 was the *reference* being sampled at the LCD frame boundary rather than
  > on the game's own tick. Three readings of one red rung, two of them confident and wrong,
  > and none of them the port.

  **Corrected 2026-08-31, and the correction is the point of the step.** This step used to open
  by arguing that the TAS is captured but is not the pass condition: a tool-assisted run expects
  the whole game, and this cart has no ship, save, pause, shooting, ammo, enemies, music, items,
  tech movement, cutscenes, or room transitions. That half is still true. The conclusion drawn
  from it — that the pass condition should therefore be a segment *we* author — was wrong, and
  it drifted away from F10, which names the TAS as the primary whole-game gate and asks for its
  **reachable-frame count as a progress metric**. A hedged criterion ("for as far as Phase 0a's
  logic reaches") is a frame count, not a licence to build a different oracle.

  **What that cost, measured.** Three defects in this step were all in the reference rather than
  the port, and each was found only by the port disagreeing with it: the game was *paused* for
  every comparison; a `WARP` was mistaken for a room load; and Samus's position was read from
  the wrong pair of addresses for the whole of Steps 14 and 15. None of them are emulation
  defects — our GB core is graded against SameBoy pixel-for-pixel and was green throughout — so
  none would have been caught by swapping in someone else's emulator. All three are mistakes
  about *the original's own conventions*, and all three were unfalsifiable because the reference
  had no ground truth of its own.

  **The asymmetry that allowed it.** `correspond.zig` refuses to write down a single SNES
  address: every pair names an `engine.sym` label and a missing label is a build error,
  specifically so the two sides cannot drift. The Game Boy side is hand-typed hex. Half the map
  is checked by construction and the other half is a guess with a comment on it, and the bug
  lived in the unchecked half.

  **The direction, agreed with James on 2026-08-31.** The TAS is the oracle, in two moves.
  **B — the TAS validates the reference machinery** (this step): 40 240 frames of known-good
  real play is exactly the falsification the address map never had, and it is available now
  without the port implementing anything. **C — the port plays the TAS from the start**
  (Step 15b, and onward through Phase 0b): the reachable-frame count becomes the gate, growing
  as the port grows. The end state is the whole movie running start to finish. It will not visit
  every room, and that is accepted: with every room and enemy built and a full run passing, a
  game-breaking defect in a room the movie skips is a risk worth carrying rather than a hole to
  close first.

  **A movie's frame zero is not ours, and the difference is the whole run.** Both published
  runs press Start inside their first ten frames and then hold nothing for four seconds. The
  first replay put that press during the game's own initialisation, lost it, and sat on the
  title screen for forty-five minutes pressing directions at it. `tas.findInputOrigin`
  measures the offset instead of guessing: cycles+bootROM 92, cycles 8, lcd+bootROM 81, lcd 1.
  So VBA ran no boot ROM and did not count frames while the LCD was off. A test re-measures it.

  **How far a replay stays faithful, measured: 40 240 frames of the any% run and 20 590 of the
  100%** — eleven and six minutes — and then Samus's energy reaches zero and both end back at
  the title. Both frame sources diverge in the same place, so the cause is core accuracy rather
  than framing.

  **Neither published run reaches a save station, so the loadout came the other way.** Each
  writes exactly one byte of cartridge RAM, the file counter, which is the same answer Step 14
  got from ninety seconds of random input. `room.LoadLog` watched the *reads* instead, found
  the file-select comparison against `LD HL,$2083`, and the ROM holds exactly two references to
  that magic — the other is inside the routine that writes a record, at 01:$7ADF. `src/save.zig`
  re-derives all 38 fields by decoding it, which is the game's own definition of the loadout.

  **The oracle found two bugs before it could run at all.** `harness.boot` leaves the game
  *paused* — Start is Metroid II's pause button as well as its start button, and thirty seconds
  of tapping it lands on the wrong parity — so every test in this repository had been booting
  into a paused game, and the first reference was 320 identical frames. And `room.spawn` wrote
  only one of the two position quads the `WARP` handler fills, so she could walk but not fall,
  and a jump ran its whole pose sequence without moving her a pixel. Step 14's five-spawn
  agreement test passed throughout, because every one of its reads goes through the quad that
  was written.

  ***Corrected 2026-08-31: they are not two copies, and calling them copies is what cost the
  step.*** `room.zig` read the `WARP` handler — `LDH ($C9),A` then `LDH ($C1),A` for the row,
  `LDH ($CB),A` then `LDH ($C3),A` for the column — and concluded that $FFC0-$FFC3 and
  $FFC8-$FFCB hold the same thing twice. They agree at the instant of a transition and diverge
  on the next frame of play, because only one of them is Samus. **$FFC0/$FFC1 is her Y and
  $FFC2/$FFC3 her X**: `samus_walkRight` (00:$1C2C) reads $FFC2, adds the walk speed, stores it
  back and carries into $FFC3, and every collision routine samples from $FFC0 and $FFC2.
  $FFC8-$FFCB is a scroll origin — 00:$32CF and 00:$34AE subtract it from Samus's sampled
  position to reach entity space. That inference was drawn from *initialisation* code and never
  checked against steady state; one frame of walking falsifies it, and nobody ran that frame.

  **The sampling point is not assumed.** Step 12a measured a one-frame lag between the camera
  variable and the picture, and found that neither Mesen's `endFrame` nor its `nmi` lines up on
  its own. Everything the oracle reads is written between `MainLoop`'s `wai` and its branch, so
  the script hooks an execution callback on that label; `endFrame` would sample wherever the
  loop happened to be when the PPU finished.

  - [x] Obtain a published Metroid II TAS input stream and drive Step 6's emulator with it,
        dumping a per-frame GB state trace (Samus position, camera, enemy slots, relevant RAM).
        Depends on nothing from the port; can run before the rest of this step —
        `tools/get-tas.sh` fetches both published Cardboard runs (949M any%, 979M 100%) into
        untracked `vendor/tas/`; `src/tas.zig` parses VBM, checks the movie's title, header
        checksum and global checksum against the ROM's own header, and replays it. **Enemy
        slots are not in the record and are not guessed at**: no address in the repository pins
        one, because nothing in Phase 0a spawns an enemy. An FNV-1a digest of all of WRAM
        stands in — strictly more sensitive, and unable to say *what* diverged, which is what
        pinning the slots would buy. Pinned in Phase 0b, where there is something to compare
  - [x] **Saves cannot be tested by watching a TAS, and the test that would work is Phase 0b's.**
        Moved to the Phase 0b stub on 2026-09-01 so Step 15 can close: the sub-task's own text
        already deferred it — Phase 0a's cart has no save station, no enemies and no damage — and
        an indefinitely-deferred box inside a step is how a step stops being closable. The design
        James named is preserved verbatim in the stub, along with the fact that `src/save.zig`
        already decodes the record it would assert against

  - [x] **Carried over from Step 14:** pin the loadout addresses — equipment, beam, energy,
        missiles, Metroid count — by pointing `room.watchSave` at the TAS run. **The premise was
        wrong and the answer is better.** A TAS does not save: both runs write one byte of
        cartridge RAM before the replay diverges. So the record came from the routine that
        *writes* it, found by watching the reads instead — `src/save.zig` re-derives all 38
        fields and the ROM independently confirms `metroidCountReal` $D089 and
        `metroidCountDisplayed` $D09A. Profiling every field over a replay named three more:
        $D051 is $99 at file start and $00 on the frame she dies (energy), $D053 is $30 and
        falls (missiles), $D081 is $30 and never moves (capacity). `room.Spawn.loadout` sets
        them by name, reading the addresses out of `save.fields` so the two cannot drift.
        **Equipment and beam are left unnamed with the reason stated**: every record field that
        is zero at file start is still zero, or a two-state flag, at the frame the replay
        diverges, because both runs desync before they collect anything that sets one
  - [x] Write the **address correspondence map**: a table pairing each traced GB address
        (`metroidCountReal` `$D089`, camera, Samus position, …) with its address in our WRAM
        layout, generated against Step 11's symbol file so it cannot silently drift —
        `src/correspond.zig`. No SNES address is written down: each pair names a label and a
        missing label is an error. `engine/main.asm` now exports the direct-page variables as
        `Var*` labels, because a define leaves no trace in a symbol file. Three transforms,
        because almost nothing is address-for-address: a position is two GB bytes and one word
        of ours, a map is a bank there and an index here, a screen is a row and a column there
        and a cell byte here
  - [x] Implement SNES-side trace extraction as a Mesen2 Lua script following the pattern in
        `snes_game_dev`'s `test/engine.lua`, emitting the same per-frame record shape.
        Establish and assert its sampling point against the engine's commit point rather than
        assuming `endFrame` or `nmi`, per Step 12a's measured one-frame lag — done twice, and
        the second time is the one that matters. The oracle's own script *bakes* the reference
        and returns one byte, because Mesen2 swallows `emu.log` in testrunner mode and leaves
        lua's `io` nil (probed, not assumed). One byte says *when* two machines disagreed and
        can never say *why*. So `src/snes_trace.zig` opens the channel the sandbox does have:
        it re-stamps a **copy** of the cart's header with a battery and 32 KiB of save RAM,
        the script writes one 39-byte record per frame into it, and Mesen writes the file out
        on power-off. The shipped cart gains nothing — the stamp is on the copy, and the
        checksum is recomputed by the same convention `snes_inject.patchHeader` uses. Sampled
        at the same `MainLoop` callback as the oracle, so a row here is the instant the
        comparator compares. Every field names an `engine.sym` label; no address is written
        down. `zig build trace` prints the port's own state beside the original's, and it
        found the defect below in one run
  - [x] Implement the comparator, reporting the **first divergent frame** and what diverged —
        one code per four frames, two ranges, which is as fine as 320 frames and two quantities
        fit into one byte. **Two initial conditions are excluded by argument rather than
        compared**: both machines start standing and at rest, because the original resolves
        `fall` to standing on the next frame where there is ground and ours spends a frame
        falling; and the camera is compared against its own frame zero, because the original's
        is placed by the door transition it arrived through — sixteen pixels apart on this
        screen, which the comparator reported at frame 0 the first time it ran
  - [x] Define Phase 0a's concrete oracle target: a **hand-authored input segment** on one
        converted screen — walk, jump, land, scroll — comparing Samus position and camera
        only. One screen because room transitions do not exist yet; position and camera only
        because nothing else does either. Both machines are placed at frame 0 through Step
        14's paired harnesses, which is why that step now comes first — 320 frames, and the
        screen and starting pixel are **chosen by measuring** rather than taken from
        `chooseBoot`: the cart's own boot cell is a flat corridor with a low ceiling, and a
        reference that barely moves is one a broken port passes. Candidates are scored by
        ground covered with vertical movement weighted four to one
  - [x] **Added 2026-08-30: the comparison has a precondition, and it was not being checked.**
        Collision on the original is a lookup into its own background tilemap — `samus_getTileIndex`
        through `getTilemapAddress`, 00:1FF5 and 00:22BC — and ours is a lookup into `!TilemapBuf`.
        If those hold different tiles the two machines are walking through different terrain, and
        every frame after the first step grades the port against a world it was never shown.
        `oracle.compareWorlds` now expands the boot cell's 256 metatile indexes through each
        metatile table and asks which one explains each machine's map; `Report.matched()` requires
        the same room, and `verify` reports the mismatch *instead of* a verdict rather than beside
        it, because "Samus's position diverged" about a setup difference sends the next person to
        the wrong file.

        **And a second precondition, from James watching the cart run (2026-08-30):** Samus spawns
        *below* the floor tiles, and one jump lifts her out, after which she lands and moves
        normally — which is independent evidence that Step 13's physics is not what is broken.
        `snes_trace.footing` reproduces `CollideBottom`'s own probe against the cart's own tilemap
        and its own solidity threshold and says so in numbers: **16 pixels inside the floor**, feet
        probing tile row 22 of column 12 where the first solid row is 20; standing on it needs her
        pixel row to be $84, not $94. Same room and right height are different questions, and the
        boot record can get the second wrong even once the first is fixed. The hitbox offsets come
        out of `engine.sym` as `Const*` symbols rather than being copied into Zig.

        *(Those figures are from the start `chooseStart` picked before the room fix below. With
        the room actually loaded the chosen start moves and the measurement reads column 4, first
        solid row 20, pixel row $84 rather than $96 — the same sixteen pixels, in the right room.)*
  - [x] Verify: a deliberately perturbed physics constant makes the comparator name the right
        frame. The fault sweep passes: 4/4 injected one-pixel faults are named at the right
        frame, so the comparator is known to be comparing rather than merely green
  - [x] **Added 2026-08-31: the segment did not match, and the reason was the reference.**
        Recorded because the wrong answer was written down twice before the right one, and both
        wrong answers were about the port.

        The symptom: the two machines agreed exactly for sixty frames, and then the cart did not
        move when right was pressed. The engine saw the button, was standing and facing right,
        called `WalkRight`, and `CollideHoriz` reverted the step. Written up on 2026-08-29 as a
        horizontal-collision defect in Step 13's territory; on 2026-08-30, after `room.spawn`
        was taught to load the room, rewritten as a collision defect that put her sixteen pixels
        too low. Neither was the port.

        Everything the port does here is correct, and each piece was checked against the
        cartridge rather than argued from the engine source. The **hitbox offsets** match the
        ROM byte for byte: `collision_samusHorizontal` (00:$1DD6/$1DE2) samples at
        `samusX + $0B` and `samusX + $14`, `collision_samusBottom` (00:$1F0F) at `+$0C`, `+$14`
        and `samusY + $2C`, and the engine's `!ORIGIN_*` derivation lands on those same six
        numbers. The **solidity threshold** matches: $5C on both, now reported side by side by
        `zig build trace` rather than left uncompared. The **worlds** match: both machines hold
        $1C at the feet slot and $1D at the slot the step is refused on.

        **The reference was reading the wrong addresses.** `correspond.pairs` paired
        `VarSamusY` with $FFC8/$FFC9 and `VarSamusX` with $FFCA/$FFCB — the scroll origin, not
        Samus. Measured over the segment: her real Y sits at $0384 and never moves, while the
        pair being graded says $0396 and also never moves, **so the Y rung of the comparator
        compared a constant against a constant for all 320 frames**; her real X advances 1.42
        px/frame, which is the walk speed `samus_walkRight` writes, while the graded pair
        advances 2.33. The $12 between $96 and $84 is eighteen pixels, which is the spawn below
        the floor James saw on the cart and the figure `snes_trace.footing` had already computed
        from the cart's own tilemap without knowing why. The cart is not misreading its world;
        it was *built* eighteen pixels low, because `chooseStart` and `reference` take the
        settled position from `room.placement`, which reads the wrong quad
  - [x] **B — the TAS validates the reference machinery.** The point is not to fix two
        addresses; it is that the Game Boy half of the correspondence map carries no obligation
        while the SNES half cannot be wrong by construction. 40 240 frames of known-good real
        play is the ground truth that was missing, it needs nothing from the port, and
        `src/tas.zig` already replays it
    - [x] Find Samus's position addresses **by behaviour over the replay rather than by reading
          the transition handler** — the search that would have rejected $FFC8/$FFCA on its
          first frame. Over the TAS, ask which addresses satisfy the properties the routines
          themselves state: the byte `samus_walkRight` stores must be the byte
          `collision_samusHorizontal` samples, and it must change by the walk speed on the
          frames she walks and not otherwise. Report the candidates and their scores, so a
          future disagreement is settled by a run instead of by a re-reading
    - [x] Give every pair in `correspond.pairs` a **falsification test over real play**, the way
          the SNES side already has one at build time. A pair whose Game Boy address is constant
          for the whole replay, or which never moves when its SNES counterpart does, fails —
          that single check is what the Y rung needed and did not have
    - [x] Repoint `correspond.pairs` at $FFC0/$FFC1 and $FFC2/$FFC3, correct `room.zig`'s
          "two copies" documentation to say what the two quads actually are, and fix
          `room.placement` and `room.spawn` to read and write Samus rather than the scroll origin
    - [x] Re-derive the boot record from the corrected addresses and re-grade the segment.
          **The segment stays** — it is a cheap regression test now that it is graded against the
          right quantities — but it is no longer described as the Phase 0a pass condition
    - [x] Verify: the address search names $FFC0-$FFC3 without being told them — over 3600
          frames of the any% run, $FFC2/$FFC3 takes 4740 writes and every one comes from the
          movement routines at 0:$1C2F-$1D46, $FFC0/$FFC1 takes 409 from `samus_moveVertical`
          at 0:$1D5A and 0:$1D9C, $FFC8/$FFC9 takes 41 from initialisation and transition code,
          and $FFCA/$FFCB takes 553 from the scroll-edge routines. The falsification test has
          teeth: it asserts the *old* addresses are **not** written by the owning routines, so
          it fails against a predicate that is accidentally always true. And a routine that
          never executed is reported as such rather than as a clean pass — `warpHandler` does
          not run in the first 3600 frames, and saying "no writes observed" about it would be
          the original mistake in a new place
    - [x] Verify: `zig build verify` green including the oracle rung. Every other rung is
          green — 3490 tests, 904 screens pixel-for-pixel, and the boot, play-window, samus,
          camera, scrolling, input and sprite rungs — and **Samus's position now matches the
          original on all 320 frames**. The rung is red on the camera alone, for the reason in
          the last sub-task below

          ***Corrected 2026-08-31: the bolded claim was false.*** The comparator returns the
          *first* divergence, and the camera's was at frame 92, so no run ever compared a
          position past it. With the camera fixed the rung is red on **Samus's position at
          frame 124 of 320**, and re-running with the old camera and the camera check disabled
          reports the same 124 — so it was always there, unmeasured. See the camera sub-task
          below

          ***Met 2026-09-01.*** `ok oracle 320 frames of the original, frame for frame, on map 0
          cell $38`, with `fault sweep 4/4 injected one-pixel faults named the right frame`
          behind it, inside a gate that is green end to end: **101/101 steps, 4245/4245 tests**.
          The frame-124 divergence was closed by the commit that found it was the *reference*
          being sampled at the LCD frame boundary rather than on the game's own tick — not a
          port defect, and not the spawn, which is what two earlier readings had assumed. So
          this rung is green on the port matching the original, not on a rung being relaxed
  - [x] **Added 2026-08-31: what the corrected oracle said, and what was wrong with it.**
        `footing` now reports *she starts on the floor, tile row 20 of column 6* — the
        spawn-below-the-floor James saw is gone, and both machines begin the segment at
        `082E,0384`. The divergence moved to frame 60 and changed character completely: it was
        no longer about collision or about the world, and both machines walked.

        Two claims were written down here from that trace and **both were wrong**, in the same
        way and for the same reason: they were read off the symptom instead of off the ROM.

        ~~The cart moves on the first frame the button is pressed; the original spends that
        frame entering the running pose.~~ The standing handler says otherwise. At 00:$1427 it
        reads `samusFacingDirection`, and only takes the no-movement turn branch when the facing
        is *wrong*: `CP $01 / JR Z,$1443`, and $1443 is `CALL $1C0D` — walk, and move on that
        same frame. At frame 60 both machines were facing right, so the original took $1443 and
        should have moved. Our `PoseStanding` has the same two branches. There was no missing
        frame to add, and adding one would have been a defect introduced to satisfy a
        misreading.

        ~~The walk alternation is out of phase.~~ It was not. The alternation was being
        suppressed, on our side, by `!Water` — see the collision-table sub-task below.

        The lesson is the step's own, restated: a divergence names a frame, not a cause, and
        the difference between the two is a disassembly

  - [x] **Added 2026-08-31: every room in the game was walking through its neighbour's
        block-type table.** The frame-60 divergence, chased properly, was three defects stacked,
        and only the last of them was where the symptom pointed.

        **`!Water` was set, and `WalkSpeed` refuses to alternate while it is.** For exactly
        eight frames of the walk our `!Water` held `$31` while the original's `$D048` held zero,
        and both machines' walk routines test that flag before they consult the counter at all
        (`LD A,($D048) / AND A / JR NZ` at 00:$1C14, `lda !Water / bne .done` in ours). So the
        cart walked a flat 1 px/frame where the original alternated 1 and 2 — which read, from
        the positions alone, exactly like a phase difference.

        **The flag was set because the two machines held different collision tables.** The
        reference held `collision_finalLab`; the cart's boot script says `COLLISION $6` and the
        cart held `collision_ruinsExt`, which marks a tile of that room's floor as water. No
        tile within the reference's picture is water at all — measured over the whole tilemap
        against the reference's own `$DC00`.

        **And the operand is not the table's index.** The op's handler at 00:$2859 banks in 8
        and reads a *pointer table*: `AND $0F / SLA A / LD HL,$7EEA / ADD HL,DE`. On this ROM
        that table is a rotation — operand $0 selects the second table and operand $7 the first
        — so an engine that treats the operand as a tileset index is off by one for **every room
        in the game**. The engine's own comment asserted the identity mapping and cited Step 4;
        Step 4 pinned the order the tables sit in ROM, which is a different fact.

        `offsets.zig` now inventories `collision_pointers` (bank 8:$7EEA, $10 bytes — exactly
        eight entries, because $7EEA+$10 is where `solidity_thresholds` begins, so a ninth
        operand would read a threshold row as a pointer). `tileset.collisionOrder` derives the
        mapping per ROM rather than hard-coding the rotation, and `snes_convert` emits the
        collision blobs in operand order so `FindBlob(!CLASS_COLLISION, operand)` is right by
        construction. `SOLIDITY` was checked the same way and is *not* affected: 00:$2430 is a
        flat `base + N*4` into `solidity_thresholds`.

        The test asserts the mapping is a permutation, that the region ends where the solidity
        rows begin, and that it is **not the identity** — without the last of those the test
        would pass against the very assumption it exists to refute
  - [x] **Added 2026-08-31: the original acts on the pad one frame after it reads it.**
        With the water gone the cart still ran two pixels ahead from the first frame of every
        walk and stayed there. The reference's own `$FF80` shows `$10` on frame 60 and she does
        not move until 61: the game polls the pad *after* `samus_handlePose` has run, so a
        button pressed during frame N first moves her on frame N+1. Our NMI polled before the
        main loop resumed. Checked against the alternative before changing anything — the GB
        harness sets the keys after each instruction step, so it could have been a one-
        instruction race at the frame boundary; setting them before the step instead changed
        nothing, which rules the harness out.

        `ReadPad` now maintains `!PadHeld`/`!PadEdge` — the original's $FF80/$FF81, including
        the rising-edge XOR that consumes the previous value — and `PublishPad`, called from NMI
        *before* the poll, hands them to `!InputPressed`/`!InputRisingEdge` one frame later.
        **Samus's position then matched the original on all 320 frames of the segment.**
        *(Corrected 2026-08-31: it matched for the 92 the camera's divergence let the comparator
        reach. It diverges at 124, which nothing could see until the camera sub-task below moved
        the camera's divergence out of the way.)*
  - [x] **Added 2026-08-31: the camera pair was mis-addressed, for the third time in the same
        shape.** With the position matching, the camera rung failed at frame 60 — and the
        reference's "camera" was jumping 242 pixels in a frame, which is not a camera.

        `$FFCC-$FFCF` is the **drawing origin**: 00:$0675 is `XOR A / LDH ($CC),A / LDH ($CE),A
        / LDH A,($C9) / LDH ($CD),A / LDH A,($CB) / LDH ($CF),A`, which zeroes both pixel halves
        and copies the camera's two screen bytes over. It is the camera rounded down to a
        screen, so it steps in metatile units and stands still in between — the rung was grading
        a staircase against a slope. `screens.zig` had pinned it by watching which HRAM the
        frame renderer reads before drawing, and that observation was correct; the inference
        from it was not. **An address the renderer reads is not thereby the variable the game
        maintains** — which is the same mistake, in a third place, as reading the `WARP`
        handler's writes and concluding those were Samus.

        The camera is `$FFC8-$FFCB`, maintained by 00:$08FE: it builds a cell index out of $FFC9
        and $FFCB, looks that screen's scroll flags up in the table at $4200, and at 00:$0949
        adds `$D035` — the speed `samus_walkRight` left behind at 00:$1C4D — straight into
        $FFCA. `locate.zig` now carries `camera_update`, and both camera pairs carry an `owner`,
        so the ownership test covers them the way it covers Samus. `room.zig` keeps the old quad
        under `draw_origin_*`, which is what `drawRoom` legitimately walks
  - [x] **The camera rung is still red, and the reason is the synthetic spawn rather than the
        port.** After the three fixes above the divergence is at frame 92, and it is an
        *initialisation* difference, not a dynamics one: the reference's camera has drifted to
        `081E` over its 60-frame settle while `InitState` seeds the cart's camera onto Samus at
        `082E`. Both then close on the same guide offset at the same rate, so the sixteen pixels
        show up as a catch-up that ends sixteen frames apart.

        The boot record already carries Samus's settled position; the camera is the other half
        of the same state and is currently a compile-time constant (`!CAM_START_X`). Carrying it
        would need `BootCamX`/`BootCamY` in the record, the injector's offsets and its
        wire-is-connected test, and one line in `oracle.grade`. **Not done here** — Step 15b
        removes the synthetic spawn entirely, and this is apparatus that exists only to serve it

        ***Done 2026-08-31, and the deferral's reasoning was wrong.*** The prediction was that
        `BootCamX`/`BootCamY` exist only to serve a spawn Step 15b removes. The opposite held:
        the movie needs them *more* than the segment did, and it was Step 15b's own residue
        audit that proved it. `InitState` seeded the camera onto Samus on the argument that a
        seeded start should be in view on frame 0. The game does not do that — at a handover of
        control its camera is wherever the opening's scrolling left it — so the audit measured
        `CamX $640 CamY $7C0` against a cart seeding `$648`/`$7D4`, Samus's own position. Every
        stretch the re-anchor grades would have started with the view in the wrong place, on
        every anchor, not just this one.

        Boot record version 4 adds the two fields (44 bytes, was 40); `InitState` loads them
        instead of copying the position; `snes_screen.Boot` gains `cam_x`/`cam_y` **with no
        default**, because the silent default is the bug the field exists to fix and a
        construction site that has not thought about the camera should not compile. A caller
        inventing a spawn writes her position, so nothing about Phase 0a's picture changes —
        `snes boot` still draws map 0 cell $38 pixel for pixel. `oracle.movieBoot` and
        `oracle.grade` write what they measured. The injector's wire-is-connected test covers
        both new fields, which matters here more than it did for the position: their default
        *is* her position, so a field that is written and never read is invisible on every cart
        the Phase 0a pipeline builds and shows up only against a movie.

        **Measured: the segment went from 92 frames to 124, and the divergence changed kind.**
        It is no longer the camera at all — it is Samus's position at frame 124, pose $07,
        input right, four frames after the segment's one `right_jump`. The residue audit's two
        `Cam` rows now read `same`, at a value that is *not* her position, which is what says
        the field carries the measurement rather than defaulting back to where it started.
        `FrameCount` is the only `differs` row left in the whole audit.

        **And the comparator got stronger for free.** The camera was compared *relatively*,
        each side against its own frame 0, because a port that could not be told where its
        camera began could not be graded on where it was. That is now a weaker check with no
        reason: a camera sixteen pixels out reaches the physics through `LatchCell`, so it
        clamps at a different moment and streams a different column, and a comparison of deltas
        calls that agreement right up until the divergence it caused surfaces somewhere else.
        Both axes are compared absolutely now — in the generated Lua, which is the thing that
        actually grades; `firstDivergence` is only the Zig model of it, and changing one and not
        the other would have graded nothing. The Lua's frame-0 check covers the camera too, so a
        cart whose record was not written lands on `code_wrong_start` rather than on a
        divergence a hundred frames later. The segment still reaches 124 under the absolute
        comparison, so the camera agrees frame for frame and does not merely move alike.

        ***A correction, and it is why this is not being called a 32-frame gain.*** Step 15's
        verify sub-task claimed **Samus's position matches the original on all 320 frames**.
        That claim was false and this step is what found it. It could not have been measured:
        the Lua returns the *first* divergence, and the camera's at frame 92 stopped every run
        before it reached frame 124. Rather than argue about it, the old camera seed was put
        back with the camera check disabled on both the start and the per-frame comparison, and
        the run reported **position diverged at 124** exactly as it does now. So the position
        defect predates boot record version 4 and is unaffected by it: the camera fix did not
        cause it and did not fix it, it removed the thing that was stopping the gate short of
        it. The honest summary is that the rung's red moved from a fixture artefact to the
        port's first real physics defect, which is worth more than 32 frames

  - [x] **Added 2026-08-30: teach `room.spawn` to load the room, not just arrive in it.**
        Two facts about the original, both taken from its own code rather than assumed.

        **A `WARP` is not a room load.** What loads a room is the door script the warp is the
        last opcode of: `door.zig`'s `copy` and `load` ops fill VRAM, `tiletable` selects the
        metatile table the screen bodies are expanded through, and `collision` and `solidity`
        select the tables the physics reads. Called alone, the handler inherits whatever the
        previous room left — which is exactly how the reference came to be standing in a Ruins
        exterior screen expanded through the *surface* table. `room.Spawn.door_index` now runs
        the interpreter at 0:$239C that `probe` found, before the warp so the warp overwrites
        the script's destination with ours; `snes_screen.Boot.door_index` already carries the
        door `screens.assign` paired with the cell, which is the same script the cart replays.

        **And the handler draws three columns of thirty-two.** 0:$07E4 queues one metatile
        column, two tiles wide — the other twenty-nine are left to the scroll-edge routines at
        0:$0700, which draw a column each time the camera crosses a metatile boundary. A spawn
        crosses nothing, so `room.drawRoom` walks the camera across the screen from
        its own origin and calls the game's own column draw sixteen times. It remaps the map
        bank before each one, because the frame wait in between calls the sound driver at
        0:$2384, which maps bank 4 and does not put it back; without that, one column of sixteen
        came from the map and fifteen from the sound driver's bank.

        *(Correction, 2026-08-30: an earlier draft of this said "a door in Metroid II is a
        scroll rather than a cut". James said from having played the game that some transitions
        fade, and he is right — **95 of the 497 decodable door scripts carry a `fadeout`**, 87 of
        them beside a warp. It changes nothing about the handler, which draws its three columns
        either way, but the claim as written was more than the ROM supports.)*

        Measured: the background map
        immediately after a spawn is the requested cell in **all 1024 tiles**, asserted both
        ways — with a door all 1024, without one fewer.

        **The precondition itself was overstated, and the correction is the interesting part.**
        The original's background map is a *moving window*, not a room: 32x32 tiles is exactly
        one screen, but it is world-aligned rather than screen-aligned, and the game keeps the
        256x256 window around the camera correct by drawing the columns and rows that scroll
        into it. Once the camera is anywhere but a screen's origin the map holds pieces of two
        screens, both of them right, so demanding 1024 tiles of one cell demands something the
        original never does. `oracle.windowMask` compares the overlap instead — the slots that
        are on screen *and* inside the cart's boot cell — computed from SCX/SCY and Samus's
        world position with no camera variable involved. $FFCC-$FFCF look like a camera and are
        not: 0:$0700 and its siblings write them from Samus's position with a different offset
        per scroll direction, so they hold wherever the last edge redraw was aimed, and reading
        them as a camera put the comparison an entire screen row out.

        **Third defect, exposed by fixing the first two:** `chooseStart` was picking a start that
        dropped Samus into a wall, from which the game ejected her sixty-six pixels left across
        the cell boundary — so `grade` built the cart for the cell she settled in while the
        reference's picture was the cell she started in. A candidate is now rejected outright if
        she ever leaves her cell during the probe, and `chooseStart` errors rather than
        defaulting when none qualifies. 3254 unit tests pass; the gate is red on the oracle rung
        alone, now for a port defect instead of a setup artifact

- [x] **Step 15b: C — the port plays the TAS, and the frame count is the gate**

  > **This is the active step.** Step 15 above is unchecked for a stated reason, not because it
  > is where the work is. Needs `export M2_ROM=$PWD/metroid2.gb` in `~/git/m2snes`.
  >
  > **Done 2026-09-01, with one sub-task deliberately deferred and left unchecked.** The porting
  > loop moved to Phase 0b having met its stop condition; the oracle infrastructure this step
  > existed for is built and gate-reported. The SameBoy reconciliation is deferred to Phase 0b —
  > it is not a D1 criterion and it costs patching the vendored emulator; its own sub-task
  > records the measured cost and the argument against deferring. State as of 2026-09-01:
  >
  > - `zig build oracle -- movie 900` reports **`REACHABLE: 372 frames`**, diverging at frame
  >   372-383 of 899 offered. The exact first disagreement is **reference frame 377, movie frame
  >   703** — the frame the game's map bank goes $0F to $0A and Samus is somewhere else
  >   entirely. It is a **room transition**, and the port has none. The thirteen frames before
  >   it, where she is pressed against the door holding right and not moving, the port already
  >   reproduces — those are play, not the transition; the transition itself is instantaneous
  >   and costs five held frames after it, measured by the duration sweep. Porting it is Phase
  >   0b's opening work, not this step's.
  > - **`zig build verify` is green end to end**, 99/99 steps and 4212/4212 tests. The segment
  >   oracle's long-standing `position diverged, at frame 124-127 of 320` is gone: it was the
  >   *reference* being sampled at the LCD frame boundary rather than on the game's own tick,
  >   not a port defect and not the spawn. Its sub-task below records the whole diagnosis,
  >   including that the movie reference is still sampled the old way.
  > - **The `reachable` rung is in as of 2026-09-01**, so a change that shortens the port's run
  >   now fails the gate: `the port reaches 372 of 899 frames of the any% run (floor 372)`. It is
  >   a different number from the `tas horizon` rung (any% 8407, 100% 4566), which measures the
  >   *reference replay's* fidelity rather than the port's progress — a sub-task below was
  >   wrongly checked off for weeks claiming they were the same. Raise `oracle.movie_gate_floor`
  >   whenever the count goes up, and re-measure it if `movie_gate_frames` ever changes.
  > - **The duration half landed 2026-09-01.** `zig build oracle -- durations` grades the
  >   stretches the frame-exact comparator must not grade — cutscenes, transitions, menus — on
  >   length, and the gate carries it: `15 of 60 stretches compared, 11 inside 2%`. The four
  >   that differ are port defects nothing else could see, because a frame-exact comparator
  >   stops at the first one and never reaches the second. The thirteen frames the sub-task was
  >   written around were not the transition; its write-up says what they were instead.
  > - The checked sub-tasks dated 2026-08-31 and 2026-09-01 are a log of what has been ported
  >   and why.

  **Added 2026-08-31.** B makes the reference trustworthy; C removes the need to trust it. The
  only reason Phase 0a needs a synthetic spawn at all is that the segment starts on a screen we
  chose, and reaching a screen nobody chose requires poking RAM that the game would have filled
  itself. Start where the game starts and that whole apparatus goes away: both machines run from
  a state neither of us invented, SameBoy can produce a reference without being poked, and the
  movie's own opening frames are the input.

  This is where F10's **reachable-frame count** becomes the real gate. Today it is zero — the
  cart boots from a boot record, not through the game's opening — and it grows as the port
  grows, through the rest of Phase 0a and across Phase 0b. The end state James named is the
  whole movie running start to finish.

  **Scoped honestly for Phase 0a.** The metric and its harness land here; the frame count does
  not, and it should not be expected to. The any% run presses Start and then walks Samus out of
  a ship, into a save-adjacent corridor, past enemies, and into rooms reached through door
  transitions — ship, enemies, transitions and shooting are all D1's Phase 0b, so the number
  this step establishes will be small and honest rather than impressive. What matters is that it
  is a number produced by the movie rather than by a segment we wrote, and that it can only go
  up.

  - [x] Make the port bootable into the game's real opening rather than a boot record, or
        establish in measurements why it cannot be in Phase 0a and what Phase 0b has to land
        first. Either outcome is a finding; guessing at it is not.

        **It cannot, and the measurement says so in intervals rather than in one movie's
        frame numbers.** Both published runs, replayed frame by frame — `tas.findOpening`,
        with `tas.Opening` holding the landmarks:

        |                                       | any% | 100% |
        |---------------------------------------|-----:|-----:|
        | Start pressed                         |    4 |    1 |
        | map bank in range (the room is loaded) |    5 |    2 |
        | Samus placed, pose $13                |    7 |    4 |
        | pose leaves $13                       |  325 |  322 |
        | first pixel of movement               |  327 |  324 |

        The absolute frames differ because each run presses Start on its own frame. Every
        interval is identical: load at +1, placement at +2, then **exactly 318 frames** held in
        pose $13, then movement at +2. Two recordings agreeing to the frame is what makes these
        the game's numbers and not a movie's. She is placed at the same pixel in both —
        y $07D4, x $0648 — before either has pressed a direction, so the game chose it.

        Across those 318 frames her position never changes, and the any% run holds A for ten
        frames from 118 and B for nine from 129 without moving her or changing her pose. The
        game is being offered input and is not taking it. A frame rendered from the middle of
        the stretch is the ship on the surface with the HUD already reading 99 energy, 30
        missiles, 39 Metroids.

        **Three things stand between the cart and the movie's frame 0, and two are real gaps.**
        Frames 0 to the Start press are the title screen: `gfx_titleScreen` is extracted and
        nothing draws it, and `Reset` has no screen other than a room and no state to leave —
        that is a title screen plus a state machine. The room load is a mechanism the port
        already has by another route (`RunBootScript`/`LoadScreen` off a boot record). The 318
        held frames are a scripted sequence Phase 0a cannot play: the pose machine has no entry
        for $13 and no notion of a stretch in which input is ignored. **What Phase 0b has to
        land first is therefore the title-to-game transition and pose $13's sequence.**

        **And the half that unblocks C without either.** The port's frame zero is `control`,
        not 0. At that frame the game has placed Samus itself — on a screen nobody chose, at a
        pixel nobody chose, with the loadout it hands a new file — and held her still long
        enough that the state is quiet. That is exactly what a boot record expresses, so
        `chooseStart`'s synthetic spawn is replaced by the game's own answer with no title
        screen and no cutscene, and the reachable-frame count is counted from `control` onward.

        **The wrong answer is under test.** "The movie is in play once the landing site loads"
        is off by 318 frames and was the assumption the rest of this step would have been built
        on. `findOpening` on a 200-frame replay reports the room entered before frame 60 and
        then returns `NeverGainedControl`, so substituting that answer back in fails. 3496 unit
        tests pass
  - [x] Feed the TAS input stream to the cart through the same channel the segment uses, and
        report the **first divergent frame** against the reference — F10's wording, over the
        movie instead of over 320 hand-authored frames.

        `zig build oracle -- movie [frames]`, via `oracle.gradeMovie`. Nothing in that path
        chooses anything: `chooseStart` does not run, no cell is scored, no spawn is synthesised
        and no pose is forced. The movie boots the game, the game places Samus, and the boot
        record is filled in from where she ended up.

        **The number is 1.** The port follows the any% run for one frame from the handover and
        diverges on position at frame 1, exactly — `frame 1` and not a bucket, because a
        divergence is re-run against a reference truncated to the end of its bucket so the
        one-byte channel resolves to a single frame. Small and honest, as this step said it
        would be, and it can only go up.

        **Four things had to be settled to get a number at all, and three were findings.**

        1. *The reference's frame 0 is `control + 1`, not `control`.* At the handover the game
           has just left pose $13 and is standing still; `first_move` is two frames later.
           Anchoring one frame past it starts both machines from rest in a pose the port has.
           Anchoring at `control` would have compared the Game Boy's $13-to-standing transition
           against a cart with no $13 to leave — an initial-conditions difference, which grades
           nothing. This is the same argument `reference()` already makes for forcing `stand`.
        2. *The game's own starting cell is one no door script names.* Map bank $F, cell $76.
           **41 of the 905 in-use cells have their tileset stated by a door warp**; this is not
           one of them, because a new file starts there and nothing warps to it.
           `screens.assign` infers it from the nearest warp target, 2 grid steps away.
           `bootCandidates` and `chooseBoot` filter to `.door` provenance — right when you are
           free to choose — so the first attempt refused the cell outright.
        3. *Refusing was wrong, and the measurement says so.* `snes_screen.bootFor` now returns
           whatever the assignment concluded together with how it concluded it, and
           `compareWorlds` decides whether the answer was right. **For this cell it is right:
           the two worlds agree on all 306 compared tiles.** A `.scrolled` cell that matches
           tile for tile is a correct boot; one that did not would have been a measurement that
           the inference failed there. Either beats declining to try.
        4. *The movie asks for things the port has no key for, and they are counted rather than
           dropped.* `unsupportedBits` names them by bit — B is shooting, Start the pause, Select
           the map, Up aiming, Down the morph ball — and right-plus-left is counted as
           unsupported rather than approximated to either one, since the original resolves it in
           code we have not read. The any% run presses **Down at frame 1**. That is a *ceiling*
           on the comparison, not a verdict on the port, and it is reported as a separate number
           from the divergence for exactly that reason: one says the port is wrong, the other
           says the port was never asked.

        **Mechanically**, `tas.Options.watcher` lets the oracle take its reference through the
        replay loop rather than owning a second copy of it — the loop owns the input origin, the
        frame-boundary source and the stall deadline, and a second copy is a second place for
        the origin to be wrong. `oracle.Take` bundles the three things the segment and the movie
        differ in (reference, per-frame inputs, exit-code resolution), so the script generator,
        the protocol and the fault sweep are written against it rather than against `segment`.
        `perCode` derives the resolution from the reference's length instead of the fixed 4,
        which silently stopped resolving anything past frame 320.

        **Under test**, with the wrong answers falsified: the reference's frame 0 must be at the
        landing site *and* must differ from `samusStart`'s cell midpoint, which is what every
        boot record held before a movie was allowed to choose — so a quiet revert to Step 15's
        synthetic spawn fails. 3606 unit tests pass
  **Re-scoped 2026-08-31, on James's call, and `01-requirements.md`'s F10 is amended to match.**
  The first two sub-tasks above were built on a single anchor at the game's one handover of
  control, and the number that came out was 1. Two things are wrong with carrying on that way.

  *Frame-exactness through a cutscene is not a gate anyone can pass.* The opening is a title
  screen plus 318 frames in which input is offered and ignored, and reproducing that
  frame-for-frame means reproducing timing that says nothing about whether the port plays the
  game correctly. James: cutscenes and screen transitions should be graded on **length**, and
  98-99% is good enough. Written into F10 as a 2% tolerance with the measured percentage
  recorded per stretch, and flagged there as a stated judgement rather than a derived figure.

  *And a single anchor caps the count at one screen.* Re-anchoring at every handover of control
  lets the port be graded frame-exactly on the stretches that are actually play, without owning
  any cutscene logic. The count becomes frames matched across anchored playable stretches plus
  the stretches whose duration held — still monotone, still a progress metric, and nonzero much
  sooner.

  *The build order follows from it.* Components are added in the order the movie needs them
  rather than screens being built in a vacuum and hoped to be reached. Each stop of the count
  names the next component, and parity is maintained as each lands rather than reconciled at the
  end.

  **One thing measured after the count was committed, and it is why the residue audit comes
  first.** Sub-task 2 assumed that skipping the opening was free. It is not: at the handover the
  Game Boy's frame counter `$FF97` reads **$47**, and the cart's own starts at 0. That is *not*
  claimed to be the frame-1 divergence — the reference's walk step across frames 4-11 is a
  constant 2px, so the 1/2 alternation `WalkSpeed` takes from that counter is not visibly in
  play, and asserting it would be exactly the unfalsified inference the last three sessions were
  spent on. What is established is narrower: there is at least one measured state difference at
  the anchor that was treated as zero, and until the residue is audited the count of 1 does not
  mean much.

  - [x] **Audit what the opening leaves behind that the port's physics reads.** Diff the Game
        Boy's state at the handover against what the cart's boot record establishes, field by
        field, and for each difference say whether any routine the port has actually reads it.
        `$FF97` is one known difference; the audit is what says whether it or anything else
        explains the frame-1 divergence. A difference nothing reads is a finding too — it bounds
        how much of the opening has to be reproduced rather than skipped

        **Done, and it did not find what it went looking for.** `src/residue.zig` is the audit
        and `zig build oracle -- residue` prints it: 49 direct-page variables, each with what
        establishes it on the cart, whether a frame can observe what it started at, and the
        routines that read it. **33 are carried across a frame boundary; 16 are scratch**, which
        is the audit's cheapest result — for those sixteen the opening can leave anything at all
        and no frame the port runs can tell. That is a bound on how much of the opening has to be
        reproduced, stated as a measurement rather than as a hope.

        **The reader lists are checked, not asserted.** `residue.sites` scans `engine/main.asm`
        for every line that touches a define, classifying `sta`/`stz` as a write and `inc`/`lsr`
        as read-modify-write, and a test compares the scan against every row's `reads`. Writing
        it this way round is the point: a reader added to the engine fails the test rather than
        silently turning a `scratch` field into a wrong one. It caught two transcription errors
        in the table on the first run (`SamusY` missing `InitState`, `Items` out of order). The
        engine source is embedded for it — `addEngine` now carries `engine_asm` beside
        `engine.bin` and `engine.sym`, because what a routine *does* with a variable is in
        neither of the other two.

        **Three measured differences at the handover, out of nine fields with a pinned Game Boy
        counterpart.** Six agree, and they are exactly the ones Step 15b was built to close:
        `SamusX`, `SamusY`, `Pose`, `MapIndex`, `Cell`, `Water`. The three that differ:

        - **`FrameCount`: `$47` on the Game Boy, `$00` on the cart.** The known one, now with
          its readers named. Nothing but NMI writes it, and three of its four readers are
          physics: `WalkSpeed` takes `(n & 1) + 1` as the walk step, `PoseJumpStart` takes
          `(n & 2) >> 1` off a jump's initial rise, `PoseSpinJump` gates a held Up on `(n & 3)`.
          Neither counter is ported but their parity is, and the port's is set by its own reset
          while the reference's has run the whole opening.
        - **`CamX`: `$640` against `$648`. `CamY`: `$7C0` against `$7D4`.** *The audit was not
          looking for this one.* `InitState` seeds the camera exactly onto Samus, which was a
          sound default while the boot record described a spawn we invented; the game does not
          do that, and leaves its camera where the opening's scrolling left it — eight pixels
          off horizontally and twenty vertically. Five routines read it. It reaches the physics
          only through `LatchCell`, which turns a camera position into the cell `LoadScreen`
          draws, so it cannot move Samus on the frame it is wrong but can hand her a different
          tilemap a screen later.

        **And the honest answer to the question the sub-task asked: no, the residue does not
        explain the frame-1 divergence.** The frame counter's alternation is not visibly in play
        at this anchor — the reference's first eight frames go `stand`, `$03`, `$04`, `$04`,
        `$05`…, straight into the run, whose step is a flat two pixels, and no frame in the
        window steps by one. That is a test (`the reference does not walk into the alternation
        the counter feeds`), not a remark. The camera cannot move her inside one frame. So the
        divergence is in how the pose machine answers the first right press, and that belongs to
        the re-anchor sub-task rather than to this one. The `oracle -- movie` count is unchanged
        at 1, which also confirms the `movieBoot` refactor — the three boot-record overrides
        pulled out of `gradeMovie` so the audit diffs against the same record — changed no
        behaviour.

        **A caveat on the headline, measured rather than assumed away.** `$FF97` over the first
        eight reference frames reads 71, 72, 73, 74, 75, 75, 77, 78: it advances by seven over
        seven frames, so it runs at one per frame, but the watcher's sample point straddles its
        increment and consecutive frames can repeat and then skip. Good enough to say the two
        counters are unrelated; **not** good enough to say what the reference's parity was on a
        named frame. Anything needing the second thing needs a better sample point first. Also a
        test.

        **What is still unmeasured, and named rather than glossed: 24 carried fields have no
        pinned Game Boy counterpart.** The audit reports them as `unmeasured` instead of
        guessing an address, because a guessed address is how Steps 14 and 15 spent three
        sessions comparing the wrong pair of bytes. The one worth pinning first is `TurnTimer`:
        `HandlePose` reads it on *every* frame before it dispatches, and nothing but the two
        turn poses writes it, so a nonzero value at an anchor changes the very first frame. The
        second is `Items`, which the engine never writes at all — correct at zero for the game's
        start and wrong the moment the run collects anything, which makes it the first field a
        later anchored stretch will need.

        **The component this names next: the boot record has to carry the camera and the frame
        counter.** Step 15 deliberately did not build `BootCamX`/`BootCamY` because they existed
        only to serve the synthetic spawn, and that was right. The audit gives them a different
        and better reason — the game's own camera at the handover is not on Samus, and the
        record is what re-anchoring will seed at every handover, not just the first.
  - [x] **The porting loop ran until it stopped naming poses, which was its stop condition.**
        Each turn read `zig build oracle -- movie 900`, took the component the stopped frame
        named, disassembled it and ported it branch for branch. It produced the crouch, the
        one-frame input lag, the morph ball, the ball's sprite and the counter's phase — the
        checked sub-tasks above are its log.

        **Moved to the Phase 0b stub on 2026-09-01, with the loop's procedure intact.** Its own
        stop condition — "done when the count stops on something that is not a pose handler" —
        was met: the count now stops at reference frame 377 / movie frame 703 on a **room
        transition**, which is a whole mechanism rather than a routine to transcribe, and which
        D1 puts in Phase 0b. Leaving a standing porting loop inside Phase 0a's last steps is what
        made this step look bottomless when it is nearly done. The loop is how Phase 0b is built,
        so it opens Phase 0b's cycle instead

  - [x] **Make the gate say *why* it stopped, not just where.** Added 2026-09-01, after two bugs
        were found by playing `build-out/m2snes.sfc` rather than by the gate. Done the same day;
        the third part is measured rather than built, and the reason is below.

        - [x] **`!Unhandled` is now read by the thing that grades.** The engine's comment claimed
              the gate read it; `src/snes_trace.zig` was its only reader in the repository, so
              when the run met pose $08 with no handler the gate said "position diverged at 216"
              and a player found the hard lock. `writeLua` now reads it at every commit — before
              the position check, because an unhandled pose is the *cause* and the position
              divergence a frame later is its symptom — and stops with **exit code 180+pose**.
              The pose is in the code rather than a single "unhandled" code because *which* pose
              is the whole value of the check: it names the next thing to port. 180 is where the
              camera's range ends and 255 is Mesen's timeout, leaving 75; every pose the Game
              Boy's machine dispatches ($00-$13) fits, and `unhandledPose` reports saturation
              rather than a wrong number if one ever does not.

              **Falsified rather than assumed**: deleting `HandlePose`'s `!POSE_MORPH` arm — a
              pose the published run actually reaches — makes the movie oracle print
              `STOPPED: the port was handed a pose it has no handler for -- pose $05`, where
              before it would have reported a position divergence some frames later. Restored
              after. Adding the check left both graded runs unchanged, which was the prediction:
              nothing in the first 372 frames is unhandled.

              The engine's two comments are corrected, and the correction says when the reader
              appeared so the next person can tell a described check from an existing one.
        - [x] **The two pose dispatches are now checked for agreement at build time.**
              `residue.poseArms` collects the `!POSE_*` set each dispatch compares against, and a
              test asserts `HandlePose` and `SamusSpriteId` offer the same one. Scoped per
              routine rather than per file, because `cmp.b #!POSE_*` also appears *inside*
              handlers — `PoseJumpStart` tests `!POSE_NJUMPSTART` to tell its two entries apart —
              and a whole-file scan would fold those in and fail for something that is not a
              defect. A second test pins that distinction.

              **Falsified the same way**: with the morph arm removed the test reports
              `expected 10, found 11`, which is exactly the shape of the bug that shipped the
              ball with no sprite arm for a day.

              ***And writing it found that the engine scanner was misreading nine lines.*** asar's
              anonymous local labels sit in column zero and share the line with the instruction —
              `+       sta !Hit` — so `residue.sites` took `+` for the opcode and fell through to
              `.read`. Nine write sites in `engine/main.asm` were being scanned as reads. One is
              on a variable the audit's table carries: `SampleTile` was listed among `!Hit`'s
              *readers* and is a writer. It changed no verdict — `Hit` is scratch either way —
              but the reader list is the evidence the verdict rests on. `stripLocalLabel` fixes
              both the new scan and the old one, and the table entry records what it was.
        - [x] **Pose is still recorded and not compared, and now there is a measurement saying
              what that costs.** The re-test the sub-task asked for, run on the segment because
              it has a known divergence to measure against:

              | | frame |
              |---|---|
              | first **pose** disagreement | **121** — reference $01 (jump), cart $09 (jump start) |
              | first **position** disagreement | **124** |

              So comparing pose would report this divergence **three frames earlier**, and would
              report it as "the port is still in the jump-start pose when the original has
              entered the jump" rather than as one pixel of X. The same pair recurs at frame 201
              on the standing jump. The hypothesis in this sub-task was right.

              **It is measured and not built, deliberately.** The exit channel is one byte:
              20-99 position, 100-179 camera, 180-254 the unhandled pose added above. A third
              graded quantity at frame resolution needs 80 more codes, which means re-partitioning
              to about 58 per quantity and taking the movie's bucket from 12 frames to 16 — a 25%
              loss of resolution on both existing quantities, and a re-measurement of
              `movie_gate_floor`. That is a trade worth making deliberately or not at all, and it
              is not this sub-task's to make in passing. **What the measurement changes now** is
              that it points at the frame-124 defect below: the port spends an extra frame in
              pose $09 before $01, and the one-pixel X difference at 124 is downstream of it.
        - [x] **Unblocked `zig build trace`, which is what took the measurement.** It had not
              compiled since `oracle.Key` became a packed struct: `trace_main.zig` still called
              `@tagName` on it. Nothing in `zig build verify` builds this tool, so nothing said
              so. It is the "why" tool the porting loop reaches for after the gate names a
              frame, and it was broken on `main`

  - [x] **The segment oracle's position defect at frame 124.** Added 2026-09-01 to give it an
        owner: it is the only FAIL in `zig build verify` and no sub-task pointed at it, while
        Step 18's verify criterion requires the gate green end to end.

        **Fixed 2026-09-01. It was neither of the two leads, and it was not in the port.** The
        reference was being sampled in the middle of the game's frame. `zig build verify` is
        green end to end: `ok oracle -- 320 frames of the original, frame for frame`, the fault
        sweep still 4/4, 3914/3914 tests.

        `harness.Machine.runFrames` returns when the **LCD** completes a frame, which is the end
        of VBlank, and that instant has no fixed relationship to how much of the game's
        per-frame work has run. `reference` read its record there. So the reference's frames
        were a machine caught mid-tick, and the cart's -- taken at the engine's own commit
        point -- were not. `reference` now advances by one of the game's ticks per record
        (`stepOneTick`, stopping on 00:$052F, the main loop's `CALL samus_handlePose`), and all
        320 frames match in position *and* camera.

        **How it was found, and why the leads were wrong.** The ROM stores pose $09 on a
        standing jump at 00:$14CB and returns -- both the directional path (00:$13DC -> $149E)
        and the directionless one (00:$1498 -> $149E) reach that store. Yet the reference's
        record never contained a single $09 frame while the cart's always did. That is not a
        physics disagreement; a pose the ROM writes and the reference never shows is a
        *sampling* disagreement. Everything else followed:

        - **Lead 1 was the symptom, correctly seen.** The port was not a frame late into $01;
          the reference was a frame early out of $09. The two position divergences are exactly
          what that one-frame offset produces: at 204 the reference had run one more arc frame
          (+3 in y) and at 124 the air-right step inside it (+1 in x). Both re-converged on the
          next frame, which is the signature of an offset rather than a wrong constant.
        - **Lead 2 was false, and the diagnostic was the thing at fault.** The two machines use
          the *same* collision table. `trace_main.zig` printed `tileset.tilesets[operand]` on a
          raw door-script operand -- the exact mistake `tileset.collisionOrder`'s doc comment
          was written to warn about, and which had already cost Step 15 a false divergence. The
          ROM's `collision_pointers` is a rotation: operand 6 resolves to `collision_finalLab`,
          which is what the Game Boy holds, and `snes_convert` lays the cart's blobs out in
          operand order so the engine resolves it too. The trace now maps through
          `collisionOrder` and the `<-- they disagree` line is gone. **A lead that reached this
          plan came from a tool nothing in the gate builds** -- `zig build trace` had not
          compiled for weeks before the sub-task above made it compile again.

        **And a latent bug the fix exposed.** With the segment finally surviving to its last
        frame, the gate reported `the segment ended early (exit 4)`: `emu.stop` does not unwind
        a Mesen2 callback, so the `emu.stop(0)` on the final frame fell through to the
        `i > #KEYS` guard and was overwritten. Every stop in that callback now returns, so the
        *first* verdict is the one reported. The pass path had never once been executed.

        **Locked in by a test that fails without it**: `"the reference is sampled on the game's
        tick, not on the LCD's"` asserts pose $00/$09/$01 across frames 200-202 and that $FF97
        advances exactly once per record. Reverting `stepOneTick` to `runFrames` makes it report
        `expected 9, found 1`.

        **The movie reference does *not* share the defect. Checked, because it looked like it
        did.** The note first written here said the movie path was sampled the same way and that
        the 372 was measured through the same misalignment. That was wrong, and measuring it is
        what said so: **the two paths take different boundaries, and only one of them is the
        LCD's.** `harness.runFrames` returns on the LCD's own frame completion — the end of
        VBlank, which is the middle of the game's main loop. `tas.run` takes the 143->144 edge
        (`FrameSource.vblank`), where the game has finished its loop body and is waiting. The
        second one is already the game's commit point.

        Measured before believing it, by building the treatment and watching it make things
        worse: a tick-aligned movie reference (hooking 00:$052F, or equivalently 00:$0577 one
        frame later — the two agreed, which is its own check) took `REACHABLE` from **372 to
        120**, and re-fitting `movie_key_lead` around it gave 1 at lead 0 and 4 at lead 2, so
        120 was the best that phase could do. Two smaller findings fell out on the way and are
        worth keeping: the game has **two** main loops that call the pose machine (00:$052F and
        00:$059E), and some frames call **neither** — 00:$0522 tests `$D048`'s neighbour `$D00E`
        and skips the pose machine entirely, which is how a cutscene stops Samus without
        stopping the game.

        The proof is a test rather than a paragraph: `"the movie reference is already on the
        game's tick"` asserts $FF97 advances exactly once per record over 400 frames of the any%
        run, and fails with `expected 76, found 75` if that run is switched to `.lcd`. The
        exploratory `tick_pc`/`onTick` hook added to `tas.zig` to run these measurements was
        reverted — nothing uses it now, and an unused hook in the replay loop is a second place
        for the frame boundary to be wrong.

        **So the reachable floor of 372 stands, and was not measured through a misalignment.**

  - [x] **Re-anchor: grade every playable stretch, not just the first.** Find each handover of
        control in the movie the way `tas.findOpening` finds the first, compare frame-exactly
        from each, and sum. Report per stretch as well as in total, since a total hides which
        stretch regressed

        **Half built, and then blocked by what building it measured.** The generalisation is
        `tas.findRefusals`: a **refusal** is a maximal run of frames on which Samus's position
        and pose both hold still, and it carries the union of what the movie held during it
        (`offered`) and how long after it ends she first moves (`moved_after`). That last field
        is the discriminator, and it is why this is not merely a stillness detector — the
        opening ends with the game giving her back and she moves three frames later, while
        Samus standing against a wall produces the same still stretch and answers a tapped Down
        with a pose change and *no movement at all*. The generalisation is checked against the
        special case rather than trusted: on both published runs the first refusal is the same
        stretch `findOpening` finds, same start, same `landing_pose`, same 318 frames, ending on
        the same `control` frame. A test asserts it, so the re-anchored comparison cannot
        quietly grade from a different frame than Step 15b measured.

        **And then it found that there is nothing else to anchor on, because the replay stops
        being the published run about 220 frames after control.** Measured on both movies:

        | | any% | 100% |
        |---|---|---|
        | control handed over | 325 | 322 |
        | first stuck refusal | **546** | **535** |
        | its length | 251 frames | 260 frames |
        | held during it | `$D0` (right, up, down) | `$50` (right, up) |
        | frames until she next moves | **519** | **520** |

        She is holding right into something she cannot pass. The pose still answers — a tapped
        Down blips it and returns — so the game is hers; it is the *route* that is wrong. Over
        the whole any% movie the consequences are unambiguous: 1 of 7 map banks visited, the
        Metroid counter never once falling from its starting 71 across 40,000 frames of play,
        and at frame 40,241 the game back on the title screen in pose $10 for the remaining
        122,000 frames. A published any% run does none of those things. `zig build tas` now
        prints the horizon beside the progress markers, because a replay that stops being the
        published run at frame 546 has not "visited one map bank", it has failed to visit six.

        **What this costs, stated plainly.** F10 names the published run as the whole-game gate
        and its reachable-frame count as the progress metric. Both rest on the replay being the
        published run, and it is that for roughly 220 frames. Re-anchoring cannot add a single
        anchor until the horizon moves: the only handover inside the faithful window is the one
        Step 15b already grades. This is not a reason to change the metric — it is the reason
        the metric was worth having, since it is what surfaced this at all.

        **One lead, offered as a lead and not a diagnosis.** The VBM header's `options_flags` at
        offset $17 reads **$30 on both movies**, and `src/tas.zig` has never decoded it: every
        other header field there carries a measured note and this one is read and ignored. A
        recording option that neither the parser nor the harness honours is one of the things
        that could put a replay off-route this early. It is equally possible the cause is our
        Game Boy's timing, and nothing here distinguishes them yet.

        ***Resolved the same day, and the lead was wrong.*** `options_flags` was not the cause
        and is still undecoded; it is no longer suspected. The cause was this repository's own
        frame boundary, four scanlines away from the game's joypad poll — see the sub-task
        below, which was added as this one's prerequisite and is now done. **The block is
        lifted.** The numbers in the table above are the old boundary's: the horizons are now
        8407 and 4566, and the any% run reaches 4 of 7 map banks inside 12 000 frames.

        ***Done 2026-09-01. The grading half is built, and building it found three fields the
        boot record was missing and one rule the anchors needed.***

        `oracle.anchorsFor` turns the refusals into anchors and `oracle.gradeAnchored` grades
        each stretch from its own boot record — one replay and one asset conversion for all of
        them, because doing either per anchor is the same waste twice. `zig build oracle --
        anchored` prints one line per stretch and then the sum, and `zig build verify` gained an
        `anchored` rung beside `reachable`. **The two are deliberately different numbers**: one
        measures how far the port survives from the game's single handover of control, the other
        how much of the run it can play at all, and neither bounds the other.

        **An anchor is not the handover, and that is the rule.** Measured on the any% run:
        **seven of the thirteen handovers straddle a room change**. A boot record is taken from
        the frame *before* the reference's frame 0, so the cart was built for the room she was
        leaving and graded against the one she arrived in — which showed up as a position
        differing in the screen byte and agreeing in the pixel byte, the shape a room change
        makes inside a comparison that does not know it happened. `pushToStableAnchor` requires
        the room *and the pose* to hold across the anchor; `settleAnchors` then pushes further
        until the two machines agree about the *picture*, because a warp draws three metatile
        columns of thirty-two and the scrolling draws the rest — **up to 46 frames** on this run.
        `zig build oracle -- settle` reports that per handover, and it is also the Game Boy's own
        duration for each transition, which is the next sub-task's first input.

        **Three fields, each found by the sweep and each measured rather than argued.**

        - **Pose.** `movieBoot` forced `stand`, on `movie_origin_delay`'s argument. That is right
          for exactly one anchor: every other handover in this run is in the ball ($05), a fall
          ($07/$08) or a jump ($01). All eleven diverged at frame 0.
        - **Facing.** `InitState` stored $01 unconditionally, so every cart booted facing right.
          On a stretch where she falls leftwards the cart spent frame 0 turning instead of
          moving and ran exactly one pixel behind for the whole stretch. Boot record version 6.
          The residue audit had this row down as "worth no more than the coincidence it is, and
          a run that turns left before the next anchor is what would actually test it" — this
          was that run.
        - **The pad.** `PublishPad` runs *before* the poll, so `!InputPressed` at the first
          commit is whatever `!PadHeld` held when NMI first ran — zero on a cart that boots
          itself. At a handover the game is already mid-input. Version 7 carries it, applied on
          `MainLoop`'s **first pass** rather than in `InitState`: enabling NMI fires one
          immediately and its `PublishPad` consumes the seed a frame early. The frame trace is
          what said so — `held` holding the seed and `pressed` zero — so `!PadHeld` is exported
          now.

        **And a correction the pad seed forced, which is the interesting one.** `movie_origin_delay`
        was 0 on the measurement that the pose byte reads `stand` at `control`. That measurement
        was right and the inference from it was not: `control` is the frame the game spends
        *leaving* pose $13, and it answers the movie's held `right` by not moving. A cart booted
        standing with that pad walks on it. **Two errors had been cancelling** — the cart also
        did not move, for the unrelated reason that its first `PublishPad` had nothing to
        publish — and the opening scored 375 frames on the strength of it. The single-anchor path
        uses `pushToStableAnchor` now too, so both paths anchor at 328 rather than 326, and
        `movie_origin_delay` is the floor of a search rather than the answer.

        Three tests elsewhere pinned numbers measured from the old anchor and were re-measured
        against the new one. One of them, the audit's own anchor check, had been asserting
        `control + movie_origin_delay == origin` — a restatement of the rule rather than a check
        of it, which is why it failed when the audit followed the oracle correctly. It compares
        the two answers now, which is what its comment always claimed.

        **Measured: 394 frames across 9 of 13 gradable stretches**, reproducible across two runs,
        against 372 from the single anchor. Four stretches are not graded at all — the cart
        cannot be booted into their rooms inside the 120-frame settle search — and they are
        reported as absent rather than as zero, which is the same distinction the duration
        sub-task below exists to make. `zig build trace -- stretch N` traces one stretch, and is
        the only thing that answers *why* on the twelve the segment cannot speak for.

  - [x] **Find the horizon's cause and move it.** Prerequisite to the re-anchor above, added
        2026-08-31 because the measurement demanded it, and done the same day.

        **It was not `options_flags`, and it was not the CPU. It was where this repository
        thought a frame ended.** Metroid II reads the joypad inside its VBlank handler: ten
        reads of `$FF00` at **LY 149**. `tas.zig` applied each frame's input at the LY wrap,
        four scanlines later — so the poll sat pressed against the boundary, and the game's
        frame is not a fixed length, so it drifted across. Measured over the any% run's first
        8000 frames: **713 frames whose poll the boundary cut in half**, the game reading the
        previous frame's byte on each. The first is at frame 463, where the movie taps A for a
        single frame and the game never sees it; eighty frames later she is walking into a wall,
        which is the refusal at 546 the last session found.

        `.vblank` puts the boundary at LY 144 — where VBA's own GB core ends a frame, and five
        lines *before* the poll. The same 8000 frames misdeliver nothing.

        | | before | after |
        |---|---|---|
        | any% horizon | 546 | **8407** |
        | 100% horizon | 535 | **4566** |
        | any% map banks in 12 000 frames | 1 of 7 | 4 of 7 |
        | frames misdelivered in the first 8000 | 713 | 0 |

        **None of it is asserted.** `tas.delivery` reads `$FF80`, which is where the game's own
        joypad routine leaves what it read, and `pollShape` separates a poll the boundary cut
        from a frame the game *declined* to read — a screen transition, which is not a defect
        and whose movie bytes were never going to be read on the recording machine either. Two
        tests hold both halves and both require the old boundary to **fail**, per the standing
        rule that the old wrong answer has to be shown wrong.

        **Two alternatives were tried and measured rather than argued.** Counting frames through
        a blanked screen — which is what a recording emulator that must not hang has to do —
        takes the any% horizon back *down* to 535, so VBA's counter stopped with the screen.
        And the origin has one more degree of freedom: the horizon is periodic in it with period
        4, because `$FF97`, the counter `WalkSpeed`, `PoseJumpStart`, `PoseSpinJump` and
        `StreamDue` all read, is what the offset shifts. Every residue but one puts both runs
        under 1600 frames. `measured_input_offset` is 4.

        **Five scanlines moved four measured constants, and all four were re-measured rather
        than adjusted.** The opening's hold is 320 frames, not 318; its place delay is 1, not 2;
        `movie_origin_delay` is now **0**, because the handover frame is itself standing — the
        `$13`-to-standing transition used to fall on the far side of the boundary, which is why
        the anchor had to be pushed a frame past it. And `opening_move_delay` is **deleted**: it
        read 2 on both runs, which made it look like the game's timing beside the other three,
        and under the correct boundary it is 4 and 1. It was always the two authors' reaction
        time, and the constant was inviting the wrong conclusion.

        **One test was inverted, and that is the best evidence the fix is real.** The residue
        audit carried a caveat that the reference's frame counter smeared — consecutive frames
        showing the same `$FF97`, then skipping — so its *parity on a named frame* was not
        knowable, which is a problem for a port whose walk speed is `(n & 1) + 1`. That was the
        sample point, not the counter. Every step is one now, and the test asserts the opposite
        and says why it changed.

        **The horizon is still finite and the next cause is named.** The any% replay walks into
        a wall at frame ~8005 and is back at the title by 8441. It is not input delivery —
        nothing is misdelivered in the first 8000 frames — so it is a state divergence between
        our Game Boy and VBA's. Finding it needs SameBoy driven by *the movie*, which does not
        exist yet: `tools/sameboy-frames.sh` drives the tester's synthetic Start/A schedule and
        `sameboy.zig` already carries an unresolved note that on two of ten captures our OAM
        puts Samus a few pixels from where SameBoy puts her, papered over with `object_slack`.
        That note and this desync are plausibly the same bug, and neither is proven
  - [x] Track the reachable-frame count as a build-reported number with its own rung in
        `zig build verify`, so a regression that shortens it fails rather than being noticed
        later. Record what stopped the run each time, since that names the next thing to port.

        ***Un-checked 2026-09-01, then built and re-checked the same day.*** The box had claimed
        to be "done as part of the sub-task above, because the horizon is that number". **It is
        not that number, and the two are not measuring the same machine.** `tas horizon` measures
        how long *our Game Boy replay* stays faithful to the published movie — a property of the
        reference emulator, which the port cannot affect. F10's reachable-frame count measures
        how far *the port* survives against that reference. They read 8407 and 372, and neither
        constrained the other. The wrong claim is preserved above rather than deleted because it
        stood for weeks and a future session is likely to make it again.

        **`zig build verify` now has a `reachable` rung:**

            ok    reachable         the port reaches 372 of 899 frames of the any% run (floor 372)
                  stopped by        Samus's position diverged, at frame 372-383
                  the original      at frame 372: 07F3,0784 camera 07B0,0796 pose $05, pad $10

        `oracle.gradeMovie` already returned the same `Report` type `verify` was calling
        `oracle.grade` for, so the rung reuses the comparator rather than adding a second one,
        and the skip paths already existed — no emulator, and no movie in `vendor/tas/`. It costs
        about 1.5 s. The suspicion on record that this was blocked by other steps and would need
        throwaway code was checked against the commits and is not what happened: `7b3ac99` says
        the horizon rung was added "because F10 makes this the progress metric", which is the
        conflation itself and not a deferral.

        **The floor is only a fact about a pinned movie length, which was measured rather than
        assumed.** `perCode` derives the exit channel's resolution from the reference's *length*,
        so the reported frame is the bottom edge of a bucket whose size depends on how much movie
        was asked for. On one unchanged cart: `want` 500 → 371, 600 → 376, 900 → 372, 1200 → 375.
        Four numbers for one port. So `movie_gate_frames` (900) and `movie_gate_floor` (372) are
        two constants that must travel together, a test asserts the coupling, and the floor is a
        bucket's bottom edge — pessimistic by up to `per_code - 1`, which is the safe direction.
        (The four buckets intersect at frames 376-377, which is where the divergence really is.)

        **The rung was falsified before being believed**: raising the floor to 384 makes it print
        `FAIL reachable — the port reaches 372 frames of the any% run, under the floor of 384`.
        Restored afterwards.

        **And building it found a use-after-free that was latent from the day `gradeMovie` was
        written.** The first output was `at frame 372: AAAA,AAAA camera AAAA,AAAA pose $AA` —
        Zig's safety fill. `gradeMovie` did `defer mr.deinit(allocator)`, which frees
        `mr.settled.frames`, while the `Report` it returns aliases that slice; `grade`, the
        segment's equivalent, has always transferred that slice to its report and never freed it.
        Nothing had read `Report.settled` on the movie path before, so nothing noticed.
        `MovieRef.deinitKeepingFrames` now names the ownership rule, and a test builds a report
        with no emulator and asserts the frames are live — it fails against the old code.

        Only the any% run is graded: the 100% run has its own opening and its own boot cell, so
        it is a second reference rather than a second data point. `zig build test` is 3909/3909.
        `zig build verify` still has exactly one FAIL, the segment oracle's frame 124, which has
        its own sub-task

  - [x] **Added 2026-08-31: the crouch, and the two things that were hiding behind it.** The
        first component the published run actually asks for, found by asking the run rather
        than by picking one. `zig build oracle -- movie 64` reported `REACHABLE: 1 frame`
        because the movie presses **Down** at reference frame 1 — and the port had no key for
        it. Three things were in the way, each hiding the next.

        **The vocabulary.** `oracle.Key` was an enum of the *combinations* the segment used —
        `none`, `right`, `left`, `jump`, `right_jump`, `left_jump` — which was honest while the
        port had a walk and a jump and nothing else. Naming every combination of five buttons
        is ten more variants that exist only so a `switch` can be exhaustive. It is a bitset
        now, so from here **"the port has no key for this" means a button the engine does not
        read, never a combination nobody wrote down**. Up and Down join the supported mask, and
        that alone moved the movie's input ceiling from **reference frame 1 to 1370** — the
        run's first B, which is shooting. Pinned by a test, because it is the number this whole
        phase exists to grow and a number that lives only in a comment drifts.

        **The crouch.** `PoseCrouch` is 00:$15F4: four branches in the original's order —
        Right, Left, Down, Up — and the order *is* the behaviour, since Down is only consulted
        when neither direction is held, so Down-and-Right is a turn and not a morph. Each fires
        on the rising edge or on a hold that has lasted eight frames for a direction and
        sixteen for Down or Up, counted in $D022, which the running handler uses as its
        animation timer — one variable, two roles, and the original's. `EnterCrouch` is 00:$1B8B
        for real now and `EnterMorph` (00:$1BA4) inherits the recorded-unhandled stub.

        The trap in this routine is `TryStanding`'s carry convention: **carry set is the
        *failing* case**, so a direction pressed where she cannot stand rolls her into the ball
        rather than standing her up. Reading it the other way round would have produced a
        plausible-looking port that morphs in open rooms. `src/routines.zig` had already pinned
        that on the Game Boy — Step 14's per-routine layer paying for itself on the first
        routine that needed it.

        **And a one-frame input lag the ceiling had been hiding.** With Down representable the
        run still stopped at frame 1, now on *position*. `PublishPad` runs from NMI before the
        poll, so a byte the script sets before frame i is what the pose machine acts on during
        frame **i+1**; the reference's `held[i]` is $FF80 sampled at the commit of frame i,
        which is the byte the game *did* act on. Handing the cart `held[i]` at frame i ran it a
        frame late on every input in the movie. The segment never showed this because both
        machines there are driven by the same *supplied* schedule and the two delays cancel —
        the movie's reference is *observed*, so nothing cancels. Measured rather than argued:
        shifting by one took the count from 1 to 4. `movie_key_lead` names it, the last
        reference frame is dropped because there is no frame after it to take a byte from, and
        a test pins the shape so the next occurrence costs a second instead of a session.

        **Measured: `REACHABLE` 1 → 4 frames, and frame 4 is the morph ball** — pose $05, which
        the run enters two frames after the crouch and the port does not have. The count named
        its own next component, which is the whole point of grading this way. `zig build test`
        3901/3901; the gate's only FAIL is still the segment's position at frame 124

  - [x] ***Added 2026-09-01: the morph ball, and the two things it uncovered.*** `REACHABLE`
        **4 → 216 frames.** Three components landed, and only the first was the one that was
        planned — the other two are defects the reachable-frame count walked into once the ball
        let it get that far.

        **The ball.** `PoseMorph` from 00:$1701, `EnterMorph` from 00:$1BA4, `TryUnmorph` from
        00:$1B2E, and the two-pixel rolling entries `BallRight`/`BallLeft` (00:$1C98 / 00:$1CC9,
        entries into the movers the walk already uses with the speed preset and the facing store
        folded in). On the ground the order is Down, Up, jump, roll, and the order *is* the
        behaviour twice: Down is tested before Up so a spring ball would win a tie, and the roll
        is only reached when none of the three fired, which is why holding Down in the ball does
        not also move her. `EnterMorph` clearing $D033 is the load-bearing store — it is what
        makes the first frame in the ball a roll rather than a bounce — so `!DownSpeed` is a new
        variable, written by `MoveVertical` on any downward move that lands and read by nothing
        else. Pose $06's handler (00:$179F, three instructions and then a fall into the jump
        handler at 00:$17BB) is ported beside it but has **no ledger row**: the observed run
        never dispatches pose $06, so the ledger cannot call that address an instruction
        boundary, and a row it could not verify would be a claim rather than an inventory.

        ***The crouch was missing its jump, and it had been missing it since the crouch landed.***
        00:$1671 sits between the Left branch and the Down branch, and the first port of that
        handler went straight from Left to Down. The published run jumps out of the crouch the
        frame after it unmorphs, so the cost was immediate and large: **120 frames of the 216**.
        Worth recording because of *how* it was missed — the handler was transcribed branch by
        branch in the original's order and one branch was skipped, which is exactly the failure
        a per-branch address citation in the comments is supposed to make visible. It is visible
        now. (The branch is also its own small finding: a direction held makes it a spin jump
        with **no item required**, where `PoseStanding` wants Space Jump for the same thing.)

        ***And the residue audit's headline finding came true, on the frame it predicted.***
        With the crouch's jump in, the run got to reference frame 131 — the first walking frame
        after she lands — and walked **one pixel where the game walked two**. `WalkSpeed` is
        `(!FrameCount & 1) + 1`, the same expression the original evaluates on $FF97 at
        00:$1C25, and the audit had been reporting `FrameCount differs` as its last outstanding
        row since the camera was fixed. **Boot record version 5** carries the counter's phase.
        Every measured row in the audit now reads `same`.

        The seed is not the measured byte. A cart frame graded against a reference frame has to
        take *both* its input and its counter from the same reference frame, and the two grading
        paths disagree about which frame that is: the movie's reference is observed and shifts
        its keys by `movie_key_lead`, the segment drives both machines from one supplied
        schedule and shifts nothing. So `frameCountSeed` carries whichever shift that path's
        keys carry. Measured both ways rather than reasoned, because the reasoning has an
        off-by-one in it whichever way you write it down: **with the shifts crossed the segment
        falls from 124 reachable frames to 60 and the movie from 216 to 128.** Getting that
        backwards is what made the segment's rung look like a regression for twenty minutes.

        **Measured: `REACHABLE` 4 → 128 (the ball and the crouch's jump) → 216 (the counter's
        phase), and frame 216 is pose $08, the falling ball** — the run rolls off a ledge at
        movie frame 548 and the port has no handler for it. The count named its own next
        component again. `zig build test` 3903/3903, `zig build verify` green on every rung
        except the segment's long-standing position defect at frame 124

  - [x] ***Added 2026-09-01: two bugs James found playing the cart, and what they were hiding.***
        `REACHABLE` **216 → 372 frames.** Neither was found by the gate — both came from playing
        `build-out/m2snes.sfc` — and both were the same shape of miss.

        **The ball drew a standing, front-facing Samus who could still roll left and right.**
        The pose machine and the drawing code dispatch through *different* tables in the
        original — 00:$0D4B and 01:$4C1D, both reached by `RST $28` on the pose — so adding a
        pose to one is not adding it to the other. `SamusSpriteId`'s fallback arm carried a
        comment asserting it was unreachable because `HandlePose` would have refused the pose
        first; that stopped being true the moment the ball got a handler, and the comment did not
        notice. The ball's arm is 01:$4C94 and draws poses $05, $06 and $08 from one animation.
        The original's table of eight is two consecutive runs of four, so two bases and an index
        off `!SpinTimer` bits 3-2 reproduce it exactly with no table of ROM bytes to keep.

        **Rolling off a ledge hard locked the game.** Pose $08 had no handler, so the dispatch
        recorded it in `!Unhandled` and did nothing — the fallback working exactly as designed
        and reading, on a cart, as a lock with no input that can recover. Worth stating plainly:
        *every* unimplemented pose is a lock, by construction, and the gate's job is to find them
        before a player does. Here it had already named this one — the reachable-frame count
        stopped at 216 on precisely this pose — and the cart got played first. `PoseBallFall` is
        ported from 00:$124B, with `TryUnmorphInAir` (00:$1BB3) behind its Up branch.

        **Three things had to come with it rather than be left as branches that quietly do
        nothing**, which is the mistake that had already cost the crouch its jump:

        - `!Springboard` — $D062, the other per-frame contact flag beside `!Water`, latched by
          `CollideBottom` from the block's `!BLOCK_SPRING` bit. Three ported branches read it.
        - `!UnmorphGrace` — $D049, the sixteen-frame window an aerial unmorph opens, counted down
          by the main loop at 00:$0556. With it, `PoseFall`'s aerial jump is written out instead
          of being a comment saying the pose it needs does not exist.
        - $D010 is **`!JumpStart`**, not "the bomb's own state" as a comment written the day
          before claimed. Four branches were missing that store, one of them in the crouch's jump
          added the same day.

        **Measured on the cart, not inferred.** At reference frame 226 the port reads pose $08,
        sprite $26, `!Unhandled` still zero: she rolls off the ledge, falls as a ball and lands
        back into the roll. Sprite ids through the roll cycle within $26-$29, so the animation
        runs. `zig build test` 3903/3903, `zig build verify` green except the segment's
        long-standing position defect at frame 124

  - [x] **Grade the non-playable stretches on duration.** Measure each cutscene, transition and
        menu on the Game Boy, measure the port's equivalent, and report the percentage. 2% is
        the tolerance; the measured figure is what gets recorded. A stretch the port does not
        have at all is reported as absent rather than as 0%

        ***Done 2026-09-01.*** `src/duration.zig`, `zig build oracle -- durations [n|all]`, and a
        `durations` rung on the gate. The whole sweep is 27 seconds.

        **The thirteen frames this sub-task was written around are not the transition, and the
        correction is the useful part.** The note below said movie frames 690-702 were the Game
        Boy's figure for the room change at 703. They are not: they are Samus pressed against a
        closed door, which is play, and the resume banner already said the port reproduces them.
        Replayed frame by frame, the change at 703 is *instantaneous* — position goes
        $07F3,$0784 to $03F3,$0484 and the map bank $0F to $0A between two adjacent frames — and
        what the game spends is the **five frames after it** during which she is held. The
        transition's duration is 5, not 13, and no amount of arguing would have got there.

        **What a non-playable stretch is, measured rather than asserted.** There is no flag in
        this game's RAM that says the player is not playing, so three predicates over the trace
        stand in for one, and each is checked against something:

        - *Cutscene* — `tas.findOpening`'s hold: Samus placed, then held in the pose she was
          placed in for 320 frames while the movie presses buttons at her. Both published runs
          give that to the frame, which is what makes it the game's number.
        - *Transition* — two adjacent frames whose map bank or screen cell differ, held until
          her position moves again. **Changes that fall inside one another's hold are one
          stretch**: crossing a boundary leftwards bounces her back over it first, which is two
          room changes and one transition, and counting them separately would say the game did
          two things.
        - *Menu* — a frame the movie holds Start or Select. Those are two of the three bits
          `unsupportedBits` already names, so the port has no key for them and is reported as
          `unrepresentable` rather than as absent: the port was never asked.

        **The LCD was the obvious signal and it is the wrong one.** `tas.zig` has said since
        Step 6 that "Metroid II turns the LCD off during a screen transition", and a blanked
        screen is the game's own statement that nothing is playable — so a `Blank` recorder went
        into the replay loop first. Measured over the any% run to its horizon there are **six
        blanks in 8407 frames**, and they are the title screen, the game starting, and the death
        that ends the run. **No door transition blanks the screen at all.** The recorder stays
        in `tas.Run.blanks` because it is the only clock still running while the frame index is
        frozen, but the transition detector is built on room changes instead.

        **A warp is separated from a scroll by a measurement.** Ten of the sixty stretches move
        her a whole screen or more in one frame; the other transitions are her walking across a
        cell boundary. `measureLongestStep` reports the largest single-frame step in the run that
        is *not* a room change — **eight pixels, at movie frame 463, a fall** — and `warp_step`
        is $100, one whole screen, thirty-two times above it. A test asserts the gap rather than
        trusting the comment.

        **And a wrap the first measurement found.** `measureLongestStep` initially reported 4094
        pixels at frame 6106. Walking right out of column $F the game's own screen byte reads
        $10 for a few frames and then snaps to $00, so a raw position goes $101B to $001D inside
        an unbroken roll. `tas.Room.of` masks the screen byte to the 16x16 grid already; a
        position compared without the same mask disagrees with the room it is in. Both axes are
        now kept modulo the grid with circular distances, and the longest step fell to eight.

        **The port's number comes from the same detector, and that is the point.** `transitions`
        takes a `[]Step` and `snes_trace.zig` already records map, cell and position per frame
        out of a headless Mesen2 run, so neither machine gets a bespoke rule — which matters
        more than usual here, because the whole claim is that two durations are comparable.
        **The port's cell is derived from its position, not from `VarCell`.** That was the first
        version and it reported every scroll as absent: `VarCell` is the room the boot script
        loaded and it does not move when she walks out of it, so it was being compared against a
        Game Boy cell computed from a position. Two detectors asking different questions.

        **Each stretch is anchored just before itself**, at the latest frame a cart can honestly
        be built at — same room, same pose, and `compareWorlds` agreeing on every compared tile,
        which is the criterion the gate already refuses to grade without. Searched *backwards*,
        and constrained to the room the stretch starts in: without that constraint the search
        walks back through the previous transition and settles on the far side of it. At the
        second stretch of the run every candidate inside the 18-frame redraw fails to settle and
        frame 702 — the room she had already left — settles cleanly, which is
        `oracle.pushToStableAnchor`'s own fault arrived at from the other direction.

        **The census, and the numbers as of 2026-09-01.** Sixty stretches to the horizon: 1
        cutscene, 10 warps, 47 scrolls, 2 menu taps. **15 produce a duration on both machines
        and 11 agree inside 2%.** The rest are honest non-answers, each named rather than folded
        into a zero: 11 `diverged` (the port left the run before the stretch began), 25 whose
        world never matched at any candidate anchor, 4 whose room the cart cannot be pointed at,
        1 `absent`, 1 `stuck`, 2 `unrepresentable`, and the opening, which is `before_port`
        because a boot record describes a room with Samus already in it.

        **The four disagreements are the port speaking, and they are new findings.** At movie
        frames 2362 and 3873 the original holds her for **21 frames** crossing a boundary
        leftwards while it draws the incoming screen, and the port crosses in **1**. At 2563 and
        3316 the original holds her for **1** frame and the port holds her for **48** and **47**.
        Both are Phase 0b work and neither was visible to a frame-exact comparator, which stops
        at the first divergence and never reaches the second.

        **At these durations 2% is exactness dressed as a tolerance** — a tenth of a frame on a
        five-frame transition — and it only starts to mean anything on the 320-frame opening,
        where it allows six. Worth stating rather than discovering later.

        **The gate carries two floors, not one.** `gate_compared_floor` (15) and
        `gate_agreeing_floor` (11) move independently: a port that gains a transition it did not
        have raises the first and may lower the second, and one number would let a lost
        comparison hide behind a gained agreement. `census_stretches` (60) is an *equality*
        rather than a floor, because a change in it means the detector changed its mind about
        what a non-playable stretch is, and that is worth looking at in either direction
  - [ ] Reconcile the reference against SameBoy over the frames the movie reaches, so "our
        emulator and the accuracy benchmark agree about this run" is measured rather than
        assumed from the PPU comparison, which covers pixels and not RAM

        ***Deferred to Phase 0b, 2026-09-01, James's call, and left unchecked rather than
        quietly dropped.*** This is the one sub-task in Step 15b that is not a D1 criterion. D1
        asks that the TAS oracle "runs against the GB ROM and produces a reference trace" and
        that "our build is compared against it **for as far as Phase 0a's logic reaches**,
        re-anchored at each handover of control" — all of which holds. What this sub-task buys
        is confidence in the *oracle*, not a closer Phase 0a, and Phase 0a is what is being
        closed.

        **The cost was measured before deferring, not guessed at.** SameBoy's `tester` target —
        the one `tools/sameboy-frames.sh` drives — takes **no input stream** (`--start` is a
        fixed Start/A schedule keyed to a 69905-cycle tick, which `sameboy.testerButtons`
        reproduces) and dumps **no RAM**: one BMP at the end of a run, plus `--sav` for the
        battery. Feeding it a VBM and reading per-frame RAM out of it means patching or linking
        the vendored C emulator and putting that build into the gate — which is the same kind of
        third-party gate dependency F10 deliberately removed on 2026-08-28 when it dropped
        `mgbdis` for our own disassembler.

        **The argument for doing it anyway is real and is recorded here so the deferral is a
        decision rather than a forget.** Three defects in Step 15 were in the *reference* rather
        than the port, and every one of them was unfalsifiable because the reference had no
        ground truth of its own. That is exactly the hole this sub-task closes. What has changed
        since is that the TAS itself now supplies the falsification the address map never had —
        8407 frames of known-good real play, `zig build tas -- any anchors` — so the reference is
        no longer ungraded, only ungraded *against a second implementation*. Phase 0b is where
        that stops being an acceptable gap: the moment enemies and room transitions land, the
        port's disagreements stop being obviously the port's.

        **What the pixel comparison already covers, so the gap is stated exactly**: `ok sameboy
        10 captures match (6 in play), 715 px/frame masked as objects`. Pixels, from power-on,
        on SameBoy's own boot ROM, cycle origins shared. Not RAM, and not under the movie's
        inputs
  - [x] Verify: the reachable-frame count is reported by the gate and is reproducible across two
        runs; the reason the run stops is named in the output rather than left as a bare number

        **Met 2026-09-01.** All three progress numbers are gate-reported and reproduce exactly
        across two consecutive runs:

        | command | run 1 | run 2 |
        |---|---|---|
        | `oracle -- movie 900` | `REACHABLE: 372 frames` | `REACHABLE: 372 frames` |
        | `oracle -- anchored` | `394 of 5174 across 9 of 13` | `394 of 5174 across 9 of 13` |
        | `oracle -- durations all` | `15 compared, 11 inside 2%` | `15 compared, 11 inside 2%` |

        And none of them is a bare number. The gate names the reason each stops:

        ```
        ok    reachable         the port reaches 372 of 899 frames of the any% run (floor 372)
              stopped by        Samus's position diverged, at frame 372-383
              the original      at frame 372: 07F3,0784 camera 07B0,0796 pose $05, pad $10
        ok    anchored          the port plays 394 of 5174 frames across 9 of 13 stretches (floor 394)
              stretch  0        anchor   328,   375 of   392 frames: Samus's position diverged
              ...
              not graded        4 stretch(es) the cart cannot be booted into
        ok    durations         15 of 60 stretches compared, 11 inside 2% (floors 15 and 11)
              scroll     2362  the game boy 21 frames, the port 1
        ```

- [x] **Step 16: Table-driven dispatch survey**

  **Rescoped 2026-09-01.** As written on 2026-08-23 this step was a survey from scratch. Since
  then Step 14's ledger has been doing half of it mechanically and nobody updated the step:
  `ledger.zig` carries a `dispatch_target` evidence kind, `zig build verify` reports **53
  routines found only by watching the game run** — precisely the set a static tool cannot reach,
  because the game arrives at them through `JP HL` — and `Observed.dispatch` marks every ROM
  offset reached through an indirect jump. The `RST $28` inline-jump-table thunk is already
  identified in `ledger.zig`, and two dispatch sites are already ported and documented in ledger
  rows: `HandlePose` (00:$0D4B) and `SamusSpriteId` (01:$4C1D).

  So the sites are found. What is not done is what the ledger was never asked for: the **shape**
  of each table, and the data-versus-rewrite judgement that F4 actually turns on.

  - [x] Enumerate the dispatch sites from `Observed.dispatch` rather than by reading a
        disassembly for them — every offset the emulator reached through an indirect jump,
        grouped by the site that jumped there. This is a query against machinery that already
        exists, and it is the honest form of "survey the ROM": the sites are a fact about the
        run, not a claim about our reading

        **`ledger.Observation.dispatch` could not be grouped, because it only recorded
        destinations.** `ExecRecorder` set a bit at every `JP HL` target and threw away which
        `JP HL` went there — enough to say "this is an entry point", which is what the ledger
        needed, and not enough to say "this belongs to that dispatch". `ledger.Edge` now carries
        the pair, deduplicated, and `Observation.edges` is the survey's input.

        ***And the site is not always the `JP HL`, which is the whole difficulty.*** `RST $28`
        is a thunk at $0028 — `ADD A,A / POP HL / LD E,A / LD D,$00 / ADD HL,DE / LD E,(HL) /
        INC HL / LD D,(HL) / PUSH DE / POP HL / JP HL` — that takes its own return address as the
        table base, so the table is the bytes the *caller* inlined after the `RST`. **Every
        inline dispatch in the game therefore funnels through one `JP HL`.** Grouping by it
        reported exactly what you would expect: **one site, 0:$0033, with nineteen arms**,
        merging the pose machine, the sprite dispatch and the sound driver into a single entry.
        Edges are attributed to the `RST $28` that called the thunk instead, and the thunk's own
        jump is found in the ROM (`ledger.rst28Jump`) rather than written down — the first guess
        at its length was eight bytes, which put the `JP HL` outside the window and is what
        produced the nineteen-arm site.

        `zig build dispatch -- [boot_s] [explore_s] [door_stride]`, the same three knobs as
        `zig build ledger`. The full sweep takes 4.5 seconds
  - [x] Name the sites execution coverage *cannot* have reached, and say why they are absent —
        a dispatch that only fires for an enemy, a boss or a menu is invisible to a 90-second
        explore plus a 12,000-frame movie. Cross-check against the door scripts and the enemy
        header/AI-pointer tables, known from Steps 4 and 14 to exist and the two largest sites in
        the game. **An unreached site is a hole in the survey, and the survey's credibility is in
        listing them rather than in the count**

        `dispatch.unreached`, four layers, each with the mechanical evidence that it exists and
        the reason no run of this repository can have dispatched through it. The report prints
        them *beside* the sites it found rather than under them, and the gate says how many
        there are:

        - **Enemy AI dispatch.** Exists: `offsets.enemy_header_pointers`/`enemy_headers`, an
          11-byte `entity.Header`, four tables over one 255-entry id space, all round-tripping
          byte-for-byte in the gate. Absent because **no enemy is ever spawned** — the
          observation boots, explores on a fixed schedule, and calls the door interpreter on a
          freshly booted machine, and none of those puts a live enemy in a slot. F4 names this
          layer separately for exactly this reason.
        - **Door script opcode dispatch.** Reached, and *not through `JP HL`*: the interpreter
          switches on an opcode byte rather than jumping through a pointer table, so it produces
          no dispatch edge at all. Table-driven in the sense F4 cares about, and already a
          first-class requirement, so it is accounted for there rather than counted here. This
          is worth stating plainly — the largest table-driven layer in the game contributes
          **zero** sites to this survey, and that is correct rather than a miss.
        - **Menu, map and pause dispatch.** Absent because no run opens one: the observation's
          schedule never does, and `duration.zig` measured that neither published run does
          either inside its horizon — the any% run's two Select taps cost one frame each and
          open nothing.
        - **Boss and cutscene sequencing.** No Alpha Metroid, no Queen, no ending

        ***And five unreached sites the survey found anyway, which is the part worth keeping.***
        Bank 4's three observed sites are one family: each loads a table base into HL and
        `CALL $46DE` turns an index into an entry. **Nothing knew that helper existed until a run
        reached one of them** — which is the whole reason a static tool stalls here — but once it
        has, the seven bytes `21 lo hi / CD DE 46 / E9` name every other site in the ROM that
        uses it:

        ```
          site       table      indexer   run reached it
          4:$448E   4:$4EC4   $46DE    yes
          4:$449E   4:$4F00   $46DE    yes
          4:$44B9   4:$55F2   $46DE    NO -- new
          4:$44C9   4:$5600   $46DE    NO -- new
          4:$44FC   4:$56CC   $46DE    yes
          4:$450C   4:$5700   $46DE    NO -- new
          4:$452E   4:$5D3F   $46DE    NO -- new
          4:$453E   4:$5D49   $46DE    NO -- new
        ```

        **Five of eight are sites no schedule this repository runs has ever entered**, and each
        comes with its table address. This is execution coverage bootstrapping a static search:
        the run supplies the shape, the bytes supply the rest, and neither half could have done
        it alone. The gate reports the count
  - [x] For each site record: the table's address, its stride and arity, how the index is
        derived, what transfers as **data** versus what must be **rewritten**, and the estimated
        line reduction. Write it as re-derived facts about the ROM — addresses, table shapes,
        dispatch mechanics — not as transcribed M2RoS label lists, so the survey stands alone

        **Seven sites, six with a table, 223 entries.** Every address below is derived from the
        user's own ROM: the sites from a run, the tables from the bytes. Nothing is transcribed.

        | site | how the table was found | table | arity | arms seen | index |
        |---|---|---|---:|---:|---|
        | 0:$02F2 | inline after `RST $28` | 0:$02F3 | 20 | 7 | `LDH A,($9B)` |
        | 0:$0D4A `HandlePose` | inline after `RST $28` | 0:$0D4B | 31 | 9 | `LD A,($D020)`, the pose byte |
        | 1:$4C1C `SamusSpriteId` | inline after `RST $28` | 1:$4C1D | 30 | 8 | `LD A,($D020)`, the pose byte |
        | 4:$448E | **searched**, from the arms | 4:$4EC4 | 60 | 7 | `LD A,($CEC0)`, guarded `CP $18` |
        | 4:$449E | **searched**, from the arms | 4:$4F00 | 30 | 7 | `LD A,($CEC1)`, guarded `CP $1F` |
        | 4:$44FC | `LD HL,nn` before the site | 4:$56CC | 52 | 1 | `LD A,($CED5)` |
        | 2:$5650 | *none* — HL comes from $FFF1/$FFF2 | — | — | 1 | a computed jump, not a table |

        The last row is the honest negative: 2:$5650 loads HL out of HRAM (`LD BC,$FFF2 /
        LD A,(BC) / LD H,A / DEC C / LD A,(BC) / LD L,A`), so there is no table in the ROM to
        find and the survey says so rather than pointing at whichever bytes happened to fit.

        **A table is found from the bytes, not from a listing.** `locate` searches the site's own
        bank for a run of 16-bit little-endian in-bank pointers, at a fixed 2-byte stride, that
        names *every* arm the run reached — two arms minimum, because one arm's bytes appear all
        over a 16 KiB bank and matching them is a coincidence rather than a finding. The stride
        is a constant with the search built around it rather than a free parameter, for the same
        reason: with two arms and a free stride, almost any pair of bytes can be made to fit.

        ***And the search's answer is checkable against the game's own instruction.*** At
        4:$448E the bytes three instructions earlier are `LD HL,$4EC4`, and the search reaches
        $4EC4 from the arms without ever reading it — **two independent derivations of the same
        address**, which is asserted by a test rather than noticed once. That check is also what
        made the seventh site resolvable: 4:$44FC was entered exactly once, so the search
        declined, but `LD HL,$56CC` sits four bytes before it and explains the one arm. Bank 4's
        three sites are one family — each loads a base into HL and `CALL $46DE` does the
        indexing — which is why the same read works for all three.

        **Arity is bounded three ways and the tightest is quoted.** To the next routine the
        ledger found; to the lowest arm that lies after the table (a table cannot run into the
        code it points at); and how many consecutive entries decode as in-bank addresses. For
        the pose machine those are 173, 173 and **31** — and `ledger.zig` states 27 by hand from
        an earlier reading, so the computed bound lands where the hand-written one already was.
        The report prints all three, because a table whose bounds disagree wildly is one to look
        at rather than one to quote.

        **What transfers as data versus what must be rewritten.** The 223 table entries are
        **data**: 446 bytes of little-endian Game Boy addresses become a SNES pointer table, and
        the dispatcher above each becomes one `JSR (addr,X)`. The arms are **code**. The
        estimate is computed rather than guessed: read every entry of every located table —
        the arms the run took and the ones it did not — and trace statically from each with
        `disasm.trace`, which follows conditionals and falls *through* a `CALL` rather than into
        it, so it counts the arm bodies and their tail-jumps and not the whole call graph
        beneath them.

        **The answer: 7248 of the ledger's 14782 instructions, 49.0%.** That is the ceiling on
        "port the dispatcher, transfer the table" for the layers a run can see. Beside it, the
        number a naive count gives: only **1963 instructions (13.3%)** sit in a routine some
        dispatch was *observed* to jump to — the run took 9 of the pose machine's 31 arms — so
        counting what was seen rather than what is there understates the layer by nearly four
        times. Both are printed, labelled, because the difference between them is the whole
        point of reading the tables
  - [x] Verify: the survey accounts for a stated share of the ~20,000 logic lines with the
        residual named, and reports that share beside the ledger's existing 59% figure so the two
        numbers are read together rather than confused. **A dispatch site the survey lists but
        the ledger has no row for is a discrepancy the verify must print**, since the point of
        pairing them is that neither can quietly disagree with the other

        ```
        ok    dispatch survey   7 sites, 6 with a located table, 223 table entries (floors 5 and 3)
              the F4 share      7248 of 14782 ledger instructions reachable from a table entry: 49.0%
              read together     the ledger's 59% is instructions against ~20000 stated lines; this is
                                dispatch arms against the 14782 instructions the ledger found
              not reached       4 dispatch layer(s) no run of this repository can have seen
        ```

        **The two shares are of different things and the rung says so in the output**, not in a
        comment: the ledger's 59% is instructions against the *stated* ~20,000 lines, the
        survey's 49% is dispatch arms against the instructions the ledger actually found. A
        reader who multiplies them concludes the survey covers a quarter of the game; a reader
        who confuses them concludes it covers half of it. It covers half of what has been
        inventoried.

        **The survey runs on the ledger rung's own observation**, deliberately: the sites and the
        routine boundaries both come from one execution trace, and a second observation would let
        the two silently describe different runs.

        **The cross-check is a failure, not a note.** `arms_without_row` counts dispatch arms
        that fall inside no ledger routine — the two mechanical inventories disagreeing about
        where a body starts — and the rung fails on any. It is 0, and a test asserts that
        independently. Sites that sit in no ledger row are printed as a line rather than a
        failure, since a dispatcher inside an unnamed routine is a gap in the ledger's naming
        rather than a contradiction.

        **The residual, named.** 51% of the inventoried instructions are not behind any dispatch
        this survey found, and four whole layers were never reached at all — enemy AI, the menus,
        the boss sequencing, and the door interpreter, which is table-driven but switches on an
        opcode byte rather than jumping through pointers and so contributes **zero** sites here.
        The largest table-driven layer in the game is invisible to this method, correctly, and
        is F4's own first criterion instead

- [x] **Step 17: Audio — moved out of Phase 0a and stubbed for Phase 0c**

  **Moved 2026-09-01, James's call, and `01-requirements.md` is amended to match** — D1 no
  longer asks for audio, F8 is marked as delivered in Phase 0c, and the Phasing section carries
  0c and what moving it costs. The box is checked because the *decision and the stub* are the
  deliverable here; the work is Phase 0c's.

  **Why it moves.** This step held the single largest piece of unbuilt tooling in the project —
  a Zig emitter for TAD's song binary format, a register-log-to-note-event analyzer, the 65816
  driver port, BRR SFX encoding and an ARAM budget — inside the go/no-go milestone, where it
  gated nothing the milestone was deciding. Phase 0a exists to retire project-killing risk in
  the conversion pipeline and the oracle. Whether ambient tracks auto-transcribe well is a real
  unknown, but its fallback (the documented SPC700 GB-APU shim) is a fallback for *how* audio is
  done, not for whether the port is viable. Nothing else in 0a, 0b or the requirements' four
  unmeasured assumptions depends on the answer.

  **What already exists, so 0c does not start cold.** `src/gb/apu.zig` ships in the builder and
  Step 6 captures the APU register writes; `extracted/audio_handle`, `audio_initialize` and
  `audio_silence` are already pulled from the ROM. The capture half of F8 has its foundation
  laid; the analyzer, the emitter and the driver port are untouched.

  **Phase 0c — stub. Not planned yet.** It gets its own `spec-and-dev` cycle covering F8 end to
  end plus F9's audio A/B: song-init capture at a known address, the register-log analyzer, the
  **Zig TAD song-binary emitter validated byte-for-byte against `tad-compiler`'s output**, the
  65816 TAD API ported or imported from `snes_game_dev`'s `engine/tad.zig`, BRR one-shot SFX,
  the measured ARAM budget with the full-soundtrack extrapolation flagged as an extrapolation,
  A/B WAV rendering, and one track proven by ear.

  **Ordering, so the cycle is not blocked on the wrong thing.** 0b and 0c are independent and
  may run in either order or in parallel. 0b's only audio dependency is the earthquake's music
  interruption path, which D2 now satisfies with a silent stub. **0c must land before Phase 1**,
  which requires every track playing as it does in vanilla.

- [x] **Step 18: Phase 0a gate and Phase 0b input**

  > **Written 2026-09-01. The verdict is GO, and every D1 criterion is now evidenced —
  > including the one nothing here could self-verify.** The hardware pass was run on the
  > console the same day and closed it; three things remain open and all three are open in
  > writing. `zig build verify` is green end to end with no rung retired.

  - [x] Confirm every D1 acceptance criterion in `01-requirements.md` — **re-read it rather than
        working from memory of it**, since D1 was amended on 2026-09-01 to drop audio

        Re-read, not remembered. Each row is the criterion's own wording against the evidence
        that answers it.

        | # | D1 criterion | evidence | verdict |
        |---|---|---|---|
        | 1 | F2 converts every asset class across the full ROM | `ok snes layout 225 KiB converted into 364 KiB reserved`; `ok coverage 189/256 KiB claimed, 17888 items` | **holds, with a stated residual** — see below |
        | 2 | F3's round-trip and render-comparison suites pass across all assets and all ~300 screens | `ok extraction 124 entries reproduce byte-for-byte`; `ok round-trip 122/124 re-encode byte-for-byte (2 raw)`; `ok snes render 904 screens match pixel for pixel`, fault sweep 4/4 | **holds** — and the screen count is 904, not ~300; the estimate was low |
        | 3 | Asset viewer works, including F9's side-by-side graphics A/B at component level across all graphics classes | `zig build inspect` — 60 graphics entries as A/B sheets with a diff channel, per-bank contact sheets over all 904 screens (`0 screens differ`), fault-injected variants beside them. Spot-checked at both ends of the range: `gfx_samusPowerSuit` 176 tiles and `gfx_titleScreen` 160 tiles, **0 pixels differ** each | **holds**; assembled metasprites not built, which F9 marks optional |
        | 4 | Builder runs the whole pipeline end to end from a user-supplied ROM, injecting into the pre-assembled engine image | `ok snes rom 512 KiB cart, 108 blobs placed, identical across two runs` with a printed digest; `ok snes engine 32 KiB image in 128 KiB reserved`, and `engine.bin`/`engine.sym` are what `engine/main.asm` assembles to | **holds** |
        | 5 | Logic inventory ledger is generated and populated | `ok logic ledger 262 routines, 11818 instructions (59% of ~20000)`, with conversion and test columns and 53 routines found only by watching the game run | **holds** |
        | 6 | ROM boots on real hardware (FXPak) and in Mesen2; Samus moves, jumps, and collides | Mesen2: `ok snes boot` — play window, samus, camera, scrolling, input, sprite. FXPak: **2026-09-01, on the current cart** — animations right, crouch and morph work, no lock-up; plus the 2026-08-27 passes across Steps 12, 12a and 13a | **holds** |
        | 7 | TAS oracle runs against the GB ROM and produces a reference trace; our build compared for as far as Phase 0a's logic reaches, re-anchored at each handover | `ok reachable 372 of 899`; `ok anchored 394 of 5174 across 9 of 13 stretches`; `ok durations 15 of 60 compared, 11 inside 2%` | **holds** |
        | 8 | Room test harness can spawn Samus anywhere with an arbitrary loadout | `room.spawn`, twelve tests including "the harness sets the loadout by name, and the game keeps it" and "the two room harnesses agree on where a position is" | **holds** |
        | 9 | Table-driven dispatch survey is complete, with its findings written down | `ok dispatch survey 7 sites, 6 with a located table, 223 table entries`; the F4 share 49.0%; four unreached layers named; five sibling sites found in the bytes. Step 16's write-up is the findings | **holds** |
        | 10 | Audio is not part of this gate (amended 2026-09-01) | Step 17; F8 in its entirety is Phase 0c | **holds** |

        **Criterion 1's residual, named rather than rounded off.** Six asset classes remain
        unread, and `zig build coverage` names each with the step that needs it. Four are owned
        by a later phase by their own note — `enemy_data` and `item_names` (Phase 0b),
        `samus_pose_tables` for the poses Phase 0a does not run (Phase 0b), and audio sequence
        data (Phase 0c with F8). **Two are filed against Phase 0a steps and are still open:**

        - `physics_constants`, filed against Step 13. Most of them genuinely are scattered as
          immediates through bank 0, so there is no class to convert; the three that *are*
          tables — `physics_fallArc`, `physics_jumpArc`, `physics_spaceJumpArc` — were pinned
          and converted as a `physics` blob in Step 13. What is left under this name is the
          immediates, which were re-derived per routine instead. Not a gap in conversion.
        - `title_tilemap`, filed against Step 12. Included in bank 5 with no address comment, so
          it is catalogued as unknown rather than guessed at. The cart draws no title screen —
          Step 15b established that the title-to-game transition is Phase 0b — so nothing in
          Phase 0a consumes it.

        Neither blocks the gate and both are named here so that "every asset class" is read as
        "every class Phase 0a needs, with two catalogued as unknown" rather than as a clean sweep

  - [x] Record measured outcomes for the requirements' unmeasured assumptions: dispatch-survey
        reduction (Step 16) and asset region sizing (Step 8, measured — tightest region is
        `map_screens` at 70%). **Transcription quality and the ARAM budget are not measured
        here** and the assessment must say so in those words: they move to Phase 0c with F8, and
        Phase 0a ships with them open. Reporting an unmeasured assumption as anything other than
        unmeasured is the one way this gate can lie

        | assumption | outcome |
        |---|---|
        | **Dispatch-survey reduction** | **Measured: 49.0%.** 7248 of the ledger's 14782 instructions are statically reachable from an entry of a located dispatch table. Seven sites, six with a table, 223 entries. The naive figure — arms the run was *observed* to take — is 13.3%, and both are printed so the difference is visible rather than chosen |
        | **Asset region sizing** | **Measured: fits, tightest region `map_screens` at 70%.** 225 KiB converted into 364 KiB reserved in a 512 KiB LoROM cart. Per-class headroom is printed by `zig build convert` and by the gate |
        | **Transcription quality** | **NOT MEASURED.** Moves to Phase 0c with F8. Phase 0a ships with it open, and the documented SPC700-shim fallback is still unexercised |
        | **ARAM budget** | **NOT MEASURED.** Moves to Phase 0c with F8. Phase 0a ships with it open |

        The two unmeasured rows are the ones this sub-task exists to keep honest, and they are
        stated in the words the plan asked for. What moving them out of 0a costs is already
        written down in `01-requirements.md`'s Phasing section and is not restated as a finding
        here

  - [x] Write the go/no-go assessment, naming anything that did not hold

        ## Phase 0a: **GO**

        The milestone D1 states is "the entire asset base of the game is converted, verified, and
        inspectable. Not playable as a game." That is met. Every asset class Phase 0a needs
        converts; 124 entries reproduce byte-for-byte and 122 re-encode byte-for-byte; all 904
        screens render pixel-for-pixel against the Game Boy, with a fault sweep that catches
        4/4 injected faults; every graphics class is inspectable side by side with a diff
        channel; the builder runs end to end from James's own ROM into a committed engine image
        and produces the same 512 KiB cart twice; and the cart boots, in Mesen2 and on the
        FXPak, with Samus walking, jumping, crouching, rolling, falling and colliding.

        The two go/no-go risks Phase 0a existed to retire are retired with numbers rather than
        with judgement: **region sizing fits at 70% in the tightest class**, and **the
        dispatch layer accounts for 49% of the inventoried logic**.

        ### What did not hold, or holds with something open

        1. ~~**The hardware pass is four days old.**~~ ***Closed 2026-09-01, on the console.***
           The cart that the gate signed off — `build-out/m2snes.sfc`, sha256 `bfbc75f4…24a5ec`,
           checked against the digest the `snes rom` rung printed so that a fault-sweep leftover
           could not be deployed by mistake — was pushed to the FXPak Pro over USB via SNI and
           booted from the SD card. **James, at the console: all animations look right and work;
           crouch works; morph works; and the game does not lock up.**

           That is D1 criterion 6 met against the *current* cart rather than against the
           2026-08-27 one, and it covers the three things no earlier hardware pass could have:
           the crouch, the morph ball, and boot record versions 5-7. **The lock-up specifically
           did not happen**, which is the pose $08 result — rolling off a ledge was a hard lock
           on the console before Step 15b implemented it, and the ledger's `PoseMorph` note
           records that the dispatch's recorded-and-do-nothing fallback was what caused it.

           One defect reproduced, and it is the one already tracked rather than a new one: see
           item 3.
        2. **The SameBoy reconciliation is deferred, on the record.** Step 15b's last sub-task —
           grading our emulator's RAM against the accuracy benchmark over the frames the movie
           reaches — is not a D1 criterion and is not done. Its cost was measured before
           deferring (SameBoy's tester takes no input stream and dumps no RAM, so it means
           patching the vendored C emulator and putting that build in the gate), and the
           argument *for* doing it is recorded beside the deferral: three defects in Step 15
           were in the reference rather than the port. It moves to Phase 0b.
        3. **An open behaviour defect, which is Phase 0b's — and it is now confirmed on
           hardware.** `docs/bug_tracker.md`: entering the morph ball in midair, she bounces on
           landing and then unmorphs, where the original keeps her morphed until Up is pressed.
           Found by James playing the cart on 2026-08-31, and **reproduced on the FXPak on
           2026-09-01** in the hardware pass above — she lands, settles after the initial
           bounce, and unmorphs.

           Not a Phase 0a criterion: D1 asks that Samus moves, jumps and collides, and she does.
           It is Phase 0b's opening work, and it is now a defect with a console reproduction
           rather than a single sighting.
        4. **A licensing discrepancy the requirements have not caught up with.**
           `01-requirements.md` still says "M2RoS ships no LICENSE file, so it is
           all-rights-reserved by default", with the licence answer listed as an **outstanding
           external dependency**. James stated on 2026-08-24 that M2RoS is MIT licensed. If that
           is right, the outstanding dependency is closed and the wording should be amended;
           this assessment asserts neither, because getting a legal posture wrong in either
           direction is worse than flagging it. **Action: confirm, and amend the requirements
           either way.**

        ### What Phase 0b gets from this

        - **The porting loop's stop condition, with the next component named.** The reachable
          count stops at movie frame 703 on a **room transition**, and the thirteen frames before
          it are already reproduced — the geometry into the door is right and only the transition
          is missing, which is a far smaller gap than "the port has no rooms".
        - **Two duration defects a frame-exact comparator cannot see.** The port crosses a screen
          boundary leftwards in 1 frame where the original holds Samus for 21 while it draws the
          incoming screen; at two other boundaries it holds her for 47-48 where the original
          holds 1.
        - **Five dispatch sites nobody has run**, each with its table address, found by the shape
          a reached site taught the survey.
        - **The title-to-game transition and pose $13's 320-frame sequence**, which Step 15b
          measured as what stands between the cart and the movie's frame 0.
        - **Three anchors the cart cannot be booted into**, from `zig build oracle -- settle`, and
          25 duration stretches whose world never matched — both lists of rooms whose assignment
          or conversion wants a second look.

  - [x] Verify: `zig build verify` green end to end — round-trip, render comparison,
        determinism, boot test, the reachable-frame rung, and the segment oracle **or** a written
        record that the segment rung was deliberately retired, per Step 15b's fix-or-retire
        sub-task. A gate that is green because a failing rung was quietly deleted is worse than a
        red one, so whichever way that lands, it lands in writing

        **Green, 2026-09-01: `Build Summary: 101/101 steps succeeded; 4245/4245 tests passed`,
        exit 0. And no rung was retired** — the segment oracle is still there and still passing,
        which is the outcome the fix-or-retire sub-task hoped for and did not assume. All
        twenty-three rungs:

        ```
        ok    ROM revision      Metroid II - Return of Samus (World) [GB, 256 KiB]
        ok    offset shapes     27 checks over 124 entries (2 still unpinned)
        ok    map/door/sprite   904/905 screens reached (1 null), 1872 door ops round-trip, 308 metasprites
        ok    extraction        124 entries reproduce byte-for-byte (0 deferred to Step 4)
        ok    round-trip        122/124 entries re-encode byte-for-byte (184 KiB, 2 raw)
        ok    coverage          189/256 KiB claimed, 17888 items, 6 classes unread
        ok    frames            904 screens render reproducibly, 05c95b96439a951f
        ok    emulator          600 frames reproduce, 8M instructions, bank 4, 4725/8192 VRAM
        ok    logic ledger      262 routines, 11818 instructions (59% of the stated ~20000 lines)
        ok    dispatch survey   7 sites, 6 with a located table, 223 table entries (floors 5 and 3)
              the F4 share      7248 of 14782 ledger instructions reachable from a table entry: 49.0%
              not reached       4 dispatch layer(s) no run of this repository can have seen
              same shape        5 of 8 sites sharing an observed indexer were never entered by any run
        ok    tas horizon       any% still the published run at frame 8407 (floor 8400)
        ok    tas horizon       100% still the published run at frame 4566 (floor 4560)
        ok    sameboy           10 captures match (6 in play), 715 px/frame masked as objects
        ok    snes layout       225 KiB converted into 364 KiB reserved, lorom cart 512 KiB
        ok    snes render       904 screens match the Game Boy reference pixel for pixel
        ok    snes engine       32 KiB image in 128 KiB reserved, patch table at $00FF00
        ok    snes rom          512 KiB cart, 108 blobs placed, identical across two runs
        ok    snes boot         the cart draws map 0 cell $38 pixel for pixel in Mesen2
        ok    oracle            320 frames of the original, frame for frame, on map 0 cell $38
        ok    reachable         the port reaches 372 of 899 frames of the any% run (floor 372)
        ok    anchored          the port plays 394 of 5174 frames across 9 of 13 stretches (floor 394)
        ok    durations         15 of 60 stretches compared, 11 inside 2% (floors 15 and 11)
        ok    file policy       82 committable files, 1934 KiB scanned, including the ROM n-gram scan
        ```

        **Determinism, round-trip and the render comparison are each their own rung**, which is
        what the sub-task asked to see rather than a single green light: `snes rom ... identical
        across two runs`, `round-trip 122/124 ... byte-for-byte`, `snes render 904 screens ...
        pixel for pixel` with a 4/4 fault sweep behind it

## Phase 0b — stub

**Not planned yet.** Phase 0b delivers the playable slice (D2 in `01-requirements.md`):
landing site through the second Alpha Metroid, exercising the full Metroid progression chain,
manually playable on hardware.

It gets its own `spec-and-dev` cycle once Phase 0a lands, because these Phase 0a outputs
determine how it should be planned:

- **Step 16's dispatch survey** — how much of the ~20,000 logic lines collapses into "port the
  dispatcher, transfer the table" rather than being rewritten routine by routine. This is the
  single largest unknown in sizing 0b.
- **Step 8's region sizing** — whether the pre-assembled image's reserved asset regions hold
  the full converted set, or whether the layout needs rework before more code lands.
- **Step 14's ledger** — the concrete routine backlog for the slice, with real counts rather
  than estimates.
- ~~**Step 17's transcription quality**~~ — **no longer an input, as of 2026-09-01.** F8 moved to
  Phase 0c, which is independent of 0b: D2's earthquake criterion is satisfied by a silent stub,
  so 0b can be planned and built without knowing whether the audio approach holds.
- **Step 18's go/no-go** — anything that did not hold, which may reopen requirements.

Planning 0b before those exist would be guessing at the four that remain.

### Phase 0b's opening step, carried over intact

**Added 2026-09-01**, lifted verbatim out of Step 15b because its stop condition was met there
and its next turn needs room transitions. This is the procedure Phase 0a used to grow the
reachable-frame count from 1 to 372, and it is how 0b grows it further. It is recorded here so
the 0b cycle inherits a working method rather than re-deriving one.

- **The porting loop: let the reachable-frame count name the next component, and keep
  going.** Added 2026-09-01 because it was the only part of this step that was never
  written down — every increment so far was recorded after the fact and a fresh session
  had nothing telling it what to do next.

  This was the standing work of Step 15b and is F10's build order made operational. One turn
  of it:

  1. `zig build oracle -- movie 900` and read where it stops. The reported frame is a
     bucket; the exact frame is worth pinning, and the cheap way is to copy
     `build-out/oracle.lua`, replace the position `emu.stop(CODE_POS + ...)` with
     `emu.stop(20 + (i % 200))`, and run `$MESEN build-out/oracle.sfc --testrunner <copy>
     --timeout=120`. Lua's index is 1-based, so reference frame = exit − 21 and movie
     frame = reference frame + 326.
  2. Read `extracted/tas/any-vblank0-trace.tsv` around that movie frame. The pose column
     usually names the component outright.
  3. Disassemble it — `zig build disasm -- <bank> <start> <end>` — and port it branch for
     branch, in the original's order, with the address of each branch in the comment. **Do
     not skip a branch because it cannot fire in Phase 0a.** Two of the three defects this
     step has cost came from exactly that: the crouch lost its jump at 00:$1671 and was
     120 frames short for a day, and `$D062`/`$D049`/`$D010` were nearly left unmodelled
     under three branches that would then have silently done nothing.
  4. A new pose needs **two** dispatches, not one: `HandlePose` and `SamusSpriteId`. They
     are separate tables in the original (00:$0D4B and 01:$4C1D) and Step 15b's "make the gate
     say why it stopped" sub-task adds the test that says so.
  5. Add a `ledger.zig` row for each routine — and if `zig build verify` says the address
     "is no longer an instruction boundary", the observed run never dispatches it, so drop
     the row and fold its note into the caller's rather than weakening the check.
  6. Update `residue.zig` for any new variable, re-run `zig build test` and
     `zig build verify`, and record the increment here with the before and after count.

  **Where it stops now, and why this one is different.** Reference frame 377, movie frame
  703: the map bank goes $0F to $0A and Samus is in another room. That is a **room
  transition**, not a pose — the first thing the count has named that is not a routine to
  transcribe but a whole mechanism, and it is D1's Phase 0b. So this loop has run out of
  cheap turns, and the two Step 15b sub-tasks that carry the count past it are **"grade the
  non-playable stretches on duration"** and **"re-anchor"**: a transition is a non-playable
  stretch, and the far side of one is a handover to anchor on.

  **Stop condition, so it is not open-ended:** one *pass* of the loop is done when the count
  stops on something that is not a pose handler. Phase 0a's pass met that on 2026-09-01. In
  Phase 0b the same condition applies per mechanism rather than per pose.

**What the 0b cycle must add to it**, since the loop as written only knows how to port a pose
handler: the next stop is a room transition, so the loop needs a second arm for mechanisms —
door scripts, the map-bank change, and the camera's re-seat on the far side. That design is the
0b cycle's work, not a carry-over.

### Also carried into Phase 0b

**Moved out of Step 15 on 2026-09-01**, for the same reason as the porting loop: it was written
as deferred-to-0b and left unchecked, which made a nearly-finished step look unfinishable.

- **Saves cannot be tested by watching a TAS, and James named the shape of the test that
  would work (2026-08-30).** A tool-assisted run only visits a save station when saving is
  faster than not, and neither published run does. So the save path needs driving
  deliberately: spawn Samus with one unit of energy, walk her to a save station, let
  something damage her, and assert the state the game loads is the state the record said
  it would be. That is a `room.zig` scenario rather than a movie, and it is written down
  here rather than done because Phase 0a's cart has no save station, no enemies and no
  damage — **deferred to Phase 0b, where all three exist.** `src/save.zig` already decodes
  the record the test would assert against

