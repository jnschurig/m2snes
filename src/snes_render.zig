//! Rasterize a screen from *converted* assets, so it can be diffed against the
//! Game Boy reference frames Step 7 produced.
//!
//! This is the check the conversion was written to face. Every round-trip test
//! in `snes_convert.zig` proves a converter and its inverse agree with each
//! other, which a pair of mirrored bugs would also pass. This one runs the
//! converted bytes through a model of the hardware that will actually read them
//! and compares the pixels against a renderer that shares no code with it.
//!
//! ## What is modelled, and what is a comparison accommodation
//!
//! Modelled, because the engine will do it: the converted door bytecode is
//! decoded and replayed into a 32K-word VRAM image; characters are read as SNES
//! 2bpp out of BG3's character region; metatiles are read as SNES tilemap words
//! and their character, palette, and flip fields are all honoured.
//!
//! Accommodations, so the two sides are comparable at all:
//!
//!  - **Shade indexes, not colours.** `renderScreen` takes a four-entry palette
//!    of DMG shades standing in for CGRAM. The engine will write real 15-bit
//!    colours; what is compared here is which of the four the pixel selected,
//!    which is the only thing the Game Boy frame knows.
//!  - **Character `$FF` draws as colour 0.** `screens.renderScreen` does this
//!    for VRAM no door wrote, and the reference frames carry it. It is a
//!    property of the reference, not of the data - `gfx_commonItems` writes
//!    `$FF` outright - so it is repeated here rather than removed from there.
//!  - **The whole 256x256 screen**, not the 160x144 play window. The plan's
//!    sub-task says the play window; Step 7 rendered full screens on purpose,
//!    because a screen is four times the window and diffing only what fits on
//!    the Game Boy at once would leave most of every room unchecked. The
//!    reference is what it is, so this follows it.

const std = @import("std");
const door = @import("door.zig");
const map = @import("map.zig");

const tileset = @import("tileset.zig");
const target = @import("snes_target.zig");
const chr = @import("snes_chr.zig");
const convert = @import("snes_convert.zig");
const engine = @import("snes_screen.zig");
const screens = @import("screens.zig");

pub const Error = error{
    /// An opcode the converted encoding does not allocate. `$B0`-`$BF` is the
    /// live case: `LOAD` became a `COPY`, so seeing one means the stream was
    /// produced by an older converter.
    UnknownOpcode,
    /// An operand ran off the end of the stream.
    TruncatedOperand,
    /// A converted `COPY` names an asset id that is not in the set.
    UnknownAsset,
    /// A copy whose source offset and length run past the end of its asset.
    SourceOutOfRange,
} || convert.Error;

// ---- The converted bytecode, read back -------------------------------------

/// One converted operation. Only the ones that move bytes carry operands worth
/// modelling here; the rest are recognised so the stream stays in step.
pub const Op = union(enum) {
    copy: struct { class: convert.CopyClass, asset: u8, offset: u16, dest: u16, words: u16, gb_bank: u8, gb_addr: u16 },
    tiletable: u4,
    collision: u4,
    solidity: u4,
    warp: struct { bank: u4, pos: u8 },
    enter_queen: u4,
    damage,
    if_met_less,
    escape_queen,
    exit_queen,
    fadeout,
    song: u4,
    item: u4,
    end,
};

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn u8_(self: *Reader) Error!u8 {
        if (self.pos >= self.bytes.len) return Error.TruncatedOperand;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }
    fn u16_(self: *Reader) Error!u16 {
        const lo = try self.u8_();
        const hi = try self.u8_();
        return @as(u16, lo) | (@as(u16, hi) << 8);
    }
};

