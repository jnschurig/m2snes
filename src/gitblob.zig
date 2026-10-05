//! Blobs out of a git object store by SHA, through one long-lived
//! `git cat-file --batch` (release Step 9).
//!
//! The pre-commit policy reads the blobs a commit stages, and the pre-push
//! audit the blobs a push sends. Both are short lists named by SHA, so this
//! asks for one blob at a time and reads its answer before asking for the
//! next: the pipe never holds more than one blob, and neither side can block
//! the other.

const std = @import("std");

pub const Reader = struct {
    child: std.process.Child,
    in: std.Io.File.Writer,
    out: std.Io.File.Reader,
    in_buf: [128]u8,
    out_buf: [64 * 1024]u8,

    /// `git -C <git_dir> cat-file --batch`. Call `init` on a `Reader` that
    /// stays where it is: the reader and writer point into it.
    pub fn init(self: *Reader, io: std.Io, git_dir: []const u8) !void {
        self.child = try std.process.spawn(io, .{
            .argv = &.{ "git", "-C", git_dir, "cat-file", "--batch" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        self.in = self.child.stdin.?.writerStreaming(io, &self.in_buf);
        self.out = self.child.stdout.?.readerStreaming(io, &self.out_buf);
    }

    /// The blob's bytes, owned by the caller. A SHA the store does not hold,
    /// or one naming something other than a blob, is an error.
    pub fn read(self: *Reader, gpa: std.mem.Allocator, sha: []const u8) ![]u8 {
        try self.in.interface.print("{s}\n", .{sha});
        try self.in.interface.flush();
        const r = &self.out.interface;
        const header = (try r.takeDelimiter('\n')) orelse return error.GitClosed;
        var f = std.mem.tokenizeScalar(u8, header, ' ');
        _ = f.next() orelse return error.BadHeader;
        const kind = f.next() orelse return error.BadHeader;
        if (std.mem.eql(u8, kind, "missing")) return error.MissingObject;
        const size = try std.fmt.parseInt(usize, f.next() orelse return error.BadHeader, 10);
        if (!std.mem.eql(u8, kind, "blob")) {
            try r.discardAll(size + 1);
            return error.NotABlob;
        }
        const bytes = try r.readAlloc(gpa, size);
        errdefer gpa.free(bytes);
        try r.discardAll(1);
        return bytes;
    }

    /// Close git's input so it exits, and reap it.
    pub fn deinit(self: *Reader, io: std.Io) !void {
        self.child.stdin.?.close(io);
        self.child.stdin = null;
        const term = try self.child.wait(io);
        if (term != .exited or term.exited != 0) return error.GitFailed;
    }
};

test "a blob comes back by SHA, and a missing one is an error" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);

    const init_r = try std.process.run(gpa, io, .{ .argv = &.{ "git", "-C", dir, "init", "-q" } });
    gpa.free(init_r.stdout);
    gpa.free(init_r.stderr);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });
    const hashed = try std.process.run(gpa, io, .{ .argv = &.{ "git", "-C", dir, "hash-object", "-w", "a.txt" } });
    defer gpa.free(hashed.stdout);
    gpa.free(hashed.stderr);
    const sha = std.mem.trimEnd(u8, hashed.stdout, "\n");

    var r: Reader = undefined;
    try r.init(io, dir);
    const bytes = try r.read(gpa, sha);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("hello\n", bytes);
    try std.testing.expectError(error.MissingObject, r.read(gpa, "0123456789012345678901234567890123456789"));
    // Still answering after a miss.
    const again = try r.read(gpa, sha);
    defer gpa.free(again);
    try std.testing.expectEqualStrings("hello\n", again);
    try r.deinit(io);
}
