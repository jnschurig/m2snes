---
created: 2026-08-23T06:51:10Z
updated:
  - 2026-08-23T06:51:10Z
  - 2026-08-23T08:00:56Z
  - 2026-08-23T08:02:18Z
  - 2026-08-23T22:20:41Z
  - 2026-08-24T00:14:26Z
  - 2026-08-28T04:24:06Z
  - 2026-08-31T17:47:10Z
  - 2026-09-01T14:24:04Z
  - 2026-09-02T05:05:09Z
  - 2026-09-21T02:56:13Z
working_directory: /Users/james/git/snes_game_dev
---

# Requirements

## Status: Final

## Overview

Rewrite *Metroid II: Return of Samus* (Game Boy) as a native SNES game, shipped from
its own repository as a **bring-your-own-ROM builder**: a self-contained executable that
takes the user's legally-owned Metroid 2 GB ROM as input and produces a SNES ROM. The
repository contains zero copyrighted bytes — all proprietary assets are extracted from
the user's ROM at build time, and every modification to them ships as a diff or as new
original work. Secondary goal is clean integration with the smz3 / "quad rando"
randomizer; tertiary goal is a set of quality-of-life improvements over the original.

## Decisions already made

These were settled during feasibility and are not open questions in the plan below.

| Decision | Choice | Rationale |
|---|---|---|
| Port technique | **Hand rewrite in 65816 asm**, M2RoS as behavioral spec | Static recompilation was re-examined and rejected: it makes every QoL goal harder (no symbols to patch), can't do per-tile color, produces no stable symbols for rando integration, and forces GB screen space |
| Relationship to `snes_game_dev` | **Standalone repo**, with **one vendored binary**: the GB-APU shim package (`audio/shim/`), generated in `snes_game_dev`, synced and hash-pinned by its `MANIFEST`. No shared source (amended 2026-09-20) | Not a zasm/engine project. The shim is a generic GB-APU-on-S-DSP runtime with nothing Metroid II-specific in it, so m2snes takes it as a build product, not a source dependency. See F8 |
| Play window | **GB 160×144 play area in Phase 1**; the extra SNES pixels become HUD/UI/QoL space. A wider world view ships later as a QoL toggle | Identical play window keeps enemy spawn *timing* identical, which makes the TAS oracle valid against the build actually shipped. The shipped configuration is verified rather than inferred |
| Viewport parameterization | **`VIEW_W`/`VIEW_H` stay build-time constants**, pinned to GB values in Phase 1 | Measured: camera and spawn code is already written in terms of `SCRN_X`/`SCRN_Y`, so keeping the later wider-view toggle open costs nothing |
| Primary oracle | **TAS input trace** run against both, reporting the first divergent frame | Whole-game coverage from one artifact — every room, boss, and item — and it pinpoints failures instead of flagging them |
| Assembly | **Pre-assembled**: asar runs in CI, the assembled engine image is committed, the builder injects assets | The game code is ours and carries no legal problem; keeps the shipped builder a single dependency-free binary |
| Builder language | **Zig** | Single static cross-platform binary, no runtime dependency for end users |
| Assembler | **asar** | Lingua franca of the SNES romhack/smz3 community; matching it is most of the rando-integration story |
| Music | **Bank 4's sound engine rewritten in SPC700 asm**, driving the GB-APU shim on the S-DSP. Song data is extracted from the user's ROM at build time (amended 2026-09-20; was: auto-transcribed to TAD sequences plus correction diffs) | The register writes are graded **exactly** against the Game Boy, with the same requests on the same tick, where transcription could only be judged by ear. It keeps nothing copyrighted in-repo, and it needs no correction diffs to review. The load fits: `surface` 18.7% and `title` 29.1% of a 50% SPC700 budget with all four channels and SFX allowed for (`2026-09-16-metroid2-audio`, `03-measurements.md`, after the shim verdict `2026-09-01-gb-apu-spc700-shim/04-verdict.md`) |
| Sound effects | **The same engine**: bank 4's SFX routines run on the SPC700 beside the music, with the Game Boy's priority and preemption (amended 2026-09-20; was: pre-rendered BRR one-shots) | One engine for both is how the original mixes SFX over music and steals channels from it. One-shots would have to re-create that. Graded by the same exact comparison |
| Work structure | **Three tracks** — deterministic conversion, interpreter/dispatch, hand rewrite | The parts have radically different automation potential; measured at ~40% data / ~60% logic |
| Asm translation | **Rejected** (source-to-source SM83→65816) | Preserves the GB's 8-bit data representation, which is exactly what the rewrite exists to shed; yields GB-emulation-in-65816, not idiomatic, patchable, parameterizable code |
| Conversion scope | **Full game in Phase 0a**, not the slice | Converter cost is per *format*, not per *item*; slice-scoping saves nothing and adds throwaway region filtering |
| Conversion verification | **Round-trip equivalence + render comparison**, both automated | Round-trip proves no information is lost; render comparison proves semantic interpretation. Neither needs game logic |
| Phase 0 | **Split 0a / 0b** — asset base converted and verified, then playable slice | Retires every project-killing risk in ~4 weeks instead of ~3 months |
| Phase 0b scope | **Landing site through the second Alpha Metroid** | Measured: the first `IF_MET_LESS` gate (`$46` vs a start count of `$47`) trips at exactly two kills — the smallest slice proving the whole progression chain |

## Measured facts about the source game

