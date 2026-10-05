//! Grading the stretches the port cannot be graded frame-exactly on.
//!
//! `01-requirements` (D1/F10) asks for the published run to be the oracle, and
//! `oracle.zig` grades it the only way a comparison of *play* can be graded:
//! frame-exactly, position and camera, from a handover of control. That answer
//! is the right one for the frames the player is playing and the wrong one for
//! the frames the player is not. A cutscene, a room transition and a menu are
//! sequences the game runs to a script of its own; a port that reproduces one
//! four frames late is not wrong in the way a port that walks into a wall is
//! wrong. Step 15b's plan says so in one line: **grade play exactly, cutscenes
//! by length.**
//!
//! So this file measures durations. For every non-playable stretch of the run
//! it reports the Game Boy's frame count, the port's frame count, and the
//! second as a percentage of the first. `tolerance_percent` is what counts as
//! agreement. A stretch the port does not have at all is reported as **absent**
//! rather than as 0%, because those are different findings: 0% would say the
//! port ran the sequence instantly, and absent says it never ran one.
//!
//! ## What a non-playable stretch is, measured rather than asserted
//!
//! There is no flag in this game's RAM that says "the player is not playing",
//! or none we have read. Three signals in the trace stand in for one, and each
//! is a predicate over frames rather than a judgement:
//!
//!   - **A cutscene** is the opening, and `tas.findOpening` already locates it:
//!     Samus is placed, and then held in the pose she was placed in while the
//!     movie presses buttons at her. 320 frames, and the number is the game's
//!     rather than one movie's because both published runs give it to the
//!     frame. Phase 0a has no pose $13, so the port's side of this one was
//!     settled by Step 15b's first sub-task: absent.
//!   - **A transition** is a room change: two adjacent frames whose map bank or
//!     screen cell differ. Its duration is the frames from the change until her
//!     position moves again, and changes that fall inside one another's hold
//!     are one stretch, not several -- crossing a boundary leftwards bounces
//!     her back across it first, which is two room changes and one transition.
//!   - **A menu** is a frame the movie holds Start or Select. Those are two of
//!     the three bits `oracle.unsupportedBits` names, so the port has no key
//!     for them and cannot be asked; a menu's port side is `unrepresentable`,
//!     which is a different answer from `absent` for the same reason absent is
//!     a different answer from 0%.
//!
//! ## The two kinds of transition, and why they are separated
//!
//! Measured over the any% run to its horizon, a room change is one of two
//! things and they are not the same sequence:
//!
//!   - A **warp**. Her position jumps a whole screen or more in one frame -- at
//!     movie frame 703 it goes $07F3,$0784 to $03F3,$0484 -- and the game then
//!     holds her for five or six frames. This is a door, and Phase 0a has none.
//!   - A **scroll**. Her position stays continuous and the cell index changes
//!     because she walked across it. Most of these cost one frame; the ones
//!     that go left or up cost about twenty, because the game bounces her back
//!     off the boundary and holds her while it draws the screen she is entering.
//!
//! `warp_step` is where the two are cut apart, and it is measured: the largest
//! single-frame step anywhere in the run that is *not* a room change is
//! `measureLongestStep`'s answer, and a test pins the threshold above it.
//!
//! ## Where the port's number comes from
//!
//! The same detector, run over the cart's own trace. `snes_trace.zig` already
//! records map, cell and position per frame out of a headless Mesen2 run, so
//! `transitions` takes a `[]Step` and neither machine gets a bespoke rule --
//! which matters here more than usual, because the whole claim being made is
//! that two durations are comparable.
//!
//! Each stretch is anchored **just before itself**: the latest frame before it
//! at which a cart can honestly be built, found the way `oracle.settleAnchors`
//! finds one after a handover, and searched backwards because a transition's
//! anchor has to be in the room she is leaving. Giving each transition its own
//! boot record is the same argument the re-anchor makes: a port that cannot
//! reach a stretch on its own has still either got the sequence or not, and
//! asking is better than inferring.
//!
//! Two honest non-answers fall out of that and are reported as themselves:
//! `no_boot`, when no frame before the stretch produces a cart whose world
//! matches, and `diverged`, when the port left the original's course between
//! its anchor and the stretch -- in which case the frames after that are not
//! the port's duration for anything.

const std = @import("std");
const tas = @import("tas.zig");
const oracle = @import("oracle.zig");
const trace = @import("snes_trace.zig");
const inject = @import("snes_inject.zig");
const convert = @import("snes_convert.zig");
const map_mod = @import("map.zig");

pub const Error = error{OutOfMemory} || oracle.Error;

/// What counts as the port agreeing with the original about a duration.
///
/// Two percent, from Step 15b. At the durations this run actually contains it
/// is exactness dressed as a tolerance -- 2% of a five-frame transition is a
/// tenth of a frame -- and it only starts to mean anything on the 320-frame
/// opening, where it allows six. That is worth saying out loud rather than
/// discovering later: for transitions this gate is exact, and the tolerance is
/// there for the sequences Phase 0b and 0c bring.
pub const tolerance_percent: f64 = 2.0;

