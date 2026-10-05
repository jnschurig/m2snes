//! Map banks $9-$F.
//!
//! Each map bank is one 16x16 grid of screens and is laid out identically:
//!
//!   $4000  $200   screen pointers      256 little-endian GB addresses
//!   $4200  $100   scroll flags         one byte per cell
//!   $4300  $200   transition indexes   256 little-endian words
//!   $4500  $3B00  screen bodies        59 screens of $100 bytes
//!
//! A screen body is 16x16 metatile indexes, row-major. Every cell in the grid
//! carries a pointer, but most point at the shared blank screen at $4500; a
//! cell is "in use" when its pointer is anything else. That definition is not
//! a guess - it yields exactly 905 in-use cells across the seven banks, which
//! is the figure the requirements independently record.
//!
//! Scroll flags encode room boundaries: bit0 right, bit1 left, bit2 up,
//! bit3 down, with the high nibble unused. A set bit means the camera is
//! **blocked** in that direction, so these bits *are* the room shape.
//!
//! The sense is the opposite of what `01-requirements.md` reads like ("a screen
//! permits scrolling in a direction only where valid content exists"), and it
//! was worth pinning down rather than assuming, because a camera built on the
//! inverted reading walks out of rooms and stops inside them. Two independent
//! measurements against the retail ROM settle it:
//!
//!  * The same requirements document records 274 in-use screens blocking both
//!    left and right, 328 blocking both up and down, and 31 fully pinned. Read
//!    as "set blocks", the ROM yields exactly 274, 328 and 31. Read as "set
//!    permits" it yields 198, 258 and 42.
//!  * Of the 1664 directions a set of in-use screens leaves unblocked under the
//!    first reading, 1621 lead to a screen that is itself in use. The 43 that
//!    do not are a 2.6% residual; under the other reading the figure is a
//!    coin toss.
//!
//! The field names carry the sense so a caller cannot read them the other way
//! by accident.

const std = @import("std");
const offsets = @import("offsets.zig");

pub const first_bank: u8 = 0x9;
pub const last_bank: u8 = 0xF;
pub const bank_count: usize = last_bank - first_bank + 1;

pub const grid_w: usize = 16;
pub const grid_h: usize = 16;
pub const cells: usize = grid_w * grid_h;

pub const screen_bytes: usize = 0x100;
pub const screens_per_bank: usize = 59;

pub const ptrs_addr: u16 = 0x4000;
pub const flags_addr: u16 = 0x4200;
pub const transitions_addr: u16 = 0x4300;
pub const screens_addr: u16 = 0x4500;
pub const bank_end: u16 = 0x8000;

/// The shared empty screen every unused cell points at.
pub const blank_screen: u16 = screens_addr;

pub const Scroll = packed struct(u8) {
    block_right: bool,
    block_left: bool,
    block_up: bool,
    block_down: bool,
    unused: u4,

    pub fn blocked(self: Scroll, comptime dir: []const u8) bool {
        return @field(self, "block_" ++ dir);
    }

    pub fn permits(self: Scroll, comptime dir: []const u8) bool {
        return !self.blocked(dir);
    }
};

pub const Cell = struct {
    /// Grid position. `index` is `y * 16 + x`, which is how the engine indexes
    /// the scroll table.
    x: u4,
    y: u4,
    screen_ptr: u16,
    scroll: Scroll,
    transition: u16,

    pub fn index(self: Cell) usize {
        return @as(usize, self.y) * grid_w + self.x;
    }

    pub fn inUse(self: Cell) bool {
        return self.screen_ptr != blank_screen;
    }

    /// Byte offset of this cell's screen body within its bank, or null when the
    /// pointer does not address the screen region at all.
    pub fn screenOffsetInBank(self: Cell) ?usize {
        if (self.screen_ptr < screens_addr or self.screen_ptr >= bank_end) return null;
        const rel = self.screen_ptr - screens_addr;
        if (rel % screen_bytes != 0) return null;
        return offsets.bank_size - (bank_end - screens_addr) + rel;
    }
};

