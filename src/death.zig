//! Samus's death on the Game Boy, measured: the lengths the cart's death is
//! graded against. Step 15c.
//!
//! ## What the original does
//!
//! `gameMode_Main` tests the *displayed* health after `miscIngameTasks`
//! (00:$04E9) and calls `killSamus` (00:$2FA2) on zero. That silences the audio,
//! asks for noise $0B and waits a frame -- so the rest of it, and the rest of the
//! play handler, belong to the next frame -- then sets `deathAnimTimer` to $20,
//! `deathFlag` to 1 and the game mode to $06.
//!
//! Mode $06 does nothing. The vblank handler does it: while `deathAnimTimer` is
//! nonzero it runs `VBlank_deathSequence` (00:$2FE1) instead of its own body,
//! and on every fourth frame zeroes one byte of every other object tile from
//! `deathAnimationTable`, 32 steps, then sets the mode to $05.
//!
//! Mode $05, `gameMode_dead` (00:$36B0), is a wait on the **sound**: it loops a
//! frame at a time until noise $0B stops playing, which is `noiseSfx_init_B`'s
//! timer ($B0, 04:$57FD `LD A,$B0`) run out by one `handleAudio` a frame from the frame the
//! request was made. Then it turns the LCD off, clears both tilemaps and OAM,
//! copies the title screen's $1000 bytes of characters to $8800, writes
//! `gameOverText` (00:$3711) at row 8 column 6, turns the LCD back on with the
//! window off, sets `countdownTimerLow` to $FF and the mode to $07. The LCD is
//! off for as long as those copies take the CPU, which is five frames.
//!
//! Mode $07, `gameMode_gameOver` (00:$371B), waits a frame and then reboots on
//! the timer or on Start's rising edge. It is two frames a pass, because the
//! main loop waits a second one, and the input is read once a pass.
//!
//! ## The clock
//!
//! Frames here are 70 224 t-cycles, not vblanks. With the LCD off the Game Boy
//! takes no vblank at all, and Mesen2, whose recording is the other witness,
//! keeps counting frames through it; so does the cart, which spends the same
//! time under forced blank. The recording's death (`docs/slice.md`) takes 128
//! frames in $06 and 54 in $05, 182 together; this clock gives 127 and 55, also
//! 182. The one frame moves between them with where in a frame each machine's
//! vblank lands, which is why the cart is graded on these within 2%.

const std = @import("std");
const harness = @import("gb/harness.zig");
const probe = @import("gb/probe.zig");
const lcd = @import("gb/lcd.zig");
const room = @import("room.zig");
const save = @import("save.zig");

const testrom = @import("testrom");

pub const game_mode_addr: u16 = 0xFF9B;
pub const cur_health_addr: u16 = 0xD051;
pub const disp_health_addr: u16 = 0xD084;
pub const noise_playing_addr: u16 = 0xCED6;
pub const countdown_addr: u16 = 0xD066;
pub const kill_samus: u16 = 0x2FA2;
pub const boot_routine: u16 = 0x01FB;

pub const mode_dying: u8 = 0x06;
pub const mode_dead: u8 = 0x05;
pub const mode_game_over: u8 = 0x07;

/// The modes the reboot and the reload run through, in the order the recording
/// shows them (`docs/slice.md`, frames 25 889-25 951): the boot routine's own
/// mode, the title, then the three a load passes through before the play
/// handler takes over. `$03` is where the record is already live -- the frame
/// its position, health and counts are readable in the variables -- and `$04`
/// is the play handler running the appearance sequence's countdown down.
pub const mode_boot: u8 = 0x00;
pub const mode_title: u8 = 0x01;
pub const mode_load_a: u8 = 0x0C;
pub const mode_load_b: u8 = 0x02;
pub const mode_loaded: u8 = 0x03;
pub const mode_play: u8 = 0x04;

/// The noise channel's id for Samus's death, 00:$2FA5 `LD A,$0B`.
pub const noise_killed: u8 = 0x0B;

