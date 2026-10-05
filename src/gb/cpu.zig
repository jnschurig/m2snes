//! The Game Boy's SM83 CPU.
//!
//! Decoding is structured rather than transcribed. The 512 opcodes (256 plus
//! the `$CB` page) are not 512 independent facts: they factor into
//! `x = op >> 6`, `y = (op >> 3) & 7`, `z = op & 7`, and the register/condition
//! tables those index. Writing them out one by one would mean 512 chances to
//! mistype a register index; decoding them means the register tables are
//! written once and every instruction that uses them is right or wrong
//! together, which is a failure mode a test can actually find.
//!
//! The CPU knows nothing about the memory map. `step` takes any `bus` exposing
//! `read(u16) u8` and `write(u16, u8) void`, so the tests here run against a
//! flat 64 KiB array and the real machine passes `bus.Bus`. That separation is
//! also what lets the blargg suites run without an LCD or a cartridge model.
//!
//! Timing is accounted per instruction, not per memory access. That is enough
//! for `instr_timing`, which measures whole instructions, and it is honestly
//! less than a hardware-accurate core: sub-instruction access ordering is not
//! modelled, so tests that observe *when within an instruction* a write lands
//! would fail. None of Phase 0a's uses need that - see `02-plan.md`, Step 6.

const std = @import("std");

/// The F register. Only the high nibble exists; the low nibble reads as zero
/// on hardware and is masked on every write.
pub const Flags = packed struct(u8) {
    _unused: u4 = 0,
    c: bool = false,
    h: bool = false,
    n: bool = false,
    z: bool = false,
};

pub const Error = error{IllegalOpcode};

/// Interrupt sources, in priority order. The bit index is also the position in
/// IE/IF, and the vector is `0x40 + 8 * bit`.
pub const Interrupt = enum(u3) {
    vblank = 0,
    lcd_stat = 1,
    timer = 2,
    serial = 3,
    joypad = 4,

    pub fn vector(self: Interrupt) u16 {
        return 0x40 + 8 * @as(u16, @intFromEnum(self));
    }
};

pub const if_addr: u16 = 0xFF0F;
pub const ie_addr: u16 = 0xFFFF;

