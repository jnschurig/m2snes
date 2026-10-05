//! What the sound engine costs the SPC700, offline (metroid2-audio Step 7).
//!
//! The shim's main loop increments an idle counter once per pass, so the rate
//! that counter advances at is time the SPC700 had nothing to do. Load is
//! `1 - busy_rate / idle_rate`, and the only honest denominator is the *same
//! machine doing the same protocol work with no engine in it*. So this runs the
//! script twice through `vendor/spcrun`: once with `engine/audio.bin` and once
//! with a null engine that returns from every tick.
//!
//! ## What the number covers, and what it leaves out
//!
//! The difference between the two runs is the engine's own work **plus** the
//! shim work the engine's register writes cause -- a live pulse voice costs the
//! shim a pitch-table lookup, two multiplies and a divide on every sequencer
//! tick, and the silent baseline never pays for it. That is the sum Step 7's
//! decision wants: "the engine, and the two-channel shim under it". What it
//! still leaves out is CH3 and CH4 synthesis, which this shim does not do yet
//! (Steps 9-10), so the verdict adds an estimate for those on top.
//!
//! ## The baseline is measured, and also checked against a constant
//!
//! Measuring both runs in one command cancels anything about the host, which a
//! recorded constant cannot. The constant is kept anyway and compared: it is
//! how a change in the shim's own per-tick cost announces itself, instead of
//! moving the baseline and the measurement together and reading as no change.

const std = @import("std");
const shimpkg = @import("shimpkg");
const aram_image = @import("aram_image.zig");
const audio_req = @import("audio_req.zig");
const audiocmp = @import("audiocmp.zig");

/// A null engine: `init` and `tick` both return at once.
///
/// Three bytes per entry because the shim jumps to fixed addresses, and one
/// `ret` they share. This is the *floor* -- the shim running its timer, its
/// sequencer and the whole port protocol, with nothing plugged into it.
pub fn nullEngine() [7]u8 {
    const ret_at = shimpkg.engine_code_addr + 6;
    return .{
        0x5f, @truncate(ret_at), @truncate(ret_at >> 8), // jmp !ret  (init)
        0x5f, @truncate(ret_at), @truncate(ret_at >> 8), // jmp !ret  (tick)
        0x6f, // ret
    };
}

/// `ENGINE__INIT` and `ENGINE__TICK` in `audio/shim/shim_abi.inc`: the engine's
/// first two instructions, three bytes apart. The package states them as
/// addresses in the assembly include rather than as Zig constants, so this is
/// where the Zig side says what it is relying on, and `engine/audio/main.asm`
/// asserts the same thing from the other side with `.assert PC == ENGINE__INIT`.
const engine_init_offset = 0;
const engine_tick_offset = 3;

/// `spcrun`'s summary line, as far as load cares about it.
pub const Summary = struct {
    idle: u64,
    idle_hz: u64,
    seconds: f64,
    overruns: u64,
    ticks: u64,

    pub fn parse(line: []const u8) !Summary {
        return .{
            .idle = try field(u64, line, "idle="),
            .idle_hz = try field(u64, line, "idle_hz="),
            .seconds = try fieldFloat(line, "seconds="),
            .overruns = try field(u64, line, "overruns="),
            .ticks = try field(u64, line, "ticks="),
        };
    }

    fn token(line: []const u8, key: []const u8) ![]const u8 {
        // Whole-token matching, so `idle=` cannot be found inside `idle_hz=`.
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        while (it.next()) |t| {
            if (std.mem.startsWith(u8, t, key)) return t[key.len..];
        }
        return error.MissingField;
    }

    fn field(comptime T: type, line: []const u8, key: []const u8) !T {
        return std.fmt.parseInt(T, try token(line, key), 10) catch error.BadField;
    }

    fn fieldFloat(line: []const u8, key: []const u8) !f64 {
        return std.fmt.parseFloat(f64, try token(line, key)) catch error.BadField;
    }
};

/// The null engine's idle rate, in passes per emulated second, on a hosted
/// image with the trace off and one tick a frame.
///
/// Recorded 2026-09-21 against `audio/shim/` at snes_game_dev
/// 5a227040c0c6eddaca1d47d248f2b56377baa6f7, the four-channel shim, on all four
/// scripts, which agreed exactly (8060 on the two-channel shim at 896f5d6). It is a property of the shim and the emulator, not of
/// this host: `spcrun` counts emulated cycles. A script with a different tick
/// rate would move it, which is what the tolerance below is for.
///
/// For comparison, snes_game_dev's own silent baselines on the same shim are
/// 8779/s fed and 8009/s resident. Hosted sits below both because a hosted pass
/// also runs the message queue and calls the engine.
pub const silent_baseline_idle_hz: u64 = 7936;

/// How far the measured baseline may sit from the recorded one before the run
/// says so. The emulator steps in buffers, so a script's last partial buffer
/// moves the rate by a fraction of a percent.
pub const baseline_tolerance = 0.02;