/// Frame by frame from the frame `killSamus` was entered on, on the 70 224
/// t-cycle clock. Every field is a frame index from that origin.
pub const Timeline = struct {
    dying: u32,
    dead: u32,
    noise_end: u32,
    lcd_off: u32,
    lcd_on: u32,
    game_over: u32,
    /// The frame the machine reached `bootRoutine`.
    reboot: u32,

    pub fn dyingLen(t: Timeline) u32 {
        return t.dead - t.dying;
    }
    pub fn deadLen(t: Timeline) u32 {
        return t.game_over - t.dead;
    }
    pub fn gameOverLen(t: Timeline) u32 {
        return t.reboot - t.game_over;
    }
    pub fn blankLen(t: Timeline) u32 {
        return t.lcd_on - t.lcd_off;
    }
};

/// How the game over screen is left: on the timer with nothing pressed, or on
/// Start held for `hold` frames from `after` frames into mode $07.
pub const Leave = union(enum) {
    timer,
    start: struct { after: u32, hold: u32 },
};

/// What the Game Boy measured, pinned. `zig build test` re-measures both and
/// fails if either moved, so the cart is graded against the machine and not
/// against a number somebody once wrote down.
pub const on_timer: Timeline = .{
    .dying = 1,
    .dead = 128,
    .noise_end = 176,
    .lcd_off = 178,
    .lcd_on = 183,
    .game_over = 183,
    .reboot = 439,
};

/// Start pressed twenty frames into mode $07, for four frames.
pub const start_press: Leave = .{ .start = .{ .after = 20, .hold = 4 } };
pub const on_start: Timeline = .{
    .dying = 1,
    .dead = 128,
    .noise_end = 176,
    .lcd_off = 178,
    .lcd_on = 183,
    .game_over = 183,
    .reboot = 205,
};

/// Kill Samus on a playing machine and time everything up to the reboot.
///
/// The lever is both health pairs at zero, the displayed one because that is
/// what 00:$04EC tests and the real one so `adjustHudValues` has nothing to
/// roll the display back up to.
pub fn measure(m: *harness.Machine, leave: Leave) !Timeline {
    m.write(cur_health_addr, 0);
    m.write(cur_health_addr + 1, 0);
    m.write(disp_health_addr, 0);
    m.write(disp_health_addr + 1, 0);

    const sys = &m.sys;
    var origin: ?u64 = null;
    var t: Timeline = std.mem.zeroes(Timeline);
    var mode = m.read(game_mode_addr);
    var noise = m.read(noise_playing_addr);
    var on = sys.bus.lcd.enabled();

    const budget: u64 = 60_000_000;
    var n: u64 = 0;
    while (n < budget) : (n += 1) {
        const pc = sys.cpu.pc;
        if (origin == null and pc == kill_samus) origin = sys.cpu.cycles;
        const f: u32 = if (origin) |o| @intCast((sys.cpu.cycles - o) / lcd.frame_cycles) else 0;
        if (origin != null and pc == boot_routine) {
            t.reboot = f;
            return t;
        }
        _ = try sys.step();

        var b: probe.Buttons = .{};
        switch (leave) {
            .timer => {},
            .start => |s| if (mode == mode_game_over and f >= t.game_over + s.after and f < t.game_over + s.after + s.hold) {
                b.buttons &= ~@as(u4, 0b1000);
            },
        }
        sys.bus.setKeys(b.dpad, b.buttons);

        if (origin == null) continue;
        const nm = m.read(game_mode_addr);
        if (nm != mode) {
            switch (nm) {
                mode_dying => t.dying = f,
                mode_dead => t.dead = f,
                mode_game_over => t.game_over = f,
                else => {},
            }
            mode = nm;
        }
        const nn = m.read(noise_playing_addr);
        if (nn != noise) {
            if (noise == noise_killed) t.noise_end = f;
            noise = nn;
        }
        const no = sys.bus.lcd.enabled();
        if (no != on) {
            if (no) t.lcd_on = f else t.lcd_off = f;
            on = no;
        }
    }
    return error.NeverRebooted;
}

