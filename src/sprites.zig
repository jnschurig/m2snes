//! What Samus looks like: the pose-to-sprite mapping, and the metasprite set
//! the engine walks into OAM.
//!
//! The mapping is mostly code. `drawSamus` (01:4BD9) builds a nibble-swapped
//! byte out of the facing direction and the d-pad, dispatches on `samusPose`
//! through a table of *code* pointers, and each `drawSamus_*` routine decides
//! for itself how to turn that byte into a sprite id. That dispatch is logic
//! and gets reimplemented in 65816. What is data - and so what this module
//! carries - is the little `db SPRITE_SAMUS_*` tables four of those routines
//! index, plus the metasprite set every sprite id ultimately names.
//!
//! The metasprite records stay in the Game Boy's own shape: four bytes per
//! part - y, x, tile, attributes - terminated by `$FF`. Turning a part into a
//! SNES OAM entry is the engine's job rather than the converter's, because the
//! two biases that come off (`OAM_X_OFS`, `OAM_Y_OFS`) and the two window
//! offsets that go on are properties of where the play field sits on a 256x224
//! frame, not properties of the sprite. Converting here would bake a screen
//! layout into the asset region and make a wider view a re-extraction.
//!
//! The pointer table does change: the ROM's entries are absolute bank-1
//! addresses, and what survives into the cart is a byte offset into the data
//! blob. That is the one conversion, and it is why `parsePointers` takes the
//! two addresses it needs to check the answer against.

const std = @import("std");
const offsets = @import("offsets.zig");
const entity = @import("entity.zig");

pub const Error = error{
    /// A pose sprite-id table whose length is not a whole number of rows.
    NotRowAligned,
    /// A samus pointer that does not address the samus metasprite data. All 69
    /// in the retail ROM do; one that does not means the pointer table and the
    /// data region were not read at the addresses `offsets.zig` claims, and
    /// guessing an offset for it would hide exactly that.
    PointerOutsideData,
    /// A samus pointer that lands mid-record. The pointer table is checked
    /// against a linear walk of the data, so this catches an off-by-one in
    /// either address rather than only in the pointer.
    PointerNotOnRecord,
};

// ---------------------------------------------------------------------------
// The pose sprite-id tables.
//
// Most of them are rows of four ids, for four different reasons.
// `drawSamus_jump` and `drawSamus_standing` index sixteen entries with the
// facing/d-pad byte, which is four vertical rows of four facings. The spin
// tables are two four-frame animations. The running tables are three
// input-selected tables of two four-entry rows each, where the fourth entry of
// each row is padding the animation counter never reaches. The ball and spider
// tables Step 11 pinned are two four-frame animations apiece, the same shape as
// the spin.
//
// **The knockback table is the exception and it is a real one.**
// `drawSamus_knockback` (01:$4C59) indexes 01:$4C69 by the facing byte and
// nothing else, so the table is two ids and there is no fourth column for it to
// have. A parser that insisted on four would have to either refuse the table or
// read two bytes of the routine after it as data, and both of those are worse
// than saying the width out loud.
//
// The width is therefore what the round trip proves: a table read at the wrong
// stride re-encodes to the same bytes only if the stride divides evenly, and
// none of these lengths admits a second divisor that is also a plausible row.
// ---------------------------------------------------------------------------

pub const row_ids: usize = 4;
/// The knockback pair: one row of two, indexed by facing alone.
pub const facing_pair: usize = 2;

/// A pose sprite-id table with the width its own reader steps by.
pub const PoseTable = struct {
    row: usize,
    ids: []u8,

    pub fn rows(self: PoseTable) usize {
        return self.ids.len / self.row;
    }

    /// Row `i`, which is what a draw routine indexes into.
    pub fn at(self: PoseTable, i: usize) []const u8 {
        return self.ids[i * self.row ..][0..self.row];
    }
};

/// The width a table of this length is read at. Two only for a table that is
/// exactly the facing pair; every longer one is fours.
pub fn rowWidthFor(len: usize) !usize {
    if (len == facing_pair) return facing_pair;
    if (len == 0 or len % row_ids != 0) return Error.NotRowAligned;
    return row_ids;
}

pub fn parsePoseTable(allocator: std.mem.Allocator, bytes: []const u8) !PoseTable {
    const row = try rowWidthFor(bytes.len);
    return .{ .row = row, .ids = try allocator.dupe(u8, bytes) };
}

pub fn encodePoseTable(allocator: std.mem.Allocator, t: PoseTable) ![]u8 {
    const out = try allocator.alloc(u8, t.rows() * t.row);
    for (0..t.rows()) |i| @memcpy(out[i * t.row ..][0..t.row], t.at(i));
    return out;
}