/// How many stretches the gate insists come back with a duration from both
/// machines, and how many of those insist on agreeing.
///
/// **Both are floors and both are meant to go up.** Measured 2026-09-01 on the
/// any% run: 15 stretches produce a number on both sides and 11 of those agree
/// inside `tolerance_percent`. The four that differ are findings, not noise --
/// the port crosses a boundary leftwards in one frame where the original spends
/// twenty-one, and it holds her for forty-odd frames at two boundaries where
/// the original holds her for one -- and they are what the floors leave room to
/// fix. Raise these whenever the numbers go up, the way `movie_gate_floor` is
/// raised.
///
/// **Raised 2026-09-05 to 17 and 13, and not by anything about durations.** B12
/// fixed the tileset assignment for map 3 cells $51 and $71, which made two
/// more of the run's stretches boot -- so two more stretches produce a number
/// on both sides, and both of them agree. A rung moved because a different
/// rung's blocker was removed, which is the shape of most of what this cycle
/// is expected to do.
/// **Raised 2026-09-07 to 19 and 17, by Step 5b's transition duration.** Four
/// stretches changed answer and all four are the same fact. Two of the run's
/// leftward crossings are not scrolls at all -- they are door transitions with
/// a script that has no `WARP`, so the room changes because the camera scrolls
/// into the next screen of the same bank and the position never jumps. The
/// port had no transition, so it crossed them in one frame where the Game Boy
/// spends twenty-one; it now spends twenty-one too, and `warp 2721`'s
/// twenty-five agree as well. **Agreeing went 13 -> 17 and nothing regressed.**
///
/// **Raised 2026-09-07 to 28 and 28, by Step 6's `SeedWindow`.** The two
/// stretches this comment had named since 2026-09-01 -- `scroll 2563` and
/// `scroll 3316`, where the port held her for the whole 48-frame search window
/// and the Game Boy crossed in one -- were never about durations either. A
/// cart booted from a mid-run record had one screen's tilemap in all 1024
/// slots of `!TilemapBuf`, so the far side of every screen boundary was the
/// boot screen's own edge instead of the neighbour's, and she walked into a
/// wall the original does not have. Seeding the whole 256-pixel window from
/// the world at boot is what the record was missing.
///
/// Nine more stretches became comparable in the same change, for the same
/// reason: a stretch whose anchor sat near a boundary used to leave the run
/// within a frame or two of booting. **Compared went 19 -> 28 and every one of
/// the 28 agrees**, which is the first time this rung has had nothing
/// outstanding. The next raise will come from stretches that still cannot be
/// booted at all, not from stretches that disagree.
pub const gate_compared_floor: usize = 28;
pub const gate_agreeing_floor: usize = 28;

/// How many stretches the whole census contains, on the any% run to its
/// horizon: 1 cutscene, 10 warps, 47 scrolls and 2 menu presses.
///
/// A gate on the Game Boy side alone, which needs no emulator. It is not a
/// floor -- it is an equality, because a change in this number means the
/// detector changed its mind about what a non-playable stretch is, and that is
/// something to look at whichever direction it moved in.
pub const census_stretches: usize = 60;

/// The movie bits that open something instead of moving her: Start and Select.
///
/// `oracle.supported_input_bits` is the other side of the same coin -- these
/// are two of the three bits it leaves out, and the third is B.
pub const menu_bits: u8 = 0x04 | 0x08;

/// How far Samus's world position may move in one frame and still be her
/// moving rather than the game moving her.
///
/// **Measured.** `measureLongestStep` reports the largest single-frame step
/// over the any% run to its horizon that is not a room change; it is a handful
/// of pixels, and a warp moves her by at least one whole screen -- $100 in the
/// `(screen << 8) | pixel` encoding both machines use. The threshold is a
/// screen because that is the unit the game warps in, and a test asserts the
/// measured maximum stays far below it rather than trusting this comment.
pub const warp_step: u32 = 0x100;

pub const Kind = enum {
    cutscene,
    warp,
    scroll,
    menu,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .cutscene => "cutscene",
            .warp => "warp",
            .scroll => "scroll",
            .menu => "menu",
        };
    }
};

/// The world is a 16x16 grid of 256-pixel screens, and it wraps.
///
/// **Measured, at movie frame 6106.** Walking right out of column $F the game's
/// own screen byte reads $10 for a few frames and then snaps to $00, so a raw
/// position goes $101B to $001D between two frames of an unbroken roll -- 4094
/// pixels, which is what the first run of `measureLongestStep` reported and
/// what sent this to be looked at. `tas.Room.of` masks the screen byte to the
/// grid already; a position compared without the same mask disagrees with the
/// room it is in. So both axes are kept modulo the grid and distances are
/// circular over it.
pub const world_mask: u16 = 0x0FFF;
pub const world_span: i32 = 0x1000;

/// One frame of a track, in the units both machines agree on.
///
/// `(screen << 8) | pixel` on each axis masked to the grid, which is
/// `room.Placement`'s arithmetic on the Game Boy and `VarSamusX`/`VarSamusY`
/// on the cart.
pub const Step = struct {
    room: tas.Room,
    x: u16,
    y: u16,

    pub fn at(room: tas.Room, x: u16, y: u16) Step {
        return .{ .room = room, .x = x & world_mask, .y = y & world_mask };
    }

    fn samePlace(a: Step, b: Step) bool {
        return a.x == b.x and a.y == b.y;
    }
};

