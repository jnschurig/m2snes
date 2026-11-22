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
//!  - Then, per character sheet (`chr_bg` and `chr_obj`), one byte per
//!    16-byte Game Boy tile: the high byte of a play-field word showing it
//!    (`attr`), the slot as its palette and BG3's priority bit. The engine
//!    DMAs these straight into `!BgAttr`, which `MetaPut` reads whole. A 4bpp sheet has one byte per 32-byte character, which
//!    is still one Game Boy tile.
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
        for (0..tiles(s)) |t| out[at + t] = attr(slotAt(s.rom_at + t * 16));
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
