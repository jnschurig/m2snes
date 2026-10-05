//! The residue audit: what the game's opening leaves in Game Boy state that
//! the cart's boot record does not establish, and whether the port reads it.
//!
//! Step 15b's movie oracle skips the opening. It cannot do otherwise -- the
//! port has no title screen and no scripted landing -- so it seeds a boot
//! record from where the *game* left Samus and starts comparing from the frame
//! control is handed over. That is the right anchor, and it carries an
//! assumption that was never checked: that the 318 frames of opening leave
//! behind nothing else the physics reads.
//!
//! They do not. `$FF97`, the frame counter `samus_walkRight` takes its 1/2 walk
//! alternation from, reads $46 at the handover; the cart's own counter used to
//! start at zero and be advanced only by its NMI. Neither counter is ported,
//! but their *parity* is, and the port had no way to arrive at the reference's
//! except by accident. The accident held for 131 frames of the published run
//! and then walked her one pixel into a frame the game walked two. Boot record
//! version 5 seeds the phase from the measurement, which is the audit's first
//! finding to be closed by the thing it found rather than by the fix for
//! something else.
//!
//! ## What this file is, and what it deliberately is not
//!
//! It is two things joined by a table:
//!
//!   - **A static read of `engine/main.asm`.** `sites` finds every routine that
//!     reads or writes a direct-page variable. That is what turns "the port
//!     reads it" from a remark into a claim a scan can refute, and the table's
//!     `readers` list is checked against it by a test. A variable nothing reads
//!     is the audit's cheapest possible finding: whatever the opening left in
//!     it cannot matter, and that much of the opening never has to be
//!     reproduced.
//!   - **A measurement of the Game Boy at the handover.** For the variables
//!     whose Game Boy counterpart this repository has actually pinned, the
//!     value the movie leaves is read out of the machine that ran the movie and
//!     set beside the value the boot record establishes.
//!
//! It is *not* a claim that every difference it lists explains a divergence,
//! and it does not invent a Game Boy address for a variable that has none. Half
//! the engine's carried state has no pinned counterpart; the audit reports that
//! as `unmeasured` rather than guessing, because a guessed address is how Steps
//! 14 and 15 spent three sessions comparing the wrong pair of bytes.

const std = @import("std");
const oracle = @import("oracle.zig");
const tas = @import("tas.zig");
const snes_screen = @import("snes_screen.zig");
const map_mod = @import("map.zig");
const testrom = @import("testrom");

/// `engine/main.asm` itself. The assembled image and its symbol file are
/// already embedded next door for `snes_inject`; the source is here because
/// what a routine *does* with a variable is not in either of them.
pub const engine_source = @embedFile("engine_asm");

// ---- Reading the engine's source -------------------------------------------

/// How a line touches a variable. `modify` is the read-modify-write group --
/// `inc !SpinTimer` both reads and writes, and calling it either one alone
/// would make a carried variable look like scratch or the reverse.
pub const Touch = enum { read, write, modify };

pub const Site = struct {
    routine: []const u8,
    line: usize,
    touch: Touch,
};

const write_ops = [_][]const u8{ "sta", "stx", "sty", "stz" };
const modify_ops = [_][]const u8{ "inc", "dec", "asl", "lsr", "rol", "ror", "tsb", "trb" };
/// Lines that name a variable as *data* rather than reading it. `BootSeed` is
/// the whole reason this exists: `db !MapIndex` puts the address in a table, and
/// counting it as a read would credit the boot seeder with reading three
/// variables it only names.
const data_ops = [_][]const u8{ "db", "dw", "dl" };

/// The mnemonic with any explicit-width suffix removed: asar writes `sta.w`,
/// `lda.b` and `jml.l` where the size cannot be inferred, and the suffix is a
/// property of the operand rather than of the operation. See the test named
/// "a store with an explicit width is still a store" for what leaving it on
/// cost.
fn mnemonic(op: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, op, '.')) |dot| return op[0..dot];
    return op;
}

fn opIn(op: []const u8, set: []const []const u8) bool {
    const m = mnemonic(op);
    for (set) |s| if (std.ascii.eqlIgnoreCase(m, s)) return true;
    return false;
}

/// Every place `engine/main.asm` touches `!<define>`, with the routine it is in.
///
/// A routine is the last label in column zero, which is how the file is
/// written: `HandlePose:` at the margin, `.release` and `+` indented under it.
pub fn sites(allocator: std.mem.Allocator, define: []const u8) ![]Site {
    var out: std.ArrayList(Site) = .empty;
    errdefer out.deinit(allocator);

    var routine: []const u8 = "-";
    var lines = std.mem.splitScalar(u8, engine_source, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        const code = if (std.mem.indexOfScalar(u8, raw, ';')) |c| raw[0..c] else raw;
        if (code.len == 0) continue;

        // A label in column zero renames the current routine.
        if (code[0] != ' ' and code[0] != '\t') {
            if (std.mem.indexOfScalar(u8, code, ':')) |c| {
                if (c > 0) routine = code[0..c];
            }
        }

        // Local labels share the line with the instruction they precede, so
        // the opcode is not always at the start. Without this, `+ sta !Hit`
        // has `+` for its opcode and is classified a *read* -- nine sites in
        // `engine/main.asm` as of 2026-09-01, found while adding `poseArms`.
        const body = stripLocalLabel(std.mem.trim(u8, code, " \t\r"));
        if (body.len == 0) continue;

        // `!Foo = $12`, `VarFoo = !Foo`, `ConstFoo = !FOO`: a definition or an
        // alias, not a use. Both sides are skipped, which is why the export
        // block does not make every variable look read.
        if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
            const lhs = std.mem.trim(u8, body[0..eq], " \t");
            if (lhs.len != 0 and std.mem.indexOfAny(u8, lhs, " \t") == null) continue;
        }

        var first_end: usize = 0;
        while (first_end < body.len and body[first_end] != ' ' and body[first_end] != '\t') first_end += 1;
        const op = body[0..first_end];
        if (opIn(op, &data_ops)) continue;

        if (!mentions(body, define)) continue;

        const touch: Touch = if (opIn(op, &write_ops))
            .write
        else if (opIn(op, &modify_ops))
            .modify
        else
            .read;
        try out.append(allocator, .{ .routine = routine, .line = lineno, .touch = touch });
    }
    return out.toOwnedSlice(allocator);
}

/// `!Name` as a whole word. `!Cam` must not match `!CamX`, and `!SamusX` must
/// not match inside `!SamusXSomething` if one is ever added.
fn mentions(body: []const u8, define: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, body, i, '!')) |at| {
        i = at + 1;
        if (at + 1 + define.len > body.len) continue;
        if (!std.mem.eql(u8, body[at + 1 ..][0..define.len], define)) continue;
        const after = at + 1 + define.len;
        if (after < body.len) {
            const c = body[after];
            if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        }
        return true;
    }
    return false;
}

/// The two routines that dispatch on `!Pose`, which must offer the same set.
///
/// Adding a pose to the game means adding it in two places -- the pose machine
/// and the drawing code -- because the original keeps them as two separate
/// tables (00:$0D4B and 01:$4C1D, the latter reached by `RST $28`). Nothing
/// checked that our two agreed, and on 2026-09-01 they did not: the morph ball
/// landed with a `HandlePose` arm and no `SamusSpriteId` arm, and the cart drew
/// a standing, front-facing Samus who could still roll. A player found it; the
/// gate could not.
pub const pose_dispatches = [_][]const u8{ "HandlePose", "SamusSpriteId" };

/// Drop asar's anonymous local labels from the front of a statement.
///
/// `+`, `-`, `++` and friends sit in column zero and share the line with the
/// instruction: `+       cmp.w #!POSE_RUN`. Every dispatch arm after the first
/// is written that way, so a scan that reads the instruction off the start of
/// the line sees ten of eleven arms as unlabelled text. Measured: without this,
/// `HandlePose` scanned as one arm rather than eleven.
fn stripLocalLabel(body: []const u8) []const u8 {
    var i: usize = 0;
    while (i < body.len and (body[i] == '+' or body[i] == '-')) i += 1;
    if (i == 0) return body;
    return std.mem.trim(u8, body[i..], " \t\r");
}

/// The `!POSE_*` names a routine compares against, sorted and deduplicated.
///
/// Scoped to one routine rather than scanning the file, because `cmp.b
/// #!POSE_*` also appears inside pose *handlers* -- `PoseJumpStart` tests
/// `!POSE_NJUMPSTART` to tell its two entries apart -- and those are not
/// dispatch arms. Column-zero labels are what bound a routine, the same rule
/// `sites` uses.
pub fn poseArms(allocator: std.mem.Allocator, routine_label: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);

    var routine: []const u8 = "-";
    var lines = std.mem.splitScalar(u8, engine_source, '\n');
    while (lines.next()) |raw| {
        const code = if (std.mem.indexOfScalar(u8, raw, ';')) |c| raw[0..c] else raw;
        if (code.len == 0) continue;
        if (code[0] != ' ' and code[0] != '\t') {
            if (std.mem.indexOfScalar(u8, code, ':')) |c| {
                if (c > 0) routine = code[0..c];
            }
        }
        if (!std.mem.eql(u8, routine, routine_label)) continue;

        const body = stripLocalLabel(std.mem.trim(u8, code, " \t\r"));
        // `cmp.b` and `cmp.w` both: the pose machine compares 16-bit and the
        // drawing code 8-bit, which is an accumulator-width difference and not
        // a difference in the set they offer.
        if (!std.mem.startsWith(u8, body, "cmp.b ") and !std.mem.startsWith(u8, body, "cmp.w ")) continue;
        const hash = std.mem.indexOfScalar(u8, body, '#') orelse continue;
        const arg = std.mem.trim(u8, body[hash + 1 ..], " \t\r");
        if (arg.len < 2 or arg[0] != '!') continue;
        const name = arg[1..];
        if (!std.mem.startsWith(u8, name, "POSE_")) continue;
        // A name with anything after it -- `!POSE_RUN|$80` -- is a composed
        // value rather than a plain arm. `!POSE_TURN` is defined that way and
        // is dispatched on by neither.
        if (std.mem.indexOfAny(u8, name, " \t|+-&") != null) continue;

        for (out.items) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else try out.append(allocator, name);
    }

    const owned = try out.toOwnedSlice(allocator);
    std.mem.sort([]const u8, owned, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return owned;
}

