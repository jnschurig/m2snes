//! What the engine does at run time, modelled in Zig: how a screen body becomes
//! the tilemap the PPU reads, where the camera is allowed to go, and which
//! screen the finished cart boots on.
//!
//! The reason these are written out here as well as in `engine/main.asm` is not
//! documentation. `snes_render.zig` draws *through* `buildTilemap`, so the
//! 904-screen comparison against the Game Boy reference frames is a test of the
//! expansion the engine actually performs rather than of a second one that
//! merely resembles it. The camera limits are read back out of the assembled
//! image by a test in `snes_inject.zig` for the same reason: a constant that
//! exists in two places is a constant that can drift.
//!
//! ## The camera
//!
//! Ported from `handleCamera` (`bank_000.asm`, `00:08FE`) and `prepMapUpdate`
//! (`00:0698`) in M2RoS, which is MIT licensed and readable as a reference.
//!
//! The thing worth stating, because Step 12 got it wrong: the clamps are not
//! the limits of camera travel. Every position in the original is a
//! `(screen, pixel)` byte pair, so moving off the edge of a screen is the pixel
//! byte wrapping and the screen nibble taking the carry - no clamp, no event,
//! nothing decides that a crossing has happened. The `SCRN/2` clamps apply only
//! on an edge the scroll byte *blocks*, and there they are the door trigger.
//!
//! What makes that work is that the tilemap is a mod-256 window on the world
//! rather than a picture of one screen: `prepMapUpdate` writes one metatile row
//! or column per frame, chosen round-robin on `frameCounter & 3`, ahead of
//! wherever the camera is going. The Game Boy's tilemap and the SNES's BG3 map
//! are both 32x32 tiles of a 256-pixel square, so this ports across unchanged.

const std = @import("std");
const target = @import("snes_target.zig");
const convert = @import("snes_convert.zig");
const map = @import("map.zig");
const screens = @import("screens.zig");
const warp = @import("warp.zig");
const save = @import("save.zig");
const offsets = @import("offsets.zig");

// ---- Screen body to tilemap ------------------------------------------------

pub const tilemap_words = target.tilemap_words;
pub const Tilemap = [tilemap_words]u16;

/// A deliberate error in the expansion, so `snes_render`'s fault sweep can
/// prove the whole-game comparison is capable of failing. Reading a metatile's
/// quadrants in the wrong order and indexing the screen body transposed are
/// both mistakes a real port makes, and both live in this function now that the
/// renderer draws through it.
pub const BuildFault = enum { none, quadrants, transpose };

pub const BuildStats = struct {
    /// Metatile indexes that address past the end of the table region.
    out_of_range: usize = 0,
};

/// Expand one 16x16 screen body into the 32x32 tilemap BG3 draws from.
///
/// Each metatile is four consecutive tilemap words in TL TR BL BR order - the
/// order the Game Boy stores its four tile ids in - so the expansion is a
/// doubling in both axes with no arithmetic on the words themselves. That is
/// the whole reason `snes_convert.convertMetatiles` bakes the palette and
/// priority bits at conversion time: the engine's inner loop is a copy.
pub fn buildTilemap(
    out: *Tilemap,
    body: []const u8,
    metatiles: []const u8,
    fault: BuildFault,
) BuildStats {
    var stats: BuildStats = .{};
    @memset(out, 0);
    for (0..map.grid_h) |row| {
        for (0..map.grid_w) |col| {
            const index = if (fault == .transpose)
                body[col * map.grid_w + row]
            else
                body[row * map.grid_w + col];
            const at = @as(usize, index) * convert.metatile_bytes;
            if (at + convert.metatile_bytes > metatiles.len) {
                stats.out_of_range += 1;
                continue;
            }
            for (0..2) |qy| {
                for (0..2) |qx| {
                    const quadrant = if (fault == .quadrants) qx * 2 + qy else qy * 2 + qx;
                    const word = @as(u16, metatiles[at + quadrant * 2]) |
                        (@as(u16, metatiles[at + quadrant * 2 + 1]) << 8);
                    out[(row * 2 + qy) * target.tilemap_w + col * 2 + qx] = word;
                }
            }
        }
    }
    return stats;
}

// ---- The camera ------------------------------------------------------------

/// One screen is 256 pixels square, which is what makes a pixel fit in a byte.
pub const screen_span: u16 = 256;

/// Re-exported so a consumer that only wants the play window's shape does not
/// have to import `snes_target.zig` for two numbers.
pub const target_view_w: usize = target.view_w;
pub const target_view_h: usize = target.view_h;

pub const Dir = enum { left, right, up, down };

/// One axis of a world position: which screen of the 16x16 grid, and the pixel
/// within it.
///
/// The original stores every position this way - `hCameraXScreen` next to
/// `hCameraXPixel` - and that is the whole reason a screen crossing is not an
/// event. The pixel byte wraps, the screen nibble takes the carry, and the
/// camera has moved into the neighbour without anything having decided to.
/// Step 12 modelled the camera as a single clamped coordinate per axis and so
/// had to invent a crossing, which is what made a boundary leap a viewport.
pub const Axis = struct {
    /// Grid column or row, 0..15. The original masks with `$0f` after every
    /// carry, so the grid wraps rather than running off its edge.
    screen: u8,
    pixel: u8,

    pub fn add(self: Axis, delta: u8) Axis {
        const sum = @as(u16, self.pixel) + delta;
        const carry: u8 = @intCast(sum >> 8);
        return .{ .screen = (self.screen +% carry) & 0x0F, .pixel = @truncate(sum) };
    }

    pub fn sub(self: Axis, delta: u8) Axis {
        const borrow: u8 = @intFromBool(self.pixel < delta);
        return .{ .screen = (self.screen -% borrow) & 0x0F, .pixel = self.pixel -% delta };
    }
};

pub const Camera = struct {
    x: Axis,
    y: Axis,

    /// The cell index the camera centre is standing in, `(y,x)` packed as the
    /// map grid indexes it.
    pub fn cell(self: Camera) u8 {
        return (self.y.screen << 4) | self.x.screen;
    }
};

/// The clamps, from `handleCamera` (`bank_000.asm`, `00:08FE`).
///
/// These are **not** the limits of camera travel. They apply only on an edge
/// the screen's scroll byte *blocks*; an open edge has no limit at all, because
/// the camera just carries into the next screen. In the original a blocked edge
/// is where a door transition starts, so reaching the clamp is the trigger, not
/// a wall - Step 15 ports the doors, and until then stopping there is the
/// stand-in.
pub const clamp_left: u8 = @intCast(target.view_w / 2);
pub const clamp_right: u8 = @intCast(screen_span - target.view_w / 2);
pub const clamp_up: u8 = @intCast(target.view_h / 2);
/// Down carries the original's `+ $08`: the bottom 8 lines of the Game Boy's
/// window are the HUD band, so the camera is allowed 8 pixels further down than
/// the symmetric value. `handleCamera` writes it as `$100 - SCRN_Y/2 + $08`.
/// (The queen's room subtracts a further `$20`; that is a boss-room special
/// case and is not ported here.)
pub const clamp_down: u8 = @intCast(screen_span - target.view_h / 2 + target.hud_h);

/// Kept under their Step 12 names because the engine's `CameraLimits` table and
/// the tests that read it back speak in these terms.
pub const min_x: u16 = clamp_left;
pub const max_x: u16 = clamp_right;
pub const min_y: u16 = clamp_up;
pub const max_y: u16 = clamp_down;

/// Phase 0a has no Samus to follow, so the camera starts in the middle of the
/// screen.
pub const start_x: u16 = screen_span / 2;
pub const start_y: u16 = screen_span / 2;
/// Pixels per frame under the d-pad. `prepMapUpdate` services one direction per
/// frame, so a 16-pixel metatile column has four frames to arrive and the
/// camera must not outrun it: 4 is the ceiling, and Phase 0a uses 2.
pub const cam_step: u16 = 2;

comptime {
    if (cam_step * 4 > 16) @compileError("camera outruns the one-direction-per-frame stream");
}

