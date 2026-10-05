//! `zig build convert` - run the SNES-target conversion and report what it
//! produced, class by class, against the reserved region layout.
//!
//! This is the human-readable face of `snes_convert.run` and
//! `snes_layout.check`. Neither the converter nor the validator writes files:
//! Step 11's injector is what places bytes into an image, and it is not written
//! yet. What this prints is the input that decision needs.

const std = @import("std");
const rom_mod = @import("rom.zig");
const convert = @import("snes_convert.zig");
const layout = @import("snes_layout.zig");
const aram = @import("aram_layout.zig");

const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    if (build_options.rom_path.len == 0) {
        try out.print("no ROM configured (set M2_ROM; see docs/setup.md)\n", .{});
        try out.flush();
        return;
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        build_options.rom_path,
        arena,
        .limited(rom_mod.expected_size * 4),
    );
    _ = try rom_mod.ingest(arena, bytes, null);

    var set = try convert.run(init.gpa, bytes);
    defer set.deinit();

    const report = layout.measure(set);
    try layout.print(report, out);

    // The SPC700's side of the same question (metroid2-audio Step 5). It is
    // reported here rather than in a command of its own because the two
    // address spaces are filled from one ROM by one build, and a reader
    // deciding whether the conversion fits should see both at once.
    //
    // The engine image's size is read off `engine/audio.bin` when it is there.
    // When it is not, the layout is still worth printing -- everything except
    // the engine's own region is known without it -- so it is reported as
    // absent rather than guessed at.
    const engine_bin = std.Io.Dir.cwd().readFileAlloc(init.io, "engine/audio.bin", arena, .limited(1 << 16)) catch null;
    const aram_layout = try aram.plan(arena, if (engine_bin) |b| b.len else 0);
    try aram.print(aram_layout, out);
    if (engine_bin == null)
        try out.print("\n  engine_code is 0: engine/audio.bin is absent (run `zig build spcengine`)\n", .{});

    const aram_over = aram.check(aram_layout);
    if (aram_over) |o| {
        try out.print("\n  ARAM OVERFLOW: {s} needs {d} bytes of {d}\n", .{ @tagName(o.class), o.used, o.capacity });
    }

    try out.flush();

    if (!report.fits() or aram_over != null) std.process.exit(1);
}
