//! `zig build release-verify` (release Step 14; Features 2 and 5): a release's
//! downloads, graded locally before James publishes it.
//!
//!   -- <vX.Y.Z>                  the tag's draft release (`gh release download`)
//!   -- --run <id>                a release workflow dry run's `release`
//!                                artifact (`gh run download`)
//!   -- --dir <dir> --commit <rev>  downloads already on disk, against <rev>
//!                                (fault checks, re-runs)
//!   [--pins <file>]              grade against this pin file instead of the
//!                                commit's (fault checks)
//!
//! In order, each check printed as an `ok`/`FAIL` line:
//!   - every archive against `SHA256SUMS`, which must list one archive per
//!     release target and nothing else;
//!   - each archive unpacked: the binary, LICENSE, THIRD-PARTY-NOTICES and
//!     README.txt, and nothing else;
//!   - a `zig build release` in a temporary `git worktree` of the release's
//!     commit, never the working tree, and each downloaded binary byte for
//!     byte against it (binaries, not archives: tar and zip carry times), and
//!     the other three files against the commit's;
//!   - the notes against `pins/cart.txt` at the commit and the commit itself;
//!   - the host's binary on the ROM, retail and debug, against those pins,
//!     and both Linux binaries the same way through `orbctl run` on macOS when
//!     OrbStack has a Linux machine, the other architecture's through
//!     `qemu-<arch>` in it (`not run:` otherwise).
//! Then one summary line, which James adds to the notes before publishing.
//!
//! The ROM never leaves the machine: the carts are hashed and deleted.

