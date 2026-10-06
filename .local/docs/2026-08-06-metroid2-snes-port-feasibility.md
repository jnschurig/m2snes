# Feasibility: rewriting Metroid II (GB) in SNES assembly on this engine

**Date:** 2026-08-06
**Revised:** 2026-08-06 — distribution model corrected, viewport decided, audio
approach changed, static recompilation considered and rejected.
**Status:** Investigated. Shelved as a project, but with several decisions now made
and one piece of tooling promoted to independently worthwhile.
**Question:** Is it possible/reasonable to rewrite Metroid II: Return of Samus on
this stack, using the [M2RoS](https://github.com/metroidret/M2RoS) disassembly
plus an owned ROM for assets? Specifically: is there enough convenient overlap to
make it *easy*?

## Verdict

Feasible, but **not easy, and not a port — a rewrite.** The overlap is real but it
is all in the *data/spec* layer, not the code layer. Scope of a complete version is
a full commercial game: 12–24 months solo at hobby pace, i.e. Phase 6-scale,
comparable to or larger than the RPG vertical slice.

The revision below does not change that verdict. It removes two of the four
arguments against, and settles two design questions the original left open.

## What was examined

- **M2RoS** (shallow clone, inspected only): ~47k lines of asm across 9 bank files
  (`SRC/bank_00*.asm`), plus `docs/` (ROM Tour, Bank 2 Map, Enemy Headers, Style
  Guide), `scripts/` extractors, `patches/`, and structured data under
  `SRC/data`, `SRC/samus`, `SRC/tilesets`, `SRC/ram`.
  - rgbds v1.0.1 + Python 3.13; originally produced with mgbdis. Verified matching
    (byte-exact rebuild).
  - **Critically: hand-labeled, not raw mgbdis output.** Symbols read like
    `samus_poseJumpTable`, `enemyHitboxes`, `handleSongAndSoundEffects`,
    `main_handleGameMode`. This is readable source, which is what makes the
    exercise thinkable at all.
  - Proprietary assets are gitignored and pulled from a legally-owned ROM by
    `extract.py` — same model we would have to follow.
- **Local ROM**: `.local/roms/Metroid II - Return of Samus (W).gb`, 256KB. Matches
  what `extract.py` expects (it looks for `./Metroid2.gb`).
- **This repo**: zasm + engine + vm + assets + runtime-pc, ~28k lines of Zig,
  through M5.

## Overlap analysis

| Domain | Transfers? | Notes |
|---|---|---|
| Behavioral spec — physics constants, pose transition tables, enemy headers/hitboxes/damage values, door scripts, metatile solidity | **Yes, large win** | Already extracted into `.asm`/`.csv` under `SRC/data` + `SRC/samus`. This is the expensive, hard-to-reverse part of any reimplementation and it is done. Unaffected by the viewport decision below. |
| Graphics | **Yes** | GB 2bpp tiles are directly usable as SNES 2bpp — same row-interleaved plane layout — or promoted to 4bpp. `scripts/extract_chr.py` is just a table of (bank, address, size, path) — trivially reimplemented in `assets/` so the pipeline stays source of truth (standing rule #2). |
| Maps / rooms | **Yes, as data** | Needs a format converter; structure is documented in `docs/Bank 2 Map.md`. Caveat: expanding the viewport makes room geometry a *starting point* rather than truth — see below. |
| SM83 code | **No — zero** | Different registers, addressing modes, flags. Read as spec, rewrite in zasm. Automated translation was investigated separately and rejected — see appendix. |
| GB PPU → SNES PPU | **No** | Different sprite-per-line limits, BG model, scroll registers, OAM format. Rewrite. |
| GB APU → SPC700 | **Changed — see below** | Originally assessed as the worst case: hand-transcribe every track to TAD MML. Superseded by [emulating the GB APU on the SPC700](2026-08-06-gb-apu-spc700-shim.md), which removes the transcription job entirely. |
| MBC bank layout | N/A | Redesign for LoROM/HiROM regardless. |

## Audio: superseded

The original assessment — *"4 fixed channels → sample-based SPC700, music must be
hand-transcribed into TAD MML, weeks of unrewarding work that teaches nothing new"* —
no longer holds.

Instead: **emulate the chip, not the music.** A GB APU emulator on the SPC700, fed a
captured register-write stream, plays the original soundtrack with no transcription
at all. The full design is in
**[GB APU → SPC700 shim](2026-08-06-gb-apu-spc700-shim.md)**.

Three consequences for this document:

- The "audio is a from-scratch transcription job with no transferable learning"
  argument against is **withdrawn**.
- The shim is **worth building whether or not Metroid II ever happens** — it is
  generic across every GB game, and gives any SNES project authentic DMG chiptune
  with 4 DSP voices left spare for sample layering.
- It is the *only* piece of the static-recompilation idea that survives, for reasons
  covered in the appendix.

## Viewport: decided — expand to 256×224

GB is **160×144**; SNES is **256×224**. No integer scale fits (2× = 320×288). The
original framing treated this as an open design question between a faithful bordered
160×144 and a reflowed full-screen 256×224.

**Decided: reflow to 256×224.** The reasoning is that fidelity is already a solved
problem by other means — Game Boy emulation is essentially perfect, and an FXPak Pro
provides Super Game Boy functionality on real SNES hardware. A faithful 160×144
rewrite would be strictly dominated by things that already exist. The rewrite only
earns its existence by being a *SNES game*: using what the platform offers, and being
integrable with other SNES-native projects.

This accepts the known cost — a wider view reveals more map and makes the game
materially easier — as a design problem to solve rather than a reason not to proceed.

### What expanding actually costs

+96px horizontal (+6 tiles), +80px vertical (+5 tiles). Roughly in order of
annoyance:

1. **Enemy spawn/despawn is viewport-relative.** A wider view means enemies pop in
   visibly at the edges. Spawn margins must be re-derived, not copied from M2RoS.
   This is the most pervasive item — it touches every enemy type.
2. **Room geometry needs re-authoring** wherever a room is narrower than the new
   viewport. Camera locks and room boundaries were designed against 160×144.
3. **M2RoS becomes spec, not truth,** for anything camera- or room-relative. Physics
   constants, enemy headers, hitboxes and damage tables still transfer cleanly —
   that's the bulk of the value, and it is unaffected.
4. **The HUD moves off the play area.** GB spent screen on the status bar; splitting
   it out still nets more play area than the original.
5. **The descent tension drops.** Metroid II's claustrophobia and its "what is below
   me?" pressure are load-bearing, and a bigger window weakens both. Available lever:
   a windowed light radius via SNES color math — cheap, very on-theme for the
   tunnels, and it buys back the tension without shrinking the viewport. Worth
   prototyping early, since it changes level feel and therefore level authoring.

Related: 4 shades → color remains an opportunity (AM2R-ish), but implies authoring
palettes for every tileset and enemy — real art work, not a conversion step.

## Distribution: corrected

The original claimed the result *"cannot be distributed... means there is no
'shipping' at the end."* **That is wrong**, and it was the second-strongest argument
against.

Ship a **bring-your-own-ROM builder**: a tool containing zero copyrighted bytes that
reads the user's own GB ROM, extracts the proprietary assets, and produces the SNES
ROM. This is a well-established model — M2RoS itself works this way (gitignored
assets + `extract.py` + build), as do sm64ex, Ship of Harkinian, and the N64Recomp
projects (Zelda 64 / Majora's Mask Recompiled).

Note this model does **not** require static recompilation. It applies unchanged to a
rewrite, which is how the refutation is obtained for free.

What it does *not* fix is the first argument against: it is still not our game.

## Fit against our architecture

Metroid II is a twitch action-platformer. Per the Phase 1.5 survey finding
(genre → opcode style), Samus physics, collision, and enemy AI belong in **native
65816 engine code**, not bytecode. The VM's honest role would be door scripts, item
pickups, and cutscenes (Queen sequence, credits) — a much narrower slice of the VM
than the RPG exercises. So this validates the *engine* hard and the *VM* lightly.

The "integrate with other SNES-native projects" motivation reinforces this and
settles a question the original left open: the rewrite targets **our** conventions —
our OAM/sprite system, our map format, the VM for scripts — rather than a GB-shaped
compatibility layer. That is precisely what makes it exercise `engine/` per PLAN.md,
and it is something the recompiler path could never have done.

## Effort

~30–35k lines of actual logic in the disassembly (remainder is data). Reimplemented
here: est. 15–25k lines of zasm-emitted 65816 plus pipeline Zig. Content scope is
~40 enemy types, ~300 rooms, ~40 Samus poses, save system, item system, Queen
fight, credits.

The audio change removes weeks of transcription from this estimate but adds the shim
build (see its own doc). Roughly a wash for Metroid II alone; a clear win once the
shim is counted as reusable.

## Arguments considered

**For:**
- Rare property: *every unknown is removed.* Never design, only implement against a
  known-correct reference, with the GB ROM in an emulator as a behavioral oracle.
  (Weakened somewhat by the viewport decision — reflowing to 256×224 reintroduces
  genuine design work around camera, spawn margins, and difficulty.)
- Exercises exactly what M5 only touched and Phase 6 needs — map streaming across
  banks, a large sprite/animation system, save system, high pipeline volume.
- Consistent with the reference corpus already in PLAN.md (zelda3/sm-style
  reimplementations); this would be doing one.
- Ships as a bring-your-own-ROM builder, so there *is* something to release.

**Against:**
- It is not our game. PLAN.md known-risk #1 is "built the engine, never shipped the
  game." A complete third-party port is the largest possible instance of that trap.
  **This remains the decisive argument.**
- The engine validation payoff saturates long before the game is complete.
- ~~Cannot be distributed.~~ **Withdrawn** — see "Distribution: corrected".
- ~~Audio is a from-scratch transcription job with no transferable learning.~~
  **Withdrawn** — see "Audio: superseded".

## Recommendation (not adopted, recorded for later)

If ever revisited, **do not attempt the full game.** Do a bounded slice —
"Phase 5.5": Samus movement + one tileset + ~6 rooms + 2–3 enemy types + one item
pickup, driven by M2RoS-derived data, GB ROM as oracle, at 256×224. Est. 6–10 weeks
for ~90% of the engine-validation value. Decide again from there.

**Current disposition: shelved.** This was a feasibility check only. The answer to
"is there enough convenient overlap to make it easy" is **no** — the overlap is in
data and behavioral spec, which is genuinely valuable, but all executable code,
rendering, and (in a rewrite) game-side audio integration is ground-up work.

**One thing was promoted out of it:** the
[GB APU → SPC700 shim](2026-08-06-gb-apu-spc700-shim.md) is worth building on its own
merits, independent of this project.

---

## Appendix: static recompilation, considered and rejected

**Idea considered:** rather than a bespoke rewrite, build an *engine that rewrites
game code* — a tool that ingests a GB ROM and emits a SNES ROM by translating SM83
machine code to 65816, along the lines of static recompilation. Distributed as a
binary, so the legal problem disappears and the work generalizes beyond one game.

**Rejected.** Not because it doesn't work — much of it works better than expected —
but because it is a *larger* project than the rewrite it was meant to shortcut, and
it bypasses this repo's engine entirely.

### The CPU translation is surprisingly viable

Worked in master cycles (1 GB clock ≈ 5.12 SNES master cycles at 21.477 MHz),
assuming FastROM, with the GB register file and HRAM in direct page. Access costs: 6
master cycles fast, 8 slow — note that direct page lives in `$0000–$1FFF`, which is
slow WRAM, so DP ops cost 8 regardless of FastROM.

| GB op | GB | Translated | Result |
|---|---|---|---|
| `LD B,C` | 953 ns | `LDA c_dp : STA b_dp` | **1.95× slower** |
| `ADD A,B` | 953 ns | `CLC : ADC b_dp` | **1.56× slower** |
| `LD A,(HL)` | 1907 ns | `LDA (hl_dp)` | 1.14× faster |
| `INC HL` | 1907 ns | 16-bit `INC dp` | ~even |
| `LD A,n` | 1907 ns | `LDA #imm` | **3.4× faster** |
| `LD (nn),A` | 3815 ns | `STA abs` | **3.2× faster** |
| `JR cc` taken | 2861 ns | `BEQ` | **3.4× faster** |
| `CALL nn` | 5722 ns | `JSR abs` | **3.1× faster** |
| `RET` | 3815 ns | `RTS` | **2.3× faster** |

The GB loses badly on everything that isn't a register-register move, because every
SM83 op is a multiple of 4 clocks at 4.19 MHz while the 65816 has finer granularity.
Aggregate: **roughly break-even, ±30%**, depending on instruction mix.

Two things decide it:

- **Flag liveness analysis is make-or-break.** SM83 has H (half-carry) and N, which
  the 65816 lacks. Materializing them conservatively on every ALU op costs 2–3× and
  kills the approach. Computing only the flags a live consumer actually reads — most
  are dead — gets the table above. Standard dynarec practice, but real compiler work.
- Size and RAM are non-issues: ~60–80 KB of GB code → ~200–300 KB of 65816 in a 4 MB
  ROM; GB's 8 KB WRAM + 8 KB VRAM shadow fit trivially in 128 KB.

Worth recording because it justifies the technique rather than the conclusion:
**interpretation is not an alternative.** An SM83 interpreter dispatch on a 3.58 MHz
65816 costs ~30–50 cycles against a 4–16 clock GB instruction — roughly 5–15% of GB
speed. If you were doing this at all, static recompilation would be the only option.

### The PPU is mostly mechanical

Shadow GB VRAM/OAM/IO in WRAM (8 KB, affordable), flush dirty regions by DMA during
VBlank. You cannot statically prove where `LD (HL),A` points, so shadowing is the
correct answer, not pointer analysis.

- **Tile data is byte-identical** between GB 2bpp and SNES 2bpp. Straight DMA.
- **Tilemaps need byte→word expansion** (DMG has no per-tile attribute byte, so the
  high byte is constant per layer). Full 32×32 re-expansion ≈ 10k cycles ≈ 17% of a
  frame; near-free with dirty tracking, since the game only writes the scrolled-in
  column anyway.
- **OAM:** 40 entries → SNES format ≈ 600 cycles/frame. GB 8×16 sprites become two
  SNES 8×8 each → ≤80 sprites, under 128. Sprites-per-line goes **10 → 32**: strictly
  better.
- **Scroll and palettes** map directly (SCX/SCY → BGxOFS, BGP/OBP → CGRAM).
- **LY/STAT** are synthesizable from the SNES V-counter for VBlank polling, but
  **raster splits are not automatable** — Metroid II's status-bar split needs a
  hand-written HDMA shim. Per-game.

### What actually sinks it

**Static code discovery.** Code and data interleave freely in GB ROMs, and worse:

- **Indirect jumps.** The canonical GB jump-table idiom
  (`ld hl,table : add hl,de : ld a,(hl+) : ld h,(hl) : ld l,a : jp hl`) is
  unresolvable statically. M2RoS literally names `samus_poseJumpTable`; the game is
  full of them.
- **MBC banking.** A call into `$4000–$7FFF` targets whatever bank `$2000` was last
  written with. Sometimes provable by value analysis, often not.

The mitigation is N64Recomp's: emit a runtime GB-PC → SNES-address dispatch for
unresolved targets (sorted table + binary search, ~150 cycles, fine for a few dozen
dispatches per frame). But that only helps for code that was *discovered*. Code
reachable only indirectly needs a fallback interpreter or human iteration — run, trap
"unknown target `$4E:xxxx`", add to the seed list, retranslate.

For Metroid II specifically this is already solved: M2RoS is byte-exact and
hand-labeled, so the code/data separation and jump tables are done, and its segment
structure can be consumed as ground truth. **That is exactly why the generality claim
fails** — the hardest part is pre-solved for this one game and for almost no others.

### Generic vs per-game

| Layer | Generic? |
|---|---|
| SM83 → 65816 translator + flag liveness | **Yes** |
| PPU shadow/flush shim | **Yes** |
| GB APU → SPC700 | **Yes** |
| Entry-point / code discovery | **No** — needs a disassembly or per-game iteration |
| Raster effects, HDMA re-expression | **No** |
| Cycle-counted loops, OAM-DMA timing, HALT-bug reliance | **No** |

Realistic shape: ~90% generic engine + ~10% per-game recipe, where the 10% is where
the months go. Honest framing would be "generic engine, per-game recipe file" — never
"point it at any GB ROM."

### Why it was rejected

- **Not smaller than the rewrite.** Translator core ~3–6 weeks; PPU shim ~2–4; APU
  shim ~4–8; whole-game bring-up open-ended at 2–6 months of whack-a-mole.
  **9–18 months.** A different, larger, more novel project — not a shortcut.
- **It bypasses the engine.** A recompiled GB game touches neither `engine/`, nor the
  VM, nor the asset pipeline. It uses `zasm` as a code-emission backend and nothing
  else. It validates nothing in PLAN.md, and it makes known-risk #1 *worse*: now
  you're building a compiler instead of a game.
- **It forces the wrong viewport.** Translated code computes positions in 160×144 GB
  screen space, so reflowing to 256×224 is impossible without editing game logic.
  Given the viewport decision above, this alone disqualifies it.
- The distribution benefit that motivated it **turns out not to require it** (see
  "Distribution: corrected").

### What survived

Only the [GB APU → SPC700 shim](2026-08-06-gb-apu-spc700-shim.md), and the reason
generalizes: the APU's interface is a 23-register hardware boundary — small, stable,
documented. The CPU's interface is the entire game's control flow. Emulating the chip
is cheap; emulating the machine is not.

(One hybrid was considered and dropped: recompile *only* `bank_004`, the sound engine,
to generate register writes at runtime. It's the best-behaved code in the ROM — self
contained, no PPU interaction, no raster timing. But it still requires most of the
translator core, and capturing the register stream offline gets the same result with
none of it.)

### Prior art

No public GB→SNES static recompiler is known to this investigation, though that was
not exhaustively searched. Super Game Boy solved the problem in hardware, with an
actual DMG SoC on the cartridge. Treat the space as unexplored, with the appeal and
the risk that implies.
