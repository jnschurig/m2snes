//! The sprite editor's data side (sprite-pixel-editor F6): what
//! `zig build sprite-editor` serves and what its save writes.
//!
//! The editor owns three data files and writes only them (`DataFile`):
//! - `full_colors.zon`: the object-side colours are patched in place, number
//!   literal by number literal (`patchColors`), so the hand comments and
//!   layout survive and the background's colours are never touched.
//! - `sprite_edits.zon` and `sprite_frames.zon`: written whole under a fixed
//!   header (`writeEdits`, `writeFrames`). They hold no hand comments.
//!
//! Every request reads the files from disk (`load`), so the page always shows
//! what the next `zig build` will use. A save is checked against the model
//! (`normalize`) before anything is written.

const std = @import("std");
const colors = @import("colors.zig");
const screens = @import("screens.zig");
const full_slots = @import("full_slots.zig");
const sprite_edits = @import("sprite_edits.zig");
const catalog = @import("sprite_catalog.zig");
const sprite_model = @import("sprite_model.zig");

/// The files the editor may write, relative to the repository root.
pub const DataFile = enum {
    colors,
    edits,
    frames,

    pub fn path(f: DataFile) []const u8 {
        return switch (f) {
            .colors => "src/data/full_colors.zon",
            .edits => "src/data/sprite_edits.zon",
            .frames => "src/data/sprite_frames.zon",
        };
    }
};

/// The colours the editor edits: `full_colors.zon`'s object side. A null
/// object palette is a suit's (1 and 7), which takes `suits`' colours.
pub const ObjColors = struct {
    obj: @FieldType(colors.FullData, "obj"),
    damage: @FieldType(colors.FullData, "damage"),
    suits: @FieldType(colors.FullData, "suits"),

    pub fn of(d: colors.FullData) ObjColors {
        return .{ .obj = d.obj, .damage = d.damage, .suits = d.suits };
    }
};

/// A tile edit as the page sends and receives it: the key in hex, since a
/// JavaScript number can't hold 64 bits.
pub const JsonEdit = struct {
    key: []const u8,
    palette: ?u3 = null,
    pixels: []const sprite_edits.Pixel = &.{},
};

/// The editable state: what `/api/model` serves beside the model, and what
/// `/api/save` takes.
pub const State = struct {
    colors: ObjColors,
    edits: []const JsonEdit,
    frames: []const catalog.Frame,
};

// ---- Reading the data files --------------------------------------------------

/// The three files as they are on disk now. Allocates from `a`: pass an arena.
/// On a ZON error, `diag` holds the file's path and the parser's message.
pub fn load(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, diag: *[]const u8) !State {
    const cs = try parseFile(colors.FullData, a, io, dir, .colors, diag);
    const es = try parseFile(sprite_edits.Edits, a, io, dir, .edits, diag);
    const fs = try parseFile(catalog.FrameData, a, io, dir, .frames, diag);
    const edits = try a.alloc(JsonEdit, es.tiles.len);
    for (es.tiles, edits) |t, *o| o.* = .{ .key = try keyHex(a, t.key), .palette = t.palette, .pixels = t.pixels };
    return .{ .colors = .of(cs), .edits = edits, .frames = fs.frames };
}

/// A data file's source, NUL-terminated for the ZON parser.
pub fn readSource(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, f: DataFile) ![:0]u8 {
    return dir.readFileAllocOptions(io, f.path(), a, .limited(16 << 20), .of(u8), 0);
}

fn parseFile(T: type, a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, f: DataFile, diag: *[]const u8) !T {
    const src = try readSource(a, io, dir, f);
    return parseZon(T, a, src, f.path(), diag);
}

fn parseZon(T: type, a: std.mem.Allocator, src: [:0]const u8, path: []const u8, diag: *[]const u8) !T {
    var d: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromSliceAlloc(T, a, src, &d, .{}) catch |e| {
        if (e == error.ParseZon) diag.* = try std.fmt.allocPrint(a, "{s}: {f}", .{ path, d });
        return e;
    };
}

fn keyHex(a: std.mem.Allocator, key: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "{x:0>16}", .{key});
}

// ---- The model, as the page reads it -----------------------------------------

/// The palettes a tile may take (F4): an enemy's never Samus's suit or visor,
/// and Samus's never 0 or 5, which her page draws as her suit anyway
/// (`full_slots.objAttr`).
pub const enemy_palettes = [_]u3{ 0, 2, 3, 4, 5, 6 };
pub const samus_palettes = [_]u3{ full_slots.samus_suit_palette, full_slots.samus_visor_palette, 2, 3, 4, 6 };

