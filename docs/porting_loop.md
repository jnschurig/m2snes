# The porting loop

How a turn of work is chosen, done, and closed. The loop's premise is that **the port's own
measurement names the next thing to port** — nobody decides a work queue up front, because the
reachable-frame count already knows where the port stops and the trace already knows what the
original was doing there.

Phase 0a used this to grow the reachable count from 1 to 372 frames, one pose handler at a time.
It was written down on 2026-09-01, after that pass had already met its stop condition, because
every increment until then had been recorded after the fact and a fresh session had nothing
telling it what to do next.

The loop has **two arms**. Arm one ports a pose handler: one routine, one dispatch pair, a
handful of variables. Arm two ports a mechanism: several routines that only mean anything
together. Phase 0a only needed the first. The count's first non-pose stop — reference frame 375, which is
movie frame 703, the frame the original's map bank goes `$0F` to `$0A` and Samus is re-placed in
another room — is a room transition, and that is what arm two was written for.

## The standing rule, which governs both arms

**Every defect found by hand gets a failing fixture before it is fixed, and the fixture is shown
failing against the unfixed engine.**

Not after. The order is the whole point: a fixture written against already-fixed code proves the
code passes it, not that it catches the defect. The morph-ball bug (`bug_tracker.md`, fixed
2026-09-02) is the precedent in both directions — it reached hardware because position and camera
alone called it a match, and it is now guarded because the branch, removed again, makes the gate
report "Samus was in a different pose" at 583-593.

This rule is stated here rather than in the verification step because it can only be obeyed
forward. An audit at the end of the cycle can measure compliance; it cannot create it.

## Arm one: a pose handler

1. **Ask where the port stops.** `zig build oracle -- movie 900`. Since 2026-09-05 the frame it
   reports is **exact**: the CLI and the gate both bisect the exit code's bucket (`oracle.Bisect`),
   at a cost of about three extra emulator runs, and the verdict reads `at frame N exactly`. If it
   instead reads `at frame N-M` with `the pin was abandoned`, a truncated run diverged on a
   different quantity than the full run did and the range is the honest answer; treat both ends as
   suspect rather than picking one. `bucket` as an argument reproduces the old bucket-edge number
   for comparison.

   The old workaround — copy `build-out/oracle.lua`, replace the position `emu.stop(CODE_POS + ...)`
   with `emu.stop(20 + (i % 200))`, and re-run Mesen2 by hand — is gone. Do not reach for it.

2. **Read the trace at that frame.** Reference frame *r* is movie frame *r* + 328 — the rung's
   origin is the game's handover of control, pushed past the room change that straddles it, so
   check it against the rung's own printed anchor rather than carrying 328 around as a constant.
   `extracted/tas/any-vblank0-trace.tsv` at that movie frame usually names the component outright
   in the pose column. `zig build oracle -- movie` also names it
   directly when the stop is an unhandled pose — the exit code carries the pose number instead of
   a frame count.

3. **Disassemble it and port it branch for branch**, in the original's order, with the address of
   each branch in the comment: `zig build disasm -- <bank> <start> <end>`. **Do not skip a branch
   because it cannot fire yet.** Two of the three defects Phase 0a's last step cost came from
   exactly that: the crouch lost its jump at 00:$1671 and was 120 frames short for a day, and
   `$D062`/`$D049`/`$D010` were nearly left unmodelled under three branches that would then have
   silently done nothing.

4. **A new pose needs two dispatches, not one:** `HandlePose` and `SamusSpriteId` are separate
   tables in the original (00:$0D4B and 01:$4C1D).

5. **Add a `ledger.zig` row for each routine.** If `zig build verify` says the address "is no
   longer an instruction boundary", the observed run never dispatches it — drop the row and fold
   its note into the caller's, rather than weakening the check.

6. **Update `residue.zig` for any new variable**, re-run `zig build test` and `zig build verify`,
   and add a row to the turn log below with the before and after count.

