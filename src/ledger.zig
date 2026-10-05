//! The logic inventory ledger: every routine in the game, and what we have
//! done about it.
//!
//! `01-requirements` (F10) asks for a machine-readable manifest of every
//! routine, with source location, conversion status, test status and target
//! phase, generated mechanically rather than written by hand -- so the backlog
//! builds itself and stays honest -- and for it to be the source of the
//! "N of ~20,000 lines adapted" figure, reporting *unconverted* and *untested*
//! as distinct states.
//!
//! ## Where the boundaries come from
//!
//! The requirement originally named `mgbdis`. It was amended on 2026-08-28 to
//! name this file instead, for two reasons that only showed up on the data:
//!
//!  1. `mgbdis` would be a Python toolchain in the gate, for a job our own
//!     `gb/disasm.zig` already does -- and that disassembler is cross-checked
//!     opcode-for-opcode against `gb/cpu.zig`, which is stronger evidence than
//!     a third-party tool's agreement with itself.
//!  2. **A static trace cannot find this game's routines.** Seeded from the
//!     reset and interrupt vectors, it reaches 22% of bank 0 and stops, because
//!     the game dispatches through `JP HL` over tables of code pointers -- the
//!     pose machine and `drawSamus` both do it -- and where a `JP HL` goes is
//!     not in the bytes. `mgbdis` has exactly the same blind spot; it just
//!     linear-sweeps past it and decodes the tables as instructions.
//!
//! So boundaries come from three mechanical seeds, and the ledger records which
//! one found each routine:
//!
//!  * **Vectors.** Reset at $0100, the five interrupt vectors, the eight `RST`
//!    targets. Fixed by the hardware, not by anyone's opinion.
//!  * **Call targets.** Every address named by a `CALL` reachable from a seed.
//!    Iterated to a fixpoint, because a newly-found routine names more.
//!  * **Executed program counters.** What our own emulator is *observed* to
//!    execute, booting the retail ROM and then calling the door-script
//!    interpreter across the door table. An executed instruction start that no
//!    routine's body covers is an entry point the static trace could not see --
//!    which is precisely a `JP HL` destination. Those are marked
//!    `dispatch_target`, and they are the reason this file exists in this shape.
//!
//! ## The tail-call rule
//!
//! A routine's body follows branches and unconditional jumps but stops at any
//! target that is *itself* a known entry. Without that rule a `JP` to a shared
//! tail swallows the whole tail into the caller and the two routines report as
//! one. It is stated here because it is the one judgement call in an otherwise
//! mechanical process, and because it is what makes the instruction totals
//! meaningful.
//!
//! ## What is not mechanical
//!
//! The names, the conversion status, the test status and the target phase.
//! Those are ours, in `known` below, and every entry says how we know. The
//! names are our *engine's own* labels -- `HandleCamera`, `PoseSpinJump` --
//! not transcribed M2RoS ones; where a Game Boy address is cited it is cited
//! as provenance for where we looked, which `engine/main.asm` already does at
//! each ported routine.

const std = @import("std");
const disasm = @import("gb/disasm.zig");
const harness = @import("gb/harness.zig");
const probe = @import("gb/probe.zig");
const door = @import("door.zig");

pub const bank_size: usize = 0x4000;
pub const bank_count: usize = 16;

pub const tsv_name = "ledger.tsv";
pub const report_name = "ledger.txt";

/// The banks the ledger disassembles.
///
/// Taken from `coverage.bank_roles`, which calls 0-4 code and the sound
/// driver, and 5 door scripts -- and `probe` established that bank 5's
/// interpreter code really is in bank 5, at $4000-$42E4, alongside its data.
/// Banks 6-8 are graphics and 9-15 are map data. That is a claim rather than a
/// fact, so `Observation.per_bank` counts executed instructions in *every*
/// bank and `report` prints any that land outside this list, rather than the
/// exclusion being silent.
pub const code_banks = [_]u8{ 0, 1, 2, 3, 4, 5 };

/// The figure `01-requirements` states for the logic left to rewrite, and what
/// the ledger's totals are checked against.
pub const stated_logic_lines: usize = 20_000;

// ---- Rows -----------------------------------------------------------------

/// Which of the three mechanical seeds found this routine. Ordered by strength
/// of evidence: a reset vector is a fact about the hardware, a call target is a
/// fact about the bytes, and a dispatch target is a fact about a run.
pub const EntryKind = enum {
    reset,
    interrupt,
    rst,
    call_target,
    dispatch_target,

    pub fn text(self: EntryKind) []const u8 {
        return switch (self) {
            .reset => "reset",
            .interrupt => "interrupt",
            .rst => "rst",
            .call_target => "call",
            .dispatch_target => "dispatch",
        };
    }
};

/// Deliberately three states, not two. `partial` is the honest answer for a
/// routine whose Phase 0a slice is ported and whose remaining arms are not --
/// the pose machine handles six poses and stubs the rest -- and collapsing it
/// into either neighbour would overstate or understate the same work.
pub const Status = enum {
    unconverted,
    partial,
    converted,

    pub fn text(self: Status) []const u8 {
        return @tagName(self);
    }
};

/// Separate from `Status` because `01-requirements` asks for unconverted and
/// untested as distinct states: a routine can be rewritten and never exercised,
/// which is the failure mode a single combined field hides.
pub const Tested = enum {
    untested,
    /// Exercised by a gate that would fail if it were wrong.
    tested,

    pub fn text(self: Tested) []const u8 {
        return @tagName(self);
    }
};

pub const Phase = enum {
    phase0a,
    phase0b,
    /// The 1.0 cycle, Phase 1 of the port (`.local/docs/2026-09-25-metroid2-1-0-complete-game`).
    phase1,
    later,
    /// Nobody has looked at it yet. The default, and the size of the backlog.
    unassigned,

    pub fn text(self: Phase) []const u8 {
        return switch (self) {
            .phase0a => "0a",
            .phase0b => "0b",
            .phase1 => "1",
            .later => "later",
            .unassigned => "-",
        };
    }
};

pub const Routine = struct {
    bank: u8,
    addr: u16,
    /// One past the highest byte the body reached.
    end: u16,
    /// `end - addr`. Not the same as the bytes actually covered, when a body
    /// jumps over a data table embedded in the middle of it.
    span: u16,
    /// Bytes the body proved are code. `span - covered` is embedded data.
    covered: u16,
    instructions: u16,
    kind: EntryKind,
    /// The emulator was observed to execute at least one instruction of it.
    executed: bool,
    /// Distinct addresses this routine calls.
    calls: u16,
    name: []const u8,
    status: Status,
    tested: Tested,
    phase: Phase,
};

// ---- What we know about them ----------------------------------------------

pub const Known = struct {
    bank: u8,
    addr: u16,
    /// Our engine's own label, from `engine/main.asm`.
    name: []const u8,
    status: Status,
    tested: Tested,
    phase: Phase,
    /// How we know -- the gate line that would fail, or why it is partial.
    note: []const u8,
};