pub const Bank = struct {
    bank: u8,
    cells: [cells]Cell,
    /// Distinct screen bodies actually referenced by this bank's grid.
    referenced: []u16,
    /// Cell indexes that are in use but whose pointer does not resolve to an
    /// aligned screen body. Bank $A has exactly one: a cell holding $0000,
    /// which is a null rather than the shared blank at $4500. It is reported
    /// rather than treated as an error - refusing to parse a whole bank over
    /// one dead cell would be wrong, and silently folding it into the blank
    /// count would hide it.
    unresolved: []u8,

    pub fn deinit(self: *Bank, allocator: std.mem.Allocator) void {
        allocator.free(self.referenced);
        allocator.free(self.unresolved);
    }
};

pub const Error = error{ NotAMapBank, ShortBank };

fn readWord(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) | (@as(u16, bytes[at + 1]) << 8);
}

/// Parse one map bank out of the full ROM image.
pub fn parseBank(allocator: std.mem.Allocator, rom: []const u8, bank: u8) !Bank {
    if (bank < first_bank or bank > last_bank) return Error.NotAMapBank;
    const base = @as(usize, bank) * offsets.bank_size;
    if (base + offsets.bank_size > rom.len) return Error.ShortBank;
    const b = rom[base..][0..offsets.bank_size];

    const p_off = ptrs_addr & 0x3FFF;
    const f_off = flags_addr & 0x3FFF;
    const t_off = transitions_addr & 0x3FFF;

    var out: Bank = .{ .bank = bank, .cells = undefined, .referenced = &.{}, .unresolved = &.{} };

    var seen: std.AutoArrayHashMapUnmanaged(u16, void) = .empty;
    defer seen.deinit(allocator);

    var unresolved: std.ArrayList(u8) = .empty;
    errdefer unresolved.deinit(allocator);

    for (0..cells) |i| {
        const ptr = readWord(b, p_off + i * 2);
        const cell: Cell = .{
            .x = @intCast(i % grid_w),
            .y = @intCast(i / grid_w),
            .screen_ptr = ptr,
            .scroll = @bitCast(b[f_off + i]),
            .transition = readWord(b, t_off + i * 2),
        };
        if (cell.inUse()) {
            if (cell.screenOffsetInBank() != null) {
                try seen.put(allocator, ptr, {});
            } else {
                try unresolved.append(allocator, @intCast(i));
            }
        }
        out.cells[i] = cell;
    }

    // The blank screen is referenced by construction; count it so the total is
    // the number of screen bodies the bank actually uses.
    try seen.put(allocator, blank_screen, {});
    out.referenced = try allocator.dupe(u16, seen.keys());
    std.mem.sort(u16, out.referenced, {}, std.sort.asc(u16));
    out.unresolved = try unresolved.toOwnedSlice(allocator);
    return out;
}

/// The `$100` bytes of a screen body, as 16x16 metatile indexes.
pub fn screenBody(rom: []const u8, bank: u8, screen_ptr: u16) ?[]const u8 {
    if (screen_ptr < screens_addr or screen_ptr >= bank_end) return null;
    const base = @as(usize, bank) * offsets.bank_size + (screen_ptr & 0x3FFF);
    if (base + screen_bytes > rom.len) return null;
    return rom[base..][0..screen_bytes];
}

// ---- Encode-back ----------------------------------------------------------
//
// One inverse per table, matching the offsets-table entries rather than the
// bank as a whole, so a round-trip failure names the table that broke instead
// of the $500-byte block it lives in.

fn writeWord(out: []u8, at: usize, v: u16) void {
    out[at] = @truncate(v);
    out[at + 1] = @truncate(v >> 8);
}

/// Screen pointers, 256 little-endian GB addresses. `out.len` must be `$200`.
pub fn encodePointers(b: Bank, out: []u8) void {
    std.debug.assert(out.len == cells * 2);
    for (b.cells, 0..) |c, i| writeWord(out, i * 2, c.screen_ptr);
}

/// Scroll flags, one byte per cell. The unused high nibble rides along in the
/// packed struct, so a bank that puts something there survives the round-trip
/// and shows up as a nonzero `unused` rather than as a silent loss.
pub fn encodeFlags(b: Bank, out: []u8) void {
    std.debug.assert(out.len == cells);
    for (b.cells, 0..) |c, i| out[i] = @bitCast(c.scroll);
}

