//! `zig build oracle` — take the Game Boy reference for the hand-authored
//! segment, write the Mesen2 script that grades the cart against it, and, when
//! an emulator is configured, run it.
//!
//! The reference is taken here rather than baked into the repository: it is
//! derived from the user's own ROM, and a checked-in copy would be exactly the
//! transcription `01-requirements.md` forbids.

const std = @import("std");
const build_options = @import("build_options");
const rom_mod = @import("rom.zig");
const oracle = @import("oracle.zig");
const screen = @import("snes_screen.zig");
const convert = @import("snes_convert.zig");
const tas = @import("tas.zig");
const inject = @import("snes_inject.zig");
const residue = @import("residue.zig");
const duration = @import("duration.zig");
const gb_trace = @import("gb_trace.zig");

const out_dir = "build-out";
const lua_name = out_dir ++ "/oracle.lua";
const cart_name = out_dir ++ "/oracle.sfc";

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    if (build_options.rom_path.len == 0) {
        try out.print("oracle: no ROM configured (set M2_ROM); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }

    const rom = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        build_options.rom_path,
        gpa,
        .limited(rom_mod.expected_size * 4),
    );

    // `zig build oracle -- movie [frames]` grades the port against a published
    // run instead of the hand-authored segment. See `oracle.gradeMovie`.
    var args_peek = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_peek.next();
    if (args_peek.next()) |first| {
        if (std.mem.eql(u8, first, "residue")) {
            try runResidue(gpa, init.io, out, rom);
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, first, "enemies")) {
            // `raw` prints each failing case's frames on both machines, and every
            // named case's.
            // Any other word names the cases to run, by substring.
            var raw = false;
            var only: []const u8 = "";
            while (args_peek.next()) |n| {
                if (std.mem.eql(u8, n, "raw")) raw = true else only = n;
            }
            const failed = try runEnemies(gpa, init.io, out, rom, init.environ_map.get("HOME") orelse "", raw, only);
            try out.flush();
            if (failed) std.process.exit(1);
            return;
        }
        if (std.mem.eql(u8, first, "hud")) {
            // `div` repeats the measurement `!DIV_STEP` rests on.
            const ho = @import("hud_oracle.zig");
            if (args_peek.next()) |n| if (std.mem.eql(u8, n, "div")) {
                var samples: [120]ho.DivSample = undefined;
                const got = try ho.measureDiv(gpa, rom, &samples);
                try out.print("{d} scrambled frames: DIV at 01:$49F9, and at $4A05\n", .{got});
                for (samples[1..got], samples[0 .. got - 1]) |s, p| {
                    try out.print("  frame {d:>6}  ${X:0>2} ${X:0>2}  +{d} frames, step ${X:0>2}\n", .{ s.frame, s.tens, s.ones, s.frame - p.frame, s.tens -% p.tens });
                }
                try out.flush();
                return;
            };
            var set = try convert.run(gpa, rom);
            defer set.deinit();
            const rec = try ho.loadRecording(gpa, init.io, rom);
            var rep = try ho.grade(gpa, init.io, rom, set, rec, build_options.mesen_path, init.environ_map.get("HOME") orelse "");
            defer rep.deinit(gpa);
            try out.print("{s}  status bar: ", .{if (rep.ok()) "ok  " else "FAIL"});
            try ho.printReport(out, rep, "");
            try out.flush();
            if (!rep.ok()) std.process.exit(1);
            return;
        }
        if (std.mem.eql(u8, first, "fade")) {
            // Step 20: the any% run's fade door, graded on brightness.
            const tas_mod = @import("tas.zig");
            const movie_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, tas_mod.any_percent, gpa, .limited(8 << 20));
            defer gpa.free(movie_bytes);
            const movie = try tas_mod.parse(movie_bytes);
            const rep = try oracle.gradeFade(gpa, init.io, rom, movie, build_options.mesen_path, oracle.movie_gate_frames);
            const ok = try oracle.printFade(out, rep);
            try out.flush();
            if (!ok) std.process.exit(1);
            return;
        }
        if (std.mem.eql(u8, first, "settle")) {
            try runSettle(gpa, init.io, out, rom);
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, first, "worlds")) {
            // `all` prints every cell reached; the default prints the
            // disagreements and counts the rest, because 200 agreeing rows
            // bury the four that matter.
            var all = false;
            if (args_peek.next()) |n| all = std.mem.eql(u8, n, "all");
            try runWorlds(gpa, init.io, out, rom, all);
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, first, "durations")) {
            var limit: usize = 8;
            if (args_peek.next()) |n| {
                limit = if (std.mem.eql(u8, n, "all")) std.math.maxInt(usize) else (std.fmt.parseInt(usize, n, 10) catch limit);
            }
            try runDurations(gpa, init.io, out, rom, limit, init.environ_map.get("HOME") orelse "");
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, first, "anchored")) {
            var min: u32 = oracle.anchor_min_frames;
            var limit: usize = 9000;
            // Pinned by default, because `zig build verify`'s anchored rung is
            // pinned and a CLI that reported a different sum from the gate for
            // the same cart would be a trap. `bucket` in any argument position
            // reproduces the old bucket-edge sum -- 386 against 394 on
            // 2026-09-05 -- which is what a floor's history is checked against.
            var resolution: oracle.Resolution = .exact;
            while (args_peek.next()) |n| {
                if (std.mem.eql(u8, n, "bucket")) {
                    resolution = .bucket;
                } else if (min == oracle.anchor_min_frames) {
                    min = @max(1, std.fmt.parseInt(u32, n, 10) catch min);
                } else {
                    limit = @max(1, std.fmt.parseInt(usize, n, 10) catch limit);
                }
            }
            try runAnchored(gpa, init.io, out, rom, min, limit, resolution);
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, first, "spider")) {
            var stride: usize = 10;
            var fault = true;
            while (args_peek.next()) |v| {
                if (std.mem.eql(u8, v, "nofault")) {
                    fault = false;
                    continue;
                }
                stride = @max(1, std.fmt.parseInt(usize, v, 10) catch stride);
            }
            try runSpider(gpa, init.io, out, rom, stride, fault);
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, first, "loadout")) {
            var stride: usize = 5;
            var fault = true;
            var only: []const u8 = "";
            var poke = false;
            while (args_peek.next()) |v| {
                if (std.mem.eql(u8, v, "nofault")) {
                    fault = false;
                    continue;
                }
                if (std.mem.eql(u8, v, "poke")) {
                    poke = true;
                    continue;
                }
                if (std.fmt.parseInt(usize, v, 10)) |n| {
                    stride = @max(1, n);
                } else |_| only = v;
            }
            try runLoadout(gpa, init.io, out, rom, stride, fault, only, poke);
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, first, "beams")) {
            var fault = true;
            var resolution: oracle.Resolution = .exact;
            var only: []const u8 = "";
            while (args_peek.next()) |v| {
                if (std.mem.eql(u8, v, "nofault")) {
                    fault = false;
                    continue;
                }
                // Leaves the whole take's script on disk, not the bisection's last.
                if (std.mem.eql(u8, v, "bucket")) {
                    resolution = .bucket;
                    continue;
                }
                only = v;
            }
            try runBeams(gpa, init.io, out, rom, fault, resolution, only);
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, first, "recorded")) {
            var window: usize = 2000;
            var start: usize = 0;
            var min: u32 = oracle.anchor_min_frames;
            // `fault` re-grades every seeded stretch against a cart built from
            // the map alone. See `oracle.Seeding`: it is what stops the seeding
            // from being an assertion about itself.
            var fault = false;
            var n: usize = 0;
            while (args_peek.next()) |v| {
                if (std.mem.eql(u8, v, "fault")) {
                    fault = true;
                    continue;
                }
                const parsed = std.fmt.parseInt(usize, v, 10) catch continue;
                switch (n) {
                    0 => start = parsed,
                    1 => window = @max(1, parsed),
                    2 => min = @max(1, @as(u32, @intCast(parsed))),
                    else => {},
                }
                n += 1;
            }
            try runRecorded(
                gpa,
                init.io,
                out,
                rom,
                start,
                window,
                min,
                fault,
                init.environ_map.get("HOME") orelse "",
            );
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, first, "movie")) {
            var want: usize = 600;
            // Pinned by default, for the same reason and at the same cost as
            // the anchored sweep: `bucket` reproduces the old bucket-edge
            // number when a floor's history has to be checked.
            var resolution: oracle.Resolution = .exact;
            while (args_peek.next()) |n| {
                if (std.mem.eql(u8, n, "bucket")) {
                    resolution = .bucket;
                } else {
                    want = @max(1, std.fmt.parseInt(usize, n, 10) catch 600);
                }
            }
            try runMovie(gpa, init.io, out, rom, want, resolution);
            try out.flush();
            return;
        }
    }

    // `zig build oracle -- 1` prints every frame of the reference; the default
    // is a tenth of them, which is enough to see the shape.
    var stride: usize = 10;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    if (args.next()) |a| stride = @max(1, std.fmt.parseInt(usize, a, 10) catch 10);
    // How many candidate cells the start search may consider. 1 pins it to the
    // cart's ordinary boot cell, which is what `zig build rom` ships.
    var cell_limit: usize = 8;
    if (args.next()) |a| cell_limit = @max(1, std.fmt.parseInt(usize, a, 10) catch 8);

    var rep = try oracle.grade(gpa, init.io, rom, build_options.mesen_path, cell_limit, true, .exact);
    const ref = rep.settled.frames;
    const pos = rep.settled.position();

    try out.print(
        "segment: {d} frames on map {d} cell ${X:0>2}, spawned at {X:0>4},{X:0>4}, settled at {X:0>4},{X:0>4}\n",
        .{
            oracle.segment_frames, rep.boot.map_index, rep.boot.cell,
            rep.spawned.position().x, rep.spawned.position().y, pos.x, pos.y,
        },
    );
    for (oracle.segment) |p| {
        var kb: [oracle.mesen_keys_max]u8 = undefined;
        try out.print("  {d: >4} frames  {s: <11} {s}\n", .{ p.frames, oracle.keyName(p.key, &kb), p.why });
    }

    try out.print(
        "\nthe Game Boy's answer: she ends at {X:0>4},{X:0>4} with the camera at {X:0>4},{X:0>4}\n",
        .{ ref[ref.len - 1].samus_x, ref[ref.len - 1].samus_y, ref[ref.len - 1].camera_x, ref[ref.len - 1].camera_y },
    );

    // A reference in which nothing moves would pass any port, including one
    // that does nothing at all.
    var moved: usize = 0;
    for (ref[1..], ref[0 .. ref.len - 1]) |a, b| moved += @intFromBool(!a.eql(b));
    try out.print("{d} of {d} frames changed something\n", .{ moved, ref.len });

    try out.print("\n  frame  key          samus        camera      pose\n", .{});
    var rowkb: [oracle.mesen_keys_max]u8 = undefined;
    for (ref, 0..) |f, i| {
        if (i % stride != 0 and i != ref.len - 1) continue;
        try out.print("  {d: >5}  {s: <11}  {X:0>4},{X:0>4}  {X:0>4},{X:0>4}  ${X:0>2}\n", .{
            i, oracle.keyName(oracle.keyAt(i), &rowkb), f.samus_x, f.samus_y, f.camera_x, f.camera_y, f.pose,
        });
    }

    try out.print("\nwrote {s} and {s}\n", .{ oracle.lua_name, oracle.cart_name });

    if (rep.no_emulator) {
        try out.print("no emulator configured (set MESEN); the cart and script are written\n", .{});
        try out.flush();
        return;
    }

    if (!rep.world.same()) {
        try out.print(
            "\nNOT THE SAME ROOM: the cart's world is cell ${X:0>2} through metatile table {d}, and\n" ++
                "the Game Boy agreed with it on {d} of the {d} tiles its camera window\n" ++
                "places inside that cell (its own best table is {d}, at {d}).\n" ++
                "Nothing below grades the port: the two are not standing in the same room.\n",
            .{
                rep.boot.cell,     rep.world.cart_table,
                rep.world.matched, rep.world.compared,
                rep.world.gb_best_table, rep.world.gb_best_matched,
            },
        );
    }

    if (rep.matched()) {
        try out.print("\nMATCH: {d} frames, position, camera and pose\n", .{oracle.segment_frames});
    } else if (rep.divergence()) |d| {
        if (d.exact()) {
            try out.print("\nDIVERGED: {s}, at frame {d} of {d}\n", .{
                oracle.explain(rep.code), d.first, oracle.segment_frames,
            });
        } else {
            try out.print("\nDIVERGED: {s}, at frame {d}-{d} of {d}\n", .{
                oracle.explain(rep.code), d.first, d.last, oracle.segment_frames,
            });
        }
        const f = @min(d.first, ref.len - 1);
        try out.print("  the Game Boy at frame {d}: {X:0>4},{X:0>4} camera {X:0>4},{X:0>4} pose ${X:0>2}\n", .{
            f, ref[f].samus_x, ref[f].samus_y, ref[f].camera_x, ref[f].camera_y, ref[f].pose,
        });
    } else {
        try out.print("\nFAILED: {s} (exit {d})\n", .{ oracle.explain(rep.code), rep.code });
    }
    try out.print("fault sweep: {d}/{d} injected one-pixel faults named the right frame\n", .{
        rep.faults_caught, rep.faults,
    });
    try out.print("pose sweep:  {d}/{d} injected pose faults named the right frame\n", .{
        rep.pose_faults_caught, rep.pose_faults,
    });
    try out.flush();
}

