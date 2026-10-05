//! `zig build gbtrace` — take the reference trace off the emulator that
//! recorded it.
//!
//! `zig build tas` replays a published `.vbm` on our own Game Boy and traces
//! what it did. That is not available for James's B11 recording: converted to a
//! VBM our emulator stops being his run at 28 796 of 76 950 frames. So this
//! drives the `.mmo` back through Mesen2 headlessly and reads the trace out of
//! cart RAM. See `src/gb_trace.zig` for the channel and for the measurements it
//! is built on.
//!
//!   zig build gbtrace -- [movie] [first] [count] [stride] [offset]
//!   zig build gbtrace -- [movie] world <frame> [frame...]
//!   zig build gbtrace -- [movie] refs <origin:frames> [origin:frames...]
//!   zig build gbtrace -- [movie] ais <through>
//!   zig build gbtrace -- [movie] kills <first> <last>
//!   zig build gbtrace -- [movie] saves <first> <last>
//!   zig build gbtrace -- <dir> set
//!
//! `movie` defaults to `reference/metroid2.mmo`; `first` and `count` name the
//! window, and `count` is capped at what one save file holds. `stride` records
//! every Nth frame instead of every one, which is how a whole 77 000-frame
//! recording is censused in a single pass. `offset` is how far the movie's rows
//! are held back as they are driven in; it defaults to the measured value and
//! is an argument only so the measurement can be repeated. The window is
//! written to `build-out/` as a tab-separated table with the same columns
//! `zig build tas` writes, and a summary is printed.
//!
//! `world` is the other kind of pass: instead of a window of rows it records
//! the whole background tilemap and the whole respawning-block array at each
//! named frame. That is what an anchor needs and a row cannot carry -- the
//! recording shoots blocks out to descend, so an anchor that restores Samus
//! and not the floor hands the port a room the trace does not have. One
//! anchor is 1 280 bytes against a 24 512-byte region, so a pass holds
//! nineteen of them; the tilemaps are written to `build-out/` as one file per
//! anchor.
//!
//! `refs` is the third: a whole reference per stretch, which is what a graded
//! stretch is compared against. Each `origin:frames` takes the world *and* the
//! placement at `origin - 1` and then records `frames` frames from `origin`, so
//! one replay produces everything `oracle.MovieRef` carries. A snapshot is
//! 1 560 bytes, so one stretch keeps 850 frames of the region and four keep 676
//! between them; asking for more is refused rather than truncated.
//!
//! `ais` is the fourth: play the movie to frame `through` and record every
//! distinct (AI, sprite) pair the enemy dispatch jumps to on the way, which is
//! how Step 12f learns which AIs the slice needs from the game rather than from
//! the spawn lists.
//!
//! `kills` is the fifth: across `first..last`, one record on every frame a
//! Metroid fight's state moved -- a hurt, a stage of the death, a step of the
//! post-death timer -- with the Alpha's slot alongside. Step 13d takes the
//! enemy oracle's kill from it.
//!
//! `saves` is the sixth: across `first..last`, one record whenever the save
//! path moves -- the game mode, the station's contact, the "COMPLETED"
//! cooldown starting or ending, the death and load flags -- carrying the active
//! slot's bytes, so the frame a record was written and what it wrote are both
//! in the table. Step 15 takes its saves, its death and its reload from it.
//!
//! `set` is the seventh: a recording delivered as a directory of ordered
//! segments (`reference/metroid2-100p-recording/`, 1.0 Step 24a), taken as one
//! run. Each segment is censused whole, each seam is checked by comparing one
//! segment's last frames with the next one's first, and every kill, pickup and
//! beam lands in one table on one frame axis.

const std = @import("std");
const build_options = @import("build_options");
const rom_mod = @import("rom.zig");
const gb_trace = @import("gb_trace.zig");
const tas = @import("tas.zig");
const oracle = @import("oracle.zig");
const screens = @import("screens.zig");
const warp = @import("warp.zig");
const map_mod = @import("map.zig");
const roster = @import("roster.zig");

