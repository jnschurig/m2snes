//! Which routine owns a Game Boy address, answered by watching the game play.
//!
//! **Why this exists.** `correspond.zig` refuses to write down a single SNES
//! address: every pair names an `engine.sym` label, and a missing label is a
//! build error, specifically so the two sides of the map cannot drift. The Game
//! Boy side was hand-typed hex with a comment on it. Half the map was checked
//! by construction and the other half was a guess, and Step 15 spent three
//! sessions on a bug that lived in the unchecked half: `VarSamusY` was paired
//! with $FFC8, which is not Samus. The Y rung of a 320-frame comparator was
//! comparing a constant against a constant, and the port was blamed twice.
//!
//! The inference that produced it was drawn from *initialisation* code. The
//! `WARP` handler writes the screen number to two places -- `LDH ($C9),A` then
//! `LDH ($C1),A` -- so the two quads look like copies of each other. They agree
//! at the instant of a transition and diverge on the next frame of play. One
//! frame of walking falsifies it; nobody ran that frame, because the reference
//! had no ground truth of its own.
//!
//! **So this is the obligation the Game Boy side was missing.** A pair does not
//! name an address and explain itself in prose; it names the *routine that owns
//! the address*, and the claim is checked by running the game and watching who
//! writes what. A routine's body is not hand-written either: `disasm.trace`
//! follows control flow from the entry point and stops at `RET`, so the body is
//! whatever the cartridge says it is.
//!
//! **And the ground truth is a published tool-assisted run**, not input we
//! invented. Forty thousand frames of somebody else playing the real game is
//! the one reference in this project that cannot have been shaped, however
//! unconsciously, to agree with the port. `observe` needs nothing from the SNES
//! side at all.
//!
//! Two questions, one observation:
//!
//!   - *Search.* "Which addresses does `samus_walkRight` write?" names
//!     $FFC2/$FFC3 without anybody having to already know them.
//!   - *Falsification.* "Is $FFCA written by `samus_walkRight`?" is a run, not
//!     a re-reading. It answers no.

const std = @import("std");
const harness = @import("gb/harness.zig");
const disasm = @import("gb/disasm.zig");
const bus_mod = @import("gb/bus.zig");
const lcd_mod = @import("gb/lcd.zig");
const tas = @import("tas.zig");

pub const Error = error{ TooManyRoutines, EntryNotReached };

/// A routine, named by its entry point only.
///
/// The body is derived, not declared: writing `lo` and `hi` by hand would put
/// the same class of guess back that this module exists to remove. Every entry
/// below is an address some other file in this repository already reaches
/// through the disassembler.
pub const Routine = struct {
    name: []const u8,
    /// Bank 0 only. Every routine that owns a physics variable lives there,
    /// and a banked entry would need the mapper state at write time to
    /// attribute correctly -- worth adding when something needs it, not before.
    entry: u16,
    note: []const u8 = "",
};

/// The routines whose variables the correspondence map cares about.
///
/// `zig build disasm -- 0 <entry> <end> <entry>` prints any of them.
pub const routines = [_]Routine{
    .{
        .name = "samus_walkRight",
        .entry = 0x1C0D,
        .note = "Reads the X pixel, adds the walk speed, stores it back and carries into the screen nibble with `AND $0F`. Whatever it stores is Samus's X by definition.",
    },
    .{
        .name = "samus_walkLeft",
        .entry = 0x1C51,
        .note = "The mirror of `samus_walkRight`, reached from the same pose handler; it subtracts where the other adds.",
    },
    .{
        .name = "samus_moveVertical",
        .entry = 0x1D4E,
        .note = "One routine for both directions: `BIT 7,A` on the signed delta picks the descending path at $1D4E or the ascending one at $1D96, and each reads the Y pixel, applies the delta, stores it back and carries into the screen nibble. Found by asking which PCs wrote $FFC0 over a replay, not by recognising a label.",
    },
    .{
        .name = "collision_samusHorizontal",
        .entry = 0x1DD6,
        .note = "Samples the tilemap at the pose's y-offsets. The address it reads its base from has to be the address the walk routine wrote, or the physics is testing somewhere Samus is not.",
    },
    .{
        .name = "collision_samusBottom",
        .entry = 0x1F0F,
        .note = "The downward probe, at `+$0C`/`+$14` horizontally and `+$2C` vertically.",
    },
    .{
        .name = "camera_update",
        .entry = 0x08FE,
        .note = "The camera. Builds a cell index out of $FFC9 and $FFCB, looks that screen's scroll flags up in the table at $4200, and at 0:$0949 adds `$D035` -- the speed `samus_walkRight` left at 0:$1C4D -- into $FFCA. Here because the camera pair was mis-addressed for the same reason Samus's was: an address the *renderer* reads is not thereby the variable the game maintains.",
    },
    .{
        .name = "warpHandler",
        .entry = 0x28FB,
        .note = "The door script's `WARP`. It writes *both* position quads, which is exactly why watching only this routine is what produced the wrong answer -- it is here so the report shows that overlap rather than hiding it.",
    },
};

