//! What one `handleAudio` call costs on the Game Boy, and where it goes.
//!
//! The metroid2-audio cycle (snes_game_dev `.local/docs/2026-09-16-metroid2-audio`)
//! rewrites bank 4's sound engine to run on the SPC700, and its gate is a spike
//! of the engine's hot path. This says which path that is and how much it does:
//! T-cycles per call (max, p95, mean) over thirty seconds of a song, and the
//! cycles attributed to the bank-4 routine each instruction belongs to.
//!
//! **A lead, not a gate.** SM83 T-cycles do not convert to SPC700 time. What
//! carries over is the proportions: which routines dominate, and how much a
//! busy frame costs against a quiet one.
//!
//! The engine is driven the way the game drives it, and nothing else runs. A
//! cold machine, `initializeAudio` once, the request written to WRAM, then
//! `handleAudio` called once per frame. The call goes to bank 4's trampoline at
//! `$4000` directly, so the `callFar` in `handleAudio_longJump` is not in the
//! figures; it is a fixed few dozen cycles and not part of the port.

const std = @import("std");
const harness = @import("gb/harness.zig");
const door = @import("door.zig");

// ---- The driver, and how we know it ----------------------------------------
//
// The entry points and the song request are snes_game_dev `audio/descriptor.zig`'s
// `metroid2_driver`, established there by calling each trampoline and watching
// the request byte. The SFX request bytes are M2RoS `ram/wram.asm`.

pub const bank: u8 = 4;
pub const handle: u16 = 0x4000;
/// `externalSilenceAudio`, which the game calls outside `handleAudio`: at a
/// death, the boot and two unused game modes (M2RoS bank_000.asm:7937 and three
/// more). Its own trampoline, between the other two; the test below holds it to
/// the ROM rather than to M2RoS's label.
pub const silence: u16 = 0x4003;
pub const initialize: u16 = 0x4006;
pub const song_request: u16 = 0xCEDC;
pub const song_playing: u16 = 0xCEDD;
pub const sfx_request_square1: u16 = 0xCEC0;
pub const sfx_request_noise: u16 = 0xCED5;

/// Thirty seconds of Game Boy frames at 59.73 Hz, rounded up.
pub const thirty_seconds: u32 = 1792;

/// A write to a request byte, before the call on `frame` (counted from the
/// first measured call).
pub const Request = struct { frame: u32, addr: u16, value: u8 };

pub const Case = struct {
    name: []const u8,
    song: u8,
    /// Calls made before measuring starts, to reach a point inside the song.
    skip: u32 = 0,
    frames: u32 = thirty_seconds,
    requests: []const Request = &.{},
};

/// A missile, a beam, and enemy noise, one every eight frames from two seconds
/// in. Denser than play, which is the point: it is the SFX-over-music case the
/// spike has to fit, not a typical one.
pub const sfx_burst = blk: {
    const pattern = [_]struct { addr: u16, value: u8 }{
        .{ .addr = sfx_request_square1, .value = 0x08 }, // shooting missile
        .{ .addr = sfx_request_noise, .value = 0x02 }, // enemy killed
        .{ .addr = sfx_request_square1, .value = 0x07 }, // shooting beam
        .{ .addr = sfx_request_noise, .value = 0x03 }, // enemy explosion
        .{ .addr = sfx_request_square1, .value = 0x0F }, // beam dink
        .{ .addr = sfx_request_noise, .value = 0x12 }, // enemy projectile fired
    };
    const first: u32 = 120;
    const every: u32 = 8;
    const count = (thirty_seconds - first) / every;
    var out: [count]Request = undefined;
    for (&out, 0..) |*r, i| {
        const p = pattern[i % pattern.len];
        r.* = .{ .frame = first + @as(u32, @intCast(i)) * every, .addr = p.addr, .value = p.value };
    }
    break :blk out;
};

/// The slice's three captured tracks (snes_game_dev `metroid2_captures`), and
/// the surface theme under a burst of sound effects.
pub const cases = [_]Case{
    .{ .name = "title", .song = 0x11 },
    // `attract` is song $11 again, 3239 driver frames in.
    .{ .name = "attract", .song = 0x11, .skip = 3239 },
    .{ .name = "surface", .song = 0x04 },
    .{ .name = "surface+sfx", .song = 0x04, .requests = &sfx_burst },
};

// ---- Measuring -------------------------------------------------------------

pub const Costs = struct {
    calls: usize,
    max: u64,
    p95: u64,
    mean: f64,
    total: u64,
};

