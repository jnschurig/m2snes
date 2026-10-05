//! `zig build verify` — the gate.
//!
//! Phase 0a has no CI (see `02-plan.md`, "Standing decisions"): every
//! interesting check needs the user's retail ROM, which a public runner cannot
//! hold. So this is the local command that stands in for one, and every later
//! step hangs its gate here.
//!
//! It splits into ROM-free checks, which always run, and ROM-dependent checks,
//! which are *skipped with a notice* rather than silently passing when the ROM
//! is absent. The notice matters: a gate that quietly does nothing is worse
//! than no gate, because it reports green.

const std = @import("std");
const rom_mod = @import("rom.zig");
const policy = @import("policy.zig");
const pin = @import("pin.zig");
const offsets = @import("offsets.zig");
const extract = @import("extract.zig");
const roundtrip = @import("roundtrip.zig");
const coverage = @import("coverage.zig");
const trace = @import("gb/trace.zig");
const sameboy = @import("gb/sameboy.zig");
const ledger_mod = @import("ledger.zig");
const screens_mod = @import("screens.zig");
const snes_convert = @import("snes_convert.zig");
const snes_layout = @import("snes_layout.zig");
const snes_render = @import("snes_render.zig");
const snes_inject = @import("snes_inject.zig");
const snes_screen = @import("snes_screen.zig");
const snes_target = @import("snes_target.zig");
const snes_romtest = @import("snes_romtest.zig");
const oracle = @import("oracle.zig");
const tas = @import("tas.zig");
const duration = @import("duration.zig");
const dispatch = @import("dispatch.zig");
const death = @import("death.zig");
const title_oracle = @import("title_oracle.zig");
const pause_oracle = @import("pause_oracle.zig");
const queen_oracle = @import("queen_oracle.zig");
const scenario = @import("scenario.zig");
const warp = @import("warp.zig");
const warp_grade = @import("warp_grade.zig");
const save_grade = @import("save_grade.zig");
const gfx_grade = @import("gfx_grade.zig");
const debug_tables = @import("debug_tables.zig");
const audio_shim = @import("audio_shim.zig");
const aram_layout = @import("aram_layout.zig");
const audio_level = @import("audio_level.zig");
// Only a gate built with `vendor/sameboy` present links the renderer; without
// it the rung says it did not run, and nothing here refers to the import.
const audio_level_run = if (build_options.have_sameboy) @import("audio_level_run.zig") else struct {};


const build_options = @import("build_options");

