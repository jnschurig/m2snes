//! Calling one routine on a booted machine, and asking what it did.
//!
//! Step 14 needs two things that turn out to be the same thing. The logic
//! ledger needs to know which program counters the game actually executes,
//! because a static trace cannot follow this game's `JP HL` dispatch tables and
//! stalls at 22% of bank 0. The per-routine unit tests need to set up state,
//! call a routine, and assert registers and memory. Both are "boot the retail
//! ROM, put it in a known state, and drive it", so both live here.
//!
//! The call mechanism is `probe.runDoors`'s, generalised. That routine proved
//! on real data that a booted machine will execute any subroutine on demand:
//! push a return address the game never uses, set PC, and step until PC comes
//! back to it. What was specific to doors -- the interpreter's address, the
//! door index in RAM, the screen-table watch -- becomes parameters.
//!
//! Three deliberate differences from `runDoors`:
//!
//!  1. **No boot ROM.** `runDoors` boots through SameBoy's `dmg_boot.bin`
//!     because it shares a cycle origin with the emulator it is graded
//!     against. Nothing here is graded against SameBoy, and that file is a
//!     build artefact under `vendor/` that a fresh checkout does not have. So
//!     this boots from `System.init`'s documented post-boot register file,
//!     which needs no vendored bytes and lets the ledger run on any checkout.
//!  2. **Interrupts off by default during a call.** With IME set, a vblank
//!     part-way through the routine under test runs the game's whole frame
//!     handler inside the measurement. Deterministic, but it means an
//!     assertion about "what this routine did" is really about what it and the
//!     frame handler did together. `Call.interrupts` turns them back on for
//!     the cases that want that.
//!  3. **An execution watch.** Every instruction start is offered to an
//!     optional callback with the bank it was fetched from, which is what the
//!     ledger records. It sits on the machine rather than on the call so a
//!     boot and every call after it accumulate into one picture.

const std = @import("std");
const system = @import("system.zig");
const cart_mod = @import("cart.zig");
const cpu_mod = @import("cpu.zig");
const probe = @import("probe.zig");

pub const Error = system.Error || std.mem.Allocator.Error;

/// A return address the game never uses, pushed so a call can tell "the
/// routine finished" from "it is still going". Shared with `probe.zig` rather
/// than re-chosen: two different sentinels would be two different things to
/// reason about, and $0001 is already argued for there.
pub const sentinel: u16 = probe.sentinel;

/// Cartridge RAM size for a 256 KiB MBC1 cart. The machine owns it, so two
/// harnesses cannot share save RAM and start each other's runs.
pub const ram_size: usize = 0x2000;

/// Long enough to tap through the title and the file select and be standing in
/// the first room. `probe.runDoors` uses 30 seconds for the same reason and
/// found it sufficient across all 512 doors.
pub const boot_seconds_default: usize = 30;

/// Every instruction start, with the bank it was fetched from. `bank` is the
/// bank mapped over the address, so a PC below $4000 reports the low bank
/// (normally 0) and one above reports the high bank.
pub const ExecWatch = struct {
    ctx: *anyopaque,
    hit: *const fn (ctx: *anyopaque, bank: usize, pc: u16) void,
};

pub const Regs = struct {
    a: ?u8 = null,
    b: ?u8 = null,
    c: ?u8 = null,
    d: ?u8 = null,
    e: ?u8 = null,
    h: ?u8 = null,
    l: ?u8 = null,
    /// Set the flag byte wholesale. Rarely wanted; present because a routine
    /// that branches on carry on entry cannot be tested without it.
    f: ?cpu_mod.Flags = null,
};

pub const Write = struct { addr: u16, value: u8 };

pub const Call = struct {
    /// Bank to map at $4000-$7FFF before the call. Null leaves whatever the
    /// machine had, which is what a bank-0 routine wants.
    bank: ?u8 = null,
    addr: u16,
    regs: Regs = .{},
    /// Applied in order, after the bank switch and before the call. Bus
    /// writes, so an address in the cartridge range banks rather than storing.
    writes: []const Write = &.{},
    /// Instruction budget. A routine that has not returned inside it is
    /// reported as unfinished rather than waited on.
    budget: usize = 4_000_000,
    /// Leave IME as the booted machine had it. Default false: a unit test
    /// wants the routine, not the routine plus whatever vblank ran through it.
    interrupts: bool = false,
};

