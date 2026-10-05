---
created: 2026-10-04T22:02:33Z
updated:
  - 2026-10-04T22:02:33Z
  - 2026-10-04T22:27:59Z
  - 2026-10-04T22:51:49Z
  - 2026-10-04T23:12:19Z
  - 2026-10-05T03:49:48Z
  - 2026-10-05T04:07:34Z
  - 2026-10-05T04:33:53Z
  - 2026-10-05T14:19:32Z
  - 2026-10-05T14:51:38Z
  - 2026-10-05T16:31:41Z
  - 2026-10-05T17:14:02Z
  - 2026-10-05T18:12:39Z
  - 2026-10-05T18:22:31Z
  - 2026-10-05T18:36:36Z
  - 2026-10-05T18:41:17Z
  - 2026-10-05T19:42:12Z
  - 2026-10-05T20:46:23Z
  - 2026-10-05T21:07:49Z
  - 2026-10-05T21:57:39Z
  - 2026-10-05T23:09:17Z
working_directory: /Users/james/git/m2snes-gh
---

# Requirements

## Status: Final

## Overview
Return m2snes to its original shape: a **downloadable binary** that a player runs against
their own local Metroid II Game Boy ROM to produce the SNES ROM. A player never installs
Zig, mise or anything else, and never runs `zig build`. Today the only working path is
`zig build rom`, which requires the dev stack; this cycle moves the whole pipeline into the
`m2snes` binary.

**Moved to GitHub (James, 2026-10-05):** the project's public home is
`github.com/jnschurig/m2snes`, cloned at `~/git/m2snes-gh`, starting from a fresh,
audited commit. GitHub Actions builds every target, including macOS, so no release
binary depends on the developer's machine. **CI never sees the ROM**: public Actions logs
are public, so every ROM-dependent check runs locally, in a pre-push hook and in a
pre-release `release-verify`. The GitLab project (`jankotron-group/m2snes`) is archived,
private.

## Facts this rests on (verified 2026-10-04, GitHub facts 2026-10-05)

- metroid2 1.0 is complete (`../2026-09-25-metroid2-1-0-complete-game/02-plan.md`).
- `src/main.zig` is still the 53-line ingest stub. The real build is `zig build rom`:
  `crawl` (cached in `build-out/`) → `src/inject_main.zig` (convert → inject), writing
  `build-out/m2snes.sfc` + `.sym` + three preview PNGs.
- A cold crawl takes **126 s** single-threaded on this Mac (1185 doors). The builder pays
  that on every run; Feature 1b parallelizes it.
- `rom.zig` already refuses: wrong size, not a GB ROM, not Metroid II, header checksum,
  size-byte mismatch, wrong revision (with expected SHA-1).
- The pipeline modules (`snes_convert`, `snes_inject`, `crawl`, `warp`, `roster`,
  `screens`) import `build_options` and/or `testrom`; the ROM path is a configure-time
  value. Libc is linked only by `verify` and `audioab` (SameBoy `sbref.c`).
