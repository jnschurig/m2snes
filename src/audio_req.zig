//! Request scripts: the one file both sides of the comparison are driven from.
//!
//! Grading the ported sound engine means running the *same* input through the
//! Game Boy's engine and the SPC700's and comparing what they write. The input
//! is what the game asked for, per `handleAudio` call: a song, a sound effect, a
//! pause, or the one engine variable the game sets directly. A `.req` script
//! states that, and this module compiles it two ways — into Game Boy WRAM
//! writes for `handleAudio`, and into port records for `spcrun` — so neither
//! side can be fed something the other was not.
//!
//! ## The format
//!
//! One line per frame, mirroring `spcrun`'s own script shape so there is one
//! mental model rather than two. Each tick in the frame is a bracketed record of
//! `name=value` ops, `-` is a frame in which the game called `handleAudio` no
//! times, `#` starts a comment, and a blank line is not a frame.
//!
//!     # thirty seconds of the surface theme
//!     [songRequest=04]        # frame 0: one tick, asking for song $04
//!     []                      # a tick with nothing in force
//!     [] [sfxRequest_noise=02]  # two ticks: the game ran the engine twice
//!     -                       # a frame with no tick at all
//!
//! Values are hex, names are M2RoS's own names for the WRAM bytes. A name is
//! required rather than an address, because an address in a test script is a
//! fact about the Game Boy that the SPC700 side does not share.
//!
//! ## Why a tick and not a frame
//!
//! `handleAudio` runs from `waitOneFrame`, not from VBlank, and also from the
//! game's wait loops — so a frame can contain zero calls or several. The engine
//! advances once per *call*, so a script that said "frame" would be unable to
//! express the cases that actually break lockstep. See `02-plan.md`'s first
//! surveyed fact.

const std = @import("std");
const audio_shim = @import("audio_shim.zig");

// ---- The slots -------------------------------------------------------------

pub const Kind = enum {
    /// A byte the game writes to ask the engine for something.
    request,
    /// An engine variable the game writes directly. The protocol needs this as
    /// its own kind: it is not a request, and the engine must not treat it as
    /// one. M2RoS `bank_001.asm:4057`.
    set,
    /// Game state the engine reads and the game owns: bytes outside audio RAM
    /// that the Game Boy engine reads straight out of WRAM. Samus's pose and
    /// items, for `maybeResumeScrewAttackingSfx` (M2RoS bank_004.asm:3528).
    game,
    /// The Game Boy's divider, `rDIV` ($FF04), which is a register and not
    /// WRAM. Five cries seed their pitch from it: square 1's $1B and square 2's
    /// $03-$06, which noise $05, $09, $0A, $16 and $17 request in turn. The
    /// harness cannot write DIV (a write resets it), so it pins what a read
    /// returns (`Bus.div_pin`); the engine reads the same byte from the record.
    /// Like `game`, it holds until a script sets it again, and it is 0 on both
    /// sides until then.
    divider,
    /// A bank-4 routine the game calls outside `handleAudio`: `silenceAudio`,
    /// at a death, the boot and two unused game modes. Not a byte at all. It
    /// runs where the op stands in the record, so an op before it is cleared by
    /// it and an op after it survives, as on the Game Boy, and its register
    /// writes are that tick's. The value is not read.
    call,
};

pub const Slot = struct {
    /// M2RoS's name for the byte, and what a script writes.
    name: []const u8,
    /// The equate in `engine/audio/main.asm` that fixes this slot's number.
    equate: []const u8,
    /// Where the byte lives in Game Boy WRAM, from M2RoS `ram/wram.asm`; for
    /// the `divider` slot, the register's address, and for a `call`, its
    /// bank-4 trampoline.
    wram: u16,
    kind: Kind,
};

