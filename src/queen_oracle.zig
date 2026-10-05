//! The Queen oracle: her fight on the cart graded against our Game Boy's
//! (1.0 Step 19a).
//!
//! **Both machines enter her room the way their own debug warp does**: our
//! Game Boy by door $19D's index set between frames (`queen.enter`), the cart
//! by the debug menu's QUEEN row, as the `warp` rung's `queen` scenario does.
//! Neither is handed any of her state. Samus stands where she lands, with the
//! new game's loadout on both, and nothing presses a button.
//!
//! **What is compared is each byte's history, collapsed.** Every frame each
//! machine records her whole `$C300` page (the cart keeps it as one page,
//! `!QueenPage`, so a Game Boy address maps by its low byte), the thirteen
//! slots she owns -- her actors, her neck and her projectiles -- at
//! `enemy_oracle.sample_fields`, and Samus's position, pose and health. Each
//! byte's run of identical values is collapsed to one entry, and the cart's
//! entries must be the Game Boy's in order: a state held a frame longer on one
//! machine is not a difference, a state the other never enters is. The
//! enemy oracle does the same per slot, for the same reason.
//!
//! **The Game Boy runs a little longer than the cart**, so a history the cart
//! reaches a frame early is still checked, and a cart history may end one entry
//! short of where the Game Boy's stood at the cart's last frame.
//!
//! **Not graded: the page's pointers into the Game Boy's address space** (the
//! state list, the neck patterns, the head's source, the LCD handler's walk,
//! the death's VRAM and tilemap), whose values are addresses and not state on
//! either machine. What each one drives is graded: the state, the neck's
//! position, the head's frame. A pointer into the page itself keeps its low
//! byte, which is graded.
//!
//! **`frameCounter`'s phase is handed across** (1.0 Step 19b). Her neck
//! retracts on odd frames (03:$73B1 `AND $01`) and the hurt flash runs on one
//! frame in four (03:$6E4A `AND $03`), both off the free-running counter,
//! whose phase at her entry is whatever the frames before it left on either
//! machine. On the first sampled frame the script writes our Game Boy's
//! counter into `!FrameCount`'s low byte; the counter's stepping, and what
//! each reader does with it, is still graded. Left alone, the cart retracted
//! on the frames the Game Boy did not and the histories parted at frame 265.
//!
//! **And one byte**: the `rDIV` read in `queenStateFunc_prepExtendingNeck`
//! (03:$78D1), which leaves her mouth shut one time in four. The Game Boy's
//! run records each value it read; the cart's script writes the same into
//! `!DivClock`'s high byte as the port's read (`QueenPrepExtend_coin`) is
//! about to run, as `enemy_oracle`'s `Case.dividers` does.
//!
//! **Each cart frame is read where the main loop wakes from NMI**
//! (`MainLoop_woke`, 1.0 Step 19b), as our Game Boy's frame is read past its
//! vblank handler. Her feet and head are drawn in the vblank and step bytes
//! her states set in the same frame (`queen_footFrame`, `queen_headFrameNext`);
//! read at the end of the frame, before NMI, the cart showed values the Game
//! Boy never holds when it is read.
//!
//! **The window ends before Samus dies**: with no input, her projectiles and
//! lunges kill Samus on frame 614, and a death is Step 20's and the death
//! sequence's to grade.

const std = @import("std");
const harness = @import("gb/harness.zig");
const room = @import("room.zig");
const queen = @import("queen.zig");
const warp = @import("warp.zig");
const warp_grade = @import("warp_grade.zig");
const debug_tables = @import("debug_tables.zig");
const enemy_oracle = @import("enemy_oracle.zig");
const inject = @import("snes_inject.zig");
const ppu_mod = @import("gb/ppu.zig");
const target = @import("snes_target.zig");
const oracle = @import("oracle.zig");
const scenario = @import("scenario.zig");

pub const Error = error{ NoQueenEntry, NeverDied, TooManyDivs, NoSymbol, ScreenPartial, UnknownBgp, PressesOnLag };

/// The Game Boy's `$C300` page: `oamScratchpad`, the special enemies' bytes
/// and hers, all cleared by `queen_initialize`.
pub const gb_page: u16 = 0xC300;
/// Her slots: `queen_initialize` clears thirteen (03:$6DCF).
pub const slot_count: usize = 13;
const gb_slots: u16 = 0xC600;
const slot_size: u16 = 0x20;

/// Page bytes that hold an address outside the page, from M2RoS
/// `SRC/ram/wram.asm`. Each is named, so a new exclusion is a decision.
pub const pointers = [_]struct { gb: u16, what: []const u8 }{
    .{ .gb = 0xC3A6, .what = "queen_pNeckPatternLow" },
    .{ .gb = 0xC3A7, .what = "queen_pNeckPatternHigh" },
    .{ .gb = 0xC3AA, .what = "queen_pInterruptListLow: the LCD handler's walk, which HDMA does not make" },
    .{ .gb = 0xC3AB, .what = "queen_pInterruptListHigh" },
    .{ .gb = 0xC3B9, .what = "queen_pOamScratchpadHigh: $C3 against the cart's page" },
    .{ .gb = 0xC3C4, .what = "queen_pNextStateLow" },
    .{ .gb = 0xC3C5, .what = "queen_pNextStateHigh" },
    .{ .gb = 0xC3CD, .what = "queen_pNeckPatternBaseLow" },
    .{ .gb = 0xC3CE, .what = "queen_pNeckPatternBaseHigh" },
    .{ .gb = 0xC3DE, .what = "queen_pDeathChrLow" },
    .{ .gb = 0xC3DF, .what = "queen_pDeathChrHigh" },
    .{ .gb = 0xC3EC, .what = "queen_pDeleteBodyLow" },
    .{ .gb = 0xC3ED, .what = "queen_pDeleteBodyHigh" },
    .{ .gb = 0xC3F3, .what = "queen_headSrcHigh: the cart keeps an offset into its copy" },
    .{ .gb = 0xC3F4, .what = "queen_headSrcLow" },
};

/// The page's names, for the report. Unnamed bytes print as their address.
const names = [_]struct { gb: u16, name: []const u8 }{
    .{ .gb = 0xC3A0, .name = "queen_bodyY" },
    .{ .gb = 0xC3A1, .name = "queen_bodyXScroll" },
    .{ .gb = 0xC3A2, .name = "queen_bodyHeight" },
    .{ .gb = 0xC3A3, .name = "queen_walkWaitTimer" },
    .{ .gb = 0xC3A4, .name = "queen_walkCounter" },
    .{ .gb = 0xC3A8, .name = "queen_headX" },
    .{ .gb = 0xC3A9, .name = "queen_headY" },
    .{ .gb = 0xC3AC, .name = "queen_headBottomY" },
    .{ .gb = 0xC3B6, .name = "queen_neckXMovementSum" },
    .{ .gb = 0xC3B7, .name = "queen_neckYMovementSum" },
    .{ .gb = 0xC3B8, .name = "queen_pOamScratchpadLow" },
    .{ .gb = 0xC3BA, .name = "queen_neckDrawingState" },
    .{ .gb = 0xC3BB, .name = "queen_cameraDeltaX" },
    .{ .gb = 0xC3BC, .name = "queen_cameraDeltaY" },
    .{ .gb = 0xC3BD, .name = "queen_walkControl" },
    .{ .gb = 0xC3BE, .name = "queen_neckSelectionFlag" },
    .{ .gb = 0xC3BF, .name = "queen_walkStatus" },
    .{ .gb = 0xC3C0, .name = "queen_neckControl" },
    .{ .gb = 0xC3C1, .name = "queen_neckStatus" },
    .{ .gb = 0xC3C2, .name = "queen_walkSpeed" },
    .{ .gb = 0xC3C3, .name = "queen_state" },
    .{ .gb = 0xC3C6, .name = "queen_cameraX" },
    .{ .gb = 0xC3C7, .name = "queen_cameraY" },
    .{ .gb = 0xC3C8, .name = "queen_footFrame" },
    .{ .gb = 0xC3C9, .name = "queen_footAnimCounter" },
    .{ .gb = 0xC3CA, .name = "queen_headFrameNext" },
    .{ .gb = 0xC3CB, .name = "queen_headFrame" },
    .{ .gb = 0xC3CC, .name = "queen_neckPattern" },
    .{ .gb = 0xC3CF, .name = "queen_delayTimer" },
    .{ .gb = 0xC3D0, .name = "queen_stunTimer" },
    .{ .gb = 0xC3D1, .name = "queen_stomachBombedFlag" },
    .{ .gb = 0xC3D2, .name = "queen_bodyPalette" },
    .{ .gb = 0xC3D3, .name = "queen_health" },
    .{ .gb = 0xC3E3, .name = "queen_projectilesActiveFlag" },
    .{ .gb = 0xC3E4, .name = "queen_projectileTempDirection" },
    .{ .gb = 0xC3E5, .name = "queen_projectileChaseTimer" },
    .{ .gb = 0xC3EE, .name = "queen_projectileChaseCounter" },
    .{ .gb = 0xC3EF, .name = "queen_lowHealthFlag" },
    .{ .gb = 0xC3F0, .name = "queen_flashTimer" },
    .{ .gb = 0xC3F1, .name = "queen_midHealthFlag" },
    .{ .gb = 0xC3F2, .name = "queen_headDest" },
};

