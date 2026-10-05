//! 1.0 Step 8a: the gfxInfo records `loadGraphics` (00:$2753) walks.
//!
//! A record is seven bytes: the source's bank, its address, the VRAM
//! destination and the size, which `loadGraphics` copies into
//! `hVramTransfer` for the vblank handler to move four tiles a frame
//! (`VBlank_vramDataTransfer`, 00:$2BA3). The port does not read them at run
//! time. Their sources are sheets `snes_convert` has already made `chr_obj`
//! blobs of, so each record becomes a row of the engine's `GfxInfo` table:
//! the sheet's asset id, where in the converted sheet the record starts, the
//! SNES destination, and the length, all in SNES bytes.
//!
//! **Which record is which comes from the code that loads it, not from a
//! list.** Each caller is decoded for its `ld hl,rec` / `call $2753` pairs, in
//! order: `toggleMissiles`, each pickup routine `handleItemPickup` dispatches
//! to, `varia_loadExtraGraphics`, and `loadGame_samusItemGraphics` with its
//! own copier (00:$3C3F). The callers name the same records more than once --
//! the spazer's is the plasma's, and the screw's and space jump's both-items
//! pair is one pair -- and every repeat is checked, so a caller that loaded a
//! different record than its neighbours is an error rather than a row.

const std = @import("std");
const offsets = @import("offsets.zig");
const items = @import("items.zig");
const target = @import("snes_target.zig");

/// The rows of the engine's `GfxInfo` table, in its order. The first two are
/// `!CANNON_BEAM` and `!CANNON_MISSILE`, so a cannon index is its row. The
/// last two are not the ROM's: see `power_base`.
pub const Id = enum(u8) {
    cannon_beam,
    cannon_missile,
    plasma,
    ice,
    wave,
    varia_suit,
    spin_space_top,
    spin_space_bottom,
    spin_screw_top,
    spin_screw_bottom,
    spin_space_screw_top,
    spin_space_screw_bottom,
    spring_top,
    spring_bottom,
    /// The power suit over the Varia record's range, and over the plasma
    /// record's. **The debug menu's, not the game's**: nothing in the original
    /// takes the Varia suit or a beam away, so no record puts the power suit
    /// back. A menu that can take them away can, and these are the rows it
    /// uses (`SamusGfxSync`).
    power_base,
    power_beam,
};
pub const count = @typeInfo(Id).@"enum".fields.len;
/// How many of `Id`'s rows are the ROM's.
pub const rom_count = @intFromEnum(Id.power_base);

/// Bytes per row of the engine's table: asset id, a pad, then the source
/// offset, the destination word and the length, each little-endian.
pub const row_bytes: usize = 8;

/// `loadGraphics`, and `loadGame_copyItemToVram`, the load's copier.
pub const load_graphics: u16 = 0x2753;
const copy_item: u16 = 0x3C3F;
/// `samus_tryShooting.toggleMissiles` and where its two records begin: the
/// routine is the bytes between.
const toggle_missiles: u16 = 0x2212;
const toggle_end: u16 = 0x2242;
/// `handleItemPickup`, where the search for its dispatch starts.
const handle_item_pickup: u16 = 0x372F;
/// `gameMode_LoadB`'s two calls: `loadGame_loadGraphics` then
/// `loadGame_samusItemGraphics`.
const load_game_graphics: u16 = 0x05FD;

/// The Game Boy's sheet for the power suit, which is `snes_inject.samus_sheet`.
pub const power_sheet = "gfx_samusPowerSuit";

pub const Error = error{
    NoDispatch,
    /// A caller did not load the records the decode expects, in number or in
    /// agreement with another caller.
    UnexpectedCaller,
    /// A record whose source is not inside one Samus sheet.
    NoSheet,
    /// A destination that is not an object tile.
    BadDest,
};

/// One gfxInfo record, as the ROM holds it.
pub const Record = struct {
    bank: u8,
    src: u16,
    dest: u16,
    size: u16,

    fn at(rom: []const u8, addr: u16) Record {
        const b = rom[addr..][0..7];
        return .{
            .bank = b[0],
            .src = std.mem.readInt(u16, b[1..3], .little),
            .dest = std.mem.readInt(u16, b[3..5], .little),
            .size = std.mem.readInt(u16, b[5..7], .little),
        };
    }
};

/// A row of the engine's table, before its sheet has an asset id.
pub const Row = struct {
    /// The `offsets` entry of the sheet the row reads.
    sheet: []const u8,
    /// Into the converted sheet, in SNES bytes.
    offset: u16,
    /// A SNES VRAM word address.
    dest: u16,
    /// SNES bytes.
    len: u16,
    /// The ROM record the row is, and where it is; `null` for `power_base`
    /// and `power_beam`.
    record: ?Record,
    record_at: ?u16,
};

