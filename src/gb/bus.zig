//! The memory map, and the IO dispatch behind it.
//!
//! `$0000-$7FFF` cart ROM       `$FE00-$FE9F` OAM
//! `$8000-$9FFF` VRAM           `$FEA0-$FEFF` unusable
//! `$A000-$BFFF` cart RAM       `$FF00-$FF7F` IO
//! `$C000-$DFFF` WRAM           `$FF80-$FFFE` HRAM
//! `$E000-$FDFF` echo of WRAM   `$FFFF`       IE
//!
//! The `video` field is the seam that keeps the rasteriser out of the shipped
//! builder. Nothing here draws: `lcd.zig` runs the timing the CPU can observe,
//! and VRAM and OAM are plain arrays. Step 7 registers a `Video` and gets
//! called once per visible line with the bus, reading the memory and registers
//! it needs. When nothing registers, none of that code is reachable and the
//! linker drops it.

const std = @import("std");
const cart_mod = @import("cart.zig");
const timer_mod = @import("timer.zig");
const lcd_mod = @import("lcd.zig");
const apu_mod = @import("apu.zig");
const cpu_mod = @import("cpu.zig");

pub const joyp_addr: u16 = 0xFF00;
pub const sb_addr: u16 = 0xFF01;
pub const sc_addr: u16 = 0xFF02;
pub const dma_addr: u16 = 0xFF46;
/// Writing anything here unmaps the boot ROM, permanently.
pub const boot_off_addr: u16 = 0xFF50;

/// Step 7's rasteriser plugs in here. Kept as a plain function pointer rather
/// than a Zig interface so `bus.zig` has no import of the PPU at all.
pub const Video = struct {
    ctx: *anyopaque,
    /// Called once per completed visible line, with the line number just
    /// finished. The callee reads VRAM, OAM and the LCD registers off the bus.
    line: *const fn (ctx: *anyopaque, bus: *const Bus, ly: u8) void,
};

/// An observer on every bus read.
///
/// The second seam in this module, and the same shape as `Video`: a plain
/// function pointer that nothing in the shipped builder registers, so with it
/// unset the cost is one null check on a path the branch predictor gets right
/// every time. It exists so a question like "which code reads the door script
/// data" can be answered by watching the game answer it, rather than by
/// reading someone else's labels off a disassembly.
pub const ReadWatch = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, bus: *const Bus, addr: u16, value: u8) void,
};

/// The mirror of `ReadWatch`, and unset for the same reason: one null check on
/// a hot path, and nothing in the shipped builder registers it.
///
/// Reads answer "which code consults this data". Writes answer "where does this
/// value live" -- watching the game copy its own save record out to cartridge
/// RAM names both the routine and the address of every field it carries,
/// without anybody having to recognise a layout by eye.
pub const WriteWatch = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bus: *const Bus, addr: u16, value: u8) void,
};

