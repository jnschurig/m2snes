//! The destructible-block mechanism's constants, read out of the cartridge.
//!
//! Every number in `engine/main.asm`'s `!BLK_*` block is an immediate operand
//! in bank 1, and this file reads each one out of the opcode it belongs to.
//! That is the porting loop's step 0a applied to a whole mechanism at once:
//!
//! > A constant transcribed from a disassembly is a number someone typed until
//! > something in the cartridge is made to say it.
//!
//! The precedent is `items.bitFor`, and the reason it earns its place is the
//! same: two of the six equipment masks had been the wrong bit since Phase 0a
//! and nothing could see it, because a mask that is never set is never read.
//! Sixteen block constants that agree with each other prove nothing at all;
//! sixteen that agree with the opcodes they were read out of is evidence.
//!
//! ## Why the addresses are pinned rather than searched for
//!
//! `items.bitFor` searches, because `handleItemPickup`'s arms are scattered and
//! their order in the ROM is not their order in the table. These are not
//! scattered: `handleRespawningBlocks` is 87 contiguous bytes and its six
//! compares are consecutive. A pinned address with an asserted opcode is the
//! stronger check of the two -- `counterAt` refuses to return anything unless
//! the byte it names really is a `CP d8` -- so a shifted address fails loudly
//! rather than finding a plausible number somewhere else.
//!
//! Bank 0 is not paged and bank 1 is the bank its window holds by default, so
//! a Game Boy address below $8000 in either of them *is* its ROM offset. `at()`
//! says so once, and every site named below is in one of those two banks.

const std = @import("std");
const testing = std.testing;
const tileset = @import("tileset.zig");
const offsets = @import("offsets.zig");
const door = @import("door.zig");

pub const Error = error{
    /// The byte at a pinned address is not the opcode the mechanism needs it to
    /// be. Refusing beats returning the operand of whatever is there instead.
    NotTheOpcode,
    /// The `SOLIDITY` loader's store sequence does not have the shape the
    /// column index is read out of.
    NotAThresholdLoad,
    /// The loader never stores to `beamSolidityIndex`.
    NoBeamThreshold,
};

/// A bank 0 or bank 1 address as a ROM offset: the same number, because bank 0
/// is fixed at $0000-$3FFF and bank 1 is what $4000-$7FFF holds by default.
fn at(addr: u16) usize {
    return addr;
}

/// Two bytes are readable at `o`. Every reader goes through this, so a site
/// past the end of a short buffer is `NotTheOpcode` rather than a panic.
fn room(rom: []const u8, o: usize) !void {
    if (o + 1 >= rom.len) return Error.NotTheOpcode;
}

// ---- Where each constant lives --------------------------------------------

/// `handleRespawningBlocks`' six `CP d8`, in the order the routine compares
/// them: 01:$56BC, $56C1, $56C6, $56CA, $56CF, $56D3.
pub const counter_sites = [_]u16{ 0x56BC, 0x56C1, 0x56C6, 0x56CA, 0x56CF, 0x56D3 };
/// The two eviction bands, 01:$56A6 (vertical) and 01:$56B5 (horizontal).
pub const evict_sites = [_]u16{ 0x56A6, 0x56B5 };
/// `destroyBlock`'s $FF (01:$5705), the first crack's $04 (01:$575E) and the
/// second's $08 (01:$5785), each a `LD A,d8`.
pub const tile_gone_site: u16 = 0x5705;
pub const tile_crack_a_site: u16 = 0x575E;
pub const tile_crack_b_site: u16 = 0x5785;
/// The reform's base id, which is an `XOR A` and not an immediate: 01:$5730.
pub const tile_solid_site: u16 = 0x5730;
/// `destroyRespawningBlock`'s slot stride, `ADD A,d8` at 01:$5679.
pub const stride_site: u16 = 0x5679;
/// The classification's `CP $04`, 01:$5168: the id below which a tile is a
/// respawning block whatever its collision byte says.
pub const respawn_ids_site: u16 = 0x5168;
/// The `BIT n,A` each classification makes on the collision byte. The beam's is
/// in `handleProjectiles`' terrain arm; the bomb's is one of five identical
/// sites and this is the first.
pub const shot_bit_site: u16 = 0x5176;
pub const bomb_bit_site: u16 = 0x5543;
/// Step 22: the acid test, the first of six (`collision_samusTop`'s left probe).
pub const acid_bit_site: u16 = 0x1EC5;

