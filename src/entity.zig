//! Enemy behaviour tables (bank 3) and metasprite definitions (bank 1).
//!
//! Four parallel enemy tables share one 255-entry id space: per-screen spawn
//! data, headers, damage values, and hitboxes. Two of them are pointer tables
//! of 255 entries; `enemy_damage` is a flat 255 bytes. That the same 255
//! recurs in tables derived independently is what pins the id space down.
//!
//! Metasprites are `$FF`-terminated lists of four-byte parts - y, x, tile,
//! attributes - which is the Game Boy's own OAM entry layout with a signed
//! offset instead of an absolute position. Three sets exist: Samus, enemies,
//! and credits.

const std = @import("std");
const offsets = @import("offsets.zig");

pub const enemy_id_space: usize = 255;

/// One enemy header: nine bytes then a 16-bit field. The fields' meanings are
/// Step 15's problem; extraction only needs the stride, and 11 bytes divides
/// the $23C region into exactly 52 headers.
pub const header_bytes: usize = 11;
pub const Header = struct {
    fields: [9]u8,
    word: u16,
};

/// Four signed bytes. Interpreting them as a box is Step 13's work.
pub const hitbox_bytes: usize = 4;
pub const Hitbox = struct { a: i8, b: i8, c: i8, d: i8 };

// ---- Per-screen spawn records ---------------------------------------------
//
// `enemy_data` is 1792 `$FF`-terminated lists, one per screen, and
// `enemy_data_pointers` is 1792 words naming where each begins. The record is
// four bytes and the field order is the one 03:$422F reads them in: it points
// DE at the *last* byte and walks backwards, `ld a,[de]` for Y, `dec de` for X,
// `dec de` for the sprite type, `dec de` for the spawn number.
//
// The first byte cannot collide with the terminator: it is an index into the
// 128-byte `enemySpawnFlags` array at $C500, and the ROM's own range is $0B to
// $7B. So the walk below is unambiguous, the way the metasprite walk is.

pub const spawn_bytes: usize = 4;

/// Seven map banks of 256 screens: the same 7 x 256 the pointer table's $E00
/// bytes already imply, and `offsets.zig`'s note derives independently.
pub const spawn_banks: usize = 7;
pub const screens_per_bank: usize = 256;
pub const spawn_lists: usize = spawn_banks * screens_per_bank;

/// One spawn record. `number` indexes `enemySpawnFlags`; `sprite` is the enemy
/// id the header, damage and hitbox tables all share; `x` and `y` are the
/// screen-relative position 03:$422F biases by the OAM offsets and the camera.
pub const Spawn = struct {
    number: u8,
    sprite: u8,
    x: u8,
    y: u8,
};

/// One screen's list: the records up to, but not including, the `$FF`.
pub const SpawnList = struct {
    /// GB address of the first record, so a pointer table can be matched to it.
    gb_addr: u16,
    spawns: []Spawn,
    /// Encoded length including the terminator byte.
    encoded_len: usize,
};

/// The blobs the enemy class ships, in the order they are laid down, so a
/// blob's index within the class is its id. Mirrored by `!EN_*_ID` in
/// `engine/main.asm`.
///
/// The headers are here because `loadOneEnemy` (03:$422F) copies nine of their
/// bytes into every slot it fills and takes the AI pointer out of the last two.
/// A spawn walk without them fills a slot with the sprite id and nothing else,
/// which is a slot no later step could grade - so they ship with the walk that
/// reads them rather than with the AI that will dispatch on them.
pub const Which = enum(u8) {
    /// The `$FF`-terminated four-byte spawn records, in the Game Boy's shape.
    data = 0,
    /// Converted pointers: one little-endian byte offset into `data` per
    /// screen, 1792 of them in bank-then-cell order.
    pointers = 1,
    /// The 11-byte headers, in the Game Boy's shape.
    headers = 2,
    /// Converted pointers: one byte offset into `headers` per enemy id, 255 of
    /// them. Every one is in range and 11-aligned; the conversion refuses one
    /// that is not, which is what makes this a check rather than a copy.
    header_pointers = 3,
    /// One damage byte per enemy id, flat: no pointer table, because the id is
    /// the index. `$FF` means solid, `$FE` means it drains, `$00` means
    /// intangible, and anything else is BCD health taken off Samus.
    damage = 4,
    /// The four-signed-byte hitboxes, in the Game Boy's shape.
    hitboxes = 5,
    /// Converted pointers: one little-endian byte offset into `hitboxes` per
    /// enemy id. **254 of the 255 relocate and the last cannot** - id $9A's
    /// entry is $C360, a WRAM address - so that one becomes `dead_pointer` and
    /// the engine refuses it by value rather than reading four bytes of
    /// whatever the region happens to hold there.
    hitbox_pointers = 6,

    /// The `offsets.zig` entry this blob is read from.
    pub fn entry(self: Which) []const u8 {
        return switch (self) {
            .data => "enemy_data",
            .pointers => "enemy_data_pointers",
            .headers => "enemy_headers",
            .header_pointers => "enemy_header_pointers",
            .damage => "enemy_damage",
            .hitboxes => "enemy_hitboxes",
            .hitbox_pointers => "enemy_hitbox_pointers",
        };
    }
};

