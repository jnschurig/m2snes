# Audio ids: what the slice asks the sound engine for

Phase 0c ports bank 4's sound engine to the SPC700 (snes_game_dev
`.local/docs/2026-09-16-metroid2-audio`). This file lists every request the
slice can make, so the port knows what it has to play. Each id carries its
source. The whole-ROM set, which Step 15 sweeps, comes after the slice list.

Three sources, and what each can and cannot say:

- **The port's request stubs** in `engine/main.asm`. The port already runs
  the slice, and every stub carries the Game Boy address it stands in for. That
  makes this the slice list. It does not cover Game Boy request sites the
  port never stubbed; those are listed separately below.
- **`zig build audiocost`'s ROM scan.** Every write to a request byte outside
  bank 4, with constant ids resolved. It covers the whole game, not only the slice.
- **Disassembly of the scan's computed sites** (`zig build disasm`), for ids a
  byte pattern cannot resolve.

A live watch of the request bytes over James's recording was not possible:
our Game Boy emulator loses that run at frame 28 796 (`tas.recorded`), and the
Mesen2 reference trace does not record these bytes.

Request bytes (M2RoS `ram/wram.asm`): `sfxRequest_square1` `$CEC0`,
`sfxRequest_square2` `$CEC7`, `sfxRequest_noise` `$CED5`, `songRequest`
`$CEDC`, `songInterruptionRequest` `$CEDE`, `sfxRequest_wave` `$CFE5`,
`audioPauseControl` `$CFC7`. `$FF` written to an SFX request is "stop", and to
`songRequest` it is silence.

## The slice

### Songs (`songRequest`)

| id | what | source |
|---|---|---|
| `$11` | title | snes_game_dev `metroid2_driver`: the only request in the title-and-demo loop |
| `$04` | main caves, the room song at the start | M2RoS `data/initialSave.asm` "Song for room" `$04`, and `currentRoomSong` in the port (`!SB_SONG`), read at 00:$0EB9 |
| `$0C` | Metroid battle | `!SONG_METROID`, 02:$6C28 |
| `$0F` | killed Metroid | `!SONG_METROID_KILLED`, 02:$6D74 |
| `$15` | the room song again, after a Metroid kill: `currentRoomSong + $11` (main caves, no intro) | `!SONG_RESTORE`, 02:$4056 `ADD A,$11`. Reached only once `currentRoomSong` is the save file's: see `$10` below |
| `$04` | the room's song, asked for whenever what is playing is not it -- which is what starts the music after the appearance sequence | 00:$0EAF, ported in Step 18; `currentRoomSong` comes from `BootRoomSong` |
| the held song | after the earthquake, from `songRequest_afterEarthquake` | 01:$7A1D |
| `$FF` | silence | door `SONG $A` (00:$25D0) |

No door script `docs/slice.md` names on the slice's route carries a `SONG` (doors 072, 074, 078, 082,
084, 085, 086, 186, 192, 201, 217, 479, 481 and 486, decoded; 074 and 217 branch
on the Metroid count to scripts 1E1 and 1E3, which carry none either).
Door-driven songs are therefore outside the slice, and Step 15's sweep still
covers them.

### Song interruptions (`songInterruptionRequest`)

| id | what | source |
|---|---|---|
| `$01` | item-get jingle | 01 item pickup, `sta !SongInt` |
| `$05` | missile-tank jingle | same routine |
| `$0E` | earthquake | `!SONG_INT_QUAKE`, 01:$5889 |
| `$03` | end the interruption | `!SONG_INT_END`, 01:$7A28, and the item path |

The game also **writes `songInterruptionPlaying` ($CEDF) directly**, as `$0E`
at the quake (`!SongPlaying`). The protocol has to carry that as a set-variable
op, not as a request.

### Square 1 SFX (`sfxRequest_square1`)

| id | what | source |
|---|---|---|
| `$07` `$09` `$16` `$0B` `$0A` `$08` | beam, ice, wave, spazer, plasma, missile shots | table 01:$4FE5 indexed by `samusActiveWeapon`, 01:$4F7A; ported as `!BeamSndA` |
| `$0C` | missile drop picked up / missile tick | `!SFX_MISSILE_TICK`, item code |
| `$0E` | small energy drop | item code |
| `$0F` | beam dink | `!SFX_BEAM_DINK`, 02:$6A26, 02:$6BCB, 02:$6C8D |
| `$10` | missile door exploding | `!SFX_DOOR_BLOWN`, 02:$6A4D |
| `$12` | item pickup (empty, duration 0) | item code |
| `$13` | bomb laid | `!SFX_BOMB_LAID` |
| `$14` | pipe bug spawner stop | `!SFX_PIPE_STOP`, 02:$5F86 |
| `$15` | select / missile select | `!SFX_SELECT`, 05:$425A |
| `$17` | large energy drop | item code |
| `$18` | Samus health changed | `!SFX_HEALTH_TICK` |
| `$19` | no-missile dud shot | port stub |
| `$1A` | screw-attacked / froze a Metroid | `!SFX_METROID_SCREW`, 02:$6CEC |
| `$1C` | saved | `!SFX_SAVED`, 01:$7B78 |
| `$FF` | stop | 02:$62D8, 02:$6A2F |

### Noise SFX (`sfxRequest_noise`)

