---
created: 2026-11-21T02:12:08Z
updated:
  - 2026-11-21T02:12:08Z
  - 2026-11-21T04:55:07Z
  - 2026-11-21T05:02:20Z
  - 2026-11-21T05:21:46Z
  - 2026-11-21T05:24:48Z
  - 2026-11-21T06:18:43Z
  - 2026-11-21T19:21:16Z
working_directory: /Users/james/git/m2snes
---

# Requirements

## Status: Final

## Overview

Phase 1 of the colorization (`00-prompt.md`). Phase 0 shipped as the `gbc`
scheme (`2026-10-07-gbc-color-option`, PR #7). This cycle adds a third
scheme, `full`.
- **Which palette each tile and sprite uses** comes from our own committed
  assignment tables. A dedicated, on-demand oracle derives them once from
  EJRTQ's GBC colorization (romhacking.net hack 4388, v1.3), replaying
  James's recorded playthrough.
- **The colours** are our own palettes, inspired by *Metroid: Samus
  Returns* (3DS), with each area coloured after its counterpart there.
- None of EJRTQ's colours are used or committed. The cart and the permanent
  gate never need or mention the patch.

## Features

### F1. The EJRTQ oracle (on demand, outside the gate)

A dedicated tool, run by hand (a `zig build` step), not part of `verify` or
`verify-full`.

**Acceptance Criteria:**
- Inputs:
  - the ROM (`M2_ROM`);
  - the EJRTQ patch: the v1.3 IPS, SHA-1
    `73b6a16f346f3b9b6584c86add217e8e1fbdc86f`, from
    `reference/Metroid_II_EJRTQ_Colorization_v1.3.zip`;
  - James's recorded 100% playthrough, `reference/metroid2-100p-recording/`
    (25 Mesen `.mmo` parts).
  Any other patch is refused, with a message naming the expected hash.
- It applies the patch in memory and reads EJRTQ's assignment statically from
  the patched ROM. The recording can't be replayed on the patched ROM (every
  part starts from a DMG savestate of the original, and the patched ROM is
  CGB-only), so the static model is checked in two ways:
  - **Coverage:** the recording is replayed on the **original** ROM in Mesen,
    recording per frame the table keys and the visible BG/window tile ids and
    sprite tile ids (with OBP1 bits).
  - **Correctness:** the patched ROM runs in SameBoy (CGB), booted fresh and
    from save files in each area. VRAM bank 1 attributes and OAM palettes
    must equal the static model at each state.
