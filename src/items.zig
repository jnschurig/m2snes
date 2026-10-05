//! The sixteen item names, and the constants the item mechanism is built from.
//!
//! ## What the block actually is, which is not what the offsets table said
//!
//! The entry read "names begin at 01:5911 with 16 pointers ... ends at 01:5AB1,
//! giving $1A0 bytes", and both halves were wrong in the same direction: it
//! started 32 bytes *after* the pointer table and ran 160 bytes *past* the
//! strings into code. Three independent statements of the real shape, which is
//! the porting loop's step 0 - ask what else in the ROM knows this:
//!
//!   * **The pointer table at 01:$58F1** holds sixteen little-endian addresses
//!     and they are $5911, $5921, ... $5A01 - sixteen bytes apart, exactly, all
//!     sixteen. A block whose strings were any other width could not produce
//!     that run.
//!   * **The far end is code, not data.** 01:$5A11 is `FA 26 C4 A7 C8 21 00 C6`
//!     - `ld a,[$C426] / and a / ret z / ld hl,$C600` - which is `drawEnemies`
//!     reading `numEnemies.active` and pointing at the slot array. M2RoS labels
//!     it `drawEnemies: ;{ 01:5A11`; the bytes say so without the label.
//!   * **The font says what a byte means.** `gfx_itemFont` (05:$6C34, $200
//!     bytes, 32 tiles) drawn out is 'A' at tile 0, 'B' at 1, ... 'Z' at 25.
//!     So a string byte is `$C0 + tile`, and that is a fact about the
//!     *graphics*, arrived at without reading a single string.
//!
//! So the class is 01:$58F1, $120 bytes: a 32-byte pointer table and sixteen
//! 16-byte fixed-width strings. The pointers are **reconstructed** on the way
//! back out, from the string index alone - which is what makes this an
//! `.encoding` round-trip rather than a `.framing` one, and what makes a
//! misread width fail it.
//!
//! ## The two bytes that are not letters
//!
//! `$DE` and `$DF` follow " SAVE" and nothing else uses them. Rendered, they
//! are two halves of one decorative rule - tile 30 is `..##...#` and tile 31 is
//! `#...##..`, which abut into a dashed line. M2RoS charmaps them `<` and `>`
//! and this keeps those spellings so the two sources can be diffed, but they
//! are a drawn rule and not punctuation. `$FF` is the space.
//!
//! ## What the names are used for
//!
//! The `ITEM` door opcode carries an index into this table in its low nibble,
//! and **that is the whole of what the opcode does** - see `Id` below.

const std = @import("std");

/// The block's shape, all three numbers taken from the ROM above.
pub const count: usize = 16;
pub const name_len: usize = 16;
pub const pointer_bytes: usize = count * 2;
pub const block_bytes: usize = pointer_bytes + count * name_len;

pub const space: u8 = 0xFF;
pub const letter_base: u8 = 0xC0;
/// The two halves of the rule after " SAVE", in ROM order.
pub const rule_left: u8 = 0xDE;
pub const rule_right: u8 = 0xDF;

pub const Error = error{
    ShortBlock,
    /// A pointer that does not land on the string its index names. The whole
    /// point of keeping the table is that this can be checked.
    PointerMismatch,
    /// A byte the font has no glyph for.
    UnknownCharacter,
    /// A name that is not exactly `name_len` characters, on the way back in.
    BadNameLength,
};

/// One byte of a name, as text. Letters are themselves; the rule's two halves
/// keep M2RoS's `<` and `>`; the space is a space.
pub fn decodeChar(b: u8) !u8 {
    if (b == space) return ' ';
    if (b == rule_left) return '<';
    if (b == rule_right) return '>';
    if (b >= letter_base and b <= letter_base + 25) return 'A' + (b - letter_base);
    return Error.UnknownCharacter;
}

pub fn encodeChar(c: u8) !u8 {
    if (c == ' ') return space;
    if (c == '<') return rule_left;
    if (c == '>') return rule_right;
    if (c >= 'A' and c <= 'Z') return letter_base + (c - 'A');
    return Error.UnknownCharacter;
}

/// The sixteen names, decoded. `text[i]` is exactly `name_len` characters
/// including the padding spaces the ROM stores, because the padding is what
/// centres the name in the window and dropping it would make the re-encode a
/// guess about where it went.
pub const Names = struct {
    /// The Game Boy address the block was read from, kept because the pointers
    /// are absolute and cannot be rebuilt without it.
    base: u16,
    text: [count][name_len]u8,

    /// The name with its padding spaces trimmed, for a report to print.
    ///
    /// By pointer, not by value: the result aliases `text`, and a by-value
    /// receiver would hand back a slice into a copy that dies on return. That
    /// is not a style note - it is what the first run of the test below found,
    /// as an empty string where "ICE BEAM" should have been.
    pub fn trimmed(self: *const Names, i: usize) []const u8 {
        return std.mem.trim(u8, &self.text[i], " ");
    }
};