/// Where the engine keeps the variables the Mesen2 gate reads back, mirrored
/// from `engine/main.asm`'s low-RAM block.
///
/// These are asar *defines*, not labels, so they do not reach `engine.sym` and
/// nothing can look them up. Gathering them here at least gives them one home
/// instead of scattering literals through the generated lua. Step 14 replaces
/// this with an address correspondence map generated from the symbol file, and
/// that is the point at which the drift stops being possible rather than merely
/// centralised.
pub const ram = struct {
    pub const frame_count: u16 = 0x00;
    pub const map_index: u16 = 0x02;
    pub const cell: u16 = 0x03;
    pub const cam_x: u16 = 0x08;
    pub const cam_y: u16 = 0x0A;
    pub const input_pressed: u16 = 0x0C;
    pub const input_rising_edge: u16 = 0x48;
    pub const samus_x: u16 = 0x4C;
    pub const samus_y: u16 = 0x4E;
    pub const pose: u16 = 0x54;
    /// The jump's frame counter. Below `physics.jump_array_base_offset` the
    /// ascent is linear and the arc is not read; at and above it the arc
    /// supplies one speed a frame. The gate watches it cross so it can tell the
    /// two halves of a jump apart.
    pub const jump_arc: u16 = 0x57;
    /// The first pose the engine was handed and could not run. The gate asserts
    /// it stays zero, so a pose the port has not reached yet fails the build
    /// instead of quietly doing nothing.
    pub const unhandled: u16 = 0x5D;
    /// Set by `MainLoop`'s first frame when `!FrameCount` is not the boot
    /// record's seed plus exactly one. The gate asserts it stays zero; see
    /// `docs/bug_tracker.md`'s 2026-09-09 entry for what a nonzero value means
    /// and why nothing outside the engine can measure it.
    pub const frame_phase: u16 = 0x0158;
    /// `!Items`, the six equipment bits. Zero until a pickup runs, which is
    /// what made two of the engine's masks wrong for two phases without any
    /// rung being able to see it.
    pub const items: u16 = 0x5B;
    /// B6's, from Step 11. `item_collected` is the trigger a sprite sets and
    /// `item_stage` is how far the inside-out `handleItemPickup` has got.
    pub const item_collected: u16 = 0x015E;
    pub const item_stage: u16 = 0x0159;
    /// `itemCollectionFlag`: $FF while a collection runs, $03 when the pickup
    /// has finished and the item may delete itself, $00 once it has.
    pub const item_flag: u16 = 0x0160;
    /// `$D033`, the speed of the last downward move that landed. Two pixels a
    /// frame or more bounces the ball into `ball_jump` without the Bomb, which
    /// is why the gate clears it while it is testing the Bomb's own branch.
    pub const down_speed: u16 = 0xBC;
    /// Which way she faces: 1 right, 0 left, the original's own encoding.
    pub const facing: u16 = 0x55;
    /// `hSpriteId`: which of the metasprite set is being drawn this frame.
    pub const sprite_id: u16 = 0x92;
    /// `hSpriteXPixel` / `hSpriteYPixel`: the sprite's anchor, still in Game
    /// Boy OAM coordinates. The SNES ones only exist in the shadow.
    pub const sprite_x: u16 = 0x95;
    pub const sprite_y: u16 = 0x97;
    /// `hOamBufferIndex`: bytes of OAM the frame's drawing used.
    pub const oam_index: u16 = 0x99;
    /// `countdownTimerLow`/`High`, $D066. How long the pose the cart booted in
    /// waits. The cold-boot rung watches it fall one a frame, which is the only
    /// way to tell the appearance sequence running from the cart being stuck in
    /// a pose that does nothing.
    pub const countdown: u16 = 0xDE;
    /// The door script a transition is owed, the original's $D08E/$D08F. Two
    /// bytes, and nonzero is the whole flag: `RunPendingTransition` runs the
    /// script and clears it. The gate writes it to make the cart execute a
    /// door on demand, which is the SNES half of what `room.spawn` does to the
    /// Game Boy by calling `warp_handler` directly.
    pub const door_index: u16 = 0xC1;
    /// `$D00E`: which way a transition is going, 1 right, 2 left, 4 up, 8 down.
    /// The gate writes it beside the door index so the crossing runs the arm of
    /// `WarpDraw` that draws the incoming edge -- without it the interpreter
    /// falls through 00:$2938 and draws nothing, which is what phase 8 did
    /// until Step 6 and why the draws went unchecked.
    pub const trans_dir: u16 = 0xC0;
    /// The 32x32 tilemap the engine's collision reads, one SNES word per slot
    /// with the Game Boy tile id in the low byte. Not a variable; the gate
    /// reads it to grade what the crossing drew.
    pub const tilemap_buf: u16 = 0x0800;
    /// B5's terrain half, from Step 12a. `!SolidBeam` is `beamSolidityIndex`,
    /// the threshold a block's tile id is classified against -- **not** the one
    /// Samus walks on, which is at $5E.
    pub const solid_beam: u16 = 0xFC;
    /// `!Blocks`, sixteen $10-byte slots. Byte 0 is the counter and zero means
    /// the slot is free; bytes 1 and 2 are the block's Y and X. The gate writes
    /// a slot directly, which is the byte `destroyRespawningBlock` writes, and
    /// grades everything downstream of it -- the same lever `item_collected` is.
    pub const blocks: u16 = 0x0500;
    pub const block_size: u16 = 0x10;
    /// `!BlkCrush`: the reform found Samus inside the block it was restoring.
    /// The gate asserts it stays zero, because 01:$5790 is recorded rather than
    /// ported and a nonzero value means the slice has grown into it.
    pub const blk_crush: u16 = 0x017C;
    /// B5's projectile half, from Step 12b. Three $10-byte slots; byte 0 is the
    /// weapon type and $FF is an empty slot, then direction, Y and X.
    ///
    /// **The gate does not write these.** Unlike `blocks` and `item_collected`,
    /// which are levers because nothing on the cart could reach them, the lever
    /// here is the fire button -- so the array is read and never poked, and a
    /// phase that found a projectile in it before the button was pressed would
    /// be reporting a cart that shoots by itself.
    pub const projs: u16 = 0x0600;
    pub const proj_size: u16 = 0x10;
    pub const proj_count: u16 = 3;
    pub const proj_none: u8 = 0xFF;
    /// `numEnemies.total`, which `processEnemies` copies into its work counter
    /// at the top of every other frame. A slot written by hand is not enough to
    /// make the pass walk it: the count is what ends the pass, not the array.
    pub const en_total: u16 = 0x010A;
    /// `numEnemies.active`, which is what `drawEnemies` returns early on. The
    /// gate reads it to know whether Samus is the only thing in OAM this frame.
    pub const en_active: u16 = 0x010B;
    /// `!Slots` and the fields the projectile's hitbox test and the damage pass
    /// read. Named individually rather than as a stride because the gate fills
    /// one by hand and every omitted field would be a zero that means something.
    pub const slots: u16 = 0x0200;
    pub const slot_size: u16 = 0x20;
    pub const en_status: u16 = 0x00;
    pub const en_ypos: u16 = 0x01;
    pub const en_xpos: u16 = 0x02;
    pub const en_sprite: u16 = 0x03;
    pub const en_baseattr: u16 = 0x04;
    pub const en_attr: u16 = 0x05;
    pub const en_stun: u16 = 0x06;
    pub const en_dirflags: u16 = 0x08;
    /// `hEnemy.counter`. Step 12e's rung needs it because it is the explosion's
    /// whole clock: `enemy_animateExplosion` builds each frame's sprite id by
    /// adding this to a base, so a fixture that wanted to know which frame of an
    /// explosion is on the screen would otherwise have to invert the addition.
    pub const en_counter: u16 = 0x09;
    pub const en_ice: u16 = 0x0B;
    pub const en_health: u16 = 0x0C;
    pub const en_drop: u16 = 0x0D;
    pub const en_explode: u16 = 0x0E;
    pub const en_maxhp: u16 = 0x11;
    pub const en_flag: u16 = 0x1C;
    /// `!CollWeapon` and `!PrUnhandled`: what the hitbox test last recorded, and
    /// the first thing the projectile half was handed that it has no arm for.
    pub const coll_weapon: u16 = 0x012E;
    pub const coll_enemy: u16 = 0x012F;
    pub const pr_unhandled: u16 = 0x0195;
    /// `!EnFrame`, `hEnemy_frameCounter`. The gate reads it rather than writing
    /// it: it is what `.becomeDrop`'s substituted roll divides, so a phase that
    /// wanted a particular roll could poke this -- and does not, because a rung
    /// that writes the quantity it is grading against grades nothing. Step 12e's
    /// drop phase retries instead.
    pub const en_frame: u16 = 0x0127;
    /// `!EnSame`, `enemy_sameEnemyFrameFlag`. It reads 1 at the end of exactly
    /// the frames the enemy pass *acted* on, which is how a fixture can sample a
    /// per-pass quantity without guessing the cadence.
    pub const en_same: u16 = 0x0128;
    /// `!EN_NUMBER`, which byte of `!SpawnFlags` this slot publishes through.
    /// A slot written by hand needs it: `SlotFlagOut` indexes the 128-byte array
    /// with it unchecked, exactly as the original does, so the $FF a cleared
    /// slot carries would have it write past the array's end.
    pub const en_number: u16 = 0x1D;
    /// `!EnUnhandledState`: the slot offset of the first enemy state
    /// `EnemyCommonAI` was handed that this cart has no handler for. Step 12e
    /// closed two of its four arms, so a phase that kills a slot and finds this
    /// nonzero has found the explosion going back to being a recorded state.
    pub const en_unhandled_state: u16 = 0x0153;
    /// `samusCurHealth`, BCD and low byte first. The drop half of
    /// `enemy_getDamagedOrGiveDrop` has been ported since Step 12b and nothing
    /// could reach it until a corpse could leave a drop; this is what it moves.
    pub const health_lo: u16 = 0x0132;
    pub const health_hi: u16 = 0x0133;
};

