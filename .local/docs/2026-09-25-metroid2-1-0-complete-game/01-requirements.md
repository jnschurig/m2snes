---
created: 2026-09-26T03:28:09Z
updated:
  - 2026-09-26T03:28:09Z
  - 2026-09-26T04:08:08Z
  - 2026-09-27T01:02:22Z
  - 2026-09-27T02:03:35Z
  - 2026-09-27T04:20:41Z
  - 2026-09-27T16:49:29Z
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
  - 2026-10-01T05:03:40Z
  - 2026-10-01T14:18:43Z
  - 2026-10-01T16:45:41Z
  - 2026-10-01T21:27:15Z
  - 2026-10-01T22:09:13Z
  - 2026-10-01T23:30:30Z
  - 2026-10-02T01:53:20Z
  - 2026-10-02T14:26:40Z
  - 2026-10-02T14:29:36Z
  - 2026-10-02T14:45:46Z
  - 2026-10-02T19:24:07Z
  - 2026-10-02T22:22:21Z
  - 2026-10-03T00:46:04Z
  - 2026-10-04T02:44:09Z
  - 2026-10-04T03:46:28Z
working_directory: /Users/james/git/snes_game_dev
---

# Requirements

## Status: Final

## Overview

Metroid II's SNES port **1.0**: the whole game, playable and completable on real hardware.
That means title → landing site → all 47 Metroids → Queen → ending → credits. Phase 0b proved
the pipeline, the audio and most of Samus. This cycle ports what the slice never reached. It
covers the remaining enemy AIs, the other Metroid species and the bosses, the item mechanics
the slice left ungraded, the whole map, and the ending. It also adds the tooling a tester
needs to reach late-game states without playing up to them. This delivers **Phase 1** of
`../2026-08-22-metroid2-snes-port/01-requirements.md`, re-scoped as below.

Target repository is **`~/git/m2snes`**, branch `remote-init`. Paths are relative to it.

## Where 0b left this (measured 2026-09-25)

| area | state |
|---|---|
| Enemy AIs | **15 of 41** `enAI_*` routines are in `AiTable` (incl. `enAI_NULL`, both Alphas, the item orb, the missile door) |
| Unported AIs | arachnus, autom, autrack, babyMetroid, blobThrower + blobProjectile, drivel + drivelSpit, flittMoving, flittVanishing, gammaMetroid, glowFly, gravitt, gunzoo, halzyn, metroidStinger, missileBlock, moto, normalMetroid, omegaMetroid, proboscum, septogg, skorpHori, skorpVert, skreek, zetaMetroid |
| The Queen | `queenHandler` (03:$6E36) and its ~2000 lines in bank 3, **not ported**. It drives the screen with LYC raster interrupts and `VBlank_drawQueen`. `queen_roomFlag`, `queen_eatingState` and `applyDamage.queenStomach` are recorded as deferred |
| Samus items | Pickup arms for every item exist. The **branches** for Hi-Jump, Screw Attack, Space Jump, Varia and Spring Ball are ported and **ungraded**. `loadGraphics` (00:$2753) is a stub that records `!GfxWanted`, so no beam or suit graphics swap happens. The Varia suit's transformation animation is not ported |
| Death / game over / game timer | ported (Step 15c) |
| Map | **4 of 7** banks are walked by any run (`$F`, `$A`, `$C`, `$B`). The tileset is assigned by inference, and B12 left **nine cells** wrong whose answer is not in the door table |
| Progression | `IF_MET_LESS` taken for real; only the thresholds the slice reaches are graded |
| Ending / credits | not ported (`creditsRoutine` 05:$55A3, ending selection by clear time, `credits_*`) |
| Test tooling | the room readout (L+R). The original has a **debug pause menu** (00:$2D39, gated by `debugFlag` $D0A0, never set in retail); C8 replaces rather than ports it |
| Open defects | 11 open entries in `docs/bug_tracker.md`, several player-visible (refill orbs invisible, damage-flash palette, sprite attribute) |

## Features

### C1. The remaining enemy AIs

Port every `enAI_*` routine the ROM's spawn data can reach, together with the children and
projectiles each spawns. Ordinary enemies only here; Metroids and bosses are C2–C4.

**Acceptance Criteria:**
- A ROM-derived census lists every AI address that any enemy header in any spawn record
  names. A unit test fails if a census AI is neither in `AiTable` nor on an explicit,
  reasoned exclusion list. This extends `enemy_oracle.census` from the slice to the whole ROM
- Each ported AI has at least one case in the `enemy AIs` rung. The case runs on the GB
  harness and on the cart in a room where the AI lives, and must agree pass for pass. The
  cart with that AI's `AiTable` row blanked must disagree
- Enemy damage, hitboxes, drops, freeze (ice) and death follow the ported common paths
  wherever the original does. Where an original AI special-cases one (the Metroids do), the
  port does too
