//! 16-bit signed PCM in a RIFF container — the plainest thing every player on
//! every platform opens without being asked twice.
//!
//! Stated once because the A/B writes two: the Game Boy's render and the
//! SNES's land side by side and are meant to be compared by ear, and a header
//! that disagrees with itself about sample rate or channel count still opens.
//!
//! `parse` exists so a test can grade the *file* rather than the array it was
//! made from, and so the A/B can check the file `spcrun` wrote rather than
//! trust that it wrote one. Nothing in the pipeline reads a WAV as input: no
//! rendered waveform is an input to anything.
//!
//! COPIED from snes_game_dev `audio/wav.zig`, for the reason `sbref.c` is: the
//! shim's renders and this repository's must land in the same container, and a
//! header written twice in two repositories is a header that can disagree with
//! itself. What changes here belongs there too.

const std = @import("std");

pub const channels: u16 = 2;
pub const bits: u16 = 16;

/// Interleaved stereo, little-endian, no chunks beyond `fmt ` and `data`.
pub fn write(w: *std.Io.Writer, samples: []const i16, rate: u32) !void {
    const data_len: u32 = @intCast(samples.len * 2);
    const byte_rate: u32 = rate * channels * (bits / 8);

    try w.writeAll("RIFF");
    try w.writeInt(u32, 36 + data_len, .little);
    try w.writeAll("WAVEfmt ");
    try w.writeInt(u32, 16, .little); // PCM fmt chunk size
    try w.writeInt(u16, 1, .little); // PCM
    try w.writeInt(u16, channels, .little);
    try w.writeInt(u32, rate, .little);
    try w.writeInt(u32, byte_rate, .little);
    try w.writeInt(u16, channels * (bits / 8), .little); // block align
    try w.writeInt(u16, bits, .little);
    try w.writeAll("data");
    try w.writeInt(u32, data_len, .little);
    for (samples) |s| try w.writeInt(i16, s, .little);
}

pub fn size(sample_count: usize) usize {
    return 44 + sample_count * 2;
}

pub const Error = error{ NotRiff, NotWave, NoFmtChunk, NoDataChunk, Unsupported, Truncated };

pub const Parsed = struct {
    rate: u32,
    channels: u16,
    /// Interleaved, in the file's own order. Borrowed from the input bytes.
    samples: []align(1) const i16,
};

/// Enough of RIFF to read back what `write` produced, and to refuse anything
/// else rather than reinterpret it.
pub fn parse(bytes: []const u8) Error!Parsed {
    if (bytes.len < 12) return Error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return Error.NotRiff;
    if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return Error.NotWave;

    var rate: ?u32 = null;
    var chans: u16 = 0;
    var data: ?[]const u8 = null;

    var at: usize = 12;
    while (at + 8 <= bytes.len) {
        const id = bytes[at..][0..4];
        const len = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        const body_at = at + 8;
        if (body_at + len > bytes.len) return Error.Truncated;
        const body = bytes[body_at..][0..len];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (len < 16) return Error.Truncated;
            if (std.mem.readInt(u16, body[0..2], .little) != 1) return Error.Unsupported;
            chans = std.mem.readInt(u16, body[2..4], .little);
            rate = std.mem.readInt(u32, body[4..8], .little);
            if (std.mem.readInt(u16, body[14..16], .little) != bits) return Error.Unsupported;
        } else if (std.mem.eql(u8, id, "data")) {
            data = body;
        }
        at = body_at + len + (len & 1); // RIFF pads odd chunks to even
    }

    const d = data orelse return Error.NoDataChunk;
    const r = rate orelse return Error.NoFmtChunk;
    if (d.len % 2 != 0) return Error.Truncated;
    return .{
        .rate = r,
        .channels = chans,
        .samples = std.mem.bytesAsSlice(i16, d),
    };
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

test "a written WAV parses back to the samples it was given" {
    const pcm = [_]i16{ 0, 1, -1, 32767, -32768, 100, -100, 0 };
    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    try write(&w.writer, &pcm, 32000);

    try testing.expectEqual(size(pcm.len), w.written().len);

    const got = try parse(w.written());
    try testing.expectEqual(@as(u32, 32000), got.rate);
    try testing.expectEqual(@as(u16, 2), got.channels);
    try testing.expectEqual(pcm.len, got.samples.len);
    for (pcm, 0..) |s, i| try testing.expectEqual(s, got.samples[i]);
}

test "a file that is not a WAV is refused rather than reinterpreted" {
    try testing.expectError(Error.NotRiff, parse("SNES-SPC700 Sound File Data v0.30"));
    try testing.expectError(Error.Truncated, parse("RIFF"));
    try testing.expectError(Error.NotWave, parse("RIFF\x00\x00\x00\x00AVI "));
}