/// The instructions belonging to a routine, and **only** to that routine.
///
/// `disasm.trace` descends into `CALL` targets, which is right for a coverage
/// question and wrong for an ownership one: traced that way, `samus_walkRight`
/// "writes" $C203 because sixteen calls down it reaches the tile sampler, and
/// every physics routine comes out owning the same four hundred bytes. This is
/// the same traversal with the descent removed -- both arms of a conditional,
/// past a `CALL` to the instruction after it, stopping at `RET` -- so what a
/// routine writes is what its own instructions store.
fn body(allocator: std.mem.Allocator, code: []const u8, entry: u16) !std.DynamicBitSetUnmanaged {
    var out = try std.DynamicBitSetUnmanaged.initEmpty(allocator, code.len);
    errdefer out.deinit(allocator);

    var work: std.ArrayList(u16) = .empty;
    defer work.deinit(allocator);
    try work.append(allocator, entry);

    while (work.pop()) |addr| {
        if (addr >= code.len) continue;
        if (out.isSet(addr)) continue;
        const insn = disasm.decode(code[addr..], addr);
        out.set(addr);
        const next = addr +% insn.len;
        switch (insn.flow) {
            .next => try work.append(allocator, next),
            .jump => |t| try work.append(allocator, t),
            .branch => |t| {
                try work.append(allocator, t);
                try work.append(allocator, next);
            },
            // Past the call, never into it. The callee is somebody else's body.
            .call, .call_cc => try work.append(allocator, next),
            .ret_cc => try work.append(allocator, next),
            .ret, .indirect, .stop, .illegal => {},
        }
    }
    return out;
}

/// Addresses worth attributing. VRAM and OAM are excluded: they are the
/// picture, and nothing in the correspondence map lives there.
fn watched(addr: u16) bool {
    return (addr >= 0xC000 and addr <= 0xDFFF) or (addr >= 0xFF80 and addr <= 0xFFFE);
}

pub const Observation = struct {
    allocator: std.mem.Allocator,
    /// Bit `r` set means routine `r` wrote this address at least once.
    by_addr: []u32,
    /// Total writes per address, over every routine and none.
    counts: []u32,
    /// Instructions in each routine's own body, so a routine whose entry was
    /// mistyped shows up as a body of almost nothing rather than as a silent
    /// zero-write result.
    body_bytes: [routines.len]usize,
    /// Instructions executed inside each routine's body.
    ///
    /// **A routine that never ran and a routine that ran and wrote nothing are
    /// different answers**, and conflating them is the same mistake in a new
    /// place: "no evidence it writes this" would otherwise be reported as
    /// "evidence it does not". Anything asserting a negative has to check this
    /// first.
    execs: [routines.len]u64,
    /// Machine frames the replay actually ran.
    frames: usize,
    /// One entry per `Options.trace_writers` address, in the same order.
    writers: []Writers,

    pub fn deinit(self: *Observation) void {
        self.allocator.free(self.by_addr);
        self.allocator.free(self.counts);
        self.allocator.free(self.writers);
    }

    pub fn wroteTo(self: Observation, routine_index: usize, addr: u16) bool {
        return self.by_addr[addr] & (@as(u32, 1) << @intCast(routine_index)) != 0;
    }

    /// Every address a routine wrote, in address order. The caller owns it.
    pub fn addressesWrittenBy(self: Observation, allocator: std.mem.Allocator, routine_index: usize) ![]u16 {
        var out: std.ArrayList(u16) = .empty;
        errdefer out.deinit(allocator);
        for (0..0x10000) |a| {
            if (self.wroteTo(routine_index, @intCast(a))) try out.append(allocator, @intCast(a));
        }
        return out.toOwnedSlice(allocator);
    }

    /// Whether the replay actually got inside a routine at all.
    pub fn ran(self: Observation, routine_index: usize) bool {
        return self.execs[routine_index] > 0;
    }

    pub fn indexOf(name: []const u8) ?usize {
        for (routines, 0..) |r, i| {
            if (std.mem.eql(u8, r.name, name)) return i;
        }
        return null;
    }
};

