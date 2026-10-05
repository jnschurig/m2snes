//! The audio A/B: one request, two engines, two WAVs to listen to.
//!
//! `audiocmp` (Step 6) answers whether the port's register writes are the Game
//! Boy's, byte for byte. It cannot answer what the result *sounds* like, and it
//! is not meant to: a rendered waveform compares the shim's synthesis and the
//! S-DSP's mixing on top of the engine, and those are three things to be wrong
//! about at once. This module is where that question is asked instead, by a
//! person, with the two files in front of them.
//!
//! ## The two sides
//!
//! Both start from the same `.req` script, which is written out beside the WAVs
//! so a render can be replayed by hand.
//!
//!   - **The Game Boy side** (`audioab_render.zig`) runs bank 4 on this
//!     repository's harness, exactly as `audiocmp.runGb` does, and feeds the
//!     writes it makes to SameBoy's APU (`sbref.c`). Not a recording of an
//!     emulator's speakers: the writes are the same ones `audiocmp` grades, so
//!     what is rendered is the stream the comparison calls the reference.
//!   - **The SNES side** is `spcrun --wav` on the ARAM image: the shim running
//!     the ported engine, and the S-DSP's own output.
//!
//! ## What the two files do not share
//!
//! Sample rate (SameBoy is asked for 44100; the S-DSP core produces 32000),
//! and the exact moment a tick's writes land inside its frame — `spcrun` packs
//! two or three ticks into a message where the console sends one, and says so
//! in its own header. Neither matters to an ear comparing two takes of the same
//! sixty seconds, and both would matter to a comparator, which is why this
//! writes files rather than a verdict.
//!
//! ## Ticks are a frame apart
//!
//! The harness calls `handleAudio` back to back, since for grading only the
//! order of writes matters. Sound needs the *rate*: on the Game Boy the call is
//! once a frame, so the render places each tick `gb_frame_cycles` apart and
//! keeps each write's own offset within its tick. Get that wrong and the music
//! plays at the speed of the emulator rather than the speed of the game.
//!
//! What links SameBoy is `audioab_render.zig`, and only that: `vendor/` is not
//! tracked, so everything here has to build and be tested on a machine that
//! has never fetched it.

const std = @import("std");
const audio_req = @import("audio_req.zig");
const wav = @import("wav.zig");

/// T-cycles in a DMG frame. The engine is called once a frame, so this is how
/// far apart two ticks are in a render; `audioab_render.zig` places them.
pub const gb_frame_cycles: u32 = 70224;

// ---- What can be asked for -------------------------------------------------

