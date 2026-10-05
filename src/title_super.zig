//! "Super" on the title, Step 24j (B15): the one deliberate presentation
//! divergence the port makes, and new art rather than anything of the ROM's.
//!
//! `assets/title_super.png` is the source of truth. It is decoded at build
//! time, checked to hold exactly the three values James drew with, and turned
//! into three blobs the engine uploads while the title is under forced blank:
//!
//!   `title_super_chr`  4bpp characters for BG1, from id `chr_first`
//!   `title_super_pal`  the art's colours, for BG palette `palette`
//!   `title_super_map`  a header -- the patch's word offset in BG1's map, its
//!                      columns and rows, the first character id -- and the
//!                      patch's map words, row by row
//!
//! ## Where it goes
//!
//! `super_at` is the art's top-left in the Game Boy's 160x144 screen, the
//! coordinates `example_title.png` was measured in. BG1's scroll stays at the
//! zero the room readout expects, so the art is placed in BG1's map at the
//! screen pixel it shows on: the play window's corner plus `super_at`, and one
//! line lower, because the PPU fetches the row after the one VOFS names (the
//! `+1` in the engine's `!SCROLL_Y_BIAS`). The art is shifted inside a patch
//! of whole tiles by the remainder; the patch's empty tiles are map word zero,
//! which is character zero, which `Reset` leaves blank.
//!
//! BG1, not objects: BG1 is off on the main screen, the readout that owns it
//! never runs on the title, and in mode 1 it is in front of BG3 at either
//! priority, so the menu's sprites and B14's grading of them are untouched.

const std = @import("std");
const png = @import("png");
const screen = @import("snes_screen.zig");

pub const png_bytes = @embedFile("title_super_png");

/// The art's top-left on the Game Boy's screen. The one position constant:
/// James moves "Super" by changing this.
pub const super_at = struct {
    pub const x: u16 = 5;
    pub const y: u16 = 61;
};

/// The values the PNG may hold, in palette order: index 0 is transparent.
pub const red = [3]u8{ 190, 6, 6 };
pub const blue = [3]u8{ 24, 44, 136 };
pub const colours = [_][3]u8{ red, blue };

/// BG palette 7, CGRAM `$70`-`$7F`: nothing else writes there.
pub const palette: u3 = 7;
/// Character zero stays blank, so every map word the patch does not use shows
/// nothing.
pub const chr_first: u16 = 1;

/// Screen pixel the art's top-left shows on, and BG1 pixel it is drawn at.
pub const screen_x: u16 = screen.win_left + super_at.x;
pub const screen_y: u16 = screen.band_top + super_at.y;
pub const bg_x: u16 = screen_x;
pub const bg_y: u16 = screen_y + 1;

pub const Error = error{ WrongSize, UnexpectedColour, TooManyCharacters };

/// The art as palette indexes, `w` by `h`: 0 transparent, 1 red, 2 blue.
pub const Art = struct {
    w: usize,
    h: usize,
    px: []u8,

    pub fn deinit(self: Art, a: std.mem.Allocator) void {
        a.free(self.px);
    }

    pub fn at(self: Art, x: usize, y: usize) u8 {
        return self.px[y * self.w + x];
    }
};

pub fn decode(a: std.mem.Allocator) !Art {
    const d = try png.decodeRgba(a, png_bytes);
    defer a.free(d.pixels);
    const px = try a.alloc(u8, d.w * d.h);
    errdefer a.free(px);
    for (px, 0..) |*p, i| {
        const c = d.pixels[i * 4 ..][0..4];
        if (c[3] == 0) {
            p.* = 0;
            continue;
        }
        // A colour James did not draw with is an error, not a nearest match:
        // an editor that anti-aliased the art would otherwise pass unseen.
        p.* = for (colours, 1..) |k, n| {
            if (c[3] == 255 and std.mem.eql(u8, c[0..3], &k)) break @intCast(n);
        } else return Error.UnexpectedColour;
    }
    return .{ .w = d.w, .h = d.h, .px = px };
}

/// 8-bit channel to the SNES's 5, to nearest: `round(c*31/255)`, the rule
/// James approved from `super_snes.png`.
pub fn channel5(c: u8) u5 {
    return @intCast((@as(u16, c) * 31 + 127) / 255);
}

