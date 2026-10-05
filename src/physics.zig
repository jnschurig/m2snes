//! Samus's vertical motion, as the ROM stores it.
//!
//! The jump and fall arcs are per-frame vertical speeds in pixels, signed:
//! negative rises, positive falls. `samus_fallArcCounter` and
//! `samus_jumpArcCounter` index them a frame at a time, so the shape of the
//! arc is data and only the counter management is code. That is what makes
//! them extractable at all - `01-requirements.md` filed the physics constants
//! as "scattered as immediates through bank 0", and most of them are, but the
//! two that decide what a jump *feels* like are tables at fixed addresses.
//!
//! The jump arcs end in $80. That byte is a terminator rather than a speed
//! (-128 pixels in a frame is not a thing), and checking that it lands exactly
//! last is what makes the round trip evidence about the address rather than a
//! copy: read the table one byte early or late and the terminator moves.
//! The fall arc has no terminator - the code caps its counter at $16 instead -
//! so "unterminated" is a property of the arc, not a parse failure.

const std = @import("std");

pub const terminator: u8 = 0x80;

pub const Error = error{ TerminatorNotLast, EmptyArc };

pub const Arc = struct {
    /// One signed pixel delta per frame.
    speeds: []i8,
    /// Whether the ROM marks the end of the arc, as the jump tables do.
    terminated: bool,

    pub fn deinit(self: Arc, allocator: std.mem.Allocator) void {
        allocator.free(self.speeds);
    }

    /// Where the arc has carried Samus after `frames` frames, in pixels down.
    /// A terminated arc holds its last speed once the counter runs off the end,
    /// which is what the engine's counter cap amounts to.
    pub fn displacement(self: Arc, frames: usize) i32 {
        if (self.speeds.len == 0) return 0;
        var sum: i32 = 0;
        for (0..frames) |i| {
            const at = @min(i, self.speeds.len - 1);
            sum += self.speeds[at];
        }
        return sum;
    }
};

pub fn parseArc(allocator: std.mem.Allocator, bytes: []const u8) !Arc {
    if (bytes.len == 0) return Error.EmptyArc;

    // A $80 anywhere but the last byte means the table is not what we think it
    // is, and a table that has none simply is not terminated.
    var terminated = false;
    for (bytes, 0..) |b, i| {
        if (b != terminator) continue;
        if (i != bytes.len - 1) return Error.TerminatorNotLast;
        terminated = true;
    }

    const n = if (terminated) bytes.len - 1 else bytes.len;
    const speeds = try allocator.alloc(i8, n);
    errdefer allocator.free(speeds);
    for (0..n) |i| speeds[i] = @bitCast(bytes[i]);
    return .{ .speeds = speeds, .terminated = terminated };
}

pub fn encodeArc(allocator: std.mem.Allocator, arc: Arc) ![]u8 {
    const out = try allocator.alloc(u8, arc.speeds.len + @intFromBool(arc.terminated));
    for (arc.speeds, 0..) |s, i| out[i] = @bitCast(s);
    if (arc.terminated) out[arc.speeds.len] = terminator;
    return out;
}

