# Bug Tracker

A list of bugs that have been found. Unresolved bugs are added with an empty `[ ]` marker. Upon fixing the bug, it gets checked off with `[x]`.

The bug description should describe the issue, the expected behavior, and any relevant steps to replicate the bug if the issue is not descriptive enough.

If a bug is left unchecked, but is unable to be reproduced, it can be surfaced for manual testing to confirm. A human can mark the bug as resolved.

Optionally, the date of the fix can be added. Example:

```
- [x] (2026-08-31) the bug description...
```

## Bug list

- [ ] (found 2026-10-04 by `warp.test`, release Step 0, on a cold crawl; **accepted as is**
  by James, debug menu only; unconfirmed on hardware) **The debug menu's warps to Metroid
  `$A:$36` and item `$A:$37` may draw the room with the wrong background.** Expected: the room
  as a player walking in sees it. Walking in is not affected: in play the cart runs the
  game's own door scripts. Only the warp table's chain decides what a warp loads.
  - **What the crawl says**: both entries use the seeded chain `$07F, $09D`, which leaves
    background 8:$69BC, solidity $5C. A cold crawl walks `$09D` into the room from truth, from
    `$B:$F8`, and that arrival leaves 7:$5800. `walkedChain` drops it because no single
    script reproduces `$B:$F8`'s truth state, and a warp entry holds two scripts
    (`max_chain = 2`). It is the class of the Metroid 01 rock bug below (same loader `$07F`,
    same 8:$69BC).
  - **Why it is unconfirmed**: 7:$5800 is `caveFirst`, the new game's graphics. The crawl's
    "truth" walks doors at the new game's count without the items a player needs, so through
    doors that load no tileset it can carry `caveFirst` where no player goes. The recording
    does not settle it either: its visits at `$A:$36`/`$A:$37` (counts $22/$23) are already
    pinned misses in `src/worlds_misses.txt`.
  - **How it hid**: the crawl cached in `build-out/` predated the committed crawler (see
    `docs/conformance.md`, release Step 0), and that crawl never reached `$B:$F8` from truth.
    The cart is byte-identical on either crawl.
  - **To check on hardware** (debug cart): warp to Metroid `$A:$36` and look at the rock,
    then walk into the same room through its door. If the two differ, this is the bug.
  - Guarded by: `warp.test` "an entry into a room the Game Boy walked into from truth leaves
    what truth left", which lists these two entries as known (this bug) and fails on any
    other.

