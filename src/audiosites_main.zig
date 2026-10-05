//! `zig build audiosites` — every Game Boy sound-request site and what the port
//! does with it. See `src/audio_sites.zig`.
//!
//! `zig build audiosites -- [sent|waived|missing|unported]` lists one status.
//! Exits 1 when a site is missing or a put or waiver is wrong, as the test does.

const std = @import("std");
const build_options = @import("build_options");
const audio_req = @import("audio_req.zig");
const sites = @import("audio_sites.zig");

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const io = init.io;

    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var only: ?sites.Status = null;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    if (args.next()) |a| only = std.meta.stringToEnum(sites.Status, a) orelse {
        try out.print("usage: zig build audiosites -- [sent|waived|missing|unported]\n", .{});
        return 2;
    };

    const got = try sites.load(gpa, io, build_options.rom_path) orelse {
        try out.print("audiosites: skipped, needs M2_ROM (see docs/setup.md)\n", .{});
        return 0;
    };
    const l = got.ledger;
    for (l.rows) |r| {
        if (only != null and only.? != r.status) continue;
        try out.print("{X:0>2}:{X:0>4}  {s:<24} ", .{ r.site.bank, r.site.addr, audio_req.slots[r.site.slot].name });
        if (r.site.value) |v| try out.print("{X:0>2}", .{v}) else try out.print("??", .{});
        try out.print("  {s:<8}", .{@tagName(r.status)});
        switch (r.status) {
            .sent => try out.print("  engine/main.asm:{d}", .{r.line}),
            .waived => try out.print("  {s}", .{r.why}),
            else => {},
        }
        if (r.routine) |n| try out.print("  in {s}", .{n});
        try out.print("\n", .{});
    }
    for (l.problems) |p| try out.print("PROBLEM {any}\n", .{p});
    try out.print("{d} sites: {d} sent, {d} waived, {d} missing, {d} unported\n", .{
        l.rows.len, l.count(.sent), l.count(.waived), l.count(.missing), l.count(.unported),
    });
    return if (l.problems.len != 0 or l.count(.missing) != 0) 1 else 0;
}
