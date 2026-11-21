//! `zig build full-assign [-- check | cover] [-- --zip <path>] [-- --dir <path>]`:
//! the full scheme's slot assignment, read from its EJRTQ reference
//! (colorization Steps 3 and 5). Run by hand; no gate runs it.
//!
//! `cover` also replays the 100% recording (`--dir`, default
//! `reference/metroid2-100p-recording/`) on the original ROM in Mesen, and
//! writes what it showed of each tile into the file's `seen` strings. Plain
//! runs and `check` keep the committed strings.
//!
//! Without `check` it writes `src/full_assign.zig`, keeping that file's
//! hand-edited section. With `check` it writes nothing and fails if the file
//! differs from a fresh extraction. Either way it fails while a conflict has
//! no hand choice, or if the rendered text would carry an EJRTQ colour.

const std = @import("std");
const rom_mod = @import("rom.zig");
const ref = @import("full_ref.zig");
const ips = @import("ips.zig");
const cover_mod = @import("full_ref_cover.zig");
const gb_trace = @import("gb_trace.zig");
const areas = @import("areas.zig");
const map = @import("map.zig");
const cgb = @import("full_ref_cgb.zig");
const cgb_run = if (build_options.have_sameboy) @import("full_ref_cgb_run.zig") else struct {};
const gbc_oracle = @import("gbc_oracle.zig");
const save = @import("save.zig");

const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var check = false;
    var cover = false;
    var write_patched: ?[]const u8 = null;
    var cgb_mode: enum { off, check, probe } = .off;
    var dir_path: []const u8 = default_dir;
    var zip_path: []const u8 = ref.default_zip;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "check")) {
            check = true;
        } else if (std.mem.eql(u8, arg, "cover")) {
            cover = true;
        } else if (std.mem.eql(u8, arg, "cgb")) {
            cgb_mode = .check;
        } else if (std.mem.eql(u8, arg, "cgb-probe")) {
            cgb_mode = .probe;
        } else if (std.mem.eql(u8, arg, "--write-patched")) {
            write_patched = args.next() orelse return fail(out, "--write-patched needs a path", .{});
        } else if (std.mem.eql(u8, arg, "--dir")) {
            dir_path = args.next() orelse return fail(out, "--dir needs a path", .{});
        } else if (std.mem.eql(u8, arg, "--zip")) {
            zip_path = args.next() orelse return fail(out, "--zip needs a path", .{});
        } else return fail(out, "unknown argument `{s}`; usage: zig build full-assign [-- check | cover] [-- --zip <path>] [-- --dir <path>]", .{arg});
    }
    if (check and cover) return fail(out, "`check` and `cover` don't combine: `cover` rewrites the file", .{});

    if (build_options.rom_path.len == 0) return fail(out, "no ROM configured (set M2_ROM); see docs/setup.md", .{});
    const rom = try cwd.readFileAlloc(io, build_options.rom_path, a, .limited(rom_mod.expected_size * 4));
    _ = try rom_mod.ingest(a, rom, null);
    const zip = cwd.readFileAlloc(io, zip_path, a, .limited(16 << 20)) catch |e|
        return fail(out, "can't read {s} ({t}): put EJRTQ's v1.3 zip there, or pass --zip", .{ zip_path, e });
    const patched = ref.patchedRom(a, rom, zip) catch |e| switch (e) {
        error.WrongPatch => return fail(out, "{s} is not EJRTQ v1.3: expected `{s}` with SHA-1 {s}", .{ zip_path, ips.ejrtq_name, ips.ejrtq_sha1 }),
        else => return e,
    };
    // For disassembly by hand. ROM-derived: keep it under build-out/.
    if (write_patched) |p| {
        try cwd.writeFile(io, .{ .sub_path = p, .data = patched });
        try out.print("wrote the patched ROM to {s}\n", .{p});
    }

    var x = try ref.extract(a, rom, patched);
    try report(out, x);
    if (cover) x.seen = try runCover(a, io, out, rom, dir_path, init.environ_map.get("HOME") orelse "", x.slots);
    if (cgb_mode != .off) {
        const home = init.environ_map.get("HOME") orelse "";
        const ok = try runCgb(a, io, out, rom, patched, x, cgb_mode == .probe, dir_path, home);
        if (!ok) return fail(out, "the patched ROM disagrees with the model; see above", .{});
        return;
    }
    if (x.stray.len != 0) {
        for (x.stray[0..@min(x.stray.len, 40)]) |s| try out.print("stray: {X:0>2}:{X:0>4} = ${X:0>2}\n", .{ s.bank, s.addr, s.value });
        return fail(out, "{d} shadow-bank bytes no graphics tile explains; the model is incomplete", .{x.stray.len});
    }

    var colour_buf: [64]u16 = undefined;
    const existing: ?[]const u8 = cwd.readFileAlloc(io, ref.output_path, a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    const text = try ref.render(a, x, ref.handSection(existing));
    if (ref.colourLeak(text, x.colours.values(&colour_buf))) |leak|
        return fail(out, "line {d} of the rendered file has a number equal to one of EJRTQ's colours; nothing written", .{leak.line});

    const settle = try ref.unsettled(a, x);
    for (settle.open) |u| try out.print("conflict: {s} id ${X:0>2} has no hand choice in {s}_choices\n", .{ u.table, u.id, u.table });
    for (settle.stale) |u| try out.print("stale: {s}_choices names id ${X:0>2}, which no edited position has\n", .{ u.table, u.id });

    if (check) {
        const have = existing orelse return fail(out, "{s} does not exist; run `zig build full-assign`", .{ref.output_path});
        if (!std.mem.eql(u8, have, text)) {
            try diffLines(out, have, text);
            return fail(out, "{s} differs from a fresh extraction", .{ref.output_path});
        }
        try out.print("check: {s} agrees with the extraction\n", .{ref.output_path});
    } else {
        try cwd.writeFile(io, .{ .sub_path = ref.output_path, .data = text });
        try out.print("wrote {s} ({d} bytes)\n", .{ ref.output_path, text.len });
    }
    // The file stands, even with an open conflict, so its choices can be made.
    if (settle.open.len != 0 or settle.stale.len != 0) return fail(out, "settle the conflicts above in the hand-edited section", .{});
}