const default_movie = gb_trace.recording_path;

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    if (build_options.rom_path.len == 0) {
        try out.print("gbtrace: no ROM configured (set M2_ROM); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    if (build_options.mesen_path.len == 0) {
        try out.print("gbtrace: no emulator configured (set MESEN); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var movie_path: []const u8 = default_movie;
    var first: usize = 0;
    var count: usize = gb_trace.max_frames;
    var stride: usize = 1;
    var offset: usize = gb_trace.input_offset;
    var wanted: std.ArrayList(u32) = .empty;
    var stretches: std.ArrayList(gb_trace.Stretch) = .empty;
    var world_mode = false;
    var refs_mode = false;
    var ais_through: ?usize = null;
    var ais_mode = false;
    var kills_mode = false;
    var kill_bounds: [2]usize = .{ 0, 0 };
    var kill_n: usize = 0;
    var saves_mode = false;
    var set_mode = false;
    var worlds_mode = false;

    // `world` and `refs` each switch the whole rest of the line from a window
    // to a list. Positional either way, which is this tool's convention.
    var n: usize = 0;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "world")) {
            world_mode = true;
            continue;
        }
        if (std.mem.eql(u8, a, "refs")) {
            refs_mode = true;
            continue;
        }
        if (std.mem.eql(u8, a, "ais")) {
            ais_mode = true;
            continue;
        }
        if (std.mem.eql(u8, a, "kills")) {
            kills_mode = true;
            continue;
        }
        if (std.mem.eql(u8, a, "saves")) {
            saves_mode = true;
            continue;
        }
        if (std.mem.eql(u8, a, "set")) {
            set_mode = true;
            continue;
        }
        if (std.mem.eql(u8, a, "worlds")) {
            worlds_mode = true;
            continue;
        }
        if (kills_mode or saves_mode) {
            if (kill_n < 2) kill_bounds[kill_n] = std.fmt.parseInt(usize, a, 10) catch continue;
            kill_n += 1;
            continue;
        }
        if (ais_mode) {
            ais_through = std.fmt.parseInt(usize, a, 10) catch continue;
            continue;
        }
        if (refs_mode) {
            // `origin:frames`. Both halves required: a stretch with no length
            // is a snapshot nobody grades against, and defaulting it would
            // hide the budget the frames are spent from.
            const colon = std.mem.indexOfScalar(u8, a, ':') orelse continue;
            const origin = std.fmt.parseInt(u32, a[0..colon], 10) catch continue;
            const frames = std.fmt.parseInt(u32, a[colon + 1 ..], 10) catch continue;
            try stretches.append(gpa, .{ .origin = origin, .frames = frames });
            continue;
        }
        if (world_mode) {
            const f = std.fmt.parseInt(u32, a, 10) catch continue;
            try wanted.append(gpa, f);
            continue;
        }
        // The movie is whichever leading argument is not a number. Written
        // this way rather than "the first argument" so `zig build gbtrace --
        // 0 1160 64` works without naming the default movie.
        const v = std.fmt.parseInt(usize, a, 10) catch {
            if (n == 0) movie_path = a;
            continue;
        };
        switch (n) {
            0 => first = v,
            1 => count = @min(gb_trace.max_frames, v),
            2 => stride = @max(1, v),
            3 => offset = v,
            else => {},
        }
        n += 1;
    }

    const rom = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        build_options.rom_path,
        gpa,
        .limited(rom_mod.expected_size * 4),
    );

    const home = init.environ_map.get("HOME") orelse "";
    if (set_mode and worlds_mode) {
        try runSetWorlds(gpa, init.io, out, rom, movie_path, offset, home);
        return;
    }
    if (set_mode) {
        try runSetMode(gpa, init.io, out, rom, movie_path, offset, home);
        return;
    }

    const mmo = std.Io.Dir.cwd().readFileAlloc(init.io, movie_path, gpa, .limited(64 * 1024 * 1024)) catch {
        try out.print(
            "gbtrace: no recording at {s}. It is vendored, not tracked: see tools/get-tas.sh\n",
            .{movie_path},
        );
        try out.flush();
        std.process.exit(1);
    };

    var rec = try gb_trace.readRecording(gpa, mmo);
    defer rec.deinit(gpa);

    rec.checkCartridge(rom) catch {
        try out.print(
            "gbtrace: {s} was recorded on {s} (SHA1 {s}), which is not the configured ROM\n",
            .{ movie_path, rec.gameFile() orelse "?", rec.sha1() orelse "?" },
        );
        try out.flush();
        std.process.exit(1);
    };

    try out.print("{s}: {d} frames, on {s}\n", .{
        std.fs.path.basename(movie_path),
        rec.frames(),
        rec.gameFile() orelse "?",
    });

    if (saves_mode) {
        try runSavesMode(gpa, init.io, out, rom, rec, kill_bounds[0], kill_bounds[1], offset, home);
        return;
    }
    if (kills_mode) {
        try runKillsMode(gpa, init.io, out, rom, rec, kill_bounds[0], kill_bounds[1], offset, home);
        return;
    }
    if (ais_mode) {
        try runAisMode(gpa, init.io, out, rom, rec, ais_through orelse rec.frames(), offset, home);
        return;
    }
    if (refs_mode) {
        try runRefsMode(gpa, init.io, out, rom, rec, stretches.items, offset, home);
        return;
    }
    if (world_mode) {
        try runWorldMode(gpa, init.io, out, rom, rec, wanted.items, offset, home);
        return;
    }

    try out.print("window: {d}..{d} of {d} by {d}, {d} bytes a frame, {d} rows a pass\n", .{
        first,
        @min(first + count * stride, rec.frames()),
        rec.frames(),
        stride,
        gb_trace.record_bytes,
        gb_trace.max_frames,
    });
    try out.print("offset: {d} — the movie's rows are held back this many frames\n", .{offset});
    try out.flush();

    var pass = try gb_trace.run(gpa, init.io, rom, rec, first, count, stride, offset, build_options.mesen_path, home, null);
    defer pass.deinit(gpa);

    const shift = pass.lag(rec);
    try out.print("ran:    {d} frames recorded, stopped at {d}, {d} polls, exit {d}\n", .{
        pass.frames, pass.frames_run, pass.polls, pass.code,
    });
    if (shift) |l| {
        try out.print("input:  $FF80 matches the movie at a lag of {d} frame(s)\n", .{l});
    } else if (pass.padChanges() < gb_trace.min_changed) {
        // Not a failure: a window that sits inside a cutscene never moves the
        // pad byte, and a check with no evidence should say so.
        try out.print("input:  not checked — the pad byte moved {d} time(s) in this window\n", .{pass.padChanges()});
    } else if (stride != 1) {
        // A strided pass cannot tell one pad change from the several it
        // stepped over, so the alignment is unchecked rather than failed.
        try out.print("input:  not checked — a stride of {d} steps over pad changes\n", .{stride});
    } else {
        try out.print("input:  $FF80 matches the movie at NO lag under {d} — the pass desynced\n", .{gb_trace.max_lag});
        // What the game acted on, beside what the movie held, for the first
        // frames that disagree. The alignment is the one thing this tool
        // cannot proceed without, so it prints its evidence rather than a
        // verdict.
        try out.print("  frame  movie  $FF80  pose  bank    y     x\n", .{});
        var shown: usize = 0;
        for (0..pass.frames) |i| {
            const f = pass.first + i * pass.stride;
            const held = if (f < rec.frames()) rec.inputs[f] else 0;
            const acted: u8 = @intCast(pass.get(i, "pad"));
            // Only frames that moved the pad byte: on a frame where the game
            // did not ask, `$FF80` is last frame's answer, and printing those
            // buries the disagreement under a cutscene.
            if (i != 0 and acted == @as(u8, @intCast(pass.get(i - 1, "pad")))) continue;
            if (held == acted and shown != 0) continue;
            try out.print("  {d:>5}   ${X:0>2}    ${X:0>2}   ${X:0>2}   ${X:0>2}  {X:0>4}  {X:0>4}\n", .{
                f,                      held,                 acted,
                pass.get(i, "pose"),    pass.get(i, "map_bank"),
                pass.get(i, "samus_y"), pass.get(i, "samus_x"),
            });
            shown += 1;
            if (shown >= 24) break;
        }
        try out.flush();
        std.process.exit(1);
    }

    const samples = try pass.samples(gpa, rec, shift orelse 0);
    const track = tas.Track.ofSamples(samples);
    const fs = try tas.faithfulness(gpa, track, tas.stuck_min_frames);

    // Every change of $D089 and of the three pickup columns, each with the
    // room it happened in. B11 asks for the two Alpha kills and Step 11 for
    // the four pickups by name, and this is what places them: `where` prints
    // the map bank and the cell, which together are the address every other
    // part of this port uses for a screen.
    try reportEvents(gpa, out, pass, samples);

    try out.print("play:   banks {d}, metroids {d} -> {d}", .{
        track.bankCount(), track.metroid_first, track.metroid_min,
    });
    if (fs.longest_stuck) |st| {
        try out.print(", longest refusal {d} frames at {d}\n", .{ st.frames, st.start });
    } else {
        try out.print(", no refusal over {d} frames\n", .{tas.stuck_min_frames});
    }

    // The game's own save bank, which no per-frame column can speak for:
    // `saveFileToSRAM` writes below the trace region, which is why records
    // start at 8 KiB and not at zero. Printed on every pass so "the recording's
    // saves appear in the trace" is a number two windows can be compared on
    // rather than a claim. The savestate carries cart RAM, so a pass's frame 0
    // is whatever the recording had already saved -- the digest is read as a
    // difference between windows, not against an empty bank.
    try out.print("save:   {d} of {d} byte(s) set in the game's own bank, digest {X:0>8}\n", .{
        pass.saveBytes(), gb_trace.game_sram_bytes, pass.saveDigest(),
    });

    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, gb_trace.out_dir, .{});
    defer dir.close(init.io);
    const name = try std.fmt.allocPrint(gpa, "{s}-{d}-by{d}.tsv", .{
        std.fs.path.stem(movie_path), first, stride,
    });
    try dir.writeFile(init.io, .{ .sub_path = name, .data = try gb_trace.tsv(gpa, pass, samples) });
    try out.print("wrote:  {s}/{s}\n", .{ gb_trace.out_dir, name });
    try out.flush();
}

/// Where a sample happened, in the map bank and cell the rest of the port
/// addresses screens by. `tas.Room.of` derives the cell from the screen bytes
/// of her position, which is the same arithmetic `room.Placement` uses.
fn where(s: tas.Sample) tas.Room {
    return tas.Room.of(s);
}

/// The trace's landmarks: every frame a Metroid died or a pickup landed.
///
/// These are the frames Steps 10-14 anchor on, so they are printed with the
/// room rather than only the frame -- a frame number alone says when the port
/// has to agree and not where it has to be standing.
const Event = struct {
    frame: u32,
    room: tas.Room,
    y: u16,
    x: u16,
    what: [48]u8,
    len: usize,

    fn text(self: *const Event) []const u8 {
        return self.what[0..self.len];
    }
};

fn event(list: *std.ArrayList(Event), gpa: std.mem.Allocator, s: tas.Sample, comptime fmt: []const u8, args: anytype) !void {
    var e: Event = .{ .frame = s.frame, .room = where(s), .y = s.samus_y, .x = s.samus_x, .what = undefined, .len = 0 };
    e.len = (try std.fmt.bufPrint(&e.what, fmt, args)).len;
    try list.append(gpa, e);
}

