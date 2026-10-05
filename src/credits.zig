//! The ending on the Game Boy, measured: the lengths the cart's credits are
//! graded against. 1.0 Step 22.
//!
//! ## What the original does
//!
//! `pickup_missileRefill` (00:$399C) with `metroidCountReal` at zero sets
//! `countdownTimerLow` to $FF, asks for song interruption $08 and puts the game
//! in mode $12; the rest of the play handler runs on that frame, and the next
//! is `prepareCredits` (05:$587F). While the countdown runs, that fades: the
//! palette is `credits_paletteFade[countdown >> 5]` into `bg_palette` and both
//! object palettes, until the countdown is under $0E. Then, in one pass, it
//! turns the LCD off, clears the tilemaps and OAM, copies the credits'
//! characters, the stars and the text, turns the LCD back on, sets Samus at
//! ($60, $88), asks for song $13 and moves to mode $13.
//!
//! Mode $13, `creditsRoutine` (05:$55A3), scrolls a pixel every fourth frame
//! and has the vblank handler draw a line of text on each eighth pixel, until
//! the text pointer reaches the $F0; then `credits_scrollingDone` is set and
//! the clock is drawn. Beside it Samus plays one of four endings, by
//! `gameTimeHours`: under 3 her hair let down, 3-5 kneeling in the suit, 5-7
//! running without end, and 7 or more standing without end. Nothing leaves the
//! mode but the soft reset (00:$02E1).
//!
//! ## The clock
//!
//! Frames are 70 224 t-cycles, as `death.zig`'s: with the LCD off the Game Boy
//! takes no vblank, and the cart spends that time under forced blank.

const std = @import("std");
const harness = @import("gb/harness.zig");
const probe = @import("gb/probe.zig");
const lcd = @import("gb/lcd.zig");
const room = @import("room.zig");

const testrom = @import("testrom");

pub const game_mode_addr: u16 = 0xFF9B;
pub const frame_counter_addr: u16 = 0xFF97;
pub const sprite_attr_addr: u16 = 0xFFC7;
pub const countdown_addr: u16 = 0xD066;
pub const item_collected_addr: u16 = 0xD06C;
pub const item_flag_addr: u16 = 0xD06D;
pub const metroid_real_addr: u16 = 0xD089;
pub const minutes_addr: u16 = 0xD098;
pub const hours_addr: u16 = 0xD099;
pub const anim_state_addr: u16 = 0xD097;
pub const scroll_done_addr: u16 = 0xD09F;
pub const scroll_y_addr: u16 = 0xC205;
pub const bg_palette_addr: u16 = 0xD07E;

/// `main_handleGameMode`'s two arms (00:$3E29, $3E34), the top of a pass.
pub const game_mode_prepare_credits: u16 = 0x3E29;
pub const game_mode_credits: u16 = 0x3E34;

pub const mode_play: u8 = 0x04;
pub const mode_prepare: u8 = 0x12;
pub const mode_credits: u8 = 0x13;
/// `pickup_missileRefill`'s number, as `itemCollected` holds it.
pub const item_missile_refill: u8 = 0x0F;

/// The animation's 22 states (05:$5620), and the ones each ending runs through.
pub const anim_states: usize = 0x16;

/// Frame by frame from the frame the refill's lever was pulled, on the 70 224
/// t-cycle clock.
pub const Timeline = struct {
    /// The frame mode $12 was first seen, and mode $13.
    prepare: u32 = 0,
    credits: u32 = 0,
    lcd_off: u32 = 0,
    lcd_on: u32 = 0,
    /// The frame `credits_scrollingDone` went to 1.
    scroll_done: u32 = 0,
    /// The frame each animation state was first entered, mode $13's; zero
    /// for a state this ending never enters (state 0 is entered with the mode).
    states: [anim_states]u32 = @splat(0),
    /// What the frame counter and `hSpriteAttr` held as mode $13 began.
    frame_counter: u8 = 0,
    sprite_attr: u8 = 0,
    /// T-cycles from the last pass of mode $12 (the one that turns the LCD
    /// off) to the first of mode $13, and from the pass before it to it.
    setup_cycles: u64 = 0,
    pass_cycles: u64 = 0,

    pub fn fadeLen(t: Timeline) u32 {
        return t.lcd_off - t.prepare;
    }
    pub fn blankLen(t: Timeline) u32 {
        return t.lcd_on - t.lcd_off;
    }
    pub fn scrollLen(t: Timeline) u32 {
        return t.scroll_done - t.credits;
    }
};

