//! The palettes a Game Boy Color picks for the configured ROM, from SameBoy.
//! Links SameBoy (`sbref.c`), so only a gate built with `vendor/sameboy`
//! present reaches it. `gbc_oracle.zig` grades what this returns.

const std = @import("std");
const gbc_oracle = @import("gbc_oracle.zig");

extern fn sbref_cgb_palettes(
    rom: [*]const u8,
    rom_len: usize,
    boot: [*]const u8,
    boot_len: usize,
    max_frames: c_uint,
    bg_out: *gbc_oracle.PaletteRam,
    obj_out: *gbc_oracle.PaletteRam,
) bool;

/// The CGB boot ROM's logo and fade take a few seconds; ten is plenty, and a
/// boot ROM that has not handed over by then never will.
const max_frames = 600;

pub const Palettes = struct { bg: gbc_oracle.PaletteRam, obj: gbc_oracle.PaletteRam };

pub const Error = error{BootRomNeverHandedOver};

pub fn run(rom: []const u8, boot: []const u8) Error!Palettes {
    var p: Palettes = undefined;
    if (!sbref_cgb_palettes(rom.ptr, rom.len, boot.ptr, boot.len, max_frames, &p.bg, &p.obj))
        return error.BootRomNeverHandedOver;
    return p;
}
