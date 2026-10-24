//! The L badge on the title, colour schemes Step 7 (F2): an L-button glyph
//! and the selected file's scheme name, in the bottom letterbox border just
//! below the window's bottom-left corner. Our own art, like "Super".
//!
//! `assets/title_badge.png` is the source of truth: one `art_w` by `badge_h`
//! badge a scheme, stacked in `colors.Scheme` id order, each the badge as it
//! shows under that scheme. It is decoded at build time, checked to hold only
//! `colours`, and turned into three blobs:
//!
//!   `title_badge_chr`  4bpp characters for BG1, from id `chr_first`; a tile
//!                      the schemes share (the glyph) is stored once
//!   `title_badge_pal`  the art's colours, for BG palette `palette`
//!   `title_badge_map`  each scheme's patch of BG1 map words, `patch.rows` by
//!                      `patch.cols`, schemes in id order
//!
//! The engine lays the scheme's patch at the title's setup and again, in
//! vblank, whenever the scheme changes. The badge's colours are its own
//! palette's, so it reads the same in every scheme. BG1 is placed as
//! `title_super` places "Super": scroll zero, one line lower than the screen
//! line it shows on.

const std = @import("std");
const screen = @import("snes_screen.zig");
const target = @import("snes_target.zig");
const colors = @import("colors.zig");
const super = @import("title_super.zig");

pub const png_bytes = @embedFile("title_badge_png");

/// The badge's top-left, from the window's bottom-left corner: `y` lines
/// below the window. James moves the badge by changing this.
pub const badge_at = struct {
    pub const x: u16 = 0;
    pub const y: u16 = 4;
};

/// The values the PNG may hold, in palette order: index 0 is transparent.
pub const body = [3]u8{ 176, 176, 176 };
pub const ink = [3]u8{ 40, 40, 40 };
pub const text = [3]u8{ 248, 248, 248 };
pub const colours = [_][3]u8{ body, ink, text };

/// BG palette 6, CGRAM `$60`-`$6F`: nothing else writes there.
pub const palette: u3 = 6;
/// Past "Super"'s characters and below the readout's font at `$C0`.
pub const chr_first: u16 = 0x80;

pub const screen_x: u16 = screen.win_left + badge_at.x;
pub const screen_y: u16 = screen.band_top + target.view_h + badge_at.y;
pub const bg_x: u16 = screen_x;
pub const bg_y: u16 = screen_y + 1;

/// One badge's size; the PNG is `badge_h` rows a scheme.
pub const art_w: usize = 48;
pub const badge_h: usize = 16;
pub const patch = super.Patch(bg_x, bg_y, art_w, badge_h);
/// One scheme's patch, in map words.
pub const patch_words: usize = patch.cols * patch.rows;

pub const Error = error{ WrongSize, TooManyCharacters };

pub fn decode(a: std.mem.Allocator) !super.Art {
    const art = try super.decodeWith(a, png_bytes, &colours);
    errdefer art.deinit(a);
    if (art.w != art_w or art.h != badge_h * colors.count) return Error.WrongSize;
    return art;
}

pub const Blobs = struct { chr: []u8, pal: []u8, map: []u8 };

/// The three blobs, allocated in `a`.
pub fn blobs(a: std.mem.Allocator) !Blobs {
    const art = try decode(a);
    defer art.deinit(a);

    var chr: std.ArrayList(u8) = .empty;
    errdefer chr.deinit(a);
    const map = try a.alloc(u8, colors.count * patch_words * 2);
    errdefer a.free(map);

    for (0..colors.count) |s| {
        const top = s * badge_h;
        for (0..patch.rows) |ty| for (0..patch.cols) |tx| {
            const x0 = @as(isize, @intCast(tx * 8)) - @as(isize, patch.shift_x);
            const y0 = @as(isize, @intCast(top + ty * 8)) - @as(isize, patch.shift_y);
            var word: u16 = 0;
            if (super.encodeTile(art, x0, y0, top, top + badge_h)) |tile| {
                const id = for (0..chr.items.len / 32) |i| {
                    if (std.mem.eql(u8, chr.items[i * 32 ..][0..32], &tile)) break chr_first + i;
                } else blk: {
                    const id = chr_first + chr.items.len / 32;
                    if (id >= 0xC0) return Error.TooManyCharacters;
                    try chr.appendSlice(a, &tile);
                    break :blk id;
                };
                word = @as(u16, @intCast(id)) | (@as(u16, palette) << 10);
            }
            std.mem.writeInt(u16, map[(s * patch_words + ty * patch.cols + tx) * 2 ..][0..2], word, .little);
        };
    }

    // Colour 0 is written and never seen, as `title_super`'s is.
    const pal = try a.alloc(u8, (colours.len + 1) * 2);
    std.mem.writeInt(u16, pal[0..2], 0, .little);
    for (colours, 1..) |c, i| std.mem.writeInt(u16, pal[i * 2 ..][0..2], super.bgr15(c), .little);

    return .{ .chr = try chr.toOwnedSlice(a), .pal = pal, .map = map };
}

