//! `zig build audiocmp -- <script.req>... [--regs <filter>]`
//!
//! Grade the ported sound engine against the Game Boy's on each request script,
//! in order, stopping at the first that diverges so the files left for replay
//! are that script's. Exits 0 when they all agree, 1 when one does not, and 0 with a named notice when a
//! piece of the harness is missing — a skip is a skip and must not read as a
//! pass, so it says which piece and how to get it.

const std = @import("std");
const rom_mod = @import("rom.zig");
const aram_image = @import("aram_image.zig");
const audio_req = @import("audio_req.zig");
const audiocmp = @import("audiocmp.zig");

const build_options = @import("build_options");

const usage =
    \\usage: audiocmp <script.req>... [--regs <filter>] [--ack-delay <frames>]
    \\
    \\  --regs       which registers to compare: all (default), square1, square2,
    \\               wave, noise. Step 7's spike grades through square1.
    \\  --ack-delay  have spcrun hold each message in flight this many frames
    \\               more, so ticks queue behind it (the busy rule). Default 0.
;

/// Where the generated `spcrun` script and the image are left, so a divergence
/// can be replayed by hand with the exact two files the comparison used.
const work_dir = ".zig-cache/audiocmp";

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

    var script_paths: std.ArrayList([]const u8) = .empty;
    var filter = audiocmp.all;
    var ack_delay: u32 = 0;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--regs")) {
            const name = it.next() orelse {
                try out.print("{s}\n--regs needs a filter name\n", .{usage});
                return 2;
            };
            filter = audiocmp.filterByName(name) orelse {
                try out.print("no filter named '{s}'. One of:", .{name});
                for (audiocmp.filters) |f| try out.print(" {s}", .{f.name});
                try out.print("\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--ack-delay")) {
            const n = it.next() orelse {
                try out.print("{s}\n--ack-delay needs a frame count\n", .{usage});
                return 2;
            };
            ack_delay = std.fmt.parseInt(u32, n, 10) catch {
                try out.print("--ack-delay: '{s}' is not a frame count\n", .{n});
                return 2;
            };
        } else if (std.mem.startsWith(u8, a, "-")) {
            try out.print("{s}\nunexpected argument '{s}'\n", .{ usage, a });
            return 2;
        } else {
            try script_paths.append(arena, a);
        }
    }
    if (script_paths.items.len == 0) {
        try out.print("{s}\nno script\n", .{usage});
        return 2;
    }

    // ---- What the comparison needs, each skipped by name ----
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

    // The slot numbers this harness sends must be the ones the engine reads.
    if (try audio_req.checkAgainstEngine(arena, io)) |drifts| {
        if (drifts.len != 0) {
            for (drifts) |d| try out.print(
                "FAIL slot drift: {s} should be {d}, engine/audio/main.asm says {?d}\n",
                .{ d.what, d.expected, d.found },
            );
            return 1;
        }
    }

    for (script_paths.items) |sp| {
        const status = try grade(init, arena, out, rom, engine, sp, filter, ack_delay);
        if (status != 0) return status;
    }
    if (script_paths.items.len > 1) try out.print("\nall {d} script(s) exact\n", .{script_paths.items.len});
    return 0;
}

fn grade(
    init: std.process.Init,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    rom: []const u8,
    engine: []const u8,
    sp: []const u8,
    filter: audiocmp.Filter,
    ack_delay: u32,
) !u8 {
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, sp, arena, .limited(64 << 20));
    var line: usize = 0;
    var what: []const u8 = "";
    const script = audio_req.parse(arena, text, &line, &what) catch |e| {
        try out.print("{s}:{d}: {s} at '{s}'\n", .{ sp, line, @errorName(e), what });
        return 2;
    };

    try out.print("{s}: {d} frame(s), {d} tick(s)\n", .{ sp, script.frames.len, script.ticks() });

    // ---- The image, kept beside the generated script ----
    const img = try aram_image.build(arena, rom, engine, .hosted_trace);
    var dir = try cwd.createDirPathOpen(io, work_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "aram.bin", .data = img.bytes });

    const image_path = work_dir ++ "/aram.bin";
    const spc_script = work_dir ++ "/script.txt";

    // ---- Both sides ----
    var gb = try audiocmp.runGb(init.gpa, rom, script);
    defer gb.deinit(init.gpa);

    var spc = audiocmp.runSpc(init.gpa, arena, io, image_path, script, spc_script, ack_delay, null) catch |e| switch (e) {
        error.SpcrunFailed => {
            try out.print("FAIL spcrun did not finish cleanly; its own message is above\n", .{});
            try out.print("  replay: {s} --image {s} {s}\n", .{ audiocmp.spcrun_path, image_path, spc_script });
            return 1;
        },
        else => return e,
    };
    defer spc.deinit(init.gpa);

    var cmp = try audiocmp.compare(arena, gb, spc, filter);
    // The tick count is checked here rather than inside `compare`, which does
    // not know what the script asked for.
    if (gb.read_back.len != script.ticks()) {
        cmp.divergence = .{ .tick_count = .{ .expected = script.ticks(), .spc = gb.read_back.len } };
    }
    try audiocmp.report(arena, out, gb, spc, cmp);

    if (cmp.divergence != null) {
        try out.print("\nreplay: {s} --image {s} {s}\n", .{ audiocmp.spcrun_path, image_path, spc_script });
        return 1;
    }
    return 0;
}
