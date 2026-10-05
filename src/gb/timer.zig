//! DIV, TIMA, TMA and TAC.
//!
//! The hardware has one 16-bit counter that runs at the CPU clock. DIV is its
//! top 8 bits; TIMA increments on the *falling edge* of a selected bit of that
//! counter ANDed with the enable bit. Modelling it that way rather than as
//! "add a scaled count every so often" is what makes the two documented
//! side effects fall out for free: writing DIV resets the whole counter, and
//! doing so can clock TIMA once as the selected bit falls.
//!
//! `instr_timing` measures instructions through this timer, so it is also the
//! thing that turns a wrong cycle count into a visible failure.

const std = @import("std");

pub const div_addr: u16 = 0xFF04;
pub const tima_addr: u16 = 0xFF05;
pub const tma_addr: u16 = 0xFF06;
pub const tac_addr: u16 = 0xFF07;

pub const Timer = struct {
    /// The full internal counter. DIV is bits 8-15.
    counter: u16 = 0,
    tima: u8 = 0,
    tma: u8 = 0,
    tac: u8 = 0,
    /// Set when TIMA overflowed; the caller raises the interrupt.
    overflow: bool = false,

    prev_edge: bool = false,

    /// Which counter bit TAC's low two bits select.
    fn selectedBit(tac: u8) u4 {
        return switch (@as(u2, @truncate(tac))) {
            0 => 9, // 4096 Hz
            1 => 3, // 262144 Hz
            2 => 5, // 65536 Hz
            3 => 7, // 16384 Hz
        };
    }

    fn edge(self: Timer) bool {
        const bit = selectedBit(self.tac);
        return (self.tac & 0x04 != 0) and (self.counter >> bit) & 1 != 0;
    }

    /// Advance by one t-cycle.
    pub fn tick(self: *Timer) void {
        self.advance(1);
    }

    /// Advance by a whole instruction's cycles at once.
    ///
    /// The falling edges of a fixed counter bit are periodic, so they can be
    /// counted arithmetically rather than found by stepping: bit `b` falls once
    /// every `2^(b+1)` counter values, so the number of falls in `(c, c+n]` is
    /// the difference of the two quotients. That is exactly what a per-cycle
    /// loop would have found - and it takes the emulator from 43 million loop
    /// iterations per 600 frames to one shift per instruction.
    ///
    /// The subsequent TIMA loop is not the same kind of hazard: at the fastest
    /// rate a bit falls every 16 cycles and the longest instruction is 24, so
    /// it runs at most twice.
    pub fn advance(self: *Timer, cycles: u32) void {
        const before: u32 = self.counter;
        const after = before + cycles;
        self.counter = @truncate(after);

        if (self.tac & 0x04 != 0) {
            const shift: u5 = @as(u5, selectedBit(self.tac)) + 1;
            var edges = (after >> shift) - (before >> shift);
            while (edges > 0) : (edges -= 1) {
                self.tima +%= 1;
                if (self.tima == 0) {
                    self.tima = self.tma;
                    self.overflow = true;
                }
            }
        }
        self.prev_edge = self.edge();
    }

    fn detect(self: *Timer) void {
        const now = self.edge();
        if (self.prev_edge and !now) {
            self.tima +%= 1;
            if (self.tima == 0) {
                self.tima = self.tma;
                self.overflow = true;
            }
        }
        self.prev_edge = now;
    }

    pub fn read(self: Timer, addr: u16) u8 {
        return switch (addr) {
            div_addr => @truncate(self.counter >> 8),
            tima_addr => self.tima,
            tma_addr => self.tma,
            // Only the low three bits exist; the rest read as set.
            tac_addr => self.tac | 0xF8,
            else => 0xFF,
        };
    }

    pub fn write(self: *Timer, addr: u16, v: u8) void {
        switch (addr) {
            div_addr => {
                // Any write resets the whole counter, not just the visible
                // byte - and the reset can drop the selected bit, clocking
                // TIMA once on the way past.
                self.counter = 0;
                self.detect();
            },
            tima_addr => self.tima = v,
            tma_addr => self.tma = v,
            tac_addr => {
                self.tac = v & 0x07;
                self.detect();
            },
            else => {},
        }
    }
};

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

fn ticks(t: *Timer, n: usize) void {
    for (0..n) |_| t.tick();
}

test "DIV advances once every 256 t-cycles" {
    var t: Timer = .{};
    ticks(&t, 255);
    try testing.expectEqual(@as(u8, 0), t.read(div_addr));
    t.tick();
    try testing.expectEqual(@as(u8, 1), t.read(div_addr));
    ticks(&t, 256 * 3);
    try testing.expectEqual(@as(u8, 4), t.read(div_addr));
}

test "writing DIV resets the whole internal counter, not just the visible byte" {
    var t: Timer = .{};
    ticks(&t, 300);
    try testing.expectEqual(@as(u8, 1), t.read(div_addr));
    t.write(div_addr, 0xFF); // the value is ignored
    try testing.expectEqual(@as(u8, 0), t.read(div_addr));
    // If only the top byte had been cleared, the next DIV tick would arrive
    // 212 cycles from now instead of a full 256.
    ticks(&t, 255);
    try testing.expectEqual(@as(u8, 0), t.read(div_addr));
    t.tick();
    try testing.expectEqual(@as(u8, 1), t.read(div_addr));
}

test "each TAC rate clocks TIMA at its documented period" {
    const cases = [_]struct { tac: u8, period: usize }{
        .{ .tac = 0x04, .period = 1024 },
        .{ .tac = 0x05, .period = 16 },
        .{ .tac = 0x06, .period = 64 },
        .{ .tac = 0x07, .period = 256 },
    };
    for (cases) |c| {
        var t: Timer = .{};
        t.write(tac_addr, c.tac);
        t.write(div_addr, 0);
        ticks(&t, c.period - 1);
        try testing.expectEqual(@as(u8, 0), t.tima);
        t.tick();
        try testing.expectEqual(@as(u8, 1), t.tima);
        ticks(&t, c.period);
        try testing.expectEqual(@as(u8, 2), t.tima);
    }
}

test "a disabled timer does not count" {
    var t: Timer = .{};
    t.write(tac_addr, 0x00); // rate 0, enable clear
    ticks(&t, 4096);
    try testing.expectEqual(@as(u8, 0), t.tima);
}

test "TIMA reloads from TMA on overflow and reports it" {
    var t: Timer = .{};
    t.write(tac_addr, 0x05); // every 16 cycles
    t.write(tma_addr, 0xF0);
    t.write(tima_addr, 0xFF);
    ticks(&t, 16);
    try testing.expectEqual(@as(u8, 0xF0), t.tima);
    try testing.expect(t.overflow);
}

test "TAC reads back with its unused bits set" {
    var t: Timer = .{};
    t.write(tac_addr, 0x05);
    try testing.expectEqual(@as(u8, 0xFD), t.read(tac_addr));
}
