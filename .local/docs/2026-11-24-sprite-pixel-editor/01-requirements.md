---
created: 2026-11-24T17:36:20Z
updated:
  - 2026-11-24T17:36:20Z
  - 2026-11-24T17:58:25Z
  - 2026-11-24T18:03:05Z
  - 2026-11-24T18:15:12Z
  - 2026-11-24T19:31:02Z
  - 2026-11-24T22:27:15Z
  - 2026-11-24T22:45:59Z
  - 2026-11-24T23:37:46Z
  - 2026-11-24T23:55:47Z
  - 2026-11-25T03:20:56Z
working_directory: /Users/james/git/m2snes
---

# Requirements

## Status: Final

## Overview
A local sprite editor for the `full` scheme. You pick a sprite, recolour it
pixel by pixel from the colours its palette can actually show, edit the
palettes, and see each palette change across every sprite that uses it. The
cart builds with those edits. It works by using the SNES's 16-colour sprite
palettes (12 usable) instead of the Game Boy's 4.

As part of this, all of `full`'s colours, and its hand-chosen sprite-tile
palettes, move out of Zig source into data files. The build and the editor both read
them, and only the editor writes them.

## Features

### F0. `full` colours as data
**Acceptance Criteria:**
- Every `full` colour moves into ZON data files that `colors.zig` imports at
  compile time:
  - the BG colour sets
  - the window palettes
  - the OBJ palettes
  - the damage steps
  - the suits
- The files hold the final colours, not mid-tones expanded by `ramp`, so what
  the editor shows is exactly what the file says.
- Sprite tiles' palette choices are data as well (see F2). The derived slot
  stays computed, and the data holds only the choices that differ from it.
  (`tile_choices` covers only background tiles and is unchanged.)
- This move alone changes no cart byte: the ROM and pins are unchanged.

### F1. Extended sprite palettes (cart side)
Under `full`, each OBJ palette has 16 entries, and a sprite pixel uses one of
12 of them.

**Shade rule (James, 2026-11-24).** An index's Game Boy shade is `index & 3`,
the same in every palette. `index >> 2` picks one of 4 variants.

| Indices | Shade | Notes |
|---|---|---|
| 0 | — | transparent |
| 1, 5, 9, 13 | 1 | light |
| 2, 6, 10, 14 | 2 | middle |
| 3, 7, 11, 15 | 3 | dark |
| 4, 8, 12 | — | never used |

So every palette has 4 lights, 4 middles and 4 darks. Anything that reads
only a sprite tile's planes 0–1 shows each pixel's shade with no extra code.

**Acceptance Criteria:**
- `full` loads all 16 entries of each of the 8 OBJ palettes, plus the
  damage-step and suit palettes.
- `mono` and `gbc` show each pixel at its shade (`index & 3`).
- Whole-palette swaps carry 16 entries, each variant defaulting to its
  shade's colour:
  - frozen (palette 3)
  - a hit Metroid's damage steps (palette 2)
  - the OBP1 swap/flash

  The engine ignores the Game Boy's palette registers under `full` (its
  palettes are static), so nothing else re-derives colours at runtime.
- The engine routines that rewrite sprite bitplanes at runtime handle planes
  2–3 too: `DeathErase`, `QueenDisintegrate` and `VariaAnimNmi`.
- Power and Varia suits (palettes 1 and 7) carry all 16 entries per suit.
- With no edits, every scheme draws the same pixels as today, checked with the
  boot-test frames. The ROM changes because the table grows, so the cart is
  re-pinned once.
- Every path that puts sprite tiles in VRAM gets the edited tiles, including
  any runtime copy of raw Game Boy tile data, which the plan must find.
- Copies of sprite tiles drawn on the 2bpp background (`UploadSamusBgTwin`,
  the BG half of `spr` transfers) show each pixel's shade colour. The editor
  marks those tiles. The Queen's head, which BG2 draws from her 4bpp object
  tiles, gets her full 16-entry palette.

### F2. Pixel overrides, one per unique tile (data)
A tile's identity is its original Game Boy content, not where it sits.
Identical tiles in different sheets are one tile for editing purposes, so an
enemy looks the same in every area and nothing is maintained twice.

**Acceptance Criteria:**
- Pixel edits and palette choices are stored once per unique tile, keyed by a
  hash of the original tile content. A full tile is never stored, so no ROM
  bytes enter the repository.
  - Edits are stored as a sparse list: pixel and new index.
  - The palette choice is stored per tile.
- The converter applies a tile's override to every copy of that tile, in every
  sheet, after `to4bpp`.
