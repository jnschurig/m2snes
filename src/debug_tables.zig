//! 1.0 Step 4 (C8b): the two lists the debug menu's METROIDS and FLAGS pages
//! show, built from the ROM by `roster.zig` and shipped as the `debug` class.
//!
//! Both are **saved-half spawn records**: a spawn number of $40 or more, whose
//! flag goes out to the save buffer when a bank is left (02:$418C) and so
//! outlives the room. The other records' flags are cleared on every room entry,
//! so there is nothing for a menu to keep for them.
//!
//!   * **METROIDS** is `roster.metroids` in playthrough order (`playthrough`,
//!     1.0 Step 26): the order the 100% recording kills them in, numbered so,
//!     and the WARP page's METROID ROOMS with it. 46 records, and the Queen
//!     makes 47. She is the last row (1.0 Step 10, so the count can reach zero
//!     from the menu). She has no spawn record, so her header is `queen_bank`,
//!     which no record has, and the engine reads her state off the count.
//!   * **FLAGS** is every other saved-half record: item orbs, missile doors
//!     and blocks, Arachnus, the stinger and the baby (James, 2026-09-27).
//!     Metroids are left to their own page, whose kill keeps the counts with
//!     the flag.
//!
//! A blob is a count byte and then `entry_bytes` per entry: the map bank
//! ($09-$0F), the cell, the spawn number, and a label of at most `label_max`
//! characters, zero-padded. The label is drawn by the menu's `DebugChar`, so
//! every character is one it draws (`drawable`).

const std = @import("std");
const offsets = @import("offsets.zig");
const roster = @import("roster.zig");
const items = @import("items.zig");
const warp = @import("warp.zig");

/// Blob ids within the class, as the engine's `!DEBUG_BLOB_*` mirror them.
/// The four `warp_*` lists are the WARP page's (1.0 Step 5b), and
/// `warp_data` is what their rows run.
pub const Which = enum(u8) { metroids = 0, flags = 1, warp_saves = 2, warp_items = 3, warp_metroids = 4, warp_queen = 5, warp_data = 6, larvae = 7 };

/// The WARP page's four lists, in its order.
pub const warp_lists = [_]Which{ .warp_saves, .warp_items, .warp_metroids, .warp_queen };

/// The first spawn number of the saved half: 02:$418C clears $C500-$C53F and
/// copies $C540-$C57F.
pub const saved_first: u8 = 0x40;

pub const label_max: usize = 20;
pub const header_bytes: usize = 3;
pub const entry_bytes: usize = header_bytes + label_max + 1;

pub const Error = error{
    /// A saved-half record whose AI has no name here: the ROM has one the
    /// list does not know how to call.
    UnnamedRecord,
    /// An item orb whose item id is not an item.
    NotAnItem,
    LabelTooLong,
    Undrawable,
    /// Not one `enAI_metroidStinger` record, or not its `ADD A,d8`.
    StingerNotUnique,
    /// `playthrough` is not `roster.metroids` reordered.
    NotThePlaythrough,
};

/// Every character the menu's `DebugChar` draws as itself; anything else it
/// draws as a blank, which a label must not rely on.
pub fn drawable(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == ' ' or
        c == '-' or c == '.' or c == ':' or c == '>';
}

fn species(ai: u16) []const u8 {
    return switch (ai) {
        0x6BB2 => "HATCHING",
        0x6C44 => "ALPHA",
        0x6F60 => "GAMMA",
        0x7276 => "ZETA",
        0x7631 => "OMEGA",
        0x7A4F => "LARVAL",
        else => unreachable, // `roster.metroids` holds only these
    };
}

/// `roster.areaName`'s quarter, as two letters.
fn quarter(cell: u8) []const u8 {
    const north = cell >> 4 < 8;
    const west = cell & 0x0F < 8;
    return if (north) (if (west) "NW" else "NE") else (if (west) "SW" else "SE");
}

