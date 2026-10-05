//! `zig build inspect [-- <what>]` - look at the conversion.
//!
//! `verify` judges the conversion in two lines. This is the other half: the
//! pictures a human uses to decide whether a passing diff is passing for the
//! right reason, and to see what a failing one actually looks like.
//!
//! Everything renders through `snes_render.Renderer`, the same code the gate
//! uses. A tool with its own render path could show a human something the gate
//! never checked, which is exactly what an A/B view is supposed to prevent.
//!
//!     zig build inspect                      contact sheets, one per map bank
//!     zig build inspect -- screens [bank]    an A/B image per screen
//!     zig build inspect -- screen B R C [T]  one screen, optionally with
//!                                            tileset T, plus its data dump
//!     zig build inspect -- chars <door>      the 256 BG3 characters a door
//!                                            script leaves loaded, A/B
//!     zig build inspect -- sheet <name>      one named asset as a tile grid,
//!                                            A/B
//!     zig build inspect -- fault <name>      any of the above renders with a
//!                                            deliberate fault injected
//!
//! Output goes under `extracted/inspect/`, which is untracked: it is made of
//! the user's ROM.

const std = @import("std");
const rom_mod = @import("rom.zig");
const offsets = @import("offsets.zig");
const map = @import("map.zig");
const tileset = @import("tileset.zig");
const gfx = @import("gfx.zig");
const screens = @import("screens.zig");
const coverage = @import("coverage.zig");
const convert = @import("snes_convert.zig");
const render = @import("snes_render.zig");
const chr = @import("snes_chr.zig");
const inspect = @import("inspect.zig");

const build_options = @import("build_options");

pub const out_dir = "extracted/inspect";

/// A screen is 256x256; a contact-sheet cell is a quarter of that.
const contact_factor: usize = 4;
/// 8x8 characters are unreadable at 1:1.
const char_zoom: usize = 3;

