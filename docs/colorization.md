# Colorization: the `full` scheme

The `full` scheme colours each tile and sprite with its own palette. **Which**
palette each tile gets comes from committed assignment tables, derived once
from EJRTQ's GBC colorization of Metroid II (romhacking.net hack 4388, v1.3).
**The colours** are our own, inspired by *Metroid: Samus Returns*. Nothing
here, and nothing committed, holds an EJRTQ colour value or a ROM byte.

This file records how EJRTQ's patch works, as found by disassembling the
patched ROM. Every claim cites an address in the patched ROM: `bb:aaaa` is
bank `bb`, CPU address `aaaa`. Banks `$00-$0F` are the original's (some
edited); `$10` and above are new.

## The patch

- **Input:** `metroid ii - color (ejrtq) v1.3.ips`, from
  `Metroid_II_EJRTQ_Colorization_v1.3.zip`. IPS SHA-1
  `73b6a16f346f3b9b6584c86add217e8e1fbdc86f`. 5,259 records, including RLE.
- **Size and header:** the ROM grows to 1 MiB, MBC1 (`$0147`), and the header
  becomes CGB-only (`$0143`).
- **Bank switching:** `RST $10` (`00:0010`) saves the current bank to `$D44E`
  and switches to bank `$10`. `RST $18` switches back to `[$D44E]`. Code in
  bank `$10` keeps `$D04E` (the original's current-bank variable) in step.

### Where the patch writes

| range | what it is |
|---|---|
| bank `$00`: 22 ranges, 296 bytes | hooks (below), and the helper block `00:3F60-3FFE` |
| bank `$01`: `5AAD`, `7A4B`, `7B87` | the enemy-sprite frozen rule, and the fade level for one mode |
| bank `$03`: `7AA8`, `7C92`, `7CF0`, `7DAD-7E15` | Queen hooks: the head's BG writes get attributes |
| bank `$05`: `4036`, `4086`, `40B4`, `42D0`, `58DE-595D` | graphics-copy hooks in the door interpreter and the title loader |
| bank `$05`: `hudBaseTilemap`, `door_pointers`, `door_data`, `7F34-7FAD` | data edits (below) |
| banks `$05-$08`: 193 tiles redrawn, 59 shade-remapped | art edits (below) |
| bank `$08`: `metatiles_queen` | new metatiles in free space |
| bank `$0F`: `mapF_screens` | ten Queen-area screens point at new screen data |
| bank `$10` | colours (`$4000-$407F`; the Queen's at `$4108-$4117`), init, attribute and palette code |
| banks `$25-$28` | the attribute tables, one byte per tile of banks `$05-$08` |
| bank `$21` | a near-copy of bank `$10`'s head (`$4000-$415F`, 95 of 352 bytes differ). The attribute path doesn't read it; its purpose is unconfirmed |

## The model: a palette per ROM tile

**The key is the source tile.** For a graphics tile at bank N, address A in
the original ROM, its attribute byte is at bank `$20+N`, address A: the first
byte of that tile's 16 bytes. All other bytes in banks `$25-$28` are zero.
Every attribute byte is 0-7, a CGB palette number. No byte sets the VRAM
bank, flip or priority bits, so EJRTQ uses no bank-1 tiles and no flips.

**Copying graphics copies the attributes.** The original's graphics copies
(`00:060E`, `0622`, `063B`, `0655`, `066F`, `36DE`; `05:4036`, `42D0`,
`58DE-58F7`) now call `00:3F68`. It does the copy and calls `00:3F74`. With
the MBC1 upper bits at 1 (`$4100`), `3F74` reads one byte per 16 from the
same address range in bank `$20+[$D065]`. It writes them to a WRAM table at
`$D200 + (VRAM destination − $8000) / 16`. `$D065` is the original's source
bank for the copy, so `[$D065]` is not a separate key. It just tells the
hook which shadow bank to read.

**The table covers VRAM tiles `$8000-$97FF`**, 384 entries at `$D200-$D37F`.
Sprites and background share it:
- **BG and window** (`10:4175`): for each map byte written, tile id `$80-$FF`
  reads `$D200+id` (VRAM `$8800-$8FFF`), and `$00-$7F` reads `$D300+id` (VRAM
  `$9000-$97FF`). That is LCDC's signed tile addressing. The result goes to
  VRAM bank 1 at the same map address.
- **Sprites** (`10:418C`): tile id reads `$D200+id` (VRAM `$8000-$8FFF`).

The same tile in VRAM `$8800-$8FFF` therefore has the same palette whether a
sprite or the background draws it.

**Every path that fills the table** is a graphics copy:
- `loadGame_loadGraphics`' copies (`00:060E-066F`). Boot runs EJRTQ's init
  first (`00:023C` → `3F60` → `10:4118`);
- the door interpreter's BG and sprite graphics loads (`05:4036`, `05:42D0`);
- the title and credits loaders (`05:58DE-58F7`);
- the queued transfers that the original spreads over frames (`hVramTransfer`,
  `$FFB1-$FFB6`). `10:41F1` handles each chunk: a chunk that targets tile
  data (`$8000-$97FF`) copies its attributes through `00:3F9F`; a chunk that
  targets a tilemap (`$9800-$9FFF`) gets its attributes built from the table
  (`$D380` → `$D3C0`, `10:424A`) and written to VRAM bank 1 (`10:4441`);
- door command `$E0` (`10:464A`, hooked at `00:2616`), which copies bytes
  from any bank to any address. Only the three Queen scripts use it (below).

**Every path that writes a tilemap applies the table:**
- room rendering through `10:416E`/`4175` (`00:3FC0`, `3FC6`);
- the HUD row, `10:41E3` (`00:3FD2`, from `05:7F72`, hooked at `05:40B4`):
  20 tiles from `[$C215]`;
- block changes (destroyed and respawning blocks): the queue entries at
  `$DE00` grow from 4 bytes to 8, a tile id and an attribute each
  (`00:08B8` → `10:4492`). `10:44AC` writes both VRAM banks;
- tilemap transfers (`10:41F1`, above);
- the Queen's head (`10:428F`, `430B` into `$D420`, flushed by bank 3's
  hooks at `03:7DAD`).

Attributes are fixed when a tilemap is written. If the graphics under a
visible tile change later, its palette is stale until the map is rewritten,
exactly as in EJRTQ.

## Sprites

`10:432D` runs once a frame (`00:031C`, `2C63` → `00:3FCC` → `10:43B5`).
It walks shadow OAM (`$C000`) in two passes:
- **Samus's entries**, `[0, [$D064])`: `$D064` is the original's OAM index
  after Samus is drawn (`00:0565`, `05D1`). Each entry's palette is the tile's
  table slot. If the entry has the DMG OBP1 bit, slot 3 becomes 1 and every
  other slot becomes 3 (`10:41A0-41AF`).
- **Everything after**, `[[$D064], [$FF8D])`: the same, except that an entry
  whose palette bits are already non-zero keeps them (`10:41C4-41C8`).

**Frozen enemies:** the enemy-sprite writer (`01:5A9A`, hooked at `01:5AAD` →
`01:7B87`) sets palette 3 when the enemy's `+$0B iceCounter` is non-zero.
The second pass keeps it.

So the per-sprite slot changes are exactly two: the OBP1 swap, and frozen
→ 3. Damage and hit flashes in the original toggle OBP1, so they go through
the swap.

## Colours and palette effects

EJRTQ ignores the DMG palette registers for colour. It still writes BGP and
OBP0 (`10:441E`), which have no effect in CGB mode, and it skips the OBP1
write (`00:0163` → `0172`). Every effect is a change to the colours instead:

- **Storage:** `10:4118` copies the colour block to `$D180` (the master) at
  boot. `10:458A` builds the working copy at `$D100` from it.
  `$D100` interleaves BG and OBJ: 2 bytes BG, then 2 bytes OBJ.
  `10:45C5` uploads the copy to BCPD and OCPD (`$FF69`, `$FF6B`) in vblank
  when `$D44A` is set.
- **Fades:** `00:2577` replaces the original's BGP-from-`$D066` lookup with a
  fade level, `$D44B = ($2F − [$D066]) / 4`. `10:426C` sets BGP/OBP0 from a
  table, so the original's logic still sees the DMG values. `10:458A`
  darkens every colour by the level: right shifts of each RGB component by
  1, 2 or 3, then black, with the odd levels blended between (`10:44F1-4589`).
- **Pause:** game mode `$08` with BGP not `$93` uses fade level 2
  (`10:437A`).
- **Credits:** game mode `$12` takes the level from `$D066` (`10:4385`).
- **Title flash:** game mode `$01` with BGP not `$93` selects mode `$82`
  (`10:436F`). `10:45E4` writes white to colour 0 of every palette.
- **Queen body flash:** in the Queen's room (`$D08B = $11`), when
  `queen_bodyPalette` (`$C3D2`) is 3, mode `$83` (`10:4364`, `4611`) rewrites
  colours 1-3 of three palettes from other entries of `$D100`.
- **The Queen's colours:** door scripts `$19D`, `$19E` and `$19F` (each ends
  in `enter_queen`) now jump through `if_met_less $99` to new scripts
  `$1F1-$1F3` (`05:7F48`, `7F5A`, `7F66`). Each runs command `$E0` to load
  16 bytes of colour from `10:4108` to `$D1C0`: BG and OBJ palette 4 for the
  Queen fight. Then it runs the original commands.

