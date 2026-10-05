//! The oracle: one hand-authored input segment, run on both machines, compared
//! frame for frame.
//!
//! `01-requirements` (D1) asks for a reference our build is graded against.
//! The published tool-assisted runs are that reference for the *original*, and
//! `tas.zig` captures them -- but they are not a pass condition for this cart,
//! which has no ship, save, pause, shooting, ammo, enemies, music, items or
//! room transitions. Phase 0a's actual target is this: a short segment on one
//! converted screen -- fall, land, walk, jump, land, walk back -- comparing
//! Samus's position and the camera, and nothing else, because position and the
//! camera are the two things the port has.
//!
//! ## Both machines are placed, not found
//!
//! The comparison is worthless unless frame 0 is the same frame 0. Step 14
//! built the two halves that make that possible: `room.spawn` puts Samus at an
//! arbitrary bank, screen and pixel on the Game Boy through the `WARP` handler,
//! and boot record version 3 carries a start position the injector writes into
//! the cart. This file asks both for the same place -- the cart's own boot cell,
//! at the same pixel -- and `correspond.zig` is what lets the two answers be
//! compared in one set of units.
//!
//! ## Where a frame is sampled, and why it is not `endFrame`
//!
//! Step 12a measured a one-frame lag between the engine's camera variable and
//! the picture, and found that neither Mesen's `endFrame` nor its `nmi` lines
//! up with the engine's own commit point on its own. So the sampling point is
//! established against the engine rather than assumed:
//!
//!     MainLoop:  wai / SavePrev / HandlePose / StreamDue / HandleCamera /
//!                DrawSamus / bra MainLoop
//!
//! Everything the oracle reads is written between the `wai` and the branch, and
//! nothing writes it afterwards, so the instant the loop arrives back at `wai`
//! is exactly when frame N's logic is complete. The generated script hooks an
//! execution callback on the `MainLoop` label and samples there. `endFrame`
//! would sample wherever the main loop happened to be when the PPU finished a
//! frame, which is a race, and `nmi` would sample before the frame's logic had
//! run at all.
//!
//! The frame index comes from the engine's own `!FrameCount`, incremented in
//! the NMI handler, rather than from a counter the script keeps: a script-side
//! counter counts callbacks, and the two are only the same while nothing ever
//! runs long.
//!
//! ## The channel is the exit code
//!
//! Mesen2 swallows `emu.log` in testrunner mode and sandboxes lua's `io`, so
//! the reference trace is baked into the generated script and the comparison
//! happens on the emulator side, the same way `snes_romtest.zig` bakes the
//! expected picture. The code protocol is below and is read back by `verify`.

const std = @import("std");
const harness = @import("gb/harness.zig");
const probe = @import("gb/probe.zig");
const room = @import("room.zig");
const correspond = @import("correspond.zig");
const snes_screen = @import("snes_screen.zig");
const map_mod = @import("map.zig");
const screens = @import("screens.zig");
const warp = @import("warp.zig");
const routines = @import("routines.zig");
const tas = @import("tas.zig");
const gb_trace = @import("gb_trace.zig");
const save = @import("save.zig");
const enemy_oracle = @import("enemy_oracle.zig");

pub const Error = error{ MissingSymbol, OutOfMemory, NoStart, NeverSettled, NotPerFrame, TooManyBlocks, UnknownPalette, NoMenuRow, PatchNoOp, NoEnemySeed, NoDoor } || harness.Error || room.Error;

// ---- The segment ----------------------------------------------------------

/// The inputs the port can be asked for: one bit per button its engine reads.
///
/// This was an enum of the *combinations* the segment used -- `none`, `right`,
/// `left`, `jump`, `right_jump`, `left_jump` -- which was honest while the port
/// had a walk and a jump and nothing else. Crouch and the morph ball need Down
/// and Up, and naming every combination of five buttons is ten more variants
/// that exist only so a `switch` can be exhaustive. A bitset says the same
/// thing and stops the vocabulary from being the reason a movie frame is
/// unrepresentable: from here, "the port has no key for this" means a *button*
/// the engine does not read, never a combination nobody wrote down.
///
/// The bit order is `tas.Input`'s own, minus the three the engine has no wire
/// for, so `movieKey` is a mask and a shift rather than a decision.
pub const Key = packed struct(u8) {
    /// A on the Game Boy; B on the cart, the way Super Metroid has it.
    jump: bool = false,
    right: bool = false,
    left: bool = false,
    up: bool = false,
    down: bool = false,
    /// B on the Game Boy; Y on the cart. Added in Step 12b, when the port
    /// grew something to do with it: `samusShoot` is the first routine in this
    /// engine that reads the bit at all.
    fire: bool = false,
    _unused: u2 = 0,

    pub fn eql(a: Key, b: Key) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }
};

/// The combinations worth a name. A separate namespace because Zig will not let
/// a declaration share a name with a field, and the fields are the better half
/// of that argument: `k.down` should mean "is Down held", always.
pub const key = struct {
    pub const none: Key = .{};
    pub const fire: Key = .{ .fire = true };
    pub const right: Key = .{ .right = true };
    pub const left: Key = .{ .left = true };
    pub const jump: Key = .{ .jump = true };
    pub const right_jump: Key = .{ .right = true, .jump = true };
    pub const left_jump: Key = .{ .left = true, .jump = true };
    pub const up: Key = .{ .up = true };
    pub const down: Key = .{ .down = true };
};

/// The same input on the Game Boy's pad. Jump is A on the original.
///
/// `probe.Buttons` is active-low, which is the hardware's own sense: a cleared
/// bit is a held button.
pub fn gbKeys(k: Key) probe.Buttons {
    var b: probe.Buttons = .{};
    if (k.right) b.dpad &= ~@as(u4, 0b0001);
    if (k.left) b.dpad &= ~@as(u4, 0b0010);
    if (k.up) b.dpad &= ~@as(u4, 0b0100);
    if (k.down) b.dpad &= ~@as(u4, 0b1000);
    if (k.jump) b.buttons &= ~@as(u4, 0b0001);
    if (k.fire) b.buttons &= ~@as(u4, 0b0010);
    return b;
}

// ---- A movie's inputs, in the port's vocabulary -----------------------------

/// The movie bits the port's engine can act on: A, Right, Left, Up, Down.
///
/// `tas.Input` bit order is A, B, Select, Start, Right, Left, Up, Down. What is
/// left out is B, Select and Start -- shooting, the item screen and the pause
/// menu -- and that is worth counting rather than quietly dropping, because it
/// is the list of things Phase 0b has to add before the movie can be followed
/// further.
///
/// Up and Down joined the mask when the crouch landed. They are read by the
/// crouch and by the morph ball, which is where the published run goes four
/// frames after it is handed control.
///
/// **B joined it in Step 12b, and that is a measurement-affecting change of the
/// same class as `codes_per_quantity`**: it alters what the cart is handed on
/// every graded frame of every rung, so it lands in a commit of its own with
/// every floor re-measured in it, rather than riding along with the port that
/// made it possible. Before it, the movie's shoot presses were silently dropped
/// and the note under `reachable` counted them; after it, the cart fires when
/// the run fires.
pub const supported_input_bits: u8 = 0x01 | 0x02 | 0x10 | 0x20 | 0x40 | 0x80;

/// Right and Left held together, which the port has no key for and the
/// original resolves in code we have not read. Treated as unsupported rather
/// than guessed at.
pub const both_directions: u8 = 0x10 | 0x20;

/// What a movie frame asked for that the cart cannot be asked for.
///
/// Zero means the frame is fully representable. Anything else is the bits that
/// were dropped, and `firstUnsupported` finds the first frame with any.
pub fn unsupportedBits(held: u8) u8 {
    const extra = held & ~supported_input_bits;
    const both: u8 = if (held & both_directions == both_directions) both_directions else 0;
    return extra | both;
}

/// One movie frame in the port's vocabulary.
///
/// A frame carrying anything else is *not* silently approximated: the caller is
/// expected to have asked `unsupportedBits` first and to have recorded the
/// answer. This function only decides what the cart is handed once that is
/// known -- which is why both directions at once comes back as neither rather
/// than as a guess.
pub fn movieKey(held: u8) Key {
    var k: Key = .{
        .jump = held & 0x01 != 0,
        .fire = held & 0x02 != 0,
        .right = held & 0x10 != 0,
        .left = held & 0x20 != 0,
        .up = held & 0x40 != 0,
        .down = held & 0x80 != 0,
    };
    if (k.right and k.left) {
        k.right = false;
        k.left = false;
    }
    return k;
}

/// The same input as Mesen's `setInput` names it, written into `buf`.
///
/// `engine/main.asm` puts jump on B, the way Super Metroid does, which is why
/// this is not simply "a". A buffer rather than a static string because the
/// vocabulary is a bitset now and there are thirty-two of these.
/// The SNES pad word for a key, in the engine's own `!PAD_*` bit assignment.
///
/// Mirrored from `engine/main.asm` like `snes_screen.pose` and for the same
/// reason: the boot record has to seed `!PadHeld` with something the engine
/// will decode, and deriving it from `mesenKeys`'s strings would be a parser.
pub const pad = struct {
    pub const right: u16 = 0x0100;
    pub const left: u16 = 0x0200;
    pub const down: u16 = 0x0400;
    pub const up: u16 = 0x0800;
    pub const jump: u16 = 0x8000;
    /// `!PAD_FIRE`, which `engine/main.asm` puts on Y.
    pub const fire: u16 = 0x4000;
};

pub fn padWord(k: Key) u16 {
    var w: u16 = 0;
    if (k.right) w |= pad.right;
    if (k.left) w |= pad.left;
    if (k.up) w |= pad.up;
    if (k.down) w |= pad.down;
    if (k.jump) w |= pad.jump;
    if (k.fire) w |= pad.fire;
    return w;
}

pub fn mesenKeys(k: Key, buf: []u8) []const u8 {
    var w: usize = 0;
    for ([_]struct { on: bool, name: []const u8 }{
        .{ .on = k.right, .name = "right = true" },
        .{ .on = k.left, .name = "left = true" },
        .{ .on = k.up, .name = "up = true" },
        .{ .on = k.down, .name = "down = true" },
        .{ .on = k.jump, .name = "b = true" },
        .{ .on = k.fire, .name = "y = true" },
    }) |e| {
        if (!e.on) continue;
        if (w > 0) {
            @memcpy(buf[w..][0..2], ", ");
            w += 2;
        }
        @memcpy(buf[w..][0..e.name.len], e.name);
        w += e.name.len;
    }
    return buf[0..w];
}

/// Enough room for every button named at once, separators included.
pub const mesen_keys_max: usize = 64;

/// A short name for a report line.
///
/// Derived from the `key` namespace rather than from a second switch, so a
/// combination that gains a name gains it here too. Anything unnamed prints as
/// its bits, which is all a reader needs for an input nothing wrote down.
pub fn keyName(k: Key, buf: []u8) []const u8 {
    inline for (@typeInfo(key).@"struct".decls) |d| {
        if (k.eql(@field(key, d.name))) return d.name;
    }
    return std.fmt.bufPrint(buf, "${X:0>2}", .{@as(u8, @bitCast(k))}) catch "?";
}

pub const Phase = struct { frames: u16, key: Key, why: []const u8 };

/// Fall, land, walk, jump, land, walk back, stand -- then morph, roll off a
/// ledge, bounce, and get up.
///
/// Long holds rather than taps: a frame-perfect input would make the segment a
/// test of the two machines' input latency, and the plan asks for a comparison
/// of position and camera.
///
/// ## The ball, added 2026-09-02, and why it is 324 frames long
///
/// The last four phases are the morph bug's regression test and they are the
/// reason `pose` is compared at all. The bug: `PoseJump`'s exit dropped the
/// original's test at 00:$1837 of *who* was flying the arc, so a ball that
/// bounced off a landing finished the bounce as pose $07 and Samus stood up
/// with no input. It was found on hardware, not here, and this segment is why
/// -- ball-fall and standing-fall share the arc, the $17 clamp and the landing
/// row snap, so the wrong pose put her on exactly the right pixel. Grading it
/// with the bug back in gives `MATCH: 644 frames` on position and camera.
///
/// The length is the room's, not a choice. `chooseStart` settles Samus at
/// $082C; the only ledge a ball can roll off is 378 pixels to the left, and the
/// roll is two pixels a frame. So 190 of the 324 frames are her getting there.
/// The rest is the whole cycle, and every pose in it is checked frame for
/// frame: $04 crouch at 321, $05 ball at 337, $08 ball-fall off the ledge at
/// 534, $05 landing at 558, $06 the bounce at 559, **$08 at 593 where the arc
/// ends -- the frame the bug got wrong** -- $05 again at 594, thirty frames of
/// sitting there still a ball, then $04 and $00 on the Up.
///
/// Held Left is what earns the bounce: released after the ledge she lands too
/// slowly for `!DownSpeed >= 2` and only rolls. Left is released at 564 so the
/// bounce is a bounce and not a steer.
///
/// ## The knockback, added 2026-09-09 by B4b, and why it is 120 frames long
///
/// The last phase is the enemy-contact test, and it exists because **the
/// published runs cannot supply one**: neither is hit inside its horizon, which
/// the planning spike measured, so the only reference for Samus taking damage
/// that this repository can produce frame for frame is a segment that goes and
/// gets hit. Until this step the segment was steered *away* from it -- the
/// comment here used to say so -- because Phase 0a's cart had no handler for
/// the pose it ends in.
///
/// Held Left past the ball's exit walks her left and off the ledge, and a
/// Senjoo -- sprite $16, damage $15, flying its diamond out of bank $9 cell
/// $37's neighbour -- reaches her while she is falling. Measured on the Game
/// Boy on 2026-09-09: contact at 701, pose $0F and `samusInvulnerableTimer`
/// $33 at 702, health $99 to $84 in BCD, the boost direction latched right and
/// then re-steered left at 724 when the arc counter passes $56, and the landing
/// at about 755. **A second Senjoo reaches her at 791**, which is where the
/// 120 frames stop: one hit graded to its end is evidence, and two overlapping
/// ones are a harder thing to read for no more of it.
///
/// **It is 56 frames and not 120, and the difference is a measurement rather
/// than a choice.** Extended to 120 the segment reaches frame 702 exactly --
/// every frame of the walk and the fall matches, including the frames the
/// enemies are moving in -- and stops there, on the contact frame.
///
/// It stopped there for one reason until 2026-09-09 and stops there for another
/// now. The first was the spawn walk: `DeriveScroll` had the wrong scroll bias,
/// so every record the cart loaded came out 48 pixels low and 32 right, sat in
/// a different band of the deactivation window, and was deleted while the Game
/// Boy kept it -- at frame 640 the Game Boy had three live slots and the cart
/// none. That is fixed, and `zig build trace`'s four `en` columns are what found
/// it: every column before them was about Samus, and "the port did not register
/// the hit" and "the port's enemy is not where the reference's is" look
/// identical from Samus's side.
///
/// The second is what the fix uncovered, and it is a frame rather than a
/// mechanism: **the cart registers the contact one tick before the Game Boy
/// does.** Run at 703 frames, both machines are in pose $0F at 702 and the
/// Game Boy's position on that frame is still frame 701's -- its arc counter
/// reads $40, the seed `hurtSamus` wrote, and the first arc step lands on 703
/// -- while the cart has already flown that step. The pose columns agreeing is
/// the sample points' doing, not agreement: `gb_logic_pc` was *after*
/// `hurtSamus` (until 1.0 Step 8d) and the cart's record is taken at `MainLoop`, so the reference's
/// pose leads its own position by a tick on exactly the frame `hurtSamus`
/// fires. Position is directly comparable and it is the position that differs.
/// The save-RAM channel holds 705 frames, so those three are affordable the
/// moment that is fixed; see `docs/bug_tracker.md`, 2026-09-09.
pub const segment = [_]Phase{
    .{ .frames = 60, .key = key.none, .why = "she starts in the fall pose; let her land" },
    .{ .frames = 60, .key = key.right, .why = "walk right, which moves the camera off its clamp" },
    .{ .frames = 1, .key = key.right_jump, .why = "jump while walking: the arc plus the walk step" },
    .{ .frames = 59, .key = key.right, .why = "hold the walk through the arc and the landing" },
    .{ .frames = 20, .key = key.none, .why = "stand still, so the camera settles on its guide" },
    .{ .frames = 1, .key = key.jump, .why = "a standing jump: the arc with no walk step under it" },
    .{ .frames = 39, .key = key.none, .why = "up and down again, and settle" },
    .{ .frames = 60, .key = key.left, .why = "walk back, which turns her and reverses the camera" },
    .{ .frames = 20, .key = key.none, .why = "stand" },
    .{ .frames = 24, .key = key.down, .why = "Down into the crouch, then sixteen more frames into the ball" },
    .{ .frames = 220, .key = key.left, .why = "roll left off the ledge, land fast, and bounce" },
    .{ .frames = 60, .key = key.none, .why = "fly the bounce out and land: she must still be a ball" },
    .{ .frames = 20, .key = key.up, .why = "Up, the only way out of the ball, which must still work" },
    .{ .frames = 59, .key = key.left, .why = "walk left off the ledge, with enemies loaded on both machines, into the Senjoo's contact and the first frames of its knockback (1.0 Step 9)" },
};

pub const segment_frames: u16 = blk: {
    var n: u16 = 0;
    for (segment) |p| n += p.frames;
    break :blk n;
};

/// How many movie frames `zig build verify`'s reachable rung offers the port.
///
/// **This used to be load-bearing and is not any more.** `perCode` derives the
/// exit channel's resolution from the reference's *length*, so before the
/// bisection landed, the frame a divergence was reported at was the bottom edge
/// of a bucket whose width depended on how much movie was asked for. Measured
/// 2026-09-01 on one unchanged cart, only `want` changing:
///
///     want 500  -> REACHABLE 371   (bucket 371-377, per_code 7)
///     want 600  -> REACHABLE 376   (bucket 376-383, per_code 8)
///     want 900  -> REACHABLE 372   (bucket 372-383, per_code 12)
///     want 1200 -> REACHABLE 375   (bucket 375-389, per_code 15)
///
/// Four different numbers for one unchanged port, which is why the two
/// constants used to have to travel together.
///
/// **Re-measured 2026-09-05 with `Bisect` pinning the frame: 375, 375, 375,
/// 375.** The same four values of `want`, the same cart, one number. The floor
/// is now a fact about the port rather than about this constant, so `want` may
/// be retuned on its own -- it decides how much of the run is *offered*, and
/// nothing else. What it still cannot do is fall below the floor: a rung that
/// offers 300 frames cannot report 375.
///
/// (The 2026-09-01 note here said the four buckets intersect at 376-377 and
/// that this was where the real divergence lay. It is now measured at 375, and
/// the intersection argument is not the reason -- those four runs predate the
/// pose becoming a graded quantity on 2026-09-02, so they describe a different
/// port. An intersection of buckets from four separate runs was never evidence
/// about any one of them, which is the sort of thing a bisection settles and an
/// argument does not.)
/// **900 -> 2000 on 2026-09-07.** Step 6 took the port past every frame 900
/// offers: the rung read 899 of 899, "nothing: every frame offered matched",
/// which is a rung that has stopped measuring anything. The window is the one
/// thing here that may be retuned freely, so it was, and the port stops at
/// 1396 instead.
pub const movie_gate_frames: usize = 2000;

/// The floor the reachable rung fails under, at `movie_gate_frames`.
///
/// This is F10's progress metric and it is meant to be *raised*: a change that
/// gets the port further is a deliberate edit here, and a change that shortens
/// the run cannot pass.
///
/// **An exact frame since 2026-09-05, and no longer a bucket edge.** It is the
/// first frame on which Samus's position disagrees with the any% run, pinned by
/// `Bisect` in three extra emulator runs. Before that it was the bottom edge of
/// a `perCode(899)`-wide bucket, which understated by up to 14 frames and moved
/// whenever the bucket moved: 372 on 2026-09-01 and 375 on 2026-09-02 for one
/// unchanged port, because the pose became a third graded quantity and narrowed
/// `codes_per_quantity` from 80 to 60.
///
/// **It did not rise, and the plan expected it to.** A bucket's bottom edge
/// understates by up to `per_code - 1`, so making the measurement exact should
/// have moved the number up. Here it did not: at `want` 900 the bucket's bottom
/// edge was 375 and the divergence is at 375, so the two coincided. That is
/// luck about this width and not a property -- at `want` 500, 600 and 1200 the
/// old edges were 371, 376 and 372 against the same exact 375, one of them
/// *over*-stating. `anchored_gate_floor` is where the understatement was real.
///
/// **375 -> 420 on 2026-09-07, and this one is the port.** Step 5b gave the
/// transition its duration, so the run's first door stops being where the count
/// ends and becomes 45 frames the port plays: it holds Samus for the 99 frames
/// the interpreter owns, warps on the frame the original warps on, and scrolls
/// the incoming screen in at four pixels a frame behind her. `zig build trace
/// -- stretch 0 372 18` says "no divergence: every frame matched" across all of
/// it.
///
/// **375 was not what it looked like**, and that is worth keeping. The port
/// used to reach it by standing still for the 94 frames the original spends
/// inside the transition -- the original because it is busy, the port because
/// it had no transition to run. The two numbers 375 are unrelated facts.
///
/// **420 -> 1396 on 2026-09-07**, by Step 6, and in two steps that are worth
/// separating.
///
/// The port first reached **899 of the 899 frames `movie_gate_frames` offered**
/// -- every one of them -- so the window was raised to 2000 and the rung asked
/// again. What had been holding it at 420 was one line: `!Meta`, the base the
/// streamer reads metatiles through, was derived only inside `LoadScreen`, and
/// `LoadScreen` runs at boot. A `TILETABLE` opcode changed `!TileTable` and
/// nothing else, so the room on the far side of the run's first door was drawn
/// -- and, since collision is a lookup into that same buffer, *walked* --
/// through the tileset the cart booted with. She rolled off a floor 45 frames
/// into the new room. `LoadMetaBase` is that derivation given a name.
///
/// The rung then stopped on a **pose** divergence at frame 1396, which was the
/// first time this count had stopped on the pose machine since Phase 0a. Read
/// beside the line above it in the report, that number came with a warning: the
/// movie asked for a bit the port had no key for at frame **1368**, 28 frames
/// earlier, so the ceiling and the stop were close enough together that the
/// stop should not have been attributed to the pose machine without looking.
///
/// **1396 -> 1466 on 2026-09-09, and the warning was the reason.** Step 12b
/// gave the port a beam and this commit gives the movie's `B` to the cart, so
/// the 28 frames between the ceiling and the stop stop being frames the port
/// was handed a different pad than the run pressed. The stop is a position
/// divergence again and it is 70 frames further in.
///
/// **This is a measurement-affecting change and it is separated from the port
/// that made it possible for that reason**, the way `codes_per_quantity` was:
/// adding a bit to `supported_input_bits` alters what the cart is handed on
/// every graded frame of every rung, so a floor that moves in the same commit
/// as a mechanism cannot be attributed to either. The commit before this one
/// landed the whole projectile half with `B` still withheld and moved nothing.
/// **1466 -> 1999 on 2026-09-15, Step 17, and 1999 is the whole offered window
/// rather than a new divergence point.** Restoring `jsr DrawSamus` to
/// `.transitionFrame` fixed more than the picture: `!OnscreenX` is what
/// `HandleCamera`'s horizontal door triggers read, and it had been holding its
/// pre-transition value for every frame of a crossing, so each crossing left
/// the trigger reading a stale column and the run stopped soon after the first.
/// With the draw restored the port plays every frame the movie offers.
///
/// **So this floor no longer bounds anything, and that is worth saying rather
/// than leaving to be discovered.** At 1999 of 1999 the rung can only go red; it
/// cannot record an improvement, because there is none left to record inside
/// this window. Raising `movie_frames` is what would give it room again, and
/// that is a deliberate edit with its own cost -- every graded frame is an
/// emulator frame -- not something to do in passing.
pub const movie_gate_floor: usize = 1999;

/// How far into the movie the anchored sweep looks for handovers.
///
/// Past the horizon the replay is no longer the published run, so the anchors
/// stop there whatever this says -- `anchorsFrom` clamps them. This only has to
/// be past the horizon of both published runs, which are 8407 and 4566.
pub const anchored_gate_limit: usize = 9000;

/// The floor the anchored rung fails under, summed across every gradable
/// stretch.
///
/// The same metric as `movie_gate_floor` and a *different number from it*, for
/// the reason the two rungs exist separately: a single anchor measures how far
/// the port survives from the game's one handover of control, and this measures
/// how much of the run it can play at all. Neither bounds the other, and a
/// change that lengthens one can shorten the other -- which is the whole
/// argument for reporting per stretch as well as in total.
///
/// **A sum of exact frames since 2026-09-05, and this is where the bucket was
/// actually costing something.** Nine stretches produce a number, so nine
/// bucket edges were being added up and each understated by up to its own
/// stretch's `per_code - 1`. Pinned, the sum is **394 where the bucket gave
/// 386** -- eight frames the port had already reached and was not being
/// credited with. Stretch 0 moves 371 -> 375 and stretch 6 moves 15 -> 19; no
/// stretch stops anywhere new, so the eight frames are resolution and not
/// reach.
///
/// The history, because the number moved twice for reasons that were not the
/// port: 394 on 2026-09-01, then 390 on 2026-09-02 when the pose became a third
/// graded quantity and narrowed `codes_per_quantity` from 80 to 60, widening
/// stretch 0's buckets from 5 frames to 7. It reads 394 again now, and the
/// coincidence with the first measurement is exactly that -- the 2026-09-01
/// figure was a sum of edges at a different width against a different port.
///
/// **This is why the pin is on by default -- in the gate and in `zig build
/// oracle -- anchored` alike -- and `bucket` is only a way to reproduce the old
/// number.** Measured 2026-09-05: the sweep takes 15.8s pinned against 7.6s
/// bucketed, on top of a run that already replays 8407 frames of Game Boy and
/// builds thirteen carts. Eight frames of honesty for eight seconds, inside a
/// `zig build verify` that takes 130.
///
/// **394 -> 445 on 2026-09-07, and this time it is the port.** Step 5 gave the
/// engine `SeedPlacement`, which applies the boot record after the boot script
/// instead of before it, and ends by calling `LoadCellFlags`. Until then
/// nothing derived `!Scroll` at boot at all: WRAM clears to zero, so a freshly
/// booted cart ran with **every edge open** until the camera happened to cross
/// into a second cell and `LatchCell` re-read the flags. That was invisible
/// wherever the anchor's own cell blocks nothing.
///
/// It is not invisible at stretch 6, which is the entire difference: anchor
/// 4370, map 15 cell $10, whose scroll byte is $0E -- left, up and down all
/// blocked, three edges of four. Booted with them open the camera left the room
/// in nineteen frames. Booted with them read it holds for **70**. No other
/// stretch moves, and stretch 0 does not, because its cell $76 blocks only
/// downward and the port never asked to go that way.
/// **445 -> 462 on 2026-09-07**, all of it stretch 0. With the transition's
/// duration ported, the stretch anchored on the run's frame 328 plays all 392
/// of its frames instead of stopping on the door at 375, and the sweep's
/// stretch count drops from 11 red to 10.
/// **462 -> 665 on 2026-09-07**, by Step 6's `SeedWindow`, and all of it is
/// stretch 6: 70 frames of 273 to all 273. A cart booted from a mid-run record
/// filled every one of the 1024 tilemap slots from the boot cell's own screen,
/// so the neighbour on the far side of any screen boundary was that screen's
/// own edge repeated -- solid where the world is open. The nine stretches that
/// stop on frame 0 are unmoved, which says their divergence is something else
/// and not this.
pub const anchored_gate_floor: usize = 665;

/// How many of the run's stretches the cart must be able to be booted into at
/// all, which is a different failure from playing none of one.
///
/// **Added 2026-09-05 with B12, because the sum did not move and the correction
/// was real anyway.** A stretch is gradable when `settleAnchors` finds a frame
/// whose room the cart reproduces tile for tile; four never did, and all four
/// were tileset assignment rather than anything about the port. Fixing two of
/// them -- map 3 cells $51 and $71, where `screens.assign` chose table 9 and
/// the Game Boy was showing table 4 -- took the gradable count from 9 to 11 and
/// the offered frames from 5174 to 6848, while the *sum* stayed at exactly 394
/// because the port reaches frame 0 of both new stretches.
///
/// So the sum alone would have recorded this work as nothing happening. This
/// floor is what makes it visible, and what fails if the assignment regresses:
/// a stretch that stops being gradable is a room the port can no longer be
/// asked about.
///
/// The remaining two are anchors 11 and 12, both map 2 cell $0D, where the
/// assignment says table 4 and the Game Boy showed table 6 on all 399 compared
/// tiles. No door in bank $B states table 6, so no inference over the door
/// table can reach it -- see `docs/bug_tracker.md`.
pub const anchored_gradable_floor: usize = 11;

/// Any segment's inputs as one entry per frame.
pub fn phaseKeys(allocator: std.mem.Allocator, phases: []const Phase) ![]Key {
    var n: usize = 0;
    for (phases) |p| n += p.frames;
    const out = try allocator.alloc(Key, n);
    var f: usize = 0;
    for (phases) |p| {
        for (0..p.frames) |_| {
            out[f] = p.key;
            f += 1;
        }
    }
    return out;
}

/// The spider segment (Step 14b): the segment's start, Spider Ball held, and a
/// schedule that takes the ball through what `snes boot` phase 25 cannot --
/// round corners, up and across surfaces, and off them into a fall. The
/// recording's own spider route could not be graded: every anchor in it boots
/// a cell whose table the cart gets wrong (see the plan, Step 14b).
pub const spider_segment = [_]Phase{
    .{ .frames = 24, .key = key.down, .why = "Down into the crouch, then into the ball" },
    .{ .frames = 10, .key = key.none, .why = "let go, so the next Down is a new press" },
    .{ .frames = 1, .key = key.down, .why = "Down with Spider Ball held: the spider at rest" },
    .{ .frames = 5, .key = key.none, .why = "at rest on the floor" },
    .{ .frames = 80, .key = key.right, .why = "roll right along the floor" },
    .{ .frames = 5, .key = key.none, .why = "let go: the rest pose, and the rotation cleared" },
    .{ .frames = 160, .key = key.left, .why = "and left, the other rotation, past where it started" },
    .{ .frames = 5, .key = key.none, .why = "rest" },
    .{ .frames = 330, .key = key.left, .why = "on left, over the ledge and down its face" },
    .{ .frames = 5, .key = key.none, .why = "rest on the wall" },
    .{ .frames = 60, .key = key.up, .why = "Up on a wall: back up the face" },
    .{ .frames = 5, .key = key.none, .why = "rest" },
    .{ .frames = 60, .key = key.down, .why = "Down on a wall: down the face again" },
    .{ .frames = 1, .key = key.jump, .why = "A: off the wall as a ball, falling" },
    .{ .frames = 4, .key = key.none, .why = "falling" },
    .{ .frames = 1, .key = key.down, .why = "Down in the falling ball: the spider falling" },
    .{ .frames = 60, .key = key.none, .why = "fall, attach to what it lands on, and rest" },
    .{ .frames = 1, .key = key.jump, .why = "A: out of the spider" },
    .{ .frames = 30, .key = key.none, .why = "a ball again" },
};

/// 1.0 Step 7's loadout segments (C5): the segment's start with one item,
/// set on the cart through the debug menu, and a schedule that takes the
/// item's branches. Each has an engine fault, its item's test blanked, that
/// must make the segment differ.
pub const LoadoutSegment = struct {
    name: []const u8,
    item: @import("items.zig").Collected,
    phases: []const Phase,
    fault: Patch,
};

pub const hi_jump_segment = [_]Phase{
    .{ .frames = 10, .key = key.none, .why = "stand" },
    .{ .frames = 40, .key = key.jump, .why = "a standing jump held to the top: the higher arc and the faster rise" },
    .{ .frames = 100, .key = key.none, .why = "down again and settle" },
    .{ .frames = 1, .key = key.jump, .why = "a standing jump let go at once: the short hop" },
    .{ .frames = 60, .key = key.none, .why = "down and settle" },
    .{ .frames = 10, .key = key.right, .why = "walk right" },
    .{ .frames = 1, .key = key.right_jump, .why = "A while walking: the spin, on `SetJumpArc`'s arc" },
    .{ .frames = 30, .key = key.right_jump, .why = "held through the spin's rise" },
    .{ .frames = 110, .key = key.right, .why = "over, down against the wall, and land" },
    .{ .frames = 20, .key = key.none, .why = "stand" },
    .{ .frames = 1, .key = key.down, .why = "Down: the crouch" },
    .{ .frames = 10, .key = key.none, .why = "crouched" },
    .{ .frames = 1, .key = key.jump, .why = "a jump from the crouch: its own arc" },
    .{ .frames = 40, .key = key.jump, .why = "held" },
    .{ .frames = 100, .key = key.none, .why = "down and settle" },
};

pub const space_jump_segment = [_]Phase{
    .{ .frames = 10, .key = key.none, .why = "stand" },
    .{ .frames = 40, .key = key.left, .why = "walk left, for room" },
    .{ .frames = 10, .key = key.right, .why = "turn and walk right" },
    .{ .frames = 1, .key = key.right_jump, .why = "A while walking: the spin" },
    .{ .frames = 20, .key = key.right_jump, .why = "held through the rise" },
    .{ .frames = 30, .key = key.right, .why = "let go: over the top and down into the window" },
    .{ .frames = 25, .key = key.right_jump, .why = "A again, held: the space jump's own arc, its rise the whole way" },
    .{ .frames = 45, .key = key.right, .why = "over the top, against the wall, and down into the window" },
    .{ .frames = 25, .key = key.left_jump, .why = "a second, turned round and held" },
    .{ .frames = 100, .key = key.left, .why = "over, down, and land walking" },
    .{ .frames = 30, .key = key.none, .why = "stand" },
};

pub const spring_ball_segment = [_]Phase{
    .{ .frames = 10, .key = key.none, .why = "stand" },
    .{ .frames = 1, .key = key.down, .why = "Down: the crouch" },
    .{ .frames = 5, .key = key.none, .why = "let go" },
    .{ .frames = 1, .key = key.down, .why = "Down again: the ball" },
    .{ .frames = 10, .key = key.none, .why = "a ball on the floor" },
    .{ .frames = 1, .key = key.jump, .why = "A in the ball on the floor: the spring ball's jump" },
    .{ .frames = 30, .key = key.jump, .why = "held" },
    .{ .frames = 50, .key = key.none, .why = "down and bounce" },
    .{ .frames = 1, .key = key.right_jump, .why = "a jump rolling right" },
    .{ .frames = 50, .key = key.right, .why = "across and down" },
    .{ .frames = 1, .key = key.jump, .why = "a short one let go at once" },
    .{ .frames = 50, .key = key.none, .why = "down and bounce" },
    .{ .frames = 1, .key = key.left_jump, .why = "rolling left" },
    .{ .frames = 40, .key = key.left_jump, .why = "held" },
    .{ .frames = 5, .key = key.left, .why = "let go of A in the air" },
    .{ .frames = 1, .key = key.left_jump, .why = "A in the air: no jump from the air" },
    .{ .frames = 60, .key = key.none, .why = "down" },
};

pub const loadout_segments = [_]LoadoutSegment{
    .{ .name = "hi_jump", .item = .high_jump, .phases = &hi_jump_segment, .fault = .{ .label = "PoseJump_hiJumpRise", .offset = 1, .bytes = &.{0x00} } },
    .{ .name = "space_jump", .item = .space_jump, .phases = &space_jump_segment, .fault = .{ .label = "PoseSpinJump_spaceItem", .offset = 1, .bytes = &.{0x00} } },
    .{ .name = "spring_ball", .item = .spring_ball, .phases = &spring_ball_segment, .fault = .{ .label = "PoseMorph_springItem", .offset = 1, .bytes = &.{0x00} } },
};

/// 1.0 Step 8c's beam segments (C5): the segment's start with a beam set on
/// the cart through the debug menu's beam row, and the projectile array
/// compared frame for frame beside Samus. `beam_wall_segment` fires each beam
/// into the room's wall and up; the enemy segments fire the plasma at a seeded
/// enemy (`Enemy`), which is where James saw its shots sometimes fly on after
/// a kill and sometimes stop (2026-09-28).
pub const Beam = enum { power, ice, wave, spazer, plasma };

/// A beam's `samusBeam` value, from the ROM: the new game's for the power
/// beam, the pickup's for the rest (`scenario.pickups`).
pub fn beamValue(rom: []const u8, b: Beam) !u8 {
    const scenario = @import("scenario.zig");
    if (b == .power) return (try scenario.Samus.newGame(rom)).beam;
    return (try scenario.pickups(rom)).beams[@intFromEnum(b) - 1];
}

/// 1.0 Step 25: a spin jump to the right, into the spikes on the ceiling of
/// `$D:$05`: the hurt is 00:$2021's, the tile read's spike arm, and its damage
/// the room's `DAMAGE` operand. No enemy in the room.
pub const spike_segment = [_]Phase{
    .{ .frames = 10, .key = key.none, .why = "stand under the ledge" },
    .{ .frames = 30, .key = key.right_jump, .why = "a spin jump to the right, into the ceiling's spikes" },
    .{ .frames = 80, .key = key.none, .why = "the hurt, the boost, and down again" },
};

/// 1.0 Step 27b, James's playthrough: hurt by spikes entering `$F:$C3` from
/// `$C:$3C`'s door ledge, after a jump scrolled the doorway partly off screen
/// and back. Door $B9 is a bare `WARP $F, $C4`: the Game Boy redraws three
/// columns ahead (00:$29C4) and keeps the rest of the tilemap it had.
pub const door_spike_segment = [_]Phase{
    .{ .frames = 40, .key = key.none, .why = "down onto the ledge by the door, and stand" },
    .{ .frames = 1, .key = key.jump, .why = "a standing jump" },
    .{ .frames = 36, .key = key.jump, .why = "held, the doorway scrolled down" },
    .{ .frames = 60, .key = key.none, .why = "down onto the ledge again, and the camera back" },
    .{ .frames = 14, .key = key.left, .why = "left off the ledge's end, into the door" },
    .{ .frames = 160, .key = key.none, .why = "carried through into $F:$C3's door ledge, and stand" },
};

/// 1.0 Step 27d, James's playthrough: `$9:$E3`'s coral hurt once when walked
/// through, and on every tick when jumped through. The coral is acid (block
/// bit 4) over the top of the step she lands on, columns 10 to 17. Both are the
/// original's: the ROM tests acid in the top, bottom and spider probes only
/// (`AcidProbe`'s six sites), not the horizontal one. Standing and running
/// call the top probe only on a jump press, and the bottom probe reads the
/// floor under her, which is not acid; a jump's top probes pass through the
/// coral. Graded against our Game Boy: the walk takes nothing, the jump four
/// ticks.
pub const coral_walk_segment = [_]Phase{
    .{ .frames = 30, .key = key.none, .why = "down onto the step, left of the coral, and stand" },
    .{ .frames = 120, .key = key.right, .why = "walk right through the coral, and off the step" },
    .{ .frames = 60, .key = key.none, .why = "stand" },
};