pub const Cpu = struct {
    a: u8 = 0,
    f: Flags = .{},
    b: u8 = 0,
    c: u8 = 0,
    d: u8 = 0,
    e: u8 = 0,
    h: u8 = 0,
    l: u8 = 0,
    sp: u16 = 0,
    pc: u16 = 0,

    ime: bool = false,
    /// EI enables interrupts *after* the following instruction. Counts down so
    /// the delay is one instruction rather than one step.
    ime_delay: u2 = 0,
    halted: bool = false,
    /// HALT with IME clear and an interrupt already pending does not halt: the
    /// byte after HALT is fetched twice. Emulating it matters because the
    /// pattern appears in real code that assumes the quirk.
    halt_bug: bool = false,
    stopped: bool = false,
    /// Total t-cycles executed. Wraps at u64, which at 4 MiHz is 146 000 years.
    cycles: u64 = 0,

    /// State after the DMG boot ROM has run and handed control to the
    /// cartridge. We start here because the boot ROM is Nintendo's and this
    /// repository ships no copyrighted bytes; the values are the documented
    /// post-boot register file for a cartridge whose header checksum is
    /// nonzero (which sets H and C).
    pub fn dmgPostBoot() Cpu {
        return .{
            .a = 0x01,
            .f = .{ .z = true, .n = false, .h = true, .c = true },
            .b = 0x00,
            .c = 0x13,
            .d = 0x00,
            .e = 0xD8,
            .h = 0x01,
            .l = 0x4D,
            .sp = 0xFFFE,
            .pc = 0x0100,
        };
    }

    /// Power-on state, for a run that starts in a boot ROM rather than at
    /// $0100. The boot ROM sets SP and the register file itself -- its very
    /// first instruction is `LD SP,$FFFE` -- so what matters here is only that
    /// PC is zero and nothing carries over from a previous run.
    pub fn powerOn() Cpu {
        return .{
            .a = 0,
            .f = .{ .z = false, .n = false, .h = false, .c = false },
            .b = 0,
            .c = 0,
            .d = 0,
            .e = 0,
            .h = 0,
            .l = 0,
            .sp = 0,
            .pc = 0,
        };
    }

    // ---- Register pairs ---------------------------------------------------

    pub fn af(self: Cpu) u16 {
        return (@as(u16, self.a) << 8) | @as(u8, @bitCast(self.f));
    }
    pub fn bc(self: Cpu) u16 {
        return (@as(u16, self.b) << 8) | self.c;
    }
    pub fn de(self: Cpu) u16 {
        return (@as(u16, self.d) << 8) | self.e;
    }
    pub fn hl(self: Cpu) u16 {
        return (@as(u16, self.h) << 8) | self.l;
    }
    pub fn setAf(self: *Cpu, v: u16) void {
        self.a = @truncate(v >> 8);
        self.f = @bitCast(@as(u8, @truncate(v)) & 0xF0);
    }
    pub fn setBc(self: *Cpu, v: u16) void {
        self.b = @truncate(v >> 8);
        self.c = @truncate(v);
    }
    pub fn setDe(self: *Cpu, v: u16) void {
        self.d = @truncate(v >> 8);
        self.e = @truncate(v);
    }
    pub fn setHl(self: *Cpu, v: u16) void {
        self.h = @truncate(v >> 8);
        self.l = @truncate(v);
    }

    // ---- Fetch ------------------------------------------------------------

    fn fetch8(self: *Cpu, bus: anytype) u8 {
        const v = bus.read(self.pc);
        if (self.halt_bug) {
            // The fetch happens, but PC does not advance: the next fetch reads
            // the same byte again.
            self.halt_bug = false;
        } else {
            self.pc +%= 1;
        }
        return v;
    }

    fn fetch16(self: *Cpu, bus: anytype) u16 {
        const lo = self.fetch8(bus);
        const hi = self.fetch8(bus);
        return (@as(u16, hi) << 8) | lo;
    }

    fn push16(self: *Cpu, bus: anytype, v: u16) void {
        self.sp -%= 1;
        bus.write(self.sp, @truncate(v >> 8));
        self.sp -%= 1;
        bus.write(self.sp, @truncate(v));
    }

    fn pop16(self: *Cpu, bus: anytype) u16 {
        const lo = bus.read(self.sp);
        self.sp +%= 1;
        const hi = bus.read(self.sp);
        self.sp +%= 1;
        return (@as(u16, hi) << 8) | lo;
    }

    // ---- Register file indexed by the decode tables -----------------------
    //
    // r[] = B, C, D, E, H, L, (HL), A. Index 6 is a memory access, which is
    // where the extra cycles in every (HL) form come from.

    fn readR(self: *Cpu, bus: anytype, idx: u3) u8 {
        return switch (idx) {
            0 => self.b,
            1 => self.c,
            2 => self.d,
            3 => self.e,
            4 => self.h,
            5 => self.l,
            6 => bus.read(self.hl()),
            7 => self.a,
        };
    }

    fn writeR(self: *Cpu, bus: anytype, idx: u3, v: u8) void {
        switch (idx) {
            0 => self.b = v,
            1 => self.c = v,
            2 => self.d = v,
            3 => self.e = v,
            4 => self.h = v,
            5 => self.l = v,
            6 => bus.write(self.hl(), v),
            7 => self.a = v,
        }
    }

    /// rp[] = BC, DE, HL, SP
    fn readRp(self: *Cpu, idx: u2) u16 {
        return switch (idx) {
            0 => self.bc(),
            1 => self.de(),
            2 => self.hl(),
            3 => self.sp,
        };
    }

    fn writeRp(self: *Cpu, idx: u2, v: u16) void {
        switch (idx) {
            0 => self.setBc(v),
            1 => self.setDe(v),
            2 => self.setHl(v),
            3 => self.sp = v,
        }
    }

    /// rp2[] = BC, DE, HL, AF — the PUSH/POP table, where SP is replaced by AF.
    fn readRp2(self: *Cpu, idx: u2) u16 {
        return if (idx == 3) self.af() else self.readRp(idx);
    }

    fn writeRp2(self: *Cpu, idx: u2, v: u16) void {
        if (idx == 3) self.setAf(v) else self.writeRp(idx, v);
    }

    /// cc[] = NZ, Z, NC, C
    fn cond(self: Cpu, idx: u2) bool {
        return switch (idx) {
            0 => !self.f.z,
            1 => self.f.z,
            2 => !self.f.c,
            3 => self.f.c,
        };
    }

    // ---- ALU --------------------------------------------------------------

    fn alu(self: *Cpu, op: u3, v: u8) void {
        switch (op) {
            0 => self.add(v, false), // ADD
            1 => self.add(v, self.f.c), // ADC
            2 => self.a = self.sub(v, false), // SUB
            3 => self.a = self.sub(v, self.f.c), // SBC
            4 => { // AND
                self.a &= v;
                self.f = .{ .z = self.a == 0, .n = false, .h = true, .c = false };
            },
            5 => { // XOR
                self.a ^= v;
                self.f = .{ .z = self.a == 0, .n = false, .h = false, .c = false };
            },
            6 => { // OR
                self.a |= v;
                self.f = .{ .z = self.a == 0, .n = false, .h = false, .c = false };
            },
            7 => _ = self.sub(v, false), // CP: SUB without keeping the result
        }
    }

    fn add(self: *Cpu, v: u8, carry: bool) void {
        const cin: u16 = @intFromBool(carry);
        const sum = @as(u16, self.a) + @as(u16, v) + cin;
        const half = (@as(u16, self.a) & 0xF) + (@as(u16, v) & 0xF) + cin;
        self.a = @truncate(sum);
        self.f = .{ .z = self.a == 0, .n = false, .h = half > 0xF, .c = sum > 0xFF };
    }

    /// Shared by SUB, SBC and CP; the caller decides whether to keep the value.
    fn sub(self: *Cpu, v: u8, carry: bool) u8 {
        const cin: u16 = @intFromBool(carry);
        const diff = @as(u16, self.a) -% @as(u16, v) -% cin;
        const half = (@as(u16, self.a) & 0xF) -% (@as(u16, v) & 0xF) -% cin;
        const r: u8 = @truncate(diff);
        self.f = .{ .z = r == 0, .n = true, .h = half & 0x10 != 0, .c = diff & 0x100 != 0 };
        return r;
    }

    fn inc8(self: *Cpu, v: u8) u8 {
        const r = v +% 1;
        self.f = .{ .z = r == 0, .n = false, .h = (v & 0xF) == 0xF, .c = self.f.c };
        return r;
    }

    fn dec8(self: *Cpu, v: u8) u8 {
        const r = v -% 1;
        self.f = .{ .z = r == 0, .n = true, .h = (v & 0xF) == 0, .c = self.f.c };
        return r;
    }

    fn addHl(self: *Cpu, v: u16) void {
        const a = self.hl();
        const sum = @as(u32, a) + @as(u32, v);
        self.f = .{
            .z = self.f.z,
            .n = false,
            .h = (a & 0xFFF) + (v & 0xFFF) > 0xFFF,
            .c = sum > 0xFFFF,
        };
        self.setHl(@truncate(sum));
    }

    /// ADD SP,d and LD HL,SP+d share this. The flags come from the *low byte*
    /// addition, unsigned, which is why H and C look like 8-bit flags on a
    /// 16-bit operation.
    fn addSpSigned(self: *Cpu, d: i8) u16 {
        const off: u16 = @bitCast(@as(i16, d));
        const r = self.sp +% off;
        self.f = .{
            .z = false,
            .n = false,
            .h = (self.sp & 0xF) + (off & 0xF) > 0xF,
            .c = (self.sp & 0xFF) + (off & 0xFF) > 0xFF,
        };
        return r;
    }

    /// Decimal adjust after an add or subtract of BCD values. The N flag
    /// selects which direction to correct in, which is the whole reason N
    /// exists on this CPU.
    fn daa(self: *Cpu) void {
        var carry = self.f.c;
        if (!self.f.n) {
            if (self.f.c or self.a > 0x99) {
                self.a +%= 0x60;
                carry = true;
            }
            if (self.f.h or (self.a & 0x0F) > 0x09) self.a +%= 0x06;
        } else {
            if (self.f.c) self.a -%= 0x60;
            if (self.f.h) self.a -%= 0x06;
        }
        self.f = .{ .z = self.a == 0, .n = self.f.n, .h = false, .c = carry };
    }

    // ---- CB rotates and shifts --------------------------------------------

    fn rot(self: *Cpu, op: u3, v: u8) u8 {
        const r: u8 = switch (op) {
            0 => std.math.rotl(u8, v, 1), // RLC
            1 => std.math.rotr(u8, v, 1), // RRC
            2 => (v << 1) | @intFromBool(self.f.c), // RL
            3 => (v >> 1) | (@as(u8, @intFromBool(self.f.c)) << 7), // RR
            4 => v << 1, // SLA
            5 => (v >> 1) | (v & 0x80), // SRA: arithmetic, bit 7 sticks
            6 => (v << 4) | (v >> 4), // SWAP
            7 => v >> 1, // SRL
        };
        const carry: bool = switch (op) {
            0, 2, 4 => v & 0x80 != 0,
            1, 3, 5, 7 => v & 0x01 != 0,
            6 => false,
        };
        self.f = .{ .z = r == 0, .n = false, .h = false, .c = carry };
        return r;
    }

    // ---- Interrupts -------------------------------------------------------

    fn pending(bus: anytype) u8 {
        return bus.read(if_addr) & bus.read(ie_addr) & 0x1F;
    }

    /// Service the highest-priority pending interrupt. 20 t-cycles: two idle
    /// M-cycles, then the push and the jump.
    fn service(self: *Cpu, bus: anytype, bit: u3) u32 {
        self.ime = false;
        self.ime_delay = 0;
        bus.write(if_addr, bus.read(if_addr) & ~(@as(u8, 1) << bit));
        self.push16(bus, self.pc);
        self.pc = 0x40 + 8 * @as(u16, bit);
        return 20;
    }

    // ---- Step -------------------------------------------------------------

    /// Execute one instruction (or service one interrupt) and return the
    /// t-cycles it took.
    pub fn step(self: *Cpu, bus: anytype) Error!u32 {
        const p = pending(bus);
        if (self.halted and p != 0) self.halted = false;

        if (self.ime and p != 0) {
            const bit: u3 = @intCast(@ctz(p));
            const n = self.service(bus, bit);
            self.cycles += n;
            return n;
        }

        const n = if (self.halted or self.stopped) 4 else try self.exec(bus);

        // EI's delay is counted down *after* the instruction, and EI itself
        // sets it to 2. So the countdown reaches zero at the end of the
        // instruction following EI - which is exactly the hardware rule: the
        // instruction after EI always runs before an interrupt can be taken.
        if (self.ime_delay > 0) {
            self.ime_delay -= 1;
            if (self.ime_delay == 0) self.ime = true;
        }

        self.cycles += n;
        return n;
    }

    fn exec(self: *Cpu, bus: anytype) Error!u32 {
        const op = self.fetch8(bus);
        const x: u2 = @truncate(op >> 6);
        const y: u3 = @truncate(op >> 3);
        const z: u3 = @truncate(op);
        const p: u2 = @truncate(y >> 1);
        const q: u1 = @truncate(y);

        switch (x) {
            0 => return self.execX0(bus, y, z, p, q),
            1 => {
                if (y == 6 and z == 6) return self.halt(bus);
                const v = self.readR(bus, z);
                self.writeR(bus, y, v);
                return if (y == 6 or z == 6) 8 else 4;
            },
            2 => {
                const v = self.readR(bus, z);
                self.alu(y, v);
                return if (z == 6) 8 else 4;
            },
            3 => return self.execX3(bus, y, z, p, q),
        }
    }

    fn halt(self: *Cpu, bus: anytype) u32 {
        if (!self.ime and pending(bus) != 0) {
            // The documented HALT bug: no halt, and the next byte is read
            // twice because PC does not advance past it.
            self.halt_bug = true;
        } else {
            self.halted = true;
        }
        return 4;
    }

    fn execX0(self: *Cpu, bus: anytype, y: u3, z: u3, p: u2, q: u1) Error!u32 {
        switch (z) {
            0 => switch (y) {
                0 => return 4, // NOP
                1 => { // LD (nn),SP
                    const addr = self.fetch16(bus);
                    bus.write(addr, @truncate(self.sp));
                    bus.write(addr +% 1, @truncate(self.sp >> 8));
                    return 20;
                },
                2 => { // STOP - two bytes, and we do not model the halt state
                    _ = self.fetch8(bus);
                    self.stopped = true;
                    return 4;
                },
                3 => { // JR d
                    const d: i8 = @bitCast(self.fetch8(bus));
                    self.pc = self.pc +% @as(u16, @bitCast(@as(i16, d)));
                    return 12;
                },
                else => { // JR cc,d
                    const d: i8 = @bitCast(self.fetch8(bus));
                    if (self.cond(@truncate(y - 4))) {
                        self.pc = self.pc +% @as(u16, @bitCast(@as(i16, d)));
                        return 12;
                    }
                    return 8;
                },
            },
            1 => {
                if (q == 0) { // LD rp,nn
                    const v = self.fetch16(bus);
                    self.writeRp(p, v);
                    return 12;
                }
                self.addHl(self.readRp(p)); // ADD HL,rp
                return 8;
            },
            2 => {
                switch (p) {
                    0 => if (q == 0) bus.write(self.bc(), self.a) else {
                        self.a = bus.read(self.bc());
                    },
                    1 => if (q == 0) bus.write(self.de(), self.a) else {
                        self.a = bus.read(self.de());
                    },
                    2 => { // (HL+)
                        const addr = self.hl();
                        if (q == 0) bus.write(addr, self.a) else {
                            self.a = bus.read(addr);
                        }
                        self.setHl(addr +% 1);
                    },
                    3 => { // (HL-)
                        const addr = self.hl();
                        if (q == 0) bus.write(addr, self.a) else {
                            self.a = bus.read(addr);
                        }
                        self.setHl(addr -% 1);
                    },
                }
                return 8;
            },
            3 => { // INC/DEC rp - no flags
                const v = self.readRp(p);
                self.writeRp(p, if (q == 0) v +% 1 else v -% 1);
                return 8;
            },
            4 => { // INC r
                const v = self.readR(bus, y);
                self.writeR(bus, y, self.inc8(v));
                return if (y == 6) 12 else 4;
            },
            5 => { // DEC r
                const v = self.readR(bus, y);
                self.writeR(bus, y, self.dec8(v));
                return if (y == 6) 12 else 4;
            },
            6 => { // LD r,n
                const v = self.fetch8(bus);
                self.writeR(bus, y, v);
                return if (y == 6) 12 else 8;
            },
            7 => {
                switch (y) {
                    // The A-register rotates always clear Z, unlike their CB
                    // counterparts. Conflating the two is the classic bug, and
                    // 01-special is the test that catches it.
                    0 => { // RLCA
                        const c = self.a & 0x80 != 0;
                        self.a = std.math.rotl(u8, self.a, 1);
                        self.f = .{ .z = false, .n = false, .h = false, .c = c };
                    },
                    1 => { // RRCA
                        const c = self.a & 0x01 != 0;
                        self.a = std.math.rotr(u8, self.a, 1);
                        self.f = .{ .z = false, .n = false, .h = false, .c = c };
                    },
                    2 => { // RLA
                        const c = self.a & 0x80 != 0;
                        self.a = (self.a << 1) | @intFromBool(self.f.c);
                        self.f = .{ .z = false, .n = false, .h = false, .c = c };
                    },
                    3 => { // RRA
                        const c = self.a & 0x01 != 0;
                        self.a = (self.a >> 1) | (@as(u8, @intFromBool(self.f.c)) << 7);
                        self.f = .{ .z = false, .n = false, .h = false, .c = c };
                    },
                    4 => self.daa(),
                    5 => { // CPL
                        self.a = ~self.a;
                        self.f = .{ .z = self.f.z, .n = true, .h = true, .c = self.f.c };
                    },
                    6 => self.f = .{ .z = self.f.z, .n = false, .h = false, .c = true }, // SCF
                    7 => self.f = .{ .z = self.f.z, .n = false, .h = false, .c = !self.f.c }, // CCF
                }
                return 4;
            },
        }
    }

    fn execX3(self: *Cpu, bus: anytype, y: u3, z: u3, p: u2, q: u1) Error!u32 {
        switch (z) {
            0 => switch (y) {
                0, 1, 2, 3 => { // RET cc
                    if (self.cond(@truncate(y))) {
                        self.pc = self.pop16(bus);
                        return 20;
                    }
                    return 8;
                },
                4 => { // LD ($FF00+n),A
                    const n = self.fetch8(bus);
                    bus.write(0xFF00 + @as(u16, n), self.a);
                    return 12;
                },
                5 => { // ADD SP,d
                    const d: i8 = @bitCast(self.fetch8(bus));
                    self.sp = self.addSpSigned(d);
                    return 16;
                },
                6 => { // LD A,($FF00+n)
                    const n = self.fetch8(bus);
                    self.a = bus.read(0xFF00 + @as(u16, n));
                    return 12;
                },
                7 => { // LD HL,SP+d
                    const d: i8 = @bitCast(self.fetch8(bus));
                    const v = self.addSpSigned(d);
                    self.setHl(v);
                    return 12;
                },
            },
            1 => {
                if (q == 0) { // POP rp2
                    const v = self.pop16(bus);
                    self.writeRp2(p, v);
                    return 12;
                }
                switch (p) {
                    0 => { // RET
                        self.pc = self.pop16(bus);
                        return 16;
                    },
                    1 => { // RETI - enables interrupts immediately, no delay
                        self.pc = self.pop16(bus);
                        self.ime = true;
                        self.ime_delay = 0;
                        return 16;
                    },
                    2 => { // JP HL
                        self.pc = self.hl();
                        return 4;
                    },
                    3 => { // LD SP,HL
                        self.sp = self.hl();
                        return 8;
                    },
                }
            },
            2 => switch (y) {
                0, 1, 2, 3 => { // JP cc,nn
                    const addr = self.fetch16(bus);
                    if (self.cond(@truncate(y))) {
                        self.pc = addr;
                        return 16;
                    }
                    return 12;
                },
                4 => { // LD ($FF00+C),A
                    bus.write(0xFF00 + @as(u16, self.c), self.a);
                    return 8;
                },
                5 => { // LD (nn),A
                    const addr = self.fetch16(bus);
                    bus.write(addr, self.a);
                    return 16;
                },
                6 => { // LD A,($FF00+C)
                    self.a = bus.read(0xFF00 + @as(u16, self.c));
                    return 8;
                },
                7 => { // LD A,(nn)
                    const addr = self.fetch16(bus);
                    self.a = bus.read(addr);
                    return 16;
                },
            },
            3 => switch (y) {
                0 => { // JP nn
                    self.pc = self.fetch16(bus);
                    return 16;
                },
                1 => return self.execCb(bus),
                6 => { // DI
                    self.ime = false;
                    self.ime_delay = 0;
                    return 4;
                },
                7 => { // EI - takes effect after the next instruction
                    self.ime_delay = 2;
                    return 4;
                },
                else => return Error.IllegalOpcode,
            },
            4 => { // CALL cc,nn
                if (y >= 4) return Error.IllegalOpcode;
                const addr = self.fetch16(bus);
                if (self.cond(@truncate(y))) {
                    self.push16(bus, self.pc);
                    self.pc = addr;
                    return 24;
                }
                return 12;
            },
            5 => {
                if (q == 0) { // PUSH rp2
                    self.push16(bus, self.readRp2(p));
                    return 16;
                }
                if (p != 0) return Error.IllegalOpcode;
                const addr = self.fetch16(bus); // CALL nn
                self.push16(bus, self.pc);
                self.pc = addr;
                return 24;
            },
            6 => { // alu A,n
                const n = self.fetch8(bus);
                self.alu(y, n);
                return 8;
            },
            7 => { // RST
                self.push16(bus, self.pc);
                self.pc = @as(u16, y) * 8;
                return 16;
            },
        }
    }

    fn execCb(self: *Cpu, bus: anytype) u32 {
        const op = self.fetch8(bus);
        const x: u2 = @truncate(op >> 6);
        const y: u3 = @truncate(op >> 3);
        const z: u3 = @truncate(op);
        const mem = z == 6;

        switch (x) {
            0 => { // rot/shift
                const v = self.readR(bus, z);
                self.writeR(bus, z, self.rot(y, v));
                return if (mem) 16 else 8;
            },
            1 => { // BIT y,r - reads only, so (HL) costs 12 rather than 16
                const v = self.readR(bus, z);
                self.f = .{
                    .z = v & (@as(u8, 1) << y) == 0,
                    .n = false,
                    .h = true,
                    .c = self.f.c,
                };
                return if (mem) 12 else 8;
            },
            2 => { // RES y,r
                const v = self.readR(bus, z);
                self.writeR(bus, z, v & ~(@as(u8, 1) << y));
                return if (mem) 16 else 8;
            },
            3 => { // SET y,r
                const v = self.readR(bus, z);
                self.writeR(bus, z, v | (@as(u8, 1) << y));
                return if (mem) 16 else 8;
            },
        }
    }
};

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

