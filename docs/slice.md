# The playable slice: region, poses, and deferrals

Phase 0b builds one contiguous region — landing site through the second Alpha Metroid —
and plays it start to finish on hardware. This file is that region's definition, and the
place every scoping decision for the cycle is written down with the measurement that
produced it.

Everything here is derived from the ROM or from a run of this repository's own tools.
Where a fact came from a rule applied to a dump, the rule is stated so the fact can be
re-derived rather than believed.

## Sources

| what | where it comes from |
|---|---|
| map grids, doors, item names | `zig build extract` → `extracted/map{9..F}_grid.txt`, `extracted/doors.txt`, `extracted/item_names.bin` |
| the published any% route | `zig build tas` → `extracted/tas/any-vblank0-trace.tsv`, 8501 frames |
| non-play stretches | `zig build oracle -- durations all` |
| dispatch sites and holes | `zig build dispatch` |

Two rules used throughout:

- **A cell from a trace row.** `cell = ((samus_y >> 8) & $F) << 4 | ((samus_x >> 8) & $F)`,
  the same arithmetic as `oracle.Settled.cell`. Checked against the one cell the planning
  spike had already named by other means: trace frame 326 is `samus_y=$07D4`,
  `samus_x=$0648`, map bank `$0F`, giving cell `$76`.
- **A cell's out-edges.** Four grid neighbours, wrapping the 16×16 grid, to any in-use
  cell; plus the `WARP` target of the door script its `transition` word indexes.
  `map.Scroll`'s blocked bits do **not** gate movement — see *Two kinds of crossing*.

## The region

**The region is the ground the published any% run covers inside its replay horizon,
plus whatever B11's recording adds past it.** The run's own route is the authority for
the first part, and it is exact: across frames 0–8442 the run occupies 71 distinct spans
of one bank and cell, 68 of them inside a map bank. That is 67 changes, and **66 of the 67
are explained by the out-edge rule above.** The one that is not is frame 6, which is the
game placing Samus at the landing site rather than a move.

Map banks visited: **`$0F`, `$0A`, `$0C`, `$0B`** — four of the seven.

### The traversal, in order

This is also the **minimum room traversal a hardware pass has to cover** for the work in
Steps 4–7. `door` is the script index the transition took.

| # | bank:cell | frames | how it was entered |
|---|---|---|---|
| 1 | `$0F:$76` | 6–420 | landing site (game placement) |
| 2 | `$0F:$77` | 421–702 | scroll right |
| 3 | `$0A:$43` | 703–719 | **door 479** |
| 4 | `$0A:$44` | 720–898 | held crossing, right |
| 5 | `$0A:$45`–`$48` | 899–1380 | scroll right ×3 |
| 6 | `$0F:$5A` | 1381–1412 | **door 082** |
| 7 | `$0F:$6A`–`$6C` | 1413–1753 | held crossing then scroll right ×2 |
| 8 | `$0C:$11` | 1754–1783 | **door 084** |
| 9 | `$0C:$21`–`$41` | 1784–2052 | held crossing then scroll down ×2 |
| 10 | `$0F:$F3` | 2053–2083 | **door 186** — a save station (see below) |
| 11 | `$0F:$03` | 2084–2190 | scroll down, wrapping row `$F` to row `$0` |
| 12 | `$0F:$02` → `$00` | 2191–2739 | scroll/held crossings leftwards |
| 13 | `$0C:$52`–`$81` | 2740–3123 | **door 072**, then scroll down ×3 |
| 14 | `$0F:$16` → `$10` | 3124–4447 | **door 201**, then leftwards to `$10` |
| 15 | `$0F:$11` → `$15` | 4448–5376 | back rightwards |
| 16 | `$0C:$80`–`$51` | 5377–6060 | **door 078**, then up ×3 |
| 17 | `$0F:$0F` → `$05` | 6061–7185 | **door 192**, then rightwards along the surface |
| 18 | `$0B:$0C`–`$0E` | 7186–7590 | **door 074** — the `$46` threshold door |
| 19 | `$0A:$0F` → `$01` | 7591–7835 | **door 086**, then rightwards |
| 20 | `$0A:$11` | 7836–8440 | scroll down; the replay collapses at 8442 |

### Two kinds of crossing, and why the scroll bits are not walls

`map.Scroll`'s four bits are camera limits, not movement barriers. Testing both readings
against the route settles it: treating a set bit as a wall explains 44 of the run's 67
cell changes and treating a clear bit as a wall explains 27, while ignoring them entirely
and allowing any in-use neighbour explains 66.

So a boundary crossing comes in two forms, and the difference is exactly the subsystem B1
has to build:

- **a free scroll**, where the bit is clear and the camera follows; and
- **a held crossing**, where the bit is set, the camera stops, and the game holds Samus
  while it draws the incoming screen.

