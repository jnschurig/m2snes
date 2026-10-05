---
created: 2026-09-02T16:14:27Z
updated:
  - 2026-09-02T16:14:27Z
  - 2026-09-02T16:31:05Z
  - 2026-09-02T17:43:35Z
  - 2026-09-03T22:48:28Z
  - 2026-09-04T04:59:04Z
  - 2026-09-05T20:01:48Z
  - 2026-09-07T05:14:04Z
  - 2026-09-07T16:04:09Z
  - 2026-09-07T21:25:04Z
  - 2026-09-08T02:04:52Z
  - 2026-09-08T04:28:21Z
  - 2026-09-08T18:35:16Z
  - 2026-09-08T18:38:45Z
  - 2026-09-08T21:13:44Z
  - 2026-09-08T21:39:32Z
  - 2026-09-09T00:56:04Z
  - 2026-09-09T02:43:35Z
  - 2026-09-09T14:26:06Z
  - 2026-09-09T15:30:38Z
  - 2026-09-09T17:33:11Z
  - 2026-09-09T17:38:52Z
  - 2026-09-09T19:05:00Z
  - 2026-09-09T21:30:13Z
  - 2026-09-10T02:24:13Z
  - 2026-09-10T04:22:41Z
  - 2026-09-12T04:23:02Z
  - 2026-09-12T06:05:00Z
  - 2026-09-13T01:02:08Z
  - 2026-09-14T03:51:53Z
  - 2026-09-14T15:29:48Z
  - 2026-09-14T16:41:47Z
  - 2026-09-14T18:49:31Z
  - 2026-09-14T20:38:24Z
  - 2026-09-14T22:29:12Z
  - 2026-09-15T01:23:43Z
  - 2026-09-15T02:47:43Z
  - 2026-09-15T04:00:54Z
  - 2026-09-15T14:31:17Z
  - 2026-09-15T17:39:05Z
  - 2026-09-15T21:03:02Z
  - 2026-09-16T01:07:38Z
  - 2026-09-16T03:59:49Z
  - 2026-09-16T14:03:15Z
  - 2026-09-16T18:25:22Z
  - 2026-09-24T19:38:07Z
  - 2026-09-24T21:34:32Z
  - 2026-09-24T23:46:26Z
  - 2026-09-25T00:38:03Z
  - 2026-09-25T00:50:50Z
  - 2026-09-25T03:13:59Z
  - 2026-09-25T03:48:00Z
  - 2026-09-25T14:21:06Z
  - 2026-09-25T16:13:16Z
  - 2026-09-25T18:35:11Z
  - 2026-09-25T20:26:33Z
  - 2026-09-25T20:49:43Z
  - 2026-09-25T20:50:19Z
  - 2026-09-25T22:04:50Z
  - 2026-09-25T22:21:46Z
  - 2026-09-25T23:04:38Z
  - 2026-09-26T01:30:24Z
working_directory: /Users/james/git/snes_game_dev
---

# Implementation Plan

## Status: Complete

> **Resuming? Go to Step 27, the hardware pass.** Step 26 closed 2026-09-26: the `recorded`
> rung grades the recording's first 2000 frames (493 of 1648, 11 of 11 stretches, 65 s), after
> two census defects that had limited every recorded sweep to a single 906-frame pass. Step 8's
> seeding fixture was asked on [10 000, 12 000) and still cannot answer: 22 of 26 anchors are
> unsettled on tileset assignment, so Step 8's box stays open. The gate is 9m12s.
>
> Earlier: Step 24i, the three save
> slots, closed 2026-09-25 on James's playtest (m2snes `32bccc0`). Step 24h closed 2026-09-25 on James's
> playtest. Step 24h landed 2026-09-25:
> the title's file select and clear on slot 0, graded by the new `title` rung against our Game
> Boy. Note `chr_obj` is at 92% of its region.
>
> Earlier: **Go to Step 24d (`snes boot` phase 7 exits 81 on some runs).** Step 24c closed 2026-09-25 in
> `m2snes` `d1f4a95`: the crossing's camera (00:$0B44) advances the spin counter `$D072` by 1 and
> the run cycle's `$D022` by 3 each frame, and the port did neither; `snes boot` phase 27 code 159
> guards it. Needs a playtest of a crossing in the ball or running. **Next is Step 24d**, phase 7's
> exit 81, which flakes at roughly 1 in 3 on fresh names and has to be fixed before Step 25.
>
> Step 24b closed
> 2026-09-24 in `m2snes` `e219e18`: a crossing's copies are queued for the next vblank instead
> of made under a forced blank held for the whole script, so a scrolling door shows the room.
> `snes boot` phase 28 codes 128/129 guard it, and the `fade` rung grades all 1999 frames. Needs a
> playtest of any scrolling door, an item door especially.
>
> Step 24 closed
> 2026-09-24 in `m2snes` `6af2b80`: `ITEM` now moves the orb and item characters, and the ball's A
> jump is gated on Spring Ball rather than the Bomb. Needs a playtest of the Bomb and Spider Ball
> orbs, and of A in the ball before and after Spring Ball.
>
> Step 23 closed 2026-09-24 with no cart change: Step 21 had already fixed the
> Missile Tank, whose tiles are `gfx_commonItems`; a ROM-backed unit test now links it to code 174.
>
> Step 22 closed 2026-09-24 in `m2snes`
> `9833f7a` and `94345f1`: the lava tables were in layout order where the ROM's pointer table says
> Empty/Full/Mid, and acid damage was ported at none of its six sites. See the step.
>
> Step 21 closed 2026-09-24 in `m2snes` `a4b7e73`: the missile door was drawn onto blank object
> characters, because the common item tiles never reached them.
>
> Before that: Step 20 closed 2026-09-16 in `m2snes`
> `a121f9c`: the fade door fades. The Game Boy scrolls a fade door too, **in the dark**
> (measured on door $1DF), so the camera was never the defect; the port now carries `bg_palette`
> and `fadeInTimer`, maps them to INIDISP brightness (our substitution), and the gate's
> thirty-second rung, `fade`, grades that brightness against the Game Boy frame for frame.
>
> Step 19 closed 2026-09-16 in
> `m2snes` `534fa57` and
> **ported nothing**: James played the cart and the Metroid stays, and the cart he played is byte
> for byte the one that carried the report — **Step 15a had already fixed it** (the saved flag
> half used to be carried across every bank with no `$04` → `$FE` translation, and the walk loads
> nothing below `$FE`, so a *seen* Metroid's flag stuck at `$04` through a door was gone
> forever). What the step built is the guard that was missing: **`enemy reload`, the gate's
> thirty-first rung**, six cases driving the camera off an enemy and back on both machines and
> comparing the *record's* return. Deleting that translation takes `alpha2 reset` from 134 of 134
> passes to 11, so the fixture fails against the defect it guards. Three things are inherited:
> a real **crossing**, a **cross-bank** one and a **save between the halves** are still
> unguarded and are written into the entry rather than the closed step; the lockstep harness
> **cannot** follow a crossing (the original's interpreter blocks for ninety frames); and
> `!SpawnReload` turned out to stand in for **two** Game Boy bytes, with the engine comment that
> claimed one routine raised both now corrected.
>
> Step 18 closed 2026-09-16 **by hand, not by a
> port**: James could not reproduce the dragged shot after Step 17 and asked for it marked fixed.
> No fixture, nothing ported, and `bug_tracker.md` says `Guarded by: playtest only` — the second
> entry in the file whose guard is a person.
>
> Step 16 and Step 17 closed 2026-09-16 in `m2snes` `06c7bef`. Step 16's box stays open on
> purpose: its fault-coverage half is Step 25. Step 17 restored `jsr DrawSamus` to
> `.transitionFrame` and moved `reachable` 1466 → 1999 of 1999, because `!OnscreenX` had been
> stale for every crossing — so the ratchet can now only go red.
>
> 15c closed 2026-09-15 in `m2snes` `8ffb0ca`: Samus dies. Every mode's length
> matches `src/death.zig`'s Game Boy measurement to the frame, graded by a new `death` rung on the
> shipped cart. The reboot goes through `Reset`, which also answers what 15b left open: the Game Boy's
> `bootRoutine` clears work RAM as well. Two findings. A Start held through the reboot left the
> cart's title, where the Game Boy's boot frame uses up that press; fixed. And the segment carts
> had been booting with zero health, harmless until a death existed; fixed in the fixture. 15d
> inherits: the rung reaches a death by writing health, not by damage.
>
> 15b closed 2026-09-15 in `m2snes` `5b4c936`: Start on the title loads
> slot 0, graded by the `load` rung. The load builds VRAM from the record's pointers, as the
> original does, rather than replaying a door script (agreed with James mid-step). It found a 15a
> defect, `COPY_DATA` storing a background source, now fixed. After a load the save text has the
> item font's characters; on a new game it still does not (unmeasured what the Game Boy shows).
> 15c inherits: the load assumes a cold boot's cleared WRAM, and a death returns to the title
> without one.
>
> 15a closed 2026-09-15: the cart saves, byte for byte the Game Boy's layout, graded by `snes boot`
> phase 26.
>
> Earlier: On 2026-09-15 Step 15 was split into
> 15a–15d with James's agreement: the cart could not reach a station, save, die or reload, and
> Samus's death is now in B7 (requirements amended the same day).
>
> Step 14b closed 2026-09-15 in `m2snes` `fd07635`:
> Spider Ball works and is graded by a new `spider segment` verify rung (847 frames against the
> Game Boy) and `snes boot` phase 25. Two defects came out of it: the Down arms into the spider
> tested Spring Ball's bit, and pose `$12` was running `$11`'s handler. The recorded rung could not
> grade the recording's spider route (its anchors boot a cell on the wrong table), so a segment
> replaced it.
>
> Step 14 closed 2026-09-15 in three `m2snes`
> commits (`b6ad829`, `4cdddec`, `64e1950`). **The headline is a correction:** `IF_MET_LESS` is
> taken at or *below* its operand (00:$254A), so the `$46` gate opens on the **first** kill, not
> the second. That was the playtest's acid room: the engine never branched. The first kill also
> starts the only earthquake in the slice; the second leaves `$45`, which is not a threshold.
> Also added: a latched room readout (L+R) for playtests. One open bug tracker entry came out of
> it: phase 16's drop check is sensitive to boot length.
>
> On 2026-09-15 a playtest added two things: Step 14 gained the acid room and a latched room
> readout, and a new **Step 14b** ports Spider Ball, which Step 11 had deferred and the route to
> the second Alpha needs.
>
> 13d closed 2026-09-14: both Alphas die, graded against the Game
> Boy by two kill cases at the recording's own shot ticks (`zig build gbtrace -- kills`) through
> the explosion and the post-death timer, and on the cart by `snes boot` phase 22. Step 14
> inherits `!QuakeAsked`, the recorder standing where `earthquakeCheck` is called, and the
> finding that a transition during the post-death wait leaves the timer part-way.
>
> 13c closed 2026-09-14: both Alpha AIs are ported but for
> `.death`, graded in five enemy-oracle rooms and `snes boot` phase 21. Two things 13d inherits:
> the hurt's `rDIV` coin is handed from the Game Boy to the cart in the oracle (`enemy_oracle.Coin`),
> so a kill case needs its coins too; and `enemyHandler`'s mid-fight transition clear (02:$4000)
> was left with the music restore.
>
> 13b closed 2026-09-14: BG2 is the Game Boy's window, the status
> bar runs in NMI on the vblanks the original's handler reaches it, and `zig build verify`'s new
> `status bar` rung grades it tile for tile against our Game Boy and against three frames of
> Mesen2's. A playtest will see one known divergence: during a major item's jingle the icon rises
> and the band does not (the window raise is still B6's recording).
>
> Step 13 was split into 13a–13d on 2026-09-14 after a playtest
> found missiles fire nothing and the HUD band is empty. 13a closed the same day: boot record
> version 11 carries the loadout, the Select toggle swaps the cannon and spends its frame, and
> `snes boot` phase 19 grades both. Step 12c closed on 2026-09-14: the bombs are ported and
> `snes boot` phase 18 grades them through the fire button. The step group's steps are listed
> in the order they were created, not run (12a, 12b, 12d, 12e, 12f, 12c). 12f closed on
> 2026-09-13: every AI James's recording dispatches is ported except the two Alphas (Step 13),
> each graded against the Game Boy by `zig build oracle -- enemies` in a room it lives in. It
> left two open camera/loader findings in `docs/bug_tracker.md` that the next AI or room may run
> into.
>
> **Step 12e landed 2026-09-12 and reversed one of its own approved decisions.** The `rDIV`
> substitution was approved as `!FrameCount`'s low bit; at the call site that bit is a constant,
> because the enemy pass acts on one frame parity only — measured on the cart over 1000 frames of
> the boot room, not argued from the listing — so every corpse in a room would have rolled the same
> way. The roll reads `!EnFrame` instead, and `snes boot` now has a rung that fails if that counter
> stops alternating. The sub-task carries the amendment.
>
> Step 8's top-level box is unchecked and will stay that way for a
> while: its two open sub-tasks are the stitch, which was measured and deliberately dropped, and
> the pristine-tilemap fault fixture, which cannot show a difference until the port can play the
> region it grades — it is waiting on Steps 9–13, not on more machinery. Steps 9, 10, 11, 12a, 12b,
> 12d and 12e are done, and `zig build verify` is green (`reachable` **1466** of 1466, moved by
> 12b's second commit and unmoved by everything since — correctly: no published run kills anything
> inside its horizon and the oracle segment contains no kill either). Step 12a's terrain half moved no rung and could not; 12b's first commit
> moved none either, deliberately, and its second moved reachable 1396 to 1466 by handing the
> movie's `B` to the cart and changing nothing else. `docs/bug_tracker.md` in
> `~/git/m2snes` carries **one open entry**, and it does not block the gate: the cart registers
> the Senjoo's contact one tick before the Game Boy does, which is what holds the oracle segment
> at 700 frames instead of the 703 that would grade the hit. That entry has the measurement
> written out; it belongs to the contact test. **Step 12b did not close it and could not**: its
> two new phases both fire at things the fixture places, so neither of them is about an enemy
> touching Samus. It is still open and Step 13 is now the natural place for it.

## Overview

Build the playable slice in the order the port's own measurements demand: make the gate's numbers
exact before anything moves them, extend the porting loop to mechanisms, get the tileset
assignment honest, then land room transitions — the mechanism the reachable count actually stops
on — and the title-to-game path that makes hand playtesting the loop for everything after it.
Entities, items, combat, the Metroid chain and save/load follow in dependency order, each with a
rung or fixture that fails when it is removed, closing on a recorded hardware pass.

All paths are relative to `~/git/m2snes`.

**Four facts this plan is built around. The first two were measured by the planning spike on
2026-09-02; the third was measured on 2026-09-03, when the recording arrived; the fourth was
raised by James on 2026-09-08 and checked against the ROM the same day.**

1. **The slice does not fit inside the any% replay horizon.** Regenerating the `vblank0` trace to
   8500 frames shows `metroid_count_real` (`$D089`) holding at `$47` from frame 6 until the
   replay collapses at 8442. **No Metroid is killed inside the horizon — not the second Alpha,
   not the first.** The geography *is* covered: the run visits map banks `$0F`, `$0A`, `$0C` and
   `$0B` before 8407, so Steps 4–7 keep their published-TAS grading. Everything from Step 9
   onward does not. **B11's recorded run is therefore the primary grader for Steps 10–14, not a
   supplement**, and Step 8 is a hard prerequisite of Step 9 rather than a convenience.
2. **The segment's own cell carries an enemy.** The segment origin is movie frame 326 at map bank
   `$0F`, cell `$76`, whose spawn list is one record — spawn 15, type `$9D`, at (`$38`, `$B8`).
   So Step 9 is expected to move the segment rung rather than leave it unmoved, which is the
   opposite of what a first draft of this plan asserted.
3. **The recording cannot be graded by replaying it on our Game Boy emulator, and Step 8 is
   rewritten because of it.** James delivered the B11 run on 2026-09-03 as a 76 951-frame Mesen2
   movie that saves several times, dies and reloads, collects Bomb, an Energy Tank, a Missile
   Tank and Spider Ball, and kills two Metroids — a superset of what B11 asked for. Converted to
   a VBM and replayed here it stops being his run at **28 796** frames, before his first save,
   and sixteen combinations of frame source and input offset give one outcome. That is the same
   limit the published runs hit at 8407 and 4566. **So Mesen2 replays it and Step 8 takes a
   trace**, which the anchored machinery then grades against by re-anchoring — nothing has to
   replay 76 950 frames. Two Step 1 decisions moved with it: Spider Ball is in the region rather
   than deferred, and B7 gets the load path free.

4. **The recording changes the shape of the rooms it plays, and the plan had no step for that.**
   James: the recorded run will stop grading on the **third screen**, because Samus shoots out
   the tiles blocking her descent and the port cannot. The ROM agrees and is specific: 01:$5155
   filters a projectile's tile by `beamSolidityIndex`, treats ids `$00`–`$03` as hardcoded
   respawning blocks, and otherwise tests bit 5 of the collision byte; `destroyBlock` writes
   `$FF` into the tilemap and `handleRespawningBlocks` brings it back. **Collision is a tilemap
   read, so a destroyed block is a change to the world's geometry**, and B5 only ever asked
   projectiles to *collide* with terrain. Two consequences, both taken: an anchor in Step 8 now
   restores the tilemap and the block slots as well as Samus, and the destruction machinery
   becomes **Step 12a**, ahead of the projectiles that trigger it.

**B4 is split across Steps 9, 10 and 13** — the entity foundation, enemy AI and damage, and the
Alpha kill — because the Alpha's death needs projectiles from Step 12b. A reader tracking B4 will
not find it closed at Step 10.

## Steps

- [x] **Step 1: Scope the slice — the region, the poses, and the deferrals**
  - [x] Walk the map from the landing site to the second Alpha Metroid using `src/map.zig` and
        `src/door.zig`, and write `docs/slice.md`: the map banks and cells in the region, the
        doors between them, and the minimum room traversal a hardware pass has to cover
  - [x] Record the spike's horizon finding in `docs/slice.md` with the measurement that produced
        it, so the decision to lean on B11 is traceable rather than remembered
  - [x] Locate a normal save station inside the region, or name the nearest one and the cost of
        growing the region to include it (B7 requires one that is not the ship)
  - [x] Enumerate the poses the slice actually reaches, by walking the trace's pose column across
        the region's banks. This is the list Step 11's tests are enforced against
  - [x] Record, as decisions rather than assumptions: whether an elevator/area-change sequence
        falls in the region; whether a lava/acid drain is reachable; whether spider ball is
        reachable; which of `duration.zig`'s 25 unmatched-world stretches sit in the region;
        which of `dispatch.unreached`'s five bank-4 sites fall inside it. Each gets in-scope or
        deferred-with-reason
  - [x] Ask James to record the B11 VBM now. It is on the critical path for Steps 9–14, not a
        supplement, and `docs/slice.md` states what it must cover: the whole slice through the
        second Alpha kill, and a save-station visit
  - [x] Verification: `docs/slice.md` is committed, and every question in this step has an
        answer with the measurement or the file that produced it

- [x] **Step 2: B9 — the floors become exact frames**
  - [x] Generalise the `refine` block in `gradeMovie`/`gradeRef` (`src/oracle.zig:2362`) into a
        bisection over reference length: truncate to N frames, run, and bisect on match/no-match
        until the exact divergence frame is pinned. It replaces the current single re-run, which
        only resolves divergences inside the first `codes_per_quantity` frames
  - [x] Confirm whether the segment rung shares `gradeRef`. If it does not, either extend the
        bisection to it or record that the segment keeps bucket reporting and why — Step 10
        lengthens the segment, which widens those buckets
  - [x] Report the exact frame on `Report`, and make `reachedFrames` return it when present, so
        the anchored sum is exact and not just the headline rung
  - [x] Re-measure `movie_gate_floor` and `anchored_gate_floor` as exact frames, and rewrite both
        doc comments: the bucket-edge caveats become history, and the new numbers record that
        they moved because the measurement got exact, not because the port changed. **Both are
        expected to rise**, since a bucket's bottom edge understates
  - [x] Add a test asserting the property directly: the reported floor is unchanged across two
        different values of `codes_per_quantity`
  - [x] Measure the cost — wall-clock for the reachable rung and for a full anchored sweep with
        bisection on. If the sweep is too slow for the gate, apply bisection to the headline
        reachable rung only and gate the rest behind `zig build oracle -- anchored exact`, and
        record the timing that drove that choice in the doc comment
  - [x] Fix the open `docs/bug_tracker.md` item where `zig build test` prints `failed command:`
        lines while every test passes. Seventeen steps of verification run through that command,
        and the tracker already records three real failures being misread as pre-existing noise.
        Route `src/locate.zig:430` and `:465` through the test's own writer
  - [x] Verification: `zig build test` is quiet and green; `zig build verify` green; the two
        floors are exact frames and the new test passes
  - **Measured 2026-09-05, where the step's expectations were wrong.** `movie_gate_floor` did
    **not** rise: the exact divergence is frame 375 and the bucket's bottom edge at
    `want` 900 was also 375, so the two coincided. `anchored_gate_floor` rose **390 → 394**,
    which is where the understatement was real — nine bucket edges summed. The pin costs three
    extra emulator runs on the reachable rung (1.6s → 4.9s) and eight seconds on the anchored
    sweep (7.6s → 15.8s), inside a `zig build verify` of 130s, so **no rung was gated behind
    `oracle -- anchored exact`** — the gate and the CLI both pin by default and `bucket`
    reproduces the old number. The property test varies `per_code`, which is what
    `codes_per_quantity` actually controls, rather than `codes_per_quantity` itself: it is a
    `pub const`, and the emulator measurement at four values of `want` is the second half of
    the same check. The segment rung does **not** share `gradeRef`; `pinExact` was factored out
    and `grade` calls it too, so the segment is pinned rather than left on buckets for Step 10
    to widen.

- [x] **Step 3: B3 — the porting loop's second arm, and the feature tracker**
  - [x] Write `docs/porting_loop.md`: the pose arm carried over from the Phase 0a plan, with its
        step 1 rewritten to use Step 2's bisection rather than the `emu.stop(20 + (i % 200))`
        workaround, plus a second arm for mechanisms — how to find the mechanism the count named,
        how to disassemble a multi-routine mechanism, the order to port it in, and what evidence
        closes one turn
  - [x] The mechanism arm names its own artefacts: `ledger.zig` rows per routine, `residue.zig`
        entries per new variable, at least one rung or fixture that fails when the mechanism is
        removed, an update to the feature tracker below, and the before/after reachable count
  - [x] **State the standing rule here, where it can govern from Step 4 onward rather than being
        audited into existence at the end: every defect found by hand gets a failing fixture
        before it is fixed, and the fixture is shown failing against the unfixed engine.** Step 16
        audits compliance; it cannot create it retroactively
  - [x] Add `docs/feature_tracker.md`, a documentation artifact in the same spirit as
        `docs/bug_tracker.md` and following its conventions: a preamble stating what the markers
        mean, then one entry per feature with a `- [ ]` / `- [x]` marker and dated closures.
        **Deliberately not a code artifact.** `dispatch.unreached` and `coverage.zig` are Zig
        tables because they are measurements derived from the ROM; a feature's phase and status
        are planning state, which is what the bug tracker already keeps in markdown
  - [x] Each entry carries: the feature id and name, the phase it is planned for (`0a`/`0b`/`0c`/
        `1`), its status, the rung or fixture that grades it once it is closed, and a reason for
        anything deferred — as nested bullets, the way a bug entry carries `Cause:` and
        `Guarded by:`
  - [x] Seed it with the whole game's feature set, not just this cycle's, so the slice's features
        are visibly a subset of the port. **This is the artifact Phase 1 inherits** — Phase 1
        opens by reading the unchecked entries rather than re-deriving them
  - [x] **F8's entry carries the shim cycle's measured state rather than its original plan
        (added 2026-09-05).** The GB-APU→SPC700 shim finished 2026-09-04 in `snes_game_dev`, not
        here, with a GO-WITH-CAVEATS: two pulse channels exact against the model and good by ear
        on an FXPak, ARAM under 15%, CPU at 57.0% on the gameplay track against a 50% budget,
        and a stated condition that four-channel work waits on re-measuring after the
        unconditional `sequencer_tick` DSP push is made conditional. The entry cites
        `.local/docs/2026-09-01-gb-apu-spc700-shim/04-verdict.md` by path, names the repo the
        code is in, and records the **open** decision — shim vs. TAD transcription — as open,
        because that verdict explicitly declined to make it. This is the one place Phase 0c can
        read it from without re-deriving the numbers
  - [x] Maintained by the same discipline the bug tracker is: no automated validation, and Step
        16's audit is a documentation review rather than a build check. That is the trade for
        keeping planning state out of the source tree
  - [x] Commit this before Step 4, which is the first step it governs
  - [x] Verification: `docs/feature_tracker.md` is committed and every B-numbered feature in
        `01-requirements.md` has an entry; `zig build verify` still passes the ledger's
        instruction-boundary check

    - **Found while writing it, 2026-09-05: the carried-over loop's frame arithmetic was
      wrong.** The Phase 0a text says "movie frame = reference frame + 326", which is the
      *segment's* origin. The movie rung's origin is the handover **pushed past the room change
      that straddles it** — 328 — so the count's stop at reference frame 375 is movie frame
      **703, the transition frame itself**, where the map bank goes `$0F` to `$0A` and Samus is
      re-placed from `$07F3`,`$0784` to `$03F3`,`$0484`. The carried-over note called it
      "reference frame 377" and B1's own status inherited that. Corrected in
      `docs/porting_loop.md` (which now says to read the rung's printed anchor rather than carry
      a constant) and in the tracker's B1 entry. **It changes B1's reading of itself**: the port
      holds Samus motionless for all 95 frames of the original's hold and then has no crossing at
      all, rather than losing the last two frames of the approach. The 0a plan's copy is left as
      written — it is a finished cycle's record.

- [x] **Step 4: B12 — tileset assignment graded against the running game**
  - [x] Sweep `compareWorlds` (`src/oracle.zig:557`) across cells rather than anchors: for each
        cell the observation can reach, compare `screens.assign`'s chosen table against the table
        that best explains the running Game Boy's tiles. Drive it from a new
        `zig build oracle -- worlds` subcommand
  - [x] The sweep's report names, per disagreement, both tables, the tile counts, and the
        `screens.Provenance` and distance — the shape `oracle -- settle` prints today
  - [x] Fix map 3 cells `$51` and `$71`, where table 4 explains 399 of 399 tiles against the
        assigned table 9. Decide per-cell override vs. retuning `assign`'s nearest-warp-target
        inference on what the sweep finds across all reachable cells, not on these two
  - [x] Diagnose map 2 cell `$0D`'s empty comparison window (`windowMask` selects no slot inside
        the boot cell) and either fix it or record what it turned out to be
  - [x] Anchored stretches 4 and 8 become gradable — that is the check the correction is real.
        Re-measure `anchored_gate_floor` and note the two newly gradable stretches
  - [x] Restate the render rung's claim in `src/verify.zig` and `src/snes_render.zig`: it checks
        the conversion through a shared table, not the assignment. The output text changes so
        "904 screens match pixel for pixel" cannot be read as validating the assignment again
  - [x] Verification: `zig build verify` green; the anchored rung reports 11 gradable stretches
        where it reported 9; a test pins the corrected table for `$51` and `$71`

    - **What the sweep found, and where the step's model of the problem was wrong.** The step
      expected two rogue cells and a nearest-warp-target rule that needed retuning. The sweep
      reaches **34 cells** across both published runs and found **15 disagreeing**, in four
      clusters, none of them explained by distance — map 1 `$44`–`$48` inherit correctly at
      distances 1 to 5, and map 3 `$21` is wrong at distance 0. Two candidate retunes were
      implemented and measured before either was believed: spreading through unblocked scroll
      edges first covers almost nothing (239 fragments, 36 with a warp target), and the fix that
      worked is a **door-inheritance pass** — a script that names no table leaves the previous
      room's loaded, so its target inherits the source room's whole `Choice`. **19 → 24 cells
      agreeing, none regressing.**
    - **The first version of that pass was wrong and a fault sweep caught it.** Seeding the
      table-less door's *own* index as the `door_index` drew 400 screens through a script that
      writes no tiles; `metatile_quadrants` fell from disturbing 828 screens to 428, because a
      fault in a tile nothing draws is invisible. Carrying the source's whole choice fixed it and
      the sweep came back stronger than before (831). That failure is why `collapsedPairs` now
      exists as a standing check.
    - **`$51` and `$71` were fixed by the retune, so no per-cell override was written.** The
      decision the step left open is answered against the sweep: an override table would have
      hidden a systematic error behind two rows.
    - **The empty comparison window was not `windowMask`.** Map 2 cell `$0D` compares 399 tiles,
      not zero. `settleAnchors` kept the best world with `w.matched > old.matched`, which can
      never fire when every candidate matches zero tiles — so the zero-initialised default was
      printed, cart table and all. Fixed, and the report now names the frame and the four numbers
      the window is derived from when it really is empty.
    - **The remaining nine disagreements are not fixable from the door table**, and that is the
      finding this step actually produced: no door in bank `$B` states table 6, and the Game Boy
      showed table 6 on all 399 compared tiles of map 2 `$0D`. The Game Boy treats the metatile
      table as **loaded state, not a property of a cell** — which the port models per cell. Both
      recorded in `docs/bug_tracker.md`; the model question is Phase 1's.
    - **The pass is vetoed in banks `$9` and `$A`**, where it takes collapsed metatile pairs from
      0 to 49 and 0 to 100. That veto is a proxy standing in where no run can grade — bank `$9`
      is unreached, and bank `$A`'s reached cells grade identically either way — so it is filed
      as a bug entry to be re-decided against B11's recording rather than left as a silent rule.
    - **Rungs that moved for a reason next door to them:** `durations` 15 → 17 compared and
      11 → 13 agreeing, screens drawing from VRAM no door wrote 72 → 44, and the anchored rung's
      offered frames 5174 → 6848 with the **sum unchanged at 394** — which is why
      `anchored_gradable_floor` was added, since the sum alone would have recorded this step as
      nothing happening.

- [x] **Step 5: B1a — the door-driven transition: WARP, the map bank, and the camera's re-seat**

  **Rescoped 2026-09-07, mid-step, on a measurement.** The step as written assumed the trigger
  and the transition's duration could land separately with the gate green in between. They
  cannot: wired in, the trigger fires on reference frame 281 — which is exactly where the
  original fires it — and then finishes in one frame what the original takes 94 frames to do,
  taking the reachable rung from 375 to 281. Those 94 frames are not a hold that can be counted
  out. They are Game Boy VRAM bandwidth: the interpreter waits a frame per opcode (00:$26D1),
  `FADEOUT` fades to black over ~38 clocked by a counter the vblank handler decrements once a
  frame (00:$0172), and every `COPY` waits at 00:$27BA for a queue that drains **64 bytes per
  vblank**. So this step keeps the transition's *state* and the new **Step 5b** takes its
  *duration*; `TransArmed` in `engine/main.asm` is the one byte between them. Both findings are
  in `docs/bug_tracker.md` under 2026-09-07, and `docs/porting_loop.md`'s arm two gained a step
  5a from it.

  - [x] Port `handleWarp` (00:$28FB — the plan said $294F, which is the body of one of its four
        arms) branch for branch, with the original's address in each comment, including the
        branches Phase 0a cannot reach. **The header is ported: the map bank out of the opcode's
        low nibble, and the destination cell's two nibbles into the screen halves of both the
        camera and Samus. The four arms it dispatches to on $D00E are draw arrangements, and they
        go to Step 6 with the streaming they exist for**
  - [x] Extend the engine's script interpreter (`RunBootScript`, `engine/main.asm:1354`) from a
        boot-only walker to a transition executor: `WARP` ($4x) changes `!MapIndex` and `!Cell`
        and seeds the position; `DAMAGE`, `SONG`, `ITEM` and `IF_MET_LESS` get stubs that record
        rather than silently skipping by length. Rename it for what it now does. **`SONG`'s stub
        records the original's song id and stops there (2026-09-05)** — no driver call, no track
        table, no ARAM layout — because Phase 0c's path is an open decision the shim cycle
        declined to make, and a stub that assumes either one is the expensive thing to unpick
  - [x] Implement the camera's re-seat: which of the transition handler's four camera
        arrangements runs is a property of the door, so `BootCamX`/`BootCamY`'s measured seeding
        stops being the only source of a camera and becomes the frame-0 fixture it was meant to
        be. `residue.zig` gets the new variables
  - [x] **Keep the existing rungs green across that change, as its own sub-task.** The segment,
        reachable and anchored rungs all boot through the record this step is rewriting. Run all
        three before and after; if any goes red, that is a finding to be understood before it is
        a refactor to be finished, and it lands in `docs/bug_tracker.md` with a failing fixture
        per the Step 3 rule.
        **Two went red and both are understood.** (1) The boot door script's own `WARP` now
        executes and overwrote the record — fixed by `SeedPlacement`, which applies the record
        *after* the script, because the record is a fixture reproducing a mid-run handover and
        the script is replayed for what it puts in VRAM. (2) The trigger without the duration,
        above. `SeedPlacement` also loads the cell's scroll flags at boot, which nothing did:
        **`anchored_gate_floor` 394 → 445**, all of it stretch 6, whose anchor cell blocks three
        edges of four and which used to boot with all of them open
  - [x] Add the door-trigger path that actually starts a transition — the `!CAM_MAX_X` clamp in
        `HandleCamera` is where the original triggers, and the port currently only settles back
  - [x] `ledger.zig` rows for every routine ported; `zig build verify`'s instruction-boundary
        check decides which rows survive. Update `docs/feature_tracker.md`
  - [x] Verification: **the cart** drives one horizontal transition end to end and asserts the
        map bank changed and the camera landed where the Game Boy's did; it fails with the
        re-seat removed. A phase of `snes boot` rather than a `room.zig` scenario, and for a
        reason worth keeping: with the trigger disarmed the transition has to be *driven*, and
        the SNES lever is writing `!DoorIndex` — which is the same lever `room.spawn` already
        pulls on the Game Boy by calling `warp_handler` directly. The assertion is the Game Boy's
        own rule and not ours: the screen halves become the warp's and **every pixel half is the
        one it had**, which is what 00:$2909-$2912 does and what the movie's crossing from
        $07F3,$0784 to $03F3,$0484 shows. Fault-injected: with `sta !CamX` removed from the warp
        the gate fails and names the transition
  - [x] Two findings closed on the way: `room.zig`'s `Direction` enum had three of four values
        misnamed (1 is right, 2 left, 4 up, 8 down), and `snes_screen.ram` — the addresses the
        cart gate reads — was a hand mirror of the engine that nothing checked. It is checked
        against the `Var*` symbols now

- [x] **Step 5b: B1a2 — the transition's duration becomes a computed quantity**

  **New, 2026-09-07, split out of Step 5 on a measurement — see Step 5's own note.** The port
  cannot fire a door trigger until a transition takes the frames the original's takes, and those
  frames are not a hold. They are the Game Boy's own vblank arithmetic, which means the port has
  to reproduce the *rule* rather than the number — the way it reproduces every other quantity
  here — and the rule has to be graded against the Game Boy across more doors than the one this
  was found on.

  **Done and verified 2026-09-07.** `zig build verify` green end to end; **reachable 375 → 420**,
  **anchored 445 → 462**, **durations 17/13 → 19/17**, and `zig build trace -- stretch 0 372 18`
  reports "no divergence: every frame matched" across the warp, the five held frames after it and
  the incoming scroll.

  - [x] Measure it before modelling it. Drive several doors through the original's interpreter on
        the Game Boy harness and record, per frame, which opcode is executing and what it is
        waiting for. **One door is one data point**, and the one in hand (bank $0F cell $77, door
        $01DF, 94 frames) is not enough to fit a constant to. The measurement lands in
        `docs/slice.md` beside B11's.
        **Done:** `src/transition.zig`'s `measure` times every opcode by watching 00:$23E1 and
        counting at the *vblank vector* rather than the LCD's frame counter (the two are a frame
        apart depending on where in the frame the interpreter was entered). The sample is a
        stride for breadth plus, for every opcode the ROM's 512 scripts contain, the first door
        that contains it — and the test fails if any reachable opcode went unrun. **160 of 160
        scripts agree, in all four directions.** Two findings came straight out of it: `TILETABLE`
        is a screen redraw (00:$2856 is `JP $2918`, into the warp handler), and `docs/bug_tracker.md`'s
        hand transcription of door $01DF was wrong — eight opcodes, not seven
  - [x] Port the frame costs, each from its own routine and with the original's address in the
        comment: the interpreter's per-opcode wait (00:$26D1) and its entry wait (00:$23AF);
        `FADEOUT`'s four frames plus its three-step fade to black, clocked by a counter the
        vblank handler decrements once a frame (00:$2561, 00:$0172); and the copy wait at
        00:$27BA, whose duration is a queue draining **64 bytes per vblank**. The port transfers
        at SNES speed and waits out the Game Boy's cost, rather than throttling its own DMA —
        state the choice in the engine comment so the alternative is on the record.
        **Done:** `OpExtraFrames` is the static half and `.copy`/`WarpWaits` the runtime half;
        `RunDoorScript` split into `StartDoorScript` and `StepDoorScript` so the interpreter is
        re-enterable a frame at a time, with `RunPendingTransition` as the pacer. A test reads
        `OpExtraFrames` back out of the assembled image and checks it against `transition.zig`
  - [x] Port the in-transition camera, 00:$0B44: while `!TransDir` is set the pose machine does
        not run (00:$0522), the streamer and the camera still do (00:$053E, $0541), and the
        camera scrolls 4 px a frame carrying Samus 1 px a frame until its pixel byte reaches the
        far clamp — then 00:$0C24 clears the direction and the transition is over.
        **Done**, all four arms, including the down arm's four strips where the others draw three
  - [x] Flip `TransArmed` to `$01` and re-measure every floor in the same commit, each recording
        that this is why. **The stop condition is the reachable rung passing 375 on a real
        transition rather than returning to it**; if it stops at 375 again, the duration model is
        wrong and the measurement above says where.
        **It stopped at 375 again, and the measurement did say where** — three off-by-ones at the
        model's seams and a boot defect, all four in `docs/bug_tracker.md`: the entry wait sharing
        a frame with the first opcode, a split `spr` transfer charging two dispatch frames for one
        Game Boy opcode, the `END` frame belonging to the interpreter rather than the main loop,
        and a cart booting with `!SprX`/`!SprY` at zero — which reads as "hard left" to two of the
        four triggers and fired a transition on frame zero
  - [x] Verification: the reachable rung past 375 with an exact frame; `snes boot`'s transition
        phase still green through the armed path; a fixture that fails when the copy wait is
        removed, shown failing first.
        **Done:** reachable 420, exact. `snes boot`'s transition phase gained a second assertion —
        the crossing has to take the frames a Game Boy would spend on that script, `TRANS_FRAMES`
        computed by `transition.zig` — and it is the fixture the copy wait fails against