/// Cycles per program counter, over every measured call. Indexed by PC: bank 4
/// is the only bank mapped high, so a PC names one instruction.
pub const Profile = struct {
    by_pc: [0x8000]u64 = [_]u64{0} ** 0x8000,
    cpu_cycles: *const u64 = undefined,
    last_pc: ?u16 = null,
    last_cycles: u64 = 0,

    fn hit(ctx: *anyopaque, _: usize, pc: u16) void {
        const self: *Profile = @ptrCast(@alignCast(ctx));
        self.close(pc);
    }

    /// Charge the instruction that just finished, and start timing `pc`.
    fn close(self: *Profile, pc: ?u16) void {
        const now = self.cpu_cycles.*;
        if (self.last_pc) |last| {
            if (last < self.by_pc.len) self.by_pc[last] += now - self.last_cycles;
        }
        self.last_pc = pc;
        self.last_cycles = now;
    }
};

pub const Error = error{ DidNotReturn, OutOfMemory } || harness.Error;

/// Run one case on a fresh machine. `profile`, if given, accumulates the
/// measured calls only.
pub fn run(allocator: std.mem.Allocator, rom: []const u8, case: Case, profile: ?*Profile) Error!Costs {
    var m = try harness.bootFrom(allocator, rom, null);
    defer m.deinit();

    if (!(try m.call(.{ .bank = bank, .addr = initialize })).returned) return error.DidNotReturn;
    m.write(song_request, case.song);
    for (0..case.skip) |_| {
        if (!(try m.call(.{ .bank = bank, .addr = handle })).returned) return error.DidNotReturn;
    }

    if (profile) |p| {
        p.cpu_cycles = &m.sys.cpu.cycles;
        m.exec = .{ .ctx = p, .hit = Profile.hit };
    }
    defer m.exec = null;

    const per_call = try allocator.alloc(u64, case.frames);
    defer allocator.free(per_call);
    var next: usize = 0;
    for (per_call, 0..) |*cost, f| {
        while (next < case.requests.len and case.requests[next].frame == f) : (next += 1) {
            m.write(case.requests[next].addr, case.requests[next].value);
        }
        const before = m.sys.cpu.cycles;
        const out = try m.call(.{ .bank = bank, .addr = handle });
        if (profile) |p| p.close(null);
        if (!out.returned) return error.DidNotReturn;
        cost.* = m.sys.cpu.cycles - before;
    }
    return summarize(per_call);
}

pub fn summarize(per_call: []u64) Costs {
    var total: u64 = 0;
    var max: u64 = 0;
    for (per_call) |c| {
        total += c;
        max = @max(max, c);
    }
    std.mem.sort(u64, per_call, {}, std.sort.asc(u64));
    return .{
        .calls = per_call.len,
        .max = max,
        .p95 = percentile(per_call, 95),
        .mean = if (per_call.len == 0) 0 else @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(per_call.len)),
        .total = total,
    };
}

/// Nearest-rank percentile of an ascending slice.
pub fn percentile(sorted: []const u64, pct: u32) u64 {
    if (sorted.len == 0) return 0;
    const rank = (sorted.len * pct + 99) / 100;
    return sorted[@max(rank, 1) - 1];
}

// ---- What the game asks for ------------------------------------------------
//
// Every write to a request byte outside bank 4, found in the ROM rather than in
// a comment about it. A site is `LD (nn),A` (`EA lo hi`) or `LD (HL),d8` after
// `LD HL,nn` (`21 lo hi 36 d8`). Its id is resolved when it is a constant:
// `LD A,d8` (`3E d8`) directly before the `EA`, or the `36`'s operand. The rest
// are listed by address, because a computed id (a table, `ADD A,$11`) is a
// question for the routine and not for a byte pattern.
//
// **Whole game, not the slice.** A byte scan cannot say which sites the slice
// executes. It is the complete set to check the slice's list against.

pub const RequestByte = struct { addr: u16, name: []const u8 };

/// M2RoS `ram/wram.asm`'s request bytes, the ones "requested by writing
/// directly" to according to its own header.
pub const request_bytes = [_]RequestByte{
    .{ .addr = 0xCEC0, .name = "sfxRequest_square1" },
    .{ .addr = 0xCEC7, .name = "sfxRequest_square2" },
    .{ .addr = 0xCECE, .name = "sfxRequest_fakeWave" },
    .{ .addr = 0xCED5, .name = "sfxRequest_noise" },
    .{ .addr = song_request, .name = "songRequest" },
    .{ .addr = 0xCEDE, .name = "songInterruptionRequest" },
    .{ .addr = 0xCFE5, .name = "sfxRequest_wave" },
    .{ .addr = 0xCFC7, .name = "audioPauseControl" },
};

