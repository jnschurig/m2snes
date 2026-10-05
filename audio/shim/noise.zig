//! CH4's seven-bit noise as BRR, and the DSP noise clock nearest each NR43
//! rate for fifteen-bit noise: what the image supplies for the shim's CH4.
//!
//! **This file imports nothing but `std`,** because it ships in the shim
//! package beside `wave.zig`: m2snes's image builder places the same samples
//! and table the benches here do. `gbapu.zig`'s tests hold its constants to
//! `memmap.inc`.
//!
//! ## Fifteen bits: the DSP's generator
//!
//! The S-DSP's noise generator is a fifteen-bit LFSR with the Game Boy's taps,
//! at 31 rates, `32000 / n` Hz for a fixed list of `n`. The table here is the
//! rate nearest each NR43 rate by ratio, for the fourteen shifts that clock.
//! Above 32 kHz every NR43 rate is the fastest the DSP has.
//!
//! ## Seven bits: a sample
//!
//! The DSP has no seven-bit mode, and seven-bit noise is a tone: 127 steps
//! that repeat. The Game Boy's LFSR shifts right and puts bit 0 XOR bit 1 into
//! bit 14, and in seven-bit mode into bit 6 as well; the channel outputs its
//! volume while bit 0 is clear. A trigger sets every bit, so a note's noise is
//! the same sequence every time, and a keyed-on sample started from that state
//! reproduces it step for step.
//!
//! 127 is not a whole number of 16-sample blocks, so every sample is 2032
//! samples, looped whole: sixteen periods at one sample a step, four at four,
//! one at sixteen. **Why more than one sample a step:** the DSP's Gaussian
//! interpolation blends each output from four neighbouring samples, so at one
//! a step the Game Boy's square edges are rounded away and the noise sounds
//! muffled (by ear, and 0.6% of the energy above 500 Hz where the Game Boy has
//! 25%). At sixteen, only the edges are blended. The shim plays the most
//! samples a step fourteen bits of `PITCH` reach (see `noise_rate`); above
//! what one reaches it plays eight steps a sample, which is sound because the
//! sequence is maximal-length: every eighth step of it is the same sequence
//! from another starting point. Asserted below.
//!
//! Levels are the square bank's 50% duty, +4 and -4 nibble units at shift 12,
//! so noise at an envelope swings as far as a pulse channel at the same one.

const std = @import("std");

// ---- The Game Boy's LFSR ---------------------------------------------------

/// What a trigger leaves in the LFSR.
pub const lfsr_reset: u15 = 0x7fff;

/// One clock of the LFSR.
pub fn step(lfsr: u15, width7: bool) u15 {
    const x: u15 = (lfsr ^ (lfsr >> 1)) & 1;
    var next = (lfsr >> 1) | (x << 14);
    if (width7) next = (next & ~@as(u15, 1 << 6)) | (x << 6);
    return next;
}

/// The channel's output at this state: high while bit 0 is clear.
pub fn high(lfsr: u15) bool {
    return lfsr & 1 == 0;
}

pub const period15: usize = 32767;
pub const period7: usize = 127;

/// Samples in each seven-bit sample, before its loop.
pub const samples7: usize = period7 * 16;

/// Samples a step in each, in source-number order.
pub const oversample = [_]usize{ 1, 4, 16 };

// ---- BRR -------------------------------------------------------------------

pub const block_bytes: usize = 9;
pub const block_samples: usize = 16;
pub const shift: u8 = 12;
pub const flag_loop: u8 = 0x02;
pub const flag_end: u8 = 0x01;
pub const level_hi: i8 = 4;
pub const level_lo: i8 = -4;

comptime {
    std.debug.assert(samples7 % block_samples == 0);
    for (oversample) |n| std.debug.assert(samples7 % (period7 * n) == 0);
}

pub const bytes7: usize = samples7 / block_samples * block_bytes;

/// The samples, in the order of their source numbers.
pub const samples_per: usize = oversample.len;
pub const bytes: usize = bytes7 * samples_per;

/// Offset of sample `tier` (an index into `oversample`) within `encode`'s output.
pub fn sampleOffset(tier: usize) usize {
    return bytes7 * tier;
}

