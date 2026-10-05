//! Per-frame state traces, and the liveness checks that keep them meaningful.
//!
//! Step 6's gate is that running the retail ROM twice produces the same trace.
//! On its own that is a weak claim: a machine that dies on the first
//! instruction is also perfectly reproducible. So a trace carries liveness
//! evidence alongside the digests - frames completed, instructions retired,
//! the LCD still on, VRAM actually written - and the gate checks both. The
//! deliberate omission is a *golden* digest: pinning one would mean rewriting
//! it every time the emulator legitimately gains behaviour, which trains
//! everyone to update the expected value without reading it.

const std = @import("std");
const system = @import("system.zig");
const lcd_mod = @import("lcd.zig");

pub const Trace = struct {
    /// One digest per completed frame, in order.
    digests: [][32]u8,
    frames: u64,
    instructions: u64,
    cycles: u64,
    final_pc: u16,
    high_bank: usize,
    lcd_on: bool,
    vram_nonzero: usize,
    wram_nonzero: usize,
    unknown_io: u32,
    last_unknown_io: u16,

    pub fn deinit(self: *Trace, allocator: std.mem.Allocator) void {
        allocator.free(self.digests);
    }

    /// Did the machine actually get somewhere? Each threshold is a floor, not
    /// a fingerprint: they are meant to separate "running the game" from
    /// "spinning in a loop having crashed", not to pin down a specific frame.
    pub fn alive(self: Trace, want_frames: u64) bool {
        return self.frames == want_frames and
            self.lcd_on and
            self.vram_nonzero > 1000 and
            self.instructions > 1_000_000;
    }
};

/// Run `frames` frames and hash the machine after each one.
pub fn capture(allocator: std.mem.Allocator, rom: []const u8, frames: u64) !Trace {
    var digests = try allocator.alloc([32]u8, frames);
    errdefer allocator.free(digests);

    // Cartridge RAM lives here rather than in the caller so two captures of
    // the same ROM cannot share it - shared save RAM would make the second run
    // start from the first one's state and hide a real divergence.
    var ram: [0x2000]u8 = @splat(0);
    var sys = try system.System.init(rom, &ram);

    var done: u64 = 0;
    while (done < frames) : (done += 1) {
        if (!try sys.stepFrame(5_000_000)) break;
        digests[done] = sys.traceDigest();
    }
    // Shrink the allocation rather than returning a sub-slice of it: the
    // caller frees what it is handed, and handing back a slice that does not
    // start and end on the allocation is an invalid free.
    if (done != frames) digests = try allocator.realloc(digests, done);

    var vram_nonzero: usize = 0;
    for (sys.bus.vram) |b| vram_nonzero += @intFromBool(b != 0);
    var wram_nonzero: usize = 0;
    for (sys.bus.wram) |b| wram_nonzero += @intFromBool(b != 0);

    return .{
        .digests = digests,
        .frames = done,
        .instructions = sys.instructions,
        .cycles = sys.cpu.cycles,
        .final_pc = sys.cpu.pc,
        .high_bank = sys.bus.cart.highBank(),
        .lcd_on = sys.bus.lcd.enabled(),
        .vram_nonzero = vram_nonzero,
        .wram_nonzero = wram_nonzero,
        .unknown_io = sys.bus.unknown_io_writes,
        .last_unknown_io = sys.bus.last_unknown_io,
    };
}