/// Every change of `$D089` and of the pickup columns, each with
/// the room it happened in. `where` gives the map bank and the cell, which
/// together are the address every other part of this port uses for a screen.
fn collectEvents(gpa: std.mem.Allocator, pass: gb_trace.Pass, samples: []const tas.Sample) ![]Event {
    var list: std.ArrayList(Event) = .empty;
    for (samples, 0..) |s, i| {
        if (i == 0) continue;
        const p = samples[i - 1];
        // A pickup and a kill can land on the same frame in principle, so
        // each column is reported on its own rather than in an `else if`.
        if (s.metroid_count != p.metroid_count) {
            // BCD, so hex reads as the count the game shows.
            try event(&list, gpa, s, "metroids {X:0>2} -> {X:0>2}", .{ p.metroid_count, s.metroid_count });
        }
        const was = pass.get(i - 1, "items");
        const items = pass.get(i, "items");
        if (items != was) {
            // Only the bits that were *gained*: losing one is the reload
            // after a death, which is not a pickup and says so.
            const got: u32 = items & ~was;
            for (gb_trace.item_bits, 0..) |name, b| {
                if (got & (@as(u32, 1) << @intCast(b)) != 0) try event(&list, gpa, s, "got {s}", .{name});
            }
            if (was & ~items != 0) try event(&list, gpa, s, "items ${X:0>2} -> ${X:0>2}", .{ was, items });
        }
        const et_was = pass.get(i - 1, "etanks");
        const et = pass.get(i, "etanks");
        if (et != et_was) try event(&list, gpa, s, "energy tanks {d} -> {d}", .{ et_was, et });
        // BCD, like the count: hex reads as the number the HUD shows.
        const mm_was = pass.get(i - 1, "missiles_max");
        const mm = pass.get(i, "missiles_max");
        if (mm != mm_was) try event(&list, gpa, s, "max missiles {X} -> {X}", .{ mm_was, mm });
    }
    return list.toOwnedSlice(gpa);
}

fn printEvent(out: *std.Io.Writer, label: []const u8, e: *const Event) !void {
    try out.print("{s}frame {d:>6}  bank ${X:0>2} cell ${X:0>2}  y {X:0>4} x {X:0>4}  {s}\n", .{
        label, e.frame, e.room.map_bank, e.room.cell, e.y, e.x, e.text(),
    });
}

fn reportEvents(gpa: std.mem.Allocator, out: *std.Io.Writer, pass: gb_trace.Pass, samples: []const tas.Sample) !void {
    const events = try collectEvents(gpa, pass, samples);
    for (events[0..@min(events.len, 40)]) |*e| try printEvent(out, "event:  ", e);
    if (events.len > 40) try out.print("event:  ... and {d} more\n", .{events.len - 40});
}

/// `zig build gbtrace -- <dir> set` — a recording delivered as ordered
/// segments, taken as one run.
///
/// Every `.mmo` in the directory, in name order, is checked against the ROM and
/// censused whole at the narrowest stride one pass holds. Each seam is checked
/// by `gb_trace.seam`, the events are printed on one frame axis (the segments'
/// lengths summed), and the table is written to `build-out/set-<dir>.tsv`.
fn bcdDec(v: u8) u8 {
    if (v == 0) return 0xFF;
    return if (v & 0x0F == 0) v - 0x10 + 0x09 else v - 1;
}

fn bcdInt(v: u8) i32 {
    return @as(i32, v >> 4) * 10 + (v & 0x0F);
}

test "a BCD count one lower" {
    try std.testing.expectEqual(@as(u8, 0x46), bcdDec(0x47));
    try std.testing.expectEqual(@as(u8, 0x39), bcdDec(0x40));
    try std.testing.expectEqual(@as(u8, 0x00), bcdDec(0x01));
}

fn runSetMode(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    dir_path: []const u8,
    offset: usize,
    home: []const u8,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        try out.print("gbtrace: no segment directory at {s}\n", .{dir_path});
        try out.flush();
        std.process.exit(1);
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".mmo")) continue;
        try names.append(gpa, try gpa.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    if (names.items.len == 0) {
        try out.print("gbtrace: no .mmo in {s}\n", .{dir_path});
        try out.flush();
        std.process.exit(1);
    }

    var tsv: std.Io.Writer.Allocating = .init(gpa);
    try tsv.writer.print("segment\tframe\trun_frame\tbank\tcell\ty\tx\tevent\n", .{});

    var failed = false;
    var base: usize = 0;
    var prev_tail: ?[gb_trace.seam_frames]u32 = null;
    var last_clock: u32 = 0;
    var last_beam: u8 = 0;
    var last_count: u32 = 0;
    var kills: usize = 0;
    var first_count: ?u8 = null;
    for (names.items, 0..) |name, k| {
        const path = try std.fs.path.join(gpa, &.{ dir_path, name });
        const mmo = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
        var rec = try gb_trace.readRecording(gpa, mmo);
        rec.checkCartridge(rom) catch {
            try out.print("FAIL:   {s} was recorded on {s} (SHA1 {s}), not the configured ROM\n", .{
                name, rec.gameFile() orelse "?", rec.sha1() orelse "?",
            });
            failed = true;
            continue;
        };
        const frames = rec.frames();
        // A row short of the most a pass holds, so the beam log has room.
        const rows = gb_trace.max_frames - gb_trace.beam_log_rows;
        const stride = (frames + rows - 1) / rows;
        const count = (frames + stride - 1) / stride;

        var pass = try gb_trace.run(gpa, io, rom, rec, 0, count, stride, offset, build_options.mesen_path, home, null);
        const samples = try pass.samples(gpa, rec, 0);
        const track = tas.Track.ofSamples(samples);
        const fs = try tas.faithfulness(gpa, track, tas.stuck_min_frames);
        const events = try collectEvents(gpa, pass, samples);

        const seam_text: []const u8 = if (prev_tail) |t| switch (gb_trace.seam(t, pass.head)) {
            .exact => |m| try std.fmt.allocPrint(gpa, "exact (tail {d}, head {d})", .{ m.at_tail, m.at_head }),
            .gap => "gap",
            .unchecked => "unchecked",
        } else "-";
        try out.print("{s}  {d:>6} frames at {d:>7}  by {d:>2}  exit {d}  seam {s}  ", .{
            name, frames, base, stride, pass.code, seam_text,
        });
        if (fs.longest_stuck) |st| {
            try out.print("refusal {d} at {d}\n", .{ st.frames, st.start });
        } else {
            try out.print("no refusal\n", .{});
        }
        if (pass.frames_run < frames or pass.code != 0) {
            try out.print("FAIL:   {s} stopped at {d} of {d}\n", .{ name, pass.frames_run, frames });
            failed = true;
        }
        for (samples, 0..) |sm, i| {
            // A kill is the count one lower, the Queen's 01 to 00 included. A
            // death reads it as 00 from anything else, and is not one.
            if (i != 0 and bcdDec(samples[i - 1].metroid_count) == sm.metroid_count) kills += 1;
            if (first_count == null and sm.metroid_count != 0) first_count = sm.metroid_count;
        }
        for (events) |*e| {
            try tsv.writer.print("{d}\t{d}\t{d}\t{X:0>2}\t{X:0>2}\t{X:0>4}\t{X:0>4}\t{s}\n", .{
                k + 1, e.frame, base + e.frame, e.room.map_bank, e.room.cell, e.y, e.x, e.text(),
            });
        }
        // The beam is not a column (see `gb_trace.end_at`): its changes come
        // from the pass's log, at the frame, without a room.
        const log = pass.beam_log orelse &.{};
        for (log) |c| {
            try out.print("        beam {s} -> {s} at {d}\n", .{
                gb_trace.beamName(last_beam), gb_trace.beamName(c.beam), c.frame,
            });
            try tsv.writer.print("{d}\t{d}\t{d}\t\t\t\t\tbeam {s} -> {s}\n", .{
                k + 1, c.frame, base + c.frame, gb_trace.beamName(last_beam), gb_trace.beamName(c.beam),
            });
            last_beam = c.beam;
        }
        if (pass.beam_log == null or pass.beam_dropped != 0 or pass.end_beam != last_beam) {
            try out.print("FAIL:   {s}'s beam log is incomplete ({d} dropped, ends {s}, pass ends {s})\n", .{
                name, pass.beam_dropped, gb_trace.beamName(last_beam), gb_trace.beamName(pass.end_beam),
            });
            failed = true;
        }
        last_beam = pass.end_beam;
        last_clock = pass.end_clock;
        if (pass.frames != 0) last_count = pass.get(pass.frames - 1, "metroid_count");
        prev_tail = pass.tail;
        base += frames;
    }

    // Decrements against the net: a kill a death undid is counted twice in
    // the first and once in the second.
    const from = first_count orelse 0;
    try out.print("run:    {d} segments, {d} frames, {d} kill(s), count {X:0>2} -> {X:0>2} ({d} net), clock {X}:{X:0>2}\n", .{
        names.items.len,                   base,                 kills, from, last_count,
        bcdInt(from) - bcdInt(@intCast(last_count)), last_clock >> 8, last_clock & 0xFF,
    });

    var odir = try std.Io.Dir.cwd().createDirPathOpen(io, gb_trace.out_dir, .{});
    defer odir.close(io);
    const tname = try std.fmt.allocPrint(gpa, "set-{s}.tsv", .{std.fs.path.basename(dir_path)});
    try odir.writeFile(io, .{ .sub_path = tname, .data = tsv.written() });
    try out.print("wrote:  {s}/{s}\n", .{ gb_trace.out_dir, tname });
    try out.flush();
    if (failed) std.process.exit(1);
}

