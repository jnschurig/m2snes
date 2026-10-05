//! 1.0 Step 8a: the `gfx` rung -- `loadGraphics` graded against our Game Boy.
//!
//! Each case is one pickup. Both machines start from a new game in play, are
//! given the items the case needs first, and then the pickup. **The pickup's
//! lever is `snes boot` phase 9's**: `enAI_itemOrb` stores the item number in
//! `itemCollected` and $FF in `itemCollectionFlag` when Samus touches the
//! item, so both are written on both machines, and cleared again when the
//! engine puts $03 in the flag, standing in for the orb deleting itself. The
//! orb is B6's and graded there; what is graded here is everything downstream
//! of it.
//!
//! **What comes first differs by machine, on purpose.** Our Game Boy is given
//! the prerequisite bits by writing them (the rule against forcing state binds
//! the cart, not the reference). The cart gets them through the debug menu's
//! own input, whose sync (`SamusGfxSync`) puts up the tiles a pickup would
//! have. The pickup under test then lays its records over either. A case with
//! missiles selected presses Select on both.
//!
//! Graded, after the pickup:
//! - the object characters $8000-$87FF, where every record lands (the cart's
//!   are 4bpp, so each Game Boy tile is its sixteen bytes and sixteen zeroes);
//! - how many frames the transfer flag was up: `vramTransferFlag` on the Game
//!   Boy, the queue not empty on the cart. The vblank handler moves a chunk a
//!   frame on both, so this is the records' chunk count, and a port that moved
//!   more a frame, or less, or waited on nothing, differs;
//! - the item's bit, the selected weapon, and her pose.
//!
//! **1.0 Step 9: Varia's transformation.** `animateGettingVaria` holds the
//! Game Boy's flag up from its first frame, so the cart counts its animation
//! as transfer too, and Varia's frames are graded with the rest. Varia's
//! whole pickup, from the orb's stores to the flag reaching $03, is graded on
//! its length as a cutscene is, within 2% of the Game Boy's; the rest print
//! theirs. And every pickup that sets a bit is graded, exactly, on the frames
//! from the bit landing to the flag's $03: the two machines take the orb's
//! stores at different points of a frame, so the whole length reads one frame
//! longer on the cart for every item, and this is the span the lever does not
//! reach.

const std = @import("std");
const harness = @import("gb/harness.zig");
const probe = @import("gb/probe.zig");
const room = @import("room.zig");
const items = @import("items.zig");
const inject = @import("snes_inject.zig");
const target = @import("snes_target.zig");
const scenario = @import("scenario.zig");

// ---- The Game Boy's addresses, as M2RoS names them -------------------------

const samus_pose: u16 = 0xD020;
const samus_items: u16 = 0xD045;
const vram_transfer_flag: u16 = 0xD047;
const frame_counter: u16 = 0xFF97;
/// `gameTimeSeconds`, the 256-frame periods `waitForNextFrame` counts.
const game_time_seconds: u16 = 0xD0A2;
const samus_active_weapon: u16 = 0xD04D;
const item_collected: u16 = 0xD06C;
const item_collection_flag: u16 = 0xD06D;
/// The object characters every record lands in.
pub const chars_at: u16 = 0x8000;
pub const chars_len: usize = 0x800;
/// `enAI_itemOrb`'s two stores, and the flag's value when the jingle is done.
const flag_collecting: u8 = 0xFF;
const flag_done: u8 = 0x03;

pub const Case = struct {
    name: []const u8,
    item: items.Collected,
    /// SAMUS page rows switched on first.
    first: []const scenario.Row = &.{},
    /// Select pressed first: missiles selected.
    missiles: bool = false,
    /// Whether the transfer's frames are graded.
    frames: bool = true,
    /// Whether the pickup's length is graded, within `length_tolerance`.
    length: bool = false,
};

/// The cutscene rule's 2% (F10, 2026-08-31).
pub const length_tolerance: f64 = 0.02;

