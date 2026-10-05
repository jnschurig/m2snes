//! The title's file select on the Game Boy: the reference the cart's `title`
//! rung is graded against. Step 24h (B14).
//!
//! ## What the original does
//!
//! `titleScreenRoutine` (05:$4118) is one frame of the title. It clears the OAM
//! buffer (00:$0370), runs the palette flash and the falling star -- the star is
//! always drawn first, so it is always OAM slot 0 -- and then draws the menu
//! through `drawNonGameSprite` (01:$73F7): the cursor at x $38, y $74 or $80
//! with clear selected, cycling `titleCursorTable` (05:$42E1) on `frameCounter
//! & $0C`; the slot's number sprite, `$23 + activeSaveSlot`, at the same place;
//! `START` at ($44,$74); and `CLEAR` at ($44,$80) while the option is shown.
//! **Only then** does it read the pad, so a press changes the state bytes on the
//! frame it is read and the sprites a frame later -- and OAM, which is the
//! shadow copied in the next vblank, a frame after that.
//!
//! The arms, in order, off the ROM's bytes: Select's rising edge *equal* to
//! Select toggles `title_showClearOption` by `XOR $FF`; Right and Left step the
//! slot when the rising edge *and* the held byte both equal the direction (Step
//! 24i); `title_clearSelected` is cleared and set again while the option is
//! shown and **bit 7 of the held byte** is -- a mask, so Down with another
//! button still selects clear; and Start's rising edge equal to Start either
//! runs the clear branch (05:$42A6: noise $0F, the slot's first two bytes
//! zeroed, the option hidden) or starts or loads the slot.
//!
//! ## How this is used
//!
//! `run` boots the retail ROM cold on our emulator, with the slots seeded
//! before the boot, and plays `script` from the title's first frame. Every
//! frame it records the menu's sprites as a set -- OAM slot 0, the star, left
//! out; the cart has no star, so its menu sits a slot lower -- the three state
//! bytes and the game mode. `snes_romtest.writeTitle` bakes the record into
//! the cart's rung.

const std = @import("std");
const harness = @import("gb/harness.zig");
const probe = @import("gb/probe.zig");
const ppu_mod = @import("gb/ppu.zig");
const blocks = @import("blocks.zig");
const offsets = @import("offsets.zig");
const save = @import("save.zig");

const testrom = @import("testrom");

pub const Error = error{ NeverReachedTitle, NeverLeftTitle, TooManySprites, OutOfMemory };

pub const game_mode_addr: u16 = 0xFF9B;
pub const frame_counter_addr: u16 = 0xFF97;
pub const active_slot_addr: u16 = 0xD0A3;
pub const clear_selected_addr: u16 = 0xD07A;
pub const show_clear_addr: u16 = 0xD0A4;
/// `loadingFromFile`: $FF when Start found a game in the slot (05:$428A).
pub const loading_addr: u16 = 0xD079;
/// `saveLastSlot`, cartridge RAM $A0C0: read by `bootRoutine` (00:$02BA) and
/// taken when below 3 (00:$02BD `CP $03`), written by Start (05:$4290).
pub const last_slot_offset: usize = 0xC0;
pub const title_first: u16 = 0x4118;
pub const title_end: u16 = 0x42C7;
pub const mode_title: u8 = 0x01;
/// Where the title hands over. Start writes $0B and a load $0C after it
/// (05:$4298-$42A3), and both are through to $02 inside the frame, so the mode
/// cannot tell a new game from a load; `loadingFromFile` does.
pub const mode_after: u8 = 0x02;

pub const bank: u8 = 5;
/// `titleCursorTable`, indexed by `(frameCounter & $0C) >> 2` (05:$4190-$419B).
pub const cursor_table_addr: u16 = 0x42E1;
pub const cursor_frames: usize = 4;

// ---- The menu's constants, each the operand of the instruction that names it