const Watcher = struct {
    obs: *Observation,
    /// Which routines own each address in bank 0, one mask per byte. Flattened
    /// from the per-routine bodies so both the write hook and the step loop
    /// cost a single array read rather than one bitset probe per routine.
    owners: []const u32,
    /// The PC of the instruction currently executing, kept the way
    /// `probe.watchDoorScripts` and `room.SaveLog` keep theirs.
    pc: u16 = 0,

    fn onWrite(ctx: *anyopaque, bus: *const bus_mod.Bus, addr: u16, _: u8) void {
        const self: *Watcher = @ptrCast(@alignCast(ctx));
        if (!watched(addr)) return;
        self.obs.counts[addr] +|= 1;
        for (self.obs.writers) |*w| {
            if (w.addr == addr) {
                const bank: u8 = if (self.pc < 0x4000) 0 else @intCast(bus.cart.highBank());
                w.note(self.pc, bank);
            }
        }
        // Bank 0 only: a PC above $3FFF is in whatever bank happens to be
        // mapped, and attributing it would need the mapper state.
        if (self.pc >= 0x4000) return;
        self.obs.by_addr[addr] |= self.owners[self.pc];
    }
};

/// Distinct writer PCs recorded per interesting address. Bounded so a variable
/// the whole game touches cannot grow the report without limit.
pub const max_writer_pcs: usize = 24;

/// Every PC that stored to one address, for a question the named routines do
/// not answer: "what *is* this byte?"
pub const Writers = struct {
    addr: u16,
    pcs: [max_writer_pcs]u16 = @splat(0),
    /// Bank mapped at the time, so a banked writer is not silently reported as
    /// a bank-0 address.
    banks: [max_writer_pcs]u8 = @splat(0),
    len: usize = 0,
    /// Distinct PCs beyond the cap, so a truncated list says so.
    dropped: usize = 0,

    fn note(self: *Writers, pc: u16, bank: u8) void {
        for (self.pcs[0..self.len], self.banks[0..self.len]) |p, b| {
            if (p == pc and b == bank) return;
        }
        if (self.len == max_writer_pcs) {
            self.dropped += 1;
            return;
        }
        self.pcs[self.len] = pc;
        self.banks[self.len] = bank;
        self.len += 1;
    }
};

pub const Options = struct {
    /// Addresses to record every writer PC for. Empty by default: this is the
    /// exploratory half, and it costs a linear scan per write.
    trace_writers: []const u16 = &.{},
    /// Machine frames to replay. The whole movie is 45 minutes; the physics
    /// variables are all exercised within the first minute of play, and a
    /// shorter run is what makes this cheap enough to sit in the gate.
    frames: usize = 3600,
    /// A DMG boot ROM, for the same frame-zero reason `tas.Options` has one.
    boot_rom: ?[]const u8 = null,
    input_offset: usize = tas.measured_input_offset,
};