fn isPointer(gb: u16) bool {
    for (pointers) |p| if (p.gb == gb) return true;
    return false;
}

/// Where a graded byte lives on the cart: an engine symbol and an offset.
pub const Cart = struct { sym: []const u8, ofs: u16 };

/// One graded byte.
/// `lead`: the cart reads it off the sound engine's reply, two ticks behind
/// the Game Boy's (`docs/audio_protocol.md`), so its history may begin with
/// the value before the Game Boy's first.
pub const Var = struct { gb: u16, cart: Cart, name: []const u8, lead: bool = false };

const page_vars: usize = 256 - pointers.len;
const slot_vars: usize = slot_count * enemy_oracle.sample_fields.len;
/// Samus: y and x (pixel, screen), pose, and health (low, high).
const samus_vars: usize = 7;
/// Her hurt's (1.0 Step 19c): `queen_eatingState`, which the open mouth's
/// missile sets to the stun's $10, and `collision_weaponType`, which she
/// spends. Not `sfxRequest_noise`: our Game Boy's `handleAudio` clears it in
/// the frame and the cart's request byte is a recording stub, so the two are
/// different mechanisms (`audio_sites` holds the cry's store to a put).
const hurt_vars: usize = 2;
/// Her death's (1.0 Step 20c): `metroidCountReal` and
/// `metroidCountDisplayed`, which `queenStateFunc_deleteBody` zeroes,
/// `metroidCountShuffleTimer`, which it starts, and `earthquakeTimer`, which
/// `queenStateFunc_prepDeath` does.
const death_vars: usize = 4;
const shot_vars: usize = 4;
/// Out of her room (1.0 Step 20d): `queen_roomFlag`, which `EXIT_QUEEN`
/// clears and a `WARP` takes to its low nibble; the map bank and the camera,
/// which the `WARP` after either opcode moves and `ESCAPE_QUEEN` places (the
/// bank as the save buffer keeps it: the cart's `!MapIndex` counts from 0); and
/// `songPlaying`, which the quake's end in her room makes the baby's song
/// (01:$7A2E), as the cart's sound engine reports it.
const leave_vars: usize = 7;
pub const var_count: usize = page_vars + slot_vars + samus_vars + hurt_vars + death_vars + shot_vars + leave_vars;

pub const vars: [var_count]Var = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [var_count]Var = undefined;
    var n: usize = 0;
    for (0..256) |i| {
        const gb: u16 = gb_page + @as(u16, @intCast(i));
        if (isPointer(gb)) continue;
        var name: []const u8 = std.fmt.comptimePrint("${X:0>4}", .{gb});
        for (names) |nm| {
            if (nm.gb == gb) name = nm.name;
        }
        if (gb >= 0xC308 and gb < 0xC338) name = std.fmt.comptimePrint("queen_objectOAM+{d}", .{gb - 0xC308});
        if (gb >= 0xC338 and gb < 0xC368) name = std.fmt.comptimePrint("queen_wallOAM+{d}", .{gb - 0xC338});
        out[n] = .{ .gb = gb, .cart = .{ .sym = "VarQueenPage", .ofs = @intCast(i) }, .name = name };
        n += 1;
    }
    for (0..slot_count) |s| {
        for (enemy_oracle.sample_fields) |f| {
            const o: u16 = @as(u16, @intCast(s)) * slot_size + f;
            out[n] = .{ .gb = gb_slots + o, .cart = .{ .sym = "VarSlots", .ofs = o }, .name = std.fmt.comptimePrint("slot {d} +${X:0>2}", .{ s, f }) };
            n += 1;
        }
    }
    out[n + 0] = .{ .gb = room.samus_pixel_y_addr, .cart = .{ .sym = "VarSamusY", .ofs = 0 }, .name = "Samus y" };
    out[n + 1] = .{ .gb = room.samus_screen_y_addr, .cart = .{ .sym = "VarSamusY", .ofs = 1 }, .name = "Samus y screen" };
    out[n + 2] = .{ .gb = room.samus_pixel_x_addr, .cart = .{ .sym = "VarSamusX", .ofs = 0 }, .name = "Samus x" };
    out[n + 3] = .{ .gb = room.samus_screen_x_addr, .cart = .{ .sym = "VarSamusX", .ofs = 1 }, .name = "Samus x screen" };
    out[n + 4] = .{ .gb = gb_pose, .cart = .{ .sym = "VarPose", .ofs = 0 }, .name = "Samus pose" };
    out[n + 5] = .{ .gb = gb_health, .cart = .{ .sym = "VarHealthLo", .ofs = 0 }, .name = "Samus health" };
    out[n + 6] = .{ .gb = gb_health + 1, .cart = .{ .sym = "VarHealthLo", .ofs = 1 }, .name = "Samus health high" };
    n += samus_vars;
    out[n + 0] = .{ .gb = 0xD090, .cart = .{ .sym = "VarQueenEating", .ofs = 0 }, .name = "queen_eatingState" };
    out[n + 1] = .{ .gb = 0xD05D, .cart = .{ .sym = "VarCollWeapon", .ofs = 0 }, .name = "collision_weaponType" };
    n += hurt_vars;
    out[n + 0] = .{ .gb = 0xD089, .cart = .{ .sym = "VarMetReal", .ofs = 0 }, .name = "metroidCountReal" };
    out[n + 1] = .{ .gb = 0xD09A, .cart = .{ .sym = "VarMetDisp", .ofs = 0 }, .name = "metroidCountDisplayed" };
    out[n + 2] = .{ .gb = 0xD096, .cart = .{ .sym = "VarShuffle", .ofs = 0 }, .name = "metroidCountShuffleTimer" };
    out[n + 3] = .{ .gb = 0xD083, .cart = .{ .sym = "VarQuakeTimer", .ofs = 0 }, .name = "earthquakeTimer" };
    n += death_vars;
    for (0..shot_vars) |i| {
        out[n + i] = .{ .gb = 0xDD20 + @as(u16, @intCast(i)), .cart = .{ .sym = "VarProjs", .ofs = 0x20 + @as(u16, @intCast(i)) }, .name = std.fmt.comptimePrint("missile +{d}", .{i}) };
    }
    n += shot_vars;
    out[n + 0] = .{ .gb = queen.room_flag_addr, .cart = .{ .sym = "VarRoomMode", .ofs = 0 }, .name = "queen_roomFlag" };
    out[n + 1] = .{ .gb = 0xD811, .cart = .{ .sym = "VarSaveBuf", .ofs = 0x11 }, .name = "saveBuf_currentLevelBank" };
    out[n + 2] = .{ .gb = room.camera_pixel_y_addr, .cart = .{ .sym = "VarCamY", .ofs = 0 }, .name = "camera y" };
    out[n + 3] = .{ .gb = room.camera_screen_y_addr, .cart = .{ .sym = "VarCamY", .ofs = 1 }, .name = "camera y screen" };
    out[n + 4] = .{ .gb = room.camera_pixel_x_addr, .cart = .{ .sym = "VarCamX", .ofs = 0 }, .name = "camera x" };
    out[n + 5] = .{ .gb = room.camera_screen_x_addr, .cart = .{ .sym = "VarCamX", .ofs = 1 }, .name = "camera x screen" };
    out[n + 6] = .{ .gb = gb_song_playing, .cart = .{ .sym = "VarAudReply", .ofs = 6 }, .name = "songPlaying", .lead = true };
    n += leave_vars;
    std.debug.assert(n == var_count);
    break :blk out;
};

