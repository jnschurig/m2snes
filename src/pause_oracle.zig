//! The pause on the Game Boy: the reference the cart's `pause` rung is graded
//! against. 1.0 Step 2a.
//!
//! ## What the original does
//!
//! `tryPausing` (00:$2C79) is the last call of `gameMode_Main`, on every path
//! through it: the normal frame, the cutscene arm, the door's skip and the
//! Queen's stomach. It refuses unless Start's rising edge is Start **alone**
//! (`CP PADF_START`), and then refuses in the Queen's room, facing the screen,
//! in a door's scroll and on a save pillar. Past those it reads the L counter
//! out of `metroidLCounterTable` (00:$203B) by the real count -- zeroed while a
//! quake is queued or shaking -- clears the OAM when `debugFlag` is set,
//! overwrites the first HUD-Metroid object it finds in the OAM buffer with a
//! blank and the one after it with `L`, asks the sound engine to pause, and
//! sets game mode $08.
//!
//! `gameMode_Paused` (00:$2CED) is then the whole of a frame: `bg_palette` and
//! `ob_palette0` flash between $E7 and $93 on bit 4 of `frameCounter`, and
//! Start's rising edge -- **tested with `BIT`**, so Start with anything else
//! still counts -- puts both back to $93, asks for the unpause and sets mode
//! $04. The in-game timer does not run: `waitForNextFrame` ticks it in mode $04
//! only (00:$0333). The status bar draws the L counter in place of the Metroid
//! count while the mode is $08 (01:$49D3).
//!
//! ## How this is used
//!
//! `run` boots the retail ROM cold on our emulator with cartridge RAM zeroed,
//! presses Start on the title for a new game, and waits for the appearance
//! sequence's countdown to start falling. That frame is the anchor on both
//! machines -- `cold boot` grades the countdown frame for frame -- and
//! `script` plays from it. Every frame records what the pause touches.

const std = @import("std");
const harness = @import("gb/harness.zig");
const probe = @import("gb/probe.zig");
const blocks = @import("blocks.zig");
const save = @import("save.zig");
const title_oracle = @import("title_oracle.zig");

const testrom = @import("testrom");

pub const Error = error{ NeverReachedTitle, NeverReachedPlay, NotPerIteration, TooFewSites, TooManySites, OutOfMemory };

// ---- The Game Boy's addresses (M2RoS `ram/`) --------------------------------

pub const game_mode_addr: u16 = 0xFF9B;
pub const frame_counter_addr: u16 = 0xFF97;
pub const samus_y_addr: u16 = 0xFFC0; // pixel, then screen
pub const samus_x_addr: u16 = 0xFFC2;
pub const pose_addr: u16 = 0xD020;
pub const countdown_addr: u16 = 0xD066; // low, then high
pub const bg_palette_addr: u16 = 0xD07E;
pub const ob_palette_addr: u16 = 0xD07F;
pub const igt_minutes_addr: u16 = 0xD098;
pub const igt_hours_addr: u16 = 0xD099;
pub const igt_seconds_addr: u16 = 0xD0A2;
pub const l_counter_addr: u16 = 0xD0A7;
pub const met_real_addr: u16 = 0xD089;
pub const audio_pause_addr: u16 = 0xCFC7;
pub const oam_index_addr: u16 = 0xFF8D;
/// `vramDest_statusBar`, the window's first row.
pub const status_bar_addr: u16 = 0x9C00;
pub const status_bar_len: usize = 20;

pub const mode_title: u8 = 0x01;
pub const mode_main: u8 = 0x04;
pub const mode_paused: u8 = 0x08;

/// `tryPausing` to the end of `gameMode_Paused`'s debug arm: the three
/// `LD (audioPauseControl),A` stores are inside it.
pub const pause_first: u16 = 0x2C79;
pub const pause_end: u16 = 0x2D39;

// ---- The pad ----------------------------------------------------------------

pub const A = title_oracle.A;
pub const B = title_oracle.B;
pub const SELECT = title_oracle.SELECT;
pub const START = title_oracle.START;
pub const RIGHT = title_oracle.RIGHT;
pub const LEFT = title_oracle.LEFT;