fn report(out: *std.Io.Writer, x: ref.Extraction) !void {
    var tiles: usize = 0;
    var per_slot: [8]usize = @splat(0);
    for (x.slots) |r| {
        tiles += r.slots.len;
        for (r.slots) |s| per_slot[s] += 1;
    }
    try out.print("source tiles: {d} in {d} regions; per slot:", .{ tiles, x.slots.len });
    for (per_slot, 0..) |n, s| try out.print(" {d}:{d}", .{ s, n });
    try out.print("\nOBP1 swap: slot {d} -> {d}, else -> {d}; frozen -> {d}\n", .{ x.obp1.when, x.obp1.then, x.obp1.otherwise, x.frozen });
    for (x.slots) |r| {
        var used: u8 = 0;
        for (r.slots) |s| used |= @as(u8, 1) << s;
        try out.print("  {s:<26} {d:>4} tiles, slots {b:0>8}\n", .{ r.name, r.slots.len, used });
    }
    try out.print("HUD ids:", .{});
    for (x.hud) |d| try out.print(" ${X:0>2}={b:0>8}{s}", .{ d.id, d.slots, if (d.conflict()) "!" else "" });
    try out.print("\nQueen screens:", .{});
    for (x.queen_screens) |s| try out.print(" ${X:0>2}", .{s});
    try out.print("; ids:", .{});
    for (x.queen) |d| try out.print(" ${X:0>2}={b:0>8}{s}", .{ d.id, d.slots, if (d.conflict()) "!" else "" });
    try out.print("\nlook-alike (kept):", .{});
    for (x.look.keep) |l| try out.print(" {t}{d}={d}/{b:0>4}", .{ l.layer, l.a, l.b, l.shades });
    try out.print("\nidentical tiles EJRTQ draws differently:", .{});
    for (x.look.differ) |l| try out.print(" {t}{d}~{d}/{b:0>4}", .{ l.layer, l.a, l.b, l.shades });
    try out.print("\npixel-identical tile pairs in different slots:\n", .{});
    for (x.look.pairs) |p| try out.print("  {s} ${X:0>2} (slot {d}) = ${X:0>2} (slot {d}): {s}\n", .{
        p.region, p.i, p.a, p.j, p.b, if (p.alike) "same colours in EJRTQ" else "EJRTQ draws them differently",
    });
}

