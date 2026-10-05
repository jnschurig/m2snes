//! `zig build coverage` — print the asset coverage report and write it to
//! `extracted/coverage.txt`.
//!
//! `zig build verify` runs the same round-trip and enforces it; this is the
//! human-readable view, for the question "what have we actually reached" rather
//! than "did anything regress".

const std = @import("std");
const rom_mod = @import("rom.zig");
const roundtrip = @import("roundtrip.zig");
const coverage = @import("coverage.zig");
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
        try out.print("coverage: no ROM configured (set M2_ROM; see docs/setup.md)\n", .{});
        try out.flush();
        std.process.exit(1);
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        build_options.rom_path,
        arena,
        .limited(rom_mod.expected_size * 4),
    );

    const text = try coverage.reportText(arena, bytes);
    try out.writeAll(text);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, extract.out_dir, .{});
    defer dir.close(init.io);
    try dir.writeFile(init.io, .{ .sub_path = coverage.file_name, .data = text });
    try out.print("\nwritten to {s}/{s}\n", .{ extract.out_dir, coverage.file_name });

    try out.flush();
}