// ---- The other half of the round trip: the reload --------------------------
//
// The death above ends at the title. What follows it in James's recording is a
// Start that loads the slot back, and that stretch is a *cutscene* in the sense
// the porting loop means: no input decides anything inside it, so it is graded
// by length rather than frame for frame.
//
// **The recording cannot supply that length on its own, and the sub-task that
// asked for it was wrong about what it was measuring.** `zig build gbtrace --
// saves 25850 26000` puts Start's rising edge on the game over screen at
// 25 889, the boot mode at 25 895, the title at 25 900, the *next* Start at
// 25 939 and the play handler at 25 951 -- so of the 52 frames from the death
// to the reload, 39 are James sitting on the title screen deciding to press a
// button. What is machine-determined, and therefore gradable, is the two ends:
// 6 frames from Start to the boot mode and 5 more to the title, then 12 from
// Start to the play handler with the record live on the second of them.
//
// This measures those on our own Game Boy the way `measure` measures the death,
// and the test below checks them against the recording's frames as an
// independent witness.

/// Frames from Start's rising edge on the title, on the same 70 224-cycle clock
/// `Timeline` uses.
pub const Reload = struct {
    /// `gameMode_LoadA`, the mode the title hands to.
    load_a: u32,
    /// `gameMode_LoadB`.
    load_b: u32,
    /// The record is live: position, health and both Metroid counts readable.
    loaded: u32,
    /// The play handler, running the appearance sequence's countdown.
    play: u32,

    /// Start to the play handler, which is the whole cutscene's length.
    pub fn len(r: Reload) u32 {
        return r.play;
    }
};

/// What our Game Boy measures, pinned; the test re-measures and fails if it
/// moved. The recording's own frames are 0, 1, 2 and 12 from its Start.
pub const on_reload: Reload = .{
    .load_a = 0,
    .load_b = 1,
    .loaded = 2,
    .play = 12,
};

/// The recording's, from `zig build gbtrace -- saves 25850 26000`. Carried so
/// the test below compares two machines rather than a machine with itself.
pub const recorded_reload_frames = [_]u32{ 25939, 25940, 25941, 25951 };
/// And the reboot's, from the same pass: Start on the game over screen, the
/// boot mode, the title.
pub const recorded_reboot_frames = [_]u32{ 25889, 25895, 25900 };

/// Load slot 0 back from the title, timing the modes on the way.
///
/// **The record has to be in cartridge RAM before the title initialises**, not
/// before Start is pressed: the title reads the slot on its way in and keeps
/// the answer. Injecting a perfectly good record into a title already on screen
/// sends Start to game mode $0B, a new game, which is how this was found. So
/// the caller either lets the game save (the round trip) or writes the slot
/// before the reboot, and this waits for the title rather than requiring it.
pub fn measureReload(m: *harness.Machine, wait_frames: usize) !Reload {
    var waited: usize = 0;
    while (m.read(game_mode_addr) != mode_title) {
        if (waited >= wait_frames) return error.NeverReachedTitle;
        waited += @intCast(try m.runFrames(1, .{}));
    }

    // **On the 70 224-cycle clock, for the reason the header gives**: mode $03
    // turns the LCD off to copy, so the machine takes no vblank at all for part
    // of the stretch and `runFrames` stops counting. Measured that way the load
    // reaches the play handler in 3 frames where the recording -- whose Mesen
    // keeps counting through the blank -- takes 12, and the 9 frames of
    // difference are entirely the copies.
    //
    // **And a mode this does not time is ignored rather than refused.**
    // `titleScreenRoutine` writes game mode $0B, a new game, and then $0C two
    // instructions later (05:$429A and $42A3), so every load passes through the
    // new game's mode for less than a frame. The recording's end-of-frame
    // census never sees it; an instruction-grained watcher does, and calling
    // that a wrong turn was the first thing this function got wrong.
    const sys = &m.sys;
    var start_keys: probe.Buttons = .{};
    start_keys.buttons &= ~@as(u4, 0b1000);

    var t: Reload = std.mem.zeroes(Reload);
    var origin: ?u64 = null;
    var mode = m.read(game_mode_addr);
    var seen = [_]bool{false} ** 4;

    const budget: u64 = 40_000_000;
    var n: u64 = 0;
    while (n < budget) : (n += 1) {
        _ = try sys.step();

        // Start until the title takes it, then nothing: the game reads a rising
        // edge, and a hold past the load would reach the play handler with a
        // button down, which is what 15b's code 170 grades the absence of.
        const b: probe.Buttons = if (origin == null) start_keys else .{};
        sys.bus.setKeys(b.dpad, b.buttons);

        const nm = m.read(game_mode_addr);
        if (nm == mode) continue;
        mode = nm;
        if (origin == null) {
            if (nm != mode_load_a) continue;
            origin = sys.cpu.cycles;
        }
        const f: u32 = @intCast((sys.cpu.cycles - origin.?) / lcd.frame_cycles);
        switch (nm) {
            mode_load_a => {
                t.load_a = f;
                seen[0] = true;
            },
            mode_load_b => {
                t.load_b = f;
                seen[1] = true;
            },
            mode_loaded => {
                t.loaded = f;
                seen[2] = true;
            },
            mode_play => {
                t.play = f;
                seen[3] = true;
                for (seen) |x| if (!x) return error.ModeSkipped;
                return t;
            },
            else => {},
        }
    }
    return error.NeverLoaded;
}