const gb_pose: u16 = 0xD020;
const gb_song_playing: u16 = 0xCEDD;
const gb_health: u16 = 0xD051; // samusCurHealthLow
const gb_death: u16 = 0xD063; // deathFlag
const gb_frame_counter: u16 = 0xFF97; // frameCounter
/// The `rDIV` read: `LD A,(rDIV)` at 03:$78D1 is three bytes, and the operand
/// comes off the bus with the PC past it.
pub const div_pc: u16 = 0x78D4;
/// The port's read, which the cart's script hands each value to.
pub const div_cart = "QueenPrepExtend_coin";
const div_bank: u8 = 3;
pub const max_divs: usize = 64;

pub const Sample = [var_count]u8;

/// Our Game Boy's fight, from its first frame in her room.
pub const GbFight = struct {
    samples: []Sample,
    /// The first sample on which `deathFlag` is up, or `samples.len`.
    death: usize,
    /// `frameCounter` on the first sample.
    counter: u8,
    divs: []u8,
    /// The play window's shades on each frame the case grades on the screen.
    screens: []Screen,
    /// The sampled frames no pass of our Game Boy's main loop woke before:
    /// `frameCounter` as it was on the frame before (`vblankBuilt`).
    lag: []u16,
    /// The pad both machines are held to: the case's, or for a case that
    /// keeps its presses off our Game Boy's lag, the one that does.
    script: []const Hold = &.{},
    /// `death_cells` of the Game Boy's map on the last sampled frame.
    cells: [death_cells.len]u8 = @splat(0),
};

/// The map cells her death writes (1.0 Step 20c): `queenStateFunc_deleteBody`'s
/// rows 13 to 19, eleven cells each from $99A0, and `queen_closeFloor`'s two
/// at $9B0E. Once her characters are spent her body's cells draw as $FF does,
/// so the screen cannot tell them apart; the map can.
pub const death_cells = blk: {
    var out: [7 * 11 + 2]u16 = undefined;
    var n: usize = 0;
    for (13..20) |r| for (0..11) |c| {
        out[n] = r * 32 + c;
        n += 1;
    };
    out[n] = 24 * 32 + 14;
    out[n + 1] = 24 * 32 + 15;
    break :blk out;
};

/// The bytes `VBlank_drawQueen` (03:$7CF0) builds out of the main loop's:
/// `queen_headBottomY` and the LCD handler's list. On a frame our Game Boy's
/// pass overran, its vblank built them from a pass half done, and the next
/// frame's from the one after: a value the cart, which kept up, builds and
/// our Game Boy never does (1.0 Step 20a, `mouth` frame 520). Lag is the
/// port's defect, not the original's to copy (`01-requirements.md`), so on
/// those frames, and only for these bytes, the cart is not graded.
pub fn vblankBuilt(gb: u16) bool {
    return gb >= 0xC3AC and gb <= 0xC3B5;
}

/// One sampled frame as our Game Boy drew it: 160x144 shades, 0-3, and the
/// BGP each line latched.
pub const Screen = struct { frame: u16, shades: []const u8, bgp: []const u8 };

/// What the cart shows a Game Boy line's BGP as (1.0 Step 19c): INIDISP's
/// brightness, `oracle.brightnessFor`'s four, and COLDATA, the white her
/// flash's $03 adds over a full brightness.
pub fn bandFor(bgp: u8) ?[2]u8 {
    if (bgp == 0x93 ^ 0x90) return .{ 15, 0xFF };
    const b = oracle.brightnessFor(bgp) orelse return null;
    return .{ b, 0xE0 };
}

const DivWatch = struct {
    m: *harness.Machine,
    vals: [max_divs]u8 = undefined,
    n: usize = 0,
    over: bool = false,
    fn read(ctx: *anyopaque, bus: *const @import("gb/bus.zig").Bus, addr: u16, value: u8) void {
        const self: *DivWatch = @ptrCast(@alignCast(ctx));
        if (addr != 0xFF04 or bus.cart.highBank() != div_bank or self.m.sys.cpu.pc != div_pc) return;
        if (self.n == max_divs) {
            self.over = true;
            return;
        }
        self.vals[self.n] = value;
        self.n += 1;
    }
};

pub const Hold = queen.Hold;
pub const holdAt = queen.holdAt;

/// Mesen's `setInput` table for a hold.
pub fn writeHoldLua(h: Hold, w: *std.Io.Writer) !void {
    try w.print("{{", .{});
    inline for (.{ "right", "left", "up", "down", "b", "y", "select" }) |k| {
        if (@field(h, k)) try w.print(" {s} = true,", .{k});
    }
    try w.print(" }}", .{});
}

/// 1.0 Step 19c: Samus selects missiles as she falls in, turns to face her once
/// she stands, and fires every 24 frames, and every 6 while her mouth is open
/// (our Game Boy's frames 316-338). On our Game Boy the head takes its first
/// missile on frame 254, the open mouth one on frame 332, which stuns her, and
/// the stunned mouth more.
pub const volley: []const Hold = blk: {
    var out: []const Hold = &.{ .{ .from = 0 }, .{ .from = 4, .select = true }, .{ .from = 5 }, .{ .from = 70, .left = true }, .{ .from = 72 } };
    var t: u16 = 80;
    while (t < search_frames) : (t += if (t >= 300 and t < 345) 6 else 24) {
        out = out ++ [_]Hold{ .{ .from = t, .y = true }, .{ .from = t + fire_hold } };
    }
    break :blk out;
};

/// 1.0 Step 20a: the volley's opening to the stun, with FULL LOADOUT; then
/// the ball, and a Spring Ball jump left into the stunned mouth.
pub const mouth: []const Hold = blk: {
    var out: []const Hold = &.{ .{ .from = 0 }, .{ .from = 4, .select = true }, .{ .from = 5 }, .{ .from = 70, .left = true }, .{ .from = 72 } };
    var t: u16 = 80;
    while (t < 336) : (t += if (t >= 300) 6 else 24) {
        out = out ++ [_]Hold{ .{ .from = t, .y = true }, .{ .from = t + fire_hold } };
    }
    out = out ++ [_]Hold{
        .{ .from = 340, .down = true }, .{ .from = 343 },
        .{ .from = 346, .down = true }, .{ .from = 349 },
        .{ .from = 352, .b = true, .left = true }, .{ .from = 380 },
        .{ .from = 420, .y = true }, .{ .from = 424 },
    };
    break :blk out;
};

/// 1.0 Step 20b: the mouth's opening to her mouth shut on Samus; then a
/// press of left, which swallows her, and a bomb in the stomach.
pub const stomach: []const Hold = blk: {
    var out: []const Hold = mouth[0 .. mouth.len - 2];
    out = out ++ [_]Hold{
        .{ .from = 440, .left = true }, .{ .from = 444 },
        .{ .from = 520, .y = true },    .{ .from = 524 },
    };
    break :blk out;
};

/// 1.0 Step 20c: the volley's opening, with FULL LOADOUT, and a missile every
/// eight frames until she dies: 150 of them land, in her head and her open
/// mouth, and on our Game Boy the last on frame 2 529.
pub const kill: []const Hold = blk: {
    @setEvalBranchQuota(100_000);
    var out: []const Hold = &.{ .{ .from = 0 }, .{ .from = 4, .select = true }, .{ .from = 5 }, .{ .from = 70, .left = true }, .{ .from = 72 } };
    var t: u16 = 80;
    while (t < kill_last_shot) : (t += 8) {
        out = out ++ [_]Hold{ .{ .from = t, .y = true }, .{ .from = t + fire_hold } };
    }
    break :blk out;
};

/// The holds of `script` that press a button and begin on the frame after
/// one our Game Boy lags on (1.0 Step 20c). There its pass, which began late,
/// reads the pad a frame sooner than when it keeps up, and sooner than the
/// cart, which keeps up: the original's lag, which the port is not to copy,
/// moving her world by a frame. On the `kill` case a missile fired so on frame
/// 680 flew a frame ahead of the cart's, and from frame 2 213 a spit it hit on
/// one machine it missed on the other. A press that begins on a lag frame
/// itself is read when the cart reads it.
pub fn pressesOnLag(script: []const Hold, lag: []const u16) []const u16 {
    const S = struct {
        var buf: [1024]u16 = undefined;
    };
    var n: usize = 0;
    for (script) |h| {
        if (!pressed(h)) continue;
        for (lag) |l| if (h.from == l + 1) {
            if (n < S.buf.len) S.buf[n] = h.from;
            n += 1;
            break;
        };
    }
    return S.buf[0..@min(n, S.buf.len)];
}