pub const coral_jump_segment = [_]Phase{
    .{ .frames = 30, .key = key.none, .why = "down onto the step, left of the coral, and stand" },
    .{ .frames = 6, .key = key.right, .why = "walk right" },
    .{ .frames = 40, .key = key.right_jump, .why = "a jump to the right, into the coral" },
    .{ .frames = 80, .key = key.right, .why = "through it, and off the step" },
    .{ .frames = 60, .key = key.none, .why = "stand" },
};

pub const BeamSegment = struct {
    name: []const u8,
    beam: Beam,
    enemy: ?Enemy = null,
    phases: []const Phase,
    /// Engine faults, each of which must make the segment differ. None for
    /// the power and ice beams into the wall, which are the contrast: the arms
    /// they take are the default's, faulted by the others' segments.
    faults: []const Patch = &.{},
    /// 1.0 Step 9: SAMUS rows set through the menu beside the beam, and
    /// whether her health is graded (`Take.health`).
    items: []const @import("scenario.zig").Row = &.{},
    health: bool = false,
    /// 1.0 Step 11: the room to start in, when the terrain is the point.
    room: ?Room = null,
    /// 1.0 Step 27b: through a door that warps (`Door`).
    door: bool = false,
};

const fire_up: Key = .{ .up = true, .fire = true };
const fire_right: Key = .{ .right = true, .fire = true };

pub const beam_wall_segment = [_]Phase{
    .{ .frames = 10, .key = key.none, .why = "stand" },
    .{ .frames = 60, .key = key.right, .why = "walk right, up against the wall" },
    .{ .frames = 5, .key = key.none, .why = "let go" },
    .{ .frames = 1, .key = fire_right, .why = "a shot right, into the wall" },
    .{ .frames = 59, .key = key.none, .why = "stopped by it, or through it to the window's edge" },
    .{ .frames = 1, .key = fire_up, .why = "a shot straight up" },
    .{ .frames = 59, .key = key.none, .why = "to the ceiling or the window's edge" },
    .{ .frames = 2, .key = key.left, .why = "turn round" },
    .{ .frames = 1, .key = key.none, .why = "let go" },
    .{ .frames = 1, .key = key.fire, .why = "a shot left" },
    .{ .frames = 59, .key = key.none, .why = "away across the room" },
};

pub const beam_enemy_segment = [_]Phase{
    .{ .frames = 2, .key = key.none, .why = "stand, the enemy seeded before frame 1" },
    .{ .frames = 1, .key = fire_right, .why = "the plasma's three at it, before a hopper is off the ground" },
    .{ .frames = 40, .key = key.none, .why = "what each of the three does at the enemy" },
};

/// 1.0 Step 8d: an Autoad frozen on the floor, jumped onto, stood on, and
/// ridden until it thaws. The phases are tuned so she lands inside its box.
pub const ice_stand_segment = [_]Phase{
    .{ .frames = 2, .key = key.none, .why = "stand, the enemy seeded before frame 1" },
    .{ .frames = 1, .key = fire_right, .why = "an ice shot at it, before it is off the ground" },
    .{ .frames = 20, .key = key.none, .why = "the shot lands and it freezes" },
    .{ .frames = 1, .key = key.jump, .why = "a standing jump, straight up beside it" },
    .{ .frames = 20, .key = key.jump, .why = "held through the rise" },
    .{ .frames = 15, .key = key.right_jump, .why = "over the top of it" },
    .{ .frames = 10, .key = key.right, .why = "over it" },
    .{ .frames = 60, .key = key.none, .why = "down onto it, and stand" },
    .{ .frames = 400, .key = key.none, .why = "stand on it until it thaws, and after" },
};

/// 1.0 Step 9: walked into an Autoad and hurt, her health graded on every
/// frame. With Varia and without, so the halving (00:$2F6B) is seen both ways.
pub const hurt_segment = [_]Phase{
    .{ .frames = 2, .key = key.none, .why = "stand, the enemy seeded before frame 1" },
    .{ .frames = 40, .key = key.right, .why = "walk right into it" },
    .{ .frames = 80, .key = key.none, .why = "the hurt, the knockback, and down again" },
};

/// 1.0 Step 9: a spin jump through an Autoad with Screw Attack: the contact
/// kills it (00:$3629) and she flies on unhurt.
pub const screw_segment = [_]Phase{
    .{ .frames = 2, .key = key.none, .why = "stand, the enemy seeded before frame 1" },
    .{ .frames = 4, .key = key.right, .why = "walk right" },
    .{ .frames = 1, .key = key.right_jump, .why = "A while walking: the spin" },
    .{ .frames = 12, .key = key.right_jump, .why = "held, spinning into it" },
    .{ .frames = 60, .key = key.right, .why = "through it, over, and down" },
    .{ .frames = 30, .key = key.none, .why = "stand" },
};

/// 1.0 Step 11: onto a platform that carries her -- a septogg, which sinks
/// under her until it meets the floor, or a moving flitt, which glides.
pub const ride_segment = [_]Phase{
    .{ .frames = 2, .key = key.none, .why = "stand, the platform seeded before frame 1" },
    .{ .frames = 1, .key = key.jump, .why = "a standing jump" },
    .{ .frames = 36, .key = key.jump, .why = "held to the top of the rise" },
    .{ .frames = 26, .key = key.left_jump, .why = "over the top of it, away from the wall" },
    .{ .frames = 60, .key = key.none, .why = "down onto it, and ride it down" },
    // Off its right edge, back towards where she started: its left edge is
    // at the seam with the next screen west, whose last two columns the two
    // machines do not agree on (`docs/bug_tracker.md`, 2026-09-29).
    .{ .frames = 30, .key = key.right, .why = "walk off it, back the way she came" },
    .{ .frames = 60, .key = key.none, .why = "and it rises back the way it sank" },
};

/// The septogg over sand: walked onto from the pillar beside the pit, ridden
/// down, and walked off back onto the pillar.
pub const sand_ride_segment = [_]Phase{
    .{ .frames = 2, .key = key.none, .why = "stand on the sand, the platform seeded before frame 1" },
    .{ .frames = 1, .key = key.left_jump, .why = "a jump towards it" },
    .{ .frames = 33, .key = key.left_jump, .why = "held, drifting over it at the top of the rise" },
    .{ .frames = 80, .key = key.none, .why = "down onto it, and ride it into the sand" },
    .{ .frames = 1, .key = key.jump, .why = "a jump, from inside the sand" },
    .{ .frames = 40, .key = key.jump, .why = "held" },
    .{ .frames = 40, .key = key.left, .why = "walk left" },
    .{ .frames = 40, .key = key.right, .why = "and right" },
    .{ .frames = 30, .key = key.none, .why = "let go" },
};

/// The moving flitt glides into place under a straight jump rather than
/// being jumped onto, since it will not stay put, and carries her right and
/// then back left.
pub const flitt_ride_segment = [_]Phase{
    .{ .frames = 2, .key = key.none, .why = "stand, the platform seeded before frame 1" },
    .{ .frames = 1, .key = key.jump, .why = "a standing jump" },
    .{ .frames = 36, .key = key.jump, .why = "held to the top of the rise" },
    .{ .frames = 200, .key = key.none, .why = "down onto it as it glides under her, and ride" },
};

pub const beam_segments = [_]BeamSegment{
    .{ .name = "power", .beam = .power, .phases = &beam_wall_segment },
    .{ .name = "ice", .beam = .ice, .phases = &beam_wall_segment },
    .{ .name = "wave", .beam = .wave, .phases = &beam_wall_segment, .faults = &.{
        // Not the wave: it takes the default arm, straight and stopped by the wall.
        .{ .label = "HandleProjectiles_waveDispatch", .offset = 1, .bytes = &.{0xFF} },
    } },
    .{ .name = "spazer", .beam = .spazer, .phases = &beam_wall_segment, .faults = &.{
        // One shot, not three: the loop back into `samusShoot` never taken.
        .{ .label = "SamusShoot_spazerThree", .offset = 1, .bytes = &.{0xFF} },
    } },
    .{ .name = "plasma", .beam = .plasma, .phases = &beam_wall_segment, .faults = &.{
        // The wall stops it, as it stops the power beam.
        .{ .label = "HandleProjectiles_plasmaClips", .offset = 1, .bytes = &.{0xFF} },
        // The defect this rung found: the three in the other order.
        .{ .label = "SamusShoot_plasmaOrder", .bytes = &.{0xD0} },
    } },
    // **Plasma against enemies: no shot pierces one.** Each of the three is
    // deleted on its own hit (00:$31F1, 01:$52E3); what outlives the kill flies
    // on, because a dead enemy is no longer a target. So how many stop is how
    // many are in the box before the enemy pass kills it, and that is the
    // pixels between them -- James saw both on the cart (2026-09-28). An Autoad
    // (`$E:$82`, health 14), which the plasma's 30 kills in one: from $30 all
    // three stop, two spawned inside it; from $38 two stop and the rearmost
    // flies on. The fault ignores the hit, so all three fly through.
    .{ .name = "plasma kill, all stop", .beam = .plasma, .phases = &beam_enemy_segment, .enemy = .{ .bank = 0xE, .cell = 0x82, .ai = 0x61DB, .dy = 0x14, .dx = 0x30 }, .faults = &.{
        .{ .label = "HandleProjectiles_enemyHit", .bytes = &.{0x80} },
    } },
    .{ .name = "plasma kill, one on", .beam = .plasma, .phases = &beam_enemy_segment, .enemy = .{ .bank = 0xE, .cell = 0x82, .ai = 0x61DB, .dy = 0x14, .dx = 0x38 }, .faults = &.{
        .{ .label = "HandleProjectiles_enemyHit", .bytes = &.{0x80} },
    } },
    // And one it cannot kill: the missile door (`$E:$6A`) takes every beam
    // and is hurt by none, so all three are spent on it.
    .{ .name = "plasma soaked", .beam = .plasma, .phases = &beam_enemy_segment, .enemy = .{ .bank = 0xE, .cell = 0x6A, .ai = 0x6A14, .dy = 0x14, .dx = 0x40 }, .faults = &.{
        .{ .label = "HandleProjectiles_enemyHit", .bytes = &.{0x80} },
    } },
    .{ .name = "hurt", .beam = .power, .phases = &hurt_segment, .health = true, .enemy = .{ .bank = 0xE, .cell = 0x82, .ai = 0x61DB, .dy = 0x14, .dx = 0x30 }, .faults = &.{
        // The defect this segment found: the horizontal entry leaving the
        // collision flag clear, so the play handler's pass runs again after a
        // walk's hit and puts the default boost over the hit's.
        .{ .label = "CollideSamusEnemiesHoriz_flag", .offset = 1, .bytes = &.{0x00} },
        // 1.0 Step 25: her i-frames never set the attribute, and the
        // attribute never moves a part to OBP1. Code 253 for both.
        .{ .label = "DrawSamus_hurtAttr", .bytes = &.{0x80} },
        .{ .label = "DrawSprite_pal1", .bytes = &.{0x80} },
    } },
    .{ .name = "spike", .beam = .power, .room = .{ .bank = 0xD, .cell = 0x05, .dx = 0x38 }, .phases = &spike_segment, .health = true, .faults = &.{
        // Step 25's arm: the tile read never hurts.
        .{ .label = "SampleTile_spike", .bytes = &.{0x80} },
    } },
    .{ .name = "door spike", .beam = .power, .room = .{ .bank = 0xC, .cell = 0x3C, .dx = -0x60 }, .phases = &door_spike_segment, .health = true, .door = true, .faults = &.{
        // The defect this segment found: the crossing frame's hurt kept.
        .{ .label = "StartTransition_hurt", .bytes = &.{ 0xEA, 0xEA, 0xEA } },
    } },
    .{ .name = "coral walk", .beam = .power, .room = .{ .bank = 0x9, .cell = 0xE3, .dx = -0x50, .dy = 0x14 }, .phases = &coral_walk_segment, .health = true },
    .{ .name = "coral jump", .beam = .power, .room = .{ .bank = 0x9, .cell = 0xE3, .dx = -0x50, .dy = 0x14 }, .phases = &coral_jump_segment, .health = true, .faults = &.{
        // The acid test never passes: no tick hurts. `beq` to `bra`.
        .{ .label = "AcidProbe", .offset = 6, .bytes = &.{0x80} },
    } },
    .{ .name = "varia hurt", .beam = .power, .items = &.{.varia}, .phases = &hurt_segment, .health = true, .enemy = .{ .bank = 0xE, .cell = 0x82, .ai = 0x61DB, .dy = 0x14, .dx = 0x30 }, .faults = &.{
        // The halving skipped: the whole damage.
        .{ .label = "ApplyDamageApply_varia", .bytes = &.{0x80} },
    } },
    .{ .name = "screw kill", .beam = .power, .items = &.{.screw}, .phases = &screw_segment, .health = true, .enemy = .{ .bank = 0xE, .cell = 0x82, .ai = 0x61DB, .dy = 0x14, .dx = 0x30 }, .faults = &.{
        // The screw's item test never passes: a spin is a hurt.
        .{ .label = "CollideResolve_screwItem", .bytes = &.{0x80} },
    } },
    .{ .name = "septogg ride", .beam = .power, .phases = &ride_segment, .enemy = .{ .bank = 0xB, .cell = 0x24, .ai = 0x6841, .dy = 0x10, .dx = -0x10 }, .faults = &.{
        // She rides it down but is not carried: the sink leaves her behind.
        .{ .label = "EnAiSeptogg_carry", .offset = 1, .bytes = &.{0x00} },
    } },
    .{ .name = "septogg sand", .beam = .power, .room = .{ .bank = 0xB, .cell = 0x24, .dx = 0x68 }, .phases = &sand_ride_segment, .enemy = .{ .bank = 0xB, .cell = 0x24, .ai = 0x6841, .dy = 0x10, .dx = -0x18 }, .faults = &.{
        // The ride into the sand, and the trap, need the carry.
        .{ .label = "EnAiSeptogg_carry", .offset = 1, .bytes = &.{0x00} },
    } },
    .{ .name = "flitt ride", .beam = .power, .phases = &flitt_ride_segment, .enemy = .{ .bank = 0xB, .cell = 0xF1, .ai = 0x68FC, .dy = 0x10, .dx = -0x20 }, .faults = &.{
        // Carried with the platform's X but not her own: two `NOP`s over `INC`/`DEC !SamusX`.
        .{ .label = "EnAiFlittMoving_carryRight", .bytes = &.{ 0xEA, 0xEA } },
        .{ .label = "EnAiFlittMoving_carryLeft", .bytes = &.{ 0xEA, 0xEA } },
    } },
    .{ .name = "ice stand", .beam = .ice, .phases = &ice_stand_segment, .enemy = .{ .bank = 0xE, .cell = 0x82, .ai = 0x61DB, .dy = 0x14, .dx = 0x30 }, .faults = &.{
        // The defect this segment found: the lift the other way round.
        .{ .label = "CollideSamusEnemiesDown_liftTest", .bytes = &.{0x90} },
        // A frozen enemy taken as a live one: a hurt, not a floor.
        .{ .label = "CollideResolve_iceCase", .offset = 3, .bytes = &.{0x80} },
        // The second: the landing snapped to the tile row on an enemy too.
        .{ .label = "PoseFall_enemyFloor", .offset = 3, .bytes = &.{0x80} },
    } },
};

pub fn gradeBeam(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    mesen_path: []const u8,
    resolution: Resolution,
    seg: BeamSegment,
    patch: ?Patch,
) !Report {
    const bits = (try @import("scenario.zig").pickups(rom)).bits;
    var mask: u8 = 0;
    for (seg.items) |row| mask |= bits[@intFromEnum(row)];
    const lo: Loadout = .{
        .via = .menu,
        .items = mask,
        .beam = try beamValue(rom, seg.beam),
        .enemy = seg.enemy,
        .projs = true,
        .health = seg.health,
        .room = seg.room,
        .door = seg.door,
        .patch = patch,
    };
    return gradeWith(allocator, io, rom, mesen_path, 8, false, resolution, seg.phases, lo);
}

/// The segment's inputs as one entry per frame, which is the form `Take` wants
/// and the form the generated script indexes.
pub fn segmentKeys(allocator: std.mem.Allocator) ![]Key {
    const out = try allocator.alloc(Key, segment_frames);
    for (0..segment_frames) |f| out[f] = keyAt(f);
    return out;
}

/// The input held on a given frame of the segment.
pub fn keyAt(frame: usize) Key {
    var at: usize = 0;
    for (segment) |p| {
        at += p.frames;
        if (frame < at) return p.key;
    }
    return key.none;
}

// ---- The reference --------------------------------------------------------

/// One frame of either machine's trace, in our units.
///
/// Position and camera only. Not because more would be hard -- the pose and the
/// cell are in `correspond.pairs` too -- but because comparing them would grade
/// the port against behaviour it does not have yet, and a gate that fails for
/// the wrong reason is worse than one that checks less.
pub const Frame = struct {
    samus_x: u16,
    samus_y: u16,
    camera_x: u16,
    camera_y: u16,
    /// **Compared, since 2026-09-02.** It was recorded and never compared for
    /// as long as the port had a walk and a jump and nothing else: grading a
    /// pose the engine had no handler for would have failed the gate for the
    /// wrong reason. The morph bug is what retired that argument. The bounce
    /// out of `PoseMorph` flies the jump arc, and the arc's exit was dropping
    /// the original's test of who was flying it -- so Samus finished a bounce
    /// standing rather than rolled up, on exactly the pixel the ball would have
    /// been on. Position and camera called that a match over all 644 frames;
    /// this field is the only one that could tell the difference.
    pose: u8 = 0,
    /// Recorded for the same reason and compared for none. The original's
    /// `samusFacingDirection` and ours are the same idea in different
    /// encodings, and `snes_trace.zig` prints them side by side.
    facing: u8 = 0,
    /// The pad byte the *game* acted on this frame ($FF80), and the frame
    /// counter `WalkSpeed` takes its 1/2 alternation from ($FF97). Neither is
    /// compared. They are here because the segment's first divergence was a
    /// disagreement about *when* an input takes effect, and no field in this
    /// struct could tell the two candidate causes apart: a port that acts a
    /// frame early, or a reference that is handed the press a frame late.
    pad: u8 = 0,
    counter: u8 = 0,
    /// `$D048`, the flag `samus_walkRight` tests at 00:$1C14 before it consults
    /// the counter at all: nonzero and the walk speed is 1 every frame instead
    /// of alternating. Our `!Water` is the same flag, so the pair of them is
    /// what tells a speed disagreement apart from a *contact* disagreement.
    water: u8 = 0,
    /// `bg_palette`, $D07E: the byte the vblank handler copies into `rBGP`.
    /// Recorded for the `fade` rung (Step 20) and compared by nothing in
    /// `firstDivergence`. Zero where a source does not sample it, which is
    /// every source but the movie and the segment.
    bg_palette: u8 = 0,
    /// The projectile array, `proj_fields` of each of its three slots: $DD00
    /// on the Game Boy, `!Projs` on the cart. Recorded by the segment and
    /// compared only by a take that asks (`Take.projs`, 1.0 Step 8c), since a
    /// segment that never fires would grade three empty slots.
    projs: [proj_bytes]u8 = @splat(0xFF),
    /// Enemy slot 0's status, Y, X and health, for `oracle -- beams` to print
    /// beside the shots. Compared by nothing: the `enemy AIs` rung grades
    /// slots.
    enemy0: [4]u8 = @splat(0xFF),
    /// Samus's health, `samusCurHealthHigh` over `samusCurHealthLow` ($D052,
    /// $D051) on the Game Boy and `!HealthHi`/`!HealthLo` on the cart, both
    /// BCD. Recorded by the segment and compared only by a take that asks
    /// (`Take.health`, 1.0 Step 9), since no segment before it was hurt.
    health: u16 = 0,
    /// How many of the frame's objects are on the second object palette: the
    /// Game Boy's OAM buffer up to `maxOamPrevFrame` with `OAMF_PAL1`, the
    /// cart's shadow up to `!OamIdx` on palette 1. Compared with `health`, by
    /// the same takes (1.0 Step 25): a hurt Samus is drawn on OBP1
    /// (01:$4B95-$4B9D, set for i-frames and acid at 01:$4DFC-$4E0D).
    obp1: u8 = 0,

    pub fn eql(a: Frame, b: Frame) bool {
        return a.samus_x == b.samus_x and a.samus_y == b.samus_y and
            a.camera_x == b.camera_x and a.camera_y == b.camera_y and
            a.pose == b.pose;
    }
};

// ---- The room both machines are standing in --------------------------------

/// Whether the reference and the cart were walking through the same terrain.
///
/// **A position comparison over two different rooms is not a comparison.** The
/// original's collision is a lookup into its own background tilemap, and ours
/// is a lookup into `!TilemapBuf`; if those hold different tiles, every frame
/// after the first step grades the port against a world it was never shown, and
/// the verdict says "Samus's position diverged" about a difference that is
/// entirely in the setup.
///
/// The cart's world is computable without an emulator: it is the boot cell's
/// 256 metatile indexes expanded through the table the boot record names. That
/// was checked against the cart itself -- `snes_trace.zig` reads `!TilemapBuf`
/// back out of a running cart, and it matched this expansion in all 1024 tiles.
///
/// ## Why this is not all 1024 tiles
///
/// The original's background map is a **moving window**, not a room. It is 32x32
/// tiles, which is 256x256 pixels, which is exactly one screen -- but it is
/// world-aligned rather than screen-aligned: the tile for world position
/// (x, y) always lives at map slot ((y/8) mod 32, (x/8) mod 32), and the game
/// keeps the 256x256 window ending at the camera correct by drawing the columns
/// and rows that scroll into it. Everything outside that window is whatever was
/// there before.
///
/// So once the camera is anywhere but a screen's own origin, the map holds
/// pieces of two screens, and demanding that it equal one converted cell in all
/// 1024 tiles demands something the original never does. What the two machines
/// genuinely have to agree on is the overlap: the slots the window puts inside
/// the boot cell. Samus is always inside the window and -- `chooseStart`
/// enforces it -- always inside the cell, so every tile her collision can reach
/// is in that overlap.
pub const World = struct {
    /// Tiles the two maps agree on, and tiles they were asked about: the slots
    /// the reference's own camera window places inside the cart's boot cell.
    matched: usize = 0,
    compared: usize = 0,
    /// The table the cart's boot record names, and the one that best explains
    /// what the Game Boy was actually showing. When they differ, the reference
    /// is standing somewhere else.
    cart_table: u4 = 0,
    gb_best_table: u4 = 0,
    gb_best_matched: usize = 0,
    /// Compared slots where the two differ **and the difference is a block the
    /// reference shot out**: the map has an intact respawning block and the
    /// trace has one of the states `destroyBlock` writes over it.
    ///
    /// Counted in `matched`, because a cart built for this anchor is seeded
    /// with those tiles -- see `blockSeeds` and `engine/main.asm`'s
    /// `SeedWorld`. Kept as its own number so a settle that leaned on the
    /// seeding can be told from one that did not, which is the only way to
    /// know whether the seeding is doing anything.
    blocks: usize = 0,

    pub fn same(self: World) bool {
        return self.compared > 0 and self.matched == self.compared;
    }
};

// ---- Which differences are damage, and which are the wrong room ------------
//
// **Mechanism, not a threshold.** `destroyBlock` (01:56E9) is the only thing
// that writes a block's four tiles, and it writes exactly four id runs: $00-$03
// when the block reforms, $04-$07 and $08-$0B over the two animation frames,
// and $FF over all four when it is gone. `01:$5155` treats ids $00-$03 as the
// hardcoded respawning blocks a projectile may break.
//
// So a compared slot whose map tile is $00-$03 and whose trace tile is $04-$0B
// or $FF is a block the reference broke, and any other disagreement is the two
// machines being in different rooms. That distinction needs no bound on how
// many tiles may differ, which is what makes it safe to settle on: a warp that
// redrew the wrong room disagrees on tiles that were never blocks.

/// The four ids an intact respawning block is drawn from. `01:$5155`'s own set.
pub fn intactBlock(tile: u8) bool {
    return tile <= 0x03;
}

/// The ids `destroyBlock` writes over one: $04-$07 and $08-$0B are the two
/// animation frames, $FF is gone.
pub fn brokenBlock(tile: u8) bool {
    return (tile >= 0x04 and tile <= 0x0B) or tile == 0xFF;
}

/// The tiles a cart booted at this anchor has to be given, because the map has
/// an intact block where the reference has a broken one.
///
/// The same predicate `compareCell` counts with, so the two cannot drift: a
/// slot the comparison forgave as damage is a slot this seeds, and no other.
/// Only slots inside the window mask, because that is the part of the buffer
/// the boot cell describes and so the only part either side can be checked on
/// -- damage in a neighbour that the streamer will draw is out of scope here,
/// and `SeedWindow` puts the intact block back there.
///
/// Returns how many were written. `Error.TooManyBlocks` when the anchor needs
/// more than `snes_inject.boot_world_max`, which is refused rather than
/// truncated: a cart seeded with some of the holes has a floor the reference
/// does not have, and would grade as a port bug.
pub fn blockSeeds(
    allocator: std.mem.Allocator,
    rom: []const u8,
    boot: snes_screen.Boot,
    gb_tiles: *const [1024]u8,
    scx: u8,
    scy: u8,
    samus_x: u16,
    samus_y: u16,
    out: []snes_screen.WorldSeed,
) !usize {
    const bank = room.map_bank_first + boot.map_index;
    var parsed = map_mod.parseBank(allocator, rom, bank) catch return 0;
    defer parsed.deinit(allocator);
    const body = map_mod.screenBody(rom, bank, parsed.cells[boot.cell].screen_ptr) orelse return 0;
    const cart = expandCell(rom, body, boot.tiletable) orelse return 0;

    const mask = windowMask(scx, scy, samus_x, samus_y, boot.cell);
    var n: usize = 0;
    for (0..1024) |i| {
        if (!mask[i]) continue;
        if (cart[i] == gb_tiles[i]) continue;
        if (!intactBlock(cart[i]) or !brokenBlock(gb_tiles[i])) continue;
        if (n >= out.len) return Error.TooManyBlocks;
        out[n] = .{ .index = @intCast(i), .tile = gb_tiles[i] };
        n += 1;
    }
    return n;
}

/// The screen the Game Boy is actually showing, in world pixels.
pub const view_w: u16 = 160;
pub const view_h: u16 = 144;

/// The map slots that are both on screen and inside the cart's boot cell.
///
/// Exact, and it needs no camera variable: the PPU shows map pixel
/// `(SCX + sx) mod 256`, and the map is world-aligned, so the world coordinate
/// of the view's left edge is the one congruent to SCX mod 256 that Samus's own
/// position sits within 160 pixels to the right of -- which is
/// `samus_x - ((samus_x - SCX) mod 256)`, because she is on screen. Walk the
/// view's tile columns from there and each one's world coordinate, and hence
/// which cell it belongs to, is known.
///
/// $FFCC-$FFCF look like the camera and are not: `$0700` and its siblings write
/// them from Samus's position with a different offset per scroll direction, so
/// they hold wherever the last edge redraw was aimed rather than where the view
/// is. Reading them as a camera put the whole comparison an entire screen row
/// out.
pub fn windowMask(scx: u8, scy: u8, samus_x: u16, samus_y: u16, cell: u8) [1024]bool {
    var mask: [1024]bool = @splat(false);
    const cell_col: u16 = cell & 0x0F;
    const cell_row: u16 = cell >> 4;

    var col_in: [32]bool = @splat(false);
    var row_in: [32]bool = @splat(false);

    const left = samus_x -% ((samus_x -% scx) & 0xFF);
    const top = samus_y -% ((samus_y -% scy) & 0xFF);

    // One past the view on each axis: a view whose edge falls mid-tile shows
    // part of one more tile than it is wide.
    var x: u16 = left & ~@as(u16, 7);
    while (x < left + view_w) : (x += 8) {
        if ((x >> 8) == cell_col) col_in[(x >> 3) & 31] = true;
    }
    var y: u16 = top & ~@as(u16, 7);
    while (y < top + view_h) : (y += 8) {
        if ((y >> 8) == cell_row) row_in[(y >> 3) & 31] = true;
    }

    for (0..32) |r| for (0..32) |c| {
        mask[r * 32 + c] = row_in[r] and col_in[c];
    };
    return mask;
}

/// Expand one cell's body through one metatile table, as Game Boy tile ids.
///
/// The Game Boy stores a metatile as four consecutive tile ids in TL TR BL BR
/// order, and `snes_screen.buildTilemap` is the same doubling over the
/// converted words; this is the Game Boy side of it, so the result can be
/// compared with a tilemap read straight out of either machine.
pub fn expandCell(rom: []const u8, body: []const u8, tt: u4) ?[1024]u8 {
    const table = screens.metatileTable(rom, tt) orelse return null;
    var out: [1024]u8 = @splat(0);
    for (0..map_mod.grid_h) |r| {
        for (0..map_mod.grid_w) |c| {
            const at = @as(usize, body[r * map_mod.grid_w + c]) * 4;
            if (at + 4 > table.len) return null;
            out[(r * 2) * 32 + c * 2] = table[at];
            out[(r * 2) * 32 + c * 2 + 1] = table[at + 1];
            out[(r * 2 + 1) * 32 + c * 2] = table[at + 2];
            out[(r * 2 + 1) * 32 + c * 2 + 1] = table[at + 3];
        }
    }
    return out;
}

/// Compare the room the reference walked through with the room the cart boots
/// into, and name the table that best explains each.
pub fn compareWorlds(
    allocator: std.mem.Allocator,
    rom: []const u8,
    boot: snes_screen.Boot,
    gb_tiles: *const [1024]u8,
    scx: u8,
    scy: u8,
    samus_x: u16,
    samus_y: u16,
) !World {
    return compareCell(
        allocator,
        rom,
        boot.map_index,
        boot.cell,
        boot.tiletable,
        gb_tiles,
        scx,
        scy,
        samus_x,
        samus_y,
    );
}

/// The same comparison against a cell and a table rather than a boot record.
///
/// Split out for `sweepWorlds`, which grades cells nothing boots into. A `Boot`
/// carries a door index, two palettes and a start position that this comparison
/// does not read, and synthesising one to ask about a cell would mean inventing
/// five fields to be ignored -- the kind of fake that later reads as data.
pub fn compareCell(
    allocator: std.mem.Allocator,
    rom: []const u8,
    map_index: u8,
    cell: u8,
    tiletable: u4,
    gb_tiles: *const [1024]u8,
    scx: u8,
    scy: u8,
    samus_x: u16,
    samus_y: u16,
) !World {
    var w: World = .{ .cart_table = tiletable };
    const bank = room.map_bank_first + map_index;
    var parsed = map_mod.parseBank(allocator, rom, bank) catch return w;
    defer parsed.deinit(allocator);
    const body = map_mod.screenBody(rom, bank, parsed.cells[cell].screen_ptr) orelse return w;

    const mask = windowMask(scx, scy, samus_x, samus_y, cell);
    for (mask) |m| w.compared += @intFromBool(m);

    if (expandCell(rom, body, tiletable)) |cart| {
        for (0..1024) |i| if (mask[i]) {
            if (cart[i] == gb_tiles[i]) {
                w.matched += 1;
            } else if (intactBlock(cart[i]) and brokenBlock(gb_tiles[i])) {
                // A block the reference shot out. Counted as matched because
                // the cart is *seeded* with this tile -- see `blockSeeds` --
                // and kept in `blocks` so a settle that leaned on the seeding
                // can be told from one that did not.
                w.matched += 1;
                w.blocks += 1;
            }
        };
    }
    for (0..screens.tiletable_order.len) |tt| {
        const cand = expandCell(rom, body, @intCast(tt)) orelse continue;
        var n: usize = 0;
        for (0..1024) |i| if (mask[i]) {
            n += @intFromBool(cand[i] == gb_tiles[i]);
        };
        if (n > w.gb_best_matched) {
            w.gb_best_matched = n;
            w.gb_best_table = @intCast(tt);
        }
    }
    return w;
}

/// The projectile slot bytes a take with `projs` compares: type, Y and X.
/// The direction is fixed at the shot, the wave index moves Y, and the frame
/// counter only ends a shot the draw's window would end first.
pub const proj_fields = [_]u8{ 0x00, 0x02, 0x03 };
pub const proj_slots: usize = 3;
pub const proj_bytes: usize = proj_fields.len * proj_slots;
const gb_projs: u16 = 0xDD00;
const gb_proj_size: u16 = 0x10;

/// What diverged first, for the exit-code protocol and for the message.
pub const What = enum { position, camera, pose, projectile, health, obp1 };

pub const Divergence = struct {
    frame: usize,
    what: What,

    /// A divergence as a report can state it: one frame when `Bisect` pinned
    /// it, the bucket the exit code named when it did not.
    ///
    /// Both cases in one type on purpose. Callers printed `d.frame` and
    /// `d.frame + per_code - 1` by hand at five sites, which is five places for
    /// an exact frame to be re-widened into a bucket by a caller that had not
    /// heard about the bisection.
    pub const Span = struct {
        first: usize,
        last: usize,
        what: What,

        pub fn exact(self: Span) bool {
            return self.first == self.last;
        }
    };
};

/// Compare two traces and name the first frame that differs.
///
/// **Both absolutely, since boot record version 4.** Each is an initial
/// condition both machines can now be handed: the position through `room.spawn`
/// on one side and `BootSamusX`/`BootSamusY` on the other, which is what Step 14
/// added it for, and the camera through `BootCamX`/`BootCamY`.
///
/// The camera used to be compared *relatively*, each side against its own frame
/// 0, and the reason was worth recording because it is the reason this changed.
/// The original's camera is placed by the door transition that brought Samus
/// into the room, and which of the handler's four camera arrangements ran is a
/// property of the door, not of the room. Our cart had no transition, so
/// `InitState` derived a camera from the start position, and the two disagreed
/// by sixteen pixels on the segment's own screen -- which the first run of this
/// comparator reported at frame 0, exactly as it should have. Comparing motion
/// was the honest way to grade a port that could not be told where its camera
/// began. It could also only ever be a weaker check: a camera sixteen pixels
/// out reaches the physics through `LatchCell`, so it clamps at a different
/// moment and streams a different column, and a comparison of deltas calls that
/// agreement right up until the divergence it caused surfaces somewhere else.
///
/// The builder measures the camera now and writes it into the record, so the
/// weaker check has no reason left. Grading it absolutely was worth 32 frames on
/// the segment the moment it landed.
pub fn firstDivergence(a: []const Frame, b: []const Frame) ?Divergence {
    const n = @min(a.len, b.len);
    if (n == 0) return null;
    for (0..n) |i| {
        if (a[i].samus_x != b[i].samus_x or a[i].samus_y != b[i].samus_y)
            return .{ .frame = i, .what = .position };
        if (a[i].camera_x != b[i].camera_x or a[i].camera_y != b[i].camera_y)
            return .{ .frame = i, .what = .camera };
        // Last, and that order is deliberate rather than incidental: a pose
        // that went wrong usually moves Samus too, and when it does the
        // position is the sharper thing to report. The pose is checked so the
        // case where it moves her *nowhere* is still caught -- which is the
        // morph bug exactly.
        if (a[i].pose != b[i].pose)
            return .{ .frame = i, .what = .pose };
    }
    return null;
}

/// `samusPose` on the Game Boy, the byte the pose machine dispatches on.
/// Named here rather than imported from `ledger.zig` so this file does not pull
/// the whole inventory in for one address; `correspond.pairs` pairs the two.
const gb_pose_addr: u16 = 0xD020;
/// `samusItems`, the byte `handleItemPickup`'s arms `SET` a bit in (00:$372F).
const gb_items_addr: u16 = 0xD045;
/// `samusBeam` and `samusActiveWeapon`, which the debug menu's beam row writes
/// together (`scenario.apply`).
const gb_beam_addr: u16 = 0xD055;
const gb_weapon_addr: u16 = 0xD04D;
/// `$C424`, the damage the last enemy hit wrote (`!DmgValue`).
const gb_dmg_value_addr: u16 = 0xC424;
/// `samusCurHealthLow` and `samusCurHealthHigh`, the pair `applyDamage`
/// subtracts from (00:$2F64).
const gb_health_lo_addr: u16 = 0xD051;
const gb_health_hi_addr: u16 = 0xD052;
/// `maxOamPrevFrame`, the buffer bytes the frame used, which
/// `clearUnusedOamSlots` (01:$4BB3) leaves behind it; the logic point is
/// after `waitOneFrame` zeroed `hOamBufferIndex`, so this is the count.
const gb_oam_max_addr: u16 = 0xD06E;
const gb_oam_buffer: u16 = 0xC000;

/// The objects of the last drawn frame on OBP1. See `Frame.obp1`.
fn gbObp1(m: *harness.Machine) u8 {
    var n: u8 = 0;
    var at: u16 = 0;
    const end = m.read(gb_oam_max_addr);
    while (at < end) : (at += 4) {
        if (m.read(gb_oam_buffer + at + 3) & 0x10 != 0) n += 1;
    }
    return n;
}

/// `samusFacingDirection`, the byte `drawSamus_spinJump` (01:4CEE) reads to
/// pick a facing's animation table. Recorded, never compared: see `Frame`.
const gb_facing_addr: u16 = 0xD02B;

/// The pad byte the pose machine tests, filled once a frame by the game's own
/// joypad read. `standingHandler` reaches it as `LDH A,($80) / BIT 4,A` for
/// right and `BIT 5,A` for left (00:$1421); $FF81 beside it is the
/// newly-pressed byte the jump check uses.
const gb_pad_addr: u16 = tas.pad_addr;

/// The frame counter `samus_walkRight` takes its 1/2 walk alternation from:
/// `LDH A,($97) / AND $01 / ADD A,$01` at 00:$1C25, so the speed on a frame is
/// `($FF97 & 1) + 1`. Our `WalkSpeed` derives the same number from
/// `!FrameCount`, which makes the two counters' *parity* part of the port even
/// though neither counter is.
const gb_counter_addr: u16 = 0xFF97;

/// `samusInWater` on the original: `collision_samusBottom` latches $31 or $FF
/// into it when a foot is on a water tile, `samus_handlePose` clears it every
/// frame, and `samus_walkRight` reads it at 00:$1C14.
const gb_water_addr: u16 = 0xD048;

/// `bg_palette`. $93 is the game's normal palette; `FADEOUT` (00:$2561) steps it
/// through $E7 and $FB to $FF, and `fadeIn` (01:$7A45) back.
const gb_bg_palette_addr: u16 = 0xD07E;

/// `samusEnergyTanks`. `save.fields` leaves the byte unnamed on purpose; the
/// Energy Tank pickup is what named it, through `gb_trace`'s `etanks` column.
const gb_tanks_addr: u16 = 0xD050;

pub fn saveAddr(comptime name: []const u8) u16 {
    for (save.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.src;
    }
    @compileError("no save-record field named " ++ name);
}

/// `samusActiveWeapon`. Not a save field: a load sets it from the beam.
const gb_active_weapon_addr: u16 = 0xD04D;
/// `songPlaying`. Not a save field: the engine's, which a handover carries.
const gb_song_playing_addr: u16 = 0xCEDD;
/// `currentRoomSong`, the save-file byte 00:$0EB3 reads to decide what the room
/// should be playing and 02:$4051 adds $11 to after a Metroid dies. Read
/// directly rather than through `saveAddr`: the save-slot table does not carry
/// it, and the live byte is what a handover needs.
const gb_room_song_addr: u16 = 0xD092;