/// One non-playable stretch, on whichever machine produced the track.
pub const Stretch = struct {
    kind: Kind,
    /// The frame the game took control, in the track's own numbering.
    start: u32,
    /// Frames it held her. Zero only for a menu press the game did not open
    /// anything for, which is a measurement worth keeping rather than a
    /// stretch to drop.
    frames: u32,
    from: tas.Room,
    to: tas.Room,
    /// The largest single-frame position step across this stretch's own room
    /// changes. What separates a warp from a scroll; zero for the kinds that
    /// have no room change.
    jump: u32 = 0,
};

/// Every transition in a track, in order.
///
/// A track is one entry per frame, starting at frame `first`. Both machines go
/// through this function; see the module comment for why that is the point.
pub fn transitions(
    allocator: std.mem.Allocator,
    track: []const Step,
    first: u32,
) Error![]Stretch {
    var out: std.ArrayList(Stretch) = .empty;
    errdefer out.deinit(allocator);
    if (track.len < 2) return out.toOwnedSlice(allocator);

    var i: usize = 1;
    while (i < track.len) {
        if (track[i].room.eql(track[i - 1].room)) {
            i += 1;
            continue;
        }

        const from = track[i - 1].room;
        var last = i;
        var jump = stepSize(track[i - 1], track[i]);
        var end = firstMoveAfter(track, last);

        // Absorb any further room change that falls inside this one's hold. A
        // leftward crossing is two changes and one transition: the game bounces
        // her back over the boundary, holds her while it draws, and then lets
        // her across for real.
        var k = last + 1;
        while (k <= end and k < track.len) : (k += 1) {
            if (track[k].room.eql(track[k - 1].room)) continue;
            last = k;
            jump = @max(jump, stepSize(track[k - 1], track[k]));
            end = firstMoveAfter(track, last);
        }

        try out.append(allocator, .{
            .kind = if (jump >= warp_step) .warp else .scroll,
            .start = first + @as(u32, @intCast(i)),
            .frames = @intCast(end - i),
            .from = from,
            .to = track[last].room,
            .jump = jump,
        });
        i = @max(end, last + 1);
    }
    return out.toOwnedSlice(allocator);
}

/// The first index after `at` whose position differs from the one at `at`, or
/// the track's end when she never moves again inside it.
fn firstMoveAfter(track: []const Step, at: usize) usize {
    var k = at + 1;
    while (k < track.len) : (k += 1) {
        if (!track[k].samePlace(track[at])) return k;
    }
    return track.len;
}

/// `tas.Room.of`'s arithmetic over a map index and a world position, for the
/// side that has no `tas.Sample` to hand it.
pub fn roomAt(map_index: u8, x: u16, y: u16) tas.Room {
    return .{
        .map_bank = map_index + map_mod.first_bank,
        .cell = @intCast(((y >> 8) & 0x0F) << 4 | ((x >> 8) & 0x0F)),
    };
}

fn stepSize(a: Step, b: Step) u32 {
    return @max(axisStep(a.x, b.x), axisStep(a.y, b.y));
}

/// Distance on one axis, the short way round the grid. See `world_mask`.
fn axisStep(a: u16, b: u16) u32 {
    const d: i32 = @intCast(@abs(@as(i32, b) - @as(i32, a)));
    return @intCast(@min(d, world_span - d));
}

/// The Game Boy's track, out of a replay.
pub fn trackOf(allocator: std.mem.Allocator, samples: []const tas.Sample, horizon: u32) Error![]Step {
    const n = @min(samples.len, horizon);
    const out = try allocator.alloc(Step, n);
    for (out, samples[0..n]) |*o, s| o.* = Step.at(tas.Room.of(s), s.samus_x, s.samus_y);
    return out;
}

/// The largest single-frame step in a track that is not a room change.
///
/// The evidence behind `warp_step`, and the reason it is a function rather than
/// a comment: a threshold nobody re-measures is a threshold that stops being
/// true when the frame boundary moves five scanlines.
///
/// `first` skips the title screen, where the trace's position fields are zero
/// because the game has not placed her: the frame she is placed on is a step of
/// two thousand pixels out of nowhere, and it is not a step she took.
pub const LongestStep = struct { pixels: u32, frame: u32 };

pub fn measureLongestStep(track: []const Step, first: u32) LongestStep {
    var most: u32 = 0;
    var at: u32 = 0;
    var i: usize = @max(1, first);
    while (i < track.len) : (i += 1) {
        if (!track[i - 1].room.eql(track[i].room)) continue;
        const d = stepSize(track[i - 1], track[i]);
        if (d <= most) continue;
        most = d;
        at = @intCast(i);
    }
    return .{ .pixels = most, .frame = at };
}

