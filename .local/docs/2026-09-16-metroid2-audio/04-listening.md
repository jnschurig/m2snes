---
created: 2026-09-22T20:05:00Z
updated:
  - 2026-09-22T20:05:00Z
working_directory: /Users/james/git/snes_game_dev
---

# The listening pass

Step 18 of `02-plan.md`. Everything before it was graded by a machine: the
register writes are the Game Boy's byte for byte (`audiocmp`, every id in every
table), the cart's ticks are the Game Boy's frame for frame (`audioparity`), and
the shim's synthesis is graded against SameBoy (`gbgrade`, in snes_game_dev).
None of that says the game *sounds* right, and this is where that is said, in
plain words, by a person.

Three passes, each in its own section: the offline A/B, Mesen2, and the FXPak
Pro. **"Sounds right" is a pass.** What is heard goes in the tables; what is
merely predicted is kept apart from what was observed, and bugs are logged in
m2snes `docs/bug_tracker.md` like any other 0b bug rather than only here.

## 1. The offline A/B

`tools/audio-ab-set.sh` renders every song and effect the slice can ask for,
through both engines, into `build-out/audio-ab/`: `<stem>.gb.wav` is bank 4 on
the Game Boy harness through SameBoy's APU, `<stem>.snes.wav` is the ported
engine through the shim and the S-DSP, and `<stem>.req` is the script they both
rendered. Effects are rendered alone and over the main caves theme (`$04`).

Ids from `m2snes/docs/audio_ids.md`, which derives the slice's set from the
port's request stubs.

### Songs

| id | what | verdict | notes |
|---|---|---|---|
| `$11` | title | | |
| `$04` | main caves (the room song at the start) | | |
| `$0C` | Metroid battle | | |
| `$0F` | killed Metroid | | |
| `$15` | main caves, no intro (the restore after a kill) | | |

### Square 1 effects

Alone and over `$04`. The shots (`$07` `$09` `$16` `$0B` `$0A` `$08`) are one
row: they are the same routine indexed by the active weapon.

| id | what | verdict | notes |
|---|---|---|---|
| `$01` `$02` | jumping, hi-jumping | | |
| `$03`–`$06` | screw attack; standing, crouching, morphing transitions | | |
| `$07` `$09` `$16` `$0B` `$0A` `$08` | beam, ice, wave, spazer, plasma, missile | | |
| `$0C` | missile drop picked up | | |
| `$0E` | small energy drop | | |
| `$0F` | beam dink | | |
| `$10` | missile door exploding | | |
| `$12` | item pickup (empty, duration 0) | | |
| `$13` | bomb laid | | |
| `$14` | pipe bug spawner stop | | |
| `$15` | select | | |
| `$17` | large energy drop | | |
| `$18` | Samus health changed | | |
| `$19` | no-missile dud shot | | |
| `$1A` | screw-attacked a Metroid | | |
| `$1B` | Metroid cry (pitch seeded from `rDIV`) | | |
| `$1C` | saved | | |

### Square 2, noise and wave

| id | what | verdict | notes |
|---|---|---|---|
| sq2 `$07` | Autom flamethrower | | |
| noise `$01` | enemy shot | | |
| noise `$02` | enemy killed | | |
| noise `$03` | enemy explosion | | |
| noise `$04` | shot block destroyed | | |
| noise `$05` | Metroid hurt (asks square 1 for `$1B`) | | |
| noise `$06` `$07` | Samus hurt, acid damage | | |
| noise `$08` | missile hit a block or door | | |
| noise `$0B` | Samus killed | | |
| noise `$0C` | bomb detonated | | |
| noise `$0D` | Metroid killed | | |
| noise `$10` | footsteps | | |
| noise `$11` | enemy hit the ground | | |
| noise `$12` | enemy projectile fired | | |
| noise `$1A` | Autoad jump | | |
| wave `$01`–`$05` | low-health beep, one id per ten points under fifty | | |

### The hand-written scripts

The cases with no id of their own, from `m2snes/test/audio/`. Each was written
for Step 15 and is graded by `audiocmp`; the A/B renders the same file.

| script | what | verdict | notes |
|---|---|---|---|
| `int-earthquake-restore` | the earthquake interruption, and the song coming back | | |
| `int-earthquake-end` | the interruption ending | | |
| `int-item-get` | the item jingle | | |
| `int-missile-pickup` | the missile-tank jingle | | |
| `int-item-get-while-quake` | a jingle arriving during the quake | | |
| `int-clear` | clearing the interruption | | |
| `pause-mid-song` / `pause-short` | pause and unpause | | |
| `silence-death` / `noise-death-wait` | the death | | |
| `fade-out` | the fade | | |
| `sfx-priority` / `noise-priority` | an effect taking a channel from the song | | |
| `wave-beep-*` | the low-health beep against songs and the quake | | |
| the rest of `test/audio/*.req` | | | |