fn diffLines(out: *std.Io.Writer, have: []const u8, want: []const u8) !void {
    var h = std.mem.splitScalar(u8, have, '\n');
    var w = std.mem.splitScalar(u8, want, '\n');
    var line: usize = 1;
    var shown: usize = 0;
    while (true) : (line += 1) {
        const hl = h.next();
        const wl = w.next();
        if (hl == null and wl == null) break;
        if (hl != null and wl != null and std.mem.eql(u8, hl.?, wl.?)) continue;
        if (shown < 20) try out.print("line {d}:\n  file:      {s}\n  extracted: {s}\n", .{ line, hl orelse "<end>", wl orelse "<end>" });
        shown += 1;
    }
    if (shown > 20) try out.print("... and {d} more differing lines\n", .{shown - 20});
}

// ---- Coverage (Step 5) -----------------------------------------------------

const default_dir = "reference/metroid2-100p-recording";

/// How many Mesens run at once, as `gbtrace -- set worlds` does.
const lanes: u8 = 8;

const Job = struct {
    path: []const u8,
    part: cover_mod.Part = undefined,
    err: ?anyerror = null,
};

const Env = struct { io: std.Io, rom: []const u8, srcs: []const cover_mod.Source, home: []const u8 };

fn runJob(env: Env, j: *Job, lane: u8) !void {
    const a = std.heap.smp_allocator;
    const mmo = try std.Io.Dir.cwd().readFileAlloc(env.io, j.path, a, .limited(64 * 1024 * 1024));
    const rec = try gb_trace.readRecording(a, mmo);
    try rec.checkCartridge(env.rom);
    j.part = try cover_mod.runPart(a, env.io, env.rom, rec, env.srcs, gb_trace.input_offset, build_options.mesen_path, env.home, lane);
    if (j.part.code != 0 or j.part.frames_run < rec.frames()) return error.PassStopped;
}

/// Every `.mmo` in `dir_path`, in name order, through Mesen `lanes` at a time.
pub fn coverParts(a: std.mem.Allocator, io: std.Io, rom: []const u8, dir_path: []const u8, home: []const u8, srcs: []const cover_mod.Source) ![]cover_mod.Part {
    if (build_options.mesen_path.len == 0) return error.NoMesen;
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if ((e.kind != .file and e.kind != .sym_link) or !std.mem.endsWith(u8, e.name, ".mmo")) continue;
        try names.append(a, try std.fs.path.join(a, &.{ dir_path, e.name }));
    }
    if (names.items.len == 0) return error.NoParts;
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    const jobs = try a.alloc(Job, names.items.len);
    for (jobs, names.items) |*j, n| j.* = .{ .path = n };

    const env: Env = .{ .io = io, .rom = rom, .srcs = srcs, .home = home };
    const Lane = struct {
        fn go(js: []Job, next: *std.atomic.Value(usize), e: Env, lane: u8) void {
            while (true) {
                const i = next.fetchAdd(1, .monotonic);
                if (i >= js.len) return;
                runJob(e, &js[i], lane) catch |err| {
                    js[i].err = err;
                };
            }
        }
    };
    var next: std.atomic.Value(usize) = .init(0);
    var threads: [lanes]std.Thread = undefined;
    const n = @min(lanes, jobs.len);
    for (threads[0..n], 0..) |*t, l| t.* = try std.Thread.spawn(.{}, Lane.go, .{ jobs, &next, env, @as(u8, @intCast(l)) });
    for (threads[0..n]) |t| t.join();
    for (jobs) |j| if (j.err) |err| {
        std.debug.print("full-assign: {s}: {s}\n", .{ j.path, @errorName(err) });
        return error.PassFailed;
    };
    const parts = try a.alloc(cover_mod.Part, jobs.len);
    for (parts, jobs) |*p, j| p.* = j.part;
    return parts;
}

