//! Tracked-file policy check: a hygiene gate against committing anything
//! derived from the user's ROM (Step 1).
//!
//! This is deliberately *not* a legal proof, and its output says so. It is a
//! tripwire for the ordinary failure — a debug dump written into the source
//! tree and swept up by `git add -A` — which is the way proprietary bytes
//! actually get committed in practice.
//!
//! Three checks (the first added in release Step 9):
//!
//!   0. **Forbidden paths.** Nothing at a ROM, cart or save file name, or under
//!      a directory `.gitignore` reserves for ROM-derived files
//!      (`forbiddenPath`), whatever its size or bytes.
//!   1. **Size ceiling.** No file in the working tree above `size_ceiling` that
//!      looks binary. Everything this repository legitimately tracks is source,
//!      documentation, or a small fixture; the assembled engine image (Step 11)
//!      is the one deliberate exception and is allow-listed by path.
//!   2. **N-gram scan.** When the ROM is available, every `window` -byte
//!      substring of every file is checked against the set of ROM windows.
//!      Low-entropy windows (long runs of one byte, which ROM padding is full
//!      of) are excluded, or every file containing 32 zero bytes would match.
//!
//! **What it scans.** The set that matters is "what could end up in the
//! repository": tracked files, plus untracked files git would pick up. That is
//! exactly `git ls-files --cached --others --exclude-standard`, and it is what
//! this uses when the tree is a git repository.
//!
//! An earlier version walked the raw working tree instead, on the reasoning
//! that it catches a dump before it is ever staged and needs no subprocess.
//! The first half still holds - `--others` covers unstaged files - but the
//! rest did not survive contact: it cannot tell a deliberately ignored local
//! ROM from a leak, and `docs/setup.md` invites users to keep a ROM beside the
//! repository. The ignore rules are the declaration of intent that separates
//! the two, so honouring them is the check being *more* correct, not laxer.
//! A file git would ignore cannot be committed by accident, which is the
//! failure this exists to catch.
//!
//! When git is unavailable or this is not a repository, it falls back to
//! walking the tree with `skip_dirs`, and the report says which mode ran -
//! a gate that silently changed what it checks would be worse than either.

const std = @import("std");

/// Files larger than this are only allowed if they are plainly text.
pub const size_ceiling: usize = 64 * 1024;

/// Substring length for the ROM scan. At 32 bytes an accidental match between
/// unrelated content is not a practical concern; the real false-positive risk
/// is repetition, handled by `isLowEntropy`.
pub const window: usize = 32;

/// Fallback only: used when git is unavailable, since git's own ignore rules
/// cover this in the normal path. Mirrors the directory entries in
/// `.gitignore`; anything here is ignored, generated, or third-party.
pub const skip_dirs = [_][]const u8{
    ".git", ".zig-cache", "zig-out", "vendor", "extracted", "reference", "build-out",
};

/// Paths allowed to exceed `size_ceiling` while being binary. Each entry needs a
/// reason: this list is the only way proprietary-looking bytes can pass, so it
/// should stay short and every addition should be arguable.
pub const large_binary_allowlist = [_]struct { path: []const u8, why: []const u8 }{
    // Step 11 commits the asar-assembled engine image. It is our own original
    // 65816 code, assembled at dev time so end users need no assembler.
    .{ .path = "engine/engine.bin", .why = "our own assembled 65816 engine image (Step 11)" },
};

/// Paths nothing may be committed at, whatever the bytes: the user's ROM
/// under any name, a cart we build, a save, and the directories `.gitignore`
/// keeps ROM-derived or fetched files in. Ignored files never reach the scan,
/// so this catches the two ways past `.gitignore`: `git add -f`, and an edit
/// to `.gitignore` itself. Extensions match without regard to case.
pub const forbidden_extensions = [_][]const u8{ ".gb", ".gbc", ".sfc", ".smc", ".srm" };
pub const forbidden_dirs = [_][]const u8{ "extracted/", "reference/", "build-out/", "vendor/" };

/// The rule `path` breaks, or null.
pub fn forbiddenPath(path: []const u8) ?[]const u8 {
    for (forbidden_dirs) |d| {
        if (std.mem.startsWith(u8, path, d)) return d;
    }
    const base = std.fs.path.basename(path);
    for (forbidden_extensions) |ext| {
        if (base.len > ext.len and std.ascii.endsWithIgnoreCase(base, ext)) return ext;
    }
    return null;
}

pub const Violation = struct {
    path: []const u8,
    kind: enum { forbidden_path, oversized_binary, rom_bytes },
    detail: []const u8,
};

pub const ScanMode = enum {
    /// `git ls-files --cached --others --exclude-standard`: what could be
    /// committed.
    git_index,
    /// Raw working-tree walk. Broader, and will flag ignored local files.
    working_tree,
};

