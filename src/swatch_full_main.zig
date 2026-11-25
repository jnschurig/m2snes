//! `zig build swatch-full` (colorization Step 9): the `full` scheme's swatch
//! sheet, `build-out/swatch-full/full-swatches.html` (`swatch_full.zig`), for
//! choosing and approving the colours by eye. The `--debug` cart loads a new
//! game's record in `full` (the SRAM scheme bytes) and warps through the menu
//! to a landing in each colour set; the script prints each frame as a PNG,
//! which go into the page and beside it as `set-NN.png`. Not graded: a set
//! with no landing, or whose landings all show another set, is reported and
//! drawn without a frame. Beside it, `enemy-swatches.html`: every sprite
//! sheet drawn from the ROM in the palettes the cart gives its tiles.
//!
//! `zig build swatch-full -- try <hex id>...`: those enemy sprites drawn
//! with every enemy sheet, to `build-out/swatch-full/try-<id>.png`, for
//! choosing a sheet by eye (`sprite_catalog.zon`'s `ai_sheets`).
//!
//! `zig build swatch-full -- survey`: what each set draws (its cells'
//! background sheets), and each background sheet's tiles by collision kind,
//! as `full_assign.tile_choices` lines.

const std = @import("std");
const build_options = @import("build_options");
const rom_mod = @import("rom.zig");
const areas = @import("areas.zig");
const map = @import("map.zig");
const colors = @import("colors.zig");
const save = @import("save.zig");
const snes_convert = @import("snes_convert.zig");
const snes_screen = @import("snes_screen.zig");
const snes_inject = @import("snes_inject.zig");
const warp = @import("warp.zig");
const debug_tables = @import("debug_tables.zig");
const wg = @import("warp_grade.zig");
const scheme_grade = @import("scheme_grade.zig");
const screens = @import("screens.zig");
const full_slots = @import("full_slots.zig");
const swatch = @import("swatch_full.zig");
const sprite_model = @import("sprite_model.zig");
const offsets = @import("offsets.zig");
const entity = @import("entity.zig");
const sprites = @import("sprites.zig");