pub const Outcome = struct {
    /// PC came back to the sentinel, rather than the budget running out.
    returned: bool,
    instructions: usize,
    a: u8,
    f: cpu_mod.Flags,
    b: u8,
    c: u8,
    d: u8,
    e: u8,
    h: u8,
    l: u8,
    sp: u16,
    /// Where the routine ended -- the sentinel when it returned, or wherever it
    /// was when the budget ran out. **Not** where the machine will resume: a
    /// call that returned puts PC back where it was, so the machine can keep
    /// running afterwards.
    pc: u16,
    /// The bank mapped at $4000 when the routine returned. A routine that
    /// switches banks and does not switch back is visible here.
    high_bank: usize,

    pub fn bc(self: Outcome) u16 {
        return (@as(u16, self.b) << 8) | self.c;
    }
    pub fn de(self: Outcome) u16 {
        return (@as(u16, self.d) << 8) | self.e;
    }
    pub fn hl(self: Outcome) u16 {
        return (@as(u16, self.h) << 8) | self.l;
    }
};

/// A copy of the whole machine. The `System` is a value type apart from
/// cartridge RAM, which is a slice the machine owns, so a snapshot is a copy
/// of both.
pub const Snapshot = struct {
    sys: system.System,
    ram: []u8,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.ram);
        self.ram = &.{};
    }
};