/// The slots, indexed by slot number. The order is the WRAM order of the bytes,
/// and `checkAgainstEngine` is what holds it to the engine's own equates.
pub const slots = [_]Slot{
    .{ .name = "sfxRequest_square1", .equate = "REQ_SFX_SQUARE1", .wram = 0xCEC0, .kind = .request },
    .{ .name = "sfxRequest_square2", .equate = "REQ_SFX_SQUARE2", .wram = 0xCEC7, .kind = .request },
    .{ .name = "sfxRequest_fakeWave", .equate = "REQ_SFX_FAKE_WAVE", .wram = 0xCECE, .kind = .request },
    .{ .name = "sfxRequest_noise", .equate = "REQ_SFX_NOISE", .wram = 0xCED5, .kind = .request },
    .{ .name = "songRequest", .equate = "REQ_SONG", .wram = 0xCEDC, .kind = .request },
    .{ .name = "songInterruptionRequest", .equate = "REQ_SONG_INTERRUPTION", .wram = 0xCEDE, .kind = .request },
    .{ .name = "songInterruptionPlaying", .equate = "REQ_SET_SONG_INT_PLAYING", .wram = 0xCEDF, .kind = .set },
    .{ .name = "audioPauseControl", .equate = "REQ_PAUSE_CONTROL", .wram = 0xCFC7, .kind = .request },
    .{ .name = "sfxRequest_wave", .equate = "REQ_SFX_WAVE", .wram = 0xCFE5, .kind = .request },
    .{ .name = "samusPose", .equate = "REQ_SAMUS_POSE", .wram = 0xD020, .kind = .game },
    .{ .name = "samusItems", .equate = "REQ_SAMUS_ITEMS", .wram = 0xD045, .kind = .game },
    .{ .name = "rDIV", .equate = "REQ_DIV", .wram = 0xFF04, .kind = .divider },
    .{ .name = "silenceAudio", .equate = "REQ_CALL_SILENCE_AUDIO", .wram = 0x4003, .kind = .call },
};

pub fn slotByName(name: []const u8) ?u8 {
    for (slots, 0..) |s, i| {
        if (std.mem.eql(u8, s.name, name)) return @intCast(i);
    }
    return null;
}

/// The five engine variables the game reads back, in the order
/// `engine/audio/main.asm` lays out the reply. `checkAgainstEngine` holds this
/// order to that file too, because a reply read in the wrong order would
/// compare five bytes that all happen to be zero most of the time.
pub const read_back = [_]struct { name: []const u8, equate: []const u8, wram: u16 }{
    .{ .name = "songPlaying", .equate = "REPLY_SONG_PLAYING", .wram = 0xCEDD },
    .{ .name = "sfxPlaying_square1", .equate = "REPLY_SFX_SQUARE1_PLAYING", .wram = 0xCEC1 },
    .{ .name = "sfxPlaying_noise", .equate = "REPLY_SFX_NOISE_PLAYING", .wram = 0xCED6 },
    .{ .name = "sfxPlaying_lowHealthBeep", .equate = "REPLY_LOW_HEALTH_BEEP", .wram = 0xCFE6 },
    .{ .name = "songInterruptionPlaying", .equate = "REPLY_SONG_INTERRUPTION", .wram = 0xCEDF },
};

/// A slot number or reply offset this module and the engine disagree about.
pub const Drift = struct {
    what: []const u8,
    expected: u32,
    found: ?u32,
};

/// Every slot number and reply offset, checked against the engine's source.
///
/// Returns the drifts, empty when they agree, or null when the source is not
/// there to read. This is the same discipline as `audio_shim.engineExpectedAbi`:
/// one statement, read by whoever needs it, rather than a copy that can rot.
pub fn checkAgainstEngine(arena: std.mem.Allocator, io: std.Io) !?[]Drift {
    const src = std.Io.Dir.cwd().readFileAlloc(
        io,
        "engine/audio/main.asm",
        arena,
        .limited(4 * 1024 * 1024),
    ) catch return null;

    var out: std.ArrayList(Drift) = .empty;
    for (slots, 0..) |s, i| {
        const found = audio_shim.incValue(src, s.equate);
        if (found == null or found.? != i) {
            try out.append(arena, .{ .what = s.equate, .expected = @intCast(i), .found = found });
        }
    }
    const count = audio_shim.incValue(src, "REQ_SLOT_COUNT");
    if (count == null or count.? != slots.len) {
        try out.append(arena, .{ .what = "REQ_SLOT_COUNT", .expected = slots.len, .found = count });
    }
    for (read_back, 0..) |r, i| {
        const found = replyOffset(src, r.equate);
        if (found == null or found.? != i) {
            try out.append(arena, .{ .what = r.equate, .expected = @intCast(i), .found = found });
        }
    }

    // And the cart's side (metroid2-audio Step 16a): `engine/main.asm` writes
    // the records, so it states the slot numbers too, as `!REQ_*` defines of
    // the same names. Its copy is held here rather than trusted.
    const cart = std.Io.Dir.cwd().readFileAlloc(io, "engine/main.asm", arena, .limited(8 * 1024 * 1024)) catch return null;
    for (slots, 0..) |s, i| {
        const name = try std.mem.concat(arena, u8, &.{ "!", s.equate });
        const found = audio_shim.incValue(cart, name);
        if (found == null or found.? != i) {
            try out.append(arena, .{ .what = name, .expected = @intCast(i), .found = found });
        }
    }
    return try out.toOwnedSlice(arena);
}