/// Which blob of the `physics` class this is, and the id the engine asks the
/// directory for.
///
/// The order is the interface between `snes_convert` and `engine/main.asm`'s
/// `!PHYS_*` constants: a blob's id is its index here, so adding one means
/// appending, never inserting.
pub const Which = enum(u8) {
    fall = 0,
    jump = 1,
    space_jump = 2,
    /// The top of Samus's hitbox per pose, for `collision_samusTop`.
    hitbox_top = 3,
    /// The vertical offsets `collision_samusHorizontal` samples at, per pose.
    hitbox_y_offsets = 4,
    /// The knockback arc `poseFunc_bombed` flies, read exactly as the jump arc
    /// is - index, compare against $80, enter the falling pose. Added in B4b.
    bomb = 5,
    /// The top of Samus's hitbox per pose for *sprite* collisions, which is a
    /// different table and a different bias from `hitbox_top`'s.
    sprite_hitbox_top = 6,
    /// The pose `hurtSamus` forces her into, per pose she was in.
    damage_poses = 7,
    /// The pose `poseFunc_bombed` leaves her in when the arc runs out.
    bombed_falling_poses = 8,
    // ---- B5's projectile half, Step 12b. ---------------------------------
    // Eleven small tables `samusShoot`, `handleProjectiles`, `drawProjectiles`
    // and the damage arm index directly. They are `physics` blobs rather than a
    // class of their own for the reason the four above are: the class is what
    // the engine looks a small table up in, not a claim about what the table
    // means.
    /// Per pose: which directions may be fired in, $80 for "lay a bomb".
    shot_directions = 9,
    /// Per d-pad combination: the one direction the shot takes.
    shot_priority = 10,
    /// Per (firing direction, facing): the projectile's X offset from Samus.
    cannon_x = 11,
    /// Per pose: its Y offset.
    cannon_y_pose = 12,
    /// Per firing direction: the rest of its Y offset.
    cannon_y_aim = 13,
    /// The wave beam's transverse velocity, with its $80 terminator kept.
    wave_speeds = 14,
    /// The missile's acceleration curve, with its $FF terminator kept.
    missile_speeds = 15,
    /// Per direction: the character and attribute a flying missile draws with.
    missile_sprite_tiles = 16,
    missile_sprite_attrs = 17,
    /// Per weapon: the sound `samusShoot` requests. The port has no driver, so
    /// what reads this leaves the id in `!Sfx1`.
    beam_sounds = 18,
    /// Per weapon: how much health a hit takes off an enemy.
    weapon_damage = 19,
    // ---- Step 12f's enemy AIs. ----------------------------------------------
    /// The hopper's jump, one speed per call on each axis.
    hopper_arc_y = 20,
    hopper_arc_x = 21,
    /// The Gullugg's circle, with the Y table's $80 terminator kept.
    gullugg_y = 22,
    gullugg_x = 23,
    /// The Chute Leech's descent, with the X table's $80 terminator kept.
    chute_leech_x = 24,
    chute_leech_y = 25,
    /// The two acceleration curves the pipe bug flies away on.
    accel_forwards = 26,
    accel_backwards = 27,
    // ---- Step 12c's bombs. -------------------------------------------------
    /// The pose an explosion throws Samus into, per pose she was in.
    bomb_poses = 28,
    // ---- Step 13b's HUD. ---------------------------------------------------
    /// `hudBaseTilemap`: the status bar's twenty window tile ids at boot. Not
    /// physics in any sense but the one the class means -- a small table the
    /// engine looks up once.
    hud_base = 29,
    // ---- Step 13c's Alpha. -------------------------------------------------
    /// `alpha_getAngleFromTable.angleTable`: the lunge angle per quadrant and
    /// slope band.
    alpha_angles = 30,
    /// `alpha_getSpeedVector`'s sixteen `LD BC,d16 / RET` arms, carried whole:
    /// the engine reads each operand out of its arm.
    alpha_speeds = 31,
    // ---- Step 14b's spider ball. -------------------------------------------
    /// `spiderDirectionTable`: four rows of sixteen, the direction to try per
    /// contact nibble, counter-clockwise then clockwise, first try then second.
    spider_dirs = 32,
    /// `spiderBallOrientationTable`: the rotation a pad press gives, per
    /// contact nibble and pad nibble.
    spider_orient = 33,
    // ---- Step 15a's save buffer. -------------------------------------------
    /// `metatilePointerTable` (08:$7F1A): what `door_loadTiletable` stores in
    /// the save buffer for a `TILETABLE` operand. A save record carries the
    /// pointer, not the operand, so the cart needs the pointer to write one.
    metatile_pointers = 34,
    /// `collision_pointers` (08:$7EEA): the same for `COLLISION`.
    collision_pointers = 35,
    // ---- Step 15c's death. -------------------------------------------------
    /// `deathAnimationTable` (00:$3042): the byte of a two-tile stride each of
    /// the death's 32 erase steps zeroes, indexed by the step counter less one.
    death_erase = 36,
    /// `gameOverText` (00:$3711): the GAME OVER screen's nine tile ids, with the
    /// $80 the copy stops on kept, because the copy reads it.
    game_over_text = 37,
    // ---- Step 24g's bar. ---------------------------------------------------
    /// `saveTextTilemap` (05:$4104): the window's second row at boot, twenty
    /// tile ids, " SAVE<>" and blanks.
    save_text = 38,
    /// `item_names` (01:$58F1): the sixteen pointers and the sixteen 16-byte
    /// names `ITEM`'s fourth transfer copies to that row. Carried whole, with
    /// its pointer table, because the arm indexes the table and not the names.
    item_names = 39,
    // ---- 1.0 Step 2a's pause. ----------------------------------------------
    /// `metroidLCounterTable` (00:$203B): the L counter the pause shows, per
    /// `metroidCountReal`, which indexes it as the BCD byte it is.
    l_counter = 40,
    // ---- 1.0 Step 6's Queen. ----------------------------------------------
    /// `queen_headFrameA`-`C` (03:$6FA2): three 6x6 frames of window tile ids,
    /// which `queen_drawHead` copies to $9C00 three rows a vblank.
    queen_head = 41,
    // ---- 1.0 Step 11's ordinary AIs. --------------------------------------
    /// `enemy_skreekJumpSpeeds` (02:$5A7D): the skreek's rise and sink.
    skreek_jump = 42,
    /// `enemy_drivelYSpeeds` and `XSpeeds` (02:$5B79, $5B97): the drivel's swoop.
    drivel_y = 43,
    drivel_x = 44,
    /// `enemy_sineConcaveSpeeds` and `ConvexSpeeds` (02:$682D, $6837): the
    /// halzyn's weave, and the missile block's (Step 12).
    sine_concave = 45,
    sine_convex = 46,
    // ---- 1.0 Step 12's. ---------------------------------------------------
    /// `enAI_blobThrower.sprite` through `.speedTable_bottom` (02:$4FFE): the
    /// thrower's part list and hitbox, which `blobThrower_loadSprite` copies
    /// to WRAM, and the three speed tables it rises and sinks along.
    blob_thrower = 47,
    /// `blobMovementTable_A`-`D` (02:$53D7): the four blobs' moves.
    blob_moves = 48,
    // ---- 1.0 Step 13's. ---------------------------------------------------
    /// `enAI_arachnus.jumpSpeedTable_high`, `_mid` and `_low` (02:$52FC), read
    /// as one run.
    arachnus_jump = 49,
    // ---- 1.0 Step 14's. ---------------------------------------------------
    /// `gamma_getAngleFromTable.angleTable`: the Gamma's lunge angle per
    /// quadrant and slope band.
    gamma_angles = 50,
    /// `gamma_getSpeedVector`'s twenty-four `LD BC,d16 / RET` arms, carried
    /// whole, as `alpha_speeds`.
    gamma_speeds = 51,
    // ---- 1.0 Step 15's. ---------------------------------------------------
    /// `enemy_seekSamus.speedTable` (03:$6BB1): the per-index step the
    /// seeking Metroids add to Y and X.
    seek_speeds = 52,
    // ---- 1.0 Step 19b's Queen. ---------------------------------------------
    /// `queen_neckPatternPointers` (03:$6C8E) and the seven patterns after it,
    /// carried whole: the pointers are Game Boy addresses, which the engine
    /// makes offsets into the blob.
    queen_neck = 53,
    /// `queen_rearFootPointers` (03:$70C4) through `queen_frontFootOffsets`:
    /// the two pointer tables, the six feet's cells and the two offset tables.
    queen_feet = 54,
    /// `queen_stateList` (03:$7484): the fight's states in order, $FF last.
    queen_states = 55,
    /// `queen_walk.walkSpeedTable` (03:$7C39), $81 and $82 kept: the reader
    /// stops on them.
    queen_walk = 56,
    // ---- 1.0 Step 20b's. ---------------------------------------------------
    /// `queen_bentNeckSprite` (03:$7961): the five objects of her neck bent
    /// up while she throws Samus up, (Y, X, tile) each.
    queen_bent_neck = 57,
    // ---- 1.0 Step 22's. ----------------------------------------------------
    /// `credits_paletteFade` (05:$5877): the eight palettes the fade steps
    /// through, read from the end.
    credits_fade = 58,
    /// `credits_starPositions` (05:$5B14): sixteen stars' (y, x), of which the
    /// setup copies the first eight.
    credits_stars = 59,
    /// `creditsText` (06:$7920): the credits, to and with their $F0.
    credits_text = 60,

    /// The `offsets.zig` entry this blob is read from.
    pub fn entry(self: Which) []const u8 {
        return switch (self) {
            .fall => "physics_fallArc",
            .jump => "physics_jumpArc",
            .space_jump => "physics_spaceJumpArc",
            .hitbox_top => "collision_samusBGHitboxTop",
            .hitbox_y_offsets => "collision_samusHorizontalYOffsets",
            .bomb => "physics_bombArc",
            .sprite_hitbox_top => "collision_samusSpriteHitboxTop",
            .damage_poses => "samus_damagePoseTable",
            .bombed_falling_poses => "samus_bombedFallingPoses",
            .shot_directions => "samus_possibleShotDirections",
            .shot_priority => "samus_shotDirectionPriority",
            .cannon_x => "samus_cannonXOffsets",
            .cannon_y_pose => "samus_cannonYOffsetsByPose",
            .cannon_y_aim => "samus_cannonYOffsetsByAim",
            .wave_speeds => "projectile_waveSpeeds",
            .missile_speeds => "projectile_missileSpeeds",
            .missile_sprite_tiles => "projectile_missileSpriteTiles",
            .missile_sprite_attrs => "projectile_missileSpriteAttrs",
            .beam_sounds => "projectile_beamSounds",
            .weapon_damage => "weapon_damage",
            .hopper_arc_y => "enemy_hopperArcY",
            .hopper_arc_x => "enemy_hopperArcX",
            .gullugg_y => "enemy_gulluggYSpeeds",
            .gullugg_x => "enemy_gulluggXSpeeds",
            .chute_leech_x => "enemy_chuteLeechXSpeeds",
            .chute_leech_y => "enemy_chuteLeechYSpeeds",
            .accel_forwards => "enemy_accelForwards",
            .accel_backwards => "enemy_accelBackwards",
            .bomb_poses => "samus_bombPoseTable",
            .hud_base => "hudBaseTilemap",
            .alpha_angles => "alpha_angleTable",
            .alpha_speeds => "alpha_speedVectors",
            .spider_dirs => "spiderDirectionTable",
            .spider_orient => "spiderBallOrientationTable",
            .metatile_pointers => "metatile_pointers",
            .collision_pointers => "collision_pointers",
            .death_erase => "deathAnimationTable",
            .game_over_text => "gameOverText",
            .save_text => "saveTextTilemap",
            .item_names => "item_names",
            .l_counter => "metroidLCounterTable",
            .queen_head => "queen_headFrames",
            .skreek_jump => "enemy_skreekJumpSpeeds",
            .drivel_y => "enemy_drivelYSpeeds",
            .drivel_x => "enemy_drivelXSpeeds",
            .sine_concave => "enemy_sineConcaveSpeeds",
            .sine_convex => "enemy_sineConvexSpeeds",
            .blob_thrower => "blobThrower_data",
            .blob_moves => "blobMovementTables",
            .arachnus_jump => "arachnus_jumpSpeedTables",
            .gamma_angles => "gamma_angleTable",
            .gamma_speeds => "gamma_speedVectors",
            .seek_speeds => "seekSamus_speedTable",
            .queen_neck => "queen_neckPatterns",
            .queen_feet => "queen_feet",
            .queen_states => "queen_stateList",
            .queen_walk => "queen_walkSpeeds",
            .queen_bent_neck => "queen_bentNeckSprite",
            .credits_fade => "credits_paletteFade",
            .credits_stars => "credits_starPositions",
            .credits_text => "creditsText",
        };
    }

    /// The `Which` an `offsets.zig` entry name belongs to, or null if the
    /// entry is not a physics blob at all. The inverse of `entry`, and it is
    /// here rather than open-coded in `roundtrip.zig` so the two directions
    /// cannot drift apart.
    pub fn forEntry(name: []const u8) ?Which {
        for (0..which_count) |i| {
            const w: Which = @enumFromInt(i);
            if (std.mem.eql(u8, w.entry(), name)) return w;
        }
        return null;
    }

    /// Arcs lose their terminator to the blob length; the hitbox tables are
    /// geometry the engine indexes directly and convert unchanged.
    pub fn isArc(self: Which) bool {
        return switch (self) {
            .fall, .jump, .space_jump, .bomb => true,
            .hitbox_top,
            .hitbox_y_offsets,
            .sprite_hitbox_top,
            .damage_poses,
            .bombed_falling_poses,
            // The two terminated tables Step 12b adds keep their terminator:
            // the wave index *resets* on its $80 rather than stopping, and the
            // missile reader holds its counter on the $FF and then reads the
            // entry in front of it -- so in both the terminator is an operand
            // of the reader and not a length in disguise.
            .shot_directions,
            .shot_priority,
            .cannon_x,
            .cannon_y_pose,
            .cannon_y_aim,
            .wave_speeds,
            .missile_speeds,
            .missile_sprite_tiles,
            .missile_sprite_attrs,
            .beam_sounds,
            .weapon_damage,
            .hopper_arc_y,
            .hopper_arc_x,
            .gullugg_y,
            .gullugg_x,
            .chute_leech_x,
            .chute_leech_y,
            .accel_forwards,
            .accel_backwards,
            .bomb_poses,
            .hud_base,
            .alpha_angles,
            .alpha_speeds,
            .spider_dirs,
            .spider_orient,
            .metatile_pointers,
            .collision_pointers,
            .death_erase,
            .game_over_text,
            .save_text,
            .item_names,
            .l_counter,
            .queen_head,
            .skreek_jump,
            .drivel_y,
            .drivel_x,
            .sine_concave,
            .sine_convex,
            .blob_thrower,
            .blob_moves,
            .arachnus_jump,
            .gamma_angles,
            .gamma_speeds,
            .seek_speeds,
            .queen_neck,
            .queen_feet,
            .queen_states,
            .queen_walk,
            .queen_bent_neck,
            .credits_fade,
            .credits_stars,
            .credits_text,
            => false,
        };
    }
};