/// `zig build gbtrace -- ... world <frame>...` — the world at each anchor.
///
/// One file per anchor rather than one table: a tilemap is a 32x32 picture and
/// a column of 1 024 numbers is not a thing anyone reads. The block array goes
/// in the same file, because the two halves of a world are only meaningful
/// together — a shot block is *absent* from the tilemap, and only the array
/// says it is coming back.
fn runWorldMode(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    rec: gb_trace.Recording,
    frames: []const u32,
    offset: usize,
    home: []const u8,
) !void {
    if (frames.len == 0) {
        try out.print("gbtrace: `world` needs at least one frame\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    if (frames.len > gb_trace.max_worlds) {
        try out.print(
            "gbtrace: {d} anchors asked for; one pass holds {d} ({d} bytes each in {d})\n",
            .{ frames.len, gb_trace.max_worlds, gb_trace.world_bytes, gb_trace.sram_bytes - gb_trace.records_at },
        );
        try out.flush();
        std.process.exit(1);
    }

    try out.print("world:  {d} anchor(s), {d} bytes each, {d} a pass\n", .{
        frames.len, gb_trace.world_bytes, gb_trace.max_worlds,
    });
    try out.print("offset: {d} — the movie's rows are held back this many frames\n", .{offset});
    try out.flush();

    var pass = try gb_trace.runWorlds(gpa, io, rom, rec, frames, offset, build_options.mesen_path, home, null);
    defer pass.deinit(gpa);

    try out.print("ran:    {d} of {d} recorded, stopped at {d}, exit {d}\n", .{
        pass.worlds.len, frames.len, pass.frames_run, pass.code,
    });

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, gb_trace.out_dir, .{});
    defer dir.close(io);

    var blank: usize = 0;
    for (pass.worlds) |w| {
        // A blocked VRAM read succeeds and returns 1 024 identical bytes, so
        // this is reported per anchor rather than left to be discovered by a
        // comparison that agrees both machines are in the same nothing.
        if (w.blank()) blank += 1;
        try out.print("  frame {d:>6}  scx {d:>3} scy {d:>3}  via {s}  {d} live block(s){s}\n", .{
            w.frame,
            w.scx,
            w.scy,
            switch (w.via) {
                .video_ram => "gbVideoRam",
                .cpu_bus => "cpu bus",
                _ => "?",
            },
            w.liveBlocks(),
            if (w.blank()) "  BLANK — the read was gated" else "",
        });

        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "world-{d}.bin", .{w.frame});
        var body: [gb_trace.tilemap_bytes + gb_trace.blocks_bytes]u8 = undefined;
        @memcpy(body[0..gb_trace.tilemap_bytes], &w.tiles);
        @memcpy(body[gb_trace.tilemap_bytes..], &w.blocks);
        try dir.writeFile(io, .{ .sub_path = name, .data = &body });
    }
    try out.print("wrote:  {d} file(s) in {s}/, tilemap then block array\n", .{
        pass.worlds.len, gb_trace.out_dir,
    });
    if (blank != 0) {
        try out.print("FAIL:   {d} anchor(s) came back blank; the tilemap read was gated\n", .{blank});
        try out.flush();
        std.process.exit(1);
    }
    try out.flush();
}

