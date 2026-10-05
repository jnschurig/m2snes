//! `zig build romtest` - generate the Mesen2 test for the finished cart.
//!
//! The expected picture is baked in rather than recomputed on the emulator
//! side: the Lua carries the 160x144 the reference renderer produces for the
//! boot screen, and the script compares it against what the PPU actually put on
//! the screen. `snes_render.bootWindow` is the single source for both this and
//! the PNG written beside the ROM, so the image a person holds up against the
//! television and the image the gate diffs are the same image.
//!
//! Mesen2 swallows `emu.log` in testrunner mode and sandboxes lua's `io`, so the
//! exit code is the verdict. The codes are documented in the generated script
//! and read back by `verify.zig`. Lua's `print` does reach stdout, which the
//! scenario scripts (1.0 Step 3) use for the line a failure prints.

const std = @import("std");
const build_options = @import("build_options");
const convert = @import("snes_convert.zig");
const romtest = @import("snes_romtest.zig");
const screen = @import("snes_screen.zig");
const target = @import("snes_target.zig");
const screens = @import("screens.zig");
const inject = @import("snes_inject.zig");
const scenario = @import("scenario.zig");
const gfx_grade = @import("gfx_grade.zig");
const warp = @import("warp.zig");
const warp_grade = @import("warp_grade.zig");
const save_grade = @import("save_grade.zig");
const debug_tables = @import("debug_tables.zig");