const std = @import("std");
const builtin = @import("builtin");
const release_options = @import("release_options");
const pin = @import("pin.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

const usage =
    \\usage: zig build release-verify -- <vX.Y.Z> [--pins <file>]
    \\       zig build release-verify -- --run <id> [--pins <file>]
    \\       zig build release-verify -- --dir <dir> --commit <rev> [--pins <file>]
    \\
;

/// The files beside the binary in every archive, and where each is in the tree.
const extras = [_]struct { name: []const u8, tree: []const u8 }{
    .{ .name = "LICENSE", .tree = "LICENSE" },
    .{ .name = "THIRD-PARTY-NOTICES", .tree = "THIRD-PARTY-NOTICES" },
    .{ .name = "README.txt", .tree = "dist/README.txt" },
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    var v: Verify = .{ .a = a, .io = io, .out = &stdout.interface };

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    // From build.zig: the Zig that runs this build, the ROM, a scratch dir.
    const zig = args.next() orelse return error.Usage;
    const rom_arg = args.next() orelse return error.Usage;
    const workdir_arg = args.next() orelse return error.Usage;

    var tag: ?[]const u8 = null;
    var run_id: ?[]const u8 = null;
    var dir_arg: ?[]const u8 = null;
    var commit_arg: ?[]const u8 = null;
    var pins_arg: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (eql(arg, "--run")) {
            run_id = args.next() orelse usageExit();
        } else if (eql(arg, "--dir")) {
            dir_arg = args.next() orelse usageExit();
        } else if (eql(arg, "--commit")) {
            commit_arg = args.next() orelse usageExit();
        } else if (eql(arg, "--pins")) {
            pins_arg = args.next() orelse usageExit();
        } else if (tag == null and arg.len > 0 and arg[0] != '-') {
            tag = arg;
        } else usageExit();
    }
    const modes = @as(u8, @intFromBool(tag != null)) + @intFromBool(run_id != null) + @intFromBool(dir_arg != null);
    if (modes != 1 or (dir_arg != null) != (commit_arg != null)) usageExit();

    const rom = try absolute(a, io, rom_arg);
    const workdir = try freshDir(a, io, workdir_arg);
    const pins_file = if (pins_arg) |p| try absolute(a, io, p) else null;

    // ---- The downloads, the commit and the notes ----------------------------
    var dl: []const u8 = undefined;
    var commit: []const u8 = undefined;
    var notes: ?[]const u8 = null;
    var label: []const u8 = undefined;
    if (tag) |t| {
        label = t;
        dl = try std.fs.path.join(a, &.{ workdir, "download" });
        commit = try v.must(&.{ "git", "rev-parse", "--verify", "--quiet", try std.fmt.allocPrint(a, "refs/tags/{s}^{{commit}}", .{t}) }, "no local tag; `git fetch origin tag <tag>` first");
        _ = try v.must(&.{ "gh", "release", "download", t, "--dir", dl }, "cannot download the release's assets");
        notes = try v.must(&.{ "gh", "release", "view", t, "--json", "body", "--jq", ".body" }, "cannot read the release's notes");
    } else if (run_id) |id| {
        label = try std.fmt.allocPrint(a, "run {s}", .{id});
        dl = try std.fs.path.join(a, &.{ workdir, "download" });
        const info = try v.must(&.{ "gh", "run", "view", id, "--json", "workflowName,conclusion,headSha", "--jq", ".workflowName + \" \" + .conclusion + \" \" + .headSha" }, "cannot read the run");
        var f = std.mem.tokenizeScalar(u8, info, ' ');
        const workflow = f.next() orelse "";
        const conclusion = f.next() orelse "";
        commit = f.next() orelse "";
        if (!eql(workflow, "release") or !eql(conclusion, "success"))
            die("run {s} is workflow \"{s}\", concluded \"{s}\": not a successful release run", .{ id, workflow, conclusion });
        _ = try v.must(&.{ "gh", "run", "download", id, "--name", "release", "--dir", dl }, "cannot download the run's `release` artifact");
        notes = try readFile(a, io, dl, "notes.md");
    } else {
        label = dir_arg.?;
        dl = try absolute(a, io, dir_arg.?);
        notes = readFile(a, io, dl, "notes.md") catch null;
    }
    if (commit_arg) |c| commit = c;
    commit = try v.must(&.{ "git", "rev-parse", "--verify", "--quiet", try std.fmt.allocPrint(a, "{s}^{{commit}}", .{commit}) }, "the commit is not in this clone; `git fetch` first");
    const short = commit[0..12];

    // ---- SHA256SUMS ----------------------------------------------------------
    const sums = readFile(a, io, dl, "SHA256SUMS") catch |e| die("no SHA256SUMS in {s}: {s}", .{ dl, @errorName(e) });
    const version = try v.checkSums(dl, sums);
    if (tag) |t| if (!eql(version, t)) v.fail("version", "the archives are named for {s}, not the tag {s}", .{ version, t });
    if (v.failures != 0) v.finish("the download is not intact, so nothing else was checked", .{});

    // ---- Unpack --------------------------------------------------------------
    const unpacked = try std.fs.path.join(a, &.{ workdir, "unpacked" });
    try std.Io.Dir.cwd().createDirPath(io, unpacked);
    var bins: [release_options.release_targets.len][]const u8 = undefined;
    for (release_options.release_targets, &bins) |t, *bin| {
        bin.* = try v.unpack(dl, unpacked, version, t);
    }

    // ---- The commit, built in a worktree, against the downloads --------------
    const src = try std.fs.path.join(a, &.{ workdir, "src" });
    _ = try v.must(&.{ "git", "worktree", "prune" }, "git worktree prune failed");
    _ = try v.must(&.{ "git", "worktree", "add", "--detach", "--quiet", src, commit }, "cannot add a worktree of the commit");
    defer removeWorktree(a, io, src);
    try v.out.print("..    build             zig build release in a worktree of {s}\n", .{short});
    try v.out.flush();
    const built = try std.process.run(a, io, .{ .argv = &.{ zig, "build", "release" }, .cwd = .{ .path = src } });
    if (built.term != .exited or built.term.exited != 0)
        die("zig build release at {s} failed:\n{s}", .{ short, built.stderr });
    for (release_options.release_targets, bins) |t, bin| {
        const ours = try std.fs.path.join(a, &.{ src, "zig-out", "release", t, exeName(t) });
        try v.compare(t, bin, ours, short);
        const dir = std.fs.path.dirname(bin).?;
        for (extras) |x| {
            try v.compare(t, try std.fs.path.join(a, &.{ dir, x.name }), try std.fs.path.join(a, &.{ src, x.tree }), short);
        }
    }

    // ---- The pins and the notes ----------------------------------------------
    const pins_path = pins_file orelse try std.fs.path.join(a, &.{ src, pin.cart_path });
    const pins_text = std.Io.Dir.cwd().readFileAlloc(io, pins_path, a, .limited(1 << 16)) catch |e| die("cannot read {s}: {s}", .{ pins_path, @errorName(e) });
    const want = pin.parse(pins_text) catch |e| die("{s}: {s}", .{ pins_path, @errorName(e) });
    if (notes) |n| {
        var missing: std.ArrayList([]const u8) = .empty;
        for ([_]pin.Kind{ .retail, .debug }) |k| {
            const hex = std.fmt.bytesToHex(want.get(k), .lower);
            if (std.mem.indexOf(u8, n, &hex) == null) try missing.append(a, try std.fmt.allocPrint(a, "the {s} pin {s}", .{ @tagName(k), &hex }));
        }
        if (std.mem.indexOf(u8, n, short) == null) try missing.append(a, try std.fmt.allocPrint(a, "the commit {s}", .{short}));
        if (missing.items.len == 0) {
            try v.ok("notes", "carry the retail and debug pins and the commit", .{});
        } else for (missing.items) |m| v.fail("notes", "do not carry {s}", .{m});
    } else try v.out.print("not run: notes            {s} has no notes.md\n", .{dl});

    // ---- The binaries on the ROM ---------------------------------------------
    var ran: std.ArrayList([]const u8) = .empty;
    const host = hostTarget();
    // OrbStack's Linux machine's architecture, if it has one.
    const orb_arch: ?[]const u8 = if (builtin.os.tag == .macos) orbArch(a, io) else null;
    for (release_options.release_targets, bins) |t, bin| {
        var prefix: []const []const u8 = &.{};
        if (host != null and eql(t, host.?)) {
            try v.checkVersion(t, bin, version, short);
        } else if (std.mem.indexOf(u8, t, "-linux") != null and builtin.os.tag == .macos) {
            const arch = orb_arch orelse {
                try v.out.print("not run: {s: <17} OrbStack has no Linux machine (`orb create ubuntu`)\n", .{t});
                continue;
            };
            const t_arch = t[0..std.mem.indexOfScalar(u8, t, '-').?];
            if (eql(t_arch, arch)) {
                prefix = &.{ "orbctl", "run" };
            } else {
                // Not through binfmt: OrbStack prefers Rosetta, which refuses
                // Zig's static x86_64 ELF ("rosetta error: bss_size overflow").
                const qemu = try std.fmt.allocPrint(a, "qemu-{s}", .{t_arch});
                if (!succeeds(a, io, &.{ "orbctl", "run", qemu, "-version" })) {
                    try v.out.print("not run: {s: <17} no {s} in OrbStack's {s} machine (`orb sudo apt install -y qemu-user`)\n", .{ t, qemu, arch });
                    continue;
                }
                prefix = try a.dupe([]const u8, &.{ "orbctl", "run", qemu });
            }
        } else {
            try v.out.print("not run: {s: <17} this host cannot run it; compared only\n", .{t});
            continue;
        }
        const wd = try std.fs.path.join(a, &.{ workdir, "run", t });
        try std.Io.Dir.cwd().createDirPath(io, wd);
        try v.out.print("..    {s: <17} retail and debug carts from your ROM (about a minute)\n", .{t});
        try v.out.flush();
        const graded = try pin.gradeAgainst(a, io, want, .{ .exe = bin, .rom = rom, .workdir = wd, .prefix = prefix }, t, v.out);
        if (graded) try ran.append(a, t) else v.failures += 1;
    }

    if (v.failures != 0) v.finish("{s}", .{label});
    var compared: std.ArrayList(u8) = .empty;
    for (release_options.release_targets, 0..) |t, i| {
        if (i != 0) try compared.appendSlice(a, ", ");
        try compared.appendSlice(a, t);
    }
    const ran_list = try std.mem.join(a, ", ", ran.items);
    try v.out.print("release-verify: ok: m2snes {s}, commit {s} | retail {x} | debug {x} | ran {s} | compared {s}\n", .{
        version, short, &want.get(.retail), &want.get(.debug), ran_list, compared.items,
    });
    try v.out.flush();
}