- Some identical tiles are in different slots today. The editor lists these
  conflicts and lets you pick one palette for the group.
- An override whose key matches no tile, or whose pixel is out of range, fails
  the build with a clear message.
- The data file records the ROM's hash. A mismatch fails the build.
- The tracked-file policy (`zig build policy`) passes with edits present.

### F3. Pick a sprite
**Acceptance Criteria:**
- Browse by sprite: each enemy, Metroid, boss, item and Samus, as the frames
  (metasprites) the game draws. You can also browse a raw sheet's tiles.
- Selecting a frame opens it zoomed for pixel editing, drawn the way the cart
  would draw it under `full`.
- Frames and sprites can be named and grouped (e.g. "Moheek, walk 1"). For a
  frame whose sheet can't be found automatically, you choose the sheet, and
  that choice is saved. Names and sheet choices go in a tracked data file with
  no ROM bytes. Unnamed frames show their metasprite id.

### F4. Edit pixels, limited to usable colours
**Acceptance Criteria:**
- Each 8×8 tile has one palette. The colour picker shows only that palette's
  12 colours plus transparent, so you can't paint a colour the tile can't
  show.
- Any pixel can take any of those 12 colours or transparent (James,
  2026-11-24). A pixel painted a different shade, or made transparent or
  opaque, changes under `mono` and `gbc` too.
- A frame's tiles can be in different palettes, and the picker follows the
  tile under the cursor.
- You can change a tile's palette, but only to a palette that sprite may use
  (never Samus's 1 and 7 for anything but Samus).
- Tools: pencil, eyedropper, and undo/redo.
- A tile shared by several frames or sprites says so and can list where else
  it appears.

### F5. Edit palettes, see the impact
**Acceptance Criteria:**
- The palette panel shows the selected palette's 12 colours in rows of light,
  middle and dark. Each colour can be edited, rounded to BGR555.
- A panel shows every sprite and frame that uses the selected palette and
  redraws them live as colours change. Selecting one colour highlights the
  pixels that use it.
- Preview toggles: frozen, Metroid damage steps 1–3, OBP1 flash, and Power or
  Varia suit.

### F6. Run and save
**Acceptance Criteria:**
- `zig build sprite-editor` reads the user's ROM, starts a local server and
  prints the URL.
  - The server listens on localhost only.
  - It writes only the editor's own data files.
- Save writes the data files. The next `zig build` produces a cart with the
  edits.
- The editor page and the ROM graphics it serves are never published or
  committed.
- The editor's rendering, palette panel and data handling are written so a
  later background editor can reuse them (see Future).

**Out of Scope:**
- Background and tilemap editing (see Future).
- Changing a sprite's shape: new tiles, metasprite layout, animation frames.
- Editing `mono` or `gbc` colours.
- Live hot-reload into a running emulator or the FXPak.
- More than 8 OBJ palettes on screen, or swapping OBJ palettes per area.

## Future (not this cycle)
A background and tilemap editor:
- screens shown and zoomable
- each screen's unique tiles in an edit panel
- an edit to a tile shown across a whole screen or area

One known limit: the play field is BG3, which is 2bpp, so BG tiles stay at 3
colours plus the backdrop. More colours there would mean moving the play field
to a 4bpp layer, which is a separate VRAM and engine project.

## Constraints & Dependencies
- Zig for all tooling (memory: prefer Zig over Python). Data files are ZON,
  imported at compile time (Zig 0.16). The editor is plain HTML/JS served by a
  small Zig server (`std.http`), with no npm toolchain.
- ROM-derived output stays in `build-out/` (gitignored). Only colours,
  overrides, palette choices and names are tracked.
- The `verify` gate must pass. The cart is re-pinned once for F1 and again
  whenever edits land.
- Depends on:
  - `full_slots`/`full_assign`: tile → slot
  - `entity.zig`: metasprites
  - `colors.zig`: `full` tables
  - `snes_convert`: `to4bpp`

## Resolved questions
1. **Frame → sheet mapping.** A metasprite names VRAM tiles, and which sheet
   is loaded there depends on the room. The plan resolves what it can
   automatically, e.g. from each enemy's graphics bank. Anything left
   unresolved is shown against a sheet James chooses, and James names and
   groups those frames by eye (F3).
2. **Samus.** She is included, with her suit palettes (1, 7) edited as the
   Power and Varia tables.
3. **Web tool.** Recommended over a native Zig GUI and over Aseprite
   round-trips (James, 2026-11-24).
