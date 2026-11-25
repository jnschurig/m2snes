---
created: 2026-11-24T18:00:25Z
updated:
  - 2026-11-24T18:00:25Z
  - 2026-11-24T18:04:00Z
  - 2026-11-24T18:16:19Z
  - 2026-11-24T19:31:02Z
  - 2026-11-24T22:27:15Z
  - 2026-11-24T22:45:59Z
  - 2026-11-24T23:37:46Z
  - 2026-11-24T23:55:47Z
  - 2026-11-25T03:20:56Z
working_directory: /Users/james/git/m2snes
---

# Implementation Plan

## Status: Final

## Overview
The work runs in four stages:
1. Move `full`'s colours into ZON (no cart change).
2. Widen the cart's sprite palettes to 16 entries, and teach the engine
   routines that touch sprite bitplanes about planes 2–3 (one re-pin).
3. Add a content-keyed sprite-edit file that the converter applies to every
   `chr_obj` asset and the `slots` blob.
4. Build the editor: a Zig `std.http` server on localhost plus one embedded
   HTML/JS page. It reuses `swatch_full`'s sprite assembly (sheet votes,
   `id_sheets`, names), which moves into a shared module and a catalogue data
   file.

**Shade rule (F1, James 2026-11-24):** a pixel's Game Boy shade is
`index & 3`, and indices 4, 8 and 12 are never used. Planes 0–1 of an edited
tile are therefore its 2bpp art, which `mono`, `gbc` and Samus's BG twin read
as they do today. A pixel may take any usable index or transparent (F4).

## Steps

- [x] **Step 1: `full` colours as ZON (F0)**
  - [x] Write `src/data/full_colors.zon` from today's `colors.full`, using a
        one-off `zig run` dumper that is deleted afterwards. It is not a build
        step, because the file is hand-maintained from then on. The file
        holds:
        - final colours (after `ramp`/`mix`), shade-indexed, as 0xRRGGBB in
          `colors.rgb888`'s form, so each is exactly a BGR555 colour
        - `obj` palettes 1 and 7 as `null`, meaning they take the Power
          suit's colours from `suits` and aren't stored twice
        - per set: `bg`; then `window`, `obj`, `damage` and `suits`
        - the comments from `colors.zig` and `swatch_full.obj_slots` that
          name each set's and slot's role, moved in beside their values.
          After the dump, this file is hand-maintained text, and its
          comments are the documentation.
  - [x] Switch `colors.full` to `@import("data/full_colors.zon")`. Delete
        `area_mids`/`acid_mids`/`bubble_mids`/`withKinds` and the `f.obj`
        literals. Keep `ramp`/`mix`/`bgr555` only where something else uses
        them.
  - [x] Unit test: `fullTable()` equals a golden copy taken before the switch,
        kept only for this step and deleted after.
  - [x] Verify: `zig build test`; `zig build verify` with the cart pins
        unchanged (byte-identical ROM).
        - 2026-11-24: `zig build test` passes. Both carts are byte-identical
          to builds taken before the step (retail `f103c507`, debug
          `17e177fd`). `verify`'s cart-pin rung is red: `pins/cart.txt`
          (`3c5cf141`/`62da8859`) predates the branch's uncommitted
          colorization work, so it was already red before this step.
          James: leave the pins until more colorization work lands.