const JsonTile = struct {
    key: []const u8,
    /// The original 16 Game Boy bytes, in hex.
    gb: []const u8,
    copies: []const sprite_model.Copy,
    twin: bool,
    conflict: bool,
    /// Loaded by a view on Samus's page: may take `samus_palettes`.
    samus: bool,
};

const JsonModel = struct {
    rom_sha1: []const u8,
    /// OBP0 as the cart sets it: a pixel's colour `c` is shade
    /// `obp0 >> 2 * (c & 3) & 3` of variant `c >> 2`.
    obp0: u8,
    /// `full_slots.objAttrPages()`: the OAM attribute of page `p`, Game Boy
    /// attribute high nibble `h` and slot `s`, at `p * 256 + h | s`.
    obj_attr: []const u16,
    pages: struct { full: u8, metroid_hit: u8, frozen: u8, samus: u8 },
    enemy_palettes: []const u3,
    samus_palettes: []const u3,
    tiles: []const JsonTile,
    sheets: []const sprite_model.Sheet,
    views: []const sprite_model.View,
    frames: []const sprite_model.Frame,
    conflicts: []const u32,
};

/// Each model tile's index is loaded by a view on Samus's page.
pub fn samusTiles(a: std.mem.Allocator, m: *const sprite_model.Model) ![]bool {
    const out = try a.alloc(bool, m.tiles.len);
    @memset(out, false);
    for (m.views) |v| {
        if (v.page != .samus) continue;
        for (v.vram) |s| if (s) |x| {
            out[x.tile] = true;
        };
    }
    return out;
}

/// The model as `/api/model`'s `model`. `m` is built with no frame overrides:
/// the page applies the state's `frames` itself, so a removed name goes away.
pub fn modelJson(a: std.mem.Allocator, m: *const sprite_model.Model, rom_sha1: []const u8) ![]u8 {
    const samus = try samusTiles(a, m);
    const tiles = try a.alloc(JsonTile, m.tiles.len);
    for (m.tiles, tiles, samus) |t, *o, s| o.* = .{
        .key = try keyHex(a, t.key),
        .gb = try a.dupe(u8, &std.fmt.bytesToHex(t.gb.*, .lower)),
        .copies = t.copies,
        .twin = t.twin,
        .conflict = t.conflict,
        .samus = s,
    };
    const pages = full_slots.objAttrPages();
    const attr = try a.alloc(u16, pages.len);
    for (pages, attr) |p, *o| o.* = p;
    const jm: JsonModel = .{
        .rom_sha1 = rom_sha1,
        .obp0 = screens.live_obp0,
        .obj_attr = attr,
        .pages = .{
            .full = @intFromEnum(full_slots.ObjPage.full),
            .metroid_hit = @intFromEnum(full_slots.ObjPage.metroid_hit),
            .frozen = @intFromEnum(full_slots.ObjPage.frozen),
            .samus = @intFromEnum(full_slots.ObjPage.samus),
        },
        .enemy_palettes = &enemy_palettes,
        .samus_palettes = &samus_palettes,
        .tiles = tiles,
        .sheets = m.sheets,
        .views = m.views,
        .frames = m.frames,
        .conflicts = m.conflicts,
    };
    return std.json.Stringify.valueAlloc(a, jm, .{});
}

// ---- Checking a save -----------------------------------------------------------

/// A save, checked and in the form the files hold it.
pub const Normalized = struct {
    colors: ObjColors,
    /// Sorted by key; no entry without a change.
    edits: []const sprite_edits.Tile,
    /// Sorted by set then id; no entry without a name, group or sheet.
    frames: []const catalog.Frame,
};

pub const SaveError = error{BadSave};