/// A flat 64 KiB address space, so the CPU can be exercised with no machine
/// around it.
pub const FlatBus = struct {
    mem: [0x10000]u8 = @splat(0),

    pub fn read(self: *FlatBus, addr: u16) u8 {
        return self.mem[addr];
    }
    pub fn write(self: *FlatBus, addr: u16, v: u8) void {
        self.mem[addr] = v;
    }
};

fn run(cpu: *Cpu, bus: *FlatBus, code: []const u8) !u32 {
    @memcpy(bus.mem[0x100..][0..code.len], code);
    cpu.pc = 0x100;
    return cpu.step(bus);
}

test "F's low nibble does not exist" {
    var cpu: Cpu = .{};
    cpu.setAf(0xAB_FF);
    try testing.expectEqual(@as(u16, 0xAB_F0), cpu.af());
    cpu.setAf(0x00_0F);
    try testing.expectEqual(@as(u16, 0), cpu.af());
}

test "post-boot state is the documented DMG hand-off" {
    const cpu = Cpu.dmgPostBoot();
    try testing.expectEqual(@as(u16, 0x01B0), cpu.af());
    try testing.expectEqual(@as(u16, 0x0013), cpu.bc());
    try testing.expectEqual(@as(u16, 0x00D8), cpu.de());
    try testing.expectEqual(@as(u16, 0x014D), cpu.hl());
    try testing.expectEqual(@as(u16, 0xFFFE), cpu.sp);
    try testing.expectEqual(@as(u16, 0x0100), cpu.pc);
}

