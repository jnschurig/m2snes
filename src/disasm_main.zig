//! `zig build disasm -- [bank] [start] [end] [entry...]` - disassemble a
//! region of the user's ROM.
//!
//! An inspection tool, not a gate, and a companion to `zig build probe`: the
//! probe says which addresses executed when the game read a region, and this
//! says what the code at those addresses is. Defaults point at bank 5's
//! door-script interpreter, which is what Step 7 needed.
//!
//! Addresses are Game Boy addresses. A bank other than 0 is mapped at
//! $4000-$7FFF, which is where its code both lives and runs.

const std = @import("std");
const rom_mod = @import("rom.zig");
const disasm = @import("gb/disasm.zig");

const build_options = @import("build_options");

fn parseNum(s: []const u8) ?usize {
    const t = if (s.len > 0 and s[0] == '$') s[1..] else s;
    if (std.mem.startsWith(u8, t, "0x")) return std.fmt.parseInt(usize, t[2..], 16) catch null;
    return std.fmt.parseInt(usize, t, 16) catch null;
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    if (build_options.rom_path.len == 0) {
        try out.print("no ROM configured (set M2_ROM); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        build_options.rom_path,
        arena,
        .limited(rom_mod.expected_size * 4),
    );

    // Defaults: the code region `zig build probe` named. Every read of bank 5
    // that came from bank 5 had its PC in $4000-$42E4, and $42E5 is where the
    // door-script pointer table starts, so that is the whole of the code.
    var bank: usize = 5;
    var start: usize = 0x4000;
    var end: usize = 0x42E5;
    var entries: std.ArrayList(u16) = .empty;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv[0]
    var n: usize = 0;
    while (args.next()) |a| : (n += 1) {
        const v = parseNum(a) orelse continue;
        switch (n) {
            0 => bank = v,
            1 => start = v,
            2 => end = v,
            else => try entries.append(arena, @intCast(v)),
        }
    }
    // With no entry given, start the trace at the top of the region. That is a
    // guess, and the listing marks which bytes it actually reached so the guess
    // is visible rather than assumed.
    if (entries.items.len == 0) try entries.append(arena, @intCast(start));

    const window: usize = if (bank == 0) 0 else 0x4000;
    const file_start = bank * 0x4000 + (start - window);
    const file_end = bank * 0x4000 + (end - window);
    if (file_end > rom.len or file_end <= file_start) {
        try out.print("region ${X:0>4}-${X:0>4} in bank {d} is not inside a {d}-byte ROM\n", .{ start, end, bank, rom.len });
        try out.flush();
        std.process.exit(1);
    }
    const code = rom[file_start..file_end];

    var listing = try disasm.trace(arena, code, @intCast(start), entries.items);
    defer listing.deinit(arena);

    try out.print("bank {d}, ${X:0>4}-${X:0>4} ({d} bytes), traced from", .{ bank, start, end - 1, code.len });
    for (entries.items) |e| try out.print(" ${X:0>4}", .{e});
    try out.print("\n\n", .{});

    var reached: usize = 0;
    var off: usize = 0;
    while (off < code.len) {
        if (!listing.starts[off]) {
            // A run the trace never proved is code. Print the bytes as data
            // rather than decoding them: a linear sweep through a jump table
            // produces confident nonsense.
            const run_start = off;
            while (off < code.len and !listing.starts[off]) off += 1;
            try dumpData(out, code[run_start..off], @intCast(start + run_start));
            continue;
        }
        const addr: u16 = @intCast(start + off);
        const insn = disasm.decode(code[off..], addr);
        reached += insn.len;
        try out.print("  ${X:0>4}  ", .{addr});
        for (0..3) |i| {
            if (i < insn.len) try out.print("{X:0>2} ", .{code[off + i]}) else try out.print("   ", .{});
        }
        try out.print(" {s}", .{insn.text()});
        if (insn.mem) |m| {
            const where = if (m.addr >= 0xFF80) "hram" else if (m.addr >= 0xFF00) "io" else if (m.addr >= 0xC000) "wram" else if (m.addr >= 0xA000) "sram" else if (m.addr >= 0x8000) "vram" else "rom";
            try out.print("   ; {s} {s}", .{ if (m.write) "->" else "<-", where });
        }
        try out.print("\n", .{});
        off += insn.len;
    }

    try out.print("\n{d} of {d} bytes reached ({d}%)\n", .{ reached, code.len, reached * 100 / code.len });
    try out.print("calls out:", .{});
    for (listing.calls) |c| try out.print(" ${X:0>4}", .{c});
    try out.print("\njumps out:", .{});
    for (listing.exits) |e| try out.print(" ${X:0>4}", .{e});
    try out.print("\n", .{});
    try out.flush();
}

fn dumpData(out: *std.Io.Writer, bytes: []const u8, base: u16) !void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 16) {
        const row = bytes[i..@min(i + 16, bytes.len)];
        try out.print("  ${X:0>4}  db  ", .{base + @as(u16, @intCast(i))});
        for (row) |v| try out.print("{X:0>2} ", .{v});
        for (row.len..16) |_| try out.print("   ", .{});
        try out.print(" |", .{});
        for (row) |v| try out.print("{c}", .{if (v >= 0x20 and v < 0x7F) v else '.'});
        try out.print("|\n", .{});
    }
}
