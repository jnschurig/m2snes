---
created: 2026-09-26T04:11:06Z
updated:
  - 2026-09-26T04:11:06Z
  - 2026-09-26T04:53:23Z
  - 2026-09-27T01:02:22Z
  - 2026-09-27T02:03:35Z
  - 2026-09-27T04:20:41Z
  - 2026-09-27T16:49:29Z
  - 2026-09-27T17:31:09Z
  - 2026-09-27T19:12:08Z
  - 2026-09-27T21:57:52Z
  - 2026-09-28T01:43:03Z
  - 2026-09-28T03:48:27Z
  - 2026-09-28T06:03:06Z
  - 2026-09-28T07:58:15Z
  - 2026-09-28T14:38:09Z
  - 2026-09-28T18:13:14Z
  - 2026-09-28T18:13:55Z
  - 2026-09-28T20:09:49Z
  - 2026-09-28T21:37:59Z
  - 2026-09-28T22:32:43Z
  - 2026-09-28T23:48:49Z
  - 2026-09-29T02:40:05Z
  - 2026-09-29T05:22:56Z
  - 2026-09-29T20:27:48Z
  - 2026-09-29T21:55:44Z
  - 2026-09-30T00:55:23Z
  - 2026-09-30T02:43:19Z
  - 2026-09-30T04:09:45Z
  - 2026-09-30T15:02:12Z
  - 2026-09-30T16:12:55Z
  - 2026-09-30T23:24:53Z
  - 2026-10-01T00:50:50Z
  - 2026-10-01T02:32:50Z
  - 2026-10-01T05:03:40Z
  - 2026-10-01T14:18:43Z
  - 2026-10-01T16:45:41Z
  - 2026-10-01T19:30:24Z
  - 2026-10-01T21:27:15Z
  - 2026-10-01T22:09:13Z
  - 2026-10-01T23:30:30Z
  - 2026-10-02T01:53:20Z
  - 2026-10-02T03:41:12Z
  - 2026-10-02T14:26:40Z
  - 2026-10-02T14:45:46Z
  - 2026-10-02T19:24:07Z
  - 2026-10-02T22:22:21Z
  - 2026-10-03T00:46:04Z
  - 2026-10-04T02:44:09Z
  - 2026-10-04T03:46:28Z
  - 2026-10-04T04:15:47Z
working_directory: /Users/james/git/snes_game_dev
---

# Implementation Plan

## Status: Complete

## Overview

The order is: tooling first, the one real technical risk second, then content in the order
the game hands it to the player. The debug screen (C8) comes first because it is the harness
every later step is set up and played with. It also gets a gate rung, `scenario`, which sets
up the cart through the debug screen. That rung exists because `snes boot` has used most of
its one-byte exit codes. The Queen's raster split is spiked before any content. Items come
before the enemies that react to them, and ordinary AIs before the Metroid species and the
Queen. The world pass follows, then the ending, then the close.

All code work is in `~/git/m2snes` on `remote-init`. This plan and the requirements live in
`snes_game_dev/.local/docs/`.

### Every step closes with

These apply to every step that touches the engine or the gate. They are not repeated per
step; a step's own sub-tasks list only what differs.

- **Port branch for branch** from the disassembly (`zig build disasm`), in the original's
  order, with the GB address of each branch in the comment. Don't skip a branch because it
  can't fire yet (`docs/porting_loop.md`).
- **One graded case and one fault per mechanism, at minimum** (the lighter-touch rule).
  - AIs: a case in the `enemy AIs` rung, and the cart with that `AiTable` row blanked must
    disagree.
  - Other mechanisms: a `scenario` (Step 3) or an oracle case, shown failing on a named
    fault.
  - Operand coverage in `correspond.zig` is added where it is cheap, not required.
- **Defects found by hand get a failing fixture first**, shown failing against the unfixed
  engine (the standing rule).
- **Bookkeeping:**
  - `ledger.zig` rows where the boundary check allows, and `residue.zig` for new variables.
  - `zig build engine`, committing `engine.bin` and `engine.sym` with the source.
  - `docs/feature_tracker.md` and `docs/bug_tracker.md` updated.
- **`zig build verify` green**, with the gate's wall-clock time noted in the commit message.
  The budget is set in Step 1 and **enforced every step**. A step that takes the gate over
  budget splits a slow tier out (a `verify-full`) in that step, not at the end.
- **Region fill.** A step that adds converted data re-reads the gate's `snes layout` line.
  If any region crosses 95%, it is resized in `snes_layout.reserved` in the same step. The
  engine finds regions through `RegionTable`, which the builder fills, so a resize is a
  build-time change and needs no reassembly.
- **A playtest ask that names the visible symptom first** (see the memory rule). It is
  omitted where the hardware can't show anything the gate doesn't.
- Commit on `remote-init` with the step's number, as in 0b.

## Steps

- [x] **Step 1: Census, roster and triage — the backlog derived from the ROM**
  - [x] Whole-ROM AI census: every AI address that any enemy header named by any spawn
        record, in all seven banks, dispatches. Extend `enemy_oracle.census`/`.pending` to it,
        with a unit test that fails if a census AI is neither in `AiTable` nor pending. Record
        any of the 26 unported AIs no spawn record reaches, with the reason
  - [x] Metroid roster: every spawn record whose AI is a Metroid species, with bank, cell,
        species, spawn-flag location and an area name. A ROM-backed test asserts roster plus
        Queen equals the ROM's starting `metroidCountReal` (`$47`, read from `initial_save`).
        Area names are our own words, derived from the map bank and region
  - [x] Destination lists for the warp page:
        - save stations, found by where the station's collision type sits in the converted
          screens;
        - item locations, from the item orb's spawn records;
        - each Metroid's room and the room next to it on the door graph;
        - the Queen's room (`ENTER_QUEEN`'s target) and the room before it;
        - the ship.
  - [x] Door-script coverage: decode all 512 scripts. List every opcode each uses against
        what `RunDoorScript` handles, with `ENTER_QUEEN`, `EXIT_QUEEN` and `ESCAPE_QUEEN`
        named
  - [x] Triage every open `bug_tracker.md` entry (11 today; 13 by Step 1, with James's two of 2026-09-25/26) into *fix in Step 25*, *accepted
        compromise* (reason written) or *diagnostic only*
  - [x] Measure the baselines this cycle will move:
        - gate wall-clock time (9m12s at 0b close);
        - every region's fill in `snes_layout` (`chr_obj` is 92%);
        - free VRAM;
        - `snes boot`'s free exit codes.
        Set the gate time budget, proposed at 15 min
  - [x] Write `docs/phase1.md` (the counterpart of `slice.md`) with all of the above. Add the
        `C*` section to `docs/feature_tracker.md`
  - [x] Verify: `zig build test` and `zig build verify` green; roster count test passes and
        fails with one record dropped

- [x] **Step 2: C8a — the debug screen: enabling, paging, and the Samus page** *(split as it
      went: 2a the pause, `8b7146d`; 2b the enabling, `9dfc77f`; 2c the screen, `7ab4cce`)*
  - [x] A `DebugAllowed` byte in the engine image. The builder's `--debug` patches it
        (`snes_inject`), and both builds stay deterministic. The gate builds both carts
  - [x] Title screen: a button combination held on Start sets `debugFlag` only when
        `DebugAllowed` is set. `titleScreenRoutine`'s retail clear (05:$4118) runs first and is kept. Pick the
        combo and write it into `docs/setup.md`
  - [x] Port the pause first: game mode $08 (`gameMode_Paused`, 00:$2CED) is not in the port,
        and James's 2026-09-25 `bug_tracker.md` entry asks for it (Step 1 triage). Start off a
        station pauses and unpauses as the original does. Fixture first, failing on today's cart
  - [x] Pause with `debugFlag` set opens the debug screen as its own game mode. It gets its
        own BG layer and tilemap region, so nothing in the play field's VRAM is disturbed. It
        uses the item font plus digits, pages with L/R, moves with the D-pad, and edits with
        A/B. Exit restores the layer mask and returns to pause
  - [x] Samus page: the item/upgrade bits (Bombs, Hi-Jump, Screw, Space Jump, Spring,
        Spider, Varia), the equipped beam, energy tanks 0–5, max and current missiles, and
        **full loadout**. Writes go to the same variables the pickups write, and the HUD
        follows
  - [x] A read-only status line showing the unhandled recorders: `!Unhandled`,
        `!EnUnhandledAi`, `!EnUnhandledState`, `!ItemUnhandled` and `!PrUnhandled`. Playtests
        then report a gap as a number, not a description
  - [x] Gate, retail build: a full `snes boot` run with the combo held at the title leaves
        `debugFlag` clear, and the frames match the run without the combo *(the `pause` rung's
        combo run, since `snes boot` never shows the title: graded frame for frame against the
        GB, which has no L or R)*
  - [x] Gate, debug build: the screen opens from pause. Fault: `DebugAllowed` ignored, so the
        retail cart opens it and the check fails
  - [x] Playtest ask: "on the `--debug` cart, the combo then pause shows the menu; on a
        normal cart the same buttons do nothing"

- [x] **Step 2d: C8 revised — the menu as the practice hack's** *(James, 2026-09-27, after
      the first hardware try: the title combination was order-sensitive and the screen only
      opened from the pause; `0d64987`)*
  - [x] Drop the title combination (`TitleDebugCombo`); keep the retail `debugFlag` clear.
        Put the `debugFlag` arms of `tryPausing` and `gameMode_Paused` back to the plain port
  - [x] The chord: on a `--debug` cart, L, R and Start all held with one of them new this
        frame opens the menu from `MainLoop`, ahead of the pause and the play handler, and
        closes it again. The menu is its own frame: nothing else of the game's runs, the
        brightness is full, and closing puts back the layers and `bg_palette` it found
  - [x] The tree: a root page (SAMUS, READOUT, CONTROLS) and pages under it. A opens,
        toggles or runs; Left/Right change a number; Up/Down move; B goes back, and closes at
        the root. Changes land the moment they are made
  - [x] The readout: a root switch on a `--debug` cart, whose L+R shortcut goes; the retail
        cart keeps L+R
  - [x] Gate: the retail cart's run with the chord in play is still the Game Boy's; the debug
        cart's opens the menu with the chord, opens SAMUS with A, goes back with B, closes
        with B at the root, and plays on; the play field's VRAM is untouched. Faults: the
        enable ignored, the chord's check, the close
  - [x] `docs/setup.md` rewritten for the chord and the tree
  - [x] Playtest ask: "on `m2snes-debug.sfc`, L+R+Start mid-walk shows the menu and Samus
        stays put; B twice closes it and she walks on. On `m2snes.sfc` the same chord only
        pauses"

