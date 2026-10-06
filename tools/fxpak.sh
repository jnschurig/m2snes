#!/usr/bin/env bash
# FXPak Pro USB deploy via SNI (https://github.com/alttpo/sni).
# Requires: sni (found through SNI_BIN, else on PATH; mise.toml resolves SNI_BIN),
# grpcurl and python3.
#
# Usage:
#   tools/fxpak.sh status              # is SNI up, is the console attached?
#   tools/fxpak.sh ls [sd-path]        # list SD card directory (default /)
#   tools/fxpak.sh put [rom] [sd-path] # upload ROM (default build-out/m2snes.sfc -> /dev/<name>)
#   tools/fxpak.sh boot <sd-path>      # boot a ROM already on the card
#   tools/fxpak.sh deploy [rom]        # put + boot in one shot
#   tools/fxpak.sh menu                # reset back to FXPak menu
#   tools/fxpak.sh reset               # reset currently running game
#   tools/fxpak.sh read <addr> [len]   # read memory while the game runs, as hex
#   tools/fxpak.sh write <addr> <hex>  # write bytes, e.g. `write 700000 0000`
#
# `read` takes a 24-bit SNES address -- $7E0000-$7FFFFF is WRAM -- and prints
# the bytes as hex. It is how a running cart is measured without a screenshot:
# a debug readout has to be drawn, read and believed, where this is the bytes.
# The cart must publish what is wanted as a matched set, because these are
# separate reads of a machine that does not stop between them.
set -euo pipefail

SNI_BIN="${SNI_BIN:-$(command -v sni || true)}"
SNI_ADDR="${SNI_ADDR:-localhost:8191}"
SD_DIR="${FXPAK_DIR:-/dev}"

# The request goes in on stdin, never as an argument: a PutFile body carries the ROM
# base64-encoded, and Linux caps a single execve argument at 128 KB (MAX_ARG_STRLEN),
# which a 256 KB ROM clears three times over. Passing it to this shell function is fine
# -- that is not an execve -- so only the grpcurl call has to change.
rpc() { grpcurl -plaintext -d @ "$SNI_ADDR" "$2" <<<"$1"; }

ensure_sni() {
  if ! grpcurl -plaintext "$SNI_ADDR" list >/dev/null 2>&1; then
    if [[ -z "$SNI_BIN" || ! -x "$SNI_BIN" ]]; then
      echo "error: SNI is not running and no sni binary was found. Put sni on PATH or set SNI_BIN." >&2
      exit 1
    fi
    echo "starting sni..." >&2
    nohup "$SNI_BIN" >/dev/null 2>&1 &
    for _ in $(seq 1 20); do
      grpcurl -plaintext "$SNI_ADDR" list >/dev/null 2>&1 && break
      sleep 0.25
    done
  fi
}

device_uri() {
  local uri
  uri=$(rpc '{}' Devices/ListDevices | python3 -c '
import json,sys
devs = json.load(sys.stdin).get("devices", [])
fx = [d for d in devs if d["uri"].startswith("fxpakpro:")]
print((fx or devs)[0]["uri"] if devs else "")')
  if [[ -z "$uri" ]]; then
    echo "error: no device found. Is the FXPak Pro connected via USB and the console powered on?" >&2
    exit 1
  fi
  echo "$uri"
}

# SNI's FxPakPro space puts WRAM at $F50000 and cartridge RAM at $E00000; a
# $7Exxxx/$7Fxxxx or LoROM $700000-$707FFF address is translated here rather than
# asking the caller to know that.
fxpak_addr() {
  python3 -c '
import sys
a = int(sys.argv[1].lstrip("$").replace("0x", ""), 16)
if 0x7E0000 <= a <= 0x7FFFFF:
    a = 0xF50000 + (a - 0x7E0000)
elif 0x700000 <= a <= 0x707FFF:
    a = 0xE00000 + (a - 0x700000)
print(a)' "$1"
}

json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

cmd="${1:-status}"
shift || true
case "$cmd" in
status)
  ensure_sni
  rpc '{}' Devices/ListDevices
  ;;
ls)
  ensure_sni
  uri=$(device_uri)
  rpc "{\"uri\":$(json_str "$uri"),\"path\":$(json_str "${1:-/}")}" DeviceFilesystem/ReadDirectory
  ;;
put | deploy)
  rom="${1:-build-out/m2snes.sfc}"
  [[ -f "$rom" ]] || {
    echo "error: $rom not found (did you run 'zig build rom'?)" >&2
    exit 1
  }
  dest="${2:-$SD_DIR/$(basename "$rom")}"
  ensure_sni
  uri=$(device_uri)
  rpc "{\"uri\":$(json_str "$uri"),\"path\":$(json_str "$SD_DIR")}" DeviceFilesystem/MakeDirectory >/dev/null 2>&1 || true
  data=$(base64 -i "$rom" | tr -d '\n')
  rpc "{\"uri\":$(json_str "$uri"),\"path\":$(json_str "$dest"),\"data\":\"$data\"}" DeviceFilesystem/PutFile >/dev/null
  echo "uploaded $rom -> $dest"
  if [[ "$cmd" == "deploy" ]]; then
    rpc "{\"uri\":$(json_str "$uri"),\"path\":$(json_str "$dest")}" DeviceFilesystem/BootFile >/dev/null
    echo "booted $dest"
  fi
  ;;
boot)
  dest="${1:?usage: fxpak.sh boot <sd-path>}"
  ensure_sni
  uri=$(device_uri)
  rpc "{\"uri\":$(json_str "$uri"),\"path\":$(json_str "$dest")}" DeviceFilesystem/BootFile >/dev/null
  echo "booted $dest"
  ;;
menu)
  ensure_sni
  uri=$(device_uri)
  rpc "{\"uri\":$(json_str "$uri")}" DeviceControl/ResetToMenu >/dev/null
  echo "reset to menu"
  ;;
reset)
  ensure_sni
  uri=$(device_uri)
  rpc "{\"uri\":$(json_str "$uri")}" DeviceControl/ResetSystem >/dev/null
  echo "reset"
  ;;
read)
  ensure_sni
  uri=$(device_uri)
  addr=${1:?usage: fxpak.sh read <addr> [len]}
  len=${2:-1}
  req=$(fxpak_addr "$addr")
  rpc "{\"uri\":$(json_str "$uri"),\"request\":{\"requestAddress\":$req,\"requestAddressSpace\":\"FxPakPro\",\"size\":$len}}" \
    DeviceMemory/SingleRead |
    python3 -c '
import base64, json, sys
d = json.load(sys.stdin)
raw = d.get("response", {}).get("data", "")
print(" ".join(f"{b:02X}" for b in base64.b64decode(raw)))'
  ;;
write)
  ensure_sni
  uri=$(device_uri)
  addr=${1:?usage: fxpak.sh write <addr> <hex>}
  hex=${2:?usage: fxpak.sh write <addr> <hex>}
  req=$(fxpak_addr "$addr")
  data=$(python3 -c 'import base64, sys; print(base64.b64encode(bytes.fromhex(sys.argv[1])).decode())' "$hex")
  rpc "{\"uri\":$(json_str "$uri"),\"request\":{\"requestAddress\":$req,\"requestAddressSpace\":\"FxPakPro\",\"data\":\"$data\"}}" \
    DeviceMemory/SingleWrite >/dev/null
  echo "wrote $hex at $addr"
  ;;
*)
  echo "unknown command: $cmd" >&2
  sed -n '6,15p' "$0" >&2
  exit 1
  ;;
esac
