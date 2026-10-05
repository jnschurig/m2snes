//! `zig build roster` -- 1.0's backlog read out of the ROM, as markdown.
//! `docs/phase1.md` quotes it; see `roster.zig` for where each list comes from.

const std = @import("std");
const build_options = @import("build_options");
const rom_mod = @import("rom.zig");
const roster = @import("roster.zig");
const map = @import("map.zig");
const screens = @import("screens.zig");
const warp = @import("warp.zig");
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
        try out.print("roster: no ROM configured (set M2_ROM); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(init.io, build_options.rom_path, gpa, .limited(rom_mod.expected_size * 4));

    var area: [32]u8 = undefined;

    // `zig build roster -- ai 59C7`: every record of one AI, and whether its
    // cell has a tileset the static reading settles -- which is what the enemy
    // oracle's `bootFor` needs to seed a case there (1.0 Step 11).
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const sub_arg = args.next();
    // `zig build roster -- tilesets`: every cell of every room a walked door
    // enters, the table the arrival loaded against `screens.assign`'s (18c).
    if (sub_arg) |sub| if (std.mem.eql(u8, sub, "tilesets")) {
        try tilesets(gpa, rom, out);
        return;
    };
    if (sub_arg) |sub| if (std.mem.eql(u8, sub, "ai")) {
        const want = try std.fmt.parseInt(u16, args.next() orelse "0", 16);
        var asg = try screens.assign(gpa, rom);
        defer asg.deinit(gpa);
        const recs = try roster.allRecords(gpa, rom);
        var wd = try roster.world(gpa, rom);
        defer wd.deinit(gpa);
        const ds = try roster.destinations(gpa, rom, wd);
        for (recs) |r| {
            if (r.ai != want) continue;
            var boots = false;
            for (asg.cells) |c| {
                if (c.bank != r.bank or @as(u8, c.y) * @as(u8, @intCast(map.grid_w)) + c.x != r.cell) continue;
                boots = c.choice != null;
            }
            try out.print("${X}:${X:0>2} #{X:0>2} sprite ${X:0>2} at {X:0>2},{X:0>2}  {s}  {s}\n", .{ r.bank, r.cell, r.number, r.sprite, r.x, r.y, if (boots) "boots" else "no boot", roster.areaName(&area, r.bank, r.cell) });
            // The warp-page destination fewest doors away from this record's
            // room, walking forwards through doors: where a playtest starts.
            const goal = wd.roomOf(.{ .bank = r.bank, .cell = r.cell });
            var best: ?usize = null;
            var best_hops: usize = std.math.maxInt(usize);
            for (ds, 0..) |d, di| {
                const hops = doorHops(wd, wd.roomOf(d.at), goal) orelse continue;
                if (hops < best_hops) {
                    best_hops = hops;
                    best = di;
                }
            }
            if (best) |bi| {
                const d = ds[bi];
                try out.print("  nearest warp: {s} ${X}:${X:0>2}, {d} door(s) on\n", .{ @tagName(d.kind), d.at.bank, d.at.cell, best_hops });
                // One door on: which one, as a cell and a direction.
                if (best_hops == 1) for (wd.edges) |e| {
                    if (wd.roomOf(e.from) != wd.roomOf(d.at) or wd.roomOf(e.dest.to) != goal) continue;
                    try out.print("    through the {s} edge of ${X}:${X:0>2}\n", .{ @tagName(e.dir), e.from.bank, e.from.cell });
                };
            } else try out.print("  no warp destination reaches it through doors\n", .{});
        }
        return;
    };

    // The census.
    const cen = try roster.census(gpa, rom);
    try out.print("## AI census\n\n| AI | name | records | banks | first record |\n|---|---|---|---|---|\n", .{});
    for (cen) |c| {
        try out.print("| 02:${X:0>4} | `{s}` | {d} | ", .{ c.ai, roster.nameOf(c.ai), c.records });
        for (0..map.bank_count) |i| if (c.banks & (@as(u8, 1) << @intCast(i)) != 0) try out.print("{X}", .{map.first_bank + i});
        try out.print(" | ${X}:${X:0>2} #{X:0>2} |\n", .{ c.first.bank, c.first.cell, c.first.number });
    }
    try out.print("\nChildren (no header names them; ported with the parent):\n\n", .{});
    for (roster.children) |c| try out.print("- 02:${X:0>4} `{s}`, from `{s}` (02:${X:0>4})\n", .{ c.ai, c.name, roster.nameOf(c.parent), c.parent });

    // The roster.
    const mets = try roster.metroids(gpa, rom);
    try out.print("\n## Metroid roster ({d} + the Queen)\n\n*menu* is the debug menu's number, the 100% recording's kill order (`debug_tables.playthrough`).\n\n| # | species | cell | spawn number | area | menu |\n|---|---|---|---|---|---|\n", .{mets.len});
    for (mets, 1..) |m, i| {
        const menu = for (debug_tables.playthrough, 1..) |k, j| {
            if (k.bank == m.bank and k.number == m.number) break j;
        } else 0;
        try out.print("| {d} | {s} | ${X}:${X:0>2} | ${X:0>2} | {s} | {d} |\n", .{ i, roster.speciesOf(m.ai).?, m.bank, m.cell, m.number, roster.areaName(&area, m.bank, m.cell), menu });
    }

    // Destinations.
    var w = try roster.world(gpa, rom);
    const dests = try roster.destinations(gpa, rom, w);
    try out.print("\n## Warp destinations\n\n| kind | cell | area | door | what |\n|---|---|---|---|---|\n", .{});
    for (dests) |d| {
        try out.print("| {s} | ${X}:${X:0>2} | {s} | ", .{ @tagName(d.kind), d.at.bank, d.at.cell, roster.areaName(&area, d.at.bank, d.at.cell) });
        if (d.door) |x| try out.print("${X:0>3}", .{x});
        try out.print(" | ", .{});
        if (d.choice) |c| try out.print("{s}, {s}", .{ screens.tiletable_order[c.tiletable], @tagName(c.provenance) });
        if (d.item) |it| try out.print("{s}", .{@tagName(it)});
        if (d.metroid) |m| try out.print("{s} ${X}:${X:0>2}", .{ roster.speciesOf(m.ai).?, m.bank, m.cell });
        try out.print(" |\n", .{});
    }
    var missing: usize = 0;
    for (mets) |m| {
        if (roster.entryInto(w, w.roomOf(.{ .bank = m.bank, .cell = m.cell }), false) == null) {
            try out.print("\nno door enters the room of the Metroid at ${X}:${X:0>2}\n", .{ m.bank, m.cell });
            missing += 1;
        }
    }
    try out.print("\n{d} rooms, {d} door edges; {d} Metroid rooms with no door in\n", .{ countRooms(w), w.edges.len, missing });
    w.deinit(gpa);

    // Door coverage.
    const cov = try roster.coverage(gpa, rom);
    try out.print("\n## Door-script coverage ({d} scripts decode, {d} do not)\n\n| op | scripts | first | port |\n|---|---|---|---|\n", .{ cov.decoded, cov.undecodable });
    for (cov.uses) |u| {
        try out.print("| `{s}` | {d} | ", .{ @tagName(u.tag), u.scripts });
        if (u.first) |f| try out.print("${X:0>3}", .{f});
        try out.print(" | {s} |\n", .{@tagName(roster.handling(u.tag))});
    }

    // The warp table (Step 5a).
    const walked = try warp.loadWalked(gpa, rom);
    const built = try warp.build(gpa, rom, walked);
    var by: [4]usize = @splat(0);
    for (built.entries) |e| by[@intFromEnum(e.basis)] += 1;
    try out.print("\n## Warp table ({d} doors walked; {d} entries: {d} walked, {d} walked from a seeded room, {d} inferred, {d} held to the recording; {d} findings)\n\n| kind | cell | basis | chain | table | Samus | camera | static reading |\n|---|---|---|---|---|---|---|---|\n", .{ walked.len, built.entries.len, by[0], by[1], by[2], by[3], built.findings.len });
    var cbuf: [8]u8 = undefined;
    for (built.entries) |e| {
        try out.print("| {s} | ${X}:${X:0>2} | {s} | ${X:0>3}", .{ @tagName(e.dest.kind), e.dest.at.bank, e.dest.at.cell, @tagName(e.basis), e.chain[0] });
        if (e.n > 1) try out.print(", ${X:0>3}", .{e.chain[1]});
        try out.print(" | `{s}`{s} | ${X:0>4},${X:0>4} | ${X:0>4},${X:0>4} | {s} |\n", .{ screens.tiletable_order[e.tileset.tiletable]["metatiles_".len..], if (e.count != warp.start_count) try std.fmt.bufPrint(&cbuf, " at ${X:0>2}", .{e.count}) else "", e.samus_y, e.samus_x, e.cam_y, e.cam_x, if (e.disagrees) "differs" else "" });
    }
    try out.print("\nFindings:\n\n", .{});
    for (built.findings) |f| {
        try out.print("- {s} ${X}:${X:0>2}: {s}", .{ @tagName(f.dest.kind), f.dest.at.bank, f.dest.at.cell, f.why });
        if (f.basis) |b| try out.print(" (its tileset {s}: `{s}`)", .{ switch (b) {
            .walked => "walked",
            .seeded => "walked from a seeded room",
            .inferred => "inferred",
            .recorded => "held to the recording",
        }, screens.tiletable_order[f.tileset.?.tiletable]["metatiles_".len..] });
        try out.print("\n", .{});
    }
}

