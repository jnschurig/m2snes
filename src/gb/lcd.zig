//! LCD *timing*: LY, the mode state machine, and the two interrupts it raises.
//!
//! No pixels. This is the half of the display the CPU can observe - which is
//! what makes the game run at all, because it waits on LY and on VBlank - and
//! it is deliberately separated from the rasteriser, which arrives in Step 7
//! and stays in the dev test suite rather than shipping inside the builder.
//! `bus.Video` is the seam between them: when nothing registers, VRAM and OAM
//! are plain memory and this timing model is all there is.
//!
//! One frame is 154 lines of 456 t-cycles = 70,224, which at 4.194304 MHz is
//! 59.73 Hz. Lines 0-143 cycle through modes 2, 3 and 0; lines 144-153 are
//! mode 1, VBlank.

const std = @import("std");

pub const lcdc_addr: u16 = 0xFF40;
pub const stat_addr: u16 = 0xFF41;
pub const scy_addr: u16 = 0xFF42;
pub const scx_addr: u16 = 0xFF43;
pub const ly_addr: u16 = 0xFF44;
pub const lyc_addr: u16 = 0xFF45;
pub const bgp_addr: u16 = 0xFF47;
pub const obp0_addr: u16 = 0xFF48;
pub const obp1_addr: u16 = 0xFF49;
pub const wy_addr: u16 = 0xFF4A;
pub const wx_addr: u16 = 0xFF4B;

pub const line_cycles: u32 = 456;
pub const visible_lines: u8 = 144;
pub const total_lines: u8 = 154;
pub const frame_cycles: u32 = line_cycles * total_lines;

pub const oam_cycles: u32 = 80;
pub const transfer_cycles: u32 = 172;

pub const Mode = enum(u2) { hblank = 0, vblank = 1, oam = 2, transfer = 3 };

pub const Lcd = struct {
    lcdc: u8 = 0x91,
    /// STAT's low three bits are computed, not stored: mode in 0-1, the LYC
    /// coincidence flag in 2. Only the interrupt-select bits 3-6 are writable.
    stat_select: u8 = 0,
    scy: u8 = 0,
    scx: u8 = 0,
    ly: u8 = 0,
    lyc: u8 = 0,
    bgp: u8 = 0xFC,
    obp0: u8 = 0xFF,
    obp1: u8 = 0xFF,
    wy: u8 = 0,
    wx: u8 = 0,

    dot: u32 = 0,
    mode: Mode = .oam,

    /// Raised for the caller to turn into IF bits.
    vblank_irq: bool = false,
    stat_irq: bool = false,
    /// Set on the cycle LY wraps back to 0, so a caller can step whole frames.
    frame_done: bool = false,

    /// The STAT interrupt line is level-triggered: it fires on a rising edge
    /// only, so two sources both asserting does not produce two interrupts.
    stat_line: bool = false,

    /// Set to the line number on the cycle mode 3 begins, which is when the
    /// real PPU latches SCY/SCX and starts fetching. A renderer that instead
    /// drew at *end* of line would apply a scroll written during that line's
    /// HBlank to the line already drawn -- exactly backwards, and exactly what
    /// a mid-frame status-bar split does. The consumer clears it.
    render_line: ?u8 = null,

    pub fn enabled(self: Lcd) bool {
        return self.lcdc & 0x80 != 0;
    }

    pub fn read(self: Lcd, addr: u16) u8 {
        return switch (addr) {
            lcdc_addr => self.lcdc,
            // Bit 7 reads as set; bit 2 is the live LY==LYC comparison.
            stat_addr => 0x80 | self.stat_select |
                (@as(u8, @intFromBool(self.ly == self.lyc)) << 2) |
                @intFromEnum(self.mode),
            scy_addr => self.scy,
            scx_addr => self.scx,
            ly_addr => self.ly,
            lyc_addr => self.lyc,
            bgp_addr => self.bgp,
            obp0_addr => self.obp0,
            obp1_addr => self.obp1,
            wy_addr => self.wy,
            wx_addr => self.wx,
            else => 0xFF,
        };
    }

    pub fn write(self: *Lcd, addr: u16, v: u8) void {
        switch (addr) {
            lcdc_addr => {
                const was = self.enabled();
                self.lcdc = v;
                if (was and !self.enabled()) {
                    // Turning the LCD off resets the line counter. Games rely
                    // on this to get a known state before touching VRAM.
                    self.ly = 0;
                    self.dot = 0;
                    self.mode = .hblank;
                    self.stat_line = false;
                } else if (!was and self.enabled()) {
                    self.ly = 0;
                    self.dot = 0;
                    self.mode = .oam;
                }
            },
            stat_addr => self.stat_select = v & 0x78,
            scy_addr => self.scy = v,
            scx_addr => self.scx = v,
            ly_addr => {}, // read-only
            lyc_addr => self.lyc = v,
            bgp_addr => self.bgp = v,
            obp0_addr => self.obp0 = v,
            obp1_addr => self.obp1 = v,
            wy_addr => self.wy = v,
            wx_addr => self.wx = v,
            else => {},
        }
    }

    /// Advance by `cycles` t-cycles.
    pub fn tick(self: *Lcd, cycles: u32) void {
        self.frame_done = false;
        if (!self.enabled()) return;

        var left = cycles;
        while (left > 0) {
            const step = @min(left, line_cycles - self.dot);
            self.dot += step;
            left -= step;

            if (self.dot >= line_cycles) {
                self.dot = 0;
                self.ly += 1;
                if (self.ly == visible_lines) {
                    self.vblank_irq = true;
                } else if (self.ly >= total_lines) {
                    self.ly = 0;
                    self.frame_done = true;
                }
            }
            self.updateMode();
        }
    }

    fn updateMode(self: *Lcd) void {
        const was = self.mode;
        self.mode = if (self.ly >= visible_lines)
            .vblank
        else if (self.dot < oam_cycles)
            .oam
        else if (self.dot < oam_cycles + transfer_cycles)
            .transfer
        else
            .hblank;

        if (self.mode == .transfer and was != .transfer) self.render_line = self.ly;

        // STAT's four sources are ORed into one line; the interrupt fires when
        // that line goes from low to high, which is why holding two sources
        // asserted does not produce a second interrupt.
        const line = (self.stat_select & 0x40 != 0 and self.ly == self.lyc) or
            (self.stat_select & 0x20 != 0 and self.mode == .oam) or
            (self.stat_select & 0x10 != 0 and self.mode == .vblank) or
            (self.stat_select & 0x08 != 0 and self.mode == .hblank);
        if (line and !self.stat_line) self.stat_irq = true;
        self.stat_line = line;
    }
};

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "a frame is 154 lines of 456 cycles" {
    try testing.expectEqual(@as(u32, 70224), frame_cycles);
    var lcd: Lcd = .{};
    var n: u32 = 0;
    while (!lcd.frame_done) : (n += 4) lcd.tick(4);
    try testing.expectEqual(frame_cycles, n);
    try testing.expectEqual(@as(u8, 0), lcd.ly);
}