/// Checks `s` against the model and puts it in file form: the same checks the
/// converter makes (`sprite_edits.Index`), and the palette (F4), colour and
/// frame rules besides. Pixels set to the tile's original index are dropped. On
/// `BadSave`, `why` says what was wrong.
pub fn normalize(a: std.mem.Allocator, m: *const sprite_model.Model, samus: []const bool, s: State, why: *[]const u8) !Normalized {
    const bad = struct {
        fn f(al: std.mem.Allocator, w: *[]const u8, comptime fmt: []const u8, args: anytype) !Normalized {
            w.* = try std.fmt.allocPrint(al, fmt, args);
            return SaveError.BadSave;
        }
    }.f;

    // Colours: each one the SNES shows, written as `colors.rgb888` writes it,
    // and the suit palettes still the suits'.
    for (s.colors.obj, 0..) |p, i| {
        const suit = i == full_slots.samus_suit_palette or i == full_slots.samus_visor_palette;
        if ((p == null) != suit) return bad(a, why, "colours: object palette {d} must {s}be null", .{ i, if (suit) "" else "not " });
    }
    {
        var all: std.ArrayList(colors.Rgb16) = .empty;
        for (s.colors.obj) |p| if (p) |x| try all.append(a, x);
        try all.appendSlice(a, &s.colors.damage);
        for (s.colors.suits) |pair| try all.appendSlice(a, &pair);
        for (all.items) |t| for (t) |row| for (row) |c| {
            if (colors.rgb888(colors.bgr555(c)) != c) return bad(a, why, "colours: 0x{X:0>6} is not a BGR555 colour", .{c});
        };
    }

    // Edits.
    var by_key: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    for (m.tiles, 0..) |t, i| try by_key.put(a, t.key, @intCast(i));
    var edits: std.ArrayList(sprite_edits.Tile) = .empty;
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (s.edits) |e| {
        const key = std.fmt.parseInt(u64, e.key, 16) catch return bad(a, why, "edits: bad key \"{s}\"", .{e.key});
        const ti = by_key.get(key) orelse return bad(a, why, "edits: key {s} matches no sprite tile", .{e.key});
        if ((try seen.getOrPut(a, key)).found_existing) return bad(a, why, "edits: key {s} twice", .{e.key});
        if (e.palette) |p| {
            const allowed: []const u3 = if (samus[ti]) &samus_palettes else &enemy_palettes;
            if (std.mem.indexOfScalar(u3, allowed, p) == null)
                return bad(a, why, "edits: tile {s} can't take palette {d} ({s} tile)", .{ e.key, p, if (samus[ti]) "a Samus" else "an enemy" });
        }
        var pixels: std.ArrayList(sprite_edits.Pixel) = .empty;
        var at: [64]bool = @splat(false);
        for (e.pixels) |p| {
            if (!sprite_edits.usable(p.index)) return bad(a, why, "edits: tile {s} pixel ({d},{d}) takes unused index {d}", .{ e.key, p.x, p.y, p.index });
            const n = @as(usize, p.y) * 8 + p.x;
            if (at[n]) return bad(a, why, "edits: tile {s} pixel ({d},{d}) twice", .{ e.key, p.x, p.y });
            at[n] = true;
            if (p.index == original(m.tiles[ti].gb, p.x, p.y)) continue;
            try pixels.append(a, p);
        }
        if (e.palette == null and pixels.items.len == 0) continue;
        std.mem.sort(sprite_edits.Pixel, pixels.items, {}, struct {
            fn lt(_: void, x: sprite_edits.Pixel, y: sprite_edits.Pixel) bool {
                return @as(u8, x.y) * 8 + x.x < @as(u8, y.y) * 8 + y.x;
            }
        }.lt);
        try edits.append(a, .{ .key = key, .palette = e.palette, .pixels = pixels.items });
    }
    std.mem.sort(sprite_edits.Tile, edits.items, {}, struct {
        fn lt(_: void, x: sprite_edits.Tile, y: sprite_edits.Tile) bool {
            return x.key < y.key;
        }
    }.lt);

    // Frames.
    var frames: std.ArrayList(catalog.Frame) = .empty;
    var seen_f: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (s.frames) |f| {
        const set = std.meta.stringToEnum(sprite_model.FrameSet, f.set) orelse return bad(a, why, "frames: unknown set \"{s}\"", .{f.set});
        if (f.id > 0xFF or m.frame(set, @intCast(f.id)) == null) return bad(a, why, "frames: no {s} frame ${X:0>2}", .{ f.set, f.id });
        if ((try seen_f.getOrPut(a, @as(u32, @intFromEnum(set)) << 16 | f.id)).found_existing) return bad(a, why, "frames: {s} ${X:0>2} twice", .{ f.set, f.id });
        if (f.sheet) |sh| if (m.viewIndex(sh) == null) return bad(a, why, "frames: {s} ${X:0>2}: no sheet \"{s}\"", .{ f.set, f.id, sh });
        const out: catalog.Frame = .{ .set = @tagName(set), .id = f.id, .name = nonEmpty(f.name), .group = nonEmpty(f.group), .sheet = nonEmpty(f.sheet) };
        if (out.name == null and out.group == null and out.sheet == null) continue;
        try frames.append(a, out);
    }
    std.mem.sort(catalog.Frame, frames.items, {}, struct {
        fn lt(_: void, x: catalog.Frame, y: catalog.Frame) bool {
            const sx = @intFromEnum(std.meta.stringToEnum(sprite_model.FrameSet, x.set).?);
            const sy = @intFromEnum(std.meta.stringToEnum(sprite_model.FrameSet, y.set).?);
            return if (sx != sy) sx < sy else x.id < y.id;
        }
    }.lt);

    return .{ .colors = s.colors, .edits = edits.items, .frames = frames.items };
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const x = s orelse return null;
    return if (x.len == 0) null else x;
}

