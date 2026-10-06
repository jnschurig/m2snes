# GB APU → SPC700 shim — cycle prompt

**Started:** 2026-09-01

## The ask

> metroid 2 audio driver. Looking to implement an audio driver that allows
> gameboy audio to be played on the snes hardware.
> See `.local/docs/2026-08-06-gb-apu-spc700-shim.md`.

## Scoping answers (2026-09-01)

Three questions were put to James before requirements were drafted, because the
existing Metroid II port plan had already chosen the *other* audio path.

| Question | Answer |
|---|---|
| Relationship to F8 / Phase 0c, which picked TAD transcription with this shim as the documented fallback? | **Standalone tooling, m2 as first client.** Build it as the design doc frames it — generic GB-APU-on-SNES tooling worth having on its own, with Metroid II as the proving ROM. m2snes wiring is a later concern, and `01-requirements.md` for the port is **not** amended by this cycle. |
| Where does the code live? | **`snes_game_dev`** — where the SPC700/DSP emulator, the TAD infrastructure, and the assembler tooling already are. |
| How much of the design doc's six-step build order? | **Steps 1–3 — the honest go/no-go.** Measure the log size, build the capture tool, build the pulse-only shim proven against a reference recording. Wave, noise, the 65816 feed and SFX are a later cycle. |

## What already exists (surveyed before drafting)

- `vendor/tad-src/crates/shvc-sound-emu` — cycle-accurate SPC700 + S-DSP core,
  exposing arbitrary ARAM, DSP registers, IO ports and `emulate()`. Already
  wrapped as a C-ABI staticlib for Zig in `runtime-pc/tadshim/`.
- `vendor/tad-src` also ships **`spc700asm`**, the assembler TAD uses to build
  its own audio driver (`audio-driver/GNUmakefile`). No new assembler needed.
- `.local/roms/Metroid II - Return of Samus (W).gb` — the proving ROM, already
  present and gitignored.
- `~/git/m2snes/src/gb/` — an SM83 core with APU *register capture* already
  written (`apu.zig`, logs `$FF10`–`$FF26` / `$FF30`–`$FF3F` with frame + cycle
  timestamps). Prior art for the capture half, in a different repo.
- `~/git/m2snes/vendor/sameboy` — SameBoy, fetched and built by script, already
  used as the accuracy oracle for that project's PPU.
