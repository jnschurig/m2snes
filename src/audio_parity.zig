//! The cart's `handleAudio` calls against the original's, over the published run.
//!
//! metroid2-audio Step 16a. The comparison harness (`audiocmp`) proves the
//! ported engine does what bank 4 does *given the same requests on the same
//! ticks*. It cannot say whether the cart sends the same requests on the same
//! ticks: that is the 65816's job, and the cart's `AudioTick` is a stand-in for
//! a call the original makes from a dozen places -- the main loop, `waitOneFrame`
//! and its callers, the death's wait loops, the door's entry wait. A stand-in
//! missing from one of them, or doubled, is a song a tick late for the rest of
//! the run, and nothing else in the gate would notice.
//!
//! So the authority is the running game. The Game Boy side is our own emulator
//! replaying the any% movie (`tas.run`), watched two ways: every execution of
//! `handleAudio_longJump` (00:$2384) closes a tick, every `silenceAudio_longJump`
//! (00:$2390) is slot 12's op, and every write the *game* makes to a request byte
//! -- any code but bank 4's and those two trampolines -- is an op in the tick it
//! falls before. The cart side is the anchored stretch's own cart in Mesen2, with
//! `AudioTick` and `AudioPut` watched the same way. Each stretch is compared for
//! as many frames as the port plays it frame for frame (`Stretch.reached`), since
//! past that the two machines are not playing the same game.
//!
//! Compared: the ops of every tick, in order, and the number of ticks each frame.
//! Slots 9-11 are held apart (`compareState`): Samus's pose and items are the
//! cart's own reading of the game, so the value it last sent has to be the Game
//! Boy's at the same call, and `rDIV` is a clock the two machines do not share
//! (`audio_req.Kind.divider`), so it only has to be sent, every tick, and vary.

const std = @import("std");
const tas = @import("tas.zig");
const harness = @import("gb/harness.zig");
const audio_req = @import("audio_req.zig");
const oracle = @import("oracle.zig");
const inject = @import("snes_inject.zig");
const trace = @import("snes_trace.zig");

pub const Op = audio_req.Op;

/// One frame: the ticks it ran, each the ops the game made since the last.
/// `engine` is the five read-back bytes (`audio_req.read_back`): on the Game
/// Boy, as they stood when the frame's last tick began; on the cart, the reply
/// the frame's logic read.
pub const Frame = struct {
    ticks: []const []const Op,
    engine: ?[audio_req.read_back.len]u8 = null,
};

pub const Window = struct { origin: usize, frames: usize };

// ---- The Game Boy ------------------------------------------------------------

/// 00:$2384 `handleAudio_longJump`, 00:$2390 `silenceAudio_longJump`, and where
/// the trampolines end: 00:$239C is `executeDoorScript`.
pub const handle_audio: u16 = 0x2384;
pub const silence_audio: u16 = 0x2390;
pub const trampolines_end: u16 = 0x239C;
pub const engine_bank: usize = 4;

/// Whether a slot is one the game writes: the request bytes, and the one engine
/// variable it sets. Slots 9-11 are the cart's reading of state, and slot 12 is
/// a call, not a write.
pub fn graded(slot: u8) bool {
    if (slot >= audio_req.slots.len) return false;
    return switch (audio_req.slots[slot].kind) {
        .request, .set, .call => true,
        .game, .divider => false,
    };
}