/// The song worth handing over: one bank 4's `handleSong` would start
/// ($01-$20), else 0 for none -- $FF is "silenced", which the boot already is.
pub fn handoverSong(song: u8) u8 {
    return if (song >= 0x01 and song <= 0x20) song else 0;
}

/// Everything boot record versions 11 to 13 carry, read out of a running Game Boy.
pub fn gbLoadout(m: *harness.Machine) snes_screen.Loadout.Measured {
    const w = struct {
        fn word(mm: *harness.Machine, at: u16) u16 {
            return (@as(u16, mm.read(at + 1)) << 8) | mm.read(at);
        }
    };
    return .{
        .tanks = m.read(gb_tanks_addr),
        .health = w.word(m, comptime saveAddr("energy")),
        .max_missiles = w.word(m, comptime saveAddr("missile_capacity")),
        .missiles = w.word(m, comptime saveAddr("missiles")),
        .metroid_real = m.read(comptime saveAddr("metroid_count_real")),
        .metroid_displayed = m.read(comptime saveAddr("metroid_count_displayed")),
        .items = m.read(0xD045),
        .beam = m.read(0xD055),
        .active_weapon = m.read(gb_active_weapon_addr),
        .song = handoverSong(m.read(gb_song_playing_addr)),
        .room_song = m.read(gb_room_song_addr),
        .acid_damage = m.read(0xD077), // acidDamageValue
        .spike_damage = m.read(0xD078), // spikeDamageValue
    };
}

/// Where the door script's `collision` op leaves the block-type table the
/// physics indexes with a tile id. Every collision routine reaches it the same
/// way -- `LD H,$DC / LD L,A / LD A,(HL)` -- so the base is an immediate in the
/// code rather than a guess; see 00:$1F41 in `collision_samusBottom`.
const gb_coltab_base: u16 = 0xDC00;

/// Where in the game's own frame the reference is sampled.
///
/// `harness.Machine.runFrames` returns when the *LCD* completes a frame, which
/// is the end of VBlank -- and that instant has no fixed relationship to how
/// much of the game's per-frame work has run. Sampling there reads a machine
/// mid-tick, and the segment's first divergence is what that looks like: the
/// ROM sets pose $09 on a standing jump at 00:$14CB, and the reference's
/// per-frame record never contained a single $09 frame while the cart's always
/// did.
///
/// $052C is the `CALL hurtSamus` in the main loop, the first call of its Samus
/// block (the pose call's twin at 00:$059E belongs to the other loop). Stopping *on*
/// it means every subsystem of the previous tick has run and none of this one
/// has, which is a point the game defines rather than one the LCD does.
///
/// **It was $052F, the `CALL samus_handlePose` after it, until 1.0 Step 8d.**
/// That put `hurtSamus` on the wrong side of the sample, so a hurt read a
/// sample early: the flag consumed, the timer at $33 and the knockback pose,
/// where the cart, sampled at the top of `MainLoop` ahead of its own
/// `HurtSamus`, shows them on the next. Measured in 1.0 Step 8c with an Autoad
/// landing on a standing Samus; the first graded segment to be hurt, `ice
/// stand`'s thaw, diverged on it at frame 420. Only $0528-$052B's clearing of
/// `$D05C` now runs ahead of the sample, and nothing graded reads it.
const gb_logic_pc: u16 = 0x052C;
/// **And $0520 when a Metroid is appearing**, added in Step 13c. The cutscene
/// arm at 00:$050B takes the place of the whole Samus block, `hurtSamus` and
/// `samus_handlePose` with it, so a tick that stops only on $052C never arrives and runs to the
/// instruction cap instead -- sixteen frames at a time, measured on the hatching
/// Alpha. $0520 is that arm's `JR $053E`: the arm's own work is done and the
/// rest of the frame is not, which is the same point of the tick $052C is on the
/// other side of the branch. No published run and no segment ever takes it.
const gb_cutscene_pc: u16 = 0x0520;

/// Step to `gb_logic_pc`, so a record is taken at the same point of every tick.
///
/// Bounded, and a machine that never arrives is left where it was rather than
/// reported as an error: the caller is taking a measurement, and a measurement
/// that cannot be aligned is still the LCD-boundary measurement it used to be.
pub fn stepToLogicPoint(m: *harness.Machine) !void {
    var n: u64 = 0;
    while (n < harness.Machine.instructions_per_frame_cap) : (n += 1) {
        if (m.sys.cpu.pc == gb_logic_pc or m.sys.cpu.pc == gb_cutscene_pc) return;
        _ = try m.sys.step();
    }
}

/// Advance the reference by exactly one of the game's own ticks.
///
/// Counting *ticks* rather than LCD frames is the whole point. `runFrames(1)`
/// followed by an alignment step is not the same thing: it advances one LCD
/// frame from wherever it starts and then runs on to the next sample point, so
/// whenever a tick boundary falls just before an LCD boundary it swallows a
/// second tick -- measured, on the segment's walk, as the reference gaining a
/// third pixel every third frame while $FF97 skipped a value.
///
/// The input is set at the top of the tick, before the tick's own joypad read,
/// which is where `runScript` sets it too.
pub fn stepOneTick(m: *harness.Machine, b: probe.Buttons) !void {
    m.sys.bus.setKeys(b.dpad, b.buttons);
    _ = try m.sys.step();
    try stepToLogicPoint(m);
}

/// The pose both machines begin the segment in. See `reference` for why it is
/// not `fall`.
pub const start_pose: u8 = snes_screen.pose.stand;

const Reader = struct {
    m: *harness.Machine,
    fn read(ctx: *anyopaque, addr: u16) u8 {
        const self: *Reader = @ptrCast(@alignCast(ctx));
        return self.m.read(addr);
    }
};

fn pairNamed(comptime name: []const u8) correspond.Pair {
    return comptime blk: {
        for (correspond.pairs) |p| {
            if (std.mem.eql(u8, p.name, name)) break :blk p;
        }
        @compileError("no correspondence pair named " ++ name);
    };
}

/// Where both machines are placed at frame 0.
pub const Start = struct {
    /// The cart's own boot cell, so the segment runs on a screen the cart
    /// actually has converted.
    map_index: u8,
    cell: u8,
    pixel_x: u8,
    pixel_y: u8,
    /// The door script that loads this cell's room -- the same one the cart's
    /// boot record replays, so both machines are handed the same metatile
    /// table, the same collision and solidity tables and the same graphics.
    /// Without it a warp arrives in the room without loading it; see
    /// `room.door_interp`.
    door_index: ?u16 = null,

    pub fn spawn(self: Start) room.Spawn {
        return .{
            .map_bank = room.map_bank_first + self.map_index,
            .screen_row = @truncate(self.cell >> 4),
            .screen_col = @truncate(self.cell & 0x0F),
            .pixel_x = self.pixel_x,
            .pixel_y = self.pixel_y,
            .door_index = self.door_index,
        };
    }

    pub fn position(self: Start) snes_screen.Position {
        return snes_screen.samusAt(self.cell, self.pixel_x, self.pixel_y);
    }
};

/// The start both machines are placed at: the cart's own boot cell, at the
/// same pixel the engine's `InitState` puts her.
///
/// `snes_screen.samusStart` is where the centre-of-the-cell arithmetic lives,
/// so this cannot drift from what the injector seeds into the boot record.
pub fn startFor(boot: snes_screen.Boot) Start {
    return .{
        .map_index = boot.map_index,
        .cell = boot.cell,
        .pixel_x = @truncate(boot.samus_x),
        .pixel_y = @truncate(boot.samus_y),
        .door_index = boot.door_index,
    };
}

/// The pixels `chooseStart` tries within the boot cell.
///
/// A coarse grid rather than every pixel: the question is which corner of the
/// screen has room, and a screen is 256 pixels of terrain built out of 16-pixel
/// metatiles, so finer would cost time and answer the same.
const candidate_pixels = [_]u8{ 0x30, 0x60, 0x90, 0xC0 };

/// Where in the boot cell to start, chosen by trying and measuring.
///
/// **The middle of the cell is a bad place to stand.** `snes_screen.samusStart`
/// puts her there because it is the arithmetic the engine used before boot
/// record version 3 and it has to keep working; on this ROM's boot cell that is
/// against a wall with a ceiling overhead, and the segment measured 82 frames
/// of movement in 320, none of it vertical. A comparator whose reference barely
/// moves is one a broken port passes.
///
/// So the start is measured. Each candidate is spawned into and given a short
/// probe -- fall, then walk -- and scored by how much ground it covers, with
/// vertical movement weighted heavily because gravity and the collision data
/// are the parts of the port most worth grading. The choice is deterministic:
/// same ROM, same grid, same winner.
pub const Chosen = struct { start: Start, boot: snes_screen.Boot, score: usize };

/// **1.0 Step 11: a segment in a room of its own choosing** rather than the
/// one `chooseStart` picks. Samus spawns at the cell's centre moved by `dx`,
/// `dy`, and settles from there, as an `enemy AIs` case's does.
pub const Room = struct { bank: u8, cell: u8, dx: i16 = 0, dy: i16 = 0 };

pub fn roomStart(allocator: std.mem.Allocator, rom: []const u8, r: Room) Error!Chosen {
    const found = (snes_screen.bootFor(allocator, rom, r.bank - 9, r.cell) catch return Error.NoStart) orelse return Error.NoStart;
    var st = startFor(found.boot);
    st.pixel_x = @truncate(@as(u16, @bitCast(@as(i16, st.pixel_x) + r.dx)));
    st.pixel_y = @truncate(@as(u16, @bitCast(@as(i16, st.pixel_y) + r.dy)));
    return .{ .start = st, .boot = found.boot, .score = 0 };
}

pub fn chooseStart(allocator: std.mem.Allocator, rom: []const u8, cells: []const snes_screen.Boot) Error!Chosen {
    var m = try room.bootIntoPlay(allocator, rom);
    defer m.deinit();
    var snap = try m.snapshot();
    defer snap.deinit(allocator);

    var best: Start = startFor(cells[0]);
    var best_boot = cells[0];
    var best_score: usize = 0;

    for (cells) |b| {
        for (candidate_pixels) |px| {
            for (candidate_pixels) |py| {
                const cand: Start = .{
                    .map_index = b.map_index,
                    .cell = b.cell,
                    .pixel_x = px,
                    .pixel_y = py,
                    .door_index = b.door_index,
                };
                m.restore(snap);
                var sp = cand.spawn();
                sp.writes = &.{.{ .addr = gb_pose_addr, .value = snes_screen.pose.fall }};
                _ = room.spawn(&m, sp) catch continue;

                var xs: usize = 0;
                var ys: usize = 0;
                var last_x: u16 = 0;
                var last_y: u16 = 0;
                var first = true;
                // **And she has to stay in the cell.** The cart's world is one
                // converted screen; the original's is a map with neighbours on
                // every side. A start that drifts over the boundary -- ejected
                // out of a wall the spawn dropped her into, or simply walked
                // out -- leaves the reference standing in a room the cart does
                // not have, and `grade` would then build the cart for the cell
                // she ended in while the reference's picture is the cell she
                // started in. That was invisible until `room.spawn` learned to
                // load the room, because before it the picture was nobody's
                // room in particular.
                var left_cell = false;
                // Fall, then walk each way: enough to tell a ledge from a
                // pocket, and short enough to try sixteen of them per cell.
                for ([_]struct { n: usize, k: Key }{
                    .{ .n = 40, .k = key.none },
                    .{ .n = 40, .k = key.right },
                    .{ .n = 40, .k = key.left },
                }) |phase| {
                    for (0..phase.n) |_| {
                        _ = try m.runFrames(1, gbKeys(phase.k));
                        const x = (@as(u16, m.read(room.screen_col_addr)) << 8) | m.read(room.pixel_x_addr);
                        const y = (@as(u16, m.read(room.screen_row_addr)) << 8) | m.read(room.pixel_y_addr);
                        if (!first) {
                            xs += @intFromBool(x != last_x);
                            ys += @intFromBool(y != last_y);
                        }
                        const here: u8 = @as(u8, @truncate(y >> 8)) *% 16 +% @as(u8, @truncate(x >> 8));
                        left_cell = left_cell or here != cand.cell;
                        last_x = x;
                        last_y = y;
                        first = false;
                    }
                }
                // Vertical movement is worth more: it is gravity, the fall arc
                // and the collision data, which is most of what Phase 0a ported.
                const score = if (left_cell) 0 else xs + 4 * ys;
                if (score > best_score) {
                    best_score = score;
                    best = cand;
                    best_boot = b;
                }
            }
        }
        // Enough movement on both axes to grade a port. Stopping here keeps the
        // search from walking the whole map for a marginal improvement.
        if (best_score >= 120) break;
    }
    // Every candidate either stood still or wandered out of its cell. Returning
    // the first one anyway would hand `grade` a reference walking through a
    // room the cart does not have, which is the failure this whole check exists
    // to make impossible -- so it is an error rather than a default.
    if (best_score == 0) return Error.NoStart;
    return .{ .start = best, .boot = best_boot, .score = best_score };
}

/// How long the Game Boy is given to come to rest after a spawn, and how many
/// frames of stillness count as rest.
///
/// **The segment cannot start at the spawn.** A `WARP` drops Samus in and the
/// original then spends twenty-odd frames doing two things our cart has no
/// equivalent of: falling to the ground from wherever the harness put her, and
/// snapping the camera from the transition's arrangement onto its guide -- two
/// hundred pixels of it, on the segment's own screen. Our engine boots with the
/// camera already on the guide and Samus already standing, so comparing those
/// frames grades a transition against the absence of one.
///
/// So the spawn is followed by stillness until she stops moving, and *that*
/// position, at rest, is what the cart's boot record is set to and what the
/// segment's frame 0 is. Both machines then begin standing still in the same
/// place with a settled camera, and everything after is the port.
pub const settle_limit: usize = 240;
pub const settle_still: usize = 12;

/// What `reference` settled to, which is what the cart must be built to boot at.
pub const Settled = struct {
    placement: room.Placement,
    frames: []Frame,
    /// The Game Boy's background tilemap at the segment's frame 0, and the
    /// scroll registers that were showing it.
    ///
    /// Collision on the original is a lookup into the picture -- `samus_getTileIndex`
    /// goes through `getTilemapAddress`, 00:1FF5 and 00:22BC -- so this is not a
    /// rendering detail, it is the world the reference was walking through. Our
    /// engine's equivalent is `!TilemapBuf`, and `snes_trace.zig` reads that one
    /// back out of the cart, which makes the two directly comparable.
    tiles: [1024]u8 = @splat(0),
    /// The same map read *before* the spawn, so "the warp never redrew the
    /// room" can be told from "the warp redrew the wrong room".
    tiles_before: [1024]u8 = @splat(0),
    scx: u8 = 0,
    scy: u8 = 0,
    /// $FFCC-$FFCF at the same instant. Recorded because they are what the
    /// drawing code reads, and *not* used as a camera -- see `windowMask`.
    camera_x: u16 = 0,
    camera_y: u16 = 0,
    /// The two halves of "is this tile solid", read out of the machine that was
    /// actually walking on it.
    ///
    /// A tile id reaches the physics through exactly two lookups on the Game
    /// Boy, and both are in RAM because a door script selects them per room:
    /// `$D056` is the threshold every `CP (HL)` in the collision routines
    /// compares against, and `$DC00` is the 256-byte block-type table those
    /// routines index with the tile id (`LD H,$DC / LD L,A / LD A,(HL)`, at
    /// 00:$1F41 and its five siblings). Our engine has both as `!Solid` and
    /// `!ColTab`, loaded by the same door script's `solidity` and `collision`
    /// ops -- so these are the reference side of a comparison that had never
    /// been made, and the world agreeing tile-for-tile does not imply it.
    solid: u8 = 0,
    coltab: [256]u8 = @splat(0),
    /// The same table before the spawn ran. See `reference`.
    coltab_before: [256]u8 = @splat(0),
    /// What she was carrying at the handover, as far as the reference can say.
    /// A machine this repository runs says all of it; the recorded trace says
    /// three fields. See `snes_screen.Loadout.Measured`.
    loadout: snes_screen.Loadout.Measured = .{},
    /// The enemy slot seeded before frame 1 (1.0 Step 8c), placed. See `Enemy`.
    seed: ?enemy_oracle.Seed = null,

    pub fn cell(self: Settled) u8 {
        return (self.placement.screen_row << 4) | (self.placement.screen_col & 0x0F);
    }

    pub fn position(self: Settled) snes_screen.Position {
        return .{ .x = self.placement.worldX(), .y = self.placement.worldY() };
    }
};

/// Run the segment on the Game Boy and record what the original does.
///
/// `room.bootIntoPlay` rather than `harness.boot`, and that is not a detail:
/// the ordinary boot schedule leaves Metroid II *paused*, so the first version
/// of this function produced three hundred and twenty identical frames and a
/// reference that any port would match by doing nothing.
///
/// The spawn also forces the pose, and to `stand` rather than to the cart's own
/// default of `fall`. Two machines that start in different poses would diverge
/// on frame one for a reason that has nothing to do with the port -- and so
/// would two that start in the *same* pose if that pose is `fall`: the original
/// resolves it to standing on the very next frame when there is ground under
/// her, and our engine spends a frame falling first. That is a difference in
/// initial conditions rather than in physics, and grading it would tell us
/// nothing. `oracle_main` sets the cart's boot record to the same pose, so both
/// machines begin standing still and the segment's own inputs are what move
/// them.
pub fn reference(allocator: std.mem.Allocator, rom: []const u8, start: Start) Error!Settled {
    var keys: [segment_frames]Key = undefined;
    for (&keys, 0..) |*k, f| k.* = keyAt(f);
    return referenceWith(allocator, rom, start, &keys, .{}, 0);
}

/// `reference` over any key schedule, with `items` OR'd into `samusItems` once
/// she has settled and before the first graded frame -- the one lever the
/// spider segment needs that the segment does not. The cart gets the same bits
/// at the same point through `Take.pokes`.
///
/// **Or after it, with `frozen` non-zero**: the cart's items then come through
/// the debug menu (`Take.setup`), which is up for `frozen` frames after graded
/// frame 0 with the game stopped behind it and NMI still counting. What that
/// leaves on the Game Boy is its counter $FF97 moved on `frozen` and the bits
/// set, and that is what is written here, after frame 0. Nothing else the
/// vblank does on a frozen frame is state the game reads: the divider is only
/// the HUD's shuffle and the sound's, and the countdown is spent in play.
///
/// 1.0 Step 8c adds `lo.beam`, written beside the items, and `lo.enemy`,
/// seeded before frame 1 whether or not the menu froze anything: the seed's
/// 32 bytes go back in `Settled.seed` for the cart to be given the same.
pub fn referenceWith(allocator: std.mem.Allocator, rom: []const u8, start: Start, keys: []const Key, lo: Loadout, frozen: usize) Error!Settled {
    const items = lo.items;
    var seed: ?enemy_oracle.Seed = null;
    if (lo.enemy) |e| seed = enemy_oracle.seedFor(allocator, rom, e.bank, e.cell, e.ai) catch return Error.NoEnemySeed;
    var m = try room.bootIntoPlay(allocator, rom);
    defer m.deinit();

    var tiles_before: [1024]u8 = @splat(0);
    {
        const base: u16 = if (m.read(0xFF40) & 0x08 != 0) 0x9C00 else 0x9800;
        for (0..tiles_before.len) |i| tiles_before[i] = m.read(base + @as(u16, @intCast(i)));
    }
    // The block-type table as the boot left it, read before the spawn touches
    // anything. A `WARP` is not a room load, so if this survives the spawn
    // unchanged then the reference is grading the segment's terrain through
    // whichever room `bootIntoPlay` happened to stop in.
    var coltab_before: [256]u8 = @splat(0);
    for (0..coltab_before.len) |i| coltab_before[i] = m.read(gb_coltab_base + @as(u16, @intCast(i)));

    var sp = start.spawn();
    sp.writes = &.{.{ .addr = gb_pose_addr, .value = start_pose }};
    _ = try room.spawn(&m, sp);

    // Stillness first. See `settle_limit`.
    var still: usize = 0;
    var prev = room.placement(&m);
    var waited: usize = 0;
    while (waited < settle_limit and still < settle_still) : (waited += 1) {
        _ = try m.runFrames(1, gbKeys(key.none));
        const now = room.placement(&m);
        still = if (now.eql(prev)) still + 1 else 0;
        prev = now;
    }
    if (still < settle_still) return Error.NeverSettled;
    const settled = room.placement(&m);

    // The picture she came to rest in, read before the segment moves her.
    var tiles: [1024]u8 = @splat(0);
    const bg_base: u16 = if (m.read(0xFF40) & 0x08 != 0) 0x9C00 else 0x9800;
    for (0..tiles.len) |i| tiles[i] = m.read(bg_base + @as(u16, @intCast(i)));
    const scx = m.read(0xFF43);
    const scy = m.read(0xFF42);
    const cam_x = (@as(u16, m.read(room.camera_screen_x_addr)) << 8) | m.read(room.camera_pixel_x_addr);
    const cam_y = (@as(u16, m.read(room.camera_screen_y_addr)) << 8) | m.read(room.camera_pixel_y_addr);
    const solid = m.read(routines.solidity_addr);
    var coltab: [256]u8 = @splat(0);
    for (0..coltab.len) |i| coltab[i] = m.read(gb_coltab_base + @as(u16, @intCast(i)));

    if (items != 0 and frozen == 0) m.write(gb_items_addr, m.read(gb_items_addr) | items);

    var r: Reader = .{ .m = &m };
    const out = try allocator.alloc(Frame, keys.len);
    errdefer allocator.free(out);

    const px = pairNamed("samus_x");
    const py = pairNamed("samus_y");
    const cx = pairNamed("camera_x");
    const cy = pairNamed("camera_y");

    // 1.0 Step 8d: `$C424`, the last enemy damage, back to the zero a new
    // game has after our Game Boy's boot. The spawn lands her in whatever the previous room's slots held,
    // and a hit there reads 00:$3655's damage table out of whichever bank is
    // mapped ($A7 from bank 4, measured); the cart's `!DmgValue` starts at the
    // zero `Reset` leaves. It decides whether a frozen enemy lifts her
    // (00:$34D0), which the `ice stand` segment grades.
    m.write(gb_dmg_value_addr, 0);
    try stepToLogicPoint(&m);
    for (keys, 0..) |k, f| {
        if (f == 1 and frozen != 0) {
            m.write(gb_counter_addr, m.read(gb_counter_addr) +% @as(u8, @truncate(frozen)));
            m.write(gb_items_addr, m.read(gb_items_addr) | items);
            if (lo.beam) |b| {
                m.write(gb_beam_addr, b);
                m.write(gb_weapon_addr, b);
            }
        }
        if (f == 1) if (seed) |*sd| {
            // In the enemy's camera space: the slot's Y and X are what
            // `loadOneEnemy` writes, `record + OAM offset - scroll`, and
            // Samus's pixel less the same scroll is where she is in it.
            const e = lo.enemy.?;
            sd.bytes[0x01] = @truncate(@as(u16, @bitCast(@as(i16, m.read(room.samus_pixel_y_addr) -% m.read(enemy_oracle.gb_scroll_y)) + e.dy)));
            sd.bytes[0x02] = @truncate(@as(u16, @bitCast(@as(i16, m.read(room.samus_pixel_x_addr) -% m.read(enemy_oracle.gb_scroll_x)) + e.dx)));
            enemy_oracle.seedGb(&m, sd.*);
        };
        try stepOneTick(&m, gbKeys(k));
        var projs: [proj_bytes]u8 = undefined;
        for (0..proj_slots) |slot| {
            for (proj_fields, 0..) |fld, j| projs[slot * proj_fields.len + j] = m.read(gb_projs + @as(u16, @intCast(slot)) * gb_proj_size + fld);
        }
        out[f] = .{
            .samus_x = correspond.readGb(px, Reader.read, &r),
            .samus_y = correspond.readGb(py, Reader.read, &r),
            .camera_x = correspond.readGb(cx, Reader.read, &r),
            .camera_y = correspond.readGb(cy, Reader.read, &r),
            .pose = m.read(gb_pose_addr),
            .facing = m.read(gb_facing_addr),
            .pad = m.read(gb_pad_addr),
            .counter = m.read(gb_counter_addr),
            .water = m.read(gb_water_addr),
            .bg_palette = m.read(gb_bg_palette_addr),
            .projs = projs,
            .enemy0 = .{ m.read(0xC600), m.read(0xC601), m.read(0xC602), m.read(0xC60C) },
            .health = (@as(u16, m.read(gb_health_hi_addr)) << 8) | m.read(gb_health_lo_addr),
            .obp1 = gbObp1(&m),
        };
    }
    return .{
        .placement = settled,
        .frames = out,
        .seed = seed,
        .tiles = tiles,
        .tiles_before = tiles_before,
        .scx = scx,
        .scy = scy,
        .camera_x = cam_x,
        .camera_y = cam_y,
        .solid = solid,
        .coltab = coltab,
        .coltab_before = coltab_before,
    };
}

// ---- The reference, taken from a published run ------------------------------

/// The movie-driven reference, and what it cost to take.
///
/// Step 15b's premise: the segment starts on a screen `chooseStart` picked, and
/// the whole synthetic-spawn apparatus exists only to get the Game Boy onto it.
/// A published run starts where the *game* starts, so neither machine's frame 0
/// is anyone's choice, and the boot record can be seeded from the game's own
/// answer instead.
pub const MovieRef = struct {
    settled: Settled,
    keys: []Key,
    /// The movie's own frame index for this reference's frame 0. See
    /// `referenceFromMovie` for why it is `control + 1` and not `control`.
    origin: u32,
    /// `tas.Opening.control`, the frame the game handed over control.
    control: u32,
    /// `$D811` at the reference's frame 0. **Not** `Placement.map_bank`, which
    /// is `$D04E` -- a shadow of whatever bank happens to be mapped. See
    /// `room.map_bank_addr`.
    map_bank: u8,
    /// The movie's raw held byte per reference frame, kept so a divergence can
    /// be read against what was actually pressed rather than against the
    /// three-key approximation of it.
    held: []u8,
    /// The first reference frame carrying an input the port has no key for,
    /// and the bits it carried. This is a ceiling on how far a comparison can
    /// mean anything, and it is a different number from the first divergence:
    /// one says the port is wrong, the other says the port was never asked.
    first_unsupported: ?usize,
    unsupported_bits: u8,

    /// The reference and the inputs to drive the cart with, phase-aligned.
    ///
    /// **The cart is handed frame i+1's byte at frame i, and that is not an
    /// off-by-one.** The two machines learn an input at different points in
    /// their frame. `ReadPad` maintains `!PadHeld` from the controller and
    /// `PublishPad`, called from NMI *before* the poll, hands it to
    /// `!InputPressed` -- so a byte the script sets before frame i runs is what
    /// the engine's pose machine acts on during frame i+1. The reference's
    /// `held[i]` is the opposite: it is $FF80 sampled at the commit point of
    /// frame i, which is the byte the game *did* act on that frame.
    ///
    /// Handing the cart `held[i]` at frame i therefore makes it act a frame
    /// late on every input in the movie. The segment never showed this because
    /// both machines there are driven by the same supplied schedule and the two
    /// delays cancel; the movie's reference is observed rather than supplied,
    /// so nothing cancels. It stayed invisible until the crouch landed, because
    /// until then the comparison stopped at frame 1 on an input the port had no
    /// key for and never reached a frame where the lag could show.
    ///
    /// Measured: aligning it took the reachable-frame count from 1 to 4, which
    /// is the first frame of the morph ball -- the next pose the run asks for.
    ///
    /// The last reference frame is dropped, because there is no frame after it
    /// to take a byte from.
    pub fn take(self: MovieRef) Take {
        const n = self.settled.frames.len - movie_key_lead;
        return Take.of(self.settled.frames[0..n], self.keys[movie_key_lead..][0..n]);
    }

    pub fn deinit(self: *MovieRef, allocator: std.mem.Allocator) void {
        allocator.free(self.settled.frames);
        self.deinitKeepingFrames(allocator);
    }

    /// Free everything *except* the reference frames, which the caller keeps.
    ///
    /// `gradeMovie` returns a `Report` whose `settled` aliases `frames`, so a
    /// blanket `deinit` leaves the report pointing at freed memory. `grade`, the
    /// segment's equivalent, has always transferred that slice to its report and
    /// never freed it; this makes the movie path do the same thing explicitly
    /// rather than by omission.
    ///
    /// The bug this fixes was latent from the day `gradeMovie` was written:
    /// nothing read `Report.settled` on the movie path until `verify`'s
    /// reachable rung printed the reference's own frame, and then it printed
    /// `AAAA,AAAA pose $AA` -- Zig's safety fill, which is what a use-after-free
    /// looks like when the allocator poisons on free.
    pub fn deinitKeepingFrames(self: *MovieRef, allocator: std.mem.Allocator) void {
        allocator.free(self.keys);
        allocator.free(self.held);
        self.keys = &.{};
        self.held = &.{};
    }
};

/// Where the reference's frame 0 sits relative to the frame control is handed
/// over, and why it is one frame later.
///
/// At `tas.Opening.control` the game has just left pose $13, and under the
/// frame boundary measured on 2026-08-31 it is *already* standing still at the
/// landing site on that frame: the pose reads `stand` and `first_move` is
/// further on, so nothing has moved yet. The boot record taken from the end of
/// that frame gives both machines the same thing `reference()` gives them --
/// standing, at rest, at the same pixel -- and the first compared frame is one
/// whose input acts on a standing Samus on both sides.
///
/// **This was 1 until that measurement.** Sampling at the LY wrap put the
/// $13-to-standing transition on the far side of the boundary, so `control`
/// showed a pose the port has no entry for and the anchor had to be pushed a
/// frame later to find a standing Samus. Anchoring at `control` itself would
/// have compared a transition the cart has no $13 to make. The boundary moved
/// five scanlines and the transition moved with it; the delay is now zero
/// because there is nothing left to skip.
pub const movie_origin_delay: u32 = 0;

/// The cell the game starts a new file on, measured by `referenceFromMovie` and
/// written down here so a test can assert against it without replaying a movie.
/// Map bank $F, grid cell $76 -- row 7, column 6.
pub const landing_map_bank: u8 = 0xF;
pub const landing_cell: u8 = 0x76;

/// One anchor's slot in a multi-anchor capture: where its frame 0 is in the
/// movie, and how many frames of reference to take from there.
const CaptureSlot = struct {
    origin: u32,
    want: usize,
    frames: []Frame,
    keys: []Key,
    held: []u8,
    n: usize = 0,
    settled: Settled = .{ .placement = undefined, .frames = &.{} },
    map_bank: u8 = 0,
    have_settled: bool = false,
};

/// Capture one or more references out of a **single** replay.
///
/// The single-anchor case is `referenceFromMovie` and reads exactly as it did.
/// The multi-anchor case exists because the alternative is quadratic: grading
/// fourteen stretches by calling `referenceFromMovie` fourteen times replays
/// the movie from a cold machine each time, and the origins run to frame 8408,
/// so it is fifty-odd thousand frames of Game Boy to record eight thousand.
/// One pass with a watcher that knows every slot records the same thing and
/// visits each frame once.
///
/// It is also the only way the slots are *guaranteed* to come from the same
/// replay. Fourteen independent runs are fourteen chances for one of them to
/// have taken a different route, and nothing downstream would be able to tell.
const MovieCapture = struct {
    allocator: std.mem.Allocator,
    movie: tas.Movie,
    slots: []CaptureSlot,

    fn onFrame(ctx: *anyopaque, m: *harness.Machine, frame: usize) anyerror!void {
        const self: *MovieCapture = @ptrCast(@alignCast(ctx));
        for (self.slots) |*slot| {
            if (frame + 1 == slot.origin) {
                snapshot(&slot.settled, &slot.map_bank, m);
                slot.have_settled = true;
                continue;
            }
            if (frame < slot.origin or slot.n >= slot.want) continue;

            var r: Reader = .{ .m = m };
            slot.frames[slot.n] = .{
                .samus_x = correspond.readGb(pairNamed("samus_x"), Reader.read, &r),
                .samus_y = correspond.readGb(pairNamed("samus_y"), Reader.read, &r),
                .camera_x = correspond.readGb(pairNamed("camera_x"), Reader.read, &r),
                .camera_y = correspond.readGb(pairNamed("camera_y"), Reader.read, &r),
                .pose = m.read(gb_pose_addr),
                .facing = m.read(gb_facing_addr),
                .pad = m.read(gb_pad_addr),
                .counter = m.read(gb_counter_addr),
                .water = m.read(gb_water_addr),
                .bg_palette = m.read(gb_bg_palette_addr),
            };
            const held = self.movie.input(frame).held();
            slot.held[slot.n] = held;
            slot.keys[slot.n] = movieKey(held);
            slot.n += 1;
        }
    }

    /// Everything the cart has to be built to boot at, read out of the machine
    /// on the frame before the reference's frame 0.
    fn snapshot(settled: *Settled, map_bank: *u8, m: *harness.Machine) void {
        settled.placement = room.placement(m);
        const bg_base: u16 = if (m.read(0xFF40) & 0x08 != 0) 0x9C00 else 0x9800;
        for (0..settled.tiles.len) |i| {
            settled.tiles[i] = m.read(bg_base + @as(u16, @intCast(i)));
            settled.tiles_before[i] = settled.tiles[i];
        }
        settled.scx = m.read(0xFF43);
        settled.scy = m.read(0xFF42);
        settled.camera_x = (@as(u16, m.read(room.camera_screen_x_addr)) << 8) | m.read(room.camera_pixel_x_addr);
        settled.camera_y = (@as(u16, m.read(room.camera_screen_y_addr)) << 8) | m.read(room.camera_pixel_y_addr);
        settled.solid = m.read(routines.solidity_addr);
        for (0..settled.coltab.len) |i| {
            settled.coltab[i] = m.read(gb_coltab_base + @as(u16, @intCast(i)));
            settled.coltab_before[i] = settled.coltab[i];
        }
        map_bank.* = m.read(room.map_bank_addr);
        settled.loadout = gbLoadout(m);
    }
};

/// Turn a filled slot into the `MovieRef` the graders take.
fn refFromSlot(slot: CaptureSlot, control: u32) !MovieRef {
    if (!slot.have_settled or slot.n == 0) return Error.NeverSettled;

    var first_unsupported: ?usize = null;
    var bits: u8 = 0;
    for (slot.held[0..slot.n], 0..) |h, i| {
        const u = unsupportedBits(h);
        if (u != 0 and first_unsupported == null) {
            first_unsupported = i;
            bits = u;
        }
    }

    var settled = slot.settled;
    settled.frames = slot.frames[0..slot.n];
    return .{
        .settled = settled,
        .keys = slot.keys[0..slot.n],
        .held = slot.held[0..slot.n],
        .origin = slot.origin,
        .control = control,
        .map_bank = slot.map_bank,
        .first_unsupported = first_unsupported,
        .unsupported_bits = bits,
    };
}

/// Run a published movie on the Game Boy from a cold machine and record what
/// the original does, starting from the frame the game hands over control.
///
/// Nothing is poked. `room.spawn` is not called, no pose is forced, and no cell
/// is chosen: the game boots itself, places Samus itself, and plays its own
/// opening, and the reference begins where that ends. That is the whole point
/// of C -- the two machines start from a state neither of us invented.
///
/// `want` frames of reference are recorded, or fewer if the movie is shorter.
pub fn referenceFromMovie(
    allocator: std.mem.Allocator,
    rom: []const u8,
    movie: tas.Movie,
    want: usize,
) !MovieRef {
    // Where control is handed over, measured rather than assumed. A short probe
    // is enough: `tas.opening_hold_frames` is 318 and this is well past it.
    var probe_run = try tas.run(allocator, rom, movie, .{
        .max_frames = 400,
        .stride = 1,
        .watch_save = false,
        .profile_record = false,
    });
    defer probe_run.deinit(allocator);
    const opening = try tas.findOpening(probe_run.track());
    // The same rule the re-anchored sweep uses, rather than a constant delay:
    // an anchor has to sit where the room and the pose are both stable across
    // its own frame 0. See `pushToStableAnchor`. `movie_origin_delay` is what
    // this used to be, and it is now the *floor* of the search rather than the
    // answer.
    const probe_track = probe_run.track();
    const origin = pushToStableAnchor(
        probe_track,
        opening.control + movie_origin_delay,
        probe_track.end(),
    ) orelse return Error.NeverSettled;

    const refs = try referencesFromMovie(allocator, rom, movie, &.{.{
        .origin = origin,
        .frames = want,
        // The refusal's own handover, which is what `MovieRef.control` is
        // documented to carry. Writing `origin` here made the two equal and the
        // push invisible to every caller that reads `control`.
        .handover = opening.control,
    }});
    defer allocator.free(refs);
    // `referencesFromMovie` reports a slot it could not fill as null rather
    // than failing the whole pass, because one bad anchor out of fourteen
    // should not lose the other thirteen. There is only one here, so a null is
    // the same failure the single-anchor path has always raised.
    return refs[0] orelse Error.NeverSettled;
}

/// A stretch of movie to grade: where its frame 0 is, and how far it runs.
pub const Anchor = struct {
    /// The movie frame this stretch's reference frame 0 comes from -- the
    /// handover of a refusal, pushed past any room change that straddles it.
    /// See `anchorsFrom`.
    origin: u32,
    /// Frames of reference to take, which is as far as the next anchor.
    frames: usize,
    /// The refusal's own handover, before any push. Equal to `origin` when
    /// nothing straddled it.
    handover: u32,
    /// Set once `settleAnchors` has found a frame the cart can honestly be
    /// built at. Null means it did not, inside `settle_search`, and the stretch
    /// is reported rather than graded.
    settled: bool = true,

    /// How many frames the room change across the handover took, or zero when
    /// there was none.
    ///
    /// This is the first duration a stretch of this run measures on the Game
    /// Boy side, and it is measured whether or not the port has anything to
    /// compare against.
    pub fn transition(self: Anchor) u32 {
        return self.origin - self.handover;
    }
};