/// Grade the port against a published tool-assisted run.
///
/// The number this prints is F10's reachable-frame count: how far the cart
/// follows the original when both are started from a state neither of us chose
/// and handed the same inputs. It is expected to be small in Phase 0a and to
/// grow as the port grows; what matters is that it comes from the movie rather
/// than from a fixture we wrote, and that the reason it stops is named.
fn runMovie(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    want: usize,
    resolution: oracle.Resolution,
) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, tas.any_percent, gpa, .limited(4 << 20)) catch {
        try out.print("oracle: no movie at {s}; run tools/get-tas.sh\n", .{tas.any_percent});
        return;
    };
    const movie = try tas.parse(bytes);

    var rep = try oracle.gradeMovie(gpa, io, rom, movie, build_options.mesen_path, want, resolution);

    try out.print(
        "movie: the any% run, from its frame {d} -- the frame the game hands over\n" ++
            "  control, measured. {d} frames offered on map bank ${X:0>1} cell ${X:0>2}, starting at\n" ++
            "  {X:0>4},{X:0>4}, which is where the game put her and not where anything here chose.\n",
        .{ rep.origin, rep.offered, rep.boot.map_index + 9, rep.boot.cell, rep.boot.samus_x, rep.boot.samus_y },
    );

    if (rep.no_boot_for_cell) {
        try out.print("\nSTOPPED: the game's starting cell is not in use, so the cart cannot be pointed at it\n", .{});
        return;
    }

    try out.print("  the cell's tileset is {s}", .{rep.provenance.label()});
    if (rep.provenance_distance != 0) {
        try out.print(", {d} grid steps away", .{rep.provenance_distance});
    }
    try out.print(".\n", .{});

    if (rep.first_unsupported) |u| {
        try out.print(
            "  the movie asks for something the port has no key for at frame {d} (bits ${X:0>2}).\n" ++
                "  That is a ceiling on the comparison, not a verdict on the port.\n",
            .{ u, rep.unsupported_bits },
        );
    } else {
        try out.print("  every frame offered is representable in the port's inputs.\n", .{});
    }

    if (rep.no_emulator) {
        try out.print("\nno emulator configured (set MESEN); the cart and script are written\n", .{});
        return;
    }

    if (!rep.world.same()) {
        try out.print(
            "\nNOT THE SAME ROOM: the Game Boy agreed with the cart's world on {d} of {d} tiles.\n" ++
                "Nothing below grades the port.\n",
            .{ rep.world.matched, rep.world.compared },
        );
        return;
    }
    try out.print("  the two worlds agree on all {d} compared tiles.\n", .{rep.world.compared});

    if (rep.matched()) {
        try out.print("\nREACHABLE: {d} frame{s} of the movie, position and camera\n", .{ rep.offered, plural(rep.offered) });
    } else if (rep.divergence()) |d| {
        try out.print("\nREACHABLE: {d} frame{s}. {s} at frame {d}", .{ d.first, plural(d.first), oracle.explain(rep.code), d.first });
        if (d.exact()) {
            try out.print(" exactly", .{});
        } else {
            try out.print("-{d}", .{d.last});
        }
        try out.print(" of {d} offered\n", .{rep.offered});
        if (rep.exact_runs != 0 and rep.exact_frame == null) {
            try out.print("  the pin was abandoned after {d} run{s}: a truncated run diverged on a\n" ++
                "  different quantity than the full one, so the bucket stands. See `oracle.Bisect`.\n", .{
                rep.exact_runs, plural(rep.exact_runs),
            });
        } else if (rep.exact_runs != 0) {
            try out.print("  pinned to the frame in {d} extra emulator run{s}.\n", .{ rep.exact_runs, plural(rep.exact_runs) });
        }
    } else if (oracle.unhandledPose(rep.code)) |u| {
        // The one stop that names the next thing to port outright, which is
        // what the porting loop's step 2 otherwise reads out of the trace.
        try out.print("\nSTOPPED: {s} -- pose ${X:0>2}{s}.\n", .{
            oracle.explain(rep.code), u.pose, if (u.saturated) " or higher" else "",
        });
        try out.print("No frame count: the exit code carries the pose instead.\n", .{});
    } else {
        try out.print("\nFAILED: {s} (exit {d})\n", .{ oracle.explain(rep.code), rep.code });
    }
}

