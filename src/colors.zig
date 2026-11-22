//! The cart's colour schemes: the one place colour values live.
//!
//! A scheme is four tables of four colours, one per Game Boy palette layer:
//! the play field (`BGP`), the HUD window (also `BGP` on the Game Boy, but its
//! own CGRAM slot here), and the two object palettes. Each table is indexed by
//! DMG shade, lightest first. The DMG palette registers pick from them the way
//! a Game Boy Color does in compatibility mode, which is `cgramWords`.
//!
//! Adding a scheme is adding a `Scheme` id and a `tables` entry. The id is
//! what SRAM stores for each save slot, so an id never changes meaning.

const std = @import("std");
const screens = @import("screens.zig");
const areas = @import("areas.zig");
const target = @import("snes_target.zig");

pub const Scheme = enum(u8) {
    /// Four evenly spaced greys: the port as it was before schemes.
    mono = 0,
    /// What a Game Boy Color shows for Metroid II.
    gbc = 1,
    /// Colorization: a palette per source tile (`full_assign.zig`), in
    /// colours per area (`full`).
    full = 2,
};

/// What fresh SRAM, a bad scheme byte, and every boot that skips the title
/// get. The gate's rungs zero SRAM first, so this is the scheme they grade.
pub const default_scheme: Scheme = .gbc;

/// Four BGR555 colours, shade 0 (lightest) first.
pub const Table = [4]u16;

pub const Tables = struct {
    bg: Table,
    window: Table,
    obp0: Table,
    obp1: Table,

    /// The four tables in CGRAM order. `cgramWords` and the shade map both
    /// walk this, so they cannot disagree about which table is which.
    pub fn layers(t: Tables) [4]Table {
        return .{ t.bg, t.window, t.obp0, t.obp1 };
    }
};

/// A DMG shade as a 15-bit SNES colour. Four evenly spaced greys, lightest
/// first, which is the order `BGP` numbers them in.
pub fn grey(shade: u2) u16 {
    const level: u16 = switch (shade) {
        0 => 31,
        1 => 21,
        2 => 10,
        3 => 0,
    };
    return level | (level << 5) | (level << 10);
}

const greys: Table = .{ grey(0), grey(1), grey(2), grey(3) };

/// The CGB boot ROM's palettes for Metroid II: title checksum `$46`, fourth
/// letter `R`, palette combination 46, which picks `Palettes` entry 28 for the
/// background and window, 25 for OBJ0 and 3 for OBJ1. Source: SameBoy's
/// `vendor/sameboy/BootROMs/cgb_boot.asm` (MIT). The values are copied raw,
/// with no colour correction.
const gbc_bg: Table = .{ 0x7FFF, 0x7E8C, 0x7C00, 0x0000 }; // Palettes 28
const gbc_obp0: Table = .{ 0x03FF, 0x001F, 0x000C, 0x0000 }; // Palettes 25
const gbc_obp1: Table = .{ 0x7FFF, 0x1BEF, 0x0200, 0x0000 }; // Palettes 3

/// The scheme's four tables. For `full` these are one view of it: the
/// `surface` set's slot 0, the window's first palette and OBJ slots 0 and 1,
/// which are what `cgramWords` and the `schemes` rung tell schemes apart by.
pub fn tables(scheme: Scheme) Tables {
    return switch (scheme) {
        .mono => .{ .bg = greys, .window = greys, .obp0 = greys, .obp1 = greys },
        .gbc => .{ .bg = gbc_bg, .window = gbc_bg, .obp0 = gbc_obp0, .obp1 = gbc_obp1 },
        .full => .{
            .bg = full.bg[areas.setOf(.{ .area = .surface })][0],
            .window = full.window[0],
            .obp0 = full.obj[0],
            .obp1 = full.obj[1],
        },
    };
}

// ---- `full` -------------------------------------------------------------------

/// A palette slot's four colours a layer: BG3's 8 palettes, the objects' 8.
pub const slot_count = 8;
pub const Slots = [slot_count]Table;
/// The Metroid damage steps OBJ palette 2 shows (`full_slots.metroidStep`):
/// step 0 is slot 2's own colours, so `Full.damage` holds steps 1-3.
pub const damage_steps = 4;