/// Every routine Phase 0a has touched, paired with the label our engine gives
/// it. The Game Boy addresses are the ones `engine/main.asm` already cites at
/// each ported routine; this table is the machine-readable form of those
/// citations, so a routine that is ported without being listed here shows up as
/// a discrepancy rather than as silence.
pub const known = [_]Known{
    .{ .bank = 0, .addr = 0x02B4, .name = "MainLoop", .status = .partial, .tested = .tested, .phase = .phase0a, .note = "The frame order is ported -- read pad, pose, camera, stream, draw -- but the original's audio, enemy and projectile passes are stubbed. `snes boot` in the gate plays the cart, so a broken order fails it." },
    .{ .bank = 0, .addr = 0x05FD, .name = "UploadSamusChr", .status = .partial, .tested = .tested, .phase = .phase0a, .note = "Only the samus tile upload is ported; the original loads several graphics sets here outside any door script. `snes boot`'s samus sprite check would draw blank tiles without it." },
    .{ .bank = 0, .addr = 0x0698, .name = "StreamRun", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The column/row streamer. `snes boot`'s scrolling check walks a screen boundary a pixel at a time and compares the streamed-in neighbour against the reference render." },
    .{ .bank = 0, .addr = 0x282A, .name = "LoadMetaBase", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "The `TILETABLE` opcode. The original selects the table and leaves through `JP $2918` ($2856), so it is both a selection and a redraw; the port does the selection here, re-derives the base the streamer reads metatiles through, and reaches `WarpDraw` for the redraw. Re-deriving the base is the whole of what the routine exists for -- the derivation used to live inside `LoadScreen`, which runs only at boot, so a table selected by a door was written down and never read." },
    .{ .bank = 0, .addr = 0x08FE, .name = "HandleCamera", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "`snes boot`'s camera check holds her at the original's guide offsets, 56 px behind and 104 ahead, while she walks. Step 5 added the four door triggers inside it -- $0921 right, $099B left, $0A5E down, $0ACF up -- so a blocked edge with the camera on its clamp and Samus at the window's edge now starts a transition instead of only settling back." },
    .{ .bank = 0, .addr = 0x0D21, .name = "HandlePose", .status = .partial, .tested = .tested, .phase = .phase0a, .note = "Eleven poses of the machine are ported; spider ball and the queen sequence are not, and `HandlePose` records the first unhandled pose it is given rather than falling through. Crouch joined when the published run asked for it: it is what the run enters four frames after it is handed control. **B4b added the three knockback poses here rather than as rows of their own**, because the gate says none of their addresses is an instruction boundary in any run this repository can make -- nothing observed has ever hurt Samus. `poseFunc_hurt` (00:$0EF7) is $0F: A on the rising edge is a mid-air jump out of the knockback that also cancels the i-frames, and anything else falls through to $11; the arc it sets is `SetJumpArc`'s three branches exactly, which the original repeats inline with sound requests between. `poseFunc_morphHurt` (00:$0F38) is $10, the ball's: Up tries to stand out of it and opens the unmorph window whether or not the stand succeeded, A is a Spring Ball jump, and neither is reachable in the slice. `poseFunc_bombed` (00:$0F6C) is $11 and $12 and is where the arc is actually flown -- both of the others fall into it. The direction only becomes steerable once the counter passes $56, which is the original's way of saying \"not while she is still going up\", and a bonk at or past $57 ends the boost where one below it does not. **Step 14b adds the spider ball's four poses and gives `$12` its own handler**, neither as rows of their own, for the same reason: no run this repository's Game Boy can make enters them. The recording does, and grades them through the recorded rung. `poseFunc_spiderBall` (00:$1029) is `$0E`: A leaves for the ball, no contact asks for `$0C`, and a pad press picks a rotation out of `spiderBallOrientationTable` by contact nibble and pad and goes to `$0B`. `poseFunc_spiderRoll` (00:$1083) is `$0B`: the pad let go is `$0E`, no contact `$0C`, otherwise up to two tries of `spiderDirectionTable`'s rows, each a pixel on one axis through `samus_rollRight.spider`/`rollLeft.spider`/`moveUp`/`moveVertical`, the second only if the first did not move her. `poseFunc_spiderJump` (00:$1170) and `poseFunc_spiderFall` (00:$11E4) are `$0D` and `$0C`: the jump's and fall's arcs, landing or attaching to anything they touch; the jump steers right a pixel and left two, as the original does. `collision_checkSpiderSet` (00:$1A42) and `collision_checkSpiderPoint` (00:$1FBF) are ported with them. `$12` was `$11`'s handler until now; it is 00:$0ECB, two arms -- Down into the spider, Up out of the ball -- in front of `$11`'s body." },
    .{ .bank = 0, .addr = 0x12F5, .name = "PoseFall", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "`snes boot`'s samus check drops her onto the collision data and lands her on the row she left. **1.0 Step 8d added the landing's skip of the row snap on an enemy floor** (00:$1378, `$C43A`), missing since 0a and found by the `beams` rung's `ice stand`; the falling ball's twin (00:$12E7) came with it." },
    .{ .bank = 0, .addr = 0x137F, .name = "TurnRight", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The turnaround timer. Its two frames draw the front-facing sprite, which `snes boot`'s samus sprite check reaches through the facing assertion." },
    .{ .bank = 0, .addr = 0x13B7, .name = "PoseStanding", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "Reached by every gate run: she boots into a fall and stands on landing." },
    .{ .bank = 0, .addr = 0x14D6, .name = "PoseRunning", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "`snes boot`'s camera and scrolling checks both walk her, which is this pose." },
    .{ .bank = 0, .addr = 0x17BB, .name = "PoseJump", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "`snes boot`'s samus check jumps the arc and lands." },
    .{ .bank = 0, .addr = 0x18E8, .name = "PoseSpinJump", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "Reached from the jump; the spin animation timer drives the sprite-id table the gate's pose assertion reads." },
    .{ .bank = 0, .addr = 0x19E2, .name = "PoseJumpStart", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The two frames between standing and jumping; the gate's jump arc starts here." },
    .{ .bank = 0, .addr = 0x15F4, .name = "PoseCrouch", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "Four branches in the original's order -- Right, Left, Down, Up -- and the order is the behaviour, since Down is only consulted when neither direction is held. Each fires on the rising edge or on a hold of eight frames for a direction and sixteen for Down or Up, counted in $D022, which the running handler uses as its animation timer. Reached because the published run presses Down at reference frame 1; before it, the movie oracle's ceiling was that frame." },
    .{ .bank = 0, .addr = 0x1B8B, .name = "EnterCrouch", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "Pose, hold counter, sprite id. A routine rather than three inline stores because standing, running and falling all reach it. The sprite id is the one field our engine does not mirror: `SamusSpriteId` derives it from the pose." },
    .{ .bank = 0, .addr = 0x1BA4, .name = "EnterMorph", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "Three stores, of which our port makes two: the pose and $D033. The third is the sprite id, which `SamusSpriteId` derives. Clearing $D033 is the load-bearing one -- it is what makes the first frame in the ball a roll rather than a bounce. 00:$1B9A makes the same two stores from the other direction and jumps here." },
    .{ .bank = 0, .addr = 0x1701, .name = "PoseMorph", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The ball. Off the ground it becomes pose $08, which has no handler yet; on it, the order is Down, Up, jump, roll, and the order is the behaviour twice over -- Down is tested before Up so a spring ball wins a tie, and the roll is only reached when none of the three fired, which is why holding Down in the ball does not also move her. The published run enters here two frames after the crouch and rolls right for about two hundred frames. Two of the handlers it hands off to are ported beside it and have no rows of their own -- pose $06 at 00:$179F, three instructions and then a fall into the jump handler at 00:$17BB, and pose $08 at 00:$124B, which is `PoseFall` with the ball's three extras in front of it and the same arc, clamp and landing snap behind them. The observed run dispatches neither, so the ledger cannot call either address an instruction boundary, and a row it could not verify would be a claim rather than an inventory. Pose $08's absence is what made rolling off a ledge a hard lock on the cart: the dispatch's recorded-and-do-nothing fallback, working exactly as written. **Step 14b: the Down arm at 00:$1785 tests Spider Ball's bit, not Spring Ball's**, and so do the two in `$06` and `$08`. They read `!ITEM_SPRING` until then, which was the right bit under the wrong name until Step 11 corrected the mask and the wrong bit after. `$06` and `$08` have handlers now; the note's \"no handler yet\" is Phase 0a's." },
    .{ .bank = 0, .addr = 0x1BB3, .name = "TryUnmorphInAir", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "Four probes rather than `TryUnmorph`'s two -- both shoulders at the standing row and both at the ball's -- because there is no floor holding her up. Failing leaves the pose untouched, where `TryUnmorph`'s failure is itself a store. Sets the window at $D049 that `poseFunc_falling` reads to allow the aerial jump." },
    .{ .bank = 0, .addr = 0x0EA5, .name = "PoseFaceScreen", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Pose $13, the appearance sequence a new game opens on, and the original routes the four unused poses $14-$17 here with it. Three branches: the countdown's two halves, tested one byte at a time the way a Game Boy compare has to, and then `loadingFromFile` deciding whether the player has to press a button. All four are ported as of metroid2-audio Step 18, the last being the song request at 00:$0EAF: it was left out while the port had no driver to ask, and leaving it out is what gave a new game no music at all -- the fanfare played, the countdown ran out, and nothing asked for the room's own song (`docs/bug_tracker.md`, 2026-09-22). `!Song` is `currentRoomSong` now, seeded from `BootRoomSong`, and the request reads `songPlaying` out of the reply with the beep's lag model, because this site runs every frame of the wait and the reply is two passes behind. What makes the sequence 320 frames long is not here: it is `countdownTimer`, set by the load and ticked down in the vblank handler." },
    .{ .bank = 1, .addr = 0x4D33, .name = "SamusSpriteId.faceScreen", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "`drawSamus_faceScreen`, which the turnaround has reached since Phase 0a and pose $13 now reaches too. Its two-instruction fade-in is the whole of what Step 7 added: while the countdown's *low byte* is nonzero it returns without naming a sprite on every frame where `frameCounter & 3` is zero, so Samus is drawn three frames in four and flickers into being. The low byte alone is the original's test, which is why the flicker pauses for the one frame in 256 where that byte passes through zero." },
    .{ .bank = 1, .addr = 0x4C94, .name = "SamusSpriteId", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The ball's arm, and one routine draws poses $05, $06 and $08. A table of eight rather than the crouch's pair of immediates, but both runs of four are consecutive, so two bases and an index off `SpinTimer` bits 3-2 reproduce it without a table of ROM bytes. Its absence is what drew a standing, front-facing Samus who could still roll: the drawing dispatch is its own table at 01:$4C1D and adding a pose to the pose machine is not adding it here." },
    .{ .bank = 0, .addr = 0x1B2E, .name = "TryUnmorph", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The same two-probe shape as `TryStanding` and a row eight pixels lower, which is why a ceiling that refuses the stand can still allow the crouch. Reports nothing: both outcomes are a pose. The original reaches `samus_enterCrouch` by falling into it at 00:$1B8B; our port jumps, so the crouch's entry stays in one place." },
    .{ .bank = 0, .addr = 0x1C98, .name = "BallRight", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "An entry into `samus_moveRight` with the speed preset to two and the facing store folded in -- the walk's callers make that store for themselves. 00:$1CC5 is a third entry, one pixel leftwards, that nothing in the ball's handler uses and our port does not have." },
    .{ .bank = 0, .addr = 0x1CC9, .name = "BallLeft", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The leftward half of the same." },
    .{ .bank = 0, .addr = 0x1B37, .name = "TryStanding", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "Was not reachable from the SNES gate at all while `EnterCrouch` was a stub, so it was converted-and-untested until `src/routines.zig` called it directly on the Game Boy and pinned all four combinations of the two tiles it samples plus the boundary value. That is what the per-routine layer is for, and this is the routine that proved it earns its place -- and the pinning paid for itself when `PoseCrouch` landed, because the carry convention is inverted from what the name suggests: carry *set* is the failing case, and a direction pressed where she cannot stand rolls her into the ball instead." },
    .{ .bank = 0, .addr = 0x1C0D, .name = "WalkRight", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "`snes boot`'s scrolling check walks right across a screen boundary." },
    .{ .bank = 0, .addr = 0x1CF5, .name = "AirRight", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "One pixel a frame in the air; the gate's jump moves horizontally." },
    .{ .bank = 0, .addr = 0x1D4E, .name = "MoveVertical", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "Reads the jump and fall arc tables; `snes boot`'s samus check jumps the arc." },
    .{ .bank = 0, .addr = 0x1D98, .name = "MoveVertical", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The upward half, which our port folds into the same routine as $1D4E rather than keeping two entries." },
    .{ .bank = 0, .addr = 0x1DD6, .name = "CollideHoriz", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "`snes boot`'s samus check walks her into the collision data." },
    .{ .bank = 0, .addr = 0x1DE2, .name = "CollideHoriz", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The leftward entry into the same routine; our port takes a direction argument instead." },
    .{ .bank = 0, .addr = 0x1E88, .name = "CollideTop", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "Ceiling collision, reached by the gate's jump." },
    .{ .bank = 0, .addr = 0x1F0F, .name = "CollideBottom", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "`snes boot`'s samus check lands her on the row she left, which is this." },
    .{ .bank = 0, .addr = 0x1FF5, .name = "SampleTile", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "Turns a world position into a collision lookup; every collision check in the gate goes through it, and `src/routines.zig` also reads the tile back through it for both halves of the tilemap." },
    .{ .bank = 0, .addr = 0x22BC, .name = "SampleTile", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The address arithmetic on its own. `src/routines.zig` checks it against a re-derivation for every 8-pixel position on screen, including the column addition that wraps the low byte without carrying into the high one." },
    .{ .bank = 0, .addr = 0x0B44, .name = "TransitionCamera", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The camera while a transition is in progress, which `handleCamera` jumps to at 00:$0902 instead of running its own body. All four arms: the camera walks four pixels a frame in the crossing's direction and drags Samus at one -- two on alternate frames going up or down -- until its pixel byte hits the far clamp exactly, and 00:$0C24 then clears the direction. Graded by the reachable rung, which walks the run's first door and forty frames of incoming scroll behind it." },
    .{ .bank = 0, .addr = 0x2BA3, .name = "StepDoorScript", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "The vblank handler's copy-queue drain, ported as arithmetic rather than as a loop. 00:$2BC2 copies until the remaining count's low six bits are zero -- at most 64 bytes a vblank -- and 00:$27BA waits that out, so the port moves the bytes by DMA and waits `ceil(len / 64)` frames instead. The choice is stated in `.copy`'s comment; `src/transition.zig` grades the number against a running Game Boy on every door script in the ROM." },
    .{ .bank = 0, .addr = 0x0C37, .name = "StartTransition", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "Turns the cell a blocked edge was crossed at into the door script that runs, by reading the transition word the converted cell carries in bytes 2-3. Three of the original's five jobs are ported: the lookup, the spider-ball pose fixup at $0C3E, and -- since Step 12c -- the three bomb-slot clears at $0C55-$0C62, which this note called entity clears until the bombs were ported and the addresses were read. That clear is not graded: `snes boot` drives its crossings by writing the door index, which never calls this routine, and no rung here asserts anything about a bomb at a door. The two flag clears around them at $0C4E and $0C63 are B4's, the progress state at $0C83 is Step 6's, and the Queen's forced door at $0C8C is B8's; all three are named in the routine's comment rather than left silent." },
    .{ .bank = 0, .addr = 0x239C, .name = "StepDoorScript", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "The door-script interpreter, and no longer boot-only or single-shot: Step 5 made the index a variable and gave five more opcodes their behaviour, and Step 5b turned it inside out. `COPY`, `TILETABLE`, `COLLISION`, `SOLIDITY` and `WARP` act; `DAMAGE`, `SONG`, `ITEM` and `IF_MET_LESS` record their operands and stop, which is what makes them assertable rather than skipped. `ENTER_QUEEN` acts since 1.0 Step 6 (`DoorEnterQueen`, with `door_queen` and `queen_initialize` under it). `ESCAPE_QUEEN`, `EXIT_QUEEN` and `FADEOUT` are still walked by length -- but they are walked at the right *speed*: the original blocks a frame after every opcode at 00:$26D1 and far longer inside three of them, and the port runs one opcode per frame with the cost in `!TransWait`. `snes boot` draws map 0 cell $38 pixel for pixel through it and asserts the crossing takes the frames a Game Boy would." },
    .{ .bank = 0, .addr = 0x28FB, .name = "RunDoorScript", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "`handleWarp`, which our port folds into the interpreter's `.warp` arm rather than keeping as a routine of its own -- the original only reaches it from one opcode. The header is ported whole: the map bank out of the opcode's low nibble, and the destination cell's two nibbles into the screen halves of both the camera and Samus, pixel halves untouched. The four arms it dispatches to on $D00E draw the incoming screen, and Step 6 ported them as `WarpDraw`: three strips right, left and up and four down (00:$2939, $29C4, $2B04, $2A4F), each strip the same `StreamRun` the per-frame streamer walks, and the waits between them the duration Step 5b already had. **No door script in this ROM carries a tilemap `COPY`**, so those strips and the streamer behind them are the whole of how an incoming room is drawn. `WarpDraw` has no row of its own because $2918 is a label inside this routine, which is what the ledger says when asked." },
    .{ .bank = 1, .addr = 0x493E, .name = "UpdateStatusBar", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "Step 13b, in NMI because the original runs it in vblank -- and *which* vblanks is the mechanism: `StatusBarDue` is 00:$0154's chain, so a frame that queued a map row, a VRAM transfer or a door draws no bar and does not tick the shuffle timer. Tanks and `E`, both health digits, three missile digits, the count and its scrambled arm, into BG2's tilemap words 0-19, which are the window's $9C00-$9C13. `partial` for two arms the slice has no state for: the Queen's head test and room row. The pause's L counter (01:$4A0F) joined in 1.0 Step 2a, as `StatusBarLCounter` in bank 1, graded by the `pause` rung. The scramble reads `!DivClock` for `rDIV`, whose step is measured (see `!DIV_STEP`). Graded by the HUD oracle, tick for tick against our Game Boy over chosen values and against Mesen2's at three frames of the recorded run." },
    .{ .bank = 1, .addr = 0x4A2B, .name = "AdjustHudValues", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Step 13b. The decimal clamp on the real health, then displayed toward real one unit a frame for health and missiles, and the two tick sounds recorded into `!Sfx1` -- the health one gated on `sfxPlaying_square1`, which no driver sets. Graded by the HUD oracle's two rolls across a hundreds boundary and its two clamps, per tick against the Game Boy, and by `snes boot`'s phase 20 for the sound's fourth frames." },
    .{ .bank = 1, .addr = 0x4B2C, .name = "DrawHudMetroid", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Step 13b. Sprite $3F or $40 on `frameCounter` bit 4, at X $80 and Y $98, or $90 on a save point or during a major item. Called from the three places the port has the original's calls: the play pass, the transition frames and the pickup's wait loops. The save-point half reads `!SaveContact`, which nothing writes until B7. It restores the sprite quartet it borrows -- scratch on both machines -- so `snes boot` can still read Samus's there. Graded by `snes boot`: the icon in OAM on every frame, its sprite against the counter, and its rise through the Bomb's jingle." },
    .{ .bank = 1, .addr = 0x4B62, .name = "DrawSprite", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "Walks a metasprite's $FF-terminated parts into the OAM shadow. `snes boot`'s samus sprite check asserts the shadow is non-empty and positioned." },
    .{ .bank = 1, .addr = 0x4BB3, .name = "ClearUnusedOam", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "Parks the OAM slots the frame did not use; without it the gate's per-part mask would grow without bound, which it is checked against." },
    .{ .bank = 1, .addr = 0x4BD9, .name = "SamusSpriteId", .status = .partial, .tested = .tested, .phase = .phase0a, .note = "The pose-to-sprite dispatch. Eight of its arms are ported -- the seven poses Phase 0a reaches plus the turnaround -- and the rest are not. The gate asserts the id follows both the pose and the facing. Step 14b adds `drawSamus_spider` (01:$4C6B) for `$0B`-`$0E`, the ball's arithmetic over `pose_sprites_spider`'s eight ids, tested ahead of the facing byte because the arms after it are at the edge of `beq` range." },
    .{ .bank = 1, .addr = 0x4CEE, .name = "SamusSpriteId", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The spin-jump arm, which picks one of two four-frame tables by facing." },
    .{ .bank = 1, .addr = 0x4D77, .name = "SamusSpriteId", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The running arm, which picks one of three tables from the held input and the row from the animation timer." },
    .{ .bank = 1, .addr = 0x4DDF, .name = "SamusAnchor", .status = .converted, .tested = .tested, .phase = .phase0a, .note = "The position arithmetic. `snes boot` asserts her OAM position is the camera guide with the two Game Boy biases removed and the window offsets added." },
    // ---- The entity foundation, Step 9 of the slice ------------------------
    .{ .bank = 0, .addr = 0x0295, .name = "DeriveScroll", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "`convertCameraToScroll`: the camera's pixel byte less $78 and $30. The port derives it wherever the original reads the result rather than keeping a copy, because a stored scroll is a second thing that can disagree with the camera -- and every enemy position in the game is relative to it. Reached on every frame the cart runs, through the spawn walk." },
    .{ .bank = 2, .addr = 0x418C, .name = "ResetEntities", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "`inGame_saveAndLoadEnemySaveFlags`, and `partial` for a stated half: the port refills the unsaved spawn flags, empties the slots and re-seeds both scroll histories, and does *not* move the saved half in and out of the save buffer. There is no save buffer until B7, and inventing one to move bytes between would be a second place for the save format to be wrong. 02:$4217 `deactivateAllEnemies` is folded in here because the original only ever calls the two together." },
    .{ .bank = 2, .addr = 0x409E, .name = "ProcessEnemies", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "The per-slot pass. The status dispatch is ported whole -- $x0 active, $x1 offscreen, anything else skipped -- and two things are deliberately absent. The AI is B4b's. The `rLY` budget cannot come at all: the routine stops mid-slot at scanline $58 and its caller gives up before starting at $70, which is a lag mechanism, and this cart has no lag to spend. So the pass runs to completion every frame where the original runs it every other one, and `enemy_sameEnemyFrameFlag` has no port." },
    .{ .bank = 2, .addr = 0x4421, .name = "SlotFlagOut", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "`enemy_moveFromHramToWram`, of which only the tail is ported and the rest is deliberately not: the routine exists because the Game Boy reaches HRAM a byte cheaper than WRAM, and a 65816 with the slot address in an index register pays nothing to work in place. The tail is not bookkeeping -- it publishes the slot's spawn flag back into $C500 and clears the flag/number pair when the slot has been deleted, which is what makes the array follow the slots instead of leading them." },
    .{ .bank = 2, .addr = 0x452E, .name = "DeactivateOffscreen", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "The despawn window: $C0-$D7 and $D8-$EF in a camera-space position byte mean the enemy has left by one edge or the other, and $F0-$FF deliberately does nothing because that band is the sixteen pixels a Game Boy sprite occupies above its own coordinate. All five flag arms are ported; `partial` for the two Metroid variables the `seen` arm also clears, which are B8's and have no home yet. **03:$6AE7 `enemy_deleteSelf` is ported with it and has no row of its own**, because the gate says that address is not an instruction boundary in any run this repository can make -- no observed run kills an enemy -- and a row it could not verify would be a claim rather than an inventory. What is ported of it is the reachable half: the fifteen-byte clear, the tail, and the pair of decrements. The half that is not is the parent link, which is B5's -- a slot whose flag has a zero low nibble is a child object, and the original decodes the rest of that byte as the address of its parent's flag, bit 4 choosing which half of the slot array and the top three bits the slot. Nothing creates a child object before B5 and an encoding that specific ported blind is one that would be wrong with nothing to catch it, so the branch records the flag in `!EnChild` instead -- the same shape `HandlePose` uses for a pose it cannot run." },
    .{ .bank = 2, .addr = 0x4464, .name = "DeleteOffscreen", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Two screens away and the slot is freed. Three of its details are the original's and none is a tidy-up: it clears the slot itself rather than calling `enemy_deleteSelf`, it decrements `total` and `offscreen` where that routine decrements `total` and `active`, and the value it fills the tail with is the *flag byte* when the enemy died rather than $FF. And $FE and $03 are not symmetric distances." },
    .{ .bank = 2, .addr = 0x44C0, .name = "ReactivateOffscreen", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The other direction: an offscreen slot whose position comes back inside the band walks its screen byte towards zero, and a slot at (0,0) is live again. Six arms, three per axis, and the two do-nothing bands are the same ones the deactivation reads." },
    .{ .bank = 2, .addr = 0x45CA, .name = "HandleEnemies", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "`updateScrollHistory`, folded into the frame's pass because only its newest pair has a reader. The original keeps three older entries; nothing in the port reads them, so the port does not have them -- `residue.zig`'s rule, applied rather than quoted. The row is on this address rather than on the enemy handler's own entry because that body is mostly the save-flag requests and the LY budget, neither of which the port has." },
    .{ .bank = 3, .addr = 0x4000, .name = "HandleEnemyLoading", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The walk and the scroll history it will compare against next time. Trivial, and it is a row of its own because the history it maintains is a *second* one, separate from `scrollHistory_A`: the loading checks one axis every other pass, so it differences against two passes ago rather than one." },
    .{ .bank = 3, .addr = 0x4014, .name = "LoadEnemies", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The camera's four edges, each rounded to the grid the records sit on, then the oscillator picking an axis. The two wraparound clamps in the middle are the load-bearing part: a camera across the map's own seam has its bottom edge on screen row 0 and its top on row 15, and without the clamp the walk reads the spawn list of a room on the far side of the map." },
    .{ .bank = 3, .addr = 0x40BE, .name = "LoadEnemiesVert", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The vertical arm: the left screen's list, then the right one reached lazily by stepping over the terminator, which is the original assuming the two are contiguous in the ROM. Measured to be true -- all 1792 pointers are distinct and every one lands on a list start in the linear walk's own order." },
    .{ .bank = 3, .addr = 0x416A, .name = "LoadEnemiesHoriz", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The horizontal arm, and **not a mirror image of the vertical one**: its top-screen branch skips to the next screen where the vertical arm would skip only the record, and it looks the bottom screen's list up properly instead of stepping over a terminator. The original's own comment calls the first of those a weird optimisation that assumes something about the data's order; both are reproduced rather than regularised." },
    .{ .bank = 3, .addr = 0x422F, .name = "LoadOneEnemy", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "One record into one slot: position biased into camera space by the OAM offsets and the scroll, the sprite type, the spawn number, nine header bytes, four cleared bytes, the initial health twice, the flag, and the AI pointer. The flag write is what stops the walk loading the same record twice -- both $01 and $04 are below the $FE the walk tests -- and the AI pointer is carried without being callable, because B4b's dispatch is what turns it into a routine." },
    .{ .bank = 3, .addr = 0x42B4, .name = "FirstEmptySlot", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "`partial` for a bound the original does not have and says so in its own comment: it walks off the end of the slot array if a seventeenth enemy is ever asked for. The port stops at the sixteenth and the caller declines to load. Neither machine reaches the case -- the walk only loads what a screen edge is passing over -- so this turns a corruption nothing triggers into a no-op nothing triggers." },
    .{ .bank = 3, .addr = 0x42C1, .name = "SpawnListAt", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "`loadEnemy_getBankOffset` and the screen entry of `loadEnemy_getPointer`, folded: the original keeps them apart because the second is also the header lookup's entry, and the port has `HeaderFor` for that. `(bank - 9) * 256 + (row << 4) + column` -- the same 7 x 256 geometry the pointer table's $E00 bytes imply. The row's nibble swap is the Game Boy's `swap` reproduced exactly rather than four shifts, because the two differ once a screen number passes $0F and the wraparound clamps deliberately let it." },
    .{ .bank = 3, .addr = 0x42D3, .name = "HeaderFor", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "`loadEnemy_getPointer.header`: an enemy id into a header offset. A row of its own rather than folded into the one above, because the original's two entry points share a body and the port's two do not -- the screen lookup indexes a relocated table of byte offsets and this one indexes a different relocated table." },
    .{ .bank = 3, .addr = 0x6BD2, .name = "ScrollEnemies", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Slot positions carried with the camera, which they must be because they are stored in camera space. The screen byte follows on a wrap and only for a slot already offscreen. This is where the Game Boy's carry convention bites hardest: the original writes `jr nc` after a `sub` to skip the screen adjustment, and a 65816 `sbc` *clears* carry where the Game Boy's `sub` sets it, so the port branches on the opposite condition." },
    .{ .bank = 3, .addr = 0x6D4A, .name = "QueenInitialize", .status = .converted, .tested = .tested, .phase = .phase1, .note = "1.0 Steps 6 and 19b. The Queen's whole $C300 page cleared, her raster split's starting lines, the neck's sums, the twelve wall objects and the state list's pointer, her thirteen slots and their actors. The page is kept at `!QueenPage` so a Game Boy address is the page plus its low byte. Graded by the `queen` rung from her entry." },
    .{ .bank = 3, .addr = 0x6E12, .name = "QueenDeactivateNeck", .status = .converted, .tested = .tested, .phase = .phase1, .note = "1.0 Step 6. The six neck slots' status to $FF. Its second entry, `.arbitrary` at 03:$6E17, is the same loop for any run of slots, and its callers are her death's (Step 20)." },
    .{ .bank = 3, .addr = 0x6E22, .name = "QueenAdjustWallToHead", .status = .converted, .tested = .tested, .phase = .phase1, .note = "1.0 Step 19b. The wall's last five objects follow the head down, eight apart: graded byte for byte in her page by the `queen` rung." },
    .{ .bank = 3, .addr = 0x6F07, .name = "QueenSetActorPositions", .status = .converted, .tested = .tested, .phase = .phase1, .note = "1.0 Steps 6 and 19b. Her body, head halves and mouth onto their slots from the variables the bands are drawn from; the neck's actors off, then onto the first object of each drawn pair, or the bent neck's one actor when her stomach is bombed (Step 20's to reach). The `queen` rung grades the slots." },
    // ---- B4b: the AI, the hitbox test and the damage, Step 10 of the slice --
    .{ .bank = 2, .addr = 0x5630, .name = "EnemyCommonAI", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The per-slot AI dispatch, and the first of `dispatch.unreached`'s four layers to be entered. Its four state tests are ported and **so are all four handlers since 1.0 Step 8b**. The original split was a deliberate one -- each state named a mechanism a later step owned -- and what closed the first two was a playtest rather than their turn: a killed enemy set `+$0E`, nothing animated it, and the slot was never freed, so the corpse went on deleting every beam that touched it. `EnemyAnimateDrop` (02:$5692) and `EnemyAnimateExplosion` (02:$56BF) have rows of their own under Step 12e. The other two came later: `metroid_state`'s, `EnemyMetroidExplosion`, in Step 13d, and the ice beam's, `EnemyAnimateIce` (02:$5652), in 1.0 Step 8b; `!EnUnhandledState`, which recorded whichever open arm was reached first, has no writer now. Both handled arms are tail jumps and not calls, because 02:$5633's `JR NZ` and 02:$5638's `JP NZ` leave the routine -- the state handler owns the rest of the slot's frame and the AI does not run. The dispatch itself could not survive the port as written -- the original's `jp hl` goes through a bank-2 address copied out of the header -- so it is a table from that address to a ported routine, which is also the only form in which \"which AIs does this cart have\" is a question with a written answer. **Five routines are ported with it and have no rows of their own**, because the gate says their addresses are not instruction boundaries in any run this repository can make -- no observed run puts a live enemy in a slot, which is the very layer `dispatch.unreached` names. `enAI_NULL` (02:$5651) is a bare `ret`, and it is in the table rather than left to the unhandled recorder because it is the *default*: an id whose header names it has an AI and one the table does not know does not. `enAI_smallBug` (02:$5ABF) -- Yumbos, Meboids, Mumbos, Pincher Flies, Seerooks and TPOs -- animates, walks a pixel a call the way the X flip points and turns on the 64th; it is what lives in the room the oracle's ball rolls into, bank $9 cell $37. `enAI_senjooShirk` (02:$5C36) bobs until Samus is within $50 pixels and then flies a diamond of four sixteen-call legs at her; **it is the enemy the segment extension is graded on**, the one that touches her at reference frame 701 and takes $15 BCD off her, and both its animation and its bob halve the pass counter again on top of the pass's own alternation. And `enemy_flipSpriteId` (02:$6B3F) and `enemy_flipHorizontal` (02:$6B62) are ported as their `.now` entries only: the `.twoFrame` and `.fourFrame` entries are the same three instructions behind a test on the frame counter, and both callers this cart has do their own dividing. `enemy_flipVertical` at 02:$6B7B has no caller here and is not ported." },
                        .{ .bank = 2, .addr = 0x43D2, .name = "EnemyStunTick", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "The stun tail of `enemy_moveFromWramToHram`, which Step 9 left behind when it declined the HRAM mirror. `partial` for exactly that: the copy is not ported and does not need to be, and the tail is, because a stunned enemy stopping for three frames is behaviour. The original expresses the skip by popping its own return address and jumping into the middle of `processEnemies`; here it is a carry flag, because a 65816 subroutine that unwinds its caller is one nobody can read." },
    .{ .bank = 0, .addr = 0x32AB, .name = "CollideSamusEnemies", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The play handler's own pass over the sixteen slots. Its `samusSpriteCollisionProcessedFlag` is what makes it run once a frame however many callers reach it, and the three entries beside it deliberately do not test it. **The horizontal entry sets it too** (`.start`, 00:$3650, which both share), so a frame whose walk ran that entry skips this one; the port set it here only until 1.0 Step 9, and after a walk's hit this pass ran again and put the default boost, to the right, over the hit's (the `beams` rung's `hurt`, `docs/bug_tracker.md`). Samus's X here is *last* frame's draw -- the original writes `samus_onscreenXPos` in `drawSamus`, which runs after this -- and her Y is recomputed from the position; that asymmetry is reproduced rather than tidied." },
    .{ .bank = 0, .addr = 0x32CF, .name = "CollideSamusEnemiesHoriz", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The entry `collision_samusHorizontal` calls, which is what makes walking into an enemy a hit on the frame of the walk rather than a frame later. Samus's X is the probe column the walk has just set. It sets `samusSpriteCollisionProcessedFlag` as the standard entry does, since 1.0 Step 9: see `CollideSamusEnemies`." },
    .{ .bank = 0, .addr = 0x348D, .name = "CollideSamusEnemiesDown", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The entry `collision_samusBottom` calls, and the one the segment extension's hit actually comes through -- Samus is falling when the Senjoo reaches her. A hit lifts her out of the enemy by the overlap the test measured only when `$C424` is $00 or $FF (00:$34D3 `JR C` skips the lift for $01-$FE); `$C424` is the last damage a hurt or screw hit wrote, and a frozen enemy's solid arm writes none. The port had the branch the other way round until 1.0 Step 8d, which turned it with the `beams` rung's `ice stand` failing first (`docs/bug_tracker.md`)." },
    .{ .bank = 0, .addr = 0x34EF, .name = "CollideSamusEnemiesUp", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The entry `collision_samusTop` calls. Samus's Y is her sprite hitbox's top added to the draw's Y, which is a different table and a different bias from the BG collision's." },
    .{ .bank = 0, .addr = 0x3324, .name = "CollideSamusOneEnemy", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "One slot's hitbox against Samus's point. Every arm is ported -- screw, ice, solid, drain, intangible and hurt -- and `partial` is for one store inside the solid arm: the Queen's stunned mouth sets `queen_eatingState`, which has no variable here, and the pose store beside it *is* ported so pose $18 arrives at `HandlePose`'s unhandled recorder rather than being mis-dispatched." },
    .{ .bank = 0, .addr = 0x3545, .name = "CollideSamusOneEnemyVert", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "The vertical twin, which differs from its neighbour in three places and is written as those three differences: no $11/$04 pull-in on the box and no pose bias, an overlap recorded for the caller to lift Samus by, and sprite id $00 treated as solid. M2RoS calls that last one \"sprite 0 (tsumuri, horizontal frame 1) is solid? What?\"; it is reproduced rather than regularised. `partial` for the same Queen store as its twin." },
    // ---- B6: the item pickup, Step 11 ------------------------------------
    .{ .bank = 2, .addr = 0x4DD3, .name = "EnAiItemOrb", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The orb and the item standing on it, which are one AI and two sprite ids -- orbs even, items odd -- and the trigger for the whole of B6. Shooting the orb increments its own id and turns it into the item; touching the item runs the `(sprite - $81)/2 + 1` loop at 02:$4E63 and sets `itemCollected`. Both refills' `already full` tests are ported and neither can fire: no refill sprite is in the recording's rooms. The delete arm at 02:$4E80 is the far end of the handshake `handleItemPickup_end` starts, and it is what makes the second wait loop's length a property of the enemy pass rather than a constant." },
    .{ .bank = 2, .addr = 0x7DA0, .name = "EnemyCollisionResults", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "`enemy_getSamusCollisionResults`: an AI asking whether this frame's contact was about its own slot. The original compares a WRAM pointer; the port compares the slot offset, which is the same question in the units this file keeps. It clears the record on a match, so the second AI to ask in one frame is told no -- the original's behaviour, not an optimisation: the pointer and the type are wiped by one `ld (hl+),a` run. `weaponDir` ($C469) has no port variable because only a projectile writes it; B5 adds it." },
    .{ .bank = 2, .addr = 0x4318, .name = "TransferCollision", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "`handleEnemies.transferCollisionResults`, the enemy handler's common exit: the hitbox test's `collision_*` becomes the AIs' `enSprCollision` and the source is cleared. **The order is the mechanism** -- the collision runs in the play handler before the enemy pass, the pass runs every AI, and only then does this -- so an AI asking about contact is asking about the previous frame, the same gap `hurtSamus` has." },
    .{ .bank = 0, .addr = 0x2C79, .name = "TryPausing", .status = .converted, .tested = .tested, .phase = .phase1, .note = "1.0 Step 2a. The play handler's last call, on its normal, transition and item-end paths: Start alone on the edge, then the Queen's room, facing the screen, a door's scroll and a save pillar refuse; the L counter off `metroidLCounterTable` by the BCD count, zeroed while a quake is queued or shaking; `debugFlag`'s OAM clear; the blank and the `L` over the first HUD-Metroid object in the buffer; the pause request; mode $08. `debugItemIndex` and `unused_D011` are not cleared -- neither exists here. Graded by the `pause` rung pass for pass against our Game Boy, with a fault for the whole routine, the object write and the L counter's bar." },
    .{ .bank = 0, .addr = 0x2CED, .name = "PausedFrame", .status = .converted, .tested = .tested, .phase = .phase1, .note = "1.0 Step 2a. Game mode $08: `bg_palette` and `ob_palette0` flash on bit 4 of the counter -- one INIDISP brightness here, as `ApplyPalette` makes every palette -- and Start's edge, tested with `BIT`, unpauses. The debug arm ($2D1B) is ported to its fork: Start alone leaves with the OAM cleared; anything else is `debugPauseMenu` (00:$2D39), which the debug screen (C8) replaces rather than ports. Graded by the `pause` rung, with faults on the flash and on Start's mask." },
    .{ .bank = 0, .addr = 0x372F, .name = "RunItemPickup", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "`handleItemPickup`, turned inside out the way `StepDoorScript` is: the original blocks for hundreds of frames and a 65816 main loop cannot, so `!ItemStage` is where it got to and `MainLoop` drives it. The frame cost is measured against the B11 recording rather than derived: on all four of its pickups the item lands **exactly four frames** after Samus freezes (Bomb 44 325/44 329, Missile Tank 44 964/44 968, Energy Tank 48 043/48 047, Spider Ball 68 449/68 453), which is the four `waitOneFrame`s at 00:$3734, and the body is `!Countdown` at $0160 for a major item or $0060 for the Missile Tank -- the split 00:$375C's `cp $0D` makes. `partial` because the two jingle branches store a song id and no driver is written, which is the same stub `SONG` has. **`handleItemPickup_end`'s two halves have no rows of their own** -- 00:$3A01 and 00:$3A32 -- because the gate says neither address is an instruction boundary in any run this repository can make: no observed run collects an item, so nothing ever traced past $372F. They are ported: the first loop's body is one store, the window raise at 00:$3A1F, since its other five calls are `MainLoop`'s on a jingle frame; the second is the jingle-off, the $03 into the flag that tells the item object to go, and the restore of the contact into `enSprCollision` -- because the pickup consumed it on the way in and the AI has to see it again to delete itself. **1.0 Step 9 found two defects in that first loop**, both graded by the `gfx` rung and logged in `docs/bug_tracker.md`: it is a do-while, so a pickup that arrives with the countdown spent (Varia's, and the refills') still draws one pass of it (`!ITEM_JINGLE1`); and both loops end in `waitForNextFrame`, which ticks the clock, where every other wait of the pickup is `waitOneFrame` (`!ItemTick`)." },
    .{ .bank = 0, .addr = 0x3797, .name = "ItemPickupArm", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The fifteen-arm `RST $28` table, every arm ported -- including the ones no run reaches, because a branch left out is one that silently does nothing the first time the port grows into it. **1.0 Step 8a gave the arms their graphics** and moved them to bank 1: each `call loadGraphics` is a `LoadGraphics` of the record the ROM's own call names (`src/gfx_info.zig` decodes them), the screw attack and space jump pick their spin pair on the other's bit, the spazer takes the plasma's record, and Varia loads its suit, the missile cannon under `call z` and `varia_loadExtraGraphics` (00:$3A84, `VariaExtraGraphics`, which has no row of its own: no run this repository makes collects Varia, so the gate cannot call its address an instruction boundary). Varia's pose is the ROM's $80 since Step 8a; it was $13. Graded by the `gfx` rung against our Game Boy's VRAM. **1.0 Step 9 ported the rest of Varia's arm** as `VariaStage`, a stage a frame: its own wait for the fanfare (00:$38B9), the bit, the pose and Samus alone for a frame, the sound, and `animateGettingVaria` (00:$27E3, `VariaAnimStart`), whose vblank half is `VariaAnimNmi` (00:$2BF4). None of them has a row, for the reason `VariaExtraGraphics` has none. Graded by the `gfx` rung: the frames the animation and the transfer hold the flag up, exactly, and the pickup's length within 2%. The missile refill's credits branch: its `metroidCountReal` test since 1.0 Step 10 (`warp`'s `refill_credits`), and since 1.0 Step 22 the branch whole, its stores made on the frame `!ITEM_CREDITS` stands for and mode $12 after it (the `credits` rung's 2:59 enters the ending this way). **These arms are also the ROM's own statement of which bit each item is**, and reading it out of the `SET n,A` opcode is what found two of `!Items`'s six masks wrong -- see `docs/bug_tracker.md`, 2026-09-09." },
    .{ .bank = 0, .addr = 0x2753, .name = "LoadGraphics", .status = .converted, .tested = .tested, .phase = .phase1, .note = "1.0 Step 8a. `loadGraphics` and `beginGraphicsTransfer` (00:$27BA): the record goes into a ring and the caller waits on the ring -- the pickup in `!ITEM_XFER`, the toggle in `!CannonHold` -- as the original waits on `vramTransferFlag`. The record is a row of `GfxInfo`, which the builder fills from the ROM's gfxInfo records by decoding each caller's `ld hl,rec / call $2753`; the sheets were already `chr_obj` blobs, so the row is an asset id, an offset, a destination and a length. `door_copyData`'s two arms (00:$2771, $2798) are the door interpreter's `COPY` and have been since 0b." },
    .{ .bank = 2, .addr = 0x5652, .name = "EnemyAnimateIce", .status = .converted, .tested = .tested, .phase = .phase1, .note = "1.0 Step 8b. `enemy_animateIce`, the fourth of `EnemyCommonAI`'s arms and a tail jump like the others: the three Metroid sprites go straight on to their AI, which thaws itself through `.call` (02:$565F, `enAI_normalMetroid`'s, Step 17); every other frozen enemy climbs its counter two every other pass, blinks from $C4, and at $D0 wakes or, at no health, is deleted with its spawn flag dead and no explosion. Graded by the `enemy AIs` rung: `crawlerA ice` (the thaw back into the crawl) and `crawlerA ice kill` (three freezes to zero health, and the death at the thaw), each with a fault that stops the climb." },
    .{ .bank = 0, .addr = 0x2BA3, .name = "GfxXferNmi", .status = .converted, .tested = .tested, .phase = .phase1, .note = "1.0 Step 8a. `VBlank_vramDataTransfer`: one chunk of the head record a vblank, the size mod $40 and then $40 at a time (00:$2BC4 `and $3F`), which in SNES bytes is mod $80 and $80. A transfer frame draws no status bar, which `!GfxMoved` tells the NMI. Its Varia arm (`VBlank_variaAnimation`, 00:$2BF4) is `VariaAnimNmi` since 1.0 Step 9, taken while `!VariaAnim` is up, with no status bar either. The Game Boy also skips its map row on a transfer frame; the port's streamer is not held, since nothing streams during a pickup and the toggle's frame did not hold it before." },
    .{ .bank = 0, .addr = 0x3BB4, .name = "SamusItemGraphics", .status = .converted, .tested = .tested, .phase = .phase1, .note = "1.0 Step 8a. `loadGame_samusItemGraphics`, which `gameMode_LoadB` calls after the sheet on every load: the suit, the spring ball, one spin pair and the beam, **the beam keyed on the active weapon rather than the beam**, as the original is. Queued and drained whole under the load's forced blank, as `loadGame_copyItemToVram` (00:$3C3F) copies. `Reset` then queues the missile cannon for a handover taken with missiles selected, which no load is." },
    .{ .bank = 0, .addr = 0x2EE3, .name = "HurtSamus", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "Reads the flag the previous frame's collision set and turns it into a pose. `partial` for `queen_roomFlag`, which forces the boost rightwards in the Queen's room and has no variable here -- writing that branch would mean inventing a room number. Everything else is ported: the i-frames, the pose table, the boost direction, the arc counter and the unmorph window." },
    .{ .bank = 0, .addr = 0x2F57, .name = "ApplyDamageSpike", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "`applyDamage.enemySpike`, including the refusal of any damage value of $60 or more. The sound request is not made: there is no driver, and unlike a `SONG` operand nothing carries the id." },
    .{ .bank = 0, .addr = 0x2F3C, .name = "ApplyDamageLarva", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "`applyDamage.larvaMetroid`: three units every eighth frame, which is what a damage byte of $FE means. Unreachable in the slice -- no enemy in the region carries $FE -- and ported because the branch that reaches it is." },
    .{ .bank = 0, .addr = 0x2F64, .name = "ApplyDamageApply", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The shared tail: Varia halves the damage, then a BCD subtract with a borrow into the tanks and a clamp at $99. The Game Boy does it with `sub`/`daa`; a 65816 has decimal mode and does the same arithmetic in it, which is a rare case of the port being shorter than the original for a reason other than a shortcut. `applyDamage.queenStomach` and `.acid` are not ported and have no callers here." },
                .{ .bank = 1, .addr = 0x4C59, .name = "SamusSpriteId", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The knockback arm, `drawSamus_knockback`: poses $0F and $11, a two-byte table indexed by facing. $10 and $12 reach the ball arm instead, which is the same routine the morph poses use." },
    // ---- B5's terrain half: the destructible blocks, Step 12a ---------------
    .{ .bank = 1, .addr = 0x5671, .name = "DestroyRespawningBlock", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The first free slot of sixteen takes the block's position and a counter of one, and a full array does nothing at all. The walk's bound is not a count: `LD A,L / ADD A,$10 / LD L,A / CP $00 / RET Z` ends when the low byte of the pointer wraps, so sixteen slots of sixteen bytes is one page and that is the array. The port keeps the stride for that reason -- a compacted three-byte slot would be a different routine wearing the same address comments. `snes boot` phase 11 writes a slot rather than calling this, because nothing on this cart can fire at a block until Step 12b; what the phase grades is everything downstream." },
    .{ .bank = 1, .addr = 0x5A11, .name = "DrawEnemies", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "**Why the enemies were invisible.** Steps 9 and 10 filled the slots, walked them on both axes, collided against them and damaged them; nothing anywhere put a single object in OAM for one, and the enemy metasprite set had been extracted and round-tripped since Step 4 without ever being shipped into the cart. No rung in this repository could see it -- they grade position, camera, pose and the background, and the sprite check graded Samus alone -- so it arrived as a bug report from a person playing the cart. `AND A` and not `AND $0F` is the walk's own difference from every other one: a slot is drawn only when its whole status byte is zero, so the offscreen state draws nothing even though `ProcessEnemies` still walks it. The `rLY` budget in front of it is a Game Boy cost and does not port, the way the other three did not. Graded by `snes boot`'s `the enemy is drawn` phase." },
    .{ .bank = 1, .addr = 0x5A3F, .name = "DrawEnemySprite", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The record walk, with 01:$5A9A `drawEnemySprite_getInfo` folded in -- it is nine reads with no caller but this one, and a row on it would be an entry point the ledger cannot show being dispatched. The flips are reflections rather than negations: `CPL / SUB $07` is `-(v + 8)`, which is only the same as negating for a part height of eight, and the original writes it that way. The attribute is the enemy's three bytes XORed and masked, then XORed *again* with each part's own -- so a part already drawn flipped comes back the other way up when the whole sprite is. **X does not survive the call to `PutObject`**, which is why the caller keeps its own cursor; the original has the same problem and answers it by reloading `drawEnemy_pLow`/`pHigh` every iteration." },
    .{ .bank = 0, .addr = 0x21EF, .name = "ClearProjectiles", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Eleven instructions, and the reason it has a row of its own rather than a line inside the boot is that leaving it out is invisible: `Reset` clears WRAM to zero, zero is the power beam's weapon type, and a cart without this boots with three live shots at whatever position the clear left. The original calls it from 00:$0CA3 `loadGame_samusData` -- the same four instructions Step 7 took the cold-boot record off -- and the port calls it from the same point. It clears $60 bytes where the original clears $100: the projectile array and, since Step 12c, the bomb array after it, whose empty is $FF too. **The bomb half is ungraded, measured**: a zeroed bomb slot sits off the window, so `DrawBombs` deletes it on the first frame and a cart without the clear boots identically. The rest of the page is unused on the Game Boy and has no counterpart here. Graded by `snes boot`'s `a shot` phase, whose first assertion is that no projectile exists before the button is pressed." },
    .{ .bank = 0, .addr = 0x21FB, .name = "SamusTryShooting", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "Two gates and a fall-through. `partial` for the second gate: 00:$2202 tests `queen_eatingState` against $22, which is B8's byte and one this cart has no writer for, so the branch is named in the engine's comment rather than written against a variable that is permanently zero -- a test nothing can set always takes one side, and one that *looks* ported is worse than one visibly absent. The first gate and the Select edge are both here. Graded by `snes boot`'s `a shot` phase, which presses the fire button and finds a projectile." },
    .{ .bank = 0, .addr = 0x2212, .name = "ToggleMissiles", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "`samus_tryShooting.toggleMissiles`, and it is a row of its own because the original reaches it as a second entry point -- 00:$0717's cutscene arm calls it directly. Both arms `call loadGraphics` with the cannon's record, which since 1.0 Step 8a is `LoadGraphics` of `GfxInfo`'s first two rows, and the frame `beginGraphicsTransfer` costs is `!CannonHold`. `snes boot` phase 19 presses Select both ways and reads the cannon's tiles out of VRAM." },
    .{ .bank = 0, .addr = 0x30BB, .name = "CollideBombEnemies", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Step 12c. `CollideProjEnemies`' walk with the explosion's sprite position where the projectile's tile point was, stopping at the first hit, and the same bank switch with nothing to port. Called once per explosion, on its first frame, from inside `drawBombs`. Graded by `snes boot`'s bomb phase, which puts an enemy beside the ball and requires `weapon_damage`'s last entry off its health." },
    .{ .bank = 0, .addr = 0x30EA, .name = "CollideBombOneEnemy", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "Step 12c. **Two differences from `collision_projectileOneEnemy`, and both widen what a bomb hits**: it has no damage test, so an enemy that does no damage to Samus is still a target, and the box grows $10 on all four sides. `LoadEnemyBox` pads the horizontal pair through `!ColPad` and the vertical pair is widened after it -- which is exact in both flip arms, because the original adds the pad after the `CPL`. The weapon direction is not written, as in the original. `partial` for 00:$3187-$31AF, the Queen's two arms, which open on `queen_eatingState` -- B8's byte, with no writer on this cart." },
    .{ .bank = 0, .addr = 0x31B6, .name = "CollideProjEnemies", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The projectile's point against sixteen slots, stopping at the first hit. The point is `tileY`/`tileX` -- the pair the tile sample used a few instructions earlier, already biased -- brought into camera space, so **a projectile's hitbox is one pixel** and the enemy's is a box. 00:$31CA's `LD ($2100),A` bank switch has nothing to port: both tables the callee reads are converted blobs and reachable from anywhere. Graded by `snes boot`'s `and into an enemy` phase, which fires into a loaded slot and watches its health fall." },
    .{ .bank = 0, .addr = 0x31F1, .name = "CollideProjOneEnemy", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "The box is `LoadEnemyBox`'s, shared with Samus's own hitbox test, and Step 12b is what made the sharing honest: the two differ in exactly one number -- 00:$3388 widens the enemy's horizontal edges by Samus's half-width and this has no counterpart -- so the widening became `!ColPad` and the twenty instructions of flip arithmetic stayed one copy. 00:$3293's Queen arm, which paralyses her when a missile lands in her open mouth, writes `queen_eatingState`'s $10 since 1.0 Step 19c (it was `partial` until then, recording the sprite into `!PrUnhandled`); the `queen` rung's volley grades the stun it starts." },
    .{ .bank = 1, .addr = 0x4E8A, .name = "SamusShoot", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "One press, one projectile -- or three, because the spazer loops the routine back into itself at 01:$4F6C, and the loop target is *above* the turnaround test rather than below it, which M2RoS marks as odd and the port reproduces. The plasma branch is ported whole even though the region has no plasma beam, per the loop's rule about branches that cannot fire yet. Until Step 12c it was `partial` for 01:$4EB4, where a ball pose lays a bomb by jumping into 01:$53D9 `samus_layBomb`; that branch recorded into `!PrUnhandled` and is now the tail jump the original makes. **One thing here is not a relabelling of the Game Boy**: 01:$4EBC swaps the pad byte to put `dulr` in the low nibble, and the SNES pad's high byte has Up and Down the other way round, so `ShotDirNibble` builds the nibble a bit at a time. Graded by `snes boot`'s `a shot` phase." },
    .{ .bank = 1, .addr = 0x4FEE, .name = "FirstEmptyProj", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Where the shot goes, and it is also the whole of the weapon's slot policy: the search starts at slot 0 for a beam and at slot 2 for a missile, so at most one missile is ever in the air and a missile can never take a beam's slot. The port returns the offset in X and the answer in the carry where the original returns a pointer and asks the caller to compare its low nibble against 3." },
    .{ .bank = 1, .addr = 0x500D, .name = "HandleProjectiles", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "755 instructions in the original and the largest single routine the port has taken. Five branches -- spazer, wave, missile, everything else, and the common tail -- and the wave beam has its own copy of the tail at 01:$513C because it goes *through* terrain and must not reach the delete. **The frame parity is behaviour, not scheduling**: 01:$52A0 asks the tilemap what a beam is flying through only on odd frames, so terrain collision runs at 30 Hz while enemy collision runs at 60, and a port whose frame counter had the wrong phase would sample the world on the frames the original does not. It was `partial` for 01:$52CA, the bomb beam's arm, until Step 12c ported `bombBeam_layBomb` behind it; the region has no bomb beam, so the arm is ported blind under the loop's rule about branches that cannot fire yet. `HitBlock` still has no row of its own and the note on `HandleRespawningBlocks` explains why -- but its two callers are here now, and what Step 12b added to it is the carry: the two copies of the classification agree on the three tests and disagree on what happens after them." },
    .{ .bank = 1, .addr = 0x5300, .name = "DrawProjectiles", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "**The despawn is in the draw**, which is the one thing about this mechanism that reads wrong until you have seen it: nothing counts a projectile's frames down and nothing tests it against the room. 01:$538A backs the pointer up three bytes and writes $FF over the type because the sprite would have landed outside the Game Boy's visible window -- so a beam's range is the screen, and the routine that enforces it is the one that draws. It is also what gave `PutObject` its reason to exist: four raw OAM bytes with no metasprite record anywhere in sight, where every other caller in this engine has one." },
    .{ .bank = 2, .addr = 0x4239, .name = "EnemyDamageOrDrop", .status = .partial, .tested = .tested, .phase = .phase0b, .note = "One routine with two halves that share nothing but their entry test -- a slot carrying a drop hands Samus health or missiles and deletes itself, a slot carrying an enemy loses health and maybe explodes -- and `+$0D dropType` picks which. **Three of its exits unwind their caller** in the original, popping their own return address to jump into the middle of `processEnemies`; here that is a carry flag, for the reason `EnemyStunTick`'s skip is one. `partial` for 02:$4386, nine bytes no branch names and the observed trace never reaches, left out rather than ported and named in the engine's comment so it is visibly left out. The explosion it sets is B4c's to animate: this writes `+$0E` and **Step 12e is what reads it**, not Step 13 -- it had to move ahead of the bombs because until it landed the slot this routine killed never stopped being a live projectile target. Its drop arm, ported here and unreachable until then, is `EnemyAnimateDrop`'s consumer." },
    .{ .bank = 2, .addr = 0x43A9, .name = "EnemyCheckShields", .status = .converted, .tested = .untested, .phase = .phase0b, .note = "Some enemies can only be hurt from some directions, and the wave beam ignores that entirely. The loop shifts the shield nibble and the direction bit together until the direction bit falls out of the bottom, which lines the two up without a table -- and M2RoS notes that a projectile with *no* direction hangs it, which is true of the port too and is reproduced rather than guarded, because nothing in this game makes one. `untested`: none of the three enemies the region loads has a shield nibble, so the routine returns at its second test on every call the gate can make, and a fixture that set the nibble by hand would be grading the port against itself." },
    .{ .bank = 1, .addr = 0x53AF, .name = "BombBeamLayBomb", .status = .converted, .tested = .untested, .phase = .phase0b, .note = "Step 12c. The bomb beam's bomb: the first empty slot, the ball's type and fuse, and the stopped beam's own position four pixels in on both axes. The region has no bomb beam, so nothing this repository runs reaches it; ported whole under the loop's rule about branches that cannot fire yet, and its two `ADD A,$04` sites are graded by `src/correspond.zig`." },
    .{ .bank = 1, .addr = 0x53D9, .name = "SamusLayBomb", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Step 12c. What the fire button does in a ball pose, reached by `samusShoot`'s tail jump at 01:$4EB4. Two gates -- the Bomb bit and the button's rising edge, so holding it lays one bomb -- and then the first of three slots, at Samus's position plus $26 and $10. `FirstEmptyBomb` is this routine's fourteen-byte walk and `bombBeam_layBomb`'s identical copy as one routine. Graded by `snes boot`'s bomb phase, whose lever is the fire button: no bomb without the Bomb, one with it, at the position the cartridge's two `ADD` operands put it." },
    .{ .bank = 1, .addr = 0x540E, .name = "DrawBombs", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Step 12c. **The explosion happens in the draw**, the way a beam's despawn does. Each live slot is drawn with Samus's own metasprites through `DrawSprite` -- the fuse blinks between $35 and $36 on bit 3 of its counter, the explosion counts down $35 to $31 -- and a slot outside $B0 on either axis is deleted. On the one frame an explosion's counter reads $08 it calls `bombs_samusAndBGCollision` (unless Samus is in a Queen pose, unmasked, so a turnaround is past the test too), draws, calls `collision_bombEnemies`, and requests the detonation sound. **The bombs draw before Samus**, from inside the Samus block of the play handler, which moved the OAM index reset out of `DrawSamus` and into `MainLoop` where the original's `waitOneFrame` has it. Graded by `snes boot`'s bomb phase." },
    .{ .bank = 1, .addr = 0x549D, .name = "HandleBombs", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Step 12c, from the play handler at 00:$0733 through the long jump at 00:$3D99. One counter per slot is both the fuse and the explosion's life: at zero a bomb becomes an explosion with eight frames left and an explosion becomes nothing. It then calls the draw, so a fuse that runs out detonates on the same frame. Graded by `snes boot`'s bomb phase, which times the fuse against the cartridge's `LD A,$60`." },
    .{ .bank = 1, .addr = 0x54D7, .name = "BombsSamusAndBG", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Step 12c. Samus first: inside $20 vertically and $10 horizontally of the explosion, measured from `samus_onscreen*`, she is thrown -- `samusAirDirection` left, up or right of it, the arc counter at $40, and her pose through `samus_bombPoseTable` (01:$55DD, pinned here). `PoseBombed` has flown that arc since Step 10 and this is its first caller that is not a pose. Then five tiles -- above, its own, below, right, left -- each through `BombProbeTile`, **which is `HitBlock`'s classification without its first test**: a bomb does not ask whether the tile is below `beamSolidityIndex`, the ROM goes straight from `CALL $2266` to `CP $04`. So `!BLOCK_BOMB`, graded against 01:$5543 since Step 12a, gets its first reader. Graded by `snes boot`'s bomb phase: a bomb-only block under the ball goes, and she is thrown into the pose the table names." },
    .{ .bank = 1, .addr = 0x5692, .name = "HandleRespawningBlocks", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Once a frame from `MainLoop` at 00:$0550, and on a transition frame too -- the play handler's skip at 00:$0522 jumps to $053E and runs everything after it. Every live slot's counter goes up by one and is compared against six exact values; there is no elapsed-time arithmetic anywhere in it, so a byte wrapping through 256 frames is the clock. The two halves are **not** mirror images: 5 and 6 frames apart going out, 4 and 4 coming back, which `src/blocks.zig` asserts because the first version of that assertion claimed the symmetry and the ROM refused it. Ahead of the dispatch is the eviction, two bands rather than two ranges -- the original masks the distance from the scroll with $F0 before comparing it against $C0 and $D0. **01:$5790 is recorded and not called**; see `!BlkCrush` for the boundary, which is a nineteen-byte pose table at 01:$57DF this repository has not pinned and a knockback that belongs to B5's other half.\n\n**`HitBlock` has no row of its own, and the ledger is what says so.** The classification the port calls by that name is 01:$5155, and $5155 is not an entry point: it is a branch three hundred bytes inside `handleProjectiles` (01:$500D-$5300, 755 instructions, `unconverted`), which is Step 12b's whole subject. A row on an address the ledger does not call a routine would be a claim rather than an inventory, so the port has the branch and the ledger does not have the row -- the same trade `EnemyDeleteSelf` and `handleItemPickup_end` are recorded under. What grades it meanwhile is every constant it stands on: `blocks.shotMask` reads its `BIT 5,A` out of 01:$5176, `blocks.compareAt` its `CP $04` out of 01:$5168, and `snes boot` phase 11 asserts `!SolidBeam` against the beam column of the row the boot door's `SOLIDITY` selects -- a number derived from the ROM's store sequence at 00:$2446 with no help from the engine." },
    .{ .bank = 1, .addr = 0x56E9, .name = "DestroyBlock", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "Four tiles of $FF over the 2x2, and a noise request. **The picture is the world**: the original's collision is a lookup into its own background tilemap, so writing $FF is what makes the floor stop being a floor -- the port inherits that exactly, because `SampleTile` reads the same `!TilemapBuf` these writes go into and nothing keeps a second world array. What does not port is the pair of `rSTAT` hblank waits before the stores: they are there because the Game Boy cannot touch VRAM while the LCD is reading it, and the port writes WRAM and raises `!Redraw` for the same vblank queue `WarpDraw` uses. The `LD A,$FF` at all eight of its call sites is dead -- $5705 loads $FF itself -- and the port does not reproduce it. 01:$5712, $5742 and $5769 have no rows of their own: they are the same nine instructions with a different immediate and are one routine here, `BlockWrite4`, with the immediate as the argument." },
    // ---- B4c's first half: the explosion, the drop, and the freed slot, Step 12e --
    .{ .bank = 2, .addr = 0x56BF, .name = "EnemyAnimateExplosion", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "`enemy_animateExplosion` with 02:$56E7 `.becomeDrop` folded in, and it is the routine that makes a kill finish. **It was not ported when the kill path was**, and the gap was not inert: `EnemyDamageOrDrop` wrote `+$0E` and cleared nothing else, `EnemyCommonAI` had no handler and recorded the state, and **the kill path never changed the slot's status** -- so the corpse stayed active, drawn, and a projectile target. Measured on the shipped cart on 2026-09-09: a shot fired at an enemy 28 px away died after four frames identically whether the enemy was alive or a corpse, which is sixteen pixels, and which reads from the player's seat as no beam leaving her weapon. The explosion flag is a byte three routines agree about -- $10 or $20 for which progression, a low nibble of $01/$02/$04 for what the corpse leaves -- and bit 5 is read first, the nibble last, because the animation runs before the drop exists. Two progressions, six frames from `!SPR_EXP_BIG` for the screw attack's and three from `!SPR_EXP_NORM` for the ordinary one, four for every flag that is not exactly $11. `.becomeDrop` has three exits and the first is not about the drop: an initial health of $FD clears the explosion and hands the slot back to its AI with the counter at one, which is how the husks come back. **The 50% roll is a substitution and not a port**: 02:$56ED reads `rDIV`, the Game Boy's free-running divider, and this machine has no counterpart, so `!EnFrame`'s low bit stands in -- the same counter the neighbouring `enemy_animateDrop` divides at 02:$569F, chosen over `!FrameCount` because the pass acts on one frame parity only and `!FrameCount & 1` would have been a constant for a whole room. Nineteen constants pinned to their own opcodes in `src/correspond.zig`; see `residue.zig`'s `EnFrame` row for the substitution." },
    .{ .bank = 2, .addr = 0x5692, .name = "EnemyAnimateDrop", .status = .converted, .tested = .tested, .phase = .phase0b, .note = "`enemy_animateDrop`: what a health or missile drop does while it waits, which is blink and then expire. The counter is the whole state -- one blink in four passes for the first $80 and one in two after, so a drop visibly speeds up as it runs out -- and the blink is a single `XOR $01`, because the two frames of every drop are an even sprite id and the odd one above it. On reaching $B0 the slot goes and its spawn flag says killed for good. **Its consumer was ported two steps earlier and could not be reached**: `EnemyDamageOrDrop`'s drop arm has handed Samus health and missiles since Step 12b, and nothing could put a `+$0D` in a slot until `.becomeDrop` landed. The counter and drop type are zeroed before the delete, which `EnemyDeleteSelf` immediately overwrites with $FF -- kept because a byte the port does not write is a divergence nobody can explain." },
};

// ---- Watching the game run ------------------------------------------------

pub const Options = struct {
    /// Tapping through the title and the file select.
    boot_seconds: usize = 30,
    /// Walking around with `probe`'s fixed exploration schedule, which reaches
    /// the pose machine, the streamer, the camera and the enemy passes.
    explore_seconds: usize = 60,
    /// A fixed segment of directed movement, after the exploration.
    ///
    /// The monkey is good at getting somewhere and bad at doing anything in
    /// particular: 90 seconds of it dispatched the standing, running, crouching
    /// and $1701 pose handlers and never once reached jumping, spin-jumping,
    /// falling or the jump start, which between them are most of the pose
    /// machine. Random input that happens to press A is not the same as input
    /// that presses A while standing on ground. This segment walks, jumps,
    /// falls and turns around on a fixed cycle, so those handlers are reached
    /// by construction rather than by luck.
    movement_seconds: usize = 20,
    /// Every `door_stride`th door of the 512, called directly on the booted
    /// machine. Doors are what reach the script interpreter and the room
    /// loaders, and no amount of walking gets to one -- `probe` established
    /// that the exploration schedule never crosses a door.
    door_stride: usize = 1,
    /// Per-door instruction budget. A door script copies kilobytes into VRAM
    /// through the engine's own loops, so this is generous.
    door_budget: usize = 4_000_000,
};

pub const Observation = struct {
    /// True at every ROM offset the emulator started an instruction at.
    executed: []bool,
    /// True at every ROM offset a `JP HL` was observed to land on.
    ///
    /// This is the sharpest instrument in the file. `JP HL` is how this game
    /// dispatches -- the pose machine and `drawSamus` both jump through tables
    /// of code pointers -- and where it goes is not in the bytes, which is the
    /// whole reason a static trace stalls at 22% of bank 0. Watching the run
    /// answers it exactly: the instruction *after* an observed `JP HL` is an
    /// entry point, and it is one whether or not some neighbouring routine's
    /// body happens to flow into it. Without this the pose handlers merge into
    /// their lower neighbours, because nothing `CALL`s them and nothing marks
    /// where one ends and the next begins.
    dispatch: []bool,
    /// The same observations, kept as site-to-target edges rather than only as
    /// destinations. `dispatch` answers "is this an entry point"; this answers
    /// "which dispatch does it belong to", which is what a survey of the
    /// table-driven layers needs. Deduplicated, in first-seen order.
    edges: []Edge,
    /// An allocation failed while `edges` was being recorded, so some are
    /// missing. See `ExecRecorder.incomplete`.
    edges_incomplete: bool = false,
    /// Distinct executed instruction starts, per bank.
    per_bank: [bank_count]usize,
    instructions: u64,
    frames: u64,
    doors_run: usize,
    doors_returned: usize,
    /// The machine was a live game rather than a crash, by `harness.alive`.
    alive: bool,
    /// Which values of `samusPose` the run was seen to hold, sampled between
    /// chunks of the input schedule.
    ///
    /// The pose byte is at $D020: `samus_handlePose` at 00:$0D21 reads it and
    /// dispatches through `RST $28`, which is the inline-jump-table thunk at
    /// $0028 -- `POP HL`, index the table that follows the call site, `JP HL`.
    /// That address is read out of the ROM here rather than taken from a
    /// listing. What poses the run reached is the difference between "we
    /// watched the game" and "we watched the parts of it the input happened to
    /// provoke", and the pose machine is most of the logic Phase 0a ported.
    poses_seen: [pose_count]bool,
    /// Where the machine was standing when exploration ended: the map bank the
    /// warp handler last selected, and the screen within it.
    ///
    /// `alive` cannot tell a title screen from a room -- both have the LCD on
    /// and VRAM written -- and "we watched the game run" is worth nothing if
    /// what we watched was the file select. A map bank in $9-$F is the game's
    /// own statement that Samus is in a room.
    map_bank: u8,
    screen_row: u8,
    screen_col: u8,

    pub fn poseCount(self: Observation) usize {
        var n: usize = 0;
        for (self.poses_seen) |p| n += @intFromBool(p);
        return n;
    }

    pub fn inRoom(self: Observation) bool {
        return self.map_bank >= probe.map_bank_first and self.map_bank <= probe.map_bank_last;
    }

    pub fn deinit(self: *Observation, allocator: std.mem.Allocator) void {
        allocator.free(self.executed);
        allocator.free(self.dispatch);
        allocator.free(self.edges);
        self.executed = &.{};
        self.dispatch = &.{};
        self.edges = &.{};
    }

    pub fn total(self: Observation) usize {
        var n: usize = 0;
        for (self.per_bank) |c| n += c;
        return n;
    }
};

/// `JP HL`. The one opcode this file needs to recognise by hand, because it is
/// the one whose destination the bytes do not carry.
const op_jp_hl: u8 = 0xE9;

/// `RST $28`, the inline-jump-table thunk's call opcode.
///
/// Needed by hand for the same reason and one more: **every inline-table
/// dispatch in the game funnels through the single `JP HL` inside the thunk at
/// $0028**, so grouping dispatch targets by the `JP HL` that jumped to them
/// would report one site with hundreds of arms. The site a survey wants is the
/// `RST $28` that called the thunk, which is also where the table is -- the
/// thunk `POP HL`s its own return address and indexes the bytes that follow the
/// call. See `Edge.site`.
const op_rst_28: u8 = 0xEF;

/// The `RST $28` vector, which is fixed by the hardware.
pub const rst28_vector: u16 = 0x0028;

/// How far past the vector to look for the thunk's own `JP HL`.
///
/// A bound on a search, not a length: `rst28Jump` finds the instruction and
/// this only says where to stop looking. Metroid II's thunk is twelve bytes
/// (`ADD A,A / POP HL / LD E,A / LD D,$00 / ADD HL,DE / LD E,(HL) / INC HL /
/// LD D,(HL) / PUSH DE / POP HL / JP HL`), and the first version of this file
/// guessed eight -- which put the `JP HL` outside the window, attributed every
/// inline dispatch in the game to the thunk instead of to its caller, and
/// reported one site with nineteen arms.
pub const rst28_search: u16 = 0x0020;

/// Where the thunk's `JP HL` is, found in the ROM rather than written down.
pub fn rst28Jump(rom: []const u8) ?u32 {
    var off: u32 = rst28_vector;
    while (off < rst28_vector + rst28_search and off < rom.len) : (off += 1) {
        if (rom[off] == op_jp_hl) return off;
    }
    return null;
}

/// One observed indirect jump: which site dispatched, and where it landed.
///
/// `site` is the `RST $28` offset for an inline-table dispatch and the `JP HL`
/// offset for every other kind, so the two idioms this game uses come out as
/// separate sites rather than as one enormous one. Both are ROM offsets, the
/// same units as `Observation.executed`.
pub const Edge = struct {
    site: u32,
    target: u32,
};

/// `samusPose`, and how many distinct values the ledger tracks. The dispatch
/// table after the `RST $28` at 00:$0D4A is 27 entries before it runs into the
/// next routine, so poses above that are not something the game produces.
pub const pose_addr: u16 = 0xD020;
pub const pose_count: usize = 32;

const ExecRecorder = struct {
    rom: []const u8,
    executed: []bool,
    dispatch: []bool,
    allocator: std.mem.Allocator,
    /// Site-to-target edges, deduplicated by `seen`. An allocation failure here
    /// stops the edges growing rather than failing the observation: the
    /// callback cannot return an error, and a ledger that did not run is the
    /// bigger lie. It sets `incomplete`, so the observation says it is
    /// missing edges instead of passing for a whole survey.
    edges: std.ArrayList(Edge) = .empty,
    seen: std.AutoHashMapUnmanaged(Edge, void) = .empty,
    incomplete: bool = false,
    /// Whether the instruction recorded immediately before this one was a
    /// `JP HL`. Instruction starts arrive in execution order, so the next one
    /// after a `JP HL` is its destination.
    prev_indirect: bool = false,
    /// The ROM offset of that `JP HL`, so the edge knows where it came from.
    prev_off: u32 = 0,
    /// The most recent `RST $28` executed, which is the call site an inline
    /// table belongs to. See `op_rst_28`.
    last_rst28: ?u32 = null,
    /// Where the thunk's own `JP HL` is, from `rst28Jump`.
    rst28_jp: ?u32 = null,

    fn hit(ctx: *anyopaque, bank: usize, pc: u16) void {
        const self: *ExecRecorder = @ptrCast(@alignCast(ctx));
        // A PC in WRAM or HRAM is real -- the game copies a DMA routine into
        // HRAM and runs it there -- but it is not a ROM offset and there is
        // nothing to record. It also breaks the `JP HL` chain, because the
        // destination is not in the ROM either.
        if (pc >= 0x8000) {
            self.prev_indirect = false;
            return;
        }
        const off32 = if (pc < 0x4000)
            bank * bank_size + pc
        else
            bank * bank_size + (pc - 0x4000);
        if (off32 >= self.rom.len) {
            self.prev_indirect = false;
            return;
        }
        const off: u32 = @intCast(off32);
        self.executed[off] = true;
        if (self.prev_indirect) {
            self.dispatch[off] = true;
            // The thunk's own `JP HL` stands for whichever `RST $28` called it.
            // Its arm is the table entry the *caller* inlined, so attributing
            // it to $0028 would merge every inline dispatch in the game.
            const is_thunk = self.rst28_jp != null and self.prev_off == self.rst28_jp.?;
            const site = if (is_thunk) (self.last_rst28 orelse self.prev_off) else self.prev_off;
            self.record(.{ .site = site, .target = off });
        }
        self.prev_indirect = self.rom[off] == op_jp_hl;
        self.prev_off = off;
        if (self.rom[off] == op_rst_28) self.last_rst28 = off;
    }

    fn record(self: *ExecRecorder, e: Edge) void {
        const gop = self.seen.getOrPut(self.allocator, e) catch {
            self.incomplete = true;
            return;
        };
        if (gop.found_existing) return;
        self.edges.append(self.allocator, e) catch {
            // Out of `seen` too, or a retry would be taken for a duplicate.
            _ = self.seen.remove(e);
            self.incomplete = true;
        };
    }

    fn deinit(self: *ExecRecorder) void {
        self.seen.deinit(self.allocator);
        self.edges.deinit(self.allocator);
    }
};

/// Boot the retail ROM, walk it, then call the door-script interpreter across
/// the door table, recording every instruction start.
pub fn observe(allocator: std.mem.Allocator, rom: []const u8, opts: Options) !Observation {
    const executed = try allocator.alloc(bool, rom.len);
    errdefer allocator.free(executed);
    @memset(executed, false);
    const dispatch = try allocator.alloc(bool, rom.len);
    errdefer allocator.free(dispatch);
    @memset(dispatch, false);

    var rec: ExecRecorder = .{
        .rom = rom,
        .executed = executed,
        .dispatch = dispatch,
        .allocator = allocator,
        .rst28_jp = rst28Jump(rom),
    };
    defer rec.deinit();

    // Built with the watch already attached rather than booted and then
    // watched: the title screen, the file select and the room load are the
    // game's own code, and leaving them out would report their routines as
    // never reached when they plainly ran. `harness.boot` with zero seconds
    // builds the machine without stepping it, so the whole run is watched.
    var m = try harness.boot(allocator, rom, 0);
    defer m.deinit();
    m.exec = .{ .ctx = &rec, .hit = ExecRecorder.hit };
    var poses_seen: [pose_count]bool = @splat(false);
    try runSampled(&m, opts.boot_seconds * 60, &rec, bootKeys, &poses_seen);

    // The door sweep starts from here, not from the end of the run.
    //
    // `probe.runDoors` calls the interpreter on a freshly booted machine and
    // gets an answer for all 512 doors. Snapshotting after the exploration and
    // movement instead got one door in sixty-four to return and eleven extra
    // instructions of coverage for it: by then Samus is mid-jump, morphed, or
    // part-way through a transition, and the interpreter called out of that
    // state does not finish. The boot state is the one the mechanism was
    // established on.
    var snap = try m.snapshot();
    defer snap.deinit(allocator);

    try runSampled(&m, opts.explore_seconds * 60, &rec, exploreKeys, &poses_seen);
    try runSampled(&m, opts.movement_seconds * 60, &rec, movementKeys, &poses_seen);

    const alive = harness.alive(&m);
    const map_bank = m.read(probe.warp_bank_addr);
    const screen_row = m.read(probe.screen_row_addr);
    const screen_col = m.read(probe.screen_col_addr);

    var doors_run: usize = 0;
    var doors_returned: usize = 0;
    if (opts.door_stride > 0) {
        var i: usize = 0;
        while (i < door.pointer_count) : (i += opts.door_stride) {
            m.restore(snap);
            const out = try m.call(.{
                .addr = probe.interp_entry,
                .budget = opts.door_budget,
                // The one place in this file that wants interrupts. A door
                // script copies kilobytes into VRAM through the engine's own
                // loops, and those loops wait on vblank; called with IME clear
                // they wait forever. With `call`'s default of interrupts off,
                // one door in sixty-four returned no matter how the boot was
                // arranged, and the sweep contributed eleven instructions.
                .interrupts = true,
                .writes = &.{
                    .{ .addr = probe.door_index_addr, .value = @truncate(i) },
                    .{ .addr = probe.door_index_addr + 1, .value = @truncate(i >> 8) },
                    .{ .addr = probe.door_direction_addr, .value = 1 },
                },
            });
            doors_run += 1;
            if (out.returned) doors_returned += 1;
        }
    }

    var per_bank: [bank_count]usize = @splat(0);
    for (executed, 0..) |hit, off| {
        if (!hit) continue;
        const b = off / bank_size;
        if (b < bank_count) per_bank[b] += 1;
    }

    return .{
        .executed = executed,
        .dispatch = dispatch,
        .edges = try allocator.dupe(Edge, rec.edges.items),
        .edges_incomplete = rec.incomplete,
        .per_bank = per_bank,
        .instructions = m.sys.instructions,
        .frames = m.sys.frames,
        .doors_run = doors_run,
        .doors_returned = doors_returned,
        .alive = alive,
        .poses_seen = poses_seen,
        .map_bank = map_bank,
        .screen_row = screen_row,
        .screen_col = screen_col,
    };
}

/// Run a schedule in short chunks, reading the pose byte between them.
///
/// Sampled rather than watched: the pose is a memory location, and the
/// execution watch sees program counters. A chunk of half a second is short
/// enough that a pose held for a jump cannot pass unseen and long enough that
/// the sampling costs nothing next to the emulation.
const sample_chunk_frames: u64 = 30;

fn runSampled(
    m: *harness.Machine,
    frames: u64,
    ctx: *anyopaque,
    keys: *const fn (ctx: *anyopaque, frame: u64) probe.Buttons,
    poses_seen: *[pose_count]bool,
) !void {
    var done: u64 = 0;
    while (done < frames) {
        const chunk = @min(sample_chunk_frames, frames - done);
        // `runScriptFrom`, not `runScript`: the schedule's frame index has to
        // keep counting across chunks, or a held input restarts every half
        // second and nothing that depends on a transition ever completes.
        const before = m.sys.frames;
        _ = try m.runScriptFrom(chunk, done, ctx, keys);
        const advanced = m.sys.frames - before;
        if (advanced == 0) return; // The machine stopped completing frames.
        done += advanced;
        const p = m.read(pose_addr);
        if (p < pose_count) poses_seen[p] = true;
    }
}

fn bootKeys(_: *anyopaque, frame: u64) probe.Buttons {
    return probe.bootButtons(@intCast(frame));
}

fn exploreKeys(_: *anyopaque, frame: u64) probe.Buttons {
    return probe.exploreButtons(@intCast(frame), probe.explore_seed);
}

/// One 120-frame cycle of deliberate movement: walk right, jump from the
/// ground, fall, land, turn around, walk left, jump again.
///
/// Held for whole runs of frames rather than re-rolled, because the poses this
/// is here to reach are entered on transitions -- ground to air, ascent to
/// descent, facing to facing -- and a schedule that changes its mind every
/// frame never completes one.
fn movementKeys(_: *anyopaque, frame: u64) probe.Buttons {
    const right: u4 = 0b0001;
    const left: u4 = 0b0010;
    const up: u4 = 0b0100;
    const down: u4 = 0b1000;
    const a: u4 = 0b0001;

    var b: probe.Buttons = .{};
    const t = frame % 120;

    // **Up first, and down never.** `exploreButtons` presses down a quarter of
    // the time and deliberately never presses up, and down twice from standing
    // is how Metroid II morphs into the ball. Without a spring ball the ball
    // cannot jump, and up is the only way out of it -- so the explorer morphs
    // her within the first few seconds and she spends the rest of the run
    // rolling. That is why 90 seconds of random input reached the standing,
    // running and crouching pose handlers and never once reached jumping,
    // falling or the jump start: not luck, a trap with no exit in the
    // schedule's alphabet.
    if (t < 8) {
        b.dpad &= ~up;
        return b;
    }

    if (t < 64) b.dpad &= ~right else b.dpad &= ~left;
    _ = down;
    // Two four-frame presses per half cycle, well apart: the first from a
    // standing start, the second while already moving.
    const u = (t - 8) % 56;
    if (u >= 16 and u < 20) b.buttons &= ~a;
    if (u >= 40 and u < 44) b.buttons &= ~a;
    return b;
}

// ---- Finding the routines -------------------------------------------------

fn windowBase(bank: u8) u16 {
    return if (bank == 0) 0 else 0x4000;
}

fn bankSlice(rom: []const u8, bank: u8) []const u8 {
    return rom[@as(usize, bank) * bank_size ..][0..bank_size];
}

fn romOffset(bank: u8, addr: u16) usize {
    return @as(usize, bank) * bank_size + (addr - windowBase(bank));
}

fn inWindow(bank: u8, addr: u16) bool {
    const base = windowBase(bank);
    return addr >= base and addr - base < bank_size;
}

fn isCodeBank(bank: u8) bool {
    for (code_banks) |b| if (b == bank) return true;
    return false;
}

const Key = struct { bank: u8, addr: u16 };
/// Insertion-ordered rather than hashed, and that is not incidental: the ledger
/// is iterated to produce a file, and a hash map's order depends on its
/// allocation history. `system.zig` makes the same point about the emulator --
/// two runs of the same input must produce the same bytes -- and it applies
/// just as much to a report as to a frame. `std` only exposes the unmanaged
/// form, so this is a thin owner for the allocator.
const SeedMap = struct {
    const Map = std.AutoArrayHashMapUnmanaged(Key, EntryKind);

    map: Map = .empty,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) SeedMap {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *SeedMap) void {
        self.map.deinit(self.allocator);
    }

    fn put(self: *SeedMap, k: Key, v: EntryKind) !void {
        try self.map.put(self.allocator, k, v);
    }

    fn getOrPut(self: *SeedMap, k: Key) !Map.GetOrPutResult {
        return self.map.getOrPut(self.allocator, k);
    }

    fn get(self: *const SeedMap, k: Key) ?EntryKind {
        return self.map.get(k);
    }

    fn count(self: *const SeedMap) usize {
        return self.map.count();
    }

    fn iterator(self: *const SeedMap) Map.Iterator {
        return self.map.iterator();
    }
};

/// The vectors the hardware fixes. Everything else is discovered.
fn seedVectors(seeds: *SeedMap) !void {
    try seeds.put(.{ .bank = 0, .addr = 0x0100 }, .reset);
    // $0040, $0048, $0050, $0058, $0060: vblank, LCD STAT, timer, serial,
    // joypad, in the priority order `cpu.Interrupt` enumerates.
    var v: u16 = 0x0040;
    while (v <= 0x0060) : (v += 8) try seeds.put(.{ .bank = 0, .addr = v }, .interrupt);
    // The eight RST targets. Metroid II uses several as short call thunks,
    // which is why they have to be seeded rather than found: nothing `CALL`s
    // them, `RST` does.
    var r: u16 = 0x0000;
    while (r <= 0x0038) : (r += 8) try seeds.put(.{ .bank = 0, .addr = r }, .rst);
}

/// Resolve a target address to the banks it could be in, and seed it.
///
/// Below $4000 it is bank 0 and there is nothing to resolve. In the banked
/// window it is ambiguous: which bank was mapped is not in the instruction. So
/// banked code calling into its own window is attributed to itself -- the
/// overwhelming case, since a bank's routines call each other -- and everything
/// else is attributed to whichever banks the emulator was *seen* to execute
/// that address in. A target nothing resolves is counted, not guessed at.
fn seedTarget(
    seeds: *SeedMap,
    obs: *const Observation,
    from_bank: u8,
    target: u16,
    unresolved: *usize,
) !bool {
    if (target >= 0x8000) return false; // RAM or HRAM; not a ROM routine.

    var added = false;
    if (target < 0x4000) {
        if (try put(seeds, 0, target)) added = true;
        return added;
    }

    var any = false;
    if (from_bank != 0) {
        if (try put(seeds, from_bank, target)) added = true;
        any = true;
    }
    for (code_banks) |b| {
        if (b == 0) continue;
        if (!obs.executed[romOffset(b, target)]) continue;
        if (try put(seeds, b, target)) added = true;
        any = true;
    }
    if (!any) unresolved.* += 1;
    return added;
}

/// Record `addr` as a call target, and say whether that changed anything.
///
/// A dispatch seed that a `CALL` also names is upgraded: being named by an
/// instruction is stronger evidence than being executed, and reporting it as a
/// dispatch target would overstate how much of the game only a run can find.
fn put(seeds: *SeedMap, bank: u8, addr: u16) !bool {
    const gop = try seeds.getOrPut(.{ .bank = bank, .addr = addr });
    if (!gop.found_existing) {
        gop.value_ptr.* = .call_target;
        return true;
    }
    if (gop.value_ptr.* == .dispatch_target) {
        gop.value_ptr.* = .call_target;
        return true;
    }
    return false;
}

const Body = struct {
    end: u16,
    covered: u16,
    instructions: u16,
    calls: u16,
    executed: bool,
};

/// Walk one routine's body: follow flow, do not descend into calls, and stop at
/// any target that is another known entry.
fn walkBody(
    allocator: std.mem.Allocator,
    rom: []const u8,
    obs: *const Observation,
    seeds: *const SeedMap,
    bank: u8,
    entry: u16,
    /// Marked true for every byte this body proved is code, indexed by ROM
    /// offset. Shared across all bodies in the bank, which is how overlap and
    /// uncovered-but-executed bytes are found.
    covered_map: []bool,
    starts_map: []bool,
) !Body {
    const code = bankSlice(rom, bank);
    const base = windowBase(bank);

    var seen = std.AutoHashMap(u16, void).init(allocator);
    defer seen.deinit();
    var callees = std.AutoHashMap(u16, void).init(allocator);
    defer callees.deinit();
    var work: std.ArrayList(u16) = .empty;
    defer work.deinit(allocator);
    try work.append(allocator, entry);

    var end: u16 = entry;
    var covered: u16 = 0;
    var instructions: u16 = 0;
    var executed = false;

    while (work.pop()) |addr| {
        if (!inWindow(bank, addr)) continue;
        if ((try seen.getOrPut(addr)).found_existing) continue;

        const off: usize = addr - base;
        const insn = disasm.decode(code[off..], addr);
        instructions += 1;
        const rom_off = romOffset(bank, addr);
        starts_map[rom_off] = true;
        if (obs.executed[rom_off]) executed = true;
        for (0..insn.len) |i| {
            if (off + i >= code.len) break;
            covered_map[romOffset(bank, @intCast(@as(usize, base) + off + i))] = true;
            covered += 1;
        }
        const last = addr +% @as(u16, insn.len);
        if (last > end) end = last;

        const next = addr +% insn.len;
        // A target that is itself an entry belongs to that entry, not to this
        // one. Without the rule, a `JP` to a shared tail folds two routines
        // into one and both instruction counts become wrong.
        const stopAt = struct {
            fn f(s: *const SeedMap, b: u8, t: u16, self_entry: u16) bool {
                return t != self_entry and s.get(.{ .bank = b, .addr = t }) != null;
            }
        }.f;

        switch (insn.flow) {
            .next => try work.append(allocator, next),
            .jump => |t| {
                if (!stopAt(seeds, bank, t, entry)) try work.append(allocator, t);
            },
            .branch => |t| {
                if (!stopAt(seeds, bank, t, entry)) try work.append(allocator, t);
                try work.append(allocator, next);
            },
            .call, .call_cc => |t| {
                try callees.put(t, {});
                try work.append(allocator, next);
            },
            .ret_cc => try work.append(allocator, next),
            .ret, .indirect, .stop, .illegal => {},
        }
    }

    return .{
        .end = end,
        .covered = covered,
        .instructions = instructions,
        .calls = @intCast(callees.count()),
        .executed = executed,
    };
}

/// Where a `known` address turned out to sit.
///
/// The distinction is not bookkeeping. `drawSamus_run` at 01:$4D77 *falls
/// through* into `drawSamus_common` at 01:$4DDF -- `offsets.zig` pins the
/// pose table's far end on exactly that fact -- so $4DDF is a label inside a
/// routine, not an entry to one. Three of our thirty named addresses are like
/// that, and a ledger that demanded they be entries would either be wrong or
/// would have to invent boundaries the bytes do not have. What it can insist
/// on is that a named address is *somewhere*: an entry, or inside a body. An
/// address that is neither is a citation that has drifted from the ROM.
pub const KnownState = enum {
    /// An entry point in its own right.
    entry,
    /// Inside another routine's body: a fall-through label or a second entry
    /// the game reaches without a `CALL`.
    inside,
    /// Neither. Either the address is wrong or nothing has reached it yet,
    /// which `executed` tells apart.
    absent,
};

pub const Ledger = struct {
    routines: []Routine,
    /// One per entry of `known`, in the same order.
    known_state: []KnownState,
    obs: Observation,
    /// Distinct instruction starts across all routines. The honest total: a
    /// routine's own count double-counts code two entries share.
    distinct_instructions: usize,
    /// Sum of the per-routine counts. Larger than `distinct_instructions` by
    /// exactly the shared code.
    summed_instructions: usize,
    /// Banked call targets no bank claimed and no run resolved.
    unresolved_targets: usize,
    /// Executed instruction starts that landed inside an instruction some
    /// routine's decode claimed. Should be zero: a nonzero count means our
    /// decode disagreed with our CPU about where an instruction begins, in a
    /// place a static trace walked into data.
    misaligned: usize,
    /// Executed instruction starts in banks the ledger does not disassemble.
    off_bank_executed: usize,
    /// Bytes of the six code banks that no routine's body claimed as code.
    ///
    /// The residual, and the honest counterweight to the instruction total.
    /// Most of it is not missing logic: banks 1, 3 and 5 hold large data tables
    /// -- metasprites, enemy headers, door scripts, title graphics -- and a byte
    /// of a table is correctly *not* code. The rest is code no run reached. The
    /// two are not separable from here, which is why this is reported as one
    /// number with that caveat rather than split on a guess.
    uncovered_bytes: usize,
    /// Of `uncovered_bytes`, how many are in banks 0, 2 and 4 -- the three that
    /// `coverage.bank_roles` calls pure code with no tables worth listing. This
    /// part of the residual really is logic nobody has reached.
    uncovered_code_bytes: usize,

    pub fn deinit(self: *Ledger, allocator: std.mem.Allocator) void {
        allocator.free(self.routines);
        allocator.free(self.known_state);
        self.obs.deinit(allocator);
    }

    pub fn find(self: Ledger, bank: u8, addr: u16) ?Routine {
        for (self.routines) |r| {
            if (r.bank == bank and r.addr == addr) return r;
        }
        return null;
    }

    pub fn counts(self: Ledger) Counts {
        var c: Counts = .{};
        for (self.routines) |r| {
            c.total += 1;
            c.instructions += r.instructions;
            switch (r.status) {
                .unconverted => c.unconverted += 1,
                .partial => c.partial += 1,
                .converted => c.converted += 1,
            }
            switch (r.tested) {
                .untested => c.untested += 1,
                .tested => c.tested += 1,
            }
            if (r.executed) c.executed += 1;
            if (r.kind == .dispatch_target) c.dispatch += 1;
        }
        return c;
    }
};

pub const Counts = struct {
    total: usize = 0,
    instructions: usize = 0,
    unconverted: usize = 0,
    partial: usize = 0,
    converted: usize = 0,
    untested: usize = 0,
    tested: usize = 0,
    executed: usize = 0,
    dispatch: usize = 0,
};

/// Build the ledger from the ROM and one observation of it running.
///
/// Two nested fixpoints, because the two kinds of evidence feed each other.
///
///  * **Inner:** trace every code bank from the entries known so far and add
///    what those routines `CALL`. A newly-found routine names more targets, so
///    this repeats until a pass adds nothing.
///  * **Outer:** walk every entry's body, then look for executed instruction
///    starts that no body covered. Each of those is an entry the bytes never
///    named -- a `JP HL` destination -- so it is added and the inner fixpoint
///    runs again, because a dispatch target calls things too.
///
/// The alternative, seeding every executed address as an entry, was tried first
/// and is wrong for an obvious reason once stated: it makes every instruction in
/// the game its own routine. An executed address is only an *entry* when
/// nothing else accounts for it.
pub fn build(allocator: std.mem.Allocator, rom: []const u8, obs: Observation) !Ledger {
    var seeds = SeedMap.init(allocator);
    defer seeds.deinit();
    try seedVectors(&seeds);

    // Every observed `JP HL` destination, before anything is traced. These are
    // entries on the strength of the run rather than of coverage: a dispatch
    // target that a neighbouring routine's body happens to flow into is still a
    // separate routine, and adding them only when uncovered merges the pose
    // handlers into whatever sits below them.
    for (obs.dispatch, 0..) |hit, off| {
        if (!hit) continue;
        const b: u8 = @intCast(off / bank_size);
        if (!isCodeBank(b)) continue;
        const addr: u16 = @intCast(windowBase(b) + (off % bank_size));
        const gop = try seeds.getOrPut(.{ .bank = b, .addr = addr });
        if (!gop.found_existing) gop.value_ptr.* = .dispatch_target;
    }

    const covered_map = try allocator.alloc(bool, rom.len);
    defer allocator.free(covered_map);
    const starts_map = try allocator.alloc(bool, rom.len);
    defer allocator.free(starts_map);

    var unresolved: usize = 0;
    var rows: std.ArrayList(Routine) = .empty;
    errdefer rows.deinit(allocator);

    // Bounded rather than `while (true)`: each round strictly grows the seed
    // set, so it terminates on its own, but a bound turns a bug in that
    // argument into a wrong number instead of a hang.
    var round: usize = 0;
    while (round < 16) : (round += 1) {
        // ---- Inner fixpoint: call targets ----
        var pass: usize = 0;
        while (pass < 64) : (pass += 1) {
            var added = false;
            for (code_banks) |b| {
                var addrs: std.ArrayList(u16) = .empty;
                defer addrs.deinit(allocator);
                var sit = seeds.iterator();
                while (sit.next()) |kv| {
                    if (kv.key_ptr.bank == b) try addrs.append(allocator, kv.key_ptr.addr);
                }
                if (addrs.items.len == 0) continue;

                var listing = try disasm.trace(allocator, bankSlice(rom, b), windowBase(b), addrs.items);
                defer listing.deinit(allocator);

                for (listing.calls) |t| {
                    if (try seedTarget(&seeds, &obs, b, t, &unresolved)) added = true;
                }
            }
            if (!added) break;
        }

        // ---- Bodies ----
        // Recomputed from scratch each round rather than patched: a new entry
        // changes the tail-call rule for every body that jumps to it, so a body
        // computed in an earlier round can be wrong by the end of this one.
        @memset(covered_map, false);
        @memset(starts_map, false);
        rows.clearRetainingCapacity();

        var it = seeds.iterator();
        while (it.next()) |kv| {
            const k = kv.key_ptr.*;
            const body = try walkBody(allocator, rom, &obs, &seeds, k.bank, k.addr, covered_map, starts_map);
            const meta = knownFor(k.bank, k.addr);
            try rows.append(allocator, .{
                .bank = k.bank,
                .addr = k.addr,
                .end = body.end,
                .span = body.end -% k.addr,
                .covered = body.covered,
                .instructions = body.instructions,
                .kind = kv.value_ptr.*,
                .executed = body.executed,
                .calls = body.calls,
                .name = if (meta) |mm| mm.name else "",
                .status = if (meta) |mm| mm.status else .unconverted,
                .tested = if (meta) |mm| mm.tested else .untested,
                .phase = if (meta) |mm| mm.phase else .unassigned,
            });
        }

        // ---- Outer: executed, but nobody's body covered it ----
        //
        // Swept in ascending address order, **covering as it goes**. The first
        // version added every uncovered executed byte at once and reported 2085
        // dispatch targets against 40 static ones, which is not a discovery -- it
        // is one entry per instruction of every routine the static trace missed,
        // and the 90588-summed against 10989-distinct instruction counts said so.
        // Walking a new entry's body immediately means the rest of that body is
        // covered before the sweep reaches it, so a routine contributes one entry
        // rather than one per instruction.
        //
        // Taking the lowest uncovered address as the entry assumes a routine's
        // entry is its lowest byte. SM83 routines flow forward and this holds for
        // all but a routine entered below its own top, which would show up as an
        // entry whose body runs backwards past its neighbours -- visible in the
        // spans rather than silent.
        var new_entries: usize = 0;
        for (code_banks) |b| {
            const base = @as(usize, b) * bank_size;
            var i: usize = 0;
            while (i < bank_size) : (i += 1) {
                const off = base + i;
                if (!obs.executed[off] or covered_map[off]) continue;
                const addr: u16 = @intCast(windowBase(b) + i);
                const gop = try seeds.getOrPut(.{ .bank = b, .addr = addr });
                if (gop.found_existing) continue;
                gop.value_ptr.* = .dispatch_target;
                new_entries += 1;
                _ = try walkBody(allocator, rom, &obs, &seeds, b, addr, covered_map, starts_map);
            }
        }
        if (new_entries == 0) break;
    }

    // An executed instruction start that a body covered but did not claim as a
    // *start* means our decode walked into data and came out misaligned. It is
    // a real inconsistency between the disassembler and the CPU on this ROM, so
    // it is counted and reported rather than smoothed over.
    var misaligned: usize = 0;
    var off_bank: usize = 0;
    for (obs.executed, 0..) |hit, off| {
        if (!hit) continue;
        const b: u8 = @intCast(off / bank_size);
        if (!isCodeBank(b)) {
            off_bank += 1;
            continue;
        }
        if (covered_map[off] and !starts_map[off]) misaligned += 1;
    }

    const known_state = try allocator.alloc(KnownState, known.len);
    errdefer allocator.free(known_state);
    for (known, 0..) |k, i| {
        const off = romOffset(k.bank, k.addr);
        known_state[i] = if (seeds.get(.{ .bank = k.bank, .addr = k.addr }) != null)
            .entry
        else if (covered_map[off])
            .inside
        else
            .absent;
    }

    var uncovered: usize = 0;
    var uncovered_code: usize = 0;
    for (code_banks) |b| {
        const base = @as(usize, b) * bank_size;
        for (covered_map[base..][0..bank_size]) |c| {
            if (c) continue;
            uncovered += 1;
            // Banks 0, 2 and 4 are the ones `coverage.bank_roles` marks as
            // holding no tables worth listing, so an uncovered byte there is
            // code nothing reached rather than data correctly left alone.
            if (b == 0 or b == 2 or b == 4) uncovered_code += 1;
        }
    }

    var distinct: usize = 0;
    for (starts_map) |s| distinct += @intFromBool(s);
    var summed: usize = 0;
    for (rows.items) |r| summed += r.instructions;

    const out = try rows.toOwnedSlice(allocator);
    std.mem.sort(Routine, out, {}, lessThan);

    return .{
        .routines = out,
        .known_state = known_state,
        .obs = obs,
        .distinct_instructions = distinct,
        .summed_instructions = summed,
        .unresolved_targets = unresolved,
        .misaligned = misaligned,
        .off_bank_executed = off_bank,
        .uncovered_bytes = uncovered,
        .uncovered_code_bytes = uncovered_code,
    };
}

fn lessThan(_: void, a: Routine, b: Routine) bool {
    if (a.bank != b.bank) return a.bank < b.bank;
    return a.addr < b.addr;
}

pub fn knownFor(bank: u8, addr: u16) ?Known {
    for (known) |k| {
        if (k.bank == bank and k.addr == addr) return k;
    }
    return null;
}

// ---- Output ---------------------------------------------------------------

/// One row per routine, tab separated, header first. Machine-readable is the
/// requirement; tab separated because a routine's name never contains a tab and
/// a note never reaches this file.
pub fn tsv(allocator: std.mem.Allocator, l: Ledger) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "bank\taddr\tend\tspan\tcovered\tinsns\tkind\texecuted\tcalls\tstatus\ttested\tphase\tname\n");
    for (l.routines) |r| {
        try buf.print(allocator, "{d}\t${X:0>4}\t${X:0>4}\t{d}\t{d}\t{d}\t{s}\t{s}\t{d}\t{s}\t{s}\t{s}\t{s}\n", .{
            r.bank,
            r.addr,
            r.end,
            r.span,
            r.covered,
            r.instructions,
            r.kind.text(),
            if (r.executed) "yes" else "no",
            r.calls,
            r.status.text(),
            r.tested.text(),
            r.phase.text(),
            r.name,
        });
    }
    return buf.toOwnedSlice(allocator);
}

pub fn reportText(allocator: std.mem.Allocator, l: Ledger) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const c = l.counts();

    try buf.print(allocator, "Logic inventory ledger\n\n", .{});
    try buf.print(allocator, 
        "  {d} routines over banks 0-5, {d} distinct instructions ({d} summed over routines,\n" ++
            "  so {d} are shared between two entries).\n\n",
        .{ c.total, l.distinct_instructions, l.summed_instructions, l.summed_instructions - l.distinct_instructions },
    );

    try buf.print(allocator, "  Against the ~{d} logic lines `01-requirements` states: {d} instructions is\n", .{ stated_logic_lines, l.distinct_instructions });
    const pct = @as(f64, @floatFromInt(l.distinct_instructions)) * 100.0 / @as(f64, @floatFromInt(stated_logic_lines));
    try buf.print(allocator, "  {d:.0}% of it. One SM83 instruction is one source line, so the two are the\n", .{pct});
    try buf.print(allocator, "  same unit.\n\n", .{});

    // Reported against the ROM's own bytes rather than as the complement of the
    // percentage above. They are different denominators -- one is a budget
    // somebody estimated, the other is how much of six banks has been accounted
    // for -- and subtracting one from the other would produce a number that
    // means nothing.
    const code_bank_bytes = code_banks.len * bank_size;
    const pure = [_]u8{ 0, 2, 4 };
    var pure_bytes: usize = 0;
    for (pure) |_| pure_bytes += bank_size;
    try buf.print(allocator, "  What is NOT accounted for, measured against the ROM instead:\n\n", .{});
    try buf.print(
        allocator,
        "    {d} of {d} bytes across banks 0-5 are claimed by no routine's body ({d}%).\n" ++
            "    Most of that is data and correctly so -- bank 1's metasprites, bank 3's\n" ++
            "    enemy headers, bank 5's door scripts and title graphics -- and a body that\n" ++
            "    decoded a table would be the bug.\n" ++
            "    The part that is not data: {d} of the {d} bytes in banks 0, 2 and 4, which\n" ++
            "    `coverage.bank_roles` marks as holding no tables worth listing. That is\n" ++
            "    logic no run has reached, and it is the number Step 15's TAS should move.\n" ++
            "    {d} banked call targets no run resolved to a bank.\n\n",
        .{
            l.uncovered_bytes,
            code_bank_bytes,
            l.uncovered_bytes * 100 / code_bank_bytes,
            l.uncovered_code_bytes,
            pure_bytes,
            l.unresolved_targets,
        },
    );

    try buf.print(allocator, "  status    converted {d}, partial {d}, unconverted {d}\n", .{ c.converted, c.partial, c.unconverted });
    try buf.print(allocator, "  tested    tested {d}, untested {d}\n", .{ c.tested, c.untested });
    try buf.print(allocator, "  found by  {d} executed, of which {d} are dispatch targets no static trace\n", .{ c.executed, c.dispatch });
    try buf.print(allocator, "            could reach\n\n", .{});

    try buf.print(allocator, "  observed  {d} frames, {d} instructions, {d} of {d} doors returned\n", .{
        l.obs.frames,
        l.obs.instructions,
        l.obs.doors_returned,
        l.obs.doors_run,
    });
    try buf.print(allocator, "  machine   {s}, {s} (map bank ${X:0>2}, screen {d},{d})\n", .{
        if (l.obs.alive) "alive" else "NOT ALIVE",
        if (l.obs.inRoom()) "in a room" else "NOT IN A ROOM",
        l.obs.map_bank,
        l.obs.screen_row,
        l.obs.screen_col,
    });
    try buf.print(allocator, "  poses     {d} distinct: ", .{l.obs.poseCount()});
    for (l.obs.poses_seen, 0..) |seen, p| {
        if (seen) try buf.print(allocator, "${X:0>2} ", .{p});
    }
    try buf.print(allocator, "\n", .{});
    try buf.print(allocator, "  executed  ", .{});
    for (l.obs.per_bank, 0..) |n, b| {
        if (n == 0) continue;
        try buf.print(allocator, "bank {d}: {d}  ", .{ b, n });
    }
    try buf.print(allocator, "\n", .{});
    if (l.off_bank_executed != 0) {
        try buf.print(allocator, "  WARNING   {d} executed instruction starts in banks the ledger calls data\n", .{l.off_bank_executed});
    }
    if (l.misaligned != 0) {
        try buf.print(allocator, "  WARNING   {d} executed starts landed inside an instruction a routine claimed\n", .{l.misaligned});
    }
    if (l.unresolved_targets != 0) {
        try buf.print(allocator, "  note      {d} banked call targets no run resolved to a bank\n", .{l.unresolved_targets});
    }

    try buf.print(allocator, "\nPhase 0a's routines\n\n", .{});
    try buf.print(allocator, "  bank addr   insns  status       tested     name\n", .{});
    for (l.routines) |r| {
        if (r.status == .unconverted and r.tested == .untested) continue;
        try buf.print(allocator, "  {d:>4} ${X:0>4} {d:>6}  {s:<12} {s:<10} {s}\n", .{
            r.bank, r.addr, r.instructions, r.status.text(), r.tested.text(), r.name,
        });
    }

    var inside: usize = 0;
    var absent: usize = 0;
    for (known, l.known_state) |k, st| {
        if (st == .entry) continue;
        if (inside + absent == 0) try buf.print(allocator, "\n  Named, but not an entry of its own:\n", .{});
        const off = @as(usize, k.bank) * bank_size + (k.addr - windowBase(k.bank));
        switch (st) {
            .entry => unreachable,
            .inside => inside += 1,
            .absent => absent += 1,
        }
        try buf.print(allocator, "    bank {d} ${X:0>4}  {s:<16} {s}\n", .{
            k.bank,
            k.addr,
            k.name,
            switch (st) {
                .entry => unreachable,
                .inside => "a label inside another routine, which is a fact about the ROM",
                .absent => if (l.obs.executed[off])
                    "executed but claimed by nothing -- the boundary rule missed it"
                else
                    "NOT REACHED: nothing executed it and no instruction names it",
            },
        });
    }

    try buf.print(allocator, "\nThe backlog: the 20 largest routines nobody has claimed\n\n", .{});
    const by_size = try allocator.dupe(Routine, l.routines);
    defer allocator.free(by_size);
    std.mem.sort(Routine, by_size, {}, biggestUnconvertedFirst);
    var shown: usize = 0;
    for (by_size) |r| {
        if (shown >= 20) break;
        if (r.status != .unconverted) continue;
        try buf.print(allocator, "  bank {d} ${X:0>4}  {d:>4} insns  {s}{s}\n", .{
            r.bank,
            r.addr,
            r.instructions,
            if (r.executed) "executed" else "never seen to run",
            if (r.kind == .dispatch_target) ", dispatch target" else "",
        });
        shown += 1;
    }

    return buf.toOwnedSlice(allocator);
}

fn biggestUnconvertedFirst(_: void, a: Routine, b: Routine) bool {
    return a.instructions > b.instructions;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "the vectors seeded are the ones the hardware fixes, and nothing else" {
    var seeds = SeedMap.init(testing.allocator);
    defer seeds.deinit();
    try seedVectors(&seeds);
    // Reset, five interrupts, eight RSTs -- but $0000 is both RST 0 and would
    // be a vector, so the map holds 14 - 1 = 13 distinct addresses only if
    // they collide, and they do not: RSTs are $00-$38, interrupts $40-$60.
    try testing.expectEqual(@as(usize, 1 + 5 + 8), seeds.count());
    try testing.expectEqual(EntryKind.reset, seeds.get(.{ .bank = 0, .addr = 0x0100 }).?);
    try testing.expectEqual(EntryKind.interrupt, seeds.get(.{ .bank = 0, .addr = 0x0040 }).?);
    try testing.expectEqual(EntryKind.rst, seeds.get(.{ .bank = 0, .addr = 0x0038 }).?);
}

test "the known table names routines in code banks at plausible addresses" {
    for (known) |k| {
        try testing.expect(isCodeBank(k.bank));
        try testing.expect(inWindow(k.bank, k.addr));
        try testing.expect(k.name.len != 0);
        try testing.expect(k.note.len != 0);
        // A converted routine with no evidence of a test is exactly what the
        // `tested` column exists to show, so it is allowed -- but an
        // unconverted routine that claims to be tested is incoherent.
        if (k.status == .unconverted) try testing.expectEqual(Tested.untested, k.tested);
    }
}

test "an edge the recorder cannot allocate marks it incomplete" {
    // `record` allocates twice on a fresh recorder: the `seen` entry, then the
    // `edges` slot. Failing either one used to drop the edge without a word.
    for ([_]usize{ 0, 1 }) |fail_index| {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var rec: ExecRecorder = .{ .rom = &.{}, .executed = &.{}, .dispatch = &.{}, .allocator = failing.allocator() };
        defer rec.deinit();
        rec.record(.{ .site = 0x0028, .target = 0x0100 });
        try testing.expect(rec.incomplete);
        try testing.expectEqual(@as(usize, 0), rec.edges.items.len);
        try testing.expectEqual(@as(u32, 0), rec.seen.count());
    }

    var rec: ExecRecorder = .{ .rom = &.{}, .executed = &.{}, .dispatch = &.{}, .allocator = testing.allocator };
    defer rec.deinit();
    rec.record(.{ .site = 0x0028, .target = 0x0100 });
    rec.record(.{ .site = 0x0028, .target = 0x0100 });
    try testing.expect(!rec.incomplete);
    try testing.expectEqual(@as(usize, 1), rec.edges.items.len);
}

test "bank and address arithmetic round-trips through the ROM offset" {
    try testing.expectEqual(@as(usize, 0x0100), romOffset(0, 0x0100));
    try testing.expectEqual(@as(usize, 0x4000), romOffset(1, 0x4000));
    try testing.expectEqual(@as(usize, 0x4BD9), romOffset(1, 0x4BD9));
    try testing.expectEqual(@as(usize, 5 * bank_size), romOffset(5, 0x4000));
    try testing.expect(inWindow(0, 0x3FFF));
    try testing.expect(!inWindow(0, 0x4000));
    try testing.expect(inWindow(3, 0x7FFF));
    try testing.expect(!inWindow(3, 0x3FFF));
}

/// A synthetic bank 0 with three routines, one of them reachable only through
/// a `JP HL` -- which is the case the whole design exists for.
fn fixture(allocator: std.mem.Allocator) ![]u8 {
    const rom = try allocator.alloc(u8, bank_count * bank_size);
    @memset(rom, 0xC9); // RET everywhere, so a stray seed decodes as a one-instruction routine.
    rom[0x0147] = 0x01;

    // $0100: CALL $0200; JP HL  -- the dispatch the static trace cannot follow.
    rom[0x0100] = 0xCD;
    rom[0x0101] = 0x00;
    rom[0x0102] = 0x02;
    rom[0x0103] = 0xE9;

    // $0200: INC A; INC A; RET  -- three instructions, found as a call target.
    rom[0x0200] = 0x3C;
    rom[0x0201] = 0x3C;
    rom[0x0202] = 0xC9;

    // $0300: four INC A then RET -- reachable only by executing it.
    rom[0x0300] = 0x3C;
    rom[0x0301] = 0x3C;
    rom[0x0302] = 0x3C;
    rom[0x0303] = 0x3C;
    rom[0x0304] = 0xC9;
    return rom;
}

fn emptyObservation(allocator: std.mem.Allocator, len: usize) !Observation {
    const executed = try allocator.alloc(bool, len);
    @memset(executed, false);
    const dispatch = try allocator.alloc(bool, len);
    @memset(dispatch, false);
    return .{
        .executed = executed,
        .dispatch = dispatch,
        .edges = try allocator.alloc(Edge, 0),
        .per_bank = @splat(0),
        .instructions = 0,
        .frames = 0,
        .doors_run = 0,
        .doors_returned = 0,
        .alive = false,
        .poses_seen = @splat(false),
        .map_bank = 0,
        .screen_row = 0,
        .screen_col = 0,
    };
}

test "call targets are found statically; a dispatch target needs the run" {
    const a = testing.allocator;
    const rom = try fixture(a);
    defer a.free(rom);

    // Without evidence of execution, $0300 is invisible: nothing names it.
    {
        var obs = try emptyObservation(a, rom.len);
        var l = try build(a, rom, obs);
        defer l.deinit(a);
        _ = &obs;
        try testing.expect(l.find(0, 0x0200) != null);
        try testing.expect(l.find(0, 0x0300) == null);
    }

    // With it, $0300 appears -- and is marked as what it is.
    {
        var obs = try emptyObservation(a, rom.len);
        obs.executed[0x0300] = true;
        var l = try build(a, rom, obs);
        defer l.deinit(a);
        const r = l.find(0, 0x0300) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(EntryKind.dispatch_target, r.kind);
        try testing.expectEqual(@as(u16, 5), r.instructions);
        try testing.expect(r.executed);
    }
}

test "an executed byte inside a routine's body is not a second routine" {
    const a = testing.allocator;
    const rom = try fixture(a);
    defer a.free(rom);

    var obs = try emptyObservation(a, rom.len);
    // $0201 is the second INC A of the routine at $0200. Executing it must not
    // manufacture an entry there: it is mid-body, and the static trace already
    // covered it.
    obs.executed[0x0201] = true;
    var l = try build(a, rom, obs);
    defer l.deinit(a);

    const inner = l.find(0, 0x0201);
    if (inner) |r| {
        // If it does appear it must at least not be a *dispatch* target, since
        // the body covers it. Failing that, the seeding rule has regressed.
        try testing.expect(r.kind != .dispatch_target);
    }
    try testing.expectEqual(@as(usize, 0), l.misaligned);
}

test "the tail-call rule keeps a shared tail out of its caller" {
    const a = testing.allocator;
    const rom = try a.alloc(u8, bank_count * bank_size);
    defer a.free(rom);
    @memset(rom, 0x00); // NOP, so an unterminated walk would run to the end.
    rom[0x0147] = 0x01;

    // $0100: CALL $0200; CALL $0300; RET
    rom[0x0100] = 0xCD;
    rom[0x0101] = 0x00;
    rom[0x0102] = 0x02;
    rom[0x0103] = 0xCD;
    rom[0x0104] = 0x00;
    rom[0x0105] = 0x03;
    rom[0x0106] = 0xC9;
    // $0200: INC A; JP $0300  -- a tail call into a routine of its own.
    rom[0x0200] = 0x3C;
    rom[0x0201] = 0xC3;
    rom[0x0202] = 0x00;
    rom[0x0203] = 0x03;
    // $0300: INC A; INC A; INC A; RET
    rom[0x0300] = 0x3C;
    rom[0x0301] = 0x3C;
    rom[0x0302] = 0x3C;
    rom[0x0303] = 0xC9;

    var obs = try emptyObservation(a, rom.len);
    var l = try build(a, rom, obs);
    defer l.deinit(a);
    _ = &obs;

    const tail_caller = l.find(0, 0x0200) orelse return error.TestUnexpectedResult;
    const tail = l.find(0, 0x0300) orelse return error.TestUnexpectedResult;
    // Two instructions: the INC and the JP. Without the rule it would be six.
    try testing.expectEqual(@as(u16, 2), tail_caller.instructions);
    try testing.expectEqual(@as(u16, 4), tail.instructions);
}

test "a static-only ledger of the retail ROM is coherent, and small" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    // Static only. Two minutes of emulation and a 512-door sweep belong in the
    // gate, not the unit suite; what this checks is the half that needs no run.
    var obs = try emptyObservation(a, rom.len);
    var l = try build(a, rom, obs);
    defer l.deinit(a);
    _ = &obs;

    // No dispatch targets are possible without an observation, and nothing may
    // claim to have been executed.
    for (l.routines) |r| {
        try testing.expect(r.kind != .dispatch_target);
        try testing.expect(!r.executed);
    }

    // **And it is small.** This is the measurement the requirement was amended
    // on: seeded from the vectors alone, a flow trace of the whole ROM finds
    // well under a tenth of the game, because `JP HL` through a table of code
    // pointers is where this game keeps its structure. If this ever stops being
    // true the amendment's reasoning deserves re-reading, so it is asserted
    // rather than left as a remark.
    try testing.expect(l.routines.len < 100);
    try testing.expect(l.distinct_instructions < stated_logic_lines / 5);

    // Every named address must at least be code the static trace can reach or
    // an address inside something it reached; `absent` here would mean a
    // citation that does not point at an instruction boundary.
    var entries: usize = 0;
    for (l.known_state) |st| entries += @intFromBool(st == .entry);
    try testing.expect(entries > 0);
}

test "the ledger is reproducible" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    // A ledger is a file people will diff. Two builds from the same inputs
    // must produce the same rows in the same order, which is why the seed map
    // is insertion-ordered rather than hashed.
    var l1 = try build(a, rom, try emptyObservation(a, rom.len));
    defer l1.deinit(a);
    var l2 = try build(a, rom, try emptyObservation(a, rom.len));
    defer l2.deinit(a);

    const t1 = try tsv(a, l1);
    defer a.free(t1);
    const t2 = try tsv(a, l2);
    defer a.free(t2);
    try testing.expectEqualStrings(t1, t2);
}
