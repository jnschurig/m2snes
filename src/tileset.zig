//! Tileset data: metatiles, collision, and solidity thresholds.
//!
//! Three tables per tileset, all in bank 8, all shape-verified against the
//! retail ROM rather than taken on a label's word (see the tests at the bottom):
//!
//!   * metatiles - 4 bytes per 16x16 metatile, four 8x8 tile ids in TL, TR, BL,
//!     BR order. Seven tilesets get $200 bytes (128 metatiles); the three
//!     lavaCaves variants get $114 (69). `$FF` means "no tile".
//!   * collision - $100 bytes, one behaviour byte per 8x8 tile id.
//!   * solidity  - one shared $20-byte table: eight rows of three thresholds
//!     plus an `$FF` terminator, one row per tileset in collision-table order.

const std = @import("std");
const gfx = @import("gfx.zig");
const offsets = @import("offsets.zig");

pub const metatile_bytes: usize = 4;
pub const collision_bytes: usize = 0x100;
pub const solidity_bytes: usize = 0x20;
pub const solidity_rows: usize = 8;
pub const solidity_row_bytes: usize = 4;

/// The id the tables use for "nothing here". It is a real value in the data,
/// not a terminator: metatiles with a blank half are common (a ledge lip has an
/// empty top row), so parsing must carry it through rather than stop at it.
pub const blank_tile: u8 = 0xFF;

/// One 16x16 metatile as four 8x8 tile ids.
///
/// The TL/TR/BL/BR order is not assumed - it is the arrangement that minimises
/// seam discontinuity across four independent tilesets, beating both the
/// column-major alternative and a scrambled control. See the order test.
pub const Metatile = struct {
    tl: u8,
    tr: u8,
    bl: u8,
    br: u8,

    pub fn get(self: Metatile, col: u1, row: u1) u8 {
        return switch (row) {
            0 => if (col == 0) self.tl else self.tr,
            1 => if (col == 0) self.bl else self.br,
        };
    }
};

pub const Error = error{ NotMetatileAligned, WrongSolidityLength, MissingTerminator };

pub fn parseMetatiles(allocator: std.mem.Allocator, bytes: []const u8) ![]Metatile {
    if (bytes.len % metatile_bytes != 0) return Error.NotMetatileAligned;
    const n = bytes.len / metatile_bytes;
    const out = try allocator.alloc(Metatile, n);
    for (0..n) |i| {
        const q = bytes[i * metatile_bytes ..][0..metatile_bytes];
        out[i] = .{ .tl = q[0], .tr = q[1], .bl = q[2], .br = q[3] };
    }
    return out;
}

/// Three thresholds per tileset. What the engine compares against them is
/// Step 13's business; here we only record that the row is well formed.
pub const Solidity = struct { thresholds: [3]u8 };

pub fn parseSolidity(bytes: []const u8) ![solidity_rows]Solidity {
    if (bytes.len != solidity_bytes) return Error.WrongSolidityLength;
    var out: [solidity_rows]Solidity = undefined;
    for (0..solidity_rows) |r| {
        const row = bytes[r * solidity_row_bytes ..][0..solidity_row_bytes];
        if (row[3] != 0xFF) return Error.MissingTerminator;
        out[r] = .{ .thresholds = .{ row[0], row[1], row[2] } };
    }
    return out;
}

/// The inverse of `parseMetatiles`. `$FF` is data here, not a terminator, so it
/// comes back out exactly where it went in.
pub fn encodeMetatiles(allocator: std.mem.Allocator, mts: []const Metatile) ![]u8 {
    const out = try allocator.alloc(u8, mts.len * metatile_bytes);
    for (mts, 0..) |m, i| {
        const q = out[i * metatile_bytes ..][0..metatile_bytes];
        q[0] = m.tl;
        q[1] = m.tr;
        q[2] = m.bl;
        q[3] = m.br;
    }
    return out;
}

/// The inverse of `parseSolidity`. The terminator is re-emitted rather than
/// carried in the struct: `parseSolidity` refuses a row that does not end in
/// `$FF`, so writing one back is reconstruction, not invention.
pub fn encodeSolidity(rows: [solidity_rows]Solidity) [solidity_bytes]u8 {
    var out: [solidity_bytes]u8 = @splat(0);
    for (rows, 0..) |r, i| {
        const row = out[i * solidity_row_bytes ..][0..solidity_row_bytes];
        row[0] = r.thresholds[0];
        row[1] = r.thresholds[1];
        row[2] = r.thresholds[2];
        row[3] = 0xFF;
    }
    return out;
}