/// `zig build oracle -- settle` — how long after each handover of control the
/// two machines agree about the room, on the Game Boy side alone.
///
/// No emulator and no cart: this is the measurement that decides where an
/// anchor can honestly be placed, and it is the Game Boy's own duration for
/// each transition.
fn runSettle(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, rom: []const u8) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, tas.any_percent, gpa, .limited(4 << 20)) catch {
        try out.print("oracle: no movie at {s}; run tools/get-tas.sh\n", .{tas.any_percent});
        return;
    };
    const movie = try tas.parse(bytes);

    // One replay, shared by the anchors and by the settle search: see
    // `oracle.anchorsFrom`.
    var r = try tas.run(gpa, rom, movie, .{
        .max_frames = 9000, .stride = 1, .watch_save = false, .profile_record = false,
    });
    defer r.deinit(gpa);

    const anchors = try oracle.anchorsFrom(gpa, r.track(), oracle.anchor_min_frames);
    if (anchors.len == 0) {
        try out.print("settle: no handover of control inside the horizon\n", .{});
        return;
    }
    const horizon: u32 = @intCast(anchors[anchors.len - 1].origin + anchors[anchors.len - 1].frames);

    const found = try oracle.settleAnchors(gpa, rom, movie, anchors, r.track(), horizon);

    try out.print(
        "settle: for each handover of control in the any% run, the first frame from\n" ++
            "  which a cart can honestly be built -- same room on both machines, and the\n" ++
            "  same picture of it. The gap is the Game Boy's own duration for the change.\n\n",
        .{},
    );
    try out.print("   #  handover  settled  gap  tiles agreed\n", .{});
    for (found, 0..) |f, i| {
        try out.print("  {d: >2}  {d: >8}  ", .{ i, f.handover });
        if (f.origin) |o| {
            try out.print("{d: >7}  {d: >3}  {d} of {d}  (table {d})\n", .{
                o, f.frames().?, f.world.matched, f.world.compared, f.world.cart_table,
            });
        } else {
            // The tables, not just the count. `World` has computed both since
            // it was written and nothing printed them, which is why four
            // ungradable anchors read as "the cart cannot be booted into"
            // rather than as the tileset-assignment question they are: if the
            // table the cart names and the table that best explains what the
            // Game Boy was showing differ, that is the whole diagnosis.
            if (!f.had_boot) {
                try out.print("{s: >7}  {s: >3}  no boot record for the cell the game left her in\n", .{ "--", "--" });
            } else {
                try out.print("{s: >7}  {s: >3}  best {d} of {d} on map {d} cell ${X:0>2}: cart table {d} ({s}, {d} away), gb best {d} at {d}\n", .{
                    "--",                    "--",
                    f.world.matched,         f.world.compared,
                    f.map_index,             f.cell,
                    f.world.cart_table,      f.provenance.label(),
                    f.provenance_distance,   f.world.gb_best_table,
                    f.world.gb_best_matched,
                });
                if (f.world.compared == 0) {
                    // Nothing was compared, so nothing above is evidence about
                    // the tileset. What the window was is the whole diagnosis.
                    try out.print("{s: >22}at frame {d}: samus ${X:0>4},${X:0>4}, scx ${X:0>2} scy ${X:0>2}\n", .{
                        "", f.at, f.samus_x, f.samus_y, f.scx, f.scy,
                    });
                }
            }
        }
    }
}

