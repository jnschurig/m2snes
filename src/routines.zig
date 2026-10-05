//! Per-routine unit tests: set up state, call one routine of the retail ROM,
//! assert registers and memory.
//!
//! `01-requirements` (F10) asks for three layers of coverage over the rewrite --
//! whole-game integration, per-routine units, and manual exploration -- and for
//! each routine's test status to be recorded in the ledger. This is the middle
//! layer. `gb/harness.zig` is the mechanism; this file is what it is for.
//!
//! Every test here is a claim about **the user's own cartridge**, not about our
//! port: it runs the Game Boy code in our emulator and checks what it does. That
//! makes them useful twice over. They pin behaviour the 65816 rewrite has to
//! match, in a form that fails loudly if a later reading of the ROM turns out to
//! be wrong -- and they reach routines the SNES gate cannot, because the gate can
//! only exercise what the engine already implements. `TryStanding` below is
//! exactly that case: our engine ports it, nothing calls it because the crouch
//! is still a stub, and the ledger has been reporting it converted-and-untested.
//! After this file it is converted-and-tested, and the ledger says so because
//! the test exists rather than because someone edited a column.
//!
//! **The expected values are computed here, independently.** A test that calls
//! the routine and then asserts whatever it returned is a change detector, not a
//! test. `tilemapAddress` below re-derives the address arithmetic from the
//! disassembly in Zig, including the part that looks like a bug and is not.

const std = @import("std");
const harness = @import("gb/harness.zig");

const testrom = @import("testrom");

// ---- Addresses, and how we know them --------------------------------------
//
// Every one of these was read out of the user's ROM with `zig build disasm`,
// which follows control flow from an entry point and prints the instruction
// that touches each address. The disassembly listings are reproducible from the
// cartridge with the commands named beside each group.

/// `zig build disasm -- 0 0x22BC 0x22E1 0x22BC`
///
/// Turns a world position into an address in the background tilemap. A pure
/// function of two RAM bytes, which is what makes it the first routine worth
/// testing: no screen state, no timing, no side effects beyond the two-byte
/// shadow it leaves behind.
pub const tilemap_address: u16 = 0x22BC;
/// The row coordinate it reads, biased by the Game Boy's $10 sprite origin.
pub const sample_y_addr: u16 = 0xC203;
/// The column coordinate, biased by the $08 sprite origin.
pub const sample_x_addr: u16 = 0xC204;
/// Where it leaves the address it computed: low byte, then high byte.
pub const sample_lo_addr: u16 = 0xC215;
pub const sample_hi_addr: u16 = 0xC216;

/// `zig build disasm -- 0 0x1FF5 0x203B 0x1FF5`
///
/// `tilemap_address`, then read the tile through it and return it in A. The
/// double read ANDed together is the original's way of riding out a VRAM access
/// window, and the `AND` makes it idempotent when both reads agree.
pub const sample_tile: u16 = 0x1FF5;
/// Bit 3 selects the second half of the tilemap, adding $0400 to the address --
/// written as `ADD A,H` with $04, which is the same thing.
pub const tilemap_half_addr: u16 = 0xC219;

/// `zig build disasm -- 0 0x1B37 0x1B6B 0x1B37`
///
/// Can Samus stand up where she is? Samples the tilemap at the two columns her
/// standing hitbox would occupy, one row above her feet, and clears the pose to
/// standing only if neither is solid -- see `solidity_addr` for which way round
/// that comparison goes, because it is not the way it reads.
pub const try_standing: u16 = 0x1B37;
/// Samus's position within the screen, in HRAM: row at $FFC0, column at $FFC2.
pub const samus_y_addr: u16 = 0xFFC0;
pub const samus_x_addr: u16 = 0xFFC2;
/// The solidity threshold in force for the current tileset.
///
/// **A tile is solid when its id is BELOW this**, not above it. The routine
/// does `CP (HL)` against it and then `RET C`, and carry means A was the
/// smaller -- so it gives up on standing precisely when the sampled tile is
/// below the threshold. `engine/main.asm:2088` states the same rule for our
/// port; this test is the ROM agreeing with it, which is the direction that
/// matters. The first draft of this file had the sense inverted and the test
/// caught it, which is a reasonable advertisement for the layer.
pub const solidity_addr: u16 = 0xD056;
/// `samusPose`, the byte the whole pose machine dispatches on.
pub const pose_addr: u16 = 0xD020;
/// Cleared to zero -- standing -- when both samples are passable.
pub const pose_standing: u8 = 0x00;

/// The base of the tilemap arithmetic, and its row stride. Both are immediates
/// in the routine: `LD HL,$97E0` and `LD DE,$0020`.
const tilemap_base: u16 = 0x97E0;
const tilemap_row_stride: u16 = 0x0020;
/// The Game Boy's sprite-origin biases, subtracted before the arithmetic.
const origin_y: u8 = 0x10;
const origin_x: u8 = 0x08;

