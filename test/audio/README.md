# Request scripts

What the game asked the sound engine for, per `handleAudio` call. One script
drives both the Game Boy's engine and the SPC700's; `zig build audiocmp --
<script>` runs it through each and reports the first tick where they disagree.

The format is in `src/audio_req.zig`'s header. In short: one line per frame,
each tick a bracketed record of `name=value` ops in hex, `-` for a frame in
which the game called `handleAudio` no times, `#` for a comment.

Names are M2RoS's own names for the WRAM bytes, not addresses: an address is a
fact about the Game Boy that the SPC700 side does not share.

The ids come from `docs/audio_ids.md`, which records where each one was found.

`songs/` is every song id for sixty seconds and `sfx/` every sound effect id
on all four channels, alone and over the surface theme. `sweep/` is every
value of each request byte, $00 to $FF, one after another over the surface
theme, which covers the ids past each table. All three are generated (by
`tools/gen-song-reqs.sh`, `tools/gen-sfx-reqs.sh` and `tools/gen-sweep-reqs.sh`). The scripts here are the
cases the generated ones cannot state. `sfx-*.req` covers square 1's priority
and preemption, the Chozo ruins' short jumps and the screw attack's resume.
`noise-*.req` covers the noise channel's priority, the earthquake dropping a
request, footsteps giving way, the death sound's wait and the cries it requests
on the square channels. `wave-*.req` covers the low-health beep's stop and the
song taking the channel back. `int-*.req` covers the song interruptions (the
earthquake, both jingles, their end and restore, and the $FF clear),
`fade-out.req` the fade to the credits, `pause-*.req` the pause and its sound,
and `silence-death.req` the game's `silenceAudio` calls.

`samusPose` and `samusItems` are game state rather than requests. The engine
reads them in one place, when an energy drop's sound ends mid screw attack, so
a script sets them and they stay set.

`rDIV` is the Game Boy's divider, which five cries seed their pitch from. On
the Game Boy side the harness pins what a read of DIV returns, since a write
would reset it. It is 0 until a script sets it, and like the game state it
stays set.

`silenceAudio` is not a byte: it is the game calling bank 4's `silenceAudio`
outside `handleAudio`, at a death, the boot and two unused game modes. It runs
where it stands in the tick, so a request before it is cleared and one after
it survives, and its register writes are that tick's. Its value is not read;
scripts write `silenceAudio=1`.