/// Which request byte a sound effect is asked through. The names are the ones
/// `tools/gen-sfx-reqs.sh` writes its scripts under, so a file here and a file
/// there are the same request.
pub const Channel = enum {
    sq1,
    sq2,
    noise,
    wave,

    pub fn slot(self: Channel) []const u8 {
        return switch (self) {
            .sq1 => "sfxRequest_square1",
            .sq2 => "sfxRequest_square2",
            .noise => "sfxRequest_noise",
            .wave => "sfxRequest_wave",
        };
    }

    pub fn byName(name: []const u8) ?Channel {
        inline for (@typeInfo(Channel).@"enum".fields) |f| {
            if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const Request = union(enum) {
    song: u8,
    sfx: struct { channel: Channel, id: u8 },
};

pub const Ask = struct {
    request: Request,
    /// A song requested on the first tick, with the effect over it at
    /// `over_at`. Songs ignore it.
    over: ?u8 = null,
    /// Ticks from the song's request to the effect's, so the effect lands
    /// mid-song rather than over its opening.
    over_at: u32 = 60,
    /// How long to run, in seconds of ticks at one a frame.
    seconds: u32 = 30,

    /// Ticks, which is frames: the engine is called once a frame.
    pub fn ticks(self: Ask) u32 {
        return self.seconds * 60;
    }

    /// The stem both files are named from. The `.gb` and `.snes` that follow it
    /// sort adjacently, which is the point: a directory listing puts the two
    /// takes of one sound next to each other.
    pub fn stem(self: Ask, buf: []u8) []const u8 {
        return switch (self.request) {
            .song => |id| std.fmt.bufPrint(buf, "song-{X:0>2}", .{id}) catch unreachable,
            .sfx => |s| if (self.over) |song|
                std.fmt.bufPrint(buf, "{s}-{X:0>2}-over-{X:0>2}", .{ @tagName(s.channel), s.id, song }) catch unreachable
            else
                std.fmt.bufPrint(buf, "{s}-{X:0>2}", .{ @tagName(s.channel), s.id }) catch unreachable,
        };
    }
};

/// The `.req` script an ask means, in the text format `audio_req.parse` reads.
///
/// Text rather than a `Script` built by hand, for the reason the generators in
/// `tools/` write text: what is rendered is a file a person can read, edit and
/// hand back to `audiocmp`, and it goes out beside the WAVs.
pub fn scriptText(arena: std.mem.Allocator, ask: Ask) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    const w = &s;

    const total = ask.ticks();
    switch (ask.request) {
        .song => |id| {
            try w.print(arena, "# Song ${X:0>2}, requested on the first tick, then {d} seconds.\n", .{ id, ask.seconds });
            try w.print(arena, "# GENERATED by `zig build audioab`; do not edit.\n", .{});
            try w.print(arena, "[songRequest={X:0>2}]\n", .{id});
            try fill(arena, w, total -| 1);
        },
        .sfx => |sfx| {
            // The ids whose pitch is seeded from rDIV read whatever the divider
            // says, so the scripts that request them set it first — as
            // `tools/gen-sfx-reqs.sh` does, and to the same byte, so a render
            // and a graded script are the same request. Set for every id:
            // harmless where it is not read, and one less thing to get wrong.
            const div = "rDIV=A7 ";
            if (ask.over) |song| {
                try w.print(arena, "# {s} ${X:0>2} at tick {d}, over song ${X:0>2}, {d} seconds in all.\n", .{
                    sfx.channel.slot(), sfx.id, ask.over_at, song, ask.seconds,
                });
                try w.print(arena, "# GENERATED by `zig build audioab`; do not edit.\n", .{});
                try w.print(arena, "[songRequest={X:0>2}]\n", .{song});
                try fill(arena, w, ask.over_at -| 1);
                try w.print(arena, "[{s}{s}={X:0>2}]\n", .{ div, sfx.channel.slot(), sfx.id });
                try fill(arena, w, total -| (ask.over_at + 1));
            } else {
                try w.print(arena, "# {s} ${X:0>2}, requested on the first tick, then {d} seconds.\n", .{
                    sfx.channel.slot(), sfx.id, ask.seconds,
                });
                try w.print(arena, "# GENERATED by `zig build audioab`; do not edit.\n", .{});
                try w.print(arena, "[{s}{s}={X:0>2}]\n", .{ div, sfx.channel.slot(), sfx.id });
                try fill(arena, w, total -| 1);
            }
        },
    }
    return s.items;
}

fn fill(arena: std.mem.Allocator, w: *std.ArrayList(u8), n: u32) !void {
    for (0..n) |_| try w.appendSlice(arena, "[]\n");
}

// ---- Looking at what came out ----------------------------------------------

pub const Measured = struct {
    /// Stereo frames.
    frames: usize,
    seconds: f64,
    peak: u16,

    /// Nothing audible at all. A song id that renders this is a failure of the
    /// render, not a quiet track: every song in the table starts playing on the
    /// tick it is asked for.
    pub fn silent(self: Measured) bool {
        return self.peak < 64;
    }
};

pub fn measure(samples: []const i16, rate: u32) Measured {
    var peak: u16 = 0;
    for (samples) |v| {
        const a: u16 = @intCast(@abs(@as(i32, v)));
        if (a > peak) peak = a;
    }
    const frames = samples.len / wav.channels;
    return .{
        .frames = frames,
        .seconds = @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(rate)),
        .peak = peak,
    };
}

/// The two machines, which do not agree on how long a tick is.
pub const Side = enum { gb, snes };

/// The DMG's clock, and the frame the engine is called once of.
pub const gb_clock_hz: f64 = 4_194_304;
/// NTSC on the SNES: 60.0988 frames a second.
pub const snes_frame_hz: f64 = 60.0988;

/// How long `frames` frames of a script last on one machine.
///
/// **Frames, not ticks.** A script line is a frame of the game and may carry no
/// ticks (a lag frame) or several; `spcrun` plays one line a frame either way,
/// and so does the Game Boy render. A script with lag in it has more frames
/// than ticks and lasts longer than its ticks suggest.
///
/// **Neither machine is 60 Hz, and the difference shows over a minute.** A DMG
/// frame is 70224 T-cycles of a 4.194304 MHz clock — 59.7275 frames a second,
/// so thirty seconds of frames is 30.14 seconds of Game Boy. The SNES runs
/// 60.0988. A check that called either of them sixty would fail every correct
/// render, and did.
pub fn wantSeconds(side: Side, frames: usize) f64 {
    const n: f64 = @floatFromInt(frames);
    return switch (side) {
        .gb => n * @as(f64, @floatFromInt(gb_frame_cycles)) / gb_clock_hz,
        .snes => n / snes_frame_hz,
    };
}

/// Is a render as long as its own machine says it should be?
///
/// Not exactly equal, and differently so on each side. SameBoy resamples to
/// whatever rate it is asked for, which lands within a sample or two of the
/// span it was advanced. `spcrun` runs whole 8 ms buffers and keeps going for
/// the frames it takes to drain the last message, so it ends a little long and
/// never short. Outside these and a render stopped early or ran at the wrong
/// rate, which is the thing worth catching.
pub fn lengthOk(side: Side, m: Measured, frames: usize) bool {
    const want = wantSeconds(side, frames);
    return switch (side) {
        .gb => @abs(m.seconds - want) <= 0.05,
        // The overshoot is the drain, not a proportion of the run: the buffer
        // it ended inside (8 ms) and the two or three frames the last message
        // took to come back. Measured between 0.04 s and 0.07 s across renders
        // from two seconds to thirty.
        .snes => m.seconds >= want - 0.05 and m.seconds <= want + 0.12,
    };
}

// ---- Tests -----------------------------------------------------------------
//
// The renders themselves need the ROM, SameBoy and `spcrun`, and are checked by
// the tool's own run (`zig build audioab`). What is here needs none of them.

const testing = std.testing;

test "a song's script is the request and then its seconds of ticks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try scriptText(arena, .{ .request = .{ .song = 0x04 }, .seconds = 2 });
    var line: usize = 0;
    var what: []const u8 = "";
    const script = try audio_req.parse(arena, text, &line, &what);
    try testing.expectEqual(@as(usize, 120), script.ticks());
    try testing.expect(std.mem.indexOf(u8, text, "[songRequest=04]") != null);
}

