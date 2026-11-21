//! `zig build areas` - draw each map bank with the colour areas over it.
//!
//! One PNG per bank, `build-out/areas/bank{X}.png`: the bank's 16x16 grid of
//! screens at half size, each tinted with its area's hue, every in-use cell
//! labelled with its index, room walls in white, cuts in red and seeds boxed
//! in magenta. They are for comparing against `metroid-2-areas.gif` by eye,
//! and they are made of the ROM, so they live in `build-out/` only.
//!
//! It also prints the fill's report: cells per area, and any clash, unreached
//! cell or unused cut, which are what to fix in `areas.zig`.

const std = @import("std");
const build_options = @import("build_options");
const png = @import("png");
const rom_mod = @import("rom.zig");
const map = @import("map.zig");
const roster = @import("roster.zig");
const screens = @import("screens.zig");
const areas = @import("areas.zig");
const warp = @import("warp.zig");

const out_dir = "build-out/areas";

const scale = 2;
const cell_px = screens.screen_px / scale;
const side = map.grid_w * cell_px;

// Palette: fixed entries, then four shades per area (unassigned first).
const ix_blank = 0;
const ix_grid = 1;
const ix_wall = 2;
const ix_label = 3;
const ix_cut = 4;
const ix_seed = 5;
const ix_nest = 6;
const ix_lava = 7;
const ix_tint = 8;

const hues = [_][3]u8{
    .{ 0x90, 0x90, 0x90 }, // unassigned
    .{ 0x40, 0xE0, 0x40 }, // surface
    .{ 0xF0, 0xA0, 0x30 }, // 1
    .{ 0xC0, 0x60, 0x30 }, // 2
    .{ 0x30, 0xC0, 0x60 }, // 3
    .{ 0xE0, 0x40, 0x40 }, // 4
    .{ 0xF0, 0x60, 0x20 }, // 5
    .{ 0x60, 0xE0, 0xA0 }, // 6
    .{ 0xE0, 0xC0, 0x40 }, // 7
    .{ 0xA0, 0x50, 0x20 }, // 8
    .{ 0xD0, 0xE0, 0x30 }, // 9
    .{ 0xFF, 0x30, 0x30 }, // 10
    .{ 0x50, 0x90, 0xFF }, // queen
};

comptime {
    std.debug.assert(hues.len == areas.Area.count + 1);
}

fn palette() [ix_tint + hues.len * 4][3]u8 {
    var pal: [ix_tint + hues.len * 4][3]u8 = @splat(.{ 0, 0, 0 });
    pal[ix_grid] = .{ 0x30, 0x30, 0x30 };
    pal[ix_wall] = .{ 0xFF, 0xFF, 0xFF };
    pal[ix_label] = .{ 0xFF, 0xFF, 0x00 };
    pal[ix_cut] = .{ 0xFF, 0x00, 0x00 };
    pal[ix_seed] = .{ 0xFF, 0x00, 0xFF };
    pal[ix_nest] = .{ 0x40, 0xFF, 0x40 };
    pal[ix_lava] = .{ 0xA0, 0x40, 0xFF };
    for (hues, 0..) |h, i| for (0..4) |s| {
        // Shade 0 is the lightest; 3 the darkest.
        const k: u16 = 256 - @as(u16, @intCast(s)) * 60;
        for (0..3) |c| pal[ix_tint + i * 4 + s][c] = @intCast(@as(u16, h[c]) * k / 256);
    };
    return pal;
}

const font = [16][5]u3{
    .{ 7, 5, 5, 5, 7 }, .{ 2, 6, 2, 2, 7 }, .{ 7, 1, 7, 4, 7 }, .{ 7, 1, 7, 1, 7 },
    .{ 5, 5, 7, 1, 1 }, .{ 7, 4, 7, 1, 7 }, .{ 7, 4, 7, 5, 7 }, .{ 7, 1, 1, 1, 1 },
    .{ 7, 5, 7, 5, 7 }, .{ 7, 5, 7, 1, 7 }, .{ 7, 5, 7, 5, 5 }, .{ 6, 5, 6, 5, 6 },
    .{ 7, 4, 4, 4, 7 }, .{ 6, 5, 5, 5, 6 }, .{ 7, 4, 7, 4, 7 }, .{ 7, 4, 7, 4, 4 },
};