Established by inspecting the M2RoS disassembly against the retail ROM. These are load-bearing
for the plan and should not be re-derived.

- The world is a **uniform grid**: 7 map banks (`$9`–`$F`), each a 16×16 grid of screens.
  A screen is 16×16 metatiles × 16px = **exactly 256×256 pixels**. Positions are stored as
  `(screen, pixel)` byte pairs, which is what fixes the screen size at 256.
- Rooms are **tetromino-shaped groups of screens**, glued by door scripts in bank 5.
  There is no variable room size — so **zero rooms are smaller than a 256×224 viewport**,
  and no room geometry needs re-authoring for the reflow.
- Camera movement is constrained by a per-screen scroll-block byte (`map_scrollData`,
  bank offset `$4200`, indexed `screenY*16 + screenX`; bit0=right, bit1=left, bit2=up,
  bit3=down). These flags *are* the room-boundary encoding: a screen permits scrolling
  in a direction only where valid content exists.
- The camera coordinate is the viewport **center**, and clamps are written as
  `$100 - SCRN_X/2` and `SCRN_X/2` (`bank_000.asm:1324`). Substituting 256×224 yields
  camera X pinned at exactly 128 (exact screen fit, zero void) and camera Y ranging
  [112, 144].
- Of 905 in-use screens: 274 (30%) block both left and right, 328 (36%) block both up
  and down, 31 (3%) are fully pinned. Bank `$C` is 100% horizontally pinned; bank `$B`
  is 95% vertically pinned.
- **Enemy spawn is already viewport-parametric.** `loadEnemies` (bank 3, `$4014`) computes
  its load window as `camera_center ± (SCRN_{X,Y}/2 + $10 + OAM_{X,Y}_OFS)` — one shared
  routine, not per-enemy code.
- **Enemy despawn is screen-granular and viewport-independent.** `deleteOffscreenEnemy`
  (bank 2, `$4464`) deletes at camera-relative screen index `$FE` (−2) or `$03` (+3),
  i.e. ~512px behind / ~768px ahead — far outside either viewport.
- There are **16 enemy slots** (`$C600–$C7FF`, `$20` bytes each), and the GB build sheds
  load mid-frame at `rLY >= $58`, resuming round-robin the next frame.
- The GB status bar is a raster split at scanline 135 (~8px bar), giving a real play
  area of about **160×136**.
- **The Metroid counter is the game's global progression gate.** `metroidCountReal`
  (`$D089`, BCD) starts at `$47` (47) per `initialSave.asm`. A *separate*
  `metroidCountDisplayed` (`$D09A`) shuffles toward it on `metroidCountShuffleTimer`
  (`$D096`) — the HUD counter animates rather than snapping. Both are saved
  (`$D821`, `$D825`).
- Killing a Metroid arms `nextEarthquakeTimer` (`$D091`), which counts down in 256-frame
  intervals; the earthquake then runs for `earthquakeTimer` (`$D083`), swapping music to
  `song_earthquake` (`$E`) and restoring via `songRequest_afterEarthquake` (`$D0A5`).
  The quake is the signal that the acid/lava level has dropped — the `lavaCaves`
  tileset exists in **Mid / Empty / Full** metatile variants (`$8:5480`, `$5594`, `$56A8`)
  for exactly this. The order is semantic, not positional: measured against the ROM in
  Step 3, the three tables differ from each other by 33 (Mid-Empty), 28 (Mid-Full), and
  52 (Empty-Full) metatiles. The two endpoints must be the pair that differs most, which
  makes `$5594` and `$56A8` the extremes and `$5480` the intermediate state. An earlier
  reading of this document assumed ROM order matched drain order (Full/Mid/Empty); it
  does not.
- Door scripts contain **171 `IF_MET_LESS` conditional transitions** across 13 distinct
  thresholds (`$00 $01 $09 $11 $12 $13 $14 $21 $23 $24 $34 $42 $46`). The highest is `$46`
  against a start count of `$47`, so **the first gate in the game trips after exactly two
  Metroid kills**.
- `OAM_X_OFS` (8) and `OAM_Y_OFS` (16) are **Game Boy hardware sprite-origin biases**.
  SNES OAM has no equivalent; these terms must become 0 or fold into the sprite-origin
  convention rather than being copied verbatim.

## Features

Work divides into three tracks with very different automation potential. Measured against the
M2RoS source: ~15,500 lines of data plus binary graphics, and ~22,800 lines of executable
logic — of which `bank_004` (the 2,733-line sound driver) is replaced wholesale by the audio
pipeline rather than ported, leaving **~20,000 lines of SM83 logic to rewrite**.

| Part | Track | Automatable |
|---|---|---|
| Graphics | A — conversion | Fully (GB 2bpp → SNES 2bpp is a reinterpretation) |
| Maps, screens, scroll flags | A — conversion | Fully |
| Data tables (enemy headers, hitboxes, damage, physics constants, pose tables, solidity) | A — conversion | Fully (re-emission) |
| Door script *data* | A — conversion | Fully (re-emission) |
| Door script *interpreter*, table-driven dispatch | B — interpreter | Partly — write the dispatcher once, the tables transfer |
| Game logic (~20,000 lines) | C — rewrite | No |
| Sound | D — audio | Mostly, but lossy and per-track |

---

## Track A — Conversion

### F1. Bring-your-own-ROM builder

A single executable that accepts a user-supplied Metroid 2 GB ROM and emits a playable
SNES ROM, with no copyrighted data of its own.

