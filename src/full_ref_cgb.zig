//! Validation of the full scheme's reference (colorization Step 5): the static
//! model against the patched ROM running on a Game Boy Color.
//!
//! SameBoy (`sbcgb.c`, linked by `full_ref_cgb_run.zig`) boots the patched ROM
//! and reports, at a chosen frame, both VRAM banks, OAM and which ROM tile
//! each VRAM tile was last copied from. The model says:
//!  - **background and window:** the attribute byte (VRAM bank 1) under each
//!    visible map byte is the slot of the source tile that id shows, by LCDC's
//!    addressing, with no other bits set;
//!  - **sprites:** an entry's palette is its tile's slot, through the OBP1
//!    swap; a frozen enemy's is the frozen slot;
//!  - **EJRTQ's table** (`$D200-$D37F`) holds each tracked VRAM tile's slot.
//! This grades those against `full_assign.zig`. It is ROM-free: the caller
//! supplies the slot of each ROM tile.

const std = @import("std");

/// `sbcgb_out_t`, field for field.
pub const Out = extern struct {
    src: [384]u32,
    vram: [0x4000]u8,
    oam: [0xA0]u8,
    table: [0x180]u8,
    lcdc: u8,
    scy: u8,
    scx: u8,
    wy: u8,
    wx: u8,
    game_mode: u8,
    samus_oam_end: u8,
    oam_end: u8,
    frames: u32,
    named: u32,
    unnamed: u32,
    miss_pc: u16,
    miss_hl: u16,
    miss_de: u16,
    miss_bank: u16,
    miss_addr: u16,
    miss_data: u8,
};

pub const initial: u32 = 0xFFFFFFFE;
pub const unknown: u32 = 0xFFFFFFFF;

/// The slot of the ROM tile at a flat offset, or null if it is not a
/// graphics tile.
pub const SlotOf = struct {
    ctx: *const anyopaque,
    f: *const fn (*const anyopaque, u32) ?u3,

    pub fn get(self: SlotOf, flat: u32) ?u3 {
        return self.f(self.ctx, flat);
    }
};

pub const Rules = struct { when: u3, then: u3, otherwise: u3, frozen: u3 };

pub const Layer = enum { bg, window, obj, table };

pub const Mismatch = struct {
    layer: Layer,
    /// Map row and column, OAM entry, or VRAM tile.
    row: u8,
    col: u8,
    id: u8,
    tile: u16,
    src: u32,
    want: u3,
    got: u8,
};

pub const Grade = struct {
    compared: [4]usize = @splat(0),
    /// Shown tiles with no tracked source.
    untracked: [4]usize = @splat(0),
    /// Sprites EJRTQ drew in the frozen slot where the model says otherwise:
    /// counted, not failed (the model can't see `iceCounter` from OAM).
    frozen: usize = 0,
    /// Map cells whose attribute differs but whose tile, as VRAM holds it,
    /// is colour 0 only: it looks the same in every slot (colour 0 is black
    /// in all of them), so the difference can't be seen. EJRTQ leaves the
    /// status bar's digit fields in the digits' slot when it blanks them.
    invisible: usize = 0,
    mismatches: std.ArrayList(Mismatch) = .empty,

    pub fn failed(self: Grade) bool {
        return self.mismatches.items.len != 0;
    }
};

/// The VRAM tile a background map byte shows: LCDC bit 4 clear is signed
/// addressing (`$00-$7F` are tiles `$100-$17F`).
pub fn bgTile(id: u8, lcdc: u8) u16 {
    if (lcdc & 0x10 == 0 and id < 0x80) return 0x100 + @as(u16, id);
    return id;
}

/// One visible map cell: which map, and its row and column.
pub const Cell = struct { window: bool, base: u16, row: u8, col: u8 };

/// The map cells on screen, as the coverage script finds them: the
/// background's 21x19 under the scroll less what the window covers, then the
/// window's.
pub fn visibleCells(buf: *std.ArrayList(Cell), allocator: std.mem.Allocator, o: *const Out) !void {
    if (o.lcdc & 0x80 == 0 or o.lcdc & 0x01 == 0) return;
    const win = o.lcdc & 0x20 != 0 and o.wy <= 143 and o.wx <= 166;
    const wxs: i32 = @as(i32, o.wx) - 7;
    const base: u16 = if (o.lcdc & 0x08 != 0) 0x1C00 else 0x1800;
    for (0..19) |k| {
        const top: i32 = @as(i32, @intCast(k * 8)) - (o.scy & 7);
        if (top > 143) continue;
        const ytop = @max(top, 0);
        var limit: i32 = 160;
        if (win and ytop >= o.wy) limit = @max(wxs, 0);
        const r: u8 = @intCast(((o.scy >> 3) + k) & 31);
        for (0..21) |j| {
            const left: i32 = @as(i32, @intCast(j * 8)) - (o.scx & 7);
            if (@max(left, 0) < limit and left <= 159)
                try buf.append(allocator, .{ .window = false, .base = base, .row = r, .col = @intCast(((o.scx >> 3) + j) & 31) });
        }
    }
    if (win) {
        const wbase: u16 = if (o.lcdc & 0x40 != 0) 0x1C00 else 0x1800;
        var r: u8 = 0;
        while (r <= (143 - o.wy) >> 3) : (r += 1) {
            for (0..32) |c| {
                const x = wxs + @as(i32, @intCast(c * 8));
                if (x > 159) break;
                if (x + 7 >= 0) try buf.append(allocator, .{ .window = true, .base = wbase, .row = r, .col = @intCast(c) });
            }
        }
    }
}

