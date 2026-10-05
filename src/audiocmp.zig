//! The exact comparison: one request script, two engines, one verdict.
//!
//! The ported sound engine is graded against the Game Boy's by the register
//! writes it makes. Both sides are driven from the same `.req` script
//! (`audio_req.zig`), and the answer this module gives is a single tick number:
//! the first one where the two disagree, and what each of them did there.
//!
//! ## Why writes, and not audio
//!
//! A rendered waveform would compare two things we are not porting — the shim's
//! synthesis and the S-DSP's mixing — on top of the one we are. The engine's
//! contract with the APU is the write sequence, so that is what is graded, byte
//! for byte and tick for tick. Whether those writes *sound* right is the shim's
//! question, answered by `gbgrade` in snes_game_dev, and whether the result is
//! pleasant is Step 18's listening pass.
//!
//! ## The two sides line up on the tick, and nothing else
//!
//! Both sides number ticks from zero in script order. On the Game Boy a tick is
//! one `handleAudio` call, bracketed by the APU log's length before and after.
//! On the SPC700 it is one `ENGINE__TICK`, and the shim's trace tags each write
//! with `STATS__HOSTED_TICKS`, which it increments *after* the call returns — so
//! the first tick's writes are tagged 0 on both sides. Nothing else about the
//! two runs is comparable: the Game Boy's cycle offsets within a tick have no
//! SPC700 counterpart, and `spcrun` packs two or three ticks into a message
//! where the console sends one. The order of writes within a tick is compared;
//! their timing inside it is not.
//!
//! The read-back bytes are compared where they can be: `spcrun` reports them per
//! message, with the cumulative tick counter the reply was latched at, so each
//! reply is checked against the Game Boy's state after that many ticks.

const std = @import("std");
const apu = @import("gb/apu.zig");
const harness = @import("gb/harness.zig");
const audiocost = @import("audiocost.zig");
const audio_req = @import("audio_req.zig");

// ---- What is compared ------------------------------------------------------

/// A register write, on either side.
pub const Write = struct {
    /// Tick ordinal, from zero, in script order.
    tick: u32,
    /// Game Boy APU address, `$FF10`-`$FF3F`.
    addr: u16,
    value: u8,
};

/// Which registers a comparison looks at.
///
/// Step 7's spike ports square 1 only, and grades through `square1`: the other
/// channels still play on the Game Boy side and would otherwise drown the
/// signal. A filter is therefore part of the comparator rather than something
/// bolted on later, and `all` is the honest default.
pub const Filter = struct {
    name: []const u8,
    /// Addresses compared. Empty means every APU address.
    addrs: []const u16 = &.{},
    /// Bits compared, for an address shared between channels. An address with
    /// no entry is compared whole.
    masks: []const Mask = &.{},

    pub const Mask = struct { addr: u16, mask: u8 };

    pub fn covers(self: Filter, addr: u16) bool {
        if (self.addrs.len == 0) return apu.owns(addr);
        for (self.addrs) |a| {
            if (a == addr) return true;
        }
        return false;
    }

    pub fn mask(self: Filter, addr: u16) u8 {
        for (self.masks) |m| {
            if (m.addr == addr) return m.mask;
        }
        return 0xFF;
    }
};

pub const all: Filter = .{ .name = "all" };

/// Square 1: its own five registers, plus its bits of the two shared ones.
///
/// `NR51` bits 0 and 4 are square 1's right and left enables; `NR52` bit 0 is
/// its length-enabled flag, and bit 7 is the APU's power, which every channel
/// depends on and so is compared here too.
pub const square1: Filter = .{
    .name = "square1",
    .addrs = &.{ 0xFF10, 0xFF11, 0xFF12, 0xFF13, 0xFF14, 0xFF25, 0xFF26 },
    .masks = &.{
        .{ .addr = 0xFF25, .mask = 0x11 },
        .{ .addr = 0xFF26, .mask = 0x81 },
    },
};

