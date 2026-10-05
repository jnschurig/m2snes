//! APU *register capture*, not synthesis.
//!
//! Step 17 converts Metroid II's music to the Terrific Audio Driver. What that
//! needs from here is not audio: it is the exact sequence of writes the sound
//! driver makes to the APU, with enough timing to reconstruct note starts and
//! lengths. So this records every write to `$FF10`-`$FF26` and `$FF30`-`$FF3F`
//! with a frame number and a cycle offset within the frame, and models just
//! enough register behaviour that the driver reads back what it expects.
//!
//! Deliberately absent: envelopes, sweeps, the frame sequencer, and any sample
//! generation. A synthesised waveform would be a second thing to be wrong about
//! and nothing in the plan consumes one - the SNES side gets notes, not PCM.

const std = @import("std");

pub const first_addr: u16 = 0xFF10;
pub const last_addr: u16 = 0xFF26;
pub const wave_first: u16 = 0xFF30;
pub const wave_last: u16 = 0xFF3F;
pub const nr52_addr: u16 = 0xFF26;

pub fn owns(addr: u16) bool {
    return (addr >= first_addr and addr <= last_addr) or
        (addr >= wave_first and addr <= wave_last);
}

/// One captured write. 12 bytes, and the log is append-only in execution
/// order, so a capture is fully described by the sequence itself - no sorting,
/// no map iteration, nothing that could reorder between runs.
pub const Write = struct {
    frame: u32,
    /// T-cycles since the start of the frame.
    cycle: u32,
    addr: u16,
    value: u8,
};

/// Bits that read back as set in each register, because the write-only fields
/// underneath them do not exist on read. Taken as a block so a driver reading
/// its own register file back gets the hardware answer rather than its own
/// value - a difference real drivers do depend on.
const read_mask = blk: {
    var m: [last_addr - first_addr + 1]u8 = @splat(0xFF);
    const set = [_]struct { a: u16, v: u8 }{
        .{ .a = 0xFF10, .v = 0x80 }, .{ .a = 0xFF11, .v = 0x3F },
        .{ .a = 0xFF12, .v = 0x00 }, .{ .a = 0xFF13, .v = 0xFF },
        .{ .a = 0xFF14, .v = 0xBF }, .{ .a = 0xFF15, .v = 0xFF },
        .{ .a = 0xFF16, .v = 0x3F }, .{ .a = 0xFF17, .v = 0x00 },
        .{ .a = 0xFF18, .v = 0xFF }, .{ .a = 0xFF19, .v = 0xBF },
        .{ .a = 0xFF1A, .v = 0x7F }, .{ .a = 0xFF1B, .v = 0xFF },
        .{ .a = 0xFF1C, .v = 0x9F }, .{ .a = 0xFF1D, .v = 0xFF },
        .{ .a = 0xFF1E, .v = 0xBF }, .{ .a = 0xFF1F, .v = 0xFF },
        .{ .a = 0xFF20, .v = 0xFF }, .{ .a = 0xFF21, .v = 0x00 },
        .{ .a = 0xFF22, .v = 0x00 }, .{ .a = 0xFF23, .v = 0xBF },
        .{ .a = 0xFF24, .v = 0x00 }, .{ .a = 0xFF25, .v = 0x00 },
        .{ .a = 0xFF26, .v = 0x70 },
    };
    for (set) |s| m[s.a - first_addr] = s.v;
    break :blk m;
};

pub const Apu = struct {
    regs: [last_addr - first_addr + 1]u8 = @splat(0),
    wave: [wave_last - wave_first + 1]u8 = @splat(0),

    /// Every write, in order. Null means capture is off, which is the state
    /// the shipped builder runs in - the log is a dev-time instrument.
    log: ?*std.ArrayList(Write) = null,
    allocator: ?std.mem.Allocator = null,

    frame: u32 = 0,
    cycle: u32 = 0,

    pub fn powered(self: Apu) bool {
        return self.regs[nr52_addr - first_addr] & 0x80 != 0;
    }

    pub fn tick(self: *Apu, cycles: u32) void {
        self.cycle += cycles;
    }

    /// Called by the machine when the LCD completes a frame, so timestamps are
    /// relative to something the game itself is synchronised to.
    pub fn endFrame(self: *Apu) void {
        self.frame += 1;
        self.cycle = 0;
    }

    pub fn read(self: Apu, addr: u16) u8 {
        if (addr >= wave_first and addr <= wave_last) return self.wave[addr - wave_first];
        if (addr < first_addr or addr > last_addr) return 0xFF;
        return self.regs[addr - first_addr] | read_mask[addr - first_addr];
    }

    pub fn write(self: *Apu, addr: u16, v: u8) !void {
        if (self.log) |log| {
            try log.append(self.allocator.?, .{
                .frame = self.frame,
                .cycle = self.cycle,
                .addr = addr,
                .value = v,
            });
        }

        if (addr >= wave_first and addr <= wave_last) {
            self.wave[addr - wave_first] = v;
            return;
        }
        if (addr < first_addr or addr > last_addr) return;

        // With the APU powered down every register except NR52 ignores writes,
        // and powering down zeroes them. Drivers use this as a reset, so
        // getting it wrong would corrupt the very sequence we are capturing.
        if (addr == nr52_addr) {
            const on = v & 0x80 != 0;
            const was = self.powered();
            self.regs[nr52_addr - first_addr] = v & 0x80;
            if (was and !on) {
                for (0..self.regs.len - 1) |i| self.regs[i] = 0;
            }
            return;
        }
        if (!self.powered()) return;
        self.regs[addr - first_addr] = v;
    }
};

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "the captured range is exactly the APU's, and nothing next to it" {
    try testing.expect(!owns(0xFF0F)); // IF
    try testing.expect(owns(0xFF10));
    try testing.expect(owns(0xFF26));
    try testing.expect(!owns(0xFF27)); // unmapped gap
    try testing.expect(!owns(0xFF2F));
    try testing.expect(owns(0xFF30)); // wave RAM
    try testing.expect(owns(0xFF3F));
    try testing.expect(!owns(0xFF40)); // LCDC
}