const out_dir = "build-out";
const lua_name = out_dir ++ "/m2snes.lua";
const cold_name = out_dir ++ "/m2snes-cold.lua";
/// The cart `snes boot` actually runs, which is **not** the one `zig build rom`
/// writes: that one ships the game's own new game and this one boots on the
/// record `chooseBoot` invents so the gate has somewhere to stand. Written
/// beside the script from Step 12b onwards, because until then the only way to
/// run a phase by hand was to run the whole gate -- three minutes an iteration
/// -- and pairing `m2snes.sfc` with `m2snes.lua` silently grades the wrong cart.
const graded_name = out_dir ++ "/m2snes-graded.sfc";

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse build_options.rom_path;
    if (path.len == 0) {
        try out.print("skip  no ROM configured; set M2_ROM or pass a path\n", .{});
        try out.flush();
        return;
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(1 << 20));
    var set = try convert.run(gpa, bytes);
    defer set.deinit();
    const boot = try screen.chooseBoot(gpa, bytes);
    var diag: inject.Diagnosis = .{};

    var lua: std.Io.Writer.Allocating = .init(gpa);
    defer lua.deinit();
    try romtest.write(gpa, bytes, set, boot, &lua.writer);

    // And the cold boot, which is a different cart: `builder.build` ships the
    // game's own new game and this script is the one that grades it, so the
    // boot it is generated against has to be the same one.
    const cold_boot = try screen.newGameBoot(gpa, bytes);
    var cold: std.Io.Writer.Allocating = .init(gpa);
    defer cold.deinit();
    try romtest.writeColdBoot(gpa, bytes, cold_boot, &cold.writer);
    // And the load (Step 15b), against the same shipped cart.
    var load: std.Io.Writer.Allocating = .init(gpa);
    defer load.deinit();
    try romtest.writeLoadBoot(gpa, bytes, cold_boot, .load, &load.writer);
    // And the death (Step 15c), against the same shipped cart.
    var death: std.Io.Writer.Allocating = .init(gpa);
    defer death.deinit();
    try romtest.writeDeathBoot(gpa, bytes, cold_boot, .grade, &death.writer);
    // And the title's file select (Step 24h), against the same shipped cart.
    var title: std.Io.Writer.Allocating = .init(gpa);
    defer title.deinit();
    try romtest.writeTitle(gpa, bytes, cold_boot, .grade, &title.writer);
    // And the pause (1.0 Step 2a), against the same shipped cart.
    var pause: std.Io.Writer.Allocating = .init(gpa);
    defer pause.deinit();
    try romtest.writePause(gpa, bytes, .grade, &pause.writer);
    // And the debug menu's chord (1.0 Step 2d): on the retail cart, and on
    // the `--debug` one (`zig build rom -- --debug`).
    var pause_combo: std.Io.Writer.Allocating = .init(gpa);
    defer pause_combo.deinit();
    try romtest.writePause(gpa, bytes, .combo, &pause_combo.writer);
    var pause_debug: std.Io.Writer.Allocating = .init(gpa);
    defer pause_debug.deinit();
    try romtest.writePause(gpa, bytes, .debug_combo, &pause_debug.writer);
    // And the round trip in slot 2 (Step 24i), against the same shipped cart,
    // which it needs built: the station's table is found in its blobs.
    var shipped = try inject.build(gpa, set, cold_boot, &diag);
    defer shipped.deinit();
    var trip: std.Io.Writer.Allocating = .init(gpa);
    defer trip.deinit();
    try romtest.writeRoundTrip(gpa, bytes, shipped, cold_boot, .slot2, &trip.writer);

    var graded = try inject.build(gpa, set, boot, &diag);
    defer graded.deinit();

    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, out_dir, .{});
    defer dir.close(init.io);
    try dir.writeFile(init.io, .{ .sub_path = "m2snes.lua", .data = lua.written() });
    try dir.writeFile(init.io, .{ .sub_path = "m2snes-cold.lua", .data = cold.written() });
    try dir.writeFile(init.io, .{ .sub_path = "m2snes-load.lua", .data = load.written() });
    try dir.writeFile(init.io, .{ .sub_path = "m2snes-death.lua", .data = death.written() });
    try dir.writeFile(init.io, .{ .sub_path = "m2snes-title.lua", .data = title.written() });
    try dir.writeFile(init.io, .{ .sub_path = "m2snes-trip2.lua", .data = trip.written() });
    try dir.writeFile(init.io, .{ .sub_path = "m2snes-pause.lua", .data = pause.written() });
    try dir.writeFile(init.io, .{ .sub_path = "m2snes-pause-combo.lua", .data = pause_combo.written() });
    try dir.writeFile(init.io, .{ .sub_path = "m2snes-pause-debug.lua", .data = pause_debug.written() });
    try dir.writeFile(init.io, .{ .sub_path = "m2snes-graded.sfc", .data = graded.bytes });
    // And the scenarios (1.0 Step 3), for the `--debug` cart.
    for (scenario.scenarios) |sc| {
        var sl: std.Io.Writer.Allocating = .init(gpa);
        defer sl.deinit();
        try scenario.writeLua(gpa, bytes, sc, &sl.writer);
        const name = try std.fmt.allocPrint(gpa, "m2snes-scenario-{s}.lua", .{sc.name});
        try dir.writeFile(init.io, .{ .sub_path = name, .data = sl.written() });
    }

    // And the WARP page's grade (1.0 Step 5c), for the `--debug` cart.
    {
        const built = try warp.build(gpa, bytes, try warp.loadWalked(gpa, bytes));
        const sorted = try debug_tables.warpOrder(gpa, bytes, built.entries);
        const refs = try warp_grade.references(gpa, bytes, sorted, warp_grade.shard_count, false);
        for (0..warp_grade.shard_count) |k| {
            var wl: std.Io.Writer.Allocating = .init(gpa);
            defer wl.deinit();
            try warp_grade.writeLua(gpa, bytes, sorted, refs, k, warp_grade.shard_count, &wl.writer);
            const name = try std.fmt.allocPrint(gpa, "m2snes-warp-{d}.lua", .{k});
            try dir.writeFile(init.io, .{ .sub_path = name, .data = wl.written() });
        }
        const walked = try warp.loadWalked(gpa, bytes);
        for (std.enums.values(warp_grade.Scenario)) |sc| {
            var wl: std.Io.Writer.Allocating = .init(gpa);
            defer wl.deinit();
            try warp_grade.writeScenarioLua(gpa, bytes, sorted, walked, sc, &wl.writer);
            const name = try std.fmt.allocPrint(gpa, "m2snes-warp-{s}.lua", .{@tagName(sc)});
            try dir.writeFile(init.io, .{ .sub_path = name, .data = wl.written() });
        }
        try out.print("wrote {s}/m2snes-warp-*.lua: {d} warps in {d} runs, each against the Game Boy's chain, and the item, Metroid and gated-door scenarios, for m2snes-debug.sfc\n", .{ out_dir, sorted.len, warp_grade.shard_count });

        // And the `saves` rung (1.0 Step 18e): a round trip at each station.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const st = try save_grade.stations(a, sorted);
        const at_st = try a.alloc(warp.Entry, st.len);
        for (st, at_st) |i, *e| e.* = sorted[i];
        const srefs = try warp_grade.references(a, bytes, at_st, st.len, false);
        for (st, srefs) |i, ref| {
            var sl: std.Io.Writer.Allocating = .init(a);
            try save_grade.writeLua(a, bytes, sorted, i, ref, &sl.writer);
            const at = sorted[i].dest.at;
            const name = try std.fmt.allocPrint(a, "m2snes-saves-{X}{X:0>2}.lua", .{ at.bank, at.cell });
            try dir.writeFile(init.io, .{ .sub_path = name, .data = sl.written() });
        }
        try out.print("wrote {s}/m2snes-saves-*.lua: a save round trip at each of {d} stations, for m2snes-debug.sfc\n", .{ out_dir, st.len });
    }

    // And the `doors` rung (1.0 Step 18a): each run its own case cart.
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const de = try warp.doorEntries(a, bytes, try warp.loadWalked(a, bytes));
        const n = warp_grade.doorShards(de.entries.len);
        const refs = try warp_grade.references(a, bytes, de.entries, n, false);
        for (0..n) |k| {
            const lo, const hi = warp_grade.shardRangeOf(de.entries.len, k, n);
            const cart = try warp_grade.doorCart(a, bytes, set, cold_boot, de.entries[lo..hi]);
            var dl: std.Io.Writer.Allocating = .init(a);
            try warp_grade.writeLua(a, bytes, de.entries[lo..hi], refs[lo..hi], 0, 1, &dl.writer);
            try dir.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(a, "m2snes-doors-{d}.lua", .{k}), .data = dl.written() });
            try dir.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(a, "m2snes-doors-{d}.sfc", .{k}), .data = cart.bytes });
        }
        var walked_n: usize = 0;
        var stood: usize = 0;
        for (de.entries) |e| {
            walked_n += @intFromBool(e.basis != .inferred);
            stood += @intFromBool(e.stand);
        }
        try out.print("wrote {s}/m2snes-doors-*.sfc and .lua: {d} door scripts in {d} case carts, {d} walked and {d} into their own WARP, {d} stood ({d} undecodable, {d} the Queen's, {d} with nowhere to go, {d} unchained)\n", .{ out_dir, de.entries.len, n, walked_n, de.entries.len - walked_n, stood, de.undecodable, de.queen, de.nowhere, de.unchained.len });

        // And the `counts` rung (1.0 Step 18d): the same at the counts they test.
        const ce = try warp.countedEntries(a, bytes, de.entries);
        const cn = warp_grade.doorShards(ce.len);
        const crefs = try warp_grade.references(a, bytes, ce, cn, true);
        for (0..cn) |k| {
            const lo, const hi = warp_grade.shardRangeOf(ce.len, k, cn);
            const cart = try warp_grade.doorCart(a, bytes, set, cold_boot, ce[lo..hi]);
            var cl: std.Io.Writer.Allocating = .init(a);
            try warp_grade.writeLua(a, bytes, ce[lo..hi], crefs[lo..hi], 0, 1, &cl.writer);
            try dir.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(a, "m2snes-counts-{d}.lua", .{k}), .data = cl.written() });
            try dir.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(a, "m2snes-counts-{d}.sfc", .{k}), .data = cart.bytes });
        }
        try out.print("wrote {s}/m2snes-counts-*.sfc and .lua: {d} door entries at the counts they test, in {d} case carts\n", .{ out_dir, ce.len, cn });
    }

    // And the `gfx` rung (1.0 Step 8a), for the `--debug` cart.
    {
        const refs = try gfx_grade.references(gpa, bytes);
        for (gfx_grade.cases, refs) |c, r| {
            var gl: std.Io.Writer.Allocating = .init(gpa);
            defer gl.deinit();
            try gfx_grade.writeLua(bytes, c, r, &gl.writer);
            const name = try std.fmt.allocPrint(gpa, "m2snes-gfx-{s}.lua", .{c.name});
            for (name) |*ch| if (ch.* == ' ') {
                ch.* = '-';
            };
            try dir.writeFile(init.io, .{ .sub_path = name, .data = gl.written() });
        }
        try out.print("wrote {s}/m2snes-gfx-*.lua: {d} pickups against our Game Boy's, for m2snes-debug.sfc\n", .{ out_dir, gfx_grade.cases.len });
    }

    try out.print("wrote {s}: two {d}x{d} reference screens, {d}x{d} window, map {d} cell ${X:0>2}\n", .{
        lua_name, screens.screen_px, screens.screen_px,
        target.view_w, target.view_h, boot.map_index, boot.cell,
    });
    try out.print("wrote {s}: map {d} cell ${X:0>2}, pose ${X:0>2} for {d} frames, no lever pulled\n", .{
        cold_name, cold_boot.map_index, cold_boot.cell, cold_boot.pose, cold_boot.countdown,
    });
    try out.print("wrote {s}/m2snes-load.lua: slot 0 holds the recording's first save; Start loads it\n", .{out_dir});
    try out.print("wrote {s}/m2snes-death.lua: two deaths, left on the timer and on Start\n", .{out_dir});
    try out.print("wrote {s}/m2snes-title.lua: the file select, against the Game Boy's\n", .{out_dir});
    try out.print("wrote {s}/m2snes-pause.lua: the pause, against the Game Boy's\n", .{out_dir});
    try out.print("wrote {s}/m2snes-pause-combo.lua and -debug.lua: the debug menu's chord in play, for m2snes.sfc and m2snes-debug.sfc\n", .{out_dir});
    try out.print("wrote {s}/m2snes-scenario-*.lua: {d} scenarios set up through the debug menu, for m2snes-debug.sfc\n", .{ out_dir, scenario.scenarios.len });
    try out.print("wrote {s}: the cart `snes boot` runs, which is not the shipped one\n", .{graded_name});
    try out.flush();
}