pub const which_count = @typeInfo(Which).@"enum".fields.len;

// ---------------------------------------------------------------------------
// The hitbox tables.
//
// `collision_samusHorizontal` walks a row of vertical offsets and samples the
// tilemap at each; `collision_samusTop` reads one offset for the pose. Both are
// biased by OAM_Y_OFS, because `getTilemapAddress` subtracts it back off - so
// the bytes are carried exactly as the ROM has them and the bias is undone
// where the original undoes it, rather than being normalised out here and
// re-added somewhere else.

/// The two OAM biases the collision arithmetic runs through. `getTilemapAddress`
/// subtracts both before dividing by 8, so an offset table entry is
/// `bias + hitbox offset` and nothing else.
pub const oam_y_ofs: u8 = 16;
pub const oam_x_ofs: u8 = 8;

/// Hitbox offsets from Samus's origin, the ones the ported routines name.
/// `constants.asm` derives all of them from the two `toCenter` values.
pub const origin_x_to_center: i8 = 0x08;
pub const origin_y_to_center: i8 = 0x0A;
pub const origin_x_to_left: i8 = origin_x_to_center - 0x05;
pub const origin_x_to_right: i8 = origin_x_to_center + 0x04;
pub const origin_y_to_stand: i8 = origin_y_to_center - 0x12;
pub const origin_y_to_stand_check: i8 = origin_y_to_stand + 0x08;
pub const origin_y_to_bottom: i8 = origin_y_to_center + 0x12;

