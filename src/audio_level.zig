//! The level check (metroid2-0b Step 24f): is the cart as loud as the Game Boy?
//!
//! `audiocmp` grades the engine's register writes, and `audioab` leaves two WAVs
//! for a person. Neither says how *loud* the result is, and on 2026-09-22 James
//! found the cart "unbelievably loud": every sound in the slice measured 3.3-4.0x
//! the Game Boy's RMS (10.4-12.0 dB), one scale across songs and effects alike.
//! This is the number that was missing, held to a tolerance.
//!
//! ## The oracle
//!
//! SameBoy's APU, through `audioab_render.zig`, as everywhere else in the audio
//! work — the same writes `audiocmp` calls the reference, rendered by a core we
//! did not write. Its full scale is four channels at ±4080, so a Game Boy at
//! full volume peaks near 16 000 and not at the rail. The cart is the S-DSP's own
//! output from `spcrun`, which is what Mesen2 plays unscaled. Mesen2's own GB
//! core would put the Game Boy about 4.6 dB lower again (from its source; its
//! testrunner has no audio capture), and is not what this grades against.
//!
//! ## The measure
//!
//! Mean square over each whole file, both channels, compared as a ratio in dB.
//! The rates differ (44 100 and 32 000) and a mean does not care. RMS and not
//! peak, because the cart's peaks sat on the rail while the Game Boy's did not,
//! so a peak ratio would have read the clamp as well as the level.
//!
//! ## The tolerance
//!
//! Two, because the ratio is one scale with some spread around it. Before the
//! fix, the twenty sounds measured spread from −1.7 dB to +1.1 dB about their
//! mean (the eight below, ±0.3 dB): the S-DSP's interpolation and SameBoy's
//! band-limited steps do not treat every waveform alike, and a volume model
//! cannot remove that. So:
//!
//!   - the **set** — the mean of the cases' dB — within ±1 dB, which is the
//!     level James was listening to; and
//!   - **each case** within ±2 dB, so no one sound can hide a gross error
//!     behind the others.
//!
//! This file builds without SameBoy; what renders is `audio_level_run.zig`.

const std = @import("std");
const audioab = @import("audioab.zig");

pub const set_tolerance_db: f64 = 1.0;
pub const case_tolerance_db: f64 = 2.0;

/// One sound the slice plays. A generated ask, or a hand-written script from
/// `test/audio/` for the cases with no id of their own.
pub const Case = struct {
    name: []const u8,
    what: union(enum) {
        ask: audioab.Ask,
        script: []const u8,
    },
};

/// Step 24f's list: the title, the room song, the Metroid music and its kill,
/// the item jingle, the two shots over the room song, and Samus killed. Short
/// windows, because the question is a level and not a whole song, and every
/// second here is about a second of gate.
pub const cases = [_]Case{
    .{ .name = "title", .what = .{ .ask = .{ .request = .{ .song = 0x11 }, .seconds = 8 } } },
    .{ .name = "main caves", .what = .{ .ask = .{ .request = .{ .song = 0x04 }, .seconds = 8 } } },
    .{ .name = "Metroid battle", .what = .{ .ask = .{ .request = .{ .song = 0x0C }, .seconds = 8 } } },
    .{ .name = "Metroid killed", .what = .{ .ask = .{ .request = .{ .song = 0x0F }, .seconds = 8 } } },
    .{ .name = "item jingle", .what = .{ .script = "test/audio/int-item-get.req" } },
    .{ .name = "beam over caves", .what = .{ .ask = .{ .request = .{ .sfx = .{ .channel = .sq1, .id = 0x07 } }, .over = 0x04, .seconds = 4 } } },
    .{ .name = "missile over caves", .what = .{ .ask = .{ .request = .{ .sfx = .{ .channel = .sq1, .id = 0x08 } }, .over = 0x04, .seconds = 4 } } },
    .{ .name = "Samus killed", .what = .{ .ask = .{ .request = .{ .sfx = .{ .channel = .noise, .id = 0x0B } }, .seconds = 3 } } },
};

/// Mean square of interleaved samples, in units of a sample squared.
pub fn meanSquare(samples: []const i16) f64 {
    if (samples.len == 0) return 0;
    var sum: f64 = 0;
    for (samples) |v| {
        const x: f64 = @floatFromInt(v);
        sum += x * x;
    }
    return sum / @as(f64, @floatFromInt(samples.len));
}