const Capture = struct {
    gpa: std.mem.Allocator,
    windows: []const Window,
    out: [][]Frame,
    installed: bool = false,
    bus: ?*@import("gb/bus.zig").Bus = null,
    inside: bool = false,
    failed: bool = false,
    cur: std.ArrayList(Op) = .empty,
    ticks: std.ArrayList([]const Op) = .empty,
    engine: ?[audio_req.read_back.len]u8 = null,

    fn hit(ctx: *anyopaque, bank: usize, pc: u16) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.inside = (pc >= 0x4000 and pc < 0x8000 and bank == engine_bank) or
            (pc >= handle_audio and pc < trampolines_end);
        if (pc == handle_audio) {
            // The state the engine reads, as it stands at the call: the cart
            // sends its own reading of it, and `compareState` holds the two
            // together.
            const bus = self.bus.?;
            for (audio_req.slots, 0..) |s, i| {
                if (s.kind != .game) continue;
                self.cur.append(self.gpa, .{ .slot = @intCast(i), .value = bus.read(s.wram) }) catch return self.fail();
            }
            var e: [audio_req.read_back.len]u8 = undefined;
            for (audio_req.read_back, &e) |r, *b| b.* = bus.read(r.wram);
            self.engine = e;
            const t = self.gpa.dupe(Op, self.cur.items) catch return self.fail();
            self.ticks.append(self.gpa, t) catch return self.fail();
            self.cur.clearRetainingCapacity();
        } else if (pc == silence_audio) {
            self.cur.append(self.gpa, .{ .slot = audio_req.slotByName("silenceAudio").?, .value = 0 }) catch return self.fail();
        }
    }

    fn write(ctx: *anyopaque, _: *const @import("gb/bus.zig").Bus, addr: u16, value: u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (self.inside) return;
        for (audio_req.slots, 0..) |s, i| {
            if (s.kind != .request and s.kind != .set) continue;
            if (s.wram != addr) continue;
            self.cur.append(self.gpa, .{ .slot = @intCast(i), .value = value }) catch return self.fail();
        }
    }

    fn fail(self: *Capture) void {
        self.failed = true;
    }

    fn onFrame(ctx: *anyopaque, m: *harness.Machine, frame: usize) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (!self.installed) {
            m.exec = .{ .ctx = self, .hit = hit };
            m.sys.bus.write_watch = .{ .ctx = self, .write = write };
            self.bus = &m.sys.bus;
            self.installed = true;
        }
        if (self.failed) return error.OutOfMemory;
        for (self.windows, self.out) |w, o| {
            if (frame >= w.origin and frame < w.origin + w.frames) {
                o[frame - w.origin] = .{ .ticks = try self.gpa.dupe([]const Op, self.ticks.items), .engine = self.engine };
            }
        }
        self.ticks.clearRetainingCapacity();
        self.engine = null;
    }
};

/// The original's ticks over each window, out of one replay of `movie`.
///
/// The first frame of the replay is spent installing the watches, so a window
/// may not start at frame 0; none of the oracle's anchors do.
pub fn captureGb(
    gpa: std.mem.Allocator,
    rom: []const u8,
    movie: tas.Movie,
    windows: []const Window,
) ![][]Frame {
    var last: usize = 0;
    const out = try gpa.alloc([]Frame, windows.len);
    for (windows, out) |w, *o| {
        if (w.origin == 0) return error.WindowAtFrameZero;
        o.* = try gpa.alloc(Frame, w.frames);
        @memset(o.*, .{ .ticks = &.{} });
        last = @max(last, w.origin + w.frames);
    }
    var cap: Capture = .{ .gpa = gpa, .windows = windows, .out = out };
    var r = try tas.run(gpa, rom, movie, .{
        .max_frames = last + 1,
        .watch_save = false,
        .profile_record = false,
        .watcher = .{ .ctx = &cap, .onFrame = Capture.onFrame },
    });
    r.deinit(gpa);
    return out;
}

// ---- The cart ----------------------------------------------------------------

pub const stem = "audtrace";
pub const cart_name = trace.out_dir ++ "/" ++ stem ++ ".sfc";
pub const lua_name = trace.out_dir ++ "/" ++ stem ++ ".lua";

/// Where in the traced cart's save RAM the event stream goes: past the 8 KiB
/// the game's own save file uses, as a length word and then the bytes.
pub const stream_at: usize = 0x2000;
pub const stream_limit: usize = trace.sram_bytes;

/// The stream's three kinds of byte. A frame's events are followed by `end`;
/// `tick` closes the ops before it; anything else is a slot, and the byte after
/// it the value.
pub const ev_end: u8 = 0xF0;
pub const ev_tick: u8 = 0xF1;
/// Then the five read-back bytes of `!AudReply`, as the pass just ended read them.
pub const ev_engine: u8 = 0xF2;