// ---------------------------------------------------------------------------
// The pointer table.
// ---------------------------------------------------------------------------

/// A converted pointer: a byte offset into the metasprite data blob.
pub const Offset = u16;

/// Turn the ROM's absolute bank-1 pointers into offsets into `data`.
///
/// `starts` is the set of record starts a linear walk of the data found, and
/// every pointer has to hit one. That check is the reason this takes a walk at
/// all rather than just subtracting a base: subtracting always produces *an*
/// answer, and an answer that lands three bytes into a four-byte part would
/// draw garbage on the console and nothing anywhere else.
/// The offset a dead pointer converts to. `$FFFF` cannot be a real one: both
/// data blobs are far shorter than 64 KiB, so no record can live at that offset.
pub const dead_offset: Offset = 0xFFFF;

/// Where the cartridge parks a sprite id that has no record: a WRAM address.
/// **Enemy id $9A is the only one in either set**, and it is the same id
/// `entity.dead_pointer` covers in the *hitbox* table -- one dead slot, named
/// twice by two different tables, which is what makes this a fact about the ROM
/// rather than a tolerance widened until the data fit through it. A pointer
/// that is outside the data and *not* in WRAM is still refused.
const gb_wram_lo: u16 = 0xC000;
const gb_wram_hi: u16 = 0xE000;

pub fn parsePointers(
    allocator: std.mem.Allocator,
    table: []const u8,
    data_gb_addr: u16,
    data_len: usize,
    records: []const entity.Metasprite,
) ![]Offset {
    const n = table.len / 2;
    const out = try allocator.alloc(Offset, n);
    errdefer allocator.free(out);
    for (0..n) |i| {
        const ptr = @as(u16, table[i * 2]) | (@as(u16, table[i * 2 + 1]) << 8);
        if (ptr < data_gb_addr or ptr >= data_gb_addr + data_len) {
            if (ptr < gb_wram_lo or ptr >= gb_wram_hi) return Error.PointerOutsideData;
            out[i] = dead_offset;
            continue;
        }
        const off = ptr - data_gb_addr;
        var found = false;
        for (records) |r| {
            if (r.gb_addr == ptr) {
                found = true;
                break;
            }
        }
        if (!found) return Error.PointerNotOnRecord;
        out[i] = off;
    }
    return out;
}

pub fn encodePointers(allocator: std.mem.Allocator, table: []const Offset) ![]u8 {
    const out = try allocator.alloc(u8, table.len * 2);
    for (table, 0..) |v, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], v, .little);
    return out;
}

// ---------------------------------------------------------------------------
// Blob ids.
//
// The order is the interface between `snes_convert` and `engine/main.asm`'s
// `!MS_*` constants: a blob's id is its index here, so adding one means
// appending, never inserting - the same rule `physics.Which` runs under.
// ---------------------------------------------------------------------------

pub const Which = enum(u8) {
    /// Converted pointers: one little-endian byte offset into `samus_data`
    /// per sprite id.
    samus_pointers = 0,
    /// The `$FF`-terminated four-byte part lists, in the Game Boy's shape.
    samus_data = 1,
    pose_jump = 2,
    pose_spin = 3,
    pose_standing = 4,
    pose_running = 5,
    /// The enemy set, converted exactly as Samus's is. Extracted and
    /// round-tripped since Step 4 and **not shipped into the cart until the
    /// enemies needed drawing**, which is the whole of why they were invisible:
    /// the slots were filled, walked, collided against and damaged, and no blob
    /// in the cart held a part list for any of them.
    enemies_pointers = 6,
    enemies_data = 7,
    /// The credits set, `drawNonGameSprite`'s (01:$73F7): the title's menu
    /// since Step 24h. Converted as the other two are.
    credits_pointers = 8,
    credits_data = 9,

    /// The `offsets.zig` entry this blob is read from.
    pub fn entry(self: Which) []const u8 {
        return switch (self) {
            .samus_pointers => "metasprite_samus_pointers",
            .samus_data => "metasprite_samus_data",
            .pose_jump => "pose_sprites_jump",
            .pose_spin => "pose_sprites_spin",
            .pose_standing => "pose_sprites_standing",
            .pose_running => "pose_sprites_running",
            .enemies_pointers => "metasprite_enemies_pointers",
            .enemies_data => "metasprite_enemies_data",
            .credits_pointers => "metasprite_credits_pointers",
            .credits_data => "metasprite_credits_data",
        };
    }
};