test "writes are captured in order with frame-relative timestamps" {
    const gpa = testing.allocator;
    var log: std.ArrayList(Write) = .empty;
    defer log.deinit(gpa);
    var apu: Apu = .{ .log = &log, .allocator = gpa };

    try apu.write(nr52_addr, 0x80); // power on
    apu.tick(100);
    try apu.write(0xFF11, 0x80);
    apu.endFrame();
    apu.tick(40);
    try apu.write(0xFF13, 0x42);

    try testing.expectEqual(@as(usize, 3), log.items.len);
    try testing.expectEqual(@as(u32, 0), log.items[0].frame);
    try testing.expectEqual(@as(u32, 0), log.items[0].cycle);
    try testing.expectEqual(@as(u32, 100), log.items[1].cycle);
    try testing.expectEqual(@as(u32, 1), log.items[2].frame);
    try testing.expectEqual(@as(u32, 40), log.items[2].cycle);
    try testing.expectEqual(@as(u16, 0xFF13), log.items[2].addr);
    try testing.expectEqual(@as(u8, 0x42), log.items[2].value);
}

test "a powered-down APU ignores writes but still records them" {
    const gpa = testing.allocator;
    var log: std.ArrayList(Write) = .empty;
    defer log.deinit(gpa);
    var apu: Apu = .{ .log = &log, .allocator = gpa };

    try apu.write(0xFF11, 0x3F); // power is off
    try testing.expectEqual(@as(u8, 0), apu.regs[0xFF11 - first_addr]);
    // The write still reached the log: what the driver *did* is the artifact,
    // and a driver writing to a powered-down APU is exactly the kind of thing
    // Step 17 needs to see rather than have filtered out.
    try testing.expectEqual(@as(usize, 1), log.items.len);
}

test "powering down zeroes every register but NR52 itself" {
    var apu: Apu = .{};
    try apu.write(nr52_addr, 0x80);
    try apu.write(0xFF11, 0x3F);
    try apu.write(0xFF12, 0xF0);
    try testing.expectEqual(@as(u8, 0xF0), apu.regs[0xFF12 - first_addr]);

    try apu.write(nr52_addr, 0x00);
    try testing.expectEqual(@as(u8, 0), apu.regs[0xFF12 - first_addr]);
    try testing.expect(!apu.powered());
}

test "write-only bits read back as set" {
    var apu: Apu = .{};
    try apu.write(nr52_addr, 0x80);
    try apu.write(0xFF13, 0x42); // NR13 is entirely write-only
    try testing.expectEqual(@as(u8, 0xFF), apu.read(0xFF13));
    // NR11's low six bits are write-only; the duty in bits 6-7 reads back.
    try apu.write(0xFF11, 0xC5);
    try testing.expectEqual(@as(u8, 0xFF), apu.read(0xFF11));
    try apu.write(0xFF11, 0x05);
    try testing.expectEqual(@as(u8, 0x3F), apu.read(0xFF11));
}

test "wave RAM reads and writes straight through" {
    var apu: Apu = .{};
    try apu.write(0xFF30, 0xAB);
    try apu.write(0xFF3F, 0xCD);
    try testing.expectEqual(@as(u8, 0xAB), apu.read(0xFF30));
    try testing.expectEqual(@as(u8, 0xCD), apu.read(0xFF3F));
    // Wave RAM is not gated on power, unlike the channel registers.
    try testing.expect(!apu.powered());
}

test "capture off costs nothing and needs no allocator" {
    var apu: Apu = .{};
    try apu.write(nr52_addr, 0x80);
    try apu.write(0xFF11, 0x3F);
    try testing.expectEqual(@as(u8, 0x3F), apu.regs[0xFF11 - first_addr]);
}