pub const Bus = struct {
    cart: cart_mod.Cart,
    vram: [0x2000]u8 = @splat(0),
    wram: [0x2000]u8 = @splat(0),
    oam: [0xA0]u8 = @splat(0),
    hram: [0x7F]u8 = @splat(0),

    timer: timer_mod.Timer = .{},
    lcd: lcd_mod.Lcd = .{},
    apu: apu_mod.Apu = .{},

    /// When set, what a read of DIV returns instead of the counter. A test
    /// hook, not hardware: the sound engine seeds five cries' pitch from DIV,
    /// and the audio comparison pins it so that both engines read one value
    /// (`audiocmp.runGb`). The counter itself keeps running underneath.
    div_pin: ?u8 = null,

    ie: u8 = 0,
    /// Only the low five bits exist; the rest read as set.
    iflags: u8 = 0,

    /// Joypad lines, 1 = released. Metroid II is driven by the TAS oracle in
    /// Step 14, which writes these directly.
    dpad: u4 = 0xF,
    buttons: u4 = 0xF,
    joyp_select: u8 = 0x30,

    sb: u8 = 0,
    sc: u8 = 0,
    /// Bytes the program pushed out the link port. blargg's suites report
    /// their results here, which is why it is captured rather than dropped.
    serial_out: ?*std.ArrayList(u8) = null,
    serial_allocator: ?std.mem.Allocator = null,

    video: ?Video = null,
    read_watch: ?ReadWatch = null,
    write_watch: ?WriteWatch = null,

    /// An optional boot ROM overlaying $0000-$00FF until the program unmaps
    /// it. Nothing in the shipped builder uses this -- it exists so a test can
    /// start from power-on and share a cycle origin with another emulator.
    /// No Nintendo boot ROM is involved: the only one this repository ever
    /// points at is SameBoy's own reimplementation, built from source under
    /// vendor/ and never tracked.
    boot: ?[]const u8 = null,

    /// Set when a write to an unimplemented IO register is seen. Reported
    /// rather than silently ignored, so a game depending on something we do
    /// not model shows up as a number instead of as a mystery.
    unknown_io_writes: u32 = 0,
    /// The last such address, so the count is diagnosable instead of just
    /// alarming.
    last_unknown_io: u16 = 0,

    pub fn init(cart: cart_mod.Cart) Bus {
        var b: Bus = .{ .cart = cart };
        // Post-boot IO state, the values the DMG's boot ROM leaves behind.
        b.iflags = 0xE1;
        b.timer.tac = 0xF8 & 0x07;
        b.lcd.lcdc = 0x91;
        b.lcd.bgp = 0xFC;
        return b;
    }

    // ---- Reads ------------------------------------------------------------

    pub fn read(self: *Bus, addr: u16) u8 {
        const v = self.readInner(addr);
        if (self.read_watch) |w| w.read(w.ctx, self, addr, v);
        return v;
    }

    fn readInner(self: *Bus, addr: u16) u8 {
        // The boot ROM overlays the bottom page while it is mapped. The
        // cartridge header at $0100 upward is never covered, which is how the
        // boot ROM reads the logo it is about to check.
        if (self.boot) |b| {
            if (addr < b.len) return b[addr];
        }
        return switch (addr) {
            0x0000...0x7FFF, 0xA000...0xBFFF => self.cart.read(addr),
            0x8000...0x9FFF => self.vram[addr - 0x8000],
            0xC000...0xDFFF => self.wram[addr - 0xC000],
            0xE000...0xFDFF => self.wram[addr - 0xE000], // echo
            0xFE00...0xFE9F => self.oam[addr - 0xFE00],
            0xFEA0...0xFEFF => 0xFF, // unusable
            0xFF00...0xFF7F => self.readIo(addr),
            0xFF80...0xFFFE => self.hram[addr - 0xFF80],
            0xFFFF => self.ie,
        };
    }

    fn readIo(self: *Bus, addr: u16) u8 {
        if (apu_mod.owns(addr)) return self.apu.read(addr);
        return switch (addr) {
            // Both selects low means both sets are read at once, ANDed.
            joyp_addr => 0xC0 | (self.joyp_select & 0x30) | @as(u8, self.joypLines()),
            sb_addr => self.sb,
            sc_addr => self.sc | 0x7E,
            cpu_mod.if_addr => self.iflags | 0xE0,
            timer_mod.div_addr => self.div_pin orelse self.timer.read(addr),
            timer_mod.div_addr + 1...timer_mod.tac_addr => self.timer.read(addr),
            // $FF46 is DMA, not an LCD register, and it sits in the middle of
            // the block - hence the split range rather than one span.
            lcd_mod.lcdc_addr...lcd_mod.lyc_addr, lcd_mod.bgp_addr...lcd_mod.wx_addr => self.lcd.read(addr),
            dma_addr => 0xFF,
            else => 0xFF,
        };
    }

    // ---- Writes -----------------------------------------------------------

    pub fn write(self: *Bus, addr: u16, v: u8) void {
        if (self.write_watch) |w| w.write(w.ctx, self, addr, v);
        switch (addr) {
            0x0000...0x7FFF, 0xA000...0xBFFF => self.cart.write(addr, v),
            0x8000...0x9FFF => self.vram[addr - 0x8000] = v,
            0xC000...0xDFFF => self.wram[addr - 0xC000] = v,
            0xE000...0xFDFF => self.wram[addr - 0xE000] = v,
            0xFE00...0xFE9F => self.oam[addr - 0xFE00] = v,
            0xFEA0...0xFEFF => {},
            0xFF00...0xFF7F => self.writeIo(addr, v),
            0xFF80...0xFFFE => self.hram[addr - 0xFF80] = v,
            0xFFFF => self.ie = v,
        }
    }

    fn writeIo(self: *Bus, addr: u16, v: u8) void {
        if (apu_mod.owns(addr)) {
            // The only failure a capture can have is running out of memory,
            // and dropping a write silently would corrupt the artifact. Count
            // it instead so the capture reports itself incomplete.
            self.apu.write(addr, v) catch {
                self.unknown_io_writes += 1;
            };
            return;
        }
        switch (addr) {
            joyp_addr => self.joyp_select = v & 0x30,
            sb_addr => self.sb = v,
            sc_addr => {
                self.sc = v;
                if (v & 0x81 == 0x81) {
                    // Transfer with the internal clock: complete it at once.
                    // Nothing is connected, so the byte goes to the capture and
                    // the incoming byte is the idle $FF.
                    if (self.serial_out) |out| {
                        out.append(self.serial_allocator.?, self.sb) catch {
                            self.unknown_io_writes += 1;
                        };
                    }
                    self.sb = 0xFF;
                    self.sc &= ~@as(u8, 0x80);
                    self.raise(.serial);
                }
            },
            cpu_mod.if_addr => self.iflags = v & 0x1F,
            timer_mod.div_addr...timer_mod.tac_addr => self.timer.write(addr, v),
            lcd_mod.lcdc_addr...lcd_mod.lyc_addr, lcd_mod.bgp_addr...lcd_mod.wx_addr => self.lcd.write(addr, v),
            dma_addr => self.oamDma(v),
            // Genuinely unmapped on a DMG: these addresses do nothing on real
            // hardware either, so a write is not evidence of anything missing.
            // Metroid II writes $FF7F, which is why the distinction matters -
            // counting it would make the "unmodelled" number permanently
            // nonzero and therefore useless.
            0xFF03, 0xFF08...0xFF0E, 0xFF27...0xFF2F, 0xFF4C, 0xFF7F => {},
            // Unmapping the boot ROM is one-way on hardware, and one-way here.
            boot_off_addr => if (v != 0) {
                self.boot = null;
            },
            // $FF4D-$FF77 are CGB registers. These do something on hardware,
            // so a program touching them is depending on behaviour we do not
            // model.
            else => {
                self.unknown_io_writes += 1;
                self.last_unknown_io = addr;
            },
        }
    }

    /// OAM DMA. On hardware this takes 640 t-cycles during which the CPU can
    /// only touch HRAM; here it is instantaneous. Nothing in Phase 0a observes
    /// the difference - the game starts a DMA and then busy-waits in HRAM for
    /// longer than the transfer takes either way.
    fn oamDma(self: *Bus, page: u8) void {
        const base = @as(u16, page) << 8;
        for (0..self.oam.len) |i| {
            self.oam[i] = self.read(base + @as(u16, @intCast(i)));
        }
    }

    // ---- Interrupts and time ----------------------------------------------

    /// Set the joypad lines, raising the joypad interrupt on any selected line
    /// that goes high to low.
    ///
    /// Writing `dpad`/`buttons` directly skips that interrupt, which is fine
    /// for a test that only reads JOYP -- and wrong for anything driving a real
    /// game, because a title screen waiting on the joypad IRQ would never wake.
    pub fn setKeys(self: *Bus, dpad: u4, buttons: u4) void {
        const before = self.joypLines();
        self.dpad = dpad;
        self.buttons = buttons;
        const after = self.joypLines();
        if (before & ~after != 0) self.raise(.joypad);
    }

    fn joypLines(self: Bus) u4 {
        var lines: u4 = 0xF;
        if (self.joyp_select & 0x10 == 0) lines &= self.dpad;
        if (self.joyp_select & 0x20 == 0) lines &= self.buttons;
        return lines;
    }

    pub fn raise(self: *Bus, which: cpu_mod.Interrupt) void {
        self.iflags |= @as(u8, 1) << @intFromEnum(which);
    }

    /// Advance every peripheral by an instruction's worth of cycles, and fold
    /// what they raised into IF. Returns true when the LCD finished a frame.
    pub fn tick(self: *Bus, cycles: u32) bool {
        self.timer.advance(cycles);
        if (self.timer.overflow) {
            self.timer.overflow = false;
            self.raise(.timer);
        }

        self.lcd.tick(cycles);
        if (self.lcd.vblank_irq) {
            self.lcd.vblank_irq = false;
            self.raise(.vblank);
        }
        if (self.lcd.stat_irq) {
            self.lcd.stat_irq = false;
            self.raise(.lcd_stat);
        }

        if (self.lcd.render_line) |ly| {
            self.lcd.render_line = null;
            // Fired at the start of mode 3, so the callee sees the scroll and
            // palette registers as the PPU latched them for *this* line. The
            // longest instruction is 24 cycles against a 456-cycle line, so at
            // most one mode-3 start can fall inside a single tick.
            if (self.video) |v| v.line(v.ctx, self, ly);
        }

        self.apu.tick(cycles);
        if (self.lcd.frame_done) self.apu.endFrame();
        return self.lcd.frame_done;
    }
};

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