/// `NAME = ENGINE_REPLY_ADDR + <n>` out of the engine's source.
///
/// Its own parser rather than `incValue`'s, because the value is an expression
/// and not a number: what matters is the offset, which is the only part of it
/// this module has an opinion about.
fn replyOffset(text: []const u8, name: []const u8) ?u32 {
    const base = "ENGINE_REPLY_ADDR";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, name)) continue;
        const after = std.mem.trim(u8, line[name.len..], " \t");
        if (after.len == 0 or after[0] != '=') continue;
        var expr = std.mem.trim(u8, after[1..], " \t");
        if (std.mem.indexOfScalar(u8, expr, ';')) |i| expr = std.mem.trim(u8, expr[0..i], " \t");
        if (!std.mem.startsWith(u8, expr, base)) return null;
        const rest = std.mem.trim(u8, expr[base.len..], " \t");
        if (rest.len == 0 or rest[0] != '+') return null;
        return std.fmt.parseInt(u32, std.mem.trim(u8, rest[1..], " \t"), 10) catch null;
    }
    return null;
}

// ---- The script ------------------------------------------------------------

pub const Op = struct { slot: u8, value: u8 };

/// The ops in force at one `handleAudio` call.
pub const Tick = []const Op;

/// The ticks the game ran in one frame. Empty is a frame with no call.
pub const Frame = []const Tick;

pub const Script = struct {
    frames: []const Frame,

    pub fn ticks(self: Script) usize {
        var n: usize = 0;
        for (self.frames) |f| n += f.len;
        return n;
    }
};

pub const ParseError = error{
    /// A record did not open with `[` or never closed.
    BadRecord,
    /// An op was not `name=value`.
    BadOp,
    /// The name is not one of `slots`.
    UnknownSlot,
    /// The value is not a hex byte.
    BadValue,
    OutOfMemory,
};

/// Parse a script. Everything is allocated in `arena`. On an error `line` is the
/// 1-based line it was found on, and `what` the token that caused it.
pub fn parse(arena: std.mem.Allocator, text: []const u8, line: *usize, what: *[]const u8) ParseError!Script {
    var frames: std.ArrayList(Frame) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    line.* = 0;
    what.* = "";
    while (lines.next()) |raw| {
        line.* += 1;
        const src = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (src.len == 0) continue;
        if (std.mem.eql(u8, src, "-")) {
            try frames.append(arena, &.{});
            continue;
        }

        var ticks: std.ArrayList(Tick) = .empty;
        var rest = src;
        while (true) {
            rest = std.mem.trimStart(u8, rest, " \t");
            if (rest.len == 0) break;
            if (rest[0] != '[') {
                what.* = rest;
                return error.BadRecord;
            }
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse {
                what.* = rest;
                return error.BadRecord;
            };
            var ops: std.ArrayList(Op) = .empty;
            var it = std.mem.tokenizeAny(u8, rest[1..close], " \t");
            while (it.next()) |tok| {
                const eq = std.mem.indexOfScalar(u8, tok, '=') orelse {
                    what.* = tok;
                    return error.BadOp;
                };
                const slot = slotByName(tok[0..eq]) orelse {
                    what.* = tok[0..eq];
                    return error.UnknownSlot;
                };
                const v = std.fmt.parseInt(u8, tok[eq + 1 ..], 16) catch {
                    what.* = tok[eq + 1 ..];
                    return error.BadValue;
                };
                try ops.append(arena, .{ .slot = slot, .value = v });
            }
            try ticks.append(arena, ops.items);
            rest = rest[close + 1 ..];
        }
        try frames.append(arena, ticks.items);
    }
    return .{ .frames = frames.items };
}

