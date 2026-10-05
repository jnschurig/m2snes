//! `zig build credits -- [name...]` -- the `credits` rung (1.0 Step 22c) on its
//! own: every clock and fault, or the ones named (a clock as `credits.variants`
//! names it, a fault by its label), each written to `build-out/credits-*.sfc`
//! and `.lua` and run in Mesen2 in parallel. The gate runs the same through
//! `credits_grade`; this is for working on it, and for running a clock by hand:
//! `Mesen build-out/credits-0.sfc --testrunner build-out/credits-0.lua`.
//! `zig build credits -- <warp scenario>` (`warp_grade.Scenario`, e.g.
//! `missile_kill`) writes that one scenario's cart and script the same way.

const std = @import("std");
const build_options = @import("build_options");
const rom_mod = @import("rom.zig");
const room = @import("room.zig");
const credits = @import("credits.zig");
const credits_grade = @import("credits_grade.zig");
const snes_convert = @import("snes_convert.zig");
const snes_screen = @import("snes_screen.zig");
const snes_inject = @import("snes_inject.zig");
const warp = @import("warp.zig");
const debug_tables = @import("debug_tables.zig");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = init.io;

    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (build_options.rom_path.len == 0) {
        try out.print("credits: no ROM configured (set M2_ROM); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, build_options.rom_path, a, .limited(rom_mod.expected_size * 4));

    var names: std.ArrayList([]const u8) = .empty;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |x| try names.append(a, x);
    const wanted = struct {
        fn f(ns: []const []const u8, n: []const u8) bool {
            if (ns.len == 0) return true;
            for (ns) |x| if (std.mem.eql(u8, x, n)) return true;
            return false;
        }
    }.f;

    var set = try snes_convert.run(a, rom);
    _ = &set;
    const boot = try snes_screen.newGameBoot(a, rom);
    var diag: snes_inject.Diagnosis = .{};
    var dbg = try snes_inject.build(a, set, boot, &diag);
    try snes_inject.enableDebug(&dbg);
    const built = try warp.build(a, rom, try warp.loadWalked(a, rom));
    const sorted = try debug_tables.warpOrder(a, rom, built.entries);
    const mets = try debug_tables.metroidsBlob(a, rom);

    const wg = @import("warp_grade.zig");
    if (names.items.len == 1) if (std.meta.stringToEnum(wg.Scenario, names.items[0])) |sc| {
        // A `warp` rung scenario, `refill_credits` the one that enters the
        // ending, written to run by hand (1.0 Step 27a: any of them).
        var lua: std.Io.Writer.Allocating = .init(a);
        try wg.writeScenarioLua(a, rom, sorted, try warp.loadWalked(a, rom), sc, &lua.writer);
        const base = try std.fmt.allocPrint(a, "build-out/{s}", .{@tagName(sc)});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.sfc", .{base}), .data = dbg.bytes });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.lua", .{base}), .data = lua.written() });
        try out.print("wrote {s}.sfc and .lua\n", .{base});
        return;
    };
    const vs = credits.variants;
    const fs = credits_grade.faults;
    var need: [vs.len]bool = @splat(false);
    for (vs, 0..) |v, i| need[i] = wanted(names.items, v.name);
    for (fs) |f| if (wanted(names.items, f.label)) {
        need[f.variant] = true;
    };

    var gm = try room.bootIntoPlay(a, rom);
    const snap = try gm.snapshot();
    var luas: [vs.len][]const u8 = @splat("");
    for (vs, 0..) |v, i| {
        if (!need[i]) continue;
        gm.restore(snap);
        const r = try credits.reference(a, &gm, v, &credits_grade.sample_passes);
        try out.print("reference {s}: fade {d}, scroll done {d}, hold {d}, reset {d}; states", .{ v.name, r.fade.len, r.done, r.hold, r.reset });
        for (r.states, 0..) |st, k| if (st) |x| try out.print(" {X:0>2}@{d}", .{ k, x });
        try out.print("\n", .{});
        try out.flush();
        var lua: std.Io.Writer.Allocating = .init(a);
        try credits_grade.writeLua(a, rom, sorted, mets, v, r, &lua.writer);
        luas[i] = lua.written();
    }

    const Job = struct { name: []const u8, rom: []const u8, lua: []const u8, want: u8 };
    var jobs: std.ArrayList(Job) = .empty;
    for (vs, 0..) |v, i| if (wanted(names.items, v.name)) try jobs.append(a, .{ .name = v.name, .rom = dbg.bytes, .lua = luas[i], .want = 0 });
    for (fs) |f| if (wanted(names.items, f.label)) {
        const fb = try a.dupe(u8, dbg.bytes);
        const o = snes_inject.symbolOffset(f.label) orelse return error.NoFaultLabel;
        @memcpy(fb[o..][0..f.patch.len], f.patch);
        try jobs.append(a, .{ .name = f.label, .rom = fb, .lua = luas[f.variant], .want = f.want });
    };

    if (build_options.mesen_path.len == 0) {
        try out.print("credits: no emulator (set MESEN); the carts and scripts are not written\n", .{});
        return;
    }
    const children = try a.alloc(std.process.Child, jobs.items.len);
    for (jobs.items, children, 0..) |j, *c, i| {
        const rom_file = try std.fmt.allocPrint(a, "build-out/credits-{d}.sfc", .{i});
        const lua_file = try std.fmt.allocPrint(a, "build-out/credits-{d}.lua", .{i});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_file, .data = j.rom });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lua_file, .data = j.lua });
        c.* = try std.process.spawn(io, .{
            .argv = &.{ build_options.mesen_path, rom_file, "--testrunner", lua_file, "--timeout=180" },
            .stdout = .pipe,
            .stderr = .ignore,
        });
    }
    var bad: usize = 0;
    for (jobs.items, children) |j, *c| {
        var buf: [256]u8 = undefined;
        var rdr = c.stdout.?.readerStreaming(io, &buf);
        const text = rdr.interface.allocRemaining(a, .limited(64 * 1024)) catch "";
        const term = try c.wait(io);
        const code: u8 = if (term == .exited) @truncate(term.exited) else 255;
        const ok = code == j.want;
        if (!ok) bad += 1;
        try out.print("{s} {s}: exit {d}, wanted {d} ({s})\n", .{ if (ok) "ok  " else "FAIL", j.name, code, j.want, credits_grade.code(code) });
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (lines.next()) |l| if (l.len > 0) try out.print("      {s}\n", .{l});
        try out.flush();
    }
    if (bad > 0) std.process.exit(1);
}