/// `zig build oracle -- worlds [all]` — the tileset assignment, graded.
///
/// `screens.assign` infers a metatile table for every in-use cell: 41 stated by
/// a door, 838 inherited from the nearest warp target, 25 the bank's default.
/// **The render rung cannot check any of that**, because it renders the Game
/// Boy screen and the converted screen through the same chosen table -- it
/// would pass with every cell assigned wrongly. This is the check that can:
/// the table is an input on one side and an observation on the other.
///
/// No emulator and no cart. Both published runs are replayed on the Game Boy
/// side alone, and every cell either of them stands still in is graded.
fn runWorlds(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, rom: []const u8, all: bool) !void {
    try out.print(
        "worlds: `screens.assign`'s tileset choice for every cell a published run stands\n" ++
            "  still in, graded against the tiles the Game Boy was showing. The render rung\n" ++
            "  cannot see this: it draws both sides through the same chosen table.\n\n",
        .{},
    );

    var rows: std.ArrayList(oracle.CellWorld) = .empty;
    defer rows.deinit(gpa);

    for (tas.published) |pub_run| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, pub_run.path, gpa, .limited(4 << 20)) catch {
            try out.print("  no movie at {s}; run tools/get-tas.sh\n", .{pub_run.path});
            continue;
        };
        defer gpa.free(bytes);
        const movie = try tas.parse(bytes);

        var r = try tas.run(gpa, rom, movie, .{
            .max_frames = pub_run.floor, .stride = 1, .watch_save = false, .profile_record = false,
        });
        defer r.deinit(gpa);

        const found = try oracle.sweepWorlds(gpa, rom, movie, pub_run.name, r.samples, pub_run.floor);
        defer gpa.free(found);

        // The runs overlap for most of the surface. A cell both reach is kept
        // once, from whichever run saw more of it.
        for (found) |row| {
            const slot = for (rows.items, 0..) |o, i| {
                if (o.map_index == row.map_index and o.cell == row.cell) break i;
            } else null;
            if (slot) |i| {
                const old = rows.items[i].world;
                if (row.world.compared > old.compared) rows.items[i] = row;
            } else try rows.append(gpa, row);
        }
    }

    if (rows.items.len == 0) {
        try out.print("worlds: no cell was stayed in long enough to be graded\n", .{});
        return;
    }

    try out.print("  map  cell  frame   run   tiles agreed   assigned                                  best\n", .{});
    var agreed: usize = 0;
    var disagreed: usize = 0;
    var empty: usize = 0;
    var partial: usize = 0;
    for (rows.items) |row| {
        if (row.world.compared == 0) empty += 1 else if (row.disagrees()) disagreed += 1 else if (row.agrees()) agreed += 1 else partial += 1;
        if (!all and !row.disagrees() and row.world.compared != 0) continue;
        try out.print("  {d: >3}   ${X:0>2}  {d: >6}  {s: >4}   {d: >4} of {d: >4}   table {d} ({s}, {d} away)", .{
            row.map_index,       row.cell,
            row.frame,           row.movie,
            row.world.matched,   row.world.compared,
            row.world.cart_table, row.provenance.label(),
            row.distance,
        });
        if (row.world.compared == 0) {
            try out.print("   -- no window inside the cell\n", .{});
        } else {
            try out.print("   table {d} at {d}\n", .{ row.world.gb_best_table, row.world.gb_best_matched });
        }
    }

    try out.print(
        "\nWORLDS: {d} cells reached; {d} agree tile for tile, {d} another table explains better,\n" ++
            "  {d} imperfect with no better table, {d} with no window inside the cell\n",
        .{ rows.items.len, agreed, disagreed, partial, empty },
    );
}

/// `zig build oracle -- anchored [min] [limit]` — the re-anchored comparison.
///
/// One line per playable stretch, then the sum. Per stretch as well as in total
/// because a total hides which stretch regressed, which is the whole reason the
/// count is reported this way rather than as one number.
fn runAnchored(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    min: u32,
    limit: usize,
    resolution: oracle.Resolution,
) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, tas.any_percent, gpa, .limited(4 << 20)) catch {
        try out.print("oracle: no movie at {s}; run tools/get-tas.sh\n", .{tas.any_percent});
        return;
    };
    const movie = try tas.parse(bytes);

    var an = try oracle.gradeAnchored(gpa, io, rom, movie, build_options.mesen_path, min, limit, null, resolution);
    defer an.deinit(gpa);

    if (an.stretches.len == 0) {
        try out.print("anchored: no handover of control inside the horizon; nothing to grade\n", .{});
        return;
    }

    try out.print(
        "anchored: the any% run, {d} stretch{s} to the horizon at frame {d}, anchored on\n" ++
            "  every refusal of {d}+ frames the game hands back. Each stretch is graded from\n" ++
            "  its own boot record, so one the port cannot enter costs that stretch alone.\n\n",
        .{ an.stretches.len, if (an.stretches.len == 1) "" else "es", an.horizon, an.min },
    );

    try printStretches(out, an);
}