/// `zig build gbtrace -- ... refs <origin:frames>...` — a whole reference per
/// stretch.
///
/// The world mode answers "what room was the trace in"; this answers "what
/// would a cart have to be built at, and what did the original do from there",
/// which is the pair a graded stretch needs. One replay serves every stretch,
/// for the reason `oracle.referencesFromMovie` gives: separate runs are
/// separate chances for one of them to have taken a different route, and
/// nothing downstream could tell.
fn runRefsMode(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    rec: gb_trace.Recording,
    stretches: []const gb_trace.Stretch,
    offset: usize,
    home: []const u8,
) !void {
    if (stretches.len == 0) {
        try out.print("gbtrace: `refs` needs at least one <origin:frames>\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    if (!gb_trace.refsFit(stretches)) {
        try out.print(
            "gbtrace: {d} stretch(es) want {d} bytes; one pass holds {d} ({d} a snapshot, {d} a frame)\n",
            .{
                stretches.len,          gb_trace.refsBytes(stretches), gb_trace.trace_region,
                gb_trace.snapshot_bytes, gb_trace.record_bytes,
            },
        );
        try out.print(
            "        {d} stretch(es) leave {d} frame(s) between them\n",
            .{ stretches.len, gb_trace.refFramesBudget(stretches.len) },
        );
        try out.flush();
        std.process.exit(1);
    }

    try out.print("refs:   {d} stretch(es), {d} bytes of snapshot each, {d} of {d} bytes used\n", .{
        stretches.len, gb_trace.snapshot_bytes, gb_trace.refsBytes(stretches), gb_trace.trace_region,
    });
    try out.print("offset: {d} — the movie's rows are held back this many frames\n", .{offset});
    try out.flush();

    var pass = try gb_trace.runRefs(gpa, io, rom, rec, stretches, offset, build_options.mesen_path, home);
    defer pass.deinit(gpa);

    try out.print("ran:    {d} of {d} taken, stopped at {d}, exit {d}\n", .{
        pass.refs.len, stretches.len, pass.frames_run, pass.code,
    });

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, gb_trace.out_dir, .{});
    defer dir.close(io);

    var blank: usize = 0;
    for (pass.refs) |r| {
        const s = r.snapshot;
        if (s.blank()) blank += 1;
        // The snapshot, as the cart would have to be built: the cell, the
        // pixel, the camera, and the two halves of the collision rule.
        try out.print(
            "  origin {d:>6} (world at {d})  bank ${X:0>2} cell ${X:0>2}  y {X:0>4} x {X:0>4}" ++
                "  cam {X:0>4},{X:0>4}  solid ${X:0>2}  {d} live block(s)  via {s}{s}\n",
            .{
                s.origin,
                s.frame,
                s.map_bank,
                (s.screen_row << 4) | (s.screen_col & 0x0F),
                (@as(u16, s.screen_row) << 8) | s.pixel_y,
                (@as(u16, s.screen_col) << 8) | s.pixel_x,
                s.camera_y,
                s.camera_x,
                s.solid,
                s.liveBlocks(),
                switch (s.via) {
                    .video_ram => "gbVideoRam",
                    .cpu_bus => "cpu bus",
                    _ => "?",
                },
                if (s.blank()) "  BLANK — the read was gated" else "",
            },
        );

        // The stretch's own frames, as the same table every other track is
        // read as. `lag` is checked per stretch rather than once for the pass:
        // each is its own window, and a window inside a cutscene has too few
        // pad changes to be evidence of anything.
        const shift = r.pass.lag(rec);
        const samples = try r.pass.samples(gpa, rec, shift orelse gb_trace.input_offset);
        defer gpa.free(samples);
        const last = samples[samples.len - 1];
        try out.print(
            "         {d} frame(s) to {d}: y {X:0>4} x {X:0>4} pose ${X:0>2} bank ${X:0>2}" ++
                "  lag {s} ({d} pad change(s))\n",
            .{
                samples.len,
                last.frame,
                last.samus_y,
                last.samus_x,
                last.pose,
                last.map_bank,
                if (shift) |sh| switch (sh) {
                    0 => "0",
                    1 => "1",
                    2 => "2",
                    3 => "3",
                    else => ">3",
                } else "unchecked",
                r.pass.padChanges(),
            },
        );

        var buf: [64]u8 = undefined;
        const tsv = try gb_trace.tsv(gpa, r.pass, samples);
        defer gpa.free(tsv);
        try dir.writeFile(io, .{
            .sub_path = try std.fmt.bufPrint(&buf, "ref-{d}.tsv", .{s.origin}),
            .data = tsv,
        });
        // Tilemap, block array and block-type table, in that order: the three
        // pieces of the world an anchor has to restore.
        var body: [gb_trace.tilemap_bytes + gb_trace.blocks_bytes + gb_trace.coltab_bytes]u8 = undefined;
        @memcpy(body[0..gb_trace.tilemap_bytes], &s.tiles);
        @memcpy(body[gb_trace.tilemap_bytes..][0..gb_trace.blocks_bytes], &s.blocks);
        @memcpy(body[gb_trace.tilemap_bytes + gb_trace.blocks_bytes ..], &s.coltab);
        try dir.writeFile(io, .{
            .sub_path = try std.fmt.bufPrint(&buf, "ref-{d}.bin", .{s.origin}),
            .data = &body,
        });
    }
    try out.print("wrote:  {d} stretch(es) in {s}/ as ref-<origin>.tsv and .bin\n", .{
        pass.refs.len, gb_trace.out_dir,
    });

    if (blank != 0) {
        try out.print("FAIL:   {d} snapshot(s) came back blank; the tilemap read was gated\n", .{blank});
        try out.flush();
        std.process.exit(1);
    }
    if (pass.refs.len != stretches.len) {
        try out.print("FAIL:   {d} stretch(es) were never reached\n", .{stretches.len - pass.refs.len});
        try out.flush();
        std.process.exit(1);
    }
    try out.flush();
}

fn runAisMode(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    rec: gb_trace.Recording,
    through: usize,
    offset: usize,
    home: []const u8,
) !void {
    try out.print("ais:    enemy AI dispatches at 02:{X:0>4}, frames 0..{d}\n", .{ gb_trace.ai_jump_addr, through });
    try out.flush();

    var pass = try gb_trace.runAis(gpa, io, rom, rec, through, offset, build_options.mesen_path, home);
    defer pass.deinit(gpa);

    try out.print("ran:    {d} distinct (AI, sprite) pair(s), stopped at {d}, exit {d}\n", .{
        pass.seen.len, pass.frames_run, pass.code,
    });

    // Sorted by AI then sprite, so two passes diff as text.
    std.mem.sort(gb_trace.AiSeen, pass.seen, {}, struct {
        fn lt(_: void, x: gb_trace.AiSeen, y: gb_trace.AiSeen) bool {
            return if (x.ai != y.ai) x.ai < y.ai else x.sprite < y.sprite;
        }
    }.lt);

    var tsv: std.Io.Writer.Allocating = .init(gpa);
    try tsv.writer.print("ai\tsprite\tbank\tcell\tfirst\tlast\tdispatches\n", .{});
    var distinct: usize = 0;
    for (pass.seen, 0..) |s, i| {
        if (i == 0 or pass.seen[i - 1].ai != s.ai) distinct += 1;
        try out.print("  02:{X:0>4}  sprite ${X:0>2}  first ${X}:${X:0>2} at {d:>6}  last {d:>6}  {d:>7} dispatch(es)\n", .{
            s.ai, s.sprite, s.bank, s.cell, s.first, s.last, s.dispatches,
        });
        try tsv.writer.print("{X:0>4}\t{X:0>2}\t{X:0>2}\t{X:0>2}\t{d}\t{d}\t{d}\n", .{
            s.ai, s.sprite, s.bank, s.cell, s.first, s.last, s.dispatches,
        });
    }
    try out.print("        {d} distinct AI(s)\n", .{distinct});

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, gb_trace.out_dir, .{});
    defer dir.close(io);
    var buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "ais-{d}.tsv", .{through});
    try dir.writeFile(io, .{ .sub_path = name, .data = tsv.written() });
    try out.print("wrote:  {s}/{s}\n", .{ gb_trace.out_dir, name });

    if (pass.overflow) {
        try out.print("FAIL:   more than {d} pairs; the census was truncated\n", .{gb_trace.max_ai_seen});
        try out.flush();
        std.process.exit(1);
    }
    // The script stops at the movie's end when `through` reaches it, as
    // `writeAiLua` clamps; the check has to clamp the same way, or every
    // whole-movie census is refused for the frames the movie does not have.
    if (pass.frames_run < @min(through + offset, rec.frames())) {
        try out.print("FAIL:   the pass stopped at {d} before reaching {d}\n", .{ pass.frames_run, through });
        try out.flush();
        std.process.exit(1);
    }
    try out.flush();
}