/// A colour as the 15-bit BGR word CGRAM holds.
pub fn bgr15(c: [3]u8) u16 {
    return @as(u16, channel5(c[0])) | (@as(u16, channel5(c[1])) << 5) | (@as(u16, channel5(c[2])) << 10);
}

/// The patch of whole BG1 tiles the art sits in.
pub fn Patch(comptime w: usize, comptime h: usize) type {
    return struct {
        pub const shift_x: usize = bg_x % 8;
        pub const shift_y: usize = bg_y % 8;
        pub const col: usize = bg_x / 8;
        pub const row: usize = bg_y / 8;
        pub const cols: usize = (shift_x + w + 7) / 8;
        pub const rows: usize = (shift_y + h + 7) / 8;
        /// Word offset of the patch's first row in BG1's 32x32 map.
        pub const map_offset: usize = row * 32 + col;
    };
}

/// `assets/title_super.png`'s size, pinned so the patch is comptime; `decode`'s
/// caller checks the file agrees.
pub const art_w: usize = 67;
pub const art_h: usize = 17;
pub const patch = Patch(art_w, art_h);

pub const map_header_bytes: usize = 6;

pub const Blobs = struct { chr: []u8, pal: []u8, map: []u8 };

/// The three blobs, allocated in `a`.
pub fn blobs(a: std.mem.Allocator) !Blobs {
    const art = try decode(a);
    defer art.deinit(a);
    if (art.w != art_w or art.h != art_h) return Error.WrongSize;

    var chr: std.ArrayList(u8) = .empty;
    errdefer chr.deinit(a);
    const map = try a.alloc(u8, map_header_bytes + patch.cols * patch.rows * 2);
    errdefer a.free(map);
    std.mem.writeInt(u16, map[0..2], patch.map_offset, .little);
    map[2] = patch.cols;
    map[3] = patch.rows;
    std.mem.writeInt(u16, map[4..6], chr_first, .little);

    var next = chr_first;
    for (0..patch.rows) |ty| for (0..patch.cols) |tx| {
        var tile: [32]u8 = @splat(0);
        var any = false;
        for (0..8) |py| for (0..8) |pxl| {
            const ax = @as(isize, @intCast(tx * 8 + pxl)) - @as(isize, patch.shift_x);
            const ay = @as(isize, @intCast(ty * 8 + py)) - @as(isize, patch.shift_y);
            if (ax < 0 or ay < 0 or ax >= art.w or ay >= art.h) continue;
            const v = art.at(@intCast(ax), @intCast(ay));
            if (v == 0) continue;
            any = true;
            const bit: u3 = @intCast(7 - pxl);
            for (0..4) |plane| if ((v >> @intCast(plane)) & 1 != 0) {
                tile[(plane / 2) * 16 + py * 2 + plane % 2] |= @as(u8, 1) << bit;
            };
        };
        var word: u16 = 0;
        if (any) {
            if (next > 0xFF) return Error.TooManyCharacters;
            try chr.appendSlice(a, &tile);
            word = next | (@as(u16, palette) << 10);
            next += 1;
        }
        std.mem.writeInt(u16, map[map_header_bytes + (ty * patch.cols + tx) * 2 ..][0..2], word, .little);
    };

    // Colour 0 is written and never seen: a background's colour 0 is
    // transparent. Written anyway so the blob is the palette's first entries.
    const pal = try a.alloc(u8, (colours.len + 1) * 2);
    std.mem.writeInt(u16, pal[0..2], 0, .little);
    for (colours, 1..) |c, i| std.mem.writeInt(u16, pal[i * 2 ..][0..2], bgr15(c), .little);

    return .{ .chr = try chr.toOwnedSlice(a), .pal = pal, .map = map };
}

/// The art laid over a Game Boy picture of `width` pixels a row: each opaque
/// pixel becomes `base + index - 1`, so a shade picture (0-3) gains red as
/// `base` and blue as `base + 1`.
pub fn composite(a: std.mem.Allocator, picture: []u8, width: usize, base: u8) !void {
    const art = try decode(a);
    defer art.deinit(a);
    for (0..art.h) |y| for (0..art.w) |x| {
        const v = art.at(x, y);
        if (v != 0) picture[(super_at.y + y) * width + super_at.x + x] = base + v - 1;
    };
}