/// What one case measured on each side.
pub const Measured = struct {
    gb_ms: f64,
    snes_ms: f64,

    pub fn gbRms(self: Measured) f64 {
        return @sqrt(self.gb_ms);
    }
    pub fn snesRms(self: Measured) f64 {
        return @sqrt(self.snes_ms);
    }
    /// The cart against the Game Boy, in dB. Positive is louder.
    pub fn db(self: Measured) f64 {
        return 10 * std.math.log10(self.snes_ms / self.gb_ms);
    }
};

pub const Verdict = struct {
    set_db: f64,
    /// The case farthest from the Game Boy's level, either way.
    worst_index: usize,
    worst_db: f64,
    set_ok: bool,
    cases_ok: bool,

    pub fn ok(self: Verdict) bool {
        return self.set_ok and self.cases_ok;
    }
};

/// Grade a set. A side that rendered silence has no level to compare, and says
/// so as an error rather than a ratio of infinity.
pub fn grade(ms: []const Measured) error{ Empty, Silent }!Verdict {
    if (ms.len == 0) return error.Empty;
    var sum: f64 = 0;
    var worst_index: usize = 0;
    var worst_db: f64 = 0;
    for (ms, 0..) |m, i| {
        if (m.gb_ms == 0 or m.snes_ms == 0) return error.Silent;
        const d = m.db();
        sum += d;
        if (i == 0 or @abs(d) > @abs(worst_db)) {
            worst_index = i;
            worst_db = d;
        }
    }
    const set_db = sum / @as(f64, @floatFromInt(ms.len));
    return .{
        .set_db = set_db,
        .worst_index = worst_index,
        .worst_db = worst_db,
        .set_ok = @abs(set_db) <= set_tolerance_db,
        .cases_ok = @abs(worst_db) <= case_tolerance_db,
    };
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

fn fromRatio(r: f64) Measured {
    // A Game Boy side of 1000 RMS and the cart at `r` times it.
    return .{ .gb_ms = 1000 * 1000, .snes_ms = (1000 * r) * (1000 * r) };
}

test "the level before Step 24f fails, on the set and on every case" {
    // The 2026-09-22 renders' ratios, cart ÷ SameBoy RMS, over the cases above.
    const before = [_]Measured{
        fromRatio(3.67), fromRatio(3.44), fromRatio(3.43), fromRatio(3.50),
        fromRatio(3.63), fromRatio(3.51), fromRatio(3.52), fromRatio(3.66),
    };
    const v = try grade(&before);
    try testing.expect(!v.ok());
    try testing.expect(!v.set_ok);
    try testing.expect(!v.cases_ok);
    try testing.expectApproxEqAbs(@as(f64, 10.99), v.set_db, 0.05);
}

test "that same spread about the Game Boy's level passes" {
    // The before ratios divided by their geometric mean: the spread the
    // tolerance was written for, centred.
    const r = [_]f64{ 3.67, 3.44, 3.43, 3.50, 3.63, 3.51, 3.52, 3.66 };
    var log_sum: f64 = 0;
    for (r) |x| log_sum += @log(x);
    const g = @exp(log_sum / r.len);
    var ms: [r.len]Measured = undefined;
    for (r, 0..) |x, i| ms[i] = fromRatio(x / g);
    const v = try grade(&ms);
    try testing.expect(v.ok());
    try testing.expectApproxEqAbs(@as(f64, 0), v.set_db, 1e-9);
}

test "one sound far off fails even when the set's mean is inside" {
    var ms = [_]Measured{fromRatio(1.0)} ** 8;
    ms[5] = fromRatio(1.5); // +3.5 dB
    const v = try grade(&ms);
    try testing.expect(v.set_ok);
    try testing.expect(!v.cases_ok);
    try testing.expectEqual(@as(usize, 5), v.worst_index);
}

test "too quiet fails as surely as too loud" {
    const ms = [_]Measured{fromRatio(0.8)} ** 8; // -1.9 dB
    const v = try grade(&ms);
    try testing.expect(!v.set_ok);
    try testing.expect(v.cases_ok);
}

test "a silent side is an error, not a ratio" {
    const ms = [_]Measured{ fromRatio(1.0), .{ .gb_ms = 1, .snes_ms = 0 } };
    try testing.expectError(error.Silent, grade(&ms));
}

test "mean square" {
    try testing.expectEqual(@as(f64, 0), meanSquare(&.{}));
    try testing.expectEqual(@as(f64, 25), meanSquare(&.{ 5, -5, 5, -5 }));
}

test "every case names something to render" {
    for (cases) |c| switch (c.what) {
        .ask => |a| try testing.expect(a.seconds > 0),
        .script => |p| try testing.expect(std.mem.endsWith(u8, p, ".req")),
    };
}