/// Pull the refill's lever with every Metroid dead and the clock at
/// `hours:minutes` (BCD), and time the ending for `frames` frames past it.
/// The lever is the item orb's two stores, as the `gfx` rung's.
pub fn measure(m: *harness.Machine, hours: u8, minutes: u8, frames: u32) !Timeline {
    m.write(metroid_real_addr, 0);
    m.write(hours_addr, hours);
    m.write(minutes_addr, minutes);
    m.write(item_collected_addr, item_missile_refill);
    m.write(item_flag_addr, 0xFF);

    const sys = &m.sys;
    const origin = sys.cpu.cycles;
    var t: Timeline = .{};
    var mode = m.read(game_mode_addr);
    var on = sys.bus.lcd.enabled();
    var state: u8 = 0xFF;
    var done: u8 = 0;
    var last_prepare: u64 = 0;
    var prev_prepare: u64 = 0;

    while (true) {
        const f: u32 = @intCast((sys.cpu.cycles - origin) / lcd.frame_cycles);
        if (f >= frames) return t;
        if (sys.cpu.pc == game_mode_prepare_credits) {
            prev_prepare = last_prepare;
            last_prepare = sys.cpu.cycles;
        }
        if (sys.cpu.pc == game_mode_credits and t.setup_cycles == 0) {
            t.setup_cycles = sys.cpu.cycles - last_prepare;
            t.pass_cycles = last_prepare - prev_prepare;
        }
        _ = try sys.step();
        const b: probe.Buttons = .{};
        sys.bus.setKeys(b.dpad, b.buttons);

        const nm = m.read(game_mode_addr);
        if (nm != mode) {
            switch (nm) {
                mode_prepare => t.prepare = f,
                mode_credits => {
                    t.credits = f;
                    t.frame_counter = m.read(frame_counter_addr);
                    t.sprite_attr = m.read(sprite_attr_addr);
                },
                else => {},
            }
            mode = nm;
        }
        const no = sys.bus.lcd.enabled();
        if (no != on) {
            if (no) t.lcd_on = f else t.lcd_off = f;
            on = no;
        }
        if (mode != mode_credits) continue;
        const ns = m.read(anim_state_addr);
        if (ns != state) {
            if (ns < anim_states and t.states[ns] == 0) t.states[ns] = f;
            state = ns;
        }
        const nd = m.read(scroll_done_addr);
        if (nd != done) {
            if (nd != 0 and t.scroll_done == 0) t.scroll_done = f;
            done = nd;
        }
    }
}

// ---- The `credits` rung's reference (1.0 Step 22c) -------------------------
//
// Both machines are sampled at the top of each pass of `mainGameLoop`, and
// what is read there is the pass before's: the Game Boy at
// `main_handleGameMode`'s two arms, the cart at `CreditsFrame`. Mode $12's
// passes give the fade, a palette each; mode $13's give the scroll, the
// state, the done flag and the objects. The objects are the pass's own OAM
// buffer, taken where the pass returns (00:$02DB) on the Game Boy, before
// `waitForNextFrame` zeroes its index, and on the cart from the shadow and
// `!OamIdx` at the next `CreditsFrame`. The tilemap is read at the next top
// on both, after the vblank that draws a row.

/// Where `mainGameLoop`'s call to `main_handleGameMode` returns (00:$02D8
/// `CALL $02F0`): the end of a pass's mode, before `waitForNextFrame`.
pub const pass_end: u16 = 0x02DB;
pub const boot_routine: u16 = 0x01FB;
pub const oam_index_addr: u16 = 0xFF8D;
pub const oam_buffer: u16 = 0xC000;
pub const oam_max: usize = 40;

/// The passes past the later of the scroll's end and the last state entered
/// that the end must hold for, and that the soft reset is then held after.
pub const hold_passes: u32 = 600;
/// Frames the reset combination may take to reboot, on either machine.
pub const reset_frames: u32 = 8;

/// A clock, BCD, and how the cart reaches the ending: the refill touched with
/// every Metroid killed from the menu, or the WARP page's ENDING.
pub const Route = enum { refill, ending };
pub const Variant = struct {
    name: []const u8,
    hours: u8,
    minutes: u8,
    route: Route,
    /// The cart's `!FrameCount` low byte at its first credits pass: the
    /// route's own, deterministic, and pinned here because our Game Boy's
    /// counter is made to agree with it there (the reference may be set up).
    /// The Lua fails 50 naming the cart's if the route moves it.
    phase: u8,
};

