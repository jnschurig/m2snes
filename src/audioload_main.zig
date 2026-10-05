//! `zig build audioload -- <script.req> [<script.req> ...]`
//!
//! What the ported sound engine costs the SPC700, offline. Each script is run
//! twice through `vendor/spcrun` -- once with `engine/audio.bin` and once with a
//! null engine -- and the difference in the shim's idle rate is the load.
//!
//! This is the offline half of Step 7's measurement. The verdict's method is
//! the console (`zig build audiobench -- --image`), because the emulator steps
//! in 8 ms buffers and its overrun counts are an artefact of that rather than a
//! hardware prediction. What the emulator is good for is the idle rate, which
//! silicon and it agreed on within 0.5% in Step 1.

const std = @import("std");
const rom_mod = @import("rom.zig");
const audio_req = @import("audio_req.zig");
const audiocmp = @import("audiocmp.zig");
const audioload = @import("audioload.zig");

const build_options = @import("build_options");

const usage =
    \\usage: audioload <script.req> [<script.req> ...]
    \\
    \\Runs each script with the engine and with a null engine, and reports
    \\`1 - busy/idle` against that null run.
;

/// Where the two images and the generated script are left, so a surprising
/// number can be reproduced by hand with the command line printed below it.
const work_dir = ".zig-cache/audioload";

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var out_buf: [1 << 16]u8 = undefined;
    var out_file = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    var scripts: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.startsWith(u8, a, "-")) {
            try out.print("{s}\nunexpected argument '{s}'\n", .{ usage, a });
            return 2;
        }
        try scripts.append(arena, a);
    }
    if (scripts.items.len == 0) {
        try out.print("{s}\nno script\n", .{usage});
        return 2;
    }

    // Each missing piece skips by name: a skip must not read as a measurement.
    if (build_options.rom_path.len == 0) {
        try out.print("skipped: no ROM configured (set M2_ROM; see docs/setup.md)\n", .{});
        return 0;
    }
    const rom = try cwd.readFileAlloc(io, build_options.rom_path, arena, .limited(rom_mod.expected_size * 4));
    _ = try rom_mod.ingest(arena, rom, null);

    const engine = cwd.readFileAlloc(io, "engine/audio.bin", arena, .limited(1 << 16)) catch {
        try out.print("skipped: engine/audio.bin is absent (run `zig build spcengine`)\n", .{});
        return 0;
    };
    cwd.access(io, audiocmp.spcrun_path, .{}) catch {
        try out.print("skipped: no {s} (run tools/get-spcrun.sh)\n", .{audiocmp.spcrun_path});
        return 0;
    };

    try out.print("  {s:<24} {s:>8} {s:>9} {s:>8} {s:>7} {s:>9}\n", .{
        "script", "seconds", "idle silent", "idle busy", "load", "overruns",
    });

    for (scripts.items) |sp| {
        const text = try cwd.readFileAlloc(io, sp, arena, .limited(64 << 20));
        var line: usize = 0;
        var what: []const u8 = "";
        const script = audio_req.parse(arena, text, &line, &what) catch |e| {
            try out.print("{s}:{d}: {s} at '{s}'\n", .{ sp, line, @errorName(e), what });
            return 2;
        };

        const dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ work_dir, std.fs.path.stem(sp) });
        const r = audioload.measure(init.gpa, arena, io, rom, engine, script, dir) catch |e| {
            try out.print("{s}: {s}\n", .{ sp, @errorName(e) });
            return 1;
        };

        try out.print("  {s:<24} {d:>8.1} {d:>11} {d:>9} {d:>6.1}% {d:>9}\n", .{
            std.fs.path.basename(sp),
            r.loaded.seconds,
            r.silent.idle_hz,
            r.loaded.idle_hz,
            r.load() * 100.0,
            r.loaded.overruns,
        });

        if (r.baselineDrift()) |d| {
            if (@abs(d) > audioload.baseline_tolerance) {
                try out.print(
                    "  ! the silent baseline moved {d:.1}% from the recorded {d}/s;\n" ++
                        "    the shim's own per-tick cost has changed, and every load figure\n" ++
                        "    recorded against the old one is stale.\n",
                    .{ d * 100.0, audioload.silent_baseline_idle_hz },
                );
            }
        } else {
            try out.print("  (no recorded baseline yet; set audioload.silent_baseline_idle_hz to {d})\n", .{r.silent.idle_hz});
        }
        try out.print("    replay: {s} --image {s}/loaded.bin --no-trace {s}/script.txt\n", .{
            audiocmp.spcrun_path, dir, dir,
        });
    }

    try out.print(
        \\
        \\Load is `1 - busy/idle` against the same image with a null engine, so it
        \\covers the engine and the shim work its register writes cause, on all
        \\four channels.
        \\
        \\Overruns are real: the console agreed with this count within 6-15% in
        \\Step 7. The console is `zig build hostedbench` in snes_game_dev.
        \\
    , .{});
    return 0;
}
