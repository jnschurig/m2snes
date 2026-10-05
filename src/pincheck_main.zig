//! The `m2snes` binary, run as a player runs it (release Step 6).
//!
//!   pincheck pins <m2snes> <rom> <workdir>
//!     `zig build pin-check`: both carts from the binary with no crawl cache,
//!     the player's path, from a working directory of their own, against
//!     `pins/cart.txt`. It is `verify-full`'s rung and the macOS check before
//!     a tag.
//!
//!   pincheck cached <m2snes> <rom> <crawl-cache> <workdir>
//!     `zig build cart-pin` (release Step 9): both carts from the binary,
//!     reading the cached crawl, against `pins/cart.txt`. Seconds, so it is
//!     the pre-push hook's pin rung; `verify`'s 13 minutes stay manual.
//!
//!   pincheck location <m2snes> <rom> <crawl-cache> <workdir>
//!     `verify-full`'s `location` rung (release Step 8): the retail cart from
//!     the binary copied to two install directories, run from two working
//!     directories, on the ROM by a relative and by an absolute path -- eight
//!     runs, each against the pin. The crawl comes from the cache, by an
//!     absolute path, so the rung takes seconds.
//!
//!   pincheck refusals <m2snes> <workdir>
//!     Part of `zig build test`, and needs no ROM: the binary on each of
//!     `rom.zig`'s refusals, built from a synthetic image, and on an output
//!     that is its own input. Each must exit 1, name the expected SHA-1 and
//!     leave nothing behind but the input.

const std = @import("std");
const rom_mod = @import("rom.zig");
const pin = @import("pin.zig");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return error.Usage;
    const exe = try absolute(a, io, args.next() orelse return error.Usage);

    const ok = if (std.mem.eql(u8, mode, "pins")) blk: {
        const rom = try absolute(a, io, args.next() orelse return error.Usage);
        const workdir = try freshDir(a, io, args.next() orelse return error.Usage);
        break :blk try pin.gradeBinary(a, io, .{ .exe = exe, .rom = rom, .workdir = workdir }, "pin-check", out);
    } else if (std.mem.eql(u8, mode, "cached")) blk: {
        const rom = try absolute(a, io, args.next() orelse return error.Usage);
        const cache = try absolute(a, io, args.next() orelse return error.Usage);
        const workdir = try freshDir(a, io, args.next() orelse return error.Usage);
        break :blk try pin.gradeBinary(a, io, .{ .exe = exe, .rom = rom, .workdir = workdir, .crawl_cache = cache }, "cart pin", out);
    } else if (std.mem.eql(u8, mode, "location")) blk: {
        const rom = try absolute(a, io, args.next() orelse return error.Usage);
        const cache = try absolute(a, io, args.next() orelse return error.Usage);
        const workdir = try freshDir(a, io, args.next() orelse return error.Usage);
        break :blk try location(a, io, exe, rom, cache, workdir, out);
    } else if (std.mem.eql(u8, mode, "refusals")) blk: {
        const workdir = try freshDir(a, io, args.next() orelse return error.Usage);
        break :blk try refusals(a, io, exe, workdir, out);
    } else return error.Usage;
    try out.flush();
    if (!ok) std.process.exit(1);
}

fn absolute(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, a);
}