const Tool = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    dir: std.Io.Dir,
    out: *std.Io.Writer,
    r: *render.Renderer,
    fault: render.Fault,
    written: usize = 0,
    bytes: usize = 0,
    loud: inspect.Loudness = .{},

    /// Writes a PNG, tagging the name with the fault when one is injected.
    ///
    /// Not cosmetic: without it a faulted run overwrites the clean image of the
    /// same screen and the two are indistinguishable afterwards, which for a
    /// tool whose whole output is pictures is the worst thing it could do.
    fn write(self: *Tool, name: []const u8, img: inspect.Image) !void {
        const data = try img.encode(self.arena);
        var tagged_buf: [128]u8 = undefined;
        const sub_path = if (self.fault == .none) name else try std.fmt.bufPrint(
            &tagged_buf,
            "fault-{s}_{s}",
            .{ @tagName(self.fault), name },
        );
        try self.dir.writeFile(self.io, .{ .sub_path = sub_path, .data = data });
        self.written += 1;
        self.bytes += data.len;
    }
};

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    if (build_options.rom_path.len == 0) {
        try out.print("no ROM configured (set M2_ROM; see docs/setup.md)\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(init.io, build_options.rom_path, arena, .limited(rom_mod.expected_size * 4));
    _ = try rom_mod.ingest(arena, rom, null);

    var arg_list: std.ArrayList([]const u8) = .empty;
    var arg_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_iter.next(); // argv[0]
    while (arg_iter.next()) |a| try arg_list.append(arena, a);
    var argv: []const []const u8 = arg_list.items;

    // `fault <name>` is a prefix on any other subcommand, so a human can look
    // at a deliberately broken conversion through exactly the same views.
    var fault: render.Fault = .none;
    if (argv.len >= 2 and std.mem.eql(u8, argv[0], "fault")) {
        fault = std.meta.stringToEnum(render.Fault, argv[1]) orelse {
            try out.print("unknown fault '{s}'; one of: ", .{argv[1]});
            for (std.enums.values(render.Fault)) |f| try out.print("{s} ", .{@tagName(f)});
            try out.print("\n", .{});
            try out.flush();
            std.process.exit(2);
        };
        argv = argv[2..];
    }

    var set = try convert.run(init.gpa, rom);
    defer set.deinit();
    var r = try render.Renderer.init(arena, rom, set);
    defer r.deinit();

    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, out_dir, .{});
    defer dir.close(init.io);

    var tool: Tool = .{ .io = init.io, .arena = arena, .dir = dir, .out = out, .r = &r, .fault = fault };

    if (fault != .none) {
        try out.print("fault injected into the converted side: {s}\n", .{@tagName(fault)});
    }

    const what = if (argv.len == 0) "contact" else argv[0];
    if (std.mem.eql(u8, what, "contact")) {
        try contactSheets(&tool);
    } else if (std.mem.eql(u8, what, "screens")) {
        const bank: ?u8 = if (argv.len > 1) try std.fmt.parseInt(u8, argv[1], 16) else null;
        try allScreens(&tool, bank);
    } else if (std.mem.eql(u8, what, "screen")) {
        if (argv.len < 4) return usage(out);
        try oneScreen(
            &tool,
            try std.fmt.parseInt(u8, argv[1], 16),
            try std.fmt.parseInt(u4, argv[2], 16),
            try std.fmt.parseInt(u4, argv[3], 16),
            if (argv.len > 4) try std.fmt.parseInt(u4, argv[4], 10) else null,
        );
    } else if (std.mem.eql(u8, what, "chars")) {
        if (argv.len < 2) return usage(out);
        try charSheet(&tool, try std.fmt.parseInt(u16, argv[1], 10));
    } else if (std.mem.eql(u8, what, "sheet")) {
        if (argv.len < 2) return usage(out);
        try assetSheet(&tool, argv[1]);
    } else {
        return usage(out);
    }

    try out.print("\n{d} images -> {s}/ ({d} KiB)\n", .{ tool.written, out_dir, tool.bytes / 1024 });
    if (tool.loud.screens != 0) {
        const bp = tool.loud.overallBp();
        try out.print("diff channel: {d}/{d} screens marked, {d}.{d:0>2}% of pixels overall, loudest screen {d}.{d:0>2}%\n", .{
            tool.loud.screens_marked, tool.loud.screens,
            bp / 100, bp % 100,
            tool.loud.loudest_bp / 100, tool.loud.loudest_bp % 100,
        });
    }

    // ---- Coverage, on every view ------------------------------------------
    //
    // Wired in here rather than left to `zig build coverage` because the
    // question these tools answer - "does the conversion look right" - is not
    // separable from "how much of the ROM has been reached at all". A picture
    // that looks perfect over 74% of the ROM is a different claim from one that
    // looks perfect over all of it.
    const text = try coverage.reportText(arena, rom);
    try dir.writeFile(init.io, .{ .sub_path = coverage.file_name, .data = text });
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "bytes claimed") != null or
            std.mem.indexOf(u8, line, "bytes unclaimed") != null or
            std.mem.indexOf(u8, line, "Unclaimed runs") != null)
        {
            try out.print("coverage: {s}\n", .{std.mem.trim(u8, line, " -")});
        }
    }
    try out.print("coverage: full report in {s}/{s}\n", .{ out_dir, coverage.file_name });
    try out.flush();
}

fn usage(out: *std.Io.Writer) !void {
    try out.print(
        \\usage: zig build inspect -- [fault <name>] <what>
        \\  contact                 contact sheets, one per map bank (default)
        \\  screens [bank]          an A/B image per screen
        \\  screen <bank> <r> <c> [tiletable]
        \\  chars <door index>      the 256 BG3 characters a door leaves loaded
        \\  sheet <asset name>      one named asset as a tile grid
        \\
    , .{});
    try out.flush();
    std.process.exit(2);
}

// ---- Contact sheets --------------------------------------------------------