pub const Report = struct {
    mode: ScanMode = .working_tree,
    files_scanned: usize = 0,
    bytes_scanned: usize = 0,
    /// Null when no ROM was available; the n-gram scan did not run.
    rom_scanned: bool = false,
    violations: std.ArrayList(Violation) = .empty,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.violations.items) |v| {
            allocator.free(v.path);
            allocator.free(v.detail);
        }
        self.violations.deinit(allocator);
    }

    pub fn ok(self: Report) bool {
        return self.violations.items.len == 0;
    }
};

/// A window with fewer than this many distinct byte values is treated as
/// structureless and excluded from the ROM index. Runs of `$00`/`$FF` padding,
/// and the long uniform stretches in tile data, would otherwise match ordinary
/// files.
const min_distinct_bytes: usize = 5;

fn isLowEntropy(bytes: []const u8) bool {
    var seen = [_]bool{false} ** 256;
    var distinct: usize = 0;
    for (bytes) |b| {
        if (!seen[b]) {
            seen[b] = true;
            distinct += 1;
            if (distinct >= min_distinct_bytes) return false;
        }
    }
    return true;
}

fn hashWindow(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// The set of high-entropy ROM windows, for membership testing.
pub const RomIndex = struct {
    set: std.AutoHashMapUnmanaged(u64, void),
    rom: []const u8,

    pub fn build(allocator: std.mem.Allocator, rom: []const u8) !RomIndex {
        var set: std.AutoHashMapUnmanaged(u64, void) = .empty;
        errdefer set.deinit(allocator);
        if (rom.len >= window) {
            var i: usize = 0;
            while (i + window <= rom.len) : (i += 1) {
                const w = rom[i..][0..window];
                if (isLowEntropy(w)) continue;
                try set.put(allocator, hashWindow(w), {});
            }
        }
        return .{ .set = set, .rom = rom };
    }

    pub fn deinit(self: *RomIndex, allocator: std.mem.Allocator) void {
        self.set.deinit(allocator);
    }

    /// Offset of the first window in `bytes` that also occurs in the ROM, or
    /// null. A hash hit is confirmed against the ROM bytes before reporting, so
    /// a collision cannot produce a false accusation.
    pub fn firstMatch(self: RomIndex, bytes: []const u8) ?usize {
        if (bytes.len < window) return null;
        var i: usize = 0;
        while (i + window <= bytes.len) : (i += 1) {
            const w = bytes[i..][0..window];
            if (isLowEntropy(w)) continue;
            if (self.set.contains(hashWindow(w))) {
                if (std.mem.indexOf(u8, self.rom, w) != null) return i;
            }
        }
        return null;
    }
};

fn looksBinary(bytes: []const u8) bool {
    const head = bytes[0..@min(bytes.len, 8192)];
    return std.mem.indexOfScalar(u8, head, 0) != null;
}

fn isAllowlisted(path: []const u8) ?[]const u8 {
    for (large_binary_allowlist) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.why;
    }
    return null;
}

fn shouldSkipDir(name: []const u8) bool {
    for (skip_dirs) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

/// Walk `root`, applying both checks. `rom` may be null, in which case only the
/// size ceiling is enforced and `Report.rom_scanned` stays false.
pub fn check(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    rom: ?[]const u8,
) !Report {
    var report: Report = .{};
    errdefer report.deinit(allocator);

    var index: ?RomIndex = if (rom) |r| try RomIndex.build(allocator, r) else null;
    defer if (index) |*ix| ix.deinit(allocator);
    report.rom_scanned = index != null;

    if (try gitFileList(allocator, io)) |list| {
        defer allocator.free(list);
        report.mode = .git_index;
        var it = std.mem.splitScalar(u8, list, '\n');
        while (it.next()) |path| {
            if (path.len == 0) continue;
            try scanOne(allocator, io, root, path, index, &report);
        }
    } else {
        report.mode = .working_tree;
        // SelectiveWalker rather than Walker: descending is opt-in, which is
        // how `skip_dirs` is enforced. Walker enters every directory
        // unconditionally.
        var walker = try root.walkSelectively(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (!shouldSkipDir(entry.basename)) try walker.enter(io, entry);
                    continue;
                },
                .file => {},
                else => continue,
            }
            try scanOne(allocator, io, root, entry.path, index, &report);
        }
    }

    return report;
}