/// A Game Boy tile's pixel: its 2bpp index.
fn original(gb: *const [16]u8, x: u3, y: u3) u4 {
    const shift: u3 = 7 - x;
    const row = @as(usize, y) * 2;
    return @intCast((gb[row] >> shift & 1) | (gb[row + 1] >> shift & 1) << 1);
}

// ---- Writing the data files ----------------------------------------------------

const edits_header =
    \\// The sprite editor's pixel edits and palette choices (`src/sprite_edits.zig`),
    \\// written whole by `zig build sprite-editor`: comments added here are lost on
    \\// its next save. One entry per unique Game Boy tile, keyed by
    \\// `sprite_edits.tileKey` of its original 16 bytes; no tile bytes are stored.
    \\// `palette` is the tile's OBJ palette slot where it differs from the derived
    \\// one, and each pixel's `index` its 4bpp colour (shade `index & 3`, never 4,
    \\// 8 or 12). `rom_sha1` is the ROM the keys were taken from, checked whenever
    \\// `tiles` is non-empty.
    \\
;

const frames_header =
    \\// The sprite editor's frame names and groups, and the sheet chosen for a frame
    \\// the model can't resolve (`sprite_catalog.Frame`), written whole by
    \\// `zig build sprite-editor`: comments added here are lost on its next save.
    \\// `set` is the sprite table (`samus` or `enemy`) and `id` the metasprite.
    \\
;

/// `sprite_edits.zon` for `edits` (sorted, as `normalize` leaves them). The ROM
/// hash is written only with edits, so an empty file needs none.
pub fn writeEdits(a: std.mem.Allocator, edits: []const sprite_edits.Tile, rom_sha1: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(edits_header);
    try w.print(".{{\n    .rom_sha1 = \"{s}\",\n", .{if (edits.len == 0) "" else rom_sha1});
    if (edits.len == 0) {
        try w.writeAll("    .tiles = .{},\n}\n");
        return out.toOwnedSlice();
    }
    try w.writeAll("    .tiles = .{\n");
    for (edits) |t| {
        try w.print("        .{{\n            .key = 0x{X:0>16},\n", .{t.key});
        if (t.palette) |p| try w.print("            .palette = {d},\n", .{p});
        if (t.pixels.len > 0) {
            try w.writeAll("            .pixels = .{\n");
            for (t.pixels) |p| try w.print("                .{{ .x = {d}, .y = {d}, .index = {d} }},\n", .{ p.x, p.y, p.index });
            try w.writeAll("            },\n");
        }
        try w.writeAll("        },\n");
    }
    try w.writeAll("    },\n}\n");
    return out.toOwnedSlice();
}

/// `sprite_frames.zon` for `frames` (sorted, as `normalize` leaves them).
pub fn writeFrames(a: std.mem.Allocator, frames: []const catalog.Frame) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(frames_header);
    if (frames.len == 0) {
        try w.writeAll(".{\n    .frames = .{},\n}\n");
        return out.toOwnedSlice();
    }
    try w.writeAll(".{\n    .frames = .{\n");
    for (frames) |f| {
        try w.print("        .{{ .set = \"{s}\", .id = 0x{X:0>2}", .{ f.set, f.id });
        if (f.name) |n| try w.print(", .name = \"{f}\"", .{std.zig.fmtString(n)});
        if (f.group) |g| try w.print(", .group = \"{f}\"", .{std.zig.fmtString(g)});
        if (f.sheet) |s| try w.print(", .sheet = \"{f}\"", .{std.zig.fmtString(s)});
        try w.writeAll(" },\n");
    }
    try w.writeAll("    },\n}\n");
    return out.toOwnedSlice();
}