/// The script: drive the stretch's keys exactly as `snes_trace` does, and log
/// the audio events.
///
/// **Where a frame ends.** A pass of `MainLoop` closes its own tick at the top of
/// the *next* pass, in `AudioFrame`, before `AudioService` -- so the end marker is
/// written on entry to `AudioService`, and everything before it, the closing
/// tick included, is the pass that just ended. Events before the first pass are
/// the boot's (its `silenceAudio` op among them) and are not recorded, because
/// the original made the matching call at power-on, long before any anchor.
pub fn writeCartLua(keys: []const oracle.Key, w: *std.Io.Writer) !void {
    const commit = inject.symbol(oracle.commit_symbol) orelse return error.MissingSymbol;
    const service = inject.symbol("AudioService") orelse return error.MissingSymbol;
    const tick = inject.symbol("AudioTickClose") orelse return error.MissingSymbol;
    const put = inject.symbol("AudioPut") orelse return error.MissingSymbol;
    const val = inject.symbol("VarAudVal") orelse return error.MissingSymbol;
    const reply = inject.symbol("VarAudReply") orelse return error.MissingSymbol;

    try w.print(
        \\-- Generated by src/audio_parity.zig. Do not edit.
        \\local sram = emu.memType.snesSaveRam
        \\local wram = emu.memType.snesWorkRam
        \\local COMMIT, SERVICE, TICK, PUT = 0x{X:0>6}, 0x{X:0>6}, 0x{X:0>6}, 0x{X:0>6}
        \\local VAL, REPLY = 0x{X:0>4}, 0x{X:0>4}
        \\local FRAMES = {d}
        \\local BASE, LIMIT = {d}, {d}
        \\local KEYS = {{
        \\
    , .{ commit, service, tick, put, @as(u16, @truncate(val)), @as(u16, @truncate(reply)), keys.len, stream_at + 4, stream_limit });
    var keybuf: [oracle.mesen_keys_max]u8 = undefined;
    for (keys) |k| try w.print("  {{{s}}},\n", .{oracle.mesenKeys(k, &keybuf)});
    try w.print(
        \\}}
        \\
        \\local i, hold, at, ends, lost = 0, nil, BASE, 0, 0
        \\local function put(b)
        \\  if at < LIMIT then emu.write(at, b, sram); at = at + 1 else lost = 1 end
        \\end
        \\local function finish(code)
        \\  local n = at - BASE
        \\  for k = 0, 3 do emu.write(BASE - 4 + k, (n >> (8 * k)) & 0xFF, sram) end
        \\  emu.stop(code + 2 * lost)
        \\end
        \\
        \\emu.addMemoryCallback(function()
        \\  i = i + 1
        \\  hold = KEYS[i]
        \\end, emu.callbackType.exec, COMMIT, COMMIT, emu.cpuType.snes, emu.memType.snesMemory)
        \\
        \\emu.addMemoryCallback(function()
        \\  if i == 0 then return end
        \\  put(0xF2)
        \\  for k = 6, 10 do put(emu.read(REPLY + k, wram)) end
        \\  put(0xF0)
        \\  ends = ends + 1
        \\  if ends > FRAMES then finish(0) end
        \\end, emu.callbackType.exec, SERVICE, SERVICE, emu.cpuType.snes, emu.memType.snesMemory)
        \\
        \\emu.addMemoryCallback(function()
        \\  if i > 0 then put(0xF1) end
        \\end, emu.callbackType.exec, TICK, TICK, emu.cpuType.snes, emu.memType.snesMemory)
        \\
        \\emu.addMemoryCallback(function()
        \\  if i == 0 then return end
        \\  local s = emu.getState()["cpu.a"] & 0xFF
        \\  if s <= 12 then put(s); put(emu.read(VAL, wram)) end
        \\end, emu.callbackType.exec, PUT, PUT, emu.cpuType.snes, emu.memType.snesMemory)
        \\
        \\emu.addEventCallback(function()
        \\  if hold ~= nil then emu.setInput(hold, 0) end
        \\end, emu.eventType.inputPolled)
        \\
        \\
        \\-- The upload is ~60 frames before the first pass; a cart that never
        \\-- reaches MainLoop stops with 1 rather than timing out.
        \\local watchdog = 0
        \\emu.addEventCallback(function()
        \\  watchdog = watchdog + 1
        \\  if i == 0 and watchdog > 300 then emu.stop(1) end
        \\end, emu.eventType.endFrame)
        \\
    , .{});
}