/// The distinct routines that read (or read-modify-write) a variable, sorted.
pub fn readers(allocator: std.mem.Allocator, define: []const u8) ![]const []const u8 {
    const all = try sites(allocator, define);
    defer allocator.free(all);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (all) |s| {
        if (s.touch == .write) continue;
        var seen = false;
        for (out.items) |o| if (std.mem.eql(u8, o, s.routine)) {
            seen = true;
            break;
        };
        if (!seen) try out.append(allocator, s.routine);
    }
    const slice = try out.toOwnedSlice(allocator);
    std.mem.sort([]const u8, slice, {}, lessName);
    return slice;
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ---- The table --------------------------------------------------------------

/// Where the cart's value comes from when `MainLoop` runs for the first time.
pub const Establishes = enum {
    /// The injector writes it into the boot record and `InitState` seeds it.
    boot_record,
    /// `InitState` writes a constant or derives it from another seeded field.
    init_state,
    /// `RunBootScript` or `ResolvePhysics` leaves it, per room.
    boot_script,
    /// Nothing writes it. `Reset` clears all of WRAM, so it is zero.
    zeroed,
};

/// Whether the value a frame begins with can be observed by that frame.
pub const Carry = enum {
    /// Some routine reads it before anything in the frame writes it, so what
    /// it starts at is part of the port's behaviour.
    carried,
    /// Written before read on every frame. Whatever it held is unobservable,
    /// and the opening leaving something in it costs nothing.
    scratch,
    /// No routine reads it at all.
    unread,
};

/// Which measured quantity, if any, gives this variable's Game Boy value at the
/// handover. Only the counterparts this repository has actually pinned appear
/// here; see the file comment for why the rest are left `null`.
pub const Measure = enum {
    samus_x,
    samus_y,
    camera_x,
    camera_y,
    pose,
    facing,
    input_pressed,
    frame_count,
    water,
    map_index,
    cell,
    solid,
};

pub const Field = struct {
    /// The engine define, without the `!`.
    define: []const u8,
    establishes: Establishes,
    carry: Carry,
    measure: ?Measure = null,
    /// Routines that read it, checked against `readers` by a test.
    reads: []const []const u8,
    note: []const u8,
};

/// Every direct-page variable that holds game state across a frame boundary, or
/// that a physics routine reads.
///
/// The boot script's own scratch (`!Blob`, `!Script`, `!Col`, `!Row` and the
/// rest of `RunBootScript`'s working set) is not here: it is written and read
/// inside one call, never spans a frame, and cannot carry residue.
pub const fields = [_]Field{
    .{
        .define = "FrameCount",
        .establishes = .boot_record,
        .carry = .carried,
        .measure = .frame_count,
        .reads = &.{ "AdjustHudValues", "ApplyDamageAcid", "ApplyDamageLarva", "ApplyDamageStomach", "CreditsMoveStars", "CreditsScroll", "CreditsStates", "DeathErase", "DrawHudMetroid", "DrawSamus", "EarthquakeAdjustScroll", "EnAiArachnus", "EnAiArachnusFireball", "EnAiBlobThrower", "EnAiItemOrb", "HandleEnemies", "HandleProjectiles", "IgtTick", "InitState", "MainLoop", "NMI", "PausedFrame", "PoseJumpStart", "PoseSpinJump", "QuakeCountdown", "QueenHandler", "QueenMoveNeck", "QueenRoarTick", "SamusShoot", "SamusSpriteId", "SaveStation", "StreamDue", "TitleDraw", "TransitionCamera", "VariaAnimNmi", "WalkSpeed" },
        .note = "**The audit's finding, and boot record version 5 is the fix.** Nothing but NMI writes it, and three of its readers are physics: `WalkSpeed` takes `(n & 1) + 1` as the walk step, `PoseJumpStart` takes `(n & 2) >> 1` off the jump's initial rise, and `PoseSpinJump` gates a held Up on `(n & 3)`. The Game Boy's counterpart is $FF97 and the original reads it the same way at 00:$1C25. The port's counter used to start from its own reset while the reference's had run the whole opening, so their phase agreed only by accident -- and the accident ran out at reference frame 131, where the movie oracle walked her one pixel into a frame the game walked two. `BootFrameCount` carries the measured phase now and this row agrees. Step 7 added a sixth reader that is not physics: `SamusSpriteId` takes `(n & 3)` to skip Samus's draw on one frame in four during the appearance sequence, which is the flicker she arrives out of. B4b adds two more, and neither is physics either: `DrawSamus` takes `(n & 4)` for the four-on four-off blink of Samus's i-frames, and `ApplyDamageLarva` takes `(n & 7)` so a health-draining enemy takes three units every eighth frame rather than every one. And a tenth reader that is not physics either and is *about* this row: `MainLoop` checks on its first frame that the counter is the record's seed plus exactly one, because that is the invariant the seed is computed from and nothing outside the engine can measure it. See `FramePhase`. And Step 12b adds two more, one of which is the sharpest use of the parity in the game: `HandleProjectiles` asks the tilemap what a beam is flying through only on odd frames, so **terrain collision runs at 30 Hz while enemy collision runs at 60** -- and a port whose counter had the wrong parity would sample the world on the frames the original does not. `SamusShoot` takes `(n & $10)` for the wave beam's starting phase, which is a coarser use of the same counter. Step 13d's `HandleEnemies` takes `(n & 1)` for the post-death timer (02:$4041), which climbs on even frames only. Step 15c's `DeathErase` takes `(n & 3)` in NMI, before the increment, for the death's erase every fourth frame (00:$2FE9). Step 22's `ApplyDamageAcid` takes `(n & $0F)`: acid bites every sixteenth frame (00:$2F4B). Step 24h's `TitleDraw` takes `(n & $0C)` for the title cursor's frame (05:$4190), on the title, before any record has seeded it: the title's own count from `Reset`, which the `title` rung grades against the Game Boy's `frameCounter` frame for frame. 1.0 Step 2a adds two. `PausedFrame` takes `(n & $10)` for the pause's flash (00:$2CEF). And `InitState` now reads it too: through the title the record's zero is not the seed, the title's count carried on is (`!TITLE_FC_LEAD`), because the Game Boy's counter is cleared at power-on and never again. Until then the cart's counter restarted at a new game and its phase against the Game Boy's was whatever the title's length made it; the `pause` rung's code 120 found it through the flash, and grades it. 1.0 Step 19b: the Queen's neck retracts on odd frames (03:$73B1) and her hurt flash runs one frame in four (03:$6E4A); the Queen oracle hands the Game Boy's phase across at her entry. 1.0 Step 20a's `ApplyDamageStomach` takes `(n & 7)` and `(n & $0F)`: the stomach's acid sounds every eighth frame and bites every sixteenth (00:$2F29). 1.0 Step 22: the credits read it as the Game Boy's `frameCounter`, one a pass -- the scroll and the stars move on `(n & 3)` (05:$595D, $55E1), the spins draw `(n & 3) + 4` (05:$5784) and her hair waves on `(n & $10)` (05:$5658) -- and the setup's pass turns NMI off for the frames the Game Boy's LCD is off, so the counter takes one step across it, as the Game Boy's does.",
    },
    .{
        .define = "MapIndex",
        .establishes = .boot_record,
        .carry = .carried,
        .measure = .map_index,
        .reads = &.{ "LoadCellFlags", "LoadScreen", "LoadScreenPri", "PeekScreen", "Readout", "ResetEntities", "SpawnListAt", "StartTransition", "StreamResolve" },
        .note = "Seeded from the record the movie oracle builds out of $D811, so this is a difference the oracle already closes. Since Step 5 it is also *written* by a transition -- `WARP` puts the destination bank here, which is what stops the record being the only thing that decides which map the cart is in. Step 9 gave it a sixth reader: `SpawnListAt` turns it into the `(bank - 9) * 256` base of the enemy pointer table, which is the same 7 x 256 geometry `offsets.zig` derives the table's size from. Step 15a adds `ResetEntities`, which names the spawn flags' save window by it. Step 24e adds `LoadScreenPri` (00:$3ED5), which reads bit 11 of the transition word of Samus's screen out of this bank's cells.",
    },
    .{
        .define = "Cell",
        .establishes = .boot_record,
        .carry = .carried,
        .measure = .cell,
        .reads = &.{ "DoorEnterQueen", "LatchCell", "LoadCellFlags", "LoadScreen", "Readout", "StartTransition" },
        .note = "Same: the record carries the cell the game left her standing in, not one we chose. Written by `WARP` as well since Step 5 -- the destination cell comes out of the opcode's operand rather than being derived from the camera by `LatchCell`, which is what lets the scroll flags be re-read on the transition frame itself.",
    },
    .{
        .define = "TileTable",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{ "LoadMetaBase", "Readout" },
        .note = "Left by the replayed door script. (`Readout`, Step 14's playtest aid, only displays it.) The Game Boy keeps the same selection somewhere unpinned; `compareWorlds` grades the result rather than the variable, which is the stronger check and the reason this one is not urgent. **Its one reader moved in Step 6 and that was a defect being fixed, not a refactor.** `LoadScreen` read it and derived `!Meta` from it, and `LoadScreen` runs once, at boot -- so a `TILETABLE` mid-run changed this byte and changed nothing else, and every metatile drawn afterwards came out of the table the cart booted with. `LoadMetaBase` is the derivation given a name, and the opcode calls it.",
    },
    .{
        .define = "Scroll",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"HandleCamera"},
        .note = "The cell's scroll-permission flags, reloaded by `LoadCellFlags` whenever the cell changes. Established per room rather than carried out of an opening.",
    },
    .{
        .define = "TransDir",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "HandleCamera", "MainLoop", "TransitionCamera", "TryPausing", "WarpDraw" },
        .note = "$D00E, and **the variable Step 5 listed as unread on purpose so that Step 5b would have to come back to this row.** Step 5's four triggers write it -- 1 right, 2 left, 4 up, 8 down, each from the edge of the same name in `HandleCamera` -- and nothing read it, because what reads it is the arrangement of column and row draws in `handleWarp`'s four arms. Step 5b gave it its first reader without porting those draws, under the name `WarpWaits`: the direction was needed because a downward crossing draws four strips where the others draw three (00:$2A4F against $2939, $29C4 and $2B04), so the *duration* of a transition depends on its direction before its picture does. **Step 6 ported the draws and the routine became `WarpDraw`**, so the arrangement itself now reads this, which is what the row was waiting for. Carried, because the trigger writes it in one frame's `HandleCamera` and the interpreter reads it several frames later.",
    },
    .{
        .define = "DoorIndex",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "AudioFrame", "EnemyPass", "QueenNmi", "RunDoorScript", "RunPendingTransition", "StartDoorScript", "StatusBarDue" },
        .note = "$D08E/$D08F. Nonzero means a transition is owed, which is the test the original makes at 00:$01A0 ahead of everything else in a frame; the interpreter clears it at 00:$26DE and `RunDoorScript` does the same. It is carried by construction: a trigger sets it during one frame's `HandleCamera` and the next frame's `MainLoop` is what acts on it, so the value crossing the frame boundary is the whole point of it. `AudioFrame` (metroid2-audio Step 16a) reads it for the door's entry wait, the trigger frame's second `handleAudio` call. `QueenNmi` (1.0 Step 20) reads its low byte as the vblank handler reads `doorIndexLow` at 00:$0167: while a door runs in her room, nothing arms her list.",
    },
    .{
        .define = "TransPtr",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"StepDoorScript"},
        .note = "The script the pending transition is part-way through. 00:$23BD-$23DC copies the script into $D700 and executes it from there; the port executes it in place, so what has to survive the ninety-odd frames a crossing takes is this pointer. `!Script` could not: it is scratch, shared with the boot path, and the interpreter is now re-entered a frame at a time.",
    },
    .{
        .define = "TransY",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"StepDoorScript"},
        .note = "How far into the script the interpreter has got. The original keeps this in HL across its `HALT`s; the port has to put it somewhere a frame boundary cannot lose it.",
    },
    .{
        .define = "TransWait",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "FadeOutFrame", "RunPendingTransition", "StepDoorScript" },
        .note = "Frames the opcode just run still owes. `StepDoorScript` reads it back because the three opcodes whose cost has a runtime part -- COPY's queue drain, and the strips TILETABLE and WARP draw -- add theirs to the floor `OpExtraFrames` already put there. Step 20: `FadeOutFrame` reads it as `FADEOUT`'s countdown timer, which is the count plus 13. This is the whole of 00:$26D1, 00:$27BA and 00:$2561's waiting, turned from a blocked CPU into a counter -- see `src/transition.zig`, which grades the counts against the Game Boy opcode for opcode.",
    },
    .{
        .define = "TransRun",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "AudioFrame", "DoCopy", "RunPendingTransition" },
        .note = "Whether the script has been started. Zero means the frame the interpreter spends at 00:$23AF before it has fetched anything, which is a real frame of the transition's duration and the reason this is a flag rather than a null pointer: the pointer does not exist until that frame is already spent. `AudioFrame` (metroid2-audio Step 16a) reads it with `DoorIndex`: owed and not started is the trigger's pass just ended, whose entry wait is a second `handleAudio` call. `DoCopy` (Step 24b) reads it as \"a live crossing\": nonzero queues the copy for the next vblank, zero is the boot record's script or a load, which copy at once under their own forced blank.",
    },
    .{
        .define = "TransCls",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"StepDoorScript"},
        .note = "The CopyClass of the transfer `DoCopy` is about to make, kept because `DoCopy` consumes `!ArgClass` and the frame cost needs to know afterwards whether the length was Game Boy bytes or half of them -- and whether this is the background twin of a `spr` transfer, which the Game Boy made and paid for once.",
    },
    .{
        .define = "TransTmp",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"TransitionCamera"},
        .note = "How far the in-transition camera drags Samus this frame: one pixel on even frames and two on odd, from 00:$0BD5 and $0C0D. Written and read inside the same routine.",
    },
    .{
        .define = "RoomMode",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DebugWarp", "EnemyPass", "HandleCamera", "QuakeQueenSong", "QueenNmi", "QueenPass", "SaveStation", "StartTransition", "StatusBarDue", "StepDoorScript", "StreamDue", "TryPausing", "UpdateStatusBar" },
        .note = "$D08B. $11 is the Queen's room and is what all three of its readers test for. `ENTER_QUEEN` ($8x) writes it since 1.0 Step 6 and `WARP` masks it off again (00:$246B). 1.0 Step 20d: `EXIT_QUEEN` clears it (00:$24D4), and the quake's end tests it for $10 or more (01:$7A13). Before then it was zero for the whole slice and every branch that read it took the ordinary path, which is why porting `ENTER_QUEEN` was one opcode rather than an archaeology of everything that should have tested for it.",
    },
    .{
        .define = "Song",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{ "HandleEnemies", "PoseFaceScreen", "SaveFileToSram" },
        .note = "`currentRoomSong` ($D092): what the `SONG` opcode writes, what the room asks for, and what a Metroid's death adds $11 to. It began as a recording of the opcode and nothing else, because which audio path Phase 0c would take was an open decision (F8) -- and `InitState` seeded $FF for \"has not run\", zero being a legitimate song id. **Step 18 made it the save-file value it names.** Phase 0c landed, and the $FF was not a harmless placeholder: 00:$0EAF asks for this byte whenever it is not what is playing, that site was unported, and the restore at 02:$4051 computed $FF + $11 = $10 -- an id whose table entry is `initializeAudio.ret`. So a new game played no music at all and lost it permanently at the first Metroid kill (`docs/bug_tracker.md`, 2026-09-22). It is now seeded from `BootRoomSong` (version 14): `initialSaveFile`'s $04 for a new game, the Game Boy's measured $D092 for a handover. **Step 18 gave it its third reader**, `PoseFaceScreen`, which is that request site. Step 13d gave it the second, the kill restore, recorded off it into `!MetSong`. Step 15a adds the save record, offset $2A, which is `currentRoomSong` on the Game Boy too.",
    },
    .{
        .define = "AcidDmg",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "AcidProbe", "SaveFileToSram" },
        .note = "$D077, the acid damage the `DAMAGE` opcode carries. **Step 15a gave it its first reader**: the save record carries it (offset $27), so a load restores the room's damage with the rest of the file. **Step 22 gave it the one it exists for**: `AcidProbe` hands it to `ApplyDamageAcid` from every Samus probe that samples acid. Until then it was recorded and never applied, and acid did not hurt.",
    },
    .{
        .define = "SpikeDmg",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "SampleTile", "SaveFileToSram" },
        .note = "$D078, and the same: record offset $28 since Step 15a. 1.0 Step 25 gives it the reader it was for: `SampleTile`'s spike arm (00:$2033) makes it the hurt's damage.",
    },
    .{
        .define = "ItemGiven",
        .establishes = .init_state,
        .carry = .unread,
        .reads = &.{},
        .note = "What the `ITEM` opcode saw. B6 is what gives it a reader, and B6 is scoped to Bombs and Spider Ball by what the B11 recording actually collects. Seeded $FF for the same reason `Song` is.",
    },
    .{
        .define = "MetLess",
        .establishes = .init_state,
        .carry = .scratch,
        .reads = &.{"StepDoorScript"},
        .note = "The Metroid count `IF_MET_LESS` compares against, written and read by the one opcode. Until Step 14 the opcode recorded it and walked past; it is now compared with `MetReal` and the branch is taken at or below it (00:$254A), so the region's first gate, $46, opens on the first kill from $47. The \"two kills\" reading this note used to carry was the strictly-less one, and `transition.zig` tests it wrong.",
    },
    .{
        .define = "MetLessTo",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"StepDoorScript"},
        .note = "And the script that gate runs when taken, which becomes `DoorIndex` (00:$2552).",
    },
    .{
        .define = "Redraw",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"NMI"},
        .note = "A request to NMI, set and cleared within a frame pair. Nothing about the opening can survive in it.",
    },
    .{
        .define = "CamX",
        .establishes = .boot_record,
        .carry = .carried,
        .measure = .camera_x,
        .reads = &.{ "CameraGuideX", "CollideCentreX", "CollideSamusEnemiesHoriz", "DeriveScroll", "DoorEnterQueen", "HandleCamera", "LatchCell", "LoadEnemies", "PoseToStomach", "QueenInitialize", "QueenScroll", "SaveFileToSram", "SeedWindow", "StepDoorScript", "StreamDue", "TransitionCamera", "WarpDraw", "WriteScroll" },
        .note = "**Written by a transition since Step 5** -- `WARP` replaces the screen half and keeps the pixel half, which is what carries the camera's offset within a screen across a room change. **The audit's second finding, and the one it was not looking for. Fixed by boot record version 4.** `InitState` used to put the camera exactly on Samus, on the argument that a seeded start should be in view on frame 0. The game does not: at the handover its camera is left where the opening's own scrolling left it, which is not on her. The difference was measured rather than argued -- $FFCA/$FFCB is pinned -- and it matters because five routines read it, `HandleCamera` and `StreamDue` among them, so it decides both what is on screen and which row or column the streamer owes. It reaches the physics only through `LatchCell`, which turns a camera position into the cell `LoadCellFlags` and `LoadScreen` then draw -- so a camera off by eight pixels could not move Samus on the frame it was wrong, but it could hand her a different tilemap a screen later. `BootCamX` carries it now and this row agrees. 1.0 Step 20a: `PoseToStomach` takes `scrollX` off it as `DeriveScroll` does (00:$0DCD).",
    },
    .{
        .define = "CamY",
        .establishes = .boot_record,
        .carry = .carried,
        .measure = .camera_y,
        .reads = &.{ "CameraGuideY", "DebugWarp", "DeriveScroll", "DoorEnterQueen", "HandleCamera", "LatchCell", "LoadEnemies", "QueenInitialize", "QueenScroll", "SaveFileToSram", "SeedWindow", "StepDoorScript", "StreamDue", "TransitionCamera", "WarpDraw", "WriteScroll" },
        .note = "As `CamX`, and it was the worse of the two: the vertical camera has further to go before it settles, so the disagreement lasted longer. `BootCamY` carries it now.",
    },
    .{
        .define = "InputPressed",
        .establishes = .boot_record,
        .carry = .scratch,
        .measure = .input_pressed,
        .reads = &.{ "DeathReadPad", "DebugChord", "EnAiArachnus", "PoseBallFall", "PoseBombed", "PoseCrouch", "PoseFaceScreen", "PoseFall", "PoseJump", "PoseJumpStart", "PoseMorph", "PoseRunning", "PoseSpiderFall", "PoseSpiderJump", "PoseSpiderRoll", "PoseSpinJump", "PoseStanding", "Readout", "SamusShoot", "SamusSpriteId", "ShotDirNibble", "SoftReset", "TitleFrame", "TitleSlotStep" },
        .note = "`PublishPad` fills it from the auto-joypad read inside NMI, before `MainLoop` resumes, so every frame after the first overwrites it -- but the *first* had nothing to be filled from, and `zeroed` was this row's answer until the re-anchor measured what that cost. At a handover the game is already mid-input; a cart that starts with an empty pad loses that frame and never gets it back, which showed as the port running exactly one frame behind the original from frame 0. `BootInput` carries it now, applied on `MainLoop`'s first pass rather than in `InitState`, because enabling NMI fires one immediately and its `PublishPad` would consume the seed a frame early. Step 15c's `DeathReadPad` copies it for the death's modes, which read the pad once a pass rather than once a frame. 1.0 Step 13 adds the first reader outside Samus: `EnAiArachnus` curls Arachnus up while B is held (02:$521B `LD A,($FF80)`), which is the Game Boy's B and the port's `!PAD_FIRE`. 1.0 Step 22's `SoftReset` reads it every pass and on the title: A, B, Start and Select held reboot (00:$02E1).",
    },
    .{
        .define = "InputRisingEdge",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "DebugChord", "DebugFrame", "HandlePose", "MainLoop", "PausedFrame", "PoseBallFall", "PoseBallJump", "PoseCrouch", "PoseFall", "PoseHurt", "PoseInMouth", "PoseJump", "PoseMorph", "PoseMorphBombed", "PoseMorphHurt", "PoseRunning", "PoseSpider", "PoseSpiderFall", "PoseSpiderJump", "PoseSpiderRoll", "PoseSpinJump", "PoseStanding", "Readout", "SamusLayBomb", "SamusShoot", "SamusTryShooting", "SaveStation", "TitleFrame", "TitleSlotStep", "TryPausing" },
        .note = "Also `PublishPad`'s, and derived from the previous frame's held byte -- so the *first* graded frame sees a rising edge computed against a pad the port never read. A one-frame effect at the anchor, and the same one at every re-anchor. Step 13c adds `MainLoop`: the cutscene arm at 00:$0519 reads Select off it, the one input a frozen Samus keeps. 1.0 Step 20a: `PoseInMouth` swallows on a press of left (00:$0E26).",
    },
    .{
        .define = "SamusX",
        .establishes = .boot_record,
        .carry = .carried,
        .measure = .samus_x,
        .reads = &.{ "CameraGuideX", "CollideCentreX", "DoorEnterQueen", "EnAiFlittMoving", "HandleCamera", "LoadScreenPri", "MoveLeftBy", "MoveRightBy", "PoseBeingEaten", "PoseOutStomach", "PoseToStomach", "SamusLayBomb", "SamusShoot", "SaveFileToSram", "SavePrev", "SetTileX", "StepDoorScript", "TransitionCamera" },
        .note = "Seeded from where the game put her. This is the difference Step 15b was built to remove, and the audit records it as closed rather than assuming it. 1.0 Step 20a: the Queen's poses (`PoseBeingEaten`, `PoseToStomach`, `PoseOutStomach`) move her pixel byte alone.",
    },
    .{
        .define = "SamusY",
        .establishes = .boot_record,
        .carry = .carried,
        .measure = .samus_y,
        .reads = &.{ "CameraGuideY", "CollideSamusEnemiesDown", "DebugWarp", "DoorEnterQueen", "EnAiSeptogg", "HandleCamera", "InitState", "LoadGameState", "LoadScreenPri", "MoveVertical", "PoseBallFall", "PoseBeingEaten", "PoseFall", "PoseOutStomach", "PoseRunning", "PoseToStomach", "SamusLayBomb", "SamusShoot", "SaveFileToSram", "SavePrev", "SetTileY", "SpiderSnapRow", "StepDoorScript", "TransitionCamera" },
        .note = "As `SamusX`. 1.0 Step 20a: the Queen's poses (`PoseBeingEaten`, `PoseToStomach`, `PoseOutStomach`) move her pixel byte alone.",
    },
    .{
        .define = "PrevX",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "MoveLeftBy", "MoveRightBy" },
        .note = "`SavePrev` is the first thing `MainLoop` calls, so what it held before is never read.",
    },
    .{
        .define = "PrevY",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"MoveVertical"},
        .note = "As `PrevX`.",
    },
    .{
        .define = "Pose",
        .establishes = .boot_record,
        .carry = .carried,
        .measure = .pose,
        .reads = &.{ "AudioTick", "BombsSamusAndBG", "CollideGuard", "CollideHoriz", "CollideResolve", "CollideSamusEnemiesUp", "CollideSamusOneEnemy", "CollideTop", "DrawBombs", "EnAiOmega", "HandlePose", "HurtSamus", "LowHealthBeep", "MainLoop", "PoseBombed", "PoseJump", "PoseJumpStart", "SamusShoot", "SamusSpriteId", "SamusTryShooting", "StartTransition", "TryPausing" },
        .note = "Taken from the reference rather than forced. `movie_origin_delay` used to be the argument for forcing `stand`, and it held for exactly one anchor: every other handover in the any% run is in the ball, a fall or a jump. `BootPose` carries what was measured, and `pushToStableAnchor` is what makes the frame it was measured on one the cart can start from. `StartTransition` is the seventh reader and the odd one: 00:$0C3E rewrites a spider-ball pose to the morph ball on the way through a door, because the spider cannot survive a transition. Unreachable in the slice -- it is gated on the Queen's room -- and ported anyway. Step 13c adds `MainLoop`: the cutscene arm clears bit 7 (00:$0514), so a turnaround a Metroid interrupts finishes facing forward.",
    },
    .{
        .define = "Facing",
        .establishes = .boot_record,
        .carry = .carried,
        .measure = .facing,
        .reads = &.{ "PoseCrouch", "PoseRunning", "PoseStanding", "SamusShoot", "SamusSpriteId", "SaveFileToSram" },
        .note = "`InitState` seeded 1 unconditionally until version 6, and this row said the equality with the Game Boy at *this* anchor was worth no more than the coincidence it was, and that a run turning left before the next anchor is what would test it. The re-anchor was that run: on a stretch of the any% run where she falls leftwards, the cart booted facing right, spent frame 0 turning instead of moving, and stayed a pixel behind for the rest of the stretch. `BootFacing` carries it now.",
    },
    .{
        .define = "AirDir",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "PoseBombed", "PoseSpinJump" },
        .note = "Latched by `PoseJumpStart` at a jump's launch, and a spin jump is only reachable through that launch -- so on any frame that reads it, this frame's own jump wrote it. Carried in shape, established in practice.",
    },
    .{
        .define = "JumpArc",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "PoseBombed", "PoseJump", "PoseSpiderJump", "PoseSpinJump", "SetJumpArc" },
        .note = "The index into the rise table. `SetJumpArc` writes it on entry to every jump, so like `AirDir` it is gated by the pose that reads it.",
    },
    .{
        .define = "FallArc",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{ "PoseBallFall", "PoseFall", "PoseSpiderFall" },
        .note = "Seeded to 1, not 0: index 0 is the first frame of a fall and `InitState` is not one. Read the moment she leaves the ground, and the port has no way to know what the Game Boy's fall index was at the handover -- but at the handover she is standing, and standing writes it on the way out.",
    },
    .{
        .define = "DownSpeed",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"PoseMorph"},
        .note = "$D033: how fast the last downward move that landed was asked to go. `MoveVertical` writes it, and the ball is the only thing that reads it -- two pixels a frame or more and she bounces on arrival instead of rolling. Carried in shape and gated in practice, because the only way into the ball is `EnterMorph`, which clears it. The Game Boy's counterpart is not pinned; it does not need to be while the anchor is taken standing, since she cannot be in the ball there.",
    },
    .{
        .define = "JumpStart",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"PoseJumpStart"},
        .note = "Written by `PoseStanding` and `PoseRunning` as they hand off. Gated the same way as `JumpArc`.",
    },
    .{
        .define = "TurnTimer",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"HandlePose"},
        .note = "**Read on every frame and written by nothing but the two turn poses.** `HandlePose` consults it before it dispatches, so a nonzero value at the anchor changes the very first frame. The cart starts it at zero; whether the Game Boy does at the handover is unknown, because its counterpart is not pinned. The clearest unmeasured risk in the table.",
    },
    .{
        .define = "Items",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "ApplyDamageApply", "AudioTick", "CollideResolve", "DebugEdit", "DebugValue", "ItemPickupArm", "JumpSound", "PoseBallFall", "PoseBallJump", "PoseCrouch", "PoseFall", "PoseJump", "PoseMorph", "PoseMorphBombed", "PoseMorphHurt", "PoseRunning", "PoseSpinJump", "PoseStanding", "SamusGfxSync", "SamusItemGraphics", "SamusLayBomb", "SamusSpriteId", "SaveFileToSram", "SetJumpArc", "VariaExtraGraphics", "VariaStage", "WalkSpeed" },
        .note = "**Step 11 gave it its first writer**: `ItemPickupArm` sets one of six equipment bits, and until then nothing in the engine wrote this at all. Two of those six masks were the wrong bit for two phases and no rung could see it, because a mask that is never set is a mask that is never read -- see `docs/bug_tracker.md`, 2026-09-09. Zero is still correct at the game's start; what makes it right *after* a pickup is now the cartridge's own `SET n,A`, checked in `correspond.zig`. Step 14b adds `PoseMorphBombed`, whose Down arm (00:$0ED4) the dispatch had been skipping, and moves the three ball Down arms from `!ITEM_SPRING` to `!ITEM_SPIDER`: they test bit 5 in the ROM, and Step 11's mask fix had silently made them wrong. **Boot record version 12 seeds it (2026-09-22, Step 16a)**: a new game from `initialSaveFile`, a handover from what its reference measured. `audioparity` found the gap: stretch 6 booted with the beam where the Game Boy had missiles selected, and asked for the beam's shot sound. **1.0 Step 8a** adds the graphics' two readers: `SamusItemGraphics` (a load's patches, 00:$3BB4) and `VariaExtraGraphics` (00:$3A84).",
    },
    .{
        .define = "Water",
        .establishes = .zeroed,
        .carry = .scratch,
        .measure = .water,
        .reads = &.{ "MoveVertical", "SetJumpArc", "WalkSpeed" },
        .note = "`HandlePose` clears it at the top of the frame and the collision routines latch it again, which is what the original does at 00:$1C14. Scratch, and measured anyway because it is the flag that tells a speed disagreement from a contact one.",
    },
    .{
        .define = "AcidContact",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "DrawSamus", "PoseBallFall", "PoseFall" },
        .note = "$D062, `acidContactFlag`, the other per-frame contact flag beside `Water`: `HandlePose` clears it at the top of the frame and every Samus probe latches $40 into it from the block's acid bit (`AcidProbe`, six sites in the original). Scratch for the same reason `Water` is. **`Springboard` until Step 22**, from reading bit 4 as a block that throws the ball; the two jump reads take it as an arc index and, per M2RoS, never see it set, and `DrawSamus` flickers her while it is.",
    },
    .{
        .define = "UnmorphGrace",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "MainLoop", "PoseFall" },
        .note = "$D049, the sixteen-frame window an unmorph in mid-air opens for the aerial jump, counted down by the main loop at 00:$0556. Genuinely carried -- it is the one variable here whose whole purpose is to survive frames -- but it can only be nonzero after an unmorph, and at a handover taken standing there has not been one. `PoseFall` consumes it, so one unmorph buys one jump.",
    },
    .{
        .define = "Unhandled",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DebugDraw", "HandlePose" },
        .note = "Diagnostic: the first pose Phase 0a was handed and could not run. It steers nothing. `EnterCrouch` and then `EnterMorph` were each briefly its second reader while their poses were stubs; both are implemented now, so the dispatch's own fallback is the only writer left -- which is where it belongs, since a pose with no handler is the one thing the fallback can see and an entry routine cannot.",
    },
    .{
        .define = "Solid",
        .establishes = .boot_script,
        .carry = .carried,
        .measure = .solid,
        .reads = &.{"SampleTileProj"},
        .note = "The solidity threshold the door script's `solidity` op leaves. $D056 is pinned, so this is measured against the machine that was walking on the tiles.",
    },
    .{
        .define = "Block",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "AcidProbe", "BombProbeTile", "CollideBottom", "CollideTop", "HitBlock", "SampleTile" },
        .note = "`SampleTile` writes it immediately before either reader runs. Step 12a adds a third reader of the same shape and a different bit: `HitBlock` tests `!BLOCK_SHOT` on the byte the sampler has just read, which is 01:$5176 reading the byte 01:$5175 fetched. Step 14b's `SpiderPoint` was a fourth, testing the acid bit (00:$1FCC); Step 22 moved every probe's acid test into `AcidProbe`, which `SpiderPoint`, `CollideTop` and `CollideBottom` call straight after `SampleTile`.",
    },
    .{
        .define = "Hit",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "CollideHoriz", "CollideTop", "RetHit" },
        .note = "As `Block`: produced and consumed inside one collision call. `SampleTile` was listed here until 2026-09-01 and is a *writer*, not a reader -- `+ sta !Hit` at engine/main.asm:2213, whose leading local label made `sites` read `+` as the opcode and fall through to `.read`. Nine sites in the engine scanned that way; this is the only one on a variable the table carries. It changed no verdict, because `Hit` is scratch either way, but the reader list is the evidence the verdict rests on and it was wrong.",
    },
    .{
        .define = "ColTab",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"SampleTileProj"},
        .note = "The block-type table pointer, from the door script's `collision` op. The Game Boy's table lives at $DC00 and `Settled.coltab` already compares its contents, which is a stronger check than comparing a pointer.",
    },
    .{
        .define = "FallArcP",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{ "PoseBallFall", "PoseFall", "PoseSpiderFall" },
        .note = "Resolved once by `ResolvePhysics`. Constant for the life of the cart.",
    },
    .{
        .define = "JumpArcP",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"JumpArcAt"},
        .note = "As `FallArcP`.",
    },
    .{
        .define = "SpaceArcP",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"PoseSpinJump"},
        .note = "As `FallArcP`.",
    },
    .{
        .define = "HitboxP",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"CollideTop"},
        .note = "As `FallArcP`.",
    },
    .{
        .define = "YOffsP",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"CollideHoriz"},
        .note = "As `FallArcP`.",
    },
    .{
        .define = "JumpArcLen",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"JumpArcAt"},
        .note = "As `FallArcP`.",
    },
    .{
        .define = "SpeedR",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnAiFlittMoving", "HandleCamera", "HandleProjectiles", "SpiderRight" },
        .note = "Written by the movers earlier in the same frame and cleared by the reader. Step 14b: the spider ball reads it back after its own move as `spiderDisplacement` (00:$1135) -- written earlier in the frame by that move, or still zero from the camera's clear when the move failed. 1.0 Step 11: the moving flitt adds its own pixel while it carries her (02:$6926, $694F), as a mover in the enemy pass, before the next frame's camera reads it.",
    },
    .{
        .define = "SpeedL",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnAiFlittMoving", "HandleCamera", "HandleProjectiles", "SpiderLeft" },
        .note = "As `SpeedR`.",
    },
    .{
        .define = "SpeedU",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "HandleCamera", "HandleProjectiles", "SpiderUp" },
        .note = "As `SpeedR`.",
    },
    .{
        .define = "SpeedD",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "HandleCamera", "HandleProjectiles", "SpiderDown" },
        .note = "As `SpeedR`.",
    },
    .{
        .define = "PrevYPix",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"HandleCamera"},
        .note = "Last frame's pixel row, for the vertical camera delta. `InitState` seeds it from the seeded position, so at the anchor it is consistent with where she is -- which is the only thing it can be, since the Game Boy's previous frame belonged to the opening.",
    },
    .{
        .define = "MoveB",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "MoveLeftBy", "MoveRightBy", "MoveVertical" },
        .note = "The mover's argument, written by `WalkSpeed` or an arc lookup immediately before the call.",
    },
    .{
        .define = "TileX",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "BlockSlotAddr", "CollideProjEnemies", "CollideSamusEnemiesHoriz", "DestroyRespawningBlock", "SampleTileProj" },
        .note = "`SetTileX` writes it, `SampleTile` reads it, both inside one collision probe. B4b gives it a second reader outside the tile sampler: `collision_samusEnemies.horizontal` takes Samus's point from the probe column the walk has just set rather than from the draw, which is what makes a walk into an enemy a hit on the frame of the walk. **Step 12a gives it two more, and they are the original's own doing**: $C203/$C204 is not a Samus variable in the ROM either -- it is the point *anything* is asking about, and `handleRespawningBlocks` loads a block's stored position into it before every draw (01:$56A0, $56AF) exactly as the collision loads Samus's. Keeping one pair rather than inventing a block-position pair is what makes those address comments mean what they say.",
    },
    .{
        .define = "TileY",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "BlockSlotAddr", "CollideProjEnemies", "DestroyRespawningBlock", "SampleTileProj" },
        .note = "As `TileX`.",
    },
    .{
        .define = "SprX",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "BombsSamusAndBG", "CollideBombEnemies", "CreditsDigit", "CreditsDrawSamus", "DrawHudMetroid", "DrawNonGameSprite", "DrawProjectiles", "DrawSprite" },
        .note = "$FFC5 `hSpriteXPixel`: where the *sprite* goes, in Game Boy OAM coordinates. **It was also `samus_onscreenXPos` until Step 12b, and that aliasing was correct for as long as Samus was the only thing this engine drew.** `drawSamus_common` (01:$4DDF) writes both from one `A`, so the two really are one number at the point the draw runs -- but `drawProjectiles` writes this and not the other, so from the first frame a beam is in the air they part company. The eight routines that wanted Samus's *position* now read `OnscreenX` and `OnscreenY`; what is left here are the two that want the sprite. See `docs/bug_tracker.md`, 2026-09-09. **And the split changed this row's own answer**: it was `carried`, because `EnAiSenjoo` and the camera read it before the frame's draw had written it. Those readers moved with the rest, and every reader that is left writes it first -- so what the opening leaves in it is now unobservable, which is what `scratch` means and is a smaller claim than the row used to make. **`DrawHudMetroid` reads it since Step 13b, and only to put it back**: the icon borrows the sprite bytes and restores them after, so the one reader at the end of a frame -- `snes boot` -- still finds Samus's there. Step 24h's `DrawNonGameSprite` reads it on the title, after `TitleDraw` writes it, before any record exists. 1.0 Step 22: the credits draw Samus, the stars and the clock through it (`CreditsDrawSamus`, `CreditsDigit`).",
    },
    .{
        .define = "SprY",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "BombsSamusAndBG", "CollideBombEnemies", "CreditsDigit", "DrawBombs", "DrawHudMetroid", "DrawNonGameSprite", "DrawProjectiles", "DrawSprite", "SamusAnchor" },
        .note = "As `SprX`, including the split and including the change of carry with it: this is `hSpriteYPixel` ($FFC4) and not `samus_onscreenYPos`. The two pixels of difference between the sprite and the camera's guide are still here -- 01:$4DF7 biases by $62 where `handleCamera`'s own guide at 00:$0A25 biases by $60, and `SamusAnchor` adds the difference back so the camera keeps the `- 2` and the sprite does not. Step 14's quake reads it back in `SamusAnchor` to add 01:$7A34's pixel, on the sprite and not on `samus_onscreenYPos`. 1.0 Step 22: as `SprX`, the clock's digits (`CreditsDigit`).",
    },
    .{
        .define = "AnimTimer",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "PoseCrouch", "PoseRunning", "SamusSpriteId", "TransitionCamera" },
        .note = "`samus_animationTimer`, $D022: the run cycle. Carried between frames while running, and `PoseStanding` clears it -- so at an anchor taken in `stand` it is zero on both machines by construction. `TransitionCamera` adds 3 on every frame of a crossing's scroll (00:$0B60), which is why a run keeps cycling through a door (Step 24c). Steers the sprite, not the physics.",
    },
    .{
        .define = "SpinTimer",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "HandlePose", "SamusSpriteId", "TransitionCamera" },
        .note = "$D072. Incremented every frame by `HandlePose`, and by `TransitionCamera` on every frame of a crossing's scroll while the pose machine is skipped (00:$0B44, Step 24c), and read only by the sprite chooser. Its phase at the anchor is as unrelated to the reference's as `FrameCount`'s used to be -- but nothing reads it that can move Samus, so the difference is visible and not divergent, and that is the whole reason it has not been given a boot record field of its own.",
    },
    .{
        .define = "Countdown",
        .establishes = .boot_record,
        .carry = .carried,
        .note = "`countdownTimerLow`/`High`, $D066-$D067. Written by the load and by nothing else; ticked down once a frame in NMI, floored at zero. **Carried, and it has to be:** pose $13 is a wait on it, so a cart that started it at the wrong value would hand over control at the wrong frame. Boot record version 8 carries it for that reason -- a mid-run handover records the original's own value, which is zero everywhere the graded stretches start, and a cold boot records the $0140 `loadGame_samusData` sets. **Step 11 gave it a fourth reader and a second writer**: the item pickup's jingle is the same timer, set to $0160 for a major item and $0060 for a Missile Tank, which is where 00:$375C's `cp $0D` divides the item space. The original shares it across several unrelated events and so does this. Step 15c: `DeathFrame` sets the low byte to $FF for the game over screen and reboots when it is spent (00:$3707, $3721). 1.0 Step 22: the credits' fade runs on its low byte (`PrepareCredits`, 05:$5882) and Samus's ending waits on it state by state (`CreditsStates`, 05:$5620).",
        .reads = &.{ "CreditsStates", "DeathFrame", "LowHealthBeep", "NMI", "PoseFaceScreen", "PrepareCredits", "RunItemPickup", "SamusSpriteId", "VariaStage" },
    },
    .{
        .define = "LoadingFromFile",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$D079. Written by `TitleStart` (05:$4264, $428A) on Start, and zero on every cart that has no title. Step 15b gave it its writer; until then every way into this cart was a new game. Pose $13 waits for a button on a new game and not on a loaded file, and the boot takes the save buffer's room, graphics and state instead of the record's. 1.0 Step 18b: a new game loads too, from `BootSave`, and `LoadGameGraphics` reads it for the item font, which only a file's load makes (00:$063E).",
        .reads = &.{ "BootGraphics", "LoadGameGraphics", "LoadSaveFile", "PoseFaceScreen", "SeedPlacement" },
    },
    .{
        .define = "SprSkip",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "Not the original's: it has no such variable, because `drawSamus_faceScreen` expresses the skipped frame as an early `ret` out of a dispatched routine and the port's dispatch is a `jsr` that has to come back. Cleared at the top of `SamusSpriteId` and read by `DrawSamus` in the same frame, so nothing carries.",
        .reads = &.{"DrawSamus"},
    },
    .{
        .define = "StreamDir",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "HandleCamera", "StreamDue", "TransitionCamera" },
        .note = "Which edges owe a row or column. Zero at boot because `LoadScreen` has just drawn the whole map, so nothing is owed -- the Game Boy is in the same state after its own room load.",
    },
    .{
        .define = "StreamX",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "StreamDue", "StreamOne", "StreamRun" },
        .note = "Set by `StreamDue` before the run that reads it.",
    },
    .{
        .define = "StreamY",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "StreamDue", "StreamOne", "StreamRun" },
        .note = "As `StreamX`.",
    },
    .{
        .define = "StreamCell",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"StreamOne"},
        .note = "A one-entry cache of the last cell a screen body was resolved from. Only ever makes the streamer skip a lookup whose answer it already has.",
    },
    .{
        .define = "StreamBody",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"StreamOne"},
        .note = "The cached body pointer beside `StreamCell`, and guarded by it.",
    },
    // ---- The entity foundation, Step 9 -------------------------------------
    //
    // The slots and the flag array are not direct-page variables and are in the
    // table anyway, which is a change to what this file covers rather than an
    // exception to it: the rule was "state a frame can observe at its start",
    // and 640 bytes of it moved out of $00xx only because the direct page ran
    // out of room. The scan does not care where a define points.
    .{
        .define = "Slots",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "AlphaGetSpeedVector", "AlphaLungeMovement", "BabyCheckBlocks", "BabyKeepOnscreen", "BlobGetFacing", "CollideBombEnemies", "CollideProjEnemies", "CollideProjOneEnemy", "CollideSamusEnemiesDown", "CollideSamusEnemiesUp", "CollideSlotLoop", "CrawlerMove", "CrawlerTurnDown", "CrawlerTurnLeft", "CrawlerTurnRight", "CrawlerTurnUp", "DeactivateOffscreen", "DebugFindSlot", "DebugFlagGet", "DebugFlagSet", "DeleteOffscreen", "DrawEnemies", "DrawEnemySprite", "EnAiAlpha", "EnAiArachnus", "EnAiArachnusFireball", "EnAiAutom", "EnAiAutrack", "EnAiBaby", "EnAiBlobProjectile", "EnAiBlobThrower", "EnAiChuteLeech", "EnAiCrawlerA", "EnAiCrawlerB", "EnAiDrivel", "EnAiDrivelSpit", "EnAiFlittMoving", "EnAiFlittVanishing", "EnAiGamma", "EnAiGlowFly", "EnAiGravitt", "EnAiGullugg", "EnAiGunzoo", "EnAiHalzyn", "EnAiHatchingAlpha", "EnAiHopper", "EnAiItemOrb", "EnAiLarva", "EnAiMissileBlock", "EnAiMissileDoor", "EnAiMoto", "EnAiOmega", "EnAiPipeBug", "EnAiProboscum", "EnAiRockIcicle", "EnAiSenjoo", "EnAiSeptogg", "EnAiSkorpHori", "EnAiSkorpVert", "EnAiSkreek", "EnAiSmallBug", "EnAiStinger", "EnAiWallfire", "EnAiZeta", "EnCollideDownCrawlA", "EnCollideDownCrawlB", "EnCollideDownFarMed", "EnCollideDownFarWide", "EnCollideDownMid", "EnCollideDownNear", "EnCollideDownOne", "EnCollideDownY", "EnCollideLeftCrawlA", "EnCollideLeftCrawlB", "EnCollideLeftFarMed", "EnCollideLeftFarWide", "EnCollideLeftMid", "EnCollideLeftNear", "EnCollideLeftX", "EnCollideRightCrawlA", "EnCollideRightCrawlB", "EnCollideRightFarMed", "EnCollideRightFarWide", "EnCollideRightMid", "EnCollideRightNear", "EnCollideRightX", "EnCollideSideFarMed", "EnCollideSideMid", "EnCollideSideNear", "EnCollideUpFarWide", "EnCollideUpMid", "EnCollideUpNear", "EnCollideUpY", "EnSineAhead", "EnSineBack", "EnSineLeft", "EnSineRight", "EnSineX", "EnSineY", "EnSpawnShort", "EnemyAccel", "EnemyAnimateDrop", "EnemyAnimateExplosion", "EnemyAnimateIce", "EnemyCheckShields", "EnemyCommonAI", "EnemyDamageOrDrop", "EnemyDeleteSelf", "EnemyFlipHoriz", "EnemyFlipSprite", "EnemyMetroidExplosion", "EnemySeekSamus", "EnemyStunTick", "EnemyToggleVisibility", "FirstEmptySlot", "GammaGetSpeedVector", "LoadEnemyBox", "LoadOneEnemy", "MetroidCorrectPosition", "MetroidDistanceDir", "MetroidKeepOnscreen", "MetroidMissileKnockback", "MetroidOscillateNarrow", "MetroidOscillateWide", "MetroidScrewKnockback", "MetroidScrewReaction", "ProcessEnemies", "QueenHeadCollision", "QueenProjectilesActive", "ReactivateOffscreen", "ScrollEnemies", "SlotFlagOut" },
        .note = "$C600, sixteen $20-byte slots. `zeroed` is what `Reset` leaves and it is exactly wrong -- a status byte of $00 means *active*, and $FF means empty -- so `InitEntities` fills the status bytes before the first frame and `ResetEntities` does it again on every room change. That ordering is load-bearing: a cart that ran one frame on the WRAM clear would treat all sixteen slots as live enemies with a sprite id of zero. The Game Boy counterpart is measured only through the fixture in `src/room.zig`, not here, because a slot's contents are camera-relative and the handover's camera is not ours until `SeedPlacement` has run. B4b took the reader count from nine to nineteen, which is the shape of the step: Step 9 filled the slots and nothing looked inside them, and this one is every routine that does.",
    },
    .{
        .define = "SpawnFlags",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DebugFlagGet", "LoadEnemiesHoriz", "LoadEnemiesVert", "LoadOneEnemy", "ResetEntities", "SaveEnemyFlags" },
        .note = "$C500, and the same $00-is-a-real-value trap as the slots: the walk loads a record whose flag is $FE or above, so a cleared array reads as \"every enemy is already loaded\" and nothing ever spawns. Two halves with different lifetimes -- $00-$3F is per-room and refilled with $FF by `ResetEntities`, $40-$7F is the *saved* half and is filled only at boot. **The saved half's persistence is B7's and the port does not have it**: the original copies that window in and out of the save buffer per map bank at 02:$418C, and until there is a save buffer a collected item is remembered for as long as the cart runs and no longer. **Step 15a adds two readers**: `ResetEntities` moves the saved half out to the save buffer under its bank and back in, and `SaveEnemyFlags` copies it into cartridge RAM.",
    },
    .{
        .define = "EnTotal",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DeleteOffscreen", "EnAiOmega", "EnAiPipeBug", "EnSpawnShort", "EnemyDeleteSelf", "LoadOneEnemy", "ProcessEnemies", "ScrollEnemies" },
        .note = "`numEnemies.total`, $C425. Zero is the right starting value here, unlike the two arrays above. `ScrollEnemies` is the only reader that acts on the count rather than maintaining it, and it only uses it to skip the walk entirely. B4b gives it a second reader that acts on the count: `ProcessEnemies` copies it into `!EnLeftN` at the top of a pass, and the pass ends when that reaches zero rather than when the array does.",
    },
    .{
        .define = "EnActive",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DeactivateOffscreen", "DebugFlagSet", "DrawEnemies", "EnAiPipeBug", "EnSpawnShort", "EnemyDeleteSelf", "LoadOneEnemy", "ReactivateOffscreen" },
        .note = "`numEnemies.active`, $C426. Nothing reads it yet for anything but its own arithmetic; the original uses it to leave `drawEnemies` early, which is B4b's.",
    },
    .{
        .define = "EnOffscr",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DeactivateOffscreen", "DebugFlagSet", "DeleteOffscreen", "ReactivateOffscreen" },
        .note = "`numEnemies.offscreen`, $C427. The third of the trio, and the one that makes the pair of decrement sites worth reading twice: `EnemyDeleteSelf` decrements total and *active*, `DeleteOffscreen` decrements total and *offscreen*, which is the original's own asymmetry and not a slip.",
    },
    .{
        .define = "EnOsc",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"LoadEnemies"},
        .note = "`loadEnemies_oscillator`, $C439-ish. One bit, flipped every pass, deciding which axis the walk checks -- so it is carried by construction and its *phase* is a thing the port could get wrong the way `FrameCount`'s was. Nothing measures the Game Boy's phase at a handover yet; if a graded stretch ever turns out to spawn an enemy one pass late, this is the byte to measure.",
    },
    .{
        .define = "SpawnReload",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"HandleEnemies"},
        .note = "$0C83's `doorExitStatus`, which the ledger's `StartTransition` row has been calling a later step's since Step 5 and which turns out to be the entity pass's reset request and nothing else. Carried across the frames of a crossing: the trigger writes it, the pass on the far side services it.",
    },
    .{
        .define = "HistAY1",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"ScrollEnemies"},
        .note = "`scrollHistory_A.y1`, $C40C: the scroll one frame ago, which is what `ScrollEnemies` differences against to know how far to carry every slot. The original keeps three older entries beside it and nothing in the port reads them, so the port does not have them. Seeded from the camera by `ResetEntities` rather than left at zero, because a first frame that differenced against zero would carry every slot by a whole screen.",
    },
    .{
        .define = "HistAX1",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"ScrollEnemies"},
        .note = "The horizontal half of the same.",
    },
    .{
        .define = "HistBY1",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"HandleEnemyLoading"},
        .note = "`scrollHistory_B.y1`, $C433. A second, separate history, and the separation is the point: the loading walk checks one axis every other pass, so it has to compare against where the scroll was *two* passes ago rather than one. This entry exists only to feed `HistBY2`.",
    },
    .{
        .define = "HistBY2",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"LoadEnemiesVert"},
        .note = "And the one the vertical walk actually differences against. A zero here on the first frame in a room is what `ResetEntities` re-seeding from the camera prevents.",
    },
    .{
        .define = "HistBX1",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"HandleEnemyLoading"},
        .note = "The horizontal half of `HistBY1`.",
    },
    .{
        .define = "HistBX2",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"LoadEnemiesHoriz"},
        .note = "And of `HistBY2`.",
    },
    // ---- B4b: the contact, the damage, and the pass's own clock ------------
    .{
        .define = "Invuln",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "CollideGuard", "DrawSamus", "HandleRespawningBlocks", "HurtSamus", "SampleTile" },
        .note = "`samusInvulnerableTimer`, $D04F. Zero is right at boot and the audit has nothing to say about the handover -- the published runs are not hit inside their horizons -- but the *carry* matters within a run: it is set to $33 by `HurtSamus`, ticked down by `DrawSamus`, and read by `CollideGuard` to refuse the whole collision pass. Ticking it in the draw rather than in the pose machine is the original's, 01:$4BDD, and it is why a frame the draw declines is still a frame of i-frames spent. Step 12a adds a fourth reader for the same reason `CollideGuard` is one: 01:$5739 gates the reform's crush on it, so a block that comes back on top of an invulnerable Samus does nothing to her. 1.0 Step 25 adds a fifth, `SampleTile`, whose spike arm is skipped while it runs (00:$2016).",
    },
    .{
        .define = "HealthLo",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "AdjustHudValues", "ApplyDamageApply", "EnAiItemOrb", "EnAiOmega", "EnemyDamageOrDrop", "LowHealthBeep", "SaveFileToSram" },
        .note = "$D051, BCD. Step 11 added the second reader: the energy refill declines when Samus is full, which is a test on this and on `Tanks`. **Boot record version 11 seeds it (2026-09-14, Step 13a)**: $99 on a new game, from `initialSaveFile`, and a handover's own measurement where its reference has one. Every cart before that booted at zero, so a hit could only underflow to the clamp `ApplyDamageApply` ends on; `killSamus` is still not ported.",
    },
    .{
        .define = "HealthHi",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "AdjustHudValues", "ApplyDamageApply", "DebugEdit", "EnAiItemOrb", "EnemyDamageOrDrop", "LowHealthBeep", "SaveFileToSram" },
        .note = "$D052, the tanks. See `HealthLo`: the pair is one BCD number and the borrow between them is what the $99 clamp tests. **It is the same number as `Tanks` and not a copy of it**: `pickup_energyTank` stores the new tank count into both, which is why a tank refills Samus as a side effect of being counted.",
    },

    // ---- B6: the item pickup, Step 11 -------------------------------------
    .{
        .define = "ItemStage",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{ "MainLoop", "RunItemPickup" },
        .note = "The port's own, and the reason there is one: `handleItemPickup` blocks for hundreds of frames and a 65816 main loop cannot. This is where the inside-out routine got to, in the shape `!TransRun`/`!TransWait` already have. Zero is idle and correct at boot; carried because `MainLoop` tests it before anything writes it.",
    },
    .{
        .define = "ItemFrames",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"RunItemPickup"},
        .note = "The four `waitOneFrame`s at 00:$3734, counted down. **Four is measured, not read off the listing**: on all four of the recording's pickups the item lands exactly four frames after Samus freezes -- Bomb 44 325/44 329, Missile Tank 44 964/44 968, Energy Tank 48 043/48 047, Spider Ball 68 449/68 453.",
    },
    .{
        .define = "ItemTick",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"MainLoop"},
        .note = "1.0 Step 9. The port's own: the last frame was a pass of `handleItemPickup_end`'s loops, which end in `waitForNextFrame` and so tick the clock; the pickup's other waits are `waitOneFrame`, which does not. Raised by `RunItemPickup` and spent by the next frame's `.itemFrame`, which is why it is carried. Until Step 9 no item frame ticked it, and every major pickup lost the tick whose counter wrap fell in its jingle: the `gfx` rung's code 14.",
    },
    .{
        .define = "VariaAnim",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"GfxXferNmi"},
        .note = "$D08C `variaAnimationFlag`, 1.0 Step 9: while it is up NMI draws the suit a line at a time instead of moving a transfer (00:$2BA3). Raised by `VariaStage` on one frame and read by the NMI after it, so carried; zero at boot, and cleared by `VariaStage` before the suit's records are queued.",
    },
    .{
        .define = "VariaDest",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "VariaAnimNmi", "VariaStage" },
        .note = "`hVramTransfer.destAddr` while the Varia suit animates, kept as the Game Boy's address because the walk is the original's arithmetic on it: NMI advances it, and `VariaStage` ends the loop when its high byte reaches $85 (00:$2813). Set to $8000 by `VariaAnimStart` before the flag goes up.",
    },
    .{
        .define = "SprWeapon",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"EnemyCollisionResults"},
        .note = "`enSprCollision.weaponType` ($C466), which is **not** `collision_weaponType` ($D05D, this port's `CollWeapon`). The second is what the hitbox test writes and the first is a copy taken at the enemy handler's exit, so an AI asking about contact is asking about the previous frame -- the same one-frame gap `HurtFlag` has. **Zero would be a false 'power beam'** and the enemy pass runs the AIs before the transfer, so `InitEntities` seeds $FF -- which is what 02:$412F does at the same point.",
    },
    .{
        .define = "SprEnemy",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"EnemyCollisionResults"},
        .note = "`enSprCollision.pEnemyLow`/`.pEnemyHigh`, as the slot's byte offset rather than its WRAM address -- the same substitution `CollEnemy` makes. `$FFFF` is the empty offset, because `$FF` is the empty *weapon* and slot 0 is a real slot at offset zero.",
    },
    .{
        .define = "ItemCollected",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{ "ItemBookkeeping", "RunItemPickup", "UpdateStatusBar" },
        .note = "$D06C, and the trigger for the whole of B6: `enAI_itemOrb` sets it when Samus touches the item, and the play handler's per-frame test at 00:$372F is what notices. One-based and starting at the plasma beam, so it is **not** the `ITEM` opcode's nibble -- a save station is not something a sprite hands over.",
    },
    .{
        .define = "ItemCopy",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{ "DrawHudMetroid", "ItemJingleDone", "ItemJingleFrame", "ItemPickupArm", "SaveStation" },
        .note = "$D093, `itemCollected_copy`. The working copy the wait loops read, taken because the orb's own AI clears `ItemCollected` while the loops are still running. **`carried` since Step 13b**: `DrawHudMetroid` reads it on every frame to decide whether the icon rises, and nothing writes it on a frame that is not a pickup's, so what a cart boots with is what the icon's first frame sees -- zero from the WRAM clear, which is the Game Boy's between pickups.",
    },
    .{
        .define = "ItemFlag",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{ "EnAiItemOrb", "RunItemPickup", "UpdateStatusBar" },
        .note = "$D06D, `itemCollectionFlag`, and it is a handshake in both directions: the AI writes $FF to say a collection has started, the pickup writes $03 to say it has finished, and the AI clears it as it deletes the item. **The second wait loop's length is that round trip**, which is why the tail after the jingle is 2 to 10 frames in the recording rather than a constant -- it is as long as the enemy pass takes to reach that slot.",
    },
    .{
        .define = "ItemOrbWeapon",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnAiItemOrb", "ItemJingleDone" },
        .note = "$D06F. The contact the orb reported, saved so `ItemJingleDone` can put it back into `SprWeapon`: the pickup consumed it on the way in and the item's AI has to see it again to delete itself.",
    },
    .{
        .define = "ItemOrbEnemy",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"ItemJingleDone"},
        .note = "$D070/$D071, and the same restore, as a slot offset. See `SprEnemy` for the substitution.",
    },
    .{
        .define = "ItemSprite",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"EnAiItemOrb"},
        .note = "$C388, `temp_spriteType`. Which sprite the item was, kept across the whole collection so the end can tell a refill -- which stays in the room -- from an item, which deletes itself.",
    },
    .{
        .define = "ItemOrbY",
        .establishes = .zeroed,
        .carry = .unread,
        .reads = &.{},
        .note = "$D094, which the original's own source calls `unused_itemOrb_yPos`. Ported because it is one store and leaving it out would be a silent difference in the residue; unread here for the same reason it is unread there.",
    },
    .{
        .define = "ItemOrbX",
        .establishes = .zeroed,
        .carry = .unread,
        .reads = &.{},
        .note = "$D095, and the same.",
    },
    .{
        .define = "ItemTmpC",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"EnAiItemOrb"},
        .note = "The sprite type the AI came in with, which the original keeps in C across the whole routine. Owned scratch, not borrowed -- see the ownership note beside `!Dir`.",
    },
    .{
        .define = "ItemTmpC2",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnAiItemOrb", "ItemBookkeeping" },
        .note = "The original's *second* use of C, in `.checkIfDone`, and of B in the bookkeeping. Two routines, one byte, and neither holds it across a call.",
    },
    .{
        .define = "ItemTmpW",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"EnemyCollisionResults"},
        .note = "The word `EnemyCollisionResults` compares X against. A 65816 has no `cpx abs` that reaches a variable through the accumulator's width without one.",
    },
    .{
        .define = "WinY",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"WriteWindow"},
        .note = "`rWY`, Step 24g (until then `ItemWindow`, a recording of the item loop's raise that nothing read). `LoadHud` sets $88 at boot, as `loadTitleScreen` does (05:$40C2), so the first frame's band is the lowered one. `SaveStation` writes it every play pass and the jingle's loop and the door's transfers otherwise, and a collection's second wait loop leaves it where the jingle put it -- so it is carried, and `WriteWindow` turns it into the band in every NMI.",
    },
    .{
        .define = "Tanks",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "DebugEdit", "DebugValue", "EnAiItemOrb", "EnemyDamageOrDrop", "ItemPickupArm", "QueenDisintegrating", "SaveFileToSram", "UpdateStatusBar" },
        .note = "$D050, `samusEnergyTanks`, capped at five by the pickup itself. **Boot record version 11 seeds it (2026-09-14, Step 13a)**: a new game from `initialSaveFile`, a handover from what its reference measured.",
    },
    .{
        .define = "MaxMissLo",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "DebugEdit", "DebugValue", "EnAiItemOrb", "EnemyDamageOrDrop", "ItemPickupArm", "SaveFileToSram" },
        .note = "$D081, BCD, and it is the **ceiling** rather than the count -- which is what makes a Missile Tank findable in the trace at all: `CurMissLo` moves every time a missile is fired and this moves only on a pickup. A new game starts at $30 BCD. **Boot record version 11 seeds it (2026-09-14, Step 13a)**: a new game from `initialSaveFile`, a handover from what its reference measured.",
    },
    .{
        .define = "MaxMissHi",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "DebugValue", "EnAiItemOrb", "EnemyDamageOrDrop", "ItemPickupArm", "SaveFileToSram" },
        .note = "$D082. The pair is one BCD number clamped at 999, which is the `cp $10` after the `DAA` -- here a `SED`/`CLD` pair, because the 65816 has decimal mode where the Game Boy has an adjust. **Boot record version 11 seeds it (2026-09-14, Step 13a)**: a new game from `initialSaveFile`, a handover from what its reference measured.",
    },
    .{
        .define = "CurMissLo",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "AdjustHudValues", "DebugEdit", "DebugValue", "EnAiItemOrb", "EnemyDamageOrDrop", "ItemPickupArm", "SamusShoot", "SaveFileToSram" },
        .note = "$D053, the missiles actually held. Read by the missile refill's 'already full' test, which cannot fire in the slice -- no refill sprite is in the recording's rooms -- and is ported because a branch left out is one that silently does nothing. **Boot record version 11 seeds it (2026-09-14, Step 13a)**: a new game from `initialSaveFile`, a handover from what its reference measured.",
    },
    .{
        .define = "CurMissHi",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "AdjustHudValues", "DebugValue", "EnAiItemOrb", "EnemyDamageOrDrop", "ItemPickupArm", "SamusShoot", "SaveFileToSram" },
        .note = "$D054, and the same pair. **Boot record version 11 seeds it (2026-09-14, Step 13a)**: a new game from `initialSaveFile`, a handover from what its reference measured.",
    },
    .{
        .define = "MetReal",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "DebugMetroidAlive", "DebugMetroidKill", "DebugQueenGet", "EarthquakeCheck", "EnAiAlpha", "EnAiGamma", "EnAiLarva", "EnAiOmega", "EnAiZeta", "HandleEnemies", "ItemPickupArm", "QuakeCountdown", "SaveFileToSram", "StepDoorScript", "TryPausing" },
        .note = "$D089 `metroidCountReal`, BCD. Seeded by boot record version 11. Step 13d gave it its first two readers: the Alpha's death takes one off it, and the restore after a kill (02:$404B) asks for no song if it has reached zero. Step 14 gave it three more: `IF_MET_LESS` (00:$254A) takes its branch when the count is at or below the operand, `earthquakeCheck` (08:$7EBC) arms the quake at a threshold, and the countdown (01:$588E) gives the Queen the short quake. 1.0 Step 10 gave it two more: the missile refill's credits branch (00:$399C) at zero, and the debug menu's Queen row, which reads her state off it.",
    },
    .{
        .define = "MetDisp",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "DebugMetroidAlive", "DebugMetroidKill", "EnAiAlpha", "EnAiGamma", "EnAiLarva", "EnAiOmega", "EnAiStinger", "EnAiZeta", "SaveFileToSram", "UpdateStatusBar" },
        .note = "$D09A `metroidCountDisplayed`, BCD. Seeded by boot record version 11; the HUD (Step 13b) is its first reader, the two digits in the corner of the status bar, and the Alpha's death (Step 13d) takes one off it.",
    },
    .{
        .define = "MetState",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DebugWarp", "EnAiBaby", "EnAiGamma", "EnAiHatchingAlpha", "EnAiOmega", "EnAiZeta", "EnemyCommonAI" },
        .note = "$C41C `metroid_state`: 0 none, 1 the intro's last step, 2 a fight, $80 dying. **Cleared on a load (02:$412F, not a crossing's 02:$418C: 1.0 Step 27a), at the post-death wait's end (02:$405D), and whenever a seen Metroid goes offscreen (02:$45BB)**, and read by the hatching Alpha to decide between the intro and the fight. Carried: a fight spans frames by definition. Step 13d's `EnemyCommonAI` test and death make it `$80`. `DebugWarp` reads it to end an explosion it leaves mid-way, which a crossing never can.",
    },
    .{
        .define = "Cutscene",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "EnAiGamma", "EnAiHatchingAlpha", "EnAiOmega", "EnAiZeta", "EnemyMetroidExplosion", "MainLoop", "SamusSpriteId" },
        .note = "$C463 `cutsceneActive`. Set by the hatching Alpha when Samus comes in range and cleared when it starts the fight; also cleared by a room load (02:$412F) and by the end of every door (00:$0C28), so nothing that fails to clear it can keep her frozen past a transition. Step 13d's explosion is a third writer and reader: it freezes her on its first call and thaws her when the slot goes. Two readers outside the enemies and both are the freeze: `MainLoop`'s cutscene arm (00:$050B) skips the Samus block, and `SamusSpriteId` (01:$4C05) ignores the pad when it picks her sprite.",
    },
    .{
        .define = "AlphaStun",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"EnAiHatchingAlpha"},
        .note = "$C464 `alpha_stunCounter`. A missile sets it to 8 and each pass ticks it down with a knockback and a blink; zero ends the stun. Cleared when a plain Alpha starts its fight (02:$6C62). A global and not a slot byte, as in the original.",
    },
    .{
        .define = "MetFight",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DebugMetroidKill", "EnAiAlpha", "EnAiBaby", "EnAiOmega", "HandleEnemies" },
        .note = "$C465 `metroid_fightActive`: 0, 1 a fight, 2 exploding. Raised by the intro or the in-range test, made 2 by the death, and cleared by a room load or by the restore. `enAI_alphaMetroid` reads it to jump into the hatching Alpha's body; `HandleEnemies` reads it for the restore after a fight (02:$4029): a transition ends a fight at 1, and at 2 the post-death timer runs out first.",
    },
    .{
        .define = "MetScrewDone",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "EnAiAlpha", "EnAiGamma", "EnAiLarva", "EnAiOmega", "EnAiZeta" },
        .note = "$C471 `metroid_screwKnockbackDone`, set on the knockback's sixth call and cleared by the reader that acts on it on the next. Carried across the pass boundary between those two.",
    },
    .{
        .define = "MetXDir",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "AlphaGetAngle", "GammaGetAngle" },
        .note = "$C45A `metroid_samusXDir`. Written by `MetroidDistanceDir` and read by the Alpha's or the Gamma's angle routine right after it, in the same call (1.0 Step 14 split the distance out, as the original has it).",
    },
    .{
        .define = "MetYDir",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "AlphaGetAngle", "GammaGetAngle" },
        .note = "$C45B `metroid_samusYDir`. As `MetXDir`.",
    },
    .{
        .define = "MetAngleIdx",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "AlphaGetAngle", "AlphaSlopeToAngleIndex", "GammaGetAngle", "GammaSlopeToAngleIndex" },
        .note = "$C45C `metroid_angleTableIndex`, the quadrant base plus the slope band, within one `AlphaGetAngle` or `GammaGetAngle` call.",
    },
    .{
        .define = "MetDistY",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"MetroidSlopeToSamus"},
        .note = "$C45D `metroid_absSamusDistY`, within one `AlphaGetAngle` or `GammaGetAngle` call.",
    },
    .{
        .define = "MetDistX",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"MetroidSlopeToSamus"},
        .note = "$C45E `metroid_absSamusDistX`, within one `AlphaGetAngle` or `GammaGetAngle` call; the slope's divisor.",
    },
    .{
        .define = "MetSlope",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "AlphaSlopeToAngleIndex", "GammaSlopeToAngleIndex", "MetroidSlopeToSamus" },
        .note = "$C45F/$C460 `metroid_slopeToSamus`, 100*dY/dX, within one `AlphaGetAngle` or `GammaGetAngle` call.",
    },
    .{
        .define = "MetPostDeath",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"HandleEnemies"},
        .note = "$C41B `metroid_postDeathTimer`. After a kill it climbs on even frames to $90 and then the room's song is asked for again (02:$4039). Cleared by that restore and by a seen Metroid going offscreen (02:$45B8), and by nothing else. **Not by a room load**, which clears the fight flag instead (02:$412F): a transition during the wait stops the timer where it stood and asks for no song, and the next kill's wait starts from there. The original's, on both machines.",
    },
    .{
        .define = "QuakeNext",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "QuakeCountdown", "TryPausing" },
        .note = "$D091 `nextEarthquakeTimer`, in ticks of 256 frames. Armed by `earthquakeCheck` (08:$7EBC) at a threshold count and stepped by the countdown on frames whose counter's low byte is zero and on which the play handler runs. Replaces 13d's `QuakeAsked` recorder, whose address it does not reuse.",
    },
    .{
        .define = "QuakeTimer",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "EarthquakeAdjustScroll", "SamusAnchor", "TryPausing" },
        .note = "$D083 `earthquakeTimer`: $FF when a quake starts, $60 when only the Queen is left, falling on even frames. Its bit 1 shakes the background and its bit 2 Samus.",
    },
    .{
        .define = "SongAfterQuake",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"EarthquakeAdjustScroll"},
        .note = "$D0A5 `songRequest_afterEarthquake`: a door's song held while the quake plays, asked for when it ends. Recorded as `Song` is; no driver (F8).",
    },
    .{
        .define = "Readout",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DebugEdit", "DebugValue", "Readout" },
        .note = "Step 14's playtest readout, on or off. Not the game's: nothing the Game Boy has corresponds, and zero, off, is what every rung runs with, since no rung hands the cart L or R.",
    },
    .{
        .define = "ReadoutMap",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DrawReadout", "Readout" },
        .note = "The map index the readout last drew; `$FF` forces a redraw when it is turned on. With `ReadoutCell` and `ReadoutTable`, the latch.",
    },
    .{
        .define = "ReadoutCell",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DrawReadout", "Readout" },
        .note = "The cell the readout last drew.",
    },
    .{
        .define = "ReadoutTable",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DrawReadout", "Readout" },
        .note = "The metatile table the readout last drew.",
    },
    .{
        .define = "ReadoutDirty",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"NMI"},
        .note = "The readout's tiles are owed to VRAM, which NMI pays.",
    },
    .{
        .define = "ReadoutFontDue",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"NMI"},
        .note = "The readout's font is owed to VRAM. Owed on turning it on rather than uploaded at boot, because the boot upload's time moved every later frame by one.",
    },
    .{
        .define = "Bands",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{ "DebugNmi", "InitHdma", "QueenOff" },
        .note = "`WindowBands` in WRAM, which HDMA channel 7 reads rather than the engine. Copied by `InitHdma` so the readout can put BG1 on the top border's band.",
    },
    .{
        .define = "QueenRoar",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"QueenRoarTick"},
        .note = "$D0A6 `sound_playQueenRoar`. Written by the `SONG` opcode's arms so the opcode's state is whole; no door in the slice plays `$A` or `$B`. Read since metroid2-audio Step 16a by `QueenRoarTick`, the end of `miscIngameTasks` (01:$58DF), which asks for the distant roar every 128 frames while it is set. Zero at every handover the slice has: no door has set it.",
    },
    .{
        .define = "QuakeShake",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DeriveScroll", "QueenScroll", "WriteScroll" },
        .note = "The port's own: what 01:$79EF added to `scrollY` this frame, $01, $FF or zero. The Game Boy stores `scrollY` once a frame and the port derives it, so the shake is latched where the derivation can add it. Carried because the door interpreter's frames do not run `EarthquakeAdjustScroll` and the vblank write still uses it, as the Game Boy's still uses the stored `scrollY`.",
    },
    .{
        .define = "MetSong",
        .establishes = .init_state,
        .carry = .unread,
        .reads = &.{},
        .note = "The port's own: `songRequest` ($CEDC) as the Alphas make it -- $0C for the fight, and 13d's $0F for the kill -- recorded rather than played, F8's stub. `$FF` from `InitEntities` means no Metroid has asked. Unread on the cart by design; a fixture reads it.",
    },
    .{
        .define = "Paused",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DebugWarp", "MainLoop", "UpdateStatusBar" },
        .note = "1.0 Step 2a: game mode $08, `gameMode_Paused`, as a flag -- the port has no mode byte, and `MainLoop` runs `PausedFrame` in place of the play handler while it is set, as `main_handleGameMode` (00:$02F0) does. `TryPausing` sets it and `PausedFrame` clears it. Zero, playing, is where every boot starts, as the Game Boy's mode $04 is.",
    },
    .{
        .define = "LCounter",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"StatusBarLCounter"},
        .note = "$D0A7 `metroidLCounterDisp`: the pause's L counter, written by `TryPausing` off `metroidLCounterTable` and read by the status bar's paused arm (01:$4A0F). Read only while `Paused` is set, which only `TryPausing` sets, after writing it.",
    },
    .{
        .define = "DebugFlag",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "PausedFrame", "TryPausing" },
        .note = "$D0A0 `debugFlag`. The title's Start clears it (05:$424B), as the retail game does, and nothing sets it: 1.0 Step 2b's title combination is gone (Step 2d), and the debug menu is a `--debug` cart's chord. Zero on every cart, which the `pause` rung's code 121 checks on every frame.",
    },
    .{
        .define = "FrameSeed",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"MainLoop"},
        .note = "1.0 Step 2a: what `InitState` put in `FrameCount` -- the record's `BootFrameCount` on a handover, the title's count plus `!TITLE_FC_LEAD` through the title -- so `MainLoop`'s first-frame phase check compares the counter with the seed it actually had. It compared with `BootFrameCount` until the title's count was carried.",
    },
    .{
        .define = "DebugOpen",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DebugFrame", "DebugMenuCheck", "QueenNmi", "QueenPass" },
        .note = "1.0 Steps 2c-2d (C8): the debug menu is up, and `MainLoop` gives it the frame. Zero on every retail cart, where nothing can open it.",
    },
    .{
        .define = "DebugPage",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DebugEdit", "DebugFrame", "DebugPageX" },
        .note = "The debug menu's page, 0 its root. Reset to the root each time it opens.",
    },
    .{
        .define = "DebugRow",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DebugDispMoves", "DebugDraw", "DebugEdit", "DebugEntry", "DebugFrame", "DebugScroll", "DebugThisRow" },
        .note = "The debug menu's cursor row on its page.",
    },
    .{
        .define = "DebugBack",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"DebugFrame"},
        .note = "The root's row a debug-menu page was opened from, where B puts the cursor back.",
    },
    .{
        .define = "DebugDue",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DebugClose", "DebugDraw", "DebugEdit", "DebugNmi", "DebugOpenScreen", "NMI" },
        .note = "What NMI owes the debug menu: its characters, its map, and the layers to open or put back.",
    },
    .{
        .define = "DebugFontUp",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"DebugOpenScreen"},
        .note = "The debug menu's characters are in VRAM: widened and uploaded the first time it opens after power-on.",
    },
    .{
        .define = "SkreekJumpA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_skreekJumpSpeeds`, 1.0 Step 11. See `HopArcYA`.",
        .reads = &.{"EnAiSkreek"},
    },
    .{
        .define = "DrivelYA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_drivelYSpeeds`, with its $80, 1.0 Step 11. See `HopArcYA`.",
        .reads = &.{"EnAiDrivel"},
    },
    .{
        .define = "DrivelXA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_drivelXSpeeds`, 1.0 Step 11. See `HopArcYA`.",
        .reads = &.{"EnAiDrivel"},
    },
    .{
        .define = "SineConcaveA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_sineConcaveSpeeds`, 1.0 Step 11: the halzyn's weave, and the missile block's when Step 12 ports it. See `HopArcYA`.",
        .reads = &.{ "EnSineLeft", "EnSineRight", "EnSineY" },
    },
    .{
        .define = "SineConvexA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_sineConvexSpeeds`. See `SineConcaveA`.",
        .reads = &.{ "EnSineLeft", "EnSineRight", "EnSineY" },
    },
    .{
        .define = "BlobThrowA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`blobThrower_data`, 1.0 Step 12: the thrower's part list and hitbox, which `BlobLoadSprite` copies to WRAM, and its three speed tables. See `HopArcYA`.",
        .reads = &.{ "BlobLoadSprite", "EnAiBlobThrower" },
    },
    .{
        .define = "BlobMovesA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`blobMovementTable_A`-`D`, 1.0 Step 12. See `HopArcYA`.",
        .reads = &.{"EnAiBlobProjectile"},
    },
    .{
        .define = "BlobAction",
        .establishes = .init_state,
        .carry = .carried,
        .note = "$C380 `blobThrower_actionTimer`, 1.0 Step 12: the index into the thrower's three tables, zeroed by `blobThrower_loadSprite` at boot and a load, as the original's 02:$412F does. There is one thrower's worth of state in the ROM, not a slot's.",
        .reads = &.{"EnAiBlobThrower"},
    },
    .{
        .define = "BlobWait",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C381 `blobThrower_waitTimer`. Nothing in the ROM clears it but the power-on WRAM clear, and the port has the same.",
        .reads = &.{"EnAiBlobThrower"},
    },
    .{
        .define = "BlobState",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C382 `blobThrower_state`. As `BlobWait`.",
        .reads = &.{"EnAiBlobThrower"},
    },
    .{
        .define = "BlobFacing",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C386 `blobThrower_facingDirection`: written as the thrower spews, and read by every blob it spewed for as long as they fly. Arachnus writes it too (Step 13).",
        .reads = &.{"EnAiBlobProjectile"},
    },
    .{
        .define = "ArachJumpA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enAI_arachnus.jumpSpeedTable_high`, `_mid` and `_low`, 1.0 Step 13, one run. See `HopArcYA`.",
        .reads = &.{"EnAiArachnus"},
    },
    .{
        .define = "ArachJumpN",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C390 `arachnus_jumpCounter`, 1.0 Step 13: the index into the jump tables. Arachnus's init state clears it (02:$511C), and so does every roll; nothing else but the power-on WRAM clear, and the port has the same. There is one Arachnus's worth of state in the ROM, not a slot's.",
        .reads = &.{"EnAiArachnus"},
    },
    .{
        .define = "ArachTimer",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C391 `arachnus_actionTimer`, 1.0 Step 13. As `ArachJumpN`.",
        .reads = &.{"EnAiArachnus"},
    },
    .{
        .define = "ArachStatus",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C393 `arachnus_jumpStatus`, 1.0 Step 13: written by every step of `.jump` and read by the same step after it lands, so what a frame begins with is unobservable.",
        .reads = &.{"EnAiArachnus"},
    },
    .{
        .define = "ArachHealth",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C394 `arachnus_health`, 1.0 Step 13: the bombs left. Set to 6 by the init state, which runs every pass until the fight starts, so the fight always starts at 6.",
        .reads = &.{"EnAiArachnus"},
    },
    .{
        .define = "GammaStun",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C46A `gamma_stunCounter`, 1.0 Step 14: eight on a missile's hurt (02:$7056), and counted down once a pass by the Gamma's AI -- and by its bolt's, which is the same AI -- until it runs out; zeroed when a seen Gamma's fight starts (02:$6FEA). The Gamma's own, beside `AlphaStun`, which is the Alpha's.",
        .reads = &.{"EnAiGamma"},
    },
    .{
        .define = "GammaAngleA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`gamma_getAngleFromTable.angleTable`, 1.0 Step 14. See `HopArcYA`.",
        .reads = &.{"GammaGetAngle"},
    },
    .{
        .define = "GammaSpeedA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`gamma_getSpeedVector`'s twenty-four arms, 1.0 Step 14. See `HopArcYA`.",
        .reads = &.{"GammaGetSpeedVector"},
    },
    .{
        .define = "ZetaStun",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C46C `zeta_stunCounter`, 1.0 Step 15: eight on a missile's hurt (02:$73FF), counted down once a pass by the Zeta's AI -- and by its husk's, which is the same AI, though no hurt reaches a Zeta while its husk lives -- until it runs out; zeroed when a seen Zeta's fight starts (02:$732F). The Zeta's own, beside `AlphaStun` and `GammaStun`.",
        .reads = &.{"EnAiZeta"},
    },
    .{
        .define = "ZetaXProx",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "$C437 `zeta_xProximityFlag`, 1.0 Step 15: raised by the chase when Samus is within $20 across (02:$738C, $739B) and cleared by the same call's test of it (02:$73A9) before anything else can read it, so it is zero between calls.",
        .reads = &.{"EnAiZeta"},
    },
    .{
        .define = "SeekSpeedA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_seekSamus.speedTable` (03:$6BB1), 1.0 Step 15. See `HopArcYA`.",
        .reads = &.{"EnemySeekSamus"},
    },
    .{
        .define = "OmegaStun",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C462 `omega_stunCounter`, 1.0 Step 16: $10 on a missile in the back (02:$76AF), three on one in front ($76B9), counted down once a pass by the Omega's AI until it runs out; zeroed when a seen Omega's fight starts (02:$7969). The Omega's own, beside `AlphaStun`, `GammaStun` and `ZetaStun`.",
        .reads = &.{"EnAiOmega"},
    },
    .{
        .define = "OmegaSprite",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C44F `omega_tempSpriteType`, 1.0 Step 16: the sprite a hurt covers with $C4 (02:$76C2), put back when the stun runs out (02:$7660). Written before it is read in every stun.",
        .reads = &.{"EnAiOmega"},
    },
    .{
        .define = "OmegaWait",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C46F `omega_waitCounter`, 1.0 Step 16: counted up on every pass of states 1, 2 and 4, and at $40 the next chase is picked and it goes back to 0 (02:$79A8); zeroed at the seen Omega's fight start, a screw knockback's end and the death.",
        .reads = &.{"EnAiOmega"},
    },
    .{
        .define = "OmegaPrevHp",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C470 `omega_samusPrevHealth`, 1.0 Step 16: Samus's health's low byte at the last chase pick (02:$79EB). The next pick takes the shortest chase if it has fallen $30 or more since, in eight bits and BCD, as the original subtracts it. The Omega's AI never clears it.",
        .reads = &.{"EnAiOmega"},
    },
    .{
        .define = "OmegaChaseIx",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C478 `omega_chaseTimerIndex`, 1.0 Step 16: which of five chase lengths the next pick takes, stepped 1-4 and back to 0 (02:$79C2); 3 after a screw knockback, and at 4 the chase ignores a crouch (02:$77C5).",
        .reads = &.{"EnAiOmega"},
    },
    .{
        .define = "LarvaHurtN",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C473 `larva_hurtAnimCounter`, 1.0 Step 17: three on a frozen larva's missile hurt (02:$7B05), counted down by the next passes of whichever larva runs, which show nothing else until it runs out and puts back $CE (02:$7AC9). One byte for every larva, as the original's.",
        .reads = &.{"EnAiLarva"},
    },
    .{
        .define = "LarvaBomb",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C474 `larva_bombState`, 1.0 Step 17: 1 once a larva has touched Samus (02:$7B70), 2 while one flies off her (02:$7A7C), when the next to touch her flies off at once rather than latch. Zeroed at the fly-off's end, the kill and a room's reset (02:$4013), which only writes it.",
        .reads = &.{"EnAiLarva"},
    },
    .{
        .define = "LarvaLatch",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$C475 `larva_latchState`, 1.0 Step 17: 2 on her, 1 flying off, 0 let go, read by every latched larva (02:$7A5A). Zeroed with `LarvaBomb`.",
        .reads = &.{"EnAiLarva"},
    },
    .{
        .define = "BabyTile",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "$C417 `metroid_babyTouchingTile`, 1.0 Step 21: the tile the last of the four mid probes read, the solid one or its third point (02:$4662, $483B, $4A28, $4C30). Only the baby reads it (02:$7D45, $7D78), each time straight after one of them, so what it held before is unobservable.",
        .reads = &.{"BabyCheckBlocks"},
    },
    .{
        .define = "BabyTempX",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "$C43B `baby_tempXpos`, 1.0 Step 21: the baby's X held while its Y is probed at the X the pass began with (02:$7D2E), put back before X is probed ($7D64). Written before it is read.",
        .reads = &.{"BabyCheckBlocks"},
    },
    .{
        .define = "EnProbeTile",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "The port's own, 1.0 Step 21: the tile `EnProbeLine` read last -- the original's A after its last `getTileIndex.enemy` -- which the mid probes copy to `BabyTile`. Written on every point.",
        .reads = &.{ "EnCollideSideMid", "EnKeepBabyTile" },
    },
    .{
        .define = "BlobN",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "The port's own: `.moveSprites`' count, the original's B, set by its caller on every call.",
        .reads = &.{"EnAiBlobThrower"},
    },
    .{
        .define = "BlobTabAt",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "The port's own: `.moveSprites`' table, where the original keeps HL on the stack. Set on every call.",
        .reads = &.{"EnAiBlobThrower"},
    },
    .{
        .define = "LCounterA",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"TryPausing"},
        .note = "Far pointer to `metroidLCounterTable`, resolved once at boot by `ResolveProjectiles`.",
    },
    .{
        .define = "AlphaAngleA",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"AlphaGetAngle"},
        .note = "Far pointer to `alpha_angleTable`, resolved once at boot by `ResolveProjectiles`.",
    },
    .{
        .define = "AlphaSpeedA",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"AlphaGetSpeedVector"},
        .note = "Far pointer to `alpha_speedVectors`, resolved once at boot by `ResolveProjectiles`.",
    },
    .{
        .define = "MetB",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "AlphaLungeMovement", "EnAiAlpha", "EnAiGamma", "EnAiHatchingAlpha", "EnAiOmega", "EnAiZeta", "EnemySeekSamus", "MetroidDistanceDir", "MetroidScrewReaction" },
        .note = "The port's own: the Metroid routines' B register -- an intermediate within one call, and the Y speed `AlphaGetSpeedVector` hands `AlphaLungeMovement` in the same pass.",
    },
    .{
        .define = "MetC",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "AlphaGetAngle", "AlphaLungeMovement", "EnAiOmega", "GammaGetAngle" },
        .note = "The port's own: the Metroid routines' C register, and the X speed beside `MetB`.",
    },
    .{
        .define = "MetD",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "AlphaLungeMovement", "EnemySeekSamus", "MetroidScrewReaction" },
        .note = "The port's own: D, `metroid_screwReaction`'s which-side flag, and the magnitude of a negative speed in `AlphaLungeMovement`.",
    },
    .{
        .define = "MetE",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnemySeekSamus", "MetroidScrewReaction" },
        .note = "The port's own: E, `metroid_screwReaction`'s which-side flag on the other axis.",
    },
    .{
        .define = "MetRem",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"MetroidSlopeToSamus"},
        .note = "The port's own: `math_divide_HL_by_C`'s DE, the running remainder, within one call.",
    },
    .{
        .define = "MetDiv",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"MetroidSlopeToSamus"},
        .note = "The port's own: the divisor C widened to sixteen bits, within one call.",
    },
    .{
        .define = "DispHealthLo",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "AdjustHudValues", "MainLoop", "UpdateStatusBar" },
        .note = "$D084 `samusDispHealth`, BCD: what the status bar shows, rolled one unit a frame toward `HealthLo` by `adjustHudValues`. Step 13b. Seeded from `BootHealth`, the record's real health, because `loadGame_samusData` loads both from the one save byte -- so a cart boots showing what she has and a handover taken mid-roll boots with the roll finished, which is a difference only the frames of an unfinished roll could see. Step 15c: `MainLoop` tests it for zero straight after `miscIngameTasks` and kills Samus on it (00:$04EC).",
    },
    .{
        .define = "DispHealthHi",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "AdjustHudValues", "UpdateStatusBar" },
        .note = "$D085, the displayed tanks' worth: the status bar fills one tank per hundred of it. See `DispHealthLo`.",
    },
    .{
        .define = "DispMissLo",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "AdjustHudValues", "UpdateStatusBar" },
        .note = "$D086 `samusDispMissiles`, BCD, seeded from `BootCurMiss`. See `DispHealthLo`.",
    },
    .{
        .define = "DispMissHi",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "AdjustHudValues", "UpdateStatusBar" },
        .note = "$D087, whose low nibble is the hundreds digit. See `DispHealthLo`.",
    },
    .{
        .define = "Shuffle",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"UpdateStatusBar"},
        .note = "$D096 `metroidCountShuffleTimer`. A kill sets it to $C0 (Step 13d); the status bar counts it down on every frame it draws and scrambles the count below $80. Zero is the Game Boy's value at any handover the slice takes before the first kill, and the recorded run's first kill is after every anchor this cart is booted at.",
    },
    .{
        .define = "HudTanks",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"UpdateStatusBar"},
        .note = "`hHUD_tank1`-`hHUD_tank5` ($FFB7-$FFBB): the five tank cells, built and emitted inside one call.",
    },
    .{
        .define = "MapUpdate",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"StatusBarDue"},
        .note = "`mapUpdateFlag` ($DE01). `MainLoop` clears it at the top of every frame, as `mainGameLoop` does at 00:$02CD, so the NMI that reads it sees only that frame's streamer.",
    },
    .{
        .define = "SaveContact",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "DrawHudMetroid", "SaveStation", "TryPausing" },
        .note = "$D07D `saveContactFlag`. **Step 15a gave it its writers**: both bottom probes of `CollideBottom` set it on a save station's tile, and the door interpreter's transfers, `StartTransition` and `SaveStation` itself clear it. Read by the HUD icon and by the Start arm. Zero is right for every handover the slice has, none of which stands on a station.",
    },
    .{
        .define = "DivClock",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "AudioTick", "EnAiAutom", "EnAiDrivel", "EnAiGunzoo", "NMI", "QueenPrepExtend", "UpdateStatusBar" },
        .note = "The port's own: the `rDIV` substitute, advanced $12.50 a frame by NMI, which is the Game Boy divider's 274.3125 counts a frame reduced mod 256. Its phase at boot is not the Game Boy's and is not graded: the scrambled count is judged by when it starts and stops, not by its digits. 1.0 Step 19b: the Queen's mouth toss on a lunge (03:$78D1), handed across by the Queen oracle.",
    },
    .{
        .define = "HudBaseA",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{ "LoadHud", "QueenHudBase" },
        .note = "`hudBaseTilemap`, resolved with the projectile tables and read at boot, and again by `ESCAPE_QUEEN` and `EXIT_QUEEN` (1.0 Step 20d), which put the status bar back where her head was. See `HopArcYA`.",
    },
    .{
        .define = "HudDiv",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"UpdateStatusBar"},
        .note = "The port's own: the divider the scrambled arm read, held across the tens digit's arithmetic.",
    },
    .{
        .define = "DaaFlags",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"GbDaa"},
        .note = "The port's own: the carry and half-carry a Game Boy `DAA` corrects by, which the 65816 has no flag for. Set by each caller before the call.",
    },
    .{
        .define = "Beam",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "DebugEdit", "DebugValue", "SamusGfxSync", "SaveFileToSram", "ToggleMissiles" },
        .note = "$D055, `samusBeam`. Written by the four beam pickups, and **Step 12b gave it its reader**: it is where the beam is parked while missiles are selected, so `toggleMissiles` reads it back to decide what switching away from missiles returns to. Carried rather than scratch because that is the whole of what it is -- the value survives every frame the player spends holding missiles. None of the four beams is in the region, so it is $00 (the power beam) for every frame of the slice, which is also what the toggle puts back. **Boot record version 12 seeds it (2026-09-22, Step 16a)**: a new game from `initialSaveFile`, a handover from what its reference measured. `audioparity` found the gap: stretch 6 booted with the beam where the Game Boy had missiles selected, and asked for the beam's shot sound.",
    },
    .{
        .define = "ActiveWeapon",
        .establishes = .boot_record,
        .carry = .carried,
        .reads = &.{ "DebugEdit", "FirstEmptyProj", "ItemPickupArm", "Reset", "SamusGfxSync", "SamusItemGraphics", "SamusShoot", "ToggleMissiles", "VariaStage" },
        .note = "$D04D. A beam pickup becomes the selected weapon **unless missiles are selected**, which is the `cp $08` every one of the four makes. Its other reader is the Select toggle, which is B5's. `Reset` reads it once, at boot, to upload the missile cannon when a handover has missiles selected. **Boot record version 12 seeds it (2026-09-22, Step 16a)**: a new game from `initialSaveFile`, a handover from what its reference measured. `audioparity` found the gap: stretch 6 booted with the beam where the Game Boy had missiles selected, and asked for the beam's shot sound. **1.0 Step 8a** adds `SamusItemGraphics`, which picks the beam's tiles by it on a load as `loadGame_samusItemGraphics` does, and the Varia arm's test for the missile cannon.",
    },
    .{
        .define = "SongInt",
        .establishes = .zeroed,
        .carry = .unread,
        .reads = &.{},
        .note = "$CEDE, `songInterruptionRequest`: which jingle the pickup asked for -- $01 for an item, $05 for missiles, $03 to stop, none for a refill. A silent stub by decision rather than by omission, like `Song`; which driver Phase 0c lands on is still open.",
    },
    .{
        .define = "SongPlaying",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "ItemBookkeeping", "ItemJingleDone", "StepDoorScript" },
        .note = "$CEDF. **Since Step 14 it has a writer**, and a stated one: the driver sets it to $0E when it accepts the quake's request and nothing else touches it until the quake's end clears it (measured on the recording), so `QuakeCountdown` writes it where the request is made and `EarthquakeAdjustScroll` clears it. Before Step 14 it had two readers and no writer, because the *driver* writes it and the port has no driver. Both readers ask the same question -- is the earthquake playing, in which case the jingle is suppressed -- and $0E is the earthquake. Zero means 'not the earthquake', which is the right answer for a cart with no music at all.",
    },
    .{
        .define = "Sfx1",
        .establishes = .zeroed,
        .carry = .unread,
        .reads = &.{},
        .note = "$CEC0, `sfxRequest_square1`. Written by the orb opening and by three arms of the bookkeeping, and since metroid2-audio Step 16a by `AudioRequest` for every square 1 site the port sends (`src/audio_sites.zig`); unread for the same reason `SongInt` is -- the game never reads this request byte back.",
    },
    .{
        .define = "SfxNoise",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"SamusSpriteId"},
        .note = "$CED5, `sfxRequest_noise`. The orb cracking open was the only writer until Step 12a; `destroyRespawningBlock` (01:$568E) and `destroyBlock` (01:$570E) both ask for the same effect $04, which is the sound a block makes. Step 12f's hopper asks for $1A when an Autoad's jump reaches its second frame (02:$6225). **Read since metroid2-audio Step 16a**, by the footstep in `drawSamus_run` (01:$4D8B), which asks for noise $10 only while no noise has been asked for since the last `handleAudio` -- the driver zeroes the byte once it has taken it, and `AudioTick` does the same. Zero at a handover on both machines: the driver has run since any request.",
    },
    // ---- Step 12f: the enemy AIs, and the tilemap probes they walk with ----
    .{
        .define = "SolidEnemy",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{ "EnProbeLine", "EnProbeWide" },
        .note = "`enemySolidityIndex`, $C407, and its canonical copy $D069: the second of the three thresholds a `SOLIDITY` row carries (00:$244E), and the one an enemy's tilemap probe compares against. The original keeps two bytes -- the op writes $D069 and the top of every enemy pass (02:$4082) copies it to $C407 -- and nothing else writes either, so the port keeps one. Unread until Step 12f; `SampleTile`'s `!Solid` is Samus's and is not this.",
    },
    .{
        .define = "HopArcYA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_hopperArcY`, a far pointer `ResolveProjectiles` fills at boot. The table is the cartridge's sixteen bytes, so it comes off the user's ROM as a blob rather than out of the engine image -- the file policy refused the first version, which had them inline. See `ShotDirsA`.",
        .reads = &.{"EnAiHopper"},
    },
    .{
        .define = "HopArcXA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_hopperArcX`. See `HopArcYA`.",
        .reads = &.{"EnAiHopper"},
    },
    .{
        .define = "GulYA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_gulluggYSpeeds`, with its $80. See `HopArcYA`.",
        .reads = &.{"EnAiGullugg"},
    },
    .{
        .define = "GulXA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_gulluggXSpeeds`. See `HopArcYA`.",
        .reads = &.{"EnAiGullugg"},
    },
    .{
        .define = "LeechXA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_chuteLeechXSpeeds`, with its $80. See `HopArcYA`.",
        .reads = &.{"EnAiChuteLeech"},
    },
    .{
        .define = "LeechYA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_chuteLeechYSpeeds`. See `HopArcYA`.",
        .reads = &.{"EnAiChuteLeech"},
    },
    .{
        .define = "EnAiTmp",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnAiArachnus", "EnAiBlobProjectile", "EnAiBlobThrower", "EnAiChuteLeech", "EnAiFlittVanishing", "EnAiGravitt", "EnAiPipeBug", "EnAiSkreek", "EnCollideSideNear", "EnSineAhead", "EnSineBack", "EnSpawnShort", "EnemyAccel", "EnemySeekSamus" },
        .note = "The port's own: a byte an AI keeps across a few instructions where the original keeps it in a register or leaves it in `(HL)` -- the Chute Leech's X speed, which 02:$5E89 tests with `BIT 7,(HL)` and 02:$5EB7 adds. Written before it is read in every call.",
    },
    .{
        .define = "AccelFwdA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_accelForwards`' curve. See `HopArcYA`.",
        .reads = &.{"EnemyAccelForwards"},
    },
    .{
        .define = "AccelBackA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`enemy_accelBackwards`' curve. See `HopArcYA`.",
        .reads = &.{"EnemyAccelBackwards"},
    },
    // ---- B5's bombs, Step 12c ---------------------------------------------
    .{
        .define = "Bombs",
        .establishes = .init_state,
        .carry = .carried,
        .note = "$DD30 `bombArray`, three $10-byte slots, and `init_state` for the reason `Projs` is: `Reset` clears WRAM to zero and zero is not the empty type, so `ClearProjectiles` runs on through this array exactly as 00:$21EF runs to the end of its page. **No rung can tell whether it does**, and that was measured rather than assumed: with both this clear and `StartTransition`'s removed the gate still passes, because a zeroed slot's position is off the window and `DrawBombs` deletes it on the first frame `MainLoop` runs. The clear is ported because the original has it, and left ungraded because the original's own draw makes it unobservable. Carried in the plain sense -- a fuse is $60 frames long -- and emptied at a door by `StartTransition` (00:$0C55), which is the only other place a bomb ends besides its own counter and the draw's window.",
        .reads = &.{ "DrawBombs", "FirstEmptyBomb", "HandleBombs" },
    },
    .{
        .define = "BombMapY",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "$D04A `bomb_mapYPixel`: the bomb being drawn, in map space, so `BombsSamusAndBG` can ask the tilemap about it after the draw has turned the slot's position into a sprite's. Written by `DrawBombs` before every read.",
        .reads = &.{"BombsSamusAndBG"},
    },
    .{
        .define = "BombMapX",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "$D04B `bomb_mapXPixel`. See `BombMapY`.",
        .reads = &.{"BombsSamusAndBG"},
    },
    .{
        .define = "BombType",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`hTemp.a` inside `drawBombs`: the slot's type, held across the window test. A variable rather than a register because `DrawSprite` and the detonation both run between its write and its read.",
        .reads = &.{"DrawBombs"},
    },
    .{
        .define = "BombTimer",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`drawBombs`' C: the slot's counter, which picks the sprite and says whether this is the explosion's first frame. `bombs_samusAndBGCollision` pushes BC around itself so the original's survives the detonation; this one survives it by being memory nothing else writes.",
        .reads = &.{"DrawBombs"},
    },
    .{
        .define = "BombHitPoseA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`samus_bombPoseTable`, pinned in Step 12c. See `ShotDirsA`.",
        .reads = &.{"BombsSamusAndBG"},
    },
    .{
        .define = "EnAccelField",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"EnemyAccel"},
        .note = "The port's own: which byte of the slot an acceleration moves, where the original passes the byte's address in HL. Set by the caller on every call.",
    },
    .{
        .define = "EnParent",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnAiArachnus", "EnAiAutom", "EnAiAutrack", "EnAiBlobThrower", "EnAiDrivel", "EnAiGamma", "EnAiGunzoo", "EnAiOmega", "EnAiPipeBug", "EnAiSkreek", "EnAiWallfire", "EnAiZeta" },
        .note = "The port's own: the spawner's slot while X is the slot it is filling. The original needs no such byte because it fills the child through HL and keeps itself in HRAM.",
    },
    .{
        .define = "EnWeaponDir",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnAiAlpha", "EnAiGamma", "EnAiMissileBlock", "EnAiMissileDoor", "EnAiOmega", "EnAiZeta" },
        .note = "$C46E `enemy_weaponDir`, handed on by `enemy_getSamusCollisionResults` beside the weapon type. Its one reader reads it only on the frame a missile's contact was just handed on, so what an earlier frame left in it is unobservable. Step 13c: the Alpha's hurt reaction is the second reader, and reads it on the same frame for the same reason.",
    },
    .{
        .define = "EnSpawnN",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"EnSpawnShort"},
        .note = "The port's own: `enemy_spawnObject`'s header count, the original's B.",
    },
    .{
        .define = "EnBgResult",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "BabyCheckBlocks", "EnAiArachnus", "EnAiCrawlerA", "EnAiCrawlerB", "EnAiDrivelSpit", "EnAiGamma", "EnAiGlowFly", "EnAiGunzoo", "EnAiHalzyn", "EnAiHopper", "EnAiLarva", "EnAiMissileBlock", "EnAiMoto", "EnAiOmega", "EnAiRockIcicle", "EnAiSeptogg", "EnAiWallfire", "EnCollideSideMid", "EnKeepBabyTile", "EnProbeLine", "EnProbeWide", "MetroidCorrectPosition" },
        .note = "$C402 `en_bgCollisionResult`. Every probe presets it before it tests anything, and every reader reads it after a probe in the same call, so what a frame begins with is unobservable.",
    },
    .{
        .define = "EnTestY",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnProbeLine", "EnProbeWide", "EnemyTileAt" },
        .note = "$C44D `enemy_testPointYPos`, camera space. Set by a probe before its first point, and stepped between points by the probes that walk down an edge.",
    },
    .{
        .define = "EnTestX",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnProbeLine", "EnProbeWide", "EnemyTileAt" },
        .note = "$C44E `enemy_testPointXPos`. Set by a probe before its first point and stepped between points; left on the last point tested, as the original leaves it.",
    },
    .{
        .define = "EnProbeN",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnProbeLine", "EnProbeWide" },
        .note = "The port's own: how many points of a probe are left. The original unrolls the loop, one `CALL $2250` per point, so it has no counterpart.",
    },
    .{
        .define = "EnProbeSX",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"EnProbeLine"},
        .note = "The port's own: the X distance between a probe's points, which the original writes as an `ADD A,d8` before each call. Every probe steps along one axis, so one of this and `EnProbeSY` is zero.",
    },
    .{
        .define = "EnProbeSY",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnProbeLine", "EnProbeWide" },
        .note = "The Y half of `EnProbeSX`.",
    },
    .{
        .define = "EnXMirror",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "AlphaLungeMovement", "BabyCheckBlocks", "EnAiGamma", "EnAiLarva", "EnCollideUpCrawlA", "EnCollideUpCrawlB", "MetroidCorrectPosition", "MetroidMissileKnockback", "MetroidScrewKnockback" },
        .note = "$C41F `enemy_xPosMirror`: the slot's X as the pass copied it in (02:$43F9), before the AI moves it. The crawlers' top probes read it rather than the live X (02:$4D5B, $4D89). Written at the top of every slot's turn, so scratch.",
    },
    .{
        .define = "EnYMirror",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "AlphaLungeMovement", "BabyCheckBlocks", "EnAiGamma", "EnAiLarva", "EnAiSeptogg", "MetroidCorrectPosition", "MetroidMissileKnockback", "MetroidScrewKnockback" },
        .note = "$C41E `enemy_yPosMirror`, written beside `EnXMirror` at the top of every enemy's turn (02:$43F9). **Step 13c gave it its readers**, which Step 9 kept it here for: the Alpha's lunge and both of its knockbacks move Y and then put it back on this mirror if the far wide probe on that edge hit. Written before read on every pass, so scratch.",
    },
    .{
        .define = "EnProbeClr",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnProbeLine", "EnProbeWide" },
        .note = "The port's own: the probe's `.exit` label as a mask -- `RES 1,(HL)` for the bottom edge -- so one row walker serves every edge.",
    },
    // ---- B5's terrain half, Step 12a of the slice -------------------------
    .{
        .define = "SolidBeam",
        .establishes = .boot_script,
        .carry = .carried,
        .note = "`beamSolidityIndex`, $D08A: the third of the three thresholds a `SOLIDITY` row carries, and **not the one Samus walks on**. The door script's own loader states which column is which by storing the three in order (00:$2447, $244E, $2455), and `blocks.beamThresholdColumn` reads the index out of that store sequence rather than out of a comment -- the same shape as `items.bitFor`, and for the same reason: a second transcription of the same table could not catch a slip in the first. `measure` is null and stays null: $D08A is not one of the addresses `gb_trace` latches, so the audit has no measured handover value for it and will not invent one. What it *is* graded against is the ROM, on every frame of `snes boot`: the fixture computes the row the boot door selects and asserts the cart holds that byte.",
        .reads = &.{"HitBlock"},
    },
    .{
        .define = "Blocks",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$D900, sixteen $10-byte slots, and **zero is the right starting value here** -- unlike `Slots`, where $00 means active. A counter of zero is a free slot, so `Reset`'s WRAM clear leaves the array empty and nothing has to fill it. Three bytes of each slot are used and the other thirteen are the original's stride, kept because the eviction walks the array with `LD A,L / AND $F0 / ADD A,$10` and that arithmetic is the array. Carried in the strongest sense in the file: a block destroyed on one frame is a hole in the world for 233 of them, and the slot is the only thing that remembers to put it back.",
        .reads = &.{ "DestroyRespawningBlock", "HandleRespawningBlocks" },
    },
    .{
        .define = "BlkDst",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "The tilemap slot a draw is about to write: $C215/$C216 with the `AND $DE` already applied. Written by `BlockSlotAddr` and read by the two routines that draw, inside one call each. `BlockSlotAddr` is its own third reader because it accumulates the row and the column in it, which is the original adding the column to L at 00:$22D7.",
        .reads = &.{ "BlockSlotAddr", "BlockWrite4", "DestroyBlock" },
    },
    .{
        .define = "BlkCrush",
        .establishes = .zeroed,
        .carry = .unread,
        .note = "The reform found Samus standing inside the block it was putting back (01:$5739). **Recorded rather than ported, with a stated boundary**: 01:$5790's first read is a nineteen-byte table at 01:$57DF indexed by her pose, which this repository has not pinned, and what it does with it is write `samus_hurtFlag`, `samus_damageBoostDirection` and `samus_damageValue` -- B5's other half, and Step 12b's. Porting it blind would mean transcribing a ROM table into `engine/main.asm`, which is what the file policy exists to stop. So the branch says it fired, the way `EnChild` and `ItemUnhandled` do, and $00 means it never has.",
        .reads = &.{},
    },
    // ---- B5's projectile half, Step 12b -----------------------------------
    .{
        .define = "Projs",
        .establishes = .init_state,
        .carry = .carried,
        .note = "$DD00, three $10-byte slots, and **`init_state` rather than `zeroed` is the whole point of the row**: `Reset` clears WRAM to zero, zero is `!WPN_NORMAL`, and a cart that did not run `ClearProjectiles` would boot with three live power-beam shots at whatever position the clear left. The original has the same hazard and the same answer -- 00:$21EF `clearProjectileArray`, called from 00:$0CA3 `loadGame_samusData`, which is the same four instructions the boot record was taken off in Step 7. Carried in the plain sense: a beam in the air on one frame is a beam in the air on the next, and the only thing that ends it is `DrawProjectiles` finding it outside the visible window.",
        .reads = &.{ "DrawProjectiles", "FirstEmptyProj", "HandleProjectiles", "SamusShoot" },
    },
    .{
        .define = "OnscreenX",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$D03C `samus_onscreenXPos`, **and Step 12b is where it stopped being `SprX`.** `drawSamus_common` writes the sprite byte and this one from a single `A`, so for as long as Samus was the only thing this engine drew they were one variable and six routines read the sprite byte as her position. `drawProjectiles` writes the sprite byte and not this one; the bug tracker's 2026-09-09 entry has what that would have cost. Carried for the reason the sprite byte is: every reader is asking about the *previous* frame's draw, because the original writes it in `drawSamus` and reads it in `handleCamera` and the collision, both of which run first. 1.0 Step 20a: `PoseBeingEaten` draws her to the Queen's mouth by it (00:$0E78).",
        .reads = &.{ "BlobGetFacing", "BombsSamusAndBG", "CollideSamusEnemies", "EnAiAlpha", "EnAiBaby", "EnAiChuteLeech", "EnAiDrivel", "EnAiFlittMoving", "EnAiGamma", "EnAiGravitt", "EnAiHatchingAlpha", "EnAiLarva", "EnAiOmega", "EnAiPipeBug", "EnAiSenjoo", "EnAiSkreek", "EnAiZeta", "EnemySeekSamus", "HandleCamera", "MetroidDistanceDir", "MetroidScrewReaction", "PoseBeingEaten", "QueenGetSamusTargets" },
    },
    .{
        .define = "OnscreenY",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$D03B `samus_onscreenYPos`, the other half of the split above. Read by the two vertical door triggers and by the downward sprite collision, which biases it by the difference between Samus's centre and her feet. 1.0 Step 20a: `PoseBeingEaten` draws her to the Queen's mouth by it (00:$0E4E).",
        .reads = &.{ "BombsSamusAndBG", "CollideSamusEnemiesDown", "CollideSamusEnemiesUp", "EnAiBaby", "EnAiLarva", "EnAiPipeBug", "EnAiSeptogg", "EnAiZeta", "EnemySeekSamus", "HandleCamera", "MetroidDistanceDir", "MetroidScrewReaction", "PoseBeingEaten", "QueenGetSamusTargets" },
    },
    .{
        .define = "EnMsPtrs",
        .establishes = .init_state,
        .carry = .carried,
        .note = "The enemy metasprite set's converted pointer table, resolved once at boot. **The blob it points at was extracted and round-tripped from Step 4 and never shipped into the cart until Step 12d**, which is the whole of why the enemies were invisible: their slots were filled, walked, collided against and damaged, and no blob held a part list for any enemy id. `$FFFF` is the offset a dead pointer converts to -- id $9A names a WRAM address in the cartridge, the same dead slot the hitbox table has -- and `DrawEnemySprite` refuses it.",
        .reads = &.{"DrawEnemySprite"},
    },
    .{
        .define = "EnMsData",
        .establishes = .init_state,
        .carry = .carried,
        .note = "The records the table above indexes, in the Game Boy's own four-bytes-a-part shape. See `EnMsPtrs`.",
        .reads = &.{"DrawEnemySprite"},
    },
    .{
        .define = "EnMsRec",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "The record being walked, computed fresh for every enemy drawn. It has an absolute home *and* a direct-page window in `TabP`, because `lda [dp],y` wants the latter and this engine's $01xx block is not the direct page; the window is re-pointed after the pointer-table read and before the part walk, which is safe because the two never overlap.",
        .reads = &.{"DrawEnemySprite"},
    },
    .{
        .define = "DrawEnY",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`drawEnemy_yPos`: the slot's camera-space row, copied out at the top of the draw so the part loop can add it without re-indexing the slot. Written and read inside one call.",
        .reads = &.{"DrawEnemySprite"},
    },
    .{
        .define = "DrawEnX",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`drawEnemy_xPos`. See `DrawEnY`.",
        .reads = &.{"DrawEnemySprite"},
    },
    .{
        .define = "DrawEnSpr",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`drawEnemy_sprite`: the id the pointer table is indexed by. See `DrawEnY`.",
        .reads = &.{"DrawEnemySprite"},
    },
    .{
        .define = "DrawEnAttr",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`drawEnemy_attr`, and it is **three of the slot's bytes exclusive-ORed together** and then masked to the high nibble: the header's base attributes at +$04, the AI's working copy at +$05 and the stun counter at +$06. A frozen enemy's palette is that third term, which is why a stun value of $10 is a palette change rather than a flag. Each part's own attribute byte is XORed with it again, so a part already drawn flipped comes back the other way up when the whole sprite is flipped.",
        .reads = &.{"DrawEnemySprite"},
    },
    .{
        .define = "PrIndex",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "$D032 `projectileIndex`. Both passes zero it at entry and walk it to three, so nothing survives a frame in it -- and it is a variable rather than a register because the original makes it one and because `CollideProjEnemies` is called from inside the loop.",
        .reads = &.{ "DrawBombs", "DrawProjectiles", "HandleBombs", "HandleProjectiles" },
    },
    .{
        .define = "PrSlot",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`hBeam_pLow`/`hBeam_pHigh` ($FFB7/$FFB8), which the original keeps as a WRAM address and the port as the slot's byte offset -- the same trade `CollEnemy` makes, and for the same reason: an offset is what X holds here and an address would have to be converted back before it could be used. Written at the top of every slot's turn.",
        .reads = &.{ "DrawBombs", "DrawProjectiles", "HandleProjectiles", "SamusShoot" },
    },
    .{
        .define = "PrType",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`hBeam_type` ($FFB9), read out of the slot at the top of its turn and used by the branch that follows. `!WeaponType` beside it is the same value in the ROM's *other* copy of it ($D08D), and the two are kept apart because the collision routines read the second and the movement reads the first.",
        .reads = &.{ "DrawProjectiles", "HandleProjectiles" },
    },
    .{
        .define = "PrWave",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`hBeam_waveIndex` ($FFBA). The working copy of the slot's own wave index -- the slot carries it between frames, this does not.",
        .reads = &.{"HandleProjectiles"},
    },
    .{
        .define = "PrFrame",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`hBeam_frameCouter` ($FFBB), the ROM's spelling. Read out of the slot, incremented, used by the spazer's spread window and the missile's speed curve, written back.",
        .reads = &.{"HandleProjectiles"},
    },
    .{
        .define = "PrTmpA",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`hTemp.a` ($FF98). **The two routines that use the trio do not agree on what it means** and that is the original's doing: it is the X offset in `samusShoot` and the direction in `handleProjectiles`, so the port names it for the HRAM byte rather than for a meaning.",
        .reads = &.{ "HandleProjectiles", "SamusShoot" },
    },
    .{
        .define = "PrTmpB",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`hTemp.b` ($FF99): the direction in `samusShoot`, the Y position in `handleProjectiles`. See `PrTmpA`.",
        .reads = &.{ "BombBeamLayBomb", "HandleProjectiles", "SamusShoot" },
    },
    .{
        .define = "PrTmpC",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`hTemp.c` ($FF9A): the Y offset in `samusShoot`, the X position in `handleProjectiles`. See `PrTmpA`.",
        .reads = &.{ "BombBeamLayBomb", "HandleProjectiles", "SamusShoot" },
    },
    .{
        .define = "PrTmpD",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`ShotDirNibble`'s own, and the one variable in this group with no Game Boy counterpart: the original builds its `%0000dulr` nibble with `SWAP A` on the pad byte, and the SNES pad's high byte has Up and Down the other way round, so the nibble has to be assembled a bit at a time and needs somewhere to assemble it.",
        .reads = &.{"ShotDirNibble"},
    },
    .{
        .define = "PrB",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "The B register of whichever of the six routines is running: the permitted-direction mask in `samusShoot`, the frame's speed in the missile and wave arms, the box edge being shifted in the hitbox test, the explosion-and-drop byte in the damage pass, and the ordinary explosion's own length in `EnemyAnimateExplosion` -- which is the register 02:$56C3 loads and 02:$56C9 increments. Owned rather than shared -- see the ownership note by `Dir` -- and written before read in every one of them. The damage pass and the explosion are the two that share a slot's frame, and they cannot collide: `EnemyDamageOrDrop` runs to its end before `EnemyCommonAI` is called at all.",
        .reads = &.{ "CollideBombOneEnemy", "CollideProjOneEnemy", "EnemyAnimateExplosion", "EnemyCheckShields", "EnemyDamageOrDrop", "HandleProjectiles", "SamusShoot" },
    },
    .{
        .define = "PrC",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "And their C: the firing direction in `samusShoot`, the box's width in the hitbox test, the direction byte in the draw, and the rotating shield nibble in `enemy_checkDirectionalShields`.",
        .reads = &.{ "CollideBombOneEnemy", "CollideProjOneEnemy", "DrawProjectiles", "EnemyCheckShields", "SamusShoot" },
    },
    .{
        .define = "WeaponType",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "$D08D `weaponType`: what `handleProjectiles` is currently moving, written where the type is read out of the slot and read by the hitbox test at the other end of the frame. The ROM keeps this *and* `hBeam_type` and writes both from the same load, which is why the port has two bytes here as well.",
        .reads = &.{"CollideProjOneEnemy"},
    },
    .{
        .define = "WeaponDir",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "$D012 `weaponDirection`, the other half of the pair above, and the one `enemy_checkDirectionalShields` eventually lines up against the enemy's shield nibble -- through `CollWeaponDir`, a frame later.",
        .reads = &.{"CollideProjOneEnemy"},
    },
    .{
        .define = "BeamCool",
        .establishes = .init_state,
        .carry = .carried,
        .note = "$D00D `samusBeamCooldown`. **Carried, and it is the only piece of firing state that is**: a held fire button counts this up to $10 and a shot clears it, so what it holds at a handover decides whether the *next* frame fires. Zero at a room load is the original's value too. The gate's own re-anchors inherit whatever the previous segment left, the way `AnimTimer` does.",
        .reads = &.{"SamusShoot"},
    },
    .{
        .define = "SprAttr",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "`hSpriteAttr` ($FFC7), the fourth of the original's sprite quartet -- `SpriteId`, `SprX` and `SprY` have been here since Phase 0a and this one arrived with the first caller that draws an object no metasprite record describes. `drawProjectiles` clears it, fills it for a missile, and clears it again after the write, which M2RoS marks with a `(why?)` and the port reproduces. 1.0 Step 22: `DrawNonGameSprite` XORs it into each part and flips on it (01:$7418-$7440), and the credits' clock writes it as each digit's attribute (05:$4015). The credits' first frame reads what play left, zero, as the Game Boy's (`src/credits.zig` measures it); the run's two frames set the X flip and clear it after (05:$59D7-$5A0B); the title clears it before its draws ($418E). 1.0 Step 25: `DrawSamus` sets it to 1 in acid or i-frames and clears it after (01:$4DFC-$4E10), and `DrawSprite` puts every part on OBP1 while it is non-zero (01:$4B95).",
        .reads = &.{ "CreditsDigit", "DrawNonGameSprite", "DrawProjectiles", "DrawSprite" },
    },
    .{
        .define = "ColPad",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "How far `LoadEnemyBox` widens the enemy's horizontal edges, and **the one place Samus's hitbox test and the projectile's resolve a different box**: 00:$3388's `SUB $05`/`ADD $05` are her own half-width and 00:$3250, the projectile's copy of the same twenty instructions, has no counterpart. Step 12b made it an argument rather than a second copy of the flip arithmetic; every caller writes it immediately before the call.",
        .reads = &.{"LoadEnemyBox"},
    },
    .{
        .define = "CollWeaponDir",
        .establishes = .init_state,
        .carry = .carried,
        .note = "$D060 `collision_weaponDir`, the fourth of the four bytes a contact leaves behind. `EnemyCollisionResults`' note has said since Step 10 that the port had no variable for it *because only a projectile writes one*; this is B5 adding it. Carried for the same reason `CollWeapon` is: it is written by the hitbox test in the play handler and read by the enemy pass afterwards, so it crosses no frame boundary of its own -- but `TransferCollision` is what ends its life, and `TransferCollision` runs after the pass. $FF is 'nothing', and $00 is a real direction, which is why it is not zeroed.",
        .reads = &.{ "EnemyCheckShields", "TransferCollision" },
    },
    .{
        .define = "SprWeaponDir",
        .establishes = .init_state,
        .carry = .carried,
        .note = "**Step 12f gave it its reader**: `enemy_getSamusCollisionResults` hands it on to `EnWeaponDir` for the missile door, which asks which side a missile came from. Carried, because a contact recorded on one frame is handed on by the pass that reaches the slot, frames later. Before that: $C469 `enSprCollision.weaponDir`, the AI-facing copy of the byte above -- and **a store with no reader on this cart**, exactly as it should be: the readers are enemy AIs that care which side they were shot from, and the region's three AIs do not. Written by `TransferCollision` and cleared by the drop arm. Kept rather than dropped because the routine that writes it is ported now and leaving one of four bytes out would make its address comment a lie.",
        .reads = &.{"EnemyCollisionResults"},
    },
    .{
        .define = "ObjY",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "One Game Boy OAM entry on its way into the SNES shadow. `PutObject`'s four arguments are exactly the four bytes such an entry is, and they exist because `drawProjectiles` writes them raw where every other caller has a metasprite record -- see `PutObject`. Written and read inside one call.",
        .reads = &.{"PutObject"},
    },
    .{
        .define = "ObjX",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "See `ObjY`.",
        .reads = &.{"PutObject"},
    },
    .{
        .define = "ObjTile",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "See `ObjY`.",
        .reads = &.{"PutObject"},
    },
    .{
        .define = "ObjAttr",
        .establishes = .zeroed,
        .carry = .scratch,
        .note = "See `ObjY`. This is the byte the Game-Boy-to-SNES attribute translation reads, so it is where the two flips and the palette bit change meaning.",
        .reads = &.{"PutObject"},
    },
    .{
        .define = "DeathMode",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "Step 15c. The Game Boy's `gameMode` ($FF9B) for the death's three modes, $06 dying, $05 dead and $07 game over, and zero on every other frame; `!DEATH_RESUME` for the one frame `killSamus` spends after its wait. Written by `KillSamus`, `DeathFrame` and `DeathErase` (NMI, $06 to $05). Zero at every anchor, since no graded stretch dies, and `Reset` clears it on the reboot, which is how the death rung sees one.",
        .reads = &.{"MainLoop"},
    },
    .{
        .define = "DeathTimer",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$D059 `deathAnimTimer`: $20 from the frame after the kill, counted down by `DeathErase` in NMI once every four frames. Nonzero is what makes NMI run the death's handler instead of its own, and the horizontal Samus-enemy collision refuses on it (00:$32DD).",
        .reads = &.{ "CollideSamusEnemiesHoriz", "DeathErase", "NMI" },
    },
    .{
        .define = "DeathFlag",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "$D063 `deathFlag`: 1 from the frame after the kill, $FF once the erase is done. Its readers act on one frame only, the one `killSamus` returns into: `HandlePose` takes the pad away and `CollideGuard` refuses every Samus-enemy pass. 1.0 Step 19b: `queenHandler` (03:$6E36) only draws her while Samus dies.",
        .reads = &.{ "CollideGuard", "HandlePose", "QueenHandler" },
    },
    .{
        .define = "DeathNoise",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "`sfxPlaying_noise` ($CED6) for the one sound the death waits on, as its timer plus one. The port has no driver; `noiseSfx_init_B` sets $B0 (04:$57FD) and `handleAudio` runs it down once a frame, and `gameMode_dead` waits until it stops.",
        .reads = &.{ "DeathAudioNoise", "DeathFrame" },
    },
    .{
        .define = "DeathBlank",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "The frames the Game Boy's LCD is off while `gameMode_dead` redraws, counted down by `DeathFrame`. While it is nonzero NMI does no video, which is also what keeps NMI off the DMA registers `GameOverScreen` is using. Measured by `death.zig`, not derived.",
        .reads = &.{ "DeathFrame", "NMI" },
    },
    .{
        .define = "DeathPass",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "Which half of `gameMode_gameOver`'s two-frame pass is next: the read and the wait, or the test.",
        .reads = &.{"DeathFrame"},
    },
    .{
        .define = "DeathPad",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "The pad as the death's last `main_readInput` left it, so an edge spans the frames between reads as the Game Boy's does. `Reset` clears it with the rest of work RAM.",
        .reads = &.{"DeathReadPad"},
    },
    .{
        .define = "CannonHold",
        .establishes = .zeroed,
        .carry = .carried,
        .note = "Step 13a. Set by `ToggleMissiles` and cleared by the next `MainLoop`, which resumes the pass after `SamusTryShooting` -- the frame `beginGraphicsTransfer` (00:$27BA) spends waiting for the vblank handler to copy the cannon's tiles. NMI read it to do that copy until 1.0 Step 8a, when the copy became `LoadGraphics`' queue and NMI drains whatever is queued. Carried by definition: its whole purpose is to cross a frame boundary. Step 13c gave it a second value: `!CANNON_HOLD_CUTSCENE` when the toggle came from the cutscene arm, which resumes at 00:$053E instead, past the Samus block the cutscene skipped.",
        .reads = &.{"MainLoop"},
    },
    .{
        .define = "PrUnhandled",
        .establishes = .init_state,
        .carry = .carried,
        .note = "The first thing the projectile half was handed that it has no arm for, the way `EnUnhandledState` records the first enemy state and `Unhandled` the first pose. Three branches write it and all three are the bomb mechanism or the Queen: `samusShoot`'s $80 arm (01:$4EB4, which lays a bomb), the bomb beam's (01:$52CA) and the missile-in-the-mouth arm at 00:$3293. $FF means none of them has ever been reached, which on this cart's region is what the gate should see. Its one reader since 1.0 Step 2c is the debug screen, which shows it; it steers nothing.",
        .reads = &.{"DebugDraw"},
    },
    .{
        .define = "ShotDirsA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "The first of the eleven `physics` blobs `ResolveProjectiles` looks up at boot, as a three-byte pointer. They are carried in the sense every resolved pointer here is -- written once, read for the rest of the cart's life -- and they are eleven rows rather than one because the residue scan works on defines and a table that nothing resolves is a table nothing can read. This one is `samus_possibleShotDirections`, the gate on the whole of `samusShoot`.",
        .reads = &.{"SamusShoot"},
    },
    .{
        .define = "ShotPriA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`samus_shotDirectionPriority`: which single direction a d-pad combination resolves to. See `ShotDirsA`.",
        .reads = &.{"SamusShoot"},
    },
    .{
        .define = "CanXA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`samus_cannonXOffsets`. See `ShotDirsA`.",
        .reads = &.{"SamusShoot"},
    },
    .{
        .define = "CanYPoseA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`samus_cannonYOffsetsByPose`. See `ShotDirsA`.",
        .reads = &.{"SamusShoot"},
    },
    .{
        .define = "CanYAimA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`samus_cannonYOffsetsByAim`. See `ShotDirsA`.",
        .reads = &.{"SamusShoot"},
    },
    .{
        .define = "WaveSpdA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`projectile_waveSpeeds`, kept with its $80 terminator because the reader *resets* on it rather than stopping. See `ShotDirsA`.",
        .reads = &.{"HandleProjectiles"},
    },
    .{
        .define = "MissSpdA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`projectile_missileSpeeds`, kept with its $FF terminator for the same kind of reason: the reader holds the index on it and then reads the entry in front of it. See `ShotDirsA` and `MissSpdLen`.",
        .reads = &.{"HandleProjectiles"},
    },
    .{
        .define = "MissTileA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`projectile_missileSpriteTiles`. See `ShotDirsA`.",
        .reads = &.{"DrawProjectiles"},
    },
    .{
        .define = "MissAttrA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`projectile_missileSpriteAttrs`. See `ShotDirsA`.",
        .reads = &.{"DrawProjectiles"},
    },
    .{
        .define = "BeamSndA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`projectile_beamSounds`, which feeds `Sfx1` -- an id with no driver behind it, exactly as `Song` is. See `ShotDirsA`.",
        .reads = &.{"SamusShoot"},
    },
    .{
        .define = "WpnDmgA",
        .establishes = .init_state,
        .carry = .carried,
        .note = "`weapon_damage`, the one of the eleven that lives in bank 2 rather than bank 1. See `ShotDirsA`.",
        .reads = &.{"EnemyDamageOrDrop"},
    },
    .{
        .define = "MissSpdLen",
        .establishes = .init_state,
        .carry = .carried,
        .note = "How long `projectile_missileSpeeds` is, because its reader wants the entry two from the end and the original writes that as an absolute `LD A,($51C1)` at 01:$51D6. Taken off the blob rather than baked, the way `BombArcLen` is -- so the number comes out of the conversion and not out of `engine/main.asm`.",
        .reads = &.{"HandleProjectiles"},
    },
    .{
        .define = "ItemUnhandled",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"DebugDraw"},
        .note = "The missile refill's branch for 'every Metroid is dead' recorded the item that reached it here from 1.0 Step 10, while game mode $12 was not ported (`!ITEM_CREDITS` held the pickup). **Since 1.0 Step 22 the mode is ported** (`CreditsFrame`) and nothing writes this; it stays zero. Its one reader since 1.0 Step 2c is the debug screen's status line, which shows it; it steers nothing.",
    },
    .{
        .define = "EnWeapon",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnAiAlpha", "EnAiArachnus", "EnAiFlittMoving", "EnAiGamma", "EnAiHatchingAlpha", "EnAiItemOrb", "EnAiLarva", "EnAiMissileBlock", "EnAiMissileDoor", "EnAiOmega", "EnAiSeptogg", "EnAiWallfire", "EnAiZeta" },
        .note = "$C46D, what `enemy_getSamusCollisionResults` leaves for the AI that called it. $FF is 'not this enemy'; the routine writes that first and only overwrites it on a match, so the value is never carried between AIs.",
    },
    .{
        .define = "HurtFlag",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"HurtSamus"},
        .note = "$C422, and **it is carried across a frame boundary by design**: the collision that sets it runs after the pose machine, and the only reader runs before the pose machine on the next frame. That one-frame gap is the original's ordering at 00:$05CF and it is visible in the reference -- the segment extension's contact is at frame 701 and the knockback pose at 702.",
    },
    .{
        .define = "BoostDir",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"HurtSamus"},
        .note = "$C423. Written by `CollideResolve` on the frame of contact and read by `HurtSamus` on the next, for the same reason `HurtFlag` is. $01 is right and $FF is left; the choice is which half of the enemy's hitbox Samus's point fell in.",
    },
    .{
        .define = "DmgValue",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{ "CollideSamusEnemiesDown", "HurtSamus" },
        .note = "$C424, the enemy's own damage byte. Carried like the two above, and read a second time inside the frame: `CollideSamusEnemiesDown` uses it to decide whether a hit lifts Samus out of the enemy: only at $00 or $FF. A solid (frozen) enemy's hit writes nothing here, so that test reads the *last* hurt's or screw hit's damage, and a new game's zero until she is first hurt (1.0 Step 8d).",
    },
    .{
        .define = "SprCollDone",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"CollideSamusEnemies"},
        .note = "$C425 `samusSpriteCollisionProcessedFlag`. `scratch` and not `carried` because `MainLoop` clears it at the top of every play frame, immediately before `HurtSamus` -- so whatever the opening left cannot be read. Only the standard entry tests and sets it; the three called from inside the collision routines deliberately do not, which is what lets a walk and the frame's own pass both find the same enemy.",
    },
    .{
        .define = "CollWeapon",
        .establishes = .init_state,
        .carry = .scratch,
        .reads = &.{ "EnemyCheckShields", "EnemyDamageOrDrop", "QueenHeadCollision", "QueenProjectilesActive", "TransferCollision" },
        .note = "`collision_weaponType`. Written by every arm of `CollideResolve` and by `CollideBottom`. **Step 11 gave it its first reader and it is not the one B5 will add**: `TransferCollision` is the enemy handler's own exit (02:$4318), which copies this into `!SprWeapon` and clears it, so an AI asking about contact reads the *previous* frame's. B5's readers -- `enemy_getDamagedOrGiveDrop` and the projectile code -- are still absent. Scratch rather than carried: the transfer overwrites it before anything reads it. 1.0 Step 19b: the Queen's spit state reads and clears it (03:$758F, $75B4): a missile or the screw takes a spit out. 1.0 Step 19c: and her `queen_headCollision` (03:$6EBA), which spends a missile on her head or mouth; in her room nothing else reads it between.",
    },
    .{
        .define = "CollEnemy",
        .establishes = .init_state,
        .carry = .scratch,
        .reads = &.{ "EnemyDamageOrDrop", "QueenHeadCollision", "QueenProjectilesActive", "TransferCollision" },
        .note = "`collision_pEnemy`, and this port stores the slot's **byte offset** where the original stores its WRAM address, because that is what X holds and an address would have to be converted back before any reader could use it. Read by `TransferCollision` from Step 11, as a pair with `CollWeapon`.",
    },
    .{
        .define = "SpiderContact",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "PoseSpider", "PoseSpiderFall", "PoseSpiderJump", "PoseSpiderRoll", "SpiderContacts", "SpiderTry" },
        .note = "$D03D `spiderContactState`: the four corners as bits, set by `SpiderContacts` (00:$1A42), which every spider pose calls before it reads the result. Step 14b.",
    },
    .{
        .define = "SpiderDir",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"SpiderTry"},
        .note = "$D042 `spiderBallDirection`, looked up and read inside one `SpiderTry`. Step 14b.",
    },
    .{
        .define = "SpiderDisp",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"PoseSpiderRoll"},
        .note = "$D043 `spiderDisplacement`: cleared at the top of each try (00:$10C8) and read at its end. Step 14b.",
    },
    .{
        .define = "SpiderRot",
        .establishes = .zeroed,
        .carry = .carried,
        .reads = &.{"SpiderTry"},
        .note = "$D044 `spiderRotationState`, 1 counter-clockwise and 2 clockwise. Set by a pad press in `PoseSpider` (00:$1074) and read on every later frame of the roll, so it spans frames. Every entry into the spider clears it (00:$1796, $125E, $17B2, $0EDE); a handover into a rolling spider would carry whatever the cart had, and none of the published runs or the recording's graded stretches hands over mid-roll.",
    },
    .{
        .define = "SpiderTmp",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "PoseSpider", "SpiderPadNibble", "SpiderTry" },
        .note = "The spider handlers' own scratch, written before every read. Step 14b.",
    },
    .{
        .define = "SpiderPad",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{"SpiderPadNibble"},
        .note = "`SpiderPadNibble`'s copy of the pad word it was handed. Step 14b.",
    },
    .{
        .define = "SpiderDirA",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"SpiderTry"},
        .note = "Far pointer to `spiderDirectionTable`, resolved once at boot by `ResolveProjectiles`.",
    },
    .{
        .define = "SpiderOrientA",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"PoseSpider"},
        .note = "Far pointer to `spiderBallOrientationTable`, resolved once at boot by `ResolveProjectiles`.",
    },
    .{
        .define = "OnSolidSprite",
        .establishes = .zeroed,
        .carry = .scratch,
        .reads = &.{ "EnAiFlittMoving", "EnAiSeptogg", "PoseBallFall", "PoseFall", "SpiderDown", "SpiderLand" },
        .note = "$C43A `samus_onSolidSprite` (00:$1F19; the address here read $C426 until Step 14b). Cleared by the two vertical collision loops and set by `CollideBottom`; **Step 14b gives it its readers**, both the spider ball's: a floor that is an enemy is not snapped to (00:$115E, 00:$1233). **1.0 Step 8d adds the fall's and the falling ball's**, the same skip (00:$1378, 00:$12E7), missing until the `beams` rung's `ice stand` found it. Written by the probe that precedes each read in the same frame, so scratch rather than carried. **1.0 Step 11 adds the two platforms that carry her**, the septogg (02:$684E) and the moving flitt (02:$691A, $6943): each reads it in the enemy pass, after the same frame's probe set it.",
    },
    .{
        .define = "EnFrame",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{ "AlphaCoin", "EnAiAlpha", "EnAiAutom", "EnAiAutrack", "EnAiBaby", "EnAiBlobProjectile", "EnAiChuteLeech", "EnAiCrawlerA", "EnAiCrawlerB", "EnAiDrivel", "EnAiDrivelSpit", "EnAiFlittMoving", "EnAiGamma", "EnAiGlowFly", "EnAiGravitt", "EnAiGunzoo", "EnAiHalzyn", "EnAiHatchingAlpha", "EnAiLarva", "EnAiMissileBlock", "EnAiMoto", "EnAiOmega", "EnAiRockIcicle", "EnAiSenjoo", "EnAiSeptogg", "EnAiSkorpHori", "EnAiSkorpVert", "EnAiSkreek", "EnAiWallfire", "EnAiZeta", "EnemyAnimateDrop", "EnemyAnimateExplosion", "EnemyAnimateIce", "EnemyToggleVisibility", "MetroidOscillateNarrow", "MetroidOscillateWide", "ProcessEnemies" },
        .note = "`hEnemy_frameCounter`. **Incremented once per pass, and a pass happens every other frame**, so it counts at 30 Hz and an AI that halves it again animates at 15. Its phase at a handover is exactly as unmeasured as `EnOsc`'s and for the same reason; if a graded stretch ever puts a Senjoo's bob one step out, this is the second byte to measure. Step 12e added two readers and **one of them is a substitution rather than a port**: `enemy_animateDrop` divides this same counter ($FFFE) for the drop's blink, which is a port, and `.becomeDrop`'s 50% drop-nothing roll reads `rDIV` on the Game Boy -- a free-running divider this machine has no counterpart for -- so the roll reads this counter's low bit instead. It was chosen over `!FrameCount`, which was the approved source and could not have worked: the enemy pass acts only on the frames `!EnSame` is clear, `!EnSame` toggles once per call on every frame whose door index is zero, so `!FrameCount & 1` is a constant for as long as Samus is in the room and every kill in that room would have rolled identically. The low bit of *this* counter alternates between acting passes. **Nothing measured the Game Boy's `rDIV` here and nothing can**: the substitution is not claimed to reproduce which corpses drop, only that half of them do. **Step 13c adds a third substitution at the same kind of site**: the Alpha's hurt reaction reads `rDIV`'s low bit twice (02:$6D2F and $6D54) to pick its second knockback axis, and `AlphaCoin` reads this counter's instead, for the reason the drop roll does. The enemy oracle does not grade the coin; it hands the cart the Game Boy's.",
    },
    .{
        .define = "EnSame",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"ProcessEnemies"},
        .note = "`enemy_sameEnemyFrameFlag`. **This is the 30 FPS gate and Step 9 mistook it for the `rLY` lag mechanism.** On the Game Boy the two are tangled -- the flag is also how a pass that ran out of scanlines resumes -- but the untangling is measurable: with no lag the flag simply alternates, and on the frames it is set `enemiesLeftToProcess` is still zero, so the pass returns having done nothing. Dropping it ran every enemy AI at twice the original's rate.",
    },
    .{
        .define = "EnLeftN",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"ProcessEnemies"},
        .note = "`enemiesLeftToProcess`. Reloaded from `!EnTotal` at the top of a pass and counted down one live slot at a time; reaching zero is what ends the pass, and on a frame the gate skips it is already zero, which is *how* the gate skips.",
    },
    .{
        .define = "EnUnhandledState",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{ "DebugDraw", "QueenStateUnported" },
        .note = "The first enemy state `EnemyCommonAI` was handed that this cart has no handler for -- a drop, an explosion or a freeze -- as the slot offset of the byte that was set. The same shape as `!Unhandled`, and here for the same reason: three branches whose handlers belong to later steps are ported as tests, and a test that fires needs somewhere to say so. Step 13c had the Alpha's `.death` record `$80` here; Step 13d ported the death and retired that arm, and 1.0 Step 8b ported the freeze (`EnemyAnimateIce`), the last. **Nothing writes it now but the room load's clear**; it stays because the debug screen's status line shows it and `snes boot`'s code 176 reads it as zero. 1.0 Step 19b: in her room, the first Queen state her dispatch has no handler for (Step 20's), which the menu shows the same way.",
    },
    .{
        .define = "EnUnhandledAi",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{ "DebugDraw", "EnemyCommonAI" },
        .note = "The first AI pointer `AiTable` did not know. The dispatch is a table from Game Boy address to ported routine rather than the original's `jp hl`, because the pointer in the slot is a bank-2 address that means nothing here -- so \"which AIs does this cart have\" is a question with a written answer, and this is where an unwritten one is recorded.",
    },
    .{
        .define = "BombArcA",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"PoseBombed"},
        .note = "`ResolvePhysics` finds the knockback arc's blob once and this holds it. In `$01xx` rather than the direct page, which has sixteen bytes left and three enemy tables that need them more; `!TabP` is the dereference slot it is copied into. Carried in the sense the other resolved pointers are: written at boot and never again.",
    },
    .{
        .define = "BombArcLen",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"PoseBombed"},
        .note = "What the arc's $80 terminator became when `physics.encodeArc` dropped it, exactly as `JumpArcLen` is -- so the index that would have read the sentinel is the index that ends the knockback.",
    },
    .{
        .define = "SprHbA",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"SpriteHitboxTop"},
        .note = "`collision_samusSpriteHitboxTop`, the per-pose top of Samus's hitbox for *sprite* collisions. A different table from `HitboxP`'s and a different bias; the two being confusable is why both are named after the tables rather than after what they are for.",
    },
    .{
        .define = "DmgPoseA",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"HurtSamus"},
        .note = "`samus_damagePoseTable`: which knockback pose a hit puts Samus into, indexed by the pose she was in with the turnaround bit cleared.",
    },
    .{
        .define = "BombPoseA",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"PoseBombed"},
        .note = "`samus_bombedFallingPoses`: which falling pose the knockback arc leaves her in. Read once, when the arc runs out.",
    },
    .{
        .define = "EnDmg",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"EnemyDamageFor"},
        .note = "`enemy_damage`, one byte per enemy id and no pointer table, because the id is the index. $FF is solid, $FE drains, $00 is intangible and anything else is BCD health -- four cases, and every one of them is a branch `CollideResolve` takes.",
    },
    .{
        .define = "EnHbox",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"LoadEnemyBox"},
        .note = "`enemy_hitboxes`, four signed bytes a record. In the direct page because `LoadEnemyBox` dereferences it with an index four times per slot per pass.",
    },
    .{
        .define = "EnXPtrs",
        .establishes = .boot_script,
        .carry = .carried,
        .reads = &.{"LoadEnemyBox"},
        .note = "The converted hitbox pointers, one byte offset per enemy id. 254 of the 255 relocate; id $9A's names a WRAM address in the cartridge and becomes `entity.dead_pointer`, which `LoadEnemyBox` refuses by value rather than reading four bytes of the next blob.",
    },
    .{
        .define = "FramePhase",
        .establishes = .zeroed,
        .carry = .unread,
        .reads = &.{},
        .note = "Set by `MainLoop`'s first frame when `!FrameCount` is not `BootFrameCount` plus one, and read by the gate rather than by the engine -- so `unread` here is the right answer and not a finding. It exists because the quantity is unobservable from outside: the seed is `InitState`'s, the increments are NMI's, and how many of the latter fall between them is a function of how long boot took. See `docs/bug_tracker.md`, 2026-09-09.",
    },
    .{
        .define = "EnData",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{ "LoadEnemiesHoriz", "LoadEnemiesVert", "LoadOneEnemy" },
        .note = "The spawn-list blob, resolved once by `InitEntities`. `init_state` rather than `boot_record`: it is a directory lookup, not a field. In the direct page because `lda [dp],y` is the only indexed read through a 24-bit pointer and its operand has to be a direct-page address -- which is why these four sit apart from the rest of the entity variables.",
    },
    .{
        .define = "EnPtrs",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"SpawnListAt"},
        .note = "One byte offset into `EnData` per screen, 1792 of them. The conversion is the relocation: the ROM stores bank-3 addresses.",
    },
    .{
        .define = "EnHdrs",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"LoadOneEnemy"},
        .note = "The 11-byte enemy headers. Nine bytes of every one are copied into the slot that loads it and the last two are the AI pointer, which is a Game Boy code address the port carries and cannot yet call.",
    },
    .{
        .define = "EnPtrs2",
        .establishes = .init_state,
        .carry = .carried,
        .reads = &.{"HeaderFor"},
        .note = "One byte offset into `EnHdrs` per enemy id, 255 of them -- the same id space the damage and hitbox tables share, which is what pins it.",
    },
};

