//! The whole machine: CPU plus bus, steppable by instruction or by frame.
//!
//! Determinism is the property this module exists to guarantee, because Step 9
//! compares rendered frames and Step 14 compares state traces, and both are
//! worthless if two runs of the same input can differ. So: no wall clock, no
//! randomness, no uninitialised memory, no iteration over a hash map. Every
//! byte of state is either zeroed or set to a documented post-boot value at
//! construction, and `traceDigest` folds the machine into a hash in a fixed
//! order.

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const bus_mod = @import("bus.zig");
const cart_mod = @import("cart.zig");
const lcd_mod = @import("lcd.zig");
const apu_mod = @import("apu.zig");

pub const Error = cpu_mod.Error || cart_mod.Error;

pub const System = struct {
    cpu: cpu_mod.Cpu,
    bus: bus_mod.Bus,
    frames: u64 = 0,
    instructions: u64 = 0,

    pub fn init(rom: []const u8, ram: []u8) Error!System {
        const cart = try cart_mod.Cart.init(rom, ram);
        return .{ .cpu = cpu_mod.Cpu.dmgPostBoot(), .bus = bus_mod.Bus.init(cart) };
    }

    /// Start at power-on with `boot` mapped over the bottom page, instead of
    /// at $0100 with the post-boot register values.
    ///
    /// Only the comparison harness uses this, and only with SameBoy's own
    /// boot ROM built from source. It exists because sharing a cycle origin
    /// with the emulator you are grading against is worth far more than
    /// guessing the offset between two different origins.
    pub fn initWithBoot(rom: []const u8, ram: []u8, boot: []const u8) Error!System {
        const cart = try cart_mod.Cart.init(rom, ram);
        var sys: System = .{ .cpu = cpu_mod.Cpu.powerOn(), .bus = bus_mod.Bus.init(cart) };
        sys.bus.boot = boot;
        // Power-on, not post-boot: the boot ROM turns the LCD on itself, and
        // starting with it already enabled would render a frame the hardware
        // never shows.
        sys.bus.lcd.lcdc = 0x00;
        sys.bus.lcd.bgp = 0x00;
        sys.bus.iflags = 0xE0;
        return sys;
    }

    /// Execute one instruction and advance the peripherals by its cycles.
    /// Returns true when that instruction completed an LCD frame.
    pub fn step(self: *System) Error!bool {
        const cycles = try self.cpu.step(&self.bus);
        self.instructions += 1;
        const done = self.bus.tick(cycles);
        if (done) self.frames += 1;
        return done;
    }

    /// Run until the LCD completes a frame. `max_instructions` bounds a
    /// runaway - a program that turns the LCD off never finishes a frame, and
    /// hanging forever is a worse failure than returning false.
    pub fn stepFrame(self: *System, max_instructions: u64) Error!bool {
        var n: u64 = 0;
        while (n < max_instructions) : (n += 1) {
            if (try self.step()) return true;
        }
        return false;
    }

    pub fn stepFrames(self: *System, count: u64, max_instructions_per_frame: u64) Error!u64 {
        var done: u64 = 0;
        while (done < count) : (done += 1) {
            if (!try self.stepFrame(max_instructions_per_frame)) return done;
        }
        return done;
    }

    /// A hash over the machine's observable state, in a fixed order.
    ///
    /// Hashing rather than dumping keeps a trace of thousands of frames small
    /// enough to compare cheaply, and the fixed order is what makes two runs
    /// comparable at all. Cartridge ROM is excluded - it does not change - but
    /// the mapper's registers are not, because the live bank is state.
    pub fn traceDigest(self: *const System) [32]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        const c = &self.cpu;
        h.update(&[_]u8{ c.a, @bitCast(c.f), c.b, c.c, c.d, c.e, c.h, c.l });
        h.update(&std.mem.toBytes(c.sp));
        h.update(&std.mem.toBytes(c.pc));
        h.update(&[_]u8{
            @intFromBool(c.ime), @intFromBool(c.halted),
            @intFromBool(c.halt_bug), @intFromBool(c.stopped),
            c.ime_delay,
        });
        h.update(&std.mem.toBytes(c.cycles));

        const b = &self.bus;
        h.update(&b.vram);
        h.update(&b.wram);
        h.update(&b.oam);
        h.update(&b.hram);
        h.update(b.cart.ram);
        h.update(&[_]u8{ b.ie, b.iflags, b.joyp_select, b.sb, b.sc });
        h.update(&[_]u8{
            b.cart.rom_bank_lo, b.cart.bank_hi,
            @intFromBool(b.cart.mode1), @intFromBool(b.cart.ram_enabled),
        });
        h.update(&std.mem.toBytes(b.timer.counter));
        h.update(&[_]u8{ b.timer.tima, b.timer.tma, b.timer.tac });
        h.update(&[_]u8{
            b.lcd.lcdc, b.lcd.stat_select, b.lcd.scy, b.lcd.scx,
            b.lcd.ly,   b.lcd.lyc,         b.lcd.bgp, b.lcd.obp0,
            b.lcd.obp1, b.lcd.wy,          b.lcd.wx,  @intFromEnum(b.lcd.mode),
        });
        h.update(&std.mem.toBytes(b.lcd.dot));
        h.update(&b.apu.regs);
        h.update(&b.apu.wave);

        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }
};

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

/// A 32 KiB ROM-only cart whose program is `code` at $0100.
fn fixture(rom: *[0x8000]u8, code: []const u8) void {
    @memset(rom, 0);
    rom[0x0147] = 0x00;
    @memcpy(rom[0x100..][0..code.len], code);
}