/// Where the seven banks' saved spawn flags live in cartridge RAM: $B000, an
/// offset of $1000 into the window that starts at $A000.
pub const save_flags_at: usize = 0x1000;

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

fn expectTimeline(want: Timeline, got: Timeline) !void {
    testing.expectEqual(want, got) catch |e| {
        std.debug.print("pinned {any}\nmeasured {any}\n", .{ want, got });
        return e;
    };
}

test "the Game Boy's death takes the frames pinned here, on the timer and on Start" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    var snap = try m.snapshot();
    defer snap.deinit(a);

    try expectTimeline(on_timer, try measure(&m, .timer));
    m.restore(snap);
    try expectTimeline(on_start, try measure(&m, start_press));
}

test "the pinned lengths are the mechanism's: 32 steps of four, the noise's $B0, and $FF on a two-frame pass" {
    // Arithmetic on the pinned numbers, so a re-pin that moved one of them for a
    // reason other than the rule shows up as this test and not only as a diff.
    try testing.expect(on_timer.dyingLen() >= 4 * 0x20 - 3 and on_timer.dyingLen() <= 4 * 0x20);
    // The noise is asked for on the frame `killSamus` runs and starts there;
    // `$B0` frames of decrements later a `handleAudio` finds it spent, and
    // `gameMode_dead` sees that on the frame after and turns the LCD off on
    // the one after that.
    try testing.expectEqual(@as(u32, 0xB0), on_timer.noise_end);
    try testing.expectEqual(on_timer.noise_end + 2, on_timer.lcd_off);
    // $FF frames of timer, read on the second frame of a two-frame pass.
    try testing.expectEqual(@as(u32, 0xFF + 1), on_timer.gameOverLen());
    try testing.expectEqual(on_timer.lcd_on, on_timer.game_over);
}

