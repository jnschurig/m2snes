# Feature Tracker

The port's feature set and where each feature stands. Unfinished features carry an empty `[ ]`
marker; a feature is checked off `[x]` only when it is delivered **and** something grades it.

A third marker, `[~]`, was added by B10's audit on 2026-09-15: **delivered and graded, with a
named defect still open against it.** It exists because `[ ]` and `[x]` both lied about the two
entries that have it — `[x]` would claim a feature the player can see is wrong, and `[ ]` would
discard the rungs that do grade it and the work that is genuinely done. A `[~]` entry must name
the open defect; when the last one closes it becomes `[x]`.

Every entry carries the same nested bullets, in the same order, the way a `bug_tracker.md` entry
carries `Cause:` and `Guarded by:`:

- **Phase:** `0a`, `0b`, `0c`, `1`, or `2+`.
- **Status:** what is actually true today, in a sentence.
- **Graded by:** the rung, fixture or evidence that would fail if the feature regressed. `none
  yet` is a legitimate answer for an unstarted feature and is never a legitimate answer for a
  checked one.
- **Deferred:** only when something inside the feature is not being done now, with the reason.

Dates go in the text, on the closure or the decision they belong to, as in the bug tracker.

**This file is deliberately documentation, not code.** `dispatch.unreached` and `coverage.zig`
are Zig tables because they are measurements derived from the ROM — they can be wrong and a build
can say so. A feature's phase and status are planning state: they are decided, not measured, and
nothing can validate them but reading. That is the same trade the bug tracker already makes, and
it carries the same cost — **there is no automated check that this file is current.** Keeping it
so is a step of the porting loop (`porting_loop.md`, "What a turn produces"), and the slice's
verification step audits it by reading rather than by building.

**Phase 1 opens by reading the unchecked entries here** rather than re-deriving them from the
requirements documents. That is why the whole game's feature set is listed and not just the
slice's: the slice is visibly a subset.

Feature ids match `.local/docs/`'s requirements documents in the planning repo — `F*` and `D*`
from the port's own requirements, `B*` from the Phase 0b slice cycle. They are two views of the
same work: a `B` entry is the slice's share of one or more `F` entries, named where they overlap.

---

## The port (F)

- [x] **F1. Bring-your-own-ROM builder** — one executable takes the user's Metroid 2 GB ROM and
  emits a playable SNES ROM, carrying no copyrighted data of its own.
  - Phase: 0a.
  - Status: closed 2026-09-01 with D1. Runs the whole pipeline end to end, injecting into the
    pre-assembled engine image.
  - Graded by: `zig build verify` — `ok snes rom 512 KiB cart, 108 blobs placed, identical across
    two runs` with a printed digest, and `ok snes engine 32 KiB image in 128 KiB reserved`.
  - Also guarded by: the file-policy check, which is what keeps ROM-derived data out of the tree.

- [x] **F2. Deterministic asset conversion, full game** — every deterministically-convertible
  asset class across the entire game, not just the slice's region.
  - Phase: 0a.
  - Status: closed 2026-09-01, **with a residual stated rather than rounded off**. Six classes
    remained unread; four were owned by a later phase by their own note. Three of those four are
    now closed: `enemy_data` in Step 9, and `item_names` and `samus_pose_tables` in Step 11 —
    **the round-trip is 130 of 130 with no raw class and `offsets.pending` is empty for the
    first time.** **And one class was converted, round-tripped and never *shipped*, which is a
    different kind of gap and cost the enemies their picture for two steps:
    `metasprite_enemies_*` had been correct in `offsets.zig` since Step 4 and had no
    `sprites.Which` entry, so nothing put it in the cart. Closed 2026-09-09 in Step 12d. A round
    trip says the bytes are understood; it says nothing about whether the cart can reach them.**
    What remains is `physics_constants`, `title_tilemap`'s successor work and the
    audio data in 0c with F8.
  - Graded by: `ok snes layout 225 KiB converted into 364 KiB reserved`, `ok coverage 189/256 KiB
    claimed, 17888 items`.
  - Deferred: `physics_constants` — most are scattered immediates with no class to convert, and
    the three that are tables were converted as the `physics` blob in Step 13. Not a conversion
    gap. `title_tilemap` — in bank 5 with no address comment, catalogued as unknown rather than
    guessed at. Nothing in 0a consumes it because the cart draws no title screen; **B2 is what
    will need it.**

- [x] **F3. Conversion verification** — automated proof that conversion is correct across the
  whole game, requiring no game logic.
  - Phase: 0a.
  - Status: closed 2026-09-01. The screen count came in at 904, not the ~300 the requirement
    estimated.
  - Graded by: `ok extraction 124 entries reproduce byte-for-byte`, `ok round-trip 122/124
    re-encode byte-for-byte (2 raw)`, `ok snes render 904 screens match pixel for pixel`, plus a
    4/4 fault sweep — the injected faults are what keep the comparison from passing vacuously.

