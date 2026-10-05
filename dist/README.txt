m2snes: Metroid II: Super Return of Samus
=========================================

m2snes builds a SNES ROM of Metroid II: Return of Samus from a dump of your own
Game Boy cartridge. It contains no game data; everything comes from your ROM.

Your ROM must be this exact revision:

    Metroid II - Return of Samus (World), Game Boy, 256 KiB (262,144 bytes)
    sha1 74a2fad86b9a4c013149b1e214bc4600efb1066d

Build
-----

    ./m2snes metroid2.gb             (Windows: m2snes.exe metroid2.gb)

It takes about half a minute and writes m2snes.sfc beside your ROM (-o chooses
another path). It then prints the SHA-1 of the ROM it wrote. Compare it with the
"retail" SHA-1 in the release notes of this version (m2snes --version prints
the version). If they match, you have exactly the cart this release was tested
as.

    ./m2snes --debug metroid2.gb

builds m2snes-debug.sfc, with a debug menu (L+R+Start in play) for testing.
Its SHA-1 is the notes' "debug" line.

macOS: the binary is not signed. If macOS blocks it, run this once:

    xattr -d com.apple.quarantine m2snes

If it refuses your ROM, it says why and writes nothing: a copier header, a
trimmed or overdumped file, another game, a corrupt or modified ROM, a colour
hack, or another revision. Dump your cartridge again, unmodified.

    ./m2snes --help                  all options

Source, issues and the full README: https://github.com/jnschurig/m2snes

License: MIT (LICENSE). Third-party notices: THIRD-PARTY-NOTICES.

Metroid, Metroid II: Return of Samus, Nintendo, Game Boy and Super Nintendo
Entertainment System are trademarks of Nintendo. This project is not affiliated
with, endorsed by, or sponsored by Nintendo. It contains no Nintendo code,
graphics, sound or other copyrighted material; the builder works only from a
ROM you dump from your own cartridge. All other trademarks and copyrights
belong to their respective owners.