- [x] **Step 3: The `scenario` rung — carts set up through the debug screen** *(`88a3a6c`)*
  - [x] A scenario is a small Zig-described script. It boots the debug cart, opens the menu
        with the chord, drives it with pad input to reach a state, runs its body, and checks.
        Each is its own Mesen2 run, with its own exit-code space, and they run in parallel.
        Record why in `docs/conformance.md`: `snes boot`'s code space and Lua's 200-local limit
        (memory: silent test traps)
  - [x] The setup goes through the menu's own input path. No RAM pokes, per the rule that
        fixtures don't force cart state
  - [x] First scenarios: each Samus-page field set and read back from the variable the game
        reads, plus full loadout. Fault: the menu writes the wrong bit for one item
  - [x] Add the rung to `docs/conformance.md`'s roster with its reference and fault

- [x] **Step 4: C8b — Metroids, flags and clock pages** *(`7cab7be`)*
  - [x] Metroids page from Step 1's roster: a converted table blob naming each Metroid by
        number, area and species
  - [x] Marking a Metroid killed runs the kill's bookkeeping, as `.death` (02:$6D61) and its
        callers do:
        - its spawn flag, in the live slot or the saved flag array;
        - both counts down one in BCD;
        - shuffle timer `$C0`;
        - `nextEarthquakeTimer` armed through `earthquakeCheck`.
        Marking one alive restores the flag and both counts, and arms nothing
  - [x] Flags page: every **saved-half** spawn record that is not a Metroid (52: item orbs,
        missile doors and blocks, Arachnus, the stinger, the baby), one scrolling list in bank
        and cell order, named by cell and by item where an orb is present. The other 567
        records are cleared on every room entry (02:$418C), and Metroids are the Metroids
        page's (James, 2026-09-27)
  - [x] Clock page: `gameTimeHours` and `gameTimeMinutes` editable
  - [x] Scenarios:
        - Metroids killed from the menu → the quake runs once it closes. The door drawing
          the new count's lava table moved to Step 5: from a new game no gated door is within
          a scripted walk (right loops back through $052, left through $0D6);
        - alive restores the count;
        - a flag marked and reset reads back from the byte the loader reads;
        - the clock shows what was set.
        The respawn itself moved to Step 5, which can warp to an item's room (James,
        2026-09-27).
        Fault: the kill not arming the quake