/// `full_colors.zon` with its object-side colours set to `new`: each number
/// literal whose value changes is rewritten as `0xRRGGBB`, and every other
/// byte (comments, layout, the background's colours) is left as it was.
pub fn patchColors(a: std.mem.Allocator, src: [:0]const u8, new: ObjColors) ![]u8 {
    var ast = try std.zig.Ast.parse(a, src, .zon);
    defer ast.deinit(a);
    const zoir = try std.zig.ZonGen.generate(a, ast, .{ .parse_str_lits = false });
    defer zoir.deinit(a);
    if (zoir.hasCompileErrors()) return error.ParseZon;

    const Patch = struct { start: usize, len: usize, value: u24 };
    var patches: std.ArrayList(Patch) = .empty;
    const P = struct {
        ast: *const std.zig.Ast,
        zoir: std.zig.Zoir,
        patches: *std.ArrayList(Patch),
        a: std.mem.Allocator,
        const Z = std.zig.Zoir.Node;

        fn field(p: @This(), n: Z.Index, name: []const u8) !Z.Index {
            const s = switch (n.get(p.zoir)) {
                .struct_literal => |s| s,
                else => return error.ColorsShape,
            };
            for (s.names, 0..) |nm, i| if (std.mem.eql(u8, nm.get(p.zoir), name)) return s.vals.at(@intCast(i));
            return error.ColorsShape;
        }

        fn elems(p: @This(), n: Z.Index, len: usize) !Z.Index.Range {
            const r = switch (n.get(p.zoir)) {
                .array_literal => |r| r,
                else => return error.ColorsShape,
            };
            if (r.len != len) return error.ColorsShape;
            return r;
        }

        fn rgb16(p: @This(), n: Z.Index, t: colors.Rgb16) !void {
            const rows = try p.elems(n, colors.variants);
            for (t, 0..) |row, v| {
                const cs = try p.elems(rows.at(@intCast(v)), 4);
                for (row, 0..) |c, i| try p.colour(cs.at(@intCast(i)), c);
            }
        }

        fn colour(p: @This(), n: Z.Index, c: u24) !void {
            const old: i64 = switch (n.get(p.zoir)) {
                .int_literal => |x| switch (x) {
                    .small => |v| v,
                    .big => return error.ColorsShape,
                },
                else => return error.ColorsShape,
            };
            if (old == c) return;
            const tok = p.ast.nodeMainToken(n.getAstNode(p.zoir));
            try p.patches.append(p.a, .{ .start = p.ast.tokenStart(tok), .len = p.ast.tokenSlice(tok).len, .value = c });
        }
    };
    const p: P = .{ .ast = &ast, .zoir = zoir, .patches = &patches, .a = a };
    const root: P.Z.Index = .root;

    const obj = try p.elems(try p.field(root, "obj"), new.obj.len);
    for (new.obj, 0..) |t, i| {
        const n = obj.at(@intCast(i));
        if (t) |x| try p.rgb16(n, x) else if (n.get(zoir) != .null) return error.ColorsShape;
    }
    const damage = try p.elems(try p.field(root, "damage"), new.damage.len);
    for (new.damage, 0..) |t, i| try p.rgb16(damage.at(@intCast(i)), t);
    const suits = try p.elems(try p.field(root, "suits"), new.suits.len);
    for (new.suits, 0..) |pair, si| {
        const ts = try p.elems(suits.at(@intCast(si)), pair.len);
        for (pair, 0..) |t, i| try p.rgb16(ts.at(@intCast(i)), t);
    }

    std.mem.sort(Patch, patches.items, {}, struct {
        fn lt(_: void, x: Patch, y: Patch) bool {
            return x.start < y.start;
        }
    }.lt);
    var out: std.Io.Writer.Allocating = .init(a);
    var at: usize = 0;
    for (patches.items) |q| {
        try out.writer.writeAll(src[at..q.start]);
        try out.writer.print("0x{X:0>6}", .{q.value});
        at = q.start + q.len;
    }
    try out.writer.writeAll(src[at..]);
    return out.toOwnedSlice();
}

// ---- Requests ----------------------------------------------------------------

/// Whether a request comes from the editor's own page: its `Host` is the
/// listener's loopback address, and its `Origin`, when it sends one, too. A
/// page elsewhere (or DNS rebinding to 127.0.0.1) fails one or the other.
pub fn localRequest(host: ?[]const u8, origin: ?[]const u8, port: u16) bool {
    var buf: [2][32]u8 = undefined;
    const hosts = [_][]const u8{
        std.fmt.bufPrint(&buf[0], "127.0.0.1:{d}", .{port}) catch unreachable,
        std.fmt.bufPrint(&buf[1], "localhost:{d}", .{port}) catch unreachable,
    };
    const h = host orelse return false;
    const host_ok = for (hosts) |x| {
        if (std.ascii.eqlIgnoreCase(h, x)) break true;
    } else false;
    if (!host_ok) return false;
    const o = origin orelse return true;
    if (!std.mem.startsWith(u8, o, "http://")) return false;
    for (hosts) |x| if (std.ascii.eqlIgnoreCase(o["http://".len..], x)) return true;
    return false;
}