/// `full`'s colours, all shade-indexed like every other table here. The
/// background's are per colour set (`areas.setOf`), the window's and the
/// objects' global. Every BG slot's shade 3 is black: BGP `$93` puts it at
/// colour 0, the backdrop.
pub const Full = struct {
    bg: [areas.set_count]Slots,
    /// One per pair of slots, `snes_target.hud_palette` on.
    window: [target.window_palettes]Table,
    obj: Slots,
    /// OBJ palette 2 at damage steps 1-3, outside the Queen's room.
    damage: [damage_steps - 1]Table,
};

/// Placeholder colours (colorization Step 8): a distinct hue per colour set,
/// stepped a little per slot. Step 9 replaces them with Samus Returns'.
pub const full: Full = blk: {
    @setEvalBranchQuota(100_000);
    var f: Full = undefined;
    for (0..areas.set_count) |s| for (0..slot_count) |i| {
        f.bg[s][i] = placeholderRamp(@intCast((s * 360 / areas.set_count + i * 5) % 360));
    };
    for (0..target.window_palettes) |i| f.window[i] = placeholderRamp(@intCast(220 + i * 12));
    for (0..slot_count) |i| f.obj[i] = placeholderRamp(@intCast((i * 45 + 20) % 360));
    // Slot 4, a Metroid's body (hue 200), round through magenta to red.
    for (0..damage_steps - 1, [_]u16{ 280, 320, 0 }) |k, h| f.damage[k] = placeholderRamp(h);
    break :blk f;
};

/// Four shades of one hue, lightest first, shade 3 black.
fn placeholderRamp(hue: u16) Table {
    return .{ hsv(hue, 35, 31), hsv(hue, 80, 24), hsv(hue, 100, 13), 0 };
}

/// A BGR555 colour from a hue in degrees, a saturation in percent and a 5-bit
/// value.
fn hsv(hue: u32, sat: u32, val: u32) u16 {
    const sector = hue / 60;
    const f = hue % 60;
    const p = val * (100 - sat) / 100;
    const q = val * (100 * 60 - sat * f) / (100 * 60);
    const t = val * (100 * 60 - sat * (60 - f)) / (100 * 60);
    const rgb: [3]u32 = switch (sector) {
        0 => .{ val, t, p },
        1 => .{ q, val, p },
        2 => .{ p, val, t },
        3 => .{ p, q, val },
        4 => .{ t, p, val },
        else => .{ val, p, q },
    };
    return @intCast(rgb[0] | (rgb[1] << 5) | (rgb[2] << 10));
}

/// Words in one colour set's part of the cart's `full` table: BG3's 8
/// palettes of 4.
pub const full_set_words = slot_count * 4;
/// Words in the table's global part: the window's palettes, the objects' 8,
/// and the damage steps.
pub const full_global_words = (@as(usize, target.window_palettes) + slot_count + damage_steps - 1) * 4;
pub const full_table_words = areas.set_count * full_set_words + full_global_words;

/// The cart's `full` table, as `LoadPalette` reads it: every colour set's BG3
/// palettes through `live_bgp`, then the window's through `live_bgp`, the
/// objects' through `live_obp0` and the damage steps through `live_obp0`.
/// Every object palette takes OBP0's register: as EJRTQ's palettes ignore
/// the registers, an OBP1 object changes palette (the OBP1 swap) and not
/// register.
pub fn fullTable() [full_table_words]u16 {
    var out: [full_table_words]u16 = undefined;
    var n: usize = 0;
    for (full.bg) |set| for (set) |t| {
        out[n..][0..4].* = apply(t, screens.live_bgp);
        n += 4;
    };
    for (full.window) |t| {
        out[n..][0..4].* = apply(t, screens.live_bgp);
        n += 4;
    }
    for (full.obj ++ full.damage) |t| {
        out[n..][0..4].* = apply(t, screens.live_obp0);
        n += 4;
    }
    std.debug.assert(n == full_table_words);
    return out;
}

/// Rec. 601 luma of a BGR555 colour, in arbitrary units: what "darkest" means.
pub fn luma(c: u16) u32 {
    return 299 * @as(u32, c & 31) + 587 * @as(u32, (c >> 5) & 31) + 114 * @as(u32, (c >> 10) & 31);
}