**Stop condition:** one pass of arm one is done when the count stops on something that is not a
pose handler. Phase 0a's pass met that on 2026-09-01.

## Arm two: a mechanism

A mechanism is not a bigger routine. It is a set of routines that share state, where porting any
one of them alone produces something that either does nothing or — worse — passes a rung on stale
state. The arm exists to keep that from happening.

1. **Name the mechanism by the state that changed, not by a routine.** Read the trace at the
   stopping frame and at the frames either side. A pose stop names a pose. A mechanism stop is
   what is left over: the pose column is unchanged, or returns to what it was, and something else
   in the row moves — the map bank, the screen, the camera's seat, an entity slot. That moving
   column is the mechanism's name, and it is the thing the closing evidence will be about.

1a. **If the stop is a duration rather than a divergence, `zig build trace -- at F` is the
   instrument.** `stretch N` traces the thirteen anchors the anchored sweep picked;
   `duration.zig` anchors somewhere else entirely — the latest frame before a room change,
   searched backwards — and its rows print that anchor. Hand the anchor to `at` and the two
   compose. It was added on 2026-09-07 because two duration rows had gone unexplained since
   2026-09-01 for want of any way to look at them.

2. **Find its entry points, plural.** `zig build dispatch` for the table that reaches it. When
   nothing dispatches it and the code has to be caught in the act, `zig build probe` watches the
   game read the data — that is how the door script region was found. The answer you want is a
   *set* of addresses. If you have one address you have probably found a leaf.

3. **Bound it before disassembling.** List every routine the set calls and every variable it
   touches, and check the variables against `residue.zig`. Ones already modelled are a boundary
   you are allowed to stop at; ones that are not are the actual work. A mechanism without a stated
   boundary expands until it is the whole game.

4. **Disassemble the set together.** `zig build disasm -- <bank> <start> <end> <entry...>` takes
   extra entry points, which is what stops a multi-routine mechanism from being decoded as data
   wherever the instruction follow does not reach.

5. **Port in the order the original writes the state, not the order it reads it.** Trigger first,
   then the bookkeeping the trigger sets, then the readers that consume it. For a room transition
   that is: the door script's `WARP`, then the map bank and the screen, then the camera's re-seat.
   A reader ported before its writer runs against whatever was already in RAM, and a rung that
   passes on stale state is a silent pass — the most expensive failure this project has.

6. **Arm one's step 3 applies unchanged:** branch for branch, in the original's order, addresses
   in the comments, and no branch skipped because the slice cannot reach it.

## What a turn produces

A turn of either arm is closed when all of these exist. They are listed as artefacts rather than
as activities so a half-finished turn is visible:

- **`ledger.zig` rows**, one per routine ported, subject to arm one's step 5.
- **`residue.zig` entries**, one per new variable. A mechanism usually adds several; the residue
  audit at the handover is what says whether the port's RAM and the original's agree at the point
  grading starts, so a missing entry makes the grading itself less trustworthy.
- **At least one rung or fixture that fails when the mechanism is removed.** This is the load-
  bearing one. "The count went up" is not evidence: the count can advance for a reason adjacent to
  the work. Take the mechanism back out, run the gate, and see it stop — then put it back. For
  paths no movie reaches, that fixture is a `room.zig` scenario rather than a rung.
- **An entry updated in `feature_tracker.md`**, with the date.
- **A turn log row below**, with the before and after reachable count and the exact frames.
- **A `bug_tracker.md` entry** for anything found by hand, with its failing fixture written first,
  per the standing rule above.

**Stop condition for arm two:** one pass is done when the count stops on something outside the
mechanism's own subsystem. Per mechanism, the way arm one's is per pose.

## What the arm's first user added to it

B1 was arm two's first real use, on 2026-09-07, and it found a hole in step 5's warning. The
warning says a reader ported before its writer runs against stale state, and that a rung passing
on stale state is the most expensive failure here. The mirror image is just as expensive and is
easier to miss:

**A rung can be passing because the port does not have the mechanism at all.** The reachable
count read 375 partly because the port stood still for the 94 frames the original spends inside a
transition — the original because it is busy, the port because it had nothing to do. Adding the
trigger, correctly, on exactly the frame the original triggers on, took the count *backwards* to
281. Nothing regressed; a coincidence ended.

So arm two gains a step, between 5 and 6:

**5a. Before porting the trigger, ask what the port is doing during the frames the mechanism
owns.** If the answer is "nothing, and the original is also visibly doing nothing", the count
across those frames is not evidence and will be lost the moment the mechanism arrives. Say so in
the turn log *before* the number moves, so the drop reads as a measurement and not as a
regression.

### And what the second turn added

Landing the duration took four defects, and **not one of them was visible in the model.** The
model agreed with the Game Boy on 160 of 160 scripts, opcode for opcode, while the port was still
a frame out on every crossing. The frames were being lost at the seams the model does not have:

- the interpreter's entry wait shares a frame with the first opcode, because the original enters
  the interpreter *inside* the trigger's own pass and blocks there;
- one Game Boy opcode had become two converted ones, and the pacer charged two dispatch frames
  for a transfer the Game Boy paid once for;
- the frame a script ends on still belongs to the interpreter, because the original runs the whole
  script inside one pass of its main loop;
- and a cart booted with its sprite guides at zero fires the two triggers that test for a *small*
  guide, on its first frame, wherever the camera happens to be.

So arm two gains a second step, after 6:

**6a. Grade the mechanism's duration against the machine playing itself, not only against the
routine run in isolation.** A per-unit model can be exactly right and the mechanism still be a
frame out, because the seams — entry, exit, and anything the conversion split or merged — are
where the frames go and they are not units. The cheapest instrument for this is the movie: watch
the state the mechanism owns across a real crossing and assert the frame each step lands on.
`src/transition.zig`'s "the movie's own crossing" test is the shape.

### And what the third turn added

B1b's two defects were both in the buffer the port draws into, and neither was in the mechanism
being ported. The first was in the *fixture* — a boot record that reconstructs one screen where
the original has a window on the world — and the second was a variable the mechanism writes and
nothing reads. So arm two gains a third step, after 6a:

**6b. Ask what reads the state the mechanism writes, and check that something does.** `TILETABLE`
wrote `!TileTable` correctly, on the right frame, with the right operand, and the base the
streamer actually reads was derived somewhere else and never again. `residue.zig`'s reader lists
are where this is visible: the row said one reader, `LoadScreen`, and `LoadScreen` runs at boot.
A mechanism whose output has exactly one reader in a routine that runs once is a mechanism whose
output is not read.

And the artefact list's load-bearing item earns its place again, in a way worth naming: **write
the fixture before you believe the mechanism works, not after.** `WarpDraw` was ported, the gate
was green, and every rung was unmoved when the draws were stubbed back out — measured, on
2026-09-07: reachable 420, durations 28/28, anchored 665, with `.column` and `.row` returning
immediately. The fixture written next found a defect on its first run.

**And when a rung stops on the exact frame the mechanism acts on, suspect one frame before
suspecting the mechanism.** The reachable rung stopped at 375 with the trigger disarmed and again
at 375 with it armed, for two entirely different reasons; the second time the port was doing the
whole thing correctly and one frame late. `zig build trace -- stretch N` is what tells those
apart, and it is worth reaching for before re-reading the ROM.

### And what the fourth turn added

B2 is not arm two -- it is a *path*, not a mechanism -- but it found the same
class of thing arm two's steps are about, twice, and both are worth writing
down.