/// The whole census of non-playable stretches on the Game Boy, in frame order.
///
/// The opening first, then transitions and menus interleaved by start frame.
pub fn census(allocator: std.mem.Allocator, r: tas.Run, horizon: u32) Error![]Stretch {
    var out: std.ArrayList(Stretch) = .empty;
    errdefer out.deinit(allocator);

    // The opening's landmarks, kept so the transitions inside it are not
    // reported twice: the game warping her into the landing site is a room
    // change, and it is the first frame of the cutscene rather than a
    // transition of its own.
    var opening_ends: u32 = 0;
    if (tas.findOpening(r.track())) |op| {
        if (op.placed < horizon) {
            opening_ends = op.control;
            try out.append(allocator, .{
                .kind = .cutscene,
                .start = op.placed,
                .frames = op.holdFrames(),
                .from = tas.Room.of(r.samples[op.placed]),
                .to = tas.Room.of(r.samples[op.placed]),
            });
        }
    } else |_| {}

    const track = try trackOf(allocator, r.samples, horizon);
    defer allocator.free(track);

    const ts = try transitions(allocator, track, 0);
    defer allocator.free(ts);
    for (ts) |t| {
        if (t.start <= opening_ends) continue;
        try out.append(allocator, t);
    }

    // Menus, folded in. A press is a stretch only for the frames it cost:
    // `firstMoveAfter` from the frame *after* the press, so a press she walks
    // straight through reports the zero frames it took rather than being
    // dropped -- "this run contains no menu" is a finding, and an empty list
    // does not say it.
    var i: usize = 1;
    while (i + 1 < track.len and i < r.samples.len) : (i += 1) {
        const held = r.samples[i].input & menu_bits;
        if (held == 0 or (r.samples[i - 1].input & menu_bits) != 0) continue;
        if (i <= opening_ends) continue;
        const end = firstMoveAfter(track, i);
        try out.append(allocator, .{
            .kind = .menu,
            .start = @intCast(i),
            .frames = @intCast(end - i - 1),
            .from = track[i].room,
            .to = track[i].room,
        });
    }

    const items = try out.toOwnedSlice(allocator);
    std.mem.sort(Stretch, items, {}, lessByStart);
    return items;
}

fn lessByStart(_: void, a: Stretch, b: Stretch) bool {
    return a.start < b.start;
}

// ---- The port's side --------------------------------------------------------

/// What the cart did with one stretch.
///
/// Four of the five are non-answers, and they are named rather than folded into
/// a zero because they are different findings. `absent` is the one the plan
/// asks for by name: the port ran the same frames from the same place and never
/// held her, so it does not have the sequence at all.
pub const Side = union(enum) {
    /// The port has the stretch, and held her for this many frames.
    frames: u32,
    /// Not asked: `measure`'s `limit` stopped before this row. The default, so
    /// a row nothing looked at cannot be mistaken for one that was looked at
    /// and came back empty-handed.
    unmeasured,
    /// Measured: the cart was booted before the stretch, handed the same
    /// inputs, and produced no stretch there.
    absent,
    /// A cart was built at every candidate frame before the stretch and none
    /// of their worlds matched the original's. `matched`/`compared` is the
    /// closest any of them got, the way `oracle -- settle` reports a handover
    /// it could not settle.
    no_boot: struct { matched: usize, compared: usize },
    /// The cart cannot be pointed at this room at all: no candidate frame
    /// before the stretch produced a boot record. A room the assignment has no
    /// tileset for is the usual reason, and it is a different finding from a
    /// cart that was built and disagreed.
    no_cell,
    /// The port left the original's course at this movie frame, before the
    /// stretch began. Nothing after it is the port's duration for anything.
    diverged: u32,
    /// The port took her and never gave her back inside the window: her
    /// position had still not changed when the trace ran out. Not a duration,
    /// and not absence either.
    stuck,
    /// The movie's input for this stretch is one the port has no key for --
    /// Start or Select. The port was never asked, which is not the same as
    /// having failed.
    unrepresentable,
    /// The stretch begins before the port has a frame zero. The opening is the
    /// only one: a boot record describes a room with Samus in it, and this
    /// stretch is the game putting her there.
    before_port,

    pub fn label(self: Side) []const u8 {
        return switch (self) {
            .frames => "frames",
            .unmeasured => "--",
            .absent => "absent",
            .stuck => "stuck",
            .no_boot => "no world",
            .no_cell => "no cell",
            .diverged => "diverged",
            .unrepresentable => "no key",
            .before_port => "pre-boot",
        };
    }
};

/// One stretch, both machines.
pub const Row = struct {
    gb: Stretch,
    port: Side,
    /// The frame the cart was booted at, when one was.
    anchor: ?u32 = null,

    /// The port's duration as a percentage of the Game Boy's, when both are
    /// numbers. Null when either side has no number to divide.
    pub fn percent(self: Row) ?f64 {
        const p = switch (self.port) {
            .frames => |n| n,
            else => return null,
        };
        if (self.gb.frames == 0) return null;
        return 100.0 * @as(f64, @floatFromInt(p)) / @as(f64, @floatFromInt(self.gb.frames));
    }

    /// Whether the two durations agree inside `tolerance_percent`, or null when
    /// there is nothing to compare.
    pub fn within(self: Row) ?bool {
        const pct = self.percent() orelse return null;
        return @abs(pct - 100.0) <= tolerance_percent;
    }
};

pub const Report = struct {
    rows: []Row,
    horizon: u32,
    /// The largest single-frame step that was not a room change, and the frame
    /// it happened on. The evidence `warp_step` rests on.
    longest_step: u32,
    longest_at: u32,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        self.rows = &.{};
    }

    /// How many rows carry a duration from both machines.
    pub fn compared(self: Report) usize {
        var n: usize = 0;
        for (self.rows) |r| n += @intFromBool(r.within() != null);
        return n;
    }

    pub fn agreeing(self: Report) usize {
        var n: usize = 0;
        for (self.rows) |r| n += @intFromBool(r.within() orelse false);
        return n;
    }

    pub fn counting(self: Report, side: std.meta.Tag(Side)) usize {
        var n: usize = 0;
        for (self.rows) |r| n += @intFromBool(std.meta.activeTag(r.port) == side);
        return n;
    }
};