- [x] **Step 6: B1b — streaming the incoming screen, and the two duration defects**

  **Done and verified 2026-09-07.** `zig build verify` green end to end. **Reachable 420 → 1396**
  (899 of the 899 frames the old window offered, so the window was raised 900 → 2000),
  **anchored 462 → 665**, **durations 19/17 → 28/28** — every stretch that can be compared now
  agrees, which this rung has never managed before.

  **The step's premise was half wrong and the measurement said so.** Sub-task 1 assumed the
  incoming screen arrives by a tilemap `COPY` that the port had to make land in `!TilemapBuf`.
  **No door script in this ROM carries a tilemap `COPY`.** A room arrives entirely through
  `handleWarp`'s strips and the per-frame streamer, so the work was the strips — and the two
  defects that were hiding behind them.

  - [x] Stream and draw the incoming screen before control returns. `WarpDraw` is
        `handleWarp`'s four draw arrangements (00:$2918): three metatile strips going right,
        left and up, four going down, each one `StreamRun`, with the waits Step 5b already had
        between them. `TILETABLE` reaches the same dispatch because 00:$2856 is `JP $2918`
  - [x] Assert `!TilemapBuf` holds the same tiles the Game Boy's background map holds for the
        room on the far side. `snes boot`'s transition phase, code **137**: the cells the arm
        can reach are baked out of the ROM by `oracle.expandCell` — the same expansion
        `compareWorlds` grades a boot against — and the *addressing* is done on the emulator
        side against the camera the cart reports, because the crossing happens seven phases into
        the run and not at the boot record's camera. Fault-injected: with `.column` and `.row`
        returning immediately the gate fails and names the transition
  - [x] **Keep the existing rungs green across the streaming change.** All green, and three
        floors raised rather than held
  - [x] Fix the duration defects. **The leftward 1-vs-21 pair was already closed by Step 5b**
        (turn log, 2026-09-07) and was re-confirmed rather than re-fixed. The two that held
        47–48 against the Game Boy's 1 — `scroll 2563` and `scroll 3316` — **were never about
        durations**: a cart booted from a mid-run record put one screen's tilemap in all 1024
        slots, so the far side of every screen boundary was the boot screen's own edge and she
        walked into a wall the original does not have. `SeedWindow` reconstructs the window the
        original actually has. The failing fixture was the durations rung itself, which had been
        printing both rows as `DIFFERS` since 2026-09-01; the mechanism behind them was measured
        first, with a new instrument (`zig build trace -- at F`), and recorded in
        `docs/bug_tracker.md` before anything was changed
  - [x] Exercise a vertical transition as well as a horizontal one, per D2. Phase 8 drives the
        same door twice — once rightward, once downward — and the downward arm's **fourth**
        strip is graded, which is the one difference between the arms
  - [x] Re-measure the `durations` rung's floors and record the new numbers: **28 compared, 28
        agreeing**, up from 19 and 17. Nine stretches became comparable that used to leave the
        run within a frame or two of booting
  - [x] Raise `movie_gate_floor` past 375 and confirm the new stop names a **different**
        mechanism than room transitions. It does, twice over. At 420 the stop was the morph ball
        falling through a floor 45 frames *inside* the room the door leads to — which turned out
        to be `TILETABLE` selecting a metatile table nothing re-read (`LoadMetaBase`), found by
        the fixture above on its first run. With that fixed the rung ran out of movie, so the
        offered window went 900 → 2000, and it now stops at **1396 on a pose divergence**, the
        first time this count has stopped on the pose machine since Phase 0a. Recorded with its
        caveat: the movie asks for a bit the port has no key for at 1368, 28 frames earlier
  - [x] Verification: `zig build verify` green; the reachable rung passes 375 with an exact
        frame (1396); the write-up follows `docs/porting_loop.md`'s mechanism arm, which gained
        a step **6b** from this turn; `docs/feature_tracker.md` and `src/ledger.zig` updated

- [x] **Step 7: B2 — title to game, and hand playtesting becomes the loop**
  - [x] Pin `title_tilemap` (bank 5, no address comment) by the same next-routine arithmetic the
        other offsets use, convert it, and add it to `offsets.zig`. It pinned at **both** ends:
        `credits_starPositions` fixes 05:5B34 below it and the already-pinned `gfx_titleScreen`
        fixes $400 above, which is 32x32 and so a whole Game Boy BG tilemap. The address was
        never missing — it is on the *include* line in `bank_005.asm`, which is why a grep of
        the data file found nothing. It is converted, read, and on the screen
  - [x] Port pose `$13`'s 320-frame sequence — Step 15b measured it as what stands between the
        cart and movie frame 0 — with its `HandlePose` and `SamusSpriteId` dispatch entries.
        Both dispatches, which `residue.zig`'s "the two pose dispatches offer the same set"
        covers. **The 320 frames are not in the handler**: it is a wait on `countdownTimer`,
        which the load sets to $0140 and the vblank handler ticks down. One branch is
        deliberately not ported — the song request at 00:$0EAF, because `!Song` is a recording
        of a door script's opcode and a second writer would break the fixture reading it
  - [x] The cart reaches gameplay from a cold boot with no synthesised boot record. The record
        stays as a test fixture; `InitState` gains the path that does not need it
  - [x] Verification: the cold-boot script `zig build romtest` now writes boots the shipped cart
        and plays it; the segment and reachable rungs still pass through the record, unchanged
        (1396, 665, 28/28 — all three unmoved)
  - **Measured 2026-09-08, and two of the step's assumptions were wrong.**
    - **There is one record, not two.** The sub-task's "the path that does not need it" was
      written expecting `InitState` to gain a branch. It did not, and it should not have: a SNES
      cart has to read its start from *somewhere* in ROM, and the honest distinction is not
      whether a record exists but **whose numbers are in it**. `chooseBoot` searches the map for
      a cell and invents a position in the middle of it; `newGameBoot` reads the position, the
      camera, the facing direction, the map bank and the cell out of `initial_save`, and the
      pose and the countdown off the four instructions that end `loadGame_samusData`. Nothing in
      the engine branches on which it got — a `BootMode` byte records the answer for a reader —
      so a cold boot is not a second boot path with its own bugs. The branch that *does* exist
      is one routine, `TitleScreen`, which returns immediately for a handover record.
    - **`room.playing` is the wrong instrument and could not have been used.** It is a Game Boy
      helper that watches $D072 through the SameBoy harness. The SNES-side equivalent is the new
      `cold boot` rung, which is stronger: it presses Start on the title, watches the countdown
      fall one a frame, measures the appearance flicker as a share, requires control to *wait*
      for a button, and then requires Samus to move. It is the only rung in the repository that
      writes nothing to the cart.
  - **The title screen was built, and it was not free.** The sub-task only asked for the tilemap
    to be pinned. Converting it and never drawing it would have been the exact smell arm two's
    step 6b names — a mechanism whose output nothing reads — and "title-to-game" without a title
    is not the feature B2 is named for. What it cost was working out that the Game Boy loads the
    title's characters as **one $1000-byte copy to $8800**, which is four `offsets.zig` entries
    the ROM keeps contiguous, and that $8800 is tile id $80 — so the port rotates the tilemap's
    ids by 128 rather than splitting a character copy across the wrap. Out of scope and left so:
    the flashing palette, the falling star, the save slots and the cursor
  - **A defect fell out of it, and it was in the oldest data in the repository.** Reading
    `initial_save` gave a second, independent statement of the surface tileset's source
    pointers. The metatile pointer agreed. The collision pointer did not — $4580 against
    `offsets.zig`'s $4480 — and all eight `collision_*` entries turned out to name the address
    one slot below the table they name, because they had been written in operand order on the
    assumption that the region is laid out in operand order too. No cart was ever wrong:
    `collisionOrder` resolves by address, so the error was absorbed exactly and came back out as
    a "rotation" that two doc comments then explained as a property of the ROM. The built cart's
    digest is unchanged across the fix. `docs/bug_tracker.md` carries it, with the fixture that
    was written first and shown failing
  - **Eight faults were injected and eight were caught.** Four in the appearance sequence — an
    unseeded countdown, a draw that never declines a frame, control on the timer alone, a counter
    that never ticks — and four in the title screen — sheets in the wrong order, no rotation, no
    title at all, and a title in VRAM but under forced blank. The gate re-injects one of them on
    every run, in the record rather than the engine so it costs one emulator pass

- [x] **Step 8: B11 — the recorded reference *trace*, which everything after this depends on**
  *(closed 2026-09-15 with two sub-tasks unchecked: the withdrawn stitch, and the seeding
  fixture deferred by decision — see the notes under each)*
  - [x] **Rewritten 2026-09-03.** The recording arrived that day and is a superset of what B11
        asked for. What failed was the mechanism: converted to a VBM and replayed on our own
        Game Boy emulator it stops being James's run at 28 796 of 76 950 frames — before his
        first save — and neither the frame source nor the input origin moves that. **So Mesen2
        replays it and we take a trace.** The measurement is in `docs/slice.md`; do not re-derive
        it, and do not spend this step trying to make our emulator replay further
  - [x] **On the critical path, not a supplement.** Zero Metroid kills fall inside the any%
        horizon, so this trace is the only reference that can grade Steps 10–14
  - [x] **The mechanism, settled 2026-09-08: Mesen2 headless, `emu.setInput` at the corrected
        index, `emu.loadSavestate` from an `addMemoryCallback(.exec)`. It replays the whole
        76 951-frame recording.** All of it: longest run of active-input-but-frozen 123 frames,
        2 472 cart-RAM writes from frame 115 to 76 421, and a `$D089` column carrying the new
        game at 118, **the first Alpha kill at 16 890**, the death at 25 891, the reload 52
        frames later at 25 943, and **the second Alpha kill at 73 392**. That is B11's whole
        acceptance list, from the recording that arrived on 2026-09-03
  - [x] **The intermediate "re-record in segments" decision is withdrawn, and so is what
        prompted it.** The premise was that a replay diverges as a function of its length. It
        does not: the harness was reading `IN[f+1]` where Mesen's `inputPolled` callback fires
        *after* the latch, so every input was delivered a frame early. Swept over par05, whose
        11 436 frames made it cheap: `IN[f]` survives whole, `IN[f+1]` dies at 2 301, `IN[f+2]`
        at 9 626. **The same defect `oracle.zig` documents on the SNES side, mirrored** — there
        the cart is handed frame *i+1*'s byte at frame *i*; here the Game Boy is handed frame
        *i−1*'s. A held button hides it and a tapped one does not, which is why it presented as
        "some segments desync and some do not"
  - [x] **`stable-retro` was considered and declined.** The macOS build in `~/git/sim_player`
        has no Game Boy core at all (nine cores, no gambatte), and the divergence it would have
        been adopted to fix was not real
  - [x] **The six segments James recorded are kept as a convenience, not as the reference.**
        `reference/metroid2_par01..06.mmo`, 43 869 frames, six independent tracks over the early
        game — all replaying cleanly under the fix, par02 carrying the first Alpha kill and
        par03 a save at its frame 3 730. They reach an anchor without replaying 76 000 frames
        first, which is worth having; they are not on the critical path
  - [x] Write the Mesen2 Game Boy Lua sampler: replay one segment and emit the columns
        `tas.zig` already writes — frame, input, `samus_y`, `samus_x`, `camera_y`, `camera_x`,
        pose, map bank, Metroid count, WRAM digest. Model it on the SNES-side script the gate
        already runs, and drive it through `$MESEN` the way every other emulator rung does,
        including the "absent means it did not run" contract. **Two channel facts it is built
        around, both measured:** cart RAM to `.srm` is 8192 bytes and a full-width per-frame
        record does not fit, so the script either narrows the record or writes in passes; and
        Mesen boots the cart against whatever `metroid2.srm` is in its Saves folder, so the
        sampler controls that file rather than inheriting it
    - **Delivered 2026-09-08 as `src/gb_trace.zig` + `zig build gbtrace`, and both channel
      facts moved.** The 8192-byte ceiling is not a ceiling: stamping `$149` to `$03` on a
      *copy* of the ROM, with the header checksum at `$14D` re-stamped, gives MBC1's full
      **32 768** bytes, Mesen writes all of it, and `emu.write(..., gbCartRam)` addresses it
      linearly across all four banks. A savestate recorded on the unstamped ROM loads into
      the stamped one without complaint, which was the fact that could have gone the other
      way. The record is 17 bytes — `tas.Sample`'s columns plus `$FF80` — so **1 441 rows a
      pass**, records start above the game's own save bank so a pass can watch the
      recording's saves land, and a `stride` argument censuses a whole 77 000-frame movie in
      one pass. The second fact is answered by not inheriting anything: the sampler runs
      `build-out/m2trace.gb`, so Mesen writes `m2trace.srm` and **the user's `metroid2.srm`
      is never opened** — the throwaway harness deleted it every run and depended on
      remembering to put it back
    - **And the off-by-one was written down backwards.** The harness's `IN[f]` meant row
      *f−1*, because its Lua table was filled one-based; the repo's first implementation
      indexed a zero-based string at `f` and was a frame early in exactly the way that
      harness had been. **`$FF80` cannot settle this** — the emulator delivers whatever
      `emu.setInput` was handed, so the pad byte agrees with any offset — and `$D089` can:
      censused over the whole recording, offset 1 gives 128 `0→71`, **16 896 `71→70`**,
      25 920 `70→0`, 25 984 `0→70`, **73 408 `70→69`** and all seven map banks, and offset 0
      gives a death at 14 144, a new game at 23 040, three banks and no Alpha at all. So
      `gb_trace.input_offset` is 1, and the "lands after the latch" explanation in
      `docs/slice.md` is struck through
  - [ ] ~~Stitch the segments into one trace~~ — **measured 2026-09-08 and dropped.** The six
        delivered segments do not abut: every one of the five seams differs in position, and
        three differ in map bank and `$D089` too, so James played between stopping one
        recording and starting the next. **That is not a defect and the requirement was the
        wrong shape.** The anchored machinery grades from anchors, not from a contiguous
        history, so six independent reference tracks are worth exactly what one stitched track
        would be — and they carry no seam risk at all. What replaces this sub-task: each
        segment is its own track with its own seed state, and the trace reader is taught to
        hold a *set* of tracks rather than one
  - [x] Verify the trace against the cartridge before anything trusts it: the movie's own SHA-1
        and the ROM the sampler ran against are both `metroid2.gb`. A trace taken on another
        revision fails by name, the way `tas.parse` already refuses a movie recorded elsewhere
    - **`Recording.checkCartridge`, and it is the stronger of the two checks.** A `.mmo`
      carries the cartridge's whole SHA-1 in `GameSettings.txt`, where a `.vbm` carries only
      a title and two header checksums, so this refuses a recording `tas.parse` would let
      through. Run before the sampler spawns anything, with a test that flips one ROM byte
      and expects the refusal
  - [x] Generalise the trace readers so this is a third track rather than a special case, and
        land a test with the generalisation. The published runs' traces must read unchanged
    - **`tas.Track`.** `faithfulness` and `findRefusals` took a `tas.Run`, which only our own
      emulator produces; they now take a `Track` — samples plus the three aggregates a
      strided sample set cannot re-derive — and `Run.track()` supplies one. `Track.ofSamples`
      derives them for a track that has nothing else, which is what a Mesen pass is. The test
      asserts a derived track grades identically to the run that produced it, which is what
      makes the substitution safe rather than merely convenient
  - [x] Treat the recording and its trace as vendored input: untracked, supplied like the
        published movies, with `tools/get-tas.sh` and `src/policy.zig` updated so the gate does
        not trip on them
    - **`policy.zig` needed no change and that is the finding, not a shortcut.** `reference/`
      is already in `.gitignore` and already in `policy.skip_dirs`, so the gate does not trip;
      a test now asserts that rather than leaving it to hold by accident. `tools/get-tas.sh`
      gained a section saying the recording is *not* fetched — it is James's, there is
      nowhere to download it from — which reports whether it is present and what to do when
      it is not
  - [x] Build the anchored sweep over this trace, so Steps 10–14 grade by spawning at an anchor
        and running forward. **This is what removes the horizon** — nothing replays 76 950
        frames of Game Boy history
    - **Started 2026-09-08; the anchor *finder* is done and the reference *taker* is not.**
      `oracle.anchorsFrom` and `pushToStableAnchor` took a `tas.Run` — our own emulator's
      output — and now take a `tas.Track`, so a Mesen pass can be anchored the same way a
      replay can. Two assumptions they had inherited are gone with it: that a track's frame
      *n* is its index *n* (`Track.indexOf`, because a Mesen window starts wherever it was
      asked to) and that `samples.len` is a frame number (`Track.end`). A strided track is
      now *refused* rather than silently mis-anchored — `Track.stride`, `Error.NotPerFrame`
      — because a refusal's length is counted in samples, so on a census pass every anchor
      would land somewhere nobody measured
    - **Delivered 2026-09-08 as `zig build oracle -- recorded [start] [window] [min]`**, and
      the shape it took is a *source* rather than a second sweep. `gradeAnchored` and
      `settleAnchors` took a movie and replayed it; they now take a `tas.Track` and a
      `RefSource`, and `MovieSource` and `TraceSource` are the two producers. Everything
      after them — the settling, the cart, the comparison — is the same code either way,
      and the gate says so: the any% rung reports 665 of 6848 across 11 of 13 stretches,
      unchanged to the frame. On the recording's first 900 frames: control at 473, three
      stretches to 830, **371 of 699 frames reached**, nothing replayed on our Game Boy
    - **The settle search was the cost, and the round size belongs to the producer.** A
      replay serves all 120 candidate frames of an anchor out of one run; a Mesen pass
      holds fifteen snapshots and costs a replay, so the same search was **24 passes for
      three anchors**. `RefSource.settle_round` is `settle_search` for a replay — one
      round, exactly as before — and 8 for the trace, which stops asking about an anchor
      the moment it settles. Same answers, **4 passes instead of 25**
    - **Two conflations found on the way, both of which presented as something else.**
      `input_offset` is where the *script* reads its input list and the lag is where the
      *game* is by the time a row is taken; the census demanded they be equal and refused a
      perfectly aligned window as `InputMisaligned`. The lag is 0, measured. And
      `findOpening` took a `Run` while reading nothing but its samples — it takes a
      `Track`, so the recording's own opening is reachable: start 114, room 115, placed
      116, control 473
    - **And the shape of the rest is now known rather than guessed.** What remains is to
      replace `referencesFromMovie` — which produces `MovieRef`s by replaying on *our* Game
      Boy — with a Mesen pass producing the same thing. It is reachable: `oracle.Frame.eql`
      compares position, camera and pose and nothing else, which is exactly what
      `tas.Sample` carries. It needs three more columns the record does not have (`$D02B`
      facing, `$FF97` counter, `$D048` water, all three already documented as consts in
      `oracle.zig`) and, unavoidably, the world dump below: `oracle.Settled` carries a
      `[1024]u8` of `$9800` because `settleAnchors` will not accept an anchor whose room the
      cart cannot be shown to be in. **So the sweep and the world seeding are one piece of
      work, not two** — the sub-task below is not an enhancement to this one, it is a
      prerequisite of it
  - [x] **The anchor restores the world, not only Samus. Added 2026-09-08, from James's note
        that the recording shoots blocks out to descend and the third screen is the first place
        it does.** An anchor that carries position, camera and pose alone hands the port a room
        whose floor the trace does not have, so every anchor after the first destroyed block
        diverges on geometry — from a capability the plan does not reach until Step 12b. So the
        sampler dumps the background tilemap (`$9800`, 1024 bytes) and the 16-slot
        `respawningBlockArray` at every anchor frame, and the sweep seeds `!TilemapBuf` and the
        port's block slots from it. Anchor-frequency, not per-frame: the per-frame columns stay
        as they are
    - **Addresses and sizing, settled 2026-09-08.** `respawningBlockArray` is `$D900..$D9FF`
      — 256 bytes, sixteen 16-byte slots, from M2RoS `SRC/ram/wram.asm` — so one anchor's
      world is **1 280 bytes**. The trace region is 24 512 (32 KiB less the game's own 8 KiB
      save bank and the 64-byte header), which is **19 anchors a pass** if the pass carries
      nothing else, and fewer when it also carries the stretch's frames. That is a real
      budget and the reason this is a separate pass mode rather than a wider record
    - **The 1024-byte shape is not new machinery**: `oracle.Settled.tiles` is already a
      `[1024]u8` of `$9800`, and `compareWorlds` already takes one. The Mesen pass is a
      second producer of a thing the grader already consumes
    - **The port's block slots do not exist until Step 12a**, so that half of the seeding
      lands there and this step seeds `!TilemapBuf` only. The dump takes both now, because
      taking it twice costs a second 100-second replay per anchor and taking it once costs
      256 bytes
    - **Delivered 2026-09-08 as `zig build gbtrace -- <movie> world <frame>...`**, and the
      two things it measured both change the sub-task. **First, `gbVideoRam` exists and the
      tilemap comes back through it.** `$9800` is VRAM and the CPU bus returns `$FF` for it
      during mode 3, so a bus-only script would sometimes record a blank room and call it a
      room; the pass prefers the ungated memory type, records which it used, and refuses a
      blank read by name rather than letting a comparison discover it. Ten probe anchors,
      all through `gbVideoRam`, none blank
    - **Second, and this is the one that matters: the block array is current state, not
      history.** `handleRespawningBlocks` (01:5692) drops a slot the moment the block
      scrolls offscreen. So the array says "which destroyed blocks are on screen right now
      and owed back" and says nothing about the rest of the room — **the tilemap is what
      carries the damage, and the array is only the timer beside it.** Seeding the port's
      block slots from it in Step 12a is therefore a smaller job than this sub-task implied,
      and seeding `!TilemapBuf` is a larger share of the value than it implied
    - **And the premise's "third screen" is wrong.** Counting destructions every frame
      (`blocks_seen`, a script-side accumulator, because a strided pass steps straight over
      the frames the array is set on) says the recording destroys **nothing at all in its
      first ~9 940 frames**, then 24 blocks between ~10 000 and 11 830, then nothing for
      forty thousand frames, then 41 and rising from 53 620. **An anchor before frame 10 000
      needs no world pass** — the room the cell already describes *is* the room the trace
      was in. That is a fact about what James did, not about the ROM, so it could only have
      come from the trace
    - **Delivered 2026-09-08, and it needed the engine.** `!TilemapBuf` is filled by
      `LoadScreen` from the converted map and then by `SeedWindow` from the neighbours, and
      nothing could put a tile in it that the map does not have. Boot record version 10 adds
      `BootWorldCount` and a 168-entry `BootWorld` table at `$00FC00`, and `SeedWorld` applies
      it after `SeedWindow` — after, because the streamer writes whole metatiles and would put
      the intact block straight back. The low byte only: a tilemap word's low byte *is* the
      Game Boy tile id (`SampleTile` says so), so the high byte stays the attribute the
      metatile chose
    - **Which tiles, decided by mechanism rather than by a threshold.** `destroyBlock`
      (01:56E9) writes `$00`–`$03` when a block reforms, `$04`–`$07` and `$08`–`$0B` over the
      two animation frames and `$FF` over all four when it is gone; `01:$5155` treats
      `$00`–`$03` as the hardcoded respawning blocks. So a compared slot whose *map* tile is
      `$00`–`$03` and whose *trace* tile is `$04`–`$0B` or `$FF` is a block the reference
      broke, and any other disagreement is the two machines being in different rooms. That
      needs no bound on how many tiles may differ, which is what makes it safe for
      `compareWorlds` to forgive: a warp that redrew the wrong room disagrees on tiles that
      were never blocks. `World.blocks` counts them so a settle that leaned on the seeding can
      be told from one that did not
  - [ ] **And the seeding has to be shown to matter.** A fault that seeds a *pristine* tilemap at
        every anchor must fail the sweep somewhere after the third screen — if it passes, the
        sweep is not reading the terrain it just loaded. This is the fixture that proves the
        sub-task above rather than the sub-task claiming itself
    - **Built 2026-09-08 as `zig build oracle -- recorded <start> <window> <min> fault`, and
      it reports honestly that it caught nothing.** `oracle.Seeding` is the switch:
      `.pristine` builds the same cart from the map alone, and every seeded stretch is
      re-graded against it — one extra emulator run per seeded stretch, nothing at all on a
      sweep that seeded none. The one seeded stretch in [10 000, 10 400) reaches **one frame
      either way**, because at Step 8 the port cannot play that region at all. **The fault
      has no room to show a difference until the port can walk through a room the reference
      shot its way down**, so this box stays unchecked and what it is waiting on is Steps
      9–13, not more machinery
    - **And the sweep there says the blocker is B12's, not the world's.** Four of six anchors
      in that window never settle, and the diagnosis is a tileset: cell `$6B` is drawn from
      **table 9**, which `screens.assign` inferred from a warp target one cell away, and 88 of
      357 tiles agree — while the Game Boy's own picture is **table 4** at **357 of 357**
      before any block breaks and **351 of 357** after. 351 + 6 = 357, so the six tiles the
      seeding accounts for are exactly the gap and the assignment is the whole remaining
      difference. `oracle -- recorded` now prints both tables and the block count per
      unsettled anchor, so the next one cannot read as a world problem
    - **Deferred by decision 2026-09-15, and the box stays unchecked.** Asked at Step 16's
      door whether to spend a window on it, James's answer was no. So the fixture is built and
      has never been run anywhere it could show a difference, and `faultsCaught` reading 0 of 1
      means *never asked*, not *asked and passed*. **What that leaves standing:** the anchored
      sweep's world seeding is unfalsified, so any Step 10–15 stretch whose reference depends on
      terrain the reference had already broken could be grading against a pristine room and
      passing for the wrong reason. Nothing observed says it is — this is an untested assumption
      being carried forward deliberately, not a known defect. Step 16's "every mechanism has a
      rung that fails when it is removed" audit is where it comes back if it is going to. The
      `$6B` tileset finding below is separate and survives this: it is a measured B12 wrongness,
      and it goes to Step 16's audit as its own item
  - [x] **Locate the two Metroid kills in the trace and write the rooms into `docs/slice.md`**,
        closing the question Step 1 recorded as open. Locate Spider Ball, Bomb, the Energy Tank
        and the Missile Tank the same way, so Step 11 has their cells
    - **Measured 2026-09-08, and the static candidate list was wrong.** Alpha 1 dies at frame
      16 888 in `$F:$10`, Alpha 2 at 73 390 in `$E:$07`; Bomb at 44 329 and the Missile Tank
      at 44 968 both in `$D:$44`, the Energy Tank at 48 047 in `$D:$3A`, the Spider Ball at
      68 453 in `$C:$13`. **Neither kill room is among the sixteen `gfx_metAlpha` warp
      targets Step 1 derived**, and the first is not even in a bank that set reaches — so
      Step 1's decision to name them from the recording did not merely save effort, it
      avoided naming the wrong rooms. Method and table in `docs/slice.md`; a stride-64
      census brackets each landmark and a stride-1 pass pins it
    - **The sampler grew the three columns that made it possible** — `$D045` `samusItems`,
      `$D050` `samusEnergyTanks`, `$D081` `samusMaxMissiles`, the *ceilings* rather than the
      counts, because firing a missile moves the count and only a pickup moves the ceiling.
      They are not `tas.Sample` columns and are not pretended to be: `Pass.samples` ignores
      them, so a Mesen track still reads as the same table every other track does
    - **And the Lua row is now generated from the field table rather than transcribed beside
      it**, with a test that every declared column is actually read. The pickups were the
      first columns anyone had added, and the failure mode of adding one to only one of the
      two lists is a column that holds the previous frame's bytes — a value that simply
      never changes, which is the quietest way for a trace to be wrong
  - [x] Keep `vendor/tas/metroid2-recorded.vbm` and `zig build tas -- rec` as the probe that
        measured the third bound, with a comment saying it is a measurement and not a grading
        path, so nobody rebuilds it later on the assumption it was never tried
    - **Done 2026-09-08 on `tas.recorded` and in `tas_main`'s usage text**, and the comment
      says the one thing that would otherwise be assumed: this 28 796 is **not** the
      off-by-one. That defect was on the Mesen side, in a harness reading `IN[f+1]`, and
      fixing it made the *Mesen* replay whole; this path never used that harness and its
      bound was re-measured after the fix. Without that sentence the obvious next move on
      reading it is to re-run the probe expecting a different answer
  - [x] Verification, **restated 2026-09-08 now that the stitch is withdrawn**: the trace
        covers the whole recording at a census stride and every landmark at stride 1;
        `$D089` in it demonstrably decrements twice, at 16 888 and 73 390; the recording's
        save writes appear in it; `zig build verify` green with the recording present and
        green with it absent
    - Half of this is already measured. **The census and the two decrements are done** — see
      the landmark sub-task above, and `docs/slice.md`'s table. What is not done is the
      save-write check and the recording-absent run of the gate, both of which want the
      anchored sweep to exist first so there is something for them to be green *about*
    - **Both done 2026-09-08.** The save writes: `Pass.saveBytes`/`saveDigest` read the
      game's own 8 KiB bank, which the trace region deliberately sits above, and every pass
      prints them. The savestate carries cart RAM, so a pass's frame 0 is whatever James had
      already saved — the check is a *difference between windows*, not a comparison against
      an empty bank, and it is unambiguous: digest `C1EB986B` at frame 200, `3F094691` at
      25 020 and 26 120, `53B37880` at 60 000. The pair at 25 020 and 26 120 being equal is
      itself a fact worth having: the death at 25 891 and the reload at 25 943 are a *load*
      and write nothing. And the gate: `reference/metroid2.mmo` moved aside, `zig build test`
      is 5 025 of 5 030 with **5 skipped and none failed**, and `zig build verify` is green
      end to end
  - **Measured 2026-09-08, and the step's central assumption is wrong in the same way B11's
    original one was.** "Mesen2 replays it and we take a trace" was written on the strength of
    Mesen2 replaying its own `.mmo` deterministically. It does — in its GUI. What this turn
    measured is that **the replay cannot be reached from a headless run**, and that re-driving
    the inputs ourselves reproduces the opening exactly and then loses the run, at the same
    order of magnitude our own emulator loses it. The measurements, so the next turn does not
    re-take them:
    - **Testrunner takes exactly one file.** `$MESEN reference/metroid2.mmo --testrunner …`
      exits 255, and so does either order of ROM and movie together. There is no Lua movie API
      either: `emu.playMovie`, `emu.startMovie`, `emu.loadMovie`, `emu.movie` and `emu.loadRom`
      are all absent. **Mesen cannot be asked to play the movie without its GUI.**
    - **The Lua surface that does exist**, probed rather than assumed: `emu.setInput(buttons,
      port)` — that argument order; the other throws — `emu.getInput`, `emu.reset`,
      `emu.getState`, `emu.getRomInfo`, `emu.getScriptDataFolder`, `emu.createSavestate`,
      `emu.loadSavestate`, and the memory types `gameboyMemory`, `gbWorkRam`, `gbCartRam`. The
      two savestate calls throw *"This function must be called inside an exec memory operation
      callback for the main CPU"* from an event callback, which is a contract and not a
      failure — from an `addMemoryCallback(.exec)` they work.
    - **`io` is nil and `emu.log` is swallowed on the Game Boy side too**, re-measured rather
      than inherited from the SNES rungs. The only wide channel out is the same one
      `snes_trace.zig` uses: cart RAM to `.srm` on exit, **8192 bytes**, against a trace of
      76 950 frames that wants more than a megabyte. Chunking it costs a full replay per chunk.
    - **Headless is fast enough that this is not the problem**: 76 951 frames in **≈100 s**.
    - **The replay is deterministic.** Two identical runs agree on every census column across
      all 76 951 frames; the only byte that differs is `$D089`'s pre-initialisation garbage at
      frame 85 (100 one run, 215 the next). `gameboy.ramPowerOnState Random` is therefore
      visible but not load-bearing, and the settings scare in `docs/slice.md` is answered: the
      user's Mesen config **already matches** `GameSettings.txt` exactly — `AutoFavorBest`,
      `UseSgb2 true`, `RamPowerOnState Random` — so the model was never a variable.
    - **The opening reproduces exactly.** Driving `Input.txt` through `emu.setInput` from a
      cleared power-on: Start at 114, pose `$13` at 117, control at 474, first move at 474,
      `$D089` = `$47`. That is `tas.zig`'s own measured opening, to the frame.
    - ~~**And then it loses the run.**~~ **Withdrawn the same day — this was the off-by-one,
      not the replay.** The measurements that read `$D089` never leaving `$47`, one cart-RAM
      write, and Samus frozen for 58 000 frames were all taken with the input index a frame
      early. With `IN[f]` the same recording replays whole. Nothing in this bullet stands, and
      the "loses the run" reading of it was what sent the step down the segment path.
    - **A trap worth keeping.** Mesen boots the cart against
      `~/Library/Application Support/MesenCE/Saves/metroid2.srm`, and a stale one silently
      changes the run: the first probe pressed Start and *continued someone's old save*,
      reading `$D089` = 69 where a new game is 71. Any sampler has to control that file. The
      one that was there has been restored.
    - **Frame- and poll-indexed input are the same thing here** (79 999 polls in 80 000
      frames) and both stall identically, so input alignment is not the cause.
  - **So the mechanism is still open, and the choice is architectural.** Recorded here rather
    than guessed at: either the sampler drives Mesen's GUI, where the movie plays properly and
    `io` may exist; or the trace is taken from something other than this recording; or B11's
    grading role is re-scoped to the ~14 000 frames that do reproduce. **Do not spend another
    turn re-measuring the list above.**

- [x] **Step 9: B4a — the entity foundation**
  - [x] Convert the `enemy_data` per-screen spawn records and `enemy_data_pointers`
        (`src/offsets.zig:180`) into the SNES asset set, and give them a region in
        `snes_layout.zig`. `zig build coverage` stops naming `enemy_data` as unread
    - **Delivered 2026-09-08 as the `enemies` region, 9118 bytes in a 16 KiB reserve, and it
      ships four blobs rather than the two the sub-task names.** The headers came with the walk
      because `loadOneEnemy` copies nine of their bytes into every slot it fills and takes the AI
      pointer out of the last two: a spawn walk without them fills a slot with a sprite id and
      nothing else, which is a slot no later step could grade. Both pointer tables are relocated
      the way the door table already was — the ROM stores bank-3 addresses — and both relocations
      are checks rather than copies. **The structure came out perfect and that is the finding:**
      1792 pointers, all distinct, all inside the region, and `ptr[i]` is exactly the *i*'th list
      the linear walk finds, so the table is in the walk's own order; 1368 of the 1792 lists are
      empty and the 424 that are not hold 665 records. All 255 header pointers are in range and
      11-aligned. `enemy_data` is `.encoding` in `roundtrip.plan` now, not `.none`, and the two
      tests that counted the undecoded set derive the number from `plan` instead of restating it
  - [x] Add the 16 entity slots to the engine with the original's layout, and port the spawn and
        despawn windows unchanged — both are prerequisites of the TAS oracle, and changing either
        desyncs whole-game verification
    - **`!Slots` at $0200 and `!SpawnFlags` at $0400**, with the original's field offsets and
      *not* its HRAM mirror: 02:$43D2 and 02:$4421 exist because the Game Boy reaches HRAM a byte
      cheaper than WRAM, and a 65816 with a slot address in an index register pays nothing to
      work in place. Only the tail of the second is ported, under the name `SlotFlagOut`, because
      that tail is not bookkeeping — it publishes the slot's flag back into $C500
    - **The despawn window is three routines, not one**, and they only mean anything together:
      02:$452E moves an active slot offscreen, 02:$44C0 brings it back, 02:$4464 frees it two
      screens out. 03:$6BD2 carries every slot with the camera, which is what feeds all three
    - **The `rLY` budget could not come and the plan should record why.** The original gives up
      before processing at scanline $70, stops mid-slot at $58, and runs a complete pass every
      *other* frame through `enemy_sameEnemyFrameFlag`. That is a lag mechanism; this cart has no
      lag to spend and no LY that means what it means there, so the pass runs to completion every
      frame. The axis alternation *is* kept, because that one is not about lag — the oscillator
      is checked unconditionally and picks an axis
  - [x] Port the per-screen spawn walk: entering a screen consults the screen's spawn list and
        fills slots; leaving it despawns on the original's condition, not on ours
    - **Both axes, and they are not mirror images.** The horizontal arm skips to the next screen
      where the vertical arm would skip only the record, and it looks the bottom screen's list up
      properly where the vertical arm steps lazily over a terminator into the next one. M2RoS's
      own comment calls the first a weird optimisation assuming something about the data's order;
      both are reproduced rather than regularised, and the lazy step is *checked* by the
      conversion, which is what the "walk's own order" measurement above is for
    - **The two carry conventions are the whole of the porting risk.** A Game Boy `cp` sets carry
      on a borrow and a 65816 `cmp` clears it, and the same inversion applies to `sub`/`sbc` — so
      every `jr nc` after a subtraction became `bcs`. `ScrollEnemies` is where it bites: the
      screen adjustment happens on the *opposite* branch from the one the source reads like
  - [x] `residue.zig` entries for the slot array and every per-slot field; `ledger.zig` rows for
        the routines ported; the feature tracker updated
    - **Eighteen `residue.zig` rows and eighteen `ledger.zig` rows**, and the residue table's own
      rule widened rather than an exception being made: the slots and the flag array are not
      direct-page variables and are in the table anyway, because 640 bytes of frame-carried state
      left $00xx only for want of room. `EnemyDeleteSelf` has no ledger row — the gate says
      03:$6AE7 is not an instruction boundary in any run this repository can make, since no
      observed run kills an enemy — so its note is folded into its caller's, per arm one's step 5
    - **And the audit's own scan had a defect that this step was the first to expose.**
      `residue.sites` classified `sta.w !Foo` as a *read*, because it compared the whole mnemonic
      against `sta`. Every variable the port had until now lives in the direct page, where asar
      sizes the operand and the source says `sta !Foo`; the entity arrays are absolute and their
      stores carry `.w`. The cost would have been an audit that can never produce an `unread` row,
      which is its cheapest finding. Fixture written first and shown failing, per the standing
      rule; `bug_tracker.md` carries it
  - [x] Verification: a `room.zig` scenario walks Samus into a screen with a known spawn list and
        asserts the slot contents against the ROM's records. ~~**The segment rung is expected to
        move, not hold:** the segment's own cell (`$0F`/`$76`) carries spawn 15, type `$9D`, at
        (`$38`, `$B8`).~~
    - **The premise was wrong and the fixture says so.** `$0F`/`$76` is not the oracle segment's
      cell. The segment runs on **map index 0 — bank `$9` — cell `$38`**, which the gate prints on
      every run, and *that* cell's spawn list is empty. `$0F`/`$76` is the **landing site** — the cell
      `initial_save` starts a new game on, which `docs/slice.md` states three times over — so the
      two starting points got crossed. The cell does carry spawn 15, type `$9D` at (`$38`,`$B8`);
      that half is right, and it means the very first screen of the game has an enemy on it,
      which is worth having for Step 10
    - **So the segment rung holds, and holding is the correct outcome.** Even where the reference
      does load an enemy inside the graded stretch — the segment rolls left into cell `$37`, which
      has two records — the rung compares position, camera and pose, and a port whose enemies
      neither move nor draw touches none of the three. The rung that moves is B4b's. `oracle`
      stays at 644/644 with 4/4 and 3/3 fault sweeps, `reachable` at 1396 and `anchored` at 665 of
      6848 across 11 of 13, all to the frame
    - **Four fixtures in `src/room.zig`, and the load-bearing one grades the reader against the
      running game.** It puts the original in `$0F`/`$76`, drags the camera across the screen a
      pixel a frame, and requires every record the *game* loads into its own slot array to be one
      `entity.zig` can point at in a cell the walk is allowed to read. What loads there is spawn
      14, type `$9B`, from cell `$75` — the screen to the left, which is where the vertical arm
      reads first — and the other three fixtures pin that down: the neighbours on both axes and
      the same cell in the neighbouring bank all disagree, so none of the five ways the cell index
      could be wrong would have produced the answer the game gave. **Fault-swept:** the cell index
      shifted by one fails all three of the fixtures that can see it
    - **The camera is driven rather than walked, and that is measured rather than lazy.** 240
      frames of held input in that room load nothing at all, because there is nowhere for her to
      walk; the walk fires only on a scroll and only as an edge crosses a record's own rounded
      coordinate. Writing the camera is the same class of lever as the `WARP` write the harness
      already makes. The fixture also has to set $C44B `saveLoadSpawnFlagsRequest` by hand, for
      the same reason: the harness's `WARP` does not go through the interpreter, so nothing
      refills the unsaved spawn flags and the room is entered holding the previous room's
    - **What Step 10 inherits, stated so it is not rediscovered:** enemies do not move, are not
      drawn and cannot be touched. The AI pointer is loaded into every slot and never called

