# Rebuilding the engine images

The cart's code is two assembled images, both committed:

| Source | Image | Symbols | Assembler |
|---|---|---|---|
| `engine/main.asm` (65816) | `engine/engine.bin` | `engine/engine.sym` (WLA) | asar 1.91 |
| `engine/audio/main.asm` (SPC700) | `engine/audio.bin` | `engine/audio.mlb` (Mesen) | spc700asm, from Terrific Audio Driver v0.4.2 |

The `m2snes` binary embeds them and patches the converted assets in, so building a cart
needs no assembler. An assembler is needed only after editing an `.asm` file.

## Getting the assemblers

Both are fetched at a pinned version and built into the ignored `vendor/`:

```sh
tools/get-asar.sh         # needs cmake and a C++ compiler
tools/get-spc700asm.sh    # needs a Rust toolchain (cargo)
```

## Reassembling

```sh
zig build engine          # engine/main.asm -> engine.bin + engine.sym
zig build spcengine       # engine/audio/main.asm -> audio.bin + audio.mlb
```

`spcengine` first runs `zig build aramsyms`, which regenerates
`engine/audio/aram_data.inc`: the ARAM addresses of bank 4's data, decided by
`src/aram_layout.zig`. The sound engine assembles against that file and against
`audio/shim/shim_abi.inc`, the ABI of the synced audio shim (`tools/sync-shim.sh`).

Commit each source together with its image and symbol file. A change to either image
changes the cart, so it usually needs `zig build repin -- "<why>"` too.

## How `verify` checks them

`zig build verify` checks that the committed images are what their sources assemble to.
When an assembler is present, it reassembles each source into a scratch file
under `.zig-cache/` and compares the result with the committed image and symbol
file byte for byte:

```
      engine source     engine.bin and engine.sym are what engine/main.asm assembles to
      audio engine      audio.bin and audio.mlb are what engine/audio/main.asm assembles to
```

A mismatch is a `FAIL` that names the stale file and the step that regenerates it. When
an assembler is absent, the line says `not rechecked: no assembler` and names the fetch
script, rather than passing. `verify` also checks that `aram_data.inc` is what the
layout plans, that the 65816 image fits the space `src/snes_layout.zig` reserves for
it, and that the ARAM image fits the shim's regions.
