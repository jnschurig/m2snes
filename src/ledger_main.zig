//! `zig build ledger` — build the logic inventory ledger and write it out.
//!
//! `zig build verify` runs the same code on a shorter observation and enforces
//! what it can; this is the full sweep and the human-readable view, for the
//! question "what is left to write" rather than "did anything regress".
//!
//! Arguments, all optional and positional:
//!
//!     zig build ledger -- [boot_seconds] [explore_seconds] [door_stride]
//!
//! A `door_stride` of 0 skips the door sweep entirely, which turns the run into
//! the static half plus exploration and takes seconds rather than minutes. That
//! is the configuration to reach for when iterating on this file; it is not the
//! one to quote a coverage figure from, because doors are the only way into the
//! script interpreter and the room loaders.

const std = @import("std");
const rom_mod = @import("rom.zig");
const ledger = @import("ledger.zig");
const extract = @import("extract.zig");

const build_options = @import("build_options");

fn parseNum(s: []const u8) ?usize {
    return std.fmt.parseInt(usize, s, 10) catch null;
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    if (build_options.rom_path.len == 0) {
        try out.print("ledger: no ROM configured (set M2_ROM); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }

    var opts: ledger.Options = .{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var n: usize = 0;
    while (args.next()) |a| : (n += 1) {
        const v = parseNum(a) orelse continue;
        switch (n) {
            0 => opts.boot_seconds = v,
            1 => opts.explore_seconds = v,
            2 => opts.door_stride = v,
            else => {},
        }
    }

    const rom = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        build_options.rom_path,
        arena,
        .limited(rom_mod.expected_size * 4),
    );

    try out.print(
        "watching the game run: {d}s boot, {d}s exploring, every {d}th door...\n",
        .{ opts.boot_seconds, opts.explore_seconds, opts.door_stride },
    );
    try out.flush();

    const obs = try ledger.observe(arena, rom, opts);
    const l = try ledger.build(arena, rom, obs);

    const text = try ledger.reportText(arena, l);
    try out.writeAll(text);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, extract.out_dir, .{});
    defer dir.close(init.io);
    try dir.writeFile(init.io, .{ .sub_path = ledger.report_name, .data = text });
    const rows = try ledger.tsv(arena, l);
    try dir.writeFile(init.io, .{ .sub_path = ledger.tsv_name, .data = rows });

    try out.print("\nwritten to {s}/{s} and {s}/{s}\n", .{
        extract.out_dir, ledger.report_name, extract.out_dir, ledger.tsv_name,
    });
    try out.flush();
}