test "the A-register rotates clear Z, the CB rotates do not" {
    var bus: FlatBus = .{};
    var cpu: Cpu = .{};

    // RLCA on 0 leaves 0 but must still clear Z.
    cpu.a = 0;
    cpu.f = .{ .z = true };
    _ = try run(&cpu, &bus, &[_]u8{0x07});
    try testing.expect(!cpu.f.z);

    // CB RLC B on 0 sets Z.
    cpu.b = 0;
    _ = try run(&cpu, &bus, &[_]u8{ 0xCB, 0x00 });
    try testing.expect(cpu.f.z);
}

test "DAA corrects in the direction N selects" {
    var bus: FlatBus = .{};
    var cpu: Cpu = .{};

    // 0x09 + 0x01 = 0x0A, which must become 0x10.
    cpu.a = 0x09;
    _ = try run(&cpu, &bus, &[_]u8{ 0xC6, 0x01, 0x27 }); // ADD A,1
    _ = try cpu.step(&bus); // DAA
    try testing.expectEqual(@as(u8, 0x10), cpu.a);

    // 0x10 - 0x01 = 0x0F, which must become 0x09 - the same low nibble,
    // corrected the other way because N is set.
    cpu.a = 0x10;
    _ = try run(&cpu, &bus, &[_]u8{ 0xD6, 0x01, 0x27 }); // SUB 1
    _ = try cpu.step(&bus); // DAA
    try testing.expectEqual(@as(u8, 0x09), cpu.a);

    // The high-nibble correction, which the two cases above never reach: a
    // borrow out of the byte means subtracting 0x60, not 0x06. blargg's
    // 01-special catches a wrong constant here, but only after running a
    // whole ROM - this pins it directly.
    cpu.a = 0x00;
    _ = try run(&cpu, &bus, &[_]u8{ 0xD6, 0x01, 0x27 }); // SUB 1 -> 0xFF, C set
    try testing.expect(cpu.f.c);
    _ = try cpu.step(&bus); // DAA
    try testing.expectEqual(@as(u8, 0x99), cpu.a);
    try testing.expect(cpu.f.c);

    // And the add direction's high-nibble correction.
    cpu.a = 0x90;
    _ = try run(&cpu, &bus, &[_]u8{ 0xC6, 0x10, 0x27 }); // ADD 0x10 -> 0xA0
    _ = try cpu.step(&bus); // DAA
    try testing.expectEqual(@as(u8, 0x00), cpu.a);
    try testing.expect(cpu.f.c);
    try testing.expect(cpu.f.z);
}