/// `convertCameraToScroll` (00:$2366), the per-frame writer of `scrollY` and
/// `scrollX` -- which is what `handleRespawningBlocks` compares a slot against.
/// The two `SUB d8` are at $2368 and $236F.
///
/// The port derives the scroll from the camera rather than storing it, so these
/// two operands are the whole of what it needs. **Reading them here rather than
/// exporting the engine's own defines is deliberate**: the gate must not take a
/// constant from the thing it is grading -- see `docs/bug_tracker.md`,
/// 2026-09-09, where this bias was $78/$30 from a third ROM site and every
/// enemy the walk loaded came out 48 pixels low.
pub const scroll_y_bias_site: u16 = 0x2368;
pub const scroll_x_bias_site: u16 = 0x236F;

/// Where `handleSolidity` (00:$2430) unpacks a `SOLIDITY` row. Bank 0 is not
/// paged, so the address is the offset.
pub const solidity_loader_lo: usize = 0x2446;
pub const solidity_loader_hi: usize = 0x245B;
/// `beamSolidityIndex`, the variable whose column this file derives.
pub const beam_threshold_addr: u16 = 0xD08A;

// ---- The readers ----------------------------------------------------------

/// The operand of the one-byte-immediate instruction `opcode` at ROM offset
/// `o`, or `NotTheOpcode` if that is not what is there. Every reader below goes
/// through this, which is what makes "read the constant out of the site" a
/// claim the ROM can refuse rather than an offset plus a hope.
fn operandAt(rom: []const u8, o: usize, opcode: u8) !u8 {
    try room(rom, o);
    if (rom[o] != opcode) return Error.NotTheOpcode;
    return rom[o + 1];
}

/// A site's ROM offset when it is not in bank 1. Bank 1's address *is* its
/// offset, which is why everything above this line can ignore the question;
/// Step 12b's `weapon_damage` neighbours are in bank 2 and cannot.
pub fn offsetIn(bank: u8, addr: u16) usize {
    if (bank == 0) return addr;
    return @as(usize, bank) * 0x4000 + (addr - 0x4000);
}

/// The operand of the `CP d8` at `addr`.
pub fn compareAt(rom: []const u8, addr: u16) !u8 {
    return operandAt(rom, at(addr), 0xFE);
}

/// The operand of the `LD A,d8` at `addr`.
pub fn loadAt(rom: []const u8, addr: u16) !u8 {
    return operandAt(rom, at(addr), 0x3E);
}

/// The operand of the `SUB d8` at `addr`.
pub fn subAt(rom: []const u8, addr: u16) !u8 {
    return operandAt(rom, at(addr), 0xD6);
}

/// The operand of the `ADD A,d8` at `addr`.
pub fn addAt(rom: []const u8, addr: u16) !u8 {
    return operandAt(rom, at(addr), 0xC6);
}

/// The same four, for a site in a bank other than 1.
pub fn compareIn(rom: []const u8, bank: u8, addr: u16) !u8 {
    return operandAt(rom, offsetIn(bank, addr), 0xFE);
}

pub fn loadIn(rom: []const u8, bank: u8, addr: u16) !u8 {
    return operandAt(rom, offsetIn(bank, addr), 0x3E);
}

pub fn addIn(rom: []const u8, bank: u8, addr: u16) !u8 {
    return operandAt(rom, offsetIn(bank, addr), 0xC6);
}

/// The operand of the `SUB d8` at `addr` in `bank`.
pub fn subIn(rom: []const u8, bank: u8, addr: u16) !u8 {
    return operandAt(rom, offsetIn(bank, addr), 0xD6);
}

/// The operand of the `AND d8` at `addr`. Step 12e's two blink divisors and the
/// mask of the drop roll are all one of these.
pub fn andIn(rom: []const u8, bank: u8, addr: u16) !u8 {
    return operandAt(rom, offsetIn(bank, addr), 0xE6);
}