/// Decode one converted operation. The dispatch is deliberately the same shape
/// as `door.decodeOne`: the whole point of keeping the opcode nibbles is that
/// the engine's dispatcher can stay the shape of 0:`$239C`.
pub fn decodeOne(r: *Reader) Error!Op {
    const opcode = try r.u8_();
    if (opcode == door.terminator) return .end;
    const low: u4 = @truncate(opcode);
    return switch (opcode >> 4) {
        0x0 => .{ .copy = .{
            .class = switch (low) {
                0 => .data,
                1 => .bg,
                2 => .obj,
                // The background half of a `spr` transfer. Same destination
                // region and same bytes as `bg`; what the class carries is
                // that the Game Boy paid for it once, so the engine's frame
                // cost charges it nothing. Nothing here has to care -- the
                // reference renderer stores the bytes either way -- and that
                // it does not is the point: a class that changed where the
                // bytes went would have to be handled twice.
                3 => .bg_twin,
                else => return Error.UnknownOpcode,
            },
            .asset = try r.u8_(),
            .offset = try r.u16_(),
            .dest = try r.u16_(),
            .words = try r.u16_(),
            .gb_bank = try r.u8_(),
            .gb_addr = try r.u16_(),
        } },
        0x1 => .{ .tiletable = low },
        0x2 => .{ .collision = low },
        0x3 => .{ .solidity = low },
        0x4 => .{ .warp = .{ .bank = low, .pos = try r.u8_() } },
        0x5 => .escape_queen,
        0x6 => blk: {
            _ = try r.u16_();
            break :blk .damage;
        },
        0x7 => .exit_queen,
        0x8 => blk: {
            for (0..4) |_| _ = try r.u16_();
            break :blk .{ .enter_queen = low };
        },
        0x9 => blk: {
            _ = try r.u8_();
            _ = try r.u16_();
            break :blk .if_met_less;
        },
        0xA => .fadeout,
        0xC => .{ .song = low },
        0xD => .{ .item = low },
        else => Error.UnknownOpcode,
    };
}

// ---- VRAM ------------------------------------------------------------------

/// A 32K-word VRAM image. `written` exists for the same reason it does on the
/// Game Boy side: a character no script loaded should be visible as such rather
/// than silently reading as zeros.
pub const Vram = struct {
    words: [target.vram_words]u16 = @splat(0),
    written: [target.vram_words]bool = @splat(false),

    pub fn store(self: *Vram, word_addr: u16, bytes: []const u8) void {
        const n = @min(bytes.len / 2, self.words.len - word_addr);
        for (0..n) |i| {
            self.words[word_addr + i] = @as(u16, bytes[i * 2]) | (@as(u16, bytes[i * 2 + 1]) << 8);
            self.written[word_addr + i] = true;
        }
    }

    /// The eight words of BG3 character `c`, as the sixteen bytes a 2bpp
    /// decoder wants.
    pub fn charBytes(self: Vram, c: u10) [16]u8 {
        var out: [16]u8 = undefined;
        const base = target.bg3_char_base + @as(usize, c) * target.charWords(target.play_depth);
        for (0..8) |i| {
            out[i * 2] = @truncate(self.words[base + i]);
            out[i * 2 + 1] = @truncate(self.words[base + i] >> 8);
        }
        return out;
    }

    pub fn charWritten(self: Vram, c: u10) bool {
        const base = target.bg3_char_base + @as(usize, c) * target.charWords(target.play_depth);
        for (0..target.charWords(target.play_depth)) |i| {
            if (!self.written[base + i]) return false;
        }
        return true;
    }
};

/// Replay one converted script's copies into a fresh VRAM image.
pub fn vramFor(set: convert.Set, script: []const u8) Error!Vram {
    var v: Vram = .{};
    var r: Reader = .{ .bytes = script };
    while (true) {
        const op = try decodeOne(&r);
        switch (op) {
            .end => break,
            .copy => |c| {
                const asset = set.assetById(c.asset) orelse return Error.UnknownAsset;
                const bytes: usize = @as(usize, c.words) * 2;
                if (@as(usize, c.offset) + bytes > asset.bytes.len) return Error.SourceOutOfRange;
                v.store(c.dest, asset.bytes[c.offset..][0..bytes]);
            },
            else => {},
        }
    }
    return v;
}

// ---- Metatiles -------------------------------------------------------------

/// The converted metatile tables, concatenated in ROM-address order.
///
/// The Game Boy's ten tables are one contiguous region, and a screen is allowed
/// to index straight off the end of its own table into the next - the three
/// equal-sized `lavaCaves` windows exist for exactly that. `screens.metatileTable`
/// preserves it by slicing from a base to the end of the region rather than to
/// the end of the entry, and the converted side has to preserve it too, which
/// means the tables cannot be addressed as ten independent blobs.
///
/// The conversion is a uniform doubling, so a base in the Game Boy region is
/// twice that base here.
pub const Tables = struct {
    bytes: []u8,
    /// Byte offset of each `screens.tiletable_order` slot within `bytes`.
    base: [screens.tiletable_order.len]usize,

    pub fn deinit(self: *Tables, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }

    /// The table slot `t` selects: from its base to the end of the region.
    pub fn table(self: Tables, t: u4) []const u8 {
        return self.bytes[self.base[t]..];
    }
};

