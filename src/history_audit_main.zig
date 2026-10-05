//! `zig build history-audit -- <git-dir> [extra-sha...]` -- the tracked-file
//! policy (`src/policy.zig`) over every blob in a repository's history, not
//! just the working tree.
//!
//! Going public publishes history, so a ROM-derived file that was committed
//! once and deleted later is still a leak. This scans every object in
//! `<git-dir>` (a `git clone --mirror` is the intended input): every blob
//! reachable from every ref, plus whatever the extra SHAs reach. Those are
//! commits that no ref holds any more, such as the old tips of force-pushes,
//! fetched by SHA before the run.
//!
//! Each blob gets the same two checks as the working tree, through
//! `policy.checkBytes`. A hit reports the blob, the path it was committed at,
//! and the commits that introduced it, and the run exits non-zero.
//!
//! `-- <git-dir> --revs <rev-list args...>` (release Step 9) scans only the
//! blobs those revisions reach, for the pre-push hook: `<sha> --not
//! --remotes=<remote>` is every blob a push sends that the remote's branches
//! do not already hold.

const std = @import("std");
const build_options = @import("build_options");
const policy = @import("policy.zig");
const rom_mod = @import("rom.zig");
const gitblob = @import("gitblob.zig");

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
    const git_dir = args.next() orelse {
        std.debug.print("usage: zig build history-audit -- <git-dir> [extra-sha...]\n", .{});
        std.process.exit(2);
    };
    var extras: std.ArrayList([]const u8) = .empty;
    var revs: ?std.ArrayList([]const u8) = null;
    while (args.next()) |arg| {
        if (revs) |*r| {
            try r.append(a, arg);
        } else if (std.mem.eql(u8, arg, "--revs")) {
            revs = .empty;
        } else {
            try extras.append(a, arg);
        }
    }
    if (revs != null and (extras.items.len != 0 or revs.?.items.len == 0)) {
        std.debug.print("usage: zig build history-audit -- <git-dir> --revs <rev-list args...>\n", .{});
        std.process.exit(2);
    }

    if (build_options.rom_path.len == 0) {
        std.debug.print("history-audit: no ROM configured (set M2_ROM; see docs/setup.md); the ROM scan is the point\n", .{});
        std.process.exit(1);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, build_options.rom_path, a, .limited(rom_mod.expected_size * 4));
    var index = try policy.RomIndex.build(a, rom);
    defer index.deinit(a);

    if (revs) |r| return auditRevs(a, init.gpa, io, git_dir, r.items, index, out);

    // An extra SHA the repository does not hold would otherwise be skipped
    // without a word, which is the failure this tool exists to rule out.
    for (extras.items) |sha| {
        const r = try git(a, io, git_dir, &.{ "cat-file", "-e", sha });
        if (r.term != .exited or r.term.exited != 0) {
            std.debug.print("history-audit: {s} is not in {s}; fetch it by SHA first\n", .{ sha, git_dir });
            std.process.exit(1);
        }
    }

    // Blob -> the first path it was committed at, from every ref and extra.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "rev-list", "--objects", "--all", "--filter=object:type=blob" });
    try argv.appendSlice(a, extras.items);
    const listed = try git(a, io, git_dir, argv.items);
    if (listed.term != .exited or listed.term.exited != 0) {
        std.debug.print("history-audit: git rev-list failed in {s}:\n{s}", .{ git_dir, listed.stderr });
        std.process.exit(1);
    }
    var paths: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, listed.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 40) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const gop = try paths.getOrPut(a, line[0..sp]);
        if (!gop.found_existing) gop.value_ptr.* = line[sp + 1 ..];
    }

    // Every object in the store, so a blob no ref reaches is scanned too
    // (labelled as such) rather than trusted.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "git", "-C", git_dir, "cat-file", "--batch-all-objects", "--unordered", "--batch=%(objectname) %(objecttype) %(objectsize)" },
        .stdout = .pipe,
        .stderr = .inherit,
    });
    var rbuf: [64 * 1024]u8 = undefined;
    var rdr = child.stdout.?.readerStreaming(io, &rbuf);
    const r = &rdr.interface;

    var report: policy.Report = .{ .rom_scanned = true };
    var hit_shas: std.ArrayList([]const u8) = .empty;
    var unreachable_blobs: usize = 0;
    while (try r.takeDelimiter('\n')) |header| {
        var f = std.mem.tokenizeScalar(u8, header, ' ');
        const sha = try a.dupe(u8, f.next() orelse return error.BadHeader);
        const kind = f.next() orelse return error.BadHeader;
        const size = try std.fmt.parseInt(usize, f.next() orelse return error.BadHeader, 10);
        if (!std.mem.eql(u8, kind, "blob")) {
            try r.discardAll(size + 1);
            continue;
        }
        const bytes = try r.readAlloc(init.gpa, size);
        defer init.gpa.free(bytes);
        try r.discardAll(1);

        const path = paths.get(sha) orelse blk: {
            unreachable_blobs += 1;
            break :blk "(no ref or extra reaches this blob)";
        };
        const before = report.violations.items.len;
        try policy.checkBytes(a, path, bytes, index, &report);
        for (report.violations.items[before..]) |_| try hit_shas.append(a, sha);
    }
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.debug.print("history-audit: git cat-file failed in {s}\n", .{git_dir});
        std.process.exit(1);
    }

    try out.print("history-audit: {d} blobs ({d} bytes) in {s}, {d} extra SHA(s), {d} blob(s) no ref reaches\n", .{
        report.files_scanned, report.bytes_scanned, git_dir, extras.items.len, unreachable_blobs,
    });
    for (report.violations.items, hit_shas.items) |v, sha| {
        try out.print("  HIT {s} blob {s} at {s}: {s}\n", .{ @tagName(v.kind), sha, v.path, v.detail });
        const find = try std.mem.concat(a, u8, &.{ "--find-object=", sha });
        var log_argv: std.ArrayList([]const u8) = .empty;
        try log_argv.appendSlice(a, &.{ "log", "--all", "--format=%h %ad %s", "--date=short", find });
        try log_argv.appendSlice(a, extras.items);
        const log = try git(a, io, git_dir, log_argv.items);
        var commits = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log.stdout, "\n"), '\n');
        while (commits.next()) |c| try out.print("      in {s}\n", .{c});
    }
    if (report.ok()) {
        try out.print("history-audit: ok, no hits. A tripwire, not a legal proof: see src/policy.zig.\n", .{});
    }
    try out.flush();
    if (!report.ok()) std.process.exit(1);
}