- `enemy_commonAI` states still unhandled after this cycle are recorded, not mis-dispatched

**Out of Scope:**
- Exhaustive per-branch fault sweeps and `correspond.zig` operand coverage for every AI.
  One faulted case per AI is the bar (the lighter-touch rule, James 2026-09-25)

### C2. Metroid species and progression

Gamma, Zeta and Omega Metroids, the larval Metroids of the final area (`normalMetroid`),
and `metroidStinger`. Includes their hatching/molting sequences, their kills counting down
the Metroid counter, and the earthquakes and level drops that follow.

**Acceptance Criteria:**
- Each species has a live case and a kill case in the `enemy AIs` rung. The kill case
  grades the Metroid globals the Alpha kill cases already grade: state, fight flag, both
  counts, post-death timer
- All **13** `IF_MET_LESS` thresholds (`$00 $01 $09 $11 $12 $13 $14 $21 $23 $24 $34 $42 $46`)
  route correctly, graded by a gate test at each threshold. The count must be driven by the
  debug menu or a save, not by a poke (see C8)
- Every `lavaCaves` level transition the game performs draws the right table, graded
  against the ROM's pointer table as B8's code 227 is
- The Metroid count reaching the Queen's threshold makes the Queen reachable

### C3. Arachnus

The Arachnus boss (`enAI_arachnus`), including its ball/upright states and the Spring
Ball it drops.

**Acceptance Criteria:**
- A live case and a kill case in the `enemy AIs` rung, pass for pass with the GB
- The Spring Ball pickup that follows is collectable and sets its bit

### C4. The Queen, and the baby Metroid

The Queen fight end to end: room entry and `queen_renderRoom`, the neck and head, the
projectiles, being swallowed and bombing out of her stomach, her death. Then the baby
Metroid that hatches, follows Samus, and eats the blocks between her and the ship.

**Acceptance Criteria:**
- The Queen's raster effects are reproduced on the SNES by HDMA and/or H-IRQ. The
  play-window image must match the GB's at graded frames: the body, the neck, and the
  split scroll of the room behind her
- The Queen's state machine is graded against the GB harness state by state, the way the
  `enemy AIs` rung grades a slot. This covers head and neck positions, health, the
  eating state, and projectiles
- Being eaten, bombing out, and her death all work. The post-Queen state (music, Metroid
  count, baby) follows
- The baby Metroid follows Samus and eats its blocks. Graded by a live case over a
  block-eating stretch
- The debug screen's Queen-room warp (C8) reaches the fight

### C5. Samus's remaining items and mechanics

Every item's effect, not just its pickup.

**Acceptance Criteria:**
- **Hi-Jump, Space Jump, Screw Attack, Spring Ball, Varia**: their `!Items` branches are
  exercised and graded. Each gets a `snes boot` phase driven by the pad with the item
  collected through a real pickup or the debug menu, and each phase fails with its branch
  faulted
- **Screw Attack** damages and kills enemies through the existing enemy-contact path.
  Graded by an `enemy AIs` case, as the Alpha's screw reaction already is
- **Varia** halves damage and plays its suit transformation animation. The animation is
  graded on duration within 2% and by its final frame
- **Beams**: Ice freezes enemies, and a frozen enemy is solid and standable. Wave passes
  through walls, Spazer fires three, and Plasma pierces. Each is graded by at least one
  `enemy AIs` or `snes boot` case
- **`loadGraphics` is ported**: collecting a beam or the Varia suit swaps the tiles the
  original swaps. Graded against the GB's VRAM after the pickup
- Energy and missile refill stations work, and their orbs are visible (closes the open
  refill-orb defect)
- The missile refill's credits branch (`metroidCountReal` test) is live

### C6. The whole world

Every room in all seven map banks is reachable, rendered with the right tileset, and
crossable.

**Acceptance Criteria:**
- Every cell shows the tileset the Game Boy shows when entered the way the game enters it,
  including B12's nine open cells. Graded by `zig build oracle -- worlds` (or its
  successor) over every cell any available run visits; when the recordings arrive (C10),
  their cells join. The mechanism is the plan's choice. B12 measured that the GB treats the
  table as loaded state set by door scripts, which is the likely answer
- A save and a load round-trip in every bank that has a save station. The enemy spawn
  flags (killed Metroids, collected items) must survive the trip, graded like B7's `load`
  and `round trip` rungs
- Every door script in the ROM executes without an unhandled opcode, graded by a unit test
  over all 512 scripts
- A hand playthrough visits every bank

### C7. Ending and credits

