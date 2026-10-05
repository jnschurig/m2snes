//! A PNG writer for shade-indexed images.
//!
//! Reference frames are stored as colour-type-3 (indexed) PNGs whose palette is
//! the four DMG greens. That choice does double duty: the file opens in any
//! viewer, and its pixel bytes *are* the shade indexes, so diffing two frames
//! is a byte comparison rather than a colour-space argument.
//!
//! Compression is stored (uncompressed) deflate blocks. Reference frames are
//! untracked scratch output regenerated from the ROM, so a few megabytes buys
//! nothing worth the surface area of a real compressor here.

const std = @import("std");

/// The DMG's four shades, lightest first, in the greenish tint the hardware
/// actually shows. Only ever a *display* choice -- nothing compares against it.
pub const dmg_palette = [4][3]u8{
    .{ 0x9B, 0xBC, 0x0F },
    .{ 0x8B, 0xAC, 0x0F },
    .{ 0x30, 0x62, 0x30 },
    .{ 0x0F, 0x38, 0x0F },
};

pub const Error = error{ BadDimensions, PixelCountMismatch };

/// Encode `pixels` (one byte per pixel, each an index into `palette`) as PNG.
pub fn encodeIndexed(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    w: usize,
    h: usize,
    palette: []const [3]u8,
) ![]u8 {
    if (w == 0 or h == 0 or palette.len == 0 or palette.len > 256) return Error.BadDimensions;
    if (pixels.len != w * h) return Error.PixelCountMismatch;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(w), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(h), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 3; // colour type: indexed
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // no interlace
    try chunk(allocator, &out, "IHDR", &ihdr);

    var plte: [768]u8 = undefined;
    for (palette, 0..) |c, i| @memcpy(plte[i * 3 ..][0..3], &c);
    try chunk(allocator, &out, "PLTE", plte[0 .. palette.len * 3]);

    // Raw scanlines, each prefixed with filter type 0.
    var raw = try allocator.alloc(u8, h * (w + 1));
    defer allocator.free(raw);
    for (0..h) |y| {
        raw[y * (w + 1)] = 0;
        @memcpy(raw[y * (w + 1) + 1 ..][0..w], pixels[y * w ..][0..w]);
    }

    const z = try zlibStored(allocator, raw);
    defer allocator.free(z);
    try chunk(allocator, &out, "IDAT", z);
    try chunk(allocator, &out, "IEND", &.{});
    return out.toOwnedSlice(allocator);
}

fn chunk(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tag: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(allocator, &len);
    try out.appendSlice(allocator, tag);
    try out.appendSlice(allocator, data);
    var h = std.hash.Crc32.init();
    h.update(tag);
    h.update(data);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, h.final(), .big);
    try out.appendSlice(allocator, &crc);
}

/// zlib stream made of stored deflate blocks.
fn zlibStored(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &.{ 0x78, 0x01 }); // deflate, 32K window, no dict

    var i: usize = 0;
    while (true) {
        const n = @min(data.len - i, 0xFFFF);
        const final: u8 = if (i + n >= data.len) 1 else 0;
        try out.append(allocator, final);
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u16, hdr[0..2], @intCast(n), .little);
        std.mem.writeInt(u16, hdr[2..4], @intCast(~@as(u16, @intCast(n))), .little);
        try out.appendSlice(allocator, &hdr);
        try out.appendSlice(allocator, data[i..][0..n]);
        i += n;
        if (final == 1) break;
    }

    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, adler32(data), .big);
    try out.appendSlice(allocator, &adler);
    return out.toOwnedSlice(allocator);
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |c| {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "an encoded image decodes back to the pixels it was given" {
    const gpa = testing.allocator;
    var pixels: [64 * 40]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i % 4);

    const png = try encodeIndexed(gpa, &pixels, 64, 40, &dmg_palette);
    defer gpa.free(png);

    try testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G' }, png[0..4]);
    // IHDR carries the dimensions we asked for.
    try testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, png[16..20], .big));
    try testing.expectEqual(@as(u32, 40), std.mem.readInt(u32, png[20..24], .big));

    const back = try decodeIndexed(gpa, png);
    defer gpa.free(back.pixels);
    try testing.expectEqual(@as(usize, 64), back.w);
    try testing.expectEqual(@as(usize, 40), back.h);
    try testing.expectEqualSlices(u8, &pixels, back.pixels);
}

test "a stream larger than one stored block still round-trips" {
    const gpa = testing.allocator;
    // 256x256 with the filter bytes is 65792 -- past the 65535 block limit, so
    // this is the case a single-block writer would silently truncate.
    const pixels = try gpa.alloc(u8, 256 * 256);
    defer gpa.free(pixels);
    var rng = std.Random.DefaultPrng.init(7);
    for (pixels) |*p| p.* = rng.random().int(u8) % 4;

    const png = try encodeIndexed(gpa, pixels, 256, 256, &dmg_palette);
    defer gpa.free(png);
    const back = try decodeIndexed(gpa, png);
    defer gpa.free(back.pixels);
    try testing.expectEqualSlices(u8, pixels, back.pixels);
}

