# The conformance harness

`zig build verify` — **the gate**. One command, forty-seven rungs, and the only thing that is
allowed to say the port is correct. Everything else in this repository is a tool for finding
out *why* a rung is red.

The gate runs locally, with your ROM: the ROM cannot be distributed, so there is no CI.
`verify`, `verify-full` and `test-rom` fail without one (`no ROM: set M2_ROM ...`) rather
than report a green that graded nothing; plain `zig build test` skips the ROM tests instead.

- **1.0 Step 26, 2026-10-02: the consolidation.** The gate is green, 46 rungs, in **12m51s**
  on the development machine, against the cycle's 15-minute budget (1.0 Step 1). `verify-full`
  runs the slow tier after it. No window of the 100% recording joins the gate (James; see below).
  The debug menu's METROIDS page and the WARP page's METROID ROOMS now follow the recording's
  kill order (`debug_tables.playthrough`). The rungs that kill a named Metroid from the menu
  find its row by its record, so `scenario`'s `metroids` and `larvae`, and `warp`'s `metroid`,
  kill the same Metroids as before. A unit test holds each playthrough row to the record
  nearest its kill, and it fails with two rows swapped.
- **Release Step 0, 2026-10-04: 1.0 was graded on a stale crawl, and is re-graded on a cold
  one.** The crawl cached in `build-out/` (1058 doors) was older than the first commit of the
  crawler. The committed crawler walks 1185, deterministically, from 027694a to HEAD. The
  cache is keyed on the ROM and `warp.crawl_version` alone, so it was never rebuilt, and every
  crawl-derived pin since 1.0 Step 5a was set on it. The shipped carts are byte-identical on
  either crawl: the crawl reaches a cart only through the debug menu's warp table, which did
  not move. What moved is the gate's reading of the crawl (`warp.walkedArrivals`), which the
  enemy fixtures, the worlds sweep and the warp tests boot rooms by.
  - **The rule.** It left a room to the static reading whenever two arrivals differed. On the
    cold crawl that unsettled 137 cells, and the worlds sweep missed 388 visits against 312
    pinned. It now takes the first arrival in the crawl's order, and leaves the room to the
    static reading only when arrivals at two counts differ. 290 misses: 30 lines removed, and
    8 late-count visits accepted as losses (`docs/porting_loop.md`'s turn log). Unsettling
    every lava room instead lost 80.
  - **The pins that moved**: walked cells 484 → 558, vetoed banks 1 → 2, unloadable 2 → 8,
    the static fault's catch 159 → 211 (`warp.zig`, `warp_grade.zig`). `warp.test` "an entry
    into a room the Game Boy walked into from truth" now skips `.recorded` entries, where
    the recording outranks the crawl, and names its two known entries (`docs/bug_tracker.md`,
    `$A:$36`/`$A:$37`).
  - **The skorps** (`enemy AIs`): room 19 is a lava room, and door `$073` floods it at the new
    game's count. The old rule had booted it with `caveFirst`, a dry room no player sees. An
    enemy case can now name a Metroid count (`Case.count`). The Game Boy holds it before the
    door script runs, and the cart boots with the table `warp.LavaReplay` gives at it
    (`snes_screen.bootForAt`). Both skorps boot at $14, drained as the recording meets them.
    `skorpVert` needs Samus $30 to the right, or it never moves.
  - **The guard**: `verify-full`'s fourth rung, `crawl cold`, crawls from scratch and fails
    unless the bytes are the cached file's. It is red on the old file and green on a fresh one.
- **`verify-full`'s fifth rung is `crawl jobs`, added 2026-10-05 by release Step 4.** The
  crawl tries a wave's doors across lanes, each with a Game Boy of its own, and files them on
  one thread in the order one machine tries them (`crawl.zig`). The rung runs the crawl from
  scratch on 1, 2 and one lane per logical CPU. Every run must give the cached file's bytes
  (`crawl cold`), and the one-lane run's entries and six counters. On this Mac (12 lanes):
  133 s and 45 MB on one lane, 25 s and 79 MB on twelve, all `d4398e1…`. Before the lanes,
  `Machine.restore` copied the snapshot's cartridge-RAM slice, which is the RAM of the
  machine that took it. A worker restoring another's room would have written that machine's
  RAM. It now points the slice at its own (`harness.zig`'s test).
- **`verify-full`'s seventh rung is `location`, and `zig build release` scans its binaries,
  added 2026-10-05 by release Step 8.** `location` (`pincheck location`) copies the binary to
  two install directories (one with a space in its name) and runs it from two working
  directories, on the ROM by a relative and by an absolute path. The crawl comes from
  `build-out/` by an absolute path. All 8 retail carts must match the pin. A wrong pin failed
  all 8. Release binaries are stripped, because Zig 0.16 records debug info's source and lib
  paths as absolute and has no prefix map. `pathscan` (`src/pathscan.zig`, run by
  `release`) fails a binary holding `/Users/`, `/home/`, `/opt/`, `/tmp/`, `/private/`,
  `/var/`, a drive letter, or the build's own root, Zig lib dir or cache. An unstripped release
  build failed it: 37 hits in each Linux binary and 2 in the macOS one. `ci/smoke.sh` is
  CI's ROM-free check of a release binary, run from outside any checkout with `PATH` cut down:
  `--version`, `--help`, and a refusal of a zeroed 256 KiB file by relative and by absolute
  path that leaves nothing behind. Three stand-ins failed it: one that accepts every file, one
  that leaves a temp file, and one with a wrong `--version`.
  Found by these checks: every executable here wrote stdout through 0.16's `File.writer`,
  which is positional. Into a regular file it writes from offset 0, so `m2snes … >> log`
  overwrote the log, and in a `zig build … > log` run each tool overwrote the one before. A
  `verify-full` log had lost its `pin-check` and `crawl cold` lines. All 33 now use
  `writerStreaming`. `smoke.sh` checks that `--version >> log` keeps the log's lines; the old
  binary failed that.
- **The forty-eighth and forty-ninth rungs are `builder` and `pin (binary)`, and
  `verify-full`'s sixth is `pin-check`, added 2026-10-05 by release Step 6.** The carts are
  now the `m2snes` binary's: `zig build rom` and the build's cart runs call it with
  `--crawl-cache build-out`, so `cart pin` grades the player's pipeline. `builder` fails when
  the binary holds the configured `M2_ROM` path, or when a plain `zig build` installs anything
  but it. `pin (binary)` runs the binary from `build-out/pin-binary/` with absolute paths, for
  both carts, against `pins/cart.txt`. `pin-check` (`src/pincheck_main.zig`) does the same with
  no crawl cache, the player's run, so the binary crawls for itself. `zig build test` also runs
  the binary on each ROM refusal and on an output that is its input (by name and by symlink):
  each must exit 1, say why, name the expected SHA-1 where the ROM was read, and leave only the
  input. Faults: a stand-in that exits 0, one that says nothing, and one that leaves a file
  behind each failed the refusal check. `warp.zig`'s test holds the cached crawl file to
  `formatWalked(parseWalked(file))`, so the cached and uncached runs build from one value.
- **The forty-seventh rung is `cart pin`, added 2026-10-04 by release Step 1.** The retail
  cart, the `--debug` cart and the crawl file, each against its SHA-1 in `pins/cart.txt`
  (`src/pin.zig`). The build makes all three fresh before the gate runs. It is what every
  refactor of the pipeline toward the `m2snes` binary is graded against. An intended change
  re-pins with `zig build repin -- "<why>"`, which appends the old and new SHA-1s and the reason
  to `pins/history.md`. The rung also fails when `pins/cart.txt` is not where that file's last
  line moved it, so a hand edit is red. A missing pin is red, not skipped. Faults: a one-byte
  mutation, a missing pin and a reasonless or disagreeing history line, in `pin.zig`'s tests.
- **The forty-sixth rung is `saves`, added 2026-10-01 by 1.0 Step 18e.** A save round trip at
  every station on the WARP page, seven in the five banks that have one, each its own run on the
  `--debug` cart through the menu's own input (`save_grade.zig`). Each run sets FULL LOADOUT and
  the clock, and kills a Metroid of another bank. Then it warps to the station, and with its
  bank loaded kills one of its Metroids and takes one of its orbs. Then Start on the pad, the
  console's reset (`emu.reset()`; the Game Boy's soft reset is not ported), and the title's
  load. The loaded state is graded against our Game Boy before the save, in the record and
  after the load. The record is graded against what she held, and the load against the record,
  as `round trip` and `load` do. Then the marks, the view, and a warp to the orb, which must not
  load it. Fault: the load's search for the record's metatile table stopped at the first.
- **The forty-fifth rung is `counts`, added 2026-09-30 by 1.0 Step 18d.** The `doors` entries
  again at the Metroid counts their scripts test (`warp.countedEntries`): for every operand a
  door entry's chain tests, the count at it (the branch taken) and the one above it (not taken),
  wherever the two leave another tileset or send her elsewhere. That is every lava door at each
  level it draws, and both sides of twelve of the ROM's thirteen thresholds; `$00` is door
  `$19E`'s alone, whose two sides run `EXIT_QUEEN` and `ESCAPE_QUEEN`, Step 20's. `$01`'s taken
  side is her room, through `$13B`. 270 entries, highest count first, twenty to a case cart: each
  run kills METROIDS' rows in order through the menu's own input until the next entry's count is
  reached, and checks the count it left (code 27). Our Game Boy runs each chain with both counts
  set. Each entry is stood again under what its count loads, and is read before any door she
  falls into runs. Fault: `IF_MET_LESS`'s `bcs` made `bcc`, every branch inverted. **1.0 Step
  20d** added `$00`: door `$19E` and `$19F` run as door entries, and `counts` holds 272.
- **The forty-fourth rung is `doors`, added 2026-09-30 by 1.0 Step 18a.** Every door script
  the cart can be asked to run, as a warp entry (`warp.doorEntries`): 424 of the 512. A door the
  crawl walked at the new game's count runs behind the loader of the room it leaves, as a
  player's crossing leaves the rest loaded, and must leave what the walk left; she stands
  nearest the edge she came in by. A door never walked there runs alone into its own `WARP`
  cell, after whatever the entry before it left, and no stand is graded (she is put in the
  middle). Twenty entries to a **case cart**: the `--debug` cart with the WARP page's lists given
  over to them (`warp_grade.doorCart`), so the menu's own input reaches them; 22 runs in
  parallel, about 14 s. Graded as `warp` is, **and the map**: the cart's `!TilemapBuf` over the
  camera's view, 21 by 19 tiles from the scroll (`camera - $50`, `- $48`), on the frame she
  arrives, against our Game Boy's `$9800` with every cell the view touches drawn under what the
  chain left (code 26). `warp` grades the map too since this step. Not run: 15 undecodable, the
  Queen's three (`ENTER_QUEEN` is WARP's own entry), 52 with no walk and no `WARP` of their own,
  and 17 walked with no chain that leaves what the walk left. Fault: `LoadMetaBase` reading
  every table from table 0's base, which leaves the loaded state and characters right and
  must fail 26. **It found the new game's solidity** (`bug_tracker.md`): five runs failed 21 on
  their first entry until 1.0 Step 18b loaded the new game from `initialSaveFile`. A unit test
  beside it holds all 497 decodable scripts' operations to the arms `StepDoorScript` compares
  for, read out of `engine/main.asm`, with `FADEOUT` waited and `ESCAPE_QUEEN`/`EXIT_QUEEN`
  ($19E, $19F) named as Steps 20-21's.