After the Queen and the return to the ship: the fade out (mode `$12`), then the credits
(mode `$13`), which roll with stars and the timer while Samus plays one of four endings,
selected by clear time. The ending is drawn *during* the credits and plays out once the
scroll ends, so it is not a sequence of its own (measured from bank 5, 2026-10-02). The four
are: under 3 hours, suitless with her hair let down; 3-5, suited and kneeling; 5-7, running
without end; 7 and over, standing without end.

**Acceptance Criteria:**
- Ending selection by clear time follows the ROM's thresholds, graded at each boundary via
  the in-game timer
- The fade, the credits' scroll and each ending variant are graded on **duration within
  2%** of the GB (the cutscene rule, F10 2026-08-31). A variant's duration is the frame
  each of its animation states is entered, since two of them never end. The measured
  percentage is recorded per stretch. Credits
  text and ending images are graded against the GB's rendered frames at a set of sampled
  frames
- Credits end as the original's do: the last screen (Samus, the timer, the stars) holds
  without end. `credits_rebootGame` (05:$5985) is reached by nothing and is not ported. The
  original's way out is its soft reset, A+B+Start+Select (00:$02E1, in `mainGameLoop`, every
  mode), which B7 left out; it is ported, and graded from the credits back to the title
  (James, 2026-10-02)
- **The reference does not wait on C10.** Until a recording covers the ending, the Game
  Boy side is set up in the post-Queen state on our GB harness. The rule against forcing
  state binds the cart, not the reference, as the enemy oracle already does. The cart side
  reaches the same state through the debug menu (C8)
- The ending and credits music plays (bank 4 already carries it)

**Out of Scope:**
- Any new ending art or text

### C8. Test tooling: the debug screen

Lets a tester reach any late-game state in under a minute on hardware. **It lands early in
the cycle** (James, 2026-09-25): it is the harness C2, C4, C5 and C7 are tested with, both
by hand and as the cart side of their gate rungs.

**A menu in the manner of the Super Metroid practice hack, not a port of the GB's menu**
(James, 2026-09-27, after the first hardware try). It opens at any point in play, freezes the
game while it is up, applies each change the moment it is made, and stays open until
dismissed. The original's one-row 
debug menu (00:$2D39) cannot hold what is needed. The screen is tooling, not game content,
so faithfulness buys nothing. That includes its B+Select Queen warp: the warp page's Queen
entries replace it, and no button combination warps anywhere (James, 2026-09-25).

**Acceptance Criteria:**
- **Opening and closing:** on a `--debug` cart, holding L, R and Start together opens the menu
  at any point in play or in the pause, in whatever order the three go down, and does so
  again to close it. B at the menu's root also closes it. Closing returns to exactly where
  play (or the pause) was
- **Layout, a tree:** the root lists the pages. A opens a page, toggles a switch or runs an
  action; Left and Right change a number; Up and Down move; B goes back a level
- **The room readout** is a switch on the menu's root on a `--debug` cart, and its L+R
  shortcut is gone there, because L+R+Start would toggle it. The retail cart keeps L+R
- **Samus page:** each item and upgrade bit (Bombs, Hi-Jump, Screw Attack, Space Jump,
  Spring Ball, Spider Ball, Varia), the equipped beam, energy tanks (0–5), and max and
  current missiles. Plus a **full loadout** action that sets everything to maximum
- **Metroids page:** all 47 Metroids by number, each named by area and species, each
  toggled killed or alive. Marking one killed runs the kill's own bookkeeping: its spawn
  flag, both counts down, the earthquake armed. The quake and the acid/lava drop then follow
  as in play. Marking one alive restores its flag and the counts and arms nothing. This is
  what tests every acid/lava level change and its earthquake without playing to it
- **Flags page:** the enemy spawn flags per room, so an enemy can be reset or marked
  killed. An item's collected state is its spawn flag, so this is also how an item is
  re-collected or skipped. Entries are named by room, and by item where one is present
- **Clock:** the in-game timer's hours and minutes are editable, so all four ending
  variants (C7) can be reached
- **Warp page — a named list only, generated from the ROM** rather than hand-kept. It
  holds every save station, every item location, every Metroid's room and the room next
  to it, the Queen's room and the room next to it, and **the ending/credits** directly.
  Every room entry arrives through a real door script into that room, so tileset, song,
  graphics and scroll flags are exactly what normal entry gives. The ending entry enters the
  ending the way the Queen's aftermath does. **Every entry is graded in the gate**: it
  arrives, and the room shows the tileset C6's grading says it should
- **Enabling it:** the menu's code ships in every cart, because the engine image is
  pre-assembled. The builder flag `--debug` patches the one byte that enables it; a
  `--debug` cart has the menu from power-on, with no step on the title (James,
  2026-09-27). `debugFlag` stays clear on every cart, as in retail. A cart built without
  the flag has no way to open the menu, and must **behave identically** to one where it does
  not exist. The gate grades both builds: without the flag, a run with L+R+Start pressed in
  play is still the Game Boy's frame for frame and the menu is never drawn; with the flag,
  the chord opens it in play, and it closes back to play