- [x] **Step 2: 16-entry sprite palettes, cart side (F1)**
  - [x] ZON:
        - `obj`, `damage` and each suit's two tables become 16 entries.
        - Widen `full_colors.zon` once, by editing the existing file rather
          than re-dumping it, so its comments are kept. Entries 4–15 take
          `entry[i & 3]`, which is the default meaning "no variant".
        - `colors.Table16` sits beside `Table`. `fullTable()` writes 16 words
          per OBJ-side table, and `full_global_words` and `!FULL_*_AT` follow.
  - [x] Audit every path that puts sprite tiles in VRAM (F1):
        - Each DMA or copy into OBJ VRAM, and into the BG windows that hold
          sprite tiles, whose source is not a converted `chr_obj` asset.
        - Known suspects: the Varia sheet `VariaAnimNmi` reads,
          `UploadSamusBgTwin`, item and drop graphics, and anything that
          reads Game Boy banks at runtime.
        - Write the list into this plan as sub-tasks under this step, each
          with its fix, or note "none found" with the search used.
        - Found (searched `CLASS_CHR_OBJ`, `OBJ_CHAR_BASE`, `BG2_CHAR_BASE`,
          `CGADD` in `engine/main.asm`): every write into OBJ VRAM is a
          `chr_obj` blob (`UploadSamusChr`, `GfxXferNmi`'s `GfxInfo` rows,
          the title's objects, `CreditsChrRows`, Varia) or a read-back of
          VRAM (`QueenChrFill`). No runtime read of raw Game Boy tiles.
          - [x] BG2 (window, HUD, the Queen's head) draws object
                characters, so its palettes need `index & 3` too: `full`'s
                window palettes are 16 words (4 copies), `mono`/`gbc` write
                the window's 4 four times. In her room `FullBg` loads her
                OBJ palette 2 into palettes 2–5 (James: the head takes her
                palette).
          - [x] `UploadSamusBgTwin` reads planes 0–1 of the converted sheet:
                shade, no change.
          - [x] Step 3: `CreditsChrRows`' `chr_bg` rows (ids 2, 3) are the
                BG halves of `gfx_creditsSprTiles`/numbers; give them
                `apply2bpp` with the `spr` windows.
          - [x] `DeathErase` erased only SNES tiles 0–63 (the Game Boy
                address taken as a 4bpp offset). Now the true map:
                `death.eraseBytes`, both tiles of a stride, planes 0–1 and
                2–3; the death rung's Lua follows.
  - [x] Engine:
        - `LoadFull` OBJ loop, `FullObj2Load` and `FullSuitLoad` DMA 32 bytes
          per palette (`FullDmaY`).
        - `LoadPaletteOne` (mono/gbc) writes OBP0's 4 colours 4 times into
          `$80-$8F` and OBP1's into `$90-$9F`, so `index & 3` holds there with
          no table growth.
  - [x] Each engine routine that rewrites sprite bitplanes at runtime must
        also update planes 2–3:
        - `DeathErase` zeroes the matching plane 2–3 bytes.
        - `QueenDisintegrate` ANDs them with the same mask, in its shadow and
          `!QdList` spans.
        - `VariaAnimNmi` copies the Varia sheet's plane 2–3 byte along with
          each plane 0–1 byte.
  - [x] The Queen's head: BG2 draws it from her 4bpp object tiles. Find its
        BG2 palette load in her room and give it her OBJ palette's 16
        entries.
  - [x] Graders: `colors.shadeOf`/`uniqueShades`, `scheme_grade` and the
        `full` frame checks must accept variant colours as their shade.
        Check `full_ref*`, `swatch_full` and `src/gb/ppu.zig` callers.
  - [x] Unit tests:
        - the graders take any variant colour (entries 4–15) as its shade
          (`index & 3`), using a synthetic table with distinct variants. This
          stays true after editor edits, unlike a check that every table
          still holds its defaults.
        - layout of the grown `fullTable()`
        - a 4bpp tile with plane 2–3 bits keeps `index & 3` under `DeathErase`'s
          byte map (Zig model of the address math)
  - [ ] Verify: `zig build verify` and `verify-full`. Re-pin the carts once:
        the table grew, and every pixel is the same because no tile uses
        indices above 3 yet. Spot-check under `full`, `gbc` and `mono` with
        `rom-test`.
        - Done: `test` green; `verify` 48/50 (only the two pin rungs red);
          `credits` green standalone. Re-pin deferred (James: "wait to
          re-pin until I have used the tool to do recoloring"), so
          `verify-full`'s slow tier stays blocked until then.

- [x] **Step 3: Sprite edits applied by the converter (F2)**
  - [x] `src/sprite_edits.zig`:
        - Schema for `src/data/sprite_edits.zon`: `rom_sha1`, then `tiles`:
          `{ key, palette: ?u3, pixels: []{ x: u3, y: u3, index: u4 } }`.
        - `tileKey(gb: *const [16]u8) u64` (Wyhash, fixed seed).
        - `apply(gb16, bytes32, edit)` sets each pixel's 4 plane bits.
        - `index` must be 0–15 and not 4, 8 or 12. Any other index, any
          shade, and transparent are all allowed (F4).
        - `apply2bpp(gb16, edit)` writes `index & 3` into a 2bpp copy.
        - `rom_sha1` is checked only when `tiles` is non-empty, so a fresh
          or empty file needs no hash.
  - [x] `snes_convert`: after all assets are built, walk every `chr_obj`
        asset's 16-byte GB chunks and apply the matching edit. Collect the
        keys used. Each of these is an `Error`, with the key printed:
        - an edit key that matches no tile
        - a ROM hash mismatch
  - [x] Also apply `apply2bpp` to the `chr_bg` half of each `spr`/`ITEM`
        window. Those windows are the same sprite bytes. Don't apply it to
        background tilesets: a blank or common tile there may share a key
        with a sprite tile by chance.
  - [x] `full_slots.blob`: an `obj` sheet's tile takes `edit.palette` when
        set, else its derived slot (`slotAt`), as it does today.
        - Derived slots stay computed. Only choices that differ from them
          are stored (F0).
  - [x] Unit tests:
        - apply/round-trip on a synthetic tile
        - an unmatched key fails
        - an empty edits file leaves every `chr_obj` asset equal to
          `to4bpp(gb)`
  - [x] ROM test: a temporary edit on one Hornoad tile and one Samus tile
        builds, and `rom-test` shows it. Remove the edit and confirm the pins
        are back.
  - [x] Verify: `zig build test`; `zig build policy` with a non-empty edits
        file.
  - Done:
        - `Asset.twin` marks the BG copies: the `spr` windows (`shared_window`),
          `spr` load windows, `ITEM`'s windows, and the credits' sprite
          sheets. Errors log `src/data/sprite_edits.zon: the edits for tile
          0x… …` before failing.
        - ROM test: a temporary edit on Hornoad `$E3` and Samus tile 1 put
          edited 4bpp bytes (planes 2–3 too) in the cart. The tile Samus
          shows in `swatch-full`'s shots isn't tile 1, so a second edit
          striped every non-blank Power Suit and `gfx_enemiesA` tile. All 19
          `full` shots showed Samus and the HUD digits striped. Reverting
          put both carts back on `ea6af2b0…`/`3ec064d5…`.
        - `policy` passed with 236 edits present (the ZON is untracked but
          listed by `--others`).

- [x] **Step 4: Move the sprite model and catalogue out (no behaviour change)**
  - [x] Move from `swatch_full.zig` into `src/data/sprite_catalog.zon`, with
        a loader in `src/sprite_catalog.zig`:
        - `enemy_names`, `ai_names`, `id_sheets`, `sheetOfAi`
        - an empty `frames` table, for names and groups
  - [x] Move `assembleSprites` (door vote plus coherence) out of
        `swatch_full_main.zig` into `src/sprite_model.zig`, unchanged.
  - [x] Point `swatch-full` at the new modules.
  - [x] Verify: `zig build test`. `zig build swatch-full` output is
        identical (diff `build-out/swatch-full` before and after).
  - Done: the catalogue also holds `ai_sheets` (was `sheetOfAi`'s switch) and
        `species_pairs` (was `sameSpecies`'s pairs). `sprite_model` still imports
        `swatch_full` for `Part`/`ObjVram`/`spritePng`; Step 5 separates them.
        `swatch-full` output and log byte-identical; `zig build test` green.

- [x] **Step 5: Extend the sprite model (F3 data)**
  - [x] Extend `sprite_model` to Samus (`sprites.zig` set, Power/Varia) and
        to items and drops. Its output:
        - unique tiles (key → GB 16 bytes, current slot, the sheets and tiles
          it appears at, copy count, BG-twin flag)
        - sheets
        - frames (parts plus resolved sheet, or "unresolved")
  - [x] Conflict list: unique tiles whose copies have different slots
        today.
  - [x] Unit tests: Samus and an item frame resolve; the conflict list is
        stable against the ROM.
  - [x] Verify: `zig build test`. `zig build swatch-full` output is still
        unchanged.
  - Done (verified: `zig build test` green; `enemy-swatches.html` and
    `full-swatches.html` byte-identical to the Step 4 output):
        - `resolveEnemies` (the door vote and coherence, unchanged) now
          returns blocks of runs with their sheet. `assembleSprites` draws
          them, and `build(a, rom, assets)` makes the model from
          `snes_convert.run`'s assets.
        - Tiles: every chunk of every `chr_obj` asset, one per key. Each has
          its copies (one per ROM offset, each with its `slotAt` slot and its
          named sheet and tile), a twin flag (a twin asset or Samus's
          `$80-$AF`) and a conflict flag.
        - Views (what object VRAM holds): Samus Power and Varia (page
          `samus`); one per enemy sheet (Samus's sheet below `$B0`, the sheet
          at `$B0`, the common items at `$F0`); `common`; and one per item
          nibble (`ITEM`'s orb at `$B0`, its tiles at `$B4`). The item orbs
          are `$80 + 2n` (orb) and `$81 + 2n` (picture). Item names are in the
          catalogue (`item_names`).
        - Frames: 68 Samus, then the enemy runs, then the item orbs. A frame
          is unresolved (`view` null) when its view loads none of its parts.
          The catalogue's `frames` override name, group and view.
        - 9 conflicts, pinned by count and key hash: six title/credits glyphs
          (title slot 3, font and digits 7), a Samus tile also in
          `gfx_surfaceSPR`, a `gfx_enemiesA` tile that appears twice, and a
          tile in both the Zeta's and the Omega's sheets. Blank tiles are
          left out.
        - `build.zig`: `-Dtest-filter` reaches the SNES modules, and a new
          `test-snes` step runs only those (seconds, against `test`'s 15
          minutes).

- [x] **Step 6: Editor server (F6)**
  - [x] Spike first: a `std.Io.net` + `std.http.Server` listener on
        `127.0.0.1:0` that serves a static `/` under Zig 0.16. This settles
        the API before anything else in the step.
  - [x] `src/sprite_editor_main.zig`, `zig build sprite-editor`:
        - reads `M2_ROM`, builds `sprite_model`, listens on `127.0.0.1:0` and
          prints the URL
        - `GET /`: the page, `@embedFile` of `src/sprite_editor/index.html`
          and `editor.js`
        - `GET /api/model`: JSON of tiles, sheets, frames, catalogue,
          palettes, edits and conflicts
        - `POST /api/save`: validates as Step 3 does, then writes the three
          data files:
          - `full_colors.zon` is patched in place. Parse it with
            `std.zig.Ast` (`.zon` mode), find each changed colour's number
            literal by its token span, and replace only those bytes.
            Comments and layout survive.
          - `sprite_edits.zon` and `sprite_frames.zon` are written whole
            under a fixed generated header. They hold no hand comments.
  - [x] Only those three paths are writable. Writes go to a temp file then
        rename. Reject a non-localhost `Host`/`Origin`.
  - [x] `mise.toml`: a `[tasks.sprite-editor]` alias that runs
        `zig build sprite-editor`, like `[tasks.verify]`. It holds no logic
        of its own.
  - [x] Unit tests:
        - model JSON shape
        - save validation rejects a bad index or palette
        - ZON round-trip is stable (writing what was read is a no-op diff)
        - patching one colour in `full_colors.zon` changes only that
          literal: comments and every other byte are unchanged
  - [x] Verify:
        - `curl` the endpoints
        - a save with no changes leaves `git status` clean
        - `mise run sprite-editor` starts the editor and prints the URL
  - Done (verified: `test-snes` green, including the new module's tests
    against the ROM; the server checked with `curl`):
        - Changes from the plan:
          - Frame names, groups and sheet choices go in a new editor-owned
            `src/data/sprite_frames.zon` (`catalog.frames`). The plan had the
            editor rewrite `sprite_catalog.zon` whole, which would have erased
            its hand comments. The catalogue stays hand-maintained.
          - The page is in `src/sprite_editor/`, not `tools/sprite-editor/`,
            because `@embedFile` can't reach outside the module's root.
          - `sprite_model.build` takes the frame overrides as a parameter. The
            editor passes none, and the page applies the state's `frames`
            itself, so removing a name takes effect without a restart.
        - `src/sprite_editor.zig` holds the data side: `load` (every request
          reads the files from disk), `modelJson`, `normalize`, `writeEdits`,
          `writeFrames`, `patchColors` (Zoir walk to each literal's token)
          and `localRequest`. The model JSON adds `obp0`, the `objAttr`
          pages and the allowed palette sets (enemy {0,2,3,4,5,6}, Samus
          {1,7,2,3,4,6}; Samus means loaded by a view on her page).
        - `normalize` also refuses colours that aren't exact BGR555 values,
          a non-null suit palette, unknown frames or sheets, and duplicates.
          It drops pixels set back to their original index, and entries left
          with nothing to store. Output is sorted, so saves diff cleanly.
        - Each file is written only if its bytes change. A no-change save
          wrote nothing (`written: []`). A real save (one edit, one frame
          name, one colour) changed exactly one colour literal, and saving
          the original state put all three files back byte-for-byte. `src/data/` is
          untracked, so this was checked with `cmp` against copies, not with
          `git status`.
        - Each connection runs in an `Io.Group` task. POST needs
          `application/json`; bad Host or Origin gets 403. `sprite_edits.zon`'s
          header is now the generated one.

- [x] **Step 7: Editor UI, browse and render (F3, F5 view)**
  - [x] The page has:
        - a left list of groups and frames (named or by id), with an
          "unresolved" section
        - a centre zoomed frame (canvas, integer zoom, tile grid overlay)
        - a right palette panel, 16 entries in shade rows
        - a bottom "uses this palette" strip
  - [x] JS renders frames exactly as `swatch_full.spritePng` does: flips,
        OAM order, `objAttr` pages ported as tables from `/api/model`.
  - [x] Preview toggles: frozen, damage 1–3, OBP1 flash, Power/Varia.
  - [x] "Shared by N" badge and where-used list. BG-twin and Queen-head
        badge.
  - [x] A wide-impact warning on a tile with many copies (e.g. the blank
        tile, or N above a threshold). Its first edit asks for
        confirmation.
  - [x] Verify: open via the `terminal-browser` skill and compare a few frames
        against `enemy-swatches.html`.
  - Done (verified in the terminal browser, driven through a Rex pane):
        - All 170 enemy frames that pair with one on `enemy-swatches.html`
          match it pixel for pixel at BGR555 precision, transparency included.
          The PNG bytes differ only because the swatch stretches 5-bit
          channels as `c*255/31` and the ZON stores `colors.rgb888`'s
          `c<<3|c>>2`.
        - Checked by eye: Samus Power and Varia (the suit toggle swaps her
          sheet as well as her palettes), an Alpha at damage step 2, frozen
          (221 frames in palette 3), the flash, and the `gfx_enemiesA` sheet
          view.
        - The damage preview reads the `metroid_hit` page only for `gfx_met*`
          views, as only a Metroid does in the cart. Palette 2's colours
          change everywhere.
        - Sheets: the page browses views (what object VRAM holds, with page
          and suit), not raw sheets, so every tile is drawn in its palette.
        - The Queen's-head badge marks every `gfx_queenSPR` tile. The model
          doesn't know which of her tiles BG2's head map uses.
        - The wide-impact sub-task is left open. The warning shows (the blank
          tile, at least 8 copies or at least 16 frames), and `confirmWide` is
          written, but it can only be called once Step 8's pencil exists.

- [x] **Step 8: Editor UI, editing and save (F4, F5, F3 naming)**
  - [x] Pixel tools:
        - pencil, with the picker limited to the tile palette's 12 colours
          plus transparent
        - eyedropper
        - undo/redo stack
  - [x] Tile palette menu, limited to the allowed set: non-Samus
        {0, 2, 3, 4, 5, 6}; Samus {suit, visor, 2, 3, 4, 6}.
  - [x] Palette editing: a colour input rounded to BGR555. The uses strip and
        all frames redraw live. Clicking an entry highlights its pixels.
  - [x] Conflict panel: pick one palette for a tile group.
  - [x] Naming and grouping frames, and choosing a sheet for an unresolved
        frame.
  - [x] Save button and an unsaved-changes guard.
  - [ ] Verify:
        - edit, save, `zig build`, then `rom-test` shows it
        - `zig build verify` passes with the edits; re-pin as expected
        - Done, except the re-pin (James: wait until real recolouring lands):
          with throwaway edits saved from the page (3 pixels and a palette
          choice on one tile, a conflict choice, one colour, a name, a group,
          a sheet for an unresolved frame), `zig build rom` built, the edited
          tile's 4bpp bytes (planes 2–3 too) were in `m2snes.sfc`, and both
          boot tests exited 0. `verify` was 48/50 with only the two pin rungs
          red. The data files were then restored from a backup.
  - Done (checked in the terminal browser with synthetic mouse events):
        - Tools: Select, Pencil, Eyedropper (V/B/I; Alt-click picks with
          the pencil). A stroke is one undo step; ⌘Z/⇧⌘Z/⌘Y. The status line
          shows the colour the pencil would paint on the tile under the
          cursor, so the picker follows that tile's palette.
        - Clicking a swatch picks the pencil's index and marks that entry's
          pixels in the frame (toggle). The colour input edits the entry in
          whichever table the preview shows (suit, or a damage step for
          palette 2), live, one undo step per change.
        - Tile palette menu and the conflict panel share one control. A
          choice equal to a tile's single derived slot is stored as none.
          "Revert this tile's pixels" is extra.
        - The Frame panel names and groups frames. Its sheet menu shows for
          a frame the model can't place, or one with a sheet chosen.
        - Unsaved changes: the state is compared with the last save, so undoing back to it is
          clean. Save is disabled when clean; leaving asks first.
        - Wide impact: the first pencil or palette edit to such a tile asks
          first (Step 7's open sub-task). Declining leaves it unedited. Only
          the blank tile is wide in this ROM (max 121 copies, 14 frames).

- [x] **Step 9: Docs and wrap-up**
  - [x] `docs/colorization.md`: the shade rule, data files and editor
        workflow. A note in `full_assign.zig` that sprite palette choices may
        be overridden by `sprite_edits.zon`.
  - [x] Remove dead code (`colors.zig` mids, the `swatch_full` tables that
        moved).
  - [ ] Verify: the full `verify-gate`.
        - Done, except the pins: `full-assign -- check` agrees with the
          generator after the header note. `verify` 48/50, 16043/16043 tests;
          only the two pin rungs red. The carts are `ea6af2b0…`/`3ec064d5…`,
          Step 3's no-edit hashes. `verify-full` waits on the re-pin.
        - Dead code: none left. Step 1 removed the `colors.zig` mids; every
          `swatch_full` table still there is used. Two unused `death.zig`
          constants predate this cycle and were left.
        - Also added: `mise run sprite-editor:start` / `:stop` (James), on a
          `zig build sprite-editor-bin` step.