test "dimensions that do not match the pixel count are refused" {
    const gpa = testing.allocator;
    var pixels: [10]u8 = @splat(0);
    try testing.expectError(Error.PixelCountMismatch, encodeIndexed(gpa, &pixels, 4, 4, &dmg_palette));
    try testing.expectError(Error.BadDimensions, encodeIndexed(gpa, &pixels, 0, 4, &dmg_palette));
}

/// Minimal reader for the subset this file writes: 8-bit indexed, filter 0,
/// stored deflate. Exists so the round-trip test is a real decode rather than
/// a re-run of the encoder's own arithmetic.
pub const Decoded = struct { w: usize, h: usize, pixels: []u8 };

pub fn decodeIndexed(allocator: std.mem.Allocator, png: []const u8) !Decoded {
    var w: usize = 0;
    var h: usize = 0;
    var idat: []const u8 = &.{};
    var pos: usize = 8;
    while (pos + 8 <= png.len) {
        const len = std.mem.readInt(u32, png[pos..][0..4], .big);
        const tag = png[pos + 4 ..][0..4];
        const data = png[pos + 8 ..][0..len];
        if (std.mem.eql(u8, tag, "IHDR")) {
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            idat = data;
        }
        pos += 12 + len;
    }

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    var i: usize = 2; // past the zlib header
    while (i + 5 <= idat.len) {
        const final = idat[i] & 1;
        const n = std.mem.readInt(u16, idat[i + 1 ..][0..2], .little);
        try raw.appendSlice(allocator, idat[i + 5 ..][0..n]);
        i += 5 + @as(usize, n);
        if (final == 1) break;
    }

    const pixels = try allocator.alloc(u8, w * h);
    errdefer allocator.free(pixels);
    for (0..h) |y| @memcpy(pixels[y * w ..][0..w], raw.items[y * (w + 1) + 1 ..][0..w]);
    return .{ .w = w, .h = h, .pixels = pixels };
}

pub const RgbaError = error{ NotAPng, UnsupportedFormat, BadFilter, Truncated };

/// A reader for PNGs an image editor wrote, Step 24j: 8-bit RGBA (colour type
/// 6), not interlaced, real deflate and all five row filters. `pixels` is four
/// bytes a pixel, R G B A. Everything else is refused rather than guessed at;
/// the one file it exists for, `assets/title_super.png`, is this format.
pub fn decodeRgba(allocator: std.mem.Allocator, png: []const u8) !Decoded {
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (png.len < 8 or !std.mem.eql(u8, png[0..8], &sig)) return RgbaError.NotAPng;
    var w: usize = 0;
    var h: usize = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    var pos: usize = 8;
    while (pos + 12 <= png.len) {
        const len = std.mem.readInt(u32, png[pos..][0..4], .big);
        if (pos + 12 + len > png.len) return RgbaError.Truncated;
        const tag = png[pos + 4 ..][0..4];
        const data = png[pos + 8 ..][0..len];
        if (std.mem.eql(u8, tag, "IHDR")) {
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
            // Bit depth 8, colour type 6, and compression, filter and
            // interlace methods all 0.
            if (!std.mem.eql(u8, data[8..13], &.{ 8, 6, 0, 0, 0 })) return RgbaError.UnsupportedFormat;
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            try idat.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, tag, "IEND")) break;
        pos += 12 + len;
    }
    if (w == 0 or h == 0) return RgbaError.NotAPng;

    var input: std.Io.Reader = .fixed(idat.items);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var d = std.compress.flate.Decompress.init(&input, .zlib, window);
    const stride = w * 4;
    const raw = try d.reader.readAlloc(allocator, h * (stride + 1));
    defer allocator.free(raw);

    const pixels = try allocator.alloc(u8, h * stride);
    errdefer allocator.free(pixels);
    for (0..h) |y| {
        const filter = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const row = pixels[y * stride ..][0..stride];
        const up: ?[]const u8 = if (y == 0) null else pixels[(y - 1) * stride ..][0..stride];
        for (0..stride) |i| {
            const a: i32 = if (i >= 4) row[i - 4] else 0;
            const b: i32 = if (up) |u| u[i] else 0;
            const c: i32 = if (i >= 4) (if (up) |u| u[i - 4] else 0) else 0;
            const pred: i32 = switch (filter) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @divFloor(a + b, 2),
                4 => paeth(a, b, c),
                else => return RgbaError.BadFilter,
            };
            row[i] = src[i] +% @as(u8, @intCast(pred));
        }
    }
    return .{ .w = w, .h = h, .pixels = pixels };
}

fn paeth(a: i32, b: i32, c: i32) i32 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}
