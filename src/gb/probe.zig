//! Finding code by watching the game run.
//!
//! Step 7 needed one fact the map data does not carry: which tileset draws each
//! screen. Door scripts state it for the screens they warp to, so the pairing
//! reduces to "what does a `WARP` operand mean".
//!
//! Rather than transcribe a hand-labeled disassembly, this module finds code by
//! observation: register a `bus.ReadWatch`, run the retail ROM, and record the
//! program counter of every read that lands in a region of interest. What comes
//! out is a set of addresses with counts, which is where `gb/disasm.zig` starts
//! rather than an answer on its own. `01-requirements` calls for facts we can
//! stand behind independently of M2RoS's licensing, and an address our own
//! emulator watched the game read qualifies.
//!
//! Two corrections this module earned the hard way, both left visible because
//! the reasoning that produced them is the kind that repeats:
//!
//!  1. `watchDoorScripts` first filtered out reads whose PC was also inside the
//!     banked window, on the theory that bank 5 reading bank 5 could only be
//!     instruction fetch. That discarded most of the signal -- plenty of bank-5
//!     code reads bank-5 data. The fetch filter is now a three-byte window
//!     around PC, which is what "its own instruction" actually means.
//!  2. Watching alone was not enough. The exploration schedule never reaches a
//!     door, so the script region is never read no matter how long it runs, and
//!     the door-script interpreter turned out to be in bank 0 at $239C -- found
//!     by searching the ROM for the instruction that loads the pointer table's
//!     address, not by watching. `runDoors` below closes the loop: it calls the
//!     interpreter directly on a booted machine, which needs no input at all.

const std = @import("std");
const system = @import("system.zig");
const bus_mod = @import("bus.zig");
const cart_mod = @import("cart.zig");

/// Bank 5, $46E5-$55A3. Duplicated from `door.zig` rather than imported: this
/// module sits under `gb/`, which is the emulator and knows nothing about
/// Metroid II's data layout, and the one-line duplication is cheaper than the
/// dependency. door.zig's own test checks the four constants from the side
/// that can see both, so the duplication cannot drift unnoticed.
pub const door_bank: usize = 5;
pub const door_data_start: u16 = 0x46E5;
pub const door_data_end: u16 = 0x55A3;
pub const door_pointers_start: u16 = 0x42E5;

/// Fixed, so two runs of the probe produce the same findings.
pub const explore_seed: u64 = 0x4D32_5053_4E45_5300;

/// One program counter that read the watched region, and how often.
pub const Site = struct {
    pc: u16,
    /// True when this site was itself executing from the banked window -- that
    /// is, bank 5 reading bank 5. The first run of this probe assumed such a
    /// read could only be the interpreter fetching its own instructions and
    /// filtered it out, which discarded the answer: the door-script code lives
    /// in bank 5 alongside its data, not in bank 0.
    in_bank: bool,
    /// Bank mapped at $0000-$3FFF when it read. Almost always 0; recorded so
    /// that "the interpreter is in bank 0" is an observation and not a premise.
    low_bank: u8,
    reads: usize,
    /// The distinct addresses this site read, capped. A site that walks the
    /// whole script stream looks very different from one that reads a pointer.
    distinct: usize,
    first_addr: u16,
    last_addr: u16,
};

pub const Report = struct {
    sites: []Site,
    /// Reads inside the region whose PC was also inside it -- the interpreter
    /// executing from bank 5, if it ever does. Counted rather than assumed away.
    same_window: usize,
    /// Reads of the 512-entry pointer table, which is how a script is selected.
    pointer_reads: usize,
    /// Reads from the banked window, per bank.
    bank_reads: [32]usize,
    bank5_map: [64]usize,
    bank5_fine: [0x400]usize,
    frames: u64,
    instructions: u64,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.sites);
    }
};

const Key = struct { pc: u16, low_bank: u8 };