/// The tileset index a door script's `COLLISION` operand selects. `SOLIDITY`
/// indexes the rows at 8:$7EFA with the same number, which is why one order
/// serves both.
///
/// Derived from the ROM, not from bank 8's layout. That distinction is the
/// whole point here, because the two disagree: this list was previously written
/// as layout order, which puts finalLab first, and finalLab is actually last.
/// Every door script issuing `COLLISION $n` loads exactly one tileset's
/// graphics -- all eight slots pinned, by between 3 and 27 scripts each, with
/// no operand ever pairing with two tilesets.
///
/// The solidity rows agree without touching the door scripts at all, though
/// they cannot settle it on their own. A row's first three bytes are thresholds
/// on an 8x8 **tile id**, not on a metatile index: `samus_getTileIndex`
/// (00:1FF5) reaches the tilemap through `getTilemapAddress` (00:22BC), which
/// indexes $9800 at 8-pixel granularity. Row 5 thresholds at 66, and lavaCaves
/// is the one tileset whose graphics stop short of 128 tiles - it has 83 - so
/// row 5 is the only row low enough to be about it. Layout order would give
/// lavaCaves row 6, whose 100 is past the end of its 83 tiles, which is how the
/// error was caught.
///
/// The limit of the argument: row 2 thresholds at $F0, past the end of any
/// tileset, so a row is plainly not obliged to fit inside the one it belongs
/// to. The door scripts are what pin the order; this only agrees with them.
pub const tileset_order = [solidity_rows][]const u8{
    "plantBubbles", "ruinsInside", "queen",     "caveFirst",
    "surface",      "lavaCaves",   "ruinsExt",  "finalLab",
};

/// Which graphics, collision, and metatile entries belong together.
///
/// The mapping is many-to-one in two places and the names do not line up on
/// their own: the queen tileset's graphics entry is `gfx_queenBG` and the
/// surface's is `gfx_surfaceBG`, and lavaCaves has three graphics variants and
/// three metatile variants against a single collision table. Spelling it out
/// here keeps the extractor from guessing.
pub const Tileset = struct {
    name: []const u8,
    gfx: []const []const u8,
    collision: []const u8,
    metatiles: []const []const u8,
};

pub const tilesets = [_]Tileset{
    .{ .name = "plantBubbles", .gfx = &.{"gfx_plantBubbles"}, .collision = "collision_plantBubbles", .metatiles = &.{"metatiles_plantBubbles"} },
    .{ .name = "ruinsInside", .gfx = &.{"gfx_ruinsInside"}, .collision = "collision_ruinsInside", .metatiles = &.{"metatiles_ruinsInside"} },
    .{ .name = "queen", .gfx = &.{"gfx_queenBG"}, .collision = "collision_queen", .metatiles = &.{"metatiles_queen"} },
    .{ .name = "caveFirst", .gfx = &.{"gfx_caveFirst"}, .collision = "collision_caveFirst", .metatiles = &.{"metatiles_caveFirst"} },
    .{ .name = "surface", .gfx = &.{"gfx_surfaceBG"}, .collision = "collision_surface", .metatiles = &.{"metatiles_surface"} },
    .{
        .name = "lavaCaves",
        .gfx = &.{ "gfx_lavaCavesA", "gfx_lavaCavesB", "gfx_lavaCavesC" },
        .collision = "collision_lavaCaves",
        .metatiles = &.{ "metatiles_lavaCavesMid", "metatiles_lavaCavesEmpty", "metatiles_lavaCavesFull" },
    },
    .{ .name = "ruinsExt", .gfx = &.{"gfx_ruinsExt"}, .collision = "collision_ruinsExt", .metatiles = &.{"metatiles_ruinsExt"} },
    .{ .name = "finalLab", .gfx = &.{"gfx_finalLab"}, .collision = "collision_finalLab", .metatiles = &.{"metatiles_finalLab"} },
};

/// Bytes for a named offsets-table entry.
pub fn slice(rom: []const u8, name: []const u8) ?[]const u8 {
    const e = offsets.find(name) orelse return null;
    if (e.romEnd() > rom.len) return null;
    return rom[e.romOffset()..e.romEnd()];
}

