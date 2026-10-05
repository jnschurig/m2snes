//! `pathscan [--prefix P]... <binary>...` -- fail on any build-host path in a
//! release binary (release Step 8, Feature 2).
//!
//! A shipped binary must not name the machine it was built on. Zig 0.16 has
//! no debug-prefix map, so the release binaries are stripped; this is the
//! check that they are. It looks for the absolute prefixes a host path starts
//! with (`/Users/`, `/home/`, `/opt/`, `/tmp/`, `/private/`, `/var/`, a drive
//! letter) and for each `--prefix` (the build root, the Zig lib dir and the
//! global cache of the build at hand). `zig build release` runs it over every
//! target's binary.

const std = @import("std");

/// The starts of a host path, on every OS a release is built on.
pub const fixed = [_][]const u8{ "/Users/", "/home/", "/opt/", "/tmp/", "/private/", "/var/" };

pub const Hit = struct {
    offset: usize,
    /// The prefix that matched; `X:\` for a drive letter.
    what: []const u8,
};

/// The first host path in `bytes` at or after `from`, or null. `extra` holds
/// the build's own paths; an empty one is ignored.
pub fn scan(bytes: []const u8, from: usize, extra: []const []const u8) ?Hit {
    var best: ?Hit = null;
    for (fixed) |p| best = earlier(best, find(bytes, from, p));
    for (extra) |p| if (p.len != 0) {
        best = earlier(best, find(bytes, from, p));
    };
    return earlier(best, driveLetter(bytes, from));
}

fn find(bytes: []const u8, from: usize, p: []const u8) ?Hit {
    const at = std.mem.indexOfPos(u8, bytes, from, p) orelse return null;
    return .{ .offset = at, .what = p };
}

fn earlier(a: ?Hit, b: ?Hit) ?Hit {
    const x = a orelse return b;
    const y = b orelse return a;
    return if (y.offset < x.offset) y else x;
}

/// `C:\x` or `C:/x`: a letter not preceded by a letter or digit, then a
/// colon, a separator and a printable character. The guards keep machine
/// code from matching by chance.
fn driveLetter(bytes: []const u8, from: usize) ?Hit {
    var i = from;
    while (i + 3 < bytes.len) : (i += 1) {
        if (!std.ascii.isAlphabetic(bytes[i]) or bytes[i + 1] != ':') continue;
        if (bytes[i + 2] != '\\' and bytes[i + 2] != '/') continue;
        if (!std.ascii.isPrint(bytes[i + 3]) or bytes[i + 3] == ' ') continue;
        if (i > 0 and std.ascii.isAlphanumeric(bytes[i - 1])) continue;
        return .{ .offset = i, .what = "X:\\" };
    }
    return null;
}

/// The printable run at `at`, for the report.
fn context(bytes: []const u8, at: usize) []const u8 {
    var end = at;
    while (end < bytes.len and end - at < 80 and std.ascii.isPrint(bytes[end])) end += 1;
    return bytes[at..end];
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var extra: std.ArrayList([]const u8) = .empty;
    var binaries: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--prefix")) {
            try extra.append(a, args.next() orelse return usage());
        } else try binaries.append(a, arg);
    }
    if (binaries.items.len == 0) return usage();

    var dirty = false;
    for (binaries.items) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(256 << 20));
        var hits: usize = 0;
        var from: usize = 0;
        while (scan(bytes, from, extra.items)) |h| : (from = h.offset + 1) {
            if (hits < 10) try out.print("pathscan: {s}: host path at 0x{x} ({s}): {s}\n", .{ path, h.offset, h.what, context(bytes, h.offset) });
            hits += 1;
        }
        if (hits == 0) {
            try out.print("pathscan: {s}: no host paths\n", .{path});
        } else {
            if (hits > 10) try out.print("pathscan: {s}: ... {d} hits in all\n", .{ path, hits });
            dirty = true;
        }
    }
    try out.flush();
    if (dirty) {
        std.debug.print("pathscan: a release binary names the build host; is it stripped? (builderExe in build.zig)\n", .{});
        std.process.exit(1);
    }
}

fn usage() noreturn {
    std.debug.print("usage: pathscan [--prefix P]... <binary>...\n", .{});
    std.process.exit(2);
}

// ---- tests -------------------------------------------------------------------

test "every host prefix fails the scan, and a clean buffer passes" {
    const extra = [_][]const u8{ "/work/build-root", "", "D:/zig/lib" };
    const cases = [_][]const u8{
        "\x00\x01/Users/james/git/m2snes/src/main.zig\x00",
        "\x00/home/runner/work/m2snes\x00",
        "\x00/opt/homebrew/lib\x00",
        "\x00/tmp/zig-cache\x00",
        "\x00/private/var/folders\x00",
        "\x00/var/folders/xy\x00",
        "\x00C:\\Users\\runneradmin\x00",
        "\x00c:/hostedtoolcache/zig\x00",
        "\x00/work/build-root/src\x00",
        "\x00\x00zig/lib/std\x00",
    };
    for (cases[0 .. cases.len - 1]) |c| {
        const h = scan(c, 0, &extra) orelse return error.TestExpectedHit;
        try std.testing.expect(h.offset <= 2);
    }
    // A relative path, the empty extra, and look-alikes pass.
    const clean = "\x00src/main.zig\x00std/fs.zig\x00usr/lib\x00ratio 3:4\x00ABC:\\x\x00\x7fELF\x00/proc/self\x00";
    try std.testing.expectEqual(@as(?Hit, null), scan(clean, 0, &extra));
    try std.testing.expectEqual(@as(?Hit, null), scan(cases[cases.len - 1], 0, &extra));
}

test "the scan reports every hit in order" {
    const bytes = "aa C:\\x bb /home/y cc /Users/z";
    var from: usize = 0;
    var got: [3]usize = undefined;
    var n: usize = 0;
    while (scan(bytes, from, &.{})) |h| : (from = h.offset + 1) {
        got[n] = h.offset;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(usize, &.{ 3, 11, 22 }, got[0..n]);
}