pub const Menu = struct {
    cursor_x: u8,
    start_y: u8,
    clear_y: u8,
    word_x: u8,
    start_id: u8,
    clear_id: u8,
    number_base: u8,
    cursor: [cursor_frames]u8,

    pub fn read(rom: []const u8) !Menu {
        var m: Menu = .{
            .cursor_x = try blocks.loadIn(rom, bank, 0x4189),
            .start_y = try blocks.loadIn(rom, bank, 0x417B),
            .clear_y = try blocks.loadIn(rom, bank, 0x4185),
            .word_x = try blocks.loadIn(rom, bank, 0x41AF),
            .start_id = try blocks.loadIn(rom, bank, 0x41B7),
            .clear_id = try blocks.loadIn(rom, bank, 0x41C8),
            .number_base = try blocks.addIn(rom, bank, 0x41A8),
            .cursor = undefined,
        };
        const t = blocks.offsetIn(bank, cursor_table_addr);
        @memcpy(&m.cursor, rom[t..][0..cursor_frames]);
        return m;
    }
};

// ---- The pad ----------------------------------------------------------------

/// The Game Boy's pad byte, as `hInputPressed` holds it.
pub const A: u8 = 0x01;
pub const B: u8 = 0x02;
pub const SELECT: u8 = 0x04;
pub const START: u8 = 0x08;
pub const RIGHT: u8 = 0x10;
pub const LEFT: u8 = 0x20;
pub const UP: u8 = 0x40;
pub const DOWN: u8 = 0x80;

/// From title frame `at`, hold `pad` until the next event.
pub const Event = struct { at: u16, pad: u8 };

/// Step 24h's sequence. Each line is one thing B14 asks the title to do or not
/// do; the gaps are long enough for the sprites to settle behind the state.
pub const script = [_]Event{
    .{ .at = 0, .pad = 0 }, // a full cursor cycle and more, untouched
    .{ .at = 20, .pad = SELECT }, // shows CLEAR
    .{ .at = 22, .pad = 0 },
    .{ .at = 30, .pad = DOWN }, // held: the cursor on CLEAR
    .{ .at = 38, .pad = 0 }, // released: back on START
    .{ .at = 46, .pad = SELECT }, // hides CLEAR
    .{ .at = 48, .pad = 0 },
    .{ .at = 56, .pad = DOWN }, // with CLEAR hidden: nothing
    .{ .at = 60, .pad = 0 },
    .{ .at = 68, .pad = B | SELECT }, // together: the edge is not Select alone
    .{ .at = 70, .pad = 0 },
    .{ .at = 78, .pad = B }, // B first...
    .{ .at = 80, .pad = B | SELECT }, // ...so this edge *is* Select alone: shows
    .{ .at = 82, .pad = 0 },
    // Step 24i. The run opens on the slot `seed_last_slot` names, 2, so the
    // first Right wraps to 0 and the third Left wraps back to 2.
    .{ .at = 90, .pad = RIGHT }, // 2 -> 0, the wrap
    .{ .at = 92, .pad = 0 },
    .{ .at = 96, .pad = RIGHT }, // -> 1
    .{ .at = 98, .pad = 0 },
    .{ .at = 102, .pad = RIGHT }, // -> 2
    .{ .at = 104, .pad = 0 },
    .{ .at = 110, .pad = LEFT }, // -> 1
    .{ .at = 112, .pad = 0 },
    .{ .at = 116, .pad = LEFT }, // -> 0
    .{ .at = 118, .pad = 0 },
    .{ .at = 122, .pad = LEFT }, // 0 -> 2, the wrap
    .{ .at = 124, .pad = 0 },
    .{ .at = 130, .pad = UP }, // Up first...
    .{ .at = 132, .pad = UP | RIGHT }, // ...so Right's edge is alone and held is not: no step
    .{ .at = 134, .pad = 0 },
    .{ .at = 140, .pad = LEFT }, // -> 1
    .{ .at = 142, .pad = 0 },
    .{ .at = 150, .pad = DOWN },
    .{ .at = 154, .pad = DOWN | START }, // Start on CLEAR: slot 1's clear
    .{ .at = 156, .pad = 0 },
    .{ .at = 166, .pad = START }, // Start: a new game, slot 1 is empty now
    .{ .at = 168, .pad = 0 },
};

/// What the graded run leaves in `saveLastSlot` before the boot: the title
/// opens on slot 2, as it does on a cart last played in slot 2.
pub const seed_last_slot: u8 = 2;

/// Frames recorded past the last event, at most. The run ends when the mode
/// leaves the title.
pub const tail: u16 = 8;