/// How many schemes the cart carries: every id below this is valid.
pub const count: u8 = @typeInfo(Scheme).@"enum".fields.len;

/// Where cartridge RAM keeps each slot's scheme (colour schemes Step 6): the
/// magic, then one id a slot. Past the spawn flags, in the part of the Game
/// Boy's $A000-$BFFF the game never touches (`save.spawn_end`).
pub const sram_at: u16 = 0x1600;
pub const sram_magic = [4]u8{ 'M', '2', 'C', 'S' };
/// The SRAM bytes a slot's id is at.
pub fn sramSlot(slot: u8) u16 {
    return sram_at + @as(u16, sram_magic.len) + slot;
}

/// One table seen through a DMG palette register: entry `i` is the colour of
/// the shade the register's field `i` names.
pub fn apply(table: Table, reg: u8) Table {
    var out: Table = undefined;
    for (0..4) |i| out[i] = table[(reg >> @intCast(i * 2)) & 3];
    return out;
}

/// The 16 CGRAM words a scheme loads, in the order the cart stores them:
/// BG palette 0 (`$00-$03`), the HUD's slot (`$10-$13`), and the two object
/// palettes (`$80-$83`, `$90-$93`), each through the live register the
/// survey found (`screens.live_bgp/obp0/obp1`).
pub fn cgramWords(scheme: Scheme) [16]u16 {
    const t = tables(scheme);
    // `full` puts every object palette through OBP0's register (`fullTable`).
    if (scheme == .full) return apply(t.bg, screens.live_bgp) ++ apply(t.window, screens.live_bgp) ++
        apply(t.obp0, screens.live_obp0) ++ apply(t.obp1, screens.live_obp0);
    return apply(t.bg, screens.live_bgp) ++ apply(t.window, screens.live_bgp) ++
        apply(t.obp0, screens.live_obp0) ++ apply(t.obp1, screens.live_obp1);
}

/// The shade a colour stands for in `scheme`, across all four tables, or
/// null if the scheme has no such colour. Graders use this to read a pixel
/// back as a shade without knowing which layer drew it, which only works if
/// no colour stands for two shades (`uniqueShades`).
pub fn shadeOf(scheme: Scheme, colour: u16) ?u2 {
    return shadeIn(tables(scheme), colour);
}

fn shadeIn(t: Tables, colour: u16) ?u2 {
    for (t.layers()) |table| {
        for (table, 0..) |c, s| if (c == colour) return @intCast(s);
    }
    return null;
}

/// A 15-bit colour as Mesen2's framebuffer holds it, `0xRRGGBB`: each 5-bit
/// channel `c` becomes `(c << 3) | (c >> 2)`.
pub fn rgb888(colour: u16) u24 {
    const x = struct {
        fn of(c: u16) u24 {
            const v: u24 = c & 31;
            return (v << 3) | (v >> 2);
        }
    };
    return (x.of(colour) << 16) | (x.of(colour >> 5) << 8) | x.of(colour >> 10);
}

/// The exit code a generated `shade` stops with when a pixel is no colour of
/// its scheme. It is free in every script that reads pixels, so each one's
/// describer gives it the same meaning.
pub const lua_off_scheme: u8 = 5;
pub const off_scheme_why = "a pixel's colour is not one of the scheme's: CGRAM holds another scheme, or the frame was dimmed";

/// Writes a Lua `shade(px)` that reads a Mesen2 framebuffer pixel back as the
/// DMG shade it stands for in `scheme`, through `shadeOf`. It matches exactly:
/// a colour outside the scheme prints its RGB and stops the script with
/// `lua_off_scheme`. It never guesses the nearest colour, so a dimmed frame
/// or a wrong palette shows up as that code and not as a misread shade.
pub fn writeLuaShade(w: *std.Io.Writer, scheme: Scheme) !void {
    // One top-level local, `shade`: `m2snes.lua` sits near Lua's 200.
    try w.print("-- The `{s}` scheme's colours as Mesen draws them, each the shade it stands for\n", .{@tagName(scheme)});
    try w.writeAll("-- (`colors.writeLuaShade`). Anything else is no colour of the scheme.\nlocal shade\ndo\n  local of = {");
    const words = cgramWords(scheme);
    for (words, 0..) |c, i| {
        if (std.mem.indexOfScalar(u16, words[0..i], c) != null) continue;
        try w.print(" [0x{X:0>6}] = {d},", .{ rgb888(c), shadeOf(scheme, c).? });
    }
    // `emu.stop` does not return, so the error ends the callback before it
    // goes on with a nil shade.
    try w.print(
        \\ }}
        \\  function shade(px)
        \\    local s = of[px & 0xFFFFFF]
        \\    if s == nil then
        \\      print(string.format("a pixel's colour %06X is not one of the {s} scheme's", px & 0xFFFFFF))
        \\      emu.stop({d})
        \\      error("off-scheme pixel")
        \\    end
        \\    return s
        \\  end
        \\end
        \\
    , .{ @tagName(scheme), lua_off_scheme });
}

