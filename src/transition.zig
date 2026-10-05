//! What a door transition costs, in frames, and why the number is arithmetic
//! rather than a constant.
//!
//! Step 5 ported the transition's *state* -- the trigger, the interpreter, the
//! warp's re-seat -- and landed it with the trigger disarmed, because the port
//! completed in one frame what the original takes ninety-four. This module is
//! the other half: the rule those ninety-four frames come out of.
//!
//! ## The rule
//!
//! The door-script interpreter is a frame-paced machine. `$2C5E` is "wait one
//! frame" -- `HALT` until the vblank handler sets `$FF82` -- and the
//! interpreter calls it:
//!
//!   * once on entry, 00:$23AF, before it has even fetched the script;
//!   * once after **every** opcode, 00:$26D1, which every dispatch arm jumps
//!     to. One frame per opcode is the floor, and `END` is the only exception:
//!     00:$23E7 leaves through $26D7 and returns without waiting.
//!
//! Three opcodes cost far more than the floor, and all three cost it for the
//! same reason: **Game Boy VRAM bandwidth**.
//!
//!   * Anything that moves bytes into VRAM ends at 00:$27BA, which sets
//!     `$D047` and then waits a frame at a time until the vblank handler
//!     clears it. The handler's drain is at 00:$2BC2:
//!
//!         $2BC2  LD A,(HL+)  /  LD (DE),A  /  INC DE
//!         $2BC5  DEC BC      /  LD A,C  /  AND $3F  /  JR NZ,$2BC2
//!
//!     It copies until the *remaining* count's low six bits are zero, so it
//!     moves at most 64 bytes per vblank and a transfer of `len` bytes takes
//!     `ceil(len / 64)` frames. That is `copyFrames` below, and it is the one
//!     number in this file that is a property of the hardware rather than of
//!     the game.
//!   * `FADEOUT` (00:$2561) waits four frames outright, then loops a palette
//!     fade: `$D066` is set to $2F, the vblank handler decrements it once a
//!     frame at 00:$0172, and the loop waits a frame per iteration until it
//!     drops below $0E. That is 34 iterations, every time -- the fade is
//!     clocked by the frame counter, so it costs the same frames on any
//!     machine that runs the loop.
//!   * `WARP` (00:$28FB) waits once at $2915 and then draws the incoming
//!     screen's edge a strip at a time, waiting between strips. Three strips
//!     and two waits going right (00:$2939), left (00:$29C4) and up
//!     (00:$2B04); **four strips and three waits going down** (00:$2A4F),
//!     because a downward crossing has one more row to bring in. The
//!     asymmetry is the reason `opFrames` takes a direction at all.
//!
//! ## What the port does with it
//!
//! The SNES moves these bytes by DMA in a fraction of one frame. Two ways to
//! land the same duration:
//!
//!   1. throttle the port's own transfer to 64 bytes a vblank, so the number
//!      falls out of the same mechanism;
//!   2. transfer at SNES speed and wait out the cost this module computes.
//!
//! The port takes (2). (1) reproduces the *number* by reproducing a limit the
//! SNES does not have, and it would make every later optimisation -- a wider
//! DMA, a different VRAM layout -- silently change the game's timing. (2)
//! keeps the timing a stated quantity that a test can read. The cost of (2) is
//! that the port has to keep this table in step with the script format; the
//! test at the bottom of this file is what keeps it honest, because it grades
//! the table against the Game Boy rather than against itself.
//!
//! ## One door is one data point
//!
//! The 94 frames in `docs/bug_tracker.md` came from a single door. A constant
//! fitted to it would have been wrong for every door with a different copy
//! length, a different direction, or no fade. So the model here is graded
//! across every door the harness can drive, and the grading test reports how
//! many agreed rather than asserting on one.

const std = @import("std");
const door = @import("door.zig");
const harness = @import("gb/harness.zig");
const probe = @import("gb/probe.zig");
const inject = @import("snes_inject.zig");
const tas = @import("tas.zig");
const room = @import("room.zig");
const convert = @import("snes_convert.zig");

const testrom = @import("testrom");

// ---- The rule -------------------------------------------------------------

/// Bytes the vblank handler's drain moves per frame, from `C & $3F` at
/// 00:$2BC7. Not a tuning constant: change it and the loop is a different
/// loop.
pub const vblank_copy_bytes: usize = 0x40;

/// Frames a `len`-byte transfer spends in the queue, from 00:$27BA's wait and
/// 00:$2BC2's drain. A zero-length transfer still costs the one frame $27BA
/// waits before it looks at `$D047`.
pub fn copyFrames(len: usize) usize {
    if (len == 0) return 1;
    return (len + vblank_copy_bytes - 1) / vblank_copy_bytes;
}

/// The interpreter waits one frame before fetching anything. 00:$23AF.
pub const entry_frames: usize = 1;

