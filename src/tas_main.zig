//! `zig build tas` — replay a published tool-assisted run and write the trace.
//!
//! Arguments, all optional and positional:
//!
//!     zig build tas -- [any|100|rec] [frames] [stride] [offset]
//!                       [vblank|lcd|cycles] [boot|noboot] [scan] [pad] [sram]
//!                       [anchors]
//!
//! The three numbers are positional; everything else is a keyword in any order.
//! `scan` measures where the movie's frame zero lands instead of replaying.
//! `pad` replays and reports what the *game* received each frame, against what
//! the movie held -- which is how the frame boundary was chosen.
//! `anchors` prints the refusal census the re-anchored comparison is built on:
//! how many handovers of control the run has inside its horizon, at each
//! candidate stillness threshold. `oracle.anchor_min_frames` is chosen off this
//! table, so moving it is a measurement rather than an argument.
//!
//! `frames` of 0 means the whole movie, which is 45 minutes of game and a few
//! minutes of wall clock. A short prefix is what to reach for while iterating;
//! the full run is what the loadout and the coverage figures come from.
//!
//! `rec` is James's own recording, converted to a VBM. **It is a probe and not
//! a grading path**: replaying it here loses the run at 28 796 of 76 950
//! frames, which is the measurement that put Phase 0b's reference on
//! `zig build gbtrace` instead. See `tas.recorded`. Nothing in `zig build
//! verify` reads it; it is kept so the bound stays reproducible and nobody
//! spends a turn rediscovering it.
//!
//! The movies are fetched by `tools/get-tas.sh` into `vendor/tas/`, untracked.

const std = @import("std");
const rom_mod = @import("rom.zig");
const extract = @import("extract.zig");
const tas = @import("tas.zig");
const png = @import("png");
const room = @import("room.zig");
const save = @import("save.zig");

const build_options = @import("build_options");

const out_subdir = "tas";

/// SameBoy's DMG boot ROM, built from source by `tools/sameboy-frames.sh` and
/// already used by the frame comparison in `src/gb/sameboy.zig`.
const boot_rom_path = "vendor/sameboy/build/bin/tester/dmg_boot.bin";