/// How far back a stretch's anchor may be searched for.
///
/// The same shape as `oracle.settle_search` and for the same reason: an anchor
/// that needs an unbounded search is not an anchor. Backwards rather than
/// forwards, because a transition's anchor has to be in the room she is
/// leaving.
pub const anchor_search: u32 = 48;

/// Frames of cart run after the Game Boy's stretch ends, so the port's own
/// stretch has room to finish inside the window.
///
/// Generous: the question being asked is how long the port's sequence takes,
/// and a window cut to the Game Boy's answer could only ever confirm it.
pub const tail_frames: u32 = 64;

/// Measure every stretch on the cart, and pair each with the Game Boy's.
///
/// One replay finds the anchors, one more takes every reference, one asset
/// conversion serves every cart, and each stretch costs a single headless
/// emulator run. `limit` caps how many stretches are measured, because the full
/// census is around seventy of those and a person asking for the first few
/// should not wait for all of them.
pub fn measure(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    movie: tas.Movie,
    mesen_path: []const u8,
    home: []const u8,
    frame_limit: usize,
    limit: usize,
) !Report {
    var r = try tas.run(allocator, rom, movie, .{
        .max_frames = frame_limit,
        .stride = 1,
        .watch_save = false,
        .profile_record = false,
    });
    defer r.deinit(allocator);

    const fs = try tas.faithfulness(allocator, r.track(), tas.stuck_min_frames);
    const horizon: u32 = fs.horizon() orelse @intCast(r.samples.len);

    const all = try census(allocator, r, horizon);
    defer allocator.free(all);

    const gb_track = try trackOf(allocator, r.samples, horizon);
    defer allocator.free(gb_track);
    const first_play: u32 = if (tas.findOpening(r.track())) |op| op.control else |_| 0;
    const longest: LongestStep = if (gb_track.len > 1)
        measureLongestStep(gb_track, first_play)
    else
        .{ .pixels = 0, .frame = 0 };

    const rows = try allocator.alloc(Row, all.len);
    errdefer allocator.free(rows);
    for (rows, all) |*row, st| row.* = .{ .gb = st, .port = .unmeasured };

    // The rows that will not be asked of an emulator at all, decided before any
    // of the expensive work: nothing here is a judgement the cart could revise.
    var wanted: std.ArrayList(usize) = .empty;
    defer wanted.deinit(allocator);
    for (rows, 0..) |*row, i| {
        switch (row.gb.kind) {
            .cutscene => row.port = .before_port,
            .menu => row.port = .unrepresentable,
            .warp, .scroll => {
                if (wanted.items.len < limit) try wanted.append(allocator, i);
            },
        }
    }
    if (wanted.items.len == 0 or mesen_path.len == 0) {
        return .{ .rows = rows, .horizon = horizon, .longest_step = longest.pixels, .longest_at = longest.frame };
    }

    // ---- Where each cart may honestly be booted -----------------------------
    //
    // Backwards from the frame before the stretch, taking the first candidate
    // whose room and pose hold across it and whose world the cart reproduces.
    // `oracle.settleAnchors` makes the same two demands after a handover; the
    // second is the one that matters, because a cell index agrees long before
    // the tilemap does.
    var cands: std.ArrayList(oracle.Anchor) = .empty;
    defer cands.deinit(allocator);
    for (wanted.items) |i| {
        const st = rows[i].gb;
        var f = st.start;
        while (f > 1 and st.start - f < anchor_search) {
            f -= 1;
            if (f >= r.samples.len) continue;
            // In the room the stretch starts in, and nowhere else. Without this
            // the search walks back *through* the previous transition and finds
            // its predecessor's room: at the second stretch of the any% run
            // every candidate inside the 18-frame redraw fails to settle, and
            // frame 702 -- the far side of the warp before it -- settles
            // cleanly and builds a cart for the room she had already left. That
            // is the exact fault `oracle.pushToStableAnchor` exists to stop,
            // arrived at from the other direction.
            if (!tas.Room.of(r.samples[f]).eql(st.from)) continue;
            if (!tas.Room.of(r.samples[f - 1]).eql(tas.Room.of(r.samples[f]))) continue;
            if (r.samples[f - 1].pose != r.samples[f].pose) continue;
            try cands.append(allocator, .{ .origin = f, .frames = 1, .handover = st.start });
        }
    }
    if (cands.items.len == 0) return .{ .rows = rows, .horizon = horizon, .longest_step = longest.pixels, .longest_at = longest.frame };

    var set = try convert.run(allocator, rom);
    defer set.deinit();

    const Settling = struct { origin: ?u32 = null, saw_boot: bool = false, best: oracle.World = .{} };
    const chosen = try allocator.alloc(Settling, rows.len);
    defer allocator.free(chosen);
    @memset(chosen, .{});
    {
        const probes = try oracle.referencesFromMovie(allocator, rom, movie, cands.items);
        defer {
            for (probes) |maybe| {
                var mr = maybe orelse continue;
                mr.deinit(allocator);
            }
            allocator.free(probes);
        }
        for (probes, cands.items) |maybe, cand| {
            const mr = maybe orelse continue;
            const slot = for (rows, 0..) |row, k| {
                if (row.gb.start == cand.handover) break k;
            } else continue;
            // Candidates are appended nearest-first, so the first one that
            // works is the latest frame before the stretch.
            if (chosen[slot].origin != null) continue;
            const map_index = mr.map_bank -% map_mod.first_bank;
            if (mr.map_bank < map_mod.first_bank or map_index >= map_mod.bank_count) continue;
            const found = (try oracle.movieBoot(allocator, rom, mr)) orelse continue;
            chosen[slot].saw_boot = true;
            const w = try oracle.compareWorlds(
                allocator,
                rom,
                found.boot,
                &mr.settled.tiles,
                mr.settled.scx,
                mr.settled.scy,
                mr.settled.placement.worldX(),
                mr.settled.placement.worldY(),
            );
            if (chosen[slot].best.compared == 0 or w.matched > chosen[slot].best.matched) {
                chosen[slot].best = w;
            }
            if (w.same()) chosen[slot].origin = cand.origin;
        }
    }

    // ---- One cart per stretch, traced ---------------------------------------
    var take_anchors: std.ArrayList(oracle.Anchor) = .empty;
    defer take_anchors.deinit(allocator);
    var slots: std.ArrayList(usize) = .empty;
    defer slots.deinit(allocator);
    for (wanted.items) |i| {
        const origin = chosen[i].origin orelse {
            // Every frame inside `anchor_search` either moved room, changed
            // pose, or built a cart whose world the original's does not match.
            rows[i].port = if (chosen[i].saw_boot)
                .{ .no_boot = .{ .matched = chosen[i].best.matched, .compared = chosen[i].best.compared } }
            else
                .no_cell;
            continue;
        };
        const st = rows[i].gb;
        const want: usize = @as(usize, st.start - origin) + st.frames + tail_frames;
        const room_for = @min(want, trace.maxFrames());
        if (origin + room_for > horizon) {
            // A stretch too close to the horizon to leave the port room to
            // finish is left unmeasured rather than measured short.
            rows[i].port = .{ .no_boot = .{ .matched = 0, .compared = 0 } };
            continue;
        }
        rows[i].anchor = origin;
        try take_anchors.append(allocator, .{ .origin = origin, .frames = room_for, .handover = st.start });
        try slots.append(allocator, i);
    }
    if (take_anchors.items.len == 0) return .{ .rows = rows, .horizon = horizon, .longest_step = longest.pixels, .longest_at = longest.frame };

    const refs = try oracle.referencesFromMovie(allocator, rom, movie, take_anchors.items);
    defer {
        for (refs) |maybe| {
            var mr = maybe orelse continue;
            mr.deinit(allocator);
        }
        allocator.free(refs);
    }

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, oracle.out_dir, .{});
    defer dir.close(io);

    for (refs, take_anchors.items, slots.items) |maybe, anchor, slot| {
        const mr = maybe orelse continue;
        rows[slot].port = try measureOne(allocator, io, dir, rom, set, mr, anchor, rows[slot].gb, mesen_path, home);
    }

    return .{ .rows = rows, .horizon = horizon, .longest_step = longest.pixels, .longest_at = longest.frame };
}