fn testCart(rom: []u8) cart_mod.Cart {
    @memset(rom, 0);
    rom[0x0147] = 0x00; // ROM only
    return cart_mod.Cart.init(rom, &.{}) catch unreachable;
}

test "echo RAM is the same storage as WRAM" {
    var rom: [0x8000]u8 = undefined;
    var bus = Bus.init(testCart(&rom));
    bus.write(0xC123, 0x42);
    try testing.expectEqual(@as(u8, 0x42), bus.read(0xE123));
    bus.write(0xE456, 0x99);
    try testing.expectEqual(@as(u8, 0x99), bus.read(0xC456));
}

test "the unusable region reads as $FF and swallows writes" {
    var rom: [0x8000]u8 = undefined;
    var bus = Bus.init(testCart(&rom));
    bus.write(0xFEA0, 0x11);
    try testing.expectEqual(@as(u8, 0xFF), bus.read(0xFEA0));
}

test "IF and IE keep only the bits that exist" {
    var rom: [0x8000]u8 = undefined;
    var bus = Bus.init(testCart(&rom));
    bus.write(cpu_mod.if_addr, 0xFF);
    try testing.expectEqual(@as(u8, 0xFF), bus.read(cpu_mod.if_addr)); // top bits read set
    try testing.expectEqual(@as(u8, 0x1F), bus.iflags);
    bus.write(cpu_mod.if_addr, 0x00);
    try testing.expectEqual(@as(u8, 0xE0), bus.read(cpu_mod.if_addr));
}