/// `FADEOUT`'s four outright waits, 00:$2563-$256C.
pub const fade_hold_frames: usize = 4;

/// `$D066` starts at $2F (00:$256F) and the loop runs while it is >= $0E
/// (00:$258F), decremented once a frame by the vblank handler at 00:$0172.
pub const fade_start: usize = 0x2F;
pub const fade_floor: usize = 0x0E;
pub const fade_steps: usize = fade_start - fade_floor + 1;

/// Bytes `LOAD` moves, from the lengths it hardcodes into the queue. Variant
/// 1 pushes $0800 to $9000 (00:$2739-$2743) and every other variant $0400 to
/// $8B00 (00:$270D-$2717) -- which is `door.zig`'s `.bg` and `.spr` in that
/// order, and the destinations agree with the names: $9000-$97FF is the
/// background-only tile block, $8B00 sits inside the block objects can reach.
pub const load_bg_bytes: usize = 0x0800;
pub const load_spr_bytes: usize = 0x0400;

/// The 20-byte strip `ESCAPE_QUEEN` (00:$24A1) and `EXIT_QUEEN` (00:$24F6)
/// push to $9C00.
pub const queen_strip_bytes: usize = 0x0014;

/// `ITEM`'s four transfers: 00:$2648, $2663, $2689 and $26C3.
pub const item_bytes = [_]usize{ 0x0040, 0x0040, 0x0230, 0x0010 };

/// Strips the warp's draw arm pushes, and the waits between them. Going down
/// brings in one more row than the other three directions do.
pub fn warpWaits(direction: u8) usize {
    return switch (direction) {
        1 => 2, // right, 00:$2939: waits at $296E and $2998
        2 => 2, // left,  00:$29C4: $29F9 and $2A23
        4 => 2, // up,    00:$2B04: $2B39 and $2B63
        8 => 3, // down,  00:$2A4F: $2A84, $2AAE and $2AD8
        // Anything else falls through the compare chain to the RET at
        // 00:$2938: the room changes and nothing is drawn.
        else => 0,
    };
}

/// Frames one opcode occupies, from the moment the interpreter dispatches it
/// to the moment it dispatches the next one.
///
/// `direction` is `$D00E`, which only `WARP` reads.
pub fn opFrames(op: door.Op, direction: u8) usize {
    // Every arm ends `JP $26D1`, which waits a frame. The exceptions say so.
    const dispatch: usize = 1;
    return switch (op) {
        // 00:$2402 -> $2747, three variants, all ending at $27BA.
        .copy => |c| dispatch + copyFrames(c.len),
        // 00:$2417 -> $282A, which selects the tile table and then falls
        // out of its own routine with `JP $2918` (00:$2856) -- straight into
        // the middle of the warp handler, at the direction dispatch. So a
        // tile-table change redraws the incoming screen's edge exactly the way
        // a warp does, and costs the same strips. Measured, not assumed: it is
        // three frames going right, left and up and four going down, which is
        // the only reason this arm takes a direction.
        .tiletable => dispatch + warpWaits(direction),
        // 00:$2421 -> $2859.
        .collision => dispatch,
        // 00:$242B, inline.
        .solidity => dispatch,
        // 00:$245F -> $28FB: one wait at $2915, then the draw arm's.
        .warp => dispatch + 1 + warpWaits(direction),
        // 00:$247A, a 20-byte strip through $24AE.
        .escape_queen => dispatch + copyFrames(queen_strip_bytes),
        // 00:$24B8. Two stores.
        .damage => dispatch,
        // 00:$24CE, the same strip through $2503.
        .exit_queen => dispatch + copyFrames(queen_strip_bytes),
        // 00:$250A: one wait at $2524, and then a third frame that is **not**
        // a wait. This is the one cost in the table that is measured rather
        // than derived, and it is worth being explicit about why: after the
        // wait, 00:$252A calls $2887, which reads the nine-byte operand and
        // draws the whole Queen's room through $0673 -- and that work takes
        // longer than one frame on a Game Boy, so a vblank passes inside it
        // before the `JP $26D1` at $253D waits again. Three frames, in every
        // direction, on every script in the ROM that uses it.
        //
        // A compute overrun is not a rule the port can reproduce: the 65816
        // does the same work in far less than a frame and would come out at
        // two. Nothing on the slice's path reaches this opcode -- it is the
        // Queen's room, which `docs/feature_tracker.md` defers as B8 -- so the
        // number here is the Game Boy's, recorded, and B8 gets to decide what
        // the port should do with it rather than inheriting a guess.
        .enter_queen => dispatch + 2,
        // 00:$2540. The not-taken branch falls to $26D1; the taken branch
        // (00:$255A) jumps to $239C instead and pays that entry's wait at
        // $23AF *in place of* $26D1's, so both cost one. `scriptFrames`
        // therefore charges only the first entry. Measured on door $04A at
        // $46: charging the re-entry as well came out one frame long.
        .if_met_less => dispatch,
        // 00:$2561.
        .fadeout => dispatch + fade_hold_frames + fade_steps,
        // 00:$23ED -> $26EB, two variants, both ending at $27BA.
        .load => |l| dispatch + copyFrames(switch (l.which) {
            .bg => load_bg_bytes,
            .spr => load_spr_bytes,
        }),
        // 00:$259E. Stores, and a driver call that does not wait.
        .song => dispatch,
        // 00:$2614: four transfers.
        .item => blk: {
            var n: usize = dispatch;
            for (item_bytes) |len| n += copyFrames(len);
            break :blk n;
        },
        // 00:$23E7 -> $26D7 -> RET. The only opcode that does not wait.
        .end => 0,
    };
}

