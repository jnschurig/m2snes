//! DMG background and window rasterisation.
//!
//! Scope is deliberate: background and window only, no sprites. Step 7 needs
//! reference *screens*, and every pixel of a Metroid II screen comes from the
//! background layer; Samus and the enemies are objects, and F9 reviews those
//! through the assembled-metasprite view instead. Leaving OAM out means this
//! file cannot silently paper over a background bug with a sprite drawn on top.
//!
//! The renderer is per-scanline, driven from `bus.Video` at the start of mode 3
//! -- the moment the real PPU latches SCY/SCX and begins fetching. That timing
//! is the whole point: Metroid II splits the frame partway down to hold its
//! status bar still while the room scrolls, and a renderer that sampled the
//! scroll registers at end-of-line would attribute every split to the wrong
//! scanline.
//!
//! Output is a shade index 0-3 per pixel -- what came out of BGP, not a colour.
//! Choosing RGB is the display's job, and keeping the framebuffer in shade
//! space means a comparison against another emulator is a comparison of pixel
//! values rather than of palette taste.

const std = @import("std");
const bus_mod = @import("bus.zig");
const lcd_mod = @import("lcd.zig");

pub const width: usize = 160;
pub const height: usize = 144;
pub const pixels: usize = width * height;

/// A shade index as BGP produced it: 0 is white, 3 is black.
pub const Shade = u8;

/// What the registers looked like when a line was latched. Recorded per line
/// so a scroll split shows up as data rather than as a visual impression.
pub const LineState = struct {
    lcdc: u8,
    scy: u8,
    scx: u8,
    wy: u8,
    wx: u8,
    bgp: u8,
};

