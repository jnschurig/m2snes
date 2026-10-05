# The cart's sound protocol, and when the game reads the engine

metroid2-audio Step 16b. The 65816 talks to the SPC700 through the GB APU shim's
hosted protocol: one message a frame, each tick's requests as a record, and a
twelve-byte reply carried back on the acks. The wire format is snes_game_dev's
`audio/gbapu/memmap.inc` ("Hosted mode's ports"); the cart's half is
`engine/main.asm`, from `AudioBoot` to `AudioIrq`. This file is about the one
thing the protocol cannot give the game: the engine's state *when the Game Boy
had it*.

## The lag

The game reads five engine bytes (`audio_req.read_back`). On the Game Boy they
are plain WRAM, and a read in frame N's logic sees the engine as the last
`handleAudio` left it: **after tick N-1**.

On the cart they come from the reply:

- Tick N-1 is closed at the top of pass N and goes out in that pass's message.
- The shim snapshots its reply when a message's first chunk arrives, *before*
  that message's ticks run. So message N's reply is the engine after tick N-2.
- The pump fetches the reply's pages by IRQ during the pass, into `!AudStage`,
  and `AudioBuild` commits them to `!AudReply` whole at the top of the next pass
  (N+1). A pass therefore reads one snapshot wherever in the pass the read falls.

So **pass N reads the engine after tick N-3: two ticks behind the Game Boy**,
every frame, provided each message completes within its pass (one message a
frame and no drops, measured in 16a; a deferred message makes it later).

This is graded, not assumed. `zig build audioparity` records the five bytes on
the Game Boy as each tick begins, logs `!AudReply` as each cart pass read it,
and requires the cart's pass f to equal the Game Boy's engine after tick f-3
(`audio_parity.compareReply`, `lag = 2`): 381 frames of stretch 0 with 17
changes, and 24 frames of stretch 6, all equal.

A handover cart carries the song the Game Boy was playing (boot record
version 13, `BootSong`), because the song changes more than `songPlaying`:
footsteps give way to a song's noise channel. It starts from its top where the
Game Boy's is part way in, so a byte can differ at first; `compareReply`
grades each byte from the first frame the two agree on it. See
`docs/bug_tracker.md`, "A handover cart boots the sound silent".

## The read sites

Found by scanning the ROM for `LD A,[nn]` and `LD [nn],A` of the five bytes
outside bank 4, which agrees with M2RoS's source. "GB" is the distance from the
tick the read sees to the read; "port" is what the port reads instead.

| Site | Byte | Routine | GB | Port | Can the lag change the branch? |
|---|---|---|---|---|---|
| 00:0EAF | songPlaying | `poseFunc_faceScreen` | 1 tick | not ported | Not ported: the room's song request at the end of the opening countdown is left out on purpose (`PoseFaceScreen`). If ported: only if the song changed in the two frames before, and nothing requests a song during the countdown. |
| 00:25A2 | songInterruptionPlaying | `executeDoorScript` | 1 tick | `!SongPlaying`, a 65816 model | No lag: the port sets the model where it asks for the quake and clears it where the quake ends (Step 14, measured on the recording). |
| 00:36B6 | sfxPlaying_noise | `gameMode_dead` wait loop | **0 ticks**: the read follows the loop's own `handleAudio` | `!DeathNoise`, a 65816 model | No lag. The reply would add 2-3 frames to every death; the model is graded frame for frame by the death rung. |
| 00:378B | songInterruptionPlaying | `handleItemPickup` | 1 tick | `!SongPlaying` | No lag, as 00:25A2. |
| 00:3A39 | songInterruptionPlaying | `handleItemPickup_end` | 1 tick | `!SongPlaying` | No lag, as 00:25A2. |
| 01:4A7D | sfxPlaying_square1 | `adjustHudValues` (health) | 1 tick | the reply | **Yes, at a square 1 sound's edges.** In the two frames after one starts, the cart can still ask for the count's tick (square 1's priority then decides); in the two after one ends, it can skip a tick the Game Boy asks for, if a four-frame slot falls there. Not fixed: the end is the engine's to know, and no 65816 model can have it. Before 16b this read a stub that was always zero, which was wrong for the whole of every sound. |
| 01:4AA2 | sfxPlaying_square1 | `adjustHudValues` (missiles) | 1 tick | the reply | As 01:4A7D. |
| 01:58CD | sfxPlaying_lowHealthBeep | `miscIngameTasks` | 1 tick | the reply, behind a model of the port's own beep requests | **Yes, fixed.** When health recovers while the beep plays, the Game Boy sends the $FF clear once; reading the reply alone, the cart saw "playing" for two more frames and sent it three times, and a beep asked for a frame before recovery was never cleared. For the ticks the reply cannot show a beep request yet (`!BeepFresh`), the port reads what it asked for (`!BeepAsked`). Guarded by `zig build audioboot`'s beep run, which counts the clears (one each time; three with the model off). |
| 01:7A0D | songInterruptionPlaying (**write**) | `earthquake_adjustScroll` | - | `%audio_put` of the set op, slot 6 | The write is a message op now, in the tick it falls before, as the game's requests are. |
| 02:6C22 | songPlaying | `enAI_hatchingAlpha` | 1 tick | the reply | Only if a $0C request went out in the two frames before. The path runs once, on the frame the fight starts, and is what asks for $0C: no. |
| 02:6C6F | songPlaying | `enAI_alphaMetroid` | 1 tick | the reply | As 02:6C22. |
| 02:6FF7 | songPlaying | `enAI_gammaMetroid` | 1 tick | the reply | As 02:6C22: the seen Gamma's fight start (1.0 Step 14). The molt's request (02:$6FB8) has no guard. |
| 02:733D | songPlaying | `enAI_zetaMetroid` | 1 tick | the reply | As 02:6C22: the seen Zeta's fight start (1.0 Step 15). The intro's request (02:$72F6) has no guard. |
| 02:797F | songPlaying | `enAI_omegaMetroid` | 1 tick | the reply | As 02:6C22: the seen Omega's fight start (1.0 Step 16). The intro's request (02:$7902) has no guard. |

## Why not no lag

Reading the engine as the Game Boy does means waiting, at the top of each
pass, for the shim to run tick N-1 and send its state back: about 20-50
scanlines a frame, the cost 16a removed because it pushed a busy frame of the
any% run into lag, and a change to the shim's ABI. Decided against on
2026-09-22: exact 65816 models where the state is the game's own doing, the
reply where two ticks cannot matter, a model of the port's own requests where
they can and the requests are the whole story (the beep), and the one site
where they are not (the HUD's square 1 test) recorded as such.