const out_dir = "build-out/swatch-full";
const label = swatch.label;
/// Landings tried a set, in warp-list order.
const tries = 6;
/// Frames after the warp before the picture: the load's fade is over.
const settle = 90;

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = init.io;

    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (build_options.rom_path.len == 0 or build_options.mesen_path.len == 0) {
        try out.print("swatch-full: needs M2_ROM and MESEN; see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, build_options.rom_path, a, .limited(rom_mod.expected_size * 4));
    var argv = std.process.Args.Iterator.init(init.minimal.args);
    _ = argv.next();
    if (argv.next()) |x| {
        if (std.mem.eql(u8, x, "survey")) return survey(a, rom, out);
        if (std.mem.eql(u8, x, "try")) {
            var ids: std.ArrayList(u8) = .empty;
            while (argv.next()) |y| try ids.append(a, try std.fmt.parseInt(u8, y, 16));
            return tryRuns(a, io, rom, ids.items, out);
        }
    }

    const set = try snes_convert.run(a, rom);
    const boot = try snes_screen.newGameBoot(a, rom);
    var diag: snes_inject.Diagnosis = .{};
    var dbg = try snes_inject.build(a, set, boot, &diag);
    try snes_inject.enableDebug(&dbg);
    const walked = try warp.loadWalked(a, rom);
    const built = try warp.build(a, rom, walked);
    const sorted = try debug_tables.warpOrder(a, rom, built.entries);
    const table = try areas.tableOf(a, rom);

    // Each set's candidate landings, as (list, row): those the set shows at,
    // and for an area, those in the same area to walk from (left, then right,
    // hopping) until it does.
    var cands: [areas.set_count]std.ArrayList([2]usize) = @splat(.empty);
    var walks: [areas.Area.count]std.ArrayList([2]usize) = @splat(.empty);
    for (sorted, 0..) |e, i| {
        // The camera's cell, as `FullFrame` reads it: a `_before` landing is
        // in the room before its target's.
        const cell: u8 = @intCast(((e.cam_y >> 8) & 0xF) << 4 | ((e.cam_x >> 8) & 0xF));
        const byte = table[e.dest.at.bank - map.first_bank][cell];
        const s = areas.setOf(areas.lookOf(byte, e.tileset.tiletable));
        if (cands[s].items.len < tries) try cands[s].append(a, debug_tables.warpRow(sorted, i));
        const ar = byte & ~areas.nest_bit;
        if (walks[ar].items.len < tries) try walks[ar].append(a, debug_tables.warpRow(sorted, i));
    }

    // Every cell of each set (nest and area from the table, acid not known
    // statically), beside the landings that reach it.
    var cells: [areas.set_count]usize = @splat(0);
    for (table) |bank| for (bank) |byte| {
        cells[areas.setOf(areas.lookOf(byte, 4))] += 1;
    };
    for (cands, cells, 0..) |c, n, s| if (c.items.len == 0) try out.print("set {d:>2} {s:<14} no landing; {d} cells\n", .{ s, try label(a, s), n });

    var lua: std.Io.Writer.Allocating = .init(a);
    const w = &lua.writer;
    try w.print(
        \\-- Generated by `zig build swatch-full`. Do not edit.
        \\-- Each colour set's landing in `full`, printed as `SHOT <set> <hex png>`.
        \\
    , .{});
    try wg.writeMenuPrelude(rom, sorted, 30000, w);
    try w.print("local FSET, SETTLE, SCHEME, FULL = {d}, {d}, {d}, {d}\n", .{ try wg.sym("VarFullSet"), settle, try wg.sym("VarScheme"), @intFromEnum(colors.Scheme.full) });
    // A game in slot 0, as the scheme byte is read only for a slot with one.
    for (try scheme_grade.gameRecord(rom), 0..) |b, i| try w.print("emu.write({d}, {d}, emu.memType.snesSaveRam)\n", .{ i, b });
    for (colors.sram_magic, 0..) |b, i| try w.print("emu.write({d}, {d}, emu.memType.snesSaveRam)\n", .{ colors.sram_at + i, b });
    for (0..save.slots) |s| try w.print("emu.write({d}, {d}, emu.memType.snesSaveRam)\n", .{ colors.sram_at + colors.sram_magic.len + s, @intFromEnum(colors.Scheme.full) });
    try w.print("CANDS = {{\n", .{});
    for (cands, 0..) |c, s| {
        try w.print("  {{ {d}, {{", .{s});
        for (c.items) |lr| try w.print(" {{ {d}, {d} }},", .{ lr[0], lr[1] });
        try w.print(" }}, {{", .{});
        if (s < areas.Area.count) for (walks[s].items) |lr| try w.print(" {{ {d}, {d} }},", .{ lr[0], lr[1] });
        try w.print(" }} }},\n", .{});
    }
    try w.print(
        \\}}
        \\local function hex(s)
        \\  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
        \\end
        \\local function main()
        \\  if emu.read(SCHEME, wram) ~= FULL then fail(10, "scheme " .. emu.read(SCHEME, wram)) end
        \\  local got = {{}}
        \\  for _, c in ipairs(CANDS) do
        \\    local want = c[1]
        \\    for _, lr in ipairs(c[2]) do
        \\      if not got[want] then
        \\        warp(lr[1], lr[2]); wait(SETTLE)
        \\        local s = emu.read(FSET, wram)
        \\        if s == want then
        \\          print(string.format("SHOT %d %d %d %s", want, lr[1], lr[2], hex(emu.takeScreenshot())))
        \\          got[want] = true
        \\        else
        \\          print(string.format("MISS %d %d %d showed %d", want, lr[1], lr[2], s))
        \\        end
        \\      end
        \\    end
        \\  end
        \\  -- The walks last, with the loadout: a hop into acid can end the game.
        \\  -- It brings the Varia Suit: her in it, at the first set's landing.
        \\  loadout()
        \\  local v = CANDS[1][2][1]
        \\  warp(v[1], v[2]); wait(SETTLE)
        \\  print(string.format("VARIA %s", hex(emu.takeScreenshot())))
        \\  for _, c in ipairs(CANDS) do
        \\    local want, done = c[1], got[c[1]]
        \\    for _, lr in ipairs(c[3]) do
        \\      for _, dir in ipairs({{ "left", "right" }}) do
        \\        if not done then
        \\          warp(lr[1], lr[2]); wait(SETTLE)
        \\          for f = 1, 360 do
        \\            if not done then
        \\              PAD = {{ [dir] = true, a = (f % 48) < 24 }}
        \\              frame()
        \\              if emu.read(FSET, wram) == want then
        \\                PAD = {{}}; wait(SETTLE)
        \\                if emu.read(FSET, wram) == want then
        \\                  print(string.format("SHOT %d %d %d %s", want, lr[1], lr[2], hex(emu.takeScreenshot())))
        \\                  done = true
        \\                end
        \\              end
        \\            end
        \\          end
        \\          PAD = {{}}
        \\        end
        \\      end
        \\    end
        \\    if not done then print(string.format("NONE %d", want)) end
        \\  end
        \\  emu.stop(0)
        \\end
        \\
    , .{});
    try wg.writeRunner(w);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "swatch-full.sfc", .data = dbg.bytes });
    try dir.writeFile(io, .{ .sub_path = "swatch-full.lua", .data = lua.written() });

    // Last run's pictures go first, so a set with none this run has none.
    for (0..areas.set_count) |si| try deleteIfThere(io, dir, try std.fmt.allocPrint(a, "set-{d:0>2}.png", .{si}));
    try deleteIfThere(io, dir, "varia.png");

    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.mesen_path, out_dir ++ "/swatch-full.sfc", "--testrunner", out_dir ++ "/swatch-full.lua", "--timeout=600", "--snes.disableFrameSkipping=true" },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var buf: [4096]u8 = undefined;
    var rdr = child.stdout.?.readerStreaming(io, &buf);
    const text = try rdr.interface.allocRemaining(a, .limited(64 << 20));
    const term = try child.wait(io);

    var shots: usize = 0;
    var frames: [areas.set_count]?[]const u8 = @splat(null);
    var varia: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "VARIA ")) {
            const h = l["VARIA ".len..];
            const png = try a.alloc(u8, h.len / 2);
            _ = try std.fmt.hexToBytes(png, h);
            try dir.writeFile(io, .{ .sub_path = "varia.png", .data = png });
            varia = png;
            continue;
        }
        if (!std.mem.startsWith(u8, l, "SHOT ")) {
            if (l.len > 0) try out.print("  {s}\n", .{l});
            continue;
        }
        var f = std.mem.tokenizeScalar(u8, l["SHOT ".len..], ' ');
        const s = try std.fmt.parseInt(usize, f.next().?, 10);
        const li = f.next().?;
        const row = f.next().?;
        const h = f.next().?;
        const png = try a.alloc(u8, h.len / 2);
        _ = try std.fmt.hexToBytes(png, h);
        const name = try std.fmt.allocPrint(a, "set-{d:0>2}.png", .{s});
        try dir.writeFile(io, .{ .sub_path = name, .data = png });
        frames[s] = png;
        try out.print("set {d:>2} {s:<14} list {s} row {s:>3} -> {s}/{s}\n", .{ s, try label(a, s), li, row, out_dir, name });
        shots += 1;
    }
    const code: u8 = if (term == .exited) @truncate(term.exited) else 255;
    if (code != 0) {
        try out.print("swatch-full: Mesen exit {d}; the page is not written\n", .{code});
        try out.flush();
        std.process.exit(1);
    }
    // The sprite sheets, from the ROM: no emulator needed.
    var sheet_pngs: [swatch.enemy_sheets.len][]const u8 = undefined;
    for (swatch.enemy_sheets, &sheet_pngs) |spec, *sp| {
        const e = offsets.find(spec.name) orelse return error.UnknownSheet;
        sp.* = try swatch.sheetPng(a, rom[e.romOffset()..e.romEnd()], spec);
        try dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "sheet-{s}.png", .{spec.name["gfx_".len..]}), .data = sp.* });
    }
    var enemy_page: std.Io.Writer.Allocating = .init(a);
    try swatch.writeEnemyPage(&enemy_page.writer, try sprite_model.assembleSprites(a, rom), &sheet_pngs);
    try dir.writeFile(io, .{ .sub_path = "enemy-swatches.html", .data = enemy_page.written() });
    try out.print("swatch-full: {s}/enemy-swatches.html\n", .{out_dir});

    var page: std.Io.Writer.Allocating = .init(a);
    try swatch.writePage(a, &page.writer, &frames, varia);
    try dir.writeFile(io, .{ .sub_path = "full-swatches.html", .data = page.written() });
    try out.print("swatch-full: {d} of {d} sets have a frame; {s}/full-swatches.html\n", .{ shots, areas.set_count, out_dir });
}