/// True when every colour in `t` stands for exactly one shade.
pub fn uniqueShades(t: Tables) bool {
    for (t.layers()) |table| {
        for (table, 0..) |c, s| if (shadeIn(t, c).? != s) return false;
    }
    return true;
}

test "mono is the greys the port always had" {
    const words = cgramWords(.mono);
    const bg = [_]u16{ grey(3), grey(0), grey(1), grey(2) }; // BGP $93
    const obp1 = [_]u16{ grey(3), grey(0), grey(0), grey(1) }; // OBP1 $43
    try std.testing.expectEqualSlices(u16, &bg, words[0..4]);
    try std.testing.expectEqualSlices(u16, &bg, words[4..8]);
    try std.testing.expectEqualSlices(u16, &bg, words[8..12]);
    try std.testing.expectEqualSlices(u16, &obp1, words[12..16]);
    try std.testing.expectEqual(@as(u16, 0x7FFF), grey(0));
    try std.testing.expectEqual(@as(u16, 0x56B5), grey(1));
    try std.testing.expectEqual(@as(u16, 0x294A), grey(2));
    try std.testing.expectEqual(@as(u16, 0x0000), grey(3));
}

test "gbc is the boot ROM's combination 46 through the live registers" {
    const t = tables(.gbc);
    try std.testing.expectEqualSlices(u16, &.{ 0x7FFF, 0x7E8C, 0x7C00, 0x0000 }, &t.bg);
    try std.testing.expectEqualSlices(u16, &t.bg, &t.window);
    try std.testing.expectEqualSlices(u16, &.{ 0x03FF, 0x001F, 0x000C, 0x0000 }, &t.obp0);
    try std.testing.expectEqualSlices(u16, &.{ 0x7FFF, 0x1BEF, 0x0200, 0x0000 }, &t.obp1);
    // The worked values in F1. Colour 0 of an object palette is transparent,
    // so only 1-3 are graded there.
    const words = cgramWords(.gbc);
    try std.testing.expectEqualSlices(u16, &.{ 0x0000, 0x7FFF, 0x7E8C, 0x7C00 }, words[0..4]);
    try std.testing.expectEqualSlices(u16, words[0..4], words[4..8]);
    try std.testing.expectEqualSlices(u16, &.{ 0x03FF, 0x001F, 0x000C }, words[9..12]);
    try std.testing.expectEqualSlices(u16, &.{ 0x7FFF, 0x7FFF, 0x1BEF }, words[13..16]);
}

test "within each scheme every colour stands for one shade" {
    inline for (@typeInfo(Scheme).@"enum".fields) |f| {
        try std.testing.expect(uniqueShades(tables(@enumFromInt(f.value))));
    }
    // And the check can fail: a table that reuses a colour at another shade.
    var bad = tables(.gbc);
    bad.obp0[1] = bad.bg[2];
    try std.testing.expect(!uniqueShades(bad));
}

test "no scheme puts Fatal's magenta in colour 0" {
    inline for (@typeInfo(Scheme).@"enum".fields) |f| {
        const words = cgramWords(@enumFromInt(f.value));
        for ([_]usize{ 0, 4, 8, 12 }) |i| try std.testing.expect(words[i] != 0x7C1F);
    }
}

