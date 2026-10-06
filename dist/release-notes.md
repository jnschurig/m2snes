m2snes {{version}} builds a SNES ROM of *Metroid II: Return of Samus* from a dump of your
own Game Boy cartridge. It contains no game data. The
[README](https://github.com/jnschurig/m2snes#playing) says which archive to download,
which ROM you need, and how to run it.

## The carts

`m2snes` prints the SHA-1 of the cart it wrote. From the right ROM, this release makes:

| Cart | Command | SHA-1 |
|---|---|---|
| retail | `m2snes metroid2.gb` | `{{retail}}` |
| debug | `m2snes --debug metroid2.gb` | `{{debug}}` |

{{history}}

Built from commit `{{commit}}`. Check a download against `SHA256SUMS`.

## Verified

{{verified}}

---

*Metroid*, *Metroid II: Return of Samus*, Nintendo, Game Boy and Super Nintendo
Entertainment System are trademarks of Nintendo. This project is not affiliated with,
endorsed by, or sponsored by Nintendo. It contains no Nintendo code, graphics, sound or
other copyrighted material; the builder works only from a ROM you dump from your own
cartridge. All other trademarks and copyrights belong to their respective owners.