/// The blobs `rev-list --objects <revs>` reaches, each once, through the
/// policy. A push audit: short lists, so one blob at a time.
fn auditRevs(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, git_dir: []const u8, revs: []const []const u8, index: policy.RomIndex, out: *std.Io.Writer) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "rev-list", "--objects", "--filter=object:type=blob" });
    try argv.appendSlice(a, revs);
    const listed = try git(a, io, git_dir, argv.items);
    if (listed.term != .exited or listed.term.exited != 0) {
        std.debug.print("history-audit: git rev-list failed in {s}:\n{s}", .{ git_dir, listed.stderr });
        std.process.exit(1);
    }

    var blobs: gitblob.Reader = undefined;
    try blobs.init(io, git_dir);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var report: policy.Report = .{ .rom_scanned = true };
    var hit_shas: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, listed.stdout, '\n');
    while (lines.next()) |line| {
        // Commits come back bare; blobs as `<sha> <path>`.
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const sha = line[0..sp];
        if ((try seen.getOrPut(a, sha)).found_existing) continue;
        const bytes = try blobs.read(gpa, sha);
        defer gpa.free(bytes);
        const before = report.violations.items.len;
        try policy.checkBytes(a, line[sp + 1 ..], bytes, index, &report);
        for (report.violations.items[before..]) |_| try hit_shas.append(a, sha);
    }
    try blobs.deinit(io);

    const shown = try std.mem.join(a, " ", revs);
    try out.print("history-audit: {d} new blob(s) ({d} bytes) in {s}\n", .{ report.files_scanned, report.bytes_scanned, shown });
    for (report.violations.items, hit_shas.items) |v, sha| {
        try out.print("  HIT {s} blob {s} at {s}: {s}\n", .{ @tagName(v.kind), sha, v.path, v.detail });
    }
    if (report.ok()) try out.print("history-audit: ok, no hits\n", .{});
    try out.flush();
    if (!report.ok()) std.process.exit(1);
}

fn git(a: std.mem.Allocator, io: std.Io, git_dir: []const u8, args: []const []const u8) !std.process.RunResult {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{ "git", "-C", git_dir }, args });
    return std.process.run(a, io, .{ .argv = argv });
}
