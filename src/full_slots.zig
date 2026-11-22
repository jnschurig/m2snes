//! The `slots` blob: the palette slot of every Game Boy tile each converted
//! character sheet holds, for the engine's per-tile palettes (colorization
//! Step 6).
//!
//! The engine keeps one attribute byte per BG3 character (`!BgAttr`). Every
//! copy into BG3's characters writes the slots of the tiles it copies there,
//! and every tilemap word ORs in the byte of the character it shows. That is
//! the `full` scheme's model (`docs/colorization.md`): a tile's palette goes
//! with the ROM tile it was copied from, whichever copy put it there.
//!
//! The blob is one table for every sheet, read through a header:
//!  - `header_entries` little-endian u16s, one per asset id: where that
//!    asset's bytes start in the blob, or `none`.
//!  - Then, per character sheet, one byte per 16-byte Game Boy tile. A
//!    `chr_bg` sheet's is the high byte of a play-field word showing it
//!    (`attr`), the slot as its palette and BG3's priority bit: the engine
//!    DMAs these straight into `!BgAttr`, which `MetaPut` reads whole. A
//!    `chr_obj` sheet's is the slot alone (Step 7), which `PutObject` ORs
//!    into its index; one byte per 32-byte character, still one Game Boy
//!    tile. (`UploadSamusBgTwin` turns its 48 into `attr` bytes.)
//!
//! A tile's slot is `full_assign.zig`'s for the region tile that holds its
//! first byte (`slot`: the derived slot, or the hand choice in
//! `tile_choices`); a tile in no region gets slot 0. Slots are scheme-independent:
//! `mono` and `gbc` load the same colours into every BG palette, so the bits
//! change nothing they show.

const std = @import("std");
const offsets = @import("offsets.zig");
const assign = @import("full_assign.zig");
const target = @import("snes_target.zig");

/// One header entry per possible asset id.
pub const header_entries = 256;
pub const header_bytes = header_entries * 2;
/// A header entry for an asset with no slots (a tilemap).
pub const none: u16 = 0xFFFF;

/// A slot as the high byte of a play-field word: `vhopppcc`, the slot in
/// palette bits 2-4 and `snes_target.play_priority` in bit 5.
pub fn attr(s: u3) u8 {
    const w: u16 = @bitCast(target.playWord(0, s));
    return @intCast(w >> 8);
}

/// The pages of `PutAttr` that `full` reads (`!ObjPage`), colorization Step 7.
pub const ObjPage = enum(u2) {
    /// Every object but the two below.
    full = 1,
    /// A Metroid's parts while `metroidStep` is non-zero.
    metroid_hit = 2,
    /// A frozen enemy's parts (`iceCounter` non-zero).
    frozen = 3,
};

/// A Metroid's body: the slot most of every Metroid sheet's tiles are in.
pub const metroid_body_slot: u3 = 4;
/// The OBJ palette a hit Metroid's body draws in, whose colours are its
/// damage step's. No gameplay sprite tile but `gfx_enemiesE` `$0C` is in slot
/// 2; the Queen's are, and she is never a hit Metroid.
pub const metroid_damage_palette: u3 = 2;

/// The SNES OAM attribute byte `full` gives an object (the engine's
/// `PutAttrFull`, colorization Step 7). `i` is the Game Boy attribute's high
/// nibble with the tile's slot in bits 0-2. The flips and priority are
/// `gbcObjAttr`'s; the palette is the slot, through the OBP1 swap, and on
/// `frozen` the frozen slot whatever the rest. On `metroid_hit` the body
/// slot, when the swap doesn't move it, is the damage palette.
pub fn objAttr(page: ObjPage, i: u8) u8 {
    const s: u3 = @intCast(i & 7);
    const pal: u3 = if (page == .frozen)
        assign.frozen_slot
    else if (i & 0x10 != 0)
        (if (s == assign.obp1_swap.when) assign.obp1_swap.then else assign.obp1_swap.otherwise)
    else if (page == .metroid_hit and s == metroid_body_slot)
        metroid_damage_palette
    else
        s;
    return (gbcObjAttr(i) & ~@as(u8, 0x0E)) | (@as(u8, pal) << 1);
}