const Verify = struct {
    a: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    failures: usize = 0,

    fn ok(v: *Verify, label: []const u8, comptime fmt: []const u8, args: anytype) !void {
        try v.out.print("ok    {s: <17} ", .{label});
        try v.out.print(fmt ++ "\n", args);
        try v.out.flush();
    }

    fn fail(v: *Verify, label: []const u8, comptime fmt: []const u8, args: anytype) void {
        v.failures += 1;
        v.out.print("FAIL  {s: <17} ", .{label}) catch {};
        v.out.print(fmt ++ "\n", args) catch {};
        v.out.flush() catch {};
    }

    /// Prints the failure count and exits 1.
    fn finish(v: *Verify, comptime fmt: []const u8, args: anytype) noreturn {
        v.out.print("release-verify: FAIL: {d} check(s): ", .{v.failures}) catch {};
        v.out.print(fmt ++ "\n", args) catch {};
        v.out.flush() catch {};
        std.process.exit(1);
    }

    /// A command that must succeed: its stdout, trimmed. Anything else ends
    /// the run with `why` and the command's stderr.
    fn must(v: *Verify, argv: []const []const u8, why: []const u8) ![]const u8 {
        const r = try std.process.run(v.a, v.io, .{ .argv = argv });
        if (r.term != .exited or r.term.exited != 0) {
            v.out.flush() catch {};
            die("{s}: {s}\n{s}", .{ argv[0], why, r.stderr });
        }
        return std.mem.trim(u8, r.stdout, " \t\r\n");
    }

    /// Every archive against `SHA256SUMS`, which must name one per release
    /// target and nothing else. Returns the version the names carry.
    fn checkSums(v: *Verify, dl: []const u8, sums: []const u8) ![]const u8 {
        var listed: std.StringHashMapUnmanaged(void) = .empty;
        var version: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, sums, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            var f = std.mem.tokenizeAny(u8, line, " \t");
            const hex = f.next() orelse "";
            var name = f.next() orelse "";
            if (name.len > 0 and name[0] == '*') name = name[1..];
            if (hex.len != Sha256.digest_length * 2 or name.len == 0 or f.next() != null or std.mem.indexOfAny(u8, name, "/\\") != null) {
                v.fail("SHA256SUMS", "a malformed line: {s}", .{line});
                continue;
            }
            try listed.put(v.a, name, {});
            const t = targetOf(name) orelse {
                v.fail("SHA256SUMS", "lists {s}, which is not a release target's archive", .{name});
                continue;
            };
            const ver = name["m2snes-".len .. name.len - t.len - 1 - extension(t).len];
            if (version) |have| {
                if (!eql(have, ver)) v.fail("SHA256SUMS", "{s} is named for {s}, not {s}", .{ name, ver, have });
            } else version = ver;
            const bytes = readFile(v.a, v.io, dl, name) catch |e| {
                v.fail("SHA256SUMS", "{s}: {s}", .{ name, @errorName(e) });
                continue;
            };
            var got: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(bytes, &got, .{});
            const got_hex = std.fmt.bytesToHex(got, .lower);
            if (std.ascii.eqlIgnoreCase(&got_hex, hex)) {
                try v.ok("SHA256SUMS", "{s}", .{name});
            } else v.fail("SHA256SUMS", "{s} is {s}, not {s}", .{ name, &got_hex, hex });
        }
        const ver = version orelse {
            v.fail("SHA256SUMS", "lists no archive", .{});
            return "";
        };
        for (release_options.release_targets) |t| {
            const name = try archiveName(v.a, ver, t);
            if (!listed.contains(name)) v.fail("SHA256SUMS", "lists no archive for {s} ({s})", .{ t, name });
        }
        // An archive downloaded but not listed would be published unchecked.
        var dir = try std.Io.Dir.cwd().openDir(v.io, dl, .{ .iterate = true });
        defer dir.close(v.io);
        var it = dir.iterate();
        while (try it.next(v.io)) |e| {
            if (std.mem.startsWith(u8, e.name, "m2snes-") and !listed.contains(e.name))
                v.fail("SHA256SUMS", "does not list {s}", .{e.name});
        }
        return ver;
    }

    /// `t`'s archive, unpacked under `into`: the path of its binary. The
    /// archive must hold one directory of its own name, with the binary and
    /// the extras in it and nothing else.
    fn unpack(v: *Verify, dl: []const u8, into: []const u8, version: []const u8, t: []const u8) ![]const u8 {
        const name = try archiveName(v.a, version, t);
        const archive = try std.fs.path.join(v.a, &.{ dl, name });
        const argv: []const []const u8 = if (std.mem.endsWith(u8, name, ".zip"))
            &.{ "unzip", "-q", archive, "-d", into }
        else
            &.{ "tar", "-xzf", archive, "-C", into };
        _ = try v.must(argv, "cannot unpack the archive");
        const top = try std.fs.path.join(v.a, &.{ into, name[0 .. name.len - extension(t).len] });
        var dir = std.Io.Dir.cwd().openDir(v.io, top, .{ .iterate = true }) catch |e|
            die("{s} holds no directory {s}: {s}", .{ name, std.fs.path.basename(top), @errorName(e) });
        defer dir.close(v.io);
        var seen: usize = 0;
        var it = dir.iterate();
        while (try it.next(v.io)) |e| {
            const expected = eql(e.name, exeName(t)) or for (extras) |x| {
                if (eql(e.name, x.name)) break true;
            } else false;
            if (expected) seen += 1 else v.fail(t, "{s} holds {s}, which is not a release file", .{ name, e.name });
        }
        if (seen != extras.len + 1) v.fail(t, "{s} is missing files: it must hold {s}, LICENSE, THIRD-PARTY-NOTICES and README.txt", .{ name, exeName(t) });
        return std.fs.path.join(v.a, &.{ top, exeName(t) });
    }

    /// A downloaded file against the commit's, byte for byte.
    fn compare(v: *Verify, t: []const u8, got_path: []const u8, want_path: []const u8, short: []const u8) !void {
        const got = std.Io.Dir.cwd().readFileAlloc(v.io, got_path, v.a, .limited(64 << 20)) catch |e| {
            v.fail(t, "{s}: {s}", .{ got_path, @errorName(e) });
            return;
        };
        const want = std.Io.Dir.cwd().readFileAlloc(v.io, want_path, v.a, .limited(64 << 20)) catch |e| {
            v.fail(t, "{s}: {s}", .{ want_path, @errorName(e) });
            return;
        };
        const what = std.fs.path.basename(got_path);
        if (std.mem.eql(u8, got, want)) {
            if (eql(what, exeName(t))) {
                var d: [Sha256.digest_length]u8 = undefined;
                Sha256.hash(got, &d, .{});
                try v.ok(t, "{s} is byte-identical to {s}'s build (sha256 {x})", .{ what, short, d[0..8] });
            }
        } else v.fail(t, "{s} differs from {s}'s ({d} bytes, not {d})", .{ what, short, got.len, want.len });
    }

    /// The host's binary says the release's version and commit.
    fn checkVersion(v: *Verify, t: []const u8, bin: []const u8, version: []const u8, short: []const u8) !void {
        const r = try std.process.run(v.a, v.io, .{ .argv = &.{ bin, "--version" } });
        const want = try std.fmt.allocPrint(v.a, "m2snes {s} (commit {s},", .{ version[1..], short });
        if (r.term == .exited and r.term.exited == 0 and std.mem.startsWith(u8, r.stdout, want)) {
            try v.ok(t, "--version: {s}", .{std.mem.trim(u8, r.stdout, "\n")});
        } else v.fail(t, "--version printed \"{s}\", not \"{s} …\"", .{ std.mem.trim(u8, r.stdout, "\n"), want });
    }
};