/// 1.0 Step 20c: the mouth's kill. The kill's missiles until her health is
/// under ten, in her stunned mouth; then, as `mouth` does, the ball, a Spring
/// Ball jump left into the stunned mouth, and a bomb on her head, which costs
/// the ten she does not have (03:$7794): eating state $20.
pub const mouth_kill: []const Hold = blk: {
    @setEvalBranchQuota(100_000);
    var out: []const Hold = &.{ .{ .from = 0 }, .{ .from = 4, .select = true }, .{ .from = 5 }, .{ .from = 70, .left = true }, .{ .from = 72 } };
    var t: u16 = 80;
    while (t <= mouth_kill_last_shot) : (t += 8) {
        out = out ++ [_]Hold{ .{ .from = t, .y = true }, .{ .from = t + fire_hold } };
    }
    const r = mouth_kill_last_shot + 12;
    out = out ++ [_]Hold{
        .{ .from = r, .down = true },      .{ .from = r + 3 },
        .{ .from = r + 6, .down = true },  .{ .from = r + 9 },
        .{ .from = r + 12, .b = true, .left = true }, .{ .from = r + 40 },
        .{ .from = mouth_kill_bomb, .y = true }, .{ .from = mouth_kill_bomb + 4 },
    };
    break :blk out;
};
const mouth_kill_last_shot: u16 = 2400;
const mouth_kill_bomb: u16 = 2492;

/// The kill's last press: past it nothing is fired.
const kill_last_shot: u16 = 2530;

/// 1.0 Step 20d: the kill, then left out of her room. Door $19E at count
/// $00 runs $19F: `EXIT_QUEEN` and `WARP $F,$A9`.
pub const exit: []const Hold = kill ++ [_]Hold{
    .{ .from = exit_walk, .left = true },
    .{ .from = exit_walk + 50, .left = true, .b = true },
    .{ .from = exit_walk + 80, .left = true },
};
const exit_walk: u16 = 3100;

/// 1.0 Step 20d: out alive. The ball, rolled left off the floor into column
/// 7's shaft and along row 14 to her room's edge, which `queen_closeFloor`
/// seals only at her death. Door $19E at count $01 runs `ESCAPE_QUEEN` and
/// `WARP $E,$C1`.
pub const escape: []const Hold = &.{
    .{ .from = 0 },
    .{ .from = 76, .down = true }, .{ .from = 79 },
    .{ .from = 82, .down = true }, .{ .from = 85 },
    .{ .from = 88, .left = true },
};

/// Frames each shot's button is held. One is a press our Game Boy can miss: on
/// a frame its main loop has overrun, the pad is not read.
const fire_hold: u16 = 4;

/// The frames a case's GB run keeps the screen of: its screens' and bands'.
pub fn framesOf(a: std.mem.Allocator, case: Case) ![]const u16 {
    var out: std.ArrayList(u16) = .empty;
    for ([_][]const u16{ case.screens, case.bands }) |list| for (list) |f| {
        if (std.mem.indexOfScalar(u16, out.items, f) == null) try out.append(a, f);
    };
    return out.toOwnedSlice(a);
}

/// One fight the oracle runs: the pad both machines are held to; the sampled
/// frames whose play window is compared, objects aside; and those whose BGP
/// bands are, line by line, as INIDISP and COLDATA (`bandFor`).
/// And `loadout` (1.0 Step 20a): the cart takes the menu's FULL LOADOUT
/// before its warp, and our Game Boy the same items written as it enters;
/// `window`, the frames graded when Samus outlives them; `unbuilt`, the
/// values the cart builds on our Game Boy's lag frames that its vblank never
/// did (`vblankBuilt`), pinned exactly so a new one is a decision.
pub const Case = struct { name: []const u8, script: []const Hold, screens: []const u16 = &.{}, bands: []const u16 = &.{}, faults: []const Fault, loadout: bool = false, window: ?usize = null, unbuilt: usize = 0, frames: usize = search_frames, death: bool = false, off_lag: bool = false };

/// Our Game Boy's lag frames inside `case`'s window.
pub fn lagIn(case: Case, gb: GbFight) usize {
    const n = windowOf(case, gb);
    var c: usize = 0;
    for (gb.lag) |f| {
        if (f < n) c += 1;
    }
    return c;
}

/// The frames of `case` graded, given our Game Boy's run of it.
pub fn windowOf(case: Case, gb: GbFight) usize {
    const to_death = gb.death - before_death - slack;
    return if (case.window) |w| @min(w, to_death) else to_death;
}
pub const cases = [_]Case{
    // Past her entry's fade, which door $19D runs on our Game Boy and the
    // debug warp does not (the `queen` scenario starts at 60 for the same
    // reason): BGP $93 down the whole screen, her body's band apart.
    //
    // And on past the death she deals Samus on 614 (1.0 Step 25): our Game
    // Boy's mode $07, the GAME OVER screen, runs 791-1046, and on 900 the
    // play window is that screen alone. `gameMode_dead` clears her room flag
    // (00:$36BB); without it her bands and feet come back over the text.
    .{ .name = "still", .script = &.{}, .screens = &.{900}, .bands = &.{ 40, 200 }, .faults = &(faults ++ still_faults) },
    // On our Game Boy the hit on frame 274 turns `queen_bodyPalette` to $03 on
    // 277, and her body's band shows BGP $03 from frame 278 to 281, a frame
    // behind: 276 and 283 either side, 200 with her walking.
    .{ .name = "volley", .script = volley, .screens = &.{ 200, 276, 278, 279, 280, 281, 283 }, .bands = &.{ 276, 278, 281, 283 }, .faults = &volley_faults },
    // Rolled into her stunned mouth on 354, bombed out on 516. Our Game Boy's
    // pass overruns on 520, as the bomb lets her go: its vblank builds her
    // list from the body's Y two passes back, and three bytes of it, which
    // the cart builds on time, are never built there.
    .{ .name = "mouth", .script = mouth, .faults = &mouth_faults, .loadout = true, .window = 700, .unbuilt = 3 },
    // Swallowed on 444, in her stomach on 504, the bomb's hit on 616: thrown
    // up her bent neck, out on 656, her health down thirty on 708, and the
    // walk back on 720. Our Game Boy lags every fourth frame while her head
    // moves, and on eight of them, as she swallows and as the neck goes out,
    // its vblank builds three bytes of her list the cart builds on time.
    .{ .name = "stomach", .script = stomach, .faults = &stomach_faults, .loadout = true, .window = 900, .unbuilt = 24 },
    // Under ten health on 2 401, rolled into her stunned mouth and in it on
    // 2 482; the bomb on her head lets Samus go dying ($20), and state $0A
    // finds no health and kills her from the stomach. As in `stomach`, our
    // Game Boy lags while her bent neck goes out, and on four of those
    // frames its vblank builds three bytes of her list the cart builds on
    // time.
    .{ .name = "mouth_kill", .script = mouth_kill, .faults = &mouth_kill_faults, .loadout = true, .frames = 3330, .death = true, .off_lag = true, .unbuilt = 12 },
    .{ .name = "kill", .script = kill, .faults = &kill_faults, .loadout = true, .frames = 3260, .death = true, .off_lag = true, .screens = &.{ 2500, 2600, 2700, 2800, 2900, 3000, 3080, 3088, 3090, 3240 } },
    // 1.0 Step 20d. The kill, then over her spent body and left: door $19E
    // on 3 275 runs $19F, `EXIT_QUEEN` clears her room flag on 3 374 and the
    // `WARP` puts Samus in $F:$A9 on 3 376. Graded to the arrival: in the new
    // room our Game Boy lags every fourth frame from 3 383, and a lag frame
    // steps the camera twice where the cart, which keeps up, steps it once.
    // And the screen, as `escape`'s: the room alone on 3 280, black from
    // 3 320 while `LOAD_bg` and `LOAD_spr` change it, and on 3 374.
    .{ .name = "exit", .script = exit, .faults = &exit_faults, .loadout = true, .frames = 3400, .window = 3383, .off_lag = true, .screens = &.{ 3280, 3320, 3360, 3374 } },
    // 1.0 Step 20d. The ball off the floor into column 7's shaft: door $19E
    // on 163 runs `ESCAPE_QUEEN` on 256 and the `WARP` puts her in $E:$C1 on
    // 261; her room flag goes to $01 on 266. Graded to 270, where our Game
    // Boy's lag in the new room begins, as in `exit`. And the screen (James's
    // playtest, 1.0 Step 20): from the door on, nothing arms her list, so on
    // 168 the room fills the screen without her head or the status bar, and
    // `FADEOUT` has it black by 215, before `LOAD_bg` and the `WARP` change
    // it. 180 and 200 are the fade's steps, which are brightness here and a
    // DMG palette there, and the `fade` rung's.
    .{ .name = "escape", .script = escape, .faults = &escape_faults, .frames = 300, .window = 270, .screens = &.{ 168, 215, 256, 262 } },
};