fn put(out: []u8, r: roster.Record, label: []const u8) Error!void {
    if (label.len > label_max) return Error.LabelTooLong;
    for (label) |c| if (!drawable(c)) return Error.Undrawable;
    @memset(out, 0);
    out[0] = r.bank;
    out[1] = r.cell;
    out[2] = r.number;
    @memcpy(out[header_bytes..][0..label.len], label);
}

/// The Queen's row's bank: no spawn record has it (banks are $09-$0F), and
/// the engine's `DebugFlagGet` takes it for her.
pub const queen_bank: u8 = 0x00;

/// One Metroid of the 100% recording's kills (`docs/phase1.md`, 1.0 Step 24a):
/// its record's bank and spawn number, and the cell the count fell in. The
/// record is the one nearest that cell; a test holds each to it.
pub const Kill = struct { bank: u8, number: u8, cell: u8 };

/// The METROIDS page's and the WARP page's Metroid order (James, 2026-09-27;
/// 1.0 Step 26): the recording's kills 1-47 less #9, which is #8 again after
/// part 06's death. #48 is the Queen.
pub const playthrough = [_]Kill{
    .{ .bank = 0xF, .number = 0x41, .cell = 0x10 }, .{ .bank = 0xE, .number = 0x49, .cell = 0x07 },
    .{ .bank = 0xB, .number = 0x50, .cell = 0xBE }, .{ .bank = 0xB, .number = 0x52, .cell = 0xC9 },
    .{ .bank = 0xB, .number = 0x51, .cell = 0xC4 }, .{ .bank = 0xB, .number = 0x40, .cell = 0x23 },
    .{ .bank = 0xD, .number = 0x45, .cell = 0x93 }, .{ .bank = 0xD, .number = 0x44, .cell = 0x76 },
    .{ .bank = 0xD, .number = 0x46, .cell = 0x04 }, .{ .bank = 0xB, .number = 0x54, .cell = 0xDF },
    .{ .bank = 0xB, .number = 0x53, .cell = 0xD9 }, .{ .bank = 0xB, .number = 0x56, .cell = 0xEC },
    .{ .bank = 0xB, .number = 0x55, .cell = 0xE5 }, .{ .bank = 0xC, .number = 0x41, .cell = 0x38 },
    .{ .bank = 0xE, .number = 0x46, .cell = 0x85 }, .{ .bank = 0xE, .number = 0x47, .cell = 0xA3 },
    .{ .bank = 0xE, .number = 0x48, .cell = 0xB3 }, .{ .bank = 0xB, .number = 0x46, .cell = 0xA8 },
    .{ .bank = 0xB, .number = 0x4F, .cell = 0xAB }, .{ .bank = 0xB, .number = 0x43, .cell = 0x39 },
    .{ .bank = 0xB, .number = 0x44, .cell = 0x3B }, .{ .bank = 0xC, .number = 0x40, .cell = 0x88 },
    .{ .bank = 0xB, .number = 0x41, .cell = 0x2E }, .{ .bank = 0xB, .number = 0x45, .cell = 0x45 },
    .{ .bank = 0xA, .number = 0x41, .cell = 0x36 }, .{ .bank = 0xA, .number = 0x40, .cell = 0x17 },
    .{ .bank = 0xB, .number = 0x47, .cell = 0x57 }, .{ .bank = 0xE, .number = 0x4A, .cell = 0x08 },
    .{ .bank = 0xA, .number = 0x45, .cell = 0xF8 }, .{ .bank = 0xE, .number = 0x45, .cell = 0x3A },
    .{ .bank = 0xA, .number = 0x44, .cell = 0xF5 }, .{ .bank = 0xB, .number = 0x42, .cell = 0x00 },
    .{ .bank = 0xB, .number = 0x4E, .cell = 0x04 }, .{ .bank = 0xB, .number = 0x49, .cell = 0x66 },
    .{ .bank = 0xB, .number = 0x4C, .cell = 0x8E }, .{ .bank = 0xF, .number = 0x40, .cell = 0xE1 },
    .{ .bank = 0xB, .number = 0x4A, .cell = 0x75 }, .{ .bank = 0xF, .number = 0x43, .cell = 0xB0 },
    .{ .bank = 0xE, .number = 0x44, .cell = 0x32 }, .{ .bank = 0xD, .number = 0x43, .cell = 0x42 },
    .{ .bank = 0xD, .number = 0x42, .cell = 0x33 }, .{ .bank = 0xD, .number = 0x41, .cell = 0x23 },
    .{ .bank = 0xE, .number = 0x42, .cell = 0x05 }, .{ .bank = 0xE, .number = 0x41, .cell = 0x03 },
    .{ .bank = 0xD, .number = 0x47, .cell = 0x00 }, .{ .bank = 0xD, .number = 0x40, .cell = 0x10 },
};