/// `path`, emptied, as an absolute path.
fn freshDir(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    try std.Io.Dir.cwd().deleteTree(io, path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    return absolute(a, io, path);
}

/// Feature 1's location rule: the same cart wherever the binary is installed
/// and wherever it is run from. The second install directory's name has a
/// space in it.
fn location(a: std.mem.Allocator, io: std.Io, exe: []const u8, rom: []const u8, cache: []const u8, workdir: []const u8, out: *std.Io.Writer) !bool {
    const label = "location";
    const text = std.Io.Dir.cwd().readFileAlloc(io, pin.cart_path, a, .limited(1 << 16)) catch |e| {
        try out.print("FAIL  {s: <17} cannot read {s}: {s}\n", .{ label, pin.cart_path, @errorName(e) });
        return false;
    };
    const want = (try pin.parse(text)).get(.retail);

    const installs = [_][]const u8{ "install-a/bin", "install b" };
    const cwds = [_][]const u8{ "run-1", "run-2/deeper" };
    var exes: [installs.len][]const u8 = undefined;
    for (installs, &exes) |dir, *e| {
        e.* = try std.fs.path.join(a, &.{ workdir, dir, std.fs.path.basename(exe) });
        try std.Io.Dir.copyFileAbsolute(exe, e.*, io, .{ .make_path = true });
    }
    var ok = true;
    var runs: usize = 0;
    for (exes) |e| for (cwds) |c| {
        const cwd = try std.fs.path.join(a, &.{ workdir, c });
        try std.Io.Dir.cwd().createDirPath(io, cwd);
        const rel = try std.fs.path.relative(a, cwd, null, cwd, rom);
        for ([_][]const u8{ rel, rom }) |r| {
            runs += 1;
            var log: []const u8 = "";
            const got = pin.runBinary(a, io, .{ .exe = e, .rom = r, .workdir = cwd, .crawl_cache = cache }, .retail, &log) catch |err| {
                try out.print("FAIL  {s: <17} {s} {s} in {s}: {s}\n{s}", .{ label, e, r, cwd, @errorName(err), log });
                ok = false;
                continue;
            };
            if (!std.mem.eql(u8, &got, &want)) {
                try out.print("FAIL  {s: <17} {s} {s} in {s}: made {x}, pinned {x}\n", .{ label, e, r, cwd, &got, &want });
                ok = false;
            }
        }
    };
    if (ok) try out.print("ok    {s: <17} retail: {x}, the pin, from {d} runs (2 installs x 2 working dirs x relative/absolute ROM)\n", .{ label, &want, runs });
    return ok;
}

const Case = struct {
    name: []const u8,
    /// What the message must say besides the expected SHA-1.
    needle: []const u8,
    /// `-o` for the run; null is the default output beside the ROM.
    out: ?[]const u8 = null,
};

fn refusals(a: std.mem.Allocator, io: std.Io, exe: []const u8, workdir: []const u8, out: *std.Io.Writer) !bool {
    const valid = try rom_mod.synthesizeRom(a);
    const h = rom_mod.header;
    const sha_hex = std.fmt.bytesToHex(rom_mod.expected_sha1, .lower);
    var ok = true;
    var n: usize = 0;

    const cases = [_]Case{
        .{ .name = "trimmed", .needle = "trimmed" },
        .{ .name = "overdumped", .needle = "overdumped" },
        .{ .name = "headered", .needle = "copier header" },
        .{ .name = "not a Game Boy ROM", .needle = "not a Game Boy ROM" },
        .{ .name = "another game", .needle = "TETRIS" },
        .{ .name = "corrupt header", .needle = "header checksum" },
        .{ .name = "size byte", .needle = "size byte" },
        .{ .name = "colourised", .needle = "colourised hack" },
        .{ .name = "wrong revision", .needle = "not the expected revision" },
        .{ .name = "output is the input", .needle = "is your ROM", .out = "in.gb" },
        .{ .name = "output links to the input", .needle = "is your ROM", .out = "link.sfc" },
    };
    for (cases) |c| {
        var bytes: std.ArrayList(u8) = .empty;
        try bytes.appendSlice(a, valid);
        const b = bytes.items;
        if (eql(c.name, "trimmed")) {
            bytes.shrinkRetainingCapacity(rom_mod.expected_size / 2);
        } else if (eql(c.name, "overdumped")) {
            try bytes.appendSlice(a, valid);
        } else if (eql(c.name, "headered")) {
            try bytes.insertSlice(a, 0, &([_]u8{0} ** rom_mod.copier_header_len));
        } else if (eql(c.name, "not a Game Boy ROM")) {
            @memset(b, 0xAA);
        } else if (eql(c.name, "another game")) {
            @memset(b[h.title..][0..h.title_len], 0);
            @memcpy(b[h.title..][0.."TETRIS".len], "TETRIS");
            b[h.checksum] = rom_mod.computeHeaderChecksum(b);
        } else if (eql(c.name, "corrupt header")) {
            b[h.cart_type] +%= 1;
        } else if (eql(c.name, "size byte")) {
            b[h.rom_size] = 0x05;
            b[h.checksum] = rom_mod.computeHeaderChecksum(b);
        } else if (eql(c.name, "colourised")) {
            b[h.cgb_flag] = 0x80;
            b[h.checksum] = rom_mod.computeHeaderChecksum(b);
        }

        n += 1;
        const dir_path = try std.fmt.allocPrint(a, "{s}/{d}", .{ workdir, n });
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{ .open_options = .{ .iterate = true } });
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "in.gb", .data = bytes.items });
        if (eql(c.name, "output links to the input")) try dir.symLink(io, "in.gb", "link.sfc", .{});

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ exe, "in.gb" });
        if (c.out) |o| try argv.appendSlice(a, &.{ "-o", o });
        const res = try std.process.run(a, io, .{ .argv = argv.items, .cwd = .{ .path = dir_path } });

        var why: ?[]const u8 = null;
        if (res.term != .exited or res.term.exited != 1) {
            why = try std.fmt.allocPrint(a, "ended {any}, not exit 1", .{res.term});
        } else if (std.mem.indexOf(u8, res.stderr, c.needle) == null) {
            why = try std.fmt.allocPrint(a, "the message does not say \"{s}\"", .{c.needle});
        } else if (c.out == null and std.mem.indexOf(u8, res.stderr, &sha_hex) == null) {
            why = "the message does not name the expected SHA-1";
        } else if (try leftBehind(a, io, dir, c.out != null and !eql(c.out.?, "in.gb"))) |name| {
            why = try std.fmt.allocPrint(a, "it left {s} behind", .{name});
        }
        if (why) |w| {
            try out.print("FAIL  binary refusal    {s}: {s}\n{s}", .{ c.name, w, res.stderr });
            ok = false;
        }
    }
    if (ok) try out.print("ok    binary refusal    {d} refusals: each exits 1, says why, and writes nothing\n", .{cases.len});
    return ok;
}

/// A file in `dir` other than the input (and the link the case made), or null.
fn leftBehind(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, has_link: bool) !?[]const u8 {
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (eql(e.name, "in.gb")) continue;
        if (has_link and eql(e.name, "link.sfc")) continue;
        return try a.dupe(u8, e.name);
    }
    return null;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
