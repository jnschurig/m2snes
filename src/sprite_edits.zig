//! The sprite editor's edits (`src/data/sprite_edits.zon`), and how the
//! converter applies them (sprite-pixel-editor F2).
//!
//! A tile is known by its original Game Boy content (`tileKey`), not by where
//! it sits, so an edit reaches every copy of that tile in every sheet. Each
//! edit is sparse: the pixels it changes, each with its new 4bpp index, and
//! optionally the OBJ palette the tile draws in under `full`.
//!
//! An index's Game Boy shade is `index & 3` and `index >> 2` its variant
//! (`colors.Table16`). 4, 8 and 12 are never used: they would be transparent
//! on the Game Boy side and opaque on the SNES.

const std = @import("std");

pub const Pixel = struct { x: u3, y: u3, index: u4 };

pub const Tile = struct {
    key: u64,
    /// The OBJ palette the tile draws in under `full`, when it differs from
    /// the derived slot (`full_slots.slotAt`).
    palette: ?u3 = null,
    pixels: []const Pixel = &.{},
};

pub const Edits = struct {
    rom_sha1: []const u8 = "",
    tiles: []const Tile = &.{},
};

pub const data: Edits = @import("data/sprite_edits.zon");

pub const Error = error{
    /// The edits were made against a different ROM.
    WrongRom,
    /// A pixel's index is 4, 8 or 12.
    UnusedIndex,
    /// Two entries for one tile.
    DuplicateKey,
    /// An entry whose key matches no sprite tile.
    UnmatchedKey,
};

const seed: u64 = 0x6D32_736E_6573; // "m2snes"

/// The key of a Game Boy tile: a hash of its 16 bytes.
pub fn tileKey(gb: *const [16]u8) u64 {
    return std.hash.Wyhash.hash(seed, gb);
}

/// Whether `i` is an index a pixel may take.
pub fn usable(i: u4) bool {
    return i == 0 or i & 3 != 0;
}

/// The edits by key, after checking them against `rom`. `bad` names the
/// offending key on `UnusedIndex` and `DuplicateKey`.
pub const Index = struct {
    map: std.AutoHashMapUnmanaged(u64, *const Tile) = .empty,

    pub fn init(a: std.mem.Allocator, e: *const Edits, rom: []const u8, bad: *?u64) !Index {
        var self: Index = .{};
        if (e.tiles.len == 0) return self;
        errdefer self.map.deinit(a);
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        std.crypto.hash.Sha1.hash(rom, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.ascii.eqlIgnoreCase(&hex, e.rom_sha1)) return Error.WrongRom;
        for (e.tiles) |*t| {
            for (t.pixels) |p| if (!usable(p.index)) {
                bad.* = t.key;
                return Error.UnusedIndex;
            };
            const gop = try self.map.getOrPut(a, t.key);
            if (gop.found_existing) {
                bad.* = t.key;
                return Error.DuplicateKey;
            }
            gop.value_ptr.* = t;
        }
        return self;
    }

    pub fn get(self: Index, gb: *const [16]u8) ?*const Tile {
        if (self.map.count() == 0) return null;
        return self.map.get(tileKey(gb));
    }
};

/// Sets each edited pixel's four plane bits in a 4bpp tile: planes 0-1 in
/// bytes 0-15, planes 2-3 sixteen bytes on, two bytes a row.
pub fn apply(snes: *[32]u8, t: *const Tile) void {
    for (t.pixels) |p| {
        const bit = @as(u8, 0x80) >> p.x;
        const row = @as(usize, p.y) * 2;
        for (0..4) |plane| {
            const at = row + (plane & 1) + (plane >> 1) * 16;
            if (p.index >> @intCast(plane) & 1 != 0) snes[at] |= bit else snes[at] &= ~bit;
        }
    }
}

/// `apply` for a 2bpp copy: each pixel's shade, `index & 3`.
pub fn apply2bpp(snes: *[16]u8, t: *const Tile) void {
    for (t.pixels) |p| {
        const bit = @as(u8, 0x80) >> p.x;
        const row = @as(usize, p.y) * 2;
        for (0..2) |plane| {
            if (p.index >> @intCast(plane) & 1 != 0) snes[row + plane] |= bit else snes[row + plane] &= ~bit;
        }
    }
}

/// A 4bpp pixel's index.
pub fn pixel4(snes: *const [32]u8, x: u3, y: u3) u4 {
    const shift: u3 = 7 - x;
    const row = @as(usize, y) * 2;
    var i: u4 = 0;
    for (0..4) |plane| {
        const at = row + (plane & 1) + (plane >> 1) * 16;
        i |= @as(u4, @intCast(snes[at] >> shift & 1)) << @intCast(plane);
    }
    return i;
}

const testing = std.testing;

const synthetic = Tile{ .key = 1, .pixels = &.{
    .{ .x = 0, .y = 0, .index = 15 },
    .{ .x = 7, .y = 7, .index = 5 },
    .{ .x = 3, .y = 4, .index = 0 },
    .{ .x = 1, .y = 2, .index = 10 },
} };

test "apply sets every plane of each edited pixel and nothing else" {
    var gb: [16]u8 = undefined;
    for (&gb, 0..) |*b, i| b.* = @intCast((i * 37 + 11) & 0xFF);
    var snes: [32]u8 = @splat(0);
    @memcpy(snes[0..16], &gb);
    apply(&snes, &synthetic);
    for (0..8) |y| for (0..8) |x| {
        const got = pixel4(&snes, @intCast(x), @intCast(y));
        const want: u4 = for (synthetic.pixels) |p| {
            if (p.x == x and p.y == y) break p.index;
        } else @intCast((gb[y * 2] >> @intCast(7 - x) & 1) | (gb[y * 2 + 1] >> @intCast(7 - x) & 1) << 1);
        try testing.expectEqual(want, got);
    };
    // The 2bpp copy shows each pixel's shade, the 4bpp tile's low planes.
    var two = gb;
    apply2bpp(&two, &synthetic);
    try testing.expectEqualSlices(u8, snes[0..16], &two);
}

test "indices 4, 8 and 12 are refused, and only they" {
    for (0..16) |i| try testing.expectEqual(i == 0 or i & 3 != 0, usable(@intCast(i)));
    const rom = "rom";
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(rom, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var bad: ?u64 = null;
    const e = Edits{ .rom_sha1 = &hex, .tiles = &.{.{ .key = 9, .pixels = &.{.{ .x = 0, .y = 0, .index = 8 }} }} };
    try testing.expectError(Error.UnusedIndex, Index.init(testing.allocator, &e, rom, &bad));
    try testing.expectEqual(@as(?u64, 9), bad);
}

test "the ROM hash is checked only when there are edits" {
    var bad: ?u64 = null;
    var none = try Index.init(testing.allocator, &.{}, "rom", &bad);
    try testing.expectEqual(@as(?*const Tile, null), none.get(&@splat(0)));
    none.map.deinit(testing.allocator);
    const e = Edits{ .rom_sha1 = "00", .tiles = &.{synthetic} };
    try testing.expectError(Error.WrongRom, Index.init(testing.allocator, &e, "rom", &bad));
}

test "a duplicate key is refused" {
    const rom = "rom";
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(rom, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var bad: ?u64 = null;
    const e = Edits{ .rom_sha1 = &hex, .tiles = &.{ synthetic, synthetic } };
    try testing.expectError(Error.DuplicateKey, Index.init(testing.allocator, &e, rom, &bad));
}