**Acceptance Criteria:**
- Runs as one self-contained binary on macOS, Linux, and Windows with no runtime
  dependency the user must install
- Verifies the input ROM by hash and rejects unrecognised or modified ROMs with a clear
  message naming the expected version. Phase 0/1 target the **World (W) revision, 256KB**
- **The builder assembles nothing.** asar runs in CI; the assembled engine image is committed
  to the repository as our own original code. The builder injects extracted assets into that
  image against a fixed layout, patching pointers. This is what makes the single-binary,
  no-runtime-dependency requirement achievable at all
- **Deterministic build:** the same input ROM and builder version always produce the same
  output file, so users can verify their ROM matches everyone else's by hash. This is a
  statement about build reproducibility only — the SNES ROM bears no byte-level or
  structural correspondence to the GB ROM, and is not expected to
- Emits a symbol file alongside the ROM (see F11)
- Extracts and places bank 4's audio data in the ARAM image, and BRR-encodes its wave tables
  (F8). **Amended 2026-09-20:** the SM83 core and GB APU emulation no longer ship for audio
  capture and SFX rendering. With the GB **PPU** and the comparison harnesses, they live in
  the dev test suite, where they are the Game Boy side of F8's exact comparison
- Fails loudly with an actionable message on any missing or malformed extraction target;
  never emits a silently-wrong ROM
- The repository contains no bytes derived from the retail ROM, enforced by a CI check

**Out of Scope:**
- Any byte-level or structural correspondence between the output SNES ROM and the input
  GB ROM. This is a rewrite for a different CPU, PPU, and memory map; the two ROMs are
  unrelated as binaries
- Distributing the GB ROM, or any asset extracted from it
- Supporting non-World revisions of the GB ROM in Phase 0
- GUI; command line only

### F2. Deterministic asset conversion — full game

Conversion of every deterministically-convertible asset class, across the **entire game**,
not just the Phase 0b slice.

**Acceptance Criteria:**
- Converts, for all banks and all areas: tile graphics (area tilesets, Samus, enemies,
  items/HUD, title and credits); **metasprite definitions** for Samus, enemies, and credits
  (converted and round-trip verified per F3, whether or not F9 renders them assembled);
  metatile definitions; collision and solidity tables; map screen data; per-screen scroll
  flags; door script data; and all behavioral data tables (enemy headers, hitboxes, damage
  values, physics constants, pose tables)
- Handles all format variants, including the three `lavaCaves` metatile sets that are
  `$114` bytes where the other seven are `$200`
- Behavioral data is derived from documented ROM offsets rather than hand-copied
- Every modification to converted data ships as a diff against the conversion output,
  applied at build time and readable in review
- The pipeline is the single source of truth: no converted asset is committed
- Asset regions and their sizes are **fixed at assembly time**: the engine image reserves
  space per asset class, and conversion output must fit. Overflow is a build error naming
  the offending class, never a silent truncation
- Final ROM size and mapper choice are determined from the complete converted asset set

**Out of Scope:**
- Audio data: F8 extracts and places it, and grades it with its own comparison (amended
  2026-09-20; was "lossy, per-track, and not deterministic", which described transcription)
- A GUI asset editor
- Round-tripping edited assets back into a GB ROM

### F3. Conversion verification

Automated proof that conversion is correct across the whole game, requiring no game logic.

**Acceptance Criteria:**
- **Round-trip equivalence:** for every asset class in F2, converting forward and back
  reproduces the original ROM bytes exactly. Run exhaustively over all assets, as a local
  gate (`zig build verify`) — see the CI note under Constraints
- **Render comparison:** a GB emulator in the dev test suite renders a reference frame for
  each of the ~300 screens; the same screen rendered from converted assets in 160×144
  play window is diffed against it. Semantic errors — metatile quadrant order,
  tilemap orientation, palette index mapping — must fail this test
- Both suites run across the full game, not a sample, and produce a reviewable artifact
- **Asset viewer:** a debug mode renders any screen with any tileset and steps through
  metatile, collision, and solidity data, so conversion is inspectable by hand as well as
  by test. Its side-by-side original/adapted surface is specified in F9
- Round-trip and render comparison are understood as complementary: round-trip proves no
  information is lost, render comparison proves interpretation is right. Neither alone is
  sufficient

**Out of Scope:**
- Verifying audio. F8 grades its register writes exactly with its own harness (amended
  2026-09-20; was "impossible by construction", which held for transcription only)
- Verifying game *behavior*; that is the TAS oracle's job (F10)

---

## Track B — Interpreter and dispatch

### F4. Door script interpreter and table-driven dispatch

Reimplement the original's data-driven dispatch layers so their tables transfer as data.

**Acceptance Criteria:**
- The door script bytecode interpreter is reimplemented in 65816, covering the opcode set
  (`COPY_DATA`/`COPY_BG`/`COPY_SPR`, `TILETABLE`, `COLLISION`, `SOLIDITY`, `WARP`,
  `DAMAGE`, `IF_MET_LESS`, `FADEOUT`, `LOAD_BG`/`LOAD_SPR`, `SONG`, `ITEM`, the Queen
  opcodes, `END_DOOR`)
- All door script *data* converts in Phase 0a; interpreter *opcodes* are implemented as
  their underlying subsystems land. Unimplemented opcodes halt loudly rather than
  misbehaving silently
- Enemy AI dispatch via header and AI-pointer tables is preserved as a dispatch layer, so
  the tables transfer as data