pub fn padAt(events: []const Event, t: usize) u8 {
    var pad: u8 = 0;
    for (events) |e| {
        if (e.at > t) break;
        pad = e.pad;
    }
    return pad;
}

fn buttonsFor(pad: u8) probe.Buttons {
    var b: probe.Buttons = .{};
    b.buttons &= ~@as(u4, @truncate(pad));
    b.dpad &= ~@as(u4, @truncate(pad >> 4));
    return b;
}

// ---- The record ---------------------------------------------------------------

/// One OAM entry in the Game Boy's own terms.
pub const Obj = struct {
    y: u8,
    x: u8,
    tile: u8,
    attr: u8,

    fn key(o: Obj) u32 {
        return (@as(u32, o.tile) << 24) | (@as(u32, o.x) << 16) | (@as(u32, o.y) << 8) | o.attr;
    }

    fn lessThan(_: void, a: Obj, b: Obj) bool {
        return a.key() < b.key();
    }
};

pub const max_objs: usize = 16;

pub const Frame = struct {
    /// Sorted, so two sets compare as slices.
    objs: [max_objs]Obj = undefined,
    n: u8 = 0,
    fc: u8,
    slot: u8,
    clear_selected: u8,
    show_clear: u8,
    mode: u8,
    loading: u8,
    pad: u8,
    /// The select sound ($15 into `sfxRequest_square1`) asked for during this
    /// frame: the stores `selectSites` finds, executed.
    sfx: u8 = 0,

    pub fn sprites(f: *const Frame) []const Obj {
        return f.objs[0..f.n];
    }
};

pub const slots_len = @as(usize, save.slots) * save.slot_size;
/// The slots and `saveLastSlot` after them: $A000-$A0C0.
pub const seed_len = last_slot_offset + 1;

/// `LD A,$15 / LD ($CEC0),A` inside `titleScreenRoutine`, as the addresses of
/// the stores: Select, Right, Left, Down and Start (05:$41DA, $41F3, $4213,
/// $4243, $425C). Read off the ROM, not written down.
pub fn selectSites(rom: []const u8) ![5]u16 {
    const pattern = [_]u8{ 0x3E, 0x15, 0xEA, 0xC0, 0xCE };
    var out: [5]u16 = undefined;
    var n: usize = 0;
    var pc: u16 = title_first;
    while (pc + pattern.len <= title_end) : (pc += 1) {
        const at = blocks.offsetIn(bank, pc);
        if (!std.mem.eql(u8, rom[at..][0..pattern.len], &pattern)) continue;
        if (n == out.len) return error.TooManySites;
        out[n] = pc + 2;
        n += 1;
    }
    if (n != out.len) return error.TooFewSites;
    return out;
}

pub const Run = struct {
    frames: []Frame,
    /// The three slots and `saveLastSlot` before and after the run,
    /// `$A000`-`$A0C0`.
    slots_before: [seed_len]u8,
    slots_after: [seed_len]u8,

    pub fn deinit(r: *Run, a: std.mem.Allocator) void {
        a.free(r.frames);
    }
};

/// What the rung seeds, and the Game Boy with it: James's first save in every
/// slot, with the slot's number in its last byte so a clear that hits the wrong
/// one cannot be mistaken for the right one, and `last_slot` in `saveLastSlot`.
pub fn seedSlots(last_slot: u8) [seed_len]u8 {
    var out: [seed_len]u8 = @splat(0);
    for (0..save.slots) |s| {
        const at = s * save.slot_size;
        @memcpy(out[at..][0..save.recorded_save.len], &save.recorded_save);
        out[at + save.slot_size - 1] = @intCast(s);
    }
    out[last_slot_offset] = last_slot;
    return out;
}

const SfxCount = struct {
    sites: [5]u16,
    n: u8 = 0,

    fn hit(ctx: *anyopaque, b: usize, pc: u16) void {
        const self: *SfxCount = @ptrCast(@alignCast(ctx));
        if (b != bank) return;
        for (self.sites) |s| {
            if (s == pc) self.n +%= 1;
        }
    }
};

