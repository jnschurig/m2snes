//! `zig build queen -- [frames] [every]` -- the Queen's room on the Game Boy:
//! each sampled frame's variables and the bands its registers latched in.
//! `docs/phase1.md` (Step 6) quotes it; see `queen.zig`.

const std = @import("std");
const build_options = @import("build_options");
const rom_mod = @import("rom.zig");
const queen = @import("queen.zig");
const snes_convert = @import("snes_convert.zig");
const snes_screen = @import("snes_screen.zig");
const snes_inject = @import("snes_inject.zig");
const warp = @import("warp.zig");
const warp_grade = @import("warp_grade.zig");
const debug_tables = @import("debug_tables.zig");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (build_options.rom_path.len == 0) {
        try out.print("queen: no ROM configured (set M2_ROM); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(init.io, build_options.rom_path, gpa, .limited(rom_mod.expected_size * 4));

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const first = args.next();
    if (first) |f| if (std.mem.eql(u8, f, "scenario")) {
        // The `queen` warp scenario, to run by hand: `Mesen build-out/queen.sfc
        // --testrunner build-out/queen.lua --snes.disableFrameSkipping=true`.
        var set = try snes_convert.run(gpa, rom);
        const boot = try snes_screen.newGameBoot(gpa, rom);
        var diag: snes_inject.Diagnosis = .{};
        var dbg = try snes_inject.build(gpa, set, boot, &diag);
        _ = &set;
        try snes_inject.enableDebug(&dbg);
        const walked = try warp.loadWalked(gpa, rom);
        const built = try warp.build(gpa, rom, walked);
        const sorted = try debug_tables.warpOrder(gpa, rom, built.entries);
        var lua: std.Io.Writer.Allocating = .init(gpa);
        try warp_grade.writeScenarioLua(gpa, rom, sorted, walked, .queen, &lua.writer);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "build-out/queen.sfc", .data = dbg.bytes });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "build-out/queen.lua", .data = lua.written() });
        try out.print("wrote build-out/queen.sfc and build-out/queen.lua\n", .{});
        return;
    };
    if (first) |f| if (std.mem.eql(u8, f, "oracle")) {
        // The Queen oracle (1.0 Step 19a), to run by hand: `Mesen --testrunner
        // build-out/queen_fight.sfc build-out/queen_fight.lua
        // --snes.disableFrameSkipping=true`. `oracle <case> [fault label]`.
        const queen_oracle = @import("queen_oracle.zig");
        var set = try snes_convert.run(gpa, rom);
        const boot = try snes_screen.newGameBoot(gpa, rom);
        var diag: snes_inject.Diagnosis = .{};
        var dbg = try snes_inject.build(gpa, set, boot, &diag);
        _ = &set;
        try snes_inject.enableDebug(&dbg);
        const walked = try warp.loadWalked(gpa, rom);
        const built = try warp.build(gpa, rom, walked);
        const sorted = try debug_tables.warpOrder(gpa, rom, built.entries);
        const name = args.next() orelse "still";
        const case = for (queen_oracle.cases) |c| {
            if (std.mem.eql(u8, c.name, name)) break c;
        } else {
            try out.print("queen oracle: no case {s}\n", .{name});
            try out.flush();
            std.process.exit(1);
        };
        // A fault, by label, as the gate places it: `rts` over its first byte.
        if (args.next()) |label| {
            const o = snes_inject.symbolOffset(label) orelse {
                try out.print("queen oracle: no symbol {s}\n", .{label});
                try out.flush();
                std.process.exit(1);
            };
            dbg.bytes[o] = 0x60;
        }
        const gb = try queen_oracle.runGbCase(gpa, rom, case);
        var lua: std.Io.Writer.Allocating = .init(gpa);
        try queen_oracle.writeLua(gpa, rom, sorted, gb, case, &lua.writer);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "build-out/queen_fight.sfc", .data = dbg.bytes });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "build-out/queen_fight.lua", .data = lua.written() });
        try out.print("wrote build-out/queen_fight.sfc and build-out/queen_fight.lua ({s}): Samus dies on our Game Boy's frame {d}, frameCounter {d} on its first, {d} rDIV reads ({any}), {d} frames graded, {d} of them lagging\n", .{ case.name, gb.death, gb.counter, gb.divs.len, gb.divs, queen_oracle.windowOf(case, gb), queen_oracle.lagIn(case, gb) });
        return;
    };
    if (first) |f| if (std.mem.eql(u8, f, "probe")) {
        // A Queen oracle case on our Game Boy (1.0 Step 20a), for writing its
        // script: her state, the eating state, her mouth and head, Samus.
        // `queen -- probe <case> [from] [to]`, in the oracle's sampled frames.
        const queen_oracle = @import("queen_oracle.zig");
        const name = args.next() orelse "still";
        const case = for (queen_oracle.cases) |c| {
            if (std.mem.eql(u8, c.name, name)) break c;
        } else {
            try out.print("queen probe: no case {s}\n", .{name});
            try out.flush();
            std.process.exit(1);
        };
        const lo: usize = if (args.next()) |n| try std.fmt.parseInt(usize, n, 10) else 0;
        const hi: usize = if (args.next()) |n| try std.fmt.parseInt(usize, n, 10) else case.frames - 1;
        const cols = [_]struct { gb: u16, label: []const u8 }{
            .{ .gb = 0xC3C3, .label = "st" },   .{ .gb = 0xD090, .label = "eat" },  .{ .gb = 0xC623, .label = "mouth" },
            .{ .gb = 0xC3A8, .label = "hx" },   .{ .gb = 0xC3A9, .label = "hy" },   .{ .gb = 0xC3C1, .label = "neck" },
            .{ .gb = 0xC3D3, .label = "qhp" },  .{ .gb = 0xC3D0, .label = "stun" }, .{ .gb = 0xD020, .label = "pose" },
            .{ .gb = 0xD03B, .label = "oy" },   .{ .gb = 0xD03C, .label = "ox" },   .{ .gb = 0xD051, .label = "hp" },
            .{ .gb = 0xD052, .label = "tk" },   .{ .gb = 0xD063, .label = "dead" }, .{ .gb = 0xFF97, .label = "fc" },
            .{ .gb = 0xC3AD, .label = "l0" },   .{ .gb = 0xC3AF, .label = "l2" },   .{ .gb = 0xC3A0, .label = "by" },
            .{ .gb = 0xDD20, .label = "mt" },   .{ .gb = 0xDD21, .label = "md" },   .{ .gb = 0xDD22, .label = "my" },
            .{ .gb = 0xDD23, .label = "mx" },
            // 1.0 Step 20d: out of her room.
            .{ .gb = 0xFFC1, .label = "sy" },   .{ .gb = 0xFFC0, .label = "" },     .{ .gb = 0xFFC3, .label = "sx" },
            .{ .gb = 0xFFC2, .label = "" },     .{ .gb = 0xD08B, .label = "room" }, .{ .gb = 0xD058, .label = "bank" },
            .{ .gb = 0xD08E, .label = "door" }, .{ .gb = 0xCEDD, .label = "song" }, .{ .gb = 0xD083, .label = "quake" },
        };
        var addrs: [cols.len]u16 = undefined;
        for (&addrs, cols) |*d, c| d.* = c.gb;
        const rows = try queen_oracle.traceGb(gpa, rom, case, hi + 1, &addrs);
        for (rows[lo..], lo..) |row, fi| {
            try out.print("{d:>4}", .{fi});
            for (cols, row) |c, b| try out.print(" {s} {X:0>2}", .{ c.label, b });
            try out.print("\n", .{});
        }
        return;
    };
    if (first) |f| if (std.mem.eql(u8, f, "lag")) {
        // A case's presses against our Game Boy's lag (1.0 Step 20c): each
        // that begins on the frame after one it lags on, and those moved.
        const queen_oracle = @import("queen_oracle.zig");
        const name = args.next() orelse "kill";
        const case = for (queen_oracle.cases) |c| {
            if (std.mem.eql(u8, c.name, name)) break c;
        } else {
            try out.print("queen lag: no case {s}\n", .{name});
            try out.flush();
            std.process.exit(1);
        };
        const gb = try queen_oracle.runGbCase(gpa, rom, case);
        try out.print("{d} lag frames:", .{gb.lag.len});
        for (gb.lag) |l| try out.print(" {d}", .{l});
        try out.print("\npresses on or after one:", .{});
        for (queen_oracle.pressesOnLag(gb.script, gb.lag)) |h| try out.print(" {d}", .{h});
        try out.print("\nmoved:", .{});
        for (case.script, gb.script) |was, now| if (was.from != now.from) try out.print(" {d}->{d}", .{ was.from, now.from });
        try out.print("\n", .{});
        return;
    };
    if (first) |f| if (std.mem.eql(u8, f, "hurt")) {
        // The Queen oracle's `volley` on our Game Boy (1.0 Step 19c): each
        // frame's body palette and the bands' BGP, for choosing the frames
        // the oracle compares on the screen. `queen -- hurt [from] [to]`, in
        // the oracle's sampled frames.
        const queen_oracle = @import("queen_oracle.zig");
        const lo: usize = if (args.next()) |n| try std.fmt.parseInt(usize, n, 10) else 270;
        const hi: usize = if (args.next()) |n| try std.fmt.parseInt(usize, n, 10) else 290;
        const frames = try queen.measureScripted(gpa, rom, hi + 2, queen_oracle.volley);
        var buf: [ppu_height]queen.Band = undefined;
        for (lo..hi + 1) |s| {
            const fr = &frames[s + 1];
            try out.print("frame {d}: state ${X:0>2} pal ${X:0>2}{s}:", .{ s, fr.state, fr.body_palette, if (fr.complete) "" else " (partial)" });
            for (queen.bands(fr, &buf)) |b| try out.print(" {d}:{X:0>2}", .{ b.first, b.state.bgp });
            try out.print("\n", .{});
        }
        return;
    };
    const count: usize = if (first) |n| try std.fmt.parseInt(usize, n, 10) else 600;
    const every: usize = if (args.next()) |n| try std.fmt.parseInt(usize, n, 10) else 60;

    const frames = try queen.measure(gpa, rom, count);

    // How many lines after its LYC each command's effect lands, per kind, over
    // every frame: the list is the previous frame's (built in the vblank
    // before this frame was drawn).
    var hist: [5][4]usize = @splat(@splat(0));
    var missing: [5]usize = @splat(0);
    var lbuf: [4]queen.Landing = undefined;
    for (frames[1..], frames[0 .. frames.len - 1]) |*f, prev| {
        if (!f.complete or prev.room_flag != queen.room_flag_fight) continue;
        for (queen.landings(f, prev.list, prev.body_x_scroll, prev.scroll_x, &lbuf)) |l| {
            const k = @min(l.kind, 4);
            if (l.line) |y| {
                const d = y - l.lyc;
                if (d < 4) hist[k][d] += 1 else missing[k] += 1;
            } else missing[k] += 1;
        }
    }
    try out.print("latency (lines after LYC) by kind: +0 +1 +2 +3, not found\n", .{});
    for (1..5) |k| try out.print("  kind {d}: {d} {d} {d} {d}, {d}\n", .{ k, hist[k][0], hist[k][1], hist[k][2], hist[k][3], missing[k] });
    var buf: [ppu_height]queen.Band = undefined;
    for (frames, 0..) |*f, i| {
        if (i % every != 0) continue;
        try out.print("frame {d}: flag ${X:0>2} state ${X:0>2} body y ${X:0>2} h ${X:0>2} xscroll ${X:0>2} pal ${X:0>2} head x ${X:0>2} y ${X:0>2} bottom ${X:0>2} scroll ${X:0>2},${X:0>2} list", .{
            i, f.room_flag, f.state, f.body_y, f.body_height, f.body_x_scroll, f.body_palette, f.head_x, f.head_y, f.head_bottom_y, f.scroll_x, f.scroll_y,
        });
        for (f.list) |b| try out.print(" {X:0>2}", .{b});
        try out.print("{s}\n  samus {X:0>4},{X:0>4} pose {X:0>2} camera {X:0>4},{X:0>4}\n", .{ if (f.complete) "" else " (partial)", f.samus_y, f.samus_x, f.pose, f.cam_y, f.cam_x });
        for (0..8) |r| {
            try out.print("  win row {d}:", .{r});
            for (f.window_map[r * 32 ..][0..32]) |b| try out.print(" {X:0>2}", .{b});
            try out.print("\n", .{});
        }
        for (queen.bands(f, &buf)) |b| {
            const s = b.state;
            try out.print("  line {d:>3}: lcdc ${X:0>2} scy ${X:0>2} scx ${X:0>2} wy ${X:0>2} wx ${X:0>2} bgp ${X:0>2}\n", .{ b.first, s.lcdc, s.scy, s.scx, s.wy, s.wx, s.bgp });
        }
    }
}

const ppu_height = @import("gb/ppu.zig").height;
