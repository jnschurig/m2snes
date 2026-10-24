---
created: 2026-10-08T20:40:00Z
updated:
  - 2026-10-08T20:40:00Z
  - 2026-10-12T01:38:51Z
  - 2026-10-12T02:29:18Z
  - 2026-10-14T14:59:17Z
  - 2026-10-14T19:16:28Z
  - 2026-10-24T01:31:03Z
  - 2026-10-24T02:23:17Z
  - 2026-10-24T03:12:25Z
  - 2026-10-24T04:43:43Z
  - 2026-10-24T19:54:20Z
working_directory: /Users/james/git/m2snes
---

# Implementation Plan

## Status: Final

## Overview

The colour values live in one Zig module (`src/colors.zig`). The builder
patches every scheme's CGRAM words into a table in the cart, the same way
`BootPalette` is patched today. The engine keeps the active scheme in WRAM
and loads it at reset, on the title, and from NMI when L or the slot changes.
Steps are ordered so the gate stays green throughout:
- the HUD moves to its own palette slot while everything is still grey;
- the graders learn to read colour before the cart shows any;
- the default flips to `gbc` only after both.

SRAM, the L handling and the badge come last.

**What the code says (found in design):**
- CGRAM is written in three places: `LoadPalette`, called once from `Reset`;
  `UploadTitleArt` (palette 7); and `Fatal`. (`ClearVideoMemory` also zeroes
  it at reset, before `LoadPalette`.) Game over reaches the title
  through `Reboot` → `Reset`, which clears WRAM, so the title re-reads SRAM
  every time. Debug warps don't reset, so the scheme in WRAM survives them.
  The credits write no CGRAM.
- The HUD's BG2 map words are written with a zero high byte (palette 0) in
  these places:
  - `HudPut` / `LoadHud`, which carry the base row, the save text and the
    bar;
  - `ItemNameUpload`;
  - `UpdateStatusBar` (the digits);
  - `HudBaseNmi`;
  - `QueenDrawHead`;
  - `ClearWindowMap`;
  - on the Zig side, `snes_target.windowWord` and `windowIdFromWord`.
- Six copies of Lua `shade(px)` classify by red channel thresholds
  (`snes_romtest` ×2, `warp_grade` ×2, `queen_oracle`, and more). Under
  `gbc`, `$7E8C` has red 99, so it would read as shade 2, not 1. They have
  to change before the default flips.
- SRAM mirrors the Game Boy's layout: slots `$000-$0BF`, the counter at
  `$0C0`, credits text from `$0800`, spawn flags `$1000-$15FF`. Free space:
  `$0C1-$07FF` and `$1600-$1FFF`.
- "Slot holds a saved file" is the game's own (broken) magic walk in
  `TitleStart`. The scheme logic uses the same walk, so it always agrees with
  what Start will do.
- The full SameBoy core is already linked into `verify` when
  `vendor/sameboy` is present (`addSameBoyApu`, `src/sbref.c`), and
  `vendor/sameboy/build/bin/tester/cgb_boot.bin` exists.

**Grading (F5, as amended):** graders map colour → shade through one map
per scheme, built from all of its layers. The Step 1 uniqueness test is the
tripwire for `full`.

## Steps

- [x] **Step 1: Branch, and the scheme data in Zig**
  - [x] `git switch -c color-schemes` from up-to-date main, carrying the
        `.local` changes. Leave `mise.lock` alone; it isn't ours.
  - [x] New `src/colors.zig`:
    - `Scheme` enum with stable ids: `mono = 0`, `gbc = 1`. The ids are what
      SRAM stores, so they never change meaning.
    - `default_scheme = .gbc`.
    - Per scheme, four tables of four colours each (`bg`, `window`, `obp0`,
      `obp1`).
    - `cgramWords(scheme) [16]u16`, which applies `screens.live_bgp/obp0/obp1`
      as `snes_screen.palette` does.
    - The `gbc` tables cite `cgb_boot.asm`'s `Palettes` 28/25/3 and
      combination 46.
  - [x] Make `snes_screen.grey`/`palette` the `mono` scheme's source, so
        `mono`'s words are byte-identical to today's.
  - [x] Unit tests:
    - `mono` equals today's greys;
    - `gbc` equals the requirement table, including the worked CGRAM values
      in F1;
    - within each scheme, every colour maps to exactly one shade;
    - no scheme puts `$7C1F` (the `Fatal` magenta) in colour 0;
    - `default_scheme` is a valid id.
  - [x] Verify: `zig build test`. No cart change yet, so the pins are
        untouched.
  - [x] Commit on the branch: "colour schemes: scheme data in Zig".

