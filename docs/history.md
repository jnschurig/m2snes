# How the port got here

This is the account the README carried while the port was built, starting in
Phase 0a, the go/no-go: convert and verify the entire asset base, prove the
builder runs end to end, and get Samus moving in a booting ROM. It is kept as
the record of how the machinery came to be. Its numbers are those of the time
(the cart is now 1 MiB, for example).

What exists today is the asset base and the machinery that proves it: ROM
ingest, a 123-entry offsets table where every entry records how we know, and
extraction for graphics, tilesets, maps, door scripts, enemy tables and
metasprites. 121 of those 123 entries decode into a typed form and re-encode to
the source bytes exactly; `zig build coverage` names the two that do not, and
the classes no reader covers yet.

Alongside it there is now a Game Boy emulator — SM83 core, MBC1, timer, LCD
timing and APU register capture — which passes blargg's `cpu_instrs` (all
eleven groups and the combined MBC1 build) and `instr_timing`, and runs the
retail ROM reproducibly frame by frame. It exists to be an oracle: reference
frames in Step 7, render comparison in Step 9, the TAS trace in Step 14, and
the audio capture in Step 17.

The SNES side now goes end to end. The converted asset set is measured against a
fixed region manifest, rendered back and compared with the Game Boy pixel for
pixel across all 904 in-use screens, and injected into a pre-assembled 65816
engine image to produce a 512 KiB LoROM cart. The engine is our own original
code; it is assembled at dev time with `asar` and committed, so building a ROM
needs nothing but the Zig binary and your cartridge dump. It boots into Mode 1
with the play field on BG3, masks a 160x144 window out of the 256x224 frame,
replays a converted door script into VRAM, draws a converted screen, and
scrolls a camera across the map. A screen boundary is not an event: a position
is a `(screen, pixel)` pair the way the original stores it, so crossing one is
the pixel byte wrapping and the screen nibble taking the carry, and the tilemap
keeps up because one metatile row or column streams into it per frame. The
`SCRN/2` clamps apply only where a cell's scroll byte blocks the edge — which in
the original is where a door transition starts, so for now the camera stops
there.

Samus moves. She has poses, not a state machine of our own devising: standing,
running, the turnaround, the crouch, the jump start, the jump, the spin jump
and the fall, each one the original's routine written out in 65816. She walks
at the ROM's own speed — one pixel a frame in water, otherwise alternating two
and one — jumps two pixels a frame while the counter climbs and then along the
converted arc a speed at a time, falls along the fall arc, and collides against
the tileset's own solidity thresholds, compared the way the Game Boy compares
them: against an 8x8 tile id read straight back out of the tilemap the streamer
already maintains. The camera follows her through the original's guide offsets
rather than being driven by the d-pad. And she is drawn. Her sheet goes to the object half of VRAM at boot,
because the original loads it outside every door script; her metasprites ship in
the Game Boy's own shape, four bytes a part and `$FF` at the end, with only the
pointer table converted from bank-1 addresses into offsets. Which sprite she is
comes from the original's own dispatch: a pose picks a routine, and the routine
picks an id out of one of four little tables in the ROM or out of an immediate.
The turnaround draws her facing the camera, which is not a special case — it is
what `drawSamus` does with a pose that has bit 7 set. A Game Boy OAM record
becomes a SNES one at the moment it reaches the shadow buffer: the two origin
biases come off, the window offsets go on, the flips move a bit left, and the
ninth x bit goes into the high table. There is no clipping code, because a net
`+40` horizontally and `+24` vertically puts the Game Boy's visible area exactly
inside the window the PPU is already masking to.