/// Poses the BG-top table covers, $00-$15.
pub const hitbox_top_poses: usize = 0x16;
/// Poses the y-offset lists cover, $00-$1D.
pub const y_offset_poses: usize = 0x1E;
/// Bytes per row. The stride is 8; the reader is not.
pub const y_offset_stride: usize = 8;
/// `collision_samusHorizontal` is unrolled five deep, so a row past five
/// offsets could not be read however many the stride would hold.
pub const y_offset_max: usize = 5;

pub const HitboxError = error{
    WrongTableLength,
    /// A row whose terminator sits past what the unrolled reader can reach, or
    /// whose bytes past the terminator are not the zero padding every real row
    /// has. Either would mean the row is not eight bytes starting where we
    /// think it does.
    RowNotPadded,
};

/// One pose's horizontal sample offsets. `count` is how many the reader would
/// actually use; the four unused poses carry a row of zeroes with no terminator
/// at all, which reads as five zero offsets and is why `terminated` is recorded
/// rather than assumed.
pub const YOffsetRow = struct {
    offsets: [y_offset_max]u8,
    count: usize,
    terminated: bool,
};

pub fn parseYOffsets(bytes: []const u8) ![y_offset_poses]YOffsetRow {
    if (bytes.len != y_offset_poses * y_offset_stride) return HitboxError.WrongTableLength;
    var out: [y_offset_poses]YOffsetRow = undefined;
    for (0..y_offset_poses) |p| {
        const row = bytes[p * y_offset_stride ..][0..y_offset_stride];
        var r: YOffsetRow = .{ .offsets = @splat(0), .count = y_offset_max, .terminated = false };
        for (row, 0..) |b, i| {
            if (b != terminator) continue;
            if (i > y_offset_max) return HitboxError.RowNotPadded;
            r.count = i;
            r.terminated = true;
            break;
        }
        // Everything past the terminator is padding, and padding is zero in
        // every row of the retail table. A non-zero byte there would mean the
        // stride is not eight.
        if (r.terminated) {
            for (row[r.count + 1 ..]) |b| {
                if (b != 0) return HitboxError.RowNotPadded;
            }
        }
        @memcpy(r.offsets[0..r.count], row[0..r.count]);
        out[p] = r;
    }
    return out;
}