fn measureOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rom: []const u8,
    set: convert.Set,
    mr: oracle.MovieRef,
    anchor: oracle.Anchor,
    gb: Stretch,
    mesen_path: []const u8,
    home: []const u8,
) !Side {
    const found = (try oracle.movieBoot(allocator, rom, mr)) orelse return .no_cell;

    var diag: inject.Diagnosis = .{};
    var cart = try inject.build(allocator, set, found.boot, &diag);
    defer cart.deinit();

    // Named by the stretch's own frame, so the cart that produced a row can be
    // reproduced by hand from the row. `% 100` was the first version and two
    // stretches a hundred frames apart overwrote each other.
    const name = try std.fmt.allocPrint(allocator, "duration{d:0>5}.sfc", .{gb.start});
    defer allocator.free(name);
    try dir.writeFile(io, .{ .sub_path = name, .data = cart.bytes });

    const take = mr.take();
    var run = try trace.run(allocator, io, cart.bytes, take.keys, mesen_path, home);
    defer run.deinit(allocator);

    const port = try allocator.alloc(Step, take.ref.len);
    defer allocator.free(port);
    for (port, 0..) |*p, f| {
        const s = run.at(f);
        // The cell from her *position*, not from `VarCell`, because that is
        // what `tas.Room.of` does on the other side. The engine's `VarCell` is
        // the room the boot script loaded and it does not move when she walks
        // out of it, so comparing it against a cell derived from a position
        // reported the port's first room for the whole window -- no room change,
        // and every scroll came back absent. The two detectors have to be
        // asking the same question or the durations are not comparable.
        p.* = Step.at(
            roomAt(@truncate(s.get("map")), s.get("samus_x"), s.get("samus_y")),
            s.get("samus_x"),
            s.get("samus_y"),
        );
    }

    // The stretch's own frame, as an index into both tracks.
    const at: usize = gb.start - anchor.origin;
    if (at >= port.len) return .{ .no_boot = .{ .matched = 0, .compared = 0 } };

    // Did the port still agree with the original when the stretch began? If it
    // did not, the frames after that are not the port's duration for anything.
    for (0..at) |f| {
        const want = Step.at(port[f].room, take.ref[f].samus_x, take.ref[f].samus_y);
        if (!port[f].samePlace(want)) {
            return .{ .diverged = anchor.origin + @as(u32, @intCast(f)) };
        }
    }

    const ts = try transitions(allocator, port, anchor.origin);
    defer allocator.free(ts);
    for (ts) |t| {
        if (t.start != gb.start) continue;
        // A stretch that ran to the end of the window never ended: `frames`
        // there is the window, not a duration. The Game Boy side makes the same
        // distinction under another name -- `tas.Refusal.released` is what
        // separates the game holding her from Samus standing against a wall.
        if (t.start + t.frames >= anchor.origin + port.len) return .stuck;
        // And it has to arrive where the original arrived. The port crossing a
        // screen boundary on the frame the original warps out of the map is not
        // the original's transition; it is the port not having one.
        if (!t.to.eql(gb.to)) return .absent;
        return .{ .frames = t.frames };
    }
    return .absent;
}

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