/// The first frame at which two traces disagree, or null when they match.
///
/// Per-frame rather than end-state: a divergence that later reconverges would
/// be invisible in a single final digest, and "the emulator briefly disagreed
/// with itself" is exactly the class of bug this is looking for.
pub fn firstDifference(a: Trace, b: Trace) ?usize {
    const n = @min(a.digests.len, b.digests.len);
    for (0..n) |i| {
        if (!std.mem.eql(u8, &a.digests[i], &b.digests[i])) return i;
    }
    if (a.digests.len != b.digests.len) return n;
    return null;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

fn fixture(rom: *[0x8000]u8, code: []const u8) void {
    @memset(rom, 0);
    rom[0x0147] = 0x00;
    @memcpy(rom[0x100..][0..code.len], code);
}

test "two captures of the same ROM agree frame by frame" {
    const gpa = testing.allocator;
    var rom: [0x8000]u8 = undefined;
    fixture(&rom, &[_]u8{
        0x21, 0x00, 0x80, // LD HL,$8000
        0x3E, 0x11, // LD A,$11
        0x22, // LD (HL+),A
        0x3C, // INC A
        0x18, 0xFB, // JR -5
    });

    var a = try capture(gpa, &rom, 4);
    defer a.deinit(gpa);
    var b = try capture(gpa, &rom, 4);
    defer b.deinit(gpa);

    try testing.expectEqual(@as(?usize, null), firstDifference(a, b));
    try testing.expectEqual(@as(u64, 4), a.frames);
    try testing.expectEqual(a.instructions, b.instructions);
    // Consecutive frames must differ from each other, or "reproducible" would
    // be true of a machine that stopped changing.
    try testing.expect(!std.mem.eql(u8, &a.digests[0], &a.digests[1]));
}

test "firstDifference names the frame, not just the fact" {
    const gpa = testing.allocator;
    var rom: [0x8000]u8 = undefined;
    fixture(&rom, &[_]u8{ 0x18, 0xFE });
    var a = try capture(gpa, &rom, 5);
    defer a.deinit(gpa);
    var b = try capture(gpa, &rom, 5);
    defer b.deinit(gpa);

    try testing.expectEqual(@as(?usize, null), firstDifference(a, b));
    b.digests[3][0] ^= 1;
    try testing.expectEqual(@as(?usize, 3), firstDifference(a, b));

    // A short trace differs at the point it stops. The full slice is put back
    // before `deinit` runs: `b` owns that allocation, and freeing a shortened
    // view of it is an invalid free, not a smaller one.
    const full = b.digests;
    b.digests = full[0..2];
    try testing.expectEqual(@as(?usize, 2), firstDifference(a, b));
    b.digests = full;
}

test "liveness rejects a machine that is reproducibly doing nothing" {
    const gpa = testing.allocator;
    var rom: [0x8000]u8 = undefined;
    // A bare self-loop: perfectly deterministic, and completely dead. It runs
    // frames, but writes no VRAM - which is the case the digests alone would
    // happily call a pass.
    fixture(&rom, &[_]u8{ 0x18, 0xFE });
    var t = try capture(gpa, &rom, 3);
    defer t.deinit(gpa);

    try testing.expectEqual(@as(u64, 3), t.frames);
    try testing.expect(t.lcd_on);
    try testing.expectEqual(@as(usize, 0), t.vram_nonzero);
    try testing.expect(!t.alive(3));
}

test "liveness rejects a machine that cannot finish its frames" {
    const gpa = testing.allocator;
    var rom: [0x8000]u8 = undefined;
    fixture(&rom, &[_]u8{
        0x3E, 0x00, // LD A,0
        0xE0, 0x40, // LDH ($40),A - LCD off
        0x18, 0xFE,
    });
    var t = try capture(gpa, &rom, 3);
    defer t.deinit(gpa);
    try testing.expectEqual(@as(u64, 0), t.frames);
    try testing.expect(!t.lcd_on);
    try testing.expect(!t.alive(3));
}

// ---- ROM-dependent --------------------------------------------------------

const testrom = @import("testrom");

pub const retail_frames: u64 = 600;

test "the retail ROM runs, and runs the same way twice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    const a = try capture(arena, rom, retail_frames);
    const b = try capture(arena, rom, retail_frames);

    if (firstDifference(a, b)) |frame| {
        std.debug.print("retail trace diverged at frame {d}\n", .{frame});
    }
    try testing.expectEqual(@as(?usize, null), firstDifference(a, b));
    try testing.expect(a.alive(retail_frames));

    // The game is genuinely running, not merely reproducible: it has switched
    // to a high ROM bank, filled most of VRAM, and retired millions of
    // instructions without hitting an illegal opcode or an unmodelled register.
    try testing.expect(a.high_bank > 0);
    try testing.expect(a.vram_nonzero > 4000);
    try testing.expectEqual(@as(u32, 0), a.unknown_io);
    try testing.expectEqual(a.instructions, b.instructions);
    try testing.expectEqual(a.cycles, b.cycles);
}