pub fn grade(allocator: std.mem.Allocator, o: *const Out, slot_of: SlotOf, rules: Rules) !Grade {
    var g: Grade = .{};
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(allocator);
    try visibleCells(&cells, allocator, o);
    for (cells.items) |c| {
        const layer: Layer = if (c.window) .window else .bg;
        const at = @as(usize, c.base) + @as(usize, c.row) * 32 + c.col;
        const id = o.vram[at];
        const attr = o.vram[0x2000 + at];
        const tile = bgTile(id, o.lcdc);
        const src = o.src[tile];
        const want = slot_of.get(src) orelse {
            g.untracked[@intFromEnum(layer)] += 1;
            continue;
        };
        g.compared[@intFromEnum(layer)] += 1;
        if (attr == want) continue;
        if (std.mem.allEqual(u8, o.vram[@as(usize, tile) * 16 ..][0..16], 0)) {
            g.invisible += 1;
            continue;
        }
        try g.mismatches.append(allocator, .{ .layer = layer, .row = c.row, .col = c.col, .id = id, .tile = tile, .src = src, .want = want, .got = attr });
    }
    if (o.lcdc & 0x80 != 0 and o.lcdc & 0x02 != 0) {
        const tall = o.lcdc & 0x04 != 0;
        const h: u8 = if (tall) 16 else 8;
        for (0..40) |i| {
            const y = o.oam[i * 4];
            const x = o.oam[i * 4 + 1];
            if (!(y > 16 - h and y < 160 and x > 0 and x < 168)) continue;
            const id = o.oam[i * 4 + 2];
            const flags = o.oam[i * 4 + 3];
            const tile: u16 = if (tall) id & 0xFE else id;
            const src = o.src[tile];
            const s = slot_of.get(src) orelse {
                g.untracked[@intFromEnum(Layer.obj)] += 1;
                continue;
            };
            const want: u3 = if (flags & 0x10 == 0) s else if (s == rules.when) rules.then else rules.otherwise;
            const got = flags & 7;
            g.compared[@intFromEnum(Layer.obj)] += 1;
            if (got == want) continue;
            if (got == rules.frozen and i >= o.samus_oam_end / 4) {
                g.frozen += 1;
                continue;
            }
            try g.mismatches.append(allocator, .{ .layer = .obj, .row = @intCast(i), .col = 0, .id = id, .tile = tile, .src = src, .want = want, .got = got });
        }
    }
    for (o.table, 0..) |v, t| {
        const want = slot_of.get(o.src[t]) orelse continue;
        g.compared[@intFromEnum(Layer.table)] += 1;
        if (v != want) try g.mismatches.append(allocator, .{ .layer = .table, .row = 0, .col = 0, .id = 0, .tile = @intCast(t), .src = o.src[t], .want = want, .got = v });
    }
    return g;
}