/// How many rungs the roster in `docs/conformance.md` accounts for. Hand-kept
/// rather than counted: the gate prints a rung per mechanism and some print two
/// lines, so a count taken from the output would drift against the document
/// this number exists to send the reader to.
const rung_count: usize = 49;

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;

    var failures: usize = 0;

    // The harness names itself. Not decoration: the gate is the only thing in
    // this repository allowed to say the port is correct, and a reader who
    // arrives at a wall of `ok` lines needs one line telling them what the
    // roster is and where the rung-by-rung account lives. See B10.
    try out.print("the gate          {d} rungs; every rung's reference and fault check: docs/conformance.md\n", .{rung_count});
    try out.print("      absent            a rung whose emulator or recording is missing prints `not run:` and stays green\n", .{});

    // ---- ROM-dependent: is the configured ROM the revision we expect? ------
    const rom_path = build_options.rom_path;
    var rom_bytes: ?[]const u8 = null;

    if (rom_path.len == 0) {
        try out.print("FAIL  ROM revision      no ROM configured (set M2_ROM; see docs/setup.md)\n", .{});
        failures += 1;
    } else {
        // Read first, validate second. The bytes feed the n-gram scan whether or
        // not they are the revision we want: a wrong ROM in the tree is still a
        // ROM, and the hygiene check should be looking for it.
        if (std.Io.Dir.cwd().readFileAlloc(init.io, rom_path, arena, .limited(rom_mod.expected_size * 4))) |bytes| {
            rom_bytes = bytes;
            var diag: rom_mod.Diagnosis = undefined;
            if (rom_mod.ingest(arena, bytes, &diag)) |_| {
                try out.print("ok    ROM revision      {s}\n", .{rom_mod.expected_revision});
            } else |_| {
                try out.print("FAIL  ROM revision      {s}\n", .{diag.message});
                failures += 1;
            }
        } else |err| {
            try out.print("FAIL  ROM revision      cannot read {s}: {s}\n", .{ rom_path, @errorName(err) });
            failures += 1;
        }
    }

    // ---- ROM-dependent: do the offsets point at the shapes they claim? ----
    if (rom_bytes) |bytes| {
        if (bytes.len == rom_mod.expected_size) {
            var v = try offsets.verifyAgainstRom(arena, bytes);
            defer v.deinit(arena);
            if (v.ok()) {
                try out.print("ok    offset shapes     {d} checks over {d} entries ({d} still unpinned)\n", .{
                    v.checked, offsets.entries.len, offsets.pending.len,
                });
            } else {
                failures += 1;
                try out.print("FAIL  offset shapes     {d} of {d} checks failed\n", .{ v.failures.items.len, v.checked });
                for (v.failures.items) |f| {
                    try out.print("        {s}: {s}\n", .{ f.entry, f.detail });
                }
            }
        }
    } else {
        try out.print("skip  offset shapes     needs the ROM ({d} entries, {d} unpinned)\n", .{
            offsets.entries.len, offsets.pending.len,
        });
    }

    // ---- ROM-dependent: does extraction reproduce, byte for byte? ---------
    //
    // Run twice and compare the manifests, which carry a SHA-256 per output
    // file. Comparing manifests rather than re-hashing the tree is deliberate:
    // it also catches a record set that changed order or lost an entry, which
    // identical file hashes would not.
    if (rom_bytes) |bytes| blk: {
        if (bytes.len != rom_mod.expected_size) break :blk;

        var root_w = try std.Io.Dir.cwd().openDir(init.io, ".", .{ .iterate = true });
        defer root_w.close(init.io);

        var first = try extract.run(arena, init.io, root_w, bytes);
        defer first.deinit(arena);
        const manifest_a = try extract.manifestJson(arena, first);

        var second = try extract.run(arena, init.io, root_w, bytes);
        defer second.deinit(arena);
        const manifest_b = try extract.manifestJson(arena, second);

        // Sizes are declared in offsets.zig and re-read from the ROM here; the
        // raw file must be exactly the declared length, per entry.
        var size_mismatches: usize = 0;
        for (second.records.items) |r| {
            if (r.files.len == 0 or r.files[0].bytes != r.size) size_mismatches += 1;
        }

        // Step 4's gate: every in-use screen resolves, the door stream
        // round-trips, and every pointer in both tables is accounted for -
        // either it lands on a record, or it is one of the known dead slots.
        const g = second.regions;
        var region_problems: usize = 0;
        if (g.in_use_screens != 905) region_problems += 1;
        if (g.screens_reached + g.screens_unresolved != g.in_use_screens) region_problems += 1;
        if (g.screens_unresolved != 1) region_problems += 1; // the bank $A null
        if (g.distinct_screens != 7 * 59) region_problems += 1;
        if (!g.doors_round_trip) region_problems += 1;
        if (g.door_pointers_aligned + g.door_pointers_empty + g.door_pointers_external != 512) region_problems += 1;
        if (g.if_met_less_ops != 171 or g.if_met_less_thresholds != 13) region_problems += 1;
        if (g.door_sources_unresolved != 0) region_problems += 1;
        if (g.metasprite_pointers_matched + g.metasprite_pointers_out_of_window != g.metasprite_pointers_total) region_problems += 1;

        if (region_problems != 0) {
            failures += 1;
            try out.print("FAIL  map/door/sprite   {d} region invariant(s) broken\n", .{region_problems});
            try out.print("        screens {d} in use, {d} reached, {d} unresolved, {d} distinct\n", .{
                g.in_use_screens, g.screens_reached, g.screens_unresolved, g.distinct_screens,
            });
            try out.print("        doors {d} ops, round-trip {}, pointers {d}+{d}+{d}\n", .{
                g.door_ops, g.doors_round_trip, g.door_pointers_aligned, g.door_pointers_empty, g.door_pointers_external,
            });
        } else {
            try out.print("ok    map/door/sprite   {d}/905 screens reached (1 null), {d} door ops round-trip, {d} metasprites\n", .{
                g.screens_reached, g.door_ops, g.metasprites,
            });
        }

        if (!std.mem.eql(u8, manifest_a, manifest_b)) {
            failures += 1;
            try out.print("FAIL  extraction        not reproducible: two runs disagree\n", .{});
        } else if (size_mismatches != 0) {
            failures += 1;
            try out.print("FAIL  extraction        {d} entries whose output size differs from offsets.zig\n", .{size_mismatches});
        } else {
            try out.print("ok    extraction        {d} entries reproduce byte-for-byte ({d} deferred to Step 4)\n", .{
                second.records.items.len, second.skipped,
            });
        }
    } else {
        try out.print("skip  extraction        needs the ROM\n", .{});
        try out.print("skip  map/door/sprite   needs the ROM\n", .{});
    }

    // ---- ROM-dependent: does every class encode back to the ROM? ---------
    //
    // Extraction reproducing itself only proves determinism. This proves the
    // readings are complete: each class is decoded into its typed form and
    // re-serialised from that form alone, and must equal the bytes it came
    // from. The coverage report beside it names what has no reader at all,
    // because an unread class produces no failing test - it produces silence.
    if (rom_bytes) |bytes| blk: {
        if (bytes.len != rom_mod.expected_size) break :blk;

        var rt = try roundtrip.run(arena, bytes);
        defer rt.deinit(arena);

        if (rt.ok()) {
            try out.print("ok    round-trip        {d}/{d} entries re-encode byte-for-byte ({d} KiB, {d} raw)\n", .{
                rt.checked, offsets.entries.len, rt.bytes_round_tripped / 1024, rt.undecoded,
            });
        } else {
            failures += 1;
            try out.print("FAIL  round-trip        {d} of {d} entries do not re-encode to their source bytes\n", .{
                rt.failed, rt.checked,
            });
            // One broken encoder fails every entry of its class, so cap the
            // list: 40 identical lines bury the one detail that identifies
            // which class went wrong.
            const max_listed = 10;
            var listed: usize = 0;
            for (rt.results.items) |r| {
                if (r.ok) continue;
                if (listed == max_listed) {
                    try out.print("        ... and {d} more (full list in {s}/{s})\n", .{
                        rt.failed - listed, extract.out_dir, coverage.file_name,
                    });
                    break;
                }
                listed += 1;
                if (r.err) |e| {
                    try out.print("        {s}: decoder refused the bytes ({s})\n", .{ r.name, e });
                } else {
                    try out.print("        {s}: first difference at +${x}, {d} bytes in vs {d} out\n", .{
                        r.name, r.first_diff orelse 0, r.bytes, r.encoded_len,
                    });
                }
            }
        }

        var cov = try coverage.summarize(arena, rt);
        defer cov.deinit(arena);

        const text = try coverage.render(arena, rt, cov);
        var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, extract.out_dir, .{});
        defer dir.close(init.io);
        try dir.writeFile(init.io, .{ .sub_path = coverage.file_name, .data = text });

        // The one coverage number that is a gate rather than a report: banks
        // $9-$F are pure map data, so an unclaimed byte there is a table we
        // failed to catalogue, not code we were never going to reach.
        if (cov.unclaimed_in_full_banks != 0) {
            failures += 1;
            try out.print("FAIL  coverage          {d} unclaimed bytes in banks $9-$F, which should be fully mapped\n", .{
                cov.unclaimed_in_full_banks,
            });
        } else {
            try out.print("ok    coverage          {d}/{d} KiB claimed, {d} items, {d} classes unread -> {s}/{s}\n", .{
                cov.claimed_total / 1024, coverage.rom_bytes / 1024, cov.items,
                coverage.not_yet_decoded.len, extract.out_dir, coverage.file_name,
            });
        }
        // ---- Step 7: the reference frames ------------------------------
        //
        // Step 9 diffs the SNES conversion against these, so the property that
        // matters here is that they are a function of the ROM and nothing else.
        // Every screen is rendered twice from the same inputs and the two
        // compared, and a digest over all of them in cell order is printed so
        // two runs of the gate can be compared by eye.
        //
        // `zig build frames` writes the images; this renders them and throws
        // them away, because the claim under test is reproducibility, not
        // PNG encoding.
        const frames = try screens_mod.renderAll(arena, bytes, screens_mod.live_bgp, null);
        var frame_problems: usize = 0;
        if (frames.unstable != 0) frame_problems += 1;
        if (frames.out_of_range != 0) frame_problems += 1;
        // 905 in use, less the one null pointer in bank $A.
        if (frames.rendered != 904) frame_problems += 1;
        if (frame_problems != 0) {
            failures += 1;
            try out.print("FAIL  frames            {d} rendered, {d} differed on a second render, {d} metatile indexes out of range\n", .{
                frames.rendered, frames.unstable, frames.out_of_range,
            });
        } else {
            try out.print("ok    frames            {d} screens render reproducibly, {x}\n", .{
                frames.rendered, frames.digest[0..8],
            });
            try out.print("      provenance        {d} stated by a door, {d} carried through a table-less door, {d} scrolled,\n" ++
                "                        {d} bank default; {d} frames touch VRAM no door wrote\n", .{
                frames.by_provenance[0], frames.by_provenance[1], frames.by_provenance[2],
                frames.by_provenance[3], frames.screens_with_unwritten,
            });
        }
    } else {
        try out.print("skip  round-trip        needs the ROM\n", .{});
        try out.print("skip  coverage          needs the ROM\n", .{});
        try out.print("skip  frames            needs the ROM\n", .{});
    }

    // ---- ROM-dependent: does the emulator run the game the same way twice? -
    //
    // The Game Boy core's correctness bar is blargg's suites, which run in the
    // unit tests this step already depends on. What is checked here is the
    // other half: that running the retail ROM produces the *same* trace twice,
    // frame by frame, and that the trace is of a machine actually playing the
    // game rather than one reproducibly sitting in a crash loop.
    if (rom_bytes) |bytes| blk: {
        if (bytes.len != rom_mod.expected_size) break :blk;

        var a = try trace.capture(arena, bytes, trace.retail_frames);
        defer a.deinit(arena);
        var b = try trace.capture(arena, bytes, trace.retail_frames);
        defer b.deinit(arena);

        if (trace.firstDifference(a, b)) |frame| {
            failures += 1;
            try out.print("FAIL  emulator          two runs of the retail ROM diverge at frame {d}\n", .{frame});
        } else if (!a.alive(trace.retail_frames)) {
            failures += 1;
            try out.print("FAIL  emulator          reproducible, but the machine is not running the game\n", .{});
            try out.print("        {d}/{d} frames, {d} instructions, LCD {s}, {d} bytes of VRAM written\n", .{
                a.frames, trace.retail_frames, a.instructions,
                if (a.lcd_on) "on" else "off", a.vram_nonzero,
            });
        } else {
            try out.print("ok    emulator          {d} frames reproduce, {d}M instructions, bank {d}, {d}/8192 VRAM\n", .{
                a.frames, a.instructions / 1_000_000, a.high_bank, a.vram_nonzero,
            });
        }

        if (a.unknown_io != 0) {
            // Not a failure: it means the game touched a register we do not
            // model, which may or may not matter. It is surfaced rather than
            // swallowed so it cannot become the unexplained cause of a Step 9
            // render mismatch.
            try out.print("warn  emulator          {d} writes to unmodelled IO (last ${x:0>4})\n", .{
                a.unknown_io, a.last_unknown_io,
            });
        }
    } else {
        try out.print("skip  emulator          needs the ROM\n", .{});
    }

    // ---- ROM-dependent: the logic inventory ledger -------------------------
    //
    // The ledger is a progress metric, so most of it cannot be asserted: "N of
    // ~20,000" is a number that is supposed to move. What can be asserted is
    // that the machinery producing it is still telling the truth, and those are
    // the four claims below.
    //
    //   * The observation reached the game. A run that sat on the title screen
    //     would report a small, stable, entirely wrong ledger and nothing else
    //     here would notice -- so the machine has to end up in a room, and to
    //     have exercised more than one pose while getting there.
    //   * Execution found what the bytes could not. If dispatch targets ever
    //     stop appearing, either the `JP HL` detection has broken or the
    //     amendment that removed `mgbdis` needs re-arguing.
    //   * Nothing named has drifted. Every address in `known` is an entry or a
    //     label inside one; `absent` means a citation no longer lands on an
    //     instruction boundary.
    //   * The decode agrees with the CPU. `misaligned` counts executed
    //     instruction starts that a routine's body covered without claiming as
    //     starts, which is what a disassembler walking into data looks like.
    if (rom_bytes) |bytes| blk: {
        if (bytes.len != rom_mod.expected_size) break :blk;

        const obs = try ledger_mod.observe(arena, bytes, .{});
        var l = try ledger_mod.build(arena, bytes, obs);
        const c = l.counts();

        var bad = false;
        if (!l.obs.alive or !l.obs.inRoom() or l.obs.poseCount() < 4) {
            failures += 1;
            bad = true;
            try out.print(
                "FAIL  logic ledger      the observed run never got into the game: {s}, {s}, {d} poses\n",
                .{
                    if (l.obs.alive) "alive" else "not alive",
                    if (l.obs.inRoom()) "in a room" else "not in a room",
                    l.obs.poseCount(),
                },
            );
        }
        if (c.dispatch == 0) {
            failures += 1;
            bad = true;
            try out.print("FAIL  logic ledger      no dispatch targets: the JP HL detection found nothing\n", .{});
        }
        for (ledger_mod.known, l.known_state) |k, st| {
            if (st != .absent) continue;
            failures += 1;
            bad = true;
            try out.print("FAIL  logic ledger      {s} (bank {d} ${X:0>4}) is no longer an instruction boundary\n", .{
                k.name, k.bank, k.addr,
            });
        }
        if (l.misaligned != 0) {
            failures += 1;
            bad = true;
            try out.print("FAIL  logic ledger      {d} executed instruction starts land inside a decoded instruction\n", .{l.misaligned});
        }

        if (!bad) {
            const pct = l.distinct_instructions * 100 / ledger_mod.stated_logic_lines;
            try out.print("ok    logic ledger      {d} routines, {d} instructions ({d}% of the stated ~{d} lines)\n", .{
                c.total, l.distinct_instructions, pct, ledger_mod.stated_logic_lines,
            });
            try out.print("      conversion        {d} converted, {d} partial, {d} unconverted; {d} tested, {d} untested\n", .{
                c.converted, c.partial, c.unconverted, c.tested, c.untested,
            });
            try out.print("      evidence          {d} found only by watching the game run; {d} of {d} doors returned\n", .{
                c.dispatch, l.obs.doors_returned, l.obs.doors_run,
            });
        }

        // ---- F4's table-driven dispatch survey -----------------------------
        //
        // Built on the same observation as the ledger above, deliberately: the
        // survey's sites and the ledger's routine boundaries both come from
        // one execution trace, and running the survey on a second observation
        // would let the two disagree about which run they are describing.
        //
        // Reported beside the ledger's own percentage rather than under it,
        // because they are shares of different things -- the ledger's is
        // instructions against the stated ~20,000 lines, the survey's is
        // dispatch arms against the instructions the ledger found -- and a
        // reader who confuses them concludes the survey covers half the game.
        var sv = try dispatch.survey(arena, bytes, obs, l);
        defer sv.deinit(arena);

        if (sv.sites.len < dispatch.gate_sites_floor or
            sv.located() < dispatch.gate_located_floor)
        {
            failures += 1;
            try out.print(
                "FAIL  dispatch survey   {d} sites and {d} located tables, under the floors of {d} and {d}\n",
                .{ sv.sites.len, sv.located(), dispatch.gate_sites_floor, dispatch.gate_located_floor },
            );
        } else if (sv.entryShare() < dispatch.gate_entry_share_floor) {
            failures += 1;
            try out.print(
                "FAIL  dispatch survey   the survey accounts for {d:.1}% of ledger instructions, under the floor of {d:.0}%\n",
                .{ sv.entryShare(), dispatch.gate_entry_share_floor },
            );
        } else {
            try out.print(
                "ok    dispatch survey   {d} sites, {d} with a located table, {d} table entries (floors {d} and {d})\n",
                .{ sv.sites.len, sv.located(), sv.tableEntries(), dispatch.gate_sites_floor, dispatch.gate_located_floor },
            );
            try out.print(
                "      the F4 share      {d} of {d} ledger instructions reachable from a table entry: {d:.1}%\n",
                .{ sv.entry_instructions, sv.total_instructions, sv.entryShare() },
            );
            try out.print(
                "      read together     the ledger's {d}% is instructions against ~{d} stated lines; this is\n" ++
                    "                        dispatch arms against the {d} instructions the ledger found\n",
                .{
                    l.distinct_instructions * 100 / ledger_mod.stated_logic_lines,
                    ledger_mod.stated_logic_lines,
                    sv.total_instructions,
                },
            );
            try out.print("      not reached       {d} dispatch layer(s) no run of this repository can have seen; see `zig build dispatch`\n", .{
                dispatch.unreached.len,
            });
            if (sv.siblings.len != 0) {
                try out.print(
                    "      same shape        {d} of {d} sites sharing an observed indexer were never entered by any run\n",
                    .{ sv.unobservedSiblings(), sv.siblings.len },
                );
            }
        }
        // What the unit suite must not assert, because asserting it needs an
        // observation and `ledger.zig` states the rule: two minutes of
        // emulation belongs in the gate, not the unit suite. The observation is
        // already in hand here, so these cost nothing.
        {
            var complaints: std.ArrayList(dispatch.Complaint) = .empty;
            defer complaints.deinit(arena);
            try dispatch.checkAgainstObservation(arena, bytes, sv, &complaints);
            for (complaints.items) |complaint| {
                failures += 1;
                try out.print("FAIL  dispatch survey   {s}: {s}\n", .{ complaint.what, complaint.detail });
            }
        }

        // The cross-check the two inventories exist to give each other. An arm
        // the survey found that no ledger routine contains means they disagree
        // about where a body starts, and neither can be quietly right.
        if (sv.arms_without_row != 0) {
            failures += 1;
            try out.print(
                "FAIL  dispatch survey   {d} dispatch arm(s) fall in no ledger routine; the two inventories disagree\n",
                .{sv.arms_without_row},
            );
        }
        for (sv.sites) |site| {
            if (dispatch.routineAt(l, site.site) != null) continue;
            try out.print("      site without row  {d}:${X:0>4} dispatches {d} arm(s) and sits in no ledger routine\n", .{
                site.bank(), site.addr(), site.arms.len,
            });
        }
    } else {
        try out.print("skip  logic ledger      needs the ROM\n", .{});
    }

    // ---- ROM-dependent: how far is each replay still the published run? ---
    //
    // F10 makes the published run the whole-game gate and its reachable-frame
    // count the progress metric. A metric nothing holds is a number in a log,
    // so the floors live in `tas.published` and this fails when one is missed.
    //
    // It is meant to go up. When it does, raise the floor in `tas.zig` -- the
    // point of the rung is that a change which *shortens* the horizon cannot
    // pass, and that a longer one is a deliberate edit rather than a drift.
    if (rom_bytes) |bytes| blk: {
        if (bytes.len != rom_mod.expected_size) break :blk;
        var any_missing = false;
        for (tas.published) |p| {
            const movie_bytes = std.Io.Dir.cwd().readFileAlloc(init.io, p.path, arena, .limited(8 << 20)) catch {
                any_missing = true;
                continue;
            };
            const movie = tas.parse(movie_bytes) catch |err| {
                failures += 1;
                try out.print("FAIL  tas horizon       {s}: {s}\n", .{ p.path, @errorName(err) });
                continue;
            };
            const got = try tas.horizonOf(arena, bytes, movie, .{ .max_frames = p.floor + 600 });
            if (got) |stop| {
                if (stop.frame < p.floor) {
                    failures += 1;
                    try out.print(
                        "FAIL  tas horizon       {s} stops being the published run at frame {d}, under the floor of {d}\n",
                        .{ p.name, stop.frame, p.floor },
                    );
                } else {
                    try out.print(
                        "ok    tas horizon       {s} still the published run at frame {d} (floor {d})\n",
                        .{ p.name, stop.frame, p.floor },
                    );
                }
                // What stopped it, which is what names the next thing to build.
                if (stop.stuck) |st| {
                    try out.print(
                        "      stopped by        held ${X:0>2} into a refusal of {d} frames at {X:0>4},{X:0>4}, pose ${X:0>2}\n",
                        .{ st.offered, st.frames, st.samus_x, st.samus_y, st.pose },
                    );
                } else if (stop.left_play) {
                    try out.print("      stopped by        the replay left play\n", .{});
                }
            } else {
                try out.print(
                    "ok    tas horizon       {s} still the published run at frame {d}, where the window ends (floor {d})\n",
                    .{ p.name, p.floor + 600, p.floor },
                );
            }
        }
        if (any_missing) try out.print("skip  tas horizon       no movies in vendor/tas -- run tools/get-tas.sh\n", .{});
    } else {
        try out.print("skip  tas horizon       needs the ROM\n", .{});
    }

    // ---- ROM-dependent: does our rasteriser agree with SameBoy? -----------
    //
    // The comparison itself is a unit test; what it reports is printed here.
    // A test that writes to stderr makes Zig's build runner print
    // `failed command:` beside a passing step, which makes a green gate read
    // red -- and the residual is exactly the number that must not be allowed to
    // grow quietly, so it belongs in gate output rather than nowhere.
    switch (try sameboy.compare(init.io, arena)) {
        .skipped => |why| try out.print("skip  sameboy           {s}\n", .{why.why()}),
        .mismatch => |m| {
            failures += 1;
            try out.print("FAIL  sameboy           {s} {d}s differs beyond the object slack ({d} px)\n", .{
                m.kind, m.secs, m.differing,
            });
        },
        .matched => |sum| {
            try out.print("ok    sameboy           {d} captures match ({d} in play), {d} px/frame masked as objects\n", .{
                sum.compared, sum.in_play, sum.avg_masked,
            });
            if (sum.strict_total != 0) {
                try out.print("      residual          {d} object px over {d} captures, all within {d} px of a sprite\n", .{
                    sum.strict_total, sum.strict_frames, sameboy.object_slack,
                });
            }
        },
    }

    // ---- ROM-dependent: does the converted set fit the region layout? -----
    //
    // The layout is a standalone manifest (`snes_layout.zig`), not something the
    // injector derives, so this line is the one place the two can disagree.
    // What it reports is the tightest class, because the total has slack the
    // individual regions do not.
    if (rom_bytes) |bytes| {
        var set = try snes_convert.run(arena, bytes);
        defer set.deinit();
        const m = snes_layout.measure(set);

        // Tightest by *fraction* of its reserve, not by spare bytes: `solidity`
        // has 4064 bytes free and is 32 bytes of data, while `map_screens` has
        // 47 KiB free and is the class that would actually run out first.
        var tightest: snes_layout.Class = .chr_bg;
        var tightest_pct: usize = 0;
        for (std.enums.values(snes_layout.Class)) |class| {
            const c = m.get(class);
            const r = snes_layout.reserved[@intFromEnum(class)];
            const pct = c.packed_size * 100 / r;
            if (pct > tightest_pct) {
                tightest_pct = pct;
                tightest = class;
            }
        }

        if (m.fits()) {
            try out.print("ok    snes layout       {d} KiB converted into {d} KiB reserved, {s} cart {d} KiB\n", .{
                m.totalPacked() / 1024,
                (snes_layout.manifestEnd() - snes_layout.engine_reserved) / 1024,
                @tagName(snes_layout.mapper),
                snes_layout.romSize() / 1024,
            });
            try out.print("      headroom          tightest is {s} at {d}% of its region; assets {d} door_op, {d} shared_window, {d} entry_kind\n", .{
                tightest.label(), tightest_pct,
                m.by_basis[0], m.by_basis[1], m.by_basis[2],
            });
        } else {
            failures += 1;
            try out.print("FAIL  snes layout      converted set does not fit; run `zig build convert` for the per-class report\n", .{});
        }
    } else {
        try out.print("skip  snes layout       needs the ROM\n", .{});
    }

    // ---- ROM-dependent: do converted assets render like the Game Boy? -----
    //
    // The comparison that the whole conversion exists to face. Both sides read
    // the same screen and the same tileset assignment; only the bytes in
    // between differ, and they must produce identical pixels.
    //
    // **Which is exactly why it says nothing about the assignment.** The chosen
    // table is an input to both sides, so a cell assigned the wrong table
    // renders wrong identically and passes here. Step 4 measured how often that
    // happens -- `zig build oracle -- worlds`, against the tilemap of a running
    // Game Boy -- and the output below is worded so this rung cannot be read as
    // having covered it.
    //
    // The fault sweep is reported beside it because a diff of zero is only
    // evidence if it could have been something else. Four deliberate errors -
    // transposed metatile quadrants, a transposed screen body, a rotated
    // palette, swapped bitplanes - are injected into the converted path and
    // each must be caught.
    if (rom_bytes) |bytes| {
        var set = try snes_convert.run(arena, bytes);
        defer set.deinit();

        const clean = try snes_render.compareAll(arena, bytes, set, .none);
        if (clean.differing == 0) {
            try out.print("ok    snes render       {d} screens convert pixel for pixel, each through the table it was assigned\n", .{clean.compared});
            try out.print("      not this rung     whether that table is the right one: both sides read the same choice.\n" ++
                "                        `zig build oracle -- worlds` grades the choice against a running Game Boy\n", .{});
        } else {
            failures += 1;
            try out.print("FAIL  snes render      {d}/{d} screens differ ({d} px), first bank ${X} pos ${X}\n", .{
                clean.differing, clean.compared, clean.differing_pixels, clean.first_bank, clean.first_pos,
            });
        }

        var caught: usize = 0;
        const faults = [_]snes_render.Fault{ .metatile_quadrants, .tilemap_transpose, .palette_permute, .bitplane_swap };
        var least: usize = std.math.maxInt(usize);
        var least_bp: usize = std.math.maxInt(usize);
        const screen_pixels = screens_mod.screen_pixels;
        for (faults) |f| {
            const c = try snes_render.compareAll(arena, bytes, set, f);
            if (c.differing != 0) caught += 1;
            if (c.differing < least) least = c.differing;
            // How loud the fault is in the diff channel, over everything
            // compared. "Visually obvious" as a number rather than a claim.
            const bp = if (c.compared == 0) 0 else c.differing_pixels * 10_000 / (c.compared * screen_pixels);
            if (bp < least_bp) least_bp = bp;
        }
        if (caught == faults.len) {
            try out.print("      fault sweep       {d}/{d} injected faults caught, the weakest on {d} screens and {d}.{d:0>2}% of pixels\n", .{
                caught, faults.len, least, least_bp / 100, least_bp % 100,
            });
        } else {
            failures += 1;
            try out.print("FAIL  fault sweep      only {d}/{d} injected faults caught\n", .{ caught, faults.len });
        }
    } else {
        try out.print("skip  snes render       needs the ROM\n", .{});
    }

    // ---- Always: the committed engine image -------------------------------
    //
    // `engine.bin` and `engine.sym` are checked in so an end user needs no
    // assembler. That convenience is also a hazard: a committed binary can
    // drift from the source it claims to be built from, and nothing in a normal
    // build would notice. When an assembler is present the source is
    // reassembled and compared; when it is not, this says so rather than
    // reporting green on an unchecked artifact.
    {
        const reserved = snes_layout.engine_reserved;
        const used = snes_inject.image.len;
        if (used > reserved) {
            failures += 1;
            try out.print("FAIL  snes engine      image is {d} bytes, {d} over the {d} reserved\n", .{
                used, used - reserved, reserved,
            });
        } else {
            try out.print("ok    snes engine       {d} KiB image in {d} KiB reserved, patch table at ${X:0>6}\n", .{
                used / 1024, reserved / 1024, snes_inject.symbol("RegionTable") orelse 0,
            });
        }

        switch (try reassemble(arena, init.io)) {
            .matches => try out.print("      engine source     engine.bin and engine.sym are what engine/main.asm assembles to\n", .{}),
            .no_assembler => try out.print("      engine source     not rechecked: no assembler (run tools/get-asar.sh)\n", .{}),
            .differs => |what| {
                failures += 1;
                try out.print("FAIL  engine source    committed {s} is not what engine/main.asm assembles to; run `zig build engine`\n", .{what});
            },
            .failed => |why| {
                failures += 1;
                try out.print("FAIL  engine source    could not reassemble engine/main.asm: {s}\n", .{why});
            },
        }
    }

    // ---- Always: the GB APU shim package and the SPC700 engine ------------
    //
    // `audio/shim/` is another repository's build product, copied in. Nothing
    // else in the tree is, and nothing else can go stale without some build
    // step noticing — see the header of `src/audio_shim.zig`.
    {
        const want = try audio_shim.engineExpectedAbi(arena, init.io);
        switch (try audio_shim.check(arena, init.io, want)) {
            .absent => try out.print("      audio shim        no audio/shim/ yet (metroid2-audio Step 4; tools/sync-shim.sh)\n", .{}),
            .ok => |ok| {
                try out.print("ok    audio shim        ABI {d}, {d} files, {d} bytes, from snes_game_dev {s}\n", .{
                    ok.abi, audio_shim.files.len, ok.bytes, ok.commit[0..@min(ok.commit.len, 12)],
                });
                // The ARAM image the cart uploads at boot: the shim, the engine
                // and bank 4's data, against the regions the shim's own map
                // declares. Needs no ROM -- every size is an offsets entry or a
                // build product -- so it runs whenever the package is present.
                {
                    const engine_bin = std.Io.Dir.cwd().readFileAlloc(init.io, "engine/audio.bin", arena, .limited(1 << 16)) catch null;
                    const layout = try aram_layout.plan(arena, if (engine_bin) |b| b.len else 0);
                    if (aram_layout.check(layout)) |o| {
                        failures += 1;
                        try out.print("FAIL  aram layout      {s} needs {d} bytes of the {d} the shim reserves\n", .{
                            @tagName(o.class), o.used, o.capacity,
                        });
                    } else {
                        try out.print("ok    aram layout       bank 4's data is {d} B of {d} KiB reserved; engine {d} B, shim {d} B\n", .{
                            layout.used(.sound_data),
                            aram_layout.Class.sound_data.capacity() / 1024,
                            layout.used(.engine_code),
                            layout.used(.shim),
                        });
                    }
                }
                // And the committed copy of those addresses that the engine's
                // assembly reads. It is generated, so the only way it can be
                // wrong is by being stale -- and a stale one assembles fine and
                // sends the engine to read the wrong table, which is silent.
                {
                    const planned = try aram_layout.includeText(arena);
                    const have = std.Io.Dir.cwd().readFileAlloc(init.io, aram_layout.include_path, arena, .limited(1 << 16)) catch null;
                    if (have == null) {
                        failures += 1;
                        try out.print("FAIL  aram symbols     {s} is absent; run `zig build aramsyms`\n", .{aram_layout.include_path});
                    } else if (!std.mem.eql(u8, have.?, planned)) {
                        failures += 1;
                        try out.print("FAIL  aram symbols     {s} is not what the layout plans; run `zig build aramsyms`\n", .{aram_layout.include_path});
                    } else {
                        try out.print("ok    aram symbols      {s} is what the layout plans\n", .{aram_layout.include_path});
                    }
                }
                switch (try reassembleSpc(arena, init.io)) {
                    .matches => try out.print("      audio engine      audio.bin and audio.mlb are what engine/audio/main.asm assembles to\n", .{}),
                    .no_assembler => try out.print("      audio engine      not rechecked: no assembler (run tools/get-spc700asm.sh)\n", .{}),
                    .differs => |what| {
                        failures += 1;
                        try out.print("FAIL  audio engine     committed {s} is not what engine/audio/main.asm assembles to; run `zig build spcengine`\n", .{what});
                    },
                    .failed => |why| {
                        failures += 1;
                        try out.print("FAIL  audio engine     could not reassemble engine/audio/main.asm: {s}\n", .{why});
                    },
                }
            },
            .failed => |why| {
                failures += 1;
                try out.print("FAIL  audio shim       {s}\n", .{why});
            },
        }
    }

    // ---- ROM-dependent: is the cart as loud as the Game Boy? --------------
    //
    // metroid2-0b Step 24f. `audiocmp` says the engine's writes are the Game
    // Boy's; this says what the shim and the S-DSP make of them is at the Game
    // Boy's level, as SameBoy renders it. Absent pieces are "did not run", the
    // way every rung whose reference is not tracked reports.
    if (rom_bytes) |bytes| blk: {
        if (comptime !build_options.have_sameboy) {
            try out.print("      audio level       not run: no SameBoy at vendor/sameboy (tools/sameboy-frames.sh)\n", .{});
            break :blk;
        } else {
            const engine_bin = std.Io.Dir.cwd().readFileAlloc(init.io, "engine/audio.bin", arena, .limited(1 << 16)) catch {
                try out.print("      audio level       not run: engine/audio.bin is absent (zig build spcengine)\n", .{});
                break :blk;
            };
            std.Io.Dir.cwd().access(init.io, audio_level_run.spcrun_path, .{}) catch {
                try out.print("      audio level       not run: no {s} (tools/get-spcrun.sh)\n", .{audio_level_run.spcrun_path});
                break :blk;
            };
            var why: []const u8 = "";
            const ms = audio_level_run.run(init.gpa, arena, init.io, bytes, engine_bin, &why) catch |e| {
                failures += 1;
                try out.print("FAIL  audio level      {s} rendering '{s}'\n", .{ @errorName(e), why });
                break :blk;
            };
            const v = audio_level.grade(&ms) catch |e| {
                failures += 1;
                try out.print("FAIL  audio level      no verdict: {s}\n", .{@errorName(e)});
                break :blk;
            };
            const sign = audio_level_run.sign;
            if (v.ok()) {
                try out.print("ok    audio level       the cart {s}{d:.1} dB against SameBoy over {d} sounds (within {d:.0}), farthest {s} {s}{d:.1} (within {d:.0})\n", .{
                    sign(v.set_db),              @abs(v.set_db),   ms.len,                 audio_level.set_tolerance_db,
                    audio_level.cases[v.worst_index].name, sign(v.worst_db), @abs(v.worst_db), audio_level.case_tolerance_db,
                });
            } else {
                failures += 1;
                try out.print("FAIL  audio level      the cart {s}{d:.1} dB against SameBoy (within {d:.0}), farthest {s} {s}{d:.1} (within {d:.0}); WAVs in {s}/\n", .{
                    sign(v.set_db),              @abs(v.set_db),   audio_level.set_tolerance_db,
                    audio_level.cases[v.worst_index].name, sign(v.worst_db), @abs(v.worst_db), audio_level.case_tolerance_db,
                    audio_level_run.out_dir,
                });
                _ = try audio_level_run.report(out, &ms, "        ");
            }
        }
    }

    // ---- ROM-dependent: does the whole thing build, the same way twice? ----
    //
    // The end of the pipeline. Two independent runs from the same input ROM
    // must produce byte-identical carts: a builder whose output depends on hash
    // map iteration order or a timestamp cannot be diffed against itself
    // between versions, which is how every later step will find out what it
    // changed.
    if (rom_bytes) |bytes| {
        var first: [32]u8 = undefined;
        var second: [32]u8 = undefined;
        var blobs: usize = 0;
        var overflow: ?snes_inject.Diagnosis = null;
        for ([_]*[32]u8{ &first, &second }) |slot| {
            var set = try snes_convert.run(arena, bytes);
            defer set.deinit();
            const boot = try snes_screen.chooseBoot(arena, bytes);
            var diag: snes_inject.Diagnosis = .{};
            var rom = snes_inject.build(arena, set, boot, &diag) catch {
                overflow = diag;
                break;
            };
            defer rom.deinit();
            blobs = rom.placements.len;
            slot.* = rom.digest();
        }
        // 1.0 Step 2b: the `--debug` cart, twice, and what it differs from the
        // retail one in -- `DebugAllowed` and the checksum, and nothing else.
        var debug_same = true;
        var debug_diff: usize = 0;
        var debug_first: ?[32]u8 = null;
        if (overflow == null) for (0..2) |_| {
            var set = try snes_convert.run(arena, bytes);
            defer set.deinit();
            const boot = try snes_screen.chooseBoot(arena, bytes);
            var diag: snes_inject.Diagnosis = .{};
            var retail = try snes_inject.build(arena, set, boot, &diag);
            defer retail.deinit();
            var debug = try snes_inject.build(arena, set, boot, &diag);
            defer debug.deinit();
            try snes_inject.enableDebug(&debug);
            const d = debug.digest();
            if (debug_first) |f| debug_same = debug_same and std.mem.eql(u8, &f, &d) else debug_first = d;
            const allowed = snes_inject.symbolOffset("DebugAllowed").?;
            const sums = [_]usize{ snes_inject.symbolOffset("ChecksumComplement").?, snes_inject.symbolOffset("Checksum").? };
            debug_diff = 0;
            for (retail.bytes, debug.bytes, 0..) |r, g, i| {
                if (r == g) continue;
                if (i == allowed or (i >= sums[0] and i < sums[0] + 2) or (i >= sums[1] and i < sums[1] + 2)) continue;
                debug_diff += 1;
            }
            if (retail.bytes[allowed] != 0 or debug.bytes[allowed] != 1) debug_diff += 1;
        };
        if (overflow) |diag| {
            failures += 1;
            try out.print("FAIL  snes rom         injection failed: {s}\n", .{diag.message});
        } else if (!std.mem.eql(u8, &first, &second)) {
            failures += 1;
            try out.print("FAIL  snes rom         two runs on the same ROM produced different bytes\n", .{});
        } else if (!debug_same) {
            failures += 1;
            try out.print("FAIL  snes rom         two --debug builds on the same ROM produced different bytes\n", .{});
        } else if (debug_diff != 0) {
            failures += 1;
            try out.print("FAIL  snes rom         the --debug cart differs from the retail one in {d} bytes besides DebugAllowed and the checksum\n", .{debug_diff});
        } else {
            try out.print("ok    snes rom          {d} KiB cart, {d} blobs placed, identical across two runs\n", .{
                snes_layout.romSize() / 1024, blobs,
            });
            try out.print("      rom digest        sha256 {x}\n", .{&first});
            try out.print("      --debug           identical across two runs; DebugAllowed and the checksum its only difference\n", .{});
        }
    } else {
        try out.print("skip  snes rom          needs the ROM\n", .{});
    }

    // ---- With a ROM and an emulator: does the cart actually draw? ----------
    //
    // Everything above this line checks bytes. This runs them. Four bugs in
    // Step 12 - a stack imbalance, an operand width, an unseeded variable and
    // an aliased scratch - were all invisible to byte checks and all obvious
    // the moment a processor executed the image, so the gate executes it.
    if (rom_bytes) |bytes| {
        var set = try snes_convert.run(arena, bytes);
        defer set.deinit();
        const boot = try snes_screen.chooseBoot(arena, bytes);
        var diag: snes_inject.Diagnosis = .{};
        var rom = try snes_inject.build(arena, set, boot, &diag);
        defer rom.deinit();
        var lua: std.Io.Writer.Allocating = .init(arena);
        defer lua.deinit();
        try snes_romtest.write(arena, bytes, set, boot, &lua.writer);

        switch (try bootTest(arena, init.io, rom.bytes, lua.written())) {
            .drew => {
                try out.print("ok    snes boot         the cart draws map {d} cell ${X:0>2} pixel for pixel in Mesen2\n", .{
                    boot.map_index, boot.cell,
                });
                try out.print("      play window       {d}x{d} compared against the reference render; camera obeys the scroll flags\n", .{
                    snes_target.view_w, snes_target.view_h,
                });
                try out.print("      samus             she falls onto the collision data, jumps the arc and lands on the row she left\n", .{});
                try out.print("      camera            while she walks it holds her at the original's guide offset, 56 px behind and 104 ahead\n", .{});
                try out.print("      scrolling         walking crosses a screen boundary a pixel at a time, and the neighbour it streams in matches\n", .{});
                try out.print("      input             a held direction reads as held every frame and as newly pressed on exactly one\n", .{});
                try out.print("      samus sprite      composed into OAM every frame, at the guide with the biases exchanged; the id follows the pose and the facing\n", .{});
                try out.print("      transition        handed a door index, the cart runs the script and its WARP re-seats map, cell, camera and Samus\n", .{});
                try out.print("      and only the seat  the screen halves become the warp's; every pixel half is the one it had\n", .{});
                try out.print("      and how long       the crossing takes the frames a Game Boy would spend on that script\n", .{});
                try out.print("      and the room       the incoming edge is the room it arrived in, going right and going down\n", .{});
                try out.print("      item pickup        the Bomb lands four frames after the freeze, on the bit the cartridge's\n", .{});
                try out.print("                         own arm sets, and Samus is frozen for all $0160 frames of the jingle\n", .{});
                try out.print("      and what it is for  the ball jumps with the Bomb held and rolls without it, which is\n", .{});
                try out.print("                         the first `!Items` branch anything on this cart has ever taken\n", .{});
                try out.print("      destructible block  the floor under Samus cracks, empties and comes back on the six\n", .{});
                try out.print("                         counters the cartridge names, and she falls and stands with it\n", .{});
                try out.print("      and off camera     a block the camera has left frees its slot and draws nothing\n", .{});
                try out.print("      a shot             the fire button makes a projectile, it flies the way she faces,\n", .{});
                try out.print("                         and it breaks the block it meets and dies there\n", .{});
                try out.print("      and into an enemy  the same shot takes `weapon_damage`'s first entry off a slot,\n", .{});
                try out.print("                         stuns it, and dies on it\n", .{});
                try out.print("      the enemy is drawn  an active slot puts its metasprite in OAM where the slot says it is,\n", .{});
                try out.print("                         and the slot going takes the objects with it\n", .{});
                try out.print("      and a kill finishes  the corpse runs its explosion frames, frees its slot, and a\n", .{});
                try out.print("                         beam fired through where it was flies on instead of dying on it\n", .{});
                try out.print("      and what it leaves  a corpse whose flag asks for small health becomes that drop, blinks,\n", .{});
                try out.print("                         and hands Samus $05 BCD when she touches it\n", .{});
                try out.print("      a missile          she boots carrying `initialSaveFile`'s loadout; Select swaps the cannon's tiles\n", .{});
                try out.print("                         and costs `beginGraphicsTransfer`'s frame; the shot spends one in BCD,\n", .{});
                try out.print("                         and with none left it is the dud\n", .{});
                try out.print("      the status bar     from WY down the band is BG2's window tiles over the backdrop, the icon is in OAM\n", .{});
                try out.print("                         on `frameCounter` bit 4's sprite and rises for a major item or a station, and the displayed\n", .{});
                try out.print("                         health rolls one unit a frame with a tick on every fourth\n", .{});
                try out.print("      the spider ball    Down in the ball enters it only with bit 5 held; on a floor both bottom corners\n", .{});
                try out.print("                         touch, it rolls a pixel a frame on one axis, stops with the pad and leaves on A,\n", .{});
                try out.print("                         and falling or jumping onto a floor it attaches\n", .{});
                try out.print("      a save station     standing on its tile sets the contact; Start takes the save on a frame of its own,\n", .{});
                try out.print("                         cartridge RAM holds the magic and `save.fields` from the live state, Start again\n", .{});
                try out.print("                         during \"COMPLETED\" does nothing, and the contact goes with the cooldown or a door\n", .{});
                try out.print("      frame phase        `!FrameCount` on the first frame of `MainLoop` is the record's seed plus exactly one\n", .{});

                var misses: [boot_faults.len]?FaultMiss = undefined;
                try bootFaultRun(arena, init.io, rom.bytes, lua.written(), &misses);
                var caught: usize = 0;
                for (boot_faults, misses) |f, miss| {
                    const m = miss orelse {
                        caught += 1;
                        continue;
                    };
                    switch (m) {
                        .unplaced => try out.print("FAIL  boot fault       {s}+{d} is not in the engine image\n", .{ f.label, f.offset }),
                        .no_op => try out.print("FAIL  boot fault       {s}+{d} already holds the patch: the cart is not faulted\n", .{ f.label, f.offset }),
                        .not_run => try out.print("FAIL  boot fault       {s}: the faulted cart did not run to a verdict\n", .{f.label}),
                        .passes => try out.print("FAIL  boot fault       {s} taken out and every phase still passes (audit row {s})\n", .{ f.label, f.row }),
                        .elsewhere => |code| try out.print("FAIL  boot fault       {s} taken out and caught by {s} (code {d}), not by the {s} phase that grades it\n", .{
                            f.label, @tagName(std.meta.activeTag(bootVerdict(code))), code, @tagName(f.want),
                        }),
                    }
                }
                // One rung, however many of its faults went uncaught.
                if (caught == boot_faults.len) {
                    try out.print("      fault sweep       {d}/{d} engine faults caught, each by the phase that grades it\n", .{ caught, boot_faults.len });
                } else {
                    failures += 1;
                }
            },
            .no_emulator => {
                try out.print("ok    snes boot         not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
                try out.print("      note              nothing here has executed the engine; bytes only\n", .{});
            },
            .differs => |row| {
                failures += 1;
                try out.print("FAIL  snes boot         the play window differs from the reference render, from row {d}\n", .{row});
            },
            .scrolled_wrong => |row| {
                failures += 1;
                try out.print("FAIL  snes boot         the screen scrolled into does not match the reference render, from row {d}\n", .{row});
            },
            .camera => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart drew, but the camera {s}\n", .{why});
            },
            .samus => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart drew, but Samus {s}\n", .{why});
            },
            .input => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart drew, but the pad {s}\n", .{why});
            },
            .transition => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart drew and played, but the room transition {s}\n", .{why});
            },
            .item => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart drew and crossed, but the item pickup {s}\n", .{why});
            },
            .block => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart drew, crossed and collected, but a block {s}\n", .{why});
            },
            .projectile => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart drew, crossed and broke a block, but a shot {s}\n", .{why});
            },
            .enemy_draw => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart shot and hit, but the enemy {s}\n", .{why});
            },
            .enemy_death => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart drew the enemy, but the kill {s}\n", .{why});
            },
            .bomb => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart shot and killed, but the bomb {s}\n", .{why});
            },
            .missile => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart laid bombs, but the missile {s}\n", .{why});
            },
            .hud => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart fired missiles, but the HUD {s}\n", .{why});
            },
            .metroid => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the cart drew the HUD, but the Metroid {s}\n", .{why});
            },
            .readout => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the Metroid chain held, but the room readout {s}\n", .{why});
            },
            .spider => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the room readout held, but the spider ball {s}\n", .{why});
            },
            .save => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the spider ball held, but the save station {s}\n", .{why});
            },
            .scroll => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         the save station held, but the transition's scroll {s}\n", .{why});
            },
            .sound => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         everything else held, but the sound engine {s}\n", .{why});
            },
            .stalled => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         {s}\n", .{why});
            },
            .failed => |why| {
                failures += 1;
                try out.print("FAIL  snes boot         {s}\n", .{why});
            },
        }
    }


    // ---- With a ROM and an emulator: does the cart a person picks up play? -
    //
    // Every rung above this one boots a cart on a record the gate invented so
    // it has somewhere to stand, and then drives it. This one boots the cart
    // `zig build rom` writes -- whose record is the game's own new game, read
    // out of `initial_save` and the four instructions that end
    // `loadGame_samusData` -- and pulls no lever until the game asks for one.
    //
    // It is the answer to B2's "no longer the only way in", and it is what
    // makes hand playtesting the loop for the rest of the cycle: a cart that
    // needs a synthesised record poked into it is a cart nobody can just play.
    if (rom_bytes) |bytes| {
        var set = try snes_convert.run(arena, bytes);
        defer set.deinit();
        const boot = try snes_screen.newGameBoot(arena, bytes);
        var diag: snes_inject.Diagnosis = .{};
        var rom = try snes_inject.build(arena, set, boot, &diag);
        defer rom.deinit();
        var lua: std.Io.Writer.Allocating = .init(arena);
        defer lua.deinit();
        try snes_romtest.writeColdBoot(arena, bytes, boot, &lua.writer);

        switch (try coldBootTest(init.io, rom.bytes, lua.written())) {
            .played => {
                try out.print("ok    cold boot         title screen to gameplay on the shipped cart, map {d} cell ${X:0>2}\n", .{
                    boot.map_index, boot.cell,
                });
                try out.print("      the title         4096 characters and 1024 tilemap words, against the cartridge's own bytes;\n", .{});
                try out.print("                        it stays up until Start's rising edge and leaves on it\n", .{});
                try out.print("      the record        the game's own: position, camera and facing from `initial_save`,\n", .{});
                try out.print("                        pose ${X:0>2} and {d} frames off the four instructions ending the load\n", .{
                    boot.pose, boot.countdown,
                });
                try out.print("      the sequence      the countdown falls one a frame, she is drawn on three frames in four,\n", .{});
                try out.print("                        control waits for a button after it is spent, and then she walks\n", .{});
                try out.print("      no lever          nothing is written to the cart at any point; the input is Start and a direction\n", .{});

                // And the rung is not vacuous. The cheapest fault that reaches
                // the whole mechanism is in the record rather than in the
                // engine: a cart whose countdown starts at zero boots into the
                // pose with nothing to wait for, and every check after the
                // first has nothing to see. Injected here rather than measured
                // once by hand, for the reason the render and oracle sweeps
                // exist -- a comparator that never fails and one that cannot
                // fail look identical from the outside.
                var faulted = boot;
                faulted.countdown = 0;
                var fdiag: snes_inject.Diagnosis = .{};
                var from = try snes_inject.build(arena, set, faulted, &fdiag);
                defer from.deinit();
                switch (try coldBootTest(init.io, from.bytes, lua.written())) {
                    .played => {
                        failures += 1;
                        try out.print("FAIL  cold boot        a cart whose countdown starts spent still passed: the rung grades nothing\n", .{});
                    },
                    else => try out.print("      fault sweep       a record with the countdown at zero fails it\n", .{}),
                }
            },
            .no_emulator => {
                try out.print("ok    cold boot         not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
            },
            .stalled => |why| {
                failures += 1;
                try out.print("FAIL  cold boot        {s}\n", .{why});
            },
            .sequence => |why| {
                failures += 1;
                try out.print("FAIL  cold boot        the cart booted, but {s}\n", .{why});
            },
            .failed => |why| {
                failures += 1;
                try out.print("FAIL  cold boot        {s}\n", .{why});
            },
        }
    } else {
        try out.print("skip  cold boot         needs the ROM\n", .{});
    }

    // ---- With a ROM and an emulator: does the cart load a save? -----------
    //
    // Step 15b. The shipped cart again, with slot 0 holding James's first save
    // byte for byte and one enemy of the saved room marked dead. Start on the
    // title has to come up in that record -- room, position, camera, energy,
    // items, counts, solidity, the table, the background characters its source
    // names and the item font a load adds -- keep the enemy dead, and hand over
    // control without a button. Then the two ways it must not: a record whose
    // energy disagrees with what the rung expects has to fail it, and a record
    // the title's broken check refuses has to start a new game.
    if (rom_bytes) |bytes| {
        var set = try snes_convert.run(arena, bytes);
        defer set.deinit();
        const boot = try snes_screen.newGameBoot(arena, bytes);
        var diag: snes_inject.Diagnosis = .{};
        var rom = try snes_inject.build(arena, set, boot, &diag);
        defer rom.deinit();

        const Run = struct { mode: snes_romtest.LoadMode, want: u8 };
        const runs = [_]Run{ .{ .mode = .load, .want = 0 }, .{ .mode = .accident, .want = 0 }, .{ .mode = .energy_fault, .want = 164 } };
        var got: [runs.len]?u8 = @splat(null);
        for (runs, 0..) |r, i| {
            var lua: std.Io.Writer.Allocating = .init(arena);
            defer lua.deinit();
            try snes_romtest.writeLoadBoot(arena, bytes, boot, r.mode, &lua.writer);
            got[i] = try loadBootTest(init.io, rom.bytes, lua.written());
            if (got[i] == null) break;
        }
        if (got[0] == null) {
            try out.print("ok    load              not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else {
            var all = true;
            for (runs, got) |r, g| {
                if (g != r.want) {
                    all = false;
                    failures += 1;
                    try out.print("FAIL  load              {s}: exit {d}, wanted {d} ({s})\n", .{ @tagName(r.mode), g.?, r.want, loadCode(g.?) });
                }
            }
            if (all) {
                try out.print("ok    load              slot 0 holds the recording's first save, and the cart comes up in it\n", .{});
                try out.print("      the state         room, position, camera, energy, items, counts, solidity and table\n", .{});
                try out.print("      the graphics      the background its record names, the item font and the common item tiles, against the cartridge's bytes\n", .{});
                try out.print("      the enemy         a spawn the record marks dead stays dead through a second of play\n", .{});
                try out.print("      the handover      control arrives when the countdown is spent, with nothing held\n", .{});
                try out.print("      the title's check a record the broken compare refuses starts a new game, as on the Game Boy\n", .{});
                try out.print("      fault sweep       a record whose energy is not the expected one fails it (164)\n", .{});
            }
        }
    } else {
        try out.print("skip  load              needs the ROM\n", .{});
    }

    // ---- With a ROM and an emulator: is the title the Game Boy's? -----------
    //
    // Step 24h (B14). The shipped cart's title, driven through
    // `title_oracle.script` -- Select, Down held and let go, the equalities,
    // the clear, and Start -- with every slot seeded, and graded frame for
    // frame against our Game Boy running the same script from a cold boot:
    // the three state bytes, the menu's sprites, rows 16 and 17's pixels, the
    // object characters, the slots after the clear, and the new game after it.
    // Then the grader is shown to grade: the same run expecting the cursor a
    // step on fails.
    if (rom_bytes) |bytes| {
        var set = try snes_convert.run(arena, bytes);
        defer set.deinit();
        const boot = try snes_screen.newGameBoot(arena, bytes);
        var diag: snes_inject.Diagnosis = .{};
        var rom = try snes_inject.build(arena, set, boot, &diag);
        defer rom.deinit();

        const Run = struct { run: snes_romtest.TitleRun, want: u8 };
        const runs = [_]Run{ .{ .run = .grade, .want = 0 }, .{ .run = .phase_fault, .want = 96 }, .{ .run = .last_slot_3, .want = 0 } };
        var got: [runs.len]?u8 = @splat(null);
        var luas: std.EnumArray(snes_romtest.TitleRun, []const u8) = .initUndefined();
        for (runs, 0..) |r, i| {
            var lua: std.Io.Writer.Allocating = .init(arena);
            try snes_romtest.writeTitle(arena, bytes, boot, r.run, &lua.writer);
            luas.set(r.run, lua.written());
            got[i] = try titleTest(init.io, rom.bytes, lua.written());
            if (got[i] == null) break;
        }
        if (got[0] == null) {
            try out.print("ok    title             not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else {
            var all = true;
            for (runs, got) |r, g| {
                if (g != r.want) {
                    all = false;
                    failures += 1;
                    try out.print("FAIL  title             {s}: exit {d}, wanted {d} ({s})\n", .{ @tagName(r.run), g.?, r.want, titleCode(g.?) });
                }
            }
            // And each new routine taken out is caught by the code that grades it.
            var misses: [title_faults.len]?TitleMiss = undefined;
            try titleFaultRun(arena, init.io, rom.bytes, luas, &misses);
            for (title_faults, misses) |f, miss| {
                const m = miss orelse continue;
                all = false;
                failures += 1;
                switch (m) {
                    .unplaced => try out.print("FAIL  title fault      {s} is not in the engine image\n", .{f.label}),
                    .no_op => try out.print("FAIL  title fault      {s} already holds the patch: the cart is not faulted\n", .{f.label}),
                    .not_run => try out.print("FAIL  title fault      {s}: the faulted cart did not run to a verdict\n", .{f.label}),
                    .code => |c| try out.print("FAIL  title fault      {s} taken out: exit {d} ({s}), wanted {d}\n", .{ f.label, c, titleCode(c), f.want }),
                }
            }
            if (all) {
                try out.print("ok    title             the file select is the Game Boy's, frame for frame, over {d} frames\n", .{title_oracle.script[title_oracle.script.len - 1].at});
                try out.print("      the picture       rows 16 and 17 (the copyright) pixel for pixel; the menu's characters\n", .{});
                try out.print("      the menu          cursor, number, START and CLEAR as the Game Boy's OAM, every frame\n", .{});
                try out.print("      the arms          Select's, Right's, Left's and Start's equalities, Down's mask, and the clear\n", .{});
                try out.print("      the slots         opened on saveLastSlot's 2 (and on 0 for its 3); Right and Left through both wraps\n", .{});
                try out.print("      the sound         the select sound on every frame the Game Boy asks for it, and on no other\n", .{});
                try out.print("      the clear         slot 1's first two bytes and nothing else; Start then starts a new game there\n", .{});
                try out.print("      \"Super\"           super.png over the Game Boy's title, pixel for pixel, its palette in CGRAM; gone from BG1 in the game\n", .{});
                try out.print("      fault sweep       expecting the cursor a step on fails it (96); {d}/{d} engine faults caught by their codes\n", .{ title_faults.len, title_faults.len });
            }
        }
    } else {
        try out.print("skip  title             needs the ROM\n", .{});
    }

    // ---- With a ROM and an emulator: is the pause the Game Boy's? -----------
    //
    // 1.0 Step 2a. The shipped cart started as a new game and driven through
    // `pause_oracle.script` -- Start facing the screen, Start while walking,
    // held through the pause, out with Start and A, Start with Left, and a
    // second pause -- graded pass for pass against our Game Boy running the
    // same script: the frame counter, the pause and unpause requests, the
    // flash, Samus, the timer, the status bar and the objects. Then the grader
    // is shown to grade: the same run expecting the flash a frame late fails,
    // and so does each new routine taken out.
    if (rom_bytes) |bytes| {
        var set = try snes_convert.run(arena, bytes);
        defer set.deinit();
        const boot = try snes_screen.newGameBoot(arena, bytes);
        var diag: snes_inject.Diagnosis = .{};
        var rom = try snes_inject.build(arena, set, boot, &diag);
        defer rom.deinit();
        // 1.0 Step 2b: and the `--debug` cart, for the one run that sets the flag.
        var debug_rom = try snes_inject.build(arena, set, boot, &diag);
        defer debug_rom.deinit();
        try snes_inject.enableDebug(&debug_rom);

        const Run = struct { run: snes_romtest.PauseRun, want: u8, debug: bool = false };
        const runs = [_]Run{
            .{ .run = .grade, .want = 0 },
            .{ .run = .flash_fault, .want = 114 },
            .{ .run = .combo, .want = 0 },
            .{ .run = .debug_combo, .want = 0, .debug = true },
        };
        var luas: std.EnumArray(snes_romtest.PauseRun, []const u8) = .initUndefined();
        var jobs: [runs.len]PauseJob = undefined;
        for (runs, 0..) |r, i| {
            var lua: std.Io.Writer.Allocating = .init(arena);
            try snes_romtest.writePause(arena, bytes, r.run, &lua.writer);
            luas.set(r.run, lua.written());
            jobs[i] = .{ .rom = if (r.debug) debug_rom.bytes else rom.bytes, .lua = lua.written() };
        }
        var got: [runs.len]?u8 = @splat(null);
        try pauseRuns(arena, init.io, &jobs, &got);
        if (got[0] == null) {
            try out.print("ok    pause             not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else {
            var all = true;
            for (runs, got) |r, g| {
                if (g != r.want) {
                    all = false;
                    failures += 1;
                    try out.print("FAIL  pause             {s}: exit {d}, wanted {d} ({s})\n", .{ @tagName(r.run), g.?, r.want, pauseCode(g.?) });
                }
            }
            var misses: [pause_faults.len]?TitleMiss = undefined;
            try pauseFaultRun(arena, init.io, rom.bytes, debug_rom.bytes, luas, &misses);
            for (pause_faults, misses) |f, miss| {
                const m = miss orelse continue;
                all = false;
                failures += 1;
                switch (m) {
                    .unplaced => try out.print("FAIL  pause fault      {s} is not in the engine image\n", .{f.label}),
                    .no_op => try out.print("FAIL  pause fault      {s} already holds the patch: the cart is not faulted\n", .{f.label}),
                    .not_run => try out.print("FAIL  pause fault      {s}: the faulted cart did not run to a verdict\n", .{f.label}),
                    .code => |c| try out.print("FAIL  pause fault      {s} taken out: exit {d} ({s}), wanted {d}\n", .{ f.label, c, pauseCode(c), f.want }),
                }
            }
            if (all) {
                try out.print("ok    pause             the pause is the Game Boy's, pass for pass, over {d} frames\n", .{pause_oracle.script[pause_oracle.script.len - 1].at});
                try out.print("      the arms          Start alone pauses, facing the screen and with Left it does not; Start with A unpauses\n", .{});
                try out.print("      the frame         the flash, Samus held, the timer held through a counter wrap, the L counter, the L\n", .{});
                try out.print("      the counter       the frame counter carried through the title, as the Game Boy's\n", .{});
                try out.print("      the chord         on the retail cart L+R+Start only pauses, and the run is still the Game Boy's\n", .{});
                try out.print("      debug menu        the chord opens it over a frozen game, A and B walk the tree, B and the chord close it\n", .{});
                try out.print("      fault sweep       expecting the flash a frame late fails it (114); {d}/{d} engine faults caught by their codes\n", .{ pause_faults.len, pause_faults.len });
            }
        }
    } else {
        try out.print("skip  pause             needs the ROM\n", .{});
    }

    // ---- With a ROM and an emulator: does the debug menu set what it says? --
    //
    // 1.0 Step 3. The `--debug` cart as a new game, set up through the debug
    // menu's own input -- the chord, then the pad on the SAMUS page -- and
    // checked after every change against the ROM: the new game's save record,
    // and the bit or value each pickup routine writes. Then closed and a second
    // of play, and checked again. One Mesen2 run per scenario, in parallel,
    // each with its own codes (`scenario.code`); a failing run prints what it
    // compared, and that line is shown here.
    if (rom_bytes) |bytes| {
        var set = try snes_convert.run(arena, bytes);
        defer set.deinit();
        const boot = try snes_screen.newGameBoot(arena, bytes);
        var diag: snes_inject.Diagnosis = .{};
        var debug_rom = try snes_inject.build(arena, set, boot, &diag);
        defer debug_rom.deinit();
        try snes_inject.enableDebug(&debug_rom);

        var jobs: [scenario.scenarios.len + scenario_faults.len]ScenarioJob = undefined;
        var luas: [scenario.scenarios.len][]const u8 = undefined;
        for (scenario.scenarios, 0..) |sc, i| {
            var lua: std.Io.Writer.Allocating = .init(arena);
            try scenario.writeLua(arena, bytes, sc, &lua.writer);
            luas[i] = lua.written();
            jobs[i] = .{ .name = sc.name, .rom = debug_rom.bytes, .lua = luas[i] };
        }
        // The faults: each patched into the cart the clean runs pass, and run
        // with its scenario's script.
        var placed = true;
        for (scenario_faults, scenario.scenarios.len..) |f, i| {
            const at = (snes_inject.symbolOffset(f.label) orelse {
                placed = false;
                try out.print("FAIL  scenario fault   {s} is not in the engine image\n", .{f.label});
                failures += 1;
                jobs[i] = .{ .name = f.label, .rom = debug_rom.bytes, .lua = "" };
                continue;
            }) + f.offset;
            if (std.mem.eql(u8, debug_rom.bytes[at..][0..f.patch.len], f.patch)) {
                placed = false;
                try out.print("FAIL  scenario fault   {s} already holds the patch: the cart is not faulted\n", .{f.label});
                failures += 1;
            }
            const faulted = try arena.dupe(u8, debug_rom.bytes);
            @memcpy(faulted[at..][0..f.patch.len], f.patch);
            const si = for (scenario.scenarios, 0..) |sc, k| {
                if (std.mem.eql(u8, sc.name, f.scenario)) break k;
            } else unreachable;
            jobs[i] = .{ .name = f.label, .rom = faulted, .lua = luas[si] };
        }
        var got: [jobs.len]?ScenarioGot = @splat(null);
        try scenarioRuns(arena, init.io, &jobs, &got);
        if (got[0] == null) {
            try out.print("ok    scenario          not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else {
            var all = placed;
            var edits: usize = 0;
            for (scenario.scenarios, got[0..scenario.scenarios.len]) |sc, g| {
                edits += sc.editCount();
                if (g.?.code == 0) continue;
                all = false;
                failures += 1;
                try out.print("FAIL  scenario          {s}: exit {d} ({s})\n", .{ sc.name, g.?.code, scenario.code(g.?.code) });
                if (g.?.line.len > 0) try out.print("      {s}\n", .{g.?.line});
            }
            for (scenario_faults, got[scenario.scenarios.len..]) |f, g| {
                const c = if (g) |x| x.code else continue;
                if (c == f.want) continue;
                all = false;
                failures += 1;
                try out.print("FAIL  scenario fault   {s} taken out: exit {d} ({s}), wanted {d}\n", .{ f.label, c, scenario.code(c), f.want });
            }
            if (all) {
                try out.print("ok    scenario          {d} scenarios, {d} edits through the debug menu's own input, each checked against the ROM\n", .{ scenario.scenarios.len, edits });
                try out.print("      the reference     the new game's save record; the bit or value each pickup routine writes\n", .{});
                try out.print("      items             the seven bits on with A, off with Left, Right on a bit already set, A to switch\n", .{});
                try out.print("      beams             Right through all four and round to power, Left round, the weapon with them\n", .{});
                try out.print("      counts            tanks up and down, the count held under the ceiling by ten both ways\n", .{});
                try out.print("      loadout           everything; the fifth tank's Right fills as the pickup does\n", .{});
                try out.print("      metroids          kill, revive, kill: counts, flag, shuffle and quake as `.death` and `earthquakeCheck`\n", .{});
                try out.print("      the quake         five kills to $42, two thresholds: the quake queued, and run once the menu closes\n", .{});
                try out.print("      flags             a bank's orb and the loaded bank's baby, in the save buffer and the live array\n", .{});
                try out.print("      clock             hours round 00-99, minutes round 00-59\n", .{});
                try out.print("      fault sweep       {d}/{d} engine faults caught by their edit's code\n", .{ scenario_faults.len, scenario_faults.len });
            }
        }
    } else {
        try out.print("skip  scenario          needs the ROM\n", .{});
    }

    // ---- With a ROM and an emulator: does every warp arrive as the GB's? ----
    //
    // 1.0 Step 5c. Every entry on the WARP page, warped to on the `--debug`
    // cart through the menu's own input, one after another in eight runs that
    // go in parallel. Each is held against our Game Boy running the entry's
    // chain by door index in the same order (`warp_grade.references`): the
    // loaded state a save keeps, the damage, and the characters the loaded
    // metatile table draws. Then she must stand where the entry puts her. The
    // fault: every two-script chain cut to its door alone, which must fail a
    // run on the loaded state or the characters.
    if (rom_bytes) |bytes| {
        var set = try snes_convert.run(arena, bytes);
        defer set.deinit();
        const boot = try snes_screen.newGameBoot(arena, bytes);
        var diag: snes_inject.Diagnosis = .{};
        var debug_rom = try snes_inject.build(arena, set, boot, &diag);
        defer debug_rom.deinit();
        try snes_inject.enableDebug(&debug_rom);
        const faulted = try arena.dupe(u8, debug_rom.bytes);
        const cut = try warp_grade.truncateChains(faulted, debug_rom);

        const built = try warp.build(arena, bytes, try warp.loadWalked(arena, bytes));
        const sorted = try debug_tables.warpOrder(arena, bytes, built.entries);
        // At each entry's count: some are held to the recording's (1.0 Step 18f).
        const refs = try warp_grade.references(arena, bytes, sorted, warp_grade.shard_count, true);
        const n = warp_grade.shard_count;
        const scs = comptime std.enums.values(warp_grade.Scenario);
        var jobs: [2 * n + scs.len + warp_faults.len]ScenarioJob = undefined;
        for (0..n) |k| {
            var lua: std.Io.Writer.Allocating = .init(arena);
            try warp_grade.writeLua(arena, bytes, sorted, refs, k, warp_grade.shard_count, &lua.writer);
            jobs[k] = .{ .name = "warp", .rom = debug_rom.bytes, .lua = lua.written() };
            jobs[n + k] = .{ .name = "warp fault", .rom = faulted, .lua = jobs[k].lua };
        }
        // The scenarios a warp reaches, each with its fault patched into the
        // cart the clean run passes.
        const walked = try warp.loadWalked(arena, bytes);
        var placed = true;
        for (scs, 0..) |sc, i| {
            var lua: std.Io.Writer.Allocating = .init(arena);
            try warp_grade.writeScenarioLua(arena, bytes, sorted, walked, sc, &lua.writer);
            const frames = sc == .queen or sc == .refills or sc == .refill_credits;
            jobs[2 * n + i] = .{ .name = @tagName(sc), .rom = debug_rom.bytes, .lua = lua.written(), .frames = frames };
        }
        // Each fault on its scenario's script, more than one to a scenario
        // where it guards more than one mechanism (1.0 Step 27a).
        for (warp_faults, 0..) |f, i| {
            const sc = std.meta.stringToEnum(warp_grade.Scenario, f.scenario) orelse return error.UnknownWarpScenario;
            const clean = jobs[2 * n + @intFromEnum(sc)];
            const at = (snes_inject.symbolOffset(f.label) orelse {
                placed = false;
                try out.print("FAIL  warp fault        {s} is not in the engine image\n", .{f.label});
                failures += 1;
                jobs[2 * n + scs.len + i] = .{ .name = f.label, .rom = debug_rom.bytes, .lua = "" };
                continue;
            }) + f.offset;
            if (std.mem.eql(u8, debug_rom.bytes[at..][0..f.patch.len], f.patch)) {
                placed = false;
                try out.print("FAIL  warp fault        {s} already holds the patch: the cart is not faulted\n", .{f.label});
                failures += 1;
            }
            const fb = try arena.dupe(u8, debug_rom.bytes);
            @memcpy(fb[at..][0..f.patch.len], f.patch);
            jobs[2 * n + scs.len + i] = .{ .name = f.label, .rom = fb, .lua = clean.lua, .frames = clean.frames };
        }
        var got: [jobs.len]?ScenarioGot = @splat(null);
        try scenarioRuns(arena, init.io, &jobs, &got);
        if (got[0] == null) {
            try out.print("ok    warp              not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else {
            var all = true;
            var hits: usize = 0;
            for (got[0..n], 0..) |g, k| {
                if (g.?.code == 0) {
                    // "20 warps, 1 hit by an enemy once standing"
                    var it = std.mem.tokenizeScalar(u8, g.?.line, ' ');
                    _ = it.next();
                    _ = it.next();
                    hits += std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
                    continue;
                }
                all = false;
                failures += 1;
                const lo, const hi = warp_grade.shardRange(sorted.len, k);
                try out.print("FAIL  warp              entries {d}-{d}: exit {d} ({s})\n", .{ lo, hi - 1, g.?.code, warp_grade.code(g.?.code) });
                if (g.?.line.len > 0) try out.print("      {s}\n", .{g.?.line});
            }
            for (scs, got[2 * n ..][0..scs.len]) |sc, g| {
                if (g.?.code == 0) continue;
                all = false;
                failures += 1;
                try out.print("FAIL  warp              {s}: exit {d} ({s})\n", .{ @tagName(sc), g.?.code, warp_grade.scenarioCode(g.?.code) });
                if (g.?.line.len > 0) try out.print("      {s}\n", .{g.?.line});
            }
            for (warp_faults, got[2 * n + scs.len ..]) |f, g| {
                const c = if (g) |x| x.code else continue;
                if (c == f.want) continue;
                all = false;
                failures += 1;
                try out.print("FAIL  warp fault        {s} taken out: exit {d} ({s}), wanted {d}\n", .{ f.label, c, warp_grade.scenarioCode(c), f.want });
            }
            if (!placed) all = false;
            // The fault must be caught by what it breaks: the chain's loaded
            // state or characters, in at least one run.
            var caught = false;
            for (got[n..][0..n]) |g| {
                const c = g.?.code;
                if (c == 21 or c == 23 or c == 26) caught = true;
            }
            if (!caught) {
                all = false;
                failures += 1;
                try out.print("FAIL  warp fault        {d} chains cut to their door alone, and no run saw the loaded state or characters differ\n", .{cut});
            }
            if (all) {
                try out.print("ok    warp              {d} warps through the menu's own input, each as the Game Boy's chain leaves it, and stood\n", .{sorted.len});
                try out.print("      the reference     our Game Boy running each chain by door index, in the cart's order\n", .{});
                try out.print("      the loaded state  $D808-$D814, the damage, and the characters the loaded metatile table draws\n", .{});
                try out.print("      the map           the background map over the camera's view, tile for tile, on the frame she arrives\n", .{});
                try out.print("      standing          where the entry puts her, in its pose, for a second; {d} hit by an enemy after standing\n", .{hits});
                try out.print("      item              an orb marked taken on FLAGS is not loaded by the warp; reset, it is\n", .{});
                try out.print("      Metroid           Metroid 01 killed on the screen mid-fight: its slot freed, the fight ended, one fewer\n", .{});
                try out.print("      missile kill      a Metroid shot dead after the last one's wait was left: four blasts, dead throughout, gone\n", .{});
                try out.print("      gated door        one Metroid killed, and the door walked through loads the ROM's table for the new count\n", .{});
                try out.print("      fault             {d} chains cut to their door alone: caught on the loaded state or characters\n", .{cut});
                try out.print("      fault sweep       {d}/{d} engine faults caught by their scenario's code\n", .{ warp_faults.len, warp_faults.len });
            }
        }

        // ---- 1.0 Step 18e: a save round trip at every station ----
        //
        // Each station on the WARP page saved in through the menu's own input:
        // FULL LOADOUT, the clock moved, a Metroid of another bank killed, the
        // warp, and with the station's bank loaded one of its Metroids killed
        // and an orb taken. Then Start on the pad, the reset button and the
        // title's load (`save_grade`). The loaded state against our Game Boy
        // running the station's chain from the new game; the record against
        // what she held, and the load against the record. The fault: the
        // load's metatile table not the record's, caught on the view (57).
        {
            const st = try save_grade.stations(arena, sorted);
            const at = try arena.alloc(warp.Entry, st.len);
            for (st, at) |si, *e| e.* = sorted[si];
            const srefs = try warp_grade.references(arena, bytes, at, st.len, false);
            const sjobs = try arena.alloc(ScenarioJob, st.len + 1);
            for (st, srefs, 0..) |si, r, k| {
                var lua: std.Io.Writer.Allocating = .init(arena);
                try save_grade.writeLua(arena, bytes, sorted, si, r, &lua.writer);
                sjobs[k] = .{ .name = "saves", .rom = debug_rom.bytes, .lua = lua.written() };
            }
            var splaced = true;
            const fb = try arena.dupe(u8, debug_rom.bytes);
            if (snes_inject.symbolOffset(save_grade.fault.label)) |o| {
                if (std.mem.eql(u8, fb[o..][0..save_grade.fault.patch.len], save_grade.fault.patch)) splaced = false;
                @memcpy(fb[o..][0..save_grade.fault.patch.len], save_grade.fault.patch);
            } else splaced = false;
            sjobs[st.len] = .{ .name = "saves fault", .rom = fb, .lua = sjobs[0].lua };
            const sgot = try arena.alloc(?ScenarioGot, sjobs.len);
            @memset(sgot, null);
            try scenarioRuns(arena, init.io, sjobs, sgot);
            if (sgot[0] == null) {
                try out.print("ok    saves             not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
            } else {
                var all = true;
                for (sgot[0..st.len], st) |g, si| {
                    if (g.?.code == 0) continue;
                    all = false;
                    failures += 1;
                    const d = sorted[si].dest.at;
                    try out.print("FAIL  saves             {X}:{X:0>2}: exit {d} ({s})\n", .{ d.bank, d.cell, g.?.code, save_grade.code(g.?.code) });
                    if (g.?.line.len > 0) try out.print("      {s}\n", .{g.?.line});
                }
                const fc = sgot[st.len].?.code;
                if (!splaced or fc != save_grade.fault.want) {
                    all = false;
                    failures += 1;
                    try out.print("FAIL  saves fault       {s}: exit {d} ({s}), wanted {d}{s}\n", .{ save_grade.fault.label, fc, save_grade.code(fc), save_grade.fault.want, if (splaced) "" else "; the patch was not placed" });
                }
                if (all) {
                    try out.print("ok    saves             a save round trip at each of {d} stations, through the menu's own input and the reset button\n", .{st.len});
                    try out.print("      the loaded state  $D808-$D814 before the save, in the record and after the load: our Game Boy's for the station's chain\n", .{});
                    try out.print("      the record        what she held on Start; after the load, she is in it\n", .{});
                    try out.print("      the flags         a Metroid of another bank, one of the station's and an orb: dead in the record, loaded back, the orb not loaded\n", .{});
                    try out.print("      the map           over the camera's view after the load, the one she saved in\n", .{});
                    try out.print("      fault             the load's metatile table not the record's: exit {d}\n", .{fc});
                }
            }
        }

        // ---- 1.0 Step 18a: every door script, on both machines ----
        //
        // Each decodable script as a warp entry (`warp.doorEntries`): a walked
        // door behind the loader of the room it leaves, an unwalked one alone
        // into its own `WARP` cell. The entries go twenty to a case cart, the
        // debug cart with its WARP page given over to them, and are graded as
        // the WARP page's are, map included. The fault: `LoadMetaBase` reading
        // every table from table 0's base, which leaves the loaded state and
        // the characters right and must be caught on the map (26).
        const de = try warp.doorEntries(arena, bytes, walked);
        const dn = warp_grade.doorShards(de.entries.len);
        const drefs = try warp_grade.references(arena, bytes, de.entries, dn, false);
        const djobs = try arena.alloc(ScenarioJob, dn + 1);
        for (0..dn) |k| {
            const lo, const hi = warp_grade.shardRangeOf(de.entries.len, k, dn);
            const cart = try warp_grade.doorCart(arena, bytes, set, boot, de.entries[lo..hi]);
            var lua: std.Io.Writer.Allocating = .init(arena);
            try warp_grade.writeLua(arena, bytes, de.entries[lo..hi], drefs[lo..hi], 0, 1, &lua.writer);
            djobs[k] = .{ .name = "doors", .rom = cart.bytes, .lua = lua.written() };
        }
        // The fault on the run whose first table other than 0 comes soonest.
        const fk = blk: {
            var best: usize = 0;
            var best_at: usize = std.math.maxInt(usize);
            for (0..dn) |k| {
                const lo, const hi = warp_grade.shardRangeOf(de.entries.len, k, dn);
                for (de.entries[lo..hi], 0..) |e, i| if (e.tileset.tiletable != 0) {
                    if (i < best_at) {
                        best_at = i;
                        best = k;
                    }
                    break;
                };
            }
            break :blk best;
        };
        const faulted_doors = try arena.dupe(u8, djobs[fk].rom);
        try warp_grade.metaBaseFault(faulted_doors);
        djobs[dn] = .{ .name = "doors fault", .rom = faulted_doors, .lua = djobs[fk].lua };
        const dgot = try arena.alloc(?ScenarioGot, dn + 1);
        try scenarioRuns(arena, init.io, djobs, dgot);
        if (dgot[0] == null) {
            try out.print("ok    doors             not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else {
            var all = true;
            var stood: usize = 0;
            for (dgot[0..dn], 0..) |g, k| {
                if (g.?.code == 0) continue;
                all = false;
                failures += 1;
                const lo, const hi = warp_grade.shardRangeOf(de.entries.len, k, dn);
                try out.print("FAIL  doors             entries {d}-{d}: exit {d} ({s})\n", .{ lo, hi - 1, g.?.code, warp_grade.code(g.?.code) });
                if (g.?.line.len > 0) try out.print("      {s}\n", .{g.?.line});
            }
            for (de.entries) |e| stood += @intFromBool(e.stand);
            if (dgot[dn].?.code != 26) {
                all = false;
                failures += 1;
                try out.print("FAIL  doors fault       LoadMetaBase reading table 0's base: exit {d} ({s}), wanted 26\n", .{ dgot[dn].?.code, warp_grade.code(dgot[dn].?.code) });
            }
            if (all) {
                try out.print("ok    doors             {d} door scripts run on the cart through the WARP page's input, each as our Game Boy leaves it\n", .{de.entries.len});
                try out.print("      the entries       a walked door behind the loader of the room it leaves; an unwalked one alone into its WARP cell\n", .{});
                try out.print("      graded            as the warp rung: the loaded state, the damage, the characters and the map over the view\n", .{});
                try out.print("      standing          {d} of {d} stood where the walk comes in; the rest have no spot, and their loaded state alone is graded\n", .{ stood, de.entries.len });
                try out.print("      not run           {d} undecodable, {d} the Queen's, {d} with no walk and no WARP, {d} with no chain that leaves what the walk left\n", .{ de.undecodable, de.queen, de.nowhere, de.unchained.len });
                try out.print("      fault             LoadMetaBase reading table 0's base: caught on the map, run {d}\n", .{fk});
            }
        }

        // ---- 1.0 Step 18d: the counts the doors test ----
        //
        // The `doors` entries again at each count a chain tests where the two
        // sides of it leave another tileset or send her elsewhere
        // (`warp.countedEntries`): every lava door's levels, and both sides of
        // all thirteen thresholds ($00 since 1.0 Step 20d). Each case cart's run kills
        // METROIDS' rows in order to reach each count, highest first, and is
        // graded as the doors are against our Game Boy run at the count. The
        // fault: `IF_MET_LESS`'s branch inverted.
        const ce = try warp.countedEntries(arena, bytes, de.entries);
        const cn = warp_grade.doorShards(ce.len);
        const crefs = try warp_grade.references(arena, bytes, ce, cn, true);
        const cjobs = try arena.alloc(ScenarioJob, cn + 1);
        for (0..cn) |k| {
            const lo, const hi = warp_grade.shardRangeOf(ce.len, k, cn);
            const cart = try warp_grade.doorCart(arena, bytes, set, boot, ce[lo..hi]);
            var lua: std.Io.Writer.Allocating = .init(arena);
            try warp_grade.writeLua(arena, bytes, ce[lo..hi], crefs[lo..hi], 0, 1, &lua.writer);
            cjobs[k] = .{ .name = "counts", .rom = cart.bytes, .lua = lua.written() };
        }
        const faulted_counts = try arena.dupe(u8, cjobs[0].rom);
        try warp_grade.metLessFault(faulted_counts);
        cjobs[cn] = .{ .name = "counts fault", .rom = faulted_counts, .lua = cjobs[0].lua };
        const cgot = try arena.alloc(?ScenarioGot, cn + 1);
        try scenarioRuns(arena, init.io, cjobs, cgot);
        if (cgot[0] == null) {
            try out.print("ok    counts            not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else {
            var all = true;
            for (cgot[0..cn], 0..) |g, k| {
                if (g.?.code == 0) continue;
                all = false;
                failures += 1;
                const lo, const hi = warp_grade.shardRangeOf(ce.len, k, cn);
                try out.print("FAIL  counts            entries {d}-{d}: exit {d} ({s})\n", .{ lo, hi - 1, g.?.code, warp_grade.code(g.?.code) });
                if (g.?.line.len > 0) try out.print("      {s}\n", .{g.?.line});
            }
            const fc = cgot[cn].?.code;
            if (fc != 20 and fc != 21 and fc != 26) {
                all = false;
                failures += 1;
                try out.print("FAIL  counts fault      IF_MET_LESS's branch inverted: exit {d} ({s}), wanted 20, 21 or 26\n", .{ fc, warp_grade.code(fc) });
            }
            if (all) {
                var lava: usize = 0;
                for (ce) |e| lava += @intFromBool(warp.isLavaTable(e.tileset.tiletable));
                try out.print("ok    counts            {d} door entries at the counts their scripts test, each as our Game Boy leaves it at that count\n", .{ce.len});
                try out.print("      the count         reached by killing METROIDS' rows in order through the menu's own input, highest first\n", .{});
                try out.print("      thresholds        both sides of each; $00's, door $19E's, run EXIT_QUEEN through $19F and ESCAPE_QUEEN\n", .{});
                try out.print("      lava              {d} arrivals in a lava table, at each level a door draws\n", .{lava});
                try out.print("      fault             IF_MET_LESS's branch inverted: exit {d}\n", .{fc});
            }
        }

        // ---- 1.0 Step 19b: the Queen's fight on her own; 19c, hurt ----
        //
        // `queen_oracle`: the debug cart warped to her room through the menu,
        // and every byte of her page, her thirteen slots and Samus's position,
        // pose and health held history for history to our Game Boy's, entered
        // by door $19D, until just before Samus dies: once on her own, and
        // once with Samus firing missiles into her head and open mouth, the
        // pad keyed to vblanks on both. The volley also compares the play
        // window and her BGP bands on the frames her flash shows. Each fault
        // takes a routine of hers out, and the fight must part.
        {
            const qc = queen_oracle.cases;
            var gbs: [qc.len]queen_oracle.GbFight = undefined;
            var njobs: usize = 0;
            for (qc, &gbs) |c, *g| {
                g.* = try queen_oracle.runGbCase(arena, bytes, c);
                njobs += 1 + c.faults.len;
            }
            const qjobs = try arena.alloc(ScenarioJob, njobs);
            const qwant = try arena.alloc(u8, njobs);
            var qplaced = true;
            var j: usize = 0;
            for (qc, gbs) |c, g| {
                var lua: std.Io.Writer.Allocating = .init(arena);
                try queen_oracle.writeLua(arena, bytes, sorted, g, c, &lua.writer);
                qjobs[j] = .{ .name = c.name, .rom = debug_rom.bytes, .lua = lua.written(), .frames = c.screens.len > 0 };
                qwant[j] = 0;
                const base = j;
                j += 1;
                for (c.faults) |f| {
                    const fb = try arena.dupe(u8, debug_rom.bytes);
                    if (snes_inject.symbolOffset(f.label)) |o| {
                        if (fb[o] == 0x60) qplaced = false;
                        fb[o] = 0x60;
                    } else qplaced = false;
                    qjobs[j] = .{ .name = f.label, .rom = fb, .lua = qjobs[base].lua, .frames = qjobs[base].frames };
                    qwant[j] = f.code;
                    j += 1;
                }
            }
            const qgot = try arena.alloc(?ScenarioGot, njobs);
            @memset(qgot, null);
            try scenarioRuns(arena, init.io, qjobs, qgot);
            if (qgot[0] == null) {
                try out.print("ok    queen             not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
            } else {
                var all = true;
                j = 0;
                for (qc) |c| {
                    if (qgot[j].?.code != 0) {
                        all = false;
                        failures += 1;
                        try out.print("FAIL  queen             {s}: exit {d}\n", .{ c.name, qgot[j].?.code });
                        if (qgot[j].?.line.len > 0) try out.print("      {s}\n", .{qgot[j].?.line});
                    }
                    j += 1;
                    for (c.faults) |f| {
                        defer j += 1;
                        if (qplaced and qgot[j].?.code == qwant[j]) continue;
                        all = false;
                        failures += 1;
                        try out.print("FAIL  queen fault       {s} ({s}) taken out of {s}: exit {d}, wanted {d}{s}\n", .{ f.label, f.what, c.name, qgot[j].?.code, qwant[j], if (qplaced) "" else "; a patch was not placed" });
                    }
                }
                if (all) {
                    var nf: usize = 0;
                    for (qc) |c| nf += c.faults.len;
                    try out.print("ok    queen             her fight on her own, {d} frames, history for history our Game Boy's\n", .{gbs[0].death - queen_oracle.before_death - queen_oracle.slack});
                    try out.print("      volley            missiles into her head and open mouth, {d} frames: her hurt, stun and flash, the play window on {d} frames and her BGP bands on {d}\n", .{ gbs[1].death - queen_oracle.before_death - queen_oracle.slack, qc[1].screens.len, qc[1].bands.len });
                    try out.print("      mouth             FULL LOADOUT, her mouth stunned, rolled into and bombed out of, {d} frames; our Game Boy lags on {d} of them, and the values its vblank never built there are pinned ({d})\n", .{ queen_oracle.windowOf(qc[2], gbs[2]), queen_oracle.lagIn(qc[2], gbs[2]), qc[2].unbuilt });
                    try out.print("      stomach           swallowed, bombed in her stomach and thrown up her bent neck, {d} frames; {d} lagging, {d} values pinned\n", .{ queen_oracle.windowOf(qc[3], gbs[3]), queen_oracle.lagIn(qc[3], gbs[3]), qc[3].unbuilt });
                    try out.print("      mouth_kill        a missile every 8 frames to under ten health, then bombed out of her mouth dying ($20) and killed from her stomach, {d} frames; {d} lagging, {d} values pinned; her death {d} frames, our Game Boy's\n", .{ queen_oracle.windowOf(qc[4], gbs[4]), queen_oracle.lagIn(qc[4], gbs[4]), qc[4].unbuilt, queen_oracle.deathLen(gbs[4]) });
                    try out.print("      kill              missiles to her death, {d} frames: her characters ANDed away on {d} frames of the play window, her body's cells and the floor's in VRAM, her death {d} frames, our Game Boy's\n", .{ queen_oracle.windowOf(qc[5], gbs[5]), qc[5].screens.len, queen_oracle.deathLen(gbs[5]) });
                    try out.print("      exit              the kill, then over her body and left out through $19F's EXIT_QUEEN into $F:$A9, {d} frames: her room flag cleared, the baby's song when the quake ends; the door's screen on {d} frames, her bands off and dark under its loads\n", .{ queen_oracle.windowOf(qc[6], gbs[6]), qc[6].screens.len });
                    try out.print("      escape            alive, the ball down her shaft and out through ESCAPE_QUEEN into $E:$C1, {d} frames: Samus and the camera placed; the door's screen on {d} frames, her bands off and dark under its loads\n", .{ queen_oracle.windowOf(qc[7], gbs[7]), qc[7].screens.len });
                    try out.print("      what              her $C300 page, her thirteen slots, Samus's position, pose and health, eating state, shot, the Metroid counts, shuffle and quake, her missile, her room flag, the bank, the camera and songPlaying: {d} bytes\n", .{queen_oracle.var_count});
                    try out.print("      handed across     the mouth's rDIV toss and frameCounter's phase at her entry; the kills' presses kept off the frame after our Game Boy lags\n", .{});
                    try out.print("      fault sweep       {d}/{d} taken out part from it\n", .{ nf, nf });
                }
            }
        }
    } else {
        try out.print("skip  warp              needs the ROM\n", .{});
    }

    // ---- With a ROM and an emulator: does a pickup swap the GB's tiles? ----
    //
    // 1.0 Step 8a. `loadGraphics` and the pickups that call it: each case is a
    // new game on the `--debug` cart, given its first items through the menu
    // and then the pickup by the orb's lever, held against our Game Boy taking
    // the same pickup (`gfx_grade.references`): the object characters the
    // records land in, the frames the transfer takes, the bit and the weapon.
    // One Mesen2 run a case, in parallel. The fault: the ice beam's arm handed
    // the wave beam's row, which the `ice` case must see in the characters.
    if (rom_bytes) |bytes| {
        var set = try snes_convert.run(arena, bytes);
        defer set.deinit();
        const boot = try snes_screen.newGameBoot(arena, bytes);
        var diag: snes_inject.Diagnosis = .{};
        var debug_rom = try snes_inject.build(arena, set, boot, &diag);
        defer debug_rom.deinit();
        try snes_inject.enableDebug(&debug_rom);

        const refs = try gfx_grade.references(arena, bytes);
        const cs = gfx_grade.cases;
        const fs = gfx_grade.faults;
        var jobs: [cs.len + fs.len]ScenarioJob = undefined;
        for (cs, refs, 0..) |c, r, i| {
            var lua: std.Io.Writer.Allocating = .init(arena);
            try gfx_grade.writeLua(bytes, c, r, &lua.writer);
            jobs[i] = .{ .name = c.name, .rom = debug_rom.bytes, .lua = lua.written() };
        }
        var placed = true;
        for (fs, cs.len..) |f, i| {
            const ci = for (cs, 0..) |c, k| {
                if (std.mem.eql(u8, c.name, f.case)) break k;
            } else unreachable;
            const at = (snes_inject.symbolOffset(f.label) orelse {
                placed = false;
                try out.print("FAIL  gfx fault         {s} is not in the engine image\n", .{f.label});
                failures += 1;
                jobs[i] = .{ .name = f.label, .rom = debug_rom.bytes, .lua = "" };
                continue;
            }) + f.offset;
            if (std.mem.eql(u8, debug_rom.bytes[at..][0..f.patch.len], f.patch)) {
                placed = false;
                try out.print("FAIL  gfx fault         {s} already holds the patch: the cart is not faulted\n", .{f.label});
                failures += 1;
            }
            const fb = try arena.dupe(u8, debug_rom.bytes);
            @memcpy(fb[at..][0..f.patch.len], f.patch);
            jobs[i] = .{ .name = f.label, .rom = fb, .lua = jobs[ci].lua };
        }
        var got: [jobs.len]?ScenarioGot = @splat(null);
        try scenarioRuns(arena, init.io, &jobs, &got);
        if (got[0] == null) {
            try out.print("ok    gfx               not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else {
            var all = placed;
            var total: usize = 0;
            for (cs, refs, got[0..cs.len]) |c, r, g| {
                if (c.frames) total += r.xfer_frames;
                if (g.?.code == 0) continue;
                all = false;
                failures += 1;
                try out.print("FAIL  gfx               {s}: exit {d} ({s})\n", .{ c.name, g.?.code, gfx_grade.code(g.?.code) });
                if (g.?.line.len > 0) try out.print("      {s}\n", .{g.?.line});
            }
            for (fs, got[cs.len..]) |f, g| {
                const c = if (g) |x| x.code else continue;
                if (c == f.want) continue;
                all = false;
                failures += 1;
                try out.print("FAIL  gfx fault         {s} taken out: exit {d} ({s}), wanted {d}\n", .{ f.label, c, gfx_grade.code(c), f.want });
            }
            if (all) {
                try out.print("ok    gfx               {d} pickups, each leaving our Game Boy's object characters, transfer frames, bit and weapon\n", .{cs.len});
                try out.print("      the reference     our Game Boy taking the same pickup from `itemCollected`, the orb's lever\n", .{});
                try out.print("      the records       the four beams, the screw attack and space jump each way, spring ball, Varia\n", .{});
                try out.print("      the frames        {d} of transfer across the cases, a chunk a vblank or Varia's animation\n", .{total});
                for (fs) |f| try out.print("      fault             {s}\n", .{f.what});
            }
        }
    } else {
        try out.print("skip  gfx               needs the ROM\n", .{});
    }

    // ---- With a ROM and an emulator: does Samus die as the original does? ---
    //
    // Step 15c. The shipped cart, played from its title to a death twice: zero
    // displayed health, the erase over the object characters, the GAME OVER
    // screen, and back to the title -- once on the timer and once on Start --
    // with every mode's length the Game Boy's (`src/death.zig` measures and
    // pins them) and cartridge RAM kept across the reboot. Then the grader is
    // shown to grade: the same run expecting mode $05 three frames longer fails.
    if (rom_bytes) |bytes| {
        var set = try snes_convert.run(arena, bytes);
        defer set.deinit();
        const boot = try snes_screen.newGameBoot(arena, bytes);
        var diag: snes_inject.Diagnosis = .{};
        var rom = try snes_inject.build(arena, set, boot, &diag);
        defer rom.deinit();

        const Run = struct { run: snes_romtest.DeathRun, want: u8 };
        const runs = [_]Run{ .{ .run = .grade, .want = 0 }, .{ .run = .length_fault, .want = 185 } };
        var got: [runs.len]?u8 = @splat(null);
        for (runs, 0..) |r, i| {
            var lua: std.Io.Writer.Allocating = .init(arena);
            defer lua.deinit();
            try snes_romtest.writeDeathBoot(arena, bytes, boot, r.run, &lua.writer);
            got[i] = try loadBootTest(init.io, rom.bytes, lua.written());
            if (got[i] == null) break;
        }
        if (got[0] == null) {
            try out.print("ok    death             not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else {
            var all = true;
            for (runs, got) |r, g| {
                if (g != r.want) {
                    all = false;
                    failures += 1;
                    try out.print("FAIL  death             {s}: exit {d}, wanted {d} ({s})\n", .{ @tagName(r.run), g.?, r.want, deathCode(g.?) });
                }
            }
            if (all) {
                const t = death.on_timer;
                try out.print("ok    death             zero displayed health kills her, and the cart reboots to the title\n", .{});
                try out.print("      the lengths       $06 {d}, $05 {d} ({d} blank), $07 {d} on the timer and {d} on Start: the Game Boy's, within 2%\n", .{
                    t.dyingLen(), t.deadLen(), t.blankLen(), t.gameOverLen(), death.on_start.gameOverLen(),
                });
                try out.print("      the erase         each of 32 steps zeroes its stride of the object characters\n", .{});
                try out.print("      GAME OVER         the title's characters, the cleared map, the text, and the window off\n", .{});
                try out.print("      the reboot        cartridge RAM kept; a Start held through it is not a press\n", .{});
                try out.print("      fault sweep       expecting mode $05 three frames longer fails it (185)\n", .{});
            }
        }
    } else {
        try out.print("skip  death             needs the ROM\n", .{});
    }

    // ---- With a ROM and an emulator: does the round trip close? ------------
    //
    // Step 15d, and the first rung whose expectation the *cart* wrote. Every
    // rung above hands it a record the gate invented: the load rung boots it on
    // James's first save, the cold boot on the ROM's own new-game record. This
    // one plays the shipped cart from its title, puts one unit of energy and a
    // post-kill Metroid count on her, stands her on a station laid from the
    // loaded collision table, saves, captures the bytes the writer left in
    // cartridge RAM, kills her, and grades what comes back after the reboot and
    // the load against those bytes. Then the grader is shown to grade: the same
    // run with the slot's energy byte changed after the capture must fail.
    if (rom_bytes) |bytes| {
        var set = try snes_convert.run(arena, bytes);
        defer set.deinit();
        const boot = try snes_screen.newGameBoot(arena, bytes);
        var diag: snes_inject.Diagnosis = .{};
        var rom = try snes_inject.build(arena, set, boot, &diag);
        defer rom.deinit();

        const Run = struct { run: snes_romtest.RoundTrip, want: u8 };
        const runs = [_]Run{ .{ .run = .grade, .want = 0 }, .{ .run = .energy_fault, .want = 207 }, .{ .run = .slot2, .want = 0 } };
        var got: [runs.len]?u8 = @splat(null);
        for (runs, 0..) |r, i| {
            var lua: std.Io.Writer.Allocating = .init(arena);
            defer lua.deinit();
            try snes_romtest.writeRoundTrip(arena, bytes, rom, boot, r.run, &lua.writer);
            got[i] = try loadBootTest(init.io, rom.bytes, lua.written());
            if (got[i] == null) break;
        }
        if (got[0] == null) {
            try out.print("ok    round trip        not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else {
            var all = true;
            for (runs, got) |r, g| {
                if (g != r.want) {
                    all = false;
                    failures += 1;
                    try out.print("FAIL  round trip        {s}: exit {d}, wanted {d} ({s})\n", .{ @tagName(r.run), g.?, r.want, roundTripCode(g.?) });
                }
            }
            if (all) {
                try out.print("ok    round trip        the cart saves, dies, and loads back the record it wrote\n", .{});
                try out.print("      the record        captured from cartridge RAM after the writer ran, not invented here\n", .{});
                try out.print("      the energy        one unit saved, none at death, one unit back\n", .{});
                try out.print("      the count         metroidCountReal is the saved $46, not a new game's $47\n", .{});
                try out.print("      the state         room, position, camera, tanks, missiles, items, beam and facing\n", .{});
                try out.print("      slot 2            chosen with Left; the record and spawn flags at slot 2's offsets only, saveLastSlot 2, and back\n", .{});
                try out.print("      fault sweep       the slot's energy byte changed after the capture fails it (207)\n", .{});
            }
        }
    } else {
        try out.print("skip  round trip        needs the ROM\n", .{});
    }

    // ---- With a ROM and an emulator: does the cart move like the original? -
    //
    // Everything above executes the cart against expectations we wrote. This
    // executes it against the *original*, frame for frame, on a hand-authored
    // segment. The fault sweep is the reason to believe it: a comparator that
    // never fails and one that cannot fail look the same from here.
    if (rom_bytes) |bytes| {
        var rep = try oracle.grade(arena, init.io, bytes, build_options.mesen_path, 8, true, .exact);
        if (rep.no_emulator) {
            try out.print("ok    oracle            not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else if (!rep.world.same()) {
            // Reported before the verdict, and instead of it. A position
            // comparison over two different rooms is not a comparison, and
            // calling it a physics failure would send the next person to the
            // wrong file. See `oracle.World`.
            failures += 1;
            try out.print("FAIL  oracle            the reference and the cart are not standing in the same room\n", .{});
            try out.print("      map {d} cell ${X:0>2}       the cart's world is metatile table {d}; {d} of {d} tiles agree\n", .{
                rep.boot.map_index, rep.boot.cell, rep.world.cart_table, rep.world.matched, rep.world.compared,
            });
            try out.print("      the original      best explained by table {d}, at {d} of the same tiles\n", .{
                rep.world.gb_best_table, rep.world.gb_best_matched,
            });
        } else if (rep.matched()) {
            try out.print("ok    oracle            {d} frames of the original, frame for frame, on map {d} cell ${X:0>2}\n", .{
                oracle.segment_frames, rep.boot.map_index, rep.boot.cell,
            });
            try out.print("      compared          position, camera and pose; the last 324 frames are the ball\n", .{});
            try out.print("      fault sweep       {d}/{d} injected one-pixel faults named the right frame\n", .{
                rep.faults_caught, rep.faults,
            });
            try out.print("      pose sweep        {d}/{d} injected pose faults named the right frame\n", .{
                rep.pose_faults_caught, rep.pose_faults,
            });
        } else if (rep.divergence()) |d| {
            failures += 1;
            if (d.exact()) {
                try out.print("FAIL  oracle            {s}, at frame {d} of {d}\n", .{
                    oracle.explain(rep.code), d.first, oracle.segment_frames,
                });
            } else {
                try out.print("FAIL  oracle            {s}, at frame {d}-{d} of {d}\n", .{
                    oracle.explain(rep.code), d.first, d.last, oracle.segment_frames,
                });
            }
            const f = @min(d.first, rep.settled.frames.len - 1);
            const g = rep.settled.frames[f];
            var kb: [oracle.mesen_keys_max]u8 = undefined;
            try out.print("      the original      at frame {d}: {X:0>4},{X:0>4} camera {X:0>4},{X:0>4} pose ${X:0>2}, input {s}\n", .{
                f, g.samus_x, g.samus_y, g.camera_x, g.camera_y, g.pose, oracle.keyName(oracle.keyAt(f), &kb),
            });
            try out.print("      fault sweep       {d}/{d} injected one-pixel faults named the right frame\n", .{
                rep.faults_caught, rep.faults,
            });
            try out.print("      pose sweep        {d}/{d} injected pose faults named the right frame\n", .{
                rep.pose_faults_caught, rep.pose_faults,
            });
        } else if (oracle.unhandledPose(rep.code)) |u| {
            failures += 1;
            try out.print("FAIL  oracle            {s}: pose ${X:0>2}{s}\n", .{
                oracle.explain(rep.code), u.pose, if (u.saturated) " or higher" else "",
            });
        } else {
            failures += 1;
            try out.print("FAIL  oracle            {s} (exit {d})\n", .{ oracle.explain(rep.code), rep.code });
        }
    }

    // ---- The spider segment, Step 14b ---------------------------------------
    //
    // The same comparison over `oracle.spider_segment`, with Spider Ball held on
    // both machines: round a ledge, down its face, off it into `$0C` and back
    // onto it. It is the grader for the spider's contact probes and direction
    // tables, which `snes boot` phase 25 cannot reach -- dropping the corner
    // rotation in `SpiderContacts` passes phase 25 and fails here at the ledge.
    // No fault sweep: the segment rung above already shows the comparator can
    // fail, and this one is the same script.
    if (rom_bytes) |bytes| blk: {
        const items_mod = @import("items.zig");
        const bit = (items_mod.bitFor(bytes, .spider_ball) catch null) orelse {
            failures += 1;
            try out.print("FAIL  spider segment    the ROM's Spider Ball arm sets no bit\n", .{});
            break :blk;
        };
        var rep = try oracle.gradeWith(arena, init.io, bytes, build_options.mesen_path, 8, false, .exact, &oracle.spider_segment, .{ .items = @as(u8, 1) << bit });
        const n = rep.settled.frames.len;
        if (rep.no_emulator) {
            try out.print("ok    spider segment    not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else if (rep.matched()) {
            var poses: [256]bool = @splat(false);
            for (rep.settled.frames) |f| poses[f.pose] = true;
            try out.print("ok    spider segment    {d} frames of the original with Spider Ball held, frame for frame\n", .{n});
            try out.print("      poses             $0B {s}, $0C {s}, $0E {s}: round a ledge, down its face, off it and back on\n", .{
                if (poses[0x0B]) "yes" else "NO", if (poses[0x0C]) "yes" else "NO", if (poses[0x0E]) "yes" else "NO",
            });
            if (!(poses[0x0B] and poses[0x0C] and poses[0x0E])) {
                failures += 1;
                try out.print("FAIL  spider segment    the reference no longer reaches every pose it was written to\n", .{});
            }
        } else if (rep.divergence()) |d| {
            failures += 1;
            try out.print("FAIL  spider segment    {s}, at frame {d}-{d} of {d}\n", .{ oracle.explain(rep.code), d.first, d.last, n });
        } else {
            failures += 1;
            try out.print("FAIL  spider segment    {s} (exit {d})\n", .{ oracle.explain(rep.code), rep.code });
        }
    }

    // ---- The loadout segments, 1.0 Step 7 ------------------------------------
    //
    // C5's items, each on the segment's start: Hi-Jump, Space Jump and Spring
    // Ball, set on the `--debug` cart through the debug menu's own input and
    // OR'd in on the Game Boy at the same point, then a schedule through the
    // item's branches compared frame for frame. Each has its fault, the item's
    // test blanked in the engine, which must differ: that is also what shows
    // the schedule still reaches the branch, since a reference that stopped
    // reaching it would pass the faulted cart too.
    if (rom_bytes) |bytes| {
        const items_mod = @import("items.zig");
        for (oracle.loadout_segments) |seg| {
            const bit = (items_mod.bitFor(bytes, seg.item) catch null) orelse {
                failures += 1;
                try out.print("FAIL  loadout           {s}: the ROM's pickup arm sets no bit\n", .{seg.name});
                continue;
            };
            const lo: oracle.Loadout = .{ .items = @as(u8, 1) << bit, .via = .menu };
            const rep = try oracle.gradeWith(arena, init.io, bytes, build_options.mesen_path, 8, false, .exact, seg.phases, lo);
            const n = rep.settled.frames.len;
            if (rep.no_emulator) {
                try out.print("ok    loadout           {s}: not run: no emulator (set MESEN, see docs/setup.md)\n", .{seg.name});
                continue;
            }
            if (!rep.matched()) {
                failures += 1;
                if (rep.divergence()) |d| {
                    try out.print("FAIL  loadout           {s}: {s}, at frame {d}-{d} of {d}\n", .{ seg.name, oracle.explain(rep.code), d.first, d.last, n });
                } else {
                    try out.print("FAIL  loadout           {s}: {s} (exit {d})\n", .{ seg.name, oracle.explain(rep.code), rep.code });
                }
                continue;
            }
            var faulted = lo;
            faulted.patch = seg.fault;
            const frep = oracle.gradeWith(arena, init.io, bytes, build_options.mesen_path, 8, false, .bucket, seg.phases, faulted) catch |e| switch (e) {
                error.MissingSymbol, error.PatchNoOp => {
                    failures += 1;
                    try out.print("FAIL  loadout           {s}: fault {s}+{d} is not in the engine image, or already holds its patch\n", .{ seg.name, seg.fault.label, seg.fault.offset });
                    continue;
                },
                else => return e,
            };
            if (frep.divergence()) |d| {
                try out.print("ok    loadout           {s}: {d} frames through the debug menu, frame for frame; {s} blanked differs at {d}\n", .{ seg.name, n, seg.fault.label, d.first });
            } else {
                failures += 1;
                try out.print("FAIL  loadout           {s}: {s} blanked and the segment does not differ (exit {d}: {s})\n", .{ seg.name, seg.fault.label, frep.code, oracle.explain(frep.code) });
            }
        }
    }

    // ---- The beams, 1.0 Step 8c ----------------------------------------------
    //
    // C5's beams in flight: each set on the `--debug` cart through the debug
    // menu's beam row and written on the Game Boy at the same point, fired
    // into the room's wall, up and away, and the projectile array compared
    // frame for frame beside Samus. The plasma is fired at a seeded enemy too:
    // a kill it outlives and one it does not, and a missile door it cannot
    // hurt. Every fault must differ.
    if (rom_bytes) |bytes| {
        for (oracle.beam_segments) |seg| {
            const rep = try oracle.gradeBeam(arena, init.io, bytes, build_options.mesen_path, .exact, seg, null);
            const n = rep.settled.frames.len;
            if (rep.no_emulator) {
                try out.print("ok    beams             {s}: not run: no emulator (set MESEN, see docs/setup.md)\n", .{seg.name});
                continue;
            }
            if (!rep.matched()) {
                failures += 1;
                if (rep.divergence()) |d| {
                    try out.print("FAIL  beams             {s}: {s}, at frame {d}-{d} of {d}\n", .{ seg.name, oracle.explain(rep.code), d.first, d.last, n });
                } else {
                    try out.print("FAIL  beams             {s}: {s} (exit {d})\n", .{ seg.name, oracle.explain(rep.code), rep.code });
                }
                continue;
            }
            var caught: usize = 0;
            for (seg.faults) |f| {
                const frep = oracle.gradeBeam(arena, init.io, bytes, build_options.mesen_path, .bucket, seg, f) catch |e| switch (e) {
                    error.MissingSymbol, error.PatchNoOp => {
                        failures += 1;
                        try out.print("FAIL  beams             {s}: fault {s}+{d} is not in the engine image, or already holds its patch\n", .{ seg.name, f.label, f.offset });
                        continue;
                    },
                    else => return e,
                };
                if (frep.divergence() != null) {
                    caught += 1;
                } else {
                    failures += 1;
                    try out.print("FAIL  beams             {s}: fault {s}+{d} and the segment does not differ (exit {d}: {s})\n", .{ seg.name, f.label, f.offset, frep.code, oracle.explain(frep.code) });
                }
            }
            if (caught == seg.faults.len) {
                try out.print("ok    beams             {s}: {d} frames, Samus and the projectiles; {d}/{d} faults differ\n", .{ seg.name, n, caught, seg.faults.len });
            }
        }
    }

    // ---- With a ROM, an emulator and the movie: how far does the port get? -
    //
    // F10's progress metric, and the rung it never had. The `tas horizon` rung
    // above measures a different machine: how long *our Game Boy replay* stays
    // faithful to the published movie, which the port cannot affect. This
    // measures how far the *port* survives against that reference. On
    // 2026-09-01 they read 8407 and 372 and neither constrains the other, which
    // is how a checked-off plan sub-task claimed for weeks that the horizon rung
    // was this one.
    //
    // The floor is meant to go up. When it does, raise `movie_gate_floor` --
    // the point of the rung is that a change which *shortens* the run cannot
    // pass, and that a longer one is a deliberate edit rather than a drift.
    //
    // Only the any% run is graded. The 100% run has its own opening and its own
    // boot cell, so it is a second reference rather than a second data point,
    // and one gate that is understood beats two that are half-checked.
    if (rom_bytes) |bytes| blk: {
        if (bytes.len != rom_mod.expected_size) break :blk;
        const movie_bytes = std.Io.Dir.cwd().readFileAlloc(init.io, tas.any_percent, arena, .limited(8 << 20)) catch {
            try out.print("skip  reachable         no any% movie in vendor/tas -- run tools/get-tas.sh\n", .{});
            break :blk;
        };
        const movie = tas.parse(movie_bytes) catch |err| {
            failures += 1;
            try out.print("FAIL  reachable         {s}: {s}\n", .{ tas.any_percent, @errorName(err) });
            break :blk;
        };
        var rep = try oracle.gradeMovie(
            arena,
            init.io,
            bytes,
            movie,
            build_options.mesen_path,
            oracle.movie_gate_frames,
            .exact,
        );
        if (rep.no_emulator) {
            try out.print("ok    reachable         not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else if (rep.no_boot_for_cell) {
            failures += 1;
            try out.print("FAIL  reachable         the game's own starting cell is not in use; nothing was graded\n", .{});
        } else if (!rep.world.same()) {
            // Same precedence as the segment rung, and for the same reason: a
            // position comparison across two different rooms is not a
            // comparison, so it is reported instead of a frame count rather
            // than as a small one.
            failures += 1;
            try out.print("FAIL  reachable         the reference and the cart are not standing in the same room\n", .{});
            try out.print("      map {d} cell ${X:0>2}       {d} of {d} tiles agree\n", .{
                rep.boot.map_index, rep.boot.cell, rep.world.matched, rep.world.compared,
            });
        } else {
            // `matched()` means the port survived everything it was offered,
            // so the count is the whole take. Otherwise it is the first
            // divergent frame, which this rung pins exactly -- see
            // `oracle.Bisect`. `reachedFrames` computes the same number for the
            // anchored sweep; both go through `Report.divergence` so an exact
            // frame cannot be re-widened into a bucket by one caller.
            const reached = oracle.reachedFrames(rep) orelse 0;
            // An unhandled pose carries the pose in its code and so cannot also
            // carry a frame. Reporting `reached` as 0 would be a lie of the
            // convenient kind -- it would fail the floor and read as a
            // catastrophic regression -- so the count is withheld and the pose
            // is what gets printed.
            if (oracle.unhandledPose(rep.code) != null) {
                failures += 1;
                try out.print(
                    "FAIL  reachable         the run stopped on a pose the port has no handler for; no frame count\n",
                    .{},
                );
            } else if (reached < oracle.movie_gate_floor) {
                failures += 1;
                try out.print(
                    "FAIL  reachable         the port reaches {d} frames of the any% run, under the floor of {d}\n",
                    .{ reached, oracle.movie_gate_floor },
                );
            } else {
                try out.print(
                    "ok    reachable         the port reaches {d} of {d} frames of the any% run (floor {d})\n",
                    .{ reached, rep.offered, oracle.movie_gate_floor },
                );
            }
            // What stopped it, which is what names the next thing to port.
            if (rep.matched()) {
                try out.print("      stopped by        nothing: every frame offered matched\n", .{});
            } else if (oracle.unhandledPose(rep.code)) |u| {
                // Named before the position check, because this is the cause:
                // a pose with no handler leaves Samus standing still and the
                // position divergence it produces a frame later is the symptom
                // the gate used to report instead.
                if (u.saturated) {
                    try out.print("      stopped by        {s}: pose ${X:0>2} or higher (the code saturates)\n", .{
                        oracle.explain(rep.code), u.pose,
                    });
                } else {
                    try out.print("      stopped by        {s}: pose ${X:0>2}\n", .{ oracle.explain(rep.code), u.pose });
                }
            } else if (rep.divergence()) |d| {
                if (d.exact()) {
                    try out.print("      stopped by        {s}, at frame {d} exactly\n", .{
                        oracle.explain(rep.code), d.first,
                    });
                } else {
                    try out.print("      stopped by        {s}, at frame {d}-{d}\n", .{
                        oracle.explain(rep.code), d.first, d.last,
                    });
                }
                const f = @min(d.first, rep.settled.frames.len - 1);
                const g = rep.settled.frames[f];
                // `pad` and not `keyAt`: the latter is the *segment's* input
                // schedule, and this run's inputs come from the movie. `pad` is
                // the byte the original's own joypad routine left at $FF80, so
                // it is what the game acted on rather than what we think we
                // offered it.
                try out.print("      the original      at frame {d}: {X:0>4},{X:0>4} camera {X:0>4},{X:0>4} pose ${X:0>2}, pad ${X:0>2}\n", .{
                    f, g.samus_x, g.samus_y, g.camera_x, g.camera_y, g.pose, g.pad,
                });
            } else {
                try out.print("      stopped by        {s} (exit {d})\n", .{ oracle.explain(rep.code), rep.code });
            }
            // A ceiling on what the number can mean, printed only when it bites.
            if (rep.first_unsupported) |u| {
                try out.print("      note              the movie holds something the port has no key for at frame {d} (bits ${X:0>2})\n", .{
                    u, rep.unsupported_bits,
                });
            }
        }

        // ---- Step 20: the fade door, on brightness ------------------------
        //
        // The track above cannot see the screen go dark: door $1DF's scroll
        // runs on both machines, and only the Game Boy hides it. This grades
        // the cart's INIDISP against `bg_palette` on every frame of the take:
        // since Step 24b that includes a scrolling door's script at $93, which
        // the port used to blank. See `oracle.fadeRows`.
        {
            const fade_rep = try oracle.gradeFade(arena, init.io, bytes, movie, build_options.mesen_path, oracle.movie_gate_frames);
            if (!try oracle.printFade(out, fade_rep)) failures += 1;
        }

        // ---- And the same metric re-anchored, which is a different number --
        //
        // The rung above measures how far the port survives from the game's one
        // handover of control. This measures how much of the published run it
        // can play at all, by grading every handover from its own boot record.
        // Neither bounds the other: a change can lengthen one and shorten the
        // other, which is exactly why both are reported and why the anchored
        // one is printed per stretch as well as in total.
        var an = try oracle.gradeAnchored(
            arena,
            init.io,
            bytes,
            movie,
            build_options.mesen_path,
            oracle.anchor_min_frames,
            oracle.anchored_gate_limit,
            null,
            // The sum is a sum of frames, so every stretch's stop is pinned to
            // one. Measured 2026-09-05: 15.8s against 7.6s for the bucket, on a
            // sweep that already replays 8407 frames of Game Boy and builds
            // thirteen carts. See `anchored_gate_floor` for what it bought.
            .exact,
        );
        defer an.deinit(arena);

        if (build_options.mesen_path.len == 0) {
            try out.print("ok    anchored          not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else if (an.stretches.len == 0) {
            failures += 1;
            try out.print("FAIL  anchored          no handover of control inside the horizon; nothing was graded\n", .{});
        } else {
            const total = an.reached();
            if (total < oracle.anchored_gate_floor) {
                failures += 1;
                try out.print(
                    "FAIL  anchored          the port plays {d} frames across the run's stretches, under the floor of {d}\n",
                    .{ total, oracle.anchored_gate_floor },
                );
            } else {
                try out.print(
                    "ok    anchored          the port plays {d} of {d} frames across {d} of {d} stretches (floor {d})\n",
                    .{ total, an.offered(), an.graded(), an.stretches.len, oracle.anchored_gate_floor },
                );
            }
            // Per stretch, because a total hides which stretch regressed. Only
            // the ones that produced a number and did not match everything:
            // a full-length stretch and an ungradable one are both quiet.
            for (an.stretches, 0..) |st, i| {
                const n = st.reached() orelse continue;
                const r = st.rep orelse continue;
                if (r.matched()) continue;
                try out.print("      stretch {d: >2}        anchor {d: >5}, {d: >5} of {d: >5} frames: {s}\n", .{
                    i, st.anchor.origin, n, r.offered, oracle.explain(r.code),
                });
            }
            var ungradable: usize = 0;
            for (an.stretches) |st| ungradable += @intFromBool(st.reached() == null);
            if (ungradable != 0) {
                try out.print("      not graded        {d} stretch(es) the cart cannot be booted into; see `zig build oracle -- settle`\n", .{ungradable});
            }
            // A separate floor from the frame sum, because the two move
            // independently: B12 made two more stretches gradable and the sum
            // did not change by a frame. See `anchored_gradable_floor`.
            if (an.graded() < oracle.anchored_gradable_floor) {
                failures += 1;
                try out.print(
                    "FAIL  anchored          {d} stretches can be booted into, under the floor of {d}: a room the port\n" ++
                        "                        could be asked about no longer can. Run `zig build oracle -- worlds`\n",
                    .{ an.graded(), oracle.anchored_gradable_floor },
                );
            }
        }

        // ---- And the stretches neither of those rungs may grade ------------
        //
        // Play is graded frame-exactly above. A cutscene, a room transition and
        // a menu are sequences the game runs to a script of its own, and a port
        // four frames late through one is not wrong the way a port that walks
        // into a wall is wrong. `src/duration.zig` grades those on length.
        //
        // Two floors rather than one: how many stretches produce a duration on
        // both machines, and how many of those agree. They move independently --
        // a port that gains a transition it did not have raises the first and
        // may lower the second -- and collapsing them into one number would let
        // a lost comparison hide behind a gained agreement.
        var dur = try duration.measure(
            arena,
            init.io,
            bytes,
            movie,
            build_options.mesen_path,
            init.environ_map.get("HOME") orelse "",
            oracle.anchored_gate_limit,
            std.math.maxInt(usize),
        );
        defer dur.deinit(arena);

        if (dur.rows.len != duration.census_stretches) {
            failures += 1;
            try out.print(
                "FAIL  durations         the census finds {d} non-playable stretches, not the {d} measured\n",
                .{ dur.rows.len, duration.census_stretches },
            );
        } else if (build_options.mesen_path.len == 0) {
            try out.print(
                "ok    durations         {d} stretches on the Game Boy; not compared: no emulator (set MESEN)\n",
                .{dur.rows.len},
            );
        } else if (dur.compared() < duration.gate_compared_floor or
            dur.agreeing() < duration.gate_agreeing_floor)
        {
            failures += 1;
            try out.print(
                "FAIL  durations         {d} stretches compared and {d} agree, under the floors of {d} and {d}\n",
                .{ dur.compared(), dur.agreeing(), duration.gate_compared_floor, duration.gate_agreeing_floor },
            );
        } else {
            try out.print(
                "ok    durations         {d} of {d} stretches compared, {d} inside {d:.0}% (floors {d} and {d})\n",
                .{
                    dur.compared(),                 dur.rows.len,
                    dur.agreeing(),                 duration.tolerance_percent,
                    duration.gate_compared_floor,   duration.gate_agreeing_floor,
                },
            );
        }
        // Per stretch, for the same reason the anchored rung prints per stretch:
        // a total hides which one regressed. Only the ones that were compared
        // and disagreed -- an absent stretch and a room the cart cannot be
        // booted into are both quiet, and `zig build oracle -- durations` is
        // where the whole table lives.
        for (dur.rows) |row| {
            if (row.within() orelse true) continue;
            try out.print("      {s: <8} {d: >6}  the game boy {d} frames, the port {d}\n", .{
                row.gb.kind.label(), row.gb.start, row.gb.frames,
                switch (row.port) {
                    .frames => |n| n,
                    else => 0,
                },
            });
        }
    }

    // ---- The enemy AIs, against the Game Boy running them ------------------
    //
    // Step 12f. Every rung above compares Samus; this one compares an enemy.
    // Each ported AI is handed the same slot on both machines in a room it
    // lives in, and its history per pass has to agree -- and a cart with that
    // AI's `AiTable` row blanked has to *disagree*, on every run, or the case
    // grades nothing. See `src/enemy_oracle.zig`.
    if (rom_bytes) |bytes| {
        const eo = @import("enemy_oracle.zig");
        var eset = try @import("snes_convert.zig").run(arena, bytes);
        defer eset.deinit();
        var bad: usize = 0;
        var reps: [eo.cases.len]eo.CaseReport = undefined;
        // 1.0 Step 12: `enemy_width` cases in flight at once, their cart runs
        // started together -- see `eo.Started`.
        try eo.gradeCases(arena, init.io, bytes, eset, &eo.cases, enemy_width, build_options.mesen_path, init.environ_map.get("HOME") orelse "", &reps);
        for (reps) |r| bad += @intFromBool(!r.ok());
        defer for (&reps) |*r| r.deinit(arena);
        if (bad != 0) {
            failures += 1;
            try out.print("FAIL  enemy AIs         {d} of {d} room(s) do not play the way the Game Boy's do\n", .{ bad, eo.cases.len });
        } else {
            try out.print("ok    enemy AIs         {d} room(s) agree with the Game Boy pass for pass, and each faulted cart does not\n", .{eo.cases.len});
        }
        for (reps) |r| try eo.printCase(out, r, "      ");

        // ---- The record that leaves the screen and comes back --------------
        //
        // Step 19. The rung above hands both machines a slot and never takes it
        // away; this one drives the camera off the enemy and back, on both
        // machines to the same schedule, and grades whether the *record* is live
        // again and under which spawn flag -- the despawn window, the delete,
        // the reactivate and the walk that reloads it. Two Metroids, whose spawn
        // numbers are in the saved half of the flag array and so survive a room
        // load, and one ordinary enemy as the control; three of the six fire the
        // room reset a transition asks for while the record is off the screen.
        // Each case must lose the record and get it back, or it grades nothing,
        // and each faulted cart must still disagree.
        var reload_bad: usize = 0;
        var reload_reps: [eo.reload_cases.len]eo.CaseReport = undefined;
        try eo.gradeCases(arena, init.io, bytes, eset, &eo.reload_cases, enemy_width, build_options.mesen_path, init.environ_map.get("HOME") orelse "", &reload_reps);
        for (reload_reps) |r| reload_bad += @intFromBool(!r.ok());
        defer for (&reload_reps) |*r| r.deinit(arena);
        if (reload_bad != 0) {
            failures += 1;
            try out.print("FAIL  enemy reload      {d} of {d} record(s) do not survive leaving the screen the way the Game Boy's do\n", .{ reload_bad, eo.reload_cases.len });
        } else {
            try out.print("ok    enemy reload      {d} record(s) leave the screen and come back as the Game Boy's do, and each faulted cart does not\n", .{eo.reload_cases.len});
        }
        for (reload_reps) |r| try eo.printCase(out, r, "      ");

        // ---- The status bar, against the Game Boy drawing it ---------------
        //
        // Step 13b. No trace carries the window, so the band is graded against
        // a render: the same values into both machines at the same point of
        // the same tick, and the twenty window tiles compared tile for tile,
        // with the roll, the shuffle timer and a walk that streams rows riding
        // along. See `src/hud_oracle.zig`.
        const ho = @import("hud_oracle.zig");
        const hrec = try ho.loadRecording(arena, init.io, bytes);
        var hrep = try ho.grade(arena, init.io, bytes, eset, hrec, build_options.mesen_path, init.environ_map.get("HOME") orelse "");
        defer hrep.deinit(arena);
        if (hrep.ok()) {
            try out.print("ok    status bar        ", .{});
        } else {
            failures += 1;
            try out.print("FAIL  status bar        ", .{});
        }
        try ho.printReport(out, hrep, "");

        // ---- The recording, anchored ---------------------------------------
        //
        // Step 26. `anchored` above grades the published run; this grades
        // James's, with every reference taken off Mesen2 rather than replayed on
        // our Game Boy. One window of it, the first 2000 frames, because a pass
        // replays from the movie's start and a deep window costs most of an
        // hour: see `recorded_gate_window`. The same call `oracle -- recorded`
        // makes, so the tool a red rung sends you to prints this sweep.
        if (build_options.mesen_path.len == 0) {
            try out.print("ok    recorded          not run: no emulator (set MESEN, see docs/setup.md)\n", .{});
        } else if (hrec) |rec| {
            var rr = try oracle.gradeRecorded(
                arena,
                init.io,
                bytes,
                rec,
                oracle.recorded_gate_start,
                oracle.recorded_gate_window,
                oracle.anchor_min_frames,
                false,
                build_options.mesen_path,
                init.environ_map.get("HOME") orelse "",
            );
            defer rr.deinit(arena);
            const ran = rr.an;
            if (ran.stretches.len == 0) {
                failures += 1;
                try out.print("FAIL  recorded          no handover of control in the recording's first {d} frames; nothing was graded\n", .{oracle.recorded_gate_window});
            } else if (ran.reached() < oracle.recorded_gate_floor) {
                failures += 1;
                try out.print(
                    "FAIL  recorded          the port plays {d} frames of the recording's first {d}, under the floor of {d}\n",
                    .{ ran.reached(), oracle.recorded_gate_window, oracle.recorded_gate_floor },
                );
            } else {
                try out.print(
                    "ok    recorded          the port plays {d} of {d} frames across {d} of {d} stretches of the recording (floor {d})\n",
                    .{ ran.reached(), ran.offered(), ran.graded(), ran.stretches.len, oracle.recorded_gate_floor },
                );
            }
            if (ran.stretches.len != 0 and ran.graded() < oracle.recorded_gradable_floor) {
                failures += 1;
                try out.print(
                    "FAIL  recorded          {d} stretches can be booted into, under the floor of {d}. Run `zig build oracle -- recorded 0 {d}`\n",
                    .{ ran.graded(), oracle.recorded_gradable_floor, oracle.recorded_gate_window },
                );
            }
        } else {
            try out.print("ok    recorded          not run: no recording at {s}, or one made on another cartridge (see tools/get-tas.sh)\n", .{@import("gb_trace.zig").recording_path});
        }
    }

    // ---- The output pins (release Step 1) ----------------------------------
    // The carts `zig build rom` writes and the crawl they are built from, each
    // against the SHA-1 in `pins/cart.txt`; the build makes all three fresh
    // before this runs. Every refactor of the pipeline is graded here. An
    // intended change re-pins with `zig build repin`, which also logs it, so
    // the pin and the history's last line must agree too.
    if (rom_bytes) |bytes| {
        if (try cartPin(arena, init.io, bytes, out)) {
            try out.print("ok    cart pin          retail, debug and crawl are the SHA-1s in {s}, the last line of {s}\n", .{ pin.cart_path, pin.history_path });
        } else failures += 1;
    } else {
        try out.print("skip  cart pin          needs the ROM\n", .{});
    }

    // ---- The binary (release Step 6) ----------------------------------------
    // The build passes the `m2snes` binary's path and what a plain `zig build`
    // installs. `builder`: the binary names no configured ROM path, and it is
    // all `zig build` installs. `pin (binary)`: both carts from the binary,
    // run from a working directory of its own, against the pins.
    var gate_args = std.process.Args.Iterator.init(init.minimal.args);
    _ = gate_args.next();
    const m2snes_exe = gate_args.next() orelse return error.MissingBinaryArgument;
    const installs = gate_args.next() orelse return error.MissingInstallsArgument;
    if (try builderRung(arena, init.io, m2snes_exe, installs, out)) {
        try out.print("ok    builder           {s} names no configured ROM path, and a plain `zig build` installs only it\n", .{std.fs.path.basename(m2snes_exe)});
    } else failures += 1;
    if (rom_bytes != null) {
        const cwd = std.Io.Dir.cwd();
        const workdir = "build-out/pin-binary";
        try cwd.deleteTree(init.io, workdir);
        try cwd.createDirPath(init.io, workdir);
        if (!try pin.gradeBinary(arena, init.io, .{
            .exe = try cwd.realPathFileAlloc(init.io, m2snes_exe, arena),
            .rom = try cwd.realPathFileAlloc(init.io, rom_path, arena),
            .workdir = try cwd.realPathFileAlloc(init.io, workdir, arena),
            .crawl_cache = try cwd.realPathFileAlloc(init.io, warp.crawl_dir, arena),
        }, "pin (binary)", out)) failures += 1;
    } else {
        try out.print("skip  pin (binary)      needs the ROM\n", .{});
    }

    // ---- Always: tracked-file policy --------------------------------------
    // cwd() is not an iterable handle (it stands in for AT_FDCWD), so open the
    // working tree explicitly before walking it.
    var root = try std.Io.Dir.cwd().openDir(init.io, ".", .{ .iterate = true });
    defer root.close(init.io);

    var report = try policy.check(arena, init.io, root, rom_bytes);
    defer report.deinit(arena);

    if (report.ok()) {
        try out.print("ok    file policy       {d} committable files, {d} KiB scanned ({s}){s}\n", .{
            report.files_scanned,
            report.bytes_scanned / 1024,
            @tagName(report.mode),
            if (report.rom_scanned) ", including the ROM n-gram scan" else " (n-gram scan skipped: no ROM)",
        });
    } else {
        failures += 1;
        try out.print("FAIL  file policy       {d} violation(s)\n", .{report.violations.items.len});
        for (report.violations.items) |v| {
            try out.print("        {s}: {s}\n", .{ v.path, v.detail });
        }
    }
    try out.print("      note              the file policy is a hygiene tripwire, not a legal proof\n", .{});

    if (failures == 0) {
        try out.print("the gate          green: {d} rungs, none retired (docs/conformance.md)\n", .{rung_count});
    } else {
        try out.print("the gate          {d} rung(s) red of {d}\n", .{ failures, rung_count });
    }

    try out.flush();
    if (failures != 0) std.process.exit(1);
}

/// The `builder` rung: true when green, otherwise it has printed why.
fn builderRung(arena: std.mem.Allocator, io: std.Io, exe: []const u8, installs: []const u8, out: *std.Io.Writer) !bool {
    var ok = true;
    if (!pin.installsOnlyBuilder(installs)) {
        try out.print("FAIL  builder           a plain `zig build` installs {s}; it must install only m2snes\n", .{installs});
        ok = false;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, exe, arena, .limited(256 << 20));
    if (pin.carriesRomPath(bytes, build_options.rom_path)) {
        try out.print("FAIL  builder           {s} carries the configured ROM path {s}\n", .{ exe, build_options.rom_path });
        ok = false;
    }
    return ok;
}

/// The `cart pin` rung: true when green, otherwise it has printed why.
fn cartPin(arena: std.mem.Allocator, io: std.Io, rom: []const u8, out: *std.Io.Writer) !bool {
    const cwd = std.Io.Dir.cwd();
    const want_text = cwd.readFileAlloc(io, pin.cart_path, arena, .limited(1 << 16)) catch |e| {
        try out.print("FAIL  cart pin          cannot read {s}: {s}; pin with {s}\n", .{ pin.cart_path, @errorName(e), pin.repin_hint });
        return false;
    };
    const want = pin.parse(want_text) catch |e| {
        try out.print("FAIL  cart pin          {s}: {s}\n", .{ pin.cart_path, @errorName(e) });
        return false;
    };
    var buf: [128]u8 = undefined;
    const crawl_path = warp.crawlPath(&buf, rom);
    var failed: []const u8 = "";
    const got = pin.current(arena, io, crawl_path, &failed) catch |e| {
        try out.print("FAIL  cart pin          cannot read {s}: {s}\n", .{ failed, @errorName(e) });
        return false;
    };
    var ok = true;
    for (std.enums.values(pin.Kind)) |k| {
        if (std.mem.eql(u8, &want.get(k), &got.get(k))) continue;
        if (ok) try out.print("FAIL  cart pin          the output moved; if that was meant, {s}\n", .{pin.repin_hint});
        ok = false;
        try out.print("        {s: <6} pinned {x}, now {x} ({s})\n", .{ @tagName(k), &want.get(k), &got.get(k), pin.outputPath(k, crawl_path) });
    }
    // The pin and the history's last line: a hand edit moves one and not the other.
    const history = cwd.readFileAlloc(io, pin.history_path, arena, .limited(1 << 20)) catch |e| {
        try out.print("FAIL  cart pin          cannot read {s}: {s}\n", .{ pin.history_path, @errorName(e) });
        return false;
    };
    const logged = pin.lastEntry(history) catch |e| {
        try out.print("FAIL  cart pin          {s}'s last line: {s}\n", .{ pin.history_path, @errorName(e) });
        return false;
    };
    if (!pin.equal(want, logged)) {
        try out.print("FAIL  cart pin          {s} is not where {s}'s last line moved it: re-pin with {s}, never by hand\n", .{ pin.cart_path, pin.history_path, pin.repin_hint });
        return false;
    }
    return ok;
}

/// Reassemble `engine/main.asm` into a scratch path and compare the result with
/// the committed image and symbol file.
///
/// The symbol file is compared too, and not only because Step 14 generates
/// against it: renaming a label changes `engine.sym` without changing a single
/// byte of `engine.bin`, so an image-only check would call a stale symbol file
/// current.
const Reassembly = union(enum) {
    matches,
    no_assembler,
    differs: []const u8,
    failed: []const u8,
};

fn reassemble(allocator: std.mem.Allocator, io: std.Io) !Reassembly {
    const asar = "vendor/asar/asar";
    std.Io.Dir.cwd().access(io, asar, .{}) catch return .no_assembler;

    const bin = ".zig-cache/engine-check.bin";
    const sym = ".zig-cache/engine-check.sym";
    // asar appends to whatever is already at the output path, so it starts empty.
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bin, .data = "" }) catch return .{ .failed = "could not create a scratch file" };

    var child = std.process.spawn(io, .{
        .argv = &.{
            asar,             "--no-title-check", "--fix-checksum=off",
            "--symbols=wla",  "--symbols-path=" ++ sym,
            "engine/main.asm", bin,
        },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return .{ .failed = "could not run the assembler" };
    const term = child.wait(io) catch return .{ .failed = "the assembler did not finish" };
    if (term != .exited or term.exited != 0) return .{ .failed = "the assembler reported errors" };

    const built = std.Io.Dir.cwd().readFileAlloc(io, bin, allocator, .limited(1 << 20)) catch
        return .{ .failed = "the assembler wrote no image" };
    defer allocator.free(built);
    if (!std.mem.eql(u8, built, snes_inject.image)) return .{ .differs = "engine.bin" };

    const built_sym = std.Io.Dir.cwd().readFileAlloc(io, sym, allocator, .limited(1 << 20)) catch
        return .{ .failed = "the assembler wrote no symbol file" };
    defer allocator.free(built_sym);
    if (!std.mem.eql(u8, built_sym, snes_inject.symbols)) return .{ .differs = "engine.sym" };

    return .matches;
}

/// The same recheck for the SPC700 side: reassemble `engine/audio/main.asm`
/// against the committed shim package and compare with `engine/audio.bin` and
/// `engine/audio.mlb`.
///
/// It is a separate function rather than a parameterised one because the two
/// assemblers share no flags, no symbol format and no failure modes, and the
/// only thing a merged version would save is the six lines they have in common.
fn reassembleSpc(allocator: std.mem.Allocator, io: std.Io) !Reassembly {
    const asm_bin = "vendor/spc700asm/spc700asm";
    std.Io.Dir.cwd().access(io, asm_bin, .{}) catch return .no_assembler;
    std.Io.Dir.cwd().access(io, "engine/audio/main.asm", .{}) catch return .no_assembler;

    const bin = ".zig-cache/audio-check.bin";
    const mlb = ".zig-cache/audio-check.mlb";

    var child = std.process.spawn(io, .{
        .argv = &.{ asm_bin, "-o", bin, "-m", mlb, "engine/audio/main.asm" },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return .{ .failed = "could not run the assembler" };
    const term = child.wait(io) catch return .{ .failed = "the assembler did not finish" };
    if (term != .exited or term.exited != 0) return .{ .failed = "the assembler reported errors" };

    const pairs = [_]struct { built: []const u8, committed: []const u8 }{
        .{ .built = bin, .committed = "engine/audio.bin" },
        .{ .built = mlb, .committed = "engine/audio.mlb" },
    };
    for (pairs) |pair| {
        const built = std.Io.Dir.cwd().readFileAlloc(io, pair.built, allocator, .limited(1 << 20)) catch
            return .{ .failed = "the assembler wrote no output" };
        defer allocator.free(built);
        const committed = std.Io.Dir.cwd().readFileAlloc(io, pair.committed, allocator, .limited(1 << 20)) catch
            return .{ .differs = pair.committed };
        defer allocator.free(committed);
        if (!std.mem.eql(u8, built, committed)) return .{ .differs = pair.committed };
    }

    return .matches;
}


// ---- The headless boot test ------------------------------------------------

/// What running the finished cart in Mesen2 said.
///
/// The generated script's exit code is the only channel Mesen2 leaves open in

/// The cold-boot rung's own result. A separate type from `BootTest` because it
/// answers a different question with a different protocol: `BootTest` grades a
/// cart the gate drove into position, and this one grades the cart the builder
/// ships, left alone.
const ColdTest = union(enum) {
    played,
    no_emulator,
    stalled: []const u8,
    sequence: []const u8,
    failed: []const u8,
};

/// Draw every frame. Flat out, which the testrunner always runs, Mesen skips
/// drawing any frame that starts within 10 ms of wall-clock time of the last
/// one it drew (`SnesPpu.cpp`, `_skipRender`), and `emu.getScreenBuffer()`
/// then hands back that last drawn frame while OAM and every variable are the
/// current one's. How stale it is follows the host's load and the script's own
/// per-frame cost, which is why `snes boot` phase 7 exited 81 on some runs of
/// the same cart and not others (Step 24d): hashed every 50th frame, two runs
/// with this switch agreed at all 89 samples, and a run without it disagreed
/// with them at 7 of the 89, all while Samus was moving. Only the drawing is
/// skipped -- sprite evaluation runs regardless -- so the two launches whose
/// scripts read the framebuffer, `cold boot` and `snes boot`, are the ones
/// that carry it.
const draw_every_frame = "--snes.disableFrameSkipping=true";

fn coldBootTest(io: std.Io, rom: []const u8, lua: []const u8) !ColdTest {
    if (build_options.mesen_path.len == 0) return .no_emulator;
    std.Io.Dir.cwd().access(io, build_options.mesen_path, .{}) catch return .no_emulator;

    const rom_file = ".zig-cache/cold-check.sfc";
    const lua_file = ".zig-cache/cold-check.lua";
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_file, .data = rom }) catch
        return .{ .failed = "could not stage the cart" };
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lua_file, .data = lua }) catch
        return .{ .failed = "could not stage the test script" };

    var child = std.process.spawn(io, .{
        .argv = &.{ build_options.mesen_path, rom_file, "--testrunner", lua_file, "--timeout=90", draw_every_frame },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return .{ .failed = "could not run the emulator" };
    const term = child.wait(io) catch return .{ .failed = "the emulator did not finish" };
    if (term != .exited) return .{ .failed = "the emulator did not exit cleanly" };

    return switch (term.exited) {
        0 => .played,
        140 => .{ .stalled = "the engine hit Fatal: it could not find something it was patched to find" },
        141 => .{ .stalled = "the frame counter never advanced: boot never finished" },
        142 => .{ .stalled = "the cart did not come up in the pose its own record names" },
        143 => .{ .sequence = "the countdown did not fall by exactly one a frame" },
        144 => .{ .sequence = "control arrived before the countdown was spent and a button was held" },
        145 => .{ .sequence = "the countdown was spent and a held button never handed over control" },
        146 => .{ .stalled = "the engine was handed a pose it could not run" },
        147 => .{ .sequence = "Samus was drawn on every frame of the appearance sequence: no flicker" },
        148 => .{ .sequence = "Samus was never drawn during the appearance sequence" },
        149 => .{ .sequence = "control arrived and the pose machine did not move her" },
        155 => .{ .sequence = "Samus drew over the ship where its colour is not 0: the start cell's transition word has bit 11, and the Game Boy puts her behind it" },
        156 => .{ .sequence = "Samus's parts covered none of the ship's pixels, or none of hers showed: the behind check graded nothing" },
        157 => .{ .sequence = "no drawn frame followed a blank one in the appearance sequence: the behind check never ran" },
        255 => .{ .failed = "the emulator timed out: the script never reached a verdict" },
        else => .{ .failed = "the cold-boot script exited with an unallocated code" },
    };
}

/// The load rung's exit code, or null when there is no emulator.
fn loadBootTest(io: std.Io, rom: []const u8, lua: []const u8) !?u8 {
    if (build_options.mesen_path.len == 0) return null;
    std.Io.Dir.cwd().access(io, build_options.mesen_path, .{}) catch return null;
    const rom_file = ".zig-cache/load-check.sfc";
    const lua_file = ".zig-cache/load-check.lua";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_file, .data = rom });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lua_file, .data = lua });
    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.mesen_path, rom_file, "--testrunner", lua_file, "--timeout=90" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    if (term != .exited) return 255;
    return @truncate(term.exited);
}

fn loadCode(code: u8) []const u8 {
    return switch (code) {
        0 => "the cart did what the slot says",
        160 => "Fatal ran",
        161 => "the title screen never ran",
        162 => "Start did not leave the title",
        163 => "the room, position or camera is not the record's",
        164 => "energy, tanks or missiles are not the record's",
        165 => "items, beam or facing are not the record's",
        166 => "the Metroid counts are not the record's",
        167 => "an enemy the record says is dead is not",
        168 => "the background characters are not the record's source",
        169 => "the item font is not in the object characters",
        170 => "control waited for a button after a load",
        171 => "the file counter was not written, or the title decided wrongly",
        172 => "the engine was handed a pose it could not run",
        173 => "the solidity or the metatile table is not the record's",
        174 => "the common item tiles are not in the object characters: a copy into the shared window made once, not twice",
        255 => "the emulator timed out",
        else => "an unallocated code",
    };
}

/// The title rung's exit code, or null when there is no emulator. It reads
/// the framebuffer, so it draws every frame.
fn titleTest(io: std.Io, rom: []const u8, lua: []const u8) !?u8 {
    if (build_options.mesen_path.len == 0) return null;
    std.Io.Dir.cwd().access(io, build_options.mesen_path, .{}) catch return null;
    const rom_file = ".zig-cache/title-check.sfc";
    const lua_file = ".zig-cache/title-check.lua";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_file, .data = rom });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lua_file, .data = lua });
    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.mesen_path, rom_file, "--testrunner", lua_file, "--timeout=90", draw_every_frame },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    if (term != .exited) return 255;
    return @truncate(term.exited);
}

/// The title rung's fault run, Step 24h: each new routine taken out of the
/// image the clean run passed, and caught only by the code that grades it.
/// `TitleDraw` and `UploadTitleObj` are `jsl`'d, so their patch is `rtl`; the
/// clear's is `clc`/`rts`, `TitleFrame`'s own stay-on-the-title return.
const TitleFault = struct { label: []const u8, patch: []const u8, want: u8, run: snes_romtest.TitleRun = .grade };
const title_faults = [_]TitleFault{
    .{ .label = "TitleDraw", .patch = &.{0x6B}, .want = 96 },
    .{ .label = "DrawNonGameSprite", .patch = &.{0x60}, .want = 96 },
    .{ .label = "UploadTitleObj", .patch = &.{0x6B}, .want = 94 },
    // The clear leaves the option shown: the state byte, first thing it grades.
    .{ .label = "TitleFrame_clear", .patch = &.{ 0x18, 0x60 }, .want = 95 },
    // Step 24j. No "Super" at all: CGRAM's palette 7 is the zero `Reset` left.
    .{ .label = "UploadTitleArt", .patch = &.{0x6B}, .want = 101 },
    // The patch's column count read from the header's row byte (`ldy #$0003`
    // for `#$0002`): the palette is right and the art is scrambled, so only
    // the pixel comparison can catch it.
    .{ .label = "TitleArtMap_cols", .patch = &.{ 0xA0, 0x03, 0x00 }, .want = 101 },
    // "Super" left in BG1's map when the game starts.
    .{ .label = "ClearTitleArt", .patch = &.{0x6B}, .want = 102 },
    // Step 24i. No seed: the title opens on slot 0 where `saveLastSlot` says 2.
    .{ .label = "TitleSeedSlot", .patch = &.{0x6B}, .want = 92 },
    // The seed's bound one wider (`cmp #$04`): 3 is taken as a slot, which
    // only the run seeded with 3 can see.
    .{ .label = "TitleSeedSlot_bound", .patch = &.{ 0xC9, 0x04 }, .want = 92, .run = .last_slot_3 },
    // No Right or Left: the first Right leaves the slot on 2.
    .{ .label = "TitleSlotStep", .patch = &.{0x6B}, .want = 95 },
    // The slot's offset always slot 0's (`lda #$0000`): the clear empties
    // slot 0 instead of slot 1.
    .{ .label = "SlotRecP_slot", .patch = &.{ 0xA9, 0x00, 0x00 }, .want = 97 },
};

const TitleMiss = union(enum) { unplaced, no_op, not_run, code: u8 };

fn titleFaultRun(arena: std.mem.Allocator, io: std.Io, rom: []const u8, luas: std.EnumArray(snes_romtest.TitleRun, []const u8), misses: *[title_faults.len]?TitleMiss) !void {
    var lua_files: std.EnumArray(snes_romtest.TitleRun, []const u8) = .initUndefined();
    var it = lua_files.iterator();
    while (it.next()) |e| {
        e.value.* = try std.fmt.allocPrint(arena, ".zig-cache/title-fault-{s}.lua", .{@tagName(e.key)});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = e.value.*, .data = luas.get(e.key) });
    }
    var children: [title_faults.len]?std.process.Child = @splat(null);
    for (title_faults, 0..) |f, i| {
        misses[i] = .not_run;
        const at = snes_inject.symbolOffset(f.label) orelse {
            misses[i] = .unplaced;
            continue;
        };
        if (std.mem.eql(u8, rom[at..][0..f.patch.len], f.patch)) {
            misses[i] = .no_op;
            continue;
        }
        const faulted = try arena.dupe(u8, rom);
        @memcpy(faulted[at..][0..f.patch.len], f.patch);
        const rom_file = try std.fmt.allocPrint(arena, ".zig-cache/title-fault-{s}.sfc", .{f.label});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_file, .data = faulted });
        children[i] = std.process.spawn(io, .{
            .argv = &.{ build_options.mesen_path, rom_file, "--testrunner", lua_files.get(f.run), "--timeout=90", draw_every_frame },
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch null;
    }
    for (&children, title_faults, 0..) |*slot, f, i| {
        var child = slot.* orelse continue;
        const term = child.wait(io) catch continue;
        if (term != .exited) continue;
        const code: u8 = @truncate(term.exited);
        misses[i] = if (code == f.want) null else .{ .code = code };
    }
}

const PauseJob = struct { rom: []const u8, lua: []const u8 };

/// The pause rung's runs, in parallel: exit codes, or null when there is no
/// emulator. It reads no picture, so it skips frames as it likes.
fn pauseRuns(arena: std.mem.Allocator, io: std.Io, jobs: []const PauseJob, got: []?u8) !void {
    @memset(got, null);
    if (build_options.mesen_path.len == 0) return;
    std.Io.Dir.cwd().access(io, build_options.mesen_path, .{}) catch return;
    var children: [8]?std.process.Child = @splat(null);
    for (jobs, 0..) |job, i| {
        const rom_file = try std.fmt.allocPrint(arena, ".zig-cache/pause-check-{d}.sfc", .{i});
        const lua_file = try std.fmt.allocPrint(arena, ".zig-cache/pause-check-{d}.lua", .{i});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_file, .data = job.rom });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lua_file, .data = job.lua });
        children[i] = try std.process.spawn(io, .{
            .argv = &.{ build_options.mesen_path, rom_file, "--testrunner", lua_file, "--timeout=90" },
            .stdout = .ignore,
            .stderr = .ignore,
        });
    }
    for (children[0..jobs.len], 0..) |*slot, i| {
        var child = slot.* orelse continue;
        const term = try child.wait(io);
        got[i] = if (term == .exited) @truncate(term.exited) else 255;
    }
}

const ScenarioJob = struct {
    name: []const u8,
    rom: []const u8,
    lua: []const u8,
    /// The script reads the framebuffer, which needs every frame drawn.
    frames: bool = false,
};
const ScenarioGot = struct { code: u8, line: []const u8 };

/// How many enemy cases are in flight at once, each with two or three Mesen2
/// runs: four is twelve processes at most, one per core on the machine the
/// gate's fifteen minutes are measured on.
const enemy_width: usize = 4;

/// The scenario rung's runs, 1.0 Step 3, all in parallel: each one's exit code
/// and the first line it printed, or null when there is no emulator. A job
/// with no script is not run.
fn scenarioRuns(arena: std.mem.Allocator, io: std.Io, jobs: []const ScenarioJob, got: []?ScenarioGot) !void {
    @memset(got, null);
    if (build_options.mesen_path.len == 0) return;
    std.Io.Dir.cwd().access(io, build_options.mesen_path, .{}) catch return;
    const children = try arena.alloc(?std.process.Child, jobs.len);
    @memset(children, null);
    for (jobs, 0..) |job, i| {
        if (job.lua.len == 0) continue;
        const rom_file = try std.fmt.allocPrint(arena, ".zig-cache/scenario-{d}.sfc", .{i});
        const lua_file = try std.fmt.allocPrint(arena, ".zig-cache/scenario-{d}.lua", .{i});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_file, .data = job.rom });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lua_file, .data = job.lua });
        const argv: []const []const u8 = if (job.frames)
            &.{ build_options.mesen_path, rom_file, "--testrunner", lua_file, "--timeout=90", draw_every_frame }
        else
            &.{ build_options.mesen_path, rom_file, "--testrunner", lua_file, "--timeout=90" };
        children[i] = try std.process.spawn(io, .{
            .argv = argv,
            .stdout = .pipe,
            .stderr = .ignore,
        });
    }
    // What a script prints is a line or two, well under a pipe's buffer, so
    // reading each in turn after all are started does not stall the others.
    for (children, 0..) |*slot, i| {
        var child = slot.* orelse continue;
        var buf: [256]u8 = undefined;
        var rdr = child.stdout.?.readerStreaming(io, &buf);
        const text = rdr.interface.allocRemaining(arena, .limited(64 * 1024)) catch "";
        const term = try child.wait(io);
        const line = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " \r");
        got[i] = .{ .code = if (term == .exited) @truncate(term.exited) else 255, .line = line };
    }
}

