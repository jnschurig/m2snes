---
created: 2026-09-02T05:05:09Z
updated:
  - 2026-09-02T05:05:09Z
  - 2026-09-02T06:05:03Z
  - 2026-09-02T16:11:48Z
  - 2026-09-03T22:48:28Z
  - 2026-09-04T04:58:44Z
  - 2026-09-05T20:01:48Z
  - 2026-09-07T05:14:04Z
  - 2026-09-07T21:25:04Z
  - 2026-09-08T02:04:52Z
  - 2026-09-08T04:28:21Z
  - 2026-09-09T14:26:06Z
  - 2026-09-14T16:41:47Z
  - 2026-09-14T17:10:45Z
  - 2026-09-14T20:38:24Z
  - 2026-09-14T22:29:12Z
  - 2026-09-15T01:26:05Z
  - 2026-09-15T02:47:43Z
  - 2026-09-15T04:00:54Z
  - 2026-09-15T14:31:17Z
  - 2026-09-15T14:58:57Z
  - 2026-09-15T17:39:05Z
  - 2026-09-16T18:25:22Z
  - 2026-09-21T02:56:22Z
  - 2026-09-24T19:38:07Z
  - 2026-09-25T16:13:16Z
  - 2026-09-25T18:35:11Z
  - 2026-09-25T20:26:33Z
  - 2026-09-25T20:42:18Z
  - 2026-09-25T20:50:19Z
  - 2026-09-25T22:04:50Z
  - 2026-09-25T22:12:55Z
  - 2026-09-25T22:17:39Z
  - 2026-09-25T23:04:38Z
  - 2026-09-26T01:30:24Z
working_directory: /Users/james/git/snes_game_dev
---

# Requirements

## Status: Final

## Overview

Phase 0b of the Metroid II SNES port: the **playable slice**. Landing site through the second
Alpha Metroid, as one contiguous region, manually playable start to finish on real hardware.
This delivers **D2** in `../2026-08-22-metroid2-snes-port/01-requirements.md` and the parts of
**F5** (game logic rewrite), **F6** (Metroid progression chain) and **F7** (play window and
camera) that the slice touches.

Target repository is **`~/git/m2snes`**, standalone and private. Paths below are relative to it.

## Where Phase 0a left this

Phase 0a closed **GO** on 2026-09-01 (Step 18). These are measurements, not estimates, and they
are what this cycle is planned against:

| fact | number | why it matters here |
|---|---|---|
| Dispatch reduction | **49.0%** — 7248 of 14782 ledger instructions statically reachable from a located table entry | The single largest sizing unknown for 0b. Half the logic is "port the dispatcher, transfer the table" |
| Asset region sizing | **fits**, tightest class `map_screens` at 70% of its region | The engine image does not need re-layout before more code lands |
| Logic ledger | **262 routines, 11818 instructions**, 59% of the stated ~20000 lines | The concrete routine backlog, with real counts |
| Reachable-frame count | **375 of 899** offered frames of the any% run (floor 375) | Where the port stops following the original |
| Anchored count | **390 of 5174** frames across 9 of 13 stretches (floor 390) | How much of the run it can play at all |
| Segment oracle | **644 frames**, position, camera and pose, frame for frame | The hand-authored fixture, now including the ball |
| Unreached dispatch layers | **4 named**, plus **5 sites** with table addresses no run has entered | Known holes, listed rather than counted |

**The reachable count stops on a room transition, and that is now confirmed by measurement
rather than predicted.** Reference frame 375 is movie frame ~703, where the map bank goes `$0F`
to `$0A`. Samus's *pixel* offsets across the stop are unchanged (`F3`, `84`) and only her screen
numbers move — she is in another room. The thirteen frames before it are already reproduced, so
the geometry into the door is right and only the transition is missing.

**One Phase 0a hand-off item is already closed.** The morph bug (`docs/bug_tracker.md`), which
Step 18 named as 0b's opening work, was fixed on 2026-09-02: `PoseJump`'s arc exit had dropped
the original's test at 00:$1837 of who was flying the arc. Position and camera could not see it,
so `pose` became a third graded quantity and the segment grew 324 frames that exercise the ball.
That is why the segment is 644 frames and why two floors were re-measured.

## What the TAS oracle can and cannot reach

Recorded here because a requirement written against a misreading of it would be unbuildable.

**The anchored rung's 13 "stretches" are segments of the published any% run, not rooms in the
slice.** They are the spans between the game's handovers of control across the first 8407 frames.
Four cannot be graded. `zig build oracle -- settle` was computing the diagnosis and not printing
it; it prints it now (commit `e131ad0`), and the four resolve into two problems:

```
 4  map 3 cell $51: cart table 9 (nearest warp target, 5 away), gb best 4 at 399
 8  map 3 cell $71: cart table 9 (nearest warp target, 7 away), gb best 4 at 399
11  map 2 cell $0D: cart table 0 (nearest warp target, 9 away), gb best 0 at 0
12  map 2 cell $0D: cart table 0 (nearest warp target, 9 away), gb best 0 at 0
```

- **4 and 8 are a tileset-assignment error with an unambiguous known answer.** Table 4 explains
  what the Game Boy was actually showing in **399 of 399** tiles; the cart booted with table 9.
  Nothing about this is a conversion defect, and nothing about it needs investigating visually —
  the numbers already decide it.
- **11 and 12 compared zero tiles.** A boot record exists; the camera window selects no slot
  inside the boot cell, so there was never anything to compare. Both are the same cell, nine
  frames apart, at a transition boundary. A different problem with a different fix.

**None of this is the TAS failing to visit, and none of it is fixed by a save state.** The run
visits all thirteen. The blocker is the cart's construction, not the reference's placement.