pub const Table = struct {
    rows: [count]Row,

    pub fn row(t: Table, id: Id) Row {
        return t.rows[@intFromEnum(id)];
    }
};

/// Every `ld hl,rec` followed by a call of `routine` (or a `call z`, which is
/// how Varia loads the missile cannon) in `rom[from..to]`, in order: the
/// record addresses the caller hands it.
fn calls(buf: *[16]u16, rom: []const u8, from: u16, to: u16, routine: u16) []const u16 {
    var n: usize = 0;
    var hl: ?u16 = null;
    var i: usize = from;
    while (i + 3 <= to) {
        const op = rom[i];
        const word = @as(u16, rom[i + 1]) | @as(u16, rom[i + 2]) << 8;
        if (op == 0x21) {
            hl = word;
            i += 3;
            continue;
        }
        if ((op == 0xCD or op == 0xCC) and word == routine) {
            if (hl) |h| {
                if (n < buf.len) buf[n] = h;
                n += 1;
            }
            i += 3;
            continue;
        }
        i += 1;
    }
    return buf[0..@min(n, buf.len)];
}

/// The routine `handleItemPickup` jumps to for `c`: its jump table follows
/// `ld a,b / dec a / rst $28`, one word per item from `itemCollected` 1.
fn handler(rom: []const u8, c: items.Collected) Error!u16 {
    var i: usize = handle_item_pickup;
    while (i < handle_item_pickup + 0x100) : (i += 1) {
        if (rom[i] == 0x78 and rom[i + 1] == 0x3D and rom[i + 2] == 0xEF) {
            const e = i + 3 + (@as(usize, @intFromEnum(c)) - 1) * 2;
            return @as(u16, rom[e]) | @as(u16, rom[e + 1]) << 8;
        }
    }
    return Error.NoDispatch;
}

/// The pickup routines lie in dispatch order in the ROM, so each one ends
/// where the next begins; the last of them ends at the energy tank's.
fn pickupRange(rom: []const u8, c: items.Collected) Error!struct { u16, u16 } {
    const h = try handler(rom, c);
    var end: u16 = 0xFFFF;
    inline for (std.meta.fields(items.Collected)) |f| {
        const o = try handler(rom, @enumFromInt(f.value));
        if (o > h and o < end) end = o;
    }
    return .{ h, end };
}

fn expect(got: []const u16, want: []const ?u16) Error!void {
    if (got.len != want.len) return Error.UnexpectedCaller;
    for (got, want) |g, w| if (w) |x| if (g != x) return Error.UnexpectedCaller;
}