/// One sheet per map bank: every in-use screen at quarter size, in its grid
/// position, with any screen whose conversion differs ringed in yellow.
///
/// Grid position rather than packed order on purpose - a contact sheet of a
/// 16x16 map should look like the map, so a human can find the room they mean.
fn contactSheets(t: *Tool) !void {
    const cell = screens.screen_px / contact_factor;
    const sheet: inspect.Sheet = .{ .cols = map.grid_w, .cell_w = cell, .cell_h = cell };
    const size = sheet.size(map.grid_w * map.grid_h);

    var total_flagged: usize = 0;
    for (map.first_bank..map.last_bank + 1) |b| {
        const bank: u8 = @intCast(b);
        var img = try inspect.Image.init(t.arena, size.w, size.h, inspect.gutter);
        var present: usize = 0;
        var flagged: usize = 0;

        for (t.r.assignment.cells) |c| {
            if (c.bank != bank) continue;
            var p = (try t.r.pair(c, null, t.fault)) orelse continue;
            defer p.deinit(t.arena);
            present += 1;

            const small = try inspect.downscale(t.arena, p.snes.pixels, screens.screen_px, screens.screen_px, contact_factor);
            const index = @as(usize, c.y) * map.grid_w + c.x;
            const o = sheet.origin(index);
            img.blit(o.x, o.y, small, cell, cell);
            const panel = try inspect.diffPanel(t.arena, p.gb.pixels, p.snes.pixels);
            defer t.arena.free(panel);
            t.loud.add(panel);
            if (inspect.diffMarked(panel) != 0) {
                inspect.flagCell(img, sheet, index, inspect.marker);
                flagged += 1;
            }
        }

        var name_buf: [32]u8 = undefined;
        try t.write(try std.fmt.bufPrint(&name_buf, "contact_bank{X}.png", .{bank}), img);
        try t.out.print("bank ${X}: {d} screens, {d} flagged\n", .{ bank, present, flagged });
        total_flagged += flagged;
    }
    try t.out.print("{d} screens differ from the reference\n", .{total_flagged});
}

// ---- A/B images ------------------------------------------------------------

fn abForCell(t: *Tool, c: screens.Cell, tiletable: ?u4) !?usize {
    var p = (try t.r.pair(c, tiletable, t.fault)) orelse return null;
    defer p.deinit(t.arena);

    {
        const panel = try inspect.diffPanel(t.arena, p.gb.pixels, p.snes.pixels);
        defer t.arena.free(panel);
        t.loud.add(panel);
    }
    const img = try inspect.abImage(t.arena, p.gb.pixels, p.snes.pixels, screens.screen_px, screens.screen_px);
    var name_buf: [64]u8 = undefined;
    const name = if (tiletable) |tt|
        try std.fmt.bufPrint(&name_buf, "ab_bank{X}_r{X}c{X}_tt{d}.png", .{ c.bank, c.y, c.x, tt })
    else
        try std.fmt.bufPrint(&name_buf, "ab_bank{X}_r{X}c{X}.png", .{ c.bank, c.y, c.x });
    try t.write(name, img);
    return p.differingPixels();
}

fn allScreens(t: *Tool, bank: ?u8) !void {
    var differing: usize = 0;
    var total: usize = 0;
    for (t.r.assignment.cells) |c| {
        if (bank) |b| if (c.bank != b) continue;
        const d = (try abForCell(t, c, null)) orelse continue;
        total += 1;
        if (d != 0) differing += 1;
    }
    try t.out.print("{d} A/B images, {d} with differences\n", .{ total, differing });
}

fn oneScreen(t: *Tool, bank: u8, row: u4, col: u4, tiletable: ?u4) !void {
    const cell = for (t.r.assignment.cells) |c| {
        if (c.bank == bank and c.y == row and c.x == col) break c;
    } else {
        try t.out.print("bank ${X} r{X} c{X} is not an in-use screen. In bank ${X}:\n", .{ bank, row, col, bank });
        var n: usize = 0;
        for (t.r.assignment.cells) |c| {
            if (c.bank != bank) continue;
            try t.out.print(" r{X}c{X}", .{ c.y, c.x });
            n += 1;
            if (n % 16 == 0) try t.out.print("\n", .{});
        }
        try t.out.print("\n", .{});
        return;
    };
    const choice = cell.choice.?;
    const tt = tiletable orelse choice.tiletable;

    const d = (try abForCell(t, cell, tiletable)) orelse {
        try t.out.print("screen has no body\n", .{});
        return;
    };
    try t.out.print("bank ${X} r{X} c{X}: door {d}, tileset {d} ({s}), provenance {s}\n", .{
        bank, row, col, choice.door_index, tt, screens.tiletable_order[tt], choice.provenance.label(),
    });
    if (tiletable != null and tiletable.? != choice.tiletable) {
        try t.out.print("  tileset overridden: assigned {d}, rendered {d}\n", .{ choice.tiletable, tt });
    }
    try t.out.print("  {d} pixels differ\n", .{d});

    try dumpScreenData(t, cell, tt);
}

