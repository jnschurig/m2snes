# m2snes cleanup: dead code and effectiveness

Findings from a read-only sweep of `../m2snes` on 2026-09-28, taken at `remote-init`
474e30e (1.0 step 8d). Work on `remote-init`, never `main`. When the sweep ran,
`engine/` and `src/gfx_grade.zig` had uncommitted changes. Leave them alone unless they
have been committed by the time this work starts.

## Worth changing

### 1. Unify the 28 test copies of `loadRom()` and stop tests skipping silently

28 files each define their own `loadRom()`. Of these, 15 end in `catch null`. In those
files, a wrong `M2_ROM` path or a failed read becomes `error.SkipZigTest`, so the test
skips instead of failing. This hides the error, and it is the same trap as the "M2_ROM
unset skips ROM tests" entry in the m2snes silent-test-traps memory.

The 15 that use `catch null`:
`gfx_info locate death audiocost save transition aram_image roster room scenario
routines tas blocks audiocmp title_oracle`

The other 13 pass the error up, but they differ in allocator and size limit
(`1 << 20`, `4 << 20`, `expected_size * 4`).

**Fix:** write one shared helper. It returns null only when `build_options.rom_path` is
empty and passes every other error up. Replace all 28 copies with it.

**Guard:** point `M2_ROM` at a path that does not exist and confirm the tests fail
instead of skipping. The old behaviour, a silent skip, must no longer be possible.

### 2. The README status is stale

`README.md:44` still reads "**Phase 0a, Step 14 of 18.** Not playable, not close." The
paragraphs after it also describe Phase 0a. The project is at 1.0 step 8d. Rewrite the
Status section to describe where the project is now.

### 3. Two orphan files

Nothing in the repo references either of these:

- `test/probe.lua`. Last touched in 8f74f77, "Step 12: the gate runs the cart". Delete
  it.
- `tools/audio-load.sh`. It samples SPC700 load over SNI from `!AudReply`. Last touched
  in 1d1c0ed. If it is still useful, list it in `docs/setup.md` and the README tool list.
  Otherwise delete it.

### 4. Unused functions

Nothing references these, tests included:

| Location | Name |
|---|---|
| `src/audio_data.zig:413` | `PointerSite.isExternal` |
| `src/locate.zig:177` | `Observation.writersOf` |
| `src/map.zig:121` | `Bank.inUseCount` |
| `src/oracle.zig:2612` | `anchorsFor` |
| `src/oracle.zig:2846` | `unhandledCode` (`unhandledPose` is used; check whether the pair should stay together) |
| `src/snes_convert.zig:981` | `Set.assetBytes`, and `blobTotal` (`:996`), which only it calls |
| `src/warp.zig:349` | `edgeOpening` |
| `src/sprites.zig:412` | `step11_tables` |

## Low priority

- **Unused named constants (about 30).** Examples: `physics.origin_x_to_right`,
  `origin_y_to_stand_check`, `hitbox_top_poses`, `jump_rise_normal`,
  `jump_rise_hi_jump`; `save.slot_index_addr`, `file_counter_addr`, `buffer_base`;
  `items.mask_bomb`, `mask_spider`; `tas.draw_origin_row_addr`, `draw_origin_col_addr`
  and the unused header fields in `tas.zig:134-166`; `crawl.load_door_index`;
  `death.mode_boot`, `save_flags_at`; `snes_screen.spin_jump`, `spin_start`;
  `snes_target.play_layer`, `bg_char_bytes`; `title_oracle.slots_len`;
  `warp.probe_left`, `probe_right`; `audiocmp.SpcError`. Most of them record facts about
  the ROM, so keeping them is reasonable. Delete only the ones that are leftovers from
  finished steps.
- **Swallowed allocation failures in void callbacks.** `ledger.zig:540`
  (`edges.append ... catch {}`) and `room.zig:680,691` (`sites.put`, `list.append`). On
  OOM these drop records silently, so a ledger or room report could come out incomplete
  without saying so. Consider setting an overflow flag and reporting it.

## Checked and clean

- Every tracked `.zig` file is reachable from `build.zig` by `@import`.
- None of the 896 top-level labels in `engine/main.asm` (552) and
  `engine/audio/main.asm` (344) is unreferenced.
- Every `zig build` step is referenced from the docs or the code, except the
  `test-death`, `test-pause`, `test-title` and `test-warp` filters. Those are harmless
  shortcuts.
- Every script in `tools/` is referenced except `audio-load.sh` (see item 3).
- `audio/shim/shimpkg.zig` has about 80 unused `pub` constants, but it is generated and
  synced from snes_game_dev, so it was left out.

## Method

The sweep used scripts, so a new finding can be checked the same way:

- Reachability: `@import` walk from every `src/...zig` path named in `build.zig`.
- Unused declarations: an identifier whose only occurrence, with comments stripped,
  across all tracked `.zig` files is its own declaration. Before using this check,
  confirm there is still no `@hasDecl` or `std.meta.declarations` reflection. Only one
  `@field` exists (`map.zig:69`).
- Asm labels: top-level `Label:` names counted across `.asm`, `.inc`, `.zig` and `.lua`
  files with comments stripped.