const Canvas = struct {
    px: []u8,

    fn set(self: Canvas, x: usize, y: usize, v: u8) void {
        if (x < side and y < side) self.px[y * side + x] = v;
    }

    fn rect(self: Canvas, x0: usize, y0: usize, w: usize, h: usize, v: u8) void {
        for (y0..y0 + h) |y| for (x0..x0 + w) |x| self.set(x, y, v);
    }

    fn glyph(self: Canvas, x0: usize, y0: usize, d: u4) void {
        const k = 3;
        self.rect(x0, y0, 4 * k + 2, 6 * k + 2, ix_blank);
        for (font[d], 0..) |row, y| for (0..3) |x| {
            if (row & (@as(u3, 4) >> @intCast(x)) != 0) self.rect(x0 + 1 + x * k, y0 + 1 + y * k, k, k, ix_label);
        };
    }
};

const Shades = struct {
    /// Per bank, one shade (0-3) per half-size pixel, or 0xFF where no screen.
    banks: [map.bank_count][]u8,

    fn frame(ctx: *anyopaque, cell: screens.Cell, _: screens.Choice, pixels: []const u8) anyerror!void {
        const self: *Shades = @ptrCast(@alignCast(ctx));
        const b = self.banks[cell.bank - map.first_bank];
        for (0..cell_px) |y| for (0..cell_px) |x| {
            const s = pixels[(y * scale) * screens.screen_px + x * scale];
            b[(@as(usize, cell.y) * cell_px + y) * side + @as(usize, cell.x) * cell_px + x] = s;
        };
    }
};

/// The area whose gate the count is past, by the gates' `IF_MET_LESS`
/// thresholds (the real count, BCD, as the trace prints it). The real count
/// is the displayed one plus 8: `$46` is the GIF's "38 remaining". Areas 8
/// and 9 open together (`$12`); the run cleared 8 first, down to 10.
fn bucket(c: u8) areas.Area {
    if (c >= 47) return .surface;
    if (c >= 43) return .area1;
    if (c >= 35) return .area2;
    if (c >= 25) return .area3;
    if (c >= 24) return .area4;
    if (c >= 22) return .area5;
    if (c >= 15) return .area6;
    if (c >= 13) return .area7;
    if (c >= 11) return .area8;
    if (c >= 10) return .area9;
    if (c >= 1) return .area10;
    // Zero: after the Queen, on the way back to the ship.
    return .surface;
}

const recording_tsv = "build-out/worlds-metroid2-100p-recording.tsv";

/// Per cell, the highest Metroid count the 100% recording stood in it at:
/// the count when the run first reached it. From `verify-full`'s worlds
/// rung, which leaves `recording_tsv` behind.
const FirstVisit = struct {
    count: [map.bank_count][map.cells]u8 = @splat(@splat(0)),
    seen: [map.bank_count][map.cells]bool = @splat(@splat(false)),

    fn load(io: std.Io, gpa: std.mem.Allocator) !FirstVisit {
        const tsv = std.Io.Dir.cwd().readFileAlloc(io, recording_tsv, gpa, .limited(1 << 22)) catch |e| {
            std.debug.print("areas: {s}: {t}; `zig build verify-full` writes it\n", .{ recording_tsv, e });
            return e;
        };
        var v: FirstVisit = .{};
        var lines = std.mem.tokenizeScalar(u8, tsv, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            var cols = std.mem.tokenizeScalar(u8, line, '\t');
            _ = cols.next();
            _ = cols.next();
            const bank = try std.fmt.parseInt(u8, cols.next().?, 16);
            const cell = try std.fmt.parseInt(u8, cols.next().?, 16);
            const count = try std.fmt.parseInt(u8, cols.next().?, 10);
            if (bank < map.first_bank or bank > map.last_bank) continue;
            const bi = bank - map.first_bank;
            v.count[bi][cell] = @max(v.count[bi][cell], count);
            v.seen[bi][cell] = true;
        }
        return v;
    }
};