/// Replay a published run and record who wrote what.
pub fn observe(
    allocator: std.mem.Allocator,
    rom: []const u8,
    movie: tas.Movie,
    opts: Options,
) !Observation {
    if (routines.len > 32) return Error.TooManyRoutines;
    try tas.checkAgainstRom(movie, rom);

    // Each routine's body, traced from its entry through the cartridge's own
    // control flow. `trace` follows both arms of a conditional, falls through a
    // `CALL` rather than descending into it, and stops at `RET` -- so what
    // comes back is this routine and not its callees.
    var bodies: [routines.len]std.DynamicBitSetUnmanaged = undefined;
    var made: usize = 0;
    errdefer for (0..made) |i| bodies[i].deinit(allocator);
    var body_bytes: [routines.len]usize = @splat(0);
    for (routines, 0..) |r, i| {
        bodies[i] = try body(allocator, rom[0..0x4000], r.entry);
        made += 1;
        body_bytes[i] = bodies[i].count();
        // A mistyped entry decodes as *something*, so "it traced" is not the
        // check. "It reached the instruction we named, and more than a handful
        // beyond it" is.
        if (!bodies[i].isSet(r.entry) or body_bytes[i] < 4) return Error.EntryNotReached;
    }
    defer for (0..routines.len) |i| bodies[i].deinit(allocator);

    const owners = try allocator.alloc(u32, 0x4000);
    defer allocator.free(owners);
    @memset(owners, 0);
    for (0..routines.len) |i| {
        var it = bodies[i].iterator(.{});
        while (it.next()) |pc| owners[pc] |= @as(u32, 1) << @intCast(i);
    }

    var obs: Observation = .{
        .allocator = allocator,
        .by_addr = try allocator.alloc(u32, 0x10000),
        .counts = try allocator.alloc(u32, 0x10000),
        .body_bytes = body_bytes,
        .execs = @splat(0),
        .frames = 0,
        .writers = try allocator.alloc(Writers, opts.trace_writers.len),
    };
    for (opts.trace_writers, 0..) |a, i| obs.writers[i] = .{ .addr = a };
    errdefer obs.deinit();
    @memset(obs.by_addr, 0);
    @memset(obs.counts, 0);

    var m = try harness.bootFrom(allocator, rom, opts.boot_rom);
    defer m.deinit();

    var w: Watcher = .{ .obs = &obs, .owners = owners };
    m.sys.bus.write_watch = .{ .ctx = &w, .write = Watcher.onWrite };
    defer m.sys.bus.write_watch = null;

    const limit = @min(opts.frames, movie.frames);
    var elapsed: usize = 0;
    var frame: usize = 0;
    var deadline = m.sys.cpu.cycles + 600 * lcd_mod.frame_cycles;

    m.sys.bus.setKeys(0xF, 0xF);
    while (frame < limit) {
        w.pc = m.sys.cpu.pc;
        if (w.pc < 0x4000) {
            var mask = owners[w.pc];
            while (mask != 0) {
                const i = @ctz(mask);
                obs.execs[i] += 1;
                mask &= mask - 1;
            }
        }
        const boundary = try m.sys.step();
        if (!boundary) {
            if (m.sys.cpu.cycles >= deadline) break;
            continue;
        }
        deadline = m.sys.cpu.cycles + 600 * lcd_mod.frame_cycles;
        elapsed += 1;
        if (elapsed < opts.input_offset) continue;
        const b = movie.input(frame).buttons();
        m.sys.bus.setKeys(b.dpad, b.buttons);
        frame += 1;
    }
    obs.frames = frame;
    return obs;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const build_options = @import("build_options");
const testrom = @import("testrom");

/// `std.debug.print`, but only when the survey was asked for.
///
/// **The dumps below are diagnostics, not verdicts, and they used to be
/// unconditional.** Anything a test binary writes to stderr makes `zig build
/// test` print a `failed command:` line under `--listen=-` even though the test
/// passed and the step exits 0 -- and on 2026-09-02 three genuinely failing
/// tests sat in the middle of that noise and were read as pre-existing. So they
/// are off unless asked for: `zig build test -Dsurvey`, or `M2_SURVEY=1 zig
/// build test`. See `docs/bug_tracker.md`.
///
/// A build option rather than an env var read here, because Zig 0.16 hands the
/// environment to `main` and a test binary's `main` is the test runner's -- the
/// build script is the only side that can still see it. The cost is that
/// toggling it rebuilds; the surveys are run for an answer, not in a loop.
fn survey(comptime fmt: []const u8, args: anytype) void {
    if (build_options.survey) std.debug.print(fmt, args);
}

fn loadMovie(allocator: std.mem.Allocator) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        tas.any_percent,
        allocator,
        .limited(64 << 20),
    ) catch null;
}

