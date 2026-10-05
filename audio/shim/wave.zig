//! CH3's waves as BRR: the encoder the shim's wave lookup is built from.
//!
//! CH3 plays 32 four-bit samples out of wave RAM, and the S-DSP plays BRR. The
//! shim does not encode on the SPC700. The image carries every wave a game
//! uses, encoded here at build time, and a table of their contents the shim
//! looks wave RAM up in at each trigger (see "The wave lookup" in
//! `gbapu/memmap.inc`).
//!
//! **This file imports nothing but `std`,** because it ships in the shim
//! package: m2snes encodes Metroid II's waves out of the user's ROM with it,
//! and the benches here encode whatever a log's wave RAM held. Two callers
//! and one encoder, so a wave cannot sound one way in a bench and another on
//! the cart. `gbapu.zig`'s tests hold its constants to `memmap.inc`.
//!
//! ## Three samples per wave, at twice the square bank's lengths
//!
//! 64, 32 and 16 samples per period, where the square bank has 32, 16 and 8.
//! CH3 plays its 32 samples at `65536 / (2048 - p)` Hz, which is half a pulse
//! channel's frequency for the same period register. A wave sample twice as
//! long therefore needs the same `PITCH` as a square sample half its length,
//! and the shim reads CH3's pitch and length index out of the square bank's
//! table unchanged. `samples.zig` states CH3's mapping on its own and asserts
//! that it agrees, entry by entry.
//!
//! - **64**: each of the 32 samples twice. The low end of the range, where 32
//!   samples a period would ask for less `PITCH` resolution than 64 does.
//! - **32**: wave RAM exactly.
//! - **16**: neighbouring pairs averaged, for the top of the range (periods
//!   2032-2039), where 32 samples a period no longer fits fourteen bits.
//!
//! ## Levels
//!
//! BRR filter 0, shift 11, so a nibble decodes to `n x 1024`. A Game Boy
//! sample is 0-15 and a nibble is -8..7, so each wave is moved down by an
//! offset before it is stored, chosen as close to its mean as the range
//! allows. The console's output capacitor removes a wave's DC, and the S-DSP
//! has none. A wave that uses all sixteen levels can only be offset by 8, and
//! keeps whatever DC is left over.
//!
//! At shift 11 a full-scale wave swings 15 x 1024 = 15360, and the square
//! bank's 16384 (8 nibble units at shift 12). So CH3 at full level is 15/16 of a
//! pulse channel at envelope 15, about 0.6 dB quieter. The mix decision in
//! Step 11 owns any per-voice scaling.

const std = @import("std");

/// Wave RAM is sixteen bytes, high nibble first.
pub const entry_size: usize = 16;
pub const Wave = [entry_size]u8;
pub const wave_samples: usize = entry_size * 2;

/// Samples per period, longest first, indexed by the pitch table's length index.
pub const lengths = [3]u32{ 64, 32, 16 };
pub const samples_per: usize = lengths.len;

pub const block_bytes: usize = 9;
pub const block_samples: usize = 16;
pub const shift: u8 = 11;
pub const flag_loop: u8 = 0x02;
pub const flag_end: u8 = 0x01;

pub fn blocksFor(n: u32) usize {
    return n / block_samples;
}

/// Where each length's sample starts within a wave's encoding, and its size.
pub fn sampleOffset(length_index: usize) usize {
    var at: usize = 0;
    for (lengths[0..length_index]) |n| at += blocksFor(n) * block_bytes;
    return at;
}

pub fn sampleLen(length_index: usize) usize {
    return blocksFor(lengths[length_index]) * block_bytes;
}

/// One wave's three samples, back to back: 36 + 18 + 9 bytes.
pub const bytes_per_wave: usize = blk: {
    var n: usize = 0;
    for (lengths) |len| n += blocksFor(len) * block_bytes;
    break :blk n;
};

/// The 32 samples in the order CH3 plays them.
pub fn levels(w: Wave) [wave_samples]u4 {
    var out: [wave_samples]u4 = undefined;
    for (w, 0..) |b, i| {
        out[i * 2] = @intCast(b >> 4);
        out[i * 2 + 1] = @intCast(b & 0x0f);
    }
    return out;
}

/// What is subtracted from each sample before it is stored: as close to the
/// wave's mean as keeps every sample inside a nibble's -8..7.
pub fn offset(w: Wave) u8 {
    const lv = levels(w);
    var lo: u8 = 15;
    var hi: u8 = 0;
    var sum: u32 = 0;
    for (lv) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
        sum += v;
    }
    const mean: u8 = @intCast((sum + wave_samples / 2) / wave_samples);
    const floor: u8 = if (hi > 7) hi - 7 else 0;
    return std.math.clamp(mean, floor, lo + 8);
}

/// Sample `i` of a period `n` samples long, before the offset.
fn sampleAt(lv: [wave_samples]u4, n: u32, i: usize) u8 {
    const k = i % n;
    return switch (n) {
        64 => lv[k / 2],
        32 => lv[k],
        // Round half up, so the average of two equal samples is that sample.
        16 => (@as(u8, lv[k * 2]) + lv[k * 2 + 1] + 1) / 2,
        else => unreachable,
    };
}