### What was rendered

134 pairs, 268 WAVs, 247 MB, nothing failed (`build-out/audio-ab/SET.log`).
Five songs at thirty seconds, every slice effect alone and over `$04`, and all
34 hand-written scripts. Renders are this ROM's music, so they stay in
`build-out/`, which is not tracked.

### Where the two takes disagree most

An ordering, not a verdict, to say where to start listening. The register
writes are already known to be identical — `audiocmp` grades every one of these
scripts exact — so anything here is in the synthesis or the mix, which is what
the ear is being asked about. Each side's loudness envelope (20 ms) is
normalised, since the SNES side is about three times the Game Boy's RMS by
design, and the two are compared **at the same fraction of their own length**:
compared as recorded, the clock difference below buries everything else and
ranks the sixty-second `surface` worst of the 134.

The index runs about 0.75 to 1.00 across the set (median 0.80). Three pairs sit
outside it, and all three are explained:

| pair | index | what it is |
|---|---|---|
| `repeat-unset-point` | 0.37 | **The one worth an ear.** See below. |
| `sq1-12` | 0.00 | The empty item-pickup id, duration 0. Both sides silent; there is nothing to correlate. |
| `lag`, `lag-sfx` | — | A tenth of a second and six tenths: too short to index. Their levels track the usual 3× ratio, and both are about the protocol rather than the sound. |

**`repeat-unset-point` is the one place the two renders differ by more than
level.** The script is deliberately pathological: song `$18` reads past its own
data into the tempo tables, and at tick 217 a `$F5` returns to the `$0000`
`initializeAudio` left, after which the Game Boy is reading its own ROM as song
data. Both engines make exactly the same 1540 writes out of that, and then
render them differently — the Game Boy's output settles around an RMS of 400 to
600 while the SNES climbs to 1300 to 1900, a ratio that is not the constant 3×
the rest of the set shows, so it is different content and not a different
volume.

*Unverified hypothesis:* the shim maps CH3's wave RAM to a precomputed BRR
sample by lookup, and the image carries only the seven `wavePatterns` bank 4
actually uses (Step 11 added a ROM test holding every `$F1` in the song data to
those seven). Garbage wave RAM has no sample to find, which the shim counts as a
`wave_miss`. Song `$18` is not in the slice, and no song the slice plays leaves
its own data.

**Heard, and accepted** (James, 2026-09-22): listening through the set, this is
indeed the most different pair. *"I will accept this for now. In a later phase
we may pick up the sound driver task again and go for better accuracy."* So the
index agreed with the ear about where to look, the difference is real, and the
decision is to leave it: the divergence is in the shim's synthesis of song data
no slice song produces, and closing it is a driver-accuracy job rather than a
port one. The hypothesis above is where that job should start, and it is
unverified — nobody has yet counted the `wave_miss`es on this script.

### Measured while rendering, not heard

Numbers taken off the renders themselves, so the ear has context before it
starts.

- **The SNES mix sits near the rail and the Game Boy's does not.** Song `$04`:
  GB peak 15661, RMS 1797, two samples at peak in thirty seconds; SNES peak
  32511, RMS 6177, 0.035% of samples at the rail. The title `$11` is 0.625% at
  the rail. **This is a decision, not a finding** — Step 11 kept `MVOL $7f` and
  full scale 127 with the title measured at 0.80% near-rail, because the DSP
  clamps the voice sum before `MVOL` and the lever is per-voice scale. What was
  heard as clipping then was key-on clicks, since fixed, after which the verdict
  was "the 127 tracks are clean". Recorded here so the same observation is not
  filed twice.
- **A frame is not 1/60 s on either machine**, so the two files are not the same
  length: 1800 frames is 30.14 s of Game Boy (59.7275 fps) and 29.95 s of SNES
  (60.0988). Nothing to hear in itself; it means the two takes drift apart by
  0.19 s over thirty seconds and 0.31 s over sixty, so a long A/B is compared in
  pieces rather than by starting both at once and listening to the end.
- **`spcrun` is coarser than the console about *when* inside a frame a tick's
  writes land**: it packs two or three ticks into a message where the cart sends
  one, which moves them against the 512 Hz sequencer. The writes and their order
  are unaffected, and the cart is graded separately by `audioparity`, but a
  very short render (`lag-sfx`, 0.6 s) shows it. It is a property of the offline
  runner, not of the port.

## 2. Mesen2

The slice start to finish, including the earthquake and its restore, item
jingles, effects over music, pause, death and the title.

2026-09-24, `m2snes.sfc` at m2snes 1d1c0ed, played by James. **A pass:** "it
behaves identically to the FXPak playthrough" — every row of §3's "Heard again"
and "The rest of the slice" holds here too, pause included (not ported, the same
in both).

