//! The output pins (release Step 1): the SHA-1 of the retail cart, the debug
//! cart and the crawl file, as `zig build rom` makes them today.
//!
//! The pin is what every later refactor is graded against: moving the pipeline
//! into a library, the parallel crawl, the `m2snes` binary and each release
//! target must all produce these bytes. It holds hashes only -- the ROM-data
//! rule allows a digest to leave the machine, never the bytes.
//!
//! An intended change re-pins with `zig build repin -- "<why>"`, which rewrites
//! `pins/cart.txt` and appends the old and new hashes and the reason to
//! `pins/history.md`. The gate checks the two agree, so a hand edit of the pin
//! without a history line is red.

const std = @import("std");

const Sha1 = std.crypto.hash.Sha1;

pub const Digest = [Sha1.digest_length]u8;

pub const cart_path = "pins/cart.txt";
pub const history_path = "pins/history.md";
pub const retail_path = "build-out/m2snes.sfc";
pub const debug_path = "build-out/m2snes-debug.sfc";

pub const repin_hint = "zig build repin -- \"<why>\"";

/// What is pinned, in the order the file and each history line hold them.
pub const Kind = enum { retail, debug, crawl };

pub const Pins = std.EnumArray(Kind, Digest);

pub fn sha1(bytes: []const u8) Digest {
    var d: Digest = undefined;
    Sha1.hash(bytes, &d, .{});
    return d;
}

pub const ParseError = error{ MissingPin, DuplicatePin, BadPinLine };

/// `pins/cart.txt`: `#` comments, then one `<kind> <sha1>` line per kind.
/// Every kind must be there: a pin that is absent is an error, never a skip.
pub fn parse(text: []const u8) ParseError!Pins {
    var pins: Pins = undefined;
    var seen = std.EnumSet(Kind).initEmpty();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse return error.BadPinLine;
        const hex = fields.next() orelse return error.BadPinLine;
        if (fields.next() != null) return error.BadPinLine;
        const kind = std.meta.stringToEnum(Kind, name) orelse return error.BadPinLine;
        if (seen.contains(kind)) return error.DuplicatePin;
        pins.set(kind, try parseDigest(hex));
        seen.insert(kind);
    }
    if (seen.count() != std.meta.fields(Kind).len) return error.MissingPin;
    return pins;
}

fn parseDigest(hex: []const u8) ParseError!Digest {
    var d: Digest = undefined;
    if (hex.len != d.len * 2) return error.BadPinLine;
    _ = std.fmt.hexToBytes(&d, hex) catch return error.BadPinLine;
    return d;
}

pub fn format(out: *std.Io.Writer, pins: Pins) !void {
    try out.writeAll(
        \\# The SHA-1s every build of the cart is graded against (src/pin.zig).
        \\# Hashes only. Never edit by hand: an intended output change re-pins with
        \\#   zig build repin -- "<why>"
        \\# which logs the old and new hashes and the reason in pins/history.md.
        \\
    );
    for (std.enums.values(Kind)) |k| try out.print("{s} {x}\n", .{ @tagName(k), &pins.get(k) });
}

/// `bytes` against the pin: the digest it has, and whether that is the pin.
pub const Check = struct {
    want: Digest,
    got: Digest,

    pub fn ok(c: Check) bool {
        return std.mem.eql(u8, &c.want, &c.got);
    }
};

pub fn check(want: Digest, bytes: []const u8) Check {
    return .{ .want = want, .got = sha1(bytes) };
}

/// Where each pinned output is on disk. The crawl's name carries the ROM's
/// digest (`warp.crawlPath`), so the caller passes it.
pub fn outputPath(k: Kind, crawl_path: []const u8) []const u8 {
    return switch (k) {
        .retail => retail_path,
        .debug => debug_path,
        .crawl => crawl_path,
    };
}

/// The digests of the three outputs as they stand on disk. A file that cannot
/// be read is an error, and `failed` names it.
pub fn current(a: std.mem.Allocator, io: std.Io, crawl_path: []const u8, failed: *[]const u8) !Pins {
    var pins: Pins = undefined;
    for (std.enums.values(Kind)) |k| {
        const path = outputPath(k, crawl_path);
        failed.* = path;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20));
        defer a.free(bytes);
        pins.set(k, sha1(bytes));
    }
    return pins;
}

// ---- pins/history.md ---------------------------------------------------------
//
// One line per pin, appended and never edited:
//
//   - 2026-10-04 | retail <old> -> <new> | debug <old> -> <new> | crawl <old> -> <new> | <why>
//
// where `<old>` is `none` on the first line.

pub const history_header =
    \\# Pin history
    \\
    \\Every change to `pins/cart.txt`, appended by `zig build repin -- "<why>"`: the date, each
    \\SHA-1 before and after, and why. The gate checks the last line matches `pins/cart.txt`.
    \\
    \\
;

