//! `zig build frames` - render a reference frame for every in-use map screen.
//!
//! These are the pictures Step 9 diffs the SNES conversion against. Each is the
//! full 256x256 screen rather than the 160x144 the Game Boy shows at once, so
//! the comparison covers the whole room instead of the quarter of it that
//! happens to fit on screen.
//!
//! They are a build product, written under `extracted/` and never tracked: they
//! are made of the user's ROM.
//!
//! Every frame is rendered twice and the two compared, because "byte-stable
//! across runs" is a property this tool can check on its own rather than a
//! claim to be taken on trust. A manifest of SHA-256 digests goes out beside
//! the images so two separate runs can be compared as well.

const std = @import("std");
const rom_mod = @import("rom.zig");
const screens = @import("screens.zig");
const png = @import("png");

const build_options = @import("build_options");

pub const out_dir = "extracted/frames";


pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    if (build_options.rom_path.len == 0) {
        try out.print("no ROM configured (set M2_ROM or pass -Drom=...); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        build_options.rom_path,
        arena,
        .limited(rom_mod.expected_size * 4),
    );

    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, out_dir, .{});
    defer dir.close(init.io);

    var writer: Writer = .{ .io = init.io, .dir = &dir, .arena = arena };
    const stats = try screens.renderAll(arena, rom, screens.live_bgp, .{ .ctx = &writer, .frame = Writer.frame });

    try dir.writeFile(init.io, .{ .sub_path = "manifest.txt", .data = writer.manifest.items });

    try out.print("{d} reference frames -> {s}/ ({d} KiB)\n", .{ stats.rendered, out_dir, writer.bytes / 1024 });
    try out.print("  provenance: {d} door, {d} inherited, {d} scrolled, {d} bank\n", .{
        stats.by_provenance[0], stats.by_provenance[1], stats.by_provenance[2], stats.by_provenance[3],
    });
    try out.print("  digest {x}\n", .{&stats.digest});
    try out.print("  {d} rendered twice and differed; {d} screens had no body, {d} no tileset\n", .{
        stats.unstable, stats.no_body, stats.no_choice,
    });
    try out.print("  {d} metatile indexes out of range\n", .{stats.out_of_range});
    // Reported rather than smoothed over: a screen draws through the VRAM of
    // the door that named it, and a door does not always load every tile the
    // screens downstream of it use. Those tiles come out as colour 0, which is
    // a hole in the picture, not a wrong colour.
    try out.print("  {d} of {d} frames touch VRAM no door wrote, over {d} quarter-metatiles\n", .{
        stats.screens_with_unwritten, stats.rendered, stats.unwritten_tiles,
    });
    try out.flush();
}

/// Writes each frame as an indexed PNG and records its digest in a manifest,
/// so two separate runs can be compared file by file and not just in total.
const Writer = struct {
    io: std.Io,
    dir: *std.Io.Dir,
    arena: std.mem.Allocator,
    manifest: std.ArrayList(u8) = .empty,
    bytes: usize = 0,

    fn frame(ctx: *anyopaque, cell: screens.Cell, choice: screens.Choice, pixels: []const u8) anyerror!void {
        const self: *Writer = @ptrCast(@alignCast(ctx));
        const image = try png.encodeIndexed(
            self.arena,
            pixels,
            screens.screen_px,
            screens.screen_px,
            &png.dmg_palette,
        );
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "bank{X}_r{X:0>1}c{X:0>1}.png", .{
            cell.bank, cell.y, cell.x,
        });
        try self.dir.writeFile(self.io, .{ .sub_path = name, .data = image });
        self.bytes += image.len;

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(image, &digest, .{});
        try self.manifest.print(self.arena, "{s}  {x}  {s}  tt{d}  door{d}\n", .{
            name, &digest, choice.provenance.label(), choice.tiletable, choice.door_index,
        });
    }
};