test "ADD SP,d takes its H and C from the low byte, unsigned" {
    var bus: FlatBus = .{};
    var cpu: Cpu = .{};
    cpu.sp = 0x000F;
    _ = try run(&cpu, &bus, &[_]u8{ 0xE8, 0x01 }); // ADD SP,+1
    try testing.expectEqual(@as(u16, 0x0010), cpu.sp);
    try testing.expect(cpu.f.h);
    try testing.expect(!cpu.f.c);
    try testing.expect(!cpu.f.z); // never set, even though the result is nonzero

    cpu.sp = 0x00FF;
    _ = try run(&cpu, &bus, &[_]u8{ 0xE8, 0x01 });
    try testing.expectEqual(@as(u16, 0x0100), cpu.sp);
    try testing.expect(cpu.f.c);

    // A negative offset is still added as an unsigned byte for flag purposes,
    // so 0x0010 + (-1) - arithmetically a subtraction - reports C set, from
    // the carry out of 0x10 + 0xFF. H stays clear: 0x0 + 0xF does not carry
    // out of bit 3. Reading these as if they described the 16-bit result is
    // the bug this case exists to catch.
    cpu.sp = 0x0010;
    _ = try run(&cpu, &bus, &[_]u8{ 0xE8, 0xFF });
    try testing.expectEqual(@as(u16, 0x000F), cpu.sp);
    try testing.expect(!cpu.f.h);
    try testing.expect(cpu.f.c);
}