// ---- Tests -------------------------------------------------------------------

const testing = std.testing;

test "localRequest: only the listener's own loopback host and origin" {
    try testing.expect(localRequest("127.0.0.1:8080", null, 8080));
    try testing.expect(localRequest("localhost:8080", "http://localhost:8080", 8080));
    try testing.expect(localRequest("localhost:8080", "http://127.0.0.1:8080", 8080));
    try testing.expect(!localRequest(null, null, 8080));
    try testing.expect(!localRequest("127.0.0.1:8081", null, 8080));
    try testing.expect(!localRequest("evil.example:8080", null, 8080));
    try testing.expect(!localRequest("127.0.0.1:8080", "http://evil.example", 8080));
    try testing.expect(!localRequest("127.0.0.1:8080", "https://127.0.0.1:8080", 8080));
    try testing.expect(!localRequest("127.0.0.1:8080", "null", 8080));
}

test "writeEdits and writeFrames: the committed files are what they write (a no-op save is a no-op)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var why: []const u8 = "";
    const es_src = try readSource(a, io, std.Io.Dir.cwd(), .edits);
    const es = try parseZon(sprite_edits.Edits, a, es_src, "edits", &why);
    try testing.expectEqualStrings(es_src, try writeEdits(a, es.tiles, es.rom_sha1));
    const fs_src = try readSource(a, io, std.Io.Dir.cwd(), .frames);
    const fs = try parseZon(catalog.FrameData, a, fs_src, "frames", &why);
    try testing.expectEqualStrings(fs_src, try writeFrames(a, fs.frames));
    // And the colours, patched with what they hold, are unchanged.
    const cs_src = try readSource(a, io, std.Io.Dir.cwd(), .colors);
    const cs = try parseZon(colors.FullData, a, cs_src, "colors", &why);
    try testing.expectEqualStrings(cs_src, try patchColors(a, cs_src, .of(cs)));
}

test "writeEdits and writeFrames round-trip through the ZON parser" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const edits = [_]sprite_edits.Tile{
        .{ .key = 0x0123_4567_89AB_CDEF, .palette = 5, .pixels = &.{ .{ .x = 0, .y = 0, .index = 15 }, .{ .x = 7, .y = 3, .index = 0 } } },
        .{ .key = 0xFEDC_BA98_7654_3210, .pixels = &.{.{ .x = 2, .y = 7, .index = 9 }} },
        .{ .key = 0xFFFF_FFFF_FFFF_FFFF, .palette = 0 },
    };
    const e_src = try a.dupeZ(u8, try writeEdits(a, &edits, "abc123"));
    const e = try parseZon(sprite_edits.Edits, a, e_src, "edits", &why);
    try testing.expectEqualStrings("abc123", e.rom_sha1);
    try testing.expectEqualDeep(@as([]const sprite_edits.Tile, &edits), e.tiles);
    try testing.expectEqualStrings(e_src, try writeEdits(a, e.tiles, e.rom_sha1));

    const frames = [_]catalog.Frame{
        .{ .set = "samus", .id = 0x03, .name = "standing, \"facing\" right" },
        .{ .set = "enemy", .id = 0x14, .group = "Hornoad", .sheet = "gfx_enemiesA" },
    };
    const f_src = try a.dupeZ(u8, try writeFrames(a, &frames));
    const f = try parseZon(catalog.FrameData, a, f_src, "frames", &why);
    try testing.expectEqualDeep(@as([]const catalog.Frame, &frames), f.frames);
}

test "patchColors rewrites only the changed literal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const src = try readSource(a, testing.io, std.Io.Dir.cwd(), .colors);
    const before = try parseZon(colors.FullData, a, src, "colors", &why);
    var new: ObjColors = .of(before);
    new.obj[5].?[2][1] = 0x08F7FF; // variant 2's middle shade of the organic palette
    new.suits[1][0][3][0] = 0xFFFFFF;
    const out = try a.dupeZ(u8, try patchColors(a, src, new));
    // Every byte but the two literals' is the same: the diff is two spans.
    var diffs: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len and j < out.len) {
        if (src[i] == out[j]) {
            i += 1;
            j += 1;
            continue;
        }
        diffs += 1;
        // Skip both literals' remaining hex digits.
        while (i < src.len and std.ascii.isHex(src[i])) i += 1;
        while (j < out.len and std.ascii.isHex(out[j])) j += 1;
    }
    try testing.expectEqual(@as(usize, 2), diffs);
    try testing.expectEqual(src.len, out.len);
    const after = try parseZon(colors.FullData, a, out, "colors", &why);
    try testing.expectEqualDeep(new, ObjColors.of(after));
    try testing.expectEqualDeep(before.bg, after.bg);
    try testing.expectEqualDeep(before.window, after.window);
}