fn record(m: *harness.Machine, pad: u8, sfx: u8) !Frame {
    var f: Frame = .{
        .sfx = sfx,
        .fc = m.read(frame_counter_addr),
        .slot = m.read(active_slot_addr),
        .clear_selected = m.read(clear_selected_addr),
        .show_clear = m.read(show_clear_addr),
        .mode = m.read(game_mode_addr),
        .loading = m.read(loading_addr),
        .pad = pad,
    };
    var s: u16 = 1; // slot 0 is the star
    while (s < 40) : (s += 1) {
        const y = m.read(0xFE00 + s * 4);
        if (y == 0) continue;
        if (f.n == max_objs) return error.TooManySprites;
        f.objs[f.n] = .{ .y = y, .x = m.read(0xFE01 + s * 4), .tile = m.read(0xFE02 + s * 4), .attr = m.read(0xFE03 + s * 4) };
        f.n += 1;
    }
    std.mem.sort(Obj, f.objs[0..f.n], {}, Obj.lessThan);
    return f;
}

/// Boot cold with `seed` in cartridge RAM, reach the title, and play `events`
/// from its first frame. Frame `t` of the result is the state after title
/// frame `t` has run with `padAt(events, t)` held.
pub fn run(a: std.mem.Allocator, rom: []const u8, events: []const Event, seed: []const u8) !Run {
    var m = try harness.bootFrom(a, rom, null);
    defer m.deinit();
    @memcpy(m.ram[0..seed.len], seed);
    var sfx: SfxCount = .{ .sites = try selectSites(rom) };

    var waited: usize = 0;
    while (m.read(game_mode_addr) != mode_title) : (waited += 1) {
        if (waited > 600) return error.NeverReachedTitle;
        _ = try m.runFrames(1, .{});
    }

    var r: Run = .{ .frames = undefined, .slots_before = undefined, .slots_after = undefined };
    @memcpy(&r.slots_before, m.ram[0..seed_len]);
    var out: std.ArrayList(Frame) = .empty;
    errdefer out.deinit(a);
    // Title frame 0 is the one the loop above stopped after: record it with
    // nothing held, then play from frame 1.
    try out.append(a, try record(&m, 0, 0));
    m.exec = .{ .ctx = &sfx, .hit = SfxCount.hit };
    const last = events[events.len - 1].at + tail;
    var t: usize = 1;
    while (t <= last) : (t += 1) {
        const pad = padAt(events, t);
        sfx.n = 0;
        _ = try m.runFrames(1, buttonsFor(pad));
        const f = try record(&m, pad, sfx.n);
        try out.append(a, f);
        if (f.mode != mode_title) break;
    } else return error.NeverLeftTitle;
    @memcpy(&r.slots_after, m.ram[0..seed_len]);
    r.frames = try out.toOwnedSlice(a);
    return r;
}

// ---- The picture ------------------------------------------------------------

/// The rows the rung grades the cart's pixels on: 16, the copyright, and 17,
/// which the window would cover if it were on. Lines 128-143.
pub const rows_first: usize = 16 * 8;
pub const rows_len: usize = ppu_mod.height - rows_first;

/// Lines `rows_first` to the bottom of the Game Boy's title, as shades, after
/// `frame` title frames. The background only: `gb/ppu.zig` draws no objects,
/// and none of the menu's reach these lines.
pub fn renderRows(a: std.mem.Allocator, rom: []const u8, frame: usize) ![rows_len * ppu_mod.width]u8 {
    const all = try renderTitle(a, rom, frame);
    return all[rows_first * ppu_mod.width ..][0 .. rows_len * ppu_mod.width].*;
}

/// The whole of the Game Boy's title, as shades, after `frame` title frames:
/// the background only, so not the falling star. Step 24j grades "Super" over
/// it; `renderRows` is its last two rows.
pub fn renderTitle(a: std.mem.Allocator, rom: []const u8, frame: usize) ![ppu_mod.height * ppu_mod.width]u8 {
    var m = try harness.bootFrom(a, rom, null);
    defer m.deinit();
    const ppu = try a.create(ppu_mod.Ppu);
    defer a.destroy(ppu);
    ppu.* = .{};
    m.sys.bus.video = ppu.video();
    var waited: usize = 0;
    while (m.read(game_mode_addr) != mode_title) : (waited += 1) {
        if (waited > 600) return error.NeverReachedTitle;
        _ = try m.runFrames(1, .{});
    }
    _ = try m.runFrames(frame, .{});
    var out: [ppu_mod.height * ppu_mod.width]u8 = undefined;
    @memcpy(&out, ppu.frame[0 .. ppu_mod.height * ppu_mod.width]);
    return out;
}