- [x] **Step 2: Oracle — SameBoy in GBC mode (F4)**
  - [x] `src/sbref.c`: `sbref_cgb_palettes(rom, rom_len, boot, boot_len,
        bg_out[32], obj_out[32])`. It does `GB_init(GB_MODEL_CGB_E)`, loads
        the boot ROM and the ROM from buffers, runs until the boot ROM hands
        over (PC = `$0100`, with a frame cap), then copies BG and OBJ palette
        RAM through `GB_get_direct_access`.
  - [x] Zig wrapper in `src/gb/sameboy.zig`, using `tester/cgb_boot.bin`.
        Skip reasons: `no_rom`, `no_boot_rom`, and no SameBoy build
        (`have_sameboy`).
  - [x] Rung `gbc palettes`:
    - SameBoy's BG palette 0 equals `colors.gbc.bg`;
    - OBJ palette 0 equals `obp0`, and OBJ palette 1 equals `obp1`;
    - fault check: `mono`'s tables fail it.
  - [x] Verify: `zig build verify` shows the rung passing with `M2_ROM` set
        and skipping cleanly with it unset.
  - [x] Commit: "colour schemes: SameBoy GBC palette oracle".
  - Done as: the wrapper is `src/gbc_oracle_run.zig` (links SameBoy) with the
    grade in `src/gbc_oracle.zig` (unit-tested), following the
    `audio_level`/`audio_level_run` split; `sameboy.zig` stays link-free.
    SameBoy's Core now builds with `-fno-sanitize=undefined`, as SameBoy
    builds itself: its CPU's signed shifts trapped UBSan once a ROM ran.
    With `M2_ROM` unset, `zig build verify` refuses before any rung runs.

- [x] **Step 3: The HUD on its own palette slot (still grey)**
  - [x] Define `snes_target.hud_palette = 1` and mirror it in asm as
        `!HUD_PAL`/`ConstHudPal`, checked by a symbol test like the others.
  - [x] Set the high byte to `!HUD_PAL<<2` in every BG2 map writer listed in
        the overview, and change the Zig window-word encoder and decoder.
        Then search again for any BG2 writer missed (`BG2_MAP`, `VMDATAH`,
        `VMDATAL+1`).
  - [x] `LoadPalette` also writes the window table to CGRAM `$10-$13`.
  - [x] Check that `hud_oracle` and the death and Queen window paths still
        decode BG2 words.
  - [x] Rung: the HUD reads its own slot. A fault that changes `$11` alters
        a HUD pixel and no play-field pixel, and a fault on `$01` does the
        reverse.
  - [x] Verify: the full gate (`verify`) is green with pixels unchanged.
        Re-pin `retail` and `debug`, and `crawl` if `zig build repin` shows
        it moved: "HUD moved to BG2 palette 1, colours unchanged".
  - [x] Commit, re-pin included.
  - Done as: the status bar has its own put, `BarPut`, whose high byte is
    `!HudAttr` (WRAM `$07A1`, the start of the free `$07A1-$07CA`).
    `UpdateStatusBar` sets it with `!HudBase`, so in the Queen's room the bar
    stays a BG3 row on palette 0, and `StatusBarLCounter` reads it too.
    `LoadPalette` moved to bank 1 (`jsl`, long reads of the boot record):
    bank 0 had 7 bytes free and the step needed ~40; it now has 44. The rung
    is two phases at the end of `cold boot` (codes 158/159): it makes
    `$11-$13`, then `$01-$03`, green for a frame and checks where the green
    lands. Code 15 also checks `$10-$13`. The faults: the engine before this
    step exits 158 (run by hand), and `UpdateStatusBar_hudAttr` patched to
    `#$00` exits 159 (in the gate). The crawl didn't move.