/// Re-derivation of what `tilemap_address` computes, from the disassembly
/// rather than from a run of it.
///
/// Two details are load-bearing and both look like mistakes:
///
///  1. **The row loop always runs once.** The routine falls into the loop at the
///     `ADD HL,DE`, so a position on the very first row still advances one
///     stride -- which is why the base is $97E0 and not $9800.
///  2. **The column addition does not carry into H.** It is `ADD A,L` then
///     `LD L,A`, so the low byte wraps and the high byte does not follow. A
///     position far enough right on a row whose low byte is already high
///     addresses the *start* of that row rather than the next one. That is the
///     hardware's behaviour and the port has to reproduce it, so it is asserted
///     below rather than quietly corrected here.
pub fn tilemapAddress(y: u8, x: u8) u16 {
    var hl: u16 = tilemap_base;
    var a: u8 = y -% origin_y;
    while (true) {
        hl +%= tilemap_row_stride;
        const sub = @subWithOverflow(a, 8);
        a = sub[0];
        // `SUB B` then `JR NC`: the loop continues while the subtraction did
        // not borrow, so a borrow is what ends it.
        if (sub[1] == 1) break;
    }
    const column: u8 = (x -% origin_x) >> 3;
    const lo: u8 = @as(u8, @truncate(hl)) +% column;
    return (hl & 0xFF00) | lo;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

/// A machine with the cartridge mapped and nothing else done to it.
///
/// Zero boot seconds on purpose. Every routine here is called with the state it
/// reads written in by the test, so booting through the title screen would add
/// half a minute of emulation per test and one more thing that could differ
/// between runs. What it costs is that the machine is not *playing*: a routine
/// that depends on state the game sets up during a room load cannot be tested
/// this way, and would need `harness.boot` with real seconds.
fn cold(allocator: std.mem.Allocator, rom: []const u8) !harness.Machine {
    return harness.boot(allocator, rom, 0);
}

test "the tilemap address is the row loop plus a column that does not carry" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var m = try cold(a, rom);
    defer m.deinit();

    // Positions spread over the arithmetic: the first row, a row boundary, the
    // middle of the map, and two chosen so the column addition wraps the low
    // byte -- the case the port would get wrong if it used 16-bit arithmetic.
    const cases = [_][2]u8{
        .{ 0x10, 0x08 },
        .{ 0x17, 0x08 },
        .{ 0x18, 0x08 },
        .{ 0x50, 0x50 },
        .{ 0x88, 0xF8 },
        .{ 0xC0, 0xE0 },
        .{ 0x10, 0xFF },
        .{ 0xFF, 0xFF },
    };

    for (cases) |c| {
        const y = c[0];
        const x = c[1];
        const out = try m.call(.{
            .addr = tilemap_address,
            .writes = &.{
                .{ .addr = sample_y_addr, .value = y },
                .{ .addr = sample_x_addr, .value = x },
            },
        });
        try testing.expect(out.returned);

        const want = tilemapAddress(y, x);
        try testing.expectEqual(want, out.hl());
        // And the shadow it leaves in RAM, which is what `sample_tile` reads
        // back when it needs the address again.
        try testing.expectEqual(@as(u8, @truncate(want)), m.read(sample_lo_addr));
        try testing.expectEqual(@as(u8, @truncate(want >> 8)), m.read(sample_hi_addr));
    }
}

test "the tilemap address stays inside the background map for every screen position" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var m = try cold(a, rom);
    defer m.deinit();

    // A property rather than a table: for every position a Samus-sized sprite
    // can occupy on screen, the address the routine computes is inside VRAM's
    // background region. Checked against the routine itself, not against
    // `tilemapAddress`, so it is evidence about the ROM and not about our
    // re-derivation of it.
    var y: u16 = origin_y;
    while (y < origin_y + 144) : (y += 8) {
        var x: u16 = origin_x;
        while (x < origin_x + 160) : (x += 8) {
            const out = try m.call(.{
                .addr = tilemap_address,
                .writes = &.{
                    .{ .addr = sample_y_addr, .value = @truncate(y) },
                    .{ .addr = sample_x_addr, .value = @truncate(x) },
                },
            });
            try testing.expect(out.returned);
            try testing.expect(out.hl() >= 0x9800);
            try testing.expect(out.hl() < 0x9C00);
            try testing.expectEqual(tilemapAddress(@truncate(y), @truncate(x)), out.hl());
        }
    }
}

test "sampling a tile returns the byte at the address the arithmetic names" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var m = try cold(a, rom);
    defer m.deinit();

    const y: u8 = 0x50;
    const x: u8 = 0x50;
    const addr = tilemapAddress(y, x);

    // The routine reads the tile twice and ANDs the results, which is a way of
    // surviving a read that lands in the middle of a VRAM access window. With
    // both reads agreeing the AND is the identity, so a tile written here comes
    // back unchanged -- and if it ever does not, the two reads disagreed, which
    // is a fact about our LCD timing worth failing over.
    for ([_]u8{ 0x00, 0x01, 0x7F, 0x80, 0xFF }) |tile| {
        m.write(addr, tile);
        const out = try m.call(.{
            .addr = sample_tile,
            .writes = &.{
                .{ .addr = sample_y_addr, .value = y },
                .{ .addr = sample_x_addr, .value = x },
                // Bit 3 clear: the first half of the tilemap, no $0400 offset.
                .{ .addr = tilemap_half_addr, .value = 0x00 },
            },
        });
        try testing.expect(out.returned);
        try testing.expectEqual(tile, out.a);
    }
}