/// The fields whose starting value a frame can observe.
pub fn carriedCount() usize {
    var n: usize = 0;
    for (fields) |f| if (f.carry == .carried) {
        n += 1;
    };
    return n;
}

// ---- The measurement --------------------------------------------------------

/// One line of the audit.
pub const Row = struct {
    field: Field,
    /// The Game Boy's value at the reference's frame 0, where a counterpart is
    /// pinned.
    gb: ?u32 = null,
    /// What the cart's boot leaves, in the same units.
    cart: ?u32 = null,

    pub const Status = enum {
        /// Measured, and the two agree.
        same,
        /// Measured, and they do not.
        differs,
        /// Carried, and not measured: either its Game Boy counterpart is not
        /// pinned in this repository, or the cart's side is left by the door
        /// script rather than by the boot record and the audit does not replay
        /// one. Either way it is an unclosed question, not a pass.
        unmeasured,
        /// Nothing the port runs can observe the difference.
        harmless,
    };

    pub fn status(self: Row) Status {
        if (self.field.carry != .carried) return .harmless;
        const gb = self.gb orelse return .unmeasured;
        const cart = self.cart orelse return .unmeasured;
        return if (gb == cart) .same else .differs;
    }
};

pub const Audit = struct {
    rows: []Row,
    /// The handover the whole audit is taken at, so a reader can tell which
    /// anchor these numbers belong to.
    control: u32,
    origin: u32,
    /// The reference's first few frames of walk step, in pixels per frame. The
    /// `FrameCount` finding predicts an alternation; this is what says whether
    /// one is visible.
    steps: [8]i32,
    poses: [8]u8,
    counters: [8]u8,

    pub fn deinit(self: *Audit, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        self.rows = &.{};
    }

    pub fn count(self: Audit, want: Row.Status) usize {
        var n: usize = 0;
        for (self.rows) |r| if (r.status() == want) {
            n += 1;
        };
        return n;
    }
};