The gate does not take that on trust. `zig build romtest` bakes the reference
render of the boot screen into a Mesen2 script, and `zig build verify` runs the
finished cart headlessly and compares its framebuffer against it pixel for
pixel across the whole play window — cut, at the camera position the engine
itself reports, out of a baked render of the whole 256x256 screen, because
where the camera comes to rest is now a consequence of the arcs and the
collision data rather than a constant this side can predict. Then it plays the
cart: it waits for Samus to fall onto the floor, holds jump to the top and
requires the converted arc to have lifted her higher than the linear part of
the ascent did on its own, watches her land on the row she left, walks her into
the edge the screen blocks, and walks her through the opening until the camera
has carried into the neighbour — whose picture is then compared against a
render of that screen alone, so it has to have been assembled a column at a
time. It masks the pixels she covers out of the
comparison — the mask is taken from where OAM actually puts her, per 8x8 part
and bounded above, so it cannot quietly grow until nothing is being compared —
and separately asserts that she was composed at all, that her anchor is the
camera guide with the Game Boy biases exchanged for the window's, that the walk
produced the number of parts the cart's own data says the id has, and that the
sprite changes with the pose and with the way she faces. Faults injected into
the collision test, the jump arc, the fall arc, the scroll registers, the
metasprite walk, the bias arithmetic and the pose dispatch are each caught, by a
different code. Without an emulator
present the gate says so rather than passing quietly.

There is now a ledger of what is left. `zig build ledger` disassembles the six
code banks from the reset and interrupt vectors, follows every `CALL` to a
fixpoint, and then — because that alone reaches barely a tenth of the game —
watches the game run and takes every program counter it executes. Metroid II
keeps its structure in `JP HL` through tables of code pointers, which no static
tool can follow, so the run is not a supplement to the disassembly; it is most
of the evidence. The pose machine is a `RST $28` thunk that pops its return
address, indexes the table lying inline after the call site, and jumps, and the
only way to learn where those entries go is to watch one arrive. What comes out
is 262 routines and 11,818 instructions, against the ~20,000 lines of SM83 logic
the plan budgets for, each row carrying how it was found, whether it has been
converted, whether anything tests it, and which phase it belongs to.

## What is table-driven, and how much of it that is

`zig build dispatch` answers F4's survey question — how much of the rewrite
reduces to "port the dispatcher, transfer the table" — out of the same run. The
ledger records *where* an indirect jump landed; the survey records *which*
indirect jump sent it there, which is a different question and needs one more
fact per edge.

That distinction is the whole difficulty. `RST $28` is a thunk that pops its own
return address for the table base, so every inline dispatch in the game passes
through a single `JP HL` — group by that and you get one site with nineteen arms
and the pose machine, the sprite dispatch and the sound driver merged into it.
Attributing each edge to the `RST $28` that called the thunk separates them.

A table is then found in the bytes rather than in a listing: search the site's
bank for a run of little-endian in-bank pointers, at a fixed stride, that names
*every* arm the run reached. Two arms minimum — one arm's bytes appear all over a
16 KiB bank, and matching them is a coincidence. Where the code happens to load
its base explicitly the two derivations can be compared, and at 4:$448E the
search reaches $4EC4 from the arms while the instruction three earlier reads
`LD HL,$4EC4`.

Seven sites, six with a table, 223 entries. **7,248 of the ledger's 14,782
instructions are reachable from a table entry: 49%.** Counting only the arms the
run actually took gives 13% — the run entered 9 of the pose machine's 31 — so
reading the tables rather than the trace is worth a factor of four, and both
numbers are printed.

The interesting part is what falls out of that. Bank 4's sites share an indexer,
`CALL $46DE`, and nothing knew that helper existed until a run reached one of
them. Once it has, the bytes `21 lo hi / CD DE 46 / E9` name every other site
that uses it — **five more, with their table addresses, that no schedule this
repository runs has ever entered.** Execution coverage bootstrapping a static
search, which is not something either half could have done alone.

And the survey says what it cannot see. Four layers are listed with the evidence
that they exist and the reason no run reached them: enemy AI (nothing spawns an
enemy), the menus (no run opens one), the boss sequencing, and the door script
interpreter — which is table-driven, is F4's own first criterion, and contributes
**zero** sites here because it switches on an opcode byte instead of jumping
through pointers. The largest table-driven layer in the game is invisible to this
method, correctly.