- **A survey pass identifies every other place the original is table-driven**, so the
  maximum possible share of the ~20,000 logic lines reduces to "port the dispatcher,
  transfer the table." This survey happens in Phase 0a, before bulk rewriting begins

**Out of Scope:**
- Inventing new bytecode not present in the original
- Queen-related opcodes' underlying logic before the Queen fight exists

---

## Track C — Rewrite

### F5. Game logic rewrite

Native 65816 reimplementation of Samus movement, collision, projectiles, enemies, items,
save, and progression — behaviorally faithful except where a QoL feature or the viewport
deliberately diverges.

**Acceptance Criteria:**
- Samus poses, physics constants, and pose-transition behavior match the original within
  the tolerance established by the TAS oracle (F10)
- Enemy AI, hitboxes, and damage values match the original's data tables
- Door transitions, item pickups, and the save system function as in the original
- The enemy slot count stays at the original **16**, and enemy spawn/despawn windows stay
  identical to the original. Both are prerequisites of the TAS oracle (F10): changing either
  shifts enemy spawn timing and desyncs whole-game verification. The mid-frame load-shedding
  threshold may be relaxed, since it affects only how work is spread across frames, not which
  enemies exist or where — any relaxation must be shown not to desync the oracle
- GB OAM origin biases (`OAM_X_OFS`=8, `OAM_Y_OFS`=16) are handled explicitly, not copied
- Code is idiomatic 65816 — 16-bit where the GB was forced into 8-bit pairs — not a
  transliteration of SM83 register shuffling
- BCD arithmetic (41 `daa` sites in the original, including the Metroid counter) uses the
  65816 decimal mode rather than emulated half-carry

**Out of Scope:**
- Mechanical SM83 → 65816 translation, in any form
- Cycle-exact reproduction of GB timing
- Reproducing GB hardware quirks (HALT bug, OAM-DMA timing) with no SNES analogue

### F6. Metroid progression chain

The game's global progression gate, called out separately because it spans five subsystems.

**Acceptance Criteria:**
- `metroidCountReal` decrements per kill and persists across save/load
- `metroidCountDisplayed` shuffles toward the real count on its timer rather than snapping
- `nextEarthquakeTimer` arms after a kill; the earthquake fires on its delay, swaps music
  to `song_earthquake`, and restores via `songRequest_afterEarthquake`
- Acid/lava level changes drive the `lavaCaves` tileset swap between the Mid, Empty, and
  Full metatile variants
- `IF_MET_LESS` transitions route correctly across all 13 thresholds. Only the `$46`
  threshold is reachable in D2; the remaining 12 are a Phase 1 obligation

**Out of Scope:**
- The Queen sequence (later phase)

### F7. Play window, camera, and screen layout

A **160×144 play window** on a 256×224 SNES screen. The surrounding pixels are UI, not world.
This is what makes the shipped build and the verified build the same build.

**Acceptance Criteria:**
- The play window is 160×144 (play area ≈160×136 after the HUD band, matching the original's
  scanline-135 split). Camera behavior, enemy spawn windows, and map streaming are byte-for-byte
  equivalent in effect to the original — **no divergence introduced by presentation**
- `VIEW_W`/`VIEW_H` remain build-time constants; camera clamping, spawn windows, and streaming
  are expressed in terms of them with no hardcoded dimensions anywhere, so the later wider-view
  toggle (F12) stays cheap
- Camera deadzone and scrolling-guide constants are **ported unchanged**, not retuned — retuning
  them would desync the oracle
- The ~96×80 pixels outside the play window are used for HUD, map, item display, and the
  toggleable-upgrades menu (F12) — never letterboxed black
- The play window is positioned deliberately (not necessarily centered) to suit the UI layout
- Because the play window matches the original, **there is no untested shipped configuration**:
  F10's TAS oracle validates exactly what users run

**Out of Scope:**
- Showing more of the game world in Phase 1. The wider view is a Phase 2+ QoL toggle (F12),
  and is explicitly *not* covered by the TAS oracle when enabled
- Any presentation change that alters camera position, spawn timing, or enemy behavior

---

## Track D — Audio

### F8. Audio pipeline

Bank 4's sound engine, rewritten to run on the SPC700 and driving the GB-APU shim, with its
data extracted from the user's ROM at build time.

