//! `zig build audioab -- song <id> | sfx <channel> <id> | <script.req> | level`
//!
//! Render one request twice — bank 4 on the Game Boy through SameBoy's APU, and
//! the ported engine through the shim and the S-DSP — and leave the two WAVs
//! next to each other in `build-out/audio-ab/` for a person to listen to.
//! `audiocmp` says whether the writes agree; this is for what they sound like.
//!
//! Each side is checked for the two ways a render fails without anyone
//! noticing: a file shorter than the request, and a song id that comes out
//! silent. Those exit 1. Everything a listener might find instead is Step 18's,
//! and is written down rather than exited on.
//!
//! `level` renders `audio_level.cases` instead and grades how loud the cart is
//! against the Game Boy: the gate's `audio level` rung, run by hand, with its
//! WAVs left in `build-out/audio-level/`.
//!
//! A `.req` path renders that script instead of a generated one, which is how
//! the cases with no id of their own are listened to: the earthquake and its
//! restore, the item jingles, the pause, the death. `test/audio/` holds them,
//! written for Step 15 and graded by `audiocmp` already, so the A/B and the
//! comparison are looking at the same script.
//!
//! Like `audiocmp`, what it cannot do it skips by name: the ROM, the assembled
//! engine and `spcrun` each say how to get them, and a skip exits 0 because a
//! skip is not a pass and must not read as a failure either.

const std = @import("std");
const rom_mod = @import("rom.zig");
const aram_image = @import("aram_image.zig");
const audio_req = @import("audio_req.zig");
const audiocmp = @import("audiocmp.zig");
const audioab = @import("audioab.zig");
const audioab_render = @import("audioab_render.zig");
const audio_level = @import("audio_level.zig");
const audio_level_run = @import("audio_level_run.zig");
const wav = @import("wav.zig");

const build_options = @import("build_options");

const usage =
    \\usage: audioab song <id> [--seconds N]
    \\       audioab sfx <sq1|sq2|noise|wave> <id> [--over <song>] [--seconds N]
    \\       audioab <script.req>
    \\       audioab level
    \\
    \\  ids are hex, as the tables in docs/audio_ids.md number them
    \\  --over     request the effect over this song, sixty ticks in
    \\  --seconds  how long to render (default 30 for a song, 3 for an effect,
    \\             4 with --over)
    \\
    \\`level` renders the level check's set and grades the cart's RMS against
    \\the Game Boy's (metroid2-0b Step 24f).
    \\
    \\A .req path renders that script as written: test/audio/ has the cases with
    \\no id of their own (the quake and its restore, the jingles, pause, death).
    \\
    \\Writes <stem>.gb.wav and <stem>.snes.wav, and the .req they both rendered,
    \\to build-out/audio-ab/.
;

const out_dir = "build-out/audio-ab";