// ---- The asset viewer's data half ------------------------------------------

/// Step through a screen's metatile, collision, and solidity data, beside the
/// picture. The collision and solidity tables are unchanged by the conversion,
/// so what this shows is the ROM's - which is the point: it is how you check
/// that the picture and the data agree.
fn dumpScreenData(t: *Tool, cell: screens.Cell, tt: u4) !void {
    const body = map.screenBody(t.r.rom, cell.bank, cell.screen_ptr) orelse return;
    const raw = screens.metatileTable(t.r.rom, tt) orelse return;
    const metatiles = try tileset.parseMetatiles(t.arena, raw);

    // Collision and solidity are per *tileset*, not per tiletable slot. The two
    // are not the same list, so map through the name rather than the index.
    const ts_name = screens.tiletable_order[tt];
    var collision: ?[]const u8 = null;
    var solidity_row: ?usize = null;
    for (tileset.tilesets, 0..) |ts, i| {
        for (ts.metatiles) |m| {
            if (std.mem.eql(u8, m, ts_name)) {
                collision = tileset.slice(t.r.rom, ts.collision);
                solidity_row = i;
            }
        }
    }

    var seen: [256]usize = @splat(0);
    for (body) |mt| seen[mt] += 1;

    try t.out.print("\n  metatiles used ({d} distinct of {d} in the table):\n", .{
        blk: {
            var n: usize = 0;
            for (seen) |c| n += @intFromBool(c != 0);
            break :blk n;
        },
        metatiles.len,
    });
    try t.out.print("    {s:>4}  {s:>5}  {s:>19}  {s:>9}\n", .{ "idx", "count", "tl tr bl br", "collision" });
    for (seen, 0..) |count, i| {
        if (count == 0) continue;
        if (i >= metatiles.len) {
            try t.out.print("    {d:>4}  {d:>5}  (past the end of the table)\n", .{ i, count });
            continue;
        }
        const m = metatiles[i];
        const col: ?u8 = if (collision) |c| (if (i < c.len) c[i] else null) else null;
        try t.out.print("    {d:>4}  {d:>5}  {X:0>2} {X:0>2} {X:0>2} {X:0>2}{s:>8}  ", .{
            i, count, m.tl, m.tr, m.bl, m.br, "",
        });
        if (col) |c| try t.out.print("${X:0>2}\n", .{c}) else try t.out.print("-\n", .{});
    }

    if (solidity_row) |sr| {
        const sol = try tileset.parseSolidity(tileset.slice(t.r.rom, "solidity_thresholds").?);
        try t.out.print("  solidity row {d} ({s}): thresholds ${X:0>2} ${X:0>2} ${X:0>2}\n", .{
            sr, tileset.tilesets[sr].name, sol[sr].thresholds[0], sol[sr].thresholds[1], sol[sr].thresholds[2],
        });
    }
}

// ---- Character-level views -------------------------------------------------

/// The 256 BG3 characters a door script leaves loaded, drawn as a 16x16 grid,
/// Game Boy beside SNES beside the diff.
///
/// This is the component level the screen view cannot reach: a screen only
/// shows the characters its metatiles happen to name, and a sheet that converts
/// wrongly in a corner no room draws would never appear in an A/B of screens.
fn charSheet(t: *Tool, door_index: u16) !void {
    const cols = 16;
    const cell = gfx.tile_w * char_zoom;
    const w = cols * cell;
    const h = (256 / cols) * cell;

    const gb_vram = t.r.gbVramForDoor(door_index);
    const sn_vram = try t.r.vramForDoor(door_index);

    const gb = try t.arena.alloc(u8, w * h);
    const sn = try t.arena.alloc(u8, w * h);
    @memset(gb, 0);
    @memset(sn, 0);

    var loaded: usize = 0;
    for (0..256) |id| {
        const cx = (id % cols) * cell;
        const cy = (id / cols) * cell;
        if (gb_vram.tileWritten(@intCast(id))) loaded += 1;

        const gb_tile = gb_vram.tile(@intCast(id));
        const bytes = sn_vram.charBytes(@intCast(id));
        const sn_tile = chr.decodeSnes2bpp(&bytes);

        for (0..gfx.tile_h) |y| {
            for (0..gfx.tile_w) |x| {
                const g = t.r.palette[gb_tile.pixels[y][x]];
                const s = t.r.palette[sn_tile[y][x] & 3];
                for (0..char_zoom) |dy| {
                    for (0..char_zoom) |dx| {
                        const px = cx + x * char_zoom + dx;
                        const py = cy + y * char_zoom + dy;
                        gb[py * w + px] = g;
                        sn[py * w + px] = s;
                    }
                }
            }
        }
    }

    const img = try inspect.abImage(t.arena, gb, sn, w, h);
    var name_buf: [48]u8 = undefined;
    try t.write(try std.fmt.bufPrint(&name_buf, "chars_door{d}.png", .{door_index}), img);

    const diff = try inspect.diffPanel(t.arena, gb, sn);
    try t.out.print("door {d}: {d}/256 characters loaded, {d} pixels differ\n", .{
        door_index, loaded, inspect.diffMarked(diff),
    });
}