/// Byte offset of each `screens.tiletable_order` slot within the concatenated
/// region, without allocating. `snes_inject` needs these to patch the engine's
/// table-base list, and it has no reason to build the concatenation to get
/// them.
pub fn tableBases(set: convert.Set) !([screens.tiletable_order.len]usize) {
    if (set.metatiles.len != screens.tiletable_order.len) return convert.Error.UnresolvedSource;
    var base: [screens.tiletable_order.len]usize = @splat(std.math.maxInt(usize));
    var at: usize = 0;
    for (set.metatiles) |b| {
        for (screens.tiletable_order, 0..) |name, slot| {
            if (std.mem.eql(u8, name, b.name)) base[slot] = at;
        }
        at += b.bytes.len;
    }
    for (base) |o| {
        if (o == std.math.maxInt(usize)) return convert.Error.UnresolvedSource;
    }
    return base;
}

pub fn tables(allocator: std.mem.Allocator, set: convert.Set) !Tables {
    const base = try tableBases(set);
    var total: usize = 0;
    for (set.metatiles) |b| total += b.bytes.len;
    const bytes = try allocator.alloc(u8, total);
    errdefer allocator.free(bytes);
    var at: usize = 0;
    for (set.metatiles) |b| {
        @memcpy(bytes[at..][0..b.bytes.len], b.bytes);
        at += b.bytes.len;
    }
    return .{ .bytes = bytes, .base = base };
}

// ---- Rendering -------------------------------------------------------------