// ---- Walking a script -----------------------------------------------------

/// A script the interpreter would run, in the order it would run it.
pub const Script = struct {
    /// The interpreter copies $40 bytes to $D700 (00:$23D3) and executes from
    /// there, so an opcode past byte 64 is never reached.
    pub const window: usize = 0x40;

    ops: [64]door.Op = undefined,
    count: usize = 0,
    /// Interpreter entries: one for the call, plus one per taken
    /// `IF_MET_LESS`, each of which restarts the fetch at 00:$239C.
    entries: usize = 1,
    /// The script ran off the end of the 64-byte window without a terminator.
    truncated: bool = false,
};

pub const Error = error{ BadDoorIndex, BadScript };

/// Index 0 is "no transition pending", not door zero: 00:$239C ORs the two
/// halves of `$D08E` together and returns through $26D7 without waiting when
/// they are both clear. The port spells the same rule `beq` on `!DoorIndex`.
pub const no_door: u16 = 0;

/// Decode the script for `index`, following `IF_MET_LESS` the way the
/// interpreter does: `met_count` is `$D089`, and the branch is taken when the
/// operand is *not* below it (00:$254A `CP B` / `JR NC`).
pub fn script(rom: []const u8, index: u16, met_count: u8) Error!Script {
    const ptrs = door.pointers(rom) orelse return Error.BadDoorIndex;
    const body = door.region(rom) orelse return Error.BadDoorIndex;

    var out: Script = .{};
    if (index == no_door) {
        out.entries = 0;
        return out;
    }
    var index_now = index;
    // A cycle of taken branches would loop forever; the real interpreter would
    // too, so bound it rather than pretending it cannot happen.
    var hops: usize = 0;
    while (hops < 8) : (hops += 1) {
        const at = @as(usize, index_now) * 2;
        if (at + 1 >= ptrs.len) return Error.BadDoorIndex;
        const gb_addr = std.mem.readInt(u16, ptrs[at..][0..2], .little);
        if (gb_addr < door.data_addr) return Error.BadScript;
        const start: usize = gb_addr - door.data_addr;
        if (start >= body.len) return Error.BadScript;

        const end = @min(start + Script.window, body.len);
        var r: door.Reader = .{ .bytes = body[start..end] };
        while (true) {
            if (out.count == out.ops.len) {
                out.truncated = true;
                return out;
            }
            const op = door.decodeOne(&r) catch {
                out.truncated = true;
                return out;
            };
            out.ops[out.count] = op;
            out.count += 1;
            switch (op) {
                .end => return out,
                .if_met_less => |m| {
                    if (m.met_count >= met_count) {
                        // 00:$2552: the operand replaces $D08E/$D08F and the
                        // interpreter restarts from the top.
                        index_now = m.transition;
                        out.entries += 1;
                        break;
                    }
                },
                else => {},
            }
        }
    }
    return Error.BadScript;
}

/// Frames the interpreter spends on a whole script, entry waits included.
pub fn scriptFrames(s: Script, direction: u8) usize {
    // One entry wait, however many entries: a taken `IF_MET_LESS`'s re-entry
    // is that opcode's own frame, which `opFrames` already counts.
    var n: usize = @min(s.entries, 1) * entry_frames;
    for (s.ops[0..s.count]) |op| n += opFrames(op, direction);
    return n;
}

// ---- The Game Boy measurement ---------------------------------------------

/// Where the door-script interpreter re-reads the next opcode: 00:$23E1,
/// `LD A,(HL)` with HL on the opcode inside the $D700 copy. Every opcode
/// passes through it exactly once, which makes it the boundary a per-opcode
/// frame cost is measured across.
pub const dispatch_pc: u16 = 0x23E1;

/// The Metroid counter the `IF_MET_LESS` branch compares against, 00:$2545.
pub const met_count_addr: u16 = 0xD089;