/// The rectangle the `title` rung grades: the art plus a tile on each side,
/// clipped to the Game Boy's screen. Game Boy coordinates, end exclusive.
pub const margin: u16 = 8;
pub const rect = struct {
    pub const x0: u16 = if (super_at.x > margin) super_at.x - margin else 0;
    pub const y0: u16 = if (super_at.y > margin) super_at.y - margin else 0;
    pub const x1: u16 = @min(super_at.x + art_w + margin, 160);
    pub const y1: u16 = @min(super_at.y + art_h + margin, 144);
};

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const chr_mod = @import("snes_chr.zig");

test "the PNG decodes as PIL reads it" {
    // PIL's reading of the same file (2026-09-25), an authority that shares no
    // code with `png.decodeRgba`: the size, every value's count, and the hash
    // of the whole RGBA grid.
    const a = testing.allocator;
    const d = try png.decodeRgba(a, png_bytes);
    defer a.free(d.pixels);
    try testing.expectEqual(@as(usize, 67), d.w);
    try testing.expectEqual(@as(usize, 17), d.h);
    var clear: usize = 0;
    var r: usize = 0;
    var b: usize = 0;
    for (0..d.w * d.h) |i| {
        const c = d.pixels[i * 4 ..][0..4];
        if (std.mem.eql(u8, c, &.{ 0, 0, 0, 0 })) clear += 1;
        if (std.mem.eql(u8, c, &.{ 190, 6, 6, 255 })) r += 1;
        if (std.mem.eql(u8, c, &.{ 24, 44, 136, 255 })) b += 1;
    }
    try testing.expectEqual(@as(usize, 753), clear);
    try testing.expectEqual(@as(usize, 262), r);
    try testing.expectEqual(@as(usize, 124), b);
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(d.pixels, &h, .{});
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "e6555188a9adbc305b731cedf0c1f13003bceba97ea19d4339adb851c69dc65a");
    try testing.expectEqualSlices(u8, &want, &h);
}

test "the approved colours, as 5-bit channels" {
    // James approved (23,1,1) and (3,5,17) from `super_snes.png`, 2026-09-25.
    try testing.expectEqual(@as(u16, 23 | (1 << 5) | (1 << 10)), bgr15(red));
    try testing.expectEqual(@as(u16, 3 | (5 << 5) | (17 << 10)), bgr15(blue));
}

test "Game Boy (5, 61) is BG1 pixel (53, 102), in a 9x3 patch at column 6, row 12" {
    try testing.expectEqual(@as(u16, 53), bg_x);
    try testing.expectEqual(@as(u16, 102), bg_y);
    try testing.expectEqual(@as(usize, 6), patch.col);
    try testing.expectEqual(@as(usize, 12), patch.row);
    try testing.expectEqual(@as(usize, 9), patch.cols);
    try testing.expectEqual(@as(usize, 3), patch.rows);
    // Clear of the readout's rows 2 and 3.
    try testing.expect(patch.row > 3);
}

test "the blobs draw the art back, pixel for pixel, where it was placed" {
    const a = testing.allocator;
    const bl = try blobs(a);
    defer {
        a.free(bl.chr);
        a.free(bl.pal);
        a.free(bl.map);
    }
    const art = try decode(a);
    defer art.deinit(a);
    try testing.expect(bl.chr.len / 32 <= 0xBF); // below the readout's glyphs at $C0
    // Rasterise the patch through `snes_chr`'s decoder, which shares no code
    // with the encoder above, and compare with the art.
    for (0..patch.rows * 8) |y| for (0..patch.cols * 8) |x| {
        const word = std.mem.readInt(u16, bl.map[map_header_bytes + ((y / 8) * patch.cols + x / 8) * 2 ..][0..2], .little);
        var got: u8 = 0;
        if (word != 0) {
            try testing.expectEqual(@as(u16, palette), (word >> 10) & 7);
            const id = word & 0x3FF;
            const tile = chr_mod.decodeSnes4bpp(bl.chr[(id - chr_first) * 32 ..][0..32]);
            got = tile[y % 8][x % 8];
        }
        const ax = @as(isize, @intCast(x)) - @as(isize, patch.shift_x);
        const ay = @as(isize, @intCast(y)) - @as(isize, patch.shift_y);
        const want: u8 = if (ax < 0 or ay < 0 or ax >= art.w or ay >= art.h) 0 else art.at(@intCast(ax), @intCast(ay));
        try testing.expectEqual(want, got);
    };
}