fn movieBytes(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        tas.any_percent,
        allocator,
        .limited(4 << 20),
    ) catch error.SkipZigTest;
}

test "a track with no room change has no transitions" {
    const room: tas.Room = .{ .map_bank = 0x0F, .cell = 0x76 };
    var track: [8]Step = undefined;
    for (&track, 0..) |*t, i| t.* = Step.at(room, @intCast(0x100 + i * 2), 0x200);

    const ts = try transitions(testing.allocator, &track, 0);
    defer testing.allocator.free(ts);
    try testing.expectEqual(@as(usize, 0), ts.len);
}

test "a warp is a jump of a whole screen and a scroll is not" {
    const a: tas.Room = .{ .map_bank = 0x0F, .cell = 0x00 };
    const b: tas.Room = .{ .map_bank = 0x0A, .cell = 0x43 };

    // Two frames in `a`, then a jump into `b`, held for three frames, then she
    // moves again.
    var warped: [8]Step = undefined;
    warped[0] = Step.at(a, 0x07F3, 0x0784);
    warped[1] = Step.at(a, 0x07F3, 0x0784);
    for (2..5) |i| warped[i] = Step.at(b, 0x03F3, 0x0484);
    for (5..8) |i| warped[i] = Step.at(b, @intCast(0x03F3 + (i - 4) * 2), 0x0484);

    const ws = try transitions(testing.allocator, &warped, 0);
    defer testing.allocator.free(ws);
    try testing.expectEqual(@as(usize, 1), ws.len);
    try testing.expectEqual(Kind.warp, ws[0].kind);
    try testing.expectEqual(@as(u32, 2), ws[0].start);
    try testing.expectEqual(@as(u32, 3), ws[0].frames);

    // The same shape with a two-pixel step across the cell boundary is a
    // scroll, and it is the same code that says so.
    var scrolled: [8]Step = undefined;
    const c: tas.Room = .{ .map_bank = 0x0F, .cell = 0x01 };
    scrolled[0] = Step.at(a, 0x00FE, 0x0084);
    scrolled[1] = Step.at(a, 0x00FE, 0x0084);
    for (2..5) |i| scrolled[i] = Step.at(c, 0x0100, 0x0084);
    for (5..8) |i| scrolled[i] = Step.at(c, @intCast(0x0100 + (i - 4) * 2), 0x0084);

    const ss = try transitions(testing.allocator, &scrolled, 0);
    defer testing.allocator.free(ss);
    try testing.expectEqual(@as(usize, 1), ss.len);
    try testing.expectEqual(Kind.scroll, ss[0].kind);
    try testing.expectEqual(@as(u32, 3), ss[0].frames);
}

test "two room changes inside one hold are one transition" {
    // The shape a leftward crossing makes: she is bounced back over the
    // boundary, held, and then let across for real. Reporting it as two
    // transitions of one frame and nineteen would say the game did two things.
    const left: tas.Room = .{ .map_bank = 0x0F, .cell = 0x01 };
    const right: tas.Room = .{ .map_bank = 0x0F, .cell = 0x02 };
    var track: [26]Step = undefined;
    track[0] = Step.at(left, 0x01FE, 0x0084);
    for (1..21) |i| track[i] = Step.at(right, 0x0200, 0x0084);
    for (21..26) |i| track[i] = Step.at(left, @intCast(0x0200 - (i - 20)), 0x0084);

    const ts = try transitions(testing.allocator, &track, 0);
    defer testing.allocator.free(ts);
    try testing.expectEqual(@as(usize, 1), ts.len);
    try testing.expectEqual(@as(u32, 1), ts[0].start);
    try testing.expectEqual(@as(u32, 21), ts[0].frames);
    try testing.expect(ts[0].to.eql(left));
}

test "the world wraps, and a step across the wrap is not a warp" {
    // Movie frame 6106: the game's own screen byte reads $10 walking out of
    // column $F and then snaps to $00, so the raw positions are 4094 pixels
    // apart inside an unbroken roll. `warp_step` would call that a warp.
    const room: tas.Room = .{ .map_bank = 0x0F, .cell = 0x00 };
    const a = Step.at(room, 0x101B, 0x0084);
    const b = Step.at(room, 0x001D, 0x0084);
    try testing.expectEqual(@as(u32, 2), stepSize(a, b));
    try testing.expect(stepSize(a, b) < warp_step);
}