/// The pose numbers, mirrored from `engine/main.asm` for the same reason `ram`
/// is: the gate has to name them and asar defines do not reach the symbol file.
/// These are the original's own values - `samus_pose` is the same variable.
pub const pose = struct {
    pub const stand: u8 = 0x00;
    pub const jump: u8 = 0x01;
    pub const spin_jump: u8 = 0x02;
    pub const run: u8 = 0x03;
    pub const crouch: u8 = 0x04;
    /// The morph ball, and the jump it can only start with the Bomb: 00:$1721
    /// tests `itemBit_bomb` before it will enter `ball_jump`, which is the
    /// branch Step 11's fixture is about.
    pub const morph: u8 = 0x05;
    pub const ball_jump: u8 = 0x06;
    /// The ball off the ground. `poseFunc_morphBall` writes it and returns
    /// without moving her, so a fixture that overwrites the pose every frame
    /// hangs her in mid-air -- which is what Step 11's first attempt did.
    pub const ball_fall: u8 = 0x08;
    pub const fall: u8 = 0x07;
    pub const njump_start: u8 = 0x09;
    pub const spin_start: u8 = 0x0A;
    /// Facing the camera: the appearance sequence a new game opens on, and the
    /// only pose in this list that no movement reaches.
    pub const face_screen: u8 = 0x13;
};

/// Where the camera holds Samus, in the window's own coordinates, mirrored from
/// `engine/main.asm` like `ram` and `pose`.
///
/// `CameraGuideX` returns `samus - camera + bias_x`, which is her centre in OAM
/// space: `bias_x` is `view_w/2 + oam_x_ofs + origin_x_to_center`. The two
/// targets are the original's `$38` from either edge - `oam_x_ofs + $38` going
/// right, `view_w + oam_x_ofs - $38` going left - so the camera keeps 56 pixels
/// behind her and 104 ahead, mirrored by which way she is walking. Turning
/// around is therefore 48 pixels of camera travel, which is the "extra space in
/// front" a person sees on a television.
pub const guide = struct {
    pub const bias_x: u8 = 0x60;
    /// `handleCamera` biases vertically by `view_h/2 + oam_y_ofs +
    /// origin_y_to_center - 2`, two less than `drawSamus_common` does on the
    /// same axis. The two pixels are the original's own divergence between
    /// where the camera aims and where the sprite is drawn, and the engine
    /// keeps them apart the same way: the guide carries the `- 2` and
    /// `SamusAnchor` adds it back.
    pub const bias_y: u8 = 0x60;
    pub const sprite_y_over_guide: u8 = 2;
    pub const right: u8 = 0x40;
    pub const left: u8 = 0x70;

    pub fn forDir(dir: Dir) u8 {
        return switch (dir) {
            .right => right,
            .left => left,
            .up, .down => unreachable,
        };
    }
};

/// The camera positions at which the whole 160x144 play window lies inside a
/// single 256x256 screen, so a render of that one screen can say what the
/// picture should be. `windowAt` returns `WindowStraddles` outside them.
pub const window_min_x: u16 = min_x;
pub const window_max_x: u16 = min_x + screen_span - target.view_w;
pub const window_min_y: u16 = min_y;
pub const window_max_y: u16 = min_y + screen_span - target.view_h;

/// The joypad bit each direction occupies in the 16-bit auto-read at $4218.
pub fn padBit(dir: Dir) u16 {
    return switch (dir) {
        .up => 0x0800,
        .down => 0x0400,
        .left => 0x0200,
        .right => 0x0100,
    };
}

/// Whether the screen's scroll byte permits leaving in `dir`.
///
/// A **set** bit blocks. `handleCamera` reads it as `bit 0, a / jr z, <move
/// freely>`, and `map.Scroll`'s header carries the two ROM measurements that
/// settle the sense independently.
pub fn permits(scroll: u8, dir: Dir) bool {
    const s: map.Scroll = @bitCast(scroll);
    return switch (dir) {
        .right => !s.block_right,
        .left => !s.block_left,
        .up => !s.block_up,
        .down => !s.block_down,
    };
}

fn clampFor(dir: Dir) u8 {
    return switch (dir) {
        .left => clamp_left,
        .right => clamp_right,
        .up => clamp_up,
        .down => clamp_down,
    };
}

fn towardMin(dir: Dir) bool {
    return dir == .left or dir == .up;
}

/// One frame of camera movement, ported from `handleCamera`.
///
/// The shape is the original's, including the part that reads oddly: on a
/// blocked edge the camera is *not* clamped before it moves, it is only stopped
/// once it is standing on the clamp, and pushed back one pixel a frame if a
/// multi-pixel step overshot. That settling is observable, so it is ported
/// rather than tidied into a saturating add.
pub fn step(cam: Camera, dir: Dir, speed: u8, scroll: u8) Camera {
    const axis = switch (dir) {
        .left, .right => cam.x,
        .up, .down => cam.y,
    };
    const next = stepAxis(axis, dir, speed, scroll);
    return switch (dir) {
        .left, .right => .{ .x = next, .y = cam.y },
        .up, .down => .{ .x = cam.x, .y = next },
    };
}

fn stepAxis(axis: Axis, dir: Dir, speed: u8, scroll: u8) Axis {
    const clamp = clampFor(dir);
    const toward_min = towardMin(dir);
    if (!permits(scroll, dir)) {
        if (axis.pixel == clamp) return axis; // the door trigger, in the original
        if (toward_min and axis.pixel < clamp) return axis.add(1); // settle back
        if (!toward_min and axis.pixel > clamp) return axis.sub(1);
    }
    if (speed == 0) return axis;
    return if (toward_min) axis.sub(speed) else axis.add(speed);
}

/// The neighbouring cell index, or null at the edge of the 16x16 grid.
pub fn neighbour(cell: u8, dir: Dir) ?u8 {
    const w: u8 = @intCast(map.grid_w);
    const h: u8 = @intCast(map.grid_h);
    const cx = cell % w;
    const cy = cell / w;
    return switch (dir) {
        .left => if (cx == 0) null else cell - 1,
        .right => if (cx == w - 1) null else cell + 1,
        .up => if (cy == 0) null else cell - w,
        .down => if (cy == h - 1) null else cell + w,
    };
}

// ---- Streaming the tilemap -------------------------------------------------

/// The tilemap is a plain mod-256 window on the world: the tile at `(tx,ty)`
/// always holds the world pixel `(tx*8, ty*8)` with the screen number thrown
/// away. `mapUpdate_getSrcAndDest` computes exactly this, as
/// `$9800 + (y & $F0)*4 + (x & $F0)/8`, and it is why the wrap needs no
/// bookkeeping: a position and its address are the same number.
pub fn destTile(x_pixel: u8, y_pixel: u8) usize {
    const row: usize = (y_pixel & 0xF0) >> 4;
    const col: usize = (x_pixel & 0xF0) >> 4;
    return row * 2 * target.tilemap_w + col * 2;
}