/// The pins the history's last entry moved to.
pub fn lastEntry(history: []const u8) ParseError!Pins {
    var last: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, history, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "- ")) last = line;
    }
    const line = last orelse return error.MissingPin;
    var pins: Pins = undefined;
    var parts = std.mem.splitSequence(u8, line, " | ");
    _ = parts.next(); // the date
    for (std.enums.values(Kind)) |k| {
        const part = parts.next() orelse return error.BadPinLine;
        var fields = std.mem.tokenizeScalar(u8, part, ' ');
        const name = fields.next() orelse return error.BadPinLine;
        if (!std.mem.eql(u8, name, @tagName(k))) return error.BadPinLine;
        _ = fields.next() orelse return error.BadPinLine; // old
        const arrow = fields.next() orelse return error.BadPinLine;
        if (!std.mem.eql(u8, arrow, "->")) return error.BadPinLine;
        pins.set(k, try parseDigest(fields.next() orelse return error.BadPinLine));
    }
    // The reason: required, so a line without one is not a pin change.
    const why = parts.rest();
    if (std.mem.trim(u8, why, " ").len == 0) return error.BadPinLine;
    return pins;
}

pub fn equal(a: Pins, b: Pins) bool {
    for (std.enums.values(Kind)) |k| if (!std.mem.eql(u8, &a.get(k), &b.get(k))) return false;
    return true;
}

/// One history line, `old` null on the first pin. `date` is `yyyy-mm-dd`.
pub fn formatEntry(out: *std.Io.Writer, day: []const u8, old: ?Pins, new: Pins, why: []const u8) !void {
    try out.print("- {s}", .{day});
    for (std.enums.values(Kind)) |k| {
        try out.print(" | {s} ", .{@tagName(k)});
        if (old) |o| try out.print("{x}", .{&o.get(k)}) else try out.writeAll("none");
        try out.print(" -> {x}", .{&new.get(k)});
    }
    try out.print(" | {s}\n", .{why});
}

/// `yyyy-mm-dd` (UTC) for a count of seconds since the epoch.
pub fn date(buf: *[10]u8, epoch_seconds: u64) []const u8 {
    const day = (std.time.epoch.EpochSeconds{ .secs = epoch_seconds }).getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), @as(u8, md.day_index) + 1 }) catch unreachable;
}

// ---- The binary (release Step 6) ---------------------------------------------
//
// `m2snes` itself, run from a working directory of its own, against the retail
// and debug pins: the gate's `pin (binary)` rung with the cached crawl, and
// `zig build pin-check` without it, which is the player's run.

/// What `runBinary` needs. Every path is absolute: the binary runs in `workdir`.
pub const Run = struct {
    exe: []const u8,
    rom: []const u8,
    workdir: []const u8,
    /// Null is the player's run, which crawls.
    crawl_cache: ?[]const u8 = null,
};

pub const RunError = error{BinaryFailed};

/// One cart from the binary: the digest of what it wrote. On a failed run
/// `log` holds its stderr.
pub fn runBinary(a: std.mem.Allocator, io: std.Io, r: Run, kind: Kind, log: *[]const u8) !Digest {
    const name = switch (kind) {
        .retail => "m2snes.sfc",
        .debug => "m2snes-debug.sfc",
        .crawl => unreachable, // the binary writes no crawl without the cache
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ r.exe, r.rom, "-o", name });
    if (kind == .debug) try argv.append(a, "--debug");
    if (r.crawl_cache) |c| try argv.appendSlice(a, &.{ "--crawl-cache", c });
    const res = try std.process.run(a, io, .{ .argv = argv.items, .cwd = .{ .path = r.workdir } });
    log.* = res.stderr;
    if (res.term != .exited or res.term.exited != 0) return error.BinaryFailed;
    var dir = try std.Io.Dir.cwd().openDir(io, r.workdir, .{});
    defer dir.close(io);
    const bytes = try dir.readFileAlloc(io, name, a, .limited(16 << 20));
    defer a.free(bytes);
    try dir.deleteFile(io, name);
    return sha1(bytes);
}

/// Both carts from the binary against `pins/cart.txt` (read from the working
/// directory), each printed as one `ok`/`FAIL` line under `label`. True when
/// both match.
pub fn gradeBinary(a: std.mem.Allocator, io: std.Io, r: Run, label: []const u8, out: *std.Io.Writer) !bool {
    const text = std.Io.Dir.cwd().readFileAlloc(io, cart_path, a, .limited(1 << 16)) catch |e| {
        try out.print("FAIL  {s: <17} cannot read {s}: {s}\n", .{ label, cart_path, @errorName(e) });
        return false;
    };
    const want = parse(text) catch |e| {
        try out.print("FAIL  {s: <17} {s}: {s}\n", .{ label, cart_path, @errorName(e) });
        return false;
    };
    var ok = true;
    for ([_]Kind{ .retail, .debug }) |k| {
        var log: []const u8 = "";
        const got = runBinary(a, io, r, k, &log) catch |e| {
            try out.print("FAIL  {s: <17} {s}: {s} {s} in {s}: {s}\n{s}", .{ label, @tagName(k), r.exe, r.rom, r.workdir, @errorName(e), log });
            ok = false;
            continue;
        };
        if (std.mem.eql(u8, &got, &want.get(k))) {
            try out.print("ok    {s: <17} {s}: {x}, the pin\n", .{ label, @tagName(k), &got });
        } else {
            try out.print("FAIL  {s: <17} {s}: pinned {x}, the binary made {x}; if that was meant, {s}\n", .{ label, @tagName(k), &want.get(k), &got, repin_hint });
            ok = false;
        }
    }
    return ok;
}