/// Parse the stream back into frames. The first end marker closes the pass
/// before the first -- the top of pass 0 -- so it is dropped.
pub fn parseStream(gpa: std.mem.Allocator, bytes: []const u8) ![]Frame {
    var frames: std.ArrayList(Frame) = .empty;
    var ticks: std.ArrayList([]const Op) = .empty;
    var cur: std.ArrayList(Op) = .empty;
    var engine: ?[audio_req.read_back.len]u8 = null;
    var first = true;
    var k: usize = 0;
    while (k < bytes.len) : (k += 1) {
        const b = bytes[k];
        if (b == ev_end) {
            if (!first) try frames.append(gpa, .{ .ticks = try ticks.toOwnedSlice(gpa), .engine = engine });
            ticks = .empty;
            engine = null;
            first = false;
        } else if (b == ev_engine) {
            if (k + audio_req.read_back.len >= bytes.len) return error.TruncatedStream;
            engine = bytes[k + 1 ..][0..audio_req.read_back.len].*;
            k += audio_req.read_back.len;
        } else if (b == ev_tick) {
            try ticks.append(gpa, try cur.toOwnedSlice(gpa));
            cur = .empty;
        } else {
            if (k + 1 >= bytes.len) return error.TruncatedStream;
            try cur.append(gpa, .{ .slot = b, .value = bytes[k + 1] });
            k += 1;
        }
    }
    return frames.toOwnedSlice(gpa);
}

/// Run the stretch's cart with the audio script and read the frames back.
pub fn runCart(
    gpa: std.mem.Allocator,
    io: std.Io,
    cart: []const u8,
    keys: []const oracle.Key,
    mesen_path: []const u8,
    home: []const u8,
) ![]Frame {
    const stamped = try gpa.dupe(u8, cart);
    defer gpa.free(stamped);
    try trace.stampSram(stamped);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, trace.out_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = stem ++ ".sfc", .data = stamped });
    var lua: std.Io.Writer.Allocating = .init(gpa);
    defer lua.deinit();
    try writeCartLua(keys, &lua.writer);
    try dir.writeFile(io, .{ .sub_path = stem ++ ".lua", .data = lua.written() });

    const srm = try trace.savePath(gpa, io, home, stem);
    defer gpa.free(srm);
    std.Io.Dir.cwd().deleteFile(io, srm) catch {};

    var child = try std.process.spawn(io, .{
        .argv = &.{ mesen_path, cart_name, "--testrunner", lua_name, "--timeout=180" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    const code: u8 = if (term == .exited) @truncate(term.exited) else 255;
    if (code == 1) return error.CartNeverReachedMainLoop;
    if (code == 2) return error.StreamFull;
    if (code != 0) return error.CartDidNotFinish;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, srm, gpa, .limited(trace.sram_bytes * 2)) catch
        return error.NoSaveFile;
    defer gpa.free(bytes);
    if (bytes.len < stream_at + 4) return error.ShortSaveFile;
    const n = std.mem.readInt(u32, bytes[stream_at..][0..4], .little);
    if (stream_at + 4 + n > bytes.len) return error.ShortSaveFile;
    return parseStream(gpa, bytes[stream_at + 4 ..][0..n]);
}

// ---- The comparison ----------------------------------------------------------

pub const Mismatch = struct {
    /// The cart frame, from the stretch's frame 0.
    frame: usize,
    /// The tick within it, or null when the frames disagree on how many.
    tick: ?usize,
};

pub const Result = struct {
    frames: usize,
    ticks: usize,
    ops: usize,
    first: ?Mismatch,
};

fn opsEqual(a: []const Op, b: []const Op) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and !graded(a[i].slot)) i += 1;
        while (j < b.len and !graded(b[j].slot)) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i].slot != b[j].slot or a[i].value != b[j].value) return false;
        i += 1;
        j += 1;
    }
}