**Amended 2026-09-20: the shim replaces TAD transcription.** The cycle that decides this is
`.local/docs/2026-09-16-metroid2-audio/`. Its gate (Step 7) ported the whole song player to the
SPC700, graded it **exact** against the Game Boy on all four channels, and measured it on an
FXPak Pro. With all four channels and the sound effects allowed for, the load is 18.7% on
`surface` and 29.1% on `title`, against a 50% budget (`03-measurements.md`, "Step 7: the
decision"). That follows the shim's own GO-WITH-CAVEATS
(`.local/docs/2026-09-01-gb-apu-spc700-shim/04-verdict.md`), whose CPU caveat this cycle's
measurements answer. Why the decision moved:
- **Transcription could never be graded exactly.** The engine port can. With the same requests
  on the same tick, it writes the same registers, in the same values and order, as the Game Boy.
  That is the same bar as the rest of the port.
- **No correction diffs.** The transcription path's copyright exposure lived in how much each
  track was hand-corrected. That exposure is gone, and nothing needs reviewing track by track.
- **SFX come for free.** Bank 4's own priority, preemption and channel stealing run unchanged.
  One-shots would have had to re-create all of them.

The TAD path as first specified is withdrawn and not kept as a fallback. The criteria below
replace it. The 2026-09-01 move of F8 from 0a to 0c stands.

**Acceptance Criteria:**
- **The 65816 sends requests, not register writes.** It sends one tick per `handleAudio` call it
  stands in for, plus the frame's request bytes. The game's "playing" bytes come back through
  the reply ports one frame later, and that latency is surveyed against every read site.
- **Bank 4 runs on the SPC700** as our own SPC700 assembly (`engine/audio/`). It calls into the
  shim's register file, and the shim's S-DSP output is already graded exactly against its
  expected-value model.
- **The shim is vendored**, not shared source: `audio/shim/` is a package generated by
  `zig build shimpkg` in `snes_game_dev`, and its `MANIFEST` pins it by commit, ABI and SHA-256.
- Song, instrument, SFX and wave-table data are **extracted from the user's ROM at build time**
  and placed in the ARAM image by the builder. Wave tables are BRR-encoded at build time.
  Nothing copyrighted is committed.
- **Verification is exact:** `audiocmp` runs the same `.req` request script through the Game Boy
  (the dev-suite SM83 core running bank 4) and through the port. It asserts every write to
  `$FF10`–`$FF3F` and the read-back bytes, byte for byte, per tick. The full id range is swept,
  and each id that doesn't extract or match is listed with its reason.
- ARAM and SPC700 load are measured, offline and on hardware, against the shim's budgets.
- The ear is still the last rung. F9's audio A/B and a listening pass on hardware judge the
  result past the register file.

**Out of Scope:**
- Transcription, TAD, correction diffs and BRR one-shot SFX (the pre-2026-09-20 path)
- Fed mode (the 65816 streaming register writes) as a runtime path. It stays a bench instrument
- Bit-exact reproduction of DMG *audio output*. The register writes are exact, but the S-DSP is
  not the Game Boy's DACs, and the gaps are judged by ear

---

## Cross-cutting

### F9. Inspection and A/B tooling

Human-facing surfaces on the verification infrastructure. Deliberately **not** new pipelines:
F3's render comparison already computes both framebuffers and F8's capture already produces
both audio paths — these tools emit reviewable output from the same code instead of a
pass/fail. Both follow precedent already established in `snes_game_dev`: `zig build
demo-audio` (WAV via the TAD emulator backend) and `zig build demo-frames` (PNG via the
soft-PPU).

**Acceptance Criteria:**
- **Audio A/B:** for any track or sound effect, render the GB original (via the builder's
  GB APU emulation) and the adapted SNES version (via SPC700/driver emulation) to WAV
  files, named so they sort adjacently for back-to-back listening
- Audio A/B covers music tracks and individual sound effects, selectable by index, across
  the full game — not only the Phase 0b region
- **Graphics A/B:** render original and adapted **side by side** as a single PNG, with a
  diff channel highlighting mismatched pixels. Covers every graphics class:
  - Area tilesets, and their metatile assemblies
  - Full screens composed from map data
  - Samus sprite tiles, per pose
  - Enemy sprite tiles and animation frames, per enemy type
  - Item, HUD, and common sprite graphics
  - Title screen and credits graphics
- **Component-level comparison is the requirement; assembled sprites are optional.**
  Comparing sprite *tiles* side by side is sufficient to catch conversion errors, and needs
  no emulator — GB 2bpp decode is unambiguous, so both sides decode directly to a pixel
  grid. Rendering **assembled metasprites** (composed per pose via the metasprite tables)
  is a nice-to-have, built only if it falls out cheaply
- The emulator-backed reference is therefore needed only where *composition semantics* are
  under test — screens built from metatiles and map data, where quadrant order, tilemap
  orientation, and palette index mapping can be silently wrong. A background-only GB PPU
  suffices for Phase 0a; OAM/sprite composition is deferred with the assembled-sprite view
- Selectable per-asset so a mismatch can be narrowed down without reading hex
- Both tools can emit a contact sheet / index for bulk review across the whole game
- **Coverage reporting** in the spirit of `ff6/assets_report.zig`: report what has been
  compared *and what has not*, because an unconverted asset class produces no failing test —
  only silence, which is what sinks a project at a checkpoint
- Both are dev-suite tools; neither ships in the builder

**Out of Scope:**
- Real-time playback UI, or any GUI — file output the user opens with normal tools
- Editing of any kind; these are inspection tools (editing is out of scope per F2)

### F10. Verification infrastructure

Three layers of test coverage over the ~20,000-line rewrite: whole-game integration, per-routine
units, and manual exploration.

**Acceptance Criteria:**
- **TAS oracle.** A tool-assisted speedrun input stream is run against the GB ROM in an emulator,
  dumping a per-frame state trace (Samus position, camera, enemy slots, relevant RAM). The same
  input stream is fed to our build and traces are compared, reporting the **first divergent
  frame** and what diverged. This is the primary whole-game correctness gate, and it is valid
  against the shipped configuration because F7 preserves the play window
- The TAS oracle runs as part of the local verify gate once enough of the game exists to reach
  meaningful depth, and its reachable-frame count is tracked as a progress metric

**Amended 2026-08-31: the comparison is re-anchored, and only the playable stretches are
frame-exact.** The wording above describes one continuous frame-indexed comparison from the
movie's frame 0. Step 15b measured what that costs: the game's opening is a title screen plus a
318-frame sequence in which input is offered and ignored, and reproducing a stretch like that
frame-for-frame means reproducing timing that has nothing to do with whether the port plays the
game correctly. Planning on both machines being frame-exact through every cutscene, screen
transition and menu is not a realistic gate, and a gate nobody can pass is not a gate.

So the oracle is re-anchored, and the two kinds of stretch are graded differently:

- **Playable stretches — frame-exact.** Every stretch in which the game accepts input is
  compared frame for frame, anchored at the frame control is handed over. The first divergent
  frame within each anchored stretch is what the gate reports, and it is exact. This is the
  criterion above, applied per stretch rather than once
- **Non-playable stretches — duration, within tolerance.** Cutscenes, screen transitions and
  menus are graded on **how long they last**, not on what they show frame by frame. The
  measured duration must be within **2%** of the original's, and the actual percentage is
  recorded per stretch rather than reduced to a pass mark. The threshold is a stated judgement
  (James, 2026-08-31: "as long as they are 98-99% the same, then they are good enough"), not a
  figure derived from anything, and it is written down here so that changing it is a decision
  rather than a drift
- **The metric follows.** The reachable-frame count becomes the total frames matched across
  anchored playable stretches, plus the stretches whose duration held. It is still monotone and
  still a progress metric; it no longer requires cutscene logic to be nonzero
- **Build order follows the movie.** Components are added in the order the tool-assisted run
  needs them, rather than screens being built in a vacuum and hoping the run reaches them. Each
  stop of the reachable-frame count names the next component to port, and parity is maintained
  as each is added rather than reconciled at the end
- **Logic inventory ledger.** A machine-readable manifest of every routine in the source, with
  source location, conversion status, test status, and target phase. The initial inventory is
  **generated mechanically from the user's own ROM** rather than written by hand, so the backlog
  builds itself and stays honest. Routine boundaries are mechanical facts; the semantic names
  attached to them are our own work, not transcribed M2RoS labels
- The generator is **our own SM83 disassembler** (`src/gb/disasm.zig`, already cross-checked
  opcode-for-opcode against `src/gb/cpu.zig`), seeded from three mechanical sources: the static
  flow trace from the reset and interrupt vectors, every `CALL`/`JP`/`JR` target named anywhere
  in the ROM, and the program counters our own GB emulator is observed to execute. This was
  amended on 2026-08-28 from an earlier wording that named the MIT-licensed `mgbdis`. The
  reasons are that it removes a third-party toolchain dependency from the gate entirely, and
  that a static-only tool — `mgbdis` included — cannot follow this game's `JP HL` dispatch
  tables, which is why a vector-seeded static trace reaches only 22% of bank 0. Execution
  coverage sees through them. `mgbdis` remains a valid cross-check if a boundary is ever
  disputed, but nothing in the build depends on it
- The ledger is the source of the "N of ~20,000 lines adapted" progress figure, and reports
  what is unconverted *and untested* as distinct states
- **Per-routine unit tests.** Routines are exercised in an emulator harness — set up state,
  call the routine, assert registers and memory — with each routine's test status recorded in
  the ledger
- **Room test harness.** Spawn Samus at an arbitrary bank/screen/position with arbitrary
  equipment, beam, energy, missiles, and Metroid count. This is a synthesized save record —
  `initialSave.asm` already carries every one of those fields — not new machinery
- The room harness is usable by hand for exploratory testing and scriptable for regression

**Out of Scope:**
- Authoring a TAS; an existing published movie is used as input
- Cycle-accurate comparison; the trace compares game state, not timing

---

## Deliverables

### D1. Phase 0a — asset base converted and verified

Milestone: **the entire asset base of the game is converted, verified, and inspectable.**
Not playable as a game.

**Acceptance Criteria:**
- F2 converts every asset class across the full ROM
- F3's round-trip and render-comparison suites pass across all assets and all ~300 screens
- Asset viewer works, including F9's side-by-side graphics A/B at component level across
  all graphics classes (assembled-metasprite view optional)
- Builder (F1) runs the whole pipeline end to end from a user-supplied ROM, injecting assets
  into the pre-assembled engine image
- Logic inventory ledger (F10) is generated and populated
- ROM boots on real hardware (FXPak) and in Mesen2; Samus moves, jumps, and collides
- TAS oracle (F10) runs against the GB ROM and produces a reference trace; our build is
  compared against it for as far as Phase 0a's logic reaches, re-anchored at each handover of
  control per F10's 2026-08-31 amendment
- Room test harness (F10) can spawn Samus anywhere with an arbitrary loadout
- Table-driven dispatch survey (F4) is complete, with its findings written down
- **Audio is not part of this gate.** Amended 2026-09-01: F8 in its entirety moves to
  **Phase 0c**, which gets its own cycle. The two criteria that used to sit here — audio A/B
  tooling working for one proven track, and a capture tool with one track proven end to end —
  move with it

**Out of Scope:**
- Enemies, items, save, HUD, progression — all Phase 0b
- Any QoL feature or color

### D2. Phase 0b — playable slice

Milestone: **a contiguous, manually playable section**, built on a proven pipeline.

**Acceptance Criteria:**
- Covers landing site through the **second Alpha Metroid** as one continuous region, with
  no fabricated stitching between areas
- Exercises door transitions, item pickup, save, and camera behavior in both a horizontal
  and a vertical area
- Exercises the full Metroid progression chain (F6) end to end, including at least one
  `IF_MET_LESS` transition demonstrably reaching content unreachable before the second kill
- If a lava/acid drain is reachable in the region, the tileset swap is exercised; if not,
  that is recorded explicitly as deferred rather than assumed working
- Playable start to finish by hand on real hardware and in an emulator
- Conformance harness passes for the covered region
- The earthquake's music interruption path is exercised. **Amended 2026-09-01:** with F8 in
  Phase 0c, the silent stub is the expected outcome here rather than the fallback — what 0b
  must prove is that the interruption *path* fires and restores, not that a track plays.
  If 0c has landed by then, the track is played instead and that is recorded as a bonus

**Out of Scope:**
- Content beyond the covered region
- Metroid species beyond Alpha (Gamma, Zeta, Omega, Queen are later phases)
- QoL features and color

---

## Later phases

### F11. Romhack and randomizer integration surface

**Acceptance Criteria:**
- The build emits a symbol/address map covering item locations, item-effect routines,
  door/transition tables, save-state layout, and the RAM map
- Item placement is data-driven and patchable without reassembling
- Free space in the ROM is documented and stable across builds
- The integration surface is documented, with a worked example of relocating one item
- The asset viewer (F3) is usable as a romhacking inspection tool

**Out of Scope:**
- Building the randomizer or any smz3 integration code
- Guaranteeing symbol stability across major versions

### F12. Quality-of-life features

Delivered individually, each in whichever phase it becomes ready.

**Acceptance Criteria:**
- **Stackable beams:** collecting Ice Beam adds freezing to the current beam rather than
  replacing it; beam state is a bitfield; all combinations reachable and rendering correctly
- **Toggleable upgrades:** a menu enables/disables collected upgrades in the spirit of
  Super Metroid; toggling takes effect immediately and persists in save
- **Colorization:** a colorized tileset preserving the original art design and pixel
  placement, changing only palette; colors reference the corresponding areas of *Samus
  Returns* where a correspondence exists; palettes are original work committed to the repo
- **Wider world view:** an optional build/toggle expanding the play window beyond 160×144
  toward the full 256×224, symmetric where possible (+48px each side horizontally, +40px
  vertically, both whole tiles). Deferred here deliberately: it shifts enemy spawn *timing*
  and therefore desyncs the TAS oracle, so it ships only once the underlying port is proven,
  and is explicitly outside oracle coverage when enabled. Camera deadzone constants need
  retuning for the wider proportions, and seeing more of the map makes the game easier —
  both accepted as consequences of enabling it
- Each feature is build-time disableable so the TAS oracle remains usable against a
  vanilla-equivalent build

**Out of Scope:**
- Redrawing or re-laying-out any art
- QoL features not listed here

### F13. Stretch — MSU-1 and PC target

**Acceptance Criteria:**
- **MSU-1:** standard track mapping so users can supply audio overrides; documented track
  index list; clean fallback to native audio when no MSU-1 data is present
- **PC target:** playable on desktop; approach deliberately unspecified

**Out of Scope:**
- Supplying any MSU-1 audio
- Committing to the PC target at all; abandoned if it is not cheap

## Phasing

Phase 0 is split. From Phase 1 onward every phase delivers a complete, playable game.

- **Phase 0a** — full-game asset conversion and verification (F1, F2, F3, F4 survey),
  inspection and A/B tooling (F9), verification infrastructure (F10), boot, Samus movement.
  Estimated 3–4 weeks. This is the go/no-go.
- **Phase 0b** — game logic for the slice (F5, F6), playable through the second Alpha
  Metroid (D2). Estimated 6–8 weeks.
- **Phase 0c** — the audio pipeline (F8) end to end, plus F9's audio A/B: bank 4 on the
  SPC700 over the GB-APU shim, graded exactly against the Game Boy, with every track and SFX
  the slice reaches played on hardware. Its own `spec-and-dev` cycle,
  `2026-09-16-metroid2-audio`. **Added 2026-09-01, path amended 2026-09-20.**

  **0b and 0c are independent and may run in either order or in parallel.** 0b's only audio
  dependency is the earthquake interruption path, which D2 now satisfies with a silent stub.
  0c's only dependency on 0b is that a track is nicer to judge inside a playable slice than on
  a test screen, and that is a convenience rather than a requirement.

  **What moving it out of 0a costs, stated rather than glossed.** The go/no-go no longer
  measures auto-transcription quality, so Phase 0a ships with that assumption open and the
  documented SPC700-shim fallback still unexercised. That is accepted: the shim is a fallback
  for *how* audio is done, not for whether the port is viable, and every risk 0a exists to
  retire — asset conversion, region sizing, dispatch reduction, the oracle — is unaffected by
  it. **0c must land before Phase 1**, which requires all music tracks playing as they do in
  vanilla. *(Resolved 2026-09-20: 0c exercised the shim and chose it over transcription. See
  F8.)*
- **Phase 1** — the complete game: 160×144 play window on a 256×224 screen, mono, no QoL;
  full audio; rando integration surface (F11). **Acceptance:** the game is completable start
  to finish; all rooms reachable; all 47 Metroids; all music tracks play as they do in vanilla;
  the TAS oracle runs clean end to end; and human play-testers are involved as the phase nears
  completion.

  **Delivered by its own `spec-and-dev` cycle, `2026-09-25-metroid2-1-0-complete-game`,
  which re-scopes this text (2026-09-25).** Its `01-requirements.md` (C1-C11) is the acceptance
  that binds; where the two differ, it wins. In short:
  - *The TAS oracle runs clean end to end* is dropped. The published runs replay faithfully
    only to frames 8407 and 4566 (0b bound 1), so there is no full-game frame-exact comparison
    to pass. Each mechanism is graded instead (C1-C7), against our Game Boy and James's 100%
    recording (C10). Cutscenes are graded on duration within 2%.
  - *Rando integration surface (F11)* is tabled to a future cycle. Item placement is already
    data, but a room's `ITEM` loads its graphics into one shared slot.
  - *Human play-testers* means James's hardware playthrough of a retail-built cart, from new
    game to credits (C11). Lag found there is a defect.
  - Added: the debug screen (C8), the tooling the cycle grades late-game states with.
- **Phase 2+** — QoL features (F12) as each becomes ready; stretch goals (F13)

## Constraints & Dependencies

- **Legal:** no copyrighted bytes in the repository, enforced by a local policy check
  (CI is deferred — see Toolchain).  The repository is **private** for the time being. Modifications ship as
  diffs against conversion output or as new original work. Note that Nintendo DMCA'd AM2R,
  a Metroid 2 remake, in 2016 — the BYO-ROM model is a materially stronger position than
  AM2R's (which distributed assets) and matches M2RoS, sm64ex, and the N64Recomp projects,
  but Metroid 2 is among the highest-risk properties in this space. This is an accepted,
  deliberate risk.
- **Reference:** the [M2RoS disassembly](https://github.com/metroidret/M2RoS) is the
  behavioral spec. It is hand-labeled, and its own GB rebuild is verified byte-exact
  against the retail ROM — which is what makes it trustworthy as a spec, and the rewrite
  tractable. (That property belongs to M2RoS's GB build, not to anything we produce.)
  It is a reference, not a dependency — no M2RoS code is vendored.
  **M2RoS is MIT licensed** (James, 2026-08-24; amended here 2026-09-02, closing the action
  Step 18's go/no-go raised as item 4). This paragraph previously said M2RoS shipped no LICENSE
  file and was therefore all-rights-reserved, and listed the licence answer as an **outstanding
  external dependency**. That dependency is **closed**: M2RoS material may be used with
  attribution, the MIT notice retained.

  **The re-derivation discipline is retained anyway**, and the reason is now the only reason —
  it was always the half of the argument that did not depend on the licence: a re-derivation is
  checkable against the ROM and a transcription is not. So it stands as engineering discipline
  rather than as a licensing obligation. Note also that an MIT file cannot relicense Nintendo's
  code in any case; it covers the author's own contribution, so the ROM-data rule below is
  untouched. Facts about the ROM are
  **independently verified against the ROM** the way `ff6/offsets.zig` treats the GPL
  `rip_list_en.json` in `snes_game_dev`, and every offset entry records *how we know*.

  A second disassembly, [Vashy777/metroid2](https://github.com/Vashy777/metroid2), is
  **MIT-licensed but mechanical** — a `mgbdis` dump (last pushed 2021-11) with no semantic
  labeling (bank 0's 765 labels are all auto-generated `Call_000_xxxx` / `Jump_` / `Data_`
  apart from the ~20 `mgbdis` emits from `hardware.inc`). It is therefore **not** a substitute
  for M2RoS as the behavioral spec, and an MIT file cannot relicense Nintendo's code in any
  case — it covers the author's own contribution. It is used for exactly one thing: the
  mechanical routine inventory behind F10's ledger — and as of 2026-08-28 it is not used for
  that either: our own disassembler plus emulator coverage reproduces the inventory from the
  user's own ROM, depending on neither repository nor on Python.
- **Oracle:** a GB emulator is the source of truth for both asset rendering and game behavior,
  driven by a published TAS input stream for whole-game coverage (F10). Divergence is a defect
  until proven to be a deliberate design change. This holds against the *shipped* build, because
  F7 keeps the play window identical to the original.
- **Toolchain:** Zig for the builder; asar for 65816 assembly, **run at dev time only** — the
  assembled engine image is committed and the shipped builder injects assets into it, so end
  users never need an assembler. The audio driver is our own SPC700 port of bank 4 over the
  vendored GB-APU shim (F8, amended 2026-09-20; was TAD).
- **CI:** deferred until the repository move. Every gate in Phase 0a needs the user's retail
  ROM, which a public runner cannot hold, so gates are local commands (`zig build verify`).
  Extracted assets and reference frames stay untracked regardless, so the ROM-free subset
  (build, unit tests, offsets invariants) can be split out and hosted later.
 A GB emulator written in Zig (CPU, APU, PPU and the comparison
  harnesses, all in the dev test suite; amended 2026-09-20, when the CPU+APU stopped shipping in
  the builder for audio capture).
- **Effort:** the complete game is a full commercial title — realistically 12–24 months solo
  at hobby pace, **inclusive of** Phase 0a (3–4 weeks) and Phase 0b (6–8 weeks).
- **Hardware:** target real hardware via FXPak Pro; emulator testing in Mesen2.
- **Unmeasured assumptions**, each to be measured early — except the first, which moved:
  auto-transcription quality on Metroid 2's ambient tracks (moved to Phase 0c on 2026-09-01,
  and **retired 2026-09-20**, when F8 took the shim instead); the ARAM budget (measured in 0c
  against the shim's budgets); how much of the ~20,000 logic
  lines the F4 dispatch survey actually removes; whether the reserved asset regions in the
  pre-assembled image are sized correctly for the full converted asset set.