/// A Metroid's METROIDS row (0-based), by its record's bank and spawn number.
pub fn rowOf(comptime bank: u8, comptime number: u8) usize {
    return comptime for (playthrough, 0..) |k, i| {
        if (k.bank == bank and k.number == number) break i;
    } else @compileError("not a Metroid of the playthrough");
}

/// `roster.metroids` in `playthrough`'s order. Refused unless the two are the
/// same 46 records.
pub fn menuMetroids(a: std.mem.Allocator, rom: []const u8) ![]roster.Metroid {
    const list = try roster.metroids(a, rom);
    if (list.len != playthrough.len) return Error.NotThePlaythrough;
    const out = try a.alloc(roster.Metroid, list.len);
    for (playthrough, out) |k, *o| {
        o.* = for (list) |m| {
            if (m.bank == k.bank and m.number == k.number) break m;
        } else return Error.NotThePlaythrough;
    }
    return out;
}

pub fn metroidsBlob(a: std.mem.Allocator, rom: []const u8) ![]u8 {
    const list = try menuMetroids(a, rom);
    const n = list.len + 1;
    const out = try a.alloc(u8, 1 + n * entry_bytes);
    out[0] = @intCast(n);
    var buf: [label_max + 8]u8 = undefined;
    for (list, 0..) |m, i| {
        const label = std.fmt.bufPrint(&buf, "{d:0>2} {X}:{X:0>2} {s} {s}", .{ i + 1, m.bank, m.cell, quarter(m.cell), species(m.ai) }) catch return Error.LabelTooLong;
        try put(out[1 + i * entry_bytes ..][0..entry_bytes], m, label);
    }
    const label = std.fmt.bufPrint(&buf, "{d:0>2} QUEEN", .{n}) catch return Error.LabelTooLong;
    try put(out[1 + list.len * entry_bytes ..][0..entry_bytes], .{ .bank = queen_bank, .cell = 0, .number = 0, .sprite = 0, .x = 0, .y = 0, .ai = 0 }, label);
    return out;
}

/// 1.0 Step 10: what the METROIDS page needs to keep `metroidCountDisplayed`
/// as the original keeps it. Until the final area the status bar's count
/// leaves the larval Metroids out: `enAI_metroidStinger` (02:$6B83) adds them,
/// `ADD A,$08` at 02:$6B92, the first time it runs, and its flag keeps it from
/// running again. The larval kill (02:$7B32) takes one off both counts, but
/// a larva cannot be reached before the stinger has run. So a larva killed or
/// revived from the menu moves the displayed count only once the stinger's
/// flag is dead; without this, all 46 killed took $39 down to $93.
///
/// The blob: the stinger's map bank and spawn number, the `ADD`'s operand,
/// the METROIDS row count, and a byte a row, 1 for a larva.
pub const larvae_rows_at: usize = 4;

pub const Larvae = struct {
    stinger: roster.Record,
    add: u8,
    /// Per METROIDS row, the Queen's last.
    larval: []bool,
};