fn runKillsMode(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    rec: gb_trace.Recording,
    first: usize,
    last: usize,
    offset: usize,
    home: []const u8,
) !void {
    try out.print("kills:  frames {d}..{d}, a record whenever the fight moves\n", .{ first, last });
    try out.flush();

    var pass = try gb_trace.runKills(gpa, io, rom, rec, first, last, offset, build_options.mesen_path, home);
    defer pass.deinit(gpa);

    try out.print("  frame  slot  pdt  st  cut stun fgt  wpn dir  real disp nxtq  eqt aftr sreq splg  ahp gstn zstn ostn   ctr pose bank scry sreq room  loaded state (D808-D814)                     st   y   x spr  gv ctr sta  hp flg\n", .{});
    var tsv: std.Io.Writer.Allocating = .init(gpa);
    try tsv.writer.print("frame\tslot", .{});
    for (gb_trace.kill_watch) |a| try tsv.writer.print("\t{X:0>4}", .{a});
    for (gb_trace.kill_carry) |a| try tsv.writer.print("\t{X:0>4}", .{a});
    for (gb_trace.kill_slot_fields) |o| try tsv.writer.print("\t+{X:0>2}", .{o});
    try tsv.writer.print("\n", .{});
    for (pass.events) |e| {
        try out.print("  {d:>5}   {X:0>2} ", .{ e.frame, e.slot });
        for (e.watch) |b| try out.print("  {X:0>2}", .{b});
        try out.print("  ", .{});
        for (e.carry) |b| try out.print("  {X:0>2}", .{b});
        try out.print("  ", .{});
        for (e.fields) |b| try out.print("  {X:0>2}", .{b});
        try out.print("\n", .{});
        try tsv.writer.print("{d}\t{X:0>2}", .{ e.frame, e.slot });
        for (e.watch) |b| try tsv.writer.print("\t{X:0>2}", .{b});
        for (e.carry) |b| try tsv.writer.print("\t{X:0>2}", .{b});
        for (e.fields) |b| try tsv.writer.print("\t{X:0>2}", .{b});
        try tsv.writer.print("\n", .{});
    }
    try out.print("ran:    {d} record(s), stopped at {d}, {d} dropped\n", .{ pass.events.len, pass.frames_run, pass.dropped });

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, gb_trace.out_dir, .{});
    defer dir.close(io);
    var buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "kills-{d}-{d}.tsv", .{ first, last });
    try dir.writeFile(io, .{ .sub_path = name, .data = tsv.written() });
    try out.print("wrote:  {s}/{s}\n", .{ gb_trace.out_dir, name });
    if (pass.dropped != 0) {
        try out.print("FAIL:   {d} record(s) did not fit; narrow the window\n", .{pass.dropped});
        try out.flush();
        std.process.exit(1);
    }
    try out.flush();
}

fn runSavesMode(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    rec: gb_trace.Recording,
    first: usize,
    last: usize,
    offset: usize,
    home: []const u8,
) !void {
    try out.print("saves:  frames {d}..{d}, a record whenever the save path moves\n", .{ first, last });
    try out.flush();

    var pass = try gb_trace.runSaves(gpa, io, rom, rec, first, last, offset, build_options.mesen_path, home);
    defer pass.deinit(gpa);

    try out.print("  frame  cool  mode cont dead load slot   cdn  ctr edge pose bank   ys  yp  xs  xp   hl  hh  dl  dh real disp  cdl cdh dat\n", .{});
    var tsv: std.Io.Writer.Allocating = .init(gpa);
    try tsv.writer.print("frame\tcooling", .{});
    for (gb_trace.save_watch) |a| try tsv.writer.print("\t{X:0>4}", .{a});
    for (gb_trace.save_carry) |a| try tsv.writer.print("\t{X:0>4}", .{a});
    try tsv.writer.print("\tslot\n", .{});
    var prev: ?[gb_trace.save_slot_bytes]u8 = null;
    for (pass.events) |e| {
        try out.print("  {d:>5}   {d}  ", .{ e.frame, e.cooling });
        for (e.watch) |b| try out.print("  {X:0>2} ", .{b});
        try out.print(" ", .{});
        for (e.carry) |b| try out.print("  {X:0>2}", .{b});
        try out.print("\n", .{});
        // The slot only when it changed: the frame the writer ran.
        if (prev == null or !std.mem.eql(u8, &prev.?, &e.slot)) {
            try out.print("         slot:", .{});
            for (e.slot) |b| try out.print(" {X:0>2}", .{b});
            try out.print("\n", .{});
        }
        prev = e.slot;
        try tsv.writer.print("{d}\t{d}", .{ e.frame, e.cooling });
        for (e.watch) |b| try tsv.writer.print("\t{X:0>2}", .{b});
        for (e.carry) |b| try tsv.writer.print("\t{X:0>2}", .{b});
        try tsv.writer.print("\t", .{});
        for (e.slot) |b| try tsv.writer.print("{X:0>2}", .{b});
        try tsv.writer.print("\n", .{});
    }
    try out.print("ran:    {d} record(s), stopped at {d}, {d} dropped\n", .{ pass.events.len, pass.frames_run, pass.dropped });

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, gb_trace.out_dir, .{});
    defer dir.close(io);
    var buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "saves-{d}-{d}.tsv", .{ first, last });
    try dir.writeFile(io, .{ .sub_path = name, .data = tsv.written() });
    try out.print("wrote:  {s}/{s}\n", .{ gb_trace.out_dir, name });
    if (pass.dropped != 0) {
        try out.print("FAIL:   {d} record(s) did not fit; narrow the window\n", .{pass.dropped});
        try out.flush();
        std.process.exit(1);
    }
    try out.flush();
}

