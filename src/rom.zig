//! ROM ingest: read the user's Game Boy ROM and prove it is the exact revision
//! every offset in `offsets.zig` was derived against (Step 1, Step 2).
//!
//! This is a bring-your-own-ROM builder, so the ROM is the one input we do not
//! control. A wrong revision would not fail loudly — it would silently shift
//! offsets and produce a subtly broken SNES ROM many steps later. So ingest
//! rejects anything that is not the expected revision, and says which one it
//! wanted.
//!
//! The check is a ladder, cheapest and most diagnostic first, so the error the
//! user sees names the actual problem ("this is Metroid II, but the Japanese
//! revision") rather than a bare hash mismatch. Each rung records *how we know*
//! its expected value, in the same spirit as `offsets.zig`:
//!
//!   1. Size — 256 KiB. Stated as measured in `01-requirements.md`, and implied
//!      by the map banks running to `$F` (16 banks x 16 KiB). A file 512 bytes
//!      longer whose bytes after the first 512 pass rungs 2-4 is a copier-headered
//!      dump; any other size is trimmed, overdumped or another file.
//!   2. Nintendo logo — fixed by the DMG boot ROM, identical on every cartridge
//!      ever published. Catches "this is not a Game Boy ROM at all".
//!   3. Title — "METROID2" at $134. Read from the cartridge header.
//!   4. Header checksum — $14D, verified by the header's own algorithm. Needs
//!      no external knowledge: the ROM checks itself.
//!   5. ROM-size byte — $148 must agree with the actual file size. Another
//!      self-consistency check.
//!   6. CGB flag — $143 bit 7 clear. The original is a DMG cartridge; a
//!      colourisation hack has to set the flag for a Game Boy Color to run it in
//!      colour, so a set bit means a hack rather than another revision.
//!   7. SHA-1 — the authoritative revision gate. The expected digest is the one
//!      the Vashy777/metroid2 disassembly states it targets (README, MIT), and
//!      matches the no-intro "Metroid II - Return of Samus (World)" entry.
//!
//! Rungs 2, 4, 5 and 6 are self-verifying against the ROM's own contents. Rungs
//! 1, 3 and 7 carry external expectations, each cited above.
//!
//! Every refusal names the expected revision and its SHA-1 and says what to do.
//! None of them repairs the file (strips a header, say): a refusal is a message.

const std = @import("std");

/// 256 KiB. 16 banks of 16 KiB, which is what puts map banks $9-$F in range.
pub const expected_size: usize = 256 * 1024;

/// The revision every offset in this repository is derived against.
pub const expected_revision = "Metroid II - Return of Samus (World) [GB, 256 KiB]";

/// SHA-1 of `expected_revision`. See the module doc comment for provenance.
pub const expected_sha1: [20]u8 = .{
    0x74, 0xA2, 0xFA, 0xD8, 0x6B, 0x9A, 0x4C, 0x01, 0x31, 0x49,
    0xB1, 0xE2, 0x14, 0xBC, 0x46, 0x00, 0xEF, 0xB1, 0x06, 0x6D,
};

/// Header field offsets, per the Game Boy cartridge header layout.
pub const header = struct {
    pub const logo: usize = 0x0104;
    pub const logo_len: usize = 48;
    pub const title: usize = 0x0134;
    pub const title_len: usize = 16;
    pub const cgb_flag: usize = 0x0143;
    pub const cart_type: usize = 0x0147;
    pub const rom_size: usize = 0x0148;
    pub const ram_size: usize = 0x0149;
    pub const destination: usize = 0x014A;
    pub const mask_version: usize = 0x014C;
    pub const checksum: usize = 0x014D;
    /// The header checksum covers $134..$14C inclusive.
    pub const checksum_range_start: usize = 0x0134;
    pub const checksum_range_end: usize = 0x014C;
};

/// The Nintendo logo bitmap the DMG boot ROM compares against. Identical on
/// every published cartridge, so a mismatch means this is not a Game Boy ROM.
pub const nintendo_logo: [48]u8 = .{
    0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83,
    0x00, 0x0C, 0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E,
    0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63,
    0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E,
};

pub const expected_title = "METROID2";

/// The 512-byte header some copiers prepend to a dump.
pub const copier_header_len: usize = 512;

pub const Error = error{
    Unreadable,
    HeaderedDump,
    TrimmedOrOverdumped,
    NotAGameBoyRom,
    NotMetroid2,
    HeaderChecksumMismatch,
    RomSizeByteMismatch,
    ColourHack,
    WrongRevision,
};