test "SRA keeps bit 7, SRL does not" {
    var bus: FlatBus = .{};
    var cpu: Cpu = .{};
    cpu.b = 0x80;
    _ = try run(&cpu, &bus, &[_]u8{ 0xCB, 0x28 }); // SRA B
    try testing.expectEqual(@as(u8, 0xC0), cpu.b);
    cpu.b = 0x80;
    _ = try run(&cpu, &bus, &[_]u8{ 0xCB, 0x38 }); // SRL B
    try testing.expectEqual(@as(u8, 0x40), cpu.b);
}

test "(HL) forms cost the extra memory cycles" {
    var bus: FlatBus = .{};
    var cpu: Cpu = .{};
    cpu.setHl(0xC000);
    try testing.expectEqual(@as(u32, 4), try run(&cpu, &bus, &[_]u8{0x78})); // LD A,B
    try testing.expectEqual(@as(u32, 8), try run(&cpu, &bus, &[_]u8{0x7E})); // LD A,(HL)
    try testing.expectEqual(@as(u32, 12), try run(&cpu, &bus, &[_]u8{0x34})); // INC (HL)
    try testing.expectEqual(@as(u32, 8), try run(&cpu, &bus, &[_]u8{ 0xCB, 0x00 })); // RLC B
    try testing.expectEqual(@as(u32, 16), try run(&cpu, &bus, &[_]u8{ 0xCB, 0x06 })); // RLC (HL)
    try testing.expectEqual(@as(u32, 12), try run(&cpu, &bus, &[_]u8{ 0xCB, 0x46 })); // BIT 0,(HL)
}