/// Which direction `prepMapUpdate` services this frame.
///
/// The original picks exactly one, round-robin on the low two bits of the frame
/// counter, so a given direction's row or column arrives at most every fourth
/// frame. That is what bounds the camera speed, and porting the cadence rather
/// than streaming all four keeps the arrival times a trace can compare.
pub fn serviced(frame: u8) Dir {
    return switch (frame & 3) {
        0 => .up,
        1 => .down,
        2 => .left,
        else => .right,
    };
}

/// The world position of the top-left corner of the metatile row or column that
/// `prepMapUpdate` fetches for `dir`.
///
/// Three of the four reach `$30` past the camera and the rightward one reaches
/// `$20`. The asymmetry is the original's, not a simplification: the row and
/// column are metatile-aligned by the `& $F0` in `destTile`, and the two
/// offsets land on the same side of that alignment.
pub fn sourceCorner(cam: Camera, dir: Dir) Camera {
    const back_x: u8 = clamp_left + 0x30;
    const back_y: u8 = clamp_up + 0x30;
    const ahead_x: u8 = clamp_left + 0x20;
    return switch (dir) {
        .up => .{ .x = cam.x.sub(back_x), .y = cam.y.sub(back_y) },
        .down => .{ .x = cam.x.sub(back_x), .y = cam.y.add(back_y) },
        .left => .{ .x = cam.x.sub(back_x), .y = cam.y.sub(back_y) },
        .right => .{ .x = cam.x.add(ahead_x), .y = cam.y.sub(back_y) },
    };
}

/// The screen bodies of one map, indexed by cell, and the metatile table they
/// share. A null body is a cell the map has no screen for.
pub const World = struct {
    bodies: []const ?[]const u8,
    metatiles: []const u8,
};

/// Write one metatile of the world into the wrapping tilemap.
pub fn streamOne(out: *Tilemap, world: World, at: Camera) void {
    const body = world.bodies[at.cell()] orelse return;
    const block = (at.y.pixel & 0xF0) | (at.x.pixel >> 4);
    const index = body[block];
    const src = @as(usize, index) * convert.metatile_bytes;
    if (src + convert.metatile_bytes > world.metatiles.len) return;
    const dest = destTile(at.x.pixel, at.y.pixel);
    for (0..2) |qy| {
        for (0..2) |qx| {
            const quadrant = qy * 2 + qx;
            const word = @as(u16, world.metatiles[src + quadrant * 2]) |
                (@as(u16, world.metatiles[src + quadrant * 2 + 1]) << 8);
            out[dest + qy * target.tilemap_w + qx] = word;
        }
    }
}

/// One frame of streaming: the 16 metatiles of the row or column due for `dir`,
/// walked from `sourceCorner` and carrying across a screen boundary in the
/// middle of the walk exactly as `.row` and `.column` do.
pub fn stream(out: *Tilemap, world: World, cam: Camera, dir: Dir) void {
    var at = sourceCorner(cam, dir);
    const along_x = dir == .up or dir == .down;
    for (0..map.grid_w) |_| {
        streamOne(out, world, at);
        at = if (along_x)
            .{ .x = at.x.add(16), .y = at.y }
        else
            .{ .x = at.x, .y = at.y.add(16) };
    }
}

/// The BG scroll register values that put the camera's view inside the play
/// window.
///
/// `BGnHOFS` names the world pixel drawn at screen column zero, so the world
/// pixel at the left of the play window has to be offset back by where the
/// window starts. `BGnVOFS` is the same with the hardware's one-line lead: the
/// PPU fetches the line *after* the one the register names.
pub const win_left: u16 = (target.screen_w - target.view_w) / 2;
pub const band_top: u16 = (target.screen_h - target.view_h) / 2;

pub fn scrollX(camera_x: u16) u16 {
    return (camera_x -% min_x -% win_left) & 0x3FF;
}

pub fn scrollY(camera_y: u16) u16 {
    return (camera_y -% min_y -% band_top -% 1) & 0x3FF;
}

// ---- Palette ---------------------------------------------------------------

/// A DMG shade as a 15-bit SNES colour. Four evenly spaced greys, lightest
/// first, which is the order `BGP` numbers them in.
pub fn grey(shade: u2) u16 {
    const level: u16 = switch (shade) {
        0 => 31,
        1 => 21,
        2 => 10,
        3 => 0,
    };
    return level | (level << 5) | (level << 10);
}

/// BG3's palette 0, as four CGRAM words.
///
/// Entry 0 is the backdrop as well as the play field's colour 0, and that is
/// not an accident of the SNES's transparency rule - it is what makes it come
/// out right. A Game Boy background pixel of index 0 is opaque and drawn with
/// `BGP`'s first field; a SNES background pixel of colour 0 shows the backdrop.
/// Writing the same colour into both means the two agree.
pub fn palette(bgp: u8) [4]u16 {
    var out: [4]u16 = undefined;
    for (0..4) |i| out[i] = grey(@intCast((bgp >> @intCast(i * 2)) & 3));
    return out;
}

// ---- Which screen the cart boots on ----------------------------------------

/// Which of the two kinds of start the record describes.
///
/// **The record is one slot and the cart reads it the same way either way**;
/// this byte says where its numbers came from, which is the difference the
/// requirement is about. A `handover` record is a measurement of the original
/// mid-run, made by `oracle.movieBoot` or invented by `chooseBoot` so a rung
/// has somewhere to stand. A `new_game` record is the game's own -- every
/// number in it is read out of `initial_save` or off the four instructions
/// that end `loadGame_samusData` -- and it is what the shipped cart boots on.
pub const Mode = enum(u8) {
    handover = 0,
    new_game = 1,
};

/// Everything the engine needs to put one converted screen on the television.
/// `initialSaveFile`'s length, `LD B,$26` in `createNewSave` (01:$4E1C).
pub const save_record_len: usize = 0x26;

