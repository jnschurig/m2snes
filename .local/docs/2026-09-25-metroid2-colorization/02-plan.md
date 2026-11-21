---
created: 2026-11-21T04:58:35Z
updated:
  - 2026-11-21T04:58:35Z
  - 2026-11-21T05:00:42Z
  - 2026-11-21T05:06:10Z
  - 2026-11-21T05:24:48Z
working_directory: /Users/james/git/m2snes
---

# Implementation Plan

## Status: Final

## Overview

Mirror EJRTQ's model, with our own data (Step 2's findings, in
`docs/colorization.md`):
- **one palette slot per source graphics tile** (bank, address) in the
  original ROM, shared by sprites and background;
- in the cart, a **384-entry table per Game Boy VRAM tile** (`$8000-$97FF`),
  filled by every graphics copy, as EJRTQ's `$D200-$D37F` is;
- tilemap writers look up each tile's slot with LCDC's signed addressing,
  and sprites with unsigned addressing;
- the per-sprite rules: the OBP1 swap (3 → 1, anything else → 3), and frozen
  enemies (`iceCounter` ≠ 0) → slot 3;
- overrides per original tile id for the HUD and the Queen area, where EJRTQ
  changed tile ids;
- **per-area colour sets** in place of EJRTQ's colours, with the Queen's room
  as its own area. Fades and flashes stay the DMG-register remap within each
  slot, as in `gbc`.

The oracle extracts EJRTQ's tables statically from the patched ROM and
checks them against the game running. It writes Zig data we commit. In
`mono`/`gbc` every slot is zero, so those schemes draw exactly as today.

**Decisions (2026-11-21, after Step 2):**
- The port keeps the original art. EJRTQ's 252 edited tiles are not used.
  Samus, the Metroids and the credits get an eye check in Step 9.
- HUD and Queen-area tile-id edits: the oracle derives a slot per original
  id there, and reports conflicts. Hand-picked overrides go in the committed
  data.
- Fades: keep the register remap. Colour 3 is each slot's darkest colour,
  and a data test checks it.
- The Queen's room is its own colour area.

**Validation (F1, amended 2026-11-21):** the recording can't be replayed on
the patched ROM. Every `.mmo` part starts from a savestate of the original ROM
in DMG/SGB mode, and the patched ROM is CGB-only. So the oracle validates in
two other ways:
- it replays the recording on the **original** ROM in Mesen (as
  `gb_trace`/`worlds` already do) to record the keys and the visible tile and
  sprite ids per frame, for coverage;
- it spot-checks the static model against the **patched** ROM in SameBoy
  (CGB), booted fresh and from save files in each area, comparing VRAM
  bank 1 and OAM palettes.

**Commits:** every step from Step 3 on ends with a commit on the branch.

## Steps

- [x] **Step 1: Branch**
  - [x] `git switch main && git pull && git switch -c colorization-full`.