pub fn larvae(a: std.mem.Allocator, rom: []const u8) !Larvae {
    const blocks = @import("blocks.zig");
    const recs = try roster.allRecords(a, rom);
    var stinger: ?roster.Record = null;
    for (recs) |r| if (r.ai == stinger_ai) {
        if (stinger != null) return Error.StingerNotUnique;
        stinger = r;
    };
    const o = blocks.offsetIn(2, stinger_add_at);
    if (rom[o] != 0xC6) return Error.StingerNotUnique; // `ADD A,d8`
    const list = try menuMetroids(a, rom);
    const larval = try a.alloc(bool, list.len + 1);
    for (list, 0..) |m, i| larval[i] = m.ai == larval_ai;
    larval[list.len] = false; // the Queen
    return .{ .stinger = stinger orelse return Error.StingerNotUnique, .add = rom[o + 1], .larval = larval };
}

/// `enAI_metroidStinger` and `enAI_normalMetroid`, and the stinger's `ADD`.
const stinger_ai: u16 = 0x6B83;
const larval_ai: u16 = 0x7A4F;
const stinger_add_at: u16 = 0x6B92;

pub fn larvaeBlob(a: std.mem.Allocator, rom: []const u8) ![]u8 {
    const l = try larvae(a, rom);
    const out = try a.alloc(u8, larvae_rows_at + l.larval.len);
    out[0] = l.stinger.bank;
    out[1] = l.stinger.number;
    out[2] = l.add;
    out[3] = @intCast(l.larval.len);
    for (l.larval, out[larvae_rows_at..]) |v, *b| b.* = @intFromBool(v);
    return out;
}

/// The saved-half records the FLAGS page lists: every one not a Metroid.
pub fn flagRecords(a: std.mem.Allocator, rom: []const u8) ![]roster.Record {
    const recs = try roster.allRecords(a, rom);
    var out: std.ArrayList(roster.Record) = .empty;
    for (recs) |r| {
        if (r.number < saved_first or roster.speciesOf(r.ai) != null) continue;
        try out.append(a, r);
    }
    return out.toOwnedSlice(a);
}

pub fn flagsBlob(a: std.mem.Allocator, rom: []const u8) ![]u8 {
    const e = offsets.find("item_names") orelse return error.UnresolvedSource;
    const names = try items.parseNames(rom[e.romOffset()..e.romEnd()], e.gb_addr);
    const list = try flagRecords(a, rom);
    const out = try a.alloc(u8, 1 + list.len * entry_bytes);
    out[0] = @intCast(list.len);
    var buf: [label_max + 24]u8 = undefined;
    for (list, 0..) |r, i| {
        const what: []const u8 = switch (r.ai) {
            // A major item's record names its orb, the even id before the
            // item's; a tank's names the item itself (`items.sprite_item_base`).
            0x4DD3 => blk: {
                const c = items.collectedFor(r.sprite | 1) orelse return Error.NotAnItem;
                break :blk names.trimmed(@intFromEnum(c));
            },
            0x6A14 => "MISSILE DOOR",
            0x6622 => "MISSILE BLOCK",
            0x5109 => "ARACHNUS",
            0x6B83 => "METROID STINGER",
            0x7BE5 => "BABY METROID",
            else => return Error.UnnamedRecord,
        };
        const label = std.fmt.bufPrint(&buf, "{X}:{X:0>2} {s}", .{ r.bank, r.cell, what }) catch return Error.LabelTooLong;
        try put(out[1 + i * entry_bytes ..][0..entry_bytes], r, label);
    }
    return out;
}

// ---- The WARP page (1.0 Step 5b) ------------------------------------------------