pub const which_count = @typeInfo(Which).@"enum".fields.len;

// ---------------------------------------------------------------------------
// Where a sprite id comes from, for the six poses Phase 0a reaches.
//
// These four numbers are the row a `drawSamus_*` routine indexes, restated here
// so `snes_romtest` can predict what the cart should be showing without
// re-deriving the dispatch. The two poses with no table - the crouch and the
// jump start - load an immediate, and those immediates are here for the same
// reason.
// ---------------------------------------------------------------------------

/// The facing/d-pad byte `drawSamus` builds: the d-pad nibble swapped down,
/// with bit 0 set for facing right and bit 1 for facing left.
pub fn facingIndex(facing_right: bool, up: bool, down: bool) u8 {
    var v: u8 = if (facing_right) 0x01 else 0x02;
    if (up) v |= 0x04;
    if (down) v |= 0x08;
    return v;
}

/// `drawSamus_jumpStart`: run frame 1, whichever way she faces.
pub const jump_start_right: u8 = 0x03;
pub const jump_start_left: u8 = 0x10;
/// The turnaround, which `drawSamus` sends to `drawSamus_faceScreen`.
pub const face_screen: u8 = 0x00;
/// `drawSamus_crouch`.
pub const crouch_right: u8 = 0x0B;
pub const crouch_left: u8 = 0x18;


/// Every sprite id the six draw routines Phase 0a reaches can produce: the four
/// pinned tables' contents, the four immediates the crouch and the jump start
/// load, and the front-facing sprite the turnaround draws.
///
/// This exists so a claim about "the sprites Phase 0a draws" can be checked
/// rather than asserted. The whole samus set contains parts the port does not
/// handle yet - eleven of them ask to be drawn behind the background - and
/// which of those matter is exactly the question this answers.
pub fn reachableIds(allocator: std.mem.Allocator, rom: []const u8) ![]u8 {
    var seen = std.AutoArrayHashMapUnmanaged(u8, void){};
    defer seen.deinit(allocator);

    for ([_]Which{ .pose_jump, .pose_spin, .pose_standing, .pose_running }) |w| {
        const e = offsets.find(w.entry()) orelse return error.UnresolvedSource;
        for (rom[e.romOffset()..e.romEnd()]) |id| try seen.put(allocator, id, {});
    }
    for ([_]u8{
        face_screen,
        jump_start_right, jump_start_left,
        crouch_right,     crouch_left,
    }) |id| try seen.put(allocator, id, {});

    return allocator.dupe(u8, seen.keys());
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a pose table round-trips through rows of four" {
    const bytes = [_]u8{ 0x00, 0x09, 0x16, 0x00, 0x00, 0x0A, 0x17, 0x00 };
    const t = try parsePoseTable(testing.allocator, &bytes);
    defer testing.allocator.free(t.ids);
    try testing.expectEqual(@as(usize, 4), t.row);
    try testing.expectEqual(@as(usize, 2), t.rows());
    try testing.expectEqualSlices(u8, bytes[4..8], t.at(1));
    const back = try encodePoseTable(testing.allocator, t);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, &bytes, back);
}

test "the knockback pair is one row of two, not a refused table" {
    // 01:$4C69 is `16 09`, and `drawSamus_knockback` indexes it by facing
    // alone. Reading it at four would either refuse it or swallow two bytes of
    // `drawSamus_spider`.
    const t = try parsePoseTable(testing.allocator, &[_]u8{ 0x16, 0x09 });
    defer testing.allocator.free(t.ids);
    try testing.expectEqual(facing_pair, t.row);
    try testing.expectEqual(@as(usize, 1), t.rows());
}

test "a table that is not a whole number of rows is refused" {
    try testing.expectError(Error.NotRowAligned, parsePoseTable(testing.allocator, &[_]u8{ 1, 2, 3 }));
    try testing.expectError(Error.NotRowAligned, parsePoseTable(testing.allocator, &.{}));
    // Six is not two rows of three and not one and a half rows of four: only
    // the exact facing pair gets the narrow width.
    try testing.expectError(Error.NotRowAligned, parsePoseTable(testing.allocator, &[_]u8{ 1, 2, 3, 4, 5, 6 }));
}

test "the facing index is the byte drawSamus builds" {
    // The two sixteen-entry tables put the plain right-facing sprite at 1 and
    // the left at 2, and aiming up four entries further along.
    try testing.expectEqual(@as(u8, 0x01), facingIndex(true, false, false));
    try testing.expectEqual(@as(u8, 0x02), facingIndex(false, false, false));
    try testing.expectEqual(@as(u8, 0x05), facingIndex(true, true, false));
    try testing.expectEqual(@as(u8, 0x0A), facingIndex(false, false, true));
}