/// Each side of the three hours `credits_animateSamus` tests (`CP $03` at
/// 05:$5796, `CP $05` at $581C, `CP $07` at $57D4). The first takes the
/// game's own way in; the others the WARP page's ENDING.
pub const variants = [_]Variant{
    .{ .name = "2:59", .hours = 0x02, .minutes = 0x59, .route = .refill, .phase = 119 },
    .{ .name = "3:00", .hours = 0x03, .minutes = 0x00, .route = .ending, .phase = 137 },
    .{ .name = "4:59", .hours = 0x04, .minutes = 0x59, .route = .ending, .phase = 145 },
    .{ .name = "5:00", .hours = 0x05, .minutes = 0x00, .route = .ending, .phase = 145 },
    .{ .name = "6:59", .hours = 0x06, .minutes = 0x59, .route = .ending, .phase = 153 },
    .{ .name = "7:00", .hours = 0x07, .minutes = 0x00, .route = .ending, .phase = 153 },
};

/// One mode $13 pass's result, as the next pass's top finds it.
pub const Pass = struct {
    scroll: u8,
    state: u8,
    done: u8,
    /// The objects the pass drew, and `oamHash` over the forty of them the
    /// buffer holds: `drawNonGameSprite` writes on past it, into WRAM nothing
    /// reads, and those are not shown.
    objects: u8,
    hash: u32,
};

/// `oamHash`: the drawn objects in order, each (y, x, tile, attribute) in the
/// Game Boy's terms. The cart's Lua computes the same over its shadow, turned
/// back into them.
pub fn oamHash(entries: []const u8) u32 {
    var h: u32 = 0;
    for (entries) |b| h = h *% 31 +% b;
    return h;
}

pub const Reference = struct {
    /// `bg_palette` after each mode $12 pass, the setup's last.
    fade: []u8,
    passes: []Pass,
    /// The pass each animation state was first entered by, and the one the
    /// scroll finished on. Indexes into `passes`; `null` for a state this
    /// ending never enters.
    states: [anim_states]?u32,
    done: u32,
    /// The passes graded on the whole tilemap and the objects in full.
    samples: []Sample,
    /// The characters the setup leaves: the objects' $8000-$8FFF, and the
    /// background's ids the credits draw, $00-$0F, $20-$3F and $F0-$FF.
    obj_chr: [0x1000]u8,
    bg_chr: [3][0x200]u8,
    /// Frames from the reset combination's first to `bootRoutine`.
    reset: u32,
    /// The pass the end's hold ends on: `hold_passes` past the first on
    /// which the scroll is done and the ending has entered its last state.
    hold: u32,

    pub fn last(r: Reference) u32 {
        var l: u32 = r.done;
        for (r.states) |s| if (s) |x| {
            l = @max(l, x);
        };
        return l;
    }
};

pub const Sample = struct {
    pass: u32,
    map: [0x400]u8,
    oam: [oam_max * 4]u8,
    objects: u8,
};

/// The background's three spans the credits draw from: THE END, the font, the
/// numbers. Game Boy addresses under the signed window.
/// `gfx_theEnd`'s $100 at $9000, the font's $200 at $9200, the numbers' $100
/// at $8F00 (05:$58E0, 05:$4030, 05:$58EC).
pub const BgSpan = struct { at: u16, len: u16 };
pub const bg_spans = [_]BgSpan{ .{ .at = 0x9000, .len = 0x100 }, .{ .at = 0x9200, .len = 0x200 }, .{ .at = 0x8F00, .len = 0x100 } };