/// The vblank vector. A transition's frames are counted here rather than off
/// the LCD's own frame counter, and the difference is not cosmetic: the LCD
/// completes a frame at the end of line 153, while `$2C5E`'s wait resumes in
/// the middle of line 144. Counting LCD frames therefore loses or gains one
/// depending on where in the frame the interpreter was entered, and the
/// interpreter is entered from wherever the main loop happened to be. The
/// vblank handler is the clock the game itself counts by -- it is what
/// decrements the fade counter at 00:$0172 and what drains the copy queue at
/// 00:$2BC2 -- so counting its entries is measuring the same thing the
/// original is waiting for.
pub const vblank_vector: u16 = 0x0040;

pub const Step = struct {
    opcode: u8,
    /// Vblanks from this opcode's dispatch to the next one's.
    frames: usize,
};

pub const Measured = struct {
    door: u16,
    direction: u8,
    /// The interpreter returned rather than running out of budget.
    returned: bool,
    /// Frames from the call to the return.
    total: usize,
    /// Frames before the first opcode was dispatched: the entry wait.
    entry: usize,
    steps: [64]Step = undefined,
    step_count: usize = 0,

    pub fn slice(self: *const Measured) []const Step {
        return self.steps[0..self.step_count];
    }
};

/// Run one door's script on the Game Boy and time every opcode in it.
///
/// The machine is left where it was: a script that warps has moved Samus and
/// swapped the map bank, and a caller measuring a second door wants the first
/// one's booted state, not its destination. The snapshot is the same lever
/// `room.spawn` uses, for the same reason.
pub fn measure(
    allocator: std.mem.Allocator,
    m: *harness.Machine,
    index: u16,
    direction: u8,
) !Measured {
    var snap = try m.snapshot();
    defer snap.deinit(allocator);
    defer m.restore(snap);

    m.writeWord(probe.door_index_addr, index);
    m.write(probe.door_direction_addr, direction);

    const sys = &m.sys;
    const cpu = &sys.cpu;
    // Interrupts stay as the booted machine had them: every wait in here is a
    // `HALT` for vblank, and a machine with IME clear would sit in the first
    // one until the budget ran out.
    cpu.halted = false;
    cpu.sp -%= 2;
    sys.bus.write(cpu.sp, @truncate(probe.sentinel));
    sys.bus.write(cpu.sp +% 1, @truncate(probe.sentinel >> 8));
    cpu.pc = probe.interp_entry;

    var frames: usize = 0;
    var out: Measured = .{
        .door = index,
        .direction = direction,
        .returned = false,
        .total = 0,
        .entry = 0,
    };
    var last_frame: usize = 0;
    var have_step = false;

    // A fade is ~40 frames and a sprite load 33, so a long script is a few
    // hundred frames of emulation. The budget is an order of magnitude past
    // the longest script in the ROM.
    const budget: usize = 8_000_000;
    var n: usize = 0;
    while (n < budget) : (n += 1) {
        if (cpu.pc == probe.sentinel) {
            out.returned = true;
            break;
        }
        if (cpu.pc == vblank_vector) frames += 1;
        if (cpu.pc == dispatch_pc) {
            const now = frames;
            if (!have_step) {
                out.entry = now;
                have_step = true;
            } else if (out.step_count > 0) {
                out.steps[out.step_count - 1].frames = now - last_frame;
            }
            if (out.step_count < out.steps.len) {
                const hl = (@as(u16, cpu.h) << 8) | cpu.l;
                out.steps[out.step_count] = .{ .opcode = sys.bus.read(hl), .frames = 0 };
                out.step_count += 1;
            }
            last_frame = now;
        }
        _ = try sys.step();
    }
    if (out.step_count > 0) {
        out.steps[out.step_count - 1].frames = frames - last_frame;
    }
    out.total = frames;
    return out;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

/// Print the per-opcode comparison for one script. Only a failing test calls
/// it, and what it is for is turning "the model is two frames short" into
/// "`ITEM` is two frames short", which is the difference between a number and
/// a lead.
fn printDisagreement(
    a: std.mem.Allocator,
    m: *harness.Machine,
    rom: []const u8,
    met: u8,
    index: u16,
    direction: u8,
) !void {
    const s = try script(rom, index, met);
    const measured = try measure(a, m, index, direction);
    std.debug.print("  door ${X:0>3} dir {d}: entry model {d} machine {d}\n", .{
        index, direction, @min(s.entries, 1) * entry_frames, measured.entry,
    });
    for (s.ops[0..s.count], 0..) |op, i| {
        const got: ?usize = if (i < measured.step_count) measured.steps[i].frames else null;
        std.debug.print("    [{d}] {s: <13} model {d: >3}  machine {?d: >3}\n", .{
            i, @tagName(std.meta.activeTag(op)), opFrames(op, direction), got,
        });
    }
    if (measured.step_count != s.count) {
        std.debug.print("    the interpreter ran {d} opcodes, the decoder found {d}\n", .{
            measured.step_count, s.count,
        });
    }
}

test "the drain moves sixty-four bytes a frame, and a short transfer still costs one" {
    // 00:$2BC2's loop stops when the remaining count is a multiple of 64, so a
    // transfer of exactly 64 is one frame and 65 is two.
    try testing.expectEqual(@as(usize, 1), copyFrames(1));
    try testing.expectEqual(@as(usize, 1), copyFrames(64));
    try testing.expectEqual(@as(usize, 2), copyFrames(65));
    try testing.expectEqual(@as(usize, 2), copyFrames(128));
    try testing.expectEqual(@as(usize, 32), copyFrames(load_bg_bytes));
    try testing.expectEqual(@as(usize, 16), copyFrames(load_spr_bytes));
    // 00:$27BA sets $D047 and waits before it looks at it, so nothing costs
    // zero frames.
    try testing.expectEqual(@as(usize, 1), copyFrames(0));
}

test "the fade is clocked by the frame counter, not by the palette table" {
    // $2F down to $0E inclusive is 34 iterations, and the four outright waits
    // at 00:$2563 are on top of them.
    try testing.expectEqual(@as(usize, 34), fade_steps);
    try testing.expectEqual(@as(usize, 39), opFrames(.fadeout, 1));
}

test "going down costs a frame more than the other three directions" {
    const w: door.Op = .{ .warp = .{ .bank = 0xA, .pos = 0x43 } };
    try testing.expectEqual(@as(usize, 4), opFrames(w, 1));
    try testing.expectEqual(@as(usize, 4), opFrames(w, 2));
    try testing.expectEqual(@as(usize, 4), opFrames(w, 4));
    try testing.expectEqual(@as(usize, 5), opFrames(w, 8));
    // A direction the compare chain does not recognise draws nothing: it still
    // pays $2915's wait and $26D1's, and no strips.
    try testing.expectEqual(@as(usize, 2), opFrames(w, 0));
}

test "the interpreter and the decoder walk the same stream, opcode for opcode" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try harness.boot(a, rom, harness.boot_seconds_default);
    defer m.deinit();
    const met = m.read(met_count_addr);

    // Door $01DF is bank $0F cell $77's transition word -- the one the movie
    // crosses at frame 609, and the one Step 5's warp arithmetic was checked
    // against. `docs/bug_tracker.md` transcribed its script by hand as
    // FADEOUT, $B1, COPY, COLLISION, ESCAPE_QUEEN, WARP, END; the machine
    // disagrees, and the machine is the authority. The correction is in the
    // tracker.
    const s = try script(rom, 0x01DF, met);
    const want = [_]std.meta.Tag(door.Op){
        .fadeout, .load, .collision, .solidity, .tiletable, .load, .warp, .end,
    };
    try testing.expectEqual(want.len, s.count);
    for (want, s.ops[0..s.count]) |w, got| try testing.expectEqual(w, std.meta.activeTag(got));
    try testing.expectEqual(@as(u4, 0xA), s.ops[6].warp.bank);
    try testing.expectEqual(@as(u8, 0x43), s.ops[6].warp.pos);

    // And the same claim made where it cannot be a coincidence: every opcode
    // byte the interpreter actually fetched, against the byte the decoder
    // would re-encode. A misread operand length desynchronises the stream, so
    // agreeing on all eight is agreeing on the format.
    const measured = try measure(a, &m, 0x01DF, 1);
    try testing.expect(measured.returned);
    try testing.expectEqual(s.count, measured.step_count);
    for (s.ops[0..s.count], measured.slice()) |op, step| {
        var buf: [16]u8 = undefined;
        _ = door.encodeOne(op, &buf);
        try testing.expectEqual(buf[0], step.opcode);
    }
}