pub const square2: Filter = .{
    .name = "square2",
    .addrs = &.{ 0xFF16, 0xFF17, 0xFF18, 0xFF19, 0xFF25, 0xFF26 },
    .masks = &.{
        .{ .addr = 0xFF25, .mask = 0x22 },
        .{ .addr = 0xFF26, .mask = 0x82 },
    },
};

pub const wave: Filter = .{
    .name = "wave",
    .addrs = &.{
        0xFF1A, 0xFF1B, 0xFF1C, 0xFF1D, 0xFF1E, 0xFF25, 0xFF26,
        0xFF30, 0xFF31, 0xFF32, 0xFF33, 0xFF34, 0xFF35, 0xFF36, 0xFF37,
        0xFF38, 0xFF39, 0xFF3A, 0xFF3B, 0xFF3C, 0xFF3D, 0xFF3E, 0xFF3F,
    },
    .masks = &.{
        .{ .addr = 0xFF25, .mask = 0x44 },
        .{ .addr = 0xFF26, .mask = 0x84 },
    },
};

pub const noise: Filter = .{
    .name = "noise",
    .addrs = &.{ 0xFF20, 0xFF21, 0xFF22, 0xFF23, 0xFF25, 0xFF26 },
    .masks = &.{
        .{ .addr = 0xFF25, .mask = 0x88 },
        .{ .addr = 0xFF26, .mask = 0x88 },
    },
};

pub const filters = [_]Filter{ all, square1, square2, wave, noise };