pub const Site = struct { bank: u8, addr: u16, target: u16, id: ?u8 };

pub fn requestSites(allocator: std.mem.Allocator, rom: []const u8) ![]Site {
    var out: std.ArrayList(Site) = .empty;
    const banks = rom.len / 0x4000;
    for (0..banks) |b| {
        if (b == bank) continue;
        const seg = rom[b * 0x4000 ..][0..0x4000];
        const org: u16 = if (b == 0) 0 else 0x4000;
        var i: usize = 0;
        while (i + 3 <= seg.len) : (i += 1) {
            const site_addr: u16 = org + @as(u16, @intCast(i));
            if (seg[i] == 0xEA) {
                const t = std.mem.readInt(u16, seg[i + 1 ..][0..2], .little);
                if (!isRequest(t)) continue;
                const id: ?u8 = if (i >= 2 and seg[i - 2] == 0x3E) seg[i - 1] else null;
                try out.append(allocator, .{ .bank = @intCast(b), .addr = site_addr, .target = t, .id = id });
            } else if (seg[i] == 0x21 and i + 5 <= seg.len and seg[i + 3] == 0x36) {
                const t = std.mem.readInt(u16, seg[i + 1 ..][0..2], .little);
                if (!isRequest(t)) continue;
                try out.append(allocator, .{ .bank = @intCast(b), .addr = site_addr, .target = t, .id = seg[i + 4] });
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

fn isRequest(addr: u16) bool {
    for (request_bytes) |r| if (r.addr == addr) return true;
    return false;
}

/// How many door-script `SONG` operations carry each operand, over the whole
/// script region. The interpreter (00:$259E) asks for the operand as the song,
/// except `$A` (silence) and while the earthquake holds the channels.
pub fn doorSongs(allocator: std.mem.Allocator, rom: []const u8) ![16]usize {
    var counts = [_]usize{0} ** 16;
    const body = door.region(rom) orelse return counts;
    var d = try door.decodeRegion(allocator, body);
    defer d.deinit(allocator);
    for (d.ops.items) |op| switch (op) {
        .song => |v| counts[v] += 1,
        else => {},
    };
    return counts;
}

// ---- Naming ----------------------------------------------------------------

/// Bank-4 symbols from `tools/get-bank4-sym.sh`, global labels only, sorted.
pub const Symbols = struct {
    addrs: []u16,
    names: [][]const u8,

    /// Parse an rgblink `.sym`. Local labels (`parent.local`) are skipped so an
    /// instruction is charged to the routine, not to a branch target inside it.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Symbols {
        var addrs: std.ArrayList(u16) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (!std.mem.startsWith(u8, line, "04:") or line.len < 9) continue;
            const name = line[8..];
            if (std.mem.indexOfScalar(u8, name, '.') != null) continue;
            const addr = std.fmt.parseInt(u16, line[3..7], 16) catch continue;
            try addrs.append(allocator, addr);
            try names.append(allocator, name);
        }
        const Ctx = struct { a: []u16, n: [][]const u8 };
        const ctx: Ctx = .{ .a = addrs.items, .n = names.items };
        std.sort.pdqContext(0, addrs.items.len, struct {
            c: Ctx,
            pub fn lessThan(s: @This(), i: usize, j: usize) bool {
                return s.c.a[i] < s.c.a[j];
            }
            pub fn swap(s: @This(), i: usize, j: usize) void {
                std.mem.swap(u16, &s.c.a[i], &s.c.a[j]);
                std.mem.swap([]const u8, &s.c.n[i], &s.c.n[j]);
            }
        }{ .c = ctx });
        return .{ .addrs = addrs.items, .names = names.items };
    }

    /// The greatest symbol at or below `pc`, or null outside bank 4's labels.
    pub fn lookup(self: Symbols, pc: u16) ?[]const u8 {
        if (pc < 0x4000) return null;
        var lo: usize = 0;
        var hi: usize = self.addrs.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.addrs[mid] <= pc) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) null else self.names[lo - 1];
    }
};

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "nearest-rank percentile" {
    const s = [_]u64{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    try testing.expectEqual(@as(u64, 100), percentile(&s, 95));
    try testing.expectEqual(@as(u64, 50), percentile(&s, 50));
    try testing.expectEqual(@as(u64, 10), percentile(&s, 1));
    try testing.expectEqual(@as(u64, 7), percentile(&[_]u64{7}, 95));
}

test "symbols charge an instruction to the routine above it, and skip local labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text =
        \\; File generated by rgblink
        \\04:4100 handleSong
        \\04:4000 externalHandleAudio
        \\04:4120 handleSong.loop
        \\01:4200 otherBank
        \\04:4200 handleSongPlaying
    ;
    const syms = try Symbols.parse(arena.allocator(), text);
    try testing.expectEqual(@as(usize, 3), syms.addrs.len);
    try testing.expectEqualStrings("externalHandleAudio", syms.lookup(0x4003).?);
    try testing.expectEqualStrings("handleSong", syms.lookup(0x4130).?);
    try testing.expectEqualStrings("handleSongPlaying", syms.lookup(0x4200).?);
    try testing.expectEqual(@as(?[]const u8, null), syms.lookup(0x3FFF));
}