/// Which of the eight collision tables a door script's `COLLISION` operand
/// selects, as an index into `tilesets`.
///
/// **The operand is not the table's position in the region.** The op's handler
/// at 00:$2859 banks in 8 and then reads a pointer out of `collision_pointers`:
/// `LD A,(HL+) / AND $0F / SLA A / LD HL,$7EEA / ADD HL,DE`. The region is laid
/// out with `finalLab` first and the other seven in operand order after it, so
/// an engine that treats the operand as a position in the region walks every
/// room in the game through its neighbour's block-type bytes. It cost Step 15 a
/// false divergence: `COLLISION $6` gave the cart `lavaCaves` where the
/// original had `ruinsExt`, `lavaCaves` marks a floor tile of the segment's
/// room as water, and `WalkSpeed` refuses to alternate while `!Water` is set.
///
/// **Through 2026-09-07 this returned a rotation, and that was a defect in
/// `offsets.zig` rather than a fact about the ROM.** The eight names were each
/// attached to the address one slot below the table they name, and resolving by
/// address absorbed the error exactly -- so the carts were right and the
/// diagnostics that print a table's name were wrong. With the addresses
/// corrected this returns the identity, and a test asserts that it does.
/// Deriving it is still what keeps that true rather than assumed.
///
/// Returns null if a pointer names an address no collision entry begins at.
pub fn collisionOrder(rom: []const u8) ?[tilesets.len]u8 {
    const ptrs = slice(rom, "collision_pointers") orelse return null;
    var out: [tilesets.len]u8 = @splat(0);
    for (0..tilesets.len) |operand| {
        const addr = std.mem.readInt(u16, ptrs[operand * 2 ..][0..2], .little);
        var found: ?u8 = null;
        for (tilesets, 0..) |ts, i| {
            const e = offsets.find(ts.collision) orelse return null;
            if (e.bank == 0x8 and e.gb_addr == addr) found = @intCast(i);
        }
        out[operand] = found orelse return null;
    }
    return out;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "metatile parsing is exactly four ids in TL TR BL BR order" {
    const gpa = testing.allocator;
    const mts = try parseMetatiles(gpa, &[_]u8{ 1, 2, 3, 4, 0xFF, 0xFF, 5, 6 });
    defer gpa.free(mts);
    try testing.expectEqual(@as(usize, 2), mts.len);
    try testing.expectEqual(Metatile{ .tl = 1, .tr = 2, .bl = 3, .br = 4 }, mts[0]);
    try testing.expectEqual(@as(u8, blank_tile), mts[1].tl);
    try testing.expectEqual(@as(u8, 5), mts[1].get(0, 1));
    try testing.expectEqual(@as(u8, 6), mts[1].get(1, 1));
    try testing.expectError(Error.NotMetatileAligned, parseMetatiles(gpa, &[_]u8{ 1, 2, 3 }));
}

test "solidity rows must terminate in $FF" {
    var bytes: [solidity_bytes]u8 = @splat(0);
    for (0..solidity_rows) |r| bytes[r * 4 + 3] = 0xFF;
    bytes[0] = 0x69;
    const rows = try parseSolidity(&bytes);
    try testing.expectEqual(@as(u8, 0x69), rows[0].thresholds[0]);

    bytes[7] = 0x00; // break row 1's terminator
    try testing.expectError(Error.MissingTerminator, parseSolidity(&bytes));
    try testing.expectError(Error.WrongSolidityLength, parseSolidity(bytes[0..8]));
}

test "every tileset names entries that exist, with the sizes the format implies" {
    var seen_collision: usize = 0;
    for (tilesets) |ts| {
        const c = offsets.find(ts.collision) orelse return error.MissingCollision;
        try testing.expectEqual(collision_bytes, c.size);
        seen_collision += 1;
        for (ts.gfx) |g| {
            const e = offsets.find(g) orelse return error.MissingGfx;
            try testing.expectEqual(@as(usize, 0), e.size % gfx.tile_bytes);
        }
        for (ts.metatiles) |m| {
            const e = offsets.find(m) orelse return error.MissingMetatiles;
            try testing.expectEqual(@as(usize, 0), e.size % metatile_bytes);
        }
    }
    // One collision table per solidity row, and the two orders must agree.
    try testing.expectEqual(solidity_rows, seen_collision);
    try testing.expectEqual(solidity_rows, tilesets.len);
    for (tilesets, tileset_order) |ts, name| try testing.expectEqualStrings(name, ts.name);
}

test "the eight collision tables tile one gapless region, finalLab first" {
    // Ascending and gapless as a *set*, which is what the region is. Not in
    // `tileset_order`: the block's physical order is `finalLab` and then the
    // other seven in operand order, and asserting the two orders were the same
    // is what let the addresses sit one slot out until 2026-09-08.
    var addrs: [tilesets.len]usize = undefined;
    for (tileset_order, 0..) |name, i| {
        const buf = try std.fmt.allocPrint(testing.allocator, "collision_{s}", .{name});
        defer testing.allocator.free(buf);
        const e = offsets.find(buf) orelse return error.MissingCollision;
        addrs[i] = e.romOffset();
    }
    const first = offsets.find("collision_finalLab") orelse return error.MissingCollision;
    std.mem.sort(usize, &addrs, {}, std.sort.asc(usize));
    try testing.expectEqual(first.romOffset(), addrs[0]);
    for (addrs[1..], 1..) |at, i| try testing.expectEqual(addrs[i - 1] + collision_bytes, at);
}

// ---- ROM-dependent derivations --------------------------------------------
//
// These are the two facts about this data that no label could establish for us,
// so they are re-derived from the ROM every time the suite runs. They skip when
// no ROM is configured rather than passing vacuously.

const testrom = @import("testrom");
const save = @import("save.zig");

/// Total seam mismatch for one (tile graphics, metatile table) pairing under a
/// given interpretation of the four bytes.
fn seamCost(tiles: []const gfx.Tile, mt: []const u8, order: [4]u2) struct { cost: u64, n: usize } {
    var cost: u64 = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i + metatile_bytes <= mt.len) : (i += metatile_bytes) {
        const q = mt[i..][0..metatile_bytes];
        var ok = true;
        for (q) |v| {
            if (v == blank_tile or v >= tiles.len) ok = false;
        }
        if (!ok) continue; // a blank half has no seam to judge
        n += 1;
        const t = [4]gfx.Tile{
            tiles[q[order[0]]], tiles[q[order[1]]],
            tiles[q[order[2]]], tiles[q[order[3]]],
        };
        cost += gfx.seamH(t[0], t[1]) + gfx.seamH(t[2], t[3]) +
            gfx.seamV(t[0], t[2]) + gfx.seamV(t[1], t[3]);
    }
    return .{ .cost = cost, .n = n };
}

