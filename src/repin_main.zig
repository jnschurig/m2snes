//! `zig build repin -- "<why>"` -- move the output pins (`src/pin.zig`) to
//! what the build makes now, and log the move.
//!
//! The build step makes both carts and the crawl first, so the hashes are of
//! this tree's output. It refuses an empty reason, and does nothing when the
//! hashes have not moved.

const std = @import("std");
const build_options = @import("build_options");
const rom_mod = @import("rom.zig");
const warp = @import("warp.zig");
const pin = @import("pin.zig");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var why_parts: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| try why_parts.append(a, arg);
    const why = std.mem.trim(u8, try std.mem.join(a, " ", why_parts.items), " \t\r\n");
    if (why.len == 0 or std.mem.indexOfScalar(u8, why, '\n') != null) {
        std.debug.print("repin: give one line saying why the output moved: {s}\n", .{pin.repin_hint});
        std.process.exit(1);
    }
    if (build_options.rom_path.len == 0) {
        std.debug.print("repin: no ROM configured (set M2_ROM; see docs/setup.md)\n", .{});
        std.process.exit(1);
    }

    const rom = try cwd.readFileAlloc(io, build_options.rom_path, a, .limited(rom_mod.expected_size * 4));
    var buf: [128]u8 = undefined;
    const crawl_path = warp.crawlPath(&buf, rom);
    var failed: []const u8 = "";
    const new = pin.current(a, io, crawl_path, &failed) catch |e| {
        std.debug.print("repin: cannot read {s}: {s}\n", .{ failed, @errorName(e) });
        std.process.exit(1);
    };

    const old: ?pin.Pins = if (cwd.readFileAlloc(io, pin.cart_path, a, .limited(1 << 16))) |text|
        pin.parse(text) catch |e| {
            std.debug.print("repin: {s} is unreadable ({s}); fix or delete it by hand\n", .{ pin.cart_path, @errorName(e) });
            std.process.exit(1);
        }
    else |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (old) |o| if (pin.equal(o, new)) {
        try out.print("repin: the output has not moved; {s} unchanged\n", .{pin.cart_path});
        try out.flush();
        return;
    };

    var day_buf: [10]u8 = undefined;
    const now: u64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
    const day = pin.date(&day_buf, now);

    const history = cwd.readFileAlloc(io, pin.history_path, a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => pin.history_header,
        else => return e,
    };
    var entry: std.Io.Writer.Allocating = .init(a);
    try pin.formatEntry(&entry.writer, day, old, new, why);
    var cart: std.Io.Writer.Allocating = .init(a);
    try pin.format(&cart.writer, new);

    try cwd.createDirPath(io, std.fs.path.dirname(pin.cart_path).?);
    try cwd.writeFile(io, .{ .sub_path = pin.history_path, .data = try std.mem.concat(a, u8, &.{ history, entry.written() }) });
    try cwd.writeFile(io, .{ .sub_path = pin.cart_path, .data = cart.written() });

    for (std.enums.values(pin.Kind)) |k| {
        if (old) |o| {
            if (std.mem.eql(u8, &o.get(k), &new.get(k))) {
                try out.print("repin: {s: <6} {x} (unchanged)\n", .{ @tagName(k), &new.get(k) });
                continue;
            }
            try out.print("repin: {s: <6} {x} -> {x}\n", .{ @tagName(k), &o.get(k), &new.get(k) });
        } else try out.print("repin: {s: <6} none -> {x}\n", .{ @tagName(k), &new.get(k) });
    }
    try out.print("repin: wrote {s} and appended to {s}: {s}\n", .{ pin.cart_path, pin.history_path, why });
    try out.flush();
}