/// Take one reference per anchor, out of a single replay.
///
/// A slot that never settled comes back null instead of failing the pass. One
/// anchor landing somewhere the capture cannot describe is a fact about that
/// stretch; losing the other thirteen to it would be a fact about this
/// function.
///
/// Anchors must be in increasing order of `origin`, which is how `anchorsFrom`
/// produces them; the replay runs to the last one's end.
pub fn referencesFromMovie(
    allocator: std.mem.Allocator,
    rom: []const u8,
    movie: tas.Movie,
    anchors: []const Anchor,
) ![]?MovieRef {
    std.debug.assert(anchors.len != 0);

    var slots = try allocator.alloc(CaptureSlot, anchors.len);
    defer allocator.free(slots);
    var built: usize = 0;
    errdefer for (slots[0..built]) |slot| {
        allocator.free(slot.frames);
        allocator.free(slot.keys);
        allocator.free(slot.held);
    };
    var last_frame: usize = 0;
    for (anchors, 0..) |anchor, i| {
        slots[i] = .{
            .origin = anchor.origin,
            .want = anchor.frames,
            .frames = try allocator.alloc(Frame, anchor.frames),
            .keys = try allocator.alloc(Key, anchor.frames),
            .held = try allocator.alloc(u8, anchor.frames),
        };
        built = i + 1;
        last_frame = @max(last_frame, anchor.origin + anchor.frames);
    }

    var cap: MovieCapture = .{ .allocator = allocator, .movie = movie, .slots = slots };
    var r = try tas.run(allocator, rom, movie, .{
        .max_frames = last_frame,
        .stride = 1,
        .watch_save = false,
        .profile_record = false,
        .watcher = .{ .ctx = &cap, .onFrame = MovieCapture.onFrame },
    });
    r.deinit(allocator);

    var out = try allocator.alloc(?MovieRef, anchors.len);
    errdefer allocator.free(out);
    for (slots, 0..) |slot, i| {
        // `control` is the first anchor's *handover*, which is the opening's
        // -- `tas.zig` asserts those are the same stretch. Carried on every ref
        // so a report can say how far into the run a stretch sits, and taken
        // from `handover` rather than `origin` so the push stays visible.
        out[i] = refFromSlot(slot, anchors[0].handover) catch |err| switch (err) {
            Error.NeverSettled => blk: {
                allocator.free(slot.frames);
                allocator.free(slot.keys);
                allocator.free(slot.held);
                break :blk null;
            },
            else => return err,
        };
    }
    return out;
}

// ---- Where a stretch's reference comes from ---------------------------------
//
// There are two producers of a `MovieRef` and the sweep must not care which it
// has. `referencesFromMovie` replays the movie on our own Game Boy, which is
// the only thing that works for a published `.vbm` and the only thing that does
// *not* work for James's recording -- converted to a VBM it stops being his run
// at 28 796 of 76 950 frames, which is before his first save and long before
// either Alpha. `referencesFromTrace` reads a Mesen pass, which replays the
// whole thing.
//
// So the sweep takes a source rather than a movie, and the two implementations
// are held to the same contract: anchors in, one optional reference each out,
// null for a stretch that could not be filled.

/// How much of `anchors[from..]` one Mesen pass can hold, and at what lengths.
///
/// A pass has 24 512 bytes: 1 560 for each stretch's snapshot and 27 for each
/// of its frames. A stretch longer than what is left over is **capped**, not
/// dropped and not silently truncated -- the batch ends on it, and the caller
/// counts it. Grading 850 frames of a 1 372-frame stretch is a smaller claim
/// honestly made; grading 1 372 frames of reference that only has 850 is not a
/// claim at all.
///
/// Pure arithmetic, split out from `TraceSource.take` so the packing can be
/// tested without a hundred seconds of emulator per case.
pub fn planPass(
    allocator: std.mem.Allocator,
    anchors: []const Anchor,
    from: usize,
    batch: *std.ArrayList(gb_trace.Stretch),
) !usize {
    batch.clearRetainingCapacity();
    var j = from;
    while (j < anchors.len) : (j += 1) {
        const a = anchors[j];
        // A stretch with no frame before it has nothing to snapshot, and one
        // with no frames is a snapshot nobody grades against. Both stop the
        // batch rather than being skipped over, so the caller sees them.
        if (a.origin == 0 or a.frames == 0) break;
        // What is left once this stretch's own snapshot is paid for.
        const spent = gb_trace.refsBytes(batch.items) + gb_trace.snapshot_bytes;
        if (spent >= gb_trace.trace_region) break;
        const fits = (gb_trace.trace_region - spent) / gb_trace.record_bytes;
        if (fits == 0) break;
        const frames: u32 = @intCast(@min(a.frames, fits));
        try batch.append(allocator, .{ .origin = a.origin, .frames = frames });
        if (frames < a.frames) {
            // The region is full to the byte: this stretch is the last in the
            // batch whether or not more anchors follow.
            j += 1;
            break;
        }
    }
    return j;
}

/// A producer of references, by anchor.
pub const RefSource = struct {
    ctx: *anyopaque,
    take: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        anchors: []const Anchor,
    ) anyerror![]?MovieRef,
    /// How many candidate frames per anchor the settle search should ask for at
    /// a time. **This is a property of the producer, not of the search.**
    ///
    /// A replay serves every candidate out of one run, so asking for all 120 at
    /// once is free and asking in rounds would be 30 replays instead of one:
    /// `MovieSource` sets this to `settle_search`. A Mesen pass holds fifteen
    /// snapshots and costs a replay each, so 120 candidates for three anchors
    /// is 24 passes -- measured, on the recording's first 900 frames -- while
    /// most anchors settle within a handful of frames of the handover. Rounds
    /// turn that into "ask for a few, keep only the anchors that still need
    /// more", which is the same answer for a fraction of the passes.
    settle_round: u32 = settle_search,

    /// One reference per anchor, in the anchors' own order. The caller owns
    /// every non-null one.
    pub fn references(
        self: RefSource,
        allocator: std.mem.Allocator,
        anchors: []const Anchor,
    ) anyerror![]?MovieRef {
        if (anchors.len == 0) return allocator.alloc(?MovieRef, 0);
        return self.take(self.ctx, allocator, anchors);
    }
};

/// References taken by replaying the movie on our own Game Boy: the source
/// every published run has always used.
pub const MovieSource = struct {
    rom: []const u8,
    movie: tas.Movie,

    pub fn source(self: *MovieSource) RefSource {
        return .{ .ctx = self, .take = MovieSource.take };
    }

    fn take(ctx: *anyopaque, allocator: std.mem.Allocator, anchors: []const Anchor) anyerror![]?MovieRef {
        const self: *MovieSource = @ptrCast(@alignCast(ctx));
        return referencesFromMovie(allocator, self.rom, self.movie, anchors);
    }
};

/// References taken off Mesen2, out of the recording B11 delivered.
///
/// **This is what removes the horizon.** Nothing here replays anything on our
/// Game Boy; `gb_trace.runRefs` drives the recording's own inputs back through
/// the emulator that recorded it, at roughly 700 frames a second, and reads the
/// references out of cart RAM.
///
/// One pass holds 24 512 bytes and a snapshot is 1 560 of them, so a set of
/// anchors is *batched* rather than run at once -- and a stretch longer than
/// what is left over is capped rather than silently truncated: `capped` counts
/// them so a caller can say how much of the run it did not ask about.
pub const TraceSource = struct {
    io: std.Io,
    rom: []const u8,
    rec: gb_trace.Recording,
    mesen_path: []const u8,
    home: []const u8,
    /// `tas.Opening.control`, which every reference carries so a report can say
    /// how far into the run a stretch sits.
    control: u32,
    offset: usize = gb_trace.input_offset,
    /// Mesen runs spawned, and stretches whose frame count did not fit. Both
    /// are counters rather than logs: a sweep's cost and its honesty, reported
    /// once at the end.
    passes: usize = 0,
    capped: usize = 0,

    pub fn source(self: *TraceSource) RefSource {
        return .{ .ctx = self, .take = TraceSource.take, .settle_round = settle_round_trace };
    }

    fn take(ctx: *anyopaque, allocator: std.mem.Allocator, anchors: []const Anchor) anyerror![]?MovieRef {
        const self: *TraceSource = @ptrCast(@alignCast(ctx));

        var out = try allocator.alloc(?MovieRef, anchors.len);
        errdefer allocator.free(out);
        @memset(out, null);
        errdefer for (out) |*maybe| {
            if (maybe.*) |*mr| mr.deinit(allocator);
        };

        var batch: std.ArrayList(gb_trace.Stretch) = .empty;
        defer batch.deinit(allocator);

        var i: usize = 0;
        while (i < anchors.len) {
            const j = try planPass(allocator, anchors, i, &batch);
            for (batch.items, anchors[i..j]) |st, a| {
                if (st.frames < a.frames) self.capped += 1;
            }
            if (batch.items.len == 0) {
                // Nothing about this anchor fits, which is a fact about the
                // anchor and not about the pass: leave it null and move on,
                // the way an unfilled slot is reported everywhere else.
                i += 1;
                continue;
            }

            var pass = try gb_trace.runRefs(
                allocator,
                self.io,
                self.rom,
                self.rec,
                batch.items,
                self.offset,
                self.mesen_path,
                self.home,
            );
            defer pass.deinit(allocator);
            self.passes += 1;

            const refs = try referencesFromTrace(
                allocator,
                self.rec.inputs,
                pass,
                anchors[i..j],
                self.control,
            );
            defer allocator.free(refs);
            @memcpy(out[i..j], refs);
            i = j;
        }
        return out;
    }
};

/// Turn a Mesen anchored pass into the references every grader already takes.
///
/// **This is the half of the sweep that removes the horizon.** The other
/// producer of `MovieRef`s, `referencesFromMovie`, replays the movie on our own
/// Game Boy — which for James's recording stops being his run at 28 796 of
/// 76 950 frames, so it cannot reach the two Alpha kills, the pickups, or the
/// save. Mesen replays the whole thing, and `gb_trace.runRefs` records at each
/// stretch exactly what a `MovieRef` carries. Nothing here replays anything;
/// the pass has already been taken.
///
/// The two producers are deliberately the same shape and are checked against
/// each other rather than trusted: `Frame` is filled from the same columns, and
/// `held` is the movie's own byte for the frame the game acted on — the pass
/// carries `$FF80` per frame so that claim is checked on the trace rather than
/// argued from a comment. See `Pass.lag`.
///
/// A stretch the replay never reached comes back null, for the reason
/// `referencesFromMovie` returns an unfilled slot as null: one bad anchor out
/// of fourteen should not lose the other thirteen.
pub fn referencesFromTrace(
    allocator: std.mem.Allocator,
    inputs: []const u8,
    pass: gb_trace.RefsPass,
    anchors: []const Anchor,
    control: u32,
) ![]?MovieRef {
    var out = try allocator.alloc(?MovieRef, anchors.len);
    errdefer allocator.free(out);
    var built: usize = 0;
    errdefer for (out[0..built]) |*maybe| {
        if (maybe.*) |*mr| mr.deinit(allocator);
    };

    for (anchors, 0..) |anchor, i| {
        built = i;
        out[i] = null;
        const ref = pass.find(anchor.origin) orelse continue;
        const n: usize = ref.snapshot.frames;
        if (n == 0) continue;

        const frames = try allocator.alloc(Frame, n);
        errdefer allocator.free(frames);
        const keys = try allocator.alloc(Key, n);
        errdefer allocator.free(keys);
        const held = try allocator.alloc(u8, n);
        errdefer allocator.free(held);

        var first_unsupported: ?usize = null;
        var bits: u8 = 0;
        for (0..n) |k| {
            frames[k] = .{
                .samus_x = @intCast(ref.pass.get(k, "samus_x")),
                .samus_y = @intCast(ref.pass.get(k, "samus_y")),
                .camera_x = @intCast(ref.pass.get(k, "camera_x")),
                .camera_y = @intCast(ref.pass.get(k, "camera_y")),
                .pose = @intCast(ref.pass.get(k, "pose")),
                .facing = @intCast(ref.pass.get(k, "facing")),
                .pad = @intCast(ref.pass.get(k, "pad")),
                .counter = @intCast(ref.pass.get(k, "counter")),
                .water = @intCast(ref.pass.get(k, "water")),
            };
            // The movie's held byte for the frame the game acted on, which is
            // the frame the row was recorded on. The offset is the script's,
            // not this function's: `Pass.first` is a movie frame already.
            const f = ref.pass.first + k;
            held[k] = if (f < inputs.len) inputs[f] else 0;
            keys[k] = movieKey(held[k]);
            const u = unsupportedBits(held[k]);
            if (u != 0 and first_unsupported == null) {
                first_unsupported = k;
                bits = u;
            }
        }

        const s = ref.snapshot;
        out[i] = .{
            .settled = .{
                .placement = .{
                    .map_bank = s.map_bank,
                    .warp_bank = s.warp_bank,
                    .screen_row = s.screen_row,
                    .screen_col = s.screen_col,
                    .pixel_y = s.pixel_y,
                    .pixel_x = s.pixel_x,
                },
                .frames = frames,
                .tiles = s.tiles,
                // The movie path sets `tiles_before` and `coltab_before` to the
                // same read, because nothing was spawned: they exist to tell
                // "the warp never redrew the room" from "the warp redrew the
                // wrong room", and a movie reference never warps. Set the same
                // way here rather than left zero, which would read as a room
                // full of tile $00.
                .tiles_before = s.tiles,
                .scx = s.scx,
                .scy = s.scy,
                .camera_x = s.camera_x,
                .camera_y = s.camera_y,
                .solid = s.solid,
                .coltab = s.coltab,
                .coltab_before = s.coltab,
                // The four the trace carries. Health, the missile count and
                // the displayed Metroid count are not columns -- growing the
                // trace means re-running the 76 951-frame replay -- so a stretch
                // anchored here boots with the new game's for those.
                .loadout = .{
                    .tanks = @intCast(ref.pass.get(0, "etanks")),
                    .max_missiles = @intCast(ref.pass.get(0, "missiles_max")),
                    .metroid_real = @intCast(ref.pass.get(0, "metroid_count")),
                    .items = @intCast(ref.pass.get(0, "items")),
                },
            },
            .keys = keys,
            .origin = anchor.origin,
            .control = control,
            .map_bank = s.map_bank,
            .held = held,
            .first_unsupported = first_unsupported,
            .unsupported_bits = bits,
        };
        built = i + 1;
    }
    built = out.len;
    return out;
}

/// How still a stretch has to be before it counts as a re-anchor point.
///
/// **Measured, not chosen for roundness.** Over the any% run to its horizon the
/// census is 25 refusals at 4 frames, 14 at 8, 12 at 12 and 5 at 24 -- and
/// *every one of them is released*, because the horizon is defined by the first
/// one that is not. Eight is where the count stops falling steeply and starts
/// naming door approaches rather than incidental pauses, and fourteen carts is
/// a gate that runs in minutes. `zig build tas -- any anchors` reprints the
/// census, so moving this is a measurement rather than an argument.
pub const anchor_min_frames: u32 = 8;

/// Move an anchor forward until the frame before it and the frame at it are in
/// the same room **and** in the same pose.
///
/// **Measured, and it is why the first anchored sweep scored twelve stretches
/// at zero.** A boot record is taken from the frame *before* the reference's
/// frame 0 -- her position, the camera, the tilemap, the collision tables -- and
/// the first compared frame is the one after it. That is sound while both
/// frames are in the same room and false the instant they are not: at the any%
/// run's second handover, frame 702 is cell $77 of map bank $F and frame 703 is
/// cell $43, so the cart was built to boot into the room she was *leaving* and
/// then graded against the room she arrived in. `zig build trace -- stretch 1`
/// reported it as a position that differed in the screen byte and agreed in the
/// pixel byte, which is what a room change looks like from inside a comparison
/// that does not know it happened.
///
/// **And the pose, which the pad seed is what exposed.** A boot record puts the
/// cart directly into the pose the reference is in; it cannot reproduce the
/// frame the reference spent *changing* pose. The opening is the case that
/// makes this concrete: at `control` the reference's pose already reads
/// `stand`, but that frame is the one it spent leaving the landing pose $13,
/// and it answers the movie's held `right` by not moving. A cart booted
/// standing with `right` seeded walks on that frame, and the two disagree about
/// a transition rather than about physics. With the pad seed at zero this was
/// invisible: the cart also did not move, for the unrelated reason that its
/// first `PublishPad` had nothing to publish, and the opening scored 375 frames
/// on two errors cancelling.
///
/// A refusal ends *because* the position or the pose changed, so this pushes by
/// at least one frame whenever the pose is what ended it. That is the point.
///
/// The push is bounded by the horizon and returns null rather than running past
/// it, because an anchor that needs an unbounded search is not an anchor.
fn pushToStableAnchor(track: tas.Track, handover: u32, horizon: u32) ?u32 {
    var f = handover;
    while (f < horizon) : (f += 1) {
        if (f == 0) return null;
        // The track's frame 0 is not its index 0 unless it happens to start at
        // the beginning, which a Mesen window does not. `indexOf` is what
        // makes this work over a window as well as over a replay; a frame the
        // track does not carry is not a place an anchor can be settled, so it
        // is skipped rather than assumed contiguous.
        const i = track.indexOf(f) orelse continue;
        const prev = track.indexOf(f - 1) orelse continue;
        if (!tas.Room.of(track.samples[prev]).eql(tas.Room.of(track.samples[i]))) continue;
        if (track.samples[prev].pose != track.samples[i].pose) continue;
        return f;
    }
    return null;
}

/// Every stretch of the movie worth grading, in order.
///
/// An anchor is the frame a refusal hands Samus back: the general form of
/// `tas.findOpening`, which finds only the first one. `tas.findRefusals` is
/// checked against that special case by a test in `src/tas.zig`, so this cannot
/// quietly start grading from a different frame than Step 15b measured.
///
/// **Stretches run anchor to anchor, not anchor to the next refusal.** The
/// alternative was tried on paper and throws away measured ground: the port
/// currently matches 377 frames from the opening, and the second refusal starts
/// at movie frame 608 -- so cutting each stretch at the next still patch would
/// score the first at 282 and call the loss a design decision. The refusals are
/// frames the port has to reproduce like any other; what the anchors buy is a
/// *re-seed* at each one, so a stretch the port cannot enter does not cost it
/// every stretch after.
///
/// Bounded by the horizon, because past it the replay is no longer the
/// published run and an anchor there would grade the port against a route
/// nobody recorded.
///
/// Over a replay the caller already has, because the settle search needs the
/// *same* samples these anchors were derived from: two replays are two chances
/// to have taken a different route, and an anchor placed against one run and
/// settled against another would be nobody's measurement.
pub fn anchorsFrom(allocator: std.mem.Allocator, track: tas.Track, min: u32) ![]Anchor {
    // **Stride 1 or nothing.** A refusal's length is counted in samples, so on
    // a strided track `Refusal.handover` is a sample index dressed as a frame
    // and every anchor lands somewhere nobody measured. A census pass is for
    // finding landmarks, not for anchoring on them.
    if (track.samples.len >= 2 and (track.stride() orelse 0) != 1) return Error.NotPerFrame;

    const fs = try tas.faithfulness(allocator, track, tas.stuck_min_frames);
    const horizon: u32 = fs.horizon() orelse track.end();

    const refusals = try tas.findRefusals(allocator, track, min);
    defer allocator.free(refusals);

    var out: std.ArrayList(Anchor) = .empty;
    errdefer out.deinit(allocator);
    for (refusals) |ref| {
        if (ref.start >= horizon) break;
        // A refusal she never leaves is not a handover; it is the horizon
        // arriving. `faithfulness` uses the same predicate to place the
        // horizon, so inside it this is belt and braces -- but the horizon is
        // computed at `stuck_min_frames` and these at `min`, and a shorter
        // stretch could in principle be stuck without moving the horizon.
        if (!ref.released(tas.release_window)) continue;
        const h = ref.handover();
        if (h >= horizon) break;
        const o = pushToStableAnchor(track, h, horizon) orelse continue;
        try out.append(allocator, .{ .origin = o, .frames = 0, .handover = h });
    }
    if (out.items.len == 0) return out.toOwnedSlice(allocator);

    // Each stretch runs to the next anchor, and the last one to the horizon.
    for (out.items[0 .. out.items.len - 1], out.items[1..]) |*a, b| {
        a.frames = b.origin - a.origin;
    }
    const last = &out.items[out.items.len - 1];
    last.frames = horizon - last.origin;

    return out.toOwnedSlice(allocator);
}

// ---- The exit-code protocol -----------------------------------------------

/// The segment's resolution: `segment_frames` over `codes_per_quantity` codes.
///
/// Derived rather than written down, because it stopped being a number a person
/// could keep right by hand the moment either the segment's length or the band
/// width moved. `perCode` is the same function the movie's take uses, so the two
/// paths cannot drift.
pub const frames_per_code: usize = perCode(segment_frames);

/// The codes a divergence may occupy per quantity, which is what caps the
/// resolution: 20-79 position, 80-139 camera, 140-199 pose.
///
/// **This was 80, for two quantities, until the pose became a third on
/// 2026-09-02.** The morph bug is the argument for the change and the argument
/// for it being a band rather than a single code: a ball that unmorphs itself
/// at the top of a bounce is in the wrong *pose* while standing on exactly the
/// right *pixel*, and the segment graded it as a match for as long as position
/// and camera were the whole comparison. Three 60-wide bands fit the byte where
/// three 80-wide ones do not, and 60 is chosen over 75 so `code_unhandled`
/// keeps a range wide enough to name any pose the original dispatches.
pub const codes_per_quantity: usize = 60;

/// Frames per exit code for a reference of `n` frames.
///
/// The segment is 320 frames and gets 4. The movie is however far the port
/// reaches, and a fixed 4 would silently stop resolving anything past frame 320
/// -- so the resolution is derived from the length instead, and reported next
/// to the verdict rather than left implicit.
pub fn perCode(n: usize) usize {
    return @max(1, std.math.divCeil(usize, n, codes_per_quantity) catch 1);
}

/// One run of the oracle: what the original did, the inputs that made it do
/// that, and the resolution the one-byte channel can name a divergence at.
///
/// The segment and the movie differ in exactly these three things. Everything
/// downstream -- the generated script, the exit-code protocol, the fault sweep
/// -- is written against this rather than against `segment`.
pub const Take = struct {
    ref: []const Frame,
    /// One entry per frame of `ref`, in the port's three-key vocabulary.
    keys: []const Key,
    per_code: usize,
    /// Bytes written into the cart's WRAM at its first commit, before any
    /// graded frame runs: the cart's half of `referenceWith`'s `items`.
    pokes: []const Poke = &.{},
    /// The pads the cart is given before its first graded frame, one per
    /// frame, in Mesen's `setInput` form: the debug menu opened, the items set
    /// and the menu closed (1.0 Step 7), the other way `referenceWith`'s
    /// `items` reaches the cart. Every frame of it is the menu's, so the game
    /// is frozen through it; the boot record's counter is seeded that many
    /// frames early so it arrives in phase. See `menuSetup`.
    setup: []const []const u8 = &.{},
    /// `!Items` once the setup has closed the menu.
    setup_items: u8 = 0,
    /// NMIs over the setup's passes: what the Game Boy's counter is moved on
    /// by (`referenceWith`'s `frozen`), and what the script checks the cart's
    /// moved by. See `menu_open_lag`.
    setup_nmis: usize = 0,
    /// `!Beam` once the setup has closed the menu, when it set one.
    setup_beam: ?u8 = null,
    /// 1.0 Step 8c: grade the projectile array (`Frame.projs`) on every
    /// frame, after Samus, in the codes from `code_projectile`.
    projs: bool = false,
    /// 1.0 Step 8c: the enemy slot the Game Boy was seeded with before frame
    /// 1, given to the cart at the same point. See `Enemy`.
    seed: ?enemy_oracle.Seed = null,
    /// 1.0 Step 9: grade Samus's health (`Frame.health`) on every frame,
    /// last, in `code_health`.
    health: bool = false,
    /// 1.0 Step 27b: the frames a door's crossing takes, which are graded
    /// only at the last. See `Door`.
    door: ?Door = null,

    pub fn of(ref: []const Frame, keys: []const Key) Take {
        return .{ .ref = ref, .keys = keys, .per_code = perCode(ref.len) };
    }

    /// Another reference over the same cart: what is compared changes, and
    /// what the cart is given before it -- the pokes, the menu's setup -- does
    /// not. The bisection and the fault sweep build their takes with this;
    /// until 1.0 Step 7 they used `of`, which dropped both, so a spider
    /// segment that diverged would have been pinned by runs without Spider
    /// Ball.
    pub fn over(self: Take, ref: []const Frame, keys: []const Key) Take {
        var t = self;
        t.ref = ref;
        t.keys = keys;
        t.per_code = perCode(ref.len);
        return t;
    }
};
pub const Poke = struct { addr: u16, value: u8 };

pub const code_ok: u8 = 0;
pub const code_never_booted: u8 = 1;
pub const code_fatal: u8 = 2;
pub const code_wrong_start: u8 = 3;
pub const code_short: u8 = 4;

/// The cart's frame counter was not the boot record's seed plus one on the
/// first frame of `MainLoop`.
///
/// **Its own code because it is a cause and every other code here is a
/// symptom.** `WalkSpeed` is `(!FrameCount & 1) + 1`, so a phase one out makes
/// Samus walk 1 where the reference walks 2 on alternate frames and the run
/// reports `code_position` a hundred frames later. That is exactly how it
/// presented on 2026-09-09, and it cost a session to trace back; see
/// `docs/bug_tracker.md`. The engine decides it -- nothing outside can, since
/// the seed is `InitState`'s and the increments are NMI's -- and this code is
/// how it is carried out.
pub const code_frame_phase: u8 = 5;

/// The debug menu did not set the loadout up (1.0 Step 7): it was shut on a
/// frame of the setup that should have been its, or open after the last, or
/// the items it left are not the ones asked for. The last of the codes the
/// fade leaves free between `code_frame_phase` and `code_position`.
pub const code_setup: u8 = 19;

/// The projectile array diverged (1.0 Step 8c): the codes the fade leaves free
/// between `code_frame_phase` and `code_setup`, which no take that grades
/// projectiles also grades a fade with. Thirteen codes and not sixty, so each
/// is `projectile_widen` of the take's buckets wide: `decode` can then read one
/// back from the take's own `per_code`, and the bisection pins the frame.
pub const code_projectile: u8 = 6;
pub const codes_projectile: usize = code_setup - code_projectile;
pub const projectile_widen: usize = (codes_per_quantity + codes_projectile - 1) / codes_projectile;
comptime {
    std.debug.assert(codes_projectile * projectile_widen >= codes_per_quantity);
}
pub const code_position: u8 = 20;
pub const code_camera: u8 = code_position + codes_per_quantity;
pub const code_pose: u8 = code_camera + codes_per_quantity;

/// The port was handed a pose it has no handler for.
///
/// Its own range rather than a single code, because *which* pose is the whole
/// value of the check: it names the next thing to port. The pose is the offset,
/// so $0B arrives as 191.
///
/// 200 is where the pose's range ends and 255 is the emulator's own timeout,
/// which leaves 55. Every pose the Game Boy's own machine dispatches fits --
/// they run $00-$1D -- except the turnaround, `$80|$03`, and that one is
/// implemented, so it cannot reach here. A pose past the range saturates on the
/// last code and `unhandledPose` says so rather than reporting a wrong number.
pub const code_unhandled: u8 = code_pose + codes_per_quantity;
pub const codes_unhandled: usize = code_obp1 - @as(usize, code_unhandled);

/// Samus's health diverged (1.0 Step 9), on some frame of the take: one code,
/// the last below the emulator's own timeout, taken off the top of the
/// unhandled poses' range, which still holds poses up to $35. No bucket: the
/// script prints the frame, and the bisection pins it from the whole take.
pub const code_health: u8 = 254;

/// The objects on the second palette diverged (1.0 Step 25), graded by the
/// takes that grade health: one code, the next down, taken off the unhandled
/// poses' range, which still holds poses up to $34.
pub const code_obp1: u8 = 253;

/// The pose an unhandled-pose exit was carrying, and whether it is exact.
///
/// `saturated` is not a detail: a caller printing "pose $4A" for what was
/// really $C0 would send the next person to write a handler for the wrong pose.
pub fn unhandledPose(code: u8) ?struct { pose: u8, saturated: bool } {
    if (code < code_unhandled or code >= code_unhandled + codes_unhandled) return null;
    const p = code - code_unhandled;
    return .{ .pose = p, .saturated = p == codes_unhandled - 1 };
}

/// How many frames one exit code names for a quantity: `per_code`, or
/// `projectile_widen` of them for the projectiles.
pub fn bucketWidth(what: What, per_code: usize) usize {
    return switch (what) {
        .projectile => per_code * projectile_widen,
        .health, .obp1 => per_code * codes_per_quantity,
        else => per_code,
    };
}

pub fn codeFor(d: Divergence, per_code: usize) u8 {
    const base: u8 = switch (d.what) {
        .position => code_position,
        .camera => code_camera,
        .pose => code_pose,
        .projectile => return code_projectile + @as(u8, @intCast(@min(codes_projectile - 1, d.frame / (per_code * projectile_widen)))),
        .health => return code_health,
        .obp1 => return code_obp1,
    };
    return base + @as(u8, @intCast(@min(codes_per_quantity - 1, d.frame / per_code)));
}

/// A one-line account of what an exit code means.
pub fn explain(code: u8) []const u8 {
    return switch (code) {
        code_ok => "every frame of the segment matched",
        code_never_booted => "the cart never reached its main loop",
        code_fatal => "the engine hit Fatal",
        code_wrong_start => "the cart did not boot where the reference was taken -- Samus or the camera",
        code_short => "the segment ended early",
        code_frame_phase => "the cart's frame counter was not the boot record's seed plus one on MainLoop's first frame",
        code_setup => "the debug menu did not set the loadout up: shut too soon, open after, or the items not the ones asked for",
        255 => "the emulator timed out with no verdict",
        // The pose itself is in the code and callers print it; this is the
        // sentence that goes in front of it. Kept out of `explain`'s return
        // type on purpose -- it is a static string, and formatting the pose
        // here would mean an allocator on a path that has never needed one.
        else => if (unhandledPose(code) != null)
            "the port was handed a pose it has no handler for"
        else if (decode(code, 1)) |d| switch (d.what) {
            .position => "Samus's position diverged",
            .camera => "the camera's motion diverged",
            .pose => "Samus was in a different pose",
            .projectile => "the projectile array diverged",
            .health => "Samus's health diverged",
            .obp1 => "the objects on the second palette diverged",
        } else "an unallocated exit code",
    };
}

/// The inverse, for `verify` to report what the emulator said. `per_code` is
/// the run's own resolution -- `Report.per_code`, not the segment's constant.
pub fn decode(code: u8, per_code: usize) ?Divergence {
    if (code >= code_position and code < code_camera)
        return .{ .frame = @as(usize, code - code_position) * per_code, .what = .position };
    if (code >= code_camera and code < code_pose)
        return .{ .frame = @as(usize, code - code_camera) * per_code, .what = .camera };
    if (code >= code_pose and code < code_pose + codes_per_quantity)
        return .{ .frame = @as(usize, code - code_pose) * per_code, .what = .pose };
    if (code >= code_projectile and code < code_projectile + codes_projectile)
        return .{ .frame = @as(usize, code - code_projectile) * per_code * projectile_widen, .what = .projectile };
    if (code == code_health) return .{ .frame = 0, .what = .health };
    if (code == code_obp1) return .{ .frame = 0, .what = .obp1 };
    return null;
}

/// Whether a divergence is resolved to the frame or left as a bucket.
///
/// The bucket is free -- it falls out of the exit code the run already
/// returned. The frame costs `Bisect.runs` more emulator runs, so it is a
/// choice each rung makes rather than a default the sweep pays for silently.
pub const Resolution = enum { bucket, exact };

/// Turning a divergence bucket into a frame, by bisecting on how much of the
/// reference the cart is offered.
///
/// **Why this works.** Truncating the reference to `n` frames cannot change
/// what the cart does on frames `0..n-1`: same cart, same boot record, same
/// inputs, same comparator, told to stop sooner. So "does a run against the
/// first `n` frames stop before it runs out of them?" is monotone in `n` --
/// false for every `n` at or below the first divergent frame `d`, true for
/// every `n` above it -- and the smallest `n` that diverges is `d + 1`.
///
/// **Why it is bounded by the bucket.** The coarse run already returned a code,
/// and `decode` reads it as "the divergence is somewhere in
/// `[start, start + per_code - 1]`". So `start` is a length known to match and
/// `start + per_code` a length known to diverge, and the search starts between
/// two answers rather than at the ends of the reference. That is
/// `ceil(log2(per_code))` runs -- four at the movie rung's width of 15 -- and
/// none at all when the bucket is already one frame wide.
///
/// **What it replaces.** A single re-run that truncated to the bucket's end and
/// hoped `perCode` of the truncated length came back 1. That only happens when
/// the whole truncation fits in `codes_per_quantity` frames, so it resolved
/// divergences inside the first 60 frames and nothing else -- and the movie
/// rung's divergence is at 376. The floors were bucket edges for that reason,
/// not because a floor wants to be one.
///
/// Split from the running so the search can be tested without an emulator: the
/// property that matters -- the same frame comes back whatever the bucket width
/// was -- is a property of this struct alone.
pub const Bisect = struct {
    /// A reference length known to match. Never run: it is the bucket's bottom
    /// edge, which the coarse run established.
    lo: usize,
    /// A reference length known to diverge. Likewise never run.
    hi: usize,
    /// Emulator runs this search has asked for.
    runs: usize = 0,

    /// `start` is the bucket's bottom edge from `decode`, `per_code` the
    /// coarse run's resolution, and `offered` the full reference length.
    ///
    /// `hi` is clamped to `offered`, for the bucket that runs off the end of
    /// the reference: the last bucket is short, and the run that produced the
    /// code is itself the evidence that `offered` diverges.
    pub fn init(start: usize, per_code: usize, offered: usize) Bisect {
        return .{ .lo = start, .hi = @min(start + per_code, offered) };
    }

    /// The next reference length to run, or null when the frame is pinned.
    pub fn next(self: Bisect) ?usize {
        if (self.hi - self.lo <= 1) return null;
        return self.lo + (self.hi - self.lo) / 2;
    }

    /// Record what a run of `n` frames did. `diverged` is false only for a run
    /// that matched every frame it was offered.
    pub fn observe(self: *Bisect, n: usize, diverged: bool) void {
        self.runs += 1;
        if (diverged) self.hi = n else self.lo = n;
    }

    /// The first divergent frame: one less than the shortest reference that
    /// diverges. Only meaningful once `next` returns null.
    pub fn frame(self: Bisect) usize {
        return self.hi - 1;
    }
};

// ---- The generated Mesen2 script ------------------------------------------

/// The engine's commit point: the top of `MainLoop`, where frame N's logic is
/// complete and frame N+1's has not started. See the module comment.
pub const commit_symbol = "MainLoop";

/// Where `HandlePose`'s fallback records the first pose Phase 0a cannot run.
///
/// `snes_trace.zig` reads the same symbol for its post-hoc trace. That was its
/// *only* reader until 2026-09-01, which is what made the engine's comment
/// about "the gate reads this and fails" wrong for as long as it stood.
pub const unhandled_symbol = "VarUnhandled";

/// Where `MainLoop`'s first frame records that the counter's phase was wrong.
/// See `code_frame_phase`.
pub const frame_phase_symbol = "VarFramePhase";

