//! Image composition for the inspection and A/B tools.
//!
//! Everything here builds indexed images out of pixels the two renderers
//! already produce; nothing here decides what is correct. `zig build verify` is
//! where the conversion is *judged* - these are for looking at it, which is a
//! different job and a much larger surface. A tool that decided correctness on
//! its own would be a second opinion the gate does not consult.
//!
//! ## The diff channel
//!
//! The middle question of an A/B view is not "do these differ" - the gate
//! answers that in one line - but "where, and does it look like a pattern".
//! So the diff panel is not a subtraction: matching pixels go flat neutral and
//! differing ones go a colour nothing else in the palette uses. A single wrong
//! character shows as a block; a transposed tilemap shows as the whole panel
//! lighting up. That is the property Step 10 asks to verify, and
//! `diffMarked` counts it so a test can assert it rather than a human squinting.

const std = @import("std");
const png = @import("png");

/// Indexes 0-3 are the DMG shades, so any panel drawn from a renderer's output
/// can be blitted unchanged. The rest are the tool's own furniture, chosen to
/// be impossible to mistake for game pixels.
pub const palette = [_][3]u8{
    png.dmg_palette[0],
    png.dmg_palette[1],
    png.dmg_palette[2],
    png.dmg_palette[3],
    .{ 0xE0, 0x20, 0x30 }, // differing
    .{ 0x20, 0x20, 0x24 }, // matching, in the diff panel
    .{ 0x00, 0x00, 0x00 }, // gutter
    .{ 0xF0, 0xC0, 0x20 }, // marker: a screen flagged on a contact sheet
};

pub const differing: u8 = 4;
pub const matching: u8 = 5;
pub const gutter: u8 = 6;
pub const marker: u8 = 7;

/// Pixels between panels, and around a contact sheet's cells.
pub const gutter_px: usize = 4;

pub const Image = struct {
    w: usize,
    h: usize,
    pixels: []u8,

    pub fn init(allocator: std.mem.Allocator, w: usize, h: usize, fill: u8) !Image {
        const pixels = try allocator.alloc(u8, w * h);
        @memset(pixels, fill);
        return .{ .w = w, .h = h, .pixels = pixels };
    }

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    /// Copy a `sw` x `sh` block of pixels in at `(x, y)`. Clipped, so a caller
    /// that miscounts gets a cropped picture rather than a corrupted heap.
    pub fn blit(self: Image, x: usize, y: usize, src: []const u8, sw: usize, sh: usize) void {
        for (0..sh) |row| {
            if (y + row >= self.h) break;
            const n = @min(sw, self.w -| x);
            if (n == 0) break;
            @memcpy(self.pixels[(y + row) * self.w + x ..][0..n], src[row * sw ..][0..n]);
        }
    }

    pub fn encode(self: Image, allocator: std.mem.Allocator) ![]u8 {
        return png.encodeIndexed(allocator, self.pixels, self.w, self.h, &palette);
    }
};

/// The diff panel: `matching` where the two agree, `differing` where they do
/// not.
pub fn diffPanel(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    std.debug.assert(a.len == b.len);
    const out = try allocator.alloc(u8, a.len);
    for (a, b, out) |x, y, *o| o.* = if (x == y) matching else differing;
    return out;
}

/// How many pixels a diff panel marked. The number Step 10's "visually obvious"
/// is measured with.
pub fn diffMarked(panel: []const u8) usize {
    var n: usize = 0;
    for (panel) |p| n += @intFromBool(p == differing);
    return n;
}

/// Three panels side by side - reference, converted, diff - separated by
/// gutters.
pub fn abImage(
    allocator: std.mem.Allocator,
    reference: []const u8,
    converted: []const u8,
    w: usize,
    h: usize,
) !Image {
    const diff = try diffPanel(allocator, reference, converted);
    defer allocator.free(diff);

    var img = try Image.init(allocator, w * 3 + gutter_px * 2, h, gutter);
    errdefer img.deinit(allocator);
    img.blit(0, 0, reference, w, h);
    img.blit(w + gutter_px, 0, converted, w, h);
    img.blit(w * 2 + gutter_px * 2, 0, diff, w, h);
    return img;
}

/// Nearest-neighbour reduction by an integer factor. Nearest rather than
/// averaging on purpose: these are palette indexes, and the mean of two shade
/// indexes is not a shade of anything.
pub fn downscale(allocator: std.mem.Allocator, pixels: []const u8, w: usize, h: usize, factor: usize) ![]u8 {
    std.debug.assert(factor >= 1);
    const ow = w / factor;
    const oh = h / factor;
    const out = try allocator.alloc(u8, ow * oh);
    for (0..oh) |y| {
        for (0..ow) |x| out[y * ow + x] = pixels[(y * factor) * w + x * factor];
    }
    return out;
}