fn parseNum(s: []const u8) ?usize {
    return std.fmt.parseInt(usize, s, 10) catch null;
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    if (build_options.rom_path.len == 0) {
        try out.print("tas: no ROM configured (set M2_ROM); see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }

    var path: []const u8 = tas.hundred_percent;
    var name: []const u8 = "100";
    var scan = false;
    var pads = false;
    var sram = false;
    var anchors = false;
    var poke: ?struct { addr: u16, value: u8 } = null;
    var opts: tas.Options = .{};
    var watch: std.ArrayList(u16) = .empty;
    // Off by default, because that is what the origin measurement says VBA
    // did; `boot` as the fifth argument turns it back on, which is how the
    // measurement gets repeated.
    var use_boot_rom = false;
    opts.screenshot = true;

    // Keywords in any order, then numbers positionally: frames, stride,
    // offset. A replay has six independent knobs and remembering their order
    // was worse than parsing them.
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var n: usize = 0;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "scan")) {
            scan = true;
        } else if (std.mem.eql(u8, a, "pad")) {
            pads = true;
        } else if (std.mem.eql(u8, a, "anchors")) {
            anchors = true;
        } else if (std.mem.eql(u8, a, "sram")) {
            sram = true;
        } else if (std.mem.startsWith(u8, a, "poke:")) {
            // poke:D081=30 -- both hex, no dollar signs.
            const eq = std.mem.indexOfScalar(u8, a, '=') orelse continue;
            poke = .{
                .addr = std.fmt.parseInt(u16, a[5..eq], 16) catch continue,
                .value = std.fmt.parseInt(u8, a[eq + 1 ..], 16) catch continue,
            };
        } else if (std.mem.eql(u8, a, "any")) {
            path = tas.any_percent;
            name = "any";
        } else if (std.mem.eql(u8, a, "100")) {
            path = tas.hundred_percent;
            name = "100";
        } else if (std.mem.eql(u8, a, "rec")) {
            path = tas.recorded;
            name = "rec";
        } else if (std.mem.startsWith(u8, a, "watch:")) {
            // `watch:D03B,D03C` -- hex, comma separated. Sampled on every
            // sampled frame into `any-*-watch.tsv`, beside the trace and never
            // inside it; see `tas.Options.watch`.
            var it = std.mem.splitScalar(u8, a["watch:".len..], ',');
            while (it.next()) |tok| {
                if (tok.len == 0) continue;
                const v = std.fmt.parseInt(u16, tok, 16) catch {
                    try out.print("tas: watch: `{s}` is not a hex address\n", .{tok});
                    try out.flush();
                    return;
                };
                try watch.append(arena, v);
            }
        } else if (std.mem.eql(u8, a, "lcd")) {
            opts.frame_source = .lcd;
        } else if (std.mem.eql(u8, a, "cycles")) {
            opts.frame_source = .cycles;
        } else if (std.mem.eql(u8, a, "vblank")) {
            opts.frame_source = .vblank;
        } else if (std.mem.eql(u8, a, "boot")) {
            use_boot_rom = true;
        } else if (std.mem.eql(u8, a, "noboot")) {
            use_boot_rom = false;
        } else if (parseNum(a)) |v| {
            switch (n) {
                0 => opts.max_frames = v,
                1 => opts.stride = @max(1, v),
                2 => opts.input_offset = v,
                else => {},
            }
            n += 1;
        }
    }

    const rom = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        build_options.rom_path,
        arena,
        .limited(rom_mod.expected_size * 4),
    );

    if (poke) |pk| {
        try out.print("booting, spawning, writing ${X:0>2} to ${X:0>4}...\n", .{ pk.value, pk.addr });
        try out.flush();
        const where: room.Spawn = .{
            .map_bank = 0x9,
            .screen_row = 7,
            .screen_col = 6,
            .pixel_y = 0x40,
            .pixel_x = 0x80,
        };
        // The same spawn twice, once untouched. Everything that differs
        // between the two tilemaps is something this byte drives, which is a
        // mechanical answer where reading digits off a 160x144 picture is not.
        const poke_frames: u64 = 240;
        const base = try tas.pokeAndDraw(arena, rom, where, null, 0, poke_frames);
        const shot_poke = try tas.pokeAndDraw(arena, rom, where, pk.addr, pk.value, poke_frames);
        const shades = shot_poke.frame;
        var diffs: usize = 0;
        for (base.maps, shot_poke.maps, 0..) |a, b, i| {
            if (a == b) continue;
            diffs += 1;
            const map: u16 = if (i < 0x400) 0x9800 else 0x9C00;
            const cell = i % 0x400;
            try out.print("  ${X:0>4} (row {d: >2} col {d: >2})  ${X:0>2} -> ${X:0>2}\n", .{
                map + @as(u16, @intCast(cell)), cell / 32, cell % 32, a, b,
            });
        }
        try out.print("  {d} tilemap cells changed\n", .{diffs});
        try out.print("  after {d} frames: bank ${X:0>2} at {X:0>4},{X:0>4}   (untouched: bank ${X:0>2} at {X:0>4},{X:0>4})\n", .{
            poke_frames,
            shot_poke.after.map_bank, shot_poke.after.worldY(), shot_poke.after.worldX(),
            base.after.map_bank,      base.after.worldY(),      base.after.worldX(),
        });
        var d = try std.Io.Dir.cwd().createDirPathOpen(init.io, extract.out_dir ++ "/" ++ out_subdir, .{});
        defer d.close(init.io);
        const shot = try std.fmt.allocPrint(arena, "poke-{X:0>4}-{X:0>2}.png", .{ pk.addr, pk.value });
        try d.writeFile(init.io, .{
            .sub_path = shot,
            .data = try png.encodeIndexed(arena, &shades, 160, 144, &png.dmg_palette),
        });
        try out.print("{s}/{s}/{s}\n", .{ extract.out_dir, out_subdir, shot });
        try out.flush();
        return;
    }

    // The load side of the save record, which needs no movie at all: boot the
    // game the way the harness always has and watch it read a record in.
    if (sram) {
        try out.print("booting and watching every cartridge-RAM read...\n", .{});
        try out.flush();
        var rep = try room.watchLoad(arena, rom, 40, 8192);
        defer rep.deinit(arena);
        try out.print("{d} reads, {d} distinct addresses ${X:0>4}-${X:0>4}, {d} sites\n\n", .{
            rep.reads.len, rep.distinct, rep.low, rep.high, rep.sites,
        });
        for (rep.reads) |r| {
            try out.print("  {X:0>2}:${X:0>4}  reads ${X:0>4} = ${X:0>2}\n", .{ r.bank, r.pc, r.addr, r.value });
        }
        if (rep.incomplete) {
            try out.print("\nFAIL the reads above are incomplete: allocation failed while recording them\n", .{});
            try out.flush();
            std.process.exit(1);
        }
        try out.flush();
        return;
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(4 << 20)) catch {
        try out.print(
            "tas: {s} is missing. Fetch the published runs first:\n\n    ./tools/get-tas.sh\n",
            .{path},
        );
        try out.flush();
        std.process.exit(1);
    };

    // The boot ROM, when it is there. See `tas.Options.boot_rom`: whether the
    // recording emulator ran one decides where the movie's frame zero is, and
    // getting it wrong loses the title screen's Start press.
    // A boot ROM shifts the origin by the length of the logo, so asking for one
    // and leaving the measured offset in place would lose the Start press
    // again. The scan is the way to find the offset for a different framing.
    if (use_boot_rom) {
        opts.input_offset = 0;
        opts.boot_rom = std.Io.Dir.cwd().readFileAlloc(init.io, boot_rom_path, arena, .limited(4096)) catch blk: {
            try out.print(
                "tas: no {s}; replaying post-boot from $0100 instead (run tools/sameboy-frames.sh)\n",
                .{boot_rom_path},
            );
            break :blk null;
        };
    }

    const movie = try tas.parse(bytes);
    try tas.checkAgainstRom(movie, rom);

    try out.print(
        "{s}: {d} frames ({d:.1} min) by {s}, {d} rerecords\n",
        .{ path, movie.frames, movie.seconds() / 60.0, movie.author, movie.rerecords },
    );
    if (scan) {
        try out.print("looking for the movie's frame origin, 900 frames per candidate...\n", .{});
        try out.flush();
        const found = try tas.findInputOrigin(arena, rom, movie, opts, 600, 900);
        if (found) |o| {
            try out.print("input origin: machine frame {d}\n", .{o});
        } else {
            try out.print("input origin: NOT FOUND in 0..600\n", .{});
        }
        try out.flush();
        return;
    }

    // What the game received, against what the movie held. A replay that
    // leaves the published route either computed the wrong thing from the
    // right input or was handed the wrong input, and this says which.
    if (pads) {
        try out.print("replaying {d} frames and reading the game's own pad byte...\n", .{opts.max_frames});
        try out.flush();
        const ds = try tas.delivery(arena, rom, movie, opts);
        const shape = try tas.pollShape(arena, ds);
        try out.print(
            "{d} reads of $FF00 per poll; {d} frames polled, {d} not asking\n",
            .{ shape.per_poll, shape.polled, shape.idle },
        );
        try out.print(
            "{d} of {d} frames misdelivered: {d} polls the boundary cut in half, {d} polls that read the wrong byte\n",
            .{ shape.bad(), ds.len, shape.drifted, shape.wrong },
        );
        if (ds.len > 1) {
            const span = ds[ds.len - 1].cycle - ds[0].cycle;
            const want = @as(u64, ds.len - 1) * 70224;
            try out.print(
                "{d} cycles over {d} frames, against {d} the movie allows: {d} frames' worth of machine time unaccounted for\n",
                .{ span, ds.len - 1, want, (span -| want) / 70224 },
            );
        }
        if (shape.first_bad) |d| {
            try out.print("first at frame {d}: held ${X:0>2}, acted on ${X:0>2}, {d} polls\n", .{ d.frame, d.held, d.acted, d.polls });
        }
        try out.print("\nframe\theld\tacted\tpressed\tpolls\tly\n", .{});
        for (ds) |d| {
            if (d.frame % opts.stride != 0 and d.agrees()) continue;
            try out.print("{d}\t{X:0>2}\t{X:0>2}\t{X:0>2}\t{d}\t{d}{s}\n", .{
                d.frame, d.held, d.acted, d.pressed, d.polls, d.poll_ly,
                if (d.agrees()) "" else "\tMISDELIVERED",
            });
        }
        try out.flush();
        return;
    }

    try out.print(
        "replaying {d} frames from machine frame {d}, sampling every {d}, frame boundary = {s}...\n",
        .{
            if (opts.max_frames == 0) movie.frames else opts.max_frames,
            opts.input_offset,
            opts.stride,
            @tagName(opts.frame_source),
        },
    );
    try out.flush();

    opts.watch = watch.items;
    var r = try tas.run(arena, rom, movie, opts);
    defer r.deinit(arena);

    try out.print("\n", .{});
    try out.print("frames replayed   {d} of {d}{s}\n", .{
        r.frames_run,
        movie.frames,
        if (r.stalled) "  (STALLED: no frame boundary arrived)" else "",
    });
    try out.print("instructions      {d}\n", .{r.instructions});
    if (r.entered_frame) |f| {
        try out.print("entered a room at frame {d}\n", .{f});
    } else {
        try out.print("entered a room    NEVER -- the replay never left the title\n", .{});
    }
    try out.print("ended at          ${X:0>4} bank ${X:0>2}, LCD {s}, {s}\n", .{
        r.final_pc,
        r.final_bank,
        if (r.lcd_on) "on" else "off",
        if (r.alive) "alive" else "not alive",
    });
    try out.print("samples           {d}\n", .{r.samples.len});
    try out.print("metroid count     {d} -> {d}\n", .{ r.metroid_first, r.metroid_min });
    try out.print("map banks visited {d} of 7\n", .{r.bankCount()});
    try out.print("distinct poses    {d}\n", .{r.poses_seen});

    // How far the replay stayed on the route the published run was recorded on.
    // Printed beside the progress markers because it is the number that says
    // what those markers are worth: a run that stops being the published run at
    // frame 546 has not visited one map bank, it has failed to visit six.
    if (opts.stride == 1) {
        if (tas.findOpening(r.track())) |op| {
            try out.print(
                "opening           Start at {d}, room at {d}, placed at {d} in pose ${X:0>2}, control at {d}, first move at {d}\n",
                .{ op.start_pressed, op.room_loaded, op.placed, op.placed_pose, op.control, op.first_move },
            );
        } else |_| {}
        const fs = try tas.faithfulness(arena, r.track(), tas.stuck_min_frames);
        if (fs.first_stuck) |stuck| {
            try out.print(
                "faithful until    frame {d}: held ${X:0>2} into a refusal of {d} frames at {X:0>4},{X:0>4}, and did not move for {?d} more\n",
                .{ stuck.start, stuck.offered, stuck.frames, stuck.samus_x, stuck.samus_y, stuck.moved_after },
            );
        } else {
            try out.print("faithful until    no stuck refusal in {d} frames\n", .{r.samples.len});
        }
        if (fs.left_play) |f| try out.print("left play at      frame {d}\n", .{f});

        if (anchors) {
            const horizon = fs.horizon() orelse @as(u32, @intCast(r.samples.len));
            try out.print("\nanchor census, to the horizon at frame {d}\n", .{horizon});
            for ([_]u32{ 4, 8, 12, 24, 60 }) |min| {
                const rs = try tas.findRefusals(arena, r.track(), min);
                var total: usize = 0;
                var released: usize = 0;
                for (rs) |ref| {
                    if (ref.start >= horizon) continue;
                    total += 1;
                    if (!ref.released(tas.release_window)) continue;
                    released += 1;
                }
                try out.print(
                    "  min {d:>3}: {d:>4} refusals, {d:>4} released (re-anchorable)\n",
                    .{ min, total, released },
                );
            }
            const rs = try tas.findRefusals(arena, r.track(), 8);
            try out.print("\n  first 40 released refusals at min 8:\n", .{});
            var shown: usize = 0;
            for (rs) |ref| {
                if (ref.start >= horizon) continue;
                if (!ref.released(tas.release_window)) continue;
                if (shown >= 40) break;
                shown += 1;
                try out.print(
                    "    handover {d:>6}  still {d:>4}f at {X:0>4},{X:0>4} pose ${X:0>2} offered ${X:0>2} moved_after {?d}\n",
                    .{ ref.handover(), ref.frames, ref.samus_x, ref.samus_y, ref.pose, ref.offered, ref.moved_after },
                );
            }
        }
    }
    try out.print("cartridge RAM     {d} bytes written by {d} sites", .{ r.save.distinct, r.save.sites });
    if (r.save.distinct != 0) {
        try out.print(", ${X:0>4}-${X:0>4}", .{ r.save.low, r.save.high });
    }
    try out.print("\n", .{});

    if (r.profile.len != 0) {
        try out.print("\nsave record, {d} fields, as they behaved over the run:\n", .{r.profile.len});
        try out.print("  off  src    start  last   min    max  changes  set  cleared  name\n", .{});
        for (r.profile) |st| {
            try out.print(
                "  {d: >3}  ${X:0>4}  ${X:0>2}    ${X:0>2}    ${X:0>2}    ${X:0>2}  {d: >7}  ${X:0>2}  ${X:0>2}       {s}\n",
                .{ st.field.offset, st.field.src, st.at_start, st.last, st.min, st.max, st.changes, st.bits_set, st.bits_cleared, st.field.name },
            );
        }
        try out.flush();
    }

    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, extract.out_dir ++ "/" ++ out_subdir, .{});
    defer dir.close(init.io);

    // Named by the framing, so two replays of the same movie under different
    // frame sources can sit side by side and be compared.
    const tag = try std.fmt.allocPrint(arena, "{s}-{s}{d}", .{ name, @tagName(opts.frame_source), opts.input_offset });
    const trace_name = try std.fmt.allocPrint(arena, "{s}-trace.tsv", .{tag});
    try dir.writeFile(init.io, .{ .sub_path = trace_name, .data = try tas.tsv(arena, r.samples) });

    if (r.screen) |shades| {
        const shot = try std.fmt.allocPrint(arena, "{s}-frame{d}.png", .{ tag, r.frames_run });
        try dir.writeFile(init.io, .{
            .sub_path = shot,
            .data = try png.encodeIndexed(arena, &shades, 160, 144, &png.dmg_palette),
        });
        try out.print("last frame        {s}/{s}/{s}\n", .{ extract.out_dir, out_subdir, shot });
    }

    if (watch.items.len != 0) {
        const watch_name = try std.fmt.allocPrint(arena, "{s}-watch.tsv", .{tag});
        var w: std.ArrayList(u8) = .empty;
        try w.appendSlice(arena, "frame");
        for (watch.items) |addr| try w.print(arena, "\t${X:0>4}", .{addr});
        try w.append(arena, '\n');
        for (r.samples, 0..) |smp, i| {
            try w.print(arena, "{d}", .{smp.frame});
            const row = r.watched[i * watch.items.len ..][0..watch.items.len];
            for (row) |b| try w.print(arena, "\t{X:0>2}", .{b});
            try w.append(arena, '\n');
        }
        try dir.writeFile(init.io, .{ .sub_path = watch_name, .data = w.items });
        try out.print("watched           {d} address(es) -> {s}/{s}/{s}\n", .{
            watch.items.len, extract.out_dir, out_subdir, watch_name,
        });
    }

    const save_name = try std.fmt.allocPrint(arena, "{s}-sram.tsv", .{tag});
    try dir.writeFile(init.io, .{ .sub_path = save_name, .data = try saveTsv(arena, r.save) });

    try out.print("\nwritten to {s}/{s}/{s} and {s}\n", .{
        extract.out_dir, out_subdir, trace_name, save_name,
    });
    if (r.save.incomplete) {
        try out.print("\nFAIL {s} is incomplete: allocation failed while recording cartridge-RAM writes\n", .{save_name});
        try out.flush();
        std.process.exit(1);
    }
    try out.flush();
}

/// Every cartridge-RAM write, in the order it happened, with the instruction
/// that made it. This is the raw material for naming the save record's fields:
/// one routine writes the whole record, so its writes arrive as a contiguous
/// run of ascending addresses from a small cluster of program counters.
fn saveTsv(allocator: std.mem.Allocator, s: room.SaveReport) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "bank\tpc\taddr\tvalue\n", .{});
    for (s.writes) |w| {
        try out.print(allocator, "{X:0>2}\t{X:0>4}\t{X:0>4}\t{X:0>2}\n", .{ w.bank, w.pc, w.addr, w.value });
    }
    return out.toOwnedSlice(allocator);
}