/// The operand of the `XOR d8` at `addr`, which is how a drop's two animation
/// frames are reached from each other.
pub fn xorIn(rom: []const u8, bank: u8, addr: u16) !u8 {
    return operandAt(rom, offsetIn(bank, addr), 0xEE);
}

/// The operand of the `LD (HL),d8` at `addr`. `enemy_metroidExplosion` puts an
/// escaped blast back at a screen edge with one of these.
pub fn loadHlIn(rom: []const u8, bank: u8, addr: u16) !u8 {
    return operandAt(rom, offsetIn(bank, addr), 0x36);
}

/// The operand of the `LD B,d8` at `addr`. `enemy_animateExplosion` keeps the
/// ordinary explosion's length in B rather than comparing against an immediate.
pub fn loadBIn(rom: []const u8, bank: u8, addr: u16) !u8 {
    return operandAt(rom, offsetIn(bank, addr), 0x06);
}

/// Both halves of the `LD BC,d16` at `addr`. The three drops are each one of
/// these and the pair is the point: B is the `dropType` the slot carries and C
/// is the sprite it wears, set together so they cannot disagree.
pub fn loadBcIn(rom: []const u8, bank: u8, addr: u16) !struct { b: u8, c: u8 } {
    const o = offsetIn(bank, addr);
    try room(rom, o);
    if (o + 2 >= rom.len) return Error.NotTheOpcode;
    if (rom[o] != 0x01) return Error.NotTheOpcode;
    return .{ .b = rom[o + 2], .c = rom[o + 1] };
}

/// `bitTestAt` for a site outside bank 1.
pub fn bitTestIn(rom: []const u8, bank: u8, addr: u16) !u3 {
    const o = offsetIn(bank, addr);
    try room(rom, o);
    if (rom[o] != 0xCB) return Error.NotTheOpcode;
    const op = rom[o + 1];
    if (op < 0x47 or op > 0x7F or (op - 0x47) % 8 != 0) return Error.NotTheOpcode;
    return @intCast((op - 0x47) / 8);
}

/// The bit a `BIT n,A` at `addr` tests. `CB` then `$47 + n * 8`.
pub fn bitTestAt(rom: []const u8, addr: u16) !u3 {
    const o = at(addr);
    try room(rom, o);
    if (rom[o] != 0xCB) return Error.NotTheOpcode;
    const op = rom[o + 1];
    if (op < 0x47 or op > 0x7F or (op - 0x47) % 8 != 0) return Error.NotTheOpcode;
    return @intCast((op - 0x47) / 8);
}

/// The mask the engine's `!BLOCK_SHOT` has to be: one shifted by the bit
/// 01:$5176 tests.
pub fn shotMask(rom: []const u8) !u8 {
    return @as(u8, 1) << try bitTestAt(rom, shot_bit_site);
}

/// And `!BLOCK_BOMB`, from the first of the five bomb arms.
pub fn bombMask(rom: []const u8) !u8 {
    return @as(u8, 1) << try bitTestAt(rom, bomb_bit_site);
}

/// And `!BLOCK_ACID`, from 00:$1EC5.
pub fn acidMask(rom: []const u8) !u8 {
    return @as(u8, 1) << try bitTestAt(rom, acid_bit_site);
}

/// The reform's base tile id, which the ROM writes as `XOR A` rather than as an
/// immediate -- so the check is on the opcode and the value falls out of it.
pub fn solidTile(rom: []const u8) !u8 {
    try room(rom, at(tile_solid_site));
    if (rom[at(tile_solid_site)] != 0xAF) return Error.NotTheOpcode;
    return 0;
}

/// **Which column of a `SOLIDITY` row is the beam's**, read out of the loader's
/// own store sequence rather than out of a comment.
///
/// 00:$2446-$245A is nothing but `LD A,(HL+)` and `LD (nn),A`, three of each
/// pair, walking one four-byte row: `$D056` then `$D069` then `$D08A`. Counting
/// the reads that precede the store to `beamSolidityIndex` is the ROM stating
/// that the beam's threshold is byte two, and it is the only statement of that
/// fact this repository has.
pub fn beamThresholdColumn(rom: []const u8) !u8 {
    var i = solidity_loader_lo;
    var reads: u8 = 0;
    while (i < solidity_loader_hi) {
        switch (rom[i]) {
            0x2A => { // LD A,(HL+)
                reads += 1;
                i += 1;
            },
            0xEA => { // LD (nn),A
                const dest = @as(u16, rom[i + 1]) | (@as(u16, rom[i + 2]) << 8);
                if (dest == beam_threshold_addr) {
                    if (reads == 0) return Error.NotAThresholdLoad;
                    return reads - 1;
                }
                i += 3;
            },
            else => return Error.NotAThresholdLoad,
        }
    }
    return Error.NoBeamThreshold;
}