test "an effect over a song is requested after the song, and both are in the script" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ask: Ask = .{
        .request = .{ .sfx = .{ .channel = .noise, .id = 0x0B } },
        .over = 0x04,
        .seconds = 4,
    };
    const text = try scriptText(arena, ask);
    var line: usize = 0;
    var what: []const u8 = "";
    const script = try audio_req.parse(arena, text, &line, &what);
    try testing.expectEqual(@as(usize, 240), script.ticks());

    const song_at = std.mem.indexOf(u8, text, "songRequest=04").?;
    const sfx_at = std.mem.indexOf(u8, text, "sfxRequest_noise=0B").?;
    try testing.expect(song_at < sfx_at);
    // The effect is asked for on tick 60, not on the song's own tick: sixty
    // ticks stand before the line it is requested on. Counted to the start of
    // that line, because the request itself sits partway into it.
    const line_at = std.mem.lastIndexOfScalar(u8, text[0..sfx_at], '\n').? + 1;
    var ticks: usize = 0;
    var it = std.mem.splitScalar(u8, text[0..line_at], '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, "[")) ticks += 1;
    }
    try testing.expectEqual(@as(usize, 60), ticks);
}

test "the two files of one ask sort next to each other" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("song-04", (Ask{ .request = .{ .song = 4 } }).stem(&buf));
    var buf2: [64]u8 = undefined;
    try testing.expectEqualStrings("sq1-1B", (Ask{
        .request = .{ .sfx = .{ .channel = .sq1, .id = 0x1B } },
    }).stem(&buf2));
    var buf3: [64]u8 = undefined;
    try testing.expectEqualStrings("noise-0B-over-04", (Ask{
        .request = .{ .sfx = .{ .channel = .noise, .id = 0x0B } },
        .over = 4,
    }).stem(&buf3));
    // `.gb` before `.snes` in every listing that sorts, which is what makes
    // them adjacent.
    try testing.expect(std.mem.order(u8, "song-04.gb.wav", "song-04.snes.wav") == .lt);
}

test "silence and length are judged by what came out" {
    const quiet = [_]i16{0} ** 64;
    try testing.expect(measure(&quiet, 32000).silent());

    var loud: [64]i16 = @splat(0);
    loud[7] = 9000;
    try testing.expect(!measure(&loud, 32000).silent());

    // 32 stereo frames at 32 Hz is one second.
    const one_second = measure(&([_]i16{1000} ** 64), 32);
    try testing.expectEqual(@as(usize, 32), one_second.frames);
}

test "a script's frame is a frame of the machine it ran on, and neither is 60 Hz" {
    // 1800 frames: 30.14 s on the Game Boy, 29.95 s on the SNES. Calling both
    // of them thirty seconds is what made the first whole set fail.
    try testing.expectApproxEqAbs(@as(f64, 30.137), wantSeconds(.gb, 1800), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 29.951), wantSeconds(.snes, 1800), 0.001);

    const gb: Measured = .{ .frames = 0, .seconds = 30.14, .peak = 1000 };
    try testing.expect(lengthOk(.gb, gb, 1800));
    // The same render judged by the other machine's clock is not close enough,
    // which is the point of asking per side.
    try testing.expect(!lengthOk(.snes, gb, 1800));

    // `spcrun` ends long, by the buffer it was in and the frames it took to
    // drain; short is a run that stopped.
    const long: Measured = .{ .frames = 0, .seconds = 30.05, .peak = 1000 };
    const short: Measured = .{ .frames = 0, .seconds = 29.5, .peak = 1000 };
    try testing.expect(lengthOk(.snes, long, 1800));
    try testing.expect(!lengthOk(.snes, short, 1800));
}