fn gbValue(m: Measure, mr: oracle.MovieRef) u32 {
    const f = mr.settled.frames[0];
    return switch (m) {
        .samus_x => f.samus_x,
        .samus_y => f.samus_y,
        .camera_x => f.camera_x,
        .camera_y => f.camera_y,
        .pose => f.pose,
        .facing => f.facing,
        .input_pressed => f.pad,
        .frame_count => f.counter,
        .water => f.water,
        .map_index => mr.map_bank - map_mod.first_bank,
        .cell => mr.settled.cell(),
        .solid => mr.settled.solid,
    };
}

/// What the cart holds when `MainLoop` runs for the first time.
///
/// `frame_count` was the one this could not answer honestly, and boot record
/// version 5 is why it can now. The cart's counter used to start from the
/// cart's own reset, so its value at frame 0 said nothing about the 318 frames
/// the other one had counted; it is seeded from the measurement now, and the
/// row below adds the movie path's key lead back, because the seed carries that
/// shift and the value the first commit holds does not.
fn cartValue(m: Measure, boot: snes_screen.Boot) ?u32 {
    return switch (m) {
        .samus_x => boot.samus_x,
        .samus_y => boot.samus_y,
        // Boot record version 4. `InitState` used to put the camera exactly on
        // Samus; the audit below is what measured that it belongs somewhere
        // else, and `oracle.movieBoot` now fills these from the game.
        .camera_x => boot.cam_x,
        .camera_y => boot.cam_y,
        .pose => boot.pose,
        // `InitState` seeds 1. The Game Boy's encoding is its own, so this pair
        // is printed and not judged.
        .facing => 1,
        // `PublishPad` fills it from the movie's own held byte for this frame,
        // through `movieKey`. Comparing the cart's *supported* subset against
        // the Game Boy's raw pad byte would report a difference on every frame
        // the movie presses something the port has no key for, which is the
        // ceiling `first_unsupported` already reports.
        .input_pressed => null,
        .frame_count => @as(u32, boot.frame_count) +% @as(u32, @intCast(oracle.movie_key_lead)),
        .water => 0,
        .map_index => boot.map_index,
        .cell => boot.cell,
        // Left by the replayed door script, which the audit does not run.
        .solid => null,
    };
}