test "the SFX burst is ordered by frame and stays inside thirty seconds" {
    var last: u32 = 0;
    for (sfx_burst) |r| {
        try testing.expect(r.frame >= last and r.frame < thirty_seconds);
        last = r.frame;
    }
}

test "the engine latches the requested song, and every call's cycles are charged somewhere" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    // The latch is the check that the request reached the engine at all: a
    // cost measured on an engine playing nothing would be a quiet-frame cost.
    var m = try harness.bootFrom(a, rom, null);
    defer m.deinit();
    try testing.expect((try m.call(.{ .bank = bank, .addr = initialize })).returned);
    m.write(song_request, 0x04);
    try testing.expect((try m.call(.{ .bank = bank, .addr = handle })).returned);
    try testing.expectEqual(@as(u8, 0x04), m.read(song_playing));

    const profile = try a.create(Profile);
    defer a.destroy(profile);
    profile.* = .{};
    const costs = try run(a, rom, .{ .name = "t", .song = 0x04, .frames = 120 }, profile);
    try testing.expectEqual(@as(usize, 120), costs.calls);
    try testing.expect(costs.max >= costs.p95 and costs.p95 > 0);
    var charged: u64 = 0;
    for (profile.by_pc) |c| charged += c;
    try testing.expectEqual(costs.total, charged);
}

test "the silence trampoline jumps to the routine that writes NR51 = $FF first" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    // `jp nn` at 4:$4003, and `ld a, $FF; ldh [rNR51], a` where it lands: the
    // first two instructions of `silenceAudio` (M2RoS bank_004.asm:1049), and
    // not of `initializeAudio`, which writes NR52 first.
    const at = @as(usize, bank) * 0x4000 + (silence - 0x4000);
    try testing.expectEqual(@as(u8, 0xC3), rom[at]);
    const target = @as(u16, rom[at + 1]) | @as(u16, rom[at + 2]) << 8;
    const t = @as(usize, bank) * 0x4000 + (target - 0x4000);
    try testing.expectEqualSlices(u8, &.{ 0x3E, 0xFF, 0xE0, 0x25 }, rom[t..][0..4]);
}

test "the request scan finds constant ids and leaves computed ones unresolved" {
    const a = testing.allocator;
    var rom = try a.alloc(u8, 5 * 0x4000);
    defer a.free(rom);
    @memset(rom, 0);
    // Bank 0: LD A,$08 ; LD ($CEC0),A. Bank 1: LD ($CED5),A with no constant.
    // Bank 2: LD HL,$CEDC ; LD (HL),$11. Bank 4 is the engine and is skipped.
    @memcpy(rom[0x100..][0..5], &[_]u8{ 0x3E, 0x08, 0xEA, 0xC0, 0xCE });
    @memcpy(rom[0x4200..][0..3], &[_]u8{ 0xEA, 0xD5, 0xCE });
    @memcpy(rom[0x8300..][0..5], &[_]u8{ 0x21, 0xDC, 0xCE, 0x36, 0x11 });
    @memcpy(rom[0x10400..][0..5], &[_]u8{ 0x3E, 0x01, 0xEA, 0xC0, 0xCE });
    const sites = try requestSites(a, rom);
    defer a.free(sites);
    try testing.expectEqual(@as(usize, 3), sites.len);
    try testing.expectEqual(Site{ .bank = 0, .addr = 0x0102, .target = 0xCEC0, .id = 0x08 }, sites[0]);
    try testing.expectEqual(Site{ .bank = 1, .addr = 0x4200, .target = 0xCED5, .id = null }, sites[1]);
    try testing.expectEqual(Site{ .bank = 2, .addr = 0x4300, .target = 0xCEDC, .id = 0x11 }, sites[2]);
}
