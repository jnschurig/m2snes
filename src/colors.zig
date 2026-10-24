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

pub const Scheme = enum(u8) {
    /// Four evenly spaced greys: the port as it was before schemes.
    mono = 0,
    /// What a Game Boy Color shows for Metroid II.
    gbc = 1,
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

pub fn tables(scheme: Scheme) Tables {
    return switch (scheme) {
        .mono => .{ .bg = greys, .window = greys, .obp0 = greys, .obp1 = greys },
        .gbc => .{ .bg = gbc_bg, .window = gbc_bg, .obp0 = gbc_obp0, .obp1 = gbc_obp1 },
    };
}

/// How many schemes the cart carries: every id below this is valid.
pub const count: u8 = @typeInfo(Scheme).@"enum".fields.len;

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
    try std.testing.expectEqual(@as(u8, 2), count);
}
