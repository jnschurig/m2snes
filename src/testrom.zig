//! The user's ROM, for tests.
//!
//! Every ROM-dependent test reads the ROM through here, and there is exactly
//! one way to skip: no ROM configured (`M2_ROM` unset and no `-Drom=`). Any
//! other failure -- a wrong path, an unreadable file -- is an error and fails
//! the test. The tests used to read the ROM themselves, about a hundred and
//! fifty times, and most of those reads ended in `catch null` or `catch return
//! error.SkipZigTest`, so a mistyped `M2_ROM` turned them into skips that
//! `zig build test` reported as green.
//!
//! It imports nothing from `src/`. The files there import each other by path,
//! so a file reached both that way and through this module would be in two
//! modules at once, which Zig rejects.

const std = @import("std");
const options = @import("testrom_options");
const testing = std.testing;

/// `rom.expected_size * 4`, the ceiling `rom.ingestFile` uses, written out
/// rather than imported for the reason above (Zig follows a file import even
/// inside a test block). The ROM is one fixed revision, so its size cannot move.
const read_limit = 256 * 1024 * 4;

/// The configured ROM, or null when none is configured. Every other failure
/// is returned. The caller owns the bytes.
pub fn load(allocator: std.mem.Allocator) !?[]u8 {
    if (options.rom_path.len == 0) return null;
    return try readAt(allocator, options.rom_path);
}

/// The file at `path`, with every error passed up. Separate from `load` so the
/// error path can be tested without reconfiguring the build.
pub fn readAt(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(read_limit));
}

test "a ROM path that does not exist is an error, not a skip" {
    // The old loaders answered `catch null` here, which their callers turned
    // into `error.SkipZigTest`.
    try testing.expectError(error.FileNotFound, readAt(testing.allocator, "build-out/no-such-rom.gb"));
}

/// The files outside this one that may still name the configured ROM path,
/// besides the executables (`*_main.zig`), which read it for their own run.
/// None of them is a test read.
const allowed = [_]struct { path: []const u8, why: []const u8 }{
    .{ .path = "testrom.zig", .why = "this file" },
    .{ .path = "verify.zig", .why = "the gate's ROM revision line, which reports the ROM rather than testing with it" },
    .{ .path = "gb/sameboy.zig", .why = "`configuredRom`, the reference-capture runner's loader, which reads through its caller's `io`" },
};

fn isAllowed(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, "_main.zig")) return true;
    for (allowed) |e| if (std.mem.eql(u8, e.path, path)) return true;
    return false;
}

/// Whether `line` reads `rom_path` off a `build_options` module, under any
/// name that starts with `build_options` or straight off the `@import`.
fn namesRomPath(line: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, ".rom_path")) |i| : (from = i + 1) {
        const before = line[0..i];
        if (std.mem.endsWith(u8, before, "@import(\"build_options\")")) return true;
        var j = i;
        while (j > 0 and (std.ascii.isAlphanumeric(before[j - 1]) or before[j - 1] == '_')) j -= 1;
        if (std.mem.startsWith(u8, before[j..], "build_options")) return true;
    }
    return false;
}

test "no file in src/ reads the configured ROM except through here" {
    // A ratchet: the reads that used to be scattered through the tests went
    // here one at a time, and this keeps a new one from coming back. A
    // test that needs the ROM calls `load`; a tool that needs it is an
    // executable, or goes on `allowed` with its reason.
    const a = testing.allocator;
    const io = testing.io;
    var src = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(a);
    defer walker.deinit();

    var found: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (isAllowed(entry.path)) continue;
        const text = try src.readFileAlloc(io, entry.path, a, .limited(16 << 20));
        defer a.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 1;
        while (lines.next()) |line| : (n += 1) {
            if (!namesRomPath(line)) continue;
            std.debug.print("src/{s}:{d}: reads the ROM path itself; use testrom.load\n", .{ entry.path, n });
            found += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), found);
}