test "every routine's body is traced from its entry, and reaches it" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    for (routines) |r| {
        var listing = try disasm.trace(a, rom[0..0x4000], 0, &.{r.entry});
        defer listing.deinit(a);
        try testing.expect(listing.starts[r.entry]);
        // A routine is more than one instruction. This is what catches an
        // entry that lands mid-table and decodes as a single `RET`.
        var reached: usize = 0;
        for (listing.starts) |s| reached += @intFromBool(s);
        try testing.expect(reached > 4);
    }
}

test "the walk routine names Samus's X, and it is not the pair we were grading" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = try loadMovie(a) orelse return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try tas.parse(bytes);

    var obs = try observe(a, rom, movie, .{});
    defer obs.deinit();
    try testing.expect(obs.frames > 1000);

    // The search, stated as the question rather than as the answer: which
    // addresses does the routine that moves Samus right actually write?
    const walk = Observation.indexOf("samus_walkRight").?;
    const wrote = try obs.addressesWrittenBy(a, walk);
    defer a.free(wrote);

    survey("\n{d} frames replayed\n", .{obs.frames});
    for (routines, 0..) |r, i| {
        const w = try obs.addressesWrittenBy(a, i);
        defer a.free(w);
        survey("  {s}: {d} instructions, {d} executed, writes:", .{
            r.name, obs.body_bytes[i], obs.execs[i],
        });
        if (!obs.ran(i)) {
            survey(" (never reached -- says nothing either way)\n", .{});
            continue;
        }
        for (w) |addr| survey(" ${X:0>4}", .{addr});
        survey("\n", .{});
    }

    // What the map had, and what it should have had.
    try testing.expect(obs.wroteTo(walk, 0xFFC2));
    try testing.expect(obs.wroteTo(walk, 0xFFC3));
    try testing.expect(!obs.wroteTo(walk, 0xFFCA));
    try testing.expect(!obs.wroteTo(walk, 0xFFCB));
}

test "what the position quads are, asked of the machine rather than of a comment" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = try loadMovie(a) orelse return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try tas.parse(bytes);

    // The eight bytes the correspondence map has been choosing between.
    const quads = [_]u16{ 0xFFC0, 0xFFC1, 0xFFC2, 0xFFC3, 0xFFC8, 0xFFC9, 0xFFCA, 0xFFCB };
    var obs = try observe(a, rom, movie, .{ .trace_writers = &quads });
    defer obs.deinit();

    survey("\nwho writes the two position quads, over {d} frames:\n", .{obs.frames});
    for (obs.writers) |w| {
        survey("  ${X:0>4}: {d} writes from", .{ w.addr, obs.counts[w.addr] });
        for (w.pcs[0..w.len], w.banks[0..w.len]) |pc, b| survey(" {d}:${X:0>4}", .{ b, pc });
        if (w.dropped != 0) survey(" (+{d} more)", .{w.dropped});
        survey("\n", .{});
    }

    // **The survey's answer, asserted rather than printed.** Until 2026-09-05
    // this test had no assertion in it at all: it dumped the table and passed
    // unconditionally, which is the same shape of gap the module comment is
    // about -- a check that cannot fail. Gating the dump behind `M2_SURVEY`
    // would otherwise have left a test that does nothing at all by default.
    //
    // What the table says, and what the map had wrong: the two quads are owned
    // by different routines. The walk routines move $FFC2/$FFC3 and never touch
    // $FFC8-$FFCB; `camera_update` moves $FFC8-$FFCB and never touches
    // $FFC2/$FFC3. That is the falsification, so it is checked as one.
    const walk = Observation.indexOf("samus_walkRight").?;
    const camera = Observation.indexOf("camera_update").?;
    // A negative is only evidence if the routine ran at all. See `Observation.execs`.
    try testing.expect(obs.ran(walk));
    try testing.expect(obs.ran(camera));
    for ([_]u16{ 0xFFC2, 0xFFC3 }) |addr| {
        try testing.expect(obs.wroteTo(walk, addr));
        try testing.expect(!obs.wroteTo(camera, addr));
    }
    for ([_]u16{ 0xFFC8, 0xFFC9, 0xFFCA, 0xFFCB }) |addr| {
        try testing.expect(obs.wroteTo(camera, addr));
        try testing.expect(!obs.wroteTo(walk, addr));
    }
    // And every quad the survey asked about was written by somebody, so a
    // silent zero cannot be read as "nothing owns it".
    for (quads) |addr| try testing.expect(obs.counts[addr] > 0);
}