pub fn filterByName(name: []const u8) ?Filter {
    for (filters) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

// ---- The Game Boy side -----------------------------------------------------

/// What the Game Boy's engine did, per tick.
pub const GbRun = struct {
    writes: []Write,
    /// The five read-back bytes after each tick, indexed by tick ordinal.
    read_back: [][audio_req.read_back.len]u8,

    pub fn deinit(self: *GbRun, gpa: std.mem.Allocator) void {
        gpa.free(self.writes);
        gpa.free(self.read_back);
    }
};

pub const GbError = error{ DidNotReturn, OutOfMemory } || harness.Error;

/// Run the script through bank 4 on the Game Boy harness.
///
/// A cold machine, `initializeAudio` once, then per tick: the tick's ops written
/// to WRAM (or, for `rDIV`, to the bus's DIV pin, and for `silenceAudio`,
/// called), `handleAudio` called, and the writes both made attributed to that
/// tick. The call goes to bank 4's trampoline directly, as `audiocost` does, so
/// the `callFar` in `handleAudio_longJump` is not in the comparison — it makes no
/// APU write and has no SPC700 counterpart.
pub fn runGb(gpa: std.mem.Allocator, rom: []const u8, script: audio_req.Script) GbError!GbRun {
    var m = try harness.bootFrom(gpa, rom, null);
    defer m.deinit();

    if (!(try m.call(.{ .bank = audiocost.bank, .addr = audiocost.initialize })).returned)
        return error.DidNotReturn;

    var log: std.ArrayList(apu.Write) = .empty;
    defer log.deinit(gpa);
    // DIV pinned from the first tick, so the cries it seeds read the same byte
    // on both sides whether or not the script says what it is.
    m.sys.bus.div_pin = 0;
    m.sys.bus.apu.log = &log;
    m.sys.bus.apu.allocator = gpa;
    defer m.sys.bus.apu.log = null;

    var writes: std.ArrayList(Write) = .empty;
    errdefer writes.deinit(gpa);
    var read_back: std.ArrayList([audio_req.read_back.len]u8) = .empty;
    errdefer read_back.deinit(gpa);

    var tick: u32 = 0;
    for (script.frames) |frame| {
        for (frame) |ops| {
            // Before the ops, because a `call` op writes registers, and they
            // are this tick's on the SPC700 side too.
            const before = log.items.len;
            for (ops) |op| switch (audio_req.slots[op.slot].kind) {
                .divider => m.sys.bus.div_pin = op.value,
                .request, .set, .game => m.write(audio_req.slots[op.slot].wram, op.value),
                .call => if (!(try m.call(.{ .bank = audiocost.bank, .addr = audio_req.slots[op.slot].wram })).returned)
                    return error.DidNotReturn,
            };

            if (!(try m.call(.{ .bank = audiocost.bank, .addr = audiocost.handle })).returned)
                return error.DidNotReturn;
            for (log.items[before..]) |w| {
                try writes.append(gpa, .{ .tick = tick, .addr = w.addr, .value = w.value });
            }

            var back: [audio_req.read_back.len]u8 = undefined;
            for (audio_req.read_back, 0..) |r, i| back[i] = m.read(r.wram);
            try read_back.append(gpa, back);
            tick += 1;
        }
    }

    return .{
        .writes = try writes.toOwnedSlice(gpa),
        .read_back = try read_back.toOwnedSlice(gpa),
    };
}

// ---- The SPC700 side -------------------------------------------------------

/// One message's reply, as `spcrun` printed it.
pub const Reply = struct {
    /// The cumulative engine tick counter the reply was latched at. The engine
    /// state it reports is the state after this many ticks.
    ticks: u16,
    engine: [audio_req.read_back.len]u8,
};

pub const SpcRun = struct {
    writes: []Write,
    replies: []Reply,
    /// `spcrun`'s own summary line, reported as-is when something goes wrong.
    summary: []const u8,

    pub fn deinit(self: *SpcRun, gpa: std.mem.Allocator) void {
        gpa.free(self.writes);
        gpa.free(self.replies);
    }
};

pub const spcrun_path = "vendor/spcrun/spcrun";

pub const SpcError = error{
    /// `spcrun` is not vendored. `tools/get-spcrun.sh`.
    NoSpcrun,
    /// It ran and failed. Its own message is on stderr, and it is precise.
    SpcrunFailed,
    /// Its output was not the format this parses.
    BadOutput,
} || std.mem.Allocator.Error;

/// Run the script through the ARAM image under `vendor/spcrun`.
///
/// The script is written out in `spcrun`'s own text format and passed as a file,
/// so the harness drives it exactly as a human would and any divergence can be
/// replayed by hand from the same two files.
///
/// `wav_out`, when given, asks `spcrun` to write what the S-DSP played there as
/// well. Grading never asks for it — the writes are the grade, and a waveform
/// would put the shim's synthesis and the S-DSP's mixing into a comparison of
/// the engine. The A/B (`audioab.zig`) is what asks.
pub fn runSpc(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    image_path: []const u8,
    script: audio_req.Script,
    script_out: []const u8,
    ack_delay: u32,
    wav_out: ?[]const u8,
) !SpcRun {
    std.Io.Dir.cwd().access(io, spcrun_path, .{}) catch return error.NoSpcrun;

    {
        var buf: [1 << 16]u8 = undefined;
        var file = try std.Io.Dir.cwd().createFile(io, script_out, .{});
        defer file.close(io);
        var w = file.writer(io, &buf);
        try audio_req.writeSpcrunScript(script, &w.interface);
        try w.interface.flush();
    }

    // `--ack-delay` holds each message as in flight for that many frames more,
    // which is the busy rule doing work: ticks queue behind it and go out
    // several to a message. The engine must see the same records in the same
    // order either way, so the grade is the same grade.
    var delay_buf: [12]u8 = undefined;
    const delay = std.fmt.bufPrint(&delay_buf, "{d}", .{ack_delay}) catch unreachable;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ spcrun_path, "--image", image_path, "--ack-delay", delay });
    if (wav_out) |p| try argv.appendSlice(gpa, &.{ "--wav", p });
    try argv.append(gpa, script_out);
    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        // A thirty-second script's trace is millions of lines, so the default
        // caps would truncate the very sequence being compared.
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
        .reserve_amount = 1 << 20,
    }) catch return error.SpcrunFailed;
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.SpcrunFailed;

    return parseSpcrun(gpa, arena, result.stdout);
}