fn deleteIfThere(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    dir.deleteFile(io, name) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
}

/// `zig build swatch-full -- survey`: each set's background sheets by cell
/// count (`screens.assign`'s static reading), then per background sheet the
/// tile ids each collision bit marks (spike, acid, slowing liquid), as
/// `tile_choices` lines.
fn survey(a: std.mem.Allocator, rom: []const u8, out: *std.Io.Writer) !void {
    const table = try areas.tableOf(a, rom);
    const asg = try screens.assign(a, rom);
    var sheets: [areas.set_count]std.StringArrayHashMapUnmanaged(usize) = @splat(.empty);
    for (asg.cells) |c| {
        const ch = c.choice orelse continue;
        const byte = table[c.bank - map.first_bank][@as(usize, c.y) * 16 + c.x];
        if (byte == areas.none) continue;
        const s = areas.setOf(areas.lookOf(byte, ch.tiletable));
        const g = try sheets[s].getOrPut(a, ch.bg_gfx orelse "?");
        if (!g.found_existing) g.value_ptr.* = 0;
        g.value_ptr.* += 1;
    }
    for (sheets, 0..) |m, s| {
        try out.print("set {d:>2} {s:<14}", .{ s, try label(a, s) });
        for (m.keys(), m.values()) |k, v| try out.print(" {s}:{d}", .{ k, v });
        try out.print("\n", .{});
    }
    const tileset = @import("tileset.zig");
    const kinds = [_]struct { bit: u8, name: []const u8 }{ .{ .bit = 0x08, .name = "spike" }, .{ .bit = 0x10, .name = "acid" }, .{ .bit = 0x01, .name = "liquid" } };
    for (tileset.tilesets) |ts| {
        const col = tileset.slice(rom, ts.collision) orelse return error.NoCollision;
        for (ts.gfx) |gfx| {
            var taken: [0x80]bool = @splat(false);
            for (kinds) |k| {
                try out.print("    .{{ .region = \"{s}\", .tiles = &.{{", .{gfx});
                var first = true;
                for (0..0x80) |id| {
                    if (taken[id] or col[id] & k.bit == 0) continue;
                    taken[id] = true;
                    try out.print("{s}0x{X:0>2}", .{ if (first) " " else ", ", id });
                    first = false;
                }
                try out.print(" }}, .slot = {s}_slot, .why = {s}_why }},\n", .{ k.name, k.name });
            }
        }
    }
}