pub const cases = [_]Case{
    .{ .name = "ice", .item = .ice_beam },
    .{ .name = "wave", .item = .wave_beam },
    .{ .name = "spazer", .item = .spazer },
    .{ .name = "plasma", .item = .plasma_beam },
    .{ .name = "ice missiles", .item = .ice_beam, .missiles = true },
    .{ .name = "screw", .item = .screw_attack },
    .{ .name = "screw space", .item = .screw_attack, .first = &.{.space} },
    .{ .name = "space", .item = .space_jump },
    .{ .name = "space screw", .item = .space_jump, .first = &.{.screw} },
    .{ .name = "spring", .item = .spring_ball },
    .{ .name = "varia", .item = .varia, .length = true },
    .{ .name = "varia everything", .item = .varia, .first = &.{ .screw, .space, .spring }, .missiles = true, .length = true },
};

pub const Ref = struct {
    chars: [chars_len]u8,
    xfer_frames: u16,
    /// Frames from the orb's stores to the flag's $03.
    length: u16,
    /// `frameCounter` ($FF97) when the stores were made.
    counter: u8,
    /// Frames from the item's bit landing to the flag's $03, or zero for an
    /// item with no bit.
    tail: u16,
    /// How many times the clock's seconds moved, from the stores to the end.
    ticks: u8,
    items: u8,
    weapon: u8,
    /// Her pose when the characters are read.
    pose: u8,
};

pub const Error = error{ PickupNeverEnded, NoSymbol, NoVblank };

/// Frames the Game Boy is run from the new game's first frame of play before
/// anything is done: the appearance, as the crawl's new game.
const settle_gb: u64 = 300;
/// And after the pickup ends, before the characters are read.
const after: u64 = 20;
const select_bit: u4 = 0b0100;
const ly: u16 = 0xFF44;
const vblank_line: u8 = 144;

/// On to the next line 144, where the vblank interrupt is raised, and the
/// flag is the one this frame's handler will act on. **Sampled here and not
/// at a frame's start**, because a pickup's second record is queued after
/// line 0 of the frame its first ends in, and moved in that frame's vblank:
/// at line 0 the gap between the two records is seen and the second's first
/// chunk is not, and the spin pair's four chunks read as three.
fn toVblank(m: *harness.Machine) !void {
    var guard: usize = 0;
    while (m.read(ly) == vblank_line) : (guard += 1) {
        if (guard > harness.Machine.instructions_per_frame_cap) return Error.NoVblank;
        _ = try m.sys.step();
    }
    while (m.read(ly) != vblank_line) : (guard += 1) {
        if (guard > harness.Machine.instructions_per_frame_cap) return Error.NoVblank;
        _ = try m.sys.step();
    }
}

/// Our Game Boy's side of every case, each from the same new game.
pub fn references(a: std.mem.Allocator, rom: []const u8) ![]Ref {
    const p = try scenario.pickups(rom);
    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    _ = try m.runFrames(settle_gb, .{});
    var base = try m.snapshot();
    defer base.deinit(a);
    const out = try a.alloc(Ref, cases.len);
    for (cases, out) |c, *r| {
        m.restore(base);
        var bits = m.read(samus_items);
        for (c.first) |row| bits |= p.bits[@intFromEnum(row)];
        m.write(samus_items, bits);
        if (c.missiles) {
            var b: probe.Buttons = .{};
            b.buttons &= ~select_bit;
            _ = try m.runFrames(1, b);
            _ = try m.runFrames(10, .{});
        }
        m.write(item_collected, @intFromEnum(c.item));
        m.write(item_collection_flag, flag_collecting);
        r.counter = m.read(frame_counter);
        r.xfer_frames = 0;
        r.ticks = 0;
        var seconds = m.read(game_time_seconds);
        var ended: ?u64 = null;
        var bit_at: ?u64 = null;
        var n: u64 = 0;
        while (n < 3000) : (n += 1) {
            try toVblank(&m);
            if (m.read(vram_transfer_flag) != 0) r.xfer_frames += 1;
            if (bit_at == null and m.read(samus_items) != bits) bit_at = n;
            if (m.read(game_time_seconds) != seconds) {
                seconds = m.read(game_time_seconds);
                r.ticks += 1;
            }
            if (ended == null and m.read(item_collection_flag) == flag_done) {
                m.write(item_collection_flag, 0);
                m.write(item_collected, 0);
                ended = n;
                r.length = @intCast(n);
                r.tail = if (bit_at) |b| @intCast(n - b) else 0;
            }
            if (ended) |e| if (n >= e + after) break;
        } else return Error.PickupNeverEnded;
        for (&r.chars, 0..) |*b, i| b.* = m.read(chars_at + @as(u16, @intCast(i)));
        r.items = m.read(samus_items);
        r.weapon = m.read(samus_active_weapon);
        r.pose = m.read(samus_pose);
    }
    return out;
}