pub const Boot = struct {
    /// Map bank `$9`-`$F` as an index 0-6, the same numbering a converted
    /// `WARP` operand uses.
    map_index: u8,
    /// Grid cell, `y * 16 + x`.
    cell: u8,
    /// Index into the converted door-pointer table of the script to replay.
    /// Replaying a real script is what fills VRAM, and it is the same script
    /// `screens.assign` paired with this screen - so the picture the cart draws
    /// is the picture `snes_render` produces for the same cell, and the
    /// 904-screen comparison covers it.
    door_index: u16,
    /// The metatile table that script left selected.
    tiletable: u4,
    palette: [4]u16,
    /// OBP0 then OBP1, as the engine writes them into the first two object
    /// palettes. `drawSamusSprite` moves every part to the second one while
    /// Samus is invulnerable or in acid.
    obj_palette: [8]u16,
    /// The `chr_obj` asset id of Samus's power-suit sheet. The injector fills
    /// this in - the converter assigns the id, and `chooseBoot` runs before
    /// conversion - so it is left at the sentinel here.
    samus_chr: u8 = no_samus_chr,
    /// Where Samus starts, as a whole world coordinate per axis: the screen
    /// number in the high byte, the pixel within it in the low one.
    ///
    /// `samusStart` computes the default, which is the middle of the boot cell
    /// -- the position the engine used to build for itself before boot record
    /// version 3. Set them to something else and the cart boots her there; that
    /// is the whole point of the field, and it is what lets Step 15 put this
    /// machine and the Game Boy on the same pixel at frame 0.
    samus_x: u16,
    samus_y: u16,
    /// Where the camera starts, in the same shape and independently of her.
    ///
    /// Boot record version 3 had no such field, because `InitState` put the
    /// camera on Samus. `src/residue.zig`'s audit measured that against the
    /// game and it is false: the original's camera is placed by the door
    /// transition that brought her into the room, so at a handover of control
    /// it is wherever that transition and the scrolling since left it. A caller
    /// that has measured the game's camera -- `oracle.movieBoot` has -- writes
    /// what it measured; a caller inventing a spawn writes her position, which
    /// is what version 3 did, so nothing about Phase 0a's picture changes.
    ///
    /// No default, deliberately. The silent default is the bug this field
    /// exists to fix, and a construction site that has not thought about the
    /// camera should not compile.
    cam_x: u16,
    cam_y: u16,
    /// What `InitState` seeds `!FrameCount` with, and so the phase of the
    /// counter the physics reads: `WalkSpeed` takes the walk's 1/2 alternation
    /// from bit 0, `PoseJumpStart` from bit 1, `PoseSpinJump` from both.
    ///
    /// Zero is the honest default here, unlike the camera above: a cart that
    /// boots on its own has no reference to be in step with, and zero is where
    /// its counter began before this field existed. A caller that has measured
    /// the game's $FF97 at a handover -- `oracle.movieBoot` has -- writes the
    /// seed that puts the two in step from frame 0, which is the measurement
    /// less `frame_count_lead`.
    frame_count: u16 = 0,
    /// The pose she starts in. `pose.fall` by default: dropped into the middle
    /// of a cell, there is no guarantee of ground under her.
    pose: u8 = pose.fall,
    /// Which way she is facing: `facing.right` or `facing.left`.
    ///
    /// Right by default, which is what `InitState` hardcoded before version 6
    /// and is the right answer for a spawn nobody transitioned into. A caller
    /// grading against the game -- `oracle.movieBoot` -- writes what it
    /// measured; see `engine/main.asm`'s `BootFacing` for what the hardcoded
    /// one cost.
    facing: u8 = facing.right,
    /// Where `!Countdown` starts, which is how long the pose the cart boots in
    /// waits before handing over control. Zero for every pose but $13, and
    /// zero is also what the original holds everywhere a graded stretch begins
    /// -- so the default is right for a handover and only a new game sets it.
    countdown: u16 = 0,
    /// Where the numbers above came from. See `Mode`; the default is the
    /// honest one, since a caller that has not thought about it is inventing a
    /// spawn rather than describing the game's own start.
    mode: Mode = .handover,
    /// What `InitState` seeds `!PadHeld` with, so the first `PublishPad` hands
    /// the pose machine the input the game was acting on at frame 0.
    ///
    /// Zero is the honest default, like `frame_count` and unlike the camera: a
    /// cart that boots itself has nothing held. A caller grading against a
    /// handover of control writes what it measured.
    input: u16 = 0,
    /// Tiles the record forces into `!TilemapBuf` after the room is drawn.
    ///
    /// **The world an anchor needs and the map cannot describe.** The
    /// original's collision is a lookup into its background tilemap, and
    /// `destroyBlock` (01:56E9) writes $FF over the four tiles of every block
    /// the reference shot out -- so a stretch anchored after a descent begins
    /// in a room whose floor the converted map still has, and every frame after
    /// that is graded against a floor that is not there.
    ///
    /// Empty is the honest default and the common case: a cart that boots
    /// itself has shot nothing, and so has every anchor in the recording's
    /// first ten thousand frames. See `engine/main.asm`'s `SeedWorld` and
    /// `oracle.blockSeeds`, which is what fills this in.
    ///
    /// Borrowed, not owned: the slice outlives the `Boot` at every site that
    /// sets it, and a `Boot` is copied by value all over this file.
    world: []const WorldSeed = &.{},
    /// Boot record version 17 (1.0 Step 18b): `initialSaveFile`, for a new
    /// game, which loads its tables, solidity and graphics from it as the Game
    /// Boy's does. Null for a handover, which replays `door_index` instead.
    save: ?[save_record_len]u8 = null,
    /// What she is carrying. Boot record version 11.
    ///
    /// Zero is *not* an honest default and is here only so a test can build a
    /// `Boot` without a ROM: every cart before version 11 booted with zero
    /// health and zero missiles, which is how a playtest pressed Select, fired,
    /// and got the dud. `bootFor` and `chooseBoot` fill in the new game's
    /// numbers from `save.initial`, and a caller grading against a handover
    /// overwrites the fields its reference measured.
    loadout: Loadout = .{},
};

/// The six numbers `loadGame_samusData` (00:$0CA3) loads that the port reads,
/// as the original stores them: BCD, and the three pairs low byte first.
pub const Loadout = struct {
    tanks: u8 = 0,
    health: u16 = 0,
    max_missiles: u16 = 0,
    missiles: u16 = 0,
    metroid_real: u8 = 0,
    metroid_displayed: u8 = 0,
    /// Version 12: the equipment bits ($D045), the beam parked while missiles
    /// are selected ($D055), and the selected weapon ($D04D).
    items: u8 = 0,
    beam: u8 = 0,
    active_weapon: u8 = 0,
    /// Version 13: the song the engine is playing, `songPlaying` ($CEDD). Zero
    /// for a new game, which asks for its own; a handover's is measured.
    song: u8 = 0,
    /// Version 14: `currentRoomSong` ($D092), the song the room asks for and
    /// the one a Metroid's death restores by adding $11. A save-file value, so
    /// a new game's is `initialSaveFile`'s and a handover's is measured.
    ///
    /// **Not `song`.** That is what to play once at a handover; this is what
    /// the game keeps asking for, and booting it wrong is silence rather than
    /// one wrong song (`docs/bug_tracker.md`, 2026-09-22).
    room_song: u8 = 0,
    /// Version 15: `acidDamageValue` and `spikeDamageValue` ($D077/$D078), what
    /// a door's `DAMAGE` sets and a save carries. **Until Step 22 no version
    /// carried them**, so a new game ran on the WRAM clear's zero: acid latched,
    /// flickered and asked for its sound, and took nothing off.
    acid_damage: u8 = 0,
    spike_damage: u8 = 0,

    /// The new game's, off `initialSaveFile` (01:$4E64). Null when the ROM's
    /// record is not pinned, which a caller turns into its own error rather
    /// than into a cart with nothing in its pockets.
    pub fn newGame(rom: []const u8) ?Loadout {
        const init = save.initial(rom) orelse return null;
        return .{
            .tanks = init.energy_tanks,
            .health = init.health,
            .max_missiles = init.max_missiles,
            .missiles = init.missiles,
            .metroid_real = init.metroid_count_real,
            .metroid_displayed = init.metroid_count_displayed,
            .items = init.items,
            .beam = init.beam,
            // 00:$0CC0: the one save byte loads into both.
            .active_weapon = init.beam,
            .room_song = init.room_song,
            .acid_damage = init.acid_damage,
            .spike_damage = init.spike_damage,
        };
    }

    /// What a reference measured at a handover, field by field. A null field
    /// is one the reference does not carry, and `over` leaves the base's value
    /// there: the recorded trace carries tanks, the missile ceiling and the
    /// real count and nothing else, so a stretch anchored on it boots with
    /// those three measured and the new game's numbers for the rest.
    pub const Measured = struct {
        tanks: ?u8 = null,
        health: ?u16 = null,
        max_missiles: ?u16 = null,
        missiles: ?u16 = null,
        metroid_real: ?u8 = null,
        metroid_displayed: ?u8 = null,
        items: ?u8 = null,
        beam: ?u8 = null,
        active_weapon: ?u8 = null,
        song: ?u8 = null,
        room_song: ?u8 = null,
        acid_damage: ?u8 = null,
        spike_damage: ?u8 = null,

        pub fn over(self: Measured, base: Loadout) Loadout {
            var out = base;
            inline for (@typeInfo(Measured).@"struct".fields) |f| {
                if (@field(self, f.name)) |v| @field(out, f.name) = v;
            }
            return out;
        }
    };
};

/// One tile the record forces into `!TilemapBuf` after the room is drawn: a
/// tilemap index in tiles, and the id to put there.
///
/// Declared here rather than in `snes_inject` because `Boot` carries it and
/// `snes_inject` imports this file; the injector re-exports it under the name
/// its own patch table uses.
pub const WorldSeed = struct {
    index: u16,
    tile: u8,
};

/// The original's own convention at `samusFacingDirection`.
pub const facing = struct {
    pub const right: u8 = 0x01;
    pub const left: u8 = 0x00;
};

/// The middle of a cell, as a world coordinate on each axis.
///
/// This is the arithmetic the engine's `InitState` did before version 3, moved
/// here so there is one source of truth for it: the cell's column nibble
/// becomes the high byte of x and its row nibble the high byte of y, each over
/// `start_x`/`start_y`. Seeding only the pixel half would put her in the middle
/// of cell $00 with the boot cell's picture drawn around her.
pub fn samusStart(cell: u8) Position {
    return samusAt(cell, @truncate(start_x), @truncate(start_y));
}

/// A whole world coordinate on each axis. Named `Position` rather than `World`
/// because this file already has a `World`, which is a map's screen bodies.
pub const Position = struct { x: u16, y: u16 };

