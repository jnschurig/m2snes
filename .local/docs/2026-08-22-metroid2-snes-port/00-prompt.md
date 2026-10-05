Relevant docs:
- ./2026-08-06-metroid2-snes-port-feasibility.md and
- ./2026-08-06-gb-apu-spc700-shim.md

Final delivery:

- Any original asm/converted asm
- Asset diffs/changes against original
- Tooling required to generate the snes rom using the gb rom as input.

Primary goal: rewrite metroid 2 for snes.

The shape of the deliverable: In its own repository, ship raw assembly and an executable
which will take a normal Metroid 2 gameboy rom provided by the user and generate a
Metroid 2 snes rom.

This repository will not contain any copyrighted assets and should be safe to share.
Instead, any modifications that need to be made to copyrighted assets (such as music
/sound/art) should be stored as diffs against original assets or should be made new
so that they won't cause any legal trouble.

Secondary goal: Make this easy to integrate for romhacks.

There is an existing project which combines several different games for a randomizer.
This is called smz3 and more recently as been termed "quad rando" and includes zelda 1,
zelda 3, metroid 1, and metroid 3. This project aims to provide a usable version of
metroid 2 which can be integrated in that rando project.

Tertiary goal: Quality of Life improvements

I would like to add some quality of life improvements over the existing metroid 2.

1. Stackable beams. Instead of trading the existing beam for ice beam and vice versa,
collecting ice beam should add the freeze functionality to the existing beam.
2. Togglable upgrades. A menu should be introduced which allows toggling collected
upgrades on/off, similar to metroid 3 (super metroid)
3. Color. Instead of gb mono, I'd like to include a colorized tileset. The existing
art design should be kept consistent, but we should add color where reasonable.

The new colors should resemble the colors from the 3DS version of Samus Returns.
Obviously there will be some adaptation and simplification. We don't want to change
design or which pixels go where, just change what color they are. Where possible we
will pick colors that relate to colors of the same areas in the newer game.

Stretch goals: 

- PC target

If simple enough, provide enough packaging/code/import to enable the game to be played
as a pc game using zasm.

- msu1 mapping:

Provide msu1 mapping to support msu1 music overrides for the game.


Significant things to note:

- We don't HAVE to ship zig necessarily.
- the pc target is optional.
- The rewritten game doesn't have to be represented as zig code. It could be converted asm
and zig could merely orchestrate or implement changes.


This work would be handled in phases. Each phase delivers a fully functional game. The
first phase is all about the mvp.

