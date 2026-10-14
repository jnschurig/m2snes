//! The `gbc` scheme graded against a Game Boy Color, not against our own copy
//! of the numbers (gbc-color-option F4).
//!
//! SameBoy boots the plain ROM in its CGB model with its own boot ROM, and the
//! palettes the boot ROM leaves behind are what a Game Boy Color draws Metroid
//! II in. This half grades them; `gbc_oracle_run.zig` produces them, and is the
//! only half that links SameBoy.

const std = @import("std");
const colors = @import("colors.zig");

/// Where the gate finds SameBoy's CGB boot ROM: assembled from source under
/// `vendor/`, never Nintendo's and never tracked.
pub const boot_path = "vendor/sameboy/build/bin/tester/cgb_boot.bin";

/// Palette RAM as SameBoy holds it: eight palettes of four BGR555 words.
pub const PaletteRam = [32]u16;

pub const Mismatch = struct {
    layer: []const u8,
    want: colors.Table,
    got: colors.Table,
};

/// The first table where SameBoy's palettes and `scheme`'s differ, or null if
/// BG palette 0, OBJ palette 0 and OBJ palette 1 all match. In compatibility
/// mode the DMG registers index these raw, so they compare against the tables
/// themselves, not `cgramWords`.
pub fn grade(scheme: colors.Scheme, bg: PaletteRam, obj: PaletteRam) ?Mismatch {
    const t = colors.tables(scheme);
    const checks = [_]struct { []const u8, colors.Table, colors.Table }{
        .{ "BG palette 0", t.bg, bg[0..4].* },
        .{ "OBJ palette 0", t.obp0, obj[0..4].* },
        .{ "OBJ palette 1", t.obp1, obj[4..8].* },
    };
    for (checks) |c| {
        if (!std.mem.eql(u16, &c[1], &c[2])) return .{ .layer = c[0], .want = c[1], .got = c[2] };
    }
    return null;
}

/// Palette RAM laid out the way the CGB boot ROM leaves it for `scheme`.
fn ramFor(scheme: colors.Scheme) [2]PaletteRam {
    const t = colors.tables(scheme);
    var bg: PaletteRam = @splat(0);
    var obj: PaletteRam = @splat(0);
    bg[0..4].* = t.bg;
    obj[0..4].* = t.obp0;
    obj[4..8].* = t.obp1;
    return .{ bg, obj };
}

test "a CGB that loaded the gbc tables passes" {
    const r = ramFor(.gbc);
    try std.testing.expectEqual(null, grade(.gbc, r[0], r[1]));
}

test "fault check: mono's tables fail the gbc grade" {
    const r = ramFor(.mono);
    try std.testing.expect(grade(.gbc, r[0], r[1]) != null);
}

test "each object palette is checked on its own" {
    var r = ramFor(.gbc);
    r[1][5] ^= 1;
    try std.testing.expectEqualStrings("OBJ palette 1", grade(.gbc, r[0], r[1]).?.layer);
}