/// The gate's `builder` rung, half one: `installs` is what a plain `zig build`
/// installs, comma-separated, as build.zig lists it.
pub fn installsOnlyBuilder(installs: []const u8) bool {
    return std.mem.eql(u8, installs, "m2snes");
}

/// Half two: whether the binary's bytes hold the configured ROM path. No path
/// configured means there is nothing to find.
pub fn carriesRomPath(binary: []const u8, rom_path: []const u8) bool {
    return rom_path.len != 0 and std.mem.indexOf(u8, binary, rom_path) != null;
}

// ---- tests -------------------------------------------------------------------

test "the builder rung fails on a second install and on a ROM path in the binary" {
    try std.testing.expect(installsOnlyBuilder("m2snes"));
    try std.testing.expect(!installsOnlyBuilder("m2snes,rom"));
    try std.testing.expect(!installsOnlyBuilder(""));
    const binary = "\x7fELF....path=/Users/x/metroid2.gb\x00....";
    try std.testing.expect(carriesRomPath(binary, "/Users/x/metroid2.gb"));
    try std.testing.expect(!carriesRomPath(binary, "/elsewhere/metroid2.gb"));
    try std.testing.expect(!carriesRomPath(binary, ""));
}

fn testPins() Pins {
    var p: Pins = undefined;
    p.set(.retail, sha1("retail"));
    p.set(.debug, sha1("debug"));
    p.set(.crawl, sha1("crawl"));
    return p;
}

test "the right bytes pass the pin and one mutated byte fails it" {
    var cart = [_]u8{0x5A} ** 4096;
    const want = sha1(&cart);
    try std.testing.expect(check(want, &cart).ok());
    cart[1234] ^= 0x01;
    const c = check(want, &cart);
    try std.testing.expect(!c.ok());
    try std.testing.expectEqualSlices(u8, &sha1(&cart), &c.got);
}

test "the pin file round-trips through format and parse" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try format(&buf.writer, testPins());
    try std.testing.expect(equal(testPins(), try parse(buf.written())));
}

test "a missing pin is an error, not a skip" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try format(&buf.writer, testPins());
    const text = buf.written();
    // Drop the debug line.
    const at = std.mem.indexOf(u8, text, "debug ").?;
    const end = at + std.mem.indexOfScalar(u8, text[at..], '\n').? + 1;
    const cut = try std.mem.concat(std.testing.allocator, u8, &.{ text[0..at], text[end..] });
    defer std.testing.allocator.free(cut);
    try std.testing.expectError(error.MissingPin, parse(cut));
    try std.testing.expectError(error.MissingPin, parse(""));
    try std.testing.expectError(error.MissingPin, parse("# only a comment\n"));
}

test "a malformed or repeated pin line is an error" {
    try std.testing.expectError(error.BadPinLine, parse("retail abc\n"));
    try std.testing.expectError(error.BadPinLine, parse("sfc 0000000000000000000000000000000000000000\n"));
    try std.testing.expectError(error.DuplicatePin, parse(
        "retail 0000000000000000000000000000000000000000\nretail 0000000000000000000000000000000000000000\n",
    ));
}

test "the history's last entry is what the pin must equal" {
    const a = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try buf.writer.writeAll(history_header);
    var first: Pins = undefined;
    inline for (comptime std.enums.values(Kind)) |k| first.set(k, sha1(@tagName(k) ++ "0"));
    try formatEntry(&buf.writer, "2026-10-04", null, first, "first pin");
    try std.testing.expect(equal(first, try lastEntry(buf.written())));
    try formatEntry(&buf.writer, "2026-10-05", first, testPins(), "a converter change");
    try std.testing.expect(equal(testPins(), try lastEntry(buf.written())));
    // A hand edit of the pin with no history line: the two disagree.
    try std.testing.expect(!equal(first, try lastEntry(buf.written())));
}

// The repository's own pin and history, embedded by build.zig, so the check
// needs no ROM and runs wherever `zig build test` does, CI included
// (release Step 9). A hand edit of `pins/cart.txt` with no history line, or a
// PR that moves the pin without a reason, is red here.
test "pins/cart.txt is where the last line of pins/history.md moved it" {
    const want = try parse(@embedFile("pins_cart"));
    const logged = try lastEntry(@embedFile("pins_history"));
    try std.testing.expect(equal(want, logged));
}

test "a history line without a reason, or no history at all, is an error" {
    const a = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try formatEntry(&buf.writer, "2026-10-04", null, testPins(), "");
    try std.testing.expectError(error.BadPinLine, lastEntry(buf.written()));
    try std.testing.expectError(error.MissingPin, lastEntry(history_header));
}

test "the date is UTC yyyy-mm-dd" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01", date(&buf, 0));
    try std.testing.expectEqualStrings("2026-10-04", date(&buf, 1791072000 + 3600));
}
