//! `zig build audioparity` — the cart's `handleAudio` calls against the
//! original's, stretch by stretch over the any% run. See `src/audio_parity.zig`.
//!
//! `zig build audioparity -- [stretch]` grades one stretch, or all of them.
//! Exits 0 when every graded stretch agrees for as far as the port plays it, 1
//! on the first that does not, with both machines' ticks around the frame.

const std = @import("std");
const build_options = @import("build_options");
const rom_mod = @import("rom.zig");
const oracle = @import("oracle.zig");
const tas = @import("tas.zig");
const audio_req = @import("audio_req.zig");
const parity = @import("audio_parity.zig");

/// Frames either side of an anchor the Game Boy side is captured over, for the
/// `--dump` context.
const slack: usize = 2;

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const io = init.io;

    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (build_options.rom_path.len == 0 or build_options.mesen_path.len == 0) {
        try out.print("audioparity: skipped, needs M2_ROM and MESEN (see docs/setup.md)\n", .{});
        return 0;
    }
    var only: ?usize = null;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var dump = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--dump")) dump = true else only = std.fmt.parseInt(usize, a, 10) catch null;
    }

    const rom = try std.Io.Dir.cwd().readFileAlloc(io, build_options.rom_path, gpa, .limited(rom_mod.expected_size * 4));
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, tas.any_percent, gpa, .limited(4 << 20)) catch {
        try out.print("audioparity: skipped, no movie at {s} (tools/get-tas.sh)\n", .{tas.any_percent});
        return 0;
    };
    const movie = try tas.parse(bytes);

    try out.print("grading the anchored stretches (the port's own frame-exact reach)...\n", .{});
    try out.flush();
    const an = try oracle.gradeAnchored(gpa, io, rom, movie, build_options.mesen_path, oracle.anchor_min_frames, 9000, only, .bucket);

    // One replay for every window.
    var windows: std.ArrayList(parity.Window) = .empty;
    var which: std.ArrayList(usize) = .empty;
    for (an.stretches, 0..) |st, i| {
        if (only != null and only.? != i) continue;
        const reached = st.reached() orelse {
            try out.print("     stretch {d:>2}  frame {d:>5}  not graded: {s}\n", .{ i, st.anchor.origin, st.withheld() orelse "no frame count" });
            continue;
        };
        if (reached == 0) {
            try out.print("     stretch {d:>2}  frame {d:>5}  not graded: the port plays none of it\n", .{ i, st.anchor.origin });
            continue;
        }
        try windows.append(gpa, .{ .origin = st.anchor.origin - slack, .frames = st.keys.len + 2 * slack });
        try which.append(gpa, i);
    }
    try out.print("capturing the Game Boy's ticks over {d} window(s)...\n", .{windows.items.len});
    try out.flush();
    const gb = try parity.captureGb(gpa, rom, movie, windows.items);

    const home = init.environ_map.get("HOME") orelse "";
    var failed = false;
    for (which.items, gb) |i, g| {
        const st = an.stretches[i];
        const reached = st.reached().?;
        const cart_bytes = try std.Io.Dir.cwd().readFileAlloc(io, st.cart_path, gpa, .limited(8 << 20));
        const cart = parity.runCart(gpa, io, cart_bytes, st.keys, build_options.mesen_path, home) catch |e| {
            try out.print("stretch {d:>2}  frame {d:>5}  cart run failed: {s}\n", .{ i, st.anchor.origin, @errorName(e) });
            failed = true;
            continue;
        };

        if (dump) {
            try out.print("stretch {d} frame {d}, reached {d}: frames where either side has ops or not one tick\n", .{ i, st.anchor.origin, reached });
            const n = @min(@min(cart.len, g.len - 2 * slack), st.keys.len);
            for (0..n) |f| {
                const gt = g[f + slack].ticks;
                const ct = cart[f].ticks;
                if (!eventful(gt) and !eventful(ct)) continue;
                try out.print("  {d:>5}{s}  gb ", .{ f, if (f >= reached) "*" else " " });
                try printTicks(out, gt);
                try out.print("\n          cart ", .{});
                try printTicks(out, ct);
                try out.print("\n", .{});
            }
        }
        // The cart's frame 0 is the Game Boy's anchor frame: measured on the
        // door trigger's two-tick frame, which lands on the same frame on both
        // machines. Fixed rather than searched, because a search finds the
        // offset that agrees longest, and a cart that is missing a sound
        // agrees longest somewhere else.
        const best_d = slack;
        const best = parity.compare(g[best_d..], cart, reached);
        const cap = parity.capFor(st.anchor.origin);
        // Slots 9-11 over the frames the requests agree on.
        const state = parity.compareState(g[best_d..], cart, best.frames);
        if (state.first) |m| {
            failed = true;
            try out.print("FAIL stretch {d:>2}  frame {d:>5}  frame {d} tick {d}: {s} gb ", .{
                i, st.anchor.origin, m.frame, m.tick, audio_req.slots[m.slot].name,
            });
            if (m.gb) |v| try out.print("{X:0>2}", .{v}) else try out.print("-", .{});
            if (audio_req.slots[m.slot].kind == .divider) {
                try out.print(", sent {d} time(s) in the tick\n", .{m.cart.?});
            } else if (m.cart) |v| try out.print(", cart last sent {X:0>2}\n", .{v}) else try out.print(", cart has sent none\n", .{});
            try out.flush();
            continue;
        }
        if (state.divs < 2 and state.ticks > 60) {
            failed = true;
            try out.print("FAIL stretch {d:>2}  frame {d:>5}  rDIV sent {d} distinct value(s) over {d} ticks: the cries would not vary\n", .{
                i, st.anchor.origin, state.divs, state.ticks,
            });
            try out.flush();
            continue;
        }
        try out.print("ok   stretch {d:>2}  frame {d:>5}  state: {d} tick(s), pose sent {d}x, items {d}x, rDIV {d} distinct\n", .{
            i, st.anchor.origin, state.ticks, state.sends[0], state.sends[1], state.divs,
        });
        // The read-back bytes, over the same frames.
        const rb = parity.compareReply(g[best_d..], cart, best.frames);
        if (rb.first) |m| {
            failed = true;
            try out.print("FAIL stretch {d:>2}  frame {d:>5}  frame {d}: the reply's {s} is {X:0>2}, the Game Boy's {d} tick(s) earlier {X:0>2}\n", .{
                i, st.anchor.origin, m.frame, audio_req.read_back[m.byte].name, m.cart, parity.lag, m.gb,
            });
            // The byte on both machines around it: the Game Boy's as each
            // frame's tick began, and the cart's as each frame read it.
            for ((m.frame -| 6)..@min(m.frame + 4, @min(cart.len, g.len - best_d))) |f| {
                const ge = g[best_d + f].engine;
                const ce = cart[f].engine;
                try out.print("  {s} {d:>5}  ticks gb {d} cart {d}  gb ", .{ if (f == m.frame) ">" else " ", f, g[best_d + f].ticks.len, cart[f].ticks.len });
                if (ge) |e| try out.print("{X:0>2}", .{e[m.byte]}) else try out.print("--", .{});
                try out.print("  cart ", .{});
                if (ce) |e| try out.print("{X:0>2}", .{e[m.byte]}) else try out.print("--", .{});
                try out.print("  gb ops ", .{});
                try printTicks(out, g[best_d + f].ticks);
                try out.print("\n", .{});
            }
            try out.flush();
            continue;
        }
        try out.print("ok   stretch {d:>2}  frame {d:>5}  reply: {d} frame(s) equal the Game Boy's engine {d} ticks earlier, {d} change(s)", .{
            i, st.anchor.origin, rb.frames, parity.lag, rb.changes,
        });
        for (rb.graded, 0..) |ok, b| if (!ok) try out.print("; {s} never converged", .{audio_req.read_back[b].name});
        try out.print("\n", .{});
        switch (parity.verdict(best, reached, cap)) {
            .exact, .diverged => {},
            .capped => {
                try out.print("ok   stretch {d:>2}  frame {d:>5}  {d} frame(s), {d} tick(s), {d} op(s) agree, capped at frame {d} of {d}: {s}\n", .{
                    i, st.anchor.origin, best.frames, best.ticks, best.ops, cap.?.frame, reached, cap.?.why,
                });
                try out.flush();
                continue;
            },
            .stale => {
                failed = true;
                try out.print("FAIL stretch {d:>2}  frame {d:>5}  agrees on its cap's frame {d}: the gap is closed, remove the cap in src/audio_parity.zig and close its bug\n", .{
                    i, st.anchor.origin, cap.?.frame,
                });
                try out.flush();
                continue;
            },
        }
        if (best.first) |m| {
            failed = true;
            try out.print("FAIL stretch {d:>2}  frame {d:>5}  {d} of {d} frame(s) agree, then frame {d}", .{
                i, st.anchor.origin, best.frames, reached, m.frame,
            });
            if (cap) |c| try out.print(" (capped at {d})", .{c.frame});
            if (m.tick) |t| try out.print(" tick {d}", .{t});
            try out.print(":\n", .{});
            const lo = m.frame -| 3;
            const hi = @min(m.frame + 4, @min(cart.len, g.len - best_d));
            for (lo..hi) |f| {
                try out.print("  {s} {d:>5}  gb ", .{ if (f == m.frame) ">" else " ", f });
                try printTicks(out, g[best_d + f].ticks);
                try out.print("\n               cart ", .{});
                try printTicks(out, cart[f].ticks);
                try out.print("\n", .{});
            }
        } else {
            try out.print("ok   stretch {d:>2}  frame {d:>5}  {d} frame(s), {d} tick(s), {d} op(s) agree\n", .{
                i, st.anchor.origin, best.frames, best.ticks, best.ops,
            });
        }
        try out.flush();
    }
    return if (failed) 1 else 0;
}

fn printTicks(out: *std.Io.Writer, ticks: []const []const parity.Op) !void {
    if (ticks.len == 0) return out.print("-", .{});
    for (ticks) |t| {
        try out.print("[", .{});
        var first = true;
        for (t) |o| {
            if (!parity.graded(o.slot)) continue;
            if (!first) try out.print(" ", .{});
            first = false;
            try out.print("{s}={X:0>2}", .{ audio_req.slots[o.slot].name, o.value });
        }
        try out.print("]", .{});
    }
}

fn eventful(ticks: []const []const parity.Op) bool {
    if (ticks.len != 1) return true;
    for (ticks[0]) |o| if (parity.graded(o.slot)) return true;
    return false;
}