/// Parse `spcrun`'s `write`, `reply` and `summary` lines.
pub fn parseSpcrun(gpa: std.mem.Allocator, arena: std.mem.Allocator, text: []const u8) !SpcRun {
    var writes: std.ArrayList(Write) = .empty;
    errdefer writes.deinit(gpa);
    var replies: std.ArrayList(Reply) = .empty;
    errdefer replies.deinit(gpa);
    var summary: []const u8 = "";

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "write ")) {
            var it = std.mem.tokenizeAny(u8, line[6..], " ");
            const tick = it.next() orelse return error.BadOutput;
            const reg = it.next() orelse return error.BadOutput;
            const value = it.next() orelse return error.BadOutput;
            try writes.append(gpa, .{
                .tick = std.fmt.parseInt(u32, tick, 10) catch return error.BadOutput,
                .addr = std.fmt.parseInt(u16, reg, 16) catch return error.BadOutput,
                .value = std.fmt.parseInt(u8, value, 16) catch return error.BadOutput,
            });
        } else if (std.mem.startsWith(u8, line, "reply ")) {
            var r: Reply = .{ .ticks = 0, .engine = @splat(0) };
            var it = std.mem.tokenizeAny(u8, line[6..], " ");
            while (it.next()) |field| {
                const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
                const key = field[0..eq];
                const val = field[eq + 1 ..];
                if (std.mem.eql(u8, key, "ticks")) {
                    r.ticks = std.fmt.parseInt(u16, val, 10) catch return error.BadOutput;
                } else if (std.mem.eql(u8, key, "engine")) {
                    if (val.len != audio_req.read_back.len * 2 + 2) return error.BadOutput;
                    // `{x}` on a byte array prints it as one run of hex digits;
                    // the six bytes are the five read-back values and the shim's
                    // liveness byte, which is not compared.
                    for (0..audio_req.read_back.len) |i| {
                        r.engine[i] = std.fmt.parseInt(u8, val[i * 2 ..][0..2], 16) catch
                            return error.BadOutput;
                    }
                }
            }
            try replies.append(gpa, r);
        } else if (std.mem.startsWith(u8, line, "summary ")) {
            summary = try arena.dupe(u8, line);
        }
    }
    if (summary.len == 0) return error.BadOutput;

    return .{
        .writes = try writes.toOwnedSlice(gpa),
        .replies = try replies.toOwnedSlice(gpa),
        .summary = summary,
    };
}

// ---- The verdict -----------------------------------------------------------

pub const Divergence = union(enum) {
    /// The two sides' write sequences differ at this position.
    write: struct {
        /// Position in the filtered sequence, so the context below it lines up.
        index: usize,
        tick: u32,
        gb: ?Write,
        spc: ?Write,
    },
    /// A read-back byte differs after a message's ticks.
    read_back: struct {
        tick: u32,
        which: usize,
        gb: u8,
        spc: u8,
    },
    /// The SPC700 side ran a different number of ticks than the script asked
    /// for. `spcrun` exits nonzero on this too; it is checked here so a
    /// mismatch cannot be read as a clean comparison.
    tick_count: struct { expected: usize, spc: usize },
};

pub const Comparison = struct {
    filter: Filter,
    gb_writes: usize,
    spc_writes: usize,
    ticks: usize,
    divergence: ?Divergence,
};

fn keep(filter: Filter, w: Write) ?Write {
    if (!filter.covers(w.addr)) return null;
    return .{ .tick = w.tick, .addr = w.addr, .value = w.value & filter.mask(w.addr) };
}

fn filtered(arena: std.mem.Allocator, filter: Filter, src: []const Write) ![]Write {
    var out: std.ArrayList(Write) = .empty;
    for (src) |w| {
        if (keep(filter, w)) |k| try out.append(arena, k);
    }
    return out.toOwnedSlice(arena);
}