- **1.0 Step 12, 2026-09-29: `enemy AIs` grew nine cases, and now runs four at a time.** The
  second batch: glowFly, proboscum, skorpVert, skorpHori, autrack, autom, gunzoo, blobThrower
  and missileBlock, each with its children. Seven blob-thrower globals are graded beside the
  slots, because its state is global in the original. A case hands across a *list* of divider
  sites now (`Case.dividers`): the gunzoo reads at two. **The rung runs in parallel.** A case's
  honest, faulted and behaviour carts start together, and `gradeCases` keeps four cases in
  flight, each with its own files (`startCart`/`finishCart`). All 47 enemy cases take 49 s,
  The gate went from 14m27s to 12m36s with nine more cases. `enemy reload` runs the same way.
- **1.0 Step 11, 2026-09-29: `enemy AIs` grew nine cases, and `beams` two segments.** The
  first batch of ordinary AIs, one case each in a room of its own spawn records: skreek (with
  its spit), drivel (with `drivelSpit`), moto, gravitt, the vanishing flitt, halzyn in two rooms
  (the weave, and a turn off a wall), septogg and the moving flitt. `zig build roster -- ai
  <addr>` lists an AI's records and whether each cell can boot. A case can now hand a divider
  read across (`Case.divider`). The Game Boy side records what each `rDIV` read at the site
  returned, and the cart's script writes the same byte into `!DivClock` as its own read is
  about to run, in the same order. The drivel's coin is the first such read: without the
  handover it differed at pass 3. The two platforms that carry Samus are graded by `beams`:
  `septogg ride` (215 frames) and `flitt ride` (239). She lands on each and is carried, frame
  for frame; the carry is faulted out (frames 79, 79 and 191). James's playtest added `septogg
  sand` (267 frames). A segment can now start in a room of its own (`BeamSegment.room`); this
  one starts in `$B:$24` and rides a septogg down through the sand, as the Game Boy does,
  until she is trapped. Fault: the carry (55).
- **1.0 Step 9, 2026-09-28: `beams` grew three segments, and `gfx` four grades.** A segment can
  grade Samus's health frame for frame (`Take.health`), in code 254, taken off the top of the
  unhandled poses' range. `hurt` walks her into an Autoad seeded $30 to her right, and `varia
  hurt` does the same with Varia: the halving is graded both ways. `screw kill` spins her
  through it with Screw Attack. `hurt` failed at frame 9 first, on the knockback's direction
  (`bug_tracker.md`). Faults: the collision flag's store (`hurt`), the halving
  (`varia hurt`), the screw's item test (`screw kill`). `gfx` now grades:
  - Varia's frames, the animation counted as transfer;
  - the pickup's length within 2% for Varia (code 12);
  - the frames from the bit landing to the flag's $03, exactly (13);
  - the clock's ticks over the pickup (14), with the cart's stores made when its counter's low
    byte is the Game Boy's less one.

  It found two defects, the jingle's missing first pass and its frames not ticking the clock,
  and has a fault for each and one that cuts Varia's animation short.
- **`beams` grew a ninth segment on 2026-09-28, 1.0 Step 8d: `ice stand`** (529 frames). An
  Autoad seeded $30 to her right is frozen by one ice shot; she jumps straight up beside it,
  drifts over, lands on it, stands until it thaws (frame 419), and takes its contact and the
  knockback. It found two defects (`bug_tracker.md`): the lift out of an enemy floor was the
  ROM's branch backwards (`CollideSamusEnemiesDown_liftTest`, 00:$34D3), and a landing on an
  enemy snapped to the tile row, where 00:$1378 and 00:$12E7 skip the snap when `$C43A` is set
  (`PoseFall_enemyFloor`). Faults: the old branch (104), the frozen enemy taken as a hurt
  (102), the snap (103). Two reference changes came with it. The Game Boy's `$C424` goes back
  to the new game's zero after the spawn, which had left $A7 in it: a hit during the teleport
  read the damage table from bank 4. And the Game Boy is now sampled at $052C, the `CALL
  hurtSamus`, not $052F after it, so a hurt no longer shows there a frame before the cart.
- **The forty-third rung is `beams`, added 2026-09-28 by 1.0 Step 8c.** Eight segments on the
  segment oracle's start. Each sets a beam on the `--debug` cart through the debug menu's beam
  row, writes the same `samusBeam` and `samusActiveWeapon` on the Game Boy after its frame 0,
  and compares **the projectile array** (type, Y and X of all three slots) frame for frame
  beside Samus. Codes 6-18 are the projectiles', each `oracle.projectile_widen` buckets wide.
  Five fire each beam into the room's wall, up and away (258 frames): power and ice are the
  contrast, and the wave through the wall, the spazer's three and the plasma through the wall
  each have a fault. Three fire the plasma at an enemy seeded in slot 0 on both machines,
  placed from Samus's pixel (`oracle.Enemy`, the `enemy AIs` rung's seed): an Autoad from $30,
  where all three shots stop, and from $38, where the rearmost flies on past the kill, and a
  missile door that spends all three. The fault ignores the hit. The rung found the plasma's
  slots in the wrong order (`bug_tracker.md`); `SamusShoot_plasmaOrder` puts it back.
- **`enemy AIs` grew by five beam cases on 2026-09-28, 1.0 Step 8b**, and grades three more
  bytes: slot 0's stun, ice counter and health, as globals (collapsed like the others), because
  the ice beam's freeze shows in nothing else until the thaw. They are globals and not slot
  fields because a slot field is paid four times a record. Even so, the hatching Alpha's 700
  frames no longer fit 32 KiB, so the case cart has 64 KiB of save RAM
  (`snes_trace.stampSramOf`). The Lua writes the records through Mesen's flat `snesSaveRam`, and
  the engine never looks past one bank. A case may also name a **behaviour fault**, a patch at an
  engine label that must make its cart differ in a slot or a global. The Spazer and Plasma kills
  are at ticks where the drop's roll agrees on both machines. The Game Boy rolls `rDIV`, the port
  `!EnFrame` (a recorded substitution). The two agree for a few passes and then disagree for a
  few; see the cases' comment.
- **The forty-second rung is `gfx`, added 2026-09-28 by 1.0 Step 8a.** Twelve pickups, each a
  new game on the `--debug` cart, held against our Game Boy taking the same pickup
  (`src/gfx_grade.zig`): the four beams and the ice beam with missiles selected, the screw attack
  and space jump each alone and after the other, the spring ball, and Varia alone and over
  everything with missiles selected. The pickup's lever is `snes boot` phase 9's, the orb's two
  stores, on both machines; the first items go through the menu on the cart and are written on
  the Game Boy. Graded after it:
  - the object characters $8000-$87FF, where every record lands;
  - the frames the transfer flag was up, sampled on the Game Boy at line 144;
  - the item's bit, the weapon and her pose.

  Varia's frames wait on Step 9's transformation. One Mesen2 run a case, in parallel. Faults: the
  ice beam's arm handed the wave's row (the characters, 9), a whole record a vblank rather than a
  chunk (the frames, 8), and Varia's pose the `$13` it was before this step (the pose, 11). The
  cart presses B first, because a new game faces the screen until a button is pressed and our
  Game Boy's boot has pressed Start.
- **The forty-first rung is `loadout`, added 2026-09-28 by 1.0 Step 7.** Three segments on the
  segment oracle's start, one per item: Hi-Jump (534 frames: a standing jump held and let go,
  a spin from a walk, a jump from the crouch), Space Jump (336: a spin, then two space jumps
  held through their rise, the second turned round) and Spring Ball (317: jumps in the ball,
  held, let go, rolling both ways, and A in the air). The cart is the `--debug` one, and the
  item is set **through the debug menu**: graded frame 0 is played, then the chord, A for
  SAMUS, Down to the item's row, A, and the chord again, one press a frame with a frame
  between. The Game Boy is given what that leaves: its `$FF97` moved on by the menu's NMIs (the
  setup's passes plus the one its opening costs, `oracle.menu_open_lag`) and the item's bit,
  after its frame 0. The script checks the menu was up on every setup pass, shut after, the
  items the ones asked for and the counter moved by what the reference froze (code 19). Then
  frame for frame, as the segment. Each has an engine fault, its item's test blanked
  (`PoseJump_hiJumpRise`, `PoseSpinJump_spaceItem`, `PoseMorph_springItem`), which must make it
  differ; that is also what says the schedule still reaches the branch.
- **The fortieth rung is `warp`, added 2026-09-27 by 1.0 Step 5c.** Every entry on the debug
  menu's WARP page (160), warped to on the `--debug` cart through the menu's own input, one
  after another in eight runs that go in parallel (`src/warp_grade.zig`). The reference is our
  Game Boy running each entry's chain by setting the door index and calling the interpreter
  (00:$239C), in the same order the cart warps, because what a chain does not load -- the
  enemy page's source, the damage -- is what the warp before it left. Graded on arrival: the
  bank, the cell the warp drew (the camera's, read before the first frame's latch) and its
  scroll flags; then `$D808`-`$D814` (the block a save keeps), the damage, and the characters
  the loaded metatile table draws, by hash. Only those: ids $80-$AF are the Game Boy's object
  tiles, which the cart keeps in the object region alone, and only the Queen's table draws any.
  Then a second of standing where the entry puts her, in its pose; a hit by an enemy ends it and
  is counted. Arrival is counted from the game's first frame after the warp, which runs with
  NMI off for frames on end. Plus three scenarios Step 4 could not reach from a new game: an orb
  marked taken on FLAGS is not loaded by the warp and is once reset (`item`); Metroid 01 killed
  from the menu mid-fight has its slot freed, its fight ended and the count lowered (`metroid`);
  one Metroid killed, and the door walked through beside the one entry whose door branches at
  $46 (`$1A4`, from $B:$13) loads the ROM's table for $46, not $47's (`gated_door`).
- **The thirty-ninth rung is `scenario`, added 2026-09-27 by 1.0 Step 3.** The `--debug`
  cart as a new game, set up through the debug menu's own input -- the chord, then the pad on
  the SAMUS page -- with no RAM poked, and checked after every change against the ROM: the new
  game's save record, and the `samusItems` bit or beam value each pickup routine writes,
  decoded from the routines `handleItemPickup` (00:$372F) dispatches to (`src/scenario.zig`).
  The menu's own rules (counts by ten, a tank taken away) are the model there, since the Game
  Boy has no menu to ask. **Each scenario is its own Mesen2 run**, with its own small code
  space (`scenario.code`), and they run in parallel: `snes boot` has spent most of its
  one-byte codes, and one script that grew a check per scenario would meet Lua's 200-local
  limit, which reads as a timeout (255), not an error. A failing run prints what it compared,
  and the gate shows that line. Later steps (the warp page) add scenarios here. 1.0 Step 4
  added `metroids`, `flags` and `clock`, graded against what `.death` (02:$6D61) and
  `earthquakeCheck` (08:$7EBC) do, read out of the ROM (`scenario.Kill`), and the flags where
  the game reads them: the save buffer's window for a bank not loaded, and the live array
  too for the loaded one. The `metroids` run waits for the quake its kills queued to start and
  run out after closing, so it takes about 25 s where the others take 2.
- **The thirty-eighth rung is `pause`, added 2026-09-27 by 1.0 Step 2a.** The shipped cart
  started as a new game and driven through `pause_oracle.script`, graded pass for pass against
  our Game Boy running the same script from a cold boot: the frame counter first, then the pause
  and unpause requests, `bg_palette`, Samus, the timer, the status bar and the objects. The Game
  Boy is sampled once per `mainGameLoop` iteration, at `waitForNextFrame`, and fed its pad per
  iteration -- it runs long on some frames, the pause's own among them, and an LCD-frame sample
  lands mid-iteration there. In play the cart's pass k reads the poll made at vblank k - 1, set
  when the counter reads k - 2; the title's presses keep the title rung's relation. It reads no
  variable the port added, so it ran on the unfixed cart and failed there. About 10 s, its two
  runs and six faults in parallel.
- **The thirty-seventh rung is `recorded`, added 2026-09-26 by Step 26.** The anchored sweep
  over `reference/metroid2.mmo`, James's own recording, with every reference taken off Mesen2:
  the first 2000 frames, 493 of 1648 reached across 11 of 11 stretches, against two floors
  (`oracle.recorded_gate_floor`, `recorded_gradable_floor`). About 65 s. One window only,
  because a Mesen pass replays from the movie's start: the same 2000 frames at 10 000 took 47
  minutes. See `oracle.recorded_gate_window` for the measurement. Before this step the census
  it runs on stopped each pass one row short and took that for the movie's end, so any window
  over 906 frames was silently one pass long.
- **The thirty-sixth rung is `audio level`, added 2026-09-25 by Step 24f.** Eight of the
  slice's sounds rendered by both engines, the cart's RMS against SameBoy's: the set within
  ±1 dB and each sound within ±2 dB (`src/audio_level.zig`). The first rung that grades what
  the sound *is* rather than which writes made it; `audiocmp` was exact while the cart played
  11 dB too loud. It needs the ROM, `vendor/sameboy` and `spcrun`, and says `not run:`
  without them. About 1.5 s: SameBoy runs in turbo, and the `spcrun`s run in parallel.
- **The thirty-fifth rung is `aram symbols`, added 2026-09-18 by the audio cycle's Step 7.**
  The committed `engine/audio/aram_data.inc` is what `aram_layout.plan` plans. The engine's
  assembly reads bank 4's ARAM addresses out of that file, and a stale copy assembles
  cleanly and sends the engine to read the wrong table, which on the SPC700 is silent.
  Like the two below it, it needs neither the ROM nor an assembler.
- **The thirty-fourth rung is `aram layout`, added 2026-09-17 by the audio cycle's Step 5.**
  Bank 4's data placed into the SPC700's 64 KiB against the regions the shim's own memory map
  declares, with the engine image measured in. Like `audio shim` it grades a structure rather
  than a behaviour, and it needs neither the ROM nor an assembler.
- **The thirty-third rung is `audio shim`, added 2026-09-17 by the audio cycle's Step 4.** It
  is the odd one out: it grades no behaviour, because at Step 4 there is no ported sound
  engine to grade. It grades a *provenance* — that `audio/shim/`, the one directory here that
  no build step produces, is still the package its MANIFEST names, and that the engine
  assembles against the ABI that package carries. Behaviour arrives with Step 7's `audiocmp`.
- **The thirty-second rung is `fade`, added 2026-09-16 by Step 20.** Door $1DF's fade in the
  any% run, graded on the cart's INIDISP brightness against the Game Boy's `bg_palette`.
- **The thirty-first rung is `enemy reload`, added 2026-09-16 by Step 19.** See finding 0 in
  the audit below for what it grades and what it does not.
- **Green end to end on 2026-09-15**, 391 s wall-clock warm on the development machine
  (780 s CPU: the rungs that spawn Mesen2 run in parallel). Cart digest
  `299fe727859b241b12cde3dcc4430d90713588772ededcda146e6f4d9b2dc281`.
- **Absent means it did not run.** Every rung that needs the ROM, the emulator or the
  recording prints `not run:` and stays green when its input is missing, because none of the
  three is vendored. A rung that silently skipped would be worse than a red one.
- The verdict from Mesen2 is a one-byte process exit code — `emu.log` is swallowed and Lua's
  `io` is sandboxed in testrunner mode — so each emulator rung defines a small code protocol.
  Lua's `print` does reach stdout (found 2026-09-27), and the `scenario` rung reads it for the
  line a failure prints; the older rungs still leave theirs in cartridge RAM.
  See `src/romtest_main.zig` and the `*Code` functions in `src/verify.zig`.

## The roster

Ordered as the gate prints them. **Fault** is the mutation check: what the rung does to prove
it is not vacuous. A rung with no fault check passes if the mechanism it grades is removed
*and* the removal happens to be invisible to what it compares — which is the failure mode
this table exists to make visible.

| Rung | What it grades | Reference | Fault |
| --- | --- | --- | --- |
| ROM revision | the cartridge is the one every offset was measured on | the ROM | n/a |
| offset shapes | 27 shape checks over 161 offset table entries | the ROM | n/a |
| map/door/sprite | 904/905 screens reached, 1872 door ops round-trip, 308 metasprites | the ROM | n/a |
| extraction | 161 entries reproduce byte-for-byte, twice | the ROM | reproducibility |
| round-trip | 161/161 entries re-encode to their source bytes | the ROM | identity |
| coverage | 191/256 KiB of the ROM claimed | the ROM | n/a |
| frames | 904 screens render reproducibly | the ROM | reproducibility |
| emulator | 600 frames of the retail ROM reproduce, twice | our GB emulator | reproducibility |
| logic ledger | 262 routines, instruction-boundary integrity | the ROM | boundary check |
| dispatch survey | 7 dispatch sites, 223 table entries | the ROM | floors |
| tas horizon (×2) | our GB replay stays faithful to the published runs: 8407 / 4566 | the published TASes | floors |
| sameboy | 10 captures match a second GB emulator | SameBoy | pixel compare |
| snes layout | 266 KiB converted fits 376 KiB reserved | the region map | headroom |
| snes render | 904 screens convert pixel for pixel | the GB render | **4/4 injected faults caught** |
| snes engine | 32 KiB image in 128 KiB, and it is what `main.asm` assembles to | `engine/main.asm` | reassembly compare |
| audio shim | `audio/shim/` is the package its MANIFEST names, and `engine/audio/main.asm`'s ABI is that package's | the MANIFEST's sha256 per file | **an edited byte, a bumped `SHIM_ABI_EXPECTED` and a stale `audio.bin` each fail it** |
| aram symbols | `engine/audio/aram_data.inc` is the addresses the layout plans | `aram_layout.plan` | **a stale or absent include fails it by name** |
| aram layout | bank 4's 9480 bytes of sound data, the engine and the shim inside the regions `shimpkg.zig` declares | the shim's own memory map | **an engine one byte over its region is refused, and every segment pair is asserted non-overlapping** |
| audio level | eight of the slice's sounds at the Game Boy's level: the set within ±1 dB, each within ±2 dB | SameBoy's APU on the same writes | **the pre-fix shim (full scale 127, `MVOL` $7f) reads +11.0 dB and fails it** |
| snes rom | 1 MiB cart, identical across two runs; the `--debug` cart likewise, differing from the retail one in `DebugAllowed` and the checksum only | itself | reproducibility |
| **snes boot** | **28 phases: the bulk of B1, B4a, B5, B6, B8, B12d, B13, spider ball, save station, the window raise and bar**; since 1.0 Step 25, code 149: her first part on palette 1 exactly while acid or i-frames run | GB renders + measured constants | **13/13 engine faults, each caught by the phase that grades it** (Steps 25, 24g); 149 failed on the cart before 1.0 Step 25 |
| cold boot | title screen to gameplay on the shipped cart | the GB's own boot | **a record whose countdown starts spent fails it** |
| load | slot 0 holds the recording's first save and the cart comes up in it | the recording's save | **`energy_fault`** |
| pause | Start alone pauses and not facing the screen or with Left; held Right does not move her; the flash on bit 4; the timer held through a counter wrap; the L counter on the bar and the `L` over the icon; Start with A unpauses; the pause and unpause requests; the frame counter carried through the title; and the debug menu (121-124): on the retail cart L+R+Start only pauses and the run stays the Game Boy's; on the `--debug` cart the chord opens the menu mid-walk with Samus frozen, BG1 alone, its root and font, A opens SAMUS, B goes back and closes, play goes on, the chord opens and closes it again, and the play field's VRAM is untouched | our GB from a cold boot's new game through the same pad script, per `mainGameLoop` iteration (`pause_oracle.zig`) | **`flash_fault` (114), and 11/11 engine faults each caught by its code**: `DebugAllowed` ignored (121), the chord never recognised, the menu never opened or never uploaded (122), never closed or its layers never restored (123) (1.0 Steps 2a-2d); and 1.0 Step 25's **125**: INIDISP as last written is full brightness exactly on the frames our Game Boy's `bg_palette` is $93, which 114 (the byte) could not see; `PauseShow` taken out fails it |
| scenario | the debug menu sets what it says, through its own input on the `--debug` cart: `items` (the seven bits on with A, off with Left, Right on a bit already set, A to switch), `beams` (Right through all four and round to power, Left round, the weapon following), `counts` (tanks up and down, max and current missiles by ten, the count held under the ceiling both ways), `loadout` (everything, and the fifth tank's Right filling); a check after each of 31 edits, and again after closing and a second of play | the new game's save record (`initial_save`) and the pickup routines' own bytes, decoded (`scenario.pickups`) | **2/2 engine faults, each caught by its edit's code**: hi-jump's row given the screw attack's bit (12), the beam row's weapon write gone (11) (1.0 Step 3) |
| scenario, world pages | `metroids` (the first Metroid killed with A, Right on it left alone, Left reviving it, A again, then four more from the bottom of the list, three in the loaded bank: $47 to $42, two thresholds, and the quake queued, starting and running out once the menu closes), `flags` (bank 9's first orb switched, set and reset in the save buffer; the baby, in the loaded bank, in the live array and the save buffer), `clock` (hours round 00-99 both ways, minutes round 00-59 both ways), `larvae` (1.0 Step 10: two larvae killed and one revived move the real count and not the shown one, then Metroid 01 moves both); 31 edits | `.death`'s flag, shuffle and counts and `earthquakeCheck`'s thresholds and ticks, read from the ROM (`scenario.Kill`); the new game's record; for `larvae`, `enAI_metroidStinger`'s `ADD A,$08` (02:$6B92) and the larval rows (`debug_tables.larvae`) | **4/4 engine faults**: the kill's `earthquakeCheck` gone (11), the flag's save-buffer write gone (11), minutes wrapped at $70 (20), `DebugDispMoves` answering "moves" for every row (11) (1.0 Steps 4, 10) |
| warp | every WARP entry (161) warped to through the menu's own input: the bank, the cell drawn and its scroll flags, `$D808`-`$D814`, the damage and the characters the loaded metatile table draws, the map over the camera's view (1.0 Step 18a), then a second stood where the entry puts her (not her room, where she falls in: `queen` follows the fall); plus `item` (an orb's flag taken, then reset), `metroid` (Metroid 01 killed on the screen mid-fight), `gated_door` (one kill, then door $1A4 loads $46's table), `queen` (1.0 Step 6: Samus's position for 30 frames after the warp, then the play window pixel for pixel at frames 60, 90 and 120, objects masked), `refills` (1.0 Step 10: `$F:$10`'s two refills, for 64 frames after each warp and after the Alpha killed from the menu, in OAM with their record's parts and every coloured pixel the shade its palette gives, and blinking into palette 1) and `refill_credits` (1.0 Step 10: `$F:$76`'s missile refill, ten short, fills at the new game's count; METROIDS, the Queen's row last, takes the count to zero and back; and at zero the refill takes the credits branch) and `spring_ball` (1.0 Step 13: Arachnus in `$D:$C0` begun with the recording's shot and handed six bombs by the enemy rung's lever, then its Spring Ball jumped at until picked up: the bit set, the record dead, and not loaded by a second warp) and `missile_kill` (1.0 Step 27a: `$A` #$40 killed from METROIDS and left by a warp 260 frames into its post-death wait, a save room, then `$D` #$46 shot dead with missiles through the pad: every frame of its death the record $02 and the slot an explosion frame, and after it no fight, no freeze, two fewer) | our Game Boy running each chain by door index, in the cart's order; the ROM's spawn flags, `.death` and `metatile_pointers`; for `refills`, the ROM's metasprites, the common item characters (00:$05FD) and OBP0/OBP1, and for `refill_credits` 00:$399C's branch and its song request; for `queen`, our Game Boy's main loop running door $19D and `gb/ppu.zig`'s background and window | **the chains cut to their door alone** (caught on the loaded state or characters), and **9/9 engine faults**: the flag's save-buffer write gone (30), the kill's slot delete gone (33), the kill's count left alone (35), `QueenApply` taken out so no LCD-handler command lands (36), OBP1 loaded at $84 as before 1.0 Step 8b (39), the missile refill's count test removed (43), the sixth bomb's switch to the item orb's AI removed (46), a crossing's reset ending the fight again (50), `EarthquakeCheck` handing back its index for the slot (50) (1.0 Steps 5c, 6, 10, 13, 27a) |
| queen | her fight on her own (1.0 Step 19b): the debug cart warped to her room through the menu, and for 604 frames, to just before Samus dies, every byte of her `$C300` page but its fifteen pointers out of it, her thirteen slots and Samus's position, pose and health, each byte's collapsed history the Game Boy's; read where the main loop wakes from NMI, as the Game Boy's frame is read past its vblank handler. Her mouth's `rDIV` toss and `frameCounter`'s phase at her entry are handed across ; and her hurt (1.0 Step 19c): the `volley` case holds both machines to one pad, keyed to vblanks (missiles selected, a turn, a shot every 24 frames and every 6 while her mouth is open), for 658 frames with `queen_eatingState` and `collision_weaponType` beside the rest, the play window on seven frames (objects aside) and her BGP bands as INIDISP and COLDATA line by line on four, her flash among them. The `still` case grades the bands on two frames; and being eaten (1.0 Step 20a): the `mouth` case starts from the menu's FULL LOADOUT (our Game Boy written the same, from the pickup routines), stuns her, rolls into her mouth and bombs out of it, 700 frames. On our Game Boy's lag frames only, the ten bytes `VBlank_drawQueen` builds may hold a value its vblank never built, each printed and their count pinned per case (0, 0, 3, 24, 12, 0; exit 51); and the stomach (1.0 Step 20b): the `stomach` case, from `mouth`'s shut mouth, swallowed on a press of left, a bomb in her stomach, thrown up her bent neck and out, her health down thirty and the walk back, 900 frames; and her death (1.0 Step 20c): `kill`, a missile every eight frames to her death and through it, 3 250 frames, with the Metroid counts, the shuffle, the quake and Samus's missile beside the rest, the play window on ten frames across the disintegration and the body's delete, her map's cells in VRAM at the end (exit 53), and her death's length, state $11 to $16, within 2% (exit 52; 596 frames, 100.00%); `mouth_kill`, the same to under ten health, then rolled into her stunned mouth and bombed out dying ($20), killed from her stomach, 3 320 frames (629 frames, 100.00%). In both, a press that would begin on the frame after one our Game Boy lags on is moved a frame on, until none does: there the original reads the pad a frame early; and out of her room (1.0 Step 20d), with her room flag, the bank, the camera and `songPlaying` (whose history may begin with the song before hers: the cart reads it off the sound engine's reply) beside the rest: `exit`, the kill, then over her body and left through door $19E into $19F's `EXIT_QUEEN` and $F:$A9, 3 383 frames, the quake ending in her room on the baby's song; and `escape`, the ball down her bottom exit and out through `ESCAPE_QUEEN` into $E:$C1, 270 frames. Each is graded to the arrival, where our Game Boy starts to lag in the new room | our Game Boy entering by door $19D's index (`queen.enter`), as the original's debug warp did, held to the same pad; its per-line BGP from `gb/ppu.zig` | **4/4 of her routines taken out part from `still`** (48), and since 1.0 Step 25 `still` runs on past Samus's death to the GAME OVER screen, compared on 900: `GameOverQueenFlag` taken out fails it (49): a state (`QueenPrepExtend`, the lunge), the spit's chase, the neck's drawing and the feet; **2/2 from `volley`**: `QueenHeadCollision` (48) and the flash's arm, `QueenSetBgp_flash` (49); **3/3 from `mouth`** (48): `QueenBombArms`, `QueenSamusEaten` and `ApplyDamageStomach`; **1/1 from `stomach`** (48): state $08, `QueenStomachBombedState`; **5/5 from `kill`**: her death's states `QueenPrepDeath`, `QueenDisintegrating` and `QueenDeleteBody` (48), the copy out, `QueenChrSpans` (49), and the rows, `QueenNmiRow` (53); **2/2 from `mouth_kill`** (48): `QueenSamusEaten_kill` and `QueenKillFromStomach`; **2/2 from `exit`** (48): `DoorExitQueen` and the quake's song, `QuakeQueenSong`; **1/1 from `escape`** (48): `DoorEscapeQueen` |
| doors | 426 door scripts (424 until 1.0 Step 20d added $19E and $19F), each as a warp entry on a case cart of twenty, through the menu's own input: a walked door behind its room's loader, an unwalked one alone into its `WARP` cell; graded as `warp`, map included, and stood where the walk comes in when the cell has a spot; plus a unit test that every decodable script's operations are the dispatch's | our Game Boy running each chain by door index in the cart's order, each cell of the view drawn under what it left (`room.drawRoom`); the crawl's walks; `StepDoorScript`'s own compares | **`LoadMetaBase` reading table 0's base** (26); and the unfixed new game failed five runs 21 (1.0 Steps 18a-18b) |
| counts | the `doors` entries at each count a chain tests where its two sides differ (272): every lava door's levels, both sides of all thirteen thresholds (`$00`'s since 1.0 Step 20d: door `$19E`, `ESCAPE_QUEEN` at `$01` and `$19F`'s `EXIT_QUEEN` at `$00`), `$01`'s through `$13B` into her room; the count reached by killing METROIDS' rows through the menu, and checked (27); graded as `doors`, read before a door she falls into runs | our Game Boy running each chain by door index with `metroidCountReal` and the shown count set to the entry's | **`IF_MET_LESS`'s branch inverted** (`bcs` to `bcc` in `StepDoorScript_metless`) (1.0 Step 18d) |
| title | the file select: 167 frames of Select, Down, the equalities, Right and Left through both wraps, the clear in slot 1 and Start, opened on `saveLastSlot`'s 2 seeded before the boot, the state bytes, the select sound's count and the menu's OAM frame for frame, rows 16–17 pixel for pixel, the menu's characters, the slots and `saveLastSlot` after; a second run seeded with 3 opens on slot 0; "Super" (B15) over its rectangle plus 8 px, its two CGRAM words, and BG1's patch zero once the game starts | our GB running the same pad script from a cold boot (`title_oracle.zig`), its select sound counted at the five stores the ROM has, with `assets/title_super.png` composited at `super_at` (`title_super.zig`) | **`phase_fault` (96), and 11/11 engine faults each caught by its code** (Steps 24h, 24i, 24j) |
| death | zero displayed health kills her and the cart reboots to the title, whose menu opens as a cold boot's | GB mode lengths | **`length_fault`**; the pre-24h cart fails 193 |
| round trip | the cart saves, dies, and loads back the record it wrote; again in slot 2, chosen with Left: the record and spawn flags at slot 2's offsets only, `saveLastSlot` 2, the reboot on slot 2 and its flags loaded | the cart's own record | **`energy_fault` (207)**; the 24j cart fails `slot2` 213 |
| saves | a save round trip at each of the seven stations (five banks), on the `--debug` cart through the menu's own input: FULL LOADOUT, the clock moved, a Metroid of another bank killed, the warp, then one of the station bank's Metroids killed and an orb taken; Start on the pad, the reset button (`emu.reset()`), the title's load. `$D808`-`$D814` before the save, in the record and after the load; the record against what she held on Start, the load against the record; the three marks dead in the record and loaded back, the orb not loaded by a warp; the map over the view after the load | our Game Boy running the station's chain from the new game; the cart's own record, as `round trip` | **the load's metatile table not the record's** (`LoadGameGraphics_metaTest`, `beq` to `bra`): every station fails on the view (57). The save's own merge of the live flags is not graded: only `$E:$55`'s buried tank needs it (1.0 Step 18e) |
| oracle | 703 frames of the hand-authored segment, frame for frame, into the Senjoo's contact (1.0 Step 9) | Mesen2 GB | **4/4 pixel faults + 3/3 pose faults** |
| spider segment | 847 frames with Spider Ball held, frame for frame | Mesen2 GB | poses asserted reachable |
| loadout | Hi-Jump 534, Space Jump 336 and Spring Ball 317 frames, frame for frame, each item set through the debug menu on the `--debug` cart | Mesen2 GB, the item's bit and the menu's NMIs given after its frame 0 | **3/3 engine faults**: each item's test blanked differs (Hi-Jump at frame 18, Space Jump at 112, Spring Ball at 28) (1.0 Step 7) |
| beams | power, ice, wave, spazer and plasma into the wall, up and away (258 frames each), and the plasma at a seeded Autoad from two distances and at a missile door (43 each): Samus and the projectile array frame for frame, each beam set through the debug menu | our Game Boy, the beam written after its frame 0 and the same enemy seed before frame 1 | **6/6 engine faults**: the wave's dispatch (76), the spazer's loop (76), the plasma's wall arm (77), the plasma's slot order (76), the enemy hit ignored (3, on all three enemy segments) (1.0 Step 8c). `ice stand` (529 frames, 1.0 Step 8d): an Autoad frozen, stood on and ridden through its thaw into the knockback; **3/3**: the lift's old branch (104), the frozen enemy taken as a hurt (102), the landing's snap on an enemy (103). `hurt`, `varia hurt` and `screw kill` (122, 122 and 109 frames, 1.0 Step 9): an Autoad walked into, with and without Varia, and spun through with Screw Attack, her health graded too (code 254); **3/3**: the horizontal entry's collision flag (position), the halving (254), the screw's item test (position). `septogg ride`, `flitt ride` and `septogg sand` (215, 239 and 267 frames, 1.0 Step 11): onto a platform that carries her, the last in `$B:$24`'s sand; **4/4**: the septogg's carry of her Y (79, and 55 in the sand), the flitt's of her X, each way (79, 191). 1.0 Step 25: `hurt` also counts the objects on the second palette every frame on both machines (**253**), which the unfixed cart failed on frame 9, the hit; and `spike`, a spin jump into `$D:$05`'s ceiling spikes, her position, health and OBP1 objects frame for frame; **3/3**: `DrawSamus_hurtAttr` and `DrawSprite_pal1` (253), `SampleTile_spike` (position and health). 1.0 Step 27b: `door spike` (311 frames), James's route off `$C:$3C`'s door ledge, a standing jump, then left through door $B9's `WARP` into `$F:$C3`: frame for frame to the warp, then the settled last frame only (`oracle.Door`: our Game Boy's samples are its main loop's, which the door blocks); **1/1**: `StartTransition_hurt`, the crossing frame's hurt kept (the settled frame's camera and health), which the engine before the step failed the same way. 1.0 Step 27d: `coral walk` and `coral jump` (210 and 216 frames), `$9:$E3`'s acid coral walked through (no damage, as the original) and jumped through (four ticks), her health frame for frame; **1/1**: `AcidProbe` never hurting (OBP1, frame 58) |
| gfx | twelve pickups on the `--debug` cart, first items through the menu, then the orb's lever: the object characters $8000-$87FF, the frames the transfer takes, the bit, the weapon and the pose | our Game Boy taking the same pickup; its transfer flag sampled at line 144 | **3/3 engine faults**: the ice beam's arm handed the wave's row (9), a whole record a vblank (8), Varia's pose $13 (11) (1.0 Step 8a). 1.0 Step 9 adds Varia's frames and length (12), the bit to the flag (13) and the clock's ticks (14); **3/3 more**: Varia's animation cut (8), the jingle's first pass (13), the jingle's frames not ticking (14) |
| reachable | how far the port survives the any% run from its one handover: 1466/1999 | the published any% TAS | floor (ratchet) |
| fade | door $1DF's fade: 168 frames of brightness against `bg_palette`, 41 of them the scroll the Game Boy hides | the published any% TAS | **a cart that lights at the script's end differs** |
| anchored | the same metric re-anchored per handover: 665 of 6848 frames, 11 of 13 stretches | the published any% TAS | floor + gradable floor |
| durations | 28 of 60 non-playable stretches inside 2% | Mesen2 GB | two floors |
| enemy AIs | 59 rooms agree pass for pass, and slot 0's stun, ice counter and health, the blob thrower's seven, Arachnus's four, the Gamma's and the Zeta's stun counters, the Omega's three, the larvae's three and Samus's health (1.0 Step 17), collapsed, as globals; four cases in flight at once (1.0 Step 12). 1.0 Step 13's `arachnus`, `arachnus roll` and `arachnus kill` freeze Samus, and `Case.fire` holds B on both machines as input over a span of ticks. 1.0 Step 14's `gamma`, `gamma shot` and `gamma kill` freeze her too, and a frozen case does not grade the cutscene flag it forces. 1.0 Step 15's `zeta`, `zeta shot` and `zeta kill` freeze her too; the coin handover watches three stun counters. 1.0 Step 16's `omega`, `omega shot` and `omega kill` freeze her too; the Omega tosses no coin. 1.0 Step 17's `stinger`, `larva`, `larva bomb` and `larva kill` do not: the stinger's freeze is its own, and a larva's business is reaching her. 1.0 Step 21's `baby` and `baby block` do not either; `metroid_babyTouchingTile` is a global, `Case.fire` holds any key (Samus walks in `baby block`), the map in view after the last tick is graded where a case asks (`tiles_end`), and the cart's frame counter is seeded with lead 1, measured by that walk. A hit can be **late** (`Hit.late`), written after Samus's contact test, which would otherwise overwrite it while she touches the enemy | Mesen2 GB | **a blanked AI row per room, in `AiTable` or `AiTableFar`; all 59 differ**; plus 20 behaviour faults: the ice counter's climb stopped (`crawlerA ice`, `crawlerA ice kill`), the wave beam testing the shield (`hopper wave`) (1.0 Step 8b); B ignored (`arachnus roll`), any weapon taken for a bomb (`arachnus kill`) (1.0 Step 13); the bolt fired on the pause's first pass (`gamma`), every left push put back (`gamma shot`), a shot at the bolt's time hurting (`gamma kill`) (1.0 Step 14); the tail wait ended at once (`zeta`), a missile going down pushed left (`zeta shot`), a missile from below hurting (`zeta kill`) (1.0 Step 15); the tail wait ended at once (`omega`), a missile going up or down hurting (`omega shot`), a missile into a left-facing back hurting as one in front (`omega kill`) (1.0 Step 16); nothing added to the shown count (`stinger`), the touch left unlatched (`larva`), a bomb that leaves it on her (`larva bomb`), the fifth frozen missile leaving it alive (`larva kill`) (1.0 Step 17); Samus out of the egg's range (`baby`), the block not eaten (`baby block`) (1.0 Step 21) |
| enemy reload | 6 records leave the screen and come back, pass for pass | Mesen2 GB | **a blanked AI row per case; all 6 differ** |
| status bar | 281/281 HUD ticks agree tile for tile, **plus the recording at 3 sampled frames** | Mesen2 GB + `reference/metroid2.mmo` | **faulted cart differs** |
| recorded | the anchored sweep over the recording's first 2000 frames: 493 of 1648, 11 of 11 stretches | Mesen2 GB replaying `reference/metroid2.mmo` | floor + gradable floor |
| file policy | 93 committable files scanned, ROM n-gram scan | the policy | n/a |

Two rungs the gate does **not** contain, deliberately:

- **`room.zig`'s scenarios are not a rung.** They are the GB-side harness — spawn, draw a room,
  watch a save or a load — that the `load`, `death`, `round trip`, `enemy AIs` and `status bar`
  rungs are *built out of*, plus unit tests under `zig build test`. The paths no movie reaches
  are graded through those rungs, not beside them.
- **The 100% recording is not in the gate** (James, 2026-10-02, 1.0 Step 26). It is graded in
  `verify-full`: the recording's worlds against their pins, and the best ending against the
  credits rung's reference (part 25). A window of it would cost the gate time it does not have,
  and every mechanism it shows already has a rung against our Game Boy.
- **Only the old recording's first 2000 frames are in the gate.** The `recorded` rung grades that
  window; `zig build oracle -- recorded` grades any other, and none of them is cheap enough to
  run every time. The kills, the pickups and the broken blocks are all deeper than 10 000
  frames, so they reach the gate only through the `status bar` rung's three sampled frames
  (45101, 48601, 74001). See finding 4 below.

## The audit: every mechanism ported in Steps 5–15, and in 1.0

Read as: if this mechanism were removed from the engine, what goes red? A cell in the **Fault**
column means the rung has been shown to distinguish a correct cart from a broken one.

| Step | Mechanism | Graded by | Fault |
| --- | --- | --- | --- |
| 5, 5b, 6 | door transition: `WARP`, the computed duration, screen streaming | `snes boot` 7, 8; `reachable`; `durations` | **yes** (Step 25) — `StreamOne` out fails phase 7's streamed neighbour (80); `WarpDraw` drawing no strips, and WARP's frame taken out of `OpExtraFrames`, each fail phase 8's duration (136) |
| 7 | title to game, pose `$13`'s 320-frame sequence | `cold boot` | **yes** |
| 9 | entity foundation: slots, spawn walk, despawn window | `snes boot` 15; `enemy reload` (Step 19) | **yes** — a blanked AI row per case, and the rung's own check that each record does leave and come back |
| 15a | the saved half of the spawn flags, per bank, `$04` out as `$FE` | `snes boot` 26; `enemy reload`'s `alpha2 reset` | **yes** — the translation deleted takes that case from 134/134 to 11/134 |
| 10 | enemy AI, hitboxes, Samus taking damage | `oracle` (700 frames); `enemy AIs` | **yes** |
| 11 | items and pickups | `snes boot` 9, 10, 28 | **yes** (Step 25) — `RunItemPickup` returning at once fails phase 9 (140) |
| 12a | shot and bomb blocks | `snes boot` 11, 12 | **yes** (Step 25) — `DestroyBlock` out fails phase 11 (151) |
| 12b | projectiles and combat | `snes boot` 13, 14 | **yes** (Step 25) — `CollideProjEnemies` out fails phase 14 (165) |
| 12c | bombs: the array and the arm that lays one | `snes boot` 18 | **yes** (Step 25) — `SamusLayBomb` out fails phase 18 (186) |
| 12d | the enemies become visible | `snes boot` 15 (`enemy_draw`) | **yes** (Step 25) — `DrawEnemies` out fails phase 15 (170) |
| 12e | the explosion, the drop, the freed slot | `snes boot` 16, 17 | **yes** (Step 25) — `EnemyAnimateExplosion` out fails phase 16 (177), `EnemyAnimateDrop` out fails phase 17 (182) |
| 12f | the region's enemy AIs | `enemy AIs` (18 rooms then; 23 since 1.0 Step 8b) | **yes** |
| 13a | missiles that fire | `snes boot` 19 | **yes** (Step 25) — `ToggleMissiles` out fails phase 19 (198) |
| 13b | the HUD band | `snes boot` 20; `status bar` | **yes** |
| 13c, 13d | the Alpha: intro, lunge, knockbacks, death | `snes boot` 21, 22; `enemy AIs` alpha cases | **yes** |
| 14 | the Metroid progression chain, `IF_MET_LESS`, the quake | `snes boot` 23 | **differential** — the phase requires each count to disagree with the one before |
| 14b | Spider Ball | `snes boot` 25, 26; `spider segment` | code 239 shown failing against the old dispatch |
| 1.0 8b | the ice beam's freeze and thaw (`enemy_animateIce`, 02:$5652), the thaw's kill, and the beams' damage against ordinary enemies: the wave through a shield, the spazer and the plasma to a kill and its missile drop | `enemy AIs` beam cases | **yes** (1.0 Step 8b) -- the climb stopped and the wave's shield test each differ |
| 1.0 8c | the beams in flight: `samusShoot`'s spazer and plasma loops, `handleProjectiles`'s wave, spazer and plasma arms, the terrain test, and a shot's deletion on an enemy hit (01:$52E3) | `beams` | **yes** (1.0 Step 8c) -- every fault differs; the plasma's slot order failed at frame 11 before its fix |
| 1.0 8d | a frozen enemy as a floor: `collision_samusEnemiesDown`'s lift (00:$34D0), the solid arm of 00:$3545, and the fall's and the falling ball's skip of the row snap on an enemy (00:$1378, 00:$12E7); the thaw's contact under her | `beams` `ice stand` | **yes** (1.0 Step 8d) -- failed at frame 103 before the lift's branch was turned, and at 103 again, on the snap, before `PoseFall` had its test; the falling ball's twin is ported branch for branch and not graded |
| 1.0 11 | skreek, drivel and `drivelSpit`, moto, gravitt, halzyn and the sine motion (02:$677C-$682C), septogg, both flitts; the `.onePoint` and three `.farMedium` probes, `enemy_spawnObject.longHeader` | `enemy AIs` nine cases; `beams` `septogg ride`, `flitt ride` | **yes** (1.0 Step 11) -- every blanked row differs, and each carry fault differs |
| 1.0 17 | the larva (02:$7A4F): the latch and its global state, the bomb that sends it off and the fly-off, the hurt's sprite, the freeze and its own thaw (`enemy_animateIce.call`, 02:$565F), five frozen missiles to the kill, the screw's and bomb's knockback, the seek and `metroid_correctPosition` (02:$7CDD); the room entry's clear of the latch (02:$4013); the stinger (02:$6B83) | `enemy AIs` `stinger`, `larva`, `larva bomb`, `larva kill` | **yes** (1.0 Step 17) -- every blanked row differs and all four behaviour faults differ; the kill case's hits are kill 40's (part 21); the bomb lands only as a late hit; the stinger's case ends on its thaw and the larva cases on a multiple of eight ticks, for the reasons `docs/phase1.md` measures |
| 1.0 21 | the baby Metroid (02:$7BE5): the egg's blink, wiggle, burst and rise with Samus frozen, a hatched baby met again, the Zeta's chase, `baby_checkBlocks` (02:$7D2A) eating tile $64 through `destroyBlock`, `baby_clearBlock` and `baby_keepOnscreen`; `enCollision_up.midMedium` (02:$4C30), and the four mid probes keeping `metroid_babyTouchingTile` | `enemy AIs` `baby`, `baby block` | **yes** (1.0 Step 21) -- both blanked rows and both behaviour faults differ; the block case's eaten tiles are graded on the map |
| 1.0 16 | the Omega (02:$7631) and its fireball, the same AI in another slot: the blinking intro, the seen Omega's start, the spit and the wait on the fireball, the chase picks (`.selectChaseTimer` and its `POP AF`), the chase, the rise and the tail wait, the dink, the dink for a missile up or down, the screw and its chase, the front and back hurts with their unprobed push, the kill; the fireball's aim, flight and burst; `enCollision_up.nearSmall` (02:$4BC2) | `enemy AIs` `omega`, `omega shot`, `omega kill` | **yes** (1.0 Step 16) -- every blanked row differs and all three behaviour faults differ; the kill case's health steps are kill 38's exactly, each missile's direction chosen for the side the recording hit; three gaps are shorter, or the case cart's save RAM ran out before the post-death timer ended |
| 1.0 15 | the Zeta (02:$7276), its husk and its fireball, the same AI in other slots: the intro, the husk's fall, the fight's seek, spit, rise and wait, the dink, the dink from below, the screw and the missile's unprobed push with its coin, the kill; `enemy_seekSamus` (03:$6B44) and its table; `metroid_keepOnscreen` (02:$7DC6); `.oscillateWide` | `enemy AIs` `zeta`, `zeta shot`, `zeta kill` | **yes** (1.0 Step 15) -- every blanked row differs and all three behaviour faults differ; the kill case at full recorded spacing outran the case cart's save RAM, and one idle gap is 500 shorter |
| 1.0 14 | the Gamma (02:$6F60) and its bolt, the same AI in a child slot: the molt, the fight's lunge and bolt cycle, the dink, the screw and the missile's probed push with its coin, the kill; `gamma_getAngle` (01:$723B), its bands and its speed arms; the Alpha's angle, slope and speed moved to bank 1 and the distance split out, as the ROM has it | `enemy AIs` `gamma`, `gamma shot`, `gamma kill` | **yes** (1.0 Step 14) -- every blanked row differs and all three behaviour faults differ; the kill case needed `max_coins` raised from 8, or the ninth and tenth hurts' coins went unhanded |
| 1.0 13 | Arachnus (02:$5109) and its fireball ($52DF): the jump tables as one run, the stand, the spit, the curl on B, the six bombs and the Spring Ball; the `.midMedium` side probes; the warp's sweep in half rows | `enemy AIs` `arachnus`, `arachnus roll`, `arachnus kill`; warp `spring_ball` | **yes** (1.0 Step 13) -- every blanked row differs, both behaviour faults differ, and `spring_ball` failed 44 on the engine before the sweep's fix |
| 1.0 9 | the screw's kill by contact (00:$3629), Varia's halving (00:$2F6B), the horizontal entry's collision flag (00:$3650), `pickup_variaSuit`'s waits and `animateGettingVaria` with its vblank half (00:$27E3, 00:$2BF4), `handleItemPickup_end`'s first pass and its clock tick | `beams` `hurt`, `varia hurt`, `screw kill`; `gfx` codes 8, 12-14 | **yes** (1.0 Step 9) -- `hurt` failed at frame 9 before the flag, Varia's bit to the flag at 191 of 192 before the first pass, and every ordinary pickup at 0 ticks of 1 before the tick |
| 1.0 7 | Hi-Jump, Space Jump, Spring Ball: `PoseJump`'s rise, `PoseSpinJump`'s space jump, `PoseMorph`'s ball jump, and the arcs they set | `loadout` | **yes** (1.0 Step 7) -- each item's test blanked makes its segment differ |
| 1.0 2-5 | the pause (00:$2C79, mode $08) and the debug menu: the chord, the tree, SAMUS, METROIDS, FLAGS, CLOCK, and WARP's chains, spots and enemy sweep | `pause` 110-124; `scenario` (four Samus scenarios and four world ones); `warp` | **yes** (1.0 Steps 2a-5c) -- 11 pause faults, 6 scenario faults, the chains cut to their door and three engine faults in `warp` |
| 1.0 6 | her room's entry and raster split: `ENTER_QUEEN`, `queen_renderRoom`, three HDMA channels built from `VBlank_drawQueen`'s list | `warp` `queen` | **yes** (1.0 Step 6) -- `QueenApply` out fails 36 |
| 1.0 10 | the refills drawn and blinking (OBP1), the missile refill's `metroidCountReal` test and its credits branch; the larvae on METROIDS | `warp` `refills`, `refill_credits`; `scenario` `larvae` | **yes** (1.0 Step 10) -- OBP1 at $84 (39), the count test removed (43), `DebugDispMoves` answering "moves" (11) |
| 1.0 12 | glowFly, proboscum, both skorps, autrack, autom, gunzoo, missileBlock, blobThrower and `blobProjectile` | `enemy AIs` nine cases | **yes** (1.0 Step 12) -- every blanked row differs; the missile block's weave is reached by neither record and not graded |
| 1.0 18 | the world: every door script on the cart (18a), the new game from `initialSaveFile` (18b), cells booted from the walked reading (18c), the lava rooms at their counts (18d), a save at every station (18e), the warp table's recorded truth (18f) | `doors`; `counts`; `saves`; `verify-full`'s worlds | **yes** (1.0 Step 18) -- `LoadMetaBase` reading table 0 (26), `IF_MET_LESS` inverted, the load's metatile test (57); the worlds held to `src/worlds_misses.txt` by name, the reach faulted by solid respawning blocks (179 out) |
| 1.0 19-20 | the Queen: her fight, hurt and flash (BGP mid-frame as INIDISP and COLDATA bands), being eaten, the stomach, her death, and out of her room by `ESCAPE_QUEEN` and `EXIT_QUEEN` | `queen` (eight cases) | **yes** (1.0 Steps 19b-20d) -- 22/22 faults in the sweep, each a routine of hers taken out and failing its case; her death's length 596 frames, 100.00%, the recording's too |
| 1.0 22 | the fade (mode $12), the credits (mode $13), the four endings by `gameTimeHours`, the soft reset (00:$02E1) | `verify-full`'s `credits` | **yes** (1.0 Step 22c) -- 4/4: the fade's index (51), a pixel every second frame (54), the best ending's `CP $03` (55), the soft reset's mask (60). Out of the gate on time |
| 1.0 27a | a Metroid's death with its slot kept across `earthquakeCheck` (08:$7EBC, X kept); a crossing's reset (02:$418C, $4217) leaving the fight to `HandleEnemies` as the original does, 02:$412F's three on a load and the Queen's escape only | `warp` `missile_kill` | **yes** (1.0 Step 27a) -- 50 on the engine before the step, and 50 under each fault: the fight cleared by the reset, `ply` for `plx` |
| 1.0 27b | a door's start clears the hurt its frame's probes set (00:$0C4F) | `beams` `door spike` | **yes** (1.0 Step 27b) -- failed on the engine before the step, and under `StartTransition_hurt` |
| 1.0 25 | OBP1 in acid and i-frames (01:$4DFC, $4B95), spikes (00:$2016), the pause's dim on screen, GAME OVER in her room (00:$36BB) | `beams` `hurt` (253) and `spike`; `snes boot` 149; `pause` 125; `queen` `still` (49) | **yes** (1.0 Step 25) -- each fix's routine taken out fails its code, and each code failed on the cart before the fix |
| 15a–d | save, load, death, round trip | `load`; `death`; `round trip` | **yes** (three fault runs) |
| 24g | the window raise (`rWY` $80 at a station and in a major item's jingle, 01:$5803-$582C, 00:$3A21) and the bar: `saveTextTilemap` at boot, `ITEM`'s name (00:$269F), BG2 on the object characters | `snes boot` codes 1 (every frame), 2 and 4 (phase 28's jingle, pixels), 3 (boot and phase 28's four doors) | **yes** (Step 24g) — `WriteWindow` out fails phase 28's picture (2); `ItemNameResolve` out fails phase 28's name (3); all four codes shown failing on the pre-fix cart |
| 24h | the title's file select (05:$4118): the menu through `drawNonGameSprite`, Select's toggle, Down's mask, the clear (05:$42A6); the title's object characters; the window off and `!WinY` set before NMI; the title a line lower | `title` 92–99; `death` 193 | **yes** (Step 24h) — `TitleDraw` and `DrawNonGameSprite` out fail 96, `UploadTitleObj` out fails 94, the clear out fails 95; the pre-24h cart fails 93–99 and `death` 193 |
| 24i | the three slots (B14): Right and Left (05:$41E5-$4223) with the sound and both wraps; `bootRoutine`'s seed from `saveLastSlot` (00:$02B6), on the title's path only; the save, the load, Start's walk, the clear and both spawn-flag copies through `!SlotP` at `$A000 + slot*$40` and `$1000 + slot*$200`; Start writes the slot to `$A0C0` | `title` 92, 95, 97, 103; `round trip` 213–215 | **yes** (Step 24i) — `TitleSeedSlot` out and its bound widened fail 92, `TitleSlotStep` out fails 95, `SlotRecP` held at slot 0 fails 97; the 24j cart fails `title` 92, 95, 96, 97, 103 and `round trip` 213 |
| 24j | "Super" on the title (B15, the one deliberate presentation divergence): `assets/title_super.png` decoded at build time, BG1 characters, BG palette 7 and a map patch uploaded under forced blank, BG1 on the play band, the patch cleared after the exit's forced blank | `title` 101, 102 | **yes** (Step 24j) — `UploadTitleArt` out and the header's column read moved fail 101, `ClearTitleArt` out fails 102; the 24h cart fails 101 |
| 24e | Samus behind the background on the screens whose transition word has bit 11 (00:$3ED5, 01:$4BA1); play-field words at BG3 priority 1 | `cold boot` 155; `snes boot` code 20 per frame; `room.zig` on our GB | **yes** — the pre-fix cart fails cold boot (155); `LoadScreenPri` forced to behind fails `snes boot` (20) |

### What the audit found

**0. Two rows moved on 2026-09-16, and they are Step 19's.** B4a's despawn window was one of the
nine `snes boot`-only rows and one of the four with no fault check that six of the eight open
playtest defects clustered on — and the lost-Metroid defect that sat on it turned out to have
been fixed by 15a and to have had **no guard at all** until now. The second row is 15a's own
flag translation, which is what that fix was. `enemy reload` is their grader: the camera is driven off
an enemy and back on both machines to the same schedule, and what is compared is whether the
*record* is live again and under which spawn flag. Three of its six cases fire the room reset a
transition asks for while the record is off the screen — which is the half of a crossing that
decides whether a Metroid can come back, because Metroid spawn numbers are in the saved half of
the flag array and a room load refills only the unsaved half. **Read the rung for what it says
and not for more:** it grades the despawn window, the delete, the reactivate and the walk's
reload, with Samus frozen and the camera written; it does not grade a crossing.

Its fault check is two things, and the second was found by trying the first. Each case's cart is
also run with the case's AI row blanked and has to differ. And `$04`'s translation to `$FE` was
deleted from `ResetEntities` by hand — the behaviour before 15a, and the defect the lost-Metroid
entry in `bug_tracker.md` was — which takes `alpha2 reset` from 134 of 134 passes to 11. That
run is also what exposed a hole in the fixture: the out-pass is skipped while
`previousLevelBank` is zero, so a case firing one reset graded the load-in against a
boot-filled buffer and passed with the translation gone. Every reset case now fires two.

**1. `snes boot` carries the most ported mechanism and has the least mutation coverage.** Nine
of the seventeen rows above are graded by a `snes boot` phase and nothing else, and the rung
has no fault run. Every other emulator rung in the gate has one. The cost of that is already on
the record: `verify.zig`'s `enemy_draw` arm exists because the enemies had collision, damage and
AI and *no picture*, and "every rung in this repository was blind to it" — they all graded
position, camera, pose or the background, and the sprite check graded Samus alone.

Individual phases do defend themselves in places — phase 1 refuses a record that left the
countdown at zero, "without which every phase below passes vacuously"; phase 23 is a fixture
only because each Metroid count must disagree with the one before; phase 25's check was
tightened when its first version passed against the old dispatch. These are good and they are
ad hoc. There is no systematic per-phase fault run.

**Closed by Step 25, 2026-09-25.** `verify.zig`'s `boot_faults` takes eleven mechanisms out of
the image the clean run has just passed, one at a time, and a fault counts as caught **only when
the phase that grades that mechanism is the one that fails**; one caught anywhere else fails the
gate, because it shows the rung can fail without showing the phase can see. Every row above that
had a dash now has at least one fault, and each was caught where the table says on the first
try. One fault needed correcting first: a bare `rts` on `RunItemPickup` left carry as it found it, skipped the frame's
drawing and was caught by the HUD (205), so its fault is the routine's own nothing-to-do exit
(`clc`), and `WarpDraw`'s is the original's no-waits path for the same reason. The eleven run in
parallel under Step 24d's frame-skip switch. Alone the slowest takes 5 s; in the gate, beside the
other emulator rungs, the gate went from 7m24s to 7m51s (twice), so about 27 s.
**What it does not cover:** phases 20–28. Their rows carry a fault check elsewhere in the table
(the HUD, the Alpha, the Metroid chain, the Spider Ball, save and load), or, for 27 and 28, the
Steps 17–24 codes that were shown failing on the pre-fix carts; none of those is in this sweep.

**2. The eight open defects cluster in exactly the rows with no fault column.** As of
2026-09-15 `bug_tracker.md` carries eight defects found by playing the cart and not by any
rung: hurtboxes active during a transition, a shot dragged across a vertical scroll, a Metroid
lost permanently on leaving the screen, the fade transition also scrolling, invisible missile
doors, acid that neither drops nor damages, invisible missile ammo upgrades, and corrupt
graphics on the Bomb and Spider Ball upgrades. Six of the eight land on B1's transition, B4a's
despawn, B5's projectiles or B6's items — four rows with no mutation check. This is a
clustering and not a proof of causation, but it is the strongest evidence the audit produced
that the missing fault coverage is where the port is actually weakest.

**3. The anchored rung's number is greener than it reads.** `665 of 6848 frames across 11 of 13
stretches` — and **nine of the eleven gradable stretches play zero frames**, stopping on the
anchor's first frame with Samus's position or the camera's motion already diverged. The floor
of 665 is met by stretches 0 and 6 alone. The floor is a regression ratchet and is doing its
job; what it is not is a coverage claim, and the printed line invites reading it as one.

**4. The recording grades three frames.** `reference/metroid2.mmo` is 76 951 frames covering
both Alpha kills, four pickups, a save, a death and a reload — the only reference that reaches
any of them, because neither published TAS kills a Metroid inside its horizon. The gate reads
it at three sampled frames, in the `status bar` rung. The machinery to do more exists
(`src/gb_trace.zig`, `oracle -- recorded`) and is not wired to the gate.

**Narrowed by Step 26 (2026-09-26), not closed.** The `recorded` rung grades the recording's
first 2000 frames: 11 stretches of James's play through the opening rooms, which the any% run
never walks. The frames this finding is about, the kills, the pickups and the broken blocks,
are not in that window and cost far more than a gate run to reach. A pass replays from the
movie's start, and deep anchors that never settle spend all fifteen settle rounds.

**5. The seeding of the anchored sweep's world is unfalsified.** `oracle.Seeding.pristine` is
built and has never run anywhere it could show a difference; `faultsCaught` reads 0 of 1 and
that 0 means *never asked*. Deferred by decision on 2026-09-15.

**Asked on 2026-09-26 (Step 26), and still unanswerable.** `oracle -- recorded 10000 2000 8
fault`, the only early window where the recording breaks blocks, ran for 47 minutes. 22 of its 26
anchors never settle, all on tileset assignment: map 6 cells $6B and $6C on table 9 where the
Game Boy shows table 4 on 391–399 of 399 tiles, and map 3 cell $21 on table 5. The one seeded
stretch (6 tiles) plays 1 frame with the seeding and 1 without. So the fixture still has no room
in which to show a difference. What it waits on is the assignment for those cells, which is B12's
and in `docs/bug_tracker.md`, not more machinery.

**Answered on 2026-09-30 (1.0 Step 18c), once B12's cells were drawn from the walked reading.**
The same command: all 26 stretches can be booted into (207 of 1852 frames reached), 17 are
seeded with 122 tiles, and **4 of the 17 lose frames without the seeding**; stretch 21 plays 33
frames with it and 0 without, stretch 12 plays 25 and 10. So the seeding is falsified. The
command still ends in `FAIL`, because its rule asks every seeded stretch to lose frames, and a
stretch that ends before it reaches a seeded block cannot. Whether that rule becomes "at least
one", like every other fault, is James's to decide.

**Closed on 2026-09-30 (1.0 Step 18c2): "at least one", with pins.** James took the lenient rule
on condition that drift stays visible. The fixture passes on one catch, and every anchor that
catches at `13a4736` must still catch (`oracle.seeding_catches`: 10327, 10390, 10832, 11567),
with the seeded stretches together still playing 168 frames (`seeding_frames_floor`). A loss
fails and names the anchor; a gain prints "raise the pin"; an accepted loss lowers the pin in its
own commit with a turn-log row (`porting_loop.md`). A false pin at 10791 was watched failing by
name. It runs in `zig build verify-full`, the slow tier, with a missing emulator or recording a
failure there rather than a notice.

### The slow tier: `zig build verify-full`

The gate, then the rungs too slow for it, held to pins rather than to "every case": run at the
close of any step that touches the world, the boots, the seeding or the ending. Three rungs
(1.0 Steps 18c2 and 22):

- **The seeding fixture** (`oracle -- recorded 10000 2000 8 fault`), above.
- **The recording's worlds** (`gbtrace -- reference/metroid2-100p-recording set worlds`): at the
  middle of each visit, the tiles Mesen's Game Boy shows against the table the port draws the
  cell with, a walked lava room's table replayed at the visit's count (`warp.LavaReplay`, 1.0
  Step 18d). The walked reading explains 641 of 953 visits; the other 312 are listed in
  `src/worlds_misses.txt`, one line per visit, so a new miss fails by name and a fixed one
  prints "raise the pin". Mesen replays the 25 segments eight at a time (about five minutes
  cold, from about 45 one at a time), and its answers are cached in `build-out/mesen-cache/`
  under a hash of the stamped cart, the script and the emulator, so a re-grade of a new reading
  takes a second.
  The same run holds two more things (1.0 Step 18f). **`src/recorded_tables.txt`**, the table
  at every visit, which the warp table reads: a line the recording no longer says, or a visit
  the file lacks, fails by name. **The warp rooms' reach**: every position Samus held in a
  warp entry's room, at a count the recording shows the entry's table at, has to be one
  `warp.reach` says a ball gets to from the room's doors (count zero with the baby's blocks
  eaten), under what the entry's chain leaves at that position's count. 35 849 of 35 888; the
  39 out are edge crossings, pinned (`reach_misses_pin`, with a floor on the positions
  graded). Fault: the respawning blocks ($00-$03) left solid, 179 out.
- **The credits** (`zig build credits`, 1.0 Step 22c; also run alone, or one clock or fault by
  name). Six clocks each side of 3, 5 and 7 hours on the `--debug` cart, set on CLOCK: 2:59 by
  the game's own way in (every METROIDS row killed, the Queen's last, ten missiles fewer and
  `$F:$76`'s missile refill touched), the rest by WARP's ENDING. Reference: our Game Boy from
  the refill's lever with the same clock (`credits.reference`), its frame counter set at the
  first credits pass to the cart's, which is the route's own and pinned per clock (exit 50).
  Both read at the top of every pass, on the pass before's: the fade's palette and length,
  the characters the setup leaves, the scroll, the state, the done flag and a hash of the
  objects every pass to 600 past the ending's settling, the tilemap and the objects in full
  on six passes, then B, Y, Start and Select to the title. **4/4 engine faults**: the fade's
  index from the countdown's low bits (51), a pixel every second frame (54), the best
  ending's `CP $03` made $04 (55), the soft reset's mask matching nothing (60). Out of the
  gate because it took it past its fifteen minutes (16m20s with it).

### Fixture-first compliance

Step 3's standing rule — every defect found by hand gets a failing fixture, written first and
shown failing, before it is fixed — was audited across all 46 `bug_tracker.md` entries.

- **40 carry an explicit `Guarded by:` line.** No closed entry was found that was fixed without
  a guard.
- **Four closed entries describe their guard in prose instead of on a `Guarded by:` line** —
  the Step 12e pair ("the gate now has a phase that kills a slot outright…", "the guard now
  covers the frame after a projectile as well"), the Step 5b script-end entry, and the 2026-08-31
  template placeholder. A formatting inconsistency, not a rule violation: the guards exist and
  the entries say what they are. Recorded here rather than backfilled quietly, per the sub-task.
- **Eleven open entries have no guard**, which is the rule working as written: the guard is due
  before the fix, and none of the eleven is fixed. Eight of them are the playtest defects above.

### Rungs retired this cycle

**None.** `feature_tracker.md`'s D1 criterion is "green end to end with no rung retired", and
the same holds for D2: every rung that existed at the start of Phase 0b still runs. What was
retired during the cycle is internal — `!EnChild` on `enemy_deleteSelf`'s parent link,
`!EnUnhandledState`'s Metroid arm, and the Alpha's `.death` recorder arm at Step 13d — all
recorder arms made redundant by the mechanism they were standing in for being ported, none of
them a grading path. Recorded in `residue.zig` at each field.