test "the Game Boy's reload takes the frames pinned here, and the recording agrees" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();

    // The round trip, not a reload on its own: she dies, the cart reboots to
    // the title, and the slot is loaded from there. Start is released and the
    // title given time to settle, because `death.zig`'s own test found that a
    // Start still down through the reboot is not a press.
    @memcpy(m.ram[0..save.recorded_save.len], &save.recorded_save);
    _ = try measure(&m, start_press);
    const got = measureReload(&m, 600) catch |e| {
        std.debug.print("slot[8..12]={X:0>2} {X:0>2} {X:0>2} {X:0>2}  rom[$208B..]={X:0>2} {X:0>2} {X:0>2} {X:0>2}  D0A3={X:0>2} D079={X:0>2} D07A={X:0>2}\n", .{
            m.ram[8], m.ram[9], m.ram[10], m.ram[11],
            rom[0x208B], rom[0x208C], rom[0x208D], rom[0x208E],
            m.read(0xD0A3), m.read(0xD079), m.read(0xD07A),
        });
        std.debug.print("measureReload failed: {s}, mode now ${X:0>2}\n", .{ @errorName(e), m.read(game_mode_addr) });
        return e;
    };
    testing.expectEqual(on_reload, got) catch |e| {
        std.debug.print("pinned {any}\nmeasured {any}\n", .{ on_reload, got });
        return e;
    };

    // The other witness: the recording's own frames, differenced from its
    // Start. Two machines, and nothing here derived from the other.
    const r = recorded_reload_frames;
    try testing.expectEqual(r[0] - r[0], on_reload.load_a);
    try testing.expectEqual(r[1] - r[0], on_reload.load_b);
    try testing.expectEqual(r[2] - r[0], on_reload.loaded);
    try testing.expectEqual(r[3] - r[0], on_reload.play);

    // And the record really did come back: the values are `recorded_save`'s,
    // read out of the live variables rather than out of the slot.
    const want = save.parseInitial(save.recorded_save[save.magic_len..]).?;
    try testing.expectEqual(want.metroid_count_real, m.read(0xD089));
    try testing.expectEqual(want.metroid_count_displayed, m.read(0xD09A));
    try testing.expectEqual(want.level_bank, m.read(0xD811));
    try testing.expectEqual(@as(u8, @truncate(want.health)), m.read(cur_health_addr));
}

test "the 52 frames from the recording's death to its reload are not a length the port can be held to" {
    // The sub-task this closes asked for "the frames from the death at 25 889
    // to the reload at 25 941" as a graded duration. It is not one: the
    // measured pass puts the title at 25 900 and the next Start at 25 939, so
    // 39 of those 52 frames are a human deciding to press a button. What is
    // gradable is the two machine-determined ends, and this pins the split so
    // the wrong reading cannot come back.
    const b = recorded_reboot_frames;
    const r = recorded_reload_frames;
    try testing.expectEqual(@as(u32, 52), r[2] - b[0]);
    // Start to the boot mode, and on to the title: the reboot's own halves.
    try testing.expectEqual(@as(u32, 6), b[1] - b[0]);
    try testing.expectEqual(@as(u32, 5), b[2] - b[1]);
    // The pause, which no port is graded on.
    try testing.expectEqual(@as(u32, 39), r[0] - b[2]);
    // And the reload, which it is.
    try testing.expectEqual(@as(u32, 2), r[2] - r[0]);
    try testing.expectEqual(on_reload.len(), r[3] - r[0]);
    // The three gradable stretches plus the pause are the whole 62 frames from
    // one Start to the other machine's handover, with nothing unaccounted for.
    try testing.expectEqual(r[3] - b[0], (b[1] - b[0]) + (b[2] - b[1]) + (r[0] - b[2]) + on_reload.len());
}

test "a Start held through the reboot does not leave the title, and a fresh one does" {
    // Found by the cart's death rung, whose Start press is this file's and so
    // still down when the Game Boy reboots. `bootRoutine` clears HRAM, the pad's
    // copy with it, so the first read after it is an edge -- and it is
    // `gameMode_Boot`'s frame that takes it, not the title's.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    _ = try measure(&m, start_press);
    var start: probe.Buttons = .{};
    start.buttons &= ~@as(u4, 0b1000);
    _ = try m.runFrames(30, start);
    _ = try m.runFrames(120, .{});
    try testing.expectEqual(@as(u8, 0x01), m.read(game_mode_addr));
    _ = try m.runFrames(4, start);
    _ = try m.runFrames(60, .{});
    try testing.expect(m.read(game_mode_addr) != 0x01);
}
