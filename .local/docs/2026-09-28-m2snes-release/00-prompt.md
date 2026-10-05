# Metroid II SNES port: first release

Package and publish m2snes (`~/git/m2snes`) as a bring-your-own-ROM builder: one
downloadable binary that takes the user's Game Boy ROM and writes the SNES ROM. It
needs no dev stack: no Zig, mise, asar, Mesen or snes_game_dev checkout. Starts after
metroid2 1.0 (`../2026-09-25-metroid2-1-0-complete-game/`) is complete.

## Decisions (James, 2026-09-28)

- **License: MIT.** M2RoS is MIT as well; the ROM-data rule still applies.
- **Release targets:** macOS arm64, Linux x86_64, Linux arm64, Windows x86_64.
  Windows arm64 is included only if it costs nothing beyond a matrix line. It would
  ship labelled untested; James will not test it.
- **Not in this cycle:** publishing zasm. That is its own goal, after m2snes's first
  release. A 1.1/2.0 is expected to be a rewrite of m2snes on top of zasm.
- **Not in this cycle: PC play.** It arrives with the zasm rewrite (James, 2026-09-28), not
  as a recompile of the current engine. **No emulator core is ever shipped or depended on.**

## Current state (verified 2026-09-28)

- The tree holds no copyrighted bytes. `engine/engine.bin` + `engine.sym` and
  `engine/audio.bin` are committed and pulled in with `addAnonymousImport`
  (`build.zig` `addEngine`).
- **The `m2snes` executable is still the Phase 0a Step 1 stub** (`src/main.zig`,
  53 lines). It reads the ROM in, checks the revision, prints the SHA-1 and stops.
- The real pipeline is the `zig build rom` step. It is a chain of separate
  executables in the build graph (`crawl` → `rom`/`src/inject_main.zig`), with
  the ROM found through `M2_ROM` and output to `build-out/`.
- The audio shim arrives from snes_game_dev as a copied package with a MANIFEST
  (commit + sha256 per file, `tools/sync-shim.sh`). That is already a pinned
  version; keep it, don't submodule.
- Zig is pinned at 0.16.0 (`mise.toml`). No LICENSE, no CI, and no
  `.github/` exist. The README status is stale ("Phase 0a, Step 14 of 18").
- `src/sbref.c` (SameBoy) is compiled only for the audio A/B, not the builder,
  so the builder should cross-compile as pure Zig. Confirm this.
- `main` is write-protected; work is committed on `remote-init`.

## Goals

1. **One binary does the whole build.** `m2snes <metroid2.gb> [-o out.sfc]` runs
   crawl → convert → inject in-process. Its output is byte-identical to
   `zig build rom`, and that is graded.
2. **Deterministic output.** The same ROM gives the same `.sfc` on every target.
   The release publishes the output's SHA-1 so a user can check their build.
3. **Clear refusals.** Wrong revision, headered or trimmed dumps, and GBC hacks
   each get their own error message with the expected SHA-1.
4. **Release mechanism.** CI cross-compiles every target on a tag. The release
   carries the binaries, checksums, the MIT LICENSE, third-party notices and a
   short README. The version is pinned in `build.zig.zon` and printed by
   `--version`, along with the engine and shim commits.
5. **Repo is publishable:** a LICENSE file, a README rewritten for players first and
   developers second, and a documented way to rebuild the engine images, which are
   the only non-Zig step.

## Open questions for requirements

- What the release is cut from, since `main` is protected: a PR merge of
  `remote-init` → `main` and then a tag, or tags on `remote-init`.
- GitHub Actions or local cross-compile plus `gh release`. Zig cross-compiles
  every target from a single host.
- Whether dev-only tooling (emulator, ledger, audiocmp, romtest) moves behind a
  build option so a plain `zig build` builds only the builder.
- macOS signing and notarization. Unsigned binaries hit Gatekeeper, so either
  document the workaround or sign.
- Grading: cross-target determinism needs the output hash from each target's
  binary. That means running the Linux arm64 and Windows binaries in CI, not only
  building them.