Colour 0 is black in every BG palette of the colour block.

## The extraction (`zig build full-assign`)

`src/full_ref.zig` reads the model above off the patched ROM, built in memory,
and writes `src/full_assign.zig`. `zig build full-assign -- check` diffs the
committed file against a fresh extraction. What it found:

- **Every slot is explained.** 2,971 source tiles in 47 regions. One other
  non-zero shadow byte, `27:7BC0 = 1`, belongs to a tile in bank 7's free
  space (`07:7B90` on), which is zeros in both ROMs and which nothing points
  at. It is allow-listed with that reason; any other stray fails.
- **The rules** read off the code: OBP1 turns slot 3 into 1 and any other
  slot into 3 (both passes agree); a frozen enemy gets slot 3.
- **The status bar's glyphs are the power suit's.** They are tiles `$9D-$AF`
  of Samus's sheet. The Varia load (`gfxInfo_variaSuit`) copies only `$7B0`
  bytes, tiles `$00-$7A`, so it never replaces them. (EJRTQ's Varia slots past
  `$7A` are all 0, which agrees: those tiles never reach VRAM.)
- **Tile-id edits.** `hudBaseTilemap` and the Queen room's status bar (map F
  screen `$FE`'s bottom row, through new metatiles `$28-$2E`) get the same
  edit: blank `$AF` becomes `$A9` (the digit 9) in the digit fields, which the
  status bar overwrites every frame, and `$9D` (an empty energy tank) at the
  tank columns. So `$AF` derives two slots, 3 and 7. The hand choice is 3,
  `$AF`'s own slot. Every other edited id keeps its own slot.