/// Compare the two runs. The first disagreement wins; there is no attempt to
/// resynchronise, because past the first divergence the engines are in different
/// states and every later difference is a consequence rather than a finding.
pub fn compare(
    arena: std.mem.Allocator,
    gb: GbRun,
    spc: SpcRun,
    filter: Filter,
) !Comparison {
    const g = try filtered(arena, filter, gb.writes);
    const s = try filtered(arena, filter, spc.writes);

    var out: Comparison = .{
        .filter = filter,
        .gb_writes = g.len,
        .spc_writes = s.len,
        .ticks = gb.read_back.len,
        .divergence = null,
    };

    var i: usize = 0;
    while (i < g.len or i < s.len) : (i += 1) {
        const a: ?Write = if (i < g.len) g[i] else null;
        const b: ?Write = if (i < s.len) s[i] else null;
        const same = a != null and b != null and
            a.?.tick == b.?.tick and a.?.addr == b.?.addr and a.?.value == b.?.value;
        if (same) continue;
        out.divergence = .{ .write = .{
            .index = i,
            .tick = if (a) |x| x.tick else b.?.tick,
            .gb = a,
            .spc = b,
        } };
        return out;
    }

    // The writes agree. Now the read-back, at the ticks the replies were
    // latched at. A reply at 0 ticks is the state before anything ran, and
    // there is no Game Boy tick to compare it with.
    for (spc.replies) |r| {
        if (r.ticks == 0 or r.ticks > gb.read_back.len) continue;
        const back = gb.read_back[r.ticks - 1];
        for (0..audio_req.read_back.len) |k| {
            if (back[k] == r.engine[k]) continue;
            out.divergence = .{ .read_back = .{
                .tick = r.ticks - 1,
                .which = k,
                .gb = back[k],
                .spc = r.engine[k],
            } };
            return out;
        }
    }

    return out;
}

// ---- Reporting -------------------------------------------------------------

/// How many writes before the divergence to show.
pub const context: usize = 8;

pub fn report(
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    gb: GbRun,
    spc: SpcRun,
    cmp: Comparison,
) !void {
    try out.print("filter {s}: {d} tick(s), {d} write(s) on the Game Boy, {d} on the SPC700\n", .{
        cmp.filter.name, cmp.ticks, cmp.gb_writes, cmp.spc_writes,
    });

    const d = cmp.divergence orelse {
        try out.print("exact: every write and read-back byte agrees\n", .{});
        return;
    };

    switch (d) {
        .tick_count => |t| try out.print(
            "DIVERGE tick count: the script asks for {d}, the SPC700 ran {d}\n",
            .{ t.expected, t.spc },
        ),
        .read_back => |r| try out.print(
            "DIVERGE read-back after tick {d}: {s} is ${X:0>2} on the Game Boy, ${X:0>2} on the SPC700\n",
            .{ r.tick, audio_req.read_back[r.which].name, r.gb, r.spc },
        ),
        .write => |w| {
            try out.print("DIVERGE tick {d}, filtered write #{d}:\n", .{ w.tick, w.index });
            try out.print("  Game Boy: {s}\n", .{try describe(arena, w.gb)});
            try out.print("  SPC700:   {s}\n", .{try describe(arena, w.spc)});

            const g = try filtered(arena, cmp.filter, gb.writes);
            const s = try filtered(arena, cmp.filter, spc.writes);
            try out.print("\nthe {d} filtered write(s) before it, which agree:\n", .{
                @min(context, w.index),
            });
            const from = w.index - @min(context, w.index);
            for (from..w.index) |i| {
                try out.print("  tick {d:>5}  {s}\n", .{ g[i].tick, try describe(arena, g[i]) });
            }
            try out.print("\nand what each side did next:\n", .{});
            try printTail(arena, out, "  Game Boy", g, w.index);
            try printTail(arena, out, "  SPC700  ", s, w.index);
        },
    }
    try out.print("\nspcrun {s}\n", .{spc.summary});
}