fn encodeOne(out: []u8, per_step: usize) void {
    var lfsr = lfsr_reset;
    var at: usize = 0;
    var n: usize = 0; // samples of this step so far
    const blocks = samples7 / block_samples;
    for (0..blocks) |b| {
        const last = b == blocks - 1;
        out[at] = (shift << 4) | (if (last) flag_loop | flag_end else 0);
        at += 1;
        for (0..block_samples / 2) |_| {
            var pair: u8 = 0;
            for (0..2) |_| {
                const v: i8 = if (high(lfsr)) level_hi else level_lo;
                pair = (pair << 4) | @as(u8, @as(u4, @bitCast(@as(i4, @intCast(v)))));
                n += 1;
                if (n == per_step) {
                    n = 0;
                    lfsr = step(lfsr, true);
                }
            }
            out[at] = pair;
            at += 1;
        }
    }
}

/// The samples, back to back. Each loops to its own start.
pub fn encode() [bytes]u8 {
    @setEvalBranchQuota(1_000_000);
    var out: [bytes]u8 = undefined;
    for (oversample, 0..) |n, t| encodeOne(out[sampleOffset(t)..][0..bytes7], n);
    return out;
}

/// ARAM address of a sample, with all placed from `base`. A directory entry's
/// start and loop are both this.
pub fn sampleAddr(base: u16, tier: usize) u16 {
    return @intCast(base + sampleOffset(tier));
}

// ---- The DSP's noise clock -------------------------------------------------

/// `FLG`'s noise clock: rate `n` is `32000 / periods[n]` Hz, and 0 is stopped.
pub const periods = [32]u16{
    0,   2048, 1536, 1280, 1024, 768, 640, 512,
    384, 320,  256,  192,  160,  128, 96,  80,
    64,  48,   40,   32,   24,   20,  16,  12,
    10,  8,    6,    5,    4,    3,   2,   1,
};

/// Shifts 14 and 15 do not clock the LFSR.
pub const clocked_shifts: usize = 14;
pub const nck_entries: usize = clocked_shifts * 8;

/// NR43's step rate in Hz, times `r2 x 2^s`: `2^19`.
pub const rate_numerator: u64 = 1 << 19;

/// `r2` for a divisor code: twice the code, or 1 for code 0.
pub fn r2(divisor: u3) u64 {
    return if (divisor == 0) 1 else 2 * @as(u64, divisor);
}

/// The DSP rate nearest `2^19 / (r2 x 2^s)` Hz by ratio. Ties go to the faster.
pub fn nckFor(s: u4, divisor: u3) u5 {
    // Compared as products, not quotients: rate_n / f against f / rate_m is
    // `32000 x r2 x 2^s x ...`, all integers.
    const den: u128 = @as(u128, r2(divisor)) << s; // f = 2^19 / den
    var best: u5 = 31;
    var best_num: u128 = 0; // distance as the ratio best_num / best_den >= 1
    var best_den: u128 = 1;
    for (1..32) |n| {
        // rate = 32000 / p, f = 2^19 / den. ratio = max(rate/f, f/rate).
        const a: u128 = 32000 * den; // rate / f = a / b
        const b: u128 = @as(u128, periods[n]) * rate_numerator;
        const num = @max(a, b);
        const dn = @min(a, b);
        if (n == 1 or num * best_den < best_num * dn or
            (num * best_den == best_num * dn and n > best))
        {
            best = @intCast(n);
            best_num = num;
            best_den = dn;
        }
    }
    return best;
}