/// The coverage pass: run it, report it, and return the `seen` strings.
fn runCover(a: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, rom: []const u8, dir_path: []const u8, home: []const u8, slots: []const ref.RegionSlots) ![]const []const u8 {
    const srcs = try cover_mod.sources(a);
    try out.print("coverage: {d} source tiles; replaying {s} (first run takes a while)\n", .{ srcs.len, dir_path });
    try out.flush();
    const parts = try coverParts(a, io, rom, dir_path, home, srcs);
    var assigned: u64 = 0;
    var unassigned: u64 = 0;
    var dropped: u64 = 0;
    var saves: usize = 0;
    for (parts) |p| {
        assigned += p.assigned;
        unassigned += p.unassigned;
        dropped += p.saves_dropped;
        saves += p.saves.len;
    }
    const c = try cover_mod.combine(a, rom, srcs, parts);
    try out.print("coverage: {d} parts; tile copies named {d}, not named {d}; saves kept {d}, dropped {d}\n", .{ parts.len, assigned, unassigned, saves, dropped });
    try out.print("coverage: shown tiles with no named source {d}; stale tracked tiles {d}; seam tiles {d}\n", .{ c.unnamed, c.stale, c.seam_tiles });

    // Per region, and the seen strings.
    const seen = try a.alloc([]const u8, slots.len);
    var k: usize = 0;
    var never: usize = 0;
    try out.print("coverage per region (shown / tiles):\n", .{});
    for (slots, seen) |r, *s| {
        const buf = try a.alloc(u8, r.slots.len);
        var shown: usize = 0;
        for (buf) |*ch| {
            if (srcs[k].entry != r.entry) return error.SourceOrder;
            ch.* = cover_mod.seenChar(c.seen[k]);
            if (ch.* != '.') shown += 1;
            k += 1;
        }
        never += r.slots.len - shown;
        try out.print("  {s:<26} {d:>4} / {d:>4}\n", .{ r.name, shown, r.slots.len });
        s.* = buf;
    }
    if (k != srcs.len) return error.SourceOrder;
    try out.print("coverage: {d} of {d} source tiles never shown (`.` in the seen strings)\n", .{ never, srcs.len });

    // Rooms: cells in use per area, and how many the recording stood in.
    const table = try areas.tableOf(a, rom);
    var in_use: [areas.Area.count]usize = @splat(0);
    var stood: [areas.Area.count]usize = @splat(0);
    for (table, 0..) |row, bi| for (row, 0..) |v, cell| {
        if (v == areas.none) continue;
        const ar = v & ~areas.nest_bit;
        in_use[ar] += 1;
        const bank: u8 = @intCast(map.first_bank + bi);
        if (cover_mod.visitedCell(&c.visited, bank, @intCast(cell))) stood[ar] += 1;
    };
    try out.print("coverage per area (cells Samus stood in / cells):", .{});
    for (0..areas.Area.count) |ar| try out.print(" {s} {d}/{d};", .{ @as(areas.Area, @enumFromInt(ar)).label(), stood[ar], in_use[ar] });
    try out.print("\n", .{});
    return seen;
}

// ---- The CGB check (Step 5) ------------------------------------------------

const SlotMap = std.AutoHashMap(u32, u3);

fn slotOfMap(ctx: *const anyopaque, flat: u32) ?u3 {
    const m: *const SlotMap = @ptrCast(@alignCast(ctx));
    return m.get(flat);
}

/// Buttons pressed from frame `at` for `len` frames, in `gb_trace` order.
const Press = struct { at: u32, held: u8, len: u32 = 4 };

fn keysOf(a: std.mem.Allocator, frames: u32, presses: []const Press) ![]u8 {
    const keys = try a.alloc(u8, frames);
    @memset(keys, 0);
    for (presses) |p| {
        for (p.at..@min(p.at + p.len, frames)) |f| keys[f] |= cgb.keyMask(p.held);
    }
    return keys;
}

const btn_a: u8 = 0x01;
const btn_start: u8 = 0x08;