/// The release target this binary was built for, if it is one.
fn hostTarget() ?[]const u8 {
    const name: []const u8 = switch (builtin.os.tag) {
        .macos => if (builtin.cpu.arch == .aarch64) "aarch64-macos" else return null,
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "x86_64-linux-musl",
            .aarch64 => "aarch64-linux-musl",
            else => return null,
        },
        .windows => if (builtin.cpu.arch == .x86_64) "x86_64-windows-gnu" else return null,
        else => return null,
    };
    for (release_options.release_targets) |t| if (eql(t, name)) return t;
    return null;
}

/// The architecture of OrbStack's default Linux machine (`uname -m`), or
/// null without OrbStack or a machine.
fn orbArch(a: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const r = std.process.run(a, io, .{ .argv = &.{ "orbctl", "run", "uname", "-m" } }) catch return null;
    if (r.term != .exited or r.term.exited != 0) return null;
    return std.mem.trim(u8, r.stdout, " \t\r\n");
}

fn succeeds(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const r = std.process.run(a, io, .{ .argv = argv }) catch return false;
    return r.term == .exited and r.term.exited == 0;
}

fn removeWorktree(a: std.mem.Allocator, io: std.Io, src: []const u8) void {
    const r = std.process.run(a, io, .{ .argv = &.{ "git", "worktree", "remove", "--force", src } }) catch |e| {
        std.debug.print("release-verify: could not remove the worktree {s}: {s}\n", .{ src, @errorName(e) });
        return;
    };
    if (r.term != .exited or r.term.exited != 0)
        std.debug.print("release-verify: could not remove the worktree {s}:\n{s}", .{ src, r.stderr });
}