/// The scenario rung's faults: a byte of the menu changed, caught by the check
/// of the edit that uses it.
const ScenarioFault = struct { label: []const u8, offset: usize = 0, patch: []const u8, scenario: []const u8, want: u8 };
const scenario_faults = [_]ScenarioFault{
    // Hi-jump's row (the second, four bytes a row) given the screw attack's
    // bit: the items scenario's second edit sets the wrong one.
    .{ .label = "DbgRowsSamus", .offset = 1 * 4 + 1, .patch = &.{0x04}, .scenario = "items", .want = 12 },
    // The beam row's weapon write gone (`nop`s): the weapon stays the power
    // beam's, which the ice beam's pickup would have changed.
    .{ .label = "DebugEdit_beamWeapon", .patch = &.{ 0xEA, 0xEA, 0xEA }, .scenario = "beams", .want = 11 },
    // 1.0 Step 4. The kill's `earthquakeCheck` gone (`nop`s over the `jsl`):
    // the first kill arms nothing.
    .{ .label = "DebugMetroidKill_quake", .patch = &.{ 0xEA, 0xEA, 0xEA, 0xEA }, .scenario = "metroids", .want = 11 },
    // The flag's save-buffer write gone: a bank not loaded keeps its flag.
    .{ .label = "DebugFlagSet_save", .patch = &.{ 0xEA, 0xEA, 0xEA, 0xEA }, .scenario = "flags", .want = 11 },
    // Minutes wrapped at $70: Right from 59 is 60.
    .{ .label = "DebugEdit_minutesTop", .offset = 1, .patch = &.{0x70}, .scenario = "clock", .want = 20 },
    // 1.0 Step 10. `DebugDispMoves` answering "moves" for every row (`lda #$01
    // / rts` over its `php / rep #$30`), as before the step: a larva killed
    // before the stinger takes one off the shown count.
    .{ .label = "DebugDispMoves", .patch = &.{ 0xA9, 0x01, 0x60 }, .scenario = "larvae", .want = 11 },
};