test "conditional control flow costs the taken path only when taken" {
    var bus: FlatBus = .{};
    var cpu: Cpu = .{};
    cpu.f.z = false;
    try testing.expectEqual(@as(u32, 12), try run(&cpu, &bus, &[_]u8{ 0x20, 0x05 })); // JR NZ taken
    cpu.f.z = true;
    try testing.expectEqual(@as(u32, 8), try run(&cpu, &bus, &[_]u8{ 0x20, 0x05 })); // not taken
    cpu.sp = 0xFFFE;
    cpu.f.z = false;
    try testing.expectEqual(@as(u32, 24), try run(&cpu, &bus, &[_]u8{ 0xC4, 0x00, 0x20 })); // CALL NZ
    cpu.f.z = true;
    try testing.expectEqual(@as(u32, 12), try run(&cpu, &bus, &[_]u8{ 0xC4, 0x00, 0x20 }));
}

test "EI opens interrupts only after the following instruction" {
    var bus: FlatBus = .{};
    var cpu: Cpu = .{};
    bus.mem[ie_addr] = 0x01;
    bus.mem[if_addr] = 0x01;
    cpu.sp = 0xFFFE;

    @memcpy(bus.mem[0x100..][0..3], &[_]u8{ 0xFB, 0x00, 0x00 }); // EI ; NOP ; NOP
    cpu.pc = 0x100;
    _ = try cpu.step(&bus); // EI
    try testing.expect(!cpu.ime);
    _ = try cpu.step(&bus); // the NOP still runs with interrupts closed
    try testing.expectEqual(@as(u16, 0x102), cpu.pc);
    try testing.expect(cpu.ime);
    const n = try cpu.step(&bus); // now the interrupt is taken
    try testing.expectEqual(@as(u32, 20), n);
    try testing.expectEqual(@as(u16, 0x40), cpu.pc);
    try testing.expect(!cpu.ime);
    try testing.expectEqual(@as(u8, 0), bus.mem[if_addr] & 0x01);
}