/// Parse the block at `gb_addr`. `bytes` is the whole $120-byte class.
pub fn parseNames(bytes: []const u8, gb_addr: u16) !Names {
    if (bytes.len < block_bytes) return Error.ShortBlock;

    var out: Names = .{ .base = gb_addr, .text = undefined };
    for (0..count) |i| {
        const ptr = @as(u16, bytes[i * 2]) | (@as(u16, bytes[i * 2 + 1]) << 8);
        const want = gb_addr + @as(u16, @intCast(pointer_bytes + i * name_len));
        if (ptr != want) return Error.PointerMismatch;
        const at = pointer_bytes + i * name_len;
        for (0..name_len) |j| out.text[i][j] = try decodeChar(bytes[at + j]);
    }
    return out;
}

/// Re-emit the block: the pointer table rebuilt from the base and the index,
/// then the strings re-encoded a character at a time.
pub fn encodeNames(allocator: std.mem.Allocator, n: Names) ![]u8 {
    const out = try allocator.alloc(u8, block_bytes);
    errdefer allocator.free(out);
    for (0..count) |i| {
        const ptr = n.base + @as(u16, @intCast(pointer_bytes + i * name_len));
        out[i * 2] = @truncate(ptr);
        out[i * 2 + 1] = @truncate(ptr >> 8);
        const at = pointer_bytes + i * name_len;
        for (0..name_len) |j| out[at + j] = try encodeChar(n.text[i][j]);
    }
    return out;
}

// ---------------------------------------------------------------------------
// The item space itself
// ---------------------------------------------------------------------------

/// The `ITEM` opcode's operand, and the index into the name table.
///
/// **The opcode gives nothing.** 00:$2634's arm loads four graphics blobs -
/// the item's four tiles, the orb, the item font and this name - and walks on.
/// Every `samusItems` bit is set by `handleItemPickup` (00:$372F), which a
/// *sprite* reaches by touching Samus. So `!ItemGiven` is a record of a room
/// having been decorated, and it is not the pickup: the two were one sub-task
/// in the plan and they are two mechanisms in the ROM.
pub const Id = enum(u4) {
    save = 0x0,
    plasma_beam = 0x1,
    ice_beam = 0x2,
    wave_beam = 0x3,
    spazer = 0x4,
    bomb = 0x5,
    screw_attack = 0x6,
    varia = 0x7,
    high_jump = 0x8,
    space_jump = 0x9,
    spider_ball = 0xA,
    spring_ball = 0xB,
    energy_tank = 0xC,
    missile_tank = 0xD,
    energy_refill = 0xE,
    missile_refill = 0xF,
};

/// `itemCollected`, which is **not** `Id`: it is one-based and starts at the
/// plasma beam, because a save station is not a thing a sprite hands over. The
/// dispatch at 00:$37C4 is `dec a` and then a fifteen-entry jump table, so
/// `Collected.plasma_beam` = 1 is `Id.plasma_beam` = 1 by coincidence of the
/// save station occupying `Id` slot 0 and nothing occupying this one.
pub const Collected = enum(u8) {
    plasma_beam = 0x01,
    ice_beam = 0x02,
    wave_beam = 0x03,
    spazer = 0x04,
    bomb = 0x05,
    screw_attack = 0x06,
    varia = 0x07,
    high_jump = 0x08,
    space_jump = 0x09,
    spider_ball = 0x0A,
    spring_ball = 0x0B,
    energy_tank = 0x0C,
    missile_tank = 0x0D,
    energy_refill = 0x0E,
    missile_refill = 0x0F,
};

/// `samusItems` bit numbers, from M2RoS SRC/constants.asm. Bit 7 is unused.
pub const bit_bomb: u3 = 0;
pub const bit_hi_jump: u3 = 1;
pub const bit_screw: u3 = 2;
pub const bit_space: u3 = 3;
pub const bit_spring: u3 = 4;
pub const bit_spider: u3 = 5;
pub const bit_varia: u3 = 6;

/// The two the B11 recording actually collects, confirmed by the trace rather
/// than inherited from the constants file: `$D045` goes `$00`->`$01` at frame
/// 44 329 and `$01`->`$21` at 68 453. See `docs/slice.md`.
pub const mask_bomb: u8 = 1 << bit_bomb;
pub const mask_spider: u8 = 1 << bit_spider;