/// The anchored table, shared by both sweeps.
///
/// Split out when the recorded sweep arrived: it grades the same stretches
/// against the same carts and differs only in where its references come from,
/// so a second copy of this table would be a second place for the two to drift.
fn printStretches(out: *std.Io.Writer, an: oracle.Anchored) !void {
    try out.print("   #  anchor  +trans  offered  reached  map cell  pose  face  pad   stopped by\n", .{});
    for (an.stretches, 0..) |st, i| {
        try out.print("  {d: >2}  {d: >6}  {d: >6}  ", .{ i, st.anchor.origin, st.anchor.transition() });
        const rep = st.rep orelse {
            try out.print("{d: >7}  {s: >7}  {s: >8}  {s: >4}  {s: >4}  {s: >4}  {s}\n", .{
                st.anchor.frames, "--", "--", "--", "--", "--", st.withheld().?,
            });
            continue;
        };
        try out.print("{d: >7}  ", .{rep.offered});
        if (st.reached()) |n| {
            try out.print("{d: >7}", .{n});
        } else {
            try out.print("{s: >7}", .{"--"});
        }
        try out.print("  {d: >3} ${X:0>2}   ${X:0>2}   ${X:0>2}  ${X:0>4}  ", .{
            rep.boot.map_index + 9, rep.boot.cell, rep.boot.pose, rep.boot.facing, rep.boot.input,
        });
        if (st.withheld()) |why| {
            try out.print("{s}\n", .{why});
        } else if (rep.matched()) {
            try out.print("nothing: every frame offered matched\n", .{});
        } else if (rep.divergence()) |d| {
            try out.print("{s} at frame {d}", .{ oracle.explain(rep.code), d.first });
            if (!d.exact()) try out.print("-{d}", .{d.last});
            try out.print("\n", .{});
        } else {
            try out.print("{s} (exit {d})\n", .{ oracle.explain(rep.code), rep.code });
        }
    }

    try out.print(
        "\nREACHABLE: {d} of {d} frames across {d} of {d} stretches\n",
        .{ an.reached(), an.offered(), an.graded(), an.stretches.len },
    );
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// `zig build oracle -- durations [n|all]` — grade the non-playable stretches
/// on length instead of frame-exactly.
///
/// See `src/duration.zig`. The default measures the first few, because the full
/// census is around seventy stretches and each costs an emulator run.
fn runDurations(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    limit: usize,
    home: []const u8,
) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, tas.any_percent, gpa, .limited(4 << 20)) catch {
        try out.print("oracle: no movie at {s}; run tools/get-tas.sh\n", .{tas.any_percent});
        return;
    };
    const movie = try tas.parse(bytes);

    var rep = try duration.measure(
        gpa, io, rom, movie, build_options.mesen_path, home, oracle.anchored_gate_limit, limit,
    );
    defer rep.deinit(gpa);

    try out.print(
        "durations: every stretch of the any% run the player is not playing, to the\n" ++
            "  horizon at frame {d}. Play is graded frame-exactly by `oracle -- anchored`;\n" ++
            "  these are graded on length, inside {d:.0}%. A stretch the port does not have\n" ++
            "  at all is absent, which is not 0%.\n\n",
        .{ rep.horizon, duration.tolerance_percent },
    );

    try out.print("  kind      frame  gb  port      pct  anchor  from     to\n", .{});
    for (rep.rows) |row| {
        try out.print("  {s: <8} {d: >6} {d: >3}  ", .{ row.gb.kind.label(), row.gb.start, row.gb.frames });
        switch (row.port) {
            .frames => |n| try out.print("{d: >8}", .{n}),
            .diverged => try out.print("{s: >8}", .{"diverged"}),
            else => try out.print("{s: >8}", .{row.port.label()}),
        }
        if (row.percent()) |pct| {
            try out.print("  {d: >6.1}", .{pct});
        } else {
            try out.print("  {s: >6}", .{"--"});
        }
        if (row.anchor) |a| {
            try out.print("  {d: >6}", .{a});
        } else {
            try out.print("  {s: >6}", .{"--"});
        }
        try out.print("  ${X:0>1}/${X:0>2}   ${X:0>1}/${X:0>2}", .{
            row.gb.from.map_bank, row.gb.from.cell, row.gb.to.map_bank, row.gb.to.cell,
        });
        if (row.within()) |ok| try out.print("   {s}", .{if (ok) "agrees" else "DIFFERS"});
        switch (row.port) {
            .diverged => |f| try out.print("   the port left the run at frame {d}", .{f}),
            .no_boot => |w| if (w.compared != 0) {
                try out.print("   best {d} of {d} tiles in {d} frames", .{ w.matched, w.compared, duration.anchor_search });
            },
            else => {},
        }
        try out.print("\n", .{});
    }

    try out.print(
        "\n{d} stretches: {d} compared, {d} inside {d:.0}%; {d} absent, {d} unreachable, " ++
            "{d} stuck, {d} with no key, {d} whose world never matched, {d} with no cell,\n" ++
            "{d} before the port's frame zero, {d} not asked\n",
        .{
            rep.rows.len,                   rep.compared(),
            rep.agreeing(),                 duration.tolerance_percent,
            rep.counting(.absent),          rep.counting(.diverged),
            rep.counting(.stuck),           rep.counting(.unrepresentable),
            rep.counting(.no_boot),         rep.counting(.no_cell),
            rep.counting(.before_port),     rep.counting(.unmeasured),
        },
    );
    try out.print(
        "the longest single-frame step that was not a room change is {d} pixels, at\n" ++
            "  frame {d}; a warp is cut at {d}, which is one whole screen\n",
        .{ rep.longest_step, rep.longest_at, duration.warp_step },
    );
}

/// `zig build oracle -- residue` — the audit from `src/residue.zig`, printed.
///
/// No emulator: the Game Boy side is a movie replay and the cart side is the
/// boot record the injector would write, so this runs wherever a ROM and the
/// published run are present.
fn runResidue(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, rom: []const u8) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, tas.any_percent, gpa, .limited(8 << 20)) catch {
        try out.print("residue: no published run at {s}; run tools/get-tas.sh\n", .{tas.any_percent});
        return;
    };
    var au = try residue.audit(gpa, rom, try tas.parse(bytes));
    defer au.deinit(gpa);

    try out.print(
        "residue audit at the handover: control frame {d}, reference frame 0 is movie frame {d}\n\n",
        .{ au.control, au.origin },
    );
    try out.print("{s: <14} {s: <12} {s: <8} {s: <7} {s: <7} {s}\n", .{
        "variable", "established", "carry", "gb", "cart", "status",
    });
    for (au.rows) |r| {
        var gb_buf: [8]u8 = undefined;
        var cart_buf: [8]u8 = undefined;
        const gb = if (r.gb) |v| try std.fmt.bufPrint(&gb_buf, "${X:0>2}", .{v}) else "-";
        const cart = if (r.cart) |v| try std.fmt.bufPrint(&cart_buf, "${X:0>2}", .{v}) else "-";
        try out.print("{s: <14} {s: <12} {s: <8} {s: <7} {s: <7} {s}\n", .{
            r.field.define, @tagName(r.field.establishes), @tagName(r.field.carry),
            gb, cart, @tagName(r.status()),
        });
    }

    try out.print(
        "\n{d} fields, {d} carried across a frame; measured: {d} agree, {d} differ; {d} carried and unmeasured\n",
        .{
            au.rows.len, residue.carriedCount(),
            au.count(.same), au.count(.differs), au.count(.unmeasured),
        },
    );

    try out.print("\nthe reference's first frames, to test the walk-alternation prediction:\n", .{});
    try out.print("  frame   ", .{});
    for (0..8) |i| try out.print("{d: >5}", .{i});
    try out.print("\n  $FF97   ", .{});
    for (au.counters) |c| try out.print("{d: >5}", .{c});
    try out.print("\n  pose    ", .{});
    for (au.poses) |p| try out.print("{X: >5}", .{p});
    try out.print("\n  dx      ", .{});
    for (au.steps) |d| try out.print("{d: >5}", .{d});
    try out.print("\n", .{});

    for (au.rows) |r| {
        if (r.status() != .differs and r.status() != .unmeasured) continue;
        try out.print("\n{s} [{s}]\n  {s}\n", .{ r.field.define, @tagName(r.status()), r.field.note });
    }
}

