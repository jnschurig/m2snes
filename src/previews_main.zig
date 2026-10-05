//! `zig build previews` (release Step 6): the pictures the cart should show,
//! for a person to hold up against the screen, and the cart's layout report.
//! `zig build rom` runs it after the `m2snes` binary has written the carts.
//!
//! None of this is in the player's binary and none of it is graded: the cart
//! is `m2snes`'s alone. This rebuilds it in memory from the cached crawl only
//! to read what went where.

const std = @import("std");
const build_options = @import("build_options");
const builder = @import("builder.zig");
const convert = @import("snes_convert.zig");
const inject = @import("snes_inject.zig");
const screen = @import("snes_screen.zig");
const render = @import("snes_render.zig");
const screens = @import("screens.zig");
const map = @import("map.zig");
const warp = @import("warp.zig");
const png = @import("png");
const title_oracle = @import("title_oracle.zig");
const title_super = @import("title_super.zig");

const out_dir = "build-out";
const boot_png_name = out_dir ++ "/m2snes-boot.png";
const title_png_name = out_dir ++ "/m2snes-title.png";
const title_png_4x_name = out_dir ++ "/m2snes-title-4x.png";

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    const path = build_options.rom_path;
    if (path.len == 0) {
        try out.print("skip  no ROM configured; set M2_ROM\n", .{});
        try out.flush();
        return;
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(1 << 20));
    var built = try builder.build(gpa, bytes, .{ .walked = try warp.loadWalked(gpa, bytes) });
    defer built.deinit();
    const set = built.set;
    const boot = built.boot;

    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, out_dir, .{});
    defer dir.close(init.io);
    try dir.writeFile(init.io, .{
        .sub_path = "m2snes-boot.png",
        .data = try bootWindow(gpa, set, boot),
    });
    try dir.writeFile(init.io, .{ .sub_path = "m2snes-title.png", .data = try titlePreview(gpa, bytes, 1) });
    try dir.writeFile(init.io, .{ .sub_path = "m2snes-title-4x.png", .data = try titlePreview(gpa, bytes, 4) });

    try out.writeAll("\n");
    try inject.print(built.rom, out);
    var aram_bytes: usize = 0;
    for (set.aram) |blob| aram_bytes += blob.bytes.len - 2;
    try out.print(
        "\naudio ARAM image {d} bytes in {d} blocks, uploaded at boot; `zig build audioboot` measures the upload\n",
        .{ aram_bytes, set.aram.len },
    );
    try out.print(
        "\nboot  map {d} cell ${X:0>2} via door {d}, metatile table {d} ({s})\n",
        .{ boot.map_index, boot.cell, boot.door_index, boot.tiletable, @tagName(boot.mode) },
    );
    try out.print(
        "      samus {X:0>4},{X:0>4} camera {X:0>4},{X:0>4} pose ${X:0>2} for {d} frames\n",
        .{ boot.samus_y, boot.samus_x, boot.cam_y, boot.cam_x, boot.pose, boot.countdown },
    );
    try out.print("wrote {s}: the cart's first frame\n", .{boot_png_name});
    try out.print("wrote {s} and {s}: the title the cart should show, \"Super\" at Game Boy ({d}, {d})\n", .{
        title_png_name, title_png_4x_name, title_super.super_at.x, title_super.super_at.y,
    });
    try out.flush();
}

/// The play window the cart should be showing on its first frame, rendered by
/// `snes_render` from the same converted bytes the cart carries.
///
/// This is not decoration. There is no way to read a framebuffer back out of an
/// emulator here - Mesen2 runs headless but never loads the Lua script that
/// would do it - so the check that the cart draws the right picture is a person
/// holding this image up against the screen. Writing it beside the ROM is what
/// makes that a comparison rather than a recollection.
fn bootWindow(gpa: std.mem.Allocator, set: convert.Set, boot: screen.Boot) ![]u8 {
    const start = std.mem.readInt(u16, set.door_pointers.bytes[@as(usize, boot.door_index) * 2 ..][0..2], .little);
    const vram = try render.vramFor(set, set.doors.bytes[start..]);
    var tabs = try render.tables(gpa, set);
    defer tabs.deinit(gpa);

    const cells = set.map_cells[boot.map_index].bytes;
    const screen_index = cells[@as(usize, boot.cell) * convert.cell_bytes];
    const body = set.map_screens[boot.map_index].bytes[@as(usize, screen_index) * map.screen_bytes ..][0..map.screen_bytes];

    var drawn = try render.renderScreen(
        gpa,
        body,
        tabs.table(boot.tiletable),
        vram,
        render.paletteFromBgp(screens.live_bgp),
        .none,
    );
    defer drawn.deinit(gpa);

    // The window the camera starts on, not the whole 256x256 screen: what is on
    // the television is what there is to compare against.
    const left = screen.start_x - screen.min_x;
    const top = screen.start_y - screen.min_y;
    const w = target_view_w;
    const h = target_view_h;
    const window = try gpa.alloc(u8, w * h);
    for (0..h) |y| {
        const src = (top + y) * screens.screen_px + left;
        @memcpy(window[y * w ..][0..w], drawn.pixels[src..][0..w]);
    }
    return png.encodeIndexed(gpa, window, w, h, &png.dmg_palette);
}

/// The title the cart should show, Step 24j: the Game Boy's title as the
/// `title` rung's reference draws it, with "Super" laid over it, in the colours
/// the cart puts in CGRAM. The rung grades the cart against the same picture;
/// this is it for a person, to judge where "Super" sits before the FXPak.
fn titlePreview(gpa: std.mem.Allocator, rom: []const u8, scale: usize) ![]u8 {
    var title = try title_oracle.renderTitle(gpa, rom, 4);
    try title_super.composite(gpa, &title, 160, 4);
    var pal: [6][3]u8 = undefined;
    const words = screen.palette(0xE4) ++ [_]u16{ title_super.bgr15(title_super.red), title_super.bgr15(title_super.blue) };
    for (words, &pal) |c, *p| {
        // Each 5-bit channel as the PPU's output expands it.
        for (0..3) |ch| {
            const v: u8 = @intCast((c >> @intCast(ch * 5)) & 31);
            p[ch] = (v << 3) | (v >> 2);
        }
    }
    const w = 160 * scale;
    const h = 144 * scale;
    const px = try gpa.alloc(u8, w * h);
    for (0..h) |y| for (0..w) |x| {
        px[y * w + x] = title[(y / scale) * 160 + x / scale];
    };
    return png.encodeIndexed(gpa, px, w, h, &pal);
}

const target_view_w: usize = screen.target_view_w;
const target_view_h: usize = screen.target_view_h;