pub const Event = title_oracle.Event;

/// The title frame Start is pressed on, for the new game.
pub const title_start_at: u16 = 4;

/// Frames from the anchor. Each line is one branch of `tryPausing` or
/// `gameMode_Paused` the rung asks for.
pub const script = [_]Event{
    .{ .at = 0, .pad = 0 },
    .{ .at = 40, .pad = START }, // facing the screen: refused
    .{ .at = 42, .pad = 0 },
    .{ .at = 330, .pad = RIGHT }, // the countdown is spent: she turns and walks
    .{ .at = 350, .pad = RIGHT | START }, // Start while Right is held: Start alone on the edge, so it pauses
    .{ .at = 352, .pad = RIGHT }, // held through the pause: she must not move
    .{ .at = 420, .pad = 0 },
    // Over 256 frames paused, so `frameCounter` wraps inside it and the
    // timer is shown not ticking.
    .{ .at = 640, .pad = START | A }, // Start with A: `BIT`, so it unpauses
    .{ .at = 642, .pad = 0 },
    .{ .at = 660, .pad = START | LEFT }, // Left and Start on one edge: not Start alone, no pause
    .{ .at = 662, .pad = 0 },
    .{ .at = 680, .pad = START }, // paused again
    .{ .at = 682, .pad = 0 },
    .{ .at = 720, .pad = START }, // and unpaused
    .{ .at = 722, .pad = 0 },
    .{ .at = 760, .pad = 0 },
};

fn buttonsFor(pad: u8) probe.Buttons {
    var b: probe.Buttons = .{};
    b.buttons &= ~@as(u4, @truncate(pad));
    b.dpad &= ~@as(u4, @truncate(pad >> 4));
    return b;
}

// ---- The record ---------------------------------------------------------------

pub const Obj = title_oracle.Obj;
pub const max_objs: usize = 40;

pub const Frame = struct {
    pad: u8,
    mode: u8,
    fc: u8,
    pose: u8,
    x: u16,
    y: u16,
    countdown: u16,
    bgp: u8,
    obp: u8,
    igt_s: u8,
    igt_m: u8,
    igt_h: u8,
    l_counter: u8,
    /// `metroidCountReal`, which indexes the L counter's table.
    met_real: u8,
    /// `hOamBufferIndex`: the objects this frame drew.
    oam_index: u8,
    bar: [status_bar_len]u8,
    /// The OAM buffer's tile bytes, all forty: `tryPausing` searches all of
    /// it, parked slots included.
    tiles: [max_objs]u8,
    /// `audioPauseControl` stores executed during this frame, by value.
    pause_req: u8 = 0,
    unpause_req: u8 = 0,
};

/// `LD (audioPauseControl),A` inside `tryPausing` and `gameMode_Paused`, as
/// the addresses of the stores. Read off the ROM, not written down.
pub fn storeSites(rom: []const u8) ![3]u16 {
    const pattern = [_]u8{ 0xEA, @truncate(audio_pause_addr), @truncate(audio_pause_addr >> 8) };
    var out: [3]u16 = undefined;
    var n: usize = 0;
    var pc: u16 = pause_first;
    while (pc + pattern.len <= pause_end) : (pc += 1) {
        if (!std.mem.eql(u8, rom[pc..][0..pattern.len], &pattern)) continue;
        if (n == out.len) return error.TooManySites;
        out[n] = pc;
        n += 1;
    }
    if (n != out.len) return error.TooFewSites;
    return out;
}

/// `waitForNextFrame` (00:$031C): the end of one pass of `mainGameLoop`, and
/// the one place `frameCounter` moves. The record is taken here, so frame `t`
/// is iteration `t` of the game's own loop and not an LCD frame: the Game Boy
/// runs long on some frames -- the pause's own frame among them, with its OAM
/// search -- and an LCD-frame sample lands mid-iteration there.
pub const wait_for_next_frame: u16 = 0x031C;