pub const which_count = @typeInfo(Which).@"enum".fields.len;

/// What a hitbox pointer becomes when it does not name a record in the region.
/// `$FFFF` and not `$0000`, because `$0000` is a real record - the first one -
/// and a sentinel that collides with a valid answer is not a sentinel.
pub const dead_pointer: u16 = 0xFFFF;

/// Walk the region linearly, the way `parseMetasprites` walks its own. The walk
/// is the authority on where a list begins rather than the pointer table, for
/// the same reason: a pointer that lands inside a record rather than on one has
/// to be refusable, and it cannot be if the pointers define the boundaries.
pub fn parseSpawnLists(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    base_gb_addr: u16,
) ![]SpawnList {
    var list: std.ArrayList(SpawnList) = .empty;
    errdefer {
        for (list.items) |l| allocator.free(l.spawns);
        list.deinit(allocator);
    }
    var pos: usize = 0;
    while (pos < bytes.len) {
        const start = pos;
        var recs: std.ArrayList(Spawn) = .empty;
        errdefer recs.deinit(allocator);
        while (true) {
            if (pos >= bytes.len) return Error.UnterminatedSpawnList;
            if (bytes[pos] == terminator) {
                pos += 1;
                break;
            }
            if (pos + spawn_bytes > bytes.len) return Error.UnterminatedSpawnList;
            try recs.append(allocator, .{
                .number = bytes[pos],
                .sprite = bytes[pos + 1],
                .x = bytes[pos + 2],
                .y = bytes[pos + 3],
            });
            pos += spawn_bytes;
        }
        try list.append(allocator, .{
            .gb_addr = base_gb_addr + @as(u16, @intCast(start)),
            .spawns = try recs.toOwnedSlice(allocator),
            .encoded_len = pos - start,
        });
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeSpawnLists(allocator: std.mem.Allocator, lists: []SpawnList) void {
    for (lists) |l| allocator.free(l.spawns);
    allocator.free(lists);
}

/// Re-emit the region, terminators included. `encoded_len` is not consulted,
/// for the reason `encodeMetasprites` gives: the length has to fall out of the
/// records, or the round-trip checks the parser against itself.
pub fn encodeSpawnLists(allocator: std.mem.Allocator, lists: []const SpawnList) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (lists) |l| {
        for (l.spawns) |s| {
            try out.append(allocator, s.number);
            try out.append(allocator, s.sprite);
            try out.append(allocator, s.x);
            try out.append(allocator, s.y);
        }
        try out.append(allocator, terminator);
    }
    return out.toOwnedSlice(allocator);
}

/// One metasprite part, in the GB's OAM order with signed placement.
pub const part_bytes: usize = 4;
pub const terminator: u8 = 0xFF;
pub const Part = struct {
    y: i8,
    x: i8,
    tile: u8,
    attr: u8,
};

pub const Error = error{
    NotHeaderAligned,
    NotHitboxAligned,
    UnterminatedMetasprite,
    UnterminatedSpawnList,
    SpawnListCountMismatch,
};

fn readWord(b: []const u8, at: usize) u16 {
    return @as(u16, b[at]) | (@as(u16, b[at + 1]) << 8);
}

pub fn parseHeaders(allocator: std.mem.Allocator, bytes: []const u8) ![]Header {
    if (bytes.len % header_bytes != 0) return Error.NotHeaderAligned;
    const n = bytes.len / header_bytes;
    const out = try allocator.alloc(Header, n);
    for (0..n) |i| {
        const rec = bytes[i * header_bytes ..][0..header_bytes];
        out[i] = .{ .fields = rec[0..9].*, .word = readWord(rec, 9) };
    }
    return out;
}

pub fn parseHitboxes(allocator: std.mem.Allocator, bytes: []const u8) ![]Hitbox {
    if (bytes.len % hitbox_bytes != 0) return Error.NotHitboxAligned;
    const n = bytes.len / hitbox_bytes;
    const out = try allocator.alloc(Hitbox, n);
    for (0..n) |i| {
        const r = bytes[i * hitbox_bytes ..][0..hitbox_bytes];
        out[i] = .{
            .a = @bitCast(r[0]), .b = @bitCast(r[1]),
            .c = @bitCast(r[2]), .d = @bitCast(r[3]),
        };
    }
    return out;
}

/// One metasprite: the parts up to, but not including, the `$FF` terminator.
pub const Metasprite = struct {
    /// GB address of the first part, so a pointer table can be matched to it.
    gb_addr: u16,
    parts: []Part,
    /// Encoded length including the terminator byte.
    encoded_len: usize,
};

/// Walk a metasprite region linearly. Pointer tables index *into* this walk;
/// a few records in each set are unreferenced, which is why the walk is the
/// authority on where records begin rather than the pointer table.
pub fn parseMetasprites(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    base_gb_addr: u16,
) ![]Metasprite {
    var list: std.ArrayList(Metasprite) = .empty;
    errdefer {
        for (list.items) |m| allocator.free(m.parts);
        list.deinit(allocator);
    }
    var pos: usize = 0;
    while (pos < bytes.len) {
        const start = pos;
        var parts: std.ArrayList(Part) = .empty;
        errdefer parts.deinit(allocator);
        while (true) {
            if (pos >= bytes.len) return Error.UnterminatedMetasprite;
            if (bytes[pos] == terminator) {
                pos += 1;
                break;
            }
            if (pos + part_bytes > bytes.len) return Error.UnterminatedMetasprite;
            try parts.append(allocator, .{
                .y = @bitCast(bytes[pos]),
                .x = @bitCast(bytes[pos + 1]),
                .tile = bytes[pos + 2],
                .attr = bytes[pos + 3],
            });
            pos += part_bytes;
        }
        try list.append(allocator, .{
            .gb_addr = base_gb_addr + @as(u16, @intCast(start)),
            .parts = try parts.toOwnedSlice(allocator),
            .encoded_len = pos - start,
        });
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeMetasprites(allocator: std.mem.Allocator, sprites: []Metasprite) void {
    for (sprites) |m| allocator.free(m.parts);
    allocator.free(sprites);
}

// ---- Encode-back ----------------------------------------------------------

fn writeWord(out: []u8, at: usize, v: u16) void {
    out[at] = @truncate(v);
    out[at + 1] = @truncate(v >> 8);
}

pub fn encodeHeaders(allocator: std.mem.Allocator, hs: []const Header) ![]u8 {
    const out = try allocator.alloc(u8, hs.len * header_bytes);
    for (hs, 0..) |h, i| {
        const rec = out[i * header_bytes ..][0..header_bytes];
        @memcpy(rec[0..9], &h.fields);
        writeWord(rec, 9, h.word);
    }
    return out;
}

pub fn encodeHitboxes(allocator: std.mem.Allocator, hb: []const Hitbox) ![]u8 {
    const out = try allocator.alloc(u8, hb.len * hitbox_bytes);
    for (hb, 0..) |h, i| {
        const rec = out[i * hitbox_bytes ..][0..hitbox_bytes];
        rec[0] = @bitCast(h.a);
        rec[1] = @bitCast(h.b);
        rec[2] = @bitCast(h.c);
        rec[3] = @bitCast(h.d);
    }
    return out;
}

/// Re-emit a metasprite region, terminators included. `encoded_len` is not
/// consulted: the length has to fall out of the parts we actually recorded, or
/// the round-trip would be checking the parser's bookkeeping against itself
/// instead of checking it against the ROM.
pub fn encodeMetasprites(allocator: std.mem.Allocator, sprites: []const Metasprite) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (sprites) |m| {
        for (m.parts) |p| {
            try out.append(allocator, @bitCast(p.y));
            try out.append(allocator, @bitCast(p.x));
            try out.append(allocator, p.tile);
            try out.append(allocator, p.attr);
        }
        try out.append(allocator, terminator);
    }
    return out.toOwnedSlice(allocator);
}

/// The three metasprite sets, each a pointer table plus a data region.
pub const MetaspriteSet = struct {
    name: []const u8,
    pointers: []const u8,
    data: []const u8,
};

pub const metasprite_sets = [_]MetaspriteSet{
    .{ .name = "samus", .pointers = "metasprite_samus_pointers", .data = "metasprite_samus_data" },
    .{ .name = "enemies", .pointers = "metasprite_enemies_pointers", .data = "metasprite_enemies_data" },
    .{ .name = "credits", .pointers = "metasprite_credits_pointers", .data = "metasprite_credits_data" },
};

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "header stride divides the region into whole headers" {
    const e = offsets.find("enemy_headers") orelse return error.Missing;
    try testing.expectEqual(@as(usize, 0), e.size % header_bytes);
    try testing.expectEqual(@as(usize, 52), e.size / header_bytes);

    const gpa = testing.allocator;
    const hs = try parseHeaders(gpa, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x34, 0x12 });
    defer gpa.free(hs);
    try testing.expectEqual(@as(usize, 1), hs.len);
    try testing.expectEqual(@as(u16, 0x1234), hs[0].word);
    try testing.expectEqual(@as(u8, 9), hs[0].fields[8]);
    try testing.expectError(Error.NotHeaderAligned, parseHeaders(gpa, &[_]u8{0} ** 12));
}

test "hitboxes are four signed bytes" {
    const e = offsets.find("enemy_hitboxes") orelse return error.Missing;
    try testing.expectEqual(@as(usize, 0), e.size % hitbox_bytes);
    try testing.expectEqual(@as(usize, 44), e.size / hitbox_bytes);

    const gpa = testing.allocator;
    const hb = try parseHitboxes(gpa, &[_]u8{ 0xF8, 0x08, 0x00, 0xFF });
    defer gpa.free(hb);
    try testing.expectEqual(@as(i8, -8), hb[0].a);
    try testing.expectEqual(@as(i8, 8), hb[0].b);
    try testing.expectEqual(@as(i8, -1), hb[0].d);
}

test "the four enemy tables share one 255-entry id space" {
    const dp = offsets.find("enemy_data_pointers") orelse return error.Missing;
    const hp = offsets.find("enemy_header_pointers") orelse return error.Missing;
    const dm = offsets.find("enemy_damage") orelse return error.Missing;
    const bp = offsets.find("enemy_hitbox_pointers") orelse return error.Missing;
    try testing.expectEqual(enemy_id_space * 2, hp.size);
    try testing.expectEqual(enemy_id_space * 2, bp.size);
    try testing.expectEqual(enemy_id_space, dm.size);
    // The spawn-data pointer table is per screen cell, not per enemy id:
    // 7 map banks x 256 cells x 2 bytes.
    try testing.expectEqual(@as(usize, 7 * 256 * 2), dp.size);
}

test "metasprites terminate on $FF and record their own addresses" {
    const gpa = testing.allocator;
    const bytes = [_]u8{
        0xF8, 0x00, 0x10, 0x20, // part: y=-8 x=0 tile=$10 attr=$20
        0x00, 0x08, 0x11, 0x00,
        0xFF,
        0x04, 0x04, 0x12, 0x00,
        0xFF,
    };
    const ms = try parseMetasprites(gpa, &bytes, 0x408A);
    defer freeMetasprites(gpa, ms);
    try testing.expectEqual(@as(usize, 2), ms.len);
    try testing.expectEqual(@as(usize, 2), ms[0].parts.len);
    try testing.expectEqual(@as(i8, -8), ms[0].parts[0].y);
    try testing.expectEqual(@as(u16, 0x408A), ms[0].gb_addr);
    try testing.expectEqual(@as(usize, 9), ms[0].encoded_len);
    // The second record starts where the first ended, terminator included.
    try testing.expectEqual(@as(u16, 0x408A + 9), ms[1].gb_addr);
    try testing.expectEqual(@as(usize, 1), ms[1].parts.len);
}

test "an unterminated metasprite region is an error, not a partial record" {
    const gpa = testing.allocator;
    try testing.expectError(Error.UnterminatedMetasprite, parseMetasprites(gpa, &[_]u8{ 0, 0, 0, 0 }, 0));
    try testing.expectError(Error.UnterminatedMetasprite, parseMetasprites(gpa, &[_]u8{ 0, 0 }, 0));
}

test "every metasprite set names a pointer table and a data region that exist" {
    for (metasprite_sets) |s| {
        const p = offsets.find(s.pointers) orelse return error.MissingPointers;
        const d = offsets.find(s.data) orelse return error.MissingData;
        try testing.expectEqual(@as(usize, 0), p.size % 2);
        try testing.expectEqual(@as(u8, 1), p.bank);
        try testing.expectEqual(@as(u8, 1), d.bank);
        // Each set's pointer table is immediately followed by its own data.
        try testing.expectEqual(p.romEnd(), d.romOffset());
    }
}

// ---- ROM-dependent derivations --------------------------------------------
//
// The record strides above came from a reference extractor. Region size alone
// does not pin them down - 572 divides by 4, 11, 13, 26, 44, 52 and 143 - so
// they are re-derived here from the pointer tables, which are independent
// evidence: every pointer into a table of fixed-stride records must be an
// exact multiple of that stride from the base.

const testrom = @import("testrom");

/// Strides that divide the region evenly *and* are consistent with every
/// pointer that lands inside it.
fn consistentStrides(
    rom: []const u8,
    ptr_entry: []const u8,
    data_entry: []const u8,
    out: *[64]bool,
) !struct { distinct: usize, out_of_region: usize } {
    const p = offsets.find(ptr_entry) orelse return error.Missing;
    const d = offsets.find(data_entry) orelse return error.Missing;
    const ptrs = rom[p.romOffset()..p.romEnd()];
    const base = d.gb_addr;
    const end = base + @as(u16, @intCast(d.size));

    var seen: std.AutoArrayHashMapUnmanaged(u16, void) = .empty;
    defer seen.deinit(testing.allocator);
    var outside: usize = 0;

    var i: usize = 0;
    while (i + 1 < ptrs.len) : (i += 2) {
        const gb = @as(u16, ptrs[i]) | (@as(u16, ptrs[i + 1]) << 8);
        if (gb >= base and gb < end) {
            try seen.put(testing.allocator, gb, {});
        } else outside += 1;
    }

    for (out, 0..) |*ok, k| {
        if (k == 0) {
            ok.* = false;
            continue;
        }
        ok.* = d.size % k == 0;
        if (!ok.*) continue;
        for (seen.keys()) |gb| {
            if ((gb - base) % k != 0) {
                ok.* = false;
                break;
            }
        }
    }
    return .{ .distinct = seen.count(), .out_of_region = outside };
}

test "the 11-byte header stride is forced by the header pointer table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rom = try testrom.load(arena_state.allocator()) orelse return error.SkipZigTest;

    var ok: [64]bool = undefined;
    const stats = try consistentStrides(rom, "enemy_header_pointers", "enemy_headers", &ok);

    // 11 works, and it is the only stride above 1 that does. Spelling out the
    // rejected divisors is the point: region size alone permits all of them.
    try testing.expect(ok[header_bytes]);
    for ([_]usize{ 2, 4, 13, 22, 26, 44, 52 }) |k| try testing.expect(!ok[k]);
    var above_one: usize = 0;
    for (2..ok.len) |k| above_one += @intFromBool(ok[k]);
    try testing.expectEqual(@as(usize, 1), above_one);

    // 51 of the 52 headers are actually referenced, and every pointer lands
    // inside the region.
    try testing.expectEqual(@as(usize, 51), stats.distinct);
    try testing.expectEqual(@as(usize, 0), stats.out_of_region);
}

test "the 4-byte hitbox stride is consistent with the hitbox pointer table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rom = try testrom.load(arena_state.allocator()) orelse return error.SkipZigTest;

    var ok: [64]bool = undefined;
    const stats = try consistentStrides(rom, "enemy_hitbox_pointers", "enemy_hitboxes", &ok);

    // Weaker than the header case, honestly: 2 also divides every delta, so
    // the pointers narrow the field to {1, 2, 4} rather than to 4 alone. 4 is
    // the largest consistent stride and matches the four signed bytes the
    // records are read as; 8 and 16 are excluded, which is the useful part.
    try testing.expect(ok[hitbox_bytes]);
    for ([_]usize{ 8, 11, 16 }) |k| try testing.expect(!ok[k]);
    var largest: usize = 0;
    for (1..ok.len) |k| {
        if (ok[k]) largest = k;
    }
    try testing.expectEqual(hitbox_bytes, largest);

    // 41 of 44 hitboxes referenced, and one pointer at $C360 - a WRAM address,
    // the same dead-slot pattern as the $C300 metasprite pointer.
    try testing.expectEqual(@as(usize, 41), stats.distinct);
    try testing.expectEqual(@as(usize, 1), stats.out_of_region);
}