/// Integer magnification, for showing 8x8 characters at a size a human can see.
pub fn upscale(allocator: std.mem.Allocator, pixels: []const u8, w: usize, h: usize, factor: usize) ![]u8 {
    std.debug.assert(factor >= 1);
    const ow = w * factor;
    const out = try allocator.alloc(u8, ow * h * factor);
    for (0..h * factor) |y| {
        for (0..ow) |x| out[y * ow + x] = pixels[(y / factor) * w + x / factor];
    }
    return out;
}

/// A grid of equally sized cells, with an optional flag colour drawn as a
/// border around any cell whose index is in `flagged`.
pub const Sheet = struct {
    cols: usize,
    cell_w: usize,
    cell_h: usize,

    pub fn size(self: Sheet, count: usize) struct { w: usize, h: usize } {
        const rows = (count + self.cols - 1) / self.cols;
        return .{
            .w = self.cols * (self.cell_w + gutter_px) + gutter_px,
            .h = rows * (self.cell_h + gutter_px) + gutter_px,
        };
    }

    pub fn origin(self: Sheet, index: usize) struct { x: usize, y: usize } {
        return .{
            .x = gutter_px + (index % self.cols) * (self.cell_w + gutter_px),
            .y = gutter_px + (index / self.cols) * (self.cell_h + gutter_px),
        };
    }
};

/// Draw a `gutter_px`-wide border in `colour` around the cell at `index`.
/// This is how a contact sheet says "look at this one" without any text.
pub fn flagCell(img: Image, sheet: Sheet, index: usize, colour: u8) void {
    const o = sheet.origin(index);
    const x0 = o.x -| gutter_px;
    const y0 = o.y -| gutter_px;
    const w = sheet.cell_w + gutter_px * 2;
    const h = sheet.cell_h + gutter_px * 2;
    for (0..h) |dy| {
        const y = y0 + dy;
        if (y >= img.h) break;
        for (0..w) |dx| {
            const x = x0 + dx;
            if (x >= img.w) break;
            const inside = dx >= gutter_px and dx < w - gutter_px and dy >= gutter_px and dy < h - gutter_px;
            if (!inside) img.pixels[y * img.w + x] = colour;
        }
    }
}

/// How loudly a fault shows in the diff channel, over a set of screens.
///
/// "Visually obvious" is not one number, because it is not one property. A
/// palette error recolours every pixel of every screen; a transposed metatile
/// quadrant is invisible on a metatile that happens to be symmetric, and the
/// retail ROM is full of those - `18 19 19 18` transposes to itself. So both
/// ends are reported: how much of the game notices at all, and how loud the
/// loudest screen is. A fault that fails the first is not caught; a fault that
/// passes the first but fails the second is caught by the gate and still worth
/// knowing about, because it is the kind a human staring at one screen would
/// miss.
pub const Loudness = struct {
    screens: usize = 0,
    screens_marked: usize = 0,
    pixels: usize = 0,
    pixels_marked: usize = 0,
    /// The largest single-screen marked fraction, in hundredths of a percent.
    loudest_bp: usize = 0,

    pub fn add(self: *Loudness, panel: []const u8) void {
        const marked = diffMarked(panel);
        self.screens += 1;
        self.pixels += panel.len;
        self.pixels_marked += marked;
        if (marked != 0) self.screens_marked += 1;
        const bp = marked * 10_000 / panel.len;
        if (bp > self.loudest_bp) self.loudest_bp = bp;
    }

    /// Marked fraction over everything, in hundredths of a percent.
    pub fn overallBp(self: Loudness) usize {
        if (self.pixels == 0) return 0;
        return self.pixels_marked * 10_000 / self.pixels;
    }
};

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

test "the diff panel marks exactly the differing pixels" {
    const gpa = testing.allocator;
    const a = [_]u8{ 0, 1, 2, 3 };
    const b = [_]u8{ 0, 1, 3, 3 };
    const d = try diffPanel(gpa, &a, &b);
    defer gpa.free(d);
    try testing.expectEqualSlices(u8, &.{ matching, matching, differing, matching }, d);
    try testing.expectEqual(@as(usize, 1), diffMarked(d));
    // Identical input marks nothing, which is what makes a nonzero count mean
    // something.
    const same = try diffPanel(gpa, &a, &a);
    defer gpa.free(same);
    try testing.expectEqual(@as(usize, 0), diffMarked(same));
}

