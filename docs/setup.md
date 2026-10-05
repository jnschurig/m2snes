# Setup

## 1. Toolchain

Tool versions are pinned in `mise.toml`:

```sh
mise trust && mise install
```

That is the whole required toolchain: **Zig**. Everything below is optional and
needed only by specific later steps.

## 2. Your ROM

This is a bring-your-own-ROM builder. The repository contains no game data —
every asset is extracted from your own cartridge dump at build time. You need:

```
Metroid II - Return of Samus (World)
256 KiB (262,144 bytes), Game Boy
sha1 74a2fad86b9a4c013149b1e214bc4600efb1066d
```

Ingest rejects anything else and tells you what it found, because a wrong
revision would not fail loudly — it would shift every offset and produce a
subtly broken SNES ROM many steps later.

`mise.toml` looks for the ROM at `./metroid2.gb` and `~/roms/gb/metroid2.gb`.
Anywhere else, point `M2_ROM` at it:

```sh
export M2_ROM=/path/to/metroid2.gb
```

or pass it per-build: `zig build verify -Drom=/path/to/metroid2.gb`.

## 3. The gate

```sh
zig build verify
```

CI runs only the checks that need no ROM (the README's CI section): every
interesting check needs your ROM, which cannot be distributed and which a public
runner cannot hold. So this local command is the gate, and every later step
hangs its checks here. **It must be run locally,
with the ROM:** without one it fails with `no ROM: set M2_ROM ...`, because a
gate that skipped its ROM checks would report green having graded nothing.
`zig build verify-full` and `zig build test-rom` (the unit tests alone) fail
the same way. Plain `zig build test` still runs without a ROM and skips the
tests that need it.

It takes about fourteen minutes on an M-series Mac with Mesen2 present (the
budget is fifteen; `docs/conformance.md` records each measurement).

```sh
zig build verify-full
```

is the gate followed by the **slow tier**: the seeding fixture, the 100% recording's
worlds against their pins, and the credits at each ending. It needs the recording in
`reference/metroid2-100p-recording/`, and there a missing input is a failure, not a
`skip`. Run it at the close of any change to the world, the boots, the seeding or the
ending. The recording's first cold run takes about five minutes in Mesen2; after that
Mesen's answers are cached in `build-out/mesen-cache/`.

**The first gate on a new ROM walks every door on the Game Boy** (`zig build crawl`, about
2 minutes, 1.0 Step 5a). The result is cached in `build-out/` by the ROM's SHA-1 and the
crawler's version, so later builds skip it.

## 4. Optional tooling

| Tool | Needed by | Install |
|---|---|---|
| asar 1.91 | rebuilding the engine image | `tools/get-asar.sh` (needs `cmake`) |
| M2RoS bank 4 symbols | routine names in `zig build audiocost` | `tools/get-bank4-sym.sh` (needs rgbds; checked against your ROM) |
| spc700asm (TAD v0.4.2) | rebuilding the SPC700 sound engine | `tools/get-spc700asm.sh` (needs cargo) |
| spcrun | grading the sound engine against the Game Boy | `tools/get-spcrun.sh <snes_game_dev>` (needs that checkout, Zig and cargo) |
| Mesen2 | the headless boot test, and Step 14's state traces | resolved by `mise.toml` as `$MESEN` |

**asar runs at dev time only.** It assembles `engine/main.asm` into
`engine/engine.bin` and `engine/engine.sym`, both of which are committed, and
the shipped builder injects converted assets into that image. Someone running
`m2snes their-rom.gb` needs the single Zig binary and nothing else — and neither
does anyone building this repository, unless they change the engine source.

Editing `engine/main.asm` means running `zig build engine` and committing all
three files together. `zig build verify` reassembles the source and compares it
with the committed pair when an assembler is present, and says
`not rechecked: no assembler` when one is not — a committed binary that has
drifted from its source is exactly the failure that would otherwise go
unnoticed.

## 5. The sound engine

The SPC700 side works the same way, one repository further out. `audio/shim/` is
the GB APU shim: an SPC700 program that accepts Game Boy APU register writes and
drives the S-DSP, developed and graded in `snes_game_dev` and copied in here as a
package — the binary, the ABI names an engine assembles against, the constants
the image builder needs, and a MANIFEST naming the commit with a sha256 per file.

```sh
tools/sync-shim.sh ~/git/snes_game_dev   # only when the shim moves
zig build spcengine                      # after editing engine/audio/main.asm
zig build verify
```

`sync-shim.sh` refuses a dirty source tree: a package built from uncommitted
edits names a commit nobody can rebuild it from, and `zig build verify` refuses
one too. The gate checks the committed package against its own MANIFEST on every
run, with no assembler and no source checkout — see `src/audio_shim.zig` for why
this directory in particular gets a tripwire.

`engine/audio/main.asm` names the shim ABI it was written against, in
`SHIM_ABI_EXPECTED`. The assembler asserts it against the package's header and
the gate compares it with the MANIFEST, so a shim that moved its jump table
cannot quietly pull an engine's calls into the middle of a routine.

### Grading it against the Game Boy

The engine is graded by the register writes it makes. A `.req` script in
`test/audio/` says what the game asked for, per `handleAudio` call, and
`audiocmp` runs it through both engines and reports the first tick where they
disagree:

```sh
zig build aramimage                              # build-out/aram.bin, for a look
zig build audiocmp -- test/audio/surface-2s.req  # both engines, one script
zig build audiocmp -- test/audio/surface-30s.req --regs square1
zig build audiocmp -- test/audio/songs/*.req     # every song id, sixty seconds each
```

Several scripts are graded in order, stopping at the first that diverges, so the
files left for replay are that script's. `test/audio/songs/` is generated by
`tools/gen-song-reqs.sh`: one script per song id that extracts, which is all of
them but `$10` (`docs/audio_ids.md`). The other scripts in `test/audio/` are
written by hand, each for one behaviour, and say which in their header.

`--regs` narrows the comparison to one channel's registers, masking the bits of
`NR51`/`NR52` that belong to the others. That is how a partial port is graded —
though as of Step 7 the whole song player is ported and the unfiltered
comparison is exact on both thirty-second scripts, so the filter is now a way to
read a divergence rather than a way to get a pass.

It needs the ROM, `engine/audio.bin` and `vendor/spcrun`, and skips with a named
reason when one is missing rather than reporting a pass. The image and the
generated `spcrun` script are left in `.zig-cache/audiocmp/`, and a divergence
prints the command to replay them by hand.

The slot numbers a script compiles to are declared once, in
`engine/audio/main.asm`'s `REQ_*` equates, and `src/audio_req.zig` reads them out
of that file — so the harness and the engine cannot disagree about what a record
means. `zig build test` fails if they drift.

### Listening to it

The comparison answers whether the writes agree, not what they sound like — a
rendered waveform would put the shim's synthesis and the S-DSP's mixing into a
comparison of the engine. `audioab` is where sound is asked about instead: one
request rendered by both engines, into two WAVs named to sort next to each other
in `build-out/audio-ab/`.

```sh
zig build audioab -- song 04                    # the main caves, thirty seconds
zig build audioab -- song 04 --seconds 8
zig build audioab -- sfx sq1 1B                 # the Metroid cry, three seconds
zig build audioab -- sfx noise 0B --over 04     # Samus killed, over the caves
zig build audioab -- test/audio/int-earthquake-restore.req
tools/audio-ab-set.sh                           # the whole slice, ~40 minutes
```

A `.req` path renders that script as written, which is how the cases with no id
of their own are listened to — the earthquake and its restore, the item
jingles, the pause, the death. They are the same scripts `audiocmp` grades, so
the A/B and the comparison look at one file rather than two descriptions of it.

`tools/audio-ab-set.sh` renders the whole set for the listening pass: every song
and effect the slice can ask for (the ids come from `docs/audio_ids.md`, which
derives them from the port's request stubs), each alone and over the main caves,
plus every hand-written script. It takes a group name — `songs`, `sfx` or
`scripts` — to render one at a time, keeps going past a failure, and leaves the
full output in `build-out/audio-ab/SET.log`.

The Game Boy side is bank 4 on this repository's harness with its writes fed to
**SameBoy's APU** — the same accuracy benchmark `src/gb/sameboy.zig` grades the
PPU against, linked as it ships (`src/sbref.c`) — so the reference is not
another emulator of ours. The SNES side is `spcrun --wav`: the shim running the
ported engine, and the S-DSP's own output. Both render the same generated
`.req`, which is written out beside the WAVs so a render can be handed to
`audiocmp` or replayed by hand.

The two files differ in sample rate (44100 against the S-DSP core's 32000) and
in where inside a frame a tick's writes land; neither matters to an ear
comparing two takes, and both would matter to a comparator, which is why this
writes files rather than a verdict. What it does check is that a render happened
at all: a file that is not as long as its own machine says it should be fails,
and so does a song id that comes out silent.

**Its own machine**, because the two do not agree on what a frame is worth: a
DMG frame is 70224 T-cycles of a 4.194304 MHz clock, or 59.7275 a second,
against the SNES's 60.0988. Thirty seconds of frames is 30.14 seconds of Game
Boy and 29.95 of SNES, and a check that called either of them "sixty frames a
second" would fail every correct render.

Length is counted in a script's **frames**, not its ticks. A line is a frame of
the game and may carry no `handleAudio` call (a lag frame, `-`) or several;
`spcrun` plays one line a frame either way, and the Game Boy render lays its
ticks out the same way, so a script with lag in it lasts longer than its tick
count suggests. What a script cannot say is how far apart two ticks of one
frame stood on the real machine — the harness's own back-to-back calls are the
only answer available, and they keep the order and the frame right.

It needs the ROM, `engine/audio.bin`, `vendor/spcrun` and `vendor/sameboy`, and
names whichever is missing. SameBoy arrives with `tools/sameboy-frames.sh`,
which clones the pinned tag; only `Core/*.c` is built for this step. Renders are
this ROM's music, so `build-out/` is not tracked and they are never committed.

### What it costs

Offline, the engine and the shim work its register writes cause, against the
same image with a null engine in it:

```sh
zig build audioload -- test/audio/surface-30s.req test/audio/title-30s.req
```

The verdict's method is a console, because the emulator steps in 8 ms buffers.
The hosted bench ROM is built in `snes_game_dev` around an image built here:

```sh
zig build aramimage -- --no-trace -o build-out/aram-notrace.bin
cd ~/git/snes_game_dev
zig build hostedbench -- \
  --image ../m2snes/build-out/aram-notrace.bin --name SURFACE --start 0404 \
  --image ../m2snes/build-out/aram-notrace.bin --name TITLE   --start 0411 \
  --stop 04FF
```

`--no-trace` because recording every write costs time, and this is the one
measurement where that time would land in the number. The records are
`(slot, value)` pairs in hex, in the `REQ_*` numbering above: `04` is
`songRequest`, so `0404` is "play song $04" and `04FF` is "silence". The bench
carries those bytes and does not read them, which is why the shim and the bench
can stay ignorant of what Metroid II's engine wants.

`zig-out/gbhosted.sfc` on an FXPak: START uploads the image and runs one tick a
frame for EXCERPT seconds, then silences the engine and measures 600 frames at
rest. Read

    busy = IDL@ x 256 / (POS / 60.0988)
    rest = (IDLR - IDL@) x 256 / (600 / 60.0988)
    load = 1 - busy / rest

`TCK` is the SPC700's own count of the ticks it ran and should equal `POS`; the
two are separate machines' accounts of the same thing, which is why both are on
screen. The upload happens once per power cycle — the S-CPU cannot reset the
S-SMP — so changing IMAGE afterwards shows ST 04 rather than measuring the
image that is actually in ARAM under the name of the one that is not.

## 6. The debug build

A tester's cart for reaching late-game states without playing up to them (1.0,
C8). Build it beside the retail cart:

```sh
zig build rom -- --debug          # build-out/m2snes-debug.sfc and .sym
```

The two carts differ in one byte, `DebugAllowed`, and the header checksum; the
gate's `snes rom` rung holds that. The debug cart has the menu from power-on.

**Hold L, R and Start together** at any point in play, or in the pause, to open
the debug menu; the order they go down in does not matter. The game freezes
behind it, every change lands the moment it is made, and it stays open until you
close it: the same chord again, or B at the menu's root. It closes back to
exactly where you were. On a retail cart the chord is just Start: it pauses, as
the Game Boy's does.

| button | in the menu |
|---|---|
| Up, Down | move |
| A | open a page, switch a switch, run an action |
| Left, Right | less and more (a switch: off and on) |
| B | back a level; at the root, close |
| L + R + Start | close, from anywhere |

The root:

- **SAMUS.** The seven item bits, the beam (power, ice, wave, spazer, plasma),
  energy tanks 0-5, max missiles and missiles by ten, and **full loadout** (A):
  every item, five tanks and full energy, 999 missiles -- the ceilings the pickups
  themselves clamp at. Each writes the variables the pickups write, so the status
  bar follows once play resumes. Changing the beam, the suit, the Screw Attack, the
  Space Jump or the Spring Ball also puts Samus's tiles up as a pickup would have left
  them. The upload is under forced blank, so a few lines of one frame may show black.
- **METROIDS.** All 46 Metroids with a spawn record, **in playthrough order**:
  the order James's 100% recording kills them in (1.0 Step 26; `docs/phase1.md`'s
  roster gives each its number here). Each is named by its cell, the quarter of its
  bank and its species (`01 F:10 NW HATCHING`, `26 A:17 NW ALPHA`); then the Queen, `47 QUEEN`, who has no spawn
  record. Her row reads DEAD when the count is only the Metroids still alive, and
  killing or reviving her moves both counts and nothing else: no death sequence,
  and her room is not changed. The status bar's count leaves the eight larval Metroids out
  until the final area's stinger has run (its FLAGS row, `METROID STINGER`, reads
  DEAD from then on), as the game's does; until then a larva killed or revived
  here moves only the real count. All 47 killed leaves the count at zero, so a missile refill
  then takes the credits branch: the room fades and the credits roll (1.0 Step 22).
  A switches
  **ALIVE** and **DEAD**, Right kills, Left revives. A kill is counted as the
  Metroid's own death counts it: its spawn flag, both counts one down, the status
  bar's shuffle, and `earthquakeCheck`, so the quake follows a few seconds after
  the menu closes and the doors past it test the new count. One on the screen is
  taken off it, and a fight it was in ends. A revive puts back the flag and the
  counts and arms nothing. The list is 20 rows at a time and scrolls with the
  cursor; Up from the first row goes to the last.