- [x] **Step 4: Graders read colour through the scheme tables (cart unchanged)**
  - [x] First, confirm Mesen's BGR555 → RGB888 conversion on one framebuffer
        read (expected `(c<<3)|(c>>2)`). The exact matching below depends on
        it.
  - [x] `colors.luaShade(scheme)` emits a Lua `shade(px)` built from that
        scheme's 16 words. It matches **exactly only**, and a colour outside
        the scheme raises a Lua error naming the pixel and its RGB. Nothing
        falls back to the nearest colour.
  - [x] Replace all six hand-written `shade` functions with the generated
        one, parameterised by the expected scheme (the default, since the
        rungs zero SRAM).
  - [x] Any rung that turns out to sample dimmed frames (a fade, the Queen's
        flash), which the old thresholds tolerated, gets explicit handling
        at that rung, with a comment. No blanket tolerance.
  - [x] Verify: `verify` and `verify-full` are green, still on greys. This
        proves the helper reproduces today's thresholds.
  - [x] Commit: "graders: shade through the scheme tables".
  - Done as: `colors.writeLuaShade(w, scheme)`. The testrunner hands back
    only an exit code, so an off-scheme pixel prints its RGB (which the
    scenario runner shows) and stops with `colors.lua_off_scheme` (5, free
    in every pixel-reading script), which each describer reads as
    `off_scheme_why`. Positions aren't named: callers pass a pixel, not a
    place. The table is local to a `do` block, so `m2snes.lua` gains no
    top-level local (it is near Lua's 200). The scheme graded is
    `colors.fresh_scheme` (`mono`), which Step 5 retires for
    `default_scheme`. The conversion was confirmed by exact matching passing
    on greys. The fault (graders set to `gbc` on the grey cart) exits 5 from
    the title, cold-boot, `snes boot` and refills scripts. No rung sampled a
    dimmed frame, so none needed handling. Found for Step 6: the title
    script writes its fail frame to SRAM `$1F00-$1F01`, inside the planned
    `$701F00` scheme region.

- [x] **Step 5: Schemes in the cart; default `gbc` (F1, F3b)**
  - [x] Asm side:
    - `SchemeTable`, a placeholder of `!SCHEMES × 16` words patched by the
      builder (`snes_inject`, the same way it patches `BootPalette` today);
    - `!SCHEMES`, `!DEFAULT_SCHEME` and WRAM `!Scheme`, mirrored and
      symbol-tested against `colors.zig`.
  - [x] `LoadPalette` takes the scheme in `!Scheme` and loads `$00-$03`,
        `$10-$13`, `$80-$83` and `$90-$93` from the table. `Reset` sets
        `!Scheme = !DEFAULT_SCHEME` first, so every boot that skips the title
        (scenario, handover) is the default.
  - [x] Retire the boot record's palette words: `BootPalette` (4 BG words)
        and the 8 object palette words (`snes_inject.boot_obj_palette_at`).
        `LoadPalette` is their only reader, and the scheme table replaces
        them. Bump the record version, and update:
    - the asm record layout and its `BootRecord` offsets;
    - `snes_inject`'s writer (the `boot.palette`/`obj_palette` loops) and
      its layout doc comment;
    - the `palette`/`obj_palette` fields of `snes_screen`'s boot struct, and
      every place that sets them;
    - `snes_romtest`'s Lua that checks CGRAM against `boot.palette`, which
      now checks against `cgramWords(default)`.
  - [x] Code 15 checks CGRAM against `cgramWords(default)` across all 16
        entries. The old greys must fail it.
  - [x] A door fade under `gbc`: CGRAM is unchanged across the fade, and
        INIDISP ramps as the `fade` rung already requires.
  - [x] A scenario-boot rung reads `gbc` words in CGRAM.
  - [x] Verify: `verify` and `verify-full` are green, with the Step 4 helper
        set to `gbc`. Re-pin `retail` and `debug`, and `crawl` if
        `zig build repin` shows it moved: "default colour scheme gbc".
  - [x] Commit, re-pin included.
  - Done as: `Reset` calls `LoadDefaultPalette`, a bank-1 entry that sets
    `!Scheme` (WRAM `$07A2`) to `!DEFAULT_SCHEME` and falls into
    `LoadPalette`; bank 0 is untouched. `SchemeTable` sits in bank 1 beside
    it, $FF until `snes_inject.patchSchemes` writes it, which refuses an
    engine whose `!SCHEMES`/`!SCHEME_WORDS` disagree with `colors.zig`.
    Boot record v18 drops 24 bytes, and a new test checks every field's
    offset against its engine label. `colors.fresh_scheme` is gone. The fade
    check is the existing `fade` rung, which now also requires CGRAM to hold
    the default's 16 words on every graded frame (code 252, off the
    unhandled-pose range). The scenario-boot check is code 9 in every
    `scenario` script: play opens on the default's words after fresh SRAM
    and Start. Faults, run by hand: `mono`'s words in `gbc`'s slot make
    `snes boot` exit 15; the fade grader expecting `mono` exits 252; the
    scenarios expecting `mono` exit 9. The crawl didn't move.