test "the A/B image is three panels and two gutters" {
    const gpa = testing.allocator;
    const a = [_]u8{ 1, 2, 3, 0 };
    const b = [_]u8{ 1, 2, 0, 0 };
    var img = try abImage(gpa, &a, &b, 2, 2);
    defer img.deinit(gpa);
    try testing.expectEqual(@as(usize, 2 * 3 + gutter_px * 2), img.w);
    try testing.expectEqual(@as(usize, 2), img.h);
    // Reference at 0, converted after one gutter, diff after two.
    try testing.expectEqual(@as(u8, 3), img.pixels[1 * img.w + 0]);
    try testing.expectEqual(@as(u8, 0), img.pixels[1 * img.w + 2 + gutter_px]);
    try testing.expectEqual(differing, img.pixels[1 * img.w + 4 + gutter_px * 2]);
    try testing.expectEqual(matching, img.pixels[0 * img.w + 4 + gutter_px * 2]);
    // And the gutter is gutter.
    try testing.expectEqual(gutter, img.pixels[2]);
}

test "scaling is nearest-neighbour both ways and round-trips at the same factor" {
    const gpa = testing.allocator;
    const src = [_]u8{ 0, 1, 2, 3 }; // 2x2
    const up = try upscale(gpa, &src, 2, 2, 2);
    defer gpa.free(up);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3 }, up);
    const down = try downscale(gpa, up, 4, 4, 2);
    defer gpa.free(down);
    try testing.expectEqualSlices(u8, &src, down);
}

test "a sheet's cells do not overlap and stay inside the image" {
    const sheet: Sheet = .{ .cols = 4, .cell_w = 16, .cell_h = 16 };
    const s = sheet.size(10); // three rows
    try testing.expectEqual(@as(usize, 4 * 20 + gutter_px), s.w);
    try testing.expectEqual(@as(usize, 3 * 20 + gutter_px), s.h);
    for (0..10) |i| {
        const o = sheet.origin(i);
        try testing.expect(o.x + sheet.cell_w <= s.w);
        try testing.expect(o.y + sheet.cell_h <= s.h);
        for (0..i) |j| {
            const p = sheet.origin(j);
            const overlaps = o.x < p.x + sheet.cell_w and p.x < o.x + sheet.cell_w and
                o.y < p.y + sheet.cell_h and p.y < o.y + sheet.cell_h;
            try testing.expect(!overlaps);
        }
    }
}

test "flagging a cell draws a border and leaves the cell itself alone" {
    const gpa = testing.allocator;
    const sheet: Sheet = .{ .cols = 2, .cell_w = 8, .cell_h = 8 };
    const s = sheet.size(4);
    var img = try Image.init(gpa, s.w, s.h, 0);
    defer img.deinit(gpa);
    flagCell(img, sheet, 1, marker);
    const o = sheet.origin(1);
    // Inside untouched, border marked.
    try testing.expectEqual(@as(u8, 0), img.pixels[o.y * img.w + o.x]);
    try testing.expectEqual(marker, img.pixels[(o.y - 1) * img.w + o.x]);
    try testing.expectEqual(marker, img.pixels[o.y * img.w + o.x - 1]);
    // And its neighbour's interior is untouched.
    const p = sheet.origin(0);
    try testing.expectEqual(@as(u8, 0), img.pixels[p.y * img.w + p.x + sheet.cell_w - 1]);
}

test "blitting past an edge clips instead of overrunning" {
    const gpa = testing.allocator;
    var img = try Image.init(gpa, 4, 4, 0);
    defer img.deinit(gpa);
    const src = [_]u8{ 9, 9, 9, 9, 9, 9, 9, 9, 9 }; // 3x3
    img.blit(2, 2, &src, 3, 3);
    try testing.expectEqual(@as(u8, 9), img.pixels[2 * 4 + 2]);
    try testing.expectEqual(@as(u8, 9), img.pixels[3 * 4 + 3]);
    // Nothing wrote outside, and the untouched corner is still fill.
    try testing.expectEqual(@as(u8, 0), img.pixels[0]);
}

const render = @import("snes_render.zig");
const convert = @import("snes_convert.zig");
const screens = @import("screens.zig");
const testrom = @import("testrom");