pub const Machine = struct {
    sys: system.System,
    ram: []u8,
    allocator: std.mem.Allocator,
    exec: ?ExecWatch = null,
    /// Frames stepped during `boot`, so a caller can report how far it got.
    booted_frames: u64 = 0,

    pub fn deinit(self: *Machine) void {
        self.allocator.free(self.ram);
        self.ram = &.{};
    }

    pub fn snapshot(self: *const Machine) !Snapshot {
        return .{ .sys = self.sys, .ram = try self.allocator.dupe(u8, self.ram) };
    }

    /// The snapshot may be another machine's (the crawl's workers restore
    /// rooms other workers walked into), and its cartridge's RAM slice is that
    /// machine's buffer: so it is pointed back at this one's.
    pub fn restore(self: *Machine, snap: Snapshot) void {
        self.sys = snap.sys;
        self.sys.bus.cart.ram = self.ram;
        @memcpy(self.ram, snap.ram);
    }

    /// A machine of its own in the state `snap` holds.
    pub fn fromSnapshot(allocator: std.mem.Allocator, snap: Snapshot) !Machine {
        var m: Machine = .{ .sys = snap.sys, .ram = try allocator.alloc(u8, snap.ram.len), .allocator = allocator };
        m.restore(snap);
        return m;
    }

    /// One instruction, offering its start to the execution watch first.
    fn stepWatched(self: *Machine) system.Error!bool {
        if (self.exec) |w| {
            const pc = self.sys.cpu.pc;
            const bank = if (pc < 0x4000) self.sys.bus.cart.lowBank() else self.sys.bus.cart.highBank();
            w.hit(w.ctx, bank, pc);
        }
        return self.sys.step();
    }

    /// `*Machine`, not `*const`: a bus read fires the read watch, so it is not
    /// a const operation on the machine even though it does not change state.
    pub fn read(self: *Machine, addr: u16) u8 {
        return self.sys.bus.read(addr);
    }

    pub fn write(self: *Machine, addr: u16, v: u8) void {
        self.sys.bus.write(addr, v);
    }

    pub fn readWord(self: *Machine, addr: u16) u16 {
        return @as(u16, self.sys.bus.read(addr)) | (@as(u16, self.sys.bus.read(addr +% 1)) << 8);
    }

    pub fn writeWord(self: *Machine, addr: u16, v: u16) void {
        self.sys.bus.write(addr, @truncate(v));
        self.sys.bus.write(addr +% 1, @truncate(v >> 8));
    }

    /// Map `bank` at $4000-$7FFF. Written through the bus so the cartridge's
    /// own register semantics apply -- MBC1's "bank 0 reads as bank 1", the
    /// two high bits at $4000 -- rather than reaching into the mapper.
    pub fn setBank(self: *Machine, bank: u8) void {
        self.sys.bus.write(0x2000, bank & 0x1F);
        self.sys.bus.write(0x4000, (bank >> 5) & 0x03);
    }

    /// Instructions a run is allowed per frame it asks for, plus a floor.
    ///
    /// A frame is about 17 000 instructions; this is an order of magnitude of
    /// slack, and exists only so a machine that has stopped completing frames
    /// stops the run instead of hanging it.
    pub const instructions_per_frame_cap: u64 = 200_000;

    /// Step until `count` more frames have completed, with input chosen per
    /// frame. The frame index handed to `keys` is relative to this call, so a
    /// schedule reads the same whether it runs first or after a boot.
    ///
    /// Stepping *instructions* under a frame-count condition, rather than
    /// calling `stepFrame` per frame, is `probe.watchDoorScripts`'s shape and
    /// the reason is worth stating: **Metroid II turns the LCD off** during a
    /// screen transition, and while it is off no frame ever completes. A loop
    /// that waits for each frame in turn treats that as the machine having
    /// died and stops -- which it did, at 2664 frames every time, no matter how
    /// long a schedule it was given, and quietly cost the ledger every routine
    /// that runs after the first transition.
    pub fn runScript(
        self: *Machine,
        count: u64,
        ctx: *anyopaque,
        keys: *const fn (ctx: *anyopaque, frame: u64) probe.Buttons,
    ) !u64 {
        return self.runScriptFrom(count, 0, ctx, keys);
    }

    /// `runScript` with the schedule's frame index starting at `first_frame`
    /// rather than at zero.
    ///
    /// Needed by any caller that runs one schedule in several pieces -- the
    /// ledger samples game state between chunks. Without it each piece restarts
    /// the schedule from frame 0, so a 24-frame held input becomes a 30-frame
    /// stutter of the same first input, and the run never gets anywhere: the
    /// first version of the ledger's sampling did exactly that and took the
    /// machine from standing in a room to sitting on the title screen.
    pub fn runScriptFrom(
        self: *Machine,
        count: u64,
        first_frame: u64,
        ctx: *anyopaque,
        keys: *const fn (ctx: *anyopaque, frame: u64) probe.Buttons,
    ) !u64 {
        const start = self.sys.frames;
        const cap = count * instructions_per_frame_cap + 1_000_000;
        var guard: u64 = 0;
        while (self.sys.frames - start < count and guard < cap) : (guard += 1) {
            _ = try self.stepWatched();
            const b = keys(ctx, first_frame + (self.sys.frames - start));
            self.sys.bus.setKeys(b.dpad, b.buttons);
        }
        return self.sys.frames - start;
    }

    const FixedKeys = struct {
        b: probe.Buttons,

        fn get(ctx: *anyopaque, _: u64) probe.Buttons {
            const self: *FixedKeys = @ptrCast(@alignCast(ctx));
            return self.b;
        }
    };

    /// Step `count` frames with one input held throughout.
    pub fn runFrames(self: *Machine, count: u64, keys: probe.Buttons) !u64 {
        var fixed: FixedKeys = .{ .b = keys };
        return self.runScript(count, &fixed, FixedKeys.get);
    }

    /// Set up state, call a routine, and report registers and where it ended.
    ///
    /// The caller reads memory back through `read`; nothing is snapshotted for
    /// it, because "what changed" is a question only the caller knows the shape
    /// of, and copying 8 KiB of WRAM per call to answer it generically would
    /// dominate the ledger's runtime.
    pub fn call(self: *Machine, c: Call) !Outcome {
        if (c.bank) |b| self.setBank(b);
        const cpu = &self.sys.cpu;
        if (c.regs.a) |v| cpu.a = v;
        if (c.regs.b) |v| cpu.b = v;
        if (c.regs.c) |v| cpu.c = v;
        if (c.regs.d) |v| cpu.d = v;
        if (c.regs.e) |v| cpu.e = v;
        if (c.regs.h) |v| cpu.h = v;
        if (c.regs.l) |v| cpu.l = v;
        if (c.regs.f) |v| cpu.f = v;
        for (c.writes) |w| self.sys.bus.write(w.addr, w.value);

        if (!c.interrupts) {
            cpu.ime = false;
            cpu.ime_delay = 0;
        }
        // HALT waiting for an interrupt that will never arrive would burn the
        // whole budget; a routine called out of context has no reason to be
        // halted on entry.
        cpu.halted = false;

        // Where the machine was, so it can be put back. `probe.runDoors` never
        // needed this -- it reads state out of the machine and throws it away --
        // but anything that runs *frames* after a call does, and the failure is
        // spectacular rather than subtle: the sentinel $0001 is the second byte
        // of the `JP $01FB` at the RST 0 vector, so resuming from it executes
        // `EI` and then reads a garbage operand, and a few frames later the
        // game has soft-reset and cleared WRAM. A room harness that spawned
        // Samus perfectly and found her gone five frames later was this.
        const resume_pc = cpu.pc;

        cpu.sp -%= 2;
        self.sys.bus.write(cpu.sp, @truncate(sentinel));
        self.sys.bus.write(cpu.sp +% 1, @truncate(sentinel >> 8));
        cpu.pc = c.addr;

        var n: usize = 0;
        var returned = false;
        while (n < c.budget) : (n += 1) {
            if (self.sys.cpu.pc == sentinel) {
                returned = true;
                break;
            }
            _ = try self.stepWatched();
        }

        // A routine that returned popped the sentinel on its way out, so SP is
        // already back where it started and only PC needs putting back. One
        // that ran out of budget is left exactly where it stopped: the caller
        // is told `returned == false`, and moving a stuck machine's PC would
        // hide where it got stuck.
        const ended_at = cpu.pc;
        if (returned) cpu.pc = resume_pc;

        return .{
            .returned = returned,
            .instructions = n,
            .a = cpu.a,
            .f = cpu.f,
            .b = cpu.b,
            .c = cpu.c,
            .d = cpu.d,
            .e = cpu.e,
            .h = cpu.h,
            .l = cpu.l,
            .sp = cpu.sp,
            .pc = ended_at,
            .high_bank = self.sys.bus.cart.highBank(),
        };
    }
};