test "rgb888 is Mesen's expansion of each channel" {
    try std.testing.expectEqual(@as(u24, 0xFFFFFF), rgb888(0x7FFF));
    try std.testing.expectEqual(@as(u24, 0x000000), rgb888(0x0000));
    try std.testing.expectEqual(@as(u24, 0xADADAD), rgb888(grey(1))); // 21 -> 173
    try std.testing.expectEqual(@as(u24, 0x0000FF), rgb888(0x7C00)); // blue is the high channel
    try std.testing.expectEqual(@as(u24, 0xFF0000), rgb888(0x001F));
}

test "the Lua shade lists each of the scheme's colours once, at its shade" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeLuaShade(&w, .gbc);
    const src = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, src, "[0xFFFFFF] = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "[0x000000] = 3,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "[0x63A5FF] = 1,") != null); // $7E8C
    try std.testing.expect(std.mem.indexOf(u8, src, "emu.stop(5)") != null);
    // Zig's multiline strings are raw: a doubled brace or percent would reach
    // the emulator as-is and kill the script.
    try std.testing.expect(std.mem.indexOf(u8, src, "{{") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "%%") == null);
}

test "the default is a valid id" {
    try std.testing.expect(@intFromEnum(default_scheme) < count);
    try std.testing.expectEqual(@as(u8, 3), count);
}

test "full's table: every set's slots, then the window, the objects and the damage steps, through the live registers" {
    const t = fullTable();
    const surface = areas.setOf(.{ .area = .surface });
    const acid = areas.setOf(.acid);
    for ([_]usize{ surface, acid }) |s| for (0..slot_count) |i| {
        const at = (s * slot_count + i) * 4;
        try std.testing.expectEqualSlices(u16, &apply(full.bg[s][i], screens.live_bgp), t[at..][0..4]);
    };
    const g = areas.set_count * full_set_words;
    try std.testing.expectEqualSlices(u16, &apply(full.window[1], screens.live_bgp), t[g + 4 ..][0..4]);
    const o = g + @as(usize, target.window_palettes) * 4;
    try std.testing.expectEqualSlices(u16, &apply(full.obj[3], screens.live_obp0), t[o + 12 ..][0..4]);
    try std.testing.expectEqualSlices(u16, &apply(full.damage[2], screens.live_obp0), t[o + slot_count * 4 + 8 ..][0..4]);
    // A synthetic slot: BGP $93 puts shade 3 at colour 0, the backdrop.
    try std.testing.expectEqualSlices(u16, &.{ 4, 1, 2, 3 }, &apply(.{ 1, 2, 3, 4 }, screens.live_bgp));
}

test "full: colour 0 of every BG palette is black, and shade 3 is each slot's darkest" {
    const t = fullTable();
    for (0..areas.set_count * slot_count + target.window_palettes) |p| {
        try std.testing.expectEqual(@as(u16, 0), t[p * 4]);
    }
    const all = [_][]const Table{ &full.window, &full.obj, &full.damage };
    for (full.bg) |set| for (set) |slot| for (slot[0..3]) |c| try std.testing.expect(luma(slot[3]) <= luma(c));
    for (all) |ts| for (ts) |slot| for (slot[0..3]) |c| try std.testing.expect(luma(slot[3]) <= luma(c));
}

test "full's placeholder sets are told apart" {
    for (0..areas.set_count) |a| for (a + 1..areas.set_count) |b| {
        try std.testing.expect(!std.mem.eql(u16, &full.bg[a][0], &full.bg[b][0]));
    };
    // And the rung can tell `full` from the other schemes by its 16 words,
    // which are the table's where `LoadPalette` puts them: the surface set's
    // BG3 palette 0, the window's first, and OBJ palettes 0 and 1.
    const f = cgramWords(.full);
    const t = fullTable();
    const surf = areas.setOf(.{ .area = .surface }) * full_set_words;
    const g = areas.set_count * full_set_words;
    const o = g + @as(usize, target.window_palettes) * 4;
    try std.testing.expectEqualSlices(u16, t[surf..][0..4], f[0..4]);
    try std.testing.expectEqualSlices(u16, t[g..][0..4], f[4..8]);
    try std.testing.expectEqualSlices(u16, t[o..][0..8], f[8..16]);
    for ([_]Scheme{ .mono, .gbc }) |s| try std.testing.expect(!std.mem.eql(u16, &f, &cgramWords(s)));
}