- **Look-alikes.** No two of EJRTQ's palettes are identical, in either layer.
  One pair of pixel-identical tiles sits in different slots:
  `gfx_plantBubbles` `$1B` (slot 0) and `$60` (slot 4), which EJRTQ draws in
  different colours. So no look-alike class is committed. That pair gets an
  eye check when the colours are chosen.

## Coverage (`zig build full-assign -- cover`)

The static read gives every source tile a slot. The coverage pass says which
of those tiles the game actually shows. It replays James's 100% recording
(`reference/metroid2-100p-recording/`, 25 `.mmo` parts) on the **original**
ROM in Mesen, eight parts at a time, through `gb_trace`'s driver and cart-RAM
channel (`src/full_ref_cover.zig`).

- **Which source tile is in each VRAM tile.** A write callback on tile data
  (`$8000-$97FF`) fires on each tile's first byte. The copy loops read the
  byte from ROM just before writing it: `copyToVram` (00:038A) and
  `VBlank_vramDataTransfer` (00:2BA3) with `LD A,(HL+)`, and
  `VBlank_variaAnimation` (00:2BF4) with `LD A,(DE)`. So the source is HL-1,
  HL or DE in the bank at `$4000`. A candidate counts only if it is the
  first byte of a graphics tile and holds the value written. Graphics regions
  are not 16-byte aligned (the title's starts at 05:5F34), so tile starts are
  matched by exact address.
- **What is shown**, at the end of every frame: the background under the
  scroll less the window, the window, and OAM's visible entries (with OBP1).
- **Parts run in parallel.** A part starts from a savestate, so its initial
  VRAM came from the previous part: those tiles take the previous part's
  final sources afterwards. The first part's are matched by content.
- **Self-checks:** at each part's end, every tracked tile's VRAM bytes equal
  its source's ROM bytes; each part's start VRAM equals the previous part's
  end.

What it found (2026-11-21):
- 28,832 tile copies with a named source, 1,342 without (clears). Stale
  tracked tiles 0, seam tiles 0. 74 shown tiles had no named source.
- **467 of 2,971 source tiles are never shown.** They are `.` in
  `full_assign.zig`'s `seen` strings: their slot is unobserved. The largest
  gaps are `gfx_queenSPR` (48), `gfx_lavaCavesC` (48), `gfx_samusVariaSuit`
  (53), `gfx_creditsSprTiles` (32) and `gfx_arachnus` (29). The Screw
  Attack frames without Space Jump (`gfx_spinScrew*`) never appear; the
  combined ones do.
- Samus stood in most of each area's cells, all of areas 4 and 9.

## Validation (`zig build full-assign -- cgb`)

The static model against the **patched** ROM running in SameBoy as a Game Boy
Color (`src/sbcgb.c`, graded by `src/full_ref_cgb.zig`). SameBoy tracks each VRAM
tile's source tile the same way as the coverage pass. At each state the check
compares:
- every visible background and window cell's attribute (VRAM bank 1) with
  the slot of its tile's source, by LCDC's addressing;
- every visible sprite's palette with its tile's slot through the OBP1 swap
  (the frozen slot on a non-Samus entry is counted, not failed);
- EJRTQ's `$D200-$D37F` table with each tracked VRAM tile's slot.

States: the title, the landing site after a new game, and a boot from the
recording's first save in each area that has one (saves are kept by the
coverage pass). Result (2026-11-21): **no mismatch** in the title, the
landing site, or areas 1, 2, 3, 7, 8 and 10. That's 340-378 background
cells, 20 window cells, 7-17 sprites and 256-384 table entries per state.

