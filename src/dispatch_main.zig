//! `zig build dispatch` — the table-driven dispatch survey (F4).
//!
//! `zig build dispatch -- [boot_s] [explore_s] [door_stride]`, the same three
//! knobs `zig build ledger` takes and with the same meaning. A `door_stride` of
//! 0 skips the door sweep, which turns minutes into seconds and is the
//! configuration to iterate on; it is not the one to quote from, because doors
//! are the only way into the script interpreter and the room loaders.

const std = @import("std");
const build_options = @import("build_options");
const rom_mod = @import("rom.zig");
const ledger = @import("ledger.zig");
const dispatch = @import("dispatch.zig");
const disasm = @import("gb/disasm.zig");

fn parseNum(s: []const u8) ?usize {
    return std.fmt.parseInt(usize, s, 10) catch null;
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    if (build_options.rom_path.len == 0) {
        try out.print("dispatch: no ROM configured (set M2_ROM); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        build_options.rom_path,
        gpa,
        .limited(rom_mod.expected_size * 4),
    );

    var opts: ledger.Options = .{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    if (args.next()) |a| opts.boot_seconds = parseNum(a) orelse opts.boot_seconds;
    if (args.next()) |a| opts.explore_seconds = parseNum(a) orelse opts.explore_seconds;
    if (args.next()) |a| opts.door_stride = parseNum(a) orelse opts.door_stride;

    try out.print(
        "observing: {d}s boot, {d}s explore, {d}s movement, every {d}th door...\n",
        .{ opts.boot_seconds, opts.explore_seconds, opts.movement_seconds, opts.door_stride },
    );
    try out.flush();

    var obs = try ledger.observe(gpa, rom, opts);
    defer obs.deinit(gpa);
    var l = try ledger.build(gpa, rom, obs);
    defer l.deinit(gpa);

    var sv = try dispatch.survey(gpa, rom, obs, l);
    defer sv.deinit(gpa);

    try out.print(
        "\n{d} dispatch sites reached, from {d} observed indirect jumps.\n" ++
            "Sites are a fact about the run: a static trace cannot follow `JP HL` at all.\n\n",
        .{ sv.sites.len, obs.edges.len },
    );

    try out.print("  site        kind      table       arity  arms  covered  name\n", .{});
    for (sv.sites) |s| {
        try out.print("  {d}:${X:0>4}   {s: <9} ", .{ s.bank(), s.addr(), @tagName(s.kind) });
        if (s.table) |t| {
            try out.print("{d}:${X:0>4}  ", .{ t / dispatch.bank_size, addrOf(t) });
        } else {
            try out.print("{s: <9}  ", .{"--"});
        }
        if (s.arity()) |n| {
            try out.print("{d: >5}", .{n});
        } else {
            try out.print("{s: >5}", .{"--"});
        }
        try out.print("  {d: >4}", .{s.arms.len});
        if (s.coverage()) |c| {
            try out.print("  {d: >6.0}%", .{c});
        } else {
            try out.print("  {s: >7}", .{"--"});
        }
        if (dispatch.routineAt(l, s.site)) |r| {
            try out.print("  {s}", .{r.name});
        }
        try out.print("\n", .{});
    }

    // Per site, the arms and the code that leads into it. This is the half a
    // person reads; the table above is the half a gate reads.
    for (sv.sites) |s| {
        try out.print("\n---- {d}:${X:0>4}", .{ s.bank(), s.addr() });
        if (dispatch.routineAt(l, s.site)) |r| try out.print("  in {s}", .{r.name});
        try out.print(" ----\n", .{});
        if (s.table) |t| {
            try out.print(
                "  table {d}:${X:0>4}, {d}-byte stride. Length bounded three ways: {?d} entries\n" ++
                    "  to the next routine, {?d} to the first arm it names, {d} that decode as\n" ++
                    "  in-bank addresses. The tightest is {?d}.\n",
                .{
                    t / dispatch.bank_size, addrOf(t),
                    dispatch.stride,        s.arity_to_next_routine,
                    s.arity_to_first_arm,   s.arity_plausible,
                    s.arity(),
                },
            );
            try out.print("  the run reached {d} of them, highest index {?d}\n", .{ s.arms.len, s.highest_index });
        } else if (s.kind == .one_arm) {
            try out.print("  one arm observed; no search can tell a one-entry table from a coincidence\n", .{});
        } else {
            try out.print("  {d} arms observed and no strided pointer run in the bank explains them\n", .{s.arms.len});
        }

        try out.print("  arms:", .{});
        for (s.arms, 0..) |a, i| {
            if (i % 4 == 0 and i != 0) try out.print("\n       ", .{});
            try out.print("  {d}:${X:0>4}", .{ a / dispatch.bank_size, addrOf(a) });
            if (dispatch.routineAt(l, a)) |r| {
                try out.print(" {s}", .{r.name});
            } else {
                try out.print(" (no ledger row)", .{});
            }
        }
        try out.print("\n", .{});

        var pre: std.ArrayList(disasm.Insn) = .empty;
        defer pre.deinit(gpa);
        try dispatch.preamble(rom, s.site, 16, &pre, gpa);
        try out.print("  leading in (backwards decode over 16 bytes; the last lines are the sound ones):\n", .{});
        const from = if (pre.items.len > 6) pre.items.len - 6 else 0;
        for (pre.items[from..]) |insn| try out.print("      {s}\n", .{insn.text()});
    }

    // Sites the bytes name once the run has taught us what a site looks like.
    if (sv.siblings.len != 0) {
        try out.print(
            "\n---- the same shape, elsewhere in the ROM ----\n" ++
                "  Three of bank 4's sites share an indexer. Nothing knew which helper to look\n" ++
                "  for until a run reached one of them; now the bytes `21 lo hi / CD .. .. / E9`\n" ++
                "  name every other site that uses it, reached or not.\n\n",
            .{},
        );
        try out.print("  site       table      indexer   run reached it\n", .{});
        for (sv.siblings) |sib| {
            try out.print("  {d}:${X:0>4}   {d}:${X:0>4}   ${X:0>4}    {s}\n", .{
                sib.site / dispatch.bank_size,  addrOf(sib.site),
                sib.table / dispatch.bank_size, addrOf(sib.table),
                sib.indexer,
                if (sib.observed) "yes" else "NO -- new",
            });
        }
        try out.print(
            "\n  {d} of {d} are sites no schedule this repository runs has ever entered.\n",
            .{ sv.unobservedSiblings(), sv.siblings.len },
        );
    }

    try out.print("\n---- what this method cannot have reached ----\n", .{});
    for (dispatch.unreached) |u| {
        try out.print("\n  {s}\n    exists: {s}\n    absent: {s}\n", .{ u.name, u.evidence, u.why });
    }

    try out.print(
        "\n---- the share F4 asks for ----\n" ++
            "  {d} of {d} sites have a located table, {d} table entries in all -- that is the\n" ++
            "  data that transfers instead of being rewritten.\n" ++
            "  {d} of {d} ledger instructions sit in a routine some dispatch was *observed*\n" ++
            "  to jump to: {d:.1}%. That is what a run saw, and it understates the layer badly --\n" ++
            "  the pose machine has 31 arms and the run took 9 of them.\n" ++
            "  Reading every entry of every located table instead, observed or not, and tracing\n" ++
            "  statically from each: {d} instructions, {d:.1}% of the ledger. **That is the\n" ++
            "  ceiling F4 asks for** -- the maximum share that reduces to \"port the dispatcher,\n" ++
            "  transfer the table\" among the layers a run can see. The layers it cannot see are\n" ++
            "  listed above, and every one of them is a dispatch too.\n" ++
            "  The ledger's {d} instructions are themselves {d:.0}% of the stated ~{d} logic lines.\n",
        .{
            sv.located(),          sv.sites.len,
            sv.tableEntries(),     sv.arm_instructions,
            sv.total_instructions, sv.armShare(),
            sv.entry_instructions, sv.entryShare(),
            sv.total_instructions,
            100.0 * @as(f64, @floatFromInt(sv.total_instructions)) /
                @as(f64, @floatFromInt(ledger.stated_logic_lines)),
            ledger.stated_logic_lines,
        },
    );
    if (sv.arms_without_row != 0) {
        try out.print(
            "\n  DISCREPANCY: {d} arm(s) fall in no ledger routine. The two mechanical\n" ++
                "  inventories disagree about where a body starts, which is worth a look.\n",
            .{sv.arms_without_row},
        );
    }
    if (obs.edges_incomplete) {
        try out.print("\nFAIL the survey above is incomplete: allocation failed while recording edges\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    try out.flush();
}

fn addrOf(off: u32) u16 {
    const in_bank: u16 = @intCast(off % dispatch.bank_size);
    return if (off < dispatch.bank_size) in_bank else in_bank + 0x4000;
}
