---
created: 2026-10-04T04:18:36Z
updated:
  - 2026-10-04T04:18:36Z
  - 2026-10-04T04:52:51Z
  - 2026-10-04T05:08:16Z
  - 2026-10-04T05:22:17Z
  - 2026-10-04T05:41:51Z
  - 2026-10-04T18:01:02Z
  - 2026-10-04T18:24:20Z
  - 2026-10-04T18:50:25Z
  - 2026-10-04T19:25:31Z
working_directory: /Users/james/git/snes_game_dev
---

# Requirements

## Status: Final

## Overview
Clean up dead code and silent test skips in `../m2snes`, from the 2026-09-28 sweep
(`00-prompt.md`), re-verified on 2026-10-04 against `remote-init` d09c30f (1.0 step 27,
clean tree). All work is on `remote-init`, never `main`.

## Re-verification (what changed since the sweep)
- `loadRom()` copies: **30**, not 28 (`credits.zig`, `debug_tables.zig` are new; `locate`,
  `gb/trace`, `gb/sameboy` counted). Silent ones: **16** `catch null` (the sweep's 15 plus
  `credits`), plus two variants the sweep missed: `pause_oracle` maps `FileNotFound` to
  null, and `snes_inject` maps *every* read error to `error.SkipZigTest`. Size limits vary:
  `1 << 20`, `4 << 20`, `1 << 22`, `expected_size * 4`.
- README Status: **already rewritten** at step 27 ("1.0, the complete game ..."). The
  "How Phase 0a got here" subsection is kept on purpose as a record. Item 2 reduces to a
  check for any remaining stale claims.
- Orphans and the 9 unused functions: still present, still unreferenced.
- Found at implementation (2026-10-04): beyond the 30 named loaders, test code reads
  `build_options.rom_path` inline about 150 times across about 50 files, about 110 of
  them `catch return error.SkipZigTest` or `catch null`. There are also three more named
  `catch null` loaders (`hud_oracle`, `snes_convert`, `snes_render`), and
  `audio_sites.load` (called by the `audiosites` CLI too) maps a read error to "no ROM".
  Feature 1 was widened to cover all of them, with a ratchet (James, 2026-10-04).
- Reflection: `oracle.zig:257` walks `@typeInfo(key).decls`, but only over the `key`
  namespace; every other `@field` walks fields, not decls. The unused-decl check still holds.

## Features

### 1. One ROM loader for tests; no silent skips
**Acceptance Criteria:**
- One shared helper loads the ROM for tests. It returns null (→ `SkipZigTest`) **only**
  when `build_options.rom_path` is empty; every read error propagates and fails the test.
- Every test read of the ROM goes through the helper: the 30 named loaders, the other
  named `catch null` loaders, and every inline `build_options.rom_path` read in a test.
  `rg 'fn loadRom'` finds nothing.
- `audio_sites.load` passes read errors up instead of returning null; null still means
  "no ROM configured".
- Ratchet: a unit test fails if `build_options.rom_path` appears in any `src/` file
  outside an explicit allowlist: `testrom.zig`, `verify.zig`, the `*_main.zig` CLIs,
  and any non-test library site, each named with its reason. A new inline test read
  therefore fails `zig build test`.
- One size limit, `rom.expected_size * 4` (1 MiB), not ad-hoc constants.
- The helper takes the allocator as a parameter (callers use arena, `testing.allocator`
  or their own).
- New failures are expected: some tests may have been skipping on a real read error.
  The cart is accepted on hardware, so a new failure is not presumed to be a cart defect.
  Each one is evaluated case by case, as either a stale or invalidated test (fix or
  retire the test) or a real finding (raise it with James), and recorded in the
  step summary and the commit message.
- Guard: with `M2_ROM` set to a nonexistent path, the ROM tests **fail** (shown once, and
  recorded in the commit message). A permanent test proves the helper's read path
  propagates `FileNotFound` rather than returning null.
- `zig build test` and `zig build verify` pass with a valid `M2_ROM`.

**Out of Scope:**
- The ~30 unused named constants (low priority in the sweep; left out 2026-10-04).
- Changing the "M2_ROM unset → skip" behaviour itself (by design).
- Non-test ROM loading (`rom.ingestFile` and the CLI paths).

### 2. README Status check
**Acceptance Criteria:**
- Status section read end to end; any claim contradicting step 27 is fixed. If none, no
  edit, and that is said in the step summary.

**Out of Scope:**
- Rewriting the "How Phase 0a got here" record.

### 3. Orphan files
**Acceptance Criteria:**
- `test/probe.lua` deleted.
- `tools/audio-load.sh` deleted (decided 2026-10-04; git history keeps it).

### 4. Unused functions
**Acceptance Criteria:**
- Deleted, each re-confirmed unreferenced first: `PointerSite.isExternal`,
  `Observation.writersOf`, `Bank.inUseCount`, `anchorsFor`, `Set.assetBytes` + `blobTotal`,
  `edgeOpening`, `step11_tables`.
- `unhandledCode`: delete unless reading it next to `unhandledPose` shows the pair is a
  deliberate API; say which in the step summary.
- Any import or helper made unused by a deletion is removed too.

### 5. Swallowed allocation failures
**Acceptance Criteria:**
- `ledger.zig` `ExecRecorder.record` (both `getOrPut ... catch return` and
  `append ... catch {}`) and `room.zig:680,691` set an overflow flag on OOM instead of
  dropping the record silently.
- A test drives each recorder with `std.testing.FailingAllocator` and asserts the flag
  is set.
- The CLI output that uses each recorder reports an error when the flag is set, instead
  of printing an incomplete report as if it were complete.

### 6. The gate requires a ROM
There is no CI and the ROM cannot be distributed, so the gate only ever runs locally with
a ROM. Today `verify` treats a missing ROM as "skip with a notice" (`build.zig:3-6`), so it
can pass without testing the ROM.

**Acceptance Criteria:**
- A "ROM present" check step fails when the configured `rom_path` is empty, with a
  message naming `M2_ROM` and `-Drom=`. No build option: with `rom_path` non-empty the
  shared loader (feature 1) can never return null, so the check alone makes skips
  impossible on these paths.
- `zig build test-rom` depends on the check, then runs the unit tests.
- `zig build verify` and `verify-full` depend on the check, so they fail before doing any
  work when `M2_ROM` is empty.
- `zig build test` keeps skipping ROM tests without a ROM (the fast no-ROM loop).
- `docs/setup.md`, the README and `docs/conformance.md` state that `test-rom` and
  `verify` must be run locally with a ROM, and why.
- Guard: with `M2_ROM` unset, `zig build test-rom` and `zig build verify` both fail
  (shown once, recorded in the commit message).

**Out of Scope:**
- Separating ROM tests from no-ROM tests into their own files or modules.
- The Mesen-absent notice in `verify` (a separate decision).
- CI. Planned next cycle: GitLab CI with the ROM from Secure Files (Settings → CI/CD →
  Secure Files, fetched into `.secure_files/` by `download-secure-files`). Runner choice is
  open: GitLab's hosted Linux runners need Mesen2 and the toolchain scripted for Linux; a
  runner on James's Mac already has them. Feature 6 is what makes such a job fail, not
  skip, if the file goes missing.

## Constraints & Dependencies
- Repo `../m2snes`, branch `remote-init`; commits there, never `main`.
- Tests depend on `M2_ROM` (from `mise.toml`); verify with it set.
- Never `zig fmt` a whole file (memory: silent test traps).
- Each feature lands as its own commit so any one can be reverted.
