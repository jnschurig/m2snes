//! Character (tile) conversion: Game Boy 2bpp to the SNES formats.
//!
//! `01-requirements.md` calls this "a reinterpretation", and it is - but that
//! is a claim about two hardware formats, and the useful thing to do with such
//! a claim is check it rather than repeat it. So this module carries a SNES
//! decoder written from the SNES side of the spec, with no reference to
//! `gfx.zig`, and the test below runs every tile of the retail ROM through both
//! and compares pixels. If the formats ever disagreed, that test would say so
//! instead of a comment saying they do not.
//!
//! ## The two formats
//!
//! SNES 2bpp: 16 bytes, eight rows of two, low bitplane first, bit 7 leftmost -
//! byte for byte what the Game Boy stores.
//!
//! SNES 4bpp: 32 bytes. The first 16 are the 2bpp tile unchanged; the second 16
//! are bitplanes 2 and 3 in the same row-interleaved shape. So promoting a
//! Game Boy tile to 4bpp is a copy followed by sixteen zeroes, and the pixel
//! values survive because indices 0-3 mean the same thing in a 16-colour
//! palette as in a 4-colour one - provided the palette's first four entries are
//! the ones the 2bpp view uses, which is `target.play_palette`'s job.
//!
//! Sprite sheets get the 4bpp form because SNES objects have no 2bpp mode. The
//! ones a background metatile can also reach - see `target.zig` on the shared
//! $8B00 window - get both.

const std = @import("std");
const gfx = @import("gfx.zig");
const target = @import("snes_target.zig");

pub const snes_2bpp_bytes: usize = 16;
pub const snes_4bpp_bytes: usize = 32;

/// Convert Game Boy tile bytes to SNES 2bpp.
///
/// It is a copy, and it is written as a copy rather than as a `@memcpy` at the
/// call site so that the one place that would have to change, if the claim were
/// ever false, is here.
pub fn to2bpp(allocator: std.mem.Allocator, gb: []const u8) ![]u8 {
    if (gb.len % gfx.tile_bytes != 0) return gfx.Error.NotTileAligned;
    const out = try allocator.alloc(u8, gb.len);
    @memcpy(out, gb);
    return out;
}

/// Convert Game Boy tile bytes to SNES 4bpp, leaving bitplanes 2 and 3 clear.
pub fn to4bpp(allocator: std.mem.Allocator, gb: []const u8) ![]u8 {
    if (gb.len % gfx.tile_bytes != 0) return gfx.Error.NotTileAligned;
    const n = gb.len / gfx.tile_bytes;
    const out = try allocator.alloc(u8, n * snes_4bpp_bytes);
    @memset(out, 0);
    for (0..n) |i| {
        @memcpy(out[i * snes_4bpp_bytes ..][0..snes_2bpp_bytes], gb[i * gfx.tile_bytes ..][0..gfx.tile_bytes]);
    }
    return out;
}

/// Recover Game Boy tile bytes from a SNES 4bpp run, or fail if any tile uses a
/// bitplane the Game Boy does not have. The inverse half of the pair: without
/// it, `to4bpp` could pad in the wrong half of the tile and nothing would
/// notice, because the game would still boot and just draw the wrong colours.
pub fn from4bpp(allocator: std.mem.Allocator, snes: []const u8) ![]u8 {
    if (snes.len % snes_4bpp_bytes != 0) return Error.Not4bppAligned;
    const n = snes.len / snes_4bpp_bytes;
    const out = try allocator.alloc(u8, n * gfx.tile_bytes);
    errdefer allocator.free(out);
    for (0..n) |i| {
        const tile = snes[i * snes_4bpp_bytes ..][0..snes_4bpp_bytes];
        for (tile[snes_2bpp_bytes..]) |b| {
            if (b != 0) return Error.HighBitplaneSet;
        }
        @memcpy(out[i * gfx.tile_bytes ..][0..gfx.tile_bytes], tile[0..snes_2bpp_bytes]);
    }
    return out;
}

pub const Error = error{ Not4bppAligned, HighBitplaneSet };

// ---- An independent SNES-side decoder --------------------------------------
//
// Written from the SNES format description, not from `gfx.zig`. It exists only
// to be disagreed with: if it and `gfx.Tile.decode` ever produced different
// pixels for the same bytes, one of the two readings would be wrong, and a
// "these formats are identical" comment would not have caught it.

pub const Pixels = [8][8]u4;

pub fn decodeSnes2bpp(bytes: *const [snes_2bpp_bytes]u8) Pixels {
    var px: Pixels = @splat(@splat(0));
    for (0..8) |row| {
        const p0 = bytes[row * 2];
        const p1 = bytes[row * 2 + 1];
        for (0..8) |col| {
            const bit: u3 = @intCast(7 - col);
            const b0: u4 = @truncate(p0 >> bit);
            const b1: u4 = @truncate(p1 >> bit);
            px[row][col] = (b0 & 1) | ((b1 & 1) << 1);
        }
    }
    return px;
}

