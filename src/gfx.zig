//! Game Boy 2bpp tile graphics.
//!
//! A GB tile is 8x8 pixels at 2 bits per pixel, stored as 16 bytes: eight rows
//! of two bytes each, low bitplane first. Within a row byte, bit 7 is the
//! leftmost pixel. So pixel (x, y) = (hi >> (7-x) & 1) << 1 | (lo >> (7-x) & 1).
//!
//! The pixel value is a *palette index*, not a colour. The GB resolves it
//! through BGP/OBP at display time, and those registers are written by code we
//! have not read yet, so nothing here pretends to know what colour an index
//! becomes. Index-to-colour is Step 8's problem; this module only ever moves
//! indices around, losslessly, in both directions.

const std = @import("std");

pub const tile_bytes: usize = 16;
pub const tile_w: usize = 8;
pub const tile_h: usize = 8;

/// One decoded tile: `pixels[y][x]`, each a 0-3 palette index.
pub const Tile = struct {
    pixels: [tile_h][tile_w]u2,

    pub fn decode(bytes: *const [tile_bytes]u8) Tile {
        var t: Tile = .{ .pixels = undefined };
        for (0..tile_h) |y| {
            const lo = bytes[2 * y];
            const hi = bytes[2 * y + 1];
            for (0..tile_w) |x| {
                const sh: u3 = @intCast(7 - x);
                const l: u2 = @truncate(lo >> sh);
                const h: u2 = @truncate(hi >> sh);
                t.pixels[y][x] = (h << 1) | (l & 1);
            }
        }
        return t;
    }

    pub fn encode(self: Tile) [tile_bytes]u8 {
        var out: [tile_bytes]u8 = @splat(0);
        for (0..tile_h) |y| {
            var lo: u8 = 0;
            var hi: u8 = 0;
            for (0..tile_w) |x| {
                const sh: u3 = @intCast(7 - x);
                const p = self.pixels[y][x];
                lo |= @as(u8, p & 1) << sh;
                hi |= @as(u8, p >> 1) << sh;
            }
            out[2 * y] = lo;
            out[2 * y + 1] = hi;
        }
        return out;
    }
};

pub const Error = error{NotTileAligned};

/// Decode a run of tiles. The caller owns the returned slice.
pub fn decodeAll(allocator: std.mem.Allocator, bytes: []const u8) ![]Tile {
    if (bytes.len % tile_bytes != 0) return Error.NotTileAligned;
    const n = bytes.len / tile_bytes;
    const out = try allocator.alloc(Tile, n);
    for (0..n) |i| {
        out[i] = Tile.decode(bytes[i * tile_bytes ..][0..tile_bytes]);
    }
    return out;
}

/// Re-encode tiles into the ROM's 2bpp form. The inverse of `decodeAll`, and
/// the half that turns the pair into evidence: a decoder on its own can be
/// self-consistently wrong about bit order, a decode/encode pair that
/// reproduces the source bytes cannot be.
pub fn encodeAll(allocator: std.mem.Allocator, tiles: []const Tile) ![]u8 {
    const out = try allocator.alloc(u8, tiles.len * tile_bytes);
    for (tiles, 0..) |t, i| {
        const enc = t.encode();
        @memcpy(out[i * tile_bytes ..][0..tile_bytes], &enc);
    }
    return out;
}

/// Flatten tiles into one byte per pixel, laid out as a single vertical strip
/// 8 pixels wide and `8 * tiles.len` tall. Chosen because it is the layout that
/// survives a diff: a one-tile insertion shifts the strip down instead of
/// reflowing every subsequent row, so `extracted/` diffs stay readable.
pub fn toIndexedStrip(allocator: std.mem.Allocator, tiles: []const Tile) ![]u8 {
    const out = try allocator.alloc(u8, tiles.len * tile_w * tile_h);
    for (tiles, 0..) |t, i| {
        for (0..tile_h) |y| {
            for (0..tile_w) |x| {
                out[(i * tile_h + y) * tile_w + x] = t.pixels[y][x];
            }
        }
    }
    return out;
}

// ---- Seam continuity ------------------------------------------------------
//
// Used to settle the metatile byte order against the ROM instead of trusting a
// label. Adjacent tiles in real tile art tend to agree along the seam they
// share; a wrong pairing does not. See `tileset.zig`'s order test.

/// Pixels that differ across the vertical seam where `left`'s right column
/// meets `right`'s left column. Lower is more continuous.
pub fn seamH(left: Tile, right: Tile) u32 {
    var n: u32 = 0;
    for (0..tile_h) |y| n += @intFromBool(left.pixels[y][tile_w - 1] != right.pixels[y][0]);
    return n;
}