/// The beam threshold a tileset's row carries: the column above, out of the
/// eight-row table at 8:$7EFA.
pub fn beamThresholdFor(rom: []const u8, tileset_index: usize) !u8 {
    const e = offsets.find("solidity_thresholds").?;
    const rows = try tileset.parseSolidity(rom[e.romOffset()..e.romEnd()]);
    return rows[tileset_index].thresholds[try beamThresholdColumn(rom)];
}

/// The `SOLIDITY` operand a door script leaves in force, or null if it issues
/// none. Which is the tileset index `beamThresholdFor` wants: `COLLISION` and
/// `SOLIDITY` share one numbering, per `tileset.tileset_order`.
pub fn solidityOf(script: []const door.Op) ?u4 {
    var out: ?u4 = null;
    for (script) |op| switch (op) {
        .solidity => |v| out = v,
        else => {},
    };
    return out;
}

// ---- Tests ----------------------------------------------------------------

const testrom = @import("testrom");

test "the six counters the block animation runs on are six CP immediates" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var got: [counter_sites.len]u8 = undefined;
    for (counter_sites, 0..) |site, i| got[i] = try compareAt(rom, site);

    // The schedule. $02 and $07 crack the block open, $0D empties it, $F6 and
    // $FA crack it back the other way -- $F6 showing the same picture as $07
    // and $FA the same as $02 -- and $FE reforms it.
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x07, 0x0D, 0xF6, 0xFA, 0xFE }, &got);

    // **The two halves are not mirror images, and this assertion is here
    // because the first version of it claimed they were and failed.** Going out
    // the gaps are 5 and 6 frames; coming back they are 4 and 4. So the
    // disappearance is a slower animation than the return, which is a fact
    // about the game and not a symmetry to be assumed.
    try testing.expectEqual(@as(u8, 5), got[1] - got[0]);
    try testing.expectEqual(@as(u8, 6), got[2] - got[1]);
    try testing.expectEqual(@as(u8, 4), got[4] - got[3]);
    try testing.expectEqual(@as(u8, 4), got[5] - got[4]);

    // What *is* symmetric is the counter itself: a byte incremented once a
    // frame from $01, so the block is gone for the 233 frames between $0D and
    // $F6 and the whole cycle is 253 frames. Nothing measures elapsed time.
    try testing.expectEqual(@as(u8, 233), got[3] - got[2]);
    try testing.expectEqual(@as(u8, 253), got[5] - 1);
}

test "the tile ids a block is drawn with come out of the ROM's own immediates" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    try testing.expectEqual(@as(u8, 0xFF), try loadAt(rom, tile_gone_site));
    try testing.expectEqual(@as(u8, 0x04), try loadAt(rom, tile_crack_a_site));
    try testing.expectEqual(@as(u8, 0x08), try loadAt(rom, tile_crack_b_site));
    try testing.expectEqual(@as(u8, 0x00), try solidTile(rom));

    // Each arm writes four consecutive ids, so the three drawn sets are
    // $00-$03, $04-$07 and $08-$0B and they do not overlap. That is also why
    // `HitBlock`'s `CP $04` can use $00-$03 as "respawning": the four ids the
    // reform draws back are the four ids it tests for.
    try testing.expectEqual(
        try loadAt(rom, tile_crack_a_site),
        try solidTile(rom) + 4,
    );
    try testing.expectEqual(
        try loadAt(rom, tile_crack_b_site),
        try loadAt(rom, tile_crack_a_site) + 4,
    );
    try testing.expectEqual(
        @as(u8, try loadAt(rom, tile_crack_a_site)),
        try compareAt(rom, respawn_ids_site),
    );
}