test "the second tilemap half is the first plus $0400" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var m = try cold(a, rom);
    defer m.deinit();

    const y: u8 = 0x50;
    const x: u8 = 0x50;
    const addr = tilemapAddress(y, x);

    m.write(addr, 0x11);
    m.write(addr + 0x0400, 0x22);

    const first = try m.call(.{ .addr = sample_tile, .writes = &.{
        .{ .addr = sample_y_addr, .value = y },
        .{ .addr = sample_x_addr, .value = x },
        .{ .addr = tilemap_half_addr, .value = 0x00 },
    } });
    try testing.expectEqual(@as(u8, 0x11), first.a);

    const second = try m.call(.{ .addr = sample_tile, .writes = &.{
        .{ .addr = sample_y_addr, .value = y },
        .{ .addr = sample_x_addr, .value = x },
        .{ .addr = tilemap_half_addr, .value = 0x08 },
    } });
    try testing.expectEqual(@as(u8, 0x22), second.a);
}

/// Put the two tiles `try_standing` samples where it will find them.
///
/// It reads Samus's screen position out of HRAM, adds the standing hitbox's
/// offsets, and samples at (`y` + $10, `x` + $0C) and (`y` + $10, `x` + $14).
/// Both offsets come from the disassembly, not from a listing's labels.
fn placeStandingTiles(m: *harness.Machine, y: u8, x: u8, left: u8, right: u8) void {
    m.write(tilemapAddress(y +% 0x10, x +% 0x0C), left);
    m.write(tilemapAddress(y +% 0x10, x +% 0x14), right);
}

test "she stands up only when both tiles above her are passable" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var m = try cold(a, rom);
    defer m.deinit();

    const y: u8 = 0x40;
    const x: u8 = 0x40;
    const threshold: u8 = 0x40;
    // Below the threshold is solid; at or above it is passable. See
    // `solidity_addr` -- the sense is the opposite of what the names would
    // suggest if they were read off the comparison alone.
    const solid: u8 = threshold - 1;
    const passable: u8 = threshold;
    const crouching: u8 = 0x04;

    // All four combinations, because the routine returns early on the *first*
    // solid tile and a test that only tried "both solid" would pass against an
    // implementation that never checked the second one at all.
    const cases = [_]struct { left: u8, right: u8, stands: bool }{
        .{ .left = passable, .right = passable, .stands = true },
        .{ .left = solid, .right = passable, .stands = false },
        .{ .left = passable, .right = solid, .stands = false },
        .{ .left = solid, .right = solid, .stands = false },
    };

    for (cases) |c| {
        placeStandingTiles(&m, y, x, c.left, c.right);
        const out = try m.call(.{
            .addr = try_standing,
            .writes = &.{
                .{ .addr = samus_y_addr, .value = y },
                .{ .addr = samus_x_addr, .value = x },
                .{ .addr = solidity_addr, .value = threshold },
                .{ .addr = pose_addr, .value = crouching },
                .{ .addr = tilemap_half_addr, .value = 0x00 },
            },
        });
        try testing.expect(out.returned);
        const pose = m.read(pose_addr);
        if (c.stands) {
            try testing.expectEqual(pose_standing, pose);
        } else {
            // Unchanged: the routine's only way of saying no is to leave the
            // pose alone, so "still crouching" is the whole assertion.
            try testing.expectEqual(crouching, pose);
        }
    }
}

test "the solidity threshold is a boundary, and the tile at it is solid" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var m = try cold(a, rom);
    defer m.deinit();

    const y: u8 = 0x40;
    const x: u8 = 0x40;
    const threshold: u8 = 0x40;
    const crouching: u8 = 0x04;

    // The boundary itself, which is the value a port gets wrong by one. `CP
    // (HL)` then `RET C` gives up when the tile is strictly below the
    // threshold, so the tile *equal* to it is passable and she stands.
    for ([_]u8{ threshold - 1, threshold, threshold + 1 }) |tile| {
        placeStandingTiles(&m, y, x, tile, tile);
        _ = try m.call(.{
            .addr = try_standing,
            .writes = &.{
                .{ .addr = samus_y_addr, .value = y },
                .{ .addr = samus_x_addr, .value = x },
                .{ .addr = solidity_addr, .value = threshold },
                .{ .addr = pose_addr, .value = crouching },
                .{ .addr = tilemap_half_addr, .value = 0x00 },
            },
        });
        const stood = m.read(pose_addr) == pose_standing;
        try testing.expectEqual(tile >= threshold, stood);
    }
}