fn describe(arena: std.mem.Allocator, w: ?Write) ![]const u8 {
    const x = w orelse return "(nothing: its sequence ended here)";
    return std.fmt.allocPrint(arena, "${X:0>4} = ${X:0>2}  ({s})", .{ x.addr, x.value, regName(x.addr) });
}

fn printTail(
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    label: []const u8,
    seq: []const Write,
    from: usize,
) !void {
    if (from >= seq.len) {
        try out.print("{s}: nothing more\n", .{label});
        return;
    }
    const to = @min(seq.len, from + context);
    for (seq[from..to]) |w| {
        try out.print("{s}: tick {d:>5}  {s}\n", .{ label, w.tick, try describe(arena, w) });
    }
}

/// The Game Boy's own name for an APU register, so a report reads as the sound
/// engine's author would have read it.
pub fn regName(addr: u16) []const u8 {
    return switch (addr) {
        0xFF10 => "NR10 sweep",
        0xFF11 => "NR11 duty/length",
        0xFF12 => "NR12 envelope",
        0xFF13 => "NR13 freq lo",
        0xFF14 => "NR14 freq hi/trigger",
        0xFF16 => "NR21 duty/length",
        0xFF17 => "NR22 envelope",
        0xFF18 => "NR23 freq lo",
        0xFF19 => "NR24 freq hi/trigger",
        0xFF1A => "NR30 DAC",
        0xFF1B => "NR31 length",
        0xFF1C => "NR32 level",
        0xFF1D => "NR33 freq lo",
        0xFF1E => "NR34 freq hi/trigger",
        0xFF20 => "NR41 length",
        0xFF21 => "NR42 envelope",
        0xFF22 => "NR43 divisor",
        0xFF23 => "NR44 trigger",
        0xFF24 => "NR50 master volume",
        0xFF25 => "NR51 panning",
        0xFF26 => "NR52 power",
        0xFF30...0xFF3F => "wave RAM",
        else => "unknown",
    };
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "a filter covers its own channel's registers and nothing else's" {
    try testing.expect(square1.covers(0xFF10));
    try testing.expect(square1.covers(0xFF14));
    try testing.expect(!square1.covers(0xFF16)); // square 2
    try testing.expect(!square1.covers(0xFF1A)); // wave
    try testing.expect(square1.covers(0xFF25)); // shared, masked
    try testing.expectEqual(@as(u8, 0x11), square1.mask(0xFF25));
    try testing.expectEqual(@as(u8, 0xFF), square1.mask(0xFF10));

    // `all` is every address the APU owns, and no neighbour of it.
    try testing.expect(all.covers(0xFF10) and all.covers(0xFF3F));
    try testing.expect(!all.covers(0xFF0F) and !all.covers(0xFF40));
    try testing.expectEqual(@as(u8, 0xFF), all.mask(0xFF25));
}

test "every filter's registers belong to the APU, and every mask to a covered address" {
    for (filters) |f| {
        for (f.addrs) |a| try testing.expect(apu.owns(a));
        for (f.masks) |m| {
            try testing.expect(f.covers(m.addr));
            try testing.expect(m.mask != 0 and m.mask != 0xFF);
        }
    }
    try testing.expect(filterByName("square1") != null);
    try testing.expect(filterByName("nonesuch") == null);
}

test "spcrun's output parses into writes and replies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\# spcrun: 2 frame(s), 3 tick(s) scripted; ack delay 0; trace on
        \\reply frame=0 seq=00 ticks=0 overruns=0 idle=0 engine=000000000001
        \\write 0 ff12 f0
        \\write 0 ff14 87
        \\reply frame=2 seq=01 ticks=2 overruns=0 idle=1 engine=040000000001
        \\write 2 ff13 42
        \\summary frames=6 messages=3 ticks=3 writes=3
    ;
    var r = try parseSpcrun(testing.allocator, arena, text);
    defer r.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), r.writes.len);
    try testing.expectEqual(Write{ .tick = 0, .addr = 0xFF12, .value = 0xF0 }, r.writes[0]);
    try testing.expectEqual(Write{ .tick = 2, .addr = 0xFF13, .value = 0x42 }, r.writes[2]);
    try testing.expectEqual(@as(usize, 2), r.replies.len);
    try testing.expectEqual(@as(u16, 0), r.replies[0].ticks);
    try testing.expectEqual(@as(u16, 2), r.replies[1].ticks);
    // `songPlaying` is the reply's first byte; the trailing $01 is the shim's
    // liveness byte and is deliberately not among the five.
    try testing.expectEqual(@as(u8, 0x04), r.replies[1].engine[0]);
    try testing.expect(std.mem.startsWith(u8, r.summary, "summary frames=6"));
}