test "the model's frame count is the Game Boy's, on a sample that reaches every opcode" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try harness.boot(a, rom, harness.boot_seconds_default);
    defer m.deinit();
    try testing.expect(harness.alive(&m));
    const met = m.read(met_count_addr);

    const Tag = std.meta.Tag(door.Op);
    const tags = std.enums.values(Tag);

    // Choosing the sample rather than taking a prefix, and for a stated
    // reason: door indices are dense and neighbouring doors share a script
    // shape, so the first hundred doors exercise a handful of opcodes and
    // leave the expensive ones -- `ITEM`'s four transfers, the queen's strips,
    // `IF_MET_LESS`'s re-entry -- entirely ungraded. The sample is a stride
    // for breadth plus, for every opcode the ROM's 512 scripts contain, the
    // first door that contains it. Decoding is cheap; running a script on the
    // Game Boy is ~100 frames of emulation, so the count is what bounds this.
    var chosen: [128]u16 = undefined;
    var chosen_n: usize = 0;
    var wanted: [tags.len]bool = @splat(false);
    var reachable: [tags.len]bool = @splat(false);

    var index: u16 = no_door + 1;
    while (index < door.pointer_count) : (index += 1) {
        const s = script(rom, index, met) catch continue;
        if (s.truncated) continue;
        var novel = false;
        for (s.ops[0..s.count]) |op| {
            const t = @intFromEnum(std.meta.activeTag(op));
            reachable[t] = true;
            if (!wanted[t]) {
                wanted[t] = true;
                novel = true;
            }
        }
        if ((novel or index % 16 == 0) and chosen_n < chosen.len) {
            chosen[chosen_n] = index;
            chosen_n += 1;
        }
    }

    var covered: [tags.len]bool = @splat(false);
    var checked: usize = 0;
    var agreed: usize = 0;
    var worst: usize = 0;
    var worst_door: u16 = 0;
    var worst_dir: u8 = 0;
    var worst_want: usize = 0;
    var worst_got: usize = 0;

    for (chosen[0..chosen_n]) |idx| {
        for ([_]u8{ 1, 2, 4, 8 }) |dir| {
            const s = script(rom, idx, met) catch continue;
            const measured = try measure(a, &m, idx, dir);
            if (!measured.returned) continue;
            checked += 1;
            for (s.ops[0..s.count]) |op| covered[@intFromEnum(std.meta.activeTag(op))] = true;
            const want = scriptFrames(s, dir);
            if (want == measured.total) {
                agreed += 1;
            } else {
                const off = if (want > measured.total) want - measured.total else measured.total - want;
                if (off > worst) {
                    worst = off;
                    worst_door = idx;
                    worst_dir = dir;
                    worst_want = want;
                    worst_got = measured.total;
                }
            }
        }
    }

    if (agreed != checked) {
        std.debug.print(
            "\nthe duration model missed {d} of {d} scripts; worst: door ${X:0>3} dir {d}, model {d} frames, machine {d}\n",
            .{ checked - agreed, checked, worst_door, worst_dir, worst_want, worst_got },
        );
        // A total that is off by n says nothing about which opcode is wrong,
        // and the whole point of measuring per opcode is not having to guess.
        try printDisagreement(a, &m, rom, met, worst_door, worst_dir);
    }
    // An opcode the sample never ran is an opcode whose frame cost is a guess,
    // so say which one rather than reporting a green model with a hole in it.
    for (tags, 0..) |t, i| {
        if (reachable[i] and !covered[i]) {
            std.debug.print("\nthe sample never ran {s}, so its frame cost is ungraded\n", .{@tagName(t)});
            return error.OpcodeUngraded;
        }
    }
    try testing.expect(checked > 100);
    try testing.expectEqual(checked, agreed);

    // `END` is in every script, so it can never be the missing one; the check
    // above is only meaningful if something less common is in the sample too.
    try testing.expect(covered[@intFromEnum(Tag.warp)]);
    try testing.expect(covered[@intFromEnum(Tag.fadeout)]);
}