// ---- The menu, derived from the ROM rather than watched -------------------------

/// `drawNonGameSprite` (01:$73F7) over the credits set's record `id` at (y, x).
/// The flips and the XORed attribute are not taken: every title call passes
/// $00 in `hSpriteAttr`.
fn appendSprite(rom: []const u8, out: *Frame, id: u8, y: u8, x: u8) !void {
    const ptrs = offsets.find("metasprite_credits_pointers").?;
    const at = std.mem.readInt(u16, rom[ptrs.romOffset() + @as(usize, id) * 2 ..][0..2], .little);
    var pos = blocks.offsetIn(1, at);
    while (rom[pos] != 0xFF) : (pos += 4) {
        if (out.n == max_objs) return error.TooManySprites;
        out.objs[out.n] = .{ .y = rom[pos] +% y, .x = rom[pos + 1] +% x, .tile = rom[pos + 2], .attr = rom[pos + 3] };
        out.n += 1;
    }
}

/// The sprites `titleScreenRoutine` draws for this state, in the set form the
/// oracle records. The Game Boy's OAM shows this a frame after the draw.
pub fn menuFor(rom: []const u8, menu: Menu, fc: u8, slot: u8, clear_selected: u8, show_clear: u8) !Frame {
    var f: Frame = .{ .fc = fc, .slot = slot, .clear_selected = clear_selected, .show_clear = show_clear, .mode = mode_title, .loading = 0, .pad = 0 };
    const y = if (clear_selected != 0) menu.clear_y else menu.start_y;
    try appendSprite(rom, &f, menu.cursor[(fc & 0x0C) >> 2], y, menu.cursor_x);
    try appendSprite(rom, &f, menu.number_base +% slot, y, menu.cursor_x);
    try appendSprite(rom, &f, menu.start_id, menu.start_y, menu.word_x);
    if (show_clear != 0) try appendSprite(rom, &f, menu.clear_id, menu.clear_y, menu.word_x);
    std.mem.sort(Obj, f.objs[0..f.n], {}, Obj.lessThan);
    return f;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

fn expectObjs(want: []const Obj, got: []const Obj) !void {
    testing.expectEqualSlices(Obj, want, got) catch |e| {
        std.debug.print("want {any}\ngot  {any}\n", .{ want, got });
        return e;
    };
}

test "the menu's constants and records are the ROM's" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const menu = try Menu.read(rom);
    // What the plan's measurement read by hand; this is the ROM agreeing.
    try testing.expectEqual(@as(u8, 0x38), menu.cursor_x);
    try testing.expectEqual(@as(u8, 0x74), menu.start_y);
    try testing.expectEqual(@as(u8, 0x80), menu.clear_y);
    try testing.expectEqual(@as(u8, 0x44), menu.word_x);
    try testing.expectEqual(@as(u8, 0x00), menu.start_id);
    try testing.expectEqual(@as(u8, 0x01), menu.clear_id);
    try testing.expectEqual(@as(u8, 0x23), menu.number_base);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x03, 0x04, 0x03 }, &menu.cursor);

    var f = try menuFor(rom, menu, 0, 0, 0, 0xFF);
    var tiles: [max_objs]u8 = undefined;
    for (f.sprites(), 0..) |o, i| tiles[i] = o.tile;
    // The cursor's first frame $ED, START $F1-$F5, CLEAR $F6-$FA, the number $FB.
    try testing.expectEqualSlices(u8, &.{ 0xED, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB }, tiles[0..f.n]);
    f = try menuFor(rom, menu, 0, 2, 0, 0);
    try testing.expectEqual(@as(u8, 0xFD), f.sprites()[f.n - 1].tile);
    try testing.expectEqual(@as(u8, 0x80), f.sprites()[f.n - 1].attr);
}