- GitHub: `jnschurig/m2snes` is **public and empty** (wiki, issues, projects on). `gh` is
  logged in as `jnschurig`. Public repos get GitHub-hosted runners free, including macOS
  arm64, Linux arm64 and Windows x86_64 (to be confirmed against GitHub's docs in the plan).
  **Actions logs of a public repo are readable by anyone.**
- Zig cross-compiles every release target from any host. On this Mac, the
  `aarch64-macos` binary built by `pin-check` and by `release` were byte-identical
  (Step 7); cross-host reproducibility is not yet shown.
- OrbStack (`orbctl`) is on this Mac and can run Linux binaries; wine and qemu are not.
- Superseded: the GitLab project, its secure file `metroid2.gb` (id 3531600) and the
  Free-plan minute budget no longer bear on the release.

## Features

### 1. One binary does the whole build
`m2snes <metroid2.gb> [-o out.sfc]` runs crawl → convert → inject in-process. The player
downloads it, runs it on their ROM, and gets a `.sfc`. Nothing else is installed.

**Acceptance Criteria:**
- The binary is the one pipeline. `zig build rom` stays for developers, but only as a thin
  step that builds `m2snes`, runs it with `--sym` into `build-out/` (same `.sfc` and
  `.sym` names as today), then runs a new dev-only `zig build previews` step. There is no
  second convert/inject path that could drift from what players run.
- The three preview PNGs (`m2snes-boot.png`, `m2snes-title.png`, `m2snes-title-4x.png`)
  move out of the cart build into the `previews` dev step, which renders them from the GB
  ROM and the cached crawl. The player binary carries no PNG encoder or title renderer.
  Previews are a human glance, not graded output.
- Before the refactor, the SHA-1 of today's `zig build rom` output is pinned in the repo.
  The binary's output must equal that pin, graded in the gate, the pre-push hook and
  `release-verify`. The pin changes
  only by a deliberate commit that says why. A mutated output must fail the grade.
- A released binary runs on a machine with no Zig, mise or repo checkout, from any
  working directory. CI checks this ROM-free on a native runner for every tested target
  (macOS arm64, Linux x86_64, Linux arm64, Windows x86_64, Windows arm64): outside the
  checkout, with no `zig` on `PATH`, the binary runs `--version` and `--help`, and
  refuses a synthetic non-ROM file with a non-zero exit, writing nothing.
- **Location-independent:** the binary behaves the same wherever it is installed and
  wherever it is run from. It reads nothing beside itself, nothing from the build host,
  and no environment variable. Every path it touches comes from its arguments, resolved
  against the working directory when relative. Graded locally: the same cart SHA-1 from
  two install directories × two working directories × a relative and an absolute ROM path
  (the relative/absolute and cwd cases are also checked ROM-free in CI with a refusal).
- Default output path is `m2snes.sfc` beside the input ROM; `-o` overrides it. It never
  overwrites the input file: the check compares the resolved file (device + inode, or the
  Windows file ID), so a symlink or another spelling of the input's path is refused too.
- Writes only the `.sfc` by default (no `.sym`, no PNGs, no `build-out/`). `--sym` also
  writes the symbol file next to it.
- `--debug` builds the debug cart instead: the same cart with `DebugAllowed` set
  (L+R+Start in play opens the debug menu), as `zig build rom -- --debug` does today.
  Its default output name is `m2snes-debug.sfc`, so it never overwrites the retail cart.
  Its SHA-1 is pinned and graded the same way as the retail one, including across
  targets. `--help` lists the flag and says what the debug menu is.
- A hidden, dev-only `--crawl-cache DIR` reuses the crawl file cached in `build-out/`;
  `zig build rom` and the gate pass it so they don't re-crawl. It is undocumented for
  players, and `pin-check` and `release-verify` grade the binary **without** it (the
  path players run). Feature 1b's
  byte-identical crawl file is what makes the two paths equivalent.
- No configure-time ROM path anywhere in the builder's import graph; the ROM arrives only
  as a runtime argument.
- Prints progress during the crawl (it is the long part) and ends by printing the output
  path and its SHA-1.
- Writes atomically (temp file + rename) so a failed run never leaves a partial `.sfc`.
- `--version` prints the m2snes version (from `build.zig.zon`), the m2snes git commit it
  was built from (the commit hash, never `git describe`, so a CI build and a local build
  of the same commit embed the same string; `unknown` when built without git, suffixed
  `-dirty` when the tree had uncommitted changes) and the shim commit (from
  `audio/shim/MANIFEST`).
- `--help` / no arguments prints usage and the expected ROM's revision and SHA-1.

**Out of Scope:**
- Caching the crawl between runs for players.
- Building the retail and debug carts in one run (run the binary twice).
- Building without the crawl. The crawl feeds only the debug menu's WARP page, but every run
  still pays for it. Deferred by James on 2026-10-05 as m2snes `docs/feature_tracker.md` F14,
  with the options there.

### 1b. Parallel door crawl
The crawl (`src/crawl.zig`) is a work queue (`entries[head..]`) that seeds the next
unreached room whenever it runs dry. Each pass takes the whole pending queue as one wave
and spreads its door tries (`tryDoor`, which depends only on the entry's snapshot) across
worker threads, each with its own Game Boy machine and its own counters. Results are
merged on one thread in today's order (entry, cell, direction, count) and the counters
are summed, so the entries, edges and crawl file it produces are unchanged. Seeding stays
sequential.

**Acceptance Criteria:**
- The crawl file is byte-identical to the single-threaded crawl's for the same ROM. A
  test asserts it at thread counts 1, 2 and the machine's core count, and the `.sfc` pins
  in Feature 1 still hold.
- Thread count defaults to the logical CPU count; `--jobs N` on the binary overrides it
  (`--jobs 1` is the sequential crawl, kept as the reference path).
- The crawl's counters (`tried`, `no_spot`, `stuck`, `walled`, `undrawn`, `seeded`) match
  the sequential crawl's.
- The emulator is confirmed free of shared mutable global state before threads use it;
  any such state is made per-machine.
- Wall-clock time is measured before and after on this Mac (126 s baseline) and recorded.
  There is no speed threshold to pass; the guess is 4–6× on 8–10 cores.
- `crawl_version` is not bumped (the output does not change), and the `zig build crawl`
  dev step uses the same parallel path.

**Out of Scope:**
- Parallelizing the seeding of unreached rooms, convert or inject.
- Changing what the crawl walks or finds.

### 2. Deterministic output
**Acceptance Criteria:**
- The same ROM gives the same `.sfc` from every release target's binary.
- **No build-host paths in a release binary.** Source and Zig-library paths recorded for
  debug info, `@src()` or panics are relative (to the repo root and to the Zig lib dir),
  never absolute. A path is absolute only when it arrives at run time as an argument.
  Measured 2026-10-05: both Linux release binaries carry 37 absolute `/Users/james/...`
  DWARF directories (repo `src/`, the mise Zig `lib/std`, a `.zig-cache/c/…` options
  module); macOS and Windows carry none. If Zig 0.16 cannot record them relative, the
  release binaries are stripped of debug info instead, and the plan says so.
  - A check scans every release binary for absolute path prefixes (`/Users/`, `/home/`,
    `/opt/`, `/tmp/`, `/private/`, a drive letter `X:\`, and the build root and Zig lib dir
    of the build at hand) and fails on any. It runs in CI and in the gate, and a
    deliberately unstripped/unmapped build fails it.
  - Developer tools are out of this rule: their configure-time paths (`M2_ROM`, `MESEN`)
    are passed in by the developer and never ship.
- **Reproducible builds:** a release binary built by CI is byte-identical to the same
  target built locally from the same commit, on any dev host. `release-verify` checks this
  for every target, every release.
- **`zig build release-verify -- vX.Y.Z`** (local, needs the ROM) runs against the tag's
  **draft** Release:
  - downloads every archive and checks it against `SHA256SUMS`;
  - checks each binary byte-identical to a local cross-build of the tag's commit;
  - runs the host's binary on the ROM, retail and debug, against `pins/cart.txt`;
  - runs both Linux binaries the same way through OrbStack when it is present, and prints
    `not run:` otherwise;
  - prints a summary line naming which targets were run and which only compared.
  - builds from a temporary `git worktree` of the tag, never the working tree, so local
    edits or a `-dirty` commit string cannot enter the comparison; the worktree is removed
    afterwards.
  - compares binaries, not archives. Archives (tar/zip timestamps) are not expected to be
    reproducible; `SHA256SUMS` checks only that the download is intact.
- Windows binaries (and macOS ones on a non-Mac dev host) are graded only by byte-identity
  plus CI's native ROM-free smoke run (Feature 1), unless a host of that OS runs
  `release-verify`.
- James publishes the draft only after `release-verify` passes. The published notes carry
  its summary line.
- The release notes publish the retail and debug SHA-1s from `pins/cart.txt` at the tag,
  which `release-verify` graded, not typed by hand.

### 3. Clear refusals
**Acceptance Criteria:**
- Distinct messages, each naming the expected revision and SHA-1, for: wrong revision;
  **headered dump** (512-byte copier header: 256 KiB + 512); **trimmed/overdumped**
  (other sizes); **GBC/colourised hack** (CGB flag set at `$0143`, or a known hack SHA-1);
  plus the existing not-GB / not-Metroid-II / corrupt-header cases.
- Each refusal exits non-zero and writes nothing.
- One unit test per refusal, built from a synthetic or mutated buffer — never a committed
  ROM byte.

**Out of Scope:**
- Accepting or auto-fixing any of these (e.g. stripping a header). A refusal says what to
  do; it does not do it.

### 4. CI on GitHub Actions
**Acceptance Criteria:**
- `.github/workflows/` holds the config. On every push and pull request, ROM-free:
  - `zig build test` with no `M2_ROM` (ROM tests print `not run:`, as they do locally).
    It includes Step 1's pin/history agreement check, so a PR cannot move the pin without
    a reason line;
  - the policy scan of the tree (without the ROM this is the size ceiling and
    forbidden-path rules);
  - the cross-compile of every release target once, on Linux, uploading only the
    binaries as workflow artifacts, plus the no-build-host-path scan (Feature 2);
  - the native smoke run (Feature 1) of those same artifacts on macOS arm64, Linux x86_64,
    Linux arm64, Windows x86_64 and Windows arm64 runners;
  - for a Dependabot PR, a check that it touches only `.github/`.
- **Tools come from `mise.toml`**: CI installs them with `jdx/mise-action`, so Zig's
  version has one pin. A committed `mise.lock` holds per-platform checksums for every
  runner and dev platform, and installs are verified against it.
- **No ROM in CI, ever.** The repo has **no Actions secrets or variables**, so nothing
  can fetch the ROM, and fork PRs have nothing to reach. `mise.toml`'s `M2_ROM`/`MESEN`
  resolve to empty on a runner.
- Caching is allowed (CI holds nothing ROM-derived to cache); mise-action's tool cache is
  used as it comes, with nothing more elaborate.
- Least privilege: workflows default to `permissions: contents: read`; only the release
  job gets `contents: write`. No `pull_request_target`. Third-party actions are pinned by
  commit SHA, and Dependabot (`github-actions` ecosystem) keeps the pins current.
- Every job has `timeout-minutes`; a `concurrency` group cancels superseded runs of the
  same ref (never on tags).
- Fork pull requests need approval before workflows run (the repo setting).
- Mesen rungs and every ROM rung are absent in CI. CI is not a replacement for the local
  `verify` / `verify-full`.
- Runner availability (native Linux arm64, macOS arm64, Windows arm64 free for public
  repos) is confirmed against GitHub's docs in the plan; a target with no native runner
  keeps byte-identity only and its archive is labelled *untested*.

**Out of Scope:**
- Running the ROM, Mesen or `verify-full` in CI.
- Self-hosted runners.
- CI linting tools (zizmor, actionlint) and custom workflow checks.

### 4b. Local hooks
**Acceptance Criteria:**
- Tracked hooks in `.githooks/`, enabled with `mise run hooks` (which sets
  `core.hooksPath`). The README's developer section says to run it once per clone.
- **`pre-commit`**: the policy scan (size ceiling, forbidden paths, ROM n-grams) over the
  staged blobs only, so ROM bytes are refused before they enter local history. Target:
  about a second. With no `M2_ROM` it still runs the ROM-free rules and prints that the
  n-gram scan did not run.
- **`pre-push`**: the history audit on the commits being pushed (every new blob through
  `policy.checkBytes`, ROM n-grams included), then the gate. A red result blocks the push.
  - Which gate: `zig build verify` is timed (warm `build-out/` cache, this Mac) in the
    plan. Under about 2 minutes, the hook runs it; otherwise it runs `zig build test` with
    the ROM plus `cart pin`, and `verify` stays manual. One tier, chosen once and recorded.
  - On a `v*` tag push it also runs `zig build pin-check`.
  - With no `M2_ROM` set it refuses the push and says why, rather than passing with the
    ROM rungs `not run:` (unset `M2_ROM` silently skips ROM tests).
- Merges done in GitHub's web UI never pass the hooks. Your own PRs from `dev` are
  covered, because `dev` was pushed through them. **A PR from anyone else is never merged
  in the web UI:** it is fetched locally and pushed to `dev` through the hooks first. The
  README's Contributing section says so.
  - **Exception: Dependabot PRs** may be merged in the web UI when they touch only
    `.github/` (CI fails one that touches anything else); action pins carry no ROM data.
  - GitHub's web file editor is not used on this repo (it bypasses the hooks); the README
    says so.
- Bypassing with `--no-verify` is possible; the release does not depend on the hooks
  alone, because `release-verify` grades the release itself.

### 5. Release mechanism
**Acceptance Criteria:**
- Pushing a tag `vX.Y.Z` runs a workflow that re-runs the CI checks and creates a
  **draft** GitHub Release with `gh release create --draft` (no third-party release
  action): archives for macOS arm64, Linux x86_64, Linux arm64, Windows x86_64 and
  Windows arm64, a `SHA256SUMS` file, and in each archive `m2snes`, LICENSE,
  THIRD-PARTY-NOTICES and a short player README.
- The tag must match `build.zig.zon`'s version or the workflow fails. The check is a
  script unit-tested locally with a mismatched name; no throwaway tag is pushed to test it.
- `v0.1.0` is the first real run. A release that turns out broken is fixed forward: bump
  the version, tag again, and delete the broken tag and its draft (or, if published and
  unusable, the release), noting why in the next release's notes.
- The first release's notes carry no `pins/history.md` entries (no previous tag).
- Linux binaries are statically linked (musl / no libc), runnable on any distro.
- Archive format: `.tar.gz` for macOS/Linux, `.zip` for Windows.
- The notes come from a template plus the pins at the tag, the trademark notice, and
  (when the pin moved since the previous release) the `pins/history.md` entries since then.
- James runs `release-verify`, adds its summary line to the notes, and publishes.
- `v*` tags are protected by a ruleset (only James can create them).

**Out of Scope:**
- macOS signing/notarization.
- A GitLab release or mirror.
- Package managers (Homebrew, Scoop, AUR).
- Publishing zasm; PC play; any emulator core.

### 6. Publishable repo
**Acceptance Criteria:**
- `LICENSE` (MIT) at the root; `THIRD-PARTY-NOTICES` covering what the shipped binary
  carries (anything from M2RoS, with its MIT notice) and noting dev-only third-party code
  (SameBoy) separately. snes_game_dev has no LICENSE, so the notices state that the audio
  shim is James's own code, MIT, from snes_game_dev at the MANIFEST's commit, after
  confirming nothing in it derives from third-party code.
- README rewritten: players first (download, run, verify SHA-1, macOS quarantine note,
  refusals explained), developers second (mise, the pre-push hook, gate, CI, how releases are cut).
- `docs/` documents rebuilding the engine images (`zig build engine`, `spcengine`, the
  asar / spc700asm fetch scripts) and that `verify` checks the committed images match.
- A trademark / non-affiliation notice appears in the README, the release's player
  README and the release notes, and `--help` prints a one-line form of it. Text:
  > *Metroid*, *Metroid II: Return of Samus*, Nintendo, Game Boy and Super Nintendo
  > Entertainment System are trademarks of Nintendo. This project is not affiliated with,
  > endorsed by, or sponsored by Nintendo. It contains no Nintendo code, graphics, sound
  > or other copyrighted material; the builder works only from a ROM you dump from your
  > own cartridge. All other trademarks and copyrights belong to their respective owners.
- A plain `zig build` builds and installs only the `m2snes` builder (it already installs
  only that; this is held by a check, not left implicit).

**Out of Scope:**
- Moving dev tools out of `build.zig` or into a separate package.

### 7. Going public on GitHub
The GitHub repo is already public, so **nothing reaches it before it passes the ROM-data
rule**: whatever is pushed there is public at once and permanent (forks, caches).

**Acceptance Criteria:**
- **Fresh start:** the first push is a single commit of the current `m2snes` tree (from
  `~/git/m2snes` at the end of Step 8), with no GitLab history. Development continues in
  `~/git/m2snes-gh`; `~/git/m2snes` is kept read-only for reference.
- **Before the first push:** the policy scan (size ceiling, ROM n-grams) and a secrets
  scan (`gitleaks`) run over the exact tree being committed, and both are clean. The
  untracked dev state (`metroid2.gb`, `build-out/`, `extracted/`, `zig-out/`, `.zig-cache/`)
  is ignored by `.gitignore` and checked absent from the commit.
- The hooks (Feature 4b) are installed in `~/git/m2snes-gh` before the first push.
- **GitHub settings:** wiki and projects off (unused); fork PR workflows need approval;
  Actions default token read-only; a ruleset on `main` (PR required, CI checks required, no
  force-push or deletion) and on `v*` tags (James only).
- **GitLab:** the project is archived and stays private; its secure file is left as is.
  Archiving is James's action, after the GitHub release is out.

**Out of Scope:**
- Carrying GitLab history, MRs or issues to GitHub.
- Renaming the project or any trademark question beyond the notice in Feature 6.

### 8. Migrate the m2snes skills and docs from snes_game_dev
m2snes-gh becomes self-contained: a session opened there has the skills, cycle docs and
memories it needs without snes_game_dev.

**Acceptance Criteria:**
- **Skills**, tracked in `.claude/skills/` (public):
  - `fxpak`, plus `tools/fxpak.sh`, adjusted to deploy `build-out/m2snes.sfc` /
    `m2snes-debug.sfc`. Its machine-specific paths (SNI binary) come from `PATH` or an
    environment variable, not hard-coded.
  - `verify-gate`, rewritten for m2snes: `zig build test` → `verify` → `verify-full`, plus
    `pin-check`, `repin` and what a red `cart pin` means.
  - `rom-test`, rewritten for m2snes: `zig build rom` → `romtest` in Mesen, with the traps
    that bite (unset `M2_ROM` skips ROM tests; `romtest` does not reassemble; framebuffer
    reads need `--snes.disableFrameSkipping`; zero SRAM first).
  - Each skill's commands are run once in m2snes-gh and work as written.
- **Cycle docs**, tracked in `.local/docs/` (public): the Metroid II cycles (port shape and
  feasibility, 0b slice, audio, 1.0, colorization, cleanup, this release) and the audio
  shim write-ups. Before they are committed:
  - the policy scan with ROM n-grams passes on them;
  - they are read for private content (personal paths are fine to keep; anything else
    private, or long hex dumps of ROM bytes, is removed and noted).
  - Originals stay in snes_game_dev, each migrated cycle directory there getting a one-line
    pointer to its new home. This release cycle continues in m2snes-gh from the move on.
- **Memories**: the m2snes-relevant notes are copied into the m2snes-gh project's memory
  directory (`~/.claude/projects/-Users-james-git-m2snes-gh/memory/`), with `MEMORY.md`,
  and updated for the GitHub model (`dev` branch, PR to `main`; GitLab notes dropped).
  snes_game_dev's memory keeps only what still applies there.

**Out of Scope:**
- `plan-site` and snes_game_dev-only docs (`PLAN.md`, `vm/docs/`).
- Moving the audio shim's source or its sync tooling.
- A `CLAUDE.md` for m2snes.

## Constraints & Dependencies
- Zig 0.16.0. Builder must cross-compile as pure Zig (no libc, no SameBoy).
- ROM-data rule: nothing ROM-derived tracked, released, cached, uploaded, or printed in a
  CI log.
- Work in `~/git/m2snes` stays on `remote-init` until the fresh start. After it, my
  commits go on a `dev` branch of `~/git/m2snes-gh`, and James merges `dev` → `main` by PR.
- Release grading depends on James running `release-verify` locally (needs the ROM).

## Decisions (James, 2026-10-04)
- **Release ref:** James merges into `main` by PR (was: `remote-init` → `main` by MR on
  GitLab) and tags `main`. `v*` tags are protected.
- **Visibility:** public. *(2026-10-05: the GitHub repo is public from the start, so the
  "logs members-only" allowance is void: no ROM in CI.)*
- **Crawl cost:** parallelized this cycle (Feature 1b), with a progress line. Caching is later.
- **macOS:** unsigned; README documents `xattr -d com.apple.quarantine`.
- **Version:** first release is **v0.1.0**.
- **Author emails** in public history stay as they are.
- ~~Keep the current GitLab project~~ *(superseded 2026-10-05: GitHub, fresh start).*
- ~~CI is manual on branches and MRs~~ and ~~no CI caches~~ *(superseded 2026-10-05:
  GitHub CI is ROM-free and free for public repos, so it runs on every push, and it may
  cache since it holds nothing ROM-derived).*
- **Preview PNGs** move to a dev-only `zig build previews` step, out of the player binary.

## Decisions (James, 2026-10-05)
- **GitHub** (`jnschurig/m2snes`, public) replaces GitLab as the public home. CI builds the
  macOS binary too, so the dev machine can be any platform.
- **No ROM in CI.** ROM checks run locally: the pre-push hook (`verify`) and
  `release-verify` before publishing.
- **Grading:** CI binaries are proven byte-identical to local builds per target, and the
  host's binary (plus Linux through OrbStack) is run against the pins.
- **History:** fresh start, one audited commit.
- **GitLab:** archived, private.
- **Migration:** fxpak (+ script), rewritten verify-gate and rom-test, the cycle docs
  (tracked, audited) and the m2snes memories move to m2snes-gh.
- **CI/hooks kept lean:** Zig pinned once in `mise.toml` (+ `mise.lock`), no custom or
  third-party workflow linting, a fast `pre-commit` policy scan, one pre-push tier chosen by
  measurement, Dependabot for action pins, Windows arm64 smoke-tested natively. Dependabot PRs touching only `.github/`
  may be merged in the web UI.
