//! The committed GB APU shim package, checked against its own MANIFEST.
//!
//! `audio/shim/` is a build product of another repository, copied in by
//! `tools/sync-shim.sh`. That makes it the one directory here whose contents no
//! build step produces and no test exercises — exactly the shape of thing that
//! drifts. A hand-edited `shim_abi.inc`, a `shim.bin` from a half-finished
//! sync, a `shimpkg.zig` left behind when the other three moved: all of them
//! assemble, and all of them would show up as an engine that plays the wrong
//! notes on a machine nobody can rebuild.
//!
//! So the package carries a sha256 per file and the commit it was built from,
//! and the gate reads them. This is a tripwire for accident, not a defence
//! against anyone: whoever can edit `shim.bin` can edit `MANIFEST` too. What it
//! catches is the sync that went halfway, which is the failure that actually
//! happens.
//!
//! It also checks the ABI. The engine assembles against the jump table and the
//! region addresses in `shim_abi.inc`; if the shim moves them, an engine built
//! against the old ones calls into the middle of a routine, and on the SPC700
//! that is silent. `engine/audio/main.asm` names the version it was written
//! against and the assembler asserts it, but the assembler is optional tooling.
//! This check needs nothing but the files.

const std = @import("std");

pub const dir = "audio/shim";

/// Every file `tools/sync-shim.sh` copies. Named here rather than taken from
/// the MANIFEST's own lines, so a MANIFEST that simply forgot a file is a
/// failure and not a shorter list of passes.
pub const files = [_][]const u8{ "shim.bin", "shim_abi.inc", "shimpkg.zig", "wave.zig", "noise.zig" };

pub const Report = union(enum) {
    ok: Ok,
    /// No package at all. Not a failure on its own: the audio cycle's Step 4
    /// is where it first appears, and a checkout from before that is intact.
    absent,
    /// A named reason the package cannot be trusted.
    failed: []const u8,

    pub const Ok = struct {
        commit: []const u8,
        abi: u32,
        bytes: usize,
    };
};

/// Read the package and compare it with its MANIFEST.
///
/// `expected_abi` is what the engine source says it was written against; pass
/// null when that could not be read, and the ABI comparison is skipped rather
/// than guessed at.
pub fn check(
    allocator: std.mem.Allocator,
    io: std.Io,
    expected_abi: ?u32,
) !Report {
    const cwd = std.Io.Dir.cwd();

    const manifest_path = dir ++ "/MANIFEST";
    const manifest = cwd.readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024)) catch
        return .absent;

    var commit: ?[]const u8 = null;
    var abi: ?u32 = null;
    // path -> the digest the MANIFEST claims for it.
    var claimed: std.StringHashMapUnmanaged([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var field = std.mem.tokenizeAny(u8, line, " \t");
        const key = field.next() orelse continue;
        if (std.mem.eql(u8, key, "commit")) {
            commit = field.next() orelse return .{ .failed = "the MANIFEST's commit line names no commit" };
        } else if (std.mem.eql(u8, key, "abi")) {
            const value = field.next() orelse return .{ .failed = "the MANIFEST's abi line names no version" };
            abi = std.fmt.parseInt(u32, value, 10) catch
                return .{ .failed = "the MANIFEST's abi version is not a number" };
        } else if (std.mem.eql(u8, key, "sha256")) {
            const digest = field.next() orelse return .{ .failed = "a MANIFEST sha256 line names no digest" };
            const path = field.next() orelse return .{ .failed = "a MANIFEST sha256 line names no file" };
            try claimed.put(allocator, path, digest);
        }
    }

    const the_commit = commit orelse return .{ .failed = "the MANIFEST names no commit" };
    const the_abi = abi orelse return .{ .failed = "the MANIFEST names no ABI version" };

    // A `-dirty` package was built from uncommitted edits, so its commit names
    // bytes that exist on one machine. `sync-shim.sh` refuses to write one;
    // this catches the copy made by hand.
    if (std.mem.endsWith(u8, the_commit, "-dirty"))
        return .{ .failed = "the package was built from a dirty tree and cannot be rebuilt from its commit" };

    var total: usize = 0;
    for (files) |name| {
        const digest = claimed.get(name) orelse
            return .{ .failed = try std.fmt.allocPrint(allocator, "the MANIFEST does not cover {s}", .{name}) };
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        const bytes = cwd.readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch
            return .{ .failed = try std.fmt.allocPrint(allocator, "{s} is missing", .{path}) };
        total += bytes.len;

        var out: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
        const hex = try std.fmt.allocPrint(allocator, "{x}", .{&out});
        if (!std.mem.eql(u8, hex, digest))
            return .{ .failed = try std.fmt.allocPrint(
                allocator,
                "{s} is not the file the MANIFEST names; re-run tools/sync-shim.sh",
                .{path},
            ) };
    }

    // The ABI number and the header the engine assembles against have to agree,
    // or the MANIFEST is describing a different package than the one on disk.
    const inc_path = dir ++ "/shim_abi.inc";
    const inc = try cwd.readFileAlloc(io, inc_path, allocator, .limited(1024 * 1024));
    const declared = incValue(inc, "SHIM_ABI_VERSION") orelse
        return .{ .failed = "shim_abi.inc declares no SHIM_ABI_VERSION" };
    if (declared != the_abi)
        return .{ .failed = try std.fmt.allocPrint(
            allocator,
            "shim_abi.inc is ABI {d} but the MANIFEST says {d}",
            .{ declared, the_abi },
        ) };

    if (expected_abi) |want| {
        if (want != the_abi)
            return .{ .failed = try std.fmt.allocPrint(
                allocator,
                "engine/audio/main.asm is written for ABI {d}, the package is ABI {d}; port the engine or sync an older shim",
                .{ want, the_abi },
            ) };
    }

    return .{ .ok = .{ .commit = the_commit, .abi = the_abi, .bytes = total } };
}