pub const Rendered = struct {
    pixels: []u8,
    /// Quarter-metatiles whose character addressed VRAM nothing wrote.
    unwritten_chars: usize,
    /// Metatile indexes past the end of the region.
    out_of_range: usize,

    pub fn deinit(self: *Rendered, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Four shade indexes, standing in for the four CGRAM entries of BG3's
/// palette 0. Built from the Game Boy's BGP so the two renderers can be
/// compared on shade rather than on colour.
pub const Palette = [4]u8;

/// A deliberate error in the converted render path, for proving the comparison
/// can fail.
///
/// A diff that reports zero is only evidence if it could have reported
/// something else. Each of these is a mistake a real conversion could plausibly
/// make - reading a metatile's four quadrants in the wrong order, indexing a
/// screen body row-major where the ROM is column-major, mapping palette entries
/// to the wrong shades, or getting the two bitplanes of a 2bpp character
/// backwards - and every one of them must make the comparison fail.
pub const Fault = enum {
    none,
    /// Read a metatile's quadrants transposed: TL TR BL BR becomes TL BL TR BR.
    metatile_quadrants,
    /// Index the screen body transposed.
    tilemap_transpose,
    /// Rotate the four palette entries by one.
    palette_permute,
    /// Read a character's two bitplanes in the wrong order.
    bitplane_swap,
};

pub fn paletteFromBgp(bgp: u8) Palette {
    var p: Palette = undefined;
    for (0..4) |i| p[i] = @intCast((bgp >> @intCast(i * 2)) & 3);
    return p;
}

/// Draw one 256x256 screen from converted metatile words and converted
/// characters.
pub fn renderScreen(
    allocator: std.mem.Allocator,
    body: []const u8,
    metatiles: []const u8,
    vram: Vram,
    palette_in: Palette,
    fault: Fault,
) !Rendered {
    var palette = palette_in;
    if (fault == .palette_permute) palette = .{ palette_in[1], palette_in[2], palette_in[3], palette_in[0] };

    const pixels = try allocator.alloc(u8, screens.screen_pixels);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    // The expansion the *engine* performs, not a second one that resembles it.
    // Drawing through `engine.buildTilemap` is what puts the runtime's own
    // metatile arithmetic under the 904-screen comparison below.
    var tilemap: engine.Tilemap = undefined;
    const stats = engine.buildTilemap(&tilemap, body, metatiles, switch (fault) {
        .metatile_quadrants => .quadrants,
        .tilemap_transpose => .transpose,
        else => .none,
    });

    var unwritten: usize = 0;
    for (0..target.tilemap_h) |ty| {
        for (0..target.tilemap_w) |tx| {
            const w: target.TilemapWord = @bitCast(tilemap[ty * target.tilemap_w + tx]);
            var tile: chr.Pixels = undefined;
            if (w.char == tileset.blank_tile) {
                tile = @splat(@splat(0));
            } else {
                if (!vram.charWritten(w.char)) unwritten += 1;
                var bytes = vram.charBytes(w.char);
                if (fault == .bitplane_swap) {
                    for (0..8) |i| std.mem.swap(u8, &bytes[i * 2], &bytes[i * 2 + 1]);
                }
                tile = chr.decodeSnes2bpp(&bytes);
            }
            const px0 = tx * 8;
            const py0 = ty * 8;
            for (0..8) |row| {
                for (0..8) |col| {
                    const sy = if (w.flip_v) 7 - row else row;
                    const sx = if (w.flip_h) 7 - col else col;
                    pixels[(py0 + row) * screens.screen_px + px0 + col] =
                        palette[tile[sy][sx] & 3];
                }
            }
        }
    }

    return .{ .pixels = pixels, .unwritten_chars = unwritten, .out_of_range = stats.out_of_range };
}

// ---- The whole-game comparison ---------------------------------------------

pub const Compare = struct {
    compared: usize = 0,
    /// Screens whose converted render differs from the Game Boy reference.
    differing: usize = 0,
    /// Pixels that differ, summed over every screen.
    differing_pixels: usize = 0,
    /// The first screen that differed, for a report that names something.
    first_bank: u8 = 0,
    first_pos: u8 = 0,
    unwritten_chars: usize = 0,
    out_of_range: usize = 0,
};

/// Both renderings of one screen, and what the converted side noticed.
pub const Pair = struct {
    gb: screens.Rendered,
    snes: Rendered,

    pub fn deinit(self: *Pair, allocator: std.mem.Allocator) void {
        self.gb.deinit(allocator);
        self.snes.deinit(allocator);
    }

    pub fn differingPixels(self: Pair) usize {
        var n: usize = 0;
        for (self.gb.pixels, self.snes.pixels) |a, b| n += @intFromBool(a != b);
        return n;
    }
};

/// The state both renderings need, set up once.
///
/// The gate and the inspection tools share this deliberately. A tool that built
/// its own pair of renders could show a human something the gate never checked,
/// which is the failure mode an A/B view exists to prevent.
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    rom: []const u8,
    set: convert.Set,
    assignment: screens.Assignment,
    decoded: door.Decoded,
    ptrs: []const u8,
    tbl: Tables,
    gb_tables: [16]?[]const tileset.Metatile = @splat(null),
    palette: Palette,

    pub fn init(allocator: std.mem.Allocator, rom: []const u8, set: convert.Set) !Renderer {
        var assignment = try screens.assign(allocator, rom);
        errdefer assignment.deinit(allocator);
        var decoded = try door.decodeRegion(allocator, door.region(rom).?);
        errdefer decoded.deinit(allocator);
        var tbl = try tables(allocator, set);
        errdefer tbl.deinit(allocator);
        return .{
            .allocator = allocator,
            .rom = rom,
            .set = set,
            .assignment = assignment,
            .decoded = decoded,
            .ptrs = door.pointers(rom).?,
            .tbl = tbl,
            .palette = paletteFromBgp(screens.live_bgp),
        };
    }

    pub fn deinit(self: *Renderer) void {
        for (self.gb_tables) |t| {
            if (t) |mts| self.allocator.free(mts);
        }
        self.tbl.deinit(self.allocator);
        self.decoded.deinit(self.allocator);
        self.assignment.deinit(self.allocator);
    }

    fn gbTable(self: *Renderer, t: u4) ![]const tileset.Metatile {
        if (self.gb_tables[t] == null) {
            const raw = screens.metatileTable(self.rom, t) orelse return screens.Error.BadTiletable;
            self.gb_tables[t] = try tileset.parseMetatiles(self.allocator, raw);
        }
        return self.gb_tables[t].?;
    }

    /// Render one cell both ways. `tiletable` overrides the assigned one, which
    /// is what makes "render any screen with any tileset" possible without a
    /// second code path; `fault` perturbs only the converted side.
    pub fn pair(self: *Renderer, cell: screens.Cell, tiletable: ?u4, fault: Fault) !?Pair {
        const choice = cell.choice orelse return null;
        const body = map.screenBody(self.rom, cell.bank, cell.screen_ptr) orelse return null;
        const t = tiletable orelse choice.tiletable;

        const ops = screens.scriptOps(self.decoded, self.ptrs, choice.door_index) orelse &[_]door.Op{};
        var gb = try screens.renderScreen(self.allocator, body, try self.gbTable(t), screens.vramFor(self.rom, ops), screens.live_bgp);
        errdefer gb.deinit(self.allocator);

        // The same script, read out of the converted stream by its converted
        // pointer, so nothing but the conversion connects the two sides.
        const script = convertedScript(self.set, choice.door_index) orelse &[_]u8{door.terminator};
        const vram = try vramFor(self.set, script);
        const conv_body = convertedBody(self.set, cell) orelse return null;
        const snes = try renderScreen(self.allocator, conv_body, self.tbl.table(t), vram, self.palette, fault);
        return .{ .gb = gb, .snes = snes };
    }

    /// The converted VRAM one door script leaves behind, for a character-level
    /// view of what a room actually has loaded.
    pub fn vramForDoor(self: *Renderer, door_index: usize) !Vram {
        const script = convertedScript(self.set, door_index) orelse &[_]u8{door.terminator};
        return vramFor(self.set, script);
    }

    /// The Game Boy's VRAM for the same script.
    pub fn gbVramForDoor(self: *Renderer, door_index: usize) screens.Vram {
        const ops = screens.scriptOps(self.decoded, self.ptrs, door_index) orelse &[_]door.Op{};
        return screens.vramFor(self.rom, ops);
    }
};

/// Render every in-use screen twice - once from the ROM through `screens.zig`,
/// once from the converted set through this file - and compare.
///
/// **What this proves and what it cannot.** Both sides read the *same*
/// `screens.assign` choice, so this is a check on the conversion -- metatile
/// expansion, tilemap, palette, bitplanes -- and it is blind to the choice
/// itself by construction. Assign every cell the wrong table and this
/// comparison still reports zero differing pixels, because the two sides would
/// be wrong identically. The check that can see the choice is
/// `zig build oracle -- worlds`, which reads the tilemap out of a running Game
/// Boy: there the table is an input on one side and an observation on the
/// other.
pub fn compareAll(allocator: std.mem.Allocator, rom: []const u8, set: convert.Set, fault: Fault) !Compare {
    var result: Compare = .{};
    var r = try Renderer.init(allocator, rom, set);
    defer r.deinit();

    for (r.assignment.cells) |cell| {
        var p = (try r.pair(cell, null, fault)) orelse continue;
        defer p.deinit(allocator);

        result.compared += 1;
        result.unwritten_chars += p.snes.unwritten_chars;
        result.out_of_range += p.snes.out_of_range;

        if (!std.mem.eql(u8, p.gb.pixels, p.snes.pixels)) {
            if (result.differing == 0) {
                result.first_bank = cell.bank;
                result.first_pos = @as(u8, cell.y) * 16 + cell.x;
            }
            result.differing += 1;
            result.differing_pixels += p.differingPixels();
        }
    }
    return result;
}

/// The converted script at Game Boy pointer index `i`, from the converted
/// pointer table and stream.
pub fn convertedScript(set: convert.Set, i: usize) ?[]const u8 {
    if (i * 2 + 1 >= set.door_pointers.bytes.len) return null;
    const at: u16 = @as(u16, set.door_pointers.bytes[i * 2]) |
        (@as(u16, set.door_pointers.bytes[i * 2 + 1]) << 8);
    if (at > set.doors.bytes.len) return null;
    return set.doors.bytes[at..];
}

/// The converted screen body a map cell names, found through the converted map
/// rather than through the ROM's pointer.
pub fn convertedBody(set: convert.Set, cell: screens.Cell) ?[]const u8 {
    const bank_index = cell.bank - map.first_bank;
    if (bank_index >= set.map_cells.len) return null;
    const cells = set.map_cells[bank_index].bytes;
    const at = (@as(usize, cell.y) * map.grid_w + cell.x) * convert.cell_bytes;
    if (at >= cells.len) return null;
    const screen = cells[at];
    const bodies = set.map_screens[bank_index].bytes;
    const off = @as(usize, screen) * map.screen_bytes;
    if (off + map.screen_bytes > bodies.len) return null;
    return bodies[off..][0..map.screen_bytes];
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "the palette is the Game Boy's BGP, unpacked" {
    // $93 = 10 01 00 11: colour 0 is the darkest shade, which is why a screen
    // whose VRAM was never written renders solid rather than blank.
    try testing.expectEqual(Palette{ 3, 0, 1, 2 }, paletteFromBgp(0x93));
    try testing.expectEqual(Palette{ 0, 1, 2, 3 }, paletteFromBgp(0xE4));
    try testing.expectEqual(Palette{ 3, 3, 3, 3 }, paletteFromBgp(0xFF));
}

test "the converted decoder refuses the opcodes the encoding does not allocate" {
    var r: Reader = .{ .bytes = &.{0xB1} };
    try testing.expectError(Error.UnknownOpcode, decodeOne(&r));
    r = .{ .bytes = &.{0xE0} };
    try testing.expectError(Error.UnknownOpcode, decodeOne(&r));
    // $03 was unallocated until the `spr` split needed a class that says
    // "the Game Boy paid for this once"; $04 is the first that is not.
    r = .{ .bytes = &.{0x04} };
    try testing.expectError(Error.UnknownOpcode, decodeOne(&r));
    // A copy that runs out of operand bytes is truncation, not a short copy.
    r = .{ .bytes = &.{ 0x01, 0x05, 0x00 } };
    try testing.expectError(Error.TruncatedOperand, decodeOne(&r));
}

test "every converted script decodes end to end" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);
    var set = try convert.run(gpa, rom);
    defer set.deinit();

    // Walk the whole stream once: every byte must belong to exactly one
    // operation, which is what makes a pointer into it safe to follow.
    var r: Reader = .{ .bytes = set.doors.bytes };
    var ops: usize = 0;
    var copies: usize = 0;
    while (r.pos < set.doors.bytes.len) {
        const op = try decodeOne(&r);
        ops += 1;
        if (op == .copy) copies += 1;
    }
    try testing.expectEqual(set.doors.bytes.len, r.pos);
    // Every Game Boy copy and load, with the 234 shared-window ones doubled.
    var gb_transfers: usize = 0;
    var doubled: usize = 0;
    {
        var d = try door.decodeRegion(gpa, door.region(rom).?);
        defer d.deinit(gpa);
        try testing.expectEqual(d.ops.items.len + 234, ops);
        for (d.ops.items) |op| switch (op) {
            .copy => |c| {
                gb_transfers += 1;
                if (c.which == .spr or target.inSharedWindow(c.dest)) doubled += 1;
            },
            .load => |l| {
                gb_transfers += 1;
                if (l.which == .spr) doubled += 1;
            },
            else => {},
        };
    }
    try testing.expectEqual(@as(usize, 234), doubled);
    try testing.expectEqual(gb_transfers + doubled, copies);

    // And every pointer lands on the start of one.
    var starts = std.AutoHashMapUnmanaged(u16, void).empty;
    defer starts.deinit(gpa);
    r = .{ .bytes = set.doors.bytes };
    while (r.pos < set.doors.bytes.len) {
        try starts.put(gpa, @intCast(r.pos), {});
        _ = try decodeOne(&r);
    }
    try starts.put(gpa, @intCast(set.doors.bytes.len), {});
    for (0..door.pointer_count) |i| {
        const at: u16 = @as(u16, set.door_pointers.bytes[i * 2]) |
            (@as(u16, set.door_pointers.bytes[i * 2 + 1]) << 8);
        try testing.expect(starts.contains(at));
    }
}