// ---- The cart's side ---------------------------------------------------------

pub fn code(c: u8) []const u8 {
    return switch (c) {
        0 => "the pickup left the Game Boy's characters, frames, bit and weapon",
        1 => "Fatal ran",
        2 => "the new game, play, or the end of the run never arrived",
        3 => "the chord did not open the menu, or A did not open SAMUS",
        4 => "the engine was handed a pose it could not run",
        5 => "the menu did not set the case's first items",
        6 => "the item's bit never landed",
        7 => "the pickup never ended",
        8 => "the transfer's frames are not the Game Boy's",
        9 => "the object characters are not the Game Boy's",
        10 => "the selected weapon is not the Game Boy's",
        11 => "her pose after the pickup is not the Game Boy's",
        12 => "the pickup's length is not within 2% of the Game Boy's",
        13 => "the frames from the item's bit to the flag's $03 are not the Game Boy's",
        14 => "the clock ticked a different number of times over the pickup",
        255 => "the emulator did not exit normally",
        else => "an unknown code: a timeout, or a script error, reads as one",
    };
}

fn sym(name: []const u8) !u32 {
    return (inject.symbol(name) orelse return Error.NoSymbol) & 0x1FFFF;
}

const apart = 8;

pub fn writeLua(rom: []const u8, c: Case, r: Ref, w: *std.Io.Writer) !void {
    const p = try scenario.pickups(rom);
    var mask: u8 = 0;
    for (c.first) |row| mask |= p.bits[@intFromEnum(row)];
    const bit: u8 = switch (c.item) {
        .screw_attack => p.bits[@intFromEnum(scenario.Row.screw)],
        .space_jump => p.bits[@intFromEnum(scenario.Row.space)],
        .spring_ball => p.bits[@intFromEnum(scenario.Row.spring)],
        .varia => p.bits[@intFromEnum(scenario.Row.varia)],
        else => 0,
    };
    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- The `{s}` case of the `gfx` rung, 1.0 Step 8a: the `--debug` cart as a
        \\-- new game, given its first items through the debug menu, then the
        \\-- pickup by the orb's lever, and held against our Game Boy taking the
        \\-- same pickup (`src/gfx_grade.zig`): the object characters, the frames
        \\-- the transfer takes, the item's bit and the weapon.
        \\--
        \\-- Exit codes: 0 held; 1 Fatal; 2 no play or out of frames; 3 no menu; 4 an
        \\-- unrunnable pose; 5 the first items; 6 no bit; 7 no end; 8 the frames;
        \\-- 9 the characters; 10 the weapon; 11 the pose. A failure prints what it
        \\-- compared.
        \\
        \\local wram  = emu.memType.snesWorkRam
        \\local vram  = emu.memType.snesVideoRam
        \\local cgram = emu.memType.snesCgRam
        \\local function rd16(addr) return emu.read(addr, wram) | (emu.read(addr + 1, wram) << 8) end
        \\local R = {{ frames = {d}, unhandled = {d}, countdown = {d}, open = {d}, page = {d},
        \\  items = {d}, weapon = {d}, collected = {d}, flag = {d}, stage = {d}, qhead = {d}, qtail = {d} }}
        \\local APART, CHARS = {d}, {d}
        \\local ITEM, BIT, FIRST, MISSILES, FRAMES = {d}, {d}, {d}, {s}, {s}
        \\local WANT_FRAMES, WANT_ITEMS, WANT_WEAPON, WANT_POSE, POSE = {d}, {d}, {d}, {d}, {d}
        \\
    , .{
        c.name,
        try sym("VarFrameCount"),    try sym("VarUnhandled"),  try sym("VarCountdown"),
        try sym("VarDebugOpen"),     try sym("VarDebugPage"),  try sym("VarItems"),
        try sym("VarActiveWeapon"),  try sym("VarItemCollected"), try sym("VarItemFlag"),
        try sym("VarItemStage"),     try sym("VarGfxQHead"),   try sym("VarGfxQTail"),
        apart,                       @as(u32, target.obj_char_base) * 2,
        @intFromEnum(c.item),        bit,                      mask,
        if (c.missiles) "true" else "false",
        if (c.frames) "true" else "false",
        r.xfer_frames,               r.items,                  r.weapon,
        r.pose,                      try sym("VarPose"),
    });
    // 1.0 Step 9's: the animation's flag, the clock, and what they grade.
    try w.print(
        \\R.varia, R.seconds = {d}, {d}
        \\local LENGTH, WANT_LENGTH, TOLERANCE = {s}, {d}, {d}
        \\local GB_COUNTER, WANT_TAIL, WANT_TICKS = {d}, {d}, {d}
        \\
    , .{
        try sym("VarVariaAnim"),     try sym("VarIgtSeconds"),
        if (c.length) "true" else "false",
        r.length,                    length_tolerance,
        r.counter,                   r.tail,
        r.ticks,
    });
    // The Game Boy's characters, a tile's sixteen bytes a row.
    try w.print("GB = {{\n", .{});
    for (0..chars_len / 16) |t| {
        try w.print("  {{", .{});
        for (r.chars[t * 16 ..][0..16], 0..) |b, k| try w.print("{s}{d}", .{ if (k == 0) "" else ",", b });
        try w.print("}},\n", .{});
    }
    // B first: a new game faces the screen until a button is pressed
    // (`poseFunc_faceScreen`, 00:$0EA5), and our Game Boy's boot has pressed
    // Start. Then the menu: the chord, A for SAMUS, each row's A, the chord.
    try w.print("}}\nSTEPS = {{ \"b\",", .{});
    if (c.first.len > 0) {
        try w.print(" \"chord\", \"a\",", .{});
        var row: u8 = 0;
        for (c.first) |f| {
            const to = @intFromEnum(f);
            while (row != to) : (row = if (row < to) row + 1 else row - 1) {
                try w.print(" \"{s}\",", .{if (row < to) "down" else "up"});
            }
            try w.print(" \"a\",", .{});
        }
        try w.print(" \"chord\",", .{});
    }
    if (c.missiles) try w.print(" \"select\",", .{});
    try w.print(" }}\n", .{});

    try w.print(
        \\
        \\for i = 0, 0x1FFF do emu.write(i, 0, emu.memType.snesSaveRam) end
        \\
        \\local phase, frames, starts, tick = 0, 0, 0, 0
        \\local stopped = false
        \\local function fail(c, what)
        \\  if stopped then return end
        \\  stopped = true
        \\  print(what)
        \\  emu.stop(c)
        \\end
        \\
        \\local FIRST_TICK = 10
        \\local function stepAt(t, off)
        \\  local i = t - FIRST_TICK - off
        \\  if i < 0 or i % APART ~= 0 then return nil end
        \\  return i // APART + 1
        \\end
        \\local PADS = {{ chord = {{ l = true, r = true, start = true }} }}
        \\local xfer, pickAt, endAt, got, gotAt, ticks, seconds = 0, nil, nil, false, nil, 0, 0
        \\
        \\emu.addEventCallback(function()
        \\  if stopped then return end
        \\  frames = frames + 1
        \\  if rd16(0, cgram) == 0x7C1F then fail(1, "Fatal") end
        \\  if emu.read(R.unhandled, wram) ~= 0 then fail(4, "unhandled pose " .. emu.read(R.unhandled, wram)) end
        \\  if frames > 6000 then fail(2, "phase " .. phase .. " at frame " .. frames) end
        \\  if phase == 0 and rd16(R.frames) ~= 0 then phase = 1 end
        \\  if phase == 2 and rd16(R.countdown) ~= 0 then phase = 3 end
        \\  if phase == 3 and rd16(R.countdown) == 0 then phase, tick = 4, 0 end
        \\  if phase ~= 4 then return end
        \\  tick = tick + 1
        \\  local k = stepAt(tick, 5)
        \\  if k ~= nil and k <= #STEPS then
        \\    if STEPS[k] == "a" and STEPS[k - 1] == "chord" and emu.read(R.page, wram) ~= 1 then fail(3, "A: no SAMUS page") end
        \\  end
        \\  -- The steps done and the menu shut: the first items must be hers.
        \\  local ready = FIRST_TICK + #STEPS * APART + 20
        \\  if tick == ready then
        \\    if emu.read(R.open, wram) ~= 0 then fail(3, "the menu is still up") return end
        \\    local have = emu.read(R.items, wram)
        \\    if (have & FIRST) ~= FIRST then fail(5, string.format("items %02x, wanted %02x in them", have, FIRST)) return end
        \\  end
        \\  -- The orb's two stores, 02:$4E6D-$4E7C, on the tick whose counter is
        \\  -- the Game Boy's at its stores less one: the frame the two sample
        \\  -- points put in step, measured on the bit's landing (1.0 Step 9).
        \\  -- Varia's animation draws on even frames, so its length depends on
        \\  -- the parity; the clock ticks on the counter's wrap, so its ticks
        \\  -- depend on the whole byte.
        \\  if pickAt == nil and tick >= ready and (rd16(R.frames) & 0xFF) == ((GB_COUNTER - 1) & 0xFF) then
        \\    emu.write(R.collected, ITEM, wram)
        \\    emu.write(R.flag, 0xFF, wram)
        \\    pickAt, seconds = tick, emu.read(R.seconds, wram)
        \\    return
        \\  end
        \\  if pickAt == nil then return end
        \\  if emu.read(R.qhead, wram) ~= emu.read(R.qtail, wram) or emu.read(R.varia, wram) ~= 0 then xfer = xfer + 1 end
        \\  if BIT ~= 0 and not got and (emu.read(R.items, wram) & BIT) ~= 0 then got, gotAt = true, tick end
        \\  if emu.read(R.seconds, wram) ~= seconds then seconds, ticks = emu.read(R.seconds, wram), ticks + 1 end
        \\  if endAt == nil and emu.read(R.flag, wram) == 3 then
        \\    emu.write(R.flag, 0, wram)
        \\    emu.write(R.collected, 0, wram)
        \\    endAt = tick
        \\  end
        \\  if endAt == nil then
        \\    if tick - pickAt > 3000 then fail(7, "the flag never reached $03") end
        \\    return
        \\  end
        \\  if tick < endAt + 20 then return end
        \\  if emu.read(R.stage, wram) ~= 0 then fail(7, "the stage is " .. emu.read(R.stage, wram) .. " after the flag") return end
        \\  if BIT ~= 0 and not got then fail(6, "no bit") return end
        \\  local items = emu.read(R.items, wram)
        \\  if items ~= WANT_ITEMS then fail(6, string.format("items %02x, the Game Boy's %02x", items, WANT_ITEMS)) return end
        \\  if FRAMES and xfer ~= WANT_FRAMES then fail(8, string.format("%d frames of transfer, the Game Boy's %d", xfer, WANT_FRAMES)) return end
        \\  for t = 0, #GB - 1 do
        \\    local base = CHARS + t * 32
        \\    for j = 0, 31 do
        \\      local want = 0
        \\      if j < 16 then want = GB[t + 1][j + 1] end
        \\      local have = emu.read(base + j, vram)
        \\      if have ~= want then
        \\        fail(9, string.format("tile $%02x byte %d: %02x, the Game Boy's %02x", t, j, have, want))
        \\        return
        \\      end
        \\    end
        \\  end
        \\  local weapon = emu.read(R.weapon, wram)
        \\  if weapon ~= WANT_WEAPON then fail(10, string.format("weapon %02x, the Game Boy's %02x", weapon, WANT_WEAPON)) return end
        \\  local pose = emu.read(POSE, wram)
        \\  if pose ~= WANT_POSE then fail(11, string.format("pose %02x, the Game Boy's %02x", pose, WANT_POSE)) return end
        \\  local length = endAt - pickAt
        \\  local off = math.abs(length - WANT_LENGTH) / WANT_LENGTH
        \\  if LENGTH and off > TOLERANCE then fail(12, string.format("%d frames, the Game Boy's %d: %.2f%%", length, WANT_LENGTH, off * 100)) return end
        \\  if BIT ~= 0 and endAt - gotAt ~= WANT_TAIL then fail(13, string.format("%d frames from the bit to the flag, the Game Boy's %d", endAt - gotAt, WANT_TAIL)) return end
        \\  if ticks ~= WANT_TICKS then fail(14, string.format("the clock ticked %d times, the Game Boy's %d", ticks, WANT_TICKS)) return end
        \\  print(string.format("%d frames of transfer; %d frames long, the Game Boy's %d (%.2f%%); %d ticks", xfer, length, WANT_LENGTH, off * 100, ticks))
        \\  stopped = true
        \\  emu.stop(0)
        \\end, emu.eventType.endFrame)
        \\
        \\emu.addEventCallback(function()
        \\  if phase == 1 then
        \\    local fc = rd16(R.frames)
        \\    local p = {{}}
        \\    if fc + 1 == 5 or fc + 1 == 6 then
        \\      p.start = true
        \\      starts = starts + 1
        \\      if starts == 2 then phase = 2 end
        \\    end
        \\    emu.setInput(p, 0)
        \\    return
        \\  end
        \\  if phase ~= 4 then return end
        \\  local k = stepAt(tick, 0) or stepAt(tick, 1)
        \\  local p = {{}}
        \\  if k ~= nil and k <= #STEPS then
        \\    local key = STEPS[k]
        \\    p = PADS[key] or {{ [key] = true }}
        \\  end
        \\  emu.setInput(p, 0)
        \\end, emu.eventType.inputPolled)
        \\
    , .{});
}