- **FLAGS.** Every other spawn record whose flag outlives the room: item orbs and
  tanks (named by the game's own item names), missile doors and blocks,
  Arachnus, the stinger and the baby, 52 in all, as `D:44 MISSILE TANK`. A
  switches **DEAD** and **NEW**, Right dead, Left new. An item's collected state
  is its flag, so DEAD skips an item and NEW puts it back to be collected again.
  Nothing else is counted. SEEN and LIVE are flags the game wrote. The spawn
  records not listed are cleared every time their room is entered.
- **CLOCK.** The in-game timer's hours (00-99) and minutes (00-59), one a press,
  wrapping. The ending (C7) is chosen on the hours: set them, then WARP's ENDING.
- **WARP** (1.0 Step 5b). Four lists, built from the ROM and the door crawl
  (`zig build roster` prints the table):
  - **SHIP AND SAVES**: the ship, then every save station (`SAVE A:99`);
  - **ITEMS**: every item, by cell and the game's name for it. The Spring Ball's
    entry is Arachnus's room (`D:C0`), since Arachnus leaves it (1.0 Step 13);
  - **METROID ROOMS**: each Metroid's room (`01 F:10 HATCHING`) and a room next
    to it (`01 NEXT F:01`), in the order and with the numbers METROIDS has;
  - **QUEEN**: two rows, which do different things, and **ENDING**.
    - `47 QUEEN` is **her fight, at any count**. It runs door $19D, whose
      `ENTER_QUEEN` places Samus at the top of her room: she falls in, as she does
      on the Game Boy, and the Queen is set up fresh every time. This is the row for
      trying her again, after an escape or a death.
    - `QUEEN NEXT E:13` is **the room before hers, at the live count**. Walking on
      from it runs door $13B, which tests the count (`IF_MET_LESS $01, $019D`):
      with one Metroid left (the Queen) or none, it runs $19D and her fight;
      with more, it warps into her area as an ordinary room, with no Queen and
      plain map blocks where her body is drawn. That is the ROM's behaviour, and the
      warp leaves it alone. The debug cart starts at 47, so kill every METROIDS row
      but hers first to reach her this way.
    - `ENDING` is **the ending, from where you stand** (1.0 Step 22): the missile
      refill's credits branch, entered directly with the clock as CLOCK left it. The
      room fades, the credits roll, and once they stop Samus plays the ending the
      hours choose: under 3 her hair let down, 3-5 kneeling in the suit, 5-7 running
      without end, 7 or more standing without end. Nothing leaves the credits but the
      soft reset: **B, Y, Start and Select held** (the Game Boy's A, B, Start and
      Select) reboot to the title, on any cart and from anywhere, as the original's
      do (00:$02E1).

  A warps. The room is entered through the door scripts a player's route into it
  runs, so its tileset, collision, song and item graphics are the ones walking in
  gives, and Samus arrives standing (or as a ball where only a ball fits), beside
  an item rather than on it and clear of a Metroid. The room's enemies load as a
  door's scroll would load them. Items, Metroids and the clock are left as they
  are: set them first. A warp made from the pause arrives paused; Start resumes.
  Where the 100% recording stood in a room, the warp draws the table it shows there, and
  stands Samus only where a player can get to from the room's doors (1.0 Step 18f). No
  warp needs the count set first: a lava room is entered through a lava door, which draws
  the level the live count gives, full at a new game and draining with kills.
  Four destinations have no entry yet (`docs/phase1.md`, Step 5a).
- **ROOM READOUT**, on or off. On a debug cart this replaces the readout's L+R
  shortcut, which the chord would trip; the retail cart keeps L+R.
- **CONTROLS.** The table above.

Every page ends with the unhandled recorders, so a playtest can report a gap as
a number: `POSE` (`!Unhandled`), `AI` and `STATE` (the enemy's), `ITEM` and
`SHOT` (`!PrUnhandled`). Zero is none, and `SHOT FF` is the projectile
recorder's own "none".