/// The files git would consider part of the repository: tracked, plus untracked
/// and not ignored. Null when this is not a git repository or git is not
/// available, which puts the caller on the working-tree fallback.
fn gitFileList(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z" },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;

    var buf: [4096]u8 = undefined;
    var rdr = child.stdout.?.readerStreaming(io, &buf);
    const raw = rdr.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024)) catch {
        _ = child.wait(io) catch {};
        return null;
    };
    errdefer allocator.free(raw);

    const term = child.wait(io) catch {
        allocator.free(raw);
        return null;
    };
    if (term != .exited or term.exited != 0) {
        allocator.free(raw);
        return null;
    }
    // -z separates with NUL so paths containing newlines survive; normalise to
    // newlines for the caller's split.
    for (raw) |*c| {
        if (c.* == 0) c.* = '\n';
    }
    return raw;
}

fn scanOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    path: []const u8,
    index: ?RomIndex,
    report: *Report,
) !void {
    const bytes = root.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch return;
    defer allocator.free(bytes);
    try checkBytes(allocator, path, bytes, index, report);
}

/// Both checks on one file's contents, wherever they came from: the working
/// tree here, or a blob in git history (`history_audit_main.zig`).
pub fn checkBytes(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    index: ?RomIndex,
    report: *Report,
) !void {
    report.files_scanned += 1;
    report.bytes_scanned += bytes.len;

    if (forbiddenPath(path)) |rule| {
        try report.violations.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .kind = .forbidden_path,
            .detail = try std.fmt.allocPrint(allocator, "nothing is committed under `{s}` (see .gitignore)", .{rule}),
        });
    }

    if (bytes.len > size_ceiling and looksBinary(bytes) and isAllowlisted(path) == null) {
        try report.violations.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .kind = .oversized_binary,
            .detail = try std.fmt.allocPrint(allocator, "{d} bytes of binary content, over the {d}-byte ceiling and not allow-listed", .{ bytes.len, size_ceiling }),
        });
    }

    if (index) |ix| {
        if (ix.firstMatch(bytes)) |off| {
            try report.violations.append(allocator, .{
                .path = try allocator.dupe(u8, path),
                .kind = .rom_bytes,
                .detail = try std.fmt.allocPrint(allocator, "offset {d} begins a {d}-byte run that also occurs in the ROM", .{ off, window }),
            });
        }
    }
}

test "low-entropy windows are excluded" {
    const zeros = [_]u8{0} ** window;
    try std.testing.expect(isLowEntropy(&zeros));

    var varied: [window]u8 = undefined;
    for (&varied, 0..) |*b, i| b.* = @intCast(i);
    try std.testing.expect(!isLowEntropy(&varied));
}

test "rom index finds a real substring and ignores unrelated text" {
    const allocator = std.testing.allocator;

    var rom: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x4d32);
    prng.random().bytes(&rom);

    var ix = try RomIndex.build(allocator, &rom);
    defer ix.deinit(allocator);

    // A run lifted straight out of the ROM must be caught.
    try std.testing.expect(ix.firstMatch(rom[100..][0..window]) != null);

    // Ordinary source text must not be.
    try std.testing.expect(ix.firstMatch("const std = @import(\"std\"); // nothing to see here") == null);
}

test "padding in a text file does not trip the scan" {
    const allocator = std.testing.allocator;
    var rom: [4096]u8 = .{0} ** 4096;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(rom[2048..]);

    var ix = try RomIndex.build(allocator, &rom);
    defer ix.deinit(allocator);

    const padded = [_]u8{0} ** 512;
    try std.testing.expect(ix.firstMatch(&padded) == null);
}

test "forbidden paths: the ROM's names, carts, saves and the ignored directories" {
    for ([_][]const u8{ "metroid2.gb", "roms/Metroid II.GB", "x.gbc", "build-out/m2snes.sfc", "m2snes.smc", "a/b.srm", "extracted/tiles.bin", "reference/x.txt", "vendor/asar/README", "build-out/crawl.txt" }) |p| {
        try std.testing.expect(forbiddenPath(p) != null);
    }
    // Our own symbol file, a Zig source, and names that only contain a rule.
    for ([_][]const u8{ "engine/engine.sym", "src/gb/cpu.zig", "docs/vendor/notes.md", ".gb", "src/gbc_palette.zig", "test/extracted/readme.md" }) |p| {
        try std.testing.expect(forbiddenPath(p) == null);
    }
}

test "checkBytes reports a forbidden path even for harmless bytes" {
    const allocator = std.testing.allocator;
    var report: Report = .{};
    defer report.deinit(allocator);
    try checkBytes(allocator, "notes.txt", "hello", null, &report);
    try std.testing.expect(report.ok());
    try checkBytes(allocator, "metroid2.gb", "hello", null, &report);
    try std.testing.expectEqual(@as(usize, 1), report.violations.items.len);
    try std.testing.expectEqual(.forbidden_path, report.violations.items[0].kind);
}