/// A warp list's rows are entries as above, the header's third byte the row's
/// index into `warp_data`. `warp_data` is a count byte and then `warp_bytes`
/// per destination, in the lists' order:
///
///   +0  scripts in the chain (1 or 2)
///   +1  the chain, two little-endian door indices (the second unused for 1)
///   +5  the map bank ($09-$0F) and the camera's cell (`warpCell`)
///   +7  Samus's y and x, the camera's y and x: whole positions, little-endian
///   +15 1 when only a ball fits and she arrives as one
///
/// One row is not a destination: ENDING, the QUEEN list's last (1.0 Step 22),
/// whose entry is all zeros. A chain of no scripts is `DebugWarp`'s cue to
/// enter the ending as the missile refill's zero-count branch does.
pub const warp_bytes: usize = 16;
pub const ending_list: usize = 3;
pub const ending_label = "ENDING";

/// The cell the warp loads as `!Cell`: the camera's, as `LatchCell` would
/// latch it, whose screen `LoadScreen` draws and whose scroll flags it takes.
/// For a record in a blank cell that is the drawn neighbour `warp.build`
/// stood her in, not the record's own (1.0 Step 5c found the warp loading the
/// blank cell).
pub fn warpCell(e: warp.Entry) u8 {
    return @truncate((e.cam_y >> 4 & 0xF0) | (e.cam_x >> 8 & 0x0F));
}

pub const WarpBlobs = struct {
    lists: [warp_lists.len][]u8,
    data: []u8,
};

fn warpLabel(buf: []u8, e: warp.Entry, mets: []const roster.Metroid, names: *const items.Names) ![]const u8 {
    const d = e.dest;
    return switch (d.kind) {
        .ship => std.fmt.bufPrint(buf, "SHIP {X}:{X:0>2}", .{ d.at.bank, d.at.cell }),
        .station => std.fmt.bufPrint(buf, "SAVE {X}:{X:0>2}", .{ d.at.bank, d.at.cell }),
        .item => std.fmt.bufPrint(buf, "{X}:{X:0>2} {s}", .{ d.at.bank, d.at.cell, names.trimmed(@intFromEnum(d.item.?)) }),
        .metroid, .metroid_before => blk: {
            const m = d.metroid.?;
            const i = for (mets, 0..) |x, i| {
                if (x.bank == m.bank and x.cell == m.cell and x.number == m.number) break i;
            } else unreachable; // a destination's Metroid is on the roster
            break :blk if (d.kind == .metroid)
                std.fmt.bufPrint(buf, "{d:0>2} {X}:{X:0>2} {s}", .{ i + 1, d.at.bank, d.at.cell, species(m.ai) })
            else
                std.fmt.bufPrint(buf, "{d:0>2} NEXT {X}:{X:0>2}", .{ i + 1, d.at.bank, d.at.cell });
        },
        .queen => std.fmt.bufPrint(buf, "QUEEN {X}:{X:0>2}", .{ d.at.bank, d.at.cell }),
        .queen_before => std.fmt.bufPrint(buf, "QUEEN NEXT {X}:{X:0>2}", .{ d.at.bank, d.at.cell }),
        .door => std.fmt.bufPrint(buf, "DOOR {X:0>3} {X}:{X:0>2}", .{ d.door.?, d.at.bank, d.at.cell }),
    } catch Error.LabelTooLong;
}

fn listOf(k: roster.Kind) usize {
    return switch (k) {
        .ship, .station, .door => 0,
        .item => 1,
        .metroid, .metroid_before => 2,
        .queen, .queen_before => 3,
    };
}

/// Rank within a list: the ship ahead of the stations, and a Metroid's own
/// room ahead of the room next to it.
fn rank(e: warp.Entry, mets: []const roster.Metroid) usize {
    return switch (e.dest.kind) {
        .ship => 0,
        .metroid, .metroid_before => blk: {
            const m = e.dest.metroid.?;
            for (mets, 0..) |x, i| if (x.bank == m.bank and x.cell == m.cell and x.number == m.number)
                break :blk 1 + i * 2 + @intFromBool(e.dest.kind == .metroid_before);
            unreachable;
        },
        else => 1,
    };
}