- [x] **Step 10: B4b — enemy AI, hitboxes, and Samus taking damage**
  - [x] Port the enemy AI dispatch: `enemy_header_pointers`/`enemy_headers` drive the per-frame
        AI pointer for a live slot. This is the first of `dispatch.unreached`'s four layers to be
        entered, so it gets a `dispatch.zig` note recording that it is no longer unreached
    - **The original's `jp hl` cannot survive the port and that is the design, not a shortcut.**
      The pointer `LoadOneEnemy` copies into the slot is a bank-2 Game Boy address; it means
      nothing on a 65816. So `EnemyCommonAI` searches an `AiTable` of (Game Boy address, ported
      routine) pairs and `jmp`s through the match, and an address the table does not know is
      recorded in `!EnUnhandledAi` rather than jumped to. That also makes "which AIs does this
      cart have" a question with a written answer, which `jp hl` never could
    - The four state tests in front of the dispatch — drop, explosion, ice, `metroid_state` — are
      ported and their handlers are not, because each is a mechanism a later step owns and none
      of the four states is enterable by anything this cart has. `!EnUnhandledState` records the
      first one ever reached, the same shape `!Unhandled` has for a pose
    - Three arms: `enAI_NULL` (200-odd ids point at it, so it is the *default* and belongs in the
      table rather than in the recorder), `enAI_smallBug` (sprite $12, the room the ball rolls
      into) and `enAI_senjooShirk` (sprite $16, the one that reaches Samus). **The gate dropped
      all eight of their `ledger.zig` rows on its own instruction-boundary check** — no observed
      run of this repository puts a live enemy in a slot, which is the very layer
      `dispatch.unreached` names — so their notes are folded into their callers', per arm one's
      step 5
  - [x] Port hitboxes from `enemy_hitbox_pointers` and damage values from `enemy_damage`,
        unchanged from the original's tables
    - Three new blobs in the `enemies` region and **one finding in the conversion**: 254 of the
      255 hitbox pointers relocate and id $9A's does not — it is $C360, a WRAM address — so it
      becomes `entity.dead_pointer` and `LoadEnemyBox` refuses it by value. The count is asserted
      at exactly one rather than tolerated, because a second would mean the region moved
    - Four more in `physics`, which is where this port keeps per-pose Samus tables:
      `collision_samusSpriteHitboxTop`, `samus_damagePoseTable`, `samus_bombedFallingPoses` and
      `physics_bombArc`. All four are new `offsets.zig` entries whose ends are pinned from the
      ROM — each near end is a `ld hl,addr` that occurs exactly once in bank 0
  - [x] Port the knockback poses `$0F` and `$10` — both dispatches each, `HandlePose` and
        `SamusSpriteId` — and the energy decrement on contact
    - **Four poses, not two:** $0F and $10 both fall through into $11, which is where the arc is
      actually flown, and $12 is $11's ball. All four in `HandlePose`; $0F and $11 draw through a
      new `.knockback` arm and $10 and $12 through the existing ball arm
    - The contact side is all four of the original's entries — 00:$32AB, $32CF, $348D and $34EF —
      over `collision_samusOneEnemy` and its vertical twin, **and porting fewer would have been
      wrong**: the encounter the segment grades comes in through `collision_samusBottom`, not
      through the play handler's own pass
    - The damage is BCD, and a 65816 has decimal mode, so `applyDamage.apply` is shorter here
      than in the original for once without anything being left out. The i-frames tick down in
      `DrawSamus`, which is where the original ticks them, and the four-on four-off blink with it
  - [x] Extend the oracle segment past frame 676, which pose `$10` currently caps at 644, and
        record the measured new `segment_frames` and what it does to the segment's bucket width
    - **644 to 700, and the last 56 frames are the first this repository has graded with enemies
      live and moving on both machines.** `frames_per_code` is unchanged, so the bucket width did
      not move; the bisection has made the reported frame exact since 2026-09-05 anyway, and
      `snes_trace.zig`'s save-RAM channel became the binding constraint instead — 700 frames at
      45 bytes plus the tilemap is 32 524 of 32 768, which is what forced a fifth trace column
      back out
    - **It was 120 frames first and that measurement is the step's most useful output.** Extended
      that far the segment reaches frame 702 *exactly* — the contact frame, every frame before it
      matching — and stops, because the cart does not register the hit. See the open item below
  - [ ] **Graded against Step 8's recorded run and `room.zig` scenarios, not the published
        floors**, which cannot see an enemy encounter inside their horizon
    - Not done, and the segment turned out to be the better grader anyway: it reaches the
      encounter frame for frame, which the recorded run's anchored sweep cannot yet do
  - [x] Verification: `zig build verify` green with the extended segment; a fixture asserts a
        known enemy's hitbox and damage against the ROM tables and fails when either is perturbed
    - The fixture is `src/room.zig`, "the enemy the segment is hit by has the hitbox and damage
      the ROM gives it", which pins the Senjoo's $15 and its box against the ROM, requires all
      four of `CollideResolve`'s damage cases to occur in the table, and requires exactly one dead
      pointer. **The gate is green**: `reachable` 1396 of 1396, `oracle` 700 frames frame for
      frame, `anchored` 665, 5075 unit tests
  - **Three defects found and fixed, each by a rung rather than by reading, each with its own
    `bug_tracker.md` entry.** They are the larger part of this step:
    - **The enemy pass ran every frame where the original runs it every other.** Step 9 read
      `enemy_sameEnemyFrameFlag` as the `rLY` lag mechanism; it is the 30 FPS gate, which the
      original's own comment says outright, and the Game Boy confirms in one column — a small
      bug's behaviour counter reads $2E,$2E,$2F,$2F,$30,$30 across consecutive frames. Every AI
      was running at twice the original's rate
    - **The cart enabled NMI wherever boot happened to end.** Inside vblank the handler fires at
      once — NMI is not maskable by `cli` — and `MainLoop`'s `wai` then waits for the next, so
      two NMIs elapse where the boot record's `!FrameCount` seed assumes one, and every walk step
      loses its parity. Latent since the engine had an NMI at all; B4b's four extra `FindBlob`
      calls were merely what moved the enable across the boundary, for exactly one of thirteen
      anchored stretches. `reachable` fell 1396 to 129 with nothing wrong in the port
    - **`SpawnListAt` subtracted 9 from a `!MapIndex` that was already an index**, following the
      original's `currentLevelBank - 9`. The cart loaded **no enemy anywhere**, and had since
      Step 9, because Step 9's fixtures grade the reader against the running Game Boy and no rung
      had ever looked at a slot on the cart
  - **The fourth defect, which was the step's blocker, and it was one constant.** The cart's
    spawn walk loaded a different set of records than the Game Boy's — at segment frame 640 the
    Game Boy had three live slots and the cart none — and `reachable` read 604 against its floor
    of 1396. The cause was **`DeriveScroll`'s bias**: the Game Boy's `scrollY`/`scrollX` are the
    camera's pixel byte less a fixed amount, and the ROM writes that pair from three sites which
    do not agree — 00:$2366 (once a frame) and 00:$2896 (the room load) subtract $48 and $50,
    while 00:$04C3, which restores the camera out of $D804..$D807, subtracts $78 and $30. The
    engine had $78/$30. Every record the walk loaded came out **48 pixels low and 32 right**, sat
    in a different band of the deactivation window, and was deleted while the Game Boy kept it —
    the small bug on frame 546, having loaded correctly on 387.
    - **Reading the ROM could not settle it, because the wrong pair is in the ROM too.** So the
      fixture asks the running game: `src/oracle.zig`, "the engine's scroll bias is the one the
      running game uses", reads the two defines out of `engine/main.asm` and grades them against
      the original on every frame of the segment, requires the camera to have actually moved, and
      requires the old $78/$30 pair to be right on **zero** frames. Put $78/$30 back and it fails
      on the first frame — checked
    - It was found by the `en` columns, exactly as they were added to be: the cart's slot 0
      against the Game Boy's, frame by frame, which turned "the port did not register the hit"
      into "the port loaded the enemy 48 pixels below where the original puts it"
  - **What the fix uncovered, recorded rather than carried silently.** With the walk right the
    segment reaches the contact, and at 703 frames the `oracle` rung reads *Samus's position
    diverged, at frame 702 of 703* — the only frame that differs. **The cart registers the
    contact one tick before the Game Boy does**: at 702 the Game Boy is still at frame 701's
    position with the arc counter on `hurtSamus`'s seed of $40, and the cart has already flown the
    first arc step. The pose columns agreeing is the sample points' doing — `gb_logic_pc` is after
    `hurtSamus` and the cart's record is at `MainLoop` — not agreement. The channel holds 705
    frames, so the three between 700 and the contact are affordable the moment that is fixed. It
    is an open `bug_tracker.md` entry with the measurement written out, and it belongs to the
    contact test rather than to the walk