test "the concatenated metatile tables reproduce the ROM's own region" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);
    var set = try convert.run(gpa, rom);
    defer set.deinit();

    var tbl = try tables(gpa, set);
    defer tbl.deinit(gpa);

    // Each slot's base is twice the Game Boy base, and the bytes from there on
    // unconvert to what `screens.metatileTable` sees.
    for (0..screens.tiletable_order.len) |slot| {
        const gb = screens.metatileTable(rom, @intCast(slot)).?;
        const back = try convert.unconvertMetatiles(gpa, tbl.table(@intCast(slot)));
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, gb, back);
    }
}

test "every converted screen renders exactly like the Game Boy reference" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);
    var set = try convert.run(gpa, rom);
    defer set.deinit();

    const c = try compareAll(gpa, rom, set, .none);
    if (c.differing != 0) {
        std.debug.print("\n{d}/{d} screens differ ({d} px), first bank ${X} pos ${X}\n", .{
            c.differing, c.compared, c.differing_pixels, c.first_bank, c.first_pos,
        });
    }
    try testing.expectEqual(@as(usize, 0), c.differing);
    try testing.expectEqual(@as(usize, 904), c.compared);
}

test "every injected fault is caught" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);
    var set = try convert.run(gpa, rom);
    defer set.deinit();

    // How many screens a fault has to disturb before it counts as caught. A
    // fault that moved one pixel on one screen would technically fail the
    // comparison while proving almost nothing about it, so the bar is that a
    // clear majority of the game notices.
    const min_screens: usize = 500;

    for ([_]Fault{ .metatile_quadrants, .tilemap_transpose, .palette_permute, .bitplane_swap }) |f| {
        const c = try compareAll(gpa, rom, set, f);
        if (c.differing < min_screens) {
            std.debug.print("\nfault {s} disturbed only {d}/{d} screens ({d} px)\n", .{
                @tagName(f), c.differing, c.compared, c.differing_pixels,
            });
        }
        try testing.expect(c.differing >= min_screens);
        try testing.expect(c.differing_pixels > 0);
    }
}

