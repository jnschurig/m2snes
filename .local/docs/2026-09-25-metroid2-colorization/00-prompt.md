# Metroid II SNES port: colorization

Colorize the m2snes port (`~/git/m2snes`). Phase 0 gives each layer its own
fixed colours, the way a Game Boy Color colours an original Game Boy game.
Phase 1 reproduces EJRTQ's Game Boy Color colorization (romhacking.net hack
4388). Later phases replace its colours, which James does not like, working
toward a Samus Returns (3DS) look.

## Goals

0. **Phase 0 (first): GBC compatibility colours.** The background, window
   (HUD), OBP0 and OBP1 each get their own 4-colour palette, starting from
   the palettes the GBC boot ROM picks for Metroid II (see "Phase 0" below).
   James's target look is a screenshot of the GBC's own colours: blue and
   white rock, a yellow and red Samus, and a white HUD with black text.
1. **Phase 1: EJRTQ parity.** Every screen shows EJRTQ's GBC
   colours, graded against the patched ROM running in SameBoy in CGB mode.
2. **Built for recolouring.** Colour values are kept apart from the
   tile/sprite-to-palette assignment. A recolour is a data swap with no engine
   change.
3. **Later (out of scope now, but don't block):** Samus Returns-inspired
   palettes per area; enemies with 4-8 colours; a non-black background colour
   on some screens.

## Phase 0: GBC compatibility palettes (found 2026-10-07)

- **Source:** the CGB boot ROM's title-checksum table
  (`vendor/sameboy/BootROMs/cgb_boot.asm`, `TitleChecksums` →
  `PalettePerChecksum` → `PaletteCombinations` → `Palettes`). `METROID2`
  sums to `$46`, which appears twice in the table. The 4th letter `R` picks
  the `???[R]????????` entry: palette index 46, `palette_comb 25, 3, 28`
  (Obj0, Obj1, Bg).
- **The colours** (BGR555, shade 0 first):

  | Layer | Boot ROM palette | Colours |
  |---|---|---|
  | BG (the GBC's window uses it too) | 28 | `$7FFF $7E8C $7C00 $0000` white, light blue, blue, black |
  | OBP0 | 25 | `$03FF $001F $000C $0000` yellow, red, dark red, black |
  | OBP1 | 3 | `$7FFF $1BEF $0200 $0000` white, green, dark green, black |

- **Same mechanism as the port's greys.** In DMG-compatibility mode the GBC
  uses each `BGP`/`OBPn` shade to pick one of the four colours. The port's
  `snes_screen.palette(bgp)` already maps each shade through `grey(shade)`
  (`src/snes_screen.zig:611`). Phase 0 replaces `grey` with one colour table
  per layer, and the colour values live in those tables alone (Goal 2).
- **The window gets its own palette, which the GBC cannot do.** On the GBC
  the window shares the background's palette. Here the HUD is BG2, and its
  map words use palette 0, so it shares CGRAM `$00-$03` with BG3
  (`engine/main.asm` "One window tile id as a BG2 tilemap word"). Point it at
  BG2 palette 1 (CGRAM `$10-$1F`, free) so it can differ. It defaults to BG
  palette 28, which matches the target screenshot.
- **The oracle:** SameBoy in CGB mode, running the plain ROM through its own
  boot ROM, picks this palette by itself. Read its palette RAM and compare it
  with the cart's CGRAM. The current greys must fail that check.
- **What changes on screen:** everything drawn with OBP1 turns green, as on a
  real GBC: Samus's acid and damage flash, frozen enemies, the stunned flash
  and blinking drops. The backdrop and letterbox stay black, because the
  play-field `BGP` maps index 0 to black. Check the title, credits and any
  other `BGP` value too.
- **Gate impact:** about 11 callers of `grey`/`palette` in `snes_screen.zig`,
  plus the test "the palette is four greys with the backdrop shade first"
  (`snes_screen.zig`) and `snes boot` code 15 (which reads `$90`). Any grader
  that compares RGB against grey Game Boy renders should compare shade
  numbers instead, so it survives every later recolour.
- **Colour correction:** copy the values raw (CGRAM uses the same BGR555
  format). SameBoy may display them colour-corrected, so judge the look on
  the FXPak.

## Current state (verified 2026-09-25; line numbers have moved since)

- **BG mode 1** (`engine/main.asm:114`, `!MODE = $01`).
  - BG3 (2bpp) is the play field.
  - BG2 (4bpp, reading the objects' characters) is the status bar.
  - BG1 (4bpp) holds the room readout and the "Super" title art.
- **CGRAM in use:**
  - `$00-$03`: BG3 palette 0, four greys from `snes_screen.grey`
    (levels 31/21/10/0) via `BootPalette`/`LoadPalette` (`engine/main.asm:4159`).
    Entry 0 is also the backdrop. The HUD uses the same entries.
  - `$70-$7F`: BG palette 7, "Super" (`src/title_super.zig`). Nothing else
    writes there.
  - `$80-$8F`, `$90-$9F`: OBP0/OBP1. OAM conversion maps the GB OBP1 bit to
    SNES object palette 1 (`engine/main.asm` ~11563).
- **Free:**
  - BG3 palettes 1-7 (CGRAM `$04-$1F`). Note that `$10-$1F` is also 4bpp BG
    palette 1.
  - Object palettes 2-7.
- **Play-field palette is hard-coded to 0:** `snes_target.play_palette = 0`
  (`src/snes_target.zig:262`), and `tileIdFromWord` rejects any other palette
  (line 311). The engine's own tilemap writers OR in `!PLAY_PRI` and assume
  palette 0.
- **Fades** use master brightness (`ApplyPalette`, `!BgPalette`), not CGRAM, so
  colour palettes should fade correctly. Verify this.

## Known mismatches and constraints

- **GBC BG colour 0 is opaque per palette; SNES BG3 colour 0 is transparent**
  and shows the one shared backdrop. Where EJRTQ palettes differ in colour 0,
  remap (swap indices at conversion) or find another approach. Measure how
  often this happens in EJRTQ's data first.
- GBC: 8 BG palettes x 4 colours, 8 OBJ palettes x 3 visible colours, BGR555.
  This is the same colour format as CGRAM, so values copy exactly. GBC per-tile
  attributes (palette, flip, bank, priority) live in VRAM bank 1. Find out how
  EJRTQ assigns them (per metatile, per room, per tileset?) by reading the
  patch and its running behaviour, not by guessing.
- Letterbox borders (bands with TM=$00) and the HUD's blank pixels show the
  backdrop. Any future non-black backdrop needs a per-band CGRAM 0 change
  (HDMA) to keep them black.
- In mode 1, BG1/BG2 always draw in front of BG3, so a background art layer
  behind the play field would mean moving the play field to a 4bpp layer. That
  is a later-phase question, noted here so Phase 1 doesn't make it harder.
- Colour correction: EJRTQ may be tuned for the GBC's washed-out LCD. Decide
  whether to apply a correction curve (SameBoy offers several) or copy the raw
  values.

## Rules that apply (see memory)

- **Existing oracle:** grade against the EJRTQ-patched ROM in SameBoy. Compare
  **palette index per pixel/tile, not RGB**, so the gate survives James's
  recolour. Also compare RGB against the raw EJRTQ data as a separate rung,
  expected to be retired when colours change. Test that the old answer (all
  palette 0 / greys) fails.
- **Third-party data:** EJRTQ's patch and palettes are handled like the ROM:
  bring your own patch. The builder applies it and extracts the palettes, and
  nothing derived is committed (`src/policy.zig`).
- Derive facts from the patched ROM itself (disassemble what reads the palette
  tables); don't infer them from side effects.
- Playtest asks must name a visible symptom that could fail.
- Each PR gets a new branch from main, never main itself (see memory "Work on
  a branch, PR to main").

## Open questions for requirements

Phase 0:

- Is Phase 0 its own PR before Phase 1 starts? (Recommended: yes.)
- Should the window default to the BG palette (as on the GBC) or get distinct
  colours from the start?
- Is OBP1 turning green acceptable, or should it get a different default?
- Do the title, credits and cutscenes use other `BGP`/`OBP` values, and do
  they look right through the same tables?

Phase 1:

- How EJRTQ stores and selects palettes (tables, per-room loads, per-enemy
  OBJ palettes), and how many distinct palettes a single screen needs at once.
  Can it exceed our 8 BG3 / 6 free OBJ palettes?
- The colour-0 policy and the colour-correction policy (see above).
- Does the HUD (BG2) get EJRTQ colours too, and from which CGRAM range?
- Title, credits and cutscenes: in scope for Phase 1 or not?