/// Our Game Boy from the refill's lever, every pass of the ending to its hold,
/// then the reset combination held. `samples_at` are mode $13 pass numbers.
pub fn reference(a: std.mem.Allocator, m: *harness.Machine, v: Variant, samples_at: []const u32) !Reference {
    m.write(metroid_real_addr, 0);
    m.write(hours_addr, v.hours);
    m.write(minutes_addr, v.minutes);
    m.write(item_collected_addr, item_missile_refill);
    m.write(item_flag_addr, 0xFF);

    var fade: std.ArrayList(u8) = .empty;
    var passes: std.ArrayList(Pass) = .empty;
    var samples: std.ArrayList(Sample) = .empty;
    var r: Reference = undefined;
    r.states = @splat(null);
    r.done = 0;

    const sys = &m.sys;
    var started = false;
    var q: u32 = 0; // mode $13 passes begun
    var end_objects: u8 = 0;
    var end_oam: [oam_max * 4]u8 = @splat(0);
    var hold_until: ?u32 = null;
    var reset_from: ?u64 = null;
    const keys_none: probe.Buttons = .{};
    // A, B, Select and Start all down: the low nibble's bits clear.
    const keys_reset: probe.Buttons = .{ .buttons = 0 };
    var guard: u64 = 0;
    while (guard < 2_000_000_000) : (guard += 1) {
        const pc = sys.cpu.pc;
        if (pc < 0x4000) {
            if (pc == game_mode_prepare_credits) {
                if (started) try fade.append(a, m.read(bg_palette_addr));
                started = true;
            } else if (pc == pass_end and started and m.read(game_mode_addr) == mode_credits) {
                end_objects = m.read(oam_index_addr) / 4;
                for (&end_oam, 0..) |*b, i| b.* = m.read(oam_buffer + @as(u16, @intCast(i)));
            } else if (pc == game_mode_credits) {
                if (q == 0) {
                    try fade.append(a, m.read(bg_palette_addr));
                    m.write(frame_counter_addr, v.phase);
                    @memcpy(&r.obj_chr, sys.bus.vram[0..0x1000]);
                    for (bg_spans, &r.bg_chr) |sp, *c| @memcpy(c[0..sp.len], sys.bus.vram[sp.at - 0x8000 ..][0..sp.len]);
                } else {
                    const p: Pass = .{
                        .scroll = m.read(scroll_y_addr),
                        .state = m.read(anim_state_addr),
                        .done = m.read(scroll_done_addr),
                        .objects = end_objects,
                        .hash = oamHash(end_oam[0 .. @as(usize, @min(end_objects, oam_max)) * 4]),
                    };
                    const i: u32 = @intCast(passes.items.len);
                    if (p.state < anim_states and r.states[p.state] == null) r.states[p.state] = i;
                    if (p.done != 0 and r.done == 0) r.done = i;
                    try passes.append(a, p);
                    const auto = (r.done != 0 and i == r.done + 1) or
                        (hold_until != null and (i == hold_until.? - hold_passes + 1 or i == hold_until.?));
                    if (auto or std.mem.indexOfScalar(u32, samples_at, i) != null) {
                        var smp: Sample = .{ .pass = i, .map = undefined, .oam = end_oam, .objects = end_objects };
                        @memcpy(&smp.map, sys.bus.vram[0x1800..0x1C00]);
                        try samples.append(a, smp);
                    }
                    if (hold_until == null and r.done != 0) {
                        // Every state the ending will enter is in by the scroll's
                        // end but the best ending's, which go on after it.
                        const settled = switch (p.state) {
                            0x15, 0x14 => true,
                            0x01 => v.hours >= 0x05,
                            0x00 => v.hours >= 0x07,
                            else => false,
                        };
                        if (settled) hold_until = i + hold_passes;
                    }
                    if (hold_until) |h| if (i == h and reset_from == null) {
                        reset_from = sys.cpu.cycles;
                        r.hold = h;
                    };
                }
                q += 1;
            } else if (pc == boot_routine) {
                if (reset_from) |o| {
                    r.reset = @intCast((sys.cpu.cycles - o) / lcd.frame_cycles);
                    r.fade = try fade.toOwnedSlice(a);
                    r.passes = try passes.toOwnedSlice(a);
                    r.samples = try samples.toOwnedSlice(a);
                    return r;
                }
            }
        }
        _ = try sys.step();
        const b = if (reset_from != null) keys_reset else keys_none;
        sys.bus.setKeys(b.dpad, b.buttons);
    }
    return error.NeverRebooted;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

/// What our Game Boy measures, pinned; the test re-measures. The setup's pass
/// is 6.94 frames, which the engine's `!CREDITS_SETUP` rounds to 7
/// (`correspond.zig` holds the two together).
pub const setup_cycles: u64 = 487_080;
pub const setup_frames: u64 = (setup_cycles + lcd.frame_cycles / 2) / lcd.frame_cycles;

test "the setup's pass takes the cycles pinned here, at every ending" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    const t = try measure(&m, 0x02, 0x59, 400);
    try testing.expectEqual(setup_cycles, t.setup_cycles);
    try testing.expectEqual(@as(u64, lcd.frame_cycles), t.pass_cycles);
    try testing.expectEqual(@as(u64, 7), setup_frames);
}

test "the credits text is 54 rows of twenty and 170 blanks, to its $F0" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const e = @import("offsets.zig").find("creditsText").?;
    const t = rom[e.romOffset()..e.romEnd()];
    var i: usize = 0;
    var rows: usize = 0;
    var blanks: usize = 0;
    while (t[i] != 0xF0) {
        if (t[i] == 0xF1) {
            blanks += 1;
            i += 1;
        } else {
            rows += 1;
            i += 20;
        }
    }
    try testing.expectEqual(@as(usize, 54), rows);
    try testing.expectEqual(@as(usize, 170), blanks);
    try testing.expectEqual(t.len - 1, i);
}
