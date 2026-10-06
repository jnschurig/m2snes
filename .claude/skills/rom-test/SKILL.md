---
name: rom-test
description: Build the m2snes cart and run its Mesen2 boot tests headlessly. Use whenever a change could affect the cart (engine/, src/, build.zig) and a quick check short of the full gate is wanted, or the user asks to build/run/boot the cart in an emulator.
---

# Build the cart + headless Mesen2 boot tests

Run under mise's environment so `M2_ROM` and `MESEN` are set:

```sh
eval "$(mise env)"
zig build rom                 # build-out/m2snes.sfc (+ .sym, preview PNGs), through the m2snes binary
zig build rom -- --debug      # build-out/m2snes-debug.sfc; each command writes only its own cart
zig build romtest             # build-out/m2snes*.lua + m2snes-graded.sfc, from the reference render (~50 s)

# snes boot: the graded cart (NOT m2snes.sfc) with m2snes.lua
"$MESEN" build-out/m2snes-graded.sfc --testrunner build-out/m2snes.lua \
  --timeout=90 --snes.disableFrameSkipping=true
# cold boot: the shipped cart, played from power-on
"$MESEN" build-out/m2snes.sfc --testrunner build-out/m2snes-cold.lua \
  --timeout=90 --snes.disableFrameSkipping=true
```

Exit 0 = pass. Each generated script lists its exit codes in its header. No window
opens. `zig build verify` runs all of these scripts and more (see `verify-gate`).
Use this skill for a quick look, not as the gate.

## Traps

- **Unset `M2_ROM` skips silently.** `zig build test` from a plain shell reports green
  with the ROM tests skipped. Always `eval "$(mise env)"` first. `zig build test-rom`
  fails instead of skipping.
- **`romtest` does not reassemble the engine.** After editing `engine/main.asm`, run
  `zig build engine` (or `spcengine` for `engine/audio/`) first.
- **Pair each script with its cart.** `m2snes.lua` grades `m2snes-graded.sfc`, which
  boots on a record `chooseBoot` picks. `m2snes-cold.lua`, `-load`, `-death` and
  `-title` grade the shipped `m2snes.sfc`. The scenario, warp and pause-debug scripts
  need `m2snes-debug.sfc`, which goes stale unless you rebuild it with `-- --debug`. A
  wrong pairing fails (`m2snes.lua` on `m2snes.sfc` exits 3), or worse, passes on a
  stale cart.
- **Framebuffer reads need `--snes.disableFrameSkipping=true`.** Run flat out, Mesen
  skips drawing frames within 10 ms of the last one, and `emu.getScreenBuffer()` hands
  back a stale picture.
- **Zero SRAM first.** Mesen keeps cart RAM per ROM file name (`.srm` in its Saves
  directory), and a fresh one powers on with noise. Generated new-game scripts zero it
  in their main chunk (`snes_romtest.writeSramPrelude`). Any new script that boots the
  title must do the same.
- **Exit 255 after the full timeout** means a Lua error, not a cart failure: a syntax
  error, a 201st top-level `local` in `m2snes.lua` (check with `luac -p`), `io` or
  `os.getenv` (both absent in the testrunner), or two Mesens sharing a cart/script name.
- **`emu.stop(code)` does not return.** Later checks in the same callback still run.
  Keep the first failure behind a flag.
- `emu.log` is swallowed in testrunner mode. The exit code is the signal, and `print`
  reaches stdout. `emu.getScreenBuffer()` is 256x239.
- Always try a new assertion against a negative control, because a broken script can
  exit 0.
- Real hardware is the accuracy check: deploy with the `fxpak` skill.