// ---- Compiling it for the SPC700 side --------------------------------------

/// One tick's record: `(slot, value)` pairs, which is what the engine reads.
pub fn record(arena: std.mem.Allocator, tick: Tick) ![]u8 {
    const out = try arena.alloc(u8, tick.len * 2);
    for (tick, 0..) |op, i| {
        out[i * 2] = op.slot;
        out[i * 2 + 1] = op.value;
    }
    return out;
}

/// The script as `spcrun`'s own script text: one line a frame, bracketed hex
/// records, `-` for a lag frame.
///
/// Text rather than bytes because `spcrun` is a vendored binary that takes a
/// file — going through its own format means the harness drives it exactly as a
/// human would, and a script that reproduced a divergence can be replayed by
/// hand.
pub fn writeSpcrunScript(script: Script, out: *std.Io.Writer) !void {
    try out.print("# generated by audiocmp from a .req script; do not edit\n", .{});
    for (script.frames) |frame| {
        if (frame.len == 0) {
            try out.print("-\n", .{});
            continue;
        }
        for (frame, 0..) |tick, i| {
            if (i != 0) try out.print(" ", .{});
            try out.print("[", .{});
            for (tick, 0..) |op, j| {
                if (j != 0) try out.print(" ", .{});
                try out.print("{x:0>2} {x:0>2}", .{ op.slot, op.value });
            }
            try out.print("]", .{});
        }
        try out.print("\n", .{});
    }
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

test "every slot has a distinct name, equate and WRAM address" {
    for (slots, 0..) |a, i| {
        try testing.expect(a.name.len != 0 and a.equate.len != 0);
        for (slots[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.name, b.name));
            try testing.expect(!std.mem.eql(u8, a.equate, b.equate));
            try testing.expect(a.wram != b.wram);
        }
    }
    // Exactly one set-variable op, which is the surveyed fact this kind exists
    // for. A second one arriving should be a deliberate change, not a surprise.
    var sets: usize = 0;
    for (slots) |s| {
        if (s.kind == .set) sets += 1;
    }
    try testing.expectEqual(@as(usize, 1), sets);
}

test "one divider slot, and it is the Game Boy's DIV register" {
    // `audiocmp.runGb` pins DIV for this slot instead of writing it, because a
    // write to $FF04 resets the divider rather than setting it.
    var n: usize = 0;
    for (slots) |s| {
        if (s.kind == .divider) {
            n += 1;
            try testing.expectEqual(@as(u16, 0xFF04), s.wram);
        }
    }
    try testing.expectEqual(@as(usize, 1), n);
}

test "one call slot, and it is the silence trampoline audiocmp calls" {
    var n: usize = 0;
    for (slots) |s| {
        if (s.kind == .call) {
            n += 1;
            try testing.expectEqual(@import("audiocost.zig").silence, s.wram);
        }
    }
    try testing.expectEqual(@as(usize, 1), n);
}

test "the set-variable slot and the read-back byte are the same WRAM address" {
    // `songInterruptionPlaying` is both written by the game and read by it,
    // which is exactly why it needs a set op as well as a reply byte.
    const slot = slots[slotByName("songInterruptionPlaying").?];
    try testing.expectEqual(Kind.set, slot.kind);
    try testing.expectEqual(slot.wram, read_back[4].wram);
}