pub fn encodeYOffsets(rows: [y_offset_poses]YOffsetRow) [y_offset_poses * y_offset_stride]u8 {
    var out: [y_offset_poses * y_offset_stride]u8 = @splat(0);
    for (rows, 0..) |r, p| {
        const row = out[p * y_offset_stride ..][0..y_offset_stride];
        @memcpy(row[0..r.count], r.offsets[0..r.count]);
        if (r.terminated) row[r.count] = terminator;
    }
    return out;
}

/// Where the ascent stops being linear and starts reading `physics_jumpArc`.
/// `poseFunc_spinJump` compares the counter against this before indexing, and
/// subtracts it first - so the table describes the arc from that point on.
pub const jump_array_base_offset: u8 = 0x40;

/// The linear part of the ascent, in pixels up per frame while A is held.
pub const jump_rise_normal: i8 = -2;
pub const jump_rise_hi_jump: i8 = -3;

// ---------------------------------------------------------------------------

const testing = std.testing;

test "an arc round-trips, and the terminator has to be last" {
    const bytes = [_]u8{ 0xFE, 0xFF, 0x00, 0x01, 0x80 };
    const arc = try parseArc(testing.allocator, &bytes);
    defer arc.deinit(testing.allocator);

    try testing.expect(arc.terminated);
    try testing.expectEqual(@as(usize, 4), arc.speeds.len);
    try testing.expectEqual(@as(i8, -2), arc.speeds[0]);
    try testing.expectEqual(@as(i8, 1), arc.speeds[3]);

    const back = try encodeArc(testing.allocator, arc);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, &bytes, back);

    // Reading the table one byte late moves the terminator off the end.
    try testing.expectError(Error.TerminatorNotLast, parseArc(testing.allocator, &.{ 0x80, 0x01 }));
    try testing.expectError(Error.EmptyArc, parseArc(testing.allocator, &.{}));
}