/// SameBoy is asked for this; the S-DSP core produces 32000 and is not asked.
const gb_rate: u32 = 44100;

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

    // ---- What was asked for ----
    var request: ?audioab.Request = null;
    var over: ?u8 = null;
    var seconds: ?u32 = null;
    var script_path: ?[]const u8 = null;
    var level = false;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "level")) {
            level = true;
        } else if (std.mem.eql(u8, a, "song")) {
            const id = it.next() orelse return bad(out, "song needs an id", .{});
            request = .{ .song = parseHex(id) orelse return bad(out, "'{s}' is not a hex id", .{id}) };
        } else if (std.mem.eql(u8, a, "sfx")) {
            const ch = it.next() orelse return bad(out, "sfx needs a channel", .{});
            const channel = audioab.Channel.byName(ch) orelse
                return bad(out, "no channel named '{s}'", .{ch});
            const id = it.next() orelse return bad(out, "sfx needs an id", .{});
            request = .{ .sfx = .{
                .channel = channel,
                .id = parseHex(id) orelse return bad(out, "'{s}' is not a hex id", .{id}),
            } };
        } else if (std.mem.eql(u8, a, "--over")) {
            const id = it.next() orelse return bad(out, "--over needs a song id", .{});
            over = parseHex(id) orelse return bad(out, "'{s}' is not a hex id", .{id});
        } else if (std.mem.eql(u8, a, "--seconds")) {
            const n = it.next() orelse return bad(out, "--seconds needs a number", .{});
            seconds = std.fmt.parseInt(u32, n, 10) catch
                return bad(out, "'{s}' is not a number of seconds", .{n});
        } else if (std.mem.endsWith(u8, a, ".req")) {
            script_path = a;
        } else {
            return bad(out, "unexpected argument '{s}'", .{a});
        }
    }
    if (level and (script_path != null or request != null or over != null or seconds != null))
        return bad(out, "level renders its own set; it takes nothing else", .{});
    if (script_path != null and request != null)
        return bad(out, "a .req script is rendered as written; it takes no song or sfx", .{});

    var ask: ?audioab.Ask = null;
    if (level) {} else if (script_path == null) {
        const req = request orelse return bad(out, "nothing to render", .{});
        if (over != null and req == .song) return bad(out, "--over is for an effect, not a song", .{});
        ask = .{
            .request = req,
            .over = over,
            .seconds = seconds orelse switch (req) {
                .song => 30,
                .sfx => if (over != null) @as(u32, 4) else 3,
            },
        };
        if (ask.?.seconds == 0) return bad(out, "--seconds 0 renders nothing", .{});
    } else if (over != null or seconds != null) {
        return bad(out, "--over and --seconds are for a generated request; a .req script says its own", .{});
    }

    // ---- What the render needs, each skipped by name ----
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

    if (level) {
        var why: []const u8 = "";
        const ms = audio_level_run.run(init.gpa, arena, io, rom, engine, &why) catch |e| {
            try out.print("FAIL level: {s} on '{s}'\n", .{ @errorName(e), why });
            return 1;
        };
        const v = try audio_level_run.report(out, &ms, "  ") orelse return 1;
        try out.print("level: the set {s}{d:.1} dB against the Game Boy (within {d:.0}), the farthest case {s}{d:.1} dB (within {d:.0}): {s}\n", .{
            audio_level_run.sign(v.set_db),   @abs(v.set_db),   audio_level.set_tolerance_db,
            audio_level_run.sign(v.worst_db), @abs(v.worst_db), audio_level.case_tolerance_db,
            if (v.ok()) "ok" else "FAIL",
        });
        return if (v.ok()) 0 else 1;
    }

    // ---- The script both sides render ----
    var stem_buf: [64]u8 = undefined;
    const stem = if (script_path) |p| stemOfPath(p) else ask.?.stem(&stem_buf);
    const text = if (script_path) |p|
        cwd.readFileAlloc(io, p, arena, .limited(64 << 20)) catch |e| {
            try out.print("cannot read '{s}': {s}\n", .{ p, @errorName(e) });
            return 2;
        }
    else
        try audioab.scriptText(arena, ask.?);
    var line: usize = 0;
    var what: []const u8 = "";
    const script = audio_req.parse(arena, text, &line, &what) catch |e| {
        try out.print("{s}:{d}: {s} at '{s}'\n", .{ script_path orelse "the generated script", line, @errorName(e), what });
        return 2;
    };
    if (script.ticks() == 0) {
        try out.print("{s}: no ticks, so nothing to render\n", .{stem});
        return 2;
    }

    var dir = try cwd.createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);
    // The script goes out beside the WAVs either way: a generated one has no
    // other home, and a copied one says exactly what was rendered even if the
    // file in test/audio/ moves on.
    const req_name = try std.fmt.allocPrint(arena, "{s}.req", .{stem});
    try dir.writeFile(io, .{ .sub_path = req_name, .data = text });

    // Frames, not ticks: a script line is a frame of the game, and a lag frame
    // carries no tick while still taking its 1/60th of a second on both sides.
    const frames = script.frames.len;
    // A song is playing from the tick it is asked for, so silence is a broken
    // render and not a quiet track. Nothing else is held to that: an effect can
    // be over long before its script is, several ids in the tables are
    // `nothing`, and some of the hand-written scripts are *about* silence
    // (`silence-death.req`, `fade-out.req`).
    const must_sound = if (ask) |a| a.request == .song else false;
    try out.print("{s}: {d} frame(s), {d} tick(s), {d:.2}s on the Game Boy, {d:.2}s on the SNES\n", .{
        stem, frames, script.ticks(), audioab.wantSeconds(.gb, frames), audioab.wantSeconds(.snes, frames),
    });

    var failed = false;

    // ---- The Game Boy ----
    const gb_samples = audioab_render.renderGb(init.gpa, rom, script, gb_rate) catch |e| {
        try out.print("FAIL the Game Boy render: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer init.gpa.free(gb_samples);
    const gb_name = try std.fmt.allocPrint(arena, "{s}.gb.wav", .{stem});
    try writeWav(arena, io, dir, gb_name, gb_samples, gb_rate);
    if (!report(out, .gb, "gb  ", gb_name, audioab.measure(gb_samples, gb_rate), frames, must_sound)) failed = true;

    // ---- The SNES ----
    const img = try aram_image.build(arena, rom, engine, .hosted);
    const image_path = out_dir ++ "/aram.bin";
    try dir.writeFile(io, .{ .sub_path = "aram.bin", .data = img.bytes });
    const snes_name = try std.fmt.allocPrint(arena, "{s}.snes.wav", .{stem});
    const snes_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir, snes_name });
    const spc_script = try std.fmt.allocPrint(arena, "{s}/{s}.spcrun.txt", .{ out_dir, stem });

    var spc = audiocmp.runSpc(init.gpa, arena, io, image_path, script, spc_script, 0, snes_path) catch |e| switch (e) {
        error.SpcrunFailed => {
            try out.print("FAIL spcrun did not finish cleanly; its own message is above\n", .{});
            try out.print("  replay: {s} --image {s} --wav {s} {s}\n", .{ audiocmp.spcrun_path, image_path, snes_path, spc_script });
            return 1;
        },
        else => return e,
    };
    spc.deinit(init.gpa);

    // Read back the file rather than the array it was made from: `spcrun` is
    // another process, and what it wrote is what anyone will listen to.
    const snes_bytes = cwd.readFileAlloc(io, snes_path, arena, .limited(1 << 30)) catch |e| {
        try out.print("FAIL spcrun wrote no {s}: {s}\n", .{ snes_path, @errorName(e) });
        return 1;
    };
    const parsed = wav.parse(snes_bytes) catch |e| {
        try out.print("FAIL {s} is not a WAV this can read: {s}\n", .{ snes_path, @errorName(e) });
        return 1;
    };
    var snes_samples = try arena.alloc(i16, parsed.samples.len);
    for (parsed.samples, 0..) |s, i| snes_samples[i] = s;
    if (!report(out, .snes, "snes", snes_name, audioab.measure(snes_samples, parsed.rate), frames, must_sound)) failed = true;

    try out.print("\nlisten: {s}/{s}\n        {s}/{s}\n", .{ out_dir, gb_name, out_dir, snes_name });
    return if (failed) 1 else 0;
}

