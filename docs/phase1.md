# Phase 1: the whole game

Phase 1 (the 1.0 cycle) finishes the game: title → landing site → all 47 Metroids → Queen →
ending → credits, playable on hardware. This file is the counterpart of `slice.md`. It holds
the backlog the cycle works from, derived from the ROM, and every scoping decision the cycle
makes, with the measurement that produced it.

As in `slice.md`, everything here is derived from the ROM or from a run of this repository's
own tools, and the rule is stated so the fact can be re-derived.

## Sources

| what | where it comes from |
|---|---|
| AI census, Metroid roster, warp destinations, door-op coverage | `zig build roster` (`src/roster.zig`) |
| which AIs the port has | `AiTable` in the assembled `engine.bin` (`enemy_oracle.tableAis`) |
| the gate's time and region fill | `zig build verify`, its wall-clock and its `snes layout` line |
| `snes boot`'s exit codes | the header and the literal `emu.stop`s of the generated `.zig-cache/boot-check.lua` |

## The AI census (1.0 Step 1)

**Rule.** For every cell of every map bank ($9–$F), read the cell's spawn list through
`enemy_data_pointers`, as the spawn walk does. Take each record's sprite id to its header
through `enemy_header_pointers`; the header's trailing word is the AI (`roster.census`).
The slice's census came from a recording that stopped at Alpha 2. This one is the whole ROM,
and the recording's thirteen are inside it (a unit test holds that).

**39 AIs are reached by spawn records, and 2 more are reached only through a parent.**
Together they are all 41 `enAI_` routines in bank 2, each exactly once (`roster.zig`'s first
test). 15 are in `AiTable`; the other 24 are `enemy_oracle.pending`, each tagged with the
plan step that ports it. The census test fails when an AI is neither ported nor pending,
when it is both, or when a pending AI is one no record reaches. Shown failing with
`babyMetroid` dropped from `pending`: `02:7BE5 babyMetroid: neither ported nor pending`.

The requirements counted "26 unported". That is these 24 plus the 2 children. **No unported
AI is unreachable**, so nothing had to be recorded as dead code.

**Corrected by 1.0 Step 24b: there are three children, not two.** The 100% recording
dispatched Arachnus's fireball, 02:$52DF, which this census missed (see Step 24b below).

- **Children.** `blobProjectile` (02:$536F) and `drivelSpit` (02:$5BD4) have no header. Their
  parent writes the address into a child slot, at 02:$50E0/$50ED/$50FA/$5107 inside
  `blobThrower` and at 02:$5B77 inside `drivel`. A ROM test finds exactly those operand
  sites and checks that each lies inside its parent. The census test holds each child to be
  ported exactly when its parent is.
- **`enAI_NULL` is spawned.** Sprite `$DB` at `$E:$21` names it. It is ported (a bare `rts`)
  and graded by nothing, which is correct for a routine that does nothing. It is listed in
  `graded_elsewhere` together with the Senjoo, which the ROM census brought in (the segment
  grades it).

### The census

| AI | name | records | banks | first record |
|---|---|---|---|---|
| 02:$4DD3 | `itemOrb` | 63 | 9ABCDEF | $9:$01 #65 |
| 02:$4EA1 | `blobThrower` | 2 | 9 | $9:$19 #1F |
| 02:$5109 | `arachnus` | 1 | D | $D:$C0 #70 |
| 02:$54A1 | `glowFly` | 23 | ABC | $A:$66 #18 |
| 02:$5542 | `rockIcicle` | 25 | A | $A:$08 #1B |
| 02:$5651 | `NULL` | 1 | E | $E:$21 #0F |
| 02:$57DE | `crawlerA` | 26 | 9ABCF | $9:$66 #2B |
| 02:$58DE | `crawlerB` | 32 | 9ABCF | $9:$66 #2A |
| 02:$59C7 | `skreek` | 6 | AB | $A:$31 #35 |
| 02:$5ABF | `smallBug` | 126 | 9ABCF | $9:$27 #23 |
| 02:$5AE2 | `drivel` | 4 | B | $B:$51 #16 |
| 02:$5C36 | `senjooShirk` | 14 | 9E | $9:$1C #16 |
| 02:$5CE0 | `gullugg` | 19 | 9B | $9:$B8 #27 |
| 02:$5E0B | `chuteLeech` | 59 | 9B | $9:$1A #1D |
| 02:$5F67 | `pipeBug` | 13 | B | $B:$16 #20 |
| 02:$60AB | `skorpVert` | 16 | ABC | $A:$C0 #1F |
| 02:$60F8 | `skorpHori` | 8 | AC | $A:$90 #14 |
| 02:$6145 | `autrack` | 7 | DE | $D:$53 #10 |
| 02:$61DB | `hopper` | 16 | 9ACDEF | $9:$21 #1E |
| 02:$62B4 | `wallfire` | 27 | D | $D:$18 #1D |
| 02:$638C | `gunzoo` | 2 | E | $E:$6B #10 |
| 02:$6540 | `autom` | 2 | E | $E:$B5 #20 |
| 02:$65D5 | `proboscum` | 6 | 9 | $9:$7D #1E |
| 02:$6622 | `missileBlock` | 2 | A | $A:$77 #60 |
| 02:$66F3 | `moto` | 13 | 9BC | $9:$20 #1D |
| 02:$6746 | `halzyn` | 47 | 9ABC | $9:$30 #25 |
| 02:$6841 | `septogg` | 12 | BF | $B:$24 #30 |
| 02:$68A0 | `flittVanishing` | 16 | B | $B:$F5 #20 |
| 02:$68FC | `flittMoving` | 11 | B | $B:$F1 #30 |
| 02:$695F | `gravitt` | 6 | 9 | $9:$77 #33 |
| 02:$6A14 | `missileDoor` | 12 | DE | $D:$44 #64 |
| 02:$6B83 | `metroidStinger` | 1 | E | $E:$22 #43 |
| 02:$6BB2 | `hatchingAlpha` | 3 | BDF | $B:$66 #49 |
| 02:$6C44 | `alphaMetroid` | 12 | ABDE | $A:$17 #40 |
| 02:$6F60 | `gammaMetroid` | 16 | ABCE | $A:$36 #41 |
| 02:$7276 | `zetaMetroid` | 3 | ABE | $A:$F8 #45 |
| 02:$7631 | `omegaMetroid` | 4 | BF | $B:$76 #4A |
| 02:$7A4F | `normalMetroid` | 8 | DE | $D:$00 #47 |
| 02:$7BE5 | `babyMetroid` | 1 | F | $F:$A7 #42 |

Children (no header names them; ported with the parent):

- 02:$536F `blobProjectile`, from `blobThrower` (02:$4EA1)
- 02:$5BD4 `drivelSpit`, from `drivel` (02:$5AE2)


## The Metroid roster (1.0 Step 1)

**Rule.** Every spawn record whose AI is a Metroid species: the hatching Alpha, Alpha,
Gamma, Zeta, Omega and the larval Metroid (`roster.metroid_species`). Spawn numbers are
per bank, because each bank's saved flags have their own window, so a Metroid's identity is
`(bank, number)`.

**The check is the ROM's own count.** A new game's record (`initial_save`, 01:$4E64, offset
$21) starts `metroidCountReal` at **$47**. The roster holds **46** records, each a distinct
`(bank, number)`, and the Queen, who has no spawn record, makes 47. The test fails with any
one record dropped. It also fails with `metroidStinger` counted in: that sprite is an event
that plays the hive song and adds 8 to the *displayed* count (02:$6B83), not a Metroid, and
counting it gives 48.

The area names are our own: the bank, and which quarter of its 16×16 grid the cell is in.
The areas fans name are not in the ROM.

**The debug menu numbers them in playthrough order** (James, 2026-09-27; 1.0 Step 26): the
order the 100% recording kills them in (1.0 Step 24a's kill table, less #9, the same Metroid
as #8 after part 06's death). It is `debug_tables.playthrough`, a record and the kill's cell
each; a unit test holds every record to the one nearest its kill, across and down, with a
record killed in its own cell no other kill's candidate ($B:$C9 is a cell from $B:$CA and
$B:$D9). The WARP page's METROID ROOMS take the same order and numbers. *menu* below is that
number; *#* is the roster's, which "Metroid 01" and the like in this cycle's earlier text mean.

| # | species | cell | spawn number | area | menu |
|---|---|---|---|---|---|
| 1 | Alpha | $A:$17 | $40 | bank A north-west | 26 |
| 2 | Gamma | $A:$36 | $41 | bank A north-west | 25 |
| 3 | Gamma | $A:$F5 | $44 | bank A south-west | 31 |
| 4 | Zeta | $A:$F8 | $45 | bank A south-east | 29 |
| 5 | Gamma | $B:$01 | $42 | bank B north-west | 32 |
| 6 | Zeta | $B:$04 | $4E | bank B north-west | 33 |
| 7 | Alpha | $B:$22 | $40 | bank B north-west | 6 |
| 8 | Gamma | $B:$2E | $41 | bank B north-east | 23 |
| 9 | Alpha | $B:$39 | $43 | bank B north-east | 20 |
| 10 | Gamma | $B:$3B | $44 | bank B north-east | 21 |
| 11 | Gamma | $B:$45 | $45 | bank B north-west | 24 |
| 12 | Gamma | $B:$57 | $47 | bank B north-west | 27 |
| 13 | Alpha (hatching) | $B:$66 | $49 | bank B north-west | 34 |
| 14 | Omega | $B:$76 | $4A | bank B north-west | 37 |
| 15 | Omega | $B:$8D | $4C | bank B south-east | 35 |
| 16 | Gamma | $B:$A7 | $46 | bank B south-west | 18 |
| 17 | Gamma | $B:$AB | $4F | bank B south-east | 19 |
| 18 | Alpha | $B:$BE | $50 | bank B south-east | 3 |
| 19 | Alpha | $B:$C4 | $51 | bank B south-west | 5 |
| 20 | Alpha | $B:$CA | $52 | bank B south-east | 4 |
| 21 | Alpha | $B:$D9 | $53 | bank B south-east | 11 |
| 22 | Gamma | $B:$DF | $54 | bank B south-east | 10 |
| 23 | Gamma | $B:$E4 | $55 | bank B south-west | 13 |
| 24 | Alpha | $B:$EC | $56 | bank B south-east | 12 |
| 25 | Gamma | $C:$38 | $41 | bank C north-east | 14 |
| 26 | Gamma | $C:$88 | $40 | bank C south-east | 22 |
| 27 | larval | $D:$00 | $47 | bank D north-west | 45 |
| 28 | Alpha | $D:$04 | $46 | bank D north-west | 9 |
| 29 | larval | $D:$10 | $40 | bank D north-west | 46 |
| 30 | larval | $D:$23 | $41 | bank D north-west | 42 |
| 31 | larval | $D:$33 | $42 | bank D north-west | 41 |
| 32 | larval | $D:$42 | $43 | bank D north-west | 40 |
| 33 | Alpha (hatching) | $D:$76 | $44 | bank D north-west | 8 |
| 34 | Alpha | $D:$93 | $45 | bank D south-west | 7 |
| 35 | larval | $E:$03 | $41 | bank E north-west | 44 |
| 36 | larval | $E:$05 | $42 | bank E north-west | 43 |
| 37 | Alpha | $E:$07 | $49 | bank E north-west | 2 |
| 38 | Gamma | $E:$08 | $4A | bank E north-east | 28 |
| 39 | larval | $E:$33 | $44 | bank E north-west | 39 |
| 40 | Zeta | $E:$3A | $45 | bank E north-east | 30 |
| 41 | Gamma | $E:$85 | $46 | bank E south-west | 15 |
| 42 | Gamma | $E:$A4 | $47 | bank E south-west | 16 |
| 43 | Alpha | $E:$B2 | $48 | bank E south-west | 17 |
| 44 | Alpha (hatching) | $F:$10 | $41 | bank F north-west | 1 |
| 45 | Omega | $F:$B0 | $43 | bank F south-west | 38 |
| 46 | Omega | $F:$E0 | $40 | bank F south-west | 36 |

## The warp page's destinations (1.0 Step 1)

`roster.destinations` builds them, and `zig build roster` prints the full table. Step 5 turns
each one into a door-script chain and a standing spot, and grades every arrival against our
Game Boy. **This list is where each destination is, not how to arrive there**, and Step 5's
scenarios are what hold it to the ROM.

**The door graph.** A *room* is a set of in-use cells joined wherever neither side's scroll
bit blocks the shared edge. A *crossing* starts at a cell edge whose scroll bit is set; the
camera cell's door index is its transition word with bit 11 (sprite priority) cleared,
00:$0C6E. The crossing goes to the script's `WARP` cell, or with no `WARP` to the next cell
over. The grid wraps, because screen coordinates are four bits. Every `IF_MET_LESS` branch
is followed, since the door graph holds all counts at once. A `WARP` onto a blank cell goes
one cell on in the crossing's direction, the rule `screens.assign`'s `handed_to_neighbour`
uses. Index 0 is a held crossing with no script. The graph has 239 rooms and 2340 crossings.

| kind | count | how |
|---|---|---|
| save stations | 7 | see below |
| items | 63 | the item orb's records: even sprite ids are orbs, odd ids are bare items (`items.collectedFor`) |
| Metroids | 46 | the roster |
| the room before each Metroid | 46 | the first crossing, bank then cell order, from outside the Metroid's room into it. **Every Metroid room has one** |
| the Queen | `$F:$FE` | `ENTER_QUEEN` (door $19D), its world scroll's high bytes |
| the room before the Queen | `$E:$13` | door $13B, whose `IF_MET_LESS` branch runs $19D at count $01 or $00; above that it warps to `$F:$EF` with no Queen (James, 2026-10-01: kept as the ROM has it; `47 QUEEN` is the fight at any count) |
| the ship | `$F:$76` | the new game's record, `save.Initial.cell` |

The 63 item records are: 23 Missile Tanks, 11 energy refills, 8 missile refills, 6 Energy
Tanks, 3 Ice, 2 each of Plasma, Spazer and Wave, and 1 each of Bomb, Hi-Jump, Screw
Attack, Space Jump, Spider Ball and Varia. There is **no Spring Ball record**, because
Arachnus leaves it (C3), so its destination is Arachnus's room at `$D:$C0`.

### Save stations, and a correction to `slice.md`

**Rule.** A cell has a station where one metatile's bottom row is save-bit tiles directly
above a metatile whose top row is (bit 7, `BIT 7,A` at 00:$1F4F). This is read in the
collision table that goes with the tileset `screens.assign` gives the cell. Every tileset
with a station draws it that way: caveFirst `$45` over `$46`, ruinsInside `$28` over `$29`,
plantBubbles `$60` over `$61`. A unit test holds the rule to that shape: half a station, or
one upside down, is not a station.

**A single save-bit tile is not enough, and it was tried first.** That reading found 60-odd
cells in bank $F alone. They are surface cells that `screens.assign` reads as caveFirst,
where tile `$10` is common. The pair rule leaves seven:

| cell | tileset | provenance |
|---|---|---|
| `$A:$99` | caveFirst | scrolled |
| `$C:$CC` | plantBubbles | scrolled |
| `$D:$26` | ruinsInside | door |
| `$D:$57` | ruinsInside | scrolled |
| `$E:$54` | ruinsInside | scrolled |
| `$E:$AA` | ruinsInside | scrolled |
| `$F:$04` | caveFirst | scrolled |

**The list is provisional**, for the reason B12 left open: on scrolled cells the tileset is
inference. Scanned under *every* tileset rather than the assigned one, `$D:$80` and
`$D:$90`–`$93` show a station only under a lava table, which is not what `assign` gives
them. Step 18's every-door tileset grading is what settles those cells. Step 5 grades every
station entry on arrival.

**`slice.md`'s "`ITEM $0` marks a save station" is not right**, and it matters for Step 5.
`ITEM $0` loads the save graphics into the one shared item slot, and doors *leaving* item
rooms run it too, to put the slot back. It runs on 36 scripts, including the ones out of
`$F:$01`. The two warp cells that section calls stations, `$F:$06` and `$F:$F3`, are blank
cells (pointer $4500). `$F:$01` itself has no station metatiles under any tileset. The station
nearest the landing site is **`$F:$04`**, a caveFirst `$45`/`$46`/`$47` stack in column 7.
`room.zig`'s "walk to `$F:$01`" comment inherits the same premise. It is left alone because
that route was abandoned for other reasons.

## Door-script coverage (1.0 Step 1)

**497 of the 512 pointers decode.** The other 15 point past the stream or into bank-5 free
space, as `offsets.zig`'s note on `door_pointers` says. Per opcode: how many scripts carry it,
the first, and what the port does (`roster.handling`). *arm* means `StepDoorScript` has one.
*converted* means the builder rewrites it as a `COPY`. *waited* is `FADEOUT`, whose frames
are waited out and whose palette steps run off that wait (Step 20). *skipped* means stepped
over by length and nothing else.

| op | scripts | first | port |
|---|---|---|---|
| `copy` | 8 | $13B | arm |
| `tiletable` | 149 | $003 | arm |
| `collision` | 95 | $003 | arm |
| `solidity` | 95 | $003 | arm |
| `warp` | 354 | $001 | arm |
| `escape_queen` | 1 | $19E | skipped |
| `damage` | 2 | $03C | arm |
| `exit_queen` | 1 | $19F | skipped |
| `enter_queen` | 1 | $19D | arm (Step 6) |
| `if_met_less` | 101 | $022 | arm |
| `fadeout` | 95 | $003 | waited |
| `load` | 285 | $001 | converted |
| `song` | 66 | $003 | arm |
| `item` | 53 | $006 | arm |
| `end` | 497 | $000 | arm |

## Triage of the open defects (1.0 Step 1, 2026-09-26)

Every open `bug_tracker.md` entry now carries a **1.0 triage** line. There were 13: the 11 the
requirements counted, plus James's two of 2026-09-25 (pause) and 2026-09-26 (the `$F:$10`
refill blocks). One more, the crawler's extra step at the screen edge, had been fixed in
`3834383` with its box never closed. It is closed now.

| entry | triage |
|---|---|
| handover Alpha boots fresh (audio parity, stretch 6) | diagnostic only |
| Chute Leech spawned one frame late (`$9:$E6`) | diagnostic only |
| the `rLY` budget: later slots finish next frame on the GB | accepted compromise, for James to confirm in Step 25 |
| cart camera moves in booted placements (`$C:$21` and others) | diagnostic only; promoted to *fix* in the step whose AI case needs the room |
| Senjoo contact one tick early | fix in Step 25; **fixed in Step 9** (the collision flag) |
| B12's nine cells on the wrong tileset | fix in Step 18 |
| banks $9/$A door-graph veto | fix in Step 18 |
| refill orbs invisible | fix in Step 10 |
| `$F:$10` refill blocks invisible until re-entry | fix in Step 10 |
| `drawSamus_common`'s sprite attribute | fix in Step 25 |
| damage/acid flash palette | fix in Step 25 |
| no pause | **fix in Step 2**: game mode $08 is not ported, and the debug screen opens from it |

The plan named B1's fade-transition and animation-hold items for Step 25. Both were fixed in
0b (Steps 20 and 24c). `feature_tracker.md`'s B1 text still lists them as open, and Step 26
tidies it.

## Baselines this cycle moves (1.0 Step 1, 2026-09-26)

| what | at 1.0 Step 1 | how measured |
|---|---|---|
| gate wall-clock | **9 m 04 s**, 37 rungs green | `zig build verify` on this machine, timed with `date` around it (0b's close: 9 m 12 s) |
| converted assets | 310 KiB packed into 426 KiB reserved; image ends at 554 KiB of a **1 MiB** LoROM cart | `zig build convert` |
| free VRAM | **$2400–$5FFF words, 30 KiB**, in one run | the bases in `snes_target.zig` and `engine/main.asm`: BG3 chars $0000, BG3 map $0800, BG2 map $0C00, BG1 chars $1000–$1FFF, BG1 map $2000 (`!READOUT_MAP`), objects $6000–$7FFF |
| `snes boot`'s free exit codes | **about 47**: 5–9, 81–120, 149, 190 | the generated script's header and literal `emu.stop`s. 0 is pass, 255 is Lua's own failure, and 20–60 are the play window's row codes |

Region fill, packed against reserved (`zig build convert`). Any region past 95% is resized in
`snes_layout.reserved` in the step that crosses it:

| class | fill | class | fill |
|---|---|---|---|
| `chr_obj` | **92%** | `enemies` | 61% |
| `doors` | **83%** | `metasprites` | 58% |
| `map_screens` | 79% | `tilemap` | 56% |
| `chr_bg` | 76% | `metatiles` | 54% |
| `aram` | 65% | `collision` | 50% |
| `physics` | 48% | `map_cells` | 44% |
| `directory` | 38% | `title_art` | 34% |
| `door_pointers` | 25% | `solidity` | 1% |

**Correction to the requirements:** the cart is 1 MiB, not 512 KiB (`snes_layout.romSize`).
Space is not what binds. The per-class reserves are, `chr_obj` first. The Queen's and the
credits' graphics go there and into `chr_bg`.

**The gate's time budget is 15 minutes**, and it is enforced every step. A step that takes the
gate over it splits a slow tier out (`verify-full`) in that step.

**`zig build convert` did not build** when this was measured: its module lacked the audio
and title embeds that the converted set gained in 0c and Step 24j. That is the command the
gate's layout-failure message sends a reader to, so it was fixed in this step (`build.zig`,
`addAudio`).