/// The table the shim reads at `(shift << 3) | divisor`, padded to its region.
pub fn nckTable(comptime size: usize) [size]u8 {
    @setEvalBranchQuota(100_000);
    var out: [size]u8 = @splat(0);
    for (0..clocked_shifts) |s| for (0..8) |d| {
        out[s * 8 + d] = nckFor(@intCast(s), @intCast(d));
    };
    return out;
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

fn sequence(gpa: std.mem.Allocator, width7: bool, n: usize) ![]bool {
    const out = try gpa.alloc(bool, n);
    var lfsr = lfsr_reset;
    for (out) |*o| {
        o.* = high(lfsr);
        lfsr = step(lfsr, width7);
    }
    return out;
}

test "both widths repeat at their published periods" {
    const s7 = try sequence(testing.allocator, true, period7 * 3);
    defer testing.allocator.free(s7);
    try testing.expectEqualSlices(bool, s7[0..period7], s7[period7 .. 2 * period7]);
    for (1..period7) |p| try testing.expect(!std.mem.eql(bool, s7[0..period7], s7[p .. p + period7]));

    const s15 = try sequence(testing.allocator, false, period15 * 2);
    defer testing.allocator.free(s15);
    try testing.expectEqualSlices(bool, s15[0..period15], s15[period15..]);
    // Not a shorter period: the first 64 steps occur nowhere else in one period.
    for (1..period15) |p| {
        if (std.mem.eql(bool, s15[0..64], s15[p..][0..64])) return error.ShorterPeriod;
    }
}

test "every eighth step is the same sequence from another point" {
    // What lets the shim play a sample at an eighth of a rate it cannot reach.
    const n = period7;
    const s = try sequence(testing.allocator, true, n * 9);
    defer testing.allocator.free(s);
    const dec = try testing.allocator.alloc(bool, n);
    defer testing.allocator.free(dec);
    for (dec, 0..) |*d, i| d.* = s[(8 * i) % n];
    const found = for (0..n) |k| {
        if (std.mem.eql(bool, dec, s[k..][0..n])) break true;
    } else false;
    try testing.expect(found);
}

test "the samples are the sequence from a trigger, each step repeated, at the square bank's levels" {
    const enc = encode();
    const s = try sequence(testing.allocator, true, samples7);
    defer testing.allocator.free(s);
    for (oversample, 0..) |per_step, t| {
        const base = sampleOffset(t);
        const blocks = samples7 / block_samples;
        for (0..blocks) |b| {
            const h = enc[base + b * block_bytes];
            try testing.expectEqual(shift, h >> 4);
            try testing.expectEqual(@as(u8, 0), (h >> 2) & 3);
            const last = b == blocks - 1;
            try testing.expectEqual(last, h & flag_end != 0);
            try testing.expectEqual(last, h & flag_loop != 0);
            for (0..block_samples) |i| {
                const byte = enc[base + b * block_bytes + 1 + i / 2];
                const nib: u4 = @truncate(if (i % 2 == 0) byte >> 4 else byte);
                const at = b * block_samples + i;
                const want: i8 = if (s[at / per_step]) level_hi else level_lo;
                try testing.expectEqual(want, @as(i8, @as(i4, @bitCast(nib))));
            }
        }
        // Whole periods, so the loop re-enters in phase.
        try testing.expectEqual(@as(usize, 0), (samples7 / per_step) % period7);
    }
}

test "the noise clock is the nearest the DSP has, by ratio" {
    // Rates worked by hand. Shift 0, divisor 0 is 524288 Hz: the fastest
    // there is. 32768 Hz (shift 4) is nearest 32000. 1024 Hz is nearest 1000
    // (rate 19). 5461 Hz (NR43 $4b's 7-bit rate, divisor 3 at shift 4) sits
    // between 5333 and 6400, and is nearer 5333 (rate 26).
    try testing.expectEqual(@as(u5, 31), nckFor(0, 0));
    try testing.expectEqual(@as(u5, 31), nckFor(4, 0));
    try testing.expectEqual(@as(u5, 19), nckFor(9, 0));
    try testing.expectEqual(@as(u5, 26), nckFor(4, 3));
    // And it never gets faster as NR43 gets slower.
    for (0..8) |d| {
        var last: u5 = 31;
        for (0..clocked_shifts) |s| {
            const n = nckFor(@intCast(s), @intCast(d));
            try testing.expect(n <= last);
            last = n;
        }
    }
    const t = nckTable(128);
    try testing.expectEqual(@as(u8, 26), t[4 * 8 + 3]);
    try testing.expectEqual(@as(u8, 0), t[nck_entries]);
}