test "the joypad returns the selected half, and both ANDed when both are selected" {
    var rom: [0x8000]u8 = undefined;
    var bus = Bus.init(testCart(&rom));
    bus.dpad = 0b1110; // right held
    bus.buttons = 0b1101; // B held

    bus.write(joyp_addr, 0x20); // select d-pad (bit 4 low)
    try testing.expectEqual(@as(u8, 0xE0 | 0b1110), bus.read(joyp_addr));
    bus.write(joyp_addr, 0x10); // select buttons
    try testing.expectEqual(@as(u8, 0xD0 | 0b1101), bus.read(joyp_addr));
    bus.write(joyp_addr, 0x00); // both
    try testing.expectEqual(@as(u8, 0xC0 | 0b1100), bus.read(joyp_addr));
    bus.write(joyp_addr, 0x30); // neither
    try testing.expectEqual(@as(u8, 0xFF), bus.read(joyp_addr));
}

test "a serial transfer captures the byte and completes immediately" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var rom: [0x8000]u8 = undefined;
    var bus = Bus.init(testCart(&rom));
    bus.serial_out = &out;
    bus.serial_allocator = gpa;

    bus.write(sb_addr, 'O');
    bus.write(sc_addr, 0x81);
    bus.write(sb_addr, 'K');
    bus.write(sc_addr, 0x81);
    try testing.expectEqualStrings("OK", out.items);
    try testing.expectEqual(@as(u8, 0), bus.sc & 0x80); // transfer reported done
    try testing.expect(bus.iflags & 0x08 != 0); // serial interrupt raised
}