- [x] **Step 6: Per-slot schemes in SRAM, and L on the title (F2, F3)**
  - [x] SRAM layout at `$701F00` (free, past the spawn flags): a 4-byte
        magic, then one scheme byte per slot. Add constants and a comment
        beside `!SRAM_SPAWN`, and teach `save.zig`'s layout the new region.
  - [x] Split the slot walk out of `TitleStart` into a side-effect-free
        routine that returns "is a game" for a given slot. `TitleStart`
        calls it unchanged in behaviour, and the title rungs prove that.
        New code goes in bank 1, reached by `jsl` (bank 0 is nearly full).
  - [x] `SlotScheme(slot)`: if the slot is a game, the magic is good and the
        byte is below `!SCHEMES`, return the byte. Otherwise return
        `!DEFAULT_SCHEME`. Never index the table with an unchecked byte.
  - [x] On the title:
    - at setup (forced blank), load `SlotScheme(ActiveSlot)` directly;
    - in `TitleFrame` after `TitleSlotStep`, when the slot changes, set
      `!Scheme` to that slot's scheme and set `!SchemeDue`;
    - an L-alone edge steps `!Scheme` to the next id, wrapping, sets
      `!SchemeDue`, and writes the magic and byte at once if the slot is a
      game;
    - after a clear, `!Scheme` goes to the default;
    - Start writes the magic and the slot's byte (this covers an empty
      slot's first game).
  - [x] NMI: when `!SchemeDue` is set, `jsl` an upload of the 16 CGRAM
        words in vblank (the `!ReadoutFontDue` pattern).
  - [x] Rungs:
    - (a) L recolours CGRAM to `mono` and back;
    - (b) moving the slot recolours to that slot's scheme;
    - (c) a saved slot keeps `mono` across `Reboot` and a fresh power-on,
      while another slot keeps its own. The fixture is a real record: the
      magic plus `BootSave`, the record a new game saves;
    - (d) an empty slot's L choice is gone after moving away and back;
    - (e) fault injection: a bad magic, and separately `$FF` with a good
      magic, both boot `gbc` with the correct CGRAM;
    - (f) Mesen write log: every `$2122` write lands in vblank or forced
      blank;
    - (g) debug cart: choose `mono`, start, warp, and the scheme is kept;
    - (h) the title timing and TAS rungs are unchanged.
  - [x] Verify: `verify`, `verify-full`. Re-pin `retail` and `debug`, and
        `crawl` if `zig build repin` shows it moved.
  - [x] Commit, re-pin included.
  - Done as: the region is at `$701600`, not `$701F00`, because the title
    scripts write their fail frame at `$1F00`. It is `colors.sram_at`; `save.zig`
    gains `spawn_end`, and a test keeps the region past it and below `$1F00`.
    The magic is `M2CS` (`SchemeMagic`, checked against `colors.sram_magic`).
    `SlotIsGame` is the walk moved whole to bank 1 (bank 0 got smaller).
    `TitleSchemeSeed` asks it of every slot once, at setup with NMI off, and
    keeps the answers in `!SlotGame` (`$07A5-$07A7`); only the clear changes
    them while the title is up. `SchemeStore` writing over SRAM with no magic
    sets all three ids to the default first, so earlier bytes don't become
    another slot's scheme. The rung is `schemes` (`src/scheme_grade.zig`,
    eight runs, 9/9 faults by run and code), and (g) is the `warp` rung's
    `scheme` scenario (fault: L removed, 51). (c)'s reboot is the reset button
    (`emu.reset()`), which reaches `Reset` as `Reboot` does, and its power-on
    is the `power_on` run, from the bytes `keep` leaves. Also added: the `cleared`
    run, the clear showing the default. `residue.zig` lists `TitleSchemeStep`
    as a reader of `!InputRisingEdge`. The crawl didn't move.