/// Pixels that differ across the horizontal seam where `top`'s bottom row meets
/// `bottom`'s top row.
pub fn seamV(top: Tile, bottom: Tile) u32 {
    var n: u32 = 0;
    for (0..tile_w) |x| n += @intFromBool(top.pixels[tile_h - 1][x] != bottom.pixels[0][x]);
    return n;
}

// ---- Tests ----------------------------------------------------------------

test "decode places bit 7 leftmost and the second byte in the high plane" {
    // Row 0: lo = 1000_0000, hi = 0000_0000 -> leftmost pixel is index 1.
    // Row 1: lo = 0000_0000, hi = 1000_0000 -> leftmost pixel is index 2.
    // Row 2: lo = 0000_0001, hi = 0000_0001 -> rightmost pixel is index 3.
    var bytes: [tile_bytes]u8 = @splat(0);
    bytes[0] = 0x80;
    bytes[3] = 0x80;
    bytes[4] = 0x01;
    bytes[5] = 0x01;
    const t = Tile.decode(&bytes);
    try std.testing.expectEqual(@as(u2, 1), t.pixels[0][0]);
    try std.testing.expectEqual(@as(u2, 0), t.pixels[0][1]);
    try std.testing.expectEqual(@as(u2, 2), t.pixels[1][0]);
    try std.testing.expectEqual(@as(u2, 3), t.pixels[2][7]);
    try std.testing.expectEqual(@as(u2, 0), t.pixels[2][6]);
}

test "encode round-trips every byte pattern we can afford to try" {
    // Exhaustive over rows would be 2^16 per row; instead walk a pseudo-random
    // spread plus the degenerate all-0/all-1 patterns, which are where a
    // bitplane mix-up hides.
    var prng = std.Random.DefaultPrng.init(0x4d32);
    const rnd = prng.random();
    var bytes: [tile_bytes]u8 = @splat(0);
    for (0..2048) |i| {
        switch (i) {
            0 => bytes = @splat(0x00),
            1 => bytes = @splat(0xff),
            2 => for (0..tile_bytes) |k| {
                bytes[k] = if (k % 2 == 0) 0xff else 0x00;
            },
            3 => for (0..tile_bytes) |k| {
                bytes[k] = if (k % 2 == 0) 0x00 else 0xff;
            },
            else => rnd.bytes(&bytes),
        }
        const t = Tile.decode(&bytes);
        try std.testing.expectEqualSlices(u8, &bytes, &t.encode());
    }
}

test "decodeAll rejects a partial tile rather than truncating it" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(Error.NotTileAligned, decodeAll(gpa, &[_]u8{0} ** 17));
    const ok = try decodeAll(gpa, &[_]u8{0} ** 32);
    defer gpa.free(ok);
    try std.testing.expectEqual(@as(usize, 2), ok.len);
}

test "indexed strip is 8 wide and stacks tiles downward" {
    const gpa = std.testing.allocator;
    var bytes: [tile_bytes * 2]u8 = @splat(0);
    bytes[0] = 0xff; // tile 0, row 0, all index 1
    bytes[tile_bytes + 1] = 0xff; // tile 1, row 0, all index 2
    const tiles = try decodeAll(gpa, &bytes);
    defer gpa.free(tiles);
    const strip = try toIndexedStrip(gpa, tiles);
    defer gpa.free(strip);
    try std.testing.expectEqual(@as(usize, 2 * 64), strip.len);
    try std.testing.expectEqual(@as(u8, 1), strip[0]);
    try std.testing.expectEqual(@as(u8, 0), strip[8]); // tile 0, row 1
    try std.testing.expectEqual(@as(u8, 2), strip[64]); // tile 1, row 0
}

test "seam costs are zero for identical edges and maximal for opposing ones" {
    const zero: Tile = .{ .pixels = @splat(@splat(0)) };
    try std.testing.expectEqual(@as(u32, 0), seamH(zero, zero));
    try std.testing.expectEqual(@as(u32, 0), seamV(zero, zero));

    // seamH looks only at the left tile's right column and the right tile's
    // left column, so changing any other column must not move the cost.
    var right_col: Tile = zero;
    for (0..tile_h) |y| right_col.pixels[y][tile_w - 1] = 3;
    try std.testing.expectEqual(@as(u32, 8), seamH(right_col, zero));
    try std.testing.expectEqual(@as(u32, 0), seamH(zero, right_col));
    try std.testing.expectEqual(@as(u32, 1), seamV(right_col, zero));

    // Likewise seamV touches only the bottom row of the top tile.
    var bottom_row: Tile = zero;
    for (0..tile_w) |x| bottom_row.pixels[tile_h - 1][x] = 3;
    try std.testing.expectEqual(@as(u32, 8), seamV(bottom_row, zero));
    try std.testing.expectEqual(@as(u32, 0), seamV(zero, bottom_row));
    try std.testing.expectEqual(@as(u32, 1), seamH(bottom_row, zero));
}