/// Run the movie to the handover and diff what it leaves against what the boot
/// record establishes.
pub fn audit(
    allocator: std.mem.Allocator,
    rom: []const u8,
    movie: tas.Movie,
) !Audit {
    var mr = try oracle.referenceFromMovie(allocator, rom, movie, 16);
    defer mr.deinit(allocator);

    const found = try oracle.movieBoot(allocator, rom, mr);

    var rows = try allocator.alloc(Row, fields.len);
    errdefer allocator.free(rows);
    for (fields, 0..) |f, i| {
        rows[i] = .{ .field = f };
        if (f.measure) |m| {
            rows[i].gb = gbValue(m, mr);
            if (found) |bf| rows[i].cart = cartValue(m, bf.boot);
        }
    }

    var steps: [8]i32 = @splat(0);
    var poses: [8]u8 = @splat(0);
    var counters: [8]u8 = @splat(0);
    for (0..@min(8, mr.settled.frames.len)) |i| {
        poses[i] = mr.settled.frames[i].pose;
        counters[i] = mr.settled.frames[i].counter;
        if (i > 0) {
            steps[i] = @as(i32, mr.settled.frames[i].samus_x) -
                @as(i32, mr.settled.frames[i - 1].samus_x);
        }
    }

    return .{
        .rows = rows,
        .control = mr.control,
        .origin = mr.origin,
        .steps = steps,
        .poses = poses,
        .counters = counters,
    };
}

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;