/// Everything the exec watch and the pad callback share.
const Runner = struct {
    m: *harness.Machine,
    events: []const Event,
    sites: [3]u16,
    out: std.ArrayList(Frame) = .empty,
    a: std.mem.Allocator,
    /// Iterations recorded since the anchor; null before it.
    t: ?usize = null,
    pad: u8 = 0,
    pause: u8 = 0,
    unpause: u8 = 0,
    last_fc: ?u8 = null,
    err: ?anyerror = null,
    done: bool = false,

    fn hit(ctx: *anyopaque, b: usize, pc: u16) void {
        const self: *Runner = @ptrCast(@alignCast(ctx));
        if (b != 0 or pc >= 0x4000 or self.done) return;
        for (self.sites) |s| {
            if (s != pc) continue;
            // A holds the value about to be stored.
            switch (self.m.sys.cpu.a) {
                1 => self.pause +%= 1,
                2 => self.unpause +%= 1,
                else => {},
            }
        }
        if (pc != wait_for_next_frame) return;
        self.iterate() catch |e| {
            self.err = e;
            self.done = true;
        };
    }

    fn iterate(self: *Runner) !void {
        // Each record is one `frameCounter` step: the counter moves at the end
        // of `waitForNextFrame`, so it has moved exactly once since the last.
        const fc = self.m.read(frame_counter_addr);
        if (self.last_fc) |l| if (fc != l +% 1) return error.NotPerIteration;
        self.last_fc = fc;
        if (self.t == null) {
            if (self.m.read(game_mode_addr) != mode_main) return;
            self.t = 0;
        }
        var f = record(self.m, self.pad);
        f.pause_req = self.pause;
        f.unpause_req = self.unpause;
        try self.out.append(self.a, f);
        self.pause = 0;
        self.unpause = 0;
        const t = self.t.? + 1;
        self.t = t;
        if (t > self.events[self.events.len - 1].at) {
            self.done = true;
            return;
        }
        // The pad the next iteration's `main_readInput` reads.
        self.pad = title_oracle.padAt(self.events, t);
    }

    fn keys(ctx: *anyopaque, _: u64) probe.Buttons {
        const self: *Runner = @ptrCast(@alignCast(ctx));
        return buttonsFor(self.pad);
    }
};

fn record(m: *harness.Machine, pad: u8) Frame {
    var f: Frame = .{
        .pad = pad,
        .mode = m.read(game_mode_addr),
        .fc = m.read(frame_counter_addr),
        .pose = m.read(pose_addr),
        .x = m.readWord(samus_x_addr),
        .y = m.readWord(samus_y_addr),
        .countdown = m.readWord(countdown_addr),
        .bgp = m.read(bg_palette_addr),
        .obp = m.read(ob_palette_addr),
        .igt_s = m.read(igt_seconds_addr),
        .igt_m = m.read(igt_minutes_addr),
        .igt_h = m.read(igt_hours_addr),
        .l_counter = m.read(l_counter_addr),
        .met_real = m.read(met_real_addr),
        .oam_index = m.read(oam_index_addr),
        .bar = undefined,
        .tiles = undefined,
    };
    for (0..status_bar_len) |i| f.bar[i] = m.read(status_bar_addr + @as(u16, @intCast(i)));
    for (0..max_objs) |i| f.tiles[i] = m.read(0xC000 + @as(u16, @intCast(i)) * 4 + 2);
    return f;
}

pub const Run = struct {
    frames: []Frame,

    pub fn deinit(r: *Run, a: std.mem.Allocator) void {
        a.free(r.frames);
    }
};