test "one frame is 70224 cycles of NOPs" {
    var rom: [0x8000]u8 = undefined;
    // JR -2: a two-byte self-loop, 12 cycles each time around.
    fixture(&rom, &[_]u8{ 0x18, 0xFE });
    var sys = try System.init(&rom, &.{});

    try testing.expect(try sys.stepFrame(100_000));
    try testing.expectEqual(@as(u64, 1), sys.frames);
    // The frame ends on the instruction that crosses the boundary, so the
    // cycle count lands within one instruction of the exact frame length.
    try testing.expect(sys.cpu.cycles >= lcd_mod.frame_cycles);
    try testing.expect(sys.cpu.cycles < lcd_mod.frame_cycles + 24);
}

test "the same ROM produces the same state trace twice" {
    var rom_a: [0x8000]u8 = undefined;
    var rom_b: [0x8000]u8 = undefined;
    // Touch a spread of state: registers, WRAM, the timer, and a stack push.
    const code = [_]u8{
        0x3E, 0x42, // LD A,$42
        0x21, 0x00, 0xC0, // LD HL,$C000
        0x77, // LD (HL),A
        0x23, // INC HL
        0x3C, // INC A
        0xF5, // PUSH AF
        0xF1, // POP AF
        0x18, 0xF6, // JR -10
    };
    fixture(&rom_a, &code);
    fixture(&rom_b, &code);

    var a = try System.init(&rom_a, &.{});
    var b = try System.init(&rom_b, &.{});
    _ = try a.stepFrames(3, 200_000);
    _ = try b.stepFrames(3, 200_000);
    try testing.expectEqualSlices(u8, &a.traceDigest(), &b.traceDigest());
    try testing.expectEqual(a.instructions, b.instructions);
}

test "the trace notices a difference in any of the state it covers" {
    var rom: [0x8000]u8 = undefined;
    fixture(&rom, &[_]u8{ 0x18, 0xFE });
    var a = try System.init(&rom, &.{});
    _ = try a.stepFrame(100_000);
    const base = a.traceDigest();

    // Each of these is a different corner of the hashed state; all must move
    // the digest, or the trace would be blind to that corner.
    var b = a;
    b.bus.wram[0x123] ^= 1;
    try testing.expect(!std.mem.eql(u8, &base, &b.traceDigest()));
    b = a;
    b.bus.vram[0] ^= 1;
    try testing.expect(!std.mem.eql(u8, &base, &b.traceDigest()));
    b = a;
    b.bus.oam[0] ^= 1;
    try testing.expect(!std.mem.eql(u8, &base, &b.traceDigest()));
    b = a;
    b.bus.hram[0] ^= 1;
    try testing.expect(!std.mem.eql(u8, &base, &b.traceDigest()));
    b = a;
    b.cpu.f.c = !b.cpu.f.c;
    try testing.expect(!std.mem.eql(u8, &base, &b.traceDigest()));
    b = a;
    b.bus.cart.rom_bank_lo +%= 1;
    try testing.expect(!std.mem.eql(u8, &base, &b.traceDigest()));
    b = a;
    b.bus.apu.regs[0] ^= 1;
    try testing.expect(!std.mem.eql(u8, &base, &b.traceDigest()));
}

test "stepFrame gives up rather than hanging when no frame can complete" {
    var rom: [0x8000]u8 = undefined;
    // Turn the LCD off, then loop forever: no frame will ever finish.
    fixture(&rom, &[_]u8{
        0x3E, 0x00, // LD A,0
        0xE0, 0x40, // LDH ($40),A - LCDC, bit 7 clear
        0x18, 0xFE, // JR -2
    });
    var sys = try System.init(&rom, &.{});
    try testing.expect(!try sys.stepFrame(10_000));
    try testing.expectEqual(@as(u64, 0), sys.frames);
}

test "an illegal opcode stops the machine instead of running as something else" {
    var rom: [0x8000]u8 = undefined;
    fixture(&rom, &[_]u8{0xD3});
    var sys = try System.init(&rom, &.{});
    try testing.expectError(cpu_mod.Error.IllegalOpcode, sys.stepFrame(10));
}

test "APU writes reach the capture log with frame timestamps" {
    const gpa = testing.allocator;
    var log: std.ArrayList(apu_mod.Write) = .empty;
    defer log.deinit(gpa);

    var rom: [0x8000]u8 = undefined;
    fixture(&rom, &[_]u8{
        0x3E, 0x80, // LD A,$80
        0xE0, 0x26, // LDH ($26),A - NR52 power on
        0x3E, 0x83, // LD A,$83
        0xE0, 0x11, // LDH ($11),A - NR11
        0x18, 0xFE, // JR -2
    });
    var sys = try System.init(&rom, &.{});
    sys.bus.apu.log = &log;
    sys.bus.apu.allocator = gpa;

    _ = try sys.stepFrames(2, 200_000);
    try testing.expectEqual(@as(usize, 2), log.items.len);
    try testing.expectEqual(@as(u16, apu_mod.nr52_addr), log.items[0].addr);
    try testing.expectEqual(@as(u16, 0xFF11), log.items[1].addr);
    try testing.expectEqual(@as(u8, 0x83), log.items[1].value);
    // Both land in frame 0, before the first frame boundary.
    try testing.expectEqual(@as(u32, 0), log.items[1].frame);
    try testing.expect(log.items[1].cycle > log.items[0].cycle);
}