/// `-- try`: each sprite in `ids` with every enemy sheet loaded, one row a
/// sheet in `swatch_full.enemy_sheets` order, to `try-<id>.png`.
fn tryRuns(a: std.mem.Allocator, io: std.Io, rom: []const u8, ids: []const u8, out: *std.Io.Writer) !void {
    const de = offsets.find("metasprite_enemies_data") orelse return error.UnresolvedSource;
    const data = rom[de.romOffset()..de.romEnd()];
    const recs_ms = try entity.parseMetasprites(a, data, de.gb_addr);
    const pe = offsets.find("metasprite_enemies_pointers") orelse return error.UnresolvedSource;
    const offs = try sprites.parsePointers(a, rom[pe.romOffset()..pe.romEnd()], de.gb_addr, data.len, recs_ms);
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);
    for (ids) |id| {
        const off = offs[id];
        if (off == sprites.dead_offset) continue;
        const m = for (recs_ms) |r| {
            if (r.gb_addr == de.gb_addr + off) break r;
        } else continue;
        const parts = try a.alloc(swatch.Part, m.parts.len);
        for (m.parts, parts) |q, *o| o.* = .{ .y = q.y, .x = q.x, .tile = q.tile, .attr = q.attr };
        var page: std.Io.Writer.Allocating = .init(a);
        try page.writer.writeAll("<title>try</title><body style=\"background:#fff\">");
        for (swatch.enemy_sheets) |spec| {
            if (!swatch.isEnemySheet(spec.name)) continue;
            const e = offsets.find(spec.name) orelse continue;
            const bytes = rom[e.romOffset()..e.romEnd()];
            var v: swatch.ObjVram = .{};
            for (0..@min(64, bytes.len / 16)) |t| {
                v.tiles[0xB0 + t] = bytes[t * 16 ..][0..16];
                v.slots[0xB0 + t] = full_slots.slot(spec.name, t) orelse 0;
            }
            const p = try swatch.spritePng(a, parts, &v, .full, 0) orelse continue;
            try dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "try-{X:0>2}-{s}.png", .{ id, spec.name["gfx_".len..] }), .data = p });
        }
        try out.print("try: ${X:0>2} with each sheet, {s}/try-{X:0>2}-*.png\n", .{ id, out_dir, id });
    }
}