Underneath it is a harness that will call any routine of your cartridge on a
booted machine, set up its state first and read its registers and memory
afterwards. `src/routines.zig` is what that is for: the tilemap address
arithmetic checked against a re-derivation for every position on screen,
including the column addition that wraps the low byte without carrying into the
high one, and the standing check exercised through all four combinations of the
two tiles it samples. That last one is a routine the SNES gate cannot reach at
all, because it is only entered from the crouch and our crouch is still a stub.
And a room harness that puts Samus in any room of any map bank at any pixel, by
handing the `WARP` handler two bytes of our own rather than going through the
door table — with a test that the position it produces is the same 16-bit world
coordinate the SNES boot record carries, which is what the frame-for-frame
oracle will need at frame 0.

## The oracle

`zig build oracle` grades the cart against the original, frame for frame. It
picks a screen and a starting pixel by trying them, spawns Samus there on the
Game Boy, lets her come to rest, and records three hundred and twenty frames of
a hand-authored segment — fall, land, walk, jump, walk back. Then it builds a
cart whose boot record starts her at exactly that pixel, bakes the recording
into a Mesen2 script, and runs it, sampling at the top of `MainLoop` because
that is where a frame's logic is finished. Position is compared absolutely; the
camera is compared against its own frame zero, because the original's camera is
placed by the door transition it arrived through and our cart has no transition.

It found three things the first time it ran. The boot schedule every test in
this repository uses leaves Metroid II *paused* — Start is the pause button too.
The room harness wrote one of the original's two copies of Samus's position, so
she could walk but not fall, and a jump ran its pose sequence without moving her
a pixel. And, with both fixed, the cart matches the original exactly for sixty
frames — a thirty-four pixel fall, a landing, a settled camera — and then does
not move when right is pressed.

## The trace, and what it said about that

One byte of exit code can say *when* two machines disagreed. It can never say
why. `zig build trace` opens the wider channel the sandbox does have: it
re-stamps a copy of the cart's header with a battery and 32 KiB of save RAM, the
script writes one record per frame into it, and Mesen writes the file out when
the machine powers off. Same sampling point, so a row is the instant the oracle
compares — but now with the input the engine saw, the pose it dispatched on, the
position it reverted to, the coordinates the collision probed, and the whole 32x32
tilemap it was walking through.

That last one settled the sixty-frame divergence, and the answer was not the
port. The cart's world is its boot cell expanded through the metatile table the
boot record names, in **all 1024 tiles** — the engine, the injector and the
conversion are exact. The Game Boy's background map at the same instant matches
no table for that cell, and kept two thirds of its tiles across the warp. The
room harness moves Samus and the camera without loading the room, so the
reference has been walking through the game's opening area while the cart walks
through a Ruins exterior screen. Samus refusing to step is correct behaviour for
the world the cart was given.

So the oracle now checks that both machines are standing in the same room before
it believes a verdict, and says *that* instead of blaming the physics.

## Loading a room, as opposed to arriving in one

Fixing it took two facts about the original, both from its own code.

A `WARP` is not a room load. What loads a room is the **door script** the warp is
the last opcode of: the `copy` and `load` ops fill VRAM, `tiletable` selects the
metatile table the screen bodies are expanded through, and `collision` and
`solidity` select the tables the physics reads. Called on its own, the handler
inherits whatever the previous room left — so `room.spawn` now runs the door
script first, through the interpreter at `0:$239C` that `probe` found, and
`snes_screen.Boot` already carries the door `screens.assign` paired with the
cell, which is the same script the cart replays.

And the handler draws **three columns of thirty-two**. `0:$07E4` queues one
metatile column, two tiles wide; the other twenty-nine are left to the
scroll-edge routines, which draw a column each time the camera crosses a
metatile boundary. A spawn crosses nothing, so `room.drawRoom` walks the camera
across the screen and calls the game's own column draw sixteen times — remapping
the map bank before each one, because the frame wait in between runs the sound
driver, which maps bank 4 and does not put it back.