fn countRooms(w: roster.World) usize {
    var top: usize = 0;
    for (w.room) |bank| for (bank) |r| {
        if (r != roster.World.none) top = @max(top, @as(usize, r) + 1);
    };
    return top;
}

/// Doors crossed from room `from` to room `to`, breadth first over the door
/// graph; null if no path.
fn doorHops(w: roster.World, from: u16, to: u16) ?usize {
    if (from == roster.World.none or to == roster.World.none) return null;
    if (from == to) return 0;
    var seen = std.AutoHashMap(u16, void).init(std.heap.page_allocator);
    defer seen.deinit();
    var frontier: [4096]u16 = undefined;
    var next: [4096]u16 = undefined;
    var n: usize = 1;
    frontier[0] = from;
    seen.put(from, {}) catch return null;
    var hops: usize = 0;
    while (n != 0 and hops < 64) {
        hops += 1;
        var m: usize = 0;
        for (frontier[0..n]) |r| {
            for (w.edges) |e| {
                if (w.roomOf(e.from) != r) continue;
                const t = w.roomOf(e.dest.to);
                if (t == roster.World.none or seen.contains(t)) continue;
                if (t == to) return hops;
                seen.put(t, {}) catch return null;
                if (m < next.len) {
                    next[m] = t;
                    m += 1;
                }
            }
        }
        @memcpy(frontier[0..m], next[0..m]);
        n = m;
    }
    return null;
}