/// Health at or above this is not a health: `!EN_HP_RESPAWN` and the
/// invulnerable `$FE`/`$FF` that a Metroid's own fireball or husk carries.
pub const hp_special: u8 = 0xFD;

/// A Metroid's damage step (the engine's `EnemyObjPage`): 0 above three
/// quarters of its full health left, then 1, 2 and 3 at a quarter or less.
/// Dead (0) and special values are 0.
pub fn metroidStep(health: u8, full_health: u8) u2 {
    if (full_health == 0 or full_health >= hp_special) return 0;
    if (health == 0 or health >= hp_special) return 0;
    const h4: u16 = @as(u16, health) * 4;
    const m: u16 = full_health;
    if (m >= h4) return 3;
    if (2 * m >= h4) return 2;
    if (3 * m >= h4) return 1;
    return 0;
}

/// The engine's first page, `PutAttr`, which `mono` and `gbc` read: OBP1 as
/// palette 1, the low nibble ignored.
pub fn gbcObjAttr(i: u8) u8 {
    return ((i & 0x60) << 1) | ((i & 0x10) >> 3) | (((i & 0x80) >> 2) ^ 0x20);
}

/// The slot of the Game Boy tile whose first byte is at ROM offset `at`: the
/// slot of the `full_assign` region tile that holds that byte, or 0.
pub fn slotAt(at: usize) u3 {
    for (assign.regions) |r| {
        const e = entry(r.name) orelse continue;
        const start = e.romOffset();
        if (at < start or at >= e.romEnd()) continue;
        const tile = (at - start) / 16;
        return slot(r.name, tile) orelse 0;
    }
    return 0;
}

/// The slot the cart draws tile `tile` of region `name` in: a hand choice
/// (`full_assign.tile_choices`) if one names it, else the derived slot.
pub fn slot(name: []const u8, tile: usize) ?u3 {
    for (assign.tile_choices) |c| {
        if (!std.mem.eql(u8, c.region, name)) continue;
        for (c.tiles) |t| if (t == tile) return c.slot;
    }
    return assign.slot(name, tile);
}