test "OAM DMA copies 160 bytes from the requested page" {
    var rom: [0x8000]u8 = undefined;
    var bus = Bus.init(testCart(&rom));
    for (0..0xA0) |i| bus.wram[0x100 + i] = @intCast(i);
    bus.write(dma_addr, 0xC1); // source $C100
    for (0..0xA0) |i| try testing.expectEqual(@as(u8, @intCast(i)), bus.oam[i]);
}

test "a pinned DIV reads as the pin, and unpinning gives the counter back" {
    var rom: [0x8000]u8 = undefined;
    var bus = Bus.init(testCart(&rom));
    bus.write(timer_mod.div_addr, 0);
    _ = bus.tick(256 * 3);
    try testing.expectEqual(@as(u8, 3), bus.read(timer_mod.div_addr));
    bus.div_pin = 0xA5;
    try testing.expectEqual(@as(u8, 0xA5), bus.read(timer_mod.div_addr));
    // TIMA, beside it, is not pinned.
    try testing.expectEqual(bus.timer.read(timer_mod.tima_addr), bus.read(timer_mod.tima_addr));
    bus.div_pin = null;
    try testing.expectEqual(@as(u8, 3), bus.read(timer_mod.div_addr));
}

test "the timer's overflow becomes an IF bit" {
    var rom: [0x8000]u8 = undefined;
    var bus = Bus.init(testCart(&rom));
    bus.iflags = 0;
    bus.write(timer_mod.tac_addr, 0x05); // every 16 cycles
    bus.write(timer_mod.tima_addr, 0xFF);
    _ = bus.tick(16);
    try testing.expect(bus.iflags & 0x04 != 0);
}

test "a frame's worth of ticks raises VBlank exactly once and reports the frame" {
    var rom: [0x8000]u8 = undefined;
    var bus = Bus.init(testCart(&rom));
    bus.iflags = 0;
    var frames: usize = 0;
    var vblanks: usize = 0;
    var c: u32 = 0;
    while (c < lcd_mod.frame_cycles) : (c += 4) {
        bus.iflags = 0;
        if (bus.tick(4)) frames += 1;
        if (bus.iflags & 0x01 != 0) vblanks += 1;
    }
    try testing.expectEqual(@as(usize, 1), frames);
    try testing.expectEqual(@as(usize, 1), vblanks);
}

test "writes to registers we do not model are counted, not ignored" {
    var rom: [0x8000]u8 = undefined;
    var bus = Bus.init(testCart(&rom));
    bus.write(0xFF4D, 0x01); // CGB speed switch
    bus.write(0xFF70, 0x02); // CGB WRAM bank
    try testing.expectEqual(@as(u32, 2), bus.unknown_io_writes);
}