/// A model of two tiles, one of them Samus's, and one frame of each set.
fn testModel(a: std.mem.Allocator) !sprite_model.Model {
    const gb = try a.create([2][16]u8);
    gb[0] = @splat(0);
    gb[1] = @splat(0xFF); // every pixel index 3
    const tiles = try a.alloc(sprite_model.Tile, 2);
    for (tiles, 0..) |*t, i| t.* = .{ .key = sprite_edits.tileKey(&gb[i]), .gb = &gb[i], .copies = &.{}, .twin = false, .conflict = false };
    const views = try a.alloc(sprite_model.View, 2);
    views[0] = .{ .name = "samus", .title = "", .page = .samus };
    views[0].vram[0] = .{ .tile = 1, .slot = 1 };
    views[1] = .{ .name = "enemy", .title = "", .page = .full };
    views[1].vram[0xB0] = .{ .tile = 0, .slot = 5 };
    const frames = try a.alloc(sprite_model.Frame, 2);
    frames[0] = .{ .set = .samus, .id = 3, .parts = &.{}, .view = 0 };
    frames[1] = .{ .set = .enemy, .id = 0x14, .parts = &.{}, .view = 1 };
    return .{ .tiles = tiles, .sheets = &.{}, .views = views, .frames = frames, .conflicts = &.{} };
}

test "normalize rejects a bad index, palette, key, colour or frame, and drops no-ops" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try testModel(a);
    const samus = try samusTiles(a, &m);
    try testing.expectEqualSlices(bool, &.{ false, true }, samus);
    const enemy_key = try keyHex(a, m.tiles[0].key);
    const samus_key = try keyHex(a, m.tiles[1].key);
    const good: State = .{ .colors = .of(colors.full_data), .edits = &.{}, .frames = &.{} };
    var why: []const u8 = "";

    const n0 = try normalize(a, &m, samus, good, &why);
    try testing.expectEqual(@as(usize, 0), n0.edits.len + n0.frames.len);

    const Case = struct { s: State, want: []const u8 };
    var bad_colors = good.colors;
    bad_colors.obj[0].?[0][0] = 0x123456;
    var null_colors = good.colors;
    null_colors.obj[0] = null;
    const cases = [_]Case{
        .{ .s = .{ .colors = good.colors, .edits = &.{.{ .key = enemy_key, .pixels = &.{.{ .x = 1, .y = 1, .index = 8 }} }}, .frames = &.{} }, .want = "unused index 8" },
        .{ .s = .{ .colors = good.colors, .edits = &.{.{ .key = enemy_key, .palette = 1 }}, .frames = &.{} }, .want = "can't take palette 1" },
        .{ .s = .{ .colors = good.colors, .edits = &.{.{ .key = enemy_key, .palette = 7 }}, .frames = &.{} }, .want = "can't take palette 7" },
        .{ .s = .{ .colors = good.colors, .edits = &.{.{ .key = samus_key, .palette = 0 }}, .frames = &.{} }, .want = "can't take palette 0" },
        .{ .s = .{ .colors = good.colors, .edits = &.{.{ .key = "00000000000000aa" }}, .frames = &.{} }, .want = "matches no sprite tile" },
        .{ .s = .{ .colors = good.colors, .edits = &.{.{ .key = "xyz" }}, .frames = &.{} }, .want = "bad key" },
        .{ .s = .{ .colors = good.colors, .edits = &.{ .{ .key = enemy_key, .palette = 2 }, .{ .key = enemy_key, .palette = 3 } }, .frames = &.{} }, .want = "twice" },
        .{ .s = .{ .colors = good.colors, .edits = &.{.{ .key = enemy_key, .pixels = &.{ .{ .x = 1, .y = 1, .index = 5 }, .{ .x = 1, .y = 1, .index = 6 } } }}, .frames = &.{} }, .want = "pixel (1,1) twice" },
        .{ .s = .{ .colors = bad_colors, .edits = &.{}, .frames = &.{} }, .want = "not a BGR555 colour" },
        .{ .s = .{ .colors = null_colors, .edits = &.{}, .frames = &.{} }, .want = "palette 0 must not be null" },
        .{ .s = .{ .colors = good.colors, .edits = &.{}, .frames = &.{.{ .set = "enemy", .id = 0x15, .name = "x" }} }, .want = "no enemy frame $15" },
        .{ .s = .{ .colors = good.colors, .edits = &.{}, .frames = &.{.{ .set = "boss", .id = 0x14 }} }, .want = "unknown set" },
        .{ .s = .{ .colors = good.colors, .edits = &.{}, .frames = &.{.{ .set = "enemy", .id = 0x14, .sheet = "gfx_nope" }} }, .want = "no sheet" },
    };
    for (cases) |c| {
        why = "";
        try testing.expectError(SaveError.BadSave, normalize(a, &m, samus, c.s, &why));
        if (std.mem.indexOf(u8, why, c.want) == null) {
            std.debug.print("want \"{s}\" in \"{s}\"\n", .{ c.want, why });
            return error.TestUnexpectedResult;
        }
    }

    // A pixel set to its original index is dropped, and an entry left with
    // nothing goes; empty names do too. What's left is sorted.
    const n = try normalize(a, &m, samus, .{ .colors = good.colors, .edits = &.{
        .{ .key = samus_key, .pixels = &.{.{ .x = 0, .y = 0, .index = 3 }} },
        .{ .key = enemy_key, .pixels = &.{ .{ .x = 7, .y = 7, .index = 0 }, .{ .x = 2, .y = 1, .index = 13 }, .{ .x = 1, .y = 0, .index = 6 } } },
    }, .frames = &.{
        .{ .set = "enemy", .id = 0x14, .name = "Hornoad" },
        .{ .set = "samus", .id = 3, .name = "" },
    } }, &why);
    try testing.expectEqual(@as(usize, 1), n.edits.len);
    try testing.expectEqual(m.tiles[0].key, n.edits[0].key);
    try testing.expectEqualDeep(@as([]const sprite_edits.Pixel, &.{ .{ .x = 1, .y = 0, .index = 6 }, .{ .x = 2, .y = 1, .index = 13 } }), n.edits[0].pixels);
    try testing.expectEqual(@as(usize, 1), n.frames.len);
    try testing.expectEqualStrings("Hornoad", n.frames[0].name.?);
}