/// `zig build areas -- draft`: one seed line per room, for `areas.seeds`.
/// A room the run reached in one bucket takes it; a mixed room takes its
/// earliest and is flagged, and an unvisited one is left commented out.
fn draft(w: roster.World, v: FirstVisit, out: *std.Io.Writer) !void {
    var top: u16 = 0;
    for (w.room) |b| for (b) |r| if (r != roster.World.none) {
        top = @max(top, r + 1);
    };
    for (0..top) |r| {
        var first_cell: ?roster.Place = null;
        var best: ?roster.Place = null;
        var best_count: u8 = 0;
        var mixed = false;
        var bucket_seen: ?areas.Area = null;
        var cells: usize = 0;
        for (0..map.bank_count) |bi| for (0..map.cells) |ci| {
            if (w.room[bi][ci] != r) continue;
            const at: roster.Place = .{ .bank = map.first_bank + @as(u8, @intCast(bi)), .cell = @intCast(ci) };
            cells += 1;
            if (first_cell == null) first_cell = at;
            if (!v.seen[bi][ci]) continue;
            const c = v.count[bi][ci];
            if (bucket_seen) |bs| mixed = mixed or bs != bucket(c) else bucket_seen = bucket(c);
            if (best == null or c > best_count) {
                best = at;
                best_count = c;
            }
        };
        const at = best orelse first_cell.?;
        if (best == null) {
            try out.print("    // s(0x{X}, 0x{X:0>2}, .unvisited), // room {d}, {d} cells\n", .{ at.bank, at.cell, r, cells });
            continue;
        }
        const a = bucket(best_count);
        try out.print("    s(0x{X}, 0x{X:0>2}, .{s}), // room {d}, {d} cells, first at {d}{s}\n", .{
            at.bank, at.cell, @tagName(a), r, cells, best_count, if (mixed) "; MIXED" else "",
        });
        if (mixed) {
            try out.print("    //", .{});
            for (0..map.bank_count) |bi| for (0..map.cells) |ci| {
                if (w.room[bi][ci] != r or !v.seen[bi][ci]) continue;
                try out.print(" {X:0>2}={d}", .{ ci, v.count[bi][ci] });
            };
            try out.print("\n", .{});
        }
    }
}

/// `zig build areas -- acid`: per room, whether the cart's reading of its
/// tileset (`warp.assignWalked`) is a lava table, against the tables the
/// recording's Game Boy showed there at any count. The acid set keys on the
/// first, so the two must agree on which rooms are acid caves.
const Lava = struct {
    /// The cart's static reading (`warp.assignWalked`).
    cart: [map.bank_count][map.cells]bool = @splat(@splat(false)),
    /// What the recording's Game Boy showed, at any count; null where unseen.
    gb: [map.bank_count][map.cells]?bool = @splat(@splat(null)),

    fn load(io: std.Io, gpa: std.mem.Allocator, rom: []const u8) !Lava {
        var l: Lava = .{};
        const walked = try warp.loadWalked(gpa, rom);
        var asg = try warp.assignWalked(gpa, rom, walked);
        defer asg.deinit(gpa);
        for (asg.cells) |c| {
            const ch = c.choice orelse continue;
            l.cart[c.bank - map.first_bank][@as(usize, c.y) * map.grid_w + c.x] = warp.isLavaTable(ch.tiletable);
        }
        const tsv = std.Io.Dir.cwd().readFileAlloc(io, recording_tsv, gpa, .limited(1 << 22)) catch return l;
        var lines = std.mem.tokenizeScalar(u8, tsv, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            var cols = std.mem.tokenizeScalar(u8, line, '\t');
            _ = cols.next();
            _ = cols.next();
            const bank = try std.fmt.parseInt(u8, cols.next().?, 16);
            const cell = try std.fmt.parseInt(u8, cols.next().?, 16);
            _ = cols.next();
            _ = cols.next();
            const t = try std.fmt.parseInt(u8, cols.next().?, 10);
            if (bank < map.first_bank or bank > map.last_bank) continue;
            const g = &l.gb[bank - map.first_bank][cell];
            g.* = (g.* orelse false) or warp.isLavaTable(@intCast(t));
        }
        return l;
    }

    /// The recording where it saw the cell, the cart's reading elsewhere.
    fn best(self: Lava, bi: usize, ci: usize) bool {
        return self.gb[bi][ci] orelse self.cart[bi][ci];
    }
};