/// `warp.build`'s entries in `warp_data`'s order: by list, then by rank. The
/// sort is stable, so within a rank the entries keep `roster.destinations`'
/// order.
pub fn warpOrder(a: std.mem.Allocator, rom: []const u8, entries: []const warp.Entry) ![]warp.Entry {
    const mets = try menuMetroids(a, rom);
    const sorted = try a.dupe(warp.Entry, entries);
    const Ctx = struct {
        mets: []const roster.Metroid,
        fn less(c: @This(), x: warp.Entry, y: warp.Entry) bool {
            const lx = listOf(x.dest.kind);
            const ly = listOf(y.dest.kind);
            if (lx != ly) return lx < ly;
            return rank(x, c.mets) < rank(y, c.mets);
        }
    };
    std.mem.sort(warp.Entry, sorted, Ctx{ .mets = mets }, Ctx.less);
    return sorted;
}

/// The list a `warp_data` entry is on (`warp_lists`' index), and its row there.
pub fn warpRow(sorted: []const warp.Entry, i: usize) struct { usize, usize } {
    const li = listOf(sorted[i].dest.kind);
    var row: usize = 0;
    for (sorted[0..i]) |x| row += @intFromBool(listOf(x.dest.kind) == li);
    return .{ li, row };
}

/// The WARP page's lists and data, from `warp.build`'s entries.
pub fn warpBlobs(a: std.mem.Allocator, rom: []const u8, entries: []const warp.Entry) !WarpBlobs {
    const e = offsets.find("item_names") orelse return error.UnresolvedSource;
    const names = try items.parseNames(rom[e.romOffset()..e.romEnd()], e.gb_addr);
    const mets = try menuMetroids(a, rom);
    const sorted = try warpOrder(a, rom, entries);
    if (sorted.len > 255) return Error.LabelTooLong;

    var counts: [warp_lists.len]usize = @splat(0);
    for (sorted) |x| counts[listOf(x.dest.kind)] += 1;
    counts[ending_list] += 1;
    var out: WarpBlobs = undefined;
    for (&out.lists, counts) |*l, n| {
        l.* = try a.alloc(u8, 1 + n * entry_bytes);
        l.*[0] = @intCast(n);
    }
    out.data = try a.alloc(u8, 1 + (sorted.len + 1) * warp_bytes);
    out.data[0] = @intCast(sorted.len + 1);
    var at: [warp_lists.len]usize = @splat(0);
    var buf: [label_max + 24]u8 = undefined;
    for (sorted, 0..) |x, i| {
        const li = listOf(x.dest.kind);
        const r: roster.Record = .{ .bank = x.dest.at.bank, .cell = x.dest.at.cell, .number = @intCast(i), .sprite = 0, .x = 0, .y = 0, .ai = 0 };
        try put(out.lists[li][1 + at[li] * entry_bytes ..][0..entry_bytes], r, try warpLabel(&buf, x, mets, &names));
        at[li] += 1;
        const dd = out.data[1 + i * warp_bytes ..][0..warp_bytes];
        dd[0] = x.n;
        std.mem.writeInt(u16, dd[1..3], x.chain[0], .little);
        std.mem.writeInt(u16, dd[3..5], if (x.n > 1) x.chain[1] else 0, .little);
        dd[5] = x.dest.at.bank;
        dd[6] = warpCell(x);
        std.mem.writeInt(u16, dd[7..9], x.samus_y, .little);
        std.mem.writeInt(u16, dd[9..11], x.samus_x, .little);
        std.mem.writeInt(u16, dd[11..13], x.cam_y, .little);
        std.mem.writeInt(u16, dd[13..15], x.cam_x, .little);
        dd[15] = @intFromBool(x.morph);
    }
    const r: roster.Record = .{ .bank = 0, .cell = 0, .number = @intCast(sorted.len), .sprite = 0, .x = 0, .y = 0, .ai = 0 };
    try put(out.lists[ending_list][1 + at[ending_list] * entry_bytes ..][0..entry_bytes], r, ending_label);
    @memset(out.data[1 + sorted.len * warp_bytes ..][0..warp_bytes], 0);
    return out;
}

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

