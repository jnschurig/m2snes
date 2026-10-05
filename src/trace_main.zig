//! `zig build trace` — run the oracle's segment on the cart and print what the
//! engine did, frame by frame, beside what the original did.
//!
//! The oracle answers "when did the two machines disagree" in one byte, because
//! one byte is all a `--testrunner` exit code has. This answers "why", by
//! handing the emulator a cart with save RAM and reading the trace it leaves
//! behind. See `src/snes_trace.zig` for the channel.
//!
//! `zig build trace -- [first] [count]` prints a window; the default is the
//! frames around the first divergence, which is the window a person wants.
//!
//! `zig build trace -- at F [span] [first] [count]` anchors a cart at movie
//! frame `F`, traces `span` frames from there, and prints `count` of them from
//! `first`. That is the anchor `duration.zig` uses and prints, so a
//! row of `oracle -- durations` can be looked into by handing its anchor here.
//!
//! `zig build trace -- stretch N [first] [count]` traces stretch `N` of the
//! re-anchored comparison instead of the segment. The oracle answers *where* a
//! stretch stopped in one byte; this is the only thing that answers *why*, and
//! twelve of the thirteen stretches are ones the segment cannot speak for.

const std = @import("std");
const build_options = @import("build_options");
const rom_mod = @import("rom.zig");
const oracle = @import("oracle.zig");
const trace = @import("snes_trace.zig");
const tileset = @import("tileset.zig");
const offsets = @import("offsets.zig");
const door = @import("door.zig");
const screens = @import("screens.zig");
const tas = @import("tas.zig");
const convert = @import("snes_convert.zig");

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    if (build_options.rom_path.len == 0) {
        try out.print("trace: no ROM configured (set M2_ROM); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    if (build_options.mesen_path.len == 0) {
        try out.print("trace: no emulator configured (set MESEN); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }

    const rom = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        build_options.rom_path,
        gpa,
        .limited(rom_mod.expected_size * 4),
    );

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var first: ?usize = null;
    var count: usize = 24;
    var stretch: ?usize = null;
    var at: ?u32 = null;
    var span: usize = 96;
    if (args.next()) |a| {
        if (std.mem.eql(u8, a, "stretch")) {
            stretch = if (args.next()) |n| (std.fmt.parseInt(usize, n, 10) catch 0) else 0;
            if (args.next()) |b| first = std.fmt.parseInt(usize, b, 10) catch null;
        } else if (std.mem.eql(u8, a, "at")) {
            at = if (args.next()) |n| (std.fmt.parseInt(u32, n, 10) catch 0) else 0;
            if (args.next()) |b| span = @max(2, std.fmt.parseInt(usize, b, 10) catch span);
            // A third argument is where to print from, as everywhere else here;
            // with none, the window falls around the divergence.
            if (args.next()) |b| first = std.fmt.parseInt(usize, b, 10) catch null;
        } else {
            first = std.fmt.parseInt(usize, a, 10) catch null;
        }
    }
    if (args.next()) |a| count = @max(1, std.fmt.parseInt(usize, a, 10) catch 24);

    // Whichever pipeline is being traced, the cart on disk is the one that was
    // graded: the oracle writes it and this reads it back rather than rebuilding
    // one, because a trace of a different cart is a trace of a different
    // question.
    var rep: oracle.Report = undefined;
    var keys: []const oracle.Key = &.{};
    var cart_path: []const u8 = oracle.cart_name;
    var what: []const u8 = "the segment";
    var what_buf: [96]u8 = undefined;

    if (at) |origin| {
        // A cart anchored at an arbitrary movie frame. `stretch N` can only
        // reach the thirteen frames `anchorsFrom` picked, and the stretches
        // `duration.zig` measures are anchored somewhere else entirely -- the
        // latest frame before a room change, searched backwards. Those rows
        // print their anchor, so this takes one and traces it, and the two
        // compose: read the anchor out of `oracle -- durations`, hand it here.
        const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, tas.any_percent, gpa, .limited(4 << 20)) catch {
            try out.print("trace: no movie at {s}; run tools/get-tas.sh\n", .{tas.any_percent});
            try out.flush();
            std.process.exit(1);
        };
        const movie = try tas.parse(bytes);
        const anchors = [_]oracle.Anchor{.{ .origin = origin, .frames = span, .handover = origin }};
        const refs = try oracle.referencesFromMovie(gpa, rom, movie, &anchors);
        const mr = refs[0] orelse {
            try out.print("trace: no reference could be taken at frame {d}\n", .{origin});
            try out.flush();
            std.process.exit(1);
        };
        var set = try convert.run(gpa, rom);
        defer set.deinit();
        var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, oracle.out_dir, .{});
        defer dir.close(init.io);
        const cp = try std.fmt.allocPrint(gpa, oracle.out_dir ++ "/at{d:0>5}.sfc", .{origin});
        const lp = try std.fmt.allocPrint(gpa, oracle.out_dir ++ "/at{d:0>5}.lua", .{origin});
        // No emulator path: `gradeRef` builds and writes the cart either way,
        // and grading here would run Mesen2 twice for one trace.
        rep = try oracle.gradeRef(gpa, init.io, dir, rom, set, mr, "", cp, lp, .bucket, .world);
        keys = mr.take().keys;
        cart_path = cp;
        what = try std.fmt.bufPrint(
            &what_buf,
            "the any% run anchored on its frame {d}",
            .{origin},
        );
    } else if (stretch) |n| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, tas.any_percent, gpa, .limited(4 << 20)) catch {
            try out.print("trace: no movie at {s}; run tools/get-tas.sh\n", .{tas.any_percent});
            try out.flush();
            std.process.exit(1);
        };
        // No emulator: the sweep builds and writes every cart either way, and
        // grading here would run Mesen twice for one trace.
        const an = try oracle.gradeAnchored(
            gpa, init.io, rom, try tas.parse(bytes), "", oracle.anchor_min_frames, 9000, n, .bucket,
        );
        if (n >= an.stretches.len) {
            try out.print("trace: stretch {d} does not exist; there are {d}\n", .{ n, an.stretches.len });
            try out.flush();
            std.process.exit(1);
        }
        const st = an.stretches[n];
        rep = st.rep orelse {
            try out.print("trace: stretch {d} has no reference: {s}\n", .{ n, st.withheld().? });
            try out.flush();
            std.process.exit(1);
        };
        keys = st.keys;
        cart_path = st.cart_path;
        what = try std.fmt.bufPrint(
            &what_buf,
            "stretch {d} of the any% run, anchored on its frame {d}",
            .{ n, st.anchor.origin },
        );
    } else {
        // It chooses the start, takes the Game Boy reference and writes
        // `build-out/oracle.sfc`.
        rep = try oracle.grade(gpa, init.io, rom, "", 8, false, .bucket);
        keys = try oracle.segmentKeys(gpa);
    }
    // The save file is the channel and it is 32 KiB, so a stretch longer than
    // it fits is traced as far as it fits rather than refused. The segment has
    // never come near the cap; a movie stretch runs to thirteen hundred frames.
    const capped = keys.len > trace.maxFrames();
    if (capped) keys = keys[0..trace.maxFrames()];
    const ref = rep.settled.frames[0..keys.len];

    const cart = try std.Io.Dir.cwd().readFileAlloc(init.io, cart_path, gpa, .limited(8 << 20));

    try out.print("tracing {d} frames of {s} on {s}\n", .{ keys.len, what, cart_path });
    if (capped) try out.print("  (capped: the save-RAM channel holds {d} records)\n", .{trace.maxFrames()});
    try out.flush();

    var run = try trace.run(
        gpa,
        init.io,
        cart,
        keys,
        build_options.mesen_path,
        init.environ_map.get("HOME") orelse "",
    );
    defer run.deinit(gpa);

    // Where the two machines part company, found on this side out of the trace
    // rather than reported by the emulator: the same comparison the oracle
    // bakes into its script, over data that survived the run.
    const snes = try gpa.alloc(oracle.Frame, keys.len);
    for (0..keys.len) |f| {
        const s = run.at(f);
        snes[f] = .{
            .samus_x = s.get("samus_x"),
            .samus_y = s.get("samus_y"),
            .camera_x = s.get("cam_x"),
            .camera_y = s.get("cam_y"),
            .pose = @truncate(s.get("pose")),
            .facing = @truncate(s.get("facing")),
        };
    }
    const diverged = oracle.firstDivergence(ref, snes);

    // Which screen each machine is standing in. The comparison is only a
    // comparison if it is the same screen.
    try out.print(
        "place: game boy map {d} cell ${X:0>2}; cart map {d} cell ${X:0>2} (boot record asked for map {d} cell ${X:0>2})\n",
        .{
            rep.spawned.map_index,       rep.settled.cell(),
            run.at(0).get("map"),        run.at(0).get("cell"),
            rep.boot.map_index,          rep.boot.cell,
        },
    );

    if (diverged) |d| {
        try out.print("\nfirst divergence: {s} at frame {d}\n", .{
            switch (d.what) {
                .position => "Samus's position",
                .camera => "the camera",
                .pose => "the pose",
            },
            d.frame,
        });
    } else {
        try out.print("\nno divergence: every frame matched\n", .{});
    }

    // A window around the divergence unless one was asked for.
    // Clamped, because a capped run has fewer frames than the caller asked to
    // print from: `at 328 1400 1390` traces 774 records and then wants a window
    // starting past the end of them.
    const start = @min(first orelse blk: {
        const where = if (diverged) |d| d.frame else 0;
        break :blk where -| 4;
    }, keys.len -| 1);
    const end = @min(keys.len, start + count);

    try out.print("\n{s}\n", .{
        "  f  key         gb x,y     snes x,y   | pose gb/snes  facing  gb pad/ctr  held/pressed  prev x  probe x,y  blk sol hit  moveb  frame  water gb/snes  cam gb x,y   cam snes x,y  en st/spr/y/x n hurt",
    });
    // `Key` is a packed struct rather than an enum, so it has no `@tagName`.
    // This file still called one until 2026-09-01, which means `zig build
    // trace` had not compiled since `Key` changed shape -- nothing in `zig
    // build verify` builds this tool, so nothing said so.
    var keybuf: [oracle.mesen_keys_max]u8 = undefined;
    for (start..end) |f| {
        const s = run.at(f);
        const g = ref[f];
        const n = snes[f];
        const mark: u8 = if (g.samus_x != n.samus_x or g.samus_y != n.samus_y) '*' else ' ';
        try out.print(
            "{c}{d:>3}  {s:<11} {X:0>4},{X:0>4}  {X:0>4},{X:0>4}  |  ${X:0>2}/${X:0>2}   {d}/{d}    ${X:0>2}/${X:0>2}      ${X:0>4}/${X:0>4}   {X:0>4}   {X:0>3},{X:0>3}    ${X:0>2} ${X:0>2} {d}    {d}      {d}    ${X:0>2}/${X:0>2}       {X:0>4},{X:0>4}  {X:0>4},{X:0>4}\n",
            .{
                mark,                      f,
                oracle.keyName(keys[f], &keybuf), g.samus_x,
                g.samus_y,                 n.samus_x,
                n.samus_y,                 g.pose,
                n.pose,                    g.facing,
                n.facing,                  g.pad,
                g.counter,                 s.get("held"),
                s.get("pressed"),
                s.get("prev_x"),           s.get("tile_x"),
                s.get("tile_y"),           s.get("block"),
                s.get("solid"),            s.get("hit"),
                s.get("move_b"),           s.get("frame"),
                g.water,                   s.get("water"),
                g.camera_x,                g.camera_y,
                n.camera_x,                n.camera_y,
            },
        );
        // Its own `print` because the row above already carries Zig's ceiling
        // of thirty-two format arguments.
        try out.print("   en st ${X:0>2} spr ${X:0>2} at ${X:0>2},${X:0>2}\n", .{
            s.get("en_st"), s.get("en_spr"), s.get("en_y"), s.get("en_x"),
        });
    }

    // Which of the ROM's eight collision tables the reference is actually
    // holding at $DC00, named by comparing all eight against it. The threshold
    // beside it was compared from the first run of this file and the table was
    // not, which is the gap the segment's first divergence fell into: two
    // machines can agree about the tile ids, the picture and the threshold and
    // still disagree about whether a tile is water.
    {
        var gb_table: ?usize = null;
        for (tileset.tilesets, 0..) |ts, i| {
            const e = offsets.find(ts.collision) orelse continue;
            const bytes = rom[e.romOffset()..][0..tileset.collision_bytes];
            if (std.mem.eql(u8, bytes, &rep.settled.coltab)) gb_table = i;
        }
        var boot_table: ?usize = null;
        for (tileset.tilesets, 0..) |ts, i| {
            const e = offsets.find(ts.collision) orelse continue;
            const bytes = rom[e.romOffset()..][0..tileset.collision_bytes];
            if (std.mem.eql(u8, bytes, &rep.settled.coltab_before)) boot_table = i;
        }
        const stale = std.mem.eql(u8, &rep.settled.coltab, &rep.settled.coltab_before);
        if (gb_table) |i| {
            try out.print("\ncollision: the reference holds table {d} ({s})\n", .{ i, tileset.tilesets[i].collision });
        } else {
            try out.print("\ncollision: the reference holds a table that is none of the eight\n", .{});
        }
        try out.print("           before the spawn it held {?d}, and the spawn {s} it\n", .{
            boot_table, if (stale) "did not change" else "changed",
        });

        // And what the cart's own boot script selects, read off the same script
        // the engine replays.
        var decoded = try door.decodeRegion(gpa, door.region(rom).?);
        defer decoded.deinit(gpa);
        const ptrs = door.pointers(rom).?;
        if (screens.scriptOps(decoded, ptrs, rep.boot.door_index)) |ops| {
            var cart_col: ?u4 = null;
            for (ops) |op| switch (op) {
                .collision => |v| cart_col = v,
                else => {},
            };
            if (cart_col) |v| {
                // Resolved through the ROM's own pointer table rather than
                // read as an index, because that is what both machines do: the
                // Game Boy's `COLLISION` handler indexes `collision_pointers`
                // and `snes_convert` lays the cart's blobs out in the order
                // that produces. Printing `tilesets[operand]` here once made
                // the two machines look like they disagreed when they do not,
                // and that false reading reached the plan as a lead (fixed
                // 2026-09-01). The mapping happens to be the identity since the
                // naming defect of 2026-09-08 was fixed; going through
                // `collisionOrder` is what keeps this right if it stops being.
                const order = tileset.collisionOrder(rom) orelse return error.UnresolvedSource;
                const ts_index = order[v];
                try out.print("           the cart's boot script (door {d}) selects operand {d} -> table {d} ({s}){s}\n", .{
                    rep.boot.door_index, v, ts_index, tileset.tilesets[ts_index].collision,
                    if (gb_table != null and gb_table.? == ts_index) "" else "   <-- they disagree",
                });
            } else {
                try out.print("           the cart's boot script (door {d}) has no COLLISION op\n", .{rep.boot.door_index});
            }
        }
    }

    // The two worlds, side by side. Collision on the original is a lookup into
    // its own background tilemap, so a port that disagrees about the picture
    // disagrees about the floor -- and a position that matches over a world
    // that does not is a coincidence, not a pass.
    const gb_tiles = &rep.settled.tiles;
    // Only over the slots the reference's camera window puts inside the boot
    // cell: outside them the original's map is the screen next door, by design.
    // See `oracle.World`.
    const mask = oracle.windowMask(
        rep.settled.scx,
        rep.settled.scy,
        rep.settled.placement.worldX(),
        rep.settled.placement.worldY(),
        rep.boot.cell,
    );
    var rows_differ: usize = 0;
    for (0..32) |r| {
        for (0..32) |c| {
            const i = r * 32 + c;
            if (mask[i] and gb_tiles[i] != run.tilemap[i]) {
                rows_differ += 1;
                break;
            }
        }
    }
    var kept: usize = 0;
    for (0..1024) |i| kept += @intFromBool(gb_tiles[i] == rep.settled.tiles_before[i]);
    try out.print(
        "\ntilemap: {d} of 32 rows differ (the Game Boy was scrolled to {d},{d})\n",
        .{ rows_differ, rep.settled.scx, rep.settled.scy },
    );
    try out.print(
        "         the Game Boy's map kept {d} of 1024 tiles across the warp\n",
        .{kept},
    );
    // And the same question with the mask taken off. The window is the part
    // of the buffer the boot cell owns; the rest is the screen next door, and
    // a port that seeds one screen over the whole buffer disagrees there and
    // nowhere else. That is invisible to the masked count above, and it is
    // what she walks into the moment she leaves the boot cell.
    {
        var outside_differ: usize = 0;
        var outside: usize = 0;
        for (0..1024) |i| {
            if (mask[i]) continue;
            outside += 1;
            outside_differ += @intFromBool(gb_tiles[i] != run.tilemap[i]);
        }
        try out.print(
            "         outside the window, {d} of {d} slots differ -- those are the neighbours\n",
            .{ outside_differ, outside },
        );
    }
    if (rows_differ != 0) {
        try out.print("     game boy                          cart\n", .{});
        for (0..32) |r| {
            const g = gb_tiles[r * 32 ..][0..32];
            const n = run.tilemap[r * 32 ..][0..32];
            var same = true;
            for (0..32) |c| {
                if (mask[r * 32 + c] and g[c] != n[c]) same = false;
            }
            const mark: u8 = if (same) ' ' else '*';
            try out.print("{c}{d:>3} ", .{ mark, r });
            for (g) |t| try out.print("{X:0>2}", .{t});
            try out.print("  ", .{});
            for (n) |t| try out.print("{X:0>2}", .{t});
            try out.print("\n", .{});
        }
    }

    // Which metatile table reproduces the world each machine walked through.
    // `oracle.compareWorlds` is the same question the gate asks, asked here
    // over the tilemap the cart actually had rather than the one it should
    // have had -- so a disagreement between those two would show up as well.
    if (rows_differ != 0) {
        try out.print(
            "         the cart's world is cell ${X:0>2} through metatile table {d}; the Game Boy\n" ++
                "         agreed with it on {d} of the {d} tiles inside its window, and its own\n" ++
                "         best table is {d}, at {d}\n",
            .{
                rep.boot.cell,     rep.world.cart_table,
                rep.world.matched, rep.world.compared,
                rep.world.gb_best_table, rep.world.gb_best_matched,
            },
        );
    }

    // The other half of "is this tile solid". Two machines can hold the same
    // tile at the same slot and still disagree about walking through it, because
    // the id is only half the question: the door script also selects a threshold
    // and a block-type table, and until this ran neither had been compared.
    // `!Solid` against $D056, `!ColTab` against $DC00.
    {
        const f0 = run.at(0);
        const cart_solid: u8 = @truncate(f0.get("solid"));
        try out.print(
            "\nsolidity: threshold gb ${X:0>2}, cart ${X:0>2}{s}\n",
            .{
                rep.settled.solid, cart_solid,
                if (rep.settled.solid == cart_solid) "" else "   <-- they disagree",
            },
        );
        // Where the two thresholds part company over the ids this room actually
        // uses: a tile the reference walks through and the cart does not is the
        // whole of the defect, if there is one.
        var seen: [256]bool = @splat(false);
        for (0..1024) |i| if (mask[i]) {
            seen[gb_tiles[i]] = true;
            seen[run.tilemap[i]] = true;
        };
        var split: usize = 0;
        for (0..256) |id| {
            if (!seen[id]) continue;
            const gb_hit = id < rep.settled.solid;
            const cart_hit = id < cart_solid;
            if (gb_hit == cart_hit) continue;
            if (split == 0) try out.print("          tiles on screen the two disagree about:", .{});
            if (split < 16) try out.print(" ${X:0>2}", .{id});
            split += 1;
        }
        if (split != 0) try out.print("  ({d} in all)\n", .{split});
    }

    // Where the cart's own world put her feet, asked of the cart's own tilemap
    // and its own solidity threshold.
    {
        const f0 = run.at(0);
        const foot = try trace.footing(
            run.tilemap,
            @truncate(f0.get("solid")),
            @truncate(f0.get("samus_x")),
            @truncate(f0.get("samus_y")),
        );
        if (foot.surface_row) |sr| {
            if (foot.standing()) {
                try out.print("\nfooting: she starts on the floor, tile row {d} of column {d}\n", .{ sr, foot.col });
            } else {
                try out.print(
                    "\nfooting: she starts {d} pixels INSIDE the floor -- her feet probe row {d} of\n" ++
                        "         column {d} and the first solid row there is {d}. Standing on it would\n" ++
                        "         need her pixel row to be ${X:0>2}, not ${X:0>2}.\n",
                    .{
                        foot.embedded,   foot.feet_row,
                        foot.col,        sr,
                        foot.wants_pixel_y orelse 0,
                        @as(u8, @truncate(f0.get("samus_y"))),
                    },
                );
            }
        } else {
            try out.print("\nfooting: nothing solid under her column at all\n", .{});
        }
    }

    if (run.at(0).get("unhandled") != 0 or run.at(keys.len - 1).get("unhandled") != 0) {
        try out.print("\nthe engine was handed a pose it does not implement: ${X:0>2}\n", .{
            run.at(keys.len - 1).get("unhandled"),
        });
    }
    try out.print("\nwrote {s} and {s}; the records are in the emulator's save file\n", .{
        trace.cart_name, trace.lua_name,
    });
    try out.flush();
}
