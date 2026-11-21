//! Runs `sbcgb.c`: the patched ROM on SameBoy's Game Boy Color. Links
//! SameBoy, so only a build with `vendor/sameboy` reaches it.
//! `ejrtq_cgb.zig` grades what it returns.

const std = @import("std");
const cgb = @import("ejrtq_cgb.zig");

extern fn sbcgb_run(
    rom: [*]const u8,
    rom_len: usize,
    boot: [*]const u8,
    boot_len: usize,
    battery: ?[*]const u8,
    battery_len: usize,
    tile_start: [*]const u8,
    keys: [*]const u8,
    nkeys: usize,
    frames: c_uint,
    modes: ?[*]u8,
    nmodes: usize,
    out: *cgb.Out,
) bool;

pub const Error = error{BootRomNeverHandedOver};

pub const Run = struct {
    rom: []const u8,
    boot: []const u8,
    battery: ?[]const u8 = null,
    /// One bit per byte of `rom` (bit `n & 7` of byte `n >> 3`): set on the
    /// first byte of each graphics tile.
    tile_start: []const u8,
    /// SameBoy key masks, one per frame.
    keys: []const u8,
    frames: u32,
    /// The game mode per frame, if wanted (`frames` long).
    modes: ?[]u8 = null,
};

pub fn run(r: Run, out: *cgb.Out) Error!void {
    std.debug.assert(r.tile_start.len * 8 >= r.rom.len);
    const ok = sbcgb_run(
        r.rom.ptr,
        r.rom.len,
        r.boot.ptr,
        r.boot.len,
        if (r.battery) |b| b.ptr else null,
        if (r.battery) |b| b.len else 0,
        r.tile_start.ptr,
        r.keys.ptr,
        r.keys.len,
        r.frames,
        if (r.modes) |m| m.ptr else null,
        if (r.modes) |m| m.len else 0,
        out,
    );
    if (!ok) return error.BootRomNeverHandedOver;
}