/// Frame by frame, `n` of them: the same number of ticks, and the same graded
/// ops in each, in order.
pub fn compare(gb: []const Frame, cart: []const Frame, n: usize) Result {
    var r: Result = .{ .frames = 0, .ticks = 0, .ops = 0, .first = null };
    const upto = @min(n, @min(gb.len, cart.len));
    for (0..upto) |f| {
        const g = gb[f].ticks;
        const c = cart[f].ticks;
        if (g.len != c.len) {
            r.first = .{ .frame = f, .tick = null };
            return r;
        }
        for (g, c, 0..) |gt, ct, t| {
            if (!opsEqual(gt, ct)) {
                r.first = .{ .frame = f, .tick = t };
                return r;
            }
            r.ticks += 1;
            for (gt) |o| r.ops += @intFromBool(graded(o.slot));
        }
        r.frames += 1;
    }
    return r;
}

/// Slots 9-11, which `compare` leaves out: what the cart tells the engine about
/// the game. Pose and items are sent when they change, so the cart's value at a
/// tick is the last one it sent, and it has to be the Game Boy's at the same
/// call. `rDIV` is a clock the two machines do not share, so its value is not
/// compared: it has to be sent on every tick, and it has to vary, since a
/// Metroid cry takes its pitch from it (Step 14).
pub const StateMiss = struct {
    frame: usize,
    tick: usize,
    slot: u8,
    gb: ?u8,
    /// The cart's value, null when it had sent none yet, or for `rDIV` the
    /// number of times the tick sent it.
    cart: ?u8,
};

pub const StateResult = struct {
    ticks: usize,
    /// Sends of slots 9 and 10 over the frames compared.
    sends: [2]usize,
    /// Distinct `rDIV` values sent.
    divs: usize,
    first: ?StateMiss,
};

pub fn compareState(gb: []const Frame, cart: []const Frame, n: usize) StateResult {
    const pose = audio_req.slotByName("samusPose").?;
    const items = audio_req.slotByName("samusItems").?;
    const div = audio_req.slotByName("rDIV").?;
    var r: StateResult = .{ .ticks = 0, .sends = .{ 0, 0 }, .divs = 0, .first = null };
    var sent: [2]?u8 = .{ null, null };
    var seen = std.StaticBitSet(256).initEmpty();
    const upto = @min(n, @min(gb.len, cart.len));
    for (0..upto) |f| {
        for (gb[f].ticks, cart[f].ticks, 0..) |gt, ct, t| {
            var divs: u8 = 0;
            for (ct) |o| {
                if (o.slot == pose or o.slot == items) {
                    const k = @intFromBool(o.slot == items);
                    sent[k] = o.value;
                    r.sends[k] += 1;
                } else if (o.slot == div) {
                    divs += 1;
                    seen.set(o.value);
                }
            }
            if (divs != 1) {
                r.first = .{ .frame = f, .tick = t, .slot = div, .gb = null, .cart = divs };
                return r;
            }
            for ([_]u8{ pose, items }, 0..) |slot, k| {
                var want: ?u8 = null;
                for (gt) |o| if (o.slot == slot) {
                    want = o.value;
                };
                if (want == null or sent[k] == null or want.? != sent[k].?) {
                    r.first = .{ .frame = f, .tick = t, .slot = slot, .gb = want, .cart = sent[k] };
                    return r;
                }
            }
            r.ticks += 1;
        }
    }
    r.divs = seen.count();
    return r;
}

/// The read-back bytes' lag, `!AudReply`'s contract: the reply the cart's pass
/// `f` reads is the engine after tick `f - 3`, where the Game Boy's pass reads
/// it after `f - 1`. The Game Boy side records the bytes as a tick *begins*, so
/// "after tick `f - 3`" is `gb[f - 2]`. Frames of other than one tick on either
/// side, and the three after them, are skipped: the count is what the contract
/// is stated in.
///
/// **A byte is graded from the first frame the two agree on it.** A handover
/// cart's song starts from its top where the Game Boy's is part way in (boot
/// record version 13), so a byte can differ at first; one that never converges
/// is reported, not failed, and one that converges and then differs fails.
pub const lag: usize = 2;