**A second source for a fact you already have is worth more than a second check
on the one you have.** `offsets.zig` had eight collision tables, each with a
note explaining how its address was derived from the door scripts, and eight
tests over them. All of it agreed with itself and all of it was one slot out.
What found it was not a better check: it was `initial_save`, a completely
different part of the ROM stating the same fact for one tileset. The port now
has three independent statements of the landing site -- the trace's frame 6, the
record, and `screens.assign`'s answer for the cell -- and they agree, which is
worth more than any one of them being checked harder.

So arm two gains a step, before 1:

**0. Ask what else in the ROM knows this.** Before deriving a fact from the
structure you are already reading, look for a place the game states it outright.
The map data, the save record, the initial save, a door script's operand and a
routine's immediate are five different authors, and where two of them overlap
the overlap is free evidence.

**And a baked expectation must not be baked from the thing it is grading.** The
cold-boot rung compares the title screen's 4096 characters against the
cartridge. The first version took those bytes by walking the same four-entry
list the injector walks, so reversing the list changed the cart and the
expectation together and the sweep passed. Taking the run by *address* fixed it,
and the fix was found only because the sweep was run at all. Which is arm two's
artefact list restated in the sharpest possible form: **the fixture is not done
when it passes; it is done when you have watched it fail.**

### And what the fifth turn added

B6 is arm two again, and it found a new way for the arm's step 0 to pay off — and a new way for
a fixture to earn its place.

**Step 0's "ask what else in the ROM knows this" applies to *constants*, not only to addresses.**
Six equipment masks sat in `engine/main.asm`, transcribed from M2RoS's `itemBit_*` names, read by
nine branches, and graded by nothing — because `!Items` is zero for the whole of Phase 0a, so
every one of those branches took its empty-handed path on every frame of every rung. Two of the
six were the wrong bit. What found it was not a better reading of the constants file: it was that
`handleItemPickup`'s own arms are `ld a,[samusItems] / set n,a / ld [samusItems],a`, so **the ROM
states the assignment in an opcode** and `items.bitFor` reads `n` out of it. A second
transcription of the same names could not have caught a slip in the first.

So arm two's step 0 gains a sentence:

**0a. A constant transcribed from a disassembly is a number someone typed until something in the
cartridge is made to say it.** Export it and compare. `ConstSprKnockL` and its three neighbours
went the same way in the same turn, for the same reason, and cost four lines that assemble to
nothing.

**And a fixture for a branch must show the branch is *gated*, not that it fires.** The bomb jump
fires when `itemBit_bomb` is set; a fixture that only watched it fire would also pass on an engine
that ignored `!Items` entirely. So the fixture runs twice — bit cleared, where the ball must keep
rolling, then bit set, where it must jump — and the negative half is the half with the evidence
in it. Two levers were needed to make the negative half honest, and both were found by measuring
rather than by reasoning: the pose is re-forced only when she is *not* already in a ball pose,
because `poseFunc_morphBall` off the ground writes $08 and returns without moving her, so
overwriting the pose every frame hung her in the air; and `!DownSpeed` is cleared every frame,
because a landing at two pixels a frame bounces into the same pose without the item and would have
made the negative half read as a pass.

### And what the sixth turn added

B5's projectile half and the enemy draw that followed it are the first work in this repository
whose defects were **outside everything the gate looks at**, and the two are the same shape.

`!SprX` and `samus_onscreenXPos` were one variable, correctly, for exactly as long as Samus was
the only thing this engine drew. `ClearUnusedOam` belonged inside her draw for exactly as long.
And the enemies had no picture for two whole steps while their slots were filled, walked,
collided against and damaged -- because **every grading path here compares state, not the
screen**: `reachable`, `anchored`, `oracle` and `durations` read position, camera and pose, and
`snes boot`'s pixel comparison is the play window with objects masked out. The one check that
looks at OAM graded Samus alone.

So arm two gains a step, after 6b:

**6c. When a mechanism puts a second thing on the screen, ask what was true only because there
was one.** Not "what does this write" -- 6b already asks that -- but which *existing* facts were
propositions about a screen with one object on it. Three of them here: an alias between a sprite
byte and a position byte, the placement of the routine that hides unused slots, and every
assertion the gate makes about `!OamIdx`, `!SpriteId`, `!SprX` and `!SprY`. All three were
correct when written and none of them said what they depended on.

**A second round of the same thing, the same day.** Making the enemies visible produced three
more symptoms a person could see and no rung could: sprites losing parts, Samus losing hers, and
shots that stopped landing. Both causes were older than the step that revealed them -- an `ORA`
into a table nothing clears, from Phase 0a, and a per-frame clear standing in for a routine that
had not been ported, from Step 10. Neither was *introduced* by drawing enemies. Both were
**latent behind the same missing thing**: with one object on the screen and one writer of the
collision record, each was a correct-looking line whose precondition had never been written down.
That is the shape 6c is about, and it is worth knowing that the step which triggers it will
usually not be the step that caused it.

**And the thing a person saw before any rung did is worth recording as a class**, because the
answer is not "write more rungs". The gate is built on an emulator that compares the *background*
to a reference render, and objects are masked out of that comparison on purpose -- the Game Boy
and the SNES do not agree pixel for pixel there. What closed the gap was two assertions about
OAM's *contents* rather than its pixels: an object lands where the slot says the enemy is, and a
slot the frame did not use is parked. Neither needs a reference image, and both would have caught
this on the day the entity foundation landed.

### And what the seventh turn added

B4c's first half is the first step here whose whole reason was a **state a recorder was holding**,
and the lesson is about the recorder rather than about the port.

`!EnUnhandledState`, `!EnUnhandledAi`, `!Unhandled`, `!PrUnhandled`, `!EnChild`: five variables
whose job is to turn "this cart has no arm for that" into a number the gate can print instead of a
jump through a Game Boy address. They are the right mechanism and they earned their place twice.
But a recorder says *that* a state was reached, and it says nothing about what the state leaves
behind while it is unhandled. Here the kill path set `+$0E explosionFlag` and nothing ran it, so
the slot's status never changed -- and an enemy whose status says *active* is still drawn, still
walked, and still a projectile target. The corpse deleted every beam that touched it. Nothing was
wrong with the recorder; what was missing was the question.

So arm two gains a step, after 6c:

**6d. When a test is ported and its handler is deferred, ask what the unhandled state owns.** Not
"can this state be entered" -- the recorder answers that, and the answer here was "not yet, and
then suddenly yes, from a routine three steps later". Ask instead: if the byte is set and nothing
clears it, which *other* routines keep treating this object as live? A deferral is safe only when
the state is inert, and a state that owns a slot's lifetime is not inert.

**And a second lesson, about substitutions rather than about ports.** Where a Game Boy register has
no counterpart here, the port substitutes -- and a substitution is judged at the *call site*, not
in general. `rDIV` is a free-running counter and `!FrameCount` is a free-running counter, so
swapping one for the other reads as an obviously accurate adaptation, and it was approved as one.
It collapses: this call happens inside a pass that acts on one frame parity, so `!FrameCount & 1`
is a constant for as long as Samus is in the room, and every corpse in that room would have rolled
identically. Measured on the cart 2026-09-12 over 1000 frames rather than argued from the listing.
The fix was to read the counter the *neighbouring routine* already divides, which is the general
shape of the answer: prefer a quantity the original itself reads at that point in the code, and
then check that it still varies where the substitution needs it to. There is now a rung for that
last clause.

## Turn log

The reachable count, and what moved it. Rows where the port did not change are kept deliberately:
two of the three entries so far are measurement changes, which is the whole reason B9 exists.