test "a script is frames of bracketed ticks, with comments, blanks and lag frames" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var line: usize = 0;
    var what: []const u8 = "";
    const s = try parse(arena_state.allocator(),
        \\# a header
        \\[songRequest=04]
        \\
        \\[] [sfxRequest_noise=02 sfxRequest_square1=8]   # two ticks
        \\-
    , &line, &what);

    // Three frames, not four: the blank line between them is not one.
    try testing.expectEqual(@as(usize, 3), s.frames.len);
    try testing.expectEqual(@as(usize, 3), s.ticks());
    try testing.expectEqual(@as(usize, 1), s.frames[0].len);
    try testing.expectEqual(@as(u8, 4), s.frames[0][0][0].slot);
    try testing.expectEqual(@as(u8, 0x04), s.frames[0][0][0].value);
    // A blank line is not a frame, so the two-tick line is frame 1.
    try testing.expectEqual(@as(usize, 2), s.frames[1].len);
    try testing.expectEqual(@as(usize, 0), s.frames[1][0].len);
    try testing.expectEqual(@as(usize, 2), s.frames[1][1].len);
    try testing.expectEqual(@as(u8, 3), s.frames[1][1][0].slot);
    try testing.expectEqual(@as(u8, 0x02), s.frames[1][1][0].value);
    try testing.expectEqual(@as(u8, 0x08), s.frames[1][1][1].value);
    try testing.expectEqual(@as(usize, 0), s.frames[2].len); // the `-` lag frame
}

test "a bad script names the line and the token" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var line: usize = 0;
    var what: []const u8 = "";

    try testing.expectError(error.UnknownSlot, parse(a, "[]\n[songrequest=1]", &line, &what));
    try testing.expectEqual(@as(usize, 2), line);
    try testing.expectEqualStrings("songrequest", what);

    try testing.expectError(error.BadOp, parse(a, "[songRequest]", &line, &what));
    try testing.expectEqualStrings("songRequest", what);

    try testing.expectError(error.BadValue, parse(a, "[songRequest=zz]", &line, &what));
    try testing.expectEqualStrings("zz", what);

    try testing.expectError(error.BadRecord, parse(a, "songRequest=04", &line, &what));
    try testing.expectError(error.BadRecord, parse(a, "[songRequest=04", &line, &what));
}

test "a tick compiles to slot/value pairs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var line: usize = 0;
    var what: []const u8 = "";
    const s = try parse(a, "[songRequest=04 sfxRequest_noise=12]", &line, &what);
    const r = try record(a, s.frames[0][0]);
    try testing.expectEqualSlices(u8, &.{ 4, 0x04, 3, 0x12 }, r);
}

test "the spcrun script is the same frames, as spcrun's own format" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var line: usize = 0;
    var what: []const u8 = "";
    const s = try parse(a, "[songRequest=04] []\n-\n", &line, &what);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeSpcrunScript(s, &w);
    try testing.expectEqualStrings(
        \\# generated by audiocmp from a .req script; do not edit
        \\[04 04] []
        \\-
        \\
    , w.buffered());
}

test "replyOffset reads the offset out of the reply's expression form" {
    const text =
        \\    REPLY_SONG_PLAYING        = ENGINE_REPLY_ADDR + 0
        \\    REPLY_ALIVE               = ENGINE_REPLY_ADDR + 5 ; a comment
        \\    REPLY_ELSEWHERE           = $1234
    ;
    try testing.expectEqual(@as(?u32, 0), replyOffset(text, "REPLY_SONG_PLAYING"));
    try testing.expectEqual(@as(?u32, 5), replyOffset(text, "REPLY_ALIVE"));
    try testing.expectEqual(@as(?u32, null), replyOffset(text, "REPLY_ELSEWHERE"));
    try testing.expectEqual(@as(?u32, null), replyOffset(text, "REPLY_MISSING"));
}

test "the engine's source agrees about every slot number and reply offset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const drifts = try checkAgainstEngine(arena_state.allocator(), testing.io) orelse
        return error.SkipZigTest;
    if (drifts.len != 0) {
        for (drifts) |d| std.debug.print(
            "drift: {s} should be {d}, engine says {?d}\n",
            .{ d.what, d.expected, d.found },
        );
    }
    try testing.expectEqual(@as(usize, 0), drifts.len);
}