- [x] **Step 2: Reverse-engineer EJRTQ's model (no code committed yet)**
  - [x] Account for every IPS range: code, tables, colours, fill. Classify the
        edits to original banks 0/3/5-8 as hooks or tile-graphics edits.
  - [x] Identify `[$D065]` (and `$D064`, `$D44x`) and every path that
        reloads the attribute tables: room load, area/tileset change, title,
        credits, game over, Queen, the pause screen.
  - [x] **Map each key to cart state:** name the port's WRAM variable (or
        derivation) that equals `[$D065]` at every reload path, and say when
        the key changes mid-screen (scroll, door, cutscene) and what the cart
        must do then.
  - [x] **Sprite table:** settle whether `$10:418C`'s `$D200` read uses the
        BG table, a table swapped in for the OAM pass, or a separate one.
        Record the sprite data shape Step 3 generates (separate table, shared
        table, or a VRAM-region split by tile id).
  - [x] Find how EJRTQ handles BGP/OBP0/OBP1 writes: flashes, fades, the
        title flash, frozen enemies, Varia. The working assumption is "the
        DMG register remaps the shades within every slot", the same as
        Phase 0's `colors.apply`. Confirm it or replace it.
  - [x] **Per-sprite slot changes:** list any effect (frozen enemies,
        blinking drops, damage) that changes a sprite's palette slot rather
        than OBP0/OBP1, with its trigger. Step 7 implements each.
  - [x] List the attribute bits EJRTQ uses (palette, bank, flip, priority).
        Raise any use of VRAM bank 1 tiles (EJRTQ art, which we can't use) or
        flips.
  - [x] Count the distinct BG and OBJ slots per table, and check that colour
        0 is never relied on as non-black.
  - [x] Write the findings into `docs/colorization.md` (addresses and
        mechanism only, no colour values). Every claim cites an address.

- [x] **Step 3: The EJRTQ oracle — extraction (`zig build ejrtq`)**
  - [x] `src/ips.zig`: IPS apply (including RLE records) and the pinned SHA-1
        check. Make `gb_trace.zipEntry` `pub` and read the zip with it. Unit
        tests on a hand-built IPS.
  - [x] `src/ejrtq.zig`: statically read the slot of every source tile in
        the graphics regions of banks 5-8 (`offsets.zig`'s `graphics_*`),
        from the tile's first byte in bank `$20+N`. Compute the look-alike
        classes by comparing EJRTQ's colours in memory only.
  - [x] Tile-id edits: from EJRTQ's `hudBaseTilemap` and Queen-area screens
        and metatiles, derive a slot per position, then per **original** tile
        id there. Report each original id that gets more than one slot.
        Overrides go in a hand-edited section that regeneration keeps.
  - [x] Generate `src/full_assign.zig`: slots per source tile (keyed by
        `offsets.zig` region name and tile index, not ROM bytes), the HUD and
        Queen overrides, the OBP1 rule, the frozen rule, look-alike classes.
        A `check` mode diffs it against the committed file. (Unobserved
        entries need the recording's coverage: moved to Step 5.)
  - [x] A unit test fails if the generated text contains any 16-bit value
        from EJRTQ's colour block (the oracle checks its own output).
  - [x] Verify: `zig build ejrtq` writes the file, `zig build ejrtq --
        check` passes, and `zig build test` is green. `src/policy.zig` passes
        on the new file.
  - [x] Commit: "full: EJRTQ extraction and assignment tables".

- [ ] **Step 4: Area map and pairing**
  - [ ] Model: area = f(map bank, screen), with the Queen's room as its own
        area (the cart can also key it on `$D08B = $11`, the room mode the
        port already mirrors). Commit `src/areas.zig` as seed
        screens per area plus boundary cuts, flood-filled over the world's
        screen connectivity (the crawl's), so it doesn't hand-list ~1,800
        screens.
  - [ ] Builder: generate the per-screen area table into the cart at build
        time from `areas.zig` + the ROM, like the other ROM-derived cart
        data. It is never committed.
  - [ ] `zig build areas`: render each map bank with the area overlay to
        `build-out/` (ROM-derived, never committed), for comparison with
        `metroid-2-areas.gif`.
  - [ ] Unit tests: every reachable screen has exactly one area, and the
        shafts between areas fall where the GIF puts them. The flood fill
        has a ROM-free test on a synthetic grid.
  - [ ] Propose the M2 → Samus Returns pairing, with one representative
        colour per area. **Checkpoint: James approves.**
  - [ ] Commit: "full: area map".

- [ ] **Step 5: The EJRTQ oracle — validation and coverage**
  - [ ] Mesen pass over `reference/metroid2-100p-recording/` on the original
        ROM (reusing `gb_trace`'s Lua driver and cart-RAM channel). Per
        frame, record which source tiles are in VRAM and visible (BG tile ids
        through the copies that loaded them, OAM tile ids plus OBP1 bits).
        Report the source tiles that are never seen, and mark them in
        `full_assign.zig` as unobserved (from Step 3: the static read gives
        every tile a slot, so only coverage can say which went unseen).
  - [ ] SameBoy CGB on the patched ROM, reusing `gbc_oracle_run`/`sbref.c`:
        boot to the title and the landing site, then boot from a save file in
        each area from Step 4 (the save records `save.zig` writes). Compare
        VRAM bank 1 and OAM palettes with the static model at each state.
  - [ ] Verify: zero mismatches. Any mismatch either revises the model
        (Step 2) or is listed in `docs/colorization.md` with its cause.
  - [ ] Commit: "full: EJRTQ oracle validation and coverage".

- [ ] **Step 6: Per-tile BG and window palettes in the engine**
  - [ ] WRAM: a 384-byte slot table per Game Boy VRAM tile (`$8000-$97FF`).
        Every graphics copy writes its source tiles' slots: `LoadGraphics`
        and its `GfxInfo` rows, the title and credits loaders, door loads,
        and the `GfxXferNmi` queue. The builder emits per-source slot data
        beside the converted CHR. `mono`/`gbc` write zeros.
  - [ ] Every BG3 writer looks up the slot through signed addressing (ids
        `$80-$FF` → VRAM tile `$80+`, `$00-$7F` → `$100+`) and ORs `slot<<10`
        into the word: `BuildTilemap`,
        `BlockWrite4`, the Queen writers, credits, the title, game over, and
        any writer found by searching for `!PLAY_PRI`/`BG3_MAP`. Check the
        cost of the `BuildTilemap` inner loop against the frame budget.
  - [ ] HUD: BG2 words take their slot from the same table, with the HUD
        overrides from `full_assign.zig`. Audit CGRAM
        `$20-$6F` first (BG1's room readout and anything else), then move the
        HUD's 4bpp palettes off `$10-$1F` (BG3 slots 4-7) to free palettes
        there.
  - [ ] Zig side: `snes_target.playWord`/`titleWord`/`windowWord` and their
        decoders accept a slot. Graders and `SampleTile` ignore the palette
        bits. ROM-free unit tests round-trip each encoder/decoder with
        non-zero slots.
  - [ ] Verify: `zig build verify` green in `gbc`, with the boot screenshots
        byte-identical to before.
  - [ ] Commit: "full: per-tile BG and window palettes".

- [ ] **Step 7: Per-sprite OBJ palettes**
  - [ ] OAM conversion (`PutObject` and friends) takes the palette from the
        VRAM tile table (unsigned addressing) and applies the OBP1 swap: slot
        3 → 1, anything else → 3. `mono`/`gbc` keep today's 0/1 mapping.
  - [ ] Frozen enemies: an enemy whose `iceCounter` (+$0B) is non-zero draws
        in slot 3 (EJRTQ `01:7B87`), and the OBP1 swap doesn't override it.
  - [ ] Verify: `zig build verify` green, and the object screenshots are
        unchanged in `gbc`.
  - [ ] Commit: "full: per-sprite palettes".

- [ ] **Step 8: The `full` scheme — CGRAM, the L cycle and the badge**
  - [ ] `colors.zig`: `full = 2`. Its data shape: per area, 8 BG slots × 4
        colours; global OBJ slots, with Samus in Samus Returns' Power and
        Varia colours; window slots. `cgramWords` grows to a full CGRAM image
        per (area, BGP, OBP0, OBP1). ROM-free unit tests on synthetic tables
        cover the image builder, including a mid-fade register value.
  - [ ] Engine: rebuild CGRAM in vblank on BGP/OBP writes (the remap within
        each slot, as `gbc` does) and on area change. The area comes from Step 4's generated
        per-screen table in cart.
  - [ ] L cycles three schemes, with the badge glyphs for `FULL`. An older
        cart reading id 2 already falls back.
  - [ ] Placeholder colours: distinct hues per area. Real colours come in
        Step 9.
  - [ ] Verify: `zig build verify` green, and a scenario boot in `full`
        (through the SRAM scheme byte, not WRAM pokes) shows non-palette-0
        words.
  - [ ] Commit: "full: scheme, CGRAM and L cycle".

- [ ] **Step 9: Samus Returns colours**
  - [ ] Pick per-area colours by eye from the reference screenshots, for each
        area's used slots (and the Queen's room); keep look-alike slots
        equal, colour 0 black and colour 3 darkest. Check Samus, the
        Metroids and the credits by eye on the original art.
  - [ ] Publish a swatch sheet: area, Samus Returns pairing, and a Mesen
        screenshot per area. **Checkpoint: James approves; tuning is
        data-only.**
  - [ ] Commit: "full: Samus Returns colours".

- [ ] **Step 10: Gate rungs**
  - [ ] Assignment rung: at the gate's states in `full` (title, landing site,
        one room per area, a Metroid fight, the Queen, the credits), each
        visible BG3/BG2 word's palette and each object's palette equal
        `full_assign.zig` + the area table.
  - [ ] Colour rung: CGRAM equals the area's tables after the DMG registers
        are applied, at those states plus one mid-fade state (a door
        transition or the title fade), checked against the full-brightness
        state either side of it.
  - [ ] Data unit tests: look-alike slots equal, colour 0 black, colour 3
        darkest in every slot, every room
        has an area, every area is paired and complete, no `Fatal` magenta in
        colour 0.
  - [ ] Fault checks: all-slot-0, the wrong area's tables, and a broken
        look-alike class each fail.
  - [ ] `zig build verify` and `verify-full` green, then `zig build repin`
        with the reason.
  - [ ] Commit: "full: gate rungs".

- [ ] **Step 11: Docs, playtest, PR**
  - [ ] README playing section, `docs/feature_tracker.md`,
        `docs/colorization.md` (how to run the oracle: patch hash, where the
        recording goes), and a THIRD-PARTY-NOTICES credit for EJRTQ.
  - [ ] FXPak playtest per F6 (use the `fxpak` skill), with named fail
        symptoms. Also scroll through a shaft between two areas and judge
        the area-change swap (neighbour tiles shown in the current area's
        colours until it happens). James signs off.
  - [ ] Open the PR to main.