/// One named asset as a tile grid: the Game Boy's own bytes decoded on the
/// left, the converted asset decoded at its own depth on the right.
///
/// This is the sprite-sheet view. An object sheet is 4bpp on the SNES and the
/// Game Boy has no such thing, so what is compared is the pixels, which is the
/// only thing the two representations share.
fn assetSheet(t: *Tool, name: []const u8) !void {
    const asset = for (t.r.set.assets) |a| {
        if (std.mem.eql(u8, a.name, name)) break a;
    } else {
        try t.out.print("no converted asset named '{s}'. Named assets:\n", .{name});
        for (t.r.set.assets) |a| try t.out.print("  {s:<28} {s:<8} {s}\n", .{ a.name, a.kind.className(), @tagName(a.basis) });
        return;
    };
    if (asset.kind == .tilemap) {
        try t.out.print("'{s}' is tilemap words, not characters; there is nothing to draw\n", .{name});
        return;
    }

    const gb_bytes = t.r.rom[asset.rom_at..][0..asset.gb_bytes];
    const count = asset.gb_bytes / gfx.tile_bytes;
    const cols = 16;
    const cell = gfx.tile_w * char_zoom;
    const rows = (count + cols - 1) / cols;
    const w = cols * cell;
    const h = rows * cell;

    const gb = try t.arena.alloc(u8, w * h);
    const sn = try t.arena.alloc(u8, w * h);
    @memset(gb, 0);
    @memset(sn, 0);

    for (0..count) |i| {
        const gb_tile = gfx.Tile.decode(gb_bytes[i * gfx.tile_bytes ..][0..gfx.tile_bytes]);
        const sn_tile: chr.Pixels = switch (asset.kind) {
            .chr_bg => chr.decodeSnes2bpp(asset.bytes[i * 16 ..][0..16]),
            .chr_obj => chr.decodeSnes4bpp(asset.bytes[i * 32 ..][0..32]),
            .tilemap => unreachable,
        };
        const cx = (i % cols) * cell;
        const cy = (i / cols) * cell;
        for (0..gfx.tile_h) |y| {
            for (0..gfx.tile_w) |x| {
                const g = t.r.palette[gb_tile.pixels[y][x]];
                const s = t.r.palette[sn_tile[y][x] & 3];
                for (0..char_zoom) |dy| {
                    for (0..char_zoom) |dx| {
                        gb[(cy + y * char_zoom + dy) * w + cx + x * char_zoom + dx] = g;
                        sn[(cy + y * char_zoom + dy) * w + cx + x * char_zoom + dx] = s;
                    }
                }
            }
        }
    }

    const img = try inspect.abImage(t.arena, gb, sn, w, h);
    var name_buf: [80]u8 = undefined;
    try t.write(try std.fmt.bufPrint(&name_buf, "sheet_{s}_{s}.png", .{ asset.name, asset.kind.className() }), img);

    const diff = try inspect.diffPanel(t.arena, gb, sn);
    try t.out.print("{s} ({s}, basis {s}): {d} tiles, {d} Game Boy bytes -> {d} converted, {d} pixels differ\n", .{
        asset.name, asset.kind.className(), @tagName(asset.basis), count, asset.gb_bytes, asset.bytes.len,
        inspect.diffMarked(diff),
    });
}