test "the scan reads the engine's source, not a description of it" {
    const a = testing.allocator;

    // `WalkSpeed` reads the frame counter, and the only routines that write it
    // are NMI, which advances it, and `InitState`, which seeds its phase from
    // the boot record. If either half of that changes, the file comment's
    // headline is wrong and this is where it says so.
    const fc = try sites(a, "FrameCount");
    defer a.free(fc);
    var reads_in_walkspeed = false;
    var writes_outside_nmi = false;
    for (fc) |s| {
        if (s.touch != .write and std.mem.eql(u8, s.routine, "WalkSpeed")) reads_in_walkspeed = true;
        const seeder = std.mem.eql(u8, s.routine, "NMI") or std.mem.eql(u8, s.routine, "InitState");
        if (s.touch != .read and !seeder) writes_outside_nmi = true;
    }
    try testing.expect(reads_in_walkspeed);
    try testing.expect(!writes_outside_nmi);

    // A define that does not exist finds nothing, which is what makes an empty
    // result meaningful rather than the default answer to a typo. `!Cam` is a
    // prefix of `!CamX` and `!CamY`, so this also pins the word boundary.
    const nothing = try sites(a, "Cam");
    defer a.free(nothing);
    try testing.expectEqual(@as(usize, 0), nothing.len);

    // The export block is not a use. `VarFrameCount = !FrameCount` would
    // otherwise credit a read to no routine at all, and every variable in the
    // table would look carried.
    for (fc) |s| try testing.expect(s.line != 424);
}

