//! `zig build probe` - find the code that reads a data region, by watching the
//! game read it.
//!
//! An inspection tool, not a gate. Step 7 needs bank 0's door-script
//! interpreter in order to pin what a `WARP` operand means, and the honest way
//! to find it -- honest in the sense that the answer does not depend on
//! M2RoS's labels or its licensing -- is to run the retail ROM and record who
//! reads bank 5.
//!
//! Output is a list of program counters with read counts, which is where a
//! disassembly starts rather than where it ends.

const std = @import("std");
const rom_mod = @import("rom.zig");
const probe = @import("gb/probe.zig");

const build_options = @import("build_options");

const boot_path = "vendor/sameboy/build/bin/tester/dmg_boot.bin";

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
    const boot = std.Io.Dir.cwd().readFileAlloc(init.io, boot_path, arena, .limited(1 << 20)) catch {
        try out.print("no {s} -- run tools/sameboy-frames.sh\n", .{boot_path});
        try out.flush();
        std.process.exit(1);
    };

    // Long enough for the attract loop to time out, a new game to start, and
    // several rooms to load. Overridable so a longer run can be tried without
    // an edit.
    var seconds: usize = 40;
    var doors = false;
    var door_limit: usize = 512;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv[0]
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "doors")) {
            doors = true;
            continue;
        }
        const v = std.fmt.parseInt(usize, a, 10) catch continue;
        if (doors) door_limit = v else seconds = v;
    }

    if (doors) {
        try runDoors(out, arena, rom, boot, door_limit);
        try out.flush();
        return;
    }

    var report = try probe.watchDoorScripts(arena, rom, boot, seconds);
    defer report.deinit(arena);

    try out.print(
        "door script region 5:${X:0>4}-${X:0>4} (pointers from ${X:0>4})\n" ++
            "{d}s: {d} frames, {d}M instructions\n\n",
        .{
            probe.door_data_start, probe.door_data_end, probe.door_pointers_start,
            seconds,               report.frames,       report.instructions / 1_000_000,
        },
    );

    if (report.sites.len == 0) {
        try out.print("no bank-0 code read the region in this run.\n", .{});
    } else {
        try out.print("  PC     where   reads  spread  first   last\n", .{});
        std.mem.sort(probe.Site, report.sites, {}, struct {
            fn lt(_: void, a: probe.Site, b: probe.Site) bool {
                return a.reads > b.reads;
            }
        }.lt);
        for (report.sites[0..@min(report.sites.len, 40)]) |s| {
            try out.print("  ${X:0>4}  {s}  {d:>6}  {d:>6}  ${X:0>4}  ${X:0>4}\n", .{
                s.pc,
                if (s.in_bank) "bank 5" else "bank 0",
                s.reads,
                s.distinct,
                s.first_addr,
                s.last_addr,
            });
        }
    }
    try out.print("\n{d} pointer-table reads, {d} reads from within bank 5 itself\n", .{
        report.pointer_reads, report.same_window,
    });

    try out.print("\nreads from $4000-$7FFF, by mapped bank:\n", .{});
    for (report.bank_reads, 0..) |n, b| {
        if (n != 0) try out.print("  bank {d:>2}: {d}\n", .{ b, n });
    }
    try out.print("\nbank 5 reads, by $100 page:\n", .{});
    for (report.bank5_map, 0..) |n, i| {
        if (n != 0) try out.print("  ${X:0>4}: {d}\n", .{ 0x4000 + i * 0x100, n });
    }
    try out.print("\nbank 5 $4000-$43FF, runs of read addresses:\n", .{});
    var i: usize = 0;
    while (i < report.bank5_fine.len) {
        if (report.bank5_fine[i] == 0) {
            i += 1;
            continue;
        }
        const start = i;
        var total: usize = 0;
        while (i < report.bank5_fine.len and report.bank5_fine[i] != 0) : (i += 1) total += report.bank5_fine[i];
        try out.print("  ${X:0>4}-${X:0>4}  {d} reads\n", .{ 0x4000 + start, 0x4000 + i - 1, total });
    }
    try out.flush();
}