test "modelJson: the page's model, from the ROM" {
    const testrom = @import("testrom");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const snes_convert = @import("snes_convert.zig");
    var set = try snes_convert.run(a, rom);
    defer set.deinit();
    const m = try sprite_model.build(a, rom, set.assets, &.{});
    const text = try modelJson(a, &m, "sha");
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    const o = v.object;
    for ([_][]const u8{ "rom_sha1", "obp0", "obj_attr", "pages", "enemy_palettes", "samus_palettes", "tiles", "sheets", "views", "frames", "conflicts" }) |k| {
        if (o.get(k) == null) {
            std.debug.print("model JSON lacks \"{s}\"\n", .{k});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(m.tiles.len, o.get("tiles").?.array.items.len);
    try testing.expectEqual(full_slots.page_count * 256, o.get("obj_attr").?.array.items.len);
    const t0 = o.get("tiles").?.array.items[0].object;
    try testing.expectEqual(@as(usize, 16), t0.get("key").?.string.len);
    try testing.expectEqual(@as(usize, 32), t0.get("gb").?.string.len);
    const v0 = o.get("views").?.array.items[0].object;
    try testing.expectEqualStrings("samus", v0.get("page").?.string);
    try testing.expectEqual(@as(usize, 256), v0.get("vram").?.array.items.len);
    const f0 = o.get("frames").?.array.items[0].object;
    try testing.expectEqualStrings("samus", f0.get("set").?.string);
    try testing.expect(f0.get("parts").?.array.items.len > 0);
    // And it reads back as the page's state types expect.
    _ = try std.json.parseFromSliceLeaky(State, a,
        \\{"colors":{"obj":[null,null,null,null,null,null,null,null],"damage":[[[0,0,0,0],[0,0,0,0],[0,0,0,0],[0,0,0,0]],[[0,0,0,0],[0,0,0,0],[0,0,0,0],[0,0,0,0]],[[0,0,0,0],[0,0,0,0],[0,0,0,0],[0,0,0,0]]],"suits":[[[[0,0,0,0],[0,0,0,0],[0,0,0,0],[0,0,0,0]],[[0,0,0,0],[0,0,0,0],[0,0,0,0],[0,0,0,0]]],[[[0,0,0,0],[0,0,0,0],[0,0,0,0],[0,0,0,0]],[[0,0,0,0],[0,0,0,0],[0,0,0,0],[0,0,0,0]]]]},"edits":[{"key":"0123456789abcdef","palette":3,"pixels":[{"x":1,"y":2,"index":5}]}],"frames":[{"set":"enemy","id":20,"name":"x","group":null,"sheet":null}]}
    , .{});
}