/// What went wrong, in enough detail to tell the user something actionable.
/// Populated on the failing rung only.
pub const Diagnosis = struct {
    err: Error,
    /// Human-readable, already naming the expected revision where relevant.
    /// Owned by the caller's allocator.
    message: []const u8,
};

pub const Rom = struct {
    bytes: []const u8,
    sha1: [20]u8,

    pub fn title(self: Rom) []const u8 {
        return titleOf(self.bytes);
    }

    pub fn maskVersion(self: Rom) u8 {
        return self.bytes[header.mask_version];
    }

    pub fn destination(self: Rom) u8 {
        return self.bytes[header.destination];
    }
};

/// The header's own checksum algorithm: x = 0; for each byte in $134..$14C,
/// x = x - byte - 1. Self-verifying, so it needs no external reference.
pub fn computeHeaderChecksum(bytes: []const u8) u8 {
    var x: u8 = 0;
    var i = header.checksum_range_start;
    while (i <= header.checksum_range_end) : (i += 1) {
        x = x -% bytes[i] -% 1;
    }
    return x;
}

/// The size the header's $148 byte claims, or null if the value is not one of
/// the defined encodings. 0 => 32 KiB, doubling per step.
pub fn declaredRomSize(byte: u8) ?usize {
    if (byte > 0x08) return null;
    return (@as(usize, 32) * 1024) << @intCast(byte);
}

/// Rungs 2-4 on a 256 KiB image: the logo, the title and the header's own
/// checksum. What "a Metroid II image" means when deciding a 512-byte-longer
/// file is a headered dump.
fn looksLikeMetroid2(bytes: []const u8) bool {
    if (bytes.len != expected_size) return false;
    if (!std.mem.eql(u8, bytes[header.logo..][0..header.logo_len], &nintendo_logo)) return false;
    if (!std.mem.eql(u8, titleOf(bytes), expected_title)) return false;
    return computeHeaderChecksum(bytes) == bytes[header.checksum];
}

fn titleOf(bytes: []const u8) []const u8 {
    const raw = bytes[header.title..][0..header.title_len];
    const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
    return raw[0..end];
}

/// Validate `bytes` as the expected revision. On success the returned `Rom`
/// borrows `bytes` — it does not copy. On failure, `diag` (if provided) is
/// filled with an allocated message the caller must free.
pub fn ingest(allocator: std.mem.Allocator, bytes: []const u8, diag: ?*Diagnosis) Error!Rom {
    // Rung 1: size.
    if (bytes.len == expected_size + copier_header_len and looksLikeMetroid2(bytes[copier_header_len..])) {
        return fail(allocator, diag, Error.HeaderedDump, "ROM is {d} bytes: a {d}-byte image behind a {d}-byte copier header. Remove the first {d} bytes, or dump the cartridge again without a header.", .{
            bytes.len, expected_size, copier_header_len, copier_header_len,
        });
    }
    if (bytes.len != expected_size) {
        return fail(allocator, diag, Error.TrimmedOrOverdumped, "ROM is {d} bytes; the cartridge holds exactly {d}. The file is trimmed, overdumped or not this game. Dump the whole cartridge again.", .{
            bytes.len, expected_size,
        });
    }

    // Rung 2: Nintendo logo — is this a Game Boy ROM at all?
    if (!std.mem.eql(u8, bytes[header.logo..][0..header.logo_len], &nintendo_logo)) {
        return fail(allocator, diag, Error.NotAGameBoyRom, "no Nintendo logo at ${x:0>4}: this is not a Game Boy ROM. Use a dump of your Metroid II cartridge.", .{header.logo});
    }

    // Rung 3: title.
    const got_title = titleOf(bytes);
    if (!std.mem.eql(u8, got_title, expected_title)) {
        return fail(allocator, diag, Error.NotMetroid2, "cartridge title is \"{s}\"; expected \"{s}\". Use a dump of your Metroid II cartridge.", .{
            got_title, expected_title,
        });
    }

    // Rung 4: header checksum — the ROM checking itself.
    const want_sum = computeHeaderChecksum(bytes);
    const got_sum = bytes[header.checksum];
    if (want_sum != got_sum) {
        return fail(allocator, diag, Error.HeaderChecksumMismatch, "header checksum is ${x:0>2} but the header's own bytes compute ${x:0>2}: the ROM is corrupt or has been modified. Dump the cartridge again.", .{ got_sum, want_sum });
    }

    // Rung 5: the $148 size byte must agree with the actual file size.
    const declared = declaredRomSize(bytes[header.rom_size]);
    if (declared == null or declared.? != bytes.len) {
        return fail(allocator, diag, Error.RomSizeByteMismatch, "header size byte ${x:0>2} disagrees with the {d}-byte file: the ROM is corrupt or has been modified. Dump the cartridge again.", .{
            bytes[header.rom_size], bytes.len,
        });
    }

    // Rung 6: the CGB flag — a colourisation hack, not a revision.
    if (bytes[header.cgb_flag] & 0x80 != 0) {
        return fail(allocator, diag, Error.ColourHack, "the Game Boy Color flag at ${x:0>4} is set (${x:0>2}): this is a colourised hack, not the original cartridge. Use an unmodified dump.", .{
            header.cgb_flag, bytes[header.cgb_flag],
        });
    }

    // Rung 7: the authoritative revision gate.
    var sha1: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &sha1, .{});
    if (!std.mem.eql(u8, &sha1, &expected_sha1)) {
        return fail(allocator, diag, Error.WrongRevision, "this is Metroid II, but not the expected revision: sha1 {x} (mask ROM version ${x:0>2}, destination ${x:0>2}). Use a dump of the World release.", .{
            &sha1, bytes[header.mask_version], bytes[header.destination],
        });
    }

    return .{ .bytes = bytes, .sha1 = sha1 };
}