/// The warp rung's scenario faults, 1.0 Step 5c: at least one for each of
/// `warp_grade.Scenario`, each on the scenario it names.
const warp_faults = [_]ScenarioFault{
    // The flag's save-buffer write gone: an orb in a bank not loaded keeps
    // its flag, and the warp loads it.
    .{ .label = "DebugFlagSet_save", .patch = &.{ 0xEA, 0xEA, 0xEA, 0xEA }, .scenario = "item", .want = 30 },
    // The slot's delete gone (`nop`s over the `jsl`): the Metroid killed on
    // the screen stays in its slot.
    .{ .label = "DebugFlagSet_free", .patch = &.{ 0xEA, 0xEA, 0xEA, 0xEA }, .scenario = "metroid", .want = 33 },
    // The kill's count left alone (`sbc #$00`): the door loads the table of
    // the count before it.
    .{ .label = "DebugMetroidKill_count", .offset = 1, .patch = &.{0x00}, .scenario = "gated_door", .want = 35 },
    // 1.0 Step 6: the LCD handler's commands applied to nothing (`rts`), so
    // the body keeps the room's scroll, the head's window never closes and
    // the status bar never comes: her room is not the Game Boy's picture.
    .{ .label = "QueenApply", .patch = &.{0x60}, .scenario = "queen", .want = 36 },
    // 1.0 Step 10: the engine before 1.0 Step 8b's fix, OBP1 loaded straight
    // after OBP0 at colour $84, so object palette 1 is black: each refill's
    // blink is black on the black play field.
    .{ .label = "LoadPalette_obp1", .offset = 1, .patch = &.{0x84}, .scenario = "refills", .want = 39 },
    // 1.0 Step 10: the count's test gone (`bne` to `bra`), as before the
    // step: the refill at zero fills and the credits branch never runs.
    .{ .label = "ItemPickupArm_missileRefillTest", .patch = &.{0x80}, .scenario = "refill_credits", .want = 43 },
    // 1.0 Step 13: the sixth bomb's AI switch gone (`nop`s over the store):
    // Arachnus keeps its own AI under the item's sprite, which it puts back
    // the next time it spits, and there is nothing to pick up.
    .{ .label = "EnAiArachnus_orbAi", .patch = &.{ 0xEA, 0xEA, 0xEA }, .scenario = "spring_ball", .want = 46 },
    // 1.0 Step 27a: a crossing's reset ending the fight again (`stz !MetFight`
    // over `stz !EnOffscr`, which nothing reads), as before the step: the
    // post-death wait stops where the warp left it and runs out mid-explosion
    // at the next kill.
    .{ .label = "ResetEntities_offscr", .patch = &.{ 0x9C, 0x7F, 0x06 }, .scenario = "missile_kill", .want = 50 },
    // 1.0 Step 27a: `EarthquakeCheck` handing back its index for the slot
    // (`ply` for `plx`), as before the step: the kill's pass runs on misaligned
    // slots and writes $FF over the explosion's counter.
    .{ .label = "EarthquakeCheck_out", .patch = &.{0x7A}, .scenario = "missile_kill", .want = 50 },
};