pub const ReplyMiss = struct { frame: usize, byte: usize, gb: u8, cart: u8 };
pub const ReplyResult = struct {
    frames: usize,
    changes: usize,
    /// Per byte: whether it was graded at all, having converged.
    graded: [audio_req.read_back.len]bool,
    first: ?ReplyMiss,
};

pub fn compareReply(gb: []const Frame, cart: []const Frame, n: usize) ReplyResult {
    var r: ReplyResult = .{ .frames = 0, .changes = 0, .graded = @splat(false), .first = null };
    const upto = @min(n, @min(gb.len, cart.len));
    var settled: usize = 0;
    var last: ?[audio_req.read_back.len]u8 = null;
    for (0..upto) |f| {
        const one = gb[f].ticks.len == 1 and cart[f].ticks.len == 1;
        settled = if (one) settled + 1 else 0;
        if (settled <= lag + 1 or f < lag) continue;
        const want = gb[f - lag].engine orelse continue;
        const got = cart[f].engine orelse continue;
        for (want, got, 0..) |w, g, b| {
            if (w == g) {
                r.graded[b] = true;
            } else if (r.graded[b]) {
                r.first = .{ .frame = f, .byte = b, .gb = w, .cart = g };
                return r;
            }
        }
        if (last) |l| r.changes += @intFromBool(!std.mem.eql(u8, &l, &got));
        last = got;
        r.frames += 1;
    }
    return r;
}

/// A stretch the cart plays frame for frame, by the position oracle, past a
/// frame where the *game* stops being the Game Boy's for a reason that is not
/// the sound: state the handover does not carry and the oracle does not grade.
/// The grade stops at `frame`, and the stop has to happen there: a stretch that
/// diverges earlier fails, and one that agrees through `frame` fails too, since
/// then the gap is closed and the cap is hiding frames that should be graded.
pub const Cap = struct {
    /// The stretch's anchor frame in the movie, which outlives its index.
    origin: usize,
    /// The first frame the two disagree on, from the stretch's frame 0.
    frame: usize,
    /// Why, and the `docs/bug_tracker.md` entry that closes it.
    why: []const u8,
};

pub const caps = [_]Cap{
    .{
        .origin = 4370,
        .frame = 27,
        .why = "the Game Boy's missile hits the Alpha (noise $05) and the cart's does not: the " ++
            "handover boots the enemy fresh, not in the Game Boy's state (docs/bug_tracker.md, " ++
            "\"A handover cart boots the Alpha fresh\")",
    },
};

pub fn capFor(origin: usize) ?Cap {
    for (caps) |c| if (c.origin == origin) return c;
    return null;
}

pub const Verdict = enum {
    /// Agrees for every frame graded.
    exact,
    /// Agrees up to its cap and disagrees on the cap's frame.
    capped,
    /// Disagrees before its cap, or has none.
    diverged,
    /// Agrees on its cap's frame: the gap is closed and the cap must go.
    stale,
};

/// `r` is `compare` run over the stretch's full reach, `reached` frames.
pub fn verdict(r: Result, reached: usize, cap: ?Cap) Verdict {
    const c = cap orelse return if (r.first == null) .exact else .diverged;
    if (r.first) |m| return if (m.frame == c.frame) .capped else if (m.frame < c.frame) .diverged else .stale;
    // Agreed throughout: stale if the reach covered the cap's frame. A stretch
    // that no longer reaches it grades what it does reach.
    return if (reached > c.frame) .stale else .exact;
}

// ---- Tests -------------------------------------------------------------------