/// Boot into play, enter her room by door $19D, and record `count` frames
/// from the second one drawn there, which is the cart's first after its warp
/// (see `warp_grade`'s `queen` scenario).
pub fn runGb(a: std.mem.Allocator, rom: []const u8, count: usize) !GbFight {
    return runGbScripted(a, rom, count, &.{}, &.{}, false);
}

/// `case` on our Game Boy, `case.frames` long. A case that keeps its presses
/// off our Game Boy's lag (`Case.off_lag`) is run again with each press that
/// begins on the frame after a lag frame moved a frame on, until none does
/// (`pressesOnLag`).
pub fn runGbCase(a: std.mem.Allocator, rom: []const u8, case: Case) !GbFight {
    const shots = try framesOf(a, case);
    if (!case.off_lag) {
        var gb = try runGbScripted(a, rom, case.frames, case.script, shots, case.loadout);
        gb.script = case.script;
        return gb;
    }
    const script = try a.dupe(Hold, case.script);
    for (0..max_lag_moves) |_| {
        var gb = try runGbScripted(a, rom, case.frames, script, shots, case.loadout);
        const on = pressesOnLag(script, gb.lag);
        if (on.len == 0) {
            gb.script = script;
            return gb;
        }
        for (on) |at| for (script, 0..) |*h, i| if (h.from == at) {
            h.from += 1;
            // Its release with it, so the press is still `fire_hold` long.
            if (i + 1 < script.len and !pressed(script[i + 1]) and script[i + 1].from <= at + fire_hold) script[i + 1].from += 1;
            break;
        };
    }
    return Error.PressesOnLag;
}

/// How many times `runGbCase` moves presses off our Game Boy's lag.
const max_lag_moves: usize = 16;

fn pressed(h: Hold) bool {
    return h.y or h.b or h.select or h.left or h.right or h.up or h.down;
}

/// GB addresses FULL LOADOUT writes (`scenario.Row.loadout`).
const gb_items: u16 = 0xD045;
const gb_tanks: u16 = 0xD050;
const gb_missiles: u16 = 0xD053;
const gb_max_missiles: u16 = 0xD081;

/// What the menu's FULL LOADOUT leaves, written into our Game Boy: every
/// item bit its pickups set, the tank ceiling and full energy, and the missile
/// ceiling, all from the pickup routines (`scenario.pickups`). The reference
/// may be set up directly; the cart goes through its menu.
fn giveLoadout(m: *harness.Machine, rom: []const u8) !void {
    const p = try scenario.pickups(rom);
    var bits: u8 = m.read(gb_items);
    for (p.bits) |b| bits |= b;
    m.write(gb_items, bits);
    m.write(gb_tanks, p.tank_ceiling);
    m.write(gb_health, p.full_low);
    m.write(gb_health + 1, p.tank_ceiling);
    for ([_]u16{ gb_missiles, gb_max_missiles }) |at| {
        m.write(at, @truncate(p.missile_ceiling));
        m.write(at + 1, @truncate(p.missile_ceiling >> 8));
    }
}

/// `runGb` with the pad held to `script` from the first sampled frame.
/// And the screen on each of `screens`, sampled frames.
pub fn runGbScripted(a: std.mem.Allocator, rom: []const u8, count: usize, script: []const Hold, screens: []const u16, loadout: bool) !GbFight {
    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    _ = try m.runFrames(300, .{}); // the appearance, as `queen.measure`
    if (loadout) try giveLoadout(&m, rom);
    const ppu = try a.create(ppu_mod.Ppu);
    defer a.destroy(ppu);
    ppu.* = .{};
    m.sys.bus.video = ppu.video();
    var shots: std.ArrayList(Screen) = .empty;
    var dw: DivWatch = .{ .m = &m };
    m.sys.bus.read_watch = .{ .ctx = &dw, .read = DivWatch.read };
    defer m.sys.bus.read_watch = null;
    try queen.enter(&m);
    _ = try m.runFrames(1, .{});

    const out = try a.alloc(Sample, count);
    var death: ?usize = null;
    var counter: u8 = 0;
    var lag: std.ArrayList(u16) = .empty;
    var last_fc: u8 = 0;
    for (out, 0..) |*s, f| {
        _ = try m.runFrames(1, holdAt(script, f).buttons());
        if (f == 0) counter = m.read(gb_frame_counter);
        const fc = m.read(gb_frame_counter);
        if (f > 0 and fc == last_fc) try lag.append(a, @intCast(f));
        last_fc = fc;
        for (vars, 0..) |v, i| s[i] = m.read(v.gb);
        if (death == null and m.read(gb_death) != 0) death = f;
        for (screens) |want| if (want == f) {
            if (!ppu.complete()) return Error.ScreenPartial;
            var bgp: [ppu_mod.height]u8 = undefined;
            for (&bgp, ppu.lines) |*b, l| b.* = l.bgp;
            try shots.append(a, .{ .frame = want, .shades = try a.dupe(u8, &ppu.frame), .bgp = try a.dupe(u8, &bgp) });
        };
    }
    if (dw.over) return Error.TooManyDivs;
    var cells: [death_cells.len]u8 = undefined;
    for (&cells, death_cells) |*b, c| b.* = m.read(0x9800 + c);
    return .{ .cells = cells, .samples = out, .death = death orelse count, .counter = counter, .divs = try a.dupe(u8, dw.vals[0..dw.n]), .screens = try shots.toOwnedSlice(a), .lag = try lag.toOwnedSlice(a) };
}

/// `case` on our Game Boy as `runGbCase` steps it, reading `addrs` on each of
/// `count` sampled frames: for writing a case's script (`queen -- probe`).
pub fn traceGb(a: std.mem.Allocator, rom: []const u8, case: Case, count: usize, addrs: []const u16) ![][]u8 {
    const script = if (case.off_lag) (try runGbCase(a, rom, case)).script else case.script;
    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    _ = try m.runFrames(300, .{});
    if (case.loadout) try giveLoadout(&m, rom);
    try queen.enter(&m);
    _ = try m.runFrames(1, .{});
    const out = try a.alloc([]u8, count);
    for (out, 0..) |*row, f| {
        _ = try m.runFrames(1, holdAt(script, f).buttons());
        row.* = try a.alloc(u8, addrs.len);
        for (row.*, addrs) |*b, at| b.* = m.read(at);
    }
    return out;
}

/// The sampled frame our Game Boy drew that the cart's vblank `n`, counted
/// from its first sampled frame, ends: `n` plus this.
pub const screen_lead: i32 = 1;

/// How many vblanks ahead of the cart's the pad it is handed belongs to: the
/// cart polls in the NMI before the pass that reads it.
pub const pad_lead: usize = 1;

/// Frames the Game Boy runs past the cart's last, so a history the cart
/// reaches early is still checked.
pub const slack: usize = 8;
/// Frames before Samus's death the window ends.
pub const before_death: usize = 2;
/// How long the Game Boy is run to find the death: past the measured 614.
pub const search_frames: usize = 1000;

/// One entry of a byte's collapsed history: its value, and the frame it began.
pub const Entry = struct { value: u8, from: u16 };

/// One byte's collapsed history over `samples[0..n]`.
pub fn history(a: std.mem.Allocator, samples: []const Sample, n: usize, v: usize) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(a);
    for (samples[0..n], 0..) |s, f| {
        if (out.items.len == 0 or out.items[out.items.len - 1].value != s[v]) try out.append(a, .{ .value = s[v], .from = @intCast(f) });
    }
    return out.toOwnedSlice(a);
}

/// Her death's lengths may differ by this much, a percentage: the rule for a
/// stretch graded by duration (`01-requirements.md` F10).
pub const death_tolerance_pct: u8 = 2;

/// `queen_state`'s index in `vars`.
pub fn stateVar() usize {
    return for (vars, 0..) |v, i| {
        if (v.gb == 0xC3C3) break i;
    } else unreachable;
}

/// The first sampled frames `queen_state` is $11 and $16 on, if both are.
pub fn deathSpan(samples: []const Sample, k: usize) ?[2]usize {
    var from: ?usize = null;
    for (samples, 0..) |s, f| {
        if (from == null and s[k] == 0x11) from = f;
        if (from != null and s[k] == 0x16) return .{ from.?, f };
    }
    return null;
}

/// Her death's length on our Game Boy, state $11 to $16, or 0.
pub fn deathLen(gb: GbFight) usize {
    const d = deathSpan(gb.samples, stateVar()) orelse return 0;
    return d[1] - d[0];
}