test "pointers become offsets, and a pointer off a record boundary is refused" {
    const base: u16 = 0x408A;
    const records = [_]entity.Metasprite{
        .{ .gb_addr = 0x408A, .parts = &.{}, .encoded_len = 9 },
        .{ .gb_addr = 0x4093, .parts = &.{}, .encoded_len = 5 },
    };
    const good = [_]u8{ 0x8A, 0x40, 0x93, 0x40 };
    const offs = try parsePointers(testing.allocator, &good, base, 0x20, &records);
    defer testing.allocator.free(offs);
    try testing.expectEqualSlices(Offset, &[_]Offset{ 0x0000, 0x0009 }, offs);

    // What comes back out is the offsets, not the addresses that went in: the
    // pointer table is the one thing here that is genuinely converted, so its
    // round trip is `offsets.zig`'s `metasprite_pointers` framing check on the
    // Game Boy bytes, and this is the conversion on top of it.
    const back = try encodePointers(testing.allocator, offs);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x09, 0x00 }, back);

    // One byte into the first record: inside the data, but not a record start.
    const midRecord = [_]u8{ 0x8B, 0x40 };
    try testing.expectError(
        Error.PointerNotOnRecord,
        parsePointers(testing.allocator, &midRecord, base, 0x20, &records),
    );
    // And a WRAM address, which is what a dead slot looks like: it converts to
    // `dead_offset` rather than being refused, because the enemy set has one and
    // the engine has to be handed something it can refuse at draw time. **The
    // tolerance is exactly this wide**: an address outside the data that is not
    // in WRAM is still an error, which the case below is.
    const wram = [_]u8{ 0x00, 0xC3 };
    const dead = try parsePointers(testing.allocator, &wram, base, 0x20, &records);
    defer testing.allocator.free(dead);
    try testing.expectEqualSlices(Offset, &[_]Offset{dead_offset}, dead);

    const elsewhere = [_]u8{ 0x00, 0x70 }; // $7000: still ROM, still not the data
    try testing.expectError(
        Error.PointerOutsideData,
        parsePointers(testing.allocator, &elsewhere, base, 0x20, &records),
    );
}

test "every Which names an entry that exists, and the ids are dense" {
    for (0..which_count) |i| {
        const w: Which = @enumFromInt(i);
        try testing.expect(offsets.find(w.entry()) != null);
        try testing.expectEqual(@as(u8, @intCast(i)), @intFromEnum(w));
    }
}

test "no sprite the reachable poses name asks to be drawn behind the background" {
    // The *record's* behind-background bit, on the ids `reachableIds` says are
    // reachable. Eleven parts elsewhere in the set have it, in poses Phase 0a
    // cannot enter. **This is not whether she is drawn behind**, and Step 24e
    // is why that needs saying: `drawSamusSprite` sets the bit on every part
    // on the screens whose transition word has bit 11 (01:$4BA1), whatever the
    // record holds, so this test passed the whole time she stood in front of
    // the ship. That rule is `room.zig`'s and `correspond.zig`'s to check.
    // Since 24e the bit is honoured either way: play-field words carry BG3's
    // priority bit, and OBJ priority 0 goes under it.
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);

    const ids = try reachableIds(testing.allocator, rom);
    defer testing.allocator.free(ids);
    try testing.expect(ids.len > 30);

    const data = offsets.find("metasprite_samus_data").?;
    const ptrs = offsets.find("metasprite_samus_pointers").?;
    const bytes = rom[data.romOffset()..data.romEnd()];
    const records = try entity.parseMetasprites(testing.allocator, bytes, data.gb_addr);
    defer entity.freeMetasprites(testing.allocator, records);

    const behind_bg: u8 = 0x80;
    var checked: usize = 0;
    for (ids) |id| {
        try testing.expect(id * 2 + 1 < ptrs.size);
        const gb = @as(u16, rom[ptrs.romOffset() + id * 2]) | (@as(u16, rom[ptrs.romOffset() + id * 2 + 1]) << 8);
        for (records) |r| {
            if (r.gb_addr != gb) continue;
            for (r.parts) |part| {
                try testing.expectEqual(@as(u8, 0), part.attr & behind_bg);
                // And no part of a reachable sprite may reach past the sheet
                // the engine uploads: `gfx_samusPowerSuit` is $B00 bytes, which
                // is 176 characters, and the tiles above that belong to sheets
                // no door script on this path loads.
                try testing.expect(part.tile < 0xB00 / 16);
            }
            checked += 1;
            break;
        }
    }
    try testing.expectEqual(ids.len, checked);
}