test "compareReply grades a byte once it converges, two ticks behind" {
    const one = [_]Op{};
    const t: []const []const Op = &.{&one};
    const e = struct {
        fn f(song: u8, sq: u8) [audio_req.read_back.len]u8 {
            return .{ song, sq, 0, 0, 0 };
        }
    }.f;
    // The Game Boy's song starts on frame 3's tick; square 1 is playing throughout.
    var gb: [10]Frame = undefined;
    var cart: [10]Frame = undefined;
    for (&gb, 0..) |*g, f| g.* = .{ .ticks = t, .engine = e(if (f >= 4) 7 else 0, 1) };
    // The cart's reply is two frames behind, and boots silent: $FF until its
    // own song request lands.
    for (&cart, 0..) |*c, f| c.* = .{ .ticks = t, .engine = e(if (f >= 6) 7 else 0xFF, 1) };
    const r = compareReply(&gb, &cart, 10);
    try testing.expect(r.first == null);
    try testing.expect(r.graded[0] and r.graded[1]);
    // One frame late is caught once the byte has converged.
    cart[9].engine = e(0, 1);
    try testing.expectEqual(@as(usize, 9), compareReply(&gb, &cart, 10).first.?.frame);
    // A byte that never agrees is not graded.
    for (&cart) |*c| c.engine = e(0xFF, 1);
    const n = compareReply(&gb, &cart, 10);
    try testing.expect(n.first == null and !n.graded[0] and n.graded[1]);
}

const testing = std.testing;

test "a cap holds only where the stretch stops, and goes stale when it plays on" {
    const c: Cap = .{ .origin = 1, .frame = 27, .why = "" };
    const at = struct {
        fn f(frame: ?usize) Result {
            return .{ .frames = frame orelse 0, .ticks = 0, .ops = 0, .first = if (frame) |x| .{ .frame = x, .tick = 0 } else null };
        }
    }.f;
    try testing.expectEqual(Verdict.capped, verdict(at(27), 273, c));
    try testing.expectEqual(Verdict.diverged, verdict(at(26), 273, c));
    try testing.expectEqual(Verdict.stale, verdict(at(28), 273, c));
    try testing.expectEqual(Verdict.stale, verdict(at(null), 273, c));
    try testing.expectEqual(Verdict.exact, verdict(at(null), 20, c));
    try testing.expectEqual(Verdict.diverged, verdict(at(27), 273, null));
    try testing.expectEqual(Verdict.exact, verdict(at(null), 273, null));
}

test "the stream parses into frames, dropping the pass before the first" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = [_]u8{
        ev_end, // the top of pass 0: nothing before it counts
        0x00, 0x0F, ev_tick, ev_end, // pass 0: one tick, one op
        ev_tick, 0x03, 0x02, ev_tick, ev_end, // pass 1: two ticks
        ev_end, // pass 2: none
    };
    const frames = try parseStream(arena, &bytes);
    try testing.expectEqual(@as(usize, 3), frames.len);
    try testing.expectEqual(@as(usize, 1), frames[0].ticks.len);
    try testing.expectEqualSlices(Op, &.{.{ .slot = 0, .value = 0x0F }}, frames[0].ticks[0]);
    try testing.expectEqual(@as(usize, 2), frames[1].ticks.len);
    try testing.expectEqual(@as(usize, 0), frames[1].ticks[0].len);
    try testing.expectEqualSlices(Op, &.{.{ .slot = 3, .value = 0x02 }}, frames[1].ticks[1]);
    try testing.expectEqual(@as(usize, 0), frames[2].ticks.len);
}