pub fn decodeSnes4bpp(bytes: *const [snes_4bpp_bytes]u8) Pixels {
    var px = decodeSnes2bpp(bytes[0..snes_2bpp_bytes]);
    for (0..8) |row| {
        const p2 = bytes[snes_2bpp_bytes + row * 2];
        const p3 = bytes[snes_2bpp_bytes + row * 2 + 1];
        for (0..8) |col| {
            const bit: u3 = @intCast(7 - col);
            const b2: u4 = @truncate(p2 >> bit);
            const b3: u4 = @truncate(p3 >> bit);
            px[row][col] |= ((b2 & 1) << 2) | ((b3 & 1) << 3);
        }
    }
    return px;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");
const offsets = @import("offsets.zig");

fn samePixels(gb: gfx.Tile, snes: Pixels) bool {
    for (0..8) |y| {
        for (0..8) |x| {
            if (@as(u4, gb.pixels[y][x]) != snes[y][x]) return false;
        }
    }
    return true;
}

test "the two decoders agree on every byte pattern, read from opposite specs" {
    var prng = std.Random.DefaultPrng.init(0x5e5);
    const rnd = prng.random();
    var bytes: [gfx.tile_bytes]u8 = undefined;
    for (0..4096) |i| {
        switch (i) {
            0 => bytes = @splat(0x00),
            1 => bytes = @splat(0xFF),
            // The pattern that catches a swapped plane order: one plane set,
            // the other clear, so every pixel is index 1 or index 2 and never
            // both.
            2 => for (0..gfx.tile_bytes) |k| {
                bytes[k] = if (k % 2 == 0) 0xFF else 0x00;
            },
            3 => for (0..gfx.tile_bytes) |k| {
                bytes[k] = if (k % 2 == 0) 0x00 else 0xFF;
            },
            else => rnd.bytes(&bytes),
        }
        try testing.expect(samePixels(gfx.Tile.decode(&bytes), decodeSnes2bpp(&bytes)));
    }
}

test "promotion to 4bpp preserves pixel values and clears the high planes" {
    const gpa = testing.allocator;
    var bytes: [gfx.tile_bytes * 3]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    prng.random().bytes(&bytes);

    const four = try to4bpp(gpa, &bytes);
    defer gpa.free(four);
    try testing.expectEqual(@as(usize, 3 * snes_4bpp_bytes), four.len);

    for (0..3) |i| {
        const gb = gfx.Tile.decode(bytes[i * gfx.tile_bytes ..][0..gfx.tile_bytes]);
        const px = decodeSnes4bpp(four[i * snes_4bpp_bytes ..][0..snes_4bpp_bytes]);
        try testing.expect(samePixels(gb, px));
        // Every pixel must stay inside the four indices the Game Boy has.
        for (px) |row| for (row) |p| try testing.expect(p < 4);
    }

    const back = try from4bpp(gpa, four);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, &bytes, back);
}

test "a 4bpp tile using a high bitplane is refused, not silently truncated" {
    const gpa = testing.allocator;
    var four: [snes_4bpp_bytes]u8 = @splat(0);
    four[snes_2bpp_bytes] = 0x01;
    try testing.expectError(Error.HighBitplaneSet, from4bpp(gpa, &four));
    try testing.expectError(Error.Not4bppAligned, from4bpp(gpa, four[0..31]));
}

test "2bpp conversion round-trips, and rejects a partial tile" {
    const gpa = testing.allocator;
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const out = try to2bpp(gpa, &src);
    defer gpa.free(out);
    try testing.expectEqualSlices(u8, &src, out);
    try testing.expectError(gfx.Error.NotTileAligned, to2bpp(gpa, src[0..15]));
    try testing.expectError(gfx.Error.NotTileAligned, to4bpp(gpa, src[0..15]));
}

test "every graphics tile in the retail ROM decodes the same on both sides" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);

    var tiles: usize = 0;
    for (offsets.entries) |e| {
        switch (e.kind) {
            .graphics_tileset, .graphics_samus, .graphics_enemy, .graphics_item, .graphics_ui => {},
            else => continue,
        }
        if (e.romEnd() > rom.len) continue;
        const bytes = rom[e.romOffset()..e.romEnd()];
        var i: usize = 0;
        while (i + gfx.tile_bytes <= bytes.len) : (i += gfx.tile_bytes) {
            const raw = bytes[i..][0..gfx.tile_bytes];
            try testing.expect(samePixels(gfx.Tile.decode(raw), decodeSnes2bpp(raw)));
            tiles += 1;
        }
    }
    // The coverage report counts 2971 graphics tiles across the five classes.
    // Pinning it here means a shrinking sweep gets noticed instead of passing
    // vacuously.
    try testing.expectEqual(@as(usize, 2971), tiles);
}