/// Fill `diag` with the rung's message, followed by the revision and SHA-1 the
/// builder expects, which every refusal names.
fn fail(
    allocator: std.mem.Allocator,
    diag: ?*Diagnosis,
    err: Error,
    comptime fmt: []const u8,
    args: anytype,
) Error {
    if (diag) |d| {
        d.* = .{
            .err = err,
            .message = std.fmt.allocPrint(allocator, fmt ++ "\n  expected: {s}\n            sha1 {x}", args ++ .{ expected_revision, &expected_sha1 }) catch "out of memory formatting ROM diagnosis",
        };
    }
    return err;
}

/// Read and validate a ROM from disk. The returned bytes are owned by
/// `allocator`. A file too large to read is refused as overdumped.
pub fn ingestFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    diag: ?*Diagnosis,
) !Rom {
    const limit = expected_size * 4;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => return fail(allocator, diag, Error.TrimmedOrOverdumped, "ROM at {s} is over {d} bytes; the cartridge holds exactly {d}. The file is overdumped or not this game. Dump the whole cartridge again.", .{
            path, limit, expected_size,
        }),
        else => {
            _ = fail(allocator, diag, Error.Unreadable, "cannot read ROM at {s}: {s}", .{ path, @errorName(err) }) catch {};
            return err;
        },
    };
    errdefer allocator.free(bytes);
    return try ingest(allocator, bytes, diag);
}

// ---------------------------------------------------------------------------
// Tests
//
// Every fixture here is *synthesized*, not derived from the retail ROM — this
// repository contains no proprietary bytes, which means the tests cannot use
// real ones either. That has one real consequence, stated plainly rather than
// papered over: rungs 1-5 are fully covered, but rung 6 (the SHA-1 gate) can
// only be tested in its *rejecting* direction. Confirming that the expected
// digest actually matches the retail ROM requires the ROM, so it is a
// ROM-dependent check in `zig build verify`, not a unit test.
// ---------------------------------------------------------------------------

/// Build a structurally valid 256 KiB Game Boy ROM with Metroid II's header.
/// Correct logo, title, size byte, and a header checksum computed to match —
/// so it passes rungs 1-6 and fails only at the SHA-1. Public for
/// `pincheck refusals`, which runs the binary on the same mutations.
pub fn synthesizeRom(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try allocator.alloc(u8, expected_size);
    @memset(bytes, 0);
    @memcpy(bytes[header.logo..][0..header.logo_len], &nintendo_logo);
    @memcpy(bytes[header.title..][0..expected_title.len], expected_title);
    bytes[header.rom_size] = 0x03; // 256 KiB
    bytes[header.checksum] = computeHeaderChecksum(bytes);
    return bytes;
}

/// Ingest `bytes`, expect refusal `want`, and check the message names the
/// expected revision and SHA-1 (every refusal does) and `needle`, if given.
/// `ingest` takes the bytes as const, so a refusal cannot have written to them.
fn expectRefusal(bytes: []const u8, want: Error, needle: ?[]const u8) !void {
    const allocator = std.testing.allocator;
    var diag: Diagnosis = undefined;
    try std.testing.expectError(want, ingest(allocator, bytes, &diag));
    defer allocator.free(diag.message);
    try std.testing.expectEqual(want, diag.err);
    const sha_hex = std.fmt.bytesToHex(expected_sha1, .lower);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, expected_revision) != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, &sha_hex) != null);
    if (needle) |n| try std.testing.expect(std.mem.indexOf(u8, diag.message, n) != null);
}

