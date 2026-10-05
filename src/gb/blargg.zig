//! Running blargg's SM83 test suites against the core.
//!
//! These ROMs are the standard correctness bar. They report through the link
//! port: each prints its name, then `Passed` or a numbered failure, then stops.
//! Catching a flag-level bug here is the whole point of Step 6 landing before
//! Step 7 - the alternative is meeting the same bug in Step 9 as an
//! unexplained one-pixel render mismatch, with 60 KiB of game code in between.
//!
//! The ROMs are not ours and are not tracked. `tools/get-testroms.sh` fetches
//! them into `vendor/testroms/`; without them these tests **skip with a
//! notice** rather than passing, because a suite that quietly runs nothing
//! reports green.

const std = @import("std");
const system = @import("system.zig");

pub const dir = "vendor/testroms";

pub const Outcome = struct {
    /// Everything the ROM sent out the link port.
    output: []u8,
    passed: bool,
    /// False when the cycle budget ran out before the ROM said anything
    /// conclusive - a different failure from the ROM reporting one.
    finished: bool,
    frames: u64,
};

/// Run one test ROM until it reports, or until the budget runs out.
pub fn run(
    allocator: std.mem.Allocator,
    rom: []const u8,
    max_frames: u64,
) !Outcome {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var ram: [0x2000]u8 = @splat(0);
    var sys = try system.System.init(rom, &ram);
    sys.bus.serial_out = &out;
    sys.bus.serial_allocator = allocator;

    var frames: u64 = 0;
    while (frames < max_frames) : (frames += 1) {
        _ = try sys.stepFrame(2_000_000);
        // blargg's ROMs finish by printing and then looping, so the output is
        // the completion signal; polling it once a frame costs nothing.
        const said_passed = std.mem.indexOf(u8, out.items, "Passed") != null;
        const said_failed = std.mem.indexOf(u8, out.items, "Failed") != null;
        if (said_passed or said_failed) {
            // Both flags are computed before the slice is taken: `toOwnedSlice`
            // empties the list, so reading `out.items` afterwards would find
            // nothing, and "no Failed in the output" would come out true for
            // every run - a runner that always reports success.
            return .{
                .output = try out.toOwnedSlice(allocator),
                .passed = !said_failed,
                .finished = true,
                .frames = frames,
            };
        }
    }
    return .{
        .output = try out.toOwnedSlice(allocator),
        .passed = false,
        .finished = false,
        .frames = frames,
    };
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

fn loadTestRom(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(1 << 21)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// The eleven individual cpu_instrs groups. Run separately rather than only as
/// the combined ROM because the group name is the diagnosis: "09-op r,r failed"
/// points at the ALU, where "cpu_instrs failed" points at nothing.
const individual = [_][]const u8{
    "01-special",
    "02-interrupts",
    "03-op-sp-hl",
    "04-op-r-imm",
    "05-op-rp",
    "06-ld-r-r",
    "07-jr-jp-call-ret-rst",
    "08-misc-instrs",
    "09-op-r-r",
    "10-bit-ops",
    "11-op-a-hl",
};

test "blargg cpu_instrs: every individual group passes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ran: usize = 0;
    var failures: usize = 0;
    for (individual) |name| {
        const path = try std.fmt.allocPrint(arena, "{s}/cpu_instrs/{s}.gb", .{ dir, name });
        const rom = try loadTestRom(arena, path) orelse continue;
        ran += 1;

        const r = try run(arena, rom, 4000);
        if (!r.passed or !r.finished) {
            failures += 1;
            std.debug.print("blargg {s}: {s} after {d} frames\n  output: {s}\n", .{
                name,
                if (r.finished) "FAILED" else "did not finish",
                r.frames,
                std.mem.trim(u8, r.output, "\n\r "),
            });
        }
    }
    if (ran == 0) {
        std.debug.print("no test ROMs in {s} - run tools/get-testroms.sh\n", .{dir});
        return error.SkipZigTest;
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expectEqual(individual.len, ran);
}

test "blargg cpu_instrs: the combined ROM passes, which also exercises MBC1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rom = try loadTestRom(arena, dir ++ "/cpu_instrs.gb") orelse return error.SkipZigTest;
    // 64 KiB, so the ROM bank register is doing real work here.
    try testing.expectEqual(@as(usize, 0x10000), rom.len);

    const r = try run(arena, rom, 20000);
    if (!r.passed) {
        std.debug.print("cpu_instrs: {s}\n{s}\n", .{
            if (r.finished) "FAILED" else "did not finish",
            r.output,
        });
    }
    try testing.expect(r.finished);
    try testing.expect(r.passed);
}

test "blargg instr_timing passes, so the cycle counts are right" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rom = try loadTestRom(arena, dir ++ "/instr_timing.gb") orelse return error.SkipZigTest;
    const r = try run(arena, rom, 4000);
    if (!r.passed) {
        std.debug.print("instr_timing: {s}\n{s}\n", .{
            if (r.finished) "FAILED" else "did not finish",
            r.output,
        });
    }
    try testing.expect(r.finished);
    try testing.expect(r.passed);
}