/// Transition indexes, 256 little-endian words. `out.len` must be `$200`.
pub fn encodeTransitions(b: Bank, out: []u8) void {
    std.debug.assert(out.len == cells * 2);
    for (b.cells, 0..) |c, i| writeWord(out, i * 2, c.transition);
}

/// One screen body: 16x16 metatile indexes, row-major.
pub const Screen = struct {
    gb_addr: u16,
    tiles: [grid_h][grid_w]u8,

    pub fn get(self: Screen, col: usize, row: usize) u8 {
        return self.tiles[row][col];
    }
};

/// Every screen body in a bank, in address order — all 59, referenced or not.
/// The walk is by position rather than by pointer on purpose: a body no cell
/// points at is still data we have to reproduce, and reading only the
/// referenced ones would let an unreferenced screen rot unnoticed.
pub fn parseScreens(allocator: std.mem.Allocator, rom: []const u8, bank: u8) ![]Screen {
    if (bank < first_bank or bank > last_bank) return Error.NotAMapBank;
    const base = @as(usize, bank) * offsets.bank_size + (screens_addr & 0x3FFF);
    if (base + screens_per_bank * screen_bytes > rom.len) return Error.ShortBank;

    const out = try allocator.alloc(Screen, screens_per_bank);
    errdefer allocator.free(out);
    for (0..screens_per_bank) |s| {
        const body = rom[base + s * screen_bytes ..][0..screen_bytes];
        var scr: Screen = .{
            .gb_addr = screens_addr + @as(u16, @intCast(s * screen_bytes)),
            .tiles = undefined,
        };
        for (0..grid_h) |row| {
            @memcpy(&scr.tiles[row], body[row * grid_w ..][0..grid_w]);
        }
        out[s] = scr;
    }
    return out;
}