The held crossings are where B1's two duration defects live. `zig build oracle --
durations all` measures them: the Game Boy holds 21 frames at frame 2362 (`$F:$02` →
`$F:$01`) and again at 3873 (`$F:$12` → `$F:$11`), against the port's 1.

## The second Alpha Metroid, and what the ROM says about it

**The threshold is `IF_MET_LESS $46`, and it opens after the first kill.** The counter at
`$D089` holds `$47` for every frame of the run.

> **Corrected 2026-09-15 (Step 14).** This paragraph used to say *two* kills, reading the
> opcode's name as strictly-less: "`$47 − 1 = $46`, which is not less than `$46`". The ROM
> says otherwise. 00:$254A is `CP B` with the operand in A and the count in B, then `JR NC`,
> so the branch is taken when the count is **at or below** the operand, and `$46` opens at
> `$46`. `transition.zig`'s decoder always had it right; this file and the engine's stub
> did not, and a playtest walked into the consequence: after a kill, door 074 kept
> drawing `$B:$0C` full of acid. The Game Boy's interpreter, run at `$46`, takes door 481
> (`src/transition.zig`, "IF_MET_LESS is taken at a count equal to its operand"). D2 still
> asks for the second Alpha. What the second kill proves is the chain repeating from a
> count the first kill left, not a gate the first kill cannot open.

Ten cells carry a `$46`-threshold door:

`$A:$08`, `$A:$0B`, `$A:$21`, `$B:$13`, `$B:$15`, `$B:$25`, `$C:$A1`, `$C:$B1`,
`$C:$E1`, `$F:$05`.

`$F:$05` is on the published route (frames 6934–7185), and the run takes its door — door
074 — at frame 7186. So the slice reaches the first-kill gate inside the horizon even
though it never reaches a kill.

### What the gate changes

Doors 481, 482 and 483 are one op each: `TILETABLE 6`, `7` and `8`. Through the ROM's
`metatilePointerTable` (08:$7F1A) those are `metatiles_lavaCavesEmpty`, `lavaCavesFull` and
`lavaCavesMid` — the three variants B8 asks to see swapped. (This paragraph named them Mid,
Empty and Full until 2026-09-24, from `screens.tiletable_order`'s layout order, which is not
the operand order. Step 22.) So **the lava/acid drain is
reachable in the region and is in scope for B8**, not deferred.

Two doors show the drain as a sequence:

- door 074 (`$F:$05`): falls through to `TILETABLE 8`; at `≤ $46` it takes `TILETABLE 6`.
- door 217 (`$C:$B1`): falls through to `TILETABLE 7`; at `≤ $42` it takes 6; at `≤ $46`
  it takes 8. (The `$42` test comes first in the script, so it wins below `$43`.)

Read as a jump, that orders the three variants **7 → 8 → 6** as kills accumulate. That
contradicted both namings recorded at the time, because both took the operand to be the
table's position in the region. **Resolved 2026-09-24 (Step 22):** the operand indexes
`metatilePointerTable`, which sends 6 to Empty, 7 to Full and 8 to Mid, so 7 → 8 → 6 is
Full → Mid → Empty. The acid falls with each kill, under M2RoS's names, which were right.

**This reading depends on `IF_MET_LESS` being a jump that ends the script rather than a
call that returns.** If it returned, door 217's trailing `TILETABLE 7` would override
every branch and the branches would do nothing, which is why a jump is the only coherent
reading — but it is a reading, and Step 5 pins it against the running game when it builds
the interpreter.

### Which rooms hold Alphas 1 and 2 is not decided here

Sixteen door scripts load `gfx_metAlpha`; fourteen are referenced by a cell. Their warp
targets are the Alpha rooms:

`$9:$85`, `$9:$EF`, `$A:$41`, `$A:$65`, `$A:$7A`, `$A:$A5`, `$B:$37`, `$B:$56`,
`$B:$A6`, `$B:$B2`, `$B:$F4`, `$B:$F5`, `$C:$28`, `$C:$F3`, `$D:$8F`, `$E:$CC`.

None of them is entered inside the replay horizon, and the Metroids themselves are not in
`enemy_data` — every one of those rooms' per-screen spawn lists is either empty or holds
ordinary enemies. Whichever table places a Metroid is code this repository has not
reached, and `zig build dispatch` says so in its own words: *"No Alpha Metroid, no Queen,
and no ending."*

**Decision: the two rooms are named by B11's recording, not by static analysis.** The
recording is on the critical path for Steps 9–14 for the same reason. Until it lands, the
region's far edge is "the run's own route to `$A:$11`, plus one or two rooms past it",
and the sixteen candidates above are the set those rooms are drawn from.

### Answered 2026-09-08, and neither room is one of the sixteen

The recording's trace names them: **`$F:$10` and `$E:$07`** — see *The trace's landmarks*
below for the frames and the method. **Neither is in the candidate set above**, and the
first is not even in a bank the set reaches: every one of the sixteen warp targets is in
`$9`–`$E`, and the first Alpha dies in `$F`, the bank the game starts you in.

So the decision to name them from the recording was not merely the cheaper route — the
static derivation would have named the wrong rooms. What it derived is sound as far as it
goes ("door scripts that load `gfx_metAlpha` warp to these cells"); what it does not
support is the step from there to "an Alpha is fought there". Two of the sixteen scripts
are referenced by no cell at all, which was already recorded above as a loose end, and the
gap is wider than that: a room can be entered by falling into it rather than through a
door, and the graphic can be loaded by the room you approach *from*. Reaching for a
stronger claim here would need the table that actually places a Metroid, which is code
this repository still has not found.

## Save stations

**A normal save station is inside the region, and the region does not need to grow.**

The `ITEM` opcode's operand indexes `item_names`, decoded from
`extracted/item_names.bin` by `chr(b - $C0 + 'A')` with `$FF` as a space:

`$0` SAVE · `$1` PLASMA BEAM · `$2` ICE BEAM · `$3` WAVE BEAM · `$4` SPAZER · `$5` BOMB ·
`$6` SCREW ATTACK · `$7` VARIA · `$8` HIGH JUMP BOOTS · `$9` SPACE JUMP · `$A` SPIDER BALL ·
`$B` SPRING BALL · `$C` ENERGY TANK · `$D` MISSILE TANK · `$E` ENERGY · `$F` MISSILES

So `ITEM $0` marks a save station. Three fall on the published route:

| room | door | how the run meets it |
|---|---|---|
| `$F:$01` | door 486 — `ITEM $0; END`, no warp | stood in it, frames 2382–2562 and 6246–6426 |
| `$F:$F3` | door 186 — `ITEM $0; WARP $F,$F3`, from `$C:$41` | entered it, frames 2053–2083 |
| `$F:$06` | door 085 — `ITEM $0; WARP $F,$06`, from `$B:$0D` | passed the door's cell, frames 7207–7420 |

`$F:$01` is the one B7's scenario should use: it is a station in its own right rather than
a warp destination, the run walks through it twice, and it is nowhere near the ship. B7's
requirement that the station not be the ship is satisfied without moving the region.

No published run saves at any of them — saving is never faster — so the save path itself
still needs B11, exactly as the requirements say. What is settled here is *where*.

### What the recording does at them (Step 15a, 2026-09-15)

`zig build gbtrace -- saves 0 40000` and `saves 40000 76951`: one record whenever game mode, the
contact (`$D07D`), the death or load flag, or the slot's bytes change, or the "COMPLETED"
cooldown (`$D088`) starts or stops.

| Start | room | contact from | slot written | contact gone | record's `$D089` |
|---|---|---|---|---|---|
| 23 001 | `$F:$04` | 22 976 | 23 002 | 23 257 | `$46` |
| 41 551 | `$D:$26` | 41 508 | 41 552 | 41 807 | `$46` |
| 50 109 | `$D:$26` | 50 068 | 50 110 | 50 277 (a door, cooldown at `$58`) | `$46` |
| 61 521 | `$D:$26` | 61 498 | 61 522 | 61 777 | `$46` |
| 76 419 | `$D:$26` | 76 378 | 76 420 | still on it at 76 675 | `$45` |

**Every save has one shape**: Start's rising edge on frame N sets game mode `$09` and the
cooldown to `$FF` on N; the slot is written on N+1 with the mode back at `$04` and the cooldown
still `$FF` (the play handler did not run); the contact holds for the cooldown's 255 frames and
then drops if she has walked off. At 50 277 a door's transfer zeroed the cooldown early, which
is the `LOAD`/`COPY` arms' clear. The first save is at `$F:$04`, not the `$F:$01` above: that is
the room the recording actually used.

The same pass shows the one death and reload: game mode `$06` at 25 550, `$05` at 25 678 (128
frames, the death animation's 32 steps of four), `$07` at 25 732, Start at 25 889 back to the
title (`$00` 25 895, `$01` 25 900), Start at 25 939 (`$0C` load, `$02`, `$03`) and control at
25 951. **Our Game Boy agrees (Step 15c).** `src/death.zig` kills Samus on the emulator
and counts 70 224-cycle frames from `killSamus`: mode $06 on 1, $05 on 128, the noise spent on 176
($B0 frames), the LCD off from 178 to 183, $07 on 183, and the reboot on 439 on the timer or 22
frames after Start. That is 127 and 55 frames where the recording has 128 and 54: 182 in both,
with the one frame moving between the two modes with where each machine's vblank lands. The slot
at 23 002 decodes with `save.zig` to Samus at `$00AC`,`$046E` in bank `$0F`
with 99 energy and `$46`/`$38` Metroids, which is the trace's own columns on that frame — a
test pins it.

### The reload, and what of it is gradable (Step 15d, 2026-09-15)

`zig build gbtrace -- saves 25850 26000` is the pass; these are its rows.

| frame | mode | what |
|---|---|---|
| 25 889 | `$07` | Start's rising edge on the game over screen |
| 25 895 | `$00` | the boot mode, **6 frames later** |
| 25 900 | `$01` | the title, **5 frames after that** |
| 25 939 | `$0C` | Start on the title — **39 frames later** |
| 25 940 | `$02` | `gameMode_LoadA` |
| 25 941 | `$03` | the record is live: `$0F`, `$00AC`,`$046E`, energy `$0099`, `$46`/`$38` |
| 25 951 | `$04` | the play handler, countdown `$013E` |

**The 52 frames from the death to the reload are not a duration the port can be held to.**
Step 15d's sub-task asked for "the frames from the death at 25 889 to the reload at 25 941"
as a graded length. Thirty-nine of those fifty-two are James sitting on the title screen
deciding to press Start — a human pause, not a cutscene. What is machine-determined, and so
gradable by the memory's cutscene rule, is the two ends: **6 + 5 frames** from Start to the
title, and **12 frames** from the title's Start to the play handler, with the record already
in the variables on the second of them. `death.zig`'s test pins the split so the wrong
reading cannot come back.

**Our Game Boy gives the same four numbers.** `death.measureReload` taps Start on a title
whose slot is already written and counts 70 224-cycle frames: `$0C` on 0, `$02` on 1, `$03`
on 2, `$04` on 12 — the recording's 25 939, 25 940, 25 941, 25 951 differenced from its own
Start, exactly, with no tolerance. It has to be that clock and not vblanks: mode `$03` turns
the LCD off to copy, and counted in vblanks the same stretch measures 3 frames instead of 12.

**And the record has to be in cartridge RAM before the title initialises**, not before Start
is pressed. `titleScreenRoutine` reads the slot on its way in (05:$426D) and keeps the
answer, so a record injected into a title already on screen sends Start to game mode `$0B`, a
new game. The same routine writes `$0B` and then `$0C` two instructions later (05:$429A,
$42A3), so every load passes through the new game's mode for less than a frame — invisible to
an end-of-frame census, and a wrong turn to anything watching instructions.

### Where a save station can be (Step 15d, 2026-09-15)

A station's tile is a collision byte with bit 7 set (`BIT 7,A` at 00:$1F4F and $1F92).
Scanned across the eight `$100`-byte tables in bank 8: `caveFirst` has ids 16–19,
`plantBubbles` and `lavaCaves` four each, `ruinsInside` six — and `finalLab`, `queen`,
`ruinsExt` and **`surface` have none at all**.

`surface` is the tileset a new game's record names, so **the game cannot be saved anywhere a
new game can reach without first walking into another tileset**, and the cart's boot cell
cannot hold a station either. That is why the recording's five saves are all `caveFirst`
rooms, and it is what both of Step 15d's scenarios have to work around: the cart's rung
points `!ColTab` at a table that has one, and the Game Boy's test does not lay a station at
all (see `room.contactStation` for the two routes that were built and why neither survives
the harness).

## The explicit in-scope / deferred decisions

### In scope

- **All 25 unmatched-world stretches.** `zig build oracle -- durations all` reports 60
  stretches, of which 25 never matched the world. Every one of them is in banks `$F`,
  `$A`, `$C` or `$B` on the run's own route — i.e. **all 25 are in the region**. The
  requirements defer them "unless a room in the slice's own region is on the list, in
  which case it is in scope by B1"; the list is entirely inside the region, so the
  deferral does not apply to any of them. This is a larger B1/B12 load than the
  requirements assumed.
- **The lava/acid drain**, per the `$46` threshold above.
- **The `$46` `IF_MET_LESS` transition**, which B8 needs and which the run reaches.
- **Four items, because the recording collects them**: Bomb (`ITEM $5`), Energy Tank
  (`$C`), Missile Tank (`$D`) and **Spider Ball** (`$A`). Spider Ball was deferred as
  out-of-region on the published run's coverage alone; the recording overrules that.
  Its door is 141, entered from `$B:$A2` into `$C:$F3`, so the region reaches at least
  that far into banks `$B` and `$C`.
- **Save *and load*.** The recording saves several times, dies once, and reloads from the
  last save. The load path is beyond B11's stated minimum and B7 gets it for free.

### Deferred, with the reason

- **Elevator / area-change sequences — deferred, not reachable in the measured region.**
  The durations census classifies every stretch as `cutscene`, `scroll`, `warp` or
  `menu`. The longest non-play stretch inside the region is the 25-frame warp at frame
  2721 (`$F:$00` → `$C:$51`), and an area change would be far longer. Revisit against
  B11: if the route to the second Alpha rides one, it comes back into scope by B1.
- **Spring Ball — deferred, not collected.** `ITEM $B`. B6's `!Items` gates for Spring
  Ball in the three ball handlers therefore stay unreachable this cycle. Hi-Jump
  (`ITEM $8`) likewise: its three doors are referenced by no cell, and the recording does
  not collect it.
- **The five unreached bank-4 dispatch sites — in scope by B4, but not separately.**
  `zig build dispatch` names them: sites `4:$44B9`, `4:$44C9`, `4:$450C`, `4:$452E`,
  `4:$453E`, with tables `4:$55F2`, `4:$5600`, `4:$5700`, `4:$5D3F`, `4:$5D49`, all five
  sharing the `$46DE` indexer with three sites the run *did* enter. Their observed
  siblings read `($CEC0)`, an entity field, which puts the whole family in the enemy
  layer. **Decision: they are entered by Step 9/10's enemy work or they are not, and
  which of the five the slice's enemies use is a measurement Step 10 takes — it is not a
  question that can be answered before an enemy runs.** No separate task is created.

## The horizon finding, and why B11 is on the critical path

Recorded here because Steps 9–14 are planned around it.

Regenerating the `vblank0` trace to 8500 frames shows `$D089` holding `$47` from frame 6
until the replay collapses at 8442. **No Metroid is killed inside the horizon — not the
second Alpha, not the first.** The measurement is one column of
`extracted/tas/any-vblank0-trace.tsv`, and it is flat.

The geography *is* covered: the run visits `$0F`, `$0A`, `$0C` and `$0B` before 8407, so
Steps 4–7 keep their published-TAS grading. Everything from Step 9 onward does not.

**So B11's recording is the primary grader for Steps 10–14, not a supplement, and Step 8
is a hard prerequisite of Step 9.**

### What the B11 recording has to cover

- Power-on to the **second Alpha Metroid kill**, so `$D089` is seen to reach `$45` and the
  `IF_MET_LESS $46` transition is seen to fire.
- **A visit to a normal save station with a save performed** — `$F:$01` is the nearest and
  is on the way; any other non-ship station is equally acceptable.
- The whole of the traversal table above, so the recording is a superset of what the
  published run already grades and the two can be checked against each other.
- VBM, same ROM, power-on with no BIOS, matching the convention `tas.zig` already verifies
  for the two published runs. It is not required to be fast or optimal.

### As delivered, 2026-09-03 — and the one thing it does not do

James recorded it in **Mesen2 2.2.1** as `reference/metroid2.mmo`, 76 951 frames (21.5
minutes). By his account it saves several times, dies once and reloads from the last save,
collects Bomb, an Energy Tank, a Missile Tank and Spider Ball, kills two Metroids, and
ends on a final save. **That is a superset of everything asked for above.**

What is settled about it:

- **It names our cartridge.** `GameSettings.txt` carries SHA-1
  `74A2FAD8…EFB1066D`, which is `metroid2.gb`.
- **The input log converts cleanly.** `Input.txt` is one line per frame,
  `|..|UDLRSsBA`, with both system columns clear for all 76 951 frames — no reset, no
  power-cycle. Converted to `tas.zig`'s word layout it passes `parse`'s cartridge check
  against the ROM header the same way the two published movies do, and lives at
  `vendor/tas/metroid2-recorded.vbm`. `zig build tas -- rec` replays it.
- **It starts the game from cold.** `findInputOrigin` puts movie frame 0 at machine frame
  0 under all three frame sources. The opening measures as: Start at 114, room loaded at
  115, Samus placed at 116 in pose `$13`, control at 473, first move at 474.

**And then our Game Boy emulator stops being his run, long before the events that matter.**

    zig build tas -- rec 0 1
    faithful until    frame 28796: held $13 into a refusal of 597 frames at 0AA2,0654
    left play at      frame 14007
    cartridge RAM     1 bytes written by 1 sites, $A0C0-$A0C0

Three readings, and they agree:

1. `tas.faithfulness`, the repository's own predicate, gives out at **28 796 of 76 950**.
2. Independently: from frame 39 120 to the end the replay never leaves cell `$0F:$6A`
   while the movie sends **29 924 frames of active input** into it. Compare the genuine
   stall at `$0A:$45` — 7 368 frames of which 6 905 are *idle*, which is a human standing
   still, not a desync. Held input that moves nothing is.
3. **One byte of cartridge RAM is written in the whole replay.** The recording saves
   several times. So the replay had already left his run before his first save.

Neither the frame source nor the input origin is the cause: `vblank`, `cycles` and `lcd`
each fail, and offsets 0–7 under both `vblank` and `cycles` all stall at `$0A:$45` at the
same frame. Sixteen combinations, one outcome.

**This is not a defect in the recording.** It is the same limit the published runs hit:
our replay of the any% VBM stops being the any% run at frame 8407, and the 100% run at
4566. A Game Boy movie replayed on an emulator that is not the one that recorded it
diverges after a few thousand frames, and B11 assumed otherwise.

Three settings would have removed variables, and are worth setting on any future
recording: `gameboy.ramPowerOnState` was **Random** (which is why Mesen had to embed a
`SaveState.mss` to replay its own movie at all), `gameboy.model` was **AutoFavorBest**
rather than Game Boy, and `gameboy.useSgb2` was on. None of them matches the DMG,
power-on, no-BIOS convention `tas.zig` measured itself against. **But none of them is
likely to be the whole story either**, because the published VBA runs are recorded under
exactly that convention and still only reach 8407.

**So B11's mechanism needs a decision, and it is recorded here as open rather than
answered.** The recording is good; replaying it on our emulator is what does not work.
The alternative that fits what is already here: Mesen2 replays its own `.mmo`
deterministically — that is what the embedded save state is for — and Mesen2 is already a
resolved dependency driving Lua scripts headlessly for the SNES side. A Game Boy sampler
producing the same columns `tas.zig` writes would make the recording a **reference trace**
for all 76 950 frames, which is what Steps 10–14 actually need, and the cart would be
graded against it by the anchored machinery that already re-anchors at every handover
rather than by replaying anything.

### That alternative was tried on 2026-09-08, and it does not work either

The paragraph above assumed Mesen2 could be asked to replay the `.mmo` the way it drives
the SNES scripts. It cannot, and the measurements are here so nobody spends another day
re-taking them.

**Mesen2 cannot be asked to play a movie headlessly.** `--testrunner` takes exactly one
file: passing `reference/metroid2.mmo` as that file exits 255, and so does either order of
the ROM and the movie together. There is no Lua movie API to reach past the command line —
`emu.playMovie`, `emu.startMovie`, `emu.loadMovie`, `emu.movie` and `emu.loadRom` are all
absent. The movie plays in the GUI or it does not play.

**The Lua surface that does exist**, probed rather than assumed, on the Game Boy side of
this build:

| call | status |
|---|---|
| `emu.setInput(buttons, port)` | works — that argument order; the reverse throws |
| `emu.loadSavestate`, `emu.createSavestate` | work, but **only inside an `addMemoryCallback(.exec)` on the main CPU**; from an event callback both throw *"This function must be called inside an exec memory operation callback"* |
| `emu.getInput`, `emu.reset`, `emu.getState`, `emu.getRomInfo`, `emu.getScriptDataFolder` | present |
| `emu.memType.gameboyMemory`, `gbWorkRam`, `gbCartRam` | present |
| `io`, `emu.log` | nil and swallowed, exactly as on the SNES side |

So the only wide channel out is the one `snes_trace.zig` already uses: cart RAM written to
`.srm` on exit, **8192 bytes**. A full-width per-frame record of 76 950 frames wants more
than a megabyte, so a sampler either narrows the record or takes several passes.

**Speed is not the problem.** 76 951 frames replay headlessly in **≈100 s**.

**Determinism is not the problem either.** Two identical runs agree on every census column
across the whole replay; the only byte that differs is `$D089`'s pre-initialisation garbage
at frame 85 (100 one run, 215 the next). `gameboy.ramPowerOnState Random` is visible and
not load-bearing. The settings worry three paragraphs up is also answered: the machine's
Mesen config **already matches** `GameSettings.txt` exactly — `AutoFavorBest`, `UseSgb2
true`, `RamPowerOnState Random` — so the model was never a variable.

**Driving the inputs ourselves reproduces the opening exactly, and then loses the run.**
Feeding `Input.txt` through `emu.setInput` from a cleared power-on gives Start at 114, pose
`$13` at 117, control at 474, first move at 474, `$D089` = `$47` — `tas.zig`'s own measured
opening, to the frame. After that: `$D089` never leaves `$47`, one cart-RAM write in the
whole replay, and Samus at one x for 58 000 frames. Loading `SaveState.mss` first gets
further — bank `$0C` by 12 800, a death at 14 141, a second cart-RAM write at 23 001 — and
then stalls the same way. **The two kills never happen and the saves never happen.** Frame-
and poll-indexed input behave identically (79 999 polls in 80 000 frames), so alignment is
not the cause, and the input log contains no invalid direction pairs for
`AllowInvalidInput` to filter.

**A trap that cost the first probe its answer.** Mesen boots the cart against whatever
`~/Library/Application Support/MesenCE/Saves/metroid2.srm` is sitting there. The first
probe pressed Start and silently *continued an old save*, reading `$D089` = 69 where a new
game is 71. Any sampler controls that file rather than inheriting it.

**`stable-retro` was considered and declined.** The macOS arm64 build in `~/git/sim_player`
ships nine libretro cores — `fceumm`, `genesis_plus_gx`, `mednafen_pce_fast`,
`mednafen_saturn`, `melonds`, `mgba`, `picodrive`, `snes9x`, `stella` — and **no Game Boy
core**, though it does carry GameBoy integration data, so the platform is supported upstream
and the core is what is missing from the build. Adding it would fix the channel outright
(Python, whole memory per frame, any file) but would not have replayed this recording: a
libretro Game Boy core is a *third* emulator, and two have already failed from the inputs
alone.

### So the reference is re-recorded in segments — *superseded, see the off-by-one below*

**This section is kept because it is why `reference/metroid2_par01..06.mmo` exist, not
because its reasoning holds.** The premise — that a replay diverges as a function of its
length — was an artifact of the input index, and once that was fixed the original recording
replayed whole. Segments are still a convenience, and the protocol below is still the right
way to record one; nothing here is any longer a *requirement*.

The reference was to become ~8 movies of roughly 10 000 frames instead of one of 76 951,
each replayed from its own seed:

1. Record each segment with Mesen's **record from current state**, not from power-on, so
   the `.mmo` embeds the `SaveState.mss` it begins at.
2. Start each segment **immediately after stopping the previous one**, without playing in
   between, so segment *k+1* begins exactly where *k* ended and the seams are continuous by
   construction.
3. Roughly three minutes each. It does not have to be precise — the sampler measures each
   segment's faithfulness and names the ones that need redoing.
4. The route is the one this file already asks B11 to cover: through the second Alpha kill,
   with a visit to a normal save station and a save actually performed.

**A pilot segment comes first.** One three-minute recording, replayed and measured end to
end, settles whether 10 000 frames is under or over the bound — before seven more are
recorded against a guess. The bound is a measurement, not a number this document asserts.

### As delivered, 2026-09-08: six segments, 43 867 frames

`reference/metroid2_par01..06.mmo`, all naming the same cartridge SHA-1, each carrying its
own `SaveState.mss`. They stop short of the second Alpha — the kill segments come later,
which is fine, because Steps 9–12 are graded on the early game and only Steps 13–14 need a
kill.

**The seams are gaps, and the requirement that wanted them contiguous was the wrong shape.**
All five seams differ in position; three differ in map bank and `$D089` as well, so play
happened between stopping one recording and starting the next. It costs nothing: the
anchored machinery grades from anchors rather than from a contiguous history, so six
independent tracks are worth what one stitched track would be and carry no seam risk.

**How much the run shoots, which is why Step 12a exists.** Counted off the input logs, the
`B` column is pressed on 419 of par01's first 5 133 frames and on 2 601 frames across the
six. Shooting is not a late-game affordance the slice can defer — it is in the opening
minutes, which is the measurement behind James's note that the reference stops grading on
the third screen.

| segment | frames | B pressed | A pressed | idle |
|---|---|---|---|---|
| par01 | 5 133 | 419 | 489 | 1 470 |
| par02 | 5 074 | 286 | 779 | 1 322 |
| par03 | 4 026 | 164 | 1 037 | 878 |
| par04 | 6 103 | 281 | 1 241 | 984 |
| par05 | 11 436 | 613 | 2 330 | 1 985 |
| par06 | 12 095 | 838 | 2 406 | 2 343 |

**par03 carries the save B7 needs**: 494 cart-RAM writes at its frame 3 730. No published
run saves at all, so this is the first save this repository has ever had a reference for.

**`$D089` is 71 through par02 and 70 from par03 on**, so the first Alpha is killed in the
gap between them. One kill is inside the delivered set's history even though no kill is
inside a segment.

### Replaying them: five carry, one does not

Each segment replayed from its own `SaveState.mss`, loaded from an
`addMemoryCallback(.exec)`, with `Input.txt` fed through `emu.setInput`. The faithfulness
column is this repository's own predicate rather than a new one — the longest run of frames
carrying **active input** while position and pose do not move, which is what
`tas.faithfulness` looks for and what caught the original recording at 28 796.

| segment | frames | longest active-but-frozen run | at frame | cart-RAM writes |
|---|---|---|---|---|
| par01 | 5 134 | 119 | 3 734 | 1 |
| par02 | 5 074 | 323 | 2 795 | 0 |
| par03 | 4 026 | **25** | 1 676 | **494** |
| par04 | 6 103 | 555 | 5 329 | 0 |
| par05 | 11 436 | 699 | 9 787 | 0 |
| par06 | 12 095 | 353 | 11 003 | 0 |

**par05's replay dies at frame 2 302, and the fault is in the replay and not the
recording.** James reports that par05 plays back perfectly under Mesen's own movie
playback, which settles the attribution: the `.mmo` is faithful and **`emu.setInput` is not
equivalent to the input Mesen's movie player injects.** Everything below describes our
harness failing, not his run.

What the failure looks like: the position census shows real play through banks `$0C`, `$0B`
and `$09` — including pose `$0F`, knockback, at frames 768 and 2 048 — and then at frame
2 302 `$D089` goes 70 to 0, the map bank goes to `$00` and Samus's position goes to zero.
Every sample from 2 560 to 11 436 is identically zero: **8 900 frames sitting on the title
screen while the movie plays 9 000 more frames of input into it.**

It is not a missing save file, which was the first suspect: `emu.loadSavestate` **does**
restore cart RAM — 495 of the low 512 bytes are real save data immediately after the load,
against a different checksum before it — so the game had a file to continue from and did
not continue.

**This makes par05 the cheap test case for the injection bug**, at 2 302 frames instead of
the original recording's 28 796 — which is worth more than a working par05 would have been.

### And the injection bug was an off-by-one, found with that test case

Sweeping the index the `inputPolled` handler reads, over par05's 11 436 frames:

| index | outcome |
|---|---|
| `IN[f]` | **survives all 11 436 frames**, ends in bank `$0D` with `$D089` = 70, last movement at frame 11 230 |
| `IN[f+1]` | dies at 2 301 |
| `IN[f+2]` | dies at 9 626 |

**The direction is right and the explanation below is wrong — see "The sampler, built
2026-09-08" for the correction.** `IN[f]` in that harness meant row *f−1*, because the table
was filled one-based; the offset is really 1, and `emu.setInput`'s relationship to the latch
is not what decides it. The table above stands as measured; the paragraphs that follow it
are kept because the wrong reasoning is what the next two sections were built on.

~~**`emu.setInput` called from `inputPolled` lands on the poll that has already been latched,
so the byte it sets is what the game reads on the *next* frame.**~~ The naive index is
therefore one frame early for the whole replay, and a movie survives it only for as long as
its inputs are held rather than tapped — which is why the fault looked like "some segments
desync and some do not" rather than like an off-by-one.

~~**This is the same defect `oracle.zig` documents on the SNES side, mirrored.**~~ There the
cart had to be handed frame *i+1*'s byte at frame *i*, because `PublishPad` runs before the
poll. The mirror image was an appealing story and it is not what the Game Boy side measures:
the pad byte agrees with whatever index the script used, so it can never settle one, and the
column that does settle it is `$D089`.

**What this retracts, and it is most of the section above.** Re-run with `IN[f]`:

| | before the fix | after |
|---|---|---|
| par01 | 615 frozen | 94 |
| par02 | 323 | **18**, and `$D089` 71 → 70 — the first Alpha kill is *inside* par02 |
| par03 | 25 | 36 |
| par04 | 555 | 94 |
| par05 | 699, then death at 2 302 | 358, survives all 11 437 |
| par06 | 353 | 332 |

**And the original 76 951-frame recording replays end to end.** All 76 951 frames, longest
frozen run 123, **2 472 cart-RAM writes** from frame 115 to 76 421, ending in bank `$0D`.
Its `$D089` column is the whole of what B11 asked for:

| frame | `$D089` | what it is |
|---|---|---|
| 118 | 0 → 71 | the new game's loadout |
| 16 890 | 71 → 70 | **the first Alpha kill** |
| 25 891 | 70 → 0 | the death |
| 25 943 | 0 → 70 | the reload, 52 frames later |
| 73 392 | 70 → **69** | **the second Alpha kill** |

So **B11 is delivered by the recording that arrived on 2026-09-03**, and the mechanism is
Mesen2 headless with `emu.setInput` at the corrected index and `loadSavestate` from an exec
callback. Every claim in "As delivered, 2026-09-03 — and the one thing it does not do" about
the recording losing the run is withdrawn: what could not replay it was our own Game Boy
emulator (a separate measurement, `zig build tas -- rec`, which stands on its own) and a
harness with an off-by-one.

**The six segments are kept and are not wasted.** They are six independent tracks over the
early game, they cost nothing to replay, and par03 carries a save at its frame 3 730 that
is reachable without replaying 76 000 frames first. They are a convenience for the anchored
sweep rather than the reference, which is the whole recording again.

**The other five are consistent with faithful play, and that is inference rather than
proof.** 119 to 555 frames of held input against an unmoving Samus is what walking into a
wall, or holding a direction through a door transition, looks like; it is also what a mild
desync looks like, and nothing here distinguishes them. par03 at 25 frames is the only one
clean enough to need no argument.

**The protocol change that makes this exact, and it costs nothing.** If segment *k+1* is
recorded starting exactly where *k* stopped — no play in between, which is what the
protocol above already asks for and what these six did not do — then *k+1*'s embedded
`SaveState.mss` **is** the oracle for *k*'s end state. Replay *k*, compare the machine
against *k+1*'s seed, and faithfulness stops being a heuristic. No extra artifact, no extra
step: the check falls out of recording the segments back to back.

### The sampler, built 2026-09-08, and the index measured against the game

`zig build gbtrace` (`src/gb_trace.zig`, `src/gb_trace_main.zig`) replaces the throwaway
harness the section above was measured with. It reads a `.mmo` itself — the zip, `Input.txt`,
`GameSettings.txt` and `SaveState.mss` — re-drives the inputs through a generated Lua script,
and reads the trace back out of cart RAM. Six things were measured building it, and four of
them correct something written above.

**The channel is 32 KiB, not 8.** Metroid II's header declares 8 KiB of battery RAM, which is
a few hundred frames of a record this wide. Stamping `$149` to `$03` on a **copy** of the ROM — and
re-stamping the header checksum at `$14D`, because the boot ROM will not start a cartridge
whose header checksum is stale — gives MBC1's full four banks, and all four of the things
that had to hold do:

| probed | result |
|---|---|
| Mesen honours the widened RAM size | writes a **32 768**-byte `.srm` |
| `emu.write(..., gbCartRam)` addresses it | **linearly, across all four banks** — offsets ≥ 8192 land |
| a savestate recorded on the *unstamped* ROM loads into it | **yes**, no error |
| the widened cart still replays the recording | **yes** — see the column below |

The cartridge type at `$147` is deliberately left alone. MBC5 would give sixteen banks, but
it would also swap the memory-bank controller under a game that is mid-replay, and the four
banks are enough.

**The stamped copy is why the user's save is safe now.** It is written to
`build-out/m2trace.gb`, so Mesen saves to `m2trace.srm` and `metroid2.srm` — a real Metroid II
save game — is never opened. The harness above deleted it before every run and depended on
remembering to restore it. Records also start at offset `$2000`, above the game's own save
bank, so a pass can watch the recording's saves land instead of overwriting them.

**The input index is 1, and `$FF80` cannot pick it.** The section above says the fix was
`IN[f]` rather than `IN[f+1]`, and explains it as `emu.setInput` landing after the frame's
latch. **The explanation is wrong and so is the way the index was written down.** The Lua
table in that harness was filled `t[base+i] = a[i]` — one-based — so its `IN[f]` was row
*f−1*, and the repo's first implementation, indexing a zero-based string at `f`, was a frame
early in exactly the way that harness had been. What settles it is not the pad byte: the
emulator delivers whatever `emu.setInput` was handed, so `$FF80` agrees with **any** offset,
and `Pass.lag` reads a lag of 0 whichever one is used. What settles it is `$D089`, censused
over the whole recording at a stride of 64:

| offset | `$D089` over 76 951 frames | banks |
|---|---|---|
| **1** | 128 `0→71`, **16 896 `71→70`**, 25 920 `70→0`, 25 984 `0→70`, **73 408 `70→69`** | **7** |
| 0 | 128 `0→71`, 14 144 `71→0`, 23 040 `0→71` — a death and a new game, no Alpha at all | 3 |

Offset 1 is the earlier full-run column to the frame, inside the stride's quantisation. So
`gb_trace.input_offset` is 1, it is an argument to `zig build gbtrace` only so the
measurement can be repeated, and the pad byte's job is narrowed to what it can actually do:
confirm the index a pass *used*, not choose one.

**`$FF80` is a variable, not a port.** On a frame where the joypad routine does not run it
still holds the previous answer — on par01, five frames of a released Start still reading
`$08` after frame 249. So the delivery check only counts frames on which the byte *moved*: a
stale frame cannot produce a change, so nothing has to know which frames were stale. Asking
the game directly was tried and is unaffordable — a `.read` callback on `$FF00` instruments
every memory read and took par01's first 1 441 frames from 2 seconds to 66.

**The row is generated from the record's own field table**, since the pickup columns landed
on 2026-09-08. It was transcribed beside it, which held exactly as long as nobody added a
column: a column declared and not recorded leaves its bytes holding the previous frame's,
which reads as a value that simply never changes — the quietest way for this to be wrong.

**A `%%` in a Zig multiline string reaches the emulator verbatim.** The Lua modulo was
carried over from the Python harness, where `%%` was an escape. Zig's `\\` strings are raw, so
the script shipped with a syntax error — and a testrunner run answers a script error by
silently doing nothing for the whole timeout. An hour, and a unit test now asserts the
generated script contains no `%%`.

**Headless costs about 105 s for the whole recording**, so a pass costs roughly as long as
the prefix it has to play. `zig build gbtrace -- <movie> [first] [count] [stride] [offset]`;
1 167 rows a pass at the record's current width, `stride` censuses a whole movie in one.

### The trace's landmarks, measured 2026-09-08

Every frame the recording kills a Metroid or picks something up, with the room it happened
in. These are what Steps 10–14 anchor on, so they are recorded with the cell and not only
the frame: a frame number says *when* the port has to agree and not *where* it has to be
standing.

Method, so it can be repeated rather than trusted: `zig build gbtrace -- reference/metroid2.mmo
0 1160 64` censuses the whole 76 951-frame recording in one pass and prints every change of
`$D089`, `$D045` (`samusItems`), `$D050` (`samusEnergyTanks`) and `$D081` (`samusMaxMissiles`)
— which narrows each landmark to a 64-frame bracket — and a stride-1 pass over each bracket
pins the frame. The cell is `tas.Room.of`'s, the screen bytes of her position, the same
arithmetic every other part of the port addresses a screen by.

| frame | room | what | column |
|---|---|---|---|
| 116 | `$F:$76` | new game: 71 Metroids, 48 missiles | `$D089` 0→71 |
| **16 888** | **`$F:$10`** | **Alpha 1 dies** | `$D089` 71→70 |
| 25 889 | — | death; the file's numbers are cleared | `$D089` 70→0 |
| 25 941 | `$F:$04` | reload from the save, 52 frames later | `$D089` 0→70 |
| **44 329** | **`$D:$44`** | **Bomb** | `$D045` $00→$01 |
| **44 968** | **`$D:$44`** | **Missile Tank** | `$D081` 48→64 |
| **48 047** | **`$D:$3A`** | **Energy Tank** | `$D050` 0→1 |
| **68 453** | **`$C:$13`** | **Spider Ball** | `$D045` $01→$21 |
| **73 390** | **`$E:$07`** | **Alpha 2 dies** | `$D089` 70→69 |

The two equipment bits are M2RoS's `itemBit_bomb` (0) and `itemBit_spider` (5), and the
trace confirms them rather than inheriting them: `$D045` goes `$00`→`$01` on the Bomb and
`$01`→`$21` on the Spider Ball.

**Every landmark lands on a frozen Samus.** At each of the nine frames her position, camera
and pose are unchanged for tens of frames either side — a kill's death animation or a
pickup's jingle — which is a useful property and not a coincidence: it means each is
already a *stable* anchor in `pushToStableAnchor`'s sense, so a stretch can be spawned there
without a search.

**Bomb and Missile Tank are the same room**, `$D:$44`, 639 frames apart. Step 11 gets two
pickups out of one screen.

**Why the max, not the count.** `$D053`/`$D054` is missiles *held* and moves every time one
is fired; `$D081`/`$D082` is the ceiling, and only a Missile Tank moves it. Same for health:
`$D050` is tanks, not hit points. Picking the wrong pair of these would have reported a
pickup every time the run shot at something.

### The world at an anchor, and what the block array turned out to be

Step 8 planned the anchored sweep around a note of James's: *the recording shoots blocks out
to descend, and the third screen is the first place it does*. An anchor that restores Samus
and not the floor hands the port a room whose geometry the trace does not have, so the
sampler grew a second kind of pass — `zig build gbtrace -- <movie> world <frame>...` — which
records the whole background tilemap (`$9800`, 1 024 bytes) and the whole
`respawningBlockArray` (`$D900`, 256 bytes) at each named frame. One anchor is 1 288 bytes
against a 24 512-byte region, so **nineteen anchors a pass**, which is why it is a mode and
not four more columns on the row.

**`$9800` is VRAM, and the CPU bus returns `$FF` for it during mode 3.** The script prefers
Mesen's `gbVideoRam` memory type, which is not gated that way, falls back to the bus when it
is absent, and records which it used. Measured: `gbVideoRam` exists, all ten probe anchors
came back through it, and none came back blank. That check is kept rather than retired — a
gated read *succeeds* and returns 1 024 identical bytes, and every comparison downstream then
agrees that both machines are in the same nothing.

**The block array is current state, not history, and that changes what it is for.**
`handleRespawningBlocks` (01:5692) drops a slot the moment the block scrolls offscreen, and
`destroyRespawningBlock` (01:5671) fills the first slot whose frame counter is zero. So the
array answers "which destroyed blocks are on screen right now and owed back", and it answers
nothing at all about the rest of the room. **The tilemap is what carries the damage**; the
array is only the timer beside it. All ten probe anchors read zero live slots, which is not a
defect — every one of them is a kill or a pickup, and Samus stands still through those.

**So the run's block destruction had to be counted rather than sampled**, which is what
`blocks_seen` is: a script-side accumulator that runs on every frame, recorded onto whichever
frames the pass writes, so a stride-70 census still reports the true total. Over the whole
recording:

| frames | destroyed | where |
|---|---|---|
| 0 – ~9 940 | **0** | the world is pristine for the whole first descent |
| ~10 000 – 11 830 | 24 | bank `$F`, then bank `$C` from 11 620 |
| 11 830 – ~53 550 | 0 | nothing destroyed for forty thousand frames |
| 53 620 onward | 41 by 57 470, and rising | bank `$B` |

**The note was right about the run and wrong about where it starts.** Nothing is destroyed in
the first ten thousand frames, so an anchor placed before then can be seeded from the pristine
room the cell already describes, and the expensive pass is not needed for it. That is a useful
thing to know before building nineteen-anchor passes for stretches that do not need one — and
it is the sort of claim that could only come from the trace, since it is a fact about what
James did rather than about the ROM.

### Seeding it, and the tileset question the seeding uncovered

`!TilemapBuf` is filled by `LoadScreen` from the converted map and then by `SeedWindow` from
the neighbours, and until 2026-09-08 nothing could put a tile in it that the map does not
have. Boot record **version 10** adds `BootWorldCount` and a 168-entry `BootWorld` table at
`$00FC00`; `SeedWorld` applies it after `SeedWindow` — after, because the streamer writes
whole metatiles out of the map and would put the intact block straight back. The low byte
only: a tilemap word's low byte *is* the Game Boy tile id, which `SampleTile` states outright,
so the high byte stays the attribute the metatile chose.

**Which tiles is a mechanism, not a threshold.** `destroyBlock` (01:56E9) writes `$00`–`$03`
when a block reforms, `$04`–`$07` and `$08`–`$0B` over the two animation frames, and `$FF`
over all four when it is gone; `01:$5155` treats `$00`–`$03` as the hardcoded respawning
blocks a projectile may break. So a compared slot whose *map* tile is `$00`–`$03` and whose
*trace* tile is `$04`–`$0B` or `$FF` is a block the reference broke, and any other
disagreement is the two machines being in different rooms. `compareWorlds` forgives the first
and nothing else, which is safe without any bound on how many tiles may differ — a warp that
redrew the wrong room disagrees on tiles that were never blocks.

**And then the sweep at frame 10 000 said something else entirely.** `zig build oracle --
recorded 10000 400 8`, six stretches, four of which never settle:

```
 2  handover 10247: best 88 of 357 (0 block(s)) on map 6 cell $6B; cart table 9 (nearest warp
                    target in the same region, 1 away), gb best 357 at table 4
 3  handover 10326: best 88 of 357 (6 block(s)) on map 6 cell $6B; cart table 9, gb best 351
                    at table 4