fn labelOf(blob: []const u8, i: usize) []const u8 {
    const l = blob[1 + i * entry_bytes + header_bytes ..][0 .. label_max + 1];
    return l[0..std.mem.indexOfScalar(u8, l, 0).?];
}

test "the METROIDS list is the roster in playthrough order, numbered so" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const b = try metroidsBlob(a, rom);
    try testing.expectEqual(@as(u8, 47), b[0]);
    try testing.expectEqualStrings("01 F:10 NW HATCHING", labelOf(b, 0));
    try testing.expectEqualStrings("26 A:17 NW ALPHA", labelOf(b, 25));
    try testing.expectEqualStrings("46 D:10 NW LARVAL", labelOf(b, 45));
    // And the Queen, whose bank no record has, which makes the ROM's 47.
    try testing.expectEqualStrings("47 QUEEN", labelOf(b, 46));
    try testing.expectEqual(queen_bank, b[1 + 46 * entry_bytes]);
    // The header: bank, cell, spawn number.
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x10, 0x41 }, b[1..][0..3]);
}

test "the playthrough is the roster, each Metroid the record nearest its kill" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const list = try roster.metroids(a, rom);
    try testing.expectEqual(list.len, playthrough.len);
    for (playthrough, 0..) |k, i| {
        for (playthrough[i + 1 ..]) |o| try testing.expect(k.bank != o.bank or k.number != o.number);
        // The bank's records by distance from the kill's cell, in cells across
        // and down; the listed one alone is nearest, and at most a cell off. A record killed
        // in its own cell is not a candidate for another kill: kill 4's $B:$C9
        // is a cell from both $B:$CA and $B:$D9, and kill 12 is in $B:$D9.
        var best: usize = std.math.maxInt(usize);
        var at_best: usize = 0;
        var mine: ?usize = null;
        for (list) |m| {
            if (m.bank != k.bank) continue;
            const own = for (playthrough) |o| {
                if (o.bank == m.bank and o.number == m.number) break o.cell == m.cell;
            } else false;
            if (own and m.number != k.number) continue;
            const dy = @abs(@as(i16, m.cell >> 4) - @as(i16, k.cell >> 4));
            const dx = @abs(@as(i16, m.cell & 0xF) - @as(i16, k.cell & 0xF));
            const d: usize = dy + dx;
            if (m.number == k.number) mine = d;
            if (d < best) {
                best = d;
                at_best = 1;
            } else if (d == best) at_best += 1;
        }
        try testing.expectEqual(best, mine.?);
        try testing.expectEqual(@as(usize, 1), at_best);
        try testing.expect(best <= 1);
    }
    try testing.expectEqual(@as(usize, 25), rowOf(0xA, 0x40));
}

test "the larvae blob: the stinger, its eight, and the larval rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const b = try larvaeBlob(a, rom);
    const mets = try metroidsBlob(a, rom);
    try testing.expectEqual(@as(u8, 0x08), b[2]);
    try testing.expectEqual(mets[0], b[3]);
    // The stinger is a FLAGS row, so the menu reads its flag where FLAGS does.
    const flags = try flagsBlob(a, rom);
    var found = false;
    for (0..flags[0]) |i| {
        const e = flags[1 + i * entry_bytes ..];
        if (e[0] == b[0] and e[2] == b[1]) found = std.mem.endsWith(u8, labelOf(flags, i), "METROID STINGER");
    }
    try testing.expect(found);
    // Every larval row is labelled LARVAL, and there are as many as the
    // stinger adds: the displayed count is the real one less them.
    var n: u8 = 0;
    for (0..b[3]) |i| {
        const larval = b[larvae_rows_at + i] == 1;
        try testing.expectEqual(larval, std.mem.endsWith(u8, labelOf(mets, i), "LARVAL"));
        n += @intFromBool(larval);
    }
    try testing.expectEqual(b[2], n);
}