/// Boot cold, start a new game, and play `events` from the anchor: the first
/// iteration of `mainGameLoop` to end in mode $04. Frame `t` of the result is
/// the state at the end of anchor iteration `t`, which read `padAt(events, t)`;
/// frame 0 is the anchor itself, with nothing held.
pub fn run(a: std.mem.Allocator, rom: []const u8, events: []const Event) !Run {
    var m = try harness.bootFrom(a, rom, null);
    defer m.deinit();

    var waited: usize = 0;
    while (m.read(game_mode_addr) != mode_title) : (waited += 1) {
        if (waited > 600) return error.NeverReachedTitle;
        _ = try m.runFrames(1, .{});
    }
    _ = try m.runFrames(title_start_at, .{});
    _ = try m.runFrames(2, buttonsFor(START));

    var r: Runner = .{ .m = &m, .events = events, .sites = try storeSites(rom), .a = a };
    errdefer r.out.deinit(a);
    m.exec = .{ .ctx = &r, .hit = Runner.hit };
    var lcd: usize = 0;
    while (!r.done) : (lcd += 1) {
        if (lcd > 900 + 2 * @as(usize, events[events.len - 1].at)) return error.NeverReachedPlay;
        _ = try m.runScript(1, &r, Runner.keys);
    }
    if (r.err) |e| return e;
    return .{ .frames = try r.out.toOwnedSlice(a) };
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

/// The first frame in `frames` from `from` on whose mode is `mode`.
fn firstMode(frames: []const Frame, from: usize, mode: u8) ?usize {
    for (frames[from..], from..) |f, t| if (f.mode == mode) return t;
    return null;
}

test "the script does on the Game Boy what each of its lines says" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var r = try run(a, rom, &script);
    defer r.deinit(a);
    const f = r.frames;
    try testing.expectEqual(@as(usize, script[script.len - 1].at + 1), f.len);

    // Start facing the screen: refused.
    try testing.expectEqual(@as(?usize, 350), firstMode(f, 0, mode_paused));
    try testing.expectEqual(save.appearance(rom).?.pose, f[40].pose);
    // Start while Right is held pauses on the frame it is read, with one
    // request for the pause sound and the L counter read.
    try testing.expectEqual(@as(u8, 1), f[350].pause_req);
    try testing.expectEqual(rom[0x203B + @as(usize, f[350].met_real)], f[350].l_counter);
    // Held through the pause she does not move, and the timer does not run
    // while the counter wraps under it.
    var wrapped = false;
    for (f[351..640]) |g| {
        try testing.expectEqual(mode_paused, g.mode);
        try testing.expectEqual(f[350].x, g.x);
        try testing.expectEqual(f[350].igt_s, g.igt_s);
        if (g.fc == 0) wrapped = true;
    }
    try testing.expect(wrapped);
    // The flash: both palettes, on bit 4 of the counter.
    for (f[351..640]) |g| {
        const want: u8 = if (g.fc & 0x10 != 0) 0x93 else 0xE7;
        try testing.expectEqual(want, g.bgp);
        try testing.expectEqual(want, g.obp);
    }
    // The blank and the `L` over the icon's two objects.
    const n = f[350].oam_index / 4;
    try testing.expect(std.mem.indexOf(u8, f[350].tiles[0..n], &.{ 0x36, 0x0F }) != null);
    try testing.expect(std.mem.indexOf(u8, f[349].tiles[0..n], &.{ 0x36, 0x0F }) == null);
    // Start with A unpauses: `BIT`, not `CP`.
    try testing.expectEqual(mode_main, f[640].mode);
    try testing.expectEqual(@as(u8, 1), f[640].unpause_req);
    try testing.expectEqual(@as(u8, 0x93), f[640].bgp);
    // Start with Left on one edge: refused, because the pause's test is `CP`.
    try testing.expectEqual(@as(?usize, 680), firstMode(f, 641, mode_paused));
    // Out again with Start alone.
    try testing.expectEqual(@as(?usize, 720), firstMode(f, 681, mode_main));
    // And the timer runs again once the mode is $04.
    var ticked = false;
    for (f[721..]) |g| if (g.igt_s != f[720].igt_s) {
        ticked = true;
    };
    try testing.expect(ticked);
}

test "the three stores are the ROM's, and the table is where tryPausing reads it" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    try testing.expectEqual([3]u16{ 0x2CE5, 0x2D13, 0x2D31 }, try storeSites(rom));
    // `LD HL,$203B` at 00:$2C94, then `LD A,(metroidCountReal)`.
    try testing.expectEqualSlices(u8, &.{ 0x21, 0x3B, 0x20, 0xFA, 0x89, 0xD0 }, rom[0x2C94..][0..6]);
}