pub const Result = struct {
    silent: Summary,
    loaded: Summary,

    /// `1 - busy/idle`, as a fraction. Negative means the two runs came out
    /// within the measurement's own noise, and should be read as "about zero".
    pub fn load(self: Result) f64 {
        const s: f64 = @floatFromInt(self.silent.idle_hz);
        const l: f64 = @floatFromInt(self.loaded.idle_hz);
        return 1.0 - l / s;
    }

    pub fn baselineDrift(self: Result) ?f64 {
        if (silent_baseline_idle_hz == 0) return null;
        const recorded: f64 = @floatFromInt(silent_baseline_idle_hz);
        const measured: f64 = @floatFromInt(self.silent.idle_hz);
        return (measured - recorded) / recorded;
    }
};

/// Run one script through both images and return both summaries.
///
/// `dir` is where the two images and the script are written; they are left
/// behind on purpose, so a surprising number can be reproduced by hand with the
/// `spcrun` command line the caller prints.
pub fn measure(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    engine_code: []const u8,
    script: audio_req.Script,
    dir: []const u8,
) !Result {
    const null_code = nullEngine();
    return .{
        .silent = try run(gpa, arena, io, rom, &null_code, script, dir, "silent"),
        .loaded = try run(gpa, arena, io, rom, engine_code, script, dir, "loaded"),
    };
}

fn run(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    engine_code: []const u8,
    script: audio_req.Script,
    dir: []const u8,
    name: []const u8,
) !Summary {
    std.Io.Dir.cwd().access(io, audiocmp.spcrun_path, .{}) catch return error.NoSpcrun;

    var out = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    defer out.close(io);

    // The trace is off: recording every write costs time, and this is the one
    // measurement where that time would land in the number.
    const img = try aram_image.build(arena, rom, engine_code, .hosted);
    const image_path = try std.fmt.allocPrint(arena, "{s}/{s}.bin", .{ dir, name });
    try out.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}.bin", .{name}),
        .data = img.bytes,
    });

    const script_path = try std.fmt.allocPrint(arena, "{s}/script.txt", .{dir});
    {
        var buf: [1 << 16]u8 = undefined;
        var file = try std.Io.Dir.cwd().createFile(io, script_path, .{});
        defer file.close(io);
        var w = file.writer(io, &buf);
        try audio_req.writeSpcrunScript(script, &w.interface);
        try w.interface.flush();
    }

    const result = std.process.run(gpa, io, .{
        .argv = &.{ audiocmp.spcrun_path, "--image", image_path, "--no-trace", script_path },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch return error.SpcrunFailed;
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.SpcrunFailed;

    var it = std.mem.splitScalar(u8, result.stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "summary ")) return Summary.parse(line);
    }
    return error.NoSummary;
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

test "the null engine's two entries are three bytes apart and share one ret" {
    const code = nullEngine();
    try testing.expectEqual(@as(usize, 7), code.len);
    try testing.expectEqual(@as(u8, 0x5f), code[0]);
    try testing.expectEqual(@as(u8, 0x5f), code[3]);
    try testing.expectEqual(@as(u8, 0x6f), code[6]);
    // Both entries jump to the same address, and that address is the `ret`.
    const target = @as(u16, code[1]) | (@as(u16, code[2]) << 8);
    try testing.expectEqual(target, @as(u16, code[4]) | (@as(u16, code[5]) << 8));
    try testing.expectEqual(@as(u16, shimpkg.engine_code_addr + 6), target);
    // And the second entry is where the ABI puts `tick`.
    try testing.expectEqual(@as(usize, 3), engine_tick_offset - engine_init_offset);
    try testing.expectEqual(@as(u8, 0x5f), code[engine_tick_offset]);
}

test "a summary line parses, and a key is not found inside a longer one" {
    const line = "summary frames=1800 messages=900 ticks=1792 writes=0 " ++
        "seconds=30.001 idle=210000 idle_hz=7000 overruns=12 errors=0 " ++
        "trace_lost=0 queue_overflow=0 queue_max=3";
    const s = try Summary.parse(line);
    try testing.expectEqual(@as(u64, 210000), s.idle);
    try testing.expectEqual(@as(u64, 7000), s.idle_hz);
    try testing.expectEqual(@as(u64, 12), s.overruns);
    try testing.expectEqual(@as(u64, 1792), s.ticks);
    try testing.expectApproxEqAbs(@as(f64, 30.001), s.seconds, 0.0001);
}

test "a summary missing a field is refused rather than read as zero" {
    try testing.expectError(error.MissingField, Summary.parse("summary frames=1"));
}

test "load is the fraction of the baseline's idle the engine took" {
    const r: Result = .{
        .silent = .{ .idle = 0, .idle_hz = 8000, .seconds = 1, .overruns = 0, .ticks = 60 },
        .loaded = .{ .idle = 0, .idle_hz = 6000, .seconds = 1, .overruns = 0, .ticks = 60 },
    };
    try testing.expectApproxEqAbs(@as(f64, 0.25), r.load(), 0.0001);
}
