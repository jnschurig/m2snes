//! `zig build extract` - write the Step 3 asset classes to `extracted/`.
//!
//! Nothing downstream reads `extracted/` yet; it exists so the extraction can
//! be inspected and diffed by hand, and so the gate has something to hash. It
//! is a build product and is never tracked.

const std = @import("std");
const rom_mod = @import("rom.zig");
const extract = @import("extract.zig");

const build_options = @import("build_options");

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

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        build_options.rom_path,
        arena,
        .limited(rom_mod.expected_size * 4),
    );
    var diag: rom_mod.Diagnosis = undefined;
    _ = rom_mod.ingest(arena, bytes, &diag) catch {
        try out.print("refusing to extract: {s}\n", .{diag.message});
        try out.flush();
        std.process.exit(1);
    };

    var root = try std.Io.Dir.cwd().openDir(init.io, ".", .{ .iterate = true });
    defer root.close(init.io);

    var report = try extract.run(arena, init.io, root, bytes);
    defer report.deinit(arena);

    var tiles: usize = 0;
    var metatiles: usize = 0;
    var files: usize = 0;
    var written: usize = 0;
    for (report.records.items) |r| {
        if (std.mem.eql(u8, r.unit, "tiles")) tiles += r.count;
        if (std.mem.eql(u8, r.unit, "metatiles")) metatiles += r.count;
        files += r.files.len;
        for (r.files) |f| written += f.bytes;
    }

    try out.print("extracted {d} entries -> {s}/ ({d} files, {d} KiB)\n", .{
        report.records.items.len, extract.out_dir, files + 1, written / 1024,
    });
    try out.print("  {d} tiles, {d} metatiles\n", .{ tiles, metatiles });
    try out.print("  {d} entries deferred to Step 4 (maps, doors, enemy tables, metasprites)\n", .{report.skipped});
    try out.flush();
}
