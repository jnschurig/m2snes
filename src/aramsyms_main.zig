//! `zig build aramsyms` — write `engine/audio/aram_data.inc`.
//!
//! The sound engine's assembly needs the ARAM address of every bank-4 data
//! table it reads, and `aram_layout.plan` is what decides those addresses. This
//! writes them out as assembly so the engine reads the layout rather than
//! restating it. It needs neither the ROM nor an assembler: the addresses are a
//! function of the entry sizes in `offsets.zig` and the shim package's region
//! bounds, so this runs on any checkout.
//!
//! `zig build spcengine` runs this first, so the include is current before the
//! assembler reads it, and `zig build verify` fails when the committed copy
//! stops matching.

const std = @import("std");
const aram_layout = @import("aram_layout.zig");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const text = try aram_layout.includeText(arena);
    const path = aram_layout.include_path;

    const old = cwd.readFileAlloc(io, path, arena, .limited(1 << 16)) catch null;
    if (old) |o| {
        if (std.mem.eql(u8, o, text)) {
            try out.print("{s} is current\n", .{path});
            return;
        }
    }

    var dir = try cwd.createDirPathOpen(io, std.fs.path.dirname(path) orelse ".", .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = std.fs.path.basename(path), .data = text });
    try out.print("wrote {s} ({d} bytes)\n", .{ path, text.len });
}