/// 1.0 Step 18c: `screens.assign` against the crawl's arrivals laid over it.
fn tilesets(gpa: std.mem.Allocator, rom: []const u8, out: *std.Io.Writer) !void {
    var st = try screens.assign(gpa, rom);
    defer st.deinit(gpa);
    const walked = try warp.loadWalked(gpa, rom);
    var wa = try warp.assignWalked(gpa, rom, walked);
    defer wa.deinit(gpa);

    try out.print("| provenance | static | walked |\n|---|---|---|\n", .{});
    for (std.enums.values(screens.Provenance)) |p| try out.print("| {s} | {d} | {d} |\n", .{ @tagName(p), st.by_provenance[@intFromEnum(p)], wa.by_provenance[@intFromEnum(p)] });

    var moved: [map.bank_count]usize = @splat(0);
    for (st.cells, wa.cells) |a, b| {
        const ca = a.choice orelse continue;
        const cb = b.choice orelse continue;
        if (ca.tiletable != cb.tiletable) moved[a.bank - map.first_bank] += 1;
    }
    try out.print("\ncells whose table the walk changes, by bank:", .{});
    for (moved, 0..) |n, i| try out.print(" ${X}:{d}", .{ map.first_bank + i, n });
    try out.print("\n", .{});

    // The bank $9/$A veto, against the walked cells.
    {
        var nv = try screens.assignWith(gpa, rom, .{ .veto = false });
        defer nv.deinit(gpa);
        for ([_]u8{ 0x9, 0xA }) |bank| {
            var agree: [2]usize = .{ 0, 0 };
            var n: usize = 0;
            for (wa.cells, st.cells, nv.cells) |c, a, b| {
                if (c.bank != bank) continue;
                const ch = c.choice orelse continue;
                if (ch.provenance != .walked) continue;
                n += 1;
                if (a.choice.?.tiletable == ch.tiletable and std.mem.eql(u8, a.choice.?.bg_gfx orelse "", ch.bg_gfx orelse "")) agree[0] += 1;
                if (b.choice.?.tiletable == ch.tiletable and std.mem.eql(u8, b.choice.?.bg_gfx orelse "", ch.bg_gfx orelse "")) agree[1] += 1;
            }
            try out.print("bank ${X}: of {d} walked cells, vetoed agrees on {d}, unvetoed on {d}\n", .{ bank, n, agree[0], agree[1] });
        }
    }
    var walked_by: [map.bank_count]usize = @splat(0);
    for (wa.cells) |c| if (c.choice) |ch| if (ch.provenance == .walked) {
        walked_by[c.bank - map.first_bank] += 1;
    };
    try out.print("walked cells by bank:", .{});
    for (walked_by, 0..) |n, i| try out.print(" ${X}:{d}", .{ map.first_bank + i, n });
    try out.print("\n", .{});
}