test "loudness is zero for identical input and rises with what differs" {
    var l: Loudness = .{};
    l.add(&[_]u8{ matching, matching, matching, matching });
    try testing.expectEqual(@as(usize, 0), l.screens_marked);
    try testing.expectEqual(@as(usize, 0), l.overallBp());
    l.add(&[_]u8{ differing, differing, matching, matching });
    try testing.expectEqual(@as(usize, 1), l.screens_marked);
    try testing.expectEqual(@as(usize, 5000), l.loudest_bp);
    // Two panels of four, two marked pixels in eight.
    try testing.expectEqual(@as(usize, 2500), l.overallBp());
}

test "a corrupted conversion lights up the diff channel" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);

    var set = try convert.run(gpa, rom);
    defer set.deinit();
    var r = try render.Renderer.init(gpa, rom, set);
    defer r.deinit();

    // One bank is enough to make the point and keeps the test to a second.
    const bank: u8 = 0x9;

    const measure = struct {
        fn f(rr: *render.Renderer, allocator: std.mem.Allocator, b: u8, fault: render.Fault) !Loudness {
            var l: Loudness = .{};
            for (rr.assignment.cells) |c| {
                if (c.bank != b) continue;
                var p = (try rr.pair(c, null, fault)) orelse continue;
                defer p.deinit(allocator);
                const panel = try diffPanel(allocator, p.gb.pixels, p.snes.pixels);
                defer allocator.free(panel);
                l.add(panel);
            }
            return l;
        }
    }.f;

    // Clean: the channel is entirely neutral. Anything else here and the
    // thresholds below would be measuring noise.
    const clean = try measure(&r, gpa, bank, .none);
    try testing.expect(clean.screens > 100);
    try testing.expectEqual(@as(usize, 0), clean.screens_marked);
    try testing.expectEqual(@as(usize, 0), clean.pixels_marked);

    for (std.enums.values(render.Fault)) |f| {
        if (f == .none) continue;
        const l = try measure(&r, gpa, bank, f);
        // A clear majority of the bank notices, rather than all of it. Some of
        // bank $9's 151 screens do not see `metatile_quadrants`, because every
        // metatile they use is symmetric under a transpose - `18 19 19 18`
        // transposes to itself, and the ROM has many like it. Measured:
        //
        //     metatile_quadrants  139/151, loudest 25.7%, overall 12.1%
        //     tilemap_transpose   141/151, loudest 67.1%, overall 37.5%
        //     palette_permute     151/151, loudest  100%, overall  100%
        //     bitplane_swap       151/151, loudest 70.6%, overall 24.8%
        //
        // **Two of these bars moved on 2026-09-05, and the reason is bank $9.**
        // They were 148/151 and 151/151 against a flat 95% until
        // `screens.assign` learned to carry a tileset through a door that names
        // none. That changed the table 15 of bank $9's 151 screens are drawn
        // with, onto tables where some of the metatile indices those screens
        // use expand to the same four tiles -- so a transposed body or a
        // transposed quadrant leaves the picture unchanged.
        //
        // **This is the cost of the pass, stated where it was measured.** Over
        // the whole map the pass is a clear improvement -- screens whose table
        // collapses metatiles they use fall from 173 to 142, the frames drawing
        // from VRAM no door wrote fall from 72 to 69, and `zig build oracle --
        // worlds` goes from 19 of 34 cells agreeing with a running Game Boy to
        // 24 with none regressing. Bank $9 is where it goes the other way, and
        // no published run reaches bank $9 to say which answer is right.
        //
        // `palette_permute` and `bitplane_swap` keep the 95%: they perturb the
        // pixels rather than the arrangement, so a flat screen still notices
        // them, and a change that made those quieter would be a different and
        // worse problem.
        const bar: usize = switch (f) {
            .metatile_quadrants, .tilemap_transpose => 90,
            else => 95,
        };
        if (l.screens_marked * 100 < l.screens * bar) {
            std.debug.print("\nfault {s}: {d}/{d} screens marked, bar {d}%\n", .{
                @tagName(f), l.screens_marked, l.screens, bar,
            });
        }
        try testing.expect(l.screens_marked * 100 >= l.screens * bar);
        // And somewhere in the bank it is unmissable - a tenth of a screen or
        // more. `metatile_quadrants` is the reason this is a per-bank maximum
        // rather than a per-screen floor: on a screen built from symmetric
        // metatiles it marks almost nothing.
        if (l.loudest_bp < 1000 or l.overallBp() < 1000) {
            std.debug.print("\nfault {s}: loudest screen {d}bp, overall {d}bp\n", .{
                @tagName(f), l.loudest_bp, l.overallBp(),
            });
        }
        try testing.expect(l.loudest_bp >= 1000);
        try testing.expect(l.overallBp() >= 1000);
    }
}