| date | what changed | reachable | anchored |
|---|---|---:|---:|
| through 2026-09-01 | Phase 0a's pose arm, one handler at a time, graded on bucket edges | 1 → 372 | — |
| 2026-09-02 | `pose` became a third graded quantity, forcing `codes_per_quantity` 80 → 60. **The port did not change.** | 372 → 375 | 394 → 390 |
| 2026-09-05 | bucket edges replaced by bisection to the exact frame. **The port did not change**; the anchored sum had been discarding eight frames across nine stretch edges. | 375 → 375, now exact | 390 → 394 |
| 2026-09-05 | B12: the tileset assignment learned to follow a door that names no table. **The port did not change**; two stretches that could not be booted into now can, so the anchored sweep offers 6848 frames where it offered 5174 and the durations rung compares 17 stretches where it compared 15. | 375 | 394 of more |
| 2026-09-07 | B1a: the transition's state. `RunDoorScript`, `WARP`, `StartTransition` and the four triggers, the triggers disarmed. Reachable is unmoved **and that is the finding** — armed, it reads 281, because the port fires on the right frame and then finishes in one frame what the original takes 94 to do. Anchored moves for an unrelated and real fix: `SeedPlacement` loads the cell's scroll flags at boot, which nothing did, and stretch 6 goes 19 → 70. | 375 | 394 → 445 |
| 2026-09-07 | B1a2: the transition's duration. The frame cost becomes arithmetic — a frame per opcode, `ceil(len/64)` per VRAM transfer, 39 for the fade — graded against the Game Boy on 160 of 160 scripts, and the trigger is armed. The port now walks *through* the door frame for frame. Durations also moves, 17/13 → 19/17: two of the run's leftward "scrolls" are transitions whose script has no `WARP`, and the port spends the Game Boy's 21 frames on them where it used to spend 1. | 375 → 420 | 445 → 462 |
| 2026-09-07 | B1b: the transition's picture. `WarpDraw` draws the incoming edge — three strips right, left and up, four down — where Step 5b only paid for it, and `TILETABLE` reaches the same dispatch. Two defects fell out: a boot record seeded one screen into all 1024 tilemap slots (`SeedWindow`), and `TILETABLE` selected a metatile table nothing re-read (`LoadMetaBase`). The second is why the count moves this far: the room past the run's first door was being *walked* in the tileset the cart booted with. Offered window raised 900 → 2000, because 899 of 899 is not a measurement. | 420 → 899 of 899, then **1396** | 462 → 665 |
| 2026-09-08 | B2: the title screen and the cold boot. The cart the builder ships starts where the *game* starts -- `initial_save` and the four instructions ending `loadGame_samusData`, not a cell we searched for -- shows the title, and plays. **The count does not move and could not**: nothing here is on the any% run's path, which begins at a handover 326 frames after the game hands over control. | 1396 | 665 |
| 2026-09-08 | B4a: the entity foundation. Sixteen slots, the per-screen spawn walk on both axes, the camera carry and the three-state despawn window; the spawn records and the enemy headers become a converted `enemies` region. **The count does not move and this time the reason is a measured fact rather than a judgement**: the segment runs on map 0 cell $38, whose spawn list is empty, and the plan's `$0F`/`$76` names a different room. Even where the reference does load an enemy -- the segment rolls into cell $37, which has two -- the rung compares position, camera and pose, and a port whose enemies neither move nor draw touches none of the three. The rung that *would* move is B4b's. | 1396 | 665 |
| 2026-09-09 | B6: items and pickups. `enAI_itemOrb`, `handleItemPickup`'s fifteen arms and `handleItemPickup_end`'s two wait loops, the blocking turned inside out into `!ItemStage`. **Reachable, anchored and the segment are all unmoved and that is the correct outcome**: neither published run collects anything, and the recording's four pickups are 44 000 frames past the horizon. What moved instead is the gate — `snes boot` grew two phases, and the second of them takes **the first `!Items` branch anything on this cart has ever taken**. Two defects fell out. The `!ITEM_BOMB` and `!ITEM_SPRING` masks had been the wrong bit since Phase 0a and no rung could see it, because a mask that is never set is never read; and `!ITEM_BOMB` was then shadowed by an item-*number* define of the same name, which the new fixture caught on its first run by reporting `!Items` as $05. | 1396 | 665 |
| 2026-09-09 | B4b: the AI, the hitbox test and the damage. `enemy_commonAI`'s dispatch as an address table, three AI arms, all four collision entries, `hurtSamus`, `applyDamage` and poses $0F-$12. **The segment moves, 644 to 700**, and its last 56 frames are the first this repository has graded with enemies live on both machines. Reachable and anchored are unmoved and that is the correct outcome: neither published run is hit inside its horizon. Three defects fell out and each was a rung's find, not a reading's -- the enemy pass running at 60 Hz where the original runs it at 30, an NMI enabled inside vblank costing every walk step its parity, and `SpawnListAt` subtracting 9 from an index that was already 0-based, which meant the cart had never loaded an enemy at all. | 1396 | 665 |
| 2026-09-09 | B5's terrain half: the destructible blocks, ported before anything can fire at one. The classification at 01:$5155, the sixteen-slot array, the counter's six dispatches, the two eviction bands and `destroyBlock`'s four tilemap writes. **Nothing moves and nothing could**: no projectile exists, so nothing on this cart reaches the classification, and neither published run's horizon contains a destroyed block. The evidence is the fixture and it was watched failing twice -- once with `HandleRespawningBlocks` out of `MainLoop`, once with a block constant changed. One defect fell out and it was the second fixture that found it, not the first: the reform's recording ran an 8-bit immediate in 16-bit A and the main loop never came back, which every assertion in the first phase passed straight over because NMI kept the cart looking alive. | 1396 | 665 |
| 2026-09-09 | B5's projectile half: `samus_tryShooting`, `samusShoot`'s five arms, the three slots, `handleProjectiles`' five branches and both copies of the terrain classification, `drawProjectiles`, the projectile-enemy hitbox test and `enemy_getDamagedOrGiveDrop`. **Nothing moves, and this time the reason is a rule rather than an accident**: the port has a key for `B` and the movie is not being handed it, deliberately -- that is the second commit, and it is separated so a floor that moves there is a measurement of the key and not of the port. The evidence is `snes boot`'s two new phases, and they are the first in this gate whose lever is *the pad*. One defect fell out and it is a class: `!SprX` and `samus_onscreenXPos` were one variable, correctly, for exactly as long as Samus was the only thing this engine drew. | 1396 | 665 |
| 2026-09-09 | `B` added to `oracle.supported_input_bits`, **and nothing else changed**. The port has read the bit since the commit before this one; this is the movie being handed it. Reachable moves 1396 to 1466 and the stop goes back to being a position divergence -- the 28 frames between the old ceiling at 1368 and the old stop at 1396 were frames the cart was given a different pad than the run pressed, which the floor's own note had been warning about since Step 6. Anchored and durations are unmoved: every anchored stretch diverges on its first frame, so a beam cannot reach them. The movie's ceiling is not gone, it has moved again -- to reference frame 3411, where the run opens the map, and the bit is `$04`. | 1396 -> **1466** | 665 |
| 2026-09-09 | **The enemies become visible**, which was a bug report and not a measurement: James played the cart and found enemies that move, hurt and die with nothing on the screen. `drawEnemies` (01:$5A11) and `drawEnemySprite` (01:$5A3F) were never written, and under them the enemy metasprite set had been extracted and round-tripped since Step 4 without ever being shipped into the cart. A second defect fell out of fixing it: `ClearUnusedOam` ran from inside `DrawSamus`, so every object appended after her -- projectiles since 12b, enemies now -- landed in slots no later frame would hide. **No rung moves and none could**: every one of them grades position, camera, pose or the background. | 1466 | 665 |
| 2026-09-09 | The glitches the draw exposed, reported by James playing it: sprites losing parts, Samus losing hers once enemies were on screen, and shots that no longer landed. Two defects, both **older than the step that revealed them**. `PutObject` ORed its pair into OAM's high table and nothing has ever cleared that table, so a slot that had once held a part wrapped past column 0 was stuck 256 pixels left for the rest of the cart's life -- a Phase 0a bug. And the four collision bytes were cleared once a frame rather than by the enemy that claims them, a Step 10 stand-in for `enemy_getDamagedOrGiveDrop` citing an address that is not an instruction boundary; with the real routine ported it ate every hit that fell on one of the pass's idle frames. | 1466 | 665 |
| 2026-09-12 | B4c's first half: the explosion, the drop, and the slot that frees itself. `enemy_animateExplosion` with `.becomeDrop` and `enemy_animateDrop` -- two of the four state arms `enemy_commonAI` had been recording rather than running, moved ahead of the bombs because the gap was not inert: a corpse kept its *active* status, so it went on deleting every beam that touched it and the first kill in a room left an invisible beam-trap. It also reached `enemy_getDamagedOrGiveDrop`'s drop arm, ported in Step 12b and unreachable until something could put a `+$0D` in a slot. **Nothing moves and nothing could**: neither published run kills anything inside its horizon, and the segment's 700 frames contain no kill either. The evidence is two new `snes boot` phases and four injected faults. One decision was reversed by reading the call site and then measured on the cart: the approved `rDIV` stand-in, `!FrameCount`'s low bit, is a constant on every frame the enemy pass acts -- so the roll reads `!EnFrame` instead, and there is a rung that fails if *that* counter stops alternating. One blind spot fell out of an older rung: the first beam on this cart ever to leave the play window dies **in the draw**, so `!SprX` holds it with the array already empty, and `checkSprite`'s alias half read that as Samus drawn in the wrong place. | 1466 | 665 |
| 2026-09-30 | 1.0 Step 18c2: **two slow pins taken, in `zig build verify-full`**, so a lenient rule cannot drift unwatched. The seeding fixture passes on one catch, and pins which anchors catch (10327, 10390, 10832, 11567) and the 168 frames its seeded stretches play (`oracle.seeding_catches`, `seeding_frames_floor`). The recording's worlds pin the 354 visits of 953 the walked reading does not explain, one line each (`src/worlds_misses.txt`); a new miss fails and is named. A per-band crawl was tried under the new pin and reverted: it explained 482, not 599. **Nothing moves**; later rows here lower or raise these pins. | 1999 | 665 |
| 2026-09-30 | 1.0 Step 18d: **the recording's worlds pin lowered, 354 → 312.** A walked lava room's table is read at the visit's count (`warp.LavaReplay`, 18c's walks replayed as scripts), and the walked reading explains 641 of 953 visits where it explained 599. The 42 lines removed are visits the run reported "raise the pin" on; none was added. With the replay off, the run fails naming the 42. The seeding pins do not move. | 1999 | 665 |
| 2026-10-04 | Release Step 0: **the recording's worlds pin lowered, 312 → 290, with 8 accepted losses (James).** The crawl cached in `build-out/` predated the committed crawler (1058 doors; the committed one walks 1185), and every pin since 18c was set on it. On the cold crawl, `warp.walkedArrivals`' rule (any two arrivals differ: the static reading) unsettled 137 cells, and 388 visits missed. The rule now takes the first arrival in the crawl's order and leaves a room to the static reading only when arrivals at two counts differ. 30 lines removed (the run reported them explained). 8 added, each a late-count visit the static reading drew right and the first arrival at $47 does not: `B 99 12`, `B 9A 12`, `B 9B 14`, `B 9C 14`, `A 66 21`, `A 77 14`, `C 19 26`, `D 11 09`. The shipped carts are byte-identical on either crawl. | 1999 | 665 |
