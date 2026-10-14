---
created: 2026-10-08T04:26:39Z
updated:
  - 2026-10-08T04:26:39Z
  - 2026-10-08T20:22:39Z
  - 2026-10-12T01:38:51Z
  - 2026-10-12T02:16:08Z
  - 2026-10-14T14:59:17Z
working_directory: /Users/james/git/m2snes
---

# Requirements

## Status: Final

## Overview

Every cart carries its colour schemes and the player picks one on the title
screen. There is no build setting. This cycle ships two schemes: `mono`
(today's greys) and `gbc`, which colours the game the way a Game Boy Color
colours an original Game Boy game, using the palettes the GBC boot ROM picks
for Metroid II. Each save file remembers its own scheme in SRAM. This is
Phase 0 of `.local/docs/2026-09-25-metroid2-colorization/00-prompt.md`; read
its "Phase 0" section for the background.

## Features

### F1. Colour schemes in the cart

The cart holds a table of colour schemes. Each scheme is one 4-colour table
per layer: BG (play field), window (HUD), OBP0 and OBP1. This cycle has two:

| Scheme | BG | Window | OBP0 | OBP1 |
|---|---|---|---|---|
| `mono` | today's greys | today's greys | today's greys | today's greys |
| `gbc` | boot ROM 28: `$7FFF $7E8C $7C00 $0000` | 28 | 25: `$03FF $001F $000C $0000` | 3: `$7FFF $1BEF $0200 $0000` |

(BGR555, shade 0 first. The `gbc` values are the CGB boot ROM's entry for
Metroid II: title checksum `$46`, 4th letter `R`, palette combination 46.)

Each layer's DMG palette register picks colours from its table, the way the
GBC does in compatibility mode and the way the port picks greys today. For
the live registers (BGP `$93`, OBP0 `$93`, OBP1 `$43`), `gbc` gives:

- BG3 palette 0: `$0000 $7FFF $7E8C $7C00`. Entry 0 is black, so the
  backdrop and letterbox stay black.
- The HUD: the same four colours, in its own CGRAM slot.
- Object palette 0: `-, $03FF $001F $000C`.
- Object palette 1: `-, $7FFF $7FFF $1BEF`.

**Acceptance Criteria:**
- With each scheme active, CGRAM holds that scheme's values. This is graded
  for both `mono` and `gbc`.
- The HUD reads its own CGRAM slot. Changing only the window table changes
  the HUD and leaves the play field alone, and the reverse holds too. This is
  graded.
- Colour values live in the scheme table only, apart from the code that
  assigns palettes. Adding a scheme (`full`, later) means adding a table
  entry, not changing the engine (colorization Goal 2).
- Fades still work in every scheme: a door fade dims and restores the
  colours. This is checked, not assumed.
- The "Super" title art (BG palette 7) is the same in every scheme.

**Out of Scope:**
- The `full` scheme (Samus Returns-inspired), per-tile, per-room or per-enemy
  palettes, and EJRTQ (Phase 1).
- Colour correction. Values are copied raw.
- The boot ROM's alternate d-pad palettes and Super Game Boy palettes.

### F2. Picking a scheme on the title screen

**Acceptance Criteria:**
- On the title screen, each press of **L** steps the selected file to the
  next scheme (`mono` → `gbc` → `mono` ...), and the screen recolours at once.
- Moving the file cursor to another slot recolours the title to that slot's
  scheme.
- Starting a file (new or continued) plays in the scheme shown on the title.
- Nothing about the title's own behaviour changes: its timing, its frame
  counts and the TAS's title inputs all stay the same. L is not a Game Boy
  button, so no original input reads it.
- CGRAM is written only during vblank (or forced blank), so a recolour never
  shows a half-written palette. This is graded from a Mesen CGRAM write log.

- **An L badge on the title,** as in James's mockup: a small L-button glyph
  in the bottom-left corner, with the current scheme's name (`MONO`, `GBC`)
  beside it. Both update on every L press and every slot change.
  - The glyph is our own art, committed like the "Super" title art. The
    name's letters use the game's font as the cart already has it in VRAM
    (from the ROM), or our own glyphs. No ROM-derived art is committed.
  - Placement: **in the bottom letterbox border**, just below the window's
    bottom-left corner, on BG1. It is turned on only on the title, by
    setting the bottom band's main-screen byte, the same way the room readout
    uses the top border (`!BAND_TOP_TM`). It stays out of the 160×144 window
    because `title_oracle.renderRows` grades the title's last two rows ("©1991
    Nintendo") there. The bottom-right of the border stays free for the R
    badge.
  - The badge's layer and palette do not change with the scheme (like
    "Super"), so it stays readable in every scheme.

**Out of Scope:**
- Changing scheme anywhere other than the title (pause screen, in play).
- The mockup's R badge (bottom right, for a future controls config). Leave
  its corner free.

### F3. Each save file remembers its scheme (SRAM)

**Acceptance Criteria:**
- Each of the three slots has its own scheme byte in SRAM, outside the Game
  Boy's save records (`$A000 + slot*64`, the counter at `$A0C0`, and the
  areas the game uses beyond them), with a validity marker.
- The title loads the selected slot's stored scheme. A slot with no valid
  scheme byte (fresh SRAM, or a corrupt or out-of-range value) loads the
  default, which is `gbc`.