/// The BRR for one wave: its three samples, longest first, each a loop of one
/// period. Filter 0 refers to no earlier sample, so a loop re-enters cleanly.
pub fn encode(w: Wave) [bytes_per_wave]u8 {
    const lv = levels(w);
    const o = offset(w);
    var out: [bytes_per_wave]u8 = undefined;
    var at: usize = 0;
    for (lengths) |n| {
        const blocks = blocksFor(n);
        for (0..blocks) |b| {
            const last = b == blocks - 1;
            out[at] = (shift << 4) | (if (last) flag_loop | flag_end else 0);
            at += 1;
            for (0..block_samples / 2) |j| {
                const i = b * block_samples + j * 2;
                const hi: u8 = @bitCast(@as(i8, @intCast(@as(i16, sampleAt(lv, n, i)) - o)));
                const lo: u8 = @bitCast(@as(i8, @intCast(@as(i16, sampleAt(lv, n, i + 1)) - o)));
                out[at] = (hi << 4) | (lo & 0x0f);
                at += 1;
            }
        }
    }
    return out;
}

/// ARAM address of wave `i`'s sample for a length index, with the waves'
/// encodings placed back to back from `base`. A directory entry's start and
/// loop are both this: the loop is the whole period.
pub fn sampleAddr(base: u16, i: usize, length_index: usize) u16 {
    return @intCast(base + i * bytes_per_wave + sampleOffset(length_index));
}

pub const Error = error{ TooManyWaves, BufferTooSmall };

/// The wave lookup's bytes: a count, then each wave's contents in order.
pub fn lut(out: []u8, waves: []const Wave, max: usize) Error![]u8 {
    if (waves.len > max) return Error.TooManyWaves;
    const n = 1 + waves.len * entry_size;
    if (out.len < n) return Error.BufferTooSmall;
    out[0] = @intCast(waves.len);
    for (waves, 0..) |w, i| @memcpy(out[1 + i * entry_size ..][0..entry_size], &w);
    return out[0..n];
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

/// A stored sample's nibbles, read back as signed values.
fn unpack(bytes: []const u8, out: []i8) void {
    var k: usize = 0;
    var b: usize = 0;
    while (b < bytes.len) : (b += block_bytes) {
        for (bytes[b + 1 ..][0..8]) |byte| {
            for ([2]u3{ 4, 0 }) |sh| {
                out[k] = @as(i4, @bitCast(@as(u4, @truncate(byte >> sh))));
                k += 1;
            }
        }
    }
}

const ramp: Wave = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10 };

test "each length is the wave, doubled, exact, or pairwise averaged" {
    const enc = encode(ramp);
    const lv = levels(ramp);
    const o: i16 = offset(ramp);

    var buf: [64]i8 = undefined;
    unpack(enc[sampleOffset(0)..][0..sampleLen(0)], buf[0..64]);
    for (0..64) |i| try testing.expectEqual(@as(i16, lv[i / 2]) - o, buf[i]);

    unpack(enc[sampleOffset(1)..][0..sampleLen(1)], buf[0..32]);
    for (0..32) |i| try testing.expectEqual(@as(i16, lv[i]) - o, buf[i]);

    unpack(enc[sampleOffset(2)..][0..sampleLen(2)], buf[0..16]);
    for (0..16) |i| {
        const avg = (@as(i16, lv[i * 2]) + lv[i * 2 + 1] + 1) >> 1;
        try testing.expectEqual(avg - o, buf[i]);
    }
}

test "every block is filter 0 shift 11, and only each sample's last loops" {
    const enc = encode(ramp);
    for (0..samples_per) |li| {
        const blocks = blocksFor(lengths[li]);
        for (0..blocks) |b| {
            const h = enc[sampleOffset(li) + b * block_bytes];
            try testing.expectEqual(shift, h >> 4);
            try testing.expectEqual(@as(u8, 0), (h >> 2) & 3);
            const last = b == blocks - 1;
            try testing.expectEqual(last, h & flag_end != 0);
            try testing.expectEqual(last, h & flag_loop != 0);
        }
    }
    try testing.expectEqual(bytes_per_wave, sampleOffset(2) + sampleLen(2));
}

test "the offset centres a wave as far as a nibble allows" {
    // A full-range wave has no choice: 0..15 fits -8..7 only at 8.
    try testing.expectEqual(@as(u8, 8), offset(ramp));
    // A wave between 4 and 11 centres on its mean, 8 rounded from 7.5.
    const mid: Wave = @splat(0x4b);
    try testing.expectEqual(@as(u8, 8), offset(mid));
    // A quiet wave at the bottom is brought up to zero mean.
    const low: Wave = @splat(0x02);
    try testing.expectEqual(@as(u8, 1), offset(low));
    // A wave pinned at the top is moved as far down as it can go.
    const top: Wave = @splat(0xff);
    try testing.expectEqual(@as(u8, 15), offset(top));
    // Whatever the wave, every stored nibble is in range, which `encode`'s
    // casts would otherwise trap on.
    _ = encode(top);
    _ = encode(low);
}

test "the lookup table is a count and the contents, in order" {
    var buf: [64]u8 = undefined;
    const t = try lut(&buf, &.{ ramp, @as(Wave, @splat(0x02)) }, 17);
    try testing.expectEqual(@as(usize, 33), t.len);
    try testing.expectEqual(@as(u8, 2), t[0]);
    try testing.expectEqualSlices(u8, &ramp, t[1..17]);
    try testing.expectError(Error.TooManyWaves, lut(&buf, &.{ ramp, ramp }, 1));
}