fn runCgb(
    a: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    patched: []const u8,
    x: ref.Extraction,
    probe: bool,
    dir_path: []const u8,
    home: []const u8,
) !bool {
    if (comptime !build_options.have_sameboy) {
        try out.print("full-assign: cgb needs vendor/sameboy (see docs/setup.md)\n", .{});
        return false;
    } else {
        const boot = std.Io.Dir.cwd().readFileAlloc(io, gbc_oracle.boot_path, a, .limited(1 << 16)) catch |e| {
            try out.print("full-assign: can't read {s} ({t}); build SameBoy's boot ROMs\n", .{ gbc_oracle.boot_path, e });
            return false;
        };
        const srcs = try cover_mod.sources(a);
        const tile_start = try a.alloc(u8, (patched.len + 7) / 8);
        @memset(tile_start, 0);
        var slots: SlotMap = .init(a);
        var k: usize = 0;
        for (x.slots) |r| for (r.slots) |s| {
            if (srcs[k].entry != r.entry) return error.SourceOrder;
            tile_start[srcs[k].flat >> 3] |= @as(u8, 1) << @intCast(srcs[k].flat & 7);
            try slots.put(srcs[k].flat, s);
            k += 1;
        };
        const slot_of: cgb.SlotOf = .{ .ctx = &slots, .f = slotOfMap };
        const rules: cgb.Rules = .{ .when = x.obp1.when, .then = x.obp1.then, .otherwise = x.obp1.otherwise, .frozen = x.frozen };
        var o: cgb.Out = undefined;

        if (probe) {
            const frames: u32 = 3000;
            const presses = [_]Press{
                .{ .at = 600, .held = btn_start },
                .{ .at = 900, .held = btn_start },
                .{ .at = 1200, .held = btn_start },
                .{ .at = 1500, .held = btn_start },
            };
            const modes = try a.alloc(u8, frames);
            try cgb_run.run(.{ .rom = patched, .boot = boot, .tile_start = tile_start, .keys = try keysOf(a, frames, &presses), .frames = frames, .modes = modes }, &o);
            try out.print("probe: modes over {d} frames (Start at 600, 900, 1200, 1500):\n", .{frames});
            var last: ?u8 = null;
            for (modes, 0..) |m, f| {
                if (last == null or last.? != m) try out.print("  frame {d}: mode ${X:0>2}\n", .{ f, m });
                last = m;
            }
            try out.print("probe: tiles named {d}, not named {d}\n", .{ o.named, o.unnamed });
            return true;
        }
        // A fresh boot: the title, and the landing site after a new game.
        var scenarios: std.ArrayList(Scenario) = .empty;
        try scenarios.append(a, .{ .name = "title", .presses = &.{}, .settle = 250 });
        try scenarios.append(a, .{ .name = "landing site", .presses = &start_at_title, .after_play = 700 });

        // One save per area, from the recording (the coverage pass's cache).
        const parts = try coverParts(a, io, rom, dir_path, home, srcs);
        const table = try areas.tableOf(a, rom);
        var have: [areas.Area.count]bool = @splat(false);
        for (parts) |p| for (p.saves) |*sv| {
            const ini = sv.initial() orelse continue;
            if (ini.level_bank < map.first_bank or ini.level_bank > map.last_bank) continue;
            const v = table[ini.level_bank - map.first_bank][ini.cell()];
            if (v == areas.none) continue;
            const ar = v & ~areas.nest_bit;
            if (have[ar]) continue;
            have[ar] = true;
            const battery = try a.alloc(u8, gb_trace.game_sram_bytes);
            @memset(battery, 0);
            @memcpy(battery[0..save.slot_size], &sv.record);
            @memcpy(battery[save.spawn_base - save.slot_base ..][0..save.spawn_size], &sv.spawn);
            try scenarios.append(a, .{
                .name = try std.fmt.allocPrint(a, "{s} (save at frame {d}, map {X} cell {X:0>2})", .{ @as(areas.Area, @enumFromInt(ar)).label(), sv.frame, ini.level_bank, ini.cell() }),
                .battery = battery,
                .presses = &start_at_title,
                .after_play = 300,
            });
        };
        for (have, 0..) |h, ar| if (!h) try out.print("cgb: no save in {s}; not checked from a save\n", .{@as(areas.Area, @enumFromInt(ar)).label()});

        var all_ok = true;
        for (scenarios.items) |sc| {
            const ok = try checkScenario(a, out, sc, patched, boot, tile_start, slot_of, rules, &o);
            all_ok = all_ok and ok;
        }
        return all_ok;
    }
}