test "HALT with IME clear and an interrupt pending reads the next byte twice" {
    var bus: FlatBus = .{};
    var cpu: Cpu = .{};
    bus.mem[ie_addr] = 0x01;
    bus.mem[if_addr] = 0x01;
    cpu.ime = false;
    cpu.a = 0;

    // HALT ; INC A ; ... - the INC A byte is fetched twice, so A ends at 2
    // with PC one past it, not 1.
    @memcpy(bus.mem[0x100..][0..3], &[_]u8{ 0x76, 0x3C, 0x00 });
    cpu.pc = 0x100;
    _ = try cpu.step(&bus); // HALT: does not halt
    try testing.expect(!cpu.halted);
    try testing.expect(cpu.halt_bug);
    _ = try cpu.step(&bus); // INC A, PC does not advance
    try testing.expectEqual(@as(u8, 1), cpu.a);
    try testing.expectEqual(@as(u16, 0x101), cpu.pc);
    _ = try cpu.step(&bus); // the same byte again
    try testing.expectEqual(@as(u8, 2), cpu.a);
    try testing.expectEqual(@as(u16, 0x102), cpu.pc);
}

test "HALT with IME set halts until an interrupt arrives" {
    var bus: FlatBus = .{};
    var cpu: Cpu = .{};
    cpu.ime = true;
    cpu.sp = 0xFFFE;
    bus.mem[ie_addr] = 0x04; // timer
    _ = try run(&cpu, &bus, &[_]u8{0x76});
    try testing.expect(cpu.halted);
    _ = try cpu.step(&bus); // still halted, burning 4 cycles
    try testing.expect(cpu.halted);
    bus.mem[if_addr] = 0x04;
    const n = try cpu.step(&bus);
    try testing.expect(!cpu.halted);
    try testing.expectEqual(@as(u32, 20), n);
    try testing.expectEqual(@as(u16, 0x50), cpu.pc); // the timer vector
}

test "interrupts are serviced in IE/IF bit order" {
    var bus: FlatBus = .{};
    var cpu: Cpu = .{};
    cpu.ime = true;
    cpu.sp = 0xFFFE;
    bus.mem[ie_addr] = 0x1F;
    bus.mem[if_addr] = 0x1F; // everything at once
    cpu.pc = 0x100;
    _ = try cpu.step(&bus);
    try testing.expectEqual(@as(u16, 0x40), cpu.pc); // vblank wins
    try testing.expectEqual(@as(u8, 0x1E), bus.mem[if_addr]); // only its bit cleared
}

test "illegal opcodes are refused rather than executed as something else" {
    var bus: FlatBus = .{};
    var cpu: Cpu = .{};
    for ([_]u8{ 0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD }) |op| {
        @memcpy(bus.mem[0x100..][0..1], &[_]u8{op});
        cpu.pc = 0x100;
        try testing.expectError(Error.IllegalOpcode, cpu.step(&bus));
    }
}

test "every opcode except the eleven illegal ones decodes" {
    var illegal: usize = 0;
    for (0..256) |i| {
        const op: u8 = @intCast(i);
        var bus: FlatBus = .{};
        var cpu: Cpu = .{};
        cpu.sp = 0xC000;
        cpu.setHl(0xC100);
        @memcpy(bus.mem[0x100..][0..3], &[_]u8{ op, 0x00, 0x00 });
        cpu.pc = 0x100;
        const n = cpu.step(&bus) catch {
            illegal += 1;
            continue;
        };
        // Nothing takes zero cycles, and nothing takes more than CALL's 24.
        try testing.expect(n >= 4 and n <= 24);
    }
    try testing.expectEqual(@as(usize, 11), illegal);
}

test "every CB opcode decodes and costs a legal number of cycles" {
    for (0..256) |i| {
        const op: u8 = @intCast(i);
        var bus: FlatBus = .{};
        var cpu: Cpu = .{};
        cpu.setHl(0xC100);
        @memcpy(bus.mem[0x100..][0..2], &[_]u8{ 0xCB, op });
        cpu.pc = 0x100;
        const n = try cpu.step(&bus);
        const mem = (op & 7) == 6;
        const is_bit = (op >> 6) == 1;
        const want: u32 = if (!mem) 8 else if (is_bit) 12 else 16;
        try testing.expectEqual(want, n);
    }
}