/// `zig build oracle -- recorded [start] [window] [min]` — the anchored sweep
/// over James's recording, with every reference taken off Mesen2.
///
/// **This is the sweep the horizon does not bound.** `anchored` grades the
/// published any% run, whose replay on our own Game Boy collapses at frame
/// 8 442 — and inside that horizon not one Metroid is killed, no Energy Tank
/// is taken and no save is made, so Steps 10–14 have nothing there to be
/// graded against. The recording holds all of it: two Alpha kills, four
/// pickups, a death and a reload. Our Game Boy cannot replay it either, and
/// that is the point of this path: Mesen replays it, and nothing here replays
/// anything.
///
/// The cost is honest and worth writing down. The census is `max_frames` rows
/// per Mesen run and every reference batch is another, each a full replay from
/// the movie's start — so a deep window is minutes to most of an hour. The
/// gate's `recorded` rung grades the one window that is cheap, the first 2000
/// frames (`oracle.recorded_gate_window`); every other window is this tool's.
fn runRecorded(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    start: usize,
    window: usize,
    min: u32,
    fault: bool,
    home: []const u8,
) !void {
    // With `fault` this is `verify-full`'s rung, and a rung that could not run
    // must not read as one that passed.
    if (build_options.mesen_path.len == 0) {
        try out.print("oracle: no emulator configured (set MESEN); see docs/setup.md\n", .{});
        if (fault) std.process.exit(1);
        return;
    }
    const mmo = std.Io.Dir.cwd().readFileAlloc(io, gb_trace.recording_path, gpa, .limited(64 << 20)) catch {
        try out.print(
            "oracle: no recording at {s}. It is vendored and not downloadable: see tools/get-tas.sh\n",
            .{gb_trace.recording_path},
        );
        if (fault) std.process.exit(1);
        return;
    };
    var rec = try gb_trace.readRecording(gpa, mmo);
    defer rec.deinit(gpa);
    rec.checkCartridge(rom) catch {
        try out.print("oracle: {s} was recorded on another cartridge ({s})\n", .{
            gb_trace.recording_path, rec.sha1() orelse "?",
        });
        return;
    };

    try out.print(
        "recorded: {d} frames, anchoring over [{d}, {d}). Every reference comes off\n" ++
            "  Mesen2 — our own Game Boy loses this run at 28 796 frames, and the published\n" ++
            "  run's horizon at 8 442 contains no kill, no pickup and no save.\n\n",
        .{ rec.frames(), start, start + window },
    );
    try out.print("census: {d} row(s) a pass, so {d} pass(es) before anything is graded\n", .{
        gb_trace.max_frames, (window + gb_trace.max_frames - 1) / gb_trace.max_frames,
    });
    try out.flush();

    // The same call the gate's `recorded` rung makes, so a red rung and this
    // table are the same sweep. The census is printed after the grading
    // rather than before it for that reason.
    var r = try oracle.gradeRecorded(gpa, io, rom, rec, start, window, min, fault, build_options.mesen_path, home);
    defer r.deinit(gpa);
    const cen = r.census;
    if (cen.samples.len == 0) {
        try out.print("recorded: the census recorded nothing; the pass never reached {d}\n", .{start});
        return;
    }
    const track = tas.Track.ofSamples(cen.samples);
    try out.print("census: {d} frame(s) to {d}, {d} bank(s), metroids {d} -> {d}\n", .{
        cen.samples.len, track.end(), track.bankCount(), track.metroid_first, track.metroid_min,
    });
    // The alignment, from the game's own $FF80 rather than from a comment.
    try out.print("census: lag {d}, measured on {d} of {d} pass(es)\n", .{
        cen.lag, cen.checked, cen.passes,
    });
    // Only a report's field: every stretch carries its own handover, which is
    // what the grading actually uses.
    if (r.opening) |op| {
        try out.print("opening: start at {d}, room at {d}, placed at {d}, control at {d}\n\n", .{
            op.start_pressed, op.room_loaded, op.placed, op.control,
        });
    } else if (start == 0) {
        try out.print("recorded: no opening in the window; control reported as 0\n", .{});
    }
    const an = r.an;

    if (an.stretches.len == 0) {
        try out.print("recorded: no handover of control in the window; nothing to grade\n", .{});
        return;
    }
    try out.print(
        "\nrecorded: {d} stretch{s} to frame {d}, anchored on every refusal of {d}+ frames.\n" ++
            "  {d} Mesen pass(es) for the references; {d} stretch(es) capped to what one\n" ++
            "  pass holds ({d} frames), which grades fewer frames rather than grading\n" ++
            "  frames the reference does not have.\n\n",
        .{
            an.stretches.len,
            if (an.stretches.len == 1) "" else "es",
            an.horizon,
            an.min,
            r.passes,
            r.capped,
            gb_trace.refFramesBudget(1),
        },
    );
    try printStretches(out, an);
    // Why each anchor that did not settle did not. **The most expensive thing
    // a sweep reports and the least explained**: the table above says "no frame
    // this room can be booted at" and nothing about whether that is the wrong
    // room, the right room drawn from the wrong tileset, or a window that
    // overlapped the cell by nothing at all.
    var unsettled: usize = 0;
    for (an.settling) |f| unsettled += @intFromBool(f.origin == null);
    if (unsettled != 0) {
        try out.print("\nUNSETTLED: {d} anchor(s) found no frame a cart can be built at\n", .{unsettled});
        for (an.settling, 0..) |f, i| {
            if (f.origin != null) continue;
            if (!f.had_boot) {
                try out.print("  {d: >2}  handover {d: >6}: no boot record for the cell the game left her in\n", .{ i, f.handover });
                continue;
            }
            try out.print(
                "  {d: >2}  handover {d: >6}: best {d} of {d} ({d} block(s)) at frame {d} on map {d} cell ${X:0>2};" ++
                    " cart table {d} ({s}, {d} away), gb best {d} at table {d}\n",
                .{
                    i,                     f.handover,
                    f.world.matched,       f.world.compared,
                    f.world.blocks,        f.at,
                    f.map_index,           f.cell,
                    f.world.cart_table,    f.provenance.label(),
                    f.provenance_distance, f.world.gb_best_matched,
                    f.world.gb_best_table,
                },
            );
            if (f.world.compared == 0) {
                try out.print("      window: samus ${X:0>4},${X:0>4}, scx ${X:0>2} scy ${X:0>2} — nothing compared\n", .{
                    f.samus_x, f.samus_y, f.scx, f.scy,
                });
            }
        }
    }

    // The world, and whether it mattered. Both numbers, because "0 seeded" and
    // "4 seeded, all four caught" are different facts and only one of them is
    // about this sweep's terrain.
    try out.print("\nWORLD: {d} stretch(es) seeded with {d} tile(s) the map does not have\n", .{
        an.seededStretches(), an.seededTiles(),
    });
    if (fault) {
        try out.print("FAULT: {d} of {d} seeded stretch(es) lost frames without the seeding\n", .{
            an.faultsCaught(), an.faultsRun(),
        });
        for (an.stretches, 0..) |st, i| {
            const f = st.fault orelse continue;
            try out.print("  {d: >2}  anchor {d: >6}  seeded {d: >3} tile(s): {d} frame(s) with, {d} without\n", .{
                i,
                st.anchor.origin,
                (st.rep orelse continue).seeded,
                st.reached() orelse 0,
                oracle.reachedFrames(f) orelse 0,
            });
        }
        // 1.0 Step 18c2: at least one catch, held to the pins. See
        // `oracle.seeding_catches`.
        const rows = try an.seedRows(gpa);
        defer gpa.free(rows);
        const v = oracle.gradeSeeding(rows, &oracle.seeding_catches, oracle.seeding_frames_floor);
        if (!try printSeeding(out, v)) {
            try out.flush();
            std.process.exit(1);
        }
    }
}