/// Write the oracle script for the finished cart.
pub fn writeLua(
    allocator: std.mem.Allocator,
    settled: Settled,
    take: Take,
    w: *std.Io.Writer,
) !void {
    const ref = take.ref;
    var missing: []const u8 = "";
    const map = try correspond.resolve(allocator, &missing);
    defer allocator.free(map);

    const commit = @import("snes_inject.zig").symbol(commit_symbol) orelse return Error.MissingSymbol;
    // Resolved from `engine.sym` like everything else here. `HandlePose`'s
    // fallback records the first pose it cannot run in this byte; until
    // 2026-09-01 nothing that graded ever read it, though the engine's comment
    // claimed the gate did.
    const unhandled: u16 = @truncate(
        @import("snes_inject.zig").symbol(unhandled_symbol) orelse return Error.MissingSymbol,
    );
    const frame_phase: u16 = @truncate(
        @import("snes_inject.zig").symbol(frame_phase_symbol) orelse return Error.MissingSymbol,
    );
    const debug_open: u16 = @truncate(
        @import("snes_inject.zig").symbol("VarDebugOpen") orelse return Error.MissingSymbol,
    );
    const items_at: u16 = @truncate(
        @import("snes_inject.zig").symbol("VarItems") orelse return Error.MissingSymbol,
    );
    const frames_at: u16 = @truncate(
        @import("snes_inject.zig").symbol("VarFrameCount") orelse return Error.MissingSymbol,
    );
    const at = struct {
        fn of(m: []const correspond.Resolved, comptime name: []const u8) u16 {
            for (m) |r| {
                if (std.mem.eql(u8, r.pair.name, name)) return @truncate(r.addr);
            }
            unreachable;
        }
    };
    const pos = settled.position();

    try w.print(
        \\-- Generated by `zig build oracle`. Do not edit.
        \\--
        \\-- One hand-authored segment, run on the Game Boy through src/oracle.zig
        \\-- and baked in below, then run again here and compared frame for frame.
        \\-- Position and camera only: they are the two things Phase 0a's port has.
        \\--
        \\-- Mesen2 swallows emu.log in testrunner mode and sandboxes lua's io, so
        \\-- the exit code is the whole channel:
        \\--    0  every frame of the segment matched
        \\--    1  the engine never reached its main loop
        \\--    2  Fatal ran
        \\--    3  she or the camera did not start where the reference started
        \\--    4  the segment ended early
        \\--    5  the frame counter's phase is wrong: NMI ran a different number
        \\--       of times between the record's seed and MainLoop's first frame
        \\--  6-18 the projectile array diverged, at frame (code - 6) * PER_PROJ
        \\--       (1.0 Step 8c; only a take that grades projectiles)
        \\--   19  the debug menu did not set the loadout up (1.0 Step 7)
        \\--   20+ Samus's position diverged, at frame (code - 20) * PER_CODE
        \\--   80+ the camera diverged, at frame (code - 80) * PER_CODE
        \\--  140+ Samus was in a different pose, at frame (code - 140) * PER_CODE
        \\--  200+ the port was handed pose (code - 200) and has no handler
        \\--  253 the objects on OBP1 diverged (1.0 Step 25; the takes that grade health)
        \\--  254 Samus's health diverged (1.0 Step 9; only a take that grades it)
        \\
        \\local wram = emu.memType.snesWorkRam
        \\
        \\-- Addresses resolved from engine.sym by src/correspond.zig, never
        \\-- written down: a hand-copied address is a second source of truth.
        \\local AT_SAMX, AT_SAMY = 0x{X:0>4}, 0x{X:0>4}
        \\local AT_CAMX, AT_CAMY = 0x{X:0>4}, 0x{X:0>4}
        \\local AT_POSE = 0x{X:0>4}
        \\local AT_UNH = 0x{X:0>4}
        \\local AT_PHASE = 0x{X:0>4}
        \\local AT_OPEN, AT_ITEMS, AT_FRAMES = 0x{X:0>4}, 0x{X:0>4}, 0x{X:0>4}
        \\local COMMIT = 0x{X:0>6}
        \\
        \\local START_X, START_Y = {d}, {d}
        \\local START_CAMX, START_CAMY = {d}, {d}
        \\local CODE_POS, CODE_CAM, CODE_POSE, PER_CODE = {d}, {d}, {d}, {d}
        \\local CODE_UNH, UNH_MAX = {d}, {d}
        \\local CODE_PHASE, CODE_SETUP = {d}, {d}
        \\
    , .{
        at.of(map, "samus_x"),   at.of(map, "samus_y"),
        at.of(map, "camera_x"),  at.of(map, "camera_y"),
        at.of(map, "pose"),
        unhandled,               frame_phase,
        debug_open,              items_at,
        frames_at,
        commit,
        pos.x, pos.y,
        ref[0].camera_x, ref[0].camera_y,
        code_position, code_camera, code_pose, take.per_code,
        code_unhandled, codes_unhandled - 1,
        code_frame_phase,        code_setup,
    });

    // The reference, one row per frame. Baked rather than loaded: there is no
    // file to load it from on the emulator side.
    // Both quantities absolute, which is what `firstDivergence` compares. The
    // camera used to be baked as a delta from its own frame 0, because the cart
    // could not be told where its camera began; boot record version 4 tells it.
    try w.print("local REF = {{\n", .{});
    for (ref) |f| {
        try w.print("  {{{d},{d},{d},{d},{d}}},\n", .{
            f.samus_x,
            f.samus_y,
            f.camera_x,
            f.camera_y,
            f.pose,
        });
    }
    try w.print("}}\n\n", .{});

    // The input schedule, as one entry per frame rather than as phases: the
    // script has to index it per frame anyway, and a phase table on this side
    // would be a second copy of `segment` to keep in step.
    try w.print("local KEYS = {{\n", .{});
    var keybuf: [mesen_keys_max]u8 = undefined;
    for (take.keys) |k| {
        try w.print("  {{{s}}},\n", .{mesenKeys(k, &keybuf)});
    }
    try w.print("}}\n\n", .{});

    try w.print("local POKES = {{", .{});
    for (take.pokes) |pk| try w.print("{{{d},{d}}},", .{ pk.addr, pk.value });
    try w.print("}}\n\n", .{});

    // The menu's pads, before the first graded frame. Empty but for a take
    // whose items go through the debug menu.
    try w.print("local SETUP = {{\n", .{});
    for (take.setup) |p| try w.print("  {{{s}}},\n", .{p});
    try w.print("}}\nlocal SETUP_ITEMS, SETUP_NMIS = {d}, {d}\n", .{ take.setup_items, take.setup_nmis });
    try w.print("local SETUP_BEAM, AT_BEAM = {d}, 0x{X:0>4}\n\n", .{
        if (take.setup_beam) |b| @as(i16, b) else -1,
        @as(u16, @truncate(@import("snes_inject.zig").symbol("VarBeam") orelse return Error.MissingSymbol)),
    });

    // 1.0 Step 8c: the projectile array per frame, and the enemy seed. Both
    // empty for every take before it.
    try w.print("local PROJ = {{\n", .{});
    if (take.projs) for (ref) |f| {
        try w.print("  {{", .{});
        for (f.projs) |b| try w.print("{d},", .{b});
        try w.print("}},\n", .{});
    };
    try w.print(
        \\}}
        \\local AT_PROJS, PROJ_SIZE, PROJ_FIELDS = 0x{X:0>4}, {d}, {{{d},{d},{d}}}
        \\local CODE_PROJ, PER_PROJ = {d}, {d}
        \\
    , .{
        @as(u16, @truncate(@import("snes_inject.zig").symbol("VarProjs") orelse return Error.MissingSymbol)),
        gb_proj_size,
        proj_fields[0], proj_fields[1], proj_fields[2],
        code_projectile, take.per_code * projectile_widen,
    });

    // 1.0 Step 9: her health per frame. Empty for every take before it.
    try w.print("local HEALTH = {{", .{});
    if (take.health) for (ref) |f| try w.print("{d},", .{f.health});
    try w.print(
        \\}}
        \\local AT_HEALTH, CODE_HEALTH = 0x{X:0>4}, {d}
        \\
    , .{
        @as(u16, @truncate(@import("snes_inject.zig").symbol("VarHealthLo") orelse return Error.MissingSymbol)),
        code_health,
    });
    // 1.0 Step 25: the objects on OBP1 per frame, by the same takes.
    try w.print("local OBP1 = {{", .{});
    if (take.health) for (ref) |f| try w.print("{d},", .{f.obp1});
    try w.print(
        \\}}
        \\local AT_OAM, AT_OAMIDX, CODE_OBP1 = 0x{X:0>4}, 0x{X:0>4}, {d}
        \\
    , .{
        @as(u16, @truncate(@import("snes_inject.zig").symbol("VarOamBuf") orelse return Error.MissingSymbol)),
        @as(u16, @truncate(@import("snes_inject.zig").symbol("VarOamIdx") orelse return Error.MissingSymbol)),
        code_obp1,
    });
    if (take.door) |d| {
        try w.print("local DOOR_FROM, DOOR_LAST = {d}, {d}\n", .{ d.from + 1, d.last + 1 });
    } else try w.print("local DOOR_FROM, DOOR_LAST = math.huge, math.huge\n", .{});
    if (take.seed) |sd| {
        try enemy_oracle.writeSeedLua(w, sd);
    } else try w.print("local seed = nil\n", .{});
    try w.print("\n", .{});

    try w.print(
        \\local function rd16(a) return emu.read(a, wram) + 256 * emu.read(a + 1, wram) end
        \\
        \\local p = -1         -- commits seen, less one: the passes that have run
        \\local hold = nil
        \\local N = #SETUP
        \\local counter1 = 0   -- the counter at graded frame 0, before the menu
        \\
        \\-- Sampled at the top of MainLoop, which is the engine's commit point:
        \\-- everything below is written between the `wai` and the branch back
        \\-- here, and nothing writes it afterwards. `endFrame` would sample
        \\-- wherever the loop happened to be when the PPU finished, which is a
        \\-- race; `nmi` would sample before the frame's logic had run at all.
        \\-- `emu.callbackType`, not `emu.memCallbackType`: this build of Mesen2
        \\-- leaves the latter nil, and registering against a nil field is a
        \\-- script-load error, which in testrunner mode is silent and reads as
        \\-- a timeout. Probed rather than remembered.
        \\emu.addMemoryCallback(function()
        \\  -- Before the position check, because this is the cause and a
        \\  -- position divergence is its symptom: a pose with no handler
        \\  -- leaves Samus where she was, so she is "in the wrong place" a
        \\  -- frame or two later and that is what the gate used to report.
        \\  -- Sticky on the engine's side -- it keeps the first pose only --
        \\  -- so reading it at every commit costs one byte and cannot miss.
        \\  -- And before *that*, because it is a cause of causes: a counter one
        \\  -- NMI out of phase inverts every walk step, and the run reports a
        \\  -- position divergence a hundred frames later with nothing wrong in
        \\  -- the port at all. Sticky on the engine's side, set on the first
        \\  -- frame of `MainLoop` and never cleared.
        \\  if emu.read(AT_PHASE, wram) ~= 0 then emu.stop(CODE_PHASE) return end
        \\  local unh = emu.read(AT_UNH, wram)
        \\  if unh ~= 0 then
        \\    if unh > UNH_MAX then unh = UNH_MAX end
        \\    emu.stop(CODE_UNH + unh)
        \\    return
        \\  end
        \\  p = p + 1
        \\  -- With a setup, pass 1 is graded frame 0 as ever -- the logic runs
        \\  -- a frame behind the pad, so the first pad reaches pass 2 -- and
        \\  -- passes 2 to N+1 are the menu's: the chord opens it, the chord
        \\  -- again on the last shuts it. Graded frame g >= 1 is pass g + N.
        \\  -- The Game Boy's counter is moved on N after its frame 0 to match.
        \\  if p == 0 then
        \\    -- The first arrival here is before any frame of logic has run, so
        \\    -- she is exactly where the boot record put her. The reference was
        \\    -- taken from the same place; if this disagrees, everything after
        \\    -- it would be measuring two different starts.
        \\    if rd16(AT_SAMX) ~= START_X or rd16(AT_SAMY) ~= START_Y then emu.stop(3) end
        \\    if rd16(AT_CAMX) ~= START_CAMX or rd16(AT_CAMY) ~= START_CAMY then emu.stop(3) end
        \\    for _, pk in ipairs(POKES) do emu.write(pk[1], pk[2], wram) end
        \\  elseif N > 0 and p >= 2 and p <= N then
        \\    if emu.read(AT_OPEN, wram) == 0 then
        \\      print(string.format("setup pass %d of %d: the menu is shut", p - 1, N))
        \\      emu.stop(CODE_SETUP)
        \\      return
        \\    end
        \\  elseif N > 0 and p == N + 1 then
        \\    local open, items = emu.read(AT_OPEN, wram), emu.read(AT_ITEMS, wram)
        \\    local nmis = (rd16(AT_FRAMES) - counter1) & 0xFFFF
        \\    local beam = emu.read(AT_BEAM, wram)
        \\    if open ~= 0 or items ~= SETUP_ITEMS or nmis ~= SETUP_NMIS or (SETUP_BEAM >= 0 and beam ~= SETUP_BEAM) then
        \\      print(string.format("after the setup: menu %d, items %02x, wanted %02x; beam %02x, wanted %d; %d NMIs, the reference froze %d",
        \\        open, items, SETUP_ITEMS, beam, SETUP_BEAM, nmis, SETUP_NMIS))
        \\      emu.stop(CODE_SETUP)
        \\      return
        \\    end
        \\  else
        \\    local g = p
        \\    if p > 1 then g = p - N end
        \\    if p == 1 then counter1 = rd16(AT_FRAMES) end
        \\    local r = REF[g]
        \\    -- 1.0 Step 27b: a door segment's crossing is not graded frame for
        \\    -- frame (`Take.door`), only its last, settled frame.
        \\    if g >= DOOR_FROM and g < DOOR_LAST then r = nil end
        \\    local sx, sy = rd16(AT_SAMX), rd16(AT_SAMY)
        \\    local function said(c)
        \\      print(string.format("frame %d: cart %04x,%04x camera %04x,%04x pose %02x; Game Boy %04x,%04x camera %04x,%04x pose %02x",
        \\        g - 1, sx, sy, rd16(AT_CAMX), rd16(AT_CAMY), emu.read(AT_POSE, wram), r[1], r[2], r[3], r[4], r[5]))
        \\      emu.stop(c)
        \\    end
        \\    if r and (sx ~= r[1] or sy ~= r[2]) then
        \\      said(CODE_POS + ((g - 1) // PER_CODE))
        \\      return
        \\    end
        \\    -- Absolutely, since boot record version 4. This used to be a delta
        \\    -- from each side's own frame 0, because the original's camera is
        \\    -- placed by the door transition it arrived through and ours was
        \\    -- derived from the start position; `BootCamX`/`BootCamY` carry the
        \\    -- measured one now. See `firstDivergence`.
        \\    if r and (rd16(AT_CAMX) ~= r[3] or rd16(AT_CAMY) ~= r[4]) then
        \\      said(CODE_CAM + ((g - 1) // PER_CODE))
        \\      return
        \\    end
        \\    -- Last of the three, and `firstDivergence` orders them the same
        \\    -- way: a wrong pose usually moves Samus too, and the position is
        \\    -- the sharper report when it does. This catches the case where it
        \\    -- moves her nowhere at all -- the ball that finishes a bounce
        \\    -- standing on the pixel the ball would have been on.
        \\    if r and emu.read(AT_POSE, wram) ~= r[5] then
        \\      said(CODE_POSE + ((g - 1) // PER_CODE))
        \\      return
        \\    end
        \\    -- 1.0 Step 8c: the projectiles, after Samus, since a shot starts
        \\    -- from her and a wrong Samus moves it too.
        \\    local pr = r and PROJ[g]
        \\    if pr ~= nil then
        \\      for slot = 0, 2 do
        \\        for j = 1, 3 do
        \\          local got = emu.read(AT_PROJS + slot * PROJ_SIZE + PROJ_FIELDS[j], wram)
        \\          if got ~= pr[slot * 3 + j] then
        \\            local cs, gs = "", ""
        \\            for q = 0, 8 do
        \\              cs = cs .. string.format(" %02x", emu.read(AT_PROJS + (q // 3) * PROJ_SIZE + PROJ_FIELDS[q % 3 + 1], wram))
        \\              gs = gs .. string.format(" %02x", pr[q + 1])
        \\            end
        \\            print(string.format("frame %d: projectiles, cart%s; Game Boy%s", g - 1, cs, gs))
        \\            emu.stop(CODE_PROJ + ((g - 1) // PER_PROJ))
        \\            return
        \\          end
        \\        end
        \\      end
        \\    end
        \\    -- 1.0 Step 9: her health, last. A hurt moves her too, so a
        \\    -- hurt that should not have happened is a position first.
        \\    local hp = r and HEALTH[g]
        \\    if hp ~= nil and rd16(AT_HEALTH) ~= hp then
        \\      print(string.format("frame %d: health, cart %04x; Game Boy %04x", g - 1, rd16(AT_HEALTH), hp))
        \\      emu.stop(CODE_HEALTH)
        \\      return
        \\    end
        \\    -- 1.0 Step 25: and the objects on OBP1, after her health, since
        \\    -- a hurt that differs differs here too. `PutAttr` puts OBP1 in
        \\    -- palette 1, bits 3-1 of the attribute.
        \\    local o1 = r and OBP1[g]
        \\    if o1 ~= nil then
        \\      local n = 0
        \\      for at = 0, rd16(AT_OAMIDX) - 4, 4 do
        \\        if (emu.read(AT_OAM + at + 3, wram) & 0x0E) == 0x02 then n = n + 1 end
        \\      end
        \\      if n ~= o1 then
        \\        print(string.format("frame %d: objects on OBP1, cart %d; Game Boy %d", g - 1, n, o1))
        \\        emu.stop(CODE_OBP1)
        \\        return
        \\      end
        \\    end
        \\    -- `emu.stop` does not unwind the callback, so without this
        \\    -- `return` the run falls through to the pad below and its
        \\    -- `k > #KEYS` guard stops it again with 4. Every stop in
        \\    -- here returns for the same reason: the *first* verdict is the
        \\    -- one that explains the run, and the last one written wins.
        \\    -- Only found once a segment survived to its final frame.
        \\    if g >= #REF then emu.stop(0) return end
        \\  end
        \\  -- The enemy, where the Game Boy got it: before graded frame 1.
        \\  if seed ~= nil and p == N + 1 then seed() end
        \\  -- The pad for the pass after next.
        \\  if p < N then
        \\    hold = SETUP[p + 1]
        \\  else
        \\    local k = p - N + 1
        \\    if k > #KEYS then emu.stop(4) return end
        \\    hold = KEYS[k]
        \\  end
        \\end, emu.callbackType.exec, COMMIT, COMMIT, emu.cpuType.snes, emu.memType.snesMemory)
        \\
        \\emu.addEventCallback(function()
        \\  if hold ~= nil then emu.setInput(hold, 0) end
        \\end, emu.eventType.inputPolled)
        \\
        \\-- A cart that never reaches MainLoop would otherwise time out with no
        \\-- verdict, which reads as an emulator problem rather than a boot one.
        \\local watchdog = 0
        \\emu.addEventCallback(function()
        \\  watchdog = watchdog + 1
        \\  if p < 0 and watchdog > 120 then emu.stop(1) end
        \\end, emu.eventType.endFrame)
        \\
    , .{});
}

// ---- The whole pipeline ---------------------------------------------------

/// Everything one grading run produced, so `oracle_main` and `verify` can
/// share the pipeline instead of each assembling it.
/// Which oracle a report came from.
pub const Source = enum {
    /// The hand-authored segment: `segment`, on a cell `chooseStart` picked.
    segment,
    /// A published tool-assisted run, from the frame the game hands over
    /// control. See `referenceFromMovie`.
    movie,
};

pub const Report = struct {
    boot: snes_screen.Boot,
    spawned: Start,
    settled: Settled,
    /// The emulator's exit code for the honest comparison.
    code: u8,
    /// Injected faults tried, and how many were caught at the right frame.
    faults: usize = 0,
    faults_caught: usize = 0,
    /// The same, for the pose rung, counted apart from the position's so that a
    /// sweep reporting "7/7" cannot hide a pose rung that caught none of three.
    pose_faults: usize = 0,
    pose_faults_caught: usize = 0,
    /// Set when no emulator was configured; `code` is then meaningless.
    no_emulator: bool = false,
    /// Whether the two machines were standing in the same room at all. Checked
    /// before the verdict is believed: see `World`.
    world: World = .{},
    /// Tiles the cart was seeded with because the reference had shot them out.
    ///
    /// Zero for every stretch of the published runs and for every anchor in the
    /// recording's first ten thousand frames -- measured, not assumed. Nonzero
    /// means this stretch was graded against a floor the converted map does not
    /// have, which is a thing a reader should be told rather than left to infer
    /// from a boot record. See `blockSeeds`.
    seeded: usize = 0,
    /// Whether the cart was actually given them. `.pristine` is the fault run:
    /// see `Seeding`.
    seeding: Seeding = .world,
    /// Frames of reference this run compared, and the resolution its exit code
    /// can name a divergence at. The segment's are 320 and 4; the movie's are
    /// whatever it reached.
    frames: usize = segment_frames,
    per_code: usize = frames_per_code,
    /// What produced the inputs. Printed with the verdict, because "matched
    /// 320 frames" means something different for each.
    source: Source = .segment,

    // ---- Movie-only ------------------------------------------------------

    /// The movie frame this run's frame 0 came from. Zero for the segment.
    origin: u32 = 0,
    /// The first frame the movie held something the port has no key for, and
    /// what it held. A ceiling on how far the comparison means anything, and
    /// not the same claim as a divergence: see `MovieRef.first_unsupported`.
    first_unsupported: ?usize = null,
    unsupported_bits: u8 = 0,
    /// Set when the game's own starting cell is not in use at all, which stops
    /// the run before any comparison. See `snes_screen.bootFor`.
    no_boot_for_cell: bool = false,
    /// How the cart's boot cell got its tileset. `.door` means the ROM states
    /// it; anything else means `screens.assign` inferred it, and `world` is
    /// what says whether the inference held.
    provenance: screens.Provenance = .door,
    provenance_distance: u8 = 0,
    /// The candidate frame `world` was measured at, and the four numbers
    /// `windowMask` derives the comparison window from. Kept so a comparison
    /// that looked at nothing can be read rather than guessed at.
    at: u32 = 0,
    scx: u8 = 0,
    scy: u8 = 0,
    samus_x: u16 = 0,
    samus_y: u16 = 0,
    /// The first divergent frame, pinned exactly by `Bisect` rather than named
    /// as a bucket. Null when nothing diverged, when the run asked for
    /// `.bucket` resolution, or when the pin was abandoned -- see `exact_runs`.
    exact_frame: ?usize = null,
    /// Emulator runs the pin cost. **Non-zero with `exact_frame` null means the
    /// pin was abandoned**, because a truncated run answered with something
    /// other than "matched" or "diverged the same way the coarse run did", and
    /// a bisection over an answer it does not understand would be a confident
    /// wrong frame. The bucket stands in that case, which is the safe direction
    /// for a floor.
    exact_runs: usize = 0,
    /// Frames of movie the port was offered.
    offered: usize = 0,

    pub fn matched(self: Report) bool {
        return !self.no_emulator and self.code == code_ok and self.world.same();
    }

    /// Where this run stopped and what stopped it, at the best resolution it
    /// has: one frame when the bisection pinned it, the coarse bucket
    /// otherwise. Null when the run did not stop on a divergence at all.
    ///
    /// Every reporting path goes through this rather than through `decode`
    /// directly, so an exact frame cannot be printed as a bucket in one place
    /// and a frame in another.
    pub fn divergence(self: Report) ?Divergence.Span {
        const d = decode(self.code, self.per_code) orelse return null;
        if (self.exact_frame) |f| return .{ .first = f, .last = f, .what = d.what };
        // The last frame the bucket could name, clamped to the reference: the
        // final bucket is short whenever `per_code` does not divide the length,
        // and a bucket that ran off the end used to be printed as-is.
        return .{ .first = d.frame, .last = @min(d.frame + bucketWidth(d.what, self.per_code) - 1, self.offered -| 1), .what = d.what };
    }
};

/// How far ahead of the reference the cart's input schedule runs.
///
/// One frame, for the reason `MovieRef.take` sets out: the cart's engine acts
/// on a byte the frame after the script sets it, and the reference's byte is the
/// one the game acted on. Named rather than written as a literal `1` so that the
/// two places that have to agree -- the slice and the frame accounting -- cannot
/// drift apart.
pub const movie_key_lead: usize = 1;

/// The segment's counter seed, 2 below the $FF97 its reference records at frame
/// 0 (1.0 Step 7). It was 0 until then, and one of the two measurements below
/// could not tell: 0 and 2 agree on bit 0, the walk's, and bit 0 is all any
/// segment then read. The Hi-Jump segment is the first to hold A through a jump
/// start, whose rise is `$FE - ($FF97 & 2) >> 1` (00:$19E8), and it diverged on
/// the start's first rise. Measured there: the Game Boy's logic at frame g reads
/// the value recorded at frame g less one (the vblank's increment lies between
/// the two), and the cart's pass for frame g reads its seed plus g plus one
/// (`VarFramePhase` holds the plus one), so the seed is the record less two.
/// With it the segment and the spider segment still match every frame, and the
/// Hi-Jump segment matches all of its; with 2 on the movie's lead instead, the
/// movie falls from 1998 frames to 136, so the movie's stays as it is.
pub const segment_counter_lead: usize = 2;

/// What `InitState` must seed `!FrameCount` with, given the reference's $FF97
/// and how far that path shifts its keys.
///
/// The counter's phase is physics: `WalkSpeed` is `(!FrameCount & 1) + 1`, the
/// same expression the original evaluates on $FF97 at 00:$1C25. So a cart frame
/// graded against a reference frame has to take *both* its input and its
/// counter from that same reference frame -- and the two grading paths do not
/// agree on which frame that is. The movie's reference is observed, so its keys
/// are shifted by `movie_key_lead`; the segment drives both machines from one
/// supplied schedule and shifts nothing. The counter carries whichever shift
/// that path's keys carry.
///
/// Measured both ways rather than reasoned, because the reasoning has an
/// off-by-one in it whichever way you write it down: with the shifts crossed,
/// the segment falls from 124 reachable frames to 60 and the movie from 216
/// to 128. **That measured bit 0 only**, and the segment's was 2 out: see
/// `segment_counter_lead`.
pub fn frameCountSeed(counter: u8, key_lead: usize) u16 {
    return @as(u16, counter) -% @as(u16, @intCast(key_lead));
}

/// The frames a fault is injected at, all before the first honest divergence
/// this port currently has, so the sweep measures the comparator rather than
/// the port.
pub const fault_frames = [_]usize{ 8, 24, 40, 52 };

/// Where the sweep perturbs the *pose* instead of the position.
///
/// A separate list because the position faults are all inside the opening fall,
/// and a pose fault has to land where the pose is actually interesting: 337 is
/// the frame she rolls into the ball, 559 the bounce, and 593 the arc's exit --
/// the frame the morph bug got wrong. A rung that has never failed is
/// indistinguishable from one that cannot, and this rung is new.
pub const pose_fault_frames = [_]usize{ 337, 559, 593 };

/// Where the pipeline writes what it built.
pub const out_dir = "build-out";
pub const lua_name = out_dir ++ "/oracle.lua";
pub const cart_name = out_dir ++ "/oracle.sfc";

/// Take the reference, build the cart, run both, and grade.
///
/// `fault_sweep` re-runs the emulator once per entry in `fault_frames` with the
/// baked reference perturbed by one pixel at that frame. A comparator that
/// reports the perturbed frame is one that is actually comparing; the existing
/// render gate makes the same argument with the same shape, and for the same
/// reason -- a check that never fails is indistinguishable from a check that
/// cannot fail.
pub fn grade(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    mesen_path: []const u8,
    cell_limit: usize,
    fault_sweep: bool,
    resolution: Resolution,
) !Report {
    return gradeWith(allocator, io, rom, mesen_path, cell_limit, fault_sweep, resolution, &segment, .{});
}

/// What a segment is played with, and how the cart comes to hold it.
pub const Loadout = struct {
    /// OR'd into `samusItems` on the Game Boy once she has settled, before the
    /// first graded frame; the cart holds the same bits by then.
    items: u8 = 0,
    /// How the cart gets them. `.poke` writes `!Items` at the first commit
    /// (Step 14b's spider segment). `.menu` builds the `--debug` cart and sets
    /// them through the debug menu's own input (1.0 Step 7), the rule that
    /// fixtures do not force cart state.
    via: enum { poke, menu } = .poke,
    /// An engine fault: bytes written over the cart's image at a label.
    patch: ?Patch = null,
    /// 1.0 Step 8c: the beam, a `samusBeam` value. The cart sets it through
    /// the menu's beam row, which writes the weapon too; the Game Boy gets
    /// both bytes where it gets `items`. `.menu` only.
    beam: ?u8 = null,
    /// 1.0 Step 8c: an enemy in slot 0, seeded on both machines before graded
    /// frame 1. See `Enemy`.
    enemy: ?Enemy = null,
    /// 1.0 Step 8c: grade the projectile array too (`Take.projs`).
    projs: bool = false,
    /// 1.0 Step 9: grade her health too (`Take.health`).
    health: bool = false,
    /// 1.0 Step 11: start in this room rather than `chooseStart`'s.
    room: ?Room = null,
    /// 1.0 Step 27b: the segment goes through a door that warps (`Door`).
    door: bool = false,
};
pub const Patch = struct { label: []const u8, offset: usize = 0, bytes: []const u8 };

/// 1.0 Step 27b: a segment through a door. The Game Boy's reference is a
/// sample per `mainGameLoop` pass, and a door script blocks the loop (00:$239C
/// waits inside it), so the crossing is three of its samples and forty-odd of
/// the cart's passes. Play is graded frame for frame up to `from`, the first
/// sample after the `WARP`; nothing is graded after it but the reference's
/// last frame, `last`, once the cart has run every key. A segment with a door
/// holds no key after the crossing, so both machines are standing still by
/// then. A shortened reference (the bisection's) grades no frame from `from`
/// on, so a divergence only the settled frame shows is pinned there.
pub const Door = struct { from: usize, last: usize };

/// The first sample of `ref` on a screen more than one away from the last
/// one's, on either axis: a `WARP`, which no scroll does.
pub fn doorFrom(ref: []const Frame) ?usize {
    for (ref[1..], 1..) |f, i| {
        const p = ref[i - 1];
        const dx = @as(i16, @intCast(f.camera_x >> 8 & 0xF)) - @as(i16, @intCast(p.camera_x >> 8 & 0xF));
        const dy = @as(i16, @intCast(f.camera_y >> 8 & 0xF)) - @as(i16, @intCast(p.camera_y >> 8 & 0xF));
        if (@abs(dx) > 1 or @abs(dy) > 1) return i;
    }
    return null;
}

/// **An enemy to shoot at, placed by where Samus is, not by its record.** The
/// segment's room is `chooseStart`'s and holds no enemy that has loaded -- the
/// loader waits for a scroll -- so the slot is written, the lever the `enemy
/// AIs` rung pulls (`enemy_oracle.seedSlot`): the record's own 32 bytes, from
/// the room its AI lives in, with its Y and X put `dy`, `dx` from Samus's
/// pixel in the enemy's camera space. The Game Boy's seed is the one written
/// on the cart, so the two cannot disagree about where it is.
pub const Enemy = struct {
    /// Where a record with this AI is: map bank `$9`-`$F` and cell.
    bank: u8,
    cell: u8,
    ai: u16,
    dy: i16,
    dx: i16,
};

/// The pads that set `items` through the debug menu, one per frame: the
/// chord, A for SAMUS, Down to each bit's row and A, and the chord again to
/// shut it. A press is one frame and every press is followed by one frame of
/// nothing, since the menu acts on a rising edge. The rows are the menu's
/// SAMUS rows (`scenario.Row`), each found by the bit its pickup sets.
///
/// **Shut with the chord, not B at the root.** The pad the last menu pass
/// reads is what the first graded key's rising edge is taken against, and B
/// is the cart's jump: a segment opening on a jump would lose it. L, R and
/// Start are keys no segment presses.
/// The NMIs the menu's opening pass costs beyond its own: the first open
/// widens the item font into `!DebugFont` (`DebugWidenFont`), and that pass
/// runs on into a second vblank. Measured on the cart (1.0 Step 7): over a
/// nine-pass setup the counter moves ten. The script checks it every run, so
/// a menu that opens faster or slower is reported as the setup's failure
/// rather than as the segment's.
pub const menu_open_lag: usize = 1;

pub fn menuSetup(allocator: std.mem.Allocator, rom: []const u8, items: u8, beam: ?u8) ![]const []const u8 {
    const scenario = @import("scenario.zig");
    const bits = (try scenario.pickups(rom)).bits;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    const press = struct {
        fn add(a: std.mem.Allocator, o: *std.ArrayList([]const u8), keys: []const u8) !void {
            try o.append(a, keys);
            try o.append(a, "");
        }
    };
    try press.add(allocator, &out, "l = true, r = true, start = true");
    try press.add(allocator, &out, "a = true");
    var row: usize = 0;
    for (bits, 0..) |b, r| {
        if (items & b == 0) continue;
        while (row < r) : (row += 1) try press.add(allocator, &out, "down = true");
        try press.add(allocator, &out, "a = true");
    }
    var all: u8 = 0;
    for (bits) |b| all |= b;
    if (items & ~all != 0) return Error.NoMenuRow;
    // The beam row, Right through the ROM's order from the new game's beam
    // (`scenario.apply`) to the one asked for.
    if (beam) |want| {
        const p = try scenario.pickups(rom);
        const beam0 = (try scenario.Samus.newGame(rom)).beam;
        const order = [5]u8{ beam0, p.beams[0], p.beams[1], p.beams[2], p.beams[3] };
        const n = std.mem.indexOfScalar(u8, &order, want) orelse return Error.NoMenuRow;
        while (row < @intFromEnum(scenario.Row.beam)) : (row += 1) try press.add(allocator, &out, "down = true");
        for (0..n) |_| try press.add(allocator, &out, "right = true");
    }
    // The last: the chord shuts it, and that pass is still the menu's.
    try out.append(allocator, "l = true, r = true, start = true");
    return out.toOwnedSlice(allocator);
}

/// `grade` over any segment, with `loadout` held from its first frame. Step
/// 14b's spider segment and 1.0 Step 7's loadout segments are the other
/// callers; see `spider_segment` and `loadout_segments`.
pub fn gradeWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    mesen_path: []const u8,
    cell_limit: usize,
    fault_sweep: bool,
    resolution: Resolution,
    phases: []const Phase,
    loadout: Loadout,
) !Report {
    const convert = @import("snes_convert.zig");
    const items = loadout.items;
    const inject = @import("snes_inject.zig");

    const chosen = if (loadout.room) |r| try roomStart(allocator, rom, r) else try chooseStart(allocator, rom, try snes_screen.bootCandidates(allocator, rom, cell_limit));
    var boot = chosen.boot;

    const keys = try phaseKeys(allocator, phases);
    defer allocator.free(keys);
    if (loadout.beam != null and loadout.via != .menu) return Error.NoMenuRow;
    const setup: []const []const u8 = if (loadout.via == .menu) try menuSetup(allocator, rom, items, loadout.beam) else &.{};
    const setup_nmis: usize = if (setup.len == 0) 0 else setup.len + menu_open_lag;
    const settled = try referenceWith(allocator, rom, chosen.start, keys, loadout, setup_nmis);
    const pos = settled.position();
    boot.cell = settled.cell();
    boot.samus_x = pos.x;
    boot.samus_y = pos.y;
    boot.pose = start_pose;
    // Boot record version 4. The segment's start is one `room.spawn` invented,
    // but the camera the game put on it is not: `handleWarp` placed it, and
    // where it placed it is measured here rather than assumed to be on her.
    boot.cam_x = settled.frames[0].camera_x;
    boot.cam_y = settled.frames[0].camera_y;
    // Boot record version 5, and the same argument one level down: the walk's
    // speed alternates on the counter's low bit, so the counter's phase is part
    // of the port's behaviour whether or not the counter itself is compared.
    boot.frame_count = frameCountSeed(settled.frames[0].counter, segment_counter_lead);
    // Boot record version 11, which this caller never filled: the segment's
    // Game Boy is a new game (`room.bootIntoPlay`), and so is what it carries.
    // Zero health was harmless until Step 15c gave the play handler its death
    // test, and then the cart died on its first frame.
    boot.loadout = snes_screen.Loadout.newGame(rom) orelse return error.NoNewGameLoadout;

    var set = try convert.run(allocator, rom);
    defer set.deinit();
    var diag: inject.Diagnosis = .{};
    var cart = try inject.build(allocator, set, boot, &diag);
    defer cart.deinit();
    if (loadout.via == .menu) try inject.enableDebug(&cart);
    if (loadout.patch) |p| {
        const at = (inject.symbolOffset(p.label) orelse return Error.MissingSymbol) + p.offset;
        if (std.mem.eql(u8, cart.bytes[at..][0..p.bytes.len], p.bytes)) return Error.PatchNoOp;
        @memcpy(cart.bytes[at..][0..p.bytes.len], p.bytes);
    }

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "oracle.sfc", .data = cart.bytes });

    var take = Take.of(settled.frames, keys);
    const items_at: u16 = @truncate(@import("snes_inject.zig").symbol("VarItems") orelse return Error.MissingSymbol);
    const pokes = [_]Poke{.{ .addr = items_at, .value = items }};
    switch (loadout.via) {
        .poke => if (items != 0) {
            take.pokes = &pokes;
        },
        .menu => {
            take.setup = setup;
            take.setup_items = boot.loadout.items | items;
            take.setup_nmis = setup_nmis;
            take.setup_beam = loadout.beam;
        },
    }
    take.projs = loadout.projs;
    take.health = loadout.health;
    take.seed = settled.seed;
    if (loadout.door) take.door = .{
        .from = doorFrom(settled.frames) orelse return Error.NoDoor,
        .last = settled.frames.len - 1,
    };

    var rep: Report = .{
        .boot = boot,
        .spawned = chosen.start,
        .settled = settled,
        .code = code_ok,
        .frames = take.ref.len,
        .per_code = take.per_code,
        .source = .segment,
        .world = try compareWorlds(
            allocator,
            rom,
            boot,
            &settled.tiles,
            settled.scx,
            settled.scy,
            settled.placement.worldX(),
            settled.placement.worldY(),
        ),
    };

    if (mesen_path.len == 0) {
        rep.no_emulator = true;
        // Still write the script, so the cart and its grader are inspectable.
        var lua: std.Io.Writer.Allocating = .init(allocator);
        defer lua.deinit();
        try writeLua(allocator, settled, take, &lua.writer);
        try dir.writeFile(io, .{ .sub_path = "oracle.lua", .data = lua.written() });
        return rep;
    }

    rep.code = try runOne(allocator, io, dir, mesen_path, settled, take, cart_name, lua_name);
    rep.offered = take.ref.len;

    // The segment gets the same pin as the movie stretches, and for the reason
    // Step 10 is about to make pressing: its bucket is `perCode(segment_frames)`
    // frames wide, and lengthening the segment widens it. Bucket reporting here
    // was never a decision, only the absence of a second copy of this loop --
    // `pinExact` is that copy removed.
    if (resolution == .exact) {
        if (decode(rep.code, take.per_code)) |d| {
            var b: Bisect = .init(d.frame, bucketWidth(d.what, take.per_code), take.ref.len);
            rep.exact_frame = try pinExact(allocator, io, dir, mesen_path, settled, take, cart_name, lua_name, d, &b);
            rep.exact_runs = b.runs;
        }
    }

    if (fault_sweep) {
        const scratch = try allocator.dupe(Frame, settled.frames);
        defer allocator.free(scratch);
        for (fault_frames) |f| {
            @memcpy(scratch, settled.frames);
            // One pixel. A fault a comparator can only catch when it is large
            // is not much of a fault.
            scratch[f].samus_x +%= 1;
            rep.faults += 1;
            const faulted = take.over(scratch, keys);
            const code = try runOne(allocator, io, dir, mesen_path, settled, faulted, cart_name, lua_name);
            if (decode(code, take.per_code)) |d| {
                if (d.what == .position and f - d.frame < take.per_code) rep.faults_caught += 1;
            }
        }
        // The pose rung's own sweep. Perturbed by one, the same argument as the
        // pixel: the codes are dense, so $05 becoming $06 is a real pose and not
        // a value the port could never hold.
        for (pose_fault_frames) |f| {
            if (f >= scratch.len) continue;
            @memcpy(scratch, settled.frames);
            scratch[f].pose +%= 1;
            rep.pose_faults += 1;
            const faulted = take.over(scratch, keys);
            const code = try runOne(allocator, io, dir, mesen_path, settled, faulted, cart_name, lua_name);
            if (decode(code, take.per_code)) |d| {
                if (d.what == .pose and f - d.frame < take.per_code) rep.pose_faults_caught += 1;
            }
        }
        // Leave the honest script on disk rather than the last perturbed one.
        var lua: std.Io.Writer.Allocating = .init(allocator);
        defer lua.deinit();
        try writeLua(allocator, settled, take, &lua.writer);
        try dir.writeFile(io, .{ .sub_path = "oracle.lua", .data = lua.written() });
    }
    return rep;
}

/// Grade the port against a published run, from the frame the game hands over
/// control.
///
/// The same pipeline as `grade`, with the one difference that is the whole of
/// Step 15b: nothing here chooses anything. `chooseStart` does not run, no cell
/// is scored, no spawn is synthesised and no pose is forced -- the movie boots
/// the game, the game places Samus, and the cart's boot record is filled in
/// from where she ended up. Both machines therefore start from a state neither
/// of us invented, which is what makes the frame count a measurement rather
/// than a property of a fixture we wrote.
///
/// `want` frames of movie are offered. What comes back is how many of them the
/// port survived, which is F10's reachable-frame count.
/// The boot record the cart is built with when a published movie is the
/// reference: the tileset assignment for the cell the *game* left Samus in,
/// with her position and pose taken from the game rather than from us.
///
/// Split out of `gradeMovie` because `src/residue.zig` has to diff the Game
/// Boy's state at the handover against exactly this record, and a second copy
/// of these three overrides is a second place for them to drift.
pub fn movieBoot(
    allocator: std.mem.Allocator,
    rom: []const u8,
    mr: MovieRef,
) !?snes_screen.BootFor {
    const map_index = mr.map_bank - map_mod.first_bank;
    var found = (try snes_screen.bootFor(allocator, rom, map_index, mr.settled.cell())) orelse return null;
    const pos = mr.settled.position();
    found.boot.samus_x = pos.x;
    found.boot.samus_y = pos.y;
    // The pose the *game* left her in at the reference's frame 0, read out of
    // the reference rather than assumed.
    //
    // **This was `start_pose` until the re-anchor measured what that cost.**
    // The comment justifying the constant said `movie_origin_delay` exists so
    // that the pose is `stand` on both sides, and for the opening that is true:
    // the game hands control back out of pose $13 and she is standing. It is
    // true of exactly one anchor. Every other handover in the any% run is in
    // the ball ($05), a fall ($07 or $08) or a jump ($01) -- measured, all
    // eleven of them -- so booting a standing Samus against them diverged on
    // frame 0 of every stretch but the first, which is what the first anchored
    // sweep reported and what sent this line to be read again.
    //
    // The argument `reference()` makes for forcing `stand` on the *segment* is
    // the argument for reading it here: two machines that start in different
    // poses diverge for a reason that has nothing to do with physics. There the
    // pose is ours to choose and `fall` would resolve differently on the two
    // machines; here it is the game's, and taking it is what makes the two
    // sides agree. Every pose an anchor lands in is one `HandlePose` implements
    // -- and a pose it does not implement stops the stretch with `code_unhandled`
    // naming it, which is the answer that sub-task wants anyway.
    found.boot.pose = mr.settled.frames[0].pose;
    // And which way she is facing, for the same reason and measured the same
    // way. Version 6; see `engine/main.asm`'s `BootFacing`.
    found.boot.facing = mr.settled.frames[0].facing;
    // And the pad the game was acting on at the reference's frame 0.
    //
    // Our `PublishPad` runs before the poll, so `!InputPressed` at the first
    // commit is whatever `!PadHeld` held when NMI first ran -- zero on a cart
    // that boots itself. That costs the first frame of every stretch anchored
    // on a moving Samus, and the re-anchored sweep measured it: the cart ran
    // exactly one frame behind the original from frame 0 and stayed there.
    //
    // **The seed is the movie's own key at the origin frame, not `Frame.pad`.**
    // `Frame.pad` is $FF80, and seeding from it broke the one stretch that had
    // been matching -- the opening fell from 375 frames to 0. The reason is
    // that `take` has already shifted the schedule by `movie_key_lead`: cart
    // frame i acts on `keys[i - 1]`, so cart frame 0 acts on the entry the
    // shift dropped off the front, which is the unshifted key at `origin`. The
    // seed is that entry and nothing else; getting it from $FF80 double-counts
    // a shift the schedule already carries.
    found.boot.input = padWord(mr.keys[0]);
    // And the camera the opening left, which is the whole reason boot record
    // version 4 has these fields: at a handover of control the game's camera is
    // wherever its own scrolling put it, and `src/residue.zig` measured that it
    // is not on Samus. Seeding it from her -- which is what version 3 did --
    // starts every graded stretch with the view in the wrong place.
    found.boot.cam_x = mr.settled.frames[0].camera_x;
    found.boot.cam_y = mr.settled.frames[0].camera_y;
    // Version 5: the counter's phase, for the same reason and with more teeth.
    // The camera can only reach the physics a screen later; this reaches it on
    // the first frame she walks.
    found.boot.frame_count = frameCountSeed(mr.settled.frames[0].counter, movie_key_lead);
    // Version 11: what she was carrying, over the new game's numbers `bootFor`
    // left. Before this every stretch booted with zero health and no missiles.
    found.boot.loadout = mr.settled.loadout.over(found.boot.loadout);
    return found;
}

pub fn gradeMovie(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    movie: tas.Movie,
    mesen_path: []const u8,
    want: usize,
    resolution: Resolution,
) !Report {
    const convert = @import("snes_convert.zig");

    var mr = try referenceFromMovie(allocator, rom, movie, want);
    // Not `deinit`: the report below aliases `mr.settled.frames`. See
    // `MovieRef.deinitKeepingFrames`.
    defer mr.deinitKeepingFrames(allocator);

    var set = try convert.run(allocator, rom);
    defer set.deinit();

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);

    return gradeRef(allocator, io, dir, rom, set, mr, mesen_path, cart_name, lua_name, resolution, .world);
}

/// Grade one movie-anchored reference against a cart built for it.
///
/// Split out of `gradeMovie` so the anchored sweep can convert the ROM's assets
/// **once** and then build fourteen carts from the same `Set`. Conversion is
/// the expensive half and it does not depend on the boot record, so doing it
/// per anchor would have been the same waste as replaying the movie per anchor.
///
/// `cart_path` and `lua_path` are parameters rather than the module constants
/// because a sweep writing every stretch to `build-out/oracle.sfc` would leave
/// the last one there and describe it as the run; each stretch gets its own
/// pair, and the single-anchor callers pass the names they always used.
/// Whether a cart is built with the tiles the reference shot out.
///
/// `.world` is the answer for every real grading. `.pristine` is the **fault**:
/// it builds the cart from the converted map alone, which is the room before
/// anyone shot at it. A stretch that scores the same either way was not reading
/// the terrain the anchor loaded, and the seeding would be claiming itself --
/// so the sweep can be asked to run both and report the difference.
pub const Seeding = enum { world, pristine };

pub fn gradeRef(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rom: []const u8,
    set: @import("snes_convert.zig").Set,
    mr: MovieRef,
    mesen_path: []const u8,
    cart_path: []const u8,
    lua_path: []const u8,
    resolution: Resolution,
    seeding: Seeding,
) !Report {
    const inject = @import("snes_inject.zig");

    const pos = mr.settled.position();
    const cell = mr.settled.cell();
    const map_index = mr.map_bank - map_mod.first_bank;

    // Zeroed rather than `undefined`: the `no_boot_for_cell` path returns
    // before either is filled in, and a caller printing a report should not be
    // reading uninitialised memory to find that out.
    var rep: Report = .{
        .boot = .{
            .map_index = map_index,
            .cell = cell,
            .door_index = 0,
            .tiletable = 0,
            .palette = @splat(0),
            .obj_palette = @splat(0),
            .samus_x = pos.x,
            .samus_y = pos.y,
            .cam_x = mr.settled.frames[0].camera_x,
            .cam_y = mr.settled.frames[0].camera_y,
            .frame_count = frameCountSeed(mr.settled.frames[0].counter, movie_key_lead),
        },
        .spawned = .{ .map_index = map_index, .cell = cell, .pixel_x = 0, .pixel_y = 0 },
        .settled = mr.settled,
        .code = code_ok,
        // The take, not the reference: `movie_key_lead` drops the last frame,
        // because there is no frame after it to take an input from. Reporting
        // the reference's length would claim a frame that was never graded.
        .frames = mr.take().ref.len,
        .per_code = perCode(mr.take().ref.len),
        .source = .movie,
        .origin = mr.origin,
        .offered = mr.take().ref.len,
        .first_unsupported = mr.first_unsupported,
        .unsupported_bits = mr.unsupported_bits,
    };

    // A map bank outside the map's range is not a room at all -- it is what
    // `$D811` holds while the game is somewhere that has no map, and an anchor
    // there has nothing to boot into. Checked before the subtraction above can
    // be trusted, because `map_index` wraps otherwise.
    if (mr.map_bank < map_mod.first_bank or map_index >= map_mod.bank_count) {
        rep.no_boot_for_cell = true;
        return rep;
    }

    const found = (try movieBoot(allocator, rom, mr)) orelse {
        rep.no_boot_for_cell = true;
        return rep;
    };
    rep.provenance = found.provenance;
    rep.provenance_distance = found.distance;
    var boot = found.boot;
    rep.boot = boot;
    // Not a spawn: nothing was poked. This is where the *game* put her, in the
    // shape the segment's report uses so the two can be printed the same way.
    rep.spawned = .{
        .map_index = map_index,
        .cell = cell,
        .pixel_x = mr.settled.placement.pixel_x,
        .pixel_y = mr.settled.placement.pixel_y,
        .door_index = boot.door_index,
    };

    // **The world before the cart, because the cart is built with it.** An
    // anchor taken after the reference shot her way down is standing in a room
    // whose floor the converted map still has, and a cart built from the map
    // alone would be graded against a floor that is not there -- a divergence
    // that reads as a physics bug and is a missing hole. See `blockSeeds`.
    var seeds: [inject.boot_world_max]snes_screen.WorldSeed = undefined;
    const n = blockSeeds(
        allocator,
        rom,
        boot,
        &mr.settled.tiles,
        mr.settled.scx,
        mr.settled.scy,
        mr.settled.placement.worldX(),
        mr.settled.placement.worldY(),
        &seeds,
    ) catch |err| switch (err) {
        // More holes than the record holds. Refused rather than half-seeded: a
        // cart with some of the floor missing grades as a port bug.
        Error.TooManyBlocks => {
            rep.no_boot_for_cell = true;
            return rep;
        },
        else => return err,
    };
    // `.pristine` counts what the anchor *needed* and hands the cart none of
    // it: the report still says how damaged the room was, and the cart is
    // built for the room before anyone shot at it.
    boot.world = if (seeding == .world) seeds[0..n] else &.{};
    rep.boot = boot;
    // **Not the slice.** `seeds` is this frame's stack and `rep` outlives it,
    // so a report carrying the list would carry a dangling one -- `rep.seeded`
    // is the count, and the tiles themselves are in the cart that was built.
    rep.boot.world = &.{};
    rep.seeded = n;
    rep.seeding = seeding;

    var diag: inject.Diagnosis = .{};
    var cart = try inject.build(allocator, set, boot, &diag);
    defer cart.deinit();
    try dir.writeFile(io, .{ .sub_path = std.fs.path.basename(cart_path), .data = cart.bytes });

    rep.world = try compareWorlds(
        allocator,
        rom,
        boot,
        &mr.settled.tiles,
        mr.settled.scx,
        mr.settled.scy,
        mr.settled.placement.worldX(),
        mr.settled.placement.worldY(),
    );

    const take = mr.take();
    if (mesen_path.len == 0) {
        rep.no_emulator = true;
        var lua: std.Io.Writer.Allocating = .init(allocator);
        defer lua.deinit();
        try writeLua(allocator, mr.settled, take, &lua.writer);
        try dir.writeFile(io, .{ .sub_path = std.fs.path.basename(lua_path), .data = lua.written() });
        return rep;
    }

    rep.code = try runOne(allocator, io, dir, mesen_path, mr.settled, take, cart_path, lua_path);

    // Resolve the bucket to the frame. Only ever runs when there is a
    // divergence to pin, and costs `ceil(log2(per_code))` runs when it does.
    // See `Bisect` for why truncating the reference is a sound way to ask.
    if (resolution == .exact) {
        if (decode(rep.code, take.per_code)) |d| {
            var b: Bisect = .init(d.frame, bucketWidth(d.what, take.per_code), take.ref.len);
            rep.exact_frame = try pinExact(allocator, io, dir, mesen_path, mr.settled, take, cart_path, lua_path, d, &b);
            rep.exact_runs = b.runs;
        }
    }
    return rep;
}

/// How far the port got on one graded stretch.
///
/// Lifted out of `verify.zig`, where it was the only copy, because the anchored
/// sweep has to compute the same number and two implementations of "how many
/// frames did it reach" is exactly the kind of thing that drifts and is then
/// argued about rather than measured.
///
/// `matched()` means the port survived everything it was offered, so the count
/// is the whole take. Otherwise it is the first divergent frame: exact when the
/// run pinned one, and the bottom edge of the divergence bucket when it did not
/// -- pessimistic by up to `per_code - 1`, which is the safe direction for a
/// floor. An unhandled pose carries the pose in its code and so cannot also
/// carry a frame; that comes back null rather than as a zero, because zero
/// would read as a catastrophic regression when it is really a missing answer.
///
/// **The exact frame is what makes the anchored sum a sum of frames.** Adding
/// thirteen bucket edges understates by up to thirteen times `per_code - 1`,
/// and that error moves whenever a stretch's length moves -- which is why
/// `anchored_gate_floor` had to be re-measured twice for reasons that were not
/// the port.
pub fn reachedFrames(rep: Report) ?usize {
    if (rep.no_emulator or rep.no_boot_for_cell or !rep.world.same()) return null;
    if (unhandledPose(rep.code) != null) return null;
    if (rep.matched()) return rep.offered;
    if (rep.divergence()) |d| return d.first;
    return 0;
}

/// One anchored stretch of the movie and what the port did with it.
pub const Stretch = struct {
    anchor: Anchor,
    /// Null when the replay never settled at this anchor, so nothing was built
    /// and nothing was graded. Distinct from a stretch that was graded and
    /// reached zero frames.
    rep: ?Report = null,
    /// The schedule the cart was driven with, in the port's key vocabulary and
    /// already phase-shifted by `movie_key_lead`. Kept because `zig build trace`
    /// has to drive the same cart with the same inputs to answer *why* a
    /// stretch stopped, and re-deriving it there would be a second copy of the
    /// shift.
    keys: []const Key = &.{},
    /// Where this stretch's cart and script were written, so a stop can be
    /// reproduced by hand against the exact pair that produced it.
    cart_path: []const u8 = "",
    lua_path: []const u8 = "",
    /// The same stretch graded against a cart built from the map alone -- the
    /// room before the reference shot at it. Only ever set when the honest run
    /// was seeded and the fault was asked for; see `Seeding`.
    ///
    /// **It is the fixture, not a diagnostic.** If a seeded stretch reaches the
    /// same frame either way, the comparison is not reading the terrain the
    /// anchor loaded, and the seeding was an assertion about itself.
    fault: ?Report = null,
    fault_cart_path: []const u8 = "",

    /// Frames matched, or null when the stretch produced no number. See
    /// `reachedFrames`; a stretch with no reference is one of those cases.
    pub fn reached(self: Stretch) ?usize {
        const r = self.rep orelse return null;
        return reachedFrames(r);
    }

    /// Why this stretch produced no frame count, in the words a report prints.
    pub fn withheld(self: Stretch) ?[]const u8 {
        if (!self.anchor.settled) return "no frame this room can be booted at: the transition never settles";
        if (self.anchor.frames == 0) return "empty: the next anchor settled past this stretch's end";
        const r = self.rep orelse return "no reference: the replay never settled at this anchor";
        if (r.no_emulator) return "no emulator";
        if (r.no_boot_for_cell) return "the anchor's cell is not one the cart can boot into";
        if (!r.world.same()) return "the reference and the cart are not in the same room";
        if (unhandledPose(r.code) != null) return "a pose the port has no handler for";
        return null;
    }
};

/// **The seeding fixture's pins (1.0 Step 18c2).** `oracle -- recorded 10000
/// 2000 8 fault` grades every seeded stretch again on a cart given none of
/// the tiles the reference had shot out. Until 18c it could not be booted
/// into; at `13a4736` 17 of its 26 stretches are seeded and four lose frames
/// without the seeding.
///
/// It passes when **at least one** does, as every other fault does: a
/// stretch that ends before it reaches a seeded block plays the same either
/// way, and asking all of them to lose frames asked the impossible. What
/// stops that leniency from hiding drift is the pins. Every anchor in
/// `seeding_catches` must still catch, and the seeded stretches together
/// must still play `seeding_frames_floor` frames. A loss fails and names the
/// anchor; a gain prints "raise the pin". **An accepted loss lowers the pin
/// in its own commit, with a row in `docs/porting_loop.md`'s turn log.**
pub const seeding_catches = [_]u32{ 10327, 10390, 10832, 11567 };
pub const seeding_frames_floor: usize = 168;

/// One seeded stretch: its anchor, the frames it plays seeded, and the frames
/// it plays on the pristine cart (null when that cart could not be graded,
/// which is the seeding mattering at its loudest).
pub const SeedRow = struct { anchor: u32, with: usize, without: ?usize };

pub fn seedCaught(r: SeedRow) bool {
    const w = r.without orelse return true;
    return w < r.with;
}

pub const SeedingVerdict = struct {
    run: usize = 0,
    caught: usize = 0,
    frames: usize = 0,
    floor: usize = 0,
    /// Pinned anchors that no longer catch, or are no longer seeded at all.
    lost: [16]u32 = undefined,
    n_lost: usize = 0,
    /// Anchors that catch and are not pinned.
    gained: [16]u32 = undefined,
    n_gained: usize = 0,

    pub fn ok(self: SeedingVerdict) bool {
        return self.caught >= 1 and self.n_lost == 0 and self.frames >= self.floor;
    }

    /// Something beat a pin: the pins should be raised to it.
    pub fn raise(self: SeedingVerdict) bool {
        return self.n_gained != 0 or self.frames > self.floor;
    }
};

pub fn gradeSeeding(rows: []const SeedRow, catches: []const u32, floor: usize) SeedingVerdict {
    var v: SeedingVerdict = .{ .run = rows.len, .floor = floor };
    for (rows) |r| {
        v.frames += r.with;
        if (!seedCaught(r)) continue;
        v.caught += 1;
        if (std.mem.indexOfScalar(u32, catches, r.anchor) == null and v.n_gained < v.gained.len) {
            v.gained[v.n_gained] = r.anchor;
            v.n_gained += 1;
        }
    }
    for (catches) |a| {
        const held = for (rows) |r| {
            if (r.anchor == a) break seedCaught(r);
        } else false;
        if (!held and v.n_lost < v.lost.len) {
            v.lost[v.n_lost] = a;
            v.n_lost += 1;
        }
    }
    return v;
}

/// **The recording's worlds pin (1.0 Step 18c2).** `gbtrace -- <recording>
/// set worlds` reads, at the middle of each visit, the tiles Mesen's Game Boy
/// shows, against the table the port draws the cell with. At 18c the walked
/// reading explains 599 of 953 visits; the rest are listed, one per line, in
/// `worlds_misses.txt`, so a miss can be named. A visit that misses and is not
/// listed fails the run; a listed one now explained, or gone, prints "raise
/// the pin". **An accepted new miss is added in its own commit, with a row in
/// `docs/porting_loop.md`'s turn log.**
pub const world_misses_pin = @embedFile("worlds_misses.txt");

/// A visit, as `set worlds` takes one: a cell, once per Metroid count.
pub const Visit = packed struct { bank: u8, cell: u8, count: u8 };

pub const WorldsVerdict = struct {
    pinned: usize = 0,
    misses: usize = 0,
    /// Misses the pin does not list.
    lost: []const Visit = &.{},
    /// Listed misses the run explained, or did not visit.
    gained: []const Visit = &.{},

    pub fn ok(self: WorldsVerdict) bool {
        return self.lost.len == 0;
    }

    pub fn raise(self: WorldsVerdict) bool {
        return self.gained.len != 0;
    }
};

/// The pin's lines: `<bank> <cell> <count>` in hex, `#` to the end of a line
/// a comment.
pub fn parseWorldPin(allocator: std.mem.Allocator, text: []const u8) ![]Visit {
    var out: std.ArrayList(Visit) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        try out.append(allocator, .{
            .bank = try std.fmt.parseInt(u8, f.next() orelse return error.BadPin, 16),
            .cell = try std.fmt.parseInt(u8, f.next() orelse return error.BadPin, 16),
            .count = try std.fmt.parseInt(u8, f.next() orelse return error.BadPin, 16),
        });
        if (f.next() != null) return error.BadPin;
    }
    return out.toOwnedSlice(allocator);
}

pub fn gradeWorlds(allocator: std.mem.Allocator, misses: []const Visit, pin: []const Visit) !WorldsVerdict {
    var lost: std.ArrayList(Visit) = .empty;
    var gained: std.ArrayList(Visit) = .empty;
    for (misses) |m| if (std.mem.indexOfScalar(Visit, pin, m) == null) try lost.append(allocator, m);
    for (pin) |p| if (std.mem.indexOfScalar(Visit, misses, p) == null) try gained.append(allocator, p);
    return .{
        .pinned = pin.len,
        .misses = misses.len,
        .lost = try lost.toOwnedSlice(allocator),
        .gained = try gained.toOwnedSlice(allocator),
    };
}

/// The whole re-anchored comparison: every playable stretch of the movie, each
/// graded frame-exactly from its own boot record, and the sum.
pub const Anchored = struct {
    stretches: []Stretch,
    /// The frame past which the replay is no longer the published run.
    horizon: u32,
    /// The stillness threshold the anchors were found at.
    min: u32,
    /// What the settle search found at each handover, in the anchors' order.
    ///
    /// **Kept rather than discarded, because an unsettled anchor is the most
    /// expensive thing a sweep can report and the least explained.** The
    /// stretch table says "no frame this room can be booted at"; this says how
    /// many tiles were compared, how many agreed, how many were blocks, and
    /// which tileset would have explained what the Game Boy was showing --
    /// which is the difference between "the wrong room" and "the right room
    /// drawn from the wrong table".
    settling: []Settling = &.{},

    /// Frames matched across every stretch that produced a number.
    pub fn reached(self: Anchored) usize {
        var n: usize = 0;
        for (self.stretches) |st| n += st.reached() orelse 0;
        return n;
    }

    /// Frames offered across those same stretches. Stretches that produced no
    /// number are left out of both, so the ratio means something.
    pub fn offered(self: Anchored) usize {
        var n: usize = 0;
        for (self.stretches) |st| {
            if (st.reached() == null) continue;
            n += (st.rep orelse continue).offered;
        }
        return n;
    }

    /// Stretches that were graded and produced a frame count.
    pub fn graded(self: Anchored) usize {
        var n: usize = 0;
        for (self.stretches) |st| n += @intFromBool(st.reached() != null);
        return n;
    }

    /// Stretches whose cart was given tiles the map does not have, and how many
    /// tiles in total. Zero for both published runs and for the recording's
    /// first ten thousand frames.
    pub fn seededStretches(self: Anchored) usize {
        var n: usize = 0;
        for (self.stretches) |st| {
            const r = st.rep orelse continue;
            n += @intFromBool(r.seeded > 0);
        }
        return n;
    }

    pub fn seededTiles(self: Anchored) usize {
        var n: usize = 0;
        for (self.stretches) |st| n += (st.rep orelse continue).seeded;
        return n;
    }

    /// Of the seeded stretches the fault was run on, how many got *worse*
    /// without the seeding -- which is the fixture passing.
    ///
    /// A seeded stretch that scores the same pristine is the fixture failing,
    /// and `faultsRun` is what says how many were asked, so "0 of 0" cannot be
    /// mistaken for "0 of 4".
    pub fn faultsRun(self: Anchored) usize {
        var n: usize = 0;
        for (self.stretches) |st| n += @intFromBool(st.fault != null);
        return n;
    }

    pub fn faultsCaught(self: Anchored) usize {
        var n: usize = 0;
        for (self.stretches) |st| {
            const f = st.fault orelse continue;
            const honest = st.reached() orelse continue;
            const broken = reachedFrames(f) orelse {
                // The pristine cart could not be graded at all -- most often
                // because the room comparison now refuses it. That is the
                // seeding mattering, in the loudest possible way.
                n += 1;
                continue;
            };
            n += @intFromBool(broken < honest);
        }
        return n;
    }

    /// Each seeded stretch the fault was run on, for `gradeSeeding`.
    pub fn seedRows(self: Anchored, allocator: std.mem.Allocator) ![]SeedRow {
        var out: std.ArrayList(SeedRow) = .empty;
        errdefer out.deinit(allocator);
        for (self.stretches) |st| {
            const f = st.fault orelse continue;
            try out.append(allocator, .{
                .anchor = st.anchor.origin,
                .with = st.reached() orelse 0,
                .without = reachedFrames(f),
            });
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *Anchored, allocator: std.mem.Allocator) void {
        allocator.free(self.settling);
        for (self.stretches) |st| {
            allocator.free(st.keys);
            allocator.free(st.cart_path);
            allocator.free(st.lua_path);
            allocator.free(st.fault_cart_path);
            // `fault` aliases the same reference frames as `rep`; only one of
            // the two owns them.
            const r = st.rep orelse continue;
            allocator.free(r.settled.frames);
        }
        allocator.free(self.stretches);
        self.stretches = &.{};
    }
};

/// How far past a handover a settled anchor may be looked for.
///
/// A room change on the Game Boy is not one frame. The warp handler draws three
/// metatile columns of the thirty-two the window holds (0:$07E4) and leaves the
/// rest to the scroll-edge routines, so for a while after the handover the
/// background map is mostly the room she *left*. An anchor placed in that window
/// builds the cart for one room and grades it against a picture of two.
///
/// A hundred and twenty frames is two seconds, which is longer than any
/// transition measured on either published run and short enough that a stretch
/// with no settled frame in it is reported as such rather than searched for
/// indefinitely.
pub const settle_search: u32 = 120;

/// How many candidate frames a Mesen-backed settle asks for at a time.
///
/// **Measured, not chosen for roundness.** One pass holds fifteen snapshots and
/// costs a full replay, so the whole 120-frame search for three anchors was 24
/// passes on the recording's first 900 frames. Eight is one pass for up to
/// fifteen anchor-rounds and covers the great majority of handovers, which
/// settle within a few frames; an anchor that needs more simply takes another
/// round rather than being reported unsettled. See `RefSource.settle_round`.
pub const settle_round_trace: u32 = 8;

/// What `settleAnchors` found at one handover.
pub const Settling = struct {
    handover: u32,
    /// The first frame at or after the handover whose room the cart can be
    /// built for and whose world the cart's reproduces, or null if none inside
    /// `settle_search`.
    origin: ?u32,
    /// The world comparison at `origin`, or the best one seen if none matched.
    world: World,
    /// Whether any candidate frame produced a boot record at all, and the cell
    /// it was for.
    ///
    /// These separate two failures that printed identically and are not the
    /// same problem. `had_boot = false` means `snes_screen.bootFor` found
    /// nothing for the cell the game left Samus in -- the cell is not in use in
    /// our map data, so there was never anything to compare. `had_boot = true`
    /// with a short `world` means a cart *was* built and its picture disagreed,
    /// which is a tileset-assignment question and is answered by
    /// `world.gb_best_table`.
    had_boot: bool = false,
    map_index: u8 = 0,
    cell: u8 = 0,
    /// How the cell got the tileset the cart booted with. `.door` means the ROM
    /// states it, so a disagreement is our reading of the door; anything else
    /// means `screens.assign` inferred it, so a disagreement is the inference.
    provenance: screens.Provenance = .door,
    provenance_distance: u8 = 0,
    /// The candidate frame `world` was measured at, and the four numbers
    /// `windowMask` derives the comparison window from. Kept so a comparison
    /// that looked at nothing can be read rather than guessed at.
    at: u32 = 0,
    scx: u8 = 0,
    scy: u8 = 0,
    samus_x: u16 = 0,
    samus_y: u16 = 0,

    /// Frames from the handover to `origin`. The Game Boy's own duration for
    /// the transition, measured whether or not the port has one to compare.
    pub fn frames(self: Settling) ?u32 {
        const o = self.origin orelse return null;
        return o - self.handover;
    }
};

/// For each handover, find the first frame from which a cart can honestly be
/// built: same room on both machines, and the same picture of it.
///
/// **Why this is not `handover + 1`.** The first anchored sweep pushed each
/// anchor one frame, far enough that the cell index agreed, and eight of the
/// thirteen stretches then reported that the two machines were not in the same
/// room after all. The cell was right and the tilemap was not: a warp draws
/// three columns and the scrolling draws the other twenty-nine over the frames
/// that follow, so "she is in cell $43" becomes true long before "the window
/// shows cell $43" does.
///
/// The criterion is the one the gate already refuses to grade without --
/// `compareWorlds` agreeing on every compared tile -- so this cannot pick an
/// anchor the comparison would then reject. One replay serves every candidate.
pub fn settleAnchors(
    allocator: std.mem.Allocator,
    rom: []const u8,
    movie: tas.Movie,
    anchors: []const Anchor,
    track: tas.Track,
    horizon: u32,
) ![]Settling {
    var src: MovieSource = .{ .rom = rom, .movie = movie };
    return settleAnchorsFrom(allocator, rom, src.source(), anchors, track, horizon);
}

/// The same search, against whichever producer of references the caller has.
///
/// Split out when the recording arrived: its references come off Mesen and not
/// off a replay, and a settle that could only replay would stop where the
/// replay does -- at 28 796 frames of a 76 950-frame run. See `RefSource`.
pub fn settleAnchorsFrom(
    allocator: std.mem.Allocator,
    rom: []const u8,
    source: RefSource,
    anchors: []const Anchor,
    track: tas.Track,
    horizon: u32,
) ![]Settling {
    // One slot per candidate frame of every anchor, all taken from a single
    // replay. `frames = 1` because only the settled snapshot is wanted.
    //
    // The search starts at the anchor's already-pushed `origin`, not at its
    // `handover`, and every candidate has to keep the invariant that push
    // established: a boot record is taken from the frame before the reference's
    // frame 0, so those two frames must be in the same room. Searching from the
    // handover instead was this function's first bug -- it compared the world at
    // `origin - 1` against a cart built for `origin - 1`, which is true by
    // construction, and duly reported that every transition settles in zero
    // frames while the sweep it was meant to explain reported eight of thirteen
    // stretches in the wrong room.
    const out = try allocator.alloc(Settling, anchors.len);
    errdefer allocator.free(out);
    for (out, anchors) |*o, a| o.* = .{ .handover = a.handover, .origin = null, .world = .{} };
    if (anchors.len == 0) return out;

    var cands: std.ArrayList(Anchor) = .empty;
    defer cands.deinit(allocator);

    // **In rounds, and how big a round is belongs to the source.** A replay
    // serves every candidate out of one run, so `MovieSource` asks for all
    // `settle_search` of them at once and this loop runs exactly once, as it
    // always did. A Mesen pass costs a replay and holds fifteen snapshots, so
    // `TraceSource` asks for a few at a time and stops asking about an anchor
    // the moment it settles -- which most do within a handful of frames of the
    // handover.
    var round: u32 = 0;
    while (round < settle_search) : (round += source.settle_round) {
        cands.clearRetainingCapacity();
        for (anchors, out) |a, o| {
            if (o.origin != null) continue;
            var f = a.origin + round;
            const stop = @min(@min(a.origin + settle_search, a.origin + round + source.settle_round), horizon);
            while (f < stop) : (f += 1) {
                if (f == 0) continue;
                // `indexOf`, not `samples[f]`. A replay's frame n is its index
                // n and a Mesen window's is not -- it starts wherever it was
                // asked to -- so subtracting would settle against the wrong
                // frames without ever saying so.
                const before = track.indexOf(f - 1) orelse continue;
                const at = track.indexOf(f) orelse continue;
                if (!tas.Room.of(track.samples[before]).eql(tas.Room.of(track.samples[at]))) continue;
                if (track.samples[before].pose != track.samples[at].pose) continue;
                try cands.append(allocator, .{ .origin = f, .frames = 1, .handover = a.handover });
            }
        }
        if (cands.items.len == 0) continue;
        try settleRound(allocator, rom, source, cands.items, out);
    }
    return out;
}

/// One round of candidates, graded into the settlings they belong to.
///
/// Split out of `settleAnchorsFrom` when the search became incremental: the
/// body is what it always was, and the only new thing is that it can be called
/// more than once. `out` is updated in place, and an anchor that has already
/// settled is left alone -- rounds after the first never see it again anyway.
fn settleRound(
    allocator: std.mem.Allocator,
    rom: []const u8,
    source: RefSource,
    cands: []const Anchor,
    out: []Settling,
) !void {
    const refs = try source.references(allocator, cands);
    defer {
        for (refs) |maybe| {
            var mr = maybe orelse continue;
            mr.deinit(allocator);
        }
        allocator.free(refs);
    }

    for (refs, cands) |maybe, cand| {
        const mr = maybe orelse continue;
        const slot = for (out, 0..) |o, k| {
            if (o.handover == cand.handover) break k;
        } else continue;
        if (out[slot].origin != null) continue;

        const map_index = mr.map_bank -% map_mod.first_bank;
        if (mr.map_bank < map_mod.first_bank or map_index >= map_mod.bank_count) continue;
        const found = (try movieBoot(allocator, rom, mr)) orelse continue;
        if (!out[slot].had_boot) {
            out[slot].had_boot = true;
            out[slot].map_index = found.boot.map_index;
            out[slot].cell = found.boot.cell;
            out[slot].provenance = found.provenance;
            out[slot].provenance_distance = found.distance;
        }
        const w = try compareWorlds(
            allocator,
            rom,
            found.boot,
            &mr.settled.tiles,
            mr.settled.scx,
            mr.settled.scy,
            mr.settled.placement.worldX(),
            mr.settled.placement.worldY(),
        );
        // Keep the most informative comparison, not the one with the most
        // matches: a window that overlaps the cell by nothing at all matches
        // zero tiles and so could never replace the zero-initialised default,
        // which is why anchors 11 and 12 reported `cart table 0` -- the
        // default's field, printed as though the assignment had said it.
        if (w.compared > out[slot].world.compared or
            (w.compared == out[slot].world.compared and w.matched > out[slot].world.matched))
        {
            out[slot].world = w;
            out[slot].at = cand.origin;
            out[slot].scx = mr.settled.scx;
            out[slot].scy = mr.settled.scy;
            out[slot].samus_x = mr.settled.placement.worldX();
            out[slot].samus_y = mr.settled.placement.worldY();
        }
        if (w.same()) {
            out[slot].origin = cand.origin;
            out[slot].world = w;
        }
    }
}

/// How long a warped-into room has to have been the same before its picture is
/// trusted.
///
/// A warp draws three columns and the scrolling draws the other twenty-nine
/// over the frames that follow, which is the measurement `settleAnchors` was
/// written for: eight of thirteen stretches reported the wrong room because the
/// cell index agreed long before the window did. The sweep has the same problem
/// and cannot use the same answer -- `settleAnchors` searches for a frame where
/// the two machines *agree*, and agreement is exactly what the sweep is asking
/// about, so using it here would only ever confirm the assignment. A fixed
/// wait, longer than any transition the run measures (the longest is 46
/// frames), is the honest substitute.
pub const sweep_warp_settle: u32 = 60;

/// And how long a scrolled-into room has to, which is far less.
///
/// Walking into the next cell does not redraw the screen: the scrolling draws
/// each column as it comes on, so the part of the new cell that is on screen is
/// the part that has already been drawn -- and the window mask counts only
/// tiles that are both on screen and inside the cell. The wait here is for the
/// scroll registers to be consistent with her position rather than for the
/// picture.
pub const sweep_scroll_settle: u32 = 8;

/// How many separate visits to one cell the sweep grades.
///
/// More than one because a visit can settle somewhere the window barely
/// overlaps the cell, and few because each costs a capture slot in the one
/// replay that serves all of them.
const sweep_visits_per_cell: usize = 3;

/// One cell of the map, graded against the tiles a running Game Boy showed.
pub const CellWorld = struct {
    map_index: u8,
    cell: u8,
    /// The movie frame the tiles were taken at, and which published run reached
    /// it. Both so a disagreement can be looked at rather than believed.
    frame: u32,
    movie: []const u8,
    provenance: screens.Provenance,
    distance: u8,
    world: World,

    /// Another table explains strictly more of the same window than the one the
    /// assignment chose.
    ///
    /// Strictly more, not "not all": a cell whose window the assigned table
    /// explains imperfectly and no other table explains better is a fact about
    /// the comparison -- a sprite in the tilemap, a window that straddles a
    /// cell edge -- and not evidence against the assignment.
    pub fn disagrees(self: CellWorld) bool {
        return self.world.compared > 0 and self.world.gb_best_matched > self.world.matched;
    }

    pub fn agrees(self: CellWorld) bool {
        return self.world.compared > 0 and self.world.same();
    }
};

/// Two grid cells share an edge, on the 16x16 grid a cell index encodes.
fn adjacent(a: u8, b: u8) bool {
    const ax: i16 = a & 0x0F;
    const ay: i16 = a >> 4;
    const bx: i16 = b & 0x0F;
    const by: i16 = b >> 4;
    const dx = @abs(ax - bx);
    const dy = @abs(ay - by);
    return dx + dy == 1;
}

/// Grade `screens.assign`'s tileset choice for every cell a published run
/// stands still in, against the tiles the Game Boy was actually showing.
///
/// **This is the only check that can see the assignment at all.** The render
/// rung converts a screen and renders both sides *through the same chosen
/// table*, so it is blind to the choice by construction -- it would pass just
/// as cleanly with every cell assigned the wrong table. Reading the tilemap out
/// of a running emulator is the one comparison where the table is an input on
/// one side and an observation on the other, and until now it ran at thirteen
/// anchors.
///
/// One replay serves every cell, the way `settleAnchors` does it.
pub fn sweepWorlds(
    allocator: std.mem.Allocator,
    rom: []const u8,
    movie: tas.Movie,
    label: []const u8,
    samples: []const tas.Sample,
    horizon: u32,
) ![]CellWorld {
    var cands: std.ArrayList(Anchor) = .empty;
    defer cands.deinit(allocator);

    var visits: std.AutoHashMapUnmanaged(u16, usize) = .empty;
    defer visits.deinit(allocator);

    // Visits first, then one frame chosen out of each, because how long a
    // visit lasts decides which frame of it can be trusted -- and that is only
    // known once it has ended.
    const end = @min(horizon, @as(u32, @intCast(samples.len)));
    var start: u32 = 1;
    var f: u32 = 1;
    while (f <= end) : (f += 1) {
        const same = f < end and tas.Room.of(samples[f - 1]).eql(tas.Room.of(samples[f]));
        if (same) continue;

        const here = tas.Room.of(samples[start]);
        const before = tas.Room.of(samples[start - 1]);
        // Walked in, or put there. A cell reached by walking is adjacent to the
        // one before it in the same bank; anything else is a warp, whichever
        // opcode did it.
        const walked = before.map_bank == here.map_bank and adjacent(before.cell, here.cell);
        const wait: u32 = if (walked) sweep_scroll_settle else sweep_warp_settle;
        defer start = f;
        if (f - start <= wait) continue;

        // The middle of the visit, but never before the wait is up. The middle
        // because that is where she is furthest from the cell's edges, and the
        // window mask counts only tiles inside the cell -- sampling just after
        // arriving grades a third of a screen and calls it a cell.
        const at = @min(f - 1, @max(start + wait, start + (f - start) / 2));
        const cell_key = (@as(u16, here.map_bank) << 8) | here.cell;
        const gop = try visits.getOrPut(allocator, cell_key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        if (gop.value_ptr.* >= sweep_visits_per_cell) continue;
        gop.value_ptr.* += 1;
        try cands.append(allocator, .{ .origin = at, .frames = 1, .handover = at });
    }
    if (cands.items.len == 0) return allocator.alloc(CellWorld, 0);

    const refs = try referencesFromMovie(allocator, rom, movie, cands.items);
    defer {
        for (refs) |maybe| {
            var mr = maybe orelse continue;
            mr.deinit(allocator);
        }
        allocator.free(refs);
    }

    // Once, not per cell: `snes_screen.bootFor` re-parses six map banks and
    // re-decodes the door region on every call, which is affordable thirteen
    // times and not eight hundred.
    // The reading the port boots a cell with (`snes_screen.bootFor`): the
    // crawl's where it walked, the static one elsewhere (1.0 Step 18c).
    const walked = try warp.loadWalked(allocator, rom);
    defer allocator.free(walked);
    var assignment = try warp.assignWalked(allocator, rom, walked);
    defer assignment.deinit(allocator);

    var out: std.ArrayList(CellWorld) = .empty;
    errdefer out.deinit(allocator);

    for (refs) |maybe| {
        const mr = maybe orelse continue;
        if (mr.map_bank < map_mod.first_bank) continue;
        const map_index = mr.map_bank -% map_mod.first_bank;
        if (map_index >= map_mod.bank_count) continue;
        const cell = mr.settled.cell();

        const choice = for (assignment.cells) |c| {
            if (c.bank != mr.map_bank) continue;
            const at: u8 = @as(u8, c.y) * @as(u8, map_mod.grid_w) + c.x;
            if (at != cell) continue;
            break c.choice;
        } else null;
        // A cell in use with no choice at all is a hole in the assignment
        // rather than a wrong answer, and `assign` reports those itself.
        const chosen = (choice orelse null) orelse continue;

        const w = try compareCell(
            allocator,
            rom,
            map_index,
            cell,
            chosen.tiletable,
            &mr.settled.tiles,
            mr.settled.scx,
            mr.settled.scy,
            mr.settled.placement.worldX(),
            mr.settled.placement.worldY(),
        );
        const row: CellWorld = .{
            .map_index = map_index,
            .cell = cell,
            .frame = mr.origin,
            .movie = label,
            .provenance = chosen.provenance,
            .distance = chosen.distance,
            .world = w,
        };

        // One row per cell: the visit that saw the most of it wins, because a
        // window that overlaps the cell by two columns can agree perfectly and
        // say almost nothing.
        const slot = for (out.items, 0..) |o, i| {
            if (o.map_index == map_index and o.cell == cell) break i;
        } else null;
        if (slot) |i| {
            const old = out.items[i].world;
            if (w.compared > old.compared or (w.compared == old.compared and w.matched > old.matched)) {
                out.items[i] = row;
            }
        } else try out.append(allocator, row);
    }

    return out.toOwnedSlice(allocator);
}

/// Grade every playable stretch of a published run, not just the first.
///
/// **What this buys, and it is the whole point of the re-anchor.** A single
/// anchor caps the count at one screen: the port matches until the first thing
/// it has not got, and everything after that frame is unmeasured whether the
/// port could play it or not. Re-anchoring at every handover of control means a
/// stretch the port cannot enter costs that stretch and no others, so the count
/// is a sum over the parts of the run the port can be asked about rather than a
/// prefix of the run it happens to survive.
///
/// **Frame-exact within a stretch, and nothing is graded across an anchor.**
/// Each stretch gets its own boot record, taken from the frame before its own
/// frame 0 the same way `gradeMovie` takes the opening's -- cell, position,
/// camera and counter phase, all read out of the machine that was there. No
/// cutscene, transition or menu is reproduced by the port and none is graded
/// here; those are the duration comparison, which is a different sub-task.
///
/// One replay and one conversion serve every stretch. See `referencesFromMovie`
/// and `gradeRef` for why each of those is not done per anchor.
pub fn gradeAnchored(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    movie: tas.Movie,
    mesen_path: []const u8,
    min: u32,
    limit: usize,
    /// Grade only this stretch, or every one when null. The replay and the
    /// conversion still happen once either way; what `only` saves is twelve
    /// emulator runs, which is what makes `zig build trace -- stretch N`
    /// as cheap to reach for as the segment's trace.
    only: ?usize,
    resolution: Resolution,
) !Anchored {
    var r = try tas.run(allocator, rom, movie, .{
        .max_frames = limit,
        .stride = 1,
        .watch_save = false,
        .profile_record = false,
    });
    defer r.deinit(allocator);
    var src: MovieSource = .{ .rom = rom, .movie = movie };
    return gradeAnchoredFrom(allocator, io, rom, r.track(), src.source(), mesen_path, min, only, resolution, false);
}

/// The anchored sweep over James's recording, census and all.
///
/// One function because two callers grade it: `oracle -- recorded`, which
/// prints the table, and the gate's `recorded` rung, which holds it to
/// `recorded_gate_floor`. A second copy of the census-then-sweep sequence would
/// be a second place for the rung to drift from the tool a red rung sends you to.
pub const Recorded = struct {
    census: gb_trace.Census,
    an: Anchored,
    /// The recording's own opening, found only when the window starts at 0.
    /// A later window has none, and every stretch carries its own handover.
    opening: ?tas.Opening,
    /// Mesen runs the references took, and stretches capped to what one holds.
    passes: usize,
    capped: usize,

    pub fn deinit(self: *Recorded, allocator: std.mem.Allocator) void {
        self.an.deinit(allocator);
        self.census.deinit(allocator);
        self.* = undefined;
    }
};

pub fn gradeRecorded(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    rec: gb_trace.Recording,
    start: usize,
    window: usize,
    min: u32,
    fault: bool,
    mesen_path: []const u8,
    home: []const u8,
) !Recorded {
    var cen = try gb_trace.census(allocator, io, rom, rec, start, window, gb_trace.input_offset, mesen_path, home);
    errdefer cen.deinit(allocator);
    if (cen.samples.len == 0) {
        return .{ .census = cen, .an = .{ .stretches = &.{}, .horizon = 0, .min = min }, .opening = null, .passes = 0, .capped = 0 };
    }
    const track = tas.Track.ofSamples(cen.samples);

    const opening: ?tas.Opening = if (start == 0) tas.findOpening(track) catch null else null;
    var src: TraceSource = .{
        .io = io,
        .rom = rom,
        .rec = rec,
        .mesen_path = mesen_path,
        .home = home,
        .control = if (opening) |op| op.control else 0,
    };
    const an = try gradeAnchoredFrom(allocator, io, rom, track, src.source(), mesen_path, min, null, .exact, fault);
    return .{ .census = cen, .an = an, .opening = opening, .passes = src.passes, .capped = src.capped };
}

/// The window of the recording the gate's `recorded` rung grades: its first
/// 2000 frames, from the savestate through the opening and into map 10.
///
/// **Chosen by cost, and measured on 2026-09-26 before anything was chosen.**
/// A Mesen pass replays from the movie's first frame whatever window it
/// records, so a window's cost grows with how deep it starts: three census
/// passes and twelve reference passes here take **65 s**, and the same 2000
/// frames at 10 000, the only early window with a broken block in it, took
/// **47 minutes**, because 22 of its 26 anchors never settle and each unsettled
/// anchor spends all fifteen settle rounds. Those 22 are tileset assignment
/// (map 6 cells $6B and $6C on table 9 where the Game Boy shows table 4, map 3
/// cell $21 on table 5) and not anything a gate run would learn from.
///
/// What this window is not is a Metroid, a pickup or a broken block: it grades
/// James's own play through the opening rooms, which the any% run never
/// walks, and it is 11 stretches to the published run's 13. The kills and
/// pickups remain `oracle -- recorded`'s to reach, off the gate.
pub const recorded_gate_start: usize = 0;
pub const recorded_gate_window: usize = 2000;

/// Frames the port must play across the gate window's stretches.
///
/// **493 of 1648, measured 2026-09-26**, on the cart at `32bccc0`:
/// stretch 0 plays all 346 of its frames (the new game's placement through the
/// first room), stretch 6 plays 97, stretches 2 and 9 play 25 each. The other
/// seven stop on frame 0 with the camera or Samus already diverged, which is
/// the same shape `anchored_gate_floor`'s nine are, and a ratchet rather than
/// a coverage claim for the same reason.
///
/// The census that grades this could not have run before that date: its stop
/// frame left out the input offset, so every pass wrote one row short and
/// `census` took the short pass for the movie ending. The whole 2000-frame
/// window was a 906-frame one, three stretches and 371 frames, and nothing said so.
pub const recorded_gate_floor: usize = 493;

/// Stretches of the gate window the cart must be able to be booted into. All
/// eleven, measured 2026-09-26; see `anchored_gradable_floor` for why this is
/// a separate number from the frame sum.
pub const recorded_gradable_floor: usize = 11;

/// The same sweep, over whichever track and reference source the caller has.
///
/// **Split out because the recording cannot supply either by replay.** A
/// published `.vbm` gives both from one run of our own Game Boy; James's
/// recording gives the track from a Mesen census pass and the references from a
/// Mesen anchored pass, and neither can be reached from `tas.run`. Everything
/// after the two of them -- settling, the cart, the comparison -- is the same
/// code either way, which is the point of the split.
pub fn gradeAnchoredFrom(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    track: tas.Track,
    source: RefSource,
    mesen_path: []const u8,
    min: u32,
    only: ?usize,
    resolution: Resolution,
    /// Re-grade every seeded stretch against a cart built from the map alone.
    /// See `Seeding`; it costs one more emulator run per seeded stretch and
    /// nothing at all on a sweep that seeded none.
    fault: bool,
) !Anchored {
    const convert = @import("snes_convert.zig");

    const anchors = try anchorsFrom(allocator, track, min);
    defer allocator.free(anchors);
    if (anchors.len == 0) return .{ .stretches = &.{}, .horizon = 0, .min = min, .settling = &.{} };

    const horizon: u32 = @intCast(anchors[anchors.len - 1].origin + anchors[anchors.len - 1].frames);

    // Move each anchor to the first frame the cart can honestly be built at,
    // then re-cut the stretches so each still runs to the next anchor. Without
    // this the sweep grades a cart built for the room she is leaving against
    // the room she arrives in; see `settleAnchors`.
    const settling = try settleAnchorsFrom(allocator, rom, source, anchors, track, horizon);
    errdefer allocator.free(settling);
    for (anchors, settling) |*a, st| {
        if (st.origin) |o| {
            a.origin = o;
        } else {
            a.settled = false;
        }
    }
    for (anchors[0 .. anchors.len - 1], anchors[1..]) |*a, b| {
        // A stretch whose next anchor was pushed past its own end is empty
        // rather than negative.
        a.frames = if (b.origin > a.origin) b.origin - a.origin else 0;
    }
    {
        const last = &anchors[anchors.len - 1];
        last.frames = if (horizon > last.origin) horizon - last.origin else 0;
    }

    var gradable: std.ArrayList(Anchor) = .empty;
    defer gradable.deinit(allocator);
    for (anchors) |a| {
        if (!a.settled or a.frames == 0) continue;
        try gradable.append(allocator, a);
    }

    const refs = try source.references(allocator, gradable.items);
    defer allocator.free(refs);

    var set = try convert.run(allocator, rom);
    defer set.deinit();

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);

    var stretches = try allocator.alloc(Stretch, anchors.len);
    errdefer allocator.free(stretches);

    var next: usize = 0;
    for (anchors, 0..) |anchor, i| {
        stretches[i] = .{ .anchor = anchor, .rep = null };
        if (!anchor.settled or anchor.frames == 0) continue;
        // `gradable` is `anchors` filtered in order, so the refs line up by a
        // walking index rather than by a search.
        std.debug.assert(gradable.items[next].origin == anchor.origin);
        const maybe_ref = refs[next];
        next += 1;
        var mr = maybe_ref orelse continue;
        if (only) |want| if (i != want) {
            mr.deinit(allocator);
            continue;
        };
        // The report aliases the reference frames; the keys are duped below
        // because the take's slice starts `movie_key_lead` into the allocation
        // and freeing an interior pointer is not a thing an allocator survives.
        defer {
            allocator.free(mr.keys);
            allocator.free(mr.held);
        }

        // Its own cart and script per stretch, so a failure can be reproduced
        // by hand against the exact pair that produced it rather than against
        // whichever stretch happened to run last.
        const cart_path = try std.fmt.allocPrint(allocator, out_dir ++ "/stretch{d:0>2}.sfc", .{i});
        const lua_path = try std.fmt.allocPrint(allocator, out_dir ++ "/stretch{d:0>2}.lua", .{i});
        stretches[i].cart_path = cart_path;
        stretches[i].lua_path = lua_path;
        // The take's keys, not the reference's: already shifted by
        // `movie_key_lead` and already trimmed to the graded length.
        stretches[i].keys = try allocator.dupe(Key, mr.take().keys);
        stretches[i].rep = try gradeRef(allocator, io, dir, rom, set, mr, mesen_path, cart_path, lua_path, resolution, .world);

        // The fixture. Only where the seeding actually did something, because
        // a pristine re-grade of an undamaged room is the same cart twice.
        if (fault and (stretches[i].rep orelse unreachable).seeded > 0 and mesen_path.len != 0) {
            const fault_cart = try std.fmt.allocPrint(allocator, out_dir ++ "/stretch{d:0>2}-pristine.sfc", .{i});
            const fault_lua = try std.fmt.allocPrint(allocator, out_dir ++ "/stretch{d:0>2}-pristine.lua", .{i});
            defer allocator.free(fault_lua);
            stretches[i].fault_cart_path = fault_cart;
            var broken = try gradeRef(allocator, io, dir, rom, set, mr, mesen_path, fault_cart, fault_lua, resolution, .pristine);
            // Both reports alias the same reference frames; only `rep` owns
            // them, so this one is stripped of the slice rather than freed.
            broken.settled.frames = &.{};
            stretches[i].fault = broken;
        }
    }

    return .{ .stretches = stretches, .horizon = horizon, .min = min, .settling = settling };
}

/// Run `Bisect` against a real emulator, and pin the frame.
///
/// Shared by both grading paths -- `grade`'s segment and `gradeRef`'s movie
/// stretches -- so the segment does not keep bucket reporting for want of a
/// second copy of this loop. That matters from Step 10 on, which lengthens the
/// segment and so widens its buckets.
///
/// Returns null, having spent `b.runs` runs, when a truncated run answers with
/// anything but "matched" or "diverged the same way the coarse run did". A
/// bisection over an answer it cannot classify would pin a confident wrong
/// frame; the caller keeps the bucket instead, which only ever understates.
fn pinExact(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    mesen_path: []const u8,
    settled: Settled,
    take: Take,
    cart_path: []const u8,
    lua_path: []const u8,
    coarse: Divergence,
    b: *Bisect,
) !?usize {
    b.* = .init(coarse.frame, bucketWidth(coarse.what, take.per_code), take.ref.len);
    while (b.next()) |n| {
        const fine = take.over(take.ref[0..n], take.keys[0..n]);
        const code = try runOne(allocator, io, dir, mesen_path, settled, fine, cart_path, lua_path);
        const diverged = if (code == code_ok)
            false
        else if (decode(code, fine.per_code)) |d| what: {
            // A truncation cannot change *what* stopped the run, because it
            // cannot change any frame before the one it stops at. A different
            // quantity means an assumption here is wrong, so stop rather than
            // average over it.
            if (d.what != coarse.what) return null;
            break :what true;
        } else return null;
        b.observe(n, diverged);
    }
    return b.frame();
}

// ---- The fade -------------------------------------------------------------

/// The Game Boy's palette as the play field shows it, and what the port uses in
/// its place: **SNES master brightness, which is our substitution**, not a
/// measurement. The DMG palettes shift every shade one step darker per stage, so
/// the four stages are spaced evenly over INIDISP's sixteen levels. The engine's
/// `FadeBrightness` table carries the same four numbers, and the `fade` rung is
/// what holds the two together: it reads the cart's register, not the table.
pub const palette_normal: u8 = 0x93;
pub fn brightnessFor(palette: u8) ?u8 {
    return switch (palette) {
        0x93 => 15,
        0xE7 => 10,
        0xFB => 5,
        0xFF => 0,
        else => null,
    };
}

pub const FadeRow = struct {
    /// Index into the take's reference.
    index: usize,
    /// INIDISP brightness the cart must show, forced blank counting as zero.
    want: u8,
};

/// The frames the `fade` rung grades: **every frame of the take**, each at the
/// brightness the Game Boy's palette maps to.
///
/// Until Step 24b this graded only the frames the palette was not normal, plus
/// the first normal frame after each run of them, because the port held a
/// forced blank across every door script and a scrolling door's script is all
/// `$93`: grading those frames would have made this rung a second report of
/// that defect. With the blank gone they are graded like the rest, so a door
/// script that blanks the screen the Game Boy keeps showing fails here.
pub fn fadeRows(allocator: std.mem.Allocator, ref: []const Frame) ![]FadeRow {
    const rows = try allocator.alloc(FadeRow, ref.len);
    errdefer allocator.free(rows);
    for (ref, 0..) |f, k| {
        rows[k] = .{ .index = k, .want = brightnessFor(f.bg_palette) orelse return Error.UnknownPalette };
    }
    return rows;
}

/// Rows at $FF on which the Game Boy's camera moved: the scroll the original
/// hides. A take with none of these is not grading what Step 20 is about, and
/// the rung says so rather than passing.
pub fn darkScrollFrames(ref: []const Frame, rows: []const FadeRow) usize {
    var n: usize = 0;
    for (rows) |r| {
        if (r.want != 0 or r.index == 0) continue;
        const a = ref[r.index - 1];
        const b = ref[r.index];
        if (a.camera_x != b.camera_x or a.camera_y != b.camera_y) n += 1;
    }
    return n;
}

/// Exit codes 6-18 are free between `code_frame_phase` and `code_setup`, and
/// the fade's graded rows are bucketed into them.
pub const code_fade: u8 = 6;
pub const codes_fade: usize = code_setup - code_fade;

pub fn fadePerCode(rows: usize) usize {
    return @max(1, (rows + codes_fade - 1) / codes_fade);
}

/// The track script, with a second commit callback that grades brightness.
///
/// The track's own checks stay in: a cart that left the reference's position
/// is not one whose brightness means anything, and it stops with the track's
/// codes. The fade callback counts its own commits rather than reading the
/// track's `i`, so the order Mesen2 runs two callbacks on one address in does
/// not matter.
pub fn writeFadeLua(
    allocator: std.mem.Allocator,
    settled: Settled,
    take: Take,
    rows: []const FadeRow,
    w: *std.Io.Writer,
) !void {
    try writeLua(allocator, settled, take, w);
    const commit = @import("snes_inject.zig").symbol(commit_symbol) orelse return Error.MissingSymbol;
    try w.print("\n-- Step 20: the fade. Index into REF -> INIDISP brightness wanted.\n", .{});
    try w.print("local FADE = {{\n", .{});
    for (rows, 0..) |r, j| try w.print("  [{d}] = {{{d},{d}}},\n", .{ r.index + 1, r.want, j });
    try w.print("}}\n", .{});
    try w.print(
        \\local CODE_FADE, FADE_PER = {d}, {d}
        \\local fadeCommits = 0
        \\emu.addMemoryCallback(function()
        \\  fadeCommits = fadeCommits + 1
        \\  -- The first commit is before any frame has run; REF[k] is the
        \\  -- (k+1)th, exactly as the track callback counts.
        \\  local row = FADE[fadeCommits - 1]
        \\  if row == nil then return end
        \\  local st = emu.getState()
        \\  local got = st["ppu.screenBrightness"]
        \\  if st["ppu.forcedBlank"] then got = 0 end
        \\  if got ~= row[1] then
        \\    emu.stop(CODE_FADE + (row[2] // FADE_PER))
        \\  end
        \\end, emu.callbackType.exec, 0x{X:0>6}, 0x{X:0>6}, emu.cpuType.snes, emu.memType.snesMemory)
        \\
    , .{ code_fade, fadePerCode(rows.len), commit, commit });
}

pub const fade_cart_name = out_dir ++ "/fade.sfc";
pub const fade_lua_name = out_dir ++ "/fade.lua";

pub const FadeReport = struct {
    no_emulator: bool = false,
    no_boot_for_cell: bool = false,
    rows: usize = 0,
    dark_scroll: usize = 0,
    per_code: usize = 1,
    code: u8 = code_ok,
    /// The reference frame the first graded row of the failing bucket is on.
    first_frame: ?usize = null,
    last_frame: ?usize = null,
    /// The movie frame the take's frame 0 is.
    origin: u32 = 0,
};

/// Step 20's rung: the any% run's door $1DF fade, graded on the cart's screen
/// brightness against the Game Boy's `bg_palette`, frame for frame.
pub fn gradeFade(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    movie: tas.Movie,
    mesen_path: []const u8,
    want: usize,
) !FadeReport {
    const convert = @import("snes_convert.zig");
    var mr = try referenceFromMovie(allocator, rom, movie, want);
    defer mr.deinit(allocator);
    var set = try convert.run(allocator, rom);
    defer set.deinit();
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);

    const take = mr.take();
    const rows = try fadeRows(allocator, take.ref);
    defer allocator.free(rows);
    var out: FadeReport = .{
        .rows = rows.len,
        .dark_scroll = darkScrollFrames(take.ref, rows),
        .per_code = fadePerCode(rows.len),
        .origin = mr.origin,
    };

    // Built, not run: an empty emulator path is `gradeRef`'s build-only arm.
    const built = try gradeRef(allocator, io, dir, rom, set, mr, "", fade_cart_name, fade_lua_name, .bucket, .world);
    if (built.no_boot_for_cell) {
        out.no_boot_for_cell = true;
        return out;
    }
    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeFadeLua(allocator, mr.settled, take, rows, &lua.writer);
    try dir.writeFile(io, .{ .sub_path = std.fs.path.basename(fade_lua_name), .data = lua.written() });
    if (mesen_path.len == 0) {
        out.no_emulator = true;
        return out;
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{ mesen_path, fade_cart_name, "--testrunner", fade_lua_name, "--timeout=90" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    out.code = if (term == .exited) @truncate(term.exited) else 255;
    if (out.code >= code_fade and out.code < code_position) {
        const bucket = out.code - code_fade;
        const lo = bucket * out.per_code;
        if (lo < rows.len) {
            out.first_frame = rows[lo].index;
            out.last_frame = rows[@min(rows.len, lo + out.per_code) - 1].index;
        }
    }
    return out;
}

/// The rung's report line, shared by `verify` and `zig build oracle -- fade`.
/// Returns whether it passed.
pub fn printFade(out: *std.Io.Writer, rep: FadeReport) !bool {
    if (rep.no_boot_for_cell) {
        try out.print("FAIL  fade              the any% run's starting cell has no boot record; nothing was graded\n", .{});
        return false;
    }
    if (rep.rows == 0 or rep.dark_scroll == 0) {
        try out.print("FAIL  fade              the reference holds {d} fade frames, {d} of them a scroll in the dark: nothing to grade\n", .{ rep.rows, rep.dark_scroll });
        return false;
    }
    if (rep.no_emulator) {
        try out.print("ok    fade              {d} Game Boy fade frames; not compared: no emulator (set MESEN)\n", .{rep.rows});
        return true;
    }
    if (rep.code == code_ok) {
        try out.print("ok    fade              the cart's brightness follows the Game Boy's palette on {d} frames, {d} of them the scroll it hides\n", .{ rep.rows, rep.dark_scroll });
        return true;
    }
    if (rep.first_frame) |f| {
        try out.print("FAIL  fade              the cart's brightness differs from the Game Boy's palette at reference frame {d}-{d} (movie {d}-{d})\n", .{
            f, rep.last_frame.?, rep.origin + f, rep.origin + rep.last_frame.?,
        });
    } else {
        try out.print("FAIL  fade              the cart left the reference before the fade could be graded: {s} (exit {d})\n", .{ explain(rep.code), rep.code });
    }
    return false;
}

fn runOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    mesen_path: []const u8,
    settled: Settled,
    take: Take,
    cart_path: []const u8,
    lua_path: []const u8,
) !u8 {
    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeLua(allocator, settled, take, &lua.writer);
    try dir.writeFile(io, .{ .sub_path = std.fs.path.basename(lua_path), .data = lua.written() });

    var child = try std.process.spawn(io, .{
        .argv = &.{ mesen_path, cart_path, "--testrunner", lua_path, "--timeout=90" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    return if (term == .exited) @truncate(term.exited) else 255;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "the segment is long enough to say something and short enough to encode" {
    // 644 until B4b extended it on 2026-09-09, then 700, then 703 in 1.0 Step
    // 9. The number is asserted rather than derived so that a phase added or
    // removed by accident fails here, and `snes_trace.zig` has a test of its
    // own that this many frames still fit its save-RAM channel -- which is what
    // caught the fifth column that walk wanted. The channel holds 705. The
    // three frames past 700 reach the Senjoo's contact at 702, which waited on
    // the horizontal entry's collision flag (`docs/bug_tracker.md`).
    try testing.expectEqual(@as(u16, 703), segment_frames);
    // The three code ranges have to fit under 256 with room for the status
    // codes and for `code_unhandled` behind them, and they have to not overlap
    // each other. The highest code any range can emit comes from the *last*
    // frame, not from one past it.
    const top = (segment_frames - 1) / frames_per_code;
    try testing.expect(code_position + top < code_camera);
    try testing.expect(code_camera + top < code_pose);
    try testing.expect(code_pose + top < code_unhandled);
    try testing.expect(code_unhandled + codes_unhandled <= 255);
    // And a code in one range is never decoded as another.
    try testing.expectEqual(What.position, decode(code_position + top, frames_per_code).?.what);
    try testing.expectEqual(What.camera, decode(code_camera + top, frames_per_code).?.what);
    try testing.expectEqual(What.pose, decode(code_pose + top, frames_per_code).?.what);
    // The unhandled band still has room for every pose the original dispatches,
    // which is what the narrowing from 80 to 60 had to not cost.
    try testing.expect(codes_unhandled > 0x1D);

    // Every phase the segment names is reachable, and the schedule covers
    // exactly the segment. `Key` carries buttons the segment never presses --
    // Up and Down are the movie's, not this fixture's -- so this asks about the
    // phases rather than about the vocabulary.
    for (segment) |ph| {
        var found = false;
        for (0..segment_frames) |f| {
            if (keyAt(f).eql(ph.key)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "a divergence survives the round trip through an exit code" {
    // Not exactly: the code carries the frame to a resolution of eight, which
    // is enough to point a person at the right part of the segment and is what
    // the channel has room for. What must survive exactly is *which* quantity.
    for ([_]What{ .position, .camera, .pose }) |w| {
        var f: usize = 0;
        while (f < segment_frames) : (f += 7) {
            const d: Divergence = .{ .frame = f, .what = w };
            const back = decode(codeFor(d, frames_per_code), frames_per_code).?;
            try testing.expectEqual(w, back.what);
            try testing.expect(back.frame <= f);
            try testing.expect(f - back.frame < frames_per_code);
        }
    }
    // And the status codes are not mistaken for divergences.
    for ([_]u8{ code_ok, code_never_booted, code_fatal, code_wrong_start, code_short }) |c| {
        try testing.expect(decode(c, frames_per_code) == null);
    }
}

test "the comparator names the first frame that differs and what differed" {
    var a: [10]Frame = @splat(.{ .samus_x = 1, .samus_y = 2, .camera_x = 3, .camera_y = 4 });
    var b = a;
    try testing.expect(firstDivergence(&a, &b) == null);

    b[6].camera_y += 1;
    var d = firstDivergence(&a, &b).?;
    try testing.expectEqual(@as(usize, 6), d.frame);
    try testing.expectEqual(What.camera, d.what);

    // Position wins over camera on the same frame: it is the earlier cause.
    b[6].samus_x += 1;
    d = firstDivergence(&a, &b).?;
    try testing.expectEqual(What.position, d.what);

    // An earlier difference wins over a later one whatever it is.
    b[2].camera_x += 1;
    d = firstDivergence(&a, &b).?;
    try testing.expectEqual(@as(usize, 2), d.frame);
}


test "a door segment's window opens on the warp and not on a scroll" {
    // `door spike`'s crossing: walked left to $C:$3C's edge, then door $B9's
    // `WARP $F, $C4` puts the camera on screen row $C.
    var f: [6]Frame = @splat(.{ .samus_x = 0x0C0B, .samus_y = 0x0384, .camera_x = 0x0C50, .camera_y = 0x0395 });
    try testing.expect(doorFrom(&f) == null);
    // A scroll into the next screen on either axis is play.
    f[2].camera_x = 0x0BFC;
    f[3].camera_y = 0x0402;
    try testing.expect(doorFrom(&f) == null);
    f[4] = .{ .samus_x = 0x03F8, .samus_y = 0x0C84, .camera_x = 0x0430, .camera_y = 0x0C95 };
    f[5] = f[4];
    try testing.expectEqual(@as(?usize, 4), doorFrom(&f));
}

test "the window mask is the part of the screen that is inside the cell" {
    // The view sitting exactly on the cell's origin: 160x144 of it is on
    // screen, which is 20x18 tiles, and every one of them is in the cell.
    {
        const m = windowMask(0, 0, 0x0800, 0x0300, 0x38);
        var n: usize = 0;
        for (m) |b| n += @intFromBool(b);
        try testing.expectEqual(@as(usize, 20 * 18), n);
        try testing.expect(m[0]);
        try testing.expect(!m[20]);
        try testing.expect(!m[18 * 32]);
    }
    // Half a screen to the left of the cell's origin, so the view straddles the
    // boundary: only the columns on the cell's side count, and the ones showing
    // the screen next door are not the cart's to be graded against.
    {
        const m = windowMask(0x80, 0, 0x0810, 0x0300, 0x38);
        var cols: usize = 0;
        for (0..32) |c| cols += @intFromBool(m[c]);
        // She is at $0810 with the view scrolled to $80, so its left edge is
        // world $0780 and it runs to $081F: sixteen of its twenty tile columns
        // are below $0800 and show cell $37, and only four are ours.
        try testing.expectEqual(@as(usize, 4), cols);
    }
    // A cell nothing on screen belongs to compares nothing at all, which is
    // what `World.same` refuses to call a match.
    {
        const m = windowMask(0, 0, 0x0800, 0x0300, 0x00);
        for (m) |b| try testing.expect(!b);
        var w: World = .{};
        for (m) |b| w.compared += @intFromBool(b);
        try testing.expect(!w.same());
    }
}

test "a spawn that names a door draws that room, and one that does not, does not" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const boot = try snes_screen.chooseBoot(a, rom);
    const bank = room.map_bank_first + boot.map_index;
    var parsed = try map_mod.parseBank(a, rom, bank);
    defer parsed.deinit(a);
    const body = map_mod.screenBody(rom, bank, parsed.cells[boot.cell].screen_ptr) orelse
        return error.SkipZigTest;
    const want = expandCell(rom, body, boot.tiletable) orelse return error.SkipZigTest;

    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    var snap = try m.snapshot();
    defer snap.deinit(a);

    const base: room.Spawn = .{
        .map_bank = bank,
        .screen_row = @truncate(boot.cell >> 4),
        .screen_col = @truncate(boot.cell & 0x0F),
        .pixel_x = @truncate(boot.samus_x),
        .pixel_y = @truncate(boot.samus_y),
    };

    // With the door: the room is loaded and every one of the map's 1024 tiles
    // is the boot cell expanded through the table the door selected. Nothing is
    // masked here -- the draw runs from the screen's own origin, so at this
    // instant, before a single frame of scrolling, the map is the whole cell.
    var withDoor = base;
    withDoor.door_index = boot.door_index;
    _ = try room.spawn(&m, withDoor);
    var agreed: usize = 0;
    {
        const at: u16 = if (m.read(0xFF40) & 0x08 != 0) 0x9C00 else 0x9800;
        for (0..1024) |i| {
            agreed += @intFromBool(m.read(at + @as(u16, @intCast(i))) == want[i]);
        }
    }
    try testing.expectEqual(@as(usize, 1024), agreed);

    // Without it, the warp draws its three columns through whatever metatile
    // table the previous room left selected. That is the defect this field
    // exists to fix, and it is asserted rather than described: a bare warp does
    // *not* produce the room.
    m.restore(snap);
    _ = try room.spawn(&m, base);
    var bare: usize = 0;
    {
        const at: u16 = if (m.read(0xFF40) & 0x08 != 0) 0x9C00 else 0x9800;
        for (0..1024) |i| {
            bare += @intFromBool(m.read(at + @as(u16, @intCast(i))) == want[i]);
        }
    }
    try testing.expect(bare < 1024);
}




// ---- The movie oracle ------------------------------------------------------

test "a movie frame is translated into what the port has, and what it lacks is counted" {
    // The port's whole vocabulary: a walk each way, a jump, and the two the
    // crouch and the morph ball read.
    try testing.expectEqual(key.none, movieKey(0x00));
    try testing.expectEqual(key.right, movieKey(0x10));
    try testing.expectEqual(key.left, movieKey(0x20));
    try testing.expectEqual(key.jump, movieKey(0x01));
    try testing.expectEqual(key.right_jump, movieKey(0x11));
    try testing.expectEqual(key.left_jump, movieKey(0x21));
    try testing.expectEqual(key.up, movieKey(0x40));
    try testing.expectEqual(key.down, movieKey(0x80));
    // And B, which joined the vocabulary in Step 12b.
    try testing.expectEqual(key.fire, movieKey(0x02));

    // A bitset, so a combination nobody wrote down is still representable.
    // This is the one the published run actually presses: Down while walking.
    try testing.expectEqual(Key{ .down = true, .right = true }, movieKey(0x90));

    // Nothing the engine reads is ever reported as dropped.
    for ([_]u8{ 0x00, 0x01, 0x02, 0x10, 0x12, 0x20, 0x11, 0x21, 0x40, 0x80, 0x90 }) |h| {
        try testing.expectEqual(@as(u8, 0), unsupportedBits(h));
    }

    // Everything else is, by name rather than by silence: Start is the pause
    // the port has no screen for, and Select is the map. Each is a thing Phase
    // 0b has still to add. **B was on this list until Step 12b** and is now on
    // the one above it, which is the whole point of that step.
    try testing.expectEqual(@as(u8, 0x08), unsupportedBits(0x08)); // start
    try testing.expectEqual(@as(u8, 0x04), unsupportedBits(0x04)); // select

    // Right and left together is not approximated to either one. The original
    // resolves it in code we have not read, so guessing would be inventing a
    // reference rather than taking one.
    try testing.expectEqual(both_directions, unsupportedBits(both_directions));
    try testing.expectEqual(key.none, movieKey(both_directions));
}

test "the pinned frame does not depend on how wide the bucket was" {
    // **The property `movie_gate_floor` exists to have and did not.** A floor
    // reported as a bucket edge is a different number at every resolution --
    // measured 2026-09-01 on one unchanged cart, `want` of 500, 600, 900 and
    // 1200 gave 371, 376, 372 and 375. Pinned, every width has to give the one
    // frame that actually diverged.
    //
    // Driven against a stated divergence rather than an emulator, because that
    // is what makes it a property test: `diverges(n)` is exactly "n is past the
    // divergence", which is the monotonicity `Bisect` rests on, and every
    // bucket width is tried instead of the two an emulator run could afford.
    const offered: usize = 900;
    for (1..offered) |d| {
        var per_code: usize = 1;
        while (per_code <= 32) : (per_code += 1) {
            // The bucket the coarse run would have named for this divergence.
            const start = (d / per_code) * per_code;
            var b: Bisect = .init(start, per_code, offered);
            while (b.next()) |n| b.observe(n, n > d);
            try testing.expectEqual(d, b.frame());
            // And it is a bisection, not a scan.
            try testing.expect(b.runs <= std.math.log2_int_ceil(usize, per_code + 1));
        }
    }

    // The bucket that runs off the end of the reference: `hi` clamps to the
    // length, and the run that produced the code is the evidence it diverges.
    var tail: Bisect = .init(896, 15, offered);
    try testing.expectEqual(@as(usize, 900), tail.hi);
    while (tail.next()) |n| tail.observe(n, n > 898);
    try testing.expectEqual(@as(usize, 898), tail.frame());

    // A one-frame bucket is already the answer and costs no runs at all, which
    // is what keeps the pin free on a rung whose reference is short.
    var exact: Bisect = .init(376, 1, offered);
    try testing.expectEqual(@as(?usize, null), exact.next());
    try testing.expectEqual(@as(usize, 0), exact.runs);
    try testing.expectEqual(@as(usize, 376), exact.frame());
}

test "a report states its divergence at the resolution it actually has" {
    // The bucket, when nothing pinned it.
    const bucket: Report = .{
        .boot = undefined,
        .spawned = undefined,
        .settled = undefined,
        .code = codeFor(.{ .frame = 376, .what = .position }, 15),
        .per_code = 15,
        .offered = 899,
        // `reachedFrames` withholds a count when the two machines were not in
        // the same room, which is the check that has to pass before a frame
        // number means anything. See `World.same`.
        .world = .{ .matched = 306, .compared = 306 },
    };
    const b = bucket.divergence().?;
    try testing.expectEqual(What.position, b.what);
    try testing.expectEqual(@as(usize, 375), b.first);
    try testing.expectEqual(@as(usize, 389), b.last);
    try testing.expect(!b.exact());

    // The frame, when the bisection ran. Same code, same width: only the pin
    // changes what is reported, which is the claim `Report.divergence` makes.
    var pinned = bucket;
    pinned.exact_frame = 376;
    pinned.exact_runs = 4;
    const e = pinned.divergence().?;
    try testing.expectEqual(What.position, e.what);
    try testing.expectEqual(@as(usize, 376), e.first);
    try testing.expectEqual(@as(usize, 376), e.last);
    try testing.expect(e.exact());
    // And that is the number the floors are summed from.
    try testing.expectEqual(@as(?usize, 376), reachedFrames(pinned));

    // A status code is not a divergence, pinned or not.
    var short = bucket;
    short.code = code_short;
    try testing.expectEqual(@as(?Divergence.Span, null), short.divergence());
}

test "the exit code's resolution follows the reference's length" {
    // `frames_per_code` is the formula applied to the segment, so this is a
    // tautology on purpose: it is what stops the two from being written down
    // separately again, which is how they last drifted.
    try testing.expectEqual(frames_per_code, perCode(segment_frames));
    // Short references resolve exactly, which is what makes a refined
    // divergence an actual frame number rather than a bucket. The boundary is
    // `codes_per_quantity`, so it moved with it.
    try testing.expectEqual(@as(usize, 1), perCode(codes_per_quantity));
    try testing.expectEqual(@as(usize, 1), perCode(1));
    try testing.expectEqual(@as(usize, 2), perCode(codes_per_quantity + 1));
    // And a reference far longer than the segment still fits the one byte.
    const long = perCode(40_000);
    const d: Divergence = .{ .frame = 39_999, .what = .camera };
    try testing.expect(codeFor(d, long) < 255);
    try testing.expectEqual(What.camera, decode(codeFor(d, long), long).?.what);
}

test "an anchor is a frame the cart can honestly be built at, and the handover usually is not" {
    // The rule the re-anchored sweep rests on, checked against the run rather
    // than restated. A boot record is taken from the frame *before* the
    // reference's frame 0, so those two frames have to be in the same room and
    // the same pose -- and on the any% run most handovers fail that, because a
    // refusal ends when the pose changes and seven of the thirteen are room
    // transitions.
    //
    // Without the second half of this test the first half would pass against a
    // `pushToStableAnchor` that returned its own argument.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try tas.parse(bytes);

    var r = try tas.run(a, rom, movie, .{
        .max_frames = anchored_gate_limit, .stride = 1, .watch_save = false, .profile_record = false,
    });
    defer r.deinit(a);

    const anchors = try anchorsFrom(a, r.track(), anchor_min_frames);
    defer a.free(anchors);
    try testing.expect(anchors.len > 1);

    var pushed: usize = 0;
    for (anchors) |an| {
        const o = an.origin;
        // The invariant, on every anchor.
        try testing.expect(tas.Room.of(r.samples[o - 1]).eql(tas.Room.of(r.samples[o])));
        try testing.expectEqual(r.samples[o - 1].pose, r.samples[o].pose);
        // And every frame the push skipped really did violate it.
        var f = an.handover;
        while (f < o) : (f += 1) {
            const moved_room = !tas.Room.of(r.samples[f - 1]).eql(tas.Room.of(r.samples[f]));
            const moved_pose = r.samples[f - 1].pose != r.samples[f].pose;
            try testing.expect(moved_room or moved_pose);
        }
        if (o != an.handover) pushed += 1;
    }
    // Most of them move, which is the fact that makes the push worth having.
    try testing.expect(pushed > anchors.len / 2);

    // The stretches partition the faithful window in order and do not overlap:
    // a stretch runs to the next anchor, which is what keeps the total a sum
    // rather than a double count.
    for (anchors[0 .. anchors.len - 1], anchors[1..]) |x, y| {
        try testing.expect(y.origin > x.origin);
        try testing.expectEqual(y.origin - x.origin, @as(u32, @intCast(x.frames)));
    }

    // And the first anchor is the opening's, which `tas.zig` independently
    // asserts is the stretch `findOpening` finds. If these ever disagree the
    // sweep has started grading from somewhere Step 15b never measured.
    const opening = try tas.findOpening(r.track());
    try testing.expectEqual(opening.control, anchors[0].handover);
}

test "the anchored sweep's first stretch is the single anchor's, graded the same way" {
    // The generalisation checked against the special case, which is the same
    // discipline `tas.findRefusals` is held to against `findOpening`.
    //
    // No emulator: this compares what the two paths *set up*, which is where
    // they could silently diverge. What each then scores is the gate's
    // business, and running Mesen here would make a unit test take a minute.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try tas.parse(bytes);

    var mr = try referenceFromMovie(a, rom, movie, 64);
    defer mr.deinit(a);

    var r = try tas.run(a, rom, movie, .{
        .max_frames = anchored_gate_limit, .stride = 1, .watch_save = false, .profile_record = false,
    });
    defer r.deinit(a);
    const anchors = try anchorsFrom(a, r.track(), anchor_min_frames);
    defer a.free(anchors);

    try testing.expectEqual(mr.origin, anchors[0].origin);
    try testing.expectEqual(mr.control, anchors[0].handover);
}

test "every stretch the sweep grades has a room the cart can be built for" {
    // `settleAnchors` is a search with a bound, so it can come back empty --
    // and a stretch it came back empty for must be reported rather than graded
    // as zero. The distinction is the whole reason `Stretch.reached` returns an
    // optional.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try tas.parse(bytes);

    var r = try tas.run(a, rom, movie, .{
        .max_frames = anchored_gate_limit, .stride = 1, .watch_save = false, .profile_record = false,
    });
    defer r.deinit(a);
    const anchors = try anchorsFrom(a, r.track(), anchor_min_frames);
    defer a.free(anchors);
    const horizon: u32 = @intCast(anchors[anchors.len - 1].origin + anchors[anchors.len - 1].frames);

    const settling = try settleAnchors(a, rom, movie, anchors, r.track(), horizon);
    defer a.free(settling);
    try testing.expectEqual(anchors.len, settling.len);

    var settled: usize = 0;
    var slow: usize = 0;
    for (settling) |st| {
        const o = st.origin orelse continue;
        settled += 1;
        try testing.expect(st.world.same());
        try testing.expect(o >= st.handover);
        if (st.frames().? > 0) slow += 1;
    }
    // Most settle, and some take many frames to -- which is the measurement
    // that says a one-frame push is not enough. Both halves matter: if every
    // gap were zero the search would be doing nothing.
    try testing.expect(settled > anchors.len / 2);
    try testing.expect(slow > 0);
}

test "the movie oracle starts where the game starts, not where we would have" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);

    var mr = try referenceFromMovie(a, rom, try tas.parse(bytes), 64);
    defer mr.deinit(a);

    // Frame 0 is the first frame at or after the handover where the room and
    // the pose are both stable across it -- `pushToStableAnchor`'s rule. On the
    // any% run that is `control + 2`, and it is *not* `control`: the frame the
    // game hands control back is the one it spends leaving pose $13, and a cart
    // booted standing with the pad the game was holding walks on it.
    try testing.expectEqual(mr.control + 2, mr.origin);
    try testing.expectEqual(@as(u32, 326), mr.control);

    // The invariant, checked against the replay rather than taken on trust --
    // and the rejected frames checked too, so a rule that always returned its
    // own argument would fail here.
    {
        var replay = try tas.run(a, rom, try tas.parse(bytes), .{
            .max_frames = 400, .stride = 1, .watch_save = false, .profile_record = false,
        });
        defer replay.deinit(a);
        const o = mr.origin;
        try testing.expect(tas.Room.of(replay.samples[o - 1]).eql(tas.Room.of(replay.samples[o])));
        try testing.expectEqual(replay.samples[o - 1].pose, replay.samples[o].pose);
        var f = mr.control;
        while (f < o) : (f += 1) {
            const room_moved = !tas.Room.of(replay.samples[f - 1]).eql(tas.Room.of(replay.samples[f]));
            const pose_moved = replay.samples[f - 1].pose != replay.samples[f].pose;
            try testing.expect(room_moved or pose_moved);
        }
    }

    // She is at the game's landing site -- the position `tas.zig` measured
    // independently, from the movie's trace rather than from this pipeline.
    const pos = mr.settled.position();
    try testing.expectEqual(tas.landing_site_x, pos.x);
    try testing.expectEqual(tas.landing_site_y, pos.y);

    // **And that is not where the synthetic spawn would have put her.** This is
    // the test that fails if Step 15b is quietly reverted to Step 15's shape:
    // `samusStart` is the middle of the cell, which is what every boot record
    // held before a movie was allowed to choose. If these two ever agree, the
    // reference has stopped coming from the game.
    const synthetic = snes_screen.samusStart(mr.settled.cell());
    try testing.expect(synthetic.x != pos.x or synthetic.y != pos.y);

    // The movie used to ask for something the port could not answer at once --
    // Down, at reference frame 1, which capped the comparison there. The crouch
    // reads Down and Up now, so nothing in this stretch is dropped.
    try testing.expectEqual(@as(?usize, null), mr.first_unsupported);
    try testing.expectEqual(@as(u8, 0), mr.unsupported_bits);

    // The inputs handed to the cart are the movie's own, frame for frame.
    try testing.expectEqual(mr.settled.frames.len, mr.keys.len);
    for (mr.held, mr.keys) |h, k| try testing.expectEqual(movieKey(h), k);
}

test "the cart's input schedule leads the reference by exactly one frame" {
    // The phase alignment `MovieRef.take` argues for, pinned as a shape rather
    // than left to the emulator to notice. A test here fails in a second; the
    // symptom without it is a divergence one frame into any movie, which took a
    // whole session to attribute the first time it mattered.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);

    var mr = try referenceFromMovie(a, rom, try tas.parse(bytes), 64);
    defer mr.deinit(a);

    const t = mr.take();
    // One frame shorter, because the last reference frame has no frame after it
    // to take an input from.
    try testing.expectEqual(mr.settled.frames.len - movie_key_lead, t.ref.len);
    try testing.expectEqual(t.ref.len, t.keys.len);

    // And every key is the *next* frame's byte, so that after the engine's own
    // one-frame publish delay both machines act on the same byte on the same
    // frame.
    for (t.keys, 0..) |k, i| try testing.expectEqual(movieKey(mr.held[i + movie_key_lead]), k);

    // The reference frames themselves are not shifted: only the inputs are.
    for (t.ref, 0..) |f, i| try testing.expectEqual(mr.settled.frames[i], f);
}

test "the movie's input ceiling is Select now, and it is a long way further in" {
    // The ceiling has moved twice and never gone away. It was reference frame 1
    // until the crouch landed, then 1368 -- the first frame the published run
    // presses B -- and Step 12b gave the port a beam, so it is now **3411**,
    // where the run first opens the map. B was $02; this is $04.
    //
    // Pinned rather than described, because "the movie asks for something we do
    // not have" is the number this whole phase is trying to grow, and a number
    // that only appears in a comment is a number that drifts. If this fails
    // low, an input the engine used to read has stopped being read.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);

    var mr = try referenceFromMovie(a, rom, try tas.parse(bytes), 3500);
    defer mr.deinit(a);

    try testing.expectEqual(@as(?usize, 3411), mr.first_unsupported);
    try testing.expectEqual(@as(u8, 0x04), mr.unsupported_bits);

    // And every frame before it really is representable, rather than the count
    // being right by luck about where the scan stopped. **Including 1368**,
    // which is where this test used to stop: the old ceiling is now a frame the
    // cart is handed, which is the half of the change that is about the port
    // rather than about the movie.
    for (mr.held[0..3411]) |h| try testing.expectEqual(@as(u8, 0), unsupportedBits(h));
    try testing.expect(mr.held[1368] & 0x02 != 0);
}

test "the game's own starting cell is one no door script names" {
    // Why `bootFor` does not filter on provenance, recorded as a fact about the
    // ROM rather than as a remark in a comment.
    //
    // The landing site is where a *new file* starts, so nothing warps to it and
    // no door script states its tileset: 41 of the 905 in-use cells are stated
    // outright and this is not one of them. `screens.assign` infers it from the
    // nearest warp target instead, and `oracle.compareWorlds` is what says
    // whether the inference held -- which for this cell it does, tile for tile.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var asg = try screens.assign(a, rom);
    defer asg.deinit(a);

    var found = false;
    for (asg.cells) |c| {
        if (c.bank != landing_map_bank) continue;
        if (@as(u8, c.y) * @as(u8, @intCast(map_mod.grid_w)) + c.x != landing_cell) continue;
        const ch = c.choice orelse return error.TestUnexpectedResult;
        try testing.expect(ch.provenance != .door);
        found = true;
    }
    try testing.expect(found);

    // And it is still bootable, which is the point of not filtering. Since
    // 1.0 Step 18c `bootFor` reads the crawl, which walked into it from the
    // new game: measured, not inferred, and still not stated by a door.
    const bf = (try snes_screen.bootFor(a, rom, landing_map_bank - map_mod.first_bank, landing_cell)).?;
    try testing.expectEqual(screens.Provenance.walked, bf.provenance);
    try testing.expectEqual(@as(u4, 5), bf.boot.tiletable);
}

test "gradeMovie's report keeps the reference frames it hands back" {
    // The regression test for a use-after-free that was latent from the day
    // `gradeMovie` was written and surfaced on 2026-09-01, when `verify`'s new
    // reachable rung became the first caller to read `Report.settled` on the
    // movie path and printed `AAAA,AAAA pose $AA` -- the allocator's safety
    // fill.
    //
    // No emulator is needed to hold the invariant: the `no_emulator` path
    // returns the same report through the same `defer`, which is exactly where
    // the ownership mistake lived.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try tas.parse(bytes);

    // What the reference says before it is handed to `gradeMovie`, read from a
    // separate build of it so the comparison cannot be against the same bytes.
    var mr = try referenceFromMovie(a, rom, movie, 64);
    const want_pose = mr.settled.frames[0].pose;
    const want_x = mr.settled.frames[0].samus_x;
    const want_len = mr.take().ref.len;
    mr.deinit(a);

    const rep = try gradeMovie(a, testing.io, rom, movie, "", 64, .bucket);
    defer a.free(rep.settled.frames);
    try testing.expect(rep.no_emulator);

    // Live memory, not a safety fill. `0xAA` in these fields is the exact
    // symptom the bug produced, so it is named rather than left to the equality
    // check to catch by luck.
    try testing.expect(rep.settled.frames.len >= want_len);
    try testing.expect(rep.settled.frames[0].pose != 0xAA);
    try testing.expectEqual(want_pose, rep.settled.frames[0].pose);
    try testing.expectEqual(want_x, rep.settled.frames[0].samus_x);

    // The frame the rung actually prints is the divergence frame, which is deep
    // into the slice rather than at its head -- a stale head can survive a
    // free that a tail cannot.
    const last = rep.settled.frames[rep.settled.frames.len - 1];
    try testing.expect(last.samus_x != 0xAAAA);
}

test "the reachable floor is a fact about the port, not about the movie's length" {
    // **This test asserted the opposite until 2026-09-05.** `perCode` derives
    // the exit channel's resolution from the reference's length, so the frame a
    // divergence was reported at was a bucket edge that moved when `want` moved
    // -- measured 2026-09-01 on one unchanged cart: want 500 -> 371, 600 -> 376,
    // 900 -> 372, 1200 -> 375. The old test therefore checked that the floor
    // was a *multiple* of the bucket width, which is the property a bucket edge
    // has and a frame does not.
    //
    // Pinned, the same four widths give 375 four times, so the floor is a frame
    // and the multiple-of check is what has to go. The widths still differ --
    // that is what makes the four measurements a real test of the property
    // rather than the same run repeated.
    // The widths still differ across windows -- that is what makes the claim
    // "the floor is a frame and not a bucket edge" testable at all, since a
    // bucket edge would move with them. The width at this window is not pinned
    // to a literal: it follows `movie_gate_frames`, which Step 6 retuned, and a
    // literal here is what broke the last time it was retuned.
    try testing.expect(perCode(499) != perCode(movie_gate_frames - 1));
    try testing.expect(perCode(1199) != perCode(movie_gate_frames - 1));

    // What still ties the two constants together, and the only thing that does:
    // a rung cannot report reaching more frames than it offered.
    try testing.expect(movie_gate_floor < movie_gate_frames);

    // And the coarse code still has to be able to *name* the bucket the pin
    // starts from: `codes_per_quantity` is the ceiling on how far a divergence
    // can be pointed at before the bisection narrows it.
    try testing.expect(movie_gate_floor / perCode(movie_gate_frames - 1) < codes_per_quantity);

    // The anchored floor is a sum over stretches, so it is bounded by nothing
    // here -- but it is a sum of exact frames now, which means it may not be a
    // multiple of anything either. Named so the next person to see 394 and
    // reach for `% per_code` finds out why not.
    //
    // **It used to be asserted greater than the reachable floor, and on
    // 2026-09-07 that stopped being true.** The relation was never a property;
    // it held while the port was mediocre everywhere, because thirteen
    // stretches of mediocrity outweigh one. Step 6 took the reachable rung to
    // 1396 frames from the run's first handover while nine of the anchored
    // sweep's stretches still diverge on their own frame zero, so one stretch
    // is now worth more than the other twelve put together. That is a finding
    // about where the port's remaining defects are -- they are at the handovers,
    // not in play -- and turning it back into an assertion would only hide it.
    try testing.expect(anchored_gate_floor > 0);
}

test "the reference is sampled on the game's tick, not on the LCD's" {
    // The segment presses jump alone at frame 200. The ROM's standing-jump
    // path stores pose $09 at 00:$14CB and returns, so the very next tick the
    // game finishes has her in $09 -- and the tick after that, with the button
    // already released, `poseFunc_jumpStart` commits her to $01.
    //
    // Sampled at the LCD frame boundary that $09 tick was invisible: the
    // reference went $00, $01 and never showed a $09 frame at all, while the
    // cart always did. That one-frame gap is what the segment's first
    // divergence was made of, and it was read for weeks as a port defect.
    // Asserting the pose here is asserting the alignment, because the pose is
    // the only field that changes fast enough to catch it.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const cells = try snes_screen.bootCandidates(a, rom, 8);
    defer a.free(cells);
    const chosen = try chooseStart(a, rom, cells);
    const ref = try reference(a, rom, chosen.start);
    defer a.free(ref.frames);

    // Frame 200 is the `jump` phase; 201 is the tick that acted on it.
    try testing.expectEqual(@as(u8, 0x00), ref.frames[200].pose);
    try testing.expectEqual(@as(u8, 0x09), ref.frames[201].pose);
    try testing.expectEqual(@as(u8, 0x01), ref.frames[202].pose);

    // And the counter advances exactly once per record. Under LCD-boundary
    // sampling it repeated and skipped values in the same run, which is the
    // same misalignment measured a second way.
    for (61..120) |f| {
        const prev = ref.frames[f - 1].counter;
        try testing.expectEqual(prev +% 1, ref.frames[f].counter);
    }
}

/// `scrollY` and `scrollX`, the two bytes every enemy position is relative to.
/// The ROM writes them from three places and **they do not all use the same
/// bias**: 00:$2366 (once a frame) and 00:$2896 (the room load, out of the
/// record it unpacks) subtract $48 and $50, while 00:$04C3, which restores the
/// camera from $D804..$D807, subtracts $78 and $30.
const gb_scroll_y_addr: u16 = 0xC205;
const gb_scroll_x_addr: u16 = 0xC206;

/// The engine's own two, read out of `engine/main.asm`. They are assembler
/// defines rather than labels, so there is no symbol to read; the source is,
/// the way `transition.zig` reads `!COPY_BG`.
fn engineScrollBias(name: []const u8) !u8 {
    const src = @embedFile("engine_asm");
    const at = std.mem.indexOf(u8, src, name) orelse return error.DefineMissing;
    const rest = src[at + name.len ..];
    const eq = std.mem.indexOfScalar(u8, rest, '$') orelse return error.DefineMissing;
    const end = std.mem.indexOfScalar(u8, rest[eq..], '\n') orelse rest.len - eq;
    return std.fmt.parseInt(u8, std.mem.trim(u8, rest[eq + 1 ..][0 .. end - 1], " \r"), 16);
}

test "the engine's scroll bias is the one the running game uses" {
    // **The cart's `DeriveScroll` had $78/$30 and the game uses $48/$50**, so
    // every enemy the spawn walk loaded came out 48 pixels below and 32 pixels
    // right of the original's -- which put it in a different band of the
    // deactivation window, deleted it while the Game Boy kept it, and left
    // `reachable` reading 604 against a floor of 1396. See `docs/bug_tracker.md`,
    // 2026-09-09.
    //
    // The wrong pair is in the ROM too, which is why reading was not enough to
    // catch it: 00:$04C3 really does subtract $78 and $30. So this asks the
    // *running* game instead, over the whole segment, and the answer is exact on
    // every frame -- there is no window in which the other pair is right.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const bias_y = try engineScrollBias("!GB_SCROLL_Y_BIAS = ");
    const bias_x = try engineScrollBias("!GB_SCROLL_X_BIAS = ");

    const cells = try snes_screen.bootCandidates(a, rom, 8);
    defer a.free(cells);
    const chosen = try chooseStart(a, rom, cells);

    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    var sp = chosen.start.spawn();
    sp.writes = &.{.{ .addr = gb_pose_addr, .value = start_pose }};
    _ = try room.spawn(&m, sp);

    var still: usize = 0;
    var prev = room.placement(&m);
    var waited: usize = 0;
    while (waited < settle_limit and still < settle_still) : (waited += 1) {
        _ = try m.runFrames(1, gbKeys(key.none));
        const now = room.placement(&m);
        still = if (now.eql(prev)) still + 1 else 0;
        prev = now;
    }
    if (still < settle_still) return error.NeverSettled;

    // How many frames the camera actually moved on. A run that never scrolled
    // would satisfy the identity trivially for any bias that happened to hold
    // at frame 0, so the count is asserted too.
    var moved: usize = 0;
    var last_cam: ?u16 = null;
    // And whether the pair this file used to carry was ever right, which is the
    // assertion that makes the fixture fail on the old answer as well as pass
    // on the new one.
    var old_pair_right: usize = 0;

    try stepToLogicPoint(&m);
    for (0..segment_frames) |f| {
        try stepOneTick(&m, gbKeys(keyAt(f)));
        const cam_y = m.read(room.camera_pixel_y_addr);
        const cam_x = m.read(room.camera_pixel_x_addr);
        const cam = (@as(u16, cam_y) << 8) | cam_x;
        if (last_cam) |p| {
            if (p != cam) moved += 1;
        }
        last_cam = cam;

        try testing.expectEqual(cam_y -% bias_y, m.read(gb_scroll_y_addr));
        try testing.expectEqual(cam_x -% bias_x, m.read(gb_scroll_x_addr));

        if (m.read(gb_scroll_y_addr) == cam_y -% 0x78 and
            m.read(gb_scroll_x_addr) == cam_x -% 0x30) old_pair_right += 1;
    }
    try testing.expect(moved > segment_frames / 4);
    try testing.expectEqual(@as(usize, 0), old_pair_right);
}

test "the movie reference is already on the game's tick" {
    // The same alignment check the segment needed, asked of the other path.
    // `$FF97` is incremented once per tick, so a reference sampled at a fixed
    // point of the tick sees it advance by exactly one per record; the segment,
    // sampled on the LCD frame boundary, saw it repeat and skip in the same run.
    //
    // It holds here, and that is why the movie path was left alone: `tas.run`
    // takes its boundary at the 143->144 edge (`FrameSource.vblank`), where the
    // game has finished its main loop and is waiting, while `harness.runFrames`
    // takes the LCD's own frame completion at the end of VBlank, which is the
    // middle of the game's work. Two boundaries, one aligned and one not.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch
        return error.SkipZigTest;
    defer a.free(bytes);

    var mr = try referenceFromMovie(a, rom, try tas.parse(bytes), 400);
    defer mr.deinit(a);

    for (1..mr.settled.frames.len) |f| {
        const prev = mr.settled.frames[f - 1].counter;
        try testing.expectEqual(prev +% 1, mr.settled.frames[f].counter);
    }
}

test "a Mesen stretch becomes the reference a replay would have produced" {
    // No emulator and no recording: the point is the *conversion*, and a test
    // that needed a 100-second Mesen replay to check it would not be run.
    // `gb_trace.runRefs` is what produces these bytes; this asserts what they
    // mean once they are back.
    const n: usize = 3;
    const rb = gb_trace.record_bytes;
    var rows: [3 * gb_trace.record_bytes]u8 = @splat(0);

    // The three frames' held bytes, used for *both* the movie's input list and
    // the `$FF80` column the game left behind. They are the same quantity on a
    // pass that is aligned, which is what the pad column is carried to check.
    // Frame 501 holds Start, which the port has no key for; 502 holds Left and
    // Right together, which it has no *answer* for. Both have to be reported
    // rather than approximated, and the first one wins `first_unsupported`.
    const held_bytes = [3]u8{ 0x10, 0x08, 0x30 };

    const Row = struct {
        fn put16(buf: []u8, at: usize, v: u16) void {
            std.mem.writeInt(u16, buf[at..][0..2], v, .little);
        }
    };
    for (0..n) |k| {
        const at = k * rb;
        Row.put16(&rows, at + gb_trace.offsetOf("samus_x"), @intCast(0x0640 + k));
        Row.put16(&rows, at + gb_trace.offsetOf("samus_y"), @intCast(0x07D0 + k * 2));
        Row.put16(&rows, at + gb_trace.offsetOf("camera_x"), 0x0600);
        Row.put16(&rows, at + gb_trace.offsetOf("camera_y"), 0x07C0);
        rows[at + gb_trace.offsetOf("pose")] = 0x03;
        rows[at + gb_trace.offsetOf("facing")] = 0x01;
        rows[at + gb_trace.offsetOf("pad")] = held_bytes[k];
        rows[at + gb_trace.offsetOf("counter")] = @intCast(0x80 + k);
        rows[at + gb_trace.offsetOf("water")] = 0;
    }

    var snap: gb_trace.Snapshot = .{
        .frame = 499,
        .origin = 500,
        .frames = @intCast(n),
        .scx = 0x40,
        .scy = 0x10,
        .via = .video_ram,
        .solid = 0x64,
        .map_bank = 0x0F,
        .warp_bank = 0x0F,
        .screen_row = 0x07,
        .screen_col = 0x06,
        .pixel_y = 0xD4,
        .pixel_x = 0x48,
        .camera_x = 0x0640,
        .camera_y = 0x07C0,
        .tiles = @splat(0x2A),
        .blocks = @splat(0),
        .coltab = @splat(0x11),
    };
    snap.tiles[7] = 0x5B;
    snap.coltab[3] = 0x99;

    var refs = [_]gb_trace.Reference{.{
        .snapshot = snap,
        .pass = .{
            .first = 500,
            .stride = 1,
            .offset = gb_trace.input_offset,
            .frames = n,
            .frames_run = 600,
            .polls = 600,
            .code = 0,
            .rows = rows[0 .. n * rb],
            .game_save = &.{},
            .backing = &.{},
        },
    }};
    const pass: gb_trace.RefsPass = .{
        .refs = &refs,
        .frames_run = 600,
        .polls = 600,
        .code = 0,
        .game_save = &.{},
        .backing = &.{},
    };

    var inputs: [504]u8 = @splat(0);
    for (held_bytes, 0..) |h, k| inputs[500 + k] = h;

    const anchors = [_]Anchor{
        .{ .origin = 500, .frames = n, .handover = 474 },
        // A stretch the replay never reached: absent from the pass, so null
        // rather than a reference full of zeros.
        .{ .origin = 9000, .frames = 8, .handover = 474 },
    };

    const got = try referencesFromTrace(testing.allocator, &inputs, pass, &anchors, 474);
    defer {
        for (got) |*maybe| {
            if (maybe.*) |*mr| mr.deinit(testing.allocator);
        }
        testing.allocator.free(got);
    }

    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expect(got[1] == null);
    const mr = got[0].?;

    // The placement is `room.placement`'s six bytes, and `Settled.cell` and
    // `position` are what a cart's boot record is built from.
    try testing.expectEqual(@as(u8, 0x76), mr.settled.cell());
    try testing.expectEqual(@as(u16, 0x0648), mr.settled.position().x);
    try testing.expectEqual(@as(u16, 0x07D4), mr.settled.position().y);
    try testing.expectEqual(@as(u8, 0x0F), mr.map_bank);
    try testing.expectEqual(@as(u32, 500), mr.origin);
    try testing.expectEqual(@as(u32, 474), mr.control);

    // The world, and the collision rule beside it. A reference carrying the
    // tilemap and not the block-type table would compare two machines walking
    // through the same picture under different rules.
    try testing.expectEqual(@as(u8, 0x5B), mr.settled.tiles[7]);
    try testing.expectEqual(@as(u8, 0x99), mr.settled.coltab[3]);
    try testing.expectEqual(@as(u8, 0x64), mr.settled.solid);
    // Set to the same read, not left zero: see `referencesFromTrace`.
    try testing.expectEqualSlices(u8, &mr.settled.tiles, &mr.settled.tiles_before);
    try testing.expectEqualSlices(u8, &mr.settled.coltab, &mr.settled.coltab_before);

    // The frames are the pass's columns, in `oracle.Frame`'s vocabulary.
    try testing.expectEqual(n, mr.settled.frames.len);
    try testing.expectEqual(@as(u16, 0x0642), mr.settled.frames[2].samus_x);
    try testing.expectEqual(@as(u16, 0x07D4), mr.settled.frames[2].samus_y);
    try testing.expectEqual(@as(u8, 0x82), mr.settled.frames[2].counter);
    try testing.expectEqual(@as(u8, 0x30), mr.settled.frames[2].pad);

    // `held[k]` is the movie's byte for the frame the row was recorded on --
    // `Pass.first + k` -- which is the frame the game acted on it. The pass
    // carries `$FF80` per frame so that is checked against the trace rather
    // than argued: here the pad column and the movie agree on all three.
    for (0..n) |k| try testing.expectEqual(inputs[500 + k], mr.held[k]);
    for (0..n) |k| try testing.expectEqual(mr.settled.frames[k].pad, mr.held[k]);
    try testing.expectEqual(movieKey(0x10), mr.keys[0]);
    // Both directions comes back as neither, rather than as a guess.
    try testing.expectEqual(key.none, mr.keys[2]);
    try testing.expectEqual(@as(?usize, 1), mr.first_unsupported);
    try testing.expectEqual(@as(u8, 0x08), mr.unsupported_bits);
}

test "a pass is packed to the byte, and a stretch too long for one is capped" {
    const a = testing.allocator;
    var batch: std.ArrayList(gb_trace.Stretch) = .empty;
    defer batch.deinit(a);

    // Four short stretches share one pass: 4 * 1 560 of snapshot leaves 676
    // frames between them, and these want 400.
    const small = [_]Anchor{
        .{ .origin = 100, .frames = 100, .handover = 100 },
        .{ .origin = 300, .frames = 100, .handover = 300 },
        .{ .origin = 500, .frames = 100, .handover = 500 },
        .{ .origin = 700, .frames = 100, .handover = 700 },
    };
    try testing.expectEqual(@as(usize, 4), try planPass(a, &small, 0, &batch));
    try testing.expectEqual(@as(usize, 4), batch.items.len);
    for (batch.items, small) |st, an| try testing.expectEqual(an.frames, st.frames);
    try testing.expect(gb_trace.refsFit(batch.items));

    // **The any% sweep's own first stretch is 1 372 frames**, which is longer
    // than the 850 one pass holds. It is capped rather than dropped, and the
    // batch ends on it: 850 frames honestly graded is a smaller claim, and
    // 1 372 frames of a reference that only has 850 is not a claim at all.
    const long = [_]Anchor{
        .{ .origin = 721, .frames = 1372, .handover = 721 },
        .{ .origin = 2094, .frames = 289, .handover = 2094 },
    };
    try testing.expectEqual(@as(usize, 1), try planPass(a, &long, 0, &batch));
    try testing.expectEqual(@as(usize, 1), batch.items.len);
    try testing.expectEqual(@as(u32, 850), batch.items[0].frames);
    try testing.expect(gb_trace.refsFit(batch.items));
    // And the next pass picks up where it stopped rather than losing it.
    try testing.expectEqual(@as(usize, 2), try planPass(a, &long, 1, &batch));
    try testing.expectEqual(@as(u32, 289), batch.items[0].frames);

    // A stretch with no frame before it has nothing to snapshot, and one with
    // no frames is a snapshot nobody grades against. Both stop the batch where
    // they are, which is how `take` comes to leave them null.
    const bad = [_]Anchor{
        .{ .origin = 0, .frames = 10, .handover = 0 },
        .{ .origin = 10, .frames = 0, .handover = 10 },
    };
    try testing.expectEqual(@as(usize, 0), try planPass(a, &bad, 0, &batch));
    try testing.expectEqual(@as(usize, 0), batch.items.len);
    try testing.expectEqual(@as(usize, 1), try planPass(a, &bad, 1, &batch));
    try testing.expectEqual(@as(usize, 0), batch.items.len);

    // Every packing is one the emulator will accept: the region is a hard
    // ceiling, and `runRefs` refuses anything over it rather than truncating.
    var many: [40]Anchor = undefined;
    for (&many, 0..) |*an, i| an.* = .{
        .origin = @intCast(1000 + i * 500),
        .frames = 400,
        .handover = @intCast(1000 + i * 500),
    };
    var at: usize = 0;
    var passes: usize = 0;
    var frames: usize = 0;
    while (at < many.len) {
        const next = try planPass(a, &many, at, &batch);
        try testing.expect(next > at);
        try testing.expect(gb_trace.refsFit(batch.items));
        for (batch.items) |st| frames += st.frames;
        passes += 1;
        at = next;
    }
    // Forty 400-frame stretches do not fit in one pass, and the sweep is
    // honest about how many it capped: the packing keeps every frame it can.
    try testing.expect(passes > 1);
    try testing.expect(frames <= passes * gb_trace.refFramesBudget(1));
}





test "the fade grades every frame, the normal ones at full brightness" {
    const n = palette_normal;
    var ref = [_]Frame{
        .{ .samus_x = 0, .samus_y = 0, .camera_x = 0, .camera_y = 0, .bg_palette = n },
        .{ .samus_x = 0, .samus_y = 0, .camera_x = 0, .camera_y = 0, .bg_palette = 0xE7 },
        .{ .samus_x = 0, .samus_y = 0, .camera_x = 0, .camera_y = 0, .bg_palette = 0xFF },
        .{ .samus_x = 0, .samus_y = 0, .camera_x = 4, .camera_y = 0, .bg_palette = 0xFF },
        .{ .samus_x = 0, .samus_y = 0, .camera_x = 4, .camera_y = 0, .bg_palette = 0xFB },
        .{ .samus_x = 0, .samus_y = 0, .camera_x = 4, .camera_y = 0, .bg_palette = n },
        .{ .samus_x = 0, .samus_y = 0, .camera_x = 4, .camera_y = 0, .bg_palette = n },
    };
    const rows = try fadeRows(testing.allocator, &ref);
    defer testing.allocator.free(rows);
    // Step 24b: the normal frames too, including the ones a scrolling
    // door's script spends at $93, which used to go ungraded.
    try testing.expectEqual(ref.len, rows.len);
    const want = [_]u8{ 15, 10, 0, 0, 5, 15, 15 };
    for (rows, want, 0..) |r, w, k| {
        try testing.expectEqual(k, r.index);
        try testing.expectEqual(w, r.want);
    }
    // Only frame 3 is dark *and* moved the camera.
    try testing.expectEqual(@as(usize, 1), darkScrollFrames(&ref, rows));
    // A palette the table does not know is refused rather than guessed.
    ref[2].bg_palette = 0x12;
    try testing.expectError(Error.UnknownPalette, fadeRows(testing.allocator, &ref));
}

test "the fade's codes fit between the frame-phase code and the setup's" {
    try testing.expect(code_fade > code_frame_phase);
    // 13 since 1.0 Step 7, which took the last of the fourteen for the setup.
    try testing.expectEqual(@as(usize, 13), codes_fade);
    try testing.expect(code_setup < code_position);
    // Every frame of the take is graded since Step 24b; its last bucket must
    // still be a fade code.
    const per = fadePerCode(movie_gate_frames);
    try testing.expect(code_fade + (movie_gate_frames - 1) / per < code_setup);
}

test "a take over another reference keeps what the cart is given before it" {
    const pads = [_][]const u8{ "l = true", "" };
    const pokes = [_]Poke{.{ .addr = 1, .value = 2 }};
    var t = Take.of(&.{}, &.{});
    t.pokes = &pokes;
    t.setup = &pads;
    t.setup_items = 0x02;
    t.setup_nmis = 3;
    const frames = [_]Frame{.{ .samus_x = 0, .samus_y = 0, .camera_x = 0, .camera_y = 0 }} ** 5;
    const keys = [_]Key{key.none} ** 5;
    const u = t.over(frames[0..4], keys[0..4]);
    try testing.expectEqual(@as(usize, 4), u.ref.len);
    try testing.expectEqual(perCode(4), u.per_code);
    try testing.expectEqual(@as(usize, 1), u.pokes.len);
    try testing.expectEqual(@as(usize, 2), u.setup.len);
    try testing.expectEqual(@as(u8, 0x02), u.setup_items);
    try testing.expectEqual(@as(usize, 3), u.setup_nmis);
}

test "the menu's setup for each loadout item: the chord, SAMUS, its row, the chord" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const items = @import("items.zig");
    const chord = "l = true, r = true, start = true";
    // The rows `scenario.Row` puts each on: Hi-Jump 1, Space Jump 3, Spring
    // Ball 4.
    const rows = [_]usize{ 1, 3, 4 };
    for (loadout_segments, rows) |seg, row| {
        const bit = (try items.bitFor(rom, seg.item)).?;
        const pads = try menuSetup(a, rom, @as(u8, 1) << bit, null);
        defer a.free(pads);
        // chord, A, `row` Downs and A, each followed by nothing; the chord.
        try testing.expectEqual(2 * (2 + row + 1) + 1, pads.len);
        try testing.expectEqualStrings(chord, pads[0]);
        try testing.expectEqualStrings("a = true", pads[2]);
        for (0..row) |k| try testing.expectEqualStrings("down = true", pads[4 + 2 * k]);
        try testing.expectEqualStrings("a = true", pads[4 + 2 * row]);
        for (pads[0 .. pads.len - 1], 0..) |p, k| if (k % 2 == 1) try testing.expectEqualStrings("", p);
        try testing.expectEqualStrings(chord, pads[pads.len - 1]);
    }
    // A bit no SAMUS row sets has no setup.
    try testing.expectError(Error.NoMenuRow, menuSetup(a, rom, 0x80, null));
    // The plasma: Down to the beam row, seven, and Right four times through
    // ice, wave and spazer to it.
    const pads = try menuSetup(a, rom, 0, try beamValue(rom, .plasma));
    defer a.free(pads);
    try testing.expectEqual(2 * (2 + 7 + 4) + 1, pads.len);
    for (0..7) |k| try testing.expectEqualStrings("down = true", pads[4 + 2 * k]);
    for (0..4) |k| try testing.expectEqualStrings("right = true", pads[18 + 2 * k]);
}

test "the seeding fixture passes on one catch, and its pins catch drift (1.0 Step 18c2)" {
    // As measured at `13a4736`: the four catches and 168 frames.
    const at = [_]SeedRow{
        .{ .anchor = 10034, .with = 1, .without = 1 },   .{ .anchor = 10327, .with = 22, .without = 11 },
        .{ .anchor = 10350, .with = 0, .without = 0 },   .{ .anchor = 10390, .with = 25, .without = 10 },
        .{ .anchor = 10464, .with = 1, .without = 1 },   .{ .anchor = 10491, .with = 0, .without = 0 },
        .{ .anchor = 10533, .with = 0, .without = 0 },   .{ .anchor = 10620, .with = 0, .without = 0 },
        .{ .anchor = 10676, .with = 0, .without = 0 },   .{ .anchor = 10791, .with = 40, .without = 40 },
        .{ .anchor = 10832, .with = 25, .without = 10 }, .{ .anchor = 10866, .with = 0, .without = 0 },
        .{ .anchor = 10976, .with = 10, .without = 10 }, .{ .anchor = 11010, .with = 0, .without = 0 },
        .{ .anchor = 11567, .with = 33, .without = 0 },  .{ .anchor = 11625, .with = 11, .without = 11 },
        .{ .anchor = 11637, .with = 0, .without = 0 },
    };
    const v = gradeSeeding(&at, &seeding_catches, seeding_frames_floor);
    try testing.expect(v.ok());
    try testing.expect(!v.raise());
    try testing.expectEqual(@as(usize, 4), v.caught);
    try testing.expectEqual(@as(usize, 17), v.run);

    // The rule the pins replace would have failed this: 13 of 17 play the same.
    try testing.expect(v.caught != v.run);

    // A catch lost fails and names its anchor, even with three still catching.
    var drift = at;
    drift[14].without = 33;
    const d = gradeSeeding(&drift, &seeding_catches, seeding_frames_floor);
    try testing.expect(!d.ok());
    try testing.expectEqual(@as(usize, 1), d.n_lost);
    try testing.expectEqual(@as(u32, 11567), d.lost[0]);

    // A frame lost fails on the floor, though every catch holds.
    var shorter = at;
    shorter[9].with = 39;
    shorter[9].without = 39;
    try testing.expect(!gradeSeeding(&shorter, &seeding_catches, seeding_frames_floor).ok());

    // A gain passes and asks for the pin to be raised.
    var more = at;
    more[12].without = 3;
    const g = gradeSeeding(&more, &seeding_catches, seeding_frames_floor);
    try testing.expect(g.ok() and g.raise());
    try testing.expectEqual(@as(u32, 10976), g.gained[0]);

    // No catch at all fails, whatever the pins say.
    try testing.expect(!gradeSeeding(at[0..1], &.{}, 0).ok());
}

test "the recording's worlds pin names a new miss, and asks to be raised (1.0 Step 18c2)" {
    const a = testing.allocator;
    const pin = try parseWorldPin(a, world_misses_pin);
    defer a.free(pin);
    // 953 visits with a window: 599 explained at 18c, 641 with the lava
    // replayed at each visit's count (18d), 663 on the committed crawler's
    // crawl with the first arrival taken (release Step 0).
    try testing.expectEqual(@as(usize, 953 - 663), pin.len);

    // The run the pin was taken from passes, and asks for nothing.
    const same = try gradeWorlds(a, pin, pin);
    try testing.expect(same.ok() and !same.raise());
    a.free(same.lost);
    a.free(same.gained);

    // A new miss fails, and is the one named.
    const extra = try a.alloc(Visit, pin.len + 1);
    defer a.free(extra);
    @memcpy(extra[0..pin.len], pin);
    extra[pin.len] = .{ .bank = 0xF, .cell = 0x00, .count = 0xFF };
    const d = try gradeWorlds(a, extra, pin);
    defer a.free(d.lost);
    defer a.free(d.gained);
    try testing.expect(!d.ok());
    try testing.expectEqual(@as(usize, 1), d.lost.len);
    try testing.expectEqual(extra[pin.len], d.lost[0]);

    // A listed miss explained passes, and asks for the pin to be raised.
    const g = try gradeWorlds(a, pin[1..], pin);
    defer a.free(g.lost);
    defer a.free(g.gained);
    try testing.expect(g.ok() and g.raise());
    try testing.expectEqual(pin[0], g.gained[0]);

    try testing.expectError(error.BadPin, parseWorldPin(a, "B 5A\n"));
}