/// The cart's script: the warp, then `frames` frames each held against the
/// Game Boy's histories. Exit codes: 0 every history agreed; 48 some did
/// not, each named with the frame it parted at; the prelude's own below 48.
pub fn writeLua(a: std.mem.Allocator, rom: []const u8, sorted: []const warp.Entry, gb: GbFight, case: Case, w: *std.Io.Writer) !void {
    const script = gb.script;
    if (gb.death < before_death + slack) return Error.NeverDied;
    const frames = windowOf(case, gb);
    const i = for (sorted, 0..) |e, i| {
        if (e.dest.kind == .queen) break i;
    } else return Error.NoQueenEntry;

    try w.print(
        \\-- Generated by `zig build queen -- oracle`. Do not edit.
        \\--
        \\-- The Queen oracle, 1.0 Step 19a (`src/queen_oracle.zig`): the debug
        \\-- cart warped to her room, and every graded byte's collapsed history
        \\-- held to our Game Boy's over {d} frames. Our Game Boy's frameCounter
        \\-- on its first frame: {d}. rDIV reads it made: {d}.
        \\--
        \\-- Exit codes: 0 every history agreed; 1 Fatal; 2 no play, or out of
        \\-- frames; 3 A did not warp; 4 an unrunnable pose; 48 a history parted
        \\-- from the Game Boy's, each printed with the frame it parted at; 49
        \\-- the play window differed on a frame the case compares; 50 her BGP
        \\-- bands did; 51 the values our Game Boy's lagging vblank never built
        \\-- were not the case's pin; 52 her death's length was not our Game
        \\-- Boy's, within the tolerance; 53 a map cell her death writes was not.
        \\
    , .{ frames, gb.counter, gb.divs.len });
    try warp_grade.writeMenuPrelude(rom, sorted, @max(6000, frames + 3000), w);
    try w.print("local QUEEN_ROW, N = {d}, {d}\nV = {{\n", .{ debug_tables.warpRow(sorted, i)[1], frames });
    for (vars, 0..) |v, k| {
        const base = warp_grade.sym(v.cart.sym) catch {
            std.log.err("queen oracle: {s} is not in the engine image", .{v.cart.sym});
            return Error.NoSymbol;
        };
        const full = try history(a, gb.samples, frames + slack, k);
        const upto = try history(a, gb.samples, frames, k);
        try w.print("  {{ {d}, \"{s}\", \"", .{ base + v.cart.ofs, v.name });
        for (full) |e| try w.print("{X:0>2}", .{e.value});
        try w.print("\", {d}, \"", .{upto.len});
        for (full) |e| try w.print("{X:0>4}", .{e.from});
        try w.print("\", {}, {} }},\n", .{ vblankBuilt(v.gb), v.lead });
    }
    // The `rDIV` toss, handed across: each read our Game Boy made, written into
    // `!DivClock`'s high byte as the port's read is about to run, in order.
    const site = inject.symbol(div_cart) orelse {
        std.log.err("queen oracle: {s} is not in the engine image", .{div_cart});
        return Error.NoSymbol;
    };
    const woke = inject.symbol("MainLoop_woke") orelse return Error.NoSymbol;
    try w.print("}}\nlocal FRAMES, GBFC = 0x{X:0>4}, {d}\nLOADOUT = {}\nLAG = {{", .{ try warp_grade.sym("VarFrameCount") & 0xFFFF, gb.counter, case.loadout });
    for (gb.lag) |f| if (f < frames) try w.print(" [{d}] = true,", .{f});
    try w.print(" }}\nUNBUILT, UNBUILT_PIN = 0, {d}\n", .{case.unbuilt});
    // Her death's length (1.0 Step 20c): state $11 to $16 on each machine,
    // within `death_tolerance_pct`.
    if (case.death) {
        const k = stateVar();
        const d = deathSpan(gb.samples[0..frames], k) orelse return Error.NeverDied;
        try w.print("DEATH = {{ {d}, {d}, {d}, {d} }}\nCELLS, BG3MAP = {{", .{ k + 1, d[0], d[1], death_tolerance_pct });
        for (death_cells, gb.cells) |c, v| try w.print(" {{ {d}, {d} }},", .{ c, v });
        try w.print(" }}, 0x{X:0>4}\n", .{target.bg3_map_base});
    } else try w.print("DEATH = nil\n", .{});
    // The pad, from the frame each hold begins on (1.0 Step 19c).
    try w.print("local PADLEAD = {d}\nlocal HOLDS = {{\n", .{pad_lead});
    for (script) |h| {
        try w.print("  {{ {d}, ", .{h.from});
        try writeHoldLua(h, w);
        try w.print(" }},\n", .{});
    }
    try w.print("}}\nlocal SCREENLEAD, VIEW_W, VIEW_H, WIN_LEFT, BAND_TOP = {d}, {d}, {d}, {d}, {d}\nlocal SCREENS = {{\n", .{ screen_lead, target.view_w, target.view_h, (target.screen_w - target.view_w) / 2, (target.screen_h - target.view_h) / 2 });
    for (gb.screens) |sc| {
        if (std.mem.indexOfScalar(u16, case.screens, sc.frame) == null) continue;
        try w.print("  [{d}] = \"", .{sc.frame});
        for (sc.shades) |sh| try w.print("{d}", .{sh});
        try w.print("\",\n", .{});
    }
    try w.print("}}\nlocal QFRONT, QDISP, QADD, QTMB = 0x{X:0>4}, 0x{X:0>5}, 0x{X:0>5}, {d}\nlocal BANDS = {{\n", .{
        try warp_grade.sym("VarQueenFront") & 0xFFFF, try warp_grade.sym("VarQueenDisp"), try warp_grade.sym("VarQueenAdd"), try warp_grade.sym("ConstQueenTmB") & 0xFFFF,
    });
    for (gb.screens) |sc| {
        if (std.mem.indexOfScalar(u16, case.bands, sc.frame) == null) continue;
        try w.print("  [{d}] = \"", .{sc.frame});
        for (sc.bgp) |b| {
            const want = bandFor(b) orelse return Error.UnknownBgp;
            try w.print("{X:0>2}{X:0>2}", .{ want[0], want[1] });
        }
        try w.print("\",\n", .{});
    }
    // The script runs on past the graded window to the last screen or band
    // asked for (1.0 Step 25: `still`'s GAME OVER screen, after the death).
    var last: u16 = 0;
    for ([_][]const u16{ case.screens, case.bands }) |list| for (list) |f| {
        last = @max(last, f);
    };
    try w.print("}}\nlocal LAST = {d}\n", .{last});
    try w.print("local WOKE = 0x{X:0>6}\nlocal DIVHIGH, DIVSITE, DIVS = 0x{X:0>4}, 0x{X:0>6}, {{", .{ woke, (try warp_grade.sym("VarDivClock") & 0xFFFF) + 1, site });
    for (gb.divs) |d| try w.print("{d},", .{d});
    try w.print(
        \\}}
        \\do
        \\  local d = 0
        \\  emu.addMemoryCallback(function()
        \\    d = d + 1
        \\    if DIVS[d] ~= nil then emu.write(DIVHIGH, DIVS[d], wram) end
        \\  end, emu.callbackType.exec, DIVSITE, DIVSITE, emu.cpuType.snes, emu.memType.snesMemory)
        \\end
        \\local function at(h, k) return tonumber(h:sub(2 * k - 1, 2 * k), 16) end
        \\-- The play window against our Game Boy's (1.0 Step 19c), as the
        \\-- `queen` scenario compares it: shades off the red channel, and
        \\-- every object's pixels left out, which the histories grade.
        \\local OVERSCAN = (239 - 224) // 2
        \\local function shade(px)
        \\  local r = (px >> 16) & 0xFF
        \\  if r > 200 then return 0 elseif r > 120 then return 1
        \\  elseif r > 40 then return 2 else return 3 end
        \\end
        \\local function objects()
        \\  local oam = emu.memType.snesSpriteRam
        \\  local mask = {{}}
        \\  for i = 0, 127 do
        \\    local x, y = emu.read(i * 4, oam), emu.read(i * 4 + 1, oam)
        \\    local ninth = (emu.read(512 + (i >> 2), oam) >> ((i & 3) * 2)) & 1
        \\    if ninth == 0 and y < 224 then
        \\      for dy = 0, 7 do
        \\        for dx = 0, 7 do
        \\          local wx, wy = x + dx - WIN_LEFT, y + dy - BAND_TOP
        \\          if wx >= 0 and wx < VIEW_W and wy >= 0 and wy < VIEW_H then mask[wy * VIEW_W + wx] = true end
        \\        end
        \\      end
        \\    end
        \\  end
        \\  return mask
        \\end
        \\-- HDMA's value on SNES line `line` of a one-register table at `base`.
        \\local function bandAt(base, line)
        \\  local a, l = base, 0
        \\  while true do
        \\    local n = emu.read(a, wram)
        \\    if n == 0 then return nil end
        \\    if line < l + n then return emu.read(a + 1, wram) end
        \\    l, a = l + n, a + 2
        \\  end
        \\end
        \\-- Her BGP bands (1.0 Step 19c), line by line off the tables NMI is
        \\-- showing: INIDISP's and COLDATA's against what our Game Boy's BGP
        \\-- on that line is on the SNES.
        \\local function bands(f, want)
        \\  local off = emu.read(QFRONT, wram) == 0 and 0 or QTMB
        \\  for y = 0, VIEW_H - 1 do
        \\    local d, c = bandAt(QDISP + off, BAND_TOP + y), bandAt(QADD + off, BAND_TOP + y)
        \\    local wd, wc = tonumber(want:sub(4 * y + 1, 4 * y + 2), 16), tonumber(want:sub(4 * y + 3, 4 * y + 4), 16)
        \\    if d ~= wd or c ~= wc then
        \\      if SCREENBAD == nil then SCREENBAD = {{ 50, string.format("frame %d line %d: INIDISP %s and COLDATA %s, where our Game Boy's BGP is %02x and %02x", f, y, tostring(d), tostring(c), wd, wc) }} end
        \\      return
        \\    end
        \\  end
        \\end
        \\local function screen(f, ref)
        \\  local buf, mask = emu.getScreenBuffer(), objects()
        \\  local bad, first, lines = 0, nil, {{}}
        \\  for y = 0, VIEW_H - 1 do
        \\    for x = 0, VIEW_W - 1 do
        \\      local k = y * VIEW_W + x
        \\      if not mask[k] then
        \\        local got = shade(buf[(BAND_TOP + OVERSCAN + y) * 256 + WIN_LEFT + x + 1])
        \\        local want = tonumber(ref:sub(k + 1, k + 1))
        \\        if got ~= want then
        \\          bad = bad + 1
        \\          lines[#lines + 1] = y
        \\          if first == nil then first = string.format("(%d,%d) %d, the Game Boy's %d", x, y, got, want) end
        \\        end
        \\      end
        \\    end
        \\  end
        \\  if bad > 0 then
        \\    if SCREENBAD == nil then SCREENBAD = {{ 49, string.format("frame %d: the play window, %d pixels differ on lines %d-%d, first at %s", f, bad, lines[1], lines[#lines], first) }} end
        \\  end
        \\end
        \\-- The frame the Game Boy's entry `k` began on.
        \\local function from(v, k) return tonumber(v[5]:sub(4 * k - 3, 4 * k), 16) end
        \\local function main()
        \\  if LOADOUT then loadout() end
        \\  warp(3, QUEEN_ROW)
        \\  local idx, bad, seen = {{}}, {{}}, {{}}
        \\  for k = 1, #V do idx[k] = 1 end
        \\  local fc = emu.read(R.frames, wram)
        \\  -- Each frame is read where the main loop wakes from NMI: past the
        \\  -- vblank's work, as our Game Boy's frame is read past its vblank
        \\  -- handler's, so a byte both write in one frame reads the same.
        \\  local f = 0
        \\  local function sample()
        \\    if f >= N then return end
        \\    -- `frameCounter`'s phase, handed across once: see `queen_oracle`.
        \\    if f == 0 then emu.write(FRAMES, GBFC, wram) end
        \\    if f == 0 then VB = 0 end
        \\    for k, v in ipairs(V) do
        \\      if not bad[k] then
        \\        local got, h, j = emu.read(v[1], wram), v[3], idx[k]
        \\        if got == at(h, j) then seen[k] = true end
        \\        if got ~= at(h, j) then
        \\          if 2 * j < #h and got == at(h, j + 1) then
        \\            idx[k] = j + 1
        \\          elseif v[6] and LAG[f] then
        \\            -- What its vblank built, on a frame our Game Boy lagged:
        \\            -- a value it never built is not one the cart owes it.
        \\            UNBUILT = UNBUILT + 1
        \\            print(string.format("frame %d: %s %02x, which our Game Boy's lagging vblank never built", f, v[2], got))
        \\          elseif v[7] and j == 1 and not seen[k] then
        \\            -- The sound engine's reply, two ticks behind (1.0 Step 20d):
        \\            -- until it first shows the Game Boy's first value, it shows
        \\            -- the room's before hers.
        \\          else
        \\            local nxt = 2 * j < #h and string.format("%02x from frame %d", at(h, j + 1), from(v, j + 1)) or "nothing"
        \\            bad[k] = {{ f, string.format("frame %d: %s %02x, the Game Boy's entry %d of %d %02x (from frame %d) then %s", f, v[2], got, j, v[4], at(h, j), from(v, j), nxt) }}
        \\          end
        \\        end
        \\      end
        \\    end
        \\    if DEATH ~= nil then
        \\      local st = emu.read(V[DEATH[1]][1], wram)
        \\      if C11 == nil and st == 0x11 then C11 = f end
        \\      if C11 ~= nil and C16 == nil and st == 0x16 then C16 = f end
        \\    end
        \\    f = f + 1
        \\  end
        \\  emu.addMemoryCallback(sample, emu.callbackType.exec, WOKE, WOKE, emu.cpuType.snes, emu.memType.snesMemory)
        \\  -- The pad, by vblank from the first sampled frame: our Game Boy is
        \\  -- stepped a vblank at a time, so a pass either machine overruns
        \\  -- costs it what it costs a player.
        \\  emu.addEventCallback(function()
        \\    if VB == nil then return end
        \\    local ref = SCREENS[VB + SCREENLEAD]
        \\    if ref ~= nil then screen(VB + SCREENLEAD, ref) end
        \\    local want = BANDS[VB + SCREENLEAD]
        \\    if want ~= nil then bands(VB + SCREENLEAD, want) end
        \\    VB = VB + 1
        \\    local p = {{}}
        \\    for _, h in ipairs(HOLDS) do if h[1] <= VB + PADLEAD then p = h[2] end end
        \\    PAD = p
        \\  end, emu.eventType.endFrame)
        \\  while f < N or (VB ~= nil and VB + SCREENLEAD <= LAST) do frame() end
        \\  for k, v in ipairs(V) do
        \\    if not bad[k] and idx[k] < v[4] - 1 then
        \\      local j = idx[k]
        \\      bad[k] = {{ from(v, j + 1), string.format("frame %d: %s stayed %02x, where the Game Boy's went on to %02x (entry %d of %d)", from(v, j + 1), v[2], at(v[3], j), at(v[3], j + 1), j + 1, v[4]) }}
        \\    end
        \\  end
        \\  local list = {{}}
        \\  for _, b in pairs(bad) do list[#list + 1] = b end
        \\  table.sort(list, function(x, y) return x[1] < y[1] end)
        \\  if #list > 0 then
        \\    for n = 1, math.min(#list, 40) do print(list[n][2]) end
        \\    fail(48, string.format("%d of %d histories parted from the Game Boy's (the cart's frame counter on frame 0: %d)", #list, #V, fc))
        \\  end
        \\  -- The screen's, after the histories: a history that parts is the
        \\  -- likelier cause of a picture that does.
        \\  if SCREENBAD ~= nil then fail(SCREENBAD[1], SCREENBAD[2]) end
        \\  -- Her death's length (1.0 Step 20c), state $11 to $16 on each.
        \\  if DEATH ~= nil then
        \\    local gbn = DEATH[3] - DEATH[2]
        \\    if C11 == nil or C16 == nil then fail(52, "her death never reached state $16 on the cart") end
        \\    local n = C16 - C11
        \\    print(string.format("her death, state $11 to $16: %d frames, our Game Boy's %d (%.2f%%)", n, gbn, 100 * n / gbn))
        \\    if math.abs(n - gbn) * 100 > DEATH[4] * gbn then fail(52, string.format("her death took %d frames, our Game Boy's %d: more than %d%% apart", n, gbn, DEATH[4])) end
        \\    -- And the cells it wrote, in BG3's map in VRAM.
        \\    for _, c in ipairs(CELLS) do
        \\      local got = emu.read((BG3MAP + c[1]) * 2, emu.memType.snesVideoRam)
        \\      if got ~= c[2] then fail(53, string.format("her map's cell %d (row %d) is %02x in VRAM, our Game Boy's %02x", c[1], c[1] // 32, got, c[2])) end
        \\    end
        \\  end
        \\  if UNBUILT ~= UNBUILT_PIN then fail(51, string.format("%d values our Game Boy's lagging vblank never built, where the case pins %d", UNBUILT, UNBUILT_PIN)) end
        \\  print(string.format("%d frames of her fight: %d histories, the Game Boy's; %d values its lagging vblank never built", N, #V, UNBUILT))
        \\  emu.stop(0)
        \\end
        \\
    , .{});
    try warp_grade.writeRunner(w);
}

/// The gate's faults (1.0 Step 19b): a routine of hers taken out (`rts` over
/// its first byte), each of which the fight must show parting from the Game
/// Boy's: exit 48, or `code`.
pub const Fault = struct { label: []const u8, what: []const u8, code: u8 = fault_code };
pub const faults = [_]Fault{
    // The plan's: one state function blanked. The lunge never starts, and
    // `queen_state` stays $02 where the Game Boy's goes on to $03.
    .{ .label = "QueenPrepExtend", .what = "the lunge's state" },
    // The spit never turns toward Samus.
    .{ .label = "QueenSeekAxis", .what = "the spit's chase" },
    // No neck pairs: her objects and the neck's actors stay off.
    .{ .label = "QueenDrawNeck", .what = "the neck's drawing" },
    // No feet, in NMI: `queen_footFrame` never steps.
    .{ .label = "QueenDrawFeet", .what = "the feet" },
};
/// Past her kill (1.0 Step 25): her room flag left set at GAME OVER, and her
/// bands and feet come back over the screen on 900, which is not our Game
/// Boy's (49).
pub const still_faults = [_]Fault{
    .{ .label = "GameOverQueenFlag", .what = "her room flag at GAME OVER", .code = 49 },
};
/// The volley's (1.0 Step 19c): no hurt, and `queen_health` never falls; no
/// flash on the screen, and the play window on frame 278 is not our Game
/// Boy's (49).
pub const volley_faults = [_]Fault{
    .{ .label = "QueenHeadCollision", .what = "her hurt" },
    .{ .label = "QueenSetBgp_flash", .what = "her flash on the screen", .code = 49 },
};
/// The mouth's (1.0 Step 20a): no bomb arm, and `queen_eatingState` never
/// leaves $03; state $0F blanked, and it stays $04; no stomach acid, and
/// Samus's health holds where the Game Boy's falls.
pub const mouth_faults = [_]Fault{
    .{ .label = "QueenBombArms", .what = "the bomb on her head" },
    .{ .label = "QueenSamusEaten", .what = "state $0F" },
    .{ .label = "ApplyDamageStomach", .what = "the stomach's acid" },
};
/// The stomach's (1.0 Step 20b): state $08 blanked, and `queen_state` stays
/// $08 where the Game Boy's goes on to $09.
pub const stomach_faults = [_]Fault{
    .{ .label = "QueenStomachBombedState", .what = "state $08" },
};
/// Her death's (1.0 Step 20c): a state of it blanked, and `queen_state`
/// stays where the Game Boy's goes on; no spans copied out, and her
/// characters on the screen are not our Game Boy's; no rows, and her body's
/// cells in VRAM are not.
pub const kill_faults = [_]Fault{
    .{ .label = "QueenPrepDeath", .what = "state $11" },
    .{ .label = "QueenDisintegrating", .what = "state $12" },
    .{ .label = "QueenDeleteBody", .what = "state $13" },
    .{ .label = "QueenChrSpans", .what = "her characters copied out", .code = 49 },
    .{ .label = "QueenNmiRow", .what = "her body's rows in VRAM", .code = 53 },
};
/// Out of her room (1.0 Step 20d). `EXIT_QUEEN` taken out leaves her room
/// flag $11 until the `WARP` makes it $01, where our Game Boy's is $00; the
/// quake's branch taken out ends the quake's song back to hers, where our
/// Game Boy's asks for the baby's.
pub const exit_faults = [_]Fault{
    .{ .label = "DoorExitQueen", .what = "EXIT_QUEEN" },
    .{ .label = "QuakeQueenSong", .what = "the quake's song in her room" },
    .{ .label = "QueenDoorFrame", .what = "her bands off for the door", .code = 49 },
};
/// `ESCAPE_QUEEN` taken out leaves Samus and the camera where she fell, where
/// our Game Boy's places them. Her bands left on for the door draw her head
/// and the status bar on 168, where our Game Boy's screen has neither.
pub const escape_faults = [_]Fault{
    .{ .label = "DoorEscapeQueen", .what = "ESCAPE_QUEEN" },
    .{ .label = "QueenDoorFrame", .what = "her bands off for the door", .code = 49 },
};
/// The mouth's kill's (1.0 Step 20c): the bomb that would kill her takes ten
/// and leaves `queen_eatingState` at $04; and state $0A finds her dead and
/// `queen_state` stays where the Game Boy's goes on to $11.
pub const mouth_kill_faults = [_]Fault{
    .{ .label = "QueenSamusEaten_kill", .what = "the mouth's kill" },
    .{ .label = "QueenKillFromStomach", .what = "the kill from her stomach" },
};
pub const fault_code: u8 = 48;

const testing = std.testing;
const testrom = @import("testrom");

test "every byte of her page is graded or a named pointer, and no cart byte twice" {
    var page: usize = 0;
    for (vars) |v| {
        if (v.gb >= gb_page and v.gb < gb_page + 0x100) page += 1;
        try testing.expect(!isPointer(v.gb));
    }
    try testing.expectEqual(@as(usize, 256), page + pointers.len);
    for (vars, 0..) |v, i| for (vars[i + 1 ..]) |u| {
        try testing.expect(!(std.mem.eql(u8, v.cart.sym, u.cart.sym) and v.cart.ofs == u.cart.ofs));
    };
}

test "a history collapses its runs and keeps when each began" {
    const a: Sample = @splat(0);
    var b: Sample = @splat(0);
    b[3] = 7;
    const h = try history(testing.allocator, &.{ a, a, b, b, a }, 5, 3);
    defer testing.allocator.free(h);
    try testing.expectEqual(@as(usize, 3), h.len);
    try testing.expectEqual(Entry{ .value = 7, .from = 2 }, h[1]);
    try testing.expectEqual(Entry{ .value = 0, .from = 4 }, h[2]);
    // Over the first two samples only, one entry.
    const short = try history(testing.allocator, &.{ a, a, b, b, a }, 2, 3);
    defer testing.allocator.free(short);
    try testing.expectEqual(@as(usize, 1), short.len);
}

// The numbers `docs/phase1.md` (Step 19a) quotes: with no input she starts in
// `queenState_startA`, tosses `rDIV` once, and kills Samus on frame 614.
test "our Game Boy's fight: her first state, one rDIV read, Samus dead on frame 614" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gb = try runGb(arena.allocator(), rom, search_frames);
    const state = for (vars, 0..) |v, i| {
        if (v.gb == 0xC3C3) break i;
    } else unreachable;
    try testing.expectEqual(@as(u8, 0x17), gb.samples[0][state]);
    try testing.expectEqual(@as(usize, 1), gb.divs.len);
    try testing.expectEqual(@as(usize, 614), gb.death);
}

// The numbers `docs/phase1.md` (Step 20a) quotes: with FULL LOADOUT, the
// `mouth` script stuns her on 332, Samus is eaten on 354, in the shut mouth
// on 410, thrown out on 517, and lives through the window.
test "our Game Boy's mouth: stunned 332, eaten 354, in 410, out 517" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const case = for (cases) |c| {
        if (std.mem.eql(u8, c.name, "mouth")) break c;
    } else unreachable;
    const gb = try runGbCase(arena.allocator(), rom, case);
    const at = struct {
        fn first(samples: []const Sample, gbv: u16, value: u8) ?usize {
            const k = for (vars, 0..) |v, i| {
                if (v.gb == gbv) break i;
            } else unreachable;
            for (samples, 0..) |s, f| if (s[k] == value) return f;
            return null;
        }
    }.first;
    try testing.expectEqual(@as(?usize, 332), at(gb.samples, 0xD090, 0x10));
    try testing.expectEqual(@as(?usize, 354), at(gb.samples, gb_pose, 0x18));
    try testing.expectEqual(@as(?usize, 410), at(gb.samples, gb_pose, 0x19));
    try testing.expectEqual(@as(?usize, 517), at(gb.samples, gb_pose, 0x1D));
    try testing.expect(windowOf(case, gb) == 700);
}