/// The record addresses by row, decoded from their callers and checked
/// against each other.
pub fn addresses(rom: []const u8) Error![rom_count]u16 {
    var at: [rom_count]u16 = undefined;
    const I = Id;
    var buf: [16]u16 = undefined;

    // `toggleMissiles`: to the beam, then to missiles.
    const t = calls(&buf, rom, toggle_missiles, toggle_end, load_graphics);
    try expect(t, &.{ null, null });
    at[@intFromEnum(I.cannon_beam)] = t[0];
    at[@intFromEnum(I.cannon_missile)] = t[1];

    // The four beams: one record each, the spazer's the plasma's.
    for ([_]items.Collected{ .plasma_beam, .ice_beam, .wave_beam }, [_]I{ .plasma, .ice, .wave }) |c, id| {
        const lo, const hi = try pickupRange(rom, c);
        const r = calls(&buf, rom, lo, hi, load_graphics);
        try expect(r, &.{null});
        at[@intFromEnum(id)] = r[0];
    }
    {
        const lo, const hi = try pickupRange(rom, .spazer);
        try expect(calls(&buf, rom, lo, hi, load_graphics), &.{at[@intFromEnum(I.plasma)]});
    }
    // Screw attack: its own pair without space jump, the both-items pair with.
    {
        const lo, const hi = try pickupRange(rom, .screw_attack);
        const r = calls(&buf, rom, lo, hi, load_graphics);
        try expect(r, &.{ null, null, null, null });
        at[@intFromEnum(I.spin_screw_top)] = r[0];
        at[@intFromEnum(I.spin_screw_bottom)] = r[1];
        at[@intFromEnum(I.spin_space_screw_top)] = r[2];
        at[@intFromEnum(I.spin_space_screw_bottom)] = r[3];
    }
    // Space jump: the mirror image, sharing the both-items pair.
    {
        const lo, const hi = try pickupRange(rom, .space_jump);
        const r = calls(&buf, rom, lo, hi, load_graphics);
        try expect(r, &.{ null, null, at[@intFromEnum(I.spin_space_screw_top)], at[@intFromEnum(I.spin_space_screw_bottom)] });
        at[@intFromEnum(I.spin_space_top)] = r[0];
        at[@intFromEnum(I.spin_space_bottom)] = r[1];
    }
    {
        const lo, const hi = try pickupRange(rom, .spring_ball);
        const r = calls(&buf, rom, lo, hi, load_graphics);
        try expect(r, &.{ null, null });
        at[@intFromEnum(I.spring_top)] = r[0];
        at[@intFromEnum(I.spring_bottom)] = r[1];
    }
    // Varia: the suit, then the missile cannon under `call z`, then
    // `varia_loadExtraGraphics`, which is the first plain call after it.
    const extras = blk: {
        const lo, const hi = try pickupRange(rom, .varia);
        const r = calls(&buf, rom, lo, hi, load_graphics);
        try expect(r, &.{ null, at[@intFromEnum(I.cannon_missile)] });
        at[@intFromEnum(I.varia_suit)] = r[0];
        var i: usize = lo;
        var seen: usize = 0;
        while (i + 3 <= hi) : (i += 1) {
            if (rom[i] == 0xCC and (@as(u16, rom[i + 1]) | @as(u16, rom[i + 2]) << 8) == load_graphics) seen = i + 3;
        }
        if (seen == 0 or rom[seen] != 0xCD) return Error.UnexpectedCaller;
        break :blk @as(u16, rom[seen + 1]) | @as(u16, rom[seen + 2]) << 8;
    };
    // `varia_loadExtraGraphics`: spring, then one of the three spin pairs.
    try expect(calls(&buf, rom, extras, extras + 0x50, load_graphics), &.{
        at[@intFromEnum(I.spring_top)],           at[@intFromEnum(I.spring_bottom)],
        at[@intFromEnum(I.spin_space_screw_top)], at[@intFromEnum(I.spin_space_screw_bottom)],
        at[@intFromEnum(I.spin_space_top)],       at[@intFromEnum(I.spin_space_bottom)],
        at[@intFromEnum(I.spin_screw_top)],       at[@intFromEnum(I.spin_screw_bottom)],
    });
    // `loadGame_samusItemGraphics`, through its own copier: the order
    // `SamusItemGraphics` ports. The spazer's is the plasma's again.
    try expect(calls(&buf, rom, try loadGameItems(rom), try loadGameItems(rom) + 0x90, copy_item), &.{
        at[@intFromEnum(I.varia_suit)],
        at[@intFromEnum(I.spring_top)],           at[@intFromEnum(I.spring_bottom)],
        at[@intFromEnum(I.spin_space_screw_top)], at[@intFromEnum(I.spin_space_screw_bottom)],
        at[@intFromEnum(I.spin_space_top)],       at[@intFromEnum(I.spin_space_bottom)],
        at[@intFromEnum(I.spin_screw_top)],       at[@intFromEnum(I.spin_screw_bottom)],
        at[@intFromEnum(I.ice)],                  at[@intFromEnum(I.plasma)],
        at[@intFromEnum(I.wave)],                 at[@intFromEnum(I.plasma)],
    });
    return at;
}

/// `loadGame_samusItemGraphics`: the call after `loadGame_loadGraphics` in
/// `gameMode_LoadB`.
fn loadGameItems(rom: []const u8) Error!u16 {
    var i: usize = 0x0400;
    while (i < 0x0500) : (i += 1) {
        if (rom[i] == 0xCD and rom[i + 1] == @as(u8, @truncate(load_game_graphics)) and
            rom[i + 2] == @as(u8, @truncate(load_game_graphics >> 8)) and rom[i + 3] == 0xCD)
            return @as(u16, rom[i + 4]) | @as(u16, rom[i + 5]) << 8;
    }
    return Error.UnexpectedCaller;
}

/// The `graphics_samus` entry a record's source lies wholly inside.
fn sheetOf(r: Record) Error!offsets.Entry {
    for (offsets.entries) |e| {
        if (e.kind != .graphics_samus or e.bank != r.bank) continue;
        if (r.src >= e.gb_addr and @as(u32, r.src) + r.size <= @as(u32, e.gb_addr) + e.size) return e;
    }
    return Error.NoSheet;
}

fn rowOf(sheet: offsets.Entry, gb_offset: u16, gb_dest: u16, gb_size: u16) Error!Row {
    return .{
        .sheet = sheet.name,
        .offset = gb_offset * 2,
        .dest = target.gbDestToObj(gb_dest) catch return Error.BadDest,
        .len = gb_size * 2,
        .record = null,
        .record_at = null,
    };
}