/// A button byte in `gb_trace`'s order (A, B, select, start, right, left,
/// up, down from bit 0) as SameBoy's key mask (right, left, up, down, A, B,
/// select, start).
pub fn keyMask(held: u8) u8 {
    return (held >> 4) | (held << 4);
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

fn blankOut() Out {
    var o = std.mem.zeroes(Out);
    @memset(&o.src, initial);
    o.lcdc = 0x83; // on, BG, sprites; signed addressing, map $9800
    o.wy = 144;
    return o;
}

const TestSlots = struct {
    fn f(_: *const anyopaque, flat: u32) ?u3 {
        if (flat >= 0x10000) return null;
        return @intCast((flat >> 4) & 7);
    }
    const it: SlotOf = .{ .ctx = undefined, .f = f };
};

test "the key mask swaps nibbles" {
    try testing.expectEqual(@as(u8, 0x80), keyMask(0x08)); // start
    try testing.expectEqual(@as(u8, 0x01), keyMask(0x10)); // right
    try testing.expectEqual(@as(u8, 0x10), keyMask(0x01)); // A
}

test "unscrolled, the background shows 20x18 cells; the window takes its rows" {
    var o = blankOut();
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(testing.allocator);
    try visibleCells(&cells, testing.allocator, &o);
    try testing.expectEqual(@as(usize, 20 * 18), cells.items.len);
    // A full-width window from line 128: two window rows of 20, and the
    // background loses its last two rows.
    o.lcdc |= 0x20 | 0x40;
    o.wy = 128;
    o.wx = 7;
    cells.clearRetainingCapacity();
    try visibleCells(&cells, testing.allocator, &o);
    var win: usize = 0;
    for (cells.items) |c| {
        if (c.window) win += 1;
    }
    try testing.expectEqual(@as(usize, 40), win);
    try testing.expectEqual(@as(usize, 20 * 16), cells.items.len - win);
}

test "a matching attribute passes, a wrong one is reported with its cell" {
    var o = blankOut();
    // Map byte $05 at row 0, col 0 shows tile $105 (signed); its source is
    // flat $30, slot 3 by TestSlots.
    o.vram[0x1800] = 0x05;
    o.src[0x105] = 0x30;
    o.table[0x105] = 3;
    o.vram[0x105 * 16] = 0x80; // one pixel, so a wrong slot shows
    o.vram[0x2000 + 0x1800] = 3;
    var g = try grade(testing.allocator, &o, TestSlots.it, .{ .when = 3, .then = 1, .otherwise = 3, .frozen = 3 });
    defer g.mismatches.deinit(testing.allocator);
    try testing.expect(!g.failed());
    try testing.expectEqual(@as(usize, 1), g.compared[@intFromEnum(Layer.bg)]);

    o.vram[0x2000 + 0x1800] = 2;
    var g2 = try grade(testing.allocator, &o, TestSlots.it, .{ .when = 3, .then = 1, .otherwise = 3, .frozen = 3 });
    defer g2.mismatches.deinit(testing.allocator);
    try testing.expect(g2.failed());
    try testing.expectEqual(Mismatch{ .layer = .bg, .row = 0, .col = 0, .id = 5, .tile = 0x105, .src = 0x30, .want = 3, .got = 2 }, g2.mismatches.items[0]);
}

test "sprites go through the OBP1 swap; the frozen slot is counted, not failed" {
    var o = blankOut();
    o.src[0x02] = 0x30; // slot 3
    o.src[0x04] = 0x50; // slot 5
    o.table[0x02] = 3;
    o.table[0x04] = 5;
    // Entry 0: tile 2 with OBP1 -> 3 becomes 1.
    o.oam[0..4].* = .{ 50, 50, 0x02, 0x10 | 1 };
    // Entry 1: tile 4 with OBP1 -> 5 becomes 3.
    o.oam[4..8].* = .{ 50, 60, 0x04, 0x10 | 3 };
    // Entry 2: tile 4, no OBP1, drawn frozen (3).
    o.oam[8..12].* = .{ 50, 70, 0x04, 3 };
    const rules: Rules = .{ .when = 3, .then = 1, .otherwise = 3, .frozen = 3 };
    var g = try grade(testing.allocator, &o, TestSlots.it, rules);
    defer g.mismatches.deinit(testing.allocator);
    try testing.expect(!g.failed());
    try testing.expectEqual(@as(usize, 1), g.frozen);
    // Entry 2 as Samus's (before $D064) is a mismatch, not frozen.
    o.samus_oam_end = 12;
    var g2 = try grade(testing.allocator, &o, TestSlots.it, rules);
    defer g2.mismatches.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), g2.mismatches.items.len);
}

test "EJRTQ's table is checked for every tracked tile" {
    var o = blankOut();
    o.src[7] = 0x20; // slot 2
    o.table[7] = 2;
    var g = try grade(testing.allocator, &o, TestSlots.it, .{ .when = 3, .then = 1, .otherwise = 3, .frozen = 3 });
    defer g.mismatches.deinit(testing.allocator);
    try testing.expect(!g.failed());
    try testing.expectEqual(@as(usize, 1), g.compared[@intFromEnum(Layer.table)]);
    o.table[7] = 4;
    var g2 = try grade(testing.allocator, &o, TestSlots.it, .{ .when = 3, .then = 1, .otherwise = 3, .frozen = 3 });
    defer g2.mismatches.deinit(testing.allocator);
    try testing.expectEqual(Layer.table, g2.mismatches.items[0].layer);
}

test "a wrong attribute under a colour-0-only tile is invisible, not a failure" {
    var o = blankOut();
    o.vram[0x1800] = 0x05;
    o.src[0x105] = 0x30; // slot 3
    o.table[0x105] = 3;
    o.vram[0x2000 + 0x1800] = 7;
    const rules: Rules = .{ .when = 3, .then = 1, .otherwise = 3, .frozen = 3 };
    var g = try grade(testing.allocator, &o, TestSlots.it, rules);
    defer g.mismatches.deinit(testing.allocator);
    try testing.expect(!g.failed());
    try testing.expectEqual(@as(usize, 1), g.invisible);
    // One non-zero pixel row makes it visible.
    o.vram[0x105 * 16] = 0x80;
    var g2 = try grade(testing.allocator, &o, TestSlots.it, rules);
    defer g2.mismatches.deinit(testing.allocator);
    try testing.expect(g2.failed());
}