**The cause is one heuristic, and it degrades measurably with distance.** All four cells got
their tileset from `screens.assign`'s inference — "nearest warp target in the same region" — at
5, 7, 9 and 9 grid steps. No door states the tileset for any of them. The reachable rung's own
cell is inferred too and is correct, at **2** steps. Across the map the split is 41 stated by a
door, 838 scrolled, 25 bank default: **most of the map is inferred**, so this is a systematic
question rather than two bad cells.

### Why the render rung could not have caught this

`zig build verify` reports `904 screens match the Game Boy reference pixel for pixel`, with a
fault sweep catching 4/4. That is easy to read as validating the tileset assignment. **It does
not.** `snes_render.Renderer.pair` takes one `t = tiletable orelse choice.tiletable` and renders
*both* sides through it — `gbTable(t)` for the reference and `tbl.table(t)` for the converted
screen. The rung's claim is "the same screen body, expanded through the same metatile table,
renders identically before and after conversion", which is a thorough check of the *conversion*
and says nothing about whether `choice.tiletable` is right. A cell with the wrong table renders
identically wrong on both sides and passes.

`compareWorlds` is the only check that can catch an assignment error, because there the Game Boy's
tiles come from a **running emulator** rather than from our own assignment. It currently runs at
a handful of anchors. That gap is B12.

**Three hard bounds on replaying a recorded run, which shape this cycle's verification.**
The first two are about the published movies and were here from the start; the third was
measured on 2026-09-03 and is about every movie, this cycle's own recording included.

1. **The replay horizon is frame 8407** (any%) and **4566** (100%) — where our replay stops being
   the published run. Nothing past it can be graded. **Measured 2026-09-03 (Step 1): the slice
   does not fit inside it.** `$D089` holds `$47` for every frame of the any% replay — no Metroid
   is killed inside the horizon, not the second Alpha and not the first. The geography is
   covered, so B1, B12 and B2 keep their published-TAS grading; everything from the entity work
   onward does not, which is what makes B11 the primary grader rather than a supplement.
2. **No published run visits a save station**, because saving is never faster than not saving.
   Known since 2026-08-30. The save path cannot be graded from these movies at any horizon.
3. **A Game Boy movie replayed on an emulator that did not record it diverges after a few
   thousand frames, and the horizon does not depend on the movie.** The published VBA runs
   stop at 8407 and 4566. James's 76 951-frame Mesen2 recording, converted into `tas.zig`'s
   word layout and verified against the ROM header, stops at **28 796** by
   `tas.faithfulness` — and before that, before his first save, since one byte of cartridge
   RAM is written in the whole replay against a recording that saves several times. It is
   not the frame source and not the origin: `vblank`, `cycles` and `lcd` each fail, and
   offsets 0–7 under both `vblank` and `cycles` stall in the same cell on the same frame.
   Sixteen combinations, one outcome. See `~/git/m2snes/docs/slice.md`.

**Therefore this cycle adds a third reference input: a run recorded by James.** The original
wording of this section assumed that input would be another VBM replayed on our own Game Boy
emulator, the way the two published movies are. Bound 3 is that assumption failing. So the
recording's value is as a **reference trace** produced by the emulator that recorded it, not
as an input stream for ours — which is what B11 now asks for.

## Features

### B1. Room transitions and screen streaming

The mechanism the reachable count stops on, and the critical path for everything after it.

**Merged 2026-09-02.** This absorbed a separate "duration defects" feature. Both are the same
subsystem — holding Samus while an incoming screen is drawn is what a boundary crossing and a
room transition each do — and splitting them meant doing the streaming work twice.

**Acceptance Criteria:**
- Door scripts drive a transition end to end: the interpreter's opcodes execute against the
  converted door data, and the map bank changes
- The camera **re-seats** on the far side the way the original's does. Phase 0a established
  that the original's camera is placed by the transition that brought Samus into the room and
  is not on her at the handover; `BootCamX`/`BootCamY` carry a measured one today, and this
  replaces that seeding with the real mechanism
- The incoming screen is streamed and drawn before control returns, and `!TilemapBuf` holds
  the same tiles the Game Boy's background map holds for that room
- **The two duration defects are fixed.** The port crosses a screen boundary leftwards in 1
  frame where the original holds Samus for 21 while it draws the incoming screen; two other
  boundaries hold her 47–48 where the original holds 1. The `durations` rung's floors (15
  stretches compared, 11 inside 2%) are raised, and the new numbers are measured
- The reachable-frame count **passes 375 and the floor is raised**, **and the new stop condition
  names a different mechanism than this one**. A transition that lands and then immediately
  diverges again on room transitions has not been delivered, and a raised floor alone would not
  say so
- Both a horizontal and a vertical transition are exercised, per D2
- **A fade door looks like a fade — added 2026-09-16 (Step 20).** On the Game Boy a `FADEOUT`
  script still runs the camera's scroll, but with the palette at `$FF` (black) the whole way,
  and only then fades in (`.endDoor` 00:$1880 → `fadeIn` 01:$7A45). Measured on door $1DF in
  the any% run: fade out 613–644, black to 746 with the camera scrolling 707–746, fade in from
  748. The port shows that scroll. Acceptance: on a fade door the cart's screen brightness
  follows the Game Boy's palette frame for frame (dim steps mapped to SNES brightness, a stated
  substitution), and the camera's track is unchanged

**Out of Scope:**
- Transitions outside the slice's region
- The elevator/area-change sequences, unless one falls inside the region — if it does, it is
  in scope; if not, that is recorded explicitly as deferred rather than assumed working