- [x] **F4. Door script interpreter and table-driven dispatch** — the original's data-driven
  dispatch layers reimplemented so their tables transfer as data.
  - Phase: 0a (the survey) and 0b (the interpreter); whole in 1.0.
  - Status: **closed 2026-10-02, 1.0 Step 26.** Every operation of the 497 decodable door
    scripts has an arm in `StepDoorScript` (`ESCAPE_QUEEN` and `EXIT_QUEEN` since 1.0 Step 20d),
    and 426 of the 512 run on the cart against our Game Boy (why the rest do not is in
    `docs/conformance.md`'s `doors` entry). The enemy AI table holds all 39 AIs the spawn records
    reach. *The 0a/0b text follows.* **Half closed** at 0a: The survey landed 2026-09-01: 7 sites, 6 with a located table, 223
    table entries, and 49.0% of ledger instructions reachable from a table entry, with four
    unreached layers named and five sibling sites found in the bytes. The door script *data* all
    converts. The **interpreter opcodes are B1's work and are not written**, `WARP` first.
  - Graded by: `ok dispatch survey 7 sites, 6 with a located table, 223 table entries` for the
    survey half; the `doors` and `counts` rungs and the unit test over every decodable script's
    operations for the interpreter (1.0 Steps 18a, 18d); `enemy_oracle`'s census for the AI
    table (C1).

- [~] **F5. Game logic rewrite** — native 65816 reimplementation of Samus movement, collision,
  projectiles, enemies, items, save and progression.
  - Phase: 0a (movement) and 0b (the rest); completed across the full game in Phase 1.
  - Status: **the whole game is ported (1.0, closed by Step 26 bar the hardware
    playthrough).** Every AI the ROM reaches (C1-C3), the Queen and the baby (C4), every item
    (C5), the world (C6), the ending and credits (C7). **Metroid kills that came back**
    (Metroid 01 on 2026-09-29, four more in the hardware playthrough) were two port defects,
    fixed in 1.0 Step 27a and guarded by `warp`'s `missile_kill`; James's re-check is open. *At 0a:* Samus's movement poses are ported and graded frame-exactly. Everything else — B1,
    B4, B5, B6, B7 — is this cycle's work and unstarted. 262 routines and 11818 instructions are
    inventoried in the ledger, 59% of the estimated ~20000.
  - Graded by: the gate's emulator rungs, `docs/conformance.md` rung by rung, and the C
    entries below. *At 0a:* the segment oracle (644 frames of the original, frame for frame),
    the reachable rung (375 frames, exact, floor 375) and the anchored rung (394 frames across
    9 of 13 stretches, floor 394).

- [x] **F6. Metroid progression chain** — the global progression gate, called out separately
  because it spans five subsystems.
  - Phase: 0b, as B8; whole in 1.0 (C2).
  - Status: **closed 2026-10-02, 1.0 Step 26.** All thirteen `IF_MET_LESS` thresholds are
    graded on both sides, every lava door at each level it draws, the count reached through
    the debug menu's METROIDS page, and the Queen's `$01` and `$00` (C2). *At 0b's start:*
    unstarted. Measured 2026-09-02: `metroid_count_real` (`$D089`) holds at `$47` for the
    whole published-TAS horizon, so **no Metroid is killed inside it** and the published run
    cannot grade this at all.
  - Graded by: the `counts` rung (272 entries; fault: the branch inverted); `snes boot` 23 and
    `scenario`'s `metroids` for the kill's bookkeeping and the quake.

- [x] **F7. Play window, camera, and screen layout** — a 160×144 play window on a 256×224 SNES
  screen, the surrounding pixels UI rather than world.
  - Phase: 0a.
  - Status: closed 2026-09-01. This is what makes the shipped build and the verified build the
    same build: identical play window keeps enemy spawn timing identical, which is what makes the
    TAS oracle valid against what actually ships.
  - Graded by: `ok snes boot` — play window, samus, camera, scrolling, input, sprite — and the
    camera being a graded quantity on every rung.
  - Deferred: `VIEW_W`/`VIEW_H` stay build-time constants pinned to GB values through Phase 1. A
    wider view is F12, Phase 2+, because it shifts enemy spawn timing.

- [ ] **F8. Audio pipeline** — bank 4's sound engine rewritten in SPC700 assembly, driving the
  vendored GB-APU shim, with its data extracted from the user's ROM at build time.
  - Phase: 0c, in its own cycle (`.local/docs/2026-09-16-metroid2-audio/` in the planning repo).
    Moved out of 0a on 2026-09-01 (James's call).
  - **Decided 2026-09-20: the shim, not the TAD transcription F8 originally chose.** The port's
    `01-requirements.md` F8 and its decision table are amended to match. The open decision
    recorded here on 2026-09-05 is closed. Why it went that way:
    - **Exact, not by ear.** With the same requests on the same tick, the SPC700 engine writes
      the same `$FF10`–`$FF3F` registers, values and order as the Game Boy. `audiocmp` asserts it
      on all four channels, over `surface-30s` (3032 writes) and `title-30s` (11158).
      Transcription could never be graded that way.
    - **It fits.** On an FXPak Pro, engine plus two-channel shim is `surface` 12.9%/13.1% and
      `title` 19.1% twice, which agrees with offline to a tenth of a point. With CH3/CH4 and the
      SFX estimated in, that is **18.7% and 29.1% of a 50% budget**. It answers the shim
      verdict's CPU caveat (57.0% in fed mode, `.local/docs/2026-09-01-gb-apu-spc700-shim/04-verdict.md`), since the port does not use fed mode.
    - **No correction diffs, no one-shots.** Nothing copyrighted is committed, and bank 4's own
      priority and preemption carry the SFX.
  - Status: **in progress.** What exists:
    - `audio/shim/`, the shim package, generated in `snes_game_dev` and pinned by `MANIFEST`.
      It is the one vendored binary. There is no shared source.
    - `engine/audio/main.asm`: the whole song player (all four channels, every instruction,
      the pitch effects). The four SFX handlers, the interruptions, the fade and the pause still
      return at the Game Boy's own labels.
    - `zig build aramimage`, and `audiocmp` with its `.req` request scripts.
    - Not yet: CH3/CH4 in the shim, the rest of bank 4, the cart wiring, and the audio A/B.
  - Graded by: `audiocmp` exact on `surface-30s` and `title-30s`, and the gate's `aram symbols`
    rung. The load numbers are in the cycle's `03-measurements.md`.
  - Deferred within 0b: B8's earthquake music interruption is still a **silent stub**, since the
    cart is not wired yet. The `SONG` opcode records the original's song id, and 0c turns those
    recorded ids into its requests unchanged.

- [x] **F9. Inspection and A/B tooling** — human-facing surfaces on the verification
  infrastructure, emitting reviewable output from the code that already computes both sides.
  - Phase: 0a for graphics; the audio A/B moves to 0c with F8.
  - Status: closed 2026-09-01 for its 0a scope.
  - Graded by: `zig build inspect` — 60 graphics entries as A/B sheets with a diff channel,
    per-bank contact sheets over all 904 screens reporting `0 screens differ`, fault-injected
    variants beside them.
  - Deferred: assembled metasprite / OAM composition views, which F9 itself marks optional. The
    audio A/B is 0c's.

- [ ] **F10. Verification infrastructure** — whole-game integration, per-routine units, and
  manual exploration.
  - Phase: 0a for the layers; it keeps growing every cycle.
  - Status: the three layers exist and the gate is green end to end in about 130 s. Left open
    deliberately, because the slice adds rungs to it — B10 and B11 are both F10 work.
  - Graded by: itself. `zig build verify` with the segment oracle, the reachable rung, the
    anchored rung, the durations rung, `room.zig` scenarios, the ledger's instruction-boundary
    check and the file policy.
  - Note: as of 2026-09-05 the floors are **exact frames rather than bucket edges**, which is B9.
    A headline number that moves for a tooling reason has cost this project a day twice.
  - Note: as of 2026-10-04 (1.0 cleanup) **a missing ROM fails the gate instead of skipping it.**
    `verify`, `verify-full` and the new `test-rom` stop with `no ROM: set M2_ROM ...`; plain
    `zig build test` still skips. Every test reads the ROM through `testrom.load`, which skips
    only when no ROM is configured and fails on any read error; a test in `testrom.zig` fails on
    any other `rom_path` read in `src/`. `ledger`'s and `room`'s recorders flag a failed
    allocation, and `dispatch` and `tas` fail on the flag instead of printing a short report.

- [ ] **F11. Romhack and randomizer integration surface** — symbol/address map, data-driven item
  placement, documented save layout.
  - Phase: 1.
  - Status: unstarted.
  - Graded by: none yet.

- [ ] **F12. Quality-of-life features** — stackable beams, and the rest, each delivered in
  whichever phase it becomes ready.
  - Phase: 2+.
  - Status: unstarted, and deliberately not started early — QoL that changes enemy spawn timing
    invalidates the oracle against the shipped build.
  - Candidates, each a departure from the original that James has asked for:
    - **The Spring Ball's banner** (James, 2026-10-03, from 1.0 Step 27c). The original
      shows no item banner for the Spring Ball: both window raises for a pickup, 00:$3A1B
      and 01:$5820, are `CP $0B / JR NC`, and the Spring Ball is item $0B. Nor does any door
      script carry `ITEM $B`, so the name is never written to the window row ($9C20), and
      raising the window alone would show the last name written. The enhancement needs both:
      the bound widened to take $0B in `ItemJingleFrame` and at `!ITEMNO_MAJOR_END`'s compare,
      and "SPRING BALL" (`item_names` $B, 01:$59C1) resolved into `!ItemName` on the pickup,
      since Arachnus's room has no `ITEM` op to do it. It changes no timing: the jingle's
      length is the same with the window up. Its guard needs a reference of its own, since
      our Game Boy will not show it.
  - Graded by: none yet.

- [ ] **F13. Stretch — MSU-1 and PC target.**
  - Phase: 2+.
  - Status: unstarted. Approach deliberately unspecified.
  - Graded by: none yet.

- [ ] **F14. The builder without the door crawl on every run.** `m2snes` crawls every door
  on each build (about 30 s on 12 lanes), but the crawl feeds only the debug menu's WARP page
  (`snes_convert.debugBlobs`), which a retail cart cannot open. The crawl is deterministic for
  the one accepted revision, so it could be computed once.
  - Phase: 2+.
  - Status: open question, deferred by James on 2026-10-05 during release Step 6. Options:
    (1) retail skips the crawl and leaves out the WARP tables. That needs a retail repin, and
    a check that nothing outside the debug menu reads `warp_data`. `--debug` still crawls.
    (2) Build the crawl into the binary. That ships about 96 KB of ROM-derived facts (rooms,
    cells, and the 13-byte loaded-state block on each side of each door), so it needs the
    ROM-data rule amended for that file. (3) Cache it on the player's machine after the first run.
    Claude recommended (1).
  - Graded by: none yet.

## The milestones (D)

- [x] **D1. Phase 0a — asset base converted, verified and inspectable.** Not playable as a game.
  - Status: closed 2026-09-01. All ten acceptance criteria re-read against evidence rather than
    remembered, including the hardware pass on the console the same day. Three things remain open
    and all three are open in writing.
  - Graded by: `zig build verify` green end to end with no rung retired.

- [ ] **D2. Phase 0b — a contiguous, manually playable slice**, landing site through the second
  Alpha Metroid, on a proven pipeline.
  - Status: in progress. The region is defined in `slice.md`; B9 is closed; everything else is
    ahead.
  - Graded by: B10, which names the harness explicitly — `zig build verify` green, rung by rung,
    with every rung's reference and fault check accounted for in `docs/conformance.md` — and the
    hardware pass that closes the cycle.

- [x] **D3. Phase 1 (1.0) — the complete game**, title to credits on hardware, as the C
  entries below mirror the cycle's requirements.
  - Status: all of C1-C10 delivered and graded (1.0 Step 26), three `[~]` with named defects.
    It closes on James's playthrough of a retail-built cart, new game to credits (C11).
    **Closed 2026-10-03** on that playthrough (C11).
  - Graded by: `zig build verify` and `zig build verify-full` green, rung by rung in
    `docs/conformance.md`, and that playthrough.

## The slice (B)

The Phase 0b cycle's features. Each is the slice's share of one or more `F` entries.

- [~] **B1. Room transitions and screen streaming** — the mechanism the reachable count actually
  stops on, and the critical path for everything after it. `F4`, `F5`.
  - Phase: 0b.
  - Status: **the crossing works, 2026-09-07.** The port walks into a door and comes out the
    other side frame for frame with the Game Boy. What exists: `RunDoorScript` (was
    `RunBootScript`) is a transition executor rather than a boot-only walker; `WARP` acts, and
    `DAMAGE`, `SONG`, `ITEM` and `IF_MET_LESS` record their operands instead of being stepped
    over by length; `StartTransition` turns a cell into a door index out of the transition word
    the converted cell already carries; the four triggers in `HandleCamera` are ported branch for
    branch from 00:$0921, $099B, $0A5E and $0ACF and **armed** (`TransArmed` is `$01`); the
    interpreter is frame-paced, one opcode per frame with the rest of the frame's work skipped
    exactly as 00:$0522 skips it; and 00:$0B44's in-transition camera scrolls the incoming screen
    in at four pixels a frame, dragging Samus at one.
  - The duration is a **computed quantity**, not a constant. `src/transition.zig` holds the rule
    — a frame per opcode (00:$26D1), `ceil(len/64)` frames per VRAM transfer (00:$2BC7's drain),
    39 for `FADEOUT`'s frame-clocked fade — and grades it against the Game Boy opcode for opcode
    on a sample that reaches every opcode the ROM's 512 door scripts contain: **160 of 160
    scripts agree, in all four directions.** `engine/main.asm`'s `OpExtraFrames` is the same rule
    in 65816, and a test reads it back out of the assembled image. `docs/slice.md` carries the
    measurement.
  - **The crossing draws Samus again, 2026-09-15, Step 17.** `.transitionFrame` never called
    `DrawSamus`, which is the only writer of `!OnscreenX`/`!OnscreenY`, so for every frame of a
    crossing those held their pre-transition value and `ClearUnusedOam` hid the slots nothing had
    appended — she was not in OAM at all. The original draws her: its skip at 00:$0522 jumps to
    $053E and `drawSamus` is $0550, past it. **Graded by `snes boot` phase 27**, the first thing
    here to let a transition's scroll run, and `reachable` moved **1466 → 1999 of 1999** on the
    fix, because the door triggers read the byte that had been stale.
  - **Open against it, which is why this is `[~]` and not `[x]`:** the fade transition also runs
    the scroll where it should fade alone (Step 20); every crossing flashed the screen black
    before the animation, because the forced blank was held across the whole door script and a
    scrolling script has no `FADEOUT` (fixed in Step 24b: the copies wait for vblank instead);
    and Samus's animation holds one frame for the length of a crossing
    (Step 24c — measured, mechanism not yet identified). B1-adjacent: a shot fired as a vertical
    scroll begins is dragged across (Step 18). All are in `bug_tracker.md`.
  - **Closed against it:** the enemy hit cashed at handover, which Step 17's fix resolved
    incidentally — the collision reads the bytes that had been frozen. Closed on playtest
    evidence, `Guarded by: playtest only`.
  - Graded by, in three places: `snes boot`'s transition phase (handed a door index, the cart's
    `WARP` re-seats map bank, cell, camera and Samus — screen halves replaced, **pixel halves
    kept**); the **reachable** rung, 375 → 420, which now walks *through* the door rather than
    stopping at it; and the **durations** rung, 17/13 → 19/17, where the run's two leftward
    crossings — door transitions whose scripts carry no `WARP` — went from one frame to the Game
    Boy's twenty-one.
  - Also moved: `anchored_gate_floor` 394 → 445 (Step 5, `SeedPlacement` loading the cell's
    scroll flags at boot) → 462 (Step 5b, stretch 0 now completing all 392 of its frames)
    → **665** (Step 6).
  - **The incoming screen is drawn, 2026-09-07, Step 6.** `handleWarp`'s four draw arrangements
    are ported as `WarpDraw` — three metatile strips going right, left and up and four going
    down, each one the same `StreamRun` the per-frame streamer walks, with the waits Step 5b
    already had between them. `TILETABLE` reaches the same dispatch, because 00:$2856 is
    `JP $2918`. **No door script in this ROM carries a tilemap `COPY`**, so those strips and the
    streaming behind them are the whole of how a room arrives; that was worth finding out before
    building anything else.
  - Two defects came out of it and both are in `docs/bug_tracker.md`. A cart booted from a
    mid-run record had one screen in all 1024 tilemap slots and so the wrong room on the far
    side of every boundary (`SeedWindow`); and `TILETABLE` selected a table that nothing
    re-read, so a room entered through a door was drawn and walked in the tileset the cart
    booted with (`LoadMetaBase`). The second was caught by the fixture written for the first
    half of this step, on that fixture's first run.
  - Graded by, additionally: `snes boot`'s code 137, which drives the crossing **twice — once
    right and once down**, per D2, and compares `!TilemapBuf` against the ROM's own map data
    expanded through the table the script selects. The reachable rung went **420 → 899 of 899**
    and then **1396** once the offered window was raised to 2000; durations **19/17 → 28/28**.
  - Still deferred: `FADEOUT`'s palette animation (the transition holds forced blank where the
    original fades). (This also listed "`$D022`'s count of owed columns", which was a misreading:
    `$D022` is the run cycle's timer, and the crossing's advance of it is Step 24c's.)
  - What the first user of the mechanism arm found, in two turns. The arm's warning is that
    porting half a mechanism makes a rung pass on stale state; it arrived in the mirror-image
    shape first — a rung that had been passing because the port *lacked* the mechanism, 375
    earned by standing still for 94 frames for the wrong reason. Then, once the duration was
    modelled, it cost **three separate off-by-ones and a boot defect**, none of which the model
    could see and all of which the machine could: the entry wait sharing a frame with the first
    opcode, a split `spr` transfer charging two dispatch frames for one Game Boy opcode, the
    `END` frame belonging to the interpreter rather than the main loop, and a cart booting with
    its sprite guides at zero — which reads as "hard left" to two of the four triggers.

- [x] **B2. Title-to-game transition** — pose `$13`'s 320-frame sequence, and a cold boot that
  reaches gameplay without a synthesised boot record.
  - Phase: 0b.
  - Status: closed 2026-09-08. **Hand playtesting is now the primary development loop**: the cart
    `zig build rom` writes shows the title screen, starts on Start, and plays. Nothing has to be
    poked into it.
  - `title_tilemap` is pinned (05:5B34, $400) and read: F2's second unknown is closed, and the
    only one left was `samus_pose_tables`, which **Step 11 closed** — the knockback, spider and
    morph tables at 01:$4C69, $4C8C and $4CB5, and no separate queen table, because
    `samus_drawJumpTable` sends all six Queen poses to `drawSamus_morph`. Pinning it needed both ends and got them —
    `credits_starPositions` below and the already-pinned `gfx_titleScreen` above — so the size is
    ROM arithmetic rather than a listing.
  - The cold boot's numbers are the game's own. `initial_save` (01:4E64) is the record
    `createNewSave` copies into `saveBuffer`, and `save.appearance` reads the pose and the
    countdown off the four instructions that end `loadGame_samusData` rather than transcribing
    them. Reading `initial_save` is also what caught the collision-table naming defect in
    `bug_tracker.md`.
  - Graded by: `ok cold boot`. The one rung here that pulls no lever — it presses Start on the
    title and a direction when the game asks for one, and watches everything else. The title's
    4096 characters and 1024 tilemap words are compared against the cartridge's own bytes, the
    countdown is watched falling one a frame, the flicker is measured as a share, and control has
    to wait for the button. Eight faults were injected across the two halves and each was caught
    with its own code; the gate re-injects one of them every run.
  - Out of scope and left so: the title's flashing palette, its falling star, the three save
    slots and the cursor. `loadingFromFile`'s branch is ported and has no writer until B7.

- [x] **B3. The porting loop's second arm** — the loop knows how to port a pose handler; the
  slice needs it to port a mechanism.
  - Phase: 0b.
  - Status: closed 2026-09-05. `porting_loop.md` carries both arms, the standing failing-fixture-
    first rule, what a turn produces, and the turn log. This file is the other half of it.
  - Graded by: documentation review, not a build check — same trade as the bug tracker, and
    stated as such above. The arm's real test is B1, its first user.

- [x] **B4. Enemies** — dispatch, AI, hitboxes, damage. `F5`.
  - **Closed 2026-09-15 by B10's audit**, which is a bookkeeping closure and not new work: the
    status bullets below were written per-step and the last of them (Step 12f) left the entry
    open while its own sub-entries B4a, B4b, B4c1 and the Alphas had all closed. All thirteen
    censused AIs are ported, the `enemy AIs` rung grades eighteen rooms pass for pass and each
    faulted cart differs, and the spawn walk the Step 12f bullet called ungraded is graded by
    `snes boot` 15. Nothing was ported to close this; the entry was stale.
  - Phase: 0b, in three steps: the entity foundation, AI and damage, then Alpha Metroids —
    and the third has since split in two, because the *death* of an ordinary enemy turned out to
    be a prerequisite of the bombs rather than of the Alphas. See B4c1 below.
  - Status (B4b, 2026-09-09): **the AI and the damage landed; the Alphas have not, and the cart's
    spawn walk is not yet graded.** `enemy_commonAI`'s four state tests and its dispatch
    (02:$5630), as a table from the Game Boy address in the slot to a ported routine — the
    original's `jp hl` cannot survive a port whose slots hold bank-2 addresses. Three arms in it:
    `enAI_NULL`, `enAI_smallBug` and `enAI_senjooShirk`, which are what the segment reaches. The
    hitbox test in all four of its entries (00:$32AB, $32CF, $348D, $34EF) over
    `collision_samusOneEnemy` and its vertical twin; `hurtSamus` and three of `applyDamage`'s
    four entries, BCD and all; poses $0F, $10, $11 and $12 with both dispatches each; the i-frames
    spent in the draw and the four-on four-off blink. Three new converted blobs in the `enemies`
    region — the damage byte per id, the hitbox records and their relocated pointers — and four
    in `physics`, which is where this port keeps per-pose Samus tables.
  - Graded by: **the oracle segment, extended from 644 frames to 700**, whose last 56 run with
    enemies live and moving on both machines. It is the rung the plan said would move at B4b and
    it moved. Twenty-one `ledger.zig` rows, of which eight were dropped again on the gate's own
    instruction-boundary check and folded into their callers'; twenty-four `residue.zig` fields.
  - **Three defects, each found by a rung and each with its own `bug_tracker.md` entry**, and
    they are the shape of this step more than the port is:
    - the enemy pass ran every frame where the original runs it every *other* frame — Step 9 read
      `enemy_sameEnemyFrameFlag` as the `rLY` lag mechanism and it is the 30 FPS gate, which the
      original's own comment says and the Game Boy confirms in one column;
    - the cart enabled NMI wherever boot happened to end, so a longer boot put the enable inside
      vblank and cost every walk step its parity — latent since the engine had an NMI at all;
    - `SpawnListAt` subtracted 9 from an index that was already 0-based, so the cart loaded no
      enemy anywhere.
  - Status (Step 12f, in progress from 2026-09-13): **the AIs the slice dispatches, measured off
    the game and graded against it.** `zig build gbtrace -- ais 73400` hooks the `JP (HL)` at
    02:$5650 over James's recording through Alpha 2's death and names thirteen AIs; nine were
    unported (`docs/slice.md` has the table). `enemy_oracle.census`, `.pending` and `.step13` are
    the ledger of that work, and a unit test fails if a census AI is neither ported nor pending.
    **All nine are ported (2026-09-13)**: the hopper, both crawlers, the rock icicle, the
    Gullugg, the Chute Leech, the pipe bugs, the wallfire and the missile door, with what they
    share -- the enemies' tilemap probes (`getTileIndex.enemy` and eleven `enCollision_*`
    entries), `!SolidEnemy`, the position mirror, the acceleration curves,
    `enemy_spawnObject.shortHeader`, `enemy_deleteSelf`'s parent link (which retired `!EnChild`)
    and the weapon direction `enemy_getSamusCollisionResults` hands on. Every ROM table is a
    `physics` blob; the two spawned headers are eleven and ten engine bytes graded against the
    cartridge. `enemy_oracle.pending` is empty.
  - Graded by (Step 12f): **`zig build oracle -- enemies`, and the `enemy AIs` rung in `zig build
    verify`.** Each ported AI is handed the same slot on the Game Boy harness and the cart in a
    room it lives in, and the two slot histories are compared pass for pass; the cart with that
    AI's `AiTable` row blanked must disagree on every run. Eleven rooms, every one agreeing
    pass for pass: children an AI spawns are graded with it (the pipe bug's bug, the wallfire's
    fireball), and a case can hand slot 0 projectile contacts at fixed ticks, which is how the
    missile door's five missiles and the wallfire's death are graded. Shown failing by hand with
    the probe never finding a floor (the cart's hopper falls through at pass 44).
  - **What it found**, all in `docs/bug_tracker.md`: `ProcessEnemies` ran an AI on the pass that
    deactivated its slot (fixed); the cart's camera moves where the Game Boy's does not in four
    rooms (open); a neighbour loads a frame late in `$9:$E6` (open); and the dropped `rLY`
    budget measured for the first time.
  - Deferred, each with the step that owns it: `enemy_getDamagedOrGiveDrop` and the drop,
    explosion and ice states `enemy_commonAI` tests for (B5, B6 and the ice beam; `!EnUnhandledState`
    records the first one ever reached rather than mis-dispatching it); `queen_eatingState` and
    `queen_roomFlag` (B8); `applyDamage.queenStomach` (ported in 1.0 Step 20a, with the
    Queen's poses; `.acid` was ported in Step 22, at all six of its sites);
    drawing the enemies, which nothing grades because the SameBoy rung masks objects; and the
    `rLY` budget, which stays dropped and is now correctly distinguished from the gate above.
  - **What the extension found and did not fix, stated so the next turn does not rediscover it:**
    at 120 frames the segment reaches frame 702 exactly — the contact frame — with every frame
    before it matching, and stops because the cart does not register the hit. At frame 689 the
    Game Boy has three live slots and the cart two: **the cart's spawn walk loads a different set
    of records**, which is Step 9's walk and has never been graded on the cart side by anything.
    `zig build trace`'s new `en` columns are the instrument for it.
  - Status (Step 13c, 2026-09-14): **the Alpha alive.** Both Alpha AIs are in `AiTable` --
    `enAI_hatchingAlpha` (02:$6BB2) and `enAI_alphaMetroid` (02:$6C44), which are one AI with two
    doors -- with every branch but `.death`: the flash-and-range wait, the freeze, the eight
    flashes, the face-screen and the rise (borrowing `enAI_zetaMetroid.oscillateNarrow`),
    `.startFight`, the seen flag's quick path, the beam dink, the screw attack's reaction and
    knockback, the missile's hurt, stun, blink and knockback, and the lunge cycle on the four
    `.farWide` probes. `alpha_getAngle` and `alpha_getSpeedVector` from bank 1, with the slope's
    multiply and divide, and two new `physics` blobs (the angle table and the sixteen speed arms,
    carried as the code they are). The Metroid globals `metroid_state`, `metroid_fightActive`,
    `cutsceneActive`, `alpha_stunCounter` and `metroid_screwKnockbackDone`, with the clears at
    02:$412F, 02:$45BB and 00:$0C28; and `cutsceneActive`'s two readers outside the AI, the play
    handler's cutscene arm (00:$050B) and `drawSamus`'s dummy input (01:$4C05). `.death` records
    `$80` into `!EnUnhandledState` until Step 13d, and `enemyHandler`'s music restore is 13d's.
    `enemy_oracle.step13` is empty.
  - Graded by (Step 13c): **the `enemy AIs` rung, five more rooms** -- the hatching Alpha in
    `$F:$10` through its whole intro and into the fight, the plain Alpha in `$E:$B2` from three
    places Samus stands, and shot there with a beam, four missiles from four directions and a
    screw attack. Every one agrees pass for pass and every faulted cart differs; hand-injected
    faults in the quadrant base, the slope band, the rise's oscillation and the missile
    knockback's ceiling were each caught, and a middle stride of 8 in the wide probe was **not**
    (no terrain in these rooms is where that point moves; `correspond.zig` grades the operand).
    **The hurt's coin is handed across, not graded**: it reads `rDIV`, the port reads `!EnFrame`
    (`AlphaCoin`), and the oracle gives the cart the Game Boy's flags on the pass its own hurt
    lands -- without that, `alpha shot` differs at its third hurt. `snes boot` phase 21 grades
    the rest: the freeze with a pad held (210-212), Select during a cutscene (213), and the coin
    as `!EnFrame`'s low bit, both ways, over six hurts (214, 215); each of 211-214 watched failing
    on its own fault. No `ledger.zig` rows: no run the ledger observes dispatches an Alpha, so the
    boundary check would drop them, as it did 12f's.
  - Status (Step 13d, 2026-09-14): **the Alpha's death, and both killable.** `.death` (02:$6D61)
    -- the explosion sprite, `metroid_state` $80, fight flag and spawn flag 2, both counts down
    one in BCD, the shuffle at $C0, the jingle recorded in `!MetSong` -- and `enemy_commonAI`'s
    fourth test into `enemy_metroidExplosion` (02:$5732), which every slot in the room goes
    through while a Metroid dies: the freeze, four blasts of six frames moved and pulled back on
    screen, the collision copy cleared, the slot deleted for good and Samus thawed.
    `enemyHandler`'s top (02:$4029): the post-death timer, climbing on even frames to $90, and the
    restore that asks for `currentRoomSong` + $11 unless no Metroids are left -- also taken when a
    transition starts mid-fight. `earthquakeCheck` is B8's and records the count it was handed in
    `!QuakeAsked`. `!EnUnhandledState`'s Metroid arm is retired.
  - Graded by (Step 13d): **two kill cases in the `enemy AIs` rung**, each at the recording's own
    shot ticks (`zig build gbtrace -- kills`, in `docs/slice.md`): the hatching Alpha in `$F:$10`
    through its intro, five missiles, the explosion, the deletion and all $90 steps of the timer
    (1240 ticks), and the plain Alpha in `$E:$B2` the same way (840). The rung now also grades
    seven Metroid globals per case -- the timer, state, freeze, stun, fight flag and both counts
    -- each as its own collapsed history, and the cart's record is write-on-change so a case can
    outlive one save file of frames; every earlier case still agrees. Faults caught by hand: no
    `$80` test, no displayed-count decrement, the first blast moved right, the timer to $91, the
    restore keeping the fight, no delete; the edge clamp at $17 was **not** caught (no blast
    reaches an edge in these rooms) and `correspond.zig` grades all 29 operands instead.
    `snes boot` phase 22 grades what the oracle cannot see (216-222): the jingle and the
    earthquake recorder, the explosion's freeze and frames, **the timer stepping on even frames
    only** -- the oracle's collapsed history cannot, because the killing pass lands on the other
    counter parity on the two machines -- the restore's song with and without Metroids left,
    the band's count after the shuffle, and a transition ending a fight; 216-220 and 222 watched
    failing each on its own fault.

- [x] **B4a. The entity foundation** — slots, the spawn walk, the despawn window.
  - Phase: 0b.
  - Status: landed 2026-09-08. Sixteen slots with the
    original's field layout, the per-screen spawn walk that fills them (03:$4014 both axes,
    03:$422F, 03:$42B4, 03:$42C1), the camera carry (03:$6BD2) and the three-state despawn window
    (02:$452E, 02:$4464, 02:$44C0). Nineteen `ledger.zig` rows, eighteen `residue.zig` fields. The
    spawn records and the enemy headers convert into the cart as a new `enemies` region, and
    `enemy_data` is no longer one of the classes `coverage.zig` calls unread. **Enemies do not
    move, are not drawn, and cannot be touched** — that was B4b and B4c, and B4b has since
    landed the first two of those three.
  - Graded by: three fixtures in `src/room.zig` that put the *running Game Boy* in the segment's
    own cell and read its slot array back — the reader is graded against the game rather than
    against our own arithmetic — plus the negative case on an empty cell and a cell-index check
    that requires both neighbours to disagree. The gate's own rungs are the guard against
    regression: `oracle`, `reachable` and `anchored` all hold at their previous figures.
  - **And the segment rung did not move, which the plan expected it to.** That expectation was
    wrong for this step rather than the step being incomplete: the oracle compares position,
    camera and pose, the reference's enemy is already in every frame it grades, and a port whose
    enemies neither move nor draw cannot change any of the three. It moved at B4b, 644 to 700.
  - Graded by, additionally (Step 19, 2026-09-16): **`enemy reload`, the gate's thirty-first
    rung.** The camera is driven off an enemy and back, on the Game Boy and on the cart to the
    same schedule, and what is compared is whether the *record* is live again and under which
    spawn flag -- which is the despawn window's three states plus the walk's reload, the thing
    the fixtures above could never ask because a standing Samus loads nothing. Six cases: both
    Metroids, an ordinary enemy as the control, and each again with the room reset a transition
    asks for. **Before it, this whole mechanism was graded by `snes boot` 15 and nothing else,
    and the lost-Metroid defect that sat on it had no guard at all** -- 15a fixed that defect and
    nothing would have caught it coming back. `alpha2 reset` is now the guard for 15a's flag
    translation: deleting `$04` -> `$FE` takes it from 134 of 134 passes to 11.
  - **And what these fixtures could not see, found by B4b on 2026-09-09:** all four grade the
    *reader* against the running Game Boy, and none of them looks at a slot on the cart. The
    cart's own walk was reading the pointer table $2400 entries low and loading nothing at all,
    for a day, with every rung green. See `bug_tracker.md`.
  - **And one thing it did not do, found by a person and not by a rung (2026-09-09):** nothing
    here draws. `drawEnemies` was not ported until Step 12d, and the enemy metasprite set was not
    shipped into the cart until then either — so from this step until that one the game had
    enemies that moved, hurt Samus and could be killed, and could not be seen. See
    `docs/bug_tracker.md` for why no grading path in this repository could tell.
  - Deferred, each with the step that owns it: the `rLY` budget that makes the original's pass
    run every other frame (no analogue on this cart, and inventing one would be a number nothing
    measured); the saved half of the spawn-flag array's persistence (B7); the parent link in
    03:$6AE7 that a dying projectile walks (B5, and recorded in `!EnChild` rather than skipped).

- [x] **B4c1. The death of an ordinary enemy** — the explosion, the drop, and the freed slot.
  `F5`.
  - Phase: 0b. Carved out of B4c on 2026-09-09 and landed 2026-09-12, ahead of the bombs.
  - Status: **landed, and it is a blocker that was found by playing rather than by a rung.**
    `enemy_animateExplosion` (02:$56BF) with `.becomeDrop` (02:$56E7) and `enemy_animateDrop`
    (02:$5692), which are two of the four state arms `enemy_commonAI` had been *recording* in
    `!EnUnhandledState` rather than running. The gap was not inert while it waited: the kill path
    set `+$0E explosionFlag` and never changed the slot's status, so a corpse stayed **active** —
    drawn, and a projectile target that `collision_projectileEnemies` deleted every later beam on.
    Measured on the shipped cart 2026-09-09: a shot fired at an enemy 28 px away died after four
    frames identically whether the enemy was alive or a corpse. Sixteen pixels, and from the
    player's seat it read as no beam leaving her weapon, so **the first kill in a room left an
    invisible beam-trap** and combat degraded from there.
  - It also reached the drop arm of `enemy_getDamagedOrGiveDrop`, ported in Step 12b and until now
    unreachable by anything: nothing could put a `+$0D dropType` in a slot.
  - **One substitution, and the approved source for it was wrong.** `.becomeDrop`'s 50%
    drop-nothing roll reads `rDIV`, the Game Boy's free-running divider, which this machine has no
    counterpart for. The plan's approved stand-in was `!FrameCount`'s low bit; at the call site
    that bit is a *constant*, because the enemy pass acts only on the frames `!EnSame` is clear and
    `!EnSame` toggles once a frame — so every corpse in a room would have rolled the same way.
    Measured on the cart 2026-09-12 rather than argued: over 1000 frames of the boot room,
    `!FrameCount & 1` took one value on every frame the pass acted. The roll reads `!EnFrame`
    instead, the port's `$FFFE`, which is the counter the neighbouring `enemy_animateDrop` already
    divides at 02:$569F — so the substitution borrows a quantity the original reads at this point
    in the code rather than inventing one. Recorded as a substitution in `residue.zig` and the
    ledger, never as a port.
  - Graded by: two new `snes boot` phases. One kills a slot outright and asserts three things —
    the explosion frames are on the screen, **the slot frees itself**, and a beam fired through
    where the corpse was flies on, which is the half that failed before this step. The other makes
    a corpse that leaves small health and asserts the drop's type and sprite, its blink, and
    Samus's health moving when she collects it; it *retries* rather than poking `!EnFrame`, because
    half of all corpses leave nothing and a rung that wrote the quantity it grades would grade
    nothing. Nineteen constants pinned to the opcodes that carry them in `src/correspond.zig`,
    including three reader shapes the repository did not have — `LD B,d8`, `AND d8` and the
    `LD BC,d16` whose two halves are a drop's type and its sprite, asserted as a pair because that
    is how the cartridge sets them. Four injected faults watched failing: the explosion arm removed
    (177), the drop arm removed (182), and the pass counter stopped from counting (184).
  - **And a blind spot in an older rung, found by the first beam on this cart ever to leave the
    play window.** The despawn is in the draw (01:$5300), so a beam that dies at the window edge
    was composed into OAM on the frame it died — which leaves `!SprX` holding the beam with the
    array already empty, and `checkSprite`'s alias half read that as Samus drawn in the wrong
    place. The guard now covers the frame *after* a projectile as well as the frames with one. No
    earlier phase could reach it: every earlier beam dies on an enemy or a block, inside
    `handleProjectiles` and before anything draws it.
  - Deferred to B4c proper, Step 13: the Alpha Metroids' own damage state and death. The ice arm
    and `metroid_state` are still the two that `!EnUnhandledState` records.

- [x] **B5. Projectiles and combat** — firing, travel, terrain and enemy collision, missiles.
  `F5`.
  - Phase: 0b.
  - Status (2026-09-09): **delivered in two steps, and the despawn is in the draw.**
    Step 12a ported the destruction machinery on its own, before anything could fire at it;
    Step 12b is what fires. What exists now: `samus_tryShooting` and the Select toggle,
    `samusShoot` with all five of its arms including the plasma spread, the three-slot array and
    its weapon-dependent search, `handleProjectiles`' five branches and both copies of the
    terrain classification, `drawProjectiles`, `collision_projectileEnemies` and its one-enemy
    hitbox test, and `enemy_getDamagedOrGiveDrop` with `enemy_checkDirectionalShields` — the
    damage, the freeze, the plink, the drop collection and the explosion flag a kill sets.
    **A beam's range is the screen and nothing else**: no timer, no room test, just
    01:$538A deleting a slot whose sprite would have landed outside the visible window, which is
    the one thing about this mechanism that reads wrong until you have seen it. Terrain
    collision runs at 30 Hz and enemy collision at 60, out of 01:$52A0's `frameCounter & 1`.
    Eleven small tables joined the converted set — the two cannon offsets, the direction mask
    and its priority resolution, the wave and missile speed curves, the missile's two sprite
    rows, the beam sounds and `weapon_damage` — and their addresses are one gapless run from
    01:$55FB to 01:$5671, which closes on an address Step 12a pinned by a different route.
  - Graded by: `zig build verify` — `snes boot`'s `a shot` and `and into an enemy` phases, whose
    lever is **the fire button and not a poke**, which is the first time that has been true of
    any phase in this gate. They assert an empty array before the press, a slot filled after it,
    the direction the facing gives with no d-pad held, a destructible block broken and the beam
    dying on it, and then `weapon_damage`'s first entry coming off an enemy's health with
    02:$4333's stun. Watched failing three ways on 2026-09-09: `SamusTryShooting` out of
    `MainLoop` reports `never appeared`, `EnemyDamageOrDrop` out of `ProcessEnemies` reports
    `took nothing off it`, and `VarTriggerX` put back to `!SprX` reports the sprite-anchor
    failure the bug below is about. Also `correspond.zig`'s "every projectile constant is the
    operand of the opcode it was read out of", twenty-six constants against their own
    `CP`/`LD`/`ADD`/`SUB` sites.
  - One defect fell out and it is a *class*: `!SprX` and `samus_onscreenXPos` were one variable
    in this engine, correctly, for as long as Samus was the only thing it drew — and
    `drawProjectiles` writes the first and not the second. Six readers would have been asking a
    projectile where Samus is. See `docs/bug_tracker.md`.
  - Status (2026-09-14): **the bombs, Step 12c, and the explosion happens in the draw.**
    `samus_layBomb` and `bombBeam_layBomb` (one `FirstEmptyBomb` for their two identical slot
    walks), `handleBombs`, `drawBombs`, `bombs_samusAndBGCollision` with its five tile arms as
    one `BombProbeTile`, and `collision_bombEnemies` with its one-enemy test. The two arms that
    used to record into `!PrUnhandled` now branch where the original does, and the bomb slots
    are cleared at boot and at a door. `samus_bombPoseTable` (01:$55DD) is pinned, which makes
    the table run gapless from there to `destroyRespawningBlock`. **Three things the plan had
    wrong, each read off the ROM**: the bomb's tile arm is *not* `HitBlock`'s three tests with
    `BIT 6` in the third — it has no beam-threshold test at all, going straight from
    `CALL $2266` to `CP $04`; `collision_bombOneEnemy` has no damage test either, so a bomb
    hits enemies a beam passes through, and it grows the box $10 on all four sides; and the
    $DD30/$DD40/$DD50 clears in `StartTransition`, which that routine's comment called entity
    slots, are the bomb array.
  - Graded by (bombs): `snes boot`'s phase 18, whose lever is the fire button in the ball.
    No bomb without the Bomb; exactly one for a press held past `samusShoot`'s cooldown; laid
    where 01:$5400/$5405 put it; drawn first in OAM; a fuse and an explosion the length
    01:$53FB and 01:$54C5 load, to the frame; and on the explosion's first frame a bomb-only
    tile of the boot room's own collision table gone, a respawning block at the right tile in
    the block array, Samus in the pose `samus_bombPoseTable` gives the ball, and a zero-damage
    enemy placed so that only the $10 pad on both axes reaches it losing `weapon_damage`'s last
    entry. Watched failing nine ways on 2026-09-14 — no `HandleBombs` (189), no Bomb gate (185),
    no `!BLOCK_BOMB` arm (192), no vertical pad (195), the OAM reset put back in `DrawSamus`
    (189), no throw (194), a probe eight pixels short (193), no fuse count (191), and the held
    button read for the pressed one (188). Also `correspond.zig`'s "every bomb constant is the
    operand of the opcode it was read out of", forty-three sites. **Two clears are ported and
    ungraded, and measured so**: with both `ClearProjectiles`' bomb half and `StartTransition`'s
    removed the gate still passes, because a zeroed slot lies off the window and `drawBombs`
    deletes it on the first frame.
  - Status (2026-09-14, Step 13a): **missiles fire, because the cart now has some.** A playtest
    pressed Select and fired a dud: boot record versions 1-10 carried no loadout, so every cart
    started with zero health, zero tanks and zero missiles, and `samusShoot`'s empty test was the
    only missile arm a player could reach. Version 11 carries tanks, health, both missile counts
    and both Metroid counts -- the new game's from `initialSaveFile` through `save.initial`, a
    handover's from what its reference measured (all six off a Game Boy this repository runs;
    tanks, the ceiling and the real count off the recorded trace, which has no other columns).
    **The toggle was a recording and is now the original's**: `loadGraphics` swaps the cannon's
    two tiles into Samus's sheet and `beginGraphicsTransfer` spends a frame waiting for them, so
    the play handler is split across two frames. `!CannonHold` is that split; NMI uploads the
    tiles and the next `MainLoop` resumes the pass after `SamusTryShooting`.
  - Graded by (missiles): `snes boot`'s phase 19, run between 17 and 18 because the bombs leave
    her in the ball. The boot loadout against the ROM's (197), the toggle both ways (198), the
    cannon's converted tiles in VRAM (199), the hold up for exactly one frame (200), a missile
    launched (201) costing one in BCD (202), and the dud at zero (203). Watched failing seven
    ways: the missile seed zeroed (197), the toggle's weapon store removed (198), the sheet index
    dropped (199), the hold never set and never cleared (both 200), decimal mode off for the
    decrement (202), the empty test removed (203). Every floor unmoved -- no graded stretch
    presses Select -- and the boot record test in `snes_inject.zig` pins the decoded loadout.
  - Deferred, each with the step that owns it: **01:$5790, the reform's crush**, unchanged from
    Step 12a: a nineteen-byte pose table at 01:$57DF this repository has not pinned. The
    explosion a kill sets (`+$0E`) is written here and animated by B4c, Step 13. The Queen's
    two arms — a paralysing missile and `queen_eatingState` — are B8's and are recorded.
    `toggleMissiles`' cannon graphic, which is a $20-byte re-upload into the middle of Samus's
    own sheet with no mechanism behind it, recorded in `!CannonGfx`. The bomb's two Queen arms
    at 00:$3187, which open on the same `queen_eatingState` (ported in 1.0 Step 20a,
    `QueenBombArms`). And the sound ids, which
    are `!Sfx1`/`!SfxNoise` with no driver, exactly as `SONG` is.
  - Note (closed 2026-09-09): adding `B` to `oracle.supported_input_bits` is **a
    measurement-affecting change of the same class as `codes_per_quantity`** — it alters what the
    cart is handed on every graded frame — so it landed in a commit of its own, with the port
    already in and every floor re-measured in it. `reachable` 1396 → **1466**, and the stop goes
    back to being a position divergence; `anchored` and `durations` are unmoved, because every
    anchored stretch diverges on its first frame and a beam cannot reach them. The movie's input
    ceiling has moved rather than gone: reference frame 3411, where the run opens the map.

- [x] **B6. Items and pickups** — pickup and effect for every item type the region yields, and
  the `!Items` gates 0a wrote out but could never reach. `F5`.
  - Phase: 0b.
  - Status (2026-09-09): **delivered, and the `ITEM` opcode is not what gives an item.** The
    plan's sub-task read as though it were; 00:$2634's arm loads four graphics blobs — the
    item's tiles, the orb, the item font and the name out of `item_names` — and walks on.
    Every `samusItems` bit is set by `handleItemPickup` (00:$372F), which a *sprite* reaches:
    `enAI_itemOrb` (02:$4DD3) turns the orb into the item when it is shot and sets
    `itemCollected` when Samus touches the item. All three parts are ported —
    the AI, the fifteen-arm dispatch and `handleItemPickup_end`'s two wait loops — with the
    blocking turned inside out into `!ItemStage` the way the door interpreter was.
  - **The frame cost is measured, not derived.** From the B11 recording at stride 1: the item
    bit lands **exactly four frames** after Samus freezes on all four of its pickups (Bomb
    44 325/44 329, Missile Tank 44 964/44 968, Energy Tank 48 043/48 047, Spider Ball
    68 449/68 453), which is the four `waitOneFrame`s at 00:$3734; the freezes run 358, 103,
    366 and 359 frames against the `$0160` and `$0060` the countdown is set to. The remainder
    is the second wait loop, which is as long as the enemy pass takes to delete the orb — so
    it is deliberately not modelled as a constant.
  - Graded by: `snes boot`'s phase 9 and 10 — the Bomb lands four frames after the freeze on
    the bit the *cartridge's* own arm sets, Samus does not move for the whole jingle, and then
    the ball jumps with the Bomb held and rolls without it. The second half is the point: it
    is the **first `!Items` branch anything on this cart has ever taken**. Fault sweep: an arm
    that ORs the wrong bit reports 142, and a `RunItemPickup` that never notices reports 140.
  - **And it found a two-phase-old defect**: two of the six `!Items` masks were the wrong bit
    (`docs/bug_tracker.md`, 2026-09-09). Nothing could see it, because a mask that is never
    set is a mask that is never read.
  - Deferred: Hi-Jump and Spring Ball are not collected — neither is in the recording, and
    Hi-Jump's doors are referenced by nothing in the region. **Their arms are ported and their
    branches are not graded.**
  - Deferred, ported-but-ungraded, against phase 1 — every one of these is written out in the
    port and reachable by nothing this cycle has:
    - **The nine pickup arms the region does not yield**: the four beams, Screw Attack, Varia,
      Hi-Jump, Space Jump, Spring Ball and the two refills. Each sets its bit or its beam.
      *`loadGraphics` (00:$2753) was a recorder, `!GfxWanted`, until 1.0 Step 8a ported it;
      the `gfx` rung grades each pickup's tiles.*
    - **The Varia suit's fanfare wait and its tile-by-tile transformation animation.** The item
      bit, the face-screen pose and the turn timer are ported; the two animations are not.
    - **The missile refill's credits branch**, which tests `metroidCountReal` — B8's variable,
      which the port does not have. The branch records the item that reached it in
      `!ItemUnhandled` instead of testing a byte that does not exist. *The test is real since
      1.0 Step 10 (`!MetReal`); only mode $12 is still recorded, until 1.0 Step 22.*
    - **The `!Items` branches for Hi-Jump, Screw Attack, Space Jump, Varia and Spring Ball** —
      nine sites in the pose machine and the collision resolver. Their masks are now checked
      against the cartridge even though the branches are not taken.
    - ~~**The window raise** at 00:$3A1F, recorded in `!ItemWindow`: the Game Boy slides `rWY`
      over the bottom of the screen for a major item, and the port's window is an HDMA band
      whose movement is Phase 0c's.~~ **Ported in Step 24g**: `!WinY`, `WriteWindow`, and
      the item's name in the bar under it.
    - **`enAI_itemOrb`'s delete arm**, and with it the far half of the `itemCollectionFlag`
      handshake. The boot rung's room has an empty spawn list, so the gate stands in for the
      AI's two stores there; the arm is ported and ungraded.
  - ~~Deferred, against phase 1, and not B6's: Spider Ball's `!Items` branches do not exist in
    this engine.~~ **Withdrawn 2026-09-15 (Step 14b).** A playtest could not reach the second
    Alpha without the spider ball, so D2 could not be met with it deferred. And the premise was
    wrong: the branches existed, under the wrong name. Every Down arm into the spider (00:$1788,
    $1254, $17A8, $0ED4) is `BIT 5,A`; three read `!ITEM_SPRING` and the fourth, pose `$12`'s, was
    not dispatched at all.
  - **Spider Ball works** (2026-09-15, Step 14b): the four poses `$0B`–`$0E`, the eight-probe
    contact nibble, both direction tables (`spiderDirectionTable` 00:$20A9 and
    `spiderBallOrientationTable` 06:$7E03, pinned and converted as physics blobs 32 and 33), the
    sprite, and `$12`'s own handler. Measured on the recording first: its route to the second
    Alpha uses `$0B` and `$0E` only (68 440–72 975); `$0C` and `$0D` are ported because `$0B` and
    `$0E` fall into `$0C` on losing contact.
  - Graded by: **`zig build verify`'s `spider segment` rung**, 847 frames of the original with
    Spider Ball held, frame for frame in position, camera and pose, over a ledge, down its face,
    off it into `$0C` and back on — shown failing at the ledge with the corner rotation removed.
    And `snes boot` phase 25 (233–239): gated on the bit, a floor's nibble, a pixel a frame, the
    pad and A leaving, landings attaching, and `$12`'s Down arm. `correspond.zig` checks every
    probe offset, pose store, table row and sprite base against its instruction.
  - Deferred: **the recording's own spider route is not graded frame for frame.** Its anchors
    boot map 3 cell `$13`, whose table the cart gets wrong (4 against the Game Boy's 9) — B12's
    loaded-state question, Phase 1's. **`$0D` is graded only by phase 25's landing**, since no
    segment input reaches a jumping ball with Down. (`applyDamage.acid` on a spider probe was not
    ported until Step 22, which ported it on every Samus probe.)

- [x] **B7. Save and load** — a real save station inside the region, a record `src/save.zig`
  decodes, and a load that restores it. `F5`.
  - Phase: 0b.
  - Status: done (Step 15, split into 15a-15d on 2026-09-15). **15a, the station and the
    save (2026-09-15)**: the contact from both bottom probes (00:$1F4F, $1F92) and its three
    clears; `miscIngameTasks`' Start arm, its 255-frame cooldown and the "PRESS START" /
    "COMPLETED" sprites; game mode $09 as one frame of its own; `saveFileToSRAM` and
    `saveEnemyFlagsToSRAM` into 8 KiB of cartridge RAM laid out as the Game Boy's; the save buffer
    the door interpreter writes (a converted `COPY` now carries its Game Boy source for it);
    02:$418C's per-bank swap of the spawn flags' saved half, which the port had been carrying
    across banks; and the in-game timer. The HUD icon's save-point rise, ported in 13b, is graded
    now. The window does not rise, as it does not for a pickup. **15b, the load (2026-09-15)**:
    the title's slot check ported as it is, broken compare and all (05:$426D), and the file
    counter; `loadSaveFile` and `loadEnemySaveFlags`; the variables `loadGame_samusData` and
    `gameMode_LoadA` read; and `loadGame_loadGraphics` from the record's own pointers, through a
    converter-built table of every source a door can store (the doors class's `load_sources`),
    the item font a load adds included. Four enemy sources land between tiles when read in bank 6,
    and are converted as the bytes the Game Boy copies. A new game still replays its door script.
    Not ported: `loadGame_samusItemGraphics` (00:$3BB4) — Varia, Spring Ball, the spin sheets and
    the beams, none in the slice. **15c, the death (2026-09-15)**: `killSamus` at the play
    handler's displayed-health test, across its `waitOneFrame`; modes $06, $05 and $07 in place of
    the play handler; `VBlank_deathSequence`'s erase over the object characters in NMI; the wait on
    the death noise as its timer ($B0); the GAME OVER screen from the title's characters, the
    cleared map and `gameOverText`, with the window off and the Game Boy's five blank frames; the
    two-frame game over pass on the timer or Start; and the reboot through `Reset`, which keeps
    cartridge RAM. The death's input erase and collision refusals, on the one frame they matter.
    Not ported: the Queen's arms, and the soft reset. **15d, the round trip (2026-09-15)**:
    nothing new ported — the mechanisms are 15a's, 15b's and 15c's — and what it adds is the
    grader that runs them as one scenario, on both machines, against a record the *cart* wrote
    rather than one the gate invented. `death.measureReload` and `death.on_reload` pin the
    load's four mode lengths on our Game Boy and check them against the recording's own frames.
    Two findings, both in `docs/slice.md`: the recording's 52 frames from death to reload are
    not a gradable duration (39 of them are a human pause on the title screen), and the
    `surface` tileset a new game starts in has no save-station tile in it at all, so neither
    machine can save where it starts.
  - Graded by: `snes boot` phase 26 (240-245, six faults caught, the writer's absence shown
    failing first); the HUD check's code 207, which now counts a station's contact; `save.zig`'s
    test on the record the recording wrote at 23 001; `correspond.zig`'s save test (constants,
    magic, the writer's store order against `save.fields`). 15b: the `load` rung in `zig build
    verify` (slot 0 holds the recording's first save; room, position, camera, energy, items,
    counts, solidity, table, background characters and item font against the cartridge -- and
    since Step 21 the common item tiles in the object characters, on a new game too (174); a
    saved-half spawn kept dead; control without a button; a record the broken check refuses starts
    a new game; an energy mismatch fails it), shown failing on four injected faults; and
    `correspond.zig`'s load test (every store `LoadGameState` makes against the ROM's load).
    15c: the `death` rung in `zig build verify` (two deaths on the shipped cart, every mode's length
    against `src/death.zig`'s Game Boy measurement: $06 127, $05 55 with 5 blank, $07 256 on the
    timer and 22 after Start, all matched to the frame; each erase step's stride; the GAME OVER
    screen against the cartridge's bytes; cartridge RAM across the reboot; a Start held through it
    not taken), shown failing on eight injected engine faults and on an expectation three frames
    long; `death.zig`'s two Game Boy tests; `correspond.zig`'s death test.
    15d: the `round trip` rung in `zig build verify` — the shipped cart played from its title
    through one unit of energy, a station laid from a collision table that has one, a save, the
    bytes captured out of cartridge RAM, a death, the reboot and a load, with room, position,
    camera, energy, tanks, missiles, items, beam, facing and both Metroid counts graded against
    those captured bytes and `metroidCountReal` checked to be the saved `$46` and not a new
    game's `$47` — shown to grade by a run whose slot energy is changed after the capture (207).
    On the Game Boy, `room.zig`'s two round-trip tests: the same scenario with `SaveLog`
    watching the writer, and the Metroid count carried across a reload; each ends by perturbing
    the record's energy field and requiring the perturbed value to come back.
    `death.zig`'s reload tests pin the load's lengths against the recording.
    Before 15a: none. **A TAS cannot grade this at all** — a tool-assisted run only saves when
    saving is faster than not, and neither published run does. The test is the scenario James
    named on 2026-08-30: spawn Samus with one unit of energy, walk her to a station, let something
    damage her, and assert the loaded state is the state the record said. A `room.zig` scenario,
    not a movie.

- [x] **B8. Metroid progression chain** — `F6` end to end, which is why D2 requires the *second*
  kill.
  - Phase: 0b.
  - Status: in progress (Step 14). The first `IF_MET_LESS` gate (`$46` against a start count of
    `$47`) trips on the **first** kill: 00:$254A takes the branch at or below the operand. It was
    recorded as "exactly two kills" until 2026-09-15, and the engine's stub never branched, which
    is the acid room a playtest found. Taken for real since Step 14, `snes boot` code 224.
    **What Step 13d already gives it (2026-09-14)**: a kill takes one off `metroidCountReal` and
    `metroidCountDisplayed` in BCD and sets the shuffle timer to $C0, graded against the Game Boy
    by the two kill cases; the post-death timer and the restore's recorded song request, which is
    the music interruption's *restore* half; and `earthquakeCheck`'s call site.
    **What Step 14 adds (2026-09-15)**: `IF_MET_LESS` taken for real, so the `lavaCaves` tables
    swap (door `$04A` 8 → 6, door `$0D9` 7 → 8 → 6); `earthquakeCheck` with the ROM's
    thresholds; the countdown, the quake's shake of the background and of Samus, and its end;
    the `SONG` opcode holding a song during the quake. `songInterruptionPlaying` is written where
    the quake's request is made, standing in for the driver's acceptance, as measured.
  - Graded by: `snes boot` phase 23 (codes 223–229): the gates at each count; the quake's tick,
    its 255 steps and shake on even frames, a door's song held and asked for at the end, and the
    Queen's `$60`. The enemy oracle's two kill cases compare `nextEarthquakeTimer` with the Game
    Boy's through the arming and first ticks. `correspond.zig` checks the thresholds and every
    operand. The recording's quake is measured in `docs/slice.md`.
  - **Closed 2026-09-24 (Step 22).** B10's audit had held it at `[~]` because the acid neither
    dropped to the right level nor damaged. Two defects, neither of them the quake: the lava
    table slots were layout order where the ROM's pointer table says Empty/Full/Mid, so every
    lava room drew one level high (`snes boot` code 227, and `screens`' pointer-table test), and
    `applyDamage.acid` was ported at none of its six sites (codes 252 and 253). See
    `bug_tracker.md`'s two acid entries.
  - Deferred: the music interruption is a silent stub — see F8. The **path** must fire and
    restore; the assertion is against the song id the `SONG` opcode records, which is an assertion
    that survives whichever driver lands in 0c.

- [x] **B9. Gate numbers that do not move for tooling reasons.**
  - Phase: 0b.
  - Status: closed 2026-09-05. The exit-code bucket is now bisected to the exact frame in both the
    gate and the CLI, at a cost of three extra emulator runs on the reachable rung and eight
    seconds on the anchored sweep, inside a 130 s gate. `movie_gate_floor` held at 375 — the
    bucket's bottom edge happened to be the true frame — and `anchored_gate_floor` rose 390 → 394,
    which is nine bucket edges that had been discarded. `bucket` reproduces the old numbers.
  - Graded by: `oracle.Bisect`'s property test — every divergence frame in 1..900 against every
    bucket width in 1..32, asserting the pinned frame does not depend on the width — plus the
    emulator measurement at four values of `want` returning the same frame each time.
  - Note: the root cause is unchanged and unfixable from this side. Mesen2 swallows `emu.log` in
    testrunner mode and sandboxes Lua's `io`, so the whole verdict is squeezed through a one-byte
    process exit code. The bisection works around the byte; it does not widen it.

- [ ] **B10. Verification for the slice, consolidated.** `F10`.
  - Phase: 0b, and the cycle's closing gate.
  - Status: unstarted, except for one playtest aid added 2026-09-15 (Step 14): **the room
    readout.** L held with R pressed shows `B:CC T` (the Game Boy map bank, the cell, the metatile
    table, in hex) in the top border on BG1. It is latched, redrawn only when one of the three
    changes. Off by default; its font is uploaded on first use so a cart with it off is unchanged
    to the frame. Graded by `snes boot` phase 24 (230–232): off and undrawn for the whole run
    before it, the toggle and the border band, the tiles against the live room, and a relatch
    through a door.
  - **The audit landed 2026-09-15 as `docs/conformance.md`**: the thirty-rung roster with each
    rung's reference and fault check, the mechanism-by-mechanism table for Steps 5–15, the
    fixture-first compliance review of all 46 `bug_tracker.md` entries, and the retired-rung
    answer (none). The gate names itself and points at it in its own first and last lines.
  - **What the audit found, and what it hands on:** `snes boot` grades nine of the seventeen
    ported mechanisms alone and is the one emulator rung with no fault run; the eight open
    playtest defects cluster in exactly those rows; the anchored rung's `665 of 6848` is met by
    two stretches while nine gradable ones play zero frames; and the recording reaches the gate
    at three frames. Each is a task of its own rather than a line in this one.
  - Graded by: itself. Includes the audit of the standing failing-fixture-first rule, and the
    documentation review of this file.

- [x] **B11. A recorded reference run for what the published TASes refuse.** `F10`.
  - Phase: 0b, and a **hard prerequisite** of everything from B4b onward rather than a supplement.
  - Status: the recording arrived 2026-09-03 as `reference/metroid2.mmo`, a Mesen2 movie of
    76 951 frames that saves several times, dies once and reloads, collects Bomb, an Energy Tank,
    a Missile Tank and Spider Ball, kills two Metroids, and ends on a save. **It is a superset of
    everything B11 asked for.** What is missing is the mechanism that turns it into a graded
    reference trace — a Mesen2 Game Boy Lua sampler — and that is the feature now.
  - Graded by, **corrected 2026-09-15 in B10's audit**: the sampler landed in Step 8
    (`src/gb_trace.zig`, `zig build gbtrace`) and the recording is now the reference behind the
    `load` and `round trip` rungs' records and the `status bar` rung's three sampled frames
    (45101, 48601, 74001). What is **not** wired to the gate is the anchored recorded sweep —
    `zig build oracle -- recorded` grades from any anchor and nothing runs it on every gate. So
    B11 is the primary grader off-gate and a three-frame sample on it. The published horizon
    still contains no kill, no save and no death, which is why that gap matters.

- [x] **B12. Tileset assignment graded against the running game.** `F2`, `F3`.
  - Phase: 0b.
  - Status: closed 2026-09-05. `zig build oracle -- worlds` replays both published runs on the
    Game Boy alone and grades `screens.assign`'s choice for every cell either run stays in, by
    reading the tilemap out of the emulator. **34 cells reached: 19 agreed before the fix, 24
    after, with none regressing.** The fix is an inheritance pass — a door script that names no
    metatile table leaves the previous room's loaded, so its target inherits the *source room's*
    whole choice, table and door index together. It seeds 79 cells and is vetoed in the two banks
    where a ROM-derived check says it makes the picture flatter.
  - Graded by: `oracle.anchored_gradable_floor` (11), `screens.zig`'s "the tables a running Game
    Boy showed", "no screen is drawn through a table that collapses the metatiles it uses"
    (≤ 1388 pairs, against 2447 before), and `zig build oracle -- worlds` itself.
  - What it moved: anchored stretches 4 and 8 became gradable (9 → 11 of 13), offered frames
    5174 → 6848, durations 15 → 17 compared and 11 → 13 agreeing, screens drawing from VRAM no
    door wrote 72 → 44.
  - What it found instead of what it expected: the step assumed two rogue cells and a
    nearest-warp-target rule that needed retuning. The measurement says the model itself is
    approximate — **the Game Boy treats the metatile table as loaded state, not as a property of
    a cell** — and nine cells are still wrong because the door table does not contain their
    answer at all. Both are in `bug_tracker.md`; the second is a Phase 1 question, because a port
    that loads tilesets from door scripts at runtime would not have it.

- [x] **B13. The HUD.** `F5`, `F7`.
  - Phase: 0b.
  - Status: closed 2026-09-14, Step 13b. BG2 is the Game Boy's window: its tilemap word `n` is
    $9C00+`n`, its scroll puts word 0 where WX $07 and WY $88 put the window's corner, and from WY
    down the HDMA band takes BG3 off and puts BG2 on, so the backdrop -- the window's colour 0 --
    shows through the bar's blanks the way the window's opaque colour 0 covers the Game Boy's
    background. The twenty characters are the top of Samus's own sheet (ids $9C-$AF), uploaded at
    boot with `hudBaseTilemap` (05:$40F0, a `physics` blob). `VBlank_updateStatusBar` runs in NMI
    on the vblanks the original's handler reaches it; `adjustHudValues` and `drawHudMetroid` run
    in the play pass where the original calls them.
  - Graded by: **the HUD oracle** (`zig build oracle -- hud`, and in the gate). 281 ticks against
    our Game Boy, tile for tile: eleven static value sets covering every digit in every cell and
    zero to five tanks, two rolls across a hundreds boundary, both health clamps, and the shuffle
    timer from a kill's $C0 to zero with a walk inside it that streams rows -- the frames the bar
    and its timer skip. Faulted with `HudTens`' digit base one high, it differs. And three frames
    of James's recording off **Mesen2's** Game Boy -- after the Missile Tank, after the Energy
    Tank's refill, after the second Alpha -- whose window rows the cart draws the same. `snes
    boot`: the band's pixels are the window tiles BG2 names (204), the icon is in OAM on every
    frame (205) on `frameCounter` bit 4's sprite (206) and rises through the Bomb's jingle (207),
    and a roll takes one unit a frame (208) with a tick on every fourth (209).
  - Watched failing: the oracle with the map-row gate removed, with `AdjustHudValues` off the play
    pass, with the scramble threshold one high and with full tanks read from the wrong byte; `snes
    boot` with the icon's frame test inverted, the rise test inverted, BG3 left on the band, BG2's
    VOFS missing the PPU's line, no tick sound, and no `LoadHud`. Each on its own tick or code.
  - The substitution: the scramble reads `rDIV`. Measured at 01:$49F9 on 120 status-bar frames,
    DIV advances $12 or $13 a frame, 5/16 of them $13 -- 70224 CPU ticks over 256 -- so the port
    keeps a clock, `!DivClock`, advanced $12.50 by NMI. The scramble is graded by when it starts
    and stops, not by its digits, and `hud_oracle`'s DIV test re-measures the step.
  - Deferred: the Queen room's HUD and the pause screen's L counter (B13's own out-of-scope).
    **The L counter is ported in 1.0 Step 2a** (01:$4A0F), graded by the `pause` rung.
    ~~**The window raise** for a major item stays `!ItemWindow`'s recording (B6), so during a
    jingle the icon rises a row above a band that does not; the Game Boy raises both.~~ **Ported
    in Step 24g**, for the jingle and the save station both. The icon's
    save-point rise is ported and reads `!SaveContact`, which nothing writes until B7.

## The whole game (C)

The Phase 1 (1.0) cycle's features, mirroring its requirements' C1–C11. The backlog they work
from is `docs/phase1.md`, derived from the ROM by `zig build roster`.

- [x] **C1. The remaining enemy AIs.** `F4`.
  - Phase: 1.
  - Status: **closed 2026-10-02, 1.0 Step 26.** All 39 AIs the ROM's spawn records reach are ported; `enemy_oracle.pending` is
    empty since 1.0 Step 21, the baby's (C4). Arachnus was 1.0 Step 13's, C3; the Gamma,
    Zeta, Omega, larvae and stinger 1.0 Steps 14-17's, C2. The children go with their parents. **1.0 Step 11 ported the first batch**:
    skreek, drivel and `drivelSpit`, moto, gravitt, halzyn (with the sine motion the missile
    block shares), septogg, and both flitts. Bank 0 being full, they are in bank 1 behind
    `AiTableFar`, which `EnemyCommonAI` falls back to. **1.0 Step 12 ported the second**:
    glowFly, proboscum, both skorps, autrack and its laser, autom and its flame, gunzoo and its
    shots, missileBlock, and blobThrower with `blobProjectile`. The thrower's WRAM part list
    and hitbox are kept as high-WRAM copies.
  - Graded by: the census test (`enemy_oracle`, "every AI the ROM's spawn records reach is
    ported or pending"), widened from the recording to the ROM in 1.0 Step 1 and shown failing
    with an AI dropped from `pending`; each AI's case in the `enemy AIs` rung as it lands.
    Step 11's nine cases all agree pass for pass, and each faulted cart differs. The drivel's
    `rDIV` toss is handed across (`Case.dividers`). The two platforms' carrying of Samus is
    graded by the `beams` rung's `septogg ride` and `flitt ride`, frame for frame, with the
    carry faulted out. Step 12's nine cases agree too, the thrower's seven globals with them;
    the autom's and gunzoo's tosses are handed across (`Case.dividers`). Not graded: the
    missile block's weave, which neither of its records reaches (each explodes on the pass
    it is hit).

- [~] **C2. Metroid species and progression.** `F4`, `F6`.
  - Phase: 1.
  - Status: **delivered and graded, 1.0 Step 26; one defect fixed and awaiting James's re-check.**
    Killed Metroids came back (Metroid 01, $A:$17, on 2026-09-29; four in the 1.0 Step 27
    playthrough): `EarthquakeCheck` left X off the slot, and a crossing ended a post-death wait
    the original carries on. Fixed in 1.0 Step 27a; `warp`'s `missile_kill` guards both. The roster is 46 spawn records plus the Queen, checked against
    `initial_save`'s `metroidCountReal` of $47 (`roster.zig`). **1.0 Step 14 ported the
    Gamma** (02:$6F60), branch for branch in bank 1: the molt from the Alpha's sprite, the
    fight, its lightning bolt (the same AI in a child slot), the missile's probed push, and
    the kill. `gamma_getAngle` (01:$723B) with its own table and bands, and its twenty-four
    speed arms, are physics blobs 50 and 51. The Alpha's angle, slope and speed routines
    moved to bank 1 with it, where both share the distance and slope, and bank 0 gained 400
    bytes. **1.0 Step 15 ported the Zeta** (02:$7276) the same way: the intro with its
    husk, the fight's seek, spit, rise and wait with its fireball, the dink from below, the
    unprobed push and the kill, with `enemy_seekSamus` (03:$6B44, its table physics blob 52)
    and `metroid_keepOnscreen` (02:$7DC6); the Omega shares both and the larvae the seek. **1.0 Step
    16 ported the Omega** (02:$7631) the same way: the blinking intro, the spit and the wait
    on its fireball (the same AI in another slot, aimed by `gamma_getAngle` and bursting on
    `enCollision_up`/`down.nearSmall`), the chase picks with their early return, the chase,
    rise and wait, the dink for a missile up or down, and the front and back hurts. **1.0
    Step 17 ported the larvae** (02:$7A4F) the same way: the latch, which is global, the
    bomb that sends one off her and the fly-off, the freeze and its own thaw, five frozen
    missiles to a kill that is an ordinary enemy's explosion with both counts down, the seek
    with `metroid_correctPosition` (02:$7CDD), and a room's entry clearing the latch. **And
    the stinger** (02:$6B83), the final area's event: the eight larvae onto the shown count,
    the hive's song, and Samus frozen for $8A passes. **1.0 Step 18d:** twelve of the thirteen
    `IF_MET_LESS` thresholds graded on both sides on the cart, the count reached from the
    METROIDS page, and every lava door at each level it draws (the `counts` rung). `$01`'s taken
    side reaches her room. `$00` since 1.0 Step 20d: door `$19E` escapes into `$E:$C1` at `$01`
    and exits through `$19F` into `$F:$A9` at `$00`.
  - Graded by: the `counts` rung (272 door entries at their counts since 1.0 Step 20d; 270 before, faulted by `IF_MET_LESS`'s
    branch inverted); the `enemy AIs` rung's `gamma`, `gamma shot` and `gamma kill` in `$E:$85`,
    Samus frozen, each with its row blanked and a behaviour fault (the bolt fired early, the
    left push always put back, a shot at the bolt's time hurting); the kill at the recording's
    spacing (kill 26, part 12), with `gamma_stunCounter` graded as a global. The rung's
    `zeta`, `zeta shot` and `zeta kill` in `$A:$F8`, the same way (the tail wait cut, a
    missile going down pushed left, a missile from below hurting); the kill at kill 30's
    spacing (part 13) with one idle gap 500 shorter, and `zeta_stunCounter` a global. The
    rung's `omega`, `omega shot` and `omega kill` in `$B:$76`, the same way (the tail wait
    cut, a missile up or down hurting, a back hit taken for a front one); the kill at kill
    38's spacing (part 20) with three gaps shorter and each missile aimed at the side the
    recording hit, so its health steps are the recording's; the Omega's stun, wait counter
    and chase index are globals. The rung's `stinger` in `$E:$22` (not frozen, so its freeze
    and thaw are graded; the fault adds nothing to the shown count), `larva` and `larva bomb`
    in `$D:$10` (Samus not frozen: it latches and drains her, and late bombs send it off; the
    faults leave the touch unlatched and keep it on her) and `larva kill` in `$D:$00` at kill
    40's spacing (part 21: eight ice shots and five frozen missiles; the fault leaves it alive
    after the fifth). The larvae's three bytes and Samus's health are globals.

- [x] **C3. Arachnus.** `F4`.
  - Phase: 1.
  - Status: **1.0 Step 13.** `enAI_arachnus` (02:$5109) and its fireball (02:$52DF), branch for
    branch in bank 1: the orb, the bounce off the pedestal, standing and spitting, the curl
    while B is held, and the six bombs that turn it into the Spring Ball. Its state is global
    ($C390-$C394), and its three jump tables are one physics blob (49). The Spring Ball's WARP
    entry is Arachnus's record. Getting there found and fixed a warp defect: the sweep lost
    the row under `scrollY`'s wrap (`docs/bug_tracker.md`, 2026-09-29).
  - Graded by: the `enemy AIs` rung's `arachnus`, `arachnus roll` (B held on both machines,
    `Case.fire`) and `arachnus kill` (the recording's bomb spacing), each with its row
    blanked, plus behaviour faults for B ignored and for any weapon taken as a bomb. And the
    warp rung's `spring_ball`: bombed, picked up, bit set, not there again; fault: the orb's
    AI never installed (46).

- [x] **C4. The Queen, and the baby Metroid.** `F4`, `F5`.
  - Phase: 1.
  - Status: **closed 2026-10-02, 1.0 Step 26**, after Steps 19-21 and James's playtests.
    Being caught in her room by GAME OVER was 1.0 Step 25's (`GameOverQueenFlag`).
    **Step 6, the spike: GO.** `ENTER_QUEEN`, `door_queen`, `queen_renderRoom` and
    `queen_initialize` (all but her sprites and state list) are ported, with `queenHandler`'s
    camera pair and `queen_setActorPositions`. Her raster split is three HDMA channels built
    from `VBlank_drawQueen`'s own list each vblank: TM, BG3's scroll, and window 2 as the head's
    columns, BG2 being the Game Boy's window. The window's map is BG2's, BG3 holds Samus's
    $80-$AF as the Game Boy's background reads them, and her room streams no rows. She does not
    move or fight yet (Step 19); BGP mid-frame (her hurt flash) is an INIDISP band still to
    build (`docs/phase1.md`, Step 6). `EXIT_QUEEN` and `ESCAPE_QUEEN` are still skipped by
    length. **Step 19a**: the table build moved out of NMI to the end of the main loop's pass,
    double-buffered (NMI ends on line 237 in her room, not 257); her page is the Game Boy's
    whole `$C300` page at `!QueenPage`; and the Queen oracle (`zig build queen -- oracle`)
    holds 378 bytes' histories to our Game Boy's over a 604-frame no-input fight. It fails
    as it should on the engine as it stands: `queen_state` stays $17 where the Game Boy's
    goes on at frame 140. It found and fixed `queen_headDest`. **Step 19b**: the fight she
    runs on her own is ported (`queen_initialize` whole, `queenHandler` but for her head's
    collision, the state list and states $00-$07, $0C, $14-$18, the walk, the neck, the feet
    in NMI, the spit and her objects through `PutObject`), and the oracle passes all 604
    frames. Her eating, stomach and death states ($08-$0B, $0D-$13) record into
    `!EnUnhandledState` until Step 20; her hurt, the missile's paralysis and BGP mid-frame are
    19c's. **Step 19c**: her hurt is ported (`queen_headCollision`, `queen_missileHurt` and
    the kill's `queen_closeFloor`, which Step 20 reaches), the open mouth's missile stuns her,
    and BGP mid-frame is two more HDMA channels, INIDISP for the brightness and COLDATA for
    her flash's $03, added white over the head and the room. The volley found her room
    overrunning a frame with a missile out mid-lunge, which is fixed with 16 lines of margin
    (`docs/bug_tracker.md`). **Step 20a**: being eaten and bombed out of her mouth. Samus's
    six Queen poses ($18-$1D, all drawn as the ball), `gameMode_Main.queenBranch`,
    `applyDamage.queenStomach`, the eating capture's state, the bomb's two arms, the
    shooting gate's $22, and her states $0D-$10. **Step 20b**: her stomach, states $08-$0B
    (the bent neck drawn by hand, the throw, thirty health for the bomb), and
    `queen_killFromStomach`, which state $0A reaches. **Step 20c**: her death, states $11-$13.
    The earthquake, the bitmasks and Samus's refill; `queen_disintegrate` ANDing her
    characters away a bitmask at a time, on WRAM shadows of BG3's copy and the objects' (BG2,
    her head, reads those), which NMI reads back during her delay and copies out a span a
    frame. Done in NMI as the Game Boy does, it overran her room's vblank by three lines. Also
    her body's cells to $FF a row a frame, both Metroid counts zeroed, the count's shuffle and
    the baby's cry. **Step 20d**: out of her room. `ESCAPE_QUEEN` and `EXIT_QUEEN` (door $19E,
    and $19F at a count of $00) clear rIE's LCD bit, kept as `!QueenStat`, which turns her
    channels off. They also put the status bar back. `ESCAPE_QUEEN` places Samus and the camera,
    and `EXIT_QUEEN` clears her room flag. The quake's end in her room asks for the baby's song
    (01:$7A13). Escaping alive is reachable down her bottom exit. **Step 21**: the baby
    (`enAI_babyMetroid`, 02:$7BE5) in bank 1: the egg's blink, wiggle and burst with Samus
    frozen, the rise, a hatched baby met again, the Zeta's chase, `baby_checkBlocks` eating
    tile $64 through `destroyBlock` with the mid probes keeping `metroid_babyTouchingTile`
    (and `enCollision_up.midMedium`, new), and `baby_keepOnscreen`. No warp row for it (James,
    2026-10-02): the cart reaches the egg from `47 QUEEN`, killing her and leaving left.
  - Graded by: the `queen` rung (1.0 Step 19b): her fight on her own, history for history our
    Game Boy's, with four of her routines taken out; and (19c) a missile volley into her head
    and open mouth, the play window on seven frames and her BGP bands line by line on four,
    with her hurt and her flash taken out; and (20a) `mouth`, with FULL LOADOUT: stunned,
    rolled into, bombed out of, 700 frames, with the bomb's arms, state $0F and the stomach's
    acid taken out; and (20b) `stomach`: swallowed, bombed in her stomach, thrown up her
    bent neck, 900 frames, with state $08 taken out; and (20c) `kill`, missiles to her death,
    3 250 frames, with ten play windows across the disintegration, her map's cells in VRAM
    and her death's length (596 frames, 100.00%), with her three death states, the copy out
    and the rows taken out; and `mouth_kill`, under ten health and bombed out of her mouth
    dying ($20), 3 320 frames, with the mouth's kill and `queen_killFromStomach` taken out;
    and (20d) `exit`, the kill then left out through `EXIT_QUEEN` into $F:$A9, and `escape`,
    the ball down her shaft and out through `ESCAPE_QUEEN` into $E:$C1, each graded to the
    arrival with its opcode taken out, and the quake's song taken out of `exit`. The
    recording's death is 596 frames too (part 23).
    The `warp` rung's `queen` scenario:
    warped to through the menu, Samus's position against our Game Boy's for 30 frames, and
    the play window pixel for pixel at three frames (objects aside), with `QueenApply`
    faulted out. `zig build queen` prints the Game Boy's bands. The `enemy AIs` rung's `baby`
    (1.0 Step 21): the egg in `$F:$A7`, hatched with Samus beside it and followed, 400 frames,
    faulted out of her range; and `baby block`: Samus walks left to the step at (10,4) and the
    baby eats its block at tick 194, graded on the map after the last tick (`tiles_end`),
    faulted to eat nothing.

- [x] **C5. Samus's remaining items and mechanics.** `F4`.
  - Phase: 1.
  - Status: **closed 2026-10-02, 1.0 Step 26.** Spikes were never ported until 1.0 Step 25
    (`SampleTile`'s arm, the `beams` rung's `spike`). Pickups for every item exist. **Hi-Jump, Space Jump and Spring Ball graded** (1.0
    Step 7): their branches were ported and needed nothing. **Screw Attack and Varia graded**
    (1.0 Step 9): the screw's kill by contact and Varia's halving by `beams` segments with her
    health, and Varia's fanfare wait and transformation ported and graded by `gfx`. **`loadGraphics` is ported** (1.0 Step 8a), with the gfxInfo records
    decoded from their callers, the Game Boy's chunk-a-vblank transfer, the pickups' tile swaps
    and `loadGame_samusItemGraphics`. Step 9 also found the knockback's
    direction after a walk's hit wrong, the pickup jingle's first pass missing, and the clock not
    ticking through a jingle; all three fixed.
    **The ice beam's thaw is ported** (1.0 Step 8b, `enemy_animateIce`), and every beam's damage
    is graded against an ordinary enemy. **The beams in flight are graded** (1.0 Step 8c): Wave
    and Plasma through walls, Spazer's three, and the Plasma at enemies, where no shot pierces
    and what outlives a kill flies on. The grade found the Plasma's three in the wrong slot
    order, fixed. **Standing on a frozen enemy is graded** (1.0 Step 8d), through its thaw and
    the contact after. It found the lift out of an enemy floor the ROM backwards and the landing
    snapping on an enemy, both fixed. **The refills** (1.0 Step 10): both are drawn and
    blink as the ROM's orb AI toggles them, which the OBP1 fix of Step 8b is what made visible;
    the missile refill's `metroidCountReal` test is ported, and at zero it takes the credits
    branch, held where mode $12 goes (1.0 Step 22).
  - Graded by: `loadout` (1.0 Step 7), a segment per item with the item set through the debug
    menu, frame for frame, each with its item's test faulted. `gfx` (1.0 Step 8a), twelve
    pickups against our Game Boy's: the object characters, the transfer's frames, the bit and
    the weapon and the pose, with three engine faults. `enemy AIs`' five beam cases (1.0 Step
    8b): the freeze, the thaw and the thaw's kill, the wave through a Ramulken's shield, the
    spazer's and plasma's kills and their missile drop, with the climb and the wave's shield test
    as behaviour faults. `beams` (1.0 Step 8c): each beam set through the debug menu and the
    projectile array frame for frame, into a wall and at a seeded enemy, with six engine faults;
    its `ice stand` segment (1.0 Step 8d) with three more. `warp`'s `refills` and
    `refill_credits` (1.0 Step 10): `$F:$10`'s refills drawn in their palettes' shades every
    frame and blinking, and `$F:$76`'s missile refill filling at a count and taking the credits
    branch at zero, faulted by OBP1 back at $84 and by the count's test removed.

- [~] **C6. The whole world.** `F2`, `F3`.
  - Phase: 1.
  - Status: **delivered and graded, 1.0 Step 26; re-graded on the committed crawler's crawl,
    release Step 0; named gaps open.** 290 of the recording's 953 cell-visits are not explained
    by the walked reading, each pinned by name in `src/worlds_misses.txt`. **Release Step 0:**
    every count below up to here was measured on a crawl cached before the crawler was
    committed (1058 doors; the committed one walks 1185). On the cold crawl the walked reading
    takes a room's first arrival, and leaves it to the static reading only when arrivals at two
    counts differ: 558 cells walked, 663 visits explained, 8 late-count visits accepted as
    losses. `verify-full`'s `crawl cold` rung holds the cache to a crawl from scratch
    (`docs/conformance.md`). The crawl's `through` ignores the respawning blocks
    (`bug_tracker.md`, diagnostic). The hand playthrough of every bank is 1.0 Step 27's. Before
    1.0: four of seven banks walked by a run. B12's nine cells fixed (Step 18c). **1.0 Step 18a:** every door script the cart can be asked to run (424
    of 512) runs on the cart and on our Game Boy, with the map over the view graded beside the
    loaded state, and every decodable script's operations are ones the interpreter handles
    (`ESCAPE_QUEEN`/`EXIT_QUEEN` since 1.0 Step 20d, when door $19E and $19F joined `doors`
    and `counts` holds the $00 threshold on both sides). **1.0 Step 18b:** the new game loads from
    `initialSaveFile`, as the Game Boy's does, rather than replaying door $D6 (its solidity). **1.0
    Step 18c:** the port boots a cell with what our Game Boy loaded walking into its room
    (`warp.assignWalked`, 484 cells): B12's nine fixed, 34 of 34 published-run cells agree; the
    recording's 953 cell-visits, 599 explained (502 before), every walked miss the lava's count.
    The rooms past the first lava wait on 18d: **18c2** tried a crawl per count band and
    reverted it (482 explained, not 599); the 354 misses are pinned in `src/worlds_misses.txt`.
    **1.0 Step 18d:** a walked lava room's table at the visit's count (`warp.LavaReplay`, 18c's
    walks replayed as scripts): 641 explained, the pin 312, 11 of them the lava. **1.0 Step
    18e:** a save round trip at each of the seven stations, in all five banks that have one:
    the loaded state against our Game Boy, the record against what she held, the load against
    the record, and the flags and the view. Two warp defects fixed on the way: `$A:$99`'s chain
    drew no pad, and `$E:$54`'s spot was beside it. Not graded: the save's own merge of the
    live flags, which only `$E:$55`'s buried Missile Tank needs (James's playtest).
  - Graded by: `oracle -- worlds` over the cells runs visit; the recording's worlds against
    their pin in `zig build verify-full`; the `doors` rung, and `warp`'s map; the `saves` rung;
    `warp_grade.cellsDrawn` (the walked cells on our Game Boy); `gbtrace -- <set> set worlds`
    (the recording's visits, through Mesen).

- [x] **C7. Ending and credits.** `F4`, `F5`.
  - Phase: 1.
  - Status: ported, 1.0 Step 22. Mode $12, `prepareCredits` (05:$587F): the fade, then the
    setup in one pass with NMI off for the Game Boy's 7 LCD-off frames. Mode $13,
    `creditsRoutine` (05:$55A3): the scroll, the row NMI draws, the clock, the stars and all
    22 of Samus's states, the four endings by `gameTimeHours`. `!DeathMode` carries both
    modes. The missile refill's zero-count branch enters it; so does the debug WARP page's
    ENDING. The soft reset (00:$02E1) is ported, in every mode and on the title. The Game
    Boy's 40-object buffer is kept: past it, the stars it writes on into WRAM are not shown.
  - Graded by: the `credits` rung, in `zig build verify-full` (six clocks, each side of 3, 5 and 7 hours, pass for pass
    against our Game Boy from the refill's lever: the fade's palettes, the characters, the
    scroll, the state, the objects every pass, the tilemap on six; the end held 600 passes
    and the soft reset to the title; 4 faults). The recording's best ending (part 25) is
    within 0.1% of our Game Boy's on the scroll and the last state.

- [x] **C8. The debug screen.** `F10`.
  - Phase: 1.
  - Status: **closed 2026-10-02, 1.0 Step 26.** That step put METROIDS and the WARP page's
    METROID ROOMS in playthrough order, numbered so: the 100% recording's kills
    (`debug_tables.playthrough`, James 2026-09-27). A unit test holds each to the record nearest
    its kill. The rungs that kill a Metroid from the menu name it by its record
    (`scenario`'s `met`). The pause it opens from is ported (1.0 Step 2a): `tryPausing` (00:$2C79) and game
    mode $08 (00:$2CED), with `debugFlag`'s arms ported to the fork where the original's menu
    (00:$2D39) begins. **The menu (Steps 2b-2d):** `DebugAllowed` in bank 1 is 1 on a cart
    built with `zig build rom -- --debug`. On such a cart L+R+Start, in any order, opens a
    menu in the manner of the Super Metroid practice hack at any point in play or the pause:
    the game frozen, changes applied as made, a tree (root: SAMUS, ROOM READOUT, CONTROLS),
    B back and closing at the root, the chord closing from anywhere. BG1 alone, with its own
    characters and map in free VRAM. `debugFlag` is never set; the GB's B+Select Queen warp
    (00:$0C8C) is not ported, by decision. Step 2b's title combination was dropped in 2d
    (James, 2026-09-27: order-sensitive, and the screen only opened from the pause).
    **Step 4:** METROIDS, FLAGS and CLOCK pages. The two lists are the ROM's saved-half spawn
    records, built by `debug_tables.zig` into the `debug` class. A kill is counted as `.death`
    counts one (flag, both counts, shuffle, `earthquakeCheck`); a Metroid or orb on the screen
    is taken off it. Flags are written where the game reads them: the save buffer always, and
    the live array and slot for the loaded bank.
    **Step 5a:** the warp table, built from the door crawl (`crawl.zig`: our GB walks Samus
    through every door and records what loads). 160 of 165 destinations have a chain and a
    standing spot (55 walked from the new game, 83 walked from a seeded room, 22 static);
    5 are findings (`docs/phase1.md`). Step 6 made her room the 161st, through door $19D. **Step 5b:** the WARP page (SHIP AND SAVES,
    ITEMS, METROID ROOMS, QUEEN) and `DebugWarp`: the chain run under forced blank,
    Samus on the spot, the room drawn as a boot draws it, and its enemies loaded
    by a sweep that stands in for the crossing's scroll. **Step 5c:** graded by the `warp`
    rung; two warp defects it found are fixed (a ball's hop on arrival, and a Metroid in a
    blank cell drawing the blank cell), and `warp_data` carries the camera's cell.
  - Graded by: the `pause` rung (codes 110-124), pass for pass against our Game Boy from a cold
    boot's new game, with eleven engine faults. Its combo run holds the chord on the retail
    cart, which only pauses and stays the Game Boy's; the debug cart's run opens the menu
    mid-walk with Samus frozen, walks the tree, closes it with B and with the chord, and
    checks the play field's VRAM is untouched (122-124). What each Samus-page field writes
    is graded by the `scenario` rung (1.0 Step 3): four scenarios, 31 edits through the menu's
    own input, each checked against the ROM's new-game record and the bit or value its pickup
    routine writes, with two engine faults (a row's wrong bit, the beam's weapon write).
    The tanks row's Right now fills at the fifth tank too, as `pickup_energyTank` does.
    Step 4's pages by three more scenarios (27 edits) against `.death` and `earthquakeCheck`
    read from the ROM, the quake then running, with three engine faults. The WARP page by the
    `warp` rung (1.0 Step 5c): all 160 entries against our Game Boy running each chain, and
    she stands; and the three Step 4 could not reach (a flag reset seen as a respawn, a
    Metroid killed live on the screen, a door drawing the new count's table after a menu
    kill), with the chains-cut fault and three engine faults.
    The `snes rom` rung builds the `--debug` cart twice and holds its one-byte difference.

- [~] **C9. Player-visible defects.**
  - Phase: 1.
  - Status: every open `bug_tracker.md` entry triaged on 2026-09-26 (1.0 Step 1) into *fix in
    step N*, *accepted compromise* or *diagnostic only*; each entry carries its line. **1.0
    Step 25** fixed the last *fix* entries: the hurt and acid palette, spikes, the pause's dim,
    and GAME OVER in her room. James accepted the `rLY` budget and the proboscum's camera dip
    (2026-10-02) and confirmed the fixes on hardware. **Open:** the 1.0 Step 27 playthrough's entries;
    its first, killed Metroids coming back (C2), fixed in Step 27a, and its second, a spike
    hurt carried through `C:3C`'s door into `F:C3`, fixed in Step 27b, each for his re-check.
    The rest open are diagnostic.
  - Graded by: each fix's fixture: `beams` 253 and `spike`, `snes boot` 149, `pause` 125,
    `queen`'s `still` 49 (1.0 Step 25), `warp`'s `missile_kill` (27a), `beams`' `door spike`
    (27b), and the steps' before it.

- [x] **C10. Reference recordings.** `F10`.
  - Phase: 1.
  - Status: the 100% run arrived 2026-09-28 as 25 segments. 1.0 Step 24a joined them into
    one run (`gbtrace -- <dir> set`): 485 325 frames, every seam exact, faithful end to end.
    Its kills, items and beams are tabled in `docs/phase1.md`. Step 24b censused its AIs:
    41 of 42, and it found the ROM census's one miss (Arachnus's fireball, now a child).
    Kill ticks, cells and durations are taken by the steps that grade them. **Closed
    2026-10-02, 1.0 Step 26:** no window of it joins the gate (James). It runs in `verify-full`
    (the worlds, and the best ending against the credits rung's reference), and its kill order
    is the debug menu's Metroid order (C8). The recording's beam and Varia frames as second
    references to `gfx` were dropped (James, 2026-10-02).
  - Graded by: `gb_trace.seam`; `enemy_oracle`'s census test holds `recorded_census_100`
    inside the ROM census and its children.

- [x] **C11. The 1.0 close.**
  - Phase: 1.
  - Status: **closed 2026-10-03.** The consolidation is done (1.0 Step 26). The hardware
    playthrough is 1.0 Step 27's: four defects logged (27a-27d), two fixed and re-checked on
    hardware, two accepted as the original's; James accepted the retail-built cart and its
    music and sound effects, 2026-10-03.
    The gate's time budget is set in `docs/phase1.md`, and `docs/conformance.md` measures it.
  - Graded by: the hardware playthrough.