const Watcher = struct {
    /// Set by the run loop before each instruction, so a read can be attributed
    /// to the instruction that caused it.
    pc: u16 = 0,
    sites: std.AutoHashMap(Key, Acc),
    same_window: usize = 0,
    pointer_reads: usize = 0,
    /// Reads from $4000-$7FFF per mapped bank. Diagnostic: a run that records
    /// no door-script reads at all needs to say whether bank 5 was ever mapped,
    /// or whether the game simply never loaded a room.
    bank_reads: [32]usize = @splat(0),
    /// Where in bank 5 the reads land, in $100-byte buckets across $4000-$7FFF.
    bank5_map: [64]usize = @splat(0),
    bank5_fine: [0x400]usize = @splat(0),

    const Acc = struct {
        reads: usize = 0,
        first_addr: u16 = 0,
        last_addr: u16 = 0,
        /// A 256-bit set over `addr >> 6` within the region, which is enough to
        /// tell a stream walker from a single-address read without holding a
        /// hash set per site.
        seen: [4]u64 = @splat(0),

        fn note(self: *Acc, addr: u16) void {
            if (self.reads == 0) self.first_addr = addr;
            self.last_addr = addr;
            self.reads += 1;
            const slot: usize = (addr - 0x4000) >> 6;
            if (slot < 256) self.seen[slot >> 6] |= @as(u64, 1) << @intCast(slot & 63);
        }

        fn distinct(self: Acc) usize {
            var n: usize = 0;
            for (self.seen) |w| n += @popCount(w);
            return n;
        }
    };

    fn onRead(ctx: *anyopaque, bus: *const bus_mod.Bus, addr: u16, _: u8) void {
        const self: *Watcher = @ptrCast(@alignCast(ctx));
        if (addr < 0x4000 or addr > 0x7FFF) return;
        const hb = bus.cart.highBank();
        if (hb < self.bank_reads.len) self.bank_reads[hb] += 1;
        if (hb != door_bank) return;
        self.bank5_map[(addr - 0x4000) >> 8] += 1;
        if (addr < 0x4400) self.bank5_fine[addr - 0x4000] += 1;
        // Instruction fetch, not a data read. `bus.read` serves both, and the
        // first ranked run was topped by sites whose "reads" were their own
        // opcode and operand bytes -- PC equal to the address, spread of one.
        // An instruction is at most three bytes, and `pc` here is the address
        // it started at, so its own bytes are exactly this window. A data read
        // that happens to land on the instruction currently executing would be
        // lost too; self-modifying code in ROM is not a thing.
        if (addr >= self.pc and addr < self.pc +| 3) return;
        if (self.pc >= 0x4000) self.same_window += 1;
        if (addr >= door_pointers_start and addr < door_data_start) self.pointer_reads += 1;
        const key: Key = .{ .pc = self.pc, .low_bank = @intCast(bus.cart.lowBank()) };
        const e = self.sites.getOrPut(key) catch return;
        if (!e.found_existing) e.value_ptr.* = .{};
        e.value_ptr.note(addr);
    }
};

/// A deterministic exploration schedule.
///
/// Step 7's SameBoy comparison drives the game with SameBoy's own tester
/// schedule, which presses Start and A and *never touches the d-pad*. That is
/// right for grading frames -- it reaches a room and holds still -- and useless
/// here, because Samus never walks, so no door is ever traversed and no door
/// script ever runs. The first probe run recorded exactly that: bank 5 mapped
/// and read 20,136 times, and not one read inside the script region.
///
/// So this drives her instead: a held direction plus jump and shoot, re-rolled
/// every `hold_frames`, from a fixed-seed LCG. Deterministic by construction --
/// same seed, same inputs, same frames -- because a probe whose findings cannot
/// be reproduced is not evidence. It is a monkey, not a TAS: it explores enough
/// of the opening area to make the game load rooms, which is all this needs.
/// Step 14's TAS oracle is where directed input belongs.
pub const explore_hold_frames: usize = 24;

pub fn exploreButtons(frame: usize, seed: u64) Buttons {
    // The interval index, hashed. Splitmix64's finalizer, so consecutive
    // intervals do not produce correlated inputs the way a raw LCG state does.
    var z: u64 = seed +% (frame / explore_hold_frames) *% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z ^= z >> 31;

    var b: Buttons = .{};
    // One of right, left, down, or no direction. Up is deliberately excluded:
    // it aims the beam upward rather than moving her, so spending a quarter of
    // the schedule on it would just stand still.
    switch (@as(u2, @truncate(z))) {
        0 => b.dpad &= ~@as(u4, 0b0001), // right
        1 => b.dpad &= ~@as(u4, 0b0010), // left
        2 => b.dpad &= ~@as(u4, 0b1000), // down
        3 => {},
    }
    // Jump on three intervals in eight, shoot on half. Doors need shooting
    // open before they can be walked through, so B is not optional here.
    if (@as(u3, @truncate(z >> 2)) < 3) b.buttons &= ~@as(u4, 0b0001); // A
    if ((z >> 5) & 1 == 0) b.buttons &= ~@as(u4, 0b0010); // B
    // Start on one interval in sixteen, to get through the opening screens.
    if (@as(u4, @truncate(z >> 6)) == 0) b.buttons &= ~@as(u4, 0b1000);
    return b;
}