/// One side's line, and whether it is a render at all.
fn report(
    out: *std.Io.Writer,
    side: audioab.Side,
    label: []const u8,
    name: []const u8,
    m: audioab.Measured,
    frames: usize,
    must_sound: bool,
) bool {
    var ok = true;
    const long_enough = audioab.lengthOk(side, m, frames);
    if (!long_enough) ok = false;
    if (must_sound and m.silent()) ok = false;

    out.print("  {s} {s}: {d:.2}s, peak {d}{s}{s}\n", .{
        label,
        name,
        m.seconds,
        m.peak,
        if (!long_enough) "  FAIL: not the length the script asked for" else "",
        if (m.silent()) (if (must_sound) "  FAIL: silent" else "  (silent)") else "",
    }) catch {};
    return ok;
}

fn writeWav(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    samples: []const i16,
    rate: u32,
) !void {
    var bytes: std.ArrayList(u8) = .empty;
    var w = std.Io.Writer.Allocating.fromArrayList(arena, &bytes);
    try wav.write(&w.writer, samples, rate);
    try dir.writeFile(io, .{ .sub_path = name, .data = w.written() });
}

/// A script's file name without its directory or its `.req`, which is what the
/// renders are named after.
fn stemOfPath(p: []const u8) []const u8 {
    const base = std.fs.path.basename(p);
    return base[0 .. base.len - ".req".len];
}

fn parseHex(s: []const u8) ?u8 {
    const body = if (std.mem.startsWith(u8, s, "$")) s[1..] else s;
    return std.fmt.parseInt(u8, body, 16) catch null;
}

fn bad(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !u8 {
    try out.print("{s}\n", .{usage});
    try out.print(fmt ++ "\n", args);
    return 2;
}