test "IF_MET_LESS is taken at a count equal to its operand, and the taken branch costs what the model says" {
    // The sample above runs at the booted count, $47, where no `$46` gate is
    // taken -- so the re-entry was never timed. This times it, on the door
    // the slice actually crosses: door $04A, `$F:$05` into `$B:$0C`, the one a
    // playtest found full of acid after a kill (`docs/bug_tracker.md`).
    //
    // 00:$254A is `CP B` with the operand in A and the count in B, then
    // `JR NC`: taken when the count is **at or below** the operand. So one
    // kill ($46) opens a `$46` gate. `docs/slice.md` read it as strictly less
    // and concluded two kills; the `$46` row below is where that reading
    // would have kept table 8, and the machine has to agree it does not.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try harness.boot(a, rom, harness.boot_seconds_default);
    defer m.deinit();
    try testing.expect(harness.alive(&m));

    const door_074: u16 = 0x04A;
    const right: u8 = 1;
    for ([_]struct { met: u8, table: u4, entries: usize }{
        .{ .met = 0x47, .table = 8, .entries = 1 },
        .{ .met = 0x46, .table = 6, .entries = 2 },
        .{ .met = 0x45, .table = 6, .entries = 2 },
    }) |c| {
        m.write(met_count_addr, c.met);
        const s = try script(rom, door_074, c.met);
        try testing.expectEqual(c.entries, s.entries);
        var table: ?u4 = null;
        for (s.ops[0..s.count]) |op| switch (op) {
            .tiletable => |t| table = t,
            else => {},
        };
        try testing.expectEqual(@as(?u4, c.table), table);

        // The machine runs the same opcodes, so the branch it took is the
        // branch the decoder took -- and it takes the frames the model says.
        const measured = try measure(a, &m, door_074, right);
        try testing.expect(measured.returned);
        try testing.expectEqual(s.count, measured.step_count);
        for (s.ops[0..s.count], measured.slice()) |op, step| {
            var buf: [16]u8 = undefined;
            _ = door.encodeOne(op, &buf);
            try testing.expectEqual(buf[0], step.opcode);
        }
        if (scriptFrames(s, right) != measured.total)
            try printDisagreement(a, &m, rom, c.met, door_074, right);
        try testing.expectEqual(scriptFrames(s, right), measured.total);
    }
}