test "the FLAGS list is the saved half less the Metroids, named from the ROM" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const b = try flagsBlob(a, rom);
    try testing.expectEqual(@as(u8, 52), b[0]);
    var seen_door = false;
    var seen_baby = false;
    for (0..b[0]) |i| {
        const e = b[1 + i * entry_bytes ..];
        try testing.expect(e[2] >= saved_first);
        try testing.expect(e[0] >= 0x09 and e[0] <= 0x0F);
        const l = labelOf(b, i);
        if (std.mem.endsWith(u8, l, "MISSILE DOOR")) seen_door = true;
        if (std.mem.eql(u8, l, "F:A7 BABY METROID")) seen_baby = true;
    }
    try testing.expect(seen_door and seen_baby);
    // The first is bank 9's first orb, and its name is the game's own.
    try testing.expectEqualSlices(u8, &.{ 0x09, 0x01, 0x65 }, b[1..][0..3]);
    try testing.expect(std.mem.startsWith(u8, labelOf(b, 0), "9:01 "));
    // Together with the Metroids they are the whole saved half: 98.
    const mets = try roster.metroids(a, rom);
    const recs = try roster.allRecords(a, rom);
    var saved: usize = 0;
    for (recs) |r| {
        if (r.number >= saved_first) saved += 1;
    }
    try testing.expectEqual(saved, b[0] + mets.len);
}

test "a label the menu cannot draw is refused" {
    var out: [entry_bytes]u8 = undefined;
    const r: roster.Record = .{ .bank = 9, .cell = 0, .number = 0x40, .sprite = 0, .x = 0, .y = 0, .ai = 0 };
    try testing.expectError(Error.Undrawable, put(&out, r, "BOMB!"));
    try testing.expectError(Error.LabelTooLong, put(&out, r, "A" ** (label_max + 1)));
    try put(&out, r, "A" ** label_max);
    try testing.expectEqual(@as(u8, 0), out[entry_bytes - 1]);
}

test "the WARP lists hold every warp entry once, and each row runs its own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const built = try warp.build(a, rom, try warp.loadWalked(a, rom));
    const wb = try warpBlobs(a, rom, built.entries);
    const sorted = try warpOrder(a, rom, built.entries);
    try testing.expectEqual(built.entries.len + 1, wb.data[0]);
    var seen = try a.alloc(bool, built.entries.len + 1);
    @memset(seen, false);
    var total: usize = 0;
    for (wb.lists) |l| {
        for (0..l[0]) |i| {
            const row = l[1 + i * entry_bytes ..][0..entry_bytes];
            const d = wb.data[1 + @as(usize, row[2]) * warp_bytes ..][0..warp_bytes];
            try testing.expect(!seen[row[2]]);
            seen[row[2]] = true;
            // ENDING, the QUEEN list's last: no chain at all.
            if (row[2] == built.entries.len) {
                try testing.expectEqualStrings(ending_label, labelOf(l, i));
                try testing.expectEqual(l[0] - 1, i);
                for (d) |b| try testing.expectEqual(@as(u8, 0), b);
                continue;
            }
            // The row names the destination, and the data warps to its bank
            // and draws the camera's cell there: the destination's, or the
            // drawn cell beside a record in a blank one.
            const e = sorted[row[2]];
            try testing.expectEqual(row[0], d[5]);
            try testing.expectEqual(e.dest.at.cell, row[1]);
            try testing.expectEqual(warpCell(e), d[6]);
            try testing.expect(d[0] == 1 or d[0] == 2);
        }
        total += l[0];
    }
    try testing.expectEqual(built.entries.len + 1, total);
    // The ship heads the first list, and a Metroid's room its NEXT.
    try testing.expect(std.mem.startsWith(u8, labelOf(wb.lists[0], 0), "SHIP "));
    try testing.expectEqualStrings("01 F:10 HATCHING", labelOf(wb.lists[2], 0));
    try testing.expect(std.mem.startsWith(u8, labelOf(wb.lists[2], 1), "01 NEXT "));
}
