//! `zig build crawl` -- the door crawl (1.0 Step 5a), written where the warp
//! table reads it: `build-out/crawl-<rom>-v<version>.txt`. Nothing to do when
//! that file is already there, so the steps that convert can depend on this
//! one and pay for the crawl once per ROM and crawler version.
//!
//! `check` is `verify-full`'s `crawl cold` rung (release Step 0): it crawls
//! from scratch and fails unless the bytes are the cached file's. The cache is
//! keyed on the ROM and `warp.crawl_version` only, so a crawler change without
//! a bump leaves it stale, and every step reads the stale one; 1.0 was graded
//! on a crawl from before the crawler was committed.
//!
//! It is also the `crawl jobs` rung (release Step 4): the crawl from scratch
//! runs on one machine, on two and on one per logical CPU, and every run must
//! give those bytes and the one-machine crawl's counters.
//!
//! `--jobs N` sets the lanes for a plain crawl (0, the default, is one per
//! logical CPU).

const std = @import("std");
const build_options = @import("build_options");
const rom_mod = @import("rom.zig");
const warp = @import("warp.zig");
const crawl = @import("crawl.zig");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    if (build_options.rom_path.len == 0) return; // no ROM: nothing converts either

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var check = false;
    var jobs: usize = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "check")) {
            check = true;
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            jobs = try std.fmt.parseInt(usize, args.next() orelse return error.MissingJobs, 10);
        } else return error.UnknownArgument;
    }

    const rom = try std.Io.Dir.cwd().readFileAlloc(init.io, build_options.rom_path, a, .limited(rom_mod.expected_size * 4));
    var buf: [128]u8 = undefined;
    const path = warp.crawlPath(&buf, rom);
    if (check) return checkCold(init.io, a, rom, path);
    if (std.Io.Dir.cwd().access(init.io, path, .{})) |_| return else |_| {}

    std.debug.print("crawl: walking every door on the Game Boy (a few minutes, once per ROM)...\n", .{});
    const t0 = std.Io.Clock.awake.now(init.io);
    const c = try crawl.walk(a, rom, .{ .jobs = jobs });
    const walked = c.doors;

    var out: std.Io.Writer.Allocating = .init(a);
    try warp.formatWalked(&out.writer, walked);
    try std.Io.Dir.cwd().createDirPath(init.io, warp.crawl_dir);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = out.written() });
    const dt = t0.durationTo(std.Io.Clock.awake.now(init.io));
    std.debug.print("crawl: {d} doors walked from {d} rooms-with-a-state ({d} seeded) in {d} s -> {s}\n", .{ walked.len, c.entries, c.seeded, @divTrunc(dt.toMilliseconds(), 1000), path });
}

/// `crawl cold` and `crawl jobs`: a crawl from scratch at each lane count,
/// against the cached file's bytes and the one-machine crawl's counters.
fn checkCold(io: std.Io, a: std.mem.Allocator, rom: []const u8, path: []const u8) !void {
    const cached = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20));
    const cpus = std.Thread.getCpuCount() catch 1;
    const counts = [_]usize{ 1, 2, cpus };
    var first: crawl.Walk = undefined;
    for (counts, 0..) |jobs, i| {
        const t0 = std.Io.Clock.awake.now(io);
        const c = try crawl.walk(a, rom, .{ .jobs = jobs });
        const dt = t0.durationTo(std.Io.Clock.awake.now(io));
        var out: std.Io.Writer.Allocating = .init(a);
        try warp.formatWalked(&out.writer, c.doors);
        if (!std.mem.eql(u8, cached, out.written())) {
            std.debug.print("FAIL  crawl cold        {s} is not what the crawler walks now on {d} lane(s) ({d} doors): delete it and re-crawl, and bump `warp.crawl_version` if the crawler changed\n", .{ path, jobs, c.doors.len });
            std.process.exit(1);
        }
        std.debug.print("crawl: {d} lane(s): {d} doors, {d} s\n", .{ jobs, c.doors.len, @divTrunc(dt.toMilliseconds(), 1000) });
        if (i == 0) {
            first = c;
            std.debug.print("ok    crawl cold        a crawl from scratch is {s}, byte for byte ({d} doors)\n", .{ path, c.doors.len });
            continue;
        }
        const Counters = struct { entries: usize, tried: usize, no_spot: usize, stuck: usize, walled: usize, undrawn: usize, seeded: usize };
        const want: Counters = .{ .entries = first.entries, .tried = first.tried, .no_spot = first.no_spot, .stuck = first.stuck, .walled = first.walled, .undrawn = first.undrawn, .seeded = first.seeded };
        const got: Counters = .{ .entries = c.entries, .tried = c.tried, .no_spot = c.no_spot, .stuck = c.stuck, .walled = c.walled, .undrawn = c.undrawn, .seeded = c.seeded };
        if (!std.meta.eql(want, got)) {
            std.debug.print("FAIL  crawl jobs        on {d} lanes the counters are {any}, on one {any}\n", .{ jobs, got, want });
            std.process.exit(1);
        }
    }
    std.debug.print("ok    crawl jobs        on 1, 2 and {d} lanes: the same bytes and counters\n", .{cpus});
}