## 1.0 Step 2a: the pause (2026-09-27)

Game mode $08 is ported: `tryPausing` (00:$2C79) as `TryPausing` and `gameMode_Paused`
(00:$2CED) as `PausedFrame`, both in bank 1, with the status bar's L counter (01:$4A0F) and
`metroidLCounterTable` (00:$203B) as physics blob 40. The `debugFlag` arms are ported up to
the fork where the original's one-row menu begins (00:$2D39); the debug screen replaces that
menu in Steps 2b-2c. Graded by the new `pause` rung (`docs/conformance.md`).

**What the rung found first was not the pause.** The cart's frame counter restarted at a new
game, where the Game Boy's carries the title's count on: 2 against 9 on the first frame of play.
`InitState` now seeds the title's count plus one (`!TITLE_FC_LEAD`), and the rung grades the
counter before anything else on every frame. See `bug_tracker.md`.

**Two ways to hand a pad to a pass.** The title rung sets the press for title frame t on the
cart's poll with the counter at t - 1, against `title_oracle`'s Game Boy, which runs a frame at
a time. The pause rung's Game Boy runs an iteration of `mainGameLoop` at a time, and against it
the cart's pass k reads the poll made with the counter at k - 2 -- the poll at vblank k - 1,
which `PublishPad` hands on at NMI k. Both are measured; a new rung picks the one that matches
how its Game Boy is stepped.

**Bank 0 was full.** 35 bytes were free at Step 1. `ProjBlobs`, the 133-byte resolve table
read once at boot, moved to bank 1 and is read long, which leaves **88 bytes** in bank 0 after
the pause's hooks. New routines go in bank 1 (about 30 KiB free), entered by `jsl`; bank 0
gained `ClearUnusedOamLong` and `DrawHudMetroidLong` for them.

## 1.0 Steps 2b-2c: the debug build and the screen (2026-09-27)