/// The pause rung's fault run, 1.0 Step 2a: each new routine, or the piece of
/// one that makes a mechanism, taken out of the image the clean run passed,
/// and caught only by the code that grades it.
const PauseFault = struct { label: []const u8, patch: []const u8, want: u8, run: snes_romtest.PauseRun = .grade, debug: bool = false };
const pause_faults = [_]PauseFault{
    // No pause at all: Start at frame 350 asks for no pause sound.
    .{ .label = "TryPausing", .patch = &.{0x6B}, .want = 119 },
    // The flash's bit cleared (`and #$00`): dark for the whole pause.
    .{ .label = "PausedFrame_flash", .patch = &.{ 0x29, 0x00 }, .want = 114 },
    // The flash kept off the screen (1.0 Step 25): `bg_palette` right, the
    // brightness full throughout.
    .{ .label = "PauseShow", .patch = &.{0x60}, .want = 125 },
    // Start's mask cleared (`and #$0000`): nothing unpauses.
    .{ .label = "PausedFrame_unpause", .patch = &.{ 0x29, 0x00, 0x00 }, .want = 119 },
    // The bar's paused arm gone: the count stays where the L counter goes.
    .{ .label = "StatusBarLCounter", .patch = &.{0x6B}, .want = 117 },
    // The blank and the `L` not written over the icon: ten bytes of `nop`.
    .{ .label = "TryPausing_found", .patch = &.{ 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA }, .want = 118 },
    // The counter seeded as the title's, less the lead (`adc #$0000`).
    .{ .label = "InitState_titleLead", .patch = &.{ 0x69, 0x00, 0x00 }, .want = 120 },
    // 1.0 Step 2d. `DebugAllowed` ignored (its `beq` a pair of `nop`s): the
    // retail cart's chord opens the menu, and the combo run sees it.
    .{ .label = "DebugMenuCheck_allowed", .patch = &.{ 0xEA, 0xEA }, .want = 121, .run = .combo },
    // The chord never recognised (`clc`/`rts`): the debug cart just pauses.
    .{ .label = "DebugChord", .patch = &.{ 0x18, 0x60 }, .want = 122, .run = .debug_combo, .debug = true },
    // The menu never drawn or opened.
    .{ .label = "DebugOpenScreen", .patch = &.{0x60}, .want = 122, .run = .debug_combo, .debug = true },
    // Never closed: B at the root does nothing.
    .{ .label = "DebugClose", .patch = &.{0x60}, .want = 123, .run = .debug_combo, .debug = true },
    // The NMI half gone: the page is drawn in WRAM and never reaches VRAM or
    // the layers.
    .{ .label = "DebugNmi", .patch = &.{0x6B}, .want = 122, .run = .debug_combo, .debug = true },
    // The layers never put back: closing leaves BG1 alone on every band.
    .{ .label = "DebugNmi_restore", .patch = &.{0x6B}, .want = 123, .run = .debug_combo, .debug = true },
};