// ---- The boot window -------------------------------------------------------

/// The 160x144 the cart should be showing on its first frame, as shade indexes.
///
/// Both the PNG written beside the ROM and the generated Mesen2 test come from
/// here, so what a person compares by eye and what the gate compares by pixel
/// are the same image.
/// The 160x144 the play window shows of `cell`, with the camera at
/// `(cam_x, cam_y)` - the reference the Mesen2 test holds the cart's own
/// framebuffer against.
///
/// Returns `error.WindowStraddles` when the camera is far enough into a screen
/// that the view runs off it. That is a legitimate camera position once the
/// tilemap streams, but the picture then comes from two screens and this
/// single-screen render cannot say what it should be.
/// The whole 256x256 of `cell`, as shade indexes, drawn through the boot
/// door's VRAM.
///
/// The Mesen2 gate bakes this rather than a window, because it no longer knows
/// in advance where the camera will be standing when it looks: the camera
/// follows Samus now, and where she comes to rest is a property of the arcs and
/// the collision data rather than of a constant. Baking the screen and cutting
/// the window on the emulator side, at whatever camera the engine reports,
/// turns that from a thing the test has to predict into a thing it can read.
pub fn screenAt(
    gpa: std.mem.Allocator,
    set: convert.Set,
    boot: engine.Boot,
    cell: u8,
) ![]u8 {
    const start = std.mem.readInt(u16, set.door_pointers.bytes[@as(usize, boot.door_index) * 2 ..][0..2], .little);
    const vram = try vramFor(set, set.doors.bytes[start..]);
    var tabs = try tables(gpa, set);
    defer tabs.deinit(gpa);

    const cells = set.map_cells[boot.map_index].bytes;
    const screen_index = cells[@as(usize, cell) * convert.cell_bytes];
    const body = set.map_screens[boot.map_index].bytes[@as(usize, screen_index) * map.screen_bytes ..][0..map.screen_bytes];

    var drawn = try renderScreen(gpa, body, tabs.table(boot.tiletable), vram, paletteFromBgp(screens.live_bgp), .none);
    defer drawn.deinit(gpa);
    return gpa.dupe(u8, drawn.pixels);
}

pub fn windowAt(
    gpa: std.mem.Allocator,
    set: convert.Set,
    boot: engine.Boot,
    cell: u8,
    cam_x: u16,
    cam_y: u16,
) ![]u8 {
    const drawn = try screenAt(gpa, set, boot, cell);
    defer gpa.free(drawn);

    const w = target.view_w;
    const h = target.view_h;
    if (cam_x < engine.min_x or cam_y < engine.min_y) return error.WindowStraddles;
    const left = cam_x - engine.min_x;
    const top = cam_y - engine.min_y;
    if (left + w > screens.screen_px or top + h > screens.screen_px) return error.WindowStraddles;

    const window = try gpa.alloc(u8, w * h);
    errdefer gpa.free(window);
    for (0..h) |y| {
        @memcpy(window[y * w ..][0..w], drawn[(top + y) * screens.screen_px + left ..][0..w]);
    }
    return window;
}

pub fn bootWindow(gpa: std.mem.Allocator, set: convert.Set, boot: engine.Boot) ![]u8 {
    return windowAt(gpa, set, boot, boot.cell, engine.start_x, engine.start_y);
}