test "compare finds a tick moved to the next frame, and ignores the cart-only slots" {
    const o0 = [_]Op{.{ .slot = 0, .value = 0x0F }};
    const o0_pose = [_]Op{ .{ .slot = 9, .value = 0x01 }, .{ .slot = 0, .value = 0x0F }, .{ .slot = 11, .value = 0x33 } };
    const t_one = [_][]const Op{&o0};
    const t_one_pose = [_][]const Op{&o0_pose};
    const t_none = [_][]const Op{};
    const t_two = [_][]const Op{ &.{}, &o0 };
    const gb = [_]Frame{ .{ .ticks = &t_one }, .{ .ticks = &t_none } };
    const same = [_]Frame{ .{ .ticks = &t_one_pose }, .{ .ticks = &t_none } };
    const late = [_]Frame{ .{ .ticks = &t_none }, .{ .ticks = &t_one } };
    const split = [_]Frame{ .{ .ticks = &t_two }, .{ .ticks = &t_none } };

    const ok = compare(&gb, &same, 2);
    try testing.expect(ok.first == null);
    try testing.expectEqual(@as(usize, 1), ok.ticks);
    try testing.expectEqual(@as(usize, 1), ok.ops);

    const r = compare(&gb, &late, 2);
    try testing.expectEqual(@as(usize, 0), r.first.?.frame);
    try testing.expect(r.first.?.tick == null);

    const s = compare(&gb, &split, 2);
    try testing.expectEqual(@as(usize, 0), s.first.?.frame);
    try testing.expect(s.first.?.tick == null);
}

test "the graded slots are the game's writes and the call" {
    try testing.expect(graded(audio_req.slotByName("sfxRequest_square1").?));
    try testing.expect(graded(audio_req.slotByName("songInterruptionPlaying").?));
    try testing.expect(graded(audio_req.slotByName("silenceAudio").?));
    try testing.expect(!graded(audio_req.slotByName("samusPose").?));
    try testing.expect(!graded(audio_req.slotByName("rDIV").?));
}

test "compareState holds the cart's last send to the Game Boy's value, and rDIV to one a tick" {
    const pose = audio_req.slotByName("samusPose").?;
    const items = audio_req.slotByName("samusItems").?;
    const div = audio_req.slotByName("rDIV").?;
    const gb0 = [_]Op{ .{ .slot = pose, .value = 1 }, .{ .slot = items, .value = 4 } };
    const gb1 = [_]Op{ .{ .slot = pose, .value = 2 }, .{ .slot = items, .value = 4 } };
    const gb = [_]Frame{ .{ .ticks = &.{&gb0} }, .{ .ticks = &.{&gb1} } };
    const c0 = [_]Op{ .{ .slot = pose, .value = 1 }, .{ .slot = items, .value = 4 }, .{ .slot = div, .value = 9 } };
    const c1 = [_]Op{ .{ .slot = pose, .value = 2 }, .{ .slot = div, .value = 10 } };
    const good = [_]Frame{ .{ .ticks = &.{&c0} }, .{ .ticks = &.{&c1} } };
    const r = compareState(&gb, &good, 2);
    try testing.expect(r.first == null);
    try testing.expectEqual(@as(usize, 2), r.divs);
    try testing.expectEqual([2]usize{ 2, 1 }, r.sends);

    // A pose change the cart did not send.
    const unsent = [_]Op{.{ .slot = div, .value = 10 }};
    const stale = [_]Frame{ .{ .ticks = &.{&c0} }, .{ .ticks = &.{&unsent} } };
    const m = compareState(&gb, &stale, 2).first.?;
    try testing.expectEqual(pose, m.slot);
    try testing.expectEqual(@as(?u8, 1), m.cart);

    // rDIV missing, and doubled.
    const nodiv = [_]Op{ .{ .slot = pose, .value = 2 } };
    const twodiv = [_]Op{ .{ .slot = pose, .value = 2 }, .{ .slot = div, .value = 1 }, .{ .slot = div, .value = 2 } };
    for ([_][]const Op{ &nodiv, &twodiv }, [_]u8{ 0, 2 }) |t, n| {
        const bad = [_]Frame{ .{ .ticks = &.{&c0} }, .{ .ticks = &.{t} } };
        const d = compareState(&gb, &bad, 2).first.?;
        try testing.expectEqual(div, d.slot);
        try testing.expectEqual(@as(?u8, n), d.cart);
    }

    // Items never sent at all.
    const noitems = [_]Op{ .{ .slot = pose, .value = 1 }, .{ .slot = div, .value = 9 } };
    const none = [_]Frame{.{ .ticks = &.{&noitems} }};
    const e = compareState(&gb, &none, 1).first.?;
    try testing.expectEqual(items, e.slot);
    try testing.expectEqual(@as(?u8, null), e.cart);
}