/// `SPRITE_ITEM_BASE_ID`. Orbs have even ids and items odd ones, and
/// `enAI_itemOrb`'s loop at 02:$4E6B converts one to the other:
/// `collected = (sprite - $81)/2 + 1`.
pub const sprite_item_base: u8 = 0x81;
pub const sprite_energy_refill: u8 = 0x9B;
pub const sprite_missile_refill: u8 = 0x9D;

/// The sprite-id-to-item-number formula, written as the loop the ROM runs
/// rather than as the division its comment claims, because an odd id that is
/// not in range walks off the end of the loop in the original and this says so.
pub fn collectedFor(sprite: u8) ?Collected {
    if (sprite < sprite_item_base or sprite % 2 == 0) return null;
    const n = (sprite - sprite_item_base) / 2 + 1;
    if (n > 0x0F) return null;
    return @enumFromInt(n);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a character survives the round trip, and an unknown byte is refused" {
    for ([_]u8{ 0xC0, 0xD9, 0xDE, 0xDF, 0xFF }) |b| {
        try testing.expectEqual(b, try encodeChar(try decodeChar(b)));
    }
    // $DA-$DD are real font tiles - the period, comma, apostrophe and dash -
    // and no name uses them, so the codec refuses them rather than inventing a
    // spelling that could not be checked against anything.
    try testing.expectError(Error.UnknownCharacter, decodeChar(0xDA));
    try testing.expectError(Error.UnknownCharacter, decodeChar(0x00));
    try testing.expectError(Error.UnknownCharacter, encodeChar('a'));
}

test "a pointer that does not name its own string is refused" {
    var buf = [_]u8{0} ** block_bytes;
    for (0..count) |i| {
        const ptr: u16 = 0x58F1 + @as(u16, @intCast(pointer_bytes + i * name_len));
        buf[i * 2] = @truncate(ptr);
        buf[i * 2 + 1] = @truncate(ptr >> 8);
    }
    @memset(buf[pointer_bytes..], space);
    _ = try parseNames(&buf, 0x58F1);

    // Move one pointer by a single byte. A `.framing` reading - one that
    // carried the pointer bytes through verbatim - would not notice.
    buf[6] +%= 1;
    try testing.expectError(Error.PointerMismatch, parseNames(&buf, 0x58F1));
}

test "the sprite id maps to the item number the ROM's own loop produces" {
    try testing.expectEqual(Collected.plasma_beam, collectedFor(0x81).?);
    try testing.expectEqual(Collected.bomb, collectedFor(0x89).?);
    try testing.expectEqual(Collected.spider_ball, collectedFor(0x93).?);
    try testing.expectEqual(Collected.energy_refill, collectedFor(sprite_energy_refill).?);
    try testing.expectEqual(Collected.missile_refill, collectedFor(sprite_missile_refill).?);
    // Even ids are orbs, not items.
    try testing.expectEqual(@as(?Collected, null), collectedFor(0x82));
    try testing.expectEqual(@as(?Collected, null), collectedFor(0x9F));
}

const testrom = @import("testrom");
const offsets = @import("offsets.zig");

test "the sixteen names are the sixteen the game shows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    const e = offsets.find("item_names") orelse return error.Missing;
    const n = try parseNames(rom[e.romOffset()..e.romEnd()], e.gb_addr);

    // Spelled out rather than derived: this is the one place the reading is
    // checked against something a person can read, and a table generated from
    // the decoder would agree with any decoder.
    const want = [count][]const u8{
        "SAVE<>",     "PLASMA BEAM", "ICE BEAM",    "WAVE BEAM",
        "SPAZER",     "BOMB",        "SCREW ATTACK", "VARIA",
        "HIGH JUMP BOOTS", "SPACE JUMP", "SPIDER BALL", "SPRING BALL",
        "ENERGY TANK", "MISSILE TANK", "ENERGY",     "MISSILES",
    };
    for (want, 0..) |w, i| try testing.expectEqualStrings(w, n.trimmed(i));
}

test "the block ends where drawEnemies begins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    const e = offsets.find("item_names") orelse return error.Missing;
    try testing.expectEqual(@as(usize, block_bytes), e.size);

    // `drawEnemies` at 01:$5A11, identified by its own first instructions and
    // not by a label: `ld a,[$C426] / and a / ret z / ld hl,$C600`.
    const after = rom[e.romEnd()..][0..8];
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFA, 0x26, 0xC4, 0xA7, 0xC8, 0x21, 0x00, 0xC6 }, after);
}