/// `zig build gbtrace -- <dir> set worlds` (1.0 Step 18c): every cell the
/// recording stays in, the tiles Mesen's Game Boy was showing against the
/// table the port draws the cell with.
///
/// `oracle -- worlds` does this for the published runs, through our own Game
/// Boy. This is the recording's, through Mesen: one census pass a segment
/// finds the visits, and one world pass a segment reads the tilemap at the
/// middle of each. A visit is a run of samples in one cell lasting
/// `set_world_min_frames` or more, and a cell is taken once a Metroid count,
/// because the lava's table moves with the count.
fn runSetWorlds(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    dir_path: []const u8,
    offset: usize,
    home: []const u8,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        try out.print("gbtrace: no segment directory at {s}\n", .{dir_path});
        try out.flush();
        std.process.exit(1);
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".mmo")) continue;
        try names.append(gpa, try gpa.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);

    // Mesen's passes, in lanes (1.0 Step 18c2). The census passes are
    // independent; the world passes depend on the picks, which depend on every
    // earlier segment's (a cell is taken once), so the picks are made in order
    // between the two. Grading is in order too, so the report reads as before.
    const lanes = set_world_lanes;
    const segs = try gpa.alloc(Seg, names.items.len);
    for (segs, names.items) |*g, name| g.* = .{ .path = try std.fs.path.join(gpa, &.{ dir_path, name }) };
    const env: SetEnv = .{ .io = io, .rom = rom, .offset = offset, .home = home };
    try inLanes(Seg, segs, lanes, env, censusSeg);

    const Key = struct { bank: u8, cell: u8, count: u8 };
    var seen: std.AutoHashMapUnmanaged(Key, void) = .empty;
    var chunks: std.ArrayList(Chunk) = .empty;
    for (segs, 0..) |*g, k| {
        // The visits, and the middle sample of each new one.
        var picks: std.ArrayList(tas.Sample) = .empty;
        const samples = g.samples;
        var start: usize = 0;
        for (0..samples.len + 1) |i| {
            if (i < samples.len and tas.Room.of(samples[i]).eql(tas.Room.of(samples[start]))) continue;
            defer start = i;
            const first = samples[start];
            const last = samples[i - 1];
            if (last.frame - first.frame < set_world_min_frames) continue;
            const mid = samples[(start + i - 1) / 2];
            const room = tas.Room.of(mid);
            if (room.map_bank < map_mod.first_bank or room.map_bank > map_mod.last_bank) continue;
            const got = try seen.getOrPut(gpa, .{ .bank = room.map_bank, .cell = room.cell, .count = mid.metroid_count });
            if (got.found_existing) continue;
            try picks.append(gpa, mid);
        }
        g.picks = picks.items;
        var at: usize = 0;
        while (at < picks.items.len) {
            const n = @min(picks.items.len - at, gb_trace.max_worlds);
            try chunks.append(gpa, .{ .seg = k, .rec = g.rec, .picks = picks.items[at..][0..n] });
            at += n;
        }
    }
    try inLanes(Chunk, chunks.items, lanes, env, worldChunk);

    var static = try screens.assign(gpa, rom);
    defer static.deinit(gpa);
    const walked_doors = try warp.loadWalked(gpa, rom);
    var walked = try warp.assignWalked(gpa, rom, walked_doors);
    defer walked.deinit(gpa);
    // A walked lava room at the visit's count, not the crawl's (1.0 Step 18d).
    var replay = try warp.LavaReplay.init(gpa, rom, walked_doors);
    defer replay.deinit(gpa);
    var world = try roster.world(gpa, rom);
    defer world.deinit(gpa);

    var tsv: std.Io.Writer.Allocating = .init(gpa);
    try tsv.writer.print("segment\tframe\tbank\tcell\tcount\tcompared\tgb_table\tgb_matched\tstatic_table\tstatic_matched\twalked_table\twalked_matched\tprovenance\n", .{});

    var tally: struct { rows: usize = 0, empty: usize = 0, st: usize = 0, wk: usize = 0, lava: usize = 0 } = .{};
    var failed = false;
    var misses: std.ArrayList(oracle.Visit) = .empty;
    var seen_tables: std.ArrayList(warp.Recorded) = .empty;

    var ci: usize = 0;
    for (segs, names.items, 0..) |g, name, k| {
        while (ci < chunks.items.len and chunks.items[ci].seg == k) : (ci += 1) {
            const wp = chunks.items[ci].worlds;
            for (chunks.items[ci].picks) |sm| {
                const wd = wp.find(sm.frame) orelse {
                    try out.print("FAIL:   {s} frame {d}: no world recorded\n", .{ name, sm.frame });
                    failed = true;
                    continue;
                };
                if (wd.blank()) {
                    try out.print("FAIL:   {s} frame {d}: the tilemap read was gated\n", .{ name, sm.frame });
                    failed = true;
                    continue;
                }
                const room = tas.Room.of(sm);
                const mi = room.map_bank - map_mod.first_bank;
                const cx: u4 = @intCast(room.cell & 0x0F);
                const cy: u4 = @intCast(room.cell >> 4);
                const sc = (static.find(room.map_bank, cx, cy) orelse continue).choice orelse continue;
                var wc = (walked.find(room.map_bank, cx, cy) orelse continue).choice orelse continue;
                if (wc.provenance == .walked and warp.isLavaTable(wc.tiletable)) {
                    if (replay.table(world.roomOf(.{ .bank = room.map_bank, .cell = room.cell }), sm.metroid_count)) |t| wc.tiletable = t;
                }
                const a = try oracle.compareCell(gpa, rom, mi, room.cell, sc.tiletable, &wd.tiles, wd.scx, wd.scy, sm.samus_x, sm.samus_y);
                const b = try oracle.compareCell(gpa, rom, mi, room.cell, wc.tiletable, &wd.tiles, wd.scx, wd.scy, sm.samus_x, sm.samus_y);
                tally.rows += 1;
                if (a.compared == 0) {
                    tally.empty += 1;
                    continue;
                }
                const st_ok = a.gb_best_matched <= a.matched;
                const wk_ok = b.gb_best_matched <= b.matched;
                tally.st += @intFromBool(st_ok);
                tally.wk += @intFromBool(wk_ok);
                const lava = !wk_ok and warp.isLavaTable(wc.tiletable) and warp.isLavaTable(b.gb_best_table);
                tally.lava += @intFromBool(lava);
                if (!wk_ok) try misses.append(gpa, .{ .bank = room.map_bank, .cell = room.cell, .count = sm.metroid_count });
                try seen_tables.append(gpa, .{ .bank = room.map_bank, .cell = room.cell, .count = sm.metroid_count, .table = a.gb_best_table });
                try tsv.writer.print("{d}\t{d}\t{X}\t{X:0>2}\t{X:0>2}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\n", .{
                    k + 1, sm.frame, room.map_bank, room.cell, sm.metroid_count, a.compared, a.gb_best_table, a.gb_best_matched, sc.tiletable, a.matched, wc.tiletable, b.matched, @tagName(wc.provenance),
                });
                if (!wk_ok) try out.print("  {s} frame {d:>6}  ${X}:${X:0>2} count {X:0>2}: Game Boy table {d} ({d}/{d}), walked {d} {s} ({d}), static {d} ({d}){s}\n", .{
                    name, sm.frame, room.map_bank, room.cell, sm.metroid_count, b.gb_best_table, b.gb_best_matched, b.compared, wc.tiletable, @tagName(wc.provenance), b.matched, sc.tiletable, a.matched, if (lava) "  -- the lava level" else "",
                });
            }
        }
        try out.print("{s}: {d} visits graded\n", .{ name, g.picks.len });
    }
    try out.flush();

    try out.print("\nWORLDS (recording): {d} cell-visits, {d} with no window; of the rest, the static reading explains {d}, the walked {d}; {d} of the walked's misses are the lava level\n", .{
        tally.rows, tally.empty, tally.st, tally.wk, tally.lava,
    });
    var odir = try std.Io.Dir.cwd().createDirPathOpen(io, gb_trace.out_dir, .{});
    defer odir.close(io);
    const tname = try std.fmt.allocPrint(gpa, "worlds-{s}.tsv", .{std.fs.path.basename(dir_path)});
    try odir.writeFile(io, .{ .sub_path = tname, .data = tsv.written() });
    try out.print("wrote:  {s}/{s}\n", .{ gb_trace.out_dir, tname });

    // 1.0 Step 18f: the warp table holds its entries to these tables, so the
    // committed copy has to be what the recording still says.
    const recorded = try warp.parseRecorded(gpa, warp.recorded_tables);
    defer gpa.free(recorded);
    var drift: usize = 0;
    for (seen_tables.items) |t| if (std.mem.indexOfScalar(warp.Recorded, recorded, t) == null) {
        try out.print("DRIFT:  {X} {X:0>2} {X:0>2} {d}  -- the recording shows it, src/recorded_tables.txt does not\n", .{ t.bank, t.cell, t.count, t.table });
        drift += 1;
    };
    for (recorded) |t| if (std.mem.indexOfScalar(warp.Recorded, seen_tables.items, t) == null) {
        try out.print("DRIFT:  {X} {X:0>2} {X:0>2} {d}  -- src/recorded_tables.txt has it, the recording does not\n", .{ t.bank, t.cell, t.count, t.table });
        drift += 1;
    };
    if (drift != 0) {
        try out.print("FAIL:   {d} line(s) of src/recorded_tables.txt differ from the recording\n", .{drift});
        failed = true;
    } else try out.print("PASS:   src/recorded_tables.txt is the recording's ({d} visits)\n", .{recorded.len});

    if (!try gradeReach(gpa, out, rom, segs, walked_doors, &world)) failed = true;

    const pin = try oracle.parseWorldPin(gpa, oracle.world_misses_pin);
    const v = try oracle.gradeWorlds(gpa, misses.items, pin);
    try out.print("PIN:    {d} miss(es), {d} pinned (src/worlds_misses.txt)\n", .{ v.misses, v.pinned });
    for (v.lost) |m| try out.print("LOST:   {X} {X:0>2} {X:0>2}  -- misses, and the pin does not list it\n", .{ m.bank, m.cell, m.count });
    for (v.gained) |m| try out.print("GAINED: {X} {X:0>2} {X:0>2}  -- listed, and explained or not visited\n", .{ m.bank, m.cell, m.count });
    if (!v.ok()) {
        try out.print("FAIL:   {d} visit(s) the reading drew right at the pin now miss\n", .{v.lost.len});
        failed = true;
    } else if (v.raise()) try out.print("PASS:   raise the pin: remove the {d} GAINED line(s) from src/worlds_misses.txt\n", .{v.gained.len}) else try out.print("PASS:   every miss is pinned\n", .{});
    try out.flush();
    if (failed) std.process.exit(1);
}

