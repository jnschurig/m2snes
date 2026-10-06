# Metroid II: Super Return of Samus

`m2snes` is a native SNES rewrite of *Metroid II: Return of Samus*, distributed as a
**bring-your-own-ROM builder**. It is one self-contained program: you give it a dump of
your own Game Boy cartridge, and it writes a SNES ROM.

This repository contains no game data. Every graphic, map, sound and table comes out
of your ROM when you run the builder.

> *Metroid*, *Metroid II: Return of Samus*, Nintendo, Game Boy and Super Nintendo
> Entertainment System are trademarks of Nintendo. This project is not affiliated with,
> endorsed by, or sponsored by Nintendo. It contains no Nintendo code, graphics, sound
> or other copyrighted material; the builder works only from a ROM you dump from your
> own cartridge. All other trademarks and copyrights belong to their respective owners.

## Playing

### 1. Download

From [Releases](https://github.com/jnschurig/m2snes/releases), download the archive
for your machine:

| Machine | Archive |
|---|---|
| macOS, Apple silicon | `aarch64-macos` (`.tar.gz`) |
| Linux, x86_64 | `x86_64-linux-musl` (`.tar.gz`) |
| Linux, arm64 | `aarch64-linux-musl` (`.tar.gz`) |
| Windows, x86_64 or arm64 | `x86_64-windows-gnu` (`.zip`) |

Windows on ARM runs the x86_64 build under emulation. Intel Macs are not supported. The Linux builds are static and run on any distribution.
To check the download, compare its SHA-256 with the release's `SHA256SUMS`
(`shasum -a 256 <archive>` on macOS, `sha256sum` on Linux,
`certutil -hashfile <archive> SHA256` on Windows).

Unpack it. Each archive holds `m2snes` (`m2snes.exe` on Windows), `README.txt`,
`LICENSE` and `THIRD-PARTY-NOTICES`.

**macOS:** the binary is not signed, so macOS blocks a downloaded copy. Clear the
quarantine flag once:

```sh
xattr -d com.apple.quarantine m2snes
```

### 2. Your ROM

You need a dump of your own cartridge, this exact revision:

```
Metroid II - Return of Samus (World), Game Boy, 256 KiB (262,144 bytes)
sha1 74a2fad86b9a4c013149b1e214bc4600efb1066d
```

`m2snes --help` prints the same.

### 3. Build

```sh
./m2snes metroid2.gb
```

On Windows, run `m2snes.exe metroid2.gb`. It takes about half a minute and writes
`m2snes.sfc` beside your ROM (`-o` chooses another path). Play that file on an
emulator or a flash cart.

It ends by printing the SHA-1 of the ROM it wrote. Compare it with the **retail** SHA-1
in the release notes of the version you downloaded. If they match, you have exactly the
cart that release was tested as. Each version builds a different cart, so compare
against your version's notes. `m2snes --version` prints which version you have.

`m2snes --debug metroid2.gb` builds `m2snes-debug.sfc` instead. Its debug menu
(L+R+Start in play) warps, gives items and sets up scenes. It is for testing, not for a
normal playthrough. Its SHA-1 is the release notes' **debug** line.

### When it refuses

`m2snes` refuses any input that is not the expected ROM. It writes nothing and exits
with status 1. Each refusal says what it found, then the revision and SHA-1 it expects.

| It says | Meaning |
|---|---|
| `… behind a … copier header` | The file has an extra header from a copier. Remove the first bytes it names, or dump again. |
| `ROM is … bytes; the cartridge holds exactly 262144` | The dump is trimmed or overdumped, or is another game. |
| `no Nintendo logo` | This is not a Game Boy ROM. |
| `cartridge title is …` | This is a Game Boy ROM, but not Metroid II. |
| `header checksum …` / `header size byte …` | The ROM is corrupt or modified. Dump again. |
| `the Game Boy Color flag … is set` | This is a colourised hack, not the original cartridge. |
| `this is Metroid II, but not the expected revision` | Another revision or a modified ROM. It prints the SHA-1 it found. |
| `… is your ROM; choose another output with -o` | The output path would overwrite your ROM. |

## Developing

### Setup

Tools are pinned in `mise.toml`, and `mise.lock` holds their checksums for every
platform. Install [mise](https://mise.jdx.dev), then in your clone:

```sh
mise trust && mise install
mise run hooks          # once per clone: use the tracked git hooks in .githooks/
```

Most checks need your ROM. Put it at `./metroid2.gb`, or set `M2_ROM` to its path.
The emulator rungs also need [Mesen2](https://www.mesen.ca), found through `MESEN`.
[docs/setup.md](docs/setup.md) has the details.

### The gate

| Command | Needs the ROM | What it is |
|---|---|---|
| `zig build test` | no | Unit tests. It skips those that need the ROM. |
| `zig build policy` | no | The tracked-file policy: size ceiling, forbidden paths, and the ROM n-gram scan when `M2_ROM` is set. |
| `zig build test-rom` | yes | Unit tests, failing without the ROM. |
| `zig build verify` | yes | The gate: every rung, against our own Game Boy emulator running your ROM. About 14 minutes. |
| `zig build verify-full` | yes | The gate, then the slow tier: the 100% recording's worlds and the credits. |
| `zig build pin-check` | yes | Both carts from the `m2snes` binary, run as a player runs it (no crawl cache), against `pins/cart.txt`. `-Dtarget=aarch64-macos` grades the exact binary `release` ships. |

The carts' SHA-1s are pinned in `pins/cart.txt`. A change that changes the output on
purpose re-pins with `zig build repin -- "<why>"`. That logs the old pin, the new pin
and the reason in `pins/history.md`. [docs/conformance.md](docs/conformance.md) lists
every rung, what it compares against, and the fault that shows it is not vacuous.

### The hooks

- **pre-commit** runs `zig build policy -- --staged` over the staged files, so ROM bytes
  are refused before they enter history.
- **pre-push** refuses to push when `M2_ROM` is unset, the tree is dirty, or the pushed
  ref is not `HEAD`. It audits every blob new in the pushed commits against the policy,
  then runs `zig build test-rom cart-pin`. On a `v*` tag it also runs
  `zig build pin-check`. It prints which checks ran.

`zig build verify` is too slow for every push. Run it yourself before you open a PR.

### CI

GitHub Actions runs on every push and pull request, **without the ROM**. The ROM cannot
be distributed, so the repository has no secrets and a runner has nothing to fetch it
with. CI runs `zig build test` and `zig build policy`, builds the release binaries
for all four targets, and smoke-tests each one natively (`ci/smoke.sh`). The smoke test
runs outside any checkout, with no Zig on `PATH`, and checks that a file of zeros is
refused. CI does not replace `verify`.

### Releasing

`zig build release` cross-compiles `m2snes` (ReleaseSafe, stripped) for the four
targets into `zig-out/release/<target>/`. The Linux binaries are static. The Windows
ones import only `ntdll` and `KERNEL32`, and the macOS one links only `libSystem`.
`release` scans each for host paths with `pathscan`. A build is reproducible: the same
commit gives the same bytes on any machine, from any checkout path.

To cut a release:

1. Set the version in `build.zig.zon`, on `dev`, and merge `dev` into `main` by PR.
2. Tag `main` with `vX.Y.Z` and push the tag. The pre-push hook runs `pin-check`.
3. The release workflow checks that the tag matches `build.zig.zon`, packages the
   binaries CI built and smoke-tested, writes `SHA256SUMS` and the notes, and creates a
   **draft** release.
4. `zig build release-verify -- vX.Y.Z` downloads the draft and checks it against
   `SHA256SUMS`. It rebuilds the binaries from the tag and compares them byte for byte,
   then runs the host's binary (and the Linux ones, under OrbStack) on the ROM against
   the pins. Add its summary line to the notes, then publish.

A broken release is fixed forward: bump the version and release again.

### Other commands

```sh
zig build rom [-- --debug]  # build the cart into build-out/, through the m2snes binary
zig build romtest           # generate the Mesen2 test for it, from the reference render
zig build extract           # assets out of your ROM, into extracted/
zig build coverage          # what we can read, and what is still missing
zig build ledger            # the logic inventory: every routine, and what we have done about it
zig build dispatch          # the table-driven dispatch survey
zig build audiocost         # what handleAudio costs per call on the Game Boy
zig build convert           # convert assets to SNES form, against the region layout
zig build inspect           # A/B images and contact sheets of the conversion
zig build roster            # the AI census, the Metroid roster and the warp destinations
zig build oracle            # grade the cart against the Game Boy, frame for frame
zig build audiocmp -- test/audio/surface-2s.req   # grade the sound engine against the Game Boy
zig build audioab -- song 04                      # render one song on both engines, to listen to
zig build engine            # reassemble engine/ after editing engine/main.asm
zig build spcengine         # reassemble engine/audio.bin after editing engine/audio/main.asm
tools/get-testroms.sh       # blargg's SM83 suites, for the emulator tests
tools/sameboy-frames.sh     # SameBoy reference frames, for grading the PPU (needs rgbds)
tools/get-bank4-sym.sh      # M2RoS's bank-4 symbols, for audiocost (needs rgbds)
tools/sync-shim.sh          # re-sync audio/shim/, the GB APU shim package
tools/get-spcrun.sh         # the offline SPC700 runner
```

The engine images are assembled at development time and committed, so building a cart
needs no assembler. [docs/engine-images.md](docs/engine-images.md) covers rebuilding
them.

### Contributing

Pull requests are welcome. Because the hooks are what keep ROM data out of this
repository, and a merge in GitHub's web UI bypasses them:

- An outside PR is never merged in the web UI. It is fetched locally and pushed to `dev`
  through the hooks, then merged into `main` from there.
- A Dependabot PR that touches only `.github/` may be merged in the web UI. CI fails one
  that touches anything else.
- GitHub's web file editor is not used on this repository.

Never commit a ROM, a cart, a save file, or bytes copied out of any of them.

## Status

**1.0, the complete game: built, graded, and accepted on hardware (2026-10-03).**
Title, landing site, all 47 Metroids, Arachnus, the Queen, the baby, the ending and the
credits are ported from the disassembly, branch for branch. Every enemy AI the ROM's
spawn records reach, every item and beam, all seven map banks, the save stations and
the soft reset are in. The sound engine is bank 4 on the SPC700 over the GB-APU shim,
graded write for write against the Game Boy.

The cycle closed when a retail-built cart was played from new game to credits on an
FXPak Pro, with every defect found there fixed or explicitly accepted.
[docs/feature_tracker.md](docs/feature_tracker.md) has the features and the defects
still open against them. [docs/history.md](docs/history.md) is the account of how the
port and its grading machinery were built.

## Sources

- **[M2RoS](https://github.com/metroidret/M2RoS)**, a hand-labelled Game Boy
  disassembly (MIT, Copyright (c) 2022 alex-west), is the behavioural spec. Facts about
  the ROM are still verified against the ROM itself, and every offset entry records how
  we know: a re-derivation can be checked against the cartridge, and a transcription
  cannot.
- **[Vashy777/metroid2](https://github.com/Vashy777/metroid2)**, an MIT-licensed
  `mgbdis` dump, is used for the routine inventory behind the logic ledger. `mgbdis` on
  your own ROM reproduces it.

Neither is vendored. [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES) lists what the binary
carries from others and what is used only during development.

## Legal

Nintendo DMCA'd AM2R, a Metroid II remake, in 2016. AM2R distributed assets. The
bring-your-own-ROM model distributes none, which is a stronger position, and the same
one M2RoS, sm64ex and the N64Recomp projects take. Metroid II is still among the
highest-risk properties in this space. This is an accepted, deliberate risk.

## License

MIT. See [LICENSE](LICENSE).