### B2. Title-to-game transition

Also the point at which the cart stops needing synthesised boot records to be played at all,
which is what makes hand playtesting the primary development loop for the rest of this cycle.

**Acceptance Criteria:**
- Pose `$13`'s 320-frame sequence runs, which Step 15b measured as what stands between the cart
  and the movie's frame 0
- The cart reaches gameplay from a cold boot without a synthesised boot record — the boot record
  remains available as a test fixture, but is no longer the only way in
- `title_tilemap`, catalogued as unknown in Phase 0a because it is in bank 5 with no address
  comment, is either pinned and converted or recorded as still unknown with what was tried

**Out of Scope:**
- The file-select and save-slot UI beyond what the slice needs to start. **Amended 2026-09-25:**
  the slot cursor, the three slots and the clear option are now in scope, as B14
- Attract mode and the ending sequence

### B3. The porting loop's second arm

Phase 0a's porting loop knows how to port a **pose handler**. The slice needs it to port a
**mechanism**, and that design is this cycle's work rather than a carry-over.

**Acceptance Criteria:**
- The loop as carried over in the Phase 0a plan is extended with a documented second arm for
  mechanisms, and the extension is committed before the mechanism work that uses it
- Each mechanism ported adds `ledger.zig` rows and `residue.zig` entries the way each pose did
- `zig build verify`'s "is no longer an instruction boundary" check still passes, so a ledger
  row that the observed run never dispatches is dropped rather than weakened

**Out of Scope:**
- Refactoring the pose arm, which works

### B4. Enemies

**The largest genuinely unknown chunk in this cycle.** Enemy AI dispatch is one of the four
layers Phase 0a's survey named as unreachable by any run it could make, so the 49% dispatch
figure says little about it — it is being entered for the first time.

**Acceptance Criteria:**
- Enemy AI dispatch is ported: the header/AI-pointer tables from Steps 4 and 14 drive live
  entities
- The enemy slot count stays at the original **16**, and spawn/despawn windows are identical to
  the original — both are prerequisites of the TAS oracle and changing either desyncs whole-game
  verification (F5)
- Hitboxes and damage values match the original's data tables
- Samus takes damage, including the knockback poses `$0F` and `$10` that Phase 0a has no handler
  for
- Alpha Metroids specifically: spawn, AI, damage state, and death
- **The segment fixture is extended past frame 676.** Pose `$10` in the segment's own room is
  what currently caps it at 644 frames; once damage exists, the fixture grows and the extension
  is measured rather than assumed

**Out of Scope:**
- Gamma, Zeta, Omega and the Queen
- Enemy types not present in the slice's region, beyond what the shared dispatch requires

### B5. Projectiles and combat

**Acceptance Criteria:**
- Samus fires; projectiles spawn, travel, collide with terrain and with enemies, and despawn
- **Shot and bomb blocks are destroyed, and they come back. Added 2026-09-08.** The original
  wording said projectiles "collide with terrain", and colliding is not destroying — a block that
  a shot removes changes the room's geometry, and nothing in this document asked for that.
  `engine/main.asm`'s own note has said since Phase 0a that shot and bomb blocks are "deliberately
  not ported" and need projectiles to mean anything; this is the criterion that closes it.
  Specifically: the classification the original uses (a tile below `beamSolidityIndex`, then tile
  ids `$00`–`$03` hardcoded as respawning and every other id tested for bit 5 of the collision
  byte), the 16-slot respawning-block array with its animation and its reform, and the permanent
  destroy that writes the tilemap. **Collision reads the tilemap on both sides, so a destroyed
  block must change what Samus can stand on** — that is the observable the tests grade, not the
  picture
- Missiles, and the beam/missile toggle, to the extent the slice's region requires them for the
  Alpha Metroid kills
- **Samus starts a new game with what the original gives her. Added 2026-09-14, from a playtest.**
  James pressed Select, the toggle changed mode, and nothing fired: the cart's boot record carries
  no energy, missile or Metroid-count fields, so every cart starts with zero missiles and
  `samusShoot`'s dud arm is the only one a new game can reach. The values come from the ROM's
  `initialSaveFile` (01:$4E64) — 99 energy, 0 tanks, 30 missiles of 30, `metroidCountReal` `$47`,
  `metroidCountDisplayed` `$39` — read off the ROM rather than transcribed. A handover boot
  takes the fields the trace carries (`$D050` tanks, `$D081` max missiles, `$D089` real count) from
  the trace it was anchored on, and the new game's values for the ones it does not (current
  health `$D051`, current missiles `$D053`, displayed count `$D09A`) — and the record says which
  is which. Growing the trace to carry them means re-running the 76 951-frame replay, and no
  graded stretch fires a missile or reads the HUD, so it is not done for this. The observable is a missile leaving the cannon
  and the count falling by one
- The `B` button joins `oracle.supported_input_bits`. **This is a measurement-affecting change,
  of the same class as `codes_per_quantity`:** it alters what the cart is handed on every graded
  frame, so every floor is re-measured in the same commit and each records that this is why it
  moved. Once B9 lands the floors are exact frames and this is cheap; before it, it is not

**Out of Scope:**
- Beam upgrades not reachable in the region
- Stackable beams, which are QoL (F12)

### B6. Items and pickups

**Acceptance Criteria:**
- Item pickup works for every item type present in the region, and the item's effect is applied
- `!Items` gates behave: the branches Phase 0a wrote out but could never reach fire correctly
  when the item is held. **Scoped 2026-09-03 to what the region actually yields**, which the
  B11 recording settles: **Bombs in the bomb jump, and Spider Ball**, which Step 1 had deferred
  as out-of-region on the published run's coverage alone. **Hi-Jump and Spring Ball are not
  collected** — neither is in the recording, and Hi-Jump's three doors are referenced by no
  cell — so their branches stay unreachable this cycle and that is a deferral, not a gap