fn pauseFaultRun(arena: std.mem.Allocator, io: std.Io, retail: []const u8, debug_rom: []const u8, luas: std.EnumArray(snes_romtest.PauseRun, []const u8), misses: *[pause_faults.len]?TitleMiss) !void {
    var lua_files: std.EnumArray(snes_romtest.PauseRun, []const u8) = .initUndefined();
    var it = lua_files.iterator();
    while (it.next()) |e| {
        e.value.* = try std.fmt.allocPrint(arena, ".zig-cache/pause-fault-{s}.lua", .{@tagName(e.key)});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = e.value.*, .data = luas.get(e.key) });
    }
    var children: [pause_faults.len]?std.process.Child = @splat(null);
    for (pause_faults, 0..) |f, i| {
        misses[i] = .not_run;
        const rom = if (f.debug) debug_rom else retail;
        const at = snes_inject.symbolOffset(f.label) orelse {
            misses[i] = .unplaced;
            continue;
        };
        if (std.mem.eql(u8, rom[at..][0..f.patch.len], f.patch)) {
            misses[i] = .no_op;
            continue;
        }
        const faulted = try arena.dupe(u8, rom);
        @memcpy(faulted[at..][0..f.patch.len], f.patch);
        const rom_file = try std.fmt.allocPrint(arena, ".zig-cache/pause-fault-{s}.sfc", .{f.label});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_file, .data = faulted });
        children[i] = std.process.spawn(io, .{
            .argv = &.{ build_options.mesen_path, rom_file, "--testrunner", lua_files.get(f.run), "--timeout=90" },
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch null;
    }
    for (&children, pause_faults, 0..) |*slot, f, i| {
        var child = slot.* orelse continue;
        const term = child.wait(io) catch continue;
        if (term != .exited) continue;
        const code: u8 = @truncate(term.exited);
        misses[i] = if (code == f.want) null else .{ .code = code };
    }
}