// ---------------------------------------------------------------------------
// Which bit is which item, taken from the cartridge rather than from a
// constants file.
//
// `handleItemPickup`'s `RST $28` table at 00:$379A holds fifteen arms, one per
// item number, and seven of them are `ld a,[samusItems] / set n,a /
// ld [samusItems],a`. **That is the ROM stating the bit assignment outright**,
// and it is the only statement of it this repository can check: M2RoS's
// `itemBit_*` names are a transcription, and so was the copy of them that sat
// in `engine/main.asm` with two of the six wrong.
//
// The bit comes out of the opcode. `SET n,A` is `$CB $C7 + n*8`, so
// `n = (op - $C7) / 8`, and a byte that is not one of the eight is refused
// rather than folded into a plausible number.
// ---------------------------------------------------------------------------

/// 00:$379A, the fifteen-entry jump table `RST $28` dispatches through.
pub const arm_table: u16 = 0x379A;
pub const arm_count: usize = 15;
/// `ld a,[samusItems]` / `ld [samusItems],a`, the two ends of a bit set.
const load_items = [_]u8{ 0xFA, 0x45, 0xD0 };
const store_items = [_]u8{ 0xEA, 0x45, 0xD0 };

pub const BitError = error{ ArmNotFound, NotASetInstruction, DuplicateBit };

/// One item's equipment bit, or null for an item that sets none - the four
/// beams, the two tanks and the two refills all leave `samusItems` alone.
pub fn bitFor(rom: []const u8, item: Collected) !?u3 {
    // Bank 0 is not paged, so a Game Boy address in it is a ROM offset.
    var arms: [arm_count]u16 = undefined;
    for (0..arm_count) |i| {
        const at = @as(usize, arm_table) + i * 2;
        arms[i] = @as(u16, rom[at]) | (@as(u16, rom[at + 1]) << 8);
    }

    const me = arms[@intFromEnum(item) - 1];
    // The arms are not in table order in the ROM - the missile tank sits after
    // the two refills - so an arm's far end is the next arm *by address*, not
    // the next entry.
    var end: usize = 0x3A01; // `handleItemPickup_end`, which every arm jumps to
    for (arms) |a| {
        if (a > me and a < end) end = a;
    }
    if (me >= end) return BitError.ArmNotFound;

    var at: usize = me;
    while (at + 8 <= end) : (at += 1) {
        if (!std.mem.eql(u8, rom[at..][0..3], &load_items)) continue;
        if (rom[at + 3] != 0xCB) continue;
        if (!std.mem.eql(u8, rom[at + 5 ..][0..3], &store_items)) continue;
        const op = rom[at + 4];
        if (op < 0xC7 or op > 0xFF or (op - 0xC7) % 8 != 0) return BitError.NotASetInstruction;
        return @intCast((op - 0xC7) / 8);
    }
    return null;
}

test "the cartridge's own pickup arms name every equipment bit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    // Seven items set a bit and eight do not, and every bit 0-6 is used once.
    var seen = [_]bool{false} ** 8;
    var set_count: usize = 0;
    inline for (@typeInfo(Collected).@"enum".fields) |f| {
        const item: Collected = @field(Collected, f.name);
        if (try bitFor(rom, item)) |b| {
            try testing.expect(!seen[b]);
            seen[b] = true;
            set_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 7), set_count);
    for (0..7) |i| try testing.expect(seen[i]);
    try testing.expect(!seen[7]); // `itemBit_UNUSED`

    // And the two the recording actually collects, which `docs/slice.md`
    // measured independently: `$D045` goes $00->$01 on the Bomb and $01->$21
    // on the Spider Ball, so bomb is bit 0 and spider is bit 5.
    try testing.expectEqual(@as(u3, bit_bomb), (try bitFor(rom, .bomb)).?);
    try testing.expectEqual(@as(u3, bit_spider), (try bitFor(rom, .spider_ball)).?);
    try testing.expectEqual(@as(u3, bit_spring), (try bitFor(rom, .spring_ball)).?);
    try testing.expectEqual(@as(u3, bit_hi_jump), (try bitFor(rom, .high_jump)).?);
    try testing.expectEqual(@as(u3, bit_screw), (try bitFor(rom, .screw_attack)).?);
    try testing.expectEqual(@as(u3, bit_space), (try bitFor(rom, .space_jump)).?);
    try testing.expectEqual(@as(u3, bit_varia), (try bitFor(rom, .varia)).?);

    // The four beams set no bit at all; they write `samusBeam` instead.
    try testing.expectEqual(@as(?u3, null), try bitFor(rom, .plasma_beam));
    try testing.expectEqual(@as(?u3, null), try bitFor(rom, .energy_tank));
}
