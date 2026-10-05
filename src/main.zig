//! `m2snes`, the builder a player downloads (release Step 6): their own
//! Metroid II ROM in, the SNES ROM out. It is the whole pipeline -- the door
//! crawl, the conversion and the inject, `builder.build` -- and the only one:
//! `zig build rom` runs this binary too, so what a player runs is what the gate
//! grades.
//!
//! The ROM arrives only as an argument. Nothing in this binary's import graph
//! carries a configure-time ROM path (`builder_options` in build.zig).

const std = @import("std");
const version_info = @import("version_info");
const rom_mod = @import("rom.zig");
const builder = @import("builder.zig");
const crawl = @import("crawl.zig");
const inject = @import("snes_inject.zig");
const layout = @import("snes_layout.zig");
const warp = @import("warp.zig");

/// The one-line form of the notice in the README.
const trademark_line = "Metroid and Nintendo are trademarks of Nintendo; this project is not affiliated with or endorsed by Nintendo.";

const usage =
    \\usage: m2snes <metroid2.gb> [-o out.sfc] [--sym] [--debug] [--jobs N]
    \\
    \\Builds a SNES ROM from your own dump of Metroid II: Return of Samus.
    \\Nothing in this program is game data; your ROM is the only source.
    \\
    \\  -o PATH     where to write the SNES ROM (default: m2snes.sfc beside your
    \\              ROM, or m2snes-debug.sfc with --debug)
    \\  --sym       also write the symbol file (PATH with .sym), for Mesen2
    \\  --debug     build the debug cart: in play, L+R+Start opens the debug
    \\              menu, which warps, gives items and sets up scenes for
    \\              testing. Not for a normal playthrough.
    \\  --jobs N    threads for the door crawl (default: one per CPU)
    \\  --version   print the version, and the commits it was built from
    \\  --help      print this
    \\
    \\Expected input: {s}
    \\          sha1 {x}
    \\
    \\{s}
    \\
;

const Args = struct {
    rom: []const u8,
    out: ?[]const u8 = null,
    sym: bool = false,
    debug: bool = false,
    jobs: usize = 0,
    /// Dev only, and not in `--help`: read the crawl from DIR if it is there,
    /// or write it there. `zig build rom` and the gate pass `build-out`.
    crawl_cache: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    // Streaming, not positional: a positional writer writes from offset 0,
    // so `m2snes … >> log` would overwrite the log rather than append.
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;

    const args = parseArgs(a, init.minimal.args, out) catch |e| switch (e) {
        error.Done => {
            try out.flush();
            return;
        },
        error.Usage => {
            try out.flush();
            std.process.exit(2);
        },
        else => return e,
    };

    const sfc_path = args.out orelse try std.fs.path.join(a, &.{
        std.fs.path.dirname(args.rom) orelse ".",
        if (args.debug) "m2snes-debug.sfc" else "m2snes.sfc",
    });
    const sym_path: ?[]const u8 = if (args.sym) try symPath(a, sfc_path) else null;

    // Before the crawl, so a wrong -o costs nothing. The ROM may be reached by
    // another spelling, a symlink or a hard link, so the files are compared,
    // not the paths.
    for ([_]?[]const u8{ sfc_path, sym_path }) |maybe| {
        const p = maybe orelse continue;
        if (try sameFile(io, args.rom, p)) refuse("{s} is your ROM; choose another output with -o", .{p});
    }

    var diag: rom_mod.Diagnosis = undefined;
    const rom = rom_mod.ingestFile(a, io, args.rom, &diag) catch refuse("{s}", .{diag.message});

    const walked = try crawlDoors(a, io, rom.bytes, args);

    var inject_diag: inject.Diagnosis = .{};
    const built = builder.build(a, rom.bytes, .{
        .debug = args.debug,
        .walked = walked,
        .diag = &inject_diag,
    }) catch |e| {
        if (inject_diag.message.len == 0) return e;
        if (inject_diag.class) |c| refuse("{s}\n  class {s}: {d} bytes reserved at ${X:0>6}", .{
            inject_diag.message, c.label(), layout.reserved[@intFromEnum(c)], inject.snesAddr(layout.regionStart(c)),
        });
        refuse("{s}", .{inject_diag.message});
    };

    try writeAtomic(io, sfc_path, built.rom.bytes);
    if (sym_path) |p| try writeAtomic(io, p, built.sym);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(built.rom.bytes, &digest, .{});
    try out.print("wrote {s}\n", .{sfc_path});
    if (sym_path) |p| try out.print("wrote {s}\n", .{p});
    try out.print("sha1  {x}\n", .{&digest});
    if (args.debug) try out.print("      the debug cart: L+R+Start in play opens the debug menu\n", .{});
    try out.flush();
}

