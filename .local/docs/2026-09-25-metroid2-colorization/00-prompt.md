# Metroid II SNES port: colorization

Colorize the m2snes port (`~/git/m2snes`). Phase 1 reproduces EJRTQ's Game Boy
Color colorization (romhacking.net hack 4388). Later phases replace its colours,
which James does not like, working toward a Samus Returns (3DS) look.

## Goals

1. **Phase 1 (this cycle): EJRTQ parity.** Every screen shows EJRTQ's GBC
   colours, graded against the patched ROM running in SameBoy in CGB mode.
2. **Built for recolouring.** Colour values are kept apart from the
   tile/sprite-to-palette assignment. A recolour is a data swap with no engine
   change.
3. **Later (out of scope now, but don't block):** Samus Returns-inspired
   palettes per area; enemies with 4-8 colours; a non-black background colour
   on some screens.

## Current state (verified 2026-09-25)

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
- Commit to the existing branch (`remote-init`), never main.

## Open questions for requirements

- How EJRTQ stores and selects palettes (tables, per-room loads, per-enemy
  OBJ palettes), and how many distinct palettes a single screen needs at once.
  Can it exceed our 8 BG3 / 6 free OBJ palettes?
- The colour-0 policy and the colour-correction policy (see above).
- Does the HUD (BG2) get EJRTQ colours too, and from which CGRAM range?
- Title, credits and cutscenes: in scope for Phase 1 or not?