/// The badge as the screen shows it under `scheme`: `art_w` by `badge_h`,
/// each pixel 0 for transparent or 1 + its index in `colours`.
pub fn picture(a: std.mem.Allocator, scheme: colors.Scheme) ![art_w * badge_h]u8 {
    const art = try decode(a);
    defer art.deinit(a);
    var out: [art_w * badge_h]u8 = undefined;
    @memcpy(&out, art.px[@as(usize, @intFromEnum(scheme)) * art_w * badge_h ..][0 .. art_w * badge_h]);
    return out;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const chr_mod = @import("snes_chr.zig");

test "the badge sits in the bottom border, clear of the window and the right half" {
    try testing.expect(screen_y >= screen.band_top + target.view_h);
    try testing.expect(screen_y + badge_h <= target.screen_h);
    try testing.expect(screen_x + art_w <= target.screen_w / 2);
    // Clear of the readout's rows 2 and 3, and inside BG1's 32-row map.
    try testing.expect(patch.row > 3 and patch.row + patch.rows <= 32);
}

test "the blobs draw each scheme's badge back, pixel for pixel" {
    const a = testing.allocator;
    const bl = try blobs(a);
    defer {
        a.free(bl.chr);
        a.free(bl.pal);
        a.free(bl.map);
    }
    // The schemes share the glyph's tiles, so there are fewer characters than
    // the patches have words.
    try testing.expect(bl.chr.len / 32 < colors.count * patch_words);
    try testing.expect(chr_first + bl.chr.len / 32 <= 0xC0);
    for (0..colors.count) |s| {
        const want = try picture(a, @enumFromInt(s));
        for (0..patch.rows * 8) |y| for (0..patch.cols * 8) |x| {
            const word = std.mem.readInt(u16, bl.map[(s * patch_words + (y / 8) * patch.cols + x / 8) * 2 ..][0..2], .little);
            var got: u8 = 0;
            if (word != 0) {
                try testing.expectEqual(@as(u16, palette), (word >> 10) & 7);
                const tile = chr_mod.decodeSnes4bpp(bl.chr[((word & 0x3FF) - chr_first) * 32 ..][0..32]);
                got = tile[y % 8][x % 8];
            }
            const ax = @as(isize, @intCast(x)) - @as(isize, patch.shift_x);
            const ay = @as(isize, @intCast(y)) - @as(isize, patch.shift_y);
            const in = ax >= 0 and ay >= 0 and ax < art_w and ay < badge_h;
            try testing.expectEqual(if (in) want[@as(usize, @intCast(ay)) * art_w + @as(usize, @intCast(ax))] else 0, got);
        };
    }
}

test "the badges differ by scheme, and \"Super\"'s characters end below the badge's" {
    const a = testing.allocator;
    const m = try picture(a, .mono);
    const g = try picture(a, .gbc);
    try testing.expect(!std.mem.eql(u8, &m, &g));
    const sb = try super.blobs(a);
    defer {
        a.free(sb.chr);
        a.free(sb.pal);
        a.free(sb.map);
    }
    try testing.expect(super.chr_first + sb.chr.len / 32 <= chr_first);
    try testing.expect(palette != super.palette);
}
