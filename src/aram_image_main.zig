//! `zig build aramimage` — write the ARAM image to `build-out/aram.bin`.
//!
//! One image, hosted mode, the trace on unless `--no-trace` turns it off. It is
//! what `audiocmp` hands to `vendor/spcrun`, and what Step 16a's boot uploads
//! through the IPL. The file is a build product and is not committed: it is a
//! pure function of the ROM, `engine/audio.bin` and `audio/shim/`, and all
//! three are either committed or checked against a manifest.

const std = @import("std");
const rom_mod = @import("rom.zig");
const aram_image = @import("aram_image.zig");
const aram_layout = @import("aram_layout.zig");

const build_options = @import("build_options");

const usage =
    \\usage: aramimage [--no-trace] [-o <path>]
    \\
    \\  --no-trace   hosted mode without the write trace (for load measurement)
    \\  -o           where to write it (default build-out/aram.bin)
;

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var mode: aram_image.Mode = .hosted_trace;
    var path: []const u8 = "build-out/aram.bin";
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--no-trace")) {
            mode = .hosted;
        } else if (std.mem.eql(u8, a, "-o")) {
            path = it.next() orelse {
                try out.print("{s}\n-o needs a path\n", .{usage});
                return error.BadUsage;
            };
        } else {
            try out.print("{s}\nunexpected argument '{s}'\n", .{ usage, a });
            return error.BadUsage;
        }
    }

    if (build_options.rom_path.len == 0) {
        try out.print("no ROM configured (set M2_ROM; see docs/setup.md)\n", .{});
        return;
    }
    const rom = try cwd.readFileAlloc(io, build_options.rom_path, arena, .limited(rom_mod.expected_size * 4));
    _ = try rom_mod.ingest(arena, rom, null);

    const engine = cwd.readFileAlloc(io, "engine/audio.bin", arena, .limited(1 << 16)) catch {
        try out.print("engine/audio.bin is absent; run `zig build spcengine`\n", .{});
        return error.NoEngine;
    };

    const img = try aram_image.build(arena, rom, engine, mode);

    var dir = try cwd.createDirPathOpen(io, std.fs.path.dirname(path) orelse ".", .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = std.fs.path.basename(path), .data = img.bytes });

    try out.print("{s}: {d} bytes, {s}\n", .{ path, img.bytes.len, @tagName(mode) });
    try aram_layout.print(img.layout, out);
    try out.print("\n  upload: {d} bytes to the highest segment's end\n", .{img.uploadSize()});
}