pub const Ppu = struct {
    frame: [pixels]Shade = @splat(0),
    lines: [height]LineState = @splat(.{ .lcdc = 0, .scy = 0, .scx = 0, .wy = 0, .wx = 0, .bgp = 0 }),
    /// The window's own line counter. It advances only on lines where the
    /// window actually drew, which is why a window that switches off for a few
    /// lines resumes where it left off instead of jumping.
    window_line: u8 = 0,
    /// Lines rasterised since the last `startFrame`, for callers that want to
    /// know a frame is whole before trusting it.
    drawn: u16 = 0,

    pub fn startFrame(self: *Ppu) void {
        self.window_line = 0;
        self.drawn = 0;
    }

    /// The `bus.Video` seam. `ctx` is a `*Ppu`.
    pub fn video(self: *Ppu) bus_mod.Video {
        return .{ .ctx = @ptrCast(self), .line = onLine };
    }

    fn onLine(ctx: *anyopaque, bus: *const bus_mod.Bus, ly: u8) void {
        const self: *Ppu = @ptrCast(@alignCast(ctx));
        if (ly == 0) self.startFrame();
        self.renderLine(bus, ly);
    }

    pub fn renderLine(self: *Ppu, bus: *const bus_mod.Bus, ly: u8) void {
        if (ly >= height) return;
        const l = bus.lcd;
        self.lines[ly] = .{ .lcdc = l.lcdc, .scy = l.scy, .scx = l.scx, .wy = l.wy, .wx = l.wx, .bgp = l.bgp };
        self.drawn += 1;
        const row = self.frame[@as(usize, ly) * width ..][0..width];

        // LCDC bit 0 on DMG blanks background *and* window: colour 0 through
        // BGP, not raw white, because BGP can remap 0 to something darker.
        if (l.lcdc & 0x01 == 0) {
            @memset(row, shadeOf(l.bgp, 0));
            return;
        }

        const bg_map: u16 = if (l.lcdc & 0x08 != 0) 0x9C00 else 0x9800;
        const win_map: u16 = if (l.lcdc & 0x40 != 0) 0x9C00 else 0x9800;
        const win_on = (l.lcdc & 0x20 != 0) and ly >= l.wy and l.wx <= 166;

        var drew_window = false;
        const bg_y: u8 = ly +% l.scy;

        for (0..width) |x| {
            var index: u2 = undefined;
            // WX is offset by 7: WX=7 puts the window's first column at x=0.
            if (win_on and @as(i32, @intCast(x)) + 7 >= @as(i32, l.wx)) {
                drew_window = true;
                const wx_off: usize = @intCast(@as(i32, @intCast(x)) + 7 - @as(i32, l.wx));
                index = self.fetch(bus, win_map, self.window_line, @intCast(wx_off & 0xFF));
            } else {
                index = self.fetch(bus, bg_map, bg_y, @intCast((x +% l.scx) & 0xFF));
            }
            row[x] = shadeOf(l.bgp, index);
        }

        if (drew_window) self.window_line +%= 1;
    }

    /// One background pixel: map lookup, tile-data addressing, 2bpp unpack.
    fn fetch(self: *Ppu, bus: *const bus_mod.Bus, map_base: u16, y: u8, x: u8) u2 {
        _ = self;
        const l = bus.lcd;
        const map_addr = map_base + (@as(u16, y / 8) * 32) + @as(u16, x / 8);
        const tile = bus.vram[map_addr - 0x8000];

        // LCDC bit 4 picks the addressing mode, not just the base: the $8800
        // block is indexed by a *signed* tile number from $9000.
        const data: u16 = if (l.lcdc & 0x10 != 0)
            0x8000 + @as(u16, tile) * 16
        else
            @intCast(@as(i32, 0x9000) + @as(i32, @as(i8, @bitCast(tile))) * 16);

        const off = data - 0x8000 + @as(u16, y % 8) * 2;
        const lo = bus.vram[off];
        const hi = bus.vram[off + 1];
        const bit: u3 = @intCast(7 - (x % 8));
        return @intCast((@as(u2, @intCast((lo >> bit) & 1))) |
            (@as(u2, @intCast((hi >> bit) & 1)) << 1));
    }

    /// Whether every visible line of the last frame was rasterised. A partial
    /// frame is not a rendering bug to report as pixels -- it means the LCD was
    /// off, and saying so is more useful than shipping a half-drawn image.
    pub fn complete(self: Ppu) bool {
        return self.drawn >= height;
    }

    /// The first line on which the window drew, if it drew at all.
    ///
    /// Metroid II's status bar is a *window*, not a scroll split -- the
    /// distinction matters because the window has its own line counter and
    /// ignores SCX/SCY entirely, so a renderer that modelled the status bar as
    /// a mid-frame scroll write would produce a plausible-looking frame with
    /// the wrong contents below the seam.
    pub fn windowStart(self: Ppu) ?u8 {
        for (self.lines, 0..) |l, i| {
            const on = l.lcdc & 0x01 != 0 and l.lcdc & 0x20 != 0 and l.wx <= 166;
            if (on and i >= l.wy) return @intCast(i);
        }
        return null;
    }

    /// Where the scroll registers change partway down the frame. Returns the
    /// first line whose SCY or SCX differs from the line above it.
    pub fn scrollSplit(self: Ppu) ?u8 {
        var i: u8 = 1;
        while (i < height) : (i += 1) {
            if (self.lines[i].scy != self.lines[i - 1].scy or
                self.lines[i].scx != self.lines[i - 1].scx) return i;
        }
        return null;
    }
};