test "the game's own new game names the surface tileset's tables, and the operand order is the identity" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    // `initial_save` is the record `createNewSave` copies into `saveBuffer`
    // before game mode $02 reads it, and the landing site it describes -- map
    // bank $0F, cell $76 -- is the surface. So the two source pointers in it
    // are the surface tileset's own tables, stated by the game rather than
    // inferred by us, and they are the only statement of that fact this
    // repository has that does not come from the door scripts.
    const init = save.initial(rom) orelse return error.NoInitialSave;
    const metatiles = offsets.find("metatiles_surface") orelse return error.MissingMetatiles;
    const collision = offsets.find("collision_surface") orelse return error.MissingCollision;
    try testing.expectEqual(metatiles.gb_addr, init.tiletable_src);
    try testing.expectEqual(collision.gb_addr, init.collision_src);

    // And the consequence, which is the thing that was wrong: a `COLLISION`
    // operand is an index into `tilesets`, full stop. `collisionOrder` derives
    // it from the ROM's own pointer table, so a labelling that puts each table
    // one slot from where the game keeps it comes back here as a rotation --
    // which is exactly how it read until 2026-09-08. See `docs/bug_tracker.md`.
    const order = collisionOrder(rom) orelse return error.NoCollisionOrder;
    for (order, 0..) |ts_index, operand| {
        testing.expectEqual(@as(u8, @intCast(operand)), ts_index) catch |err| {
            std.debug.print(
                "COLLISION ${X} selects {s}, not {s}\n",
                .{ operand, tilesets[ts_index].collision, tilesets[operand].collision },
            );
            return err;
        };
    }
}