test "percentages, the tolerance, and what has no percentage at all" {
    const gb: Stretch = .{
        .kind = .scroll,
        .start = 100,
        .frames = 100,
        .from = .{ .map_bank = 9, .cell = 0 },
        .to = .{ .map_bank = 9, .cell = 1 },
    };
    try testing.expectEqual(@as(?bool, true), (Row{ .gb = gb, .port = .{ .frames = 100 } }).within());
    try testing.expectEqual(@as(?bool, true), (Row{ .gb = gb, .port = .{ .frames = 102 } }).within());
    try testing.expectEqual(@as(?bool, false), (Row{ .gb = gb, .port = .{ .frames = 103 } }).within());
    // Absent is not zero percent: a port that never ran the sequence and a port
    // that ran it instantly are different findings, and only one of them has a
    // percentage.
    try testing.expectEqual(@as(?f64, null), (Row{ .gb = gb, .port = .absent }).percent());
    try testing.expectEqual(@as(?bool, null), (Row{ .gb = gb, .port = .stuck }).within());
    try testing.expectEqual(@as(?bool, null), (Row{ .gb = gb, .port = .{ .diverged = 4 } }).within());
}

test "the census of the any% run, and the opening is a cutscene rather than a warp" {
    const allocator = testing.allocator;
    const rom = try testrom.load(allocator) orelse return error.SkipZigTest;
    defer allocator.free(rom);
    const bytes = try movieBytes(allocator);
    defer allocator.free(bytes);
    const movie = try tas.parse(bytes);

    var r = try tas.run(allocator, rom, movie, .{
        .max_frames = oracle.anchored_gate_limit,
        .stride = 1,
        .watch_save = false,
        .profile_record = false,
    });
    defer r.deinit(allocator);

    const fs = try tas.faithfulness(allocator, r.track(), tas.stuck_min_frames);
    const horizon: u32 = fs.horizon() orelse @intCast(r.samples.len);

    const all = try census(allocator, r, horizon);
    defer allocator.free(all);
    try testing.expectEqual(census_stretches, all.len);

    // The game warps her into the landing site, so a detector that only knew
    // about room changes would report the opening twice -- once as a warp on
    // the frame she is placed, and never as the 320-frame hold that follows.
    const op = try tas.findOpening(r.track());
    try testing.expectEqual(Kind.cutscene, all[0].kind);
    try testing.expectEqual(op.placed, all[0].start);
    try testing.expectEqual(tas.opening_hold_frames, all[0].frames);
    for (all[1..]) |st| try testing.expect(st.start > op.control);

    // The first transition after it is the one Step 15b located by hand: the
    // room change at movie frame 703, a warp out of map bank $F into $A.
    var first_warp: ?Stretch = null;
    for (all) |st| {
        if (st.kind != .warp) continue;
        first_warp = st;
        break;
    }
    const w = first_warp orelse return error.NoWarpInTheRun;
    try testing.expectEqual(@as(u32, 703), w.start);
    try testing.expectEqual(@as(u8, 0x0F), w.from.map_bank);
    try testing.expectEqual(@as(u8, 0x0A), w.to.map_bank);
}

test "warp_step sits far above the longest step Samus takes herself" {
    const allocator = testing.allocator;
    const rom = try testrom.load(allocator) orelse return error.SkipZigTest;
    defer allocator.free(rom);
    const bytes = try movieBytes(allocator);
    defer allocator.free(bytes);
    const movie = try tas.parse(bytes);

    var r = try tas.run(allocator, rom, movie, .{
        .max_frames = oracle.anchored_gate_limit,
        .stride = 1,
        .watch_save = false,
        .profile_record = false,
    });
    defer r.deinit(allocator);

    const fs = try tas.faithfulness(allocator, r.track(), tas.stuck_min_frames);
    const horizon: u32 = fs.horizon() orelse @intCast(r.samples.len);
    const track = try trackOf(allocator, r.samples, horizon);
    defer allocator.free(track);

    const op = try tas.findOpening(r.track());
    const longest = measureLongestStep(track, op.control);
    // Eight pixels, at movie frame 463 -- a fall. The threshold is a whole
    // screen, which is what the game warps in. The gap between them is the
    // whole justification for a single constant separating the two kinds.
    try testing.expect(longest.pixels < warp_step / 8);
}

test "no menu in the any% run's horizon holds her for more than a frame" {
    // The measured claim behind reporting menus as `unrepresentable` rather
    // than chasing a duration for them: the run taps Select twice, each press
    // costs one frame of movement, and the game opens nothing. If a published
    // run ever does open the map, this fails and says so.
    const allocator = testing.allocator;
    const rom = try testrom.load(allocator) orelse return error.SkipZigTest;
    defer allocator.free(rom);
    const bytes = try movieBytes(allocator);
    defer allocator.free(bytes);
    const movie = try tas.parse(bytes);

    var r = try tas.run(allocator, rom, movie, .{
        .max_frames = oracle.anchored_gate_limit,
        .stride = 1,
        .watch_save = false,
        .profile_record = false,
    });
    defer r.deinit(allocator);

    const fs = try tas.faithfulness(allocator, r.track(), tas.stuck_min_frames);
    const horizon: u32 = fs.horizon() orelse @intCast(r.samples.len);
    const all = try census(allocator, r, horizon);
    defer allocator.free(all);

    var menus: usize = 0;
    for (all) |st| {
        if (st.kind != .menu) continue;
        menus += 1;
        try testing.expect(st.frames <= 1);
    }
    try testing.expectEqual(@as(usize, 2), menus);
}