An earlier draft of this said "a door in Metroid II is a scroll rather than a
cut", which is wrong and James said so from having played it: **95 of the 497
decodable door scripts carry a `fadeout`**, 87 of them beside a warp, so about a
fifth of the game's transitions do cut to black. It makes no difference to the
handler, which draws its three columns either way — a fade hides the rest
arriving, it does not draw it — but the claim as written was more than the ROM
supports.

The measurement: the background map immediately after a spawn is now the
requested cell in **all 1024 tiles**, and a test asserts both halves of that — with
a door, all 1024; without one, fewer.

## What "the same room" can honestly mean

The first version of the check demanded all 1024 tiles at the segment's frame 0,
and that is not a thing the original ever does. Its background map is a *moving
window*: 32x32 tiles is exactly one screen, but it is world-aligned rather than
screen-aligned, and the game keeps the 256x256 window around the camera correct
by drawing the columns and rows that scroll into it. Once the camera is anywhere
but a screen's origin the map holds pieces of two screens, both of them right.

So the precondition is the overlap — the map slots that are on screen *and*
inside the cart's boot cell. `oracle.windowMask` computes them from SCX/SCY and
Samus's world position, with no camera variable involved, because $FFCC-$FFCF
look like a camera and are not: `0:$0700` and its siblings write them from
Samus's position with a different offset per scroll direction, so they hold
wherever the last edge redraw was aimed. Reading them as a camera put the
comparison an entire screen row out.

The last piece was in `chooseStart`: a candidate start is now rejected outright
if Samus ever leaves her cell during the probe. She was being dropped into a
wall, ejected sixty-six pixels left across the boundary, and the cart was then
built for the cell she ended in while the reference's picture was the cell she
started in.

With all three, `trace` reports `0 of 32 rows differ` between the Game Boy's map
and the cart's `!TilemapBuf`, and the gate's oracle rung has stopped reporting a
setup artifact and started reporting the port: `FAIL oracle, Samus's position
diverged, at frame 60-63 of 320` — the first frame the segment presses right, with
both machines in map 0 cell $38 and the cart's horizontal collision refusing the
step.

The trace answers one more question the same way, because watching the cart run
raises it immediately: Samus spawns *below* the floor tiles, and one jump lifts
her out, after which she lands and walks normally. `snes_trace.footing` runs
`CollideBottom`'s own probe against the cart's own tilemap and threshold and puts
a number on it — sixteen pixels inside the floor, and the pixel row that would
put her on top of it. Same room and right height are separate questions; a boot
record can get the second wrong once the first is right, and now that the first
is right, the second is what is left.

`zig build tas` replays either published tool-assisted run of Metroid II through
the emulator. Neither is a pass condition: the any% run replays faithfully for
40 240 frames and the 100% for 20 590, and both then die. What they are for is a
reference trace, and for `src/save.zig`, which recovered the game's 38-field save
record by finding the routine that writes it — and with it the addresses of
energy, missiles and the two Metroid counters.

## Grading the frames the player is not playing

Frame-exact comparison is the right answer for play and the wrong one for a
cutscene. `zig build oracle -- durations` measures the other kind: it finds every
non-playable stretch of the published run — the opening, every room transition,
every menu press — measures how long each one lasts on the Game Boy, boots a cart
just before it, and measures the same stretch the same way on the cart. The port
is asked to be within 2%, and a stretch it does not have at all is reported as
**absent** rather than as 0%, because a port that never ran the sequence and one
that ran it instantly are different findings.

The census is 60 stretches to the run's horizon: one cutscene (the 320-frame
landing, which both published runs give to the frame), ten warps, forty-seven
screen scrolls and two menu taps that open nothing. A warp is separated from a
scroll by a measurement rather than by a name — the largest single-frame step
Samus ever takes herself is eight pixels, and a warp moves her at least a whole
screen.

Fifteen stretches currently produce a number on both machines and eleven agree.
The four that do not are the port speaking: it crosses a boundary leftwards in
one frame where the original spends twenty-one holding her while it draws, and at
two other boundaries it holds her for forty-odd frames where the original holds
her for one.

The requirements and implementation plan live outside this repository, in
`snes_game_dev/.local/docs/2026-08-22-metroid2-snes-port/`.