pub fn decode(rom: []const u8) Error!Table {
    const at = try addresses(rom);
    var t: Table = undefined;
    for (at, 0..) |a, i| {
        const r = Record.at(rom, a);
        const sheet = try sheetOf(r);
        t.rows[i] = try rowOf(sheet, r.src - sheet.gb_addr, r.dest, r.size);
        t.rows[i].record = r;
        t.rows[i].record_at = a;
    }
    // The power suit under the two records the menu can take away.
    const power = offsets.find(power_sheet) orelse return Error.NoSheet;
    for ([_]Id{ .power_base, .power_beam }, [_]Id{ .varia_suit, .plasma }) |id, over| {
        const r = t.row(over).record.?;
        if (r.dest < 0x8000 or r.dest - 0x8000 + r.size > power.size) return Error.NoSheet;
        t.rows[@intFromEnum(id)] = try rowOf(power, r.dest - 0x8000, r.dest, r.size);
    }
    return t;
}

/// The engine's table, given each row's sheet as an asset id.
pub fn tableBytes(t: Table, assetId: anytype) ![count * row_bytes]u8 {
    var out: [count * row_bytes]u8 = undefined;
    for (t.rows, 0..) |r, i| {
        const o = out[i * row_bytes ..][0..row_bytes];
        o[0] = try assetId.of(r.sheet);
        o[1] = 0;
        std.mem.writeInt(u16, o[2..4], r.offset, .little);
        std.mem.writeInt(u16, o[4..6], r.dest, .little);
        std.mem.writeInt(u16, o[6..8], r.len, .little);
    }
    return out;
}

/// How many frames the Game Boy's vblank handler spends moving `size` bytes:
/// `VBlank_vramDataTransfer` copies until the count's low six bits are zero,
/// so the first chunk is the size mod $40 (or $40) and every later one $40.
pub fn chunks(size: u16) u16 {
    return size / 0x40 + @intFromBool(size % 0x40 != 0);
}

// ---- Tests -----------------------------------------------------------------

const testrom = @import("testrom");

test "the records decode, and every caller agrees" {
    const rom = try testrom.load(std.testing.allocator) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(rom);
    const t = try decode(rom);
    // M2RoS's `vramDest_*` for each, which the decode did not read.
    const want = [_]struct { Id, u16, u16 }{
        .{ .cannon_beam, 0x8080, 0x20 },  .{ .cannon_missile, 0x8080, 0x20 },
        .{ .plasma, 0x87E0, 0x20 },       .{ .ice, 0x87E0, 0x20 },
        .{ .wave, 0x87E0, 0x20 },         .{ .varia_suit, 0x8000, 0x7B0 },
        .{ .spin_space_top, 0x8500, 0x70 }, .{ .spin_space_bottom, 0x8600, 0x50 },
        .{ .spin_screw_top, 0x8500, 0x70 }, .{ .spin_screw_bottom, 0x8600, 0x50 },
        .{ .spin_space_screw_top, 0x8500, 0x70 }, .{ .spin_space_screw_bottom, 0x8600, 0x50 },
        .{ .spring_top, 0x8590, 0x20 },   .{ .spring_bottom, 0x8690, 0x20 },
    };
    for (want) |w| {
        const r = t.row(w[0]).record.?;
        try std.testing.expectEqual(w[1], r.dest);
        try std.testing.expectEqual(w[2], r.size);
        try std.testing.expectEqual(try target.gbDestToObj(w[1]), t.row(w[0]).dest);
    }
    try std.testing.expectEqualStrings("gfx_beamIce", t.row(.ice).sheet);
    try std.testing.expectEqualStrings("gfx_samusVariaSuit", t.row(.varia_suit).sheet);
    try std.testing.expectEqualStrings(power_sheet, t.row(.power_base).sheet);
    try std.testing.expectEqual(t.row(.varia_suit).len, t.row(.power_base).len);
    try std.testing.expectEqual(t.row(.plasma).dest, t.row(.power_beam).dest);
}

test "a caller that loads another record is refused" {
    const a = std.testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    // The wave beam's pickup handed the ice beam's record: `loadGame`'s list
    // no longer agrees with the pickups'.
    const bad = try a.dupe(u8, rom);
    defer a.free(bad);
    const at = try addresses(rom);
    const lo, const hi = try pickupRange(rom, .wave_beam);
    var i: usize = lo;
    while (i + 3 <= hi) : (i += 1) {
        if (bad[i] == 0x21) {
            std.mem.writeInt(u16, bad[i + 1 ..][0..2], at[@intFromEnum(Id.ice)], .little);
            break;
        }
    }
    try std.testing.expectError(Error.UnexpectedCaller, decode(bad));
}

test "the transfer's frames" {
    try std.testing.expectEqual(@as(u16, 1), chunks(0x20));
    try std.testing.expectEqual(@as(u16, 2), chunks(0x70));
    try std.testing.expectEqual(@as(u16, 2), chunks(0x50));
    try std.testing.expectEqual(@as(u16, 31), chunks(0x7B0));
}