```

Read it as a pair of sums and it is not ambiguous. The cart draws cell `$6B` from **table 9**,
which `screens.assign` inferred from the nearest warp target one cell away, and 88 of 357
tiles agree. The Game Boy's own picture is explained by **table 4**, at **357 of 357** before
any block is broken and **351 of 357** after — and 351 + 6 is 357. So:

- **The seeding is exactly right.** The six tiles it accounts for are precisely the gap
  between the room the trace was in and the room the map describes, once the room is drawn
  from the right table.
- **The blocker is the tileset assignment, which is B12's**, not the world's. Four of six
  anchors in this window are unsettled for a reason that has nothing to do with blocks, and
  `zig build oracle -- recorded` now prints the two tables side by side so the next one cannot
  be mistaken for a world problem.

**What the fixture cannot yet show.** The plan asks that a *pristine* cart — one seeded with
nothing — lose frames somewhere after the first destroyed block. `zig build oracle -- recorded
<start> <window> <min> fault` runs exactly that, re-grading every seeded stretch against a
cart built from the map alone, and it reports honestly that it caught nothing: the one seeded
stretch reaches **one frame either way**, because at Step 8 the port cannot play that region
at all. The fault has no room to show a difference until the port can walk through a room the
reference shot its way down, which is Steps 9–13. The fixture is built and wired; what it is
waiting for is a port that gets past frame 1.

## What a door transition costs, measured

Recorded here for the same reason the horizon finding is: Step 5b is planned around it, and
the number that started it — 94 frames — turned out to be the wrong shape of fact.

A crossing is not a hold the port can count out. It is the Game Boy's own arithmetic, and
the arithmetic is in three parts:

- **A frame per opcode.** The door-script interpreter waits a frame on entry (0:`$23AF`)
  and a frame after every opcode (0:`$26D1`, which every dispatch arm jumps to). `END` is
  the only exception: 0:`$23E7` returns through `$26D7` without waiting.
- **A frame per 64 bytes of VRAM.** Everything that moves bytes into VRAM ends at
  0:`$27BA`, which waits a frame at a time until the vblank handler clears `$D047`. The
  handler's drain at 0:`$2BC2` runs until the *remaining* count's low six bits are zero —
  `AND $3F` — so it moves at most 64 bytes a vblank and a transfer of `len` bytes costs
  `ceil(len / 64)` frames. **This is a property of the hardware, not of the game.**
- **A frame per fade step.** `FADEOUT` (0:`$2561`) waits four frames outright, then sets
  `$D066` to `$2F` and loops a three-step palette fade until it drops below `$0E`. `$D066`
  is decremented once a frame by the vblank handler at 0:`$0172`, so the loop is 34 frames
  every time. 39 with the dispatch frame.

### The per-opcode table, graded against the Game Boy

`src/transition.zig` holds the rule and `engine/main.asm`'s `OpExtraFrames` holds it again
in 65816; a test reads the second out of the assembled image and checks it against the
first. The costs are *total* frames, the dispatch frame included:

| opcode | frames | where the cost is |
|---|---|---|
| `$0` COPY | 1 + `ceil(len/64)` | 0:`$2747` → `$27BA` |
| `$1` TILETABLE | 1 + strips | 0:`$282A`, which ends `JP $2918` — **into the warp handler** |
| `$2` COLLISION | 1 | 0:`$2859` |
| `$3` SOLIDITY | 1 | 0:`$242B`, inline |
| `$4` WARP | 2 + strips | 0:`$2915`, then the direction's draw arm |
| `$5` ESCAPE_QUEEN | 2 | a 20-byte strip, 0:`$24AE` |
| `$6` DAMAGE | 1 | 0:`$24B8` |
| `$7` EXIT_QUEEN | 2 | the same strip, 0:`$2503` |
| `$8` ENTER_QUEEN | 3 | one wait at 0:`$2524`, and one frame lost *inside* `$2887` |
| `$9` IF_MET_LESS | 1 | 0:`$2540`; the taken branch pays the re-entry instead |
| `$A` FADEOUT | 39 | 4 + 34 + 1 |
| `$B` LOAD | 1 + `ceil(len/64)` | 0:`$26EB` → `$27BA`; `$B1` is 2048 bytes, everything else 1024 |
| `$C` SONG | 1 | 0:`$259E` |
| `$D` ITEM | 13 | four transfers: `$40`, `$40`, `$230`, `$10` bytes |
| `$F` END | 0 | 0:`$23E7` |

"strips" is 2 going right, left and up and **3 going down** — a downward crossing brings in
one more row (0:`$2A4F` against `$2939`, `$29C4` and `$2B04`). So the *duration* of a
transition depends on its direction before its picture does.

Two entries are worth their own line:

- **`TILETABLE` is a screen redraw.** 0:`$2856` is `JP $2918`, into the middle of the warp
  handler at the direction dispatch, so selecting a tile table draws the incoming edge
  exactly the way a warp does and costs the same strips. Nothing about the opcode's name
  suggests that.
- **`ENTER_QUEEN`'s third frame is not a wait.** After the wait at `$2524`, `$2887` draws
  the whole Queen's room through `$0673`, and that takes longer than a frame on a Game Boy,
  so a vblank passes inside it. This is the one cost in the table that is measured rather
  than derived, and a 65816 doing the same work would not lose the frame. Nothing on the
  slice's path reaches it — B8 gets to decide what the port should do with it.

### How it was graded

`src/transition.zig`'s `measure` runs a door's script on the Game Boy through
`gb/harness.zig` and times every opcode by watching 0:`$23E1`, the fetch every opcode
passes through exactly once. **Frames are counted at the vblank vector, not off the LCD's
frame counter**: the LCD completes a frame at the end of line 153 and `$2C5E`'s wait
resumes in the middle of line 144, so counting LCD frames loses or gains one depending on
where in the frame the interpreter was entered. Counting vblanks is counting the thing the
original is waiting for.

The sample is a stride for breadth plus, for every opcode the ROM's 512 scripts contain,
the first door that contains it — and a test fails if any reachable opcode went unrun, so
"the model is graded" is a checkable claim rather than a hope. **160 of 160 scripts agree,
in all four directions.**

### And against the game playing itself

The any% run walks into a door at movie frame **608** and the model predicts every frame
after it:

| frame | what |
|---|---|
| 608 | the trigger fires: `$D00E` and `$D08E` are set |
| 609 | `FADEOUT` runs — the entry wait and the first opcode are the **same** frame |
| 648, 681, 682, 683, 686 | `LOAD $B1`, `COLLISION`, `SOLIDITY`, `TILETABLE`, `LOAD $B2` |
| 703 | `WARP $A,$43` — `$07F3,$0784` becomes `$03F3,$0484`, bank `$0F` becomes `$0A` |
| 707 | `END`; the interpreter returns |
| 708–747 | 0:`$0B44` scrolls the camera 4 px a frame and drags her 1 px a frame, 40 steps |
| 747 | 0:`$0C24` clears `$D00E` and the crossing is over |

The one that cost a gate run: **the entry wait and the first opcode are the same frame.**
The original enters the interpreter at 0:`$0568`, in the trigger's own frame and after the
camera that fired it, and blocks; it wakes on the next frame *with an opcode to run*. A
port that spends one frame arriving and another on the first opcode is one frame late for
the entire crossing — and one frame late lands exactly on the frame the reachable rung
compares the warp at.

### The correction the measurement forced

`docs/bug_tracker.md`'s 2026-09-07 entry transcribed door `$01DF`'s script by hand as
`FADEOUT, $B1, COPY, COLLISION, ESCAPE_QUEEN, WARP, END`. The interpreter disagrees: it is
`FADEOUT, $B1, COLLISION, SOLIDITY, TILETABLE, $B2, WARP, END`, eight opcodes and not
seven. The `WARP $A,$43` was right, which is why the arithmetic Step 5 checked against it
was right. A test now compares every opcode byte the interpreter fetched against the byte
the decoder re-encodes, because a hand transcription is exactly the thing that should not
be load-bearing.

## Poses the slice reaches

Counted over frames 6–8407 of the any% trace, banks `$9`–`$F`. This is the list Step 11's
tests are enforced against.

| pose | name | frames | first seen |
|---|---|---|---|
| `$00` | STAND | 80 | f5 `$F:$00` |
| `$01` | JUMP | 924 | f445 `$F:$77` |
| `$02` | SPINJUMP | 108 | f2114 `$F:$03` |
| `$03` | RUN | 336 | f457 `$F:$77` |
| `$04` | CROUCH | 118 | f327 `$F:$76` |
| `$05` | MORPH | 4207 | f329 `$F:$76` |
| `$06` | BALLJUMP | 26 | f3557 `$F:$13` |
| `$07` | FALL | 578 | f455 `$F:$77` |
| `$08` | BALLFALL | 1394 | f548 `$F:$77` |
| `$09` | NJUMPSTART | 234 | f463 `$F:$77` |
| `$0A` | SPINSTART | 11 | f2113 `$F:$03` |
| `$0F` | **no handler** | 67 | f5504 `$C:$81` |
| `$13` | FACESCREEN | 320 | f6 `$F:$76` |

Twelve of the thirteen are implemented. `$13` joined them in Step 7 and the one that has
not:

- **`$13`, 320 frames at the landing site from frame 6.** B2's title-to-game sequence, and
  the first thing the cart meets on a cold boot — which it now is, since Step 7. The 320
  frames are not in the handler: `poseFunc_faceScreen` (00:0EA5) is a *wait* on
  `countdownTimer`, which `loadGame_samusData` sets to $0140 and the vblank handler ticks
  down. Control arrives on the first frame the counter is spent and something is pressed,
  which is movie frame 326 — the segment's own origin.
- **`$0F`, 67 frames from frame 5504 in `$C:$81`.** Knockback. B4 names `$0F` and `$10` as
  the poses Phase 0a has no handler for; the run reaches `$0F` and not `$10`, so `$10`
  enters through B4's own work rather than through the published route.

## The landing site, stated three times

Step 7 pinned `initial_save` (01:4E64), the $26 bytes `createNewSave` copies into
`saveBuffer` before game mode $02 reads them. It is the game's own answer to where the
game begins, and it agrees with two answers this repository already had:

| what | says | from |
|---|---|---|
| the any% trace, frame 6 | Samus `07D4,0648`, map bank `$0F` | replaying the published movie |
| the any% trace, frame 8 | camera `07C0,0640` | the same |
| `initial_save` | all four, and facing right | the cartridge, one game mode earlier |
| `screens.assign` for `$F:$76` | metatile table 5 | the door graph |
| `initial_save` | metatile source `$5280`, which is table 5 | the cartridge |

The last pair is the one worth keeping. Cell `$F:$76`'s table is `.scrolled` provenance at
distance 2 — no door states it, and it was inferred two hops through the graph — which is
exactly the class of answer `bug_tracker.md`'s open 2026-09-05 item is about. Here the
inference is confirmed by a part of the ROM that owes the door graph nothing.

The same record disagreed with `offsets.zig` about the surface's *collision* table, and
that disagreement was a real defect in our labelling; see `bug_tracker.md`, 2026-09-08.

Per bank: `$F` reaches all thirteen; `$C` adds `$0F`; `$A` and `$B` reach only the
ordinary movement set.

## Enemies, as the spawn data has them

Measured 2026-09-08 for Step 9 (B4a), from `enemy_data` (03:$50E0) and
`enemy_data_pointers` (03:$42E0) through `src/entity.zig`.

The structure is exact, which is worth stating because the walk that reads it takes
advantage of every part of it:

| what | number |
|---|---|
| pointers, = 7 map banks x 256 screens | 1792 |
| distinct pointer values | 1792 — no two screens share a list |
| lists found by walking the region linearly | 1792, and `ptr[i]` is the *i*'th of them |
| lists that are empty (a bare `$FF`) | 1368 |
| four-byte records in the rest | 665 |
| distinct enemy ids used | 67, the highest `$F8` |
| spawn numbers used | `$0B` to `$7B` — inside the 128-byte `$C500` array, straddling both halves |

That `ptr[i]` is the *i*'th list in ROM order is not a curiosity: 03:$40BE reaches the
screen next door by stepping over a terminator rather than looking the pointer up, on
the assumption that the two lists abut. The measurement is what says that assumption
holds everywhere and not just where the game happens to walk.

**The landing site has an enemy on it.** `$F:$76` carries one record — spawn 15, type
`$9D`, at (`$38`,`$B8`) — and its left neighbour `$F:$75` carries spawn 14, type `$9B`,
at (`$D0`,`$B8`). Both sit near the boundary between the two screens, which is where the
walk finds them: the camera's left edge sweeps `$75` while Samus stands in `$76`.

**The oracle segment's cell does not.** `oracle.chooseStart` picks map index 0 — bank
`$9` — cell `$38`, and its list is empty; the segment's neighbour `$9:$37` has two
records, which the roll leftwards reaches. This is written down because the Step 9 plan
said the opposite, having crossed the segment's start with the landing site above.

### The AIs the slice runs, measured 2026-09-13 off the game rather than the data

Step 12f ports "the enemy AIs the region needs", and the spawn lists turned out to be
the wrong instrument for that question. Read over the published route they name 6 AIs;
over the cells the recording's 64-frame census passes through, 13; with the neighbouring
screens added — which 03:$40BE does read — 20, Gamma and Zeta Metroids among them. The
census steps over short visits and the neighbour rule loads screens nobody scrolls to,
so the first under-counts and the last over-counts, and nothing in the data says which
of the three is the answer.

So the game was asked. `enemy_commonAI` ends at 02:5650 in `JP (HL)`, with HL loaded
from `hEnemy.pAI` two instructions earlier, and every AI any enemy runs goes through
that one instruction. `zig build gbtrace -- ais 73400` hooks it and keeps one record per
distinct (AI, `hEnemy.spriteType`) pair across every frame through Alpha 2's death at
73 390 — the `blocks_seen` argument again: a thing that happens between samples has to
be counted. One pass, one replay, written to `build-out/ais-73400.tsv`.

**Thirteen AIs**, and the set is exactly the 64-frame census's, so the lossy method got
lucky here and the neighbour rule did not. `spriteType` is the animation frame, not the
spawn record's type, which is why most AIs show two to eight sprites. Names are M2RoS's.

| AI | M2RoS | first dispatched | last | graded |
|---|---|---|---|---|
| 02:4DD3 | `enAI_itemOrb` | `$F:$10` at 16 530 | 68 806 | ported, Step 11 |
| 02:5542 | `enAI_rockIcicle` | `$A:$44` at 1 066 | 32 367 | ported 12f, `$A:$54` |
| 02:57DE | `enAI_crawlerA` | `$F:$6A` at 9 842 | 59 283 | ported 12f, `$F:$6A` and `$A:$0A` |
| 02:58DE | `enAI_crawlerB` | `$F:$6A` at 10 162 | 59 057 | ported 12f, `$F:$6B` |
| 02:5ABF | `enAI_smallBug` | `$A:$44` at 1 083 | 58 239 | ported, Step 10 |
| 02:5CE0 | `enAI_gullugg` | `$9:$E5` at 40 673 | 60 965 | ported 12f, `$9:$E6` |
| 02:5E0B | `enAI_chuteLeech` | `$B:$13` at 32 427 | 72 001 | ported 12f, `$9:$C9` |
| 02:5F67 | `enAI_pipeBug` | `$B:$16` at 36 497 | 60 340 | ported 12f, `$B:$17` |
| 02:61DB | `enAI_hopper` | `$A:$44` at 1 270 | 19 466 | ported 12f, `$A:$45` |
| 02:62B4 | `enAI_wallfire` | `$D:$38` at 42 292 | 66 382 | ported 12f, `$D:$4C` |
| 02:6A14 | `enAI_missileDoor` | `$D:$45` at 43 957 | 44 132 | ported 12f, `$E:$6A`, with hits |
| 02:6BB2 | `enAI_hatchingAlpha` | `$F:$11` at 15 963 | 16 888 | Step 13c, `$F:$10`; killed 13d |
| 02:6C44 | `enAI_alphaMetroid` | `$E:$07` at 72 765 | 73 390 | Step 13c, `$E:$B2`; killed 13d |

**`enAI_senjooShirk` (02:5C36) is not on the list.** Step 10 ported it because the
published run's oracle segment is knocked down by one; James's recording never
dispatches it. It stays — the segment rung reads it — but it is not a slice AI.

**Where the graded rooms are not the census's rooms, it is for a reason the oracle measured.**
`zig build oracle -- enemies` grades each AI in a room it lives in, and several first
meetings are unusable as fixtures: the Chute Leech at `$B:$13` and the wallfire at `$D:$3B`
hang below or above the view and are deactivated before their AIs run (a faulted cart agreed
with the honest one, which is what said so), and `$C:$21`, `$C:$31`, `$A:$42` and `$A:$22`
move the cart's camera where the Game Boy's stays still — open in `docs/bug_tracker.md`.

## The two kills, shot by shot

Step 13d's enemy oracle kills each Alpha at the recording's own ticks, and these are them.
Method: `zig build gbtrace -- kills 15900 17300` and `-- kills 72700 73420` write one record
on every frame a fight's state moved -- `metroid_state`, `cutsceneActive`,
`alpha_stunCounter`, `metroid_fightActive`, the post-death timer, both counts, and the
AI-facing collision copy `enemy_weaponType`/`enemy_weaponDir` -- with the Alpha's slot beside
them. A shot's frame is the one `enemy_weaponType` takes it, which is the pass that acted on
it.

| Alpha | fight starts | shots, frames after it (direction) | dies |
|---|---|---|---|
| 1, hatching, `$F:$10` | 16 265 (intro from 15 993) | missiles +288 up, +354 up, +414 up, +511 right, +623 up | 16 888 |
| 2, plain, `$E:$07` | 72 894 | beam +2 right; missiles +86 right, +144, +344, +440, +496 up | 73 390 |

Both have five health and die on the fifth missile. Samus touches each (`$20`) several times
between shots. **After the kill both play out identically**: the slot becomes `$E2`, the
explosion's four blasts take 56 frames and the slot is gone at +56; the post-death timer steps
on every frame whose `$FF97` is even until it reads `$90` at +290, and on the frame after
that the restore clears it and `metroid_fightActive` (17 179 for Alpha 1). The counts fall on the killing pass: 47/39
→ 46/38 and 46/38 → 45/37.

### What the first kill sets going: the earthquake (Step 14)

`zig build gbtrace -- kills 16265 18500`, with the pass now also watching
`nextEarthquakeTimer` ($D091), `earthquakeTimer` ($D083), `songRequest_afterEarthquake`
($D0A5) and the driver's two interruption bytes ($CEDE, $CEDF), and carrying `scrollY`:

| frame | what happens |
|---|---|
| 16 888 | the kill: the count reaches `$46`, the first entry of `earthquakeCheck`'s thresholds, and the countdown is armed to **3** |
| 16 956 | first tick (`$FF97` is `$00`): 2 |
| 17 212 | second tick: 1 |
| 17 468 | **no tick**: the counter's zero fell on a frame the play handler did not run |
| 17 724 | third tick: 0. `earthquakeTimer` is `$FF` and falls to `$FE` on the same (even) frame; the interruption `$0E` is asked for and the driver's byte reads `$0E` |
| 17 724–18 250 | the timer falls once every two frames, 255 steps; `songInterruptionPlaying` stays `$0E` throughout |
| 18 250 | the timer reaches 0: the game clears the driver's byte, finds no held song and asks for interruption `$03`; the driver's byte reads `$02` for one frame, then `$00` |

**The second kill starts no quake.** It leaves the count at `$45`, which is not a threshold;
the next is `$42`. So in the slice the quake is the first kill's alone. The same kill opens
the `$46` door gates (see the correction above), which is the game's own pairing of the two.

## An unclaimed check

The out-edge rule at the top of this file explains 66 of the run's 67 in-map cell changes.
That is a property, it is cheap, and nothing asserts it today. It belongs as a rung when
Step 3 extends the porting loop — a map model that stops explaining the run's own route
has broken, and right now nothing would say so.