test "a store with an explicit width is still a store" {
    // **The scan's own defect, found on 2026-09-08 by the first variables that
    // needed absolute addressing.** `opIn` compared the whole mnemonic against
    // `sta`/`stx`/`sty`/`stz`, so `sta.w !Foo` matched none of them and was
    // classified a *read*. Every direct-page variable the port had until then
    // is written as `sta !Foo` with no suffix -- asar sizes it -- so nothing in
    // the table was wrong; the entity arrays live at $0200 and $0400 and their
    // stores carry `.w`, which made `EnChild` scan as read by the two routines
    // that only ever write it and would have made a genuinely unread variable
    // look carried. An `unread` row is this audit's cheapest finding, so a scan
    // that cannot produce one is the expensive kind of broken.
    const a = testing.allocator;
    // `EnChild` was the variable this was written against; Step 12f ported the
    // branch it recorded and it went. `SfxNoise` took its place until the
    // footstep read it (metroid2-audio Step 16a); `Sfx1` is stored with `.w` by
    // every routine that touches it and read by none.
    const found = try sites(a, "Sfx1");
    defer a.free(found);
    try testing.expect(found.len >= 2);
    for (found) |site| try testing.expectEqual(Touch.write, site.touch);
}

test "every field's reader list is what the engine actually does" {
    // The table's `reads` is a claim about `engine/main.asm`, and this is the
    // scan that refutes it. Written this way round deliberately: a reader added
    // to the engine fails here rather than silently making a `harmless` field
    // wrong, which is the failure this audit exists to prevent.
    // Every field is checked before failing, so one run names them all.
    const a = testing.allocator;
    var wrong: usize = 0;
    for (fields) |f| {
        const found = try readers(a, f.define);
        defer a.free(found);
        var same = f.reads.len == found.len;
        if (same) {
            for (f.reads, found) |claimed, actual| same = same and std.mem.eql(u8, claimed, actual);
        }
        if (same) continue;
        wrong += 1;
        std.debug.print("{s}: table says {d} readers, engine has {d}:\n", .{ f.define, f.reads.len, found.len });
        for (found) |r| std.debug.print("    {s}\n", .{r});
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "an unread field is one the scan finds no reader for" {
    // The audit's cheapest finding is \"nothing reads it\", and it is worthless
    // unless the two definitions of \"unread\" are the same one.
    const a = testing.allocator;
    for (fields) |f| {
        const found = try readers(a, f.define);
        defer a.free(found);
        if (f.carry == .unread) try testing.expectEqual(@as(usize, 0), found.len);
        if (found.len == 0) try testing.expectEqual(Carry.unread, f.carry);
    }
}

test "the audit measures the handover the movie oracle anchors on" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);

    var au = try audit(a, rom, try tas.parse(bytes));
    defer au.deinit(a);

    try testing.expectEqual(fields.len, au.rows.len);
    // The same anchor `oracle.referenceFromMovie` grades from, not a second
    // one -- asserted against that function rather than against a formula.
    //
    // It used to be `control + movie_origin_delay`, which was a restatement of
    // the rule and not a check of it: when the rule changed to
    // `pushToStableAnchor` the audit followed the oracle correctly and this
    // line failed anyway, because it was checking arithmetic instead of
    // agreement. Comparing the two answers is what the sentence above says.
    {
        var mr = try oracle.referenceFromMovie(a, rom, try tas.parse(bytes), 8);
        defer mr.deinit(a);
        try testing.expectEqual(mr.origin, au.origin);
        try testing.expectEqual(mr.control, au.control);
        // And the anchor is not the handover, which is the fact the push exists
        // for: asserting only equality would pass if both regressed together.
        try testing.expect(au.origin > au.control);
    }

    // Step 15b's work shows up here as fields that no longer differ: the
    // position, the pose and the room all come from the game.
    for (au.rows) |r| {
        const m = r.field.measure orelse continue;
        switch (m) {
            .samus_x, .samus_y, .pose, .map_index, .cell => {
                testing.expectEqual(Row.Status.same, r.status()) catch |e| {
                    std.debug.print("{s}: gb {?d} cart {?d}\n", .{ r.field.define, r.gb, r.cart });
                    return e;
                };
            },
            else => {},
        }
    }

    // And the finding: the counter the walk speed alternates on is not zero at
    // the handover, which is the state the port was assuming.
    for (au.rows) |r| {
        if (!std.mem.eql(u8, r.field.define, "FrameCount")) continue;
        // The ROM fact: the counter is a long way from zero at the handover,
        // because the opening counted every one of its frames. If this half
        // ever fails, the reference has stopped coming from the game.
        try testing.expect(r.gb.? != 0);
        // And the fix: version 5 seeds the phase, so the row agrees at a value
        // the port could not have guessed.
        try testing.expectEqual(Row.Status.same, r.status());
    }
}