- The `enemy_data` and `item_names` asset classes, which `zig build coverage` names as unread
  and owned by Phase 0b, are read and converted
- `samus_pose_tables` for the poses Phase 0a does not run, likewise

- **Spider Ball works, not only registers. Added 2026-09-15, from a playtest.** Step 11 delivered
  the bit and `pose_sprites_spider` and deferred the spider poses `$0B`–`$0E` to Phase 1; James
  found on hardware that the route to the second Alpha needs them, so D2 cannot be met without
  them. The poses and every `!ITEM_SPIDER` branch the slice reaches are ported, and graded against
  the recording's Spider Ball stretch (collected at 68 453, before the second kill at 73 392)

**Out of Scope:**
- Items outside the region
- The Hi-Jump and Spring Ball `!Items` branches, per the criterion above

### B7. Save and load

**Acceptance Criteria:**
- **A normal save station is located and brought inside the slice's region, even at the cost of
  growing the region slightly.** The ship counts as a save station and will be in the region
  anyway; it is not sufficient on its own, because the ship is the start state and a station
  entered mid-play is the case the save path actually has to survive
- Saving writes a record `src/save.zig` decodes, and loading restores it
- The scenario James named on 2026-08-30 is the test, because a TAS cannot exercise this: spawn
  Samus with one unit of energy, walk her to a save station, let something damage her, and assert
  that the state the game loads is the state the record said it would be. It is a `room.zig`
  scenario rather than a movie
- **The load path gains a second grader, free — added 2026-09-03.** The B11 recording dies once
  and reloads from the last save, so the reference trace carries a real load. The `room.zig`
  scenario stays the primary test, because it is the one that can be made to fail on demand;
  the recording is the check that the scenario's idea of a load matches the game's