pub fn encodeScreens(allocator: std.mem.Allocator, list: []const Screen) ![]u8 {
    const out = try allocator.alloc(u8, list.len * screen_bytes);
    for (list, 0..) |s, i| {
        for (0..grid_h) |row| {
            @memcpy(out[i * screen_bytes + row * grid_w ..][0..grid_w], &s.tiles[row]);
        }
    }
    return out;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "the bank partition is contiguous and fills the bank exactly" {
    try testing.expectEqual(@as(usize, 0x200), flags_addr - ptrs_addr);
    try testing.expectEqual(@as(usize, 0x100), transitions_addr - flags_addr);
    try testing.expectEqual(@as(usize, 0x200), screens_addr - transitions_addr);
    try testing.expectEqual(screens_per_bank * screen_bytes, @as(usize, bank_end - screens_addr));
    try testing.expectEqual(offsets.bank_size, @as(usize, bank_end - ptrs_addr));
}

test "scroll flags decode to the documented bit assignment" {
    const s: Scroll = @bitCast(@as(u8, 0b0000_0101));
    try testing.expect(s.block_right);
    try testing.expect(!s.block_left);
    try testing.expect(s.block_up);
    try testing.expect(!s.block_down);
    try testing.expectEqual(@as(u4, 0), s.unused);
    try testing.expect(s.blocked("right"));
    try testing.expect(!s.blocked("left"));
    try testing.expect(s.permits("left"));
    try testing.expect(!s.permits("right"));
}

test "cell index is row-major, matching the engine's screenY*16 + screenX" {
    const c: Cell = .{ .x = 3, .y = 2, .screen_ptr = blank_screen, .scroll = @bitCast(@as(u8, 0)), .transition = 0 };
    try testing.expectEqual(@as(usize, 35), c.index());
    try testing.expect(!c.inUse());
}

test "screen offsets are aligned and rejected when they are not" {
    var c: Cell = .{ .x = 0, .y = 0, .screen_ptr = 0x4600, .scroll = @bitCast(@as(u8, 0)), .transition = 0 };
    try testing.expect(c.inUse());
    try testing.expectEqual(@as(?usize, 0x0600), c.screenOffsetInBank());
    c.screen_ptr = 0x4601;
    try testing.expectEqual(@as(?usize, null), c.screenOffsetInBank());
    c.screen_ptr = 0x4000; // inside the bank, but not the screen region
    try testing.expectEqual(@as(?usize, null), c.screenOffsetInBank());
    c.screen_ptr = 0x7F00; // the last screen
    try testing.expectEqual(@as(?usize, 0x3F00), c.screenOffsetInBank());
}

test "offsets.zig agrees with the partition constants for every map bank" {
    var bank: u8 = first_bank;
    while (bank <= last_bank) : (bank += 1) {
        var buf: [40]u8 = undefined;
        const parts = [_]struct { suffix: []const u8, addr: u16, size: usize }{
            .{ .suffix = "screen_pointers", .addr = ptrs_addr, .size = 0x200 },
            .{ .suffix = "scroll_flags", .addr = flags_addr, .size = 0x100 },
            .{ .suffix = "transition_indexes", .addr = transitions_addr, .size = 0x200 },
            .{ .suffix = "screens", .addr = screens_addr, .size = screens_per_bank * screen_bytes },
        };
        for (parts) |p| {
            const name = try std.fmt.bufPrint(&buf, "map{X}_{s}", .{ bank, p.suffix });
            const e = offsets.find(name) orelse return error.MissingMapEntry;
            try testing.expectEqual(p.addr, e.gb_addr);
            try testing.expectEqual(p.size, e.size);
            try testing.expectEqual(bank, e.bank);
        }
    }
}

test "a set scroll bit blocks, measured against the ROM" {
    // Two independent measurements, because the sense is not derivable from
    // the bit layout and the requirements' prose reads the other way.
    //
    // `01-requirements.md` records, from a different pass over the same data,
    // that 274 in-use screens block both left and right, 328 block both up and
    // down, and 31 are pinned in all four. Only one reading reproduces those.
    const testrom = @import("testrom");
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);

    var in_use: usize = 0;
    var lr: usize = 0;
    var ud: usize = 0;
    var pinned: usize = 0;
    // And the corroborating measurement: where a screen leaves a direction
    // unblocked, does that direction lead anywhere?
    var open_to_content: usize = 0;
    var open_to_nothing: usize = 0;

    for (first_bank..last_bank + 1) |b| {
        var bank = try parseBank(testing.allocator, rom, @intCast(b));
        defer bank.deinit(testing.allocator);
        for (bank.cells) |c| {
            if (!c.inUse()) continue;
            in_use += 1;
            if (c.scroll.blocked("left") and c.scroll.blocked("right")) lr += 1;
            if (c.scroll.blocked("up") and c.scroll.blocked("down")) ud += 1;
            if (c.scroll.blocked("left") and c.scroll.blocked("right") and
                c.scroll.blocked("up") and c.scroll.blocked("down")) pinned += 1;

            const dirs = [_]struct { blocked: bool, dx: i32, dy: i32 }{
                .{ .blocked = c.scroll.block_right, .dx = 1, .dy = 0 },
                .{ .blocked = c.scroll.block_left, .dx = -1, .dy = 0 },
                .{ .blocked = c.scroll.block_up, .dx = 0, .dy = -1 },
                .{ .blocked = c.scroll.block_down, .dx = 0, .dy = 1 },
            };
            for (dirs) |d| {
                if (d.blocked) continue;
                const nx = @as(i32, c.x) + d.dx;
                const ny = @as(i32, c.y) + d.dy;
                if (nx < 0 or nx >= grid_w or ny < 0 or ny >= grid_h) {
                    open_to_nothing += 1;
                } else if (bank.cells[@intCast(ny * @as(i32, grid_w) + nx)].inUse()) {
                    open_to_content += 1;
                } else {
                    open_to_nothing += 1;
                }
            }
        }
    }

    try testing.expectEqual(@as(usize, 905), in_use);
    try testing.expectEqual(@as(usize, 274), lr);
    try testing.expectEqual(@as(usize, 328), ud);
    try testing.expectEqual(@as(usize, 31), pinned);

    // An unblocked direction almost always leads to a screen that exists. The
    // residual is real and small; pinning it means a future change that made it
    // worse would be seen rather than absorbed.
    try testing.expectEqual(@as(usize, 1621), open_to_content);
    try testing.expectEqual(@as(usize, 43), open_to_nothing);
}