test "the Game Boy draws exactly what the ROM's records say, a frame late" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const menu = try Menu.read(rom);
    const seed = seedSlots(seed_last_slot);
    var r = try run(a, rom, &script, &seed);
    defer r.deinit(a);

    // OAM at t is the shadow drawn during t, from the state and the counter
    // t-1 left behind: the draw comes before the pad in the frame.
    var t: usize = 2;
    while (t < r.frames.len) : (t += 1) {
        if (r.frames[t].mode != mode_title) break;
        const s = r.frames[t - 1];
        const want = try menuFor(rom, menu, s.fc, s.slot, s.clear_selected, s.show_clear);
        expectObjs(want.sprites(), r.frames[t].sprites()) catch |e| {
            std.debug.print("title frame {d}\n", .{t});
            return e;
        };
    }
}

test "the recorded run does what B14 says, and an empty title is not it" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const seed = seedSlots(seed_last_slot);
    var r = try run(a, rom, &script, &seed);
    defer r.deinit(a);
    const fr = r.frames;

    // The title opens with the counter at 1, the option hidden, and the slot
    // `saveLastSlot` names.
    try testing.expectEqual(@as(u8, 1), fr[0].fc);
    try testing.expectEqual(seed_last_slot, fr[0].slot);
    try testing.expectEqual(@as(u8, 0), fr[0].show_clear);
    try testing.expectEqual(@as(u8, 0), fr[0].clear_selected);
    // Every title frame after the first two draws the menu; a cart that draws
    // nothing -- the cart before this step -- fails on every one of them.
    for (fr[2..]) |f| {
        if (f.mode != mode_title) break;
        try testing.expect(f.n >= 7);
    }
    // A press is in the state the frame after the pad changed.
    try testing.expectEqual(@as(u8, 0), fr[20].show_clear);
    try testing.expectEqual(@as(u8, 0xFF), fr[21].show_clear);
    // Down held selects clear; released, the cursor is back a frame later.
    try testing.expectEqual(@as(u8, 1), fr[31].clear_selected);
    try testing.expectEqual(@as(u8, 1), fr[38].clear_selected);
    try testing.expectEqual(@as(u8, 0), fr[39].clear_selected);
    // Down with the option hidden selects nothing.
    for (fr[56..62]) |f| try testing.expectEqual(@as(u8, 0), f.clear_selected);
    // B and Select together do not toggle; Select while B is held does.
    for (fr[68..81]) |f| try testing.expectEqual(@as(u8, 0), f.show_clear);
    try testing.expectEqual(@as(u8, 0xFF), fr[81].show_clear);
    // Step 24i. Right three times through the wrap, Left three times back.
    const steps = [_]struct { t: usize, slot: u8 }{
        .{ .t = 91, .slot = 0 }, .{ .t = 97, .slot = 1 },  .{ .t = 103, .slot = 2 },
        .{ .t = 111, .slot = 1 }, .{ .t = 117, .slot = 0 }, .{ .t = 123, .slot = 2 },
        .{ .t = 141, .slot = 1 },
    };
    for (steps) |st| {
        try testing.expectEqual(st.slot, fr[st.t].slot);
        try testing.expect(fr[st.t - 1].slot != st.slot);
        // The select sound on the step's own frame, once.
        try testing.expectEqual(@as(u8, 1), fr[st.t].sfx);
    }
    // Right while Up is held: the edge is Right alone, the held byte is not.
    for (fr[124..141]) |f| try testing.expectEqual(@as(u8, 2), f.slot);
    for (fr[130..136]) |f| try testing.expectEqual(@as(u8, 0), f.sfx);
    // The sound comes only with a press that does something: Select's three
    // toggles, Down's two edges with CLEAR shown, the steps, and the Start
    // that leaves. The clear's Start is the noise instead: $4254 branches
    // before the select sound at $425A.
    var sounds: usize = 0;
    for (fr) |f| sounds += f.sfx;
    try testing.expectEqual(@as(usize, 3 + 2 + steps.len + 1), sounds);
    // Start on CLEAR clears and hides, and the title stays up.
    try testing.expectEqual(@as(u8, 0xFF), fr[154].show_clear);
    try testing.expectEqual(@as(u8, 0), fr[155].show_clear);
    try testing.expectEqual(mode_title, fr[155].mode);
    // Start without it leaves the title, for a new game: the slot is empty.
    try testing.expectEqual(mode_after, fr[fr.len - 1].mode);
    try testing.expectEqual(@as(u8, 0), fr[fr.len - 1].loading);
    try testing.expectEqual(@as(usize, 168), fr.len);

    // The clear zeroed slot 1's first two bytes and nothing else, and Start
    // wrote slot 1 to `saveLastSlot`.
    var want = r.slots_before;
    want[save.slot_size] = 0;
    want[save.slot_size + 1] = 0;
    want[last_slot_offset] = 1;
    try testing.expect(r.slots_before[save.slot_size] != 0);
    try testing.expectEqualSlices(u8, &want, &r.slots_after);
}