/// The ABI version `engine/audio/main.asm` says it was written against.
///
/// Read out of the source rather than duplicated here: the assembler asserts
/// the same constant against the package's header, so the two checks share a
/// single statement and cannot drift apart from each other.
pub fn engineExpectedAbi(allocator: std.mem.Allocator, io: std.Io) !?u32 {
    const src = std.Io.Dir.cwd().readFileAlloc(
        io,
        "engine/audio/main.asm",
        allocator,
        .limited(4 * 1024 * 1024),
    ) catch return null;
    return incValue(src, "SHIM_ABI_EXPECTED");
}

/// `NAME = <number>` out of an spc700asm source line, in decimal or `$hex`.
///
/// Public because `audio_req.zig` reads its own slot equates out of the same
/// file, and two parsers for one syntax is one too many.
pub fn incValue(text: []const u8, name: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, name)) continue;
        const rest = std.mem.trim(u8, line[name.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        var value = std.mem.trim(u8, rest[1..], " \t");
        // A trailing comment is not part of the number.
        if (std.mem.indexOfAny(u8, value, ";")) |i| value = std.mem.trim(u8, value[0..i], " \t");
        if (value.len == 0) return null;
        if (value[0] == '$') return std.fmt.parseInt(u32, value[1..], 16) catch null;
        return std.fmt.parseInt(u32, value, 10) catch null;
    }
    return null;
}

test "incValue reads decimal, hex and commented forms" {
    try std.testing.expectEqual(@as(?u32, 1), incValue("    SHIM_ABI_EXPECTED = 1\n", "SHIM_ABI_EXPECTED"));
    try std.testing.expectEqual(@as(?u32, 0x21), incValue("SHIM_ABI_VERSION = $21\n", "SHIM_ABI_VERSION"));
    try std.testing.expectEqual(@as(?u32, 3), incValue("X = 3 ; why\n", "X"));
    try std.testing.expectEqual(@as(?u32, null), incValue("SHIM_ABI_VERSIONS = 1\n", "SHIM_ABI_VERSION"));
    try std.testing.expectEqual(@as(?u32, null), incValue("; SHIM_ABI_EXPECTED = 1\n", "SHIM_ABI_EXPECTED"));
}

test "the committed package matches its MANIFEST" {
    // The gate runs this against the real tree too; here it is a unit so a
    // `zig build test` catches a broken sync without a ROM or an assembler.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Tests run with the build root as the cwd (`setCwd` in build.zig).
    switch (try check(arena.allocator(), std.testing.io, null)) {
        .ok, .absent => {},
        .failed => |why| {
            std.debug.print("audio/shim: {s}\n", .{why});
            return error.ShimPackageFailed;
        },
    }
}
