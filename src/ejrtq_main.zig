//! `zig build ejrtq [-- check] [-- --zip <path>]`: the EJRTQ oracle's
//! extraction (colorization Step 3). Run by hand; no gate runs it.
//!
//! Without `check` it writes `src/full_assign.zig`, keeping that file's
//! hand-edited section. With `check` it writes nothing and fails if the file
//! differs from a fresh extraction. Either way it fails while a conflict has
//! no hand choice, or if the rendered text would carry an EJRTQ colour.

const std = @import("std");
const rom_mod = @import("rom.zig");
const ejrtq = @import("ejrtq.zig");
const ips = @import("ips.zig");

const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var check = false;
    var zip_path: []const u8 = ejrtq.default_zip;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "check")) {
            check = true;
        } else if (std.mem.eql(u8, arg, "--zip")) {
            zip_path = args.next() orelse return fail(out, "--zip needs a path", .{});
        } else return fail(out, "unknown argument `{s}`; usage: zig build ejrtq [-- check] [-- --zip <path>]", .{arg});
    }

    if (build_options.rom_path.len == 0) return fail(out, "no ROM configured (set M2_ROM); see docs/setup.md", .{});
    const rom = try cwd.readFileAlloc(io, build_options.rom_path, a, .limited(rom_mod.expected_size * 4));
    _ = try rom_mod.ingest(a, rom, null);
    const zip = cwd.readFileAlloc(io, zip_path, a, .limited(16 << 20)) catch |e|
        return fail(out, "can't read {s} ({t}): put EJRTQ's v1.3 zip there, or pass --zip", .{ zip_path, e });
    const patched = ejrtq.patchedRom(a, rom, zip) catch |e| switch (e) {
        error.WrongPatch => return fail(out, "{s} is not EJRTQ v1.3: expected `{s}` with SHA-1 {s}", .{ zip_path, ips.ejrtq_name, ips.ejrtq_sha1 }),
        else => return e,
    };

    const x = try ejrtq.extract(a, rom, patched);
    try report(out, x);
    if (x.stray.len != 0) {
        for (x.stray[0..@min(x.stray.len, 40)]) |s| try out.print("stray: {X:0>2}:{X:0>4} = ${X:0>2}\n", .{ s.bank, s.addr, s.value });
        return fail(out, "{d} shadow-bank bytes no graphics tile explains; the model is incomplete", .{x.stray.len});
    }

    var colour_buf: [64]u16 = undefined;
    const existing: ?[]const u8 = cwd.readFileAlloc(io, ejrtq.output_path, a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    const text = try ejrtq.render(a, x, ejrtq.handSection(existing));
    if (ejrtq.colourLeak(text, x.colours.values(&colour_buf))) |leak|
        return fail(out, "line {d} of the rendered file has a number equal to one of EJRTQ's colours; nothing written", .{leak.line});

    const settle = try ejrtq.unsettled(a, x);
    for (settle.open) |u| try out.print("conflict: {s} id ${X:0>2} has no hand choice in {s}_choices\n", .{ u.table, u.id, u.table });
    for (settle.stale) |u| try out.print("stale: {s}_choices names id ${X:0>2}, which no edited position has\n", .{ u.table, u.id });

    if (check) {
        const have = existing orelse return fail(out, "{s} does not exist; run `zig build ejrtq`", .{ejrtq.output_path});
        if (!std.mem.eql(u8, have, text)) {
            try diffLines(out, have, text);
            return fail(out, "{s} differs from a fresh extraction", .{ejrtq.output_path});
        }
        try out.print("check: {s} agrees with the extraction\n", .{ejrtq.output_path});
    } else {
        try cwd.writeFile(io, .{ .sub_path = ejrtq.output_path, .data = text });
        try out.print("wrote {s} ({d} bytes)\n", .{ ejrtq.output_path, text.len });
    }
    // The file stands, even with an open conflict, so its choices can be made.
    if (settle.open.len != 0 or settle.stale.len != 0) return fail(out, "settle the conflicts above in the hand-edited section", .{});
}

fn report(out: *std.Io.Writer, x: ejrtq.Extraction) !void {
    var tiles: usize = 0;
    var per_slot: [8]usize = @splat(0);
    for (x.slots) |r| {
        tiles += r.slots.len;
        for (r.slots) |s| per_slot[s] += 1;
    }
    try out.print("source tiles: {d} in {d} regions; per slot:", .{ tiles, x.slots.len });
    for (per_slot, 0..) |n, s| try out.print(" {d}:{d}", .{ s, n });
    try out.print("\nOBP1 swap: slot {d} -> {d}, else -> {d}; frozen -> {d}\n", .{ x.obp1.when, x.obp1.then, x.obp1.otherwise, x.frozen });
    for (x.slots) |r| {
        var used: u8 = 0;
        for (r.slots) |s| used |= @as(u8, 1) << s;
        try out.print("  {s:<26} {d:>4} tiles, slots {b:0>8}\n", .{ r.name, r.slots.len, used });
    }
    try out.print("HUD ids:", .{});
    for (x.hud) |d| try out.print(" ${X:0>2}={b:0>8}{s}", .{ d.id, d.slots, if (d.conflict()) "!" else "" });
    try out.print("\nQueen screens:", .{});
    for (x.queen_screens) |s| try out.print(" ${X:0>2}", .{s});
    try out.print("; ids:", .{});
    for (x.queen) |d| try out.print(" ${X:0>2}={b:0>8}{s}", .{ d.id, d.slots, if (d.conflict()) "!" else "" });
    try out.print("\nlook-alike (kept):", .{});
    for (x.look.keep) |l| try out.print(" {t}{d}={d}/{b:0>4}", .{ l.layer, l.a, l.b, l.shades });
    try out.print("\nidentical tiles EJRTQ draws differently:", .{});
    for (x.look.differ) |l| try out.print(" {t}{d}~{d}/{b:0>4}", .{ l.layer, l.a, l.b, l.shades });
    try out.print("\npixel-identical tile pairs in different slots:\n", .{});
    for (x.look.pairs) |p| try out.print("  {s} ${X:0>2} (slot {d}) = ${X:0>2} (slot {d}): {s}\n", .{
        p.region, p.i, p.a, p.j, p.b, if (p.alike) "same colours in EJRTQ" else "EJRTQ draws them differently",
    });
}

fn diffLines(out: *std.Io.Writer, have: []const u8, want: []const u8) !void {
    var h = std.mem.splitScalar(u8, have, '\n');
    var w = std.mem.splitScalar(u8, want, '\n');
    var line: usize = 1;
    var shown: usize = 0;
    while (true) : (line += 1) {
        const hl = h.next();
        const wl = w.next();
        if (hl == null and wl == null) break;
        if (hl != null and wl != null and std.mem.eql(u8, hl.?, wl.?)) continue;
        if (shown < 20) try out.print("line {d}:\n  file:      {s}\n  extracted: {s}\n", .{ line, hl orelse "<end>", wl orelse "<end>" });
        shown += 1;
    }
    if (shown > 20) try out.print("... and {d} more differing lines\n", .{shown - 20});
}

fn fail(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try out.print("ejrtq: " ++ fmt ++ "\n", args);
    try out.flush();
    std.process.exit(1);
}