- **Invisible differences, documented.** In every gameplay state, four
  status-bar cells (window row 0, columns 8, 14, 15, 16) have attribute 7
  where the model gives `$AF` slot 3 and `$FF` slot 0. These are the digit
  fields: EJRTQ sets the digits' slot (7) when it draws them, and leaves it
  when the field is blanked. Its `$AF` is redrawn as colour 0 only (the
  original's is solid shade 1), and `$FF` is colour 0 only in both ROMs, so
  in EJRTQ the difference can't be seen. The grader counts a mismatch under a
  colour-0-only tile as invisible. For the port, which draws the original
  `$AF`, the status bar's slots are the hand choice (`hud_choices`), and the
  HUD gets its own palette (colorization F3).
- **Not checked from a save:** areas 4, 5, 6 and 9, and the Queen's room. The
  recording saves in none of them. (The surface is the landing site.) The
  model has no area key, so these states would only add tilesets.

## What the port takes, and what it doesn't

**Taken (as committed data, F2):** each source tile's slot (banks `$25-$28`),
the OBP1 swap, the frozen rule, and which slots EJRTQ makes look alike.

**Not taken:**
- **Colours:** the colour block, the Queen override and every effect's
  colour values.
- **Art edits:** 252 tiles in banks `$05-$08`. 59 only remap shades (a
  consistent swap of the four shades): Samus's Power Suit 19, Varia 2, the
  title 2, credits fonts and sprites 21, enemies 11, Gamma 4. 193 are
  redrawn: credits sprites 77, Metroids 35, enemies and Arachnus 24,
  tilesets 25, the title 13, Samus 10, items 9. The port draws the original
  art. Where a tile's slot was chosen for EJRTQ's redrawn pixels, our
  colours land on the original pixels instead.
- **Tile-id edits:** `hudBaseTilemap` (`05:40F0-4103`) and the Queen area's
  screens and metatiles (`0F:50F0-50F9`, `08:4F22-4F3B`). There EJRTQ shows
  tile ids the original doesn't use, so those positions' slots can't be
  read from the table through original ids.

## In the cart

Since colorization Step 6 every tilemap word carries its tile's slot.

- **Key → cart state.** There is no area or tileset key. Each character
  copy also writes its source tiles' slots into `!BgAttr` (`$1800`), one
  byte per BG3 character: the high byte of a play-field word showing it,
  the slot as its palette and BG3's priority bit. That mirrors
  `$D200-$D37F`, indexed by BG3 character rather than by Game Boy VRAM tile:
  BG3's characters `$00-$FF` are exactly what signed addressing reaches.
  The writers are `DoCopy` (door scripts and the load's copies, through
  `CopyAttrs`), `UploadTitleChr` (`UploadTitleSlots`, so GAME OVER too),
  `CreditsChrRow`, and `UploadSamusBgTwin`. `GfxXferNmi`'s `GfxInfo`
  copies go to the objects' characters only, and the Varia load stops at
  `$7A`, below the twin.
- **The slots** come from the builder's `slots` blob (`src/full_slots.zig`):
  a byte per Game Boy tile of every character sheet, keyed by asset id,
  which `SlotFill` DMAs into `!BgAttr` (channel 1, through the WRAM port). A
  tile takes the slot of the `full_assign.zig` region tile holding its first
  byte, after the hand choices in `tile_choices`; a tile in no region is
  slot 0.
- **Tilemap writers** OR `!BgAttr[char]` into each word: `BuildTilemap` and
  `StreamOne` (`MetaPut`, which reads `!BgAttr` whole as the word's high
  byte), `BlockWrite4`, `DestroyBlock`, `SeedWorld`, the
  Queen's floor, body and feet, the credits' rows, and GAME OVER's clear
  and text. A tilemap copy (`bg_queenHead`) goes up from a stage in WRAM
  with its palettes (`CopyAttrs`). The title's map is the one exception: its
  characters are always the same copy, so the converter bakes its slots
  (`convertTilemap`), which keeps the title's load as long as it was. A pass
  over the whole map there took a frame and moved the title one frame
  later. `SampleTile` reads the low byte only.
- **The window** is BG2, 4bpp, so it cannot share BG3's palettes. It has
  four of its own, BG palettes 2-5 (CGRAM `$20-$5F`; 6 and 7 are the
  title's art). A window word's palette is `!HUD_PAL` plus half its tile's
  slot (`WinAttr`, `BarPut`): the HUD's slots 0, 3 and 7 land in 2, 3 and
  5. A table from slot to palette was tried and dropped: the status bar is
  twenty lookups in every vblank, and in the Queen's room that was a lag
  frame. The status
  bar's edits (`hud`, `queen`) give every id its own tile's slot, which a
  test holds, so the engine has no override table.
- **`mono` and `gbc`** load their one background palette into all eight of
  BG3's and their HUD palette into all four of the window's, so the slots
  change nothing they show. `LoadPalette`
  copies them by DMA (channel 2): from NMI, a CPU loop over 96 bytes
  pushed the title's badge out of vblank.
- **Cost.** `MetaPut` reads `!BgAttr` at the id less one, so the byte lands
  high, and puts the id back under it: some 20 cycles a word more than the
  old copy. Three heavier versions each cost the gate a lag frame: a
  stack-based lookup (a warp's strips), a word table rebuilt at each copy
  (GAME OVER's load, and the frame phase the Queen's cases boot into), and
  a per-cell lookup for the status bar (her room's vblank).
- **Spikes.** Every tileset with spikes but one has a slot none of its other
  background tiles use (its acid tiles, `$FF` and, on the surface,
  `gfx_surfaceSPR`'s `$BA-$EF` included). `tile_choices` puts its spikes
  there: `plantBubbles` 1, `ruinsInside` 5, `surface` 1, `lavaCavesA/B/C`
  2/1/3, `finalLab` 5. `ruinsExt` has none: its acid tiles alone use
  slot 5 and its other tiles the rest, so its twelve spikes keep their
  derived slots. Acid tiles (bit 4) are not counted as spikes; they take
  the acid colour set.
- **Objects** (Step 7). `!ObjSlot` (`$7E3500`) is `!BgAttr`'s twin for the
  256 object characters, holding plain slots (0-7): an object sheet's blob
  bytes are its slots, not `attr` bytes (`UploadSamusBgTwin` converts the 48
  it lends BG3). Every copy into the object characters writes it
  (`ObjSlots`, from `CopyAttrs`, `UploadSamusChr`, `UploadTitleObj`, the
  credits' rows, and `LoadGraphics`/`VariaAnimStart` when a `GfxInfo` row is
  queued, not when NMI moves it). `PutObject` indexes `PutAttr` by the Game
  Boy attribute's high nibble with the tile's slot in bits 0-2, on page
  `!ObjPage`: 0 for `mono` and `gbc` (OBP1 as palette 1, the slot ignored),
  1 for `full`, and for an enemy in `full` `EnemyObjPage`'s: 2 a hit
  Metroid, 3 frozen (`iceCounter` non-zero, every part in slot 3: EJRTQ's
  01:`7B87`). `LoadPalette` sets the page from the scheme, and `DrawEnemies`
  puts it back after the enemies. The builder patches pages 1-3 from
  `full_slots.objAttr`: the slot through the OBP1 swap (3 → 1, else 3).
  EJRTQ tells Samus's entries from the rest by OAM index; the port needs no
  split, since only enemies get pages 2 and 3. The cost is some fourteen
  cycles an object. A first version that masked and stored the attribute
  and set the page in every `PutObject` (about fifty) lagged the Queen's
  room a frame.
- **Metroid damage** (Step 7; ours, not EJRTQ's). `EnemyObjPage` gives a
  Metroid's parts (AI Alpha, hatching Alpha, Gamma, Zeta, Omega or larval;
  the Queen is no slot) page 2 when `full_slots.metroidStep` of its health
  and full health (`+$0C`, `+$11`) is non-zero: 1 at three quarters or less,
  2 at a half, 3 at a quarter. Page 2 draws the body slot (4) in OBJ palette
  2. The OBP1 hit flash and frozen still win. No sprite in play uses slot 2
  but the Queen's sheet and `gfx_enemiesE` `$0C`, so one palette is free
  for it. It holds one step: `DrawEnemies` publishes the pass's worst in
  `!MetStep`, and Step 8 loads palette 2 from it. Several hit Metroids on
  screen (the larval rooms) all show the worst one's step. A Metroid's
  fireball or husk carries its AI but health `$FF`, which is no step.
- **Capacity.** BG uses slots 0-7: at least one tileset (`gfx_ruinsExt`)
  uses all eight, BG3 palettes 0-7 (CGRAM `$00-$1F`). Sprites use slots 0-7,
  which map to SNES OBJ palettes 0-7 (CGRAM `$80-$FF`); palette 2 doubles as
  the Metroid damage palette outside the Queen's room.
- **Colours and CGRAM** (Step 8). `colors.full` holds `full`'s colours,
  shade-indexed like every scheme's: 8 BG slots per colour set
  (`areas.setOf`: the 12 areas, 11 `nest` variants, `acid`; 24 sets), and
  global window, OBJ and Metroid damage tables. `colors.fullTable` applies
  the live registers (BGP `$93` to BG and window, OBP0 `$93` to every OBJ
  palette: an OBP1 object changes palette, not register, as in EJRTQ). The
  table is the `slots` class's blob 1; the engine's two banks have no room
  for it, so the builder points `FullTablePtr` at it. (The debug menu's
  digits moved out the same way, `DebugHexFontPtr`, to make room for the
  code.) `LoadPalette` loads all of it in the `surface` set: the title, game
  over and the credits (`FullSurface`). In play, `FullFrame`, at the end of
  `DrawEnemies`, reads the camera cell's area byte and the metatile table,
  picks the set as `areas.lookOf`, and asks NMI for the BG3 palettes when
  the set changes and for OBJ palette 2 when the damage step changes (bits 1
  and 2 of `!SchemeDue`, which `SchemeNmi` already tests). Fades and flashes
  stay INIDISP brightness, as in `gbc`.
- **Cost outside `full`** (Step 8). `mono` and `gbc` pay one branch a play
  frame, and nothing in NMI. `Reset`'s path through `LoadPalette` is the
  cycles it was: `AudioBoot`'s upload is a byte-by-byte handshake with the
  SPC700, and nine cycles before it stretched it 19 lines, which moved the
  title and everything after it a frame against the Game Boy's (the `title`
  and `queen` rungs). The title also discards a stale NMI flag before NMI
  on, so a setup that ends inside a vblank still gets a whole vblank for
  its first frame.

## Decisions

- **Art:** the port keeps the original art. Samus, the Metroids and the
  credits get an eye check when colours are chosen.
- **Tile-id edits:** for the HUD and the Queen area, the oracle derives a
  slot per original tile id and reports any id that gets more than one.
  Hand-picked overrides are committed with the assignment data.
- **Fades and flashes:** the port keeps the original's effects as `gbc`
  does: CGRAM holds each slot through the live registers, and fades and
  flashes are INIDISP brightness and colour math (amended 2026-11-22: the
  port never remapped CGRAM on register writes). It does not take EJRTQ's
  colour darkening. Colour 3 is still each slot's darkest colour, and a data
  test checks it.
- **The title, game over and the credits** use the `surface` set.
- **The Queen's room** is its own colour area, in place of EJRTQ's
  door-script override of palette 4.