- [x] **Step 11: B6 — items and pickups**
  - [x] Implement the `ITEM` door opcode's effect and item pickup for every item type in the
        region, applying the item's effect to `!Items`
    - **The two halves of this sub-task are two mechanisms, and the `ITEM` opcode is not the
      one that gives an item.** 00:$2634's arm loads four graphics blobs — the item's tiles,
      the orb, the item font and the name out of `item_names` — and walks on; `!ItemGiven` is
      a record of a room having been *decorated*. Every `samusItems` bit is set by
      `handleItemPickup` (00:$372F), which a **sprite** reaches: `enAI_itemOrb` (02:$4DD3)
      turns the orb into the item when it is shot and sets `itemCollected` when Samus touches
      the item. All three parts are ported — the AI, the fifteen-arm dispatch, and
      `handleItemPickup_end`'s two wait loops — with the blocking turned inside out into
      `!ItemStage`, the way Step 5b turned the door interpreter inside out
    - **The frame cost is measured against the recording rather than derived.** Stride-1 passes
      over the four pickups: the item bit lands **exactly four frames** after Samus freezes in
      all four (Bomb 44 325/44 329, Missile Tank 44 964/44 968, Energy Tank 48 043/48 047,
      Spider Ball 68 449/68 453), which is the four `waitOneFrame`s at 00:$3734 and nothing
      else; the freezes run 358, 103, 366 and 359 frames against the `$0160` and `$0060` the
      countdown is set to, and 00:$375C's `cp $0D` is where the item space divides. The tails
      are 2, 3, 10 and 3 and are **deliberately not modelled as a constant**: the second loop
      runs until the orb's AI deletes it, which is as long as the enemy pass makes it
    - **`enSprCollision` is not `collision_weaponType`**, and the difference is a frame. The
      hitbox test writes `$D05D`; the enemy handler's own exit (02:$4318) copies it into
      `$C466` and clears the source; the AIs read the copy. So an AI asking about contact is
      asking about the previous frame — the same gap `hurtSamus` has, and the port now has
      `TransferCollision` for it
  - [x] Convert `item_names` (`src/offsets.zig:204`), and **pin the `samus_pose_tables` for every
        pose the original dispatches, not only the slice's** — morph, spider ball, knockback and
        the queen sequence — so Phase 1 inherits a complete table set rather than a partial one
    - **Done 2026-09-09, and the offsets entry was wrong at both ends.** It read `$5911/$1A0`,
      which starts 32 bytes *after* the pointer table and runs 160 bytes *past* the strings
      into `drawEnemies`. Three independent statements of the real shape, none of them a
      listing: the pointer table at 01:$58F1 holds sixteen addresses and they are $5911,
      $5921 ... $5A01, sixteen apart, all sixteen; 01:$5A11 is `FA 26 C4 A7 C8 21 00 C6`,
      which is `ld a,[numEnemies.active] / and a / ret z / ld hl,$C600` and identifies
      `drawEnemies` from its own first instructions; and `gfx_itemFont` (05:$6C34, 32 tiles)
      **drawn out** is A at tile 0 and Z at tile 25, so a string byte is `$C0 + tile` — a fact
      about the graphics, reached without reading a string. So the class is $120 bytes and
      `src/items.zig` decodes it, rebuilding the pointer table from the string index rather
      than carrying it through. **`item_names` was the last raw class: coverage now reads
      130 of 130.**
    - **And the pending pose tables are three, not four.** `samus_drawJumpTable` sends all
      thirty poses to eight routines; the knockback is 01:$4C69, the spider 01:$4C8C and the
      morph 01:$4CB5, and **all six Queen poses $18–$1D dispatch to `drawSamus_morph`** — so
      there is no separate queen table to find, which is what *closes* `offsets.pending`
      rather than shrinking it. Each end from the ROM: every `ld hl,<table>` occurs exactly
      once in bank 1, and each table's far end is the first instruction of the next draw
      routine
    - **The knockback pair forced a real change to the model.** `sprites.parsePoseTable`
      insisted on rows of four; `drawSamus_knockback` indexes two bytes by facing alone, so
      four would either refuse the table or swallow two bytes of `drawSamus_spider`. The row
      width is now the table's own reader's, with two reserved for exactly that length
    - **What the pinning actually bought is not data on the cart.** None of the three is
      converted — the knockback and the ball are drawn from immediates in `SamusSpriteId`,
      and the spider has no pose until Phase 1. What it bought is that those four immediates
      stopped being numbers someone typed: `ConstSprKnockL/R` and `ConstSprBallL/R` are
      exported and `correspond.zig` compares them against the cartridge, including the
      "each row counts up by one" property the bases-plus-index reading depends on
  - [x] **Enforce tests only on the poses Step 1 found in the slice.** Every other pinned pose is
        recorded in `docs/feature_tracker.md` as ported-but-ungraded against phase `1`, which is
        what marks it as untested rather than forgotten
    - Done 2026-09-09. B6's entry now carries six ported-but-ungraded bullets: the nine pickup
      arms the region does not yield, the Varia suit's two animations, the missile refill's
      credits branch (B8's `metroidCountReal`, recorded in `!ItemUnhandled` rather than tested),
      the `!Items` branches for the five items the slice does not grant, the window raise at
      00:$3A1F, and `enAI_itemOrb`'s delete arm
  - [x] Reach the `!Items` branches the region actually yields, **scoped 2026-09-03 to what the
        B11 recording collects**: **Bombs in the bomb jump, and Spider Ball**. Each gets a
        fixture that holds the item and asserts the branch fires. **Hi-Jump and Spring Ball are
        not collected** — neither is in the recording, and Hi-Jump's three doors are referenced
        by no cell — so their branches are recorded in `docs/feature_tracker.md` as
        ported-but-ungraded against phase `1`, not left looking like an oversight
    - **The Bomb's branch is graded and it is the first `!Items` branch anything on this cart
      has ever taken.** `snes boot` phase 10 runs it twice — bit cleared, where the ball must
      keep rolling, then the bit the pickup gave it, where it must jump — so the fixture shows
      the branch is *gated* rather than merely that it fires, and the "fails with the item
      cleared" half of the verification lives inside the fixture instead of beside it
    - **Spider Ball has no branch to reach, and that is a finding rather than a shortfall.**
      `!ITEM_SPIDER` has exactly one user in the engine — the pickup that sets it — because the
      spider poses `$0B`–`$0E` are Phase 1's. So B6's Spider Ball scope is the bit and the
      `pose_sprites_spider` table, both delivered; the branches arrive with the poses, and the
      feature tracker says so
    - Two levers were needed to make the negative half honest and both were **measured**: the
      pose is re-forced only when she is not already in a ball pose, because
      `poseFunc_morphBall` off the ground writes $08 and returns without moving her — forcing
      it every frame hung her in mid-air, and the probe read poses $05 and $08 and nothing
      else; and `!DownSpeed` is cleared every frame, because a landing at two pixels a frame
      bounces into the same pose *without* the item (00:$1740) and would have made the ungated
      half read as a pass
  - [x] Verification: `zig build coverage` reports `enemy_data`, `item_names` and
        `samus_pose_tables` as read; the `!Items` fixtures pass and fail with the item cleared;
        the feature tracker shows every unpinned pose closed and every untested one named
    - **All three, and the first is stronger than the sub-task asked for**: coverage reads
      **130 of 130 entries with no raw class**, and `offsets.pending` is empty for the first
      time in the project. `zig build verify` is green end to end with the numbers unmoved —
      reachable 1396, anchored 665, durations 28/28, the oracle segment 700 — which is the
      correct outcome and not a null result: neither published run collects anything, and the
      recording's four pickups are 44 000 frames past the horizon
    - **A defect fell out that had been latent since Phase 0a.** `!ITEM_BOMB` was `$10` and
      `!ITEM_SPRING` was `$20` — Spring Ball's bit and Spider Ball's — and Spider Ball had no
      mask at all. Nine branches read them and none could show it, because `!Items` is zero for
      the whole of Phase 0a. The fixture came first and was watched failing. The oracle is the
      *cartridge*: `handleItemPickup`'s seven equipment arms are `ld a,[samusItems] / set n,a /
      ld [samusItems],a`, so `items.bitFor` reads the bit out of the `SET n,A` opcode — a
      second transcription of M2RoS's names could not have caught a slip in the first
    - **And the fixture found a second one on its first run**: `!ITEM_BOMB` was then shadowed by
      an item-*number* define of the same name three hundred lines later, so `ItemPickupArm`
      ORed the number into `!Items` while the exported mask still read the mask. It reported
      `!Items` as $05. The item numbers are `!ITEMNO_*` now

- [x] **Step 12a: B5's terrain half — shot and bomb blocks, before anything fires at them**
  - **Added 2026-09-08.** The requirements said projectiles "collide with terrain" and never said
    a block disappears; `engine/main.asm:3556` has said since Phase 0a that shot and bomb blocks
    are deliberately not ported. It is its own step because **the destruction machinery does not
    need the entity layer** — only its trigger does — so it can be built and graded directly,
    and Step 12b then has nothing to do but call it
  - [x] Port the classification the original uses at 01:$5155: a tile is eligible only below
        `beamSolidityIndex` (the beam threshold in the solidity row `tileset.zig` already
        models); **tile ids `$00`–`$03` are hardcoded respawning blocks**; every other id is
        eligible iff bit 5 (`blockType_shot`) of its collision byte is set. Add the missing bits
        to `engine/main.asm`'s block-type constants, which stop at `!BLOCK_SPRING`
  - [x] Port `destroyRespawningBlock` (01:$5671) and its 16-slot array, `handleRespawningBlocks`
        (01:$5692) with its per-frame counter and its offscreen eviction, and `destroyBlock`
        (01:$56E9) — the four tilemap writes, the animation frames at counters `$02`, `$07`,
        `$F6`, `$FA`, the empty at `$0D` and the reform at `$FE`. The Game Boy's two `rSTAT`
        hblank waits are a Game Boy timing constraint and do not port; the SNES writes through
        the same vblank queue the transition code already uses
  - [x] `residue.zig` entries for the block array and its fields; `ledger.zig` rows for the three
        routines; `docs/feature_tracker.md` updated. `zig build coverage` unchanged — this step
        reads no new asset class
  - [x] Verification: a `room.zig` scenario destroys a tile directly, with no projectile in the
        game, and asserts **the collision change, not the picture** — Samus falls through where
        she stood — then asserts the reform puts the floor back and she stands again. A second
        fixture drives the counter past the offscreen eviction and asserts the slot frees. The
        sound-effect request is recorded as an id, the way Step 5's `SONG` stub is, and no
        driver is written

- [x] **Step 12b: B5 — projectiles and combat**
  - [x] Port projectile spawn, travel, terrain collision and despawn from the original's
        routines. **Not into the entity slots Step 9 established, and the sub-task was wrong
        about that**: the ROM keeps a separate three-slot `projectileArray` at $DD00 with its own
        stride, its own weapon-dependent search and its own pass, and `handleProjectiles` never
        touches `enemyDataSlots`. Corrected here rather than designed around. The despawn turned
        out to live in the *draw* — 01:$538A frees a slot whose sprite would land outside the
        visible window, and nothing anywhere counts a projectile's frames down
  - [x] Wire the trigger: `HitBlock` gained a caller and a return value. Its two copies in the
        original (01:$515E for the wave, 01:$52A6 for everything else) agree on the three tests
        and disagree on what happens after them, so the carry is what tells them apart.
        **The plan's `01:$2367` is not an address in bank 1** and the bomb arm is 01:$553F;
        the bomb half is deferred to Step 12c, below
  - [x] Port enemy collision and the damage applied to a hit enemy: `collision_projectileEnemies`,
        `collision_projectileOneEnemy` sharing `LoadEnemyBox` with Samus's test through a new
        `!ColPad`, and `enemy_getDamagedOrGiveDrop` with `enemy_checkDirectionalShields`
  - [x] Missiles and the beam/missile toggle: the missile's acceleration curve, its two sprite
        rows, the BCD decrement and the dud shot, and `toggleMissiles` — whose cannon graphic is
        a $20-byte re-upload into the middle of Samus's sheet and is recorded in `!CannonGfx`
        rather than performed
  - [x] **Two commits, deliberately.** `ce62d20` is the port with `B` withheld: reachable 1396,
        anchored 665, durations 28/28, all unmoved, which is the predicted outcome.
        `4606295` adds `B` and changes nothing else: reachable **1396 → 1466**, and the stop
        goes back to being a position divergence. The floor's own note had been warning since
        Step 6 that the ceiling at 1368 was 28 frames before the stop at 1396
  - [x] Verification: `zig build verify` green after each commit separately; `snes boot`'s two
        new phases fire a shot into terrain and into an enemy, and **their lever is the fire
        button rather than a byte written into the cart**, which is a first for this gate.
        Watched failing three ways: `SamusTryShooting` out of `MainLoop` (161), `EnemyDamageOrDrop`
        out of `ProcessEnemies` (165), and the `!SprX` aliasing put back (122)
  - **One defect fell out and it is a class.** `!SprX` and `samus_onscreenXPos` were one variable
        in this engine, correctly, for exactly as long as Samus was the only thing it drew;
        `drawProjectiles` writes the sprite byte and not the other, and eight routines would have
        been asking a projectile where Samus is. See `docs/bug_tracker.md`
  - **And one gate hazard worth carrying forward**: the generated Lua is capped at 200 locals per
        chunk and was at 198. This step's constants took it past, the script stopped *parsing*,
        and the gate reported a timeout that read exactly like a hung cart. Groups go in tables
        now. `zig build romtest` also writes the cart `snes boot` actually runs, which is not the
        one `zig build rom` ships — pairing the two silently grades the wrong cart

- [x] **Step 12d: the enemies become visible**
  - **Added 2026-09-09, and it is a bug report rather than a measurement.** James played the cart
    and found enemies that move, hurt Samus and can be killed, with nothing on the screen. It
    goes before Step 12c because a mechanism you cannot see is a mechanism you cannot playtest,
    and hand playtesting has been the loop since Step 7
  - [x] Port `drawEnemies` (01:$5A11) and `drawEnemySprite` (01:$5A3F) with
        `drawEnemySprite_getInfo` (01:$5A9A) folded into it, through Step 12b's `PutObject`
  - [x] **Ship the enemy metasprite set**, which is the cause underneath the cause: it had been
        correct in `offsets.zig` and round-tripping since Step 4 and had no `sprites.Which`
        entry, so nothing ever put it in the cart. A round trip says the bytes are understood; it
        says nothing about whether the cart can reach them
  - [x] The metasprite region: 8071 bytes against 4096 reserved. Took 12 KiB out of
        `map_screens`' slack rather than let the cart double — **512 KiB, 133 blobs**
  - [x] **A second defect, and the same shape as Step 12b's:** `ClearUnusedOam` ran from inside
        `DrawSamus`, which was right while she was the only thing drawn and wrong from the first
        frame anything appended after her. Projectiles have been leaving unhidden slots since
        12b. Moved to the end of the frame, where the original has it
  - [x] Verification: `snes boot`'s `the enemy is drawn` phase, both halves — an object lands
        within a sprite of where the slot says the enemy is, and taking the slot away takes the
        objects with it. Watched failing both ways (170 and 172). `zig build verify` green,
        every floor unmoved, **and unmoved is the correct outcome**: no rung here grades a sprite
  - **What this cost the loop, written into `porting_loop.md` as arm two's step 6c:** when a
        mechanism puts a second thing on the screen, ask what was true only because there was
        one. Three things were, here — the `!SprX` alias, the placement of the clear, and every
        assertion the gate makes about `!OamIdx` and `!SpriteId` — and all three were correct
        when written and none said what it depended on

- [x] **Step 12e: B4c's first half — the explosion, the drop, and the slot that frees itself**
  - **Added 2026-09-09, ahead of the bombs, and the reason is that the gap is not inert while it
    waits.** A killed enemy sets `+$0E explosionFlag`; `EnemyCommonAI` has no handler for it and
    records it in `!EnUnhandledState`; and **the kill path never changes the slot's status**. So
    the corpse stays *active*: still drawn, still a projectile target, and every beam that
    touches it is deleted by `CollideProjEnemies` while `EnemyDamageOrDrop` sees the flag and
    does nothing. Measured on the shipped cart on 2026-09-09: a shot fired at an enemy 28 px away
    dies after **4 frames — identically whether the enemy is alive or a corpse**, which is 16
    pixels and reads from the player's seat as "no beam left her weapon". **The first kill in a
    room leaves an invisible beam-trap**, and combat degrades from there. That is what makes this
    a blocker for hand playtesting rather than a missing animation
  - [x] Port `enemy_animateExplosion` (02:$56BF): the animation counter, both sprite
        progressions — normal from `SPRITE_NORMAL_EXPLOSION_START` and the screw attack's from
        its own base — the extra frame non-health drops get, and `.becomeDrop`
  - [x] Port `enemy_animateDrop` (02:$5692), which is the other arm `EnemyCommonAI` records as
        unhandled today (`+$0D dropType`), and the drop collection half of
        `enemy_getDamagedOrGiveDrop` that Step 12b already ported is its consumer
  - [x] **The RNG, and it is a substitution rather than a port.** `.becomeDrop` reads `rDIV`, the
        Game Boy's free-running divider, for its 50% drop-nothing roll. The SNES has no
        counterpart. Use **`!EnFrame`'s low bit**: the same kind of quantity, read the same way,
        and it keeps the cart deterministic against the reference the way every other rung needs.
        Record it as a substitution in `residue.zig` and the ledger, not as a port — the one thing
        that must not happen is a later reader believing `rDIV` was ported
  - **Amended 2026-09-12. The approved source was `!FrameCount`'s low bit and it could not
    work**, which is a reading of the call site rather than a measurement: `.becomeDrop` runs
    inside `ProcessEnemies`, `!EnSame` toggles once per call, and `ProcessEnemies` is called on
    every frame whose door index is zero — so the pass only ever *acts* on one frame parity, and
    `!FrameCount & 1` is a constant for as long as Samus stays in the room. Every kill in a room
    would roll the same way: all drops or none. `!EnFrame` is the port's `$FFFE`, incremented once
    per acting pass at 02:$40B2, and it is the counter the neighbouring `enemy_animateDrop` reads
    at 02:$569F for its own blink — so its low bit alternates between passes and the roll varies
    with when the shot lands. **James chose it on 2026-09-12** over shipping the approved source
    with the collapse recorded as a divergence
  - [x] The sprite ids the two progressions and the three drops are built from, **read out of the
        `ADD A,d8` and `LD A,d8` sites that carry them** rather than transcribed, the way Step
        12a's block constants and Step 12b's twenty-six are. `correspond.zig` gets the rows
  - [x] Verification: `snes boot` grows a phase that kills a slot outright and asserts three
        things — it runs the explosion frames, **its slot frees**, and a beam fired through where
        it was now flies on. The third is the half that fails today and the reason this step
        exists; watch it fail with the explosion arm removed

- [x] **Step 12f: the enemy AI arms the region needs**
  - **Added 2026-09-09, from the same playtest.** `EnemyCommonAI` dispatches through a table of
    ported arms and records anything else in `!EnUnhandledAi` rather than jumping through a Game
    Boy address. Step 10 ported three — null, the small bug, the Senjoo — plus B6's item orb.
    Everything else spawns, draws, collides, takes damage and **sits still**. The frog on the
    second screen of the landing-site region is one: measured 2026-09-09, `!EnUnhandledAi` reads
    nonzero there and the enemy never moves a pixel in 300 frames
  - **Amended 2026-09-13, on a survey, three decisions James made.** The spawn lists cannot
    answer "which AIs": over the published route they name 6 AIs, over the recording's
    64-frame census 13, and with neighbour screens added — which the loader does read — 20,
    including Gamma and Zeta. The census is lossy and the neighbour rule over-counts. So:
    (1) **the set is measured off the running Game Boy**, not read out of the data; (2) **one
    step**, committed per AI, not split by route; (3) **the rung is a static table check**, not an
    emulator walk over cells
  - [x] Enumerate the AIs the recording actually dispatches: a `gbtrace` accumulator that records
        every address the enemy AI `jp hl` reaches, frames 0–73 392 (through Alpha 2's death), in
        one pass. `entity.parseSpawnLists` stays the cross-check, and every census AI must appear in
        some visited cell's list or a neighbour's. The set lands in `docs/slice.md` with its method
    - **`zig build gbtrace -- ais 73400`, commit `6b57804`.** Thirteen AIs, identical to the
      spawn lists over the 64-frame census's cells, so the cross-check holds. Nine to port:
      `rockIcicle`, `crawlerA`, `crawlerB`, `gullugg`, `chuteLeech`, `pipeBug`, `hopper`,
      `wallfire`, `missileDoor`. `senjooShirk` is never dispatched by the recording — it stays for
      the segment rung
  - [x] **A Game Boy-vs-cart enemy slot oracle, before the second AI (James, 2026-09-13).** The
        static table check proves an AI is dispatched, not that it behaves. For each ported AI, spawn
        a cell it lives in on the Game Boy harness and on the cart, no input, and compare the slot's
        Y, X, sprite and state per acting pass over N frames. The Game Boy is the authority; each
        later AI is a row in its table, and each row is shown failing with the AI's `AiTable` entry
        removed
    - **`src/enemy_oracle.zig`, commit `8b1f72d`**, as `zig build oracle -- enemies` and the
      `enemy AIs` rung in `zig build verify`. Both machines get the *same slot* (the bytes
      `loadOneEnemy` would write for the cell's record under the settled scroll), not the same
      spawn walk, because the loader only loads as a camera edge crosses a record. Histories are
      compared per pass (runs of identical records collapsed), so the 30 FPS parity each machine
      booted into does not matter. The `AiTable`-blanked fault runs on every gate run
    - **Hopper landed with it**: 150 of 150 passes in `$A:$45`. Its arc tables are `physics` blobs
      — the file policy refused them inline — and its ledger rows were dropped by the
      instruction-boundary check, as the small bug's were
  - [x] Port that set, minus `enAI_hatchingAlpha` and `enAI_alphaMetroid`, which are Step 13's.
        One commit per AI, each with its `ledger.zig` rows and `residue.zig` entries
    - **All nine, 2026-09-13**, in six commits (`8b1f72d` hopper, `f77bd8a` crawlers, `0903d18` rock
      icicle and Gullugg, `2a098dd` Chute Leech, `aa7c0a2` pipe bugs, `94b8923` wallfire and
      missile door) — grouped where two AIs share their machinery rather than strictly one per AI.
      **Ledger rows were written for the first and dropped by the instruction-boundary check**, as
      the small bug's and the Senjoo's were: the observed run never executes these routines, and
      B3's rule is that such a row is dropped rather than weakened. `residue.zig` carries every new
      variable. Every ROM table is a `physics` blob; the two spawned headers (eleven and ten bytes)
      are engine data graded against the cartridge
    - **What the shared layer turned out to be**: eleven `enCollision_*` probes over
      `getTileIndex.enemy`, `!SolidEnemy` (the `SOLIDITY` row's second column, unread until now),
      the position mirror, both acceleration curves, `enemy_spawnObject.shortHeader`,
      `enemy_deleteSelf`'s parent link — which retired Step 9's `!EnChild` recorder — and the
      weapon direction `enemy_getSamusCollisionResults` hands on
    - **The oracle grew with the AIs**: four slots sampled and slot 0's children graded with it
      (the pipe bug's bug, the wallfire's fireball); tilemap and camera agreement checked at the
      seed and reported as room findings rather than AI failures; per-case projectile contacts
      written on both machines at the same tick (the missile door, the wallfire's death); a shorter
      faulted history counted as caught. Eleven rooms, all agreeing pass for pass
    - **Four findings, in `docs/bug_tracker.md`**: `ProcessEnemies` ran an AI on the pass that
      deactivated it (**fixed**, found by the first crawler case); the cart's camera moves where the
      Game Boy's does not in `$C:$21`, `$C:$31`, `$A:$42` and `$A:$22` (open, not diagnosed); in
      `$9:$E6` a neighbour loads one frame late on the cart (open); and the deliberately dropped
      `rLY` budget measured for the first time. Plus one `snes boot` exit 81 seen once and not
      reproduced in six standalone runs
  - [x] Leave the rest recorded rather than stubbed, which is what `!EnUnhandledAi` is for
    - The rest is the two Alphas; `enemy_oracle.step13` names them and the recorder is unchanged
  - [x] Verification: a build-time test reads the assembled `AiTable` and fails if any AI in the
        measured set is missing, less a named Step 13 exclusion list — so an AI arriving later is a
        build failure rather than an enemy that quietly does nothing. Shown failing with one row
        removed. `zig build verify` green
    - `enemy_oracle`'s "every AI the recording dispatches is ported, pending, or Step 13's" test,
      which also fails if a ported AI has no oracle case. Shown failing with the hopper put back on
      the pending list. `zig build verify` green on `94b8923`: every floor unmoved (reachable 1466,
      anchored 665, durations 28/28), which is correct — no movie rung grades an enemy AI

- [x] **Step 12c: B5's bombs — the second array, and the arm that lays one**
  - **Added 2026-09-09, carved out of 12b the way 12a was.** The bombs are arm two's own
    definition of a mechanism: `bombArray` at $DD30, `samus_layBomb` (01:$53D9), `handleBombs`
    (00:$549D), `bombs_samusAndBGCollision` (01:$54D7) with the block arm at 01:$553F, `drawBombs`
    (01:$540E) and `bombBeam_layBomb` (01:$53AF). None of it shares state with the projectile
    array, and the two arms that reach it from 12b — 01:$4EB4's ball pose and 01:$52CA's bomb
    beam — record into `!PrUnhandled` rather than branching into nothing
  - [x] Port the array, the timer, the explosion and the draw, in the original's order
    - **Done 2026-09-14.** `!Bombs` at $0630, directly after `!Projs` as $DD30 is after $DD00.
      `SamusLayBomb`, `BombBeamLayBomb` (one `FirstEmptyBomb` for their identical walks),
      `HandleBombs` → `DrawBombs`, `BombsSamusAndBG` and `CollideBombEnemies`/`CollideBombOneEnemy`
      (00:$30BB/$30EA, which the plan did not list: `drawBombs` calls them on the explosion's
      first frame). `handleBombs` is 01:$549D, not 00: — the listing's label is wrong about the
      bank. Both `!PrUnhandled` arms now branch where the original does. The slots are also
      cleared by `ClearProjectiles` (00:$21EF runs to the end of the page) and by
      `StartTransition` at 00:$0C55–$0C62, **which that routine's comment had been calling
      "entity slots"**. Forty-three constant sites graded in `correspond.zig`
    - **A 6c defect, found by reading before it could bite**: `DrawSamus` zeroed `!OamIdx`,
      and the bombs draw *before* her. The reset moved to `MainLoop`, where `waitOneFrame`
      (00:$2C5E) has it. In `docs/bug_tracker.md`
  - [x] The block arm at 01:$553F, which is `HitBlock`'s three tests with `BIT 6,A` in the third —
        so `!BLOCK_BOMB`, exported and graded since Step 12a, gets its first reader
    - **Amended on the ROM: two tests, not three.** The bomb arm has no `beamSolidityIndex`
      test; it goes straight from `CALL $2266` to `CP $04`. So it is `BombProbeTile`, not a
      reuse of `HitBlock`. And `collision_bombOneEnemy` has no damage test and grows the box
      $10 on all four sides — a bomb hits enemies a beam passes through
  - [x] Samus's own knockback from her bomb: `samus_bombPoseTable` (01:$55DD) is the one table in
        the 01:$55FB–$5671 run Step 12b did not pin, and this is what reads it
    - Physics blob 28, pinned by `21 DD 55` at 01:$551D. `PoseBombed` (Step 10) flies the arc
  - [x] Verification: `snes boot` grows a phase that lays a bomb from the ball and watches a bomb
        block go, with `!PrUnhandled` asserted to have been reached and then cleared
    - **Phase 18**, lever the fire button. The `!PrUnhandled` half reads as "stays $FF": the
      arms no longer record. It asserts the Bomb gate, one bomb per press held past the $10
      cooldown, the laid position, drawn first in OAM, fuse and explosion to the frame, and on
      the explosion's first frame a bomb-only tile of the room's own collision table gone, a
      respawning block reached at the right probe, Samus in the table's pose, and a zero-damage
      enemy that only the $10 pad on *both* axes reaches losing `weapon_damage[9]`. **Watched
      failing nine ways** (codes 185–195). The first 6-frame hold passed with the rising-edge
      gate removed — it was inside `samusShoot`'s cooldown — so the hold is 24 frames
    - **Two clears are ported and ungraded, measured**: with both removed the gate still passes,
      because a zeroed slot lies off the window and `drawBombs` deletes it on frame one. A boot
      check for it was written, watched *not* failing, and removed
    - `zig build verify` green; every floor unmoved (reachable 1466, anchored 665, durations
      28/28, enemy AIs 11 rooms), which is correct — no graded stretch lays a bomb. 262 ledger
      rows, all seven new ones surviving the boundary check

- [x] **Step 13a: B5 — missiles that fire: the new game's numbers on the cart**
  - **Added 2026-09-14, from a playtest, and split out of Step 13 with 13b–13d.** James pressed
    Select, the toggle changed mode, and nothing left the cannon. Measured: the boot record
    (`BootRecord`, `engine/main.asm`) has no energy, tank, missile or Metroid-count field, so
    `!CurMissLo`/`!CurMissHi` are zero on every cart and `samusShoot`'s missile arm (01:$4F22)
    takes its dud branch. The arm itself is ported and graded (Step 12b; the missile door in 12f
    is hit by missiles the oracle hands it). What is missing is the number
  - [x] Grow the boot record by the `loadGame_samusData` fields the port lacks — energy tanks,
        health, max and current missiles, `metroidCountReal`, `metroidCountDisplayed` — and seed
        them in `InitState` at the same offsets for both boot kinds. The displayed health and
        missile copies are seeded equal to the real ones, as `loadGame_samusData`'s writes do
    - **Done 2026-09-14 as boot record version 11**, 70 bytes: `BootTanks`, `BootHealth`,
      `BootMaxMiss`, `BootCurMiss`, `BootMetReal`, `BootMetDisp`, and `BootCannonChr` (below).
      `!MetReal`/`!MetDisp` are new variables at $01FB/$01FC, unread until 13b and 13d.
      **Amended: the displayed health and missile copies are 13b's**, because no variable for them
      exists until `adjustHudValues` is ported; 13b seeds them from the same record fields
  - [x] A new game (`BootMode` $01) takes them from `initialSaveFile` (01:$4E64), decoded by
        `save.zig` off the ROM the way `save.appearance` already reads the countdown — 99, 0,
        30/30, `$47`, `$39` are the expected decode, asserted, not transcribed. A handover boot
        takes tanks, max missiles and the real count from its trace and the new game's values for
        current health, current missiles and the displayed count, which the trace does not carry;
        the record's comment says which is which
    - `snes_screen.Loadout.newGame` off `save.initial`, set in `bootFor` and `chooseBoot` so every
      boot starts from it; `Loadout.Measured.over` lays a reference's measurements on top.
      **Better than planned for the published runs and the enemy oracle**: both run a Game Boy
      this repository owns, so `oracle.gbLoadout` reads all six at the handover. The recorded
      trace supplies its three columns. `snes_inject`'s new test pins 99, 0, 30/30, `$47`, `$39`
      and was watched failing with the displayed count off by one
  - [x] Check where the original's Select toggle and missile HUD icon interact with the pose
        (`samusActiveWeapon` $08, the missile-cannon sprite) and that the port's arm matches;
        record the answer
    - **The answer: the toggle was a recording, and two things were missing.** `toggleMissiles`
      calls `loadGraphics` (00:$2753), which swaps `gfx_cannonMissile`/`gfx_cannonBeam`'s two
      tiles into Samus's sheet at `vramDest_cannon` $8080, and `beginGraphicsTransfer` (00:$27BA)
      then spends one `waitOneFrame` -- so the play handler is split across two frames and the one
      between draws nothing. The port recorded `!CannonGfx` and did neither. Both are ported:
      `ToggleMissiles` resolves the blob and sets `!CannonHold`, NMI's `UploadCannonChr` copies it
      to `$6080`, and the next `MainLoop` resumes after `SamusTryShooting`. The HUD's missile icon is
      static tiles in `hudBaseTilemap`, not a weapon indicator, so it is 13b's and not this one's
  - [x] Verification: `snes boot` grows a phase that boots a new game, toggles to missiles with
        Select, fires, and asserts a missile slot with the missile's type, `!CurMissLo` stepping
        `$30` → `$29` in BCD, and a dud with the count forced to zero. Watched failing with the
        seed removed. `zig build verify` green; any floor that moves because a graded stretch now
        carries missiles records that as the reason
    - **Phase 19**, run between 17 and 18: forcing the stand pose onto the Samus the bombs throw
      left her in pose $07 for 600 frames, so the phase takes her standing from the shots. It
      boots the `snes boot` cart rather than a new-game cart, and checks at boot that the cart
      carries the new game's loadout (197) -- `cold boot` is the new-game cart and is unchanged.
      Codes 197-203, **watched failing seven ways**, each on its own code. An older check had to
      learn the stall frame: `checkSprite` asserts a nonzero OAM index and now allows a frame with
      `!CannonHold` up, as it allows an item pickup's first frame
    - `zig build verify` green; every floor unmoved (reachable 1466, anchored 665, durations
      28/28, enemy AIs 11 rooms), which is correct: no graded stretch presses Select, and seeding
      99 health and 30 missiles into every anchor moved nothing

- [x] **Step 13b: B13 — the HUD band**
  - **Added 2026-09-14, from the same playtest.** BG2 has been the HUD band since Phase 0a and
    nothing draws into it. Before the Alphas because the kills' consequences — the count, the
    missiles spent — are read there, and a death step graded without a HUD would be re-graded
    once one arrives
  - [x] Convert `hudBaseTilemap` (05:$40F0, 20 bytes) and the window's character tiles into the
        BG2 band, at the position the Game Boy's `rWX`/`rWY` ($07/$88) put it relative to the
        play window. Tile ids resolve through the same character set the window uses on the Game
        Boy; find where $9D–$AF come from before converting them
    - **Done 2026-09-14.** **$9C–$AF are Samus's own sheet**: `loadGame_loadGraphics` (00:$05FD)
      copies `gfx_samusPowerSuit`, $B00 bytes, to $8000, and the window names its top twenty
      through the $8800 window. `LoadHud` copies those twenty characters out of the 4bpp object
      blob into BG2's half at the same indexes. The only other id is `$FF`, the last tile of
      `gfx_commonItems`, which is all colour 0 on the ROM (a test says so), so BG2's char $FF is
      left cleared. `hudBaseTilemap` is `physics` blob 29, pinned by `21 F0 40` at 05:$4092
    - BG2's tilemap word `n` is the window's $9C00+`n`; `!HUD_HOFS`/`!HUD_VOFS` put word 0 at WX/WY,
      re-derived from the cartridge's operands in `correspond.zig`. **The band needed an HDMA
      split, which the plan did not name**: the window's colour 0 is opaque on the Game Boy and
      BG2's is transparent, so from WY down the band now takes BG3 off the main screen and puts
      BG2 on, and the backdrop -- BGP's first shade -- shows through
  - [x] Port `VBlank_updateStatusBar` (01:$493E): tanks and `E`, the health digits, three missile
        digits, the Metroid count, its scrambled arm and the shuffle timer's countdown. The Queen-room destination and the pause
        L counter are out of scope (B13). The scrambled arm reads `rDIV`; choose the substitute on
        a measurement at the call site, as 12e did, and record it
    - **Done 2026-09-14, in NMI, gated by 00:$0154's chain** (`StatusBarDue`): a VRAM transfer
      (`!CannonHold`), a door, or a map row queued this frame skips the bar and its timer. The
      last needed a flag the port did not have, `!MapUpdate` (`mapUpdateFlag`, $DE01), because
      `!Redraw` is also raised by the blocks, which the Game Boy writes outside that queue
    - **The `rDIV` substitute, measured**: DIV at 01:$49F9 on 120 status-bar frames of our Game
      Boy advances $12 on 82 and $13 on 37 -- 274.3125 counts a frame, 70224 CPU ticks over 256.
      So the port keeps `!DivClock`, an 8.8 accumulator NMI advances by $1250. `hud_oracle`'s DIV
      test re-measures it. The scramble's `DAA` on a raw divider is `GbDaa`, the Game Boy's exact
      correction, because decimal mode only agrees with it on decimal operands
  - [x] Port `adjustHudValues` (01:$4A2B), the displayed-toward-real roll for health and
        missiles, including its BCD clamp and its sound requests. Its displayed copies are new
        variables; `InitState` seeds them from `BootHealth` and `BootCurMiss`, as
        `loadGame_samusData` does (moved here from 13a)
    - **Done 2026-09-14.** `sfxPlaying_square1` is `!Sfx1Playing`, which no driver writes, so the
      health tick always asks. Called at 00:$0553's place in the play pass and on transition
      frames, which the original's handler also reaches
  - [x] Port `drawHudMetroid` (01:$4B2C) and its sprite from `samusSpritePointerTable`: $98, or
        $90 on a save point or during a major item, X $80, frame from `frameCounter` bit 4. Call it
        from every site the original does — `gameMode_Main` (twice), `gameMode_Paused`,
        `gameMode_dying` and `handleItemPickup_end` (twice), six `drawHudMetroid_longJump`
        calls — and place the OAM write where the original's order puts it relative to
        `drawSamus`, the bombs and the enemies
    - **Done 2026-09-14, amended on the ROM: three of the six sites are not in the slice.**
      `gameMode_Main`'s second call is its `.queenBranch` (being eaten), `gameMode_Paused`'s is
      inside `.debugBranch`, and `gameMode_dying`'s runs only in the Queen's room. The port
      calls it where the play pass (00:$0560) and both pickup wait loops (00:$3A04, $3A63) do --
      the port's `.itemFrame` is both loops -- and on transition frames. After the blocks and
      before the enemies, so the icon's two objects sit between Samus and them
    - **One liberty, in scratch**: it puts back `!SpriteId`/`!SprX`/`!SprY`, which the original
      leaves holding the icon and nothing reads before the next write. `snes boot` reads them at
      the end of a frame, and the first alternative -- a memory callback -- made that script
      nondeterministic (`docs/bug_tracker.md`). `!SaveContact` is new and unwritten until B7.
      **During a major item the icon rises a row above a band that does not**: the window raise
      is still `!ItemWindow`'s recording (B6), which a playtest will see
  - [x] Verification: a Game Boy reference render of the status-bar row — our emulator running
        `VBlank_updateStatusBar` over chosen value sets, one of them from a trace frame — compared
        tile for tile against the cart's BG2 row seeded the same way; the scramble graded by the
        frames it starts (timer below `$80`) and stops (zero), not by its digits; the icon's
        major-item rise graded, the save-point rise left to Step 15; and `snes boot` asserting the roll
        takes one unit a frame and the icon swaps on bit 4. Watched failing with a digit's `add $A0`
        off by one and with the icon's frame test inverted. Every sprite rung re-run; any move
        recorded with its reason
    - **`src/hud_oracle.zig`, in the gate as `status bar`**: both machines stand Samus still at
      the landing site, take the same pokes at the same point of the same tick, and after every
      tick the Game Boy's twenty window tiles are compared with the cart's twenty BG2 words, with
      the displayed counts, the shuffle timer, the camera and the counter alongside. 281 ticks:
      eleven static sets (every digit in every cell, zero to five tanks), two rolls across a
      hundreds boundary, both clamps, and a kill's $C0 counted to zero **with a walk inside it**
      -- which is what grades the map-row skip, 8 ticks the timer did not move on either machine.
      The count cells are masked on ticks the scramble drew and nowhere else. The fault (the
      digit base one high) differs on every run
    - **Amended: the trace frame is Mesen2's, not a trace column.** No trace carries health or the
      window, so `gb_trace` grew a HUD pass that replays James's recording and reads the window
      row with its bytes; three frames (45 101, 48 601, 74 001: after the Missile Tank, the Energy
      Tank's refill, the second Alpha) and the cart draws each row the same. It costs the gate
      about two minutes and is skipped without the recording
    - **Two probe facts, measured**: the cart is sampled after `MainLoop`'s `wai` (NMI draws the
      bar, so a poke before NMI is drawn un-rolled), and that sample point needs the counter seed
      one lower than the enemy oracle's -- a compared byte, so checked every tick
    - `snes boot`: codes 204-209 (the band's pixels are BG2's window tiles, the icon in OAM, its
      frame on bit 4, its rise through the Bomb's jingle, the roll a unit a frame, the tick on
      every fourth), each **watched failing** on its own code. The oracle was watched failing with
      the map-row gate removed, the roll off the play pass, the scramble threshold one high and
      full tanks from the wrong byte
    - **Every sprite rung re-run, and four fixtures moved with a reason** (`docs/bug_tracker.md`):
      the part count, phase 15's objects-past-Samus, phase 19's dud request and cold boot's
      flicker share all assumed Samus was the last thing drawn. **And a memory callback made
      `snes boot` nondeterministic**, which is why the icon checks read the counter at the end of
      the frame. `zig build verify` green twice; every floor unmoved (reachable 1466, anchored
      665, durations 28/28, enemy AIs 11 rooms), which is correct: no graded rung compares OAM
      beyond Samus's parts or the HUD's pixels

- [x] **Step 13c: B4c — the Alpha alive: the intro, the lunge, and the knockbacks**
  - [x] The Metroid globals the port does not have: `metroid_state`, `metroid_fightActive`,
        `cutsceneActive`, `alpha_stunCounter`, `metroid_screwKnockbackDone`, with every clear the
        original makes (`inGame_loadEnemySaveFlags` 02:$412F, `deactivateOffscreenEnemy`'s
        `.seenEnemy` 02:$452E, `handleCamera_door`'s `.endDoor` 00:$0B44)
    - **Done 2026-09-14**, at $067C-$0680, with the angle routine's six scratch bytes and
      `!MetSong` beside them. The clears are in `ResetEntities` (02:$412F), `DeactivateOffscreen`'s
      `.seen` (02:$45BB -- it also clears `metroid_postDeathTimer`, 13d's) and
      `TransitionCamera.finish` (00:$0C28). **Not ported, and 13d's**: `enemyHandler`'s case-1
      arm (02:$4000), which clears the fight when a transition starts mid-fight. It sits inside
      the music restore and the room load clears the same two bytes a few frames later
  - [x] `cutsceneActive`'s two readers: the turnaround clear in `gameMode_Main` (00:$04DF) and the
        dummy input in bank 1's `drawSamus` neighbourhood (01:$4BD9 — locate the exact routine
        before porting) that freezes Samus while a Metroid appears
    - **Located: both are inside the routines the plan named.** `gameMode_Main`'s arm is 00:$050B:
      it clears pose bit 7, lets Select through to `toggleMissiles`, and jumps to $053E, past the
      whole Samus block. `drawSamus`'s reader is 01:$4C05, where the pad is not read and the
      facing is the whole draw byte. `MainLoop` gained the arm, and `!CannonHold` a second value
      so a toggle made in a cutscene resumes at $053E rather than inside the Samus block
  - [x] `enAI_hatchingAlpha` (02:$6BB2) and `enAI_alphaMetroid` (02:$6C44) with every branch
        except `.death`: the flash-and-range wait, the face-screen and rise (borrowing
        `enAI_zetaMetroid.oscillateNarrow`, 02:$75EC), `.startFight`, `.checkIfInRange` and the
        seen flag `$04`, the shot reactions (beam dink, screw, missile hurt with its stun and
        knockback), `.standardAction`'s lunge cycle, `.lungeMovement` on the `farWide` probes and
        `.animate`
    - Done, and the four `.farWide` probes with them (`EnProbeWide`: four points, strides 8, 6, 8)
  - [x] `metroid_screwReaction`, `metroid_screwKnockback`, `metroid_missileKnockback` and
        `enemy_toggleVisibility` (02:$7DF8)
  - [x] `alpha_getAngle` (01:$70BA, with `metroid_getDistanceAndDirection` and the angle table)
        and `alpha_getSpeedVector` (01:$71CB, the 16 sign-magnitude pairs as a `physics` blob
        pinned by its load site)
    - Physics blobs 30 and 31. **The speed blob is the sixteen arms whole**, `01 cc bb C9` each,
      because they are code: the jump table at 01:$71DB pins them contiguous and
      `correspond.zig` checks every arm. The angle table is pinned by `21 58 71` at 01:$7131. The
      slope's multiply and divide are the same products; see `MetroidSlopeToSamus`
  - [x] The hurt reaction's `rDIV` reads take 12e's substitute, `!EnFrame`, **re-measured at this
        call site** rather than assumed; if its parity is constant here the choice reopens
    - **Not constant, measured on the cart**: `snes boot` phase 21 lands six missile hurts a pass
      apart relative to the stun's end and requires the coin to be `!EnFrame`'s low bit and to
      come up both ways (214, 215). **But it cannot agree with the Game Boy, and the plan's
      verification assumed it would**: a hurt's second knockback axis comes out of `rDIV`, so an
      oracle case that shoots an Alpha diverges at the first hurt whose coins differ -- measured,
      `alpha shot`'s third. So the oracle hands the cart the Game Boy's coin (`enemy_oracle.Coin`)
      on the pass the cart's own hurt lands, masked to the tossed axis only
  - [x] Song requests write the recorded id and nothing more (F8); `.death` records into
        `!EnUnhandledState` until 13d
    - `!MetSong`, not `!Song`: the door opcode's recorder has a fixture reading it. The
      `songPlaying` guard is named in the routine's comment rather than written, because no
      driver writes that byte
  - [x] Verification: `zig build oracle -- enemies` gains the hatching Alpha in `$F:$11` (the
        intro, Samus frozen, the fight starting) and the Alpha in `$E:$07` (the quick path and the
        lunge), plus a case with missile contacts at fixed ticks that stun without killing. Each
        agrees pass for pass and each faulted cart differs. `enemy_oracle.step13` shrinks by the
        two AIs
    - **Two rooms moved.** The hatching Alpha's record is in `$F:$10`, next to the census's cell.
      From the middle of `$E:$07` Samus is never in range, and the oracle stands her still, so
      the plain Alpha is graded in `$E:$B2`, from three places she stands (a Case gained
      `samus_dx`) and shot there: a beam, four missiles from four directions, a screw attack.
      Five cases, 286, 300, 300, 467 and 290 passes, all agreeing, every faulted cart
      differing. `step13` is empty
    - **A sampler defect found first** (`docs/bug_tracker.md`): the Game Boy's tick stopped only
      inside the Samus block the cutscene skips, so the intro was sampled sixteen frames a tick.
      `stepToLogicPoint` also stops on the cutscene arm's exit, 00:$0520
    - **"Samus frozen" is not the oracle's to see**, since it stands her still: `snes boot` phase
      21 holds a direction during a raised `!Cutscene` and requires no movement (210), no
      turnaround (211), no pad in the sprite (212), and Select toggling past the Samus block
      (213). Faults watched failing: no cutscene arm, no bit-7 clear (211 each), the pad read
      (212), the hold not raised to the cutscene value (213), the coin off `!FrameCount` (214)
    - Engine faults in the oracle cases, by hand: quadrant base +1, slope band, no oscillation,
      the missile knockback's ceiling -- each caught. **A middle stride of 8 in `EnProbeWide` was
      not**: no terrain in these rooms sits where that point moves; the operand is graded by
      `correspond.zig`
    - No `ledger.zig` rows, as in 12f: no run the ledger observes dispatches an Alpha, so the
      instruction-boundary check would drop them
    - `zig build test` quiet and green; `zig build verify` green, `enemy AIs` 11 → **16 rooms**,
      every other floor unmoved (reachable 1466, anchored 665, durations 28/28, status bar
      281/281), which is correct: no graded stretch meets an Alpha

- [x] **Step 13d: B4c — the Alpha's death, and two of them killable**
  - [x] `.hurtReaction`'s health reaching zero and `.death`: the explosion sprite, `metroid_state`
        `$80`, `metroid_fightActive` `$02`, spawn flag `$02`, both counts decremented in BCD and
        the shuffle timer set to `$C0`
    - **Done 2026-09-14** at 02:$6D61, with the jingle recorded in `!MetSong` ($0F) and the BCD
      through decimal mode, which agrees with `SUB $01 / DAA` on the decimal operands both counts
      hold (`GbDaa` stays the scramble's)
  - [x] `enemy_commonAI`'s `metroid_state $80` test and `enemy_metroidExplosion` (02:$5732): the
        cutscene freeze, `.forceOnscreen`, four explosions moved by state, the collision clear and
        the permanent delete. `!EnUnhandledState`'s Metroid arm is retired
    - `EnemyMetroidExplosion`, including the two arms no kill in the slice reaches -- a child
      projectile deleted on the spot, and any non-explosion slot sent back to its own AI, which is
      every other enemy in the room while a Metroid dies
  - [x] `enemyHandler`'s post-death timer and music restore (02:$4000) and the loader's
        clear, so a room entered after a kill is not still in a fight
    - `HandleEnemies` gained 02:$4029-$4062 ahead of the room load, with `!SpawnReload` standing
      in for `justStartedTransition`: both are raised by `loadDoorIndex` (00:$0C37) and serviced on
      the same pass. `!MetPostDeath` is new, and `DeactivateOffscreen`'s `.seen` clears it
      (02:$45B8). The loader's clear was already 13c's (02:$412F). **A finding, recorded in
      `residue.zig`**: a transition during the post-death wait clears the fight flag and not the
      timer, so the restore never runs and the next kill's wait starts part-way -- the original's
  - [x] `earthquakeCheck` (08:$7EBC) is Step 14's: it records that it was reached, the way
        `!PrUnhandled` did before 12c
    - `!QuakeAsked`, holding the real count it was called with; `$FF` until a kill
  - [x] Two Alphas are killable in the region, which is what D2's *second* kill requires
    - Both AIs die through the same `.hurtReaction`, and each is killed by its own oracle case:
      the hatching Alpha in its own room `$F:$10`, the plain one in `$E:$B2` for 13c's reason
      (from the middle of `$E:$07` a standing Samus is never in range)
  - [x] Graded against Step 8's recorded run — the published runs kill nothing inside their
        horizons, which the spike measured — through an oracle case that kills the Alpha with
        missiles at the recording's own ticks and agrees through the slot's deletion, with
        `$D089` and `$D09A` compared on both machines
    - **The ticks are measured, by a fifth `gb_trace` pass**, `zig build gbtrace -- kills <first>
      <last>`: a record on every frame a fight's state moved. Alpha 1: fight at 16 265, missiles at
      +288, +354, +414, +511, +623; Alpha 2: fight at 72 894, a beam at +2 and missiles at +86,
      +144, +344, +440, +496 (`docs/slice.md`). `hatchingAlpha kill` (1240 ticks) and `alpha kill`
      (840) run those shots from their own fight's start, **through the deletion and all $90 steps
      of the post-death timer to the restore**, and both agree with every faulted cart differing
    - **The rung grew two things to do it.** Seven Metroid globals are compared per case --
      the timer, state, freeze, stun, fight flag, `$D089`, `$D09A` -- each as its own collapsed
      history; and the cart writes a record only when it changes, with its tick, because a kill
      waited out is longer than one save file of per-frame records. Every earlier case still agrees
    - **Measured, and why the globals are collapsed rather than per frame**: with the frame
      counter compared as well, the counters agree on every tick but the killing pass runs at $D4
      on the Game Boy and $D5 on the cart -- the pass parity the rung already calls a property of
      the boot -- so the cart's timer steps a frame sooner. Not a port defect, and `snes boot`
      grades the even-frame rule directly
    - Faults by hand, `alpha kill`: no `$80` test, no displayed-count decrement, the first blast
      moved right, the timer to $91, the restore keeping the fight, no delete -- each caught. The
      edge clamp at $17 was **not** (no blast here reaches an edge); `correspond.zig` now checks
      all 29 of the death's, explosion's and restore's operands against the cartridge, and caught it
  - [x] Verification: a `room.zig` scenario kills an Alpha and asserts the death sequence ran and
        the slot freed; the HUD's count reads one lower; the recorded run's floor is re-measured;
        the feature tracker updated. The HUD's scramble runs from the kill's `$C0`. The Senjoo contact entry in `docs/bug_tracker.md` is
        re-read against what this step learned about contact and left open or closed on that
    - **Amended: `snes boot` phase 22, not a `room.zig` scenario**, for 13c's reason -- `room.zig`
      drives the Game Boy, and the oracle cases already kill both Alphas on it. Phase 22 kills an
      Alpha on the cart twice (from a real count of $10, then $01) and asserts what the oracle
      cannot see: the death's flags, sprite and jingle (216); both counts in BCD, the shuffle and
      the earthquake recorder (217); the freeze, the six frames, four blasts and the freed slot
      (218); the timer on even frames only, every second frame, to $90 (219); the restore's song,
      and none with no Metroids left (220); the fight ended and the band's count one lower once
      the shuffle has run out (221); and a transition ending a fight with the song asked for, and
      not without one (222). Codes mapped in `verify.zig`, which had also never mapped 13c's
      210-215. Watched failing: 216, 217, 218, 219, 222 and twice for 220 (the song's source, and
      asking with none left), each on its own fault
    - Feature tracker (B4, B8), `docs/slice.md` and the Senjoo entry updated; that entry is **left
      open** -- the kill cases meet Samus but compare the slot, and a touch is `.standardAction`,
      which a slot history cannot tell from no contact
    - **The recorded run's floor, re-measured: unmoved at 371 of 699 frames across 3 stretches**
      (`zig build oracle -- recorded`), which is correct -- nothing in its first 900 frames meets a
      Metroid. `zig build test` green; `zig build verify` green, `enemy AIs` 16 → **18 rooms**,
      every other floor unmoved (reachable 1466, anchored 665, durations 28/28, status bar
      281/281)

- [x] **Step 14: B8 — the Metroid progression chain**
  - [x] `metroidCountReal` decrements per kill; `metroidCountDisplayed` shuffles toward it on its
        timer rather than snapping. The spike pins the starting values: `$D089` is `$47` and
        `$D09A` is `$39` at the movie's frame 6
    - Already delivered by 13b (the shuffle) and 13d (the decrements), graded there. Nothing new
  - [x] `nextEarthquakeTimer` arms after a kill, the earthquake fires on its delay, and the music
        interruption **path** fires and restores. A silent stub is the expected outcome — F8 is
        Phase 0c. **As of 2026-09-05 the shim cycle has proven two pulse channels on hardware but
        changed nothing here and chose no Phase 0c path**
        (`.local/docs/2026-09-01-gb-apu-spc700-shim/04-verdict.md`), so the stub stands. What this
        step asserts is that the interruption path fires and restores against the recorded id
        Step 5's `SONG` stub keeps — an assertion that survives whichever driver lands later.
        If 0c has landed by then, the track plays and that is recorded as a bonus
    - **Done 2026-09-15, `4cdddec`.** Measured first on the recording (the kill pass now watches
      the quake bytes): the first kill arms 3, a tick is lost to a blocked frame, the quake runs
      17 724–18 250 with the driver's byte `$0E`, and **the second kill starts none** (`$45` is not
      a threshold). Ported: `earthquakeCheck`, the countdown, the shake of `scrollY` and of Samus,
      the end's restore, and the `SONG` opcode's quake arm. `songInterruptionPlaying` is written
      where the request is made, standing in for the driver's acceptance, which was measured
      rather than modelled. 0c has not landed; the path is recorded, not played. Graded by
      `snes boot` phase 23 (225–229, five faults caught), the kill cases comparing
      `nextEarthquakeTimer` with the Game Boy, and `correspond.zig`. The quake's 255 steps do not
      fit the enemy oracle's cart record, so they are graded by rule on the cart and not by history
  - [x] Implement the `IF_MET_LESS` door opcode for real, and demonstrate the `$46` threshold
        reaching content that was unreachable before the second kill — which is consistent with
        the counter starting at `$47` and two kills reaching `$45`
    - **Amended on a ROM read, 2026-09-15: the first kill, not the second.** 00:$254A is `CP B`
      with the operand in A, then `JR NC`, so the branch is taken at or below the operand and
      `$46` opens at `$46`. `transition.zig`'s decoder always had it right; `docs/slice.md`,
      `residue.zig`, `dispatch.zig` and the feature tracker carried "two kills" and are corrected.
      The earthquake's first threshold is also `$46`. Engine: taken branch jumps (`StartDoorScript`),
      one frame either way. A new transition test runs door `$04A` on the Game Boy at `$47`, `$46`
      and `$45`, and found the model charging a taken branch's re-entry twice (fixed). Committed
      `b6ad829`
  - [x] If Step 1 found a lava/acid drain in the region, exercise the `lavaCaves` tileset swap
        between Mid, Empty and Full. If not, the deferral Step 1 recorded stands and is cited here
    - `snes boot` phase 23 drives door `$04A` at `$47`/`$46` (tables 8, 6) and door `$0D9` at
      `$47`/`$46`/`$42` (7, 8, 6), checking the frames, the destination and the table; shown failing
      against the stub (224 at `$46`, table 8) and against the strictly-less reading as a fault
  - [x] **The playtest's acid room (added 2026-09-15, `docs/bug_tracker.md`).** The room to the
        right of the first save point comes up full of acid. Before it is called a defect, find the
        door and read what the Game Boy showed there in the recording: at a count of `$47` door
        074 is meant to fall through to `TILETABLE 8`, so "full" may be correct. If the cart
        differs, a failing fixture goes in first and is shown failing; if not, the entry closes
        with the measurement
    - **The cart differed after a kill**: the stub never branched. Graded against our Game Boy's
      interpreter rather than the recording (the door's table is a property of the script and
      the count, and the interpreter is the authority for both). Entry closed, with a question to
      James: if the Alpha was still alive, full acid was correct there. **Found on the way**:
      `checkSprite` failed one crossing in sixteen on the `END` frame (bug tracker)
  - [x] **The latched room readout (B10, added 2026-09-15).** A toggle, off by default, drawing
        the map bank, the cell and the loaded metatile table id, latched when a transition ends.
        It is drawn where no rung grades, and a `snes boot` phase checks that the latched values
        are the ones the transition wrote and that nothing is drawn with the toggle off
    - **`64e1950`.** L held + R shows `B:CC T` in hex in the top border on BG1 (the reserved
      layer), put on the border's band by a WRAM copy of the HDMA table. Latched on *any*
      change of the three, not only a door's end, since a scroll crossing changes the cell too;
      between changes the picture is still. Phase 24 (230–232), three faults caught. **Found on
      the way**: uploading its font at boot shifted every later frame by one, and phase 16's
      drop check failed on that alone. The font now goes up on first use; the check's boot
      sensitivity is an open bug tracker entry
  - [x] Verification: a scenario kills two Alphas and asserts the count, the displayed shuffle,
        the earthquake timer, and the `$46` transition; each assertion fails when its mechanism
        is removed
    - **Amended, as in 13c and 13d: `snes boot` phases, not a `room.zig` scenario.** Phase 22
      kills twice on the cart and asserts both counts, the shuffle and `nextEarthquakeTimer`
      (3 at a threshold, untouched at `$00`). Phase 23 grades the gates and the quake, and the
      enemy oracle's two kill cases compare the countdown with the Game Boy's. Faults watched
      failing: strictly-less gate (224), no countdown (225), timer every frame (226), shake
      stuck (226), no held song (228), no restore (229). `zig build test` and `zig build verify`
      green; every floor unmoved (reachable 1466, anchored 665, durations 28/28, enemy AIs 18,
      status bar 281/281, recorded run 371 of 699), which is correct: no graded stretch meets a
      kill or a `$46` door below `$47`

- [x] **Step 14b: B6 — Spider Ball, which the route to the second Alpha needs**

  **New, 2026-09-15, from a playtest.** Step 11 deferred the spider poses to Phase 1 because
  nothing it graded reached them; James found on hardware that the second Alpha cannot be reached
  without them, so the hardware pass could not pass (Step 17 then; **Step 27** since the defect
  steps were inserted on 2026-09-15). Before Step 15, so the save/load work and the audit
  are done over an engine that can play the whole slice.

  - [x] Measure first: from the recording's trace, the stretch from the pickup at 68 453 to the
        second fight at 72 894, list which of poses `$0B`–`$0E` it enters and on which frames, and
        which `!ITEM_SPIDER` sites in `HandlePose`/`SamusSpriteId` and the collision resolver it
        dispatches. That list is the step's scope; anything the route does not reach stays
        Phase 1's, by name
    - **Measured 2026-09-15, five stride-1 passes over 68 440-72 975.** `$0B` 1 151 frames and
      `$0E` 229, in banks `$C`, `$B` and `$9`; seven entries, all `$05`→`$0E` through the ball's
      Down (00:$1785); seven exits on A; one upward door crossed while rolling (`$C`→`$B` at
      71 100). **`$0C` and `$0D` are never entered.** The scope was widened past the list on
      purpose, and this is the reason: `$0B` and `$0E` branch into `$0C` the moment contact is
      lost, so porting only the two the route shows would leave a hard lock one ledge away on
      hardware. All four are ported; `$0C`/`$0D` are graded by the fixture, not the recording.
    - **The `!ITEM_SPIDER` sites were not missing, they were mislabelled.** Every Down arm into
      the spider (00:$1788 `$05`, 00:$1254 `$08`, 00:$17A8 `$06`, 00:$0ED4 `$12`) is `BIT 5,A`.
      The engine read `!ITEM_SPRING` in three of them, correct by accident until Step 11 fixed
      the mask, and skipped the fourth entirely: `$12` was dispatched to `$11`'s handler, which
      drops 00:$0ECB's Down and Up arms.
  - [x] Port the poses and the branches on that list, branch for branch with the original's
        addresses, with `ledger.zig`/`residue.zig` updated and the spider operands checked by
        `correspond.zig`
    - **`fd07635`.** The four handlers, `SpiderContacts`, `SpiderPoint`, the sprite arm, `$12`'s own
      handler (`PoseMorphBombed`), and the two tables as physics blobs 32 and 33. No ledger rows of
      their own — no run our Game Boy can make enters them — so the notes are folded into
      `HandlePose`, `PoseMorph` and `SamusSpriteId`. Nine `residue.zig` rows; `OnSolidSprite` has
      readers now (its address comment read `$C426`; it is `$C43A`). `correspond.zig` checks the
      fourteen probe operands, ten pose stores, the four `BIT 5,A`s, the five `LD HL` table loads,
      the sprite bases and `$12`'s pose-table entry
  - [ ] ~~Grade against the recording through the anchored sweep (`zig build oracle -- recorded`)
        at anchors inside that stretch~~ — **measured 2026-09-15 and replaced.** Run over
        68 440–72 940 against the pre-14b engine, every one of its 7 anchors was unbootable: map 3
        cell `$13` gets table 4 on the cart and the Game Boy shows table 9 on 399 of 399 tiles,
        which is Step 4's "the table is loaded state" finding that Phase 1 owns. The census also
        stopped after one of five passes, and the run took about two hours. Replaced, with James's
        agreement, by the sub-task below
  - [x] **A Samus oracle for the spider ball**, in the enemy oracle's shape: seed the same cell,
        placement, items and spider pose on our Game Boy and on the cart, drive the same pad, and
        compare Samus's position, pose and facing frame for frame. Cases chosen to exercise what
        phase 25 cannot: a climb up a wall, over an outside corner, across a ceiling, and a fall
        off contact into `$0C`. Shown failing with a fault in `SpiderContacts`' corner rotation
    - **Built as the segment oracle rather than beside the enemy one**, because the segment
      oracle already compares Samus frame for frame from a key schedule; `grade` became
      `gradeWith(phases, items)` and `reference` `referenceWith`, and the cart gets the item bit
      through `Take.pokes` at its first commit. `zig build oracle -- spider` and a `spider segment`
      rung in `zig build verify`: **847 frames, MATCH**, poses `$0B`/`$0C`/`$0E`, rounding the boot
      cell's ledge at 600, down its face, A off it, Down in the fall into `$0C` at 756 and attached
      at 757. Dropping the corner rotation diverges at 585–599. **Two limits, recorded:** there is
      no climb *up* a face in it (Up on that wall picks rotation 0 on both machines), and `$0D` is
      not reached by any input the schedule has
  - [x] Verification: ~~the recorded rung's floor for the stretch rises and names a mechanism other
        than the spider poses~~ (replaced with the spider segment, above); a fixture fails with the
        spider arm removed, shown failing first; `zig build verify` green; the feature tracker's
        Phase 1 deferral is withdrawn with the reason; the bug tracker entry closes
    - **Done 2026-09-15.** `snes boot` phase 25 (233–239), written first and shown failing on the
      Spring Ball arm (234), the unported dispatch (78) and `$12` as `$11` (239); faults caught:
      ungated 233, two pixels 236, pad release 237, attach keeping the arc 238. The corner rotation
      is **not** caught by phase 25 (a flat floor's midpoint sets the same bits), which is why the
      spider segment exists. `zig build test` 5951/5951 and `zig build verify` green in 5m53s,
      every floor unmoved (reachable 1466, anchored 665, durations 28/28, segment 700, enemy AIs
      18). **Found on the way:** the longer boot (two more blobs resolved) tripped phase 17's
      drop retry with 181, the open boot-sensitivity entry; the third try now waits one pass, which
      closes it. Phase 25 carves its own floor, because phase 24's door leaves the ball embedded in
      terrain, reading contact `$F`

- [x] **Step 15: B7 — save and load** *(split 2026-09-15 into 15a–15d; the top-level box closes
  when all four do — it did, 2026-09-15)*

  **Split on a read of the ROM against the engine, with James's agreement.** The sub-tasks as
  first written assumed the port could already reach a station, save, die and reload, and it can
  do none of the four: nothing sets `saveContactFlag` (the collision's two bit-7 tests are unported, and so is
  `miscIngameTasks`' Start arm, 01:$57F2); there is no writer
  (01:$7ADF, 01:$7A6C) and the header declares no SRAM; the title's Start never reads a slot
  (`titleScreenRoutine`'s magic check, bank 5) and nothing ports `loadSaveFile` (01:$4E33); and **Samus cannot die** — health
  reaches zero and nothing reads it (`killSamus` 00:$2FA2, `VBlank_deathSequence` 00:$2FE1,
  `gameMode_dead` 00:$36B0, `gameMode_gameOver` 00:$371B). James's scenario and the recording's
  reload both run through all four. Out, by name: the pause screen (`tryPausing` 00:$2C79, whose
  save-pillar exclusion is therefore moot), the title's slot cursor and clear option, and the
  debug menu's save. The cart uses slot 0.

  - [x] Bring a normal save station into the region per Step 1's finding, growing the region if
        that is what it costs. **Answered by Step 1, no growth:** `docs/slice.md` "Save stations"
        names `$F:$01` (door 486, `ITEM $0; END`) as B7's, and `$F:$F3` and `$F:$06` besides

- [x] **Step 15a: B7 — the station, and the save**
  - [x] Measure first, on the recording: the frames of its saves (the census's cart-RAM writes
        into `$A000`–`$A03F`), the room each is in, and for one of them the frames from contact
        to Start to `COMPLETED` clearing. Decode each written record with `save.fields` and check
        its position, bank and `$D089` against the trace's columns on that frame — which grades
        `save.zig`'s layout against the game rather than against itself
    - **Five saves, one shape** (`zig build gbtrace -- saves`, new): Start on N sets mode `$09`
      and the cooldown `$FF` on N, the slot is written on N+1 with the cooldown untouched, the
      contact holds 255 frames. At 23 001 (`$F:$04`, not `$F:$01`), 41 551, 50 109, 61 521 and
      76 419 (`$D:$26`). The first record decodes to the trace's own columns, pinned as a
      `save.zig` test. The same pass has the death and reload for 15c/15d. `docs/slice.md`
  - [x] Port the contact: the save bit's test at both collision probe sites setting `!SaveContact` to
        `$FF`, and every clear — the door's (`executeDoorScript` 00:$239C: its entry, and the
        `LOAD`/`COPY` arms, which clear `saveMessageCooldownTimer` too), and the window arm's own.
        Addresses pinned from the ROM, not from M2RoS: **the engine's `!SaveContact` comment
        cites "00:$5265, $5325, 00:$1912", which are M2RoS source line numbers** — fix it
  - [x] Port `miscIngameTasks`' save arm: the cooldown's decrement, the window raise, Start's
        rising edge taking the save with the cooldown at `$FF`, `COMPLETED` while the cooldown
        runs and the blinking `PRESS START` (bit 3 of the frame counter) after it, both at
        `$98`,`$44`. The two sprite ids `$42`/`$43` go through the sprite conversion if they are
        not already in it
    - `SaveStation`, ahead of the quake. The OAM index is now zeroed above it, since the text is
      the first thing drawn. The two ids were already converted. **The text's tiles are the item
      font at `$C0`, which the port does not load** (the `ITEM` opcode's graphics arm, deferred
      with the item text since Step 11), so on the cart the parts are placed and drawn from
      whatever is in those characters. Recorded rather than silently accepted; James's playtest
      will say whether it matters before 17
  - [x] Port the writer, 01:$7ADF and 01:$7A6C, into SNES save RAM laid out **byte for byte as
        the Game Boy's**: the magic and record at slot offset `$00`, the file counter at `$C0`, the
        seven banks' spawn flags at `$1000` (the Game Boy's `$B000`), so `save.zig` decodes the
        cart's `.srm` with no second layout. The saved half of the spawn flags (`$02` and `$FE` as
        they are, `$04` as `$FE`) is written into a WRAM save buffer the way the original's is.
        Header SRAM size set; `residue.zig`/`ledger.zig` rows; `correspond.zig` checks the
        record's source order against `save.fields`
    - Done, and two things the sub-task did not know it needed. **The save buffer's pointers were
      gone from the cart**: a converted `COPY` kept an asset id and dropped the Game Boy's bank
      and address, so it now carries them (8 → 11 bytes), and the `TILETABLE`/`COLLISION`
      pointers come from two new physics blobs (`metatile_pointers`, a new `offsets.zig` entry
      at 08:$7F1A, and `collision_pointers`). **And 02:$418C's per-bank half was never ported**:
      the saved spawn flags were one array across all seven banks. `ResetEntities` swaps them
      now. Plus the in-game timer, which the record carries. No `ledger.zig` rows: no run our
      Game Boy makes reaches these addresses, as with 14b. `correspond.zig` checks ten constants,
      the save bit, the magic, and all seventeen single stores against `save.fields`
  - [x] Grade the HUD Metroid icon's save-point rise (`drawHudMetroid`'s `saveContactFlag` arm,
        ported in Step 13b and ungradable until now)
    - The per-frame HUD check (code 207) counts the contact now; it failed on phase 26 before it
      did, which is the rise being reached for the first time
  - [x] Verification: a `snes boot` phase stands Samus on `$F:$01`'s save tile, presses Start,
        reads the cart's save RAM back and decodes it with `save.zig` — position, bank, energy,
        items, both counts — shown failing first against the unported writer; faults caught for
        no contact, no door clear, Start ungated by the cooldown, and one field out of order.
        `zig build test` and `zig build verify` green
    - **Done 2026-09-15.** Phase 26 (240-245) lays save-station tiles from the loaded collision
      table under her rather than walking to `$F:$01`, the way phase 25 lays its floor. Shown
      failing first with the writer absent (241); faults caught: no contact 240, two fields
      swapped 242, `$05` saved as `$FE` 243, Start ungated 244, no transfer clear 245. Two
      existing checks had to learn about the station, and that was the rise being reached: the
      HUD's 207, and the OAM part count (123/124), which now allows for the text drawn ahead of
      her. `zig build test` and `zig build verify` green twice; every floor unmoved (reachable
      1466, anchored 665, durations 28/28, segment 700, spider 847, enemy AIs 18, status bar
      281/281), which is right: no graded stretch stands on a station or crosses a bank with a
      changed spawn flag

- [x] **Step 15b: B7 — the load**

  **Amended 2026-09-15 on a read of the boot path, with James's agreement.** The second sub-task
  said `newGameBoot` "already reads from `initial_save`, so the change is where the 38 bytes come
  from, not a second boot path". It does not: it reads them **at build time** into the ROM boot
  record, and the cart's graphics come from replaying the door script `screens.assign` paired
  with the cell. Nothing at runtime reads a 38-byte buffer. The original's load builds VRAM from
  the record's own pointers (`gameMode_LoadA` 00:$03B5, `gameMode_LoadB` 00:$0464), and the
  recording's first save names caveFirst's for all of them. So the load ports that half. The
  new-game cart keeps its door replay, and routing it through the buffer is not this step's.

  - [x] Port the title's slot check as the original does it (`titleScreenRoutine`, bank 5), **including the
        comparison M2RoS documents as working by accident** — it reads ROM past the magic until the
        first mismatch, into the damage-pose table at 00:$208B, which the cart carries — and the
        file counter it writes
  - [x] Port `loadSaveFile` (01:$4E33) and `loadEnemySaveFlags` (01:$7AB9): the record into the
        save buffer, the spawn flags back, `loadSpawnFlagsRequest` cleared
    - `loadSpawnFlagsRequest` is not a port variable: on this path it only asks for the window load
      `InitEntities`' room reset already does. The spawn-flag fill moved before the title
      (`FillSpawnFlags`, 00:$0243's place) so the load's flags are not filled over
  - [x] Port the load's half of `gameMode_LoadA`/`LoadB` from the save buffer: the variables
        `loadGame_samusData` and LoadA read, the metatile and collision tables by pointer, the BG
        and enemy graphics through a converter-built table from Game Boy source to asset (the
        reverse of 15a's carried source), and the room drawn at the record's camera through
        `LoadScreen`/`SeedWindow`
    - The table is the doors class's second blob, `load_sources`: every source a door stores plus
      `initialSaveFile`'s, each as the converted `LOAD`, and the load's two fixed copies (common
      items, item font) read off 00:$05FD. **Two findings.** Four enemy sources (the Metroid pages
      and `gfx_queenSPR`, `LOAD`ed from bank 8) land `$9C` into a tile when the load reads them in
      bank 6, so they are converted as the bytes the Game Boy copies. And **15a stored a source for
      `COPY_DATA`**, which the original does not: three scripts copy the item tiles into the
      characters, and a save after one would have reloaded the room in them. Fixture first, fixed,
      in `docs/bug_tracker.md`. `loadGame_samusItemGraphics` (00:$3BB4) is not ported: nothing it
      patches is in the slice
  - [x] `loadingFromFile`'s two other arms: the item font copy in `loadGame_loadGraphics` (00:$05FD),
        which gives 15a's save text its characters after a load, and pose `$13` handing over
        without a button (`poseFunc_faceScreen`, 00:$0EA5). Addresses inside them pinned from the
        ROM with `zig build disasm`, not from M2RoS line numbers
  - [x] Verification: a cold boot with a save file written by `save.zig` lands on the record's
        position, bank, energy, items and counts and keeps a killed enemy dead; perturbing the
        record's energy field fails it; a cart with no save file still starts a new game. Shown
        failing first
    - **Done 2026-09-15.** `zig build verify`'s new `load` rung (160-173) runs the shipped cart
      three times: slot 0 holding the recording's first save (`save.recorded_save`) with a
      saved-half spawn in its bank marked dead, which must come up in the record, graphics
      included, keep the spawn dead through a second of play and hand over control with nothing
      held; a record whose early bytes agree with the ROM past the magic until the broken compare
      reads one below $08, which must start a new game; and the energy perturbed, which must fail
      on 164. Faults caught: no title check 171, no font copy 169, no spawn flags 167, a title that
      counts matching bytes (it loads the refused record and stops at `Fatal`). The cold boot rung
      now blanks cartridge RAM before Start. `correspond.zig` checks every store `LoadGameState`
      makes against the ROM's load. `zig build test` and `zig build verify` green; every floor
      unmoved (reachable 1466, anchored 665, durations 28/28, segment 700, spider 847, enemy AIs
      18, status bar 281/281), which is right: no graded run loads

- [x] **Step 15c: B7 — Samus's death, the game over screen, and back to the title**
  - [x] Measure first on our Game Boy: from displayed health reaching zero, the frames to
        `gameMode` `$06`, to `$05`, to `$07`, and to the title on the timer and on Start
    - `src/death.zig` (new), on a 70 224-cycle clock from `killSamus`: $06 on 1, $05 on 128, the
      noise spent on 176, LCD off 178-183, $07 on 183, reboot on 439 (timer) or 22 frames after
      Start. Pinned, and a test re-measures both paths. The recording's 128/54 is the same 182
      frames as our 127/55; the one frame moves with where each machine's vblank lands. The LCD's
      five blank frames are CPU time, so they are measured, not derived. `docs/slice.md`
  - [x] Port `killSamus` (00:$2FA2) at the play handler's displayed-health test (in `gameMode_Main`, 00:$04DF),
        `VBlank_deathSequence`'s erase over Samus's tiles (00:$2FE1, every fourth frame, 32
        steps, `deathAnimationTable`), `gameMode_dead`'s GAME OVER screen (00:$36B0, the title
        characters and `gameOverText`), and `gameMode_gameOver`'s timer and Start back to the
        title (00:$371B). The death sound request is recorded, as every other sound is
    - `!DeathMode` holds the Game Boy's mode numbers. `killSamus` is split across its
      `waitOneFrame` and resumes into the play handler. `DeathErase` runs in NMI and replaces the
      handler, as `VBlank_deathSequence` does. Mode $05 waits on the noise as its timer ($B0,
      04:$57FD), since the port has no driver. GAME OVER reuses the title's character upload
      (`UploadTitleChr`, factored out). The text is a new physics blob (`gameOverText`), and so is
      the erase table (`deathAnimationTable`). The window band is turned off, as LCDC $C3 does.
      $07 is a two-frame pass that reads the pad once. `Reboot` jumps to `Reset` with NMI and HDMA
      off; cartridge RAM survives. Also ported: the input erase in `HandlePose` and the two
      collision refusals. Not ported: the Queen's arms and the soft reset
    - **Two findings, both in `docs/bug_tracker.md`.** (1) A Start held through the reboot left the
      cart's title. On the Game Boy, `gameMode_Boot`'s frame uses up that press (a new `death.zig`
      test confirms it). Shown failing (192), then fixed: `TitleScreen` seeds `!PadHeld` from
      `JOY1`. (2) `oracle.gradeWith` booted the segment and spider segment carts with zero health.
      Both went red on the death test; the fixture now carries the new game's loadout
  - [x] Verification: a `snes boot` phase kills Samus and checks each mode's length against the
        Game Boy's measurement, the GAME OVER text in the tilemap, and that Start leaves for the
        title; shown failing first; `zig build verify` green
    - **Done 2026-09-15, as a rung, not a `snes boot` phase.** `snes boot` runs a handover
      record that has no title to reboot into. Like 15b's `load` rung, the new `death` rung
      (180-192) plays the shipped cart from its title to two deaths, one left on the timer and
      one on Start. $06 127, $05 55 (5 blank), $07 256 and 22: all equal to the Game Boy's.
      It also checks each erase step's stride, the GAME OVER screen against the cartridge's bytes,
      cartridge RAM across the reboot, and a held Start not being taken. Eight engine faults are
      each caught with their own code: no erase 184, noise short 185, blank 4 frames 185, window
      on 186, no input erase 191, one-frame pass 189, no text 186, erase every frame 183. The gate
      also runs an expectation three frames long, which must fail on 185. `correspond.zig`'s death
      test checks every constant; the residue rows are added. `zig build test` and
      `zig build verify` green; every floor unmoved (reachable 1466, anchored 665, durations
      28/28, segment 700, spider 847, enemy AIs 18, status bar 281/281)

- [x] **Step 15d: B7 — the round trip, and the recording's reload**

  **Nothing new is ported here.** The mechanisms are 15a's, 15b's and 15c's; what 15d adds is
  the grader that runs them as one scenario — and the first rung in the cycle whose expectation
  the *cart itself* wrote. Every rung before it hands the cart a record the gate invented.

  - [x] Write the scenario James named: spawn Samus with one unit of energy, walk her to a save
        station, save, let something damage her, and assert the state the game loads is the state
        the record said it would be. **On the Game Boy as a `room.zig` test** (the original's
        behaviour, with `watchSave`/`watchLoad` logging the writes and reads), **and on the cart
        as a `snes boot` phase** through 15a–15c — the same amendment 13c, 13d and 14 made, since
        the cart is what the slice ships
    - **Done, and on the cart as a rung rather than a `snes boot` phase** — the same amendment
      15b and 15c made, and for their reason: `snes boot` runs a handover record that has no
      title to die into and no title to load from, and the round trip needs both. The new
      `round trip` rung (200-212) plays the shipped cart from its title through control, one
      unit of energy, a post-kill Metroid count, a station, a save, the death, the reboot and a
      load, and grades the state that comes back against **the bytes the writer left in
      cartridge RAM**, captured on the frame after Start. On the Game Boy, two `room.zig` tests
      do the same on one machine — she dies, `bootRoutine` runs, the title comes up and reads
      the slot the game wrote — with `SaveLog` attached across the save
    - **Neither machine walks to a station, and that is a narrowing worth stating plainly.**
      The cart *lays* one from the loaded collision table, which is the call 15a made for phase
      26 and James accepted. The Game Boy sets `saveContactFlag` itself, which is the one store
      both bottom probes make (00:$1F53, $1F96). Two routes to the real thing were built and
      neither survives the harness, for reasons that are the map's and the hardware's:
      `$F:$01`'s script is `ITEM $0; END` and names no tables, because in play she arrives
      through a door that loaded them, and `screens.assign`'s answer for the cell is door 085 —
      another station script, which run out of context does not return; and laying a tile needs
      video RAM, which the PPU locks outside vblank, sits at `$97E0` with a `$0400` page bit,
      and is drawn over by the streamer within a frame. **The contact is not left ungraded**:
      phase 26 stands her on a laid station and fails on 240 if it does not rise, and it showed
      the cart failing before the collision's two bit-7 tests were ported. 15d does not claim
      it a second time
    - **And a fact that shaped both halves: a new game cannot save where it starts.** A
      station's tile is a collision byte with bit 7 set; across the eight tables in bank 8,
      `caveFirst` has ids 16-19, `plantBubbles` and `lavaCaves` four each, `ruinsInside` six —
      and `surface`, which a new game's record names, has **none**. So the cart's boot cell has
      no station either, and the rung points `!ColTab` at a table that has one, writing the same
      address the engine's own `.collFound` stores after `FindBlob`. It is also why the
      recording's five saves are all `caveFirst` rooms. `docs/slice.md`
  - [x] `metroidCountReal` persists: the cart's scenario runs after a kill, so the count it
        reloads is `$46`, not the new game's `$47`
    - Graded on both machines, and both halves asserted: equal to the record, and **not** equal
      to the cartridge's own new-game count, which is read out of `initial_save` rather than
      written down. The `$46` is *set* rather than reached by killing an Alpha — that is Step
      13d's phases and this rung boots from the title — and the script says so where it sets it
  - [x] Grade the recording's death and reload by length (the memory's rule for cutscenes): the
        frames from the death at 25 889 to the reload at 25 941, and the loaded record's position
        and counts against the trace on the first frame of control
    - **The length this asked for is not a length, and the measurement says so.** `zig build
      gbtrace -- saves 25850 26000` puts Start on the game over screen at 25 889, the boot mode
      at 25 895, the title at 25 900, the *next* Start at 25 939 and the play handler at 25 951.
      **Thirty-nine of the fifty-two frames are James sitting on the title screen deciding to
      press a button** — a human pause, not a cutscene, and holding the port to it would be
      grading a thumb. What is machine-determined is graded instead: 6 frames from Start to the
      boot mode, 5 more to the title, and 12 from the title's Start to the play handler with the
      record live on the second of them. A test pins the split so the wrong reading cannot come
      back
    - **And our Game Boy gives the same four numbers with no tolerance at all.**
      `death.measureReload` / `death.on_reload`: `$0C` on 0, `$02` on 1, `$03` on 2, `$04` on
      12, which is the recording's 25 939/940/941/951 differenced from its own Start. It has to
      be the 70 224-cycle clock: mode `$03` turns the LCD off to copy, and counted in vblanks
      the same stretch measures 3 frames rather than 12 — the trap `death.zig`'s header already
      documented for the death. The record's position, bank, health and both counts on the first
      frame of control are checked against `save.recorded_save`, which is the trace's own
      columns on 23 002
    - **Two things about the title the port has to get right, found here.** The slot must be in
      cartridge RAM *before the title initialises*: `titleScreenRoutine` reads it on its way in
      (05:$426D) and keeps the answer, so a record injected into a title already on screen sends
      Start to game mode `$0B`, a new game. And that routine writes `$0B` and then `$0C` two
      instructions later (05:$429A, $42A3), so **every load passes through the new game's mode
      for less than a frame** — invisible to an end-of-frame census, and a wrong turn to
      anything watching instructions. Both are in `docs/slice.md`
  - [x] Verification: the scenario passes on both machines and fails when the record's energy
        field is perturbed; `zig build test` and `zig build verify` green; B7's feature tracker
        entry closed with its graders
    - **Done 2026-09-15.** The fault is the sharp end of the step: the cart run changes the
      slot's energy byte *after* the record is captured and before the death, so the load brings
      back a number the record does not name, and the rung must fail on 207 — it does. The Game
      Boy tests do the same through `save.fields`' own offset for the field. Without it, a load
      that ignored the slot entirely would have passed, since a new game's energy is a perfectly
      plausible number to find in the variables. `zig build test` and `zig build verify` green
      from a clean build; **every floor unmoved** (reachable 1466, anchored 665, durations
      28/28, segment 700, spider 847, enemy AIs 18, status bar 281/281), which is right: no
      graded stretch saves or dies. B7 closed in `docs/feature_tracker.md` with its graders
    - **James playtested the whole loop by hand on 2026-09-15** — saving, loading, restoring,
      being killed, the game over, and restoring again — before these graders existed. That is
      why 15d found no defects to fix: it is writing fixtures for a loop already seen working,
      and the fixtures earn their place by failing when the record is perturbed, which a hand
      playtest cannot show

- [x] **Step 16: B10 — the slice's verification, consolidated** *(every sub-task closed
  except the third's second half — adding the missing fault coverage — which is Step 25; the
  top-level box stays open until that lands)*
  - [x] Name the conformance harness in `docs/` and in `verify.zig`'s output: `zig build verify`
        green end to end, with the segment oracle, the reachable rung, the anchored rung, the
        `durations` rung, the recorded run's rung from Step 8, and the `room.zig` scenarios for
        the paths no movie reaches
    - **`docs/conformance.md`, 2026-09-15.** The thirty-rung roster, each with what it grades,
      what it grades *against*, and its fault check. The gate names itself in its first line and
      its last and points at the document, off a hand-kept `rung_count` with a comment saying
      why it is not counted from the output. Measured on the green run that preceded it:
      **391 s wall-clock warm, 780 s CPU**, exit 0, cart digest `299fe727…`
    - **Two of the six things this sub-task names are not what it assumed.** `room.zig` is not a
      rung and is recorded as not being one: it is the Game Boy harness the `load`, `death`,
      `round trip`, `enemy AIs` and `status bar` rungs are built out of, plus unit tests — the
      paths no movie reaches are graded *through* those rungs, not beside them. And **the
      recorded run's rung does not exist**: `oracle -- recorded` grades from any anchor and
      nothing runs it on every gate, so the recording reaches the gate only through the
      `status bar` rung's three sampled frames (45101, 48601, 74001). Documented as a gap and
      handed to Step 26 rather than built here
  - [x] Scope the anchored floor's criterion to the gradable stretches — 11 after Step 4, not 13
        — because the remainder are capped by conversion work this cycle defers
    - **Already done, and not by this step.** `oracle.anchored_gradable_floor = 11` landed with
      B12 on 2026-09-05 — the tileset fix took the gradable count 9 → 11 while the frame sum
      stayed at 394, which is the case the floor exists for — and `verify.zig:1441` enforces it.
      Verified rather than rebuilt
    - **And the audit found the weakness this sub-task was aimed at, one level down.** The rung
      reads `665 of 6848 frames across 11 of 13 stretches`, and **nine of the eleven gradable
      stretches play zero frames**, stopping on the anchor's first frame. The floor is met by
      stretches 0 and 6 alone. It is a regression ratchet doing its job; what it is not is the
      coverage claim its wording invites. Written into `conformance.md` as finding 3
  - [x] Audit that every mechanism ported in Steps 5–15 has a rung or fixture that fails when it
        is removed, and add the missing ones. The morph bug is the standing argument
    - **The audit is done; adding the missing ones is not, and the box stays open until it is.**
      `conformance.md` carries the mechanism-by-mechanism table: seventeen rows for Steps 5–15,
      each naming its rung and whether that rung has ever been shown to tell a correct cart from
      a broken one. Seven rows have a fault check. **Nine are graded by a `snes boot` phase and
      nothing else, and that rung is the one emulator rung in the gate with no fault run** —
      `cold boot`, `load`, `death`, `round trip`, `oracle`, `enemy AIs`, `status bar` and
      `snes render` all have one. Individual phases defend themselves ad hoc (phase 1's spent
      countdown, phase 23's count-must-differ, phase 25's tightening) and there is no systematic
      per-phase fault
    - **And the clustering, which is the audit's strongest result.** Six of the eight open
      playtest defects land on B1's transition, B4a's despawn, B5's projectiles or B6's items —
      four of the rows with no fault check. Correlation, not proof; it is still the best evidence
      available for where to spend the fault work. **Building the `snes boot` fault run is
      Step 25**
    - **Closed 2026-09-25 by Step 25** (`m2snes` `cf435cd`): every row of the table that had a
      dash now has a fault, each caught by the phase that grades it
  - [x] Audit compliance with Step 3's failing-fixture-first rule across the cycle, and record
        any step that did not follow it rather than quietly backfilling
    - **All 46 `bug_tracker.md` entries read. No closed entry was fixed without a guard.** Forty
      carry an explicit `Guarded by:` line. Four closed entries describe their guard in prose
      instead — the Step 12e pair, the Step 5b script-end entry, and the 2026-08-31 template
      placeholder — which is a formatting inconsistency and not a rule violation, and is recorded
      in `conformance.md` rather than backfilled. Eleven open entries have no guard, which is the
      rule working as written: the guard is due before the fix and none of the eleven is fixed
  - [x] `docs/feature_tracker.md` shows every `0b` entry either checked off with the rung that
        grades it, or explicitly deferred with a reason. That review is this cycle's exit
        criterion and Phase 1's entry point
    - **Done 2026-09-15, and it needed a third marker.** `[ ]` and `[x]` both lied about B1 and
      B8: `[x]` would claim a feature the player can see is wrong, `[ ]` would discard the rungs
      that do grade it. **`[~]` is "delivered and graded, with a named defect still open"**, it
      is defined in the file's header, and an entry carrying it must name the defect. B1 names
      the transition hurtboxes and the fade-plus-scroll; B8 names the acid
    - **Two entries were simply stale and are now closed.** B4 was left open by its own Step 12f
      status bullet while every sub-entry under it had closed — all thirteen censused AIs ported,
      eighteen rooms graded, the "ungraded" spawn walk graded by `snes boot` 15. And B11 said
      "Graded by: none yet" months after `gb_trace.zig` landed; corrected to what actually grades
      it, including the gap that the recorded sweep is off-gate. **Nothing was ported to close
      either**, and both say so
  - [x] Any rung retired during the cycle is recorded in writing with the reason
    - **None was.** Every rung that existed at the start of Phase 0b still runs, which is D1's
      criterion carried into D2. What was retired during the cycle is internal and not a grading
      path: `!EnChild` on `enemy_deleteSelf`'s parent link, `!EnUnhandledState`'s Metroid arm,
      and the Alpha's `.death` recorder arm at Step 13d — all recorder arms made redundant by the
      mechanism they stood in for being ported, each recorded at its field in `residue.zig`.
      Stated in `conformance.md` so the absence is on the record rather than assumed
  - [x] Verification: `zig build test` and `zig build verify` green from a clean build-out, twice
    - **Done 2026-09-15, on the second attempt, and the first attempt is worth recording.** Run
      one put all three commands' output through a single redirect and the two `zig build verify`
      processes interleaved on the same file offset — run 2's `time` output overwrote run 1's
      text mid-line, and the combined block exited 0 only because the *last* command did. The
      log could not be read as two results and was not treated as one. Re-run with a separate
      log per command
    - **`zig build test`: 91 s, exit 0.** **`zig build verify` from a cleared `build-out`: 392 s,
      exit 0, 30 `ok` rungs, no `FAIL`. Second run: 412 s, exit 0, 30 `ok` rungs, no `FAIL`.**
      Both runs report the same cart digest `299fe727859b241b12cde3dcc4430d90713588772ededcda146e6f4d9b2dc281`,
      and the three ratchets are unmoved: `reachable` 1466 of 1999, `anchored` 665 of 6848 across
      11 of 13, `durations` 28 of 60 inside 2%

**Steps 17–24: the eight open playtest defects, one step each.**
  *(Added 2026-09-15 on James's decision, out of B10's audit. Each of the eight is a defect found
  by playing the cart, sitting in `bug_tracker.md` since 2026-09-14/15 with no fixture and no fix,
  while the gate is green. They are steps rather than sub-tasks of Step 16 because each is a port
  of a mechanism, not a correction to one. **Step 3's rule governs every one of them:** the
  failing fixture is written first and shown failing before the fix, and the entry's `Guarded by:`
  line names it. The order is the order the audit found them in, not a priority — reorder freely,
  none depends on another.)*

- [x] **Step 17: Samus during a room transition — her position, and what can hit her**
  *(Scope widened 2026-09-15 by James before the step started. The original entry reported two
  symptoms and the widening is his third reading of the first one: during a **scrolling** room
  transition Samus's position looks **locked** — she stays at the far edge of the screen — and
  then **snaps back** once the scroll finishes. The entry's own words were "pushed forward during
  the scroll, then she snaps back". **Treat one cause as the hypothesis and not as the finding:**
  a position the engine holds wrong for the length of the scroll would explain both the visual and
  the hit, because the enemy collision reads the same position. Measure before believing it.)*
  - [x] **Measure first, and measure the position before the collision.** Off the recording: for
        a scrolling transition, what does the Game Boy hold in Samus's position and the camera on
        every frame from the scroll's first to the frame after control returns? Then the same
        columns off the cart. The difference, frame by frame, is the finding — `gb_trace.zig` and
        `zig build trace` already emit `samus_y`, `samus_x`, `camera_y`, `camera_x` and pose
    - **Begun 2026-09-15, and two things are settled. First, the any% run's first crossing is
      invisible on the Game Boy.** `zig build tas -- any N 1` puts the crossing at frames
      608–747: 608–707 frozen (the door script and its `FADEOUT`, position and camera both
      unmoving), then 708–747 the scroll, camera +4/frame and Samus +1/frame. Rendered, **every
      frame from 707 to 747 is byte-identical and the picture is blank** — the fade blanks the
      display, the scroll happens behind it, and the room is back at 752. Nothing is visible and
      nothing can snap, so this crossing is not the one the report describes
    - **Second, a visible scroll exists and is where this has to be measured:** frames 1387–1420,
      a downward crossing with the screen on and the room moving, camera +4/frame and Samus
      +1–2/frame. The other stretches with a 4 px camera step are 1760–1793, 2059–2092,
      2382–2421 and 2745–2784
    - **And one inference was wrong and is struck rather than left to mislead.** `samus_x −
      camera_x` reaching −53 on the first crossing, and holding a constant −33 across the second,
      is **not** a statement about the screen: it is −33 on the frames *before* the scroll starts,
      when she is on screen and controllable. `camera_x` is not the screen origin. Nothing about
      on-screen position can be read off these two columns; `CameraGuideX` computes the real
      quantity and leaves it in `$D03C`
    - **What the measurement still needs, and the tool it needs.** `$D03C` and OAM, per frame,
      across 1387–1420, on the Game Boy and then on the cart. `tas.zig` samples a fixed column
      set and no arbitrary address, so this wants a watch facility on `zig build tas`. **James's
      observation on 2026-09-15 is the thing being tested:** on the original her sprite stays
      synchronised with the scroll and does not snap. If that holds, the port's skipped
      `DrawSamus` is a plain infidelity and `main.asm:3047`'s claim that the original's `00:$0522`
      skip covers "the draw with it" is wrong. Do not settle this from that comment
  - [x] Separate the two transitions before diagnosing. The **door/WARP** crossing is graded by
        `snes boot` 8 and re-seats everything; the **scroll** between screens is `HandleCamera`'s
        and drags Samus at a pixel a frame (Step 6, 00:$0B44). The report says scrolling. Confirm
        which one is wrong rather than assuming they share a defect
  - [x] Fixture first, for whichever half the measurement indicts: Samus's position on every frame
        of a scroll compared against the Game Boy's, shown failing on the shipped cart
    - **`snes boot` phase 27**, and the reason it never existed is a line in phase 8:
      `emu.write(RAM_TRANSDIR, 0, wram)`, commented "the scroll is not what this phase grades".
      Shown failing first — with `jsr DrawSamus` removed the phase exits **121, "was not drawn at
      all: nothing was composed into OAM"**, which is `checkSprite`'s own code and the reported
      symptom exactly. Four dead ends are written into the fixture rather than left to be
      rediscovered: Lua's 200-local ceiling in the main chunk (a new `local` stopped the script
      compiling and read as a hung cart); a watch bounded by the scroll *ending* hangs, because
      `TransitionCamera` stops on `CamX & $FF` **equalling** `TRANS_STOP` and a crossing driven by
      a written door index need not be congruent to it; and running the watch mid-test does not
      survive, because the warp back keeps pixel halves and phase 11 then finds Samus elsewhere
      (exit 153), so it runs last
  - [ ] ~~Fixture first, second half: a crossing with an enemy on the incoming screen~~ —
        **not built. Closed on playtest evidence, on James's explicit call 2026-09-15.**
    - The position fix alone did make it pass: James could not reproduce the hit after Step 17,
      and the mechanism explains why — the enemy collision reads `!OnscreenX`/`!OnscreenY`, which
      were frozen for the whole crossing. **So the hypothesis is confirmed and the fixture is
      not built**, which is the trade being recorded rather than glossed: this is the one closed
      entry in `bug_tracker.md` whose guard is a person. The concern was raised, the call was
      James's, and `Guarded by: playtest only` says so in the entry
  - [ ] ~~Measure the Game Boy's collision rule~~ — **moot, and the report's proposed fix was
        wrong.** "Enemies should not have hurtboxes until the transition completes" was a
        hypothesis about the original; the defect was never the hurtbox, it was the position the
        hurtbox was measured against. Not measured, because nothing now depends on the answer
  - [x] Port; both `bug_tracker.md` halves get their `Guarded by:` lines
    - **One call: `jsr DrawSamus` restored to `.transitionFrame`, before `DrawProjectiles`**,
      which is the original's order (00:$074C, $0741, $0742). The skip at 00:$0522 jumps to $053E
      and runs everything from there, and `drawSamus` is 00:$0550 — past it. `main.asm`'s comment
      claiming the skip covers "the draw with it" is corrected in place; it was why nobody looked
    - Both halves are in `bug_tracker.md`: the draw defect guarded by phase 27, the enemy hit by
      the playtest, each saying which
  - [x] Verification: both fixtures green, the `durations` rung's 28/60 and `snes boot` 8's
        assertions unmoved, and B1's `[~]` loses one of its two named defects
    - **Gate green 30/30**, `durations` 28 of 60 unmoved, `snes boot` green end to end including
      phase 8. **And `reachable` moved 1466 → 1999 of 1999**: `!OnscreenX` is what
      `HandleCamera`'s horizontal door triggers read, so a stale one had been breaking every
      crossing after the first. `movie_gate_floor` raised to 1999 with a note that the rung can
      now only go red — the window is exhausted and giving it room means raising `movie_frames`
    - B1 keeps its `[~]`: the hurtbox defect closed, and Steps 20, 24b and 24c are named against
      it instead

- [x] **Step 18: a shot fired as a vertical scroll starts is dragged across**
  *(**Closed 2026-09-16 on James's call, not by a port.** He could not reproduce it by hand after
  Step 17 and asked for it marked fixed. **Nothing was ported and no fixture was built**, so this
  is the **second** entry in `bug_tracker.md` whose guard is a person — Step 17's enemy-hit half
  is the first — and the entry says so in those words rather than claiming a rung. Every
  sub-task below stays unchecked, because none of them was done.)*
  - [ ] ~~Fixture first, off the recorded repro `reference/vertical_screen_scroll_shot_drag.mmo`~~
        — **not built.** The recording is still there and is the fixture's starting point if this
        recurs
  - [ ] ~~Measure where the original despawns it~~ — **not measured**, and the one candidate the
        engine already supplies is written down instead of being tested: `.transitionFrame` calls
        `DrawProjectiles`, whose four window compares at 01:$5359 free any slot outside the play
        window, and those compares are taken against `DeriveScroll`'s scroll — which moves every
        frame of a scroll. So a live shot *is* despawned during a crossing; what the report
        described is more likely what OAM showed than what the array held. Step 17 changed
        exactly that: `DrawSamus` went back in ahead of `DrawProjectiles`, moving which OAM slots
        a crossing composes into. **Plausible and unverified** — it is a hypothesis for whoever
        reopens this, not the finding
  - [ ] ~~Port it; `Guarded by:` line~~ — nothing to port
  - [ ] ~~Verification: the new phase green~~ — no new phase. `.transitionFrame`'s standing
        comment ("nothing can be in the air across a crossing today, because `ClearProjectiles`
        is not called on one") is the thing a future fixture would have to contradict first

- [x] **Step 19: a live Metroid is lost permanently on leaving the screen**
  *(**Closed 2026-09-16 on James's playtest, and the step ported nothing — the fix was already
  in the cart.** He activated an encounter, left the screen, came back to find the Metroid still
  there, and killed it: death cutscene, counter decremented, quake. The cart he played is byte
  for byte the one that carried the report (`engine/engine.bin` unchanged; the only engine change
  this step made is a corrected comment). So the step's work became: find out which earlier step
  fixed it, and leave a rung behind that fails if it comes back. **Step 15a is the step**, by
  dates and mechanism rather than by a measurement of the old cart — see the sub-tasks below —
  and `enemy reload`'s `alpha2 reset` case is the guard, shown failing against the pre-15a
  behaviour.)*
  - [x] Fixture first: spawn-walk back into a room whose Metroid was active and require the slot
        to come back. This is B4a's despawn window, one of the rows with no fault check
    - **`enemy reload`, the gate's thirty-first rung** (`src/enemy_oracle.zig`, `reload_cases`,
      wired in `verify.zig`). Six cases: both Metroids in the slice and an ordinary enemy as the
      control, each with and without the room reset a transition asks for. The camera is driven
      off the enemy and back on both machines to the same schedule, and what is compared is
      whether the **record** is live again and under which spawn flag — the despawn window
      (02:$452E), the delete for good ($4464), the reactivate ($44C0) and the walk's reload
      (03:$4014). **All six agree pass for pass and each faulted cart differs**
    - **Three levers, and two of them were paid for in wrong answers first.** The camera holds
      each position for **two ticks**: the enemy pass runs on every other frame and which parity
      it lands on is a property of each machine's boot, so a camera that moved every tick turned
      that one-frame offset into a four-pixel *position* difference at the reload — measured,
      `crawler away` reloading its record at x $F5 on the Game Boy and $F1 on the cart, one
      four-pixel step apart, with nothing else about the two runs disagreeing. And Samus is **frozen** (`$C463`), because
      the camera is hers: dragged sideways by hand and thawed she walks into terrain, and the
      record then came back a pixel apart in Y with the camera's Y differing on 400 of 560
      frames while the sweep only ever wrote X. The third lever is following the record **by
      spawn number** rather than by slot 0, which the delete empties and the walk refills with
      a neighbour on its own AI
    - **The rung defends itself**: every case must lose the record and get it back
      (`leftAndCameBack`), or it would agree with the Game Boy on a history that says nothing
  - [x] Measure the original's rule for a Metroid specifically — the ordinary despawn window is
        ported and this is what survives it
    - **The rule, off the running Game Boy** (`room.zig`'s camera drive, and then the rung):
      a live record deleted for good has its flag put back to **$FF** when it was `$01` (never
      seen) and to **$FE** when it was `$04` (seen), and the walk loads anything at or above
      $FE. So a Metroid is *meant* to come back, and on the Game Boy it does
    - **What is Metroid-specific is the half of the array, not the code.** A flag is indexed by
      the record's spawn number; the ROM's fifteen Metroid records are numbers **$40-$56**, and
      $40 is where the **saved** half begins. A room load refills the unsaved half with $FF, so
      a wrong flag for an ordinary enemy is gone at the next door and a wrong flag for a Metroid
      is permanent. That is the whole reason the entry names Metroids, and it is why the rung
      grades one enemy from each half
    - **And one infidelity found on the way, which is not this bug.** `!SpawnReload` stands in
      for two Game Boy bytes: `$C44B` (the room reset, raised by the door interpreter's end at
      00:$26D7) and `$D09E` (`justStartedTransition`, raised $FF by the door trigger at
      00:$0C63, and what ends a Metroid fight). The engine's comment claimed 00:$0C37 raised
      both; corrected in place. A crossing raises both, so the merge holds in play — shown by
      measurement: with one raised the cart ends a fight the Game Boy does not, with both
      raised the case is green
  - [ ] ~~Port it~~ — **nothing to port: Step 15a had already fixed it, on 2026-09-15 in
        `b63013d`.** `ResetEntities`' own note says what the engine used to do: "until then the
        saved half was filled at boot and carried across every bank", with no out-pass and so no
        translation of `$04` to `$FE`. Against the walk, which loads a record only at `$FE` or
        above, that is the whole bug: a Metroid that has been **seen** carries `$04`, a crossing
        empties every slot without publishing a translated flag, and the flag then sits at `$04`
        with no slot — never loadable again, and in the saved half, so no room load clears it.
        It needs a seen Metroid and a door, which is precisely the repro James gave when asked:
        **"through a door"**, **"it was fighting"**. **This is inference from the dates, the note
        and the mechanism, not a measurement of a pre-15a cart**, and the entry says so
  - [x] `Guarded by:` line — and the guard was shown failing first, which is the part that
        makes the closure worth anything
    - **Delete `$04`'s translation to `$FE` from `ResetEntities`** — the pre-15a behaviour — and
      **`alpha2 reset` goes red**: 11 of 134 passes, the Game Boy's record coming back at flag
      `$04` and the faulted cart's at `$01`. Restored, it is 134 of 134. `alpha reset` and
      `crawler reset` stay green under the same fault, which is the useful part rather than a
      weakness: the hatching Alpha never leaves its intro in that case so its flag is `$01`, and
      the crawler's number is in the unsaved half. **The case that guards this is the one whose
      Metroid has been seen** — the one the report describes
    - **And the fault run found a hole in the fixture, which is why it was worth doing.** The
      out-pass is skipped while `previousLevelBank` is zero (02:$419D), and it is zero until a
      reset sets it — so the first version of these cases fired **one** reset, graded the
      load-in against a boot-filled buffer, and **passed with the translation deleted**. Every
      reset case now fires two: the room the player came from, then the one whose flag has to
      survive
  - [x] Verification: the new fixture green, and the `enemy AIs` rung unmoved
    - **`zig build verify` green end to end, exit 0, "31 rungs, none retired"** — measured
      before the reset cases gained their second reset, and **re-run after it, green again: 31
      rungs, exit 0**, with `engine/engine.bin` unchanged. The ratchets on that run: `reachable`
      1999 of 1999, `anchored` 665 of 6848 across 11 of 13, `durations` 28 of 60, `enemy AIs` 18
      rooms, `enemy reload` 6 records `enemy reload`
      reports all six cases agreeing with the Game Boy pass for pass, each faulted cart
      differing, and each record having left the screen and come back. **`enemy AIs` is
      unmoved**: the same 18 rooms with the same pass counts. `durations` unmoved at 28 of 60.
      The run was not timed; `conformance.md`'s 391 s is still the last measured wall-clock and
      is left as it stands rather than replaced with a guess
    - `zig build test` passes, with four new unit tests: the saved/unsaved halves the cases
      claim, the three levers every reload case must set, `leftAndCameBack`'s own fixture, and
      the existing AI/table checks extended over the new list
  - **What is still unguarded, carried in `bug_tracker.md` rather than closed with the step**, so
    it is not lost: a real **crossing** (this rung fires the reset request, not a door script —
    the original's interpreter blocks for ninety frames and `stepOneTick` cannot follow it, so it
    wants a `snes boot` phase beside 27, which already owns a live crossing); a **cross-bank**
    crossing, where the out-pass goes under `!PrevBank` and the in-pass under `!MapIndex + 9`
    where the original reads `$D058` — they agree inside one bank and the rung proves it, and
    **Metroid numbers repeat across banks** (73 in both `$B:$66` and `$E:$07`), where `$02` is
    the one value that never reloads; and a **save or load between the two halves**, which puts
    `SaveEnemyFlags`' own translation in the middle of the trip

- [x] **Step 20: the fade transition also runs the scroll**
  *(**Rewritten 2026-09-16 with James, before any code.** The first draft's fixture — "a fade
  door must not move the camera" — is wrong against the ROM and the running Game Boy. The
  original scrolls on a fade door too, **in the dark**: `zig build tas -- any 900 1
  watch:D07E,D09B,D08E,FFC8,FFC9,FFCA,FFCB` on door $1DF shows `$D07E` $93 to 612, $E7 613–628,
  $FB 629–644, **$FF 645–747** with the warp at 703 and **the camera walking $3B0 → $44C at four
  pixels a frame, 707–746**, then `fadeInTimer` $2F at 747 (`.endDoor`, 00:$1880) and $FB,
  $E7, $93 from 748 (`fadeIn`, 01:$7A45). What the player sees is James's report — fade out,
  fade in with Samus in place — and what the port does wrong is light the screen at the
  script's `END`, showing the scroll the Game Boy hides. Stopping the camera would move
  `reachable` and `durations`, which grade exactly those frames.)*
  - [x] Fixture first: the cart's screen brightness graded frame for frame against the Game
        Boy's `$D07E` through door $1DF's crossing, off Mesen2's `ppu.screenBrightness` and
        `ppu.forcedBlank` (probed: both readable from `emu.getState()`). Shown failing on
        today's cart before the port
  - [x] Port `fadeInTimer` ($D09B): set where `.endDoor` sets it (`TransitionCamera .finish`,
        when the palette is not $93), cleared where `loadDoorIndex` clears it
        (`StartTransition`), and ticked where `miscIngameTasks` ticks it
  - [x] Port `FADEOUT`'s palette steps, and hold the screen dark from the fade through the
        scroll. The palette byte becomes SNES brightness through a stated table ($93 → 15, $E7,
        $FB, $FF → 0), written down as our substitution. **Step 24b's hazard applies**: lifting
        the forced blank on `FADEOUT`'s frames is the narrowing that failed `snes boot` 204
        before — if it fails again, record it and leave those frames to 24b
  - [x] `Guarded by:` line in `bug_tracker.md`, and the fixture shown failing against the
        pre-port cart
  - [x] Verification: `zig build verify` green; `reachable` 1999/1999, `durations` 28/60 and
        `anchored` unmoved; `snes boot` green including 204
    - **Closed 2026-09-16 in `m2snes` `a121f9c`.** Gate green, exit 0, "32 rungs, none retired",
      404 s wall-clock. `fade`: 168 frames, 41 of them the hidden scroll. `reachable` 1999/1999,
      `anchored` 665 across 11 of 13, `durations` 28/60, `enemy AIs` 18, `enemy reload` 6 —
      all unmoved. Cart digest `5f319cc6…4b79c34`
    - **Shown failing twice**: on the pre-port cart at movie 613 (forced blank where the Game
      Boy dims), and with the script's end put back to full brightness at movie 697–708 (the
      scroll). The blank lifted for `FADEOUT`'s wait frames did **not** trip `snes boot` 204,
      so Step 24b's failure is specific to lifting it around `COPY`
    - Not graded, and left to 24b: script frames where the Game Boy's palette is $93, which
      includes the fade door's own first four frames

- [x] **Step 21: missile doors work but are invisible**
  - **Diagnosed 2026-09-24, and it is not a drawing bug either.** On the `missileDoor` oracle
    cart ($E:$6A) the door *is* drawn: twelve objects, tiles `$F4`–`$F6`, six of them on screen.
    Those characters are **all zero** in the object half of VRAM. `$F0`–`$FF` is where 00:$05FD
    and three door scripts' `COPY_DATA` put `gfx_commonItems` ($8F00), which is inside the window
    the Game Boy's background and objects share. `convertOp` split a copy there in two only when
    its opcode was `spr`, though its own comment and `target.inSharedWindow` both say the rule
    is the destination's. So the common items reached the BG characters and never the object
    ones. The door, the drops and the item orb all draw from them, so this is probably also
    Step 23 and the refill-orb report. That is measured for the door only
  - [x] Fixture first: the door's metasprite or tiles present in VRAM/OAM where the Game Boy
        draws them. The `enemy AIs` rung already grades `missileDoor`'s *behaviour* at `$E:$6A`,
        which is why this reads as a drawing bug and not an AI one
  - [x] Port the draw; `Guarded by:` line
    - *(Nothing to port: the draw was already there. The fix is the conversion's split rule and
      00:$05FD on a new game.)*
  - [x] Verification: the new check green
    - **Closed 2026-09-24 in `m2snes` `a4b7e73`.** The fixture is the `load` rung's **code 174**:
      the ROM's `gfx_commonItems` at 4bpp against the object characters, on a load and a new
      game. It failed on all three of the rung's runs before the fix, and so did a converter
      test ("every copy into the shared window writes the object characters too") on the door
      stream. Re-probed on the `missileDoor` cart: `$F4`–`$F6` now have 14, 16 and 16 nonzero
      bytes. Gate green, 35 rungs. `reachable` 1999/1999, `anchored` 665, `durations` 28/60,
      `enemy AIs` 18, `enemy reload` 6, `fade` 168, `snes render` 904/904, all unmoved.
      182 blobs (was 181). Cart digest `bef61456…cbd192311`
    - **Two fixes, not one.** The converter split a copy into `$8800`–`$8FFF` only for `spr`,
      and a **new game never ran 00:$05FD**, because it replays a door script instead of the
      load. `BootGraphics` now calls `LoadCommonItems` on both paths
    - **Found on the way, and not this step's:** the pre-fix gate hit `snes boot`'s exit-81
      flake, and the staged cart and script alone gave 81 on 6 of 15 runs. So the tracker's
      "two emulators at once" hypothesis is wrong. Mesen's SNES `RamPowerOnState` is `Random`,
      which makes uninitialised RAM the lead suspect, but that is not measured. The same run
      failed `enemy AIs`' `crawlerA corners` once. Both are recorded in the tracker entry

- [x] **Step 22: after Alpha 1's quake the acid does not drop, and acid does not damage**
  *(Amended 2026-09-24 to cover both tracker entries: 2026-09-15's "doesn't drop / doesn't
  damage" and 2026-09-22's "levels too high", with eight screenshots.)*
  - **Diagnosed 2026-09-24: two defects, and neither is the quake.**
    1. **The levels.** `screens.tiletable_order` maps `TILETABLE` operands 6/7/8 in physical
       layout order, `Mid`/`Empty`/`Full`. The ROM's `metatilePointerTable` at 08:$7F1A maps
       them **`Empty`/`Full`/`Mid`**. So the port draws table 8, the no-kill table, as Full where
       the Game Boy draws Mid, and table 6, after the kill, as Mid where the Game Boy draws Empty.
       That is one level high on both sides of the kill, which is what the screenshots show
       (`E:0D` at 8 and then 6, `A:08`, `B:13`, `C:E1`). This is the same mistake the collision
       tables had before 2026-09-08. The existing test could not catch it because all three
       lava variants load the same graphics. The Step 14 `IF_MET_LESS` fix already makes the
       drop happen; it drops to the wrong level. Collision is sampled from the drawn tilemap,
       so the acid is also in the wrong *place*
    2. **The damage.** Bit 4 of a collision byte is `blockType_acid`, and $D062 is
       `acidContactFlag`. The port names them `!BLOCK_SPRING` and `!Springboard`. None of
       the six `applyDamage.acid` calls is ported (two in `collision_samusTop`, two in
       `collision_samusBottom`, two in `collision_checkSpiderPoint`, one per branch; first
       written here as five from a truncated search), and `CollideTop` does not latch the
       flag at all.
       `applyDamage.acid` (00:$2F4A) damages every 16th frame by `acidDamageValue`, with the
       `$07` noise
  - [x] Fixture first, levels: a unit test that resolves every `TILETABLE` operand through the
        ROM's pointer table (a new `metatile_pointers` offsets entry, 08:$7F1A, $14 bytes), the
        way `tileset.collisionOrder` does for collision, and requires `tiletable_order` to
        agree. Shown failing on today's order
  - [x] Fixture first, levels, on the cart: `snes boot` phase 23 already runs `$B:$0C` at
        tables 8 and 6. Grade the cart's metatile bytes for the room against the ROM table the
        pointer names. Shown failing before the fix
  - [x] Fix the order: derive it from the pointer table rather than from layout, remove
        `tiletable_unpinned` (the pointer table pins slot 7), and correct the offsets note that
        says the naming is unresolved
    - Done. The unit test is `screens`' "a TILETABLE operand selects the table the ROM's pointer
      table names"; it failed at operand 6 (`$5480` wanted, the ROM's `$5594`). The cart's is
      `snes boot` **code 227**: each gate door's incoming edge against its room expanded
      through `screens.metatileTable`, which now resolves through the ROM's pointer and not
      through `tiletable_order`, so the list the cart is built from is held to the ROM. Exit 227
      on the pre-fix cart, 0 after. `tiletable_order` stays a named list, since array lengths
      and the converter need it at comptime, and the test pins it
    - **Found on the way:** `!META_PTRS_N` was 8 against ten pointers, so loading a save made
      in a table-8 or table-9 room reached `Fatal`. Now 10, exported, and held to the offsets
      entry's size by `correspond`'s "the load searches every pointer the two pointer tables
      hold", which fails at 8
  - [x] Fixture first, damage: Samus in an acid tile loses `acidDamageValue` on every frame
        where `frameCounter & $0F == 0`, and the flag latches. Grade it against the Game Boy if
        the recording or a `gbtrace` case can put her in acid. Otherwise use a `snes boot` phase
        with the ROM's arithmetic, and write down which one was used
  - [x] Port `applyDamage.acid` and its six call sites in their original positions, with the
        flag latched in `CollideTop` too. Rename `!BLOCK_SPRING` → `!BLOCK_ACID` and
        `!Springboard` → `!AcidContact`, and correct the comments that describe a spring block
    - Done. **The Game Boy measurement is the any% run's, not the recording's**: the recording
      never touches acid (`$D062` zero on all 76 951 frames), and any% does on 693. Frames
      7369-7493: health moves only on a counter of `$x0`, by 4 at 7376 and 7472 and by 2 at
      7392 and 7488, at a damage of 2. So it is once per probe in acid, which is why the call
      sits at each site's position. The stretch is anchored-sweep stretch 12, which still
      cannot be booted (map 2 cell `$0D`, the tracker's tileset-assignment entry), so the
      cart-side fixture grades the rule rather than those frames
    - The fixture is `snes boot` phase 23's last step. It lays a floor of the loaded table's
      solid acid tile under her (`lavaCaves` has 20 below its `$42` threshold) and requires
      `acidContactFlag` on every frame she stands, exactly one damage (2) on every `$x0` frame
      and nothing on the others, four times: **code 252**, which it stops at when the damage
      call is removed. Then it fills 64 pixels above the floor with liquid acid and drops her
      from 48 up: 4 on the tick mid-fall, 2 once landed. That is **code 254**, which it stops
      at when the engine allows one acid call a frame. James reported the same 4-then-2 on
      every entry while this step was running. The acid flicker (01:$4BE8, ported too) is **code 253** in the per-frame sprite
      check, and it stops at 253 when the flicker is removed. `!BLOCK_ACID` is exported and
      held to 00:$1EC5's `BIT 4,A` by `correspond`
    - **Six sites, not five**: `collision_checkSpiderPoint` carries the test in both
      branches. One `AcidProbe` routine is called from each site's position
    - The sound request is ported (00:$2F52, `$07`) but not graded here: `AudioTick` clears
      the request byte inside the frame
    - **Not ported, and not this step's:** `drawSamus`' sprite attribute for hurt *or* acid
      (01:$4DFF, `hSpriteAttr` = 1 while either is set). Neither cause has it; recorded in the
      tracker
  - [x] Measure the quake's acid step off the recording: confirm the drop is a door-time table
        change and nothing in-room, so nothing else is owed
    - Done **from the ROM, not the recording**. The quake is `earthquakeCheck` (08:$7EBC), the
      countdown in bank 1's play handler and `earthquake_adjustScroll` (01:$79EF), and between
      them they write `scrollY`, `nextEarthquakeTimer`, `earthquakeTimer` and the song bytes.
      Nothing else. The acid moves only when a door's `IF_MET_LESS` picks the next table.
      `gbtrace world` at 17700/17990/18249/18300 could not show it either way, because the
      camera moves through the whole quake
  - [x] `Guarded by:` lines on both tracker entries
  - [x] Verification: `zig build verify` green; `snes render` re-baselined deliberately if
        lava screens move (they should, and the count that moved goes in the closing note);
        `reachable`/`anchored`/`durations` unmoved; B8 becomes `[x]`
    - **Closed 2026-09-24 in `m2snes` `9833f7a`.** Gate green, exit 0, "35 rungs, none
      retired". `reachable` 1999/1999, `anchored` 665 across 11 of 13, `durations` 28/60,
      `enemy AIs` 18, `enemy reload` 6, `fade` 168, all unchanged. Cart digest `66dc2746…99ee`.
      B8 is `[x]` in `feature_tracker.md`
    - **`snes render` did not need a new baseline**: it converts each screen through the table
      it was assigned, on both sides, so the order moved them together. What moved is the
      picture. 32 of 904 reference frames differ from the pre-fix commit (13 in bank B, 3 in
      C, 16 in F), and quarter-metatiles reading unwritten VRAM fell from 40 976 to 35 733
    - **Reopened 2026-09-24 by James's playtest: acid played its sound and flicker and took
      nothing off.** A new game booted with `!AcidDmg` 0 (and `!SpikeDmg` 0), because no boot
      record version carried $D077/$D078. The phase 23 fixture had forced the value to 2, so
      it graded the mechanism on a value the cart never had. Fixed by boot record version 15
      (`BootAcid`, `BootSpike`, from `initialSaveFile` or the handover's measurement). Guarded
      by code 197, the new-game loadout, which failed on the version-14 cart. The acid step now
      reads the cart's own value (252 on zero), and phase 23 holds her health through the gates
      and the quake, which now hurt. Closed in `m2snes` `94345f1`. That gate's only red
      was `snes boot` exit 81, the known flake; a clean rerun was not taken
    - **Revises the tileset-assignment tracker entry**: through the right names, map 2 `$0D`
      and `$0E` show table **8**, which door `$04A` states for bank `$B`, where the entry said
      no door in bank `$B` states the table. Anchors 11 and 12 are still unbootable, but that
      may now be reachable by inference, and those two stretches hold the any% run's acid

- [x] **Step 23: missile ammo upgrades are invisible**
  - **Fixed by Step 21 before this step started.** James reported it gone on 2026-09-24. The
    Missile Tank is sprite $99, and the ROM's metasprite table (01:$5AB1) draws it from tiles
    `$F0`-`$F3`, which are `gfx_commonItems`, the copy Step 21 made reach the object
    characters. The energy refill ($9B, `$FD`) and missile refill ($9D, `$FB $FC`) are in the
    same range. The attribution rests on that ROM fact and on code 174 failing on the
    pre-Step-21 cart. No tank was measured on screen on the old cart
  - [x] Fixture first: the pickup's tiles in VRAM where the Game Boy has them. B6's pickup
        *effect* is graded by `snes boot` 9 and 10; the picture is not
    - The VRAM half already existed: the `load` rung's **code 174** holds the object characters
      to the ROM's `gfx_commonItems` at 4bpp, and it failed on all three runs before Step 21.
      What was missing was the link from the tank to those characters. That is `snes_convert`'s
      new "the Missile Tank and both refills draw only from the common item characters", which
      reads the three sprites' parts out of the ROM and requires them inside the 00:$05FD copy.
      It also requires the Bomb's sprite *outside* that range, so it can tell the difference.
      Shown failing with the Bomb's id put in the tank's place
    - **No `snes boot` room has an item orb**, so there is still no on-cart check that the
      tank's OAM entries point at those characters. The missile door draws `$F4`-`$F6` through
      the same path and James has seen it drawn
  - [ ] Port the draw; `Guarded by:` line
    - Not needed: the draw was already ported, and Step 21 fixed its characters. `Guarded by:`
      is written on the closed tracker entry. The refill entry stays open with a note, because
      no refill has been seen on the cart since the fix
  - [x] Verification: the new check green
    - Closed in `m2snes` `cd8eb29`. `zig build test -Drom=…` 7808/7808. **Without `M2_ROM` in the environment the ROM tests
      skip silently**: the first fault run passed because of that. The gate was not re-run,
      because nothing the cart is built from changed

- [x] **Step 24: the Bomb and Spider Ball upgrades have corrupt graphics**
  - **Diagnosed 2026-09-24: two defects, and neither is the one Step 24 first guessed.**
    1. **The graphics.** The cart's `ITEM` arm only records `!ItemGiven`. The ROM's arm
       (00:$2624-$26D4) makes four transfers: `gfx_items` + ((op-1)&$F)·$40 to $8B40 (`$B4`-`$B7`,
       the item), `gfx_itemOrb` to $8B00 (`$B0`-`$B3`, the orb), $230 bytes of `gfx_itemFont`
       to $8C00 (the font and three characters past it), and `item_names[op&$F]` to $9C10.
       None is on the cart, so every orb and every major item draws from whatever the room's
       enemy sheet left there. That is corrupt, not blank, which matches the report. The Bomb is
       door `$145` (`ITEM 5`) and Spider Ball `$08D`/`$110` (`ITEM A`). `transition.zig` already
       models `ITEM` at 1 + 1+1+9+1 = 13 frames, and the cart charges 1
    2. **Spring Ball.** 00:$1721 is `BIT 0,A` on the pad (A) and then `BIT 4,A` on `samusItems`,
       which is **Spring Ball**. `PoseMorph`'s A-jump tests `!ITEM_BOMB`, so the ball jumps on
       A once the Bomb is held. `snes boot` phase 10 grades that wrong rule ("the ball jumps
       with the Bomb held"). The ROM's other spring tests are $0F47 (`PoseMorphHurt`, ported
       right), and $3A84/$3BC1, which choose Samus's graphics. The pickup arms set bits 4 and 5
       separately and are right
  - [x] Fixture first: both pickups' tiles compared against the cartridge's own bytes, the way
        `load`'s graphics check already compares a room's
    - `snes boot` **phase 28**, after 27: runs the Bomb's door ($145) and the Spider Ball's ($08D)
      through phase 27's door-index lever. Each time, `$B0`-`$B7` must be the ROM's orb and that
      door's nibble of tiles, at 4bpp in the object characters and 2bpp in the background's:
      **code 138**. The nibble comes from each door's decoded script, and the bytes from the arm
      `convert.itemArm` parses. **Code 139** if the script never finishes, or if the characters
      already hold the answer before it runs. Shown failing (138) with `.item`'s transfers
      skipped, and again with every nibble reading entry 0
  - [x] Diagnose before porting — corrupt rather than absent points at the conversion or the
        transfer, not at a missing draw, so this may be a `snes render` or region-layout defect
        rather than an engine one
    - It was a missing transfer after all, of a kind the guess did not name: `ITEM` loads the
      orb and item characters and the cart's opcode never did. See the diagnosis above
  - [x] Fix; `Guarded by:` line
    - `snes_convert.itemArm` parses the arm (bank, base, destinations, lengths, and the
      `(op-1)&$F × $40` index shape) and refuses anything else. The load table's prelude carries
      `ITEM`'s transfers after the font: orb and font, two copies each, then two per nibble
      (`load_item_at` 46, `load_item_tiles_at` 90, `load_entries_at` 442). They come from two new
      window assets, `item_window` (bank 7 $7790-$7B90: `gfx_items`, the orb and the common
      items, which is every source a nibble can index) and `item_font` ($230 bytes). `.item` runs
      the nibble's copies through `LoadCopy`, keeping the door script's pointer on the stack,
      and waits `!ITEM_WAIT` = 12. `correspond` holds the offsets, the wait, and
      `transition.item_bytes` to the arm's lengths
    - **The name (to $9C20) is not ported**; its frame is charged. It has its own tracker entry
  - [x] **Spring Ball is bundled into the Spider Ball** (James, tracker entry 2026-09-24). They
        are separate items in the Game Boy game (Spring Ball is item $0B, `bit_spring` 4, and
        it is collected somewhere else). Diagnose first: find out whether the pickup ORs both
        bits or whether a pose or collision test reads the wrong mask. The engine's
        `!ITEM_SPRING` history (2026-09-15, Step 14b) is the first place to look. Add a failing
        fixture, then fix and write the `Guarded by:` line
    - Diagnosed above: `PoseMorph` tested the Bomb's bit where 00:$1727 tests Spring Ball's, so
      it was bundled with the Bomb. Phase 10 now tries three times: cleared, the Bomb alone
      (**code 148**), and the Bomb plus Spring Ball's bit taken from the cartridge's pickup arm.
      Exit 148 on the pre-fix engine, 0 after. `PoseBallJump`'s comment named both wrong and is
      corrected. **Lua's 200-local limit**: the boot script's main chunk was at 200, so a new
      `local` there is a syntax error that Mesen reports as a 300-second timeout (255). The new
      constants are globals. `luac -p build-out/m2snes.lua` finds it in a second
  - [x] Verification: the new check green, and `snes render`'s 904/904 unmoved
    - **Closed 2026-09-24 in `m2snes` `6af2b80`.** Gate green, exit 0, "35 rungs, none retired".
      `snes render` 904/904, `reachable` 1999/1999, `anchored` 665 across 11 of 13,
      `durations` 28/60, `enemy AIs` 18, `enemy reload` 6, `fade` 168: all unchanged,
      although `ITEM` now costs 13 frames where it cost 1. So none of the graded stretches or
      durations crosses an `ITEM` door. Cart digest `07711f38…1889`. Standalone `snes boot`
      runs hit the known exit 81 on about a third of runs before phase 10; the gate's run did not

- [x] **Step 24b: the black flash at the start of a crossing**
  *(Added 2026-09-15 from James's report, after the attempt inside Step 17 failed and was reverted.
  Numbered `24b` rather than `28` so it sits with the other playtest defects, the way 12a-f and
  15a-d already do.)*
  - **Not a new defect.** The forced blank has been held across the whole door script since B1;
    `RunPendingTransition`'s comment has described it as a deliberate deviation the whole time.
    What is new is that the deviation now has a reported symptom and a measurement behind it
  - [x] Fixture first: a scrolling crossing must not blank the screen for the script's frames.
        The frozen room is what the Game Boy shows, and `snes boot` phase 27 already owns the
        scroll, so this is its neighbour rather than a new harness
    - **Phase 28, not a new phase.** It already runs the two `ITEM` doors, which don't fade, and
      `ITEM` is the worst case: six copies. A third door joins them, derived rather than named:
      the first door whose script loads an enemy sheet and does not fade (`$001`), which is what
      181 of the scrolling doors do. Its sheet is graded against the ROM like the items' (138).
      On every script frame: **code 128** if the frame ends blanked or below brightness 15 (the
      Game Boy's `$93`), and **code 129** if a window row lit before the trigger has gone black.
      A door with a `FADEOUT` is refused at generation
    - **Phase 27 leaves the room dark, and the phase has to undo that.** Its door ($104) fades,
      and it ends the scroll by clearing the direction, which skips `.finish` and so 00:$0C2B's
      fade-in. The room stays at brightness 0 for good, which no play reaches. Phase 28 starts
      the fade-in once, as 00:$0C2B does (palette `$93` and timer `$2F` read from the ROM, the
      two addresses from the engine's defines), and arms once the room is fully lit. A
      timeout there is 139, not 128
    - Shown failing: 128 on the pre-fix cart. 129 against a cart that blanks around each copy
      and lifts the blank straight after, which the register at frame end cannot see
    - **The `fade` rung's hole is closed too.** `fadeRows` skipped `$93` frames inside a door
      script and cited this step. It now grades every frame of its take: **1999**, up from
      168. It fails on the pre-fix engine (movie 471-613) and passes on this one
  - [x] **What was already tried, so it is not tried twice.** Narrowing the blank to wrap
        `DoCopy` alone — which is the only thing that needs it — fails `snes boot` **code 204,
        the HUD band**, and fails it in *phase 20*, long after the crossing is over. Long
        addressing on the `$2100` store does not change it, so the data bank is ruled out. The
        interaction between the transition's blank and the HUD's window/HDMA setup is the thing
        to understand before trying again
    - **Understood: it was never the HDMA.** `DoCopy` also runs for the boot record's script
      (`BootGraphics`) and for a load, under their callers' forced blank with NMI off and
      *before* `LoadHud`. A `DoCopy` that lifts the blank turns the screen on for the rest of
      the boot, and every VRAM write after it is dropped: the HUD's among them, and phase 20 is
      the first thing to look. Reproduced in kind: lifting the blank after the boot path's copy
      exits 12 (no characters at all). The 2026-09-15 code is not in history, so 204 itself was
      not reproduced
    - **And narrowing would have shown anyway.** Measured on the graded cart: the interpreter
      runs from line 241, 16 lines into vblank. `LOAD_spr`'s copy ran from line 2 to line 16 of
      the next frame, and `ITEM`'s six from line 8 to line 89
    - **Fix: the copies wait for vblank.** `RunPendingTransition` writes no blank. On a live
      crossing (`!TransRun`) `DoCopy` queues each copy (`!XferQ` at $07A1, six entries of seven
      bytes, committed by `!XferEnd` last), and `DrainXfers` makes them in the next NMI, after
      OAM and before the tilemap. Measured: every copy of the three doors lands on lines 229-242,
      and vblank runs 225-261. The boot path and a load still copy at once. The largest copy
      any door makes is the Queen's `COPY_spr`, 2560 bytes (about 15 lines), which is outside
      the slice and would still fit
  - [x] Keep the fade honest while fixing the scroll: a fade script has no palette fade yet
        (B1b's), so a crossing that stops blanking will hard-cut where the original dims.
        Decide deliberately whether the fade keeps its blank until B1b lands, and write the
        decision down either way
    - **Decided: the fade loses its blank too, because Step 20 already made it honest.**
      `FADEOUT` steps the palette to dark before any copy runs, and the rest of the script
      holds brightness 0. The widened `fade` rung grades exactly those frames against the Game
      Boy, 1999 of 1999
  - [x] Verification: the new check green, `snes boot` green end to end including 204, and the
        gate's `reachable` and `anchored` unmoved
    - **Closed 2026-09-24 in `m2snes` `e219e18`.** Gate green, "35 rungs, none retired", 7m17s.
      `snes render` 904/904, `reachable` 1999/1999, `anchored` 665 across 11 of 13,
      `durations` 28/60, `enemy AIs` 18, `enemy reload` 6: all unchanged. `fade` 1999 of 1999
      (was 168 graded). Shipped cart digest `ce1e995a…e97c`. `residue` now lists `DoCopy` as a
      reader of `!TransRun`
    - **Exit 81 is mostly a stale Mesen save.** One gate run went red on 81 with the same digest
      that had just passed. A passing `snes boot` leaves phase 26's save in
      `MesenCE/Saves/boot-check.srm`, and the next run of the same name hit 81 3 times in 3;
      with a fresh name or the `.srm` deleted, 15 runs in 16 did not. The pre-fix cart hits it as
      often. Not chased here, and one run in sixteen is still unexplained. The gate going green
      after deleting that file is the run recorded above

- [x] **Step 24c: Samus's animation freezes for the length of a crossing**
  *(Added 2026-09-15 from James's report. Distinct from Step 17's defect and outliving it: 17 was
  where she is drawn and whether she is drawn at all, this is which frame of the animation.)*
  - [x] **Measure which byte selects the sprite first, and do not port from a variable's name.**
        `$D022` was watched across the any% run's vertical crossing (frames 1387-1420): static at
        45 through ordinary play, **+3 on every frame of the crossing**, static at 147 after. A
        run cycle would do the reverse. So `!AnimTimer`'s comment — "the run cycle, and nothing
        else" — does not describe what that address does, and the byte that drives the drawn
        sprite has not been identified. Read the Game Boy's OAM tile index across the crossing
        and find what it follows
    - **Measured 2026-09-25: two bytes, and the crossing's camera advances both.** A search of
      the ROM for every instruction addressing `$D022` finds a read-add-3-write in each of the
      four arms of 00:$0B44 (at $0B60, $0B94, $0BC7, $0BFF), and $0B44's own first act is `INC`
      on `$D072`, the spin counter `drawSamus` reads for the ball, the spider and the spin jump
      (01:$4C94). `$D022` *is* `samus_animationTimer` — `drawSamus_run` reads it at 01:$4D77 —
      and the camera adds the 3 a frame `poseFunc_running` does. At 1387-1420 she is in pose
      `$01`, which draws from neither, so her tile holds while the byte climbs. That is what
      the earlier reading mistook for "the reverse of a run cycle"
    - The sprite follows on the Game Boy: across the ball crossing at 708-716 `$D072` goes $59,
      $5A ... one a frame, and the ball's OAM tile turns at 712 and 716. During the script
      before it (609-707) both hold, because the interpreter blocks. The any% run's first
      20 000 frames cross only in poses $01, $05 and $07, never running
  - [x] Fixture first, once the byte is known: the drawn sprite must change across a crossing
        the way the Game Boy's does. `snes boot` phase 27 is the neighbour, as with Step 24b
    - **Code 159, on the timers rather than the sprite**: phase 27 crosses standing, whose
      sprite reads neither, and every sprite that does is a function of these two alone. On
      every scroll frame after the first, the spin timer must be one up and the run cycle's
      three up — or zero, in the run pose, once the add reaches $30, as `drawSamus_run` writes
      back. `VarSpinTimer` and `ConstPoseRun` are new exports; the addresses ride in `B5`
      because the chunk is at its 200-local ceiling
    - Shown failing: **159 on the pre-fix cart, 10 runs of 10**
  - [x] Port whatever advances it, in the original's position. **The pose machine is not it** —
        `.transitionFrame` skips that correctly, per 00:$0522 — so the writer is somewhere the
        transition path already runs, or somewhere the port has not ported at all
    - The port had not ported it at all. `TransitionCamera` now does `inc !SpinTimer` ahead of
      its direction test (so a direction with no arm still advances it, as $0B44 does) and adds
      3 to `!AnimTimer` in each arm after the camera's move. `residue` lists it as a reader of
      both
  - [x] Correct `!AnimTimer`'s comment in `engine/main.asm` to what the measurement shows,
        whichever way it comes out
    - Both the define and `TransitionCamera`'s header, which called `$D022` "the count of
      columns and rows the scroll leaves owed". `feature_tracker.md` repeated that and is
      corrected too
  - [x] Verification: the new check green, and `reachable`/`anchored` unmoved
    - **Closed 2026-09-25 in `m2snes` `d1f4a95`.** Gate green, "35 rungs, none retired", 7m19s.
      `snes render` 904/904, `reachable` 1999/1999, `anchored` 665 across 11 of 13,
      `durations` 28/60, `enemy AIs` 18, `enemy reload` 6, `fade` 1999: all unchanged. Graded
      cart digest `312f908c…b5aa`. Unit tests green, `residue` included
    - **Phase 7's exit 81 is a harness flake, and a bigger one than Step 24b measured.** With
      fresh cart names and no `.srm`, the fixed cart hit 81 on 5 of 15 runs, which looked like a
      regression — but `TransDir` is never set before phase 8, so nothing this step changed
      runs there, and the *pre-fix* cart hits 81 too (2 of 6) under the same Lua. One extra
      `emu.read` per frame raised it to 4 of 5, so it tracks the Lua's per-frame cost rather
      than the cart. Mesen's SNES `RamPowerOnState` is `Random`; `--snes.ramPowerOnState=AllZeros`
      did not remove it. Not chased here; it will make Step 25's extra emulator runs flaky and
      should be understood before them

- [x] **Step 24d: `snes boot` phase 7 exits 81 on some runs of the same cart**
  *(Added 2026-09-25 from what Step 24c measured. Ahead of Step 25 on purpose: Step 25 multiplies
  the emulator runs, and at the measured rate it could not go green.)*
  - **What is known.** Code 81 is phase 7's neighbour compare (`compareAt`, band rows 8-15). Fresh
    cart names and no `.srm`: 5 of 15 runs of Step 24c's cart, 2 of 6 of the cart before it
    under the same Lua, 0 of 10 in one earlier batch; about 30 runs in all, so the rate is rough.
    `TransDir` is never set before phase 8. One extra `emu.read` per frame in the Lua raised it
    to 4 of 5, so it tracks the harness's per-frame cost rather than the cart. The HUD note in
    `snes_romtest.zig` records the same symptom with the state identical up to the frame. Mesen's
    SNES `RamPowerOnState` is `Random`; `--snes.ramPowerOnState=AllZeros` did not remove it, and
    whether Mesen honoured that switch is unconfirmed
  - **Why it blocks Step 25**: a faulted cart can exit 81 at phase 7 before it reaches the phase
    it faults, and 26 extra runs at even 1 in 16 fail about 81% of the time
  - [x] Measure the rate properly first, on the current cart and a fixed Lua: enough runs to
        tell 1 in 3 from 1 in 16, and record the count
    - **It has no single rate, and that was the finding.** Cart `312f908c…b5aa`, the gate's own
      staged Lua, fresh names, one run at a time: **3 of 40**, all three in runs 2-4 while a
      stray Mesen process was starting, then 36 clean. Interleaved against the fix under six
      busy cores: **0 of 40**. With a probe adding per-frame cost: **2 of 3**, then **2 of 10**.
      The same cart and script go from 0% to 67% on what the host and the Lua are doing
  - [x] Find what differs on a failing run. Leading hypothesis, unverified: `emu.getScreenBuffer()`
        at `endFrame` sometimes returns a frame that is not the one the OAM mask was computed
        from. Test it by comparing the buffer against the mask's frame (or against the previous
        frame's buffer) on the same run, and by confirming whether the RAM override is honoured
    - **The hypothesis was right, and the source says why.** Mesen2's `SnesPpu` sets
      `_skipRender` on any frame that starts within 10 ms wall-clock of the last one it drew,
      whenever the emulator runs flat out (the testrunner sets `MaximumSpeed`) and
      `Snes.DisableFrameSkipping` is off. A skipped frame neither swaps nor fills the output
      buffer, so `getScreenBuffer()` (which filters `GetPpuFrame()` synchronously) returns the
      last *drawn* frame while OAM is current. Sprite evaluation is outside the skip, so only
      pixels are affected
    - **Measured directly, not by rate.** The framebuffer hashed every 50th frame on top of the
      gate's Lua: two runs with `--snes.disableFrameSkipping=true` agree at **89 of 89**
      samples; a stock run differs from them at **7 of 89**, all between frames 150 and 400
      where Samus falls and walks, and matches wherever the screen is still. Same emulated
      frames, different pictures
    - **The switches are honoured**: the testrunner parses them before `ApplyConfig()` and with
      `DisableSaveSettings`, so James's settings are untouched. The RAM override was never the
      lever, and **the `.srm` was not either**: 0 of 10 reusing one name with the save kept
  - [x] Fix the cause, in the harness if it is the harness. No retries, and no weakening of the
        compare to hide a difference that is real
    - `verify.zig`'s `draw_every_frame` passes `--snes.disableFrameSkipping=true` on the two
      launches whose scripts read the framebuffer, `cold boot` and `snes boot`. The other ten
      Mesen launches read no pixels and are unchanged. The compare is untouched.
      `snes_romtest.zig`'s HUD note, which blamed Step 13b's callback, now cites the cause
  - [x] Verification: the measured batch again with zero 81s, the gate green, and the
        stale-`.srm` note in `bug_tracker.md` and memory corrected to what was found
    - **Closed 2026-09-25 in `m2snes` `c3b96e1`.** With the switch: **0 of 40** on the gate's
      script, **0 of 10** under the provoking probe (stock, interleaved: 2 of 10), **0 of 10**
      with the `.srm` kept. Gate green, "35 rungs, none retired", 7m24s (7m19s before),
      started with `boot-check.srm` in place. `snes render` 904/904, `reachable` 1999/1999,
      `anchored` 665 across 11 of 13, `durations` 28/60, `fade` 1999, `enemy AIs` 18,
      `enemy reload` 6: all unchanged; cart digest `312f908c…b5aa` unchanged. Unit tests green
    - `bug_tracker.md`'s exit-81 entry is closed with the measurement, and Step 13b's entry
      notes its diagnosis was wrong. **Not explained by this**: the `enemy AIs` `crawlerA
      corners` failure recorded beside the 81, since that rung reads no framebuffer
    - **No fixture fails on its own if the switch is removed** — the flake returns at a rate the
      machine sets. A guard that could would need a framebuffer read every frame, whose own
      cost stops the skipping it is meant to catch. Recorded as `Guarded by: nothing`

- [x] **Step 24e: Samus draws in front of the ship and of open door frames**
  *(Added 2026-09-25 on James's request, from `bug_tracker.md`'s 2026-09-24 entry: on the Game
  Boy she passes behind the ship she lands in and behind an opened door's frame; on the cart she
  passes in front of both. Numbered with the other playtest defects, and ahead of Step 27 so the
  hardware pass sees it fixed.)*
  - [x] **Measure how the Game Boy puts her behind before porting anything.** The candidates are
        OAM attribute bit 7 (OBJ behind BG colours 1-3, per pixel, by the BG's colour *index*,
        not its shade) on her parts, or something that decides it per room or per tile. Read her
        OAM attributes in Mesen2 GB standing at the ship and walking through an open door, find
        the ROM code that sets or clears the bit, and record the address. Do not port from a
        variable's name (Step 24c)
    - **Per screen, by a bit in the transition word, for every part at once.** From the ROM's
      bytes (`zig build disasm`): 00:$3ED5 reads the high byte of the word at $4300 +
      2·(screen_y·16 + screen_x) for *Samus's* screen ($FFC1/$FFC3, bank $D058) and stores bit 3
      inverted in $D057. 01:$4BA1-$4BAA, inside `drawSamusSprite` (01:$4B62), sets OAM bit 7 on
      each part while $D057 is 0, and 01:$4E18 zeroes $D057 once she is drawn. 00:$0C7E's
      `RES 3` is the same bit being kept out of the door index, which the cart already ports
    - **Measured on our Game Boy** (`room.zig`, "Samus goes behind the background on the
      screens whose transition word has bit 11"): standing at the ship, `$F:$76`, **12 of 12**
      parts have bit 7 and the HUD Metroid's two do not; on a bank-9 screen, **0 of 11**; at the
      ship with the bit cleared in a copy of the ROM, **0 of 12**. So the bit is the lever
    - **Which screens.** Bank `$F`: `$5D $5E $75 $76 $FE`; `$B`: `$38`-`$3B`; `$D` 78 and `$E`
      69; `$9`, `$A`, `$C` none. Door frames are behind only on these screens. It is not a
      door rule
    - **Only Samus changes per screen.** The other callers of $4B62 are the save text
      (`miscIngameTasks`) and the bombs (`handleBombs`). Both draw *before* `drawSamus` in
      `gameMode_Main` (00:$04DF), while $D057 still holds the 1 that the previous frame's
      `drawHudMetroid` stored at 01:$4B4F. Enemies and beams draw through other routines
    - **Found on the way, not fixed here:** the cart's `DrawSprite` also lacks $4B95-$4B9D, which
      sets OBP1 while `hSpriteAttr` is non-zero (acid contact or i-frames). `!SprAttr` exists
      only for the projectiles. Recorded in `bug_tracker.md`
  - [x] Measure the cart's side of the same frames: the OBJ priority bits `DrawSamus` writes, and
        the BG tile priority bits the converted tilemap carries at the ship and the door frame
    - **In front everywhere, for two reasons, and either would have been enough.** `DrawSamus`
      never reads bit 11 (its comment at $4B4F calls the variable irrelevant), so her parts get
      OBJ priority 2. And no BG3 word ever has tile priority 1 (`snes_target.play_priority`,
      `BlockWrite4`), so in mode 1 even priority 0 would draw above the play field.
      `PutObject`'s comment already said so. Shown on the frame by the cold-boot fixture below
  - [x] Fixture first: on a frame where her parts overlap the ship's or a door frame's non-zero BG
        pixels, the framebuffer shows the BG there as the Game Boy's does. The ship is where a new
        game starts, so `cold boot` is its neighbour; a door frame belongs beside the crossing
        phases. Shown failing on the current cart, and the entry's `Guarded by:` names it
    - `cold boot`, during the appearance sequence. She flickers there and nothing else moves, so
      the blank frame before a drawn one shows the ship alone. Inside her parts' boxes (from
      the PPU's OAM), wherever the blank frame's shade is not colour 0's (from the live BGP),
      the drawn frame must match it: **code 155**. **156** if the pair covered none of the
      ship's pixels or none of hers showed, and **157** if no pair ever formed. **Exit 155 on
      the current cart**
    - `snes boot`, **code 20**, on every frame the 124 check runs: her first OAM entry's
      priority must be 0 where her screen's transition word has bit 11 (`PRI_BEHIND`, taken
      from the ROM's seven tables) and 2 elsewhere. No phase stands her on a bit-set screen,
      so it guards the other direction, against a cart that puts her behind everywhere. It
      passes on the current cart, as it should. Shown live by inverting its expectation in a
      copy of the script: exit 20
    - **Door frames are not a separate fixture**: the rule is per screen, and a door frame on a
      bit-set screen is the same case as the ship
  - [x] Port the rule in the original's position. The SNES has no per-pixel "behind colours 1-3"
        bit, so the mapping (BG tile priority, OBJ priority, and colour 0 staying transparent the
        way the Game Boy's index 0 does) is a design decision: write down which and why before
        writing it. Check what it does to the HUD band, which is BG2 and also sits over her
    - **The mapping.** Mode 1's order puts OBJ priority 0 between BG3's two levels and nowhere
      else under BG3, so **every play-field word gets tile priority 1** and the object's own
      priority decides: 0 for the Game Boy's bit 7, 2 without it (`PutObject`'s translation,
      unchanged). BG3's colour 0 is transparent, so she still shows over index 0 as on the Game
      Boy. **The HUD band**: BG2's words stay priority 0, so priority 2 is above it and priority 0
      below its non-zero pixels, which is the Game Boy's rule for the window too. The title keeps
      priority 0 (`snes_target.title_priority`, new): nothing draws behind it
    - **Where the bit comes from**: `snes_target.play_priority` = 1 bakes it into converted
      metatiles, and the engine's `!PLAY_PRI` ($2000) goes on the words it writes itself:
      `BlockWrite4`, `DestroyBlock`'s `$FF`, `BlankTilemap`. `SeedWorld` writes only the low
      byte. `SampleTile` masks to the id. `correspond` ties `!PLAY_PRI` to `play_priority`
    - **The rule**: `LoadScreenPri` ports 00:$3ED5 from Samus's `!SamusY`/`!SamusX` screen bytes,
      not the camera's `!Cell`. `DrawSamus` calls it before the anchor and zeroes `!ScreenPri`
      ($07CB, after the transfer queue) once she is drawn. `DrawSprite` ports the $4BA1 arm.
      `DrawHudMetroid` stores 1 at $4B4F again, where it used to say "no store". `DrawSprite`'s
      callers are exactly $4B62's (Samus, save text, bombs, HUD icon); enemies and beams use
      `PutObject`. The cart's `MainLoop` has the Game Boy's order, so the text and bombs stay in
      front. `residue.zig` lists the new reader of `MapIndex`, `SamusX` and `SamusY`
    - **Faults**: the pre-fix cart exits cold boot 155. The fixed cart with `LoadScreenPri`
      forced to behind (`EOR #$08` → `LDA #$00` at the graded cart's $2C77) exits `snes boot` 20.
      The fixed cart: cold boot 0, `snes boot` 0
  - [x] Verification: the new check green, `snes render` 904/904 (it grades tilemap words, and a
        priority bit changes them), the gate green, and James's playtest of the ship and a door
    - **Closed 2026-09-25.** Gate green, "35 rungs, none
      retired". `snes render` 904/904, `snes boot` fault sweep 11/11, `reachable` 1999/1999,
      `anchored` 665 across 11 of 13, `durations` 28/60, `fade` 1999, `enemy AIs` 18,
      `enemy reload` 6: all unchanged. Cold boot green with the new 155-157. Unit tests green;
      two had to learn the bit: the metatile round-trip's high byte (`$20`) and `residue`'s
      reader lists. Shipped cart `0c417e23…6b73`. The gate's wall-clock was not captured
    - **James's playtest, in Mesen2, 2026-09-25: passed.** The FXPak run was skipped at his
      call; Step 27's hardware pass covers the cart on hardware. A door frame on a screen without
      the bit is *in front* of her on the Game Boy too

- [x] **Step 24f: the audio is far too loud**
  *(Added 2026-09-25 on James's request, from `bug_tracker.md`'s 2026-09-22 entry: "unbelievably
  loud … uncomfortable unless the sound is turned down to 10%". **This reopens a decision on a
  different question.** On 2026-09-21 James kept per-voice full scale 127 and `MVOL $7f`
  (audio cycle `03-measurements.md`, "The mix"), and that decision was about *clipping*. The
  same cycle measured the *level*: song `$04` at RMS 6177 on the cart against the Game Boy's
  1797, about 3.4x (~11 dB), and set it aside as "a decision, not a finding". The playtest says
  the level is the finding.)*
  - [x] Measure first: cart against Game Boy, RMS and peak, over the songs and effects the slice
        plays (`title`, `surface`, the item jingle, the Metroid music, beam and missile SFX), from
        the existing A/B renders (`zig build audioab`). Confirm the two Mesen cores' outputs are on
        the same scale before trusting the ratio: a per-core volume setting would fake one
    - **One scale, not a mix.** m2snes `build-out/audio-ab/` (2026-09-22 13:25, after the last
      engine and shim change), RMS over the whole file, cart ÷ SameBoy: songs `$11` 3.67,
      `$04` 3.44, `$0C` 3.43, `$0F` 3.50, `$15` 3.42; `int-item-get` 3.63, `int-missile-pickup`
      3.51; `sq1-07` (beam) 3.48, `sq1-08` (missile) 3.48, both over `$04` 3.51; noise `$02`
      3.52, `$03` 3.96, `$05` 3.31, `$0D` 3.35, `$0B` 3.66; `sq1-18` (health tick, RMS 185)
      2.88. **3.3-4.0x, 10.4-12.0 dB, every sound.** Peaks: SameBoy 15 661 on `$04`, the cart on
      the rail (32 511) on every song, so its crest is 5.3 against 8.7
    - **SameBoy is not what James heard, and Mesen2's GB core is quieter still.** Mesen2's
      settings have every per-channel volume at 100 on both cores, so no setting fakes a ratio.
      From Mesen2's source (`GbApu::UpdateOutput`, `Gb*Channel::GetOutput`, `Spc.cpp`,
      `SoundMixer::PlayAudioBuffer`, master): a GB channel is `7 - out` (15 steps p-p) ×
      (NR50+1) × 40, 4 800 p-p at full; SameBoy's is `(15 - 2·out)` × 34 × (NR50+1), 8 160 p-p.
      The S-DSP's samples go to the mixer unscaled, as `spcrun`'s do. So **in Mesen2 the cart is
      about 3.5 ÷ 0.588 ≈ 5.9x (≈15.4 dB) louder than the Game Boy**. Derived from source, not
      rendered: Mesen2's testrunner has no audio capture
    - **The levers.** Per-voice full scale: `VOLUME_FULL = 127` (`gbapu/shim.asm:169`) and
      `NOISE_DSP_VOLUME_FULL = 96` (`gbapu/memmap.inc:423`), mirrored by
      `gbapu.zig`'s `dsp_volume_full`. `MVOL`: `#$7f` at `shim.asm:598-601`. Both in
      snes_game_dev, reaching m2snes through `shimpkg` and `audio/shim/MANIFEST`
  - [x] Decide the target with James, and write it down: the leading candidate is the Game Boy's
        level as Mesen renders it, which is the oracle already used everywhere else in the audio
        work. **The lever matters**: the S-DSP clamps the voice sum *before* `MVOL`, so `MVOL`
        alone lowers the level and leaves the 0.8% near-rail `title` samples as they are, while
        per-voice full scale lowers both. Find where each is set (the shim is packaged in
        `snes_game_dev`, and `audio/shim/`'s MANIFEST pins it) before choosing
    - **Decision (James, 2026-09-25): SameBoy's level, by both levers.** Per-voice full scale
      127 → 64 (noise 96 → 48, in proportion), which the 2026-09-21 table shows leaves no
      near-rail samples on `title`, and `MVOL` for the rest of the way (≈ $46 by that table's
      RMS; set from the fixture's own renders, not from this estimate). SameBoy stays the
      oracle, as in the rest of the audio work. Mesen2's GB core would be ≈4.6 dB lower still;
      that figure is from its source and is not the target
  - [x] Fixture first: a level check — the cart's RMS against the Game Boy's on those songs,
        inside a written tolerance — that fails at today's ~3.4x, and the entry's `Guarded by:`
        names it
    - **`audio level`, the gate's thirty-sixth rung** (m2snes `src/audio_level.zig`, the set,
      grade and tests; `src/audio_level_run.zig`, the renders). Eight sounds: songs `$11`,
      `$04`, `$0C`, `$0F` (8 s each), `int-item-get.req`, `sq1 $07` and `$08` over `$04`, noise
      `$0B`. Mean square over each file, cart ÷ SameBoy in dB. **Tolerance: the set's mean
      within ±1 dB, each case within ±2 dB**, because the twenty sounds measured spread −1.7 to
      +1.1 dB about their mean and a volume model cannot remove that. By hand:
      `zig build audioab -- level`. `not run:` without `vendor/sameboy`, the ROM or `spcrun`;
      `build.zig` links SameBoy into `verify` only when it is there (`have_sameboy`)
    - **Shown failing in the gate** on the pre-fix shim: `FAIL audio level … +11.0 dB …
      farthest Samus killed +11.3`, and the only red rung of 36. Five unit tests hold the
      grade, including the pre-fix ratios failing and the same spread centred passing
    - **Found on the way: the A/B rendered the Game Boy in real time.** SameBoy's
      `GB_timing_sync` slept to the DMG's clock, so the first run took 53 s at 8% CPU, and
      `audio-ab-set.sh` its forty minutes. `sbref.c` now sets turbo (uncapped, no frame skip),
      which touches only the sleep and the display: all sixteen WAVs byte-identical before and
      after. With the `spcrun`s spawned together the rung takes about 1.3 s warm
    - `bug_tracker.md`'s 2026-09-22 entry carries the measurement, the fix and `Guarded by:`
  - [x] Make the change. If it is the shim, re-package through the MANIFEST so `audio shim` and
        `aram layout` stay green rather than being edited to fit
    - **snes_game_dev `3924c36`.** `shim.asm`: `VOLUME_FULL` 127 → 64, and `MVOL` from a new
      `MAIN_VOLUME` = $46; `memmap.inc` and `gbapu.zig`: `NOISE_DSP_VOLUME_FULL` 96 → 48.
      `expect.zig`'s model gains `dsp_full` = 64 (seven-bit noise uses it too) and
      `noise_dsp_full` = 48. `corpus.golden.txt` regenerated: 447 lines, volume columns only.
      gbbench's two tests that named 127-scale volumes now ask `volFor`. Tests green (with
      `--libc` at MacOSX26.5.sdk: SDK 27's libcxx break, unchanged)
    - **`MVOL` from the renders, not the table.** At full scale 64 and `MVOL` $7f the set read
      +5.2 dB (every case +4.9 to +5.5); 127 × 10^(−5.2/20) = 70 = $46. Then: **set −0.0 dB,
      cases −0.3 to +0.3 dB**, cart peaks 6 656-14 228 (SameBoy's reach 15 661), **no sample
      within 800 of the rail**
    - Synced by `tools/sync-shim.sh` from the commit: `MANIFEST`, `shim.bin`, `shimpkg.zig`
      change; `shim_abi.inc` does not, so `audio.bin` is not reassembled
  - [x] Verification: the level check green, the audio rungs (`audio shim`, `aram symbols`,
        `aram layout`, `audiocmp`) green, the gate green, and James listening on the FXPak at a
        normal volume. The entry is not closed on the numbers alone
    - **The numbers, 2026-09-25, m2snes `003fe79`.** Gate green, "36 rungs, none retired",
      532 s wall (including the rebuild that links SameBoy into `verify`; Step 25's 7m51s did
      not have one). `audio level` −0.0 dB, farthest `title` +0.3. `audio shim` names
      `3924c36`; `aram layout` 9691 B of 24 KiB, shim 7468 B; `aram symbols` and the engine
      reassembly unchanged. `audiocmp` over all 210 scripts in `test/audio/`: exact. `snes
      render` 904, fault sweep 11/11, `reachable` 1999/1999, `anchored` 665 across 11 of 13,
      `durations` 28/60, `fade` 1999, `enemy AIs` 18, `enemy reload` 6: all unchanged. Cart
      digest `3e12a19c…7e44` (the shim is in it)
    - **James's listen on the FXPak, 2026-09-25: passed.** "The sound is good, and requires no
      adjustments when going between different games." Shipped cart `516eb45d…acee0` from
      `zig build rom` at `003fe79`, carrying `MVOL $46` and not `$7f`. (The gate's `rom digest`
      hashes the injected image before the `rom` step finishes the cart, so it differs.)
      **Closed 2026-09-25**

- [x] **Step 24g: the text bar at save stations and major items**
  *(Added 2026-09-25 on James's request, with two screenshots. On the Game Boy, standing on a
  save station raises the HUD by one row and shows a black bar under it, `SAVE··· PRESS START`
  in white; a major item shows its name the same way. On the cart, at a station, the HUD stays
  on the bottom row, no bar appears, and the HUD row itself is damaged: the missile and Metroid
  icons and some digits are wrong and there are white blocks across it. Numbered with the other
  playtest defects. It absorbs `bug_tracker.md`'s 2026-09-24 entry for `ITEM`'s unported name
  transfer to $9C20.)*
  - **What is already known, and where it came from.** Step 15a ported the save arm's "window
    raise" and `COMPLETED`/`PRESS START` as sprites `$42`/`$43` at `$98`,`$44`, and recorded that
    their characters are the item font at `$C0`, which the cart did not load then. Step 24 loads
    the font to $8C00 inside the `ITEM` opcode only, and left the name (16 bytes of
    `item_names[op & $0F]` to the window's second row, 00:$26A0-$26CB) unported. Step 13b's
    HDMA split puts BG2 on from WY down, with WY fixed at `$88`. **Unverified reading**: the
    cart's white blocks are the text sprites landing on the HUD row, drawn from characters that
    are not the font, because the band never moved. Measure before believing it
  - [x] Measure the Game Boy first, in Mesen2 GB or on the recording (Step 15a's five saves,
        23 001 onward, and Step 11's pickups): what `rWY` holds before, during and after a
        station contact and a major-item pickup; which code writes it and which restores it
        (ROM addresses, not M2RoS line numbers or names); what the window's second row ($9C20)
        holds in each case and who writes it, including where `SAVE···` comes from; which part
        of the bar is window tiles and which is sprites; and what makes the bar black with white
        text while the HUD row is the other way round (the tiles' own colours, or a palette)
    - **Measured 2026-09-25 on the recording**, by a one-off replay script (the `gbtrace`
      driver with its own recorder; not kept) reading `rWY`, `LCDC`, the palettes, $9C00-$9C3F
      and the screen's pixels at 22 995/22 996/23 010/23 300 (the first save), 41 545 and
      50 100/50 115 (two later ones), and 44 300/44 330/44 500/44 700 (the Bomb). Every frame read
      `LCDC $E3`, `WX $07`, `BGP $93`
    - **`rWY` is $80 while she stands on a station, and while a major item's jingle runs; $88
      otherwise.** Every `LD A,n / LDH (rWY),A` in the ROM, found by its bytes (the `LDH`'s
      address): $88 at 00:$23FA and $240F (the door interpreter's `LOAD_BG/SPR` and `COPY`
      arms, beside clearing the save flags), 00:$24DA (`EXIT_QUEEN`), 01:$580F
      (`miscIngameTasks`, every frame) and 05:$40C2 (`loadTitleScreen`); $80 at 01:$5826 (item
      copy nonzero and below $0B) and $582C (the contact), 00:$3A21 (the item loop's first
      half), and 00:$2806 and $38CF (`animateGettingVaria` and `pickup_variaSuit`, outside the
      slice). At 44 300, in the Bomb's room before the pickup, it is $88; at 44 330 and 44 500
      $80; at 44 700, after, $88 again
    - **The bar is the window's second row, and it is written by `ITEM` and by boot only.** A
      write watch on $9C20-$9C2F from 22 000 to 50 110 saw ten writes, each a whole row: six by
      the transfer routine (PC 00:$2BC4) carrying `ITEM`'s name (22 455, 41 315, 43 137,
      46 008, 49 289: `FF D2 C0 D5 C4 DE DF FF…`, which is `itemName_00`, " SAVE<>"; 43 561:
      `FF×8 C1 CE CC C1 FF×4`, "BOMB"), and the game over's clears and `loadTitleScreen`
      (05:$40AA, 25 900), which copies `saveTextTilemap` (05:$4104, $14 bytes) there. So a save
      room's door script carries `ITEM $D0`, and that is what puts " SAVE<>" back after an
      item's name
    - **Text: window tiles, "PRESS START"/"COMPLETED": sprites.** `SAVE··` is the window row;
      the two sprites sit at OAM y $98, which is the second window row's line $88 once the
      window is at $80
    - **Colours: the tiles' own.** The bar is tile $FF and font glyphs, colour 0 under BGP $93
      (black) with the strokes in colour 1 (white); the HUD's tiles are mostly colour 1. No
      palette changes. The font is at $8C00, which both the window ($8800 addressing) and the
      objects read as $C0; the enemy page (`vramDest_enemies`, $8B00, 64 tiles) overwrites it,
      and `ITEM`'s third transfer puts it back, so the Game Boy's font is resident exactly when
      the room's door script ran `ITEM` (or after a file load, 00:$0858)
  - [x] Measure the cart on the same moments: `!HUD_VOFS` and the HDMA split's line, BG2's
        second row, and the text sprites' positions and character numbers against what $C0 holds
        on that frame. Confirm or refute the reading above, and say what damages the HUD row
    - **Measured 2026-09-25 on the gate's cart (`3e12a19c…`)**, `snes boot` phase 26 held on
      the station for 16 frames and dumped. The HDMA table reads `28 00 | 7f 14 | 09 14 | 08 12
      | 28 00`: the play field 136 lines, the window 8, which is WY $88 on a contact frame. BG2's
      second row is sixteen `$0000` words. "PRESS START" is ten OAM entries at y 176, which is
      the HUD row, tiles `$CF $D1 $C4 $D2 $D2 …`; the Metroid icon is raised to y 168, over the
      play field. **The reading is confirmed**: the text sprites land on the HUD row because the
      band never moved, and the icon sits a row above it. In this fixture the object font was
      resident (`$C0` held a glyph); James's room may not have had it, which would make the
      letters blocks. Not reproduced, since the fixture's station is laid, not a save room
    - **Phase 26's screen is at brightness 0**, left by phase 24's door, so no framebuffer
      check can see anything there. The new check has to fade in first, as phase 28 does
  - [x] Fixture first, beside the phases that already reach both moments: `snes boot` phase 26
        (the station) and phase 28 (the Bomb's `ITEM` door). On the contact frame and on the
        pickup, the framebuffer's band is one row higher, the row under it is the bar and holds
        the Game Boy's text, and the HUD row is intact. New codes, shown failing on the current
        cart, and the tracker entry's `Guarded by:` names them
    - **Four codes, 1-4, all `hud`** (the only unused ones left; a Lua error exits 255, so the
      low codes are clean). **1**, every frame the play handler owns, at code 207's site: `!WinY`
      (the port's `rWY`, `!ItemWindow` renamed) must be $80 when the icon's reason holds (a
      contact, or a major item's copy) and $88 otherwise, both operands read off 01:$580D and
      $582A. **2**, phase 9's Bomb jingle, once two passes in a row have raised it: `hud.bar`
      grades the status bar's row at WY $80 against BG2's first row, pixel for pixel, skipping
      pixels under a hardware OAM sprite. **3**, BG2's second row: `saveTextTilemap` at boot
      (read off `LD HL,$4104 / LD DE,$9C20 / LD B,$14` at 05:$40A0), and in phase 28 after each
      door the door's `item_names` entry (through the pointer table), unchanged after the sheet
      door. **4**, the bar itself: phase 28 gained a fourth door, the first non-fading one that
      runs `ITEM $D0` after its last object `LOAD` ($0AE, found, as the sheet door is), and then
      a Bomb pickup through phase 9's lever. Its jingle raises the window on a lit screen, and
      `hud.bar` grades both rows, the second against the ROM's item font
    - **Not phase 26's station, and why.** Phase 26 is dark (brightness 0), and a station laid in
      phase 28 was tried and refused: after door $0AE the collision table has no id with bit 7
      at all, so there is nothing to lay. The station's raise is code 1's, in phase 26; the
      picture is the same `!WinY`-to-NMI path for both reasons
    - **Shown failing on the current cart** (`zig build romtest`'s graded cart, which differs
      from the gate's only by the rename): exit 3 at boot; with 3 off, exit 1 on the first
      frame; with 1 off too, exit 2 in phase 9; with the status-bar row's half of `hud.bar`
      off, the bar's (code 4's path) in phase 28, on a second-row id that is no glyph
  - [x] Port the raise and the bar in the original's position: WY's writes move the split line
        (and whatever else keys off `$88`), the second row's writes go to BG2, and the font the
        text sprites draw from is resident whenever the save arm can draw them, not only inside
        `ITEM`. Close the $9C20 entry with it. Check where the lowered play window's bottom row
        goes, since the bar covers it on the Game Boy
    - **`!WinY` is the port's `rWY`** (`!ItemWindow` renamed, same address), written where the
      Game Boy writes it: `SaveStation` ($88 at 01:$580F, then $80 for the contact or a major
      item's copy), the jingle's loop (00:$3A21), the door's `COPY` arm (00:$23FA/$240F, which
      every converted `LOAD` is), and `LoadHud` at boot (05:$40C2). **`WriteWindow`**, in NMI
      after the scroll, turns it into the HDMA split's two counts (`!Bands+4` = WY - 127,
      `!Bands+6` = 144 - WY; the entry count does not change, so the death's and the readout's
      bytes stay put) and BG2VOFS = -(40 + WY + 1). The lowered play window's bottom row is
      simply off the main screen for those 8 lines, as the window covers it on the Game Boy
    - **Two timing facts the fixture had wrong first, both the Game Boy's.** `miscIngameTasks`
      is the pass's first call, so it reads the contact the *previous* pass's collision left:
      the window rises one pass after the icon at a station. And the collection's second wait
      loop (00:$3A63) draws the icon with the copy cleared and never writes `rWY`, so the window
      stays up, icon down, until the main loop resumes. The cart did both already; code 1 was
      rewritten to them
    - **The bar**: `saveTextTilemap` (new physics blob 38, 05:$4104) into BG2's second row in
      `LoadHud`; `item_names` (physics blob 39, the existing $120-byte entry with its pointer
      table) resolved by `.item` into `!ItemName` through `LD HL,$58F1` (00:$26AB), and written
      by NMI (`ItemNameUpload`). The main loop resolves it because `!TabP` is the main loop's
    - **BG2 reads the object characters** (`BG12NBA` $11 -> $61, `snes_target.bg2_char_base`).
      Found on the first green-up: the bar's ids were right and its glyphs were the dev readout's
      digits, because BG2 had a character set of its own (BG1's, shared) that only `LoadHud`'s
      twenty HUD tiles reached, and `ITEM`'s font "twin" is BG3's. The Game Boy's window reads
      $8800-$8FFF, which are its objects' $80-$FF, and BG2 is 4bpp like the objects, so
      pointing BG2 at them is the Game Boy's sharing exactly: the font is there when `ITEM` has
      put it there, and `LoadHud` no longer copies characters. A seventh queued copy was the
      alternative, and `ITEM` already fills the six-entry queue
    - `correspond` holds `ConstHudWY` to 01:$580D and 00:$23F8/$240D, `ConstHudWYUp` to
      01:$5824/$582A and 00:$3A1F, `ConstSaveTextCells` to 05:$40A6, and the two blobs and
      `ConstItemNamesBase`/`ConstItemNameLen` to the instructions that name them. The fault
      sweep gains `WriteWindow` and `ItemNameResolve` (row 24g, both `hud`)
    - Phase 28's picture after the fix, dumped: the status bar at lines 128-135 with the icon on
      it, and `SAVE··` in white on black at 136-143 -- the same rows, pixel for pixel in shape,
      as the recording's frame 22 995
  - [x] Add a `bug_tracker.md` entry for the save/item bar (James's report, this date) and close
        it and the $9C20 entry with the fix
    - The $9C20 entry is closed with its guard (code 3). The new entry carries the cause, the
      fix and `Guarded by:` codes 1-4, and **stays open until James's playtest**, as Step 24f's
      did; the box is ticked for the entry, not for the closure
  - [x] Verification: the new checks green, phase 26's HUD check (207) and OAM part count
        (123/124) unchanged or changed for a stated reason, `snes render` 904/904, the gate
        green, and James's playtest at a save station and at a major item
    - **The numbers, 2026-09-25, m2snes `a4d3bc7`.** Gate green, "36 rungs, none retired",
      8m11s. `snes boot` passes all 28 phases with codes 1-4 live, fault sweep **13/13**
      (`WriteWindow` and `ItemNameResolve` added, row 24g). Phase 26's HUD check (207) and OAM
      part counts (123/124) unchanged: they pass untouched. `snes render` 904/904, `reachable`
      1999/1999, `anchored` 665 across 11 of 13, `durations` 28/60, `fade` 1999, `enemy AIs` 18,
      `enemy reload` 6, `status bar` 281/281, `cold boot`, `load`, `death`, `round trip` and
      `audio level` (-0.0 dB) all green. Unit tests 7987/7987 with `M2_ROM` set. Shipped cart
      from `zig build rom`: `db5676e1…6dc0`
    - **James's playtest on the FXPak, 2026-09-25: passed.** "Both items look correct": the save
      station and a major item, on cart `db5676e1…6dc0`. Tracker entry closed in m2snes.
      **Closed 2026-09-25**

- [x] **Step 24h: B14 — the title's file select and the clear, on slot 0**
  *(Added 2026-09-25 on James's request, with three screenshots: the cart's title has the logo
  and nothing under it; the Game Boy's has a pulsing cursor at `START 1` and `©1991 Nintendo`;
  Select shows `CLEAR`, and holding Down moves the cursor and the number to it. Numbered with
  the playtest steps because it is the last thing before the slice is complete. B14 in the
  requirements. **Split at the plan's sanity check** into this step, which ships the picture,
  the menu and the clear on slot 0, and Step 24i, the three slots, so the title gets a commit
  and a playtest of its own and a save-path problem cannot hold it up.)*
  - **What is already known, and where it came from.** The original is `titleScreenRoutine`
    (05:$4118-$42C6). Its sprites come from `creditsSpritePointerTable` (01:$744A, `offsets.zig`'s
    `metasprite_credits_pointers`/`_data`) through `drawNonGameSprite` (01:$73F7), which honours
    the flip bits and ORs the call's attribute in — a different walker from `drawSamusSprite`.
    Read off the ROM 2026-09-25: `START` is sprite `$00` (five parts, tiles `$F1`-`$F5`), `CLEAR`
    `$01` (`$F6`-`$FA`), the cursor `$02`/`$03`/`$04` (`$ED`/`$EE`/`$EF`), the star `$06`
    (`$EF`, attr `$80`), and the slot numbers `$23`-`$25` (`$FB`-`$FD`, x +$36, attr `$80`). All
    of those object ids are $80-$FF, which on the Game Boy is $8800-$8FFF, the first $800 bytes
    of the title's character run: **the objects read the title's own characters**. The cart has
    neither half. `sprites.zig`'s `Which` ships Samus's and the enemies' sets and not the credits
    set, and `snes_convert.basisFor` classifies the four title sheets (`graphics_ui`) as `chr_bg`
    only, so nothing puts them where the objects look. The cart's RAM is already laid out for
    three slots (`!SRAM` comment, `save.zig`'s `slots = 3`); the engine hardcodes slot 0 in four
    routines (`TitleStart`, `LoadSaveFile`, `LoadEnemySaveFlags`, the save at ~16199 and its
    spawn-flag copy) and writes 0 to `$A0C0`. `bootRoutine` (00:$01FB) clears $D000-$DFFF, so
    every title visit starts with clear hidden and the cursor on `START` (B14). `snes boot` has
    no exit codes left (Step 24g took the last four), so the title's checks are a rung of their
    own, with their own script and codes, the way `cold boot` and `load` are
  - [x] Measure the cart and the Game Boy before believing any of the above
    - The cart's copyright row: dump the title's framebuffer, BG3's row 16 map words and the
      characters they name, and say why `©1991 Nintendo` is drawn as a few dashes. The ids are
      `$0F $1F $3E $3E $3F`, `$4A`-`$4F`; by `charForTitleId` they are run characters `$8F`,
      `$9F`, `$BE`, `$BF`, `$CA`-`$CF`, inside the $1000-byte run. Candidates, none believed: the
      run is not all uploaded, something overwrites those characters after it is, the row falls
      outside the band BG3 is shown in, or the map words are wrong
    - The Game Boy, on our emulator from a cold boot (`gb/harness.zig`, as `death.zig` and
      `hud_oracle.zig` drive it): `frameCounter`'s value on the title's first frame (the
      cursor's animation phase is `frameCounter & $0C`), OAM every frame with slot 0 the star,
      and `activeSaveSlot` ($D0A3), `title_clearSelected` ($D07A) and `title_showClearOption`
      ($D0A4) under the input sequence below; and **the frame, relative to the pad, on which each
      input first takes effect** on both machines — the cart reads `!InputRisingEdge` a frame
      behind the poll (`PublishPad`), and that offset is measured, not assumed. Also read off the ROM, by bytes, not by M2RoS
      names: the select sound's and the cleared-file noise's ids at 05:$425A and the clear
      branch; `bootRoutine`'s `saveLastSlot` read and its `CP $03`; and the number sprites'
      attribute `$80` — what the Game Boy's object-behind-background rule shows on the title's
      `$FF` background, so the cart's priority is chosen from it rather than from Step 24e's
      `!ScreenPri`
    - **Measured 2026-09-25.** *The copyright row is not drawn on the cart, and the cause is
      Step 24g, not Step 7.* A Mesen probe (framebuffer, BG3's map, `!Bands` into SRAM) on the
      shipped cart: BG3's row 16 words are right (`$8F $9F $BE $BE $BF`, `$CA`-`$CF`), and
      window lines 128-143 are black but for a 64-pixel stripe on line 142, the "dashes". The
      band table reads `28 00 | 7F 14 | 81 14 | 90 12 | 28 00`: `!WinY` is 0 on the title,
      because `InitState` seeds it after `TitleScreen`, so NMI's `WriteWindow` (a4d3bc7) writes
      `0-127 = $81` and `144-0 = $90` as line counts. Both have bit 7 set, HDMA falls into
      repeat mode, and BG3 is off from line 128. **Two more divergences came with it.** The
      Game Boy's title has the window *off* (05:$40C8 `LD A,$C3`), so its row 17 is background
      (stars); the cart's band would show BG2 there even with `!WinY` right, the same thing
      the game over already handles by copying `!BAND_PLAY_TM` over `!BAND_HUD_TM` (00:$3700).
      And the cart's title is **one line higher** than the Game Boy's (the star at GB line 120
      is at the cart's 119, the copyright's top line at 127 against 128): `TitleScreen` sets
      `!CamY` to `!CAM_MIN_Y+1` for "the extra line `!SCROLL_Y_BIAS` carries", but the bias
      already carries it, and the render rung's `top = camy - CAM_ORIGIN_Y` puts that at
      line 1. The game over's `$36F5` copies the same `+1`.
      *The Game Boy* (`title_oracle.zig`'s measurement, cold boot, no boot ROM): the title's
      first frame has `frameCounter` = 1, and **the same after a death** (slot 0, clear
      hidden, clear not selected), which confirms B14's "every visit opens the same way". The
      star is OAM slot 0 on every frame (`hOamBufferIndex` starts at 0), at y 0 until it
      falls. Cursor `$ED`/`$EE`/`$EF`/`$EE` by `(fc & $0C) >> 2`, number `$FB` at x `$6E` attr
      `$80`, `START` `$F1`-`$F5` from x `$44`, `CLEAR` `$F6`-`$FA` at y `$80`. **Latency:** a
      pad change on frame *i* shows in the state bytes after frame *i*+1 and in OAM after *i*+2
      (the frame draws before it reads input, and OAM is the shadow a vblank later); a Down
      release is the same. The cart's offset is measured by the rung against the ported cart,
      since there is no menu on it to measure yet. **Every menu sprite pixel sits on
      background colour index 0** (LCDC `$C3`, BGP `$93`), so the number's behind-background
      bit changes nothing on this screen: the cart uses ordinary priority and a unit test pins
      the zero overlap. Off the ROM by bytes: the select sound is `$15` to `$CEC0` (05:$41D8,
      $41F1, $4211, $4241, $425A), the cleared-file noise `$0F` to `$CED5` (05:$42A6); the clear
      zeroes `$A000 + slot*$40` and the next byte; `bootRoutine` reads `$A0C0` at 00:$02BA and
      takes it on `CP $03` / `JR NC` (00:$02BD). **Two corrections to the text above:**
      `drawNonGameSprite` **XORs** the call's attribute in (01:$7440 `XOR (HL)`), not ORs; and
      `titleScreenRoutine`'s Down test is `BIT 7` of the held byte (05:$4232), a mask, not an
      equality, so Down with another button held still selects clear. `Select`, `Right`,
      `Left` and `Start` are equalities. `title_showClearOption` toggles by `XOR $FF`, so it
      holds `$00` or `$FF`
  - [x] The reference: `src/title_oracle.zig`, our Game Boy emulator running a fixed input
        sequence from a cold boot — idle for a cursor cycle; Select; Down held 8 frames and
        released; Down without the option shown; Select with another button held (the
        equality: no toggle); Select, Down, Start on `CLEAR` against slot 0 seeded with a save;
        and Start. Left and Right are Step 24i's, which extends the sequence. Per frame it records the menu
        sprites as a set of (id, x, y, attr) — OAM slot 0 excluded, because the star is always
        drawn first — the three state bytes, and after the clear the cart RAM's three slots
    - Unit tests: the tables and records come off the ROM (`titleCursorTable` 05:$42E1, the
      nine sprite records); the recorded sequence has the properties the requirement states
      (releasing Down returns the cursor on the next frame; the clear zeroes two bytes of the
      selected slot and nothing else; the wrap); and **the old wrong answer fails** — the
      oracle's expectation does not match a run of the current title, which draws no sprites
    - **How the two runs line up, written down before any grading.** Per the standing rule
      (grade play exactly, re-anchor on each handover), each input event is an anchor: the
      comparison re-aligns on the first frame the input takes effect on each machine and is
      exact from there to the next event. The cursor's animation phase on the title's first
      frame is **its own check** (the cart's frame counter against the Game Boy's
      `frameCounter & $0C`), not an offset tuned until the sprites match
    - **Done 2026-09-25**, `src/title_oracle.zig`, `zig build test-title` (4 tests, and in
      `zig build test`). `run` boots cold with every slot seeded (James's first save, the
      slot's number in its last byte), records from the title's first frame, and ends when the
      mode leaves the title. `menuFor` derives the menu from the ROM (the instruction operands
      and the credits records) and the emulator's OAM equals it on every frame, **which pinned
      the lag**: OAM at title frame *t* is drawn from the state and counter frame *t*-1 left,
      and a pad change at *t* is in the state at *t*+1. The script: idle 20; Select; Down held
      8 and released; Select; Down with the option hidden; B+Select together (no toggle); B
      then Select (toggles, because only the edge is compared); Down, Down+Start (the clear);
      Start (a new game). Two things the plan did not know: the mode after Start is `$02` for
      a new game **and** a load, since `$0B` and `$0C` are both passed inside the frame, so
      the oracle records `loadingFromFile` ($D079) and the new game is graded on it; and the
      sequence ends on title frame 107.
      **How the two runs line up.** Title frame 0 is the frame the title is first up, and on
      it the cart's frame counter must equal the Game Boy's (1) — the cursor phase's own check.
      The pad script is played from title frame 0 on both machines. Each event that changes
      a state byte is an anchor: the rung finds the frame it takes effect on the cart and on
      the Game Boy, and grades exactly from there to the next anchor. A correct port has the
      same offset at every anchor; the rung reports each and fails if one differs from the
      first, rather than re-aligning silently
  - [x] Fixture first: a new `title` rung in `verify.zig` (`snes_romtest.writeTitle`, its own
        Lua and exit codes, `draw_every_frame` because it reads the framebuffer), driving the
        cart through the same input sequence on the shipped new-game cart, with the load rung's
        SRAM seeding for the clear. It grades: the copyright row's pixels against the Game
        Boy's render of row 16; per frame, the cart's menu sprites (read back from OAM through
        `PutObject`'s offsets) against the oracle's set; the three state bytes against the
        oracle's; the cleared slot's first two bytes zero and the other two slots unchanged;
        and a Start after the clear beginning a new game rather than loading. Opening state is
        checked after a cold boot here, and after a game over by whichever is cheaper — a code
        in the existing `death` rung, which already reaches the title, or a death inside this
        one — with the choice and its reason written down
    - Shown failing on the current cart, code by code, and each code's meaning recorded in
      `verify.zig` the way `coldBootTest`'s are. Watch the 201-local ceiling
      (`m2snes-silent-test-traps`): the reference tables go in as data, not locals
    - **Done 2026-09-25.** `snes_romtest.writeTitle`, `verify.zig`'s `title` rung (codes 90-100,
      `titleCode`), `build-out/m2snes-title.lua` from `zig build romtest`. **An order slip, said
      plainly:** the engine port was written before the rung, not after. The fixture-first
      evidence is still real: the rung was run against the **HEAD cart** (`4907efe`, built in a
      worktree) with a variant that records every code instead of stopping at the first, and
      it fires **93** (frame 5), **94** (1), **95** (21, Select), **96** (1), and **97, 98, 99**
      (94: the old title leaves on Down+Start's edge and loads slot 0). 92 is vacuous there
      (the old cart has no such bytes), 90/91/100 are guards. Opening state after a game over
      went into the **`death` rung as code 193**, the cheaper of the two: it already reaches the
      title after its second death, and it now leaves the title's bytes stale ($FF, $01) at the
      kill so the reboot has something to clear; the HEAD cart fails it (no cursor).
      **How the rung lines up, measured rather than chosen** (this replaces the per-anchor
      re-alignment written above, which it makes unnecessary): both machines run the same
      loop, vblank (counter up, shadow out) then one `titleScreenRoutine`, so title frame *n*
      is the iteration run with the counter at *n* on both, and the cursor phase needs no
      offset. Two sampling facts place the reads: Mesen's end of frame falls after the cart's
      iteration and before the next upload, so the cart's **shadow** is frame *n*'s draw and
      its PPU OAM frame *n*-1's (both graded); and the cart polls a vblank before it consumes
      (`PublishPad`) where the Game Boy polls in the vblank just before, so the Game Boy's pad
      for frame *t* is set on the cart's poll at vblank *t*. With those, every state byte and
      sprite matches on all 106 title frames with no offset anywhere; a press a frame early or
      late fails 95. The leave frame: the cart leaves inside the iteration that takes Start,
      and `InitState` reseeds the counter before that frame ends, so the last title frame it
      shows is the Game Boy's leave frame - 1 (code 99 either side). The Lua's own
      fault: `phase_fault` expects the cursor a step on and exits 96
  - [x] Port the picture and the menu, slot 0 only
    - Whatever the copyright measurement found, fixed at its cause
    - The credits metasprite set shipped (`sprites.zig` `Which`, the engine's `!MS_*` ids), and
      the title run's first $800 bytes given a `chr_obj` twin at object characters $80-$FF —
      a converter rule in `basisFor` beside rule 3's shared window, derived from
      `title_loadGraphics`'s destination, not a per-sheet exception — uploaded by
      `UploadTitleChr`. The game over's screen shares it, and the Game Boy copies the same
      characters there too, so that is the original's behaviour; the `death` rung staying green
      is what shows it
    - **The cart image changes**: the twin adds $1000 bytes of 4bpp characters and the credits
      set its records, so the asset list and the cart digest move. Re-run the asset-region fit
      (`zig build coverage` and the region sizing Phase 0a measured at 70% for its tightest
      class) and record the new numbers for the classes that grew
    - `DrawNonGameSprite`: `drawNonGameSprite`'s walk (the flips and the ORed attribute) over
      `PutObject`, rather than a flag on `DrawSprite`
    - `TitleScreen`'s wait loop becomes `titleScreenRoutine`'s frame: clear the OAM shadow,
      draw cursor, number, `START` and `CLEAR` in the original's order, then the input arms,
      each an equality where the original's is. The clear branch (`.clearSaveBranch`): the
      noise, the slot's two bytes, the option hidden, and back to the loop. The palette flash
      and the star are not ported (B14 out of scope), and a comment says so where they would be
    - `correspond` holds every new constant (positions, sprite ids, the cursor table, the sound
      ids) to the instruction that names it
    - **Done 2026-09-25.** Engine: `TitleScreen` sets `!WinY` = 05:$40C0's `$88` and the
      band's window lines to BG3 before NMI (and restores `!TM_HUD` on the way out), both
      cameras use `!CAM_MIN_Y`; `TitleFrame` (bank 0: Select, Down's mask, Start, the clear)
      calls bank 1's `TitleDraw` and `DrawNonGameSprite` through two `rtl` trampolines,
      `FindBlobLong`/`PutObjectLong`. **Bank 0 was full** (about 260 bytes free at HEAD), which
      is why the draw, the walker, `TitleResolve` and `UploadTitleObj` live in bank 1, as the
      readout does. The walker takes no flips and no XOR: every title call passes zero, and a
      branch no caller reaches would be untested code. Boot record **version 16**,
      `BootTitleObj`. Converter: `sprites.Which` 8/9 ship the credits set; `markTitleWindow`
      marks every bank-5 entry the title's copy (read off 05:$42C7's three operands by
      `titleCopy`) lands in $8800-$8FFF as `chr_obj` too, which is `gfx_titleScreen` alone.
      `correspond`'s new test pins fourteen constants to their instructions, the cursor table
      to 05:$42E1's bytes, the clear's six shifts, and `ConstTitleObjFirst` to the copy's
      destination. `audio_sites` loses three waivers (05:$41DA, $4243, $42A8), keeping Right's
      and Left's for 24i. `residue` gains the new readers (`TitleDraw` on `FrameCount`,
      `TitleFrame` on both pad words, `DrawNonGameSprite` on `SprX`/`SprY`)
    - **The region fit, re-run by the gate's `snes layout` rung**: 309 KiB converted into 424
      KiB reserved; **the tightest class is `chr_obj` at 92% of its 64 KiB**, up from about 84%
      (the twin is $1400 bytes of 4bpp; the credits set adds $5A5 bytes to `metasprites`).
      That is well past Phase 0a's 70%, and it is the class a later step will run out of
      first. `coverage` reads 200/256 KiB claimed. (`zig build convert` does not build on HEAD
      either: its step never wires `audio_bin`. Not this step's, and noted rather than fixed)
  - [x] The fault sweep gains the new routines (the menu draw, the sprite walk, the clear), each
        caught by the `title` rung's code for it; `conformance.md`'s table and roster gain the
        rung; a `bug_tracker.md` entry for the copyright row (a defect in Step 7's title), with
        the cause and `Guarded by:`, open until James's playtest
    - **Done 2026-09-25.** `verify.zig`'s `title_faults`: `TitleDraw` → `rtl` (96),
      `DrawNonGameSprite` → `rts` (96), `UploadTitleObj` → `rtl` (94), `TitleFrame_clear` →
      `clc`/`rts` (95, the option stays shown), all four caught by their codes, in parallel
      as `snes boot`'s are. A sweep of the title rung's own rather than `snes boot`'s, whose
      verdicts are its phases. `conformance.md`: roster row and audit row 24h; `death` notes
      193. `bug_tracker.md`: the title entry, open until the playtest. **It corrects this
      sub-task**: the copyright row is Step 24g's regression, not Step 7's; Step 7's is the
      one-line shift, and Step 13b's the window on row 17
  - [x] Verification: the `title` rung green and every fault caught; `cold boot`, `load`,
        `death`, `round trip`, `snes boot`, `snes render` 904/904 and the rest of the gate green;
        the gate's wall-clock re-measured; unit tests with `M2_ROM` set. James's FXPak playtest:
        the title matches the Game Boy's screenshots, and a clear really empties the slot
    - **Gate green 2026-09-25**: `zig build verify` exit 0 in **7 min 31 s** wall-clock; `title`
      green with `phase_fault` (96) and 4/4 faults; `cold boot`, `load`, `death` (with 193),
      `round trip`, `snes boot` (13/13 faults), `snes render` 904/904 and the rest green.
      `zig build test` with `M2_ROM` set: 0 failures.
    - **Playtest passed 2026-09-25** (James, FXPak, cart `f786e9e3…`, m2snes `87d1396`): "Title
      screen looks good. The menu works, and it can successfully clear the sram for save 1."
      Tracker entry closed in m2snes. **Closed 2026-09-25**

- [x] **Step 24i: B14 — three save slots, Left and Right**
  - **Why it is cheap, and how to tell if it is not.** The cart's RAM is already laid out for
    three slots and `save.zig` decodes all three; the engine hardcodes slot 0 in four routines
    and in the `$A0C0` write (Step 24h's list). If threading the slot turns out to touch more
    than those, say so and re-plan rather than widen the step
  - [x] Fixture first: extend Step 24h's reference sequence and `title` rung with Right ×3
        through the wrap and Left ×3 back, Right with another direction held (the equality: no
        step), the sound on each step, the number sprite following the slot, a clear in slot 1
        leaving slots 0 and 2 unchanged, and a save and load in slot 2 read back through
        `save.zig`'s decoder. Boot's seeding from `$A0C0` graded with the byte set to 2 and to
        an out-of-range 3. Shown failing on Step 24h's cart
    - **Done 2026-09-25.** `title_oracle`: `seedSlots(last_slot)` seeds `$A0C0` too, `run`
      records the slots and `$A0C0` before and after, and counts the select sound per frame
      with the harness's execution watch on the five `LD A,$15 / LD ($CEC0),A` stores
      `selectSites` finds in `titleScreenRoutine` (05:$41DA, $41F3, $4213, $4243, $425C,
      pinned by a test). The script opens on slot 2 (`seed_last_slot`) and adds Right ×3 (2→0
      wraps), Left ×3 (0→2 wraps), Up then Up+Right (no step), Left to slot 1, the clear on
      slot 1 and Start (a new game there); it now ends on title frame 167. Tests: the steps,
      the sound once per step and 13 in all (the clear's Start branches at $4254 before the
      select sound at $425A, so it is the noise alone), slot 1's two bytes and `$A0C0` = 1
      the only changes, and boot's seed for `$A0C0` 0/1/2/3/$FF. **Read off the ROM by bytes**:
      Right and Left are two equalities each (`FE 10`/`FE 20` on the edge and the held byte),
      the wraps are `CP $03` at 05:$41FD and `CP $FF` → `LD A,$02` at $421D/$4221, and boot
      takes `$A0C0` on `CP $03` / `JR NC` at 00:$02BD.
      The `title` rung: SRAM is seeded **before the boot** (below), code 92 grades the
      opening slot against the Game Boy's, 97 covers `$A0C0`, new **103** counts the cart's
      `(square 1, $15)` pairs in `!AudRec` against the Game Boy's per frame, and a
      `last_slot_3` run (seed 3, graded to title frame 4) must pass. The `round trip` rung
      gains a `slot2` run: Left on the title (0 wraps to 2), then the same save, death and
      load, with **213** (Left did not select slot 2), **214** (the record or spawn window
      written outside slot 2, the window not the buffer, or `$A0C0` not 2) and **215** (the
      reboot's title not on slot 2, or the load's flags not slot 2's). The plan's "read back
      through `save.zig`'s decoder" is the rung's `O` offsets, generated from `save.fields`:
      Mesen's Lua cannot hand bytes back to Zig. `zig build romtest` also writes
      `build-out/m2snes-trip2.lua`.
      **Shown failing on Step 24j's cart** (`8567711`; 24j sits after 24h): `title` exits
      **92**, and a variant that records every code instead of stopping hits **92, 95, 96**
      (title frame 1: slot 0 and `$FB` where the Game Boy has 2 and `$FD`), **103** (frame
      91: the first Right, no sound) and **97** (frame 166: slot 0 cleared, `$A0C0` 0);
      `round trip` `slot2` exits **213**. The slot-0 trip with the new window checks passes
      on it, so 214/215 are not tripping on something slot 0 already does.
      **Found on the way, and fixed in the harness rather than the step's engine list:
      Mesen keeps a cart's RAM between runs**, per ROM file name
      (`~/Library/Application Support/MesenCE/Saves/*.srm`), and powers a fresh one on with
      noise (`$7A` at `$C0` on the probe). Once boot reads `$A0C0`, a slot-2 run would leak
      into the next `load` or `death` run sharing `load-check.sfc`, and a new file name
      could boot on a random slot. Measured that a write in the Lua main chunk is what the
      cart reads, so `snes_romtest.writeSramPrelude` zeroes cartridge RAM (and writes the
      title's seed) before the boot in all five new-game writers: `cold`, `load`, `death`,
      `round trip`, `title`. Handover carts skip the title and never read it
  - [x] Port it
    - `!ActiveSlot` (the port's `activeSaveSlot`), seeded at boot from `$A0C0` when below 3,
      as `bootRoutine` does (its address read off the ROM in Step 24h's measurement); Left/Right
      on the title with the wrap; `TitleStart`'s magic walk, the save, the load and both
      spawn-flag copies at `slot*$40` and `$1000 + slot*$200`; `TitleStart` writes the slot to
      `$A0C0`. The existing `load`, `death` and `round trip` rungs keep slot 0 as their default
      and pass unchanged
    - `correspond` holds the wrap bounds and the slot stride to the instructions that name them
    - **Done 2026-09-25**, and within the step's list: `TitleStart` (the walk and the `$A0C0`
      write), `LoadSaveFile`, `LoadEnemySaveFlags`, `SaveFileToSram`, `SaveEnemyFlags`, the
      clear, plus the seed and the arms. **Bank 0 had 52 bytes**, so the new code is in bank
      1 behind `jsl`: `TitleSeedSlot` (00:$02B6-$02C3, called from `TitleScreen`, so only on
      the title's path; a handover record is a moment of the recording, whose slot is 0),
      `TitleSlotStep` (05:$41E5-$4223), `SlotRecP` (`!SlotP` = $70:slot*$40) and `SlotSpawnP`
      (`!SlotP` = $70:$1000 + slot*$200, the Game Boy's `ADD A,A / ADD A,D` into the high
      byte). `!SlotP` is DP $FD-$FF, the last three free bytes. The save's stores are
      `sta.l !SRAM+$xx,x` with X the slot's offset; the loops and Start's walk go through
      `[!SlotP],y`. The bank-1 sound goes through a new `%audio_put_long` and a 4-byte
      `AudioPutLong` trampoline; `audio_sites` parses it and loses the last two waivers
      (05:$41F3, $4213). Bank 0 ends at $FBDE, 34 bytes free. `!SRAM_RECORD` is gone.
      Citations were checked against `zig build disasm`, not guessed.
      `correspond`: `ConstSaveSlots` against 05:$41FD and 00:$02BD, `ConstSlotLast` against
      $4221, the two new `ConstSfxSelect` sites, the six shifts at all four Game Boy sites
      and `ConstSlotShift`, the spawn stride's bytes at 01:$7A9D and $7AC4 and
      `ConstSpawnSlotShift`, and Left's `CP $FF`; the writer-order check reads the new `,x`.
      `residue`: `TitleSlotStep` reads both pad words. `zig build test` with `M2_ROM`: green
  - [x] The fault sweep gains the slot step and the slot offset, each caught by the `title`
        rung's code for it; `conformance.md` updated
    - **Done 2026-09-25.** `title_faults` gains four, and a fault now names the title run
      that grades it: `TitleSeedSlot` → `rtl` (92), `TitleSeedSlot_bound` widened to
      `cmp #$04` on the `last_slot_3` run (92), `TitleSlotStep` → `rtl` (95),
      `SlotRecP_slot` held at slot 0 (`lda #$0000`, 97). The spawn window's offset is not
      the title's to see, so it was checked by hand against `round trip` `slot2`:
      `SlotSpawnP`'s `asl a` → `nop` puts slot 2's window on slot 1's and exits **214**. Not
      in the gate: `round trip` has no fault sweep beyond `energy_fault`.
      `conformance.md`: the `title` and `round trip` roster rows, and audit row 24i
  - [x] Verification: the `title` rung green and every fault caught; `cold boot`, `load`,
        `death`, `round trip` and the rest of the gate green; the gate's wall-clock
        re-measured; unit tests with `M2_ROM` set. James's FXPak playtest: the three slots save,
        load and clear independently
    - **Gate green 2026-09-25**: `zig build verify` exit 0 in **8 min 0 s** wall-clock
      (24j's 8 min 58 s; not attributed), "36 rungs, none retired"; `title` green with
      `phase_fault` (96), `last_slot_3` and **11/11** faults; `round trip` green with
      `slot2`; `cold boot`, `load`, `death`, `snes boot` (13/13), `snes render` 904/904 and
      the rest green. `zig build test` with `M2_ROM` set: 0 failures.
    - Landed in m2snes `32bccc0`; cart `b524c268…e16c`.
    - **The playtest is open.** Each ask has a symptom the screen shows: the number beside
      `START` is the slot (1-3); a save in slot 3 and a reset (or a death) must open the title
      on 3, and Start there must come back where that save was; slots 1 and 2 must still load
      their own games or start new ones; and a clear on one slot must leave the other two
      loading. What the screen cannot show, the rungs read: the spawn-flag window (214, 215)
      and `$A0C0` (97, 214)
    - **Playtest passed 2026-09-25** (James, FXPak, the cart m2snes `32bccc0` builds): "A
      manual test works. I can cycle between saves and reload/clear as needed." The step is
      new behaviour, not a defect, so there is no tracker entry to close; its guards are
      `title` 92/95/97/103 and `round trip` 213-215. **Closed 2026-09-25**

- [x] **Step 24j: B15 — "Super" on the title** *(independent of 24i; may run before it)*
  - **The layer is BG1, not objects.** BG1 is 4bpp, off on the main screen, and used only by
    the room readout, which the title never runs: its glyphs are BG1 characters `$C0`-`$D0`
    and its map (`!READOUT_MAP`, word `$2000`) is drawn on rows 2-3. In mode 1 with
    BGMODE bit 3 clear, BG1 at either priority is in front of BG3, so "Super" covers `RETURN`
    with no priority bits to set. The menu's sprites are at OBJ priority 2, in front of BG1,
    and share no line with "Super" anyway. Objects would have meant OAM slots `ResolveSprites`
    does not overwrite, 27 more sprites, object characters beside the title's `$80`-`$FF`, and
    a hole in B14's sprite-set comparison; BG1 needs none of those and leaves B14 untouched
  - **What goes where** (all measured 2026-09-25 against `main.asm`):
    - Characters: BG1 ids `$01`-`$1B` at `!BG12_CHAR_BASE+16` (word `$1010`). Id `$00` stays
      the zero `Reset` leaves, so every other word of the map is transparent
    - Palette: BG palette 7, CGRAM `$70`-`$7F`. The only CGRAM writers are `Reset`'s clear and
      `LoadPalette` (colours `$00`-`$03` and `$80` up); BG3's 2bpp palettes stop at `$1F`
    - Map: BG1's map as it is (`$2000`), scroll left at the zero the init table writes. The
      Game Boy's (5, 61) is screen (`!WIN_LEFT`+5, `!BAND_TOP`+61) = (53, 101), and BG row 102
      because the PPU fetches the row after the one VOFS names (the `+1` in
      `!SCROLL_Y_BIAS`). So the converter shifts the art 5 right and 6 down inside a 9×3-tile
      patch at map column 6, row 12. Clear of the readout's rows
    - Visibility: the title's `!BAND_PLAY_TM` gains `!TM_BG1`, set before the existing copy
      into `!BAND_HUD_TM` so that copy carries it unchanged (the second play entry's byte
      too, if it is not already the same byte's value). `TitleScreen`'s exit restores
      `!TM_PLAY` where it already restores `!TM_HUD`, and zeroes the patch's 27 map words
      **after** its `lda #$80 / sta !INIDISP`: `TitleStart` runs with the screen on
      (`$0F`), where the PPU drops VRAM writes (sanity check, 2026-09-25). So the game never
      has "Super" in BG1
  - [x] Fixture first. The `title` rung gains exit code **101**: the cart's framebuffer over
        "Super"'s rectangle plus 8 px on each side (clipped to the play window) is not the
        expected picture. The expected picture is `title_oracle`'s Game Boy render of the title,
        widened from `renderRows`'s two rows to all 144 lines (`renderTitle`; `renderRows`
        becomes a slice of it), at the frame the copyright check already uses, with
        `super.png` composited at `super_at` = (5, 61) in the approved colours. It compares the
        same way code 93 does, every pixel through the cart's CGRAM; and because that alone
        would pass a wrong palette, CGRAM `$71` and `$72` are checked against the 15-bit
        values the Zig converter computes, baked into the script. Shown failing on Step 24h's
        cart with 101. **Done 2026-09-25**: `m2snes.sfc` as Step 24h left it exits 101; code
        102's check is in the same script, at the new game
  - [x] The art in the build
    - `assets/title_super.png` in m2snes: `~/Desktop/super.png` copied byte for byte
      (1 KB, under `policy.zig`'s ceiling, and not ROM bytes)
    - `png.zig` gains `decodeRgba`: 8-bit RGBA, non-interlaced (what `super.png` is: colour
      type 6), inflated with `std.compress.flate`'s zlib reader and all five row filters. The
      existing `decodeIndexed` only reads the stored-deflate files `encodeIndexed` writes.
      Unit-tested against PIL's reading of the same file (the oracle we did not build):
      67×17, 753 transparent, 262 red, 124 blue, and the SHA-256 of the RGBA grid
      `e6555188…c65a`
    - `src/title_super.zig`: `super_at`, the one position constant, with the Game Boy→BG1
      arithmetic above and a test that it lands at (53, 102); the conversion to 4bpp
      characters (empty tiles dropped, ids from `$01`), the 9×3 map words on palette 7, and
      the palette from the rule the requirements approved (`round(c*31/255)`, giving
      (23,1,1) and (3,5,17)). A colour other than transparent, red and blue is an error, not a
      nearest match
    - `snes_layout.Class` gains `title_art`, appended last as `physics` and `aram` were, so
      no earlier region moves. Three blobs: characters, palette, and the map with a header
      (first VRAM word, columns, rows). The builder embeds the PNG as `audio_bin` is embedded
      (`addAnonymousImport`), so the shipped builder still needs only itself and a ROM.
      Tests that enumerate the classes or count the directory learn the new class rather than
      being skipped
  - [x] The engine
    - `UploadTitleArt`, called from `TitleScreen` after `UploadTitleChr` under the same forced
      blank: `FindBlob` for the three `!CLASS_TITLE_ART` blobs, the characters and palette by
      DMA, the map row by row from its header. The band TM bytes as above
    - On the way out, before `TitleStart`: the TM bytes restored, and the patch's map words
      zeroed from the same header
    - `zig build engine`; `engine.bin` and `engine.sym` committed with it
    - **Found in the build, 2026-09-25**: a 16th class overflowed `snes_inject`'s class
      index. `@intFromEnum(class)` is the enum's tag type, `u4`, and `i + 1` at `title_art`
      (15) panicked in `patchTable`. Widened to `usize` at all three sites. The art is 20
      characters, not 27: the patch's seven empty tiles are map word zero
  - [x] PNGs for James's eye: the build writes the expected title (the Game Boy's with "Super"
        composited) at 1× and 4× beside the ROM, as the render PNG already is. The cart's own
        frame is not exported: Mesen's Lua `io` is sandboxed in test-runner mode (the reason
        exit codes are the rung's only channel), so the cart side is the rung's pixel
        comparison, then Mesen by hand and the FXPak. **James, 2026-09-25, on `m2snes-title-4x.png`:** "The
        pngs look exactly right. The position is exactly how I want it" — `super_at` (5, 61)
        stands
  - [x] Fault sweep: `title_faults` gains `UploadTitleArt` taken out (`rtl` at entry: it
        is `jsl`'d) and the map header's column byte moved by one — **as built**, the
        engine's read of it moved (`TitleArtMap_cols`, `ldy #$0003` for `#$0002`), since the
        fault run patches the engine image, not the converted blobs, each caught with 101; and the exit's clear taken
        out, caught by a check that BG1's patch words are zero once the game has started
        (new code 102). `conformance.md` updated with the three
  - [x] Verification: the `title` rung green, every fault caught; `cold boot`, `load`,
        `death` (its title after the death opens as a cold boot's, "Super" included),
        `round trip`, `snes boot`, `snes render` and the rest of the gate green; the gate's
        wall-clock re-measured; unit tests with `M2_ROM` set; `policy` clean. James's look at
        the PNG, then the FXPak playtest: "Super" where he wants it, and gone in the game
        with the readout toggled on (L+R) — *that last part could not fail; see below*
    - **Gate green 2026-09-25**: `zig build verify` exit 0 in **8 min 58 s** wall-clock (24h's
      was 7 min 31 s; not attributed); `title` green with `phase_fault` (96) and **7/7**
      faults, `UploadTitleArt` and `TitleArtMap_cols` caught by 101 and `ClearTitleArt` by
      102; `cold boot`, `load`, `death`, `round trip`, `snes boot` (13/13), `snes render`
      904/904 and the rest green; `file policy` clean over 355 files with the PNG in it,
      ROM n-gram scan included. Unit tests with `M2_ROM` set run inside the gate: 0 failures.
      **The FXPak playtest is open**
    - **Playtest passed 2026-09-25** (James, FXPak, cart `1ccd77dd…`, m2snes `8567711`,
      which rebuilds it byte for byte): "The playtest works perfectly. The "super" part of the title
      appears on fresh boot and game over -> title. It show up fine on soft and hard resets
      as well." **The readout half was not a test and is withdrawn**: the readout runs only in
      play, never on the title (James), and in play BG1 is on only for the top border's
      lines, while the patch is on lines 96-119, so art left in BG1 would be invisible
      either way. What "Super" leaving BG1 rests on is code 102 alone, which reads the
      patch's words in VRAM, and the `ClearTitleArt` fault shows it catching one.
      **Closed 2026-09-25**


- [x] **Step 25: the `snes boot` fault run** *(the other half of Step 16's third sub-task)*
  - [x] Give `snes boot` what every other emulator rung in the gate has: a faulted cart per phase,
        or per phase group where one fault covers several, and a report line in the gate's output
        the way `enemy AIs` prints "faulted cart differs" per room
    - **`verify.zig`'s `boot_faults`: eleven faults, one or more per audit row.** Each patches
      the image the clean run just passed — an `rts` at a routine's entry, or a table byte — and
      runs the same Lua. A fault is caught **only if the exit code's category is the phase that
      grades the mechanism**; caught anywhere else it fails the gate too, because that shows the
      rung can fail, not that the phase can see. The gate prints `fault sweep 11/11 engine faults
      caught, each by the phase that grades it`, and one `FAIL  boot fault` line per miss naming
      the label and what happened (not placed, already the patch, no verdict, still passes, or
      caught by which phase and code). `bootTest`'s code table became `bootVerdict` so both runs
      share it
  - [x] Nine of the seventeen mechanisms in `conformance.md`'s table are graded by a `snes boot`
        phase and nothing else. Each fault must be shown catching, and any phase whose fault is
        *not* caught is a finding to write down, not a fault to weaken
    - Eight rows still had a dash (Step 19 had moved B4a's). Caught, with the phase each code
      comes from checked against the Lua: `StreamOne` phase 7 (80); `WarpDraw` and WARP's
      `OpExtraFrames` byte phase 8 (136 each); `RunItemPickup` phase 9 (140); `DestroyBlock`
      phase 11 (151); `CollideProjEnemies` phase 14 (165); `DrawEnemies` phase 15 (170);
      `EnemyAnimateExplosion` phase 16 (177); `EnemyAnimateDrop` phase 17 (182); `SamusLayBomb`
      phase 18 (186); `ToggleMissiles` phase 19 (198)
    - **No phase missed its fault. One fault was wrong, and the fix was the fault, not the phase.**
      A bare `rts` on `RunItemPickup` left carry as it found it, so `bcs .noDraw` skipped the
      frame's drawing and the HUD caught it (205) on the first frame. That is a broken caller,
      not a missing pickup, so its fault is `clc; rts`, the routine's own nothing-to-do exit.
      `WarpDraw` returns its waits in A for the same reason, and its fault is the original's
      unrecognised-direction path: `lda #0; rts`, no strips and no waits
    - **The sweep shown failing**: one gate run with the bare `rts` back on `RunItemPickup` and an
      extra fault on `QueenRoarTick` (the Queen is outside the slice) printed `caught by hud
      (code 205), not by the item phase` and `every phase still passes`, and went red. Restored
      after. That run counted each miss as a rung; the sweep now counts as one
  - [x] Budget it against the gate's 391 s: one extra emulator run per faulted phase is 26 runs
        if done naively. Group the faults, or run the sweep behind a flag the gate sets and a
        developer can skip, and record the measured cost either way
    - **Neither grouped nor flagged: run in parallel.** The faulted runs share nothing but the
      script, so all eleven are spawned at once and waited on together. A fault ends the run at
      its phase, so the slowest takes 5 s alone. Measured in the gate: **7m24s → 7m51s**, on two
      runs (7m52s, 7m51s), so about 27 s with eleven Mesens drawing every frame beside the rest
  - [x] Update `conformance.md`'s table — the **Fault** column is the deliverable
    - Every dash filled with the fault and its code; `snes boot`'s roster row reads 28 phases
      and 11/11 faults; finding 1 carries a "Closed by Step 25" paragraph, including what the
      sweep does not cover: phases 20–28, whose rows have a fault check elsewhere or codes shown
      failing on pre-fix carts, none of them in this sweep
  - [x] Verification: the sweep green, every injected fault caught, and the gate's wall-clock
        re-measured and written down
    - **Closed 2026-09-25 in `m2snes` `cf435cd`.** Gate green, "35 rungs, none retired", 7m51s,
      `fault sweep 11/11`. `snes render` 904/904, `reachable` 1999/1999, `anchored` 665 across
      11 of 13, `durations` 28/60, `fade` 1999, `enemy AIs` 18, `enemy reload` 6: all unchanged;
      cart digest `312f908c…b5aa` unchanged. Unit tests green (2m58s)

- [x] **Step 26: the recorded sweep becomes a gate rung**
  - [x] Wire `oracle -- recorded`'s anchored sweep into `verify.zig` as a rung, with the same
        "absent means it did not run" contract every other recording-dependent rung has —
        `reference/metroid2.mmo` is vendored and not downloadable
    - **`oracle.gradeRecorded`, called by both the rung and `oracle -- recorded`**, so a red
      rung and the table it sends you to are the same sweep. The rung reuses the `status bar`
      rung's `loadRecording`, so a recording that is absent, or made on another cartridge,
      prints `not run:` for both. No emulator also prints `not run:`
    - **Two census defects came first, and together they meant the sweep had never graded more
      than one pass.** (1) `writeLua`'s stop frame left out `input_offset` where `FIRST` had it, so
      every pass wrote 906 rows of 907. `census` reads a short pass as the movie ending, so **any
      window over 906 frames was silently one pass**: `recorded 0 2000` graded 3 stretches and
      371 frames, and said nothing. (2) Once the second pass ran, `census` refused it as
      `InputMisaligned`. `Pass.lag` counted a pass's first row as a change, and at frame 907
      `$FF80` still held the `$10` of the frame before. Its own doc says only changed frames are
      evidence, and a first row has nothing before it to change from. `padChanges` had the same
      rule and got the same fix. Both have unit tests, shown failing before the fix
  - [x] Choose the window and the floor deliberately and write down why, the way
        `anchored_gate_floor` and `anchored_gradable_floor` are written down. The recording is
        76 951 frames; the rung grades a window of it, not all of it
    - **The first 2000 frames, chosen by James from two measurements** and written at
      `oracle.recorded_gate_window`. The cost is depth: every Mesen pass replays from frame 0.
      [0, 2000) takes **65 s**: 3 census passes and 12 reference passes. [10 000, 12 000), the
      only early window with broken blocks, took **47 minutes**, because 22 of 26 anchors never
      settle and each unsettled anchor runs all 15 settle rounds
    - **Floors: `recorded_gate_floor` 493 of 1648 frames, `recorded_gradable_floor` 11 of 11
      stretches.** Stretch 0 plays all 346 of its frames, 6 plays 97, and 2 and 9 play 25 each.
      The other seven stop on frame 0, the same shape as `anchored_gate_floor`'s nine: a ratchet,
      not a coverage claim. The pre-fix census is the "old wrong answer" and would fail it
      (371 < 493)
    - **What the window is not:** no kill, pickup or broken block. It grades James's play through
      the opening rooms, which the any% run never walks. Everything deeper stays with the tool
  - [x] This is also where the deferred seeding fixture from Step 8 can finally be asked, now
        that Steps 9–15 let the port play the region: run `oracle -- recorded … fault` in the
        chosen window and record what it catches. **If James still does not want it, say so here
        and leave the Step 8 box unchecked** — it must not close silently
    - **James said yes (2026-09-26). It was run where it could answer, and it still cannot.**
      The gate's window has no broken blocks, so the fixture ran on [10 000, 12 000):
      `oracle -- recorded 10000 2000 8 fault`, 47 minutes. **1 seeded stretch (6 tiles), 1 frame
      with the seeding and 1 without: FAULT 0 of 1**, and the tool exits red. That is not the
      seeding failing. 22 of the window's 26 anchors never settle, all on tileset assignment:
      map 6 $6B and $6C on table 9, and map 3 $21 on table 5, where the Game Boy shows table 4
      on 391–399 of 399 tiles. It is the open `docs/bug_tracker.md` entry from 2026-09-05. That
      entry now says it also blocks this fixture
    - **Step 8's box stays unchecked**, as agreed: close on a catch, record and leave it open on
      no answer. `conformance.md` finding 5 carries the same paragraph
  - [x] Update `conformance.md`'s roster and the "not in the gate" note it currently carries
    - The 37th rung's bullet and roster row; the note now reads "only the recording's first 2000
      frames are in the gate"; finding 4 is **narrowed, not closed**, and finding 5 records the
      2026-09-26 run. `verify.zig`'s `rung_count` is 37
  - [x] Verification: the new rung green with the recording present and green with it absent, and
        the gate's wall-clock re-measured
    - **Present:** gate green, "37 rungs, none retired", `recorded` 493 of 1648 across 11 of 11.
      **9m12s, up from 7m51s** (+81 s; the rung alone is about 65 s). Every other rung unchanged:
      `anchored` 665 across 11 of 13, `reachable` 1999, `durations` 28/60, `enemy AIs` 18,
      `enemy reload` 6, `status bar` 281/281. Unit tests green (2m54s)
    - **Absent:** `reference/metroid2.mmo` moved aside, backed up and SHA-1-checked. The gate
      is green, "37 rungs, none retired", in 5m57s; `recorded` prints `not run: no recording`
      beside `status bar`'s "not taken". The file was restored with the same SHA-1 (`2899219…`)
    - **Closed 2026-09-26 in `m2snes` `f18bb90`.** No cart change: the diff is `gb_trace.zig`,
      `oracle.zig`, `oracle_main.zig`, `verify.zig` and two docs

- [x] **Step 27: the hardware pass**
  - [x] Build the cart, record its digest, and confirm it is the digest the gate signed off
  - [x] Play the slice start to finish on the FXPak and keep a run log recording: the minimum
        required rooms traversed (Step 1's list), `metroidCountReal` showing two Metroids
        defeated, every required and collected item registering as collected, and no lock-up
  - [x] Every defect found lands in `docs/bug_tracker.md` with a repro, and each gets a failing
        fixture before it is fixed, per Step 3's rule
  - [x] Re-run the pass after the fixes, against a rebuilt cart whose digest the gate signed off
  - [x] Verification: the run log is committed, the pass conditions are all met on one run, and
        `zig build verify` is green against that cart
  - [x] Of note, this step has been crossed off manually. Hardware testing had been done, but
    not as part of this step.