fn parseArgs(a: std.mem.Allocator, argv: std.process.Args, out: *std.Io.Writer) !Args {
    // The allocating iterator, which Windows needs. Never deinit: `a` is the
    // arena, and the arguments returned point into its buffer.
    var it = try argv.iterateAllocator(a);
    _ = it.next();
    var args: Args = .{ .rom = "" };
    var rom: ?[]const u8 = null;
    var any = false;
    while (it.next()) |arg| {
        any = true;
        if (eql(arg, "--help") or eql(arg, "-h")) {
            try printUsage(out);
            return error.Done;
        } else if (eql(arg, "--version")) {
            try out.print("m2snes {s} (commit {s}, audio shim {s})\n", .{ version_info.version, version_info.commit, version_info.shim_commit });
            return error.Done;
        } else if (eql(arg, "-o")) {
            args.out = try a.dupe(u8, it.next() orelse return usageError(out, "-o needs a path"));
        } else if (eql(arg, "--sym")) {
            args.sym = true;
        } else if (eql(arg, "--debug")) {
            args.debug = true;
        } else if (eql(arg, "--jobs")) {
            const n = it.next() orelse return usageError(out, "--jobs needs a number");
            args.jobs = std.fmt.parseInt(usize, n, 10) catch return usageError(out, "--jobs needs a number");
            if (args.jobs == 0) return usageError(out, "--jobs needs a number above 0");
        } else if (eql(arg, "--crawl-cache")) {
            args.crawl_cache = try a.dupe(u8, it.next() orelse return usageError(out, "--crawl-cache needs a directory"));
        } else if (arg.len > 1 and arg[0] == '-') {
            try out.print("m2snes: unknown option {s}\n\n", .{arg});
            return usageError(out, null);
        } else if (rom != null) {
            return usageError(out, "give one ROM");
        } else {
            rom = try a.dupe(u8, arg);
        }
    }
    if (!any) {
        try printUsage(out);
        return error.Usage;
    }
    args.rom = rom orelse return usageError(out, "give the path to your Metroid II ROM");
    return args;
}

fn printUsage(out: *std.Io.Writer) !void {
    try out.print(usage, .{ rom_mod.expected_revision, &rom_mod.expected_sha1, trademark_line });
}

fn usageError(out: *std.Io.Writer, why: ?[]const u8) error{ Usage, WriteFailed } {
    if (why) |w| try out.print("m2snes: {s}\n\n", .{w});
    try printUsage(out);
    return error.Usage;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

/// `out.sfc` -> `out.sym`; any other name gets `.sym` added.
fn symPath(a: std.mem.Allocator, sfc: []const u8) ![]const u8 {
    const stem = if (std.ascii.endsWithIgnoreCase(sfc, ".sfc")) sfc[0 .. sfc.len - 4] else sfc;
    return std.mem.concat(a, u8, &.{ stem, ".sym" });
}

/// Whether `other` is the file at `rom`. `Stat` has no device number, so a
/// match is the inode (the file index on Windows) with the same size and
/// modification time; a link to the ROM shares all three.
fn sameFile(io: std.Io, rom: []const u8, other: []const u8) !bool {
    const cwd = std.Io.Dir.cwd();
    const r = cwd.statFile(io, rom, .{}) catch return false; // ingest says why
    const o = cwd.statFile(io, other, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    return r.inode == o.inode and r.size == o.size and r.mtime.nanoseconds == o.mtime.nanoseconds;
}

/// Written beside `path` and renamed over it, so a failed run never leaves a
/// partial file.
fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);
}

fn crawlDoors(a: std.mem.Allocator, io: std.Io, rom: []const u8, args: Args) ![]const warp.WalkedDoor {
    var name_buf: [64]u8 = undefined;
    const cached: ?[]const u8 = if (args.crawl_cache) |dir|
        try std.fs.path.join(a, &.{ dir, warp.crawlName(&name_buf, rom) })
    else
        null;
    if (cached) |p| {
        if (std.Io.Dir.cwd().readFileAlloc(io, p, a, .limited(16 << 20))) |text| {
            return warp.parseWalked(a, text);
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        }
    }

    progress_tty = std.Io.File.stderr().isTty(io) catch false;
    std.debug.print("crawl: walking every door on the Game Boy, about a minute...\n", .{});
    const t0 = std.Io.Clock.awake.now(io);
    const w = try crawl.walk(a, rom, .{ .jobs = args.jobs, .progress = &progress });
    const dt = t0.durationTo(std.Io.Clock.awake.now(io));
    if (progress_tty) std.debug.print("\n", .{});
    std.debug.print("crawl: {d} doors in {d} s\n", .{ w.doors.len, @divTrunc(dt.toMilliseconds(), 1000) });

    if (cached) |p| {
        var text: std.Io.Writer.Allocating = .init(a);
        try warp.formatWalked(&text.writer, w.doors);
        try std.Io.Dir.cwd().createDirPath(io, args.crawl_cache.?);
        try writeAtomic(io, p, text.written());
    }
    return w.doors;
}

/// Whether stderr is a terminal: there the progress line rewrites itself,
/// elsewhere (a CI log) it prints a line per hundred rooms.
var progress_tty = false;
var progress_last: usize = 0;

fn progress(s: crawl.Status) void {
    if (progress_tty) {
        std.debug.print("\rcrawl: {d} of {d} rooms, {d} doors", .{ s.done, s.queued, s.doors });
    } else if (s.done >= progress_last + 100) {
        progress_last = s.done - s.done % 100;
        std.debug.print("crawl: {d} of {d} rooms, {d} doors\n", .{ s.done, s.queued, s.doors });
    }
}

/// Every refusal: the reason on stderr, exit 1, nothing written.
fn refuse(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("m2snes: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