/// The faults the rung is shown failing on, each with the case and the code
/// that must see it.
pub const Fault = struct {
    label: []const u8,
    offset: usize,
    patch: []const u8,
    case: []const u8,
    want: u8,
    what: []const u8,
};
pub const faults = [_]Fault{
    // The ice beam's arm handed the wave beam's row: past `lda.b #$01` to
    // `ldx.w #!GFX_ICE`'s operand. The characters are the wave's.
    .{ .label = "ItemPickupArm_beamIce", .offset = 3, .patch = &.{0x04}, .case = "ice", .want = 9, .what = "the ice beam's arm handed the wave's row: caught on the characters" },
    // A whole record a vblank (`and.w #$FFFF`): the spin pair's four chunks
    // go up in two frames.
    .{ .label = "GfxXferNmi_chunk", .offset = 1, .patch = &.{ 0xFF, 0xFF }, .case = "screw", .want = 8, .what = "a whole record a vblank, not a chunk: caught on the frames" },
    // Varia's pose back to the `$13` the arm wrote before 1.0 Step 8a (past
    // `lda !Items / ora / sta !Items` to `lda.b #$80`'s operand). The ROM
    // writes $80 (00:$38E8): standing, turned to the screen. `$13` is the
    // appearance, which a new game holds until a button is pressed.
    .{ .label = "VariaStage_pose", .offset = 7, .patch = &.{0x13}, .case = "varia", .want = 11, .what = "Varia's pose the appearance's $13, as before Step 8a: caught on the pose" },
    // 1.0 Step 9: the animation's loop ended at once (`cmp.b #$85` made
    // `#$80`), so none of it is drawn: caught on the frames.
    .{ .label = "VariaStage_rows", .offset = 1, .patch = &.{0x80}, .case = "varia", .want = 8, .what = "Varia's animation cut to nothing: caught on the frames" },
    // 1.0 Step 9's two defects, each put back. The jingle's first pass tests
    // the countdown (`bra .jingleFrame` made a branch to the next line), so
    // Varia's pickup, which arrives with it spent, loses the pass.
    .{ .label = "RunItemPickup_jingle1", .offset = 6, .patch = &.{0x00}, .case = "varia", .want = 13, .what = "the jingle's first pass testing the countdown: caught from the bit to the flag" },
    // And the jingle's frames not ticking the clock.
    .{ .label = "MainLoop_itemTick", .offset = 0, .patch = &.{0x80}, .case = "ice", .want = 14, .what = "the jingle's frames not ticking the clock: caught on the ticks" },
};