/// Boot the retail ROM and leave it standing in the first room.
///
/// `ram` is allocated here rather than taken, because a caller that reused one
/// buffer across two machines would have the second run start from the first
/// one's save state -- the exact bug `trace.capture` documents avoiding.
pub fn boot(allocator: std.mem.Allocator, rom: []const u8, seconds: usize) Error!Machine {
    const ram = try allocator.alloc(u8, ram_size);
    errdefer allocator.free(ram);
    @memset(ram, 0);

    var m: Machine = .{
        .sys = try system.System.init(rom, ram),
        .ram = ram,
        .allocator = allocator,
    };

    _ = try m.runScript(seconds * 60, &m, bootKeys);
    m.booted_frames = m.sys.frames;
    return m;
}

/// A machine at frame zero, optionally with a DMG boot ROM mapped over the
/// bottom page instead of the post-boot register values.
///
/// `boot(.., 0)` and `bootFrom(.., null)` are the same machine. The boot-ROM
/// form exists for `tas.zig`: a recorded movie's frame zero is whatever its
/// emulator called frame zero, and if that emulator ran a boot ROM then the
/// movie's first sixty-odd frames are the scrolling logo. Replaying it from
/// $0100 shifts the whole input stream earlier by that much.
pub fn bootFrom(allocator: std.mem.Allocator, rom: []const u8, boot_rom: ?[]const u8) Error!Machine {
    const ram = try allocator.alloc(u8, ram_size);
    errdefer allocator.free(ram);
    @memset(ram, 0);
    return .{
        .sys = if (boot_rom) |b|
            try system.System.initWithBoot(rom, ram, b)
        else
            try system.System.init(rom, ram),
        .ram = ram,
        .allocator = allocator,
    };
}