test "output with no summary line is refused rather than read as an empty run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.BadOutput, parseSpcrun(
        testing.allocator,
        arena_state.allocator(),
        "write 0 ff12 f0\n",
    ));
}

/// The two sides of a comparison, built by hand.
fn fixture(
    arena: std.mem.Allocator,
    gb_writes: []const Write,
    spc_writes: []const Write,
    ticks: usize,
) !struct { gb: GbRun, spc: SpcRun } {
    const back = try arena.alloc([audio_req.read_back.len]u8, ticks);
    for (back) |*b| b.* = @splat(0);
    return .{
        .gb = .{ .writes = try arena.dupe(Write, gb_writes), .read_back = back },
        .spc = .{ .writes = try arena.dupe(Write, spc_writes), .replies = &.{}, .summary = "summary" },
    };
}

test "identical runs are exact, and a changed value diverges at its own tick" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const seq = [_]Write{
        .{ .tick = 0, .addr = 0xFF12, .value = 0xF0 },
        .{ .tick = 0, .addr = 0xFF14, .value = 0x87 },
        .{ .tick = 3, .addr = 0xFF13, .value = 0x42 },
    };
    {
        const f = try fixture(arena, &seq, &seq, 4);
        const c = try compare(arena, f.gb, f.spc, all);
        try testing.expect(c.divergence == null);
        try testing.expectEqual(@as(usize, 3), c.gb_writes);
    }
    {
        var bad = seq;
        bad[2].value = 0x43;
        const f = try fixture(arena, &seq, &bad, 4);
        const c = try compare(arena, f.gb, f.spc, all);
        const d = c.divergence.?.write;
        try testing.expectEqual(@as(u32, 3), d.tick);
        try testing.expectEqual(@as(usize, 2), d.index);
        try testing.expectEqual(@as(u8, 0x42), d.gb.?.value);
        try testing.expectEqual(@as(u8, 0x43), d.spc.?.value);
    }
}

test "an engine that writes nothing diverges at the first write, and the report names that tick" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The self-test of the plan's Step 6: the seat engine plays nothing, so the
    // very first Game Boy write has no counterpart.
    const gb_seq = [_]Write{
        .{ .tick = 0, .addr = 0xFF26, .value = 0x80 },
        .{ .tick = 0, .addr = 0xFF12, .value = 0xF0 },
    };
    const f = try fixture(arena, &gb_seq, &.{}, 1);
    const c = try compare(arena, f.gb, f.spc, all);
    const d = c.divergence.?.write;
    try testing.expectEqual(@as(u32, 0), d.tick);
    try testing.expectEqual(@as(usize, 0), d.index);
    try testing.expectEqual(@as(u16, 0xFF26), d.gb.?.addr);
    try testing.expect(d.spc == null);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try report(arena, &w, f.gb, f.spc, c);
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "DIVERGE tick 0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "NR52 power") != null);
    try testing.expect(std.mem.indexOf(u8, text, "nothing: its sequence ended here") != null);
}

