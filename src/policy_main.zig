//! `zig build policy [-- --staged]` -- the file policy on its own, ROM or no
//! ROM (release Step 9).
//!
//! `verify` runs the same check but needs the ROM for everything else it
//! does. This is the ROM-free entry point: CI runs it with no ROM at all, and
//! the pre-commit hook runs it with `--staged`. Without a ROM it enforces the
//! size ceiling and the forbidden paths and says the n-gram scan did not run.
//!
//! `--staged` checks only what the next commit adds: each blob
//! `git diff --cached` names, read from the index rather than the working
//! tree, because the index is what gets committed.

const std = @import("std");
const build_options = @import("build_options");
const policy = @import("policy.zig");
const gitblob = @import("gitblob.zig");
const rom_mod = @import("rom.zig");

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
    var staged = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--staged")) {
            staged = true;
        } else {
            std.debug.print("usage: zig build policy [-- --staged]\n", .{});
            std.process.exit(2);
        }
    }

    const cwd = std.Io.Dir.cwd();
    const rom: ?[]const u8 = if (build_options.rom_path.len == 0) null else try cwd.readFileAlloc(io, build_options.rom_path, a, .limited(rom_mod.expected_size * 4));

    var report: policy.Report = .{ .rom_scanned = rom != null };
    var what: []const u8 = undefined;
    if (staged) {
        what = "staged blobs";
        const index: ?policy.RomIndex = if (rom) |r| try policy.RomIndex.build(a, r) else null;
        try checkStaged(a, init.gpa, io, index, &report);
    } else {
        var root = try cwd.openDir(io, ".", .{ .iterate = true });
        defer root.close(io);
        report = try policy.check(a, io, root, rom);
        what = @tagName(report.mode);
    }

    if (report.ok()) {
        try out.print("policy: ok, {d} file(s), {d} KiB ({s})\n", .{ report.files_scanned, report.bytes_scanned / 1024, what });
    } else {
        try out.print("policy: {d} violation(s) ({s})\n", .{ report.violations.items.len, what });
        for (report.violations.items) |v| try out.print("  {s}: {s}\n", .{ v.path, v.detail });
    }
    if (!report.rom_scanned) try out.print("policy: not run: the ROM n-gram scan (M2_ROM is unset)\n", .{});
    try out.flush();
    if (!report.ok()) std.process.exit(1);
}

/// Every blob the index holds that HEAD does not: added, copied, modified,
/// renamed or retyped. Gitlinks (mode 160000) name a commit, not content.
fn checkStaged(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, index: ?policy.RomIndex, report: *policy.Report) !void {
    const diff = try std.process.run(a, io, .{ .argv = &.{
        "git", "diff", "--cached", "--raw", "-z", "--no-abbrev", "--no-renames", "--diff-filter=ACMT",
    } });
    if (diff.term != .exited or diff.term.exited != 0) {
        std.debug.print("policy: git diff --cached failed:\n{s}", .{diff.stderr});
        std.process.exit(1);
    }

    var blobs: gitblob.Reader = undefined;
    try blobs.init(io, ".");
    // `:<old mode> <new mode> <old sha> <new sha> <status>` NUL `<path>` NUL.
    var fields = std.mem.splitScalar(u8, diff.stdout, 0);
    while (fields.next()) |meta| {
        if (meta.len == 0) continue;
        const path = fields.next() orelse return error.BadDiff;
        var f = std.mem.tokenizeScalar(u8, meta, ' ');
        _ = f.next() orelse return error.BadDiff;
        const mode = f.next() orelse return error.BadDiff;
        _ = f.next() orelse return error.BadDiff;
        const sha = f.next() orelse return error.BadDiff;
        if (std.mem.eql(u8, mode, "160000")) continue;
        const bytes = try blobs.read(gpa, sha);
        defer gpa.free(bytes);
        try policy.checkBytes(a, path, bytes, index, report);
    }
    try blobs.deinit(io);
}