fn pauseCode(code: u8) []const u8 {
    return switch (code) {
        0 => "the pause did what the Game Boy's did",
        110 => "Fatal ran",
        111 => "the title, the new game or the anchor never arrived",
        112 => "the engine was handed a pose it could not run",
        113 => "a pass after the anchor was not one frame: the counter skipped",
        114 => "bg_palette is not the Game Boy's on some frame: the flash",
        115 => "Samus's position or pose is not the Game Boy's on some frame",
        116 => "the in-game timer is not the Game Boy's on some frame",
        117 => "the status bar is not the Game Boy's on some frame: the L counter",
        118 => "the objects' characters are not the Game Boy's on some frame: the L over the HUD's Metroid",
        119 => "a frame asked for the pause or the unpause sound another number of times than the Game Boy's",
        120 => "the frame counter is not the Game Boy's frameCounter on some frame",
        121 => "debugFlag set, or the debug menu up, on a retail cart",
        122 => "the chord did not open the debug menu over a frozen game, with its root, its font, BG1 alone and SAMUS under A",
        123 => "B back, B at the root or the chord again did not close the menu to play's layers, or play did not go on",
        124 => "the play field's VRAM changed under the debug menu",
        125 => "the screen's brightness does not follow bg_palette: full where the Game Boy's is $93, dimmer where not",
        255 => "the emulator did not exit normally",
        else => "an unknown code: a timeout, or a script error, reads as one",
    };
}

fn titleCode(code: u8) []const u8 {
    return switch (code) {
        0 => "the title did what the Game Boy's did",
        90 => "Fatal ran",
        91 => "the title never came up",
        92 => "the title did not open as the Game Boy's: the option hidden, clear unselected, and the slot saveLastSlot names",
        93 => "rows 16 and 17 are not the Game Boy's pixels: the copyright row",
        94 => "the title's object characters are not the cartridge's first sheet",
        95 => "a state byte is not the Game Boy's on some frame",
        96 => "the menu's sprites are not the Game Boy's on some frame",
        97 => "the clear or Start left the slots or saveLastSlot other than the Game Boy's",
        98 => "Start after the clear did not start a new game",
        99 => "the cart left the title on another frame than the Game Boy's",
        100 => "the engine was handed a pose it could not run",
        101 => "\"Super\" is not super.png at super_at over the Game Boy's title, or its colours are not the approved ones",
        102 => "\"Super\" is still in BG1's map once the game has started",
        103 => "a frame asked for the select sound another number of times than the Game Boy's",
        255 => "the emulator timed out",
        else => "an unallocated code",
    };
}

fn deathCode(code: u8) []const u8 {
    return switch (code) {
        0 => "both deaths ran the Game Boy's course",
        180 => "Fatal ran",
        181 => "the title or the new game never arrived",
        182 => "zero displayed health did not kill her, or mode $06 did not follow",
        183 => "mode $06 is not the Game Boy's length",
        184 => "the erase zeroed the wrong bytes, or not all of the object characters",
        185 => "mode $05 is not the Game Boy's length, or not blank for its frames",
        186 => "the GAME OVER screen is wrong, or the window is on",
        187 => "mode $07 on its timer is not the Game Boy's length",
        188 => "the reboot did not reach the title, or cartridge RAM did not survive it",
        189 => "Start on the game over screen did not reboot when the Game Boy's does",
        190 => "the engine was handed a pose it could not run",
        191 => "the pad moved Samus on the frame she died",
        192 => "a Start held through the reboot left the title, or a fresh Start did not",
        193 => "the title after the death did not open as a cold boot's: the option, clear, slot 0 and the cursor",
        255 => "the emulator timed out",
        else => "an unallocated code",
    };
}

fn roundTripCode(code: u8) []const u8 {
    return switch (code) {
        0 => "the cart came back in the record it had written",
        200 => "Fatal ran",
        201 => "the title or the new game never arrived",
        202 => "the save station's tiles did not set the contact",
        203 => "Start on the station did not write a record",
        204 => "the death did not reach the title, or cartridge RAM did not survive it",
        205 => "the title refused the record it had just written",
        206 => "the room, position or camera is not the record's",
        207 => "energy, tanks or missiles are not the record's",
        208 => "the Metroid counts are not the record's, or are a new game's",
        209 => "items, beam or facing are not the record's",
        210 => "the engine was handed a pose it could not run",
        211 => "control never arrived after the load",
        212 => "the loaded collision table has no save station tile in it",
        213 => "Left on the title did not select the slot the run saves in",
        214 => "the save wrote outside its slot, its spawn flags are not the buffer's, or saveLastSlot is not the slot",
        215 => "the title after the reboot did not open on the saved slot, or the load's spawn flags are not that slot's",
        255 => "the emulator timed out",
        else => "an unallocated code",
    };
}

/// testrunner mode - `emu.log` is swallowed and lua's `io` is sandboxed - so the
/// codes are a small protocol, defined in `src/romtest_main.zig` and read back
/// here.
const BootTest = union(enum) {
    /// The cart drew the screen `snes_render` draws, pixel for pixel.
    drew,
    /// No emulator configured.
    no_emulator,
    /// The cart ran and the picture is wrong; the row it first differs on.
    differs: usize,
    /// The camera scrolled into the neighbour and the picture it assembled by
    /// streaming is wrong; the row it first differs on.
    scrolled_wrong: usize,
    /// The picture was right and the camera was not.
    camera: []const u8,
    /// The picture was right and Samus did not move the way the arcs and the
    /// collision data say she should.
    samus: []const u8,
    /// The picture and the camera were right and the input pair was not.
    input: []const u8,
    /// Everything above was right and the room transition was not. Reported
    /// apart from `camera` and `stalled` on purpose: the transition is a
    /// mechanism of its own, and a warp that lands in the wrong room sends the
    /// next person to `RunDoorScript` rather than to `HandleCamera`.
    transition: []const u8,
    /// Everything above was right and the item pickup was not. Its own arm for
    /// the same reason the transition has one: B6 is a mechanism of its own,
    /// and a pickup that gives the wrong bit is nobody's camera bug.
    item: []const u8,
    /// Everything above was right and a destructible block was not. Its own arm
    /// for the same reason the two above have one: B5's terrain half is a
    /// mechanism, and a block that does not stop being a floor is not a
    /// collision bug -- the collision is doing exactly what the tilemap says.
    block: []const u8,
    /// Everything above was right and a projectile was not. Its own arm again,
    /// and this one earns it twice over: B5's projectile half is the first
    /// mechanism on this cart whose *lever is the pad*, so a failure here is a
    /// failure of something a player does rather than of a byte the gate wrote.
    projectile: []const u8,
    /// Everything above was right and the enemies were not drawn. Its own arm,
    /// and this one is the answer to a bug report rather than to a rung: they
    /// had collision, damage and AI, and no picture -- which every rung in this
    /// repository was blind to, because they all grade position, camera, pose or
    /// the background, and the sprite check graded Samus alone.
    enemy_draw: []const u8,
    /// Everything above was right and a kill did not finish. Its own arm because
    /// the mechanism is its own: a corpse that never stops being an enemy is not
    /// a drawing bug and not a collision bug -- the collision is doing exactly
    /// what the slot says, and the slot says the enemy is alive.
    enemy_death: []const u8,
    /// Everything above was right and a bomb was not. Its own arm because the
    /// bombs are their own mechanism -- their own array, pass, draw and
    /// collision -- and a bomb that breaks nothing is not a beam bug.
    bomb: []const u8,
    /// And a missile was not. Step 13a: the loadout the cart boots with, the
    /// toggle and its frame, and the shot that spends one.
    missile: []const u8,
    /// And the HUD was not. Step 13b: the band's picture, the icon, the roll.
    hud: []const u8,
    /// And a Metroid was not. Steps 13c and 13d: the freeze, the coin, and the
    /// kill's effects the enemy oracle cannot see.
    metroid: []const u8,
    /// And the playtest readout was not. Step 14: off by default, toggled by
    /// the shoulders, and showing the room the cart is in.
    readout: []const u8,
    /// And the spider ball was not. Step 14b: gated on its bit, a pixel a
    /// frame, and attached to what it lands on.
    spider: []const u8,
    /// And the save station was not. Step 15a: the contact, the Start arm and
    /// its cooldown, and the record in cartridge RAM.
    save: []const u8,
    /// And the transition's scroll was not. Step 17: the camera walks the
    /// incoming room in and the port has to keep drawing her while it does.
    scroll: []const u8,
    /// And the sound engine was not running. metroid2-audio Step 16b: a smoke
    /// check of SPC RAM, not a grade of what it played.
    sound: []const u8,
    /// The cart did not get as far as a picture.
    stalled: []const u8,
    failed: []const u8,
};