- Between the static read and these checks, it derives:
  - **BG, window and sprites:** the palette slot of each source graphics
    tile (bank, address) in the original ROM. Design found that EJRTQ keys
    by source tile (`docs/colorization.md`). Sprites and background share
    the slots.
  - **Tile-id edits:** where EJRTQ changes which tile ids are shown (the HUD
    tilemap, and the Queen area's screens and metatiles), it derives a slot
    per original tile id at those positions. Any original id that gets more
    than one slot is reported as a conflict, and its slot is chosen by hand.
    The choice is recorded as an override in the committed data.
  - **Look-alike slots:** which slots show identical colours at the same
    moment in the same room. Hidden passages and breakable blocks depend on
    this.
  - **Run-time palette changes:** the per-sprite rules (the OBP1 swap, which
    carries damage and hit flashes; frozen enemies → slot 3). EJRTQ's colour
    effects (fades, the title flash, the Queen's body flash) are not taken.
    The port keeps the original's DMG-register effects instead (F4).
- It writes our committed assignment data (F2) as Zig source. It never
  writes an EJRTQ colour value to disk.
- Re-run against the committed data, it reports agreement or lists every
  difference. So the data can be regenerated or checked after hand edits.
- It reports coverage: the rooms, tiles and sprites that the recording never
  showed. Each such key gets a defined default slot in the generated data,
  marked as unobserved, so it can be reviewed by hand.
- Any SameBoy mismatch either revises the model or is documented with its
  cause in `docs/colorization.md`.

**Out of Scope:**
- Other EJRTQ versions, the v1.3 beta and addendums (e.g. "Canon Samus").
- Running the oracle in CI.

### F2. Committed assignment and area data

**Acceptance Criteria:**
- **Assignment tables** (from F1): tile → BG slot, sprite → OBJ slot, the
  look-alike classes, and the run-time palette-change rules. These are
  committed as our own data and may be hand-edited afterwards. They hold no
  colours.
- **Area map:** every Metroid II room is assigned an area: the surface or
  areas 1-10, as numbered on
  `~/Pictures/screenshots/metroid-ros-reference/metroid-2-areas.gif`, plus
  the Queen's room as its own colour area (EJRTQ gives the Queen fight its
  own colours). This is committed as data. Design defines how the cart knows the current room/area
  from game state, and shows it is right for every room, including shafts
  between areas.
- Each Metroid II area is paired with the same-or-similar Samus Returns area
  (the surface and areas 1-8, numbered on `metroid-samus-returns-areas.png`).
  Design proposes the pairing, and James approves it.
- **Colour sets beyond the areas** (amended 2026-11-21, James): two room
  kinds take another colour set in place of their area's:
  - `acid`: the caves whose acid level changes with the Metroid count (rooms
    drawn with one of the lava metatile tables). One set, the same
    everywhere: the acid caves are like an area of their own;
  - `nest`: rooms with a Metroid spawn record. A variant of each area's
    set, leaning green.
  Precedence: queen > nest > acid > area. Both are derived from the ROM at
  build time, so the cart's per-screen table gains no committed data beyond
  the rule.
- No committed file contains ROM bytes (the `src/policy.zig` scan still
  passes) or EJRTQ colour values.

### F3. Samus Returns-inspired colours

**Acceptance Criteria:**
- Our palettes are committed source, chosen by eye from the reference
  screenshots in `~/Pictures/screenshots/metroid-ros-reference/`. No colour
  is sampled from EJRTQ. The screenshots are not committed.
- **Per area:** each area has one 4-colour table per BG slot it uses,
  inspired by its paired Samus Returns area.
- **Samus** uses Samus Returns' colours: the Power Suit, and the Varia Suit
  after it is collected. Her colours are the same in every area.
- **Other sprites:** Metroids, enemies, beams and drops, per OBJ slot.
- **HUD:** its own palette(s), legible in every area: blue with white text,
  as Samus Returns' message boxes (`2.40.27`). The item-name window uses the
  same.
- **Acid caves:** mostly purple, as Samus Returns' acid areas (`2.52.56`,
  `2.43.02`).
- **Metroid rooms:** each area's colours leaning green, as Samus Returns'
  Metroid rooms
  (`2.46.33`, `3.04.25`, `3.16.21`).
- **Damaging tiles** (corals, spikes: tiles the ROM's damage data marks as
  hurting Samus): strongly red, as Samus Returns' corals (`2.56.04`). They
  take a slot of their own, overriding EJRTQ's, where the tileset has one
  free; design reports any tileset where they can't.
- **Look-alike slots** get identical colours wherever F2 says they must, so
  hidden passages stay hidden.
- **Colour 0** is black in every BG slot. SNES BG3 colour 0 shows the shared
  backdrop, so a non-black one wouldn't work. (Design confirmed EJRTQ's
  colour 0 is black in every BG palette.)
- **Colour 3** is the darkest colour in every BG and OBJ slot, so that the
  original's fades, which push every shade towards 3, end dark.
- **Art:** the port draws the original art. EJRTQ's 252 redrawn or
  shade-remapped tiles are not used. Where a slot was chosen for EJRTQ's
  pixels, our colours sit on the original ones. Samus, the Metroids and the
  credits are checked by eye when choosing colours.
- Recolouring is a data change: editing a table changes colours with no
  engine change (colorization Goal 2).
- James approves the colours (F5). Tuning afterwards is data-only.

**Out of Scope:**
- Enemies with more than 4 colours, background art layers, and a non-black
  backdrop. These are later phases, and this cycle must not make them harder.
- Colour correction. Values are copied raw.

### F4. The `full` scheme on screen

**Acceptance Criteria:**
- `full` is scheme id 2, in every cart. L on the title cycles `mono` →
  `gbc` → `full` → `mono`, and the badge reads `FULL`. The default stays
  `gbc`.
- **Every screen is coloured:** title, file select, play field, HUD,
  sprites, game over, the ending and the credits.