test "the mode sequence within a visible line is 2, 3, 0" {
    var lcd: Lcd = .{};
    try testing.expectEqual(Mode.oam, lcd.mode);
    lcd.tick(oam_cycles);
    try testing.expectEqual(Mode.transfer, lcd.mode);
    lcd.tick(transfer_cycles);
    try testing.expectEqual(Mode.hblank, lcd.mode);
    lcd.tick(line_cycles - oam_cycles - transfer_cycles);
    try testing.expectEqual(@as(u8, 1), lcd.ly);
    try testing.expectEqual(Mode.oam, lcd.mode);
}

test "VBlank is raised once, on entry to line 144" {
    var lcd: Lcd = .{};
    lcd.tick(line_cycles * 143);
    try testing.expect(!lcd.vblank_irq);
    lcd.tick(line_cycles);
    try testing.expectEqual(@as(u8, 144), lcd.ly);
    try testing.expect(lcd.vblank_irq);
    lcd.vblank_irq = false;
    lcd.tick(line_cycles * 9);
    try testing.expect(!lcd.vblank_irq); // not again during the other VBlank lines
    try testing.expectEqual(Mode.vblank, lcd.mode);
}

test "STAT reports the live LY==LYC comparison and keeps bit 7 set" {
    var lcd: Lcd = .{};
    lcd.write(lyc_addr, 0);
    try testing.expect(lcd.read(stat_addr) & 0x04 != 0);
    try testing.expect(lcd.read(stat_addr) & 0x80 != 0);
    lcd.write(lyc_addr, 5);
    try testing.expect(lcd.read(stat_addr) & 0x04 == 0);
    lcd.tick(line_cycles * 5);
    try testing.expectEqual(@as(u8, 5), lcd.ly);
    try testing.expect(lcd.read(stat_addr) & 0x04 != 0);
}

test "the STAT interrupt fires on a rising edge, not while the line is held" {
    var lcd: Lcd = .{};
    lcd.write(stat_addr, 0x40); // LYC source only
    lcd.write(lyc_addr, 2);
    lcd.stat_irq = false;

    lcd.tick(line_cycles * 2);
    try testing.expectEqual(@as(u8, 2), lcd.ly);
    try testing.expect(lcd.stat_irq);
    lcd.stat_irq = false;

    // Still on line 2, still matching: no second interrupt.
    lcd.tick(100);
    try testing.expect(!lcd.stat_irq);
}

test "STAT's mode and coincidence bits are not writable" {
    var lcd: Lcd = .{};
    lcd.write(stat_addr, 0xFF);
    try testing.expectEqual(@as(u8, 0x78), lcd.stat_select);
    // Mode 2 at reset, so the low bits come from the state machine.
    try testing.expectEqual(@as(u8, 2), lcd.read(stat_addr) & 0x03);
}

test "turning the LCD off parks LY at 0 and stops the clock" {
    var lcd: Lcd = .{};
    lcd.tick(line_cycles * 3);
    try testing.expectEqual(@as(u8, 3), lcd.ly);
    lcd.write(lcdc_addr, 0x11); // bit 7 clear
    try testing.expectEqual(@as(u8, 0), lcd.ly);
    lcd.tick(line_cycles * 10);
    try testing.expectEqual(@as(u8, 0), lcd.ly);
    lcd.write(lcdc_addr, 0x91);
    lcd.tick(line_cycles);
    try testing.expectEqual(@as(u8, 1), lcd.ly);
}

test "LY is read-only" {
    var lcd: Lcd = .{};
    lcd.write(ly_addr, 100);
    try testing.expectEqual(@as(u8, 0), lcd.ly);
}