/// BGP maps a 2-bit colour index to a 2-bit shade, two bits per index.
pub fn shadeOf(bgp: u8, index: u2) Shade {
    return @intCast((bgp >> (@as(u3, index) * 2)) & 3);
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const cart_mod = @import("cart.zig");

/// A bus with a one-bank ROM, enough to hold VRAM and the LCD registers.
fn testBus(rom: *[0x8000]u8, ram: *[0x2000]u8) !bus_mod.Bus {
    rom[0x147] = 0x00; // ROM only
    rom[0x148] = 0x00; // 32 KiB
    return bus_mod.Bus.init(try cart_mod.Cart.init(rom, ram));
}

/// Write one 8x8 tile whose every pixel is `index`.
fn solidTile(bus: *bus_mod.Bus, tile: u8, index: u2) void {
    const base: usize = @as(usize, tile) * 16;
    for (0..8) |r| {
        bus.vram[base + r * 2] = if (index & 1 != 0) 0xFF else 0x00;
        bus.vram[base + r * 2 + 1] = if (index & 2 != 0) 0xFF else 0x00;
    }
}

test "BGP remaps colour indexes to shades" {
    try testing.expectEqual(@as(Shade, 0), shadeOf(0xE4, 0));
    try testing.expectEqual(@as(Shade, 1), shadeOf(0xE4, 1));
    try testing.expectEqual(@as(Shade, 2), shadeOf(0xE4, 2));
    try testing.expectEqual(@as(Shade, 3), shadeOf(0xE4, 3));
    // The inverted palette the game fades through must invert the output too.
    try testing.expectEqual(@as(Shade, 3), shadeOf(0x1B, 0));
    try testing.expectEqual(@as(Shade, 0), shadeOf(0x1B, 3));
}

test "a checkerboard tilemap renders as 8-pixel blocks" {
    var rom: [0x8000]u8 = @splat(0);
    var ram: [0x2000]u8 = @splat(0);
    var bus = try testBus(&rom, &ram);
    bus.lcd.lcdc = 0x91; // on, BG on, $8000 addressing, $9800 map
    bus.lcd.bgp = 0xE4;
    solidTile(&bus, 0, 0);
    solidTile(&bus, 1, 3);
    for (0..32) |ty| for (0..32) |tx| {
        bus.vram[0x9800 - 0x8000 + ty * 32 + tx] = @intCast((tx + ty) % 2);
    };

    var ppu: Ppu = .{};
    ppu.startFrame();
    for (0..height) |ly| ppu.renderLine(&bus, @intCast(ly));
    try testing.expect(ppu.complete());
    try testing.expectEqual(@as(Shade, 0), ppu.frame[0]);
    try testing.expectEqual(@as(Shade, 3), ppu.frame[8]);
    try testing.expectEqual(@as(Shade, 3), ppu.frame[8 * width]);
    try testing.expectEqual(@as(Shade, 0), ppu.frame[8 * width + 8]);
}

test "signed tile addressing reaches the $8800 block" {
    var rom: [0x8000]u8 = @splat(0);
    var ram: [0x2000]u8 = @splat(0);
    var bus = try testBus(&rom, &ram);
    bus.lcd.lcdc = 0x81; // on, BG on, $8800 addressing
    bus.lcd.bgp = 0xE4;
    // Tile 0 is the one number the two modes disagree about most: $8000
    // unsigned, $9000 signed. (Tile $FF would have been a useless choice --
    // $8000 + 255*16 and $9000 - 16 are the same address.)
    for (0..8) |r| {
        bus.vram[0x9000 - 0x8000 + r * 2] = 0xFF;
        bus.vram[0x9000 - 0x8000 + r * 2 + 1] = 0xFF;
    }
    @memset(bus.vram[0x9800 - 0x8000 ..][0..0x400], 0);

    var ppu: Ppu = .{};
    ppu.startFrame();
    ppu.renderLine(&bus, 0);
    try testing.expectEqual(@as(Shade, 3), ppu.frame[0]);

    // The same tile number under $8000 addressing must land somewhere else, or
    // the two modes are not actually distinguished.
    bus.lcd.lcdc = 0x91;
    ppu.renderLine(&bus, 0);
    try testing.expectEqual(@as(Shade, 0), ppu.frame[0]);
}

test "SCX and SCY wrap within the 256-pixel tilemap" {
    var rom: [0x8000]u8 = @splat(0);
    var ram: [0x2000]u8 = @splat(0);
    var bus = try testBus(&rom, &ram);
    bus.lcd.lcdc = 0x91;
    bus.lcd.bgp = 0xE4;
    solidTile(&bus, 0, 0);
    solidTile(&bus, 1, 3);
    // Only the very last tile column and row are non-zero.
    @memset(bus.vram[0x9800 - 0x8000 ..][0..0x400], 0);
    bus.vram[0x9800 - 0x8000 + 31 * 32 + 31] = 1;

    var ppu: Ppu = .{};
    ppu.startFrame();
    // Scroll so that map tile (31,31) lands at screen (0,0).
    bus.lcd.scx = 31 * 8;
    bus.lcd.scy = 31 * 8;
    ppu.renderLine(&bus, 0);
    try testing.expectEqual(@as(Shade, 3), ppu.frame[0]);
    try testing.expectEqual(@as(Shade, 0), ppu.frame[8]); // wrapped to tile 0
}

test "a scroll written between lines moves only the lines below it" {
    var rom: [0x8000]u8 = @splat(0);
    var ram: [0x2000]u8 = @splat(0);
    var bus = try testBus(&rom, &ram);
    bus.lcd.lcdc = 0x91;
    bus.lcd.bgp = 0xE4;
    solidTile(&bus, 0, 0);
    solidTile(&bus, 1, 3);
    @memset(bus.vram[0x9800 - 0x8000 ..][0..0x400], 0);
    // Tile column 0 is dark only on map row 14.
    bus.vram[0x9800 - 0x8000 + 14 * 32] = 1;

    var ppu: Ppu = .{};
    ppu.startFrame();
    for (0..height) |ly| {
        // The split: from line 100 down, add 16 to SCY. Line 99 then samples
        // map row 12 (light) and line 100 samples row 14 (dark).
        if (ly == 100) bus.lcd.scy = 16;
        ppu.renderLine(&bus, @intCast(ly));
    }
    try testing.expectEqual(@as(Shade, 0), ppu.frame[99 * width]);
    try testing.expectEqual(@as(Shade, 3), ppu.frame[100 * width]);
    try testing.expectEqual(@as(u8, 100), ppu.scrollSplit().?);
}

test "the window covers the background from WX and its own line counter" {
    var rom: [0x8000]u8 = @splat(0);
    var ram: [0x2000]u8 = @splat(0);
    var bus = try testBus(&rom, &ram);
    bus.lcd.lcdc = 0x91 | 0x20 | 0x40; // window on, window map $9C00
    bus.lcd.bgp = 0xE4;
    solidTile(&bus, 0, 0);
    solidTile(&bus, 1, 3);
    @memset(bus.vram[0x9800 - 0x8000 ..][0..0x400], 0); // background: light
    @memset(bus.vram[0x9C00 - 0x8000 ..][0..0x400], 1); // window: dark
    bus.lcd.wy = 100;
    bus.lcd.wx = 7 + 80;

    var ppu: Ppu = .{};
    ppu.startFrame();
    for (0..height) |ly| ppu.renderLine(&bus, @intCast(ly));

    try testing.expectEqual(@as(Shade, 0), ppu.frame[99 * width + 100]); // above WY
    try testing.expectEqual(@as(Shade, 0), ppu.frame[100 * width + 79]); // left of WX
    try testing.expectEqual(@as(Shade, 3), ppu.frame[100 * width + 80]); // first window column
    // 44 lines drew the window, so its line counter advanced 44 times.
    try testing.expectEqual(@as(u8, 44), ppu.window_line);
}

test "LCDC bit 0 blanks the line through BGP rather than to raw white" {
    var rom: [0x8000]u8 = @splat(0);
    var ram: [0x2000]u8 = @splat(0);
    var bus = try testBus(&rom, &ram);
    bus.lcd.lcdc = 0x90; // BG disabled
    bus.lcd.bgp = 0x1B; // inverted: index 0 maps to shade 3
    solidTile(&bus, 0, 3);

    var ppu: Ppu = .{};
    ppu.startFrame();
    ppu.renderLine(&bus, 0);
    try testing.expectEqual(@as(Shade, 3), ppu.frame[0]);
}

test "the video seam renders through the bus at mode 3" {
    var rom: [0x8000]u8 = @splat(0);
    var ram: [0x2000]u8 = @splat(0);
    var bus = try testBus(&rom, &ram);
    bus.lcd.lcdc = 0x91;
    bus.lcd.bgp = 0xE4;
    solidTile(&bus, 0, 3);
    @memset(bus.vram[0x9800 - 0x8000 ..][0..0x400], 0);

    var ppu: Ppu = .{};
    bus.video = ppu.video();
    var n: u32 = 0;
    while (n < lcd_mod.frame_cycles) : (n += 4) _ = bus.tick(4);
    try testing.expect(ppu.complete());
    try testing.expectEqual(@as(u16, height), ppu.drawn);
    try testing.expectEqual(@as(Shade, 3), ppu.frame[pixels - 1]);
}