/// Start on the title, twice: the second press is for a file select.
const start_at_title = [_]Press{ .{ .at = 400, .held = btn_start }, .{ .at = 460, .held = btn_start } };

const Scenario = struct {
    name: []const u8,
    battery: ?[]const u8 = null,
    presses: []const Press,
    /// Check this many frames after the title appears (mode `$01`)...
    settle: ?u32 = null,
    /// ... or this many after play begins (mode `$04`).
    after_play: ?u32 = null,
};

/// Run once to find the moment, then again to stop there and grade.
fn checkScenario(
    a: std.mem.Allocator,
    out: *std.Io.Writer,
    sc: Scenario,
    patched: []const u8,
    boot: []const u8,
    tile_start: []const u8,
    slot_of: cgb.SlotOf,
    rules: cgb.Rules,
    o: *cgb.Out,
) !bool {
    const look: u32 = 3000;
    const modes = try a.alloc(u8, look);
    const base: cgb_run.Run = .{ .rom = patched, .boot = boot, .battery = sc.battery, .tile_start = tile_start, .keys = try keysOf(a, look, sc.presses), .frames = look, .modes = modes };
    try cgb_run.run(base, o);
    const want_mode: u8 = if (sc.after_play != null) 0x04 else 0x01;
    const reached = std.mem.indexOfScalar(u8, modes, want_mode) orelse {
        try out.print("FAIL  {s}: mode ${X:0>2} never reached in {d} frames\n", .{ sc.name, want_mode, look });
        return false;
    };
    const at: u32 = @intCast(reached + (sc.after_play orelse sc.settle.?));
    var r = base;
    r.frames = at;
    r.modes = null;
    try cgb_run.run(r, o);
    var g = try cgb.grade(a, o, slot_of, rules);
    const L = cgb.Layer;
    try out.print("{s}  {s} at frame {d} (mode ${X:0>2}): bg {d}, window {d}, sprites {d}, table {d} compared; untracked bg {d} window {d} sprites {d}; frozen {d}; invisible {d}; tile writes named {d}, not named {d}\n", .{
        if (g.failed()) "FAIL" else "ok  ",
        sc.name,
        at,
        o.game_mode,
        g.compared[@intFromEnum(L.bg)],
        g.compared[@intFromEnum(L.window)],
        g.compared[@intFromEnum(L.obj)],
        g.compared[@intFromEnum(L.table)],
        g.untracked[@intFromEnum(L.bg)],
        g.untracked[@intFromEnum(L.window)],
        g.untracked[@intFromEnum(L.obj)],
        g.frozen,
        g.invisible,
        o.named,
        o.unnamed,
    });
    if (o.miss_addr != 0) try out.print("      first unnamed tile write: pc {X:0>4} hl {X:0>4} de {X:0>4} bank {X:0>2} -> {X:0>4} = {X:0>2}\n", .{ o.miss_pc, o.miss_hl, o.miss_de, o.miss_bank, o.miss_addr, o.miss_data });
    for (g.mismatches.items[0..@min(g.mismatches.items.len, 12)]) |m| {
        try out.print("      {t} {d},{d} id ${X:0>2} tile ${X:0>3} src {X:0>6}: model {d}, EJRTQ {d}\n", .{ m.layer, m.row, m.col, m.id, m.tile, m.src, m.want, m.got });
    }
    if (g.mismatches.items.len > 12) try out.print("      ... and {d} more\n", .{g.mismatches.items.len - 12});
    return !g.failed();
}

fn fail(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try out.print("full-assign: " ++ fmt ++ "\n", args);
    try out.flush();
    std.process.exit(1);
}