- Changes made on the screen save through the normal save station path, so a debug-built
  save is a normal save
- Documented in `docs/setup.md`: how to build with it, the chord, the pages and controls

**Out of Scope:**
- A minimap or arbitrary-cell teleport (not chosen, 2026-09-25). The tileset is loaded
  state that depends on the door used, so an arbitrary cell can arrive wrong
- Directly setting current energy, noclip, spawning enemies
- Builder-generated preset save files (not chosen, 2026-09-25)
- Porting the GB's own debug menu

### C9. Player-visible defects

**Acceptance Criteria:**
- Every open `bug_tracker.md` entry is triaged into *fixed*, *accepted as a compromise*
  (with the reason), or *diagnostic only*
- All player-visible ones are fixed or explicitly accepted by James. Known today: refill
  orbs invisible, Samus's damage/acid flash palette, `drawSamus_common`'s sprite attribute,
  and B1's fade-transition and animation-hold items

### C10. Reference recordings (when available)

James will supply any% and/or 100% Mesen2 recordings later. The cycle must not block on
them, and must use them when they land.

**Acceptance Criteria:**
- Until they arrive, the GB harness in `enemy_oracle`, `room.zig` and the Queen oracle is
  the reference, with rooms and ticks derived from the ROM
- When a recording arrives, it is run through `zig build gbtrace -- ais` for the full-game
  AI census and `-- kills` for kill ticks. Its cutscene durations feed the durations rung,
  and its visited cells join C6's worlds grading. Any census AI it names that C1's
  ROM-derived census missed is a defect
- Wiring a recording is a step with its own checkbox, not an assumption

### C11. The 1.0 close

**Acceptance Criteria:**
- `zig build verify` green with every new rung listed in `docs/conformance.md`
- `docs/feature_tracker.md` updated: F4, F5, F6 and D-level entries for Phase 1 closed or
  `[~]` with named defects. A new `C*` section mirrors this document
- A hand playthrough on FXPak: new game → credits, all 47 Metroids, every major item. Can
  be split across saves; the debug menu is **not** used for this run
- Lag or slowdown the playthrough finds is a defect with a `bug_tracker.md` entry, not an
  impression. Likely places are the Queen's HDMA/IRQ work and rooms with many live enemies.
  It is fixed or explicitly accepted
- All music tracks and SFX play as in vanilla (already graded by 0c; spot-checked in the
  playthrough)

## Explicitly out of scope, with the reason

- **"The TAS oracle runs clean end to end"** (Phase 1's original wording). The published
  runs' replay horizon is frame 8407/4566 (0b bound 1), so no full-game frame-exact
  comparison exists to pass. Replaced by C1–C7's per-mechanism grading plus C10's recordings
- **F12 QoL, F13 MSU-1/PC** — Phase 2+
- **SameBoy reconciliation** — still deferred (0b); C10's Mesen2 recordings route around it
- **Frame-exactness through cutscenes** — duration within 2%, as F10 2026-08-31
- **Other ROM revisions** — World revision only
- **F11, the randomizer integration surface** — tabled (James, 2026-09-25). The direction is
  still data-driven item placement and connectivity. It makes assumptions nothing can verify
  yet, though, so it is a future cycle. What was learned in scoping it: items already live
  in converted spawn records and doors in converted door-script blobs. The real blocker is
  that a room's `ITEM` opcode loads that room's item graphics into one shared slot, so a
  moved item draws wrong. Keeping every item's graphics resident in VRAM would remove it.
  Connection randomization is harder, because the tileset is loaded state that depends on
  the door used

## Constraints & Dependencies

- Everything in the port's and 0b's Constraints sections still applies. That includes no
  ROM-derived bytes in the tree, facts derived from the ROM, a committed `engine.bin` +
  `engine.sym` rebuilt with `zig build engine`, and commits on `remote-init` only
- **Lighter-touch grading (James, 2026-09-25):** each AI/mechanic gets at least one
  oracle case and one fault run. Cutscenes are graded by duration, and the final gate is a
  full playthrough. The fixture-first rule still holds for *defects*
- **Fixtures must not force cart state.** Reaching late-game states in the gate goes
  through the debug menu or a real save, not RAM pokes
- **Budgets to watch:** the 512 KiB cart and its region table (Queen and credits
  graphics are new blobs), and CPU for the Queen's HDMA/IRQ. Each is measured when it lands, not assumed
- **Risk:** the Queen (C4) is the one mechanism needing a new display technique. It
  should be spiked early, not left last
- **Sizing:** 26 AIs, the Queen, the ending, the items, tooling and the world pass. Expect
  this to be the largest cycle yet; the plan will size it against the ledger