test "metatile bytes are TL TR BL BR: row-major beats column-major and a control" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    // Four single-variant tilesets. lavaCaves is excluded on purpose: its three
    // graphics variants are near-identical, so it carries almost no signal.
    const cases = [_]struct { g: []const u8, m: []const u8 }{
        .{ .g = "gfx_plantBubbles", .m = "metatiles_plantBubbles" },
        .{ .g = "gfx_ruinsInside", .m = "metatiles_ruinsInside" },
        .{ .g = "gfx_caveFirst", .m = "metatiles_caveFirst" },
        .{ .g = "gfx_surfaceBG", .m = "metatiles_surface" },
    };

    var row_major: u64 = 0;
    var col_major: u64 = 0;
    var control: u64 = 0;
    var total_n: usize = 0;

    for (cases) |c| {
        const tiles = try gfx.decodeAll(arena, slice(rom, c.g) orelse return error.MissingGfx);
        const mt = slice(rom, c.m) orelse return error.MissingMetatiles;
        // Read as TL TR / BL BR, as TL BL / TR BR, and as a deliberately
        // scrambled pairing that should be no better than chance.
        const a = seamCost(tiles, mt, .{ 0, 1, 2, 3 });
        const b = seamCost(tiles, mt, .{ 0, 2, 1, 3 });
        const c3 = seamCost(tiles, mt, .{ 0, 3, 2, 1 });
        row_major += a.cost;
        col_major += b.cost;
        control += c3.cost;
        total_n += a.n;
        // Per-tileset, not just in aggregate - one dominant tileset must not be
        // able to carry a wrong conclusion for the rest.
        try testing.expect(a.cost < b.cost);
    }

    try testing.expect(total_n > 150);
    try testing.expect(row_major < col_major);
    // The real check: column-major is not merely worse, it is worse than a
    // scrambled control, which is what "this reading is meaningless" looks like.
    try testing.expect(row_major < control);
    try testing.expect(col_major > control);
}

test "lavaCaves variant naming: the table at 8:$5480 is the intermediate state" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    const mid = slice(rom, "metatiles_lavaCavesMid") orelse return error.MissingMetatiles;
    const empty = slice(rom, "metatiles_lavaCavesEmpty") orelse return error.MissingMetatiles;
    const full = slice(rom, "metatiles_lavaCavesFull") orelse return error.MissingMetatiles;

    // Count metatiles that differ, not bytes: one changed tile id is one
    // changed metatile however many of its four bytes moved.
    const diff = struct {
        fn f(x: []const u8, y: []const u8) usize {
            var n: usize = 0;
            var i: usize = 0;
            while (i + metatile_bytes <= @min(x.len, y.len)) : (i += metatile_bytes) {
                if (!std.mem.eql(u8, x[i..][0..metatile_bytes], y[i..][0..metatile_bytes])) n += 1;
            }
            return n;
        }
    }.f;

    const mid_empty = diff(mid, empty);
    const mid_full = diff(mid, full);
    const empty_full = diff(empty, full);

    // Three states of a draining lava room. The two endpoints must be the
    // furthest apart, and the intermediate one must be closer to each endpoint
    // than they are to each other. Only $5480 satisfies that, which is what
    // makes M2RoS's Mid/Empty/Full labels right and a positional
    // Full/Mid/Empty reading of the ROM order wrong.
    try testing.expect(empty_full > mid_empty);
    try testing.expect(empty_full > mid_full);
    try testing.expect(mid_empty + mid_full >= empty_full);
}

test "a COLLISION operand selects a table through the ROM's pointer table, not by its own value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rom = try testrom.load(arena) orelse return error.SkipZigTest;
    const order = collisionOrder(rom) orelse return error.TestUnexpectedResult;

    // Every table is reachable and none twice: the mapping is a permutation, so
    // reordering the converted blobs by it loses nothing and duplicates nothing.
    var seen: [tilesets.len]bool = @splat(false);
    for (order) |i| {
        try testing.expect(i < tilesets.len);
        try testing.expect(!seen[i]);
        seen[i] = true;
    }

    // And the thing this test exists to refute is still refuted, but it is
    // about the *region* and not about `tilesets`. An operand is a tileset
    // index -- the assertion for that lives with the new-game record above --
    // and it is emphatically not a position in the region: `collision_finalLab`
    // is physically first and its operand is $7. An engine that DMA'd the
    // operand'th $100 bytes of the class would walk every room in the game
    // through its neighbour's block-type bytes, which is the divergence Step 15
    // spent a day on.
    var by_position: [tilesets.len]usize = undefined;
    for (order, 0..) |ts_index, operand| {
        by_position[operand] = (offsets.find(tilesets[ts_index].collision) orelse
            return error.MissingCollision).romOffset();
    }
    var ascending = true;
    for (by_position[1..], 1..) |at, i| {
        if (at < by_position[i - 1]) ascending = false;
    }
    try testing.expect(!ascending);

    // The pointer table stops where the solidity rows begin. An operand of $8
    // would read `solidity_thresholds` as a pointer, so the region's size is
    // load-bearing rather than decorative.
    const ptrs = offsets.find("collision_pointers").?;
    const sol = offsets.find("solidity_thresholds").?;
    try testing.expectEqual(sol.romOffset(), ptrs.romEnd());
}
