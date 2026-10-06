---
created: 2026-10-04T04:53:43Z
updated:
  - 2026-10-04T04:53:43Z
  - 2026-10-04T04:59:46Z
  - 2026-10-04T05:08:45Z
  - 2026-10-04T05:22:17Z
  - 2026-10-04T05:41:51Z
  - 2026-10-04T18:01:02Z
  - 2026-10-04T18:24:20Z
  - 2026-10-04T18:50:25Z
  - 2026-10-04T19:25:31Z
  - 2026-10-04T19:38:23Z
working_directory: /Users/james/git/snes_game_dev
---

# Implementation Plan

## Status: Complete

## Overview
Work in `../m2snes` on `remote-init`, one commit per step. Steps 1–3 add a shared
`testrom` module and route every test read of the ROM through it: about 150 reads in about
50 files (widened from the sweep's 30 loaders on 2026-10-04). Reads that already pass
errors up move first (step 1), so that commit changes no behaviour. The silent ones (about
110) move in two batches by file (steps 2 and 3), with failures triaged as they appear;
step 3 also adds the ratchet and the guard. Step 4 makes the gate require a ROM. Steps 5
and 6 are the dead-code deletions and the OOM flags. `zig build test` runs at every step;
`zig build verify` (about 14 min) runs at steps 3, 4 and 6.

Conversion shape, everywhere: `const rom = try testrom.load(a) orelse return
error.SkipZigTest;`. The site's `if (rom_path.len == 0) return error.SkipZigTest;` line
and any local loader go. The site keeps its allocator. A test that frees the bytes keeps
its `defer` (`load` returns `[]u8` owned by that allocator).

## Steps

- [x] **Step 1: The `testrom` module, and every read that already propagates**
  - [x] Add `src/testrom.zig`. `pub fn load(allocator) !?[]u8` returns null only when
        `build_options.rom_path` is empty, and otherwise returns `readAt(allocator,
        build_options.rom_path)`. `pub fn readAt(allocator, path) ![]u8` reads with
        `.limited(rom.expected_size * 4)` and passes every error up.
  - [x] Test in `testrom.zig`: `readAt` on a nonexistent path returns
        `error.FileNotFound` (the old `catch null` answer was null, so it fails this test).
        As built: `testrom` has its own options (`testrom_options`) and imports nothing
        from `src/` (a file reached by path and by module is rejected by Zig), so the limit
        is the literal `256 * 1024 * 4`; the import goes on all 79 `build_options` modules.
  - [x] `build.zig`: create `testrom_mod` (imports `build_options` and `rom`), add it to
        the test list, and `addImport("testrom", ...)` on every module whose tests read
        the ROM.
  - [x] Convert the named loaders that propagate (`warp_grade`, `roundtrip`, `sprites`
        `loadRomForTest`, `debug_tables`, `entity`, `warp`, `items`, `coverage`,
        `gb/trace`, `tileset`, `screens`, and `gb/sameboy`'s test use) and every inline
        test read that uses `try` (e.g. `crawl.zig:479`). `gb/sameboy`'s non-test loader
        (`:408`, used at `:470` with a caller-supplied `io`) stays and goes on the
        ratchet's allowlist. Remove `build_options` imports left unused.
  - [x] Verify: `zig build test` passes with `M2_ROM` set; 11,668 pass and 0 skip at
        baseline, and the counts must not change.

- [x] **Step 2: Silent reads, first batch (`a`–`l` files, by name)**
  - [x] Convert every `catch null` / `catch return error.SkipZigTest` / `catch
        |err| switch` read in `src/` files named `a*`–`l*` (including `gb_trace`,
        `correspond`, `enemy_oracle`, `hud_oracle`, `inspect`, `ledger`, `locate`,
        `blocks`, `credits`, `death`, `dispatch`, `duration`, `aram_*`, `audio*`,
        `gfx_info`). `audio_sites.load` passes read errors up; null stays "no ROM".
  - [x] Run `zig build test` with `M2_ROM` set and triage each new failure case by case.
        The cart is accepted on hardware, so a new failure is first suspected to be a
        stale or invalidated test (fix or retire it). If it is a real finding, stop and
        raise it with James. Record each failure and its verdict in the step summary
        and the commit.

- [x] **Step 3: Silent reads, second batch (`m`–`z`), the ratchet, and the guard**
  - [x] Convert the rest: `map`, `oracle`, `pause_oracle`, `queen_oracle`, `residue`,
        `room`, `roster`, `routines`, `save`, `scenario`, `snes_*` (`snes_inject`,
        `snes_chr`, `snes_layout`, `snes_convert`, `snes_render`), `sprites`, `tas`,
        `title_oracle`, `transition` and any others the scan finds.
  - [x] Ratchet: a test in `testrom.zig` scans `src/**/*.zig` and fails on any
        `build_options*.rom_path` outside the allowlist (`testrom.zig`, `verify.zig`,
        `*_main.zig`, and each non-test library site with its reason). `testrom_mod`'s
        test run gets `setCwd` so it can read `src/`. Check that the ratchet can fail:
        put one inline read back, watch it fail, then remove it.
  - [x] Confirm `rg 'fn loadRom'` finds nothing.
  - [x] Triage new failures as in step 2.
  - [x] Guard: with `M2_ROM=/nonexistent.gb`, `zig build test` fails, in a former
        `catch null` loader, a former inline `catch return error.SkipZigTest` read, and
        `snes_inject`. Record the output in the commit message.
  - [x] Verify: `zig build verify` passes.

- [x] **Step 4: The gate requires a ROM**
  - [x] `build.zig`: when `rom_path` is empty, `rom_check = b.addFail("no ROM: set
        M2_ROM (mise.toml) or pass -Drom=; see docs/setup.md")`. Otherwise it is a no-op
        step.
  - [x] Add a `test-rom` step that depends on `rom_check` and `test_step`.
        `verify_run` depends on `rom_check`. `verify-full` gets it through `verify_run`.
  - [x] Update the `verify` step description and the gate comment (`build.zig` "Phase
        0a has no CI ...") and the `romPath` doc comment. In `verify.zig`, the no-ROM
        branch (`:83`) becomes a `FAIL`, so running the executable by hand cannot report
        green either, and the `absent` legend line (`:77`) names only the emulator and the
        recording. `mise.toml`'s `M2_ROM` comment and the `verify` task description
        stop saying "skip".
  - [x] Docs: `docs/setup.md`, the README command list and `docs/conformance.md` say that
        `test-rom`, `verify` and `verify-full` must be run locally with a ROM, why (it
        cannot be distributed; there is no CI yet), and that `zig build test` skips ROM
        tests without one.
  - [x] Guard: with `M2_ROM` unset (`env -u M2_ROM`, outside mise), `zig build test-rom`
        and `zig build verify` both fail with the message, and `zig build test` passes.
        Record this in the commit message.
  - [x] Verify: `zig build test-rom` and `zig build verify` pass with `M2_ROM` set.

- [x] **Step 5: Dead code, orphans, README**
  - [x] Re-run `rg -w` on each name across the whole repo (Zig, Lua, asm, docs), then
        delete `PointerSite.isExternal`
        (`audio_data.zig`), `Observation.writersOf` (`locate.zig`), `Bank.inUseCount`
        (`map.zig`), `anchorsFor` (`oracle.zig`), `Set.assetBytes` and `blobTotal`
        (`snes_convert.zig`), `edgeOpening` (`warp.zig`) and `step11_tables`
        (`sprites.zig`).
  - [x] Read `unhandledCode` next to `unhandledPose`. Delete it unless the pair is a
        deliberate API, and say which.
  - [x] Remove any imports, constants or helpers that the deletions leave unused
        (re-run the unused-declaration check on the touched files).
  - [x] `git rm test/probe.lua tools/audio-load.sh`.
  - [x] Read the README Status section and fix any claim that contradicts step 27. If
        there is none, make no edit and say so.
  - [x] Verify: `zig build test` passes.

- [x] **Step 6: Flag swallowed allocation failures**
  - [x] `ledger.ExecRecorder`: add `incomplete: bool`, set it in `record` on either
        allocation failure, and carry it out as `Observation.edges_incomplete`. Update
        the struct comment: the observation still runs (a ledger that did not run is the
        bigger lie), but it now says it is missing edges.
  - [x] `room.SaveLog`: move the record-keeping in `onWrite` into
        `fn note(self, bank, addr, value)` so it can be tested without a bus. Add
        `incomplete: bool`, set it on a failed `sites.put` or `list.append`, and carry
        it out as `SaveReport.incomplete`. As built: `room.LoadLog` (`:777,788`) had the
        same two swallowed allocations, which the sweep missed, and gets the same `note`, flag
        and `LoadReport.incomplete`. A write past the log's `limit` is still dropped on
        purpose and does not set the flag.
  - [x] Tests: drive `ExecRecorder.record` and `SaveLog.note` with
        `std.testing.FailingAllocator`, and assert the flag is set. As built: one test
        per file, failing each of the two allocations in turn, for both logs. With the
        flag-setting lines removed, both tests fail.
  - [x] Consumers: `dispatch.zig` (the reader of `obs.edges`) and `tas_main.zig:394`
        (the reader of `r.save`) still print their report, then a `FAIL ... incomplete:
        allocation failed` line, and exit with an error when the flag is set. As built:
        also `tas_main.zig`'s `--sram` path, which prints the `LoadLog` report.
  - [x] Verify: `zig build test` and `zig build verify` pass.

- [x] **Step 7: Close**
  - [x] Check `docs/feature_tracker.md` and `docs/conformance.md` for anything that
        should record these changes (the `test-rom` step, the ROM requirement), and
        update them.
        As built: `conformance.md` already had it (step 4); `feature_tracker.md` F10 gets a
        2026-10-04 note.
  - [x] Final `zig build verify` on the last commit; report the commit list to James.