| id | what | source |
|---|---|---|
| `$01` | enemy shot | $42FB, $432B (`sfx_noise_enemyShot`) |
| `$02` | enemy killed | `!SFX_ENEMY_KILLED`, 02:$62DD |
| `$03` | enemy explosion | `!SFX_ENEMY_BURST`, 02:$635F |
| `$04` | shot block destroyed | $570E, $568E |
| `$05` | Metroid hurt | `!SFX_METROID_HURT`, 02:$6CFF |
| `$08` | missile hit a block or door | `!SFX_MISSILE_HIT`, 02:$6A34 |
| `$0B` | Samus killed | `!NOISE_KILLED`, 00:$2FA5 |
| `$0C` | bomb detonated | `!SFX_BOMB_BLAST` |
| `$0D` | Metroid killed | `!SFX_METROID_KILLED`, 02:$6D6F |
| `$11` | enemy hit the ground | `!SFX_HIT_GROUND`, 02:$55FA |
| `$12` | enemy projectile fired | `!SFX_ENEMY_SHOT`, 02:$6325 |
| `$1A` | Autoad jump | `!SFX_AUTOAD_JUMP`, 02:$6223 |

### Game Boy requests the port has no stub for

The ROM requests these ids and the port records none of them. Step 16a adds
request stubs; any of these the slice reaches will be silent until then.
Whether the slice reaches each site is not traced here, except where noted.

| id | request | what | Game Boy site |
|---|---|---|---|
| `$01` / `$02` | square 1 | jumping / hi-jumping: `((items & 2) >> 1) + 1`. The slice jumps. | 00:$1509, 00:$167F |
| `$1`-`$5` | wave | low-health beep level: health's BCD tens digit + 1, below 50 | 01:$58C8 |
| `$01` / `$02` | pause | pause / unpause (`audioPauseControl`) | 3 constant sites |
| — | `silenceAudio` | a call, not an id: record slot 12 (Step 15). The port's `KillSamus` clears its own request bytes in its place | 00:$2FA2 (death), 00:$3E3F (boot), 00:$3ACE and 00:$3B43 (unused modes) |
| `$03`-`$06` | square 1 | screw attack; standing, crouching and morphing transitions | constant sites (M2RoS names) |
| `$06` `$07` `$10` | noise | Samus hurt, acid damage, footsteps | constant sites (M2RoS names) |

## The whole ROM (for Step 15's sweep)

From `zig build audiocost` (whole ROM, bank 4 excluded):

| request byte | sites | constant ids | computed |
|---|---:|---|---|
| square 1 | 98 | 01-06 0C-10 12-15 17-1A 1C 1D 2D FF | 00:1509, 00:167F (jump), 01:4F7A, 01:4FE1 (shot table), 02:4E0F (`XOR A`: `$00`) |
| square 2 | 1 | 07 | |
| fake wave | 0 | | |
| noise | 58 | 01-18 1A | |
| song | 25 | 01 02 0C 0E 0F 11 12 13 1F FF | 00:0EB9 (room song), 00:25B0 (door `SONG`), 01:7A1D (after quake), 02:4056 (room song + `$11`) |
| song interruption | 8 | 00 01 03 05 08 0E | |
| wave | 5 | FF | 01:58C8 (low-health level) |
| pause | 3 | 01 02 | |

Door-script `SONG` operands across all 512 scripts: `$3` ×21, `$4` ×6, `$5` ×6,
`$6` ×6, `$7` ×4, `$8` ×5, `$9` ×2, `$A` ×1, `$B` ×1, `$D` ×13.

Step 15 swept every value of every request byte, `$00` to `$FF`, over the
surface theme (`test/audio/sweep/`, from `tools/gen-sweep-reqs.sh`), on top
of `songs/` and `sfx/`, which grade each id in its table. All are exact: the
ids past each table are ignored exactly as bank 4 ignores them (square 1 from
`$1F`, which is where the game's `$2D` goes; square 2 from `$08`; noise from
`$1B`; the wave channel from `$06`; songs from `$21`, which leave the playing
song playing), `sfxRequest_fakeWave` is only ever cleared, `audioPauseControl`
acts on `$01` and `$02` alone, and a song interruption other than `$01`,
`$03`, `$05`, `$08`, `$0E` and `$FF` does nothing. The one id that does not
match is below.

Step 13 listed square 1's `$1B` and square 2's `$03`-`$06` here, because
their init seeds the pitch from `rDIV` and no request site in the ROM names
them. Step 14 found that the noise channel requests them: `$05` (Metroid hurt,
in the slice) asks square 1 for `$1B`, and `$09`, `$0A`, `$16` and `$17` ask
square 2 for `$03`, `$06`, `$04` and `$05`. The divider is now carried as
record slot 11 (`rDIV`). The Game Boy harness pins what a DIV read returns, and
the engine reads the same byte, so all five match and have left this table.

| id | request | why | since |
|---|---|---|---|
| `$10` | song | Bank 4's table entry is `initializeAudio.ret`, which is code, not a song header. The Game Boy reads the code bytes as a header. The port has a sentinel there (`aram_image.song_nothing_sentinel`) and the engine does not test for it yet. No request site in the ROM asks for `$10` **as a constant** -- but 02:$4051 computes one, `currentRoomSong + $11`, and reaching `$10` means `currentRoomSong` was `$FF`. Step 15's sweep leaves it out; requested alone it diverges at tick 1 (the Game Boy writes NR10, the port NR12). | Step 12 |

**`$10` was reachable in the slice until Step 18, and that was a bug of ours.**
`!Song` booted at `$FF` -- "no door script has run" -- so the restore after a
Metroid kill asked for `$FF + $11 = $10` where the Game Boy asks for `$15`, and
the music stopped at the first Metroid and never came back
(`docs/bug_tracker.md`, 2026-09-22). `!Song` is now seeded from `BootRoomSong`,
so the restore asks for `$15` and nothing computes `$10`. If this id ever turns
up in a reply again, the room song is wrong before the sound is.