- **Fallback for an invalid byte:** every read of a scheme byte is
  bounds-checked against the number of schemes in the cart, even when the
  validity marker is intact. An out-of-range value never indexes past the
  scheme table. It loads the default instead, and the slot plays in the
  default until L is pressed or the file is cleared, either of which
  overwrites it with a valid value. This is graded with fault injection: a
  rung writes a bad marker, and separately an out-of-range byte (e.g. `$FF`)
  with a good marker, and checks that both boot in `gbc` with the correct
  CGRAM.
- A cart with fewer schemes than the one that saved (for example, an older
  build reading a save from a build that has `full`) takes the same
  fallback.
- On a slot holding a saved file, an L press stores that slot's scheme
  straight away, so it survives power-off before the next in-game save.
- On an empty slot, L changes the scheme shown, and starting a new game there
  uses whatever scheme is shown at that moment. The scheme is stored for the
  slot when the game starts, but the title only reads a slot's scheme byte
  once that slot holds a saved file. Until then the empty slot keeps no
  choice: moving away and back, or power-cycling before the first in-game
  save, shows the default again.
- A slot cleared with the title's clear option shows the default. This
  follows from empty slots ignoring their scheme byte, so the clear writes
  nothing new.
- The Game Boy save records stay byte-for-byte what they are now, so the
  save grading is unaffected.

### F3b. Paths that skip the title

**Acceptance Criteria:**
- A boot that never passes the title (the gate's scenario and boot-record
  boots) uses the default scheme.
- A debug-menu warp keeps the current scheme.
- Every CGRAM reload of the four layer palettes reads the active scheme, never
  fixed greys. That includes game over back to the title, the credits, and
  any other path that reloads them. Design lists every such path, found from
  the code (`LoadPalette`'s callers and every CGRAM writer).

### F4. Oracle: SameBoy in GBC mode

The `gbc` tables are graded against SameBoy, not against our own copy of the
numbers.

**Acceptance Criteria:**
- A rung boots the user's plain ROM in SameBoy's CGB model with
  `cgb_boot.bin`, reads BG palette 0 and OBJ palettes 0 and 1 once the boot
  ROM has handed over, and checks that they equal the `gbc` BG, OBP0 and OBP1
  tables.
- Fault check: the `mono` tables fail the rung.
- Like the other SameBoy rungs, it skips with a named reason when `M2_ROM` is
  unset or the SameBoy build is missing.

### F5. The gate under a colour default

Fresh SRAM now boots in `gbc`, and the gate zeroes SRAM first. So every rung
that reads CGRAM or the framebuffer sees colour unless it is told otherwise.

**Acceptance Criteria:**
- Every existing rung passes. Rungs that compare pixels compare shade
  numbers, not RGB, so they hold in either scheme. A colour is mapped back
  to a shade through **one map per scheme**, built from that scheme's tables
  across all layers. Graders don't know which layer a pixel came from, so
  they don't need to.
- A unit test asserts that within each scheme every colour belongs to exactly
  one shade. This holds for `mono` and `gbc`. A scheme that breaks it fails
  the test, which forces a decision instead of letting a grader quietly
  misread a pixel.
- `full` (per-tile palettes) will break that test, and per-layer maps would
  not fix it. Its grading approach (pixel rungs in `mono`, or decoding with
  knowledge of each pixel's palette) is decided in its own requirements, not
  here.
- No rung forces the scheme by poking WRAM. A rung that needs `mono` gets
  there the way the cart does: through a saved-file record plus its SRAM
  scheme byte, or an L press on the title (memory: "Fixtures must not force
  cart state").
- Docs: `docs/feature_tracker.md` gets an entry for colour schemes, and the
  README's playing section mentions L on the title.
- `retail`, `debug` and `crawl` (if it moves) are re-pinned with
  `zig build repin`, with the reason given. The output name stays
  `m2snes.sfc` / `m2snes-debug.sfc`.

### F6. Playtest on hardware

**Acceptance Criteria:**
- On the FXPak with fresh SRAM, the title and the landing site are in colour:
  blue and white rock, a yellow and red Samus, and a white HUD with black
  text, as in James's GBC screenshot. A grey screen fails this.
- The title shows the L badge reading `GBC`. L switches to greys, and the
  badge to `MONO`, and back. On a saved file, power-cycling keeps the choice
  for that slot, and another slot keeps its own.
- Walking into acid in `gbc` turns Samus's flash green (OBP1). A grey or
  black flash fails.

## Constraints & Dependencies

- **The colours are committed as source constants**, cited to SameBoy's
  `vendor/sameboy/BootROMs/cgb_boot.asm` (`Palettes`, combination 46).
  SameBoy is MIT. Twelve colour values are facts, not game data, so the "no
  ROM data committed" policy does not apply. Check whether
  THIRD-PARTY-NOTICES needs a line.
- **The builder stays ROM-only and gains no option:** no boot ROM or SameBoy
  is needed to build. SameBoy is used only by the gate.
- No game logic or timing changes. The TAS and the play and cutscene oracles
  stay valid.
- Bank 0 is nearly full: new engine code goes elsewhere or through `%call0`
  (memory: "m2snes silent test traps").
- Work goes on a new branch from main, with a PR (memory: "Work on a branch,
  PR to main"). Nothing depends on the `font-sheets` branch.
- New asset or codegen tooling (the badge) is Zig plus a `zig build` step,
  not Python.