test "the engine's frame table is this module's rule, entry for entry" {
    // The port carries the same arithmetic in 65816, and a table in two places
    // is a table that drifts. This reads the one the cart actually ships --
    // out of the assembled image, by symbol -- and checks it against the rule
    // graded above. The engine's entry is a *floor*: three opcodes add a
    // runtime part it computes for itself, so those three are compared with
    // that part subtracted back off.
    const at = inject.symbolOffset("OpExtraFrames") orelse return error.NoOpExtraFrames;
    const table = inject.image[at..][0..16];

    // One operation per high nibble, in nibble order. The two unallocated
    // nibbles and the terminator have no operation and no cost.
    const reps = [_]?door.Op{
        .{ .copy = .{ .which = .data, .src_bank = 0, .src_addr = 0, .dest = 0, .len = 0x100 } },
        .{ .tiletable = 0 },
        .{ .collision = 0 },
        .{ .solidity = 0 },
        .{ .warp = .{ .bank = 9, .pos = 0 } },
        .escape_queen,
        .{ .damage = .{ .acid = 0, .spike = 0 } },
        .exit_queen,
        .{ .enter_queen = .{ .bank = 9, .scroll_y = 0, .scroll_x = 0, .samus_y = 0, .samus_x = 0 } },
        .{ .if_met_less = .{ .met_count = 0, .transition = 0 } },
        .fadeout,
        null, // $B, the hole `LOAD` left when it became a `COPY`
        .{ .song = 0 },
        .{ .item = 0 },
        null, // $E, unallocated
        .end,
    };

    for (reps, 0..) |maybe, nibble| {
        const op = maybe orelse {
            try testing.expectEqual(@as(u8, 0), table[nibble]);
            continue;
        };
        // Every direction, because two of the three runtime parts depend on it
        // and a table entry that only held for one would be a table entry that
        // held by accident.
        for ([_]u8{ 1, 2, 4, 8 }) |dir| {
            const runtime: usize = switch (op) {
                .copy => |c| copyFrames(c.len),
                .tiletable, .warp => warpWaits(dir),
                else => 0,
            };
            // `END` is the one opcode that costs nothing at all, not even the
            // dispatch frame, so it has no floor to subtract one from.
            const total = opFrames(op, dir);
            const floor = if (total == 0) 0 else total - 1 - runtime;
            try testing.expectEqual(floor, table[nibble]);
        }
    }
}

test "the engine and the converter agree on which copy class is the twin" {
    // The engine names two CopyClass values, because two are what its frame
    // cost turns on. They are assembler defines rather than labels, so there is
    // no symbol to read; the source is.
    const asm_src = @embedFile("engine_asm");
    for ([_]struct { name: []const u8, class: convert.CopyClass }{
        .{ .name = "!COPY_BG      = ", .class = .bg },
        .{ .name = "!COPY_BG_TWIN = ", .class = .bg_twin },
    }) |want| {
        const at = std.mem.indexOf(u8, asm_src, want.name) orelse return error.DefineMissing;
        const rest = asm_src[at + want.name.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const value = try std.fmt.parseInt(u4, std.mem.trim(u8, rest[0..end], " \r"), 10);
        try testing.expectEqual(@intFromEnum(want.class), value);
    }
}

test "the movie's own crossing is the frames this model predicts, end to end" {
    // The rule above is graded opcode for opcode against the interpreter run in
    // isolation. This grades it against the game playing itself: the any% run
    // walks into a door at movie frame 608 and comes out the other side, and
    // every number in between is one this module claims.
    //
    // It is also where the frame the *port* has to fire on comes from, and that
    // turns out to be a distinction worth a test. The trigger and the first
    // opcode are not the same frame -- 00:$23AF blocks before the interpreter
    // has fetched anything -- but the entry wait and the first opcode *are*:
    // the interpreter is entered during the trigger's own frame, blocks, and
    // wakes on the next one with an opcode to run. A port that spends a frame
    // arriving and another frame on the first opcode is one frame late for the
    // whole crossing, which is exactly what the reachable rung caught.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, tas.any_percent, a, .limited(4 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try tas.parse(bytes);

    const Watch = struct {
        triggered: ?usize = null,
        warped: ?usize = null,
        settled: ?usize = null,
        fn on(ctx: *anyopaque, m: *harness.Machine, frame: usize) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // $D00E, the direction: set by the trigger and cleared by 00:$0C24
            // when the incoming screen has finished scrolling in.
            const dir = m.read(probe.door_direction_addr);
            if (self.triggered == null) {
                if (dir != 0) self.triggered = frame;
            } else if (self.settled == null and dir == 0) {
                self.settled = frame;
            }
            // $D058, the map bank the warp selects.
            if (self.warped == null and m.read(probe.warp_bank_addr) == 0x0A) self.warped = frame;
        }
    };
    var w: Watch = .{};
    var r = try tas.run(a, rom, movie, .{
        .max_frames = 800, .stride = 1, .watch_save = false, .profile_record = false,
        .watcher = .{ .ctx = &w, .onFrame = Watch.on },
    });
    defer r.deinit(a);

    // Measured, and every other number here is relative to it.
    try testing.expectEqual(@as(?usize, 608), w.triggered);

    const met = r.samples[w.triggered.?].metroid_count;
    const s = try script(rom, 0x01DF, met);
    // Bank $0F cell $77's transition word. Seven opcodes and a terminator, the
    // sixth of which is `WARP $A,$43` -- bank $0A, row 4, column 3, which is
    // the movie's own $03F3,$0484.
    try testing.expectEqual(@as(usize, 8), s.count);

    // The interpreter is entered on the trigger's frame and wakes on the next
    // one with the first opcode, so opcode 0 runs at 609. Each subsequent
    // opcode runs that many frames later.
    var at: usize = w.triggered.? + entry_frames;
    for (s.ops[0..s.count], 0..) |op, i| {
        if (i == 6) {
            try testing.expectEqual(@as(?usize, at), w.warped);
            try testing.expectEqual(@as(usize, 703), at);
        }
        at += opFrames(op, @intFromEnum(room.Direction.right));
    }
    // `END` returns without waiting, so the crossing's last held frame is the
    // one the warp's own strips end on and the scroll starts the frame after.
    try testing.expectEqual(@as(usize, 708), at + 1);

    // And the scroll itself: four camera pixels a frame from $03B0 up to $0450,
    // which is 00:$0B52's `ADD A,$04` and 00:$0B7C's stop. Forty steps, the
    // first on 708 and the last on 747 -- and the direction is cleared on that
    // last frame rather than the one after it, because 00:$0B7F falls into
    // $0C24 having already made the step.
    const scroll_steps = (0x450 - 0x3B0) / 4;
    try testing.expectEqual(@as(usize, 40), scroll_steps);
    try testing.expectEqual(@as(?usize, 708 + scroll_steps - 1), w.settled);
}