/// A cell and a pixel within it, as a whole world coordinate on each axis.
///
/// **This is the same number the Game Boy uses.** `room.Placement.worldX` builds
/// it from the screen column and the pixel offset the `WARP` handler leaves in
/// $FFCB/$FFCA, and the original's own camera arithmetic at 00:$294F treats
/// that pair as a 16-bit value by adding $50 to it with `ADD`/`ADC`. So the two
/// machines can be asked for the same position in the same units, which is the
/// precondition Step 15's frame-for-frame comparator needs at frame 0 -- and
/// `room.zig`'s "the two room harnesses agree" test is where that is checked
/// rather than assumed.
///
/// A cell is `row * 16 + col`, so the column is the low nibble and the row the
/// high one.
pub fn samusAt(cell: u8, pixel_x: u8, pixel_y: u8) Position {
    return .{
        .x = (@as(u16, cell & 0x0F) << 8) | pixel_x,
        .y = (@as(u16, cell >> 4) << 8) | pixel_y,
    };
}

/// An id no asset can have, so an unfilled `samus_chr` is caught rather than
/// pointing at asset 0.
pub const no_samus_chr: u8 = 0xFF;

pub const Error = error{ NoBootScreen, OutOfMemory } || screens.Error;

/// Choose the screen the cart boots on: the first cell, in bank and then grid
/// order, whose tileset a door script *stated* rather than one we inferred.
///
/// Deterministic on purpose - the gate compares two builds byte for byte - and
/// restricted to `.door` provenance on purpose too. A screen reached by the
/// nearest-warp rule would still render, but the first thing the engine ever
/// draws should be a picture the ROM vouches for, not one of the inferences
/// Step 7 had to make.
/// Every cell `chooseBoot` would consider, in the same order, up to `limit`.
///
/// `chooseBoot` returns the first; the oracle needs a few, because the first
/// one on this ROM is a flat corridor with a ceiling and a segment that runs
/// there can never test a fall. Same provenance rule, same ordering, so the
/// first element is exactly what `chooseBoot` returns.
pub fn bootCandidates(allocator: std.mem.Allocator, rom: []const u8, limit: usize) Error![]Boot {
    var a = try screens.assign(allocator, rom);
    defer a.deinit(allocator);

    var out: std.ArrayList(Boot) = .empty;
    errdefer out.deinit(allocator);

    // Collect, then sort by the same key `chooseBoot` minimises.
    const Keyed = struct { key: usize, boot: Boot };
    var keyed: std.ArrayList(Keyed) = .empty;
    defer keyed.deinit(allocator);

    for (a.cells) |c| {
        const choice = c.choice orelse continue;
        if (choice.provenance != .door) continue;
        const cell: u8 = @as(u8, c.y) * @as(u8, @intCast(map.grid_w)) + c.x;
        const start = samusStart(cell);
        try keyed.append(allocator, .{
            .key = (@as(usize, c.bank) << 16) | cell,
            .boot = .{
                .map_index = c.bank - map.first_bank,
                .cell = cell,
                .door_index = choice.door_index,
                .tiletable = choice.tiletable,
                .palette = palette(screens.live_bgp),
                .obj_palette = palette(screens.live_obp0) ++ palette(screens.live_obp1),
                .samus_x = start.x,
                .samus_y = start.y,
                .cam_x = start.x,
                .cam_y = start.y,
            },
        });
    }
    std.mem.sort(Keyed, keyed.items, {}, struct {
        fn lt(_: void, x: Keyed, y: Keyed) bool {
            return x.key < y.key;
        }
    }.lt);
    for (keyed.items) |k| {
        if (out.items.len >= limit) break;
        try out.append(allocator, k.boot);
    }
    return out.toOwnedSlice(allocator);
}

/// A boot record for one *named* cell, with the provenance of the tileset it
/// was given.
///
/// `bootCandidates` and `chooseBoot` both pick a cell and then describe it, and
/// both restrict themselves to `.door` provenance -- when you are free to
/// choose, choose one the ROM states outright. The movie oracle has the
/// opposite problem: the *game* chose the cell, and the question is only
/// whether the cart can be pointed at it.
///
/// So this does not filter. It returns whatever the assignment concluded and
/// says how it concluded it, because for a cell nobody chose the provenance is
/// a fact about the answer rather than a filter on the question -- and
/// `oracle.compareWorlds` is what decides whether the answer was right, by
/// comparing the cart's tilemap against the Game Boy's. A `.scrolled` cell
/// whose world matches tile for tile is a correct boot; one whose world does
/// not is a measurement that the inference failed there, which is worth more
/// than declining to try.
pub const BootFor = struct { boot: Boot, provenance: screens.Provenance, distance: u8 };

///
/// **Through the crawl's reading since 1.0 Step 18c** (`warp.assignWalked`):
/// a cell whose room our Game Boy walked into is booted with what it loaded
/// there, which put `$F:$6B` and `$C:$21` right where the static reading had
/// them wrong (`docs/bug_tracker.md`, B12).
pub fn bootFor(allocator: std.mem.Allocator, rom: []const u8, map_index: u8, cell: u8) !?BootFor {
    return bootForAt(allocator, rom, map_index, cell, null);
}

/// `bootFor` at a Metroid count other than the new game's (release Step 0):
/// a walked lava room takes the table it shows at `count`
/// (`warp.LavaReplay`), as the recording's sweep reads it.
pub fn bootForAt(allocator: std.mem.Allocator, rom: []const u8, map_index: u8, cell: u8, count: ?u8) !?BootFor {
    const walked = try warp.loadWalked(allocator, rom);
    defer allocator.free(walked);
    var a = try warp.assignWalked(allocator, rom, walked);
    defer a.deinit(allocator);
    var found = (try bootIn(a, rom, map_index, cell)) orelse return null;
    if (count) |n| {
        if (try warp.lavaTableAt(allocator, rom, walked, map_index + map.first_bank, cell, n)) |t| found.boot.tiletable = t;
    }
    return found;
}

/// `bootFor` through a given assignment.
pub fn bootIn(a: screens.Assignment, rom: []const u8, map_index: u8, cell: u8) Error!?BootFor {
    for (a.cells) |c| {
        if (c.bank - map.first_bank != map_index) continue;
        const at: u8 = @as(u8, c.y) * @as(u8, @intCast(map.grid_w)) + c.x;
        if (at != cell) continue;
        const choice = c.choice orelse return null;
        const start = samusStart(at);
        const loadout = Loadout.newGame(rom) orelse return Error.NoBootScreen;
        return .{
            .provenance = choice.provenance,
            .distance = choice.distance,
            .boot = .{
                .map_index = map_index,
                .cell = at,
                .door_index = choice.door_index,
                .tiletable = choice.tiletable,
                .palette = palette(screens.live_bgp),
                .obj_palette = palette(screens.live_obp0) ++ palette(screens.live_obp1),
                .samus_x = start.x,
                .samus_y = start.y,
                .cam_x = start.x,
                .cam_y = start.y,
                .loadout = loadout,
            },
        };
    }
    return null;
}

pub fn chooseBoot(allocator: std.mem.Allocator, rom: []const u8) Error!Boot {
    var a = try screens.assign(allocator, rom);
    defer a.deinit(allocator);
    const loadout = Loadout.newGame(rom) orelse return Error.NoBootScreen;

    var best: ?Boot = null;
    var best_key: usize = std.math.maxInt(usize);
    for (a.cells) |c| {
        const choice = c.choice orelse continue;
        if (choice.provenance != .door) continue;
        const cell: u8 = @as(u8, c.y) * @as(u8, @intCast(map.grid_w)) + c.x;
        const key = (@as(usize, c.bank) << 16) | cell;
        if (key >= best_key) continue;
        best_key = key;
        const start = samusStart(cell);
        best = .{
            .map_index = c.bank - map.first_bank,
            .cell = cell,
            .door_index = choice.door_index,
            .tiletable = choice.tiletable,
            .palette = palette(screens.live_bgp),
            .obj_palette = palette(screens.live_obp0) ++ palette(screens.live_obp1),
            .samus_x = start.x,
            .samus_y = start.y,
            .cam_x = start.x,
            .cam_y = start.y,
            .loadout = loadout,
        };
    }
    return best orelse Error.NoBootScreen;
}

