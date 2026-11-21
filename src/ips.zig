//! IPS patches, applied in memory (colorization Step 3).
//!
//! The format: the five bytes `PATCH`, then records, then `EOF`. A record is a
//! three-byte big-endian offset and a two-byte big-endian size, then `size`
//! bytes to write at the offset. A size of zero is an RLE record instead: a
//! two-byte count and one byte to write `count` times. A record past the end of
//! the input grows the output, and the gap is zero-filled. An optional
//! three-byte length after `EOF` truncates the output.
//!
//! The only patch this reads is EJRTQ's colorization, pinned by SHA-1
//! (`ejrtq_sha1`). A different patch is refused before it is applied.

const std = @import("std");

pub const Error = error{
    /// No `PATCH` header.
    NotAnIps,
    /// A record or the trailer runs past the end of the patch.
    Truncated,
    /// The patch is not the pinned one.
    WrongPatch,
};

/// SHA-1 of `metroid ii - color (ejrtq) v1.3.ips`, the file inside
/// `Metroid_II_EJRTQ_Colorization_v1.3.zip` (romhacking.net hack 4388).
pub const ejrtq_sha1 = "73b6a16f346f3b9b6584c86add217e8e1fbdc86f";
pub const ejrtq_name = "metroid ii - color (ejrtq) v1.3.ips";

/// The lowercase hex SHA-1 of `bytes`.
pub fn sha1Hex(bytes: []const u8) [40]u8 {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// `patch` if its SHA-1 is `want`, else `WrongPatch`.
pub fn checkHash(patch: []const u8, want: []const u8) Error!void {
    const have = sha1Hex(patch);
    if (!std.mem.eql(u8, &have, want)) return Error.WrongPatch;
}

/// `input` with `patch` applied. The caller owns the result.
pub fn apply(allocator: std.mem.Allocator, input: []const u8, patch: []const u8) (Error || std.mem.Allocator.Error)![]u8 {
    if (patch.len < 5 or !std.mem.eql(u8, patch[0..5], "PATCH")) return Error.NotAnIps;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, input);

    var at: usize = 5;
    while (true) {
        if (at + 3 > patch.len) return Error.Truncated;
        if (std.mem.eql(u8, patch[at..][0..3], "EOF")) {
            at += 3;
            break;
        }
        if (at + 5 > patch.len) return Error.Truncated;
        const offset: usize = std.mem.readInt(u24, patch[at..][0..3], .big);
        const size: usize = std.mem.readInt(u16, patch[at + 3 ..][0..2], .big);
        at += 5;
        if (size == 0) {
            if (at + 3 > patch.len) return Error.Truncated;
            const count: usize = std.mem.readInt(u16, patch[at..][0..2], .big);
            const value = patch[at + 2];
            at += 3;
            try grow(allocator, &out, offset + count);
            @memset(out.items[offset..][0..count], value);
        } else {
            if (at + size > patch.len) return Error.Truncated;
            try grow(allocator, &out, offset + size);
            @memcpy(out.items[offset..][0..size], patch[at..][0..size]);
            at += size;
        }
    }
    if (at + 3 <= patch.len) {
        const len: usize = std.mem.readInt(u24, patch[at..][0..3], .big);
        if (len < out.items.len) out.shrinkRetainingCapacity(len);
    }
    return out.toOwnedSlice(allocator);
}

fn grow(allocator: std.mem.Allocator, out: *std.ArrayList(u8), len: usize) !void {
    if (len <= out.items.len) return;
    const old = out.items.len;
    try out.resize(allocator, len);
    @memset(out.items[old..], 0);
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

/// A patch built by hand: one plain record, one RLE record that grows the
/// output past the input, and `EOF`.
const sample_patch = "PATCH" ++
    "\x00\x00\x01" ++ "\x00\x02" ++ "\xAA\xBB" ++
    "\x00\x00\x06" ++ "\x00\x00" ++ "\x00\x03" ++ "\x5A" ++
    "EOF";

test "a plain record overwrites and an RLE record grows the output with a zero gap" {
    const out = try apply(testing.allocator, &.{ 1, 2, 3, 4 }, sample_patch);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 1, 0xAA, 0xBB, 4, 0, 0, 0x5A, 0x5A, 0x5A }, out);
}

test "the length after EOF truncates" {
    const out = try apply(testing.allocator, &.{ 1, 2, 3, 4 }, "PATCH" ++ "EOF" ++ "\x00\x00\x02");
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, out);
}

test "a missing header and a cut-off record are refused" {
    try testing.expectError(Error.NotAnIps, apply(testing.allocator, &.{}, "PATCX"));
    try testing.expectError(Error.Truncated, apply(testing.allocator, &.{}, "PATCH\x00\x00\x01\x00\x04\xAA"));
    try testing.expectError(Error.Truncated, apply(testing.allocator, &.{}, "PATCH"));
}

test "the hash check takes the pinned digest and refuses any other" {
    // SHA-1("abc"), from FIPS 180.
    try checkHash("abc", "a9993e364706816aba3e25717850c26c9cd0d89d");
    try testing.expectError(Error.WrongPatch, checkHash(sample_patch, ejrtq_sha1));
}