test "the game's camera at the handover is not on Samus, and the boot record carries it" {
    // The finding the audit was not looking for, and the fix for it, checked
    // together because either half alone can pass for the wrong reason.
    //
    // The ROM fact first: the game's camera at a handover of control is not on
    // Samus. It is wherever the opening's own scrolling left it. If that half
    // ever fails, the reference has stopped coming from the game and nothing
    // downstream of it means anything.
    //
    // Then the fix. `InitState` used to seed the camera to Samus's position,
    // which was a sound default while the boot record described a spawn we
    // invented and is wrong for a movie. Boot record version 4 gave the camera
    // its own field, so the two Cam rows now agree -- and they agree at a value
    // that is *not* her position, which is what says the field is being filled
    // from the measurement rather than defaulted back to where it started.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);

    var mr = try oracle.referenceFromMovie(a, rom, try tas.parse(bytes), 1);
    defer mr.deinit(a);

    const f = mr.settled.frames[0];
    try testing.expect(f.camera_x != f.samus_x or f.camera_y != f.samus_y);

    // And the audit now reports the pair as the same.
    var au = try audit(a, rom, try tas.parse(bytes));
    defer au.deinit(a);
    var reported: usize = 0;
    for (au.rows) |r| {
        if (!std.mem.startsWith(u8, r.field.define, "Cam")) continue;
        try testing.expectEqual(Row.Status.same, r.status());
        reported += 1;
    }
    try testing.expectEqual(@as(usize, 2), reported);

    // Agreeing on the value the version 3 default would have produced anyway
    // would prove nothing, so check the cart's camera is the game's and not
    // hers. This is the assertion that fails if `movieBoot` stops copying.
    const boot = ((try oracle.movieBoot(a, rom, mr)) orelse return error.NoBootForCell).boot;
    try testing.expectEqual(f.camera_x, boot.cam_x);
    try testing.expectEqual(f.camera_y, boot.cam_y);
    try testing.expect(boot.cam_x != boot.samus_x or boot.cam_y != boot.samus_y);
}

test "the frame counter now advances exactly once per reference frame" {
    // A caveat that was measured, and then went away when its cause was found.
    //
    // This test used to assert the opposite: that consecutive reference frames
    // could show the same $FF97 and then skip one, so the counter's value was
    // good to about one and its parity on a named frame was not knowable. That
    // was true, and it was not a property of the counter. It was the frame
    // boundary. `tas.zig` sampled at the LY wrap, four scanlines past the point
    // in VBlank where the game does its per-frame work, so the sample landed
    // inside the increment often enough to smear it. Moving the boundary to LY
    // 144 -- for the joypad's sake, not the counter's -- made every step one.
    //
    // Kept, inverted, because the thing worth holding is that the sample point
    // is stable: `WalkSpeed`, `PoseJumpStart`, `PoseSpinJump` and `StreamDue`
    // all read the counter's low bits, and a port graded frame for frame needs
    // the reference's parity on a named frame to mean something.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);

    var au = try audit(a, rom, try tas.parse(bytes));
    defer au.deinit(a);

    // Every step is one, so the parity on a named frame is the game's own.
    for (1..au.counters.len) |i| {
        const d = @as(i32, au.counters[i]) - @as(i32, au.counters[i - 1]);
        try testing.expectEqual(@as(i32, 1), d);
    }
    // Which also makes the total the frame count, as it was before.
    const total = @as(i32, au.counters[au.counters.len - 1]) - @as(i32, au.counters[0]);
    try testing.expectEqual(@as(i32, @intCast(au.counters.len - 1)), total);
}

test "the reference does not walk into the alternation the counter feeds" {
    // Why the `FrameCount` finding could not be blamed for the divergence that
    // was in front of it, and where it did turn up in the end.
    //
    // `WalkSpeed` takes `($FF97 & 1) + 1`, so a divergence in the counter's
    // parity shows as a one-pixel-per-frame disagreement -- but only while she
    // is walking. Over the first eight reference frames the movie takes her
    // from the crouch into the morph ball, whose step is a flat two pixels, so
    // the alternation is not in play at this anchor at all. The frame-1
    // divergence of the time was something else, and saying so was the point of
    // writing this down.
    //
    // It bit at reference frame 131 instead, a hundred and twenty-three frames
    // past this window, on the first walking frame after she jumps out of the
    // ball. Boot record version 5 fixed it and the reachable-frame count went
    // from 128 to 216. This test still measures the window rather than the
    // fix -- the fix is checked by the audit row above -- because what it says
    // is that the counter cannot be read off these eight frames, and that is
    // still true.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);

    var au = try audit(a, rom, try tas.parse(bytes));
    defer au.deinit(a);

    // **The window moved with the anchor, and the claim survived it.** This
    // used to read "she starts standing and is running by the last of the
    // eight", because the anchor was `control` and the movie took her straight
    // into the run. `pushToStableAnchor` puts the anchor two frames later, at
    // the crouch, and the eight frames are now crouch into the morph ball.
    //
    // The assertion is therefore written as what actually matters rather than
    // as the two pose numbers it used to name: the pose changes inside the
    // window, so the window is not a still one, and *no frame steps by a single
    // pixel* -- which is what a walk alternating 1 and 2 would have to produce.
    // The counter's parity still cannot be read off these eight frames.
    try testing.expect(au.poses[au.poses.len - 1] != au.poses[0]);
    for (au.steps) |d| try testing.expect(d == 0 or d == 2);
}

test "the two pose dispatches offer the same set of poses" {
    // The build-time check that would have caught the ball's missing sprite
    // arm. See `pose_dispatches`: adding a pose is two edits, and until
    // 2026-09-01 nothing said so.
    const a = testing.allocator;
    const machine = try poseArms(a, pose_dispatches[0]);
    defer a.free(machine);
    const drawing = try poseArms(a, pose_dispatches[1]);
    defer a.free(drawing);

    // Neither may be empty: a scan that silently matches nothing would make
    // two empty sets "agree" and the check would pass forever.
    try testing.expect(machine.len >= 8);
    try testing.expect(drawing.len >= 8);
    try testing.expectEqual(machine.len, drawing.len);
    for (machine, drawing) |m, d| try testing.expectEqualStrings(m, d);
}

test "poseArms reads dispatch arms and not the comparisons inside handlers" {
    // `PoseJumpStart` compares `!POSE_NJUMPSTART` to tell its two entry points
    // apart, and `PoseBallJump` compares `!POSE_BALLJUMP`. Both are `cmp.b
    // #!POSE_*` in the same file, and neither is a dispatch arm -- so a scan of
    // the whole file rather than of one routine would fold them in and the
    // agreement check would fail for a reason that is not a defect.
    const a = testing.allocator;
    const inside = try poseArms(a, "PoseJumpStart");
    defer a.free(inside);
    try testing.expectEqual(@as(usize, 1), inside.len);
    try testing.expectEqualStrings("POSE_NJUMPSTART", inside[0]);

    // And a routine that dispatches on nothing yields nothing, rather than
    // inheriting the previous routine's arms.
    const none = try poseArms(a, "SamusAnchor");
    defer a.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