## 3. The FXPak Pro

2026-09-22, `m2snes.sfc` and then `stretch00.sfc` on the console.

### How it was read

Not off a drawn readout: `!AudReply` ($7E075B) is the last completed message's
reply, and the cart commits it whole, so the shim's tick count, overrun count
and idle counter are already the matched set the plan asks for — filled in by
the SPC700 in one pass before they were published. `tools/fxpak.sh read` (added
here) reads those twelve bytes over SNI while the game runs, which is bytes
rather than a screenshot to be believed.

**Every read is accumulated, not just the window's ends.** The overrun byte is
eight bits of a counter climbing 25 to 80 a second, so it wraps inside twenty
seconds, and differencing the ends reads a wrap as a small number: the busiest
window measured first reported 5.8 overruns a second and was really 80.8. The
sampler reads every 160 ms and adds each gap, where a wrap cannot happen, and
rejects a gap holding more ticks than 60 a second allows — which is what a reset
looks like, and one reset reported 3880 ticks a second and a negative load
before that check existed.

### Load and overruns

| condition | songPlaying | overruns | of the 512 Hz ticks | idle | load |
|---|---|---|---|---|---|
| no music, still | `$10` | 26.8/s | 5.2% | 6381/s | 19.6% |
| surface theme, still | `$04` | 55.6/s | 10.8% | 5813/s | 26.8% |
| no music, playing | `$10` | 39.4/s | 7.7% | 5802/s | 26.9% |
| battle theme, playing with effects | `$0C` | **80.8/s** | **15.8%** | 4998/s | **37.0%** |

Against the gate Step 11 set — 50% on `surface` — the worst measured here is
37.0%, under the battle theme with effects firing. Music costs about seven
points over silence, and so do effects; together with the heavier track, 17.

**The absolute load is not trustworthy yet; the differences between the rows
are.** Load is `1 - idle/baseline` against Step 11's *offline* hosted silent
baseline of 7936 passes a second, and this hardware idles at 6381 with nothing
playing — a fifth below the baseline before a note sounds. The SMP's clock
cannot explain it (the console's is 0.13% faster than the core's, not 20%
slower), so either the offline baseline was taken under conditions the cart does
not share, or something costs 20% at rest. **A hardware silent baseline should
be measured before any of these percentages is quoted.** The overrun counts are
measured directly and need no baseline.

**The overrun rate is the highest this project has measured.** `audio/README.md`
records `surface` at 36/s fed in Mesen2 and 11.5/s resident offline; hosted on
hardware under the battle theme it is 80.8/s, 15.8% of the sequencer's ticks
arriving late. Ticks are never lost — the shim services every one and counts the
excess — so what it should cost is jitter rather than wrong notes, and whether
that is audible is the ear's to say. **The ear says not** (2026-09-24, below).

### What was heard

| what | verdict |
|---|---|
| the shipped cart, new game, walking the starting area | **No music at all.** Effects only. The surface theme never comes up. |
| `stretch00`, which boots with the surface theme | Music plays. |
| after killing the first Alpha on `stretch00` | **The music disappears for the rest of play** — "sound effects randomly played here and there instead of music". |

That is one bug, found by playing and then measured, and **fixed the same day**
(m2snes `docs/bug_tracker.md`, boot record version 14 plus the 00:$0EAF request
site, guarded by `zig build audioboot`'s room run: `$04` seeded, requested and
playing from pass 324, and the guard fails if the seed is reverted). It is
logged in m2snes `docs/bug_tracker.md`. `!Song` (the port's
`currentRoomSong`) is never seeded and stays `$FF`, because the site that asks
for the room song (00:$0EAF) was deliberately left unported while "which audio
driver Phase 0c lands on is an open decision" — a decision this cycle has since
made. After a Metroid dies the restore computes `!Song + $11`, so the cart asks
for `$FF + $11 = $10` where the Game Boy asks for `$15`, and `$10`'s table entry
is `initializeAudio.ret` rather than a song header. Hence silence, permanently.

**It also corrects a claim in `docs/audio_ids.md`**: `$10`, the one id
`audiocmp` has never matched, is listed as outside the slice. It is not — the
slice reaches it every time a Metroid dies, *because* of this bug. Seeding
`!Song` makes the restore ask for `$15` and puts `$10` back out of reach.

None of this is the sound engine's: every id is exact under `audiocmp`, `$04`
renders correctly in the offline A/B, and effect requests were seen arriving
throughout (square 1 read `$07`, a beam shot, mid-window). The engine plays what
it is asked for. It is being asked for silence.

### Heard again, on the fixed cart