fn bootKeys(_: *anyopaque, frame: u64) probe.Buttons {
    return probe.bootButtons(@intCast(frame));
}

/// Whether the machine looks like a live game rather than a crashed one.
///
/// The same shape of claim `trace.Trace.alive` makes, and for the same reason:
/// every call below is worthless if the machine it starts from is spinning in
/// a loop having died on the title screen.
pub fn alive(m: *const Machine) bool {
    if (!m.sys.bus.lcd.enabled()) return false;
    var vram_nonzero: usize = 0;
    for (m.sys.bus.vram) |b| vram_nonzero += @intFromBool(b != 0);
    return vram_nonzero > 1000 and m.sys.instructions > 1_000_000;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

/// A cartridge whose reset vector spins, with a handful of routines placed at
/// known addresses. Synthetic rather than the retail ROM, so this file's tests
/// run without one.
fn fixtureRom(allocator: std.mem.Allocator) ![]u8 {
    const rom = try allocator.alloc(u8, 4 * cart_mod.bank_size);
    @memset(rom, 0x00);
    rom[0x0147] = 0x01; // MBC1
    // $0100: JR -2, so booting parks the machine without running off.
    rom[0x0100] = 0x18;
    rom[0x0101] = 0xFE;

    // $0200: A = A + 1; RET
    rom[0x0200] = 0x3C; // INC A
    rom[0x0201] = 0xC9; // RET

    // $0210: write $5A to $C000; RET
    rom[0x0210] = 0x3E; // LD A,$5A
    rom[0x0211] = 0x5A;
    rom[0x0212] = 0xEA; // LD ($C000),A
    rom[0x0213] = 0x00;
    rom[0x0214] = 0xC0;
    rom[0x0215] = 0xC9; // RET

    // $0220: never returns -- JR -2.
    rom[0x0220] = 0x18;
    rom[0x0221] = 0xFE;

    // In each high bank, $4000 loads the bank number into A and returns, so a
    // call can prove which bank it ran in.
    for (1..4) |b| {
        const base = b * cart_mod.bank_size;
        rom[base + 0] = 0x3E; // LD A,imm
        rom[base + 1] = @intCast(b);
        rom[base + 2] = 0xC9; // RET
    }
    return rom;
}

fn bootFixture(allocator: std.mem.Allocator) !Machine {
    const rom = try fixtureRom(allocator);
    // The fixture never enables the LCD, so `boot`'s frame loop would spin;
    // build the machine directly instead of booting it.
    const ram = try allocator.alloc(u8, ram_size);
    @memset(ram, 0);
    return .{
        .sys = try system.System.init(rom, ram),
        .ram = ram,
        .allocator = allocator,
    };
}

fn freeFixture(allocator: std.mem.Allocator, m: *Machine) void {
    allocator.free(m.sys.bus.cart.rom);
    m.deinit();
}

test "a call runs the routine and comes back at the sentinel" {
    const a = testing.allocator;
    var m = try bootFixture(a);
    defer freeFixture(a, &m);

    const out = try m.call(.{ .addr = 0x0200, .regs = .{ .a = 0x41 } });
    try testing.expect(out.returned);
    try testing.expectEqual(@as(u8, 0x42), out.a);
    // Two instructions retired, and PC parked on the sentinel rather than
    // wherever the routine's RET happened to land.
    try testing.expectEqual(@as(usize, 2), out.instructions);
    try testing.expectEqual(sentinel, out.pc);
}

test "a routine that never returns is reported unfinished, not waited on" {
    const a = testing.allocator;
    var m = try bootFixture(a);
    defer freeFixture(a, &m);

    const out = try m.call(.{ .addr = 0x0220, .budget = 500 });
    try testing.expect(!out.returned);
    try testing.expectEqual(@as(usize, 500), out.instructions);
}

test "memory a routine wrote is readable afterwards" {
    const a = testing.allocator;
    var m = try bootFixture(a);
    defer freeFixture(a, &m);

    try testing.expectEqual(@as(u8, 0x00), m.read(0xC000));
    const out = try m.call(.{ .addr = 0x0210 });
    try testing.expect(out.returned);
    try testing.expectEqual(@as(u8, 0x5A), m.read(0xC000));
}

test "a snapshot puts the machine back, WRAM and all" {
    const a = testing.allocator;
    var m = try bootFixture(a);
    defer freeFixture(a, &m);

    var snap = try m.snapshot();
    defer snap.deinit(a);

    _ = try m.call(.{ .addr = 0x0210 });
    try testing.expectEqual(@as(u8, 0x5A), m.read(0xC000));

    m.restore(snap);
    try testing.expectEqual(@as(u8, 0x00), m.read(0xC000));
    // And a second call from the restored state does the same thing again,
    // which is the property the ledger's per-door sweep depends on.
    _ = try m.call(.{ .addr = 0x0210 });
    try testing.expectEqual(@as(u8, 0x5A), m.read(0xC000));
}

test "a snapshot restored on another machine writes that machine's cartridge RAM" {
    const a = testing.allocator;
    var m = try bootFixture(a);
    defer freeFixture(a, &m);
    m.write(0x0000, 0x0A); // RAM on
    m.write(0xA000, 0x11);
    var snap = try m.snapshot();
    defer snap.deinit(a);

    var other = try Machine.fromSnapshot(a, snap);
    defer other.deinit();
    try testing.expectEqual(@as(u8, 0x11), other.read(0xA000));
    other.write(0xA000, 0x22);
    try testing.expectEqual(@as(u8, 0x11), m.ram[0]);
    try testing.expectEqual(@as(u8, 0x22), other.ram[0]);
    // And once more through `restore` onto a machine that already has state.
    other.restore(snap);
    other.write(0xA000, 0x33);
    try testing.expectEqual(@as(u8, 0x11), m.ram[0]);
}

test "the bank a call names is the bank it runs in" {
    const a = testing.allocator;
    var m = try bootFixture(a);
    defer freeFixture(a, &m);

    for (1..4) |b| {
        const out = try m.call(.{ .bank = @intCast(b), .addr = 0x4000 });
        try testing.expect(out.returned);
        try testing.expectEqual(@as(u8, @intCast(b)), out.a);
        try testing.expectEqual(b, out.high_bank);
    }
}

const CountWatch = struct {
    hits: usize = 0,
    banks: [16]usize = @splat(0),

    fn hit(ctx: *anyopaque, bank: usize, _: u16) void {
        const self: *CountWatch = @ptrCast(@alignCast(ctx));
        self.hits += 1;
        if (bank < self.banks.len) self.banks[bank] += 1;
    }
};

test "the execution watch sees every instruction start, with its bank" {
    const a = testing.allocator;
    var m = try bootFixture(a);
    defer freeFixture(a, &m);

    var w: CountWatch = .{};
    m.exec = .{ .ctx = &w, .hit = CountWatch.hit };

    _ = try m.call(.{ .addr = 0x0200 });
    try testing.expectEqual(@as(usize, 2), w.hits);
    try testing.expectEqual(@as(usize, 2), w.banks[0]);

    _ = try m.call(.{ .bank = 2, .addr = 0x4000 });
    // Two more instructions, both fetched from bank 2's window.
    try testing.expectEqual(@as(usize, 4), w.hits);
    try testing.expectEqual(@as(usize, 2), w.banks[2]);
}

test "interrupts are off inside a call unless the call asks for them" {
    const a = testing.allocator;
    var m = try bootFixture(a);
    defer freeFixture(a, &m);

    m.sys.cpu.ime = true;
    _ = try m.call(.{ .addr = 0x0200 });
    try testing.expect(!m.sys.cpu.ime);

    m.sys.cpu.ime = true;
    _ = try m.call(.{ .addr = 0x0200, .interrupts = true });
    try testing.expect(m.sys.cpu.ime);
}