test "an unterminated arc is a shape, not a failure" {
    const bytes = [_]u8{ 0x01, 0x01, 0x02, 0x03 };
    const arc = try parseArc(testing.allocator, &bytes);
    defer arc.deinit(testing.allocator);
    try testing.expect(!arc.terminated);
    try testing.expectEqual(@as(usize, 4), arc.speeds.len);

    // Past the end the last speed is held, which is the counter cap.
    try testing.expectEqual(@as(i32, 7), arc.displacement(4));
    try testing.expectEqual(@as(i32, 13), arc.displacement(6));
}

test "a y-offset row is five offsets at most, and the rest is padding" {
    var bytes: [y_offset_poses * y_offset_stride]u8 = @splat(0);
    // A full-length row: five offsets, then the terminator at index 5.
    const full = [_]u8{ 0x10, 0x18, 0x20, 0x28, 0x2A, terminator, 0, 0 };
    @memcpy(bytes[0..8], &full);
    // A short row, and an unused row that is all zeroes with no terminator.
    const short = [_]u8{ 0x20, 0x25, 0x2A, terminator, 0, 0, 0, 0 };
    @memcpy(bytes[8..16], &short);

    const rows = try parseYOffsets(&bytes);
    try testing.expectEqual(@as(usize, 5), rows[0].count);
    try testing.expect(rows[0].terminated);
    try testing.expectEqual(@as(u8, 0x2A), rows[0].offsets[4]);
    try testing.expectEqual(@as(usize, 3), rows[1].count);
    try testing.expect(rows[1].terminated);
    // The unused poses read as five zero offsets, which is what the unrolled
    // reader would do with them - not as an empty list.
    try testing.expectEqual(@as(usize, y_offset_max), rows[2].count);
    try testing.expect(!rows[2].terminated);

    try testing.expectEqualSlices(u8, &bytes, &encodeYOffsets(rows));

    // A terminator the reader could never reach means the stride is wrong.
    bytes[0] = 0x10;
    @memcpy(bytes[0..8], &[_]u8{ 1, 2, 3, 4, 5, 6, terminator, 0 });
    try testing.expectError(HitboxError.RowNotPadded, parseYOffsets(&bytes));
    // So does a non-zero byte in the padding.
    @memcpy(bytes[0..8], &[_]u8{ 1, terminator, 0, 9, 0, 0, 0, 0 });
    try testing.expectError(HitboxError.RowNotPadded, parseYOffsets(&bytes));
    try testing.expectError(HitboxError.WrongTableLength, parseYOffsets(bytes[0..16]));
}