2026-09-24, `m2snes.sfc` built at m2snes 1d1c0ed. Slot 0 still held the buggy
cart's save, so its magic was zeroed over SNI (`tools/fxpak.sh write 700000
0000000000000000`) with the title up, which makes Start begin a new game.

| what | heard | read off the cart |
|---|---|---|
| new game, past the countdown | the surface theme | `!Song $04`, `songPlaying $04` |
| after killing the first Alpha | the music comes back | later, in the next area: `!Song $05`, `songPlaying $16` — the restore's `+ $11`, not `$10` |
| playing on past it | "all music and sound seemed good with no noticeable stutter or timing issues" | |

The last row is the verdict on the overruns: 15.8% of ticks arriving late is
not audible in play.

### The rest of the slice

Same session, same cart. James's words: "the general play is good".

| what | verdict |
|---|---|
| music in every room, effects over it | right |
| the earthquake: its interruption, then the room song restored | right |
| item jingles, and the song after them | right |
| death | right |
| back to the title | right |
| pause (Start away from a save point) | **does nothing — not ported.** The game's pause screen is outside the slice (m2snes `docs/feature_tracker.md`, deferred with B13's L counter), so nothing sends `!REQ_PAUSE_CONTROL`. The engine's half, `audioPauseControl`, is ported and exact under `audiocmp` (`sweep-audioPauseControl.req`), but cannot be heard until the game pauses. |

### What is already measured, for comparison

| | offline | FXPak (2026-09-21, Step 11) | FXPak, hosted in the game (2026-09-22) |
|---|---|---|---|
| `surface` load | 16.0% | 15.8% / 15.7% | 26.8%, standing still |
| `title` load | 25.3% | 22.6% | not measured |
| `surface` + effects | 19.5% (measured engine + Step 7's +22% for effects) | | not measured apart; the battle theme with effects is 37.0% |

The in-game column carries §3's caveat: its baseline is the offline one, and
this hardware idles a fifth below it at rest, so compare its rows with each
other, not with the columns to its left.

- **ARAM:** the image is 31,187 bytes in 18 blocks (`zig build rom`).
- **Boot upload:** 60 frames, 1.0 s, first pass at frame 65 (`zig build
  audioboot`). With every APU port read forced to 0 the cart reports state 0 and
  runs without audio, first pass at frame 27.
- **The audio service's cost to the game:** 6 scanlines a frame, down from 40
  before the IRQ-driven pump. Over stretch 0's 392 frames the worst `MainLoop`
  pass is busy 149 of 262 lines, 6 of them the sound's, with no overrun.

## Gaps

Kept in three lists so that a thing predicted is never read as a thing heard.

### Observed

- **A new game plays no room song** (m2snes `docs/bug_tracker.md`, 2026-09-22).
  Found by playing the cart; the mechanism is above. **Fixed and guarded the same
  day, and confirmed on hardware 2026-09-24** after clearing the buggy cart's
  save. A slot saved by a buggy cart still restores the bad byte; a player with
  one needs the same clearing, since the port's title offers only Start.
- **80.8 overruns a second is not audible** (2026-09-24, playing past the first
  Alpha on the fixed cart).
- **`$10` is reachable in the slice**, contrary to `docs/audio_ids.md`, as a
  consequence of the same bug.
- **Overruns on hardware are 80.8/s under the battle theme with effects**, well
  above every figure recorded offline or in Mesen2. Judged inaudible, above.

### Predicted, from what is known about the port

- **The reply the game reads is two ticks old.** `docs/audio_protocol.md` records
  the one place it can change a branch: the HUD's square 1 test at a sound's
  first and last two frames. Whether it is audible is a question for the ear.
- **Song `$10` is the one unmatched id** and is not in the slice: bank 4's table
  points it at `initializeAudio.ret`, code rather than a header
  (`docs/audio_ids.md`).

### Accepted, and deferred to a later phase

- **The offline A/B set as a whole** (2026-09-24). James listened through the
  rendered pairs: "there are some differences, but they are acceptable at this
  phase of design and implementation". The writes are exact under `audiocmp`;
  what differs is synthesis, the shim's and not the port's.
- **The pause is never heard.** The game's pause screen is outside the slice, so
  the engine's pause and unpause — graded exact offline — have no caller yet.
  They get their listening when the pause screen is ported.

- **`repeat-unset-point`'s synthesis divergence** (above). Accepted by James on
  2026-09-22 after listening to the set. Revisit if and when the sound driver is
  picked up again for accuracy; the starting point is whether the shim's CH3
  lookup misses on the garbage wave RAM that script produces.

### Unfixed bugs

- **"A handover cart boots the Alpha fresh"** (m2snes `docs/bug_tracker.md`).
  Not an audio bug: stretch 6 is capped at frame 27 because the Game Boy's
  missile hits the Alpha there and the cart's does not. The hit sound is right
  in manual play.