// ---------------------------------------------------------------------------
// The three tables Step 11 pinned, and the engine constants they replace.
//
// `pose_sprites_knockback`, `pose_sprites_spider` and `pose_sprites_morph` are
// not converted into the cart: nothing on it reads them. The knockback and the
// ball are drawn from immediates in `SamusSpriteId`, which is what
// `drawSamus_knockback` amounts to and what two consecutive four-frame runs
// amount to; the spider has no pose handler until Phase 1.
//
// What the pinning buys, therefore, is not data on the cart. It is that those
// immediates stop being numbers someone typed: the test below reads them out of
// the assembled engine's symbol table and compares them against the cartridge.
// ---------------------------------------------------------------------------

test "the spider table is the same shape as the ball's, and is read by nothing yet" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    // `drawSamus_spider` indexes it exactly as `drawSamus_morph` indexes its
    // own, so two runs of four consecutive ids is a property the port will rely
    // on the day Phase 1 gives the spider ball a pose - and asserting it now is
    // what makes "pinned but ungraded" a statement about the *handler* rather
    // than about the table.
    const e = offsets.find("pose_sprites_spider") orelse return error.Missing;
    const t = try parsePoseTable(arena, rom[e.romOffset()..e.romEnd()]);
    try testing.expectEqual(@as(usize, 2), t.rows());
    for (0..2) |row| {
        for (1..row_ids) |i| {
            try testing.expectEqual(t.at(row)[i - 1] + 1, t.at(row)[i]);
        }
    }

    // And nothing on the cart reads it: `snes_convert` converts the four tables
    // `Which` names, and this is not one of them. If it ever becomes one, this
    // line is where the claim above stops being true.
    for (0..which_count) |i| {
        const w: Which = @enumFromInt(i);
        try testing.expect(!std.mem.eql(u8, w.entry(), "pose_sprites_spider"));
    }
}

test "every pose the original dispatches has a pinned table or a named immediate" {
    // `samus_drawJumpTable` (01:$4C1D) sends all thirty poses to eight
    // routines. Four of the eight index a table Step 13a pinned, three index
    // one Step 11 pinned, and the crouch, the jump start and the face-screen
    // load immediates that are constants above. So the pose id space is
    // covered, which is what closed `offsets.pending`.
    var covered: usize = 0;
    for ([_][]const u8{
        "pose_sprites_jump",  "pose_sprites_spin",
        "pose_sprites_standing", "pose_sprites_running",
        "pose_sprites_knockback", "pose_sprites_spider",
        "pose_sprites_morph",
    }) |name| {
        _ = offsets.find(name) orelse return error.Missing;
        covered += 1;
    }
    try testing.expectEqual(@as(usize, 7), covered);
    try testing.expectEqual(@as(usize, 0), offsets.pending.len);
}

const testrom = @import("testrom");

test "the only pointer in either set that names no record is the dead one" {
    // The tolerance above is one entry wide and this is what keeps it that way.
    // Samus's set has none at all, so shipping the enemy set changed nothing
    // about hers; the enemy set has exactly one, at id $9A, and it is the same
    // id `entity.dead_pointer` covers in the hitbox table.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const sets = [_]struct { ptrs: []const u8, data: []const u8, dead: usize }{
        .{ .ptrs = "metasprite_samus_pointers", .data = "metasprite_samus_data", .dead = 0 },
        .{ .ptrs = "metasprite_enemies_pointers", .data = "metasprite_enemies_data", .dead = 1 },
    };
    for (sets) |set| {
        const de = offsets.find(set.data) orelse return error.Missing;
        const pe = offsets.find(set.ptrs) orelse return error.Missing;
        const data_gb = rom[de.romOffset()..de.romEnd()];
        const records = try entity.parseMetasprites(a, data_gb, de.gb_addr);
        defer entity.freeMetasprites(a, records);
        const offs = try parsePointers(a, rom[pe.romOffset()..pe.romEnd()], de.gb_addr, data_gb.len, records);
        defer a.free(offs);
        var dead: usize = 0;
        var dead_at: usize = 0;
        for (offs, 0..) |o, i| if (o == dead_offset) {
            dead += 1;
            dead_at = i;
        };
        try testing.expectEqual(set.dead, dead);
        if (set.dead == 1) try testing.expectEqual(@as(usize, 0x9A), dead_at);
    }
}
