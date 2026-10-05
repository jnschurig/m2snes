---
name: verify-gate
description: Run m2snes's verification ladder — unit tests, the tracked-file policy, the ROM gate (`verify`), the slow tier (`verify-full`) and the cart pins. Use before committing or opening a PR, when asked to "run the gate", "check everything still passes", re-pin the carts, or read a red `cart pin`.
---

# Verification ladder

From the repo root, under mise's environment (`eval "$(mise env)"`, so `M2_ROM` and
`MESEN` are set). Each rung costs more than the last, so stop at the first failure.
Never run two gates at once: Mesen runs have wall-clock timeouts, and two runs that
write the same output file interleave.

| Rung | Command | Time (warm) | When |
|---|---|---|---|
| Unit tests | `zig build test` | ~6 min | Every change. Without `M2_ROM` it skips the ROM tests (CI runs it this way). |
| Policy | `zig build policy` | seconds | Every change. Size ceiling, forbidden paths, and ROM n-grams when `M2_ROM` is set. `-- --staged` is what pre-commit runs. |
| Pre-push tier | `zig build test-rom cart-pin` | ~6 min | Every push (the hook runs it). `test-rom` fails rather than skips without the ROM. |
| The gate | `zig build verify` | ~14 min | Before opening a PR, and after any engine, converter or crawl change. Too slow for the hook. |
| Slow tier | `zig build verify-full` | ~18 min | Before a release, and after a crawl, warp or recording change. It runs the gate first. |
| Player's path | `zig build pin-check` | ~1 min | Both carts from the `m2snes` binary with no crawl cache, against `pins/cart.txt`. `-Dtarget=aarch64-macos` grades the stripped release binary. The pre-push hook runs it on a `v*` tag. |

`verify` prints one `ok`/`FAIL`/`not run:` line per rung. `docs/conformance.md`
lists every rung, what it is graded against, and the fault that shows it is not
vacuous. A `not run:` for a rung you meant to run (no ROM, no Mesen) is a failure
to report, not a pass.

## The cart pins

`pins/cart.txt` holds the SHA-1s of the retail cart, the debug cart and the crawl
file. `verify`'s `cart pin` and `pin (binary)` rungs, `cart-pin`, `pin-check` and
`release-verify` all grade against it.

A red `cart pin` names each output that moved (retail, debug or crawl), with the pinned
and the new SHA-1 and the command to re-pin:

```
FAIL  cart pin          the output moved; if that was meant, zig build repin -- "<why>"
        retail pinned 3452e39…, now <sha1> (build-out/m2snes.sfc)
```

A moved `crawl` alone means the crawler's output changed, and the carts may follow.
`cart pin` reads the carts already in `build-out/`. The gate rebuilds them first;
outside the gate, `zig build cart-pin` runs the binary itself.

- **If you didn't mean to change the output**, it's a regression. Find what moved
  it. Don't re-pin.
- **If you did** (an engine, converter, shim or `crawl_version` change, or a new
  feature), run `zig build repin -- "<why>"`. It rebuilds both carts, rewrites
  `pins/cart.txt`, and appends old → new and the reason to `pins/history.md`. It
  refuses an empty reason and does nothing when the hashes are unchanged. Commit the
  pin with the change that moved it.
- Never hand-edit `pins/cart.txt`. `zig build test` checks it against the last line of
  `pins/history.md` and goes red on a mismatch.
- **A stale crawl cache passes silently.** `build-out/crawl-<rom>-v<n>.txt` is keyed
  only on the ROM and `crawl_version`. After changing the crawler, bump
  `crawl_version` or delete the cache before trusting a crawl-derived pin.
  `verify-full`'s `crawl cold` rung catches a stale cache.

## Hardware

Real hardware is a manual check, on request: build with `zig build rom`, then deploy
with the `fxpak` skill.