`zig build rom -- --debug` writes `m2snes-debug.sfc`, the retail cart with `DebugAllowed`
set. On it L+R+Start opens the debug menu at any point in play (Step 2d; Step 2b's title
combination and the pause-only opening were James's first hardware try, and dropped). How to
use it is `docs/setup.md` section 6.

**VRAM.** The screen takes $2400-$2BFF of the free run: BG1 characters $140-$172 at
$2400-$272F (a blank, the item font as the title's sheet holds it widened to 4bpp, the
readout's 0-F and colon, a cursor) and its map at $2800-$2BFF. Free VRAM is now
**$2C00-$5FFF words, 26 KiB**. The play field's VRAM is untouched, and the `pause` rung checks
that (code 124).

**WRAM.** $07F4-$07FD for the screen's state, $7E23F0 for the layer masks it found, $7E2400
for its page ($700) and $7E2C00 for the widened font ($400). $07FE-$07FF are the last of
page 7.

**The first frame is long.** Widening the font and drawing the page take one pass past the
vblank on the frame the menu first opens. It is a debug cart's frame, so the rung's debug run
keeps time by the counter rather than requiring one pass a frame.

## 1.0 Step 4: the METROIDS, FLAGS and CLOCK pages (2026-09-27)

**Only the saved half is listed.** A spawn number of $40 or more has its flag saved to the
bank's window of the save buffer when the bank is left (02:$418C); the rest are cleared every
time a room is entered, so a menu has nothing to keep for them. The saved half is 98 records:
the 46 Metroids and 52 others (item orbs and tanks, missile doors and blocks, Arachnus, the
stinger, the baby). METROIDS lists the first and FLAGS the second (James, 2026-09-27).
`debug_tables.zig` builds both from `roster.zig` into a new class, `debug`, appended last:
2354 bytes of its 4 KiB. A record names an orb (an even sprite id) for a major item and the
item itself (odd) for a tank; the label takes the game's own item name either way.

**Where a flag lives.** The bank the flags were last loaded for (`!PrevBank`) keeps its saved
half live in `!SpawnFlags`, which a live slot leads by up to a pass; every other bank's is in
the save buffer. The menu writes the save buffer always, because a room reset saves a window
back with only its $02s and $FEs (02:$41B6): a flag reset to $FF in the live array alone would
come back as the stale $02. For the loaded bank it writes the live array and slot too, and a
slot marked dead is freed as `EnemyDeleteSelf` frees one.

**A kill is `.death`'s bookkeeping** (02:$6D61): the flag, both counts one down in BCD, the
shuffle and `earthquakeCheck`. A Metroid live on the screen is taken off it, and a fight it
was in is ended the way its death ends one (the fight flag at $02, then the post-death wait
and the room's song). The shuffle is the status bar's, in NMI, so it counts down with the
menu up as it does in the pause.

**Not gradable from a new game.** Walking right from the start loops back to bank F through
door $052, and left from bank A goes back through $0D6: no door that tests the count is within
a scripted walk. The door drawing the new count's table after a menu kill, a flag reset seen
as a respawn, and a kill of a Metroid on the screen moved to Step 5, which can warp.

**Bank 0** has 53 bytes left under $FC00 after `EarthquakeCheckLong` and
`EnemyDeleteSelfLong`. **WRAM:** $7E23F6-$7E23FB for the list's top row, the entry's bank
and number, its slot and whether the kill freed one.

## 1.0 Step 5a: the door crawl and the warp table (2026-09-27)

**The ROM does not say which tileset about half the warp destinations have.** A door that
loads only an enemy page (most Metroid rooms) or only a lava table keeps the rest of whatever
the room it leaves had, and a scroll-blocked edge is a door only where Samus can walk through
it. Three static readings were tried first:

- **the door graph with openings** settles 59 destination rooms;
- **`screens.assign`'s** covers the rest, but differs from the graph on 15-30 of them;
- **combined,** 137 of 165 build, and 28 fail, mostly with no standing spot, because the
  guessed tileset makes the room solid (the first Alpha, A:17, as caveFirst collision under a
  lava table).

The GB-against-cart grade the plan gives Step 5 cannot see a wrong guess, because both
machines run the same chain. So the Game Boy decides (James, 2026-09-27).

**The crawl** (`src/crawl.zig`, `zig build crawl`). Our GB loads the room a door leaves, puts
Samus one or two tiles from the door (James's suggestion; the middle of the screen is the
fallback) and walks, drops or jumps her through with a short budget. The engine decides both
whether she passes and what the door loads. Rooms are crawled from the new game. When that
runs dry, a room nobody walked into is seeded from the static reading and the crawl goes on.

An arrival is **truth** when:

- it was walked from truth, or
- it came through a door that loads a whole tileset of its own.

A door that branches on the count is tried again at the counts where it goes somewhere else.

**The crawl's output.** Every door walked, both ends, goes to
`build-out/crawl-<ROM SHA-1>-v<version>.txt`. It takes about 2 minutes, once per ROM and
crawler version. Every step that converts depends on it and reads the file. Walking the
engine rather than triggering doors from a script matters: a triggered crawl accepted crossings
nobody can walk, and put one room at three lava levels at one count.

**The warp table** (`src/warp.zig`, printed by `zig build roster`). A destination's chain is:

- a walked door into its room, after a script that loads the tileset of the room that door
  leaves; or
- the door alone, when it loads a whole tileset.

The chain is kept only if running it leaves what the engine left. Beside the chain goes a
standing spot: the nearest place to the destination's point where both of Samus's probe
columns are clear from her head down over a floor, or, where only a ball fits (items in
tunnels), a ball spot. A "room before a Metroid" whose listed cell cannot be stood in falls
back to another walked door into that Metroid's room.

| | count |
|---|---|
| doors walked | 1058 |
| entries, walked from truth | 56 (her room since Step 6: door $19D loads a whole tileset) |
| entries, walked from a seeded room | 83 |
| entries, the static reading only | 22 |
| findings | 4 (5 until Step 6) |

**The findings** go to James rather than being dropped:

- **$E:$D3, two item records** in a blank cell with no drawn neighbour. The door graph gives
  them no room.
- **The Metroids at $A:$F5 and $B:$3B** have no standing spot under the tileset their rooms
  get: ruinsExt, from a seeded room and inferred respectively. Solid rock and acid are what a
  wrong tileset looks like. The crawl never walked into those rooms from truth.
- **The Queen** waited for `ENTER_QUEEN`. Step 6 ported it, and her room is an entry.

**Two things the crawl turned up** about our own tools, with the harness traps in the memory
notes:

- `roster.collisionFor` pairs a *metatile* table with its collision table by name, and is
  not the table a `COLLISION` operand selects, because the two orders differ.
  `warp.collisionTable` reads the operand through `collision_pointers`.
- A placement on the GB needs `$D00C` and `$D029` as well as `$FFC0`, the CPU state and ROM
  bank restored around a harness call, and IME set for it.

## 1.0 Step 5b: the cart's warp and the WARP page (2026-09-27)

**The mechanism: a redraw, as a load, not a crossing.** The plan left the choice to
this step. A crossing would need Samus stood in the room before and walked
through: that is the crawl's work on the Game Boy, and on the cart it would mean
driving the pose machine from the menu. The scripts that run are the same either
way. So `DebugWarp` (bank 1) does what the boot does with its record's script:
1. under forced blank with NMI off, it runs the entry's chain through
   `RunDoorScript`;
2. it puts Samus and the camera on the entry's spot;
3. it draws with `LoadScreen` and `SeedWindow`.

What a crossing has that this does not is the scroll, and that mattered for one
thing:

**The enemy loader only walks the seam the camera has just crossed** (03:$40BE,
and on the Game Boy too). A room entered with no scroll loads nothing. The first
cut arrived at the $9:$01 item with no orb. So the warp runs one entity pass
with the crossing's reset request, which empties the slots and ends a Metroid
fight as a crossing ends one. It then brings the camera onto the spot from $C0
away, a grid row at a time, with `ScrollEnemies` and the loader at each row: the
scroll a crossing would have given, with no AI running. It sweeps down from above
in the map's lower half and up from below in its upper half, because a sweep
started across the map's edge meets the loader's wraparound clamp. The first
version, always from above, still missed that orb, which sits on the map's top
row.

**Where she stands.** Step 5a's spot was nearest the destination's point, and for
an item that is the orb, which hid her and could not be shot open. An item's spot
is now at least 24 pixels to one side of the orb, and a Metroid's 48. The nearest
spot of any kind is the fallback.

**A warp from the pause arrives paused.** The menu closes to where it was
opened. The first cut unpaused with Start's own sound request, but a second send
of that site is what `audio_sites` exists to refuse, and the pause is the menu's
contract anyway.

**Costs.**
- Bank 0: one byte, `Bank0Rtl`, the `rtl` that `%call0` returns through. A
  bank-1 routine calls a bank-0 `rts` routine with no wrapper per routine, and
  52 bytes are left under $FC00.
- The debug class: 8759 of 12 KiB (WARP's lists 3844, `warp_data` 2561).
- WRAM: `!DebugBackSub` at $7E23FC; `!WarpData`, `!WarpCamY` and `!WarpStep` at
  $7E2B00-$7E2B13, between the menu's map and its font.

**The pages.** WARP sits under the root with four lists under it:
- SHIP AND SAVES, 8 (the ship and 7 stations);
- ITEMS, 61;
- METROID ROOMS, 90 (44 rooms and 46 rooms next to one);
- QUEEN, 1.

That is 160.

A page entry gains the page B goes back to (`DebugPages`, eight bytes a page),
and `!DebugBackSub` is the row a page under a page was opened from.

**For when the builder ships.** `m2snes <rom>` is still Step 1's stub. The carts
are built by `zig build rom`, which runs the crawl first. The warp table is in
every cart, so the retail and debug carts still differ by one byte, and a
shipped builder will have to crawl as well: about 2 minutes on a player's first
build, or cached beside it.

## 1.0 Step 5c: the WARP page graded (2026-09-27)

**The reference is our Game Boy running each chain by door index**: from the new game, each
script is run by setting `$D08E` and calling the interpreter (00:$239C), which is what
`loadDoorIndex` (00:$0C37) leaves for the main loop. What it left is read back and held
against the cart after the same warp (`src/warp_grade.zig`, the `warp` rung):
- `$D808`-`$D814`, the block a save keeps, which the cart mirrors at `!SaveBuf+$08`;
- the damage `DAMAGE` writes;
- the characters the loaded metatile table draws, by hash.

This is not 5a's claim again. 5a held the tables' pointers against the crawl's walk; this
holds the cart's interpreter, loader and VRAM against the Game Boy's.

**What the first runs taught about the reference:**
- **Order matters.** What a chain does not load -- the enemy page's source (`$D808`), the
  damage -- is what the warp before it left. The cart warps entry after entry, so the Game Boy
  does too, in the same eight runs.
- **The bank is the entry's.** A chain's loader can warp to another bank than its door
  (`$003`, which loads ruinsInside, warps to bank E), and a door that loads only an enemy page
  has no `WARP`: a player crossing it stays in her bank.
- **Only drawn characters are graded.** Ids $80-$AF are the Game Boy's `$8800`-`$8AFF`,
  object tiles the cart keeps in the object region alone. Of the ten metatile tables only the
  Queen's draws any of them ($9E-$AF), and her room waits on Step 6.

**What the cart side learned:**
- **The warp runs with NMI off for frames on end.** A press made before the game runs again is
  one it never sees, so a scenario's chord right after a warp did nothing. Arrival is counted
  from the frame counter moving, and the stand check from there.
- **Enemies hit her.** 14 of the 160 are hit within the second, one of them ($F:$04, a save
  station) on the first frame. She is checked stood at the spot on the frame she arrives, and a
  hit ends the check and is counted rather than failed.

**Two warp defects, fixed** (`docs/bug_tracker.md`): a ball arrived with the last room's down
speed and hopped (00:$1747), and a Metroid in a blank cell ($D:$23, $B:$57) had the blank cell
drawn. `warp_data` now carries the camera's cell (`debug_tables.warpCell`), which is what
`LatchCell` would latch.

**Step 4's three, reached by warping:**
- `item`: the first ITEMS entry's orb marked taken on FLAGS is not loaded by the warp; reset,
  the next warp loads it.
- `metroid`: Metroid 01's room, the Alpha's fight begun (range $50 against the spot's 48 px),
  killed from METROIDS: its slot freed, the fight flag at $02, the count $46.
- `gated_door`: the one entry beside a walked door that loads another table at $46 than at $47
  is $B:$13, the room before a Metroid, with door `$1A4` to its right (lavaCavesFull at $47,
  lavaCavesMid at $46). One Metroid killed from the menu, then walked right with the crawl's
  jumps: the door loads `$5480`, the ROM's table for $46.

**Faults.** Every two-script chain in the cart's `warp_data` cut to its door alone must fail a
run on the loaded state or the characters. The scenarios' three: the flag's save-buffer write
gone (30), the kill's slot delete gone (33), the kill's count left alone (35).

**Costs.** The Game Boy's reference takes about 10 s; the eight runs and three scenarios about
15 s, in parallel with each other. WRAM and bank 0: nothing new. `VarScroll` is exported.

## Step 6: the Queen's room, and her raster split on the SNES (C4 spike)

**GO.** Her room is entered, and the raster split the Game Boy makes with its LYC interrupt is
reproduced by HDMA and graded pixel for pixel against our Game Boy. The technique, its cost, and
what Step 19 inherits are below.

### What the Game Boy changes mid-frame

`zig build queen` enters her room on our Game Boy and prints each frame's registers as bands
(`src/queen.zig`). `VBlank_drawQueen` (03:$7CF0) builds a list of (LYC, command) pairs every
vblank; the LCD handler (03:$7C7F) walks it:

| command | what it writes | effect |
|---|---|---|
| 1, the body | SCX = `queen_bodyXScroll`; BGP = `queen_bodyPalette` when that is not zero | her body, which is room tiles scrolled to another column |
| 2, the room again | SCX = `scrollX`; BGP = $93 | back to the room |
| 3, the head's bottom | LCDC bit 5 off | her head is the **window** (WX, WY), 38 lines tall |
| 4, the status bar | window off, SCX 0, SCY $70 | row 31 of the room's map, where `VBlank_updateStatusBar` writes in her room ($9BE0) |

A command with bit 7 set is followed on the same line by the next. **Every command takes
effect on the line after its LYC**: over 400 frames of the fight, 1,529 landings, all four kinds,
none elsewhere. Her head is the window's map ($9C00, `bg_queenHead` and `queen_drawHead`'s three
frames); her body is in the room's own tiles. Samus, the neck and her projectiles are objects.

### The technique

- **BG3 is the Game Boy's background and BG2 its window**, as everywhere else. BG2 is pointed at
  the head each vblank (`!HUD_HOFS`/`!HUD_VOFS`' formulas at her WX and WY).
- **Three HDMA channels**, the tables rebuilt in NMI by walking the list the way the handler
  does (`QueenEffects`, `QueenBands`): channel 7 writes TM as it always has, channel 6 writes
  BG3's scroll (mode 3, both registers twice), channel 5 writes window 2's edges. Window 2 is
  the head's columns: BG2 is masked outside it, BG3 inside it, and only on the lines the Game Boy
  draws the window on (W2 is empty elsewhere). The Game Boy's window is opaque; BG2's colour 0 is
  not, but the backdrop behind it is the same shade, as for the status bar since Step 13b.
- The V-IRQ is the audio pump's and there is no LYC interrupt, so an H-IRQ was not chosen.
- **Not built, and not graded by anything yet: BGP mid-frame.** The cart shows `bg_palette` as
  master brightness (`ApplyPalette`), so command 1's `queen_bodyPalette` (her hurt flash) and
  command 2's $93 (which differs only during a fade) would be an INIDISP band on a fourth channel.
  Step 19 builds it with the flash, and decides how a flash palette that is not a brightness is
  shown.

### What else her room needed

- **`ENTER_QUEEN` and `door_queen`** (00:$250A, 00:$2887), `queen_renderRoom` (00:$0673, which is
  `LoadScreen` of the camera's cell), and `queen_initialize` (03:$6D4A) but for her sprites and
  state list. `queenHandler`'s camera pair (03:$716E, $7190) and `queen_setActorPositions`
  (03:$6F07) run every frame; nothing else of hers does, and nothing else moves her before her
  first state ends (frame 200).
- **The window's map is BG2's.** Until now both Game Boy maps folded onto BG3's, which would put
  her head over the top of her room (`snes_target.Dest.window`).
- **BG3 needs $80-$AF.** Her metatiles and her status bar row draw ids $9C-$AF, which on the Game
  Boy are Samus's sheet read through the background's window. The sheet is kept twice on the cart
  now (`UploadSamusBgTwin`), as every other copy into that window is. Step 9's suit swap must
  refresh the twin.
- **No map rows in her room.** The Game Boy's vblank takes `.queenBranch` there, which never
  draws the row `prepMapUpdate` prepared; the cart's streamer stops (`StreamDue`), or the room's
  bottom row lands over her status bar.
- **The window's map is $FF** below the head, as `bootRoutine`'s `clearTilemaps` leaves it:
  `ClearWindowMap` at boot.
- The WARP page's QUEEN list has her room.

### A harness trap, found here

`room.loadRoom` calls the door interpreter wherever the Game Boy's frame is paused. The first
reference run of her room paused inside `collision_samusEnemiesDown`, so the loop resumed with the
temporaries from before the door and lifted Samus $6C off nothing on the first frame. The
reference now sets the door index between frames and lets the main loop run it, as the
original's debug warp does (`queen.enter`). The crawl and the warp references still use
`loadRoom`; they grade what a door loads, which the trap cannot touch, but a reference that
grades a position must not. Reading the cart's collision to explain the phantom lift found a real
defect: `CollideSamusEnemiesDown` lifts Samus out of the wrong enemies (`docs/bug_tracker.md`),
left for Step 8's fixture.

### Graded

The `warp` rung's fourth scenario, `queen`: the debug cart warps to her room through the menu,
Samus's position is held to our Game Boy's for the first 30 frames (she falls in from the top),
and the play window at frames 60, 90 and 120 is our Game Boy's picture pixel for pixel, but where
the cart has an object (our Game Boy draws none). Fault: `QueenApply` taken out (`rts`), so no
command lands: 5,234 pixels on 72 lines, code 36. The `warp` rung's shards include her room for the loaded state and the
characters; its arrival and standing checks are the `queen` scenario's fall instead.

### Cost

| | |
|---|---|
| HDMA channels | 5, 6 and 7 in her room; 7 alone elsewhere. 1-4 free, 0 is the general DMA's |
| NMI, an ordinary room | ends on line 234 |
| NMI, her room | the Queen's part runs from line 230 to 252, and the NMI ends on 256 of 261 |
| main loop | her handler is a few hundred cycles |
| WRAM | $1300-$14BF, above the OAM shadow |
| bank 0 | `SaveFileToSram` moved to bank 1 to make room for the hooks |

**Five lines of vblank are left in her room, which Step 19 cannot live in**: her feet, the neck's
OAM and her death's tiles are all vblank work. So Step 19 moves `QueenBands` out of NMI, into
the end of the main loop's pass, double-buffered, with NMI only pointing the channels at the new
tables. The tables are built from what the pass leaves, which is what the Game Boy's vblank reads
too.

## 1.0 Step 7: Hi-Jump, Space Jump, Spring Ball graded (C5a, 2026-09-28)

**Nothing needed porting.** Each item's branches were already in the engine, and each segment
matches our Game Boy frame for frame once the grader was right. The work was the grader, and
it found two defects in the oracle, not in the cart (`docs/bug_tracker.md`).

### The loadout segments

`oracle.loadout_segments`: the segment oracle's start (map 0 cell $38), one item, and a
schedule through its branches. A wall stands at x $0883 and the ledge is further left, so the
schedules turn round rather than run.

| item | frames | what it takes | fault, and where it differs |
|---|---|---|---|
| Hi-Jump | 534 | a standing jump held (3 px a frame, not 2), a hop, a spin from a walk, a jump from the crouch | `PoseJump_hiJumpRise`: frame 18 |
| Space Jump | 336 | a spin, then two space jumps in the window on the way down (arc index 44-63), held through their rise | `PoseSpinJump_spaceItem`: frame 112 |
| Spring Ball | 317 | jumps in the ball, held and let go, rolling both ways, and A in the air | `PoseMorph_springItem`: frame 28 |

`zig build oracle -- loadout [name] [stride] [nofault] [poke]` prints each reference and its
verdict. `poke` sets the item by writing it, as the spider segment does, which is how to tell
the menu apart from the port when one differs.

### Setting the item through the menu

The cart's logic reads the pad a pass behind the poll, so pass 1 is always played on no input,
and it stays graded frame 0. The menu's pads go in after it: the chord, A for SAMUS, Down to the
row, A, and the chord again. It shuts with the chord, not B, because the last menu pad is what
the first graded key's rising edge is taken against, and B is the cart's jump.

The game is frozen while the menu is up, but NMI keeps counting. So the Game Boy is given what
the menu leaves, after its frame 0: `$FF97` moved on by the menu's NMIs, and the item's bit. The
counter moves one more than the setup's passes, because the first open widens the item font and
that pass runs into a second vblank (`oracle.menu_open_lag`). The script checks the count every
run, so a menu that gets faster or slower fails as the setup (code 19), not as a phantom
divergence later.

### Two defects in the oracle

- **The segment's counter seed was 2 high.** Jump start's rise reads `$FF97` bit 1; no segment
  had held A through one, and bit 0, the walk's, cannot tell 0 from 2. Fixed as
  `oracle.segment_counter_lead`; the movie's lead is right as it was (2 more costs it 1862
  frames).
- **The bisection and the pixel-fault sweep dropped the cart's setup.** `Take.of` kept only the
  reference and keys; `Take.over` keeps the pokes and the menu's pads.

### Cost

The rung is six emulator runs in sequence, about 40 seconds: three honest and three faulted, no
bisection on the faulted ones.


## 1.0 Step 8a: `loadGraphics`, the pickups' tile swaps and the load path (C5b, 2026-09-28)

`loadGraphics` (00:$2753) was a recorder, `!GfxWanted`. It is ported, with the gfxInfo records
it walks, and every item's pickup now swaps the tiles the original swaps.

### The records

The sheets were already `chr_obj` blobs, so no new graphics were converted. What was missing
was the records: which sheet, from where, to where, how much. `src/gfx_info.zig` decodes them
from the code that loads them, each caller's `ld hl,rec / call $2753` in order:
`toggleMissiles`, the pickups `handleItemPickup` dispatches to, `varia_loadExtraGraphics`
(00:$3A84), and `loadGame_samusItemGraphics` (00:$3BB4) with its own copier. The callers name
the same records more than once, and every repeat is checked:
- the spazer's record is the plasma's;
- the screw attack's and space jump's both-items pair is one pair;
- Varia's extras and the load's list are the pickups' records again.

A caller that loads another record is refused (a unit test hands the wave beam's pickup the ice
beam's). The builder writes each record as a row of the engine's `GfxInfo` table: the sheet's
asset id, the offset, the SNES destination and the length. Two rows are not the ROM's. They are
the power suit over the Varia record's range and over the beam's, which only the debug menu
uses, because nothing in the game takes the suit or a beam away.

### The transfer

`LoadGraphics` queues a row, resolved on the logic side. NMI moves one Game Boy chunk of the
head a frame, as `VBlank_vramDataTransfer` (00:$2BA3) does: the size mod $40, or $40. So a $20
record is one frame, a spin sheet's $70 and $50 two each, and the Varia suit's $7B0
thirty-one. A transfer frame draws no status bar (00:$019E). The pickup waits in a new stage,
`!ITEM_XFER`, which draws nothing, as `beginGraphicsTransfer` (00:$27BA) waits on
`vramTransferFlag`. The jingle's countdown runs on in NMI, so the pickup is no longer, and its
first loop is that many frames shorter. The toggle goes through the same queue; its frame is
still `!CannonHold`.

The arms moved to bank 1 with it; bank 0 had 162 bytes left. The load path runs
`SamusItemGraphics` after Samus's sheet and drains the queue whole under the load's forced
blank. It keys the beam's tiles on the active weapon, not the beam, as the original does.

### The debug menu

An edit on SAMUS that changes the beam, or a bit whose pickup loads tiles, queues the whole
sheet as her items now say (`SamusGfxSync`). The next NMI puts it up under forced blank: up to a
whole suit, more than a vblank holds. So a few lines of one frame may show black. The menu is
tooling. Hi-Jump, Bombs and Spider Ball load nothing, so the Step 7 segments' Hi-Jump setup
costs nothing new.

### The `gfx` rung

Twelve pickups, each a new game on the `--debug` cart, held against our Game Boy taking the
same pickup (`src/gfx_grade.zig`):
- the four beams, and the ice beam with missiles selected;
- the screw attack and space jump, each alone and after the other;
- the spring ball;
- Varia, alone and over the screw, space and spring with missiles selected.

The lever is `snes boot` phase 9's: the orb's two stores, `itemCollected` and the flag,
written on both machines and cleared when the flag reaches $03. The first items go through the
menu on the cart and are written on the Game Boy.

Graded after the pickup:
- the object characters $8000-$87FF;
- the frames the transfer flag was up;
- the item's bit, the weapon and her pose.

Faults:
- the ice beam's arm handed the wave's row (the characters, 9);
- a whole record a vblank instead of a chunk (the frames, 8);
- Varia's pose back to `$13` (the pose, 11): see below.

Varia's frames are not graded: the Game Boy's include `animateGettingVaria`, which is Step 9's.
The cart presses B first in every case. A new game faces the screen until a button is pressed
(`poseFunc_faceScreen`, 00:$0EA5), and our Game Boy's boot has already pressed Start.

**Found porting the arms: Varia's pose was `$13`, the ROM's is `$80`** (00:$38E8), standing and
turned to the screen through the turnaround. `$13` is the appearance, which a new game holds
until a button is pressed, so a cart that collected Varia stood facing the screen until the
player touched the pad. The pose check was added and shown failing on `$13` (11) before the
rung was green on `$80`. It is logged in `bug_tracker.md`.

**The frames are sampled at line 144 on the Game Boy, not at a frame's start.** At line 0 the
spin pair read three frames against the cart's four. A pickup's second record is queued after
line 0 of the frame its first one ends in, and gets its first chunk in that frame's vblank. A
line-0 sample sees the gap between the records and misses that chunk. Sampled when the vblank
interrupt is raised, the flag is the one the handler is about to act on, and the Game Boy
reads four.

## 1.0 Step 8b: the ice beam's thaw, and the beams against an ordinary enemy (C5b, 2026-09-28)

**What the grade found missing was one routine.** Every beam's arm in `samusShoot` was already
ported: the spazer's three, the plasma's three, the wave's path. So was the hit side:
`enemy_getDamagedOrGiveDrop`'s ice arm, `EnemyCheckShields`'s wave exemption, and the frozen
enemy's solidity in both `collision_samusEnemies` routines. The gap was
`enemy_animateIce` (02:$5652), which `EnemyCommonAI` recorded into `!EnUnhandledState`. It is
ported, a tail jump like the other three arms:
- the three Metroid sprites go straight on to their AI, which thaws itself through `.call`
  (02:$565F), the normal Metroid's, Step 17;
- every other frozen enemy climbs its counter two every other pass and blinks from $C4;
- at $D0 it wakes or, at no health, is deleted with its spawn flag dead, with no explosion.

**"Plasma pierces" means walls.** 00:$31F1 sets carry on any hit, and 01:$52E3 deletes the beam
for every weapon; only the terrain test (01:$52CD, $52D1) lets the spazer and plasma through.
Step 8c grades that, with the projectiles in flight.

**The cases.** Five, in the `enemy AIs` rung. Hits are the rung's lever, the collision record
handed to both machines at the same tick:

| case | enemy | hits | what it grades | behaviour fault |
|---|---|---|---|---|
| `crawlerA ice` | moheek, `$A:$0A`, health 5 | ice | the climb, the blink, the thaw back into the crawl | the climb stopped |
| `crawlerA ice kill` | the same | ice ×3, 5→3→1→0 | the second decrement skipped at zero; the death at the thaw | the climb stopped |
| `hopper wave` | Ramulken, `$9:$21`, health 12, shielded right/left/down | power, wave ×3, from the right | the plink; the wave through the shield, 12→8→4→dead | the wave tests the shield |
| `hopper spazer` | Autoad, `$E:$82`, health 14 | spazer ×2 | 14→6→dead, the explosion, a missile drop | — |
| `hopper plasma` | the same | plasma | dead in one, a missile drop | — |

The rung grades slot 0's **stun, ice counter and health**, as globals. A freeze is invisible in
the slot's other bytes until it thaws. As slot fields they would cost four bytes a record, one
for each slot recorded. Even as globals, the hatching Alpha's 700 frames no longer fit 32 KiB,
so the case cart now has 64 KiB of save RAM. The script writes through Mesen's flat
`snesSaveRam`, so the bank limit that set 32 does not bind; `hatchingAlpha kill` was checked on
it.

**The drop's roll is not graded in general, and the kill ticks are chosen for it.** 02:$56ED
tosses `rDIV`'s bit 0 for whether a corpse drops anything. The port tosses `!EnFrame`'s, a
substitution recorded in `EnemyAnimateExplosion` and `residue.zig`. Both flip every pass. The
divider runs at about 274.3 counts a frame, so the two agree for a few passes and disagree for a
few. Measured:
- the plasma's one shot agrees at ticks 21-24 and 33-35;
- the spazer's second agrees at 67-71 and 77-81.

The cases kill at 23 and 67, where both machines drop, so the missile drop's blink and expiry
are graded as well. The first try, at 20 and 60, disagreed. That is the substitution's known
cost, not a defect: a player cannot tell which parity a divider had.

## 1.0 Step 8c: the beams in flight (C5b, 2026-09-28)

**The segment grew a projectile array and an enemy.** `oracle.Frame.projs` is the three
slots' type, Y and X, read at $DD00 and at `!Projs`, which has the same layout. A take with
`projs` compares it after Samus, in the codes the fade leaves free (6-18). The loadout gained
a beam, set through the debug menu's beam row (Right through the ROM's order, `menuSetup`) and
checked after the setup (code 19). It also gained an enemy: the `enemy AIs` rung's slot seed,
written on both machines before graded frame 1, with its Y and X put from Samus's pixel in the
enemy's camera space. The segment's room holds no enemy that has loaded, so one is written.

**What the grade found: the plasma's three in the wrong order.** 01:$4F93 adds $10 to every
slot but the first. The port added it to the first only, following M2RoS's comment ("if this
is the first slot") rather than `JR Z`. The positions were the same three, so nothing a still
picture shows differed. But 01:$4F81 lets the plasma fire again when slot 0 is free, and on
the cart slot 0 was the leading shot. Its hit on an enemy freed the gun, and a new volley
wrote over the two still flying. That, and the rule below, is what James saw.

**No beam pierces an enemy, the plasma included** (confirming 8b). Every shot that hits is
deleted. What outlives the kill flies on, because the enemy pass kills the enemy on its own
frame and a dead enemy is not a target. So how many of the three stop depends on the gap:

| gap to the Autoad | the Game Boy and the cart |
|---|---|
| $30 | all three stop, two of them spawned inside it |
| $38 | two stop; the rearmost flies on |
| $3C | all three stop (it had begun to hop into their line) |
| $44 | two stop; the rearmost flies on |

Two more rules make it look inconsistent in play, both the original's:
- an enemy that does no contact damage is no target at all (00:$3213);
- a shot inside a wall on a terrain frame skips the enemy test (01:$52D1).

**The rung, `beams`.** Eight segments (see `docs/conformance.md`). Found on the way:
- the bisection pinned a projectile divergence inside a bucket a fifth as wide as the code's,
  and `pinExact` re-initialised it narrow too (`oracle.bucketWidth`);
- in `$9:$38` every shot leaves the window before the wall, so the wall segment walks up to it
  first.

**Not a defect: an Autoad landing on Samus.** Fired at on frame 10 from $40, the Autoad hops
over the shots and comes down on Samus at frame 60. The Game Boy shows the knockback pose one
frame before the cart. The enemy's position agrees on every frame, and so does her motion from
frame 61. The cause is the reference's sampling point. `oracle.gb_logic_pc` is `CALL
samus_handlePose`, and `hurtSamus` runs just before it, so the Game Boy's sample already holds
the next tick's hurt. The cart is sampled before `HurtSamus`. A segment in which Samus is hurt
would need the sample moved to 00:$052C. None is hurt, and the shipped segments fire on frame 2
and end before the landing.

## 1.0 Step 8d: standing on a frozen enemy (C5b, 2026-09-28)

**The segment, `ice stand`** (the ninth in `beams`, 529 frames). An Autoad is seeded $30 to
Samus's right and frozen by one ice shot on frame 2. She jumps straight up beside it, drifts
over and lands on it at frame 101. She stands until it thaws (the ice counter spent at frame
419), and its contact knocks her back. The first tries at $30 and at -$30 had her hit its side,
or the shot miss a hopping Autoad; a frozen enemy is solid from the side too.

**It failed first at frame 103, and three causes stood behind it.**
- **The lift was the ROM backwards** (the open entry from Step 6). 00:$34D3's `JR C` skips
  the lift for `$C424` in $01-$FE. The port lifted for those and not for $00/$FF. `$C424` is
  the last damage a hurt or screw hit wrote: the solid arm (a frozen enemy's, 00:$362E) writes
  none.
- **The landing snapped on an enemy.** `poseFunc_fall` sets the row to `y & $F8 | 4` only when
  `$C43A` is clear (00:$1378), and the falling ball the same (00:$12E7). The port snapped
  always. The spider's twin (00:$1233) was already ported. Three `$C43A` readers in bank 2 are
  Step 11's AIs.
- **The reference's `$C424` was $A7.** `room.spawn`'s teleport let a hit read 00:$3655's damage
  table with bank 4 mapped. A new game on our Game Boy has $00 there, as the cart does, and
  the reference is reset to it after the settle.

**Then it diverged at 420, on the knockback: the sampling point that 8c named.** The Game Boy
is now sampled on `CALL hurtSamus` (00:$052C), so a hurt shows on the same frame as on the
cart, and the segment matches to the end. Faults: the lift's old `bcc` (104), the frozen enemy
taken as a hurt (102), the snap (103).

**What it means in play.** A pixel on the frames after she lands on an enemy. The snap's skip
holds always. The lift runs only until she is first hurt: after that `$C424` holds a damage.

## 1.0 Step 9: Screw Attack and Varia (C5c, 2026-09-28)

**Both effects were already ported; what was missing was Varia's animation and every grade.**
The screw's contact arm (00:$3629) and Varia's halving (00:$2F6B) were in the engine from 0b.
The step graded them, ported the rest of Varia's arm, and found three defects around them
(`bug_tracker.md`).

### Health in the segment oracle

A segment can now grade Samus's health frame for frame (`Take.health`, `Frame.health`: $D052
over $D051 on the Game Boy, `!HealthHi`/`!HealthLo` on the cart). The codes were all spent, so
it takes one code, 254, off the top of the unhandled poses' range. That range still holds
poses up to $35, and the Game Boy dispatches none above $1D. The script prints the frame, and
the bisection pins it over the whole take. `BeamSegment` also carries SAMUS rows set through
the menu beside the beam.

Three new segments in `beams`, each with an Autoad seeded $30 to her right:
- `hurt`: she walks into it, is hurt twice (15 each, $99 to $69), and knocked back;
- `varia hurt`: the same with Varia, 7 each. Fault: the halving skipped (health, frame 8);
- `screw kill`: a spin jump through it with Screw Attack. It dies and she is unhurt. Fault:
  the screw's item test never passing (position, frame 10).

**`hurt` failed at frame 9 first**, on the knockback's direction. The cause was a flag the
horizontal entry sets and the port did not. After a walk's hit, the play handler's pass ran
again and wrote the default boost over the hit's.

The Alpha's screw reaction case in `enemy AIs` still agrees.

**The same flag was the open Senjoo entry.** The cart met the segment's Senjoo a tick early
because its standard pass ran a second time in the frame the walk had already tested. With the
segment lengthened to 703 frames, as that entry asked, the `oracle` rung matches every frame;
with the flag's store undone it diverges at 702. The segment stays at 703.

### Varia's arm

`pickup_variaSuit` (00:$38B9) blocks three times before it loads the suit. Each block is a
pickup stage (`VariaStage`, bank 1):
- its own wait for the jingle's countdown, drawing Samus, the enemies and the Metroid icon in
  that order and no projectiles;
- then the bit, pose $80, Samus alone and a frame;
- the sound, `variaAnimationFlag`, and `animateGettingVaria` (00:$27E3) until the walk reaches
  $8500.

Then the suit, the cannon and the extras are queued and the pickup waits on them, as 8a's arms
do. None of these waits is `waitForNextFrame`, so none ticks the clock.

**The animation is NMI's** (`VariaAnimNmi`, 00:$2BF4). On an even frame it writes one byte of
each of sixteen tiles, the suit's over the power suit's: a row of pixels, one bitplane at a
time. That is 80 writes over five rows of tiles, 160 frames. The walk is the original's
arithmetic on its Game Boy address. Each byte then lands in the SNES tile it belongs to: the
sheet is 4bpp, so byte `b` of a Game Boy tile is byte `b` of the 32, the low or high half of
word `b/2`. The loop sets the data bank to the sheet's, which on this LoROM cart mirrors WRAM
and the PPU below $8000. A Varia vblank draws no status bar either.

### The `gfx` rung's new grades

- **Varia's frames**, now graded like the other cases: the cart counts the animation as
  transfer, as the Game Boy's flag is up through it. 190 frames alone, 198 over everything,
  exact.
- **The pickup's length, within 2%**, for Varia; the others print theirs. Every pickup reads
  one frame longer on the cart, because the two machines take the orb's stores at different
  points of a frame.
- **From the bit landing to the flag's $03, exactly**, which the lever does not reach: 352
  frames for every ordinary item, 192 and 200 for Varia. This found the jingle loop's missing
  first pass.
- **The clock's ticks over the pickup.** The cart's stores wait until its counter's low byte
  is the Game Boy's less one. That offset was measured: at the old stores, Varia's
  even-frame animation agreed only when the parities were opposite, and less one lines up the
  frame the bit lands. The clock's ticks found that no item frame ticked it.

Faults: Varia's animation cut to nothing (8), the jingle's first pass testing the countdown
(13), and the jingle's frames not ticking (14), besides 8a's three.

**Playtest, 2026-09-28, on `af904c1`**: James confirmed both on the FXPak. The knockback
throws her away from an enemy walked into, and Varia's suit wipes onto her a line at a time
after the fanfare.

### Not done

- The (C10) cross-check of Varia's length against the 100% recording's pickup (part 05, frame
  25 317) is left for Step 26's C10 pass, as 8c's and 8's were. The `gfx` rung grades against
  our Game Boy running the ROM, which is the authority.

## 1.0 Step 10: the refills and the ship's branch (C5d, 2026-09-28)

**The refills were already visible; the step found which step made them so.** Both refills
are odd sprite ids, so they are items as far as `enAI_itemOrb` (02:$4DD3) is concerned, and
it toggles their palette bit on the bob frames: measured on the cart, 8 frames in OBP0 and 8
in OBP1. OBP1 was black until 1.0 Step 8b (`d80d095`), so a refill was black on the black
play field half the time, and before 0b Step 21 its characters were missing outright. The
`warp` rung's `refills` scenario holds `$F:$10`'s pair to the ROM's parts, characters and
palettes every frame and fails (39) on the unfixed engine. James's "until re-entry", after a
fought kill, was not reproduced: a kill from the menu changes nothing about the blink.

**The missile refill's `metroidCountReal` test is ported** (00:$399C). At zero the original
writes `$D066`'s low byte and the song request $08, sets mode $12 and returns without
`handleItemPickup_end`. The port writes the same, records the item in `!ItemUnhandled`, and
holds the pickup at `!ITEM_CREDITS`, a frame of nothing, which is where mode $12 goes in 1.0
Step 22. Before the step every missile refill was recorded, whatever the count.

**The METROIDS page gained the Queen**, its 47th row, as C8 says: without her the menu took
the count to $01 at best (James, 2026-09-28). She has no spawn record, so her row's state is
read off the count: dead when `!MetReal` is the number of the 46 still alive. Killing or
reviving her moves both counts and nothing else; her death is Step 20's.

**James's playtest of `269f982` found the shown count going to 93** with every Metroid but the
Queen killed from the menu. The status bar's count leaves the eight larvae out until the
final area's stinger runs (02:$6B92 adds $08), and the menu took them off it anyway. A larva
now moves the shown count only once the stinger's flag is dead (`debug_larvae`, a blob from
the ROM), graded by the `scenario` rung's `larvae`.

**A finding about the warp page:** `$F:$10`'s two ITEMS entries stand Samus on the far side of
a wall from the refills they name (the spot is the nearest floor to the record, not one she
can reach it from). The `refill_credits` scenario collects at `$F:$76` instead, where a jump
reaches the refill. Step 18's world pass can revisit how an item's spot is chosen.

## 1.0 Step 11: ordinary AIs, the first batch (C1a, 2026-09-29)

**Nine AIs and a child, ported branch for branch and graded against our Game Boy:** skreek
(02:$59C7) and its spit, which is the same AI told apart by the spawn flag's low nibble;
drivel (02:$5AE2) and `drivelSpit` (02:$5BD4); moto (02:$66F3); gravitt (02:$695F); halzyn
(02:$6746); septogg (02:$6841); `flittVanishing` (02:$68A0) and `flittMoving` (02:$68FC).
They brought the halzyn's sine motion (02:$677C-$682C), which the missile block shares in
Step 12. They also brought `enCollision_down.onePoint`, the three `.farMedium` probes and
`enemy_spawnObject.longHeader`. Five speed tables are new physics blobs (ids 42-46). The two
spit headers are carried whole and compared with the cartridge's by `correspond.zig`.

**Bank 0 is full, so these are in bank 1.** `EnemyCommonAI` looks an AI up in `AiTable` and
hands anything it does not find to `AiDispatchFar`, which walks `AiTableFar` and calls the
routine; an AI in either table is the same contract. Bank-0 helpers are reached through
`%call0`. A header an AI hands to `EnSpawnShort` is in bank 1 too, so the call is wrapped in
the data bank set to 1, which mirrors the slots. It cost bank 0 seven bytes (379 are left) and
bank 1 2 397 (20 091 left).

**The rooms.** Each case is in a room of the AI's own spawn records, and `zig build roster --
ai <addr>` now lists them with whether each cell can boot. Five first records cannot:
`$A:$31` has no settled tileset, and in `$9:$20`, `$9:$77`, `$9:$30` and others Samus never
comes to rest at the cell's centre. The cases use `$B:$54` (skreek), `$B:$51` (drivel),
`$B:$62` (moto), `$9:$97` (gravitt), `$B:$F5` and `$B:$F1` (the flitts), `$B:$24` (septogg),
and `$9:$67` and `$9:$69` for halzyn. The first weaves through all four states and both speeds
before leaving the screen; the second turns off a wall.

**The drivel tosses `rDIV`** (02:$5AEA) for when to start looking for Samus. The port reads
`!DivClock`'s high byte, the divider clock the status bar's scrambled count already reads,
and the enemy oracle hands the Game Boy's byte across at each read (`Case.divider`). Without
that, the two machines' drivels part at pass 3, as they must.

**Riding.** The septogg and the moving flitt carry Samus, which a case with Samus standing
still never reaches. The `beams` rung's `septogg ride` and `flitt ride` seed each beside her
and put her on it. She sinks with the septogg three pixels a pass to the floor and walks off.
The flitt glides under a straight jump and carries her right and back. Both are graded frame
for frame, with the carry faulted out. Not graded: the septogg's rise back up once she is
off, which moves no one.

**James's playtest: the septogg sinks through the sand with Samus, and she is stuck.** It
is the original's behaviour. The sand ($5A, $5B) is above the enemy solidity index ($54) and
below Samus's ($5C). The septogg's probe does not see it, and the septogg moves her
without collision. `septogg sand` grades it in `$B:$24`: the ride, the sinking and the trap,
frame for frame. It needed segments to start in a room of their own choosing
(`BeamSegment.room`, `oracle.roomStart`). His second report was the ask's fault: the
skreeks and drivels are not west of `$B:$57`. `zig build roster -- ai` now names the
nearest warp and its door: Metroid 11 (`$B:$45`), then down through `$B:$44`'s floor.

**A finding for Step 18.** The first draft of the ride walked her off the septogg's west
edge, across the seam into cell $37. There the Game Boy stopped her against a block the cart
does not have (`docs/bug_tracker.md`, 2026-09-29). The oracle's `World` check compares only
the boot cell, and the Game Boy arrives by a `WARP`, so which side is wrong is open.

## 1.0 Step 12: ordinary AIs, the second batch (C1b, 2026-09-29)

**Ten AIs, ported branch for branch into bank 1 behind `AiTableFar` and graded against our
Game Boy:** glowFly (02:$54A1), proboscum ($65D5), skorpVert ($60AB), skorpHori ($60F8),
autrack ($6145) and its laser, autom ($6540) and its flame, gunzoo ($638C) and its three
shots, missileBlock ($6622), and blobThrower ($4EA1) with `blobProjectile` ($536F). The
children's headers are carried whole and compared with the cartridge's by `correspond.zig`.
`pending` now holds only the Metroids, Arachnus and the baby. It cost bank 0 53 bytes (326
are left), mostly the thrower's draw and hitbox paths, and bank 1 2 906 (17 185 left).

The ROM keeps the gunzoo's three shot headers back to back, and the four blob headers too.
Carried that way they are 39 and 52 bytes of the ROM in its own order, and the file policy
stopped the first. So each group is split, with code between, and no run reaches 32 bytes.
Each header is still compared whole with the cartridge's.

**The blob thrower is not an ordinary enemy, and the port gives it what the original does.**
`blobThrower_loadSprite` (02:$4DB1) copies its part list ($3E bytes) and its hitbox (4) into
WRAM at $C300, and the AI rewrites both as it rises and opens: its sprite pointer and its
hitbox pointer name WRAM. The port keeps the same two copies in high WRAM (`!BlobSprite`,
`!BlobBox`), loaded at boot from the ROM's own bytes, which are a new physics blob (id 47).
The movement tables its blobs follow are id 48. `DrawEnemySprite` and `LoadEnemyBox` read
the copies when the converted pointer is dead, which only sprite $9A's is. Its state lives in
globals ($C380-$C386), not its slot, so the oracle grades seven more globals beside the
slots: the action, the wait, the state, the facing, the mouth's tile, the lip's Y and the
hitbox's top.

**Two AIs toss `rDIV`, at three sites**: the autom's flame (02:$6549) and the gunzoo's two patrols
($63AB, $6446). `Case.divider` became `Case.dividers`, a list of sites, each handed across in
its own order.

**The rooms.** Six are the first record's room. Four are not, and a Samus offset moves where
she settles:
- **proboscum**, `$9:$7D`, $18 left. From the centre, the Game Boy's camera dips three
  pixels every 52 frames and the cart's does not (`docs/bug_tracker.md`, 2026-09-29).
- **skorpVert**, `$A:$C7`. In `$B:$9B` the cart's camera scrolls down $1B pixels and the
  Game Boy's holds: the 2026-09-13 entry's kind, in one more room.
- **autrack**, `$E:$82`, $30 right, the flipped turret. `$D:$53`'s record and `$E:$74`'s
  hang below the screen, and in `$E:$64` Samus never settles.
- **autom**, `$E:$B7`, $30 left. From `$E:$B5` it walks off the screen in twenty passes.

The missile block needed Samus off it. Standing on it, her touch ($20) is the contact on
every pass and overwrites the missile the case hands it. Both of its records sit in a stack
of solid tiles, so on the Game Boy the block explodes on the pass it is hit, from either
side. The case grades that (eight entries), and the weave (02:$6660-$66AD) is not reached.

**Settled: the 100% run does dispatch `blobThrower`** (Step 24b's open finding). The
Game Boy harness showed it passing the ordinary dispatch at 02:$5650: 121 thrower and 359
projectile dispatches in the case's 600 frames. Re-running the unmodified census on part 07
gives `02:4EA1 sprite $9A first $9:$1B at 100 ... 642 dispatch(es)`. So the omission was
in `recorded_census_100`, not in the run, and the list now has it. All 42 are dispatched.

**The gate's time.** The enemy rung was 45 cases of two or three Mesen2 runs each, run one
after another, and after Step 11 the gate stood at 14m27s. `runCart` is now `startCart` and
`finishCart`, and `gradeCases` keeps four cases in flight, each case's runs started together
under its own file names (`enemies<i>`, `-fault`, `-behaviour`). `zig build oracle --
enemies` does the same: all 47 cases in 49 s. The gate: green, 43 rungs, 12m36s, down from 14m27s with nine more cases.

## 1.0 Step 13: Arachnus (C3, 2026-09-29)

**`enAI_arachnus` (02:$5109) and its fireball (02:$52DF), ported branch for branch into bank 1
behind `AiTableFar`.** It is an orb ($9C) until a beam or a missile hits it. Then it bounces off
its pedestal, stands up, faces Samus, and spits a fireball whenever the last one has gone.
**Only bombs hurt it, and only while it stands**: six of them, counted in `arachnus_health`
($C394). Its slot holds $FF, so no other weapon's damage lands. **Holding the Game Boy's B
curls it up** (02:$521B reads `$FF80`), and it bounces towards Samus and stands again. It is
the first AI that reads the pad. The sixth bomb turns it into the Spring Ball: sprite $95 and
the item orb's AI (02:$5256). `pending` now holds only the Metroids and the baby.

- **Its state is global** ($C390-$C394), as the blob thrower's is. The port keeps four of the
  seven bytes the init clears; `arachnus_unknownVar` ($C392) and the two after the health are
  never read. The enemy rung grades the four as globals, so the bombs' countdown is graded one
  bomb at a time.
- **Its three jump tables are one run** (02:$52FC, $73 bytes, physics blob 49). `.jump`
  indexes whichever table it was handed by the counter, and a landing on a table's $80 steps
  the counter onto the next table's first byte. So the opening bounce reads all three tables,
  and a roll reads the last two. `correspond.zig` holds each table's offset to its reader's
  `LD HL`, and the fireball's header to the cartridge's.
- **Two probes it needs were new**: `enCollision_right.midMedium` (02:$4662) and
  `enCollision_left.midMedium` ($483B), the roll's walls.

**The cases**, all in `$D:$C0` and begun with the recording's opening shot (part 07 frame
1 097, the ice beam from the right):
- `arachnus`: the orb, the bounce, standing, and two fireballs in 400 frames.
- `arachnus roll`: B tapped, then held for 100 ticks. It curls, rolls to Samus and past her,
  stands, and curls again while B is still down. The behaviour fault ignores B.
- `arachnus kill`: six bombs at the recording's spacing, from part 07 frames 3 102, 3 112,
  3 120, 3 751, 3 757 and 3 765, where `zig build gbtrace -- kills` sees `arachnus_health` go
  6 to 0. The first lands at tick 300, not the recording's +2 005 from the opening shot:
  those frames are the player's rolls, which `arachnus roll` grades, and a case that long
  would outrun the cart's record. The behaviour fault takes any weapon for a bomb.

**Two harness changes came with them.**
- **`Case.fire`**: B held on both machines over a span of ticks. It is real input, not a
  byte written. The Game Boy steps the tick with the key down, and the cart is handed it on
  the poll the segment rung's relation names. `kills` now also follows Arachnus's slot and
  watches `arachnus_health`, so Steps 14-17 get the same table.
- **Samus is frozen in all three** (`freeze`). Unfrozen, the fireballs knock her back and her
  camera moves on every frame. At tick 302 the Game Boy's `rLY` budget then finished the
  fireball's slot a frame late (`enemiesLeftToProcess` 1 after the pass). That is the
  accepted deferral of 2026-09-13 (`docs/bug_tracker.md`), and it landed on a pass whose
  positions differed. Arachnus never reads the cutscene flag.

**The drop: the warp rung's `spring_ball` scenario.** The Spring Ball has no orb record, so
Arachnus's record is now its WARP entry, under ITEMS (`roster.destinations`). The scenario:
- takes FULL LOADOUT with the Spring Ball row turned back off, and warps in;
- begins the fight with the recording's shot, and hands over the six bombs the way the enemy
  rung hands them, each once Arachnus stands again;
- jumps Samus at what is left until the pickup runs.

It checks that the Spring Ball's bit is set, that Arachnus's record is dead, and that a
second warp loads nothing. Its fault takes out the sixth bomb's switch to the item orb's
AI, and there is nothing to pick up (46).

**It found a defect in the warp (Step 5b): the entry never loaded Arachnus.** The warp
sweeps the camera onto the spot a grid row at a time, so the loader walks each row once. The
loader tells down from up by `scrollY` less its value two passes ago, unsigned (03:$40C5),
so the one pass whose `scrollY` wraps through $00 walks the top edge. The original moves a
few pixels a pass and walks each row over several passes, so losing one walk loses nothing.
The sweep walked each row once and lost the row under the wrap, and Arachnus's record,
$CB0, was that row. The sweep now steps half a row (`!WARP_STEP`), so every row is walked
twice and the wrap can take only one of them. `spring_ball` failed 44 ("no slot holds
#$70") on the unfixed engine.

**Playtest (James, 2026-09-29, hardware): perfect.** WARP to the Spring Ball's entry: the orb on
the pedestal, shot and bouncing off, standing and spitting, curling and rolling while fire is
held, bombed six times into the Spring Ball, and picked up with the jingle.

## 1.0 Step 14: the Gamma Metroids (C2a, 2026-09-29)

**`enAI_gammaMetroid` (02:$6F60), ported branch for branch into bank 1 behind `AiTableFar`.**
The Gamma arrives wearing the Alpha's sprite. **The molt is its own AI's**, not another's: a
Gamma the room has not seen waits for Samus within $50, freezes her, asks for the fight song,
and swaps its sprite between the Alpha's and its own every fourth pass, sixteen times
(`XOR $0E`, $A3 and $AD). Then she thaws and the fight starts, at `metroid_state` 1 (the
Alpha's is 2). A seen Gamma skips the molt the next time she is in range.

- **The fight.** Fourteen passes of lunging along one of twenty-four angles, five of
  stillness, and on the twentieth a lightning bolt below it on the side it faces.
- **The bolt is the same AI in a child slot**: its spawn flag is a link, whose low nibble is
  zero, and `.checkIfHurt` sends such a slot to `.projectileCode`. Three steps on even
  passes, up and across, and it deletes itself; `EnemyDeleteSelf` then puts the Gamma's flag
  back from `$05` to `$04`. **While the bolt lives the Gamma does nothing**: `$05` returns
  before anything reads what hit it. The bolt also counts down the Gamma's stun counter,
  which is shared.
- **A missile's push is probed**, where the Alpha's is not: five pixels away from the shot,
  put back on the mirror if the far wide probe on that edge hits, and then no flag for that
  axis. The other axis is `rDIV`'s coin, `!EnFrame` standing in as for the Alpha, and handed
  across by the enemy rung the same way (`Coin`, now watching either stun counter).
- **Its own stun counter**, `gamma_stunCounter` ($C46A, `!GammaStun`), graded as a global.

**`gamma_getAngle` (01:$723B) shares the Alpha's distance and slope, so the Alpha's moved.**
The ROM's angle routines are three each: `metroid_getDistanceAndDirection` (01:$70C1) and
`metroid_getSlopeToSamus` (01:$7170) shared, then the species' own table walk and slope bands.
The port had the Alpha's as one routine in bank 0, which was full. Its angle, slope and speed
routines are now in bank 1, with the distance split out as `MetroidDistanceDir`, and the Alpha
reaches them with `jsl`. The Gamma's table (01:$729C, $20 bytes: bases $00, $04, $0B, $12,
$19, bands 0-6) and its twenty-four `LD BC,d16 / RET` arms (01:$7359) are physics blobs 50 and
51; `correspond.zig` checks each arm, the bolt's header (02:$71D0), and 57 operands. **Bank 0
gained 400 bytes** (726 free); bank 1 has 14 606 left.

**The cases are in `$E:$85`, not the census's `$A:$36`.** At `$A:$36` this rung's Gamma never
moves, on either machine and wherever Samus stands: every probe its lunge makes hits, and
every push is put back, so a fault on the push could not be caught. In `$E:$85` (Metroid 41,
the recording's kill 16) it lunges along seven angles in 600 frames. Samus is frozen in all
three (`freeze`), because the molt freezes and thaws her, and she thaws a frame apart on the
two machines -- the enemy pass's parity -- so her camera, and every slot's screen Y with it,
then runs a frame apart. What the freeze gives up is the range test before the molt, which a
raised cutscene flag skips. **A frozen case no longer grades the cutscene flag** it forces:
the molt's end clears it, and the two machines sample either side of the fixture's rewrite.

- `gamma`: the molt, and three cycles of lunges and bolts; the bolt graded as slot 1's child.
  The behaviour fault fires the bolt on the pause's first pass.
- `gamma shot`: a beam's dink, missiles from all four directions and a screw attack. The
  behaviour fault puts every left push back, as if its probe had hit.
- `gamma kill`: twelve missiles at the recording's spacing, **kill 26's** (`$A:$36`, part 12,
  `zig build gbtrace -- kills`): the fight at 24 113, ten hurting shots at +72, +130, +160,
  +220, +280, +306, +334, +392, +462 and +566, and two at +202 and +434 that land while the
  bolt is out and do nothing. Not kill 16's, in this room: that fight leaves the screen four
  times and restarts on each return. The behaviour fault lets a shot at the bolt's time hurt.
  The case needed `max_coins` raised from 8 to 12: the ninth and tenth hurts' coins went
  unrecorded, and the cart tossed its own.

**`kills` now follows the Gamma** (`gb_trace.kill_ais`) and watches `gamma_stunCounter`. It
takes the first slot running a listed AI **that is not a child**, because the bolt runs the
Gamma's AI too.

**Playtest (James, 2026-09-29, hardware).** Metroid 41, the Gamma: perfect. Most Alphas fine.
**Metroid 01 (`$A:$17`) drew the wrong rock**, and a kill once came straight back with Samus
frozen. The rock was the warp table's, not the room's (`docs/bug_tracker.md`): the recording's
`$D808`-`$D814` in the room, read with `kills` carrying the block, is the crawl's truth
arrival through door $09A, which had no chain because `loaderFor` took no count-gated
script. Now it does, when no ungated script loads the state, and a truth arrival over a
crossing that runs no script takes a same-bank loader or the room before's chain. 13 entries
moved to truth (70 walked, 78 seeded, 14 inferred). The new `warp.test` holds every entry into
a room with a truth arrival to one; it failed on six first. The frozen kill is not reproduced.

## 1.0 Step 15: the Zeta Metroids (C2b, 2026-09-30)

**`enAI_zetaMetroid` (02:$7276), ported branch for branch into bank 1 behind `AiTableFar`,
with the two things it spawns, which run the same AI in other slots.**

- **The intro is three slots' work.** An unseen Zeta arrives wearing a Gamma's sprite ($AD)
  and blinks until Samus is within $50 across. Then she freezes, the fight song is asked for,
  and eight blinks later it **sheds the husk** (sprite $B2, flag $03, 02:$759F's long
  header) where it stood, moves up eight and becomes the Zeta ($B3). The Zeta oscillates
  narrowly and rises six times, one pixel every eighth pass, and sets `metroid_state` 1; the
  husk oscillates widely (`.oscillateWide`, 02:$75FF) until then, takes the Zeta's palette,
  falls on the acceleration curve until it is off the bottom, deletes itself, and sets
  `metroid_state` 2, on which the Zeta starts the fight (3) and Samus thaws.
- **The fight** is states 3-6: seek Samus (`enemy_seekSamus`, 03:$6B44), facing her; with
  her within $20 across and within $20 below, spit a fireball ($BE, flag $06, 02:$75E2's
  short header) that falls three a pass and drifts the way it faces; state 4 the spit's
  sprites, 5 the rise on the backwards curve to $30, 6 a $20-pass tail wag, then 3 again.
  The fireball deletes itself when the Zeta reaches state 6, or at the bottom.
- **Hits.** A beam dinks, a screw attack knocks it back as the Alpha's does, and **a missile
  from below dinks** (`BIT 2`). Any other missile takes one of its twenty health, stuns it
  for eight passes, and pushes it five pixels **with no probe** (the Gamma's has one): right,
  down, or left if that leaves it at $10 or more; the other axis takes the `rDIV` coin. The
  stun's end puts the direction flags back to $FF, so those flags are never acted on.
- **While `metroid_state` is not 0 it is kept on the screen**: `metroid_keepOnscreen`
  (02:$7DC6), Y no higher than $18 and X between $18 and $90. It applies to the husk too.
- Its own state: `zeta_stunCounter` ($C46C, `!ZetaStun`, a new enemy-rung global) and
  `zeta_xProximityFlag` ($C437, zero between calls).

**`enemy_seekSamus` (03:$6B44) is the Omega's and the larvae's too**, so it is its own
routine, `EnemySeekSamus`, taking B, D and E in `!MetB`, `!MetD` and `!MetE`. Its $21-byte
speed table (03:$6BB1) is physics blob 52. `correspond.zig` checks the table's two loads,
both headers, and 85 operands, among them the Zeta's `LD DE,$2000` and `LD B,$02` and
`metroid_keepOnscreen`'s `LD BC,$1890`. **Bank 0 is unchanged**; bank 1 gained 1 707 bytes and has 12 899
left.

**The cases are in the census's `$A:$F8`** (Metroid 4, and the recording's kill 30). Samus is
frozen in all three, as for the Gamma; the intro raises the flag she is frozen by anyway.
The fight starts on tick 242.

- `zeta`: the intro, the husk's fall, two spits with their fireballs, the rises and the tail
  waits, 900 ticks. The behaviour fault ends the tail wait at once.
- `zeta shot`: a beam's dink, missiles from the right, the left and above, one from below that
  dinks, one during the stun, and a screw attack. The behaviour fault pushes a missile going
  down to the left.
- `zeta kill`: **kill 30's spacing** (part 13, `zig build gbtrace -- kills`): the fight at
  24 763, twenty hurting missiles, the first ten from the right but one from above and the
  rest from the left, and two from below at +1 074 and +1 086 that only dink. **One gap is
  500 shorter than the recording's**: nothing lands between +418 and +1 074, and at full
  length the case cart's save RAM runs out (`TooManyRecords` at 2 000 ticks), so every hit
  from +1 074 on is 500 earlier, spacing kept. The case runs 1 560 ticks, past the
  post-death timer's $90: a global cut mid-climb is one step short on the cart, which is
  pass parity and not a defect. The behaviour fault lets a missile from below hurt.

**The coin handover watches three stun counters** now, and takes each hurt's mask from the
latest missile at or before its tick rather than the *n*th missile: a Zeta's missile from
below takes no coin, and its kill's missiles come from three sides. `max_coins` is 24.
**`kills` now follows the Zeta** and watches `zeta_stunCounter`; the husk ($03) and the
fireball ($06) are skipped as children. The recording's other two Zeta kills (31, `$E:$3A`;
34, `$B:$04`) run 2 200 and 2 080 frames from the fight to the kill, longer than kill 30's.

## 1.0 Step 16: the Omega Metroids (C2c, 2026-09-30)

**`enAI_omegaMetroid` (02:$7631), ported branch for branch into bank 1 behind `AiTableFar`,
with the fireball it spits, which runs the same AI in another slot (flag $06).**

- **The intro is one slot's.** An unseen Omega blinks between the Zeta's sprite and its own
  (`XOR $0C`) every fourth pass once Samus is within $50 across -- both sides biased by $10,
  which the seen Omega's test is not -- freezing her and asking for the fight song. On the
  twenty-fourth blink it becomes the Omega ($BF), thaws her and starts the fight with its flag
  at `$04`. A seen Omega starts at once when she is in range.
- **The fight** is `metroid_state` 1, 2, 4, 5, 6 and 7 (3 is unused). 1 faces her and spits
  after sixteen passes; 2 waits while the fireball lives (`numEnemies.total`), closing its
  mouth and wagging its tail; the fireball's end is 4, which is 1 again. **Every pass of 1, 2
  and 4 counts `omega_waitCounter`, and at $40 it picks a chase** -- $0C, $14, $28, $40 or
  $60 passes by `omega_chaseTimerIndex`, stepping 1-4 and back, or the shortest if her health
  fell $30 since the last pick -- and returns from the AI through its `POP AF`, which the port
  writes as a jump out. 5 seeks her (`EnemySeekSamus`) until the timer runs out or she
  crouches (unless the index is 4), 6 rises to $34 on the backwards curve, 7 wags $38 passes.
- **The fireball** aims once through `gamma_getAngle` and flies along the Gamma's
  twenty-four speeds, bursting ($C8-$CC) where its near probe meets a wall above or below.
  The up probe, `enCollision_up.nearSmall` (02:$4BC2), is new, in bank 0 beside its down
  twin (48 bytes). Its last result goes to `unknown_C42D`, which nothing reads; the port
  has no byte for it.
- **Hits.** A beam dinks, a screw attack knocks it back and sets the chase index to 3, and a
  missile **going up or down dinks** (`AND $03`). A missile in the back takes three health
  and stuns it $10 passes; one in front takes one and stuns it three. Either shows $C4, cries
  (`metroidQueenCry`) and pushes it five pixels the way the missile went, unprobed, the left
  push not below $10; the stun's end puts back the covered sprite. **No coin**: the Omega
  reads no `rDIV`.
- Its own state: `omega_stunCounter` ($C462), `omega_tempSpriteType` ($C44F),
  `omega_waitCounter` ($C46F), `omega_samusPrevHealth` ($C470) and `omega_chaseTimerIndex`
  ($C478). The stun, the wait counter and the index are enemy-rung globals. `.unusedProc`
  (02:$7A06) is reached by nothing and is not ported.

`correspond.zig` checks the fireball's header, the chase's `LD DE,$2000` against the Zeta's,
and 82 operands. **Bank 0 has 678 free** (+48); bank 1 gained 1 527 bytes and has 11 372
left. `audio_protocol.md`'s `songPlaying` rows for the seen Zeta and the seen Omega now read
the reply (Step 15 had left the Zeta's as "not ported").

**The cases are in the census's `$B:$76`** (Metroid 14). Samus is frozen in all three. The
fight starts on tick 190.

- `omega`: the intro, two spits with their fireballs, one bursting on a wall, a chase pick,
  the chase, rise and wait, 1 200 ticks. The behaviour fault ends the tail wait at once.
- `omega shot`: a beam's dink, a missile in front and one in the back, one during the stun,
  one going down and one going up that dink, a screw attack (its chase takes index 3), and a
  front and a back hit after it: health $28, $27, $24, $23, $20. The behaviour fault lets a
  missile going up or down hurt.
- `omega kill`: **kill 38's spacing** (part 20, `$B:$75`, `zig build gbtrace -- kills`, which
  now follows the Omega and watches its stun): the fight at 511 and eighteen hurting
  missiles, the first in front, seven in the back, five in front, five in the back, the last
  the kill. **Three gaps are shorter** (250, 400 and 200): at full length the case cart's save
  RAM runs out before the post-death timer ends, and a cut mid-climb leaves the machines'
  timer histories a pass apart, which the strict global comparison calls a difference.
  **Each missile's direction is chosen to hit the side the recording's did**, from the way
  this Omega faces at that tick, since Samus stands elsewhere; the health steps are then the
  recording's exactly, $28 to $01 and the kill. The behaviour fault takes a missile into a
  left-facing back for one in front.

The recording's other Omega kills are 36 (`$B:$8E`), 37 (`$F:$E1`) and 39 (`$F:$B0`), by
cell against the roster's Omegas 15, 46 and 45.

## 1.0 Step 17: the larval Metroids and the stinger (C2d, 2026-09-30)

**`enAI_normalMetroid` (02:$7A4F) and `enAI_metroidStinger` (02:$6B83), ported branch for
branch into bank 1 behind `AiTableFar`, with `metroid_correctPosition` (02:$7CDD).**
`enemy_oracle.pending` now holds only the baby.

- **Latched** (`+$07` set), a larva follows `larva_latchState` ($C475), which is global, so
  one larva on Samus is the one every larva sees: 2 sits on her, and a bomb makes it 1; 1
  flies off her, up and left three pixels a pass for $18 passes, each axis refused past $10 or
  into a wall by the far-wide probe, holding `larva_bombState` ($C474) at 2 so no other larva
  latches meanwhile; 0, or the fly-off's end, clears everything and puts the seek vector at
  rest. The drain is Samus's side, which Step 0b had ported: a damage byte of $FE is
  `applyDamage.larvaMetroid`, three units every eighth frame.
- **Not latched**, a hurt shows $CF for three passes (`larva_hurtAnimCounter`, $C473) before
  anything else. **Frozen**, it thaws itself through `enemy_animateIce.call` (02:$565F, which
  Step 8b left for this step); at the thaw it is $CE with five health. A missile takes one,
  and the fifth kills it; ice refreezes it; any other beam dinks. **Free**, it blinks between
  $A0 and $CE every fourth pass; a touch latches it (or sends it straight off her while
  another flies off); a screw attack or a bomb knocks it back as the Alpha's does; ice
  freezes it ($44 on the counter); any other shot, missiles included, dinks. Untouched, it
  rides a knockback out or seeks her one step a pass (`EnemySeekSamus`, D $1E and E $02) and
  backs out of walls (`metroid_correctPosition`).
- **The kill is not the other species'**: no `metroid_state`, no fight, no jingle. The slot
  explodes as an ordinary enemy's does (`+$0E` $10, no drop), both counts go down one, the
  shuffle timer is set and the quake check runs.
- **The stinger** is the final area's event, one record (`$E:$22` #43) with no sprite. Its
  first pass adds the eight larvae to the shown count, sets the shuffle timer to $CA, asks for
  the hive's song ($1F) and freezes Samus; its $8A'th deletes it, its flag dead, and thaws her.
- **A room's entry clears both latch bytes** (02:$4013, beside the collision bytes the port
  already cleared there), so a larva on her as she leaves does not stay latched.

`correspond.zig` checks the larva's `LD DE,$1E02` and 47 operands. **Bank 0 has 672 free**
(+6, the room's clears); bank 1 gained 797 bytes and has 10 575 left.

**`kills` now follows the larva** (the first live one of a room's) and watches its three
globals. Part 21 has all eight larva kills (40-47), and two latches: at 20 834, bombed off at
21 090, re-latched at 21 178 and bombed off again at 21 240.

**The rung grows by two things.** Samus's health (`samusCurHealthLow`) is graded beside the
Metroid globals in every case, since the drain is what a larva does to her; all 63 cases agree
with it. And a hit can be **late** (`Hit.late`): written after Samus's own contact test
(00:$0538; `MainLoop_afterContact` on the cart) rather than at the top of the tick. Her touch
writes the same byte earlier in the frame, so a hit written at the logic point is lost
whenever she is touching the enemy, as she is while a larva is on her; a bomb's test comes
after hers in the original. The Game Boy's seed also clears the two latch bytes, as a room's
entry does: the settle runs the room, and in `$D:$00` a larva touched her during it.

- `stinger`: `$E:$22`, not frozen, so the cutscene flag is graded; the thaw at tick 274 on
  both machines. **The case ends on that tick.** The room's own record loads during the Game
  Boy's settle and freezes her mid-fall (the flag $01 and pose $0F where the settle stops), so
  the fall's momentum is not in the cart's boot record, and past the thaw the two falls
  differ. That is the harness's placement, not the AI. The behaviour fault adds nothing to the
  shown count.
- `larva`: `$D:$10` (Metroid 29), Samus $30 left of the centre and not frozen. It latches at
  tick 34 and drains her. The behaviour fault leaves the touch unlatched.
- `larva bomb`: the same, with a late bomb at tick 100 that sends it off her; it re-latches at
  182, and a second late bomb lands at +62, the recording's spacing. The behaviour fault keeps
  it on her.
- `larva kill`: **kill 40's spacing** (part 21, `$E:$32`): the first ice shot at 15 629,
  seven more that keep it frozen, and five missiles from 15 736 to 15 828. In `$D:$00`
  (Metroid 27), where it wedges against the terrain short of her, the first ice lands at tick
  40. Both counts go down one and the quake check runs. The behaviour fault leaves it alive
  after the fifth missile.

**Two measured limits of the rung, written down rather than worked around:**

- **The drains land a frame apart**, and the first touch a frame apart, as the enemy pass's
  parity decides. The cart is one drain behind from the first touch; the collapsed history
  agrees. So **every larva case ends on a tick that is a multiple of eight**, after both
  machines' drain, or the last step is cut on one of them.
- **The rung cannot grade a death.** Its Game Boy logic point is in the play handler, which a
  death leaves, so past her death the Game Boy's ticks stop being frames. Measured on a trial
  run to 400 ticks: the Game Boy left mode $06 after 11 ticks, while the erase (every fourth
  frame, $20 steps) takes 128 frames, which the cart's mode $06 did. Every larva case ends long
  before her health does.

## 1.0 Step 18a: every door on both machines (C6, 2026-09-30)

**In play the cart's tileset is already loaded state**, as the Game Boy's is, because the cart
runs the door scripts. `screens.assign`'s inference draws only the oracle's boots and seeds the
crawl. So what this step grades is the interpreter, the loader and the drawing, over every
script, and it leaves the inference to 18c.

**The entries** (`warp.doorEntries`), one per script:

| | scripts |
|---|---|
| walked by the crawl at the new game's count: the loader of the room it leaves, then the door, which must leave what the walk left | 319 |
| never walked there, run alone into its own `WARP` cell | 105 |
| walked, with no chain that leaves what the walk left | 17 |
| no walk and no `WARP` of their own (an enemy page, a song, a lava table) | 52 |
| the Queen's three: `ENTER_QUEEN` is WARP's own, `EXIT_QUEEN`/`ESCAPE_QUEEN` Steps 20-21's | 3 |
| undecodable (Step 1) | 15 |

A walked entry stands nearest the edge she came in by: 300 of the 424 stand. The rest, the 105
run into their own `WARP` and 19 walked into a cell with no spot, are put in the middle of the
cell and graded on what they loaded alone.

**The runs.** Twenty entries go on a **case cart**: the `--debug` cart with the WARP page's four
lists given over to them, all on the first (`warp_grade.doorCart`, `roster.Kind.door`). The
menu's own input reaches them as it reaches the real page, and 22 runs take about 14 s in
parallel. The Game Boy runs each chain by door index in the same order, from a new game at the
start of each run, as the `warp` rung's reference does.

**The map.** Beside the loaded state, the damage and the characters, both rungs now grade the
background map over the camera's view: 21 by 19 tiles from the scroll, which is `camera - $50`
and `- $48` (00:$2366). The cart's side is `!TilemapBuf` on the frame she arrives. The Game
Boy's side is `$9800` with each cell the view touches drawn whole under what the chain left
(`room.drawRoom`): the map is one cell wide, so a slot's tile is its cell's at the same slot.
All 160 WARP entries and all 424 doors agree tile for tile. The fault, `LoadMetaBase` reading
every table from table 0's base, leaves the loaded state and characters right and fails 26.

**The unit test** (`warp_grade`): every operation of the 497 decodable scripts is one
`StepDoorScript` compares for, read out of `engine/main.asm`, or `FADEOUT`, whose frames are
`OpExtraFrames`'. `ESCAPE_QUEEN` and `EXIT_QUEEN` are one script each, $19E and $19F, and named.
With the `IF_MET_LESS` arm taken out of the parse it fails on 176 operations.

**What it found: the new game's solidity.** Five runs failed 21 on their first entry, each a
script with no `SOLIDITY` of its own run straight after the new game: `$D812` was $69 on the cart
and $64 on the Game Boy. That was a mechanism, not a table, so it became 18b.

## 1.0 Step 18b: the new game as a load (C6, 2026-09-30)

**The Game Boy's new game is a load.** `createNewSave` (01:$4E1C) copies `initialSaveFile`
(01:$4E64) into the save buffer, and game mode $02 (`gameMode_LoadA`, 00:$03B5, then `LoadB`,
00:$0464) loads from it as from a file: the tables, the solidity and the graphics. Only the
item font waits on `loadingFromFile` (00:$063E). The cart replayed its boot record's door
script instead, which for the new game is `screens.assign`'s door for the ship's cell, `$D6`,
the way back in from `$A:$44`. That door loads solidity `$69 $69 $69`, and the record has `$64
$64 $64`. Nothing else in the block differs.

**The fix.** Boot record version 17 carries the record (`BootSave`, patched by the builder from
the ROM). A new game copies it into `!SaveBuf` in `LoadSaveFile`, as `createNewSave` does, and
takes the load's path: `LoadGameState`, then `LoadGameGraphics` from `BootGraphics`, with the
font now behind `!LoadingFromFile`. A handover's boot has no record and still replays its door
script. The five runs pass, and so does the rest of the gate.

**Not measured:** whether the start rooms draw a tile in $64-$68, where the two thresholds
decide differently. So there is no playtest ask: the hardware may show nothing the rung does
not.

## 1.0 Step 18c: the Game Boy's tileset over the inference (C6, 2026-09-30)

**`screens.assign` infers; the door crawl measured.** Every room our Game Boy walked into from
the new game was arrived in with what the door left loaded, and a room is one scroll region,
which is what the crawl stands Samus in. `warp.assignWalked` lays that over the static reading:
where every such arrival into a room drew it with the same graphics and metatile table, each of
the room's cells takes them, as provenance `.walked`. An arrival's picture counts when it was
walked out of a room reached from the new game, or when the door loads both itself. A room
arrived in two ways keeps the static reading. So do two rooms (five cells) arrived in with
lavaCavesFull, which no one script loads at the new game's count.

`assign` itself stays static, because the crawl is seeded from it. `snes_screen.bootFor` (the
anchors, the enemy and beam cases) and `oracle -- worlds` take the walked reading. `chooseBoot`
and the new game's boot keep the static one: the first picks door-stated cells by design, and a
new game runs no door script (18b).

| provenance | static | walked |
|---|---|---|
| door | 41 | 10 |
| walked | 0 | 484 |
| inherited | 79 | 60 |
| scrolled | 765 | 331 |
| bank | 20 | 20 |

(`zig build roster -- tilesets`.) The walk changes the table of 179 cells: $A 76, $B 16, $C 38,
$D 9, $E 4, $F 36, and none in bank $9.

**Graded on our Game Boy** (`warp_grade.cellsDrawn`): for each room, the loader of the arrival's
tileset runs from the new game, and every cell is drawn (`room.drawRoom`) and held against the
cell expanded through the walked choice's table, with its graphics. All 484 agree. The fault,
the static reading alone, draws 159 of them differently.

**B12's nine cells are settled.** `oracle -- worlds` over both published runs: **34 of 34 cells
agree tile for tile**, all of them `.walked`, where the static reading had 24. The nine are
$F:$6B/$6C and $C:$21/$31 (table 4), and $B:$0D/$0E, $A:$00/$01/$11 (lavaCavesMid, 8; the sweep
names 6 and 7 for $A:$00 and $A:$11, which draw those cells as 8 does).

**The bank $9/$A veto is re-decided on the walk.** `assign` throws its inheritance pass away in
both on a proxy (`collapsedPairs`). Against the walked cells, the vetoed reading agrees with 151
of bank $9's 151 and the pass with 136; in bank $A the vetoed reading with 5 of 58 and the pass
with 14. `assignWalked` takes, per bank, whichever agrees with more, for the cells it did not
walk: the veto stays in $9 and goes in $A.

**Cell $37's seam is the harness, not the port.** `$9:$37`'s last two columns at pixel rows
$60-$6F convert to $6C $6D over $FF $FF, which the cart showed. The Game Boy's $1A $1B over $1E
$1F are `$9:$38`'s own columns 30-31: the map is one cell wide, and the reference was booted by
`room.spawn`, which draws the boot cell whole from its origin. So a view across the seam shows
the boot cell's far columns where the original, which draws around the camera, has the
neighbour's. The cart is right, and a segment must not look across its boot cell's seam.

**The recording** (`zig build gbtrace -- reference/metroid2-100p-recording set worlds`): each
segment censused, each visit of 120 frames or more read at its middle through Mesen's Game Boy,
a cell once a Metroid count. 956 cell-visits, 3 with no window. The walked reading explains
599 of the 953, the static one 502 (`build-out/worlds-metroid2-100p-recording.tsv`).

- **In walked cells, 466 of 516.** All 50 misses are the lava at a lower count: lavaCavesMid
  walked at $47 and lavaCavesEmpty shown after kills, or the reverse (door $4A loads 8 at $47
  and 6 from $46). That is 18d's.
- **In cells the crawl never walked from the new game, about 133 of 437.** Most of the misses
  are not the lava. They are the rooms past the first lava: the crawl walks at $47, where the
  lava stands, so it reaches them only from seeds. Walking them from truth means crawling at the
  counts the thresholds open, **a mechanism change, so it is Step 18c2**, not this step's.

**Three enemy cases were standing in the wrong rock.** rockIcicle (`$A:$54`), missileBlock
(`$A:$77`) and the drivel (`$B:$51`) passed in rooms drawn with caveFirst, where the recording's
Game Boy shows the lava caves' tables (399 of 399 tiles against 0 at `$A:$54`). In the right
rooms Samus stands elsewhere and the camera leaves each enemy out of view within a pass or
seven. rockIcicle stands her $20 right (127 passes, all six states), missileBlock $10 right
(24 entries, five states); from $10-$20 left its view crossed into `$A:$76`, the seam limit
above. The drivel flies off the room's left clamp wherever she stands, so its camera is carried
a pixel a tick for 96 (191 passes, its acid 128). At two pixels a tick the Game Boy moves the
acid a pass late at tick 82, which looks like the `rLY` budget's accepted deferral; not graded.

**The anchored rung** boots 12 of its 13 stretches where it booted 11, at the same 665 frames.

**What this does not change:** the cart in play. It runs the door scripts, and 18a graded all
of them. The reading draws only boots (the oracle's and the enemy cases') and, for a room the
crawl did not reach, the warp table's inferred entries.

## 1.0 Step 18c2: the pins, and the per-band crawl reverted (C6, 2026-09-30)

**The seeding fixture passes on one catch, held to pins** (`docs/conformance.md`, item 5): the
four anchors that catch at `13a4736` and the 168 frames the seeded stretches play.

**The recording's worlds are a rung.** `gbtrace -- <set> set worlds` took about 45 minutes, one
Mesen at a time, which is a check nobody runs. Each pass's files are now named per lane
(`m2trace-<n>.*`), so eight run at once, and each pass's save file is cached under a hash of
the stamped cart, the script (which carries the recording's input) and the emulator. Cold, 316 s,
byte for byte the serial run's report; cached, 1 s. Only a clean `emu.stop(0)` is kept. The
walked reading's 354 misses of 953 are pinned one per line in `src/worlds_misses.txt`; a
removed line was watched failing by name, an extra one asking for the pin to be raised. Both
rungs are `zig build verify-full`.

**The crawl at each count, tried and reverted** (James, 2026-09-30). The plan was to walk the
rooms past the first lava from the new game, by crawling once per count band an `IF_MET_LESS`
opens ($47 and the twelve operands below it; one thread each, 199 s). It walked 540 cells where
18c walked 484, and the recording says it reads them worse:

| reading | visits explained, of 953 |
|---|---:|
| 18c's crawl | **599** |
| per band, a room's arrival at its highest count | 482 |
| per band, at its lowest count | 493 |
| per band, each visit read with its own count's band (a ceiling) | 557 |

Even a table per band loses to 18c's reading, so the rule choosing among bands is not the fault.
The walks are. Bank $B's room 32 (`$B:$5A`): at no count above $34 is it reached from the new
game, and from $34 down its arrivals from the new game come through door $0D out of `$9:$A4` and
door $153 out of `$A:$F8`, both carrying caveFirst's graphics and table. The recording shows the ruins exterior there. A room
entered through a door that loads no table has the picture of the path that led in, and the
crawl takes whichever path it reaches first, standing Samus at any door of a scroll region,
including doors a player cannot reach at that count. So the reading stays 18c's, and the count
work goes to 18d. It needs a crawl that walks only what a player can reach at a count, and the
recording's pin to grade it. The patch is kept with the 1.0 plan.

## 1.0 Step 18d: the thresholds and the lava (C2, C6, 2026-09-30)

**The lava at the visit's count, not a crawl** (James, 2026-09-30). A door script reads the
count only through `IF_MET_LESS`, so 18c's walks need not be walked again: each arrival's path,
back through the doors the crawl walked to the new game or a seed, is run again as scripts at
the count asked (`warp.LavaReplay`). Run at the count it was walked at, a path leaves the table
our Game Boy loaded on all but a few of the 604 arrivals. A walked lava room takes the table its
first arrival leaves, counting only arrivals that walked in with a lava table. One that walked
in with another table can reach lava at a lower count down a path no player takes: `$B:$F1`,
by `$B:$E3`, read Full where the recording shows Mid, and lost seven visits until those
arrivals were left out.

| reading | visits explained, of 953 | lava misses |
|---|---:|---:|
| 18c's | 599 | 53 |
| the replay, every arrival | 637 | 15 |
| the replay, arrivals in lava | **641** | **11** |

42 lines came off `src/worlds_misses.txt` and none went on. With the replay off, the pin fails
naming those 42. The 11 left are path dependence. `$A:$81` at $24 is the case in point: every
arrival the crawl walked loads Mid there (door `$188` above $21, `$66` sends her elsewhere at
$24), and the recording shows Empty because the player came in from a neighbour drained
earlier. Which door a player came in by is not in the ROM.

**The `counts` rung: every threshold and every lava level, on the cart.** `warp.countedEntries`
takes the `doors` rung's 424 entries. For every operand a chain tests, it keeps the count at it
(branch taken) and the one above it (not taken), wherever the two leave another tileset or send
her elsewhere: 270 entries. A run kills METROIDS' rows in order through the menu, never a poke,
until it reaches each entry's count, highest first. It checks the count (27), then warps and
grades as `doors` does. Our Game Boy runs the same chain with the count set, which the reference
side may be. All 14 runs pass. The fault, `IF_MET_LESS`'s `bcs` made `bcc`, fails.

- **Twelve of the thirteen thresholds, both sides.** `$01`'s taken side is door `$13B`
  branching to `$19D`: she arrives in her room through `ENTER_QUEEN`, reached at last by the
  count rather than by the WARP page's direct entry (C2's "the Queen reachable"). **`$00` is
  Step 20's.** Only door `$19E` tests it, and its two sides run `EXIT_QUEEN` (through `$19F`)
  and `ESCAPE_QUEEN`, so it is graded with her death.
- **The lava.** Every door that draws a lava table draws it at each count where its table
  changes: the loaded table's pointer against the ROM's `metatile_pointers` entry, and the map
  over the view (the B8 code-227 grade, door by door).
- **A side's floor is its own.** First run: door `$E9` at $46 failed 21. Stood where the doors
  rung stands her at $47 (Full), she fell through `$B:$16`'s floor under Mid and ran door `$59`
  into bank $C before the check ten frames on. Each side is now stood again under what its count
  loads, and the grade is read before any door she falls into runs (its index is set the frame
  before).

## 1.0 Step 18e: a save round trip at every station (C6, 2026-10-01)

**The `saves` rung.** One run per save station on the WARP page, seven in five banks, on the
`--debug` cart through the menu's own input (`src/save_grade.zig`). Each run sets FULL LOADOUT,
moves the clock (hours up two, minutes down one), and kills a Metroid of another bank. Then it
warps to the station, and with the station's bank loaded it kills one of that bank's Metroids
and marks one of its orbs taken. Last: Start on the pad, the reset button (Mesen's
`emu.reset()`: cartridge RAM survives it and nothing else does), and the title's Start, which
loads the slot. Graded:

- **The loaded state.** `$D808`-`$D814`, before the save, in the record and after the load,
  against our Game Boy running the station's chain from the new game. This is what a station
  inherits from the doors that led to it, and what the load has to put back.
- **The record.** It must hold what she held on the frame Start was pressed: position, camera,
  items, beam, tanks, energy, missiles, facing, damage, both counts, song and clock. After the
  load she must be in it. These are B7's `round trip` and `load` grades, at every station.
- **The flags.** The three marks must be dead in the record's window. After the load, the
  saved buffer must be the record's, and the live array must hold the station bank's marks.
  A warp to the orb then loads nothing.
- **The map.** The background over the camera's view after the load must be the one she saved
  in. The `warp` rung grades that view against our Game Boy on arrival.

All seven pass. **The fault:** the load's search for the record's metatile table stops at the
first table (`LoadGameGraphics_metaTest`, `beq` to `bra`). Every station then fails on the view
(57), and the gate runs it on the first station.

**Not graded: the save's own merge of the live flags** (`SaveEnemyFlags`, 01:$7A6C). With it
taken out (`SaveEnemyFlags_put`), all seven runs still pass. Every room entry already merges the
live half into the saved buffer (02:$4197), and the menu's marks write the saved buffer too. So
the merge at a save matters only for a record in the station's own room, changed since she came
in. Of the seven stations' rooms, one has such a record: `$E:$55`'s Missile Tank (#6D), beside
`$E:$54`'s pad. It is buried in the blocks that fill `$E:$55`. A trip that walked over, firing
and jumping, stopped at their edge (`$0532`), and digging in with bombs is more script than one
orb warrants. This path is James's playtest (below).

**Two warp defects, found by the rung and fixed.** Neither station could be saved at.

- **`$A:$99`'s chain drew no pad.** `walkedChain` took the crawl's truth arrival from `$A:$79`
  (doors `$186`, `$1E1`), which draws the room with lavaCavesEmpty at every count, and that
  table draws no station. The recording settles what the room really is. In part 21 the
  player comes in from `$C:$C7` through `$0E1` at $09, and from `$F:$FC` through `$17F` at $01.
  Both doors keep the caveFirst the room before had, and `set worlds` shows table 4 at both
  visits. Both visits are pinned misses in `src/worlds_misses.txt`. `gbtrace -- <part 21>
  saves 7000 9000` gives the save made there: Samus at `$096C,$09B0`, and `$D808`-`$D814`
  `20 6D 07 00 58 80 50 80 44 0A 63 5D 63`. A station's chain now has to draw its pad when
  some walked door does (`walkedChain`'s `pad`). `$A:$99` takes `$055` then `$0DB`, which
  leaves the recorded block in all but `$D809`, the enemy page, which no chain loads. Her spot
  is the recorded one too. The test that holds an entry to its room's truth arrivals now skips
  a station whose truth arrivals draw no pad. The new test holds `$A:$99` to the recording
  instead.
- **`$E:$54`'s spot was beside the pad.** A station's spot was the standing spot nearest the
  middle of the pad's upper metatile. `nearest` measures from `y + 10`, so a floor 24 px lower
  and one column over came out nearer than the pad. She stood with no contact (exit 50). The
  point is now her feet on the pad's top, at its middle. The other five stations' spots do not
  move.

A unit test, "every station's warp stands her on its pad", fails on both of the old answers.

**`$F:$04`'s enemy.** The record beside the pad (spawn `$2E`) hits her on the frame she
arrives. The `warp` rung has counted that hit since Step 5c. The trip walks her back as a player
would: toward the pad, jumping with B while she is below it, until the contact has held for four
frames.

**Not ported, and so not the reset used:** the Game Boy's soft reset, A+B+Select+Start
(00:$02E1, `jp z, bootRoutine` in `mainGameLoop`). B7 Step 15c left it out. A player on the cart
has the console's reset button instead.

## 1.0 Step 24a: the 100% recording, as one run (C10, 2026-09-28)

James recorded a 100% run in Mesen2 2.2.1 as **25 ordered segments**,
`reference/metroid2-100p-recording/metroid2-100-part01..25.mmo`. It collects every item and
every beam pickup, duplicates included, beats Arachnus, crosses the dark room, kills the Queen
and plays the ending. All 25 name our cartridge's SHA-1 and carry their own `SaveState.mss`.

`zig build gbtrace -- reference/metroid2-100p-recording set` takes the directory as one run.
Each segment is censused whole at the narrowest stride one pass holds, 6 to 41. Every seam is
checked, and the events land on one frame axis (`build-out/set-metroid2-100p-recording.tsv`).

**It is one continuous run of 485 325 frames (2 h 15 m).** Each seam is checked by
`gb_trace.seam`. The pass digests the whole of work RAM on its first and last four frames, and a
seam is exact when a tail frame is a head frame. **All 24 are exact, tail 3 to head 0**: each
segment was started from the state the one before it stopped in. So a segment's embedded seed is
the oracle for the previous one's end, the check `slice.md` proposed for segmented recordings.

**It replays faithfully end to end.** No segment has a refusal over 60 frames except part 25,
at 652 frames from its frame 319: the ending, which takes no input. Every pass ran to its
segment's last frame and exited 0.

**The clock reads 2:06 at the end** (`$D099:$D098`, BCD). The ending is chosen on the hours:
under 3, 3–5, 5–7 and 7 or more (`cp $03`, `$05`, `$07`, bank 5). So the recording is the best
ending, and C7's other three are graded from the Game Boy set up at a clock, as planned.

### Kills

48 decrements of `$D089` for 47 Metroids. #8 is undone by the death in part 06 (frame 18 315,
the count reads 00, then the reload's 40), and #9 is the same Metroid again. #48 is the Queen.
"Frame" is the segment's own; "run" is the frame on the joined axis. Times are to the census
stride, so a kill is placed within 6–41 frames; `kills` (24c) takes them exactly.

| # | part | frame | run | cell | count |
|---|---|---|---|---|---|
| 1 | 01 | 6220 | 6220 | $F:$10 | 47 → 46 |
| 2 | 03 | 2329 | 34316 | $E:$07 | 46 → 45 |
| 3 | 03 | 14263 | 46250 | $B:$BE | 45 → 44 |
| 4 | 04 | 2254 | 48851 | $B:$C9 | 44 → 43 |
| 5 | 04 | 4466 | 51063 | $B:$C4 | 43 → 42 |
| 6 | 05 | 5945 | 64373 | $B:$23 | 42 → 41 |
| 7 | 05 | 20851 | 79279 | $D:$93 | 41 → 40 |
| 8 | 06 | 13616 | 97801 | $D:$76 | 40 → 39 |
| 9 | 07 | 9002 | 126240 | $D:$76 | 40 → 39 |
| 10 | 08 | 24820 | 153895 | $D:$04 | 39 → 38 |
| 11 | 08 | 30260 | 159335 | $B:$DF | 38 → 37 |
| 12 | 09 | 1476 | 161210 | $B:$D9 | 37 → 36 |
| 13 | 09 | 3690 | 163424 | $B:$EC | 36 → 35 |
| 14 | 09 | 6191 | 165925 | $B:$E5 | 35 → 34 |
| 15 | 09 | 35711 | 195445 | $C:$38 | 34 → 33 |
| 16 | 10 | 11508 | 207459 | $E:$85 | 33 → 32 |
| 17 | 10 | 15820 | 211771 | $E:$A3 | 32 → 31 |
| 18 | 10 | 23576 | 219527 | $E:$B3 | 31 → 30 |
| 19 | 11 | 13098 | 234189 | $B:$A8 | 30 → 29 |
| 20 | 11 | 15392 | 236483 | $B:$AB | 29 → 28 |
| 21 | 11 | 18204 | 239295 | $B:$39 | 28 → 27 |
| 22 | 11 | 21460 | 242551 | $B:$3B | 27 → 26 |
| 23 | 11 | 27639 | 248730 | $C:$88 | 26 → 25 |
| 24 | 11 | 31783 | 252874 | $B:$2E | 25 → 24 |
| 25 | 12 | 11808 | 265961 | $B:$45 | 24 → 23 |
| 26 | 12 | 24682 | 278835 | $A:$36 | 23 → 22 |
| 27 | 12 | 31775 | 285928 | $A:$17 | 22 → 21 |
| 28 | 13 | 16470 | 307531 | $B:$57 | 21 → 20 |
| 29 | 13 | 20250 | 311311 | $E:$08 | 20 → 19 |
| 30 | 13 | 26280 | 317341 | $A:$F8 | 19 → 18 |
| 31 | 15 | 2850 | 328366 | $E:$3A | 18 → 17 |
| 32 | 15 | 26460 | 351976 | $A:$F5 | 17 → 16 |
| 33 | 16 | 4144 | 356606 | $B:$00 | 16 → 15 |
| 34 | 16 | 9324 | 361786 | $B:$04 | 15 → 14 |
| 35 | 18 | 7068 | 387986 | $B:$66 | 14 → 13 |
| 36 | 18 | 13661 | 394579 | $B:$8E | 13 → 12 |
| 37 | 19 | 10545 | 407997 | $F:$E1 | 12 → 11 |
| 38 | 20 | 2580 | 416350 | $B:$75 | 11 → 10 |
| 39 | 20 | 11920 | 425690 | $F:$B0 | 10 → 09 |
| 40 | 21 | 15840 | 447150 | $E:$32 | 09 → 08 |
| 41 | 21 | 16740 | 448050 | $D:$42 | 08 → 07 |
| 42 | 21 | 17670 | 448980 | $D:$33 | 07 → 06 |
| 43 | 21 | 18150 | 449460 | $D:$23 | 06 → 05 |
| 44 | 21 | 18750 | 450060 | $E:$05 | 05 → 04 |
| 45 | 21 | 19530 | 450840 | $E:$03 | 04 → 03 |
| 46 | 21 | 20670 | 451980 | $D:$00 | 03 → 02 |
| 47 | 21 | 21510 | 452820 | $D:$10 | 02 → 01 |
| 48 | 23 | 5481 | 470490 | $F:$FE | 01 → 00 |

### Pickups

Items, from `samusItems` gaining a bit:

| item | part | frame | cell |
|---|---|---|---|
| Bombs | 02 | 1 312 | $D:$44 |
| Spider Ball | 02 | 13 504 | $C:$13 |
| Varia | 05 | 25 317 | $D:$60 |
| Spring Ball (Arachnus) | 07 | 3 850 | $D:$C0 |
| Hi-Jump | 08 | 9 214 | $D:$D9 |
| Space Jump | 09 | 27 224 | $E:$61 |
| Screw Attack | 15 | 5 850 | $E:$2B |

**Beams**, from a log of every change of `samusBeam` ($D055) the pass plays through. It is
kept in the last 61 bytes of cart RAM, after the rows. The beam is not a column, because the
record is the one graded stretches read too, and three more bytes a frame would cost every
stretch 85 frames. So the frame is exact and there is no cell. The end state alone missed both
spazers: each was picked up and replaced inside one segment.

| beam | part | frame |
|---|---|---|
| Ice | 02 | 6 092 |
| Wave | 07 | 11 364 |
| Spazer | 10 | 7 476 |
| Plasma | 10 | 16 893 |
| Spazer | 17 | 2 026 |
| Wave | 17 | 7 842 |
| Ice | 17 | 8 844 |

Part 06's death reads the beam as power at 18 293 and the reload puts ice back at 18 348;
neither is a pickup.

**Energy tanks**: 5, the last at part 15 frame 19 350 ($9:$22). **Missile tanks**: 22, taking
the maximum from 30 to 250 (BCD at $D081; the census prints it in hex).

### What 24b-24e take from it

- **24b**: `ais` per segment, for the AIs the run dispatches against the ROM census.
- **24c**: `kills` around each row above, for exact ticks; and the METROIDS page in this order.
- **24d**: the cells it visits for the `worlds` grading, and its cutscene durations.
- **24e**: which window, if any, joins the gate.

## 1.0 Step 24b: the AI census over the 100% run (C10, 2026-09-28)

`zig build gbtrace -- <segment> ais` over each of the 25 segments, unioned: every AI the
dispatch at 02:$5650 jumps to, with its sprite, first cell and frames. Held in
`enemy_oracle.recorded_census_100`. A unit test holds it inside the ROM census or
`roster.children`, and fails naming any AI it finds outside both.

**42 AIs dispatched, of 42** (first recorded as 41: see below). The ROM census has 39 AIs
plus 2 children, and the run dispatches:
- all 39 (the list first left out `blobThrower`);
- both children;
- **one the census missed: 02:$52DF, `enAI_arachnus.fireballAI`**. Sprites $7B/$7C, in
  $D:$C0, part 07 frames 1 463-3 655.

**The miss.** The fireball is not installed by a slot write, the pattern the census's child
scan looks for. Arachnus spawns it from a long header of its own at 02:$52D2 through
`enemy_spawnObject.longHeader`. No spawn record names that header, so the spawn walk cannot
reach it. It is now the third `roster.children`, site 02:$52DD (the header's AI word), parent
Arachnus, and it is ported with Arachnus in Step 13. The test was shown failing with the child
dropped: `02:52DF: a recording dispatches it and the census misses it`.

**Closed in Step 12: `blobThrower` is dispatched.** This was first recorded as never
dispatched, though its projectiles are (`blobProjectile`, 02:$536F, sprites $9E/$9F, 933
dispatches in part 07 from frame 122 around `$9:$1B`). Re-run, part 07 dispatches the thrower
642 times from frame 100 in `$9:$1B`, through the ordinary dispatch. The omission was in the
list, not the run. See 1.0 Step 12.

**Also seen:**
- `enAI_NULL` runs (part 22, $E:$21), as the census expected.
- The Queen's fight (part 23) passes no enemy AI at all: the Queen is `queenHandler`, not a
  slot.
- A dispatch on the partial frame the savestate loads into is dated frame -1 (printed as
  4 294 967 295, part 25). This is the hook's arithmetic, not the game's.

## 1.0 Step 18f: every warp can be walked out of (C8, 2026-10-01)

**Metroid 11's sealed tunnel was the tileset, not the spot.** James's playtest (2026-09-29)
found the warp to `$B:$45` leaving Samus in a morph-ball tunnel with no way out. The entry
was `seeded`, through `$055`, `$1F0`, which draws the room with caveFirst. The recording's
Game Boy shows lavaCavesEmpty at $24 there (`set worlds`, `B 45 24 6`). In caveFirst the room
reads as rock with pockets, and the nearest floor to the Metroid was one of them.

**The warp table now holds to the recording.** `src/recorded_tables.txt` is every visit `set
worlds` grades, with the table Mesen's Game Boy showed (953 lines). An entry whose cell the
recording visits, or failing that its room, needs a chain that leaves the table of the
recording's first visit (the highest count) at that count: its own when it does, else a door
into the room, alone or after a loader of the table. **No warp needs a count set first**
(James, 2026-10-01): every chain runs at the live count, so a room's other tables draw at any
count only through a chain that does not test it, which is preferred. **A lava room keeps its
lava.** Its chain must leave a lava table at $47 too, and best is one whose level moves with
the count as the area's own lava doors' does. Metroid 11's area is entered through `$04A`
(and `$05E`): lavaCavesMid at $47, lavaCavesEmpty from $46, so about the bottom five tile
rows are lava until the first kill. lavaCavesFull, which fills both cells, no door loads
here. 24 of the 153 warp cells the recording visits had disagreed with it, among them
`$C:$98` and `$B:$39` (caveFirst for plantBubbles), `$E:$B0` (finalLab for ruinsInside),
`$D:$33` (surface for finalLab) and `$F:$5E` (caveFirst for surface). 20 entries moved
(`roster` prints them as `recorded`); the rest were lava rooms the recording found drained,
which keep $47's level.

**Where a player gets to (`warp.reach`).** A ball with every item, so anywhere two tiles are
clear, flooded from where each of the room's doors fires. Destructible blocks count as cleared:
a tunnel behind one is a way in (James, 2026-10-01). A door fires where `HandleCamera` says,
not at the cell's edge: down, falling with her y at $D6 or more, so a warp in through a door
down (`$09A`, `$B:$F1` to `$A:$06`) puts her low in the next cell, not at its top. Standing
spots are chosen inside the reach; a destination with none is a finding. One spot moved,
`$B:$B4` (Metroid's room before, inferred).

**The reach graded against the recording.** Every position Samus held in a warp room, at a
count where the entry's chain leaves the table the recording shows, has to be in reach under
that table: 35 849 of 35 888. The 39 out are frames of an edge crossing. Two readings were wrong until the recording said so:

- **Tiles $00-$03 are respawning blocks**, whatever the collision table says (01:$2433 and
  01:$16FC test `cp $04` before the table). The recording walked through them into the ruins'
  item chambers (`$D:$4D`, `$D:$C7`, `$D:$D7`). On the Game Boy's tilemap the blocks were
  gone. Without the rule, 179 positions are out of reach.
- **The baby's block, tile $64** (`baby_checkBlocks`, 02:$7D2A), is eaten after the Queen. At
  count zero the reach clears it; 330 of `$F:$5E`'s post-Queen positions needed it.

**A door is a way out only if she comes out of it** (James's playtest, 2026-10-01). Metroid 11
works. The skreek route from it, down through `$B:$44`'s floor, does not: the floor is lava
over a blocked edge whose door, `$1AA`, crosses into `$B:$54`'s top, which is rock. The reach
now checks the far side where it is known, a door script into the cell beside that loads no
table (`lands`). Checking more lost real exits: with `WARP`s and table-loading doors checked
under tables it can only guess, 292 recorded positions fell out of reach; with crossings that
run no script checked, Metroid 01's room had no way out. The warp table is unchanged by it.

**What else moved.** Metroid 10's room (`$B:$3B`) was a finding, with no standing spot in
ruinsExt; in the recording's plantBubbles it has one. 163 entries, 3 findings. The rooms
before Metroids 13 and 22 stay `$C:$0D` and `$B:$DD`: Step 1's `$A:$E0` and `$A:$E7` are lava
rooms no chain keeps lava in at $47.

**The `warp` rung at each entry's count.** Our Game Boy runs each chain at its entry's count,
and the cart reaches it on METROIDS by switching the first rows both ways, killed to go down
and revived to come back up. Every entry but the Queen's is at $47 now; the switch is kept for
the list order it no longer assumes.

**Not changed:** the crawl's `through` still counts only the collision table's destructible
bits, so it does not stand Samus beside a respawning block's far side
(`docs/bug_tracker.md`). The reach does not model the ruins' warp in `$E:$D3`, still a finding.


## 1.0 Step 19a: the Queen oracle, and her bands out of NMI (C4, 2026-10-01)

Step 19 is split as it goes: her code is bank 3's $6C8E-$7DAC, about 3 300 lines of M2RoS, so the
oracle comes first and the port is graded against it as it lands (19b, the fight she runs on her
own; 19c, the hurt and the flash).

### The oracle

`zig build queen -- oracle` writes `build-out/queen_fight.{sfc,lua}` (`src/queen_oracle.zig`). Our
Game Boy enters her room by door $19D's index set between frames (`queen.enter`), the debug cart
by the menu's QUEEN row, as the `queen` scenario does; neither is handed any of her state. Samus
stands where she lands, with the new game's loadout on both, and nothing presses a button.

Every frame, each machine's **whole `$C300` page**, her **thirteen slots** at
`enemy_oracle.sample_fields`, and **Samus's position, pose and health**: 378 bytes. Each byte's
history is collapsed to its runs, and the cart's must be the Game Boy's in order, as the enemy
oracle's slots are. The Game Boy runs 8 frames past the cart, and a cart history may end one entry
short, so a phase difference at the window's end is not a failure. A failure names the byte, the
frame, and the Game Boy's entry with the frame it began; a history the cart never moves on from
names the frame the Game Boy's did.

- **The cart keeps her page as the Game Boy's**: `!QueenPage` = $1500, page-aligned, so a Game Boy
  address maps by its low byte and a pointer into the page keeps its low byte.
  `QueenInitialize` clears all 256 bytes, as 03:$6D4A does. Step 6's variables are now offsets
  into it.
- **Not graded: the fifteen page bytes that are addresses outside the page** (the state list,
  the neck patterns, the head's source, the LCD handler's walk, the death's VRAM and tilemap,
  `queen_pOamScratchpadHigh`). Each is named in `queen_oracle.pointers`. What each drives is
  graded.
- **One `rDIV` read**, `queenStateFunc_prepExtendingNeck`'s mouth toss at 03:$78D1, is recorded on
  the Game Boy (one read in the window, $31) for the cart's script to hand across once 19b ports
  it.
- **`frameCounter`'s phase**: our Game Boy's is $C4 on the first frame and the cart's $66. The
  parity agrees, which is all the neck's retract (`and $01`, 03:$73B1) reads; the hurt flash reads it mod
  4 (`and $03`, 03:$6E4A), where they differ by two. That is 19c's to settle against a hit case.
- **The window is 604 frames.** With no input she runs her whole state list (startA, startB, a
  walk, two lunges, a walk back, her projectiles) and kills Samus: `deathFlag` rises on our Game
  Boy's frame 614, and the window ends 10 frames before it. A death is Step 20's.

**Shown failing on the engine as it stands**: 159 of 378 histories part. The bytes Step 6
ported agree until she moves: her body's and head's Y, the camera, Samus's fall (66 entries) and
her actors' Y. What parts is what she lacks: `queen_initialize`'s wall sprites and the
delay's first tick at frame 0, then `queen_state` staying $17 where the Game Boy's goes to $18 at
frame 140. That is the fixture 19b turns green. It stays out of the gate until then.

**It found one defect in Step 6's port**: `queen_drawHead` stored `queen_headDest` after every
row, so it ended a frame at $C0; the Game Boy keeps the row in L and stores it only when the
first half hands the second to the next vblank (03:$7058), so it holds $60 (`bug_tracker.md`).

### The bands out of NMI

`QueenPass` (bank 1), from the top of `MainLoop` ahead of `PassEnd`, builds `VBlank_drawQueen`'s
list and the three tables from what the pass leaves, into the pair NMI is not reading. Two of
each table: TM at $1600, BG3's scroll at $1680, W2's edges at $1780, the B tables at +$40, +$80
and +$40. `QueenNmi` draws the head, flips to the new pair when the pass has finished one
(`!QueenReady`), and points the channels and BG2 from the front pair's latched WX and WY. A pass
that overruns into the next frame leaves the old pair up for that frame. Outside her room, or
with the menu up, nothing is built and NMI forgets both pairs.

| | Step 6 | 19a |
|---|---|---|
| NMI ends, her room (over 721 frames) | line 257 (Step 6's doc says 256) | line 237, once 240 |
| the pass's build ends | | by line 125 |

Measured with an exec callback on the NMI's `rti` and on `QueenPass`'s end, reading Mesen's
scanline, on the `queen` scenario's cart; the same script on the engine before the move read 257.
Twenty lines of vblank are back for her feet, the neck's objects and her death's tiles. The
`queen` scenario holds: Samus's fall and the three pictures are the Game Boy's.

## 1.0 Step 19b: the fight she runs on her own (C4, 2026-10-01)

Ported branch for branch from bank 3 (all in bank 1, +2 592 bytes, 7 859 left):

- **`queen_initialize` whole** (03:$6D4A): the neck's sums, the twelve wall objects down the
  right edge and their head alignment, the state list's pointer.
- **`queenHandler`** (03:$6E36) but for `queen_headCollision` (19c's): the dying arm, the
  hurt flash on her objects' OBP bit, the health flags, and its eleven calls in order.
- **The state list** (03:$7484) and states $00-$07, $0C and $14-$18: the walks, the
  lunges and their retraction, the spit, the list's pick and its start. Her eating,
  stomach and death states ($08-$0B, $0D-$13) are Step 20's; until then the first one
  reached is recorded in `!EnUnhandledState`, the menu's STATE.
- **`queen_walk`, `queen_moveNeck`** (with the missile's paralysis arm, which nothing sets
  until 19c, and the low-health double step), **`queen_drawNeck`**, the spit's five routines,
  `queen_adjustSpritesForCamera`, `queen_setActorPositions`' two neck arms.
- **`queen_writeOam`** (03:$7140): her page keeps the Game Boy's OAM entries (Y, X, tile,
  attribute) at $08 and $38, as the original does, and each goes to the shadow through
  `PutObject`, which converts one.
- **`queen_drawFeet`** (03:$706A) in NMI, ahead of the head it shares the vblank with: each
  cell into VRAM and into `!TilemapBuf`, which collision reads as the Game Boy reads its map.
- **Four `physics` blobs**: `queen_neckPatterns` (03:$6C8E), `queen_feet` ($70C4),
  `queen_stateList` ($7484) and `queen_walkSpeeds` ($7C39), each pinned by the loads that
  read it (`correspond.zig`). The neck and feet tables keep Game Boy addresses, which the
  engine turns into offsets against the pinned bases; the feet are copied to RAM at entry for
  NMI, as the head frames are. `queen_eatingState` ($D090) has a byte, `!QueenEating`.

### The oracle, green

`zig build queen -- oracle` passes all 604 frames: 378 histories, the Game Boy's. Two things
it needed that were not port defects:

- **Where the cart's frame is read.** Read at Mesen's end of frame, before NMI, the cart showed
  `queen_headFrameNext` $02 and `queen_footFrame` $02 for a frame where our Game Boy, read past
  its vblank handler, already holds $FF and $82: her head and feet are drawn in the vblank and
  step what her states set that frame. The script now reads each frame where the main loop
  wakes from NMI (`MainLoop_woke`).
- **`frameCounter`'s phase.** Her neck retracts on odd frames (03:$73B1) and the hurt flash runs
  on one frame in four (03:$6E4A). The counter is free-running on both machines, and at her
  entry the cart's was one off: it retracted on frames 263, 265 and 267 where the Game Boy did
  on 264, 266 and 268, and the histories parted at 265. The script hands the Game Boy's counter
  into `!FrameCount`'s low byte on the first frame, as it hands the mouth's `rDIV` toss
  (03:$78D1, $31) to `QueenPrepExtend_coin`. What each reads is still graded.

It joins the gate as the `queen` rung, with four of her routines taken out (`rts`), each of
which must part (48): `QueenPrepExtend` (the plan's state blanked), `QueenSeekAxis` (the spit's
chase), `QueenDrawNeck` and `QueenDrawFeet`.

Not graded here, and 19c's: what she draws (her objects through `PutObject`, her feet in the
map) beyond the bytes that drive it, her hurt, and BGP mid-frame. A look at frames 200, 250,
290, 420 and 460 shows the walk, a lunge with its neck pairs, the spit and the wall's objects.
`ledger.zig` gets rows for the four of her routines the ledger finds as boundaries
(`queen_initialize`, `.neck`, `queen_adjustWallSpriteToHead`, `queen_setActorPositions`);
the ledger's trace does not reach `queenHandler`, so nothing it calls is a boundary yet.

## 1.0 Step 19c: the hurt and the flash (C4, 2026-10-01)

Ported branch for branch from bank 3, into bank 1:

- **`queen_headCollision`** (03:$6EA7), the end of `queenHandler`: the flash's countdown, then
  the frame's shot. A missile on either half of her head, or in a mouth that is not open,
  costs one health, starts the eight-frame flash with BGP $93 and her cry (the low-health cry
  once `queen_lowHealthFlag` is up). It spends `collision_weaponType`; nothing else reads it
  in her room. The original tests the actor's address, high byte then low; the port keeps a
  slot offset and compares it whole.
- **`queen_missileHurt`** (03:$7436) and **`queen_closeFloor`** (03:$7AA8): the kill's
  branch (the head falls, she stops, her actors go, the floor's two cells close) is ported
  and reached only by Step 20's kill. The cells go into `!TilemapBuf` and `QueenNmi` copies
  the two words up.
- **00:$3293's Queen arm**: a missile in her open mouth writes `queen_eatingState`'s $10,
  where it recorded `!PrUnhandled`. `QueenMoveNeck`'s stun (19b) runs on it.

### BGP mid-frame

`QueenApply`'s commands 1 and 2 now carry BGP as the LCD handler writes it: command 1 the
body's `queen_bodyPalette` unless zero, command 2 $93; each frame starts at `bg_palette`.
**Our substitution, as `ApplyPalette`'s is**: each run's BGP becomes two more channels of
the TM table's shape, written at its offsets. **Channel 4 is INIDISP**, the brightness
`ApplyPalette` gives the same palette (its mapping is now `PaletteBrightness`, in bank 1,
which both call). **Channel 3 is COLDATA**: her flash's other phase, $93^$90 = $03, turns
every shade but colour 0 white, which no brightness can show. In her room CGADSUB adds the
fixed colour to BG2 and BG3 (the head and the room) and COLDATA is black, which adds
nothing, except on a $03 run, where it is white. Colour 0 is the backdrop there, which is
not added to, so it stays black, as BGP $03's first field is. It is exact for the greys.

Channel 4 makes a hazard: a forced blank set mid-frame is lifted at the next run. `QueenOff`
(the `.off` path out of `QueenNmi`) turns her channels off, and `GameOverScreen` calls it
before its forced blank, since NMI does not run `QueenNmi` through a death.

In every fight we can reach, BGP is the same down the screen but for the flash. Door $19D's
fade on our Game Boy is uniform (command 2's $93 is not in the list then), and the debug
warp the cart enters by does not fade. So the INIDISP band is graded only at full
brightness: no reachable case makes it differ from the frame's.

### The volley

The oracle has cases now. `still` is 19b's fight. `volley` holds both machines to one pad:
missiles selected as she falls in, a turn to face her, a shot every 24 frames and every 6
while her mouth is open. On our Game Boy the head takes missiles from frame 274, the open
mouth one on 332, which stuns her, and the stunned mouth more. It passes 658 frames, 380
histories, the Game Boy's, with `queen_eatingState` and `collision_weaponType` graded beside
her page. It also compares the play window (objects aside) on seven frames and her BGP
bands line by line on four. Our Game Boy shows the body's band at $03 on 278-281, a frame
behind `queen_bodyPalette`. Its faults: `QueenHeadCollision` taken out (48, health never
falls) and `QueenSetBgp_flash` taken out (49, frame 278's window is not the Game Boy's).

Getting there took three things that were not port defects:

- **A shot held one frame is a press our Game Boy can miss**: on a frame its main loop has
  overrun, the pad is not read. Shots are held four frames, and the edge fires once.
- **The pad is keyed to vblanks, not passes**: our Game Boy is stepped a vblank at a time, so
  a pass either machine overruns costs it what it costs a player. Keyed to passes, a cart
  that lagged took the edge two passes early and found the missile slot still full.
- `sfxRequest_noise` is not graded: our Game Boy's `handleAudio` clears it within the frame,
  and the cart's byte is a recording stub. `audio_sites` holds the cry's store to a put.

And one that was. Keyed to vblanks, the volley parted at frame 269: **the cart lagged where
our Game Boy did not**. Her room's pass is about 180 lines idle. A missile in flight adds
about 25 (its box against her thirteen slots, and Samus's three passes over them), and in a
lunge passes reached 238-248 and overran four frames running (`docs/bug_tracker.md`). An
instruction profile of those passes put `PutObject` first (22%, her forty-odd objects) and
`LoadEnemyBox` second (16%). Three local changes, each behaviour-preserving:
`PutObject`'s high-table pair from two four-entry tables instead of a shift loop, its
attribute byte from a 256-entry table (`PutAttr`), and `LoadEnemyBox`'s hitbox pointer read
as one word. The busiest pass is now 234 lines, and the worst ends on line 209, 16 before
vblank. That is thin. The cart is SlowROM (2.68 MHz); FastROM is the broad lever, for
James to decide on.

`ledger.zig` gets no rows for her three new routines: the ledger's trace does not reach
`queenHandler`, so nothing under it is a boundary yet (as in 19b). `CollideProjOneEnemy` is
`converted` now that its Queen arm writes `queen_eatingState`.

## 1.0 Step 20a: eaten, and bombed out of her mouth (C4, 2026-10-01)

Ported branch for branch:

- **Samus's Queen poses** (00:$0D87-$0EA4): $18 `poseFunc_beingEaten`, drawn into the stunned
  mouth a pixel a frame on each axis; $19 `poseFunc_inMouth`, held at ($A6, $6C) and let go
  by the eating state's $05 or $20, swallowed on a press of left; $1A-$1C, the swallow, the
  stomach and the throw up, which 20b's stomach case grades; and $1D, which is
  `poseFunc_morphBombed`. All six draw as the ball (`samus_drawJumpTable`). They move the
  pixel bytes alone, as the original's `LDH` to `hSamusYPixel` does. One branch is kept as
  the original has it: X's match is counted with `INC C` and a `JR Z` that never jumps, so
  an aligned Samus still moves left two, and her X shakes while her Y closes in.
- **`gameMode_Main.queenBranch`** (00:$0578): while she has Samus there is no `hurtSamus`, no
  cutscene or door arm, no `handleItemPickup`, and the enemies' call has no door test
  (`EnemyPass_noDoor`).
- **`applyDamage.queenStomach`** (00:$2F29): the acid's sound every eighth frame, two units
  every sixteenth.
- **The eating capture's `queen_eatingState` $01** (00:$343C, $3644), beside the pose it
  already wrote; **the bomb's two arms** (00:$3187-$31AF, `QueenBombArms`); and
  **`samus_tryShooting`'s $22 gate** (00:$2203), which three comments recorded as unported
  while the byte had no writer.
- **Her states $0D-$10** (03:$772B-$7811): the neck back with Samus in, the mouth shut, the
  bomb on her head (ten health, the cry, the flash, the stun's $3E), and the walk back taken
  up from the list's seventh entry (`QueenPickNextState_direct`).

### The `mouth` case

The oracle's cases can start with **FULL LOADOUT**: the cart takes the menu's row before its
warp, and our Game Boy is written the same items, tanks and missiles, decoded from the pickup
routines (`scenario.pickups`). The script is the volley's opening to the stun on 332, then the
ball and a Spring Ball jump left. On our Game Boy she is eaten on 354, is in the shut mouth on
410, lays a bomb on 420 that lands on 516 ($92 to $88), and is thrown out on 517; she walks
back on 579. It grades 700 frames, 380 histories. Faults: `QueenBombArms` (the eating state
stays $03), `QueenSamusEaten` (stays $04) and `ApplyDamageStomach` (her health holds), each
48.

Two things were the harness's, not the port's:

- **`Hold.a` pressed the Game Boy's A and Mesen's A**, and the cart's jump is SNES B. No case
  had pressed it before. It is `Hold.b` now, the Game Boy's A and Mesen's B, as `y` is
  already the Game Boy's B.
- **Our Game Boy lags in her room**, on 53 of `still`'s 604 frames and 89 of `mouth`'s 700
  (its `frameCounter` does not move between two samples). `VBlank_drawQueen` builds
  `queen_headBottomY` and the LCD handler's list every vblank out of whatever the pass has
  written. On `mouth`'s frame 520, as the bomb lets her go, it built them from a pass half
  done, so three values of the list exist only on the cart, which kept up. The requirements
  count lag as the port's defect, not the original's to copy. On our Game Boy's lag frames
  only, those ten bytes may hold a value its vblank never built (`vblankBuilt`). Each such
  value is printed, and their count is pinned per case (`Case.unbuilt`: 0, 0, 3), exit 51
  on any change.

Tooling: `zig build queen -- probe <case> [from] [to]` prints our Game Boy's run of a case
(her state, the eating state, the mouth, the head, Samus on screen, the frame counter), which
is how the script was written. M2RoS builds byte-identical with rgbds from `vendor/m2ros-src`
plus `extract.py`; its `.sym` names every address quoted here.

## 1.0 Step 20b: her stomach (C4, 2026-10-01)

Ported branch for branch, 03:$7970-$7AA7:

- **State $08** (`queenStateFunc_stomachBombed`): the neck out along pattern 4 from its
  second byte, the head up, and the neck drawn bent: five objects written by hand from
  `queen_bentNeckSprite` (03:$7961, a new physics blob, 57) into her first five, with
  `queen_neckDrawingState` zero so `queen_drawNeck` adds none, and `queen_stomachBombedFlag`
  set, which three readers ported in 19b already test (the neck's one actor, the camera's
  adjustment, and `queen_moveNeck`'s $D0 floor). $7970-$7976 load `queen_headY` and
  compare it with $2C and $71, and nothing reads the flags before the stores after them
  overwrite them: not ported, and said so in the comment.
- **States $09-$0B**: the neck out, $50 frames with the feet stopped at their second frame,
  then her palette back and thirty off her health; the neck back, the bent neck's objects off
  and the list's next state. `SUB $1E` with a `JR C` means that at exactly thirty she lives on
  at zero; kept.
- **`queen_killFromStomach`** (03:$7A4D), pulled forward from 20c because state $0A reaches
  it: her thirteen slots off, the neck out along pattern 5, the floor closed, the save-cleared
  noise and state $11, which 20c ports and which records into `!EnUnhandledState` until then.
  Her mouth's kill goes through here too: state $0F's kill sets the eating state $20 and state
  $08, so the head-bomb death is a stomach throw followed by this.

### The `stomach` case

The `mouth` script to the shut mouth (pose $19 on 412), then left on 440 and a bomb on 520.
On our Game Boy she is swallowed on 444 and in the stomach ($1B) on 504; the bomb's hit is
616 ($07, then $08 and state $08); she is thrown up the bent neck and out ($1D) on 656, her
health goes $92 to $74 on 708, and the walk back begins on 720. It grades 900 frames, 380
histories. Fault: `QueenStomachBombedState`, 48.

Our Game Boy lags every fourth frame while her head moves (162 of the 900). On eight of them,
as she swallows and as the neck goes out, its vblank builds three bytes of the LCD handler's
list from a pass half done; the cart builds them on time. The pin is 24 (`Case.unbuilt`).

`ledger.zig` gets no rows: its trace still does not reach `queenHandler`.

## 1.0 Step 20c: her death (C4, 2026-10-01)

Ported branch for branch, 03:$7ABF-$7BE7:

- **State $11** (`queenStateFunc_prepDeath`): once her head is down, $50 frames, the count of
  five, the eight bitmasks ($EE $BB $DD $77 twice), the earthquake ($D0), its song ($0E, a put
  only) and the eating state $22, which stops Samus switching to missiles (20a's gate).
- **State $12** (`queenStateFunc_disintegrate`): Samus's health refilled on the delay's fourth
  frame; then, each time the last bitmask is spent, the next: the entry at the index rotated
  three left, from $8B10 plus the index. The index steps three of eight, and each time it
  comes round to zero the count falls; at zero the body's delete begins.
- **`queen_disintegrate`** (03:$7B69): $1A bytes a frame, every eighth, ANDed with the bitmask
  to $9570. One Game Boy byte is two copies on the cart: BG3's 2bpp character (the id kept,
  `snes_target.charForTileId`) and, below $9000, the objects' 4bpp one, which BG2 (her head)
  reads too. Planes 0 and 1 are the Game Boy's two bytes and 2 and 3 are clear, so an AND of
  the one plane is exact.
- **State $13** (`queenStateFunc_deleteBody`): a row of eleven cells to $FF a frame, rows 13
  to 19, into `!TilemapBuf` at once (collision reads it as the Game Boy reads its map) and to
  VRAM in `QueenNmi` (`QueenNmiRow`); then the eating state and both Metroid counts zero, state
  $16, the count's shuffle ($80) and the baby's cry ($17).

### Her characters, out of NMI

Done as the Game Boy does it, reading VRAM back and writing each byte in NMI, the death's NMI
ran past vblank on 234 frames, the main loop waking on lines 1 and 2. The play windows still
matched, because the overrun fell after the writes; OAM and the channels' set-up after them
would not have survived it on the console. So the AND is done on two WRAM shadows in bank $7F
(BG3's $A60 bytes, $8B10-$956F in the Game Boy's order, and the objects' tiles $B0-$FF whole,
$A00), from `QueenPass` where `VBlank_drawQueen` calls it. `QueenChrSpans` leaves the spans it
changed: BG3's, split where it crosses $9000 (id $FF to $00), and the objects' whole tiles.
`QueenNmiChr` copies them out on channel 0. The shadows are read back from VRAM in eleven
chunks of $200 bytes at most, one an NMI, from state $11's last frame, inside the $50 frames
before the first bitmask.

| her death, over the `kill` case | NMI by hand | the shadows |
|---|---|---|
| main loop woken outside vblank | 234 frames, lines 1-2 | none |
| latest wake line | | 243 (250 in her fight) |
| lag frames on the cart | | none |

Mesen returns the word at VMADD twice after an address is set (the prefetch, then the read that
steps it), so each chunk's DMA from $2139 follows one read of its own; without it every chunk
began with its first word twice and the play window on frame 2 600 was 1 832 pixels apart.

### The `kill` and `mouth_kill` cases

`kill` is the volley's opening with FULL LOADOUT and a missile every eight frames until frame
2 530. On our Game Boy 150 land, in her head and her stunned mouth, the last on 2 497: state
$11, $12 on 2 498, $13 on 3 086, $16 on 3 093. It grades 3 250 frames, the play window on ten of
them (2 500 to 3 090, across the disintegration and the delete, and 3 240), her map's 79 cells
in VRAM at the end (exit 53) and her death's length, state $11 to $16: **596 frames on both,
100.00%** (exit 52 past 2%). Four bytes join the graded ones: `metroidCountReal`,
`metroidCountDisplayed`, `metroidCountShuffleTimer` and `earthquakeTimer`, and Samus's missile
slot's four, which is how the lag below was found (388 histories).

`mouth_kill` fires to 2 400. Her stunned mouth takes her under ten on 2 401; then the ball, the
jump into the mouth (in it on 2 482) and the bomb. 03:$7794's carry lets Samus go dying ($20),
state $0A finds no health and `queen_killFromStomach` runs. It grades 3 320 frames; **629
frames on both, 100.00%**. As in `stomach`, our Game Boy lags as her bent neck goes out, and on
four frames its vblank builds three bytes of her list the cart builds on time: pinned at 12.

**Presses kept off our Game Boy's lag.** The first `kill` parted at frame 2 213: a spit Samus's
missile destroyed on our Game Boy flew on on the cart. The missile slot showed the cause at 721.
Our Game Boy lags every other frame while her neck and spit are out. A press beginning on the
frame after a lag frame is read by a pass that began late, a frame sooner than when it keeps
up, and sooner than the cart, which keeps up. The missile on 680 flew a frame ahead from then
on. A press beginning on a lag frame itself is read when the cart reads it. Lag is the
original's, not the port's to copy, so `Case.off_lag` runs our Game Boy again with each such
press a frame later until none is left (`pressesOnLag`; 13 presses moved, on the lag stretches
around 680, 1 392 and 2 160). Both machines are handed the moved script. `zig build queen --
lag <case>` prints the lag frames and the moves.

**Not graded: the status bar during the shuffle.** `VBlank_updateStatusBar` draws the scrambled
count from `rDIV` for the 127 frames after state $16, so 3 095 and 3 150 were dropped for 3 240,
where "00" shows on both. The timer itself is a graded byte.

**Faults**: `kill`'s three death states (48); the copy out, `QueenChrSpans` (49, 160 pixels on
frame 2 600); the rows, `QueenNmiRow`: no screen sees it, because her spent characters draw as
$FF does, so the map's cells are read from VRAM (53, row 13 col 7 $0B where our Game Boy has
$FF). `mouth_kill`'s: the mouth's kill, `QueenSamusEaten_kill` (48, the health wraps and the
eating state stays $04), and `queen_killFromStomach` (48).

Not here: `EXIT_QUEEN`, `ESCAPE_QUEEN`, the quake's Queen branch (01:$7A13, song 1 when the
quake ends in her room) and the baby's egg, which are 20d's. `ledger.zig` gets no rows: its trace
still does not reach `queenHandler`.

## 1.0 Step 20d: out of her room (C4, 2026-10-01)

**The way out is door $19E, cell $F:$FE's**, crossed leaving her room. Decoded from the ROM:

| door | script |
|---|---|
| $19E | `COPY`, `IF_MET_LESS $00 → $19F`, `FADEOUT`, `LOAD`, `COLLISION 7`, `SOLIDITY 7`, `ITEM 2`, `ESCAPE_QUEEN`, `TILETABLE 0`, `SONG 8`, `WARP $E,$C1` |
| $19F | `FADEOUT`, two `LOAD`s, `COLLISION 4`, `SOLIDITY 4`, `EXIT_QUEEN`, `TILETABLE 5`, `WARP $F,$A9` |

At a count of $00 the door runs $19F into $F:$A9, beside the baby's egg. At any other count it
escapes into $E:$C1 with her alive. **Escaping alive is reachable**: the bottom exit (column
7's shaft, then row 14 rolled left) stays open until `queen_closeFloor` (03:$7AA8) seals it
at her death.

Ported (00:$2476 and $24CE, `DoorLeaveQueen` in bank 1):
- **Both clear rIE's bit 1.** M2RoS's comments call it vblank; it is the LCD interrupt, the
  one that walks her list down the frame. `ENTER_QUEEN` sets it at $2537. The port keeps it
  as `!QueenStat`, and `QueenNmi` turns her channels off while it is clear. Without it,
  `ESCAPE_QUEEN` would leave her bands running for the four opcodes before the `WARP`, since
  her room flag is still $11 until the `WARP` masks it.
- **Both copy `hudBaseTilemap` to the status bar**, where her head was in the window's first
  row. The arm copies it and NMI uploads it (`HudBaseNmi`); the frame the Game Boy waits for
  its own copy was already in `OpExtraFrames`.
- **`ESCAPE_QUEEN`** places Samus at pixel ($D7, $78) and the camera at ($C0, $80), the pixel
  bytes only; the `WARP` gives the screens. Its `loadSpawnFlagsRequest` of zero (00:$24B1) asks
  for a load without a save (02:$4061). The door's end has already asked for a save and a
  load, which runs first in the same pass, so the second load reads the same flags into the
  same slots. It is not kept.
- **`EXIT_QUEEN`** clears `queen_roomFlag` and puts rWY back to $88. Its rWX of $07 is
  `QueenOff`'s BG2 scroll, which follows once her channels go off.
- **The quake's Queen branch** (01:$7A10-$7A33, `QuakeQueenSong`): when the quake her death
  starts ends with her room flag at $10 or more, song 1 (the baby's) is asked for and nothing
  is held. Its waiver in `audio_sites` is gone.

**The egg** is the baby's spawn record at $F:$A7 (#42, sprite $A6, AI 02:$7BE5). Its AI is
Step 21's.

### The `exit` and `escape` cases

Seven bytes join the Queen oracle's graded ones: `queen_roomFlag`, the bank as the save buffer
keeps it (`$D811`; the cart's `!MapIndex` counts from 0), the camera's four, and `songPlaying`.
The cart reads `songPlaying` off the sound engine's reply, two ticks behind
(`docs/audio_protocol.md`). So its history may begin with the song before her room's
(`Var.lead`); after that it is graded as any byte.

- **`exit`**: `kill`, then left at 3 100 and a jump onto her spent body at 3 150. Door $19E on
  3 275 runs $19F; `EXIT_QUEEN` clears her room flag on 3 374, and the `WARP` puts Samus in
  $F:$A9 on 3 376. The quake ended on 2 913 with song 1 on both machines. Graded to 3 383.
- **`escape`**: the ball off the floor at 76-88 and left into the shaft. Door $19E on 163,
  `ESCAPE_QUEEN` on 256, the `WARP` into bank E on 261, her room flag $01 on 266. Graded to
  270.

**Both windows end at the arrival**: in each new room our Game Boy lags every fourth frame
(from 3 383 and 270). A lag frame steps the camera twice where the cart, which keeps up, steps
it once, so the cart shows a value the Game Boy's history skips. Lag is the original's, not the
port's to copy.

Gate 13m22s, 46 rungs; the `queen` rung's fault sweep 20/20.

**Faults**: `DoorExitQueen` (48: her room flag $01 at 3 376 where our Game Boy's went to $00);
`QuakeQueenSong` (48: `songPlaying` $00 at 2 917 where our Game Boy's is $01);
`DoorEscapeQueen` (48: Samus y $B9 and the camera y $A4 at 268 where our Game Boy's are
$D7 and $C0).

### The `$00` threshold

`doors` and `counts` now take door $19E and $19F (426 and 272 entries, from 424 and 270); only
`ENTER_QUEEN`'s $19D stays out, being the `queen` rung's. `countedEntries` no longer skips a test of $00. So `counts` holds all thirteen
thresholds on both sides. At $01, $19E escapes into $E:$C1 (stood in $E:$B1 beside it, which has
a screen). At $00, the cart has killed every METROIDS row, the Queen's last, and $19F exits
into $F:$A9. The opcode test over all 497 decodable scripts has no deferred script left, and
`roster`'s door coverage has no skipped opcode.

### The recording (C10)

`gbtrace -- kills` now watches `queen_state` ($C3C3) and `queen_roomFlag` ($D08B). Over part
23: state $11 on frame 4 881 and $16 on 5 477, **596 frames, as on our Game Boy and the cart
(100.00%)**. The quake ends on 5 297 in her room. Her room flag goes to $00 on 5 716
(`EXIT_QUEEN`), and the strided pass has Samus at $0A84,$08BA in bank F by 5 800: through $19F
into $F:$A9, as the `exit` case goes.

## 1.0 Step 22: the ending and the credits (C7, 2026-10-02)

**Two modes, and the ending is not a sequence of its own.** Mode $12, `prepareCredits`
(05:$587F), fades the room out and sets the credits up; mode $13, `creditsRoutine` (05:$55A3),
rolls them and draws Samus beside them, and three of the four endings only move once the
scroll is done. Nothing leaves mode $13 but the soft reset (00:$02E1): `credits_rebootGame`
(05:$5985) is reached by nothing. Steps 22 and 23 were merged for this (James, 2026-10-02).

### What the cart does

- **`!DeathMode` carries both modes**, $12 and $13, as it carries the death's three: it is the
  Game Boy's `gameMode` for the modes that replace the play handler. Bank 0 pays a dispatch
  in `DeathFrame` (`jml CreditsFrame`); the rest is bank 1's. `GameOverScreen` moved to bank 1
  to make the room (bank 0 had six bytes).
- **The way in is the missile refill's zero-count branch** (00:$399C). The port runs a pickup's
  arm in the last of its four waits, a pass before the Game Boy's; so the branch's stores (the
  countdown's low byte $FF, song interruption $08, mode $12) are made on the next pass,
  `!ITEM_CREDITS`, the Game Boy's frame of the arm, where the play handler's rest runs too.
  Start on that frame pauses, and the unpause's mode $04 loses the credits, as on the Game
  Boy. The fault test `refill_credits` now looks for mode $12 there.
- **The fade**: `credits_paletteFade[countdown >> 5]`, read from the end, into `bg_palette` and
  `ApplyPalette`'s INIDISP. Three of its palettes are new to the port: $A3, $A7 and $EB, each
  one shade of three darker than the last. Ours, as the four were: brightness 13, 12 and 8
  between theirs (15, 10, 5, 0).
- **The setup** is one pass with **NMI off**: the Game Boy's LCD is off for it and takes no
  vblank, so neither its frame counter nor its countdown moves. Our Game Boy's pass is
  487 080 t-cycles, 6.94 frames (`credits.setup_cycles`); the cart waits out six vblanks by
  polling and enables NMI in active display, `Reset`'s way, so the pass is seven. The text goes
  to cart RAM at $700800, the Game Boy's `creditsTextBuffer` at $A800: the 8 KiB SRAM mirrors
  the Game Boy's and has it free. The characters go where the Game Boy's copies put them
  (`CreditsChrRows`): the object sheets at 4bpp, the background's under the signed window's
  rotation. Two object sheets are new to `chr_obj`, classified by `prepareCredits`' own copies
  (`markCreditsObjects`); the region went from 64 to 72 KiB (93%), and `physics` from 4 to
  8 KiB, which the text (1 251 bytes) took past its 4 096.
- **The credits**: a pixel every fourth frame, a row on each eighth drawn by NMI from
  `HudBaseNmi` (NMI ends by line 236 on a row's frame, 233 otherwise); the clock once the
  scroll is done; sixteen stars, of which the setup copies eight (`LD B,$10`) and the other
  eight drop in from zero; Samus's 22 states, with both of the original's stores to the wrong
  half of the countdown kept.
- **The Game Boy's object buffer is forty**, and `drawNonGameSprite` does not stop at its end:
  past it the parts go to $C0A0 on, which nothing reads. In the suit Samus is 36 parts, so four
  stars show and twelve do not. The cart's shadow holds 128, so `CreditsOamLimit` parks what
  the Game Boy put past its forty. The rung found it on its first run.
- **`drawNonGameSprite`'s flips and attribute** (01:$7418-$7440) are ported: the run's two
  frames flip their legs. The title clears `hSpriteAttr` first, as its own code does at $418E.
- **The soft reset**: B, Y, Start and Select held (the Game Boy's A, B, Start, Select) reboot,
  tested at every `MainLoop` pass's top (`FrameTop`) and on the title. The Game Boy tests at
  the pass's end with the same pad, so the pass it reboots on does nothing first here.
- **The debug WARP page's ENDING** (C8): the QUEEN list's last row, a `warp_data` entry of
  zeros. `DebugWarp` enters the `!ITEM_CREDITS` frame from it, with the clock as CLOCK left it.

### The `credits` rung

Six clocks, each side of the hours `credits_animateSamus` tests (`CP $03`, $05, $07): 2:59 by
the game's own way in (every METROIDS row killed, the Queen's last, then `$F:$76`'s missile
refill, ten missiles short: the orb takes no touch at full), the other five by ENDING. Our
Game Boy takes the refill's lever with the same clock. Both are read at the top of every pass,
on the pass before's: the fade's palette and length, the characters, the scroll, the state, the
done flag and the objects' hash, to 600 passes past the ending settling, and the tilemap and
objects in full on six passes; then the reset combination to the title. The cart's frame
counter at the first credits pass is the route's own and pinned per clock; our Game Boy's is
set to it there. **It is a `verify-full` rung** (`zig build credits` alone): the gate took
16m20s with it, past its fifteen-minute budget.

| clock | route | fade passes | scroll done | settled | reset |
|---|---|---|---|---|---|
| 2:59 | refill | 242 | 7 166 | $15, pass 7 483 | 1 frame |
| 3:00, 4:59 | ENDING | 242 | 7 168 | $14, pass 7 303 | 1 |
| 5:00, 6:59, 7:00 | ENDING | 242 | 7 168 | at the scroll's end | 1 |

**Every pass agrees exactly**, on all six: durations are 100.00%. Faults, each on one clock:
the fade's index from the countdown's low bits (51), a pixel every second frame (54), the best
ending's `CP $03` made $04 (55), the soft reset's mask matching nothing (60).

The `warp` rung's `refill_credits` failed the first gate with exit 2 after printing its pass:
a script that ends in `emu.stop(0)` can be given one more frame under load, and the runner
resumed the finished coroutine and failed it. `writeRunner` now leaves a finished script
alone. The same symptom was Steps 15 and 16's "passed alone and on the rerun".

James's playtest (2026-10-02), the four clocks from ENDING and the soft reset: good.

### The recording (C10)

`gbtrace -- kills` watches `gameMode`, the credits state and the done flag. Part 25, the best
ending (clock 2:06): the refill on frame 63, mode $12 on 68, $13 on 315, the run on 570, the
scroll done on 7 482 and the hair in the wind ($15) on 7 799. From $13: done +7 167 against
our Game Boy's 7 166 passes at 2:59, $15 +7 484 against 7 483 (99.99%); the fade 247 frames against
the cart's 242 passes and 7-frame setup (99.6%).