- Each tile and object uses its slot from F2, coloured from F3's tables for
  the current area. The colours change when the area changes.
- Run-time palette changes (F1's list) happen at the same moment as in the
  game, in our colours.
- **Metroid damage** (new; neither the original nor EJRTQ does it): a
  Metroid (larval, Alpha to Omega; not the Queen) shifts towards red as its
  health falls, in a few steps by the fraction of its species' full health
  left. The OBP1 hit flash still shows over it. The Queen is left out: her
  AI already shows her health.
- **Fades and flashes** work as in `gbc`: the DMG registers (BGP, OBP0,
  OBP1) remap the four shades within every slot, at the original's timing.
  Fades dim and restore the colours. This is checked, not assumed.
- **Capacity:** design shows that one screen never needs more palettes than
  the SNES layout gives. Today the HUD's 4bpp palette 1 (CGRAM `$10-$1F`)
  overlaps BG3 palettes 4-7, and object palettes 2-7 are free. If the
  assignment uses all 8 BG slots, the HUD moves.
- The SRAM layout, the save records and the title's timing are unchanged.
  An older cart (two schemes) reading a `full` slot takes the existing
  bad-byte fallback.

### F5. The permanent gate

No rung references EJRTQ, its patch or its recording.

**Acceptance Criteria:**
- **Assignment rung:** with `full` active, at the gate's existing states
  (title, landing site, one room per area, a Metroid fight, the Queen, the
  credits), every visible tile's BG3/BG2 map palette and every object's
  palette equal what the committed F2 tables give.
- **Colour rung:** CGRAM equals F3's tables for the current area.
- **Unit tests** on the data:
  - look-alike slots have identical colours in every area;
  - colour 0 is black in every BG slot;
  - colour 3 is the darkest colour in every slot;
  - every room has an area;
  - every area has a pairing and complete tables;
  - no scheme puts the `Fatal` magenta in colour 0;
  - the set precedence (queen > nest > acid > area), on synthetic rooms;
  - the Metroid damage steps, on synthetic health values.
- **Fault checks:** all-slot-0 fails the assignment rung. One area's tables
  shown in another area fail the colour rung. A look-alike class given two
  colours fails its test.
- The new code paths have unit tests on small synthetic data, so the
  ROM-free CI covers them.
- The existing shade graders keep grading the default scheme (`gbc`). Any
  pixel rung that runs in `full` decodes with per-tile palette knowledge
  (Phase 0 F5's open question, answered here).
- Every existing rung passes. `retail`, `debug` and `crawl` are re-pinned
  with `zig build repin`, with the reason given.

### F6. Docs and playtest

**Acceptance Criteria:**
- `docs/feature_tracker.md` and the README's playing section mention
  `full`. A doc describes how to run the F1 oracle (patch version and hash,
  where the recording goes). THIRD-PARTY-NOTICES credits EJRTQ (EJR Tairne,
  Justin Olbrantz) for the palette assignment the tables were derived from.
- **FXPak playtest:**
  - L on the title reaches `FULL`, and the title recolours.
  - The landing site, then one room in each of at least three other areas,
    shows colours that differ between areas and suit that area's Samus
    Returns inspiration. Samus wears her Samus Returns colours.
  - A known hidden passage is not visible.
  - An acid cave is purple, a Metroid room green, corals red, the HUD blue
    with white text, and a Metroid reddens as it is hit.
  - Fails: a single-palette play field (every tile the same colours), two
    areas with the same colours, or a visible hidden block.
  - James signs off on the colours.

## Constraints & Dependencies

- The patch and the recording live in `reference/` (gitignored). The patched
  ROM is GBC-only.
- The port is a native rewrite, not an emulator. EJRTQ's code never runs in
  the cart. Its assignment reaches the cart only through the committed F2
  tables.
- Nothing ROM-derived or EJRTQ-colour-derived is committed.
- No game logic or timing changes. The TAS and the play, cutscene and title
  oracles stay valid.
- Bank 0 is nearly full: new engine code goes elsewhere or through `%call0`.
- Tooling is Zig plus `zig build` steps, not Python.
- Work goes on a new branch from main, with a PR.