test "no frame queues more copies than the engine holds" {
    // 1.0 Step 20 (James's playtest): door $180 went to `Fatal`. A live
    // crossing's copies go to `!XferQ` for the next vblank, and each opcode
    // hands its frame back, so a frame's copies are one opcode's -- except a
    // twin's. A copy into the shared window (`spr`, and `COPY_DATA` to $8F00)
    // converts to two, and the second (`.copyTwin`) is not an opcode: it falls
    // through into the next one's frame. $180 runs `ITEM`, six copies, straight
    // after `COPY_DATA gfx_commonItems`'s twin, and the queue held six.
    // Every script at both ends of the count, so every `IF_MET_LESS` both ways.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const target = @import("snes_target.zig");
    const asm_src = @embedFile("engine_asm");
    const max = blk: {
        const name = "!XFER_MAX     = ";
        const at = std.mem.indexOf(u8, asm_src, name) orelse return error.DefineMissing;
        const rest = asm_src[at + name.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        break :blk try std.fmt.parseInt(usize, std.mem.trim(u8, rest[0..end], " \r"), 10);
    };
    // `ITEM`'s copies, as the engine's arm makes them: one `DoCopy` a `LoadCopy`.
    const item = blk: {
        const at = std.mem.indexOf(u8, asm_src, "\n.item\n") orelse return error.ItemArmMissing;
        const rest = asm_src[at..];
        const end = std.mem.indexOf(u8, rest, "jmp .next") orelse return error.ItemArmMissing;
        break :blk std.mem.count(u8, rest[0..end], "jsr LoadCopy");
    };
    try testing.expectEqual(@as(usize, 6), item);

    var peak: usize = 0;
    var peak_door: u16 = 0;
    var index: u16 = 1;
    while (index < door.pointer_count) : (index += 1) {
        for ([_]u8{ 0x00, 0xFF }) |count| {
            const s = script(rom, index, count) catch continue;
            var carry: usize = 0;
            for (s.ops[0..s.count]) |op| {
                const own: usize, const twin: usize = switch (op) {
                    .copy => |c| if (c.which == .spr or target.inSharedWindow(c.dest)) .{ 1, 1 } else .{ 1, 0 },
                    .load => |l| if (l.which == .spr) .{ 1, 1 } else .{ 1, 0 },
                    .item => .{ item, 0 },
                    else => .{ 0, 0 },
                };
                if (carry + own > peak) {
                    peak = carry + own;
                    peak_door = index;
                }
                carry = twin;
            }
        }
    }
    try testing.expect(peak <= max);
    // Pinned, so a script or a conversion that raises it is a decision: $180's
    // twin and `ITEM`, the one frame over the old six.
    try testing.expectEqual(@as(usize, 7), peak);
    try testing.expectEqual(@as(u16, 0x180), peak_door);
}