test "synthetic ROM passes every structural rung and fails only on revision" {
    const bytes = try synthesizeRom(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try expectRefusal(bytes, Error.WrongRevision, "World release");
}

test "a truncated ROM is refused as trimmed" {
    const bytes = try synthesizeRom(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try expectRefusal(bytes[0 .. expected_size / 2], Error.TrimmedOrOverdumped, "trimmed");
}

test "an overdumped ROM is refused, even with a valid image at its start" {
    const allocator = std.testing.allocator;
    const rom = try synthesizeRom(allocator);
    defer allocator.free(rom);
    const bytes = try allocator.alloc(u8, expected_size * 2);
    defer allocator.free(bytes);
    @memcpy(bytes[0..expected_size], rom);
    @memcpy(bytes[expected_size..], rom);
    try expectRefusal(bytes, Error.TrimmedOrOverdumped, "overdumped");
}

test "a copier-headered dump is refused as headered, not as the wrong size" {
    const allocator = std.testing.allocator;
    const rom = try synthesizeRom(allocator);
    defer allocator.free(rom);
    const bytes = try allocator.alloc(u8, copier_header_len + expected_size);
    defer allocator.free(bytes);
    @memset(bytes[0..copier_header_len], 0);
    @memcpy(bytes[copier_header_len..], rom);
    try expectRefusal(bytes, Error.HeaderedDump, "Remove the first 512 bytes");

    // 512 bytes too many, but no Metroid II image behind them: just the wrong size.
    bytes[copier_header_len + header.logo] ^= 0xFF;
    try expectRefusal(bytes, Error.TrimmedOrOverdumped, null);
}

test "a non-Game Boy file is refused at the logo" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, expected_size);
    defer allocator.free(bytes);
    @memset(bytes, 0xAA);
    try expectRefusal(bytes, Error.NotAGameBoyRom, "not a Game Boy ROM");
}

test "a different Game Boy game is refused by title" {
    const bytes = try synthesizeRom(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    @memcpy(bytes[header.title..][0.."TETRIS".len], "TETRIS");
    @memset(bytes[header.title + "TETRIS".len ..][0 .. header.title_len - "TETRIS".len], 0);
    bytes[header.checksum] = computeHeaderChecksum(bytes);
    try expectRefusal(bytes, Error.NotMetroid2, "TETRIS");
}

test "a corrupted header is refused by its own checksum" {
    const bytes = try synthesizeRom(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    bytes[header.cart_type] +%= 1; // inside the checksummed range, checksum not recomputed
    try expectRefusal(bytes, Error.HeaderChecksumMismatch, "Dump the cartridge again");
}

test "a size byte disagreeing with the file is refused" {
    const bytes = try synthesizeRom(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    bytes[header.rom_size] = 0x05; // claims 1 MiB
    bytes[header.checksum] = computeHeaderChecksum(bytes);
    try expectRefusal(bytes, Error.RomSizeByteMismatch, "Dump the cartridge again");
}

test "a colourised hack is refused by its CGB flag, before the revision check" {
    const bytes = try synthesizeRom(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    for ([_]u8{ 0x80, 0xC0 }) |flag| { // CGB-enhanced and CGB-only
        bytes[header.cgb_flag] = flag;
        bytes[header.checksum] = computeHeaderChecksum(bytes);
        try expectRefusal(bytes, Error.ColourHack, "colourised hack");
    }
}

test "header checksum algorithm matches the hardware definition" {
    // Worked by hand over a two-byte range to pin the -byte-1 accumulation.
    var bytes = [_]u8{0} ** (header.checksum_range_end + 1);
    bytes[header.checksum_range_start] = 0x10;
    bytes[header.checksum_range_start + 1] = 0x20;
    var expect: u8 = 0;
    var i = header.checksum_range_start;
    while (i <= header.checksum_range_end) : (i += 1) expect = expect -% bytes[i] -% 1;
    try std.testing.expectEqual(expect, computeHeaderChecksum(&bytes));
}

test "declared ROM size decoding" {
    try std.testing.expectEqual(@as(?usize, 32 * 1024), declaredRomSize(0x00));
    try std.testing.expectEqual(@as(?usize, 256 * 1024), declaredRomSize(0x03));
    try std.testing.expectEqual(@as(?usize, null), declaredRomSize(0xFF));
}