test "the select sound's stores are the five the plan names" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    try testing.expectEqualSlices(u16, &.{ 0x41DA, 0x41F3, 0x4213, 0x4243, 0x425C }, &(try selectSites(rom)));
}

test "boot takes saveLastSlot below 3 and slot 0 otherwise, and a slot-0 title is not it" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    for ([_]struct { last: u8, want: u8 }{
        .{ .last = 0, .want = 0 },   .{ .last = 1, .want = 1 },
        .{ .last = 2, .want = 2 },   .{ .last = 3, .want = 0 },
        .{ .last = 0xFF, .want = 0 },
    }) |c| {
        const seed = seedSlots(c.last);
        var m = try harness.bootFrom(a, rom, null);
        defer m.deinit();
        @memcpy(m.ram[0..seed.len], &seed);
        while (m.read(game_mode_addr) != mode_title) _ = try m.runFrames(1, .{});
        try testing.expectEqual(c.want, m.read(active_slot_addr));
    }

    // The old wrong answer: Step 24h's cart held the slot at 0 and drew $FB
    // for it. The graded run is on another slot for most of its frames.
    const seed = seedSlots(seed_last_slot);
    var r = try run(a, rom, &script, &seed);
    defer r.deinit(a);
    var off_zero: usize = 0;
    for (r.frames) |f| off_zero += @intFromBool(f.slot != 0);
    try testing.expect(off_zero > r.frames.len / 2);
}

test "the rows the rung grades hold the copyright and are the title's" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const rows = try renderRows(a, rom, 4);
    // The title's background is shade 3 under BGP $93; the copyright's glyphs
    // are lighter. A render that missed the row would be all one shade.
    var lit: usize = 0;
    for (rows[0 .. 8 * ppu_mod.width]) |p| lit += @intFromBool(p != 3);
    try testing.expect(lit > 200);
    // And the picture does not move: the rows are the same a frame later.
    try testing.expectEqualSlices(u8, &rows, &(try renderRows(a, rom, 5)));
}

test "every menu pixel sits on background colour 0, so the number's behind bit shows nothing" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var m = try harness.bootFrom(a, rom, null);
    defer m.deinit();
    while (m.read(game_mode_addr) != mode_title) _ = try m.runFrames(1, .{});
    const menu = try Menu.read(rom);
    const vram = m.sys.bus.vram;
    // Both rows the cursor and number can stand on, and both words.
    for ([_]u8{ 0, 1 }) |sel| {
        const f = try menuFor(rom, menu, 0, 0, sel, 0xFF);
        for (f.sprites()) |o| for (0..8) |dy| for (0..8) |dx| {
            const sy = @as(usize, o.y) - 16 + dy;
            const sx = @as(usize, o.x) - 8 + dx;
            const tile = vram[0x1800 + (sy / 8) * 32 + sx / 8];
            const data: usize = @intCast(@as(i32, 0x1000) + @as(i32, @as(i8, @bitCast(tile))) * 16);
            const bit: u3 = @intCast(7 - (sx % 8));
            const idx = ((vram[data + (sy % 8) * 2] >> bit) & 1) | (((vram[data + (sy % 8) * 2 + 1] >> bit) & 1) << 1);
            try testing.expectEqual(@as(u8, 0), idx);
        };
    }
    // And the screen is the one that was measured: signed addressing, map $9800.
    try testing.expectEqual(@as(u8, 0xC3), m.read(0xFF40));
}