fn entry(name: []const u8) ?offsets.Entry {
    for (offsets.entries) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

/// What the blob needs of a converted sheet.
pub const Sheet = struct {
    id: u8,
    /// Character sheets only; anything else gets `none`.
    chr: bool,
    /// An object sheet: plain slots, not `attr` bytes.
    obj: bool = false,
    rom_at: usize,
    gb_bytes: usize,
};

/// The blob, for `sheets` (any order, ids unique).
pub fn blob(a: std.mem.Allocator, sheets: []const Sheet) ![]u8 {
    var size: usize = header_bytes;
    for (sheets) |s| if (s.chr) {
        size += tiles(s);
    };
    const out = try a.alloc(u8, size);
    @memset(out[0..header_bytes], 0xFF);
    var at: usize = header_bytes;
    for (sheets) |s| {
        if (!s.chr) continue;
        std.debug.assert(std.mem.readInt(u16, out[@as(usize, s.id) * 2 ..][0..2], .little) == none);
        std.mem.writeInt(u16, out[@as(usize, s.id) * 2 ..][0..2], @intCast(at), .little);
        for (0..tiles(s)) |t| {
            const sl = slotAt(s.rom_at + t * 16);
            out[at + t] = if (s.obj) sl else attr(sl);
        }
        at += tiles(s);
    }
    std.debug.assert(at == size);
    return out;
}

fn tiles(s: Sheet) usize {
    return (s.gb_bytes + 15) / 16;
}

/// The attribute bytes of asset `id` in `b`, or null if it has none.
pub fn of(b: []const u8, id: u8) ?[]const u8 {
    const at = std.mem.readInt(u16, b[@as(usize, id) * 2 ..][0..2], .little);
    if (at == none) return null;
    var end: usize = b.len;
    for (0..header_entries) |i| {
        const o = std.mem.readInt(u16, b[i * 2 ..][0..2], .little);
        if (o != none and o > at and o < end) end = o;
    }
    return b[at..end];
}

const testing = std.testing;

test "a tile takes the slot of the region tile holding its first byte" {
    for (assign.regions) |r| {
        const e = entry(r.name).?;
        for (0..r.slots.len) |i| {
            const want = slot(r.name, i).?;
            try testing.expectEqual(want, slotAt(e.romOffset() + i * 16));
            try testing.expectEqual(want, slotAt(e.romOffset() + i * 16 + 15));
        }
    }
}

test "a hand choice overrides the derived slot, and names real tiles" {
    for (assign.tile_choices) |c| {
        const r = region(c.region) orelse return error.UnknownRegion;
        for (c.tiles) |t| {
            try testing.expect(t < r.slots.len);
            try testing.expectEqual(c.slot, slot(c.region, t).?);
        }
    }
}

fn region(name: []const u8) ?assign.Region {
    for (assign.regions) |r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

test "a tile in no region is slot 0" {
    try testing.expectEqual(@as(u3, 0), slotAt(0));
}

test "every region names an offsets entry, one slot per tile" {
    for (assign.regions) |r| {
        const e = entry(r.name) orelse return error.UnknownRegion;
        try testing.expectEqual((e.size + 15) / 16, r.slots.len);
    }
}

test "the blob round-trips each sheet's attribute bytes" {
    const r = assign.regions[1];
    const e = entry(r.name).?;
    const sheets = [_]Sheet{
        .{ .id = 7, .chr = true, .rom_at = e.romOffset(), .gb_bytes = e.size },
        .{ .id = 3, .chr = false, .rom_at = 0, .gb_bytes = 0x400 },
        .{ .id = 0, .chr = true, .rom_at = e.romOffset() + 32, .gb_bytes = 48 },
    };
    const b = try blob(testing.allocator, &sheets);
    defer testing.allocator.free(b);
    try testing.expect(of(b, 3) == null);
    try testing.expect(of(b, 200) == null);
    const seven = of(b, 7).?;
    try testing.expectEqual(r.slots.len, seven.len);
    for (seven, 0..) |got, i| try testing.expectEqual(attr(slot(r.name, i).?), got);
    const zero = of(b, 0).?;
    try testing.expectEqual(@as(usize, 3), zero.len);
    try testing.expectEqualSlices(u8, seven[2..5], zero);
}

test "an object sheet's blob bytes are its plain slots" {
    const r = assign.regions[1];
    const e = entry(r.name).?;
    const sheets = [_]Sheet{
        .{ .id = 7, .chr = true, .obj = true, .rom_at = e.romOffset(), .gb_bytes = e.size },
    };
    const b = try blob(testing.allocator, &sheets);
    defer testing.allocator.free(b);
    for (of(b, 7).?, 0..) |got, i| try testing.expectEqual(@as(u8, slot(r.name, i).?), got);
}

/// The slot of the tile the status bar's id `id` shows: Samus's power suit
/// sheet below `$F0` (`$8000` on; the Varia load stops at `$7A`), the common
/// item tiles from `$F0` (`$8F00`).
fn barSlot(id: u8) ?u3 {
    if (id >= 0xF0) return assign.slot("gfx_commonItems", id - 0xF0);
    return assign.slot("gfx_samusPowerSuit", id);
}

test "the status bar's edits give each id its own tile's slot" {
    // So the engine needs no override table: `WinAttr` and `BarAttr` read
    // `!BgAttr` alone. If an edit ever disagreed, this fails first.
    for ([_][]const assign.Derived{ &assign.hud, &assign.queen }, [_][]const assign.Choice{ &assign.hud_choices, &assign.queen_choices }) |derived, choices| {
        for (derived) |d| {
            const want = assign.editSlot(derived, choices, d.id) orelse return error.UnresolvedEdit;
            try testing.expectEqual(barSlot(d.id), want);
        }
    }
}

test "objAttr: the slot, the OBP1 swap, and the frozen page over both" {
    for (0..8) |s| {
        const slot3: u8 = @intCast(s);
        // OBP0: the slot itself.
        try testing.expectEqual(slot3 << 1, objAttr(.full, slot3) & 0x0E);
        // OBP1: 3 becomes 1, anything else 3.
        const swapped: u8 = if (s == 3) 1 else 3;
        try testing.expectEqual(swapped << 1, objAttr(.full, 0x10 | slot3) & 0x0E);
        // Frozen: 3, OBP1 or not, a Metroid or not.
        try testing.expectEqual(@as(u8, 3) << 1, objAttr(.frozen, slot3) & 0x0E);
        try testing.expectEqual(@as(u8, 3) << 1, objAttr(.frozen, 0x10 | slot3) & 0x0E);
    }
}

test "objAttr on a hit Metroid: the body in the damage palette, under the flash" {
    for (0..256) |n| {
        const i: u8 = @intCast(n);
        const moved = i & 0x10 == 0 and i & 7 == metroid_body_slot;
        if (moved) {
            try testing.expectEqual(@as(u8, metroid_damage_palette) << 1, objAttr(.metroid_hit, i) & 0x0E);
            try testing.expectEqual(objAttr(.full, i) & 0xF1, objAttr(.metroid_hit, i) & 0xF1);
        } else {
            try testing.expectEqual(objAttr(.full, i), objAttr(.metroid_hit, i));
        }
    }
}

test "metroidStep: by quarters of the health left" {
    try testing.expectEqual(@as(u2, 0), metroidStep(40, 40));
    try testing.expectEqual(@as(u2, 0), metroidStep(31, 40));
    try testing.expectEqual(@as(u2, 1), metroidStep(30, 40));
    try testing.expectEqual(@as(u2, 1), metroidStep(21, 40));
    try testing.expectEqual(@as(u2, 2), metroidStep(20, 40));
    try testing.expectEqual(@as(u2, 2), metroidStep(11, 40));
    try testing.expectEqual(@as(u2, 3), metroidStep(10, 40));
    try testing.expectEqual(@as(u2, 3), metroidStep(1, 40));
    // Five hits: one hit is a step, as a small full health must give.
    try testing.expectEqual(@as(u2, 1), metroidStep(3, 5));
    try testing.expectEqual(@as(u2, 2), metroidStep(2, 5));
    try testing.expectEqual(@as(u2, 3), metroidStep(1, 5));
    // Not a Metroid's health: dead, a fireball's $FF, a respawn marker.
    try testing.expectEqual(@as(u2, 0), metroidStep(0, 40));
    try testing.expectEqual(@as(u2, 0), metroidStep(0xFF, 0xFF));
    try testing.expectEqual(@as(u2, 0), metroidStep(3, 0xFD));
    try testing.expectEqual(@as(u2, 0), metroidStep(3, 0));
    // Never up again as health falls.
    for (1..hp_special) |m| {
        var last: u2 = 0;
        var h: usize = m;
        while (h > 0) : (h -= 1) {
            const s = metroidStep(@intCast(h), @intCast(m));
            try testing.expect(s >= last);
            last = s;
        }
    }
}

test "the Metroids' sheets are mostly the body slot, and slot 2 is free in play" {
    const metroids = [_][]const u8{ "gfx_metAlpha", "gfx_metGamma", "gfx_metZeta", "gfx_metOmega" };
    for (metroids) |name| {
        const r = region(name).?;
        var counts = [_]usize{0} ** 8;
        for (r.slots) |c| counts[c - '0'] += 1;
        for (counts[1..], 1..) |c, s| {
            if (s != metroid_body_slot) try testing.expect(c < counts[metroid_body_slot]);
        }
    }
    // Every sprite sheet shown in play, but the Queen's, has no tile in the
    // damage palette's slot but `gfx_enemiesE` $0C.
    for (assign.regions) |r| {
        if (std.mem.indexOfScalar(u8, r.seen, 's') == null) continue;
        if (std.mem.startsWith(u8, r.name, "gfx_title") or std.mem.startsWith(u8, r.name, "gfx_credits") or
            std.mem.eql(u8, r.name, "gfx_queenSPR")) continue;
        for (r.slots, 0..) |c, t| {
            if (c - '0' != metroid_damage_palette) continue;
            try testing.expectEqualStrings("gfx_enemiesE", r.name);
            try testing.expectEqual(@as(usize, 0x0C), t);
        }
    }
}

test "objAttr keeps gbc's flips and priority, and gbc ignores the low nibble" {
    for (0..256) |n| {
        const i: u8 = @intCast(n);
        try testing.expectEqual(gbcObjAttr(i) & 0xF1, objAttr(.full, i) & 0xF1);
        try testing.expectEqual(gbcObjAttr(i) & 0xF1, objAttr(.frozen, i) & 0xF1);
        try testing.expectEqual(gbcObjAttr(i & 0xF0), gbcObjAttr(i));
    }
    // The flips a bit left, behind-background as priority 0, else 2.
    try testing.expectEqual(@as(u8, 0xC0 | 0x20), gbcObjAttr(0x60));
    try testing.expectEqual(@as(u8, 0x00), gbcObjAttr(0x80));
    try testing.expectEqual(@as(u8, 0x22), gbcObjAttr(0x10));
}

test "attr is a play-field word's high byte, the slot its palette" {
    for (0..8) |s| {
        const w: target.TilemapWord = @bitCast(@as(u16, attr(@intCast(s))) << 8);
        try testing.expectEqual(@as(u3, @intCast(s)), w.palette);
        try testing.expectEqual(target.play_priority, w.priority);
        try testing.expect(!w.flip_h and !w.flip_v);
        try testing.expectEqual(@as(u10, 0), w.char);
    }
}

// ---- On the ROM: the spike choices ---------------------------------------

const tileset = @import("tileset.zig");
const testrom = @import("testrom");

/// Bit 3 of a collision byte: the tile hurts Samus (`00:$2021`).
const spike_bit: u8 = 0x08;

/// The slots the background can show beside tileset `ts`'s graphics `gfx`
/// other than through its spikes: its other tiles (acid included), `$FF`,
/// and the `gfx_surfaceSPR` tiles the surface's metatiles draw.
fn othersOf(rom: []const u8, ts: tileset.Tileset, gfx: []const u8) !u8 {
    const col = tileset.slice(rom, ts.collision) orelse return error.NoCollision;
    const r = region(gfx) orelse return error.UnknownRegion;
    var used: u8 = @as(u8, 1) << slot("gfx_commonItems", 0xF).?;
    for (0..@min(0x80, r.slots.len)) |id| {
        if (col[id] & spike_bit != 0) continue;
        used |= @as(u8, 1) << slot(gfx, id).?;
    }
    for (ts.metatiles) |m| {
        for (tileset.slice(rom, m) orelse return error.NoMetatiles) |id| {
            if (id < 0x80 or id == 0xFF) continue;
            // Only the surface draws past $80: `gfx_surfaceSPR` at $8B00.
            try testing.expectEqualStrings("surface", ts.name);
            used |= @as(u8, 1) << slot("gfx_surfaceSPR", id - 0xB0).?;
        }
    }
    return used;
}

test "every spike is in a slot no other background tile of its tileset uses" {
    const rom = (try testrom.load(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    var unfree: usize = 0;
    for (tileset.tilesets) |ts| {
        const col = tileset.slice(rom, ts.collision) orelse return error.NoCollision;
        for (ts.gfx) |gfx| {
            const r = region(gfx) orelse return error.UnknownRegion;
            var spikes: usize = 0;
            for (0..@min(0x80, r.slots.len)) |id| {
                if (col[id] & spike_bit != 0) spikes += 1;
            }
            if (spikes == 0) continue;
            const others = try othersOf(rom, ts, gfx);
            for (0..@min(0x80, r.slots.len)) |id| {
                if (col[id] & spike_bit == 0) continue;
                const s = slot(gfx, id).?;
                if (others & (@as(u8, 1) << s) != 0) {
                    // Only where no slot is free, which `tile_choices` says.
                    try testing.expectEqual(@as(u8, 0xFF), others);
                    unfree += 1;
                }
            }
        }
    }
    // `ruinsExt`'s twelve, and nothing else.
    try testing.expectEqual(@as(usize, 12), unfree);
}
