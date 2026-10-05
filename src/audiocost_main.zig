//! `zig build audiocost` - what `handleAudio` costs per call on the Game Boy,
//! and which bank-4 routines the cycles go to. See `audiocost.zig`.
//!
//! Routine names come from `vendor/m2ros/bank4.sym` (`tools/get-bank4-sym.sh`).
//! Without it the attribution is by address.

const std = @import("std");
const audiocost = @import("audiocost.zig");
const rom_mod = @import("rom.zig");

const build_options = @import("build_options");

const sym_path = "vendor/m2ros/bank4.sym";
const top_routines: usize = 15;

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    if (build_options.rom_path.len == 0) {
        try out.print("no ROM configured (set M2_ROM); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(init.io, build_options.rom_path, arena, .limited(rom_mod.expected_size * 4));

    const syms: ?audiocost.Symbols = blk: {
        const text = std.Io.Dir.cwd().readFileAlloc(init.io, sym_path, arena, .limited(1 << 20)) catch break :blk null;
        break :blk try audiocost.Symbols.parse(arena, text);
    };

    try out.print(
        \\# handleAudio on the Game Boy: T-cycles per call
        \\
        \\SM83 T-cycles (4194304/s; one LCD frame is 70224). A lead for the
        \\SPC700 spike, not a gate: the proportions carry over, the units do not.
        \\One call per frame, {d} calls ({d} s) per case, from song-init unless
        \\a skip is given. Routine names: {s}.
        \\
        \\| case | song | skip | max | p95 | mean | mean % of frame |
        \\|---|---|---:|---:|---:|---:|---:|
        \\
    , .{ audiocost.thirty_seconds, 30, if (syms != null) sym_path else "none (run tools/get-bank4-sym.sh)" });

    const profiles = try arena.alloc(audiocost.Profile, audiocost.cases.len);
    for (audiocost.cases, profiles) |case, *p| {
        p.* = .{};
        const c = try audiocost.run(arena, rom, case, p);
        try out.print("| {s} | ${X:0>2} | {d} | {d} | {d} | {d:.0} | {d:.2}% |\n", .{
            case.name, case.song, case.skip, c.max, c.p95, c.mean, c.mean * 100.0 / 70224.0,
        });
    }

    for (audiocost.cases, profiles) |case, *p| {
        try out.print("\n## {s}: where the cycles go\n\n| routine | cycles | share |\n|---|---:|---:|\n", .{case.name});
        try printAttribution(arena, out, p, syms);
    }
    try printRequests(arena, out, rom);
    try out.flush();
}

fn printRequests(arena: std.mem.Allocator, out: *std.Io.Writer, rom: []const u8) !void {
    const sites = try audiocost.requestSites(arena, rom);
    try out.print(
        \\
        \\# What the game asks for (whole ROM, outside bank 4)
        \\
        \\A byte scan: `LD A,d8; LD (nn),A` and `LD HL,nn; LD (HL),d8` resolve an id,
        \\and a bare `LD (nn),A` is listed by address for its routine to answer.
        \\
        \\| request byte | sites | constant ids | computed at |
        \\|---|---:|---|---|
        \\
    , .{});
    for (audiocost.request_bytes) |r| {
        var seen = [_]bool{false} ** 256;
        var n: usize = 0;
        for (sites) |site| {
            if (site.target != r.addr) continue;
            n += 1;
            if (site.id) |id| seen[id] = true;
        }
        try out.print("| `{s}` ${X:0>4} | {d} | ", .{ r.name, r.addr, n });
        for (seen, 0..) |on, id| if (on) try out.print("{X:0>2} ", .{id});
        try out.print("| ", .{});
        for (sites) |site| {
            if (site.target == r.addr and site.id == null) try out.print("{X:0>2}:{X:0>4} ", .{ site.bank, site.addr });
        }
        try out.print("|\n", .{});
    }

    const songs = try audiocost.doorSongs(arena, rom);
    try out.print("\n## Door-script `SONG` operands\n\n| operand | scripts |\n|---|---:|\n", .{});
    for (songs, 0..) |c, v| if (c > 0) try out.print("| ${X} | {d} |\n", .{ v, c });
}

const Row = struct { name: []const u8, cycles: u64 };

fn printAttribution(arena: std.mem.Allocator, out: *std.Io.Writer, p: *const audiocost.Profile, syms: ?audiocost.Symbols) !void {
    var rows: std.ArrayList(Row) = .empty;
    var total: u64 = 0;
    for (p.by_pc, 0..) |c, pc| {
        if (c == 0) continue;
        total += c;
        const name = if (syms) |s| (s.lookup(@intCast(pc)) orelse try std.fmt.allocPrint(arena, "${X:0>4}", .{pc})) else try std.fmt.allocPrint(arena, "${X:0>4}", .{pc});
        for (rows.items) |*r| {
            if (std.mem.eql(u8, r.name, name)) {
                r.cycles += c;
                break;
            }
        } else try rows.append(arena, .{ .name = name, .cycles = c });
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn gt(_: void, a: Row, b: Row) bool {
            return a.cycles > b.cycles or (a.cycles == b.cycles and std.mem.lessThan(u8, a.name, b.name));
        }
    }.gt);
    var shown: u64 = 0;
    for (rows.items[0..@min(rows.items.len, top_routines)]) |r| {
        shown += r.cycles;
        try out.print("| `{s}` | {d} | {d:.1}% |\n", .{ r.name, r.cycles, pct(r.cycles, total) });
    }
    if (rows.items.len > top_routines) {
        try out.print("| {d} others | {d} | {d:.1}% |\n", .{ rows.items.len - top_routines, total - shown, pct(total - shown, total) });
    }
}

fn pct(a: u64, b: u64) f64 {
    return if (b == 0) 0 else @as(f64, @floatFromInt(a)) * 100.0 / @as(f64, @floatFromInt(b));
}