/// **The warp rooms' reach against the recording (1.0 Step 18f).** Every
/// position Samus held in a warp entry's room, at a count where the entry's
/// chain leaves the table the recording shows, has to be one `warp.reach`
/// says a ball gets to from the room's doors under that table: the reading
/// the warp's spots are chosen inside.
fn gradeReach(gpa: std.mem.Allocator, out: *std.Io.Writer, rom: []const u8, segs: []const Seg, walked: []const warp.WalkedDoor, world: *const roster.World) !bool {
    var built = try warp.build(gpa, rom, walked);
    defer built.deinit(gpa);
    const recorded = try warp.parseRecorded(gpa, warp.recorded_tables);
    defer gpa.free(recorded);
    var runner = try warp.Runner.init(gpa, rom);
    defer runner.deinit(gpa);
    var held: usize = 0;
    var total: usize = 0;
    for (built.entries) |e| {
        if (e.dest.kind == .queen or e.dest.kind == .ship) continue;
        const cell: u8 = @intCast(((e.samus_y >> 8) & 0xF) << 4 | ((e.samus_x >> 8) & 0xF));
        const room = world.roomOf(.{ .bank = e.dest.at.bank, .cell = cell });
        // The reach under what the chain leaves at each position's count: the
        // warp runs it at the live count, and a lava room's level moves with it.
        var reaches: std.AutoHashMapUnmanaged(u16, warp.Reach) = .empty;
        defer {
            var it = reaches.valueIterator();
            while (it.next()) |v| v.deinit(gpa);
            reaches.deinit(gpa);
        }
        var in: usize = 0;
        var n: usize = 0;
        var first_out: ?tas.Sample = null;
        for (segs) |g| for (g.samples) |sm| {
            const at = tas.Room.of(sm);
            if (at.map_bank != e.dest.at.bank or world.roomOf(.{ .bank = at.map_bank, .cell = at.cell }) != room) continue;
            const t = runner.tilesetAt(e, sm.metroid_count);
            const shows = for (recorded) |rc| {
                if (rc.bank == at.map_bank and rc.cell == at.cell and rc.count == sm.metroid_count) break rc.table == t.tiletable;
            } else false;
            if (!shows) continue;
            n += 1;
            const key = @as(u16, t.tiletable) << 1 | @intFromBool(sm.metroid_count == 0);
            const got = try reaches.getOrPut(gpa, key);
            if (!got.found_existing) got.value_ptr.* = try warp.reachWith(gpa, rom, world.*, e.dest.at.bank, room, t, sm.metroid_count == 0);
            if (got.value_ptr.near(sm.samus_y, sm.samus_x)) in += 1 else if (first_out == null) first_out = sm;
        };
        total += n;
        held += in;
        if (first_out) |sm| try out.print("REACH:  {s} ${X}:${X:0>2}: {d} of {d} recorded positions in reach; first out frame {d} at ${X:0>4},${X:0>4} pose {X:0>2}\n", .{
            @tagName(e.dest.kind), e.dest.at.bank, e.dest.at.cell, in, n, sm.frame, sm.samus_y, sm.samus_x, sm.pose,
        });
    }
    try out.print("REACH (recording): {d} of {d} positions in warp rooms are in reach\n", .{ held, total });
    const missed = total - held;
    if (total < reach_positions_floor or missed > reach_misses_pin) {
        try out.print("FAIL:   {d} out of reach (pin {d}) of {d} graded (floor {d})\n", .{ missed, reach_misses_pin, total, reach_positions_floor });
        return false;
    }
    if (missed < reach_misses_pin) try out.print("PASS:   raise the pin: reach_misses_pin to {d}\n", .{missed}) else try out.print("PASS:   the reach's misses are the pin's {d}\n", .{missed});
    return true;
}

/// The reach grade's pins (1.0 Step 18f), taken at its close: the recorded
/// positions out of reach, every one a frame of an edge crossing (her x or y
/// past the door's trigger, into the cell beyond), and the positions graded.
/// A lower count is a gain; lower the pin in the commit that makes it. The
/// floor moved from 36 182 once, when lava rooms kept their $47 level and
/// `$A:$E0` and `$A:$E7` left the warp list (no chain into them keeps lava).
const reach_misses_pin: usize = 39;
const reach_positions_floor: usize = 35888;

/// How many Mesens `set worlds` runs at once (1.0 Step 18c2). Each is one
/// core, and each has its own file names (`gb_trace.spawnPassIn`).
const set_world_lanes: u8 = 8;

const SetEnv = struct { io: std.Io, rom: []const u8, offset: usize, home: []const u8 };

/// One segment of a recording: its census, and the visits picked from it.
const Seg = struct {
    path: []const u8,
    rec: gb_trace.Recording = undefined,
    samples: []tas.Sample = &.{},
    picks: []const tas.Sample = &.{},
    err: ?anyerror = null,
};

/// One world pass: up to `max_worlds` of a segment's picks.
const Chunk = struct {
    seg: usize,
    rec: gb_trace.Recording,
    picks: []const tas.Sample,
    worlds: gb_trace.WorldPass = undefined,
    err: ?anyerror = null,
};

fn censusSeg(env: SetEnv, g: *Seg, lane: u8) !void {
    const a = std.heap.smp_allocator;
    const mmo = try std.Io.Dir.cwd().readFileAlloc(env.io, g.path, a, .limited(64 * 1024 * 1024));
    g.rec = try gb_trace.readRecording(a, mmo);
    try g.rec.checkCartridge(env.rom);
    const frames = g.rec.frames();
    const rows = gb_trace.max_frames - gb_trace.beam_log_rows;
    const stride = (frames + rows - 1) / rows;
    const count = (frames + stride - 1) / stride;
    const pass = try gb_trace.run(a, env.io, env.rom, g.rec, 0, count, stride, env.offset, build_options.mesen_path, env.home, lane);
    g.samples = try pass.samples(a, g.rec, 0);
}

fn worldChunk(env: SetEnv, c: *Chunk, lane: u8) !void {
    const a = std.heap.smp_allocator;
    const want = try a.alloc(u32, c.picks.len);
    for (c.picks, want) |sm, *f| f.* = sm.frame;
    c.worlds = try gb_trace.runWorlds(a, env.io, env.rom, c.rec, want, env.offset, build_options.mesen_path, env.home, lane);
}

/// Run `f` over `jobs`, `lanes` at a time, each lane taking the next job as
/// it finishes one. A job's error is kept on it and reported after the join,
/// by name: one failed pass fails the run.
fn inLanes(comptime J: type, jobs: []J, lanes: u8, env: SetEnv, comptime f: fn (SetEnv, *J, u8) anyerror!void) !void {
    const Lane = struct {
        fn go(js: []J, next: *std.atomic.Value(usize), e: SetEnv, lane: u8) void {
            while (true) {
                const i = next.fetchAdd(1, .monotonic);
                if (i >= js.len) return;
                f(e, &js[i], lane) catch |err| {
                    js[i].err = err;
                };
            }
        }
    };
    var next: std.atomic.Value(usize) = .init(0);
    var threads: [32]std.Thread = undefined;
    const n = @min(lanes, jobs.len);
    for (threads[0..n], 0..) |*t, l| t.* = try std.Thread.spawn(.{}, Lane.go, .{ jobs, &next, env, @as(u8, @intCast(l)) });
    for (threads[0..n]) |t| t.join();
    var failed = false;
    for (jobs, 0..) |j, i| if (j.err) |err| {
        std.debug.print("gbtrace: pass {d} of {d} failed: {s}\n", .{ i + 1, jobs.len, @errorName(err) });
        failed = true;
    };
    if (failed) return error.PassFailed;
}

/// A visit shorter than this is not graded: a warp's transition takes up to
/// 46 frames to draw (`oracle.sweep_warp_settle`), and the middle of a visit
/// this long is past it.
const set_world_min_frames: u32 = 120;