test "the slot array is one page: sixteen slots of sixteen bytes" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const stride = try addAt(rom, stride_site);
    try testing.expectEqual(@as(u8, 0x10), stride);
    // The walk's terminator is what fixes the count: 01:$567C is `CP $00`, so
    // the array ends when the low byte of the pointer wraps, and the count can
    // only be $100 / stride.
    try testing.expectEqual(@as(u8, 0x00), try compareAt(rom, 0x567C));
    try testing.expectEqual(@as(usize, 16), 0x100 / @as(usize, stride));
}

test "the shot and bomb bits are different bits, and neither is one Samus reads" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const shot = try bitTestAt(rom, shot_bit_site);
    const bomb = try bitTestAt(rom, bomb_bit_site);
    try testing.expectEqual(@as(u3, 5), shot);
    try testing.expectEqual(@as(u3, 6), bomb);
    try testing.expect(shot != bomb);

    // All five of the ROM's bomb arms test the same bit. They are five copies
    // of one routine and a disagreement would mean the address list is wrong.
    for ([_]u16{ 0x5543, 0x5563, 0x5585, 0x55AD, 0x55CF }) |site| {
        try testing.expectEqual(bomb, try bitTestAt(rom, site));
    }

    // And neither is a bit the walking collision reads: water is 0, the two
    // half-solids are 1 and 2, spike 3, spring 4. 00:$1EB5 and 00:$1EC5 are the
    // two of those five the port already had.
    try testing.expectEqual(@as(u3, 0), try bitTestAt(rom, 0x1EB5));
    try testing.expectEqual(@as(u3, 4), try bitTestAt(rom, 0x1EC5));
}

test "the beam's solidity threshold is the row's third byte, and the ROM says so" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    try testing.expectEqual(@as(u8, 2), try beamThresholdColumn(rom));

    // It is not Samus's. If it were, this whole variable would be a second name
    // for `!Solid` and the classification would be checking the wrong thing --
    // so the two are asserted to differ on at least one tileset rather than
    // merely to be read from different columns.
    const e = offsets.find("solidity_thresholds").?;
    const rows = try tileset.parseSolidity(rom[e.romOffset()..e.romEnd()]);
    var differ: usize = 0;
    for (rows) |r| {
        if (r.thresholds[2] != r.thresholds[0]) differ += 1;
    }
    try testing.expect(differ > 0);
}

test "the scroll bias the eviction compares against is the per-frame writer's" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    // The numbers `engine/main.asm` calls `!GB_SCROLL_Y_BIAS` and
    // `!GB_SCROLL_X_BIAS`, out of the routine that writes `scrollY`/`scrollX`
    // once a frame. A third ROM site (00:$04C3, the camera restore) subtracts
    // $78 and $30 instead, and this file names the per-frame one on purpose --
    // taking the other pair is what put every loaded enemy 48 pixels low. See
    // `docs/bug_tracker.md`, 2026-09-09.
    try testing.expectEqual(@as(u8, 0x48), try subAt(rom, scroll_y_bias_site));
    try testing.expectEqual(@as(u8, 0x50), try subAt(rom, scroll_x_bias_site));

    // The room load at 00:$2896 unpacks a stored record and agrees, which is
    // the second of the two sites that do.
    try testing.expectEqual(@as(u8, 0x48), try subAt(rom, 0x2899));
    try testing.expectEqual(@as(u8, 0x50), try subAt(rom, 0x28A4));
}

test "bitTestAt refuses a byte that is not a BIT n,A" {
    // The fault the pinned addresses exist to catch: a shifted address lands on
    // some other opcode, and the reader has to say so rather than return the
    // byte after it.
    const fake = [_]u8{ 0xCB, 0x46, 0x00, 0x3E, 0x04 };
    try testing.expectError(Error.NotTheOpcode, bitTestAt(&fake, 0));
    try testing.expectError(Error.NotTheOpcode, compareAt(&fake, 0));
    // And a site past the end of the buffer, which is what a wrong address on a
    // truncated ROM would be.
    try testing.expectError(Error.NotTheOpcode, loadAt(&fake, 0x40));
}