fn exeName(t: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, t, "windows") != null) "m2snes.exe" else "m2snes";
}

fn extension(t: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, t, "windows") != null) ".zip" else ".tar.gz";
}

/// `m2snes-<version>-<target>.tar.gz` (`.zip` on Windows), as ci/package.sh
/// names it.
fn archiveName(a: std.mem.Allocator, version: []const u8, t: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "m2snes-{s}-{s}{s}", .{ version, t, extension(t) });
}

/// The release target an archive's name is for, or null.
fn targetOf(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "m2snes-")) return null;
    for (release_options.release_targets) |t| {
        const suffix_len = 1 + t.len + extension(t).len;
        if (name.len <= "m2snes-".len + suffix_len) continue;
        const tail = name[name.len - suffix_len ..];
        if (tail[0] == '-' and std.mem.startsWith(u8, tail[1..], t) and eql(tail[1 + t.len ..], extension(t))) return t;
    }
    return null;
}

fn readFile(a: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ dir, name });
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20));
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

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("release-verify: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usageExit() noreturn {
    std.debug.print(usage, .{});
    std.process.exit(2);
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

test "an archive's name gives its target, and nothing else does" {
    try std.testing.expectEqualStrings("aarch64-macos", targetOf("m2snes-v0.1.0-aarch64-macos.tar.gz").?);
    try std.testing.expectEqualStrings("x86_64-windows-gnu", targetOf("m2snes-v0.1.0-x86_64-windows-gnu.zip").?);
    try std.testing.expect(targetOf("m2snes-v0.1.0-x86_64-windows-gnu.tar.gz") == null);
    try std.testing.expect(targetOf("m2snes-v0.1.0-aarch64-windows-gnu.zip") == null);
    try std.testing.expect(targetOf("m2snes--aarch64-macos.tar.gz") == null);
    try std.testing.expect(targetOf("m2snes-aarch64-macos.tar.gz") == null);
    try std.testing.expect(targetOf("notes.md") == null);
}