- [x] (found by James 2026-10-02 on hardware, 1.0 Step 27's playthrough; **priority
  1 of 4**; **fixed 2026-10-03, 1.0 Step 27a**, hardware re-check open) **Killed Metroids respawn, and the Metroid count runs ahead of the kills.** Expected:
  the explosion, a dead record that stays dead, control back once it ends, and the counts down
  by one per Metroid.
  - `D:04`: exploded, came straight back, and Samus froze. The debug menu showed it alive,
    though the count had gone down. Warped away and back, she could move; the second kill
    stayed dead and the count went down again.
  - `A:17` (the open Metroid 01 entry, below): a longer death animation than normal, then it
    came back. The count went down and Samus kept control. The one that came back could not
    be killed, so she ran away.
  - `A:F8` and `B:04`: as `A:17`. Each one that came back could not be killed.
  - Consequence: the count ran ahead, so the Omega at `B:8D` spawned early, and the Alpha
    normally at `B:8D` or `B:8C` on the first visit was missing.
  - **Two causes, both the port's, and either alone gives the symptoms.** In both, the dying
    Metroid's slot stops being an explosion before its fourth blast. `EnemyCommonAI` then
    hands it to its own AI, which draws it again with health $00 (so the next missile wraps it
    to $FF, and it is unkillable) and publishes its flag as alive. The count had already gone
    down at `.death`.
    1. **`EarthquakeCheck` left X on its threshold index** (08:$7EBC walks in HL; the port
       walked in X). Every species' `.death` calls it with X on its slot, so the rest of that
       pass ran on slots misaligned by up to 12 bytes. `SlotFlagOut` wrote a spawn flag nobody
       owned, and, where the misaligned status read $FF, wrote $FF over the next slot's +$09.
       In `$D:$04` that is the Alpha's explosion counter: the first blast drew $E2+$FF = $E1,
       not an explosion frame. Which kills it hit depends on the count and on what the other
       slots hold, which is why most kills were fine.
    2. **A crossing ended the fight that the original carries on.** `ResetEntities` cleared
       `metroid_state`, `metroid_fightActive` and `cutsceneActive`, which only 02:$412F (a
       load's) clears; 02:$418C and $4217 do not. A door taken within five seconds of a kill
       stopped the post-death wait (02:$4039) where it stood, and the next kill resumed it from
       there. Reaching $90 mid-explosion cleared `metroid_state`. The original has a narrower
       form of this (a next fight begun within the wait), which is kept.
  - **Fixed**: `EarthquakeCheck` keeps X (`phx`/`plx`); the three clears moved to
    `InitEntities` and `DoorEscapeQueen` (02:$412F's two callers); `DebugWarp` ends an
    explosion it leaves mid-way, as the fourth blast would, since a crossing never can.
  - Guarded by: the `warp` rung's `missile_kill` scenario (A #$40 killed from the menu and left
    260 frames into its wait, then D #$46 shot dead through the pad), which failed 50 on the
    engine before the fix and fails 50 under each fault (`ResetEntities_offscr`,
    `EarthquakeCheck_out`). The enemy rung's kill cases hand over a contact record and never
    left a room mid-wait, which is why they passed.
  - **James's save is not repaired by the fix.** Its flags and counts are what the bug left; the
    debug menu's METROIDS page can set them right, or the playthrough restarts.

- [x] (found by James 2026-10-02 on hardware, 1.0 Step 27's playthrough; **priority
  2 of 4**; **fixed 2026-10-03, 1.0 Step 27b**, confirmed by James on hardware the same day) **Spike damage on entering `F:C3` without touching spikes.** Expected: no damage.
  Repro: land on the ledge by the door on `C:3C`, jump so the transition scrolls partly off
  screen, come back, and go through the transition into `F:C3`. Walking back and forth
  through the transition alone does not do it.
  - **Cause: the crossing frame's hurt was kept.** On the frame she walks off `C:3C`'s left
    edge, one of `SampleTile`'s probes sits at `TileX` $07, which wraps to tilemap column 31,
    row 19: id $53, block type $6C, the spike bit. The spike arm sets `samus_hurtFlag`, the
    door's 46 frames run, and the hurt lands on the first frame of play in `F:C3`, on the
    door ledge. The original sets the same flag from the same read, but `loadDoorIndex`
    clears it at 00:$0C4F when the door starts. `StartTransition` listed that clear as "nothing
    yet for it to write to", and spikes arrived in 1.0 Step 25 without anyone going back to it.
  - **On the cart in Mesen the jump is not needed:** a stand, then a walk left off the ledge,
    is hurt the same way, with the same tilemap at the hurt. Why James's walks did not do it
    on hardware is not known; the fix does not depend on the route.
  - **Fixed**: `StartTransition` clears `!HurtFlag` (00:$0C4F), ahead of the save contact.
  - Guarded by: the `beams` rung's `door spike` segment (James's route: stand on the ledge,
    a standing jump, then left through door $B9's `WARP $F, $C4`), graded against our Game
    Boy frame for frame up to the warp and on its settled last frame (`oracle.Door`), her
    health included. It failed on the engine before the fix (the settled frame's camera, 16
    pixels low after the knockback, over health 91 for 99), and fails the same under the
    fault `StartTransition_hurt`.

- [x] (found by James 2026-10-02 on hardware, 1.0 Step 27's playthrough; **priority
  3 of 4**; **accepted 2026-10-03, 1.0 Step 27c**: the original's, an F12 enhancement) **No item banner for the Spring Ball after Arachnus.** Expected: the pickup's name
  in the banner below the HUD, as for the other items.
  - **The original does the same (1.0 Step 27c, 2026-10-03).** Both of the Game Boy's window
    raises for a pickup test the item number against $0B: 00:$3A1B and 01:$5820 are
    `LD A,[$D093] / CP $0B / JR NC` ahead of `LD A,$80 / LDH [rWY],A` (read from the ROM's
    bytes). The Spring Ball is item $0B: the orb's AI counts sprite $95 down to $81 in twos
    from 1 (`enAI_itemOrb`, 02:$4DD3). So it is the one major item whose jingle runs with the window down. No
    door script carries `ITEM $B` either, so a raised window would show the last name written.
    The port has both bounds (`!ITEMNO_MAJOR_END`, `ItemJingleFrame`).
  - **Accepted as the original's for 1.0 (James, 2026-10-03)**, and recorded as an enhancement
    for later: `feature_tracker.md`, F12.

- [x] (found by James 2026-10-02 on hardware, 1.0 Step 27's playthrough; **priority
  4 of 4**; **accepted 2026-10-03, 1.0 Step 27d**: the original's) **Walking through the coral on `9:E3` hurts for one tick only.** Expected: damage
  on the regular ticks for as long as she is in it. Jumping through it does hurt on regular
  ticks.
  - James, 2026-10-03: true of every coral area. Standing and walking in it does no damage;
    off the floor in it she is hurt on the regular ticks.
  - **The original does the same (1.0 Step 27d, 2026-10-03).** The coral is acid (block bit
    4). The ROM tests it in the top, bottom and spider probes only (00:$1EC5, $1EFA, $1F63,
    $1FA3, $1FCC, $1FE4), never the horizontal one. Standing and running call the top probe
    only on a jump press (00:$13B7, $14D6), and the bottom probe reads the floor under her,
    which is not acid. Graded against our Game Boy on `9:E3`'s step, both agree frame for
    frame with her health: walked through, nothing; jumped through, four ticks (99 to 91).
    Guarded by the `beams` rung's `coral walk` and `coral jump` (fault: `AcidProbe` never
    hurting).
  - Re-measured on Mesen2's Game Boy core, which we did not build, after James reported the
    original hurting on the floor: the 100% recording's part 4 to frame 1930 in `B:CA`, then
    right into the coral pit and stand. The fall through the coral ticks once (150 to 146,
    `$D062` = $40); walking along the pit floor in it and 270 frames standing in it take
    nothing. The coral is acid and non-solid over a solid floor there, read from that core.
  - **Accepted as the original's for 1.0 (James, 2026-10-03)**: the original's coral behaves
    differently in different places, and the cart does what it does.

- [x] (found 2026-10-02 by the gate, 1.0 Step 22; **fixed 2026-10-02**, the same step) **A
  scenario that passed could exit 2.** `refill_credits` printed its pass and then failed 2.
  The scripts end in `emu.stop(0)` and return, and under the gate's load Mesen2 ran a frame more
  before stopping; the runner (`warp_grade.writeRunner`) resumed the finished coroutine, which
  errors, and failed the run with 2. Expected: a finished script is left alone. It is the
  likeliest cause of Steps 15 and 16's exits 2 that passed alone and on the rerun. Not shown
  failing on demand: whether the extra frame runs depends on the machine's load, and a
  fixture that cannot fail on demand is not one. The fix is the runner's
  `coroutine.status(co) == "dead"` test.

- [x] (found 2026-10-01 by reading, 1.0 Step 20d; **shown and fixed 2026-10-02, 1.0 Step 25**)
  **Dying in the Queen's room may leave her bands and feet running over the GAME OVER screen.**
  `gameMode_dead` clears `queen_roomFlag` at 00:$36BB, before its LCD-off copies. The port's
  `GameOverScreen` turns her channels off (`QueenOff`, Step 19c) but does not clear
  `!RoomMode`. `QueenPass` runs on every pass of the main loop and `QueenNmi` on every normal
  vblank, both while `!RoomMode` is $11. So once the GAME OVER screen is up and NMI is back
  on its ordinary path, they would build her bands again and draw her feet's cells into BG3.
  Expected: the GAME OVER screen as after any death. Found while porting `EXIT_QUEEN`, which
  clears the same flag; no gate case dies in her room past its window, so nothing has shown
  it. To do (Step 25): a fixture first, the `still` case run on to the GAME OVER screen,
  then 00:$36BB ported.
  - **Shown**: our Game Boy's `still` run is in mode $07, the GAME OVER screen, from 791 to
    1046 after her kill on 614. The cart without the clear differs from it on 900 (49).
  - **Fixed**: `GameOverQueenFlag` clears `!RoomMode` at the top of `GameOverScreen`, as
    00:$36BB does, before `QueenOff`.
  - Guarded by: the `queen` rung's `still` case, which now runs on past the death and
    compares the play window on 900 (`queen_oracle.cases`); `GameOverQueenFlag` taken out
    fails it with 49.

- [x] (found 2026-10-01 by the gate, 1.0 Step 19c; **fixed 2026-10-01**, the same step) **The
  `warp` rung read the map over the view before the stream had written it.** Two entries
  failed on an engine whose only change for them was a few cycles more a frame: `24 C:13`
  read slot $014 as $18 where our Game Boy's is $1A, and `44 D:D6` read $34 for $FF. A
  `QueenNmi` refactor with no change of logic was enough to fail them, and HEAD's engine
  passed. Expected: a grade that holds the map once it is drawn. The warp draws the camera's
  cell, and a row or column of the neighbouring one comes from the map stream, one direction
  a frame, round-robin on the frame counter. The grade read the view on the frame it decided
  she had arrived, which is the frame counter's first move after the warp, and on these two
  that was before the stream's turn. The reference is every cell drawn whole.
  - **Fix**: the view is read four frames after the arrival, once every direction has had a
    frame, or earlier if a door's index is set. The arrival's own checks (loaded state, the
    damage, the characters, her pose) stay on the arrival frame. A rule that the stream owes
    nothing did not work, because a camera still settling keeps a direction owed.
  - Guarded by: the 161 warps against the 19c engine, run alone and in the gate. Both entries
    failed before the fix, in the gate and alone at the live count. The rung's chain-cut fault
    and `LoadMetaBase` fault still fail it.
- [x] (found 2026-10-01 by the Queen oracle's volley, 1.0 Step 19c; **fixed 2026-10-01**, the
  same step) **The Queen's fight slowed down while a missile was in flight during her lunge.**
  Expected: the Game Boy's pace, which drops no frame there. The cart's main loop overran
  four passes running (frames 245-248 of the volley), and three more at 329-331 and seven
  from 515: the fight ran four frames behind the Game Boy's from the first. Her room's pass
  is about 180 lines idle, a missile's tests against her thirteen slots add about 25, and a
  lunge took passes to 238-248.
  - **Fix**: `PutObject`'s high-table pair and attribute byte from tables, and
    `LoadEnemyBox`'s hitbox pointer as one word. Busiest pass 234 lines, ending on line 209.
    **The margin is 16 lines**, and the cart is SlowROM (2.68 MHz). A heavier moment (her
    spit and a lunge with a missile out) may still overrun. C11's playthrough is the check,
    and FastROM is the lever.
  - Guarded by: the `queen` rung's volley, with the pad keyed to vblanks on both machines.
    It parted at frame 269 (a missile spent four frames early) before the fix and does not
    after.
- [x] (found 2026-10-01 by the Queen oracle, 1.0 Step 19a; **fixed 2026-10-01**, the same step)
  **`queen_headDest` ended each head frame at $C0, where the Game Boy's holds $60.** Expected:
  the low byte of the row the second half starts on, stored once, when the first half hands it
  to the next vblank (03:$7058). The port (Step 6's `QueenDrawHead`) stored the destination
  after every row, so the second half moved it on to $C0. Nothing was drawn wrong, because a
  new frame starts from $9C00, but the byte was not the Game Boy's.
  - **Fix**: the destination is `!QnDest` while drawing, as the Game Boy keeps it in L, and
    `!QueenHeadDest` and the source are stored only on the `.else` arm.
  - Guarded by: the Queen oracle, which parted on `queen_headDest` at frame 1 before the fix
    and does not after. In the gate once 19b turns the oracle green.
- [x] (found 2026-10-01 by the `saves` rung, 1.0 Step 18e; **fixed 2026-10-01**, the same step)
  **The station at `$A:$99`, warped to, had no pad to save on.** Expected: caveFirst's station
  pad at metatile row 8, column 11, as the 100% recording's Game Boy draws the room when the
  player saves there (part 21, frame 7350, at count $09, and again at $01). The cart drew the
  room under lavaCavesEmpty, and she stood where the pad is with no contact (exit 50).
  - **Cause**: the warp table. Since Step 14's fix the entry took the crawl's truth arrival
    from `$A:$79` (doors `$186`, `$1E1`), and that chain draws the lava table at every count.
    The player comes in from `$C:$C7` through `$0E1`, or from `$F:$FC` through `$17F`. Both
    doors keep the caveFirst of the room before.
  - **Fix** (`src/warp.zig`): a station's chain must draw its pad when some walked door does
    (`walkedChain`'s `pad`). `$A:$99` takes `$055, $0DB`, which leaves the recording's saved
    `$D808`-`$D814` in all but the enemy page, and the recording's spot, `$096C,$09B0`.
  - Guarded by: `warp.test` "every station's warp stands her on its pad", which holds the entry
    to the recorded block, and the `saves` rung, whose `$A:$99` run failed 50.

- [x] (found 2026-10-01 by the `saves` rung, 1.0 Step 18e; **fixed 2026-10-01**, the same step)
  **The station at `$E:$54`, warped to, put her beside the pad.** Expected: standing on the
  pad. She stood one column right and 24 px lower, on the floor beside it, with no contact
  (exit 50).
  - **Cause**: a station's standing spot was the one nearest the middle of the pad's upper
    metatile, and `nearest` measures a spot from `y + 10`, so the floor beside it came out
    nearer than the pad.
  - **Fix** (`warp.pointOf`): the point is her feet on the pad's top, at its middle. The other
    stations' spots do not move.
  - Guarded by: the same test, and the `saves` rung's `$E:$54` run.

- [x] (found 2026-09-30 by the `doors` rung, 1.0 Step 18a; **fixed 2026-09-30**, 1.0 Step 18b)
  **A new game started with door `$D6`'s solidity, not the save's.** Expected: `$64 $64 $64` at
  `$D812`-`$D814`, the ROM's `initial_save` (01:$4E64), which is what our Game Boy holds after
  a new game. The cart holds `$69 $69 $69`, read out of `!SaveBuf+$12` once play begins. The
  rest of the block agrees.
  - **Cause**: the new game is booted, not loaded. `BootGraphics` replays the boot record's
    door script, and for the new game that is `screens.assign`'s choice for the ship's cell,
    door `$D6` (the way back in from `$A:$44`), which loads `$69`. The Game Boy's new game
    is a load: `createNewSave` (01:$4E1C) copies `initial_save` into the save buffer, and
    game mode $02 (`gameMode_LoadA`, 00:$03F0) takes the tables and the solidity from it.
    The engine's own comment at `LoadSaveFile` says as much, and then takes the door script.
  - Seen by: five of the 22 `doors` runs, each on its first entry, a script with no
    `SOLIDITY` of its own run straight after the new game (doors $001, $027, $0E3, $17B,
    $18F; exit 21). No other rung reads the new game's solidity before a door writes it.
  - **Fix**: boot record version 17 carries `initialSaveFile` (`BootSave`). A new game copies
    it into `!SaveBuf` in `LoadSaveFile`, as `createNewSave` does, and takes the load's path:
    `LoadGameState`, then `LoadGameGraphics`, whose item font now waits on `!LoadingFromFile`
    (00:$063E). A handover's boot still replays its door script.
  - Guarded by: the `doors` rung, whose five runs failed 21 on the unfixed engine and pass.
  - Not measured: whether the start rooms draw a tile in $64-$68, where the two thresholds
    decide differently, so no playtest ask.

- [x] (found by James 2026-09-29 on hardware, 1.0 Step 14's playtest; fixed the same day)
  **Metroid 01's room (`$A:$17`), warped to, drew the wrong rock.** Expected: the lava caves'
  tall rock, as the 100% recording shows the room (kill 27, part 12). The cart drew round
  rock and hollow boxes along the floor, with solidity $5C where the Game Boy has $42.
  - **Cause**: the warp table (1.0 Step 5a), not the room. The crawl had walked door $09A
    into the room from truth, and the recording's `$D808`-`$D814` there is that arrival's.
    But `loaderFor` took no script that tests the Metroid count, and the lava caves' rooms
    are loaded only by such scripts. So the truth arrival had no chain, and a seeded guess
    won (`$07F, $09A`, background 8:$69BC). Our Game Boy ran the same guess, so the warp
    rung agreed with it.
  - **Fix** (`src/warp.zig`): a count-gated loader is taken when no ungated one loads the
    state, run at the live count as the cart runs it; and a truth arrival over a crossing
    that runs no script takes a loader into the same map bank, or the room before's own
    chain. Thirteen entries now come from truth: Metroid 01 (`$05F, $09A`), its room
    before, `$B:$F1`, the station at `$A:$99`, and ten items (`$A:$16`, and nine in bank D
    that were inferred).
  - Guarded by: `warp.test` "an entry into a room the Game Boy walked into from truth leaves
    what truth left", which failed on six entries before the fix. It covers only rooms with
    a truth arrival; the 78 seeded and 14 inferred entries are Step 18's.

- [x] (found by James 2026-09-29 on hardware, 1.0 Step 14's playtest; **fixed 2026-10-03, 1.0
  Step 27a**) **Metroid 01, warped to and killed, came straight back and Samus lost control.** Warped
  away and back, the second kill stayed dead and play went on. Expected: the explosion, a
  dead record, and control back once it ends.
  - **Not reproduced.** Warped in through the menu's own input and killed on the cart twice,
    with the enemy rung's lever and with Samus's own missiles, on the room as it was and as
    fixed above: each time the explosion's freeze (02:$574B) is released on its fourth blast
    (02:$5781), the record's flag is $02 in the save array, and control comes back. The
    room was in the wrong loaded state at the time (solidity $5C/$5D, not $42), which lets
    her and the Alpha through rock the Game Boy's do not pass. Open for James's re-test on
    the fixed room: the weapon, and where each of them was, if it happens again.
  - **1.0 triage (2026-10-02, Step 25):** **Player-visible if real; open for James's re-test.**
    Step 27's hardware playthrough kills Metroid 01 and is the re-test.
  - **Renumbered (2026-10-02, 1.0 Step 26):** Metroid 01 is the Alpha at `$A:$17`, spawn
    `$40`. The debug menu now numbers Metroids in playthrough order, and it is `26 A:17` on
    METROIDS and on WARP's METROID ROOMS.
  - **Reproduced (2026-10-02, 1.0 Step 27's playthrough):** on four Metroids, during the
    hand playthrough. Tracked by the priority-1 entry at the top, and closes with it.
  - **Explained (2026-10-03, 1.0 Step 27a)**: the priority-1 entry's two causes. Not reproduced
    in Step 14 because a warp-in kill at the new game's count leaves X on threshold $46's
    index, 1, where the misaligned slot does not read as empty.

- [x] (found and fixed 2026-09-29, 1.0 Step 13, by the warp rung's `spring_ball`) **The WARP
  entry for the Spring Ball (`$D:$C0`) arrived with no Arachnus.** Expected: the room's
  spawns, as walking in loads them. Nothing loaded, and #$70's flag stayed $FF.
  - **Cause**: `DebugWarp` swept the camera onto the spot a 16-pixel grid row at a time, so
    the loader walked each row once. The loader tells down from up by `scrollY` less its
    value two passes ago, unsigned (03:$40C5 `SUB (HL)` / `JR C`, ported as is). On the one
    step whose `scrollY` wrapped through $00 ($F8 to $08, camera $C50), it walked the top
    edge, and the bottom row it skipped, $CB0, was Arachnus's. The original moves a few
    pixels a pass and walks each row over several passes, so it never loses one.
  - **Fix**: the sweep steps half a row (`!WARP_STEP`, 8), so every row is walked twice and
    the wrap can take only one of them.
  - Guarded by: the warp rung's `spring_ball` scenario, which failed 44 ("no slot holds
    #112") on the unfixed engine and holds now. Any other entry whose records sit on its
    wrap row was losing them the same way.

- [x] (found 2026-09-29, 1.0 Step 12, by the enemy oracle; **accepted by James 2026-10-02**) **Settled at the centre
  of `$9:$7D`, the Game Boy's camera dips three pixels every 52 frames and the cart's does
  not.** This is the other way round from the 2026-09-13 entry: here the Game Boy moves. Repro:
  set the `proboscum` case's `samus_dx` to 0 and run `zig build oracle -- enemies proboscum
  raw`. The camera's Y byte is `$95` on both until frame 29. Then on the Game Boy it goes
  `$92` (29-34), `$93`, `$94`, back to `$95` at 38, and again from 81, 133, 185 and so on.
  The cart's holds at `$95`. Only slot 0 is live, and the proboscum does not move in that
  window, so it is not an enemy. Expected: the same camera on both.
  - Not diagnosed. The period does not match anything the proboscum does ($40 passes). It
    could be Samus's own idle state at that spot. `zig build trace` is the instrument.
  - **1.0 triage (2026-10-02, Step 25):** **Player-visible, small; James to decide** between
    diagnosing it now and accepting it: a three-pixel camera dip every 52 frames while
    standing still at one spot.
  - **Accepted by James, 2026-10-02** (1.0 Step 25), as a compromise.
  - Guarded by: nothing. The case stands her $18 to the left, where the two agree.
- [x] (reported 2026-09-29 by James, playtest of `73d8346`; **fixed 2026-10-01, 1.0 Step 18f**) **The
  warp to Metroid 11 (Gamma, `$B:$45`) leaves Samus in a morph-ball tunnel with no way out.**
  The warp table's row for it is `seeded` (its tileset read from a seeded room, not walked
  there) and its static reading `differs`: Samus at $04C4,$0548, `caveFirst`. Not settled
  whether the spot is wrong, the tileset is wrong, or the room needs an item the warp does
  not give. It is also how 1.0 Step 11's skreek and drivel playtest was routed (through the
  down edge of `$B:$44`), so that playtest is deferred with it. `roster -- ai`'s route counts
  door edges, which says nothing about whether the rooms between are walkable.
  - **Cause (1.0 Step 18f): the tileset.** The recording's Game Boy shows lavaCavesEmpty in
    the room at $24 (`set worlds`, `B 45 24 6`); the chain `$055`, `$1F0` drew caveFirst, in
    which the room is rock with pockets, and the spot nearest the Metroid was one of them. 24
    of the 153 warp cells the recording visits disagreed with it the same way.
  - **Fix:** the warp table holds every entry the recording visits to the recording's table at
    its count (`src/recorded_tables.txt`, `warp.heldToRecording`), run at the live count. A
    lava room keeps its lava (James, 2026-10-01): Metroid 11 is now `$04A`, `$1F0`, the
    area's lava door, lavaCavesMid at $47 and the recording's lavaCavesEmpty from $46, Samus
    at `$0474,$05B8`. And a spot must be in `warp.reach`, where a ball with every item gets
    to from the room's doors, destructible blocks cleared.
  - **Guarded by:** `warp.test` "every warp stands where a player gets to": every entry in
    reach, every visited one in the recording's table, and the old caveFirst spot out of reach
    (fails with the hold off at `$B:$E3`, with the reach off at `$B:$B4`). `set worlds` holds
    the reach to the recording's positions (pinned) and the tables file to the recording.
  - **Playtest (James, 2026-10-01, `6c94836`):** "It works perfectly." The skreek route he
    then tried, down through `$B:$44`'s floor, was the reach's error: no door comes out
    there (`a3996a9`).
- [ ] (found 2026-10-01, 1.0 Step 18f, not fixed) **The crawl's `through` does not know the
  respawning blocks.** Tiles $00-$03 are destructible whatever the collision table says
  (01:$2433, 01:$16FC), and `warp.reach` counts them cleared. `Grid.through`, which
  `spotsNear` uses to stand Samus by a door, still reads only the table's bits, so a door
  behind such a block is tried from fewer places. Changing it changes the crawl, and with it
  the whole warp table and the worlds pin, so it waits for a step that rewalks the crawl.
  - Guarded by: nothing yet.
  - **1.0 triage (2026-10-02, Step 25):** **Diagnostic only.** The crawl is the warp table's
    harness; a player standing by such a door is not affected.
- [x] (reported 2026-09-29 by James, playtest of `a61c34d`; **not a defect: the original does
  the same**) **A septogg carries Samus down through the sand, and she is stuck there.**
  - **The Game Boy does it too.** The sand is tiles $5A and $5B. `enemySolidityIndex` in that
    room is $54, and a tile at or above it is not solid to an enemy (`CP (HL)`, `RET C`). So
    the septogg's floor probe (02:$4AD6) passes through the sand to the rock beneath.
    `samusSolidityIndex` is $5C, so the sand is solid to Samus: she walks on it, but the
    septogg moves her by `hSamusYPixel` directly (02:$687E), with no collision. Measured on our
    Game Boy in `$B:$24`: she lands on the septogg, is carried from $026F to $02BA, $26 below
    the sand's surface, and neither a jump nor a walk either way moves her afterwards.
  - Guarded by: the `beams` rung's `septogg sand` (267 frames, the ride, the sinking and the
    trap, frame for frame against our Game Boy). Its fault takes the carry out and differs at
    frame 55.
- [x] (found 2026-09-29 by the `beams` rung's `septogg ride`, 1.0 Step 11; **settled 2026-09-30,
  1.0 Step 18c: the reference's, not the port's**) **The beams room's west neighbour disagrees at the seam.** The segment boots in bank
  9 cell $38. With Samus walked off the septogg's left edge at X $07FD, the Game Boy held her
  there for four frames of her fall and the cart let her drift on (frames 143-146). The Game
  Boy's BG map has a block, tiles $1A $1B over $1E $1F, in the last two columns of cell $37
  (world X $07F0-$07FF) at rows $0366-$036F. The cart's tilemap has $6C $6D over $FF $FF
  there, the rock of cell $38 continued. The columns right of the seam agree.
  - **Not yet settled which side is wrong.** The oracle's `World` check compares only the boot
    cell's tiles, so nothing graded cell $37. The Game Boy reference arrives by a `WARP`, which
    is not a room load, so its VRAM there may be left over from the room before. Or the cart's
    neighbour cell may draw with the wrong tiles.
  - The ride now walks off the septogg's right edge, inside cell $38. Step 18 grades every
    cell a door enters against the Game Boy's tilemap and settles this.
  - **Settled: the cart is right.** Both cells are drawn with table 9 (the walk says so too).
    `$9:$37`'s columns 30-31 at pixel rows $60-$6F convert to $6C $6D over $FF $FF, the cart's.
    The Game Boy's $1A $1B over $1E $1F are `$9:$38`'s own columns 30-31. The map is one cell
    wide, and `room.spawn` draws the boot cell whole from its origin, so a view across the seam
    shows the boot cell's far columns. The original draws around the camera and would have
    `$37`'s there. A limit of the reference boot: a segment must not look across its boot cell's
    seam.
- [x] (found 2026-09-28 by the `beams` rung's `hurt` segment, 1.0 Step 9; **fixed 2026-09-28**)
  **Walking into an enemy knocked Samus towards it, not away.** Expected: as on the Game Boy,
  where the knockback goes away from the enemy's centre. The segment walks her into an Autoad
  from the left; at frame 9 the Game Boy has her at 0835, the cart at 0837.
  - **Cause**: `samusSpriteCollisionProcessedFlag` is set in `.start` (00:$3650), which the
    standard entry (00:$32AB) and the horizontal one (00:$32CF) share. So once the walk's
    horizontal entry has run, the play handler's standard pass is skipped for the rest of the
    frame. The port set the flag in the standard entry only. After the walk's hit, the standard
    pass ran again, passed the Y test, and wrote the default boost, $01 (right), before its X
    test failed. The Game Boy keeps the hit's $FF.
  - Found by probing both machines at the hit: the same enemy box ($70-$91), the same Samus X
    ($6B on screen), and on the cart a second `CollideSlotLoop` after the hit.
  - Fixed: `CollideSamusEnemiesHoriz` sets `!SprCollDone`.
  - Guarded by: the `beams` rung's `hurt` segment (Samus, the camera, the pose and her health,
    frame for frame), which failed at frame 9 on the unfixed engine. Its fault
    `CollideSamusEnemiesHoriz_flag` stores zero instead and must differ.
  - Confirmed on the FXPak by James, 2026-09-28, on `af904c1`: walked into from its left, an
    enemy throws her left, away from it.
- [x] (found 2026-09-28 by the `gfx` rung, 1.0 Step 9; **fixed 2026-09-28**)
  **Varia's pickup ended a frame early; so would a refill's.** `handleItemPickup_end`'s first
  loop (00:$3A01) is a do-while: draw, wait, then test the countdown. The port tested first. A
  pickup that reaches the loop with the countdown already spent skipped its one pass: Varia,
  whose arm waits out the jingle itself, and the refills, which set no countdown.
  - **The measurement**: from the item's bit landing to the flag's $03, which the lever does not
    reach, Varia took 191 frames on the cart and 192 on the Game Boy (199 and 200 with
    everything). The other pickups agree at 352.
  - Fixed: a first-pass stage, `!ITEM_JINGLE1`, which draws without the test. The arm and the
    transfer's end both enter the loop through it.
  - Guarded by: the `gfx` rung's code 13 (from the bit to the flag, exactly), which failed on
    both Varia cases first. Its fault `RunItemPickup_jingle1` sends the first pass to the test.
- [x] (found 2026-09-28 reading `handleItemPickup_end`, 1.0 Step 9; **fixed 2026-09-28**)
  **The game clock lost a tick in most major pickups.** Both of `handleItemPickup_end`'s loops
  end in `waitForNextFrame` (00:$031C). That routine ticks `gameTimeSeconds` when the frame
  counter wraps, as the play handler's own wait does. The port's item frames never called
  `IgtTick`. A major item's jingle is 352 frames, so its window almost always holds a wrap.
  One tick is 256 frames, so the clock lost about four seconds per item, which decides the
  ending at a threshold. The pickup's other waits are `waitOneFrame`, which does not tick, and
  Varia's are all of that kind.
  - Fixed: `!ItemTick`, raised by every pass of either loop and spent by the next frame's
    `.itemFrame`, which ticks. The pass that ends the pickup is left to the play handler's own
    tick.
  - Guarded by: the `gfx` rung's code 14, the clock's ticks over the pickup against our Game
    Boy's. The cart's stores are made when its counter's low byte is the Game Boy's less one:
    the frame the two sample points put in step, measured on the bit's landing. On the unfixed
    engine the nine ordinary pickups read 0 ticks against 1. The Varia cases read 0 on both,
    because their wrap falls in the arm's own waits: the negative control. The fault
    `MainLoop_itemTick` never ticks.

- [x] (found 2026-09-28 by James on the FXPak, 1.0 Step 8c; **fixed 2026-09-28**)
  **The plasma beam sometimes stops at an enemy it kills, and sometimes flies on.** Expected:
  as on the Game Boy, where the same thing happens and for a reason. No beam pierces an enemy:
  each of the plasma's three shots, 8 px apart, is deleted by its own hit (00:$31F1 sets carry,
  01:$52E3 deletes). A dead enemy is no longer a target, so a shot that is not yet in the box
  when the enemy pass kills it flies on. How many stop is how many were in the box by then: the
  pixels between Samus and the enemy.
  - **Cause of the part that was ours**: `samusShoot`'s plasma loop (01:$4F93, $4FA5) adds $10
    on every slot but the first (`LD A,L / AND A / JR Z`). The port added it on the first only,
    following M2RoS's comment rather than the code. So the three came out in the other order,
    with the leading shot in slot 0. 01:$4F81 lets the plasma fire again once slot 0 is free,
    so on the cart the leading shot's hit freed the gun, and a new volley wrote over the two
    still flying.
  - Fixed: `beq` for `bne` in both arms.
  - Guarded by: the `beams` rung's `plasma` segment, which compares the projectile array frame
    for frame. It failed at frame 11 on the unfixed engine (the slots `58 50 48` against
    `48 50 58`), and its fault `SamusShoot_plasmaOrder` puts the old branch back and must
    differ. `plasma kill, all stop` and `plasma kill, one on` grade both outcomes against the
    Game Boy.
  - Confirmed on the FXPak by James, 2026-09-28, on `c3b5167`: the plasma behaves as it
    should.
- [x] (found 2026-09-28 by James playing `3db54e5` on the FXPak, 1.0 Step 8b; **fixed 2026-09-28**)
  **Frozen enemies are black or invisible, and so is the flash of a flashing item.** The ice
  beam otherwise works: the freeze, standing on a frozen enemy, the thaw and the death at it.
  Expected: the Game Boy draws a frozen enemy in OBP1 (`$43`, the light shades), because
  `drawEnemySprite_getInfo` XORs the stun counter into the attribute (01:$5A9A), and `$10` is
  the OBP1 bit.
  - **Cause, measured on the cart's CGRAM**: `LoadPalette` wrote OBP0 to colours $80-$83 and
    OBP1 straight after it, at $84-$87. An SNES object palette is sixteen colours, so the
    palette 1 that `PutObject` selects for bit 4 is $90-$9F, which held `0000` throughout. Every
    object the original draws in OBP1 came out black on the black play field: a frozen enemy, a
    stunned enemy's flash ($11-$13), and the blink of items and drops.
  - Fixed: OBP1 goes to $90.
  - Guarded by: `snes boot` code 15 now reads object palette 1 at $90 against the builder's
    OBP1. Shown failing (15) on the unfixed engine, passing with the fix.

- [ ] (found 2026-09-28, 1.0 Step 8b's first gate run; **one occurrence, not reproduced**) **The
  `warp` rung's `queen` scenario exited 2 with no line.** Exit 2 is the script's own `fail(2)`,
  the emulated frame limit or a Lua error, and both print a reason first. This run printed
  nothing, and Mesen's wall-clock timeout would have been 255. The same cart and script passed:
  - alone, three times (`zig build queen -- scenario`, with the gate's switch);
  - in the gate's next full run, which was green.

  That run had five more `enemy AIs` cases in parallel than before, so load is the suspect, but
  nothing measured says how a load could produce a code of 2. Expected: the same cart and script
  give the same verdict.
  - Guarded by: nothing that fails on its own; a flaky gate is caught by running it twice. If it
    comes back, log the child's stderr, which `scenarioRuns` ignores.
  - **1.0 triage (2026-10-02, Step 25):** **Diagnostic only.** A gate flake; no cart differs.

- [x] (found 2026-09-28 porting 1.0 Step 8a's pickup arms; **fixed 2026-09-28**)
  **Collecting Varia left Samus in the appearance's pose.** `ItemPickupArm`'s Varia arm wrote
  `!POSE_FACESCREEN` ($13), the pose a new game opens on, which holds her facing the screen until
  a button is pressed. The ROM writes $80 (00:$38E8): standing, turned to the screen by the
  turnaround, with `samus_turnAnimTimer` $10 (00:$38F0), after which she stands. On a cart she
  would have stood facing the screen after the Varia jingle until the pad was touched.
  - **Fixture:** the `gfx` rung grades her pose against our Game Boy's after each pickup (code
    11). With the arm's operand back at $13 (the rung's fault `ItemPickupArm_varia`) the `varia`
    case reads `pose 13, the Game Boy's 00`, exit 11; at $80 it agrees.
  - Varia's fanfare wait, the frame between the pose and the sound, and the transformation are
    still missing, and are 1.0 Step 9's.

- [x] (found 2026-09-22 by James playing the cart on the FXPak Pro, metroid2-audio Step 18; **fixed 2026-09-22**)
  **A new game plays no room song.** Walking around the starting area on hardware, the surface
  theme never comes up: the effects play, the engine is alive, and nothing asks for music.
  Expected: the caves theme ($04), as the Game Boy plays from the first room.
  - **Measured on the cart** (`tools/fxpak.sh read`): `!Song` ($7E00C4) is `$FF`, the whole save
    buffer around `!SB_SONG` ($7E0418-$0420) is `$FF`, and the reply's `songPlaying` is `$00`
    through three 10-second windows of play. Square 1 shows `$07` (a beam shot) in the same
    windows, so requests reach the engine; there is simply no song request to make.
  - **Cause, and it is a stale decision rather than a regression.** The Game Boy asks for the
    room's song at 00:$0EAF when what is playing is not it, reading `currentRoomSong` ($D092) --
    `$04` for a new game, from `initialSaveFile`. `engine/main.asm`'s `PoseFaceScreen` leaves
    that site out on purpose, and says why: "which audio driver Phase 0c lands on is an open
    decision (F8), and a stub that assumed one is the expensive thing to unpick later". Phase 0c
    has now landed, and nothing went back to the site.
  - **Two things are missing, not one.** The request site 00:$0EAF, and a value for it to read:
    `!Song` is defined as a recording of what a door script's `$Cx` opcode asked for, `$FF`
    meaning none has run, so it is *correct* as it stands and is not the Game Boy's
    `currentRoomSong`. A new game needs `$04` seeded from `initialSaveFile` and a handover needs
    what its reference measured -- the shape boot record versions 11, 12 and 13 already use.
    `BootSong` is a different field: what to play once at a handover, zero for a new game.
  - **Why nothing caught it.** `audioparity` grades handover stretches, where `BootSong` requests
    the song directly and the room-song path is never taken; the new-game boot is not a graded
    stretch. The site's ledger entry (00:$0EB9, `zig build audiosites`) is *waived* as "reads
    `songPlaying`, the driver's, to decide: Step 16b's read-back" -- which justifies the read and
    not the missing request, so the waiver is wrong and should fail once the site is claimed.
  - **Confirmed on hardware, and it is worse after a Metroid dies** (James, 2026-09-22, playing
    `stretch00.sfc`, which boots with `BootSong $04` so the surface theme *is* playing): killing
    the first Alpha silenced the music for the rest of play, leaving "sound effects randomly
    played here and there instead of music". The restore path is the arithmetic
    (`engine/main.asm`, `.restoreMusic`, 02:$4051):

        lda.w !Song              ; $FF on this cart
        adc.b #!SONG_RESTORE     ; + $11
        sta.w !MetSong           ; $FF + $11 = $10, eight bits
        %audio_put(!REQ_SONG, $024056)

    The Game Boy computes `$04 + $11 = $15` (main caves, no intro). The cart computes `$10`,
    whose table entry is `initializeAudio.ret` -- code, not a song header -- so nothing plays and
    nothing ever asks again. `songPlaying` read `$10` in every window after the kill.
  - **This also explains the "one unmatched id".** `$10` is the single id `audiocmp` has never
    matched, and `docs/audio_ids.md` lists it as outside the slice. It is not: the slice reaches
    it every time a Metroid dies, *because* of this bug. Seeding `!Song` makes the restore ask
    for `$15`, and `$10` stops being reachable. The doc's claim should be corrected with the fix.
  - **Not the engine's.** Every id including $04 is exact under `audiocmp`, and $04 renders
    correctly in the offline A/B (`song-04.snes.wav`). The engine plays what it is asked for;
    it is being asked for silence, and then for a song that is not one.
  - **Fixed 2026-09-22, in two halves, because two things were missing.** Boot record
    **version 14** carries `BootRoomSong` -- `initialSaveFile`'s `$04` for a new game
    (`save.initial`'s `room_song`), the Game Boy's measured `$D092` for a handover
    (`oracle.gbLoadout`) -- and `InitState` seeds `!Song` from it where it used to write `$FF`.
    And 00:$0EAF is ported in `PoseFaceScreen`: if `songPlaying` is not `!Song`, request
    `!Song`. That site runs every frame of the appearance's wait and the reply is two passes
    behind, so it reads its own request while the reply cannot show it yet -- the model Step 16b
    gave the low-health beep. Without that the song would be requested three frames running.
  - **Guarded by `zig build audioboot`'s `room` run**, which is the only thing that covers this
    site: `audioparity` grades handover stretches, and a handover has no appearance sequence.
    It presses Start at the title in Mesen2 (where save RAM is blank, so a new game is what
    begins), runs past the 320-frame countdown, and requires `!Song` seeded `$04`, `$04`
    requested, and the reply reporting `$04` playing -- which it does from pass 324. Reverting
    the seed alone makes it read `!Song $FF, requested $FF, playing $00` and fail, so it is not
    vacuous. The ledger enforces the request too: 00:$0EB9's waiver is gone and the site now
    reads `sent`, 119 of 203.
  - **A save written before the fix still carries the old byte.** `!Song` is a save-file value,
    so a slot saved while it was `$FF` restores `$FF` and the bug with it -- confirmed on the
    cart, where a save made post-Alpha-kill loaded with `SaveBuf+SB_SONG` `$FF` and no music.
    The port's title only implements Start, not the clear-file option, so on hardware such a
    slot cannot be got past; clear save RAM to test a new game. Nothing migrates it, and for a
    dev cart nothing should.

- [x] (found 2026-09-22 by `zig build audioparity`, metroid2-audio Step 16b; **fixed**)
  **A handover cart boots the sound silent.** A stretch's cart boots the engine through
  `silenceAudio`, where the Game Boy at the anchor is playing a song ($04 at stretch 0, $0C at
  stretch 6). Expected: the cart plays what the Game Boy plays.
  - **What it changed.** `songPlaying` in the reply never matched, and at stretch 0's frame 132
    the footsteps ($10) played on the cart and not on the Game Boy, because footsteps give way
    to the song's noise channel (`test/audio/noise-footsteps.req`). It would also flip the
    Alpha's fight-song guard, which reads `songPlaying`.
  - **Fixed 2026-09-22 by boot record Version 13** (`BootSong`, measured off the Game Boy at
    the anchor by `oracle.gbLoadout`, zero for a new game), requested by `AudioBoot` after its
    `silenceAudio`. It needed bank 1: bank 0 had ~6 bytes, and the readout moved out to make
    room. The song starts from its top where the Game Boy's is part way in. Guarded by
    `audioparity`'s reply check: with `BootSong` ignored, stretch 0 fails at frame 132 again.

- [ ] (found 2026-09-22 by `zig build audioparity`, metroid2-audio Step 16a; **suspected, unmeasured**)
  **A handover cart boots the Alpha fresh.** In the any% run's stretch 6 (anchor frame 4370) the
  Game Boy's missile hits the Alpha on the stretch's frame 27 (noise $05, `SFX_METROID_HURT`,
  02:$6D01), which frees the slot for the next shot at frame 28. The cart's missile does not hit.
  Expected: the cart's missile hits the Alpha on the same frame.
  - **Not an audio bug.** The hit's request site is ported and sent (`zig build audiosites`),
    and in manual play a missile hitting the Alpha sounds right (James, 2026-09-22). What
    differs is whether the hit happens.
  - **Suspected cause.** Samus's position agrees for all 273 frames, so the enemy is the
    suspect: the handover boots the Alpha fresh, not in the state the Game Boy had it at the
    anchor. The position oracle does not grade enemy state, so only the sound shows it.
  - **Held by a cap.** `audio_parity.caps` stops stretch 6's grade at frame 27, and
    `audioparity` fails if the stretch diverges earlier *or* agrees on frame 27, so fixing
    this makes the cap fail until it is removed.
  - **1.0 triage (2026-09-26, Step 1):** **Diagnostic only.** A handover artefact of the
    audio-parity harness, held by its cap; no player sees it. Revisit if a C10 recording stretch
    needs it.

- [x] (found 2026-09-22 by `zig build audioparity`, metroid2-audio Step 16a; **fixed**)
  **A handover cart boots with the beam selected when the Game Boy has missiles.** In the any%
  run's stretch 6 (anchor frame 4370) the Game Boy fires a missile on the stretch's frame 17 and
  asks for square 1's $08; the cart fires a beam and asks for $07. Expected: the cart shoots what
  the Game Boy shoots.
  - **Not a gameplay bug: a gap in the boot record.** `!ActiveWeapon` ($D04D), `!Beam` and
    `!Items` ($D045) are not record fields. `InitState` seeds the six loadout values Version 11
    added (health, missiles, tanks, Metroid counts) and nothing else, so a handover cart starts
    with `ActiveWeapon` zeroed (`residue.zig` says `.zeroed`, with no measurement) and no items.
    Only `LoadGameState` (a save file) and the pickups write them.
  - **Why the position oracle never saw it.** A shot does not move Samus; the anchored comparison
    grades position, camera and pose. The sound is the first thing graded that depends on the
    weapon.
  - **The fix**: record Version 12, adding the three bytes, measured off the Game Boy at the anchor
    as the loadout already is (`oracle.gbLoadout`), seeded by `InitState`, with the new game's
    values from `initialSaveFile`. Then `audioparity` should grade stretch 6 exactly.
  - **Fixed 2026-09-22 by boot record Version 12** (`BootItems`, `BootBeam`, `BootWeapon`;
    `InitState` seeds them, and a cart booted with missiles selected uploads the missile cannon
    under forced blank). Stretch 6 now agrees 27 of 273 frames, up from 17, frame 17's $08
    included. Guarded by `snes_inject`'s "the boot record carries the new game's loadout" and
    the direct-load test.
  - The weapon gap is closed, and this entry with it. Stretch 6 stops at frame 27 for another
    reason, logged below as its own entry.

- [x] (reported 2026-09-15 by James playing the cart; fixed 2026-09-25, Step 24c)
  **Samus's sprite holds one animation frame for the whole of a scrolling crossing.** On the
  Game Boy whatever she was doing carries on through it -- running, somersaulting -- on both
  horizontal and vertical scrolls. Expected: the animation continues; the crossing moves her, it
  does not pause her.
  - **Distinct from the `DrawSamus` defect Step 17 fixed**, and it outlives it: that one was
    *where* she is drawn and *whether* she is drawn at all, this is *which frame of the
    animation*. Phase 27 grades the first and says nothing about the second.
  - **The measurement, and it does not say what the variable's name says.** Watched over the
    any% run's vertical crossing at frames 1387-1420 with
    `zig build tas -- any 1430 1 watch:D022,D020`: `$D022` is **static at 45 through ordinary
    play** before the crossing, advances by **exactly 3 on every frame of it** -- 48, 51, 54 ...
    147 -- and is static at 147 after. `$D020`, the pose, is `$01` throughout. A run cycle would
    do the reverse: tick while she moves and stop while she does not. So `!AnimTimer`'s comment
    in `engine/main.asm` -- "samus_animationTimer: the run cycle, and nothing else" -- is not
    what the running game shows at that address.
  - **Why the port freezes regardless.** The only writers of `!AnimTimer` in the engine are
    inside pose handlers (`.heldLongEnough` and `.heldSixteen`), and `.transitionFrame` skips the
    pose machine -- correctly, that is what 00:$0522 does. Nothing else advances it, so whatever
    byte the sprite id is selected from does not move for the crossing's frames.
  - **The measurement this still needs**, before anything is ported: which byte actually selects
    the drawn sprite during a crossing. `$D022` moving is suggestive and is not that answer --
    read the tile index the Game Boy puts in OAM across 1387-1420 and find what it follows. Do
    not port from the variable's name.
  - **Diagnosed 2026-09-25: the crossing's camera advances both animation timers, and the
    port's advanced neither.** A search of the ROM for every instruction addressing `$D022`
    finds four read-add-3-writes at 00:$0B60, $0B94, $0BC7 and $0BFF, one in each arm of the
    transition camera, and that routine's first instruction (00:$0B44) is `INC` on `$D072`, the
    spin counter the ball, the spider and the spin jump draw from. The name was right after all:
    `$D022` *is* `samus_animationTimer`, read by `drawSamus_run` (01:$4D77), and the camera adds
    the same 3 a frame `poseFunc_running` does. In pose `$01` nothing draws from it, which is why
    the sprite at 1387-1420 did not move; the byte did because the camera moved it.
  - **The Game Boy's sprite does follow it.** Across the any% run's ball crossing, `$D072` holds
    through the script (609-707, the interpreter blocks), then goes $59, $5A ... one a frame
    from 708, and the ball's OAM tile turns at 712 and 716 with its bits 3-2. `$D022` goes
    $03, $06 ... over the same frames. `zig build tas -- any 720 1
    watch:D00E,D020,D022,D072,FE02` reproduces it.
  - Fixed: `TransitionCamera` increments `!SpinTimer` ahead of its direction test and adds 3 to
    `!AnimTimer` in each arm, where the original does.
  - Guarded by: **`snes boot` phase 27, code 159**, which requires on every frame of the scroll
    that the spin timer went up by 1 and the run cycle's by 3 (or clamped to zero at $30 in the
    run pose, as `drawSamus_run` writes back). Exits 159 on the pre-fix cart, 10 runs of 10.

- [x] (reported 2026-09-15 by James playing the cart; fixed 2026-09-24, Step 24b)
  **Every crossing flashes the screen black before the animation starts.** The delay is the door
  script's real length and matches the Game Boy; the blackness does not. On a *scrolling*
  crossing the original keeps showing the room it is standing in for the script's frames and then
  scrolls it out. Expected: the frozen room for those frames, then the scroll.
  - **Not a regression.** `RunPendingTransition` (00:$23AF's port) has written `INIDISP = $80`
    across the whole script since B1, and its own comment has called the blank "ours" the whole
    time: a converted `COPY` reaches VRAM by DMA and DMA is only safe under blank. The reasoning
    given was that the original goes black anyway, because `FADEOUT` opens nearly every door
    script. That is true of a fade script and false of a scrolling one.
  - **Attempted and reverted 2026-09-15**: narrowing the blank to wrap `DoCopy` alone, which is
    the only thing that needs it. The cart then fails `snes boot` **code 204, the HUD band**, in
    *phase 20* — long after the crossing, so the damage outlives it. Rewriting the `$2100` store
    with long addressing does not change it, which rules out the data bank. Reverted rather than
    trade a green gate for a red rung; the negative result is in the engine comment so it is not
    re-tried blind.
  - **Why that attempt failed (Step 24b).** `DoCopy` is not only the transition's: the boot
    record's script (`BootGraphics`) and a load (`LoadGameGraphics`) run it too, under their
    callers' forced blank with NMI off and *before* `LoadHud`. A `DoCopy` that lifts the blank
    turns the screen on for the rest of the boot, and every VRAM write after it is dropped: the
    HUD's characters among them, which phase 20 is the first to look at. Reproduced in kind
    (lifting it after the boot path's copy exits 12, no characters at all; the 2026-09-15 code
    is not in history). And narrowing it to a live crossing would still have shown: the
    interpreter runs from line 241, and `ITEM`'s six copies measured from line 8 to line 89 of
    the next frame.
  - **The fade question is settled by Step 20**, which gave `FADEOUT` its palette steps. A fade
    door is now dark by brightness, so it needs no blank either; both kinds lose it.
  - Fixed: `RunPendingTransition` writes no blank. On a live crossing (`!TransRun`) `DoCopy`
    queues the copy (`!XferQ`, six entries, `ITEM`'s count) and `DrainXfers` makes it in the next
    NMI, after OAM and before the tilemap. Measured in vblank for every copy of the three graded
    doors: lines 229-242, where vblank runs 225-261. The boot and a load still copy at once.
  - Guarded by: `snes boot` phase 28, which runs three doors that do not fade (the Bomb's, the
    Spider Ball's, and the first door that loads an enemy sheet, $001). On every script frame,
    **code 128** if the frame ends blanked or below full brightness, and **code 129** if a window
    row lit before the trigger has gone black: the band a mid-frame blank leaves, which the
    register at the frame's end cannot show. Code 128 shown on the pre-fix cart, 129 against a
    cart that blanks around each copy and lifts it straight after, and 138 when the queue lost its
    high bytes. And the `fade` rung now grades every frame of its take, 1999, not only the dimmed
    168: it fails on the pre-fix cart at movie 471-613 and passes on this one.

- [x] (found and fixed 2026-09-15, Step 15c) **The segment and spider segment carts booted with
  zero health.** `oracle.gradeWith` takes its record from `snes_screen.bootCandidates`, which never
  filled boot record version 11's loadout. Nothing read the health until Step 15c ported the play
  handler's death test (00:$04EC), and then both carts died on their first frame: the `oracle` rung
  diverged at frame 61 and `spider segment` at frame 1. Expected: the cart carries what the Game
  Boy it is graded against carries, and that machine is a new game (`room.bootIntoPlay`).
  - Fixed: `gradeWith` gives the record `Loadout.newGame`.
  - Guarded by: the two rungs themselves, which went red on the engine change and green on the fix.
    The fixture was wrong, not the death: a Game Boy with zero health dies too.

- [x] (found and fixed 2026-09-15, Step 15c) **A Start held through a reboot left the title.** The
  Game Boy's `bootRoutine` clears HRAM, so its first pad read after a reboot sees a held button
  as a press. But that read belongs to `gameMode_Boot`'s frame, and the title's own reads find the
  button already down, so the title stays. `Reset` cleared `!PadHeld` the same way, and the title's
  first poll was the press. Expected: the title stays until Start is pressed again. Repro: hold
  Start on the game over screen until the reboot and past the title's arrival.
  - Found by the death rung, whose Start is `death.zig`'s measured press and so is still down when
    the cart reboots, as it was on the Game Boy.
  - Fixed: `TitleScreen` seeds `!PadHeld` from `JOY1` before it enables NMI. The register keeps the
    last auto-read across the jump, and it is zero on a cold boot.
  - Guarded by: the death rung's code 192, shown failing on the unfixed engine first; and
    `death.zig`'s "a Start held through the reboot does not leave the title, and a fresh one does",
    which is the Game Boy's side of it.

- [x] (found and fixed 2026-09-15, Step 15b) **A save after one of three doors named the common
  item tiles as the room's background.** `door_copyData` (00:$2747) stores a source in the save
  buffer for `COPY_BG` and `COPY_SPR` and falls through without one for `COPY_DATA`. The converter
  turns a `COPY_DATA` into the characters into the same class as `COPY_BG`, and Step 15a's `.copy`
  arm stored on the class, so the three scripts that copy `gfx_commonItems` (7:$7A90) to $8F00
  overwrote `saveBuf_bgGfxSrc*`. A save before the next background `LOAD` would record 7:$7A90,
  and a load would draw the room in the item sheet. Expected: the record keeps the room's tileset.
  - Found writing the load's graphics table, whose sources are every source a door stores.
  - Fixed: a converted `COPY_DATA` carries `snes_convert.no_source_bank` ($FF, no cartridge bank)
    and the engine's `.copy` arm stores nothing for it.
  - Guarded by: `snes_convert`'s "a transfer carries a source for the save buffer only where the
    Game Boy stores one", shown failing on the unfixed converter first, and "every graphics source
    a save record can hold has a load", which requires 7:$7A90 not to be one.

- [x] (found 2026-09-15, Step 14; fixed 2026-09-15, Step 14b) **`snes boot` phase 16's drop check fails if the cart's boot
  takes one frame longer.** The room readout first uploaded its font at boot, inside `LoadHud`
  under forced blank. Every later frame moved by one, and phase 16 then stopped with code 181,
  "left nothing behind four corpses running". A loop of the same length writing only WRAM failed
  the same way, and removing it passed, so it is the time and not the VRAM. The check asserts
  that `!EnFrame`'s low bit comes up both ways across four kills. The four kills are spaced
  evenly in frames, so a one-frame shift can put all four on the no-drop parity. The engine's
  rule is unchanged; the fixture's premise, that four kills sample both parities, is what depends
  on the boot.
  - Not fixed in Step 14: the readout now uploads its font on first use, so a cart with it off is
    unchanged to the frame, and the gate is green. Expected: a drop check that holds whatever the
    boot's length, e.g. kills spaced an odd number of passes apart, or the parity forced per kill.
  - **Hit again in Step 14b**, and not by a readout: resolving the spider ball's two tables at boot
    lengthened it, and the check stopped with 181 on a cart whose drop rule had not changed. The
    retry is phase 17's (the 181 is its code). Fixed in the fixture, not the engine: the third try
    waits two frames more, one acting pass, so it rolls on the first try's parity plus 2N+1 when
    every try takes N passes -- the other parity whatever N is. The roll is still retried, not
    poked.
  - Guarded by: the Step 14b cart, which failed with 181 before the change and passes after it.
    Nothing re-lengthens a boot on purpose, so a regression of the fixture would show only on a
    cart whose N is even.

- [x] (found and fixed 2026-09-15, Step 14) **`snes boot`'s HUD icon check failed one door crossing
  in sixteen.** `checkSprite` skips the icon's sprite check on frames the door script owns, and
  tested ownership as "the door index is set". The frame `END` runs clears the index and is still
  the interpreter's frame, so nothing is drawn and OAM keeps the frame before's icon. When
  `frameCounter` bit 4 flipped on that frame, the stale icon read as the wrong sprite (code 206).
  Phase 8's two crossings never landed on a flip. Phase 23's five did, on door $0D9 at `$47`,
  frame 10 of 10. Expected: a frame the interpreter owns is never graded as a drawing frame. Fix:
  a frame is owned if the index is set now or was set a frame ago.
  - Guarded by: phase 23's crossings, which fail with the old test. Nothing fails on its own if a
    future change reintroduces it, except by the same one-in-sixteen chance.

- [x] (found and fixed 2026-09-14, Step 13c) **The Game Boy's tick sampler lost whole frames
  whenever a Metroid was appearing.** `oracle.stepToLogicPoint` stops on 00:$052F, the
  `CALL samus_handlePose` inside the play handler's Samus block, and `cutsceneActive` skips that
  block (00:$050B). So every tick of the hatching Alpha's intro ran to the instruction cap instead
  -- sixteen frames at a time, measured: the Game Boy's slot counter rose by two per sampled tick
  where the cart's rose by one per eight frames, and the case read 2 of 356 passes agreeing.
  Expected: one tick per game frame whatever arm the frame takes. Fix: the sampler also stops on
  00:$0520, the cutscene arm's `JR $053E`, which is the same point of the tick on the other side
  of the branch; no published run and no segment takes that arm, so no other rung can move.
  - Guarded by: the enemy oracle's `hatchingAlpha` case, 286 of 286 passes agreeing through the
    intro, which cannot agree with a sampler that skips frames.

- [x] (found and fixed 2026-09-14, Step 13b) **A memory callback made `snes boot`'s pictures racy.**
  The first version of the HUD checks read `!FrameCount` and `!SpriteId` from an exec callback on
  `DrawHudMetroid`, and the gate went from passing on every run to failing on some: phase 7's
  neighbour at code 81 and phase 19 at 203, on the same cart and script, with the counter, both
  camera bytes, Samus's X, her pose and the phase identical on every frame up to the failure in a
  per-frame SRAM dump of three runs. Without the callback the same script gives one answer every
  time. Expected: a script that reads the cart at the end of a frame is deterministic. The fix is
  in the script and in one scratch store: no callback, the counter read at the frame's end (the
  counter that frame's logic saw), and `DrawHudMetroid` putting back the sprite bytes it borrows.
  - Guarded by: nothing that fails on its own; a flaky gate is caught by running it twice. The
    script's comment above `hud.icon` says why there is no callback.
  - **The diagnosis was wrong (Step 24d, 2026-09-25).** The callback only added per-frame cost;
    what made the pictures racy was Mesen skipping the drawing of frames by wall-clock time.
    See the exit-81 entry below. The callback was not put back.
  - Found beside it: **the script is at Lua's limit of 200 locals in one function.** One more
    top-level `local` stops the file compiling, and Mesen reports only a timeout. New state goes
    in fields of existing tables; `luac -p build-out/m2snes.lua` names the limit.

- [x] (found and fixed 2026-09-14, Step 13b) **Four gate fixtures assumed Samus was the last
  thing a frame drew, and a HUD makes each one wrong.** `drawHudMetroid` writes `hSpriteId` and
  both sprite pixel bytes after `drawSamus`, composes two objects between her and the enemies,
  and draws on the appearance sequence's blank frames too; and `adjustHudValues` requests a tick
  sound into `sfxRequest_square1` while a display rolls. So `snes boot`'s part count (123), phase
  15's "the objects past Samus are the enemy's" (171/172), phase 19's dud request (203) and
  `cold boot`'s flicker share (147, "drawn on every frame") all failed on behaviour that is the
  original's. Expected: each fixture grades its own mechanism. The part counts include the icon's,
  a cold-boot frame holding only the icon counts as blank, and phase 19 settles the display
  before it reads the request.
  - Guarded by: `snes boot` and `cold boot` green, and the six HUD faults failing on their own codes.

- [x] (found by a playtest and fixed 2026-09-14, Step 13a) **Missiles fired nothing, and every
  cart started with zero health.** James pressed Select, the mode changed, and the fire button did
  nothing visible. The boot record had never carried a loadout, so `!CurMissLo`/`Hi`, `!HealthLo`
  and `!Tanks` were the WRAM clear's zeros on every cart and `samusShoot` took its dud branch
  (01:$4F2A). `src/residue.zig` had recorded the zero health since Step 11 as "B7's to fix".
  Expected: a new game carries 99 energy and 30 of 30 missiles, `initialSaveFile`'s. **And the
  cannon never changed**: `toggleMissiles` was a recording, so the sheet kept the beam cannon and
  the frame `beginGraphicsTransfer` spends was never spent.
  - Guarded by: `snes boot` phase 19's codes 197-203, each shown failing with its mechanism
    removed, and `snes_inject`'s "the boot record carries the new game's loadout, off the ROM".
  - Found along the way: forcing the stand pose onto a Samus the bombs had thrown leaves her
    falling for good (pose $07 for 600 frames), which is why the phase runs before the bombs.

- [x] (found and fixed 2026-09-14, Step 12c, by reading the original before porting) **The OAM
  index was zeroed at the top of `DrawSamus`**, which was the original's behaviour only while
  she was the first thing drawn. The original zeroes `hOamBufferIndex` at the end of
  `waitOneFrame` (00:$2C5E), and `handleBombs` draws the bombs from inside the Samus block of
  the play handler, *before* `drawSamus` -- so the reset where it was would have erased every
  bomb on every frame. Arm two's step 6c, a third time. Moved to `MainLoop`'s play path and
  `.itemFrame`; the transition path is unchanged, because it does not draw Samus at all.
  - Guarded by: `snes boot` phase 18's code 189, shown failing with `stz !OamIdx` put back at
    the top of `DrawSamus`.
  - What it cost the gate: `checkSprite` had asserted a nonzero index on every frame, which held
    only because the old reset lived in a routine the first frame of an item pickup never
    calls. That frame now reads 0, as the original's would; the check allows exactly that frame
    (`!ItemStage` nonzero) and no other.

- [ ] (found 2026-09-13, Step 12f, by the enemy oracle; not diagnosed) **In map `$9` cell
  `$E6`, the spawn walk loads the neighbouring Chute Leech one frame later on the cart than on
  the Game Boy.** Repro: `zig build oracle -- enemies raw` with the Gullugg case, before
  `enemy_oracle.childOfSlot0` excluded neighbours from grading. The leech lands in slot 1 at
  camera-space Y `$99` on the Game Boy and `$97` on the cart -- the same record, two pixels of
  scrolling apart -- and every pass after agrees. Expected: the same frame. The camera is moving
  on both machines identically, so the walk's edge test is the candidate, unmeasured.
  - Guarded by: nothing yet. The oracle reports it only in `raw`; the walk has no rung of its
    own on the cart side, which the B4 tracker entry already says.
  - **1.0 triage (2026-09-26, Step 1):** **Diagnostic only.** One frame and two pixels of scroll on
    a spawn nobody can see arrive; reopen as *fix* if an AI case in Steps 11-12 needs the neighbour
    graded.

- [x] (measured 2026-09-13, Step 12f; **a recorded deferral, not a new defect**; **accepted by
  James 2026-10-02, 1.0 Step 25**) **With more
  than one live enemy the Game Boy sometimes finishes the later slots on the next frame, and
  the cart never does.** 02:$4148's `rLY` budget ends a pass early and `enemy_sameEnemyFrameFlag`
  resumes it; B4b dropped the budget deliberately. Measured in map `$B` cell `$17`: a
  neighbouring pipe spawner's counter steps a frame earlier on the cart at frames 100, 108 and
  116 of 300 and nowhere else. It is why the enemy oracle collapses each slot's history
  separately and grades only the seeded slot and its children. If a graded stretch ever turns
  on an enemy's frame, this is the first thing to port.
  - **1.0 triage (2026-09-26, Step 1):** **Accepted compromise, for James to confirm in Step 25.**
    The `rLY` budget is the Game Boy running out of scanlines; reproducing it would reproduce the
    handheld's slowdown on a machine that does not have it. Graders stay per-slot as they are.
  - **1.0 Step 13 met it on a graded slot**: Arachnus's fireball, deleted at tick 302 on the
    cart and 303 on the Game Boy (`enemiesLeftToProcess` 1 after the pass). It shows only
    because the fireballs knocked Samus back and moved her camera on every pass, so the
    Arachnus cases freeze her (`enemy_oracle.cases`, `arachnus`).

- [x] (seen once 2026-09-13, Step 12f; fixed 2026-09-25, Step 24d) **`snes boot` failed one
  `zig build verify` run with exit 81** -- "the screen scrolled into does not match the
  reference render, from row 8" -- on the engine that went on to pass. Evidence, so it is
  not filed as noise and not taken for a regression either: the gate stages the exact cart
  and script it ran as `.zig-cache/boot-check.sfc` and `.lua`; run straight through Mesen2
  afterwards, those two files exited 0 six times out of six, and the next full
  `zig build verify` on the same tree was green. The change under test touched no
  background code. The one thing that differs between the failing run and the standalone
  ones is that `zig build verify` runs the unit tests beside the gate, and several of them
  launch Mesen2 too, so the working hypothesis -- unmeasured -- is two emulator processes
  sharing Mesen's settings or save folder. If it recurs, record the exit code and whether
  the unit tests were still running.
  - **Recurred 2026-09-24 (metroid2-phase-0b Step 21), and the hypothesis is wrong.** Exit 81
    on a full gate run with nothing else running. The staged `.zig-cache/boot-check.sfc` and
    `.lua` then ran alone through Mesen2, one process at a time, and exited 81 on **6 of 15
    runs**: 81, 81, 0; then 0, 0, 81 with the battery save deleted before each run (so it is not
    `boot-check.srm`); 81, 0, 0 with it kept; and 0, 81, 0, 81, 0, 0 with
    `--snes.ramPowerOnState=AllZeros` on the command line. James's Mesen settings have
    `Snes.RamPowerOnState: "Random"`. Whether the command-line override took effect was not
    checked, so uninitialised RAM is still the leading suspect rather than ruled out. The
    script registers no memory callback. Same gate run: `enemy AIs` failed `crawlerA corners`
    (camera different on 300 of 300 frames, `VarMetState` 02 where the Game Boy has 00) and
    passed when re-run alone. That may be the same cause.
  - **Fixed 2026-09-25 (metroid2-phase-0b Step 24d): Mesen was skipping the drawing, and
    neither RAM nor the `.srm` had anything to do with it.** The testrunner runs flat out, and
    flat out `SnesPpu` skips drawing any frame that starts within 10 ms of wall-clock time of
    the last one it drew (`_skipRender`, unless `Snes.DisableFrameSkipping`). The skipped frame
    neither swaps nor fills the output buffer, so `emu.getScreenBuffer()` returns the last
    frame that *was* drawn, while the OAM the sprite mask reads is this frame's. How many
    frames stale depends on the host's load and on the script's per-frame cost, which is every
    symptom above: the rate moving with an extra `emu.read`, with a callback (Step 13b), and
    with whatever else the machine was doing. Measured on cart `312f908c…b5aa`:
    - The framebuffer hashed every 50th frame: two runs with `--snes.disableFrameSkipping=true`
      agree at all 89 samples; a stock run disagrees with them at 7 of the 89, all between
      frames 150 and 400, where Samus is falling and walking. Same emulated frames, different
      pictures.
    - Stock, fresh names: 81 on 3 of 40 (runs 2-4, while another Mesen process was starting),
      0 of 40 under six busy cores, and 2 of 10 with the hash probe adding its cost. So the
      rate is not a property of the cart and no single number describes it.
    - With the switch: **0 of 40** on the gate's script, **0 of 10** with the probe (against
      2 of 10 stock, interleaved), and **0 of 10** reusing one cart name with its `.srm` left
      in place every run. The stale-save explanation from Step 24b was a coincidence of timing.
  - The switch is `verify.zig`'s `draw_every_frame`, on the two launches whose scripts read the
    framebuffer: `cold boot` and `snes boot`. Only the drawing is skipped, so nothing else is
    affected: sprite evaluation, and with it `$213E`, runs either way. The `enemy AIs` failure
    above reads no framebuffer and is **not** explained by this.
  - Guarded by: nothing that fails on its own. Removing the switch brings the flake back at a
    rate that depends on the machine. The comment on `draw_every_frame` records the
    measurement, and so does `hud.seen`'s note in `snes_romtest.zig`.

- [ ] (found 2026-09-13, Step 12f, by the enemy oracle; not fixed) **Booted into map `$C`
  cell `$21` from a settled Game Boy placement, the cart's camera moves and the Game Boy's
  does not.** Repro: add `.{ .name = "x", .ai = 0x57DE, .bank = 0xC, .cell = 0x21 }` to
  `enemy_oracle.cases` and run `zig build oracle -- enemies raw`. Both machines start with
  the camera's pixel bytes at Y `$80`, X `$80`; on frame 3 the cart's Y goes to `$84` and it
  differs on 297 of 300 frames, while the Game Boy's never moves. Cell `$C:$31` measures
  identically; `$A:$42` differs on 234 of 300 and `$A:$22` on 58, both found by the rock
  icicle's cases the same day. **So it is not one room**, and it is the most likely thing
  to cost the next AI a room too. Expected: a camera that is still on the Game Boy is still on the cart.
  - **Not the enemy AI**, which is why it is its own entry: the crawler's slot is in camera
    space, so the cart's is carried four pixels by `ScrollEnemies` and every pass after
    disagrees by that much. The oracle now records both cameras and reports a camera
    disagreement as a finding about the room rather than a failure of the AI.
  - Not diagnosed. Candidates, unmeasured: the boot record's camera against `HandleCamera`'s
    idea of where it should be for this placement, or a Samus who is not settled on the cart
    the way she is on the Game Boy. `zig build trace` is the instrument.
  - Guarded by: nothing yet. The case was taken out of the gate's list so Step 12f's AIs are
    graded in rooms where the two cameras agree.
  - **1.0 triage (2026-09-26, Step 1):** **Diagnostic only**, as a harness defect: it is a booted
    placement the player never reaches. **Promoted to *fix* in the step whose AI case needs one of
    these rooms** (Steps 11-12 name their rooms from the census).
  - **1.0 Step 12 (2026-09-29): one more room, `$B:$9B`**, skorpVert's first record. The cart's
    camera Y goes from `$A5` to `$C0` over 22 frames and the Game Boy's holds, so it differs on
    298 of 300 frames. Not promoted: the AI has other records, and its case is graded in
    `$A:$C7`, where the two cameras agree.

- [x] (found 2026-09-13, Step 12f, by the enemy oracle's first crawler; fixed in `3834383`;
  box closed 2026-09-26 by 1.0 Step 1's triage) **An enemy walking off the screen took one more step on the pass it was deactivated.** Symptom, from
  `zig build oracle -- enemies`: the Game Boy's crawler at `$F:$6A` reaches X `$C0` and
  goes inactive there; the cart's goes inactive at `$C1`. 69 of 70 passes agree and the
  70th is this. Expected: the pass that finds an enemy in the offscreen band sets it
  inactive and runs nothing else for it.
  - **Cause.** 02:$452E `deactivateOffscreenEnemy` ends its deactivating path with
    `POP AF` and a jump to `processEnemies.doneProcessingEnemy` -- it unwinds its caller,
    so `enemy_commonAI` is not called that pass. The port turned the unwind into a carry,
    as it does for the stun tail and the damage pass, and `DeactivateOffscreen` sets it;
    **`ProcessEnemies` then ignored it** and called `EnemyCommonAI` regardless. The
    carry's own comment says "set if the slot stopped being processed this frame".
  - **Why no rung could tell.** Every enemy a rung watched before 2026-09-13 either
    stayed on screen or was Samus's business rather than its own: the segment's Senjoo
    comes *at* her, and `snes boot`'s phases write slots that sit still. An AI whose
    history is compared pass for pass against the Game Boy's is the first grader that
    watches an enemy cross the band.
  - Guarded by: the enemy oracle's `crawlerA` case, shown failing before the fix.

- [x] (found by James playing the cart, fixed 2026-09-12, Step 12e) **A killed enemy
  never stopped being one, so the first kill in a room left an invisible trap that ate
  every later beam.** Symptom: combat works, then degrades -- after one kill, shots fired
  near where the corpse was die immediately and nothing happens. Expected: a killed enemy
  explodes, frees its slot, and stops interacting with anything.
  - **The mechanism, and the point is that it is made of three correct pieces.**
    `enemy_getDamagedOrGiveDrop` sets `+$0E explosionFlag` and returns; that is right, and
    it is what the original does. `enemy_commonAI` has a test for that flag and, with no
    handler ported, records the state in `!EnUnhandledState` rather than jumping through a
    Game Boy address; that is the recorder working exactly as designed. And **the kill path
    never changes the slot's status**, because on the original it does not have to -- the
    handler it defers to is what eventually deletes the slot. Each piece is correct. What
    falls out of the three together is a slot whose status still says *active*, so
    `drawEnemies` draws it, `processEnemies` walks it, and `collision_projectileEnemies`
    deletes every projectile that touches it while the damage pass sees the flag and does
    nothing.
  - **Measured before the fix, on the shipped cart, 2026-09-09**: a shot fired at an enemy
    28 px away dies after **4 frames -- identically whether the enemy is alive or a
    corpse**. At the beam's speed that is sixteen pixels, and from the player's seat it
    reads as "no beam leaves her weapon".
  - **Why no rung could tell.** Every grading path here compares position, camera and pose
    on a run that never kills anything: neither published TAS kills a Metroid inside its
    horizon, the oracle segment's 700 frames contain no kill, and `snes boot`'s phases
    shot an enemy and asserted the damage, which is the half that *was* right. The gate now
    has a phase that kills a slot outright and requires a later beam to fly through where
    the corpse was.
  - **The class, written into `porting_loop.md` as arm two's step 6d:** when a test is
    ported and its handler is deferred, ask what the unhandled state *owns*. A recorder
    says that a state was reached; it says nothing about what the state holds while nothing
    runs it, and a state that owns a slot's lifetime is not inert.

- [x] (found while building the above, fixed 2026-09-12, Step 12e) **`checkSprite`'s alias
  assertion was wrong on the frame a beam left the play window, and the first beam on this
  cart ever to get that far found it.** Symptom: `snes boot` exits 122 -- "Samus has a
  sprite anchor that is not the camera guide" -- on a frame where Samus is fine.
  - **The mechanism.** The despawn is in the draw: `drawProjectiles` (01:$5300) is what
    notices a beam outside the window and clears its slot. So on the frame a beam dies at
    the window edge it *was* composed into OAM, and `!SprX`/`!SprY` hold the beam -- while
    the array the fixture reads is already empty. The guard skipped frames with a live
    projectile and this frame no longer had one.
  - **Why it took until now.** Every earlier phase's beam dies on an enemy or on a
    destructible block, and both of those deletions happen inside `handleProjectiles`,
    before anything draws it. Step 12e's second shot is the first that is *supposed* to
    fly on, and so the first to reach the window edge.
  - The guard now covers the frame after a projectile as well as the frames with one.

- [x] (found by James playing the cart, fixed 2026-09-09, Step 12d) **Nothing ever
  cleared OAM's high table, so a slot that had once held a wrapped sprite was stuck
  256 pixels to the left forever.** Symptom: sprites lose parts, and Samus starts
  losing parts of her own once enemies are on screen. Expected: an object is drawn
  where its coordinates say, every frame, whatever was in that slot before.
  - **The mechanism.** OAM's high table is two bits a sprite -- the ninth bit of x
    and the size -- packed four sprites to a byte. `PutObject` computed its pair
    and `ORA`'d it in. Nothing anywhere clears the table: `InitOam` writes the
    *low* one and `ClearUnusedOam` only parks a y. So the ninth bit was
    write-once-and-stick: the first object in a given slot whose x needed it left
    it set, and every later object in that slot was drawn 256 pixels left.
  - **Which objects need it, and why this took until now to see.** No unwrapped
    column can: the play window is 160 wide and starts at 48, so the widest an
    unclipped part reaches is 199. What sets the bit is a part whose offset takes
    it *left of column 0* -- the eight-bit wrap `DrawSprite` reproduces on purpose
    -- so it lands near 248 and the window's net +40 pushes it past 255. That
    happens whenever a sprite touches the left edge of the screen. With Samus
    alone it took a while and the damage was invisible, because her twelve parts
    always occupy the same twelve slots and the bit is only wrong for the parts
    that are not at the edge. With projectiles and enemies sharing the shadow the
    slots are reused by objects at unrelated positions, and it showed up in
    seconds.
  - **This is a Phase 0a bug**, not Step 12d's: the `ORA` has been there since
    `DrawSprite` was written. Step 12d is only what made it visible.
  - The fix is to replace the pair rather than OR it: the mask rides in the high
    byte of the same word as the value, so the one shift loop produces both.
  - Guarded by: `snes boot`'s `the enemy is drawn` phase, which puts an enemy hard
    against the left edge so its parts wrap, requires the ninth bit to be *set*
    while it is needed, moves the same enemy to the middle and requires it to be
    **gone**. Watched failing with the `ORA` put back: `went and its objects
    stayed`'s neighbour, 174.

- [x] (found while fixing the above, 2026-09-09, Step 12d) **The four collision
  bytes were cleared on a timer rather than by the enemy that claims them, so half
  the shots that hit did nothing.** Expected: a hit registered on any frame is
  acted on by the enemy pass.
  - **The mechanism.** `enemy_getDamagedOrGiveDrop` (02:$4239) is the only routine
    that transfers `collision_weaponType` and its three neighbours into the
    AI-facing copies and clears the source, and it does that **per enemy**, at each
    of its own exits, for the slot the contact names. Step 10 had not ported it and
    stood in for it with an unconditional `jsr TransferCollision` at the end of
    every `HandleEnemies` -- citing 02:$4318, **which is not an instruction
    boundary in this ROM**; it is the middle of a `LD HL,$43C8`.
  - Harmless until Step 12b, and a real defect after it. The enemy pass runs at 30
    Hz; `HandleProjectiles` runs every frame and writes the collision record when a
    beam meets an enemy. On the frames the pass was idle the stand-in wiped the
    record before anything could act on it, so a hit only landed if it happened to
    fall on an active frame.
  - The original's own clear is per *room*: 02:$4013 wipes the seven bytes when
    `justStartedTransition` is set and at no other time. That is where the port's
    is now -- `ResetEntities`.
  - Guarded by: `snes boot`'s `and into an enemy` phase, which writes a contact
    naming a slot offset nothing has -- so no enemy can legitimately consume it --
    and requires it to still be there five frames later. Watched failing with the
    per-frame call put back: `the record was thrown away`.

- [x] (found by James playing the cart, fixed 2026-09-09, Step 12d) **The enemies had
  collision and no picture.** They moved, they hurt Samus, a beam took health off
  them and killed them -- and nothing on the screen showed any of it. Expected: an
  active slot puts its metasprite in OAM where the slot says the enemy is.
  - **Two causes, and the second is the one worth keeping.** The port had no
    `drawEnemies` at all: 01:$5A11 and 01:$5A3F were simply not written, because
    Step 9 built the slots, Step 10 the AI and the hitbox test, and neither turn's
    stop condition was ever "the count stops on a picture". Underneath that, the
    enemy metasprite set had been extracted and round-tripped **since Step 4** and
    was never shipped into the cart -- `sprites.Which` had Samus's two blobs and
    the four pose tables and no enemy pair -- so even a ported draw would have had
    no part list to read.
  - **Why no rung could see it, which is the finding.** Every grading path in this
    repository compares position, camera, pose, or the background: `reachable`,
    `anchored`, `oracle` and `durations` all read state, and `snes boot`'s picture
    comparison is the *play window* with objects excluded. The one check that looks
    at OAM is the samus sprite phase, and it graded Samus alone -- so a cart that
    drew nothing but her passed every one of them. It took a person playing it.
  - Guarded by: `snes boot`'s `the enemy is drawn` phase, which puts a slot in the
    middle of the window and asserts an object lands within a sprite of where the
    slot says it is, then takes the slot away and asserts the objects go with it.
    Watched failing with `DrawEnemies` out of `HandleEnemies`: `was never drawn`.

- [x] (found while fixing the above, 2026-09-09, Step 12d) **A slot the frame did
  not use was never hidden, because `ClearUnusedOam` ran in the middle of the
  frame.** The port called it from the tail of `DrawSamus`, which was right while
  Samus was the only thing drawn and wrong from the first frame anything appended
  after her. Expected: an object drawn on one frame and not the next is parked on
  the hidden row.
  - **The mechanism.** `ClearUnusedOam` hides every slot between `!OamIdx` and
    `!OamMax` and then sets `!OamMax = !OamIdx`. Called from inside Samus's draw,
    `!OamMax` records *her* count -- so the projectiles Step 12b appended after it,
    and the enemies Step 12d appends after those, were written into slots no later
    frame would ever hide. A beam that died left its sprite on the screen until
    something else happened to write over that slot.
  - The original has never had it there: `clearUnusedOamSlots` is the last thing
    the play handler does, after the enemies, and that is where `MainLoop` calls it
    from now.
  - **It was invisible for the same reason the entry above was**, one step later:
    Step 12b's own phases assert what the *projectile array* holds, not what OAM
    is showing, so a ghost sprite was outside everything they look at.
  - Guarded by: the second half of `snes boot`'s `the enemy is drawn` phase, which
    removes the slot and requires the objects past Samus's parts to be on the
    hidden row. Watched failing with the call put back inside `DrawSamus`: `went
    and its objects stayed`.

- [x] (found and fixed 2026-09-09, Step 12b) **`hSpriteXPixel` and
  `samus_onscreenXPos` are one variable in this engine, and they stopped being
  one the moment a projectile could be drawn.** `drawSamus_common` (01:$4DDF)
  writes each pair from a single `A` -- `ldh [hSpriteXPixel],a` then
  `ld [samus_onscreenXPos],a` -- so while Samus was the only thing the port
  drew, `!SprX` really was her on-screen position and six routines read it as
  such: `HandleCamera`'s four door triggers, and the two entries of the sprite
  collision. Expected: the byte the door trigger compares against $A1 is
  Samus's, on every frame.
  - **What broke it.** `drawProjectiles` (01:$5300) writes `hSpriteXPixel` and
    `hSpriteYPixel` for every projectile it draws and writes **neither** of the
    on-screen pair. So from the first frame a beam is in the air, `!SprX` holds
    the beam. The right-hand door trigger would have fired when a *shot* reached
    the edge of the play window rather than when Samus did -- and the horizontal
    sprite collision would have tested the beam's column against every enemy's
    box.
  - **Why no rung could have caught it before today.** Nothing on this cart had
    ever drawn a second object. `DrawSprite` had exactly one caller, and the
    aliasing was written down as a *fact about the original* -- which it is, at
    the point `drawSamus_common` runs -- rather than as an invariant that only
    holds while nothing else draws.
  - The fixture came first and was watched failing. `snes boot` phase 13 fires a
    shot and then asserts that **the byte the trigger reads** equals the camera
    guide, taking the address from the engine's own `VarTriggerX` symbol rather
    than from a mirror -- so the assertion is about *which variable* the trigger
    reads and a mirror could not have agreed with the bug. With `VarTriggerX`
    put back to `!SprX` the gate reports `snes boot` failing at 122, "Samus has
    a sprite anchor that is not the camera guide", on the first frame with a
    projectile in the air.
  - The fix is `!OnscreenY`/`!OnscreenX` as their own bytes, written by
    `SamusAnchor` where 01:$4DEC and 01:$4DF8 write them, and read by all six.
  - **The class, which is worth more than the instance.** Every alias in this
    engine that says "these two are the same number because one routine writes
    both" is an alias with an unstated precondition: *and nothing else writes
    either*. `!TileX`/`!TileY` already survived that test -- Step 12a gave them a
    second writer deliberately and `residue.zig` says so -- and this one did not.
  - Guarded by: `snes boot` phase 13's trigger assertion, and phase 14's, which
    run on every frame a projectile exists.

- [x] (found and fixed 2026-09-09, Step 12a) **The block reform ran an 8-bit immediate in
  16-bit A and took the main loop with it.** `HandleRespawningBlocks`' reform arm ends by
  recording 01:$5739's branch, and the `lda.b #$01 / sta.w !BlkCrush` that does it sits
  immediately after a `jsr BlockWrite4` — which returns in `rep #$30`. asar does not track the
  processor flags, so `lda.b #$01` assembles to `A9 01` regardless, and a 16-bit accumulator
  swallows the `8D` of the store after it: `LDA #$8D01`, then `7C 01 …` is `JMP ($0001,X)`.
  The main loop never came back.
  - **What it looked like, which is why it was nearly missed.** Nothing hangs visibly. NMI keeps
    running — OAM goes up, the tilemap goes up, `!FrameCount` advances — so the cart looks alive
    and every frame-by-frame assertion in `snes boot` passes on state that stopped changing.
    Samus keeps her last pose and her last pixel. The gate's own sprite check passed on all of
    it. What it failed on was a *later* phase asking a fresh question: a block written into a
    slot after the derailment had its counter still reading `1` twenty frames on.
  - The fixture came first and was watched failing: phase 11 passed and phase 12 reported the
    eviction never happening, then the probe narrowed it to "`HandleRespawningBlocks` is not
    running at all after the reform" — the counter of a slot armed in phase 12 stayed at its
    written value while the ROM's own gates (`!ItemStage`, `!TransDir`, `!DoorIndex`) all read
    zero.
  - **The class, which is worth more than the instance.** Every routine in this engine that
    ends `rep #$30 / rts` hands its caller a 16-bit accumulator, and an `lda.b`/`sta.b` after
    such a call is a two-byte instruction the processor reads as three. `BlockWrite4`,
    `DestroyBlock`, `BlockSlotAddr` and `SampleTile` all return that way. The fix is one
    `sep #$20`, and the comment beside it names the failure rather than the rule.
  - Guarded by: `snes boot` phase 12, which arms a slot *after* the reform has run and asserts
    it is evicted. Phase 11 alone could not catch this — every one of its assertions is about
    state at or before the frame the derailment happens on.

- [x] (found and fixed 2026-09-09, Step 11) **Two of the six `!Items` masks were the wrong bit,
  and nine ported branches read them.** `!ITEM_BOMB` was `$10` and `!ITEM_SPRING` was `$20`;
  the cartridge sets bit 0 for the Bomb and bit 4 for Spring Ball, so `$10` is Spring Ball's
  bit and `$20` is Spider Ball's — which the engine did not have a mask for at all. A cart
  that granted the Bomb would have taken the *Spring Ball* branches in the three ball
  handlers, and a cart that granted Spring Ball would have taken none.
  - **Why nothing caught it for two phases.** `!Items` is zero for the whole of Phase 0a, so
    every one of the nine branches took its empty-handed path on every frame of every rung.
    The masks were graded by nobody, and a wrong one is invisible until the first item is
    granted — which is Step 11 and no earlier.
  - Found by hand, while porting `handleItemPickup` and needing a mask for Spider Ball that
    did not exist. The fixture came first and was watched failing against the unfixed engine:
    `ConstItemBomb: engine has $10, the cartridge's arm sets bit 0 ($01)`, and the same for
    Spring Ball.
  - **The oracle is the cartridge, not M2RoS.** `handleItemPickup`'s fifteen-arm `RST $28`
    table at 00:$379A has seven arms of the form `ld a,[samusItems] / set n,a /
    ld [samusItems],a`, and `items.bitFor` reads `n` out of the `SET n,A` opcode
    (`n = (op - $C7) / 8`). That is the ROM stating the assignment outright; the constants
    file this was originally transcribed from is a second transcription of the same fact and
    could not have caught a slip in the first. The B11 trace agrees independently: `$D045`
    goes `$00`→`$01` on the Bomb and `$01`→`$21` on Spider Ball.
  - Guarded by: `correspond.zig`'s "every equipment mask is the bit that pickup arm sets in
    the cartridge", which checks all seven — including `!ITEM_VARIA`, `!ITEM_SCREW`,
    `!ITEM_SPACE` and `!ITEM_HIJUMP`, which were right.

- [x] (found 2026-09-09; **fixed 2026-09-28**, 1.0 Step 9) **The cart registers the Senjoo's contact one tick before the
  Game Boy does.** Uncovered by fixing the scroll bias below, which is what first let the segment
  reach the contact at all. Expected: the collision fires on the same tick on both machines, and
  the knockback's first arc step lands on the same frame.
  - **The measurement.** Set the segment's last phase to 59 frames (`segment_frames` 703; the
    save-RAM channel holds 705, so this costs nothing) and `zig build verify`. The `oracle` rung
    reads *Samus's position diverged, at frame 702 of 703* -- the only frame that differs in 703.
    On the Game Boy at 702: pose $0F, `samus_jumpArcCounter` ($D026) **$40**, position
    065C,0423, which is frame 701's position unchanged; the first arc step lands at 703, where
    the counter reads $41 and she is at 065D,0420. The cart at 702 is already at 065D,0420.
  - **The pose columns agreeing is not agreement.** `oracle.gb_logic_pc` is 00:$052F, which is
    *after* `hurtSamus` and before `handlePose`, while the cart's record is taken at `MainLoop`,
    after everything. So on the one frame `hurtSamus` fires, the reference's pose leads its own
    position by a tick and the cart's does not. Position is written by the pose handler on both
    sides of both sample points and is directly comparable; it is the position that differs.
  - **Where to look:** `CollideSamusEnemies` and `collision_samusOneEnemy`'s four entries, and
    what each machine's Senjoo's position is on 701 and 702. The enemy that lands the hit is
    **slot 3** on the Game Boy, and `zig build trace`'s `en` columns carry slot 0 only -- the
    small bug -- so grading this needs the recorded slot widened or moved, which is the same
    save-RAM budget question `snes_trace.zig` already documents.
  - What it costs today: nothing on the gate, which is green with the segment at 700. It costs
    the three frames between 700 and the contact, which is the one event in this repository that
    grades an enemy touching Samus.
  - **Re-read 2026-09-14 against Step 13d, and left open.** 13d taught nothing about Samus being
    touched: its kill cases do meet her -- the lunge reaches her between shots, as it does in the
    recording -- but the enemy oracle compares the slot and the Metroid globals and not Samus, and
    the Alpha's reaction to a touch (`$20`) is `.standardAction`, which a slot history cannot tell
    from no contact at all. The entry still wants what it asked for: the segment's slot 3 on both
    machines on 701 and 702.
  - **1.0 triage (2026-09-26, Step 1):** **Fix in Step 25**, fixture first. The measurement is
    already written down (`segment_frames` 703).
  - **Fixed by 1.0 Step 9's collision flag** (the entry at the top of this list): the
    horizontal entry left `samusSpriteCollisionProcessedFlag` clear, so after the walk's own
    pass the play handler's pass ran again and met the Senjoo a tick before the Game Boy's
    next frame did. With the segment at 703 the `oracle` rung matches every frame; with the
    flag's store made zero again it reads *position diverged, at frame 702 of 703*, as this
    entry measured. The segment stays at 703 (`segment_frames`), so the contact is graded.


- [x] (found and fixed 2026-09-09) **The cart's spawn walk loaded a different set of records
  than the Game Boy's**, and the cause was one constant: `DeriveScroll` subtracted the wrong bias.
  The Game Boy's `scrollY`/`scrollX` are the camera's pixel byte less a fixed amount, and the ROM
  writes that pair from three places which **do not all use the same bias** -- 00:$2366 (once a
  frame) and 00:$2896 (the room load) subtract $48 and $50, while 00:$04C3, which restores the
  camera out of $D804..$D807, subtracts $78 and $30. `engine/main.asm` had $78/$30, from the third
  site. Expected: for the same camera path the cart fills the same slots with the same records as
  the running Game Boy does.
  - **What it cost:** every enemy the walk loaded came out **48 pixels below and 32 pixels right**
    of where the original puts it, because `LoadOneEnemy` stores `record + OAM offset - scroll`.
    Measured on the oracle segment: both machines load the small bug on frame 388, the Game Boy at
    y $22 x $F4 and the cart at y $52 x $D2. Off by that much the slot sat in a different band of
    the deactivation window, so the cart deleted it on frame 546 while the Game Boy kept it, and by
    frame 640 the Game Boy had three live slots and the cart none. On the movie path the visible
    symptom was a *collision* -- pose $10 at reference frame 605 -- and `reachable` read 604
    against its floor of 1396.
  - **The measurement that found it, so nobody has to find it twice.** Read `$C205`/`$C206` and
    `$FFC8`/`$FFCA` off the running Game Boy on every frame of the segment: `scrollY` is
    `camera_pixel_y - $48` and `scrollX` is `camera_pixel_x - $50` on all 700 of them, with no
    exceptions. Reading the ROM was *not* enough to settle it, because the pair this file had is
    also in the ROM -- which is the whole reason the fixture below asks the running game.
  - Guarded by: `src/oracle.zig`, "the engine's scroll bias is the one the running game uses",
    which reads the two defines out of `engine/main.asm` and grades them against the original over
    the segment, requires the camera to have actually moved, and requires the old $78/$30 pair to
    be right on **zero** frames. With $78/$30 back in it fails on the first frame. `reachable`'s
    1396 and the segment's last 56 frames are the second and third.
  - Why it survived Step 9: B4a's four fixtures put the *running Game Boy* in a room and read its
    slot array back, which grades the reader and says nothing about the cart. `zig build trace`'s
    four `en` columns are what ended that, and are what found this -- the cart's slot 0 against the
    Game Boy's, frame by frame.


- [x] (found and fixed 2026-09-09) `SpawnListAt` subtracted 9 from `!MapIndex` before using it as
  the base of the enemy pointer table, following the original's `currentLevelBank - 9`. **This
  engine's `!MapIndex` is already an index**: `PeekScreen` hands it straight to `FindBlob` as a
  `map_cells` blob id, and `WARP` writes the door opcode's low nibble, which is 0-6 and not
  $9-$F. So the subtraction happened twice and every lookup landed $2400 pointers below the
  table. Expected: the cart's spawn walk reads the same list for a cell that `entity.zig` does.
  - Why it mattered: **the cart loaded no enemy at all, anywhere.** Not a wrong enemy -- none.
  - Shipped in Step 9 and invisible until B4b, and the reason is worth keeping: Step 9's four
    fixtures put the *running Game Boy* in a room and read its slot array back, which grades the
    reader beautifully and says nothing whatever about the cart. No rung had ever looked at a
    slot on the SNES side, so a walk that filled nothing was indistinguishable from a room with
    no records in it. That is the mirror of the hazard `porting_loop.md` names in arm two's step
    5 -- a rung passing because the port does not have the mechanism at all.
  - Guarded by: `zig build trace`'s four `en` columns, added with the fix, and the oracle
    segment's last 56 frames, which run with enemies live on both machines. With the second
    subtraction back in, the segment's `en st` column reads $FF for all seven hundred frames.


- [x] (found and fixed 2026-09-09) The cart enabled NMI wherever boot happened to end, and if
  that was inside vblank the handler fired *immediately* -- NMI is not maskable by `cli` -- and
  then `MainLoop`'s `wai` waited for the next one. Two NMIs before the first frame of logic where
  the boot record's `!FrameCount` seed assumes exactly one. Expected: the number of NMIs between
  `InitState`'s seed and frame 0 is a property of the cart, not of how long boot took.
  - Why it mattered: `!FrameCount`'s **parity** is physics. `WalkSpeed` is `(n & 1) + 1`, so an
    off-by-one phase makes Samus walk 1 where the original walks 2 and 2 where it walks 1, on
    alternate frames forever. `boot record version 5` exists precisely to get this phase right
    and it was being undone after the fact.
  - How it was found: B4b added four `FindBlob` calls to `ResolvePhysics` and five stores to
    `InitEntities`, which moved the enable across a vblank boundary for **one** of the thirteen
    anchored stretches. `zig build oracle -- movie` fell from 1396 reachable frames to 129, and
    `zig build trace -- stretch 0 0 3` showed the cause in one column: frame 0 read `!FrameCount`
    73 against the Game Boy's `$FF97` of 72, where every other stretch still read equal. Nothing
    about the port's behaviour had changed; boot had got longer.
  - **Latent since the engine had an NMI at all**, and invisible because it is a function of a
    duration nobody controls. Any future step that adds work to boot could have set it off, and
    the symptom -- a one-pixel position difference on alternate frames, reported as "Samus's
    position diverged" -- names neither the counter nor the boot.
  - Fixed by waiting for a vblank and then for it to end before writing $4200, so the enable
    lands at the top of active display about 180 scanlines from the next NMI, and by reading
    $4210 first to discard whatever flag the vblank it waited through had latched.
  - Guarded by: the `snes boot` rung's `frame phase` check, which reads `!FrameCount` on the
    cart's first play frame and requires it to be the boot record's `BootFrameCount` plus
    exactly one. Shown failing against the unfixed engine before the fix was kept.

- [x] (found and fixed 2026-09-08) `src/residue.zig`'s source scan classified a store with an
  explicit width -- `sta.w !Foo`, `stz.w !Foo` -- as a **read**. `opIn` compared the whole
  mnemonic against `sta`/`stx`/`sty`/`stz`, and `sta.w` matches none of them. Expected: the
  suffix is a property of the operand's size, not of the operation, so the two forms classify
  alike.
  - Why it mattered: an `unread` row is this audit's cheapest possible finding -- "whatever the
    opening left in it cannot matter" -- and a scan that turns every write into a read cannot
    ever produce one. It also silently inflates the `reads` list every field carries, which is
    the claim the audit's own test is supposed to be able to refute.
  - Not wrong until Step 9: every variable the port had lived in the direct page, where asar
    sizes the operand and the source says `sta !Foo`. The entity slots and the spawn flags are
    at $0200 and $0400, so their stores carry `.w`, and `!EnChild` -- a variable two routines
    only ever write -- scanned as read by both of them.
  - Guarded by: `residue.zig`'s test "a store with an explicit width is still a store", written
    against the unfixed scanner and shown failing on it before `mnemonic` existed.
- [x] (discovered 2026-08-31, reproduced on FXPak hardware 2026-09-01, fixed 2026-09-02) When samus enters morph ball and falls through midair, it bounces like normal after hitting the ground and when the bouncing is complete she unmorphs. Samus should stay morphed until the player chooses to unmorph by pressing "up" in non-spider-ball mode.
  - Cause: `PoseJump`'s `.startFalling` set pose $07 unconditionally. The original tests
    `samusPose == pose_morphJump` at 00:$1837 and exits to $08 instead, and the port had dropped
    that branch -- so a bounce, which flies the jump arc, ended as a standing fall.
  - Guarded by: the oracle segment's last 324 frames, and `pose` is now a graded quantity.
    With the branch removed again the gate reports "Samus was in a different pose" at 583-593.
    Position and camera alone called it a match, which is why it reached hardware.
- [x] (found 2026-09-02, fixed 2026-09-05) `zig build test` prints `failed command:` lines for test binaries that
  emit `std.debug.print` diagnostics, while every test passes and the step exits 0. Run directly
  the same binary reports `All 254 tests passed` and exits 0, so the binaries are fine; the lines
  only appear under the build runner's `--listen=-`. The emitters are `src/locate.zig:430` and
  `:465` ("N frames replayed", "who writes the two position quads"), and each `failed command`
  is immediately preceded by that dump. **Why it matters: it makes the output untrustworthy at a
  glance.** On 2026-09-02 three genuinely failing tests were sitting in the middle of this noise
  and the first read of it was "pre-existing, exit 0". Expected: `zig build test` output is quiet
  when everything passes. Likely fix: route those diagnostics through the test's own writer, or
  gate them behind an env var, rather than `std.debug.print`.
  - Cause: nothing about the tests. The build runner treats *any* stderr from a test binary under
    `--listen=-` as a failed command, and both emitters are unconditional `std.debug.print`
    surveys that run whenever the ROM and the movie are present.
  - Fix: a `-Dsurvey` build option (also set by `M2_SURVEY` in the environment), read in
    `src/locate.zig`'s `survey`. Off by default; `zig build test -Dsurvey` still prints both
    tables. There is no "test's own writer" to route to -- Zig 0.16 hands the environment to
    `main`, and a test binary's `main` belongs to the test runner, so the build script is the
    only side that can see it.
  - Guarded by: nothing automated, deliberately -- a test that asserts the build's own output is
    quiet would have to run the build. What *is* guarded is the second emitter: "what the position
    quads are, asked of the machine rather than of a comment" had no assertion in it at all and
    passed unconditionally, so gating its dump would have left a test that did nothing. It now
    asserts the survey's answer -- the walk routines write $FFC2/$FFC3 and never $FFC8-$FFCB,
    `camera_update` the reverse -- and fails when either half is perturbed.
- [x] (found and fixed 2026-09-08) All eight `collision_*` entries in `src/offsets.zig` named the
  address of the table one slot below the one they name. `collision_surface` read $4480, which is
  `caveFirst`'s table; `collision_finalLab` read $4780, which is `ruinsExt`'s; and
  `finalLab`'s own table, at $4080, was labelled `plantBubbles`. Expected: an entry's name and its
  address describe the same table, which is the whole contract `offsets.zig` exists to keep.
  - Found by: the game's own new-game record. Step 7 pinned `initial_save` (01:4E64), the $26
    bytes `createNewSave` copies into `saveBuffer`, and the record names the surface tileset's two
    source pointers outright -- $5280 for the metatiles, which matched, and $4580 for the
    collision, which did not. The landing site is the surface, so there is no reading of that
    record in which $4580 is anything else.
  - Cause: the entries were written in operand order on the assumption that the region is laid out
    in operand order too. It is not. M2RoS's `bank_008.asm` includes `finalLab` first and then the
    other seven in operand order, so operand $N sits at $4080+($N+1)*$100 for $N under 7 and
    operand $7 sits at $4080. `collisionPointerTable` (08:7EEA) says the same thing in the ROM.
  - **No cart was ever wrong.** `tileset.collisionOrder` resolves an operand by matching the ROM's
    pointer against each entry's *address*, so the mislabelling was absorbed exactly and came out
    the other side as a rotation. The digest of the built cart is byte-identical across the fix,
    which is how that was checked rather than argued. What was wrong is everything that prints a
    table's name: `zig build trace`'s "the reference holds table N (name)" and the two doc
    comments that explained the rotation as a property of the ROM.
  - And a third confirmation, found while rewriting those comments: the Step 15 divergence story
    said `COLLISION $6` gave the cart `ruinsExt` where the original had `finalLab`, and that
    "ruinsExt marks a floor tile of the segment's room as water". Under the corrected names it
    reads `lavaCaves` where the original had `ruinsExt` -- and water in the lava caves is the
    obvious reading of that byte, where water in the outdoor ruins never was.
  - Guarded by: `tileset.zig`'s "the game's own new game names the surface tileset's tables, and
    the operand order is the identity", written before the fix and shown failing against the
    unfixed table ($4480 where the record says $4580). It asserts both halves -- the record's two
    pointers, and that `collisionOrder` is now the identity -- so a name that drifts one slot in
    either direction fails it. The neighbouring "a COLLISION operand selects a table through the
    ROM's pointer table" test used to assert the mapping was *not* the identity, which locked the
    defect in; it now asserts the true claim, that the operand is not a position in the region.
- [x] (found 2026-09-05; **fixed 2026-09-30, 1.0 Step 18c**) Nine cells the published runs walk through are assigned a metatile table
  the Game Boy was not using, and two of the any% run's thirteen stretches cannot be graded
  because of it. `zig build oracle -- worlds` names them: map 6 $6B and $6C (assigned 9, the Game
  Boy showed 4), map 3 $21 and $31 (assigned 5, showed 4), map 2 $0D and $0E and map 1 $00, $01
  and $11 (assigned 4, showed 6 -- and **zero** of the compared tiles agree on those five).
  Anchors 11 and 12 of the anchored sweep are map 2 cell $0D, which is why they still report "no
  frame this room can be booted at".
  - **Revised 2026-09-24 (Step 22): "showed 6" was the wrong names.** Until then the lava
    table slots were layout order, and `oracle -- worlds` judged the Game Boy's tiles through
    them. Through the ROM's pointer table, map 2 $0D and $0E show **table 8**, the table door
    $04A states for bank $B, and map 1 $00, $01 and $11 show 6, 8 and 7. So the reasoning
    below that no door in bank $B states the table no longer holds for map 2. The assignment is
    still wrong (table 4), and anchors 11 and 12 are still unbootable, but the fix may now be
    reachable by inference. Those two stretches cover the any% run's acid (frames 7369-8407).
  - **What else it blocks, measured 2026-09-26 (Step 26): the seeding fixture.** In the
    recording, map 6 $6B and $6C and map 3 $21 are where James shoots blocks out
    ([10 000, 12 000)), and 22 of that window's 26 anchors never settle for exactly these cells:
    391-399 of 399 tiles agree at table 4, which the Game Boy was showing, against 88-218 at the
    assigned table. So `oracle -- recorded 10000 2000 8 fault` has one gradable seeded stretch, it
    plays 1 frame either way, and the anchored sweep's world seeding stays unfalsified until
    these cells are drawn from the right table.
    Fixing it therefore re-opens Step 8's last sub-task, and that fixture is how to confirm the fix.
  - Cause: not one bug. `screens.assign` models the metatile table as a property of a *cell*, and
    the Game Boy treats it as loaded state -- a door script that names no table leaves the
    previous room's loaded, so which table a room is drawn with can depend on how the player
    reached it. The inheritance pass added on 2026-09-05 follows the door graph one hop and
    recovers most of it. What is left is where the door table simply does not contain the answer:
    **no door in bank $B states table 6 at all**, so no inference over the doors can produce the
    table the Game Boy was showing in map 2.
  - Not fixed by: the two inferences that were tried and measured. Spreading through unblocked
    scroll edges first covers almost nothing -- the flags cut the map into 239 fragments and only
    36 contain a warp target. Reweighting by distance from the nearest warp target cannot help
    either: map 1 cells $44-$48 inherit correctly at distances 1 to 5, and map 3 $21 is wrong at
    distance 0.
  - Guarded by: `oracle.anchored_gradable_floor`, which fails if a stretch that can be booted into
    stops being one, and `screens.zig`'s "the tables a running Game Boy showed" test, which pins
    all nine as still wrong so that fixing one is noticed rather than absorbed.
  - **1.0 triage (2026-09-26, Step 1):** **Fix in Step 18** (C6 names B12's nine cells), graded by
    running every door script on both machines.
  - **Fixed 2026-09-30 (1.0 Step 18c)** by reading the door crawl instead of inferring:
    `warp.assignWalked` gives each room our Game Boy walked into from the new game what the
    arrival loaded, and `snes_screen.bootFor` and `oracle -- worlds` take it. **34 of 34 cells
    the published runs stay in agree tile for tile** (24 through the static reading), the nine
    among them. The lava cells were never an inference beyond reach: walked, they have table 8,
    which is what the Game Boy shows. `screens.assign` itself is unchanged, because the crawl is
    seeded from it.
  - Guarded by: `warp.zig`'s "the tables a running Game Boy showed, against the walked reading",
    which holds all nineteen measured cells as `.walked`; and `warp_grade`'s "every cell a walked
    room settles draws as our Game Boy drew it", 484 cells, whose fault (the static reading)
    fails 159. The seeding fixture now has rooms to grade in: see `docs/conformance.md`.
- [x] (found 2026-09-05; **re-decided 2026-09-30, 1.0 Step 18c**) Banks $9 and $A are the two where following the door graph makes the
  picture worse rather than better, and nothing grades them. Seeding a table-less door's target
  from the room it was entered from takes collapsed metatile pairs -- two different indices a
  screen uses that draw the same picture -- from 0 to 49 in bank $9 and from 0 to 100 in bank $A.
  `assign` therefore vetoes the pass in those two banks, on that measurement alone.
  - Why it is a bug entry and not just a decision: the veto is a *proxy* standing in for a
    measurement nobody can make. No published run reaches bank $9, and in bank $A the runs reach
    eight cells that are graded identically either way -- so "flatter is worse" is being trusted
    without a picture of the original to check it against. B11's recording may reach bank $9, and
    when it does this should be re-decided against the Game Boy rather than against the proxy.
  - Guarded by: `screens.zig`'s "no screen is drawn through a table that collapses the metatiles
    it uses", at a ceiling of 1388 pairs against 2447 with no pass and 1537 with the pass
    everywhere; and `assign`'s `vetoed_banks`, pinned at 2.
  - **1.0 triage (2026-09-26, Step 1):** **Fix in Step 18.** Its every-door tileset grading is the
    measurement this entry says nobody could make; the veto is re-decided against it.
  - **Re-decided 2026-09-30 (1.0 Step 18c)** against the cells the door crawl walked. Bank $9:
    the vetoed reading agrees with 151 of 151, the pass with 136, so the veto was right. Bank $A:
    the vetoed reading with 5 of 58, the pass with 14, so it was wrong. `warp.assignWalked` now
    takes, per bank, whichever agrees with more walked cells for the cells it did not walk; the
    walked cells take what was walked. `assign`'s own proxy veto stays, pinned at 2, for the
    crawl's seeds.
  - Guarded by: `warp.zig`'s walked-reading test, which pins `vetoed_banks` at 1.
- [x] (found and fixed 2026-09-07, Step 5) `src/room.zig`'s `Direction` enum names three of its four values
  wrongly. It reads `settle = 1, up = 2, down = 4, across = 8`; the ROM says **1 is right, 2 is
  left, 4 is up and 8 is down**. Nothing has produced a wrong result yet, because the only caller
  is `probe.runDoors`, which writes 1 to `door_direction_addr` for all 512 doors and never names
  the value -- but Step 5's `room.zig` transition scenario is about to select a direction on
  purpose, and a scenario that asks for `.across` and gets a downward warp would fail in a way
  that reads as a port defect.
  - Evidence, from the ROM rather than from the names: `handleWarp` dispatches on $D00E at
    00:$2918-$2934, and each arm's draws say which way it faces. $2939 (value 1) draws three
    columns at camera + $50/$60/$70 -- to the right; $29C4 (2) at camera - $60/$70/$80 -- to the
    left; $2B04 (4) three rows above the camera; $2A4F (8) three rows below. The four triggers in
    `handleCamera` agree: 00:$092B sets 1 on the right-blocked edge, $09A5 sets 2 on the left,
    $0AD6 sets 4 on the up and $0A66 sets 8 on the down.
  - Fix: renamed to `right = 1, left = 2, up = 4, down = 8`, with the two readings above written
    into the enum's own comment so the next person does not have to re-derive them.
  - Guarded by: nothing automated, and honestly so. A name is not a measurement -- what a test
    could catch is a *value* being wrong, and the values were always right. What the comment now
    carries is the evidence, which is the same trade `docs/feature_tracker.md` makes.
- [x] (found 2026-09-07, Step 5; fixed 2026-09-07, Step 5b) **The reachable rung's 375 was partly earned by standing still
  for the wrong reason, and porting the door trigger is what exposed it.** With Step 5's trigger
  wired in, the port fires the transition at reference frame 281 -- which is exactly where the
  original fires it, movie frame 609 -- and then completes the whole thing inside one frame,
  where the original takes 94. So the rung, which had read 375, now reads 281.
  - What was measured, and it is worth keeping because it is the whole mechanism in one place.
    `extracted/tas/any-vblank0-trace.tsv`, movie frames 600-712:
    - 608: she is at $07F3,$0784, camera $07B0,$0796, map bank $0F. $07B0 is `!CAM_MAX_X`, so the
      camera is on its clamp and the right edge is blocked.
    - 609: **everything freezes.** Samus, the camera and the bank hold for 94 frames. This is the
      door script running, not Samus being held by a pose: the interpreter waits a frame after
      every opcode at 00:$26D1, and two of this door's opcodes are expensive.
    - 703: the `WARP` executes. Bank $0F to $0A, Samus to $03F3,$0484, camera to $03B0,$0496.
    - 703-707: the rest of the script, still a frame apiece.
    - 708 onward: 00:$0B44, the in-transition camera -- camera + 4 a frame, Samus + 1 a frame,
      until the camera's pixel byte reaches $50.
  - The door itself, decoded from the ROM: bank $0F cell $77's transition word is $01DF, which is
    door $1DF, whose script at bank 5 $553D is `FADEOUT`, `$B1`, `COPY`, `COLLISION`,
    `ESCAPE_QUEEN`, `WARP $A,$43`, `END`. **`WARP $A,$43` is bank $0A, screen row 4, column 3 --
    the trace's $03F3,$0484 exactly**, which is the confirmation that Step 5's warp arithmetic is
    right independently of any rung.
  - Where the 94 frames come from: `FADEOUT` (00:$2561) waits four frames and then runs a palette
    fade of $2F down to $0E, one frame an iteration, so roughly 38; `COPY` (00:$2747) chunks a
    multi-kilobyte VRAM transfer across frames for the rest of it.
  - Cause: not a defect in what Step 5 ported. It is the mechanism being landed in halves -- the
    trigger without the duration -- which is the failure mode `docs/porting_loop.md`'s arm two
    was written to prevent, arriving in the one shape the arm did not anticipate: not a silent
    pass on stale state, but a rung that had been passing on the port *not* having the mechanism.
  - Guarded by: the reachable rung itself, which is now red and says so.
  - **Where the 94 frames actually come from, measured 2026-09-07 and the reason the merge is
    bigger than it looked.** They are not a hold the port can simply reproduce by counting
    opcodes. The original's frame cost per opcode is a property of *Game Boy VRAM bandwidth*:
    - The main loop's play-state handler skips the whole Samus block while `$D00E` is set
      (00:$0522), and calls the streamer and the camera either way (00:$053E, $0541). So during a
      transition the pose machine does not run, which is why she holds still.
    - The interpreter blocks: it waits a frame after every opcode at 00:$26D1, and once more on
      entry at 00:$23AF.
    - `FADEOUT` (00:$2561) waits four frames, then fades to black in three palette steps -- $E7,
      $FB, $FF from the table at $259B -- driven by `$D066`, which the vblank handler decrements
      once a frame at 00:$0172. From $2F down to $0E that is ~34 frames.
    - `COPY` and the two graphics loads inside `$B1` and `ESCAPE_QUEEN` all end at 00:$27BA,
      which sets `$D047` and then waits a frame at a time until the vblank queue drain has
      cleared it. **The drain moves at most 64 bytes per vblank** -- the loop runs until
      `C & $3F` is zero -- so a copy's duration is `ceil(len / 64)` frames and this door copies
      1714 bytes in one of three transfers.
    So a port that wants the same frame count either throttles its own DMA to 64 bytes a frame,
    or computes the duration from the same rule and waits it out while transferring at SNES
    speed. The second is the port's usual method -- reproduce the rule, let the number fall out
    -- and it needs the rule graded against the Game Boy across several doors rather than fitted
    to this one.
  - **Fixed by Step 5b**, which made the duration a computed quantity rather than a hold. The
    rule is `src/transition.zig` in Zig and `OpExtraFrames` plus `.copy` in the engine, and the
    two are checked against each other out of the assembled image. **Reachable 375 -> 420, and
    the port now crosses the door frame for frame**: `zig build trace -- stretch 0 372 18` reports
    "no divergence: every frame matched" across the warp, the five held frames after it and the
    incoming scroll. The four defects it took to get there are the four entries below.
  - The transcription in this entry is **wrong and is left standing as written** so the correction
    below has something to point at. Door $01DF's script is not `FADEOUT, $B1, COPY, COLLISION,
    ESCAPE_QUEEN, WARP, END`; see the next entry.

- [x] (found and fixed 2026-09-07, Step 5b) **This tracker's own transcription of door $01DF was
  wrong, and it was load-bearing.** The 2026-09-07 entry above reads the script by hand as seven
  operations: `FADEOUT, $B1, COPY, COLLISION, ESCAPE_QUEEN, WARP $A,$43, END`. The interpreter
  disagrees. It is eight: `FADEOUT, $B1, COLLISION, SOLIDITY, TILETABLE, $B2, WARP $A,$43, END`.
  - How it was caught: not by reading it again. `src/transition.zig`'s `measure` records the
    opcode byte the Game Boy actually fetched at 00:$23E1 for every operation in a script, and
    the first thing it disagreed with was the length.
  - Nothing downstream was wrong, because the one field Step 5 leaned on -- `WARP $A,$43` -- was
    right, which is why the warp arithmetic checked out against the movie. But the frame model
    *is* per opcode, and a duration built on the wrong seven would have been wrong by 20 frames.
  - Guarded by: "the interpreter and the decoder walk the same stream, opcode for opcode", which
    re-encodes every operation the decoder produced and compares it against the byte the machine
    read. A misread operand length desynchronises the stream, so agreeing on all eight is
    agreeing on the format.

- [x] (found and fixed 2026-09-07, Step 5b) **The interpreter's entry wait and its first opcode
  are the same frame, and treating them as two put the whole crossing a frame late.** The port
  spent one frame arriving at `RunPendingTransition`, resolving the script and returning, and a
  second frame running `FADEOUT`. The original does not: 00:$0568 is downstream of the camera at
  00:$0541, so the interpreter is entered *inside the trigger's own frame*, blocks at 00:$23AF,
  and wakes on the next frame with an opcode to run.
  - Measured rather than reasoned: `tas.run` with a watcher on $D00E and $D058 says the any% run
    triggers at movie frame **608**, runs `FADEOUT` at **609** and warps at **703**. The model's
    94 frames of preceding opcodes land the warp on 703 only if 609 is both the entry wait and
    `FADEOUT`.
  - Symptom: the reachable rung stopping at 375 -- the exact frame the original's warp lands --
    and `zig build trace -- stretch 0` showing the port's warp on 376 with every frame after it
    matching. A one-frame offset is invisible in the model and only visible against the machine.
  - Guarded by: "the movie's own crossing is the frames this model predicts, end to end", which
    walks the script's opcodes from frame 608 and asserts the warp lands on 703.

- [x] (found and fixed 2026-09-07, Step 5b) **A `spr` transfer is one Game Boy opcode and two
  converted ones, and the pacer charged it two dispatch frames.** `snes_convert` splits a `spr`
  `COPY`/`LOAD` in two because the same pixels have to exist at two depths in two VRAM regions;
  the Game Boy made the transfer once and paid one dispatch frame and one queue drain for it.
  Running the second half as its own opcode added a frame to every script containing one -- which
  is most of them.
  - Fix: the background half gets its own `CopyClass`, `bg_twin` ($3), which maps to the same
    region as `bg` and to **no frames at all**. It does not yield to the pacer: it falls back
    into the fetch so the next opcode runs in the frame its own dispatch would have cost.
  - Guarded by: the reachable rung, which moved 375 -> 376 -> 375 across this fix and the one
    above; and the class is checked against `snes_convert.CopyClass` out of the engine source.

- [x] (found and fixed 2026-09-07, Step 5b) **The frame a script ends on is still the
  interpreter's, and handing it back started the incoming scroll a frame early.** `END` costs no
  frame of its own (00:$23E7 returns through $26D7 without waiting), so `RunPendingTransition`
  returned carry clear and the rest of that frame's main loop ran -- including the camera, which
  took its first 4-pixel step one frame ahead of the original's.
  - The original cannot do that: it runs the whole interpreter inside *one pass* of its main
    loop, so the camera at 00:$0B44 does not get a turn until the next pass.
  - Measured on stretch 0: the port stepping the camera on 379 where the original steps it on
    380. The movie trace agrees -- `END` at 707, first camera step at 708.

- [x] (found and fixed 2026-09-07, Step 5b) **A cart boots with its sprite guides at zero, and
  two of the four door triggers fire on a *small* guide.** `!SprX` and `!SprY` are Samus in
  camera space, written by `SamusAnchor` at the end of every frame's draw and read by the
  triggers before that draw -- so frame zero reads whatever `Reset` left, which is zero. The
  leftward trigger fires when `!SprX` is under $0F and the upward one when `!SprY` is under $1B,
  so **a cart booted anywhere with the camera already on a clamp fires a transition on its first
  frame.** Invisible until Step 5b, because `TransArmed` was zero.
  - Measured on the durations rung: booted at the run's frame 2361, one frame before a leftward
    crossing with the camera already on $50, the port fired the transition immediately where the
    original fires it on 2362 -- and the stretch went from "compared" to "the port left the run
    at frame 2361". Two stretches were lost that way, which is what took the compared count from
    17 to 15.
  - Fix: `Reset` calls `SamusAnchor` after `SeedPlacement`, so frame zero gets the guide its own
    position implies instead of a zero that means "hard left".
  - Guarded by: the durations rung's compared count, which is a floor. It went 17 -> **19** with
    the fix in, and agreeing went 13 -> **17**: the two leftward crossings this defect had made
    unreachable are transitions whose script carries no `WARP`, and the port now spends the Game
    Boy's twenty-one frames on each where it used to spend one.

- [x] (found and fixed 2026-09-07, Step 6) **A cart booted from a mid-run record had one screen's
  tilemap in all 1024 slots, so every screen boundary had the wrong room on the far side of it.**
  This is what `scroll 2563` and `scroll 3316` were -- the two rows `src/duration.zig` had named
  since 2026-09-01, reading 48 and 46 frames against the Game Boy's 1, and neither of them a
  transition. She walks left out of the boot screen and stops dead against a wall the original
  does not have, for the whole search window, until the movie happens to press jump.
  - The original's buffer is not a room. It is a mod-256 window on the world, and after a few
    seconds of play the slots outside the camera's own window hold **the screen next door**.
    `LoadScreen` fills all 1024 from one screen body, which is right for a room and wrong for
    that window; collision reads the same buffer (`SampleTile`), so those slots are floor and
    wall rather than decoration.
  - Measured rather than reasoned, with an instrument that did not exist that morning:
    `zig build trace -- at 2562` anchors a cart at any movie frame and traces it, which is what
    `stretch N` does for the thirteen anchors the sweep picked and could not do for the anchors
    `duration.zig` picks. It reads **0 of 32 rows differing inside the window and 304 of 871
    slots differing outside it**. Frame 3315 gives the same reading at 501 of 871.
  - Fix: `SeedWindow`, sixteen columns of the streamer from the same corner `prepMapUpdate`
    measures from, which covers all 1024 slots exactly once. It belongs to the record and is
    called only from `Reset`, because after a real door the original genuinely does have one
    screen plus the edge strips, and seeding the window there would be more correct than the
    original.
  - Guarded by: the durations rung, **19/17 -> 28/28**, and the anchored floor, **462 -> 665**.
    Nine stretches that used to leave the run within a frame or two of booting now do not.

- [x] (found and fixed 2026-09-07, Step 6) **`TILETABLE` changed the table and nothing re-read
  it, so a room entered through a door was drawn -- and walked -- in the tileset the cart booted
  with.** `!Meta` is the base the streamer looks metatiles up through, and it was derived inside
  `LoadScreen`, which runs once, at boot. The opcode wrote `!TileTable` and that was all it did.
  - Found by the fixture written for `WarpDraw`, **on the fixture's first run**, which is the
    standing rule paying for itself: `snes boot` compares the incoming edge against the ROM's
    map data expanded through the table the *script* selects, and the engine had drawn it
    through the table the *record* selected. The fixture was written to check that the strips
    were drawn at all; it caught them being drawn out of the wrong book.
  - Symptom, before anyone knew what it was: the reachable rung stopping at 420 on a pose
    divergence, 45 frames into the room the run's first door leads to, with the morph ball
    falling through a floor the original rolls along. Neither `SeedWindow` nor the strips moved
    it, which is what said the defect was not about *which* tiles were fetched.
  - Fix: `LoadMetaBase`, the derivation given a name and called from both places. Note that the
    four lines it replaced left A byte-wide because the block after them in `LoadScreen` is
    byte-wide; extracting them without saying so took the cart to `Fatal`.
  - Guarded by: `snes boot`'s code 137, and the reachable rung -- **420 -> 899 of the 899 frames
    then offered, and 1396 once the window was raised to 2000.**

- Not a defect yet, recorded because it will be one: **a `COPY` whose destination is a tilemap
  writes VRAM, and the buffer collision reads never sees it.** On the Game Boy the background map
  *is* the memory `samus_getTileIndex` looks the tile up in, so a `COPY_data` both draws and
  gives her the floor. The port keeps that map in WRAM and DMAs it out once a frame, so a tilemap
  copy lands in VRAM and the next `!Redraw` writes the old buffer back over it.
  - **Nothing in the slice reaches it.** No door script in this ROM carries a tilemap `COPY`;
    the rooms are drawn by `WarpDraw`'s strips and the streamer. The copies that do exist are
    the queen-head writes to $9C00 -- Game Boy tilemap *1*, not the one collision reads -- which
    `snes_target.gbDestToChar` already folds into the same BG3 map.
  - It was written and then reverted on 2026-09-07 for exactly that reason: unexercised by any
    rung, and the $9800/$9C00 conflation is a decision that wants the Queen in front of it. B8's.

- [x] (found 2026-09-14, fixed 2026-09-15, Step 14) Found 2026-09-14 - The room directly to the
  right of the first save point transitions to the wrong screen. It transitions directly into a
  full acid room. Likely want to create a debug feature which puts a room/tile code on screen so
  it is easier to identify which screen is which.
  - Which door: the `$F:$01` station's room leads right along the surface to `$F:$05`, whose door
    074 (`$04A`) warps to `$B:$0C` and then runs `IF_MET_LESS $46, $01E1; TILETABLE 8`. Door
    `$1E1` is `TILETABLE 6`.
  - Cause: the engine's `IF_MET_LESS` recorded its operands and never branched, so every cart drew
    `$B:$0C` through table 8, the no-kill table, whatever the count. That is right at `$47` (the
    anchored rung grades this room at `$47` on the published run) and wrong after any kill: 00:$254A
    is `CP B` with the operand in A, then `JR NC`, which takes the branch at **or below** the operand,
    so one kill opens it. The design documents had the same misreading ("two kills"). If the
    playtest had not killed the first Alpha before this door, the full-acid room was the Game Boy's
    too, and the fix changes nothing there. **James: worth confirming whether the Alpha was dead.**
  - Measured: our Game Boy's interpreter, run on door `$04A` at `$47`, `$46` and `$45`, ends on
    table 8, 6 and 6, in the frames `transition.zig` predicts. A taken branch costs one frame, not
    two; the model double-charged it and was corrected by the same test.
  - Guarded by: `snes boot` phase 23, code 224, shown failing first with table 8 at `$46`; and the
    transition test named above. The room readout James suggests is Step 14's too.

- [x] Found 2026-09-14; fixed 2026-09-15, Step 14b - Spider ball is non-functional, likely not implemented yet, but is required
  in order to reach the second alpha metroid.
  - Cause: two things, and the second hid the first. The four spider poses `$0B`-`$0E` had no
    handlers (Step 11 deferred them to Phase 1), **and** the Down arm that enters the spider tested
    the wrong bit. Every Down arm into the spider -- the ball at 00:$1788, the falling ball at
    00:$1254, the jumping ball at 00:$17A8 -- is `BIT 5,A`, Spider Ball's; the port read
    `!ITEM_SPRING`. While Phase 0a's `!ITEM_SPRING` was the wrong value ($20) the arms tested the
    right bit under the wrong name; Step 11's mask fix corrected the value and made all three wrong.
    On the cart, Down in the ball with Spider Ball held did nothing at all.
  - Measured first, on the recording, 68 440-72 975: 1 151 frames of `$0B` and 229 of `$0E`, seven
    entries from the ball's Down and seven exits on A, one upward door crossed while rolling (71 100),
    and no `$0C` or `$0D`. All four are ported anyway: `$0B` and `$0E` branch into `$0C` the moment
    the ball loses contact.
  - Guarded by: `snes boot` phase 25 -- entered only with the bit (233, 234), both bottom corners on
    a floor (235), a pixel a frame on one axis (236), the pad and A leave it (237), and a fall or a
    jump onto a floor attaches (238). Shown failing first: the Spring Ball arm reports 234, and the
    unported dispatch 78. Fault sweep: ungated 233, two pixels 236, pad release ignored 237, attach
    keeping the arc 238. Dropping the corner rotation in `SpiderContacts` is **not** caught there,
    because on a flat floor the bottom midpoint sets the same bits; the climbs are the recorded
    rung's.

- [x] (found and fixed 2026-09-15, Step 14b) **Pose `$12` ran `$11`'s handler and skipped two arms of
  its own.** The dispatch sent the bombed ball to `PoseBombed` on the reading that only the draw
  differs. The pose table says `$12` is 00:$0ECB and `$11` is 00:$0F6C, and the 44 bytes between
  are Down into the spider with Spider Ball held and Up out of the ball with the unmorph-jump window
  opened -- then a jump into `$11`'s body. Found reading the pose table for the spider's entries.
  Expected: a bombed ball can unmorph and spider like a hurt one. Fix: `PoseMorphBombed`.
  - Guarded by: `snes boot` phase 25, code 239 -- `$12` with Down on its own frame must be `$0C` on
    that frame. Shown failing with the old dispatch. Its first version passed against the old
    dispatch too, because `$11`'s body puts her in the falling ball and that pose's own Down arm
    reaches the spider a frame later; the check was tightened to the frame before it was trusted.

- [x] (found 2026-09-14 by James playing the cart, fixed 2026-09-15, Step 17) **Samus was not
  drawn at all for the frames of a room transition, and every byte that says where she is on the
  screen held its value from before it.** Symptom, in the order it was reported: she looks stuck
  on one side of the screen during the scroll and snaps back when it ends; and on a later
  playtest, plainly, "her sprite disappears during the scroll animation". Expected: the sprite
  tracks the scroll, as the Game Boy's does.
  - **The mechanism, and it is one call.** The play handler's skip at 00:$0522 covers the Samus
    block and jumps to $053E, and everything from there runs -- `drawSamus` included, because it
    is at 00:$0550, *past* $053E. `.transitionFrame` reproduced $053E, $0541 and $0544 and then
    jumped to the projectiles, dropping `DrawSamus`. It is the only writer of `!OnscreenX` and
    `!OnscreenY`, so for a whole crossing those held the pre-transition value; and `!OamIdx` is
    zeroed at the top of every frame whether or not the branch is taken, so `ClearUnusedOam` hid
    the slots nothing had appended and she was not in OAM at all.
  - **The engine's own comment asserted the opposite and was the reason nobody looked.**
    `main.asm`'s note on the skip read "the pose machine and the draw with it". The pose machine
    is skipped; the draw is not. Corrected in place.
  - **Measured before the fix, off the Game Boy, not argued from the addresses.** Across the any%
    run's vertical crossing at frames 1387-1420, `$D03B` -- the on-screen Y `drawSamus` leaves
    and the sprite collision reads -- moves on every single frame: 122, 120, 117, 115 ... 37, and
    reverses at 1421 when she walks. `zig build tas -- any 1430 1 watch:D03B,D03C` reproduces it.
    The `watch:` facility was added for this and writes beside `tas.Sample` rather than into it,
    so no rung's columns changed.
  - Fixed: `jsr DrawSamus` restored to `.transitionFrame`, before `DrawProjectiles`, which is the
    original's order (00:$074C, $0741, $0742).
  - Guarded by: **`snes boot` phase 27**, the first thing in this repository to let a transition's
    scroll run at all -- phase 8's `emu.write(RAM_TRANSDIR, 0, wram)`, commented "the scroll is
    not what this phase grades", is why it had never been graded. Shown failing first: with
    `jsr DrawSamus` removed the phase exits **121, "was not drawn at all: nothing was composed
    into OAM"**, which is `checkSprite`'s own code and the reported symptom exactly.
  - **And it moved a gate number.** `reachable` went **1466 -> 1999 of 1999** on the fix: the port
    now survives the whole offered window of the any% run. `!OnscreenX` is what
    `HandleCamera`'s horizontal door triggers read, so a stale one was breaking the crossings
    downstream of the first.

- [x] (found 2026-09-14 by James playing the cart, **closed 2026-09-15 on playtest evidence**,
  Step 17) **An enemy that scrolls onto the screen during a crossing lands a hit that is cashed
  the moment the player gets control.** Reported as: she takes damage and is knocked
  back as soon as control returns. The report's own proposed fix -- "enemies should not have
  collision/active hurtboxes until after the transition is complete" -- is a hypothesis about the
  original and has not been measured against it.
  - **Why Step 17's fix is expected to have addressed it, and why that is not a claim.** The
    enemy collision reads `!OnscreenX`/`!OnscreenY`, which were frozen for the whole crossing, so
    hits were being computed against where she had been; `HurtSamus` runs only outside a
    transition and so cashes a flag set during one on the first frame after. With the draw
    restored those bytes now move every frame. **No fixture has been run for this**, and the
    cash-on-handover ordering is faithful on its own -- the Game Boy skips `hurtSamus` across a
    crossing too -- so what is unverified is whether the spurious *collision* is gone.
  - Fixed: incidentally, by Step 17's `jsr DrawSamus`. The enemy collision reads `!OnscreenX`
    and `!OnscreenY`, which had been frozen for the whole crossing, so hits were computed against
    where she had been; `HurtSamus` runs only outside a transition and so cashed the flag on the
    first frame after. With the draw restored those bytes move every frame. **That is the
    inference; the evidence is the playtest.**
  - **Guarded by: playtest only, and closed on James's explicit call 2026-09-15.** Found by
    hand, could not be reproduced by hand after the fix, closed by hand, to be reopened if it
    recurs. Written plainly rather than dressed up as a rung, because it is the one closed entry
    in this file whose guard is a person: a change to `.transitionFrame`'s call list or to the
    draw order could bring the hit back and nothing in the gate would notice. `snes boot`
    phase 27 already owns a live crossing, so an enemy on the incoming screen and one assertion
    about health and knockback at handover is the cheap way to fix that if it ever matters.
    Step 25's fault run over `snes boot` is where it would otherwise surface.

- [x] (found 2026-09-14, closed 2026-09-16 by hand) On vertical screen scrolling, if samus shoots
  toward the transition on the same frame that the transition starts, the bullet will be dragged
  across, and it looks like a long bullet. See recorded movie
  `../reference/vertical_screen_scroll_shot_drag.mmo`
  The shot should despawn when the room transition starts.
  - **Closed by hand, and nothing was ported for it.** Not reproducible by hand after Step 17's
    `DrawSamus` fix; James asked for it marked fixed on 2026-09-16. This is the second entry in
    this file whose guard is a person, after the transition-hurtbox half of Step 17 above.
  - **The candidate mechanism, unverified and written down so it is not re-derived.**
    `.transitionFrame` does call `DrawProjectiles`, and 01:$5359's four window compares free any
    slot outside the play window -- taken against `DeriveScroll`'s scroll, which moves on every
    frame of a scroll. A live shot therefore is despawned during a crossing, so the reported
    "long bullet" is more likely what OAM held than what the array held, and Step 17 moved which
    OAM slots a crossing composes into by restoring `DrawSamus` ahead of `DrawProjectiles`.
    Nothing was measured to confirm this.
  - Guarded by: playtest only. Reopen if it recurs; the recorded movie is the fixture's starting
    point and `snes boot` phase 27 already owns a live crossing to hang it on.

- [x] (found 2026-09-14, closed 2026-09-16) If the player leaves the screen while an active
  metroid is present and comes back, the metroid will not respawn and the metroid is gone
  forever.
  **Closed on James's playtest, and nothing was ported for it on the day it closed.** He
  activated an encounter, left the screen, came back and the Metroid was still there; killing it
  then ran the death cutscene, decremented the counter and started the quake. The cart he played
  is **byte for byte** the cart that carried the report -- `engine/engine.bin` is unchanged --
  so the fix landed in an earlier step and this entry's work was to find out which and to guard
  it.
  - **The step that fixed it, and the reasoning rather than a measurement of the old cart:
    15a** (2026-09-15, `b63013d`). `ResetEntities`' own note says what the engine used to do:
    "until then the saved half was filled at boot and carried across every bank", with no
    out-pass and so **no translation of `$04` to `$FE`**. Put that together with the walk, which
    loads a record only at a flag of `$FE` or above: a Metroid that has been *seen* carries
    `$04`, a crossing empties every slot without publishing a translated flag, and the flag then
    sits at `$04` with no slot -- loadable never again, and in the saved half, so no room load
    clears it. It needs the Metroid to have been seen and it needs a door, which is exactly the
    repro James gave when asked: **"through a door"** and **"it was fighting"**. Nothing here was
    measured on a pre-15a cart; the dates, the note and the mechanism agree and that is what is
    claimed.
  - **And it is now guarded, shown failing first.** Delete `$04`'s translation to `$FE` from
    `ResetEntities` -- the pre-15a behaviour -- and `enemy reload`'s **`alpha2 reset`** case goes
    red: 11 of 134 passes, the Game Boy's record coming back at flag `$04` and the faulted
    cart's at `$01`. `alpha reset` and `crawler reset` stay green under the same fault, and that
    is the useful part: the hatching Alpha in that case never leaves its intro, so its flag is
    `$01`, and the crawler's number is in the unsaved half. **The case that guards this is the
    one whose Metroid has been seen**, which is the one the report describes.
  - **One hole in the fixture was found this way and is worth knowing.** The out-pass is skipped
    while `previousLevelBank` is zero (02:$419D) and it is zero until a reset sets it, so a case
    that fired *one* reset graded the load-in against a boot-filled buffer and passed with the
    translation deleted. Every reset case fires two: the room the player came from, then the one
    whose flag has to survive.
  - **What a Metroid has that an ordinary enemy does not**, which is why the entry names
    Metroids and is the frame for everything below: a spawn flag's index is the record's spawn
    *number*, the ROM's fifteen Metroid records are numbers $40-$56, and $40 is where the
    **saved** half of the flag array starts. A room load refills the unsaved half with $FF
    (02:$418C) and the saved half only round-trips through its bank's window in `$C900`. So a
    wrong flag for a Gullugg is gone at the next door and a wrong flag for a Metroid is forever.
  - **Ruled out, by measurement, on the Game Boy and on the cart together.** A new rung,
    `enemy reload` (`src/enemy_oracle.zig`, six cases), drives the camera off an enemy and back
    on both machines to the same schedule and compares whether the *record* is live again and
    under which flag. All six agree pass for pass, and each faulted cart differs:
    - the **despawn window** (02:$452E), the **delete for good** ($4464) and the
      **reactivate** ($44C0);
    - the **walk's reload** (03:$4014) after the delete -- the record comes back on the cart
      exactly where and when it comes back on the Game Boy;
    - both Metroids in the slice (numbers 65 and 72, saved half) and an ordinary enemy (unsaved
      half) as the control;
    - and the **room reset a transition asks for** (`!SpawnReload`, 02:$418C plus $4217) fired
      while the record is live and off the screen, which is the step of a crossing that decides
      whether the flag survives. Flag $01 and flag $04 both come back.
  - **The repro, from James on 2026-09-16**: he left **through a door**, and the Metroid **was
    fighting** when he did -- which is what pointed at `$04` and at the translation above.
  - **What no rung covers even now**, left here rather than in a closed step's prose: a real
    **crossing** (the rung fires the reset request, not a door script -- the original's
    interpreter blocks for ninety frames and the lockstep harness cannot follow it, so this
    wants a `snes boot` phase beside 27, which already owns a live crossing); a **cross-bank**
    crossing, where `SpawnWindow` picks which of the seven $40-byte windows is written and read
    -- the out-pass goes under `previousLevelBank` and the in-pass under the room's own bank,
    they agree inside one bank and the rung proves it, and **Metroid numbers repeat across
    banks** (73 is a Metroid in both `$B:$66` and `$E:$07`), where `$02` is the one value that
    never reloads; and a **save or load** between the two halves of the trip, which puts
    `SaveEnemyFlags`' own translation ($04 as $FE, and unlike the room reset's copy *not* $05)
    between leaving and coming back.
  - **And one thing the measurement found that is not this bug**, written down because the next
    reader of `HandleEnemies` will hit it: the port's `!SpawnReload` stands in for **two**
    Game Boy bytes. `$C44B` (`loadSpawnFlagsRequest`, raised by the door interpreter's end at
    00:$26D7) gates the flags-and-slots reset at 02:$4069, and `$D09E`
    (`justStartedTransition`, raised $FF by the door trigger at 00:$0C63) gates the
    fight-ending arm and the collision clears at 02:$4009. The engine's comment at
    `HandleEnemies` says both are raised by 00:$0C37; that is wrong, and it is corrected in
    place. A crossing raises both, so the merge holds in play -- measured: with only `$C44B`
    raised on the Game Boy the cart ends a Metroid fight the Game Boy does not, and with both
    raised the case is green.
  - Guarded by: `enemy reload`, six cases -- and specifically `alpha2 reset` for the flag
    translation this bug was, shown failing against the pre-15a behaviour. Not guarded: a real
    crossing, a cross-bank one, and a save between the halves.

- [x] Found 2026-09-14 - Of the two types of room transition animations, the fade animation also
  combines the scroll animation. It should just do the fade as intended, with the screen fading out
  from one screen and fading in on the new screen with samus in position.
  - **The Game Boy scrolls too -- in the dark.** Measured with `zig build tas -- any 900 1
    watch:D07E,D09B,D08E,FFC8,FFC9,FFCA,FFCB` on door $1DF: `bg_palette` $E7 from 613, $FB from
    629, $FF from 645; the warp at 703; the camera walking $3B0 to $44C at four pixels a frame over
    707-746 with the palette still $FF; `.endDoor` (00:$0C2B) setting `fadeInTimer` to $2F at 747;
    `fadeIn` (01:$7A45) stepping $FB, $E7, $93 from 748. What the player sees is exactly the
    report. The port had no palette fade (B1b's deferral): it forced blank for the script and
    lit the screen at `END`, so the scroll the original hides was on screen.
  - Fixed (Step 20): `FADEOUT` steps `!BgPalette` on its wait frames and lifts the blank for them
    (nothing reaches VRAM until it returns), the script's end applies the palette instead of full
    brightness, `TransitionCamera .finish` sets `!FadeIn`, and `FadeInTick` runs the fade in from
    `miscIngameTasks`' position. The palette becomes INIDISP brightness 15/10/5/0 -- **our
    substitution**, stated in `oracle.brightnessFor` and `ApplyPalette`. The camera is unchanged.
  - Not covered, until Step 24b: the four hold frames before the fade and every script frame at
    $93 showed a forced blank on the cart, and the rung did not grade them. Both are graded now.
  - Guarded by: the `fade` rung (`zig build oracle -- fade`), shown failing on the pre-port cart
    (movie 613) and against a cart that lights at the script's end.

- [x] Found 2026-09-14, closed 2026-09-24 - Some doors are opened by shooting them with 5 missiles. These doors work
  as expected, but the door itself is invisible.
  - **Drawn, onto blank characters.** On the `missileDoor` oracle cart ($E:$6A) the door's
    twelve objects are in OAM, tiles `$F4`-`$F6`, and those characters were all zero in the
    object half of VRAM. `$F0`-`$FF` is where `gfx_commonItems` goes: to $8F00, by 00:$05FD on
    every boot and by `COPY_DATA` in three door scripts. $8F00 is inside the window the Game
    Boy's background and objects share, and `snes_convert.convertOp` split a copy there in two
    only for `spr`. So the common items reached the BG characters and never the object ones.
  - Fixed (Step 21): the split is now decided by the destination (`target.inSharedWindow`),
    so a `COPY_DATA` there converts to an `obj` copy plus a `bg_twin`, neither of which carries a
    source. The `obj` half is charged, at the same `len` the `bg` copy was, so no duration moves.
    `gfx_commonItems` gets a 4bpp asset on the `shared_window` basis. The load table's common
    entry is two copies (`!LS_FONT` 24, `!LS_ENTRIES` 46). **A second defect underneath:** a new
    game replays its record's door script and never ran 00:$05FD, which the Game Boy runs on a
    new game too, so `BootGraphics` now calls `LoadCommonItems` on both paths.
  - Also the invisible Missile Tank (closed by Step 23 from the ROM's metasprite table) and
    probably the refill orbs below, which draw from the same sheet.
  - Guarded by: the `load` rung's code 174, the ROM's `gfx_commonItems` at 4bpp against the
    object characters on a load and on a new game, shown failing on all three of the rung's
    runs before the fix; and `snes_convert`'s "every copy into the shared window writes the
    object characters too", shown failing on the door stream.

- [x] (found 2026-09-15, fixed 2026-09-24, Step 22) Found 2026-09-15 - After the shaking animation after killing alpha metroid 1, the acid in the
  next section doesn't drop. Also, acid does not damage samus.
  - **Two defects, and neither is the quake.** The quake (08:$7EBC, bank 1's countdown,
    01:$79EF) writes `scrollY`, its two timers and the song bytes and nothing else. The acid
    moves when a door's `IF_MET_LESS` picks the next table. Step 14's fix made the drop happen,
    and the entry below is why it dropped to the wrong level.
  - The damage: bit 4 of a collision byte is `blockType_acid` and $D062 is `acidContactFlag`,
    which the engine called `!BLOCK_SPRING` and `!Springboard`, from reading the bit as a block
    that throws the ball. None of the six `applyDamage.acid` calls was ported (00:$1EC5, $1EFA
    top; $1F63, $1FA3 bottom; $1FCC, $1FE4 spider), `CollideTop` never latched the flag, and
    `drawSamus`' acid flicker (01:$4BE8) was missing. All ported: `ApplyDamageAcid` (00:$2F4A)
    and one `AcidProbe` called from each site's position.
  - Measured on the Game Boy, off the any% run (the recording never touches acid): at a damage
    of 2, frames 7376 and 7472 lose 4 and 7392 and 7488 lose 2, every one on a counter of `$x0`.
    Once per probe in acid, every sixteenth frame. James saw the same on 2026-09-24: 4 on the
    first tick after entering, 2 after, and 4 again on re-entry. Falling in, both bottom probes
    read non-solid acid; stood on the solid acid floor, the left probe stops the routine.
  - **Reopened the same day by James: the sound and flicker played and health did not move.**
    A new game booted with `acidDamageValue` at **0**. No boot record version carried $D077 or
    $D078, so `InitState` left them at the WRAM clear, and `applyDamage.acid` subtracted zero
    every sixteenth frame. The Game Boy's `initialSaveFile` has $02 and $08, loaded by
    `loadGame_samusData` on a new game as on a load. The fixture below had forced the value to
    2, so it could not see this. Measured on the shipped cart: `!AcidDmg` 0 after title → new
    game, and 2 after the fix. Spikes had the same zero. Fixed by boot record **version 15**
    (`BootAcid`, `BootSpike`): `initialSaveFile`'s values for a new game, the Game Boy's
    measured $D077/$D078 at a handover.
  - Guarded by: `snes boot` **code 197**, the new-game loadout, now including both damage
    values; shown failing on the version-14 cart. The phase 23 acid step now grades the cart's
    own damage value and stops at 252 if it is zero. And `snes boot` phase 23, **code 252** (a floor of solid acid under her: the flag on
    every frame, exactly one damage on each `$x0` frame and none on the others), shown failing
    with the damage call removed; **code 254** (then 64 pixels of liquid acid over it and a
    drop: 4 on the tick mid-fall, 2 once landed), shown failing with the engine allowed one
    acid call a frame; **code 253** (the flicker), shown failing with the flicker removed; and `correspond`'s constant check holding `!BLOCK_ACID` to 00:$1EC5's
    `BIT 4,A`. Exact per-frame grading against the Game Boy waits on the any% stretch that
    covers those frames becoming bootable (the tileset-assignment entry above).

- [x] Found 2026-09-15, closed 2026-09-24 (Step 23) - Missile ammo upgrades are invisible.
  - **Fixed by Step 21, found by James's playtest after it; nothing in Step 23 changed the cart.**
    The Missile Tank is sprite $99, and its four parts in the ROM's metasprite table (01:$5AB1)
    are tiles `$F0`-`$F3`: the first four characters of `gfx_commonItems`, which 00:$05FD
    copies to $8F00 and which never reached the object characters until Step 21. The
    attribution rests on that ROM fact and on code 174 failing on the pre-Step-21 cart. A tank
    was not measured on screen on the old cart.
  - Guarded by: `snes_convert`'s "the Missile Tank and both refills draw only from the common
    item characters", which ties the three sprites to the range code 174 grades on the cart.
    Shown failing with the Bomb's sprite put in the tank's place. Code 174 is the cart-side guard.

- [x] Found 2026-09-15, fixed 2026-09-24 (Step 24) - The morph bomb upgrade has corrupt graphics. The spider ball upgrade has
  corrupt graphics.
  - **The `ITEM` door opcode moved no graphics.** Its arm (00:$2618-$26D4) makes four
    transfers: `gfx_items` + ((op-1)&$F)·$40 to $8B40 (`$B4`-`$B7`, the item), `gfx_itemOrb` to
    $8B00 (`$B0`-`$B3`, the orb), $230 bytes of the item font to $8C00, and the item's name to
    $9C20. The cart's `.item` only recorded `!ItemGiven`, so every orb and major item drew from
    whatever the room's enemy sheet had left at `$B0`-`$B7`: corrupt rather than blank. It also
    cost 1 frame where the Game Boy's costs 13.
  - Fixed: `snes_convert.itemArm` reads the arm off the ROM; the load table carries its
    transfers (`load_item_at`: orb and font, then two copies per nibble), from two window
    assets (`item_window`, bank 7 $7790-$7B90, and `item_font`, $230 bytes); `.item` runs the
    nibble's and waits `!ITEM_WAIT`, 12 frames plus its dispatch. The name is not ported (entry
    below).
  - Guarded by: `snes boot` phase 28, **code 138**: the Bomb's door ($145) and the Spider Ball's
    ($08D) scripts run, and `$B0`-`$B7` at both depths must be the ROM's orb and that nibble's
    tiles. Shown failing with the transfers skipped and with every nibble reading entry 0.
    **Code 139** if the characters already held the answer. `correspond` holds the table's
    offsets, `!ITEM_WAIT`, and `transition.item_bytes` to the lengths the arm hands $27BA.

- [x] (found 2026-09-24, Step 24; closed 2026-09-25, Step 24g) **`ITEM`'s fourth transfer, the
  item's name to $9C20, is not ported.** 00:$26A0-$26CB copies `item_names[op & $0F]` (16 bytes)
  to the window tilemap's second row. Its frame is charged. What the Game Boy shows it with, and
  when, has not been measured.
  - **Measured and ported in Step 24g** (the entry below): the row is the bar the raised window
    shows, and a save room's `ITEM $D0` writes " SAVE<>" into it. `.item` resolves the name
    through the pointer table (`ItemNameResolve`) and NMI writes it to BG2's second row.
  - Guarded by: `snes boot` **code 3**, BG2's second row after each of phase 28's four doors
    (Bomb, Spider Ball, a sheet door that must leave it alone, and save door $0AE) and at boot.
    Shown failing on the pre-fix cart, and by the fault sweep's `ItemNameResolve`.

- [x] found 2026-09-25 (James, two screenshots), closed 2026-09-25 (Step 24g) - **At a save station the HUD does not rise and no
  text bar appears, and the HUD row is damaged.** On the Game Boy, standing on a station raises
  the status bar a row and shows a black bar under it, `SAVE··` and a blinking `PRESS START` in
  white; a major item shows its name the same way during the jingle. On the cart the status bar
  stayed on the bottom row, and the missile and Metroid icons, some digits and white blocks
  were wrong across it.
  - **Cause, measured** (Step 24g): the window never moved. `rWY` is $80 at a station and in a
    major item's jingle (01:$5824/$582A, 00:$3A1F); the cart recorded the jingle's raise and
    nothing read it, so its HDMA split stayed at WY $88. `PRESS START` is two sprites at OAM y
    $98, which is the bar's line once the window is up and the status bar's while it is not: the
    white blocks were the letters on the status bar, and the raised Metroid icon sat a row above
    it. The bar itself was not there either: BG2's second row was never written, and BG2 had a
    character set of its own the item font never reached.
  - Fixed 2026-09-25 (Step 24g): `!WinY` is the port's `rWY`, written where the Game Boy writes
    it (`SaveStation`, the jingle's loop, the door's transfers, boot), and `WriteWindow` turns it
    into the HDMA split's two counts and BG2's scroll in every NMI. BG2 reads the object
    characters (`BG12NBA` $61), as the Game Boy's window reads $8800-$8FFF, so the font is there
    exactly when `ITEM` has loaded it. `saveTextTilemap` is written at boot and `ITEM`'s name by
    the door (entry above).
  - Guarded by: `snes boot` **code 1** (every frame the play handler runs, `!WinY` against the
    icon's reason, as the pass before left it), **codes 2 and 4** (phase 28: a Bomb jingle after
    save door $0AE, both window rows graded pixel for pixel against the ROM's tiles and font),
    **code 3** (the row). All four shown failing on the pre-fix cart; the fault sweep's
    `WriteWindow` fault fails code 2.
  - **James's playtest on the FXPak, 2026-09-25: passed** at a save station and at a major item,
    on cart `db5676e1…6dc0` from `zig build rom` at `a4d3bc7`. **Closed.**

- [x] (found 2026-09-28 by James playing `269f982`, **fixed 2026-09-28**, 1.0 Step 10) **Every
  Metroid but the Queen marked dead on the METROIDS page showed 93 on the status bar.**
  - **Cause:** the status bar's count, `metroidCountDisplayed`, leaves the eight larval
    Metroids out until `enAI_metroidStinger` first runs and adds them (`ADD A,$08`,
    02:$6B92): a new game shows $39 of $47. The larval kill (02:$7B32) takes one off both
    counts, which in the original is safe because no larva can be reached before the stinger.
    The menu's kill took one off both whatever the stinger had done, so all 46 took $39 down
    46 in BCD: $93.
  - **Fixed:** `DebugDispMoves`, from a `debug_larvae` blob built from the ROM (the stinger's
    record, its $08, the larval rows): a larva moves the shown count only once the stinger's
    flag is dead. Every other row, the Queen's included, moves both.
  - Guarded by: the `scenario` rung's **`larvae`**: two larvae killed and one revived from a
    new game leave the shown count at $39, then Metroid 01 takes it to $38. Shown failing (11,
    "disp 38, wanted 39") with `DebugDispMoves` answering "moves" for every row, which is the
    gate's fault for it and the engine James played.
  - Also in James's playtest, and **not defects**: with every Metroid and the Queen dead, the
    missile refill froze the game with only the menu opening. That is the credits branch's
    hold until mode $12 is ported (1.0 Step 22); the ask should have said so. With the larvae
    left alive and the Queen dead, the refill filled and the bar showed 0: the real count was
    8, so the ROM refills, and the shown count was 0 because it had never counted the larvae.

- [x] found 2026-09-15, closed 2026-09-28 (1.0 Step 10) - The health and ammo refil orbs/icons are invisible. They function correctly,
  but do not show up at all. They appear as empty space.
  - Probably fixed by Step 21, like the Missile Tank above, **but not confirmed by play**: the
    energy refill ($9B) draws `$FD` and the missile refill ($9D) `$FB $FC`, both inside
    `gfx_commonItems`, and Step 23's test holds them there. Needs a playtest to close.
  - **1.0 triage (2026-09-26, Step 1):** **Fix in Step 10**, fixture first (C5 closes it).
  - **Two causes, fixed by two steps, neither of them Step 10.** Until 0b Step 21 their
    characters never reached the object half of VRAM (the entry above). After it, a refill
    spent half its frames black: the refills are odd sprite ids, so `enAI_itemOrb` (02:$4DD3)
    toggles their palette bit on the bob frames, 8 frames in OBP0 and 8 in OBP1, and until
    1.0 Step 8b (`d80d095`) OBP1 was loaded at colour $84 and object palette 1 was black on
    the black play field. Measured on the unfixed engine at `$F:$10`: 0 of the energy refill's
    164 coloured pixels shown on its OBP1 frames, and every pixel on its OBP0 frames, before
    and after the Alpha is killed from the menu.
  - Guarded by: the `warp` rung's **`refills`** scenario (`src/warp_grade.zig`): `$F:$10`'s two
    refills, warped to through the menu, for 64 frames after each warp and after the Alpha's
    kill, must be in OAM with the ROM's metasprite parts (38), every pixel their characters
    colour the shade OBP0 or OBP1 gives it (39), and blink into palette 1 (40). Shown failing
    (39) with OBP1 put back at $84, which is the gate's fault for it. Graded against the ROM's
    parts, characters and palettes, not a Game Boy frame: our GB PPU draws no objects.

- [x] (found 2026-09-22, fixed 2026-09-25, Step 24f) found 2026-09-22 - The audio is unbelievably loud. It could blow speakers if the sound is turned up,
  and it is uncomfortable unless the sound is turned down to 10%.
  - **One scale, about 11 dB.** Against SameBoy's render of the same writes, every sound in the
    slice was 3.3-4.0x the Game Boy's RMS (10.4-12.0 dB), songs and effects alike, with the
    cart's peaks on the rail. Mesen2's own GB core is about 4.6 dB quieter than SameBoy (from
    its source), so in Mesen2 the gap was nearer 15 dB. The shim's per-voice full scale was
    127 and `MVOL` $7f, kept on 2026-09-21 for clipping, not for level.
  - **Fixed 2026-09-25 (Step 24f), in snes_game_dev `3924c36`:** full scale 127 → 64
    (fifteen-bit noise 96 → 48), which keeps four voices off the S-DSP's clamp, and `MVOL`
    $7f → $46, set from the renders. The set now reads −0.0 dB, every case within 0.3 dB, and
    no sample near the rail.
  - **Guarded by the gate's `audio level` rung** (`src/audio_level.zig`; by hand,
    `zig build audioab -- level`): eight of the slice's sounds, the set within ±1 dB of the
    Game Boy and each within ±2 dB. It read +11.0 dB and failed on the pre-fix shim. Not run
    where `vendor/sameboy` is absent.
  - **Closed by James's listen on the FXPak, 2026-09-25:** "The sound is good, and requires no
    adjustments when going between different games." Cart `516eb45d…acee0` from `003fe79`.

- [x] (found 2026-09-22, fixed 2026-09-24, Step 22) found 2026-09-22 - on screen B The acid levels are too high prior to any metroids being defeated.
  see screenshot `~/Desktop/acid levels bug.png`
  After killing the first metroid, the port lowers it to where it is supposed to be pre-metroid kill.
  see screenshot `~/Desktop/acid levels bug post metroid kill.png`
  Also there are incorrect acid levels on A:00 `~/Desktop/acid levels bug post metroid kill 2.png`
  Another screen: `~/Desktop/acid levels bug post metroid kill 3.png`
  Another screen A:08 `~/Desktop/acid levels bug post metroid kill 4.png`
  Another screen A:09 `~/Desktop/acid levels bug post metroid kill 5.png`
  Another screen B:13 `~/Desktop/acid levels bug post metroid kill 6.png`
  Another screen C:E1 `~/Desktop/acid levels bug post metroid kill 7.png`
  - Cause: `screens.tiletable_order` put `TILETABLE` 6/7/8 in layout order, Mid/Empty/Full. The
    ROM's `metatilePointerTable` (08:$7F1A) says **Empty/Full/Mid**. The cart's `TileTableBases`
    are built from that list, so the no-kill table 8 drew Full where the Game Boy draws Mid,
    and table 6 after a kill drew Mid where the Game Boy draws Empty. One level high on both
    sides of the kill, as in every screenshot. Collision is read from the drawn tilemap, so the
    acid was in the wrong place as well as the wrong picture. This is the same mistake the
    collision tables had until 2026-09-08. The graphics-pairing test could not see it, because
    all three lava tables go with the same graphics.
  - Found on the way: the load's `!META_PTRS_N` was 8 against ten pointers, so a save made in a
    room on table 8 or 9 reached `Fatal` on load. Now 10.
  - Guarded by: `screens`' "a TILETABLE operand selects the table the ROM's pointer table
    names", which failed at operand 6 (`$5480` against the ROM's `$5594`); `snes boot` phase 23
    **code 227**, each gate door's incoming edge against its room expanded through the table the
    ROM's pointer names (`screens.metatileTable` now resolves through the pointer, not the
    list), exit 227 on the pre-fix cart; and `correspond`'s "the load searches every pointer
    the two pointer tables hold", which fails at 8.

- [x] found 2026-09-24, fixed 2026-09-24 (Step 24) - The spring ball functionality has been bundled into the spider ball upgrade.
  Spring ball is supposed to be a separate upgrade, obtained in a different location.
  - **Bundled with the Bomb, not the Spider Ball.** `PoseMorph`'s A jump tested `!ITEM_BOMB`,
    where 00:$1727 is `BIT 4,A`, Spring Ball's bit. So the ball jumped on A from the moment
    the Bomb was collected, which in the slice comes before the Spider Ball. `snes boot`
    phase 10 graded the same wrong rule. The pickup arms were right.
  - Guarded by: `snes boot` phase 10, now three tries: `!Items` cleared (147 if it jumps),
    the Bomb alone (**148** if it jumps), and the Bomb with Spring Ball's bit, read out of the
    cartridge's pickup arm (146 if it does not). Exit 148 on the pre-fix engine.

- [x] (found 2026-09-24, Step 22; **fixed 2026-10-02, 1.0 Step 25**, with the entry below)
  `drawSamus_common` sets the sprite attribute (`hSpriteAttr` = 1)
  while `acidContactFlag` or `samusInvulnerableTimer` is set (01:$4DFF), which is Samus's
  hurt palette. The port draws her with neither: not in acid and not in i-frames. Found reading
  01:$4BE8's flicker, which is ported; this is the attribute half, and it is older than acid.
  - **1.0 triage (2026-09-26, Step 1):** **Fix in Step 25**, with the flash-palette entry below;
    they are one arm.

- [x] found 2026-09-24, fixed 2026-09-25 (Step 24e) - There are some layering issues. Namely, samus is on a layer in front of the
  ship in the rom, but in the gameboy she shows up behind the ship. The same happens with opened
  door shells. Samus walks in front of the doorway, but should walk behind it.
  - **A per-screen rule, not a per-sprite or per-door one.** 00:$3ED5 reads bit 11 of the
    transition word of Samus's screen and stores it inverted in $D057; `drawSamusSprite` sets
    OAM bit 7 on every part while $D057 is 0 (01:$4BA1), and `drawSamus` zeroes it after
    (01:$4E18). Measured on our Game Boy at the ship (`$F:$76`): 12 of 12 parts behind; on a
    bank-9 screen 0 of 11; at the ship with the bit patched out, 0 of 12. The slice's bit-set
    screens are `$F:$5D $5E $75 $76 $FE` and `$B:$38`-`$3B`. A door frame goes in front of her
    only on those, as on the Game Boy
  - **The cart missed it twice.** `DrawSamus` never read the bit, and no BG3 word had tile
    priority 1, so in mode 1 even OBJ priority 0 drew over the play field. Now every play-field
    word carries it (`snes_target.play_priority`, the engine's `!PLAY_PRI`), `LoadScreenPri`
    ports $3ED5, `DrawSprite` ports $4BA1, and the HUD icon's store at $4B4F is back. The save
    text and bombs draw before her, while $D057 still holds the icon's 1, so they stay in front
  - Guarded by: `cold boot` **code 155**: during the appearance sequence, wherever the ship's
    colour index is not 0 inside her parts, the drawn frame matches the blank one before it
    (exit 155 on the pre-fix cart; 156/157 if the pair grades nothing). `snes boot` **code 20**,
    every frame the 124 check runs: her OAM priority is 0 where her screen's word has bit 11
    and 2 elsewhere (a cart faulted to put her behind everywhere exits 20). `room.zig`'s "Samus
    goes behind the background on the screens whose transition word has bit 11" measures the
    Game Boy, and `correspond.zig` pins the three sites' bytes and `!PLAY_PRI`

- [x] (found 2026-09-25, Step 24e; **fixed 2026-10-02, 1.0 Step 25**) **Samus's damage and
  acid flash never changes palette.**
  `drawSamusSprite` sets OBP1 on every part while `hSpriteAttr` is non-zero (01:$4B95-$4B9D),
  and `drawSamus_common` sets that for acid contact or i-frames (01:$4DFC-$4E0D). The cart's
  `DrawSprite` has no such arm; `!SprAttr` exists only for the projectiles. So her flicker
  while hurt or in acid is right and the palette swap is missing. Not measured on the frame yet
  - **1.0 triage (2026-09-26, Step 1):** **Fix in Step 25**, fixture first.
  - **2026-09-28, 1.0 Step 8b:** the arm alone would have flashed her black. Object palette 1
    was empty until then (OBP1 was loaded at $84, not $90; see the frozen-enemy entry).
  - **Fixed** (1.0 Step 25): `DrawSamus` sets `!SprAttr` to 1 in acid or i-frames and clears
    it after the draw (01:$4DFC-$4E10); `DrawSprite` puts every part on OBP1 while it is
    non-zero (01:$4B95). Both halves of the entry above.
  - Guarded by: the `beams` rung's `hurt` segment, **code 253**: on every frame, the objects
    on the second palette are counted on both machines (the Game Boy's OAM buffer up to
    `maxOamPrevFrame`, the cart's shadow on palette 1). The unfixed cart parts on frame 9,
    the hit; `DrawSamus_hurtAttr` and `DrawSprite_pal1` taken out fail it the same way. And
    `snes boot` **code 149**: her first part is on palette 1 exactly while acid or i-frames
    were set when she was drawn; `DrawSamus_acidAttr` taken out fails it in phase 23's acid.

- [x] found 2026-09-25 (James, three screenshots), fixed 2026-09-25 (Step 24h), closed
  2026-09-25 by James's FXPak playtest of `87d1396` (title, menu and a clear of slot 0) - **The
  title shows the logo and nothing under it.** The Game Boy's has a pulsing
  cursor beside `START 1` and `©1991 Nintendo` on row 16; the cart's copyright row is a few
  dashes, and there is no menu.
  - **Cause, measured** (Step 24h): three defects of different ages, and a missing feature.
    *The copyright row* is a Step 24g regression: `!WinY` is zero on the title, because
    `InitState` seeds it after `TitleScreen`, and NMI's `WriteWindow` turned that into line
    counts `$81` and `$90`. Both have bit 7 set, so HDMA fell into repeat mode and BG3 went off
    from window line 128 (the band table read `28 00 | 7F 14 | 81 14 | 90 12` off a Mesen
    probe; BG3's row 16 words were right). *Row 17* has shown BG2 since Step 13b, where the
    Game Boy's title has the window off (05:$40C8 `LD A,$C3`). *The whole title* has sat a line
    higher than the Game Boy's since Step 7: `!CamY` was `!CAM_MIN_Y+1` for the PPU's extra
    line, which `!SCROLL_Y_BIAS` already carries; the GAME OVER screen copied it. *The menu*
    was never ported (B2 left it out).
  - Fixed: `TitleScreen` sets `!WinY` to 05:$40C0's `$88` and the band's window lines to BG3
    before NMI runs, and puts the band back on the way out; both cameras use the clamp;
    `TitleFrame` and bank 1's `TitleDraw` port `titleScreenRoutine`'s menu, Select, Down and the
    clear; the converter twins the title's first sheet into object characters $80-$FF, as the
    Game Boy's copy to $8800 does. B14's three slots are Step 24i's.
  - Guarded by: the **`title` rung** (codes 92-99), graded against our Game Boy running the same
    pad script (`title_oracle.zig`): rows 16-17 pixel for pixel (93), the menu's characters
    (94), the state bytes (95) and the menu's OAM (96) on every frame, the slots after the clear
    (97), a new game after it (98) and Start's frame (99). The pre-fix cart fails 93, 94, 95,
    96, 97, 98 and 99. `death` **code 193**: the title after a death opens as a cold boot's.

- [x] (2026-09-27, 1.0 Step 2a) Found 2026-09-25 - Implement the basic pause feature in which pressing "Start" will pause the game
  when the player is not standing on a save point. Currently pressing start when not on
  a save station will do nothing.
  - **1.0 triage (2026-09-26, Step 1):** **Fix in Step 2.** Game mode $08 (`gameMode_Paused`,
    00:$2CED) is not ported, and the debug screen opens from it, so it lands first. Fixture first.
  - **Fixed by porting it.** `tryPausing` (00:$2C79) is the play handler's last call on its
    normal, transition and item-end paths (`TryPausing`, bank 1), and mode $08 is `!Paused`, for
    which `MainLoop` runs `PausedFrame` in place of the play handler. What the player sees: the
    screen flashes dim and bright every 16 frames, Samus and the enemies stop, the music stops
    with the pause sound, the status bar's Metroid count becomes the area's L counter, and the
    Metroid icon beside it becomes `L`. Start again (with anything else held) resumes with the
    unpause sound. Facing the screen, on a save pillar, in a door's scroll and in the Queen's
    room, Start does not pause, and Start pressed together with another button does not either.
  - **Guarded by:** the **`pause` rung** (codes 110-120), our Game Boy and the cart through the
    same pad script from a cold boot's new game, pass for pass. Shown failing on the unfixed
    cart before the fix: 118 at frame 2 (the flicker, the counter below), then 120 at frame 0
    once the counter was graded first. Six engine faults, each caught by its own code.
- [x] (2026-09-27, 1.0 Step 2a) **Found by the `pause` rung: after the title, the cart's frame
  counter is not the Game Boy's.** The Game Boy's `frameCounter` ($FF97) is cleared at power-on
  and never again, so a new game or a load inherits the title's count; `InitState` reseeded the
  cart's to the boot record's zero. At the first frame of a new game started on title frame 6
  the Game Boy's counter reads 9 and the cart's read 2. What that moves, player-visibly and
  small: which frames Samus flickers on as she appears, the walk's one-or-two-pixel
  alternation, the beam's 30 Hz terrain checks, the acid's bite frames, and the pause's flash.
  - **Fix:** through the title the seed is the title's count plus `!TITLE_FC_LEAD` (1): the Game
    Boy takes three passes of `mainGameLoop` from the title's Start to the first frame of play
    (modes $0B or $0C, $02, $03) and the cart two NMIs. `!FrameSeed` keeps what was seeded, for
    `MainLoop`'s first-frame phase check. A handover record's measured seed is unchanged.
  - **Guarded by:** the `pause` rung's **code 120**, checked first on every frame; the unfixed
    cart fails it at frame 0 (2 against 9), and the fault `InitState_titleLead` fails it.

- [x] (2026-09-27, 1.0 Step 5c) **Found by the `warp` rung: a morph-ball warp arrives with a
  hop.** Of the 160 warps, the ball entries (items in tunnels) came in as a ball and went into
  `ball_jump` ($06) for a few frames before settling back on the spot. `DebugWarp` puts her at
  rest -- pose, jump arc, fall arc, invulnerability -- but left `!DownSpeed` as the room before
  had it, and `.roll` bounces a ball whose down speed is 2 or more (00:$1747).
  - **Fix:** `DebugWarp` clears `!DownSpeed` with the rest.
  - **Guarded by:** the `warp` rung's **code 25** (she moved in the second after arriving); on
    the unfixed cart five of its eight runs failed it at their first ball entry.
  - **Playtest (James, 2026-09-27):** a ball warp on `m2snes-debug.sfc` sits still.

- [x] (2026-09-27, 1.0 Step 5c) **Found by the `warp` rung: a warp to a Metroid in a blank cell
  drew the blank cell.** Two Metroid records ($D:$23, $B:$57) sit in cells drawn with the
  shared blank screen, and the warp table stands Samus in the drawn cell beside
  (`warp.drawnCell`). `warp_data` carried the record's cell, and `DebugWarp` loads it as
  `!Cell`: `LoadScreen` drew the blank cell's screen and `LoadCellFlags` took its scroll
  flags, while the camera was in the cell beside. The next frame's `LatchCell` moved `!Cell`
  to the camera's cell and re-read the flags, but not the screen.
  - **Fix:** `warp_data`'s cell is the camera's (`debug_tables.warpCell`), which is what
    `LatchCell` would latch.
  - **Guarded by:** the `warp` rung's **code 20**, which reads `!Cell` as the warp left it,
    before the first latch, against the camera's; the unfixed table fails it at both entries.
    `warp_grade`'s unit test holds every entry's warp cell to a cell in use.
  - **Playtest (James, 2026-09-27):** the $D:$23 warp on `m2snes-debug.sfc` draws the room.

- [x] (2026-09-28, 1.0 Step 7) **Found by the `loadout` rung: the segment oracle seeded the
  cart's frame counter 2 high.** The Hi-Jump segment is the first to hold A through a jump
  start, whose rise is `$FE - ($FF97 & 2) >> 1` (00:$19E8), and it diverged at the start's
  first rise, 2 pixels where the Game Boy rose 3. It diverged the same way with the item poked,
  so the menu was not the cause. Measured: the Game Boy's logic at frame g reads the $FF97 the
  reference records at g, less one; the cart's pass for frame g reads its seed plus g plus one.
  So the seed is the record less two, and `gradeWith` used the record. Every segment until
  now read bit 0 only (the walk's speed), where 0 and 2 agree, which is also why the
  measurement in `frameCountSeed`'s comment could not tell.
  - **Fix:** `oracle.segment_counter_lead`, 2. The movie's lead stays 1: with 2 more, the
    movie falls from 1998 frames to 136 and `anchored` from 665 to 155.
  - **Guarded by:** the `loadout` rung's `hi_jump`, which fails at frame 12 with the old seed.
    The segment (700) and the spider segment (847) still match every frame.
  - **Not the engine's.** No cart changed. The enemy oracle's own seed (`enemy_oracle.zig`,
    lead 0) is a different reference, stepped per pass, and its rung agrees pass for pass.

- [x] (2026-09-28, 1.0 Step 7) **Found building the `loadout` rung: the bisection and the
  pixel-fault sweep re-ran the cart without its setup.** `pinExact` and the sweep built their
  takes with `Take.of`, which drops `pokes`, so a spider segment that ever diverged would have
  been pinned by runs without Spider Ball. With the menu's setup it showed at once: the
  bisected script had no setup, and the frame it named was wrong.
  - **Fix:** `Take.over`, which changes the reference and keeps what the cart is given.
  - **Guarded by:** the unit test "a take over another reference keeps what the cart is given
    before it".

- [x] Found 2026-09-26, closed 2026-09-28 (1.0 Step 10) - When entering metroid room F:10 and killing the metroid, the
  ammo and health refill blocks are not visible. Then after leaving the room and
  returning they are then visible. They should always be visible.
  - **1.0 triage (2026-09-26, Step 1):** **Fix in Step 10**, fixture first, with the invisible-orb
    entry above. $F:$10 is the hatching Alpha's cell (roster #44).
  - this is fixed now, as a result of fixing the visibility of frozen enemies during
    the 1.0 cycle.
  - **Attributed to 1.0 Step 8b's OBP1 fix (`d80d095`)**, the entry above: the refills blink
    into object palette 1, which was black. The `refills` scenario grades them in this room
    after the Alpha is killed, and fails on the unfixed engine. **Not reproduced: the "until
    re-entry" part.** The scenario kills the Alpha from the menu, not in a fight, and on the
    unfixed engine the refills blinked black the same way before and after that kill. What a
    fought kill did differently was not found; James's playtest after `d80d095` is the
    evidence that it is gone.

- [x] Found 2026-09-26, closed 2026-10-02 (already fixed) - Items/pickups that flash do so by toggling full visibility and
  completely invisibility. The original game does flashing by toggling full visibility
  and one shade darker. A similar functionality is seen when the game is paused. In the
  original during pause the screen flashes, toggling full vis and everything being one
  shade darker. In the built rom the game just stays the same visibility during pause.
  - **1.0 Step 10: the items' half has the refills' cause** (the entries above): an item's
    flash is its palette toggled into OBP1 (02:$4DD3), which was black until 1.0 Step 8b. The
    `refills` scenario now grades that flash in OBP1's shades. **The pause's half** was ported
    in 1.0 Step 2a (`gameMode_Paused`'s flash, graded by the `pause` rung's code 114). Both
    are for James to confirm on hardware before this closes.

- [x] Found 2026-09-27, closed 2026-10-02 (already fixed) - The Ice Beam does not have the correct
  sprite. The sprite looks like the power beam pills, but it should shoot little spikey
  circles. Also, frozen enemies appear black or invisible, so they are hard to see.

- [ ] (2026-09-27, 1.0 Step 5c; **diagnostic only**) **One gate run saw the `pause` rung's
  `DebugClose` fault end in Fatal (110) instead of its code 123.** The runs either side of it
  were green, and the same faulted cart with the gate's own script (`.zig-cache/
  pause-fault-DebugClose.sfc`, `pause-fault-debug_combo.lua`) gave 123 four times out of four,
  alone and beside sixteen other Mesen2 runs. Mesen2 is deterministic on a fixed cart and
  script, so something differed that the run did not record. If it comes back, keep the
  `.zig-cache` cart and script from that run, and the Mesen2 save folder's
  `pause-fault-DebugClose.srm`.

- [x] (found 2026-09-28, 1.0 Step 6, by reading the port against the ROM; **fixed 2026-09-28,
  1.0 Step 8d**) **Samus's landing on an enemy lifts her out of the wrong enemies.**
  `collision_samusEnemiesDown` (00:$348D) lifts her out of an enemy she falls into only when
  its damage is $00 or $FF: 00:$34D0-$34D3 is `DEC A / CP $FE / JR C,$34E3`, and the `JR C`
  jumps *over* the lift for $01-$FE. So a solid, harmless enemy is a floor and a damaging one is
  only a hit. `CollideSamusEnemiesDown` has the branch the other way (`bcc .lift`): it lifts her
  out of every damaging enemy and lets her fall through a $00/$FF one. `ledger.zig`'s row said
  the same backwards thing; `residue.zig`'s `DmgValue` note had it right.
  - **How it was found.** The Queen's spike (Step 6) first measured the Game Boy lifting Samus
    $6C off her body's actor on the first frame. That lift was **our harness's**, not the
    game's (`docs/phase1.md`, Step 6), and it is gone with the reference fixed. Reading the
    port's arm to explain the difference is what found this; it is not shown by any rung.
  - **Not fixed, because nothing yet fails on it.** The fixture the rule asks for is Step 8's
    standing on a frozen enemy: `collision_samusOneEnemyVertical`'s ice arm makes a frozen
    enemy's damage one of the two floor values. It must fail on the cart as it is, then the one
    branch is turned. Also worth reading beside the Senjoo entry above: a lift out of a
    damaging enemy the Game Boy does not make moves Samus on the frame of a contact.
  - **Correction to the above.** The ice arm does not make the damage anything: the solid arm
    (00:$362E) writes no `$C424` at all, so the test reads the *last* damage a hurt or screw hit
    wrote. A new game on our Game Boy has $00 there (measured after its boot; that the ROM
    clears it is not checked), so a frozen enemy is lifted out of until Samus is first hurt,
    and not after. The cart's `!DmgValue` starts at the same zero.
  - **Fixed, 1.0 Step 8d.** The `beams` rung's `ice stand` segment (an Autoad frozen, stood on
    and ridden through its thaw) failed on the cart as it was. `.liftTest`'s `bcc` is now the
    ROM's `bcs`, and the old `bcc` is the segment's fault (it differs at frame 104).
  - **And a second defect under it, found by the same segment.** `poseFunc_fall`'s landing
    skips the row snap (`y & $F8 | 4`) when she landed on an enemy (00:$1378, `$C43A`), and so
    does the falling ball's (00:$12E7). The port snapped on both, which put her a pixel off
    on the landing frame (103). Both tests are ported; `PoseFall_enemyFloor` is the fault.
  - **And two reference defects.** The Game Boy's `$C424` was $A7 when the segment began,
    because `room.spawn`'s teleport let a hit read the damage table with bank 4 mapped. It is
    now reset to the new game's zero after the settle. And the reference was sampled after
    `hurtSamus`, so the thaw's knockback showed a frame early there (frame 420). It is now
    sampled on the `CALL hurtSamus` (00:$052C). See `oracle.gb_logic_pc`.

- [x] (found 2026-10-01; **fixed 2026-10-02, 1.0 Step 25**) Spikes don't do any damage or
  knockback. In the original, when samus touches spikes, she will take damage and knockback.
  - **Cause**: never ported. `samus_getTileIndex` (00:$1FF5) ends with the spike arm
    (00:$2016-$2038): while Samus is not invulnerable, a tile with collision bit 3 sets
    `samus_hurtFlag`, boost $00 (up) and `samus_damageValue` from `spikeDamageValue`, and
    asks for square-1 effect $04. The port's `SampleTile` was that routine without the arm,
    and `audio_sites` carried $002027 as a waiver for it.
  - **Fixed**: `SampleTile` is Samus's, with the arm; `SampleTileProj` is the bare read
    (`getTileIndex.projectile`, 00:$2266) that `HitBlock`, `BombProbeTile` and `EnemyTileAt`
    call, as the Game Boy's do. The waiver is gone.
  - Guarded by: the `beams` rung's `spike` segment: a spin jump into the ceiling spikes of
    `$D:$05` (no enemy in the room), Samus's position, health and OBP1 objects graded frame
    for frame against our Game Boy, which loses $08 on the hit. `SampleTile_spike` taken out
    fails it.

- [x] (found 2026-10-01 by James's Queen playtest, 1.0 Step 20; **fixed 2026-10-01**) **Leaving
  the Queen's room by a door, the tileset changes on screen.** Escaping alive (the ball down her
  shaft, door $19E's `ESCAPE_QUEEN`) the room's characters were visibly swapped for the final
  lab's before the `WARP`. On the Game Boy the screen is black by then.
  - Measured with the `escape` case's screen (`zig build queen -- oracle escape`). On our Game
    Boy, from frame 164, the frame after the door, her head and the status bar are gone and the
    room fills the screen. `FADEOUT` has it all black by 215, ahead of `LOAD_bg`. On the cart
    her head and the status bar stayed, and below her body's top (line 71) the screen stayed lit
    through the fade, the load and `ESCAPE_QUEEN`: 6 408 pixels differed on 215, and 7 071 on 256.
  - Cause: the vblank handler tests `doorIndexLow` before `.queenBranch` (00:$0167-$0170). So
    while a door's script runs, `VBlank_drawQueen` never arms her LYC list. The frame before ended
    at the status bar's command (03:$7CB1), which takes the window off, and rBGP is
    `bg_palette`'s from the top of the frame. `QueenNmi` kept her HDMA channels running instead,
    and her INIDISP channel overwrote the fade's brightness on every line from her body down.
  - Fixed: `QueenDoorFrame` turns her channels off for a door's frames and puts the window's band
    on the play field's, as `gameMode_dead` does. INIDISP becomes the palette's. `!WinOff` stands
    for LCDC bit 5, which `SaveStation` turns back on outside her room, as $5803-$580C does.
  - Guarded by the `escape` case's screens on 168, 215, 256 and 262, and the `exit` case's on
    3 280, 3 320, 3 360 and 3 374. `QueenDoorFrame` is a fault in both. The fade's own steps
    (180, 200, 3 290) are left out: they are master brightness on the cart and a DMG palette on
    the Game Boy, which the `fade` rung grades.

- [x] (found 2026-10-01 by James's Queen playtest, 1.0 Step 20; **fixed 2026-10-01**) **QUEEN
  NEXT, down into her area, then out by the ball's escape: the cart froze on the magenta
  `Fatal` screen.** At a live count above $01, door $13B warps into her area as an ordinary
  room, and the escape's bottom-left exit is cell `$F:$FF`'s door $180 rather than $19E.
  - Measured on the cart along that route: at the 79th frame of $180, seven transfers were
    queued for one vblank, and `DoCopy`'s full-queue check (`!XFER_MAX`, six) went to `Fatal`.
  - Cause: a copy into the shared window converts to two, and the second (`.copyTwin`) is not
    an opcode. It falls through into the next opcode's frame. $180 runs `ITEM` straight after
    `COPY_DATA gfx_commonItems, $8F00`, so the twin's one and `ITEM`'s six shared a frame. Of
    every door script in the ROM, $180 is the only one where a twin is followed by `ITEM`.
  - Fixed: the queue holds seven and moved to $1499. Frame timing is unchanged. That vblank
    drains 2 768 bytes and its NMI returns on line 253 of 261. Running the twin in its main
    copy's frame instead was measured and rejected: `$13B`'s `COPY_spr` pair would drain
    3 840 bytes in one vblank, too close to its end.
  - Guarded by `transition.zig`'s "no frame queues more copies than the engine holds". It walks
    every script at counts $00 and $FF with the engine's rule, reading `!XFER_MAX` and
    `ITEM`'s `LoadCopy` count from the engine source, and pins the peak at 7, door $180. At
    the old six it fails.

- [x] (found 2026-10-02; **fixed 2026-10-02, 1.0 Step 25**; confirmed by James on hardware the same day)
  When paused, the screen is supposed to flash between normal brightness
  and a darker shade. Currently, the screen stays at normal brightness while paused.
  - **Cause**: `PausedFrame` wrote the flash into `!BgPalette` and nothing put it on the
    screen. The Game Boy's vblank copies `bg_palette` to rBGP on every frame (00:$0163); the
    port's play calls `ApplyPalette` only where a door changes it, and the pause never did.
    The `pause` rung's code 114 graded the byte, so it passed while the screen never dimmed:
    a fixture that could not fail on this.
  - **Fixed**: `PauseShow` (`ApplyPalette` through `%call0`) after each of the pause's three
    stores: the flash, the unpause and the debug arm's unpause.
  - Guarded by: the `pause` rung's **code 125**: INIDISP as last written is full brightness
    exactly on the frames our Game Boy's `bg_palette` is $93. `PauseShow` taken out fails it.