/// Active low, as the hardware reports them: bit 0 right/A, 1 left/B,
/// 2 up/select, 3 down/start. Declared here rather than imported from
/// `sameboy.zig`: this module is imported by `door.zig`'s cross-check, and
/// `sameboy.zig` pulls in `png` and `build_options`, which that test has no
/// reason to need.
pub const Buttons = struct {
    dpad: u4 = 0xF,
    buttons: u4 = 0xF,
};

/// Start, tapped every half second, to get past the title and the file select.
/// Only used for the opening seconds, before `exploreButtons` takes over.
pub fn bootButtons(frame: usize) Buttons {
    var b: Buttons = .{};
    if ((frame / 30) % 2 == 0) b.buttons &= ~@as(u4, 0b1000);
    return b;
}

/// Run the retail ROM for `seconds` and report every site that read the door
/// script region.
pub fn watchDoorScripts(
    allocator: std.mem.Allocator,
    rom: []const u8,
    boot: []const u8,
    seconds: usize,
) !Report {
    const ram = try allocator.alloc(u8, 0x2000);
    defer allocator.free(ram);
    @memset(ram, 0);

    var sys = try system.System.initWithBoot(rom, ram, boot);

    var w: Watcher = .{ .sites = std.AutoHashMap(Key, Watcher.Acc).init(allocator) };
    defer w.sites.deinit();
    sys.bus.read_watch = .{ .ctx = &w, .read = Watcher.onRead };

    // The opening seconds tap Start to get past the title and file select;
    // exploration takes over once the game is live.
    const boot_frames: usize = 120;
    const target = seconds * 60;
    var frame: usize = 0;
    while (frame < target) {
        w.pc = sys.cpu.pc;
        _ = try sys.step();
        if (sys.frames > frame) {
            frame = sys.frames;
            const b = if (frame < boot_frames)
                bootButtons(frame)
            else
                exploreButtons(frame - boot_frames, explore_seed);
            sys.bus.setKeys(b.dpad, b.buttons);
        }
    }

    var sites: std.ArrayList(Site) = .empty;
    errdefer sites.deinit(allocator);
    var it = w.sites.iterator();
    while (it.next()) |kv| {
        try sites.append(allocator, .{
            .pc = kv.key_ptr.pc,
            .in_bank = kv.key_ptr.pc >= 0x4000,
            .low_bank = kv.key_ptr.low_bank,
            .reads = kv.value_ptr.reads,
            .distinct = kv.value_ptr.distinct(),
            .first_addr = kv.value_ptr.first_addr,
            .last_addr = kv.value_ptr.last_addr,
        });
    }
    // Sorted by address so two runs report in the same order -- the whole
    // emulator exists to be deterministic, and a hash-map walk would undo it.
    std.mem.sort(Site, sites.items, {}, struct {
        fn lt(_: void, a: Site, b: Site) bool {
            return a.pc < b.pc;
        }
    }.lt);

    return .{
        .sites = try sites.toOwnedSlice(allocator),
        .same_window = w.same_window,
        .pointer_reads = w.pointer_reads,
        .bank_reads = w.bank_reads,
        .bank5_map = w.bank5_map,
        .bank5_fine = w.bank5_fine,
        .frames = sys.frames,
        .instructions = sys.instructions,
    };
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "the watch records in-bank reads, skips instruction fetches, and filters on bank" {
    // A synthetic run: no ROM needed. Every filter in `onRead` is one this
    // probe got wrong at least once, so each gets a case.
    var w: Watcher = .{ .sites = std.AutoHashMap(Key, Watcher.Acc).init(testing.allocator) };
    defer w.sites.deinit();

    var rom: [16 * cart_mod.bank_size]u8 = @splat(0);
    rom[0x0147] = 0x03; // MBC1+RAM+battery, as the retail cart declares
    rom[0x0148] = 0x03;
    rom[0x0149] = 0x02;
    var ram: [0x2000]u8 = @splat(0);
    const cart = try cart_mod.Cart.init(&rom, &ram);
    var bus = bus_mod.Bus.init(cart);

    bus.write(0x2000, door_bank);
    try testing.expectEqual(@as(usize, door_bank), bus.cart.highBank());

    // A read from the fixed bank into the banked window: recorded.
    w.pc = 0x1234;
    Watcher.onRead(&w, &bus, door_data_start, 0);
    try testing.expectEqual(@as(usize, 1), w.sites.count());

    // A read from *within* bank 5. This is the case the first version of this
    // probe threw away, on the theory that it could only be the interpreter
    // fetching its own instructions -- and throwing it away discarded the
    // answer, because Metroid II's door-script code lives in bank 5 beside its
    // data rather than in bank 0. It is recorded, and flagged.
    w.pc = 0x5000;
    Watcher.onRead(&w, &bus, door_data_start, 0);
    try testing.expectEqual(@as(usize, 2), w.sites.count());
    try testing.expectEqual(@as(usize, 1), w.same_window);

    // An instruction fetch: the address is the instruction's own bytes. Not a
    // data read, and before this was filtered the ranked output was nothing but
    // these -- every entry with PC equal to its address and a spread of one.
    const before = w.sites.count();
    // Deliberately past the pointer table, so this case cannot also perturb
    // the pointer-read count asserted at the end.
    // A PC not used above, so a new site is genuinely a new site, and past the
    // pointer table so this cannot perturb the pointer count asserted below.
    w.pc = 0x5100;
    Watcher.onRead(&w, &bus, 0x5100, 0); // opcode
    Watcher.onRead(&w, &bus, 0x5101, 0); // operand
    Watcher.onRead(&w, &bus, 0x5102, 0); // operand
    try testing.expectEqual(before, w.sites.count());
    // One byte past the instruction is a data read again.
    Watcher.onRead(&w, &bus, 0x5103, 0);
    try testing.expectEqual(before + 1, w.sites.count());

    // Right addresses, wrong bank: not the door data at all.
    bus.write(0x2000, 6);
    w.pc = 0x1234;
    const n = w.sites.count();
    Watcher.onRead(&w, &bus, door_data_start, 0);
    try testing.expectEqual(n, w.sites.count());

    // Outside the banked window entirely: WRAM, HRAM, IO.
    bus.write(0x2000, door_bank);
    Watcher.onRead(&w, &bus, 0xC000, 0);
    Watcher.onRead(&w, &bus, 0xFF40, 0);
    try testing.expectEqual(n, w.sites.count());

    // Pointer-table reads are counted apart from script-body reads.
    Watcher.onRead(&w, &bus, door_pointers_start, 0);
    try testing.expectEqual(@as(usize, 1), w.pointer_reads);
}

test "the exploration schedule moves, and is reproducible" {
    // The point of this schedule is the d-pad: SameBoy's tester schedule never
    // presses one, so Samus never walks, so no door script ever runs. That was
    // the first probe run's entire finding.
    var pressed_dpad: usize = 0;
    var pressed_b: usize = 0;
    var distinct = std.AutoHashMap(u8, void).init(testing.allocator);
    defer distinct.deinit();
    for (0..explore_hold_frames * 200) |f| {
        const b = exploreButtons(f, explore_seed);
        if (b.dpad != 0xF) pressed_dpad += 1;
        if (b.buttons & 0b0010 == 0) pressed_b += 1;
        try distinct.put((@as(u8, b.dpad) << 4) | b.buttons, {});
        // Same frame, same seed, same answer -- the run has to be repeatable.
        try testing.expectEqual(b.dpad, exploreButtons(f, explore_seed).dpad);
        try testing.expectEqual(b.buttons, exploreButtons(f, explore_seed).buttons);
    }
    // A direction is held most of the time, and the beam fires often enough to
    // open a door.
    try testing.expect(pressed_dpad * 2 > explore_hold_frames * 200);
    try testing.expect(pressed_b != 0);
    // And it is not one input repeated.
    try testing.expect(distinct.count() >= 8);
    // Input is held across a whole interval rather than re-rolled per frame.
    for (1..explore_hold_frames) |f| {
        try testing.expectEqual(exploreButtons(0, explore_seed).dpad, exploreButtons(f, explore_seed).dpad);
    }
}

test "a site distinguishes a stream walker from a single-address read" {
    var acc: Watcher.Acc = .{};
    acc.note(door_data_start);
    acc.note(door_data_start);
    acc.note(door_data_start);
    try testing.expectEqual(@as(usize, 3), acc.reads);
    try testing.expectEqual(@as(usize, 1), acc.distinct());

    var walker: Watcher.Acc = .{};
    var a: u16 = door_data_start;
    while (a < door_data_end) : (a += 1) walker.note(a);
    try testing.expect(walker.distinct() > 8);
    try testing.expectEqual(door_data_start, walker.first_addr);
}

// ---- Running one door script on demand ------------------------------------
//
// The exploration monkey never reaches a door, so the interpreter never runs
// on its own. But it does not have to be reached by walking: it is an ordinary
// subroutine that takes its argument in RAM, and a booted machine can be asked
// to execute it directly. That is what this does -- boot the game normally so
// every table, HRAM routine and shadow register is live, then for each door
// index in turn, restore that booted state, write the index where the
// interpreter reads it, and call it.
//
// The addresses below were read out of the ROM with `zig build disasm`, not
// taken from a labelled disassembly:
//
//   $239C  the door-script entry. Reads a 16-bit door index from $D08E/$D08F,
//          switches to bank 5, and indexes the 512-entry pointer table at
//          5:$42E5 to find the script.
//   $D00E  which way the door is being traversed. The interpreter's warp
//          handler dispatches on it (1, 2, 4, 8) and returns without loading
//          anything if it holds none of those.
//   $D058  where the warp's *bank* nibble is stored, and what gets written to
//          $2100 to map the map bank.
//   $FFC9 / $FFCB  the screen row and column of Samus's position, as written
//          by the warp handler at $28FB from the operand's two nibbles.
//
// What the run reports is not any of those, though: it is which entry of the
// map bank's screen-pointer table the engine actually read. That is the fact
// Step 7 needs, and it is an observation rather than a reading.

pub const interp_entry: u16 = 0x239C;
pub const door_index_addr: u16 = 0xD08E;
pub const door_direction_addr: u16 = 0xD00E;
pub const warp_bank_addr: u16 = 0xD058;
pub const screen_row_addr: u16 = 0xFFC9;
pub const screen_col_addr: u16 = 0xFFCB;
/// The low bytes of the same two positions -- Samus's offset *within* the
/// screen. The warp handler does not touch them, which is the door mechanic:
/// you keep your position within the screen and only the screen changes.
/// They matter here because the camera is derived from the full 12-bit
/// position (`-$74` in Y, `+$50` in X at $2939), so a large enough offset
/// borrows or carries into the screen number and the camera shows the
/// neighbouring screen. Being able to set them is what separates "the operand
/// names Samus's screen" from "the operand names the screen the camera drew".
pub const pos_y_low_addr: u16 = 0xFFC8;
pub const pos_x_low_addr: u16 = 0xFFCA;
/// Screen-pointer table, at $4000 of whichever map bank is mapped: 256
/// little-endian words, indexed by `row * 16 + col`.
pub const screen_table_start: u16 = 0x4000;
pub const screen_table_end: u16 = 0x4200;
pub const map_bank_first: usize = 0x9;
pub const map_bank_last: usize = 0xF;

/// A return address the game never uses, pushed so the run can tell "the
/// interpreter finished" from "it is still going". $0001 is inside the
/// cartridge header area's first restart vector and is never a call target;
/// the loop stops *before* executing there, so nothing is actually run.
pub const sentinel: u16 = 0x0001;

pub const DoorRun = struct {
    door: u16,
    /// The interpreter returned, rather than running out of budget.
    returned: bool,
    instructions: usize,
    /// $D058 after the run: the bank the warp handler selected.
    map_bank: u8,
    screen_row: u8,
    screen_col: u8,
    /// Screen-pointer table entries read during the run, in order, capped.
    /// Entry 0 is the screen the engine loaded first.
    cells: [8]u16,
    cell_count: usize,
    /// How many table reads there were in total, capped or not.
    total_cell_reads: usize,
    /// The background palette the room left in BGP. Reported rather than
    /// assumed, because the reference frames are rendered through it.
    bgp: u8,
};

const DoorWatcher = struct {
    cells: [8]u16 = @splat(0),
    count: usize = 0,
    total: usize = 0,

    fn onRead(ctx: *anyopaque, bus: *const bus_mod.Bus, addr: u16, _: u8) void {
        const self: *DoorWatcher = @ptrCast(@alignCast(ctx));
        if (addr < screen_table_start or addr >= screen_table_end) return;
        const hb = bus.cart.highBank();
        if (hb < map_bank_first or hb > map_bank_last) return;
        // Each entry is a word and the engine reads both halves; count the
        // low half only, so one lookup is one cell rather than two.
        if ((addr & 1) != 0) return;
        self.total += 1;
        const cell = (addr - screen_table_start) / 2;
        if (self.count < self.cells.len) {
            self.cells[self.count] = cell;
            self.count += 1;
        }
    }
};

/// Boot the game, then run each of `doors` from the same booted state.
///
/// `direction` is written to $D00E before each call. The four values the warp
/// handler accepts correspond to the four ways a door can be crossed; they
/// change where the *camera* ends up, not where Samus does.
pub fn runDoors(
    allocator: std.mem.Allocator,
    rom: []const u8,
    boot: []const u8,
    doors: []const u16,
    direction: u8,
    boot_seconds: usize,
    /// Sub-screen position to force before each call, or null to leave
    /// whatever the booted machine had.
    offset: ?[2]u8,
) ![]DoorRun {
    const ram = try allocator.alloc(u8, 0x2000);
    defer allocator.free(ram);
    @memset(ram, 0);

    var sys = try system.System.initWithBoot(rom, ram, boot);

    // Long enough to get through the title, the file select and into the
    // first room. Start is tapped throughout; no walking is needed, because
    // the point is a live machine rather than a particular position.
    const boot_frames = boot_seconds * 60;
    while (sys.frames < boot_frames) {
        _ = try sys.step();
        const b = bootButtons(@intCast(sys.frames));
        sys.bus.setKeys(b.dpad, b.buttons);
    }

    // The machine is a value type apart from cartridge RAM, which is a slice
    // the caller owns, so a snapshot is a copy of both.
    const booted = sys;
    const booted_ram = try allocator.dupe(u8, ram);
    defer allocator.free(booted_ram);

    const out = try allocator.alloc(DoorRun, doors.len);
    errdefer allocator.free(out);

    for (doors, 0..) |door, i| {
        sys = booted;
        @memcpy(ram, booted_ram);

        var w: DoorWatcher = .{};
        sys.bus.read_watch = .{ .ctx = &w, .read = DoorWatcher.onRead };

        sys.bus.write(door_index_addr, @truncate(door));
        sys.bus.write(door_index_addr + 1, @truncate(door >> 8));
        sys.bus.write(door_direction_addr, direction);
        if (offset) |o| {
            sys.bus.write(pos_y_low_addr, o[0]);
            sys.bus.write(pos_x_low_addr, o[1]);
        }
        // Call it: push the sentinel and jump.
        sys.cpu.sp -%= 2;
        sys.bus.write(sys.cpu.sp, @truncate(sentinel));
        sys.bus.write(sys.cpu.sp +% 1, @truncate(sentinel >> 8));
        sys.cpu.pc = interp_entry;

        var n: usize = 0;
        var returned = false;
        // Generous, because a door script copies several kilobytes into VRAM
        // through the engine's own copy loops. A script that has not finished
        // by then is reported as unfinished rather than waited on.
        const budget: usize = 4_000_000;
        while (n < budget) : (n += 1) {
            if (sys.cpu.pc == sentinel) {
                returned = true;
                break;
            }
            _ = try sys.step();
        }

        // Detach the watch before reading state out, so this module's own
        // reads cannot land in the numbers it is about to report.
        sys.bus.read_watch = null;
        out[i] = .{
            .door = door,
            .returned = returned,
            .instructions = n,
            .map_bank = sys.bus.read(warp_bank_addr),
            .screen_row = sys.bus.read(screen_row_addr),
            .screen_col = sys.bus.read(screen_col_addr),
            .cells = w.cells,
            .cell_count = w.count,
            .total_cell_reads = w.total,
            .bgp = sys.bus.lcd.bgp,
        };
    }
    return out;
}