- `metroidCountReal` persists across save/load (F6)
- **Samus can die, and a death returns to the title and the save — added 2026-09-15.** The
  scenario above and the recording's reload both pass through it, and the port had no death at
  all: `killSamus` (00:2FA2) at displayed health zero, the death animation, the game over screen
  and its timer or Start, and the reboot to the title. Graded by length against the Game Boy
  (the memory's rule for cutscenes), and the title's load against the record it reads
- The station's own behaviour: contact from the save tile's collision bit, cleared by doors, the
  "PRESS START"/"COMPLETED" window arm on Start, and the save RAM the cart keeps laid out as the
  Game Boy's so `save.zig` decodes it unchanged

**Out of Scope:**
- Multi-slot file management beyond what the slice needs: the cart uses slot 0, and the title's
  slot cursor and clear-file option stay out. **Amended 2026-09-25:** moved into scope as B14,
  from James's request — a slice with a save and no way to erase it is not complete
- The pause screen

### B8. Metroid progression chain

F6 end to end, which spans five subsystems and is why D2 requires the *second* kill.

**Acceptance Criteria:**
- `metroidCountReal` decrements per kill and persists across save/load
- `metroidCountDisplayed` shuffles toward the real count on its timer rather than snapping. The
  timer's countdown and the scrambled draw are B13's (the status-bar routine owns both); this
  criterion is the kill setting the timer and the displayed count landing on the real one
- `nextEarthquakeTimer` arms after a kill; the earthquake fires on its delay, and the music
  interruption **path** fires and restores. With F8 in Phase 0c, **a silent stub is the expected
  outcome**, not a fallback — what must be proven is the path, not that a track plays. If 0c has
  landed by then the track plays instead, and that is recorded as a bonus
- At least one `IF_MET_LESS` transition demonstrably reaches content that was unreachable before
  the first kill. **Amended 2026-09-15:** this said "the second kill", on a misreading of the
  opcode as strictly-less; 00:$254A takes it at or below the operand, so `$46` opens at `$46`. D2
  still asks for the second kill, which proves the chain repeating from the count the first left.
  Only the `$46` threshold is reachable in the slice; the other 12 are Phase 1
- If a lava/acid drain is reachable in the region, the `lavaCaves` tileset swap between the Mid,
  Empty and Full metatile variants is exercised. **If it is not reachable, that is recorded
  explicitly as deferred rather than assumed working**

**Out of Scope:**
- The remaining 12 `IF_MET_LESS` thresholds
- The Queen sequence

### B9. Gate numbers that do not move for tooling reasons

**Added 2026-09-02, from the morph fix.** Adding `pose` as a third graded quantity forced
`codes_per_quantity` from 80 to 60, which moved `movie_gate_floor` 372 → 375 and
`anchored_gate_floor` 394 → 390 without the port changing at all. That is the second time
configuration has moved a headline number, and B5 would be the third.

The root cause is single and known: **Mesen2 swallows `emu.log` in testrunner mode and sandboxes
Lua's `io`, so the entire verdict is squeezed through a one-byte process exit code.** Widening
bands only moves the next collision. The fix is to stop the floors being bucket edges.

**Acceptance Criteria:**
- The reachable rung reports the **exact** divergence frame, not a bucket's bottom edge, by
  generalising the existing `refine` in `gradeMovie` into a bisection: truncate the reference to
  N frames, run, and bisect on match/no-match. About 10 runs resolves 900 frames
- `movie_gate_floor` and `anchored_gate_floor` become exact frames, and changing
  `codes_per_quantity`, adding a graded quantity, or adding an input bit no longer moves them
- The cost is measured and stated. If bisecting every anchored stretch is too slow for the gate,
  it is applied to the headline reachable rung and run on demand for the rest — and that choice
  is recorded with the timing that drove it, not asserted
- A test asserts the property directly: the floor is unchanged across two different values of
  `codes_per_quantity`

**Out of Scope:**
- Replacing the exit-code channel itself, or patching Mesen
- Retro-fitting exactness to the `durations` rung

### B10. Verification for the slice

**Acceptance Criteria:**
- **The conformance harness for this cycle is named explicitly**, since D2's wording predates it:
  it is `zig build verify` green end to end, with the segment oracle, the reachable rung, the
  anchored rung, and the `durations` rung, plus the `room.zig` scenarios for paths no movie
  reaches
- Floors are raised where the slice's work bears on them. **The anchored floor's criterion is
  scoped to the nine gradable stretches**, because four are capped by conversion work this cycle
  explicitly defers, and a criterion whose ceiling is set by out-of-scope work is not a criterion
- Every mechanism ported gets a rung or a fixture that fails when it is removed. The morph bug is
  the standing argument: it shipped to hardware because the comparator could not see it, and
  `MATCH: 644 frames` with the defect reintroduced is what that looks like
- **Every defect found by hand gets a failing fixture before it is fixed**, and the fixture is
  shown to fail against the unfixed engine. This is the morph bug's procedure made standing
- **The hardware pass condition, written down rather than judged by feel.** The slice is played
  start to finish on the FXPak against a cart whose digest matches the one the gate signed off,
  and the run log records: the minimum required rooms traversed; `metroidCountReal` showing two
  Metroids defeated; every required and collected item registering as collected; no lock-up. Any
  defect found lands in `docs/bug_tracker.md` with a repro
- If a rung is retired, that lands in writing with the reason. A gate that is green because a
  failing rung was deleted is worse than a red one
- **A playtest readout of where Samus is. Added 2026-09-15, from a playtest** that could not say
  which screen a wrong transition had led to. A toggle shows the map bank, the cell and the loaded
  metatile table id, **latched on each transition** so it can be read off the console at leisure.
  It is a development aid: off by default, drawn outside anything a rung grades, and not a
  presentation change

**Out of Scope:**
- Whole-game conformance, which is Phase 1

### B11. A recorded reference run for what the published TASes refuse

**Rewritten 2026-09-03.** The recording was delivered that day as `reference/metroid2.mmo`,
a Mesen2 movie of 76 951 frames that saves several times, dies once and reloads from the
last save, collects Bomb, an Energy Tank, a Missile Tank and Spider Ball, kills two
Metroids, and ends on a final save. **The recording is a superset of everything the
original B11 asked for. What failed was the mechanism**, per the third bound above, and
this feature is now the mechanism that works rather than the one that was assumed.

**The recording is not replayed on our Game Boy emulator. Mesen2 replays it, and what we
take from it is a trace.** Mesen2 replays its own `.mmo` deterministically — that is what
the movie's embedded `SaveState.mss` is for, and it is why `gameboy.ramPowerOnState
Random` costs us nothing under this design. Mesen2 is already a resolved dependency
driving Lua scripts headlessly for the SNES side, so this is a second script against an
emulator the gate already runs, not a new dependency.

**Acceptance Criteria:**
- **A Game Boy Lua sampler for Mesen2 produces a reference trace of the whole recording**,
  in the columns `tas.zig` already writes: frame, input, `samus_y`, `samus_x`, `camera_y`,
  `camera_x`, pose, map bank, Metroid count, and a WRAM digest. It covers all 76 950 frames,
  not a horizon
- **The trace is verified against the cartridge before it is trusted**, the way `tas.parse`
  verifies a movie: the movie's own SHA-1 and the ROM the sampler ran against are both
  checked to be `metroid2.gb`. A trace taken on another revision fails by name
- **The trace is read by the same code paths the published runs' traces are**, so the
  reachable, anchored and `durations` rungs treat it as a third track rather than a special
  case. Where that requires generalising a reader, the generalisation lands with a test
- **Anchors are taken from the recording's own trace**, and Steps 10–14 grade the cart by
  spawning at an anchor and running forward — the anchored machinery's existing shape. This
  is what removes the horizon: nothing has to replay 76 950 frames of Game Boy history
- **An anchor carries the world, not only Samus. Added 2026-09-08.** Position, camera and pose
  are not a room's state: the recording shoots blocks out to descend — the third screen is the
  first place it does — and from there the recording's world has holes the port's does not.
  An anchor that restores only Samus drops her onto a floor the trace does not have, so an
  anchor must also restore the background tilemap and the live respawning-block slots as the
  recording had them at that frame. **This is what lets the trace grade Steps 9–11 before the
  port can fire a shot**, and it is a property of the anchor rather than a workaround: an
  anchored sweep is only sound if the anchor states the whole world it resumes
- **The two Metroid kills are located from the trace and written into `docs/slice.md`**,
  closing the one question Step 1 recorded as open — which rooms hold Alphas 1 and 2
- The recording and any trace derived from it are **vendored input**: untracked, dev-time
  only, supplied like the published movies
- **The converted VBM (`vendor/tas/metroid2-recorded.vbm`) and `zig build tas -- rec` are
  retained as the probe that measured the third bound**, and the horizon they measure is
  recorded rather than left as folklore. They are not a grading path

**Out of Scope:**
- Requiring it to be tool-assisted or frame-optimal — it is a coverage instrument, not a speedrun
- Replacing the published runs as the whole-game reference
- **Making our Game Boy emulator replay the recording to its end.** That is the SameBoy
  reconciliation deferred below, now with a second argument for it and still deferred
- Re-recording. The delivered recording is sufficient under this mechanism, and three
  settings worth changing on any *future* recording — `ramPowerOnState` to zeros, `model`
  to Game Boy, `useSgb2` off — are recorded in `docs/slice.md` rather than acted on

### B12. Tileset assignment graded against the running game

**Added 2026-09-02**, from diagnosing the four ungradable anchors. `screens.assign` infers the
metatile table for **most of the map** — 41 cells stated by a door, 838 scrolled, 25 bank
default — and the render rung cannot check the inference, because it renders both sides through
the same choice. The only check that can is `compareWorlds`, which reads the tiles out of a
running emulator, and it runs at a handful of anchors.

This matters to the slice directly, not just to the anchored rung: B1 hands Samus into a room and
the incoming room's tilemap has to be right, and a wrong table is invisible to every rung except
one.

**Acceptance Criteria:**
- The world comparison is swept across cells rather than run only at anchors: for each cell the
  observation can reach, the table `screens.assign` chose is compared against the table that best
  explains what the running Game Boy displays
- The sweep reports disagreements with both tables, the tile counts and the provenance — the
  shape `zig build oracle -- settle` now prints — so a disagreement names its own fix
- **Map 3 cells `$51` and `$71` are corrected**, where table 4 explains 399 of 399 tiles against
  the assigned table 9. Anchored stretches 4 and 8 become gradable, which is the check that the
  correction is real
- Whether the fix is per-cell or a change to the inference is decided by what the sweep finds.
  The distance evidence points at the inference — correct at 2 grid steps, wrong at 5 and 7 —
  but two cells are not enough to retune a heuristic on, and the sweep is what makes it enough
- **The render rung's claim is restated to say what it actually checks**, so "904 screens match
  pixel for pixel" is not read again as validating an assignment it renders both sides through
- Map 2 cell `$0D`'s empty window (stretches 11 and 12) is diagnosed and either fixed or recorded
  with what it turned out to be. It is a different failure from the other two and is not assumed
  to fall out of the same fix

**Out of Scope:**
- Cells the observation cannot reach, which cannot be graded this way and stay inferred
- Re-deriving the door-stated assignments, which are authoritative

### B13. The HUD

**Added 2026-09-14, from a playtest.** The SNES layout has reserved BG2 as the HUD band since
Phase 0a (`!HUD_H`, `snes_target.bg2_map_base`), and nothing has ever drawn into it. The original
shows it on every gameplay frame, and the Alpha kills are the first thing in the slice whose
consequences the player reads only there.

**Acceptance Criteria:**
- The band shows what the Game Boy's window shows, in the same place relative to the play window:
  energy tanks and `E`, the health digits, the missile icon and three missile digits, the Metroid
  icon and the two-digit Metroid count. The base tilemap is the ROM's `hudBaseTilemap` (05:$40F0)
  and the digit writes are `VBlank_updateStatusBar`'s (01:$493E), both read off the ROM
- The displayed health and missile counts roll toward the real ones a unit at a time, as
  `adjustHudValues` (01:$4A2B) does, rather than snapping
- The Metroid icon is `drawHudMetroid` (01:$4B2C): a two-frame sprite that swaps every 16 frames
  and rises 8 pixels while Samus stands on a save point or collects a major item
- The counter's scrambled arm is drawn, and the shuffle timer's countdown is ported with it —
  `VBlank_updateStatusBar` decrements `metroidCountShuffleTimer` itself, so this criterion is
  most of B8's displayed shuffle. What stays B8's is a kill *setting* the timer. The scrambled
  digits come from `rDIV`, which the port substitutes, so they are graded by **when** the scramble
  starts and stops (timer below `$80`, and zero) and not by which digits it shows
- The icon's rise is ported for both conditions. The major-item half is graded here; the
  save-point half is graded by B7, when a save station is in the region
- **Graded against a Game Boy reference render of the status-bar row**, not against a trace
  (no trace carries the window): our Game Boy emulator runs `VBlank_updateStatusBar` over chosen
  health, tank, missile and count values and the resulting 20 window tiles are compared tile for
  tile with the cart's BG2 row seeded the same way, including at least one value set taken from a
  trace frame. A fixture fails when a digit is wrong. **Adding the
  icon to OAM is an ordering change** (12c's `!OamIdx` lesson): every sprite rung is re-run in the
  same commit and any that moves records why

**Out of Scope:**
- The Queen room's HUD, which is drawn on the background layer, and the pause screen's L counter
- A wider or restyled HUD, which is presentation divergence (F12)

### B14. The title's file select, and clearing a save

**Added 2026-09-25, from James's request with three screenshots.** The cart's title shows the logo
and `RETURN OF SAMUS` and nothing under them; the Game Boy's shows a pulsing cursor beside
`START 1`, and `©1991 Nintendo` on the bottom row. A slice that saves and cannot erase the save
is not complete: the only way back to a new game today is wiping the cart's RAM by hand. The
original is `titleScreenRoutine` (05:$4118-$42C6) and `loadTitleScreen` (05:$408F); the port
has only its Start arm (`TitleStart`) and the slot-0 half of that.

**Acceptance Criteria:**
- **The copyright row is shown.** `titleTilemap`'s row 16 carries `©1991 Nintendo` (ids `$0F $1F
  $3E $3E $3F` and `$4A`-`$4F`, all inside the title's $1000-byte character run). The cart
  draws something on that row today that is not it; why is measured before it is fixed
- **The menu is drawn as the Game Boy draws it**, as sprites: `START` at ($44,$74), the cursor
  at x $38 and y $74 (or $80 while clear is selected) cycling `titleCursorTable` (05:$42E1)
  every four frames, the slot's number sprite (`$23` + slot) at the cursor's position, and
  `CLEAR` at ($44,$80) while the option is shown. Sprite ids, positions and tables are read
  off the ROM
- **The input arms are the original's, equality tests included**: Select (rising edge equal
  to Select alone) toggles the clear option with the select sound; Down *held* while the
  option is shown selects clear, with the sound on its rising edge, and releasing it returns
  the cursor to `START`; Start with clear selected runs `.clearSaveBranch` — the cleared-file
  noise, the slot's first two bytes zeroed, the option hidden, and the title stays up;
  Start without it starts or loads the selected slot as today
- **Three slots, Left and Right.** Right and Left (rising edge *and* held both equal to the
  direction alone) step `activeSaveSlot` through 0-2 with wrap, with the select sound. The
  save, the load, the spawn flags and the clear all use the selected slot, at `$A000 +
  slot*$40` and the spawn flags at `$1000 + slot*$200` in the cart's RAM, the layout the cart
  already keeps. Boot seeds the slot from `saveLastSlot` (`$A0C0`, taken when below 3, as
  the boot routine does; its address read off the ROM in design), so the title opens on the
  last slot played. `save.zig` already decodes all three
- **Every visit to the title opens the same way: clear hidden, cursor on `START`.** The game
  over's exit is `jp bootRoutine` (00:$01FB), which clears $D000-$DFFF, and with it
  `loadingFromFile` ($D079), `title_clearSelected` ($D07A) and `title_showClearOption` ($D0A4).
  So `loadTitleScreen`'s "select clear when loading from a file" branch is dead on the Game Boy
  and is not ported; the starting state it would have changed is graded instead, after a
  cold boot and after a death
- **Graded against the Game Boy, not against the port's own idea of it.** For a scripted input
  sequence (idle; Select; Down held and released; Right and Left through the wrap; Start on
  clear), the cart's menu sprites and the slot/clear state match our Game Boy emulator running
  the same inputs from the same boot, frame by frame; and the cart's framebuffer over the
  copyright row matches the Game Boy's render of it. **The sprites are compared as a set of
  (id, x, y), not slot for slot**: the Game Boy draws the star first, into OAM slot 0, and the
  port has no star, so every menu sprite sits one slot lower on the cart
- **The clear is graded by what it leaves behind**: a cart seeded with a save in a slot, cleared
  from the title, starts a new game on the next Start (the magic check fails as the Game
  Boy's does), and the other two slots are untouched. The existing `cold boot`, `load`,
  `death` and `round trip` rungs stay green, with slot 0 as their default
- Each new behaviour has a fixture shown failing on the current cart first (B10's standing
  rule), and the `snes boot` fault sweep gains the new routines

**Out of Scope:**
- The title's palette flash and the falling star — presentation the request did not ask for,
  and the star's respawn reads `rDIV`, which the port substitutes. Recorded as deferred
- The debug flag the Start arm clears
- Save-slot contents shown on the title (the Game Boy shows none)

### B15. "Super" on the title

**Added 2026-09-25, from James's request with two images**: `example_title.png`, the target
screen, and `super.png`, the art. The title gains a red script "Super" with a blue drop shadow
on the left, between the logo and `RETURN OF SAMUS`. **This is a deliberate presentation
divergence** and the one exception to the constraint below; it is new art, not ROM data, and
nothing the Game Boy draws moves or changes to make room for it.

**Acceptance Criteria:**
- **The art is `super.png`, pixel for pixel.** 67×17, three values: transparent, red
  `(190,6,6)` and blue `(24,44,136)`. The PNG is copied into m2snes and converted at build
  time; it is the source of truth, and nothing hand-transcribes it into tiles. Colours are the
  nearest 15-bit BGR values, which is the only permitted difference: red (23,1,1), blue
  (3,5,17) as 5-bit R,G,B, approved by James 2026-09-25 from `super_snes.png`
- **Placed at Game Boy (5, 61)** for the art's top-left, measured from `example_title.png`
  (~4.05× the Game Boy's 160×144). The position is one named constant, so James can move it
  after looking at the render; that is a one-line change, not a new step. It is drawn in
  front of everything it overlaps (the `p`'s descender reaches `RETURN`'s top row)
- **Shown whenever the title is**, from its first visible frame, after a cold boot and after a
  death, and gone when the game starts. It is static: no animation, no flash
- **Graded as a rendering, with tools already in place.** The expected picture is the Game
  Boy's title background as `title_oracle.renderRows`'s renderer draws it (`gb/ppu.zig`, which
  draws no objects, so the falling star is not in it), extended from rows 16-17 to the full
  144 lines, with `super.png` composited at the placement. The `title` rung compares the
  cart's framebuffer against it over "Super"'s rectangle plus one tile of margin, the way it
  already grades the copyright rows, on a frame where the Game Boy's palette is not flashing.
  Outside that rectangle, the existing checks stand
- **The expected rendering is also written out as PNGs** (1× and 4×) through `png.zig`, so
  James can judge the placement by eye before the FXPak playtest. **Amended 2026-09-25:** not
  the cart's captured frame beside it, since Mesen's Lua `io` is sandboxed in test-runner mode;
  the cart side is the rung's pixel comparison, then Mesen by hand and the FXPak
- **B14 is undisturbed.** If "Super" is drawn with sprites, B14's sprite-set comparison excludes
  exactly its declared objects and no others; the menu, the cursor and the clear behave and
  grade as before, and no menu sprite is dropped for OAM or per-line limits
- Shown failing on the current cart first (B10's standing rule), and the `snes boot` fault
  sweep gains a fault that removes or moves it, caught by the new check

**Out of Scope:**
- Any other change to the title: the logo, the stars, the palette flash and the falling star
  stay as B14 left them
- "Super" anywhere but the title (the game over screen, the credits)

## Explicitly deferred, with the reason

Recorded so that "not done" reads as a decision rather than an oversight.

- **SameBoy reconciliation** — grading our GB emulator's RAM against the accuracy benchmark.
  Deferred out of Step 15b with its cost measured: SameBoy's tester takes no input stream and
  dumps no RAM, so it means patching the vendored C emulator and putting that build in the gate.
  The argument *for* it grew on 2026-09-03 and it is still deferred. B11's third bound is a
  second instance of the thing this would fix: our Game Boy emulator stops being a recorded
  run after a few thousand frames, on every movie tried and under every frame source and
  offset. **B11 routes around it rather than fixing it**, which is the right trade for one
  cycle and is not a fix. If Phase 1 wants whole-game grading against anything but the two
  published runs, this is what stands in the way.
- **The 25 unmatched-world duration stretches — no longer deferred, measured 2026-09-03.**
  The deferral was conditional: out of scope *unless a room in the slice's own region is on
  the list*. `zig build oracle -- durations all` reports 60 stretches of which 25 never
  matched the world, and **every one of them is in banks `$F`, `$A`, `$C` or `$B` on the
  published run's own route** — the whole list is inside the region. So all 25 are in scope
  by B1, and this is a larger B1/B12 load than this document assumed when it was written.
- **Audio (F8)** — Phase 0c entirely. B8's earthquake criterion is satisfied by a silent stub, so
  this cycle has no audio dependency. **Amended 2026-09-05.** The GB-APU→SPC700 shim cycle
  finished on 2026-09-04 with a GO-WITH-CAVEATS
  (`.local/docs/2026-09-01-gb-apu-spc700-shim/04-verdict.md`): two pulse channels reproduce the
  model exactly, they sound right on an FXPak, ARAM is not the constraint, and CPU is — 57.0% on
  the gameplay track `surface` against a 50% budget, with three unpulled levers behind it. That
  cycle deliberately changed nothing in `m2snes` and did **not** decide whether Phase 0c takes
  the shim or the TAD transcription F8 originally chose. **So this cycle still has no audio
  dependency, and gains one obligation instead: nothing it writes may prejudge that decision.**
  Concretely, the `SONG` opcode stub records the original's song id and nothing more — no driver
  call, no track table, no ARAM layout — so either Phase 0c path can be wired to it later.
  **Amended 2026-09-20: the decision is made, in Phase 0c, not here.** Phase 0c
  (`.local/docs/2026-09-16-metroid2-audio/`) took the shim. Bank 4 runs on the SPC700, graded
  exact against the Game Boy, at 18.7% on `surface` with all four channels and SFX allowed for.
  The port's F8 is amended to match. The stub's obligation is kept and has paid off: 0c turns
  the recorded ids (`!Song`, `!SongInt`, `!Sfx1`, `!SfxNoise`, …) into its requests unchanged, so
  0b's assertions on them stand. Audio bugs found in play go in `docs/bug_tracker.md` as part of
  this cycle's sweep.
- **The five unreached bank-4 dispatch sites** — in scope by B4, not separately, measured
  2026-09-03. All five share the `$46DE` indexer with three sites a run *did* enter, and the
  observed siblings read `($CEC0)`, an entity field, which puts the family in the enemy layer.
  Which of the five the slice's enemies use is a measurement the enemy work takes; it is not a
  question that can be answered before an enemy runs, so no separate task is created.

## Constraints & Dependencies

- **Everything in the Phase 0a requirements' Constraints section still applies**, unchanged,
  except the licence item below.
- **M2RoS licensing — amended 2026-09-02.** The Phase 0a requirements said M2RoS shipped no
  LICENSE file and listed the licence as an outstanding external dependency. **It is MIT** (James,
  2026-08-24); that dependency is closed and the Phase 0a document has been corrected.
  **Re-derivation is retained anyway**, as engineering discipline rather than as a licensing
  obligation: a re-derivation is checkable against the ROM and a transcription is not, which is
  the reason that was always independent of the licence. M2RoS material may be used with
  attribution, the MIT notice retained. This does **not** change the ROM-data rule — a
  disassembly still carries data derived from the copyrighted ROM, so `src/policy.zig`'s
  tracked-file policy and the bring-your-own-ROM model stand unchanged.
- **The oracle is the authority.** Divergence from the Game Boy is a defect until proven to be a
  deliberate design change. Facts about the ROM are derived from the ROM.
- **No presentation divergence.** F7's play window, camera deadzone and scrolling-guide constants
  are ported unchanged. Retuning them desyncs the oracle. **One exception, added 2026-09-25:**
  B15's "Super" on the title, which is graded against its own source image and changes no
  timing, state or other pixel.
- **The engine image is committed**; asar runs at dev time only. Any change to `engine/main.asm`
  requires `zig build engine` and lands with `engine.bin` and `engine.sym`.
- **Mesen2 gains a second role — added 2026-09-03.** It already drives the SNES cart's
  headless checks; B11 makes it the *reference emulator for the Game Boy side of the
  recording* as well. It stays resolved by `mise.toml` as `$MESEN`, and the same contract
  every emulator-dependent rung uses applies: absent means the rung reports that it did not
  run, not that it passed.
- **Phase 0b and Phase 0c are independent** and may run in either order or in parallel.
- **Sizing.** The Phase 0a requirements estimate 6–8 weeks. That estimate predates the dispatch
  survey's 49% and is not re-derived here. The plan cycle tests it against the actual routine
  backlog, and B4 is where it is most likely to be wrong.