/// The start the *game* begins from, rather than one this repository chose.
///
/// **This is what B2 means by a cold boot with no synthesised boot record.**
/// `chooseBoot` searches the map for a cell some door states outright and then
/// invents a position in the middle of it; every number it produces is ours.
/// Every number here is the cartridge's:
///
///   * the position, the camera and the facing direction come from
///     `initial_save`, the $26 bytes `createNewSave` (01:4E1C) copies into
///     `saveBuffer` before game mode $02 reads them;
///   * the map bank comes from the same record, and the cell is the screen
///     halves of the two positions, which is how `WARP` packs one;
///   * the pose and the countdown come off the four instructions that end
///     `loadGame_samusData` (00:$0D0C), read out of the ROM by
///     `save.appearance` rather than transcribed.
///
/// Two things are still this side's, and both are named rather than hidden.
///
/// **The door script.** A new game does not run one: the original fills VRAM
/// from `loadGame_loadGraphics` and then renders the room out of the map data.
/// The port has no equivalent of either yet, and replays a script instead --
/// the one `screens.assign` paired with this cell, exactly as every other boot
/// does. That the two produce the same picture is not assumed here; it is what
/// the 904-screen render comparison grades. The record corroborates the
/// assignment for this cell independently, which is worth saying because the
/// cell is `.scrolled` rather than `.door`: the assignment answers table 5 and
/// `initial_save`'s own metatile pointer is `metatiles_surface`, which is
/// table 5.
///
/// **The frame counter's phase and the pad.** Both are zero, and zero is
/// correct rather than a default here: a cart that boots itself has nothing
/// held and no counter to be in step with.
pub fn newGameBoot(allocator: std.mem.Allocator, rom: []const u8) Error!Boot {
    const init = save.initial(rom) orelse return Error.NoBootScreen;
    const app = save.appearance(rom) orelse return Error.NoBootScreen;
    if (init.level_bank < map.first_bank or init.level_bank > map.last_bank) return Error.NoBootScreen;

    // The static reading, not the crawl's: a new game takes the load's path
    // (1.0 Step 18b) and runs no door script, so this door is not run.
    var a = try screens.assign(allocator, rom);
    defer a.deinit(allocator);
    const found = try bootIn(a, rom, init.level_bank - map.first_bank, init.cell()) orelse
        return Error.NoBootScreen;

    var boot = found.boot;
    boot.samus_x = init.samus_x;
    boot.samus_y = init.samus_y;
    boot.cam_x = init.cam_x;
    boot.cam_y = init.cam_y;
    boot.facing = init.facing;
    boot.pose = app.pose;
    boot.countdown = app.countdown;
    boot.mode = .new_game;
    const rec = offsets.find("initial_save") orelse return Error.NoBootScreen;
    if (rec.size != save_record_len or rec.romEnd() > rom.len) return Error.NoBootScreen;
    boot.save = rom[rec.romOffset()..][0..save_record_len].*;
    return boot;
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

test "the camera clamps where the original clamps" {
    // 01-requirements.md records the clamps as SCRN/2 and $100 - SCRN/2, and
    // `handleCamera` adds $08 to the downward one for the HUD band. Pin the
    // arithmetic, not just the formula. These bound a *blocked* edge only; an
    // open edge has no limit, which the carry tests above cover.
    try testing.expectEqual(@as(u16, 80), min_x);
    try testing.expectEqual(@as(u16, 176), max_x);
    try testing.expectEqual(@as(u16, 72), min_y);
    try testing.expectEqual(@as(u16, 192), max_y);

    // The window's edges land on the screen where the mask puts them.
    try testing.expectEqual(@as(u16, 48), win_left);
    try testing.expectEqual(@as(u16, 40), band_top);
    // At the left clamp the world's column 0 is the leftmost visible column,
    // so the scroll has to place world 0 at screen 48.
    try testing.expectEqual(@as(u16, 0x3FF - 48 + 1), scrollX(min_x));
    try testing.expectEqual(@as(u16, 0), scrollX(min_x + win_left));

    // The camera has to start somewhere it is allowed to be. It did not, once:
    // WRAM clears to zero and nothing wrote a starting position, so the first
    // frame ran with a camera 80 pixels outside its own left clamp.
    try testing.expect(start_x >= min_x and start_x <= max_x);
    try testing.expect(start_y >= min_y and start_y <= max_y);
    try testing.expect(cam_step > 0 and cam_step < max_x - min_x);
}

test "an open edge is a carry, not a crossing" {
    const open: u8 = 0x00;
    const cam: Camera = .{ .x = .{ .screen = 5, .pixel = 1 }, .y = .{ .screen = 3, .pixel = 128 } };

    // Well inside the screen a step is just a step.
    const inside = step(.{ .x = .{ .screen = 5, .pixel = 128 }, .y = cam.y }, .left, 2, open);
    try testing.expectEqual(@as(u8, 126), inside.x.pixel);
    try testing.expectEqual(@as(u8, 5), inside.x.screen);

    // At the edge it carries into the neighbour and keeps its sub-pixel phase.
    // This is the case Step 12 got wrong: it teleported to the far clamp, which
    // moved the view by a whole viewport in one two-pixel step.
    const crossed = step(cam, .left, 2, open);
    try testing.expectEqual(@as(u8, 255), crossed.x.pixel);
    try testing.expectEqual(@as(u8, 4), crossed.x.screen);

    // Rightwards, upwards and downwards carry the same way, so a transposed
    // axis or a dropped borrow cannot pass.
    const right = step(.{ .x = .{ .screen = 5, .pixel = 254 }, .y = cam.y }, .right, 4, open);
    try testing.expectEqual(@as(u8, 2), right.x.pixel);
    try testing.expectEqual(@as(u8, 6), right.x.screen);
    const up = step(.{ .x = cam.x, .y = .{ .screen = 3, .pixel = 0 } }, .up, 2, open);
    try testing.expectEqual(@as(u8, 254), up.y.pixel);
    try testing.expectEqual(@as(u8, 2), up.y.screen);
    const down = step(.{ .x = cam.x, .y = .{ .screen = 3, .pixel = 255 } }, .down, 2, open);
    try testing.expectEqual(@as(u8, 1), down.y.pixel);
    try testing.expectEqual(@as(u8, 4), down.y.screen);

    // The grid wraps rather than running off its edge, because the original
    // masks the screen nibble with $0f after every carry.
    const wrapped = step(.{ .x = .{ .screen = 0, .pixel = 0 }, .y = cam.y }, .left, 1, open);
    try testing.expectEqual(@as(u8, 15), wrapped.x.screen);
}

test "a blocked edge stops the camera on the clamp, and settles onto it" {
    const walls: u8 = 0x0F; // every direction blocked
    const y: Axis = .{ .screen = 3, .pixel = 128 };

    // Approaching the clamp is ordinary movement - the original does not clamp
    // before it moves, only once the camera is standing on the clamp.
    const near = step(.{ .x = .{ .screen = 5, .pixel = clamp_left + 2 }, .y = y }, .left, 2, walls);
    try testing.expectEqual(clamp_left, near.x.pixel);

    // On the clamp, nothing moves. In the original this is where a door
    // transition starts instead.
    const held = step(.{ .x = .{ .screen = 5, .pixel = clamp_left }, .y = y }, .left, 2, walls);
    try testing.expectEqual(clamp_left, held.x.pixel);
    try testing.expectEqual(@as(u8, 5), held.x.screen);

    // Past the clamp - which a multi-pixel step can overshoot into - it walks
    // back one pixel a frame rather than snapping.
    const settling = step(.{ .x = .{ .screen = 5, .pixel = clamp_left - 3 }, .y = y }, .left, 2, walls);
    try testing.expectEqual(clamp_left - 2, settling.x.pixel);

    // The other three, so no axis or sign is transposed.
    try testing.expectEqual(clamp_right, step(.{ .x = .{ .screen = 5, .pixel = clamp_right }, .y = y }, .right, 2, walls).x.pixel);
    try testing.expectEqual(clamp_up, step(.{ .x = y, .y = .{ .screen = 3, .pixel = clamp_up } }, .up, 2, walls).y.pixel);
    try testing.expectEqual(clamp_down, step(.{ .x = y, .y = .{ .screen = 3, .pixel = clamp_down } }, .down, 2, walls).y.pixel);

    // And the down clamp is 8 lower than its mirror, because the bottom 8 lines
    // of the Game Boy window are the HUD band.
    try testing.expectEqual(@as(u8, 192), clamp_down);
    try testing.expectEqual(@as(u8, 8), @as(u8, @intCast(clamp_down - (screen_span - target.view_h / 2))));
}

test "the scroll byte's bits are the ROM's, and a set bit is a wall" {
    // bit0 right, bit1 left, bit2 up, bit3 down, set meaning blocked. Both
    // halves matter: a symmetric test would miss a transposed axis, and a test
    // that only checked the bit positions would miss the inverted sense - which
    // is the one that shipped.
    try testing.expect(!permits(0b0001, .right));
    try testing.expect(permits(0b0001, .left));
    try testing.expect(!permits(0b0010, .left));
    try testing.expect(!permits(0b0100, .up));
    try testing.expect(!permits(0b1000, .down));
    try testing.expect(permits(0b0000, .right));
    try testing.expect(permits(0b1110, .right));
}

test "the tilemap is a mod-256 window, streamed a row or column at a time" {
    // A world of two screens side by side, each filled with a metatile that
    // names itself, so a tile in the map says which screen it came from.
    var metatiles: [3 * convert.metatile_bytes]u8 = @splat(0);
    for (1..3) |m| {
        for (0..4) |q| {
            const w: u16 = @intCast(0x100 * m + q);
            metatiles[m * convert.metatile_bytes + q * 2] = @truncate(w);
            metatiles[m * convert.metatile_bytes + q * 2 + 1] = @truncate(w >> 8);
        }
    }
    var left_body: [map.cells]u8 = @splat(1);
    var right_body: [map.cells]u8 = @splat(2);
    var bodies: [256]?[]const u8 = @splat(null);
    bodies[0x35] = &left_body;
    bodies[0x36] = &right_body;
    const world: World = .{ .bodies = &bodies, .metatiles = &metatiles };

    // Destination is the world position with the screen thrown away: the two
    // screens' metatile columns land on top of each other in the tilemap.
    try testing.expectEqual(@as(usize, 0), destTile(0, 0));
    try testing.expectEqual(destTile(0x10, 0x20), destTile(0x10, 0x20));
    try testing.expectEqual(@as(usize, 2 * 2 * target.tilemap_w + 3 * 2), destTile(0x3F, 0x2F));

    // Camera near the right edge of screen $35, streaming the rightward column.
    // The column is fetched $20 past the camera, which at pixel 240 is already
    // in screen $36 - so the tilemap holds tiles of the neighbour before the
    // camera has crossed. That is what makes a crossing seamless.
    var tm: Tilemap = @splat(0);
    const cam: Camera = .{ .x = .{ .screen = 5, .pixel = 240 }, .y = .{ .screen = 3, .pixel = 128 } };
    const corner = sourceCorner(cam, .right);
    try testing.expectEqual(@as(u8, 6), corner.x.screen);
    stream(&tm, world, cam, .right);

    const col = @as(usize, (corner.x.pixel & 0xF0) >> 4) * 2;
    var rows: usize = 0;
    for (0..target.tilemap_h) |row| {
        if (tm[row * target.tilemap_w + col] != 0) {
            // Even tile rows are the metatile's top half, odd rows its bottom.
            const want: u16 = if (row % 2 == 0) 0x200 else 0x202;
            try testing.expectEqual(want, tm[row * target.tilemap_w + col]);
            rows += 1;
        }
    }
    try testing.expectEqual(@as(usize, target.tilemap_h), rows);

    // Every other column is untouched: a column stream must not write a row.
    for (0..target.tilemap_h) |row| {
        for (0..target.tilemap_w) |c| {
            if (c == col or c == col + 1) continue;
            try testing.expectEqual(@as(u16, 0), tm[row * target.tilemap_w + c]);
        }
    }

    // The four directions are serviced round-robin, one per frame, so a column
    // has four frames to arrive - which is what bounds `cam_step`.
    try testing.expectEqual(Dir.up, serviced(0));
    try testing.expectEqual(Dir.down, serviced(1));
    try testing.expectEqual(Dir.left, serviced(2));
    try testing.expectEqual(Dir.right, serviced(3));
    try testing.expectEqual(Dir.up, serviced(4));
}

test "streaming fills the tilemap that buildTilemap would have drawn" {
    // The two paths have to agree, or a screen looks different depending on
    // whether you arrived by loading it or by scrolling into it.
    var metatiles: [256 * convert.metatile_bytes]u8 = @splat(0);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    prng.random().bytes(&metatiles);
    var body: [map.cells]u8 = undefined;
    prng.random().bytes(&body);

    var built: Tilemap = undefined;
    _ = buildTilemap(&built, &body, &metatiles, .none);

    var bodies: [256]?[]const u8 = @splat(null);
    bodies[0x00] = &body;
    const world: World = .{ .bodies = &bodies, .metatiles = &metatiles };

    // Stream all 16 rows of the one screen, from a camera standing in it.
    var streamed: Tilemap = @splat(0xFFFF);
    for (0..map.grid_h) |row| {
        const at: Camera = .{
            .x = .{ .screen = 0, .pixel = 0 },
            .y = .{ .screen = 0, .pixel = @intCast(row * 16) },
        };
        for (0..map.grid_w) |col| {
            streamOne(&streamed, world, .{
                .x = .{ .screen = 0, .pixel = @intCast(col * 16) },
                .y = at.y,
            });
        }
    }
    try testing.expectEqualSlices(u16, &built, &streamed);
}

test "neighbours stop at the grid edge" {
    try testing.expectEqual(@as(?u8, null), neighbour(0, .left));
    try testing.expectEqual(@as(?u8, null), neighbour(0, .up));
    try testing.expectEqual(@as(?u8, 0xFE), neighbour(0xFF, .left));
    try testing.expectEqual(@as(?u8, null), neighbour(0xFF, .right));
    try testing.expectEqual(@as(?u8, null), neighbour(0xFF, .down));
    try testing.expectEqual(@as(?u8, 0x11), neighbour(0x01, .down));
}

test "a metatile becomes four words in TL TR BL BR order" {
    // One metatile at index 1, four distinguishable words, in a body that
    // places it at grid (row 1, col 2).
    var metatiles: [2 * convert.metatile_bytes]u8 = @splat(0);
    for (0..4) |q| {
        const w: u16 = @intCast(0x1000 + q);
        metatiles[convert.metatile_bytes + q * 2] = @truncate(w);
        metatiles[convert.metatile_bytes + q * 2 + 1] = @truncate(w >> 8);
    }
    var body: [map.cells]u8 = @splat(0);
    body[1 * map.grid_w + 2] = 1;

    var tm: Tilemap = undefined;
    const stats = buildTilemap(&tm, &body, &metatiles, .none);
    try testing.expectEqual(@as(usize, 0), stats.out_of_range);

    const base = (1 * 2) * target.tilemap_w + 2 * 2;
    try testing.expectEqual(@as(u16, 0x1000), tm[base]);
    try testing.expectEqual(@as(u16, 0x1001), tm[base + 1]);
    try testing.expectEqual(@as(u16, 0x1002), tm[base + target.tilemap_w]);
    try testing.expectEqual(@as(u16, 0x1003), tm[base + target.tilemap_w + 1]);

    // The faults have to actually change something, or the sweep proves
    // nothing.
    var faulted: Tilemap = undefined;
    _ = buildTilemap(&faulted, &body, &metatiles, .quadrants);
    try testing.expect(!std.mem.eql(u16, &tm, &faulted));
    _ = buildTilemap(&faulted, &body, &metatiles, .transpose);
    try testing.expect(!std.mem.eql(u16, &tm, &faulted));
}

test "an index past the end of the table region is counted, not read" {
    var metatiles: [convert.metatile_bytes]u8 = @splat(0xAB);
    var body: [map.cells]u8 = @splat(0);
    body[0] = 1; // one metatile past the single-entry table
    var tm: Tilemap = undefined;
    const stats = buildTilemap(&tm, &body, &metatiles, .none);
    try testing.expectEqual(@as(usize, 1), stats.out_of_range);
    try testing.expectEqual(@as(u16, 0), tm[0]);
}

test "the palette is four greys with the backdrop shade first" {
    const p = palette(screens.live_bgp);
    // BGP $93 puts shade 3 in index 0, so the play field's colour 0 - and the
    // backdrop with it - is black.
    try testing.expectEqual(@as(u16, 0x0000), p[0]);
    try testing.expectEqual(@as(u16, 0x7FFF), p[1]);
    // Greys, so all three channels agree.
    for (p) |c| {
        const r = c & 0x1F;
        try testing.expectEqual(r, (c >> 5) & 0x1F);
        try testing.expectEqual(r, (c >> 10) & 0x1F);
        try testing.expectEqual(@as(u16, 0), c >> 15);
    }
}