fn acidCheck(io: std.Io, gpa: std.mem.Allocator, rom: []const u8, w: roster.World, out: *std.Io.Writer) !void {
    const lava = try Lava.load(io, gpa, rom);
    const cart = lava.cart;
    const gb = lava.gb;
    var top: u16 = 0;
    for (w.room) |b| for (b) |r| if (r != roster.World.none) {
        top = @max(top, r + 1);
    };
    var acid_rooms: usize = 0;
    for (0..top) |r| {
        var any_cart = false;
        var all_cart = true;
        var any_gb = false;
        var seen_gb = false;
        var first: ?roster.Place = null;
        for (0..map.bank_count) |bi| for (0..map.cells) |ci| {
            if (w.room[bi][ci] != r) continue;
            if (first == null) first = .{ .bank = map.first_bank + @as(u8, @intCast(bi)), .cell = @intCast(ci) };
            any_cart = any_cart or cart[bi][ci];
            all_cart = all_cart and cart[bi][ci];
            if (gb[bi][ci]) |g| {
                seen_gb = true;
                any_gb = any_gb or g;
            }
        };
        if (any_cart) acid_rooms += 1;
        const disagree = (any_cart != all_cart) or (seen_gb and any_gb != any_cart);
        if (!any_cart and !any_gb) continue;
        try out.print("room {d:>3} ${X}:{X:0>2}  cart {s}  gb {s}{s}\n", .{
            r, first.?.bank, first.?.cell,
            if (all_cart) "lava" else if (any_cart) "part" else "-",
            if (!seen_gb) "unseen" else if (any_gb) "lava" else "-",
            if (disagree) "  DISAGREE" else "",
        });
    }
    try out.print("{d} acid rooms\n", .{acid_rooms});
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (build_options.rom_path.len == 0) {
        try out.print("areas: no ROM configured (set M2_ROM); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(init.io, build_options.rom_path, gpa, .limited(rom_mod.expected_size * 4));

    var w = try roster.world(gpa, rom);
    defer w.deinit(gpa);

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const sub: []const u8 = args.next() orelse "";

    if (std.mem.eql(u8, sub, "acid")) {
        try acidCheck(init.io, gpa, rom, w, out);
        return;
    }

    if (std.mem.eql(u8, sub, "draft")) {
        try draft(w, try FirstVisit.load(init.io, gpa), out);
        return;
    }

    const g = try areas.graphOf(gpa, w);
    var f = try areas.fill(gpa, g, &areas.seeds, &areas.cuts);
    // The nest bit, on a copy: `f.table` stays the plain areas for the tint.
    var marked = f.table;
    const ms = try roster.metroids(gpa, rom);
    areas.markNests(&marked, w.room, ms);
    const lava = try Lava.load(init.io, gpa, rom);
    defer f.deinit(gpa);

    // `zig build areas -- recording`: tint each cell by the bucket of the
    // count the recording first reached it at, instead of by area, to check
    // the seeds against.
    if (std.mem.eql(u8, sub, "recording")) {
        const v = try FirstVisit.load(init.io, gpa);
        for (&f.table, v.count, v.seen) |*fb, cb, sb| for (fb, cb, sb) |*o, c, seen| {
            o.* = if (!seen) areas.none else @intFromEnum(bucket(c));
        };
    }

    var shades: Shades = .{ .banks = undefined };
    for (&shades.banks) |*b| {
        b.* = try gpa.alloc(u8, side * side);
        @memset(b.*, 0xFF);
    }
    _ = try screens.renderAll(gpa, rom, screens.live_bgp, .{ .ctx = &shades, .frame = Shades.frame });

    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, out_dir, .{});
    defer dir.close(init.io);
    const pal = palette();

    for (0..map.bank_count) |bi| {
        const bank: u8 = map.first_bank + @as(u8, @intCast(bi));
        const cv: Canvas = .{ .px = try gpa.alloc(u8, side * side) };
        for (shades.banks[bi], cv.px, 0..) |s, *o, i| {
            const ci = (i / side / cell_px) * map.grid_w + (i % side) / cell_px;
            const a = f.table[bi][ci];
            const hue: usize = if (a == areas.none) 0 else @as(usize, a) + 1;
            o.* = if (s == 0xFF) ix_blank else @intCast(ix_tint + hue * 4 + s);
        }
        for (w.banks[bi].cells, 0..) |c, ci| {
            const x0 = (ci % map.grid_w) * cell_px;
            const y0 = (ci / map.grid_w) * cell_px;
            // Grid, then walls where the camera is blocked.
            cv.rect(x0, y0, cell_px, 1, ix_grid);
            cv.rect(x0, y0, 1, cell_px, ix_grid);
            if (!c.inUse()) continue;
            if (c.scroll.block_up) cv.rect(x0, y0, cell_px, 3, ix_wall);
            if (c.scroll.block_down) cv.rect(x0, y0 + cell_px - 3, cell_px, 3, ix_wall);
            if (c.scroll.block_left) cv.rect(x0, y0, 3, cell_px, ix_wall);
            if (c.scroll.block_right) cv.rect(x0 + cell_px - 3, y0, 3, cell_px, ix_wall);
            if (marked[bi][ci] != areas.none and marked[bi][ci] & areas.nest_bit != 0) {
                cv.rect(x0 + 6, y0 + 6, cell_px - 12, 3, ix_nest);
                cv.rect(x0 + 6, y0 + cell_px - 9, cell_px - 12, 3, ix_nest);
                cv.rect(x0 + 6, y0 + 6, 3, cell_px - 12, ix_nest);
                cv.rect(x0 + cell_px - 9, y0 + 6, 3, cell_px - 12, ix_nest);
            }
            if (lava.best(bi, ci)) cv.rect(x0 + 40, y0 + 8, cell_px - 50, 10, ix_lava);
            cv.glyph(x0 + 4, y0 + 4, @intCast(ci >> 4));
            cv.glyph(x0 + 4 + 15, y0 + 4, @intCast(ci & 0xF));
        }
        for (areas.cuts) |c| {
            if (c.a.bank != bank or c.b.bank != bank) continue;
            const ax = c.a.cell & 0xF;
            const ay = c.a.cell >> 4;
            const bx = c.b.cell & 0xF;
            const by = c.b.cell >> 4;
            if (ay == by) {
                // Horizontal neighbours: a vertical red bar on the shared edge.
                const x = @as(usize, @max(ax, bx)) * cell_px;
                const edge_x = if (@max(ax, bx) - @min(ax, bx) == 1) x else 0;
                cv.rect(if (edge_x == 0) 0 else edge_x - 4, @as(usize, ay) * cell_px, 8, cell_px, ix_cut);
            } else if (ax == bx) {
                const y = @as(usize, @max(ay, by)) * cell_px;
                const edge_y = if (@max(ay, by) - @min(ay, by) == 1) y else 0;
                cv.rect(@as(usize, ax) * cell_px, if (edge_y == 0) 0 else edge_y - 4, cell_px, 8, ix_cut);
            }
        }
        for (areas.seeds) |s| {
            if (s.at.bank != bank) continue;
            const x0 = (s.at.cell & 0xF) * @as(usize, cell_px);
            const y0 = (s.at.cell >> 4) * @as(usize, cell_px);
            cv.rect(x0 + 8, y0 + 8, cell_px - 16, 4, ix_seed);
            cv.rect(x0 + 8, y0 + cell_px - 12, cell_px - 16, 4, ix_seed);
            cv.rect(x0 + 8, y0 + 8, 4, cell_px - 16, ix_seed);
            cv.rect(x0 + cell_px - 12, y0 + 8, 4, cell_px - 16, ix_seed);
        }
        const image = try png.encodeIndexed(gpa, cv.px, side, side, &pal);
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "bank{X}.png", .{bank});
        try dir.writeFile(init.io, .{ .sub_path = name, .data = image });
    }

    var counts: [areas.Area.count]usize = @splat(0);
    for (f.table) |b| for (b) |a| if (a != areas.none) {
        counts[a] += 1;
    };
    try out.print("{d} banks -> {s}/\n", .{ map.bank_count, out_dir });
    for (counts, 0..) |n, i| try out.print("  {s:<8} {d:>4} cells\n", .{ @as(areas.Area, @enumFromInt(i)).label(), n });
    for (f.clashes) |c| try out.print("missing cut: ${X}:{X:0>2} ({s}) / ${X}:{X:0>2} ({s})\n", .{ c.link.a.bank, c.link.a.cell, c.a.label(), c.link.b.bank, c.link.b.cell, c.b.label() });
    for (f.overrun_seeds) |s| try out.print("overrun seed: ${X}:{X:0>2} ({s})\n", .{ s.at.bank, s.at.cell, s.area.label() });
    for (f.unused_cuts) |c| try out.print("unused cut: ${X}:{X:0>2} / ${X}:{X:0>2}\n", .{ c.a.bank, c.a.cell, c.b.bank, c.b.cell });
    if (f.unassigned.len > 0) {
        try out.print("{d} in-use cells unassigned:", .{f.unassigned.len});
        for (f.unassigned, 0..) |u, i| {
            if (i % 12 == 0) try out.print("\n ", .{});
            try out.print(" ${X}:${X:0>2}", .{ u.bank, u.cell });
        }
        try out.print("\n", .{});
    }
}