fn bootTest(allocator: std.mem.Allocator, io: std.Io, rom: []const u8, lua: []const u8) !BootTest {
    if (build_options.mesen_path.len == 0) return .no_emulator;
    std.Io.Dir.cwd().access(io, build_options.mesen_path, .{}) catch return .no_emulator;

    const rom_file = ".zig-cache/boot-check.sfc";
    const lua_file = ".zig-cache/boot-check.lua";
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_file, .data = rom }) catch
        return .{ .failed = "could not stage the cart" };
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lua_file, .data = lua }) catch
        return .{ .failed = "could not stage the test script" };
    _ = allocator;

    var child = std.process.spawn(io, .{
        .argv = &.{ build_options.mesen_path, rom_file, "--testrunner", lua_file, "--timeout=90", draw_every_frame },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return .{ .failed = "could not run the emulator" };
    const term = child.wait(io) catch return .{ .failed = "the emulator did not finish" };
    if (term != .exited) return .{ .failed = "the emulator did not exit cleanly" };

    return bootVerdict(term.exited);
}

/// What a `snes boot` exit code says, shared by the clean run and the fault run.
fn bootVerdict(exit: u8) BootTest {
    return switch (exit) {
        0 => .drew,
        10 => .{ .stalled = "the engine hit Fatal: it could not find something it was patched to find" },
        11 => .{ .stalled = "the frame counter never advanced: boot never finished" },
        12 => .{ .stalled = "no character data reached VRAM" },
        13 => .{ .stalled = "the tilemap was never uploaded" },
        14 => .{ .stalled = "the boot record's cell was not seeded into the engine's state" },
        15 => .{ .stalled = "CGRAM does not hold the palette the builder patched in" },
        16 => .{ .stalled = "the frame counter's phase is wrong: NMI ran a different number of times between the boot record's seed and MainLoop's first frame" },
        17 => .{ .stalled = "the play window straddled two screens where a picture was compared" },
        18 => .{ .camera = "never reached the guide offset it holds Samus at while she walks, or drifted off it" },
        19 => .{ .samus = "jumped, but the arc never ran or lifted her no higher than the linear ascent did" },
        255 => .{ .failed = "the emulator timed out: the script never reached a verdict" },
        61 => .{ .samus = "never came to rest after the fall she starts in" },
        62 => .{ .samus = "fell out of the screen she starts on" },
        63 => .{ .samus = "did not leave the ground when jump was pressed, or never came back down" },
        64 => .{ .samus = "jumped without going through the poses a jump goes through" },
        65 => .{ .samus = "did not land back on the row the jump started from" },
        66 => .{ .samus = "moved sideways in one frame by more than a walk step" },
        67 => .{ .samus = "walked faster than the ROM's three pixels every two frames" },
        68 => .{ .camera = "did not follow her up the jump" },
        69 => .{ .samus = "walked into the blocked edge without either stopping or reaching the camera's clamp" },
        70 => .{ .camera = "passed the clamp on the edge the screen blocks" },
        71 => .{ .camera = "changed screens across the edge the screen blocks" },
        72 => .{ .camera = "never crossed when she walked into an opening" },
        73 => .{ .camera = "crossed into the wrong cell" },
        74 => .{ .camera = "jumped: a frame moved it further than a walk step and the guide" },
        75 => .{ .camera = "never came to rest inside the neighbour" },
        76 => .{ .input = "did not read as held on every frame of a hold" },
        77 => .{ .input = "rose more than once during a hold, or never rose at all" },
        78 => .{ .stalled = "the engine was handed a pose it could not run" },
        79 => .{ .camera = "was showing a window Samus was not standing in" },
        121 => .{ .samus = "was not drawn at all: nothing was composed into OAM" },
        122 => .{ .samus = "has a sprite anchor that is not the camera guide with the two Game Boy biases exchanged" },
        123 => .{ .samus = "was drawn with the wrong number of metasprite parts for the sprite id" },
        124 => .{ .samus = "has an OAM entry that is not her anchor with the window offsets on it" },
        20 => .{ .samus = "has an OAM priority her screen's transition word does not give: behind where bit 11 is set, in front elsewhere (00:$3ED5, 01:$4BA1)" },
        149 => .{ .samus = "was drawn on OBP0 in acid or i-frames, or on OBP1 out of them (01:$4DFC, $4B95)" },
        125 => .{ .samus = "is drawn as the same sprite standing and jumping" },
        126 => .{ .samus = "is drawn as the same sprite facing either way" },
        127 => .{ .samus = "covered none of the play window, or an implausible amount of it" },
        130 => .{ .transition = "never ran: the door index was still set long after it was written" },
        131 => .{ .transition = "did not put the warp's map bank in !MapIndex" },
        132 => .{ .transition = "did not put her in the cell the warp's operand names" },
        133 => .{ .transition = "left the camera's screen halves where they were: the re-seat did not happen" },
        134 => .{ .transition = "left Samus's screen halves where they were" },
        135 => .{ .transition = "moved a pixel half: the warp replaced more of a position than the screen" },
        136 => .{ .transition = "took the wrong number of frames: the Game Boy's per-opcode wait and its 64-bytes-a-vblank queue" },
        137 => .{ .transition = "left the room she came from in the tilemap: the incoming edge was not drawn" },
        140 => .{ .item = "never started: the item byte was written and `!ItemStage` stayed idle" },
        141 => .{ .item = "did not land the item bit four frames after the freeze began" },
        142 => .{ .item = "set the wrong bit in `!Items`, or more than one" },
        143 => .{ .item = "let Samus move while the jingle was playing" },
        144 => .{ .item = "ended before the Game Boy's $0160 frames were spent" },
        145 => .{ .item = "never ended: `!ItemStage` never returned to idle" },
        146 => .{ .item = "gave Spring Ball and the ball still would not jump: 00:$1721's branch never fired" },
        147 => .{ .item = "let the ball jump with `!Items` cleared: the branch is not gated on the bit" },
        148 => .{ .item = "let the ball jump with only the Bomb: 00:$1727 tests Spring Ball's bit" },
        138 => .{ .item = "ran a door's `ITEM` or `LOAD_spr` and the characters are not the ROM's: 00:$2618's transfers, or a copy that landed outside vblank" },
        139 => .{ .item = "could not grade a door's characters: the script never finished, or they already held the answer" },
        128 => .{ .transition = "blanked or dimmed a door script that does not fade: the Game Boy shows the room at $93 for every frame of it (Step 24b)" },
        129 => .{ .transition = "blacked out lines of the window during a door script that does not fade: a copy blanked mid-frame, which the register at the frame's end cannot show (Step 24b)" },
        150 => .{ .block = "would be classified against the wrong threshold: `!SolidBeam` is not the beam column of the row the boot door's `SOLIDITY` selects" },
        151 => .{ .block = "never went: its counter passed the empty frame and the four tiles were still the floor" },
        152 => .{ .block = "skipped a crack: one of the two animation frames never reached the tilemap" },
        153 => .{ .block = "was destroyed and Samus went on standing on it: the collision did not follow the picture" },
        154 => .{ .block = "never came back: the reform did not write the four solid tiles" },
        155 => .{ .block = "never freed its slot: the counter ran past $FE" },
        156 => .{ .block = "came back and Samus did not stand on it: the collision did not follow the picture the other way" },
        157 => .{ .block = "off camera was not evicted, or drew a picture on its way out" },
        160 => .{ .projectile = "was in the air before anything fired: the array is not cleared at boot, or Samus never came to rest to fire from" },
        161 => .{ .projectile = "never appeared: the fire button was pressed and no slot was filled" },
        162 => .{ .projectile = "went the wrong way: with no direction held the shot takes the facing, 01:$4EC3's own fallback" },
        163 => .{ .projectile = "never died: it flew into a destructible block and neither of them went" },
        164 => .{ .projectile = "died without breaking the block it hit: `HitBlock`'s respawning arm never reached a slot" },
        165 => .{ .projectile = "hit an enemy and took nothing off it, or took the wrong amount: `weapon_damage`'s first entry" },
        166 => .{ .projectile = "reached one of the bomb arms, which are recorded and not ported: `!PrUnhandled` is no longer $FF" },
        167 => .{ .projectile = "damaged an enemy without stunning it: 02:$4333's `$11` never reached the slot" },
        168 => .{ .projectile = "hit an enemy and flew on: the carry `collision_projectileEnemies` returns is not being acted on" },
        169 => .{ .projectile = "was recorded as a hit and the record was thrown away: the four collision bytes are being cleared on a timer rather than by the enemy that claims them" },
        170 => .{ .enemy_draw = "was never drawn: an active slot put nothing in OAM" },
        171 => .{ .enemy_draw = "was drawn somewhere else: no object landed within a sprite of where the slot says the enemy is" },
        172 => .{ .enemy_draw = "went and its objects stayed: a slot the frame did not use is still holding last frame's picture" },
        175 => .{ .enemy_death = "never happened: the shot was fired at a slot with one beam's worth of health and no explosion flag was ever set" },
        176 => .{ .enemy_death = "set a state nothing handles, or set the wrong one: bit 5 of the flag, the counter 02:$4378 zeroes, or `!EnUnhandledState` recording an arm Step 12e ported" },
        177 => .{ .enemy_death = "left the corpse active: `enemy_animateExplosion` never reached `.noDrop`, so the slot was never freed and the corpse is still a projectile target" },
        178 => .{ .enemy_death = "freed the slot without animating it: not one of the four ids above `!SPR_EXP_NORM` was ever on the screen" },
        179 => .{ .enemy_death = "left a beam-trap behind it: a shot fired through where the corpse was died anyway, which is what a slot that never freed itself does to every later beam" },
        180 => .{ .enemy_death = "left the wrong thing behind: a flag of $11 is an ordinary death leaving small health, and 02:$5705 says which type and which sprite that is" },
        181 => .{ .enemy_death = "left nothing behind four corpses running: the 50% roll is substituted here and `!EnFrame`'s low bit is not alternating between passes" },
        182 => .{ .enemy_death = "left a drop that does not blink: 02:$56AF's `XOR $01` never reached the sprite id" },
        183 => .{ .enemy_death = "left a drop Samus could not collect: the drop half of `enemy_getDamagedOrGiveDrop` was ported in Step 12b and this is the first thing that could reach it" },
        185 => .{ .bomb = "was laid without the Bomb: 01:$53DC's `BIT 0,A` is not gating `samus_layBomb`" },
        186 => .{ .bomb = "never appeared: the ball came to rest, the fire button was pressed with the Bomb held, and no slot was filled" },
        187 => .{ .bomb = "went in with the wrong type, or somewhere other than 01:$5400 and $5405 put it" },
        188 => .{ .bomb = "came out twice for one press: the gate is the rising edge and something is reading the held button" },
        189 => .{ .bomb = "was not drawn, or not first: OAM object 0 is not its first part where the slot says it is" },
        191 => .{ .bomb = "burned for the wrong length: the fuse is 01:$53FB's and the explosion 01:$54C5's, to the frame" },
        192 => .{ .bomb = "left a bomb-only block standing beside it: `BombProbeTile`'s `!BLOCK_BOMB` arm never reached `DestroyBlock`" },
        193 => .{ .bomb = "never reached the respawning block at its right tile: a probe is at the wrong distance, or the arm missed `DestroyRespawningBlock`" },
        194 => .{ .bomb = "did not throw Samus: she is not in the pose `samus_bombPoseTable` gives the ball on the explosion's first frame" },
        195 => .{ .bomb = "took nothing off the enemy beside it, or the wrong amount: the box grows $10 on all four sides for a bomb and the hit is `weapon_damage`'s last entry" },
        196 => .{ .bomb = "did not end when its eight frames were up, or ended before them" },
        197 => .{ .missile = "had nothing to fire from: boot record version 11 did not seed what she carries: health, tanks, both missile counts and both Metroid counts are not `initialSaveFile`'s" },
        198 => .{ .missile = "toggle did not switch the weapon: Select left `!ActiveWeapon` off 00:$2215's missile id, asked for no select sound, or did not switch back to the beam" },
        199 => .{ .missile = "cannon in VRAM is not the sheet the toggle asked for: `LoadGraphics` queued nothing, or the other row, or NMI never moved it" },
        200 => .{ .missile = "toggle did not cost `beginGraphicsTransfer`'s frame: `!CannonHold` was not up for exactly one frame, or the resumed pass ran early" },
        201 => .{ .missile = "never launched: the fire button with missiles selected filled no slot, or filled one with the wrong type" },
        202 => .{ .missile = "did not cost exactly one: 01:$4F35's decrement through decimal mode" },
        203 => .{ .missile = "fired with none left, or asked for no dud: 01:$4F29's empty test" },
        204 => .{ .hud = "band is not the window: a pixel from WY down is not the shade of the BG2 tile named there -- the object characters BG2 reads, BG2's scroll, or the HDMA split that takes BG3 off those lines" },
        205 => .{ .hud = "icon is not in OAM: no part at `drawHudMetroid`'s X and either of its Ys, with either of its sprites' first tile" },
        206 => .{ .hud = "icon's sprite is not `frameCounter` bit 4's, or only one of its two sprites ever showed" },
        207 => .{ .hud = "icon did not rise eight pixels for a major item's jingle or a save station's contact, or rose without either (01:$4B37)" },
        208 => .{ .hud = "displayed health did not roll one unit a frame to the real health and stop there: `AdjustHudValues`" },
        209 => .{ .hud = "roll's tick sound was not asked for on exactly the rolling frames `frameCounter & 3` is zero" },
        // Step 24g: the window raise and the bar under it.
        1 => .{ .hud = "window's Y is not `rWY`'s: `!WinY` must be $80 on a pass with a station's contact or a major item's jingle, $88 on any other the play handler runs (01:$580F-$582C, 00:$3A21), and left alone by the loop that waits for the orb to go (00:$3A63)" },
        2 => .{ .hud = "window did not rise on the screen: in phase 28's jingle, with WY $80 for two passes, a pixel of the status bar's row one row higher is not BG2's first row -- the HDMA split's two counts or BG2's scroll" },
        3 => .{ .hud = "window's second row is not the Game Boy's text: `saveTextTilemap` at boot (05:$40A0), or the door's `item_names` entry after its `ITEM` (00:$26A0)" },
        4 => .{ .hud = "bar under the raised status bar is not the second row's glyphs in the item font, or phase 28's station could not be laid or never raised it" },
        210 => .{ .metroid = "appearing let Samus move, or she could not move once it was over: `MainLoop`'s cutscene arm (00:$050B)" },
        211 => .{ .metroid = "appearing left her in a turnaround: 00:$0514's pose bit 7 clear" },
        212 => .{ .metroid = "appearing let a held pad change her sprite: 01:$4C05 reads the facing, not the pad" },
        213 => .{ .metroid = "appearing stopped Select toggling, or the toggle resumed inside the Samus block" },
        214 => .{ .metroid = "hurt's coin is not `!EnFrame`'s low bit, or the missile landed no hurt" },
        215 => .{ .metroid = "hurt's coin came up the same way on every hurt" },
        216 => .{ .metroid = "was not killed by its last missile: no `metroid_state` $80, no fight flag 2, no dead spawn flag, no explosion sprite or no jingle (02:$6D61)" },
        217 => .{ .metroid = "kill did not take one off both counts in BCD, start the shuffle, or arm `earthquakeCheck`'s countdown the ROM's way: 3 at a threshold, untouched elsewhere (08:$7EBC)" },
        218 => .{ .metroid = "explosion did not freeze Samus, show its six frames over four blasts, and delete the slot and thaw her (02:$5732)" },
        219 => .{ .metroid = "post-death timer did not step once every two frames, on the even ones, to $90 (02:$4039)" },
        220 => .{ .metroid = "restore did not ask for `currentRoomSong` + $11, or asked with no Metroids left (02:$404B)" },
        221 => .{ .metroid = "restore did not end the fight, or the band's count is not the displayed count once the shuffle ends" },
        222 => .{ .metroid = "fight was not ended by a transition with the room's song asked for, or a transition with no fight asked for one (02:$4033)" },
        225 => .{ .metroid = "quake did not start on the tick: `nextEarthquakeTimer` must reach zero on a frame whose counter's low byte is zero, ask for interruption $0E, and last $FF, or $60 with one Metroid left (01:$5873)" },
        226 => .{ .metroid = "quake did not shake and fall the ROM's way: the timer steps on even frames only and not under the door interpreter, and `scrollY` moves by its bit 1 as +1 or -1 (01:$79EF)" },
        228 => .{ .metroid = "door's song during a quake was asked for at once instead of being held in `songRequest_afterEarthquake` (00:$25A2)" },
        229 => .{ .metroid = "quake's end did not clear the driver's byte and ask for the held song, or end the isolated effect with none held (01:$7A0C)" },
        230 => .{ .readout = "was on, owed a redraw, or had drawn something before anyone asked for it: the playtest readout must be off by default" },
        231 => .{ .readout = "did not toggle on L with R, or did not put BG1 on the top border's band and take it off again" },
        232 => .{ .readout = "does not show the map bank, cell and table the cart is in, or did not relatch after a door" },
        233 => .{ .spider = "was entered by Down in the ball without Spider Ball, or the ball never came to rest: the arm is not gated on bit 5 (00:$1788)" },
        234 => .{ .spider = "was not entered by Down in the ball with Spider Ball held (00:$1785 `.activateSpiderBall`)" },
        235 => .{ .spider = "at rest on a floor does not read both bottom corners in contact (`collision_checkSpiderSet`, 00:$1A42)" },
        236 => .{ .spider = "did not roll one pixel a frame on one axis, or did not roll at all (`samus_rollRight.spider`, 00:$1C94)" },
        237 => .{ .spider = "kept rolling with the pad released, or A did not leave it for the ball (00:$109A, 00:$1089)" },
        238 => .{ .spider = "fell or jumped onto a floor and did not attach to it (00:$1233-$1241)" },
        240 => .{ .save = "did not set the contact under a Samus standing on its tile, or no save tile is in the loaded table (00:$1F4F)" },
        241 => .{ .save = "did not take the save on the frame after Start, alone, with the cooldown at $FF and the sound asked for (01:$583A, 00:$3CE2)" },
        242 => .{ .save = "wrote a record that is not the magic and `save.fields` from the live state and the save buffer (01:$7ADF)" },
        243 => .{ .save = "did not save the spawn flags as the Game Boy does: $02 and $FE kept, $04 made $FE, $05 left out (01:$7A83)" },
        244 => .{ .save = "saved a second time on Start while \"COMPLETED\" was showing (01:$582E)" },
        245 => .{ .save = "kept its contact after the cooldown ran out off the station, or a door's transfer did not clear the cooldown (01:$585B, 00:$23F2)" },
        246 => .{ .scroll = "never ended: `TransitionCamera` did not clear the direction, or the warp back never ran (00:$0B44)" },
        247 => .{ .scroll = "lasted fewer than 8 frames, so the phase graded nothing -- the fixture is wrong, not the cart" },
        248 => .{ .scroll = "left Samus's drawn position standing still: `$D03B`/`$D03C` move on every frame of the Game Boy's scroll, and `DrawSamus` is the only writer of them (00:$0550, past the $053E the transition skip jumps to)" },
        159 => .{ .scroll = "froze Samus's animation: every camera frame of the Game Boy's crossing adds 1 to the spin timer `$D072` and 3 to the run cycle's `$D022` (00:$0B44, $0B60), which the run pose alone clamps to zero at $30 (01:$4D77)" },
        250 => .{ .scroll = "never started: the door script phase 27 asked for did not clear its index" },
        249 => .{ .sound = "never ran `init` (`REPLY_ALIVE` at ARAM $3005 is zero) or ran no ticks (`STATS__HOSTED_TICKS` at $0E18): the upload or the shim failed" },
        223 => .{ .metroid = "gate door $04A did not finish, took other than the Game Boy's frames, or landed somewhere other than its warp" },
        224 => .{ .metroid = "gate did not choose the table a Game Boy would at that count: `IF_MET_LESS` is taken at or below its operand (00:$254A)" },
        184 => .{ .enemy_death = "rests its 50% roll on a counter that does not alternate: `!EnFrame` took the same parity on every frame the enemy pass acted, which is the collapse `!FrameCount` was rejected for" },
        158 => .{ .block = "reformed with Samus vulnerable and `!BlkCrush` does not say so: 01:$5739's branch is recorded rather than followed, and a recording nothing reaches is dead code" },
        else => |code| if (code >= 20 and code <= 60)
            .{ .differs = (code - 20) * 8 }
        else if (code >= 80 and code <= 120)
            .{ .scrolled_wrong = (code - 80) * 8 }
        else
            .{ .failed = "the test script exited with an unallocated code" },
    };
}

/// `snes boot`'s fault run, Step 25. Every other emulator rung in the gate has
/// been shown telling a correct cart from a broken one; `snes boot`, which
/// grades more of the ported mechanism than any of them, had not. Each fault
/// takes one mechanism out of the image the clean run just passed, and **is
/// caught only if the phase that grades that mechanism is the one that
/// fails**: a cart that falls over somewhere else shows the rung can fail, not
/// that the phase sees what `docs/conformance.md` says it does.
///
/// Most patches are an `rts` at the routine's entry. Two routines hand
/// something back, and there the patch is their own nothing-to-do exit
/// instead: `RunItemPickup` clears carry, and `WarpDraw` returns no waits,
/// which is the original's path for a direction it does not recognise. A bare
/// `rts` on `RunItemPickup` left carry as it found it, skipped the frame's
/// drawing, and was caught by the HUD (205) -- a broken caller, not a missing
/// pickup.
const BootFault = struct {
    /// The row of `docs/conformance.md`'s audit it answers.
    row: []const u8,
    label: []const u8,
    /// Bytes past the label, for a table entry rather than an entry point.
    offset: u16 = 0,
    patch: []const u8,
    want: std.meta.Tag(BootTest),
};

const boot_faults = [_]BootFault{
    // The screen streamer, which a walk across a boundary runs too: phase 7.
    .{ .row = "5, 5b, 6", .label = "StreamOne", .patch = &.{0x60}, .want = .scrolled_wrong },
    // WARP's strips, and WARP's own frame in the opcode table: phase 8.
    .{ .row = "5, 5b, 6", .label = "WarpDraw", .patch = &.{ 0xC2, 0x30, 0xA9, 0x00, 0x00, 0x60 }, .want = .transition },
    .{ .row = "5, 5b, 6", .label = "OpExtraFrames", .offset = 4, .patch = &.{0x00}, .want = .transition },
    .{ .row = "11", .label = "RunItemPickup", .patch = &.{ 0x18, 0x60 }, .want = .item },
    .{ .row = "12a", .label = "DestroyBlock", .patch = &.{0x60}, .want = .block },
    .{ .row = "12b", .label = "CollideProjEnemies", .patch = &.{0x60}, .want = .projectile },
    .{ .row = "12c", .label = "SamusLayBomb", .patch = &.{0x60}, .want = .bomb },
    .{ .row = "12d", .label = "DrawEnemies", .patch = &.{0x60}, .want = .enemy_draw },
    .{ .row = "12e", .label = "EnemyAnimateExplosion", .patch = &.{0x60}, .want = .enemy_death },
    .{ .row = "12e", .label = "EnemyAnimateDrop", .patch = &.{0x60}, .want = .enemy_death },
    .{ .row = "13a", .label = "ToggleMissiles", .patch = &.{0x60}, .want = .missile },
    // The window raise and the bar, Step 24g: the band never moves (phase 28's
    // picture, 2), and `ITEM`'s name never reaches the row (phase 28, 3).
    .{ .row = "24g", .label = "WriteWindow", .patch = &.{0x60}, .want = .hud },
    .{ .row = "24g", .label = "ItemNameResolve", .patch = &.{0x60}, .want = .hud },
    // Samus's hurt palette, Step 25: acid never moves her to OBP1 (phase
    // 23's acid, 149). The i-frames' half is the `beams` rung's `hurt`, 253.
    .{ .row = "25", .label = "DrawSamus_acidAttr", .patch = &.{ 0xA9, 0x00 }, .want = .samus },
};

/// Why a fault was not caught, or null when it was.
const FaultMiss = union(enum) {
    /// The label is not in `engine.sym`, or the patch runs off the image.
    unplaced,
    /// The bytes there already are the patch, so the cart is not faulted.
    no_op,
    /// The emulator could not be run or did not exit with a code.
    not_run,
    /// The faulted cart passes every phase.
    passes,
    /// Caught, but by a phase other than the one that grades it; the code.
    elsewhere: u8,
};

/// Every fault at once: the runs share nothing but the script, and together
/// they cost the gate about as long as the slowest of them.
fn bootFaultRun(arena: std.mem.Allocator, io: std.Io, rom: []const u8, lua: []const u8, misses: *[boot_faults.len]?FaultMiss) !void {
    const lua_file = ".zig-cache/boot-fault.lua";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lua_file, .data = lua });

    var children: [boot_faults.len]?std.process.Child = @splat(null);
    for (boot_faults, 0..) |f, i| {
        misses[i] = .not_run;
        const at = (snes_inject.symbolOffset(f.label) orelse {
            misses[i] = .unplaced;
            continue;
        }) + f.offset;
        if (at + f.patch.len > snes_inject.image.len) {
            misses[i] = .unplaced;
            continue;
        }
        if (std.mem.eql(u8, rom[at..][0..f.patch.len], f.patch)) {
            misses[i] = .no_op;
            continue;
        }
        const faulted = try arena.dupe(u8, rom);
        @memcpy(faulted[at..][0..f.patch.len], f.patch);
        const rom_file = try std.fmt.allocPrint(arena, ".zig-cache/boot-fault-{s}.sfc", .{f.label});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rom_file, .data = faulted });
        children[i] = std.process.spawn(io, .{
            .argv = &.{ build_options.mesen_path, rom_file, "--testrunner", lua_file, "--timeout=90", draw_every_frame },
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch null;
    }
    for (&children, boot_faults, 0..) |*slot, f, i| {
        var child = slot.* orelse continue;
        const term = child.wait(io) catch continue;
        if (term != .exited) continue;
        const verdict = bootVerdict(term.exited);
        misses[i] = if (verdict == .drew)
            .passes
        else if (std.meta.activeTag(verdict) == f.want)
            null
        else
            .{ .elsewhere = term.exited };
    }
}