- [x] **Step 7: The L badge in the bottom border (F2)**
  - [x] Draft `assets/title_badge.png` in our own art: a 16×16 L-button
        glyph and one name strip per scheme (`MONO`, `GBC`). It uses
        `title_super.png`'s rules: a fixed palette, checked colours, and
        index 0 transparent. James can redraw it.
  - [x] `src/title_badge.zig`, following `title_super.zig`:
    - it decodes the PNG and checks its colours;
    - it emits a chr blob from a free BG1 character range, a palette for
      BG palette 6 (CGRAM `$60`, free), and a map patch per scheme;
    - it places the badge at the window's left edge in the bottom border.
  - [x] Engine:
    - `UploadTitleArt` also uploads the badge's chr and palette, plus the
      active scheme's patch;
    - define `!BAND_BOTTOM_TM`, and turn BG1 on in the bottom band on the
      title only; `ClearTitleArt` turns it off and clears the patch;
    - `!SchemeDue`'s NMI upload also rewrites the name patch.
  - [x] Rungs:
    - the badge's pixels in the border match `title_badge.png` for each
      scheme;
    - the badge is gone in play;
    - the existing title rungs (window rows, "Super") are unchanged;
    - the bottom-right corner stays empty.
  - [x] Verify: `verify`, `verify-full`. Re-pin `retail` and `debug`, and
        `crawl` if `zig build repin` shows it moved.
  - [x] Commit, re-pin included.
  - Done as: the PNG is 48×32, one 48×16 badge a scheme stacked in id
    order; tiles are deduplicated, so the glyph is stored once. Characters
    from `$80`, BG palette 6, 4 lines below the window (BG1 map rows 23-25,
    6×3 words a scheme). `title_super` gained `decodeWith`, `encodeTile` and
    a positioned `Patch` for it. The blobs are `title_art` ids 3-5.
    `UploadTitleArt` keeps the map blob's address in `!BadgeMap` (`$07A8`),
    so `BadgeShow` can DMA the scheme's patch from NMI without `FindBlob`;
    `SchemeNmi` calls it after `LoadPalette`. `!BAND_BOTTOM_TM` is
    `!Bands+9`, held by an assert on the table's size. The grading is in the
    `schemes` rung: every `expect` also reads the whole bottom border (code
    13), the badge plus backdrop on the title, backdrop alone in play, which
    also keeps the right corner empty. The title rung's 102 also checks the
    badge patch is zero once play starts. Faults: `SchemeNmi_badge` → `rtl`
    exits 13 on `l_press`; `ClearTitleArt` → `rtl` exits 13 on `power_on`.
    The crawl didn't move.

- [ ] **Step 8: Docs, playtest, PR**
  - [ ] `docs/feature_tracker.md`: a colour-schemes entry, graded by the
        rungs above. README playing section: L on the title cycles the
        colour scheme, and each file remembers its own.
  - [ ] THIRD-PARTY-NOTICES: decide on a SameBoy line for the 12 colour
        values (MIT) and add it if needed.
  - [ ] `verify-gate` skill run: unit, policy, `verify`, `verify-full`,
        pins.
  - [ ] FXPak playtest (F6), each check able to fail:
    - fresh SRAM shows a colour title with the `GBC` badge;
    - L shows greys and `MONO`;
    - a saved slot keeps its scheme after a power-cycle;
    - acid turns Samus's flash green.
  - [ ] Commit the docs, push, and open a PR to main, with the attribution
        lines.