- [x] **Step 5: C8c — the warp page, built from the ROM** *(split as it went, James
      2026-09-27: the ROM alone does not settle about half the destinations' tilesets, so
      the Game Boy walks the doors)*
  - [x] **5a: the door crawl and the warp table** *(`027694a`)*. `src/crawl.zig`: our GB tries every
        door with Samus stood one or two tiles from it (the middle of the screen as a
        fallback) and walked, fallen or jumped through; the engine decides whether she
        passes and what loads. Rooms are crawled from the new game; a room nobody walked
        into is seeded from the static reading (`warp.Inference`: door graph, else
        `screens.assign`), and each arrival records whether it is GB truth (walked from
        truth, or through a door that loads a whole tileset). A door that branches on the
        count is retried at the counts where it goes elsewhere. The crawl is a cached
        build step. `src/warp.zig` builds each destination's chain from a walked door into
        its room, and its standing spot; a destination with none is a finding
  - [x] **5b: the cart's warp and the WARP page** (the sub-tasks below that touch the cart) *(`b0fb978`)*
  - [x] **5c: the GB reference and the scenarios** (the sub-tasks below that grade) *(`b797ad6`)*
  - [x] Build time: for each Step 1 destination, derive a **door-script chain** from the
        ROM. Its opcodes other than `WARP` (COPY, TILETABLE, COLLISION, SOLIDITY, DAMAGE,
        SONG) fix the loaded state, and its last script's `WARP` enters the destination
        room. The chains become a converted blob. **When the door graph cannot settle a
        destination's loaded state**, fall back to the loaded state the GB saves at the
        nearest save station on a path in (the save record's `$D808`–`$D814` block holds
        exactly this). If that fails too, the destination goes to James as a finding. It is
        never dropped silently, because C8 requires it on the list *(5a's crawl stands in
        for the save-station fallback; the 5 it cannot settle are findings in
        `docs/phase1.md`)*
  - [x] Build time: a standing spot per destination, from the destination cell's solidity:
        the nearest floor with headroom to the station, orb or door point
  - [x] Cart: the warp runs the chain through `RunDoorScript`, places Samus at the spot, and
        redraws the room and spawns enemies the way the load path (B7) does. The mechanism
        (a real crossing versus the load path's redraw) is chosen in this step, and the
        choice is written down *(a redraw, as a load; plus an enemy sweep for the scroll
        it lacks: `docs/phase1.md`, Step 5b)*
  - [x] GB reference: our GB harness runs the same chain by setting the door index, which is
        how the original's own debug warp reached the Queen (`loadDoorIndex`, 00:$0C37). Compare the metatile
        table, the collision table and the tile VRAM after arrival *(the whole `$D808`-`$D814`
        block, the damage, and the characters the loaded table draws; in the cart's order, since
        what a chain does not load is what the warp before it left)*
  - [x] Scenarios (from Step 4, which a new game cannot walk to):
        - warp to an item's room; marked taken on the Flags page, the orb is not loaded;
          reset, it is;
        - warp beside a gated door; a Metroid killed from the menu, and the door draws the
          lava table the ROM's pointer table gives for the new count (as B8's code 227);
        - warp into a Metroid's room; killed from the menu while live on the screen, it is
          taken off it and a fight it was in ends
  - [x] Scenarios: **every** entry arrives with Samus standing (not falling for 60 frames,
        not in a wall), and the tileset matches the GB reference. Fault: the chain truncated
        to its last script differs on at least one entry *(found and fixed two warp defects:
        a ball's hop, and a Metroid in a blank cell drawing the blank cell)*
  - [x] Documented in `docs/setup.md`: the pages, the controls, and what each warp does

- [x] **Step 6: C4 spike — the Queen's room, and her raster split on the SNES**
  - [x] Port `ENTER_QUEEN` (its arm of `executeDoorScript`, 00:$239C) and `queen_renderRoom`
        (00:$0673), so the Queen's room can be entered at all. Step 5's Queen-room warp
        entry and this spike both need it. Grade the room's tilemap after entry against our
        GB
  - [x] Measure what the Queen changes mid-frame: `VBlank_drawQueen` (03:$7CF0), the LYC
        setup at 03:$6D4A and the LYC handler, and which of SCX/SCY/WX/WY/LCDC change at
        which lines. Take the numbers from the running GB in the Queen room, reached by
        `ENTER_QUEEN`
  - [x] Prototype on the cart: warp to the Queen's room and draw her body and the room behind
        with the split reproduced. Use HDMA onto the BG scroll registers and/or an H-IRQ,
        alongside the existing HUD window band
  - [x] Compare the play window against our GB PPU's frame at a few graded frames; measure
        the CPU and HDMA channel cost
  - [x] Write the GO/NO-GO and the chosen technique into `docs/phase1.md`. If NO-GO, stop and
        bring it to James before Step 20 *(GO: three HDMA channels, TM, BG3 scroll and window 2
        as the head's columns. Pulled forward from Step 19: her actors and
        `queen_setActorPositions`, the head's drawing, no row streaming in her room. Left for
        Step 19: BGP mid-frame as an INIDISP band, and moving the table build out of NMI, which
        leaves 5 lines of vblank)*

- [x] **Step 7: C5a — Hi-Jump, Space Jump, Spring Ball** *(`0739c7d`: nothing needed
      porting; the grade found two oracle defects, the segment's counter seed 2 high and the
      bisection dropping the cart's setup)*
  - [x] Exercise the ported `!Items` branches for all three. Port any Space Jump branch in
        the spin-jump pose that is missing (grade first; port what the grade shows missing)
  - [x] Grading: a **loadout segment** for each item. Our GB harness and the cart start in
        the same room with that item (the room harness, F10), take the same input script,
        and compare position, camera and pose frame for frame, as the segment oracle does.
        The cart side is set up through the debug screen
  - [x] Faults: each item's branch blanked makes its segment differ

- [x] **Step 8: C5b — `loadGraphics` and the beams** *(split as it went, 2026-09-28: the
      sheets are already `chr_obj` blobs, so the port is a record table and a transfer queue;
      the beams' arms are mostly ported, and `enemy_animateIce` is still a recorder)*
  - [x] **8a: `loadGraphics`, the pickups' tile swaps and the load path** *(`69001f9`; also
        found and fixed Varia's pose, $13 where the ROM has $80)*
        - `src/gfx_info.zig`: the gfxInfo records, decoded from each caller's
          `ld hl,rec / call $2753` (the pickups, `toggleMissiles`, `varia_loadExtraGraphics`),
          mapped onto the converted sheets. The builder patches them into a `GfxInfo` table.
        - Engine: `LoadGraphics` queues a record. NMI moves one Game Boy chunk a frame, as
          `VBlank_vramDataTransfer` (00:$2BA3) does: the size mod $40, else $40. The pickup
          gets an `!ITEM_XFER` stage that draws nothing while the queue drains.
        - The pickup arms, branch for branch: the screw/space choice, spring's two, the beams
          (the spazer takes the plasma record), and Varia's tail with its missile cannon and
          `varia_loadExtraGraphics` (its fanfare wait and animation are Step 9's). The toggle
          goes through the queue.
        - `loadGame_samusItemGraphics` (00:$3BB4) on boot and load, keyed on the active
          weapon as the original is. The debug menu's close re-derives the same patches.
        - Rung `gfx`: our GB takes each pickup from `itemCollected` (the orb's lever, as
          `snes boot` phase 9). The cart gets its prerequisites from the menu. Graded: the
          object characters $8000-$87FF and the transfer's frame count. Fault: one arm's
          record swapped.
  - [x] **8b: Ice's thaw, and the beams against an ordinary enemy** *(`3db54e5`, and `d80d095` for James's playtest: OBP1 was loaded at $84, not $90, so frozen enemies and flashing items drew black; split again,
        2026-09-28: every beam's arm in `samusShoot` and the hit side of ice were ported; the
        one gap was `enemy_animateIce`. Plasma pierces *walls*, not enemies: 00:$32A4 deletes
        every beam that hits)*
        - Port `enemy_animateIce` (02:$5652), retiring `EnemyCommonAI`'s last recorder arm.
        - The `enemy AIs` rung grades slot 0's stun, ice counter and health as globals. The case
          cart gets 64 KiB of save RAM, because the hatching Alpha's 700 frames no longer fit.
        - A case can name a behaviour fault, a patch at an engine label, that must differ too.
        - Cases: `crawlerA ice` (thaw), `crawlerA ice kill` (death at the thaw), `hopper wave`
          (a Ramulken's shield), `hopper spazer` and `hopper plasma` (an Autoad, and its missile
          drop). Faults: the climb stopped (both ice cases); Wave tests the shield.
  - [x] **8c: the beams in flight.** *(the `beams` rung, 8 segments, 6/6 faults; found and fixed
        the plasma's slot order, which James's playtest showed as a volley wiping out shots still
        flying)* The loadout segment compares the projectile array frame
        for frame (a band in codes 6-18, which only the fade rung uses). The beam is set through
        the debug menu's beam row. Segments fire Wave, Spazer and Plasma into a wall, and Ice and
        Power for contrast. Faults: Wave's skip of the terrain test; Spazer's loop; Plasma's
        pass-through
        - **Plasma against enemies** (James, 2026-09-28: on the cart the shots sometimes fly
          on after a kill and sometimes stop). The ROM never pierces an enemy: each of the
          three shots, 8 px apart, is deleted on its own hit (00:$31F1 → 01:$52E3), and
          only what outlives the kill flies on. Segments: `plasma kills` (a weak enemy,
          trailing shots fly on) and `plasma soaked` (a tough one, all three spent), plus an
          alignment that puts two shots in the box on the killing frame. Fault: the carry
          ignored (code 168's cause) *(two Autoad gaps, $30 all stop and $38 one on, and a
          missile door; the rule measured at four gaps on both machines)*
        - Cross-check a plasma hit in the 100% recording (part 10 on) against the rule *(not
          done: the segments grade the cart against our Game Boy running the ROM, which is the
          authority for the rule; a recorded hit would re-confirm it, left for Step 26's C10
          pass)*
  - [x] **8d: standing on a frozen enemy.** *(`474e30e`: the `beams` rung's `ice stand`, 529
        frames through the thaw and its knockback, 3/3 faults; found and fixed the lift the ROM
        backwards and the landing snapping on an enemy (00:$1378, 00:$12E7); the reference's
        `$C424` reset after the spawn, and the GB now sampled on `CALL hurtSamus`, 00:$052C)*
        A loadout segment in a room with a live enemy: ice
        it, jump onto it, stand, and ride the thaw. Fault: the frozen case of
        `CollideSamusEnemiesDown`
  - [x] Port `loadGraphics` (00:$2753) and convert the gfxInfo records it walks into new
        blobs. Retire `!GfxWanted` and the cannon-missile recorder *(no new blobs were
        needed: the sheets were already converted)*
  - [x] Beam pickups swap the tiles the original swaps. Grade the tile VRAM after each
        pickup against the GB *(8a's `gfx` rung)*
  - [x] Ice: the freeze state `enemy_commonAI` tests, the thaw timer, and a frozen enemy is
        solid and standable. Wave passes walls; Spazer fires three; Plasma pierces. These
        arms are ported in `samusShoot`; grade them and port what the grade shows missing
        *(8b the thaw; 8c the flight; 8d the standing)*
  - [x] Cases: an `enemy AIs` case per beam against an ordinary enemy, and a loadout segment
        standing on a frozen enemy *(8b the cases; 8d the segment)*
  - [x] Faults: one per beam behaviour *(8b ice and Wave's shield; 8c the flight)*
  - [ ] (C10) The beam pickups' reference frames are the recording's: ice (part 02), wave
        (07), spazer and plasma (10), and the second spazer, wave and ice (17), `docs/phase1.md`
        *(not done: the `gfx` rung grades the pickups against our GB running the ROM; the
        recording's frames would re-confirm them, left for Step 26's C10 pass, as 8c's.
        Dropped, James 2026-10-02: `gfx` grades them against our Game Boy running the ROM)*

- [x] **Step 9: C5c — Screw Attack and Varia** *(both effects were already ported; the step
      graded them, ported Varia's waits and animation, and found three defects, one of them
      the open Senjoo entry)*
  - [x] Screw Attack: the pose/sprite and the enemy-contact kill path. An `enemy AIs` case
        has Screw Attack kill an ordinary enemy; the Alpha's screw reaction case must still
        agree *(a `beams` segment, `screw kill`, not an `enemy AIs` case: the hit lever hands
        weapon $10 across and would skip the contact branch the fault is on. The Alpha's case
        agrees 290/290)*
  - [x] Varia: `applyDamage`'s Varia branch (halving) graded by a damage scenario with and
        without the suit. The suit's graphics swap goes through Step 8's `loadGraphics`
        *(the `beams` segments `hurt` and `varia hurt`, with Samus's health graded frame for
        frame, code 254. `hurt` found the knockback's direction wrong after a walk's hit: the
        horizontal entry never set `samusSpriteCollisionProcessedFlag`. The same defect was the
        Senjoo's early contact, now closed with the segment at 703)*
  - [x] Varia's fanfare wait and tile-by-tile transformation animation. Grade the duration
        within 2% of the GB and the final frame's tiles *(`VariaStage` and `VariaAnimNmi`; the
        `gfx` rung grades the animation's frames exactly, the length within 2%, the
        characters, and the bit to the flag exactly. The last found the jingle loop's missing
        first pass. The clock's ticks over a pickup found the jingle's frames not ticking)*
  - [x] Faults: halving removed; the screw's contact branch blanked *(and the collision flag,
        Varia's animation cut, the jingle's first pass, the jingle's tick)*
  - [ ] (C10) Varia's animation duration is also measured off the recording's pickup (part 05
        frame 25 317) as a second reference *(not done: left for Step 26's C10 pass, as 8's
        and 8c's. Dropped, James 2026-10-02: `gfx` grades it against our Game Boy)*

- [x] **Step 10: C5d — refills and the ship's branch** *(`269f982`, and `42dc2f9` for James's playtest: larvae took the shown count to 93 before the stinger had added them; the orbs were already visible: 1.0
      Step 8b's OBP1 fix, `d80d095`, was the step; the METROIDS page gained the Queen's row so
      the count can reach zero, James 2026-09-28)*
  - [x] Energy and missile refill stations. Fix the invisible refill orbs: fixture first,
        reusing the open `bug_tracker.md` entry *(no engine fix needed: the refills blink into
        OBP1, which was black until `d80d095`. The fixture fails 39 on that engine; both
        entries closed with the attribution, the "until re-entry" part not reproduced)*
  - [x] The missile refill's `metroidCountReal` test (`pickup_missileRefill`, via 00:$372F) is live. With a
        non-zero count it refills. With zero it records that it would enter mode `$12`
        until Step 23 ports that mode *(Step 22's, per its own text: `!ITEM_CREDITS` holds the
        pickup, `!ItemUnhandled` records it)*
  - [x] Scenarios: both refills with the orb drawn, and the zero-count branch reached through
        the Metroids page *(`warp`'s `refills`, fault OBP1 at $84 → 39; `refill_credits` at
        `$F:$76`, since `$F:$10`'s warp spot is walled off from its refills, fault the count's
        test removed → 43)*

- [x] **Step 11: C1a — ordinary AIs, first batch** *(in bank 1 behind `AiTableFar`, bank 0
      being full; gate 14m27s, close to the budget, so Step 12 splits a slow tier out)*
  - [x] Port skreek (02:$59C7), drivel + drivelSpit ($5AE2, $5BD4), septogg ($6841), moto
        ($66F3), halzyn ($6746), gravitt ($695F), flittVanishing ($68A0) and flittMoving
        ($68FC), with their children *(and the halzyn's sine motion, 02:$677C-$682C, which
        the missile block shares)*
  - [x] One `enemy AIs` case each in a room from the census. Add a kill case where the AI has
        its own death behaviour *(nine cases, halzyn in two rooms; none of the batch has a
        death of its own, and the two spits' self-deletion is graded in the child slot. The
        drivel's `rDIV` toss is handed across, `Case.divider`. The platforms' carry of Samus is
        the `beams` rung's `septogg ride` and `flitt ride`. Found: cell $37's seam columns
        disagree between the machines, `bug_tracker.md`, for Step 18)*
  - [x] `enemy_oracle.pending` shrinks by the batch

- [x] **Step 12: C1b — ordinary AIs, second batch**
  - [x] Port glowFly ($54A1), proboscum ($65D5), skorpVert ($60AB), skorpHori ($60F8),
        autrack ($6145), autom ($6540), gunzoo ($638C), blobThrower + blobProjectile ($4EA1,
        $536F) and missileBlock ($6622)
  - [x] Cases and pending as Step 11. After this, `pending` holds only Metroids, Arachnus and
        the baby
  - [x] (C10) Settle why the 100% run never dispatches `blobThrower` though its projectiles
        run (Step 24b, `docs/phase1.md`): its case shows how it is run

- [x] **Step 13: C3 — Arachnus** *(playtested by James on hardware, 2026-09-29: perfect)*
  - [x] Port `enAI_arachnus` (02:$5109): ball and upright states, projectiles, hurt and
        death, and the item it leaves. The fireball (02:$52DF, spawned from its own long
        header) is a `roster.children` since Step 24b and is ported with it *(its state is
        global, $C390-$C394, graded as four globals; the jump tables are one physics blob, 49;
        and the two `.midMedium` side probes were new)*
  - [x] Cases: live, and a kill at fixed hit ticks. The item it drops is collected and sets
        its bit (scenario) *(`arachnus`, `arachnus roll` and `arachnus kill`, Samus frozen, with
        `Case.fire` added to hold B, which curls it up; the warp rung's `spring_ball`, from a new
        WARP entry, Arachnus's record. It found and fixed a warp defect: the sweep lost the row
        under `scrollY`'s wrap, and Arachnus with it)*
  - [x] (C10) The kill's hit ticks come from the recording (Spring Ball at part 07 frame 3 850,
        `$D:$C0`), taken with `gbtrace -- kills` around it *(`kills` now follows Arachnus:
        bombs at 3 102, 3 112, 3 120, 3 751, 3 757, 3 765; the case keeps their spacing from
        tick 300, not the +2 005 of the player's rolls before them)*

- [x] **Step 14: C2a — Gamma Metroids** *(`0c8b0fe`; gate 13m40s. James's playtest, 2026-09-29: the Gamma perfect; Metroid 01's warp drew the wrong rock, a warp-table defect fixed in `864fd0b`; its frozen kill not reproduced, open for his re-test)*
  - [x] Port `enAI_gammaMetroid` (02:$6F60) with every branch, and the molt,
        owned by whichever AI Step 1's census says owns it *(the molt is the Gamma's own;
        its bolt is the same AI in a child slot. The Alpha's angle, slope and speed moved to
        bank 1 so both share the distance and slope, as the ROM does: bank 0 +400 bytes)*
  - [x] Cases: live, beam dink, missile hurt, and a kill, grading the Metroid globals as the
        Alpha kill cases do *(`gamma`, `gamma shot`, `gamma kill` in `$E:$85`, Samus frozen:
        at the census's `$A:$36` the Gamma never moves on either machine; three behaviour
        faults; `gamma_stunCounter` a new global; `max_coins` 8 → 12)*
  - [x] (C10) Kill ticks for the cases from `gbtrace -- kills` around a Gamma kill in the
        recording's table *(kill 26, `$A:$36`, part 12: ten hurting shots and two at the
        bolt's time that do nothing; `kills` now skips the bolt's child slot)*

- [x] **Step 15: C2b — Zeta Metroids** *(`b78c719`; gate 12m17s. The first gate run failed
      warp's `spring_ball` with exit 2, which passed three runs alone and the rerun)*
  - [x] Port `enAI_zetaMetroid` (02:$7276). `.oscillateNarrow` is already borrowed by the
        Alpha *(with its husk and fireball, the same AI in other slots; `enemy_seekSamus`,
        03:$6B44, its table physics blob 52, and `metroid_keepOnscreen`, 02:$7DC6, as their
        own routines for Steps 16-17)*
  - [x] Cases: live, hurt, kill *(`zeta`, `zeta shot`, `zeta kill` in `$A:$F8`, Samus frozen,
        three behaviour faults; the coin handover watches three stun counters)*
  - [x] (C10) Kill ticks as Step 14, from a Zeta kill in the recording *(kill 30, part 13:
        twenty hurting missiles and two from below that dink; one idle gap 500 shorter, as
        the case cart's save RAM runs out at full length)*

- [x] **Step 16: C2c — Omega Metroids** *(gate 13m27s; the first run failed warp's
      `refill_credits` with exit 2, which passed three runs alone and the rerun)*
  - [x] Port `enAI_omegaMetroid` (02:$7631) *(with its fireball, the same AI in another
        slot, and `enCollision_up.nearSmall` (02:$4BC2), bank 0 +48 bytes; the chase pick's
        `POP AF` is a jump out; `.unusedProc` is reached by nothing and not ported)*
  - [x] Cases: live, hurt, kill *(`omega`, `omega shot`, `omega kill` in `$B:$76`, Samus
        frozen, three behaviour faults; the Omega's stun, wait counter and chase index are
        globals)*
  - [x] (C10) Kill ticks as Step 14, from an Omega kill in the recording *(kill 38, part 20:
        eighteen hurting missiles, front and back as the recording's by a direction chosen
        per hit, so the health steps are the recording's; three gaps shorter for the case
        cart's save RAM)*

- [x] **Step 17: C2d — larval Metroids and `metroidStinger`** *(`393e640`; gate 12m45s)*
  - [x] Port `enAI_normalMetroid` (02:$7A4F): latching onto Samus, freeze-and-missile kills.
        Also `enAI_metroidStinger` (02:$6B83) *(with `metroid_correctPosition`, 02:$7CDD; the
        latch bytes are global and a room's entry clears them, 02:$4013. Bank 0 +6, bank 1
        +797)*
  - [x] Cases: live, latch, kill. `enemy_oracle.pending` now holds only the baby *(`stinger`,
        `larva`, `larva bomb`, `larva kill`, four behaviour faults. The rung gained Samus's
        health as a global and `Hit.late`, a hit written after her contact test, without
        which a bomb never lands on a larva on her. Two measured limits: the drains land a
        frame apart, so larva cases end on a multiple of eight ticks; and the rung cannot
        grade a death, so every case ends before hers)*
  - [x] (C10) Kill ticks as Step 14, from a larval kill in the recording (part 21's run of
        eight) *(kill 40, `$E:$32`: eight ice shots and five missiles; the bomb case's second
        bomb takes part 21's re-latch-to-bomb spacing, +62)*

- [x] **Step 18: C2 + C6 — the whole world** *(split as it goes, 2026-09-30: in play the
      cart's tileset is already loaded state, as the Game Boy's, because it runs the door
      scripts. `screens.assign`'s inference draws only the oracle's boots and seeds the crawl)*
  - [x] **18a: every door on both machines.** A `doors` rung: every decodable script as a
        warp entry, with a walked door's chain the room it leaves' loader then the door, and
        an unwalked one's the door alone at its `WARP` cell. The entries go in shards of case
        carts whose WARP list holds only those entries. Graded as the `warp` rung is, plus the
        **tilemap**: the cart's `!TilemapBuf` over the camera's view, against our Game Boy's
        `$9800` with each cell the view touches drawn under the same loaded state. The `warp`
        rung gains the tilemap grade too. A unit test: every opcode of all 497 is one
        `RunDoorScript` handles (`EXIT_QUEEN`/`ESCAPE_QUEEN` named as Steps 20-21's)
  - [x] **18b: the new game as a load** *(opened by 18a's rule: a mechanism change)*. 18a found
        the cart's new game holding door `$D6`'s solidity, `$69`, where the ROM's `initial_save`
        and our Game Boy hold `$64` (`bug_tracker.md`). The Game Boy's new game is a load of
        that record (`createNewSave`, then `gameMode_LoadA`); the cart's replays the boot
        record's door script. The builder carries the record's loaded-state block, and the new
        game takes the load path's tables, solidity and graphics from it, the boot record's
        door script kept for the graded boots that are not a new game. Fixture: the five `doors`
        runs that fail 21 on the unfixed engine
  - [x] **18c: the Game Boy's tileset replaces the inference.** *(`13a4736`; gate 13m09s)* Host-side, every cell of
        every room a walked door enters, drawn on our GB under the loaded state and held against
        the converted cell. `screens.assign` takes the crawl's arrivals where it has them; B12's
        nine cells, the bank $9/$A veto and cell $37's seam are settled against it. The
        recording's visited cells join `worlds`
    - [x] `warp.assignWalked`: the crawl's arrivals over the static reading (484 cells walked);
          `bootFor` and `oracle -- worlds` take it; `assign` stays static (it seeds the crawl)
    - [x] `warp_grade.cellsDrawn`: 484 cells drawn on our GB agree; the static reading fails 159
    - [x] B12's nine settled: `oracle -- worlds` 34/34 (24 static); the veto kept in $9 (151 vs
          136 of 151), dropped in $A (5 vs 14 of 58); cell $37's seam is `room.spawn`'s whole-cell
          draw, the cart is right
    - [x] The recording through Mesen (`gbtrace -- <set> set worlds`): 599 of 953 cell-visits
          (502 static); every walked miss is the lava's count (18d)
    - [x] Gate green, commit. Three enemy cases (rockIcicle, missileBlock, drivel) had passed
          in the wrong rock and were re-stood in their true rooms
  - [x] **18c2: the crawl past the first lava** *(opened by 18c's rule: a mechanism change)* *(`6b9bc32`; gate test 3m53s, verify-full 20m16s)*. The
        crawl walks at $47, where the lava stands, so the rooms beyond it are reached only from
        seeds, and the recording shows the reading wrong on about 300 of 437 visits there. Crawl
        at each count a threshold opens, so those rooms are walked from truth; grade on the
        recording's `set worlds` *(James, 2026-09-30: the seeding fixture's rule and its drift
        guard folded in here, first, so the crawl change is the first thing it guards)*
    - [x] The seeding fixture passes on at least one catch, and pins which stretches catch
          and the frames the seeded stretches play: a lost catch or frame fails and names the
          stretch; a gain prints "raise the pin"; an accepted drop lowers the pin in a commit
          with a turn-log row (`porting_loop.md`)
    - [x] `zig build verify-full`: the slow tier, the seeding fixture its first rung, run at
          the close of any step that touches the world, boots or seeding
    - [x] Pins taken at `13a4736` (anchors 10327, 10390, 10832, 11567; 168 frames), shown
          failing on a named fault: a false pin at 10791 fails naming it, and the unit test
          fails a lost catch, a lost frame and no catch
    - [ ] The crawl at each count a threshold opens; rooms walked from truth past the lava
          *(tried and reverted, James 2026-09-30, option 1: the recording's worlds fell from
          599 to 482 (lowest-count rule 493; a table per band, the ceiling, 557). Per band the
          crawl reaches a room first down a path no player takes, e.g. $B room 32 through
          doors $0D and $153 with table 4, where the recording shows 9. The reading stays
          18c's; the count work moves to 18d, graded on the recording in seconds. Patch kept
          as `18c2-crawl-per-band.patch` beside this plan)*
    - [x] The recording's `set worlds` fast enough to run: Mesen's answers per segment cached
          in `build-out/` (keyed on the recording, the ROM and the Lua), segments run in
          parallel under their own file names; a re-grade in seconds, a cold run in minutes;
          its explained-visit count pinned as a `verify-full` rung *(James, 2026-09-30: "a
          45 minute run is too long")*
    - [x] The recording's `set worlds` re-graded; `verify` and `verify-full` green
  - [x] **18d: the thresholds and the lava.** Below *(`dd385ad`; gate 11m19s, verify-full 10m43s. `$00` moved to Step 20)*
  - [x] **18e: a save round trip per bank.** Below *(`614f8ee`; gate 10m27s, verify-full green)*
  - [x] **18f: every warp can be walked out of.** Below, then the skreek playtest *(James,
        2026-10-01: a spot in a morph tunnel behind destructible blocks is fine; a spot no
        player can reach is the defect. Measured: Metroid 11's sealed tunnel is a wrong
        tileset, caveFirst where the recording shows lavaCavesEmpty at $24; 24 of the 153
        warp cells the recording visits disagree with it; 10 of 162 spots out of reach)*
    - [x] The recording's tables held by the warp table: a committed file of the
          recording's visits (bank, cell, count, table) from `set worlds`, with a
          `verify-full` check that the recording still says the same. An entry whose cell
          the recording visits takes a chain that leaves the recording's table at the
          recording's count (its highest there: the first time a player stands in it), and
          carries that count when the table depends on it *(superseded the same day, James:
          no count to set for a warp. Every chain runs at the live count, and a lava room
          keeps its lava: lavaCavesMid at $47 for Metroid 11, through the area's door `$04A`.
          `6c94836`)* Unit test: every visited warp cell agrees, all 24
          that disagreed among them *(28 entries moved; the drift check fails naming the
          line)*
    - [x] Reach: a ball with every item, destructible blocks cleared, flooded from the
          room's doors (`warp.reach`). Standing spots are chosen inside it; a destination
          with none is a finding, not a guess *(flooded from where each door's trigger
          fires, not the cell edge; graded against the recording's positions in warp rooms,
          36 143 of 36 182, the 39 edge-crossing frames pinned. One spot moved, `$B:$B4`)*
    - [x] Guard: every entry's spot is in reach; `$B:$45`'s old spot and table fail it
          *(fails with the hold off at `$B:$E3`, with the reach off at `$B:$B4`)*
    - [x] The three ruins item rooms read as closed boxes (`$D:$4D`, `$D:$C7`, `$D:$D7`):
          diagnose (a wall the reading does not model, or a true defect) and settle *(the
          reading: tiles $00-$03 are respawning blocks whatever the collision table says;
          the Game Boy's tilemap had them cleared. Also the baby's tile $64 at count zero)*
    - [x] `warp` and `doors` rungs, `verify` and `verify-full` green; commit *(`b0dc085`;
          gate 11m25s, verify-full 11m44s. The `warp` rung now runs each entry at its count,
          METROIDS rows switched both ways. `refill_credits` hit the 90 s wall limit once under
          load and passed on the rerun)*
    - [x] Playtests: Metroid 11 walked out of; the skreeks and drivels (below) *(Metroid 11:
          James, 2026-10-01, "works perfectly"; skreeks and drivels: passes, James found the
          way by walking around. The skreek route down `$B:$44`'s floor was the
          reach's error, no door there; fixed and guarded, `a3996a9`)*
  - [x] Tileset grading for every door target. For each of the 512 scripts, our GB harness
        runs it (door index set, as in Step 5) and reads the running tilemap; the cart runs the
        same script. Every cell a door enters is graded, beyond what the published runs
        visit. B12's nine cells are included. Fix what disagrees **if the fix is local**. If
        it needs a mechanism change (how loaded state is carried, not one table), stop,
        write the finding into `docs/phase1.md`, and open **Step 18b** for it, so this step
        does not swell *(done by 18a: the `doors` rung, every decodable script, 424 run
        on the cart, graded on the tilemap; B12's nine by 18c)*
  - [x] Every door script executes on the cart with no unhandled opcode (unit test over all
        512, plus a scenario sample). `EXIT_QUEEN` and `ESCAPE_QUEEN` may stay
        recorded until Steps 20–21, and are named as such *(done by 18a's unit test, all
        497 decodable scripts' opcodes)*
  - [x] A table per count band for the rooms the lava redraws (53 of the recording's 354
        pinned misses), from a crawl that walks only what a player can reach at that count;
        18c2's per-band crawl is the starting point and its failure the thing to beat
        (`18c2-crawl-per-band.patch`). Graded by `verify-full`'s worlds pin: each miss
        fixed is a line removed from `src/worlds_misses.txt` *(James, 2026-09-30: not a
        crawl. `warp.LavaReplay` replays 18c's walked paths as scripts at the visit's count,
        over the arrivals that walked in with lava. 599 → 641 explained, 53 → 11 lava misses,
        42 lines off the pin, none lost; with the replay off the pin fails 42)*
  - [x] All 13 `IF_MET_LESS` thresholds: a scenario per threshold sets the count through the
        Metroids page and crosses a door that tests it *(18d: twelve; `$00` moved to Step 20 by
        James, 2026-09-30, in the `counts` rung —
        270 door entries at the counts their chains test, both sides of each threshold, the
        count reached by killing METROIDS' rows; `$01`'s taken side is her room through `$13B`.
        `$00` is door `$19E`'s alone, and both its sides run `EXIT_QUEEN`/`ESCAPE_QUEEN`)*
  - [x] Every `lavaCaves` level transition draws the ROM's table *(18d: the `counts` rung,
        every lava door at each level it draws, its table pointer and the map over the view)*
  - [x] Save and load round-trip at a station in every bank that has one, with killed-Metroid
        and collected-item flags surviving. Grade as B7's `load` and `round trip` *(18e: the
        `saves` rung, all seven stations in five banks, the reset button and the title's load;
        the loaded state against our Game Boy. Found and fixed two warp defects: `$A:$99` drew
        no pad, now held to the recording's save there; `$E:$54` stood her beside it. Not
        graded: the save's own merge of live flags, which only `$E:$55`'s buried tank needs,
        left to James's playtest)*
  - [x] Fault: one threshold's branch inverted; the loaded-state inheritance removed *(18d:
        the first half, `IF_MET_LESS`'s `bcs` made `bcc`, fails the `counts` rung on the map
        (26); 18e the second, the load's metatile table not the record's, fails `saves` on the
        view (57) at every station)*
  - [x] (C10) The recording's visited cells join the `worlds` grading *(18c: `gbtrace -- <set>
        set worlds`)*
  - [x] Every warp destination leaves Samus somewhere she can walk out of, with the items
        the warp gives. First, Metroid 11 (`$B:$45`): James found it a sealed morph-ball
        tunnel (`bug_tracker.md`) *(18f: built and gated; James's playtest open)*
  - [x] (from Step 11, deferred by James 2026-09-29) Playtest the skreeks and drivels
        (`$B:$51`-`$54`) by a route walked on the running world, not read off the door graph
        *(passes, James 2026-10-01, by a route he found walking; `$B:$44`'s floor has no door,
        and no warp lies on the recording's walk there)*

- [x] **Step 19: C4a — the Queen: the fight** *(split as it goes, 2026-10-01: her code is
      bank 3's $6C8E-$7DAC, about 3 300 lines of M2RoS, so the oracle comes first and the
      port is graded against it as it lands)*
  - [x] **19a: the Queen oracle, and the bands out of NMI.** *(gate 11m39s. NMI in her room
        ends on line 237, not 257; the oracle fails 159 of 378 on the engine as it stands, first
        `queen_state` at frame 140; it found and fixed `queen_headDest`)* Our GB entered by `queen.enter`,
        the cart by the debug warp's QUEEN row, Samus standing where she lands on both. Each
        frame records her whole `$C300` page, which the cart now keeps as one page at a fixed
        base so the map is an offset (`queen_initialize` clears all of it), and her thirteen
        slots (actors, neck and projectiles); Samus's position, pose and health beside them,
        the loadout the same on both. The histories are collapsed per variable and compared as the enemy oracle's.
        `rDIV` (`queenStateFunc_prepExtendingNeck`'s mouth toss) is handed across, as
        `Case.dividers`; `frameCounter`'s phase (the retract's parity, the neck's hurt flash)
        is aligned at entry or shown not to matter to collapsed histories. Shown agreeing
        through states `$17`/`$18` and failing at the first state the cart lacks, naming it: the fixture the port must turn green. Kept out of the gate
        until 19b. And `QueenBands` out of NMI, double-buffered (below); the `queen` scenario
        stays green and the NMI's end line in her room is measured again
  - [x] **19b: the fight she runs on her own.** *(`480a40c`; gate 11m35s, the `queen` rung
        new: all 604 frames, 378 histories, 4/4 of her routines taken out part. Bank 1 +2 592
        bytes. The oracle needed two alignments, not port fixes: each cart frame read where
        the main loop wakes from NMI, and `frameCounter`'s phase handed across at her entry,
        as the `rDIV` toss is; left alone, the cart retracted her neck on the other parity
        and parted at frame 265. Her eating, stomach and death states record into
        `!EnUnhandledState` until Step 20)* The rest of `queen_initialize`,
        `queenHandler`'s body, the state list and states `$00`-`$07`, `$0C`, `$14`, `$15`,
        `$17`, `$18`; `queen_walk`, `queen_moveNeck`, `queen_drawNeck`, `queen_drawFeet`,
        `queen_writeOam`, `queen_adjustSpritesForCamera`, `queen_setActorPositions`' neck
        arms, and the projectiles. Measured on our GB (`zig build queen -- 2400 100`): with
        no input she runs the whole list (walk, two lunges, walk back, spit) and her
        projectiles and lunges kill Samus near frame 760. The oracle passes that fight up
        to Samus's death; it joins the gate
  - [x] **19c: the hurt and the flash.** *(`8331493`; gate 12m17s; James's playtest closed 2026-10-01 with Step 20's ("the fight itself seems perfect"). The oracle's `volley`
        case: 658 frames, 380 histories, the play window on 7 frames and the BGP bands line
        by line on 4, with `QueenHeadCollision` (48) and the flash's arm (49) taken out. The
        pad is keyed to vblanks on both machines, and so the volley found her room overrunning
        a frame mid-lunge with a missile out, which is fixed in `PutObject` and `LoadEnemyBox`
        with 16 lines of margin. The cart is SlowROM; FastROM is for James to decide. The gate
        also found the warp grade reading the map before the stream's turn, now read four
        frames on)*
        `queen_headCollision`, `queen_missileHurt`, the
        stun, the health flags, the neck's hurt palette, and BGP mid-frame. Oracle cases
        with missiles at fixed ticks into the open mouth and the head, the play window at
        sampled frames, and the fault. Playtest ask: warp to her with full loadout; she
        walks, lunges and spits, and flashes and cries when a missile lands in her open
        mouth
  - [x] Finish `queen_initialize` (03:$6D4A: the neck's sums, the wall sprites, the state
        list's pointer) *(19b)*. `ENTER_QUEEN`, `queen_renderRoom`, the rest of `queen_initialize`,
        `handleEnemiesOrQueen`'s Queen arm, the camera pair and `queen_setActorPositions` (but
        its neck arms) landed in Step 6
  - [x] Move `QueenBands` out of NMI into the end of the main loop's pass, double-buffered,
        NMI only pointing the channels: her room leaves 5 lines of vblank as Step 6 left it
  - [x] BGP mid-frame: commands 1 (`queen_bodyPalette`, the hurt flash) and 2 ($93) as an
        INIDISP band on a fourth HDMA channel, and how a flash palette that is not a brightness
        is shown *(19c: INIDISP on channel 4, and the flash's $03 as COLDATA white added to BG2
        and BG3 on channel 3, exact for the greys; `GameOverScreen` turns her channels off
        before its forced blank)*
  - [x] Port `queenHandler` (03:$6E36) and its state list (03:$7484): neck and head
        (`queen_moveNeck`, `queen_drawNeck`), projectiles, missile hurt, and head collision
        with Samus and with shots. Also the Queen's OAM writer, and `VBlank_drawQueen` over
        Step 6's technique *(19b and 19c)*
  - [x] A **Queen oracle** case: our GB harness and the cart in the fight from entry, with
        fixed hit ticks. Compare the Queen's state, health, head/neck positions and projectile
        slots pass for pass; compare the play window at sampled frames *(19c: `volley`)*
  - [x] Fault: one state function blanked *(19b: `QueenPrepExtend`, with the spit's chase, the
        neck's drawing and the feet, in the `queen` rung)*

- [x] **Step 20: C4b — being eaten, the stomach, and her death** *(split as it goes,
      2026-10-01: three of bank 3's state functions are ported of twelve, and the Samus side
      is six poses, `gameMode_Main`'s `.queenBranch` (00:$0578), three collision arms and a
      shooting gate. Both oracle cases need the menu's LOADOUT on the cart and the same items
      written into our GB, the reference)*
  - [x] **20a: being eaten, and bombed out of her mouth.** *(`98e5230`; gate 11m45s; the
        `mouth` case 700 frames, 380 histories, 3/3 faults. On our GB's lag frames the ten bytes
        `VBlank_drawQueen` builds may hold a value it never built, pinned per case: 0, 0, 3)*
        The eating capture's
        `queen_eatingState` $01 (00:$343C, $3644); all six Queen poses ($18-$1C, and $1D as
        `poseFunc_morphBombed`) in `HandlePose` and `SamusSpriteId`; `.queenBranch`
        (00:$0578); `.queenStomach`; states $0D-$10; both bomb arms (00:$3187-$31AF);
        `samus_tryShooting`'s $22 gate. Oracle case `mouth`: LOADOUT, missile her mouth to the
        stun, roll in, bomb her head, out. Faults: the bomb arms, state $0F, the acid
  - [x] **20b: the stomach.** *(`525520b`; gate 13m39s; the `stomach` case 900 frames, 380
        histories, 1/1 fault; 24 unbuilt values pinned on our GB's 162 lag frames.
        `queen_killFromStomach` pulled in from 20c, as state $0A branches to it; the mouth's
        kill also runs through state $08)* States $08-$0B, the bent neck, `queen_setDefaultNeckAttributes`
        from state $10's path. Oracle case `stomach`: swallowed (left in her mouth), bomb the
        body, spat out. Fault: state $08
  - [x] **20c: her death.** *(`4f5ee74`; gate 12m49s. `kill` 3 250 frames and `mouth_kill`
        3 320, her death 596 and 629 frames on both machines, 100.00%; faults 5/5 and 2/2. The
        AND runs on WRAM shadows and NMI copies the spans out: in NMI it overran vblank by
        three lines. Presses kept off the frame after our GB lags, where it reads the pad a
        frame early)* ~~`queen_killFromStomach`~~ (20b's), the mouth's kill ($20), states
        $11-$13 and $16, `queen_disintegrate` in NMI (her CHR, a bitmask a row), the body's
        delete, the counts zeroed and the shuffle. Oracle case
        `kill`, through state $16; the death sequence's duration within 2%
  - [x] **20d: out of her room.** *(`5d25991`; gate 13m22s, 46 rungs; the `queen` rung's fault
        sweep 20/20; James's playtest closed 2026-10-01)* `EXIT_QUEEN`, `ESCAPE_QUEEN`, the post-Queen music and the
        baby's egg; the `$00` threshold; the playtest; the recording's measurement. Found on
        resuming (2026-10-01): door `$19E` is cell `$F:$FE`'s, crossed leaving her room to the
        left. At count `$00` it branches to `$19F` (`EXIT_QUEEN`, `WARP $F,$A9`), otherwise it
        runs `ESCAPE_QUEEN`, `WARP $E,$C1`. Escaping alive is reachable: the bottom exit
        (column 7's shaft, then row 14 rolled left) is open until `queen_closeFloor` seals it
        at her death. Both opcodes `res 1` rIE, which is the STAT (LYC) interrupt, not VBlank
        as M2RoS's comment says. The egg is the baby's spawn record at `$F:$A7`; its AI is
        Step 21's
    - [x] Engine: `DoorEscapeQueen` (00:$2476) and `DoorExitQueen` (00:$24CE), dispatched
          from `StepDoorScript`. A `!QueenStat` byte stands for rIE bit 1: `ENTER_QUEEN` sets it
          and both clear it, and `QueenNmi` turns her channels off while it is clear. Also the
          HUD's base strip queued to BG2 for NMI, `ESCAPE_QUEEN`'s four position bytes, and
          `EXIT_QUEEN`'s room flag and window
    - [x] Engine: `earthquake_adjustScroll`'s Queen branch (01:$7A13): song 1 when the quake
          ends with `queen_roomFlag` at or above $10
    - [x] Recording (C10): `gbtrace -- kills` watches `queen_state` and `queen_roomFlag`. Part
          23 times her death, state $11 to $16, and the exit; part 24 the arrival *(596 frames,
          4 881 to 5 477, 100.00%; room flag $00 on 5 716; Samus in $F:$A9 by 5 800)*
    - [x] Queen oracle cases: `exit` (the kill, then left out of her room through `$19F` into
          `$F:$A9`) and `escape` (alive, down the shaft and rolled out through `ESCAPE_QUEEN`
          into `$E:$C1`). Graded: her room flag, the camera, the map bank and `songPlaying`.
          Faults: each opcode's arm, and the quake's branch *(each graded to its arrival: our Game
          Boy lags every fourth frame in the new room)*
    - [x] The `$00` threshold: door `$19E` joins `doors`/`counts` (only `ENTER_QUEEN` stays
          out); `counts` holds both sides; the opcode test's deferred list is empty *(doors 426,
          counts 272)*
    - [x] Gate green, docs, commit
    - [x] The playtest ask (below). *(Closed 2026-10-01, James: the fight is right, and the escape works on both routes. Three findings on
          the escape. (1) The door's screen showed the tileset swap. Fixed: her bands stay off for
          a door's frames, as the GB's vblank skips `VBlank_drawQueen` while `doorIndexLow` is
          set. Guarded by the `escape` and `exit` cases' screens and the `QueenDoorFrame` fault;
          see `bug_tracker.md`. (2) After QUEEN NEXT, her room had no Queen and blocks where she
          was. That is the ROM: $13B at $E:$13 branches to $19D's `ENTER_QUEEN` only at count
          $01 or less, and the debug cart's live count is 47, so it warps into $F:$EF as an
          ordinary room. The QUEEN row re-enters her fight after an escape; checked on the cart. James kept
          both rows as they are; `docs/setup.md` documents the difference, `5dc940e`. (3) James,
          after: the escape looks right with her spawned, but QUEEN NEXT, into her area and out
          by the ball's escape froze on `Fatal`. That exit is $F:$FF's door $180, where
          `COPY_DATA`'s twin and `ITEM`'s six shared one frame of a six-entry queue. Fixed: the
          queue holds seven; guarded by `transition.zig`'s peak over every script; see
          `bug_tracker.md`)*
  - [x] Samus's Queen poses (the six `samus_drawJumpTable` sends to `drawSamus_morph`),
        `queen_eatingState`, and `applyDamage.queenStomach`. Also bombing out of the stomach
  - [x] The Queen's death, `EXIT_QUEEN`, `ESCAPE_QUEEN`, and the post-Queen state: count,
        music, the baby's egg *(its spawn record; its AI is Step 21's)*
  - [x] The `$00` threshold (moved from Step 18d, James 2026-09-30): door `$19E` in the
        `counts` rung on both sides, `ESCAPE_QUEEN` at `$01` and `$19F`'s `EXIT_QUEEN` at `$00`,
        reached by killing every METROIDS row, the Queen's last
  - [x] Queen oracle cases: swallowed and bombed out; the kill. Durations within 2% for her
        death sequence
  - [x] Playtest ask: debug warp to the Queen with full loadout, then be eaten, bomb out, and
        kill her *(closed 2026-10-01: the fight perfect; the escape on both routes after two fixes)*
  - [x] (C10) The death sequence's duration is also measured off the recording (the Queen at
        part 23 frame 5 481)

- [x] **Step 21: C4c — the baby Metroid** *(`9cd903e`; gate 12m46s. Found: the enemy
      oracle's counter seed was a frame out of parity for a walking Samus, now lead 1, measured
      by `baby block`; every older case agrees either way. Playtest open)*
  - [x] Port `enAI_babyMetroid` (02:$7BE5): hatching, following Samus, and eating its blocks
        *(and `enCollision_up.midMedium`; the four mid probes now keep
        `metroid_babyTouchingTile`, graded as a global in every case)*
  - [x] Cases: follow, and a block-eating stretch. `enemy_oracle.pending` is empty *(`baby`:
        hatched and followed, 400 frames; `baby block`: Samus walks left, the block eaten at
        tick 194, graded on the map after the last tick (`tiles_end`); each with a behaviour
        fault)*
  - [x] No new warp entries (James, 2026-10-02). The cart reaches the egg from `47 QUEEN`:
        kill her and leave left through `$19F`, as the `exit` case already does. The METROIDS
        page's DEAD on her row moves only the counts and leaves her in her room, so it is not
        a route past her

- [x] **Step 22: C7 — the ending and the credits** *(`e802006`; gate green, 46 rungs, the
      `credits` rung in verify-full. James's playtest, 2026-10-02: good) (Steps 22 and 23 merged, James
      2026-10-02: the ending is not a sequence of its own. Mode `$12` is a fade and a setup;
      mode `$13` rolls the credits and draws Samus's ending beside them, and three of the four
      variants only move once the scroll is done (`credits_scrollingDone`). The credits never
      leave: `credits_rebootGame` (05:$5985) is reached by nothing, and the original's way out
      is its soft reset, ported here)*
  - [x] **22a: mode `$12`, the fade and the setup** (`prepareCredits`, 05:$587F)
    - [x] Builder: `offsets.zig` entries derived from the code that reads them:
          `credits_paletteFade` (05:$5877, 8), `credits_starPositions` (05:$5B14, the 16
          bytes the loop copies of its $20), `creditsText` (06:$7920, to and with its `$F0`,
          1 251 bytes), `gfx_creditsSprTiles` and `gfx_theEnd` as sheets. Converted blobs
          for each; region fill re-read, resized past 95% *(physics blobs 58-60; the two
          object sheets classified by `prepareCredits`' own copies (`markCreditsObjects`);
          `chr_obj` 64 → 72 KiB at 68 256, `physics` 4 → 8 KiB, which was at 4 056 of 4 096)*
    - [x] Engine: a credits mode flag in `MainLoop`, beside `!DeathMode`, owning the whole
          frame. The missile refill's zero-count branch enters it with the countdown at
          `$FF` and song interruption `$08`, as 00:$399C does; `!ITEM_CREDITS` and its `!ItemUnhandled` record retire
          *(`!DeathMode` itself takes $12 and $13, the GB's `gameMode`, so bank 0 pays only a
          dispatch; `GameOverScreen` moved to bank 1 for the room. `!ITEM_CREDITS` stays as the
          frame the arm returns into, the play handler's rest running, as the GB's does; Start
          on that frame pauses and loses the credits, as on the GB)*
    - [x] The fade branch for branch: the palette from `credits_paletteFade` by the
          countdown's top three bits into `bg_palette` and both object palettes, until the
          countdown is under `$0E`; then the low-health beep cleared *(three more palettes,
          $A3, $A7, $EB, mapped to brightness 13, 12, 8 between the four's)*
    - [x] The setup: forced blank; tilemaps and OAM cleared; the font, sprite sheet, THE END
          and numbers to the VRAM the original's `vramDest_*` map to; the text copied as
          `loadCreditsText` (00:$3C6A) does, into cart RAM at what `creditsTextBuffer`
          ($A800) maps to, or a WRAM buffer if the port's SRAM has no room (chosen and
          written down); the stars; the scroll zeroed; Samus at ($60, $88); song `$13`;
          state 0; then the mode advances *(cart RAM at $700800, the GB's $A800: the 8 KiB
          SRAM has it free. The GB's setup pass is 487 080 cycles, 6.94 frames, LCD off; the
          cart takes 7 with NMI off, so the frame counter and countdown stand still as the
          GB's do)*
    - [x] Fault: the fade's index taken from the low bits *(the `credits` rung, exit 51)*
  - [x] **22b: mode `$13`, the credits and the ending** (`creditsRoutine`, 05:$55A3)
    - [x] `credits_scrollHandler` (05:$593E): a pixel every fourth frame, a line queued on
          each 8-pixel boundary, `credits_scrollingDone` at the `$F0`
    - [x] `VBlank_drawCreditsLine` (05:$403D) in NMI: twenty characters less `$21`, or a
          blank row for `$F1`, into the row `getTilemapAddress` names; the flag cleared.
          NMI's line cost measured in a credits frame *(NMI ends by line 236 on a row's frame,
          233 otherwise; 224 rows)*
    - [x] `credits_moveStars`, `credits_drawStars` (sprites `$1B`/`$1C` through
          `DrawNonGameSprite`), `credits_drawTimer` and its digits (05:$4000, $4015),
          `title_clearUnusedOamSlots`
    - [x] `credits_animateSamus` (05:$5620): all 22 states, including the
          `countdownTimerHigh` stores the original makes where it means Low (kept, and
          commented), and `credits_drawSamus`'s table (05:$598D) over the credits set
    - [x] The soft reset (00:$02E1): A+B+Start+Select held in `mainGameLoop` reboots, in
          every mode `mainGameLoop` runs. B7 left it out; the retail runs never press it
  - [x] **22c: the grading** *(built and green; James's playtest closed it. The rung is
        `verify-full`'s: with it the gate took 16m20s)*
    - [x] GB reference: our GB harness in the post-Queen state at the ship's refill
          (`metroidCountReal` 0, the clock set; the reference may be set up). The cart:
          LOADOUT, every METROIDS row killed and the clock set from the menu, the ship warp,
          the refill touched. A `credits` rung, one Mesen run per variant, in parallel
          *(`$F:$76`'s refill, `refill_credits`' own, for the 2:59 clock, ten missiles short;
          the others by ENDING. Both machines read at the top of every pass, the cart's frame
          counter pinned per clock and our GB's set to it. `zig build credits` runs it alone)*
    - [x] Graded per variant, each percentage recorded in `docs/phase1.md`: the fade's
          length; the scroll's length to `credits_scrollingDone`; the frame each animation
          state is entered. Tiles at sampled frames: the text rows, Samus's sprite, the stars
          and the timer, against our GB's rendered frame *(pass for pass, so every duration is
          100.00%; the tilemap and objects in full on five passes, a hash of the objects on
          every one; the GB's 40-object buffer found and kept)*
    - [x] Variants at each clock boundary, both sides: 2:59/3:00, 4:59/5:00, 6:59/7:00 (the
          ROM's `cp $03`, `$05`, `$07` on `gameTimeHours`)
    - [x] The end holds: past the last state the screen is unchanged for 600 frames on both
          machines. Then A+B+Start+Select reaches the title on both
    - [x] Faults: the scroll's rate; one threshold's compare; the soft reset's mask
    - [x] The warp page gains **ENDING**: the refill's zero-count path entered directly (the
          countdown at `$FF`, the clock as the menu left it). Graded by the `credits` rung
          from that entry too *(the QUEEN list's last row, a zero chain into the `!ITEM_CREDITS`
          frame)*
    - [x] (C10) The best ending's fade, scroll and states measured off the recording (parts
          24-25, clock 2:06) as a second reference; the other three stay on the set-up GB
          *(part 25: scroll and last state 99.97%, the fade 99.6%)*
    - [x] Playtest ask: "from ENDING with the clock at 2:00, 4:00, 6:00 and 8:00, the
          screen fades, the credits roll with stars, and once they stop Samus lets her hair
          down / kneels in the suit / runs on / stands; A+B+Start+Select returns to the title"

- [x] **Step 23: merged into Step 22** *(James, 2026-10-02)*

- [x] **Step 24: C10 — wiring the recordings** *(arrived 2026-09-28 as
      `reference/metroid2-100p-recording/`, 25 ordered `.mmo` segments, a 100% run; taken
      before 8b. **Re-scoped with James, 2026-09-28**: this step joins the run and censuses
      its AIs; every other use of it moves to the step that consumes it, marked "(C10)" there,
      and the gate window to Step 26)*
  - [x] **24a: the segment set.** *(`ddd66b3`)* `gbtrace` takes the directory as one ordered
        recording: every segment's SHA-1, frames and faithfulness, and each seam checked by
        comparing segment *k*'s end against *k+1*'s embedded seed. A beam log joins the census
        (not a column: the record is the one graded stretches read). The run's event table goes
        in `docs/phase1.md` *(485 325 frames, all 24 seams exact, 48 decrements for 47
        Metroids, clock 2:06: the best ending)*
  - [x] **24b: the AI census.** *(`ec5024a`: 41 of 42; found the census's miss, Arachnus's
        fireball, now a child; `blobThrower` never dispatched, open for Step 12)* `gbtrace -- ais` over all 25 segments, unioned. Any AI it
        dispatches that Step 1's census missed is a defect; any census AI it never dispatches
        is recorded with the reason (a 100% run need not enter every room)

- [x] **Step 25: C9 — the player-visible defects** *(`48b4544`, closed `fed4911`; gate green, 46 rungs. Four
      fixed, each with a fixture that fails without it. Found on the way: a `+` label of
      mine retargeted `DrawSamus`'s `!SprSkip` branch, so declined frames drew her
      (`cold boot` 157, `pause` 118); caught by the gate and fixed before the commit)*
  - [x] Fix every entry Step 1 triaged as *fix*, each fixture first. Known: Samus's
        damage/acid flash palette, `drawSamus_common`'s sprite attribute (the Senjoo's
        early contact was fixed in Step 9; refill orbs were Step 10; B1's fade-transition and animation-hold items
        were already fixed in 0b Steps 20 and 24c, found by Step 1's triage)
        *(the palette arm: `beams`' `hurt` grades the objects on OBP1 against our Game Boy,
        code 253, and `snes boot` 149 grades acid. Also the later entries: spikes, never
        ported (00:$2021; `beams`' `spike` segment in `$D:$05`); dying in her room
        (00:$36BB; `queen`'s `still` run on to GAME OVER on 900, 49); and James's pause
        flash (2026-10-02): the byte flashed and the screen did not, which 114 could not
        see; `pause` code 125 grades INIDISP)*
  - [x] Triage the open entries Step 1 did not reach *(Metroid 01's freeze: Step 27's
        re-test; the crawl's `through` and the warp rung's exit 2: diagnostic)*
  - [x] James accepts or rejects each *accepted compromise* in writing in `bug_tracker.md`
        *(the `rLY` budget, 2026-09-13 entry: accepted, 2026-10-02)*
  - [x] James decides the proboscum camera dip (`$9:$7D`, three pixels every 52 frames on
        the Game Boy): diagnose now or accept *(accepted, 2026-10-02)*
  - [x] James confirms on hardware: the hurt and acid palette, spikes, the pause flash
        *(2026-10-02)*

- [x] **Step 26: Consolidation** *(`020567c`; gate green, 46 rungs, 12m51s against the 15-minute budget;
      `verify-full` green: seeding pins, worlds 312/312 pinned, credits 6 clocks and 4/4 faults)*
  - [x] `docs/conformance.md`: every new rung and case with its reference and fault; the gate
        time against Step 1's budget, splitting a slow tier out if it is over *(Step 25's codes
        on the roster; audit rows for 1.0 Steps 2-5, 6, 10, 12, 18, 19-20, 22, 25; under budget)*
  - [x] `docs/feature_tracker.md`: F4, F5 and F6, and the C entries, closed or `[~]` with a
        named defect. Also `README.md` and `docs/setup.md` *(F4, F6 `[x]`; F5 `[~]`, Metroid
        01's freeze; C1, C4, C5, C8, C10 `[x]`; C2 and C9 `[~]`, the same defect; C6 `[~]`, the
        312 pinned visits; C11 open; D3 added for 1.0)*
  - [x] Update the port's `01-requirements.md` Phase 1 text to point at this cycle
  - [x] (C10) Decide with James whether a window of the 100% recording joins the gate, as 0b
        Step 26 did with `recorded` *(no, James 2026-10-02: the recording stays in
        `verify-full`, the worlds and the credits' cross-check, and the gate keeps its budget)*
  - [x] (C10) The METROIDS page in playthrough order (James, 2026-09-27, deferred): the
        recording's kill order, `docs/phase1.md` *(and WARP's METROID ROOMS, numbered alike,
        James 2026-10-02; `debug_tables.playthrough`, held by a unit test to the record nearest
        each kill, failing on a swap)*

- [x] **Step 27: C11 — the hardware playthrough**
  - [x] James plays a **retail-built** cart on FXPak from new game to credits: all 47
        Metroids, every major item, split across saves as needed, without the debug screen
  - [x] Every defect found gets a `bug_tracker.md` entry, including lag and slowdown. It is
        fixed fixture first, or accepted by James
    *(first pass, 2026-10-02: four logged, in James's priority order. Each is a fixture shown
    failing, then the fix, then a hardware re-check)*
    - [x] **27a: killed Metroids respawn** (`D:04`, `A:17`, `A:F8`, `B:04`): `D:04` came back
          and froze Samus; the others came back unkillable after a long explosion. The count
          still fell each time, so the Omega at `B:8D` spawned early and the first-visit Alpha
          there was missing. Subsumes the open Metroid 01 entry
          *(two port defects, either enough: `EarthquakeCheck` left X off the slot, so the
          kill's pass ran misaligned and wrote $FF over the explosion's counter; and
          `ResetEntities` cleared the fight that 02:$418C leaves, freezing the post-death
          wait at a door, which then ran out mid-explosion at the next kill. Fixed; `warp`'s
          `missile_kill` failed 50 on HEAD's engine and fails 50 under each fault)*
      - [x] Reproduced on the cart with real missiles, no pokes
      - [x] Fixture first: `warp` `missile_kill`, failing on the unfixed engine
      - [x] Fixed, and a fault per cause (`ResetEntities_offscr`, `EarthquakeCheck_out`)
      - [x] Gate green *(`a510575`; 46 rungs, 12m33s)*
      - [x] James re-checks on hardware
    - [x] **27b: spike damage entering `F:C3`** from `C:3C`'s door ledge, after a jump scrolls
          the transition partly off screen and back
          *(a port defect: on the crossing frame a probe wraps to tilemap column 31 and reads a
          spike, and `StartTransition` never ported 00:$0C4F's clear of `samus_hurtFlag`, so
          the hurt landed after door $B9's warp. On the cart in Mesen the jump is not needed)*
      - [x] Reproduced on the cart with the pad alone, no pokes: hurt 99 to 91 on `F:C3`'s
            door ledge, where our Game Boy walks on unhurt
      - [x] Fixture first: `beams` `door spike`, graded to the warp and on the settled last
            frame (`oracle.Door`, new); failed on the unfixed engine
      - [x] Fixed (`StartTransition` clears `!HurtFlag`), and the fault `StartTransition_hurt`
      - [x] Gate green *(`f0141d5`; 46 rungs, 13m55s)*
      - [x] James re-checks on hardware *(fixed, 2026-10-03)*
    - [x] **27c: no item banner for the Spring Ball** after Arachnus
          *(the original's: 00:$3A1B and 01:$5820 raise the window only for items below $0B,
          and the Spring Ball is $0B; the port has both bounds. Accepted for 1.0 by James,
          2026-10-03, and recorded as an F12 enhancement for later, `feature_tracker.md`)*
    - [x] **27d: `9:E3`'s coral hurts once when walked through**, on every tick when jumped
          through
          *(James: in every coral area, standing or walking does no damage, off the floor it
          ticks. The original's: the coral is acid, tested in the top, bottom and spider
          probes only; on the floor only the bottom one runs, and it reads the floor. `beams`'
          `coral walk` and `coral jump` agree with our Game Boy frame for frame, health
          included; fault `AcidProbe`. James to accept it or ask for a departure)*
          *(2026-10-03, later: James says the original hurts on the floor too, tested by hand. Re-measured
          on Mesen2's Game Boy core, which we did not build: the 100% recording's part 4 to
          frame 1930 in `B:CA`, then right into the coral pit and stand. The fall through the
          coral ticks once (150 to 146, `$D062` = $40); walking along the pit floor in the coral
          and 270 frames standing in it take nothing, `$D062` = 0. Asked James which game he
          tested on, and whether he wants a departure. **Accepted as the original's for 1.0 by James,
          2026-10-03**: the original's coral behaves differently in different places)*
  - [x] Music and SFX spot-checked throughout *(good, James 2026-10-03)*
  - [x] Close the cycle when the playthrough completes with no open player-visible defect
        that James has not accepted