test "a filter hides another channel's divergence and keeps its own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const gb_seq = [_]Write{
        .{ .tick = 0, .addr = 0xFF12, .value = 0xF0 }, // square 1
        .{ .tick = 0, .addr = 0xFF17, .value = 0xA0 }, // square 2: not ported
        .{ .tick = 0, .addr = 0xFF25, .value = 0x33 }, // shared panning
    };
    const spc_seq = [_]Write{
        .{ .tick = 0, .addr = 0xFF12, .value = 0xF0 },
        // No square-2 envelope, and the panning carries only square 1's bits.
        .{ .tick = 0, .addr = 0xFF25, .value = 0x11 },
    };
    const f = try fixture(arena, &gb_seq, &spc_seq, 1);
    try testing.expect((try compare(arena, f.gb, f.spc, square1)).divergence == null);
    // Unfiltered, the same pair diverges at the square-2 write.
    const unfiltered = (try compare(arena, f.gb, f.spc, all)).divergence.?.write;
    try testing.expectEqual(@as(u16, 0xFF17), unfiltered.gb.?.addr);
}

test "a read-back byte is compared at the tick its reply was latched at" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const back = try arena.alloc([audio_req.read_back.len]u8, 3);
    for (back) |*b| b.* = @splat(0);
    back[1][0] = 0x04; // songPlaying after tick 1
    const gb: GbRun = .{ .writes = &.{}, .read_back = back };

    var engine: [audio_req.read_back.len]u8 = @splat(0);
    engine[0] = 0x04;
    const agree: SpcRun = .{
        .writes = &.{},
        .replies = try arena.dupe(Reply, &.{ .{ .ticks = 0, .engine = @splat(0) }, .{ .ticks = 2, .engine = engine } }),
        .summary = "summary",
    };
    try testing.expect((try compare(arena, gb, agree, all)).divergence == null);

    // The same reply one tick earlier is the state after tick 0, where the
    // Game Boy has not latched the song yet.
    const early: SpcRun = .{
        .writes = &.{},
        .replies = try arena.dupe(Reply, &.{.{ .ticks = 1, .engine = engine }}),
        .summary = "summary",
    };
    const d = (try compare(arena, gb, early, all)).divergence.?.read_back;
    try testing.expectEqual(@as(u32, 0), d.tick);
    try testing.expectEqual(@as(usize, 0), d.which);
    try testing.expectEqual(@as(u8, 0x00), d.gb);
    try testing.expectEqual(@as(u8, 0x04), d.spc);
}

test "the Game Boy side attributes writes to the tick that made them, and latches the song" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rom = try testrom.load(arena) orelse return error.SkipZigTest;
    var line: usize = 0;
    var what: []const u8 = "";
    const script = try audio_req.parse(arena, "[songRequest=04]\n[]\n[]\n[]\n", &line, &what);

    var run = try runGb(a, rom, script);
    defer run.deinit(a);

    try testing.expectEqual(@as(usize, 4), run.read_back.len);
    // The request reached the engine: `songPlaying` is $04 from the first tick
    // on. Without this the comparison could be two silent engines agreeing.
    try testing.expectEqual(@as(u8, 0x04), run.read_back[0][0]);
    try testing.expectEqual(@as(u8, 0x04), run.read_back[3][0]);

    // Song init writes registers, and they are charged to tick 0.
    try testing.expect(run.writes.len > 0);
    try testing.expectEqual(@as(u32, 0), run.writes[0].tick);
    for (run.writes) |w| {
        try testing.expect(apu.owns(w.addr));
        try testing.expect(w.tick < 4);
    }
    // Ticks are non-decreasing, because the log is append-only in execution
    // order and each tick's slice is taken as it is made.
    var last: u32 = 0;
    for (run.writes) |w| {
        try testing.expect(w.tick >= last);
        last = w.tick;
    }
}