/// The seeding fixture's verdict against its pins. True when it passes.
pub fn printSeeding(out: *std.Io.Writer, v: oracle.SeedingVerdict) !bool {
    try out.print("PINS:  {d} catch(es), {d} pinned; {d} frame(s) seeded, floor {d}\n", .{
        v.caught, oracle.seeding_catches.len, v.frames, v.floor,
    });
    for (v.lost[0..v.n_lost]) |a| try out.print("FAIL:  anchor {d} caught at the pin and does not now\n", .{a});
    if (v.frames < v.floor) try out.print("FAIL:  the seeded stretches play {d} frame(s), under the floor of {d}\n", .{ v.frames, v.floor });
    if (v.caught == 0) try out.print("FAIL:  no seeded stretch lost frames without the seeding: the comparison\n       is not reading the terrain the anchor loaded\n", .{});
    for (v.gained[0..v.n_gained]) |a| try out.print("raise the pin: anchor {d} catches and is not pinned\n", .{a});
    if (v.frames > v.floor) try out.print("raise the pin: {d} frame(s) over the floor\n", .{v.frames - v.floor});
    if (v.ok()) try out.print("ok    seeding           {d} of {d} seeded stretch(es) lost frames without the seeding; the pins hold\n", .{ v.caught, v.run });
    return v.ok();
}

/// `zig build oracle -- enemies`: each ported AI against the Game Boy running
/// it, and then against a cart with its `AiTable` row blanked, which has to
/// disagree. See `src/enemy_oracle.zig`.
fn runEnemies(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, rom: []const u8, home: []const u8, raw: bool, only: []const u8) !bool {
    const eo = @import("enemy_oracle.zig");
    var set = try convert.run(gpa, rom);
    defer set.deinit();
    var failed = false;
    // Both lists: the AI cases and Step 19's reload cases, which the gate runs as
    // two rungs and which this names by substring either way.
    // Graded four at a time, as the gate grades them.
    var picked: std.ArrayList(eo.Case) = .empty;
    defer picked.deinit(gpa);
    for (eo.cases ++ eo.reload_cases) |c| {
        if (std.mem.indexOf(u8, c.name, only) != null) try picked.append(gpa, c);
    }
    const reps = try gpa.alloc(eo.CaseReport, picked.items.len);
    defer gpa.free(reps);
    try eo.gradeCases(gpa, io, rom, set, picked.items, 4, build_options.mesen_path, home, reps);
    defer for (reps) |*r| r.deinit(gpa);
    for (reps) |rep| {
        if (!rep.ok()) failed = true;
        try out.print("{s}  ", .{if (rep.ok()) "ok  " else "FAIL"});
        try eo.printCase(out, rep, "");
        if (raw and (!rep.ok() or only.len != 0)) try eo.printRaw(out, rep, if (rep.verdict) |v| (v.first_diff orelse 0) * 2 -| 8 else 0, if (only.len != 0) 600 else 30);
    }
    return failed;
}

/// `zig build oracle -- loadout [name] [stride] [nofault] [poke]`: 1.0 Step
/// 7's loadout segments, each graded with its item set through the debug menu
/// and then again with its engine fault, which must differ. `poke` writes the
/// item instead, as the spider segment does: a diagnostic, for telling the
/// menu's setup apart from the port when a segment differs.
fn runLoadout(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    stride: usize,
    fault: bool,
    only: []const u8,
    poke: bool,
) !void {
    const items = @import("items.zig");
    for (oracle.loadout_segments) |seg| {
        if (only.len != 0 and !std.mem.eql(u8, only, seg.name)) continue;
        const bit = (try items.bitFor(rom, seg.item)) orelse {
            try out.print("{s}: the ROM's pickup arm sets no bit\n", .{seg.name});
            continue;
        };
        const lo: oracle.Loadout = .{ .items = @as(u8, 1) << bit, .via = if (poke) .poke else .menu };
        var rep = try oracle.gradeWith(gpa, io, rom, build_options.mesen_path, 8, false, .exact, seg.phases, lo);
        const ref = rep.settled.frames;
        const keys = try oracle.phaseKeys(gpa, seg.phases);
        try out.print("\n{s}: {d} frames on map {d} cell ${X:0>2}, $D045 bit {d} set through the debug menu\n", .{
            seg.name, ref.len, rep.boot.map_index, rep.boot.cell, bit,
        });
        var poses: [256]usize = @splat(0);
        for (ref) |f| poses[f.pose] += 1;
        try out.print("the Game Boy's poses:", .{});
        for (poses, 0..) |n, pz| if (n != 0) try out.print(" ${X:0>2}x{d}", .{ pz, n });
        try out.print("\n  frame  key          samus        camera      pose  $FF97\n", .{});
        var kb: [oracle.mesen_keys_max]u8 = undefined;
        for (ref, 0..) |f, i| {
            if (i % stride != 0 and i != ref.len - 1) continue;
            try out.print("  {d: >5}  {s: <11}  {X:0>4},{X:0>4}  {X:0>4},{X:0>4}  ${X:0>2}   ${X:0>2}\n", .{
                i, oracle.keyName(keys[i], &kb), f.samus_x, f.samus_y, f.camera_x, f.camera_y, f.pose, f.counter,
            });
        }
        if (rep.no_emulator) {
            try out.print("no emulator configured (set MESEN)\n", .{});
            continue;
        }
        if (rep.matched()) {
            try out.print("MATCH: {d} frames, position, camera and pose\n", .{ref.len});
        } else if (rep.divergence()) |d| {
            try out.print("DIVERGED: {s}, at frame {d}-{d} of {d}\n", .{ oracle.explain(rep.code), d.first, d.last, ref.len });
            const f = @min(d.first, ref.len - 1);
            try out.print("  the Game Boy at frame {d}: {X:0>4},{X:0>4} camera {X:0>4},{X:0>4} pose ${X:0>2}\n", .{
                f, ref[f].samus_x, ref[f].samus_y, ref[f].camera_x, ref[f].camera_y, ref[f].pose,
            });
        } else {
            try out.print("FAILED: {s} (exit {d})\n", .{ oracle.explain(rep.code), rep.code });
        }
        if (!fault) continue;
        var faulted = lo;
        faulted.patch = seg.fault;
        const frep = try oracle.gradeWith(gpa, io, rom, build_options.mesen_path, 8, false, .exact, seg.phases, faulted);
        if (frep.divergence()) |d| {
            try out.print("fault {s}+{d}: differs, {s} at frame {d}\n", .{ seg.fault.label, seg.fault.offset, oracle.explain(frep.code), d.first });
        } else {
            try out.print("fault {s}+{d}: NOT caught (exit {d}: {s})\n", .{ seg.fault.label, seg.fault.offset, frep.code, oracle.explain(frep.code) });
        }
    }
}