/// `zig build probe -- doors [n]`: execute the first `n` door scripts on a
/// booted machine and report the screen each one loaded.
///
/// This is the cross-check the static disassembly cannot do on its own. The
/// disassembly says the warp operand's high nibble is the screen row and its
/// low nibble the column; running the interpreter says which screen-pointer
/// entry the engine actually read. Agreement is the proof.
fn runDoors(
    out: *std.Io.Writer,
    arena: std.mem.Allocator,
    rom: []const u8,
    boot: []const u8,
    limit: usize,
) !void {
    var list: std.ArrayList(u16) = .empty;
    for (0..@min(limit, 512)) |i| try list.append(arena, @intCast(i));

    // Three sub-screen offsets, not one. The middle one borrows in neither
    // axis; the other two force the borrow and the carry the camera
    // arithmetic performs, which is how "the operand names Samus's screen"
    // is told apart from "the operand names the screen that got drawn".
    const offsets = [_]?[2]u8{ .{ 0x80, 0x00 }, .{ 0x00, 0xC0 }, null };
    const runs = try probe.runDoors(arena, rom, boot, list.items, 1, 30, offsets[0]);
    const shifted_y = try probe.runDoors(arena, rom, boot, list.items, 1, 30, offsets[1]);
    const as_booted = try probe.runDoors(arena, rom, boot, list.items, 1, 30, offsets[2]);
    try out.print(
        "door  ret   instr  bank  row col  operand  cells read           agrees\n",
        .{},
    );
    var agree: usize = 0;
    var disagree: usize = 0;
    var silent: usize = 0;
    for (runs) |r| {
        if (r.cell_count == 0) {
            silent += 1;
            continue;
        }
        const operand: u16 = @as(u16, r.screen_row) * 16 + r.screen_col;
        var ok = false;
        for (r.cells[0..r.cell_count]) |c| {
            if (c == operand) ok = true;
        }
        if (ok) agree += 1 else disagree += 1;
        try out.print("{d:>4}  {s}  {d:>7}  ${X:0>2}  {d:>3} {d:>3}  ${X:0>3}   ", .{
            r.door,
            if (r.returned) "y" else "n",
            r.instructions,
            r.map_bank,
            r.screen_row,
            r.screen_col,
            operand,
        });
        for (r.cells[0..r.cell_count]) |c| try out.print(" ${X:0>3}", .{c});
        if (r.total_cell_reads > r.cell_count) try out.print(" +{d}", .{r.total_cell_reads - r.cell_count});
        try out.print("   {s}\n", .{if (ok) "yes" else "NO"});
    }
    try out.print("\n{d} doors ran: {d} read the screen the operand names, {d} did not, {d} read no screen table\n", .{
        runs.len, agree, disagree, silent,
    });

    // The same doors with a sub-screen offset that borrows out of the screen
    // number, and with whatever the booted machine happened to hold.
    var moved: usize = 0;
    var same: usize = 0;
    var row_still: usize = 0;
    for (runs, shifted_y, as_booted) |a, b, c| {
        if (a.cell_count == 0 or b.cell_count == 0 or c.cell_count == 0) continue;
        if (a.cells[0] == b.cells[0]) same += 1 else moved += 1;
        // Whatever the camera did, the screen the *operand* named is the same
        // in all three runs: the handler writes it from the operand alone.
        if (a.screen_row == b.screen_row and a.screen_row == c.screen_row and
            a.screen_col == b.screen_col and a.screen_col == c.screen_col) row_still += 1;
    }
    var palettes: [256]usize = @splat(0);
    for (runs) |r| {
        if (r.cell_count != 0) palettes[r.bgp] += 1;
    }
    try out.print("BGP left by the doors that loaded a screen:", .{});
    for (palettes, 0..) |n, v| {
        if (n != 0) try out.print(" ${X:0>2} x{d}", .{ v, n });
    }
    try out.print("\n", .{});

    try out.print(
        "sub-screen offset: the first screen read moved for {d} doors and stayed for {d};\n" ++
            "the row/col the handler wrote was identical in all three runs for {d}\n",
        .{ moved, same, row_still },
    );
}
