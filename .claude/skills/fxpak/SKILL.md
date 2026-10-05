---
name: fxpak
description: Deploy the m2snes cart to the FXPak Pro console over USB via SNI. Use when the user asks to run/test the cart on real hardware, the console, or the FXPak, to transfer/upload an .sfc file to the cart, or to read/write a running cart's memory.
---

# FXPak Pro deploy

All console I/O goes through `tools/fxpak.sh`, which talks to SNI (gRPC on
localhost:8191) and starts it if needed. SNI comes from `SNI_BIN` (resolved by
`mise.toml`) or `PATH`; it is built from https://github.com/alttpo/sni. The
script also needs `grpcurl` and `python3`. Run it under mise's environment
(`eval "$(mise env)"` first, or `mise exec -- tools/fxpak.sh …`).

## Workflow

1. Build the cart if the change isn't in it yet:
   `zig build rom` → `build-out/m2snes.sfc`, or
   `zig build rom -- --debug` → `build-out/m2snes-debug.sfc` (the debug menu:
   L+R+Start in play). Each command writes only its own cart, so a stale
   debug cart stays stale until you rebuild it.
2. Check the console is reachable: `tools/fxpak.sh status` must list an
   `fxpakpro://...` device. `{}` means none: ask the user to connect the FXPak
   Pro by USB and power on the console (at the FXPak menu or in a game).
3. Deploy and boot in one shot:
   `tools/fxpak.sh deploy` (the retail cart), or
   `tools/fxpak.sh deploy build-out/m2snes-debug.sfc`.
   It uploads to `/dev/<name>.sfc` on the SD card, then boots it.

## Other commands

- `tools/fxpak.sh ls [sd-path]`: list SD card contents
- `tools/fxpak.sh put [rom] [sd-path]`: upload without booting
- `tools/fxpak.sh boot <sd-path>`: boot a file already on the card
- `tools/fxpak.sh menu`: back to the FXPak menu; `reset`: reset the current game
- `tools/fxpak.sh read <addr> [len]` / `write <addr> <hex>`: a running cart's
  WRAM ($7E0000-$7FFFFF) or SRAM ($700000-$707FFF), as hex. Separate reads of
  a running machine are not a matched set: have the cart latch what is read
  together.
- Env overrides: `FXPAK_DIR` (SD dest dir, default `/dev`), `SNI_BIN`, `SNI_ADDR`

## Troubleshooting

- No device listed: on macOS check `ls /dev/cu.usbmodem*`. If it's absent, the
  cart isn't enumerating at all. The usual cause is a charge-only micro-USB
  cable; otherwise the console is off.
- Linux: the device lists but SNI can't open it ("Permission denied"). Install
  `tools/70-fxpak.rules` (instructions in the file).
- SNI misbehaving: `pkill sni` and rerun any command (the script restarts it).

## Notes

- Before asking the user to check something on hardware, name the visible
  symptom a defect would cause, and confirm it would actually be on screen.
- Save data (`.srm`) on the cart is disposable during development.