/// `zig build oracle -- beams [name] [nofault]`: 1.0 Step 8c's beam
/// segments, each with its beam set through the debug menu, the projectile
/// array printed on every frame the Game Boy had a shot in the air, then
/// graded, and graded again with its fault.
fn runBeams(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    fault: bool,
    resolution: oracle.Resolution,
    only: []const u8,
) !void {
    for (oracle.beam_segments) |seg| {
        if (only.len != 0 and !std.mem.eql(u8, only, seg.name)) continue;
        const rep = try oracle.gradeBeam(gpa, io, rom, build_options.mesen_path, resolution, seg, null);
        const ref = rep.settled.frames;
        const keys = try oracle.phaseKeys(gpa, seg.phases);
        try out.print("\n{s}: {d} frames on map {d} cell ${X:0>2}, beam ${X:0>2} through the debug menu", .{
            seg.name, ref.len, rep.boot.map_index, rep.boot.cell, try oracle.beamValue(rom, seg.beam),
        });
        if (rep.settled.seed) |sd| try out.print(", enemy sprite ${X:0>2} seeded at {X:0>2},{X:0>2}", .{ sd.bytes[3], sd.bytes[1], sd.bytes[2] });
        try out.print("\n  frame  key          samus        projectiles (type y x) x3\n", .{});
        var kb: [oracle.mesen_keys_max]u8 = undefined;
        for (ref, 0..) |f, i| {
            const live = f.projs[0] != 0xFF or f.projs[3] != 0xFF or f.projs[6] != 0xFF;
            const was = i > 0 and (ref[i - 1].projs[0] != 0xFF or ref[i - 1].projs[3] != 0xFF or ref[i - 1].projs[6] != 0xFF);
            if (!live and !was and seg.enemy == null and !seg.health) continue;
            try out.print("  {d: >5}  {s: <11}  {X:0>4},{X:0>4} cam {X:0>4},{X:0>4} pose {X:0>2} hp {X:0>4} ", .{ i, oracle.keyName(keys[i], &kb), f.samus_x, f.samus_y, f.camera_x, f.camera_y, f.pose, f.health });
            for (0..oracle.proj_slots) |slot| {
                const b = f.projs[slot * 3 ..][0..3];
                if (b[0] == 0xFF) try out.print("   --      ", .{}) else try out.print("   {X:0>2} {X:0>2} {X:0>2}", .{ b[0], b[1], b[2] });
            }
            if (seg.enemy != null) try out.print("   enemy {X:0>2} {X:0>2},{X:0>2} hp {X:0>2}", .{ f.enemy0[0], f.enemy0[1], f.enemy0[2], f.enemy0[3] });
            try out.print("\n", .{});
        }
        if (rep.no_emulator) {
            try out.print("no emulator configured (set MESEN)\n", .{});
            continue;
        }
        if (rep.matched()) {
            try out.print("MATCH: {d} frames, Samus and the projectiles\n", .{ref.len});
        } else if (rep.divergence()) |d| {
            try out.print("DIVERGED: {s}, at frame {d}-{d} of {d}\n", .{ oracle.explain(rep.code), d.first, d.last, ref.len });
        } else {
            try out.print("FAILED: {s} (exit {d})\n", .{ oracle.explain(rep.code), rep.code });
        }
        if (!fault) continue;
        for (seg.faults) |f| {
            const frep = try oracle.gradeBeam(gpa, io, rom, build_options.mesen_path, resolution, seg, f);
            if (frep.divergence()) |d| {
                try out.print("fault {s}+{d}: differs, {s} at frame {d}\n", .{ f.label, f.offset, oracle.explain(frep.code), d.first });
            } else {
                try out.print("fault {s}+{d}: NOT caught (exit {d}: {s})\n", .{ f.label, f.offset, frep.code, oracle.explain(frep.code) });
            }
        }
    }
}

/// `zig build oracle -- spider [stride] [nofault]`: Step 14b's spider segment,
/// the segment oracle's start and comparison over `oracle.spider_segment` with
/// Spider Ball held on both machines from its first frame.
fn runSpider(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rom: []const u8,
    stride: usize,
    fault: bool,
) !void {
    const items = @import("items.zig");
    const bit = (try items.bitFor(rom, .spider_ball)) orelse {
        try out.print("oracle: the ROM's Spider Ball arm sets no bit\n", .{});
        return;
    };
    var rep = try oracle.gradeWith(gpa, io, rom, build_options.mesen_path, 8, fault, .exact, &oracle.spider_segment, .{ .items = @as(u8, 1) << bit });
    const ref = rep.settled.frames;
    const keys = try oracle.phaseKeys(gpa, &oracle.spider_segment);

    try out.print("spider: {d} frames on map {d} cell ${X:0>2}, Spider Ball ($D045 bit {d}) held\n", .{
        ref.len, rep.boot.map_index, rep.boot.cell, bit,
    });
    for (oracle.spider_segment) |p| {
        var kb: [oracle.mesen_keys_max]u8 = undefined;
        try out.print("  {d: >4} frames  {s: <11} {s}\n", .{ p.frames, oracle.keyName(p.key, &kb), p.why });
    }
    var poses: [256]usize = @splat(0);
    for (ref) |f| poses[f.pose] += 1;
    try out.print("\nthe Game Boy's poses:", .{});
    for (poses, 0..) |n, pz| if (n != 0) try out.print(" ${X:0>2}x{d}", .{ pz, n });
    try out.print("\n\n  frame  key          samus        camera      pose\n", .{});
    var kb2: [oracle.mesen_keys_max]u8 = undefined;
    for (ref, 0..) |f, i| {
        if (i % stride != 0 and i != ref.len - 1) continue;
        try out.print("  {d: >5}  {s: <11}  {X:0>4},{X:0>4}  {X:0>4},{X:0>4}  ${X:0>2}\n", .{
            i, oracle.keyName(keys[i], &kb2), f.samus_x, f.samus_y, f.camera_x, f.camera_y, f.pose,
        });
    }
    if (rep.no_emulator) {
        try out.print("no emulator configured (set MESEN)\n", .{});
        return;
    }
    if (rep.matched()) {
        try out.print("\nMATCH: {d} frames, position, camera and pose\n", .{ref.len});
    } else if (rep.divergence()) |d| {
        try out.print("\nDIVERGED: {s}, at frame {d}-{d} of {d}\n", .{ oracle.explain(rep.code), d.first, d.last, ref.len });
        const f = @min(d.first, ref.len - 1);
        try out.print("  the Game Boy at frame {d}: {X:0>4},{X:0>4} camera {X:0>4},{X:0>4} pose ${X:0>2}\n", .{
            f, ref[f].samus_x, ref[f].samus_y, ref[f].camera_x, ref[f].camera_y, ref[f].pose,
        });
    } else {
        try out.print("\nFAILED: {s} (exit {d})\n", .{ oracle.explain(rep.code), rep.code });
    }
    if (fault) try out.print("fault sweep: {d}/{d} position, {d}/{d} pose\n", .{
        rep.faults_caught, rep.faults, rep.pose_faults_caught, rep.pose_faults,
    });
}
